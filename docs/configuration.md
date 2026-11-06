# Configuration

The authoritative catalog is `config/packages.json` (schema 2). Profiles, groups and package metadata are data, not display-name heuristics.

## Top-level shape

```json
{
  "SchemaVersion": 2,
  "CatalogVersion": "2026.11.06",
  "Profiles": {
    "minimal": { "Groups": ["Core"], "Description": "Core Windows setup essentials." }
  },
  "Groups": ["Core", "Developer", "AI", "Engineering", "Personal"],
  "Packages": []
}
```

## Package fields

See [package resolution](package-resolution.md) for field meanings and conflict/cycle rules. A representative entry:

```json
{
  "Key": "Git",
  "Name": "Git",
  "Vendor": "Git Project",
  "Id": "Git.Git",
  "Source": "winget",
  "Architecture": "auto",
  "Scope": "auto",
  "VersionPolicy": "latest",
  "Stage": "WindowsBase",
  "Category": "Core",
  "Groups": ["Core"],
  "Privilege": "elevated",
  "Dependencies": [],
  "Conflicts": [],
  "ExpectedState": "installed",
  "Reboot": "possible",
  "Recovery": {
    "Class": "manual",
    "AutomaticRollback": false,
    "Instructions": "Review Windows Settings or run the exact WinGet uninstall command."
  }
}
```

## Profiles

The built-in profiles are:

| Profile | Groups |
| --- | --- |
| Minimal | Core |
| Developer | Core, Developer |
| AI | Core, Developer, AI |
| Engineering | Core, Developer, Engineering |
| Full | Core, Developer, AI, Engineering, Personal |

`-Group`, `-IncludePersonal`, `-Package` and `-Exclude` modify the selected set. `Full` does not automatically enable WSL, Docker or environment configuration.

## Optional operations

| Option | Added operations | Privilege |
| --- | --- | --- |
| `-ConfigureEnvironment` | selected tool-specific config operations | user and elevated depending on target |
| `-EnableWsl` | WSL feature setup + WSL 2/Ubuntu runtime | elevated |
| `-EnableDocker` | WSL operations + Docker Desktop | elevated |
| `-DockerSmokeTest` | `docker run --rm hello-world` | elevated |
| `-SkipCondaInit` | skips conda PowerShell profile initialization | user |

## Custom catalogs in rc.1

Use `whinset plan -ConfigPath <path>` to inspect a custom schema-2 catalog. Schema 1 remains readable by the legacy entrypoints. `whinset apply` intentionally blocks custom catalogs in this release candidate because the elevated worker trusts only the installed built-in catalog. Use a reviewed legacy `SetupNewPC_Optimized.ps1` custom-manifest flow until catalog pinning is implemented.

## Legacy schema

Schema 1 catalogs remain readable by the legacy entrypoints. New catalogs should use schema 2.
