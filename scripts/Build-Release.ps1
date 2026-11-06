param(
    [Parameter(Mandatory)][string]$Version,
    [string]$OutputDirectory = '',
    [switch]$WriteBootstrap,
    [switch]$VerifyBootstrap
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw "Version must be a v-prefixed SemVer tag: $Version" }
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/Configuration.ps1')
. (Join-Path $root 'src/SetupNewPC.Core.ps1')
. (Join-Path $root 'src/Whinset/00-Constants.ps1')
. (Join-Path $root 'src/Whinset/01-Utilities.ps1')
. (Join-Path $root 'scripts/Bootstrap.ps1')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Whinset-release-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$stage = Join-Path ([IO.Path]::GetTempPath()) ('Whinset-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    foreach ($file in @('whinset.ps1','whinset.cmd','whinset.sh','whinset.nu','README.md','LICENSE','CONTRIBUTING.md','SECURITY.md','index.html','.nojekyll')) {
        $source = Join-Path $root $file
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $stage $file) -Force }
    }
    foreach ($directory in @('config','src','docs','examples','tests','legacy','bootstrap','scripts')) {
        $source = Join-Path $root $directory
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $stage $directory) -Recurse -Force }
    }
    $textExtensions = @('.ps1','.psm1','.psd1','.py','.json','.md','.yml','.yaml','.html','.svg','.toml','.txt','.cmd','.sh','.nu')
    foreach ($file in @(Get-ChildItem -LiteralPath $stage -File -Recurse)) {
        $extension = $file.Extension.ToLowerInvariant()
        $isNamedText = $file.Name -in @('LICENSE','.gitignore')
        if ($extension -notin $textExtensions -and -not $isNamedText) { continue }
        $text = [IO.File]::ReadAllText($file.FullName)
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        if ($extension -eq '.cmd') { $text = $text.Replace("`n", "`r`n") }
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($file.FullName, $text, $encoding)
    }

    $archiveName = "Whinset-$Version.zip"
    $archivePath = Join-Path $OutputDirectory $archiveName
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $python) { throw 'Python is required to create the deterministic release archive.' }
    & $python.Source (Join-Path $PSScriptRoot 'Pack-DeterministicZip.py') --source $stage --output $archivePath
    if ($LASTEXITCODE -ne 0) { throw "Deterministic ZIP creation failed with exit code $LASTEXITCODE." }
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bootstrapPath = Join-Path $root 'beatwin.txt'
    if ($WriteBootstrap) {
        $bootstrapArgs = @{
            TemplatePath = Join-Path $root 'bootstrap/beatwin.template.txt'
            Version = $Version
            Sha256 = $archiveHash
            OutputPath = $bootstrapPath
        }
        $null = New-WhinsetBootstrapFile @bootstrapArgs
    }
    $integrity = Test-WhinsetBootstrapIntegrity -Path $bootstrapPath -ArchivePath $archivePath
    if ($VerifyBootstrap -and -not $integrity.Ok) { throw "Bootstrap verification failed: $($integrity.Error)" }
    if ($integrity.Ok -and $integrity.Manifest.Version -ne $Version) { throw "beatwin.txt pins $($integrity.Manifest.Version), not $Version." }
    $bootstrapHash = $null
    if (Test-Path -LiteralPath $bootstrapPath) { $bootstrapHash = (Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    $sumsPath = Join-Path $OutputDirectory 'SHA256SUMS.txt'
    $lines = @("$archiveHash  $archiveName")
    if ($bootstrapHash) { $lines += "$bootstrapHash  beatwin.txt" }
    Write-WhinsetTextFile -Path $sumsPath -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    return [pscustomobject][ordered]@{ Version=$Version; ArchivePath=$archivePath; ArchiveSha256=$archiveHash; BootstrapPath=$(if (Test-Path -LiteralPath $bootstrapPath) { $bootstrapPath } else { $null }); BootstrapSha256=$bootstrapHash; SumsPath=$sumsPath; BootstrapIntegrity=$integrity }
} finally {
    if (Test-Path -LiteralPath $stage) {
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolvedStage.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedStage -Leaf) -like 'Whinset-stage-*') { Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
