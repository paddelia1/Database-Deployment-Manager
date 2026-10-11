# Database Deployment Manager - Usage Guide

Detailed reference for Database Deployment Manager. For an overview and quick start, see the [README](../README.md).

## Contents

- [Key terms](#key-terms)
- [Requirements](#requirements)
- [Installation](#installation)
- [First run](#first-run)
- [Project layout](#project-layout)
- [Configuration file reference](#configuration-file-reference)
- [Value sets](#value-sets)
- [Authentication](#authentication)
- [Local SQL Server examples](#local-sql-server-examples)
- [Deploying to Microsoft Fabric](#deploying-to-microsoft-fabric)
- [Testing a connection outside the tool](#testing-a-connection-outside-the-tool)
- [Using a git repository (Azure DevOps, GitHub and others)](#using-a-git-repository-azure-devops-github-and-others)
- [Check version and file headers](#check-version-and-file-headers)

## Key terms

| Term | Meaning |
|---|---|
| **Value set** | A named list of target servers and databases, plus how to sign in to them. Pick one from the **Value set** menu. |
| **Host** | A server to deploy to, as you would type it in SSMS: `SQLDEV01`, `SQLPROD02\INSTANCE1`, `SQLPROD02\INSTANCE1,1433` (instance and/or port) or a Fabric endpoint. |
| **Database** | The target database (or Fabric warehouse). The one chosen in the **Target database** box is where scripts run. |
| **Platform** | The kind of database engine. Only `MSSQL` (SQL Server, Azure SQL, Fabric) exists today. |
| **Authentication** | How the tool signs in: `Windows`, `SqlLogin`, `EntraInteractive` or `EntraDefault`. Chosen per value set. |
| **Windows (integrated) authentication** | You are signed in as the Windows account that launched the tool; no password is needed. SSMS shows the login as `COMPUTER\User` or `DOMAIN\User`. |
| **SQL login** | A user name and password stored inside SQL Server. SSMS shows just the name, for example `app_deploy`. |
| **Microsoft Entra ID** | Microsoft's cloud identity service (formerly Azure AD). Required for Fabric. |
| **Fabric warehouse** | A Microsoft Fabric data warehouse. It accepts Entra sign-in only and a subset of T-SQL. |
| **sqlcmd** | The SQL Server command-line client the tool uses to run every script. There are two kinds: the older ODBC-based one and the newer Go-based one. |
| **Repository root** | The folder that holds your SQL files. Explicit-list entries are relative to it. |
| **Explicit file list** | A list of files to deploy, one per line, instead of "changed since" detection. |
| **Initialization script** | A script marked in the review grid to run before the others. |
| **Prepared file** | The temporary copy of a script the tool edits (CREATE OR ALTER, USE) and runs. Your source file is never changed. |
| **Personal config** | `Config\Database Deployment config.psd1`, created from the example on first run and excluded from git. |
| **Saved value sets file** | `Config\Database Deployment valuesets.user.psd1`, written by the value set dialog and excluded from git. |

## Requirements

- Windows PowerShell 5.1 or later (the GUI uses `System.Windows.Forms`).
- `sqlcmd.exe` in `PATH` or in a standard client-tools location, or set per
  value set (see [Authentication](#authentication)).
- Network access from the machine running the tool to your target servers
  (TCP 1433 or the instance port).
- Optional: Azure CLI (Fabric without per-file sign-in prompts).
- Optional: AWS CLI, only if you deploy from an S3 bucket.

## Installation

Run these in a normal (not elevated) PowerShell window.

**1. Check PowerShell and sqlcmd**

```powershell
$PSVersionTable.PSVersion                # 5.1 or later
Get-Command sqlcmd.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
sqlcmd -?                                # the first line shows the sqlcmd version
```

If sqlcmd is missing, install the command-line tools:

```powershell
winget install sqlcmd
```

If winget reports an existing package and does not give you the Go-based tool,
download the Windows zip from the go-sqlcmd releases page
(<https://github.com/microsoft/go-sqlcmd/releases>) and unpack it:

```powershell
New-Item -ItemType Directory -Force -Path 'C:\Tools\go-sqlcmd' | Out-Null
Expand-Archive -Path "$env:USERPROFILE\Downloads\<downloaded-file>.zip" -DestinationPath 'C:\Tools\go-sqlcmd' -Force
& 'C:\Tools\go-sqlcmd\sqlcmd.exe' --version
```

**2. Get the tool**

```powershell
git clone https://github.com/paddelia1/Database-Deployment-Manager.git
Set-Location .\Database-Deployment-Manager
Get-ChildItem -Recurse | Unblock-File    # needed when files came from a ZIP download
```

To use your own fork, clone `https://github.com/<your-account>/Database-Deployment-Manager.git`
instead. Without git, download the ZIP from GitHub, extract it and run the
`Unblock-File` line inside the extracted folder.

**3. Start it**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Database Deployment Manager.ps1"
```

To start it from the desktop, create a shortcut once:

```powershell
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut("$([Environment]::GetFolderPath('Desktop'))\Database Deployment Manager.lnk")
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($PWD.Path)\Database Deployment Manager.ps1`""
$shortcut.WorkingDirectory = $PWD.Path
$shortcut.Save()
```

**4. Optional - Azure CLI (Microsoft Fabric without per-file prompts)**

```powershell
winget install -e --id Microsoft.AzureCLI
# open a new PowerShell window, then:
az login --allow-no-subscriptions
```

## First run

1. On first launch the tool creates `Config\Database Deployment config.psd1`
   from `Config\Database Deployment config.example.psd1`.
2. Click the **...** button next to **Value set** and choose
   **New / edit value set...**.
3. Enter a name, the hosts and databases (one per line), and the
   authentication. Add a sqlcmd path if this set needs a particular
   `sqlcmd.exe`. Save. The set is available immediately.
4. Set the **Repository root** to the folder with your SQL files.
5. Click **Test Connection**. The log shows the sqlcmd used and the login
   that connected.

The example config ships demonstration sets (`Example`, `SqlLoginExample`,
`FabricExample`) and a template named `Custom` with empty lists. Replace or
ignore them.

## Project layout

```text
Database Deployment Manager.ps1                 GUI (entry point)
Config/
    Database Deployment config.example.psd1     template, tracked in git
    Database Deployment config.psd1             your personal config (git-ignored)
    Database Deployment valuesets.user.psd1     value sets saved from the GUI (git-ignored)
Modules/
    Platforms/
        MSSQL/
            Database Deployment Engine.psm1     SQL Server engine
```

The application expects these relative paths. Your personal config is
git-ignored, so pulling updates from upstream never overwrites it. When a new
release adds settings, compare your config with the example file.

## Configuration file reference

The personal config is a PowerShell data file (`.psd1`): a hashtable, so every
text value goes in single quotes and lists use `@( 'a' 'b' )`. Changes made in
a text editor take effect after a restart. A missing closing quote or bracket
stops the file from loading, and the tool shows the parse error.

| Key | Meaning | Example |
|---|---|---|
| `DefaultValueSet` | Value set selected on the first run (afterwards the last one used is restored). | `'Example'` |
| `DefaultPlatform` | Platform used when a value set does not name one. | `'MSSQL'` |
| `Platforms` | Platforms offered in the GUI. Keep `MSSQL`. | `@('MSSQL')` |
| `RepositoryRoot` | Default folder that holds your SQL files. | `'C:\Source\MyDatabaseRepo'` |
| `AwsProfile` | AWS CLI profile used for the S3 source. | `'MyAwsProfile'` |
| `DatabaseSubstitution` | Optional: replace one database name with another in the prepared copy when deploying to a named `Server`. Leave empty to disable. | `Server`, `DefaultDatabase`, `ReplacementDatabase` |
| `UseManagement` | `DefaultToTargetDatabase` and `Mappings` for the "Manage USE statements" option (see below). | |
| `ValueSets` | The named lists of servers and databases (next section). | |

## Value sets

A value set is a named list of target servers and databases, plus how to sign
in. Define as many as you need under `ValueSets` in your personal config:

```powershell
ValueSets = @{
    Example = @{
        Platform  = 'MSSQL'
        Hosts     = @('SQLDEV01', 'SQLTEST01', 'SQLPROD02\INSTANCE1,1433')
        Databases = @('SalesDB', 'SalesDB_TEST')
    }
    Customer2 = @{
        Platform  = 'MSSQL'
        Hosts     = @('OTHER-SQL-01')
        Databases = @('OrdersDB')
    }
}
```

Keys a value set can contain:

| Key | Required | Meaning |
|---|---|---|
| `Platform` | no (default `MSSQL`) | Database engine. |
| `Hosts` | yes | Servers to list in the **Target server(s)** menu. |
| `Databases` | no | Databases to list in the **Target database** box (you can also type one). |
| `Authentication` | no (default `Windows`) | `Windows`, `SqlLogin`, `EntraInteractive` or `EntraDefault`. |
| `AuthUser` | for `SqlLogin` and `EntraInteractive` | SQL login name, or Entra user name. |
| `SqlCmdPath` | no | Full path of the `sqlcmd.exe` this set must use. Overrides the SQLCMD box on the main window. |

Each key appears in the **Value set** menu.

You can also build lists without touching the config: choose
**New / edit value set...** in the Value set menu. The dialog starts from the
selected set. Change the name to create a new set, or keep a saved name to
update it. **Delete saved set** removes it. Saved sets are written to
`Config\Database Deployment valuesets.user.psd1` (generated, git-ignored) and
override a main-config set of the same name; they work immediately, with no
restart.

Other menu items: **Edit config file...** opens the file that holds the selected
set; **Edit main config file...** opens the personal config; **Forget SQL login
password** clears the remembered password. If you edit a file by hand, restart
the tool.

## Authentication

Each value set chooses how the tool signs in to its servers. The active mode
and sqlcmd are written to the log when a value set is selected, and **Test
Connection** shows the login that was used. Generated deployment scripts record
the same mode.

| Authentication | Sign-in | `sqlcmd` switches | Notes |
|---|---|---|---|
| `Windows` (default) | The Windows account running the tool | `-E` | Needs a login for that account on the server. No password involved. |
| `SqlLogin` | A SQL Server login | `-U <AuthUser>` | The password is asked once per session, kept in memory only and passed to `sqlcmd` through the `SQLCMDPASSWORD` environment variable. It is never on the command line and never saved. Generated scripts ask for it when they run. |
| `EntraInteractive` | Microsoft Entra, browser sign-in with MFA | `-G -U <AuthUser>` | May prompt for an account on every `sqlcmd` call. |
| `EntraDefault` | Microsoft Entra default credential | `-G` | No user name. With the Go-based sqlcmd it uses the Azure default credential chain, which picks up an Azure CLI sign-in (`az login`). No prompts. |

Which one do I use? Look at how SSMS connects. If the login shown for the
server is `COMPUTER\User` or `DOMAIN\User`, use `Windows`. If it is a plain
name such as `app_deploy`, use `SqlLogin`. For Microsoft Fabric use
`EntraDefault` (after `az login`) or `EntraInteractive`.

**Which sqlcmd for which sign-in**

| Sign-in | Recommended sqlcmd | Why |
|---|---|---|
| `Windows` | ODBC-based sqlcmd | The Go-based sqlcmd can fail integrated sign-in with `InitializeSecurityContext failed 8009030e`. |
| `SqlLogin` | Either | |
| `EntraInteractive` / `EntraDefault` | Go-based sqlcmd | The ODBC-based sqlcmd uses an embedded sign-in window that some federated tenants reject ("try a different browser or client"). |

Set this per value set with `SqlCmdPath`, so local sets use one sqlcmd and the
Fabric set uses the other.

Notes for Microsoft Entra:

- Needs `sqlcmd` 13.1 or later (ODBC-based) or the Go-based tool.
- `EntraInteractive` can open a browser sign-in for every `sqlcmd` call, so a
  deployment of many files may prompt repeatedly. To avoid that, run
  `az login` once (add `--allow-no-subscriptions` for a tenant without an Azure
  subscription) and use `EntraDefault` with the Go-based sqlcmd.
- The Azure CLI sign-in expires after a while. When the log shows an
  authentication error, run `az login --allow-no-subscriptions` again.
- Microsoft Fabric accepts Microsoft Entra sign-in only, not SQL logins.

## Local SQL Server examples

Windows integrated security (the default, no extra keys):

```powershell
Dev = @{
    Platform  = 'MSSQL'
    Hosts     = @('SQLDEV01', 'SQLDEV02\INSTANCE1')
    Databases = @('SalesDB')
}
```

SQL login (the tool asks for the password once per session):

```powershell
LocalSqlLogin = @{
    Platform       = 'MSSQL'
    Authentication = 'SqlLogin'
    AuthUser       = 'app_deploy'
    SqlCmdPath     = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE'
    Hosts          = @('myserver.example.local')
    Databases      = @('SalesDB')
}
```

A named instance or a non-default port is part of the host name:
`'SQLPROD02\INSTANCE1'`, `'SQLPROD02,1434'` or `'SQLPROD02\INSTANCE1,58441'`.

## Deploying to Microsoft Fabric

A Fabric warehouse (or SQL database in Fabric) accepts normal SQL Server
connections over port 1433 with Microsoft Entra sign-in only.

1. Install the Go-based sqlcmd ([Installation](#installation)) and the Azure CLI.
2. Sign in once: `az login --allow-no-subscriptions`.
3. In the Fabric portal, copy the server name from the warehouse's SQL
   connection string (it ends in `.datawarehouse.fabric.microsoft.com`). The
   database is the warehouse name.
4. Create a value set:

   ```powershell
   Fabric = @{
       Platform       = 'MSSQL'
       Authentication = 'EntraDefault'
       SqlCmdPath     = 'C:\Tools\go-sqlcmd\sqlcmd.exe'
       Hosts          = @('your-endpoint-id.datawarehouse.fabric.microsoft.com')
       Databases      = @('YourWarehouse')
   }
   ```

   For a browser sign-in instead, use `Authentication = 'EntraInteractive'`
   with `AuthUser = 'you@yourtenant.onmicrosoft.com'`.
5. Click **Test Connection**. The login shown is your Entra account.

Fabric supports a subset of T-SQL. For example triggers and synonyms are not
supported, `ALTER TABLE` is limited and `SET XACT_ABORT` is rejected
(`Msg 15869`), so scripts written for SQL Server may fail until they are
adjusted. `CREATE OR ALTER` conversion and the SET-option guard have not been
validated against Fabric, so test them first. See Microsoft's T-SQL surface
area documentation for the current list.

## Testing a connection outside the tool

If **Test Connection** fails, try the same connection by hand. This shows
whether the problem is the tool or the connection.

```powershell
# Is the server reachable? (port 1433 or your instance port)
Test-NetConnection myserver.example.local -Port 1433

# Windows authentication
sqlcmd -S myserver.example.local -d SalesDB -E -Q "SELECT SUSER_SNAME()"

# SQL login (password through the environment variable, not the command line)
$secure = Read-Host 'Password' -AsSecureString
$env:SQLCMDPASSWORD = [Net.NetworkCredential]::new('', $secure).Password
sqlcmd -S myserver.example.local -d SalesDB -U app_deploy -Q "SELECT SUSER_SNAME()"
Remove-Item Env:\SQLCMDPASSWORD

# Microsoft Fabric with the Go-based sqlcmd and an Azure CLI sign-in
az login --allow-no-subscriptions
& 'C:\Tools\go-sqlcmd\sqlcmd.exe' -S your-endpoint-id.datawarehouse.fabric.microsoft.com -d YourWarehouse -G -Q "SELECT SUSER_SNAME()"
```

## What the tool remembers between sessions

Saved automatically when you close the window to
`%LOCALAPPDATA%\DDM_SQL_Deployment_GUI\state.json` (never inside the repository):

- value set and the target servers you had selected
- target database
- repository root, S3 bucket and prefix, AWS profile
- detection mode, date/time, explicit file list
- transformation options and database-substitution values
- sqlcmd path (main window box), command timeout, window size and position

Passwords are never saved. A SQL login password is kept in memory for the
session only.

Delete `state.json` to reset to the config defaults.

## Source selection and candidate detection

Sources: **File System** or **AWS S3** (via the AWS CLI and your own
credentials/profile).

Detection modes:

- **Modified since date/time** - files changed after the chosen cutoff.
  **Ignore modification date** lists every matching file.
- **Explicit file list** - one SQL file per line (see below).

### Explicit file list format

Enter one entry per line, as a path **relative to the Repository root**. The
`.sql` extension is optional.

```text
Stored Procedures\usp_Example.sql
Views\vw_Example
```

With the root set to `C:\Repos\MyDb` these resolve to
`C:\Repos\MyDb\Stored Procedures\usp_Example.sql` and
`C:\Repos\MyDb\Views\vw_Example.sql`.

Notes:

- Files in subfolders need the subfolder in the entry; a bare filename is only
  found when the file sits directly in the root.
- A full path is accepted if it is under the Repository root (it is converted to
  a relative path). A path outside the root is reported as Missing.
- Do not paste extra columns (order numbers, actions); use the filename only.
- Select the **Explicit file list** radio button; the box is disabled otherwise.
- Entries that are not found show as **Missing** in the review grid, and the
  log shows the full path that was tried.

For S3, entries are object keys relative to the configured prefix.

## Using a git repository (Azure DevOps, GitHub and others)

The tool reads SQL files from a folder, so any git repository works once it is
cloned locally. Nothing in the tool is specific to a git host, and it never
stores git credentials: git (and Git Credential Manager) handles the sign-in.

```powershell
# Azure DevOps Repos
git clone https://dev.azure.com/<organization>/<project>/_git/<repository> C:\Source\MyDatabaseRepo

# GitHub
git clone https://github.com/<account>/<repository>.git C:\Source\MyDatabaseRepo

# Later, to get the latest changes
git -C C:\Source\MyDatabaseRepo pull
```

Then set the **Repository root** to the cloned folder (or a subfolder of it).

**Important: file dates after a clone.** The **Modified since date/time**
detection compares file timestamps. Git sets a file's timestamp to the moment
it was checked out, not the time of the commit:

- After a fresh `git clone`, every file looks modified at the clone time, so
  "modified since" lists everything newer than that.
- After a `git pull`, only the files that changed are touched, so a cutoff set
  to just before the pull finds the files the pull brought in.
- A branch switch can touch many files at once.

For a precise list, build an **Explicit file list** from git itself. The tool
needs paths relative to the Repository root with backslashes:

```powershell
$repo = 'C:\Source\MyDatabaseRepo'

# Files added or modified on this branch compared with main
git -C $repo diff --name-only --diff-filter=AM main...HEAD -- '*.sql' |
    ForEach-Object { $_ -replace '/', '\' } | Set-Clipboard

# Files changed in commits since a date
git -C $repo log --since='2026-10-01' --name-only --pretty=format: -- '*.sql' |
    Where-Object { $_ } | Sort-Object -Unique |
    ForEach-Object { $_ -replace '/', '\' } | Set-Clipboard
```

Paste the clipboard into the explicit list box. Git reports paths relative to
the top of the repository. When your Repository root is a subfolder, add
`--relative` to `git diff` (and run it with `-C` pointing at that subfolder) so
the paths are relative to it. Items that are not found show as **Missing**
in the review grid.

Deleting a file in git does not drop the object from the database; the tool only
deploys files that exist.

## Check version and file headers

When **Check version** is enabled, the tool reads the top of each SQL file and
shows the version it finds in the **Version** column. This only works if your
files carry a header with a version line. Files without one show an empty
Version column; deployment itself does not depend on it.

Rules the tool applies:

- Only the **first 80 lines** of the file are read (for S3, only the beginning
  of the object).
- It looks for a line that starts with the word `Version`, optionally after a
  comment marker (`--`, `/*`, `*`, `//` or `#`), followed by `:` or `=` and a
  number with at least one dot, for example `1.2` or `1.2.3`. Up to five
  parts are accepted, and letters, `_` and `-` are allowed after the first
  part (`1.2.3-beta`).
- The **first** matching line wins, so keep one `Version :` line near the top
  and do not repeat that form in a change history.
- Every other header field (author, dates, purpose) is for people; the tool
  ignores it.

Example header for a stored procedure, view or function:

```sql
/*
Script   : usp_GetCustomerOrders
Author   : Your Name
Created  : 2026-01-15
Modified : 2026-10-11
Version  : 1.2.0
Purpose  : Returns the open orders for a customer.

Change history:
  1.2.0 - 2026-10-11 - Added @IncludeClosed parameter
  1.1.0 - 2026-06-02 - Added index hint for large customers
  1.0.0 - 2026-01-15 - Initial version
*/
```

These single-line forms are also recognized:

```sql
-- Version: 1.2.0
/* Version: 1.2.0 */
```

A PowerShell-style header is accepted too, with the version on the line after
`.VERSION`:

```text
.VERSION
    1.2.0
```

To add a header to many existing files, start with one convention for the whole
repository and agree who updates `Version` and `Modified` when a file changes
(for example as part of each pull request).

## Pre-deployment review

The review grid lets you include or exclude items, mark initialization scripts
(these run first), reorder items (Up, Down, Top, Bottom), and save or reload the
deployment order. Clicking the **Deploy** column header toggles all eligible
rows.

## Deployment transformations

All transformations apply to a temporary copy; source files are never modified.

- **CREATE OR ALTER** - converts `CREATE PROC/PROCEDURE/VIEW` to
  `CREATE OR ALTER`.
- **Manage USE statements for target database** - the database selected in the
  **Target database** dropdown is the only execution target. A different `USE`
  is replaced; a script without `USE` gets one prepended. When unchecked, source
  `USE` statements are preserved exactly. `UseManagement.Mappings` in the config
  only informs the review display.
- **Database-name substitution** - replaces a database name inside SQL text when
  deploying to the configured server. Independent of USE management.
- **SET-option guard** (always on for MSSQL) - injects `SET ANSI_NULLS ON` and
  `SET QUOTED_IDENTIFIER ON` before the first CREATE/ALTER of a procedure,
  view, function or trigger, because SQL Server persists these settings with
  the module. An explicit `OFF` is kept and logged as a warning.

## Continue on error and retry

Item-level SQL failures are recorded and the run continues. Successful items are
unchecked; failed items stay checked and are listed in a Deployment Errors
dialog so you can fix them and retry only what remains.

## Generated deployment scripts

Instead of deploying immediately you can copy a generated, standalone
PowerShell script. File System items resolve at run time from a single
`$RepositoryRoot` variable at the top of the script, so the script is portable:
edit that one line when the repository lives elsewhere.

## Platform architecture

The engine is platform-oriented (`Modules\Platforms\<Platform>`). Only MSSQL is
implemented. Other platforms listed in comments in the config are ideas, not
existing engines.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Explicit list items show Missing | Path must be relative to the Repository root; see the log for the full path tried. |
| sqlcmd not found | Install the SQL Server command-line tools or set the sqlcmd path in the GUI or the value set. |
| Config will not load / red squiggles in the editor | A quote or bracket is missing in a `.psd1` list. Every entry needs both quotes, for example `'192.168.1.77'`. |
| `InitializeSecurityContext failed 8009030e` | Windows authentication failed in the Go-based sqlcmd. Use the ODBC-based sqlcmd for `Windows` value sets, or use `SqlLogin`. |
| `TCP Provider: The wait operation timed out` / `Login timeout expired` | The server is not reachable with that name or port. Check `Test-NetConnection`, the instance name and port, the firewall, and that the SQL Server service is running. |
| Connection works in SSMS but not in the tool | Compare the login SSMS shows. A plain name means a SQL login: use `Authentication = 'SqlLogin'`. |
| "Yikes! Something's gone wrong" or "try a different browser or client" during Entra sign-in | The ODBC-based sqlcmd cannot sign in to this tenant. Use the Go-based sqlcmd (`SqlCmdPath`). |
| Entra sign-in asks for an account on every file | Use `az login` once and `Authentication = 'EntraDefault'` with the Go-based sqlcmd. |
| `Msg 15869 ... XACT_ABORT is not supported` on Fabric | Fabric does not accept that statement. Remove it from the script or deploy a Fabric-compatible version. |
| Deployment failed, no detail | Failed items keep their prepared SQL file in your temp folder; the path is logged. |
| Config problems | Delete `Config\Database Deployment config.psd1` to recreate it from the example. |
| Value set menu looks wrong after hand-editing | Restart the tool. Saved sets live in `Config\Database Deployment valuesets.user.psd1`; delete that file to remove them all. |
