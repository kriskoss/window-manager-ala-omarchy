#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook

; Windows-key chords for Komorebi.
; Super is the Windows key. This script does not start Komorebi.
;
; Win+L locks the PC. Focus right is Win+Right.
; Win+Space no longer switches input language while this script is running.
; Win+Tab no longer opens Task View while this script is running.
; Win+K opens and closes the shortcut list, so focus up is Win+Up.
; Win+Alt+Backspace turns tiling and these shortcuts off and on. It keeps working while the others are suspended.

KomorebicExe := FindOnPath("komorebic.exe")
if !KomorebicExe || !FileExist(KomorebicExe)
    KomorebicExe := EnvGet("LOCALAPPDATA") "\komorebi\komorebic.exe"
if !FileExist(KomorebicExe)
    KomorebicExe := ""
FlowLauncherExe := FindFlowLauncher()
CliScript := A_ScriptDir "\..\cli\omarchy.ps1"
LastVirtualDesktop := ""
RebindBusy := false
RebindCooldownUntil := 0
SeenLogSize := 0
LastStateCheck := 0
NextRepair := 0

if !KomorebicExe
    TrayTip("komorebic.exe was not found on PATH. Tiling chords will not run until Komorebi is installed.", "Omarchy", "Icon!")

BindWorkspaceHotkeys()
SetTimer(WatchSystem, 300)

#h::RunKomorebic("focus left")
#j::RunKomorebic("focus down")
#Left::RunKomorebic("focus left")
#Down::RunKomorebic("focus down")
#Up::RunKomorebic("focus up")
#Right::RunKomorebic("focus right")

#+h::MoveTile("left")
#+j::MoveTile("down")
#+k::MoveTile("up")
#+l::MoveTile("right")
*#+Left::MoveTile("left")
*#+Down::MoveTile("down")
*#+Up::MoveTile("up")
*#+Right::MoveTile("right")

#Tab::RunCliWait("workspace-cycle next")
#+Tab::RunCliWait("workspace-cycle previous")

#q::RunKomorebic("close")
#w::RunKomorebic("close")
#t::RunKomorebic("toggle-float")
#f::RunKomorebic("toggle-monocle")

; BSP and Scrolling only. komorebic cycle-layout walks every layout.
#!l::RunCli("layout cycle")

#-::RunKomorebic("resize-axis horizontal increase")
#=::RunKomorebic("resize-axis horizontal decrease")
#+-::RunKomorebic("resize-axis vertical increase")
#+=::RunKomorebic("resize-axis vertical decrease")

#Enter::OpenTerminal()
#+Enter::OpenDefaultBrowser()
#+f::Run("explorer.exe")

#Space::OpenLauncher()
#+Space::RunCli("bar toggle")
#k::ToggleShortcuts()

#SuspendExempt
#!Backspace::RunCli("system toggle")
#SuspendExempt False

BindWorkspaceHotkeys() {
    Loop 9 {
        n := A_Index
        Hotkey("#" n, FocusWorkspace.Bind(n))
        Hotkey("#+" n, MoveToWorkspace.Bind(n))
    }
}

FocusWorkspace(n, *) {
    RunCliWait("workspace " n)
}

MoveToWorkspace(n, *) {
    RunCliWait("workspace-move " n)
}

MoveTile(direction, *) {
    RunCliWait(Format("move {1}", direction))
}

RunKomorebic(args) {
    global KomorebicExe
    if !KomorebicExe {
        TrayTip("komorebic.exe was not found on PATH.", "Omarchy", "Icon!")
        return
    }
    Run(Format('"{1}" {2}', KomorebicExe, args), , "Hide")
}

RunCli(args) {
    global CliScript
    if !FileExist(CliScript) {
        TrayTip("cli\omarchy.ps1 is missing.", "Omarchy", "Icon!")
        return
    }
    Run(Format('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" {2}', CliScript, args), , "Hide")
}

RunCliWait(args) {
    global CliScript
    if !FileExist(CliScript) {
        TrayTip("cli\omarchy.ps1 is missing.", "Omarchy", "Icon!")
        return
    }
    RunWait(Format('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" {2}', CliScript, args), , "Hide")
}

OpenLauncher(*) {
    global FlowLauncherExe
    if !FlowLauncherExe || !FileExist(FlowLauncherExe) {
        TrayTip("Flow Launcher was not found. Install it, then reload this script.", "Omarchy", "Icon!")
        return
    }
    try
        Run(Format('"{1}"', FlowLauncherExe))
    catch
        TrayTip("Flow Launcher could not be started.", "Omarchy", "Icon!")
}

OpenTerminal(*) {
    try
        Run("wt.exe")
    catch
        TrayTip("Windows Terminal (wt.exe) was not found.", "Omarchy", "Icon!")
}

OpenDefaultBrowser(*) {
    try
        Run(A_ComSpec ' /c start "" "https:"', , "Hide")
    catch
        TrayTip("The default browser could not be opened.", "Omarchy", "Icon!")
}

