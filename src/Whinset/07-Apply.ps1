function Get-WhinsetActionableOperations {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$State)
    $result = @()
    foreach ($operation in @($Plan.Operations)) {
        if ($operation.Action -eq 'none') { continue }
        $record = Get-WhinsetOperationRecord -State $State -OperationId $operation.Id
        if ($record -and (Test-WhinsetOperationTerminalSuccess -Status $record.Status)) { continue }
        $result += $operation
    }
    return $result
}

function Reset-WhinsetStateForReconcile {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$FreshState)
    foreach ($record in @($State.Operations)) {
        $record.Status = 'Pending'
        $record.Attempts = 0
        $record.StartedAt = $null
        $record.EndedAt = $null
        $record.DurationMs = 0
        $record.ExitCode = $null
        $record.Error = ''
        $record.Detail = ''
        $record.RebootRequired = $false
        $record.RecoveryData = $null
    }
    $State.CreatedAt = $FreshState.CreatedAt
    $State.BootId = $FreshState.BootId
    $State.Status = 'Running'
    $State.Detail = 'Fresh reconciliation run using the same deterministic plan.'
    $State.RebootRequired = $false
    $State.Elevation.Required = [bool]$Plan.Summary.RequiresElevation
    $State.Elevation.Attempted = $false
    $State.Elevation.AlreadyElevated = $false
    $State.Elevation.Denied = $false
}

function Get-WhinsetRunContext {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Environment, [Parameter(Mandatory)][string]$StateRoot)
    $paths = Get-WhinsetRunPaths -StateRoot $StateRoot -PlanHash $Plan.PlanHash
    Initialize-WhinsetPrivateRunDirectory -Path $paths.RunDirectory
    $fresh = New-WhinsetRunState -Plan $Plan -Environment $Environment -Paths $paths
    $state = $null
    if (Test-Path -LiteralPath $paths.StatePath) {
        $state = Read-WhinsetRunState -Path $paths.StatePath
        Assert-WhinsetStateMatchesPlan -State $state -Plan $Plan
        if ($state.Status -eq 'AwaitingReboot' -and [string]$state.BootId -eq [string](Get-WhinsetBootId)) {
            Write-WhinsetJsonFileAtomically -Path $paths.PlanPath -Value $Plan
            return [pscustomobject][ordered]@{ Paths=$paths; State=$state; RebootGate=$true; ReusedState=$true }
        }
        if ($state.Status -eq 'Complete') {
            Reset-WhinsetStateForReconcile -State $state -Plan $Plan -FreshState $fresh
        } else {
            if ([string]$state.BootId -ne [string](Get-WhinsetBootId)) {
                $state.BootId = [string](Get-WhinsetBootId)
                $state.RebootRequired = $false
                foreach ($record in @($state.Operations)) { $record.RebootRequired = $false }
            }
            foreach ($record in @($state.Operations)) {
                if ($record.Status -in @('Running','Failed','AwaitingReboot','Blocked')) {
                    $record.Status = 'Pending'
                    $record.Error = ''
                    $record.Detail = 'Resumed after interruption or reboot.'
                    $record.EndedAt = $null
                }
            }
            $state.Status = 'Running'
            $state.Detail = 'Resuming the deterministic plan.'
            $state.Elevation.Denied = $false
            $state.Elevation.Attempted = $false
        }
        $state.Elevation.Required = [bool]((@(Get-WhinsetActionableOperations -Plan $Plan -State $state | Where-Object { $_.Privilege -eq 'elevated' }).Count) -gt 0)
    } else {
        $state = $fresh
        Write-WhinsetRunEvent -RunDirectory $paths.RunDirectory -Type 'run.created' -Data @{ RunId=$Plan.RunId; PlanHash=$Plan.PlanHash; WhinsetVersion=$script:WhinsetVersion }
    }
    Write-WhinsetJsonFileAtomically -Path $paths.PlanPath -Value $Plan
    Save-WhinsetRunState -State $state -Paths $paths
    return [pscustomobject][ordered]@{ Paths=$paths; State=$state; RebootGate=$false; ReusedState=($null -ne $state -and $state.CreatedAt -ne $fresh.CreatedAt) }
}

