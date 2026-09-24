# Windows New PC Setup

可配置、可预览、可重复执行的 Windows 11 新机装机脚本。支持 Windows PowerShell 5.1 和 PowerShell 7，使用 WinGet 安装缺少的软件；WSL、Docker、WinUtil 和环境变量配置均为显式选项。

下载：[最新 Release](https://github.com/styayur/windows-new-pc-setup/releases/latest) · [v2.0.0 升级说明](docs/releases/v2.0.0.md)。优先下载 Release 中的完整 ZIP，并用附带的 SHA256 文件校验。

## 快速开始

下载并解压**整个仓库**，保留 `src/` 和 `config/`。不要只下载单个 PS1。先在普通 PowerShell 中预览：

```powershell
.\SetupNewPC_Optimized.ps1 -Profile Developer -WhatIf | ConvertTo-Json -Depth 8
```

检查清单和软件许可后，在**当前用户的管理员 PowerShell** 中运行：

```powershell
.\SetupNewPC_Optimized.ps1 -Profile Developer -AcceptAgreements
$LASTEXITCODE
```

若下载的文件被阻止，可在检查文件后运行 `Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File`；执行策略需要调整时只针对当前进程：`Set-ExecutionPolicy -Scope Process Bypass`。

要求 Windows 11 客户端、64 位 PowerShell、WinGet 1.8+、可访问所选软件源的网络。缺少 WinGet 时，先安装或更新 [Microsoft App Installer](https://aka.ms/getwinget)，再打开新终端。脚本不自行安装包管理器，不改变全局执行策略或软件源。不要以另一个管理员账号代跑：用户软件、WSL 和配置会属于执行账号。

## 选择配置

| Profile | 软件分组 |
| --- | --- |
| Minimal | Core：PowerShell 7、7-Zip、Git、GitHub CLI、Chrome |
| Developer（默认） | Core + Developer：VS Code、Node.js LTS、Python、uv、Java、Go、Rustup 等 |
| AI | Core + Developer + AI |
| Engineering | Core + Developer + Engineering |
| Full | 所有分组，含 Personal |

完整清单以 [config/packages.json](config/packages.json) 为准。Clash、游戏、截图及硬件诊断等个人偏好工具属于 Personal，默认不安装；`Full` 也不会自动启用 WSL、Docker 或 WinUtil。

```powershell
# 不下载、不查询 WinGet、不提权、不创建目录、日志或计划任务
.\SetupNewPC_Optimized.ps1 -Profile Full -SkipStoreApps -WhatIf

# 排除软件，增加分组；名称使用清单中的 Key 或完整 Id
.\SetupNewPC_Optimized.ps1 -Profile Developer -ExtraGroups AI,Engineering `
    -Exclude Chrome,Postman -SkipStoreApps -AcceptAgreements

# 每个缺少的软件单独输入 Y；其他输入跳过。默认 Developer，可显式选择 Full
.\Install-Applications.WithConfirmation.ps1 -Profile Full -AcceptAgreements

# 按需启用 WSL2 + Ubuntu；Docker 会同时启用 WSL
.\SetupNewPC_Optimized.ps1 -Profile Developer -EnableWSL -AcceptAgreements
.\SetupNewPC_Optimized.ps1 -Profile Developer -EnableDocker -AcceptAgreements
```

`-AcceptAgreements` 授权本次调用向 WinGet 传递软件源和安装包协议接受参数。逐项模式仍会对每个缺少的包询问；无人值守调用不要传 `-ConfirmEach`。

## 自定义软件清单

复制 `config/packages.json`，删除不需要的项目或添加自己的项目，然后传 `-ConfigPath`。自定义文件**替换整个清单**，不与默认文件合并；软件按文件顺序、分阶段执行。

```json
{
  "SchemaVersion": 1,
  "Packages": [
    {
      "Key": "Git",
      "Name": "Git",
      "Id": "Git.Git",
      "Source": "winget",
      "Stage": "WindowsBase",
      "Category": "Core",
      "Groups": ["Core"]
    }
  ]
}
```

```powershell
.\SetupNewPC_Optimized.ps1 -ConfigPath .\config\my-packages.json -WhatIf
.\SetupNewPC_Optimized.ps1 -ConfigPath .\config\my-packages.json -AcceptAgreements
```

- 必填字段如上；`Key` 和 `Id` 不可重复。未知字段、分组、源及排除项会立即报错。
- `Source` 只接受 `winget` / `msstore`；`Stage` 为 `WindowsBase` / `Development`；分组与上表一致，`Category` 也使用这些分组名。
- 可选 `Version` 固定 WinGet 包版本；已安装其他版本时报告冲突，**不会自动升级或降级**。使用 `winget export` 的结构化结果核对版本；不解析本地化表格。
- 可选 `Scope` 为 `user` / `machine`，只对支持该范围的包有效。`Version` 与 `Scope` 不能同时使用，因为 WinGet 导出不能可靠地按安装范围核对版本。Store 包不接受 `Version`。
- Docker 不允许绕过依赖检查放入软件清单，应使用 `-EnableDocker`。
- 自定义包不运行任意命令、下载脚本或安装器参数。ID、版本、许可和架构是否仍然可用，由执行时的软件源决定。

需要复用同一套参数时，可以复制 [examples/Setup-MyPC.ps1](examples/Setup-MyPC.ps1)，修改其中参数，之后一直执行这个入口。路径相对入口文件定位，不依赖当前工作目录。

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

## 可选环境配置

`-ConfigureEnvironment` 会针对本次选择且成功安装的软件执行 Git LFS 初始化、JAVA_HOME/PATH、Go GOPATH、Rust stable，以及 uv/conda 策略。默认只安装包，不执行这些额外配置。安装器自身仍可能修改 PATH 和系统设置。

```powershell
.\SetupNewPC_Optimized.ps1 -Profile Engineering -ConfigureEnvironment `
    -SkipCondaInit -AcceptAgreements
```

`-SkipCondaInit` 跳过 PowerShell profile 初始化；conda 自动激活 base 仍会关闭。系统 Python 用于普通脚本和 uv 项目，conda 用于显式科学计算环境。不要在已有复杂开发环境上无审阅地启用这些配置。

Docker Desktop 安装后需手动打开、接受许可并完成首次设置。后台服务没有运行不等于安装失败：脚本用 Docker daemon 的实际响应判断可用性，并将未启动记录为警告。显式加 `-DockerSmokeTest` 时，会拉取并运行 `hello-world`；daemon 不可用将作为测试失败。Ubuntu 首次 Linux 用户创建也需自行完成，脚本不会代设密码。

WinUtil 仅接受已审阅的本地脚本和固定 SHA256，不再下载并执行浮动的远程脚本：

```powershell
.\SetupNewPC_Optimized.ps1 -EnableWinUtil -WinUtilPath D:\Reviewed\winutil.ps1 `
    -WinUtilSha256 '<审阅版本的64位SHA256>' -AcceptAgreements
```

同一配置已成功执行的 WinUtil 不会重复执行。哈希只能证明文件与审阅版本一致，不代表第三方行为安全。WinUtil 的内部网络访问和更改由其自身实现决定。

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

旧 DSC 和说明已归档到 [legacy/](legacy/README.md)，不是 v2 的等价入口，不要与新脚本混用。脚本 `.txt` 镜像已移除，避免多份实现漂移。

## 验证与维护

```powershell
# 不会安装应用或启用系统功能；测试只在临时目录写测试数据
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

GitHub Actions 在两种 PowerShell 上运行相同回归测试。测试覆盖预览、配置校验、命令行转义、超时、WinGet 失败/重试/重启、用户跳过、原子状态、身份隔离与重复运行。真实安装、重启及 BIOS/WSL/Docker 的端到端验收需在可恢复 Windows 11 虚拟机执行，见 [tests/VM-CHECKLIST.md](tests/VM-CHECKLIST.md)。

实现依据：[WinGet install](https://learn.microsoft.com/windows/package-manager/winget/install)、[list](https://learn.microsoft.com/windows/package-manager/winget/list)、[退出码](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md)、[WSL 命令](https://learn.microsoft.com/windows/wsl/basic-commands)。

## 许可证

项目采用 [MIT License](LICENSE)。第三方软件、软件包、服务及 WinUtil 遵循各自许可证。
