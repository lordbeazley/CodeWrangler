use [master] ;
go

set quoted_identifier, ansi_nulls on ;

if exists (select 1 from information_schema.routines where [routine_schema] = 'dbo' and [routine_name] = 'pr_CodeWrangler')
	drop procedure dbo.[pr_CodeWrangler] ;
go

create procedure dbo.[pr_CodeWrangler] (
	@database nvarchar(4000) = null,
	@exclude bit = 0,
	@reset bit = 0,
	@monitor varchar(64) = 'AF, FN, IF, IS, P, RF, TF, TR',									-- CODE ONLY
--	@monitor varchar(64) = 'AF, FN, IF, IS, P, RF, TF, TR, U, V, C, D, F, UQ, PK, R',		-- CODE + TABLES/VIEWS/CONSTRAINTS/RULES
	@verbosity tinyint = 1
)
as
begin

-----------------------------------------------------------------------------------------------------------------------
-- Procedure:	pr_CodeWrangler
-- Author:		Phillip Beazley (phillip@beazley.org)
-- Date:		04/03/2014
--
-- Purpose:		Creates an archive copy of all monitored (configurable) database objects essentially maintaining a
--				current and historic data dictionary. Scans for new and changed objects on each execution. The initial
--				execution will store all existing objects first.
--
-- Notes:		@verbosity == 0: quiet, 1: show changes, 2: testing (code shown only)
--
-- Depends:		master database, udf_longHash
--
-- REVISION HISTORY ---------------------------------------------------------------------------------------------------
-- 06/08/2012	lordbeazley	Initial creation.
-- 06/20/2012	lordbeazley	Repurposed code for greater scope.
-- 06/21/2012	lordbeazley	Separated object system date and entry date.
-- 06/22/2012	lordbeazley	Added handling of table object id changes (drop/recreates).
-- 06/25/2012	lordbeazley	Added handling of object relationships.
-- 07/06/2012	lordbeazley	Added reported creation date/time.
-- 07/06/2012	lordbeazley	Fixed database-name-with-spaces escape issue.
-- 07/06/2012	lordbeazley	Fixed collation mismatch issue.
-- 07/06/2012	lordbeazley	Fixed null set elimination warning.
-- 03/31/2014	lordbeazley	Merged codeArchive bits.
-- 04/01/2014	lordbeazley	Solved the energy crisis.
-- 04/03/2014	lordbeazley	Fixed to utilize @monitor list but default to code only.
-- TDB			lordbeazley	Added marking/pruning of deleted objects.
-----------------------------------------------------------------------------------------------------------------------

set nocount, ansi_padding, ansi_warnings, concat_null_yields_null on ;

declare @begin datetime = GetDate() ;
declare @beginStr varchar(19) = Convert(varchar(10), @begin, 101) + ' ' + Convert(varchar(8), @begin, 108) ;

if (@verbosity > 0) raiserror(':: EXECUTING CODE WRANGLER @ %s', 0, 1, @beginStr) with nowait ;
if (@verbosity > 0) raiserror('', 0, 1) with nowait ;

-- check for dependencies
if not exists (select 1 from information_schema.routines where [routine_schema] = 'dbo' and [routine_name] = 'fn_LongHash')
begin
	raiserror(':: missing dbo.[fn_LongHash] -- install before continuing', 16, 1) with nowait ;
	return -1 ;
end

-- reset archive
if (@reset = 1 and exists (select 1 from information_schema.tables where [table_schema] = 'dbo' and [table_name] = N'CodeWrangler' and [table_type] = 'BASE TABLE'))
begin
	exec sp_executesql N'drop table dbo.[CodeWrangler] ;' ;
	raiserror(':: dropped table dbo.[CodeWrangler]', 0, 1) with nowait ;
end

