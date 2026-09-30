# Security Policy

## Supported version

Security fixes target the current `main` branch and the latest release.

## Report privately

Do not open a public issue for a vulnerability. Use GitHub private vulnerability reporting:

https://github.com/styayur/windows-new-pc-setup/security/advisories/new

Include the affected version, Windows/PowerShell/WinGet versions, exact command, configuration, impact, and a minimal reproduction. Sanitize machine names, usernames, local paths, tokens, tenant information, and private package inventories.

## Security-sensitive areas

This project can install packages and, when explicitly requested, enable Windows features, modify user environments, configure WSL/Docker, and execute a reviewed WinUtil script. Reports about command injection, path traversal, supply-chain substitution, hash bypass, privilege escalation, unsafe state handling, or unintended system modification are in scope.

## Operating boundary

- `-WhatIf` is designed to avoid system, network, state-directory, and package-manager changes.
- Real execution requires explicit `-AcceptAgreements`.
- The script does not silently download WinUtil or bypass administrator requirements.
- Review the complete preview and software licenses before executing on a real machine.
- Use a VM or disposable machine when validating risky changes.
