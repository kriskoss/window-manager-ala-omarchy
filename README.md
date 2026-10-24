# Windows Omarchy

A Windows 11 keyboard-driven desktop modeled on [Omarchy](https://omarchy.org/manual/). Omarchy itself is Linux. This repo does not install or configure Hyprland, Quickshell, or Arch.

On this PC:

- Komorebi tiles windows. Its BSP layout is the dwindle equivalent: every window on a workspace stays visible.
- AutoHotkey v2 owns the Windows-key chords.
- `cli\omarchy.ps1` is the small companion CLI.
- Flow Launcher is the `Windows + Space` menu.
- `config\shell.json` is the top-bar layout. The bar window is not built yet.

Nothing here replaces `explorer.exe`. The Windows taskbar stays until you auto-hide it yourself.

## Prerequisites

Install these yourself:

- [Komorebi](https://komorebi.lgug2z.com/) (`komorebic.exe` on `PATH`)
- [AutoHotkey v2](https://www.autohotkey.com/)
- Flow Launcher, if you want `Windows + Space`
- Windows Terminal (`wt.exe`), if you want `Windows + Enter`

## Files

| File | Role |
| --- | --- |
| `config\komorebi.json` | Nine BSP workspaces, gaps, borders, and a 34px top offset for the bar |
| `hotkeys\omarchy.ahk` | Windows-key chords |
| `config\shell.json` | Bar widgets: workspaces and window title on the left, clock in the center, system metrics on the right |
| `config\theme.json` | Dark color and font tokens for a future bar |
| `cli\omarchy.ps1` | Query state, change layout, hop workspace, toggle the bar flag |
| `scripts\link-config.ps1` | Optional. Points `%USERPROFILE%\komorebi.json` at the repo config |

## Turn it on

1. Run `scripts\link-config.ps1` only when you want this repo to become the live Komorebi config. If `%USERPROFILE%\komorebi.json` already exists, the script renames it to `komorebi.json.bak-<timestamp>` and then links the repo file in its place. It does not start Komorebi.
2. Start Komorebi yourself: `komorebic start`
3. Run `hotkeys\omarchy.ahk` with AutoHotkey v2.

A second monitor needs its own object in `config\komorebi.json`, copied from the first `monitors` entry. Komorebi uses array index 0 for the primary monitor and index 1 for the next one.

## Chords

Super is the Windows key. Workspace numbers are 1–9. Komorebi itself counts from 0; the script and CLI translate.

| Chord | Action |
| --- | --- |
| `Win + H/J/K/L` or arrows | Focus left / down / up / right |
| `Win + Shift + H/J/K/L` or arrows | Move the window that way |
| `Win + 1`–`9` | Focus that workspace |
| `Win + Shift + 1`–`9` | Move the window to that workspace and follow it |
| `Win + Tab` / `Win + Shift + Tab` | Next / previous workspace |
| `Win + Q` or `Win + W` | Close the window |
| `Win + T` | Float or tile the window |
| `Win + F` | Monocle (workspace fullscreen) |
| `Win + Alt + L` | Toggle BSP and Scrolling |
| `Win + Minus` / `Win + Equal` | Grow / shrink horizontally |
| `Win + Shift + Minus` / `Win + Shift + Equal` | Grow / shrink vertically |
| `Win + Enter` | Windows Terminal |
| `Win + Shift + Enter` | Default browser |
| `Win + Shift + F` | File Explorer |
| `Win + Space` | Flow Launcher |
| `Win + Shift + Space` | Toggle `bar.visible` in `config\shell.json` |

`Win + Alt + L` switches only BSP and Scrolling. `komorebic cycle-layout` walks every Komorebi layout, so this chord does not use it. Floating is per window (`Win + T`), because Komorebi does not have a third "floating" layout.

## CLI

```powershell
.\cli\omarchy.ps1 state
.\cli\omarchy.ps1 layout bsp
.\cli\omarchy.ps1 layout scrolling
.\cli\omarchy.ps1 layout cycle
.\cli\omarchy.ps1 workspace 2
.\cli\omarchy.ps1 bar toggle
```

`state` prints Komorebi's JSON. `bar toggle` only flips the flag in `config\shell.json`. There is no bar process yet.

## Windows behavior worth knowing

- Bare `Win` still opens the Start menu.
- While the hotkey script is running, `Win + Space` does not switch input language, and `Win + Tab` does not open Task View.
- Windows reserves `Win + L` for locking the PC. Focus-right may not fire on that chord. Use `Win + Right`.
- The top work-area offset is 34px, matching the bar height. The bottom offset is 0, so tiled windows still stop above the Windows taskbar.
- Flow Launcher floats. Start, Search, and `ShellExperienceHost.exe` are ignored so Komorebi does not tile them.
- Borders stay at Komorebi's Windows 11 sizes (`border_width` 8, `border_offset` -1). A 1px border disappears into the Desktop Window Manager frame.
