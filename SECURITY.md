# Security Policy

## Supported version

Security fixes target the current `main` branch. The latest public prerelease is expected to be `v2.0.0-rc.1` until final v2 certification.

## Report privately

Do not open a public issue for a vulnerability. Use GitHub private vulnerability reporting:

https://github.com/styayur/whinset/security/advisories/new

Include the affected version, Windows/PowerShell/WinGet versions, exact command, configuration, impact, and a minimal reproduction. Sanitize machine names, usernames, local paths, tokens, tenant information and private package inventories.

## Security-sensitive areas

This project can install packages and, when explicitly requested, enable Windows features, modify user/machine environment values, configure WSL/Docker and execute installer/vendor tooling. Reports about command injection, plan tampering, path traversal, plan/nonce substitution, catalog substitution, checksum bypass, unsafe state handling, unintended system modification or UAC orchestration defects are in scope.

## Operating boundary

- `plan` does not create Whinset state or request UAC. WinGet inventory is read-only; WinGet may refresh local source metadata.
- `apply` requires `-AcceptAgreements`.
- User-level operations stay in the current user process.
- Elevated operations are allowlisted and reconstructed from the installed catalog by the elevated worker. The worker does not execute arbitrary plan-provided PowerShell.
- UAC uses normal Windows elevation. There is no UAC bypass or encoded command path.
- Declining UAC records `ElevationDenied`, starts no elevated worker, and exits 4.
- `beatwin.txt` verifies a pinned release SHA-256 before executing anything from the archive.
- No automatic rollback is claimed.

Use a disposable Windows 11 VM when validating risky changes and preserve logs before cleaning up.
