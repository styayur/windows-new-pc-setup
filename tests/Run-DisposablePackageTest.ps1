#requires -Version 5.1
param([Parameter(Mandatory)][string]$EvidencePath)
# Real component integration, restricted to disposable GitHub-hosted environments.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'This installer test is restricted to disposable GitHub-hosted runners.' }
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/Whinset.psd1') -Force
& (Get-Module Whinset) {
    param($Root,$EvidencePath)
    $environment = Get-WhinsetEnvironmentSnapshot
    $plan = New-WhinsetPlan -CatalogPath (Join-Path $Root 'config/packages.json') -Profile Minimal -Package Notepad3 -Offline -Environment $environment
    $paths = Get-WhinsetRunPaths -StateRoot (Join-Path $env:RUNNER_TEMP 'real-package-state') -PlanHash $plan.PlanHash
    Initialize-WhinsetPrivateRunDirectory $paths.RunDirectory
    $state = New-WhinsetRunState $plan $environment $paths
    $operation = @($plan.Operations | Where-Object PackageKey -eq Notepad3)[0]
    # No synthetic Windows 11 environment: exercise the package component on the actual runner OS.
    $package = [pscustomobject]@{ Key=$operation.PackageKey; Id=$operation.PackageId; Source=$operation.Source; Architecture=$operation.Architecture; Scope=$operation.Scope; Version=$operation.Version; VersionPolicy=$operation.VersionPolicy }
    $before = Test-WhinsetPackageInstalled $package -AcceptAgreements
    if ($before.Installed) { throw 'Notepad3 already exists; this run cannot prove a fresh installation.' }
    $first = Invoke-WhinsetPackageOperation $plan $state $operation $paths
    $second = Invoke-WhinsetPackageOperation $plan $state $operation $paths
    $evidence = [ordered]@{ SchemaVersion=1; Suite='real disposable package component integration'; Environment=$environment; Package=$package; First=$first; Repeated=$second; InteractiveUac='NOT RUN'; Reboot='NOT RUN'; Windows11CliAcceptance='NOT APPLICABLE'; RunUrl="https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" }
    Write-WhinsetJsonFileAtomically $EvidencePath $evidence
    if ($first.Status -ne 'Succeeded' -or $second.Status -ne 'AlreadyInstalled') { throw 'Fresh installation or repeated package verification failed; inspect evidence.' }
} $root $EvidencePath
