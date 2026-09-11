/* ==========================================================================
   Extended Events: track access to accontrl, qccontrl2, ldm
   - In-memory ring_buffer target (subject to eviction under memory pressure
     or once it hits max_memory - by design, this is expected)
   - Permanent table + stored proc to flush new events out of the ring buffer
   - SQL Agent job to run the flush on a schedule so nothing is lost between
     eviction cycles
   ========================================================================== */

/* --------------------------------------------------------------------------
   1. CREATE THE EVENT SESSION
   -------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'Track_DB_Access')
    DROP EVENT SESSION [Track_DB_Access] ON SERVER;
GO

CREATE EVENT SESSION [Track_DB_Access] ON SERVER
ADD EVENT sqlserver.sql_batch_completed
(
    ACTION (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    WHERE (
        sqlserver.database_name = N'accontrl'
        OR sqlserver.database_name = N'qccontrl2'
        OR sqlserver.database_name = N'ldm'
    )
),
ADD EVENT sqlserver.rpc_completed
(
    ACTION (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id,
        sqlserver.sql_text
    )
    WHERE (
        sqlserver.database_name = N'accontrl'
        OR sqlserver.database_name = N'qccontrl2'
        OR sqlserver.database_name = N'ldm'
    )
),
ADD EVENT sqlserver.login
(
    ACTION (
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_name,
        sqlserver.server_principal_name,
        sqlserver.session_id
    )
    -- login fires with the connecting/default database; filter is best-effort here
    WHERE (
        sqlserver.database_name = N'accontrl'
        OR sqlserver.database_name = N'qccontrl2'
        OR sqlserver.database_name = N'ldm'
    )
)
ADD TARGET package0.ring_buffer(SET max_memory = 51200)  -- 50 MB; raise if busy
WITH (
    MAX_MEMORY = 8192 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 15 SECONDS,
    TRACK_CAUSALITY = ON,
    STARTUP_STATE = ON     -- auto-restarts session after a SQL Server restart
);
GO

ALTER EVENT SESSION [Track_DB_Access] ON SERVER STATE = START;
GO

/* --------------------------------------------------------------------------
   2. PERMANENT LOG TABLE  (pick / create a home DB for this - e.g. a small
      "DBAUtility" or "master"-adjacent admin DB; do NOT put it in one of the
      3 monitored databases if you want it independent of their backups)
   -------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DBAccessLog') IS NULL
BEGIN
    CREATE TABLE dbo.DBAccessLog
    (
        LogID             BIGINT IDENTITY(1,1) PRIMARY KEY,
        EventName         SYSNAME         NOT NULL,
        EventTimeUTC      DATETIME2(3)    NOT NULL,
        EventTimeCentral  DATETIME2(3)    NOT NULL,
        DatabaseName      SYSNAME         NULL,
        LoginName         SYSNAME         NULL,
        ClientAppName     NVARCHAR(128)   NULL,
        ClientHostName    NVARCHAR(128)   NULL,
        SessionID         INT             NULL,
        SqlText           NVARCHAR(MAX)   NULL,
        Duration_ms       BIGINT          NULL,
        CapturedAt        DATETIME2(3)    NOT NULL DEFAULT SYSDATETIME()
    );

    CREATE INDEX IX_DBAccessLog_EventTimeUTC ON dbo.DBAccessLog (EventTimeUTC);
    CREATE INDEX IX_DBAccessLog_DatabaseName  ON dbo.DBAccessLog (DatabaseName);
END
GO

/* --------------------------------------------------------------------------
   3. FLUSH PROC - shreds the ring buffer, inserts only events newer than
      the last one already captured (avoids duplicates on repeated runs)
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_FlushXEDBAccessLog
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LastTimeUTC DATETIME2(3) =
        ISNULL((SELECT MAX(EventTimeUTC) FROM dbo.DBAccessLog), '19000101');

    ;WITH XEData AS
    (
        SELECT CAST(st.target_data AS XML) AS TargetXML
        FROM sys.dm_xe_session_targets st
        JOIN sys.dm_xe_sessions s
            ON s.address = st.event_session_address
        WHERE s.name = 'Track_DB_Access'
          AND st.target_name = 'ring_buffer'
    ),
    Events AS
    (
        SELECT
            EventNode.value('@name', 'sysname')                                           AS EventName,
            EventNode.value('@timestamp', 'datetimeoffset(3)')                             AS EventTimeUTCOffset,
            EventNode.value('(action[@name="database_name"]/value)[1]', 'sysname')         AS DatabaseName,
            EventNode.value('(action[@name="server_principal_name"]/value)[1]', 'sysname') AS LoginName,
            EventNode.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(128)') AS ClientAppName,
            EventNode.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(128)') AS ClientHostName,
            EventNode.value('(action[@name="session_id"]/value)[1]', 'int')                AS SessionID,
            EventNode.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')        AS SqlText,
            EventNode.value('(data[@name="duration"]/value)[1]', 'bigint')                 AS Duration_ms
        FROM XEData
        CROSS APPLY TargetXML.nodes('/RingBufferTarget/event') AS T(EventNode)
    ),
    Shaped AS
    (
        SELECT
            EventName,
            CAST(SWITCHOFFSET(EventTimeUTCOffset, '+00:00') AS DATETIME2(3))            AS EventTimeUTC,
            CAST(EventTimeUTCOffset AT TIME ZONE 'Central Standard Time' AS DATETIME2(3)) AS EventTimeCentral,
            DatabaseName,
            LoginName,
            ClientAppName,
            ClientHostName,
            SessionID,
            SqlText,
            Duration_ms
        FROM Events
    )
    INSERT INTO dbo.DBAccessLog
        (EventName, EventTimeUTC, EventTimeCentral, DatabaseName, LoginName,
         ClientAppName, ClientHostName, SessionID, SqlText, Duration_ms)
    SELECT
        EventName, EventTimeUTC, EventTimeCentral, DatabaseName, LoginName,
        ClientAppName, ClientHostName, SessionID, SqlText, Duration_ms
    FROM Shaped
    WHERE EventTimeUTC > @LastTimeUTC
    ORDER BY EventTimeUTC;
END
GO

/* --------------------------------------------------------------------------
   4. SQL AGENT JOB - runs the flush every 5 minutes
      (adjust @freq_subday_interval and ring buffer max_memory together:
       busier systems need either a shorter interval or a bigger buffer)
   -------------------------------------------------------------------------- */
USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'Flush XE DB Access Log')
    EXEC msdb.dbo.sp_delete_job @job_name = N'Flush XE DB Access Log';
GO

EXEC msdb.dbo.sp_add_job
    @job_name = N'Flush XE DB Access Log',
    @enabled = 1,
    @description = N'Flushes Track_DB_Access ring_buffer events into dbo.DBAccessLog before they age out of memory.';

-- >>> change @database_name below to whichever DB hosts dbo.DBAccessLog / the proc
EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'Flush XE DB Access Log',
    @step_name = N'Flush ring buffer',
    @subsystem = N'TSQL',
    @database_name = N'master',   -- <-- set to your admin/utility DB
    @command = N'EXEC dbo.usp_FlushXEDBAccessLog;',
    @on_success_action = 1,
    @on_fail_action = 2;

EXEC msdb.dbo.sp_add_schedule
    @schedule_name = N'Every5Min',
    @freq_type = 4,                  -- daily
    @freq_interval = 1,
    @freq_subday_type = 4,           -- minutes
    @freq_subday_interval = 5,
    @active_start_time = 000000;

EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'Flush XE DB Access Log',
    @schedule_name = N'Every5Min';

EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'Flush XE DB Access Log',
    @server_name = N'(local)';
GO

/* --------------------------------------------------------------------------
   5. HANDY QUERIES ONCE DATA IS FLOWING
   -------------------------------------------------------------------------- */
-- Who's hitting which DB, from what, in the last day:
-- SELECT DatabaseName, LoginName, ClientAppName, ClientHostName, COUNT(*) AS Hits,
--        MIN(EventTimeCentral) AS FirstSeen, MAX(EventTimeCentral) AS LastSeen
-- FROM dbo.DBAccessLog
-- WHERE EventTimeCentral >= DATEADD(DAY, -1, SYSDATETIME())
-- GROUP BY DatabaseName, LoginName, ClientAppName, ClientHostName
-- ORDER BY Hits DESC;

-- Raw feed, most recent first:
-- SELECT TOP 200 * FROM dbo.DBAccessLog ORDER BY EventTimeUTC DESC;
