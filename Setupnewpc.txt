# Compatibility wrapper.
# The active implementation lives in SetupNewPC_Optimized.ps1.
$target = Join-Path $PSScriptRoot 'SetupNewPC_Optimized.ps1'
if (-not (Test-Path -LiteralPath $target)) {
    throw "找不到主脚本：$target"
}
& $target @args
exit $LASTEXITCODE
