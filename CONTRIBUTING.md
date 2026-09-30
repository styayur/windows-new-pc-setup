# Contributing

This repository provisions Windows machines, so correctness and reversibility matter more than clever automation.

## Canonical entrypoint

`SetupNewPC_Optimized.ps1` is the supported entrypoint. `Setupnewpc.ps1` is a compatibility wrapper. `Install-Applications.WithConfirmation.ps1` is an alternate per-package confirmation mode. `legacy/` is historical and is not compatible with the v2 workflow.

## Development

Requirements: Windows 11, Windows PowerShell 5.1 or PowerShell 7, and WinGet for real execution. Tests are dependency-free and must not touch the host.

```powershell
.\SetupNewPC_Optimized.ps1 -Profile Developer -WhatIf | ConvertTo-Json -Depth 8
.\tests\Run-Tests.ps1
```

The regression suite must cover parser validation, `-WhatIf`, configuration schema, non-admin behavior, mocked install flows, retries, and concurrency. Do not add tests that install software or alter Windows features.

## Pull requests

- Keep one entrypoint canonical; wrappers must remain thin and compatible.
- Add regression tests for behavior changes.
- Document new privileged, destructive, networked, or restart-related behavior.
- Preserve exit-code and state-file compatibility unless a migration is documented.
- New package-catalog entries require an official WinGet/MSStore ID and a practical reason.
- Do not silently download scripts or installers outside WinGet/MSStore.

Maintainers perform releases. Security issues must follow [SECURITY.md](SECURITY.md), not the public issue tracker.
