function Invoke-WhinsetExternalCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 300,
        [string]$WorkingDirectory = ''
    )
    return Invoke-ExternalCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkingDirectory
}

function Get-WhinsetWingetVersion {
    try {
        $result = Invoke-WhinsetExternalCommand -FilePath 'winget.exe' -ArgumentList @('--version') -TimeoutSeconds 30
        $text = "$($result.Output) $($result.Error)".Trim()
        $version = $null
        if ($text -match 'v?(\d+\.\d+\.\d+)') { $version = $Matches[1] }
        return [pscustomobject][ordered]@{ Available = $result.Success; Version = $version; Output = $text; ExitCode = $result.ExitCode }
    } catch {
        return [pscustomobject][ordered]@{ Available = $false; Version = $null; Output = $_.Exception.Message; ExitCode = $null }
    }
}

function Get-WhinsetPendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { [void]$reasons.Add('Component Based Servicing') }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { [void]$reasons.Add('Windows Update') }
        $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
        if ($sessionManager -and $sessionManager.PSObject.Properties['PendingFileRenameOperations'] -and $sessionManager.PendingFileRenameOperations) { [void]$reasons.Add('Pending file rename') }
    } catch { }
    return @($reasons)
}

function Get-WhinsetEnvironmentSnapshot {
    $osCaption = $null
    $osVersion = $null
    $osBuild = 0
    $productType = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osCaption = [string]$os.Caption
        $osVersion = [string]$os.Version
        $osBuild = [int]$os.BuildNumber
        $productType = [int]$os.ProductType
    } catch { }
    $winget = Get-WhinsetWingetVersion
    $wingetVersionOk = $false
    if ($winget.Available -and $winget.Version) {
        try { $wingetVersionOk = ([version]$winget.Version -ge [version]'1.8.0') } catch { $wingetVersionOk = $false }
    }
    $platformIsWindows = ([Environment]::OSVersion.Platform -eq 'Win32NT')
    $blockers = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not $platformIsWindows) { [void]$blockers.Add('Whinset provisioning requires Windows.') }
    if ($platformIsWindows -and ($osBuild -lt 22000 -or $productType -ne 1)) { [void]$blockers.Add('Whinset provisioning requires Windows 11 client build 22000 or later.') }
    if (-not [Environment]::Is64BitProcess) { [void]$blockers.Add('Run a 64-bit PowerShell process.') }
    if (-not $winget.Available) { [void]$blockers.Add('winget.exe was not found. Install or update Microsoft App Installer.') }
    elseif (-not $wingetVersionOk) { [void]$blockers.Add("WinGet 1.8+ is required; detected $($winget.Version).") }
    $pending = @(Get-WhinsetPendingReboot)
    if ($pending.Count -gt 0) { [void]$warnings.Add('Windows already reports a pending restart: ' + ($pending -join ', ')) }
    $powerShellVersion = $PSVersionTable.PSVersion.ToString()
    if ($PSVersionTable.PSVersion.Major -lt 7) { [void]$warnings.Add('PowerShell 7 is recommended; compatibility mode is active for Windows PowerShell 5.1.') }
    $identity = Get-WhinsetMachineIdentity
    $architecture = Get-WhinsetHostArchitecture
    if ($architecture -eq 'x86') { [void]$blockers.Add('32-bit Windows is not supported.') }
    return [pscustomobject][ordered]@{
        Caption = $osCaption
        OsVersion = $osVersion
        BuildNumber = $osBuild
        ProductType = $productType
        IsWindows11 = ($osBuild -ge 22000 -and $productType -eq 1)
        PowerShellVersion = $powerShellVersion
        PowerShellEdition = [string]$PSVersionTable.PSEdition
        Is64BitProcess = [Environment]::Is64BitProcess
        Architecture = $architecture
        IsAdministrator = Test-WhinsetIsAdministrator
        ComputerName = $identity.ComputerName
        UserSid = $identity.UserSid
        UserProfile = $env:USERPROFILE
        LocalAppData = $env:LOCALAPPDATA
        Temp = $env:TEMP
        WingetAvailable = [bool]$winget.Available
        WingetVersion = $winget.Version
        WingetVersionOk = $wingetVersionOk
        PendingReboot = $pending
        Blockers = @($blockers)
        Warnings = @($warnings)
        BootId = Get-WhinsetBootId
    }
}

