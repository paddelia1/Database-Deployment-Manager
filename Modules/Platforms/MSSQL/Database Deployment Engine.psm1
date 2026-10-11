#requires -Version 5.1
<#
.SYNOPSIS
    Database Deployment Manager - Deployment Engine

.VERSION
    1.0.0

.MODIFIED
    2026-10-10

.AUTHOR
    Philippe Addelia

.DESCRIPTION
    GUI-independent deployment engine used by Database Deployment Manager.

    This module intentionally contains no Windows Forms code. It can therefore
    be reused later by a command-line front end or CI/CD pipeline.

    Current engine responsibilities:
      - SQLCMD discovery and execution
      - AWS CLI discovery and execution
      - S3 object listing and download
      - File-system candidate discovery
      - SQL deployment transformations, including optional target USE management
      - MSSQL object-creation guard enforcing ANSI_NULLS ON and QUOTED_IDENTIFIER ON
      - optional SQL header-version discovery for local and S3 candidates
      - optional progress callback during file-system candidate discovery
      - Initialization and deployment execution

    Change history:
      Version 1.0.0 - 2026-10-10:
        - Initial public release.
#>

Set-StrictMode -Version 2.0

function Get-DDMRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FullPath
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $normalizedFile = [System.IO.Path]::GetFullPath($FullPath)

    if ($normalizedFile.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedFile.Substring($normalizedRoot.Length)
    }

    return $normalizedFile
}

function Get-DDMAwsCliPath {
    [CmdletBinding()]
    param()

    $command = Get-Command 'aws.exe' -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command 'aws' -ErrorAction SilentlyContinue
    }

    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function Write-DDMUtf8NoBomFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-DDMAwsProfileArgs {
    [CmdletBinding()]
    param(
        [bool]$UseProfile,
        [string]$ProfileName
    )

    if ($UseProfile -and -not [string]::IsNullOrWhiteSpace($ProfileName)) {
        return @('--profile', $ProfileName)
    }

    return @()
}

function Invoke-DDMAwsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [bool]$UseProfile = $false,
        [string]$ProfileName = ''
    )

    $finalArguments = @($Arguments) + @(Get-DDMAwsProfileArgs -UseProfile $UseProfile -ProfileName $ProfileName)
    $output = & $AwsExe @finalArguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            throw "AWS CLI failed with exit code $exitCode."
        }
        throw $outputText.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($outputText)) {
        return $null
    }

    return ($outputText | ConvertFrom-Json)
}

function Get-DDMS3Buckets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [bool]$UseProfile = $false,
        [string]$ProfileName = ''
    )

    $response = Invoke-DDMAwsJson `
        -AwsExe $AwsExe `
        -Arguments @('s3api','list-buckets','--output','json') `
        -UseProfile $UseProfile `
        -ProfileName $ProfileName

    if ($response -and $response.Buckets) {
        return @($response.Buckets | Sort-Object Name | ForEach-Object { [string]$_.Name })
    }

    return @()
}

function Get-DDMS3Objects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [Parameter(Mandatory)][string]$Bucket,
        [string]$Prefix = '',
        [bool]$UseProfile = $false,
        [string]$ProfileName = ''
    )

    $baseArgs = @('s3api','list-objects-v2','--bucket',$Bucket,'--output','json')

    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        $normalizedPrefix = $Prefix.Trim('/')
        $baseArgs += @('--prefix', ($normalizedPrefix + '/'))
    }

    $allObjects = @()
    $continuationToken = $null

    do {
        $args = @($baseArgs)

        if ($continuationToken) {
            $args += @('--continuation-token', $continuationToken)
        }

        $response = Invoke-DDMAwsJson `
            -AwsExe $AwsExe `
            -Arguments $args `
            -UseProfile $UseProfile `
            -ProfileName $ProfileName

        if ($response -and $response.Contents) {
            $allObjects += @($response.Contents)
        }

        $continuationToken = $null
        if ($response -and $response.IsTruncated -and $response.NextContinuationToken) {
            $continuationToken = [string]$response.NextContinuationToken
        }
    }
    while ($continuationToken)

    return @($allObjects)
}

