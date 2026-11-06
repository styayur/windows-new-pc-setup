# Status, recovery and migration

## State location

Whinset state defaults to:

```text
%LOCALAPPDATA%\Whinset\v2
```

Use `-StateDirectory <path>` to select another parent location. Each plan hash has its own run directory:

```text
runs\<plan-hash>\
  plan.json
  state.json
  state.json.bak
  operations.jsonl
  report.json
  elevation-request.json       # elevated runs
  elevated-result.json         # elevated runs
```

`latest.json` points to the latest run. `operations.jsonl` is append-only structured logging; `state.json` uses temp-file replacement plus a backup.

## Status

```powershell
whinset status
whinset status -RunId <short-id> -Json
```

Operation states include `Pending`, `Running`, `Succeeded`, `AlreadyInstalled`, `Skipped`, `Warning`, `Failed`, `AwaitingReboot` and `Blocked`. The distinction matters: already-installed software is not reported as newly installed.

## Interruption

If the process is interrupted while an operation is `Running`, the next apply with the same plan normalizes that record to `Pending`. Exact WinGet inventory checks decide whether an installer is needed; a recorded success is not treated as proof forever.

## Restart continuation

When an installer or Windows feature returns a restart code:

1. The operation becomes `AwaitingReboot`.
2. Later operations remain pending.
3. The run exits **3010**.
4. Re-running in the same boot returns 3010 without starting a new installer.
5. After Windows restarts, the changed boot ID permits resume.

No scheduled task or automatic restart exists. Run the same `apply` or `whinset recover -Retry` after restarting.

## Retry

```powershell
whinset recover
whinset recover -Retry
whinset recover -RunId <short-id> -Retry
```

`-Retry` loads the saved plan, reconstructs it from the installed catalog, verifies the plan hash and resumes. Installed packages are rechecked before any UAC request.

## UAC denial

If UAC is declined, the run status is `ElevationDenied`, exit code is **4**, and no elevated worker starts. Retry after reviewing the request and authorizing normal Windows elevation.

## Recovery classes

| Class | Meaning |
| --- | --- |
| `manual` | Review settings/uninstall manually; exact instructions are in the operation |
| `external` | Vendor/Windows owns removal and first-run state |
| `automatic` | Reserved for a future verified rollback implementation |

The current catalog does **not** promise automatic rollback. Successful installs and settings remain after failure or cancellation.

## Package recovery

The catalog records exact Source:Id values. Example manual uninstall:

```powershell
winget uninstall --id Git.Git --exact --source winget
```

Some installers may leave services, PATH entries, registry values, caches or configuration behind.

## Legacy SetupNewPC state

Existing directories under:

```text
%LOCALAPPDATA%\SetupNewPC\v2
```

are discovered read-only by `whinset status`. They are not deleted or rewritten. The migration path is to run `whinset plan` and `whinset apply`; inventory reconciliation installs only missing packages and records new state under `Whinset\v2`.

Legacy v4 state remains usable by the compatibility scripts, but it is not treated as proof that a current Whinset operation succeeded.
