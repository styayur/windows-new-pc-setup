function Write-WhinsetPlanHuman {
    param([Parameter(Mandatory)]$Plan, [switch]$Detailed)
    Write-Output ''
    Write-Output ("Whinset {0}  plan {1}" -f $Plan.WhinsetVersion, $Plan.PlanHash.Substring(0,12))
    Write-Output ("Host: {0}  Windows build {1}  {2}" -f $Plan.Environment.ComputerName, $Plan.Environment.BuildNumber, $Plan.Environment.Architecture)
    Write-Output ("Profile: {0}  Groups: {1}" -f $Plan.Request.Profile, (@($Plan.Request.Groups) -join ', '))
    Write-Output ("Packages: {0} selected, {1} already present, {2} to change, {3} unknown" -f $Plan.Selection.SelectedCount, $Plan.Selection.AlreadyInstalledCount, $Plan.Selection.MissingCount, $Plan.Selection.UnknownCount)
    $elevationText = 'none'
    if ([bool]$Plan.Summary.RequiresElevation) {
        if ([int]$Plan.Summary.UacPromptsExpected -eq 1) { $elevationText = 'one UAC authorization, all elevated operations consolidated' }
        else { $elevationText = 'already elevated; no second UAC' }
    }
    Write-Output ("Elevation: {0}" -f $elevationText)
    $rebootText = 'none expected'
    if ([bool]$Plan.Summary.PendingRebootNow) { $rebootText = 'a restart is already pending' }
    elseif ([bool]$Plan.Summary.RebootPossible) { $rebootText = 'possible; operations stop cleanly and resume after restart' }
    Write-Output ("Reboot: {0}" -f $rebootText)
    Write-Output ''
    Write-Output 'Execution order'
    $index = 0
    foreach ($operationId in @($Plan.Order)) {
        $operation = @($Plan.Operations | Where-Object { $_.Id -eq $operationId })[0]
        $index++
        $action = 'configure'
        if ($operation.Action -eq 'none') { $action = 'installed' }
        elseif ($operation.Action -eq 'install') { $action = 'install' }
        elseif ($operation.Action -eq 'fail-conflict') { $action = 'conflict' }
        $identity = $operation.PackageId
        if (-not $identity) { $identity = $operation.Kind }
        Write-Output ("{0,2}. [{1,-9}] {2,-30} {3,-28} {4}" -f $index, $action, $operation.Name, $operation.Privilege, $identity)
        if ($Detailed -or ($operation.PSObject.Properties['Error'] -and $operation.Error)) {
            if ($operation.Description) { Write-Output ("    {0}" -f $operation.Description) }
            if ($operation.InventoryStatus -and $operation.InventoryStatus -ne 'Unknown') { Write-Output ("    inventory: {0}" -f $operation.InventoryStatus) }
        }
    }
    if (@($Plan.Warnings).Count -gt 0) {
        Write-Output ''
        Write-Output 'Warnings'
        foreach ($warning in @($Plan.Warnings)) { Write-Output "  - $warning" }
    }
    if (@($Plan.Blockers).Count -gt 0) {
        Write-Output ''
        Write-Output 'Blockers'
        foreach ($blocker in @($Plan.Blockers)) { Write-Output "  - $blocker" }
    }
    Write-Output ''
    Write-Output 'Recovery limits'
    foreach ($limitation in @($Plan.RecoveryLimitations)) { Write-Output "  - $limitation" }
    Write-Output ''
    Write-Output 'Review the full plan and software/source licenses. Apply requires -AcceptAgreements.'
}

function Write-WhinsetApplyHuman {
    param([Parameter(Mandatory)]$Result)
    $state = $Result.State
    $color = 'Green'
    if ($Result.ExitCode -eq 3010) { $color = 'Yellow' }
    elseif ($Result.ExitCode -ne 0) { $color = 'Red' }
    Write-Output ''
    Write-Output ("Whinset apply: {0} (exit {1})" -f $state.Status, $Result.ExitCode) -ForegroundColor $color
    Write-Output $state.Detail
    $state.Operations | Select-Object -Property @('Name','Privilege','Status','Attempts','Detail','Error') | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
    Write-Output ("State: {0}" -f $Result.Paths.RunDirectory)
    Write-Output ("Log:   {0}" -f $Result.Paths.EventsPath)
    if ($Result.PSObject.Properties['Error'] -and $Result.Error) { Write-Output ("Error: {0}" -f $Result.Error) }
    if ($Result.ExitCode -eq 3010) { Write-Output 'Restart Windows, then run: whinset recover -Retry' }
    elseif ($Result.ExitCode -ne 0) { Write-Output 'Run whinset recover for recovery guidance.' }
}

