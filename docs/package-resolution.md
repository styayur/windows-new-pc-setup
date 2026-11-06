# Package resolution and metadata

## Schema 2

`config/packages.json` uses schema 2. Every package includes:

| Field | Purpose |
| --- | --- |
| `Key` | Stable internal selector, independent of display name |
| `Name` | Human-readable name |
| `Vendor` | Vendor distinction shown in ambiguity/candidate output |
| `Id` | Exact WinGet/MSStore package identifier |
| `Source` | `winget` or `msstore` |
| `Architecture` | `auto`, `x64`, `arm64` or `neutral` |
| `Scope` | `auto`, `user` or `machine` |
| `VersionPolicy` | `latest` or `pinned` |
| `Stage` | `WindowsBase` or `Development` |
| `Category` / `Groups` | Profile selection metadata |
| `Privilege` | `user` or `elevated` |
| `Dependencies` | Stable package Keys |
| `Conflicts` | Stable package Keys that cannot be selected together |
| `ExpectedState` | `installed` or `absent` (rc.1 executes only `installed`) |
| `Reboot` | `never`, `possible` or `required` |
| `Recovery` | Manual/external strategy and instructions |

`Profiles` and top-level `Groups` are also part of the catalog. Profiles are not hard-coded in the new planner.

## Resolution algorithm

1. Match an exact stable Key.
2. Else match an exact package ID and optional source qualifier.
3. If an ID matches multiple sources and no source was supplied, fail and show all candidates.
4. If a display name matches, refuse it as an installation selector and show the stable Keys/IDs to use instead.
5. If no match exists, show nearby candidates.

Display-name similarity never causes an automatic installation.

## Dependency and conflict validation

- Every dependency must name an existing stable Key.
- Selected dependencies are auto-included.
- Excluding a required dependency fails.
- Cycles fail with the unresolved node list.
- Declared conflicts fail before any operation runs.
- Stage-limited requests fail if they exclude a dependency stage.

## Version behavior

- `latest`: installer chooses the current package version.
- `pinned`: install/verify an exact version where WinGet supports it.
- An installed version that differs from a pin is a conflict; Whinset does not silently upgrade or downgrade.
- `Version` plus explicit `user`/`machine` scope remains rejected because WinGet export cannot reliably verify version per scope.

## Architecture and scope

`auto` means the package manager manifest chooses the host-compatible installer and scope. Explicit `x64`, `arm64`, `user` or `machine` values are surfaced in the plan. The current catalog preserves existing machine-wide package behavior: package operations are classified as elevated unless a package is explicitly declared user-level (the msstore ChatGPT entry is user-level).

## Custom catalogs

In v2.0.0-rc.1, custom catalogs are accepted by `plan` but blocked for `whinset apply`. The elevated worker reconstructs plans only from the installed built-in catalog so a plan cannot introduce arbitrary elevated package operations at execution time. Use the legacy entrypoint for reviewed custom-manifest workflows until catalog trust pinning is implemented.