function Test-DDMS3Object {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [Parameter(Mandatory)][string]$Bucket,
        [Parameter(Mandatory)][string]$Key,
        [bool]$UseProfile = $false,
        [string]$ProfileName = ''
    )

    try {
        $head = Invoke-DDMAwsJson `
            -AwsExe $AwsExe `
            -Arguments @('s3api','head-object','--bucket',$Bucket,'--key',$Key,'--output','json') `
            -UseProfile $UseProfile `
            -ProfileName $ProfileName

        return [pscustomobject]@{
            Exists       = $true
            LastModified = if ($head.LastModified) { [datetime]$head.LastModified } else { [datetime]::MinValue }
        }
    }
    catch {
        return [pscustomobject]@{
            Exists       = $false
            LastModified = [datetime]::MinValue
        }
    }
}

function Copy-DDMS3Object {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [Parameter(Mandatory)][string]$SourceUri,
        [Parameter(Mandatory)][string]$Destination,
        [bool]$UseProfile = $false,
        [string]$ProfileName = ''
    )

    $args = @('s3','cp',$SourceUri,$Destination,'--only-show-errors') +
            @(Get-DDMAwsProfileArgs -UseProfile $UseProfile -ProfileName $ProfileName)

    $output = & $AwsExe @args 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            throw "AWS CLI failed downloading [$SourceUri]. Exit code: $exitCode"
        }
        throw $outputText.Trim()
    }

    return $outputText
}

function Get-DDMVersionFromText {
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    # Common SQL/comment header forms:
    #   -- Version: 1.2.3
    #   /* Version: 1.2.3 */
    #   * Version: 1.2.3
    # Also supports the PowerShell-style:
    #   .VERSION
    #       1.2.3
    $patterns = @(
        '(?im)^\s*(?:--\s*|/\*+\s*|\*+\s*|//\s*|#\s*)?Version\s*[:=]\s*([0-9]+(?:\.[0-9A-Za-z_-]+){1,4})\b',
        '(?im)^\s*\.VERSION\s*\r?\n\s*([0-9]+(?:\.[0-9A-Za-z_-]+){1,4})\b'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Text, $pattern)
        if ($match.Success) {
            return [string]$match.Groups[1].Value
        }
    }

    return ''
}

function Get-DDMFileHeaderVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [int]$MaxLines = 80
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return ''
    }

    try {
        $header = (Get-Content -LiteralPath $FilePath -TotalCount $MaxLines -ErrorAction Stop) -join "`n"
        return Get-DDMVersionFromText -Text $header
    }
    catch {
        return ''
    }
}