function Write-WhinsetRunReport {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Paths)
    $report = [ordered]@{
        SchemaVersion = 1
        GeneratedAt = Get-WhinsetTimestamp
        WhinsetVersion = $script:WhinsetVersion
        Plan = $Plan
        State = $State
        Recovery = Get-WhinsetRecoveryPlan -State $State
    }
    Write-WhinsetJsonFileAtomically -Path $Paths.ReportPath -Value $report -Depth 60
    return $report
}

function Get-WhinsetPowerShellExecutable {
    $processPath = (Get-Process -Id $PID).Path
    if ($processPath) { return $processPath }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Invoke-WhinsetElevation {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Paths)
    $nonce = [guid]::NewGuid().ToString('N')
    $request = [ordered]@{
        SchemaVersion = 1
        RunId = $Plan.RunId
        PlanHash = $Plan.PlanHash
        PlanPath = $Paths.PlanPath
        Nonce = $nonce
        OriginalUserSid = (Get-WhinsetMachineIdentity).UserSid
        CreatedAt = Get-WhinsetTimestamp
    }
    Write-WhinsetJsonFileAtomically -Path $Paths.ElevationRequestPath -Value $request
    Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'elevation.start' -Data @{ Nonce=$nonce; PlanHash=$Plan.PlanHash }
    if (Test-Path -LiteralPath $Paths.ElevatedResultPath) { Remove-Item -LiteralPath $Paths.ElevatedResultPath -Force }
    $worker = Join-Path (Get-WhinsetRepositoryRoot) 'src\Whinset.ElevatedWorker.ps1'
    if (-not (Test-Path -LiteralPath $worker)) { throw "Elevated worker not found: $worker" }
    $powerShell = Get-WhinsetPowerShellExecutable
    $workerArguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker,'-PlanPath',$Paths.PlanPath,'-PlanHash',$Plan.PlanHash,'-Nonce',$nonce)
    $argumentString = (@($workerArguments | ForEach-Object { ConvertTo-NativeArgument -Argument ([string]$_) }) -join ' ')
    try {
        $process = Start-Process -FilePath $powerShell -ArgumentList $argumentString -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
    } catch {
        $message = $_.Exception.Message
        $nativeCode = Get-WhinsetNativeErrorCode -Exception $_.Exception
        $denied = ($nativeCode -eq 1223)
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'elevation.exception' -Data @{ Denied=$denied; NativeErrorCode=$nativeCode; Error=$message }
        return [pscustomobject][ordered]@{ Granted=$false; Denied=$denied; ExitCode=$null; Error=$message; Result=$null }
    }
    $processExit = $null
    try { $processExit = $process.ExitCode } catch { }
    if (Test-Path -LiteralPath $Paths.ElevatedResultPath) {
        try {
            $result = Read-WhinsetJsonFile -Path $Paths.ElevatedResultPath
            if ($result.SchemaVersion -ne 1 -or $result.Nonce -cne $nonce -or $result.PlanHash -cne $Plan.PlanHash -or $result.RunId -ne $Plan.RunId -or $null -eq $processExit -or [int]$result.ExitCode -ne [int]$processExit) { throw 'Elevated result identity, nonce or process exit code does not match.' }
        } catch {
            $errorText = $_.Exception.Message
            Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'elevation.invalid-result' -Data @{ ExitCode=$processExit; Error=$errorText }
            return [pscustomobject]@{ Granted=$true; Denied=$false; ExitCode=$processExit; Error=$errorText; Result=$null }
        }
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'elevation.end' -Data @{ ExitCode=$result.ExitCode; Error=$result.Error }
        return [pscustomobject][ordered]@{ Granted=$true; Denied=$false; ExitCode=$result.ExitCode; Error=[string]$result.Error; Result=$result }
    }
    $errorText = "Elevated worker exited without a result file (process exit $processExit)."
    Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'elevation.end' -Data @{ ExitCode=$processExit; Error=$errorText }
    return [pscustomobject][ordered]@{ Granted=$true; Denied=$false; ExitCode=$processExit; Error=$errorText; Result=$null }
}

