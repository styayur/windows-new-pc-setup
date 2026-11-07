$script:WhinsetVersion = '2.0.0-rc.2'
$script:WhinsetSchemaVersion = 2
$script:WhinsetStateSchemaVersion = 1
$script:WhinsetAllowedCommands = @('help','plan','apply','status','doctor','resolve','recover','install-cli','version')
$script:WhinsetAllowedGroups = @('Core','Developer','AI','Engineering','Personal')
$script:WhinsetExitCodes = [ordered]@{
    Success          = 0
    OperationFailed  = 1
    InvalidInput     = 2
    Canceled         = 3
    ElevationDenied  = 4
    Unhealthy        = 5
    RebootRequired   = 3010
}
$script:WhinsetPublicProfileNames = @('Minimal','Developer','AI','Engineering','Full')
