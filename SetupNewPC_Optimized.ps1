#requires -Version 5.1
<#
.SYNOPSIS
    Configurable Windows 11 provisioning. Start with -WhatIf.
.DESCRIPTION
    Install missing packages, optionally configure WSL/Docker and environments.
    Rerun the SAME command after interruption or reboot. No automatic restart or
    scheduled task is created. Exit codes: 0 complete, 1 failed, 2 invalid input /
    prerequisites, 3 incomplete (user skipped), 3010 restart required.
.EXAMPLE
    .\SetupNewPC_Optimized.ps1 -Profile Developer -WhatIf
.EXAMPLE
    .\SetupNewPC_Optimized.ps1 -Profile Developer -EnableDocker -AcceptAgreements
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto','WindowsBase','Development')][string]$Stage = 'Auto',
    [ValidateSet('Minimal','Developer','AI','Engineering','Full')][string]$Profile = 'Developer',
    [ValidateSet('Core','Developer','AI','Engineering','Personal')][string[]]$ExtraGroups = @(),
    [switch]$IncludePersonal,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\packages.json'),
    [string[]]$Exclude = @(),
    [string]$StateDirectory = '',
    [Alias('Plan')][switch]$WhatIf,
    [switch]$AcceptAgreements,
    [switch]$ConfirmEach,
    [switch]$ApplicationsOnly,
    [switch]$ConfigureEnvironment,
    [switch]$EnableWSL,
    [switch]$EnableDocker,
    [switch]$SkipWSL,
    [switch]$SkipDocker,
    [switch]$SkipStoreApps,
    [switch]$SkipCondaInit,
    [switch]$DockerSmokeTest,
    [switch]$EnableWinUtil,
    [switch]$SkipWinUtil,
    [string]$WinUtilPath = '',
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$WinUtilSha256,
    [ValidateRange(1,5)][int]$MaxAttempts = 2,
    [ValidateRange(30,14400)][int]$InstallTimeoutSeconds = 3600,
    # Legacy switches: accepted for compatibility; no reboot, task or pause.
    [switch]$NoResume,
    [switch]$NoPause,
    [switch]$AllowReboot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'src\Configuration.ps1')
