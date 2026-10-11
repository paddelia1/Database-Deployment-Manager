# Changelog

## 1.2.0 - 2026-10-11

- New "New / edit value set..." dialog in the Value set menu: create or change
  a value set (hosts, databases, authentication) from the GUI without
  restarting. Saved sets are written to
  `Config/Database Deployment valuesets.user.psd1` (git-ignored, generated).
- New authentication mode `SqlLogin` (SQL Server login, password prompted once
  per session and never stored). Added to the value set dialog.
- Optional `SqlCmdPath` per value set, overriding the SQLCMD box.
- "Edit config file..." opens the file that holds the selected value set;
  "Edit main config file..." opens the main config.

## 1.1.0 - 2026-10-11

- Selectable authentication per value set: `Windows` (default),
  `EntraInteractive` (with `AuthUser`) or `EntraDefault`. Enables deployments to
  Microsoft Fabric warehouses and Azure SQL. Applies to Test Connection,
  immediate deployments and generated scripts.
- Example config includes a `FabricExample` value set.

## 1.0.0 - 2026-10-10

Initial public release.

- Windows Forms GUI for reviewing, ordering and deploying SQL scripts.
- File System and AWS S3 sources; "modified since" and explicit-list detection.
- Value sets (named server and database lists) defined in a personal config file.
- Remembers the last session: value set, selected servers, database, repository
  root, S3 settings, detection mode, options and window layout.
- MSSQL engine: CREATE OR ALTER conversion, target-authoritative USE management,
  ANSI_NULLS / QUOTED_IDENTIFIER guard, continue-on-error with retry.
- Generates a standalone PowerShell deployment script.
