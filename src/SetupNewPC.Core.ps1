function ConvertTo-NativeArgument {
    param([AllowNull()][AllowEmptyString()][string]$Argument)
    # Windows CommandLineToArgvW/CRT quoting, including trailing backslashes.
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Normalize-NativeOutput {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "`0", '').Trim()
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 300,
        [string]$WorkingDirectory = ''
    )

    $resolvedPath = $FilePath
    if (-not [IO.Path]::IsPathRooted($resolvedPath)) {
        $command = Get-Command $FilePath -ErrorAction SilentlyContinue
        if (-not $command) {
            throw "Executable not found: $FilePath"
        }
        $resolvedPath = $command.Source
    }
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "Executable not found: $resolvedPath"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $resolvedPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ([IO.Path]::GetFileName($resolvedPath) -ieq 'wsl.exe') {
        $startInfo.StandardOutputEncoding = [Text.Encoding]::Unicode
        $startInfo.StandardErrorEncoding = [Text.Encoding]::Unicode
    }
    $startInfo.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-NativeArgument -Argument $_ }) -join ' ')
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedAt = Get-Date
    $exitCode = -1
    $timedOut = $false

    try {
        if (-not $process.Start()) {
            throw "Failed to start: $resolvedPath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try {
                $killer = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -ArgumentList @('/PID', $process.Id, '/T', '/F') -WindowStyle Hidden -PassThru
                if (-not $killer.WaitForExit(10000)) { $killer.Kill() }
                $killer.Dispose()
            } catch { try { $process.Kill() } catch { } }
            $null = $process.WaitForExit(5000)
        }

        $stdout = ''; $stderr = ''
        if ($stdoutTask.Wait(5000)) { $stdout = Normalize-NativeOutput -Text $stdoutTask.Result }
        else { $timedOut = $true; $stderr = 'Output pipe did not close.' }
        if ($stderrTask.Wait(5000)) { $stderr += Normalize-NativeOutput -Text $stderrTask.Result }
        else { $timedOut = $true }
        if (-not $timedOut) {
            $exitCode = $process.ExitCode
        }
    } finally {
        $process.Dispose()
    }

    return [pscustomobject]@{
        FilePath  = $resolvedPath
        Arguments = $startInfo.Arguments
        ExitCode  = $exitCode
        Output    = $stdout
        Error     = $stderr
        TimedOut  = $timedOut
        Success   = (-not $timedOut -and $exitCode -eq 0)
        DurationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
    }
}


function Get-SelectedGroups {
    $groups = @('Core')
    switch ($Profile) {
        'Minimal' { }
        'Developer' { $groups += 'Developer' }
        'AI' { $groups += @('Developer', 'AI') }
        'Engineering' { $groups += @('Developer', 'Engineering') }
        'Full' { $groups += @('Developer', 'AI', 'Engineering', 'Personal') }
    }
    if ($IncludePersonal) { $groups += 'Personal' }
    if ($ExtraGroups.Count -gt 0) { $groups += $ExtraGroups }
    return @($groups | Where-Object { $_ } | Select-Object -Unique)
}


function Get-SoftwareCatalog { return $script:Catalog }

function Test-ItemInSelectedGroups {
    param([Parameter(Mandatory)]$Item)
    $selected = Get-SelectedGroups
    foreach ($group in @($Item.Groups)) {
        if ($selected -contains $group) { return $true }
    }
    return $false
}

function Get-SoftwareForStage {
    param([Parameter(Mandatory)][string]$StageName)
    return @($script:SelectedPackages | Where-Object { $_.Stage -eq $StageName })
}

function Get-ItemResult {
    param([Parameter(Mandatory)][string]$Key)
    if ($script:ItemResults.Contains($Key)) {
        return $script:ItemResults[$Key]
    }
    return $null
}

function Save-ProgressState {
    Save-SetupState -Status $script:CurrentStatus -Detail $script:CurrentDetail -LastCompletedStage $script:LastCompletedStage
}

function Set-ItemResult {
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Name = '',
        [string]$Id = '',
        [string]$Stage = '',
        [string]$Category = '',
        [Parameter(Mandatory)][string]$Status,
        [string]$Error = '',
        [string]$Version = '',
        [switch]$IncrementAttempt,
        [switch]$Persist
    )

    $record = Get-ItemResult -Key $Key
    if (-not $record) {
        $recordName = $Key
        if ($Name) { $recordName = $Name }
        $record = [pscustomobject][ordered]@{
            Name          = $recordName
            Id            = $Id
            Stage         = $Stage
            Category      = $Category
            Status        = 'Pending'
            Error         = ''
            Attempts      = 0
            LastAttemptAt = $null
            LastSuccessAt = $null
            Version       = ''
        }
    }

    if ($Name) { $record.Name = $Name }
    if ($Id) { $record.Id = $Id }
    if ($Stage) { $record.Stage = $Stage }
    if ($Category) { $record.Category = $Category }
    $record.Status = $Status
    if ($PSBoundParameters.ContainsKey('Error')) { $record.Error = $Error }
    if ($PSBoundParameters.ContainsKey('Version')) { $record.Version = $Version }

    if ($IncrementAttempt) {
        $record.Attempts = [int]$record.Attempts + 1
        $record.LastAttemptAt = (Get-Date).ToString('o')
    }
    if ($Status -eq 'Succeeded') {
        $record.LastSuccessAt = (Get-Date).ToString('o')
        $record.Error = ''
        $script:Failures = @($script:Failures | Where-Object { $_ -ne $record.Name })
    } elseif ($Status -eq 'Failed') {
        if ($script:Failures -notcontains $record.Name) {
            $script:Failures += $record.Name
        }
    } elseif ($Status -in @('Skipped', 'AwaitingReboot', 'Warning')) {
        $script:Failures = @($script:Failures | Where-Object { $_ -ne $record.Name })
    }

    $script:ItemResults[$Key] = $record
    if ($Persist) {
        Save-ProgressState
    }
}


function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Add-EnvironmentPathEntry {
    param(
        [Parameter(Mandatory)][string]$PathEntry,
        [ValidateSet('Machine', 'User')][string]$Scope = 'Machine'
    )

    $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    $entries = @($current -split ';' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().TrimEnd('\') })
    $normalized = $PathEntry.Trim().TrimEnd('\')
    if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $normalized })) {
        $entries += $normalized
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), $Scope)
    }
    Update-SessionPath
}

function Get-BootId {
    if (-not (Get-Variable -Name CachedBootId -Scope Script -ErrorAction SilentlyContinue)) {
        $script:CachedBootId = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc().ToString()
    }
    return $script:CachedBootId
}

function Get-SetupState {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    try {
        $state = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.Version -ne $script:StateVersion -or $state.ConfigurationHash -ne $script:ConfigurationHash -or $state.MachineIdentity -ne $script:MachineIdentity) {
            throw 'State belongs to a different schema, configuration, machine or Windows user.'
        }
        return $state
    } catch { throw "Cannot load state. Preserve it for diagnosis and use another -StateDirectory: $($_.Exception.Message)" }
}

