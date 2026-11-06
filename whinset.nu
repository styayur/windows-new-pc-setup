#!/usr/bin/env nu
# Experimental argument-forwarding adapter; no installation logic lives here.
def --wrapped main [...args: string] {
    let core = ($env.FILE_PWD | path join 'whinset.ps1')
    if (which pwsh.exe | is-not-empty) {
        ^pwsh.exe -NoLogo -NoProfile -File $core ...$args
    } else {
        ^powershell.exe -NoLogo -NoProfile -File $core ...$args
    }
    exit $env.LAST_EXIT_CODE
}
