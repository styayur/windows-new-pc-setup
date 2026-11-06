#requires -Version 5.1
param([string]$EvidencePath = '', [switch]$RequireGitBash, [switch]$RequireNushell)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/SetupNewPC.Core.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Whinset-shell-' + [guid]::NewGuid().ToString('N'))
$copy = Join-Path $testRoot ('space ' + [char]0x96ea)
$results = New-Object Collections.Generic.List[object]
$utf8 = New-Object Text.UTF8Encoding($false)
function Assert($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Quote-Bash([string]$Value) { return "'" + $Value.Replace("'", "'\''") + "'" }
function Run-Shell($Shell, [string[]]$Arguments) {
    $core = Join-Path $copy 'whinset.ps1'
    switch ($Shell.Kind) {
        'powershell' { return (Invoke-ExternalCommand $Shell.Path (@('-NoLogo','-NoProfile','-File',$core) + $Arguments)) }
        'cmd' {
            $command = '@echo off' + "`r`nchcp 65001 >nul`r`ncall " + (ConvertTo-NativeArgument (Join-Path $copy 'whinset.cmd')) + ' ' + (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ') + "`r`nexit /b %errorlevel%`r`n"
            $path = Join-Path $testRoot 'invoke.cmd'
            [IO.File]::WriteAllText($path,$command,$utf8)
            return (Invoke-ExternalCommand $Shell.Path @('/d','/c',$path))
        }
        'bash' {
            $command = 'bash ' + (Quote-Bash ((Join-Path $copy 'whinset.sh').Replace('\','/'))) + ' ' + (($Arguments | ForEach-Object { Quote-Bash $_ }) -join ' ')
            return (Invoke-ExternalCommand $Shell.Path @('--noprofile','--norc','-c',$command))
        }
        'nu' { return (Invoke-ExternalCommand $Shell.Path (@('--no-config-file',(Join-Path $copy 'whinset.nu')) + $Arguments)) }
    }
}
try {
    New-Item -ItemType Directory $copy -Force | Out-Null
    foreach ($name in @('src','config','whinset.ps1','whinset.cmd','whinset.sh','whinset.nu')) { Copy-Item (Join-Path $root $name) $copy -Recurse }
    $shells = @(
        [pscustomobject]@{ Name='PowerShell 5.1'; Kind='powershell'; Path=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'); Required=$true },
        [pscustomobject]@{ Name='PowerShell 7'; Kind='powershell'; Path=(Get-Command pwsh.exe).Source; Required=$true },
        [pscustomobject]@{ Name='CMD launcher'; Kind='cmd'; Path=$env:ComSpec; Required=$true }
    )
    $bash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
    $nu = Get-Command nu.exe -ErrorAction SilentlyContinue
    $shells += [pscustomobject]@{ Name='Git Bash adapter'; Kind='bash'; Path=$bash; Required=[bool]$RequireGitBash }
    $shells += [pscustomobject]@{ Name='Nushell adapter'; Kind='nu'; Path=$(if ($nu) { $nu.Source } else { '' }); Required=[bool]$RequireNushell }
    foreach ($shell in $shells) {
        if (-not $shell.Path -or -not (Test-Path -LiteralPath $shell.Path)) {
            $status = if ($shell.Required) { 'FAIL' } else { 'NOT RUN' }
            $results.Add([pscustomobject]@{ Shell=$shell.Name; Test='availability'; Status=$status; Detail='Executable unavailable' })
            continue
        }
        foreach ($case in @('json-unicode-path','quoted-argument','stderr-and-exit','offline-plan')) {
            try {
                switch ($case) {
                    'json-unicode-path' {
                        $r = Run-Shell $shell @('version','-Json')
                        Assert ($r.ExitCode -eq 0 -and -not $r.Error) "Exit $($r.ExitCode): $($r.Error) $($r.Output)"
                        $json = $r.Output | ConvertFrom-Json
                        Assert ($json.RepositoryRoot -eq $copy) 'Unicode/spaced repository path changed'
                    }
                    'quoted-argument' {
                        $query = 'spaces ' + [char]0x96ea + ' "quoted" C:\tail\'
                        $r = Run-Shell $shell @('resolve',$query,'-Json')
                        Assert ($r.ExitCode -eq 2 -and -not $r.Error) "Exit $($r.ExitCode): $($r.Error) $($r.Output)"
                        Assert (($r.Output | ConvertFrom-Json).Query -ceq $query) "Argument changed: $($r.Output)"
                    }
                    'stderr-and-exit' {
                        $r = Run-Shell $shell @('plan','-Profile','DoesNotExist','-Offline')
                        Assert ($r.ExitCode -eq 2) "Expected exit 2, got $($r.ExitCode)"
                        Assert (-not $r.Output -and $r.Error -like '*whinset:*') "Expected stderr only: $($r.Output) $($r.Error)"
                    }
                    'offline-plan' {
                        $r = Run-Shell $shell @('plan','-Profile','Minimal','-Offline','-Json')
                        Assert ($r.ExitCode -eq 0 -and -not $r.Error) "Exit $($r.ExitCode): $($r.Error) $($r.Output)"
                        Assert (($r.Output | ConvertFrom-Json).SchemaVersion -eq 2) 'Invalid plan JSON'
                    }
                }
                $results.Add([pscustomobject]@{ Shell=$shell.Name; Test=$case; Status='PASS'; Detail='' })
                Write-Output "PASS $($shell.Name): $case"
            } catch {
                $results.Add([pscustomobject]@{ Shell=$shell.Name; Test=$case; Status='FAIL'; Detail=[string]$_ })
                Write-Output "FAIL $($shell.Name): $case : $_"
            }
        }
    }
    Import-Module (Join-Path $copy 'src/Whinset.psd1') -Force
    $exports = @((Get-Module Whinset).ExportedFunctions.Keys)
    Assert ($exports.Count -eq 1 -and $exports[0] -eq 'Invoke-Whinset') 'Unexpected public module functions'
    Assert ([bool](& (Get-Module Whinset) { Get-Command Invoke-WhinsetElevatedWorker -ErrorAction Stop })) 'Private worker entrypoint unavailable'
    $results.Add([pscustomobject]@{ Shell='module'; Test='exports and private worker'; Status='PASS'; Detail='' })
} finally {
    if ($EvidencePath) {
        $payload = [ordered]@{ SchemaVersion=1; Suite='real read-only CLI shell invocations'; PowerShellVersion=$PSVersionTable.PSVersion.ToString(); Results=@($results.ToArray()) }
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath),($payload | ConvertTo-Json -Depth 8),$utf8)
    }
    Remove-Module Whinset -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'Whinset-shell-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
$failed = @($results | Where-Object Status -eq FAIL).Count
Write-Output "$(@($results | Where-Object Status -eq PASS).Count) passed; $failed failed"
if ($failed) { exit 1 }
exit 0
