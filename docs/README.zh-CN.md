# Whinset 中文说明

**可审查的 Windows 11 装机计划、精确软件 ID、依赖 DAG 与单次 UAC 提权。**

当前源码版本为 **v2.0.0-rc.1**。由于尚未完成真实 Windows 11 虚拟机中的 UAC、系统功能和重启续跑验收，暂不发布最终 v2.0.0。

[English README](../README.md) · [CLI](cli.md) · [软件解析](package-resolution.md) · [安全模型](security-model.md) · [恢复](recovery.md)

## 下载前必须了解

- 管理员操作可能安装机器级软件、启用 Windows 可选功能、安装 WSL/Ubuntu 和 Docker Desktop，并修改机器 `JAVA_HOME`/`PATH`。
- 用户级操作可能修改 Git LFS、uv、Conda、Go、Rust 和用户环境变量。
- `apply` 仅在仍有管理员操作时请求一次正常 Windows UAC。不会绕过、关闭或隐藏 UAC。
- 拒绝 UAC 时不会启动提升后的工作进程，退出码为 **4**。
- 可能需要重启；Whinset 返回 **3010**，不会自动重启或创建续跑任务。
- 成功安装和系统修改不会自动回滚。部分注册表、服务、PATH、WSL 和 Docker 状态只能人工恢复。
- 日志和状态保存在 `%LOCALAPPDATA%\Whinset\v2`。

## 快速开始

`beatwin.txt` 默认处于安全预览模式：

1. 下载固定的 `v2.0.0-rc.1` Release 资产。
2. 先校验固定 SHA-256。
3. 解压到临时目录。
4. 运行 `plan`。
5. 结束后删除临时目录。

审阅计划、软件许可证和恢复限制后，在粘贴内容中把 `$WhinsetMode = 'plan'` 改为 `'apply'`。`apply` 仍会重新构建并验证计划。

## 安装命令

```powershell
pwsh -NoProfile -File .\whinset.ps1 plan -Profile Developer
pwsh -NoProfile -File .\whinset.ps1 install-cli
```

打开新终端后：

```powershell
whinset version
whinset plan -Profile Developer
whinset apply -Profile Minimal -AcceptAgreements
whinset status
whinset doctor
whinset recover -Retry
```

## 软件选择

使用稳定的 `Key` 或精确的 `Source:Id`：

```powershell
whinset plan -Profile Minimal -Exclude Chrome
whinset plan -Profile Developer -Package uv,Git
whinset resolve chrome
```

显示名称不会作为安装选择器。同名/近似包必须通过 `Key` 或 `winget:<id>` / `msstore:<id>` 明确指定。依赖会自动加入；循环依赖、未知依赖和冲突会在执行前失败。

## 退出码

`0` 完成，`1` 操作失败，`2` 输入/计划/协议错误，`3` 兼容流程取消，`4` 拒绝 UAC，`5` doctor 不健康，`3010` 需要重启。

## 兼容性

旧的 `SetupNewPC_Optimized.ps1`、`Setupnewpc.ps1`、逐项确认脚本、schema 1 清单和旧状态目录仍保留。新命令只读发现旧 `SetupNewPC\v2` 状态；迁移方式是重新运行 `whinset plan`/`apply`，按实际安装状态补缺，不删除旧状态。

MIT License.
