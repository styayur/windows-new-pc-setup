function New-WhinsetOperationResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = '',
        [string]$Error = '',
        [AllowNull()]$ExitCode = $null,
        [switch]$RebootRequired,
        [switch]$StopAll,
        [AllowNull()]$RecoveryData = $null
    )
    return [pscustomobject][ordered]@{ Status=$Status; Detail=$Detail; Error=$Error; ExitCode=$ExitCode; RebootRequired=[bool]$RebootRequired; StopAll=[bool]$StopAll; RecoveryData=$RecoveryData }
}

function Test-WhinsetWingetRebootCode {
    param([AllowNull()]$ExitCode)
    return ($null -ne $ExitCode -and [int]$ExitCode -in @(3010,1641,-1978334967,-1978334966,-1978334965))
}

function Get-WhinsetWingetInstallArguments {
    param([Parameter(Mandatory)]$Package)
    $arguments = @('install','--id',$Package.Id,'--exact','--source',$Package.Source,'--accept-source-agreements','--accept-package-agreements','--silent','--disable-interactivity','--no-upgrade')
    if ($Package.Version) { $arguments += @('--version',[string]$Package.Version) }
    if ($Package.Scope -in @('user','machine')) { $arguments += @('--scope',[string]$Package.Scope) }
    return $arguments
}

function Update-WhinsetSessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = "$machinePath;$userPath"
}

function Invoke-WhinsetPackageOperation {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Operation,
        [Parameter(Mandatory)]$Paths
    )
    if ($Operation.Action -eq 'none') { return (New-WhinsetOperationResult -Status 'AlreadyInstalled' -Detail 'Detected by the plan; no installer was started.' -ExitCode 0) }
    if ($Operation.Action -eq 'fail-conflict') { return (New-WhinsetOperationResult -Status 'Failed' -Error 'Installed version differs from the pinned request. Resolve manually; no upgrade or downgrade was attempted.') }
    $package = [pscustomobject][ordered]@{
        Key = $Operation.PackageKey
        Id = $Operation.PackageId
        Source = $Operation.Source
        Architecture = $Operation.Architecture
        Scope = $Operation.Scope
        Version = $Operation.Version
        VersionPolicy = $Operation.VersionPolicy
    }
    $probe = Test-WhinsetPackageInstalled -Package $package -AcceptAgreements
    if ($probe.Installed) {
        if ($package.VersionPolicy -eq 'pinned' -and -not $probe.VersionVerified) {
            return (New-WhinsetOperationResult -Status 'Failed' -Error "Installed package exists but the pinned version $($package.Version) could not be verified. No change was made." -ExitCode $probe.ExitCode)
        }
        return (New-WhinsetOperationResult -Status 'AlreadyInstalled' -Detail 'Verified through exact WinGet identity before installation.' -ExitCode 0)
    }
    if ($probe.Error) {
        return (New-WhinsetOperationResult -Status 'Failed' -Error $probe.Error -ExitCode $probe.ExitCode)
    }
    $maxAttempts = [int]$Plan.Execution.MaxAttempts
    $timeout = [int]$Plan.Execution.InstallTimeoutSeconds
    $lastError = ''
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            $recheck = Test-WhinsetPackageInstalled -Package $package -AcceptAgreements
            if ($recheck.Installed -and ($package.VersionPolicy -ne 'pinned' -or $recheck.VersionVerified)) {
                return (New-WhinsetOperationResult -Status 'AlreadyInstalled' -Detail 'Verified after an interrupted installer attempt; no duplicate install was started.' -ExitCode 0)
            }
            if ($recheck.Error) { return (New-WhinsetOperationResult -Status 'Failed' -Error $recheck.Error -ExitCode $recheck.ExitCode) }
            Set-WhinsetOperationRecord -State $State -OperationId $Operation.Id -Status 'Running' -Detail "Retry attempt $attempt of $maxAttempts" -IncrementAttempt
            Save-WhinsetRunState -State $State -Paths $Paths
        }
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'install.start' -Data @{ OperationId=$Operation.Id; Package=$Operation.PackageId; Source=$Operation.Source; Attempt=$attempt }
        try {
            $result = Invoke-WhinsetExternalCommand -FilePath 'winget.exe' -ArgumentList (Get-WhinsetWingetInstallArguments -Package $package) -TimeoutSeconds $timeout
        } catch {
            $lastError = $_.Exception.Message
            Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'install.exception' -Data @{ OperationId=$Operation.Id; Attempt=$attempt; Error=$lastError }
            continue
        }
        $combined = "$($result.Output)`n$($result.Error)".Trim()
        if ($combined.Length -gt 12000) { $combined = $combined.Substring(0,12000) + '...[truncated]' }
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'install.end' -Data @{ OperationId=$Operation.Id; Attempt=$attempt; ExitCode=$result.ExitCode; TimedOut=$result.TimedOut; Output=$combined }
        if (Test-WhinsetWingetRebootCode -ExitCode $result.ExitCode) {
            return (New-WhinsetOperationResult -Status 'AwaitingReboot' -Detail "WinGet requested a restart (exit $($result.ExitCode))." -ExitCode $result.ExitCode -RebootRequired)
        }
        if ($result.TimedOut) {
            return (New-WhinsetOperationResult -Status 'Failed' -Error 'Installer timed out. No later installer will be started until you inspect running processes and retry.' -ExitCode $result.ExitCode -StopAll)
        }
        if ($result.Success -or [int]$result.ExitCode -in @(-1978335135,-1978335189)) {
            $verified = Test-WhinsetPackageInstalled -Package $package -AcceptAgreements
            if ($verified.Installed -and ($package.VersionPolicy -ne 'pinned' -or $verified.VersionVerified)) {
                return (New-WhinsetOperationResult -Status 'Succeeded' -Detail 'Installed and verified through exact WinGet identity.' -ExitCode $result.ExitCode)
            }
            $lastError = "Installer exited but exact package verification failed. $($verified.Error)"
        } else {
            $lastError = "WinGet exit $($result.ExitCode): $combined"
        }
        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds ([Math]::Min(10, $attempt * 3)) }
    }
    if ($lastError.Length -gt 3000) { $lastError = $lastError.Substring(0,3000) + '...[truncated]' }
    return (New-WhinsetOperationResult -Status 'Failed' -Error $lastError)
}

