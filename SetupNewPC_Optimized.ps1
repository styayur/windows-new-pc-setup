[CmdletBinding()]
param(
    [switch]$SkipWinUtil,
    [switch]$SkipWSL,
    [switch]$SkipStoreApps,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Failures = @()

# 获取管理员权限
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
    $hostCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($hostCommand) {
        $hostExe = $hostCommand.Source
    } else {
        $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $elevatedArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($SkipWinUtil) { $elevatedArgs += '-SkipWinUtil' }
    if ($SkipWSL) { $elevatedArgs += '-SkipWSL' }
    if ($SkipStoreApps) { $elevatedArgs += '-SkipStoreApps' }
    if ($NoPause) { $elevatedArgs += '-NoPause' }
    Start-Process -FilePath $hostExe -ArgumentList $elevatedArgs -Verb RunAs
    exit
}

# 初始化日志
$logDir = Join-Path $env:ProgramData 'SetupNewPC'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'setup.log'
$transcriptStarted = $false
try {
    Start-Transcript -Path $logFile -Append -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Warning "无法启动日志：$($_.Exception.Message)"
}

function Add-Failure {
    param([Parameter(Mandatory)][string]$Name)
    $script:Failures += $Name
}

function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'winget',
        [string[]]$ExtraArgs = @()
    )
    Write-Host "安装 $Id ..." -ForegroundColor Cyan
    $wingetArgs = @(
        'install', '--id', $Id, '--exact', '--source', $Source,
        '--accept-source-agreements', '--accept-package-agreements',
        '--silent', '--disable-interactivity'
    )
    if ($ExtraArgs.Count -gt 0) { $wingetArgs += $ExtraArgs }
    try {
        & winget @wingetArgs
        if ($LASTEXITCODE -ne 0) {
            Add-Failure $Id
            Write-Warning "$Id 安装失败，退出码 $LASTEXITCODE"
            return $false
        }
        return $true
    } catch {
        Add-Failure $Id
        Write-Warning "$Id 安装异常：$($_.Exception.Message)"
        return $false
    }
}

function Install-AppGroup {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Ids
    )
    Write-Host "`n$Title" -ForegroundColor Green
    foreach ($id in $Ids) {
        Invoke-Winget -Id $id | Out-Null
    }
    Update-SessionPath
}

Write-Host '========== 开始装机流水线 ==========' -ForegroundColor Green

# 系统优化
Invoke-Winget -Id 'HiBitSoftware.HiBitUninstaller' | Out-Null
if (-not $SkipWinUtil) {
    Write-Host "`n启动 WinUtil，请完成优化后退出。" -ForegroundColor Yellow
    $legacyShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $legacyShell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://christitus.com/winutil' | iex"
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'WinUtil'
        Write-Warning 'WinUtil 未正常结束。'
    }
}

$basicApps = @(
    '7zip.7zip',
    'ClashVergeRev.ClashVergeRev',
    'Git.Git',
    'GitHub.cli',
    'Google.Chrome',
    'Bopsoft.Listary',
    'Microsoft.VisualStudioCode',
    'Posit.RStudio',
    'RProject.R',
    'Valve.Steam'
)
Install-AppGroup -Title '安装基础软件' -Ids $basicApps

# Python 与 Node.js
Write-Host "`n安装 Python 3.13 与 Node.js" -ForegroundColor Green
Invoke-Winget -Id 'Python.Python.3.13' -ExtraArgs @(
    '--override', '/passive InstallAllUsers=1 PrependPath=1'
) | Out-Null
Invoke-Winget -Id 'OpenJS.NodeJS' | Out-Null
Update-SessionPath

$specialApps = @(
    'farion1231.CC-Switch',
    'Logseq.Logseq',
    'Rizonesoft.Notepad3',
    'PixPin.PixPin',
    'Daum.PotPlayer',
    'Alex313031.Thorium'
)
Install-AppGroup -Title '安装常用工具' -Ids $specialApps

# AI 工具
if (-not $SkipStoreApps) {
    Write-Host "`n安装 ChatGPT 商店版" -ForegroundColor Green
    Invoke-Winget -Id '9PLM9XGG6VKS' -Source 'msstore' | Out-Null
}
$aiApps = @('OpenAI.Codex', 'Anthropic.Claude', 'Anysphere.Cursor')
Install-AppGroup -Title '安装 AI 工具' -Ids $aiApps