function Get-ItemSummary {
    $summary = [ordered]@{
        Pending   = 0
        Running   = 0
        Succeeded = 0
        Failed    = 0
        Skipped   = 0
        Warning   = 0
        AwaitingReboot = 0
    }
    foreach ($record in $script:ItemResults.Values) {
        if ($summary.Contains($record.Status)) {
            $summary[$record.Status] = [int]$summary[$record.Status] + 1
        }
    }
    return [pscustomobject]$summary
}

function Initialize-RunState {
    $state = Get-SetupState
    if (-not $state) {
        return
    }

    $itemsProperty = $state.PSObject.Properties['Items']
    if ($itemsProperty -and $itemsProperty.Value) {
        foreach ($property in $itemsProperty.Value.PSObject.Properties) {
            $loaded = $property.Value
            $name = $property.Name
            if ($loaded.PSObject.Properties['Name']) { $name = [string]$loaded.Name }
            $record = [pscustomobject][ordered]@{
                Name          = $name
                Id            = [string]$loaded.Id
                Stage         = [string]$loaded.Stage
                Category      = [string]$loaded.Category
                Status        = [string]$loaded.Status
                Error         = [string]$loaded.Error
                Attempts      = [int]$loaded.Attempts
                LastAttemptAt = $loaded.LastAttemptAt
                LastSuccessAt = $loaded.LastSuccessAt
                Version       = [string]$loaded.Version
            }
            $script:ItemResults[$property.Name] = $record
            # Keep attempt history; current-run failures are collected only when rechecked.
        }
    }

    $lastStageProperty = $state.PSObject.Properties['LastCompletedStage']
    if ($lastStageProperty -and $lastStageProperty.Value) {
        $script:LastCompletedStage = [string]$lastStageProperty.Value
    }
}

function Save-SetupState {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = '',
        [string]$LastCompletedStage = ''
    )

    $script:CurrentStatus = $Status
    $script:CurrentDetail = $Detail
    if ($LastCompletedStage) {
        $script:LastCompletedStage = $LastCompletedStage
    }

    $state = [ordered]@{
        Version            = $script:StateVersion
        ConfigurationHash  = $script:ConfigurationHash
        MachineIdentity    = $script:MachineIdentity
        Status             = $Status
        Detail             = $Detail
        Profile            = $Profile
        Groups             = @(Get-SelectedGroups)
        Stage              = $Stage
        LastCompletedStage = $script:LastCompletedStage
        BootId             = Get-BootId
        UpdatedAt          = (Get-Date).ToString('o')
        ScriptPath         = $PSCommandPath
        Summary            = Get-ItemSummary
        Items              = $script:ItemResults
    }

    $tempStateFile = "$script:StateFile.tmp"
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tempStateFile -Encoding UTF8
    if (Test-Path -LiteralPath $script:StateFile) {
        [IO.File]::Replace($tempStateFile, $script:StateFile, "$script:StateFile.bak")
    } else { [IO.File]::Move($tempStateFile, $script:StateFile) }
}

function Get-PendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Component Based Servicing')
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update')
    }

    $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sessionManager -and $sessionManager.PSObject.Properties['PendingFileRenameOperations'] -and $sessionManager.PendingFileRenameOperations) {
        $reasons.Add('Pending file rename')
    }

    if ($script:InstallerRebootRequired) { $reasons.Add('Installer or Windows feature requested restart') }
    foreach ($name in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
        if (-not $SkipWSL -and (Get-WindowsFeatureState -Name $name) -in @('EnablePending','DisablePending')) { $reasons.Add("$name pending") }
    }
    return $reasons.ToArray()
}

function Get-WindowsFeatureState {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        return [string]$feature.State
    } catch {
        return 'Unknown'
    }
}

function Get-WslStatusText {
    try {
        $result = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--status') -TimeoutSeconds 20
        return $result.Output
    } catch {
        return ''
    }
}

