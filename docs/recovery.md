# Recovery guide

## Inspect first

```powershell
whinset status
whinset recover
whinset doctor
```

Review `state.json` and `operations.jsonl` under the printed run directory. Do not delete state to hide a problem; preserve it for diagnosis.

## Failed package

1. Read the operation error and WinGet exit code.
2. Check whether the package is actually installed with `whinset plan`.
3. Restore network/source access or correct the catalog conflict.
4. Run `whinset recover -Retry`.

Whinset does not silently upgrade/downgrade a pinned version or install a conflicting package.

## Reboot required

- Save work.
- Restart Windows manually.
- Do not repeatedly retry in the same boot.
- Run `whinset recover -Retry` after restart.

## UAC denied

- Run status is `ElevationDenied`.
- No elevated operation was started by that phase.
- Review the plan and user/machine changes.
- Retry and authorize normal Windows UAC if intended.

## WSL or Docker

- Feature activation may require restart.
- Ubuntu may require first-run user initialization.
- Docker Desktop may require first-run license/daemon setup.
- `whinset doctor` can verify later; it does not fix anything.

## Manual removal

Use exact package identity. Example:

```powershell
winget uninstall --id Google.Chrome --exact --source winget
```

Feature removal and Docker/WSL removal are manual. Removing Whinset itself does not remove packages, packages' settings or Windows features.

## What is not recoverable automatically

- Vendor installer side effects
- Services/startup/registry/PATH changes made by installers
- WSL distribution content
- Docker images, volumes and first-run state
- Machine policy/security settings changed by external tools
- User data overwritten outside Whinset's recorded operation

Whinset records what it attempted; it does not claim universal rollback.

## RC.2 reconciliation and trust failures

Different-user UAC credentials are unsupported. Retry from the intended account using same-user elevation; never use the alternate administrator's profile as a substitute. A launch failure/crash or invalid/missing worker result is a failure, not UAC denial. Review the structured elevation events and process/native error codes.

Every package is rechecked against exact identity before execution, including prior successes in a partial run. Before a second installer attempt, inventory is checked again to avoid duplicating an installation that completed despite a transport interruption. A partial elevated phase retains completed records; interrupted/failed work becomes pending. Restart flags are cleared after a boot-ID change and prerequisites are re-evaluated. Do not manually clear a same-boot reboot gate to continue.

Atomic writes preserve the previous committed file as `.bak`; an orphan `.tmp-*` is not authoritative. Corrupt JSON and mismatched identity/operation metadata fail closed. Preserve the main file, backup, temporary files and JSONL logs before manual inspection. There is no automatic backup promotion, state repair or power-loss durability guarantee. After resolving installer state manually, use a fresh private state directory if the old state cannot be trusted.

Existing directories with foreign writers/owners or reparse paths are rejected. Inspect ACLs manually; Whinset does not take ownership or weaken access controls. Nonce-consumption markers remain under the run directory to reject replay. A new retry creates a fresh nonce; do not remove a marker to replay an old request.

RC.1 plans include a different version identity and cannot be forced through RC.2 recovery. Preserve their state/logs, run a fresh RC.2 plan and reconcile actual installed packages. No package uninstall or rollback is performed by this transition.
