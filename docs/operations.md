# Operation, recovery and removal / 运行与恢复

[Back to README](../README.md) · [配置参考](configuration.md)

## Download and version boundary

The maintained checkout implements the v2 workflow. As audited on 2026-10-16, the latest public release is **v1.1.0** and v2.0.0 remains an unpublished draft. Do not use v1 assets with v2 commands or assume they have the same defaults. v1 can execute downloaded WinUtil and create a resume task. Prefer a reviewed checkout of `main` for the workflow documented here; record `git rev-parse HEAD` to identify the exact source. A GitHub-generated source ZIP does not include a separately published checksum manifest.

[Release history](https://github.com/styayur/windows-new-pc-setup/releases) is retained for existing users. The public v1.1.0 assets have no `SHA256SUMS.txt`. Where GitHub supplies an asset digest, compare its complete `sha256:` value with `Get-FileHash <exact-downloaded-file> -Algorithm SHA256`; otherwise no publisher checksum is available. Do not treat a locally calculated hash alone as provenance.

For a future published v2 bundle, use the exact archive filename shown on that release, download its accompanying `SHA256SUMS.txt`, and compare the full hash before extracting. The automated workflow uses `windows-new-pc-setup-vX.Y.Z.zip`; the existing unpublished draft uses `SetupNewPC-v2.0.0.zip`. Do not guess a download URL or rename assets to hide a mismatch.

No remote script execution or execution-policy adjustment is required. Review downloaded files before using `Unblock-File` if permitted by local policy; organization signing requirements still apply.

## Undo and uninstall limits

There is **no automatic rollback or general uninstall command**. Rerunning reconciles installation records and retries missing/failed packages; it does not undo successful changes. Removing the checkout or state directory does not uninstall applications, disable WSL/Docker, restore PATH/environment values or reverse WinUtil changes.

Before real provisioning, use a recoverable Windows 11 VM snapshot or your normal system/configuration backup process. For an unwanted package, use its supported uninstaller or an individually reviewed WinGet uninstall command. Review package data and dependencies first. Restore environment/profile changes from your own prior backup; this tool does not capture a complete before-image of the system. WSL distributions can hold user data and require separate backup before removal.

Keep `plan.json`, `state.json` and logs until failures/reboot requirements are resolved. Once no setup process is running and you no longer need the records, remove only the dedicated checkout/state directory you chose. Logs may contain private package inventories or installer output; redact before sharing.

## 重试、重启与状态
安装顺序是 WindowsBase → 重启检查 → Development。脚本不主动重启，不注册自动登录任务。遇到返回码 `3010`，保存工作、手动重启，然后**再次执行相同命令**。软件安装返回重启要求后停止启动后续安装器；同一启动周期内再次运行也不会越过重启检查。

每次运行都会重新检查实际安装情况：已安装则跳过、被卸载则重装、失败则重试。Auto 模式在重启后也会检查基础阶段，避免丢失此前失败的包。`-Stage WindowsBase` 或 `-Stage Development` 适用于手动分阶段，第二阶段启用 WSL 时仍会检查重启前置条件。

状态默认保存到 `%LOCALAPPDATA%\SetupNewPC\v2\<配置哈希>\`，也可用 `-StateDirectory D:\SetupState` 指定父目录。配置、选中的包或功能选项变化会进入新状态目录；重试次数和超时参数变化不会创建新配置。状态还校验机器与用户身份，不能复制到另一台电脑作为成功凭据。

| 文件 | 内容 |
| --- | --- |
| `plan.json` | 实际配置快照，便于审阅 |
| `state.json` / `state.json.bak` | 逐项结果、安装尝试次数、上次状态备份 |
| `setup.log` | 追加式执行日志，含安装器输出 |
| `environment-report.json` / `.txt` | 所选包安装核验结果；JSON 另含配置步骤结果 |
| `virtualization-report.json` / `docker-readiness.json` | 启用相关功能时的诊断 |

状态以同目录临时文件加原子替换写入。损坏或身份不匹配时停止执行，保留原文件；查明原因后可指定新的 `-StateDirectory` 重新核验。全机互斥锁避免两个装机进程并行操作安装器和状态。

| 退出码 | 含义 |
| --- | --- |
| 0 | 当前所选阶段完成；诊断警告仍需查看日志 |
| 1 | 当前运行存在安装、核验或配置失败 |
| 2 | 参数、配置、协议接受、权限或前置检查失败 |
| 3 | 有软件被用户主动跳过，清单尚未全部完成 |
| 3010 | 等待重启，尚未全部完成 |

失败优先于其他退出码；若日志同时提示重启，先重启再重试。源码被 PowerShell 拒绝解析、执行策略阻止、参数绑定失败等宿主错误不受此退出码约定控制。

## 故障处理与限制
- 先运行 `winget --version`、`winget source list`，按日志检查网络、代理、源策略。脚本不自动重置源或绕过证书/哈希检查。
- 默认安装失败最多尝试两次；`-MaxAttempts 1..5`、`-InstallTimeoutSeconds 30..14400` 可调整。查询出错会明确失败，不会当作“未安装”继续安装。
- WinGet 安装超时会尝试终止该进程树，并停止本轮后续安装；脱离进程树的安装服务可能仍在工作，重试前检查日志和任务管理器。没有自动卸载/回滚；部分安装成功的项目保留。
- `--silent`、安装范围及 Store 的交互行为受第三方包支持情况影响。企业策略、地区限制、软件许可证、首次登录不能由脚本保证。
- “安装完成”核验的是 WinGet 可识别的安装记录，不保证每个 GUI 应用首次启动或业务功能正常。WSL、Docker 及显式环境配置另有运行时检查。
- 使用 `-WhatIf | ConvertTo-Json -Depth 8` 查看完整清单；普通表格输出可能折叠 Packages。

## 从 v1 迁移
`Setupnewpc.ps1` 与逐项确认入口仍保留，但必须同时带上 `src/` 与 `config/`。默认 WinUtil、WSL、Docker、环境修改、自动提权、自动续跑和暂停均已取消。`-NoPause` / `-NoResume` 作为无操作兼容参数保留，`-AllowReboot` 会明确报错。旧 `%ProgramData%\SetupNewPC` 状态不会导入。

如果 v1 曾注册过续跑任务，升级前检查并移除该旧任务，避免登录时又运行 v1：

```powershell
Get-ScheduledTask -TaskName 'SetupNewPC-Resume-After-Reboot' -ErrorAction SilentlyContinue
# 确认属于旧版装机脚本后：
Unregister-ScheduledTask -TaskName 'SetupNewPC-Resume-After-Reboot' -Confirm:$false
```

旧 DSC 和说明已归档到 [legacy/](../legacy/README.md)，不是 v2 的等价入口，不要与新脚本混用。脚本 `.txt` 镜像已移除，避免多份实现漂移。