function Get-WslDistroReport {
    $result = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--list', '--verbose') -TimeoutSeconds 30
    if (-not $result.Success) {
        return [pscustomobject]@{ Success = $false; Distros = @(); Output = $result.Output; Error = $result.Error }
    }

    $distros = @()
    foreach ($line in @($result.Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^NAME\s+STATE\s+VERSION') { continue }
        $isDefault = $trimmed.StartsWith('*')
        $clean = $trimmed.TrimStart('*').Trim()
        $parts = @($clean -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 3) { continue }
        $name = $parts[0]
        $state = $parts[$parts.Count - 2]
        $versionText = $parts[$parts.Count - 1]
        $versionNumber = 0
        [void][int]::TryParse($versionText, [ref]$versionNumber)
        $distros += [pscustomobject]@{
            Name        = $name
            State       = $state
            Version     = $versionNumber
            VersionText = $versionText
            IsDefault   = $isDefault
        }
    }

    return [pscustomobject]@{ Success = $true; Distros = $distros; Output = $result.Output; Error = $result.Error }
}

function Test-WslReady {
    $result = [ordered]@{
        Ready          = $false
        VersionOk      = $false
        StatusOk       = $false
        ListOk         = $false
        UbuntuPresent  = $false
        UbuntuName     = ''
        UbuntuVersion  = 0
        VersionText    = ''
        StatusText     = ''
        DistroText     = ''
        Error          = ''
    }

    try {
        $versionResult = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--version') -TimeoutSeconds 20
        $statusResult = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--status') -TimeoutSeconds 20
        $distroResult = Get-WslDistroReport

        $result.VersionText = $versionResult.Output
        $result.StatusText = $statusResult.Output
        $result.DistroText = $distroResult.Output
        $result.VersionOk = $versionResult.Success -and $versionResult.Output.Length -gt 0 -and ($versionResult.Output -match '(?i)WSL|Windows Subsystem')
        $result.StatusOk = $statusResult.Success -and $statusResult.Output.Length -gt 0
        $result.ListOk = $distroResult.Success

        $ubuntu = @($distroResult.Distros | Where-Object { $_.Name -match '^Ubuntu' } | Select-Object -First 1)
        if ($ubuntu.Count -gt 0) {
            $result.UbuntuPresent = $true
            $result.UbuntuName = $ubuntu[0].Name
            $result.UbuntuVersion = [int]$ubuntu[0].Version
        }

        $result.Ready = $result.VersionOk -and $result.StatusOk -and $result.ListOk -and $result.UbuntuPresent -and $result.UbuntuVersion -eq 2
        if (-not $result.Ready) {
            $result.Error = 'WSL version/status/list/Ubuntu/WSL2 validation did not all pass.'
        }
    } catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-VirtualizationReport {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $featureNames = @(
        'VirtualMachinePlatform',
        'Microsoft-Windows-Subsystem-Linux',
        'Microsoft-Hyper-V-All',
        'Containers'
    )
    $features = [ordered]@{}
    foreach ($featureName in $featureNames) {
        $features[$featureName] = Get-WindowsFeatureState -Name $featureName
    }

    $firmwareVirtualization = $null
    $vmExtensions = $null
    $slat = $null
    if ($cpu) {
        if ($null -ne $cpu.VirtualizationFirmwareEnabled) {
            $firmwareVirtualization = [bool]$cpu.VirtualizationFirmwareEnabled
        }
        if ($null -ne $cpu.VMMonitorModeExtensions) {
            $vmExtensions = [bool]$cpu.VMMonitorModeExtensions
        }
        if ($null -ne $cpu.SecondLevelAddressTranslationExtensions) {
            $slat = [bool]$cpu.SecondLevelAddressTranslationExtensions
        }
    }

    $wslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
    $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem
    $hypervisorPresent = $null
    if ($computer) {
        $hypervisorPresent = [bool]$computer.HypervisorPresent
    }
    $wslExecutable = $null
    if ($wslCommand) {
        $wslExecutable = $wslCommand.Source
    }
    $dockerExecutable = $null
    if ($dockerCommand) {
        $dockerExecutable = $dockerCommand.Source
    }
    $dockerServiceStatus = $null
    if ($dockerService) {
        $dockerServiceStatus = [string]$dockerService.Status
    }

    $report = [ordered]@{
        Timestamp                     = (Get-Date).ToString('o')
        ComputerName                  = $env:COMPUTERNAME
        WindowsBuild                  = [string]$os.BuildNumber
        HypervisorPresent             = $hypervisorPresent
        VirtualizationFirmwareEnabled = $firmwareVirtualization
        VMMonitorModeExtensions       = $vmExtensions
        SecondLevelAddressTranslation = $slat
        Features                      = $features
        WslExecutable                 = $wslExecutable
        WslStatus                     = Get-WslStatusText
        DockerExecutable              = $dockerExecutable
        DockerServiceStatus           = $dockerServiceStatus
        PendingReboot                 = @(Get-PendingReboot)
    }

    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:VirtualizationReportFile -Encoding UTF8
    return [pscustomobject]$report
}

function Show-VirtualizationReport {
    param([Parameter(Mandatory)]$Report)

    $pendingText = '无'
    if (@($Report.PendingReboot).Count -gt 0) {
        $pendingText = @($Report.PendingReboot) -join ', '
    }
    Write-Host "  待重启原因: $pendingText"
    Write-Host "  HypervisorPresent: $($Report.HypervisorPresent)"
    Write-Host "  CPU 固件虚拟化: $($Report.VirtualizationFirmwareEnabled)"
    Write-Host "  VT-x/AMD-V 扩展: $($Report.VMMonitorModeExtensions)"
    Write-Host "  SLAT: $($Report.SecondLevelAddressTranslation)"
    Write-Host "  VirtualMachinePlatform: $($Report.Features.VirtualMachinePlatform)"
    Write-Host "  Microsoft-Windows-Subsystem-Linux: $($Report.Features.'Microsoft-Windows-Subsystem-Linux')"
    Write-Host "  Microsoft-Hyper-V-All: $($Report.Features.'Microsoft-Hyper-V-All')"
}

function Test-VirtualizationHardwareBlocker {
    param([Parameter(Mandatory)]$Report)

    if ($Report.HypervisorPresent -eq $true) {
        return $false
    }

    $firmwareDisabled = $Report.VirtualizationFirmwareEnabled -eq $false
    $extensionsDisabled = $Report.VMMonitorModeExtensions -eq $false
    return ($firmwareDisabled -or $extensionsDisabled -or ($Report.PSObject.Properties['SecondLevelAddressTranslation'] -and $Report.SecondLevelAddressTranslation -eq $false))
}

function Enable-WslPrerequisites {
    if ($SkipWSL) {
        Set-ItemResult -Key 'step:WSLPrerequisites' -Name 'WSL prerequisites' -Stage 'WindowsBase' -Category 'Platform' -Status 'Skipped' -Error '-SkipWSL' -Persist
        Write-Warning '已指定 -SkipWSL，跳过 WSL/VMP 功能启用与 Docker 依赖初始化。'
        return
    }

    Write-Host "`n检测虚拟化、VMP 与 Windows Subsystem for Linux..." -ForegroundColor Green
    $report = Get-VirtualizationReport
    Show-VirtualizationReport -Report $report

    if (Test-VirtualizationHardwareBlocker -Report $report) {
        Set-ItemResult -Key 'step:VirtualizationHardware' -Name 'CPU virtualization' -Stage 'WindowsBase' -Category 'Platform' -Status 'Failed' -Error 'CPU firmware virtualization, VT-x/AMD-V or SLAT is unavailable.' -IncrementAttempt -Persist
        Write-Warning 'CPU 虚拟化前置条件不可用，请检查 BIOS/UEFI 虚拟化开关及 CPU 支持。'
        return
    }
    Set-ItemResult -Key 'step:VirtualizationHardware' -Name 'CPU virtualization' -Stage 'WindowsBase' -Category 'Platform' -Status 'Succeeded' -Version "HypervisorPresent=$($report.HypervisorPresent)" -Persist

    $requiredFeatures = @(
        'VirtualMachinePlatform',
        'Microsoft-Windows-Subsystem-Linux'
    )

    foreach ($featureName in $requiredFeatures) {
        $itemKey = "feature:$featureName"
        $state = Get-WindowsFeatureState -Name $featureName
        if ($state -in @('Enabled', 'EnablePending')) {
            Set-ItemResult -Key $itemKey -Name $featureName -Stage 'WindowsBase' -Category 'Platform' -Status 'Succeeded' -Version $state -Persist
            Write-Host "  $featureName 已启用或等待重启。" -ForegroundColor DarkGray
            continue
        }

        Write-Host "  启用 $featureName ..." -ForegroundColor Cyan
        try {
            $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -ErrorAction Stop
            if ($enableResult.RestartNeeded) { $script:InstallerRebootRequired = $true }
            $newState = Get-WindowsFeatureState -Name $featureName
            Set-ItemResult -Key $itemKey -Name $featureName -Stage 'WindowsBase' -Category 'Platform' -Status 'Succeeded' -Version "$newState;RestartNeeded=$($enableResult.RestartNeeded)" -IncrementAttempt -Persist
        } catch {
            Set-ItemResult -Key $itemKey -Name $featureName -Stage 'WindowsBase' -Category 'Platform' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
            Write-Warning "启用 $featureName 失败：$($_.Exception.Message)"
        }
    }

    Get-VirtualizationReport | Out-Null
}

function Test-WingetInstalled {
    param([Parameter(Mandatory)][string]$Id, [string]$Source = 'winget', [string[]]$ExtraArgs = @())
    $listArgs = @()
    $scopeIndex = [array]::IndexOf($ExtraArgs, '--scope')
    if ($scopeIndex -ge 0) { $listArgs = @('--scope', $ExtraArgs[$scopeIndex + 1]) }
    $result = Invoke-ExternalCommand -FilePath 'winget.exe' -ArgumentList (@(
        'list', '--id', $Id, '--exact', '--source', $Source,
        '--accept-source-agreements', '--disable-interactivity'
    ) + $listArgs) -TimeoutSeconds 120
    # Exact filtering + HRESULT avoids parsing localized/truncated table output.
    if ($result.Success) {
        $versionIndex = [array]::IndexOf($ExtraArgs, '--version')
        if ($versionIndex -lt 0) { return $true }
        $inventoryPath = Join-Path $script:StateDir (('inventory-{0}.json' -f [guid]::NewGuid()))
        try {
            $export = Invoke-ExternalCommand -FilePath 'winget.exe' -ArgumentList @('export', '--output', $inventoryPath, '--include-versions', '--source', $Source, '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds 120
            if (-not $export.Success) { throw "Cannot verify pinned version: winget export exit $($export.ExitCode)" }
            $inventory = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in $inventory.Sources) {
                foreach ($package in $entry.Packages) {
                    if ($package.PackageIdentifier -eq $Id -and $package.PSObject.Properties['Version'] -and $package.Version -eq $ExtraArgs[$versionIndex + 1]) { return $true }
                }
            }
            return $false
        } finally { if (Test-Path -LiteralPath $inventoryPath) { Remove-Item -LiteralPath $inventoryPath -Force } }
    }
    if (-not $result.TimedOut -and $result.ExitCode -eq -1978335212) { return $false }
    throw "WinGet inventory failed for $Id (exit $($result.ExitCode)): $($result.Error) $($result.Output)"
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory)][string]$Id, [string]$Name = '', [string]$Source = 'winget',
        [string[]]$ExtraArgs = @(), [string]$Stage = 'Development', [string]$Category = 'Software'
    )
    if (-not $Name) { $Name = $Id }
    $key = "winget:$Id"
    $lastError = ''
    $confirmed = -not $ConfirmEach
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if (Test-WingetInstalled -Id $Id -Source $Source -ExtraArgs $ExtraArgs) {
                Set-ItemResult -Key $key -Name $Name -Id $Id -Stage $Stage -Category $Category -Status 'Succeeded' -Version 'Already installed (verified)' -Persist
                return $true
            }
            # Never upgrade/downgrade an existing package to meet a pinned version.
            if ($ExtraArgs -contains '--version' -and (Test-WingetInstalled -Id $Id -Source $Source)) {
                throw 'Installed version/scope differs from configuration. Resolve the conflict manually; no upgrade or downgrade was performed.'
            }
            if (-not $confirmed) {
                $answer = Read-Host "Install $Name [$Source/$Id]? Enter Y to accept this package and install"
                if ($answer -cnotmatch '^[Yy]$') {
                    $script:UserSkipped = $true
                    Set-ItemResult -Key $key -Name $Name -Id $Id -Stage $Stage -Category $Category -Status 'Skipped' -Error 'User declined' -Persist
                    return $false
                }
                $confirmed = $true
            }
            Set-ItemResult -Key $key -Name $Name -Id $Id -Stage $Stage -Category $Category -Status 'Running' -IncrementAttempt -Persist
            Write-Host "Installing $Name ($attempt/$MaxAttempts)..." -ForegroundColor Cyan
            $result = Invoke-ExternalCommand -FilePath 'winget.exe' -ArgumentList (@(
                'install', '--id', $Id, '--exact', '--source', $Source,
                '--accept-source-agreements', '--accept-package-agreements', '--silent',
                '--disable-interactivity', '--no-upgrade'
            ) + $ExtraArgs) -TimeoutSeconds $InstallTimeoutSeconds
            $combined = "$($result.Output)`n$($result.Error)".Trim()
            # Store full output in transcript; keep bounded state detail.
            Write-Host $combined
            if (-not $result.TimedOut -and $result.ExitCode -in @(3010, 1641, -1978334967, -1978334966, -1978334965)) {
                $script:InstallerRebootRequired = $true
                Set-ItemResult -Key $key -Name $Name -Id $Id -Stage $Stage -Category $Category -Status 'AwaitingReboot' -Error "ExitCode=$($result.ExitCode); rerun after reboot to verify" -Persist
                return $false
            }
            if ($result.TimedOut) {
                $script:StopInstallations = $true
                # Do not start a second installer while a child may still be shutting down.
                throw 'Installer timed out; inspect running installers and logs before retrying.'
            }
            if ($result.Success -or $result.ExitCode -in @(-1978335135, -1978335189)) {
                if (Test-WingetInstalled -Id $Id -Source $Source -ExtraArgs $ExtraArgs) {
                    Set-ItemResult -Key $key -Name $Name -Id $Id -Stage $Stage -Category $Category -Status 'Succeeded' -Version 'Installed (verified)' -Persist
                    return $true
                }
                throw 'Installer exited but the requested package was not detected.'
            }
            throw "ExitCode=$($result.ExitCode); $combined"
        } catch {
            $lastError = $_.Exception.Message
            Write-Warning "${Name}: $lastError"
            if ($lastError -like '*timed out*' -or $lastError -like 'Installed version/scope*') { break }
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds ([Math]::Min(10, $attempt * 3)) }
    }
    if ($lastError.Length -gt 2000) { $lastError = $lastError.Substring(0, 2000) }
    Set-ItemResult -Key $key -Name $Name -Id $Id -Stage $Stage -Category $Category -Status 'Failed' -Error $lastError -Persist
    return $false
}

