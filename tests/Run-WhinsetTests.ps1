#requires -Version 5.1
# Dependency-free Whinset tests. No real installers, Windows features or UAC prompts are used.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Whinset-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$script:oldWhinsetMutexName = $env:WHINSET_MUTEX_NAME
$env:WHINSET_MUTEX_NAME = 'Local\Whinset-tests-' + $PID + '-' + [guid]::NewGuid().ToString('N')
$script:WhinsetRoot = $root
. (Join-Path $root 'src/Configuration.ps1')
. (Join-Path $root 'src/SetupNewPC.Core.ps1')
Get-ChildItem -LiteralPath (Join-Path $root 'src/Whinset') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
. (Join-Path $root 'scripts/Bootstrap.ps1')
$script:passed = 0
$script:failed = 0
function Assert($Condition, [string]$Message = 'Assertion failed') { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '*') {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true; Assert ($_.Exception.Message -like $Pattern) "Unexpected error: $_" }
    Assert $caught 'Expected an exception'
}
function Test([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name : $_`n$($_.ScriptStackTrace)" }
}
function New-TestEnvironment([bool]$IsAdministrator = $false, [bool]$WingetAvailable = $true) {
    return [pscustomobject][ordered]@{
        Caption='Windows 11 Test'; OsVersion='10.0.26100'; BuildNumber=26100; ProductType=1; IsWindows11=$true
        PowerShellVersion='7.0.0'; PowerShellEdition='Core'; Is64BitProcess=$true; Architecture='x64'
        IsAdministrator=$IsAdministrator; ComputerName='TEST-PC'; UserSid='S-1-5-21-TEST'
        UserProfile=(Join-Path $testRoot 'user'); LocalAppData=(Join-Path $testRoot 'local'); Temp=$testRoot
        WingetAvailable=$WingetAvailable; WingetVersion='1.9.0'; WingetVersionOk=$WingetAvailable
        PendingReboot=@(); Blockers=@(); Warnings=@(); BootId='boot-1'
    }
}
function Copy-TestPackage($Package, [string]$Key, [string]$Id = '', [string]$Source = '') {
    $copy = $Package | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $copy.Key = $Key
    if ($Id) { $copy.Id = $Id }
    if ($Source) { $copy.Source = $Source }
    if ($copy.PSObject.Properties['Version'] -and -not $copy.Version) { $copy.PSObject.Properties.Remove('Version') }
    return $copy
}
try {
    $catalogPath = Join-Path $root 'config/packages.json'
    Test 'Catalog schema 2 has complete metadata and profile definitions' {
        $catalog = Read-WhinsetCatalog -Path $catalogPath
        Assert ($catalog.SchemaVersion -eq 2)
        Assert ($catalog.Packages.Count -eq 38)
        Assert ($catalog.Profiles.Count -eq 5)
        foreach ($package in $catalog.Packages) {
            Assert ($package.Key -and $package.Vendor -and $package.Id -and $package.Source)
            Assert ($package.Architecture -in @('auto','x64','arm64','neutral'))
            Assert ($package.Privilege -in @('user','elevated'))
            Assert ($package.Recovery.Class -in @('automatic','manual','external'))
        }
    }
    Test 'Display names are not installation selectors' {
        $catalog = Read-WhinsetCatalog -Path $catalogPath
        Assert-Throws { Resolve-WhinsetPackageReference -Catalog $catalog -Reference 'Google Chrome' } '*Display names are not installation selectors*'
        $pkg = Resolve-WhinsetPackageReference -Catalog $catalog -Reference 'Chrome'
        Assert ($pkg.Id -eq 'Google.Chrome')
    }
    Test 'Same package ID in different sources requires source qualification' {
        $catalog = Read-WhinsetCatalog -Path $catalogPath
        $base = $catalog.Packages[0]
        $one = Copy-TestPackage $base 'CrossSourceWinget' 'Example.App' 'winget'
        $two = Copy-TestPackage $base 'CrossSourceStore' 'Example.App' 'msstore'
        $document = [ordered]@{ SchemaVersion=2; CatalogVersion='test'; Profiles=$catalog.Profiles; Groups=$catalog.Groups; Packages=@($one,$two) }
        $path = Join-Path $testRoot 'cross-source.json'
        $document | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8
        $fixture = Read-WhinsetCatalog -Path $path
        Assert-Throws { Resolve-WhinsetPackageReference -Catalog $fixture -Reference 'Example.App' } '*multiple sources*'
        Assert ((Resolve-WhinsetPackageReference -Catalog $fixture -Reference 'winget:Example.App').Key -eq 'CrossSourceWinget')
        Assert ((Resolve-WhinsetPackageReference -Catalog $fixture -Reference 'msstore:Example.App').Key -eq 'CrossSourceStore')
    }
    Test 'Dependency cycles are rejected' {
        $catalog = Read-WhinsetCatalog -Path $catalogPath
        $a = Copy-TestPackage $catalog.Packages[0] 'CycleA'
        $b = Copy-TestPackage $catalog.Packages[1] 'CycleB'
        $a.Dependencies = @('CycleB'); $b.Dependencies = @('CycleA')
        $document = [ordered]@{ SchemaVersion=2; CatalogVersion='test'; Profiles=$catalog.Profiles; Groups=$catalog.Groups; Packages=@($a,$b) }
        $path = Join-Path $testRoot 'cycle.json'
        $document | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8
        $fixture = Read-WhinsetCatalog -Path $path
        Assert-Throws { Test-WhinsetCatalogCycles -Catalog $fixture } '*Dependency cycle*'
    }
    Test 'Package conflicts are rejected before execution' {
        $catalog = Read-WhinsetCatalog -Path $catalogPath
        $a = Copy-TestPackage $catalog.Packages[0] 'ConflictA'
        $b = Copy-TestPackage $catalog.Packages[1] 'ConflictB'
        $a.Conflicts = @('ConflictB')
        $document = [ordered]@{ SchemaVersion=2; CatalogVersion='test'; Profiles=$catalog.Profiles; Groups=$catalog.Groups; Packages=@($a,$b) }
        $path = Join-Path $testRoot 'conflict.json'
        $document | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8
        $fixture = Read-WhinsetCatalog -Path $path
        Assert-Throws { Resolve-WhinsetSelection -Catalog $fixture -Profile Minimal -Package @('ConflictA','ConflictB') } '*conflict*'
    }
    Test 'Dependency auto-selection produces deterministic DAG order' {
        $environment = New-TestEnvironment
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Package 'uv' -Offline -Environment $environment
        $order = @($plan.Order)
        $pythonIndex = [array]::IndexOf($order,'package:SystemPython')
        $uvIndex = [array]::IndexOf($order,'package:uv')
        Assert ($pythonIndex -ge 0 -and $uvIndex -gt $pythonIndex) "Order: $($order -join ', ')"
    }
    Test 'Plan hashes are deterministic and planning creates no state directory' {
        $environment = New-TestEnvironment
        $stateRoot = Join-Path $testRoot 'plan-must-not-create'
        $one = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $two = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        Assert ($one.PlanHash -eq $two.PlanHash)
        Assert ($one.Order.Count -eq $two.Order.Count)
        Assert (-not (Test-Path -LiteralPath $stateRoot))
    }
    Test 'Human plan formatting handles all operation shapes' {
        $environment = New-TestEnvironment
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        Write-WhinsetPlanHuman -Plan $plan -Detailed | Out-Null
    }
    Test 'Architecture mismatch fails before execution' {
        $catalog = Read-WhinsetCatalog -Path $catalogPath
        $pkg = Copy-TestPackage $catalog.Packages[0] 'ArmOnly' 'Example.ArmOnly' 'winget'
        $pkg.Architecture = 'arm64'
        $document = [ordered]@{ SchemaVersion=2; CatalogVersion='test'; Profiles=$catalog.Profiles; Groups=$catalog.Groups; Packages=@($pkg) }
        $path = Join-Path $testRoot 'architecture.json'
        $document | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8
        $environment = New-TestEnvironment
        $environment.Architecture = 'x64'
        Assert-Throws { New-WhinsetPlan -CatalogPath $path -Profile Minimal -Package 'ArmOnly' -Offline -Environment $environment } '*requires arm64*'
    }
    Test 'Plan distinguishes user and elevated operations and expects one UAC' {
        $environment = New-TestEnvironment -IsAdministrator $false
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Developer -ConfigureEnvironment -Offline -Environment $environment
        $gitLfs = @($plan.Operations | Where-Object Id -eq 'config:git-lfs')[0]
        $java = @($plan.Operations | Where-Object Id -eq 'config:java-home')[0]
        Assert ($gitLfs.Privilege -eq 'user')
        Assert ($java.Privilege -eq 'elevated')
        Assert ($plan.Summary.UacPromptsExpected -eq 1)
        Assert ($plan.Summary.RequiresElevation)
    }
    Test 'Already-elevated plans expect no second UAC' {
        $environment = New-TestEnvironment -IsAdministrator $true
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        Assert ($plan.Summary.RequiresElevation)
        Assert ($plan.Summary.UacPromptsExpected -eq 0)
    }
    Test 'Plan trust reconstruction rejects catalog substitution' {
        $environment = New-TestEnvironment
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $paths = Get-WhinsetRunPaths -StateRoot (Join-Path $testRoot 'trust') -PlanHash $plan.PlanHash
        New-Item -ItemType Directory -Path $paths.RunDirectory -Force | Out-Null
        Write-WhinsetJsonFileAtomically -Path $paths.PlanPath -Value $plan
        $trusted = Get-WhinsetTrustedPlan -PlanPath $paths.PlanPath -ExpectedPlanHash $plan.PlanHash
        Assert ($trusted.PlanHash -eq $plan.PlanHash)
        $tampered = Get-Content $paths.PlanPath -Raw | ConvertFrom-Json
        $tampered.Identity.Catalog.Sha256 = ('0' * 64)
        Write-WhinsetJsonFileAtomically -Path $paths.PlanPath -Value $tampered
        Assert-Throws { Get-WhinsetTrustedPlan -PlanPath $paths.PlanPath -ExpectedPlanHash $plan.PlanHash } '*catalog hash*'
    }
    $script:probeInstalled = $false
    $script:probeError = ''
    $script:elevationCalls = 0
    $script:elevationMode = 'grant'
    $script:adminInstallCalls = 0
    function Get-WhinsetMachineIdentity { [pscustomobject][ordered]@{ ComputerName='TEST-PC'; UserSid='S-1-5-21-TEST' } }
    # This suite simulates orchestration. Real temporary-file ACL checks live in Run-HardeningTests.ps1.
    function Initialize-WhinsetPrivateRunDirectory { param($Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    function Assert-WhinsetPrivatePath { param($Path,$UserSid) }
    function Test-WhinsetIsAdministrator { return $true }
    function Test-WhinsetPackageInstalled {
        param($Package, [switch]$AcceptAgreements)
        if ($script:probeError) { return [pscustomobject][ordered]@{ Installed=$false; VersionVerified=$false; Error=$script:probeError; ExitCode=-1 } }
        return [pscustomobject][ordered]@{ Installed=[bool]$script:probeInstalled; VersionVerified=[bool]$script:probeInstalled; Error=''; ExitCode=$(if ($script:probeInstalled) { 0 } else { -1978335212 }) }
    }
    function Invoke-WhinsetExternalCommand {
        param($FilePath,$ArgumentList,$TimeoutSeconds,$WorkingDirectory)
        $argumentsText = $ArgumentList -join ' '
        throw "Unexpected external command in unit test: $FilePath $argumentsText"
    }
    function Invoke-WhinsetPackageOperation {
        param($Plan,$State,$Operation,$Paths)
        $script:adminInstallCalls++
        return (New-WhinsetOperationResult -Status 'Succeeded' -Detail 'Mock package install succeeded.' -ExitCode 0)
    }
    function Invoke-WhinsetElevation {
        param($Plan,$Paths)
        $script:elevationCalls++
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'elevation.start' -Data @{ Mock=$true }
        if ($script:elevationMode -eq 'deny') { return [pscustomobject][ordered]@{ Granted=$false; Denied=$true; ExitCode=$null; Error='UAC denied by user.'; Result=$null } }
        $state = Read-WhinsetRunState -Path $Paths.StatePath
        foreach ($operation in @($Plan.Operations | Where-Object { $_.Privilege -eq 'elevated' })) {
            $record = Get-WhinsetOperationRecord -State $state -OperationId $operation.Id
            if ($record.Status -notin @('Succeeded','AlreadyInstalled','Skipped','Warning')) {
                Set-WhinsetOperationRecord -State $state -OperationId $operation.Id -Status 'Succeeded' -Detail 'Mock elevated operation succeeded.' -ExitCode 0
            }
        }
        Save-WhinsetRunState -State $state -Paths $Paths
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'elevation.end' -Data @{ Mock=$true }
        return [pscustomobject][ordered]@{ Granted=$true; Denied=$false; ExitCode=0; Error=''; Result=[pscustomobject]@{ ExitCode=0 } }
    }

    Test 'Apply requests one UAC for multiple elevated operations' {
        $script:probeInstalled = $false; $script:elevationCalls = 0; $script:elevationMode = 'grant'
        $environment = New-TestEnvironment -IsAdministrator $false
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $stateRoot = Join-Path $testRoot 'single-uac'
        $result = Invoke-WhinsetApplyPlan -Plan $plan -StateRoot $stateRoot -AcceptAgreements
        Assert ($result.ExitCode -eq 0) "Exit=$($result.ExitCode)"
        Assert ($script:elevationCalls -eq 1) "Elevation calls=$($script:elevationCalls)"
        Assert ($result.State.Status -eq 'Complete')
    }
    Test 'UAC denial stops cleanly with exit code 4' {
        $script:probeInstalled = $false; $script:elevationCalls = 0; $script:elevationMode = 'deny'
        $environment = New-TestEnvironment -IsAdministrator $false
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $stateRoot = Join-Path $testRoot 'uac-denied'
        $result = Invoke-WhinsetApplyPlan -Plan $plan -StateRoot $stateRoot -AcceptAgreements
        Assert ($result.ExitCode -eq 4)
        Assert ($result.State.Status -eq 'ElevationDenied')
        Assert ($result.State.ExitCode -eq 4)
        Assert (@($result.State.Operations | Where-Object { $_.Status -eq 'Running' }).Count -eq 0)
    }
    Test 'Already-elevated execution never invokes a second elevation' {
        $script:probeInstalled = $false; $script:elevationCalls = 0; $script:adminInstallCalls = 0; $script:elevationMode = 'grant'
        $environment = New-TestEnvironment -IsAdministrator $true
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $stateRoot = Join-Path $testRoot 'already-elevated'
        $result = Invoke-WhinsetApplyPlan -Plan $plan -StateRoot $stateRoot -AcceptAgreements
        Assert ($result.ExitCode -eq 0)
        Assert ($script:elevationCalls -eq 0)
        Assert ($script:adminInstallCalls -gt 0)
    }
    Test 'Already-installed packages converge without UAC' {
        $script:probeInstalled = $true; $script:elevationCalls = 0; $script:elevationMode = 'grant'
        $environment = New-TestEnvironment -IsAdministrator $false
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $stateRoot = Join-Path $testRoot 'already-installed'
        $result = Invoke-WhinsetApplyPlan -Plan $plan -StateRoot $stateRoot -AcceptAgreements
        Assert ($result.ExitCode -eq 0)
        Assert ($script:elevationCalls -eq 0)
        Assert (@($result.State.Operations | Where-Object { $_.Status -eq 'AlreadyInstalled' }).Count -eq 5)
        Write-WhinsetApplyHuman -Result $result | Out-Null
    }
    Test 'Elevated worker reconstructs and executes only the trusted plan' {
        $script:adminInstallCalls = 0
        $environment = New-TestEnvironment -IsAdministrator $false
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $stateRoot = Join-Path $testRoot 'worker'
        $context = Get-WhinsetRunContext -Plan $plan -Environment $environment -StateRoot $stateRoot
        $nonce = [guid]::NewGuid().ToString('N')
        $request = [ordered]@{ SchemaVersion=1; RunId=$plan.RunId; PlanHash=$plan.PlanHash; PlanPath=$context.Paths.PlanPath; Nonce=$nonce; OriginalUserSid=$environment.UserSid; CreatedAt=Get-WhinsetTimestamp }
        Write-WhinsetJsonFileAtomically -Path $context.Paths.ElevationRequestPath -Value $request
        $result = Invoke-WhinsetElevatedWorker -PlanPath $context.Paths.PlanPath -PlanHash $plan.PlanHash -Nonce $nonce
        Assert ($result.ExitCode -eq 0)
        Assert ($script:adminInstallCalls -eq $plan.Operations.Count)
        $state = Read-WhinsetRunState -Path $context.Paths.StatePath
        Assert (@($state.Operations | Where-Object { $_.Status -eq 'Succeeded' }).Count -eq $plan.Operations.Count)
        Assert ($state.ElevatedUserSid -eq $environment.UserSid)
        Assert-Throws { Invoke-WhinsetElevatedWorker -PlanPath $context.Paths.PlanPath -PlanHash $plan.PlanHash -Nonce 'wrong-nonce' } '*nonce*'
    }
    Test 'Structured JSONL logging records operation lifecycle' {
        $stateRoot = Join-Path $testRoot 'single-uac'
        $run = @(Get-WhinsetRunInventory -StateRoot $stateRoot)[0]
        $eventsPath = Join-Path $run.RunDirectory 'operations.jsonl'
        Assert (Test-Path -LiteralPath $eventsPath)
        $lines = @(Get-Content -LiteralPath $eventsPath)
        Assert ($lines.Count -gt 0)
        foreach ($line in $lines) { $event = $line | ConvertFrom-Json; Assert ($event.Timestamp -and $event.Type) }
        $types = @($lines | ForEach-Object { ($_ | ConvertFrom-Json).Type })
        Assert ($types -contains 'run.start')
        Assert ($types -contains 'elevation.start')
        Assert ($types -contains 'run.end')
    }
    Test 'Interrupted operations are normalized to pending on the same boot' {
        $environment = New-TestEnvironment
        $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
        $stateRoot = Join-Path $testRoot 'interrupted'
        $context = Get-WhinsetRunContext -Plan $plan -Environment $environment -StateRoot $stateRoot
        $record = Get-WhinsetOperationRecord -State $context.State -OperationId $plan.Order[0]
        $record.Status = 'Running'; $record.StartedAt = Get-WhinsetTimestamp
        Save-WhinsetRunState -State $context.State -Paths $context.Paths
        $resumed = Get-WhinsetRunContext -Plan $plan -Environment $environment -StateRoot $stateRoot
        Assert ($resumed.State.Operations[0].Status -eq 'Pending')
        Assert (-not $resumed.RebootGate)
    }
    Test 'Reboot gate blocks the same boot and resumes after a new boot' {
        $oldBoot = $env:WHINSET_BOOT_ID
        try {
            $env:WHINSET_BOOT_ID = 'boot-1'
            $environment = New-TestEnvironment
            $environment.BootId = 'boot-1'
            $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
            $stateRoot = Join-Path $testRoot 'reboot-gate'
            $context = Get-WhinsetRunContext -Plan $plan -Environment $environment -StateRoot $stateRoot
            $context.State.Status = 'AwaitingReboot'; $context.State.BootId = 'boot-1'; $context.State.RebootRequired = $true
            Set-WhinsetOperationRecord -State $context.State -OperationId $plan.Order[0] -Status 'AwaitingReboot' -RebootRequired
            Save-WhinsetRunState -State $context.State -Paths $context.Paths
            $same = Get-WhinsetRunContext -Plan $plan -Environment $environment -StateRoot $stateRoot
            Assert $same.RebootGate
            $env:WHINSET_BOOT_ID = 'boot-2'
            $next = Get-WhinsetRunContext -Plan $plan -Environment $environment -StateRoot $stateRoot
            Assert (-not $next.RebootGate)
            Assert ($next.State.Operations[0].Status -eq 'Pending')
        } finally {
            if ($null -eq $oldBoot) { Remove-Item Env:WHINSET_BOOT_ID -ErrorAction SilentlyContinue } else { $env:WHINSET_BOOT_ID = $oldBoot }
        }
    }
    Test 'Legacy SetupNewPC state is discovered read-only' {
        $legacyRoot = Join-Path $testRoot 'legacy-state'
        $legacyRun = Join-Path $legacyRoot 'abc123'
        New-Item -ItemType Directory -Path $legacyRun -Force | Out-Null
        [ordered]@{ Version=4; ConfigurationHash='abc123'; Status='AwaitingReboot'; Profile='Developer'; Stage='Auto'; BootId='boot'; UpdatedAt='2026-11-06T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyRun 'state.json') -Encoding UTF8
        $inventory = @(Get-WhinsetLegacyRunInventory -LegacyRoot $legacyRoot)
        Assert ($inventory.Count -eq 1)
        Assert ($inventory[0].Status -eq 'AwaitingReboot')
        Assert ($inventory[0].Compatibility -like 'read-only*')
    }
    Test 'Bootstrap manifest is pinned, human-readable and rejects dynamic execution' {
        $bootstrapPath = Join-Path $root 'beatwin.txt'
        if (-not (Test-Path -LiteralPath $bootstrapPath)) { Write-Output 'SKIP bootstrap file is a release asset outside the archive'; return }
        $bootstrapPath = Join-Path $root 'beatwin.txt'
        $manifest = Get-WhinsetBootstrapManifest -Path $bootstrapPath
        Assert ($manifest.Version -eq 'v2.0.0-rc.1')
        Assert ($manifest.Sha256 -match '^[0-9a-f]{64}$')
        Assert ($manifest.AssetUrl -like '*releases/download/v2.0.0-rc.1/*')
        Assert ($manifest.Text -notmatch '(?i)Invoke[-]Expression|[-]EncodedCommand|FromBase64String|/main/')
        Assert ($manifest.Text -like '*UAC*')
        Assert ($manifest.Text -like '*No automatic rollback*')
    }
    Test 'Bootstrap checksum mismatch is reported' {
        $bootstrapPath = Join-Path $root 'beatwin.txt'
        if (-not (Test-Path -LiteralPath $bootstrapPath)) { Write-Output 'SKIP bootstrap file is a release asset outside the archive'; return }
        $manifest = Get-WhinsetBootstrapManifest -Path (Join-Path $root 'beatwin.txt')
        $fake = Join-Path $testRoot 'fake-archive.zip'
        'not the pinned archive' | Set-Content -LiteralPath $fake -Encoding UTF8
        $result = Test-WhinsetBootstrapArtifact -Manifest $manifest -ArchivePath $fake
        Assert (-not $result.Ok)
        Assert ($result.Error -like '*mismatch*')
        $generated = Join-Path $testRoot 'generated-beatwin.txt'
        $fakeHash = (Get-FileHash -LiteralPath $fake -Algorithm SHA256).Hash.ToLowerInvariant()
        $bootstrapArgs = @{
            TemplatePath = Join-Path $root 'bootstrap/beatwin.template.txt'
            Version = 'v2.0.0-rc.1'
            Sha256 = $fakeHash
            OutputPath = $generated
        }
        $null = New-WhinsetBootstrapFile @bootstrapArgs
        $matching = Test-WhinsetBootstrapIntegrity -Path $generated -ArchivePath $fake
        Assert ($matching.Ok)
    }
    Test 'Command completion exposes commands, profiles and package keys' {
        $hostExe = (Get-Process -Id $PID).Path
        $module = Join-Path $root 'src/Whinset.psd1'
        $command = "Import-Module '$module' -Force; `$s='whinset '; `$a=@(TabExpansion2 `$s `$s.Length).CompletionMatches.CompletionText; `$s='whinset plan -Profile M'; `$b=@(TabExpansion2 `$s `$s.Length).CompletionMatches.CompletionText; `$s='whinset plan -Package G'; `$c=@(TabExpansion2 `$s `$s.Length).CompletionMatches.CompletionText; @{Commands=`$a;Profiles=`$b;Packages=`$c} | ConvertTo-Json -Depth 4"
        $json = & $hostExe -NoLogo -NoProfile -Command $command
        Assert ($LASTEXITCODE -eq 0) "Completion child exited $LASTEXITCODE"
        $completion = $json | ConvertFrom-Json
        Assert ($completion.Commands -contains 'plan')
        Assert ($completion.Commands -contains 'doctor')
        Assert ($completion.Profiles -contains 'Minimal')
        Assert ($completion.Packages -contains 'Git')
    }
    Test 'Concurrent apply is blocked before state mutation' {
        $oldMutex = $env:WHINSET_MUTEX_NAME
        $name = 'Local\Whinset-test-' + [guid]::NewGuid().ToString('N')
        $ready = Join-Path $testRoot 'mutex-ready.txt'
        $holder = Join-Path $root 'tests/Hold-WhinsetMutex.ps1'
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$holder`" -Name `"$name`" -ReadyPath `"$ready`""
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $ready) -and $watch.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            Assert (Test-Path -LiteralPath $ready) 'Mutex holder did not become ready.'
            $env:WHINSET_MUTEX_NAME = $name
            $environment = New-TestEnvironment
            $plan = New-WhinsetPlan -CatalogPath $catalogPath -Profile Minimal -Offline -Environment $environment
            $stateRoot = Join-Path $testRoot 'concurrent-must-not-create'
            Assert-Throws { Invoke-WhinsetApplyPlan -Plan $plan -StateRoot $stateRoot -AcceptAgreements } '*already running*'
            Assert (-not (Test-Path -LiteralPath $stateRoot))
        } finally {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
            $process.Dispose()
            if ($null -eq $oldMutex) { Remove-Item Env:WHINSET_MUTEX_NAME -ErrorAction SilentlyContinue } else { $env:WHINSET_MUTEX_NAME = $oldMutex }
        }
    }

    Test 'install-cli copies a runnable per-user command without changing PATH in test mode' {
        $oldInstall = $env:WHINSET_INSTALL_ROOT
        $oldSkip = $env:WHINSET_SKIP_PATH_UPDATE
        try {
            $env:WHINSET_INSTALL_ROOT = Join-Path $testRoot 'cli-install'
            $env:WHINSET_SKIP_PATH_UPDATE = '1'
            $installed = Install-WhinsetCli
            Assert (Test-Path -LiteralPath (Join-Path $installed.InstallRoot 'whinset.ps1'))
            Assert (Test-Path -LiteralPath (Join-Path $installed.InstallRoot 'src/Whinset.psd1'))
            Assert (-not $installed.PathAdded)
            $hostExe = (Get-Process -Id $PID).Path
            $json = & $hostExe -NoLogo -NoProfile -File (Join-Path $installed.InstallRoot 'whinset.ps1') version -Json
            Assert ($LASTEXITCODE -eq 0)
            Assert (($json | ConvertFrom-Json).Version -eq '2.0.0-rc.1')
            $oldPath = $env:PATH
            try {
                $env:PATH = $installed.InstallRoot + ';' + $env:PATH
                $commandJson = & $hostExe -NoLogo -NoProfile -Command '& whinset version -Json'
                Assert ($LASTEXITCODE -eq 0)
                Assert (($commandJson | ConvertFrom-Json).Version -eq '2.0.0-rc.1')
                $s = 'whinset '
                $scriptCommands = @(TabExpansion2 $s $s.Length).CompletionMatches.CompletionText
                Assert ($scriptCommands -contains 'plan')
                $s = 'whinset plan -Profile M'
                $scriptProfiles = @(TabExpansion2 $s $s.Length).CompletionMatches.CompletionText
                Assert ($scriptProfiles -contains 'Minimal')
                $s = 'whinset plan -Package G'
                $scriptPackages = @(TabExpansion2 $s $s.Length).CompletionMatches.CompletionText
                Assert ($scriptPackages -contains 'Git')
            } finally { $env:PATH = $oldPath }
        } finally {
            if ($null -eq $oldInstall) { Remove-Item Env:WHINSET_INSTALL_ROOT -ErrorAction SilentlyContinue } else { $env:WHINSET_INSTALL_ROOT = $oldInstall }
            if ($null -eq $oldSkip) { Remove-Item Env:WHINSET_SKIP_PATH_UPDATE -ErrorAction SilentlyContinue } else { $env:WHINSET_SKIP_PATH_UPDATE = $oldSkip }
        }
    }
    Test 'CLI invalid input emits structured JSON and exit code 2' {
        $output = & (Join-Path $root 'whinset.ps1') plan -Profile Typo -Offline -Json 2>&1
        $code = $LASTEXITCODE
        Assert ($code -eq 2) "Exit=$code"
        $parsed = ($output | Out-String) | ConvertFrom-Json
        Assert ($parsed.Ok -eq $false)
        Assert ($parsed.ExitCode -eq 2)
    }
    Test 'Apply without AcceptAgreements returns input failure before state creation' {
        $stateRoot = Join-Path $testRoot 'agreement-required'
        $output = & (Join-Path $root 'whinset.ps1') apply -Profile Minimal -Offline -StateDirectory $stateRoot -Json 2>&1
        $code = $LASTEXITCODE
        Assert ($code -eq 2)
        Assert (-not (Test-Path -LiteralPath $stateRoot))
    }
} finally {
    if ($null -eq $script:oldWhinsetMutexName) { Remove-Item Env:WHINSET_MUTEX_NAME -ErrorAction SilentlyContinue } else { $env:WHINSET_MUTEX_NAME = $script:oldWhinsetMutexName }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'Whinset-tests-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Output "$script:passed passed; $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
