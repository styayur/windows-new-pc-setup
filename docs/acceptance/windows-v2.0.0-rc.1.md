# Windows acceptance report - v2.0.0-rc.1

Date: 2026-11-06
Status: **release candidate; final v2.0.0 NOT certified**

## Test host

- Windows 11 client, build 26200, product type 1
- PowerShell 7.6.9 (Core)
- Windows PowerShell 5.1.26100.9711
- WinGet 1.29.380
- x64 process
- Host already had a pending file-rename restart marker during part of the validation; `doctor` correctly reported it as a warning.

## Read-only catalog validation

All 38 schema-2 package identities were queried with exact `--id`, `--source`, `--accept-source-agreements`, and `--disable-interactivity` using `winget show`:

- 38 / 38 found
- 0 source/ID lookup failures
- Included both `winget` and `msstore` entries

This proves the catalog IDs resolved on this host/source state on the test date. It does not prove future source availability or installer behavior.

## Automated regression evidence

| Suite | PowerShell 7 | Windows PowerShell 5.1 |
| --- | --- | --- |
| Legacy `tests/Run-Tests.ps1` | PASS, 25 tests | PASS, 25 tests |
| Whinset `tests/Run-WhinsetTests.ps1` | PASS, 28 tests | PASS, 28 tests |

Whinset coverage includes catalog metadata, source-qualified ambiguity, display-name rejection, dependency/cycle/conflict/architecture validation, deterministic plan hashes, user/elevated separation, one-UAC orchestration, UAC denial, already-elevated execution, already-installed reconciliation, elevated worker plan trust/nonces, JSONL logs, interruption, reboot gate, legacy state discovery, bootstrap manifest/checksum behavior, completion, concurrent-apply mutex, `install-cli`, and JSON exit codes.

`PSScriptAnalyzer -Severity Error` reported 0 errors across all PowerShell files.

## Read-only and no-op host integration

- `whinset version -Json`: exit 0, structured JSON.
- `whinset doctor -Json`: exit 0, `Healthy`; pending restart reported as WARN.
- `whinset plan -Profile Minimal -Offline -Json`: exit 0, no Whinset state directory created.
- `whinset plan -Profile Minimal -Json`: exact inventory found all five Minimal packages already installed; UAC prompts expected: 0.
- `whinset apply -Profile Minimal -AcceptAgreements` against a temporary state root: exit 0, `Complete`, no UAC request, all five operations `AlreadyInstalled`.
- `whinset recover -Retry` against the complete temporary run: exit 0, plan reconstructed/hash-verified, no UAC request.
- `whinset status -Json`: found the run and returned the expected operation summary.
- A temporary `install-cli` root was added to PATH. PowerShell resolved `whinset` as the installed `whinset.ps1`, and tab completion returned commands, `Minimal`, and package keys (`Git`, `GitHubCLI`, `Chrome`, `Go`) under both PowerShell 7 and Windows PowerShell 5.1.

## Bootstrap integrity simulation

The deterministic release archive was built and verified with `beatwin.txt`. A local simulation replaced only the network transfer with a copy of the exact archive, then exercised SHA-256 verification, extraction, `whinset plan`, human output, and temporary cleanup: exit 0. A second simulation with a deliberately wrong pinned SHA-256 failed before execution with exit 1.

## Not yet executed

The following require an interactive Windows 11 VM and remain **NOT RUN** for rc.1:

- approve and deny a real UAC prompt
- elevate a batch of genuinely missing package installs through the worker
- clean-VM package installation and installer side effects
- WSL optional feature activation and restart continuation
- WSL/Ubuntu first-run validation
- Docker Desktop first run and hello-world
- real vendor uninstall/manual recovery verification

## Release decision

Because the real UAC/reboot/installer acceptance items are not complete, the correct publication is **v2.0.0-rc.1 prerelease**, not final v2.0.0. CI results and bootstrap asset integrity are recorded on the PR/release after the branch is pushed.