. (Join-Path $PSScriptRoot 'src\SetupNewPC.Core.ps1')
$exitCode = 2
$transcriptStarted = $false
$lockHeld = $false
$mutex = $null
$stateReady = $false
try {
    if ($AllowReboot) { throw '-AllowReboot has been retired. Restart manually after saving your work.' }
    if ($EnableWSL -and $SkipWSL) { throw 'EnableWSL and SkipWSL conflict.' }
    if ($EnableDocker -and ($SkipDocker -or $SkipWSL)) { throw 'EnableDocker conflicts with SkipDocker/SkipWSL.' }
    if ($EnableWinUtil -and $SkipWinUtil) { throw 'EnableWinUtil and SkipWinUtil conflict.' }
    if ($ApplicationsOnly -and ($EnableWSL -or $EnableDocker -or $EnableWinUtil -or $ConfigureEnvironment -or $DockerSmokeTest)) { throw 'ApplicationsOnly cannot enable system or environment configuration.' }
    $SkipWSL = -not ($EnableWSL -or $EnableDocker) -or $SkipWSL -or $ApplicationsOnly
    $SkipDocker = -not $EnableDocker -or $SkipDocker -or $SkipWSL -or $ApplicationsOnly
    $SkipWinUtil = -not $EnableWinUtil -or $SkipWinUtil -or $ApplicationsOnly
    if ($DockerSmokeTest -and $SkipDocker) { throw 'DockerSmokeTest requires EnableDocker.' }
    if (-not $SkipWinUtil) {
        if (-not $WinUtilPath -or -not $WinUtilSha256) { throw 'WinUtil requires a reviewed local -WinUtilPath and -WinUtilSha256.' }
        $WinUtilPath = (Resolve-Path -LiteralPath $WinUtilPath).Path
        if ((Get-FileHash -LiteralPath $WinUtilPath -Algorithm SHA256).Hash -ne $WinUtilSha256) { throw 'WinUtil SHA256 mismatch.' }
    }
    $script:Catalog = @(Read-PackageCatalog -Path $ConfigPath)
    foreach ($id in $Exclude) {
        if ($id -notin $script:Catalog.Id -and $id -notin $script:Catalog.Key) { throw "Unknown Exclude package: $id" }
    }
    $script:SelectedPackages = @(Get-SoftwareCatalog | Where-Object {
        (Test-ItemInSelectedGroups -Item $_) -and $_.Id -notin $Exclude -and $_.Key -notin $Exclude -and
        (-not $SkipStoreApps -or $_.Source -ne 'msstore')
    })
    $plan = [ordered]@{
        SchemaVersion = 4; Profile = $Profile; Groups = @(Get-SelectedGroups)
        Packages = $script:SelectedPackages; WSL = (-not $SkipWSL); Docker = (-not $SkipDocker)
        WinUtil = (-not $SkipWinUtil); WinUtilSha256 = $WinUtilSha256
        ConfigureEnvironment = [bool]$ConfigureEnvironment; SkipCondaInit = [bool]$SkipCondaInit
        ApplicationsOnly = [bool]$ApplicationsOnly; DockerSmokeTest = [bool]$DockerSmokeTest
    }
    $script:ConfigurationHash = Get-ConfigurationHash -Value $plan
    if ($WhatIf) {
        # Deliberately before privilege checks, WinGet, directory creation and logging.
        [pscustomobject]@{ Profile=$Profile; Stage=$Stage; ConfigurationHash=$script:ConfigurationHash;
            WSL=$plan.WSL; Docker=$plan.Docker; WinUtil=$plan.WinUtil;
            ConfigureEnvironment=$plan.ConfigureEnvironment; AcceptAgreements=[bool]$AcceptAgreements;
            Packages=@($script:SelectedPackages | Where-Object { $Stage -eq 'Auto' -or $_.Stage -eq $Stage }) }
        exit 0
    }
    if (-not $AcceptAgreements) { throw 'Review the plan and software/source licenses, then pass -AcceptAgreements to execute.' }
    Assert-SetupPrerequisites
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:MachineIdentity = "$env:COMPUTERNAME/$identity"
    if (-not $StateDirectory) { $StateDirectory = Join-Path $env:LOCALAPPDATA 'SetupNewPC\v2' }
    $script:StateDir = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) $script:ConfigurationHash
    $script:StateFile = Join-Path $script:StateDir 'state.json'
    $script:LogFile = Join-Path $script:StateDir 'setup.log'
    $script:VirtualizationReportFile = Join-Path $script:StateDir 'virtualization-report.json'
    $script:DockerReadinessFile = Join-Path $script:StateDir 'docker-readiness.json'
    $script:PythonPolicyFile = Join-Path $script:StateDir 'python-strategy.txt'
    $script:EnvironmentReportFile = Join-Path $script:StateDir 'environment-report.json'
    $script:EnvironmentReportTextFile = Join-Path $script:StateDir 'environment-report.txt'
    $script:Failures = @(); $script:ItemResults = [ordered]@{}; $script:EnvironmentResults = @()
    $script:CurrentStatus = 'Running'; $script:CurrentDetail = ''; $script:LastCompletedStage = 'None'
    $script:StateVersion = 4; $script:InstallerRebootRequired = $false
    $script:UserSkipped = $false; $script:StopInstallations = $false
    $mutex = New-Object Threading.Mutex($false, 'Global\SetupNewPC-v2')
    try { $lockHeld = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'Another SetupNewPC process is running. Wait for it to finish.' }
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    Initialize-RunState
    $stateReady = $true
    Start-Transcript -Path $script:LogFile -Append -Force | Out-Null
    $transcriptStarted = $true
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $script:StateDir 'plan.json') -Encoding UTF8
    $exitCode = 1
    $finalStatus = Invoke-SetupPipeline
    if (@($script:ItemResults.Values | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $exitCode = 1 }
    elseif ($finalStatus -eq 'AwaitingReboot') { $exitCode = 3010 }
    elseif ($script:UserSkipped) { $exitCode = 3 }
    else { $exitCode = 0 }
    Write-Host "Status: $finalStatus; exit code: $exitCode"
    $script:ItemResults.Values | Format-Table Name,Status,Attempts -AutoSize | Out-Host
    Write-Host "State and logs: $script:StateDir"
} catch {
    Write-Warning $_.Exception.Message
    if ($stateReady) {
        $exitCode = 1
        try { Save-SetupState -Status 'Failed' -Detail $_.Exception.Message } catch { Write-Warning "Could not save state: $_" }
    }
} finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    if ($lockHeld) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
exit $exitCode
