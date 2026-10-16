# Windows New PC Setup 中文说明

可预览、可审查、可重复执行的 Windows 11 装机工具，以 WinGet JSON 清单选择软件，并显式控制 WSL、Docker 和环境配置。

[English README](../README.md) · [配置参考](configuration.md) · [状态、恢复与迁移](operations.md)

## 快速开始

当前受维护源码是 v2 流程；公开最新版 v1.1.0 的默认行为不同，v2.0.0 尚为草稿。请克隆或下载整个当前仓库，不要只下载单个 PS1，也不要套用旧 Release 的命令。

```powershell
git clone https://github.com/styayur/windows-new-pc-setup.git
cd windows-new-pc-setup
./SetupNewPC_Optimized.ps1 -Profile Minimal -WhatIf | ConvertTo-Json -Depth 8
```

预览不联网、不查询 WinGet、不提权、不创建状态或日志。需要 Windows PowerShell 5.1 或 PowerShell 7；实际执行需要 Windows 11 客户端、64 位当前用户管理员终端、WinGet 1.8+ 和所选软件源的网络访问。审查下载文件，不要默认更改执行策略。

审阅完整清单和软件许可后，在同一 Windows 用户的管理员终端执行：

```powershell
./SetupNewPC_Optimized.ps1 -Profile Minimal -AcceptAgreements
$LASTEXITCODE
```

`Minimal` 选择五个 Core 包；省略 `-Profile` 默认是 Developer。`Full` 包含个人偏好工具，但不会自动启用 WSL/Docker/WinUtil。安装器自身可能修改 PATH、服务和系统设置；可撤销不代表脚本有自动回滚。

## 常用入口

```powershell
./SetupNewPC_Optimized.ps1 -Profile Developer -SkipStoreApps -WhatIf
./Install-Applications.WithConfirmation.ps1 -Profile Minimal -WhatIf
# 完成审阅后才传 -AcceptAgreements；逐项入口仍需对缺少的包输入 Y。
```

配置清单和可选功能见[配置参考](configuration.md)。退出码 3010 时保存工作、手动重启，再执行相同命令。状态与日志默认在 `%LOCALAPPDATA%/SetupNewPC/v2/<配置哈希>/`；0 为所选阶段完成，1 失败，2 参数/前置检查失败，3 用户跳过，3010 待重启。状态不能跨机器/账号作为成功凭据。

**没有自动卸载或回滚。** 成功安装和系统修改会保留。删除脚本或状态目录不会撤销它们；真实装机前准备可恢复备份。详见[恢复、移除和旧版迁移](operations.md)。旧 DSC 位于 [legacy](../legacy/README.md)，不是当前入口。

真实应用安装、重启及 WSL/Docker 验收需可恢复的 Windows 11 虚拟机；模拟测试不等于端到端验收。见[验收清单](../tests/VM-CHECKLIST.md)。

[MIT](../LICENSE) · [贡献与测试](../CONTRIBUTING.md) · [安全报告](../SECURITY.md)
