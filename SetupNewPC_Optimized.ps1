<#
.SYNOPSIS
    Reliable Windows 11 provisioning for a personal engineering/AI workstation.

.DESCRIPTION
    Keeps the existing WindowsBase -> reboot gate -> Development architecture.
    Adds Profiles, persistent per-item results, retry/skip behavior, real WSL and
    Docker validation, safer opt-in WinUtil execution, and a final PASS/FAIL/
    SKIPPED environment report.

.PARAMETER Profile
    Minimal, Developer, AI, Engineering, or Full. Default: Developer.

.PARAMETER ExtraGroups
    Add groups to the selected profile: Core, Developer, AI, Engineering, Personal.

.PARAMETER EnableWinUtil
    Explicit opt-in to download WinUtil locally and apply its Standard preset.
    WinUtil is skipped by default. For unattended use, provide -WinUtilSha256.

.PARAMETER WinUtilSha256
    Expected SHA256 of the downloaded WinUtil script. A mismatch blocks execution.

.PARAMETER DockerSmokeTest
    Run `docker run --rm hello-world` only when Docker is already usable.

.EXAMPLE
    .\SetupNewPC_Optimized.ps1 -Profile Developer

.EXAMPLE
    .\SetupNewPC_Optimized.ps1 -Profile AI -IncludePersonal -DockerSmokeTest

.EXAMPLE
    .\SetupNewPC_Optimized.ps1 -Profile Full -EnableWinUtil -WinUtilSha256 <64-hex-hash>

.EXAMPLE
    .\SetupNewPC_Optimized.ps1 -Stage WindowsBase -Profile Engineering
    # Reboot if requested, then run:
    .\SetupNewPC_Optimized.ps1 -Stage Development -Profile Engineering
#>

[CmdletBinding()]
param(
    [ValidateSet('Auto', 'WindowsBase', 'Development')]
    [string]$Stage = 'Auto',

    [ValidateSet('Minimal', 'Developer', 'AI', 'Engineering', 'Full')]
    [string]$Profile = 'Developer',

    [ValidateSet('Core', 'Developer', 'AI', 'Engineering', 'Personal')]
    [string[]]$ExtraGroups = @(),

    [switch]$IncludePersonal,
    [switch]$SkipWinUtil,
    [switch]$EnableWinUtil,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$WinUtilSha256 = '',
    [switch]$SkipWSL,
    [switch]$SkipDocker,
    [switch]$DockerSmokeTest,
    [switch]$SkipStoreApps,
    [switch]$SkipCondaInit,
    [switch]$AllowReboot,
    [switch]$NoResume,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Failures = @()
$script:ItemResults = [ordered]@{}
$script:EnvironmentResults = @()
$script:CurrentStatus = 'Running'
$script:CurrentDetail = ''
$script:LastCompletedStage = 'None'
$script:ResumeTaskName = 'SetupNewPC-Resume-After-Reboot'
$script:StateVersion = 3

# Macro structure:
#   [1/3] Windows base -> [2/3] optional reboot gate -> [3/3] development.
# WSL/VirtualMachinePlatform can require a restart, so development work is
# deliberately kept out of the first run until those components are active.

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) {
        $hostExe = $pwsh.Source
    } else {
        $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $elevatedArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-Stage', $Stage,
        '-Profile', $Profile
    )
    if ($ExtraGroups.Count -gt 0) { $elevatedArgs += @('-ExtraGroups', ($ExtraGroups -join ',')) }
    if ($IncludePersonal) { $elevatedArgs += '-IncludePersonal' }
    if ($SkipWinUtil) { $elevatedArgs += '-SkipWinUtil' }
    if ($EnableWinUtil) { $elevatedArgs += '-EnableWinUtil' }
    if ($WinUtilSha256) { $elevatedArgs += @('-WinUtilSha256', $WinUtilSha256) }
    if ($SkipWSL) { $elevatedArgs += '-SkipWSL' }
    if ($SkipDocker) { $elevatedArgs += '-SkipDocker' }
    if ($DockerSmokeTest) { $elevatedArgs += '-DockerSmokeTest' }
    if ($SkipStoreApps) { $elevatedArgs += '-SkipStoreApps' }
    if ($SkipCondaInit) { $elevatedArgs += '-SkipCondaInit' }
    if ($AllowReboot) { $elevatedArgs += '-AllowReboot' }
    if ($NoResume) { $elevatedArgs += '-NoResume' }
    if ($NoPause) { $elevatedArgs += '-NoPause' }

    Start-Process -FilePath $hostExe -ArgumentList $elevatedArgs -Verb RunAs
    exit
}

$script:StateDir = Join-Path $env:ProgramData 'SetupNewPC'
$script:StateFile = Join-Path $script:StateDir 'state.json'
$script:LogFile = Join-Path $script:StateDir 'setup.log'
$script:VirtualizationReportFile = Join-Path $script:StateDir 'virtualization-report.json'
$script:DockerReadinessFile = Join-Path $script:StateDir 'docker-readiness.json'
$script:PythonPolicyFile = Join-Path $script:StateDir 'python-strategy.txt'
$script:EnvironmentReportFile = Join-Path $script:StateDir 'environment-report.json'
$script:EnvironmentReportTextFile = Join-Path $script:StateDir 'environment-report.txt'
$script:DownloadDir = Join-Path $script:StateDir 'downloads'
New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null

$transcriptStarted = $false
try {
    Start-Transcript -Path $script:LogFile -Append -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Warning "无法启动日志：$($_.Exception.Message)"
}

function ConvertTo-NativeArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument -eq '') {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + ($Argument.Replace('"', '\"')) + '"'
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
            try { $process.Kill() } catch { }
            $process.WaitForExit()
        }

        $stdout = Normalize-NativeOutput -Text $stdoutTask.Result
        $stderr = Normalize-NativeOutput -Text $stderrTask.Result
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

