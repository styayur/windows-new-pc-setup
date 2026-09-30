# Script boundaries

The repository intentionally keeps one active engine and two narrow compatibility/alternate entrypoints.

| Path | Status | Purpose |
| --- | --- | --- |
| `SetupNewPC_Optimized.ps1` | Canonical | Full preview, package installation, optional environment/WSL/Docker setup |
| `Setupnewpc.ps1` | Compatibility wrapper | Forwards existing calls to the canonical script |
| `Install-Applications.WithConfirmation.ps1` | Alternate mode | Applications-only flow with per-package confirmation |
| `legacy/` | Historical | Archived v1/DSC material; do not mix with the v2 workflow |
| `src/Configuration.ps1` | Internal | Catalog parsing and validation |
| `src/SetupNewPC.Core.ps1` | Internal | State, package, environment, and install orchestration |

The canonical script is side-effect free in `-WhatIf` mode. Real execution requires administrator context where the OS demands it, explicit `-AcceptAgreements`, and a reviewed profile/catalog. Tests replace external command execution with mocks.
