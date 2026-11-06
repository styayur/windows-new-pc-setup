# RC.2 acceptance evidence

Date: 2026-11-07 (Asia/Singapore). Decision: RC.2 only; Stable is not eligible.

The [machine-readable matrix](windows-v2.0.0-rc.2.json) distinguishes PASS, FAIL, NOT RUN, BLOCKED and NOT APPLICABLE. Each PASS identifies its evidence scope. It records the tested runtime revision; later release metadata/version preparation is verified by the release-preparation PR CI.

| Evidence | Result | Scope |
| --- | --- | --- |
| [PowerShell CI](https://github.com/styayur/whinset/actions/runs/42263019789) | PASS | PowerShell 5.1 and 7 legacy/Whinset/hardening suites; static analysis, catalog/module checks and reproducible builds |
| [Hosted shell snapshot](evidence/rc2-shells-ci.json) | 17 PASS; Nushell NOT RUN | Real read-only CLI invocation: PS5.1, PS7, CMD, Git Bash and module checks |
| [Local shell snapshot](evidence/rc2-shells-local.json) | 21 PASS | Same read-only checks plus Nushell 0.116.1 |
| [Hardening PS5.1](evidence/rc2-hardening-ps51.json) / [PS7](evidence/rc2-hardening-ps7.json) | 19 PASS each | Simulated UAC/transport/operations; actual temporary state-file/ACL I/O |
| [Disposable package integration](https://github.com/styayur/whinset/actions/runs/42263020010) | PASS | Actual Notepad3 fresh installation and AlreadyInstalled repeat on the actual hosted OS; [snapshot](evidence/rc2-package-ci.json) |
| Independent interactive Windows 11 VM | BLOCKED | No connected disposable interactive environment; individual gates remain NOT RUN |

The security regression covers identical/different SIDs, native denial classification, grant/deny/launch/crash/missing-result transport simulations, wrong/stale/replayed requests, modified graph/catalog and mismatched state. Recovery evidence covers repeated reconciliation, interrupted package execution, partial elevated phase, interrupted atomic state writes, reboot flags/boot-ID changes, package rechecks, concurrent apply rejection and inconsistent state rejection. These tests do not claim real UAC, power-loss durability or physical reboot acceptance.

No privileged installer or system modification was run on the developer machine. Local writes were limited to source, build output and temporary test files/ACLs. The actual package installation occurred only in a disposable hosted runner.

Outstanding independent acceptance is listed by every `RequiredForStable: true` matrix row and the [VM checklist](../../tests/VM-CHECKLIST.md): real same-user UAC grant/deny and different-user rejection; profile isolation; clean Windows 11 multi-package apply/idempotency; installer timeout/interruption; restart 3010/same-boot gate/post-boot continuation; WSL features, original-user registration and first run; Docker machine install, original-user first run and hello-world; actual published-bootstrap download/apply; vendor uninstall/manual recovery. Retain commands, both SIDs, boot IDs, state/JSONL logs, VM snapshot identity and independent reviewer sign-off. Keep [Issue #8](https://github.com/styayur/whinset/issues/8) open.
