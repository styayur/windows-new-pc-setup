# Pure configuration helpers: safe to dot-source without touching the machine.
function Read-PackageCatalog {
    param([Parameter(Mandatory)][string]$Path)
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $config -or $config -is [array]) { throw 'Config must be a JSON object.' }
    $allowedTopLevel = @('SchemaVersion', 'CatalogVersion', 'Profiles', 'Groups', 'Packages')
    foreach ($property in $config.PSObject.Properties.Name) {
        if ($property -notin $allowedTopLevel) { throw "Unknown config property: $property" }
    }
    if (-not $config.PSObject.Properties['SchemaVersion'] -or $config.SchemaVersion -is [bool] -or $config.SchemaVersion -is [string] -or $config.SchemaVersion -notin @(1, 2)) { throw 'SchemaVersion must be 1 or 2.' }
    if (-not $config.PSObject.Properties['Packages'] -or $config.Packages -isnot [array]) { throw 'Packages must be an array.' }
    if ($config.SchemaVersion -eq 1) {
        foreach ($property in $config.PSObject.Properties.Name) {
            if ($property -notin @('SchemaVersion', 'Packages')) { throw "Unknown config property: $property" }
        }
    } else {
        if (-not $config.PSObject.Properties['CatalogVersion'] -or $config.CatalogVersion -isnot [string] -or [string]::IsNullOrWhiteSpace($config.CatalogVersion)) { throw 'CatalogVersion must be a nonempty string.' }
        if (-not $config.PSObject.Properties['Profiles'] -or $null -eq $config.Profiles -or $config.Profiles -is [array]) { throw 'Profiles must be an object.' }
        if (-not $config.PSObject.Properties['Groups'] -or $config.Groups -isnot [array] -or $config.Groups.Count -eq 0) { throw 'Groups must be a nonempty array.' }
    }

    $keys = @{}
    $identities = @{}
    $allowedFields = @('Key','Name','Vendor','Id','Source','Architecture','Scope','VersionPolicy','Stage','Category','Groups','Privilege','Dependencies','Conflicts','ExpectedState','Reboot','Recovery','Version')
    $groups = @('Core', 'Developer', 'AI', 'Engineering', 'Personal')
    foreach ($item in $config.Packages) {
        if ($null -eq $item) { throw 'Package cannot be null.' }
        $requiredFields = @('Key', 'Name', 'Id', 'Source', 'Stage', 'Category', 'Groups')
        if ($config.SchemaVersion -eq 2) {
            $requiredFields += @('Vendor', 'Architecture', 'Scope', 'VersionPolicy', 'Privilege', 'Dependencies', 'Conflicts', 'ExpectedState', 'Reboot', 'Recovery')
        }
        foreach ($field in $requiredFields) {
            if (-not $item.PSObject.Properties[$field]) { throw "Missing package field: $field" }
        }
        foreach ($field in $item.PSObject.Properties.Name) {
            if ($field -notin $allowedFields) { throw "Unknown package field: $field" }
        }
        foreach ($field in @('Key', 'Id')) {
            if ($item.$field -isnot [string] -or $item.$field -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw "Invalid $field" }
        }
        if ($item.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Name)) { throw 'Name must be a nonempty string.' }
        if ($item.Source -isnot [string] -or $item.Source -notin @('winget', 'msstore')) { throw "Invalid Source: $($item.Source)" }
        $identity = "$($item.Source)|$($item.Id)"
        if ($keys.ContainsKey($item.Key) -or $identities.ContainsKey($identity)) { throw "Duplicate package Key or Source/Id: $($item.Source)/$($item.Id)" }
        $keys[$item.Key] = $true
        $identities[$identity] = $true
        if ($item.Id -eq 'Docker.DockerDesktop') { throw 'Use -EnableDocker for Docker Desktop so its prerequisites are checked.' }
        if ($item.Stage -isnot [string] -or $item.Stage -notin @('WindowsBase', 'Development')) { throw "Invalid Stage: $($item.Stage)" }
        if ($item.Category -isnot [string] -or $item.Category -notin $groups) { throw "Invalid Category: $($item.Category)" }
        if ($item.Groups -isnot [array] -or $item.Groups.Count -eq 0) { throw 'Groups must be a nonempty array.' }
        foreach ($group in $item.Groups) { if ($group -isnot [string] -or $group -notin $groups) { throw "Invalid Group: $group" } }
        if ($item.PSObject.Properties['Scope'] -and ($item.Scope -isnot [string] -or $item.Scope -notin @('auto', 'user', 'machine'))) { throw 'Scope must be auto, user or machine.' }
        if ($item.PSObject.Properties['Version']) {
            if ($item.Version -isnot [string] -or $item.Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { throw 'Invalid Version.' }
            if ($item.Source -eq 'msstore') { throw 'Version is not supported for msstore packages.' }
            if ($item.PSObject.Properties['Scope'] -and $item.Scope -in @('user', 'machine')) { throw 'Version and an explicit Scope cannot be combined: WinGet export cannot reliably verify version per scope.' }
        }
        if ($config.SchemaVersion -eq 2) {
            if ($item.Vendor -isnot [string] -or [string]::IsNullOrWhiteSpace($item.Vendor)) { throw 'Vendor must be a nonempty string.' }
            if ($item.Architecture -isnot [string] -or $item.Architecture -notin @('auto', 'x64', 'arm64', 'neutral')) { throw "Invalid Architecture: $($item.Architecture)" }
            if ($item.VersionPolicy -isnot [string] -or $item.VersionPolicy -notin @('latest', 'pinned')) { throw "Invalid VersionPolicy: $($item.VersionPolicy)" }
            if ($item.Privilege -isnot [string] -or $item.Privilege -notin @('user', 'elevated')) { throw "Invalid Privilege: $($item.Privilege)" }
            if ($item.Dependencies -isnot [array]) { throw 'Dependencies must be an array.' }
            if ($item.Conflicts -isnot [array]) { throw 'Conflicts must be an array.' }
            if ($item.ExpectedState -isnot [string] -or $item.ExpectedState -notin @('installed', 'absent')) { throw "Invalid ExpectedState: $($item.ExpectedState)" }
            if ($item.Reboot -isnot [string] -or $item.Reboot -notin @('never', 'possible', 'required')) { throw "Invalid Reboot: $($item.Reboot)" }
            if ($null -eq $item.Recovery -or $item.Recovery -is [array] -or -not $item.Recovery.PSObject.Properties['Class']) { throw 'Recovery must be an object with Class and instructions.' }
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
    if ($Item.PSObject.Properties['Scope'] -and $Item.Scope -in @('user', 'machine')) { $arguments += @('--scope', $Item.Scope) }
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