function Get-WhinsetOptionalFeatureState {
    param([Parameter(Mandatory)][string]$Name)
    try { return [string](Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State }
    catch { return 'Unknown' }
}

function Get-WhinsetVirtualizationSnapshot {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $hypervisor = $false
    if ($computer -and $null -ne $computer.HypervisorPresent) { $hypervisor = [bool]$computer.HypervisorPresent }
    $firmware = $null; $extensions = $null; $slat = $null
    if ($cpu) {
        if ($null -ne $cpu.VirtualizationFirmwareEnabled) { $firmware = [bool]$cpu.VirtualizationFirmwareEnabled }
        if ($null -ne $cpu.VMMonitorModeExtensions) { $extensions = [bool]$cpu.VMMonitorModeExtensions }
        if ($null -ne $cpu.SecondLevelAddressTranslationExtensions) { $slat = [bool]$cpu.SecondLevelAddressTranslationExtensions }
    }
    return [pscustomobject][ordered]@{ HypervisorPresent=$hypervisor; VirtualizationFirmwareEnabled=$firmware; VMMonitorModeExtensions=$extensions; SecondLevelAddressTranslation=$slat }
}

function Test-WhinsetVirtualizationBlocker {
    param([Parameter(Mandatory)]$Report)
    if ($Report.HypervisorPresent) { return $false }
    return ($Report.VirtualizationFirmwareEnabled -eq $false -or $Report.VMMonitorModeExtensions -eq $false -or $Report.SecondLevelAddressTranslation -eq $false)
}

function Invoke-WhinsetWslFeaturesOperation {
    $virtualization = Get-WhinsetVirtualizationSnapshot
    if (Test-WhinsetVirtualizationBlocker -Report $virtualization) {
        return (New-WhinsetOperationResult -Status 'Failed' -Error 'CPU virtualization, VT-x/AMD-V or SLAT is unavailable. Enable virtualization in UEFI/BIOS before retrying.' -RecoveryData $virtualization)
    }
    $features = @('VirtualMachinePlatform','Microsoft-Windows-Subsystem-Linux')
    $states = [ordered]@{}
    $reboot = $false
    foreach ($feature in $features) {
        $state = Get-WhinsetOptionalFeatureState -Name $feature
        $states[$feature] = $state
        if ($state -in @('Enabled','EnablePending')) {
            if ($state -eq 'EnablePending') { $reboot = $true }
            continue
        }
        try {
            $activation = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
            if ($activation.RestartNeeded) { $reboot = $true }
            $states[$feature] = Get-WhinsetOptionalFeatureState -Name $feature
        } catch {
            return (New-WhinsetOperationResult -Status 'Failed' -Error "Failed to enable $feature`: $($_.Exception.Message)" -RecoveryData $states)
        }
    }
    if ($reboot -or @($states.Values | Where-Object { $_ -eq 'EnablePending' }).Count -gt 0) {
        return (New-WhinsetOperationResult -Status 'AwaitingReboot' -Detail 'Windows feature activation requires a restart before WSL can be configured.' -RebootRequired -RecoveryData $states)
    }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail 'WSL optional features are enabled.' -RecoveryData $states)
}