function Get-WhinsetStatusObject {
    param([string]$StateRoot = '', [string]$RunId = '')
    if (-not $StateRoot) { $StateRoot = Get-WhinsetDefaultStateRoot }
    $StateRoot = [IO.Path]::GetFullPath($StateRoot)
    $runs = @(Get-WhinsetRunInventory -StateRoot $StateRoot)
    $legacy = @(Get-WhinsetLegacyRunInventory -LegacyRoot (Get-WhinsetLegacyStateRoot))
    $selected = $null
    if ($RunId) {
        $found = Find-WhinsetRunByRunId -StateRoot $StateRoot -RunId $RunId
        if (-not $found) { throw "No run found for RunId '$RunId' under $StateRoot" }
        $selected = $found.State
    } else {
        $latestDirectory = Get-WhinsetLatestRunDirectory -StateRoot $StateRoot
        if ($latestDirectory) { $selected = Read-WhinsetRunState -Path (Join-Path $latestDirectory 'state.json') }
        elseif ($runs.Count -gt 0) { $selected = Read-WhinsetRunState -Path (Join-Path $runs[0].RunDirectory 'state.json') }
    }
    $recovery = $null
    if ($selected) { $recovery = Get-WhinsetRecoveryPlan -State $selected }
    return [pscustomobject][ordered]@{ Ok=$true; StateRoot=$StateRoot; HasRun=($null -ne $selected); Latest=$selected; Recovery=$recovery; Runs=$runs; LegacyRuns=$legacy }
}

function Write-WhinsetStatusHuman {
    param([Parameter(Mandatory)]$Status)
    Write-Output ("Whinset state: {0}" -f $Status.StateRoot)
    if (-not $Status.HasRun) { Write-Output 'No Whinset runs found. Use whinset plan first.' }
    else {
        $state = $Status.Latest
        Write-Output ("Run {0}  {1}  exit {2}  updated {3}" -f $state.RunId, $state.Status, $state.ExitCode, $state.UpdatedAt)
        $state.Operations | Select-Object -Property @('Name','Privilege','Status','Attempts','Detail','Error') | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
    }
    if ($Status.Runs.Count -gt 1) {
        Write-Output 'Recent runs'
        $Status.Runs | Select-Object -First 10 -Property @('RunId','Status','ExitCode','UpdatedAt','RunDirectory') | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
    }
    if ($Status.LegacyRuns.Count -gt 0) {
        Write-Output 'Legacy SetupNewPC state (read-only compatibility)'
        $Status.LegacyRuns | Select-Object -First 10 -Property @('Status','Profile','UpdatedAt','LegacyStatePath') | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
    }
}

