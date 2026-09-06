# Gemini in Chrome（Windows / macOS）

适用于 Windows PowerShell 5.1、PowerShell 7 和 macOS（Intel / Apple Silicon）的 Gemini in Chrome 配置脚本。安装后可继续从原来的 Chrome 图标、任务栏、程序坞或链接启动，无需专用快捷方式。

## 安装

Windows：在 PowerShell 中运行：

```powershell
irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1 | iex
```

macOS：在“终端”中运行，无需 `sudo` 或安装额外依赖：

```bash
curl -fsSL https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.sh | /bin/bash
```

如果 Chrome 正在运行，脚本会提示你保存工作、完全退出 Chrome（包括后台进程），再按回车继续。**macOS 请使用 `Command+Q` 退出 Chrome，仅关闭窗口不算退出。** 若再次检查到 Chrome 仍在运行，则停止安装；脚本不会强制结束或自动启动 Chrome。macOS 的管道安装通过 `/dev/tty` 读取回车；没有可交互终端且 Chrome 正在运行时，会报错退出。

安装成功后，**从原来的 Chrome 图标重新启动，再打开 Gemini 侧栏验证**。脚本成功写入配置不等于 Google 已允许使用侧栏。

脚本使用中文状态文字，并以青色显示检查和处理阶段、绿色显示完成、黄色显示待办事项或警告、红色显示错误及下一步。macOS 使用 ANSI 颜色，输出到非终端时不带颜色。

两个入口分别检查当前操作系统并调用对应实现。Windows 入口 `install.ps1` 使用 ASCII 编码，显式按 UTF-8 读取中文实现 `src/configure.ps1` 并去除 BOM 后执行，兼容 PowerShell 5.1 的远程和本地执行。macOS 入口 `install.sh` 使用系统 Bash，通过系统自带的 `osascript` 和 Foundation 运行 `src/configure-macos.js`。远程安装仅从本仓库下载当前平台的入口和实现文件，不引入第三方依赖。

## 配置与备份

脚本会在当前用户 Chrome Stable 数据目录的 `Local State` 中应用以下设置：

- 设置 `variations_permanent_overridden_country`，默认值为 `us`。
- 在 `browser.enabled_labs_experiments` 中启用 `glic@1`，保留其他实验开关。

修改前，在用户数据目录的 `GeminiInChromeBackup` 文件夹内保存带唯一编号的完整原文件备份，以及 `restore.json` 备份索引和校验记录。重复安装保留首次安装的有效恢复记录；每次写入使用临时文件和原子替换，并重新读取校验结果。

两种平台使用相同的备份和字段恢复规则。默认数据目录如下：

| 平台 | Chrome Stable 数据目录 |
| --- | --- |
| Windows | `$env:LOCALAPPDATA\Google\Chrome\User Data` |
| macOS | `~/Library/Application Support/Google/Chrome` |

数据目录或 `Local State` 不存在、配置无法解析时，脚本会停止并提示原因。请先正常启动一次目标 Chrome，再退出后安装。其他 Chrome 渠道或自定义数据目录需通过 Windows 的 `-UserDataDir` 或 macOS 的 `--user-data-dir` 指定，路径应为包含 `Local State` 的目录，而非 `Default` 等个人资料子目录。

Windows 安装成功后会清理旧版生成的桌面 `Chrome - Gemini.lnk`，或 `-ShortcutPath` 指定的旧快捷方式。仅删除描述标记为 `Gemini in Chrome launcher (HangMine/gemini-in-chrome)` 的文件；其他来源的同名文件保留并提示。两种平台都不会创建快捷方式。

## 参数

Windows：

| 参数 | 用途 |
| --- | --- |
| `-Country us` | 永久地区覆盖值，默认 `us`。接受两个英文字母并转为小写；格式有效不代表该地区受 Google 支持。 |
| `-UserDataDir` | 指定包含 `Local State` 的 Chrome 数据目录。默认 `$env:LOCALAPPDATA\Google\Chrome\User Data`。 |
| `-ChromePath` | 兼容旧参数。可选指定 `chrome.exe` 路径，用于检查文件和版本；不会据此推断数据目录。 |
| `-ShortcutPath` | 兼容旧参数。仅用于清理旧版管理的 `.lnk` 文件；默认检查桌面 `Chrome - Gemini.lnk`。 |
| `-Uninstall` | 根据恢复记录撤销本脚本的字段修改，保留其他配置变更。自定义数据目录时应同时传入原来的 `-UserDataDir`。 |
| `-WhatIf` | 预览操作，不写入文件，也不等待关闭 Chrome。 |