function Invoke-WhinsetElevatedWorker {
    param([Parameter(Mandatory)][string]$PlanPath, [Parameter(Mandatory)][string]$PlanHash, [Parameter(Mandatory)][string]$Nonce)
    $runDirectory = Split-Path $PlanPath -Parent
    $resultPath = Join-Path $runDirectory 'elevated-result.json'
    $statePath = Join-Path $runDirectory 'state.json'
    $requestPath = Join-Path $runDirectory 'elevation-request.json'
    $validated = $false
    try {
        if (-not (Test-WhinsetIsAdministrator)) { throw 'Elevated worker requires an administrator token.' }
        $currentSid = [string](Get-WhinsetMachineIdentity).UserSid
        foreach ($path in @($runDirectory,$PlanPath,$statePath,$requestPath)) { Assert-WhinsetPrivatePath -Path $path -UserSid $currentSid }
        if (-not (Test-Path -LiteralPath $requestPath)) { throw 'Elevation request file is missing.' }
        $request = Read-WhinsetJsonFile -Path $requestPath
        if ([string]$request.Nonce -ne $Nonce -or [string]$request.PlanHash -ne $PlanHash) { throw 'Elevation request nonce or plan hash does not match.' }
        $plan = Get-WhinsetTrustedPlan -PlanPath $PlanPath -ExpectedPlanHash $PlanHash
        $state = Read-WhinsetRunState -Path $statePath
        Assert-WhinsetElevationRequest -Request $request -Plan $plan -State $state -PlanPath $PlanPath -PlanHash $PlanHash -Nonce $Nonce
        $expectedDirectory = Join-Path (Split-Path $runDirectory -Parent) $PlanHash
        if ([IO.Path]::GetFullPath($runDirectory) -ine [IO.Path]::GetFullPath($expectedDirectory)) { throw 'Run directory does not match plan hash.' }
        $claimPath = Join-Path $runDirectory ('elevation-consumed-' + $Nonce)
        $claim = [IO.File]::Open($claimPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $claim.Dispose()
        $validated = $true
        $state.ElevatedUserSid = [string](Get-WhinsetMachineIdentity).UserSid
        $state.Elevation.Attempted = $true
        $state.Elevation.AlreadyElevated = $false
        $baseRoot = Split-Path (Split-Path $runDirectory -Parent) -Parent
        $paths = Get-WhinsetRunPaths -StateRoot $baseRoot -PlanHash $PlanHash
        Save-WhinsetRunState -State $state -Paths $paths
        Write-WhinsetRunEvent -RunDirectory $runDirectory -Type 'elevated-worker.start' -Data @{ PlanHash=$PlanHash; UserSid=$state.ElevatedUserSid }
        [void](Invoke-WhinsetOperationGraph -Plan $plan -State $state -Paths $paths -Privilege 'elevated')
        $statuses = @($state.Operations | ForEach-Object { $_.Status })
        $exitCode = 0
        if ($statuses -contains 'AwaitingReboot') { $exitCode = [int]$script:WhinsetExitCodes.RebootRequired }
        elseif ($statuses -contains 'Failed' -or $statuses -contains 'Blocked') { $exitCode = [int]$script:WhinsetExitCodes.OperationFailed }
        $result = [pscustomobject][ordered]@{ SchemaVersion=1; Nonce=$Nonce; RunId=$plan.RunId; PlanHash=$PlanHash; ExitCode=$exitCode; Status='ElevatedPhaseFinished'; Error=''; FinishedAt=(Get-WhinsetTimestamp) }
        Write-WhinsetJsonFileAtomically -Path $resultPath -Value $result
        Write-WhinsetRunEvent -RunDirectory $runDirectory -Type 'elevated-worker.end' -Data @{ ExitCode=$exitCode }
        return $result
    } catch {
        $result = [pscustomobject][ordered]@{ SchemaVersion=1; Nonce=$Nonce; RunId=$null; PlanHash=$PlanHash; ExitCode=1; Status='ElevatedPhaseFailed'; Error=$_.Exception.Message; FinishedAt=(Get-WhinsetTimestamp) }
        if ($validated) {
            $result.RunId = $plan.RunId
            try { Write-WhinsetJsonFileAtomically -Path $resultPath -Value $result } catch { }
        }
        throw
    }
}

function Invoke-WhinsetPackagePreflightRecheck {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Paths)
    $changed = $false
    foreach ($operation in @($Plan.Operations | Where-Object { $_.Kind -eq 'package' })) {
        $record = Get-WhinsetOperationRecord -State $State -OperationId $operation.Id
        # Recheck packages even when a partial prior run recorded success.
        $package = [pscustomobject][ordered]@{ Key=$operation.PackageKey; Id=$operation.PackageId; Source=$operation.Source; Architecture=$operation.Architecture; Scope=$operation.Scope; Version=$operation.Version; VersionPolicy=$operation.VersionPolicy }
        $probe = Test-WhinsetPackageInstalled -Package $package -AcceptAgreements
        if ($probe.Installed -and ($package.VersionPolicy -ne 'pinned' -or $probe.VersionVerified)) {
            $operation.Action = 'none'
            Set-WhinsetOperationRecord -State $State -OperationId $operation.Id -Status 'AlreadyInstalled' -Detail 'Rechecked immediately before elevation; no installer was started.' -ExitCode 0
            $changed = $true
        } elseif ($probe.Installed -and $package.VersionPolicy -eq 'pinned' -and -not $probe.VersionVerified) {
            $operation.Action = 'fail-conflict'
            Set-WhinsetOperationRecord -State $State -OperationId $operation.Id -Status 'Failed' -Error "Installed version differs from pinned $($package.Version). No upgrade or downgrade was attempted." -ExitCode $probe.ExitCode
            $changed = $true
        } elseif ($probe.Error) {
            Set-WhinsetOperationRecord -State $State -OperationId $operation.Id -Status 'Failed' -Error $probe.Error -ExitCode $probe.ExitCode
            $changed = $true
        } else {
            $operation.Action = 'install'
            Set-WhinsetOperationRecord -State $State -OperationId $operation.Id -Status 'Pending' -Detail 'Package is missing; install remains pending.'
            $changed = $true
        }
    }
    if ($changed) { Save-WhinsetRunState -State $State -Paths $Paths }
}