function Get-WhinsetWslDistros {
    try { $result = Invoke-WhinsetExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--list','--verbose') -TimeoutSeconds 30 }
    catch { return [pscustomobject][ordered]@{ Success=$false; Distros=@(); Output=''; Error=$_.Exception.Message } }
    if (-not $result.Success) { return [pscustomobject][ordered]@{ Success=$false; Distros=@(); Output=$result.Output; Error=$result.Error } }
    $distros = @()
    foreach ($line in @($result.Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^NAME\s+STATE\s+VERSION') { continue }
        $isDefault = $trimmed.StartsWith('*')
        $clean = $trimmed.TrimStart('*').Trim()
        $parts = @($clean -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 3) { continue }
        $distros += [pscustomobject][ordered]@{ Name=$parts[0]; State=$parts[$parts.Count-2]; Version=$parts[$parts.Count-1]; IsDefault=$isDefault }
    }
    return [pscustomobject][ordered]@{ Success=$true; Distros=$distros; Output=$result.Output; Error=$result.Error }
}

function Invoke-WhinsetWslRuntimeOperation {
    $vmp = Get-WhinsetOptionalFeatureState -Name 'VirtualMachinePlatform'
    $wslFeature = Get-WhinsetOptionalFeatureState -Name 'Microsoft-Windows-Subsystem-Linux'
    if ($vmp -in @('EnablePending','DisablePending') -or $wslFeature -in @('EnablePending','DisablePending')) {
        return (New-WhinsetOperationResult -Status 'AwaitingReboot' -Detail 'WSL feature changes are still pending a restart.' -RebootRequired -RecoveryData ([ordered]@{ VirtualMachinePlatform=$vmp; WSL=$wslFeature }))
    }
    if ($vmp -ne 'Enabled' -or $wslFeature -ne 'Enabled') {
        return (New-WhinsetOperationResult -Status 'Failed' -Error "WSL prerequisites are not enabled (VirtualMachinePlatform=$vmp; WSL=$wslFeature).")
    }
    $update = Invoke-WhinsetExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--update') -TimeoutSeconds 900
    if (Test-WhinsetWingetRebootCode -ExitCode $update.ExitCode) { return (New-WhinsetOperationResult -Status 'AwaitingReboot' -Detail 'wsl --update requested a restart.' -ExitCode $update.ExitCode -RebootRequired) }
    if (-not $update.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "wsl --update failed: $($update.Error) $($update.Output)" -ExitCode $update.ExitCode) }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail 'Machine WSL runtime updated; distribution registration remains in the original user phase.' -ExitCode 0)
}

