#Requires -Version 5.1
<#
.SYNOPSIS
持久化设置 Gemini in Chrome 的本地实验地区，无需专用快捷方式。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [AllowEmptyString()]
    [string]$Country = 'us',
    [string]$UserDataDir,
    [string]$ChromePath,
    [string]$ShortcutPath,
    [switch]$Uninstall
)

# Invoke-Expression has no PSCmdlet; the invoked advanced block supplies one.
& {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $ErrorActionPreference = 'Stop'
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $marker = 'Gemini in Chrome launcher (HangMine/gemini-in-chrome)'
    $countryKey = 'variations_permanent_overridden_country'

    function Get-BytesHash([byte[]]$Bytes) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
        finally { $sha.Dispose() }
    }

    function Assert-JsonValue($Value, [int]$Depth = 0) {
        if ($Depth -gt 80) { throw '配置嵌套过深，已停止操作，原文件未修改。' }
        if ($Value -is [datetime]) {
            throw '当前 PowerShell 无法原样保留此配置的日期文本，请使用 Windows PowerShell 5.1 或最新版 PowerShell 7。'
        }
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $Value.PSObject.Properties) { Assert-JsonValue $property.Value ($Depth + 1) }
        }
        elseif ($Value -is [array]) {
            foreach ($item in $Value) { Assert-JsonValue $item ($Depth + 1) }
        }
    }

    function Read-JsonFile([string]$Path) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $text = $utf8.GetString($bytes).TrimStart([char]0xFEFF)
        $options = @{ ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')) { $options.NoEnumerate = $true }
        try { $value = ConvertFrom-Json -InputObject $text @options }
        catch { throw "无法解析 JSON 文件：$Path。请保留原文件并检查其完整性。" }
        if ($value -isnot [System.Management.Automation.PSCustomObject]) { throw "配置必须是 JSON 对象：$Path" }
        Assert-JsonValue $value
        return [pscustomobject]@{ Value = $value; Bytes = $bytes; Hash = (Get-BytesHash $bytes) }
    }

    function Get-LabFlags($State) {
        $browser = $State.PSObject.Properties['browser']
        if ($null -eq $browser) { return ,@() }
        if ($browser.Value -isnot [System.Management.Automation.PSCustomObject]) { throw '配置中的 browser 不是对象，已停止修改。' }
        $flags = $browser.Value.PSObject.Properties['enabled_labs_experiments']
        if ($null -eq $flags) { return ,@() }
        if ($flags.Value -isnot [array]) { throw '实验开关配置不是数组，已停止修改。' }
        foreach ($flag in $flags.Value) {
            if ($flag -isnot [string]) { throw '实验开关包含非文本内容，已停止修改。' }
        }
        return ,@($flags.Value)
    }

    function Set-Property($Object, [string]$Name, $Value) {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value -Force
    }

    function Write-JsonAtomic([string]$Path, $Value, [string]$ExpectedHash) {
        $text = ConvertTo-Json -InputObject $Value -Depth 100 -Compress -WarningAction Stop
        $temporary = Join-Path (Split-Path -Parent $Path) ('.gemini-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($temporary, $text, $utf8)
            $null = Read-JsonFile $temporary
            if ($ExpectedHash) {
                if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
                    throw '写入前检测到 Chrome 又已启动，请关闭 Chrome 后重新运行；配置未写入。'
                }
                if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $ExpectedHash) {
                    throw '配置在检查后发生变化，已停止覆盖。请关闭 Chrome 后重新运行。'
                }
                try { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
                catch {
                    throw [IO.IOException]::new("无法替换配置文件：$Path。请确认 Chrome 已退出、文件未被占用且目录可写，原始备份已保留。", $_.Exception)
                }
            }
            else {
                [IO.File]::Move($temporary, $Path)
            }
            if ([IO.File]::ReadAllText($Path, $utf8) -cne $text) {
                throw "写入后校验未通过，请保留备份并检查文件：$Path"
            }
        }
        finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }

    function Remove-LegacyShortcut {
        if (-not $ShortcutPath -or -not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { return }
        $shell = $null
        $link = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($ShortcutPath)
            if ($link.Description -eq $marker) {
                Remove-Item -LiteralPath $ShortcutPath -ErrorAction Stop
                Write-Host "[完成] 已移除旧版专用快捷方式：$ShortcutPath" -ForegroundColor Green
            }
            else {
                Write-Host "[注意] 同名快捷方式不属于本脚本，已保留：$ShortcutPath" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "[注意] 旧快捷方式未能清理，配置操作不受影响：$($_.Exception.Message)" -ForegroundColor Yellow
        }
        finally {
            if ($null -ne $link) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
            if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        }
    }

    try {
        Write-Host '[检查] Gemini in Chrome 持久化设置' -ForegroundColor Cyan
        if ($env:OS -ne 'Windows_NT') { throw '此脚本仅支持 Windows。' }
        if ($Country -cnotmatch '\A[A-Za-z]{2}\z') { throw '地区代码必须是两个英文字母，例如 us。' }
        $Country = $Country.ToLowerInvariant()
        if (-not $UserDataDir) { $UserDataDir = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' }
        $UserDataDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($UserDataDir)
        $statePath = Join-Path $UserDataDir 'Local State'
        $backupDir = Join-Path $UserDataDir 'GeminiInChromeBackup'
        $manifestPath = Join-Path $backupDir 'restore.json'

        if ($ChromePath) {
            if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf) -or [IO.Path]::GetExtension($ChromePath) -ine '.exe') {
                throw '-ChromePath 必须指向已存在的 Chrome 可执行文件。'
            }
            $version = (Get-Item -LiteralPath $ChromePath).VersionInfo.ProductVersion
            Write-Host "[检查] Chrome 版本：$version" -ForegroundColor Cyan
        }
        if (-not $ShortcutPath) {
            $desktop = [Environment]::GetFolderPath('DesktopDirectory')
            if ($desktop) { $ShortcutPath = Join-Path $desktop 'Chrome - Gemini.lnk' }
        }
        if ($ShortcutPath) {
            $ShortcutPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ShortcutPath)
            if ([IO.Path]::GetExtension($ShortcutPath) -ine '.lnk') { throw '-ShortcutPath 必须是旧版 .lnk 快捷方式路径。' }
        }

        $hasManifest = Test-Path -LiteralPath $manifestPath -PathType Leaf
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf) -and -not ($Uninstall -and -not $hasManifest)) {
            throw "未找到 Chrome 配置：$statePath。请先运行一次 Chrome，或通过 -UserDataDir 指定正确的数据目录。"
        }
        if ($WhatIfPreference) {
            $operation = if ($Uninstall) { '按备份还原地区和 Gemini 开关' } else { "设置永久地区 $Country 并启用 Gemini 开关" }
            Write-Host "[预览] 将$operation：$statePath" -ForegroundColor Cyan
            Write-Host '[预览] 将保留备份并清理旧版托管快捷方式；未写入文件，无需关闭 Chrome。' -ForegroundColor Cyan
            return
        }
        if ($Uninstall -and -not $hasManifest) {
            if ($PSCmdlet.ShouldProcess($ShortcutPath, '清理旧版托管快捷方式')) { Remove-LegacyShortcut }
            Write-Host '[完成] 未发现本脚本的持久化回退记录，Chrome 配置未修改。' -ForegroundColor Green
            return
        }

        if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
            Write-Host '[等待] 请保存工作并完全退出 Chrome，包括后台进程。脚本不会强制关闭浏览器。' -ForegroundColor Yellow
            $null = Read-Host '关闭后按回车继续'
            if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
                throw '仍检测到 Chrome 运行，尚未修改配置。请完全退出后重新运行脚本。'
            }
        }

        $current = Read-JsonFile $statePath
        $state = $current.Value
        $flags = Get-LabFlags $state
        $otherFlags = @($flags | Where-Object { $_ -cnotmatch '\Aglic(@.*)?\z' })
        $original = $null
        if ($hasManifest) {
            $manifest = (Read-JsonFile $manifestPath).Value
            if ($manifest.version -ne 1 -or $manifest.backup_file -isnot [string] -or
                $manifest.backup_file -notmatch '\ALocal State\.[a-f0-9]+\.bak\z' -or
                $manifest.sha256 -notmatch '\A[A-Fa-f0-9]{64}\z') {
                throw '回退记录格式不正确，已停止操作。请保留 GeminiInChromeBackup 目录。'
            }
            $backupPath = Join-Path $backupDir $manifest.backup_file
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw '原始配置备份缺失，已停止操作。' }
            $backup = Read-JsonFile $backupPath
            if ($backup.Hash -ne $manifest.sha256) { throw '原始备份校验失败，已停止操作，未修改配置。' }
            $original = $backup.Value
            $null = Get-LabFlags $original
        }

        if ($Uninstall) {
            $savedCountry = $original.PSObject.Properties[$countryKey]
            if ($null -ne $savedCountry) { Set-Property $state $countryKey $savedCountry.Value }
            else { $state.PSObject.Properties.Remove($countryKey) }
            $originalFlags = Get-LabFlags $original
            $savedFlags = @($originalFlags | Where-Object { $_ -cmatch '\Aglic(@.*)?\z' })
            $restoredFlags = @($otherFlags) + @($savedFlags)
            $originalBrowser = $original.PSObject.Properties['browser']
            $hadFlags = $null -ne $originalBrowser -and $null -ne $originalBrowser.Value.PSObject.Properties['enabled_labs_experiments']
            if ($restoredFlags.Count -gt 0 -or $hadFlags) {
                if ($null -eq $state.PSObject.Properties['browser']) { Set-Property $state 'browser' ([pscustomobject]@{}) }
                Set-Property $state.browser 'enabled_labs_experiments' $restoredFlags
            }
            elseif ($null -ne $state.PSObject.Properties['browser']) {
                $state.browser.PSObject.Properties.Remove('enabled_labs_experiments')
            }
            if ($null -eq $originalBrowser -and $null -ne $state.PSObject.Properties['browser'] -and
                @($state.browser.PSObject.Properties).Count -eq 0) {
                $state.PSObject.Properties.Remove('browser')
            }
        }
        else {
            Set-Property $state $countryKey $Country
            if ($null -eq $state.PSObject.Properties['browser']) { Set-Property $state 'browser' ([pscustomobject]@{}) }
            Set-Property $state.browser 'enabled_labs_experiments' (@($otherFlags) + @('glic@1'))
        }

        $action = if ($Uninstall) { '恢复原有地区和 Gemini 开关，并清理旧版托管快捷方式' } else { "备份配置，设置永久地区 $Country 并启用 Gemini" }
        if (-not $PSCmdlet.ShouldProcess($statePath, $action)) { return }
        if (-not $hasManifest) {
            Write-Host '[备份] 保存本次安装前的原始配置。' -ForegroundColor Cyan
            $null = New-Item -ItemType Directory -Path $backupDir -Force
            $backupName = 'Local State.' + [guid]::NewGuid().ToString('N') + '.bak'
            $backupPath = Join-Path $backupDir $backupName
            [IO.File]::WriteAllBytes($backupPath, $current.Bytes)
            if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -ne $current.Hash) { throw '备份校验失败，未写入 Chrome 配置。' }
            Write-JsonAtomic $manifestPath ([pscustomobject]@{ version = 1; backup_file = $backupName; sha256 = $current.Hash })
        }
        else {
            Write-Host '[备份] 原始备份已存在，将继续保留，不会被本次操作覆盖。' -ForegroundColor Cyan
        }

        Write-Host '[应用] 正在写入并校验 Chrome 配置。' -ForegroundColor Cyan
        Write-JsonAtomic $statePath $state $current.Hash
        if ($Uninstall) {
            $archive = Join-Path $backupDir ('restored-' + [guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::Move($manifestPath, $archive)
            Write-Host '[完成] 已还原原有地区和 Gemini 开关，其他 Chrome 设置保持不变。' -ForegroundColor Green
        }
        else {
            Write-Host "[完成] 永久实验地区已设为 $Country，Gemini 开关已启用。" -ForegroundColor Green
        }
        Remove-LegacyShortcut
        Write-Host "[备份] 原始配置保留在：$backupDir" -ForegroundColor Cyan
        Write-Host '[下一步] 设置已写入，请从原来的 Chrome 图标重新启动并验证侧栏。' -ForegroundColor Green
        Write-Host '[说明] 本地设置不会改变实际网络出口；侧栏能否使用仍需打开后验证。' -ForegroundColor Yellow
    }
    catch {
        Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}
