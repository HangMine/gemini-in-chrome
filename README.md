# Gemini in Chrome

适用于 Windows PowerShell 5.1 和 PowerShell 7 的 Gemini in Chrome 配置脚本。安装后可继续从原来的桌面图标、任务栏或链接启动 Chrome，无需专用快捷方式。

## 安装

在 PowerShell 中运行：

```powershell
irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1 | iex
```

如果 Chrome 正在运行，脚本会提示你保存工作、完全退出 Chrome（包括后台进程），再按回车继续。若检查到 Chrome 仍在运行，则停止安装；脚本不会强制结束或自动启动 Chrome。

安装成功后，**从原来的 Chrome 图标重新启动，再打开 Gemini 侧栏验证**。脚本成功写入配置不等于 Google 已允许使用侧栏。

脚本使用中文状态文字，并以青色显示检查和处理阶段、绿色显示完成、黄色显示待办事项或警告、红色显示错误及下一步。入口 `install.ps1` 使用 ASCII 编码，中文实现 `src/configure.ps1` 使用 UTF-8 BOM 编码；入口显式按 UTF-8 读取实现并去除 BOM 后执行，以兼容 Windows PowerShell 5.1 的远程和本地执行。远程安装仅从本仓库下载这两个文件，不引入第三方依赖。

## 配置与备份

脚本会在当前用户 Chrome Stable 数据目录的 `Local State` 中应用以下设置：

- 设置 `variations_permanent_overridden_country`，默认值为 `us`。
- 在 `browser.enabled_labs_experiments` 中启用 `glic@1`，保留其他实验开关。

修改前，在用户数据目录的 `GeminiInChromeBackup` 文件夹内保存带唯一编号的完整原文件备份，以及 `restore.json` 备份索引和校验记录。重复安装保留首次安装的有效恢复记录；每次写入使用临时文件和原子替换，并重新读取校验结果。

数据目录或 `Local State` 不存在、配置无法解析时，脚本会停止并提示原因。请先正常启动一次目标 Chrome，再退出后安装。其他 Chrome 渠道或自定义数据目录需通过 `-UserDataDir` 指定，路径应为包含 `Local State` 的目录，而非 `Default` 等个人资料子目录。

安装成功后会清理旧版生成的桌面 `Chrome - Gemini.lnk`，或 `-ShortcutPath` 指定的旧快捷方式。仅删除描述标记为 `Gemini in Chrome launcher (HangMine/gemini-in-chrome)` 的文件；其他来源的同名文件保留并提示。新版不会创建快捷方式。

## 参数

| 参数 | 用途 |
| --- | --- |
| `-Country us` | 永久地区覆盖值，默认 `us`。接受两个英文字母并转为小写；格式有效不代表该地区受 Google 支持。 |
| `-UserDataDir` | 指定包含 `Local State` 的 Chrome 数据目录。默认 `$env:LOCALAPPDATA\Google\Chrome\User Data`。 |
| `-ChromePath` | 兼容旧参数。可选指定 `chrome.exe` 路径，用于检查文件和版本；不会据此推断数据目录。 |
| `-ShortcutPath` | 兼容旧参数。仅用于清理旧版管理的 `.lnk` 文件；默认检查桌面 `Chrome - Gemini.lnk`。 |
| `-Uninstall` | 根据恢复记录撤销本脚本的字段修改，保留其他配置变更。自定义数据目录时应同时传入原来的 `-UserDataDir`。 |
| `-WhatIf` | 预览操作，不写入文件，也不等待关闭 Chrome。 |

为远程脚本传参时，使用以下形式：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1))) -Country us -WhatIf
```

本地执行需下载或克隆完整仓库，保留 `install.ps1` 与 `src/configure.ps1` 的相对位置，不能仅下载入口文件后离线运行。本地脚本支持相同参数，例如预览自定义数据目录的安装：

```powershell
.\install.ps1 -UserDataDir 'D:\ChromeData' -WhatIf
```

去掉 `-WhatIf` 后执行实际安装。

## 卸载

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1))) -Uninstall
```

卸载同样要求完全退出 Chrome。脚本仅恢复安装前的永久地区覆盖值和本脚本修改的 `glic` 实验项，保留安装后其他 Chrome 设置的变化，不用完整旧文件覆盖当前配置。

卸载成功后会归档本次恢复记录，保留完整备份；再次安装将为新的安装周期建立恢复记录。之后从原来的 Chrome 图标启动即可。

## 为什么使用持久化地区覆盖

Chrome 152 可从 `VariationsSeedV2` 和 `VariationsSafeSeedV2` 读取实验地区，因此只改旧的 `variations_country` 等缓存字段可能没有效果。本脚本使用 `variations_permanent_overridden_country` 持久化覆盖 Chrome 实验配置的永久地区。该字段在 Chrome 152 对永久地区的选择中优先于种子缓存，无需为每次启动附加参数。

这是 Chrome 实验配置的地区覆盖，作用范围不只限于 Gemini；它不覆盖所有会话地区来源，也不会改变代理配置、实际网络出口、Google 账号资格或服务端开放状态。脚本不修改 V2 二进制缓存、账号资格字段或注册表。Gemini 网页版可用并不保证 Chrome 侧栏可用。

实现依据为 Chromium `152.0.7977.83` 的相关代码，未来 Chrome 可能调整这些内部字段或实验开关。本脚本不保证所有 Chrome 版本或网络、账号组合都能使用 Gemini。

参考：

- [Chromium 152.0.7977.83 地区配置字段定义](https://github.com/chromium/chromium/blob/152.0.7977.83/components/variations/pref_names.h)
- [Chromium 152.0.7977.83 实验与地区选择实现](https://github.com/chromium/chromium/blob/152.0.7977.83/components/variations/service/variations_field_trial_creator.cc)
- [Google 官方可用地区及条件](https://support.google.com/gemini/answer/17140089?hl=en)
- [appsail/Gemini-in-Chrome 原始项目](https://github.com/appsail/Gemini-in-Chrome)

本项目参考原始项目的用途，安装脚本已重新实现。

## 本地验证

在仓库根目录分别运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\install.Tests.ps1
pwsh -NoProfile -File .\tests\install.Tests.ps1
```

自动测试覆盖配置缺失、重复安装、保留其他设置、备份恢复、写入失败、Chrome 未退出、旧快捷方式清理及 `-WhatIf`。真实使用还需在安装后，从原来的 Chrome 图标启动，确认主进程没有地区启动参数并实际打开侧栏；自动测试不验证 Google 服务端是否允许使用 Gemini。