function Get-DDMS3ObjectHeaderVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [Parameter(Mandatory)][string]$Bucket,
        [Parameter(Mandatory)][string]$Key,
        [bool]$UseProfile = $false,
        [string]$ProfileName = '',
        [int]$HeaderBytes = 16384
    )

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) (
        "DatabaseDeployment_Header_" + [guid]::NewGuid().ToString('N') + '.txt'
    )

    try {
        $lastByte = [Math]::Max(0, $HeaderBytes - 1)
        $args = @(
            's3api','get-object',
            '--bucket',$Bucket,
            '--key',$Key,
            '--range',"bytes=0-$lastByte",
            $tempFile
        ) + @(Get-DDMAwsProfileArgs -UseProfile $UseProfile -ProfileName $ProfileName)

        $output = & $AwsExe @args 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $tempFile)) {
            return ''
        }

        return Get-DDMFileHeaderVersion -FilePath $tempFile -MaxLines 80
    }
    catch {
        return ''
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-DDMUseDatabase {
    [CmdletBinding()]
    param(
        [string]$SourceDatabase,
        [string]$SelectedDatabase = '',
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true
    )

    # IMPORTANT:
    # The Target database selected in the GUI is authoritative.  A configured
    # source->target mapping must NEVER redirect a deployment to a database
    # different from the database selected by the user.
    #
    # UseMappings is retained for review/description of known relationships;
    # it does not choose the actual USE target.
    if (-not [string]::IsNullOrWhiteSpace($SelectedDatabase)) {
        return $SelectedDatabase
    }

    return $null
}

function Get-DDMUseStatementInfo {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string]$SelectedDatabase = '',
        [bool]$ManageUseStatements = $false,
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true
    )

    $usePattern = '(?im)^\s*USE\s+(?:\[([^\]]+)\]|([A-Za-z0-9_.$#@-]+))\s*;?\s*$'
    $matches = @([regex]::Matches([string]$Text, $usePattern))

    $databases = @(
        foreach ($match in $matches) {
            if ($match.Groups[1].Success) { [string]$match.Groups[1].Value }
            elseif ($match.Groups[2].Success) { [string]$match.Groups[2].Value }
        }
    )

    $uniqueDatabases = @($databases | Select-Object -Unique)

    if (-not $ManageUseStatements) {
        return [pscustomobject]@{
            UseDatabase = if ($uniqueDatabases.Count -eq 0) { 'None' } else { $uniqueDatabases -join ', ' }
            UseAction   = 'Preserve'
            UseCount    = $matches.Count
        }
    }

    if ([string]::IsNullOrWhiteSpace($SelectedDatabase)) {
        return [pscustomobject]@{
            UseDatabase = if ($uniqueDatabases.Count -eq 0) { 'None' } else { $uniqueDatabases -join ', ' }
            UseAction   = 'No target DB'
            UseCount    = $matches.Count
        }
    }

    if ($uniqueDatabases.Count -eq 0) {
        return [pscustomobject]@{
            UseDatabase = 'None'
            UseAction   = "Add -> $SelectedDatabase"
            UseCount    = 0
        }
    }

    $actions = @()

    foreach ($sourceDb in $uniqueDatabases) {
        if ($sourceDb.Equals($SelectedDatabase,[System.StringComparison]::OrdinalIgnoreCase)) {
            $actions += "$sourceDb -> No change"
            continue
        }

        # Mapping is informational only.  If it describes exactly the selected
        # target, show it as a recognized map; otherwise the GUI-selected target
        # still wins.
        if ($UseMappings -and
            $UseMappings.ContainsKey($sourceDb) -and
            ([string]$UseMappings[$sourceDb]).Equals(
                $SelectedDatabase,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            $actions += "$sourceDb -> Map to $SelectedDatabase"
        }
        else {
            $actions += "$sourceDb -> Replace with $SelectedDatabase"
        }
    }

    return [pscustomobject]@{
        UseDatabase = ($uniqueDatabases -join ', ')
        UseAction   = ($actions -join '; ')
        UseCount    = $matches.Count
    }
}

function Get-DDMFileUseStatementInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$SelectedDatabase = '',
        [bool]$ManageUseStatements = $false,
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true,
        [int]$MaxLines = 120
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return [pscustomobject]@{ UseDatabase=''; UseAction=''; UseCount=0 }
    }

    try {
        $text = (Get-Content -LiteralPath $FilePath -TotalCount $MaxLines -ErrorAction Stop) -join "`n"
        return Get-DDMUseStatementInfo `
            -Text $text `
            -SelectedDatabase $SelectedDatabase `
            -ManageUseStatements $ManageUseStatements `
            -UseMappings $UseMappings `
            -DefaultToTargetDatabase $DefaultToTargetDatabase
    }
    catch {
        return [pscustomobject]@{ UseDatabase='Unknown'; UseAction='Inspection failed'; UseCount=0 }
    }
}

function Get-DDMS3ObjectUseStatementInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AwsExe,
        [Parameter(Mandatory)][string]$Bucket,
        [Parameter(Mandatory)][string]$Key,
        [string]$SelectedDatabase = '',
        [bool]$ManageUseStatements = $false,
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true,
        [bool]$UseProfile = $false,
        [string]$ProfileName = '',
        [int]$HeaderBytes = 16384
    )

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("DatabaseDeployment_UseInspect_" + [guid]::NewGuid().ToString('N') + '.sql')

    try {
        $lastByte = [Math]::Max(0,$HeaderBytes - 1)
        $args = @('s3api','get-object','--bucket',$Bucket,'--key',$Key,'--range',"bytes=0-$lastByte",$tempFile) +
                @(Get-DDMAwsProfileArgs -UseProfile $UseProfile -ProfileName $ProfileName)

        $null = & $AwsExe @args 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempFile)) {
            return [pscustomobject]@{ UseDatabase='Unknown'; UseAction='Inspection failed'; UseCount=0 }
        }

        return Get-DDMFileUseStatementInfo `
            -FilePath $tempFile `
            -SelectedDatabase $SelectedDatabase `
            -ManageUseStatements $ManageUseStatements `
            -UseMappings $UseMappings `
            -DefaultToTargetDatabase $DefaultToTargetDatabase
    }
    catch {
        return [pscustomobject]@{ UseDatabase='Unknown'; UseAction='Inspection failed'; UseCount=0 }
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
    }
}