-- create archive table if needed
if not exists (select 1 from information_schema.tables where [table_schema] = 'dbo' and [table_name] = N'CodeWrangler' and [table_type] = 'BASE TABLE')
begin
	create table dbo.[CodeWrangler] (
		[id] int not null identity (1, 1),
		[dt] datetime not null constraint def_dt default (GetDate()),
		[dbName] sysname not null constraint def_dbname default (db_name()),
		[oid] int not null,
		[pid] int not null,
		[objName] nvarchar(128) not null,
		[objType] varchar(32) not null,
		[objRevision] int not null constraint def_objRevision default (0),
		[objDateTime] datetime not null constraint def_objDateTime default (GetDate()),
		[objText] varchar(max) null,
		[objLength] int null,
		[objDigest] varbinary(36) null,
		[defObj] int null,
		[chkObj] int null,
		[isComputed] bit null,
		[isNullable] bit null,
		[isIdentity] bit null,
		constraint [pk_CodeWrangler] primary key clustered ([dbName], [oid], [pid], [objName], [objType], [objRevision])
	) ;
	create index [ix_CodeWrangler_objName] on dbo.[CodeWrangler] ([objName] asc) ;
	create index [ix_CodeWrangler_dt] on dbo.[CodeWrangler] ([dt] desc) ;
	create index [ix_CodeWrangler_objDateTime] on dbo.[CodeWrangler] ([objDateTime] asc) ;
	create index [ix_CodeWrangler_objLength] on dbo.[CodeWrangler] ([objLength] asc) ;
	create index [ix_CodeWrangler_objDigest+i] on dbo.[CodeWrangler] ([objDigest] asc) include ([dbName], [objName], [objType]) ;
	raiserror(':: created table dbo.[CodeWrangler]', 0, 1) with nowait ;
end

-- close and deallocate cursors if they exist
if cursor_status('global', 'dbCursor') <> -3
begin
	if cursor_status('global', 'dbCursor') <> -1
		close dbCursor ;
	deallocate dbCursor ;
end

-- create variables
declare
	@excluded char(1),
	@databaseCount varchar(3),
	@dbName sysname,
	@sql varchar(max),
	@z nvarchar(max),
	@q varchar(max),
	@err int,
	@errMsg varchar(2048),
	@parObj sysname,
	@curObj sysname,
	@curRev int ;

select
	@excluded = Convert(char, @exclude),
	@databaseCount = Convert(varchar, Coalesce(Len(@database), 0)) ;

