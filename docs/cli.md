# Whinset CLI reference

## Invocation

```powershell
whinset <command> [options]
```

Before installing the command, use `pwsh -NoProfile -File .\whinset.ps1` or `powershell.exe -NoProfile -File .\whinset.ps1`.

CMD uses `whinset.cmd`; Git Bash and Nushell have experimental forwarding adapters. See [shell compatibility](shell-compatibility.md) for quoting, JSON encoding, stderr and exit-code behavior. Different-user UAC credentials are unsupported; see the [security policy](security-model.md).

## Commands

### `plan`

```powershell
whinset plan [-Profile <name>] [-Package <key-or-id>] [-Exclude <key-or-id>] [-Group <group>] [-Json]
```

Builds the catalog selection, dependency graph, environment snapshot and operation order. `plan` does not create Whinset state or request UAC. It can perform read-only WinGet inventory; add `-Offline` to skip inventory.

### `apply`

```powershell
whinset apply [-Profile <name>] [-Package <key-or-id>] [-Exclude <key-or-id>] [-AcceptAgreements] [-Json]
```

Rebuilds and validates the plan, runs user-level operations in the current user context, requests UAC once if elevated work remains, and runs all elevated operations in one worker. Apply requires `-AcceptAgreements`.

### `status`

```powershell
whinset status [-RunId <id>] [-Json]
```

Shows the latest/selected run, operation statuses, exit code, recovery information and read-only legacy SetupNewPC state.

### `doctor`

```powershell
whinset doctor [-Json]
```

Read-only checks for Windows 11, 64-bit process, PowerShell version, WinGet, sources, catalog schema, deterministic plan engine, state compatibility and restart state. Exit code 5 means an unhealthy required capability.

### `resolve`

```powershell
whinset resolve <query> [-Json]
```

Shows candidates with stable Key, display name, vendor, exact Source:Id, architecture, scope and privilege. It never installs.

### `recover`

```powershell
whinset recover [-RunId <id>] [-Retry] [-Json]
```

Without `-Retry`, prints pending operations and recovery limits. With `-Retry`, loads the saved plan, reconstructs it from the installed catalog, verifies its hash and resumes. A restart-required state in the same boot returns 3010.

### `install-cli`

```powershell
whinset install-cli
```

Copies the current reviewed files under `%LOCALAPPDATA%\Whinset\current` and adds that directory to the current user's PATH. No administrator access is needed.

### `version`

```powershell
whinset version [-Json]
```

## Common options

| Option | Meaning |
| --- | --- |
| `-Profile` | `Minimal`, `Developer`, `AI`, `Engineering` or `Full` |
| `-Package` | Exact stable Key or exact Source:Id; repeatable |
| `-Exclude` | Exact package Key or Source:Id; repeatable |
| `-Group` | Add a catalog group; repeatable |
| `-IncludePersonal` | Add the Personal group |
| `-SkipStoreApps` | Exclude msstore packages |
| `-Stage` | `Auto`, `WindowsBase` or `Development` |
| `-ConfigureEnvironment` | Add environment operations |
| `-SkipCondaInit` | Do not run `conda init powershell` |
| `-EnableWsl` | Add WSL feature/runtime operations |
| `-EnableDocker` | Enable WSL and add Docker Desktop |
| `-DockerSmokeTest` | Run `docker run --rm hello-world` |
| `-ApplicationsOnly` | Reject system/environment options |
| `-MaxAttempts` | Package attempt cap, 1-5 |
| `-InstallTimeoutSeconds` | Installer timeout, 30-14400 seconds |
| `-Json` | Emit one JSON document |
| `-Offline` | Skip WinGet inventory in plan mode |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Complete |
| 1 | Operation failed, blocked or incomplete |
| 2 | Invalid input, invalid plan/catalog or missing agreement |
| 3 | Compatibility-flow cancellation |
| 4 | UAC denied / elevation did not start |
| 5 | Doctor unhealthy |
| 3010 | Restart required |

## Tab completion

After `Import-Module .\src\Whinset.psd1` or `install-cli`, completion is registered for the command alias and function. It completes command names, profiles, groups, stages, package keys and exclusions from the current catalog.
