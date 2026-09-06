#Requires -Version 5.1
# ASCII entry point: explicitly decode the Chinese implementation as UTF-8.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [AllowEmptyString()]
    [string]$Country = 'us',
    [string]$UserDataDir,
    [string]$ChromePath,
    [string]$ShortcutPath,
    [switch]$Uninstall
)

& {
    param($EntryPath, $BoundOptions)
    if ($EntryPath) {
        $implementation = Join-Path (Split-Path -Parent $EntryPath) 'src\configure.ps1'
        $content = [IO.File]::ReadAllText($implementation, [Text.Encoding]::UTF8)
    }
    else {
        $content = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/HangMine/gemini-in-chrome/main/src/configure.ps1' -ErrorAction Stop
    }
    & ([scriptblock]::Create($content.TrimStart([char]0xFEFF))) @BoundOptions
} $MyInvocation.MyCommand.Path $PSBoundParameters
