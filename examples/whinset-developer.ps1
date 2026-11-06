#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$AcceptAgreements
)
$entry = Join-Path (Split-Path $PSScriptRoot -Parent) 'whinset.ps1'
$common = @{
    Profile = 'Developer'
    Exclude = @('Postman','DBeaver')
    SkipStoreApps = $true
}
if ($AcceptAgreements) {
    & $entry apply -Profile $common.Profile -Exclude $common.Exclude -SkipStoreApps -AcceptAgreements
} else {
    & $entry plan -Profile $common.Profile -Exclude $common.Exclude -SkipStoreApps
}
exit $LASTEXITCODE