Windows 远程传参示例：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1))) -Country us -WhatIf
```

macOS：

| 参数 | 用途 |
| --- | --- |
| `--country us` | 永久地区覆盖值，默认 `us`。接受两个英文字母并转为小写。 |
| `--user-data-dir PATH` | 指定包含 `Local State` 的 Chrome 数据目录；有空格的路径需加引号。 |
| `--what-if` | 预览操作，不修改 Chrome 配置、备份或快捷方式，也不等待关闭 Chrome。 |
| `--uninstall` | 根据恢复记录撤销本脚本的字段修改；自定义目录时同时传入原来的 `--user-data-dir`。 |
| `--help` | 显示中文帮助。 |

macOS 远程传参示例：

```bash
curl -fsSL https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.sh | /bin/bash -s -- --country us --what-if
```

本地执行需下载或克隆完整仓库，保留入口与 `src` 目录的相对位置，不能仅下载入口文件后离线运行。本地脚本支持相同参数，例如预览自定义数据目录的安装：

```powershell
.\install.ps1 -UserDataDir 'D:\ChromeData' -WhatIf
```

```bash
/bin/bash ./install.sh --user-data-dir "$HOME/Library/Application Support/Google/Chrome" --what-if
```

去掉 `-WhatIf` 或 `--what-if` 后执行实际安装。

## 卸载

Windows：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1))) -Uninstall
```

macOS：

```bash
curl -fsSL https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.sh | /bin/bash -s -- --uninstall
```

卸载同样要求完全退出 Chrome。脚本仅恢复安装前的永久地区覆盖值和本脚本修改的 `glic` 实验项，保留安装后其他 Chrome 设置的变化，不用完整旧文件覆盖当前配置。

卸载成功后会归档本次恢复记录，保留完整备份；再次安装将为新的安装周期建立恢复记录。之后从原来的 Chrome 图标启动即可。

## 常见问题

| 提示或现象 | 处理方式 |
| --- | --- |
| 找不到 `Local State` | 正常启动一次目标 Chrome 后完全退出；自定义目录请指向包含 `Local State` 的目录。 |
| Chrome 仍在运行 | 保存工作并关闭所有 Chrome 进程；macOS 使用 `Command+Q`，然后重新运行脚本。 |
| 下载失败 | 检查网络和代理是否能访问 `raw.githubusercontent.com`，恢复连接后重试；也可下载完整仓库后本地运行。 |
| 目录无写入权限 | 确认操作的是当前用户的 Chrome 数据目录，检查目录所有者和写入权限；不要使用 `sudo` 安装到其他用户的目录。 |
| 配置无法解析或备份校验失败 | 按错误提示检查配置及备份，保留文件以便排查，不要删除恢复记录后强行重装。 |
| 设置成功但侧栏仍不可用 | 完全退出后从原图标启动验证，同时检查实际网络出口、账号资格和 Google 当前开放条件。 |

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

Windows 在仓库根目录分别运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\install.Tests.ps1
pwsh -NoProfile -File .\tests\install.Tests.ps1
```

macOS 在仓库根目录运行：

```bash
python3 -m unittest discover -s tests -p 'install-macos.Tests.py' -v
```

Python 仅用于开发测试，安装不需要。macOS 测试使用隔离的数据目录，并通过系统 `osascript` 执行实际实现。

CI 覆盖 Windows PowerShell 5.1、PowerShell 7，以及 macOS 15 的 Intel 和 Apple Silicon 环境。自动测试检查配置缺失、重复安装、保留其他设置、备份恢复、写入失败、Chrome 未退出、预览模式等行为；旧快捷方式清理仅适用于 Windows。

Windows 已由用户验证安装后可从原来的 Chrome 图标打开 Gemini 侧栏。**macOS 实际打开 Gemini 侧栏尚未完成实机验收，CI 仅验证配置和脚本行为。** 自动测试不验证 Google 服务端是否允许使用 Gemini，也不保证未来 Chrome 版本的侧栏可用性。