function Get-PreferredPowerShellExecutable {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
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

function Test-GroupSelected {
    param([Parameter(Mandatory)][string]$Group)
    return ((Get-SelectedGroups) -contains $Group)
}

function Get-SoftwareCatalog {
    return @(
        [pscustomobject]@{ Key='PowerShell7'; Name='PowerShell 7'; Id='Microsoft.PowerShell'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='HiBitUninstaller'; Name='HiBit Uninstaller'; Id='HiBitSoftware.HiBitUninstaller'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='SevenZip'; Name='7-Zip'; Id='7zip.7zip'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='Git'; Name='Git'; Id='Git.Git'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='GitHubCLI'; Name='GitHub CLI'; Id='GitHub.cli'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='Chrome'; Name='Google Chrome'; Id='Google.Chrome'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='Listary'; Name='Listary'; Id='Bopsoft.Listary'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='CCSwitch'; Name='CC Switch'; Id='farion1231.CC-Switch'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='Notepad3'; Name='Notepad3'; Id='Rizonesoft.Notepad3'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='PixPin'; Name='PixPin'; Id='PixPin.PixPin'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='LibreHardwareMonitor'; Name='LibreHardwareMonitor'; Id='LibreHardwareMonitor.LibreHardwareMonitor'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='CrystalDiskInfo'; Name='CrystalDiskInfo'; Id='CrystalDewWorld.CrystalDiskInfo'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='CrystalDiskMark'; Name='CrystalDiskMark'; Id='CrystalDewWorld.CrystalDiskMark'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='SysinternalsSuite'; Name='Sysinternals Suite'; Id='Microsoft.Sysinternals.Suite'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },
        [pscustomobject]@{ Key='ProcessExplorer'; Name='Process Explorer'; Id='Microsoft.Sysinternals.ProcessExplorer'; Source='winget'; Stage='WindowsBase'; Category='Core'; Groups=@('Core') },

        [pscustomobject]@{ Key='ClashVerge'; Name='Clash Verge Rev'; Id='ClashVergeRev.ClashVergeRev'; Source='winget'; Stage='WindowsBase'; Category='Personal'; Groups=@('Personal') },
        [pscustomobject]@{ Key='Steam'; Name='Steam'; Id='Valve.Steam'; Source='winget'; Stage='WindowsBase'; Category='Personal'; Groups=@('Personal') },
        [pscustomobject]@{ Key='Logseq'; Name='Logseq'; Id='Logseq.Logseq'; Source='winget'; Stage='WindowsBase'; Category='Personal'; Groups=@('Personal') },
        [pscustomobject]@{ Key='PotPlayer'; Name='PotPlayer'; Id='Daum.PotPlayer'; Source='winget'; Stage='WindowsBase'; Category='Personal'; Groups=@('Personal') },
        [pscustomobject]@{ Key='Thorium'; Name='Thorium'; Id='Alex313031.Thorium'; Source='winget'; Stage='WindowsBase'; Category='Personal'; Groups=@('Personal') },

        [pscustomobject]@{ Key='VSCode'; Name='Visual Studio Code'; Id='Microsoft.VisualStudioCode'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='NodeJS'; Name='Node.js'; Id='OpenJS.NodeJS'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='SystemPython'; Name='System Python 3.13'; Id='Python.Python.3.13'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='uv'; Name='uv'; Id='astral-sh.uv'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='Postman'; Name='Postman'; Id='Postman.Postman'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='DBeaver'; Name='DBeaver'; Id='DBeaver.DBeaver.Community'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='OpenJDK21'; Name='Microsoft OpenJDK 21'; Id='Microsoft.OpenJDK.21'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='Go'; Name='Go'; Id='GoLang.Go'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='Rustup'; Name='Rustup'; Id='Rustlang.Rustup'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },
        [pscustomobject]@{ Key='MinGW'; Name='MinGW-w64 GCC'; Id='BrechtSanders.WinLibs.POSIX.UCRT'; Source='winget'; Stage='Development'; Category='Developer'; Groups=@('Developer') },

        [pscustomobject]@{ Key='ChatGPT'; Name='ChatGPT Desktop'; Id='9PLM9XGG6VKS'; Source='msstore'; Stage='Development'; Category='AI'; Groups=@('AI') },
        [pscustomobject]@{ Key='CodexCLI'; Name='OpenAI Codex'; Id='OpenAI.Codex'; Source='winget'; Stage='Development'; Category='AI'; Groups=@('AI') },

        [pscustomobject]@{ Key='Anaconda'; Name='Anaconda'; Id='Anaconda.Anaconda3'; Source='winget'; Stage='Development'; Category='Engineering'; Groups=@('Engineering') },
        [pscustomobject]@{ Key='RProject'; Name='R'; Id='RProject.R'; Source='winget'; Stage='Development'; Category='Engineering'; Groups=@('Engineering') },
        [pscustomobject]@{ Key='RStudio'; Name='RStudio'; Id='Posit.RStudio'; Source='winget'; Stage='Development'; Category='Engineering'; Groups=@('Engineering') },
        [pscustomobject]@{ Key='KiCad'; Name='KiCad'; Id='KiCad.KiCad'; Source='winget'; Stage='Development'; Category='Engineering'; Groups=@('Engineering') },
        [pscustomobject]@{ Key='FreeCAD'; Name='FreeCAD'; Id='FreeCAD.FreeCAD'; Source='winget'; Stage='Development'; Category='Engineering'; Groups=@('Engineering') },
        [pscustomobject]@{ Key='MobaXterm'; Name='MobaXterm'; Id='Mobatek.MobaXterm'; Source='winget'; Stage='Development'; Category='Engineering'; Groups=@('Engineering') }
    )
}

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
    return @(Get-SoftwareCatalog | Where-Object { $_.Stage -eq $StageName -and (Test-ItemInSelectedGroups -Item $_) })
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

function Add-Failure {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Error = '',
        [string]$Stage = '',
        [string]$Category = 'Step'
    )
    Set-ItemResult -Key "step:$Name" -Name $Name -Stage $Stage -Category $Category -Status 'Failed' -Error $Error -IncrementAttempt -Persist
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
    $os = Get-CimInstance Win32_OperatingSystem
    return $os.LastBootUpTime.ToFileTimeUtc().ToString()
}

