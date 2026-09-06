# Run with: powershell -NoProfile -File .\tests\install.Tests.ps1
[CmdletBinding()]
param(
    [string]$ChromePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
)

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '..\install.ps1'
$marker = 'Gemini in Chrome launcher (HangMine/gemini-in-chrome)'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('gemini-launcher-tests-' + [guid]::NewGuid().ToString('N'))
$shell = $null
$checks = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Assert-Fails([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}

function Read-Shortcut([string]$Path) {
    $link = $shell.CreateShortcut($Path)
    try {
        [pscustomobject]@{
            TargetPath = $link.TargetPath
            Arguments = $link.Arguments
            Description = $link.Description
            IconLocation = $link.IconLocation
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link)
    }
}

try {
    if (-not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) {
        throw 'Chrome was not found. Pass -ChromePath with an installed chrome.exe path.'
    }
    $ChromePath = (Resolve-Path -LiteralPath $ChromePath).Path
    [void](New-Item -ItemType Directory -Path $testRoot)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = Join-Path $testRoot 'Chrome - Gemini.lnk'
    $options = @{ ChromePath = $ChromePath; ShortcutPath = $shortcut }

    & $installer @options -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $shortcut)) 'WhatIf created a shortcut.'

    & $installer @options
    Assert-True (Test-Path -LiteralPath $shortcut -PathType Leaf) 'Install did not create a shortcut.'
    $link = Read-Shortcut $shortcut
    Assert-True ($link.TargetPath -eq $ChromePath) 'Shortcut target is incorrect.'
    Assert-True ($link.Arguments -eq '--enable-features=Glic --variations-override-country=us') 'Default arguments are incorrect.'
    Assert-True ($link.Description -eq $marker) 'Shortcut ownership marker is incorrect.'
    Assert-True ($link.IconLocation -eq "$ChromePath,0" -or $link.IconLocation -eq "$ChromePath, 0") 'Shortcut icon is incorrect.'

    & $installer @options -Country GB
    $link = Read-Shortcut $shortcut
    Assert-True ($link.Arguments -eq '--enable-features=Glic --variations-override-country=gb') 'Reinstall did not replace and normalize the country.'

    & $installer @options -Country us -WhatIf
    Assert-True ((Read-Shortcut $shortcut).Arguments -eq $link.Arguments) 'WhatIf updated an existing shortcut.'
    & $installer @options -Uninstall -WhatIf
    Assert-True (Test-Path -LiteralPath $shortcut) 'WhatIf deleted a shortcut.'
    & $installer @options -Uninstall
    Assert-True (-not (Test-Path -LiteralPath $shortcut)) 'Uninstall did not delete a managed shortcut.'
    & $installer @options -Uninstall
    Assert-True (-not (Test-Path -LiteralPath $shortcut)) 'Uninstall created a missing shortcut.'

    $unmanaged = $shell.CreateShortcut($shortcut)
    try {
        $unmanaged.TargetPath = $ChromePath
        $unmanaged.Arguments = '--incognito'
        $unmanaged.Description = 'Existing user shortcut'
        $unmanaged.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($unmanaged)
    }
    $originalHash = (Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash
    Assert-Fails { & $installer @options } 'Install accepted an unmanaged shortcut.'
    Assert-Fails { & $installer @options -Uninstall } 'Uninstall accepted an unmanaged shortcut.'
    Assert-True ((Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash -eq $originalHash) 'An unmanaged shortcut was modified.'

    $options.ShortcutPath = Join-Path $testRoot 'Validation.lnk'
    foreach ($country in @('', 'u', 'usa', 'u1', 'us --incognito', "us`n")) {
        Assert-Fails { & $installer @options -Country $country } "Invalid country was accepted: '$country'."
    }
    Assert-True (-not (Test-Path -LiteralPath $options.ShortcutPath)) 'Invalid country created a shortcut.'
    Assert-Fails {
        & $installer -ChromePath (Join-Path $testRoot 'missing\chrome.exe') -ShortcutPath $options.ShortcutPath
    } 'A missing Chrome executable was accepted.'
    Assert-Fails {
        & $installer -ChromePath $ChromePath -ShortcutPath (Join-Path $testRoot 'missing\Chrome.lnk')
    } 'A missing shortcut directory was accepted.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'missing'))) 'The installer created a missing parent directory.'
    Assert-Fails {
        & $installer -ChromePath $ChromePath -ShortcutPath (Join-Path $testRoot 'Chrome.txt')
    } 'A non-lnk shortcut path was accepted.'

    & {
        function Get-Process {
            param($Name, $ErrorAction)
            [pscustomobject]@{ ProcessName = 'chrome'; Id = 12345 }
        }
        $runningWarnings = @()
        & $installer @options -WarningVariable runningWarnings -WarningAction SilentlyContinue
        Assert-True (Test-Path -LiteralPath $options.ShortcutPath) 'Install failed while Chrome was running.'
        Assert-True ($runningWarnings.Count -gt 0) 'Running Chrome did not produce a warning.'
    }

    $downloadedScript = [scriptblock]::Create((Get-Content -LiteralPath $installer -Raw))
    $options.ShortcutPath = Join-Path $testRoot 'Downloaded script.lnk'
    & $downloadedScript @options -Country US
    Assert-True ((Read-Shortcut $options.ShortcutPath).Arguments -eq '--enable-features=Glic --variations-override-country=us') 'Downloaded script content cannot execute with bound parameters.'

    $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Chrome - Gemini.lnk'
    $desktopHashBefore = if (Test-Path -LiteralPath $desktopShortcut) { (Get-FileHash -LiteralPath $desktopShortcut).Hash } else { $null }
    & {
        # Match an interactive irm | iex call without inheriting this test script's advanced-command context.
        $PSCmdlet = $null
        $PSBoundParameters = @{}
        $ErrorActionPreference = 'Stop'
        $WhatIfPreference = $true
        Get-Content -LiteralPath $installer -Raw | Invoke-Expression
    }
    $desktopHashAfter = if (Test-Path -LiteralPath $desktopShortcut) { (Get-FileHash -LiteralPath $desktopShortcut).Hash } else { $null }
    Assert-True ($desktopHashBefore -eq $desktopHashAfter) 'Invoke-Expression preview changed the default desktop shortcut.'

    Write-Host "PASS: $checks checks; shortcuts were created only in the temporary test directory."
} finally {
    if ($null -ne $shell) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = $tempBase.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar + 'gemini-launcher-tests-'
    if (-not $resolvedRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected path: $resolvedRoot"
    }
    if (Test-Path -LiteralPath $resolvedRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
