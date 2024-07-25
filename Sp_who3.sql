 ﻿USE [Admin]
GO
/****** Object:  StoredProcedure [dbo].[sp_who3]    Script Date: 3/25/2024 8:40:54 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


ALTER PROCEDURE [dbo].[sp_who3] @x NVARCHAR(128) = NULL 

AS
/****************************************************************************************** 
   This is a current activity query used to identify what processes are currently running 
   on the processors.  Use to first view the current system load and to identify a session 
   of interest such as blocking, waiting and granted memory, missing index.  You should execute the query 
   several times to identify if a query is increasing it's CPU time or memory granted.

	Parameters:
	sp_who3 		                    - who is active;
	sp_who3 0 or 'help'		            - Get Parameters sp_who3 accept;
	sp_who3 1 or 'memory'  	            - who is requesting more memory (top 10);
	sp_who3 2 or 'cpu cached queries'   - who has cached plans that consumed the most cumulative CPU (top 10);
	sp_who3 21 or 'cpu high current'    - High cpu consuming queries currently running (top 10);
	sp_who3 3 or 'count'  	            - who is connected and how many sessions it has by login and host name;
	sp_who3 4 or 'all connection' 	    - who connected -all connection where SPID >50 and login <> sa;
	sp_who3 5 or 'block' 	            - who is blocking-shows blocking tree;
	sp_who3 6 or 'VLF' 	                - Find number of VLM per database;
	sp_who3 7 or 'MissingIndex' 	    - Find top 10 missing index;
	sp_who3 8 or 'Wait type' 	        - Find top 10 Wait type;
	sp_who3 9 or 'Update_stat' 	        - Check Update Stat in each Data Base.


This store Procedure is adopted from the following source and Abbott DBA has customized it 

1.	SP_Who3: source  https://gallery.technet.microsoft.com/SPWHO3-74fb1c35 
2.	SP_Who3: source  https://github.com/ronascentes/sp_who3

*******************************************************************************************/
BEGIN
	SET NOCOUNT ON;
	DECLARE @sql_who		NVARCHAR(4000);
	
	SET @sql_who = N'SELECT r.session_id, se.host_name, se.login_name, db_name(r.database_id) AS db_name, r.status, r.command,
					CAST(((DATEDIFF(s,start_time,GetDate()))/3600) as varchar) + '' hour(s), ''
					+ CAST((DATEDIFF(s,start_time,GetDate())%3600)/60 as varchar) + ''min, ''
					+ CAST((DATEDIFF(s,start_time,GetDate())%60) as varchar) + '' sec'' as running_time,
					r.blocking_session_id AS blk_by, r.open_transaction_count AS open_tran_count, r.wait_type,
					object_name = OBJECT_SCHEMA_NAME(s.objectid,s.dbid) + ''.'' + OBJECT_NAME(s.objectid, s.dbid),
 					program_name = se.program_name, p.query_plan AS query_plan,
					sql_text = SUBSTRING(s.text,
						1+(CASE WHEN r.statement_start_offset = 0 THEN 0 ELSE r.statement_start_offset/2 END),
						1+(CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(s.text) ELSE r.statement_end_offset/2 END - (CASE WHEN r.statement_start_offset = 0 THEN 0 ELSE r.statement_start_offset/2 END))),
					 mg.requested_memory_kb, mg.granted_memory_kb, mg.ideal_memory_kb, mg.query_cost,
					((((ssu.user_objects_alloc_page_count + (SELECT SUM(tsu.user_objects_alloc_page_count) FROM sys.dm_db_task_space_usage tsu WHERE tsu.session_id = ssu.session_id)) -
					(ssu.user_objects_dealloc_page_count + (SELECT SUM(tsu.user_objects_dealloc_page_count) FROM sys.dm_db_task_space_usage tsu WHERE tsu.session_id = ssu.session_id)))*8)/1024) AS user_obj_in_tempdb_MB,
					((((ssu.internal_objects_alloc_page_count + (SELECT SUM(tsu.internal_objects_alloc_page_count) FROM sys.dm_db_task_space_usage tsu WHERE tsu.session_id = ssu.session_id)) -
					(ssu.internal_objects_dealloc_page_count + (SELECT SUM(tsu.internal_objects_dealloc_page_count) FROM sys.dm_db_task_space_usage tsu WHERE tsu.session_id = ssu.session_id)))*8)/1024) AS internal_obj_in_tempdb_MB,
					r.cpu_time,	start_time, percent_complete,		
					CAST((estimated_completion_time/3600000) as varchar) + '' hour(s), ''
					+ CAST((estimated_completion_time %3600000)/60000 as varchar) + ''min, ''
					+ CAST((estimated_completion_time %60000)/1000 as varchar) + '' sec'' as est_time_to_go,
					dateadd(second,estimated_completion_time/1000, getdate()) as est_completion_time
			FROM   sys.dm_exec_requests r WITH (NOLOCK)  
			JOIN sys.dm_exec_sessions se WITH (NOLOCK) ON r.session_id = se.session_id
			LEFT OUTER JOIN sys.dm_exec_query_memory_grants mg WITH (NOLOCK) ON r.session_id = mg.session_id AND r.request_id = mg.request_id
			LEFT OUTER JOIN sys.dm_db_session_space_usage ssu WITH (NOLOCK) ON r.session_id = ssu.session_id
			OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) s 
			OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) p ';

	IF  @x IS NULL
	BEGIN
			SET @sql_who = @sql_who + N'WHERE r.session_id <> @@SPID AND se.is_user_process = 1;';
			EXECUTE sp_executesql @sql_who;
	END;

	ELSE IF @x = '1'  OR @x = 'memory'
		BEGIN
			-- who is consuming the memory
			-- Get top 10 Query to show current memory requests, grants, required, used, query cost, sql statement and execution plan for each session
			-- This result shows top 10 with high requested_memory_kb - can be sorted by and of the following granted_memory_kb, required_memory_kb,used_memory_kb, query_cost

			SELECT TOP 10 mg.session_id, t.[text]  as Sql_Statement, qp.query_plan ,mg.requested_memory_kb, mg.granted_memory_kb, mg.required_memory_kb,mg.used_memory_kb, mg.query_cost
			FROM sys.dm_exec_query_memory_grants  mg WITH (NOLOCK) 
			CROSS APPLY sys.dm_exec_sql_text(mg.sql_handle) t 
			CROSS APPLY sys.dm_exec_query_plan(mg.plan_handle) qp 
			where mg.session_id <> @@SPID
			ORDER BY mg.requested_memory_kb DESC 
		END
	ELSE IF @x = '2'  OR @x = 'cpu cached queries'
		BEGIN
			-- who has cached plans that consumed the most cumulative CPU (top 10)
			SELECT TOP 10 DatabaseName = DB_Name(t.dbid),
			sql_text = SUBSTRING (t.text, qs.statement_start_offset/2,
			(CASE WHEN qs.statement_end_offset = -1 THEN LEN(CONVERT(nvarchar(MAX), t.text)) * 2
			ELSE qs.statement_end_offset END - qs.statement_start_offset)/2),
			ObjectName = OBJECT_SCHEMA_NAME(t.objectid,t.dbid) + '.' + OBJECT_NAME(t.objectid, t.dbid),
			qs.execution_count AS [Executions], 
			qs.total_worker_time AS [Total CPU Time (ms)],
			convert (decimal (10,2),qs.total_worker_time/1000000.00) AS [Total CPU Time_Sec],
			qs.total_elapsed_time AS [Duration (ms)], 
			convert (decimal (10,2),qs.total_elapsed_time/1000000.00) AS [Duration_Sec], 
			qs.total_worker_time/qs.execution_count AS [Avg CPU Time (ms)],
			convert (decimal (10,2) ,(qs.total_worker_time/qs.execution_count)/1000000.00) AS [Avg CPU Time_Sec],
			qs.total_logical_reads as [Total Logical Reads],
			qs.total_logical_writes as [Total Logical Writes],
			qs.creation_time AS [Data Cached], qp.query_plan
			FROM sys.dm_exec_query_stats qs WITH(NOLOCK) 
			CROSS APPLY sys.dm_exec_sql_text(plan_handle) AS t
			CROSS APPLY sys.dm_exec_query_plan(plan_handle) AS qp 
			ORDER BY qs.total_worker_time DESC;
		END
