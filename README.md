# Whinset

**Deterministic Windows 11 setup with explicit package identities, a reviewable DAG plan, and one necessary UAC boundary.**

[![PowerShell regression tests](https://github.com/styayur/whinset/actions/workflows/test.yml/badge.svg)](https://github.com/styayur/whinset/actions/workflows/test.yml)
[Security model](docs/security-model.md) · [CLI reference](docs/cli.md) · [Shell compatibility](docs/shell-compatibility.md) · [Package resolution](docs/package-resolution.md) · [Recovery](docs/recovery.md) · [中文说明](docs/README.zh-CN.md)

Current source: **v2.0.0-rc.2**. This is a release candidate because real Windows 11 VM acceptance of UAC, privileged installers, Windows features and reboot continuation is not yet certified.

## Before download: privilege and system-change disclosure

Read this before running `beatwin.txt` or changing `WhinsetMode` from `plan` to `apply`.

- **Administrator operations may include:** installing machine-scoped WinGet/MSStore packages, enabling `VirtualMachinePlatform` and Windows Subsystem for Linux, updating the machine WSL runtime, installing Docker Desktop, and setting machine `JAVA_HOME`/`PATH`.
- **User operations may include:** WSL Ubuntu registration, Docker daemon/hello-world checks, Git LFS hooks, `UV_PYTHON_PREFERENCE`, Conda PowerShell initialization and `auto_activate_base=false`, Go user configuration, Rust's `~/.cargo/bin`, and user `PATH` changes.
- Installers can change files, services, startup entries, PATH, registry values and other machine state beyond Whinset's own operation records.
- UAC is used through normal Windows elevation. Whinset does not disable UAC, collect credentials, use hidden elevation tricks, or pass arbitrary PowerShell code to the elevated process.
- A non-elevated `apply` requests **one UAC authorization** when elevated work remains. All elevated operations then run in one validated worker.
- If UAC is declined, the elevated phase stops with exit code **4**. The non-elevated planning/state files remain intact; no privileged installer was started by that phase.
- Different-user UAC credentials are unsupported and rejected before elevated operations. User work remains in the intended original account.
- Logs and structured state are stored under `%LOCALAPPDATA%\Whinset\v2`.
- Packages can normally be removed with an exact WinGet uninstall, but some installer changes remain manual. Windows features, WSL distributions, Docker first-run state, registry edits and vendor services must be reviewed individually. **Whinset does not claim automatic rollback.**
- There is no promise that uninstalling a package restores every PATH, service, registry or application setting that its installer changed.
- Restart may be required. Whinset never restarts Windows automatically.

The same disclosure is included in the `v2.0.0-rc.2` release notes and in `beatwin.txt` before the download step.

## Quick start with `beatwin.txt`

`beatwin.txt` is the human-readable copy-and-paste bootstrap. It defaults to safe plan mode:

1. Download the pinned `v2.0.0-rc.2` release archive.
2. Verify its fixed SHA-256 value before extraction.
3. Extract under the current user's temporary directory.
4. Run `plan` without Whinset state creation.
5. Delete the temporary download/extraction directory.

After reviewing the plan and licenses, change `$WhinsetMode = 'plan'` to `$WhinsetMode = 'apply'` in the pasted block. `apply` still rebuilds and validates the plan, then requests UAC only if elevated work remains.

`beatwin.txt` never downloads `main`, never uses `Invoke-Expression`, never uses encoded commands, and is tied to a release URL and SHA-256 rather than a moving branch.

## Install the `whinset` command

From a reviewed checkout:

```powershell
pwsh -NoProfile -File .\whinset.ps1 plan -Profile Developer
pwsh -NoProfile -File .\whinset.ps1 install-cli
```

`install-cli` copies the reviewed files under `%LOCALAPPDATA%\Whinset\current` and adds that directory to the **current user's PATH**. Open a new terminal afterwards:

```powershell
whinset version
whinset plan -Profile Developer
```

The command is a PowerShell module/alias backed by `whinset.ps1` and `whinset.cmd`; no internal path is required after installation. Tab completion covers commands, profiles, groups, stages and package keys.

## Command reference

```powershell
whinset plan   -Profile Developer
whinset plan   -Profile Minimal -Exclude Chrome
whinset apply  -Profile Minimal -AcceptAgreements
whinset status
whinset doctor
whinset resolve chrome
whinset recover -Retry
```

| Command | Purpose |
| --- | --- |
| `plan` | Build and validate the immutable operation graph. Does not create Whinset state or request UAC. |
| `apply` | Recheck package state, execute user operations, then one elevated worker for elevated operations. Requires `-AcceptAgreements`. |
| `status` | Show the latest/selected run, operation outcomes, reboot gate and read-only legacy SetupNewPC state. |
| `doctor` | Read-only checks for Windows 11, architecture, PowerShell, WinGet, sources, catalog, plan engine and restart state. |
| `resolve` | Show candidates with stable key, vendor, exact `Source:Id`, architecture, scope and privilege. |
| `recover` | Show recovery limits; `-Retry` reconstructs and hash-verifies the saved plan before resuming. |
| `install-cli` | Install/update the per-user command and PATH entry. |
| `version` | Print Whinset, PowerShell and repository information. |

Use `-Json` for one structured JSON document. Use `whinset help`, `whinset help apply`, or `whinset help security` for command help.

## Profiles

Profiles and groups live in [config/packages.json](config/packages.json), not in display-name matching code.

| Profile | Groups |
| --- | --- |
| Minimal | Core |
| Developer | Core + Developer |
| AI | Core + Developer + AI |
| Engineering | Core + Developer + Engineering |
| Full | Core + Developer + AI + Engineering + Personal |

`-Group`, `-IncludePersonal`, `-Package`, `-Exclude` and `-SkipStoreApps` adjust the selection deterministically. Add `-ConfigureEnvironment`, `-EnableWsl`, `-EnableDocker` or `-DockerSmokeTest` only when those changes are intended.

## Package disambiguation

Every package in schema 2 has a stable internal key, display name, vendor, exact WinGet/MSStore ID, source, architecture policy, scope policy, version policy, stage, privilege, dependencies, conflicts, expected state and recovery metadata.

Resolution rules:

- A stable **Key** is always accepted, for example `Chrome` or `Git`.
- An exact **ID** is accepted when unique, for example `Google.Chrome`.
- If the same ID exists in more than one source, qualify it as `winget:<id>` or `msstore:<id>`, or use the stable Key.
- A display name is **not** an installation selector. `whinset plan -Package "Google Chrome"` fails and prints candidates rather than guessing.
- Similar candidates show vendor, identity, architecture, scope and privilege.
- Dependencies are auto-included; dependency cycles, unknown dependencies and declared conflicts fail before execution.
- `-Version` plus an explicit scope remains rejected because WinGet export cannot reliably prove the version per scope.

Use `whinset resolve <query>` to inspect candidates without changing the machine.

## Execution architecture

```text
catalog -> explicit selection -> dependency DAG -> environment/preflight
        -> immutable plan hash -> user operations
        -> one validated elevated worker -> user post-operations -> report
```

The plan records:

- OS/PowerShell/WinGet/user context and pending restart state
- requested profile, exact package set and operation order
- installed/missing/unknown inventory
- dependencies, conflicts and stable tie-breakers
- user versus elevated privilege
- optional reboot interruption point
- recovery classification and limitations
- expected UAC count
- a SHA-256 plan identity and short run ID

Installed packages are rechecked immediately before elevation. If a package disappeared after planning it returns to the validated install operation; if it is still installed, no UAC is requested for it.

The elevated worker does not trust plan-provided scripts or paths. It reloads the installed catalog, reconstructs the allowed operation graph, verifies the catalog and plan hashes, accepts fixed operation kinds only, and checks a per-attempt nonce. There is no `Invoke-Expression` or arbitrary command field in the serialized plan.

## Status, logs and resume

Default state root:

```text
%LOCALAPPDATA%\Whinset\v2
```

Each run contains:

```text
runs\<plan-hash>\
  plan.json
  state.json
  operations.jsonl
  report.json
```

`operations.jsonl` is append-only structured logging for plan/elevation/operation lifecycle and installer output. `state.json` uses atomic replacement with a `.bak` copy.

Re-running the same plan:

- verifies actual installed state again
- skips operations already verified
- retries failed/interrupted pending operations
- blocks continuation in the same boot after a reboot request
- resumes pending operations after a new boot
- preserves previous operation history in `operations.jsonl`

Legacy `%LOCALAPPDATA%\SetupNewPC\v2` state is discovered read-only by `whinset status`. The migration path is to run `whinset plan` and `whinset apply`: exact inventory checks reconcile what is already installed without deleting legacy state.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Complete; all selected operations succeeded or were already satisfied |
| 1 | Operation failure, blocked dependency or incomplete operation graph |
| 2 | Invalid input, catalog/plan validation failure or missing `-AcceptAgreements` |
| 3 | User cancellation/decline in a compatibility flow |
| 4 | UAC authorization denied or elevation did not start |
| 5 | `doctor` found an unhealthy required capability |
| 3010 | Restart required; stop and resume after Windows restarts |

## Requirements and limitations

- Real apply: Windows 11 client build 22000+, 64-bit, WinGet 1.8+, network access to selected sources, and a user who can authorize administrator operations.
- PowerShell 7 is the primary target; Windows PowerShell 5.1 remains supported and tested.
- Plan mode is read-only with respect to Whinset state, packages and Windows features. WinGet itself may refresh local source metadata during inventory.
- No Windows restart, scheduled continuation, automatic uninstall or automatic rollback is implemented.
- Docker Desktop first-run setup and daemon startup may require manual action.
- WSL/Docker behavior remains vendor- and policy-dependent.
- Custom catalogs are **plan-only** in this release candidate. Apply uses the installed built-in catalog. The legacy `SetupNewPC_Optimized.ps1` remains available for reviewed custom manifests.
- Legacy per-package confirmation remains available only through `Install-Applications.WithConfirmation.ps1`; the canonical Whinset apply flow intentionally avoids redundant per-operation prompts.
- Mocked CI tests do not certify every installer. Clean Windows 11 VM UAC/reboot acceptance is still pending for rc.2. See the [Windows acceptance report](docs/acceptance/windows-v2.0.0-rc.2.md).

## Compatibility

The following remain for existing users:

- `SetupNewPC_Optimized.ps1`
- `Setupnewpc.ps1`
- `Install-Applications.WithConfirmation.ps1`
- schema 1 custom catalogs
- legacy state directories and archived DSC material under `legacy/`

New development and documentation use the `whinset` identity. See [script boundaries](docs/script-boundaries.md) for the compatibility matrix.

## Development and verification

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-WhinsetTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WhinsetTests.ps1
pwsh -NoProfile -File .\scripts\Build-Release.ps1 -Version v2.0.0-rc.2 -OutputDirectory $env:TEMP\whinset-release -VerifyBootstrap
```

The release workflow rebuilds the archive deterministically, verifies the pinned `beatwin.txt` checksum, uploads `Whinset-<version>.zip`, `beatwin.txt` and `SHA256SUMS.txt`, and publishes `v2.0.0-rc.2` as a prerelease.

MIT licensed. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