function Get-DDMFileSystemCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [datetime]$StartDate,
        [bool]$IgnoreModificationDate = $false,
        [bool]$CheckVersion = $false,
        [string]$SelectedDatabase = '',
        [bool]$ManageUseStatements = $false,
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true,
        [scriptblock]$ProgressAction
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Repository root does not exist: $Root"
    }

    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction Stop |
        Where-Object {
            $_.Extension -ieq '.sql' -and
            ($IgnoreModificationDate -or $_.LastWriteTime -ge $StartDate)
        } |
        Sort-Object LastWriteTime, FullName |
        ForEach-Object {
            if ($ProgressAction) {
                & $ProgressAction
            }

            $useInfo = Get-DDMFileUseStatementInfo `
                -FilePath $_.FullName `
                -SelectedDatabase $SelectedDatabase `
                -ManageUseStatements $ManageUseStatements `
                -UseMappings $UseMappings `
                -DefaultToTargetDatabase $DefaultToTargetDatabase

            [pscustomobject]@{
                Origin        = 'File System'
                DisplayName   = Get-DDMRelativePath -Root $Root -FullPath $_.FullName
                Source        = $_.FullName
                LastWriteTime = $_.LastWriteTime
                Version       = if ($CheckVersion) { Get-DDMFileHeaderVersion -FilePath $_.FullName } else { '' }
                UseDatabase   = $useInfo.UseDatabase
                UseAction     = $useInfo.UseAction
                Missing       = $false
                Bucket        = $null
                Key           = $null
            }
        }
    )
}

function Get-DDMSqlCmdPath {
    [CmdletBinding()]
    param([string]$PreferredPath)

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        if (Test-Path -LiteralPath $PreferredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $PreferredPath).Path
        }

        $preferredCommand = Get-Command $PreferredPath -ErrorAction SilentlyContinue
        if ($null -ne $preferredCommand) {
            return $preferredCommand.Source
        }
    }

    $candidates = @(
        'sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE',
        'C:\Program Files\Microsoft SQL Server\110\Tools\Binn\SQLCMD.EXE'
    )

    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return $command.Source
        }
    }

    return $null
}

function Invoke-DDMSqlCmdText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$SqlCmdExe,
        [int]$QueryTimeout = 120
    )

    $tempSqlFile = [System.IO.Path]::ChangeExtension(
        [System.IO.Path]::GetTempFileName(),
        '.sql'
    )

    try {
        Write-DDMUtf8NoBomFile -Path $tempSqlFile -Text $Query

        return Invoke-DDMSqlCmdFile `
            -ServerInstance $ServerInstance `
            -Database $Database `
            -FilePath $tempSqlFile `
            -SqlCmdExe $SqlCmdExe `
            -QueryTimeout $QueryTimeout
    }
    finally {
        if (Test-Path -LiteralPath $tempSqlFile) {
            Remove-Item -LiteralPath $tempSqlFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-DDMSqlCmdFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$SqlCmdExe,
        [int]$QueryTimeout = 120
    )

    $args = @(
        '-S', $ServerInstance,
        '-d', $Database,
        '-E',
        '-b',
        '-w', '65535',
        '-y', '0',
        '-Y', '0',
        '-i', $FilePath,
        '-l', '30',
        '-t', $QueryTimeout
    )

    $output = & $SqlCmdExe @args 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { $_.ToString() }) -join "`r`n"

    if ($exitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            throw "sqlcmd.exe failed with exit code $exitCode and returned no output."
        }
        throw ($outputText.Trim() + "`r`n(sqlcmd.exe exit code: $exitCode)")
    }

    return $outputText
}


