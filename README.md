# Database Deployment Manager

A Windows PowerShell GUI for reviewing, ordering, transforming and deploying
SQL scripts to one or more SQL Server instances. Fork it, edit one config file
with your own servers and databases, and the tool remembers your choices from
session to session.

- **Author:** Philippe Addelia
- **Version:** 1.0.0
- **License:** MIT (see `LICENSE`)

> **Test first.** This tool executes SQL against the servers you select. Try it
> on a non-production server before pointing it at anything important. It is
> provided as is, without warranty.

## Requirements

- Windows PowerShell 5.1 or later (the GUI uses `System.Windows.Forms`).
- `sqlcmd.exe` (SQL Server command-line tools) in `PATH` or in a standard
  client-tools location.
- Network access from the machine running the tool to your target servers.
- AWS CLI, only if you deploy from an S3 bucket.

## Quick start

1. Fork and clone this repository (or download it as a ZIP).
2. Run the script:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File ".\Database Deployment Manager.ps1"
   ```

   If Windows blocked the downloaded files, unblock them first:
   `Get-ChildItem -Recurse | Unblock-File`.
3. On first launch the tool creates `Config\Database Deployment config.psd1`
   from `Config\Database Deployment config.example.psd1`.
4. Click the **...** button next to **Value set** and choose
   **Edit config file...**. Replace the example servers, databases and
   repository root with your own, save, and restart the tool.

## Project layout

```text
Database Deployment Manager.ps1                 GUI (entry point)
Config/
    Database Deployment config.example.psd1     template, tracked in git
    Database Deployment config.psd1             your personal config (git-ignored)
Modules/
    Platforms/
        MSSQL/
            Database Deployment Engine.psm1     SQL Server engine
```

The application expects these relative paths. Your personal config is
git-ignored, so pulling updates from upstream never overwrites it. When a new
release adds settings, compare your config with the example file.

## Building your own lists (value sets)

A value set is a named list of target servers and databases. Define as many as
you need under `ValueSets` in your personal config:

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

Each key appears in the **Value set** menu. Restart the tool after editing the
config. `DefaultValueSet` is used on the first run; afterwards the last value
set you used is restored.

## What the tool remembers between sessions

Saved automatically when you close the window to
`%LOCALAPPDATA%\DDM_SQL_Deployment_GUI\state.json` (never inside the repository):

- value set and the target servers you had selected
- target database
- repository root, S3 bucket and prefix, AWS profile
- detection mode, date/time, explicit file list
- transformation options and database-substitution values
- sqlcmd path, command timeout, window size and position

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

## Check version

When **Check version** is enabled, the tool reads a version declaration near the
top of each SQL file and shows it in the **Version** column:

```sql
-- Version: 1.2.3
```

For S3 only the beginning of each object is retrieved.

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
| sqlcmd not found | Install the SQL Server command-line tools or set the sqlcmd path in the GUI. |
| Deployment failed, no detail | Failed items keep their prepared SQL file in your temp folder; the path is logged. |
| Config problems | Delete `Config\Database Deployment config.psd1` to recreate it from the example. |

## Contributing

Issues and pull requests are welcome. Please keep example values generic and do
not commit real server names, paths or credentials.
