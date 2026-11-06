param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ReadyPath,
    [int]$HoldSeconds = 20
)
$mutex = New-Object Threading.Mutex($false, $Name)
try {
    [void]$mutex.WaitOne()
    Set-Content -LiteralPath $ReadyPath -Value 'ready' -Encoding UTF8
    Start-Sleep -Seconds $HoldSeconds
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
