# Database Deployment Manager

A Windows desktop tool for deploying SQL scripts to your database servers
safely and repeatably. Point it at a folder of SQL files (or an S3 bucket),
review what will run, and deploy to one or many SQL Server instances, with the
steps and settings you used last time already filled in.

Written in PowerShell. No installer, no database of its own, nothing to host:
fork it, edit one config file, and run it.

- **Author:** Philippe Addelia
- **Version:** 1.0.0
- **License:** MIT (see [LICENSE](LICENSE))

## What it does

Deploying a handful of changed scripts by hand is easy to get wrong: wrong
server, wrong database, wrong order, a script left out. Database Deployment
Manager puts a review step in front of the deployment:

1. **Find** the scripts to deploy, either everything changed since a date and
   time or an explicit list of files.
2. **Review** them in a grid. Exclude items, mark initialization scripts, and
   put the rest in the right order.
3. **Deploy** to the selected servers and database, or generate a standalone
   PowerShell script to run later or hand to someone else.
4. **Fix and retry.** If some items fail, the rest still deploy and only the
   failures stay selected, with the error details ready to copy.

## Highlights

- **Your own lists.** Define named sets of servers and databases (for example
  dev, test, staging, a second customer) and switch between them in one click.
- **Remembers your last session.** Servers, database, folders, options and
  window layout come back the next time you open it.
- **Safe by design.** Source files are never modified; every change is made to
  a temporary copy, and a pre-deployment review shows what will happen.
- **Script preparation.** Optional conversion to `CREATE OR ALTER`, control of
  which database each script runs against, and protection for the
  `ANSI_NULLS` / `QUOTED_IDENTIFIER` settings.
- **Files or S3.** Deploy from a local repository folder or from an AWS S3
  bucket.
- **Repeatable.** Save and reload a deployment order, or generate a portable
  deployment script.
- **Extensible.** Engines are organized by platform; SQL Server is implemented
  today.

<!--
SCREENSHOTS (enable once images are added to docs/images/):

## Screenshots

![Main window](docs/images/main-window.png)
*The main window: pick a value set, servers and source, then build the review.*

![Review grid](docs/images/review-grid.png)
*Pre-deployment review: include, exclude and order the scripts.*

![Deployment result](docs/images/deployment-result.png)
*Results and error details after a deployment.*
-->

## Requirements

- Windows PowerShell 5.1 or later
- `sqlcmd.exe` (SQL Server command-line tools)
- Network access from your machine to the target servers
- AWS CLI, only if you deploy from S3

## Quick start

1. Fork and clone this repository, or download it as a ZIP.
2. Run:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File ".\Database Deployment Manager.ps1"
   ```

   If Windows blocked the downloaded files, run
   `Get-ChildItem -Recurse | Unblock-File` first.
3. On first launch the tool creates your personal config from the shipped
   example. Click **...** next to **Value set**, choose
   **Edit config file...**, enter your own servers, databases and repository
   folder, save, and restart.

Your personal config is excluded from git, so pulling updates from this
repository never overwrites it.

> **Test first.** This tool runs SQL against the servers you select. Try it on
> a non-production server before using it on anything important. It is
> provided as is, without warranty.

## Documentation

See the [Usage Guide](docs/USAGE.md) for configuration, the explicit file list
format, deployment options, remembered settings and troubleshooting.

## Project layout

```text
Database Deployment Manager.ps1                 the application
Config/                                         example config (your own copy is git-ignored)
Modules/Platforms/MSSQL/                        SQL Server deployment engine
docs/                                           usage guide (and screenshots)
```

## Contributing

Issues and pull requests are welcome. Please keep example values generic and do
not commit real server names, paths or credentials.