function Get-SetupState {
    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "无法读取状态文件：$($_.Exception.Message)"
        return $null
    }
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
            $activeFailureCategories = @(Get-SelectedGroups) + @('Platform', 'Python', 'Recovery', 'System', 'Step', 'Check')
            $categoryIsActive = $true
            if ($record.Category -and $activeFailureCategories -notcontains $record.Category) {
                $categoryIsActive = $false
            }
            if ($categoryIsActive -and $record.Status -eq 'Failed' -and $script:Failures -notcontains $record.Name) {
                $script:Failures += $record.Name
            }
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
    Move-Item -LiteralPath $tempStateFile -Destination $script:StateFile -Force
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
    if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
        $reasons.Add('Pending file rename')
    }

    return @($reasons)
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
    return ($firmwareDisabled -and $extensionsDisabled)
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
        Set-ItemResult -Key 'step:VirtualizationHardware' -Name 'CPU virtualization' -Stage 'WindowsBase' -Category 'Platform' -Status 'Failed' -Error 'CPU firmware virtualization and VT-x/AMD-V are unavailable.' -IncrementAttempt -Persist
        Write-Warning 'CPU 固件虚拟化与 VT-x/AMD-V 均不可用，请先在 BIOS/UEFI 中启用虚拟化。'
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
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'winget'
    )

    try {
        $result = Invoke-ExternalCommand -FilePath 'winget.exe' -ArgumentList @(
            'list', '--id', $Id, '--exact', '--source', $Source,
            '--accept-source-agreements', '--disable-interactivity'
        ) -TimeoutSeconds 60
        if (-not $result.Success) { return $false }
        return ($result.Output -match [regex]::Escape($Id))
    } catch {
        return $false
    }
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name = '',
        [string]$Source = 'winget',
        [string[]]$ExtraArgs = @(),
        [string]$Stage = 'Development',
        [string]$Category = 'Software',
        [int]$MaxAttempts = 2
    )

    $displayName = $Id
    if ($Name) { $displayName = $Name }
    $itemKey = "winget:$Id"

    $existing = Get-ItemResult -Key $itemKey
    if ($existing -and $existing.Status -eq 'Succeeded') {
        if (Test-WingetInstalled -Id $Id -Source $Source) {
            Write-Host "$displayName 已安装且状态记录有效，跳过。" -ForegroundColor DarkGray
            return $true
        }
        Write-Host "$displayName 状态记录为成功，但本机未检测到，将重新安装。" -ForegroundColor Yellow
    } elseif (Test-WingetInstalled -Id $Id -Source $Source) {
        Set-ItemResult -Key $itemKey -Name $displayName -Id $Id -Stage $Stage -Category $Category -Status 'Succeeded' -Version 'Already installed' -IncrementAttempt -Persist
        Write-Host "$displayName 已安装，记录为成功并跳过。" -ForegroundColor DarkGray
        return $true
    }

    $wingetArgs = @(
        'install', '--id', $Id, '--exact', '--source', $Source,
        '--accept-source-agreements', '--accept-package-agreements',
        '--silent', '--disable-interactivity'
    )
    if ($ExtraArgs.Count -gt 0) {
        $wingetArgs += $ExtraArgs
    }

    $lastError = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Set-ItemResult -Key $itemKey -Name $displayName -Id $Id -Stage $Stage -Category $Category -Status 'Running' -IncrementAttempt -Persist
        Write-Host "安装 $displayName (attempt $attempt/$MaxAttempts) ..." -ForegroundColor Cyan

        try {
            $result = Invoke-ExternalCommand -FilePath 'winget.exe' -ArgumentList $wingetArgs -TimeoutSeconds 3600
            $combined = "$($result.Output)`n$($result.Error)".Trim()
            if ($result.Success -or $combined -match 'already installed|No applicable|No available upgrade|已安装') {
                Set-ItemResult -Key $itemKey -Name $displayName -Id $Id -Stage $Stage -Category $Category -Status 'Succeeded' -Version 'Installed' -Persist
                return $true
            }

            $lastError = "ExitCode=$($result.ExitCode); $combined"
            if ($lastError.Length -gt 2000) { $lastError = $lastError.Substring(0, 2000) }
            Write-Warning "$displayName 安装失败：$lastError"
        } catch {
            $lastError = $_.Exception.Message
            Write-Warning "$displayName 安装异常：$lastError"
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds ([Math]::Min(10, $attempt * 3))
        }
    }

    Set-ItemResult -Key $itemKey -Name $displayName -Id $Id -Stage $Stage -Category $Category -Status 'Failed' -Error $lastError -Persist
    return $false
}

function Install-SoftwareForStage {
    param([Parameter(Mandatory)][string]$StageName)

    Write-Host "`n安装 $StageName 阶段软件..." -ForegroundColor Green
    foreach ($item in @(Get-SoftwareForStage -StageName $StageName)) {
        Invoke-Winget -Id $item.Id -Name $item.Name -Source $item.Source -Stage $item.Stage -Category $item.Category | Out-Null
        Update-SessionPath
    }
}

function Invoke-WinUtilStandardPreset {
    $itemKey = 'step:WinUtilStandardPreset'
    if ($SkipWinUtil -or -not $EnableWinUtil) {
        Set-ItemResult -Key $itemKey -Name 'WinUtil Standard preset' -Stage 'WindowsBase' -Category 'System' -Status 'Skipped' -Error 'Opt-in required; use -EnableWinUtil.' -Persist
        Write-Host 'WinUtil 默认跳过。需要时显式使用 -EnableWinUtil，并提供 -WinUtilSha256。' -ForegroundColor DarkGray
        return
    }

    $existing = Get-ItemResult -Key $itemKey
    if ($existing -and $existing.Status -eq 'Succeeded' -and (Test-Path -LiteralPath (Join-Path $script:DownloadDir 'winutil.ps1'))) {
        Write-Host 'WinUtil Standard preset 已成功应用，跳过重复执行。' -ForegroundColor DarkGray
        return
    }

    New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null
    $winUtilPath = Join-Path $script:DownloadDir 'winutil.ps1'
    $hashPath = Join-Path $script:DownloadDir 'winutil.sha256.txt'

    try {
        Set-ItemResult -Key $itemKey -Name 'WinUtil Standard preset' -Stage 'WindowsBase' -Category 'System' -Status 'Running' -IncrementAttempt -Persist
        Write-Warning '即将下载 WinUtil。该脚本来自 https://christitus.com/win，并将在本机管理员会话中执行。'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://christitus.com/win' -OutFile $winUtilPath -ErrorAction Stop

        $actualHash = (Get-FileHash -LiteralPath $winUtilPath -Algorithm SHA256).Hash.ToLowerInvariant()
        "$actualHash  $winUtilPath" | Set-Content -LiteralPath $hashPath -Encoding UTF8
        Write-Host "WinUtil SHA256: $actualHash" -ForegroundColor Yellow

        if ($WinUtilSha256) {
            if ($actualHash -ne $WinUtilSha256.ToLowerInvariant()) {
                throw "WinUtil SHA256 mismatch. Expected $($WinUtilSha256.ToLowerInvariant()), got $actualHash"
            }
        } elseif ($NoPause) {
            throw 'Unverified WinUtil is blocked in -NoPause mode. Supply -WinUtilSha256.'
        } else {
            $confirmation = Read-Host '未提供 WinUtilSha256。核验哈希后输入 RUN-WINUTIL 继续，其他输入取消'
            if ($confirmation -ne 'RUN-WINUTIL') {
                throw 'User declined unverified WinUtil execution.'
            }
        }

        $escapedPath = $winUtilPath.Replace("'", "''")
        $command = "& ([ScriptBlock]::Create((Get-Content -LiteralPath '$escapedPath' -Raw))) -Preset Standard"
        $legacyShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $result = Invoke-ExternalCommand -FilePath $legacyShell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command) -TimeoutSeconds 3600
        if (-not $result.Success) {
            throw "WinUtil exit code $($result.ExitCode): $($result.Error) $($result.Output)"
        }

        Set-ItemResult -Key $itemKey -Name 'WinUtil Standard preset' -Stage 'WindowsBase' -Category 'System' -Status 'Succeeded' -Version "SHA256=$actualHash" -Persist
    } catch {
        Set-ItemResult -Key $itemKey -Name 'WinUtil Standard preset' -Stage 'WindowsBase' -Category 'System' -Status 'Failed' -Error $_.Exception.Message -Persist
        Write-Warning "WinUtil 未执行或执行失败：$($_.Exception.Message)"
    }
}

