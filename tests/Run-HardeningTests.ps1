#requires -Version 5.1
param([string]$EvidencePath = '')
# Deterministic security/recovery tests. UAC and operation execution are simulated.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$script:WhinsetRoot = $root
. (Join-Path $root 'src/Configuration.ps1')
. (Join-Path $root 'src/SetupNewPC.Core.ps1')
Get-ChildItem (Join-Path $root 'src/Whinset') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Whinset-hardening-' + [guid]::NewGuid().ToString('N'))
$results = New-Object Collections.Generic.List[object]
function Assert($Value, [string]$Message = 'Assertion failed') { if (-not $Value) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern = '*') {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $true; Assert ($_.Exception.Message -like $Pattern) "Unexpected error: $_" }
    Assert $caught 'Expected rejection'
}
function Test([string]$Name, [scriptblock]$Action) {
    try { & $Action; $results.Add([pscustomobject]@{ Name=$Name; Status='PASS'; Detail='' }); Write-Output "PASS $Name" }
    catch { $results.Add([pscustomobject]@{ Name=$Name; Status='FAIL'; Detail=[string]$_ }); Write-Output "FAIL $Name : $_ $($_.ScriptStackTrace)" }
}
$sid = [string](Get-WhinsetMachineIdentity).UserSid
$environment = [pscustomobject]@{
    Caption='Windows 11 deterministic fixture'; OsVersion='10.0.26100'; BuildNumber=26100; ProductType=1; IsWindows11=$true
    PowerShellVersion='5.1'; PowerShellEdition='Desktop'; Is64BitProcess=$true; Architecture='x64'
    IsAdministrator=$false; ComputerName=$env:COMPUTERNAME; UserSid=$sid
    UserProfile=$env:USERPROFILE; LocalAppData=$env:LOCALAPPDATA; Temp=$testRoot
    WingetAvailable=$true; WingetVersion='1.9.0'; WingetVersionOk=$true; PendingReboot=@(); Blockers=@(); Warnings=@(); BootId='boot-1'
}
$plan = New-WhinsetPlan -CatalogPath (Join-Path $root 'config/packages.json') -Profile Minimal -Offline -Environment $environment
function Fixture {
    $context = Get-WhinsetRunContext -Plan $plan -Environment $environment -StateRoot (Join-Path $testRoot ([guid]::NewGuid().ToString('N')))
    $request = [pscustomobject]@{ SchemaVersion=1; RunId=$plan.RunId; PlanHash=$plan.PlanHash; PlanPath=$context.Paths.PlanPath; Nonce=[guid]::NewGuid().ToString('N'); OriginalUserSid=$sid; CreatedAt=Get-WhinsetTimestamp }
    Write-WhinsetJsonFileAtomically $context.Paths.ElevationRequestPath $request
    return [pscustomobject]@{ Context=$context; Request=$request }
}
# Only this token probe and the actual operation executor are simulated for worker tests.
function Test-WhinsetIsAdministrator { return $true }
$script:executed = 0
function Invoke-WhinsetOperationInternal { param($Plan,$State,$Operation,$Paths)
    $script:executed++; New-WhinsetOperationResult -Status Succeeded -ExitCode 0 }
