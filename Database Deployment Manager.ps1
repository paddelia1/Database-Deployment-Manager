#requires -Version 5.1
<#
.SYNOPSIS
    Database Deployment Manager

.VERSION
    1.0.0

.MODIFIED
    2026-10-10

.AUTHOR
    Philippe Addelia

.DESCRIPTION
    Builds a reviewed deployment set from either:
      - SQL files modified since a selected date/time, or
      - an explicit editable list of SQL files/objects.

    Deployment items may come from:
      - the local/repository File System, or
      - AWS S3 using the locally available AWS CLI credentials.

    The operator can:
      - select one or more target SQL Server instances,
      - select a target database,
      - select/edit the repository root or S3 bucket/prefix,
      - review and exclude detected files/objects,
      - copy the generated deployment PowerShell command/script,
      - or execute the deployment immediately.

    The explicit list is persisted between runs.

.NOTES
    Version 1.0.0 - 2026-10-10:
      - Initial public release.

    Requires:
      - Windows PowerShell 5.1+
      - sqlcmd.exe available in PATH or a standard SQL client tools location.
      - AWS CLI only when S3 origin is used.
      - Config\Database Deployment config.psd1 (created from
        Config\Database Deployment config.example.psd1 on first run).
      - Modules\Platforms\MSSQL\Database Deployment Engine.psm1 must exist.
      - AWS CLI is required only when S3 features are used.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# DEFAULTS
# ============================================================

# ============================================================
# EXTERNAL CONFIGURATION
# ============================================================
$ConfigPath = Join-Path (Join-Path $PSScriptRoot 'Config') 'Database Deployment config.psd1'
$ConfigExamplePath = Join-Path (Join-Path $PSScriptRoot 'Config') 'Database Deployment config.example.psd1'