function Install-WindowsBase {
    Write-Host "`n========== [1/3] Windows 基础 ==========" -ForegroundColor Magenta

    $winUtilHandled = $false
    foreach ($item in @(Get-SoftwareForStage -StageName 'WindowsBase')) {
        Invoke-Winget -Id $item.Id -Name $item.Name -Source $item.Source -Stage $item.Stage -Category $item.Category | Out-Null
        Update-SessionPath
        if ($item.Key -eq 'HiBitUninstaller' -and -not $winUtilHandled) {
            Invoke-WinUtilStandardPreset
            $winUtilHandled = $true
        }
    }
    if (-not $winUtilHandled) {
        Invoke-WinUtilStandardPreset
    }

    $wslNeeded = (Test-GroupSelected -Group 'Developer') -or (Test-GroupSelected -Group 'AI') -or (Test-GroupSelected -Group 'Engineering')
    if ($SkipWSL) {
        Set-ItemResult -Key 'step:WSLPrerequisites' -Name 'WSL prerequisites' -Stage 'WindowsBase' -Category 'Platform' -Status 'Skipped' -Error '-SkipWSL' -Persist
    } elseif ($wslNeeded) {
        Enable-WslPrerequisites
    } else {
        Set-ItemResult -Key 'step:WSLPrerequisites' -Name 'WSL prerequisites' -Stage 'WindowsBase' -Category 'Platform' -Status 'Skipped' -Error 'Profile does not require WSL.' -Persist
    }

    Update-SessionPath
}

function Register-ResumeTask {
    if ($NoResume) {
        Set-ItemResult -Key 'step:ResumeTask' -Name 'Reboot resume task' -Stage 'WindowsBase' -Category 'Recovery' -Status 'Skipped' -Error '-NoResume' -Persist
        return
    }

    try {
        $hostExe = Get-PreferredPowerShellExecutable
        $argumentParts = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"",
            '-Stage', 'Development',
            '-Profile', $Profile,
            '-NoPause'
        )
        if ($ExtraGroups.Count -gt 0) { $argumentParts += @('-ExtraGroups', ($ExtraGroups -join ',')) }
        if ($IncludePersonal) { $argumentParts += '-IncludePersonal' }
        if ($SkipWSL) { $argumentParts += '-SkipWSL' }
        if ($SkipDocker) { $argumentParts += '-SkipDocker' }
        if ($DockerSmokeTest) { $argumentParts += '-DockerSmokeTest' }
        if ($SkipStoreApps) { $argumentParts += '-SkipStoreApps' }
        if ($SkipCondaInit) { $argumentParts += '-SkipCondaInit' }

        $userId = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute $hostExe -Argument ($argumentParts -join ' ')
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest

        Register-ScheduledTask -TaskName $script:ResumeTaskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Force | Out-Null
        Set-ItemResult -Key 'step:ResumeTask' -Name 'Reboot resume task' -Stage 'WindowsBase' -Category 'Recovery' -Status 'Succeeded' -Version $script:ResumeTaskName -Persist
        Write-Host "已登记重启后自动续跑任务：$script:ResumeTaskName" -ForegroundColor Green
    } catch {
        Set-ItemResult -Key 'step:ResumeTask' -Name 'Reboot resume task' -Stage 'WindowsBase' -Category 'Recovery' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "无法登记自动续跑任务：$($_.Exception.Message)"
        Write-Host '重启后仍可手动运行同一脚本，Auto 模式会继续开发环境阶段。' -ForegroundColor Yellow
    }
}

function Unregister-ResumeTask {
    try {
        if (Get-ScheduledTask -TaskName $script:ResumeTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false
        }
        Set-ItemResult -Key 'step:ResumeTask' -Name 'Reboot resume task' -Stage 'WindowsBase' -Category 'Recovery' -Status 'Succeeded' -Version 'Removed after completion' -Persist
    } catch {
        Set-ItemResult -Key 'step:ResumeTask' -Name 'Reboot resume task' -Stage 'WindowsBase' -Category 'Recovery' -Status 'Warning' -Error $_.Exception.Message -Persist
        Write-Warning "无法移除续跑任务：$($_.Exception.Message)"
    }
}

function Request-NextReboot {
    Write-Host "`n检测到 WSL/VMP 等系统组件需要重启后才能继续。" -ForegroundColor Yellow
    Write-Host '开发环境阶段尚未开始；重启后脚本会从 Development 阶段续跑。' -ForegroundColor Yellow
    Set-ItemResult -Key 'step:RebootGate' -Name 'Reboot gate' -Stage 'WindowsBase' -Category 'Recovery' -Status 'AwaitingReboot' -Version 'WSL/VMP or Windows servicing reboot required' -Persist

    if ($AllowReboot) {
        Write-Host '按 -AllowReboot 参数要求在 10 秒后重启...' -ForegroundColor Yellow
        Start-Sleep -Seconds 10
        Restart-Computer -Force
        return
    }

    if (-not $NoPause) {
        $answer = Read-Host '现在重启吗？输入 Y 立即重启，直接回车则稍后手动重启 [Y/N]'
        if ($answer -match '^[Yy]$') {
            Restart-Computer -Force
        }
    }
}