function Invoke-WhinsetWslDistributionOperation {
    $default = Invoke-WhinsetExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--set-default-version','2') -TimeoutSeconds 60
    if (-not $default.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "wsl --set-default-version 2 failed: $($default.Error) $($default.Output)" -ExitCode $default.ExitCode) }
    $report = Get-WhinsetWslDistros
    if (-not $report.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "wsl --list --verbose failed: $($report.Error)") }
    $ubuntu = @($report.Distros | Where-Object { $_.Name -match '^Ubuntu' } | Select-Object -First 1)
    if ($ubuntu.Count -eq 0) {
        $install = Invoke-WhinsetExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--install','--distribution','Ubuntu','--no-launch') -TimeoutSeconds 1800
        if (Test-WhinsetWingetRebootCode -ExitCode $install.ExitCode) { return (New-WhinsetOperationResult -Status 'AwaitingReboot' -Detail 'Ubuntu installation requested a restart.' -ExitCode $install.ExitCode -RebootRequired) }
        if (-not $install.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "Ubuntu installation failed: $($install.Error) $($install.Output)" -ExitCode $install.ExitCode) }
        $report = Get-WhinsetWslDistros
        $ubuntu = @($report.Distros | Where-Object { $_.Name -match '^Ubuntu' } | Select-Object -First 1)
    }
    if ($ubuntu.Count -eq 0) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'Ubuntu was not detected after installation.') }
    if ([int]$ubuntu[0].Version -ne 2) {
        $convert = Invoke-WhinsetExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--set-version',$ubuntu[0].Name,'2') -TimeoutSeconds 1800
        if (Test-WhinsetWingetRebootCode -ExitCode $convert.ExitCode) { return (New-WhinsetOperationResult -Status 'AwaitingReboot' -Detail 'WSL version conversion requested a restart.' -ExitCode $convert.ExitCode -RebootRequired) }
        if (-not $convert.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "WSL2 conversion failed: $($convert.Error) $($convert.Output)" -ExitCode $convert.ExitCode) }
        $report = Get-WhinsetWslDistros
        $ubuntu = @($report.Distros | Where-Object { $_.Name -match '^Ubuntu' } | Select-Object -First 1)
    }
    if ($ubuntu.Count -eq 0 -or [int]$ubuntu[0].Version -ne 2) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'WSL2 Ubuntu validation did not pass.') }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail "WSL2 runtime ready: $($ubuntu[0].Name)." -RecoveryData $report.Distros)
}

function Invoke-WhinsetDockerOperation {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Operation, [Parameter(Mandatory)]$Paths)
    $package = [pscustomobject][ordered]@{ Key='Docker'; Id='Docker.DockerDesktop'; Source='winget'; Architecture='auto'; Scope='machine'; Version=$null; VersionPolicy='latest' }
    $probe = Test-WhinsetPackageInstalled -Package $package -AcceptAgreements
    if ($probe.Error) { return (New-WhinsetOperationResult -Status 'Failed' -Error $probe.Error -ExitCode $probe.ExitCode) }
    if (-not $probe.Installed) {
        $arguments = Get-WhinsetWingetInstallArguments -Package $package
        $lastError = ''
        for ($attempt=1; $attempt -le [int]$Plan.Execution.MaxAttempts; $attempt++) {
            if ($attempt -gt 1) {
                Set-WhinsetOperationRecord -State $State -OperationId $Operation.Id -Status 'Running' -Detail "Docker install retry $attempt" -IncrementAttempt
                Save-WhinsetRunState -State $State -Paths $Paths
            }
            $result = Invoke-WhinsetExternalCommand -FilePath 'winget.exe' -ArgumentList $arguments -TimeoutSeconds ([int]$Plan.Execution.InstallTimeoutSeconds)
            if (Test-WhinsetWingetRebootCode -ExitCode $result.ExitCode) { return (New-WhinsetOperationResult -Status 'AwaitingReboot' -Detail 'Docker Desktop requested a restart.' -ExitCode $result.ExitCode -RebootRequired) }
            if ($result.TimedOut) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'Docker Desktop installation timed out.' -StopAll -ExitCode $result.ExitCode) }
            if ($result.Success -or [int]$result.ExitCode -in @(-1978335135,-1978335189)) {
                $verified = Test-WhinsetPackageInstalled -Package $package -AcceptAgreements
                if ($verified.Installed) { break }
                $lastError = "Docker installation could not be verified. $($verified.Error)"
            } else { $lastError = "WinGet exit $($result.ExitCode): $($result.Error) $($result.Output)" }
        }
        if (-not (Test-WhinsetPackageInstalled -Package $package -AcceptAgreements).Installed) { return (New-WhinsetOperationResult -Status 'Failed' -Error $lastError) }
    }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail 'Machine Docker Desktop installation verified; user daemon verification is separate.' -ExitCode 0)
}

