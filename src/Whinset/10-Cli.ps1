function Invoke-Whinset {
    <#
    .SYNOPSIS
        Deterministic Windows 11 setup with explicit plans, package identities and one-UAC orchestration.
    .DESCRIPTION
        Whinset separates planning from execution. Use plan to inspect the exact operation graph, apply to execute it, status to inspect resumable state, doctor to check prerequisites and recover to inspect or retry failed/interrupted work.
    .EXAMPLE
        whinset plan -Profile Developer
    .EXAMPLE
        whinset apply -Profile Minimal -AcceptAgreements
    .EXAMPLE
        whinset doctor -Json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position=0)][string]$Command = 'help',
        [Parameter(Position=1)][string]$Topic = '',
        [string]$Profile = 'Developer',
        [string[]]$Package = @(),
        [string[]]$Exclude = @(),
        [string[]]$Group = @(),
        [switch]$IncludePersonal,
        [switch]$SkipStoreApps,
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
    $commandKey = [string]$Command
    if ([string]::IsNullOrWhiteSpace($commandKey)) { $commandKey = 'help' }
    $commandKey = $commandKey.ToLowerInvariant()
    $exitCode = 0
    try {
        if ($commandKey -notin $script:WhinsetAllowedCommands) { throw "Unknown command '$Command'. Run 'whinset help'." }
        $badGroups = @($Group | Where-Object { $_ -notin $script:WhinsetAllowedGroups })
        if ($badGroups.Count -gt 0) { throw "Unknown group. Available groups: $($script:WhinsetAllowedGroups -join ', ')" }
        if ($Stage -notin @('Auto','WindowsBase','Development')) { throw 'Stage must be Auto, WindowsBase or Development.' }
        if ($MaxAttempts -lt 1 -or $MaxAttempts -gt 5) { throw 'MaxAttempts must be between 1 and 5.' }
        if ($InstallTimeoutSeconds -lt 30 -or $InstallTimeoutSeconds -gt 14400) { throw 'InstallTimeoutSeconds must be between 30 and 14400.' }
        if ($Help -or $commandKey -eq 'help') {
            $helpTopic = $Topic
            if ($commandKey -eq 'help') { $helpTopic = $Topic } else { $helpTopic = $Command }
            $text = Show-WhinsetHelp -Topic $helpTopic
            if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value ([pscustomobject][ordered]@{ Ok=$true; Command='help'; Text=$text }) -Depth 5) }
            else { Write-Output $text }
            $global:LASTEXITCODE = 0
            return
        }
        if ($PlanOnly -and $commandKey -eq 'apply') { $commandKey = 'plan' }
        if (-not $ConfigPath) { $ConfigPath = Join-Path (Get-WhinsetRepositoryRoot) 'config\packages.json' }
        switch ($commandKey) {
            'version' {
                $info = [pscustomobject][ordered]@{ Name='Whinset'; Version=$script:WhinsetVersion; PowerShell=$PSVersionTable.PSVersion.ToString(); Edition=[string]$PSVersionTable.PSEdition; RepositoryRoot=(Get-WhinsetRepositoryRoot) }
                if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value $info -Depth 8) } else { Write-Output "Whinset $($info.Version)  PowerShell $($info.PowerShell) $($info.Edition)" }
            }
            'plan' {
                $plan = New-WhinsetPlan -CatalogPath $ConfigPath -Profile $Profile -Package $Package -Exclude $Exclude -Group $Group -IncludePersonal:$IncludePersonal -SkipStoreApps:$SkipStoreApps -Stage $Stage -ConfigureEnvironment:$ConfigureEnvironment -SkipCondaInit:$SkipCondaInit -EnableWsl:$EnableWsl -EnableDocker:$EnableDocker -DockerSmokeTest:$DockerSmokeTest -ApplicationsOnly:$ApplicationsOnly -MaxAttempts $MaxAttempts -InstallTimeoutSeconds $InstallTimeoutSeconds -Offline:$Offline
                if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value $plan -Depth 60) } else { Write-WhinsetPlanHuman -Plan $plan -Detailed:$Detailed }
            }
            'apply' {
                if (-not $AcceptAgreements) { throw 'Review the plan and software/source licenses, then pass -AcceptAgreements to execute.' }
                $result = Invoke-WhinsetApply -CatalogPath $ConfigPath -Profile $Profile -Package $Package -Exclude $Exclude -Group $Group -IncludePersonal:$IncludePersonal -SkipStoreApps:$SkipStoreApps -Stage $Stage -ConfigureEnvironment:$ConfigureEnvironment -SkipCondaInit:$SkipCondaInit -EnableWsl:$EnableWsl -EnableDocker:$EnableDocker -DockerSmokeTest:$DockerSmokeTest -ApplicationsOnly:$ApplicationsOnly -MaxAttempts $MaxAttempts -InstallTimeoutSeconds $InstallTimeoutSeconds -AcceptAgreements -StateDirectory $StateDirectory
                $exitCode = [int]$result.ExitCode
                if ($Json) {
                    $errorText = ''
                    if ($result.PSObject.Properties['Error']) { $errorText = [string]$result.Error }
                    $output = [ordered]@{ Ok=($exitCode -eq 0); ExitCode=$exitCode; Status=$result.Status; RunId=$result.State.RunId; PlanHash=$result.Plan.PlanHash; RunDirectory=$result.Paths.RunDirectory; LogPath=$result.Paths.EventsPath; State=$result.State; Recovery=(Get-WhinsetRecoveryPlan -State $result.State); Error=$errorText }
                    Write-Output (ConvertTo-WhinsetJson -Value $output -Depth 60)
                } else { Write-WhinsetApplyHuman -Result $result }
            }
            'status' {
                $status = Get-WhinsetStatusObject -StateRoot $StateDirectory -RunId $RunId
                if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value $status -Depth 60) } else { Write-WhinsetStatusHuman -Status $status }
            }
            'doctor' {
                $report = Get-WhinsetDoctorReport -StateRoot $StateDirectory
                if (-not $report.Ok) { $exitCode = [int]$script:WhinsetExitCodes.Unhealthy }
                if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value $report -Depth 60) } else { Write-WhinsetDoctorHuman -Report $report }
            }
            'resolve' {
                if (-not $Topic -and $Package.Count -gt 0) { $Topic = $Package[0] }
                if (-not $Topic) { throw 'resolve requires a query, for example: whinset resolve chrome' }
                $catalog = Read-WhinsetCatalog -Path $ConfigPath
                $resolved = Get-WhinsetResolveResult -Catalog $catalog -Query $Topic
                if (-not $resolved.Ok) { $exitCode = [int]$script:WhinsetExitCodes.InvalidInput }
                if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value $resolved -Depth 20) } else { Write-WhinsetResolveHuman -Result $resolved }
            }
            'recover' {
                $root = $StateDirectory
                if (-not $root) { $root = Get-WhinsetDefaultStateRoot }
                if ($Retry) {
                    if (-not $RunId) {
                        $status = Get-WhinsetStatusObject -StateRoot $root
                        if (-not $status.HasRun) { throw 'No Whinset run is available to retry.' }
                        $RunId = $status.Latest.RunId
                    }
                    $result = Invoke-WhinsetResumeRun -StateRoot $root -RunId $RunId
                    $exitCode = [int]$result.ExitCode
                    if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value ([ordered]@{ Ok=($exitCode -eq 0); ExitCode=$exitCode; Status=$result.Status; RunId=$result.State.RunId; PlanHash=$result.Plan.PlanHash; State=$result.State; Recovery=(Get-WhinsetRecoveryPlan -State $result.State); RunDirectory=$result.Paths.RunDirectory; LogPath=$result.Paths.EventsPath }) -Depth 60) }
                    else { Write-WhinsetApplyHuman -Result $result }
                } else {
                    $status = Get-WhinsetStatusObject -StateRoot $root -RunId $RunId
                    if (-not $status.HasRun) { throw 'No Whinset run is available for recovery.' }
                    $runDirectory = ''
                    if ($status.Latest.PSObject.Properties['Paths']) { $runDirectory = [string]$status.Latest.Paths.RunDirectory }
                    $output = [ordered]@{ Ok=$true; ExitCode=0; RunId=$status.Latest.RunId; RunDirectory=$runDirectory; Recovery=$status.Recovery }
                    if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value $output -Depth 40) }
                    else {
                        Write-Output ("Run {0} status: {1}" -f $status.Latest.RunId, $status.Latest.Status)
                        Write-Output ("Reboot required: {0}; same boot: {1}" -f $status.Recovery.RebootRequired, $status.Recovery.SameBoot)
                        if ($status.Recovery.PendingOperations.Count -gt 0) { $status.Recovery.PendingOperations | ForEach-Object { [pscustomobject][ordered]@{ Name=$_.Name; Status=$_.Status; Privilege=$_.Privilege; Error=$_.Error; Rollback=$_.Recovery.Class } } | Format-Table -AutoSize | Out-String -Width 240 | Write-Output }
                        Write-Output ("Retry: {0}" -f $status.Recovery.RetryCommand)
                    }
                }
            }
            'install-cli' {
                $install = Install-WhinsetCli
                if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value $install -Depth 12) }
                else {
                    Write-Output "Installed Whinset CLI at $($install.InstallRoot)"
                    Write-Output $install.CommandHint
                    if ($install.PathAdded) { Write-Output 'The current user PATH was updated. Open a new terminal to use the command.' }
                }
            }
        }
    } catch {
        if ($commandKey -eq 'doctor') { $exitCode = [int]$script:WhinsetExitCodes.Unhealthy }
        elseif ($commandKey -in @('help','plan','resolve','apply','recover')) { $exitCode = [int]$script:WhinsetExitCodes.InvalidInput }
        else { $exitCode = [int]$script:WhinsetExitCodes.OperationFailed }
        if ($Json) { Write-Output (ConvertTo-WhinsetJson -Value ([ordered]@{ Ok=$false; Command=$commandKey; ExitCode=$exitCode; Error=$_.Exception.Message }) -Depth 12) }
        else { [Console]::Error.WriteLine("whinset: $($_.Exception.Message)") }
    }
    $global:LASTEXITCODE = $exitCode
}
