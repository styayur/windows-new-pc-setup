function Get-WhinsetDefaultStateRoot {
    if ($env:WHINSET_STATE_ROOT) { return [IO.Path]::GetFullPath($env:WHINSET_STATE_ROOT) }
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'Whinset\v2')
}

function Get-WhinsetLegacyStateRoot {
    if ($env:WHINSET_LEGACY_STATE_ROOT) { return [IO.Path]::GetFullPath($env:WHINSET_LEGACY_STATE_ROOT) }
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'SetupNewPC\v2')
}

function Get-WhinsetRunPaths {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$PlanHash)
    $root = [IO.Path]::GetFullPath($StateRoot)
    $runDirectory = [IO.Path]::GetFullPath((Join-Path $root (Join-Path 'runs' $PlanHash)))
    if (-not $runDirectory.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid run directory.' }
    return [pscustomobject][ordered]@{
        StateRoot = $root
        RunDirectory = $runDirectory
        PlanPath = (Join-Path $runDirectory 'plan.json')
        StatePath = (Join-Path $runDirectory 'state.json')
        EventsPath = (Join-Path $runDirectory 'operations.jsonl')
        ReportPath = (Join-Path $runDirectory 'report.json')
        ElevatedResultPath = (Join-Path $runDirectory 'elevated-result.json')
        ElevationRequestPath = (Join-Path $runDirectory 'elevation-request.json')
        LatestPath = (Join-Path $root 'latest.json')
    }
}

function Write-WhinsetRunEvent {
    param([Parameter(Mandatory)][string]$RunDirectory, [Parameter(Mandatory)][string]$Type, [hashtable]$Data = @{})
    $entry = [ordered]@{ Timestamp = Get-WhinsetTimestamp; Type = $Type }
    foreach ($key in @($Data.Keys | Sort-Object)) { $entry[$key] = $Data[$key] }
    Append-WhinsetJsonLine -Path (Join-Path $RunDirectory 'operations.jsonl') -Value $entry
}

function Set-WhinsetLatestRun {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$PlanHash, [string]$Status = '')
    if (-not (Test-Path -LiteralPath $Paths.StateRoot)) { New-Item -ItemType Directory -Path $Paths.StateRoot -Force | Out-Null }
    $latest = [ordered]@{
        SchemaVersion = 1
        RunId = $RunId
        PlanHash = $PlanHash
        RunDirectory = $Paths.RunDirectory
        Status = $Status
        UpdatedAt = Get-WhinsetTimestamp
    }
    Write-WhinsetJsonFileAtomically -Path $Paths.LatestPath -Value $latest
}

function New-WhinsetOperationRecord {
    param([Parameter(Mandatory)]$Operation)
    return [pscustomobject][ordered]@{
        Id = [string]$Operation.Id
        Kind = [string]$Operation.Kind
        Name = [string]$Operation.Name
        Privilege = [string]$Operation.Privilege
        Status = 'Pending'
        Attempts = 0
        StartedAt = $null
        EndedAt = $null
        DurationMs = 0
        ExitCode = $null
        Error = ''
        Detail = ''
        RebootRequired = $false
        Recovery = $Operation.Recovery
        RecoveryData = $null
    }
}

function New-WhinsetRunState {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Environment, [Parameter(Mandatory)]$Paths)
    $operations = @($Plan.Operations | ForEach-Object { New-WhinsetOperationRecord -Operation $_ })
    $now = Get-WhinsetTimestamp
    return [pscustomobject][ordered]@{
        SchemaVersion = $script:WhinsetStateSchemaVersion
        RunId = [string]$Plan.RunId
        PlanHash = [string]$Plan.PlanHash
        Status = 'Running'
        ExitCode = $null
        Detail = ''
        CreatedAt = $now
        UpdatedAt = $now
        MachineIdentity = [ordered]@{ ComputerName = $Environment.ComputerName; UserSid = $Environment.UserSid }
        OriginalUserSid = [string]$Environment.UserSid
        ElevatedUserSid = $null
        BootId = [string]$Environment.BootId
        AgreementAcceptedAt = $now
        Elevation = [ordered]@{ Required = [bool]$Plan.Summary.RequiresElevation; Attempted = $false; AlreadyElevated = $false; Denied = $false }
        RebootRequired = (@($Environment.PendingReboot).Count -gt 0)
        Operations = $operations
        Summary = [ordered]@{ Pending = $operations.Count; Running = 0; Succeeded = 0; AlreadyInstalled = 0; Skipped = 0; Warning = 0; Failed = 0; AwaitingReboot = 0; Blocked = 0 }
        Paths = [ordered]@{ RunDirectory = $Paths.RunDirectory; Plan = $Paths.PlanPath; Events = $Paths.EventsPath; Report = $Paths.ReportPath }
    }
}

