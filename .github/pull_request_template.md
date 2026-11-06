## Summary

## Why

## Validation

- [ ] `.\tests\Run-Tests.ps1` passes in Windows PowerShell 5.1.
- [ ] `.\tests\Run-Tests.ps1` passes in PowerShell 7.
- [ ] `.\tests\Run-WhinsetTests.ps1` passes in Windows PowerShell 5.1.
- [ ] `.\tests\Run-WhinsetTests.ps1` passes in PowerShell 7.
- [ ] New PowerShell files parse without errors.
- [ ] Tests use mocks and do not install software, change Windows features, or approve UAC.
- [ ] Plan mode remains free of Whinset state creation and UAC.
- [ ] Elevated operations remain allowlisted and reconstructed from the installed catalog.
- [ ] Reboot, interruption and UAC-denial behavior was updated if affected.
- [ ] Privileged/destructive behavior, rollback limits and logs are documented.

## Compatibility

Describe changes to exit codes, state paths/schema, package metadata, profile selection, bootstrap checksum, or legacy commands.
