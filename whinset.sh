#!/usr/bin/env bash
# Experimental Git Bash adapter. All execution remains in the PowerShell core.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -W)"
if command -v pwsh.exe >/dev/null 2>&1; then
  exec pwsh.exe -NoLogo -NoProfile -File "$root/whinset.ps1" "$@"
fi
exec powershell.exe -NoLogo -NoProfile -File "$root/whinset.ps1" "$@"
