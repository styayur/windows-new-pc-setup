#requires -Version 5.1
[CmdletBinding()]
param([switch]$WhatIf, [switch]$AcceptAgreements)
$setup = @{
    Profile = 'Developer'
    ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\packages.json'
    Exclude = @('Postman', 'DBeaver')
    EnableDocker = $false
    ConfigureEnvironment = $false
    SkipStoreApps = $true
    WhatIf = $WhatIf
    AcceptAgreements = $AcceptAgreements
}
& (Join-Path (Split-Path $PSScriptRoot -Parent) 'SetupNewPC_Optimized.ps1') @setup
exit $LASTEXITCODE
