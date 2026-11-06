function Get-WhinsetBootstrapManifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Bootstrap file not found: $Path" }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $versionMatch = [regex]::Match($text, '(?m)^\s*\$WhinsetVersion\s*=\s*''([^'']+)''\s*$')
    $shaMatch = [regex]::Match($text, '(?m)^\s*\$WhinsetArchiveSha256\s*=\s*''([0-9a-fA-F]{64})''\s*$')
    $urlMatch = [regex]::Match($text, '(?m)^\s*\$WhinsetAssetUrl\s*=\s*''([^'']+)''\s*$')
    if (-not $versionMatch.Success) { throw 'Bootstrap is missing a valid WhinsetVersion.' }
    if (-not $shaMatch.Success) { throw 'Bootstrap is missing a valid 64-character WhinsetArchiveSha256.' }
    if (-not $urlMatch.Success) { throw 'Bootstrap is missing WhinsetAssetUrl.' }
    $version = $versionMatch.Groups[1].Value
    $sha = $shaMatch.Groups[1].Value.ToLowerInvariant()
    $url = $urlMatch.Groups[1].Value
    $expectedUrl = "https://github.com/styayur/whinset/releases/download/$version/Whinset-$version.zip"
    if ($url -ne $expectedUrl) { throw "Bootstrap URL is not the expected pinned release asset. Expected $expectedUrl" }
    if ($text -match '(?i)Invoke[-]Expression|[-]EncodedCommand|FromBase64String|/main/|/master/') { throw 'Bootstrap contains a forbidden dynamic or unpinned download pattern.' }
    return [pscustomobject][ordered]@{ Path=(Resolve-WhinsetAbsolutePath -Path $Path); Version=$version; Sha256=$sha; AssetUrl=$url; Text=$text }
}

function New-WhinsetBootstrapFile {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$OutputPath
    )
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'A 64-character SHA-256 is required.' }
    if ($Version -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw "Invalid Whinset version: $Version" }
    $url = "https://github.com/styayur/whinset/releases/download/$Version/Whinset-$Version.zip"
    $text = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $text = $text.Replace('__WHINSET_VERSION__',$Version).Replace('__WHINSET_SHA256__',$Sha256.ToLowerInvariant()).Replace('__WHINSET_URL__',$url)
    if ($text -match '__WHINSET_') { throw 'Bootstrap template still contains unresolved placeholders.' }
    Write-WhinsetTextFile -Path $OutputPath -Text ($text.TrimEnd() + [Environment]::NewLine)
    return (Get-WhinsetBootstrapManifest -Path $OutputPath)
}

function Test-WhinsetBootstrapArtifact {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$ArchivePath)
    if (-not (Test-Path -LiteralPath $ArchivePath)) { return [pscustomobject][ordered]@{ Ok=$false; Expected=$Manifest.Sha256; Actual=$null; Error='Archive not found.' } }
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject][ordered]@{ Ok=($actual -eq $Manifest.Sha256.ToLowerInvariant()); Expected=$Manifest.Sha256; Actual=$actual; Error=$(if ($actual -eq $Manifest.Sha256.ToLowerInvariant()) { '' } else { 'SHA-256 mismatch.' }) }
}

function Test-WhinsetBootstrapIntegrity {
    param([Parameter(Mandatory)][string]$Path, [string]$ArchivePath = '')
    try {
        $manifest = Get-WhinsetBootstrapManifest -Path $Path
        $artifact = $null
        if ($ArchivePath) { $artifact = Test-WhinsetBootstrapArtifact -Manifest $manifest -ArchivePath $ArchivePath }
        $ok = $true
        if ($artifact -and -not $artifact.Ok) { $ok = $false }
        return [pscustomobject][ordered]@{ Ok=$ok; Manifest=$manifest; Artifact=$artifact; Error=$(if ($ok) { '' } else { $artifact.Error }) }
    } catch {
        return [pscustomobject][ordered]@{ Ok=$false; Manifest=$null; Artifact=$null; Error=$_.Exception.Message }
    }
}
