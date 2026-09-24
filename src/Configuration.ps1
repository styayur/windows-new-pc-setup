# Pure configuration helpers: safe to dot-source without touching the machine.
function Read-PackageCatalog {
    param([Parameter(Mandatory)][string]$Path)
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $config -or $config -is [array]) { throw 'Config must be a JSON object.' }
    foreach ($property in $config.PSObject.Properties.Name) {
        if ($property -notin @('SchemaVersion', 'Packages')) { throw "Unknown config property: $property" }
    }
    if (-not $config.PSObject.Properties['SchemaVersion'] -or $config.SchemaVersion -is [bool] -or $config.SchemaVersion -is [string] -or $config.SchemaVersion -ne 1) { throw 'SchemaVersion must be 1.' }
    if (-not $config.PSObject.Properties['Packages'] -or $config.Packages -isnot [array]) { throw 'Packages must be an array.' }
    $keys = @{}; $ids = @{}
    foreach ($item in $config.Packages) {
        if ($null -eq $item) { throw 'Package cannot be null.' }
        foreach ($field in @('Key', 'Name', 'Id', 'Source', 'Stage', 'Category', 'Groups')) {
            if (-not $item.PSObject.Properties[$field]) { throw "Missing package field: $field" }
        }
        foreach ($field in $item.PSObject.Properties.Name) {
            if ($field -notin @('Key', 'Name', 'Id', 'Source', 'Stage', 'Category', 'Groups', 'Version', 'Scope')) { throw "Unknown package field: $field" }
        }
        foreach ($field in @('Key', 'Id')) {
            if ($item.$field -isnot [string] -or $item.$field -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Invalid $field" }
        }
        if ($item.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Name)) { throw 'Name must be a nonempty string.' }
        if ($keys.ContainsKey($item.Key) -or $ids.ContainsKey($item.Id)) { throw "Duplicate package Key or Id: $($item.Id)" }
        $keys[$item.Key] = $true; $ids[$item.Id] = $true
        if ($item.Id -eq 'Docker.DockerDesktop') { throw 'Use -EnableDocker for Docker Desktop so its prerequisites are checked.' }
        if ($item.Source -isnot [string] -or $item.Source -notin @('winget', 'msstore')) { throw "Invalid Source: $($item.Source)" }
        if ($item.Stage -isnot [string] -or $item.Stage -notin @('WindowsBase', 'Development')) { throw "Invalid Stage: $($item.Stage)" }
        $groups = @('Core', 'Developer', 'AI', 'Engineering', 'Personal')
        if ($item.Category -isnot [string] -or $item.Category -notin $groups) { throw "Invalid Category: $($item.Category)" }
        if ($item.Groups -isnot [array] -or $item.Groups.Count -eq 0) { throw 'Groups must be a nonempty array.' }
        foreach ($group in $item.Groups) { if ($group -isnot [string] -or $group -notin $groups) { throw "Invalid Group: $group" } }
        if ($item.PSObject.Properties['Scope'] -and ($item.Scope -isnot [string] -or $item.Scope -notin @('user', 'machine'))) { throw 'Scope must be user or machine.' }
        if ($item.PSObject.Properties['Version']) {
            if ($item.Version -isnot [string] -or $item.Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw 'Invalid Version.' }
            if ($item.Source -eq 'msstore') { throw 'Version is not supported for msstore packages.' }
            if ($item.PSObject.Properties['Scope']) { throw 'Version and Scope cannot be combined: WinGet export cannot reliably verify version per scope.' }
        }
        $item
    }
}

function Test-PackageSelected {
    param([string]$Key)
    return @($script:SelectedPackages | Where-Object { $_.Key -eq $Key }).Count -gt 0
}

function Test-PackageReady {
    param([string]$Key)
    $item = $script:SelectedPackages | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $item) { return $false }
    $record = Get-ItemResult -Key "winget:$($item.Id)"
    return ($null -ne $record -and $record.Status -eq 'Succeeded')
}

function Get-ConfigurationHash {
    param([Parameter(Mandatory)]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 20 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PackageArguments {
    param([Parameter(Mandatory)]$Item)
    $arguments = @()
    if ($Item.PSObject.Properties['Version']) { $arguments += @('--version', $Item.Version) }
    if ($Item.PSObject.Properties['Scope']) { $arguments += @('--scope', $Item.Scope) }
    return $arguments
}

function Test-SetupAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-SetupPrerequisites {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Execution requires Windows.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Run 64-bit PowerShell.' }
    if (-not (Test-SetupAdministrator)) { throw 'Open PowerShell as administrator using your own Windows account, then rerun the same command.' }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 22000 -or [int]$os.ProductType -ne 1) { throw 'This script supports Windows 11 client (build 22000+) only.' }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'WinGet is missing. Install/update Microsoft App Installer, open a new terminal, then retry: https://aka.ms/getwinget' }
    $version = Invoke-ExternalCommand -FilePath $winget.Source -ArgumentList @('--version') -TimeoutSeconds 30
    if (-not $version.Success -or $version.Output -notmatch 'v?(\d+\.\d+\.\d+)' -or [version]$Matches[1] -lt [version]'1.8.0') { throw 'WinGet 1.8+ is required. Update Microsoft App Installer first.' }
}
