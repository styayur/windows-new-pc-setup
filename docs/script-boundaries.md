# Script and module boundaries

| Path | Status | Purpose |
| --- | --- | --- |
| `whinset.ps1` | Canonical entrypoint | New Whinset CLI |
| `whinset.cmd` | Canonical CMD shim | Calls `whinset.ps1` with `pwsh` or Windows PowerShell |
| `whinset.sh` / `whinset.nu` | Experimental adapters | Forward arguments to the same PowerShell entrypoint |
| `src/Whinset.psd1` | Module manifest | `Invoke-Whinset` and `whinset` alias |
| `src/Whinset.psm1` | Module loader | Loads compatibility helpers and `src/Whinset/*` |
| `src/Whinset.ElevatedWorker.ps1` | Elevated entrypoint | Validates and executes the trusted elevated phase |
| `src/Configuration.ps1` | Compatibility parser | Reads schema 1/2 catalogs for legacy scripts |
| `src/SetupNewPC.Core.ps1` | Legacy engine | Existing full setup behavior and native process helper |
| `SetupNewPC_Optimized.ps1` | Legacy canonical script | Preserved existing flow and per-stage behavior |
| `Setupnewpc.ps1` | Compatibility wrapper | Forwards legacy calls |
| `Install-Applications.WithConfirmation.ps1` | Legacy alternate flow | Applications-only per-package Y/N prompts |
| `beatwin.txt` | Release bootstrap | Pinned download, SHA-256, safe plan/apply entry |
| `scripts/Build-Release.ps1` | Release tooling | Deterministic archive and bootstrap checksum generation |
| `legacy/` | Historical material | Archived v1/DSC inputs; not current entrypoints |

## Authority

- New CLI: `whinset.ps1` / module.
- New execution planner: `src/Whinset/05-Plan.ps1`.
- Identity/request/ACL validation: `src/Whinset/04-Security.ps1`; persistent state: `04-State.ps1`.
- New privilege worker: `src/Whinset/07-Apply.ps1` and `src/Whinset.ElevatedWorker.ps1`.
- Legacy behavior: `SetupNewPC_Optimized.ps1` and `src/SetupNewPC.Core.ps1`.

Do not mix legacy `state.json` with the new run state. Legacy state is read only by the new status command.

## RC.2 execution order

The original process validates the plan, creates private state, reconciles packages and runs ready user operations. One same-user UAC worker handles machine prerequisites and installation. The original process then registers/configures its WSL distribution and verifies its Docker daemon/smoke test after dependencies complete. A reboot-required result stops later work until a changed boot ID is observed. Docker installation does not depend on user distribution registration, so machine work stays in one elevated phase.

The worker reconstructs executable metadata from the installed catalog, checks state/request identity and age, claims the nonce once, and returns a nonce-bound result. The module exports only Invoke-Whinset and its alias; the worker entry script explicitly enters private module scope. The trusted distribution includes code and catalog together; hashes are consistency checks rather than code signatures.