function Get-WhinsetDoctorReport {
    param([string]$StateRoot = '')
    $checks = @()
    $environment = Get-WhinsetEnvironmentSnapshot
    $checks += [pscustomobject][ordered]@{ Name='Windows 11'; Status=$(if ($environment.IsWindows11) { 'PASS' } else { 'FAIL' }); Detail=$environment.Caption }
    $checks += [pscustomobject][ordered]@{ Name='64-bit process'; Status=$(if ($environment.Is64BitProcess) { 'PASS' } else { 'FAIL' }); Detail=$environment.Architecture }
    $psStatus = 'PASS'
    if ($PSVersionTable.PSVersion.Major -lt 7) { $psStatus = 'WARN' }
    $checks += [pscustomobject][ordered]@{ Name='PowerShell'; Status=$psStatus; Detail="$($environment.PowerShellVersion) $($environment.PowerShellEdition)" }
    $checks += [pscustomobject][ordered]@{ Name='WinGet'; Status=$(if ($environment.WingetAvailable -and $environment.WingetVersionOk) { 'PASS' } else { 'FAIL' }); Detail=$environment.WingetVersion }
    $sources = Get-WhinsetWingetSources
    $checks += [pscustomobject][ordered]@{ Name='WinGet sources'; Status=$(if ($sources.Success) { 'PASS' } else { 'FAIL' }); Detail=$sources.Output }
    $catalogPath = Join-Path (Get-WhinsetRepositoryRoot) 'config\packages.json'
    $catalog = $null
    try { $catalog = Read-WhinsetCatalog -Path $catalogPath; $checks += [pscustomobject][ordered]@{ Name='Catalog'; Status='PASS'; Detail="Schema 2, $($catalog.Packages.Count) packages, $($catalog.Profiles.Count) profiles" } }
    catch { $checks += [pscustomobject][ordered]@{ Name='Catalog'; Status='FAIL'; Detail=$_.Exception.Message } }
    if ($catalog) {
        try {
            $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
            $trust = Test-WhinsetPlanTrust -Plan $plan
            $status = 'PASS'; if (-not $trust.Valid) { $status = 'FAIL' }
            $checks += [pscustomobject][ordered]@{ Name='Plan engine'; Status=$status; Detail=("Plan {0}; {1} operations" -f $plan.PlanHash.Substring(0,12), $plan.Operations.Count) }
        } catch { $checks += [pscustomobject][ordered]@{ Name='Plan engine'; Status='FAIL'; Detail=$_.Exception.Message } }
    }
    if (-not $StateRoot) { $StateRoot = Get-WhinsetDefaultStateRoot }
    $checks += [pscustomobject][ordered]@{ Name='State root'; Status='PASS'; Detail=$StateRoot }
    $legacy = Get-WhinsetLegacyStateRoot
    $legacyExists = Test-Path -LiteralPath $legacy
    $checks += [pscustomobject][ordered]@{ Name='Legacy state'; Status='PASS'; Detail=$(if ($legacyExists) { "Preserved read-only at $legacy" } else { 'None detected' }) }
    $pending = @($environment.PendingReboot)
    $checks += [pscustomobject][ordered]@{ Name='Pending reboot'; Status=$(if ($pending.Count -gt 0) { 'WARN' } else { 'PASS' }); Detail=$(if ($pending.Count -gt 0) { $pending -join ', ' } else { 'None' }) }
    $checks += [pscustomobject][ordered]@{ Name='Elevation'; Status='PASS'; Detail=$(if ($environment.IsAdministrator) { 'Current process is elevated' } else { 'Standard user context; apply requests one UAC only when the plan requires it' }) }
    $failures = @($checks | Where-Object { $_.Status -eq 'FAIL' })
    return [pscustomobject][ordered]@{ Ok=($failures.Count -eq 0); Status=$(if ($failures.Count -eq 0) { 'Healthy' } else { 'Unhealthy' }); Checks=$checks; Environment=$environment; Failures=$failures }
}

function Write-WhinsetDoctorHuman {
    param([Parameter(Mandatory)]$Report)
    Write-Output ("Whinset doctor: {0}" -f $Report.Status) -ForegroundColor $(if ($Report.Ok) { 'Green' } else { 'Red' })
    $Report.Checks | Select-Object -Property @('Name','Status','Detail') | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
}

function Get-WhinsetResolveResult {
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][string]$Query)
    $candidates = @(Get-WhinsetPackageCandidates -Catalog $Catalog -Query $Query)
    return [pscustomobject][ordered]@{ Ok=($candidates.Count -gt 0); Query=$Query; Count=$candidates.Count; Candidates=$candidates }
}

function Write-WhinsetResolveHuman {
    param([Parameter(Mandatory)]$Result)
    if ($Result.Count -eq 0) { Write-Output "No package candidates matched '$($Result.Query)'."; return }
    Write-Output "Package candidates for '$($Result.Query)'"
    $Result.Candidates | ForEach-Object { [pscustomobject][ordered]@{ Key=$_.Key; Name=$_.Name; Vendor=$_.Vendor; Identity="$($_.Source):$($_.Id)"; Architecture=$_.Architecture; Scope=$_.Scope; Privilege=$_.Privilege } } | Format-Table -AutoSize | Out-String -Width 260 | Write-Output
    Write-Output 'Use Key or exact Source:Id for plan/apply. Display names are never installation selectors.'
}