function Get-DDMModuleSetOptionInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlText
    )

    $modulePattern = '(?im)^\s*(?:CREATE(?:\s+OR\s+ALTER)?|ALTER)\s+(?:PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\b'
    $moduleMatch = [regex]::Match($SqlText, $modulePattern)

    if (-not $moduleMatch.Success) {
        return [pscustomobject]@{
            IsModule = $false
            AnsiNulls = ''
            QuotedIdentifier = ''
            Warnings = @()
        }
    }

    $prefix = $SqlText.Substring(0, $moduleMatch.Index)

    function Get-LastSetting {
        param([string]$Name)
        $pattern = "(?im)^\s*SET\s+$([regex]::Escape($Name))\s+(ON|OFF)\s*;?\s*$"
        $matches = @([regex]::Matches($prefix, $pattern))
        if ($matches.Count -eq 0) { return '' }
        return ([string]$matches[$matches.Count - 1].Groups[1].Value).ToUpperInvariant()
    }

    $ansi = Get-LastSetting 'ANSI_NULLS'
    $quoted = Get-LastSetting 'QUOTED_IDENTIFIER'
    $warnings = @()

    if ($ansi -eq 'OFF') {
        $warnings += 'Source explicitly sets ANSI_NULLS OFF immediately before the module definition. The deployment manager preserved OFF; review this legacy setting.'
    }

    if ($quoted -eq 'OFF') {
        $warnings += 'Source explicitly sets QUOTED_IDENTIFIER OFF immediately before the module definition. The deployment manager preserved OFF; review this legacy setting.'
    }

    return [pscustomobject]@{
        IsModule = $true
        AnsiNulls = $ansi
        QuotedIdentifier = $quoted
        Warnings = @($warnings)
    }
}

function Add-DDMRequiredCreateSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlText
    )

    # SQL Server persists ANSI_NULLS and QUOTED_IDENTIFIER when a module is
    # created/altered.  Enforce ON unless the source explicitly leaves the
    # corresponding setting OFF immediately before the module definition.
    #
    # Explicit OFF is treated as developer intent: it is preserved and surfaced
    # as a warning by Invoke-DDMDeploymentPlan.
    $modulePattern = '(?im)^\s*(?:CREATE(?:\s+OR\s+ALTER)?|ALTER)\s+(?:PROCEDURE|PROC|VIEW|FUNCTION|TRIGGER)\b'
    $moduleMatch = [regex]::Match($SqlText, $modulePattern)

    if (-not $moduleMatch.Success) {
        return $SqlText
    }

    $prefix = $SqlText.Substring(0, $moduleMatch.Index)
    $moduleAndRemainder = $SqlText.Substring($moduleMatch.Index)
    $settingInfo = Get-DDMModuleSetOptionInfo -SqlText $SqlText

    $guardLines = @()

    if ($settingInfo.AnsiNulls -ne 'OFF') {
        $guardLines += 'SET ANSI_NULLS ON;'
        $guardLines += 'GO'
    }

    if ($settingInfo.QuotedIdentifier -ne 'OFF') {
        $guardLines += 'SET QUOTED_IDENTIFIER ON;'
        $guardLines += 'GO'
    }

    if ($guardLines.Count -eq 0) {
        return $SqlText
    }

    if ($prefix.Length -gt 0 -and -not $prefix.EndsWith("`n") -and -not $prefix.EndsWith("`r")) {
        $prefix += "`r`n"
    }

    $guard = ($guardLines -join "`r`n") + "`r`n"
    return $prefix + $guard + $moduleAndRemainder
}

