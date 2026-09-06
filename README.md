# Gemini in Chrome

适用于 Windows PowerShell 5.1 和 PowerShell 7 的启动快捷方式安装脚本。它为 Chrome 启用 Gemini 入口，并通过启动参数覆盖 Chrome 的本地实验配置地区。

## 安装

在 PowerShell 中运行：

```powershell
irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1 | iex
```

脚本会在桌面创建 `Chrome - Gemini.lnk`，使用以下启动参数：

```text
--enable-features=Glic --variations-override-country=us
```

安装后，保存工作并**完全退出 Chrome，包括后台进程**，然后通过 `Chrome - Gemini` 快捷方式启动，再打开 Gemini 侧栏。脚本不会关闭或自动启动 Chrome。

Chrome 已运行时，再打开快捷方式可能只是复用已有进程，新的启动参数不会生效。从普通任务栏图标或其他链接启动 Chrome，也不会自动带上这些参数。

重复安装会更新本脚本创建的快捷方式。如果目标位置存在其他来源的同名文件，脚本会报错并保留该文件；可以通过 `-ShortcutPath` 选择其他位置。

## 参数

| 参数 | 用途 |
| --- | --- |
| `-Country us` | 覆盖地区，默认 `us`。仅校验两个英文字母，不代表该地区一定受 Google 支持。 |
| `-ChromePath` | 指定 `chrome.exe` 的完整路径。 |
| `-ShortcutPath` | 指定 `.lnk` 文件的完整路径；其父目录必须已经存在。 |
| `-Uninstall` | 删除本脚本管理的快捷方式。自定义过路径时，需同时传入原来的 `-ShortcutPath`。 |
| `-WhatIf` | 预览操作，不修改文件。 |

为远程脚本传参时，使用以下形式：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1))) -Country us
```

本地脚本也支持相同参数，例如指定 Chrome 和快捷方式位置：

```powershell
.\install.ps1 -ChromePath 'C:\Program Files\Google\Chrome\Application\chrome.exe' -ShortcutPath "$env:USERPROFILE\Desktop\Chrome - Gemini.lnk" -WhatIf
```

去掉 `-WhatIf` 后执行实际安装。

## 卸载

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1))) -Uninstall
```

卸载后，完全退出 Chrome，再从原来的 Chrome 快捷方式启动即可。卸载不会结束正在运行的 Chrome 进程。

## 为什么使用启动参数

Chrome 152 可使用 V2 实验种子存储，包括 `VariationsSeedV2` 和 `VariationsSafeSeedV2`。在使用该存储方式时，仅修改 `Local State` 中的地区字段，可能仍让 Chrome 从 V2 数据读取原来的地区。例如，`Local State` 已是 `us`，V2 数据仍是 `cn`，侧栏仍可能显示地区不可用。

本脚本使用 `--variations-override-country=us` 覆盖当前 Chrome 进程的地区判断，避免直接修改二进制种子文件。脚本不编辑 `Local State`、V2 文件或账号资格字段，也不修改原有 Chrome 快捷方式。

该参数只影响 Chrome 的本地地区判断，不会改变代理配置、实际网络出口、Google 账号资格或服务端开放状态。Gemini 网页版可用也不保证 Chrome 侧栏可用；本脚本不能保证服务可用。

参考：

- [Chromium 152.0.7977.83 实验种子读写实现](https://github.com/chromium/chromium/blob/152.0.7977.83/components/variations/seed_reader_writer.cc#L506)
- [Google 官方可用地区及条件](https://support.google.com/gemini/answer/17140089?hl=en)
- [appsail/Gemini-in-Chrome 原始项目](https://github.com/appsail/Gemini-in-Chrome)

本项目参考原始项目的用途，安装脚本已重新实现。

## 本地验证

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\install.Tests.ps1
```

测试验证脚本行为，不验证 Google 服务端是否允许使用 Gemini。