# First run: create the personal config from the shipped example.
# The personal config is excluded from source control so pulling updates
# never overwrites it.
if (-not (Test-Path -LiteralPath $ConfigPath) -and (Test-Path -LiteralPath $ConfigExamplePath)) {
    try {
        Copy-Item -LiteralPath $ConfigExamplePath -Destination $ConfigPath -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "First run: a configuration file was created from the example:`r`n$ConfigPath`r`n`r`nUse the Value set '...' button and choose 'Edit config file...' to enter your own servers, databases and repository root, then restart the tool.",
            'Database Deployment Manager',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to create the configuration file from the example:`r`n$ConfigPath`r`n`r`n$($_.Exception.Message)",
            'Database Deployment Manager',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Configuration file not found:`r`n$ConfigPath",
        'Database Deployment Manager',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

try {
    $AppConfig = Import-PowerShellDataFile -LiteralPath $ConfigPath
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Unable to load configuration file:`r`n$ConfigPath`r`n`r`n$($_.Exception.Message)",
        'Database Deployment Manager',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

if (-not ($AppConfig.ValueSets -is [hashtable]) -or $AppConfig.ValueSets.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "The configuration file must define at least one entry under ValueSets:`r`n$ConfigPath",
        'Database Deployment Manager',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

$DefaultValueSet = if ($AppConfig.DefaultValueSet -and $AppConfig.ValueSets.ContainsKey([string]$AppConfig.DefaultValueSet)) {
    [string]$AppConfig.DefaultValueSet
}
else {
    [string](@($AppConfig.ValueSets.Keys | Sort-Object)[0])
}
$DefaultPlatform = if ($AppConfig.DefaultPlatform) { [string]$AppConfig.DefaultPlatform } else { 'MSSQL' }
$ConfiguredPlatforms = @(
    if ($AppConfig.Platforms) {
        @($AppConfig.Platforms)
    }
    else {
        @('MSSQL')
    }
)

# Existing variables are populated from configuration so the rest of the
# application remains backward-compatible while configuration is externalized.
$DefaultRepoRoot         = if ($AppConfig.RepositoryRoot) { [string]$AppConfig.RepositoryRoot } else { '' }
$DefaultDevAwsProfile    = if ($AppConfig.AwsProfile) { [string]$AppConfig.AwsProfile } else { '' }
$DefaultDbMapServer      = if ($AppConfig.DatabaseSubstitution.Server) { [string]$AppConfig.DatabaseSubstitution.Server } else { '' }
$DefaultDbMapSource      = if ($AppConfig.DatabaseSubstitution.DefaultDatabase) { [string]$AppConfig.DatabaseSubstitution.DefaultDatabase } else { '' }
$DefaultDbMapReplacement = if ($AppConfig.DatabaseSubstitution.ReplacementDatabase) { [string]$AppConfig.DatabaseSubstitution.ReplacementDatabase } else { '' }

$UseManagementConfig = if ($AppConfig.UseManagement) { $AppConfig.UseManagement } else { @{} }
$UseManagementMappings = if ($UseManagementConfig.Mappings) { $UseManagementConfig.Mappings } else { @{} }
$UseManagementDefaultToTarget = if ($null -ne $UseManagementConfig.DefaultToTargetDatabase) {
    [bool]$UseManagementConfig.DefaultToTargetDatabase
}
else {
    $true
}


# ============================================================
# DEPLOYMENT ENGINE
# ============================================================
$EnginePath = Join-Path `
    (Join-Path (Join-Path (Join-Path $PSScriptRoot 'Modules') 'Platforms') 'MSSQL') `
    'Database Deployment Engine.psm1'

if (-not (Test-Path -LiteralPath $EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Deployment engine not found:`r`n$EnginePath",
        'Database Deployment Manager',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

try {
    Import-Module -Name $EnginePath -Force -ErrorAction Stop
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Unable to load deployment engine:`r`n$EnginePath`r`n`r`n$($_.Exception.Message)",
        'Database Deployment Manager',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}


$DefaultDetectionDate = (Get-Date).Date.AddDays(-1)
$DefaultSqlCmdPath = ''
$DefaultCommandTimeout = 120
# Persist GUI state in LocalAppData.
$StateDirectory = Join-Path $env:LOCALAPPDATA 'DDM_SQL_Deployment_GUI'
$StateFile = Join-Path $StateDirectory 'state.json'

# ============================================================
# STATE HELPERS
# ============================================================

function Get-SavedState {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Save-State {
    param(
        [string[]]$Hosts,
        [string]$RepoRoot,
        [string]$ExplicitList,
        [string]$Database,
        [string]$SqlCmdPath,
        [int]$CommandTimeout,
        [string]$DetectionMode,
        [datetime]$DetectionDate,
        [string]$Origin,
        [string]$S3Bucket,
        [string]$S3Prefix,
        [string]$AwsProfile,
        [bool]$CreateOrAlter,
        [string]$DbMapServer,
        [string]$DbMapSource,
        [string]$DbMapReplacement,
        [string]$ValueSet,
        [bool]$UseAwsProfile,
        [bool]$ManageUseStatements,
        [string]$Platform,
        [int]$WindowWidth,
        [int]$WindowHeight,
        [int]$WindowX,
        [int]$WindowY,
        [string]$WindowState,
        [int]$MainSplitterDistance,
        [int]$RightSplitterDistance
    )

    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }

    $state = [ordered]@{
        Hosts          = @($Hosts)
        RepoRoot       = $RepoRoot
        ExplicitList   = $ExplicitList
        Database       = $Database
        SqlCmdPath     = $SqlCmdPath
        CommandTimeout = $CommandTimeout
        DetectionMode  = $DetectionMode
        DetectionDate  = $DetectionDate.ToString('o')
        Origin         = $Origin
        S3Bucket       = $S3Bucket
        S3Prefix       = $S3Prefix
        AwsProfile       = $AwsProfile
        CreateOrAlter     = $CreateOrAlter
        DbMapServer       = $DbMapServer
        DbMapSource       = $DbMapSource
        DbMapReplacement  = $DbMapReplacement
        ValueSet             = $ValueSet
        UseAwsProfile        = $UseAwsProfile
        ManageUseStatements  = $ManageUseStatements
        Platform             = $Platform
        WindowWidth          = $WindowWidth
        WindowHeight         = $WindowHeight
        WindowX              = $WindowX
        WindowY              = $WindowY
        WindowState          = $WindowState
        MainSplitterDistance = $MainSplitterDistance
        RightSplitterDistance = $RightSplitterDistance
    }

    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

$SavedState = Get-SavedState

# ============================================================
# GENERAL HELPERS
# ============================================================

function Get-RelativePath {
    param([string]$Root,[string]$FullPath)
    return Get-DDMRelativePath -Root $Root -FullPath $FullPath
}
function Normalize-ListEntry {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $value = $Text.Trim().Trim('"').Trim("'")
    $value = $value -replace '^\{([^}]+)\}', '$1'

    if ($rbS3.Checked) {
        $value = $value -replace '\\', '/'
        $value = $value.TrimStart('/')

        if ($chkSqlOnly.Checked -and
            -not $value.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) {
            $value += '.sql'
        }

        $prefix = $txtS3Prefix.Text.Trim().Trim('/')

        if (-not [string]::IsNullOrWhiteSpace($prefix) -and
            -not $value.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $value.Equals($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {

            $value = "$prefix/$value"
        }

        return $value
    }

    $value = $value -replace '/', '\'
    $value = $value -replace '^\.\\', ''
    $value = $value -replace '^\\(?!\\)', ''

    if (-not $value.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) {
        $value += '.sql'
    }

    return $value
}


function Get-ValueSetData {
    param([string]$SetName)

    if (-not $AppConfig.ValueSets.ContainsKey($SetName)) {
        $SetName = $DefaultValueSet
    }

    $set = $AppConfig.ValueSets[$SetName]

    return [pscustomobject]@{
        Name      = $SetName
        Platform  = if ($set.Platform) { [string]$set.Platform } else { 'MSSQL' }
        Servers   = @($set.Hosts)
        Databases = @($set.Databases)
    }
}

function Populate-ServerMenu {
    param([string[]]$Servers)

    $ctxServers.Items.Clear()
    $script:ServerMenuItems = @()

    foreach ($serverName in $Servers) {
        $menuItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $menuItem.Text = [string]$serverName
        $menuItem.CheckOnClick = $true

        $menuItem.Add_CheckedChanged({
            Update-ServerDropdownText
        })

        [void]$ctxServers.Items.Add($menuItem)
        $script:ServerMenuItems += $menuItem
    }

    if ($Servers.Count -gt 0) {
        [void]$ctxServers.Items.Add(
            (New-Object System.Windows.Forms.ToolStripSeparator)
        )
    }

    $doneItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $doneItem.Text = 'Done'
    $doneItem.Font = New-Object System.Drawing.Font(
        $doneItem.Font,
        [System.Drawing.FontStyle]::Bold
    )

    $doneItem.Add_Click({
        $ctxServers.Close()
    })

    [void]$ctxServers.Items.Add($doneItem)

    Update-ServerDropdownText
}

function Apply-ValueSet {
    param(
        [Parameter(Mandatory)]
        [string]$SetName
    )

    $set = Get-ValueSetData -SetName $SetName
    $script:CurrentValueSet = $set.Name
    $lblValueSetValue.Text = $set.Name

    Populate-ServerMenu -Servers $set.Servers

    $currentDb = $cmbDatabase.Text
    $cmbDatabase.Items.Clear()

    foreach ($db in $set.Databases) {
        [void]$cmbDatabase.Items.Add([string]$db)
    }

    if (-not [string]::IsNullOrWhiteSpace($currentDb) -and
        $cmbDatabase.Items.Contains($currentDb)) {
        $cmbDatabase.Text = $currentDb
    }
    elseif ($cmbDatabase.Items.Count -gt 0) {
        $cmbDatabase.SelectedIndex = 0
    }
    else {
        $cmbDatabase.Text = ''
    }

    Write-Log "Value set selected: $($set.Name)"
}

function Get-CurrentWindowLayout {
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $bounds = $form.Bounds
    }
    else {
        $bounds = $form.RestoreBounds
    }

    return [pscustomobject]@{
        Width  = [int]$bounds.Width
        Height = [int]$bounds.Height
        X      = [int]$bounds.X
        Y      = [int]$bounds.Y
        State  = [string]$form.WindowState
        MainSplitterDistance  = [int]$splitMain.SplitterDistance
        RightSplitterDistance = [int]$splitRight.SplitterDistance
    }
}

function Get-SelectedServers {
    $servers = @()

    foreach ($menuItem in $script:ServerMenuItems) {
        if ($menuItem.Checked) {
            $servers += [string]$menuItem.Text
        }
    }

    return $servers
}

function Update-ServerDropdownText {
    $servers = @(Get-SelectedServers)

    if (@($servers).Count -eq 0) {
        $btnServerDropdown.Text = 'Select target server(s)...'
    }
    elseif (@($servers).Count -eq 1) {
        $btnServerDropdown.Text = $servers[0]
    }
    else {
        $btnServerDropdown.Text = "$(@($servers).Count) servers selected"
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'

    switch ($Level) {
        'Success' { $prefix = '[OK]' }
        'Warning' { $prefix = '[WARN]' }
        'Error'   { $prefix = '[ERROR]' }
        default   { $prefix = '[INFO]' }
    }

    $txtLog.AppendText("$timestamp $prefix $Message`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Get-UseManagementMappings {
    $result = @{}

    if ($UseManagementMappings) {
        foreach ($key in $UseManagementMappings.Keys) {
            $result[[string]$key] = [string]$UseManagementMappings[$key]
        }
    }

    return $result
}

function Get-AwsProfileArgs {
    $args = @()

    if ($chkUseAwsProfile.Checked) {
        $profile = $txtAwsProfile.Text.Trim()

        if (-not [string]::IsNullOrWhiteSpace($profile) -and
            $profile -ne 'Profile not used in this box') {
            $args += @('--profile', $profile)
        }
    }

    return $args
}

function Get-AwsAuthDescription {
    if ($chkUseAwsProfile.Checked) {
        $profile = $txtAwsProfile.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($profile) -or
            $profile -eq 'Profile not used in this box') {
            return 'AWS profile enabled but no profile name was provided'
        }

        return "AWS profile [$profile]"
    }

    return 'AWS profile disabled - using default/server AWS credential chain'
}

function Update-AwsProfileControls {
    if ($chkUseAwsProfile.Checked) {
        $txtAwsProfile.Enabled = $true

        if ($txtAwsProfile.Text -eq 'Profile not used in this box' -or
            [string]::IsNullOrWhiteSpace($txtAwsProfile.Text)) {

            if ($SavedState -and $SavedState.AwsProfile -and
                [string]$SavedState.AwsProfile -ne 'Profile not used in this box') {
                $txtAwsProfile.Text = [string]$SavedState.AwsProfile
            }
            else {
                $txtAwsProfile.Text = $DefaultDevAwsProfile
            }
        }
    }
    else {
        $txtAwsProfile.Enabled = $false
        $txtAwsProfile.Text = 'Profile not used in this box'
    }
}

function Get-AwsCliPath {
    return Get-DDMAwsCliPath
}

function Invoke-AwsCliJson {
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    return Invoke-DDMAwsJson `
        -AwsExe $AwsExe `
        -Arguments $Arguments `
        -UseProfile ([bool]$chkUseAwsProfile.Checked) `
        -ProfileName $txtAwsProfile.Text.Trim()
}

function Set-OriginControls {
    $isFileSystem = $rbFileSystem.Checked

    $lblRepo.Visible = $isFileSystem
    $txtRepoRoot.Visible = $isFileSystem
    $btnBrowseRepo.Visible = $isFileSystem

    $lblS3Bucket.Visible = -not $isFileSystem
    $cmbS3Bucket.Visible = -not $isFileSystem
    $btnListBuckets.Visible = -not $isFileSystem
    $lblS3Prefix.Visible = -not $isFileSystem
    $txtS3Prefix.Visible = -not $isFileSystem
    $chkUseAwsProfile.Visible = -not $isFileSystem
    $lblAwsProfile.Visible = -not $isFileSystem
    $txtAwsProfile.Visible = -not $isFileSystem
    $chkSqlOnly.Visible = -not $isFileSystem
    $chkIgnoreFileDate.Enabled = $rbDate.Checked

    Update-AwsProfileControls

    if ($isFileSystem) {
        $grpSource.Text = 'File System source'
        $rbList.Text = 'Explicit file list'
        $colFile.HeaderText = 'Repository-relative file'
        $btnDetect.Text = 'Build / Refresh Review'
    }
    else {
        $grpSource.Text = 'S3 source'
        $rbList.Text = 'Explicit S3 object list'
        $colFile.HeaderText = 'S3 object key'
        $btnDetect.Text = 'Load / Refresh S3 Items'
    }

    $gridReview.Rows.Clear()
    $lblReviewCount.Text = 'Candidates: 0'
}

function Set-ModeControls {
    if ($rbDate.Checked) {
        $dtpDetection.Enabled = -not $chkIgnoreFileDate.Checked
        $chkIgnoreFileDate.Enabled = $true
        $txtExplicitList.Enabled = $false
    }
    else {
        $dtpDetection.Enabled = $false
        $chkIgnoreFileDate.Enabled = $false
        $txtExplicitList.Enabled = $true
    }
}

function Get-FileSystemCandidateItems {
    $repoRoot = $txtRepoRoot.Text.Trim()

    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
        throw "Repository root does not exist: $repoRoot"
    }

    if ($rbDate.Checked) {
        $startDate = $dtpDetection.Value

        return @(
            Get-DDMFileSystemCandidates `
                -Root $repoRoot `
                -StartDate $startDate `
                -IgnoreModificationDate ([bool]$chkIgnoreFileDate.Checked) `
                -CheckVersion ([bool]$chkCheckVersion.Checked) `
                -SelectedDatabase $(if ($cmbDatabase.SelectedItem) { [string]$cmbDatabase.SelectedItem } else { [string]$cmbDatabase.Text }) `
                -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
                -UseMappings (Get-UseManagementMappings) `
                -DefaultToTargetDatabase $UseManagementDefaultToTarget `
                -ProgressAction { Update-LoadingIndicator }
        )
    }

    $result = @()

    foreach ($line in $txtExplicitList.Lines) {
        $entry = Normalize-ListEntry $line

        if (-not $entry) {
            continue
        }

        # Full paths are accepted when they are under the Repository root;
        # they are converted to repository-relative entries. A full path outside
        # the root cannot be mapped to a portable relative path and is reported.
        if ([System.IO.Path]::IsPathRooted($entry)) {
            $rootWithSep = $repoRoot.TrimEnd('\') + '\'
            if ($entry.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
                $entry = $entry.Substring($rootWithSep.Length)
            }
            else {
                Write-Log "Explicit list: '$entry' is outside the Repository root '$repoRoot' - marked Missing. Use a path relative to the root."
                $fullPath = $entry
                $exists = $false
            }
        }

        if (-not [System.IO.Path]::IsPathRooted($entry)) {
            $fullPath = Join-Path $repoRoot $entry
            $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
            if (-not $exists) {
                Write-Log "Explicit list: file not found: $fullPath"
            }
        }

        Update-LoadingIndicator

        $useInfo = if ($exists) {
            Get-DDMFileUseStatementInfo `
                -FilePath $fullPath `
                -SelectedDatabase $cmbDatabase.Text `
                -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
                -UseMappings (Get-UseManagementMappings) `
                -DefaultToTargetDatabase $UseManagementDefaultToTarget
        } else {
            [pscustomobject]@{ UseDatabase=''; UseAction=''; UseCount=0 }
        }

        $result += [pscustomobject]@{
            Origin        = 'File System'
            DisplayName   = $entry
            Source        = $fullPath
            LastWriteTime = if ($exists) { (Get-Item -LiteralPath $fullPath).LastWriteTime } else { [datetime]::MinValue }
            Version       = if ($exists -and $chkCheckVersion.Checked) { Get-DDMFileHeaderVersion -FilePath $fullPath } else { '' }
            UseDatabase   = $useInfo.UseDatabase
            UseAction     = $useInfo.UseAction
            Missing       = -not $exists
            Bucket        = $null
            Key           = $null
        }
    }

    return @($result | Sort-Object DisplayName -Unique)
}

function Get-S3CandidateItems {
    $bucket = $cmbS3Bucket.Text.Trim()
    $prefix = $txtS3Prefix.Text.Trim().Trim('/')

    if ([string]::IsNullOrWhiteSpace($bucket)) {
        throw 'Enter or select an S3 bucket name.'
    }

    $awsExe = Get-AwsCliPath

    if (-not $awsExe) {
        throw 'AWS CLI was not found. S3 origin requires aws.exe/aws to be available in PATH.'
    }

    Write-Log "S3 authentication: $(Get-AwsAuthDescription)"
    Write-Log "S3 bucket: $bucket"
    Write-Log "S3 prefix: $(if ([string]::IsNullOrWhiteSpace($prefix)) { '<none>' } else { $prefix })"

    if ($rbDate.Checked) {
        $args = @('s3api','list-objects-v2','--bucket',$bucket,'--output','json')

        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            $args += @('--prefix', ($prefix + '/'))
        }

        $allObjects = @()
        $continuationToken = $null

        do {
            $pagedArgs = @($args)

            if ($continuationToken) {
                $pagedArgs += @('--continuation-token', $continuationToken)
            }

            $response = Invoke-AwsCliJson -AwsExe $awsExe -Arguments $pagedArgs

            if ($response -and $response.Contents) {
                $allObjects += @($response.Contents)
            }

            $continuationToken = $null

            if ($response -and $response.IsTruncated -and $response.NextContinuationToken) {
                $continuationToken = [string]$response.NextContinuationToken
            }
        }
        while ($continuationToken)

        $sqlObjects = @(
            $allObjects | Where-Object {
                ([string]$_.Key).EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)
            }
        )

        if ($chkSqlOnly.Checked) {
            $candidateObjects = $sqlObjects
        }
        else {
            $candidateObjects = $allObjects
        }

        $startDate = $dtpDetection.Value

        if ($chkIgnoreFileDate.Checked) {
            $matchingObjects = $candidateObjects
        }
        else {
            $matchingObjects = @(
                $candidateObjects | Where-Object {
                    ([datetime]$_.LastModified) -ge $startDate
                }
            )
        }

        Write-Log "S3 objects returned: $($allObjects.Count)"
        Write-Log "S3 .sql objects found: $($sqlObjects.Count)"
        Write-Log "S3 content filter: $(if ($chkSqlOnly.Checked) { 'SQL files only' } else { 'All object types' })"

        if ($chkCheckVersion.Checked) {
            Write-Log 'Reading SQL header versions from the first 16 KB of each matching S3 SQL object...'
        }

        if ($chkIgnoreFileDate.Checked) {
            Write-Log "Modification-date filter is disabled. Matching objects: $($matchingObjects.Count)"
        }
        else {
            Write-Log "Objects modified since $($startDate.ToString('yyyy-MM-dd HH:mm:ss')): $($matchingObjects.Count)"
        }

        $result = @()

        foreach ($obj in $matchingObjects) {
            Update-LoadingIndicator

            $key = [string]$obj.Key
            $modified = [datetime]$obj.LastModified

            $version = ''

            if ($chkCheckVersion.Checked -and
                $key.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) {
                $version = Get-DDMS3ObjectHeaderVersion `
                    -AwsExe $awsExe `
                    -Bucket $bucket `
                    -Key $key `
                    -UseProfile ([bool]$chkUseAwsProfile.Checked) `
                    -ProfileName $txtAwsProfile.Text.Trim()
            }

            $useInfo = if ($key.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) {
                Get-DDMS3ObjectUseStatementInfo `
                    -AwsExe $awsExe `
                    -Bucket $bucket `
                    -Key $key `
                    -SelectedDatabase $(if ($cmbDatabase.SelectedItem) { [string]$cmbDatabase.SelectedItem } else { [string]$cmbDatabase.Text }) `
                    -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
                    -UseMappings (Get-UseManagementMappings) `
                    -DefaultToTargetDatabase $UseManagementDefaultToTarget `
                    -UseProfile ([bool]$chkUseAwsProfile.Checked) `
                    -ProfileName $txtAwsProfile.Text.Trim()
            } else {
                [pscustomobject]@{ UseDatabase=''; UseAction=''; UseCount=0 }
            }

            $result += [pscustomobject]@{
                Origin        = 'S3'
                DisplayName   = $key
                Source        = "s3://$bucket/$key"
                LastWriteTime = $modified
                Version       = $version
                UseDatabase   = $useInfo.UseDatabase
                UseAction     = $useInfo.UseAction
                Missing       = $false
                Bucket        = $bucket
                Key           = $key
            }
        }

        return @($result | Sort-Object LastWriteTime, DisplayName)
    }

    $result = @()

    foreach ($line in $txtExplicitList.Lines) {
        $key = Normalize-ListEntry $line

        if (-not $key) {
            continue
        }

        Update-LoadingIndicator

        $headArgs = @(
            's3api','head-object',
            '--bucket',$bucket,
            '--key',$key,
            '--output','json'
        )

        try {
            $head = Invoke-AwsCliJson -AwsExe $awsExe -Arguments $headArgs
            $modified = if ($head.LastModified) { [datetime]$head.LastModified } else { [datetime]::MinValue }
            $missing = $false
        }
        catch {
            $modified = [datetime]::MinValue
            $missing = $true
        }

        $version = ''

        if ($chkCheckVersion.Checked -and
            -not $missing -and
            $key.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) {
            $version = Get-DDMS3ObjectHeaderVersion `
                -AwsExe $awsExe `
                -Bucket $bucket `
                -Key $key `
                -UseProfile ([bool]$chkUseAwsProfile.Checked) `
                -ProfileName $txtAwsProfile.Text.Trim()
        }

        $useInfo = if (-not $missing -and $key.EndsWith('.sql', [System.StringComparison]::OrdinalIgnoreCase)) {
            Get-DDMS3ObjectUseStatementInfo `
                -AwsExe $awsExe `
                -Bucket $bucket `
                -Key $key `
                -SelectedDatabase $(if ($cmbDatabase.SelectedItem) { [string]$cmbDatabase.SelectedItem } else { [string]$cmbDatabase.Text }) `
                -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
                -UseProfile ([bool]$chkUseAwsProfile.Checked) `
                -ProfileName $txtAwsProfile.Text.Trim()
        } else {
            [pscustomobject]@{ UseDatabase=''; UseAction=''; UseCount=0 }
        }

        $result += [pscustomobject]@{
            Origin        = 'S3'
            DisplayName   = $key
            Source        = "s3://$bucket/$key"
            LastWriteTime = $modified
            Version       = $version
            UseDatabase   = $useInfo.UseDatabase
            UseAction     = $useInfo.UseAction
            Missing       = $missing
            Bucket        = $bucket
            Key           = $key
        }
    }

    Write-Log "Explicit S3 object list evaluated: $($result.Count) item(s)."

    return @($result | Sort-Object DisplayName -Unique)
}

function Get-CandidateItems {
    if ($rbS3.Checked) {
        return @(Get-S3CandidateItems)
    }

    return @(Get-FileSystemCandidateItems)
}

function Populate-ReviewGrid {
    param([array]$Items)

    $gridReview.Rows.Clear()

    foreach ($item in $Items) {
        $missing = [bool]$item.Missing
        $modified = if ($missing -or $item.LastWriteTime -eq [datetime]::MinValue) {
            if ($missing) { 'NOT FOUND' } else { '' }
        }
        else {
            ([datetime]$item.LastWriteTime).ToString('yyyy-MM-dd HH:mm:ss')
        }

        $version = ''
        if ($item.PSObject.Properties['Version']) {
            $version = [string]$item.Version
        }

        $useDatabase = if ($item.PSObject.Properties['UseDatabase']) { [string]$item.UseDatabase } else { '' }
        $useAction = if ($item.PSObject.Properties['UseAction']) { [string]$item.UseAction } else { '' }

        $rowIndex = $gridReview.Rows.Add(
            $true,
            $false,
            0,
            $item.Origin,
            $item.DisplayName,
            $version,
            $useDatabase,
            $useAction,
            $modified,
            $(if ($missing) { 'Missing' } else { 'Ready' })
        )

        $gridReview.Rows[$rowIndex].Tag = $item

        if ($missing) {
            $gridReview.Rows[$rowIndex].Cells[0].Value = $false
            $gridReview.Rows[$rowIndex].Cells[0].ReadOnly = $true
            $gridReview.Rows[$rowIndex].Cells[1].Value = $false
            $gridReview.Rows[$rowIndex].Cells[1].ReadOnly = $true
        }
    }

    Update-SequenceNumbers
    $lblReviewCount.Text = "Candidates: $($gridReview.Rows.Count)"
}

function Get-InitializationItems {
    $items = @()

    foreach ($row in $gridReview.Rows) {
        if ($row.IsNewRow) { continue }

        if ([bool]$row.Cells[1].Value) {
            $items += $row.Tag
        }
    }

    return $items
}

function Get-SelectedDeploymentItems {
    $items = @()

    foreach ($row in $gridReview.Rows) {
        if ($row.IsNewRow) { continue }

        if ([bool]$row.Cells[0].Value -and -not [bool]$row.Cells[1].Value) {
            $items += $row.Tag
        }
    }

    return $items
}

function Normalize-InitializationRows {
    $initRows = @()
    $otherRows = @()

    foreach ($row in @($gridReview.Rows)) {
        if ($row.IsNewRow) { continue }

        if ([bool]$row.Cells[1].Value) {
            $initRows += $row
        }
        else {
            $otherRows += $row
        }
    }

    if ($initRows.Count -eq 0) {
        Update-SequenceNumbers
        return
    }

    $orderedRows = @($initRows) + @($otherRows)
    $gridReview.Rows.Clear()

    foreach ($row in $orderedRows) {
        [void]$gridReview.Rows.Add($row)
    }

    Update-SequenceNumbers
}

function Update-SequenceNumbers {
    $sequence = 1
    foreach ($row in $gridReview.Rows) {
        if ($row.IsNewRow) { continue }
        $row.Cells[2].Value = $sequence
        $sequence++
    }
}

function Get-SelectedGridRow {
    if ($gridReview.SelectedRows.Count -gt 0) { return $gridReview.SelectedRows[0] }
    if ($gridReview.CurrentRow -and -not $gridReview.CurrentRow.IsNewRow) { return $gridReview.CurrentRow }
    return $null
}

function Move-GridRow {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.DataGridViewRow]$Row,
        [Parameter(Mandatory)][int]$NewIndex
    )

    if ($Row.IsNewRow) { return }
    if ($NewIndex -lt 0) { $NewIndex = 0 }
    $maxIndex = $gridReview.Rows.Count - 1
    if ($NewIndex -gt $maxIndex) { $NewIndex = $maxIndex }

    $oldIndex = $Row.Index
    if ($oldIndex -eq $NewIndex) { return }

    $gridReview.Rows.RemoveAt($oldIndex)
    if ($NewIndex -gt $gridReview.Rows.Count) { $NewIndex = $gridReview.Rows.Count }
    $gridReview.Rows.Insert($NewIndex, $Row)

    $gridReview.ClearSelection()
    $Row.Selected = $true
    if ($Row.Cells.Count -gt 2) { $gridReview.CurrentCell = $Row.Cells[4] }

    Update-SequenceNumbers
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}


function Convert-DeploymentSqlText {
    param(
        [Parameter(Mandatory)][string]$SqlText,
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$SelectedDatabase
    )

    return Convert-DDMSqlText `
        -SqlText $SqlText `
        -ServerInstance $ServerInstance `
        -SelectedDatabase $SelectedDatabase `
        -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
        -CreateOrAlter ([bool]$chkCreateOrAlter.Checked) `
        -DbMapServer $txtDbMapServer.Text.Trim() `
        -DbMapSource $txtDbMapSource.Text.Trim() `
        -DbMapReplacement $txtDbMapReplacement.Text.Trim()
}

function New-PreparedDeploymentFile {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$SelectedDatabase
    )

    return New-DDMPreparedSqlFile `
        -SourceFile $SourceFile `
        -ServerInstance $ServerInstance `
        -SelectedDatabase $SelectedDatabase `
        -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
        -CreateOrAlter ([bool]$chkCreateOrAlter.Checked) `
        -DbMapServer $txtDbMapServer.Text.Trim() `
        -DbMapSource $txtDbMapSource.Text.Trim() `
        -DbMapReplacement $txtDbMapReplacement.Text.Trim()
}

function Get-SqlCmdPath {
    param([string]$PreferredPath)
    return Get-DDMSqlCmdPath -PreferredPath $PreferredPath
}

function Invoke-SqlCmdText {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$SqlCmdExe,
        [int]$QueryTimeout = 120
    )

    return Invoke-DDMSqlCmdText `
        -ServerInstance $ServerInstance `
        -Database $Database `
        -Query $Query `
        -SqlCmdExe $SqlCmdExe `
        -QueryTimeout $QueryTimeout
}

function Invoke-SqlCmdFile {
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$SqlCmdExe,
        [int]$QueryTimeout = 120
    )

    return Invoke-DDMSqlCmdFile `
        -ServerInstance $ServerInstance `
        -Database $Database `
        -FilePath $FilePath `
        -SqlCmdExe $SqlCmdExe `
        -QueryTimeout $QueryTimeout
}

function Get-ReviewStatusColumnIndex {
    for ($i = 0; $i -lt $gridReview.Columns.Count; $i++) {
        if ($gridReview.Columns[$i].HeaderText -eq 'Status') {
            return $i
        }
    }

    return -1
}

function Update-ReviewAfterDeployment {
    param([Parameter(Mandatory)]$DeploymentResult)

    $statusColumn = Get-ReviewStatusColumnIndex

    foreach ($row in $gridReview.Rows) {
        if ($row.IsNewRow -or $null -eq $row.Tag) {
            continue
        }

        $item = $row.Tag
        $phase = if ([bool]$row.Cells[1].Value) { 'Initialization' } else { 'Deployment' }

        $matches = @(
            $DeploymentResult.ItemResults | Where-Object {
                $_.Phase -eq $phase -and
                [string]$_.Source -eq [string]$item.Source
            }
        )

        if ($matches.Count -eq 0) {
            continue
        }

        $failed = @($matches | Where-Object { -not $_.Success }).Count -gt 0

        if ($failed) {
            if ($phase -eq 'Initialization') {
                $row.Cells[1].Value = $true
                $row.Cells[0].Value = $false
            }
            else {
                $row.Cells[0].Value = $true
                $row.Cells[1].Value = $false
            }

            if ($statusColumn -ge 0) {
                $row.Cells[$statusColumn].Value = 'Error'
            }
        }
        else {
            if ($phase -eq 'Initialization') {
                $row.Cells[1].Value = $false
            }
            else {
                $row.Cells[0].Value = $false
            }

            if ($statusColumn -ge 0) {
                $row.Cells[$statusColumn].Value = 'Deployed'
            }
        }
    }
}

function Show-DeploymentErrors {
    param([Parameter(Mandatory)][array]$Errors)

    if ($Errors.Count -eq 0) {
        return
    }

    $errorForm = New-Object System.Windows.Forms.Form
    $errorForm.Text = "Deployment Errors - $($Errors.Count) error(s)"
    $errorForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $errorForm.Size = New-Object System.Drawing.Size(900, 600)
    $errorForm.MinimumSize = New-Object System.Drawing.Size(650, 400)

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Text = "$($Errors.Count) item error(s) were encountered. Successful items have been unchecked; failed items remain checked."
    $lblSummary.Location = New-Object System.Drawing.Point(15, 15)
    $lblSummary.Size = New-Object System.Drawing.Size(850, 35)
    $lblSummary.Anchor = 'Top,Left,Right'
    $errorForm.Controls.Add($lblSummary)

    $txtErrors = New-Object System.Windows.Forms.TextBox
    $txtErrors.Location = New-Object System.Drawing.Point(15, 55)
    $txtErrors.Size = New-Object System.Drawing.Size(850, 455)
    $txtErrors.Anchor = 'Top,Bottom,Left,Right'
    $txtErrors.Multiline = $true
    $txtErrors.ScrollBars = 'Both'
    $txtErrors.WordWrap = $false
    $txtErrors.ReadOnly = $true
    $txtErrors.Font = New-Object System.Drawing.Font('Consolas', 9)

    $errorLines = @()

    foreach ($err in $Errors) {
        $errorLines += @(
            ('=' * 100),
            "Server   : $($err.Server)",
            "Database : $($err.Database)",
            "Phase    : $($err.Phase)",
            "Item     : $($err.DisplayName)",
            "Source   : $($err.Source)",
            '',
            $err.Error,
            ''
        )
    }

    $txtErrors.Text = ($errorLines -join "`r`n")
    $errorForm.Controls.Add($txtErrors)

    $btnCopyErrors = New-Object System.Windows.Forms.Button
    $btnCopyErrors.Text = 'Copy Errors'
    $btnCopyErrors.Location = New-Object System.Drawing.Point(665, 520)
    $btnCopyErrors.Size = New-Object System.Drawing.Size(95, 30)
    $btnCopyErrors.Anchor = 'Bottom,Right'
    $btnCopyErrors.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($txtErrors.Text)
    })
    $errorForm.Controls.Add($btnCopyErrors)

    $btnCloseErrors = New-Object System.Windows.Forms.Button
    $btnCloseErrors.Text = 'Close'
    $btnCloseErrors.Location = New-Object System.Drawing.Point(770, 520)
    $btnCloseErrors.Size = New-Object System.Drawing.Size(95, 30)
    $btnCloseErrors.Anchor = 'Bottom,Right'
    $btnCloseErrors.Add_Click({ $errorForm.Close() })
    $errorForm.Controls.Add($btnCloseErrors)

    [void]$errorForm.ShowDialog($form)
}

function Get-DDMItemInferredRepositoryRoot {
    param(
        [Parameter(Mandatory)]$Item
    )

    if ([string]$Item.Origin -ne 'File System') {
        return $null
    }

    $source = ([string]$Item.Source).Trim()
    $display = ([string]$Item.DisplayName).Trim()

    if ([string]::IsNullOrWhiteSpace($source) -or
        [string]::IsNullOrWhiteSpace($display)) {
        return $null
    }

    try {
        $fullSource = [System.IO.Path]::GetFullPath($source)
    }
    catch {
        return $null
    }

    $normalizedDisplay = $display.Replace('/','\').TrimStart('\')
    $suffix = '\' + $normalizedDisplay

    if ($fullSource.EndsWith($suffix,[System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullSource.Substring(0,$fullSource.Length - $suffix.Length)
    }

    return $null
}

function Get-DDMGeneratedRepositoryRoot {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$ConfiguredRoot
    )

    $roots = @(
        $Items |
        Where-Object { [string]$_.Origin -eq 'File System' } |
        ForEach-Object { Get-DDMItemInferredRepositoryRoot -Item $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )

    if ($roots.Count -eq 1) {
        return [string]$roots[0]
    }

    if ($roots.Count -gt 1) {
        throw "Selected File System items resolve to more than one repository root: $($roots -join '; '). Refresh the review list from one repository root before generating the deployment script."
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredRoot)) {
        return $ConfiguredRoot.Trim()
    }

    return ''
}

function Get-DDMGeneratedRelativePath {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    if ([string]$Item.Origin -ne 'File System') {
        return [string]$Item.DisplayName
    }

    $source = ([string]$Item.Source).Trim()

    if ([string]::IsNullOrWhiteSpace($source)) {
        throw "Cannot generate portable path for [$($Item.DisplayName)] because its File System Source is empty. Refresh the review list before generating the deployment script."
    }

    $relative = Get-DDMRelativePath -Root $RepositoryRoot -FullPath $source

    # Get-DDMRelativePath returns the absolute path when Source is not under Root.
    if ([System.IO.Path]::IsPathRooted($relative)) {
        throw "Cannot make [$source] relative to generated RepositoryRoot [$RepositoryRoot]. Refresh the review list before generating the deployment script."
    }

    return $relative
}

function Build-DeploymentScript {
    $servers = @(Get-SelectedServers)
    $database = [string]$cmbDatabase.Text
    $initItems = @(Get-InitializationItems)
    $items = @(Get-SelectedDeploymentItems)
    $preferredSqlCmd = $txtSqlCmd.Text.Trim()
    $configuredRepositoryRoot = $txtRepoRoot.Text.Trim()
    $allSelectedItems = @($initItems) + @($items)
    $repositoryRoot = Get-DDMGeneratedRepositoryRoot `
        -Items $allSelectedItems `
        -ConfiguredRoot $configuredRepositoryRoot
    $commandTimeout = [int]$numTimeout.Value
    $awsProfile = if ($chkUseAwsProfile.Checked) { $txtAwsProfile.Text.Trim() } else { '' }
    $createOrAlter = [bool]$chkCreateOrAlter.Checked
    $manageUseStatements = [bool]$chkManageUseStatements.Checked
    $useManagementDefaultToTarget = [bool]$UseManagementDefaultToTarget
    $useManagementMappings = Get-UseManagementMappings
    $dbMapServer = $txtDbMapServer.Text.Trim()
    $dbMapSource = $txtDbMapSource.Text.Trim()
    $dbMapReplacement = $txtDbMapReplacement.Text.Trim()

    if (@($servers).Count -eq 0) {
        throw 'Select at least one target server.'
    }

    if ([string]::IsNullOrWhiteSpace($database)) {
        throw 'Select a target database.'
    }

    if (@($items).Count -eq 0 -and @($initItems).Count -eq 0) {
        throw 'No deployment or initialization items are selected.'
    }

    if (@($items | Where-Object { $_.Origin -eq 'S3' }).Count -gt 0 -and -not (Get-AwsCliPath)) {
        throw 'AWS CLI was not found. It is required to generate/run an S3 deployment.'
    }

    $serverLiteral = ($servers | ForEach-Object {
        "    $(Quote-PowerShellLiteral $_)"
    }) -join "`r`n"

    $initItemLiteral = ($initItems | ForEach-Object {
        $originValue = [string]$_.Origin
        $origin = Quote-PowerShellLiteral $originValue
        $sourceValue = [string]$_.Source
        $source = Quote-PowerShellLiteral $sourceValue
        $relativeValue = if ($originValue -eq 'File System') {
            Get-DDMGeneratedRelativePath -Item $_ -RepositoryRoot $repositoryRoot
        } else {
            [string]$_.DisplayName
        }
        $relative = Quote-PowerShellLiteral $relativeValue
        $display = Quote-PowerShellLiteral ([string]$_.DisplayName)
        "    [pscustomobject]@{ Origin = $origin; Source = $source; RelativePath = $relative; DisplayName = $display }"
    }) -join "`r`n"

    $itemLiteral = ($items | ForEach-Object {
        $originValue = [string]$_.Origin
        $origin = Quote-PowerShellLiteral $originValue
        $sourceValue = [string]$_.Source
        $source = Quote-PowerShellLiteral $sourceValue
        $relativeValue = if ($originValue -eq 'File System') {
            Get-DDMGeneratedRelativePath -Item $_ -RepositoryRoot $repositoryRoot
        } else {
            [string]$_.DisplayName
        }
        $relative = Quote-PowerShellLiteral $relativeValue
        $display = Quote-PowerShellLiteral ([string]$_.DisplayName)
        "    [pscustomobject]@{ Origin = $origin; Source = $source; RelativePath = $relative; DisplayName = $display }"
    }) -join "`r`n"

    $scriptText = @"
<#
.SYNOPSIS
    Database Deployment Manager - Generated Deployment Script

.VERSION
    1.0.0

.GENERATED
    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

.CHANGES
    2026-10-10 - v1.0.0
      - Initial public release.
#>

`$Servers = @(
$serverLiteral
)

`$Database = $(Quote-PowerShellLiteral $database)

# File System items are resolved at runtime from this root plus each item's
# generated RelativePath. This root is inferred from the selected candidates'
# actual Source + DisplayName, preventing duplicated folder segments when the
# GUI repository-root textbox has changed after the review was built.
# Edit this one value only if the same repository lives elsewhere on this host.
`$RepositoryRoot = $(Quote-PowerShellLiteral $repositoryRoot)

`$PreferredSqlCmdPath = $(Quote-PowerShellLiteral $preferredSqlCmd)
`$QueryTimeout = $commandTimeout
`$AwsProfile = $(Quote-PowerShellLiteral $awsProfile)
`$CreateOrAlter = `$$createOrAlter
`$ManageUseStatements = `$$manageUseStatements
`$DefaultToTargetDatabase = `$$useManagementDefaultToTarget
`$UseMappings = @{}
$(($useManagementMappings.GetEnumerator() | Sort-Object Key | ForEach-Object {
    "`$UseMappings[$(Quote-PowerShellLiteral ([string]$_.Key))] = $(Quote-PowerShellLiteral ([string]$_.Value))"
}) -join "`r`n")
`$DbMapServer = $(Quote-PowerShellLiteral $dbMapServer)
`$DbMapSource = $(Quote-PowerShellLiteral $dbMapSource)
`$DbMapReplacement = $(Quote-PowerShellLiteral $dbMapReplacement)

`$InitializationItems = @(
$initItemLiteral
)

`$Items = @(
$itemLiteral
)

function Get-SqlCmdPath {
    param([string]`$PreferredPath)

    if (-not [string]::IsNullOrWhiteSpace(`$PreferredPath)) {
        if (Test-Path -LiteralPath `$PreferredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath `$PreferredPath).Path
        }

        `$preferredCommand = Get-Command `$PreferredPath -ErrorAction SilentlyContinue
        if (`$null -ne `$preferredCommand) {
            return `$preferredCommand.Source
        }
    }

    `$Candidates = @(
        'sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\110\Tools\Binn\SQLCMD.EXE'
    )

    foreach (`$Candidate in `$Candidates) {
        `$Command = Get-Command `$Candidate -ErrorAction SilentlyContinue
        if (`$null -ne `$Command) {
            return `$Command.Source
        }
    }

    return `$null
}

function Get-AwsProfileArgs {
    if ([string]::IsNullOrWhiteSpace(`$AwsProfile)) {
        return @()
    }

    return @('--profile', `$AwsProfile)
}

function Get-AwsCliPath {
    `$Command = Get-Command 'aws.exe' -ErrorAction SilentlyContinue

    if (`$null -eq `$Command) {
        `$Command = Get-Command 'aws' -ErrorAction SilentlyContinue
    }

    if (`$null -eq `$Command) {
        return `$null
    }

    return `$Command.Source
}

`$SqlCmdExe = Get-SqlCmdPath -PreferredPath `$PreferredSqlCmdPath

if (-not `$SqlCmdExe) {
    throw 'sqlcmd.exe was not found on PATH or in the standard SQL client tool locations.'
}