function Invoke-WhinsetDockerUserOperation {
    param([Parameter(Mandatory)]$Plan)
    Update-WhinsetSessionPath
    $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $docker) {
        $known = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
        if (Test-Path -LiteralPath $known) { $dockerPath = $known } else { return (New-WhinsetOperationResult -Status 'Warning' -Detail 'Docker is installed but docker.exe is not yet available in this session. Sign out or open a new terminal and rerun verification.') }
    } else { $dockerPath = $docker.Source }
    $info = Invoke-WhinsetExternalCommand -FilePath $dockerPath -ArgumentList @('info','--format','{{.ServerVersion}}') -TimeoutSeconds 60
    if (-not $info.Success) {
        if ($Plan.Request.DockerSmokeTest) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'Docker daemon is not ready; the requested smoke test could not run.') }
        return (New-WhinsetOperationResult -Status 'Warning' -Detail 'Docker Desktop is installed. Open it, complete first-run setup, and rerun whinset doctor/apply to verify the daemon.')
    }
    if ($Plan.Request.DockerSmokeTest) {
        $smoke = Invoke-WhinsetExternalCommand -FilePath $dockerPath -ArgumentList @('run','--rm','hello-world') -TimeoutSeconds 300
        if (-not $smoke.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "Docker hello-world smoke test failed: $($smoke.Error) $($smoke.Output)" -ExitCode $smoke.ExitCode) }
        return (New-WhinsetOperationResult -Status 'Succeeded' -Detail "Docker daemon ready ($($info.Output)) and hello-world passed." -RecoveryData @{ ServerVersion=$info.Output })
    }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail "Docker daemon ready ($($info.Output))." -RecoveryData @{ ServerVersion=$info.Output })
}

function Find-WhinsetCondaExecutable {
    $candidates = @()
    $command = Get-Command conda.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $candidates += @(
        (Join-Path $env:USERPROFILE 'anaconda3\Scripts\conda.exe'),
        (Join-Path $env:USERPROFILE 'miniconda3\Scripts\conda.exe'),
        'C:\ProgramData\Anaconda3\Scripts\conda.exe',
        'C:\ProgramData\Miniconda3\Scripts\conda.exe'
    )
    return ($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

function Invoke-WhinsetGitLfsOperation {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'git.exe not found.') }
    $install = Invoke-WhinsetExternalCommand -FilePath $git.Source -ArgumentList @('lfs','install') -TimeoutSeconds 120
    $verify = Invoke-WhinsetExternalCommand -FilePath $git.Source -ArgumentList @('lfs','version') -TimeoutSeconds 60
    if (-not $install.Success -or -not $verify.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "Git LFS failed: $($install.Error) $($verify.Error)" -ExitCode $install.ExitCode) }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail $verify.Output -ExitCode 0)
}

function Invoke-WhinsetUvOperation {
    $uv = Get-Command uv.exe -ErrorAction SilentlyContinue
    if (-not $uv) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'uv.exe not found.') }
    $prior = [Environment]::GetEnvironmentVariable('UV_PYTHON_PREFERENCE','User')
    [Environment]::SetEnvironmentVariable('UV_PYTHON_PREFERENCE','system','User')
    $env:UV_PYTHON_PREFERENCE = 'system'
    $current = [Environment]::GetEnvironmentVariable('UV_PYTHON_PREFERENCE','User')
    if ($current -ne 'system') { return (New-WhinsetOperationResult -Status 'Failed' -Error 'UV_PYTHON_PREFERENCE was not persisted.') }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail "UV_PYTHON_PREFERENCE=system; $($uv.Source)" -RecoveryData @{ Variable='UV_PYTHON_PREFERENCE'; Scope='User'; Prior=$prior; New='system' })
}

