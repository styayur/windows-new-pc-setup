#requires -Version 5.1
# Dependency-free regression suite. Never invokes real installers or Windows features.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SetupNewPC-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:passed = 0
$script:failed = 0
function Assert($Condition, [string]$Message = 'Assertion failed') {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '*') {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true; Assert ($_.Exception.Message -like $Pattern) "Unexpected error: $_" }
    Assert $caught 'Expected an exception'
}
function Test([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "FAIL $Name : $_`n$($_.ScriptStackTrace)" -ForegroundColor Red }
}
function Initialize-Fixture {
    $script:Profile = 'Developer'; $script:ExtraGroups = @(); $script:IncludePersonal = $false
    $script:SkipStoreApps = $false; $script:SkipWSL = $true; $script:SkipDocker = $true
    $script:SkipWinUtil = $true; $script:ConfigureEnvironment = $false; $script:ConfirmEach = $false
    $script:ApplicationsOnly = $false; $script:Stage = 'Auto'; $script:MaxAttempts = 2
    $script:InstallTimeoutSeconds = 30; $script:Failures = @(); $script:ItemResults = [ordered]@{}
    $script:EnvironmentResults = @(); $script:InstallerRebootRequired = $false; $script:UserSkipped = $false; $script:StopInstallations = $false
    $script:CurrentStatus = 'Running'; $script:CurrentDetail = ''; $script:LastCompletedStage = 'None'
    $script:StateVersion = 4; $script:ConfigurationHash = 'test-hash'; $script:MachineIdentity = 'test-machine/user'
    $script:StateDir = Join-Path $testRoot ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $script:StateDir | Out-Null
    $script:StateFile = Join-Path $script:StateDir 'state.json'
    $script:EnvironmentReportFile = Join-Path $script:StateDir 'environment-report.json'
    $script:EnvironmentReportTextFile = Join-Path $script:StateDir 'environment-report.txt'
    $script:Catalog = @(Read-PackageCatalog (Join-Path $root 'config/packages.json'))
    $script:SelectedPackages = @($script:Catalog | Where-Object { Test-ItemInSelectedGroups $_ })
    $script:calls = @(); $script:queue = New-Object Collections.Queue
}
function Result([int]$Code = 0, [string]$Output = '', [bool]$TimedOut = $false) {
    [pscustomobject]@{ ExitCode=$Code; Output=$Output; Error=''; Success=($Code -eq 0 -and -not $TimedOut); TimedOut=$TimedOut }
}
try {
    . (Join-Path $root 'src/Configuration.ps1')
    . (Join-Path $root 'src/SetupNewPC.Core.ps1')
    Test 'All PowerShell files parse' {
        foreach ($file in Get-ChildItem $root -Filter *.ps1 -Recurse) {
            $tokens=$null; $errors=$null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            Assert ($errors.Count -eq 0) "$($file.Name): $errors"
        }
    }
    Test 'Preview is side-effect free and excludes personal software by default' {
        $path = Join-Path $testRoot 'must-not-exist'
        $plan = & (Join-Path $root 'SetupNewPC_Optimized.ps1') -Profile Minimal -WhatIf -StateDirectory $path
        Assert ($LASTEXITCODE -eq 0)
        Assert ($plan.Packages.Count -eq 5)
        Assert (-not $plan.WSL -and -not $plan.Docker -and -not $plan.WinUtil)
        Assert (-not (Test-Path -LiteralPath $path))
    }
    Test 'Profiles, exclusions, Store filtering and aliases' {
        foreach ($profile in @('Minimal','Developer','AI','Engineering','Full')) {
            $plan = & (Join-Path $root 'Setupnewpc.ps1') -Profile $profile -Plan -Exclude Git -SkipStoreApps
            Assert ($LASTEXITCODE -eq 0)
            Assert ($plan.Packages.Key -notcontains 'Git')
            Assert ($plan.Packages.Source -notcontains 'msstore')
        }
        $plan = & (Join-Path $root 'Install-Applications.WithConfirmation.ps1') -WhatIf -Profile Minimal
        Assert ($LASTEXITCODE -eq 0 -and $plan.Packages.Count -eq 5)
    }
    Test 'Invalid options and missing agreement return exit 2 without state creation' {
        $path = Join-Path $testRoot 'not-created'
        & (Join-Path $root 'SetupNewPC_Optimized.ps1') -StateDirectory $path -WarningAction SilentlyContinue
        Assert ($LASTEXITCODE -eq 2)
        & (Join-Path $root 'SetupNewPC_Optimized.ps1') -WhatIf -EnableDocker -SkipWSL -WarningAction SilentlyContinue
        Assert ($LASTEXITCODE -eq 2)
        & (Join-Path $root 'SetupNewPC_Optimized.ps1') -WhatIf -Exclude Typo -WarningAction SilentlyContinue
        Assert ($LASTEXITCODE -eq 2)
        & (Join-Path $root 'SetupNewPC_Optimized.ps1') -WhatIf -EnableWinUtil -WarningAction SilentlyContinue
        Assert ($LASTEXITCODE -eq 2)
        Assert (-not (Test-Path -LiteralPath $path))
    }
    Test 'Strict catalog validation catches duplicates, typos, types and Docker bypass' {
        Initialize-Fixture
        $file = Join-Path $testRoot 'invalid.json'
        foreach ($json in @(
            '{"SchemaVersion":2,"Packages":[]}',
            '{"SchemaVersion":1,"Packages":[],"Packges":[]}',
            '{"SchemaVersion":1,"Packages":"bad"}',
            '{"SchemaVersion":1,"Packages":[null]}'
        )) {
            Set-Content -LiteralPath $file -Value $json -Encoding UTF8
            Assert-Throws { Read-PackageCatalog $file }
        }
        @{SchemaVersion=1;Packages=@($script:Catalog[0],$script:Catalog[0])} | ConvertTo-Json -Depth 6 | Set-Content $file
        Assert-Throws { Read-PackageCatalog $file } '*Duplicate*'
        $script:Catalog[0].Id = 'Docker.DockerDesktop'
        @{SchemaVersion=1;Packages=@($script:Catalog[0])} | ConvertTo-Json -Depth 6 | Set-Content $file
        Assert-Throws { Read-PackageCatalog $file } '*EnableDocker*'
    }
    Test 'Configuration hash changes when package or options change' {
        Assert ((Get-ConfigurationHash @{WSL=$false}) -ne (Get-ConfigurationHash @{WSL=$true}))
        Assert ((Get-ConfigurationHash @{Id='Git.Git'}) -eq (Get-ConfigurationHash @{Id='Git.Git'}))
    }
    Test 'Example entry point is portable and preview-only' {
        $plan = & (Join-Path $root 'examples/Setup-MyPC.ps1') -WhatIf
        Assert ($LASTEXITCODE -eq 0)
        Assert ($plan.Packages.Key -notcontains 'Postman')
    }
    Test 'Native argument escaping round trips spaces, quotes, Unicode and trailing slashes' {
        $fixture = Join-Path $testRoot 'echo args.ps1'
        '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); ConvertTo-Json -InputObject @($args) -Compress' | Set-Content $fixture -Encoding UTF8
        $exe = (Get-Process -Id $PID).Path
        $values = @('hello world', 'a"b', 'C:\space path\', '', '中文路径')
        $result = Invoke-ExternalCommand -FilePath $exe -ArgumentList (@('-NoProfile','-File',$fixture) + $values) -TimeoutSeconds 30
        Assert $result.Success $result.Error
        $actual = $result.Output | ConvertFrom-Json
        Assert ($actual.Count -eq $values.Count) $result.Output
        for ($i=0; $i -lt $values.Count; $i++) { Assert ($actual[$i] -ceq $values[$i]) "Argument $i mismatch: $($actual[$i])" }
    }
    Test 'Native process timeout is bounded and reported' {
        $exe = (Get-Process -Id $PID).Path
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ExternalCommand -FilePath $exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -TimeoutSeconds 1
        Assert ($result.TimedOut -and -not $result.Success)
        Assert ($watch.Elapsed.TotalSeconds -lt 25)
    }

    # All remaining tests use a fake external process boundary and fake boot/registry.
    function Invoke-ExternalCommand {
        param($FilePath, $ArgumentList, $TimeoutSeconds)
        $script:calls += ,@($ArgumentList)
        if ($script:queue.Count -eq 0) { throw 'Unexpected external invocation in test' }
        return $script:queue.Dequeue()
    }
    function Get-BootId { 'boot-1' }
    function Get-PendingReboot { @() }
    function Update-SessionPath { }
    function Start-Sleep { param($Seconds) }
    Test 'Inventory is locale-independent and source errors are not treated as absent' {
        Initialize-Fixture
        $script:queue.Enqueue((Result 0 '本地化名称，截断 ID'))
        Assert (Test-WingetInstalled 'Git.Git')
        $script:queue.Enqueue((Result -1978335212))
        Assert (-not (Test-WingetInstalled 'Git.Git'))
        $script:queue.Enqueue((Result -1978335163))
        Assert-Throws { Test-WingetInstalled 'Git.Git' } '*inventory failed*'
    }
    Test 'No applicable installer text is a failure, not success' {
        Initialize-Fixture
        $script:MaxAttempts = 1
        $script:queue.Enqueue((Result -1978335212))
        $script:queue.Enqueue((Result -1978335216 'No applicable installer; already installed?'))
        Assert (-not (Invoke-Winget 'Git.Git'))
        Assert ($script:ItemResults['winget:Git.Git'].Status -eq 'Failed')
    }
    Test 'An old success is rechecked and missing software is installed and verified' {
        Initialize-Fixture
        Set-ItemResult -Key 'winget:Git.Git' -Name Git -Status Succeeded
        $script:queue.Enqueue((Result -1978335212))
        $script:queue.Enqueue((Result 0))
        $script:queue.Enqueue((Result 0))
        Assert (Invoke-Winget 'Git.Git')
        Assert ($script:calls.Count -eq 3)
        Assert ($script:calls[1] -contains '--no-upgrade')
    }
    Test 'Transient failure retries, then verifies success' {
        Initialize-Fixture
        foreach ($code in @(-1978335212,-1,-1978335212,0,0)) { $script:queue.Enqueue((Result $code)) }
        Assert (Invoke-Winget 'Git.Git')
        Assert ($script:ItemResults['winget:Git.Git'].Attempts -eq 2)
        Assert ($script:Failures.Count -eq 0)
    }
    Test 'Timeout never retries an installer immediately' {
        Initialize-Fixture
        $script:queue.Enqueue((Result -1978335212))
        $script:queue.Enqueue((Result -1 '' $true))
        Assert (-not (Invoke-Winget 'Git.Git'))
        Assert ($script:calls.Count -eq 2)
        Assert $script:StopInstallations
    }
    Test 'Reboot code is pending, not success, and does not retry' {
        foreach ($code in @(3010,-1978334967,-1978334966)) {
            Initialize-Fixture
            $script:queue.Enqueue((Result -1978335212))
            $script:queue.Enqueue((Result $code))
            Assert (-not (Invoke-Winget 'Git.Git'))
            Assert $script:InstallerRebootRequired
            Assert ($script:ItemResults['winget:Git.Git'].Status -eq 'AwaitingReboot')
            Assert ($script:calls.Count -eq 2)
        }
    }
    Test 'User decline skips installation and records incomplete outcome' {
        Initialize-Fixture
        function Read-Host { param($Prompt) 'N' }
        $script:ConfirmEach = $true
        $script:queue.Enqueue((Result -1978335212))
        Assert (-not (Invoke-Winget 'Git.Git'))
        Assert ($script:calls.Count -eq 1 -and $script:UserSkipped)
        Assert ((Get-FinalStatus) -eq 'Incomplete')
    }
    Test 'Environment configuration does not run for a declined package' {
        Initialize-Fixture
        Set-ItemResult -Key 'winget:astral-sh.uv' -Status Skipped
        Configure-UvEnvironment
        Assert ($script:ItemResults['step:uvStrategy'].Status -eq 'Skipped')
        Assert ($script:calls.Count -eq 0)
    }
    Test 'Pinned versions use structured export; list never receives --version' {
        Initialize-Fixture
        function Invoke-ExternalCommand {
            param($FilePath,$ArgumentList,$TimeoutSeconds)
            $script:calls += ,@($ArgumentList)
            if ($ArgumentList[0] -eq 'export') {
                $file = $ArgumentList[[array]::IndexOf($ArgumentList,'--output')+1]
                '{"Sources":[{"Packages":[{"PackageIdentifier":"Git.Git","Version":"2.0"}]}]}' | Set-Content -LiteralPath $file -Encoding UTF8
            }
            return Result 0
        }
        Assert (Test-WingetInstalled 'Git.Git' -ExtraArgs @('--version','2.0'))
        Assert ($script:calls[0] -notcontains '--version')
        Assert (-not (Test-WingetInstalled 'Git.Git' -ExtraArgs @('--version','1.0')))
        Assert (-not (Invoke-Winget 'Git.Git' -ExtraArgs @('--version','1.0')))
        Assert (@($script:calls | Where-Object { $_[0] -eq 'install' }).Count -eq 0)
        Assert (@(Get-ChildItem $script:StateDir -Filter 'inventory-*.json').Count -eq 0)
    }
    Test 'Atomic state replacement, corruption protection and identity binding' {
        Initialize-Fixture
        Save-SetupState -Status Running
        Save-SetupState -Status Complete
        Assert ((Get-SetupState).Status -eq 'Complete')
        Assert (Test-Path -LiteralPath "$script:StateFile.bak")
        $script:MachineIdentity = 'other/user'
        Assert-Throws { Get-SetupState } '*different*'
        Set-Content -LiteralPath $script:StateFile -Value '{invalid'
        Assert-Throws { Get-SetupState } '*Cannot load state*'
    }
    Test 'Reboot gate requires a changed boot and resumes base reconciliation' {
        Initialize-Fixture
        Save-SetupState -Status AwaitingReboot
        Assert ((Resolve-SetupStage) -eq 'AwaitingReboot')
        function Get-BootId { 'boot-2' }
        Assert ((Resolve-SetupStage) -eq 'WindowsBase')
    }
    Test 'Virtualization disabled in firmware blocks WSL even when CPU supports it' {
        Assert (Test-VirtualizationHardwareBlocker ([pscustomobject]@{HypervisorPresent=$false;VirtualizationFirmwareEnabled=$false;VMMonitorModeExtensions=$true}))
        Assert (-not (Test-VirtualizationHardwareBlocker ([pscustomobject]@{HypervisorPresent=$true;VirtualizationFirmwareEnabled=$false;VMMonitorModeExtensions=$false})))
    }
    Test 'Feature RestartNeeded is honored even without a registry reboot marker' {
        Initialize-Fixture
        $script:SkipWSL = $false
        function Get-VirtualizationReport { [pscustomobject]@{HypervisorPresent=$true;VirtualizationFirmwareEnabled=$true;VMMonitorModeExtensions=$true} }
        function Show-VirtualizationReport { param($Report) }
        function Get-WindowsFeatureState { param($Name) 'Disabled' }
        # Switch parameters must match the Windows cmdlet contract.
        function Enable-WindowsOptionalFeature { param([switch]$Online,$FeatureName,[switch]$All,[switch]$NoRestart,$ErrorAction) [pscustomobject]@{RestartNeeded=$true} }
        Enable-WslPrerequisites
        Assert $script:InstallerRebootRequired
    }
    Test 'An installer timeout stops all later packages in either stage' {
        foreach ($stageName in @('WindowsBase','Development')) {
            Initialize-Fixture
            $script:Stage = $stageName
            $script:SelectedPackages = @($script:Catalog | Where-Object { $_.Stage -eq $stageName } | Select-Object -First 2)
            $script:queue.Enqueue((Result -1978335212))
            $script:queue.Enqueue((Result -1 '' $true))
            Assert ((Invoke-SetupPipeline) -eq 'CompletedWithFailures')
            Assert ($script:calls.Count -eq 2)
            Assert $script:StopInstallations
        }
    }
    Test 'Two full mocked runs converge; the second run installs nothing' {
        Initialize-Fixture
        $script:SelectedPackages = @($script:Catalog | Where-Object { $_.Key -in @('Git','uv') })
        $script:installed = @{}; $script:installCount = 0
        function Invoke-ExternalCommand {
            param($FilePath,$ArgumentList,$TimeoutSeconds)
            $id = $ArgumentList[[array]::IndexOf($ArgumentList,'--id')+1]
            if ($ArgumentList[0] -eq 'list') {
                if ($script:installed.ContainsKey($id)) { return Result 0 }
                return Result -1978335212
            }
            Assert ($ArgumentList[0] -eq 'install')
            $script:installed[$id]=$true; $script:installCount++
            return Result 0
        }
        Assert ((Invoke-SetupPipeline) -eq 'Complete')
        Assert ($script:installCount -eq 2)
        $script:ItemResults = [ordered]@{}
        Initialize-RunState
        Assert ((Invoke-SetupPipeline) -eq 'Complete')
        Assert ($script:installCount -eq 2)
        Assert (Test-Path -LiteralPath $script:EnvironmentReportFile)
    }
    Test 'A failed base package is retried after a later package requests reboot' {
        Initialize-Fixture
        $script:MaxAttempts = 1
        $script:SelectedPackages = @($script:Catalog | Where-Object { $_.Key -in @('PowerShell7','Git') })
        # First package fails, second asks for reboot.
        foreach ($code in @(-1978335212,-1,-1978335212,3010)) { $script:queue.Enqueue((Result $code)) }
        Assert ((Invoke-SetupPipeline) -eq 'AwaitingReboot')
        Assert ((Get-SetupState).Status -eq 'AwaitingReboot')
        Assert ($script:ItemResults['winget:Microsoft.PowerShell'].Status -eq 'Failed')
        function Get-BootId { 'boot-2' }
        $script:InstallerRebootRequired = $false
        $script:ItemResults = [ordered]@{}; $script:Failures = @()
        Initialize-RunState
        # First is installed and verified; second now exists after reboot.
        foreach ($code in @(-1978335212,0,0,0)) { $script:queue.Enqueue((Result $code)) }
        Assert ((Invoke-SetupPipeline) -eq 'Complete')
        Assert ($script:ItemResults['winget:Microsoft.PowerShell'].Status -eq 'Succeeded')
        Assert ($script:ItemResults['winget:Git.Git'].Status -eq 'Succeeded')
    }
} finally {
    # Only this suite's explicit, resolved temporary directory is removed.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'SetupNewPC-tests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host "$script:passed passed; $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