function Resolve-SetupStage {
    if ($Stage -ne 'Auto') {
        return $Stage
    }

    $state = Get-SetupState
    if (-not $state -or -not $state.Status) {
        return 'WindowsBase'
    }

    if ($state.Status -eq 'AwaitingReboot') {
        $currentBootId = Get-BootId
        $pending = @(Get-PendingReboot)
        if ([string]$state.BootId -ne $currentBootId -or $pending.Count -eq 0) {
            return 'Development'
        }
        return 'AwaitingReboot'
    }

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
        $report.Ready = $report.DockerExecutable -and $report.ServicePresent -and $report.ServiceStatus -eq 'Running' -and [bool]$report.ServerVersion
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
    if ($existingValidation -and $existingValidation.Status -eq 'Succeeded') {
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
            if (-not $convertResult.Success) {
                Set-ItemResult -Key 'step:UbuntuWSL2' -Name 'Ubuntu WSL2 conversion' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error "$($convertResult.Error) $($convertResult.Output)" -IncrementAttempt -Persist
            } else {
                Set-ItemResult -Key 'step:UbuntuWSL2' -Name 'Ubuntu WSL2 conversion' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version '2' -Persist
            }
        }

        $validation = Test-WslReady
        if ($validation.Ready) {
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
    if ($SkipDocker) {
        Set-ItemResult -Key 'step:DockerDesktop' -Name 'Docker Desktop' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error '-SkipDocker' -Persist
        return $false
    }

    Write-Host "`n安装 Docker Desktop..." -ForegroundColor Green
    Invoke-Winget -Id 'Docker.DockerDesktop' -Name 'Docker Desktop' -Stage 'Development' -Category 'Platform' | Out-Null
    Update-SessionPath

    try {
        $service = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            Start-Service -Name 'com.docker.service' -ErrorAction Stop
            $service.Refresh()
        }
        if ($service -and $service.Status -eq 'Running') {
            Set-ItemResult -Key 'step:DockerService' -Name 'Docker service' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version 'Running' -Persist
        } else {
            Set-ItemResult -Key 'step:DockerService' -Name 'Docker service' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error 'com.docker.service not present or not running.' -Persist
        }
    } catch {
        Set-ItemResult -Key 'step:DockerService' -Name 'Docker service' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "Docker 服务未启动：$($_.Exception.Message)"
    }

    try {
        $dockerUsers = Get-LocalGroup -Name 'docker-users' -ErrorAction SilentlyContinue
        if ($dockerUsers) {
            $userId = "$env:USERDOMAIN\$env:USERNAME"
            $member = Get-LocalGroupMember -Group 'docker-users' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $userId }
            if (-not $member) {
                Add-LocalGroupMember -Group 'docker-users' -Member $userId -ErrorAction Stop
                Write-Host '已把当前用户加入 docker-users；需重新登录后生效。' -ForegroundColor Yellow
            }
            Set-ItemResult -Key 'step:DockerUsers' -Name 'docker-users membership' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version $userId -Persist
        } else {
            Set-ItemResult -Key 'step:DockerUsers' -Name 'docker-users membership' -Stage 'Development' -Category 'Platform' -Status 'Warning' -Error 'docker-users group not found.' -Persist
        }
    } catch {
        Set-ItemResult -Key 'step:DockerUsers' -Name 'docker-users membership' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "配置 docker-users 失败：$($_.Exception.Message)"
    }

    $readiness = Test-DockerReady
    if ($readiness.Ready) {
        Set-ItemResult -Key 'step:DockerValidation' -Name 'Docker validation' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version "Server $($readiness.ServerVersion)" -Persist
    } else {
        Set-ItemResult -Key 'step:DockerValidation' -Name 'Docker validation' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error $readiness.Error -IncrementAttempt -Persist
    }

    if ($DockerSmokeTest) {
        if ($readiness.Ready) {
            $smokeResult = Invoke-ExternalCommand -FilePath $readiness.DockerPath -ArgumentList @('run', '--rm', 'hello-world') -TimeoutSeconds 300
            if ($smokeResult.Success) {
                Set-ItemResult -Key 'step:DockerSmokeTest' -Name 'Docker smoke test' -Stage 'Development' -Category 'Platform' -Status 'Succeeded' -Version 'hello-world' -Persist
            } else {
                Set-ItemResult -Key 'step:DockerSmokeTest' -Name 'Docker smoke test' -Stage 'Development' -Category 'Platform' -Status 'Failed' -Error "$($smokeResult.Error) $($smokeResult.Output)" -IncrementAttempt -Persist
            }
        } else {
            Set-ItemResult -Key 'step:DockerSmokeTest' -Name 'Docker smoke test' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error 'Docker daemon is not ready.' -Persist
        }
    } else {
        Set-ItemResult -Key 'step:DockerSmokeTest' -Name 'Docker smoke test' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error 'Use -DockerSmokeTest to enable.' -Persist
    }

    $finalReadiness = [ordered]@{
        Timestamp      = (Get-Date).ToString('o')
        Docker         = $readiness
        Virtualization = Get-VirtualizationReport
    }
    $finalReadiness | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:DockerReadinessFile -Encoding UTF8
    return $readiness.Ready
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
    if (-not (Test-GroupSelected -Group 'Developer')) {
        Set-ItemResult -Key 'step:uvStrategy' -Name 'uv strategy' -Stage 'Development' -Category 'Python' -Status 'Skipped' -Error 'Developer group not selected.' -Persist
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
    if (-not (Test-GroupSelected -Group 'Engineering')) {
        Set-ItemResult -Key 'step:CondaInit' -Name 'Conda initialization' -Stage 'Development' -Category 'Python' -Status 'Skipped' -Error 'Engineering group not selected.' -Persist
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
    if (-not (Test-GroupSelected -Group 'Developer')) {
        Set-ItemResult -Key 'step:GitLFS' -Name 'Git LFS' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Developer group not selected.' -Persist
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
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    $java = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($java) { $candidates += (Split-Path (Split-Path $java.Source -Parent) -Parent) }
    $candidates += @(Get-ChildItem 'C:\Program Files\Microsoft\jdk-*' -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'bin\java.exe'))) {
            return $candidate
        }
    }
    return $null
}