`$UsesS3 = (
    @(`$Items | Where-Object { `$_.Origin -eq 'S3' }).Count -gt 0 -or
    @(`$InitializationItems | Where-Object { `$_.Origin -eq 'S3' }).Count -gt 0
)
`$AwsExe = `$null

if (`$UsesS3) {
    `$AwsExe = Get-AwsCliPath

    if (-not `$AwsExe) {
        throw 'AWS CLI was not found. S3 deployment requires aws.exe/aws in PATH.'
    }
}

function New-PreparedDeploymentFile {
    param([string]`$SourceFile,[string]`$ServerInstance,[string]`$SelectedDatabase)

    if ([string]::IsNullOrWhiteSpace(`$SourceFile)) {
        throw "New-PreparedDeploymentFile received an empty SourceFile path. This indicates a generated-script path-resolution defect before SQL preparation."
    }

    if (-not (Test-Path -LiteralPath `$SourceFile -PathType Leaf)) {
        throw "SQL source file not found: [`$SourceFile]"
    }

    `$SqlText = Get-Content -LiteralPath `$SourceFile -Raw

    # Manage USE: the selected Target database is authoritative.
    if (`$ManageUseStatements -and -not [string]::IsNullOrWhiteSpace(`$SelectedDatabase)) {
        `$UsePattern = '(?im)^\s*USE\s+(?:\[[^\]]+\]|[A-Za-z0-9_.$#@-]+)\s*;?\s*$'
        `$EscapedTargetDb = `$SelectedDatabase.Replace(']', ']]')
        `$TargetUse = "USE [`$EscapedTargetDb];"

        if ([regex]::IsMatch(`$SqlText, `$UsePattern)) {
            `$SqlText = [regex]::Replace(`$SqlText, `$UsePattern, `$TargetUse)
        }
        else {
            `$SqlText = "`$TargetUse`r`nGO`r`n" + `$SqlText
        }
    }

    # Persisted module SET-option guard. Explicit final OFF in the source is
    # preserved and warned about rather than silently overridden.
    `$ModulePattern = '(?im)^\s*(?:CREATE(?:\s+OR\s+ALTER)?|ALTER)\s+(?:PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\b'
    `$ModuleMatch = [regex]::Match(`$SqlText, `$ModulePattern)

    if (`$ModuleMatch.Success) {
        `$Prefix = `$SqlText.Substring(0, `$ModuleMatch.Index)
        `$ModuleAndRemainder = `$SqlText.Substring(`$ModuleMatch.Index)

        function Get-LastModuleSetting {
            param([string]`$PrefixText,[string]`$Name)
            `$Pattern = "(?im)^\s*SET\s+`$([regex]::Escape(`$Name))\s+(ON|OFF)\s*;?\s*`$"
            `$Matches = @([regex]::Matches(`$PrefixText, `$Pattern))
            if (`$Matches.Count -eq 0) { return '' }
            return ([string]`$Matches[`$Matches.Count - 1].Groups[1].Value).ToUpperInvariant()
        }

        `$AnsiSetting = Get-LastModuleSetting -PrefixText `$Prefix -Name 'ANSI_NULLS'
        `$QuotedSetting = Get-LastModuleSetting -PrefixText `$Prefix -Name 'QUOTED_IDENTIFIER'
        `$GuardLines = @()

        if (`$AnsiSetting -eq 'OFF') {
            Write-Warning "`$SourceFile explicitly sets ANSI_NULLS OFF before the module definition. OFF is being preserved."
        }
        else {
            `$GuardLines += 'SET ANSI_NULLS ON;'
            `$GuardLines += 'GO'
        }

        if (`$QuotedSetting -eq 'OFF') {
            Write-Warning "`$SourceFile explicitly sets QUOTED_IDENTIFIER OFF before the module definition. OFF is being preserved."
        }
        else {
            `$GuardLines += 'SET QUOTED_IDENTIFIER ON;'
            `$GuardLines += 'GO'
        }

        if (`$GuardLines.Count -gt 0) {
            if (`$Prefix.Length -gt 0 -and -not `$Prefix.EndsWith("`n") -and -not `$Prefix.EndsWith("`r")) {
                `$Prefix += "`r`n"
            }
            `$SqlText = `$Prefix + ((`$GuardLines -join "`r`n") + "`r`n") + `$ModuleAndRemainder
        }
    }

    if (`$CreateOrAlter) {
        `$SqlText = [regex]::Replace(
            `$SqlText,
            '(?im)^(\s*)CREATE\s+(?!OR\s+ALTER\s+)(PROCEDURE|PROC|VIEW)\b',
            '`$1CREATE OR ALTER `$2'
        )
    }

    if (-not [string]::IsNullOrWhiteSpace(`$DbMapServer) -and
        -not [string]::IsNullOrWhiteSpace(`$DbMapSource) -and
        -not [string]::IsNullOrWhiteSpace(`$DbMapReplacement) -and
        `$ServerInstance.Equals(`$DbMapServer,[System.StringComparison]::OrdinalIgnoreCase)) {

        `$Escaped = [regex]::Escape(`$DbMapSource)
        `$SqlText = [regex]::Replace(
            `$SqlText,
            `$Escaped,
            [System.Text.RegularExpressions.MatchEvaluator]{ param(`$m) `$DbMapReplacement },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    `$TempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("DDM_SQL_Prepared_" + [guid]::NewGuid().ToString('N') + '.sql')
    `$Utf8NoBom = New-Object System.Text.UTF8Encoding(`$false)
    [System.IO.File]::WriteAllText(`$TempFile, `$SqlText, `$Utf8NoBom)
    return `$TempFile
}

