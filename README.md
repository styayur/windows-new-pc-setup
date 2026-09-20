# Windows New PC Setup

Windows 11 新机配置示例，包含可执行 PowerShell 脚本和 DSC v3 YAML。

## 重要说明

- 执行前请完整审查代码、软件许可和第三方来源。
- PS1 与 DSC 配置二选一，不要同时执行。
- 建议先在虚拟机或可恢复环境中验证。
- 仓库不保证第三方软件包、下载地址和许可长期不变。
- 商业软件不自动安装，仅保留提示。

## 文件

- `SetupNewPC_Optimized.ps1`：直接运行的 PowerShell 装机脚本。
- `SetupNewPC_Optimized.ps1.txt`：脚本代码文本副本。
- `SetupNewPC.dsc.yaml`：WinGet / DSC v3 配置。
- `SetupNewPC.dsc.yaml.txt`：DSC 配置文本副本。
- `使用说明_PS1与DSC.txt`：完整使用说明。
- `使用说明_PS1与DSC.pdf`：同一使用说明的 PDF 版本。

## PowerShell 快速使用

在管理员 PowerShell 中运行：

```powershell
Unblock-File .\SetupNewPC_Optimized.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\SetupNewPC_Optimized.ps1
```

可选参数：

```powershell
.\SetupNewPC_Optimized.ps1 -SkipWinUtil
.\SetupNewPC_Optimized.ps1 -SkipWSL
.\SetupNewPC_Optimized.ps1 -SkipStoreApps
.\SetupNewPC_Optimized.ps1 -NoPause
```

## DSC 快速使用

推荐使用 WinGet 的 DSC v3 处理器：

```powershell
winget configure validate -f .\SetupNewPC.dsc.yaml
winget configure show -f .\SetupNewPC.dsc.yaml
winget configure test -f .\SetupNewPC.dsc.yaml
winget configure -f .\SetupNewPC.dsc.yaml
```

独立 DSC CLI：

```powershell
dsc config test --file .\SetupNewPC.dsc.yaml
dsc config set --file .\SetupNewPC.dsc.yaml
```

若 `Microsoft.WinGet/Package` 资源不可用，请更新 WinGet，优先使用 `winget configure` 路线。

## 安全建议

- 不要在不了解内容时执行远程脚本。
- WinUtil 资源适合可信任环境；可使用 PS1 的 `-SkipWinUtil`，或在 DSC 中删除对应资源。
- 企业环境应先检查代理、证书、源策略和许可证。
- 不要在域控制器、生产服务器或他人设备上直接运行。