function Get-WhinsetVersionString { return $script:WhinsetVersion }

function Get-WhinsetRepositoryRoot {
    if ($script:WhinsetRoot) { return $script:WhinsetRoot }
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

function ConvertTo-WhinsetCanonicalValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [datetime] -or $Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $ordered[$key] = ConvertTo-WhinsetCanonicalValue -Value $Value[$key]
        }
        return [pscustomobject]$ordered
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        foreach ($name in @($Value.PSObject.Properties.Name | Sort-Object)) {
            $ordered[$name] = ConvertTo-WhinsetCanonicalValue -Value $Value.$name
        }
        return [pscustomobject]$ordered
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) { $items += ,(ConvertTo-WhinsetCanonicalValue -Value $item) }
        return $items
    }
    return $Value
}

function ConvertTo-WhinsetJson {
    param([AllowNull()]$Value, [int]$Depth = 30, [switch]$Compress)
    $json = ConvertTo-Json -InputObject $Value -Depth $Depth -Compress:$Compress
    if ($null -eq $json) { return 'null' }
    return $json
}

function Get-WhinsetCanonicalJson {
    param([AllowNull()]$Value, [int]$Depth = 50)
    return (ConvertTo-WhinsetJson -Value (ConvertTo-WhinsetCanonicalValue -Value $Value) -Depth $Depth -Compress)
}

function Get-WhinsetHashText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-WhinsetHashFile {
    param([Parameter(Mandatory)][string]$Path)
    # Avoid autoloading a PS7-only Get-FileHash function in a nested PS5.1 host.
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Write-WhinsetTextFile {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-WhinsetJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "JSON file not found: $Path" }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) { throw "JSON file is empty: $Path" }
    return ($text | ConvertFrom-Json)
}

function Write-WhinsetJsonFileAtomically {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 40)
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    Write-WhinsetTextFile -Path $temp -Text ((ConvertTo-WhinsetJson -Value $Value -Depth $Depth) + [Environment]::NewLine)
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($temp, $Path, "$Path.bak")
    } else {
        [IO.File]::Move($temp, $Path)
    }
}

function Append-WhinsetJsonLine {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $encoding = New-Object Text.UTF8Encoding($false)
    $line = (ConvertTo-WhinsetJson -Value $Value -Depth 30 -Compress) + [Environment]::NewLine
    [IO.File]::AppendAllText($Path, $line, $encoding)
}

function Get-WhinsetTimestamp { return (Get-Date).ToUniversalTime().ToString('o') }

function Get-WhinsetHostArchitecture {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch -Regex ($arch) {
        '^(AMD64|x64)$' { return 'x64' }
        '^(ARM64)$' { return 'arm64' }
        '^(x86)$' { return 'x86' }
        default { return ([string]$arch).ToLowerInvariant() }
    }
}

function Get-WhinsetBootId {
    if ($env:WHINSET_BOOT_ID) { return [string]$env:WHINSET_BOOT_ID }
    try { return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc().ToString() }
    catch { return 'unknown' }
}

function Get-WhinsetMachineIdentity {
    $computer = $env:COMPUTERNAME
    $sid = $null
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    catch { $sid = "$env:USERDOMAIN\$env:USERNAME" }
    return [ordered]@{ ComputerName = $computer; UserSid = $sid }
}

function Test-WhinsetIsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Resolve-WhinsetAbsolutePath {
    param([Parameter(Mandatory)][string]$Path, [string]$BasePath = (Get-Location).Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}
