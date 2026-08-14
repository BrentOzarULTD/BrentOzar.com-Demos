# Texas Hold 'Em web viewer proof of concept

This folder contains two deployable pieces:

- `azure-function/` is a .NET 10 isolated Azure Function. `GET
  /api/poker/state` calls `dbo.sp_TexasHoldEm_Public` as a spectator and turns
  its four result sets into JSON.
- `wordpress/texas-holdem-viewer/` is a WordPress plugin that provides the
  `[texas_holdem_viewer]` shortcode and refreshes the displayed game every 10
  seconds without reloading the page.

The Function keeps a 10-second, single-flight in-memory snapshot. Concurrent
requests handled by one warm Function instance share one SQL call. A scaled-out
instance has its own cache, so this is intentionally a proof-of-concept cache,
not a globally distributed guarantee. Direct SSMS players bypass this cache by
design.

## Production installation checklist

Work from the repository root unless a step says otherwise.

### 1. Deploy the non-blocking stored procedure

Run the complete `../sp_TexasHoldEm_Public.sql` installer in the target Azure
SQL database. The web API expects the opt-in parameter from issue #24:

```sql
SELECT name
FROM sys.parameters
WHERE object_id = OBJECT_ID(N'dbo.sp_TexasHoldEm_Public')
  AND name = N'@WaitForTurn';
```

Do not continue until that query returns one row. The Function calls:

```sql
EXEC dbo.sp_TexasHoldEm_Public
    @Action = N'Status',
    @ShowWhatHappened = N'ThisGame',
    @WaitForTurn = 0;
```

The public SQL login needs only the permission granted by the installer. The
Function deliberately sends no player name or seat password, so its cached
response is an observer-safe view.

### 2. Install deployment tools

The deployment machine needs:

1. .NET 10 SDK: <https://dotnet.microsoft.com/download/dotnet/10.0>
2. Azure CLI: <https://learn.microsoft.com/cli/azure/install-azure-cli>
3. Azure Functions Core Tools 4.x:
   <https://learn.microsoft.com/azure/azure-functions/functions-run-local>

Sign in and select the intended subscription:

```bash
az login
az account set --subscription "YOUR SUBSCRIPTION NAME OR ID"
```

### 3. Configure and deploy Azure

Choose globally unique lowercase names for the Function app and storage
account. Storage names must be 3-24 lowercase letters or digits.

```bash
export AZURE_RESOURCE_GROUP="texas-holdem-web"
export AZURE_LOCATION="eastus"
export AZURE_FUNCTION_APP="YOUR-GLOBALLY-UNIQUE-FUNCTION-NAME"
export AZURE_STORAGE_ACCOUNT="YOURUNIQUESTORAGENAME"
export WORDPRESS_ORIGIN="https://www.example.com"
export POKER_SQL_CONNECTION_STRING='PASTE THE PUBLISHED AZURE SQL CONNECTION STRING HERE'

T-SQL/sp_TexasHoldEm_Claude/web/scripts/deploy-azure.sh
```

The script is safe to rerun. It creates the resource group, storage account,
and Flex Consumption Function app when missing; sets the three application
settings; adds the exact WordPress CORS origin; and publishes the Function.
The SQL connection string is stored as an Azure application setting and is not
copied into the deployment package.

The Azure SQL firewall must allow the Function. For this public experiment,
the existing public firewall policy may already do that. Otherwise, enable
"Allow Azure services and resources to access this server" or allow all of the
Function app's outbound IP addresses.

### 4. Verify the API before touching WordPress

Use the endpoint printed by the deployment script:

```bash
curl --fail --show-error \
  "https://YOUR-FUNCTION.azurewebsites.net/api/poker/state"
```

Verify that the JSON contains `generatedAt`, `stale`, `hand`, `seats`,
`whatNow`, and `history`. Call it several times inside ten seconds and inspect
Application Insights: one warm Function instance should issue only one SQL
call during that window.

If the endpoint returns HTTP 503, inspect Function logs. Common causes are:

- `@WaitForTurn is not a parameter`: the issue #24 procedure is not deployed.
- SQL login or firewall errors: test the same published credential in SSMS.
- Result-shape errors: the procedure no longer returns Hand, Seat, What Now,
  and What Happened in that order.

### 5. Package and install the WordPress plugin

```bash
T-SQL/sp_TexasHoldEm_Claude/web/scripts/package-wordpress.sh
```

This creates the ignored local artifact
`T-SQL/sp_TexasHoldEm_Claude/web/artifacts/texas-holdem-viewer.zip`.

In WordPress:

1. Open **Plugins > Add New Plugin > Upload Plugin**.
2. Upload `texas-holdem-viewer.zip` and activate it.
3. Add this before the "stop editing" line in `wp-config.php`:

   ```php
   define(
       'TEXAS_HOLDEM_API_URL',
       'https://YOUR-FUNCTION.azurewebsites.net/api/poker/state'
   );
   ```

4. Create or edit a WordPress page and add this shortcode:

   ```text
   [texas_holdem_viewer]
   ```

5. Publish the page. In the browser's Network panel, confirm that the Function
   endpoint is fetched about every ten seconds and the document itself is not
   reloaded.

For a temporary test without editing `wp-config.php`, the endpoint may be
passed directly:

```text
[texas_holdem_viewer endpoint="https://YOUR-FUNCTION.azurewebsites.net/api/poker/state"]
```

### 6. Final production checks

- The API permits CORS only from the exact production WordPress origin,
  including `www` when the site uses it.
- The page shows only public cards until showdown.
- Stopping Azure SQL leaves the last successful snapshot visible with a stale
  warning; a brand-new Function instance with no snapshot returns HTTP 503.
- SQL resumes with no WordPress changes after a transient outage.
- The page keeps its existing data during a failed browser refresh and retries
  ten seconds later.

## Local validation

Restore/build requires NuGet access. The Function tests do not contact Azure
SQL:

```bash
dotnet test \
  T-SQL/sp_TexasHoldEm_Claude/web/azure-function.tests/PokerApi.Tests.csproj \
  --configuration Release

php -l \
  T-SQL/sp_TexasHoldEm_Claude/web/wordpress/texas-holdem-viewer/texas-holdem-viewer.php

node --check \
  T-SQL/sp_TexasHoldEm_Claude/web/wordpress/texas-holdem-viewer/assets/poker-viewer.js
```