ToggleShortcuts(*) {
    global ShortcutGui
    if IsSet(ShortcutGui) {
        sheet := ShortcutGui
        ShortcutGui := unset
        try sheet.Destroy()
        return
    }
    ShortcutGui := Gui("+AlwaysOnTop +ToolWindow", "Shortcuts")
    ShortcutGui.BackColor := "1d2021"
    ShortcutGui.MarginX := 22
    ShortcutGui.MarginY := 16
    ShortcutGui.SetFont("s16 cFABD2F", "Segoe UI")
    ShortcutGui.Add("Text", , "Shortcuts")
    ShortcutGui.SetFont("s10 c928374", "Segoe UI")
    ShortcutGui.Add("Text", "w640", "Press Win+K again to close. Win+L locks the PC, so focus right is Win+Right.")
    ShortcutGui.SetFont("s11 cEBDBB2", "Segoe UI")
    ShortcutGui.Add("Text", "w640", ShortcutText())
    ShortcutGui.OnEvent("Escape", ToggleShortcuts)
    ShortcutGui.OnEvent("Close", ForgetShortcuts)
    ShortcutGui.Show("AutoSize Center")
}

ForgetShortcuts(*) {
    global ShortcutGui
    ShortcutGui := unset
}

ShortcutText() {
    return "Focus`n"
        . "Win+H or Win+Left             focus left`n"
        . "Win+J or Win+Down             focus down`n"
        . "Win+Up                        focus up`n"
        . "Win+Right                     focus right`n"
        . "Win+L may lock the PC, so it is not used for focus.`n"
        . "At the screen edge, arrows move focus onto the next screen.`n`n"
        . "Move a window`n"
        . "Win+Shift+H  J  K  L or arrows`n"
        . "At the screen edge, this moves the window onto the next screen.`n`n"
        . "Workspaces`n"
        . "Win+1 through 9               go to that workspace on this screen`n"
        . "Win+Shift+1 through 9         move the window there and follow it`n"
        . "Win+Tab                       next workspace`n"
        . "Win+Shift+Tab                 previous workspace`n"
        . "An empty workspace closes when you leave it.`n"
        . "Win+3 still means workspace 3 after another one closes.`n`n"
        . "Windows`n"
        . "Win+Q or Win+W                close`n"
        . "Win+T                         float or tile`n"
        . "Win+F                         fullscreen on this workspace`n"
        . "Win+Alt+L                     BSP (full, then split) or Scrolling`n"
        . "Win+Minus / Win+Equal         grow or shrink sideways`n"
        . "Win+Shift+Minus / Equal       grow or shrink vertically`n`n"
        . "Launch`n"
        . "Win+Space                     Flow Launcher`n"
        . "Win+Shift+Space               hide or show the top bar`n"
        . "Win+Enter                     Windows Terminal`n"
        . "Win+Shift+Enter               browser`n"
        . "Win+Shift+F                   File Explorer`n"
        . "Win+K                         this list`n`n"
        . "System`n"
        . "Win+Alt+Backspace             turn tiling and these shortcuts off or on`n"
        . "The On / Off button on the left of the bar does the same.`n"
        . "While off, Windows shortcuts work again, including Win+Shift+S.`n`n"
        . "Taken from Windows while On`n"
        . "Win+H                         voice typing`n"
        . "Win+W                         Widgets`n"
        . "Win+Q                         Search`n"
        . "Win+T                         cycle taskbar apps`n"
        . "Win+F                         Feedback Hub`n"
        . "Win+K                         Cast`n"
        . "Win+1 through 9               launch pinned taskbar apps`n"
        . "Win+Shift+1 through 9         new window of a pinned app`n"
        . "Win+Arrow                     snap. Win+Up maximizes, Win+Down restores`n"
        . "Win+Space                     switch input language`n"
        . "Win+Tab                       Task View`n"
        . "Win+Minus / Win+Equal         Magnifier`n`n"
        . "Not used here`n"
        . "Win+Shift+S and Print Screen  snip the whole desktop`n"
        . "Win+S  E  D  P  I  A  V  X    Search, Explorer, desktop, project,`n"
        . "                              Settings, quick settings, clipboard, menu"
}

WatchSystem() {
    WatchDesktop()
    if (SystemIsOff() && !A_IsSuspended)
        Suspend(true)
    else if (!SystemIsOff() && A_IsSuspended)
        Suspend(false)
}

WatchDesktop() {
    global LastVirtualDesktop, RebindBusy, RebindCooldownUntil, SeenLogSize
    if (SystemIsOff() || RebindBusy)
        return
    cooled := (RebindCooldownUntil != 0 && A_TickCount < RebindCooldownUntil)
    id := ReadVirtualDesktopId()
    first := (LastVirtualDesktop = "")
    idChanged := !first && id != "" && id != LastVirtualDesktop
    stuck := false
    if (!cooled)
        stuck := TilingIsStuck()
    if first
        LastVirtualDesktop := id
    if (idChanged || stuck) {
        if (idChanged)
            Sleep(500)
        RebindBusy := true
        RunCliWait(Format('desktop rebind "{1}"', LastVirtualDesktop))
        LastVirtualDesktop := ReadVirtualDesktopId()
        SeenLogSize := KomorebiLogSize()
        RebindCooldownUntil := A_TickCount + 20000
        RebindBusy := false
    }
    RepairTiles()
}