`$DeploymentErrors = @()

foreach (`$Server in `$Servers) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Target: `$Server / `$Database"
    Write-Host "SQLCMD: `$SqlCmdExe"
    Write-Host "============================================================"

    foreach (`$Item in `$InitializationItems) {
        `$ExecutionFile = `$null
        `$TempSqlFile = `$null
        `$PreparedFile = `$null

        try {
            if (`$Item.Origin -eq 'S3') {
                `$TempSqlFile = Join-Path ([System.IO.Path]::GetTempPath()) ("DDM_SQL_Init_" + [guid]::NewGuid().ToString('N') + '.sql')
                `$AwsArgs = @('s3','cp',`$Item.Source,`$TempSqlFile,'--only-show-errors') + @(Get-AwsProfileArgs)
                & `$AwsExe @AwsArgs

                if (`$LASTEXITCODE -ne 0) {
                    throw "AWS CLI failed while retrieving initialization item [`$(`$Item.Source)]. Exit code: `$LASTEXITCODE"
                }

                `$ExecutionFile = `$TempSqlFile
            }
            else {
                if ([string]::IsNullOrWhiteSpace(`$RepositoryRoot)) {
                    throw "RepositoryRoot is empty. Set `$RepositoryRoot near the top of this generated deployment script."
                }

                `$RelativePath = [string]`$Item.RelativePath
                if ([string]::IsNullOrWhiteSpace(`$RelativePath)) {
                    throw "RelativePath is empty for File System item [`$(`$Item.DisplayName)]. Original Source: [`$(`$Item.Source)]"
                }

                `$ExecutionFile = Join-Path -Path `$RepositoryRoot -ChildPath `$RelativePath

                if (-not (Test-Path -LiteralPath `$ExecutionFile -PathType Leaf)) {
                    throw "SQL source file not found: [`$ExecutionFile]. RepositoryRoot: [`$RepositoryRoot]. RelativePath: [`$RelativePath]. Original Source: [`$(`$Item.Source)]"
                }

                `$ExecutionFile = (Resolve-Path -LiteralPath `$ExecutionFile).Path

                if ([string]::IsNullOrWhiteSpace(`$ExecutionFile)) {
                    throw "Resolved File System path is empty for [`$(`$Item.DisplayName)]."
                }
            }

            `$PreparedFile = New-PreparedDeploymentFile -SourceFile `$ExecutionFile -ServerInstance `$Server -SelectedDatabase `$Database

            Write-Host "Initializing: `$(`$Item.DisplayName)"

            `$SqlCmdArgs = @(
                '-S', `$Server,
                '-d', `$Database,
                '-E',
                '-b',
                '-w', '65535',
                '-y', '0',
                '-Y', '0',
                '-i', `$PreparedFile,
                '-l', '30',
                '-t', `$QueryTimeout
            )

            `$Output = & `$SqlCmdExe @SqlCmdArgs 2>&1
            `$ExitCode = `$LASTEXITCODE

            if (`$Output) {
                `$Output | ForEach-Object { Write-Host `$_.ToString() }
            }

            if (`$ExitCode -ne 0) {
                throw "Initialization failed on [`$Server] while executing [`$(`$Item.DisplayName)]. sqlcmd.exe exit code: `$ExitCode"
            }
        }
        catch {
            `$DeploymentErrors += [pscustomobject]@{
                Server   = `$Server
                Database = `$Database
                Phase    = 'Initialization'
                Item     = `$Item.DisplayName
                Error    = `$_.Exception.Message
            }

            Write-Host "ERROR: Initialization failed for `$(`$Item.DisplayName) on `$Server"
            Write-Host `$_.Exception.Message
            Write-Host "Continuing with the next item..."
        }
        finally {
            if (`$PreparedFile -and (Test-Path -LiteralPath `$PreparedFile)) {
                Remove-Item -LiteralPath `$PreparedFile -Force -ErrorAction SilentlyContinue
            }

            if (`$TempSqlFile -and (Test-Path -LiteralPath `$TempSqlFile)) {
                Remove-Item -LiteralPath `$TempSqlFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach (`$Item in `$Items) {
        `$ExecutionFile = `$null
        `$TempSqlFile = `$null

        try {
            if (`$Item.Origin -eq 'S3') {
                `$TempSqlFile = Join-Path ([System.IO.Path]::GetTempPath()) ("DDM_SQL_Deploy_" + [guid]::NewGuid().ToString('N') + '.sql')

                Write-Host "Retrieving S3 object: `$(`$Item.Source)"
                `$AwsArgs = @('s3','cp',`$Item.Source,`$TempSqlFile,'--only-show-errors') + @(Get-AwsProfileArgs)
                & `$AwsExe @AwsArgs

                if (`$LASTEXITCODE -ne 0) {
                    throw "AWS CLI failed while retrieving [`$(`$Item.Source)]. Exit code: `$LASTEXITCODE"
                }

                `$ExecutionFile = `$TempSqlFile
            }
            else {
                if ([string]::IsNullOrWhiteSpace(`$RepositoryRoot)) {
                    throw "RepositoryRoot is empty. Set `$RepositoryRoot near the top of this generated deployment script."
                }

                `$RelativePath = [string]`$Item.RelativePath
                if ([string]::IsNullOrWhiteSpace(`$RelativePath)) {
                    throw "RelativePath is empty for File System item [`$(`$Item.DisplayName)]. Original Source: [`$(`$Item.Source)]"
                }

                `$ExecutionFile = Join-Path -Path `$RepositoryRoot -ChildPath `$RelativePath

                if (-not (Test-Path -LiteralPath `$ExecutionFile -PathType Leaf)) {
                    throw "SQL source file not found: [`$ExecutionFile]. RepositoryRoot: [`$RepositoryRoot]. RelativePath: [`$RelativePath]. Original Source: [`$(`$Item.Source)]"
                }

                `$ExecutionFile = (Resolve-Path -LiteralPath `$ExecutionFile).Path

                if ([string]::IsNullOrWhiteSpace(`$ExecutionFile)) {
                    throw "Resolved File System path is empty for [`$(`$Item.DisplayName)]."
                }
            }

            `$PreparedFile = New-PreparedDeploymentFile -SourceFile `$ExecutionFile -ServerInstance `$Server -SelectedDatabase `$Database

            Write-Host "Executing: `$(`$Item.DisplayName)"

            `$SqlCmdArgs = @(
                '-S', `$Server,
                '-d', `$Database,
                '-E',
                '-b',
                '-w', '65535',
                '-y', '0',
                '-Y', '0',
                '-i', `$PreparedFile,
                '-l', '30',
                '-t', `$QueryTimeout
            )

            `$Output = & `$SqlCmdExe @SqlCmdArgs 2>&1
            `$ExitCode = `$LASTEXITCODE

            if (`$Output) {
                `$Output | ForEach-Object { Write-Host `$_.ToString() }
            }

            if (`$ExitCode -ne 0) {
                throw "Deployment failed on [`$Server] while executing [`$(`$Item.DisplayName)]. sqlcmd.exe exit code: `$ExitCode"
            }
        }
        catch {
            `$DeploymentErrors += [pscustomobject]@{
                Server   = `$Server
                Database = `$Database
                Phase    = 'Deployment'
                Item     = `$Item.DisplayName
                Error    = `$_.Exception.Message
            }

            Write-Host "ERROR: Deployment failed for `$(`$Item.DisplayName) on `$Server"
            Write-Host `$_.Exception.Message
            Write-Host "Continuing with the next item..."
        }
        finally {
            if (`$PreparedFile -and (Test-Path -LiteralPath `$PreparedFile)) {
                Remove-Item -LiteralPath `$PreparedFile -Force -ErrorAction SilentlyContinue
            }

            if (`$TempSqlFile -and (Test-Path -LiteralPath `$TempSqlFile)) {
                Remove-Item -LiteralPath `$TempSqlFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host ""

if (`$DeploymentErrors.Count -eq 0) {
    Write-Host "Deployment completed successfully."
}
else {
    Write-Host "Deployment completed with `$(`$DeploymentErrors.Count) error(s)."
    Write-Host ""
    Write-Host "==================== DEPLOYMENT ERRORS ===================="

    foreach (`$DeploymentError in `$DeploymentErrors) {
        Write-Host ""
        Write-Host "Server   : `$(`$DeploymentError.Server)"
        Write-Host "Database : `$(`$DeploymentError.Database)"
        Write-Host "Phase    : `$(`$DeploymentError.Phase)"
        Write-Host "Item     : `$(`$DeploymentError.Item)"
        Write-Host `$DeploymentError.Error
    }
}
"@

    return $scriptText
}

function Validate-ImmediateDeployment {
    $servers = @(Get-SelectedServers)
    $database = [string]$cmbDatabase.Text
    $initItems = @(Get-InitializationItems)
    $items = @(Get-SelectedDeploymentItems)

    if (@($servers).Count -eq 0) {
        throw 'Select at least one target server.'
    }

    if ([string]::IsNullOrWhiteSpace($database)) {
        throw 'Select a target database.'
    }

    if (@($items).Count -eq 0 -and @($initItems).Count -eq 0) {
        throw 'No deployment or initialization items are selected.'
    }

    $allSelectedItems = @($initItems) + @($items)

    $missingLocal = @(
        $allSelectedItems | Where-Object {
            $_.Origin -eq 'File System' -and
            -not (Test-Path -LiteralPath $_.Source -PathType Leaf)
        }
    )

    if (@($missingLocal).Count -gt 0) {
        throw 'One or more selected File System items do not exist.'
    }

    $sqlCmdExe = Get-SqlCmdPath -PreferredPath $txtSqlCmd.Text.Trim()

    if (-not $sqlCmdExe) {
        throw 'sqlcmd.exe was not found on PATH or in the standard SQL client tool locations.'
    }

    $usesS3 = @($allSelectedItems | Where-Object { $_.Origin -eq 'S3' }).Count -gt 0
    $awsExe = $null

    if ($usesS3) {
        $awsExe = Get-AwsCliPath

        if (-not $awsExe) {
            throw 'AWS CLI was not found. S3 deployment requires aws.exe/aws in PATH.'
        }
    }

    return [pscustomobject]@{
        SqlCmdExe = $sqlCmdExe
        AwsExe    = $awsExe
    }
}

# ============================================================
# MAIN FORM
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Database Deployment Manager'
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1000, 650)

# Size the application from the actual usable Windows desktop rather than
# assuming a particular monitor size or resolution.
$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$isLargeDisplay = ($workingArea.Width -ge 1600 -and $workingArea.Height -ge 900)

$defaultWidth  = [Math]::Min($workingArea.Width,  [Math]::Max(1000, [int]($workingArea.Width  * 0.94)))
$defaultHeight = [Math]::Min($workingArea.Height, [Math]::Max(650,  [int]($workingArea.Height * 0.94)))

$restoreSavedLayout = $false

if ($SavedState -and
    $SavedState.WindowWidth -and
    $SavedState.WindowHeight -and
    [int]$SavedState.WindowWidth -ge 1000 -and
    [int]$SavedState.WindowHeight -ge 650) {

    $savedWidth  = [Math]::Min([int]$SavedState.WindowWidth,  $workingArea.Width)
    $savedHeight = [Math]::Min([int]$SavedState.WindowHeight, $workingArea.Height)

    $form.Size = New-Object System.Drawing.Size($savedWidth, $savedHeight)

    if ($null -ne $SavedState.WindowX -and $null -ne $SavedState.WindowY) {
        $savedX = [int]$SavedState.WindowX
        $savedY = [int]$SavedState.WindowY

        # Restore only when at least part of the saved window remains on screen.
        if ($savedX -lt $workingArea.Right -and
            $savedY -lt $workingArea.Bottom -and
            ($savedX + 100) -gt $workingArea.Left -and
            ($savedY + 100) -gt $workingArea.Top) {

            $form.StartPosition = 'Manual'
            $form.Location = New-Object System.Drawing.Point($savedX, $savedY)
        }
    }

    $restoreSavedLayout = $true
}
else {
    $form.Size = New-Object System.Drawing.Size($defaultWidth, $defaultHeight)
}

# On the first run, make good use of a large desktop. Once the user has resized
# the application, the saved layout takes precedence on later runs.
if (-not $restoreSavedLayout -and $isLargeDisplay) {
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
}
elseif ($SavedState -and $SavedState.WindowState -eq 'Maximized') {
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
}

# Main split: settings on left, review/log on right.
$splitMain = New-Object System.Windows.Forms.SplitContainer
$splitMain.Dock = 'Fill'
$splitMain.Orientation = 'Vertical'
$splitMain.SplitterWidth = 8
$splitMain.BackColor = [System.Drawing.SystemColors]::ControlDark
$splitMain.Panel1.BackColor = [System.Drawing.SystemColors]::Control
$splitMain.Panel2.BackColor = [System.Drawing.SystemColors]::Control
$form.Controls.Add($splitMain)

# Visual grip on the main left/right splitter.
$splitMain.Add_Paint({
    param($sender, $e)

    $r = $splitMain.SplitterRectangle
    $cx = $r.Left + [int]($r.Width / 2)
    $cy = $r.Top + [int]($r.Height / 2)

    for ($offset = -8; $offset -le 8; $offset += 4) {
        $e.Graphics.DrawLine(
            [System.Drawing.SystemPens]::ControlDarkDark,
            $cx - 1,
            $cy + $offset,
            $cx + 1,
            $cy + $offset
        )
    }
})

# ============================================================
# LEFT PANEL
# ============================================================

$left = $splitMain.Panel1
$left.AutoScroll = $true

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Deployment Settings'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(15, 15)
$lblTitle.AutoSize = $true
$left.Controls.Add($lblTitle)

# Host / database value set
$lblValueSet = New-Object System.Windows.Forms.Label
$lblValueSet.Text = 'Value set'
$lblValueSet.Location = New-Object System.Drawing.Point(15, 46)
$lblValueSet.AutoSize = $true
$left.Controls.Add($lblValueSet)

$lblValueSetValue = New-Object System.Windows.Forms.Label
$lblValueSetValue.Text = $DefaultValueSet
$lblValueSetValue.Location = New-Object System.Drawing.Point(78, 46)
$lblValueSetValue.Size = New-Object System.Drawing.Size(220, 20)
$left.Controls.Add($lblValueSetValue)

$btnValueSet = New-Object System.Windows.Forms.Button
$btnValueSet.Text = '...'
$btnValueSet.Location = New-Object System.Drawing.Point(307, 40)
$btnValueSet.Size = New-Object System.Drawing.Size(45, 28)
$left.Controls.Add($btnValueSet)

$ctxValueSet = New-Object System.Windows.Forms.ContextMenuStrip

foreach ($setName in @($AppConfig.ValueSets.Keys | Sort-Object)) {
    $setItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $setItem.Text = [string]$setName
    $setItem.Tag = [string]$setName
    $setItem.Add_Click({
        param($sender, $eventArgs)
        Apply-ValueSet -SetName ([string]$sender.Tag)
    })
    [void]$ctxValueSet.Items.Add($setItem)
}

[void]$ctxValueSet.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$editConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem
$editConfigItem.Text = 'Edit config file...'
$editConfigItem.Add_Click({
    try {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $ConfigPath + '"')
        Write-Log 'Config file opened for editing. Restart Database Deployment Manager to load the changes.' 'Warning'
    }
    catch {
        Write-Log "Unable to open the config file: $($_.Exception.Message)" 'Error'
    }
})
[void]$ctxValueSet.Items.Add($editConfigItem)

$btnValueSet.Add_Click({
    $point = New-Object System.Drawing.Point(0, $btnValueSet.Height)
    $ctxValueSet.Show($btnValueSet, $point)
})

# Source
$grpOrigin = New-Object System.Windows.Forms.GroupBox
$grpOrigin.Text = 'Source'
$grpOrigin.Location = New-Object System.Drawing.Point(15, 75)
$grpOrigin.Size = New-Object System.Drawing.Size(337, 55)
$grpOrigin.Anchor = 'Top,Left'
$left.Controls.Add($grpOrigin)

$lblOrigin = New-Object System.Windows.Forms.Label
$lblOrigin.Text = 'Source'
$lblOrigin.Location = New-Object System.Drawing.Point(15, 24)
$lblOrigin.AutoSize = $true
$grpOrigin.Controls.Add($lblOrigin)

$cmbOrigin = New-Object System.Windows.Forms.ComboBox
$cmbOrigin.Location = New-Object System.Drawing.Point(65, 20)
$cmbOrigin.Size = New-Object System.Drawing.Size(145, 24)
$cmbOrigin.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$cmbOrigin.Items.Add('File System')
[void]$cmbOrigin.Items.Add('AWS S3')
$grpOrigin.Controls.Add($cmbOrigin)

$chkCheckVersion = New-Object System.Windows.Forms.CheckBox
$chkCheckVersion.Text = 'Check version'
$chkCheckVersion.Location = New-Object System.Drawing.Point(220, 21)
$chkCheckVersion.AutoSize = $true
$chkCheckVersion.Checked = $false
$grpOrigin.Controls.Add($chkCheckVersion)

# Compatibility state used internally by the existing candidate-discovery code.
# These controls are intentionally not added to the GUI.
$rbFileSystem = New-Object System.Windows.Forms.RadioButton
$rbS3 = New-Object System.Windows.Forms.RadioButton

# Source
$grpSource = New-Object System.Windows.Forms.GroupBox
$grpSource.Text = 'File System source'
$grpSource.Location = New-Object System.Drawing.Point(15, 138)
$grpSource.Size = New-Object System.Drawing.Size(337, 150)
$grpSource.Anchor = 'Top,Left'
$left.Controls.Add($grpSource)

$lblRepo = New-Object System.Windows.Forms.Label
$lblRepo.Text = 'Repository root'
$lblRepo.Location = New-Object System.Drawing.Point(15, 20)
$lblRepo.AutoSize = $true
$grpSource.Controls.Add($lblRepo)

$txtRepoRoot = New-Object System.Windows.Forms.TextBox
$txtRepoRoot.Location = New-Object System.Drawing.Point(15, 43)
$txtRepoRoot.Size = New-Object System.Drawing.Size(265, 24)
$txtRepoRoot.Anchor = 'Top,Left'
$txtRepoRoot.Text = if ($SavedState -and $SavedState.RepoRoot) { $SavedState.RepoRoot } else { $DefaultRepoRoot }
$grpSource.Controls.Add($txtRepoRoot)

$btnBrowseRepo = New-Object System.Windows.Forms.Button
$btnBrowseRepo.Text = '...'
$btnBrowseRepo.Location = New-Object System.Drawing.Point(286, 41)
$btnBrowseRepo.Size = New-Object System.Drawing.Size(36, 28)
$btnBrowseRepo.Anchor = 'Top,Left'
$grpSource.Controls.Add($btnBrowseRepo)

$lblS3Bucket = New-Object System.Windows.Forms.Label
$lblS3Bucket.Text = 'S3 bucket'
$lblS3Bucket.Location = New-Object System.Drawing.Point(15, 20)
$lblS3Bucket.AutoSize = $true
$grpSource.Controls.Add($lblS3Bucket)

$cmbS3Bucket = New-Object System.Windows.Forms.ComboBox
$cmbS3Bucket.Location = New-Object System.Drawing.Point(15, 42)
$cmbS3Bucket.Size = New-Object System.Drawing.Size(205, 24)
$cmbS3Bucket.DropDownStyle = 'DropDown'
$cmbS3Bucket.Text = if ($SavedState -and $SavedState.S3Bucket) { [string]$SavedState.S3Bucket } else { '' }
$grpSource.Controls.Add($cmbS3Bucket)

$btnListBuckets = New-Object System.Windows.Forms.Button
$btnListBuckets.Text = 'List Buckets'
$btnListBuckets.Location = New-Object System.Drawing.Point(226, 40)
$btnListBuckets.Size = New-Object System.Drawing.Size(96, 28)
$grpSource.Controls.Add($btnListBuckets)

$lblS3Prefix = New-Object System.Windows.Forms.Label
$lblS3Prefix.Text = 'Prefix (optional)'
$lblS3Prefix.Location = New-Object System.Drawing.Point(15, 72)
$lblS3Prefix.AutoSize = $true
$grpSource.Controls.Add($lblS3Prefix)

$txtS3Prefix = New-Object System.Windows.Forms.TextBox
$txtS3Prefix.Location = New-Object System.Drawing.Point(110, 69)
$txtS3Prefix.Size = New-Object System.Drawing.Size(212, 24)
$txtS3Prefix.Text = if ($SavedState -and $null -ne $SavedState.S3Prefix) { [string]$SavedState.S3Prefix } else { '' }
$grpSource.Controls.Add($txtS3Prefix)

$chkUseAwsProfile = New-Object System.Windows.Forms.CheckBox
$chkUseAwsProfile.Location = New-Object System.Drawing.Point(15, 99)
$chkUseAwsProfile.Size = New-Object System.Drawing.Size(18, 20)
$chkUseAwsProfile.Checked = if ($SavedState -and $null -ne $SavedState.UseAwsProfile) {
    [bool]$SavedState.UseAwsProfile
}
else {
    $true
}
$grpSource.Controls.Add($chkUseAwsProfile)

$lblAwsProfile = New-Object System.Windows.Forms.Label
$lblAwsProfile.Text = 'AWS profile'
$lblAwsProfile.Location = New-Object System.Drawing.Point(38, 100)
$lblAwsProfile.AutoSize = $true
$grpSource.Controls.Add($lblAwsProfile)

$txtAwsProfile = New-Object System.Windows.Forms.TextBox
$txtAwsProfile.Location = New-Object System.Drawing.Point(110, 97)
$txtAwsProfile.Size = New-Object System.Drawing.Size(212, 24)
$txtAwsProfile.Text = if ($SavedState -and $SavedState.AwsProfile) { [string]$SavedState.AwsProfile } else { $DefaultDevAwsProfile }
$grpSource.Controls.Add($txtAwsProfile)

$chkSqlOnly = New-Object System.Windows.Forms.CheckBox
$chkSqlOnly.Text = 'SQL files only'
$chkSqlOnly.Location = New-Object System.Drawing.Point(15, 124)
$chkSqlOnly.AutoSize = $true
$chkSqlOnly.Checked = $true
$grpSource.Controls.Add($chkSqlOnly)

if ($SavedState -and $SavedState.Origin -eq 'S3') {
    $cmbOrigin.SelectedItem = 'AWS S3'
    $rbS3.Checked = $true
    $rbFileSystem.Checked = $false
}
else {
    $cmbOrigin.SelectedItem = 'File System'
    $rbFileSystem.Checked = $true
    $rbS3.Checked = $false
}

# Detection mode
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'Detection mode'
$grpMode.Location = New-Object System.Drawing.Point(15, 296)
$grpMode.Size = New-Object System.Drawing.Size(337, 245)
$grpMode.Anchor = 'Top,Left'
$left.Controls.Add($grpMode)

$rbDate = New-Object System.Windows.Forms.RadioButton
$rbDate.Text = 'Modified since date/time'
$rbDate.Location = New-Object System.Drawing.Point(15, 28)
$rbDate.AutoSize = $true
$grpMode.Controls.Add($rbDate)

$dtpDetection = New-Object System.Windows.Forms.DateTimePicker
$dtpDetection.Location = New-Object System.Drawing.Point(15, 55)
$dtpDetection.Size = New-Object System.Drawing.Size(295, 24)
$dtpDetection.Format = 'Custom'
$dtpDetection.CustomFormat = 'yyyy-MM-dd HH:mm:ss'
$dtpDetection.ShowUpDown = $false

if ($SavedState -and $SavedState.DetectionDate) {
    try { $dtpDetection.Value = [datetime]$SavedState.DetectionDate }
    catch { $dtpDetection.Value = $DefaultDetectionDate }
}
else {
    $dtpDetection.Value = $DefaultDetectionDate
}
$grpMode.Controls.Add($dtpDetection)

$chkIgnoreFileDate = New-Object System.Windows.Forms.CheckBox
$chkIgnoreFileDate.Text = 'Ignore modification date'
$chkIgnoreFileDate.Location = New-Object System.Drawing.Point(15, 83)
$chkIgnoreFileDate.AutoSize = $true
$chkIgnoreFileDate.Checked = $false
$grpMode.Controls.Add($chkIgnoreFileDate)

$rbList = New-Object System.Windows.Forms.RadioButton
$rbList.Text = 'Explicit file list'
$rbList.Location = New-Object System.Drawing.Point(15, 115)
$rbList.AutoSize = $true
$grpMode.Controls.Add($rbList)

$txtExplicitList = New-Object System.Windows.Forms.TextBox
$txtExplicitList.Location = New-Object System.Drawing.Point(15, 142)
$txtExplicitList.Size = New-Object System.Drawing.Size(295, 92)
$txtExplicitList.Multiline = $true
$txtExplicitList.ScrollBars = 'Vertical'
$txtExplicitList.AcceptsReturn = $true
$txtExplicitList.AcceptsTab = $false
$txtExplicitList.Text = if ($SavedState -and $null -ne $SavedState.ExplicitList) { [string]$SavedState.ExplicitList } else { '' }
$grpMode.Controls.Add($txtExplicitList)

if ($SavedState -and $SavedState.DetectionMode -eq 'List') {
    $rbList.Checked = $true
}
else {
    $rbDate.Checked = $true
}

# Deployment transformations
$grpTransforms = New-Object System.Windows.Forms.GroupBox
$grpTransforms.Text = 'Deployment transformations'
$grpTransforms.Location = New-Object System.Drawing.Point(15, 552)
$grpTransforms.Size = New-Object System.Drawing.Size(337, 145)
$grpTransforms.Anchor = 'Top,Left'
$left.Controls.Add($grpTransforms)

$chkCreateOrAlter = New-Object System.Windows.Forms.CheckBox
$chkCreateOrAlter.Text = 'Convert CREATE PROC/PROCEDURE/VIEW to CREATE OR ALTER'
$chkCreateOrAlter.Location = New-Object System.Drawing.Point(12, 25)
$chkCreateOrAlter.Size = New-Object System.Drawing.Size(315, 28)
$chkCreateOrAlter.Checked = if ($SavedState -and $null -ne $SavedState.CreateOrAlter) { [bool]$SavedState.CreateOrAlter } else { $true }
$grpTransforms.Controls.Add($chkCreateOrAlter)

$chkManageUseStatements = New-Object System.Windows.Forms.CheckBox
$chkManageUseStatements.Text = 'Manage USE statements for target database'
$chkManageUseStatements.Location = New-Object System.Drawing.Point(12, 51)
$chkManageUseStatements.Size = New-Object System.Drawing.Size(315, 24)
$chkManageUseStatements.Checked = if ($SavedState -and $null -ne $SavedState.ManageUseStatements) {
    [bool]$SavedState.ManageUseStatements
}
else {
    $true
}
$grpTransforms.Controls.Add($chkManageUseStatements)

# Database-name substitution: 3 columns x 2 rows.
# Row 1 = labels; Row 2 = editable values.
$lblDbMapServer = New-Object System.Windows.Forms.Label
$lblDbMapServer.Text = 'Server'
$lblDbMapServer.Location = New-Object System.Drawing.Point(12, 82)
$lblDbMapServer.Size = New-Object System.Drawing.Size(82, 18)
$grpTransforms.Controls.Add($lblDbMapServer)

$lblDbMapSource = New-Object System.Windows.Forms.Label
$lblDbMapSource.Text = 'Default DB'
$lblDbMapSource.Location = New-Object System.Drawing.Point(101, 82)
$lblDbMapSource.Size = New-Object System.Drawing.Size(94, 18)
$grpTransforms.Controls.Add($lblDbMapSource)

$lblDbMapReplacement = New-Object System.Windows.Forms.Label
$lblDbMapReplacement.Text = 'Replace DB'
$lblDbMapReplacement.Location = New-Object System.Drawing.Point(202, 82)
$lblDbMapReplacement.Size = New-Object System.Drawing.Size(123, 18)
$grpTransforms.Controls.Add($lblDbMapReplacement)

$txtDbMapServer = New-Object System.Windows.Forms.TextBox
$txtDbMapServer.Location = New-Object System.Drawing.Point(12, 102)
$txtDbMapServer.Size = New-Object System.Drawing.Size(82, 24)
$txtDbMapServer.Text = if ($SavedState -and $SavedState.DbMapServer) { [string]$SavedState.DbMapServer } else { $DefaultDbMapServer }
$grpTransforms.Controls.Add($txtDbMapServer)

$txtDbMapSource = New-Object System.Windows.Forms.TextBox
$txtDbMapSource.Location = New-Object System.Drawing.Point(101, 102)
$txtDbMapSource.Size = New-Object System.Drawing.Size(94, 24)
$txtDbMapSource.Text = if ($SavedState -and $SavedState.DbMapSource) { [string]$SavedState.DbMapSource } else { $DefaultDbMapSource }
$grpTransforms.Controls.Add($txtDbMapSource)

$txtDbMapReplacement = New-Object System.Windows.Forms.TextBox
$txtDbMapReplacement.Location = New-Object System.Drawing.Point(202, 102)
$txtDbMapReplacement.Size = New-Object System.Drawing.Size(123, 24)
$txtDbMapReplacement.Text = if ($SavedState -and $SavedState.DbMapReplacement) { [string]$SavedState.DbMapReplacement } else { $DefaultDbMapReplacement }
$grpTransforms.Controls.Add($txtDbMapReplacement)

# Servers
$lblServers = New-Object System.Windows.Forms.Label
$lblServers.Text = 'Target server(s)'
$lblServers.Location = New-Object System.Drawing.Point(15, 709)
$lblServers.AutoSize = $true
$left.Controls.Add($lblServers)

# Compact dropdown-style multi-select server picker.
# Each server is individually checkable. There is intentionally no Select All.
$btnServerDropdown = New-Object System.Windows.Forms.Button
$btnServerDropdown.Text = 'Select target server(s)...'
$btnServerDropdown.Location = New-Object System.Drawing.Point(15, 732)
$btnServerDropdown.Size = New-Object System.Drawing.Size(337, 30)
$btnServerDropdown.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$btnServerDropdown.Anchor = 'Top,Left'
$left.Controls.Add($btnServerDropdown)

$ctxServers = New-Object System.Windows.Forms.ContextMenuStrip
$ctxServers.ShowCheckMargin = $true
$ctxServers.ShowImageMargin = $false

# Keep the server selector open while the operator checks/unchecks
# multiple servers. It is closed explicitly with Done or by clicking
# the selector button again.
$ctxServers.AutoClose = $false

$script:ServerMenuItems = @()

$btnServerDropdown.Add_Click({
    if ($ctxServers.Visible) {
        $ctxServers.Close()
    }
    else {
        $point = New-Object System.Drawing.Point(0, $btnServerDropdown.Height)
        $ctxServers.Show($btnServerDropdown, $point)
    }
})

# Database
$lblDatabase = New-Object System.Windows.Forms.Label
$lblDatabase.Text = 'Target database'
$lblDatabase.Location = New-Object System.Drawing.Point(15, 774)
$lblDatabase.AutoSize = $true
$left.Controls.Add($lblDatabase)

$cmbDatabase = New-Object System.Windows.Forms.ComboBox
$cmbDatabase.Location = New-Object System.Drawing.Point(15, 797)
$cmbDatabase.Size = New-Object System.Drawing.Size(337, 25)
$cmbDatabase.DropDownStyle = 'DropDown'
$cmbDatabase.Anchor = 'Top,Left'

# Populated after the selected value set is applied.
$left.Controls.Add($cmbDatabase)

# SQLCMD
$lblSqlCmd = New-Object System.Windows.Forms.Label
$lblSqlCmd.Text = 'SQLCMD executable / path'
$lblSqlCmd.Location = New-Object System.Drawing.Point(15, 834)
$lblSqlCmd.AutoSize = $true
$left.Controls.Add($lblSqlCmd)

$txtSqlCmd = New-Object System.Windows.Forms.TextBox
$txtSqlCmd.Location = New-Object System.Drawing.Point(15, 857)
$txtSqlCmd.Size = New-Object System.Drawing.Size(337, 24)
$txtSqlCmd.Anchor = 'Top,Left'

if ($SavedState -and $SavedState.SqlCmdPath) {
    $txtSqlCmd.Text = [string]$SavedState.SqlCmdPath
}
else {
    $detectedSqlCmd = Get-SqlCmdPath -PreferredPath $DefaultSqlCmdPath
    $txtSqlCmd.Text = if ($detectedSqlCmd) { $detectedSqlCmd } else { 'sqlcmd.exe' }
}
$left.Controls.Add($txtSqlCmd)

$lblTimeout = New-Object System.Windows.Forms.Label
$lblTimeout.Text = 'Query timeout (seconds)'
$lblTimeout.Location = New-Object System.Drawing.Point(15, 892)
$lblTimeout.AutoSize = $true
$left.Controls.Add($lblTimeout)

$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Location = New-Object System.Drawing.Point(15, 915)
$numTimeout.Size = New-Object System.Drawing.Size(120, 24)
$numTimeout.Minimum = 1
$numTimeout.Maximum = 86400
$numTimeout.Value = if ($SavedState -and $null -ne $SavedState.CommandTimeout -and [int]$SavedState.CommandTimeout -gt 0) {
    [decimal]$SavedState.CommandTimeout
}
else {
    [decimal]$DefaultCommandTimeout
}
$left.Controls.Add($numTimeout)

$lblPlatform = New-Object System.Windows.Forms.Label
$lblPlatform.Text = 'Platform'
$lblPlatform.Location = New-Object System.Drawing.Point(155, 892)
$lblPlatform.AutoSize = $true
$left.Controls.Add($lblPlatform)

$cmbPlatform = New-Object System.Windows.Forms.ComboBox
$cmbPlatform.Location = New-Object System.Drawing.Point(155, 915)
$cmbPlatform.Size = New-Object System.Drawing.Size(197, 24)
$cmbPlatform.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

foreach ($platformName in $ConfiguredPlatforms) {
    if (-not [string]::IsNullOrWhiteSpace([string]$platformName)) {
        [void]$cmbPlatform.Items.Add([string]$platformName)
    }
}

$initialPlatform = if ($SavedState -and $SavedState.Platform -and
    $cmbPlatform.Items.Contains([string]$SavedState.Platform)) {
    [string]$SavedState.Platform
}
else {
    $DefaultPlatform
}

if ($cmbPlatform.Items.Contains($initialPlatform)) {
    $cmbPlatform.SelectedItem = $initialPlatform
}
elseif ($cmbPlatform.Items.Count -gt 0) {
    $cmbPlatform.SelectedIndex = 0
}

$left.Controls.Add($cmbPlatform)

$btnTestConnection = New-Object System.Windows.Forms.Button
$btnTestConnection.Text = 'Test Connection'
$btnTestConnection.Location = New-Object System.Drawing.Point(15, 952)
$btnTestConnection.Size = New-Object System.Drawing.Size(160, 36)
$btnTestConnection.Anchor = 'Top,Left'
$left.Controls.Add($btnTestConnection)

$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Text = 'Build / Refresh Review'
$btnDetect.Location = New-Object System.Drawing.Point(182, 952)
$btnDetect.Size = New-Object System.Drawing.Size(170, 36)
$btnDetect.Anchor = 'Top,Left'
$left.Controls.Add($btnDetect)

# ============================================================
# RIGHT PANEL
# ============================================================

$right = $splitMain.Panel2

# Right-side workspace:
#   Panel1 = review grid + review/order/deployment controls
#   Panel2 = generated script / deployment log
# The splitter is draggable, allowing each operator to choose the balance.
$splitRight = New-Object System.Windows.Forms.SplitContainer
$splitRight.Dock = 'Fill'
$splitRight.Orientation = 'Horizontal'
$splitRight.SplitterWidth = 9
$splitRight.BackColor = [System.Drawing.SystemColors]::ControlDark
$splitRight.Panel1.BackColor = [System.Drawing.SystemColors]::Control
$splitRight.Panel2.BackColor = [System.Drawing.SystemColors]::Control
$right.Controls.Add($splitRight)

# Visible horizontal grip so the operator can immediately see that this
# boundary is draggable.
$splitRight.Add_Paint({
    param($sender, $e)

    $r = $splitRight.SplitterRectangle
    $cx = $r.Left + [int]($r.Width / 2)
    $cy = $r.Top + [int]($r.Height / 2)

    for ($offset = -12; $offset -le 12; $offset += 6) {
        $e.Graphics.DrawLine(
            [System.Drawing.SystemPens]::ControlDarkDark,
            $cx + $offset - 2,
            $cy,
            $cx + $offset + 2,
            $cy
        )
    }
})

$reviewPanel = $splitRight.Panel1
$outputPanel = $splitRight.Panel2

$lblReview = New-Object System.Windows.Forms.Label
$lblReview.Text = 'Pre-deployment Review'
$lblReview.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblReview.Location = New-Object System.Drawing.Point(15, 15)
$lblReview.AutoSize = $true
$reviewPanel.Controls.Add($lblReview)

$lblReviewCount = New-Object System.Windows.Forms.Label
$lblReviewCount.Text = 'Candidates: 0'
$lblReviewCount.Location = New-Object System.Drawing.Point(15, 46)
$lblReviewCount.AutoSize = $true
$reviewPanel.Controls.Add($lblReviewCount)

$lblLoading = New-Object System.Windows.Forms.Label
$lblLoading.Text = 'Loading...'
$lblLoading.Location = New-Object System.Drawing.Point(130, 45)
$lblLoading.AutoSize = $true
$lblLoading.Font = New-Object System.Drawing.Font(
    'Segoe UI',
    9,
    [System.Drawing.FontStyle]::Bold
)
$lblLoading.Visible = $false
$reviewPanel.Controls.Add($lblLoading)

$script:BusyFrame = 0
$script:LoadingForm = $null

function Start-LoadingIndicator {
    $script:BusyFrame = 0

    # Inline status remains useful when the progress dialog is behind another
    # window or the application is viewed over RDP.
    $lblLoading.Text = 'Loading...'
    $lblLoading.Visible = $true

    # Use the standard Windows busy cursor throughout the application.
    $form.UseWaitCursor = $true
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    # A small modeless progress window provides a much more obvious visual cue
    # without blocking the synchronous discovery work.
    if ($null -eq $script:LoadingForm -or $script:LoadingForm.IsDisposed) {
        $loadingForm = New-Object System.Windows.Forms.Form
        $loadingForm.Text = 'Database Deployment Manager'
        $loadingForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $loadingForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $loadingForm.Size = New-Object System.Drawing.Size(390, 145)
        $loadingForm.MinimizeBox = $false
        $loadingForm.MaximizeBox = $false
        $loadingForm.ControlBox = $false
        $loadingForm.ShowInTaskbar = $false
        $loadingForm.TopMost = $false

        $loadingLabel = New-Object System.Windows.Forms.Label
        $loadingLabel.Text = 'Loading candidates...'
        $loadingLabel.Font = New-Object System.Drawing.Font(
            'Segoe UI',
            11,
            [System.Drawing.FontStyle]::Bold
        )
        $loadingLabel.Location = New-Object System.Drawing.Point(20, 18)
        $loadingLabel.Size = New-Object System.Drawing.Size(340, 25)
        $loadingForm.Controls.Add($loadingLabel)

        $loadingDetail = New-Object System.Windows.Forms.Label
        $loadingDetail.Text = 'Please wait while the candidate list is prepared.'
        $loadingDetail.Location = New-Object System.Drawing.Point(20, 48)
        $loadingDetail.Size = New-Object System.Drawing.Size(340, 22)
        $loadingForm.Controls.Add($loadingDetail)

        $progress = New-Object System.Windows.Forms.ProgressBar
        $progress.Location = New-Object System.Drawing.Point(20, 78)
        $progress.Size = New-Object System.Drawing.Size(340, 20)
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $progress.MarqueeAnimationSpeed = 35
        $loadingForm.Controls.Add($progress)

        $script:LoadingForm = $loadingForm
    }

    $script:LoadingForm.Show($form)
    $script:LoadingForm.BringToFront()
    $script:LoadingForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-LoadingIndicator {
    $script:BusyFrame++

    if (($script:BusyFrame % 2) -eq 0) {
        $lblLoading.Text = 'Loading...'
    }
    else {
        $lblLoading.Text = 'Loading...'
    }

    $lblLoading.Refresh()

    if ($script:LoadingForm -and -not $script:LoadingForm.IsDisposed) {
        $script:LoadingForm.Refresh()
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Stop-LoadingIndicator {
    $lblLoading.Visible = $false

    if ($script:LoadingForm -and -not $script:LoadingForm.IsDisposed) {
        $script:LoadingForm.Close()
        $script:LoadingForm.Dispose()
    }

    $script:LoadingForm = $null

    $form.UseWaitCursor = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    [System.Windows.Forms.Application]::DoEvents()
}

$gridReview = New-Object System.Windows.Forms.DataGridView
$gridReview.Location = New-Object System.Drawing.Point(15, 70)
$gridReview.Size = New-Object System.Drawing.Size(735, 300)
$gridReview.Anchor = 'Top,Bottom,Left'
$gridReview.AllowUserToAddRows = $false
$gridReview.AllowUserToDeleteRows = $false
$gridReview.AllowUserToResizeRows = $false
$gridReview.RowHeadersVisible = $false
$gridReview.SelectionMode = 'FullRowSelect'
$gridReview.MultiSelect = $false
$gridReview.AutoSizeColumnsMode = 'None'
$gridReview.AllowDrop = $true
$gridReview.ScrollBars = [System.Windows.Forms.ScrollBars]::Both

$colDeploy = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colDeploy.HeaderText = 'Deploy'
$colDeploy.Width = 55
$colDeploy.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
$colDeploy.ToolTipText = 'Click to select / unselect all'
[void]$gridReview.Columns.Add($colDeploy)

$colInit = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colInit.HeaderText = 'Init'
$colInit.Width = 45
[void]$gridReview.Columns.Add($colInit)

$colSequence = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSequence.HeaderText = '#'
$colSequence.Width = 42
$colSequence.ReadOnly = $true
$colSequence.DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
[void]$gridReview.Columns.Add($colSequence)

$colOrigin = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colOrigin.HeaderText = 'Origin'
$colOrigin.Width = 75
$colOrigin.ReadOnly = $true
[void]$gridReview.Columns.Add($colOrigin)

$colFile = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFile.HeaderText = 'Repository-relative file'
$colFile.Width = 280
$colFile.ReadOnly = $true
[void]$gridReview.Columns.Add($colFile)

$colVersion = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colVersion.HeaderText = 'Version'
$colVersion.Width = 85
$colVersion.ReadOnly = $true
[void]$gridReview.Columns.Add($colVersion)

$colUseDb = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUseDb.HeaderText = 'USE DB'
$colUseDb.Width = 120
$colUseDb.ReadOnly = $true
[void]$gridReview.Columns.Add($colUseDb)

$colUseAction = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUseAction.HeaderText = 'USE Action'
$colUseAction.Width = 160
$colUseAction.ReadOnly = $true
[void]$gridReview.Columns.Add($colUseAction)

$colModified = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colModified.HeaderText = 'Modified'
$colModified.Width = 140
$colModified.ReadOnly = $true
[void]$gridReview.Columns.Add($colModified)

$colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colStatus.HeaderText = 'Status'
$colStatus.Width = 90
$colStatus.ReadOnly = $true
[void]$gridReview.Columns.Add($colStatus)

$reviewPanel.Controls.Add($gridReview)

function Update-RightWorkspaceLayout {
    # Keep the review grid and Script/Log pane on identical horizontal margins.
    $horizontalMargin = 15
    $availableWidth = $reviewPanel.ClientSize.Width - ($horizontalMargin * 2)

    if ($availableWidth -lt 100) {
        $availableWidth = 100
    }

    $gridReview.Left = $horizontalMargin
    $gridReview.Width = $availableWidth

    # Grid height remains controlled by its Top/Bottom anchors and the
    # draggable horizontal splitter.
}

$reviewPanel.Add_Resize({
    Update-RightWorkspaceLayout
})


# Primary review/deployment action row.
$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = 'Select All'
$btnSelectAll.Location = New-Object System.Drawing.Point(15, 380)
$btnSelectAll.Size = New-Object System.Drawing.Size(90, 28)
$btnSelectAll.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnSelectAll)

$btnClearAll = New-Object System.Windows.Forms.Button
$btnClearAll.Text = 'Clear All'
$btnClearAll.Location = New-Object System.Drawing.Point(112, 380)
$btnClearAll.Size = New-Object System.Drawing.Size(90, 28)
$btnClearAll.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnClearAll)

$btnGenerate = New-Object System.Windows.Forms.Button
$btnGenerate.Text = 'Generate Deployment Script'
$btnGenerate.Location = New-Object System.Drawing.Point(215, 380)
$btnGenerate.Size = New-Object System.Drawing.Size(180, 28)
$btnGenerate.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnGenerate)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = 'Copy Script'
$btnCopy.Location = New-Object System.Drawing.Point(402, 380)
$btnCopy.Size = New-Object System.Drawing.Size(100, 28)
$btnCopy.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnCopy)

$btnDeploy = New-Object System.Windows.Forms.Button
$btnDeploy.Text = 'Deploy Now'
$btnDeploy.Location = New-Object System.Drawing.Point(510, 380)
$btnDeploy.Size = New-Object System.Drawing.Size(100, 28)
$btnDeploy.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnDeploy)

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Text = 'Download'
$btnDownload.Location = New-Object System.Drawing.Point(617, 380)
$btnDownload.Size = New-Object System.Drawing.Size(100, 28)
$btnDownload.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnDownload)

# Ordering row.
$btnMoveUp = New-Object System.Windows.Forms.Button
$btnMoveUp.Text = 'Up'
$btnMoveUp.Location = New-Object System.Drawing.Point(15, 415)
$btnMoveUp.Size = New-Object System.Drawing.Size(75, 28)
$btnMoveUp.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnMoveUp)

$btnMoveDown = New-Object System.Windows.Forms.Button
$btnMoveDown.Text = 'Down'
$btnMoveDown.Location = New-Object System.Drawing.Point(96, 415)
$btnMoveDown.Size = New-Object System.Drawing.Size(75, 28)
$btnMoveDown.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnMoveDown)

$btnMoveTop = New-Object System.Windows.Forms.Button
$btnMoveTop.Text = 'Top'
$btnMoveTop.Location = New-Object System.Drawing.Point(177, 415)
$btnMoveTop.Size = New-Object System.Drawing.Size(70, 28)
$btnMoveTop.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnMoveTop)

$btnMoveBottom = New-Object System.Windows.Forms.Button
$btnMoveBottom.Text = 'Bottom'
$btnMoveBottom.Location = New-Object System.Drawing.Point(253, 415)
$btnMoveBottom.Size = New-Object System.Drawing.Size(70, 28)
$btnMoveBottom.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnMoveBottom)

$btnSaveOrder = New-Object System.Windows.Forms.Button
$btnSaveOrder.Text = 'Save Order'
$btnSaveOrder.Location = New-Object System.Drawing.Point(335, 415)
$btnSaveOrder.Size = New-Object System.Drawing.Size(95, 28)
$btnSaveOrder.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnSaveOrder)

$btnLoadOrder = New-Object System.Windows.Forms.Button
$btnLoadOrder.Text = 'Load Order'
$btnLoadOrder.Location = New-Object System.Drawing.Point(436, 415)
$btnLoadOrder.Size = New-Object System.Drawing.Size(95, 28)
$btnLoadOrder.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($btnLoadOrder)

$lblDragHint = New-Object System.Windows.Forms.Label
$lblDragHint.Text = 'Drag a row to reorder'
$lblDragHint.Location = New-Object System.Drawing.Point(545, 421)
$lblDragHint.AutoSize = $true
$lblDragHint.Anchor = 'Bottom,Left'
$reviewPanel.Controls.Add($lblDragHint)

$tabsBottom = New-Object System.Windows.Forms.TabControl
$tabsBottom.Dock = 'Fill'
$outputPanel.Padding = New-Object System.Windows.Forms.Padding(15, 4, 15, 10)
$outputPanel.Controls.Add($tabsBottom)

$tabScript = New-Object System.Windows.Forms.TabPage
$tabScript.Text = 'Generated Script'
$tabsBottom.TabPages.Add($tabScript)

$txtGenerated = New-Object System.Windows.Forms.TextBox
$txtGenerated.Dock = 'Fill'
$txtGenerated.Multiline = $true
$txtGenerated.ScrollBars = 'Both'
$txtGenerated.WordWrap = $false
$txtGenerated.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabScript.Controls.Add($txtGenerated)

$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = 'Deployment Log'
$tabsBottom.TabPages.Add($tabLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Dock = 'Fill'
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Both'
$txtLog.WordWrap = $false
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabLog.Controls.Add($txtLog)

# Apply splitter constraints and saved/default positions only after the form
# has completed its initial Windows/DPI layout.
$form.Add_Shown({
    try {
        $splitMain.Panel1MinSize = 350
        $splitMain.Panel2MinSize = 550

        $mainDesired = 385
        if ($SavedState -and $SavedState.MainSplitterDistance) {
            $mainDesired = [int]$SavedState.MainSplitterDistance
        }

        $mainMax = $splitMain.Width - $splitMain.Panel2MinSize
        if ($mainDesired -lt $splitMain.Panel1MinSize) { $mainDesired = $splitMain.Panel1MinSize }
        if ($mainDesired -gt $mainMax) { $mainDesired = $mainMax }

        if ($mainDesired -gt 0) {
            $splitMain.SplitterDistance = $mainDesired
        }

        # The review controls use two rows beneath the grid. Keep enough
        # vertical space to show Up/Down/Top/Bottom/Save/Load without requiring
        # the operator to drag the splitter immediately after startup.
        $splitRight.Panel1MinSize = 465
        $splitRight.Panel2MinSize = 145

        $rightDesired = [int]($splitRight.Height * 0.68)

        if ($SavedState -and $SavedState.RightSplitterDistance) {
            $rightDesired = [int]$SavedState.RightSplitterDistance
        }

        $rightMax = $splitRight.Height - $splitRight.Panel2MinSize
        if ($rightDesired -lt $splitRight.Panel1MinSize) { $rightDesired = $splitRight.Panel1MinSize }
        if ($rightDesired -gt $rightMax) { $rightDesired = $rightMax }

        if ($rightDesired -gt 0) {
            $splitRight.SplitterDistance = $rightDesired
        }

        Update-RightWorkspaceLayout
    }
    catch {
        # Display scaling can briefly report transient dimensions while opening.
        # The default docking layout remains usable if Windows rejects a saved
        # splitter position.
    }
})

$splitMain.Add_SplitterMoved({
    Update-RightWorkspaceLayout
})

$splitRight.Add_SplitterMoved({
    Update-RightWorkspaceLayout
})

# ============================================================
# EVENTS
# ============================================================

$chkManageUseStatements.Add_CheckedChanged({
    if ($gridReview.Rows.Count -gt 0) {
        $gridReview.Rows.Clear()
        $lblReviewCount.Text = 'Candidates: 0'
        Write-Log 'USE-management setting changed. Refresh the review list to recalculate USE DB / USE Action.' 'Warning'
    }
})

$chkUseAwsProfile.Add_CheckedChanged({
    Update-AwsProfileControls
})

$cmbOrigin.Add_SelectedIndexChanged({
    $isS3 = ($cmbOrigin.SelectedItem -eq 'AWS S3')
    $rbS3.Checked = $isS3
    $rbFileSystem.Checked = -not $isS3

    Set-OriginControls
    Set-ModeControls
})

$rbDate.Add_CheckedChanged({ Set-ModeControls })
$chkIgnoreFileDate.Add_CheckedChanged({ Set-ModeControls })
$rbList.Add_CheckedChanged({ Set-ModeControls })

$btnBrowseRepo.Add_Click({
    $folder = New-Object System.Windows.Forms.FolderBrowserDialog
    $folder.Description = 'Select repository root'

    if (Test-Path -LiteralPath $txtRepoRoot.Text) {
        $folder.SelectedPath = $txtRepoRoot.Text
    }

    if ($folder.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtRepoRoot.Text = $folder.SelectedPath
    }
})

$btnListBuckets.Add_Click({
    try {
        $awsExe = Get-AwsCliPath

        if (-not $awsExe) {
            throw 'AWS CLI was not found. aws.exe/aws must be available in PATH.'
        }

        Write-Log 'Listing S3 buckets. This is performed only because List Buckets was clicked.'
        Write-Log "S3 authentication: $(Get-AwsAuthDescription)"

        $buckets = Get-DDMS3Buckets `
            -AwsExe $awsExe `
            -UseProfile ([bool]$chkUseAwsProfile.Checked) `
            -ProfileName $txtAwsProfile.Text.Trim()

        $currentBucket = $cmbS3Bucket.Text.Trim()
        $cmbS3Bucket.Items.Clear()

        foreach ($bucket in $buckets) {
            [void]$cmbS3Bucket.Items.Add([string]$bucket)
        }

        if (-not [string]::IsNullOrWhiteSpace($currentBucket)) {
            $cmbS3Bucket.Text = $currentBucket
        }

        Write-Log "Bucket list loaded. $($cmbS3Bucket.Items.Count) bucket(s) found." 'Success'
    }
    catch {
        Write-Log $_.Exception.Message 'Error'

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Unable to list S3 buckets',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$btnDetect.Add_Click({
    Start-LoadingIndicator

    try {
        $mode = if ($rbDate.Checked) { 'Date' } else { 'List' }
        $origin = if ($rbS3.Checked) { 'S3' } else { 'FileSystem' }

        $layout = Get-CurrentWindowLayout

        Save-State `
            -Hosts @(Get-SelectedServers) `
            -RepoRoot $txtRepoRoot.Text.Trim() `
            -ExplicitList $txtExplicitList.Text `
            -Database $cmbDatabase.Text `
            -SqlCmdPath $txtSqlCmd.Text.Trim() `
            -CommandTimeout ([int]$numTimeout.Value) `
            -DetectionMode $mode `
            -DetectionDate $dtpDetection.Value `
            -Origin $origin `
            -S3Bucket $cmbS3Bucket.Text.Trim() `
            -S3Prefix $txtS3Prefix.Text.Trim() `
            -AwsProfile $txtAwsProfile.Text.Trim() `
            -CreateOrAlter ([bool]$chkCreateOrAlter.Checked) `
            -DbMapServer $txtDbMapServer.Text.Trim() `
            -DbMapSource $txtDbMapSource.Text.Trim() `
            -DbMapReplacement $txtDbMapReplacement.Text.Trim() `
            -ValueSet $script:CurrentValueSet `
            -UseAwsProfile ([bool]$chkUseAwsProfile.Checked) `
            -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
            -Platform $cmbPlatform.Text `
            -WindowWidth $layout.Width `
            -WindowHeight $layout.Height `
            -WindowX $layout.X `
            -WindowY $layout.Y `
            -WindowState $layout.State `
            -MainSplitterDistance $layout.MainSplitterDistance `
            -RightSplitterDistance $layout.RightSplitterDistance

        if ($rbS3.Checked) {
            Write-Log "Loading S3 candidates from bucket [$($cmbS3Bucket.Text.Trim())]..."
        }
        else {
            Write-Log "Scanning File System source [$($txtRepoRoot.Text.Trim())]..."
        }

        Write-Log "Version checking: $(if ($chkCheckVersion.Checked) { 'Enabled' } else { 'Disabled' })"

        $items = Get-CandidateItems

        Write-Log "Effective cutoff: $($dtpDetection.Value.ToString('yyyy-MM-dd HH:mm:ss')) | Ignore date: $([bool]$chkIgnoreFileDate.Checked) | Mode: $mode"
        $stamped = @($items | Where-Object { $_.LastWriteTime -ne [datetime]::MinValue } | Sort-Object LastWriteTime)
        if ($stamped.Count -gt 0) {
            Write-Log "Candidate LastWriteTime range: $($stamped[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) to $($stamped[-1].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        }

        Populate-ReviewGrid -Items $items

        if ($rbDate.Checked -and $chkIgnoreFileDate.Checked) {
            Write-Log 'Modification-date filter is disabled; all eligible items were included.'
        }

        Write-Log "Review list built. $(@($items).Count) candidate(s) found." 'Success'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Unable to build review',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null

        Write-Log $_.Exception.Message 'Error'
    }
    finally {
        Stop-LoadingIndicator
    }
})

$cmbDatabase.Add_SelectedIndexChanged({
    if ($gridReview.Rows.Count -gt 0) {
        $gridReview.Rows.Clear()
        $lblReviewCount.Text = 'Candidates: 0'
        Write-Log 'Target database changed. Refresh the review list to recalculate USE DB / USE Action.' 'Warning'
    }
})

$btnTestConnection.Add_Click({
    try {
        $servers = @(Get-SelectedServers)
        $database = [string]$cmbDatabase.Text

        if (@($servers).Count -eq 0) {
            throw 'Select at least one target server.'
        }

        if ([string]::IsNullOrWhiteSpace($database)) {
            throw 'Select a target database.'
        }

        $sqlCmdExe = Get-SqlCmdPath -PreferredPath $txtSqlCmd.Text.Trim()

        if (-not $sqlCmdExe) {
            throw 'sqlcmd.exe was not found on PATH or in the standard SQL client tool locations.'
        }

        $query = @"
SET NOCOUNT ON;
SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS DatabaseName,
    SUSER_SNAME() AS LoginName;
"@

        $tabsBottom.SelectedTab = $tabLog
        $results = @()

        foreach ($server in $servers) {
            Write-Log "Testing connection to $server / $database..."

            try {
                $output = Invoke-SqlCmdText `
                    -ServerInstance $server `
                    -Database $database `
                    -Query $query `
                    -SqlCmdExe $sqlCmdExe `
                    -QueryTimeout ([int]$numTimeout.Value)

                Write-Log "Connection successful: $server / $database" 'Success'

                if (-not [string]::IsNullOrWhiteSpace($output)) {
                    foreach ($line in ($output -split "`r?`n")) {
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $txtLog.AppendText("    $line`r`n")
                        }
                    }
                }

                $results += "$server : SUCCESS"
            }
            catch {
                Write-Log "Connection failed: $server / $database. $($_.Exception.Message)" 'Error'
                $results += "$server : FAILED"
            }
        }

        [System.Windows.Forms.MessageBox]::Show(
            ($results -join "`r`n"),
            'Connection Test',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Write-Log $_.Exception.Message 'Error'

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Connection Test',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$gridReview.Add_CurrentCellDirtyStateChanged({
    if ($gridReview.IsCurrentCellDirty) {
        $gridReview.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})

$gridReview.Add_CellValueChanged({
    param($sender, $e)

    if ($e.RowIndex -lt 0) { return }

    $row = $gridReview.Rows[$e.RowIndex]

    # Deploy column = 0, Init column = 1.
    if ($e.ColumnIndex -eq 1 -and [bool]$row.Cells[1].Value) {
        $row.Cells[0].Value = $false
        Normalize-InitializationRows
    }
    elseif ($e.ColumnIndex -eq 0 -and [bool]$row.Cells[0].Value) {
        $row.Cells[1].Value = $false
    }
})

$btnMoveUp.Add_Click({
    $row = Get-SelectedGridRow
    if ($null -ne $row -and $row.Index -gt 0) {
        Move-GridRow -Row $row -NewIndex ($row.Index - 1)
    }
})

$btnMoveDown.Add_Click({
    $row = Get-SelectedGridRow
    if ($null -ne $row -and $row.Index -lt ($gridReview.Rows.Count - 1)) {
        Move-GridRow -Row $row -NewIndex ($row.Index + 1)
    }
})

$btnMoveTop.Add_Click({
    $row = Get-SelectedGridRow
    if ($null -ne $row) { Move-GridRow -Row $row -NewIndex 0 }
})

$btnMoveBottom.Add_Click({
    $row = Get-SelectedGridRow
    if ($null -ne $row) { Move-GridRow -Row $row -NewIndex ($gridReview.Rows.Count - 1) }
})

$script:DragRowIndex = -1

$gridReview.Add_MouseDown({
    param($sender, $e)
    $hit = $gridReview.HitTest($e.X, $e.Y)
    $script:DragRowIndex = $hit.RowIndex
})

$gridReview.Add_MouseMove({
    param($sender, $e)
    if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -and $script:DragRowIndex -ge 0) {
        $row = $gridReview.Rows[$script:DragRowIndex]
        [void]$gridReview.DoDragDrop($row, [System.Windows.Forms.DragDropEffects]::Move)
    }
})

$gridReview.Add_DragOver({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataGridViewRow])) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Move
    } else {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
})

$gridReview.Add_DragDrop({
    param($sender, $e)
    $point = $gridReview.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $hit = $gridReview.HitTest($point.X, $point.Y)
    $row = $e.Data.GetData([System.Windows.Forms.DataGridViewRow])
    if ($null -eq $row) { return }
    $target = $hit.RowIndex
    if ($target -lt 0) { $target = $gridReview.Rows.Count - 1 }
    Move-GridRow -Row $row -NewIndex $target
})

$btnSaveOrder.Add_Click({
    try {
        if ($gridReview.Rows.Count -eq 0) { throw 'There is no review list to save.' }

        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title = 'Save Deployment Order'
        $dialog.Filter = 'Deployment order (*.txt)|*.txt|All files (*.*)|*.*'
        $dialog.FileName = 'DDM_Deployment_Order.txt'

        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $lines = @()
        foreach ($row in $gridReview.Rows) {
            if ($row.IsNewRow) { continue }
            $item = $row.Tag
            if ($null -eq $item) { continue }
            $deploy = if ([bool]$row.Cells[0].Value) { '1' } else { '0' }
            $init = if ([bool]$row.Cells[1].Value) { '1' } else { '0' }
            $version = if ($item.PSObject.Properties['Version']) { [string]$item.Version } else { '' }
            $lines += "$deploy|$init|$($item.Origin)|$($item.Source)|$($item.DisplayName)|$version"
        }

        Set-Content -LiteralPath $dialog.FileName -Value $lines -Encoding UTF8
        Write-Log "Deployment order saved to $($dialog.FileName)." 'Success'
    }
    catch {
        Write-Log $_.Exception.Message 'Error'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Save Order Error','OK','Error') | Out-Null
    }
})

$btnLoadOrder.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Load Deployment Order'
        $dialog.Filter = 'Deployment order (*.txt)|*.txt|All files (*.*)|*.*'

        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $gridReview.Rows.Clear()

        foreach ($line in (Get-Content -LiteralPath $dialog.FileName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split '\|',6
            if ($parts.Count -lt 5) { continue }

            $deploy = ($parts[0] -eq '1')
            $init = ($parts[1] -eq '1')
            $origin = $parts[2]
            $source = $parts[3]
            $display = $parts[4]
            $savedVersion = if ($parts.Count -ge 6) { [string]$parts[5] } else { '' }

            if ($origin -eq 'File System') {
                $exists = Test-Path -LiteralPath $source -PathType Leaf
                $item = [pscustomobject]@{
                    Origin='File System'; DisplayName=$display; Source=$source
                    LastWriteTime=if($exists){(Get-Item -LiteralPath $source).LastWriteTime}else{[datetime]::MinValue}
                    Version=if(-not [string]::IsNullOrWhiteSpace($savedVersion)){$savedVersion}elseif($exists){Get-DDMFileHeaderVersion -FilePath $source}else{''}
                    Missing=(-not $exists); Bucket=$null; Key=$null
                }
            }
            elseif ($origin -eq 'S3') {
                $bucket=$null; $key=$null
                if ($source -match '^s3://([^/]+)/(.+)$') { $bucket=$matches[1]; $key=$matches[2] }
                $item = [pscustomobject]@{
                    Origin='S3'; DisplayName=$display; Source=$source
                    LastWriteTime=[datetime]::MinValue; Version=$savedVersion; Missing=$false; Bucket=$bucket; Key=$key
                }
            }
            else { continue }

            $rowIndex = $gridReview.Rows.Add(
                $deploy,$init,0,$item.Origin,$item.DisplayName,$item.Version,'','Loaded'
            )
            $gridReview.Rows[$rowIndex].Tag = $item

            if ($item.Missing) {
                $gridReview.Rows[$rowIndex].Cells[0].Value = $false
                $gridReview.Rows[$rowIndex].Cells[0].ReadOnly = $true
                $gridReview.Rows[$rowIndex].Cells[1].Value = $false
                $gridReview.Rows[$rowIndex].Cells[1].ReadOnly = $true
                $gridReview.Rows[$rowIndex].Cells[9].Value = 'Missing'
            }
        }

        Normalize-InitializationRows
        $lblReviewCount.Text = "Candidates: $($gridReview.Rows.Count)"
        Write-Log "Deployment order loaded from $($dialog.FileName)." 'Success'
    }
    catch {
        Write-Log $_.Exception.Message 'Error'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Load Order Error','OK','Error') | Out-Null
    }
})

$btnSelectAll.Add_Click({
    foreach ($row in $gridReview.Rows) {
        if (-not $row.IsNewRow -and
            -not $row.Cells[0].ReadOnly -and
            -not [bool]$row.Cells[1].Value) {
            $row.Cells[0].Value = $true
        }
    }
})

$btnClearAll.Add_Click({
    foreach ($row in $gridReview.Rows) {
        if (-not $row.IsNewRow -and -not $row.Cells[0].ReadOnly) {
            $row.Cells[0].Value = $false
        }
    }
})

# Deploy column header (index 0) toggles select all / unselect all.
$gridReview.Add_ColumnHeaderMouseClick({
    param($sender, $e)

    if ($e.ColumnIndex -ne 0) { return }

    [void]$gridReview.EndEdit()

    # Same eligibility as the Select All button: skip Missing and Init rows.
    $eligibleRows = @(
        foreach ($row in $gridReview.Rows) {
            if (-not $row.IsNewRow -and
                -not $row.Cells[0].ReadOnly -and
                -not [bool]$row.Cells[1].Value) {
                $row
            }
        }
    )

    if ($eligibleRows.Count -eq 0) { return }

    # If anything is unchecked, check all. If everything is checked, clear all.
    $anyUnchecked = @($eligibleRows | Where-Object { -not [bool]$_.Cells[0].Value }).Count -gt 0

    foreach ($row in $eligibleRows) {
        $row.Cells[0].Value = $anyUnchecked
    }
})

$btnGenerate.Add_Click({
    try {
        $txtGenerated.Text = Build-DeploymentScript
        $tabsBottom.SelectedTab = $tabScript
        Write-Log 'Deployment script generated.' 'Success'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Unable to generate script',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})

$btnCopy.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($txtGenerated.Text)) {
            $txtGenerated.Text = Build-DeploymentScript
        }

        [System.Windows.Forms.Clipboard]::SetText($txtGenerated.Text)
        Write-Log 'Generated deployment script copied to the clipboard.' 'Success'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Unable to copy script',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})

$btnDownload.Add_Click({
    try {
        $items = @((Get-InitializationItems)) + @((Get-SelectedDeploymentItems))

        if (@($items).Count -eq 0) {
            throw 'No items are selected.'
        }

        $s3Items = @($items | Where-Object { $_.Origin -eq 'S3' })

        if (@($s3Items).Count -eq 0) {
            throw 'Download is available for selected S3 items. No S3 items are selected.'
        }

        $awsExe = Get-AwsCliPath

        if (-not $awsExe) {
            throw 'AWS CLI was not found. Download requires aws.exe/aws in PATH.'
        }

        $downloadFolder = Join-Path $env:USERPROFILE 'Downloads'

        if (-not (Test-Path -LiteralPath $downloadFolder -PathType Container)) {
            New-Item -ItemType Directory -Path $downloadFolder -Force | Out-Null
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Download $(@($s3Items).Count) selected S3 item(s) to:`r`n`r`n$downloadFolder`r`n`r`nProceed?",
            'Confirm Download',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Download cancelled by user.' 'Warning'
            return
        }

        $tabsBottom.SelectedTab = $tabLog
        Write-Log "Download destination: $downloadFolder"
        Write-Log "S3 authentication: $(Get-AwsAuthDescription)"

        $downloaded = 0

        foreach ($item in $s3Items) {
            $fileName = [System.IO.Path]::GetFileName([string]$item.Key)

            if ([string]::IsNullOrWhiteSpace($fileName)) {
                $fileName = [System.IO.Path]::GetFileName([string]$item.Source)
            }

            if ([string]::IsNullOrWhiteSpace($fileName)) {
                Write-Log "Skipping S3 object with no file name: $($item.Source)" 'Warning'
                continue
            }

            $destination = Join-Path $downloadFolder $fileName

            if (Test-Path -LiteralPath $destination) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $ext = [System.IO.Path]::GetExtension($fileName)
                $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $destination = Join-Path $downloadFolder ("{0}_{1}{2}" -f $base, $stamp, $ext)
            }

            Write-Log "Downloading $($item.Source) -> $destination"

            $awsArgs = @('s3','cp',$item.Source,$destination,'--only-show-errors') + @(Get-AwsProfileArgs)
            $awsOutput = & $awsExe @awsArgs 2>&1
            $awsExitCode = $LASTEXITCODE

            if ($awsOutput) {
                foreach ($line in $awsOutput) {
                    $txtLog.AppendText("    $($line.ToString())`r`n")
                }
            }

            if ($awsExitCode -ne 0) {
                throw "AWS CLI failed downloading [$($item.Source)]. Exit code: $awsExitCode"
            }

            $downloaded++
            Write-Log "Downloaded $fileName" 'Success'
        }

        [System.Windows.Forms.MessageBox]::Show(
            "$downloaded file(s) downloaded to:`r`n$downloadFolder",
            'Download Complete',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Write-Log $_.Exception.Message 'Error'

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Download Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$btnDeploy.Add_Click({
    try {
        $validation = Validate-ImmediateDeployment

        $sqlCmdExe = $validation.SqlCmdExe
        $awsExe = $validation.AwsExe
        $servers = @(Get-SelectedServers)
        $database = [string]$cmbDatabase.Text
        Write-Log "Target database selected for deployment and USE management: $database"
        $initItems = @(Get-InitializationItems)
        $items = @(Get-SelectedDeploymentItems)
        $queryTimeout = [int]$numTimeout.Value
        $targetSummary = ($servers -join ', ')
        $originSummary = (@((@($initItems) + @($items)) | Select-Object -ExpandProperty Origin -Unique) -join ', ')

        $message = @"
You are about to deploy:

Server(s): $targetSummary
Database : $database
Initialization items: $(@($initItems).Count)
Deployment items    : $(@($items).Count)
Origin              : $originSummary
Order               : Init items first, then review-grid sequence (# column)

CREATE OR ALTER conversion: $(if ($chkCreateOrAlter.Checked) { 'Enabled' } else { 'Disabled' })
SQL text DB mapping: on $($txtDbMapServer.Text.Trim()), replace $($txtDbMapSource.Text.Trim()) -> $($txtDbMapReplacement.Text.Trim())

SQLCMD   : $sqlCmdExe

For S3 items, each object is downloaded to a temporary .sql file,
executed, and then deleted.

Item-level SQL errors are recorded and deployment continues with the remaining items.
Successful items are unchecked automatically; failed items remain checked for retry.

Proceed?
"@

        $answer = [System.Windows.Forms.MessageBox]::Show(
            $message,
            'Confirm Immediate Deployment',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Immediate deployment cancelled by user.' 'Warning'
            return
        }

        $tabsBottom.SelectedTab = $tabLog

        $engineLogger = {
            param($message, $level)

            if ($level -eq 'Raw') {
                foreach ($line in ($message -split "`r?`n")) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $txtLog.AppendText("    $line`r`n")
                    }
                }
                $txtLog.SelectionStart = $txtLog.TextLength
                $txtLog.ScrollToCaret()
            }
            else {
                Write-Log -Message $message -Level $level
            }
        }

        $deploymentResult = Invoke-DDMDeploymentPlan `
            -Servers $servers `
            -Database $database `
            -InitializationItems $initItems `
            -DeploymentItems $items `
            -SqlCmdExe $sqlCmdExe `
            -QueryTimeout $queryTimeout `
            -AwsExe $(if ($awsExe) { $awsExe } else { '' }) `
            -UseAwsProfile ([bool]$chkUseAwsProfile.Checked) `
            -AwsProfile $txtAwsProfile.Text.Trim() `
            -CreateOrAlter ([bool]$chkCreateOrAlter.Checked) `
            -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
            -UseMappings (Get-UseManagementMappings) `
            -DefaultToTargetDatabase $UseManagementDefaultToTarget `
            -DbMapServer $txtDbMapServer.Text.Trim() `
            -DbMapSource $txtDbMapSource.Text.Trim() `
            -DbMapReplacement $txtDbMapReplacement.Text.Trim() `
            -LogAction $engineLogger

        Update-ReviewAfterDeployment -DeploymentResult $deploymentResult

        if ($deploymentResult.ErrorCount -gt 0) {
            Write-Log "Deployment completed with $($deploymentResult.ErrorCount) error(s). Failed items remain checked." 'Warning'
            Show-DeploymentErrors -Errors @($deploymentResult.Errors)
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                'Deployment completed successfully. Successfully deployed items have been unchecked.',
                'Deployment Complete',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        Write-Log $_.Exception.Message 'Error'

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Deployment Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$form.Add_FormClosing({
    try {
        $mode = if ($rbDate.Checked) { 'Date' } else { 'List' }
        $origin = if ($rbS3.Checked) { 'S3' } else { 'FileSystem' }

        $layout = Get-CurrentWindowLayout

        Save-State `
            -Hosts @(Get-SelectedServers) `
            -RepoRoot $txtRepoRoot.Text.Trim() `
            -ExplicitList $txtExplicitList.Text `
            -Database $cmbDatabase.Text `
            -SqlCmdPath $txtSqlCmd.Text.Trim() `
            -CommandTimeout ([int]$numTimeout.Value) `
            -DetectionMode $mode `
            -DetectionDate $dtpDetection.Value `
            -Origin $origin `
            -S3Bucket $cmbS3Bucket.Text.Trim() `
            -S3Prefix $txtS3Prefix.Text.Trim() `
            -AwsProfile $txtAwsProfile.Text.Trim() `
            -CreateOrAlter ([bool]$chkCreateOrAlter.Checked) `
            -DbMapServer $txtDbMapServer.Text.Trim() `
            -DbMapSource $txtDbMapSource.Text.Trim() `
            -DbMapReplacement $txtDbMapReplacement.Text.Trim() `
            -ValueSet $script:CurrentValueSet `
            -UseAwsProfile ([bool]$chkUseAwsProfile.Checked) `
            -ManageUseStatements ([bool]$chkManageUseStatements.Checked) `
            -Platform $cmbPlatform.Text `
            -WindowWidth $layout.Width `
            -WindowHeight $layout.Height `
            -WindowX $layout.X `
            -WindowY $layout.Y `
            -WindowState $layout.State `
            -MainSplitterDistance $layout.MainSplitterDistance `
            -RightSplitterDistance $layout.RightSplitterDistance
    }
    catch {
        # Do not block closing if state cannot be saved.
    }
})

# ============================================================
# INITIALIZE
# ============================================================

Set-ModeControls
Set-OriginControls
Update-AwsProfileControls

$initialValueSet = if ($SavedState -and $SavedState.ValueSet) {
    [string]$SavedState.ValueSet
}
else {
    $DefaultValueSet
}

Apply-ValueSet -SetName $initialValueSet

# Re-check the target servers that were selected in the previous session.
if ($SavedState -and $SavedState.Hosts -and ([string]$SavedState.ValueSet -eq $script:CurrentValueSet)) {
    $savedHosts = @($SavedState.Hosts | ForEach-Object { [string]$_ })
    foreach ($menuItem in $script:ServerMenuItems) {
        if ($savedHosts -contains [string]$menuItem.Text) {
            $menuItem.Checked = $true
        }
    }
}

if ($SavedState -and $SavedState.Database) {
    $cmbDatabase.Text = [string]$SavedState.Database
}

Update-ServerDropdownText
Write-Log 'Database Deployment Manager started.'
Write-Log "Host: $env:COMPUTERNAME"
Write-Log "Platform: $($cmbPlatform.Text)"
Write-Log "Display working area: $($workingArea.Width)x$($workingArea.Height)"
Write-Log "AWS mode: $(Get-AwsAuthDescription)"
Write-Log "Default detection date: $($dtpDetection.Value.ToString('yyyy-MM-dd HH:mm:ss'))"

[void]$form.ShowDialog()
