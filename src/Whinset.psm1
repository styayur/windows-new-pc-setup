Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WhinsetRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Configuration.ps1')
. (Join-Path $PSScriptRoot 'SetupNewPC.Core.ps1')
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Whinset') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
Register-WhinsetCompleters
Set-Alias -Name whinset -Value Invoke-Whinset -Scope Script
Export-ModuleMember -Function Invoke-Whinset -Alias whinset