# WSL 与 Docker
Write-Host "`n配置 WSL、Docker 与 Git LFS" -ForegroundColor Green
if (-not $SkipWSL) {
    & wsl.exe --install
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'WSL'
        Write-Warning 'WSL 安装未完成，可能需要重启后重试。'
    }
}
Invoke-Winget -Id 'Docker.DockerDesktop' | Out-Null
Update-SessionPath
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($git) {
    & $git.Source lfs install
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'Git LFS'
        Write-Warning 'Git LFS 初始化失败。'
    }
} else {
    Add-Failure 'Git LFS'
    Write-Warning '未找到 git.exe，跳过 Git LFS。'
}

$engineeringApps = @(
    'Anaconda.Anaconda3',
    'Postman.Postman',
    'DBeaver.DBeaver.Community',
    'KiCad.KiCad',
    'FreeCAD.FreeCAD',
    'Mobatek.MobaXterm'
)
Install-AppGroup -Title '安装工程与数据工具' -Ids $engineeringApps

# 编程语言环境
Write-Host "`n安装 Java、Go、Rust 与 MinGW" -ForegroundColor Green
Invoke-Winget -Id 'Microsoft.OpenJDK.21' | Out-Null
Invoke-Winget -Id 'GoLang.Go' | Out-Null
Invoke-Winget -Id 'Rustlang.Rustup' | Out-Null
Invoke-Winget -Id 'BrechtSanders.WinLibs.POSIX.UCRT' | Out-Null
Update-SessionPath

$java = Get-Command java.exe -ErrorAction SilentlyContinue
if ($java) {
    $jdkHome = Split-Path (Split-Path $java.Source -Parent) -Parent
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdkHome, 'Machine')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$jdkHome\bin*") {
        $newPath = "$machinePath;$jdkHome\bin"
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    }
    Write-Host "JAVA_HOME=$jdkHome" -ForegroundColor Green
} else {
    Add-Failure 'JAVA_HOME'
    Write-Warning '未找到 java.exe，无法配置 JAVA_HOME。'
}

$go = Get-Command go.exe -ErrorAction SilentlyContinue
if ($go) {
    & $go.Source env -w "GOPATH=$env:USERPROFILE\go"
}
$rustup = Get-Command rustup.exe -ErrorAction SilentlyContinue
if ($rustup) {
    & $rustup.Source default stable
}

Write-Host "`n商业软件需自行安装：" -ForegroundColor Magenta
Write-Host '1. MATLAB 与 Simulink'
Write-Host '2. AutoCAD、SolidWorks 与 Ansys'
Write-Host '3. Keil、STM32CubeIDE 与 Vivado'

# 环境验证
Write-Host "`n环境验证" -ForegroundColor Green
$checks = @(
    @{ Name = 'Python'; Exe = 'python.exe'; Args = @('--version') },
    @{ Name = 'Node.js'; Exe = 'node.exe'; Args = @('--version') },
    @{ Name = 'Java'; Exe = 'java.exe'; Args = @('-version') },
    @{ Name = 'Go'; Exe = 'go.exe'; Args = @('version') },
    @{ Name = 'Rust'; Exe = 'rustc.exe'; Args = @('--version') },
    @{ Name = 'GCC'; Exe = 'gcc.exe'; Args = @('--version') }
)
foreach ($check in $checks) {
    $command = Get-Command $check.Exe -ErrorAction SilentlyContinue
    if ($command) {
        & $command.Source @($check.Args)
    } else {
        Write-Warning "$($check.Name) 未加入当前 PATH。"
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Warning "失败项：$($script:Failures -join ', ')"
} else {
    Write-Host "`n全部流水线执行完成。" -ForegroundColor Green
}
Write-Host '建议重启，再打开新 PowerShell 验证环境。' -ForegroundColor Yellow
Write-Host "日志：$logFile"

if (-not $NoPause) {
    Read-Host '按 Enter 键退出' | Out-Null
}
if ($transcriptStarted) {
    Stop-Transcript | Out-Null
}
