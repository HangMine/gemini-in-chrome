# Run with powershell or pwsh: -NoProfile -File .\tests\install.Tests.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '..\install.ps1'
$implementation = Join-Path $PSScriptRoot '..\src\configure.ps1'
$marker = 'Gemini in Chrome launcher (HangMine/gemini-in-chrome)'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('gemini-persistent-tests-' + [guid]::NewGuid().ToString('N'))
$encoding = New-Object Text.UTF8Encoding($false)
$checks = 0
$shell = $null
$runtime = [pscustomobject]@{ Mode = 'Stopped'; ProcessCalls = 0; ReadCalls = 0; KillCalls = 0 }
$originalJson = '{"variations_permanent_overridden_country":"cn","browser":{"enabled_labs_experiments":["other@1","glic@2","glic-share-image@1"],"keep":true},"nested":{"text":"\u4e2d\u6587","iso":"2026-09-06T12:34:56.1234567+08:00","large":9223372036854775807,"items":[{"keep":1}]}}'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Assert-Fails([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri)
    if ($Uri -ceq 'https://example.invalid/install.ps1' -or
        $Uri -ceq 'https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/install.ps1') {
        Assert-True ($null -ne $entrySource) 'The mocked installer source was not loaded.'
        return $entrySource
    }
    if ($Uri -ceq 'https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/src/configure.ps1') {
        return $implementationSource
    }
    throw "Refusing an unexpected network request in installer tests: $Uri"
}

function Get-Process {
    param($Name, $ErrorAction)
    $runtime.ProcessCalls++
    if ($runtime.Mode -eq 'Running' -or
        ($runtime.Mode -eq 'CloseAfterPrompt' -and $runtime.ReadCalls -eq 0) -or
        ($runtime.Mode -eq 'Race' -and $runtime.ProcessCalls -gt 1)) {
        [pscustomobject]@{ ProcessName = 'chrome'; Id = 12345 }
    }
}

function Read-Host {
    param($Prompt)
    $runtime.ReadCalls++
    return ''
}

function Stop-Process {
    param($Name, $Id, [switch]$Force, $ErrorAction)
    $runtime.KillCalls++
    throw 'The installer must never terminate Chrome.'
}

function Reset-Runtime([string]$Mode = 'Stopped') {
    $runtime.Mode = $Mode
    $runtime.ProcessCalls = 0
    $runtime.ReadCalls = 0
}

function New-Fixture([string]$Json = $originalJson) {
    $directory = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory 'Local State'), $Json, $encoding)
    return @{ UserDataDir = $directory; ShortcutPath = (Join-Path $directory 'Chrome - Gemini.lnk') }
}

function Read-State($Options) {
    $jsonOptions = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
    [IO.File]::ReadAllText((Join-Path $Options.UserDataDir 'Local State')) | ConvertFrom-Json @jsonOptions
}

function Write-State($Options, $State) {
    [IO.File]::WriteAllText((Join-Path $Options.UserDataDir 'Local State'), ($State | ConvertTo-Json -Depth 100), $encoding)
}

function State-Hash($Options) {
    (Get-FileHash -LiteralPath (Join-Path $Options.UserDataDir 'Local State') -Algorithm SHA256).Hash
}

function Manifest-Path($Options) {
    Join-Path $Options.UserDataDir 'GeminiInChromeBackup\restore.json'
}

function New-Shortcut($Options, [string]$Description) {
    $link = $shell.CreateShortcut($Options.ShortcutPath)
    try {
        $link.TargetPath = $fakeChrome
        $link.Arguments = '--enable-features=Glic --variations-override-country=us'
        $link.Description = $Description
        $link.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link)
    }
}