function Install-SoftwareForStage {
    param([Parameter(Mandatory)][string]$StageName)

    Write-Host "`n安装 $StageName 阶段软件..." -ForegroundColor Green
    foreach ($item in @(Get-SoftwareForStage -StageName $StageName)) {
        Invoke-Winget -Id $item.Id -Name $item.Name -Source $item.Source -Stage $item.Stage -Category $item.Category -ExtraArgs @(Get-PackageArguments -Item $item) | Out-Null
        Update-SessionPath
        if ($script:InstallerRebootRequired -or $script:StopInstallations) { break }
    }
}

function Invoke-WinUtilStandardPreset {
    if ($SkipWinUtil) { return }
    $key = 'step:WinUtilStandardPreset'
    $existing = Get-ItemResult -Key $key
    if ($existing -and $existing.Status -eq 'Succeeded') { return }
    try {
        if ((Get-FileHash -LiteralPath $WinUtilPath -Algorithm SHA256).Hash -ne $WinUtilSha256) { throw 'WinUtil SHA256 mismatch.' }
        Set-ItemResult -Key $key -Name 'WinUtil Standard preset' -Stage 'WindowsBase' -Category 'System' -Status 'Running' -IncrementAttempt -Persist
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $result = Invoke-ExternalCommand -FilePath $shell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WinUtilPath, '-Preset', 'Standard') -TimeoutSeconds $InstallTimeoutSeconds
        if ($result.TimedOut) { $script:StopInstallations = $true }
        if (-not $result.Success) { throw "WinUtil failed: $($result.ExitCode) $($result.Error) $($result.Output)" }
        Set-ItemResult -Key $key -Name 'WinUtil Standard preset' -Stage 'WindowsBase' -Category 'System' -Status 'Succeeded' -Version $WinUtilSha256 -Persist
    } catch { Set-ItemResult -Key $key -Name 'WinUtil Standard preset' -Stage 'WindowsBase' -Category 'System' -Status 'Failed' -Error $_.Exception.Message -Persist }
}

