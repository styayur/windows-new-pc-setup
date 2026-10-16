# Windows New PC Setup

Preview, review and repeat a Windows 11 setup from a WinGet package manifest, with explicit control over system changes.

**PowerShell-native · CLI-first · Read-only-first · Explicit recovery limits · Minimal dependencies**

[![CI](https://github.com/styayur/windows-new-pc-setup/actions/workflows/test.yml/badge.svg)](https://github.com/styayur/windows-new-pc-setup/actions/workflows/test.yml)
[中文说明](docs/README.zh-CN.md) · [Project page](https://styayur.github.io/windows-new-pc-setup/) · [Release history](https://github.com/styayur/windows-new-pc-setup/releases)

For Windows users who want a reviewable software list they can reuse on another PC. Select a profile, exclude packages or supply your own JSON manifest. Repeated execution checks installed packages and retries missing ones.

**Version boundary:** these instructions describe the v2 source workflow. The latest public release is still **v1.1.0**; v2.0.0 remains a draft. Old release assets have different defaults. Use a reviewed current checkout for these commands; see [download and verification](docs/operations.md#download-and-version-boundary).

## Quick start

Use Windows PowerShell **5.1** or PowerShell **7**. Clone the complete repository, review the scripts, and start in a normal, non-elevated terminal:

```powershell
git clone https://github.com/styayur/windows-new-pc-setup.git
cd windows-new-pc-setup
./SetupNewPC_Optimized.ps1 -Profile Minimal -WhatIf | ConvertTo-Json -Depth 8
```

`-WhatIf` (also `-Plan`) does not query WinGet, use the network, elevate, create logs/state or register tasks. Actual preview excerpt (2026-10-16; selected fields and package count):

```text
Profile              : Minimal
Stage                : Auto
WSL                  : False
Docker               : False
WinUtil              : False
ConfigureEnvironment : False
PackageCount         : 5
```

After reviewing the full plan and software/source licenses, open a **64-bit administrator terminal as the same Windows user**, return to the checkout, and run:

```powershell
./SetupNewPC_Optimized.ps1 -Profile Minimal -AcceptAgreements
$LASTEXITCODE
```

Actual execution requires Windows 11 client (build 22000+), WinGet 1.8+ and access to the selected package sources. Install/update [Microsoft App Installer](https://aka.ms/getwinget) yourself if needed. No package manager, global execution-policy change or optional integration is installed as a bootstrap step.

## Choose what runs

| Profile | Selected groups |
| --- | --- |
| Minimal | Core: PowerShell 7, 7-Zip, Git, GitHub CLI, Chrome |
| Developer (default when omitted) | Core + Developer |
| AI / Engineering | Core + Developer + the named group |
| Full | All groups, including Personal |

```powershell
./SetupNewPC_Optimized.ps1 -Profile Developer -Exclude Chrome,Postman -SkipStoreApps -WhatIf
./Install-Applications.WithConfirmation.ps1 -Profile Minimal -WhatIf
# After review: add -AcceptAgreements without -WhatIf to execute.
# The confirmation entrypoint asks for Y for each missing package.
```

[The manifest](config/packages.json) is authoritative. A custom `-ConfigPath` replaces it entirely. `Full` does not enable WSL, Docker, WinUtil or extra environment configuration. Those require explicit switches described in [configuration](docs/configuration.md). WinUtil additionally requires a reviewed local file and matching SHA-256; the tool does not download and execute a floating remote script.

## Status, retry and recovery

Inspect `%LOCALAPPDATA%/SetupNewPC/v2/<configuration-hash>/`: `plan.json`, `state.json`, `setup.log` and `environment-report.json` record the run. A custom `-StateDirectory` selects the parent location. There is no separate status subcommand; preview and saved reports are the inspection entrypoints.

| Exit code | Meaning |
| --- | --- |
| 0 | Selected stage completed; inspect warnings |
| 1 / 2 | Execution failure / input or prerequisite failure |
| 3 | User skipped packages; incomplete |
| 3010 | Restart required; incomplete |

For 3010, save work, restart manually and repeat the same command. The tool does not restart Windows or schedule automatic continuation. **There is no automatic uninstall or rollback:** successful package installations and system changes remain. Removing the checkout/state does not undo them. Prepare a recoverable system/configuration backup before provisioning; see [recovery, removal and v1 migration](docs/operations.md).

## Requirements and limits

- Real provisioning is Windows 11 only. Packages, Store region/policy, licenses and installer behavior can change; preview does not verify live availability.
- Installers can modify PATH, services and system settings even without `-ConfigureEnvironment`. WSL/Docker may require restart and manual first-run setup.
- Installed-record checks do not prove every application's functionality. A timed-out installer may leave detached services running; inspect before retrying.
- Existing tests use mocks. Real installation, reboot and WSL/Docker acceptance remain separate [VM checks](tests/VM-CHECKLIST.md).
- `Setupnewpc.ps1` remains a compatibility wrapper. Archived DSC files are historical, not a supported v2 alternative.

## Documentation

[Configuration and optional features (中文)](docs/configuration.md) · [Operation, verification and recovery](docs/operations.md) · [Script boundaries](docs/script-boundaries.md) · [Reusable local entrypoint](examples/Setup-MyPC.ps1) · [Historical material](legacy/README.md)

<a id="快速开始"></a>
<a id="从-v1-迁移"></a>

## License, contributing and security

[MIT](LICENSE) · [Contributing and tests](CONTRIBUTING.md) · [Security](SECURITY.md) · [Issues](https://github.com/styayur/windows-new-pc-setup/issues)

Third-party packages, services and WinUtil retain their own licenses. Reversibility means planning and documenting recovery, not claiming that every system change can be automatically undone.
