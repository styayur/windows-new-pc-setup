<#
.SYNOPSIS
    Install SetupNewPC applications one by one with an explicit confirmation.

.DESCRIPTION
    Reuses the software catalog from SetupNewPC_Optimized.ps1, but never installs
    an application without a per-application Y confirmation. Already installed
    applications are reported and skipped.

.EXAMPLE
    .\Install-Applications.WithConfirmation.ps1 -Profile Full

.EXAMPLE
    .\Install-Applications.WithConfirmation.ps1 -Profile AI -IncludePersonal
#>
[CmdletBinding()]
param(
    [ValidateSet('Minimal', 'Developer', 'AI', 'Engineering', 'Full')]
    [string]$Profile = 'Full',

    [ValidateSet('Core', 'Developer', 'AI', 'Engineering', 'Personal')]
    [string[]]$ExtraGroups = @(),

    [switch]$IncludePersonal,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
    $hostExe = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($hostExe) {
        $hostPath = $hostExe.Source
    } else {
        $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Profile', $Profile)
    if ($ExtraGroups.Count -gt 0) { $argsList += @('-ExtraGroups', ($ExtraGroups -join ',')) }
    if ($IncludePersonal) { $argsList += '-IncludePersonal' }
    if ($NoPause) { $argsList += '-NoPause' }
    Start-Process -FilePath $hostPath -ArgumentList $argsList -Verb RunAs
    exit
}

$mainScript = Join-Path $PSScriptRoot 'SetupNewPC_Optimized.ps1'
if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "Cannot find SetupNewPC_Optimized.ps1 next to this script: $mainScript"
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Cannot parse software catalog source: $($parseErrors[0].Message)"
}

$requiredFunctions = @('Get-SelectedGroups', 'Get-SoftwareCatalog', 'Test-ItemInSelectedGroups')
foreach ($requiredFunction in $requiredFunctions) {
    $definition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $requiredFunction
    }, $true) | Select-Object -First 1
    if (-not $definition) {
        throw "Function not found in SetupNewPC_Optimized.ps1: $requiredFunction"
    }
    Invoke-Expression $definition.Extent.Text
}

$logDir = Join-Path $env:ProgramData 'SetupNewPC'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'interactive-app-install.log'
$transcriptStarted = $false
try {
    Start-Transcript -Path $logFile -Append -Force | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Warning "无法启动日志：$($_.Exception.Message)"
}

function Test-WingetInstalled {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'winget'
    )
    try {
        $output = & winget list --id $Id --exact --source $Source --accept-source-agreements --disable-interactivity 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape($Id))
    } catch {
        return $false
    }
}

function Invoke-ConfirmedWinget {
    param(
        [Parameter(Mandatory)]$Item
    )

    if (Test-WingetInstalled -Id $Item.Id -Source $Item.Source) {
        Write-Host "已安装，跳过：$($Item.Name)" -ForegroundColor DarkGray
        return [pscustomobject]@{ Name=$Item.Name; Id=$Item.Id; Status='ALREADY'; Detail='Already installed' }
    }

    Write-Host ''
    Write-Host "应用：$($Item.Name)" -ForegroundColor Cyan
    Write-Host "ID：$($Item.Id)"
    Write-Host "来源：$($Item.Source)"
    $answer = Read-Host '是否安装？输入 Y 安装，其他输入跳过'
    if ($answer -notmatch '^[Yy]$') {
        Write-Host "已跳过：$($Item.Name)" -ForegroundColor Yellow
        return [pscustomobject]@{ Name=$Item.Name; Id=$Item.Id; Status='SKIPPED'; Detail='User skipped' }
    }

    try {
        $output = & winget install --id $Item.Id --exact --source $Item.Source --accept-source-agreements --accept-package-agreements --silent --disable-interactivity 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $output -match 'already installed|No applicable|No available upgrade|已安装') {
            Write-Host "安装完成：$($Item.Name)" -ForegroundColor Green
            return [pscustomobject]@{ Name=$Item.Name; Id=$Item.Id; Status='INSTALLED'; Detail='Winget success' }
        }
        Write-Warning "安装失败：$($Item.Name)，退出码 $LASTEXITCODE"
        return [pscustomobject]@{ Name=$Item.Name; Id=$Item.Id; Status='FAILED'; Detail=$output.Trim() }
    } catch {
        Write-Warning "安装异常：$($Item.Name)，$($_.Exception.Message)"
        return [pscustomobject]@{ Name=$Item.Name; Id=$Item.Id; Status='FAILED'; Detail=$_.Exception.Message }
    }
}

$selectedGroups = @(Get-SelectedGroups)
$items = @(Get-SoftwareCatalog | Where-Object { Test-ItemInSelectedGroups -Item $_ })
$results = @()

Write-Host '========== 逐项确认安装 ==========' -ForegroundColor Green
Write-Host "Profile=$Profile；Groups=$($selectedGroups -join ',')；应用数=$($items.Count)" -ForegroundColor Cyan
Write-Host '每个应用都必须单独确认，输入 Y 才会安装。' -ForegroundColor Yellow

foreach ($item in $items) {
    $results += Invoke-ConfirmedWinget -Item $item
}

Write-Host ''
Write-Host '安装结果：' -ForegroundColor Green
$results | Format-Table Name, Id, Status, Detail -AutoSize
Write-Host "日志：$logFile"

if ($transcriptStarted) {
    Stop-Transcript | Out-Null
}

if (-not $NoPause) {
    Read-Host '按 Enter 键退出' | Out-Null
}