function Invoke-WhinsetCondaOperation {
    param([Parameter(Mandatory)]$Plan)
    $conda = Find-WhinsetCondaExecutable
    if (-not $conda) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'conda.exe not found.') }
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileHash = $null
    if (Test-Path -LiteralPath $profilePath) { $profileHash = Get-WhinsetHashFile -Path $profilePath }
    if (-not $Plan.Request.SkipCondaInit) {
        $init = Invoke-WhinsetExternalCommand -FilePath $conda -ArgumentList @('init','powershell') -TimeoutSeconds 300
        if (-not $init.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "conda init failed: $($init.Error) $($init.Output)" -ExitCode $init.ExitCode) }
    }
    $config = Invoke-WhinsetExternalCommand -FilePath $conda -ArgumentList @('config','--set','auto_activate_base','false') -TimeoutSeconds 120
    if (-not $config.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "conda config failed: $($config.Error) $($config.Output)" -ExitCode $config.ExitCode) }
    $version = Invoke-WhinsetExternalCommand -FilePath $conda -ArgumentList @('--version') -TimeoutSeconds 60
    if (-not $version.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'conda --version failed.') }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail "auto_activate_base=false; $($version.Output)" -RecoveryData @{ ProfilePath=$profilePath; PriorProfileSha256=$profileHash; CondaPath=$conda })
}

function Invoke-WhinsetGoOperation {
    $go = Get-Command go.exe -ErrorAction SilentlyContinue
    if (-not $go) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'go.exe not found.') }
    $prior = Invoke-WhinsetExternalCommand -FilePath $go.Source -ArgumentList @('env','GOPATH') -TimeoutSeconds 30
    $target = Join-Path $env:USERPROFILE 'go'
    $set = Invoke-WhinsetExternalCommand -FilePath $go.Source -ArgumentList @('env','-w',"GOPATH=$target") -TimeoutSeconds 60
    if (-not $set.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "go env -w failed: $($set.Error) $($set.Output)" -ExitCode $set.ExitCode) }
    $version = Invoke-WhinsetExternalCommand -FilePath $go.Source -ArgumentList @('version') -TimeoutSeconds 30
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail $version.Output -RecoveryData @{ PriorGopath=$prior.Output; NewGopath=$target })
}

function Add-WhinsetUserPathEntry {
    param([Parameter(Mandatory)][string]$PathEntry)
    $prior = [Environment]::GetEnvironmentVariable('Path','User')
    $entries = @($prior -split ';' | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('\') })
    $normalized = $PathEntry.Trim().TrimEnd('\')
    if (-not ($entries | Where-Object { $_ -ieq $normalized })) { $entries += $normalized; [Environment]::SetEnvironmentVariable('Path',($entries -join ';'),'User') }
    Update-WhinsetSessionPath
    return $prior
}

function Invoke-WhinsetRustOperation {
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    $priorPath = Add-WhinsetUserPathEntry -PathEntry $cargoBin
    $rustup = Join-Path $cargoBin 'rustup.exe'
    if (-not (Test-Path -LiteralPath $rustup)) {
        $command = Get-Command rustup.exe -ErrorAction SilentlyContinue
        if ($command) { $rustup = $command.Source }
    }
    if (-not (Test-Path -LiteralPath $rustup)) {
        $init = Get-Command rustup-init.exe -ErrorAction SilentlyContinue
        if ($init) {
            $initResult = Invoke-WhinsetExternalCommand -FilePath $init.Source -ArgumentList @('-y','--no-modify-path') -TimeoutSeconds 1200
            if (-not $initResult.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "rustup-init failed: $($initResult.Error) $($initResult.Output)") }
        }
    }
    if (-not (Test-Path -LiteralPath $rustup)) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'rustup.exe was not found after installation.') }
    $default = Invoke-WhinsetExternalCommand -FilePath $rustup -ArgumentList @('default','stable') -TimeoutSeconds 1200
    $rustc = Invoke-WhinsetExternalCommand -FilePath (Join-Path $cargoBin 'rustc.exe') -ArgumentList @('--version') -TimeoutSeconds 30
    $cargo = Invoke-WhinsetExternalCommand -FilePath (Join-Path $cargoBin 'cargo.exe') -ArgumentList @('--version') -TimeoutSeconds 30
    if (-not $default.Success -or -not $rustc.Success -or -not $cargo.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'Rust stable toolchain validation failed.') }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail "$($rustc.Output); $($cargo.Output)" -RecoveryData @{ CargoBin=$cargoBin; PriorUserPath=$priorPath })
}

