/* If you want to drive the configuration from a table, insert a row into this: */
IF NOT EXISTS(SELECT * FROM sys.all_objects WHERE name = 'sp_SendStartupEmail_Config')
	BEGIN
	CREATE TABLE dbo.sp_SendStartupEmail_Config
		(DatabaseMailProfileName SYSNAME, Recipients VARCHAR(MAX));
	END
GO



IF OBJECT_ID('dbo.sp_SendStartupEmail') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_SendStartupEmail AS RETURN 0;');
GO

ALTER PROC dbo.sp_SendStartupEmail AS
BEGIN
/* More info: https://www.BrentOzar.com/go/startupmail
Contributors from the live stream: JediMindGorilla, GSerdjinn, WetSeal, RenegadeLarsen
*/
DECLARE @DatabaseMailProfileName SYSNAME = NULL, 
	@Recipients VARCHAR(MAX) = NULL,
	@StringToExecute NVARCHAR(4000);


/* If the config table exists, get recipients & valid email profile */
IF EXISTS (SELECT * FROM sys.all_objects WHERE name = 'sp_SendStartupEmail_Config')
	BEGIN
	SET @StringToExecute = N'SELECT TOP 1 @DatabaseMailProfileName_Table = DatabaseMailProfileName, @Recipients_Table = Recipients 
		FROM dbo.sp_SendStartupEmail_Config mc
		INNER JOIN msdb.dbo.sysmail_profile p ON mc.DatabaseMailProfileName = p.name;'
	EXEC sp_executesql @StringToExecute, N'@DatabaseMailProfileName_Table SYSNAME OUTPUT, @Recipients_Table VARCHAR(MAX) OUTPUT',
		@DatabaseMailProfileName_Table = @DatabaseMailProfileName OUTPUT, @Recipients_Table = @Recipients OUTPUT;
	END

IF @DatabaseMailProfileName IS NULL AND 1 = (SELECT COUNT(*) FROM msdb.dbo.sysmail_profile)
	SELECT TOP 1 @DatabaseMailProfileName = name
	FROM msdb.dbo.sysmail_profile;

/* If they didn't specify a recipient, use the last operator that got an email */
IF @Recipients IS NULL
	SELECT TOP (1) @Recipients = email_address 
	FROM msdb.dbo.sysoperators o 
	WHERE o.[enabled] = 1 ORDER BY o.last_email_date DESC;

IF @DatabaseMailProfileName IS NULL OR @Recipients IS NULL 
	RETURN;

DECLARE @email_subject NVARCHAR(255) = N'SQL Server Started: ' + COALESCE(@@SERVERNAME, N'Unknown Server Name'),
	@email_body NVARCHAR(MAX);

IF NOT EXISTS (SELECT * FROM sys.databases WHERE state NOT IN (0, 1, 7, 10))
	SET @email_body = N'All databases okay.';
ELSE
	BEGIN
	SELECT @email_body = CONCAT(@email_body, COALESCE(name, N' Database ID ' + CAST(database_id AS NVARCHAR(10))), N' state: ' + state_desc + NCHAR(13) + NCHAR(10)) 
		FROM sys.databases
		WHERE state NOT IN (0, 1, 7, 10);

	IF @email_body IS NULL
		SET @email_body = N'We couldn''t get a list of databases with problems. Better check on this server manually.';
	END


EXEC msdb.dbo.sp_send_dbmail  
    @profile_name = @DatabaseMailProfileName,  
    @recipients = @Recipients,  
    @body = @email_body,  
    @subject = @email_subject ;

END
GO



/* Mark this stored procedure as a startup stored procedure: */
EXEC sp_procoption @ProcName = N'sp_SendStartupEmail',
	@OptionName = 'startup',
	@OptionValue = 'on';
GO

IF 0 = (SELECT value_in_use FROM sys.configurations WHERE name = 'scan for startup procs')
	AND 0 = (SELECT value FROM sys.configurations WHERE name = 'scan for startup procs')
	BEGIN

	PRINT '/* WARNING! Startup stored procs not enabled. Run this to enable: */';
	PRINT 'EXEC sp_configure ''scan for startup procs'', 1;'
	PRINT 'RECONFIGURE;'
	PRINT '/* And then restart the SQL Server service. (Or it will take effect automatically on the next restart.) */'
	END


/* For testing: 
EXEC sp_SendStartupEmail;
*/