function Invoke-WhinsetApplyPlanUnlocked {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$StateRoot, [switch]$AcceptAgreements)
    if (-not $AcceptAgreements) { throw 'Review the plan and software/source licenses, then pass -AcceptAgreements to execute.' }
    Assert-WhinsetSameUser -OriginalUserSid $Plan.Environment.UserSid -CurrentUserSid ([string](Get-WhinsetMachineIdentity).UserSid)
    $trust = Test-WhinsetPlanTrust -Plan $Plan
    if (-not $trust.Valid) { throw ('Plan validation failed: ' + ($trust.Errors -join ' ')) }
    if (@($Plan.Blockers).Count -gt 0) { throw ('Apply is blocked: ' + (@($Plan.Blockers) -join ' ')) }
    $environment = $Plan.Environment
    $context = Get-WhinsetRunContext -Plan $Plan -Environment $environment -StateRoot $StateRoot
    $paths = $context.Paths
    $state = $context.State
    if ($context.RebootGate) {
        Write-WhinsetRunEvent -RunDirectory $paths.RunDirectory -Type 'run.reboot-gate' -Data @{ BootId=$state.BootId }
        $report = Write-WhinsetRunReport -Plan $Plan -State $state -Paths $paths
        return [pscustomobject][ordered]@{ ExitCode=[int]$script:WhinsetExitCodes.RebootRequired; Status='AwaitingReboot'; Plan=$Plan; State=$state; Paths=$paths; Report=$report }
    }
    Write-WhinsetRunEvent -RunDirectory $paths.RunDirectory -Type 'run.start' -Data @{ RunId=$Plan.RunId; PlanHash=$Plan.PlanHash; UserSid=$environment.UserSid; IsAdministrator=$environment.IsAdministrator }

    Invoke-WhinsetPackagePreflightRecheck -Plan $Plan -State $state -Paths $paths
    [void](Invoke-WhinsetOperationGraph -Plan $Plan -State $state -Paths $paths -Privilege 'user')
    $statuses = @($state.Operations | ForEach-Object { $_.Status })
    if ($statuses -notcontains 'AwaitingReboot') {
        $elevatedActionable = @(Get-WhinsetActionableOperations -Plan $Plan -State $state | Where-Object { $_.Privilege -eq 'elevated' })
        $state.Elevation.Required = ($elevatedActionable.Count -gt 0)
        if ($elevatedActionable.Count -gt 0) {
            if ($environment.IsAdministrator) {
                $state.Elevation.AlreadyElevated = $true
                $state.Elevation.Attempted = $true
                Save-WhinsetRunState -State $state -Paths $paths
                Write-WhinsetRunEvent -RunDirectory $paths.RunDirectory -Type 'elevation.already-elevated'
                [void](Invoke-WhinsetOperationGraph -Plan $Plan -State $state -Paths $paths -Privilege 'elevated')
            } else {
                $state.Elevation.Attempted = $true
                Save-WhinsetRunState -State $state -Paths $paths
                $elevation = Invoke-WhinsetElevation -Plan $Plan -Paths $paths
                if (-not $elevation.Granted) {
                    $state = Read-WhinsetRunState -Path $paths.StatePath
                    if ($elevation.Denied) { $state.Status = 'ElevationDenied' } else { $state.Status = 'CompletedWithFailures' }
                    if ($elevation.Denied) { $state.Detail = 'Administrator authorization was declined. No elevated operation was started.' }
                    else { $state.Detail = "Elevation failed before the worker started: $($elevation.Error)" }
                    $state.Elevation.Denied = [bool]$elevation.Denied
                    Save-WhinsetRunState -State $state -Paths $paths
                    $report = Write-WhinsetRunReport -Plan $Plan -State $state -Paths $paths
                    if ($elevation.Denied) { $exitCode = [int]$script:WhinsetExitCodes.ElevationDenied }
                    else { $exitCode = [int]$script:WhinsetExitCodes.OperationFailed }
                    return [pscustomobject][ordered]@{ ExitCode=$exitCode; Status=$state.Status; Plan=$Plan; State=$state; Paths=$paths; Report=$report; Error=$elevation.Error }
                }
                $state = Read-WhinsetRunState -Path $paths.StatePath
                if (-not $elevation.Result -or ($elevation.Result.PSObject.Properties["Error"] -and $elevation.Result.Error)) {
                    $state = Read-WhinsetRunState -Path $paths.StatePath
                    $state.Status = "CompletedWithFailures"
                    $state.Detail = "Elevated worker did not complete cleanly: $($elevation.Error)"
                    Save-WhinsetRunState -State $state -Paths $paths
                    $report = Write-WhinsetRunReport -Plan $Plan -State $state -Paths $paths
                    return [pscustomobject][ordered]@{ ExitCode=[int]$script:WhinsetExitCodes.OperationFailed; Status=$state.Status; Plan=$Plan; State=$state; Paths=$paths; Report=$report; Error=$elevation.Error }
                }
            }
        }
        $statuses = @($state.Operations | ForEach-Object { $_.Status })
        if ($statuses -notcontains 'AwaitingReboot') { [void](Invoke-WhinsetOperationGraph -Plan $Plan -State $state -Paths $paths -Privilege 'user') }
    }

    $state = Read-WhinsetRunState -Path $paths.StatePath
    $statuses = @($state.Operations | ForEach-Object { $_.Status })
    if ($statuses -contains 'AwaitingReboot') {
        $state.Status = 'AwaitingReboot'
        $state.Detail = 'A restart is required. Restart Windows, then run whinset apply with the same options or whinset recover -Retry.'
        $exitCode = [int]$script:WhinsetExitCodes.RebootRequired
    } elseif ($statuses -contains 'Failed' -or $statuses -contains 'Blocked') {
        $state.Status = 'CompletedWithFailures'
        $state.Detail = 'One or more operations failed. Review operation errors and use whinset recover.'
        $exitCode = [int]$script:WhinsetExitCodes.OperationFailed
    } elseif ($statuses -contains 'Pending' -or $statuses -contains 'Running') {
        $state.Status = 'Incomplete'
        $state.Detail = 'Some operations did not run. Inspect blockers and retry.'
        $exitCode = [int]$script:WhinsetExitCodes.OperationFailed
    } else {
        $state.Status = 'Complete'
        $state.Detail = 'All selected operations completed or were verified as already present.'
        $exitCode = [int]$script:WhinsetExitCodes.Success
    }
    Save-WhinsetRunState -State $state -Paths $paths
    $report = Write-WhinsetRunReport -Plan $Plan -State $state -Paths $paths
    Write-WhinsetRunEvent -RunDirectory $paths.RunDirectory -Type 'run.end' -Data @{ Status=$state.Status; ExitCode=$exitCode }
    return [pscustomobject][ordered]@{ ExitCode=$exitCode; Status=$state.Status; Plan=$Plan; State=$state; Paths=$paths; Report=$report }
}