function Convert-DDMSqlText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlText,
        [Parameter(Mandatory)][string]$ServerInstance,
        [string]$SelectedDatabase = '',
        [bool]$ManageUseStatements = $false,
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true,
        [bool]$CreateOrAlter = $false,
        [string]$DbMapServer = '',
        [string]$DbMapSource = '',
        [string]$DbMapReplacement = ''
    )

    $result = $SqlText

    # Master switch: when false, USE configuration is completely ignored and
    # source USE statements remain unchanged.
    if ($ManageUseStatements) {
        $usePattern = '(?im)^\s*USE\s+(?:\[([^\]]+)\]|([A-Za-z0-9_.$#@-]+))\s*;?\s*$'

        if ([regex]::IsMatch($result,$usePattern)) {
            $result = [regex]::Replace(
                $result,
                $usePattern,
                [System.Text.RegularExpressions.MatchEvaluator]{
                    param($m)

                    $sourceDb = if ($m.Groups[1].Success) {
                        [string]$m.Groups[1].Value
                    }
                    else {
                        [string]$m.Groups[2].Value
                    }

                    $resolvedDb = Resolve-DDMUseDatabase `
                        -SourceDatabase $sourceDb `
                        -SelectedDatabase $SelectedDatabase `
                        -UseMappings $UseMappings `
                        -DefaultToTargetDatabase $DefaultToTargetDatabase

                    if ([string]::IsNullOrWhiteSpace($resolvedDb)) {
                        return $m.Value
                    }

                    $escapedResolvedDb = $resolvedDb.Replace(']', ']]')
                    return "USE [$escapedResolvedDb];"
                }
            )
        }
        elseif ($DefaultToTargetDatabase -and -not [string]::IsNullOrWhiteSpace($SelectedDatabase)) {
            $escapedTargetDb = $SelectedDatabase.Replace(']', ']]')
            $result = "USE [$escapedTargetDb];`r`nGO`r`n" + $result
        }
    }

    # Enforce SQL Server's persisted module SET options in the prepared copy.
    # An explicit final OFF in the source is preserved as developer intent and
    # logged as a warning by the deployment plan.
    $result = Add-DDMRequiredCreateSettings -SqlText $result

    if ($CreateOrAlter) {
        $result = [regex]::Replace(
            $result,
            '(?im)^(\s*)CREATE\s+(?!OR\s+ALTER\s+)(PROCEDURE|PROC|VIEW)\b',
            '$1CREATE OR ALTER $2'
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($DbMapServer) -and
        -not [string]::IsNullOrWhiteSpace($DbMapSource) -and
        -not [string]::IsNullOrWhiteSpace($DbMapReplacement) -and
        $ServerInstance.Equals($DbMapServer,[System.StringComparison]::OrdinalIgnoreCase)) {

        $escapedSource = [regex]::Escape($DbMapSource)
        $result = [regex]::Replace(
            $result,
            $escapedSource,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($m)
                return $DbMapReplacement
            },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    return $result
}

function New-DDMPreparedSqlFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$ServerInstance,
        [string]$SelectedDatabase = '',
        [bool]$ManageUseStatements = $false,
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true,
        [bool]$CreateOrAlter = $false,
        [string]$DbMapServer = '',
        [string]$DbMapSource = '',
        [string]$DbMapReplacement = ''
    )

    $sqlText = Get-Content -LiteralPath $SourceFile -Raw

    if ($null -eq $sqlText) {
        $sqlText = ''
    }

    if ([string]::IsNullOrWhiteSpace($sqlText)) {
        throw "SQL source file is empty: $SourceFile"
    }

    $preparedText = Convert-DDMSqlText `
        -SqlText $sqlText `
        -ServerInstance $ServerInstance `
        -SelectedDatabase $SelectedDatabase `
        -ManageUseStatements $ManageUseStatements `
        -UseMappings $UseMappings `
        -DefaultToTargetDatabase $DefaultToTargetDatabase `
        -CreateOrAlter $CreateOrAlter `
        -DbMapServer $DbMapServer `
        -DbMapSource $DbMapSource `
        -DbMapReplacement $DbMapReplacement

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) (
        "DatabaseDeployment_Prepared_" + [guid]::NewGuid().ToString('N') + '.sql'
    )

    Write-DDMUtf8NoBomFile -Path $tempFile -Text $preparedText
    return $tempFile
}

function Write-DDMEngineLog {
    param(
        [scriptblock]$LogAction,
        [string]$Message,
        [string]$Level = 'Info'
    )

    if ($LogAction) {
        & $LogAction $Message $Level
    }
}