try {
    $entrySource = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($installer))
    $implementationSource = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($implementation))
    Assert-True ($entrySource -notmatch '[^\x00-\x7F]') 'The one-line installer entry point must contain only ASCII.'
    Assert-True ($implementationSource[0] -eq [char]0xfeff) 'The downloaded implementation fixture must retain its UTF-8 BOM.'
    [void][IO.Directory]::CreateDirectory($testRoot)
    $fakeChrome = Join-Path $testRoot 'chrome.exe'
    [IO.File]::WriteAllText($fakeChrome, '', $encoding)
    $shell = New-Object -ComObject WScript.Shell

    $options = New-Fixture
    New-Shortcut $options $marker
    $before = State-Hash $options
    Reset-Runtime 'Running'
    & $installer @options -WhatIf
    Assert-True ((State-Hash $options) -eq $before) 'WhatIf changed Local State.'
    Assert-True (-not (Test-Path -LiteralPath (Manifest-Path $options))) 'WhatIf created a backup.'
    Assert-True (Test-Path -LiteralPath $options.ShortcutPath) 'WhatIf removed a shortcut.'
    Assert-True ($runtime.ReadCalls -eq 0) 'WhatIf prompted to close Chrome.'

    Reset-Runtime
    & $installer @options -ChromePath $fakeChrome
    $state = Read-State $options
    Assert-True ($state.variations_permanent_overridden_country -ceq 'us') 'Default country was not installed.'
    Assert-True (($state.browser.enabled_labs_experiments -join ',') -ceq 'other@1,glic-share-image@1,glic@1') 'Glic flags were not merged correctly.'
    Assert-True ($state.browser.keep -eq $true -and $state.nested.items[0].keep -eq 1) 'Unrelated nested data changed.'
    Assert-True ($state.nested.text -ceq (([char]0x4e2d).ToString() + [char]0x6587)) 'Unicode data changed.'
    Assert-True ($state.nested.iso -is [string] -and $state.nested.iso -ceq '2026-09-06T12:34:56.1234567+08:00') 'ISO date text or its time zone changed.'
    Assert-True ($state.nested.large.ToString() -ceq '9223372036854775807') 'Large integer precision was lost.'
    Assert-True (-not (Test-Path -LiteralPath $options.ShortcutPath)) 'Managed legacy shortcut was not removed.'
    $manifestPath = Manifest-Path $options
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $backupPath = Join-Path (Split-Path $manifestPath) $manifest.backup_file
    Assert-True ($manifest.version -eq 1) 'Backup manifest version is incorrect.'
    Assert-True ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -eq $before) 'Full backup did not preserve original bytes.'
    Assert-True ($manifest.sha256 -eq $before) 'Manifest hash does not identify the original backup.'
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash

    & $installer @options -Country GB
    Assert-True ((Read-State $options).variations_permanent_overridden_country -ceq 'gb') 'Country was not normalized on reinstall.'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $manifestHash) 'Reinstall replaced the first restore manifest.'
    Assert-True ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -eq $before) 'Reinstall changed the original backup.'
    Assert-True (@((Read-State $options).browser.enabled_labs_experiments | Where-Object { $_ -ceq 'glic@1' }).Count -eq 1) 'Reinstall duplicated glic@1.'

    $state = Read-State $options
    $state.browser.enabled_labs_experiments += 'later@2'
    $state | Add-Member -NotePropertyName laterSetting -NotePropertyValue 'preserve me'
    Write-State $options $state
    $installedHash = State-Hash $options
    & $installer @options -Uninstall -WhatIf
    Assert-True ((State-Hash $options) -eq $installedHash) 'Uninstall WhatIf changed Local State.'
    Assert-True (Test-Path -LiteralPath $manifestPath) 'Uninstall WhatIf archived the manifest.'
    & $installer @options -Uninstall
    $state = Read-State $options
    Assert-True ($state.variations_permanent_overridden_country -ceq 'cn') 'Uninstall did not restore the original country.'
    Assert-True (@(Compare-Object @('other@1', 'glic-share-image@1', 'later@2', 'glic@2') $state.browser.enabled_labs_experiments).Count -eq 0) 'Uninstall did not restore original Glic and retain later unrelated flags.'
    Assert-True ($state.laterSetting -ceq 'preserve me') 'Uninstall reverted an unrelated later setting.'
    Assert-True (-not (Test-Path -LiteralPath $manifestPath)) 'Uninstall left an active manifest.'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $manifestPath) -Filter 'restored-*.json').Count -eq 1) 'Uninstall did not archive its restore manifest.'
    Assert-True (Test-Path -LiteralPath $backupPath) 'Uninstall removed the full original backup.'
    $restoredHash = State-Hash $options
    & $installer @options -Uninstall
    Assert-True ((State-Hash $options) -eq $restoredHash) 'Repeated uninstall changed restored settings.'

    foreach ($json in @('{"keep":1}', '{"browser":{"keep":1}}', '{"variations_permanent_overridden_country":null,"browser":{"enabled_labs_experiments":[]}}')) {
        $options = New-Fixture $json
        $initial = Read-State $options
        & $installer @options
        Assert-True ((Read-State $options).browser.enabled_labs_experiments -contains 'glic@1') 'Install failed for missing browser or flags.'
        & $installer @options -Uninstall
        $state = Read-State $options
        if ($null -ne $initial.PSObject.Properties['variations_permanent_overridden_country']) {
            Assert-True ($null -ne $state.PSObject.Properties['variations_permanent_overridden_country'] -and $null -eq $state.variations_permanent_overridden_country) 'Uninstall did not preserve an originally null country.'
        } else {
            Assert-True ($null -eq $state.PSObject.Properties['variations_permanent_overridden_country']) 'Uninstall left a previously absent country.'
        }
        if ($null -eq $initial.browser -or $null -eq $initial.browser.PSObject.Properties['enabled_labs_experiments']) {
            Assert-True ($null -eq $state.browser -or $null -eq $state.browser.PSObject.Properties['enabled_labs_experiments']) 'Uninstall left a previously absent experiments property.'
        } else {
            Assert-True (@($state.browser.enabled_labs_experiments).Count -eq 0) 'Uninstall did not restore an originally empty experiments array.'
        }
    }

    $options = New-Fixture
    New-Shortcut $options 'Existing user shortcut'
    $shortcutHash = (Get-FileHash -LiteralPath $options.ShortcutPath -Algorithm SHA256).Hash
    & $installer @options
    & $installer @options -Uninstall
    Assert-True ((Get-FileHash -LiteralPath $options.ShortcutPath -Algorithm SHA256).Hash -eq $shortcutHash) 'An unmanaged shortcut was changed.'

    foreach ($mode in @('CloseAfterPrompt', 'Running', 'Race')) {
        $options = New-Fixture
        $before = State-Hash $options
        Reset-Runtime $mode
        if ($mode -eq 'CloseAfterPrompt') {
            & $installer @options
            Assert-True ((Read-State $options).variations_permanent_overridden_country -ceq 'us') 'Install did not proceed after Chrome closed.'
            Assert-True ($runtime.ReadCalls -eq 1) 'Closing Chrome required more than one prompt.'
        } else {
            Assert-Fails { & $installer @options } "Install continued with Chrome active: $mode."
            Assert-True ((State-Hash $options) -eq $before) "Active Chrome configuration was modified: $mode."
            Assert-True ($runtime.ReadCalls -le 1) 'The installer repeatedly prompted while Chrome remained active.'
        }
    }
    Reset-Runtime
    Assert-True ($runtime.KillCalls -eq 0) 'The installer tried to terminate Chrome.'

    foreach ($json in @('{broken', '[]', '[{}]', '{"browser":[]}', '{"browser":"invalid"}', '{"browser":{"enabled_labs_experiments":7}}')) {
        $options = New-Fixture $json
        $before = State-Hash $options
        Assert-Fails { & $installer @options } 'Malformed Local State was accepted.'
        Assert-True ((State-Hash $options) -eq $before) 'Malformed Local State was modified.'
        Assert-True (-not (Test-Path -LiteralPath (Manifest-Path $options))) 'Invalid input created an active backup.'
    }

    $options = New-Fixture
    Remove-Item -LiteralPath (Join-Path $options.UserDataDir 'Local State')
    Assert-Fails { & $installer @options } 'A missing Local State was accepted.'
    Assert-True (@(Get-ChildItem -LiteralPath $options.UserDataDir -Force).Count -eq 0) 'Missing Local State created files.'
    New-Shortcut $options $marker
    & $installer @options -Uninstall
    Assert-True (-not (Test-Path -LiteralPath $options.ShortcutPath)) 'Legacy-only uninstall failed without Local State.'

    foreach ($damage in @('Version', 'MissingBackup', 'Hash', 'MissingState')) {
        $options = New-Fixture
        & $installer @options
        $before = State-Hash $options
        $manifestPath = Manifest-Path $options
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        switch ($damage) {
            'Version' { $manifest.version = 999 }
            'MissingBackup' { $manifest.backup_file = 'does-not-exist.bak' }
            'Hash' { $manifest.sha256 = ('0' * 64) }
            'MissingState' { Remove-Item -LiteralPath (Join-Path $options.UserDataDir 'Local State') }
        }
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 100), $encoding)
        Assert-Fails { & $installer @options -Uninstall } "Uninstall accepted damaged restore data: $damage."
        Assert-True (Test-Path -LiteralPath $manifestPath) "Failed uninstall lost its restore manifest: $damage."
        if ($damage -ne 'MissingState') {
            Assert-True ((State-Hash $options) -eq $before) "Failed uninstall changed Local State: $damage."
            Assert-Fails { & $installer @options } "Reinstall accepted damaged restore data: $damage."
            Assert-True ((State-Hash $options) -eq $before) "Failed reinstall changed Local State: $damage."
        } else {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $options.UserDataDir 'Local State'))) 'Failed uninstall recreated a missing Local State.'
        }
    }

    $options = New-Fixture
    $before = State-Hash $options
    $statePath = Join-Path $options.UserDataDir 'Local State'
    $lock = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-Fails { & $installer @options } 'A locked Local State was reported as installed.'
    } finally {
        $lock.Dispose()
    }
    Assert-True ((State-Hash $options) -eq $before) 'A failed replacement changed Local State.'
    Assert-True (@(Get-ChildItem -LiteralPath $options.UserDataDir -File).Count -eq 1) 'A failed replacement left temporary files.'
    $manifestPath = Manifest-Path $options
    Assert-True (Test-Path -LiteralPath $manifestPath) 'Write failure lost its recovery manifest.'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    Assert-True ((Get-FileHash -LiteralPath (Join-Path (Split-Path $manifestPath) $manifest.backup_file) -Algorithm SHA256).Hash -eq $before) 'Write failure lost its original backup.'
    & $installer @options
    Assert-True ((Read-State $options).variations_permanent_overridden_country -ceq 'us') 'Install could not recover after a temporary write failure.'

    $options = New-Fixture
    $before = State-Hash $options
    foreach ($country in @('', 'u', 'usa', 'u1', 'us --incognito', "us`n")) {
        Assert-Fails { & $installer @options -Country $country } "Invalid country was accepted: '$country'."
    }
    Assert-Fails { & $installer @options -ChromePath (Join-Path $testRoot 'missing.exe') } 'A missing explicit ChromePath was accepted.'
    Assert-True ((State-Hash $options) -eq $before) 'Parameter validation changed Local State.'

    $downloadedScript = [scriptblock]::Create([IO.File]::ReadAllText($installer))
    & $downloadedScript @options -Country US
    Assert-True ((Read-State $options).variations_permanent_overridden_country -ceq 'us') 'Downloaded content failed with bound parameters.'

    $localAppDataBefore = $env:LOCALAPPDATA
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Chrome - Gemini.lnk'
    $desktopHashBefore = if (Test-Path -LiteralPath $desktopShortcut) { (Get-FileHash -LiteralPath $desktopShortcut).Hash } else { $null }
    try {
        $env:LOCALAPPDATA = Join-Path $testRoot 'PipelineLocalAppData'
        $pipelineUserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
        [void][IO.Directory]::CreateDirectory($pipelineUserData)
        [IO.File]::WriteAllText((Join-Path $pipelineUserData 'Local State'), $originalJson, $encoding)
        & {
            # Reproduce interactive irm | iex scope without writing to a real profile or desktop.
            $PSCmdlet = $null
            $PSBoundParameters = @{}
            $WhatIfPreference = $true
            [IO.File]::ReadAllText($installer) | Invoke-Expression
        }
        Assert-True ([IO.File]::ReadAllText((Join-Path $pipelineUserData 'Local State')) -ceq $originalJson) 'Invoke-Expression preview changed Local State.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $pipelineUserData 'GeminiInChromeBackup'))) 'Invoke-Expression preview created a backup.'

        $pipelineRecords = @(& {
            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$Path, [string]$PathType)
                if ($LiteralPath -eq $desktopShortcut) { return $false }
                Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
            }
            $PSCmdlet = $null
            $PSBoundParameters = @{}
            $WhatIfPreference = $false
            $pipelineOptions = @{ UserDataDir = $pipelineUserData }
            for ($attempt = 0; $attempt -lt 2; $attempt++) {
                irm https://example.invalid/install.ps1 | iex
                $pipelineState = Read-State $pipelineOptions
                Assert-True ($pipelineState.variations_permanent_overridden_country -ceq 'us') 'irm | iex did not persist the default country.'
                Assert-True ($pipelineState.browser.enabled_labs_experiments -contains 'glic@1') 'irm | iex did not persist the Glic flag.'
                $pipelineManifestHash = (Get-FileHash -LiteralPath (Manifest-Path $pipelineOptions) -Algorithm SHA256).Hash
                if ($attempt -eq 0) {
                    $firstPipelineManifestHash = $pipelineManifestHash
                } else {
                    Assert-True ($pipelineManifestHash -eq $firstPipelineManifestHash) 'Repeated irm | iex replaced the original restore manifest.'
                }
            }
        } 6>&1)
        $pipelineText = ($pipelineRecords | ForEach-Object { $_.ToString() }) -join "`n"
        $writtenText = -join [char[]]@(0x8bbe, 0x7f6e, 0x5df2, 0x5199, 0x5165)
        Assert-True (@($pipelineRecords | Where-Object { $_ -is [Management.Automation.InformationRecord] }).Count -gt 0) 'irm | iex did not emit information records.'
        Assert-True ([regex]::Matches($pipelineText, [regex]::Escape($writtenText)).Count -eq 2) 'Chinese completion text was missing or corrupted in an irm | iex run.'
        Assert-True (-not $pipelineText.Contains(([char]0xfffd).ToString())) 'irm | iex messages contained a Unicode replacement character.'
    } finally {
        $env:LOCALAPPDATA = $localAppDataBefore
    }
    $desktopHashAfter = if (Test-Path -LiteralPath $desktopShortcut) { (Get-FileHash -LiteralPath $desktopShortcut).Hash } else { $null }
    Assert-True ($desktopHashBefore -eq $desktopHashAfter) 'Invoke-Expression preview changed the real desktop shortcut.'

    Write-Host "PASS: $checks checks; all configuration writes stayed inside temporary fixtures."
} finally {
    if ($null -ne $shell) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = $tempBase.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar + 'gemini-persistent-tests-'
    if (-not $resolvedRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected path: $resolvedRoot"
    }
    if (Test-Path -LiteralPath $resolvedRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