function Invoke-WhinsetApplyPlan {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$StateRoot, [switch]$AcceptAgreements)
    $mutexName = 'Local\Whinset-v2'
    if ($env:WHINSET_MUTEX_NAME) { $mutexName = [string]$env:WHINSET_MUTEX_NAME }
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another Whinset apply is already running. Wait for it to finish before retrying.' }
        return (Invoke-WhinsetApplyPlanUnlocked -Plan $Plan -StateRoot $StateRoot -AcceptAgreements:$AcceptAgreements)
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}
function Invoke-WhinsetApply {
    param(
        [string]$CatalogPath = '',
        [string]$Profile = 'Developer',
        [string[]]$Package = @(),
        [string[]]$Exclude = @(),
        [string[]]$Group = @(),
        [switch]$IncludePersonal,
        [switch]$SkipStoreApps,
        [ValidateSet('Auto','WindowsBase','Development')][string]$Stage = 'Auto',
        [switch]$ConfigureEnvironment,
        [switch]$SkipCondaInit,
        [switch]$EnableWsl,
        [switch]$EnableDocker,
        [switch]$DockerSmokeTest,
        [switch]$ApplicationsOnly,
        [ValidateRange(1,5)][int]$MaxAttempts = 2,
        [ValidateRange(30,14400)][int]$InstallTimeoutSeconds = 3600,
        [switch]$AcceptAgreements,
        [string]$StateDirectory = ''
    )
    if (-not $CatalogPath) { $CatalogPath = Join-Path (Get-WhinsetRepositoryRoot) 'config\packages.json' }
    $plan = New-WhinsetPlan -CatalogPath $CatalogPath -Profile $Profile -Package $Package -Exclude $Exclude -Group $Group -IncludePersonal:$IncludePersonal -SkipStoreApps:$SkipStoreApps -Stage $Stage -ConfigureEnvironment:$ConfigureEnvironment -SkipCondaInit:$SkipCondaInit -EnableWsl:$EnableWsl -EnableDocker:$EnableDocker -DockerSmokeTest:$DockerSmokeTest -ApplicationsOnly:$ApplicationsOnly -MaxAttempts $MaxAttempts -InstallTimeoutSeconds $InstallTimeoutSeconds
    if (-not $StateDirectory) { $StateDirectory = Get-WhinsetDefaultStateRoot }
    return (Invoke-WhinsetApplyPlan -Plan $plan -StateRoot $StateDirectory -AcceptAgreements:$AcceptAgreements)
}

