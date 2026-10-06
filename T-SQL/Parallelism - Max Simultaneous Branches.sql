/* Parallelism - How Many Branches Can One SELECT Run at Once?

A parallel plan is split into branches (zones between Parallelism operators),
and SQL Server reserves DOP worker threads for every branch that can run at
the same time. This demo builds one SELECT that keeps as many branches
running simultaneously as the server will allow.

Uses the Stack Overflow database, documented hints only, no server changes.

The trick is the shape of the plan:

* Row mode, not batch mode. In batch mode, hash joins share one hash table
  across threads and don't need exchanges at all, so the whole plan collapses
  into one branch. USE HINT('DISALLOW_BATCH_MODE') prevents that.

* Hash joins whose builds are single tables and whose probes are the rest of
  the chain. A hash join's build branch has to finish before its probe starts,
  so builds never overlap each other. Once every build is done, though, the
  rows from u1 stream up through every join at once.

* Every join uses a different hash key (u2.Id = u1.Id + 1, u3.Id = u2.Id + 1,
  and so on), so the probe stream has to be repartitioned again above every
  join. Each repartition starts a new branch, and they all run concurrently.

* OPTIMIZE FOR tells the optimizer every table returns all 9M Users, so it
  goes parallel, but at runtime @x = 2 means each table returns a row or two.
  That's why the query finishes in seconds instead of minutes.
*/
USE StackOverflow;
GO


/* Start small: 10 tables. Turn on the actual execution plan (Ctrl-M), run
this, and look at the SELECT operator's properties: Thread Stat shows
Branches = 10, UsedThreads = 40 at DOP 4. */
DECLARE @x INT = 2;
SELECT MAX(u1.Reputation) + MAX(u2.Reputation) + MAX(u3.Reputation) + MAX(u4.Reputation) + MAX(u5.Reputation)
     + MAX(u6.Reputation) + MAX(u7.Reputation) + MAX(u8.Reputation) + MAX(u9.Reputation) + MAX(u10.Reputation)
FROM dbo.Users u10
INNER JOIN (dbo.Users u9
    INNER JOIN (dbo.Users u8
        INNER JOIN (dbo.Users u7
            INNER JOIN (dbo.Users u6
                INNER JOIN (dbo.Users u5
                    INNER JOIN (dbo.Users u4
                        INNER JOIN (dbo.Users u3
                            INNER JOIN (dbo.Users u2
                                INNER JOIN dbo.Users u1 ON u2.Id = u1.Id + 1)
                            ON u3.Id = u2.Id + 1)
                        ON u4.Id = u3.Id + 1)
                    ON u5.Id = u4.Id + 1)
                ON u6.Id = u5.Id + 1)
            ON u7.Id = u6.Id + 1)
        ON u8.Id = u7.Id + 1)
    ON u9.Id = u8.Id + 1)
ON u10.Id = u9.Id + 1
WHERE u1.Id < @x AND u2.Id < @x AND u3.Id < @x AND u4.Id < @x AND u5.Id < @x
  AND u6.Id < @x AND u7.Id < @x AND u8.Id < @x AND u9.Id < @x AND u10.Id < @x
OPTION (USE HINT('DISALLOW_BATCH_MODE'), HASH JOIN, FORCE ORDER, OPTIMIZE FOR (@x = 2147483647));
GO


/* Now go big. Typing out dozens of nested joins gets old, so this builds the
same query for any number of tables. Each table adds one concurrent branch.

57 is the max on a 4-core SQL Server 2025 box with max worker threads at the
default 512: 57 branches x DOP 4 = 228 reserved threads. At 58 tables, the
optimizer silently produces a serial plan instead - no NonParallelPlanReason.
The cutoff was 57 at MAXDOP 2 too, and that box had 283 workers already
allocated (mostly idle pooled ones), leaving 512 - 283 = 229 free. */
DECLARE @Tables INT = 57;

DECLARE @i INT = 2,
    @Select NVARCHAR(MAX) = N'MAX(u1.Reputation)',
    @From NVARCHAR(MAX) = N'dbo.Users u1',
    @Where NVARCHAR(MAX) = N'u1.Id < @x',
    @StringToExecute NVARCHAR(MAX);

WHILE @i <= @Tables
    BEGIN
    SET @Select += N' + MAX(u' + CAST(@i AS NVARCHAR(10)) + N'.Reputation)';
    SET @From = N'dbo.Users u' + CAST(@i AS NVARCHAR(10)) + N' INNER JOIN '
        + CASE WHEN @i > 2 THEN N'(' + @From + N')' ELSE @From END
        + N' ON u' + CAST(@i AS NVARCHAR(10)) + N'.Id = u' + CAST(@i - 1 AS NVARCHAR(10)) + N'.Id + 1'
        + NCHAR(13) + NCHAR(10);
    SET @Where += N' AND u' + CAST(@i AS NVARCHAR(10)) + N'.Id < @x';
    SET @i += 1;
    END;

SET @StringToExecute = N'/* MaxBranchesDemo */ DECLARE @x INT = 2;' + NCHAR(13) + NCHAR(10)
    + N'SELECT ' + @Select + NCHAR(13) + NCHAR(10)
    + N'FROM ' + @From
    + N'WHERE ' + @Where + NCHAR(13) + NCHAR(10)
    + N'OPTION (USE HINT(''DISALLOW_BATCH_MODE''), HASH JOIN, FORCE ORDER, OPTIMIZE FOR (@x = 2147483647));';

EXEC sp_executesql @StringToExecute;
GO


/* How many threads did it actually reserve and use? */
SELECT TOP 1 qs.last_dop, qs.last_reserved_threads, qs.last_used_threads,
    qs.last_reserved_threads / NULLIF(qs.last_dop, 0) AS concurrent_branches,
    qs.last_execution_time
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE st.text LIKE N'/* MaxBranchesDemo */%'
ORDER BY qs.last_execution_time DESC;
GO


/* To do on a bigger box: is the ceiling really free workers?

1. Check how many workers are already allocated:
   SELECT max_workers_count FROM sys.dm_os_sys_info;
   SELECT SUM(current_workers_count) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE';
2. Raise @Tables until the plan goes serial, and see whether the last parallel
   count x DOP lands just under max_workers_count - current workers.
3. Let the server sit idle 15+ minutes so idle workers get trimmed, then
   repeat. If the ceiling rises, the limit is free workers, not branches.
4. Repeat at different core counts. Max worker threads, and so the ceiling,
   scales with cores.
*/
