#requires -Version 5.1
# Shared engine; every missing package requires an explicit Y response.
# Pass -WhatIf to preview, -AcceptAgreements to allow source agreement acceptance.
& (Join-Path $PSScriptRoot 'SetupNewPC_Optimized.ps1') -ApplicationsOnly -ConfirmEach @args
exit $LASTEXITCODE
