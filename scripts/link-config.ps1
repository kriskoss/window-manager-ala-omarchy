# Points the user-profile Komorebi config at this repo.
# Backs up an existing %USERPROFILE%\komorebi.json first.
# Does not start Komorebi.
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Config = Join-Path $RepoRoot "config\komorebi.json"
if (-not (Test-Path -LiteralPath $Config)) {
    [Console]::Error.WriteLine("Missing $Config")
    exit 1
}
$Config = (Resolve-Path -LiteralPath $Config).Path
$Dest = Join-Path $env:USERPROFILE "komorebi.json"

if (Test-Path -LiteralPath $Dest) {
    $existing = Get-Item -LiteralPath $Dest -Force
    if ($existing.PSIsContainer) {
        [Console]::Error.WriteLine("$Dest is a directory. This script only replaces a config file.")
        exit 1
    }
    if ($existing.LinkType) {
        foreach ($target in @($existing.Target)) {
            if (-not $target) { continue }
            $resolved = Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue
            if ($resolved -and $resolved.Path -eq $Config) {
                Write-Output "Already linked: $Dest -> $Config"
                Write-Output "Komorebi was not started. When you want it: komorebic start"
                exit 0
            }
        }
    }

    $backup = "{0}.bak-{1}" -f $Dest, (Get-Date -Format "yyyyMMdd-HHmmss")
    Move-Item -LiteralPath $Dest -Destination $backup
    Write-Output "Backed up the existing config to $backup"
}

try {
    New-Item -ItemType SymbolicLink -Path $Dest -Target $Config | Out-Null
    Write-Output "Linked $Dest -> $Config"
}
catch {
    try {
        New-Item -ItemType HardLink -Path $Dest -Target $Config | Out-Null
        Write-Output "Hard-linked $Dest to $Config (same file on this drive)."
    }
    catch {
        [Console]::Error.WriteLine("Could not link the config. Windows blocked the link. Your previous file is still in the .bak copy if one was made.")
        exit 1
    }
}

Write-Output "Komorebi was not started. When you want it: komorebic start"
Write-Output "Then run hotkeys\omarchy.ahk with AutoHotkey v2."