try {
    Test 'SID policy accepts identical SIDs and rejects different-user credentials' {
        Assert-WhinsetSameUser 'S-1-5-21-1' 'S-1-5-21-1'
        Reject { Assert-WhinsetSameUser 'S-1-5-21-1' 'S-1-5-21-2' } '*Different-user*'
    }
    Test 'Native cancellation uses ERROR_CANCELLED 1223 independent of language' {
        Assert ((Get-WhinsetNativeErrorCode (New-Object ComponentModel.Win32Exception(1223,'Zugriff'))) -eq 1223)
        Assert ((Get-WhinsetNativeErrorCode (New-Object Exception('cancelled'))) -eq $null)
        Assert ((Get-WhinsetNativeErrorCode (New-Object Exception('wrapped',(New-Object ComponentModel.Win32Exception(5))))) -eq 5)
    }
    Test 'Private state directory and inherited file ACLs reject foreign writers' {
        $f = Fixture
        Assert-WhinsetPrivatePath $f.Context.Paths.StatePath $sid
        $acl = Get-Acl $f.Context.Paths.StatePath
        $foreign = New-Object Security.Principal.SecurityIdentifier('S-1-1-0')
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($foreign,'Write','Allow')))
        Set-Acl $f.Context.Paths.StatePath $acl
        Reject { Assert-WhinsetPrivatePath $f.Context.Paths.StatePath $sid } '*write access*'
    }
    Test 'Worker grant simulation executes once and rejects replay' {
        $f = Fixture; $script:executed = 0
        $r = Invoke-WhinsetElevatedWorker $f.Context.Paths.PlanPath $plan.PlanHash $f.Request.Nonce
        Assert ($r.ExitCode -eq 0 -and $r.Nonce -eq $f.Request.Nonce)
        Assert ($script:executed -eq $plan.Operations.Count)
        Reject { Invoke-WhinsetElevatedWorker $f.Context.Paths.PlanPath $plan.PlanHash $f.Request.Nonce } '*already exists*'
        Assert ($script:executed -eq $plan.Operations.Count)
    }
    Test 'Worker rejects wrong nonce without result writes' {
        $f = Fixture
        Reject { Invoke-WhinsetElevatedWorker $f.Context.Paths.PlanPath $plan.PlanHash ('a' * 32) } '*nonce*'
        Assert (-not (Test-Path $f.Context.Paths.ElevatedResultPath))
    }
    Test 'Worker rejects stale and future requests' {
        foreach ($minutes in @(-11,2)) {
            $f = Fixture; $f.Request.CreatedAt = [DateTimeOffset]::UtcNow.AddMinutes($minutes).ToString('o')
            Write-WhinsetJsonFileAtomically $f.Context.Paths.ElevationRequestPath $f.Request
            Reject { Invoke-WhinsetElevatedWorker $f.Context.Paths.PlanPath $plan.PlanHash $f.Request.Nonce } '*stale*'
        }
    }
    Test 'Worker rejects alternate-user request and mismatched state' {
        $f = Fixture; $f.Request.OriginalUserSid = 'S-1-5-21-OTHER'
        Write-WhinsetJsonFileAtomically $f.Context.Paths.ElevationRequestPath $f.Request
        Reject { Invoke-WhinsetElevatedWorker $f.Context.Paths.PlanPath $plan.PlanHash $f.Request.Nonce } '*identity*'
        $f = Fixture; $f.Context.State.Operations[0].Privilege = 'user'
        Save-WhinsetRunState $f.Context.State $f.Context.Paths
        Reject { Invoke-WhinsetElevatedWorker $f.Context.Paths.PlanPath $plan.PlanHash $f.Request.Nonce } '*metadata*'
    }
    Test 'Trusted reconstruction rejects modified executable plan and catalog hash' {
        $f = Fixture; $stored = Read-WhinsetJsonFile $f.Context.Paths.PlanPath
        $stored.Operations[0].Scope = 'user'
        Write-WhinsetJsonFileAtomically $f.Context.Paths.PlanPath $stored
        Reject { Get-WhinsetTrustedPlan $f.Context.Paths.PlanPath $plan.PlanHash } '*graph differs*'
        $stored.Identity.Catalog.Sha256 = '0' * 64
        Write-WhinsetJsonFileAtomically $f.Context.Paths.PlanPath $stored
        Reject { Get-WhinsetTrustedPlan $f.Context.Paths.PlanPath $plan.PlanHash } '*catalog hash*'
    }
    Test 'WSL and Docker graphs isolate machine and original-user operations' {
        $p = New-WhinsetPlan -CatalogPath (Join-Path $root 'config/packages.json') -Profile Minimal -EnableDocker -Offline -Environment $environment
        foreach ($id in @('system:wsl-features','system:wsl-runtime','system:docker')) { Assert ((@($p.Operations | Where-Object Id -eq $id)[0]).Privilege -eq 'elevated') }
        foreach ($id in @('user:wsl-distribution','user:docker-verify')) { Assert ((@($p.Operations | Where-Object Id -eq $id)[0]).Privilege -eq 'user') }
        Assert ((@($p.Operations | Where-Object Id -eq 'system:docker')[0]).Scope -eq 'machine')
    }
    Test 'Interrupted state replacement preserves old valid JSON and backup' {
        $f = Fixture; $path = $f.Context.Paths.StatePath
        [IO.File]::WriteAllText(($path + '.tmp-interrupted'),'{')
        Assert ((Read-WhinsetRunState $path).PlanHash -eq $plan.PlanHash)
        $f.Context.State.Detail = 'new committed value'
        Save-WhinsetRunState $f.Context.State $f.Context.Paths
        Assert ((Read-WhinsetRunState $path).Detail -eq 'new committed value')
        Assert ((Read-WhinsetRunState ($path + '.bak')).PlanHash -eq $plan.PlanHash)
    }
    Test 'Partial elevated phase resumes pending work and preserves successes' {
        $f = Fixture
        $f.Context.State.Operations[0].Status = 'Succeeded'
        $f.Context.State.Operations[1].Status = 'Running'
        Save-WhinsetRunState $f.Context.State $f.Context.Paths
        $c = Get-WhinsetRunContext $plan $environment $f.Context.Paths.StateRoot
        Assert ($c.State.Operations[0].Status -eq 'Succeeded')
        Assert ($c.State.Operations[1].Status -eq 'Pending')
        $c.State.Operations = @($c.State.Operations | Select-Object -Skip 1)
        Save-WhinsetRunState $c.State $c.Paths
        Reject { Get-WhinsetRunContext $plan $environment $c.Paths.StateRoot } '*operations do not match*'
    }
    Test 'Interrupted installer is rechecked before another install attempt' {
        $f = Fixture; $script:probes = 0; $script:installs = 0
        function Test-WhinsetPackageInstalled {
            param($Package,[switch]$AcceptAgreements)
            $script:probes++
            [pscustomobject]@{ Installed=($script:probes -gt 1); VersionVerified=$true; Error=''; ExitCode=0 }
        }
        function Invoke-WhinsetExternalCommand { param($FilePath,$ArgumentList,$TimeoutSeconds)
            $script:installs++; throw 'Installer transport interrupted after launch' }
        $operation = $plan.Operations[0]
        $r = Invoke-WhinsetPackageOperation $plan $f.Context.State $operation $f.Context.Paths
        Assert ($r.Status -eq 'AlreadyInstalled' -and $script:installs -eq 1)
    }
    Test 'Repeated apply package recheck detects removed package after success' {
        $f = Fixture
        foreach ($op in $f.Context.State.Operations) { $op.Status = 'Succeeded' }
        function Test-WhinsetPackageInstalled { param($Package,[switch]$AcceptAgreements)
            [pscustomobject]@{ Installed=$false; VersionVerified=$false; Error=''; ExitCode=0 } }
        Invoke-WhinsetPackagePreflightRecheck $plan $f.Context.State $f.Context.Paths
        Assert (@($f.Context.State.Operations | Where-Object Status -eq Pending).Count -eq $plan.Operations.Count)
    }
    # Launch transport simulation exercises the real parent elevation function, never RunAs.
    $script:launchMode = 'grant'
    function Start-Process {
        param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$Wait,[switch]$PassThru,$ErrorAction)
        if ($script:launchMode -eq 'deny') { throw (New-Object ComponentModel.Win32Exception(1223,'Localized text')) }
        if ($script:launchMode -eq 'launch-failure') { throw (New-Object ComponentModel.Win32Exception(2)) }
        if ($script:launchMode -in @('crash','missing')) { return [pscustomobject]@{ ExitCode=$(if ($script:launchMode -eq 'crash') { 42 } else { 0 }) } }
        $req = Read-WhinsetJsonFile $script:launchPaths.ElevationRequestPath
        $nonce = $req.Nonce
        if ($script:launchMode -eq 'wrong-nonce') { $nonce = '0' * 32 }
        $r = [pscustomobject]@{ SchemaVersion=1; RunId=$plan.RunId; PlanHash=$plan.PlanHash; Nonce=$nonce; ExitCode=0; Error='' }
        Write-WhinsetJsonFileAtomically $script:launchPaths.ElevatedResultPath $r
        return [pscustomobject]@{ ExitCode=0 }
    }
    foreach ($mode in @('grant','deny','launch-failure','crash','missing','wrong-nonce')) {
        Test "Elevation transport simulation: $mode" {
            $f = Fixture; $script:launchPaths = $f.Context.Paths; $script:launchMode = $mode
            $r = Invoke-WhinsetElevation $plan $script:launchPaths
            if ($mode -eq 'grant') { Assert ($r.Granted -and $r.Result -and $r.ExitCode -eq 0) }
            elseif ($mode -eq 'deny') { Assert ($r.Denied -and -not $r.Granted) }
            elseif ($mode -eq 'launch-failure') { Assert (-not $r.Denied -and -not $r.Granted) }
            else { Assert ($r.Granted -and -not $r.Result -and $r.Error); if ($mode -eq 'crash') { Assert ($r.ExitCode -eq 42) } }
        }
    }
} finally {
    if ($EvidencePath) { Write-WhinsetJsonFileAtomically $EvidencePath ([ordered]@{ SchemaVersion=1; Suite='deterministic hardening; simulated UAC and operations'; PowerShellVersion=$PSVersionTable.PSVersion.ToString(); Results=@($results.ToArray()) }) }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'Whinset-hardening-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
$failed = @($results | Where-Object Status -eq 'FAIL').Count
Write-Output "$($results.Count - $failed) passed; $failed failed"
if ($failed) { exit 1 }
exit 0