function Find-WhinsetJavaHome {
    $candidates = @()
    $root = Join-Path $env:ProgramFiles 'Microsoft'
    $candidates += @(Get-ChildItem -Path (Join-Path $root 'jdk-21*') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    foreach ($candidate in $candidates) {
        $release = Join-Path $candidate 'release'
        if ((Test-Path -LiteralPath $release) -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe'))) {
            if ((Get-Content -LiteralPath $release -Raw) -match '(?m)^JAVA_VERSION="21(?:[.\+"]|$)') { return $candidate }
        }
    }
    return $null
}

function Invoke-WhinsetJavaHomeOperation {
    $jdk = Find-WhinsetJavaHome
    if (-not $jdk) { return (New-WhinsetOperationResult -Status 'Failed' -Error 'A Microsoft OpenJDK 21 installation could not be located.') }
    $priorJava = [Environment]::GetEnvironmentVariable('JAVA_HOME','Machine')
    $priorPath = [Environment]::GetEnvironmentVariable('Path','Machine')
    [Environment]::SetEnvironmentVariable('JAVA_HOME',$jdk,'Machine')
    $entries = @($priorPath -split ';' | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('\') })
    $bin = (Join-Path $jdk 'bin').TrimEnd('\')
    if (-not ($entries | Where-Object { $_ -ieq $bin })) { $entries += $bin; [Environment]::SetEnvironmentVariable('Path',($entries -join ';'),'Machine') }
    Update-WhinsetSessionPath
    $env:JAVA_HOME = $jdk
    $verify = Invoke-WhinsetExternalCommand -FilePath (Join-Path $jdk 'bin\java.exe') -ArgumentList @('-version') -TimeoutSeconds 30
    if (-not $verify.Success) { return (New-WhinsetOperationResult -Status 'Failed' -Error "java -version failed: $($verify.Error)") }
    return (New-WhinsetOperationResult -Status 'Succeeded' -Detail $jdk -RecoveryData @{ PriorJavaHome=$priorJava; PriorMachinePath=$priorPath; NewJavaHome=$jdk })
}

function Invoke-WhinsetOperationInternal {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Operation, [Parameter(Mandatory)]$Paths)
    if ($Operation.Privilege -eq 'user' -or ($Operation.Kind -eq 'package' -and $Operation.Scope -ne 'machine')) {
        Assert-WhinsetSameUser -OriginalUserSid $State.OriginalUserSid -CurrentUserSid ([string](Get-WhinsetMachineIdentity).UserSid)
    }
    switch ([string]$Operation.Kind) {
        'package' { return (Invoke-WhinsetPackageOperation -Plan $Plan -State $State -Operation $Operation -Paths $Paths) }
        'wsl-features' { return (Invoke-WhinsetWslFeaturesOperation) }
        'wsl-distribution' { return (Invoke-WhinsetWslDistributionOperation) }
        'docker-user' { return (Invoke-WhinsetDockerUserOperation -Plan $Plan) }
        'wsl-runtime' { return (Invoke-WhinsetWslRuntimeOperation) }
        'docker' { return (Invoke-WhinsetDockerOperation -Plan $Plan -State $State -Operation $Operation -Paths $Paths) }
        'config-git-lfs' { return (Invoke-WhinsetGitLfsOperation) }
        'config-uv' { return (Invoke-WhinsetUvOperation) }
        'config-conda' { return (Invoke-WhinsetCondaOperation -Plan $Plan) }
        'config-go' { return (Invoke-WhinsetGoOperation) }
        'config-rust' { return (Invoke-WhinsetRustOperation) }
        'config-java-home' { return (Invoke-WhinsetJavaHomeOperation) }
        default { return (New-WhinsetOperationResult -Status 'Failed' -Error "Unsupported operation kind: $($Operation.Kind)") }
    }
}

function Test-WhinsetOperationTerminalSuccess {
    param([Parameter(Mandatory)][string]$Status)
    return ($Status -in @('Succeeded','AlreadyInstalled','Skipped','Warning'))
}

function Invoke-WhinsetOperationGraph {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][ValidateSet('user','elevated')][string]$Privilege
    )
    $stopAll = $false
    foreach ($operationId in @($Plan.Order)) {
        if ($stopAll) { break }
        $operation = @($Plan.Operations | Where-Object { $_.Id -eq $operationId })[0]
        if ($null -eq $operation -or $operation.Privilege -ne $Privilege) { continue }
        $record = Get-WhinsetOperationRecord -State $State -OperationId $operation.Id
        if (Test-WhinsetOperationTerminalSuccess -Status $record.Status) { continue }
        $crossPrivilegePending = $false
        $dependencyFailed = $false
        foreach ($dependencyId in @($operation.DependsOn)) {
            $dependencyRecord = Get-WhinsetOperationRecord -State $State -OperationId $dependencyId
            $dependencyOperation = @($Plan.Operations | Where-Object { $_.Id -eq $dependencyId })[0]
            if ($null -eq $dependencyRecord) { $dependencyFailed = $true; break }
            if (Test-WhinsetOperationTerminalSuccess -Status $dependencyRecord.Status) { continue }
            if ($dependencyOperation -and $dependencyOperation.Privilege -ne $Privilege) { $crossPrivilegePending = $true; break }
            if ($dependencyRecord.Status -in @('Failed','Blocked','AwaitingReboot')) { $dependencyFailed = $true; break }
        }
        if ($crossPrivilegePending) { continue }
        if ($dependencyFailed) {
            Set-WhinsetOperationRecord -State $State -OperationId $operation.Id -Status 'Blocked' -Error 'A dependency did not complete successfully.'
            Save-WhinsetRunState -State $State -Paths $Paths
            continue
        }
        Set-WhinsetOperationRecord -State $State -OperationId $operation.Id -Status 'Running' -Detail 'Operation started.' -IncrementAttempt
        Save-WhinsetRunState -State $State -Paths $Paths
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'operation.start' -Data @{ OperationId=$operation.Id; Kind=$operation.Kind; Privilege=$Privilege }
        try {
            $result = Invoke-WhinsetOperationInternal -Plan $Plan -State $State -Operation $operation -Paths $Paths
            if ($null -eq $result) { $result = New-WhinsetOperationResult -Status 'Failed' -Error 'Operation returned no result.' }
        } catch {
            $result = New-WhinsetOperationResult -Status 'Failed' -Error $_.Exception.Message
        }
        Set-WhinsetOperationRecord -State $State -OperationId $operation.Id -Status $result.Status -Detail $result.Detail -Error $result.Error -ExitCode $result.ExitCode -RecoveryData $result.RecoveryData -RebootRequired:$result.RebootRequired
        Save-WhinsetRunState -State $State -Paths $Paths
        Write-WhinsetRunEvent -RunDirectory $Paths.RunDirectory -Type 'operation.end' -Data @{ OperationId=$operation.Id; Status=$result.Status; ExitCode=$result.ExitCode; RebootRequired=$result.RebootRequired; Error=$result.Error }
        if ($result.RebootRequired -or $result.Status -eq 'AwaitingReboot') { $State.RebootRequired = $true; Save-WhinsetRunState -State $State -Paths $Paths; break }
        if ($result.StopAll) { $stopAll = $true }
    }
    return [pscustomobject][ordered]@{ Privilege=$Privilege; StopAll=$stopAll; Summary=(Get-WhinsetStateSummary -State $State) }
}