function Install-WindowsBase {
    Write-Host "`n========== [1/3] Windows 基础 ==========" -ForegroundColor Magenta

    Invoke-WinUtilStandardPreset
    if ($script:StopInstallations) { return }

    foreach ($item in @(Get-SoftwareForStage -StageName 'WindowsBase')) {
        Invoke-Winget -Id $item.Id -Name $item.Name -Source $item.Source -Stage $item.Stage -Category $item.Category -ExtraArgs @(Get-PackageArguments -Item $item) | Out-Null
        Update-SessionPath
        if ($script:InstallerRebootRequired -or $script:StopInstallations) { return }
    }

    if ($SkipWSL) {
        Set-ItemResult -Key 'step:WSLPrerequisites' -Name 'WSL prerequisites' -Stage 'WindowsBase' -Category 'Platform' -Status 'Skipped' -Error '-SkipWSL' -Persist
    } else {
        Enable-WslPrerequisites
    }

    Update-SessionPath
}



function Request-NextReboot {
    Write-Host 'Restart required. Save your work, restart Windows, then rerun the same command.' -ForegroundColor Yellow
}

function Resolve-SetupStage {
    $state = Get-SetupState
    if ($state -and $state.Status -eq 'AwaitingReboot' -and [string]$state.BootId -eq (Get-BootId)) { return 'AwaitingReboot' }
    if ($Stage -ne 'Auto') { return $Stage }
    # Always reconcile base packages too: a failed install before reboot must not be lost.
    return 'WindowsBase'
}

function Test-DockerReady {
    $report = [ordered]@{
        Ready            = $false
        DockerExecutable = $false
        DockerPath       = ''
        ServicePresent   = $false
        ServiceStatus    = 'NotPresent'
        ServerVersion    = ''
        InfoOutput       = ''
        Error            = ''
    }

    try {
        $dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
        $dockerPath = ''
        if ($dockerCommand) {
            $dockerPath = $dockerCommand.Source
        } else {
            $knownDocker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
            if (Test-Path -LiteralPath $knownDocker) { $dockerPath = $knownDocker }
        }
        if ($dockerPath) {
            $report.DockerExecutable = $true
            $report.DockerPath = $dockerPath
        }
        $service = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
        if ($service) {
            $report.ServicePresent = $true
            $report.ServiceStatus = [string]$service.Status
        }
        if ($report.DockerExecutable) {
            $infoResult = Invoke-ExternalCommand -FilePath $dockerPath -ArgumentList @('info', '--format', '{{.ServerVersion}}') -TimeoutSeconds 30
            $report.InfoOutput = $infoResult.Output
            if ($infoResult.Success -and $infoResult.Output) {
                $report.ServerVersion = $infoResult.Output
            } else {
                $report.Error = "docker info failed: $($infoResult.Error) $($infoResult.Output)"
            }
        } else {
            $report.Error = 'docker.exe not found.'
        }
        $report.Ready = $report.DockerExecutable -and [bool]$report.ServerVersion
    } catch {
        $report.Error = $_.Exception.Message
    }
    return [pscustomobject]$report
}

function Initialize-WslEnvironment {
    if ($SkipWSL) {
        Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error '-SkipWSL' -Persist
        return $false
    }

    $existingValidation = Get-ItemResult -Key 'step:WSL2Validation'
    if ($existingValidation -and $existingValidation.Status -eq 'Succeeded' -and @($script:ItemResults.Values | Where-Object { $_.Category -eq 'Platform' -and $_.Status -eq 'Failed' }).Count -eq 0) {
        $cachedValidation = Test-WslReady
        if ($cachedValidation.Ready) {
            Write-Host 'WSL2 验证仍然通过，跳过重复更新。' -ForegroundColor DarkGray
            return $true
        }
    }

    Write-Host "`n深化检查 WSL、VMP、Linux 子系统与 Docker 前置条件..." -ForegroundColor Green
    $report = Get-VirtualizationReport
    Show-VirtualizationReport -Report $report

    $featureReady = (
        $report.Features.VirtualMachinePlatform -eq 'Enabled' -and
        $report.Features.'Microsoft-Windows-Subsystem-Linux' -eq 'Enabled'
    )
    if (Test-VirtualizationHardwareBlocker -Report $report) {
        Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error 'CPU virtualization unavailable.' -Persist
        Write-Warning 'CPU 虚拟化不可用，跳过 WSL 和 Docker Desktop。'
        return $false
    }
    if (-not $featureReady) {
        Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error 'VirtualMachinePlatform or WSL feature is not Enabled.' -Persist
        Write-Warning 'VirtualMachinePlatform 或 WSL 功能尚未生效，请重启后再次运行 Development 阶段。'
        return $false
    }
    if (@($report.PendingReboot).Count -gt 0) {
        Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error ("Pending reboot: " + (@($report.PendingReboot) -join ', ')) -Persist
        Write-Warning "仍存在待重启原因：$(@($report.PendingReboot) -join ', ')。请重启后再运行 Development 阶段。"
        return $false
    }

    try {
        Write-Host '更新 WSL 内核...' -ForegroundColor Cyan
        $updateResult = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--update') -TimeoutSeconds 900
        if (-not $updateResult.TimedOut -and $updateResult.ExitCode -eq 3010) {
            $script:InstallerRebootRequired = $true
            return $false
        }
        if (-not $updateResult.Success) {
            Set-ItemResult -Key 'step:WSLUpdate' -Name 'WSL update' -Stage 'Development' -Category 'Platform' -Status 'Warning' -Error "$($updateResult.Error) $($updateResult.Output)" -IncrementAttempt -Persist
        } else {
            Set-ItemResult -Key 'step:WSLUpdate' -Name 'WSL update' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Persist
        }

        $defaultResult = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--set-default-version', '2') -TimeoutSeconds 60
        if (-not $defaultResult.Success) {
            Set-ItemResult -Key 'step:WSLDefaultVersion' -Name 'WSL default version' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error "$($defaultResult.Error) $($defaultResult.Output)" -IncrementAttempt -Persist
        } else {
            Set-ItemResult -Key 'step:WSLDefaultVersion' -Name 'WSL default version' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version '2' -Persist
        }

        $distroResult = Get-WslDistroReport
        $ubuntu = @($distroResult.Distros | Where-Object { $_.Name -match '^Ubuntu' } | Select-Object -First 1)
        if ($ubuntu.Count -eq 0) {
            Write-Host '安装 Ubuntu 发行版（不自动启动初始化）...' -ForegroundColor Cyan
            $installResult = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--install', '--distribution', 'Ubuntu', '--no-launch') -TimeoutSeconds 1800
            if (-not $installResult.TimedOut -and $installResult.ExitCode -eq 3010) {
                $script:InstallerRebootRequired = $true
                return $false
            }
            if (-not $installResult.Success) {
                Set-ItemResult -Key 'step:UbuntuWSL' -Name 'Ubuntu WSL distribution' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error "$($installResult.Error) $($installResult.Output)" -IncrementAttempt -Persist
            } else {
                Set-ItemResult -Key 'step:UbuntuWSL' -Name 'Ubuntu WSL distribution' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Persist
            }
        } else {
            Set-ItemResult -Key 'step:UbuntuWSL' -Name 'Ubuntu WSL distribution' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version $ubuntu[0].Name -Persist
        }

        $distroResult = Get-WslDistroReport
        $ubuntu = @($distroResult.Distros | Where-Object { $_.Name -match '^Ubuntu' } | Select-Object -First 1)
        if ($ubuntu.Count -gt 0 -and [int]$ubuntu[0].Version -ne 2) {
            $convertResult = Invoke-ExternalCommand -FilePath 'wsl.exe' -ArgumentList @('--set-version', $ubuntu[0].Name, '2') -TimeoutSeconds 1800
            if (-not $convertResult.TimedOut -and $convertResult.ExitCode -eq 3010) {
                $script:InstallerRebootRequired = $true
                return $false
            }
            if (-not $convertResult.Success) {
                Set-ItemResult -Key 'step:UbuntuWSL2' -Name 'Ubuntu WSL2 conversion' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error "$($convertResult.Error) $($convertResult.Output)" -IncrementAttempt -Persist
            } else {
                Set-ItemResult -Key 'step:UbuntuWSL2' -Name 'Ubuntu WSL2 conversion' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version '2' -Persist
            }
        }

        $validation = Test-WslReady
        if ($validation.Ready) {
            Set-ItemResult -Key 'step:UbuntuWSL2' -Name 'Ubuntu WSL2 conversion' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version '2 (verified)' -Persist
            Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version "$($validation.UbuntuName) v$($validation.UbuntuVersion)" -Persist
        } else {
            Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error $validation.Error -IncrementAttempt -Persist
        }

        $readiness = [ordered]@{
            Timestamp      = (Get-Date).ToString('o')
            Virtualization = $report
            Validation     = $validation
        }
        $readiness | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:DockerReadinessFile -Encoding UTF8
        return $validation.Ready
    } catch {
        Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "WSL 配置异常：$($_.Exception.Message)"
        return $false
    }
}
function Install-DockerDesktop {
    $installed = Invoke-Winget -Id 'Docker.DockerDesktop' -Name 'Docker Desktop' -Stage 'Development' -Category 'Platform'
    if (-not $installed) { return $false }
    Update-SessionPath
    $readiness = Test-DockerReady
    $readiness | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:DockerReadinessFile -Encoding UTF8
    if ($readiness.Ready) {
        Set-ItemResult -Key 'step:DockerValidation' -Name 'Docker runtime' -Status 'Succeeded' -Version $readiness.ServerVersion -Persist
    } else {
        Set-ItemResult -Key 'step:DockerValidation' -Name 'Docker runtime' -Status 'Warning' -Error 'Installed. Open Docker Desktop, accept its license and finish first-run setup; then rerun to verify.' -Persist
        Write-Warning 'Docker Desktop installed; open it and finish first-run setup to start the daemon.'
    }
    if ($DockerSmokeTest) {
        if (-not $readiness.Ready) {
            Set-ItemResult -Key 'step:DockerSmokeTest' -Name 'Docker smoke test' -Status 'Failed' -Error 'Docker daemon is not ready.' -Persist
        } else {
            $result = Invoke-ExternalCommand -FilePath $readiness.DockerPath -ArgumentList @('run', '--rm', 'hello-world') -TimeoutSeconds 300
            $status = 'Failed'; if ($result.Success) { $status = 'Succeeded' }
            Set-ItemResult -Key 'step:DockerSmokeTest' -Name 'Docker smoke test' -Status $status -Error "$($result.Error) $($result.Output)" -Persist
        }
    }
    return $true
}