function Find-WhinsetRunByRunId {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$RunId)
    $runsRoot = Join-Path ([IO.Path]::GetFullPath($StateRoot)) 'runs'
    if (-not (Test-Path -LiteralPath $runsRoot)) { return $null }
    foreach ($directory in @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue)) {
        $statePath = Join-Path $directory.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath)) { continue }
        try { $state = Read-WhinsetRunState -Path $statePath; if ([string]$state.RunId -eq $RunId) { return [pscustomobject]@{ Directory=$directory.FullName; StatePath=$statePath; PlanPath=(Join-Path $directory.FullName 'plan.json'); State=$state } } } catch { }
    }
    return $null
}

function Invoke-WhinsetResumeRun {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)][string]$RunId)
    $found = Find-WhinsetRunByRunId -StateRoot $StateRoot -RunId $RunId
    if (-not $found) { throw "No Whinset run found for RunId '$RunId' under $StateRoot" }
    $stored = Read-WhinsetJsonFile -Path $found.PlanPath
    $plan = Get-WhinsetTrustedPlan -PlanPath $found.PlanPath -ExpectedPlanHash ([string]$stored.PlanHash)
    return (Invoke-WhinsetApplyPlan -Plan $plan -StateRoot $StateRoot -AcceptAgreements)
}
