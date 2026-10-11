# Database Deployment config.example.psd1
# Configuration template for Database Deployment Manager
# Author: Philippe Addelia
# Version: 1.2.0
# Modified: 2026-10-11
#
# HOW TO USE
#   On first launch the tool copies this file to
#   'Database Deployment config.psd1' in the same folder. That personal copy is
#   excluded from source control, so pulling updates never overwrites it.
#   Use the Value set '...' button > 'New / edit value set...' to build your
#   lists in the GUI (saved without a restart), or 'Edit main config file...'
#   to change this file by hand (restart afterwards).
#
# This file contains environment-specific values only. All values below are
# examples - replace them with your own.

@{
    # Value set selected when the tool starts (the last value set you used is
    # remembered between sessions and takes precedence).
    DefaultValueSet = 'Example'

    # Supported database platforms shown in the GUI.
    # Add a platform only when its engine exists under Modules\Platforms\<Platform>.
    DefaultPlatform = 'MSSQL'
    Platforms = @(
        'MSSQL'
    )

    # Default repository root (folder that contains your SQL files).
    # Overridden by the last value you used.
    RepositoryRoot = 'C:\Source\MyDatabaseRepo'

    # AWS CLI profile used when AWS S3 is the deployment source.
    AwsProfile = 'MyAwsProfile'

    # Optional database-name substitution applied to the prepared (temporary)
    # copy of each script when deploying to the named Server. Leave the values
    # empty to disable.
    DatabaseSubstitution = @{
        Server              = 'SQLTEST01'
        DefaultDatabase     = 'SalesDB'
        ReplacementDatabase = 'SalesDB_Staging'
    }

    # MSSQL USE-statement management.
    #
    # Evaluated ONLY when the GUI checkbox "Manage USE statements for target
    # database" is checked. When unchecked, source USE statements are preserved
    # unchanged. The database selected in the GUI Target database dropdown is
    # always authoritative; Mappings only describe known source -> target
    # relationships for the review display and never redirect execution.
    UseManagement = @{
        DefaultToTargetDatabase = $true

        Mappings = @{
            'SalesDB'     = 'SalesDB_TEST'
            'InventoryDB' = 'InventoryDB_TEST'
        }
    }

    # Value sets: named lists of target servers and databases shown in the GUI.
    #
    # Optional per value set:
    #   Authentication = 'Windows'           (default) the Windows account running the tool
    #                    'SqlLogin'          SQL Server login; AuthUser is the login name and the
    #                                        password is prompted once per session (never stored)
    #                    'EntraInteractive'  Microsoft Entra sign-in (browser/MFA); requires AuthUser
    #                    'EntraDefault'      Microsoft Entra default credential (no user name)
    #   AuthUser       = 'user@contoso.com'  used by SqlLogin and EntraInteractive
    #   SqlCmdPath     = 'C:\Tools\go-sqlcmd\sqlcmd.exe'  use this sqlcmd for the set instead of the
    #                    box on the main window (for example the Go-based sqlcmd for Fabric)
    # Add as many as you like - each key becomes an entry in the Value set menu.
    # Server names may include an instance and/or port, for example
    # 'SQLPROD01\INSTANCE1,1433'.
    ValueSets = @{
        Example = @{
            Platform = 'MSSQL'

            Hosts = @(
                'SQLDEV01'
                'SQLTEST01'
                'SQLPROD01'
                'SQLPROD02\INSTANCE1,1433'
            )

            Databases = @(
                'SalesDB'
                'SalesDB_TEST'
                'InventoryDB'
                'InventoryDB_TEST'
            )
        }

        # Example: local SQL Server with a SQL login (the password is asked once
        # per session and never stored). Use this when SSMS shows a plain login
        # name instead of COMPUTER\User or DOMAIN\User.
        SqlLoginExample = @{
            Platform       = 'MSSQL'
            Authentication = 'SqlLogin'
            AuthUser       = 'app_deploy'

            Hosts = @(
                'myserver.example.local'
            )

            Databases = @(
                'SalesDB'
            )
        }

        # Example: a Microsoft Fabric warehouse. Copy the server name from the
        # item's SQL connection string in the Fabric portal. Fabric accepts
        # Microsoft Entra sign-in only. EntraInteractive opens a browser sign-in
        # (it can prompt for every file). For no prompts, run 'az login
        # --allow-no-subscriptions' once, use Authentication = 'EntraDefault'
        # and the Go-based sqlcmd:
        #     Authentication = 'EntraDefault'
        #     SqlCmdPath     = 'C:\Tools\go-sqlcmd\sqlcmd.exe'
        FabricExample = @{
            Platform       = 'MSSQL'
            Authentication = 'EntraInteractive'
            AuthUser       = 'you@yourtenant.onmicrosoft.com'

            Hosts = @(
                'your-endpoint-id.datawarehouse.fabric.microsoft.com'
            )

            Databases = @(
                'YourWarehouse'
            )
        }

        # Copy this block to create your own list.
        Custom = @{
            Platform = 'MSSQL'

            Hosts = @(
                # 'MY-SQL-01'
                # 'MY-SQL-02\INSTANCE,1433'
            )

            Databases = @(
                # 'MyDatabase1'
                # 'MyDatabase2'
            )
        }

        # Future examples (only MSSQL is implemented today):
        #
        # PostgreSQLLab = @{
        #     Platform = 'PostgreSQL'
        #     Hosts = @('pg-server')
        #     Databases = @('application')
        # }
    }
}
