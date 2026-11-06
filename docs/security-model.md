# Security and privilege model

## Boundaries

Whinset has three distinct contexts:

1. **Current user executor** – builds plans, reads environment/inventory, writes run state and executes explicitly user-scoped operations.
2. **Elevated worker** – starts only through normal Windows UAC and executes allowlisted elevated operation kinds.
3. **External installers / Windows components** – WinGet, MSI/EXE installers, Windows optional features, WSL and Docker. Their own trust, policy and rollback behavior remains external.

## What may require elevation

- Machine-scoped package installation
- Enabling Windows optional features
- Machine WSL runtime updates (distribution registration stays in the original user process)
- Docker Desktop installation
- Machine `JAVA_HOME` and machine PATH changes

User environment operations do not need elevation and remain in the user executor.

## One authorization

The non-elevated `apply` command:

1. Builds and validates the exact operation graph.
2. Rechecks already-installed/missing package state.
3. Runs user operations whose dependencies are already satisfied.
4. Requests one UAC authorization if elevated work remains.
5. Launches one hidden elevated PowerShell worker with a plan path, plan hash and per-attempt nonce.
6. Executes all elevated operations in dependency order.
7. Returns to the original user process for user post-operations.

If UAC is denied, no elevated worker starts. The state records `ElevationDenied` and the command exits 4.

## Trusted plan validation

The elevated worker does not execute plan-provided script text. It:

- rejects a nonce/plan hash mismatch
- reloads the catalog from the installed Whinset directory
- verifies the catalog SHA-256 recorded in the plan
- reconstructs the operation graph from the catalog and serialized request
- compares plan hashes
- allowlists operation kinds
- fixes Docker's package identity
- rejects package metadata that differs from the catalog

There is no arbitrary command, script path or `Invoke-Expression` field in the execution plan.

## Not in scope

Whinset does not:

- bypass or disable UAC
- collect credentials
- run encoded PowerShell payloads
- unpin `main`-branch remote code in `beatwin.txt`
- silently weaken Windows security settings
- claim automatic rollback

## Logs

Structured logs are stored under `%LOCALAPPDATA%\Whinset\v2\runs\<plan-hash>\operations.jsonl`. Review them before sharing; they can contain machine paths, package IDs and installer output.

## RC.2 identity and request policy

Different-user UAC credentials are unsupported in RC.2. The worker rejects a SID mismatch before claiming a request, writing results/state, or running operations. Use same-user elevation from the intended account. Starting the whole CLI as another administrator makes that administrator the original user; Whinset cannot infer a previous desktop account. There is no credential collection or token impersonation.

The original process performs user package installs, WSL default-version/distribution registration and Docker daemon/hello-world checks. The elevated phase enables Windows features, updates the machine WSL runtime and installs machine-scoped Docker Desktop. Docker first-run initialization remains a manual original-user action when the daemon is unavailable. Package scope `auto` follows the catalog/vendor installer; because different-user elevation is rejected, it cannot silently target a different administrator profile. It is not a guarantee that every vendor installer supports machine scope.

Run directories are protected with inheritable full-control entries only for the original SID, SYSTEM and Administrators. Existing directories/files with foreign writers or owners are rejected, as are state paths containing reparse points. Existing RC.1 state with unsuitable ACLs requires manual inspection and a new private state directory; Whinset does not silently take ownership. State identity and operation metadata must match the reconstructed graph.

Requests expire after ten minutes (future timestamps beyond 30 seconds are rejected). A unique nonce is claimed with CreateNew before operation execution; a second use is rejected. Every retry creates a new request/nonce. Results bind the nonce, run ID, plan hash and process exit code. Only native ERROR_CANCELLED (1223), including wrapped Win32 exceptions, means UAC denial; launch failures and crashes remain failures with structured diagnostic events. The worker requires an administrator token and is invoked inside private module scope.

Plan hashes, ACLs and nonces detect inconsistent inputs; they are not a signature or a security boundary against the same Windows user or administrators. The installed scripts and catalog must be reviewed/trusted together before UAC. This portable release does not protect a user-writable checkout from a same-user process changing code before elevation. Do not elevate a checkout supplied by another account. No claim of interactive UAC acceptance follows from deterministic tests.
