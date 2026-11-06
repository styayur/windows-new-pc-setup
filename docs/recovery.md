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
