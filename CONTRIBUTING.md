# Contributing

## Scope

Whinset preserves the legacy SetupNewPC entrypoints while the `whinset` module is the canonical v2 interface. Changes must not silently remove a previously supported package or bypass the documented privilege/recovery boundaries.

## Before changing package behavior

- Use an exact WinGet/MSStore `Source:Id`.
- Add stable `Key`, `Vendor`, architecture, scope, version policy, stage, privilege, dependencies, conflicts, expected state and recovery metadata.
- Explain vendor/source/scope distinctions when adding similar packages.
- Never select a package by display-name similarity at execution time.
- Update ambiguity, dependency and conflict tests.

## Validation

Run all four suites:

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-WhinsetTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WhinsetTests.ps1
```

Build and verify the release candidate:

```powershell
pwsh -NoProfile -File .\scripts\Build-Release.ps1 -Version v2.0.0-rc.1 -OutputDirectory $env:TEMP\whinset-release -VerifyBootstrap
```

Mocked tests do not certify real UAC, installers, Windows features or reboot continuation. Record real Windows 11 VM acceptance separately in `tests/VM-CHECKLIST.md`.

## Privilege and security review

Any change to planning, elevation, package execution, catalog trust, logging or recovery requires tests for:

- one-UAC consolidation
- UAC denial with no elevated operation started
- already-elevated execution
- interrupted operation recovery
- reboot gate and new-boot resume
- exact plan reconstruction/hash validation
- structured logging
- no arbitrary elevated command/script injection

Do not add hidden UAC bypasses, credential collection, encoded payloads, unpinned remote code or claims of automatic rollback that are not implemented and verified.

## Pull requests

Describe compatibility effects on exit codes, state layout, schema, package IDs and legacy entrypoints. Link real acceptance evidence separately from mocked test results.