function Invoke-DDMDeploymentPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Servers,
        [Parameter(Mandatory)][string]$Database,
        [object[]]$InitializationItems = @(),
        [object[]]$DeploymentItems = @(),
        [Parameter(Mandatory)][string]$SqlCmdExe,
        [int]$QueryTimeout = 120,
        [string]$AwsExe = '',
        [bool]$UseAwsProfile = $false,
        [string]$AwsProfile = '',
        [bool]$CreateOrAlter = $false,
        [bool]$ManageUseStatements = $false,
        [hashtable]$UseMappings = @{},
        [bool]$DefaultToTargetDatabase = $true,
        [string]$DbMapServer = '',
        [string]$DbMapSource = '',
        [string]$DbMapReplacement = '',
        [scriptblock]$LogAction
    )

    # Normalize scalar/list inputs and defensively flatten any accidentally
    # nested collections. A deployment item must always be a PSCustomObject-like
    # value with Origin, Source, and DisplayName properties.
    $Servers = @($Servers)

    $InitializationItems = @(
        $InitializationItems | ForEach-Object {
            if ($_ -is [System.Array]) {
                $_ | ForEach-Object { $_ }
            }
            else {
                $_
            }
        }
    )

    $DeploymentItems = @(
        $DeploymentItems | ForEach-Object {
            if ($_ -is [System.Array]) {
                $_ | ForEach-Object { $_ }
            }
            else {
                $_
            }
        }
    )

    foreach ($item in @($InitializationItems) + @($DeploymentItems)) {
        if ($null -eq $item -or
            -not $item.PSObject.Properties['Origin'] -or
            -not $item.PSObject.Properties['Source'] -or
            -not $item.PSObject.Properties['DisplayName']) {
            throw 'Deployment engine received an invalid deployment item. Refresh the review list and try again.'
        }

        if ([string]::IsNullOrWhiteSpace([string]$item.Source)) {
            throw "Deployment engine received an item with an empty Source: $($item.DisplayName)"
        }
    }

    if ($Servers.Count -eq 0) {
        throw 'At least one target server is required.'
    }

    if ([string]::IsNullOrWhiteSpace($Database)) {
        throw 'A target database is required.'
    }

    $allItems = @($InitializationItems) + @($DeploymentItems)
    $usesS3 = @($allItems | Where-Object { $_.Origin -eq 'S3' }).Count -gt 0

    if ($usesS3 -and [string]::IsNullOrWhiteSpace($AwsExe)) {
        throw 'AWS CLI is required because the deployment plan contains S3 items.'
    }

    $itemResults = @()
    $errors = @()

    foreach ($server in $Servers) {
        Write-DDMEngineLog $LogAction "Starting deployment to $server / $Database." 'Info'

        if (-not [string]::IsNullOrWhiteSpace($DbMapServer) -and
            $server.Equals($DbMapServer,[System.StringComparison]::OrdinalIgnoreCase)) {
            Write-DDMEngineLog $LogAction "SQL text mapping active: $DbMapSource -> $DbMapReplacement" 'Warning'
        }

        foreach ($phase in @(
            [pscustomobject]@{ Name='Initialization'; Items=@($InitializationItems) },
            [pscustomobject]@{ Name='Deployment'; Items=@($DeploymentItems) }
        )) {
            foreach ($item in $phase.Items) {
                $sourceFile = [string]$item.Source
                $s3TempFile = $null
                $preparedFile = $null
                $succeeded = $false
                $errorText = ''

                try {
                    if ($item.Origin -eq 'S3') {
                        $prefix = if ($phase.Name -eq 'Initialization') { 'Init' } else { 'Deploy' }
                        $s3TempFile = Join-Path ([System.IO.Path]::GetTempPath()) (
                            "DatabaseDeployment_${prefix}_" + [guid]::NewGuid().ToString('N') + '.sql'
                        )

                        Write-DDMEngineLog $LogAction "Retrieving S3 object $($item.Source)..." 'Info'

                        [void](Copy-DDMS3Object `
                            -AwsExe $AwsExe `
                            -SourceUri $item.Source `
                            -Destination $s3TempFile `
                            -UseProfile $UseAwsProfile `
                            -ProfileName $AwsProfile)

                        $sourceFile = $s3TempFile
                    }

                    $sourceSqlText = Get-Content -LiteralPath $sourceFile -Raw
                    if ($null -ne $sourceSqlText -and -not [string]::IsNullOrWhiteSpace($sourceSqlText)) {
                        $setOptionInfo = Get-DDMModuleSetOptionInfo -SqlText $sourceSqlText
                        foreach ($warning in @($setOptionInfo.Warnings)) {
                            Write-DDMEngineLog `
                                $LogAction `
                                "$($item.DisplayName): $warning" `
                                'Warning'
                        }
                    }

                    $preparedFile = New-DDMPreparedSqlFile `
                        -SourceFile $sourceFile `
                        -ServerInstance $server `
                        -SelectedDatabase $Database `
                        -ManageUseStatements $ManageUseStatements `
                        -UseMappings $UseMappings `
                        -DefaultToTargetDatabase $DefaultToTargetDatabase `
                        -CreateOrAlter $CreateOrAlter `
                        -DbMapServer $DbMapServer `
                        -DbMapSource $DbMapSource `
                        -DbMapReplacement $DbMapReplacement

                    if ($phase.Name -eq 'Initialization') {
                        Write-DDMEngineLog $LogAction "Initializing with $($item.DisplayName) on $server / $Database..." 'Info'
                    }
                    else {
                        Write-DDMEngineLog $LogAction "Executing $($item.DisplayName) on $server / $Database..." 'Info'
                    }

                    $output = Invoke-DDMSqlCmdFile `
                        -ServerInstance $server `
                        -Database $Database `
                        -FilePath $preparedFile `
                        -SqlCmdExe $SqlCmdExe `
                        -QueryTimeout $QueryTimeout

                    if (-not [string]::IsNullOrWhiteSpace($output)) {
                        Write-DDMEngineLog $LogAction $output 'Raw'
                    }

                    $succeeded = $true

                    if ($phase.Name -eq 'Initialization') {
                        Write-DDMEngineLog $LogAction "Initialization completed: $($item.DisplayName)" 'Success'
                    }
                    else {
                        Write-DDMEngineLog $LogAction "Completed $($item.DisplayName) on $server." 'Success'
                    }
                }
                catch {
                    $errorText = $_.Exception.Message

                    $errors += [pscustomobject]@{
                        Server      = $server
                        Database    = $Database
                        Phase       = $phase.Name
                        DisplayName = [string]$item.DisplayName
                        Source      = [string]$item.Source
                        Error       = $errorText
                    }

                    Write-DDMEngineLog `
                        $LogAction `
                        "$($phase.Name) FAILED for $($item.DisplayName) on $server. $errorText" `
                        'Error'

                    # Deliberately continue with the next item. SQL validation,
                    # compilation, and other item-level failures should not
                    # prevent the remainder of a deployment batch from running.
                }
                finally {
                    $itemResults += [pscustomobject]@{
                        Server      = $server
                        Database    = $Database
                        Phase       = $phase.Name
                        DisplayName = [string]$item.DisplayName
                        Source      = [string]$item.Source
                        Success     = $succeeded
                        Error       = $errorText
                    }

                    if ($preparedFile -and (Test-Path -LiteralPath $preparedFile)) {
                        if ($succeeded) {
                            Remove-Item -LiteralPath $preparedFile -Force -ErrorAction SilentlyContinue
                        }
                        else {
                            Write-DDMEngineLog $LogAction "Prepared SQL kept for troubleshooting: $preparedFile" 'Warning'
                        }
                    }

                    if ($s3TempFile -and (Test-Path -LiteralPath $s3TempFile)) {
                        Remove-Item -LiteralPath $s3TempFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        $serverErrors = @($errors | Where-Object { $_.Server -eq $server }).Count

        if ($serverErrors -eq 0) {
            Write-DDMEngineLog $LogAction "Completed deployment to $server / $Database with no errors." 'Success'
        }
        else {
            Write-DDMEngineLog $LogAction "Completed deployment to $server / $Database with $serverErrors error(s)." 'Warning'
        }
    }

    $itemResults = @($itemResults)
    $errors = @($errors)

    return [pscustomobject]@{
        Servers             = @($Servers)
        Database            = $Database
        InitializationCount = @($InitializationItems).Count
        DeploymentCount     = @($DeploymentItems).Count
        ItemResults         = @($itemResults)
        Errors              = @($errors)
        ErrorCount          = @($errors).Count
        Success             = (@($errors).Count -eq 0)
    }
}

Export-ModuleMember -Function @(
    'Get-DDMRelativePath',
    'Get-DDMAwsCliPath',
    'Get-DDMAwsProfileArgs',
    'Invoke-DDMAwsJson',
    'Get-DDMS3Buckets',
    'Get-DDMS3Objects',
    'Test-DDMS3Object',
    'Copy-DDMS3Object',
    'Get-DDMVersionFromText',
    'Get-DDMFileHeaderVersion',
    'Get-DDMS3ObjectHeaderVersion',
    'Get-DDMModuleSetOptionInfo',
    'Add-DDMRequiredCreateSettings',
    'Resolve-DDMUseDatabase',
    'Get-DDMUseStatementInfo',
    'Get-DDMFileUseStatementInfo',
    'Get-DDMS3ObjectUseStatementInfo',
    'Get-DDMFileSystemCandidates',
    'Get-DDMSqlCmdPath',
    'Invoke-DDMSqlCmdText',
    'Invoke-DDMSqlCmdFile',
    'Convert-DDMSqlText',
    'New-DDMPreparedSqlFile',
    'Invoke-DDMDeploymentPlan'
)
