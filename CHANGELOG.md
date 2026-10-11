# Changelog

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