function Assert-WhinsetApplyPrerequisites {
    param([Parameter(Mandatory)]$Environment)
    if (@($Environment.Blockers).Count -gt 0) { throw (@($Environment.Blockers) -join ' ') }
}

function Get-WhinsetWingetSources {
    try {
        $result = Invoke-WhinsetExternalCommand -FilePath 'winget.exe' -ArgumentList @('source','list','--disable-interactivity') -TimeoutSeconds 60
        return [pscustomobject][ordered]@{ Success = $result.Success; ExitCode = $result.ExitCode; Output = "$($result.Output) $($result.Error)".Trim() }
    } catch {
        return [pscustomobject][ordered]@{ Success = $false; ExitCode = $null; Output = $_.Exception.Message }
    }
}

function Test-WhinsetPackageInstalled {
    param(
        [Parameter(Mandatory)]$Package,
        [switch]$AcceptAgreements
    )
    $wingetArgs = @('list','--id',$Package.Id,'--exact','--source',$Package.Source,'--disable-interactivity')
    if ($AcceptAgreements) { $wingetArgs += '--accept-source-agreements' }
    try {
        $result = Invoke-WhinsetExternalCommand -FilePath 'winget.exe' -ArgumentList $wingetArgs -TimeoutSeconds 120
    } catch {
        return [pscustomobject][ordered]@{ Installed = $false; VersionVerified = $false; Error = $_.Exception.Message; ExitCode = $null }
    }
    if (-not $result.TimedOut -and $result.ExitCode -eq -1978335212) {
        return [pscustomobject][ordered]@{ Installed = $false; VersionVerified = $false; Error = ''; ExitCode = $result.ExitCode }
    }
    if (-not $result.Success) {
        return [pscustomobject][ordered]@{ Installed = $false; VersionVerified = $false; Error = "WinGet inventory failed (exit $($result.ExitCode)): $($result.Error) $($result.Output)".Trim(); ExitCode = $result.ExitCode }
    }
    if ($Package.VersionPolicy -eq 'pinned' -and $Package.Version) {
        $temp = Join-Path $env:TEMP ("whinset-inventory-{0}.json" -f [guid]::NewGuid().ToString('N'))
        try {
            $export = Invoke-WhinsetExternalCommand -FilePath 'winget.exe' -ArgumentList @('export','--output',$temp,'--include-versions','--source',$Package.Source,'--disable-interactivity','--accept-source-agreements') -TimeoutSeconds 120
            if (-not $export.Success) { return [pscustomobject][ordered]@{ Installed = $true; VersionVerified = $false; Error = "Cannot verify pinned version (exit $($export.ExitCode))."; ExitCode = $result.ExitCode } }
            $inventory = Get-Content -LiteralPath $temp -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($sourceNode in @($inventory.Sources)) {
                foreach ($entry in @($sourceNode.Packages)) {
                    if ($entry.PackageIdentifier -eq $Package.Id -and $entry.PSObject.Properties['Version'] -and [string]$entry.Version -eq [string]$Package.Version) {
                        return [pscustomobject][ordered]@{ Installed = $true; VersionVerified = $true; Error = ''; ExitCode = $result.ExitCode }
                    }
                }
            }
            return [pscustomobject][ordered]@{ Installed = $true; VersionVerified = $false; Error = "Installed version differs from pinned $($Package.Version)."; ExitCode = $result.ExitCode }
        } catch {
            return [pscustomobject][ordered]@{ Installed = $true; VersionVerified = $false; Error = $_.Exception.Message; ExitCode = $result.ExitCode }
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    }
    return [pscustomobject][ordered]@{ Installed = $true; VersionVerified = $true; Error = ''; ExitCode = $result.ExitCode }
}