function Configure-JavaEnvironment {
    if (-not (Test-GroupSelected -Group 'Developer')) {
        Set-ItemResult -Key 'step:JavaHome' -Name 'JAVA_HOME' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Developer group not selected.' -Persist
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
    if (-not (Test-GroupSelected -Group 'Developer')) {
        Set-ItemResult -Key 'step:GoEnvironment' -Name 'Go environment' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Developer group not selected.' -Persist
        return
    }

    $itemKey = 'step:GoEnvironment'
    try {
        $go = Get-Command go.exe -ErrorAction SilentlyContinue
        if (-not $go) { throw 'go.exe not found.' }
        $result = Invoke-ExternalCommand -FilePath $go.Source -ArgumentList @('env', '-w', "GOPATH=$env:USERPROFILE\go") -TimeoutSeconds 60
        if (-not $result.Success) { throw "go env failed: $($result.Error) $($result.Output)" }
        $version = Invoke-ExternalCommand -FilePath $go.Source -ArgumentList @('version') -TimeoutSeconds 30
        Set-ItemResult -Key $itemKey -Name 'Go environment' -Stage 'Development' -Category 'Developer' -Status 'Succeeded' -Version $version.Output -Persist
    } catch {
        Set-ItemResult -Key $itemKey -Name 'Go environment' -Stage 'Development' -Category 'Developer' -Status 'Failed' -Error $_.Exception.Message -IncrementAttempt -Persist
        Write-Warning "配置 Go 环境失败：$($_.Exception.Message)"
    }
}

function Configure-RustEnvironment {
    if (-not (Test-GroupSelected -Group 'Developer')) {
        Set-ItemResult -Key 'step:RustEnvironment' -Name 'Rust environment' -Stage 'Development' -Category 'Developer' -Status 'Skipped' -Error 'Developer group not selected.' -Persist
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
    Update-SessionPath

    Configure-GitLfs
    Configure-JavaEnvironment
    Configure-GoEnvironment
    Configure-RustEnvironment
    Configure-PythonStrategy

    $wslNeeded = (Test-GroupSelected -Group 'Developer') -or (Test-GroupSelected -Group 'AI') -or (Test-GroupSelected -Group 'Engineering')
    if (-not $wslNeeded) {
        Set-ItemResult -Key 'step:WSL2Validation' -Name 'WSL2 validation' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error 'Profile does not require WSL.' -Persist
        Set-ItemResult -Key 'step:DockerDesktop' -Name 'Docker Desktop' -Stage 'Development' -Category 'Platform' -Status 'Skipped' -Error 'Profile does not require Docker.' -Persist
        return
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
function Get-SystemPythonExecutable {
    $candidates = @(
        'C:\Program Files\Python313\python.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe')
    )
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python -and $python.Source -notmatch 'anaconda|miniconda') {
        $candidates += $python.Source
    }
    return ($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1)
}

function Add-EnvironmentResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'SKIPPED')][string]$Status,
        [string]$Version = '',
        [string]$Detail = ''
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
    Set-ItemResult -Key "check:$Name" -Name $Name -Stage 'EnvironmentCheck' -Category 'Check' -Status $itemStatus -Error $Detail -Version $Version -Persist
}

