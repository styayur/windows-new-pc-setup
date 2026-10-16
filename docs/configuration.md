# 配置参考 / Configuration

[English README](../README.md) · [运行、恢复与迁移](operations.md)。下列命令从仓库根目录执行，实际安装前先用 `-WhatIf` 审阅。

## 选择配置
| Profile | 软件分组 |
| --- | --- |
| Minimal | Core：PowerShell 7、7-Zip、Git、GitHub CLI、Chrome |
| Developer（默认） | Core + Developer：VS Code、Node.js LTS、Python、uv、Java、Go、Rustup 等 |
| AI | Core + Developer + AI |
| Engineering | Core + Developer + Engineering |
| Full | 所有分组，含 Personal |

完整清单以 [config/packages.json](../config/packages.json) 为准。Clash、游戏、截图及硬件诊断等个人偏好工具属于 Personal，默认不安装；`Full` 也不会自动启用 WSL、Docker 或 WinUtil。

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

需要复用同一套参数时，可以复制 [examples/Setup-MyPC.ps1](../examples/Setup-MyPC.ps1)，修改其中参数，之后一直执行这个入口。路径相对入口文件定位，不依赖当前工作目录。

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