function Get-WhinsetStateSummary {
    param([Parameter(Mandatory)]$State)
    $summary = [ordered]@{ Pending = 0; Running = 0; Succeeded = 0; AlreadyInstalled = 0; Skipped = 0; Warning = 0; Failed = 0; AwaitingReboot = 0; Blocked = 0 }
    foreach ($operation in @($State.Operations)) {
        $status = [string]$operation.Status
        if ($summary.Contains($status)) { $summary[$status] = [int]$summary[$status] + 1 }
    }
    return $summary
}

function Get-WhinsetExitCodeFromState {
    param([Parameter(Mandatory)]$State)
    $statuses = @($State.Operations | ForEach-Object { [string]$_.Status })
    if ($statuses -contains 'AwaitingReboot') { return [int]$script:WhinsetExitCodes.RebootRequired }
    if ($statuses -contains 'Failed') { return [int]$script:WhinsetExitCodes.OperationFailed }
    if ($statuses -contains 'Blocked') { return [int]$script:WhinsetExitCodes.OperationFailed }
    if ($State.Status -eq 'ElevationDenied') { return [int]$script:WhinsetExitCodes.ElevationDenied }
    if ($State.Status -eq 'Canceled') { return [int]$script:WhinsetExitCodes.Canceled }
    if ($statuses -contains 'Pending' -or $statuses -contains 'Running') { return [int]$script:WhinsetExitCodes.OperationFailed }
    return [int]$script:WhinsetExitCodes.Success
}

function Get-WhinsetStatusFromState {
    param([Parameter(Mandatory)]$State)
    $statuses = @($State.Operations | ForEach-Object { [string]$_.Status })
    if ($statuses -contains 'AwaitingReboot') { return 'AwaitingReboot' }
    if ($statuses -contains 'Failed') { return 'CompletedWithFailures' }
    if ($statuses -contains 'Blocked') { return 'CompletedWithFailures' }
    if ($State.Status -eq 'ElevationDenied') { return 'ElevationDenied' }
    if ($State.Status -eq 'Canceled') { return 'Canceled' }
    if ($statuses -contains 'Pending' -or $statuses -contains 'Running') { return 'Incomplete' }
    return 'Complete'
}

function Save-WhinsetRunState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Paths)
    $State.UpdatedAt = Get-WhinsetTimestamp
    $State.Summary = Get-WhinsetStateSummary -State $State
    $State.ExitCode = Get-WhinsetExitCodeFromState -State $State
    Write-WhinsetJsonFileAtomically -Path $Paths.StatePath -Value $State
    Set-WhinsetLatestRun -Paths $Paths -RunId $State.RunId -PlanHash $State.PlanHash -Status $State.Status
}

function Read-WhinsetRunState {
    param([Parameter(Mandatory)][string]$Path)
    $state = Read-WhinsetJsonFile -Path $Path
    if ([int]$state.SchemaVersion -ne [int]$script:WhinsetStateSchemaVersion) { throw "Unsupported state schema in $Path" }
    return $state
}

function Get-WhinsetOperationRecord {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$OperationId)
    foreach ($operation in @($State.Operations)) {
        if ([string]$operation.Id -eq $OperationId) { return $operation }
    }
    return $null
}

