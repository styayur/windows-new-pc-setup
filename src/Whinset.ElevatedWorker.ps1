#requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$PlanHash,
    [Parameter(Mandatory)][string]$Nonce
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Whinset.psd1') -Force -ErrorAction Stop
    $result = Invoke-WhinsetElevatedWorker -PlanPath $PlanPath -PlanHash $PlanHash -Nonce $Nonce
    exit ([int]$result.ExitCode)
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