RepairTiles() {
    global NextRepair, RebindBusy
    if (SystemIsOff() || RebindBusy)
        return
    if (NextRepair != 0 && A_TickCount < NextRepair)
        return
    NextRepair := A_TickCount + 15000
    RunCliWait("desktop repair")
}

TilingIsStuck() {
    global LastStateCheck
    if LogSaysIgnoring()
        return true
    if (LastStateCheck != 0 && A_TickCount - LastStateCheck < 3000)
        return false
    LastStateCheck := A_TickCount
    return TilingStateEmpty()
}

LogSaysIgnoring() {
    global SeenLogSize
    path := KomorebiLogPath()
    if !path
        return false
    size := FileGetSize(path)
    if (size < SeenLogSize)
        SeenLogSize := 0
    if (size = SeenLogSize)
        return false
    return InStr(ReadTail(path, SeenLogSize), "ignoring events and commands")
}

TilingStateEmpty() {
    global KomorebicExe
    if !KomorebicExe || !FileExist(KomorebicExe)
        return false
    out := A_Temp "\omarchy-stuck-state.txt"
    if FileExist(out) {
        try
            FileDelete(out)
        catch
            return false
    }
    try
        RunWait(Format('"{1}" /c ""{2}" state > "{3}""', A_ComSpec, KomorebicExe, out), , "Hide")
    catch
        return false
    if !FileExist(out)
        return true
    try
        text := Trim(FileRead(out), " `t`r`n")
    catch
        return true
    return text = "" || StrLen(text) < 2
}

KomorebiLogPath() {
    best := ""
    bestTime := ""
    loop files A_Temp "\komorebi_plaintext.log.*" {
        if (best = "" || A_LoopFileTimeModified > bestTime) {
            best := A_LoopFileFullPath
            bestTime := A_LoopFileTimeModified
        }
    }
    return best
}

KomorebiLogSize() {
    path := KomorebiLogPath()
    return path ? FileGetSize(path) : 0
}

ReadTail(path, from, maxBytes := 8192) {
    size := FileGetSize(path)
    if (size <= from)
        return ""
    start := from
    if (size - start > maxBytes)
        start := size - maxBytes
    file := FileOpen(path, "r", "UTF-8")
    if !file
        return ""
    file.Pos := start
    text := file.Read()
    file.Close()
    return text
}

ReadVirtualDesktopId() {
    parts := []
    try {
        Loop Reg, "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo", "K" {
            parts.Push(ReadBinaryReg("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\" A_LoopRegName "\VirtualDesktops", "CurrentVirtualDesktop"))
        }
    }
    catch {
    }
    parts.Push(ReadBinaryReg("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops", "CurrentVirtualDesktop"))
    blank := true
    for part in parts {
        if (part != "")
            blank := false
    }
    if blank
        return ""
    out := ""
    for index, part in parts {
        if (index > 1)
            out .= "|"
        out .= part
    }
    return out
}

ReadBinaryReg(key, valueName) {
    try
        data := RegRead(key, valueName)
    catch
        return ""
    if !(data is Buffer)
        return Trim(String(data))
    hex := ""
    loop data.Size
        hex .= Format("{:02X}", NumGet(data, A_Index - 1, "UChar"))
    return hex
}

SystemIsOff() {
    path := EnvGet("LOCALAPPDATA") "\omarchy\system-enabled"
    if !FileExist(path)
        return false
    try
        state := Trim(FileRead(path), " `t`r`n")
    catch
        return false
    return state = "off"
}

FindOnPath(name) {
    pathEnv := EnvGet("PATH")
    if pathEnv = ""
        return ""
    for dir in StrSplit(pathEnv, ";") {
        dir := Trim(dir, " `t`"")
        if dir = ""
            continue
        candidate := RTrim(dir, "\") "\" name
        if FileExist(candidate)
            return candidate
    }
    return ""
}

FindFlowLauncher() {
    localAppData := EnvGet("LOCALAPPDATA")
    candidates := [
        localAppData "\FlowLauncher\Flow.Launcher.exe",
        localAppData "\FlowLauncher\app\Flow.Launcher.exe",
        EnvGet("ProgramFiles") "\Flow Launcher\Flow.Launcher.exe"
    ]
    for path in candidates {
        if FileExist(path)
            return path
    }
    loop files localAppData "\FlowLauncher\app-*", "D" {
        candidate := A_LoopFileFullPath "\Flow.Launcher.exe"
        if FileExist(candidate)
            return candidate
    }
    return FindOnPath("Flow.Launcher.exe")
}
