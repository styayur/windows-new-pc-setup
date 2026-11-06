# beatwin.txt bootstrap

`beatwin.txt` is a root-level, human-readable PowerShell copy-and-paste block. It is also published as a release asset.

## What it does

1. Checks Windows and PowerShell 5.1+.
2. Prints the privilege/system-change disclosure before downloading.
3. Downloads only the pinned GitHub release archive URL.
4. Verifies a release-specific SHA-256 value.
5. Extracts to a controlled random temporary directory.
6. Unblocks files only after the hash matches.
7. Invokes `whinset.ps1 plan` by default.
8. In apply mode, builds and inspects the plan before running `whinset.ps1 apply -AcceptAgreements`.
9. Leaves permanent state/logs under `%LOCALAPPDATA%\Whinset\v2`.
10. Removes only its verified temporary directory in a `finally` block.

## Safe default

```powershell
$WhinsetMode = 'plan'
```

After reviewing the plan, licenses and recovery limits, change it to:

```powershell
$WhinsetMode = 'apply'
```

The apply path does not add unnecessary per-operation confirmation prompts. The declared request, reviewed plan and UAC prompt are the relevant boundaries.

## Integrity model

The archive excludes `beatwin.txt` itself. This avoids a self-referential checksum. `scripts/Build-Release.ps1`:

- stages the release from a fixed file list
- sorts entries
- writes deterministic timestamps and compressed entries
- computes the archive SHA-256
- regenerates `beatwin.txt` from `bootstrap/beatwin.template.txt`
- writes `SHA256SUMS.txt`

The release workflow runs the build with `-VerifyBootstrap`; a tag fails if `beatwin.txt` does not pin the exact asset hash for that source tree.

## Prohibited patterns

`beatwin.txt` must not contain:

- `Invoke-Expression` on remote content
- encoded PowerShell commands
- `main`/`master` branch archive URLs
- unpinned download URLs
- hidden privilege escalation
- credential collection
- UAC bypass attempts
