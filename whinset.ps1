#requires -Version 5.1
<#
.SYNOPSIS
    Whinset command entry point.
.DESCRIPTION
    Run 'whinset help' for usage. Planning is read-only; apply requires explicit agreement and requests UAC once only when the validated plan contains elevated work.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ArgumentCompleter({
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $word = if ($null -eq $wordToComplete) { '' } else { [string]$wordToComplete }
        foreach ($candidate in @('help','plan','apply','status','doctor','resolve','recover','install-cli','version')) {
            if (-not $word -or $candidate -like "$word*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) }
        }
    })]
    [string]$Command = 'help',
    [Parameter(Position=1)][string]$Topic = '',
    [ArgumentCompleter({
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $word = if ($null -eq $wordToComplete) { '' } else { [string]$wordToComplete }
        foreach ($candidate in @('Minimal','Developer','AI','Engineering','Full')) {
            if (-not $word -or $candidate -like "$word*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) }
        }
    })]
    [string]$Profile = 'Developer',
    [ArgumentCompleter({
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $word = if ($null -eq $wordToComplete) { '' } else { [string]$wordToComplete }
        try {
            $catalogPath = Join-Path $env:LOCALAPPDATA 'Whinset\current\config\packages.json'
            if (-not (Test-Path -LiteralPath $catalogPath)) {
                $resolved = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($resolved -and $resolved.Source) { $catalogPath = Join-Path (Split-Path $resolved.Source -Parent) 'config\packages.json' }
            }
            if (-not (Test-Path -LiteralPath $catalogPath)) { $catalogPath = Join-Path (Get-Location) 'config\packages.json' }
            if (Test-Path -LiteralPath $catalogPath) {
                $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($package in @($catalog.Packages)) {
                    if (-not $word -or $package.Key -like "$word*" -or $package.Id -like "$word*") { [System.Management.Automation.CompletionResult]::new($package.Key,$package.Key,[System.Management.Automation.CompletionResultType]::ParameterValue,"$($package.Name) [$($package.Source):$($package.Id)]") }
                }
            }
        } catch { }
    })]
    [string[]]$Package = @(),
    [ArgumentCompleter({
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $word = if ($null -eq $wordToComplete) { '' } else { [string]$wordToComplete }
        try {
            $catalogPath = Join-Path $env:LOCALAPPDATA 'Whinset\current\config\packages.json'
            if (-not (Test-Path -LiteralPath $catalogPath)) {
                $resolved = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($resolved -and $resolved.Source) { $catalogPath = Join-Path (Split-Path $resolved.Source -Parent) 'config\packages.json' }
            }
            if (-not (Test-Path -LiteralPath $catalogPath)) { $catalogPath = Join-Path (Get-Location) 'config\packages.json' }
            if (Test-Path -LiteralPath $catalogPath) {
                $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($package in @($catalog.Packages)) {
                    if (-not $word -or $package.Key -like "$word*" -or $package.Id -like "$word*") { [System.Management.Automation.CompletionResult]::new($package.Key,$package.Key,[System.Management.Automation.CompletionResultType]::ParameterValue,"$($package.Name) [$($package.Source):$($package.Id)]") }
                }
            }
        } catch { }
    })]
    [string[]]$Exclude = @(),
    [ArgumentCompleter({
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $word = if ($null -eq $wordToComplete) { '' } else { [string]$wordToComplete }
        foreach ($candidate in @('Core','Developer','AI','Engineering','Personal')) {
            if (-not $word -or $candidate -like "$word*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) }
        }
    })]
    [string[]]$Group = @(),
    [switch]$IncludePersonal,
    [switch]$SkipStoreApps,
    [ArgumentCompleter({
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $word = if ($null -eq $wordToComplete) { '' } else { [string]$wordToComplete }
        foreach ($candidate in @('Auto','WindowsBase','Development')) {
            if (-not $word -or $candidate -like "$word*") { [System.Management.Automation.CompletionResult]::new($candidate,$candidate,[System.Management.Automation.CompletionResultType]::ParameterValue,$candidate) }
        }
    })]
    [string]$Stage = 'Auto',
    [switch]$ConfigureEnvironment,
    [switch]$SkipCondaInit,
    [switch]$EnableWsl,
    [switch]$EnableDocker,
    [switch]$DockerSmokeTest,
    [switch]$ApplicationsOnly,
    [int]$MaxAttempts = 2,
    [int]$InstallTimeoutSeconds = 3600,
    [switch]$AcceptAgreements,
    [switch]$Json,
    [switch]$Offline,
    [switch]$Detailed,
    [Alias('WhatIf')][switch]$PlanOnly,
    [string]$ConfigPath = '',
    [string]$StateDirectory = '',
    [string]$RunId = '',
    [switch]$Retry,
    [Alias('?')][switch]$Help
)
$ErrorActionPreference = 'Stop'
# A stable pipe encoding is part of the -Json contract, including PowerShell 5.1.
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
try {
    Import-Module (Join-Path $PSScriptRoot 'src\Whinset.psd1') -Force -ErrorAction Stop
    Invoke-Whinset -Command $Command -Topic $Topic -Profile $Profile -Package $Package -Exclude $Exclude -Group $Group -IncludePersonal:$IncludePersonal -SkipStoreApps:$SkipStoreApps -Stage $Stage -ConfigureEnvironment:$ConfigureEnvironment -SkipCondaInit:$SkipCondaInit -EnableWsl:$EnableWsl -EnableDocker:$EnableDocker -DockerSmokeTest:$DockerSmokeTest -ApplicationsOnly:$ApplicationsOnly -MaxAttempts $MaxAttempts -InstallTimeoutSeconds $InstallTimeoutSeconds -AcceptAgreements:$AcceptAgreements -Json:$Json -Offline:$Offline -Detailed:$Detailed -PlanOnly:$PlanOnly -ConfigPath $ConfigPath -StateDirectory $StateDirectory -RunId $RunId -Retry:$Retry -Help:$Help
    exit $global:LASTEXITCODE
} catch {
    if ($Json) { [ordered]@{ Ok=$false; Command=$Command; ExitCode=2; Error=$_.Exception.Message } | ConvertTo-Json -Depth 8 -Compress } else { [Console]::Error.WriteLine("whinset: $($_.Exception.Message)") }
    exit 2
}
