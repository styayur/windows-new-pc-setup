# Windows New PC Setup

Windows 11 新机配置示例，按“Windows 基础 -> 重启门 -> 开发环境”组织，
包含可续跑的 PowerShell 脚本和两阶段 DSC v3 YAML。

在线说明：https://styayur.github.io/windows-new-pc-setup/

## 重要说明

- 执行前请完整审查代码、软件许可和第三方来源。
- PS1 与 DSC 配置二选一，不要同时执行。
- WSL/VMP 功能可能需要重启；PS1 会保存状态并自动续跑，DSC 需要重启后执行第二阶段。
- 建议先在虚拟机或可恢复环境中验证。
- 仓库不保证第三方软件包、下载地址和许可长期不变。
- 商业软件不自动安装，仅保留提示。

## 文件

- `SetupNewPC_Optimized.ps1`：主 PowerShell 装机脚本，支持 Profile、逐项状态、重试、Auto/WindowsBase/Development 阶段。
- `SetupNewPC_Optimized.ps1.txt`：脚本代码文本副本。
- `SetupNewPC.WinBase.dsc.yaml`：DSC 阶段 1，Windows 基础与 WSL/VMP 功能启用。
- `SetupNewPC.WinBase.dsc.yaml.txt`：阶段 1 文本副本。
- `SetupNewPC.Development.dsc.yaml`：DSC 阶段 2，重启后的 Docker 与开发环境。
- `SetupNewPC.Development.dsc.yaml.txt`：阶段 2 文本副本。
- `installfirsttwoapplications.txt`：人工安装顺序、包 ID 和 Python/conda 分工。
- `使用说明_PS1与DSC.txt`：完整使用说明。
- `使用说明_PS1与DSC.pdf`：同一使用说明的 PDF 版本。

## 在线说明页

- `index.html`：GitHub Pages 使用的详细说明、使用方法、自定义指南和故障排查页面。

## PowerShell 快速使用

在管理员 PowerShell 中运行：

```powershell
Unblock-File .\SetupNewPC_Optimized.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\SetupNewPC_Optimized.ps1 -Profile Developer
```

默认 `-Stage Auto` 会先执行 Windows 基础；如果 WSL/VMP 要求重启，会登记
登录续跑任务。重启后自动进入 Development 阶段。

可选参数：

```powershell
.\SetupNewPC_Optimized.ps1 -Profile AI -IncludePersonal -DockerSmokeTest
.\SetupNewPC_Optimized.ps1 -Profile Engineering -SkipCondaInit
.\SetupNewPC_Optimized.ps1 -Profile Full -EnableWinUtil -WinUtilSha256 <64-hex-hash>
.\SetupNewPC_Optimized.ps1 -Profile Developer -SkipWSL -NoPause
```

## DSC 快速使用

推荐使用 WinGet 的 DSC v3 处理器。先执行阶段 1：

```powershell
winget configure validate -f .\SetupNewPC.WinBase.dsc.yaml
winget configure show -f .\SetupNewPC.WinBase.dsc.yaml
winget configure -f .\SetupNewPC.WinBase.dsc.yaml
```

若输出 `REBOOT REQUIRED`，重启后执行阶段 2：

```powershell
winget configure validate -f .\SetupNewPC.Development.dsc.yaml
winget configure show -f .\SetupNewPC.Development.dsc.yaml
winget configure -f .\SetupNewPC.Development.dsc.yaml
```

独立 DSC CLI：

```powershell
dsc config test --file .\SetupNewPC.WinBase.dsc.yaml
dsc config set --file .\SetupNewPC.WinBase.dsc.yaml
# 重启后
dsc config test --file .\SetupNewPC.Development.dsc.yaml
dsc config set --file .\SetupNewPC.Development.dsc.yaml
```

若 `Microsoft.WinGet/Package` 资源不可用，请更新 WinGet，优先使用 `winget configure` 路线。

## 安全建议

- 不要在不了解内容时执行远程脚本。
- WinUtil 在 PS1 中默认跳过；只有 `-EnableWinUtil` 才下载到本地并校验 SHA256，随后才执行 Standard preset。
- 企业环境应先检查代理、证书、源策略和许可证。
- 不要在域控制器、生产服务器或他人设备上直接运行。

## 许可证

本项目源代码和文档采用 MIT License，详见 [LICENSE](LICENSE)。

配置中涉及的第三方软件、软件包和在线服务仍分别受其自身许可证约束。