function Find-CondaExecutable {
    $candidates = @()
    $condaCommand = Get-Command conda.exe -ErrorAction SilentlyContinue
    if ($condaCommand) { $candidates += $condaCommand.Source }
    $candidates += @(
        (Join-Path $env:USERPROFILE 'anaconda3\Scripts\conda.exe'),
        (Join-Path $env:USERPROFILE 'miniconda3\Scripts\conda.exe'),
        'C:\ProgramData\Anaconda3\Scripts\conda.exe',
        'C:\ProgramData\Miniconda3\Scripts\conda.exe'
    )
    return ($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

function Configure-UvEnvironment {
    if (-not (Test-PackageReady -Key 'uv')) {
        Set-ItemResult -Key 'step:uvStrategy' -Name 'uv strategy' -Stage 'Development' -Category 'Python' -Status 'Skipped' -Error 'Required package not selected or not successfully installed.' -Persist
        return
    }

    try {
        $uv = Get-Command uv.exe -ErrorAction SilentlyContinue
        if (-not $uv) { throw 'uv.exe not found.' }
        [Environment]::SetEnvironmentVariable('UV_PYTHON_PREFERENCE', 'system', 'User')
        $env:UV_PYTHON_PREFERENCE = 'system'
        Set-ItemResult -Key 'step:uvStrategy' -Name 'uv strategy' -Stage 'Development' -Category 'Python' -Status 'Succeeded' -Version "UV_PYTHON_PREFERENCE=system; $($uv.Source)" -Persist
        Write-Host 'uv 默认使用系统 Python；项目仍通过 .venv 隔离依赖。' -ForegroundColor Green
    } catch {
        Set-ItemResult -Key 'step:uvStrategy' -Name 'uv strategy' -Stage 'Development' -Category 'Python' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "配置 uv 失败：$($_.Exception.Message)"
    }
}

function Configure-CondaEnvironment {
    if (-not (Test-PackageReady -Key 'Anaconda')) {
        Set-ItemResult -Key 'step:CondaInit' -Name 'Conda initialization' -Stage 'Development' -Category 'Python' -Status 'Skipped' -Error 'Required package not selected or not successfully installed.' -Persist
        return
    }

    $conda = Find-CondaExecutable
    if (-not $conda) {
        Set-ItemResult -Key 'step:CondaInit' -Name 'Conda initialization' -Stage 'Development' -Category 'Python' -Status 'Failed' -Error 'conda.exe not found.' -IncrementAttempt -Persist
        Write-Warning '未找到 conda.exe，无法初始化科学计算环境。'
        return
    }

    try {
        if (-not $SkipCondaInit) {
            $initResult = Invoke-ExternalCommand -FilePath $conda -ArgumentList @('init', 'powershell') -TimeoutSeconds 300
            if (-not $initResult.Success) {
                throw "conda init failed: $($initResult.Error) $($initResult.Output)"
            }
        } else {
            Write-Host '按 -SkipCondaInit 跳过 PowerShell profile 修改。' -ForegroundColor DarkGray
        }

        $configResult = Invoke-ExternalCommand -FilePath $conda -ArgumentList @('config', '--set', 'auto_activate_base', 'false') -TimeoutSeconds 120
        if (-not $configResult.Success) {
            throw "conda config failed: $($configResult.Error) $($configResult.Output)"
        }
        $condaVersion = Invoke-ExternalCommand -FilePath $conda -ArgumentList @('--version') -TimeoutSeconds 60
        if (-not $condaVersion.Success) {
            throw "conda --version failed: $($condaVersion.Error) $($condaVersion.Output)"
        }

        $detail = "auto_activate_base=false; $($condaVersion.Output)"
        if ($SkipCondaInit) { $detail += '; profile init skipped' }
        Set-ItemResult -Key 'step:CondaInit' -Name 'Conda initialization' -Stage 'Development' -Category 'Python' -Status 'Succeeded' -Version $detail -Persist
        Write-Host 'conda 已配置；自动激活 base 已关闭。' -ForegroundColor Green
    } catch {
        Set-ItemResult -Key 'step:CondaInit' -Name 'Conda initialization' -Stage 'Development' -Category 'Python' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "conda 初始化失败：$($_.Exception.Message)"
    }
}

function Configure-PythonStrategy {
    Configure-UvEnvironment
    Configure-CondaEnvironment

    $policyLines = @(
        'Python strategy for this machine',
        '',
        '1. System Python (python.exe):',
        '   - Use for ordinary scripts, one-file tools, and uv project development.',
        '   - Do not use it as the place for a large global package collection.',
        '',
        '2. uv:',
        '   - UV_PYTHON_PREFERENCE=system, so uv starts from the installed system Python.',
        '   - Create project-local .venv and lock dependencies in pyproject.toml / uv.lock.',
        '   - Typical commands:',
        '       uv init',
        '       uv add <package>',
        '       uv run <script-or-command>',
        '',
        '3. conda:',
        '   - Use for scientific computing, CUDA/ML stacks, simulation, and project-specific environments.',
        '   - base auto-activation is disabled so python stays the system interpreter by default.',
        '   - Typical commands:',
        '       conda create -n science python=3.13',
        '       conda activate science',
        '       conda install <packages>'
    )
    Set-Content -LiteralPath $script:PythonPolicyFile -Value ($policyLines -join [Environment]::NewLine) -Encoding UTF8
}
function Configure-GitLfs {
    if (-not (Test-PackageReady -Key 'Git')) {
        Set-ItemResult -Key 'step:GitLFS' -Name 'Git LFS' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Required package not selected or not successfully installed.' -Persist
        return
    }

    $itemKey = 'step:GitLFS'
    try {
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        if (-not $git) { throw 'git.exe not found.' }
        $installResult = Invoke-ExternalCommand -FilePath $git.Source -ArgumentList @('lfs', 'install') -TimeoutSeconds 120
        $verifyResult = Invoke-ExternalCommand -FilePath $git.Source -ArgumentList @('lfs', 'version') -TimeoutSeconds 60
        if (-not $installResult.Success -or -not $verifyResult.Success) {
            throw "git lfs install/version failed: $($installResult.Error) $($verifyResult.Error)"
        }
        Set-ItemResult -Key $itemKey -Name 'Git LFS' -Stage 'Development' -Category 'Developer' -Status 'Succeeded' -Version $verifyResult.Output -IncrementAttempt -Persist
    } catch {
        Set-ItemResult -Key $itemKey -Name 'Git LFS' -Stage 'Development' -Category 'Developer' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "Git LFS 配置失败：$($_.Exception.Message)"
    }
}

function Get-JavaHome {
    $candidates = @()
    $jdkRoot = Join-Path $env:ProgramFiles 'Microsoft'
    $candidates += @(Get-ChildItem -Path (Join-Path $jdkRoot 'jdk-21*') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { $_.FullName })
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    foreach ($candidate in $candidates) {
        $release = Join-Path $candidate 'release'
        if ((Test-Path -LiteralPath $release) -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe'))) {
            if ((Get-Content -LiteralPath $release -Raw) -match '(?m)^JAVA_VERSION="21(?:[.\+"]|$)') { return $candidate }
        }
    }
    return $null
}

function Configure-JavaEnvironment {
    if (-not (Test-PackageReady -Key 'OpenJDK21')) {
        Set-ItemResult -Key 'step:JavaHome' -Name 'JAVA_HOME' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Required package not selected or not successfully installed.' -Persist
        return
    }

    $itemKey = 'step:JavaHome'
    try {
        $jdkHome = Get-JavaHome
        if (-not $jdkHome) { throw 'Unable to locate a Java home directory.' }
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdkHome, 'Machine')
        $env:JAVA_HOME = $jdkHome
        Add-EnvironmentPathEntry -PathEntry (Join-Path $jdkHome 'bin') -Scope Machine
        $result = Invoke-ExternalCommand -FilePath (Join-Path $jdkHome 'bin\java.exe') -ArgumentList @('-version') -TimeoutSeconds 30
        if (-not $result.Success) { throw "java -version failed: $($result.Error)" }
        $versionText = "$($result.Error) $($result.Output)".Trim()
        Set-ItemResult -Key $itemKey -Name 'JAVA_HOME' -Stage 'Development' -Category 'Developer' -Status 'Succeeded' -Version "$jdkHome; $versionText" -IncrementAttempt -Persist
    } catch {
        Set-ItemResult -Key $itemKey -Name 'JAVA_HOME' -Stage 'Development' -Category 'Developer' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "配置 JAVA_HOME 失败：$($_.Exception.Message)"
    }
}

function Configure-GoEnvironment {
    if (-not (Test-PackageReady -Key 'Go')) {
        Set-ItemResult -Key 'step:GoEnvironment' -Name 'Go environment' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Required package not selected or not successfully installed.' -Persist
        return
    }

    $itemKey = 'step:GoEnvironment'
    try {
        $go = Get-Command go.exe -ErrorAction SilentlyContinue
        if (-not $go) { throw 'go.exe not found.' }
        $result = Invoke-ExternalCommand -FilePath $go.Source -ArgumentList @('env', '-w', "GOPATH=$env:USERPROFILE\go") -TimeoutSeconds 60
        if (-not $result.Success) { throw "go env failed: $($result.Error) $($result.Output)" }
        $version = Invoke-ExternalCommand -FilePath $go.Source -ArgumentList @('version') -TimeoutSeconds 30
        if (-not $version.Success) { throw 'go version failed.' }
        Set-ItemResult -Key $itemKey -Name 'Go environment' -Stage 'Development' -Category 'Developer' -Status 'Succeeded' -Version $version.Output -Persist
    } catch {
        Set-ItemResult -Key $itemKey -Name 'Go environment' -Stage 'Development' -Category 'Developer' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "配置 Go 环境失败：$($_.Exception.Message)"
    }
}

function Configure-RustEnvironment {
    if (-not (Test-PackageReady -Key 'Rustup')) {
        Set-ItemResult -Key 'step:RustEnvironment' -Name 'Rust environment' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Required package not selected or not successfully installed.' -Persist
        return
    }

    $itemKey = 'step:RustEnvironment'
    try {
        $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
        Add-EnvironmentPathEntry -PathEntry $cargoBin -Scope User
        $rustup = Join-Path $cargoBin 'rustup.exe'
        if (-not (Test-Path -LiteralPath $rustup)) {
            $rustupCommand = Get-Command rustup.exe -ErrorAction SilentlyContinue
            if ($rustupCommand) { $rustup = $rustupCommand.Source }
        }
        if (-not (Test-Path -LiteralPath $rustup)) {
            $rustupInit = Get-Command rustup-init.exe -ErrorAction SilentlyContinue
            if ($rustupInit) {
                $initResult = Invoke-ExternalCommand -FilePath $rustupInit.Source -ArgumentList @('-y', '--no-modify-path') -TimeoutSeconds 1200
                if (-not $initResult.Success) { throw "rustup-init failed: $($initResult.Error) $($initResult.Output)" }
            }
        }
        if (-not (Test-Path -LiteralPath $rustup)) { throw 'rustup.exe not found after installation.' }
        $defaultResult = Invoke-ExternalCommand -FilePath $rustup -ArgumentList @('default', 'stable') -TimeoutSeconds 1200
        if (-not $defaultResult.Success) { throw "rustup default stable failed: $($defaultResult.Error) $($defaultResult.Output)" }
        $rustc = Invoke-ExternalCommand -FilePath (Join-Path $cargoBin 'rustc.exe') -ArgumentList @('--version') -TimeoutSeconds 30
        $cargo = Invoke-ExternalCommand -FilePath (Join-Path $cargoBin 'cargo.exe') -ArgumentList @('--version') -TimeoutSeconds 30
        if (-not $rustc.Success -or -not $cargo.Success) { throw 'rustc or cargo validation failed.' }
        Set-ItemResult -Key $itemKey -Name 'Rust environment' -Stage 'Development' -Category 'Developer' -Status 'Succeeded' -Version "$($rustc.Output); $($cargo.Output)" -Persist
    } catch {
        Set-ItemResult -Key $itemKey -Name 'Rust environment' -Stage 'Development' -Category 'Developer' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "配置 Rust 环境失败：$($_.Exception.Message)"
    }
}

function Install-DevelopmentEnvironment {
    Write-Host "`n========== [3/3] 开发环境 ==========" -ForegroundColor Magenta

    Install-SoftwareForStage -StageName 'Development'
    if ($script:InstallerRebootRequired -or $script:StopInstallations) { return }
    Update-SessionPath

    if ($ConfigureEnvironment) {
        Configure-GitLfs
        Configure-JavaEnvironment
        Configure-GoEnvironment
        Configure-RustEnvironment
        Configure-PythonStrategy
    }

    if ($SkipWSL) {
        Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error '-SkipWSL' -Persist
        Set-ItemResult -Key 'step:DockerDesktop' -Name 'Docker Desktop' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error '-SkipWSL' -Persist
        return
    }

    $wslReady = Initialize-WslEnvironment
    if ($SkipDocker) {
        Set-ItemResult -Key 'step:DockerDesktop' -Name 'Docker Desktop' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error '-SkipDocker' -Persist
    } elseif ($wslReady) {
        Install-DockerDesktop | Out-Null
    } else {
        Set-ItemResult -Key 'step:DockerDesktop' -Name 'Docker Desktop' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error 'WSL prerequisites are not ready.' -Persist
        Write-Warning 'WSL 前置条件未就绪，Docker Desktop 本轮跳过。'
    }
}

function Add-EnvironmentResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIPPED')][string]$Status,
        [string]$Version = '',
        [string]$Detail = '',
        [string]$Key = $Name
    )

    $script:EnvironmentResults += [pscustomobject]@{
        Name    = $Name
        Status  = $Status
        Version = $Version
        Detail  = $Detail
    }

    $itemStatus = 'Skipped'
    if ($Status -eq 'PASS') { $itemStatus = 'Succeeded' }
    if ($Status -eq 'FAIL') { $itemStatus = 'Failed' }
    Set-ItemResult -Key "check:$Key" -Name $Name -Stage 'EnvironmentCheck' -Category 'Check' -Status $itemStatus -Error $Detail -Version $Version -Persist
}

