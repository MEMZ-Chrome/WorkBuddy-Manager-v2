# WorkBuddy Manager

管理同一台机器上 WorkBuddy 国内版 / 国际版（WorkBuddy AI）的 PowerShell 小工具。

## 功能

| 选项 | 作用 |
|------|------|
| `[1] Scan installs` | 自动扫描常见安装位置，显示每个安装的版本与身份（国内/国际） |
| `[2] Disable force-update` | 关闭启动强制更新，写入后回读校验，有进程在跑会中止并提示 |
| `[3] Show key info` | 查看关键信息，并检测两版单实例锁 / 数据目录是否冲突 |

## 用法

右键 `WorkBuddy-Manager.ps1` → 用 PowerShell 运行；或在 PowerShell 中执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WorkBuddy-Manager.ps1
```

## 说明

- 脚本只修改安装目录下的 `resources\app.asar.unpacked\cli\product.json`；
- 修改前会在 `%LOCALAPPDATA%\Programs\workbuddy-fix-backup` 留下带时间戳的备份；
- 需要关闭 WorkBuddy 后再运行 `[2]`，否则会跳过并提示。