function Test-Environment {
    Write-Host "`n环境验证" -ForegroundColor Green
    $script:EnvironmentResults = @()

    $os = Get-CimInstance Win32_OperatingSystem
    Add-EnvironmentResult -Name 'Windows' -Status 'PASS' -Version "$($os.Caption) $($os.Version) build $($os.BuildNumber)" -Detail 'Operating system'

    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) {
        $result = Invoke-ExternalCommand -FilePath $pwsh.Source -ArgumentList @('--version') -TimeoutSeconds 30
        if ($result.Success) { Add-EnvironmentResult -Name 'PowerShell 7' -Status 'PASS' -Version $result.Output -Detail $pwsh.Source }
        else { Add-EnvironmentResult -Name 'PowerShell 7' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
    } else {
        Add-EnvironmentResult -Name 'PowerShell 7' -Status 'FAIL' -Detail 'pwsh.exe not found.'
    }

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $result = Invoke-ExternalCommand -FilePath $git.Source -ArgumentList @('--version') -TimeoutSeconds 30
        if ($result.Success) { Add-EnvironmentResult -Name 'Git' -Status 'PASS' -Version $result.Output -Detail $git.Source }
        else { Add-EnvironmentResult -Name 'Git' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
    } else {
        Add-EnvironmentResult -Name 'Git' -Status 'FAIL' -Detail 'git.exe not found.'
    }

    if (Test-GroupSelected -Group 'Developer') {
        if ($git) {
            $result = Invoke-ExternalCommand -FilePath $git.Source -ArgumentList @('lfs', 'version') -TimeoutSeconds 30
            if ($result.Success) { Add-EnvironmentResult -Name 'Git LFS' -Status 'PASS' -Version $result.Output -Detail $git.Source }
            else { Add-EnvironmentResult -Name 'Git LFS' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
        } else {
            Add-EnvironmentResult -Name 'Git LFS' -Status 'FAIL' -Detail 'git.exe not found.'
        }
    } else {
        Add-EnvironmentResult -Name 'Git LFS' -Status 'SKIPPED' -Detail 'Developer group not selected.'
    }

    if (Test-GroupSelected -Group 'Developer') {
        $python = Get-SystemPythonExecutable
        if ($python) {
            $result = Invoke-ExternalCommand -FilePath $python -ArgumentList @('--version') -TimeoutSeconds 30
            if ($result.Success) { Add-EnvironmentResult -Name 'Python' -Status 'PASS' -Version $result.Output -Detail $python }
            else { Add-EnvironmentResult -Name 'Python' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
        } else {
            Add-EnvironmentResult -Name 'Python' -Status 'FAIL' -Detail 'System Python 3.13 not found.'
        }

        $uv = Get-Command uv.exe -ErrorAction SilentlyContinue
        if ($uv) {
            $result = Invoke-ExternalCommand -FilePath $uv.Source -ArgumentList @('--version') -TimeoutSeconds 30
            if ($result.Success) { Add-EnvironmentResult -Name 'uv' -Status 'PASS' -Version $result.Output -Detail $env:UV_PYTHON_PREFERENCE }
            else { Add-EnvironmentResult -Name 'uv' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
        } else {
            Add-EnvironmentResult -Name 'uv' -Status 'FAIL' -Detail 'uv.exe not found.'
        }
    } else {
        Add-EnvironmentResult -Name 'Python' -Status 'SKIPPED' -Detail 'Developer group not selected.'
        Add-EnvironmentResult -Name 'uv' -Status 'SKIPPED' -Detail 'Developer group not selected.'
    }

    if (Test-GroupSelected -Group 'Developer') {
        $node = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($node) {
            $result = Invoke-ExternalCommand -FilePath $node.Source -ArgumentList @('--version') -TimeoutSeconds 30
            if ($result.Success) { Add-EnvironmentResult -Name 'Node.js' -Status 'PASS' -Version $result.Output -Detail $node.Source }
            else { Add-EnvironmentResult -Name 'Node.js' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
        } else {
            Add-EnvironmentResult -Name 'Node.js' -Status 'FAIL' -Detail 'node.exe not found.'
        }
    } else {
        Add-EnvironmentResult -Name 'Node.js' -Status 'SKIPPED' -Detail 'Developer group not selected.'
    }

    if (Test-GroupSelected -Group 'Developer') {
        $java = Get-Command java.exe -ErrorAction SilentlyContinue
        if ($java) {
            $result = Invoke-ExternalCommand -FilePath $java.Source -ArgumentList @('-version') -TimeoutSeconds 30
            $versionText = "$($result.Error) $($result.Output)".Trim()
            if ($result.Success) { Add-EnvironmentResult -Name 'Java' -Status 'PASS' -Version $versionText -Detail "JAVA_HOME=$env:JAVA_HOME" }
            else { Add-EnvironmentResult -Name 'Java' -Status 'FAIL' -Detail $versionText }
        } else {
            Add-EnvironmentResult -Name 'Java' -Status 'FAIL' -Detail "java.exe not found. JAVA_HOME=$env:JAVA_HOME"
        }
    } else {
        Add-EnvironmentResult -Name 'Java' -Status 'SKIPPED' -Detail 'Developer group not selected.'
    }

    if (Test-GroupSelected -Group 'Developer') {
        $go = Get-Command go.exe -ErrorAction SilentlyContinue
        if ($go) {
            $result = Invoke-ExternalCommand -FilePath $go.Source -ArgumentList @('version') -TimeoutSeconds 30
            if ($result.Success) { Add-EnvironmentResult -Name 'Go' -Status 'PASS' -Version $result.Output -Detail $go.Source }
            else { Add-EnvironmentResult -Name 'Go' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
        } else {
            Add-EnvironmentResult -Name 'Go' -Status 'FAIL' -Detail 'go.exe not found.'
        }
    } else {
        Add-EnvironmentResult -Name 'Go' -Status 'SKIPPED' -Detail 'Developer group not selected.'
    }

    if (Test-GroupSelected -Group 'Developer') {
        $rustc = Get-Command rustc.exe -ErrorAction SilentlyContinue
        $cargo = Get-Command cargo.exe -ErrorAction SilentlyContinue
        if ($rustc -and $cargo) {
            $rustResult = Invoke-ExternalCommand -FilePath $rustc.Source -ArgumentList @('--version') -TimeoutSeconds 30
            $cargoResult = Invoke-ExternalCommand -FilePath $cargo.Source -ArgumentList @('--version') -TimeoutSeconds 30
            if ($rustResult.Success -and $cargoResult.Success) {
                Add-EnvironmentResult -Name 'Rust / Cargo' -Status 'PASS' -Version "$($rustResult.Output); $($cargoResult.Output)" -Detail 'rustc and cargo available'
            } else {
                Add-EnvironmentResult -Name 'Rust / Cargo' -Status 'FAIL' -Detail "$($rustResult.Error) $($cargoResult.Error)"
            }
        } else {
            Add-EnvironmentResult -Name 'Rust / Cargo' -Status 'FAIL' -Detail 'rustc.exe or cargo.exe not found.'
        }
    } else {
        Add-EnvironmentResult -Name 'Rust / Cargo' -Status 'SKIPPED' -Detail 'Developer group not selected.'
    }

    if (Test-GroupSelected -Group 'Developer') {
        $gcc = Get-Command gcc.exe -ErrorAction SilentlyContinue
        if ($gcc) {
            $result = Invoke-ExternalCommand -FilePath $gcc.Source -ArgumentList @('--version') -TimeoutSeconds 30
            $firstLine = @($result.Output -split "`r?`n")[0]
            if ($result.Success) { Add-EnvironmentResult -Name 'GCC' -Status 'PASS' -Version $firstLine -Detail $gcc.Source }
            else { Add-EnvironmentResult -Name 'GCC' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
        } else {
            Add-EnvironmentResult -Name 'GCC' -Status 'FAIL' -Detail 'gcc.exe not found.'
        }
    } else {
        Add-EnvironmentResult -Name 'GCC' -Status 'SKIPPED' -Detail 'Developer group not selected.'
    }

    if (Test-GroupSelected -Group 'Engineering') {
        $conda = Find-CondaExecutable
        if ($conda) {
            $result = Invoke-ExternalCommand -FilePath $conda -ArgumentList @('--version') -TimeoutSeconds 60
            if ($result.Success) { Add-EnvironmentResult -Name 'Conda' -Status 'PASS' -Version $result.Output -Detail $conda }
            else { Add-EnvironmentResult -Name 'Conda' -Status 'FAIL' -Detail "$($result.Error) $($result.Output)" }
        } else {
            Add-EnvironmentResult -Name 'Conda' -Status 'FAIL' -Detail 'conda.exe not found.'
        }
    } else {
        Add-EnvironmentResult -Name 'Conda' -Status 'SKIPPED' -Detail 'Engineering group not selected.'
    }

    $wslNeeded = (Test-GroupSelected -Group 'Developer') -or (Test-GroupSelected -Group 'AI') -or (Test-GroupSelected -Group 'Engineering')
    if (-not $wslNeeded -or $SkipWSL) {
        Add-EnvironmentResult -Name 'WSL2' -Status 'SKIPPED' -Detail 'WSL not selected or -SkipWSL.'
        Add-EnvironmentResult -Name 'Ubuntu' -Status 'SKIPPED' -Detail 'WSL not selected or -SkipWSL.'
    } else {
        $wsl = Test-WslReady
        if ($wsl.Ready) {
            Add-EnvironmentResult -Name 'WSL2' -Status 'PASS' -Version $wsl.VersionText -Detail "$($wsl.UbuntuName) v$($wsl.UbuntuVersion)"
            Add-EnvironmentResult -Name 'Ubuntu' -Status 'PASS' -Version $wsl.UbuntuName -Detail "WSL version $($wsl.UbuntuVersion)"
        } else {
            Add-EnvironmentResult -Name 'WSL2' -Status 'FAIL' -Detail $wsl.Error
            $ubuntuStatus = 'FAIL'
            $ubuntuDetail = $wsl.Error
            if (-not $wsl.UbuntuPresent) { $ubuntuDetail = 'Ubuntu distribution not found.' }
            Add-EnvironmentResult -Name 'Ubuntu' -Status $ubuntuStatus -Detail $ubuntuDetail
        }
    }

    if (-not $wslNeeded -or $SkipDocker) {
        Add-EnvironmentResult -Name 'Docker' -Status 'SKIPPED' -Detail 'Docker not selected or -SkipDocker.'
    } else {
        $docker = Test-DockerReady
        if ($docker.Ready) {
            Add-EnvironmentResult -Name 'Docker' -Status 'PASS' -Version "Server $($docker.ServerVersion)" -Detail $docker.DockerPath
            if ($DockerSmokeTest) {
                $smoke = Invoke-ExternalCommand -FilePath 'docker.exe' -ArgumentList @('run', '--rm', 'hello-world') -TimeoutSeconds 300
                if ($smoke.Success) { Add-EnvironmentResult -Name 'Docker smoke test' -Status 'PASS' -Version 'hello-world' -Detail $smoke.Output }
                else { Add-EnvironmentResult -Name 'Docker smoke test' -Status 'FAIL' -Detail "$($smoke.Error) $($smoke.Output)" }
            }
        } else {
            Add-EnvironmentResult -Name 'Docker' -Status 'FAIL' -Detail $docker.Error
        }
    }

    $report = [ordered]@{
        GeneratedAt = (Get-Date).ToString('o')
        Profile     = $Profile
        Groups      = @(Get-SelectedGroups)
        Results     = $script:EnvironmentResults
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:EnvironmentReportFile -Encoding UTF8

    $textLines = @("Environment report - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Profile: $Profile", '')
    foreach ($entry in $script:EnvironmentResults) {
        $textLines += ('{0,-20} {1,-7} {2} {3}' -f $entry.Name, $entry.Status, $entry.Version, $entry.Detail).TrimEnd()
    }
    Set-Content -LiteralPath $script:EnvironmentReportTextFile -Value ($textLines -join [Environment]::NewLine) -Encoding UTF8

    Write-Host ''
    $script:EnvironmentResults | Format-Table Name, Status, Version, Detail -AutoSize | Out-String -Width 260 | Write-Host
    Write-Host "环境报告：$script:EnvironmentReportFile" -ForegroundColor Cyan
}
function Get-FinalStatus {
    if ($script:Failures.Count -gt 0) { return 'CompletedWithFailures' }
    return 'Complete'
}

function Invoke-SetupPipeline {
    Write-Host '========== 新机配置：Windows 基础 -> 重启门 -> 开发环境 ==========' -ForegroundColor Green
    Write-Host "Profile=$Profile；Groups=$((Get-SelectedGroups) -join ',')" -ForegroundColor Cyan
    $resolvedStage = Resolve-SetupStage

    if ($resolvedStage -eq 'AwaitingReboot') {
        Write-Host '当前状态仍在等待重启。' -ForegroundColor Yellow
        Register-ResumeTask
        Request-NextReboot
        return 'AwaitingReboot'
    }

    if ($resolvedStage -eq 'WindowsBase') {
        $script:CurrentStatus = 'Running'
        $script:CurrentDetail = 'Windows base is running.'
        Save-SetupState -Status 'Running' -Detail $script:CurrentDetail -LastCompletedStage 'WindowsBase'
        Install-WindowsBase
        $pending = @(Get-PendingReboot)
        $wslNeeded = (Test-GroupSelected -Group 'Developer') -or (Test-GroupSelected -Group 'AI') -or (Test-GroupSelected -Group 'Engineering')
        if ($pending.Count -gt 0 -and $wslNeeded -and -not $SkipWSL) {
            Save-SetupState -Status 'AwaitingReboot' -Detail ($pending -join ', ') -LastCompletedStage 'WindowsBase'
            Register-ResumeTask
            Request-NextReboot
            return 'AwaitingReboot'
        }

        $baseStatus = Get-FinalStatus
        if ($baseStatus -eq 'Complete') { $baseStatus = 'WindowsBaseComplete' }
        Save-SetupState -Status $baseStatus -Detail 'Windows base stage finished.' -LastCompletedStage 'WindowsBase'
        if ($Stage -eq 'WindowsBase') {
            return $baseStatus
        }
    }

    if ($Stage -eq 'Development' -or $Stage -eq 'Auto') {
        $script:CurrentStatus = 'Running'
        $script:CurrentDetail = 'Development environment is running.'
        if (@(Get-PendingReboot).Count -eq 0) {
            Set-ItemResult -Key 'step:RebootGate' -Name 'Reboot gate' -Stage 'WindowsBase' -Category 'Recovery' -Status 'Succeeded' -Version 'No pending reboot before Development.' -Persist
        } else {
            Set-ItemResult -Key 'step:RebootGate' -Name 'Reboot gate' -Stage 'WindowsBase' -Category 'Recovery' -Status 'Warning' -Error 'Development started while a reboot is still pending.' -Persist
        }
        Save-SetupState -Status 'Running' -Detail $script:CurrentDetail -LastCompletedStage 'WindowsBase'
        Install-DevelopmentEnvironment
        Test-Environment
        $finalStatus = Get-FinalStatus
        Save-SetupState -Status $finalStatus -Detail 'Development environment stage finished.' -LastCompletedStage 'Development'
        Unregister-ResumeTask
        return $finalStatus
    }

    return 'Complete'
}

try {
    Initialize-RunState
    $finalStatus = Invoke-SetupPipeline

    if ($script:Failures.Count -gt 0) {
        Write-Warning "失败或需人工处理项：$($script:Failures -join ', ')"
    } elseif ($finalStatus -eq 'AwaitingReboot') {
        Write-Host '当前等待重启；完成后请重新运行脚本或等待登录续跑任务。' -ForegroundColor Yellow
    } else {
        Write-Host "`n流水线执行完成。" -ForegroundColor Green
    }

    $summary = Get-ItemSummary
    Write-Host "结果状态：$finalStatus" -ForegroundColor Cyan
    Write-Host "软件/步骤：成功 $($summary.Succeeded)，失败 $($summary.Failed)，跳过 $($summary.Skipped)，等待重启 $($summary.AwaitingReboot)"
    Write-Host "状态文件：$script:StateFile"
    Write-Host "虚拟化检测报告：$script:VirtualizationReportFile"
    Write-Host "Docker/WSL 检测报告：$script:DockerReadinessFile"
    Write-Host "Python/uv/conda 分工：$script:PythonPolicyFile"
    Write-Host "环境报告：$script:EnvironmentReportFile"
    Write-Host "日志：$script:LogFile"
    if ($finalStatus -eq 'AwaitingReboot') {
        Write-Host '重启后脚本会从 Development 阶段继续；也可以手动重新运行同一脚本。' -ForegroundColor Yellow
    } else {
        Write-Host '若刚加入 docker-users 或修改了系统 PATH，请重新登录后再验证。' -ForegroundColor Yellow
    }
} catch {
    $script:CurrentStatus = 'Failed'
    $script:CurrentDetail = $_.Exception.Message
    Add-Failure -Name 'Unhandled pipeline error' -Error $_.Exception.Message -Stage $Stage -Category 'Fatal'
    Save-SetupState -Status 'Failed' -Detail $_.Exception.Message -LastCompletedStage $script:LastCompletedStage
    Write-Warning "流水线异常，已保存 Failed 状态：$($_.Exception.Message)"
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}

if (-not $NoPause) {
    Read-Host '按 Enter 键退出' | Out-Null
}