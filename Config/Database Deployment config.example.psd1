# Database Deployment config.example.psd1
# Configuration template for Database Deployment Manager
# Author: Philippe Addelia
# Version: 1.0.0
# Modified: 2026-10-10
#
# HOW TO USE
#   On first launch the tool copies this file to
#   'Database Deployment config.psd1' in the same folder. That personal copy is
#   excluded from source control, so pulling updates never overwrites it.
#   Edit the personal copy (Value set '...' button > 'Edit config file...')
#   and restart the tool.
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
