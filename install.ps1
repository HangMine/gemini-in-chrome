#Requires -Version 5.1
<#
.SYNOPSIS
Creates a dedicated Chrome shortcut with a Gemini feature and country override.
.DESCRIPTION
Uses Chrome's startup switches instead of editing Local State or VariationsSeedV2.
Close all Chrome processes before starting Chrome from the installed shortcut.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('\A[A-Za-z]{2}\z')]
    [string]$Country = 'us',
    [string]$ChromePath,
    [string]$ShortcutPath,
    [switch]$Uninstall
)

# Invoke-Expression does not supply a PSCmdlet; an invoked advanced block does.
& {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($env:OS -ne 'Windows_NT') {
        throw 'This installer supports Windows only.'
    }

    $managedDescription = 'Gemini in Chrome launcher (HangMine/gemini-in-chrome)'
    $Country = $Country.ToLowerInvariant()

    if (-not $ShortcutPath) {
        $desktop = [Environment]::GetFolderPath('DesktopDirectory')
        if (-not $desktop) {
            throw 'Desktop folder not found. Specify -ShortcutPath with an existing directory.'
        }
        $ShortcutPath = Join-Path $desktop 'Chrome - Gemini.lnk'
    }

    $ShortcutPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ShortcutPath)
    if ([IO.Path]::GetExtension($ShortcutPath) -ine '.lnk') {
        throw '-ShortcutPath must name a Windows .lnk shortcut.'
    }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $ShortcutPath) -PathType Container)) {
        throw 'The shortcut directory does not exist. Specify an existing directory.'
    }
    if ((Test-Path -LiteralPath $ShortcutPath) -and
        -not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        throw "The shortcut path is not a file: $ShortcutPath"
    }

    if ($Uninstall -and -not (Test-Path -LiteralPath $ShortcutPath)) {
        Write-Host "Nothing to uninstall: $ShortcutPath"
        return
    }

    if (-not $Uninstall) {
        if (-not $ChromePath) {
            $installRoots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)
            foreach ($installRoot in $installRoots) {
                if ($installRoot) {
                    $candidate = Join-Path $installRoot 'Google\Chrome\Application\chrome.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                        $ChromePath = $candidate
                        break
                    }
                }
            }
        }
        if (-not $ChromePath -or -not (Test-Path -LiteralPath $ChromePath -PathType Leaf)) {
            throw 'Chrome was not found. Install Chrome or specify -ChromePath.'
        }
        $ChromePath = (Resolve-Path -LiteralPath $ChromePath -ErrorAction Stop).ProviderPath
        if ([IO.Path]::GetExtension($ChromePath) -ine '.exe') {
            throw '-ChromePath must name a Chrome executable (.exe).'
        }
    }

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell -ErrorAction Stop
        $shortcut = $shell.CreateShortcut($ShortcutPath)

        # Only links created by this installer may be changed or removed.
        if ((Test-Path -LiteralPath $ShortcutPath) -and
            $shortcut.Description -ne $managedDescription) {
            throw "Refusing to change an unrelated shortcut: $ShortcutPath. Choose another -ShortcutPath."
        }

        if ($Uninstall) {
            if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Remove the managed Gemini shortcut')) {
                Remove-Item -LiteralPath $ShortcutPath -ErrorAction Stop
                Write-Host "Removed: $ShortcutPath"
            }
            return
        }

        $arguments = "--enable-features=Glic --variations-override-country=$Country"
        if ($PSCmdlet.ShouldProcess($ShortcutPath, "Create or update Chrome shortcut ($Country)")) {
            $shortcut.TargetPath = $ChromePath
            $shortcut.Arguments = $arguments
            $shortcut.WorkingDirectory = Split-Path -Parent $ChromePath
            $shortcut.IconLocation = "$ChromePath,0"
            $shortcut.Description = $managedDescription
            $shortcut.Save()

            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
            $shortcut = $null
            $shortcut = $shell.CreateShortcut($ShortcutPath)
            if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) -or
                $shortcut.TargetPath -ine $ChromePath -or
                $shortcut.Arguments -cne $arguments -or
                $shortcut.Description -ne $managedDescription) {
                throw "Shortcut verification failed: $ShortcutPath"
            }

            Write-Host "Installed: $ShortcutPath" -ForegroundColor Green
            Write-Host "Arguments: $arguments"
            if (Get-Process -Name chrome -ErrorAction SilentlyContinue) {
                Write-Warning 'Chrome is running. Save your work and fully exit Chrome, including background processes.'
            }
            Write-Host 'Start Chrome using this shortcut after all Chrome processes have exited.'
            Write-Host 'The override applies to that browser process. Existing Chrome shortcuts are unchanged.'
            Write-Host 'This does not change your network exit location or guarantee Gemini service access.'
        }
    }
    finally {
        if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        }
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}
