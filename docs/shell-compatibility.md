# Shell compatibility

PowerShell is the single execution core. `-Json` is the machine-readable interface. JSON uses UTF-8 stdout, including Windows PowerShell 5.1. Human command errors use stderr; JSON errors remain a single stdout object. Callers must also check the process exit code.

| Shell | Support | Invocation | Coverage |
| --- | --- | --- | --- |
| PowerShell 7 | Official | `pwsh -NoProfile -File ./whinset.ps1 version -Json` | Windows CI and local |
| Windows PowerShell 5.1 | Official | `powershell.exe -NoProfile -File ./whinset.ps1 version -Json` | Windows CI and local |
| CMD | Official | `whinset.cmd version -Json` | Windows CI and local |
| Git Bash | Experimental | `bash ./whinset.sh version -Json` | Required Windows CI and local |
| Nushell | Experimental | `nu --no-config-file ./whinset.nu version -Json` | Local when installed; CI records NOT RUN when unavailable |

CMD, Git Bash and Nushell adapters prefer `pwsh.exe`, falling back to `powershell.exe`. They contain argument forwarding only. They do not implement package installation. Use Git for Windows Bash; WSL Bash is a different environment and is not supported by this adapter.

Examples of literal, single arguments:

```cmd
whinset.cmd plan -ConfigPath "C:\reviewed files\packages.json" -Offline -Json
```

```bash
bash ./whinset.sh resolve 'Google Chrome' -Json
```

```nu
nu --no-config-file ./whinset.nu resolve 'Google Chrome' -Json | from json
```

The test suite copies the real CLI under a directory containing spaces and Unicode. It checks JSON parsing, a literal argument containing Unicode, spaces, embedded quotes and a trailing backslash, human stderr, invalid-input exit 2 and successful exit 0. Offline planning is read-only. These tests do not run installers, UAC, reboots or first-run initialization. Shell metacharacters still follow the invoking shell's quoting rules; there is no promise that unquoted `%`, `$`, `&` or similar syntax is literal. For PowerShell array parameters, use native PowerShell/module invocation; other shells should use one selector per invocation or a reviewed profile.

Run `./tests/Run-ShellTests.ps1 -RequireGitBash -EvidencePath <absolute-json-path>` to generate evidence. `-RequireNushell` turns a missing Nushell executable into FAIL. Evidence statuses are PASS, FAIL or NOT RUN; the release acceptance matrix additionally supports BLOCKED and NOT APPLICABLE.