function Test-Environment {
    $script:EnvironmentResults = @()
    # Checks follow the selected packages, not a hard-coded profile wish list.
    foreach ($item in $script:SelectedPackages) {
        if ($Stage -ne 'Auto' -and $item.Stage -ne $Stage) { continue }
        $record = Get-ItemResult -Key "winget:$($item.Id)"
        $status = 'SKIPPED'; $detail = 'Not attempted in this stage.'
        if ($record) {
            $detail = "$($record.Version) $($record.Error)".Trim()
            if ($record.Status -eq 'Succeeded') { $status = 'PASS' }
            elseif ($record.Status -eq 'Failed') { $status = 'FAIL' }
        }
        Add-EnvironmentResult -Name $item.Name -Key $item.Id -Status $status -Detail $detail
    }
    $report = [ordered]@{ GeneratedAt=(Get-Date).ToString('o'); ConfigurationHash=$script:ConfigurationHash;
        Profile=$Profile; Results=$script:EnvironmentResults; Steps=$script:ItemResults }
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:EnvironmentReportFile -Encoding UTF8
    $script:EnvironmentResults | Format-Table Name,Status,Detail -AutoSize | Out-String -Width 240 |
        Set-Content -LiteralPath $script:EnvironmentReportTextFile -Encoding UTF8
}