function Set-WhinsetOperationRecord {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = '',
        [string]$Error = '',
        [AllowNull()]$ExitCode = $null,
        [switch]$IncrementAttempt,
        [AllowNull()]$RecoveryData = $null,
        [switch]$RebootRequired
    )
    $record = Get-WhinsetOperationRecord -State $State -OperationId $OperationId
    if ($null -eq $record) { throw "Unknown operation in state: $OperationId" }
    $record.Status = $Status
    $record.Detail = $Detail
    $record.Error = $Error
    $record.ExitCode = $ExitCode
    if ($IncrementAttempt) { $record.Attempts = [int]$record.Attempts + 1 }
    if ($PSBoundParameters.ContainsKey('RecoveryData')) { $record.RecoveryData = $RecoveryData }
    if ($RebootRequired) { $record.RebootRequired = $true; $State.RebootRequired = $true }
    if ($Status -eq 'Running') { $record.StartedAt = Get-WhinsetTimestamp }
    if ($Status -in @('Succeeded','AlreadyInstalled','Skipped','Warning','Failed','AwaitingReboot','Blocked')) { $record.EndedAt = Get-WhinsetTimestamp }
    if ($record.StartedAt -and $record.EndedAt) {
        try { $record.DurationMs = [int](([datetime]$record.EndedAt) - ([datetime]$record.StartedAt)).TotalMilliseconds } catch { $record.DurationMs = 0 }
    }
}

function Get-WhinsetLatestRunDirectory {
    param([Parameter(Mandatory)][string]$StateRoot)
    $root = [IO.Path]::GetFullPath($StateRoot)
    $latestPath = Join-Path $root 'latest.json'
    if (-not (Test-Path -LiteralPath $latestPath)) { return $null }
    $latest = Read-WhinsetJsonFile -Path $latestPath
    $directory = [IO.Path]::GetFullPath([string]$latest.RunDirectory)
    if (-not $directory.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'latest.json points outside the Whinset state root.' }
    if (-not (Test-Path -LiteralPath $directory)) { return $null }
    return $directory
}

function Get-WhinsetRunInventory {
    param([Parameter(Mandatory)][string]$StateRoot)
    $runsRoot = Join-Path ([IO.Path]::GetFullPath($StateRoot)) 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) { return @() }
    $runs = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue)) {
        $statePath = Join-Path $directory.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath)) { continue }
        try {
            $state = Read-WhinsetRunState -Path $statePath
            $runs += [pscustomobject][ordered]@{
                RunId = $state.RunId
                PlanHash = $state.PlanHash
                Status = $state.Status
                ExitCode = $state.ExitCode
                CreatedAt = $state.CreatedAt
                UpdatedAt = $state.UpdatedAt
                RunDirectory = $directory.FullName
                Summary = $state.Summary
            }
        } catch { }
    }
    return @($runs | Sort-Object UpdatedAt -Descending)
}

function Get-WhinsetLegacyRunInventory {
    param([Parameter(Mandatory)][string]$LegacyRoot)
    if (-not (Test-Path -LiteralPath $LegacyRoot)) { return @() }
    $runs = @()
    foreach ($statePath in @(Get-ChildItem -LiteralPath $LegacyRoot -Recurse -Filter 'state.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $legacy = Get-Content -LiteralPath $statePath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $runs += [pscustomobject][ordered]@{
                LegacyStatePath = $statePath.FullName
                Version = $legacy.Version
                Status = $legacy.Status
                Profile = $legacy.Profile
                Stage = $legacy.Stage
                BootId = $legacy.BootId
                UpdatedAt = $legacy.UpdatedAt
                ConfigurationHash = $legacy.ConfigurationHash
                Compatibility = 'read-only; rerun whinset plan/apply to reconcile installed packages'
            }
        } catch { }
    }
    return @($runs | Sort-Object UpdatedAt -Descending)
}

function Get-WhinsetRecoveryPlan {
    param([Parameter(Mandatory)]$State)
    $pending = @($State.Operations | Where-Object { $_.Status -in @('Pending','Running','Failed','AwaitingReboot','Blocked') } | ForEach-Object {
        [pscustomobject][ordered]@{ Id = $_.Id; Name = $_.Name; Status = $_.Status; Privilege = $_.Privilege; Error = $_.Error; Recovery = $_.Recovery; RecoveryData = $_.RecoveryData }
    })
    return [pscustomobject][ordered]@{
        RunId = $State.RunId
        PlanHash = $State.PlanHash
        Status = $State.Status
        RebootRequired = [bool]$State.RebootRequired
        CurrentBootId = Get-WhinsetBootId
        RecordedBootId = $State.BootId
        SameBoot = ([string]$State.BootId -eq (Get-WhinsetBootId))
        PendingOperations = $pending
        RetryCommand = "whinset recover -RunId $($State.RunId) -Retry"
    }
}