-- create list of databases
set @database = Replace(@database, ',', ''',''') ;
exec ('
declare dbCursor cursor fast_forward for
select
	[name]
from
	master.dbo.[sysdatabases]
where
	DatabasePropertyEx([name], ''Status'') = ''ONLINE''
	and DatabasePropertyEx([name], ''Updateability'') = ''READ_WRITE''
	and DatabasePropertyEx([name], ''IsInStandBy'') = 0
	and [name] not in (''tempdb'', ''model'')
	and (
		(
			' + @excluded + ' = 0
			and (
				[name] in (''' + @database + ''')
				or ' + @databaseCount + ' = 0
			)
		)
		or
		(
			' + @excluded + ' = 1
			and [name] not in (''' + @database + ''')
		)
	)
order by
	[name] asc ;
') ;
open dbCursor ;
fetch next from dbCursor into @dbName ;

-- create database loop
while @@fetch_status = 0
	begin

		if (@verbosity > 0) raiserror(':: checking : [%s]', 0, 1, @dbName) with nowait ;

		select @sql = null, @z = null, @q = null ;

		set @sql = '
			use [' + @dbName + '] ;
			set ansi_warnings off ;
		' ;

		-- find and update table id changes
		select
			@sql = Coalesce(@sql, '') + '
			update master.dbo.[CodeWrangler] set [oid] = ' + Convert(varchar, [o].[id]) + ' from master.dbo.[CodeWrangler] [cw] where cw.[oid] = ' + Convert(varchar, cw.[oid]) + ' ;
			update master.dbo.[CodeWrangler] set [pid] = ' + Convert(varchar, [o].[id]) + ' from master.dbo.[CodeWrangler] [cw] where cw.[pid] = ' + Convert(varchar, cw.[oid]) + ' ;
		'
		from
			sysobjects [o]
			inner join dbo.[CodeWrangler] [cw]
				on [o].[name] = [cw].[objName]
					and [cw].[dbName] = db_name()
					and [cw].[objName] = [o].[name]
					and [cw].[objType] = [o].[xtype]
					and [o].[id] <> [cw].[oid]
		where
			[o].[xtype] = 'U'
			and objectpropertyex([o].[id],'IsMSShipped') = 0 ;

		select @sql = @sql + '
			insert into
				master.dbo.[CodeWrangler]
			select distinct
				[dt] = GetDate(),
				[dbName] = db_name(),
				[oid] = o.[id],
				[pid] = o.[parent_obj],
				[objName] = o.[name],
				[objType] = o.[xtype],
				[objRevision] = (select Coalesce(Max([objRevision]), 0) + 1 from master.dbo.[CodeWrangler] where [dbName] collate database_default = db_name() collate database_default and [objName] collate database_default = o.[name] collate database_default and [objType] collate database_default = o.[xtype] collate database_default),
				[objDateTime] = Coalesce(o.[crdate], GetDate()),
				[objText] = RTrim(LTrim(c.[text])),
				[objLength] = Len(RTrim(LTrim(c.[text]))),
				[objDigest] = master.dbo.[udf_longHash](Convert(varbinary(max), c.[text])),
				[defObj] = null,
				[chkObj] = null,
				[isComputed] = null,
				[isNullable] = null,
				[isIdentity] = null
			from
				sysobjects [o]
				left outer join (
					select
						[id],
						[text] = 
		' ;

		set @z = N'select @q = coalesce(@q + ''							+ '', ''					  '') + ''Cast(Coalesce(Min(case when c.[colid] = '' + cast([colid] as varchar) + '' then c.[text] end), '''''''') as varchar(max))'' + char(13) + char(10) from [' + @dbName + ']..syscomments group by [colid] order by [colid] asc ;' ;
		exec sp_executesql @z, N'@q varchar(max) output', @q = @q output ;
		select @sql = @sql + @q + '					from
						syscomments [c]
					where
						c.[colid] is not null
--						and c.[encrypted] = 0
					group by
						c.[id]
				) [c]
					on o.[id] = c.[id]
			where
				o.[name] <> ''dtproperties''
				and objectpropertyex(o.[id],''IsMSShipped'') = 0
				and o.[xtype] in (''' + replace(@monitor, ', ', ''', ''') + ''')
				and (
					not exists (
						-- new object
						select
							1
						from
							master.dbo.[CodeWrangler] [cw]
						where
							cw.[dbName] collate database_default = db_name() collate database_default
							and cw.[objName] collate database_default = o.[name] collate database_default
							and cw.[objType] collate database_default = o.[xtype] collate database_default
					)
					or exists (
						-- object changed
						select
							1
						from
							master.dbo.[CodeWrangler] [cw]
						where
							cw.[dbName] collate database_default = db_name() collate database_default
							and cw.[objName] collate database_default = o.[name] collate database_default
							and cw.[objType] collate database_default = o.[xtype] collate database_default
							and cw.[objRevision] = (select Max([objRevision]) from master.dbo.[CodeWrangler] where [dbName] collate database_default = cw.[dbName] collate database_default and [objName] collate database_default = cw.[objName] collate database_default and [objType] collate database_default = cw.[objType] collate database_default)
							and (
								(
--									o.[xtype] <> (''AF'', ''FN'', ''IF'', ''IS'', ''IT'', ''P'', ''F'', ''PK'', ''R'', ''S'', ''SQ'', ''TF'', ''TR'', ''UQ'', ''V'', ''PC'')
									c.[text] is not null
									and cw.[objDigest] <> master.dbo.[udf_longHash](Convert(varbinary(max), c.[text]))
								) or (
									o.[xtype] = ''U''
									and o.[id] <> cw.[oid]
								)
							)
					)
				)
			order by
				o.[name] asc ;

			insert into
				master.dbo.[CodeWrangler]
			select distinct
				[dt] = GetDate(),
				[dbName] = db_name(),
				[oid] = 0,
				[pid] = c.[id],
				[objName] = c.[name],
				[objType] = s.[name],
				[objRevision] = (select Coalesce(Max([objRevision]), 0) + 1 from master.dbo.[CodeWrangler] where [dbName] collate database_default = db_name() collate database_default and [oid] = 0 and [pid] = c.[id] and [objName] collate database_default = c.[name] collate database_default),
				[objDateTime] = Coalesce(o.[crdate], GetDate()),
				[objText] =
					case
						when s.[name] in (''char'', ''nchar'', ''varchar'', ''nvarchar'')
							then s.[name] + '' ('' + Convert(varchar, c.[length]) + '')''
						when s.[name] in (''decimal'', ''numeric'')
							then s.[name] + '' ('' + Convert(varchar, c.[prec]) + '', '' + Convert(varchar, c.[scale]) + '')''
						when s.[name] in (''float'')
							then s.[name] + '' ('' + Convert(varchar, c.[prec]) + '')''
						else
							s.[name]
					end,
				[objLength] = c.[length],
				[objDigest] = master.dbo.[udf_longHash](Convert(varbinary(max), c.[name] + s.[name] + Convert(varchar, c.[length]) + Convert(varchar, Coalesce(c.[prec], 0)) + Convert(varchar, Coalesce(c.[scale], 0)))),
				[defObj] = c.[cdefault],
				[chkObj] = c.[domain],
				[isComputed] = c.[iscomputed],
				[isNullable] = c.[isnullable],
				[isIdentity] = ColumnProperty(o.[id], c.[name], ''IsIdentity'')
			from
				sysobjects [o]
				inner join syscolumns [c] on o.[id] = c.[id]
				inner join systypes [s] on c.[xusertype] = s.[xusertype]
			where
				c.[name] <> ''''
				and c.[name] <> ''dtproperties''
				and objectpropertyex(o.[id],''IsMSShipped'') = 0
				and o.[xtype] in (''' + Replace(@monitor, ', ', ''', ''') + ''')
				and (
					not exists (
						-- new object
						select
							1
						from
							master.dbo.[CodeWrangler] [cw]
						where
							cw.[dbName] collate database_default = db_name() collate database_default
							and cw.[objName] collate database_default = c.[name] collate database_default
							and cw.[objType] collate database_default = s.[name] collate database_default
					)
					or exists (
					-- object changed
						select
							1
						from
							master.dbo.[CodeWrangler] [cw]
						where
							cw.[dbName] collate database_default = db_name() collate database_default
							and cw.[objName] collate database_default = c.[name] collate database_default
							and cw.[objType] collate database_default = s.[name] collate database_default
							and cw.[oid] = 0
							and cw.[pid] = c.[id]
							and cw.[objRevision] = (select Max([objRevision]) from master.dbo.[CodeWrangler] where [dbName] collate database_default = cw.[dbName] collate database_default and [oid] = 0 and [pid] = c.[id] and [objName] collate database_default = c.[name] collate database_default)
							and cw.[objDigest] <> master.dbo.[udf_longHash](Convert(varbinary(max), c.[name] + s.[name] + Convert(varchar, c.[length]) + Convert(varchar, Coalesce(c.[prec], 0)) + Convert(varchar, Coalesce(c.[scale], 0))))
					)
				)
			order by
				c.[name] asc ;
		' ;

		--declare
		--	@prune bit,
		--	@pruneObj int ;

		--declare pruneCursor cursor local fast_forward for
		--select distinct [id] = [oid] from master.dbo.[CodeWrangler] where [oid] <> 0
		--union
		--select distinct [id] = [pid] from master.dbo.[CodeWrangler] where [pid] <> 0
		--order by [id] asc ;
		--open pruneCursor ;
		--fetch next from pruneCursor into @pruneObj ;

		---- create change loop
		--while @@fetch_status = 0
		--	begin

		--		set @prune = 1 ;
		--		select @prune = 0 from sysobjects where objectpropertyex([id],'IsMSShipped') = 0 and [id] = @pruneObj ;
		--		select @prune = 0 from syscolumns where objectpropertyex([id],'IsMSShipped') = 0 and [id] = @pruneObj ;

		--		if (@prune = 1)
		--			raiserror('   del obj  : [%d]', 0, 1, @pruneObj) with nowait ;

		--		-- get next object to prune
		--		fetch next from pruneCursor into @pruneObj ;
		--	end

		---- close prune cursor
		--close pruneCursor ;
		--deallocate pruneCursor ;

		if (@verbosity = 2)

			raiserror(@sql, 10, 1) with nowait ;

		else
		begin

			-- gather changes
			exec @err = sp_sqlexec @sql ;
			set @err = Coalesce(NullIf(@err, 0), @@error) ;
			if (@err != 0)
			begin
				select @errMsg = '@err: ' + Cast(@err as varchar) + ' while processing database: ' + @dbName ;
				raiserror(@errMsg, 10, 1) with nowait ;
			end

			-- show changes
			if (@verbosity = 1)
			begin

				declare chgCursor cursor local fast_forward for
				select
					[parentObjName] = Coalesce((select top 1 [objName] from master.dbo.[CodeWrangler] where [oid] = cw.[pid] and cw.[pid] <> 0), ''),
					cw.[objName],
					cw.[objRevision]
				from
					master.dbo.[CodeWrangler] [cw]
				where
					cw.[dt] >= @begin
					and cw.[dbName] = @dbName
				order by
					[parentObjName] asc,
					cw.[objName] asc ;
				open chgCursor ;
				fetch next from chgCursor into @parObj, @curObj, @curRev ;

				-- create change loop
				while @@fetch_status = 0
					begin

						if (Coalesce(@parObj, '') <> '') set @parObj = QuoteName(@parObj) ;
						else set @parObj = '' ;

						if (Coalesce(@curObj, '') <> '') set @curObj = '.' + QuoteName(@curObj) ;
						else set @curObj = '' ;

						if (@curRev = 1)
							raiserror('   new obj  : [%s].%s%s (rev %d)', 0, 1, @dbName, @parObj, @curObj, @curRev) with nowait ;
						else
							raiserror('   changed  : [%s].%s%s (rev %d)', 0, 1, @dbName, @parObj, @curObj, @curRev) with nowait ;

						-- get next database name
						fetch next from chgCursor into @parObj, @curObj, @curRev ;
					end

				-- close change cursor
				close chgCursor ;
				deallocate chgCursor ;

			end

		end

		-- get next database name
		fetch next from dbCursor into @dbName ;
	end

-- close database cursor
close dbCursor ;
deallocate dbCursor ;

if (@verbosity > 0) raiserror('', 0, 1) with nowait ;
if (@verbosity > 0) raiserror(':: CODE WRANGLER CHECK COMPLETE', 0, 1) with nowait ;

end
go

return ;

-- example(s)
--exec [pr_CodeWrangler] @monitor = 'AF, FN, IF, IS, P, RF, TF, TR' ;	-- monitor code only
--exec [pr_CodeWrangler] @database = 'msdb', @reset = 1 ;
--exec [pr_CodeWrangler] @reset = 1 ;
--exec [pr_CodeWrangler] @database = 'AdventureWorks', @reset = 1 ;
--exec [pr_CodeWrangler] @database = 'AdventureWorks', @verbosity = 2 ;
--exec [pr_CodeWrangler] @database = 'master', @verbosity = 0 ;
--exec [pr_CodeWrangler] @database = 'master', @verbosity = 1 ;
--exec [pr_CodeWrangler] @database = 'master', @verbosity = 2 ;
--exec [pr_CodeWrangler] @verbosity = 1 ;

--select top 5 * from dbo.[CodeWrangler] order by [objLength] desc, [dbName] asc, [objName] asc, [objRevision] desc ;	-- biggest
--select top 5 * from dbo.[CodeWrangler] order by [dt] desc, [dbName] asc, [objName] asc, [objRevision] desc ;			-- newest
--select top 5 * from dbo.[CodeWrangler] order by [objRevision] desc, [dbName] asc, [objName] asc ;						-- revisions