function Get-FinalStatus {
    if (@($script:ItemResults.Values | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { return 'CompletedWithFailures' }
    if ($script:UserSkipped) { return 'Incomplete' }
    return 'Complete'
}

function Invoke-SetupPipeline {
    Write-Host "Profile=$Profile; Groups=$((Get-SelectedGroups) -join ',')" -ForegroundColor Cyan
    $resolvedStage = Resolve-SetupStage
    if ($resolvedStage -eq 'AwaitingReboot') { Request-NextReboot; return 'AwaitingReboot' }
    if ($resolvedStage -eq 'WindowsBase') {
        Save-SetupState -Status 'Running' -Detail 'Reconciling Windows base packages.'
        Install-WindowsBase
        if ($script:StopInstallations) {
            Test-Environment
            Save-SetupState -Status 'CompletedWithFailures' -Detail 'Installer timed out; no further installers started.'
            return 'CompletedWithFailures'
        }
        $script:LastCompletedStage = 'WindowsBase'
        if ($script:InstallerRebootRequired -or (-not $SkipWSL -and @(Get-PendingReboot).Count -gt 0)) {
            Save-SetupState -Status 'AwaitingReboot' -Detail 'Base stage requires reboot.'
            Test-Environment
            Request-NextReboot
            return 'AwaitingReboot'
        }
        if ($Stage -eq 'WindowsBase') {
            Test-Environment
            $status = Get-FinalStatus
            if ($status -eq 'Complete') { $status = 'WindowsBaseComplete' }
            Save-SetupState -Status $status -Detail 'Base stage finished.'
            return $status
        }
    }
    if (-not $SkipWSL -and @(Get-PendingReboot).Count -gt 0) {
        Save-SetupState -Status 'AwaitingReboot' -Detail 'Restart before WSL development stage.'
        Request-NextReboot
        return 'AwaitingReboot'
    }
    Save-SetupState -Status 'Running' -Detail 'Reconciling development packages.'
    Install-DevelopmentEnvironment
    Test-Environment
    if ($script:InstallerRebootRequired) {
        Save-SetupState -Status 'AwaitingReboot' -Detail 'Development installation requires reboot.'
        Request-NextReboot
        return 'AwaitingReboot'
    }
    $status = Get-FinalStatus
    Save-SetupState -Status $status -Detail 'Selected stages finished.' -LastCompletedStage 'Development'
    return $status
}