function Install-WhinsetCli {
    $sourceRoot = Get-WhinsetRepositoryRoot
    if ($env:WHINSET_INSTALL_ROOT) { $localRoot = [IO.Path]::GetFullPath($env:WHINSET_INSTALL_ROOT) } else { $localRoot = Join-Path $env:LOCALAPPDATA 'Whinset' }
    $current = Join-Path $localRoot 'current'
    $alreadyInstalled = ([IO.Path]::GetFullPath($sourceRoot) -ieq [IO.Path]::GetFullPath($current))
    if (-not $alreadyInstalled) {
        $staging = Join-Path $localRoot ('staging-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        try {
            $files = @('whinset.ps1','whinset.cmd','whinset.sh','whinset.nu','README.md','LICENSE','SECURITY.md')
            foreach ($file in $files) {
                $source = Join-Path $sourceRoot $file
                if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $staging $file) -Force }
            }
            foreach ($directory in @('config','src')) {
                $source = Join-Path $sourceRoot $directory
                if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $staging $directory) -Recurse -Force }
            }
            if (Test-Path -LiteralPath $current) {
                $resolvedCurrent = [IO.Path]::GetFullPath($current)
                $resolvedLocal = [IO.Path]::GetFullPath($localRoot).TrimEnd('\') + '\'
                if (-not $resolvedCurrent.StartsWith($resolvedLocal, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to replace a path outside the Whinset local install root.' }
                Remove-Item -LiteralPath $resolvedCurrent -Recurse -Force
            }
            Move-Item -LiteralPath $staging -Destination $current
        } catch {
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            throw
        }
    }
    $priorPath = [Environment]::GetEnvironmentVariable('Path','User')
    $entries = @($priorPath -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
    $pathAdded = $false
    if ($env:WHINSET_SKIP_PATH_UPDATE -ne '1' -and -not ($entries | Where-Object { $_ -ieq $current.TrimEnd('\') })) {
        $entries += $current.TrimEnd('\')
        [Environment]::SetEnvironmentVariable('Path',($entries -join ';'),'User')
        $pathAdded = $true
    }
    return [pscustomobject][ordered]@{ Ok=$true; InstallRoot=$current; PathAdded=$pathAdded; PriorUserPath=$priorPath; RestartShell=$pathAdded; CommandHint=$(if ($pathAdded) { 'Open a new terminal, then run: whinset version' } else { 'Run: whinset version' }) }
}

function Complete-WhinsetPackageParameter {
    param([string]$WordToComplete = '', [string]$ParameterName = 'Package')
    try {
        $catalog = Read-WhinsetCatalog -Path (Join-Path (Get-WhinsetRepositoryRoot) 'config\packages.json')
        foreach ($package in $catalog.Packages) {
            $key = $package.Key
            if ($WordToComplete -and $key -notlike "$WordToComplete*" -and $package.Id -notlike "$WordToComplete*") { continue }
            [System.Management.Automation.CompletionResult]::new($key, $key, [System.Management.Automation.CompletionResultType]::ParameterValue, "$($package.Name) [$($package.Source):$($package.Id)]")
        }
    } catch { }
}

function Register-WhinsetCompleters {
    $commands = @('help','plan','apply','status','doctor','resolve','recover','install-cli','version')
    $profiles = @('Minimal','Developer','AI','Engineering','Full')
    $groups = @('Core','Developer','AI','Engineering','Personal')
    $stages = @('Auto','WindowsBase','Development')
    $commandCompleter = { param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters) foreach ($candidate in $commands) { if (-not $wordToComplete -or $candidate -like "$wordToComplete*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) } } }.GetNewClosure()
    $profileCompleter = { param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters) foreach ($candidate in $profiles) { if (-not $wordToComplete -or $candidate -like "$wordToComplete*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) } } }.GetNewClosure()
    $groupCompleter = { param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters) foreach ($candidate in $groups) { if (-not $wordToComplete -or $candidate -like "$wordToComplete*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) } } }.GetNewClosure()
    $stageCompleter = { param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters) foreach ($candidate in $stages) { if (-not $wordToComplete -or $candidate -like "$wordToComplete*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) } } }.GetNewClosure()
    foreach ($commandName in @('Invoke-Whinset','whinset')) {
        Register-ArgumentCompleter -CommandName $commandName -ParameterName Command -ScriptBlock $commandCompleter -ErrorAction SilentlyContinue
        Register-ArgumentCompleter -CommandName $commandName -ParameterName Profile -ScriptBlock $profileCompleter -ErrorAction SilentlyContinue
        Register-ArgumentCompleter -CommandName $commandName -ParameterName Group -ScriptBlock $groupCompleter -ErrorAction SilentlyContinue
        Register-ArgumentCompleter -CommandName $commandName -ParameterName Stage -ScriptBlock $stageCompleter -ErrorAction SilentlyContinue
        Register-ArgumentCompleter -CommandName $commandName -ParameterName Package -ScriptBlock { param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters) Complete-WhinsetPackageParameter -WordToComplete $wordToComplete -ParameterName 'Package' } -ErrorAction SilentlyContinue
        Register-ArgumentCompleter -CommandName $commandName -ParameterName Exclude -ScriptBlock { param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters) Complete-WhinsetPackageParameter -WordToComplete $wordToComplete -ParameterName 'Exclude' } -ErrorAction SilentlyContinue
    }
}