ELSE IF @x = '21'  OR @x = 'CPU High current'
	Begin
	SELECT top 10
    req.session_id,
    req.status,
    req.start_time,
    req.cpu_time AS 'cpu_time_ms',
    req.logical_reads,
    req.dop,
    s.login_name,
    s.host_name,
    s.program_name,
    object_name(st.objectid,st.dbid) 'ObjectName',
    REPLACE (REPLACE (SUBSTRING (st.text,(req.statement_start_offset/2) + 1,
        ((CASE req.statement_end_offset    WHEN -1    THEN DATALENGTH(st.text) 
        ELSE req.statement_end_offset END - req.statement_start_offset)/2) + 1),
        CHAR(10), ' '), CHAR(13), ' ') AS statement_text,
    qp.query_plan,
    qsx.query_plan as query_plan_with_in_flight_statistics
FROM sys.dm_exec_requests as req  
JOIN sys.dm_exec_sessions as s on req.session_id=s.session_id
CROSS APPLY sys.dm_exec_sql_text(req.sql_handle) as st
OUTER APPLY sys.dm_exec_query_plan(req.plan_handle) as qp
OUTER APPLY sys.dm_exec_query_statistics_xml(req.session_id) as qsx
ORDER BY req.cpu_time desc;
end

	ELSE IF @x = '3'  OR @x = 'count'
		BEGIN
			-- shows who is connected and how many sessions it has 
			-- collects activity from a logging table 'whoisactive'
			EXEC Admin.dbo.sp_WhoIsActive @get_transaction_info = 1,
									@get_outer_command = 1,
									@get_plans = 1,
									@destination_table = 'Admin.dbo.WhoIsActive';
			-- who is connected and how many sessions it has by LoginName
			Select [login_name],count ([session_id]) as NumberOfSession
			FROM Admin.dbo.WhoIsActive WITH (NOLOCK)
			GROUP BY login_name ORDER BY count ([session_id]) DESC

			-- who is connected and how many sessions it has by HostName
			Select [host_name],count ([session_id]) as NumberOfSession
			FROM Admin.dbo.WhoIsActive WITH (NOLOCK)
			GROUP BY [host_name] ORDER BY count ([session_id]) DESC
		END
	ELSE IF @x = '4'  OR @x = 'all connection'
		BEGIN
			IF OBJECT_ID('tempdb..#SQLStatement') IS NOT NULL DROP TABLE #SQLStatement;
			SELECT spid,
			Definition = CAST(text AS VARCHAR(MAX))
			Into #SQLStatement
			FROM master.sys.sysprocesses s
			CROSS APPLY sys.dm_exec_sql_text (sql_handle)
			WHERE  s.spid > 50 ;

			SELECT sp.spid, sp.hostname, sp.loginame, sp.[program_name], sp.waittime, sp.lastwaittype, sp.cpu, sp.physical_io, sp.memusage, sp.login_time, sp.last_batch, sp.[status], sp.cmd, DB_NAME(sp.[dbid]) dbname,
			DATEDIFF(HOUR, sp.last_batch, GETDATE()) AgeInHours,st.Definition as SQLStatement
			FROM sys.sysprocesses sp
			LEFT JOIN #SQLStatement st on st.spid = sp.spid
			WHERE sp.spid > 50 and loginame <> 'sa'
		END

	ELSE IF @x = '5' OR @x = 'block'
		BEGIN
			IF OBJECT_ID('tempdb..#t') IS NOT NULL DROP TABLE #t;
			CREATE TABLE #t (spid int, blocked int, waittime bigint, lastwaittype nchar(32), waitresource nchar(256), last_batch datetime, hostname varchar(128), [program_name] varchar(128), loginame varchar(128), [sql_handle] varbinary(64), dbname varchar(80), batch varchar(2000));
			INSERT INTO #t (spid, blocked, waittime, lastwaittype, waitresource, last_batch, hostname, [program_name], loginame, [sql_handle]) 
			SELECT spid, blocked, waittime, lastwaittype, waitresource, last_batch, hostname, [program_name], loginame, [sql_handle] 
			FROM sys.sysprocesses 
			WHERE blocked <> 0 AND blocked <> spid;
			INSERT INTO #t (spid, blocked, waittime, lastwaittype, waitresource, last_batch, hostname, [program_name], loginame, [sql_handle]) 
			SELECT spid, blocked, waittime, lastwaittype, waitresource, last_batch, hostname, [program_name], loginame, [sql_handle] 
			FROM sys.sysprocesses 
			WHERE blocked = 0 AND spid IN (SELECT blocked FROM #t);
			UPDATE t SET dbname = DB_NAME(s.[dbid]), batch = LEFT(s.[text], 2000) FROM #t t CROSS APPLY sys.dm_exec_sql_text(t.[sql_handle]) s;
			DECLARE @i INT = 1;
			WHILE @i > 0 BEGIN
			UPDATE #t SET batch = LEFT(batch, PATINDEX('%--%', batch) - 1) + RIGHT(batch, LEN(batch) - CHARINDEX(CHAR(13), batch, PATINDEX('%--%', batch)) + 1) WHERE PATINDEX('%--%', batch) > 0 AND CHARINDEX(CHAR(13), batch, PATINDEX('%--%', batch)) > 0;
			SET @i = @@ROWCOUNT;
			END;
			SET @i = 1;
			WHILE @i > 0 BEGIN
			UPDATE #t SET batch = LEFT(batch, PATINDEX('%/*%', batch) - 1) + RIGHT(batch, LEN(batch) - PATINDEX('%*/%', batch) - 1) WHERE PATINDEX('%/*%', batch) > 0 AND PATINDEX('%*/%', batch) > PATINDEX('%/*%', batch);
			SET @i = @@ROWCOUNT;
			END;
			SET @i = 1;
			DECLARE @lf CHAR(2) = CHAR(13) + CHAR(10);
			WHILE @i > 1 BEGIN
			UPDATE #t SET batch = REPLACE(batch, @lf+@lf, @lf) WHERE PATINDEX('%' + @lf + @lf + '%', batch) > 0;
			SET @i = @@ROWCOUNT;
			END;
			WITH b AS (
			SELECT #t.*, CAST(spid AS VARCHAR(1000)) AS [level] 
			FROM #t 
			WHERE #t.blocked = 0 
			UNION ALL
			SELECT #t.*, CAST(b.[level] + '/' + CAST(#t.spid AS VARCHAR) AS VARCHAR(1000)) AS [level] 
			FROM #t 
			INNER JOIN b ON #t.blocked = b.spid WHERE #t.blocked > 0 AND #t.spid <> #t.blocked)
			SELECT [level], spid, LEFT(batch, 400) AS blockingtree, waittime, lastwaittype, waitresource, dbname, last_batch, hostname, [program_name], loginame 
			FROM b 
			UNION
			SELECT CAST(spid AS VARCHAR(1000)), spid, LEFT(batch, 400), waittime, lastwaittype, waitresource, dbname, last_batch, hostname, [program_name], loginame 
			FROM #t 
			WHERE #t.spid = #t.blocked;
			IF OBJECT_ID('tempdb..#t') IS NOT NULL DROP TABLE #t;
		END

	ELSE IF @x = '6' OR @x = 'VLF'
	   BEGIN
			IF OBJECT_ID('tempdb..#dbccLogInfo') IS NOT NULL DROP TABLE #dbccLogInfo;
			CREATE TABLE #dbccLogInfo (DatabaseId INT, RecoveryUnitId INT, FileId INT, FileSize BIGINT, StartOffset BIGINT, FSeqNo INT, [Status] INT, Parity INT, CreateLSN NVARCHAR(25));
 
			IF OBJECT_ID('tempdb..#dbFileInfo') IS NOT NULL DROP TABLE #dbFileInfo;
			CREATE TABLE #dbFileInfo (database_id INT, [file_id] INT, [name] NVARCHAR(128), size BIGINT, is_percent_growth BIT, growth BIGINT);
 
			DECLARE @version INT = CAST(LEFT(CAST(SERVERPROPERTY('productversion') AS VARCHAR), 2) AS INT);
 
			IF @version <= 10
			EXEC sp_MSforeachdb 'USE [?]; INSERT INTO #dbccLogInfo (FileId, FileSize, StartOffset, FSeqNo, [Status], Parity, CreateLSN) EXEC (''DBCC LOGINFO()''); UPDATE #dbccLogInfo SET DatabaseId = DB_ID() WHERE DatabaseId IS NULL;';
			ELSE
			EXEC sp_MSforeachdb 'USE [?]; INSERT INTO #dbccLogInfo (RecoveryUnitId, FileId, FileSize, StartOffset, FSeqNo, [Status], Parity, CreateLSN) EXEC (''DBCC LOGINFO()''); UPDATE #dbccLogInfo SET DatabaseId = DB_ID() WHERE DatabaseId IS NULL;';
 
			EXEC sp_MSforeachdb 'USE [?]; INSERT INTO #dbFileInfo SELECT DB_ID(), [file_id], [name], size, is_percent_growth, growth FROM sys.database_files WHERE [type_desc] = N''LOG''';
 
			WITH v AS (
			SELECT DatabaseId, FileId, COUNT(1) AS NumberOfVLFs, MIN(FileSize / 1048576) AS MinVLFSize, MAX(FileSize / 1048576) AS MaxVLFSize, AVG(FileSize / 1048576) AS AvgVLFSize
			FROM #dbccLogInfo
			GROUP BY DatabaseId, FileId),
			f AS (
			SELECT mf.database_id, mf.[file_id], DB_NAME(mf.database_id) AS DbName, mf.[name] AS LogFileName, mf.size / 128 AS FileSizeMB, CASE WHEN mf.is_percent_growth = 1 THEN mf.size * mf.growth / 12800 ELSE mf.growth / 128 END AS NextGrowthMB, v.NumberOfVLFs, v.MinVLFSize, v.MaxVLFSize, v.AvgVLFSize
			FROM #dbFileInfo mf
			LEFT JOIN v ON v.DatabaseId = mf.database_id AND v.FileId = mf.[file_id]),
			r AS (
			SELECT DatabaseId, FileId, COUNT(1) AS Reusable
			FROM #dbccLogInfo
			WHERE [Status] = 0
			GROUP BY DatabaseId, FileId)
			SELECT f.DbName as DatabaseName , f.LogFileName, f.FileSizeMB, f.NextGrowthMB, f.NumberOfVLFs--, ISNULL(r.Reusable, 0) AS NumberOfVLFsForReuse, CASE WHEN f.NextGrowthMB = 0 THEN 0 WHEN @version >= 12 AND f.FileSizeMB / f.NextGrowthMB > 8 THEN 1 WHEN f.NextGrowthMB > 1024 THEN 16 ELSE 8 END AS NewVLFsByAutogrowth, f.MinVLFSize, f.MaxVLFSize, f.AvgVLFSize, CASE WHEN f.FileSizeMB > 1024 THEN 16 ELSE 8 END AS MinNumberOfVLFs
			FROM f
			LEFT JOIN r ON r.DatabaseId = f.database_id AND r.FileId = f.[file_id]
			where f.DbName not in ('master','tempdb','model','msdb','SSISDB','Admin')
 
			IF OBJECT_ID('tempdb..#dbccLogInfo') IS NOT NULL DROP TABLE #dbccLogInfo;
			IF OBJECT_ID('tempdb..#dbFileInfo') IS NOT NULL DROP TABLE #dbFileInfo;
	  END
	
	ELSE IF @x = '7' OR @x = 'Missingindex'
	   BEGIN
		    SELECT TOP 10 db.[name] AS [DatabaseName]
			  ,id.[statement] AS [FullyQualifiedObjectName]
			,ISNULL(id.equality_columns,'') + ISNULL(id.inequality_columns,'') AS IndexColumn
			,[IncludeCloumns] = ISNULL(id.included_columns,'')
			--,gs.[avg_total_user_cost] AS [AvgTotalUserCost] 
			,gs.[avg_user_impact] AS [AvgUserImpact] 
			--,[Score] = ROUND((avg_total_user_cost * avg_user_impact) * (user_seeks + user_scans),0)
			--,[IndexAdvantage] = CONVERT(DECIMAL(18, 0) , (user_seeks + user_scans) * avg_total_user_cost *  avg_user_impact ) 
			,[TotalCost] = ROUND(avg_total_user_cost * avg_user_impact * (user_seeks + user_scans),0),
			 'CREATE INDEX [IX_' + OBJECT_NAME(id.[object_id], db.[database_id]) + '_' + REPLACE(REPLACE(REPLACE(ISNULL(id.[equality_columns], ''), ', ', '_'), '[', ''), ']', '') + CASE
				WHEN id.[equality_columns] IS NOT NULL
					AND id.[inequality_columns] IS NOT NULL
					THEN '_'
				ELSE ''
				END + REPLACE(REPLACE(REPLACE(ISNULL(id.[inequality_columns], ''), ', ', '_'), '[', ''), ']', '') + '_' + LEFT(CAST(NEWID() AS [nvarchar](64)), 5) + ']' + ' ON ' + id.[statement] + ' (' + ISNULL(id.[equality_columns], '') + CASE
				WHEN id.[equality_columns] IS NOT NULL
					AND id.[inequality_columns] IS NOT NULL
					THEN ','
				ELSE ''
				END + ISNULL(id.[inequality_columns], '') + ')' + ISNULL(' INCLUDE (' + id.[included_columns] + ')', '') AS [ProposedIndex]
			,CAST(CURRENT_TIMESTAMP AS [smalldatetime]) AS [CollectionDate]
			FROM [sys].[dm_db_missing_index_group_stats] gs WITH (NOLOCK)
			INNER JOIN [sys].[dm_db_missing_index_groups] ig WITH (NOLOCK) ON gs.[group_handle] = ig.[index_group_handle]
			INNER JOIN [sys].[dm_db_missing_index_details] id WITH (NOLOCK) ON ig.[index_handle] = id.[index_handle]
			INNER JOIN [sys].[databases] db WITH (NOLOCK) ON db.[database_id] = id.[database_id]
			WHERE ROUND(avg_total_user_cost * avg_user_impact * (user_seeks + user_scans), 0) > 10000 AND avg_user_impact > 70
			ORDER BY [TotalCost] DESC
	  END

	ELSE IF @x = '8' OR @x = 'Wait Type'
	   BEGIN
		-- Last updated Nov 15, 2023: SQLSkills
		WITH [Waits] AS
			(SELECT
				[wait_type],
				[wait_time_ms] / 1000.0 AS [WaitS],
				([wait_time_ms] - [signal_wait_time_ms]) / 1000.0 AS [ResourceS],
				[signal_wait_time_ms] / 1000.0 AS [SignalS],
				[waiting_tasks_count] AS [WaitCount],
				100.0 * [wait_time_ms] / SUM ([wait_time_ms]) OVER() AS [Percentage],
				ROW_NUMBER() OVER(ORDER BY [wait_time_ms] DESC) AS [RowNum]
			FROM sys.dm_os_wait_stats
			WHERE [wait_type] NOT IN (N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR',N'BROKER_TASK_STOP', N'BROKER_TO_FLUSH',N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',N'CHKPT', N'CLR_AUTO_EVENT',N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE',N'DBMIRROR_WORKER_QUEUE', N'DBMIRRORING_CMD',N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',N'EXECSYNC', N'FSAGENT',N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',N'HADR_LOGCAPTURE_WAIT', N'HADR_NOTIFICATION_DEQUEUE',N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP',N'LOGMGR_QUEUE', N'MEMORY_ALLOCATION_EXT',N'ONDEMAND_TASK_QUEUE',N'PREEMPTIVE_XE_GETTARGETSTATE',N'PWAIT_ALL_COMPONENTS_INITIALIZED',N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',N'QDS_SHUTDOWN_QUEUE', N'REDO_THREAD_PENDING_WORK',N'REQUEST_FOR_DEADLOCK_SEARCH', N'RESOURCE_QUEUE',N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH',N'SLEEP_DBSTARTUP', N'SLEEP_DCOMSTARTUP',N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP',N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT',N'SP_SERVER_DIAGNOSTICS_SLEEP', N'SQLTRACE_BUFFER_FLUSH',N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',N'SQLTRACE_WAIT_ENTRIES', N'WAIT_FOR_RESULTS',N'WAITFOR', N'WAITFOR_TASKSHUTDOWN',N'WAIT_XTP_RECOVERY',N'WAIT_XTP_HOST_WAIT', N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',N'WAIT_XTP_CKPT_CLOSE', N'XE_DISPATCHER_JOIN',N'XE_DISPATCHER_WAIT', N'XE_TIMER_EVENT')

			--WHERE [wait_type] NOT IN (
			--    -- These wait types are almost 100% never a problem and so they are
			--    -- filtered out to avoid them skewing the results. Click on the URL
			--    -- for more information.
			--    N'BROKER_EVENTHANDLER', -- https://www.sqlskills.com/help/waits/BROKER_EVENTHANDLER
			--    N'BROKER_RECEIVE_WAITFOR', -- https://www.sqlskills.com/help/waits/BROKER_RECEIVE_WAITFOR
			--    N'BROKER_TASK_STOP', -- https://www.sqlskills.com/help/waits/BROKER_TASK_STOP
			--    N'BROKER_TO_FLUSH', -- https://www.sqlskills.com/help/waits/BROKER_TO_FLUSH
			--    N'BROKER_TRANSMITTER', -- https://www.sqlskills.com/help/waits/BROKER_TRANSMITTER
			--    N'CHECKPOINT_QUEUE', -- https://www.sqlskills.com/help/waits/CHECKPOINT_QUEUE
			--    N'CHKPT', -- https://www.sqlskills.com/help/waits/CHKPT
			--    N'CLR_AUTO_EVENT', -- https://www.sqlskills.com/help/waits/CLR_AUTO_EVENT
			--    N'CLR_MANUAL_EVENT', -- https://www.sqlskills.com/help/waits/CLR_MANUAL_EVENT
			--    N'CLR_SEMAPHORE', -- https://www.sqlskills.com/help/waits/CLR_SEMAPHORE
			--    N'CXCONSUMER', -- https://www.sqlskills.com/help/waits/CXCONSUMER
 
			--    -- Maybe comment these four out if you have mirroring issues
			--    N'DBMIRROR_DBM_EVENT', -- https://www.sqlskills.com/help/waits/DBMIRROR_DBM_EVENT
			--    N'DBMIRROR_EVENTS_QUEUE', -- https://www.sqlskills.com/help/waits/DBMIRROR_EVENTS_QUEUE
			--    N'DBMIRROR_WORKER_QUEUE', -- https://www.sqlskills.com/help/waits/DBMIRROR_WORKER_QUEUE
			--    N'DBMIRRORING_CMD', -- https://www.sqlskills.com/help/waits/DBMIRRORING_CMD
 
			--    N'DIRTY_PAGE_POLL', -- https://www.sqlskills.com/help/waits/DIRTY_PAGE_POLL
			--    N'DISPATCHER_QUEUE_SEMAPHORE', -- https://www.sqlskills.com/help/waits/DISPATCHER_QUEUE_SEMAPHORE
			--    N'EXECSYNC', -- https://www.sqlskills.com/help/waits/EXECSYNC
			--    N'FSAGENT', -- https://www.sqlskills.com/help/waits/FSAGENT
			--    N'FT_IFTS_SCHEDULER_IDLE_WAIT', -- https://www.sqlskills.com/help/waits/FT_IFTS_SCHEDULER_IDLE_WAIT
			--    N'FT_IFTSHC_MUTEX', -- https://www.sqlskills.com/help/waits/FT_IFTSHC_MUTEX
 
			--    -- Maybe comment these six out if you have AG issues
			--    N'HADR_CLUSAPI_CALL', -- https://www.sqlskills.com/help/waits/HADR_CLUSAPI_CALL
			--    N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', -- https://www.sqlskills.com/help/waits/HADR_FILESTREAM_IOMGR_IOCOMPLETION
			--    N'HADR_LOGCAPTURE_WAIT', -- https://www.sqlskills.com/help/waits/HADR_LOGCAPTURE_WAIT
			--    N'HADR_NOTIFICATION_DEQUEUE', -- https://www.sqlskills.com/help/waits/HADR_NOTIFICATION_DEQUEUE
			--    N'HADR_TIMER_TASK', -- https://www.sqlskills.com/help/waits/HADR_TIMER_TASK
			--    N'HADR_WORK_QUEUE', -- https://www.sqlskills.com/help/waits/HADR_WORK_QUEUE
 
			--    N'KSOURCE_WAKEUP', -- https://www.sqlskills.com/help/waits/KSOURCE_WAKEUP
			--    N'LAZYWRITER_SLEEP', -- https://www.sqlskills.com/help/waits/LAZYWRITER_SLEEP
			--    N'LOGMGR_QUEUE', -- https://www.sqlskills.com/help/waits/LOGMGR_QUEUE
			--    N'MEMORY_ALLOCATION_EXT', -- https://www.sqlskills.com/help/waits/MEMORY_ALLOCATION_EXT
			--    N'ONDEMAND_TASK_QUEUE', -- https://www.sqlskills.com/help/waits/ONDEMAND_TASK_QUEUE
			--    N'PARALLEL_REDO_DRAIN_WORKER', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_DRAIN_WORKER
			--    N'PARALLEL_REDO_LOG_CACHE', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_LOG_CACHE
			--    N'PARALLEL_REDO_TRAN_LIST', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_TRAN_LIST
			--    N'PARALLEL_REDO_WORKER_SYNC', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_WORKER_SYNC
			--    N'PARALLEL_REDO_WORKER_WAIT_WORK', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_WORKER_WAIT_WORK
			--    N'PREEMPTIVE_OS_FLUSHFILEBUFFERS', -- https://www.sqlskills.com/help/waits/PREEMPTIVE_OS_FLUSHFILEBUFFERS 
			--    N'PREEMPTIVE_XE_GETTARGETSTATE', -- https://www.sqlskills.com/help/waits/PREEMPTIVE_XE_GETTARGETSTATE
			--    N'PWAIT_ALL_COMPONENTS_INITIALIZED', -- https://www.sqlskills.com/help/waits/PWAIT_ALL_COMPONENTS_INITIALIZED
			--    N'PWAIT_DIRECTLOGCONSUMER_GETNEXT', -- https://www.sqlskills.com/help/waits/PWAIT_DIRECTLOGCONSUMER_GETNEXT
			--    N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', -- https://www.sqlskills.com/help/waits/QDS_PERSIST_TASK_MAIN_LOOP_SLEEP
			--    N'QDS_ASYNC_QUEUE', -- https://www.sqlskills.com/help/waits/QDS_ASYNC_QUEUE
			--    N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
			--        -- https://www.sqlskills.com/help/waits/QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP
			--    N'QDS_SHUTDOWN_QUEUE', -- https://www.sqlskills.com/help/waits/QDS_SHUTDOWN_QUEUE
			--    N'REDO_THREAD_PENDING_WORK', -- https://www.sqlskills.com/help/waits/REDO_THREAD_PENDING_WORK
			--    N'REQUEST_FOR_DEADLOCK_SEARCH', -- https://www.sqlskills.com/help/waits/REQUEST_FOR_DEADLOCK_SEARCH
			--    N'RESOURCE_QUEUE', -- https://www.sqlskills.com/help/waits/RESOURCE_QUEUE
			--    N'SERVER_IDLE_CHECK', -- https://www.sqlskills.com/help/waits/SERVER_IDLE_CHECK
			--    N'SLEEP_BPOOL_FLUSH', -- https://www.sqlskills.com/help/waits/SLEEP_BPOOL_FLUSH
			--    N'SLEEP_DBSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_DBSTARTUP
			--    N'SLEEP_DCOMSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_DCOMSTARTUP
			--    N'SLEEP_MASTERDBREADY', -- https://www.sqlskills.com/help/waits/SLEEP_MASTERDBREADY
			--    N'SLEEP_MASTERMDREADY', -- https://www.sqlskills.com/help/waits/SLEEP_MASTERMDREADY
			--    N'SLEEP_MASTERUPGRADED', -- https://www.sqlskills.com/help/waits/SLEEP_MASTERUPGRADED
			--    N'SLEEP_MSDBSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_MSDBSTARTUP
			--    N'SLEEP_SYSTEMTASK', -- https://www.sqlskills.com/help/waits/SLEEP_SYSTEMTASK
			--    N'SLEEP_TASK', -- https://www.sqlskills.com/help/waits/SLEEP_TASK
			--    N'SLEEP_TEMPDBSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_TEMPDBSTARTUP
			--    N'SNI_HTTP_ACCEPT', -- https://www.sqlskills.com/help/waits/SNI_HTTP_ACCEPT
			--    N'SOS_WORK_DISPATCHER', -- https://www.sqlskills.com/help/waits/SOS_WORK_DISPATCHER
			--    N'SP_SERVER_DIAGNOSTICS_SLEEP', -- https://www.sqlskills.com/help/waits/SP_SERVER_DIAGNOSTICS_SLEEP
			--    N'SQLTRACE_BUFFER_FLUSH', -- https://www.sqlskills.com/help/waits/SQLTRACE_BUFFER_FLUSH
			--    N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', -- https://www.sqlskills.com/help/waits/SQLTRACE_INCREMENTAL_FLUSH_SLEEP
			--    N'SQLTRACE_WAIT_ENTRIES', -- https://www.sqlskills.com/help/waits/SQLTRACE_WAIT_ENTRIES
			--    N'VDI_CLIENT_OTHER', -- https://www.sqlskills.com/help/waits/VDI_CLIENT_OTHER
			--    N'WAIT_FOR_RESULTS', -- https://www.sqlskills.com/help/waits/WAIT_FOR_RESULTS
			--    N'WAITFOR', -- https://www.sqlskills.com/help/waits/WAITFOR
			--    N'WAITFOR_TASKSHUTDOWN', -- https://www.sqlskills.com/help/waits/WAITFOR_TASKSHUTDOWN
			--    N'WAIT_XTP_RECOVERY', -- https://www.sqlskills.com/help/waits/WAIT_XTP_RECOVERY
			--    N'WAIT_XTP_HOST_WAIT', -- https://www.sqlskills.com/help/waits/WAIT_XTP_HOST_WAIT
			--    N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', -- https://www.sqlskills.com/help/waits/WAIT_XTP_OFFLINE_CKPT_NEW_LOG
			--    N'WAIT_XTP_CKPT_CLOSE', -- https://www.sqlskills.com/help/waits/WAIT_XTP_CKPT_CLOSE
			--    N'XE_DISPATCHER_JOIN', -- https://www.sqlskills.com/help/waits/XE_DISPATCHER_JOIN
			--    N'XE_DISPATCHER_WAIT', -- https://www.sqlskills.com/help/waits/XE_DISPATCHER_WAIT
			--    N'XE_TIMER_EVENT' -- https://www.sqlskills.com/help/waits/XE_TIMER_EVENT
			--    )
			AND [waiting_tasks_count] > 0
			)
		SELECT Top 10
			MAX ([W1].[wait_type]) AS [WaitType],
			CAST (MAX ([W1].[Percentage]) AS DECIMAL (5,2)) AS [Percentage],
			MAX ([W1].[WaitCount]) AS [WaitCount],
			CAST (MAX ([W1].[WaitS]) AS DECIMAL (16,2)) AS [Wait_Sec],
			--CAST (MAX ([W1].[ResourceS]) AS DECIMAL (16,2)) AS [Resource_S],
			--CAST (MAX ([W1].[SignalS]) AS DECIMAL (16,2)) AS [Signal_S],
    
			CAST ((MAX ([W1].[WaitS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgWait_Sec],
			--CAST ((MAX ([W1].[ResourceS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgRes_S],
			--CAST ((MAX ([W1].[SignalS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgSig_S],
			CAST ('https://www.sqlskills.com/help/waits/' + MAX ([W1].[wait_type]) as XML) AS [Help/Info URL]
		FROM [Waits] AS [W1]
		INNER JOIN [Waits] AS [W2] ON [W2].[RowNum] <= [W1].[RowNum]
		GROUP BY [W1].[RowNum]
		HAVING SUM ([W2].[Percentage]) - MAX( [W1].[Percentage] ) < 99; -- percentage threshold
	END 
	
	ELSE IF @x = '9' OR @x = 'Update_stat'
		BEGIN
	        --Exec Admin.dbo.DBA_UPDATE_STAT_CHECK
		DECLARE @SQLStatement NVARCHAR(4000),  @name NVARCHAR(4000), @sqlmajorver int, @sqlminorver int, @sqlbuild int
		SELECT @sqlmajorver = CONVERT(int, (@@microsoftversion / 0x1000000) & 0xff);
		SELECT @sqlminorver = CONVERT(int, (@@microsoftversion / 0x10000) & 0xff);
		SELECT @sqlbuild = CONVERT(int, @@microsoftversion & 0xffff);

			DECLARE backup_cursor CURSOR FOR  
			SELECT name FROM master.sys.databases
			WHERE  name not in ('master','model','msdb','SSISDB','Admin','tempdb')
						AND [state] = 0 
						AND [is_read_only] = 0
						AND [source_database_id] IS NULL
  			BEGIN
				OPEN backup_cursor   
				FETCH NEXT FROM backup_cursor INTO @name  
				WHILE @@FETCH_STATUS=0
				BEGIN 
					IF (@sqlmajorver = 10 AND @sqlminorver = 50 AND @sqlbuild >= 4000) OR (@sqlmajorver = 11 AND @sqlbuild >= 3000) OR @sqlmajorver > 11
					BEGIN
						SET @SQLStatement = 'USE ' + @name + ';
						SELECT DISTINCT ''' + @name + ''' AS [DatabaseName], t.name AS schemaName, OBJECT_NAME(mst.[object_id]) AS tableName, ss.name AS [stat_name], ISNULL(sp.[rows],SUM(p.[rows])) AS [rows], sp.modification_counter, STATS_DATE(o.[object_id], ss.[stats_id]) AS [stats_date]
						FROM sys.stats AS ss 
							  INNER JOIN sys.objects AS o ON o.[object_id] = ss.[object_id]
							  INNER JOIN sys.tables AS mst ON mst.[object_id] = o.[object_id]
							  INNER JOIN sys.schemas AS t ON t.[schema_id] = mst.[schema_id]
							  INNER JOIN sys.partitions AS p ON p.[object_id] = ss.[object_id]
							  CROSS APPLY sys.dm_db_stats_properties(ss.[object_id], ss.[stats_id]) AS sp
						GROUP BY o.[object_id], mst.[object_id], t.name, ss.stats_id, ss.name, sp.[rows], sp.modification_counter
						ORDER BY t.name, OBJECT_NAME(mst.[object_id]), ss.name';
					END
				ELSE
					BEGIN
					SET @SQLStatement = 'USE ' + @name + ';
						SELECT DISTINCT ''' + @name + ''' ASAS [databaseID], mst.[object_id] AS objectID, ss.[stats_id], ''' + DB_NAME() + ''' AS [DatabaseName], t.name AS schemaName, OBJECT_NAME(mst.[object_id]) AS tableName, ss.name AS [stat_name], SUM(p.[rows]) AS [rows], rowmodctr AS modification_counter, STATS_DATE(o.[object_id], ss.[stats_id]) AS [stats_date]
					FROM sys.stats AS ss
						  INNER JOIN sys.sysindexes AS si ON si.id = ss.[object_id]
						  INNER JOIN sys.objects AS o ON o.[object_id] = si.id
						  INNER JOIN sys.tables AS mst ON mst.[object_id] = o.[object_id]
						  INNER JOIN sys.schemas AS t ON t.[schema_id] = mst.[schema_id]
						  INNER JOIN sys.partitions AS p ON p.[object_id] = ss.[object_id]
						  LEFT JOIN sys.indexes i ON si.id = i.[object_id] AND si.indid = i.index_id
					WHERE o.type <> ''S'' AND i.name IS NOT NULL
					GROUP BY o.[object_id], mst.[object_id], t.name, rowmodctr, ss.stats_id, ss.name
					ORDER BY t.name, OBJECT_NAME(mst.[object_id]), ss.name'
					END
				  EXEC (@SQLStatement)
				  --PRINT @SQLStatement

			FETCH NEXT FROM backup_cursor INTO @name   
		END 
		END
		CLOSE backup_cursor
		DEALLOCATE backup_cursor
	  END
	ELSE IF @x = '0' OR @x = 'help'
		BEGIN
			DECLARE @text NVARCHAR(4000);
			DECLARE @NewLineChar AS CHAR(2) = CHAR(13) + CHAR(10);
			SET @text = N'Synopsis:' + @NewLineChar +
						N'Who is currently running on my system?'  + @NewLineChar +
						N'-------------------------------------------------------------------------------------------------------------------------------------'  + @NewLineChar +
						N'Description:'  + @NewLineChar +
						N'The first area to look at on a system running SQL Server is the utilization of hardware resources, the core of which are memory,' + @NewLineChar +
						N'storage, CPU and long blockings. Use sp_who3 to first view the current system load and to identify a session of interest.' + @NewLineChar +
						N'-------------------------------------------------------------------------------------------------------------------------------------' + @NewLineChar +
						N'Parameters:'  + @NewLineChar +
						N'sp_who3 		                   - who is active;' + @NewLineChar +
						N'sp_who3 1 or ''memory''  	            - who is requesting more memory (top 10);' + @NewLineChar +
						N'sp_who3 2 or ''cpu cached queries''   - who has cached plans that consumed the most cumulative CPU (top 10);'+ @NewLineChar +
						N'sp_who3 21 or ''cpu high current''    - High cpu consuming queries currently running (top 10);' + @NewLineChar +
						N'sp_who3 3 or ''count''  	            - who is connected and how many sessions it has by login and host name;'+ @NewLineChar +
						N'sp_who3 4 or ''all connection'' 	    - who connected -all connection where SPID >50 and login <> sa;'+ @NewLineChar +
						N'sp_who3 5 or ''block'' 	            - who is blocking-shows blocking tree;'+ @NewLineChar +
						N'sp_who3 6 or ''VLF'' 	                - Find number of VLM per database;'+ @NewLineChar +
						N'sp_who3 7 or ''MissingIndex'' 	    - Find top 10 missing index;'+ @NewLineChar +
						N'sp_who3 8 or ''Wait type'' 	        - Find top 10 Wait type;'+ @NewLineChar +
						N'sp_who3 9 or ''Update_stat'' 	        - Check Update Stat in each Data Base.'

			PRINT @text;
		END
	
END;






