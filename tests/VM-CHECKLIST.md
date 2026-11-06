# Windows 11 VM acceptance - Whinset v2.0.0-rc.2

Automated/mocked tests do not replace real Windows acceptance. Use a recoverable Windows 11 VM snapshot. Record OS build, PowerShell versions, WinGet version, exact commands, run directories and exit codes.

## Release gate

- [ ] Windows 11 client build 22000+.
- [ ] PowerShell 7 and Windows PowerShell 5.1 can run `whinset version`, `doctor` and `plan`.
- [ ] `plan`/`-WhatIf` requests no UAC and creates no Whinset run state.
- [ ] `apply` without `-AcceptAgreements` exits 2 and creates no run state.
- [ ] One UAC prompt consolidates a request with multiple missing machine packages; no second prompt appears.
- [ ] UAC denial exits 4, records `ElevationDenied`, starts no installer, and leaves pending state recoverable.
- [ ] Already-elevated execution does not request a second UAC.
- [ ] A mix of user and machine operations executes user configuration outside the elevated worker.

## Package reconciliation

- [ ] Clean VM: a two-package test plan installs both, then a second apply starts no installers.
- [ ] Pre-installed packages are reported `AlreadyInstalled`, not newly installed.
- [ ] Remove one package, rerun, and only that package is installed.
- [ ] Unknown invalid package ID fails with useful source/ID evidence.
- [ ] Ambiguous ID/source fixture fails without installation; source-qualified or stable Key succeeds.
- [ ] Pinned-version conflict does not upgrade/downgrade.
- [ ] Installer timeout stops later installers and leaves a recoverable state.
- [ ] Ctrl+C/interruption leaves parseable state; rerun rechecks actual inventory.

## Reboot and features

- [ ] Installer exit 3010 records `AwaitingReboot`; same-boot retry returns 3010 without a new installer.
- [ ] After restart, boot ID changes and pending work resumes.
- [ ] WSL optional-feature activation records restart correctly.
- [ ] WSL 2 + Ubuntu validation succeeds after restart and manual first-run readiness.
- [ ] Firmware virtualization disabled produces a clear blocker, not false success.
- [ ] Docker Desktop installation/daemon readiness behaves as documented; optional hello-world smoke test passes when requested.

## Recovery and logs

- [ ] `operations.jsonl` parses entirely as JSON lines and records run/elevation/operation lifecycle.
- [ ] `state.json` remains parseable after interruption and preserves `.bak`.
- [ ] `status`, `recover` and `recover -Retry` point to the expected run.
- [ ] Legacy `%LOCALAPPDATA%\SetupNewPC\v2` state appears read-only in `whinset status` and is not modified.
- [ ] State path with spaces/Chinese characters works.
- [ ] Two concurrent applies do not corrupt state or start duplicate installers.

## Bootstrap and release

- [ ] `beatwin.txt` plan mode downloads the pinned asset, validates SHA-256, runs plan, and removes its temp directory.
- [ ] A deliberately corrupted archive fails before extraction/execution.
- [ ] `beatwin.txt` apply mode runs the reviewed plan and uses the one-UAC flow.
- [ ] `SHA256SUMS.txt` matches `Whinset-v2.0.0-rc.2.zip` and `beatwin.txt`.
- [ ] Release archive contains no `beatwin.txt` self-reference and includes `whinset.ps1`, `src`, `config`, tests and docs.
- [ ] No `Invoke-Expression`, encoded payload, `main` archive URL, UAC bypass or automatic rollback claim appears.

## Sign-off

Record each item as PASS, FAIL, NOT RUN, BLOCKED or NOT APPLICABLE. Do not mark final `v2.0.0` published until all release-gate items have evidence.

## RC.2 identity and independent sign-off

- [ ] Record OriginalUserSid and ElevatedUserSid for same-user UAC grant/deny.
- [ ] Supply different-user administrator credentials; verify no worker installation/configuration starts and no alternate-administrator profile receives packages, WSL registrations or Docker user data.
- [ ] Verify feature activation/runtime updates and Docker machine installation separately from original-user distribution registration and daemon/hello-world checks.
- [ ] Record state owner and inheritable ACL entries, reject foreign-writable/reparse paths, and retain the rejection logs.
- [ ] Verify stale/replayed requests and unexpected result files cannot resume worker execution.
- [ ] Test interrupted installer and partial elevated phase, retaining logs and package inventory before and after retry.
- [ ] Preserve corrupt/interrupted state and backup for manual reconciliation; do not claim rollback.
- [ ] Independently review evidence for every RequiredForStable entry in docs/acceptance/windows-v2.0.0-rc.2.json.
- [ ] Record reviewer, date, VM snapshot identity, commands, logs, both SIDs and boot IDs. Keep Issue #8 open until this is complete.
