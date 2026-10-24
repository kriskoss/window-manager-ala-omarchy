# Windows 11 companion for this repo. Calls komorebic.exe and edits config\shell.json.
# Does not start Komorebi.
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Value,

    [Parameter(Position = 2)]
    [string]$Extra
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Show-Usage {
    [Console]::Error.WriteLine(@"
Usage:
  omarchy.ps1 state
  omarchy.ps1 layout bsp|scrolling|cycle
  omarchy.ps1 workspace <1-9>
  omarchy.ps1 workspace-move <1-9>
  omarchy.ps1 workspace-cycle next|previous
  omarchy.ps1 desktop rebind [leaving-id]
  omarchy.ps1 desktop repair
  omarchy.ps1 bar toggle
  omarchy.ps1 system toggle
"@)
}

function Get-SystemFlagPath {
    Join-Path $env:LOCALAPPDATA "omarchy\system-enabled"
}

function Set-SystemFlag {
    param([string]$State)
    $path = Get-SystemFlagPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $State, $utf8)
}

function Switch-System {
    $exe = Get-Komorebic
    $config = Join-Path $RepoRoot "config\komorebi.json"
    $mutex = New-Object System.Threading.Mutex($false, "Local\OmarchySystemToggle")
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        Write-Output "System toggle is already running."
        exit 0
    }
    try {
        if (Get-Process komorebi -ErrorAction SilentlyContinue) {
            Set-SystemFlag "off"
            & $exe stop | Out-Null
            $deadline = (Get-Date).AddSeconds(25)
            while ((Get-Process komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
            }
            if (Get-Process komorebi -ErrorAction SilentlyContinue) {
                Set-SystemFlag "on"
                [Console]::Error.WriteLine("Komorebi did not stop.")
                exit 1
            }
            Write-Output "System is off."
            exit 0
        }

        if (-not (Start-KomorebiForRebind)) {
            Set-SystemFlag "off"
            [Console]::Error.WriteLine("Komorebi did not start.")
            exit 1
        }
        Set-SystemFlag "on"
        Write-Output "System is on."
        exit 0
    }
    finally {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}

function Get-Komorebic {
    $cmd = Get-Command komorebic.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    $portable = Join-Path $env:LOCALAPPDATA "komorebi\komorebic.exe"
    if (Test-Path -LiteralPath $portable) {
        return $portable
    }
    [Console]::Error.WriteLine("komorebic.exe was not found on PATH. Install Komorebi and reopen the shell.")
    exit 1
}

function Get-FocusedLayoutName {
    param([string]$Exe)

    $raw = & $Exe state 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine($raw.Trim())
        exit $LASTEXITCODE
    }

    $state = $raw | ConvertFrom-Json
    $monitorRing = $state.monitors
    $workspaceRing = $monitorRing.elements[$monitorRing.focused].workspaces
    $layout = [string]$workspaceRing.elements[$workspaceRing.focused].layout
    if (-not $layout) {
        [Console]::Error.WriteLine("Could not read the focused workspace layout from komorebic state.")
        exit 1
    }
    return $layout
}

function Set-BarVisible {
    $path = Join-Path $RepoRoot "config\shell.json"
    if (-not (Test-Path -LiteralPath $path)) {
        [Console]::Error.WriteLine("Missing $path")
        exit 1
    }

    $raw = [System.IO.File]::ReadAllText($path)
    if ($raw -match '"visible"\s*:\s*true') {
        $updated = [regex]::Replace($raw, '"visible"\s*:\s*true', '"visible": false', 1)
        $now = "hidden"
    }
    elseif ($raw -match '"visible"\s*:\s*false') {
        $updated = [regex]::Replace($raw, '"visible"\s*:\s*false', '"visible": true', 1)
        $now = "visible"
    }
    else {
        [Console]::Error.WriteLine('config\shell.json has no bar.visible flag.')
        exit 1
    }

    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $updated, $utf8)
    Write-Output "Bar is $now."
}

function Test-SystemOff {
    $path = Get-SystemFlagPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $false
    }
    return ([System.IO.File]::ReadAllText($path).Trim() -eq "off")
}

function Enter-OmarchyLock {
    $script:OmarchyLock = New-Object System.Threading.Mutex($false, "Local\OmarchySystemToggle")
    $owned = $false
    try {
        $owned = $script:OmarchyLock.WaitOne(45000)
    }
    catch [System.Threading.AbandonedMutexException] {
        $owned = $true
    }
    if (-not $owned) {
        [Console]::Error.WriteLine("Komorebi is busy.")
        exit 1
    }
}

function Exit-OmarchyLock {
    if (-not $script:OmarchyLock) {
        return
    }
    try {
        $script:OmarchyLock.ReleaseMutex() | Out-Null
    }
    catch {
    }
    $script:OmarchyLock.Dispose()
    $script:OmarchyLock = $null
}

function Invoke-Komorebic {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $exe = Get-Komorebic
    & $exe @Arguments | Out-Null
}

function Get-KomorebiState {
    $exe = Get-Komorebic
    $out = Join-Path $env:TEMP ("omarchy-state-" + [guid]::NewGuid().ToString("n") + ".json")
    $err = Join-Path $env:TEMP ("omarchy-state-" + [guid]::NewGuid().ToString("n") + ".err")
    try {
        Start-Process -FilePath $exe -ArgumentList "state" -RedirectStandardOutput $out -RedirectStandardError $err -Wait -WindowStyle Hidden | Out-Null
        if (-not (Test-Path -LiteralPath $out)) {
            return $null
        }
        $raw = [System.IO.File]::ReadAllText($out)
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim().Length -lt 2) {
            return $null
        }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
    finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Get-RingItems {
    param($Node)
    if ($null -eq $Node) {
        return @()
    }
    $raw = $null
    if ($Node -is [System.Array]) {
        $raw = $Node
    }
    elseif ($Node.PSObject.Properties.Name -contains "elements") {
        $raw = $Node.elements
    }
    else {
        return @()
    }
    if ($null -eq $raw) {
        return @()
    }
    return @($raw)
}

function Get-FocusedMonitorSnapshot {
    param($State)
    if ($null -eq $State) {
        return $null
    }
    $monitors = @(Get-RingItems $State.monitors)
    if ($monitors.Count -eq 0) {
        return $null
    }
    $focused = 0
    if ($State.monitors.PSObject.Properties.Name -contains "focused" -and $null -ne $State.monitors.focused) {
        $focused = [int]$State.monitors.focused
    }
    if ($focused -lt 0 -or $focused -ge $monitors.Count) {
        $focused = 0
    }
    $monitor = $monitors[$focused]
    $workspaces = @(Get-RingItems $monitor.workspaces)
    if ($workspaces.Count -eq 0) {
        return $null
    }
    $workspaceIndex = 0
    if ($monitor.workspaces.PSObject.Properties.Name -contains "focused" -and $null -ne $monitor.workspaces.focused) {
        $workspaceIndex = [int]$monitor.workspaces.focused
    }
    if ($workspaceIndex -lt 0 -or $workspaceIndex -ge $workspaces.Count) {
        $workspaceIndex = 0
    }
    return [pscustomobject]@{
        MonitorIndex   = $focused
        Workspaces     = $workspaces
        WorkspaceIndex = $workspaceIndex
    }
}

function Get-MonitorSnapshot {
    param($State, [int]$MonitorIndex)
    $monitors = @(Get-RingItems $State.monitors)
    if ($MonitorIndex -lt 0 -or $MonitorIndex -ge $monitors.Count) {
        return $null
    }
    $monitor = $monitors[$MonitorIndex]
    $workspaces = @(Get-RingItems $monitor.workspaces)
    if ($workspaces.Count -eq 0) {
        return $null
    }
    $workspaceIndex = 0
    if ($monitor.workspaces.PSObject.Properties.Name -contains "focused" -and $null -ne $monitor.workspaces.focused) {
        $workspaceIndex = [int]$monitor.workspaces.focused
    }
    if ($workspaceIndex -lt 0 -or $workspaceIndex -ge $workspaces.Count) {
        $workspaceIndex = 0
    }
    return [pscustomobject]@{
        MonitorIndex   = $MonitorIndex
        Workspaces     = $workspaces
        WorkspaceIndex = $workspaceIndex
    }
}

function Test-WorkspaceEmpty {
    param($Workspace)
    if ($null -eq $Workspace) {
        return $true
    }
    if (@(Get-RingItems $Workspace.containers).Count -gt 0) {
        return $false
    }
    if (@(Get-RingItems $Workspace.floating_windows).Count -gt 0) {
        return $false
    }
    if ($Workspace.PSObject.Properties.Name -contains "monocle_container" -and $null -ne $Workspace.monocle_container) {
        return $false
    }
    if ($Workspace.PSObject.Properties.Name -contains "maximized_window" -and $null -ne $Workspace.maximized_window) {
        return $false
    }
    return $true
}

function Get-WorkspaceNamePath {
    Join-Path $env:LOCALAPPDATA "omarchy\workspace-names.json"
}

function Get-DesktopLayoutDir {
    Join-Path $env:LOCALAPPDATA "omarchy\desktops"
}

function Get-DesktopLayoutKey {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) {
        return ""
    }
    return ($Token.Trim() -replace '[^A-Za-z0-9]', '_')
}

function Save-DesktopLayout {
    param([string]$Token)
    $key = Get-DesktopLayoutKey $Token
    if (-not $key) {
        return
    }
    $dir = Get-DesktopLayoutDir
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $code = Invoke-TileScript -Arguments @("save", (Join-Path $dir "$key.json"))
    if ($code -ne 0) {
        return
    }
    $names = Get-WorkspaceNamePath
    if (Test-Path -LiteralPath $names) {
        Copy-Item -LiteralPath $names -Destination (Join-Path $dir "$key.names.json") -Force
    }
}

function Restore-DesktopLayout {
    param([string]$Token)
    $key = Get-DesktopLayoutKey $Token
    if (-not $key) {
        return
    }
    $saved = Join-Path (Get-DesktopLayoutDir) "$key.json"
    if (-not (Test-Path -LiteralPath $saved)) {
        return
    }
    $code = Invoke-TileScript -Arguments @("restore", $saved)
    if ($code -ne 0) {
        return
    }
    $names = Join-Path (Get-DesktopLayoutDir) "$key.names.json"
    if (-not (Test-Path -LiteralPath $names)) {
        return
    }
    $dest = Get-WorkspaceNamePath
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
    }
    Copy-Item -LiteralPath $names -Destination $dest -Force
}

function Read-WorkspaceNameMap {
    $map = @{}
    $path = Get-WorkspaceNamePath
    if (-not (Test-Path -LiteralPath $path)) {
        return ,$map
    }
    try {
        $raw = [System.IO.File]::ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return ,$map
        }
        $obj = $raw | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) {
            $map[$prop.Name] = @($prop.Value | ForEach-Object { [string]$_ })
        }
    }
    catch {
    }
    return ,$map
}

function Write-WorkspaceNameMap {
    param($Map)
    $path = Get-WorkspaceNamePath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("{")
    $first = $true
    foreach ($key in ($Map.Keys | Sort-Object { [int]$_ })) {
        if (-not $first) {
            [void]$builder.Append(",")
        }
        $first = $false
        $labels = @($Map[$key] | ForEach-Object { '"' + (([string]$_) -replace '"', '') + '"' })
        [void]$builder.Append(('"{0}":[{1}]' -f $key, ($labels -join ",")))
    }
    [void]$builder.Append("}")
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $builder.ToString(), $utf8)
}

function Set-NamesForMonitor {
    param([int]$MonitorIndex, [string[]]$Names)
    $map = Read-WorkspaceNameMap
    $map["$MonitorIndex"] = @($Names)
    Write-WorkspaceNameMap $map
}

function Get-KomorebiWorkspaceName {
    param($Workspace)
    if ($Workspace.PSObject.Properties.Name -contains "name" -and $Workspace.name) {
        return [string]$Workspace.name
    }
    return ""
}

function Get-NamesForMonitor {
    param([int]$MonitorIndex, $Workspaces)
    $workspaces = @($Workspaces)
    $map = Read-WorkspaceNameMap
    $key = "$MonitorIndex"
    $saved = New-Object System.Collections.Generic.List[string]
    if ($map.ContainsKey($key)) {
        foreach ($item in @($map[$key])) {
            $saved.Add([string]$item)
        }
    }
    if ($saved.Count -eq $workspaces.Count -and $saved.Count -gt 0) {
        $script:PublishedNames = $saved
        return
    }
    $saved.Clear()
    $used = @{}
    $labels = $saved
    foreach ($workspace in $workspaces) {
        $label = Get-KomorebiWorkspaceName $workspace
        if ($label -and -not $used.ContainsKey($label)) {
            $labels.Add($label)
            $used[$label] = $true
            continue
        }
        $number = 1
        while ($used.ContainsKey("$number")) {
            $number++
        }
        $labels.Add("$number")
        $used["$number"] = $true
    }
    $map[$key] = @($labels)
    Write-WorkspaceNameMap $map
    $script:PublishedNames = $labels
}

function Find-NameIndex {
    param($Names, [string]$Name)
    if ($null -eq $Names) {
        return -1
    }
    for ($i = 0; $i -lt $Names.Count; $i++) {
        if ([string]$Names[$i] -eq $Name) {
            return $i
        }
    }
    return -1
}

function Focus-WorkspaceByName {
    param([int]$MonitorIndex, [string]$Name)
    $state = Get-KomorebiState
    if ($null -eq $state) {
        return
    }
    $snap = Get-MonitorSnapshot $state $MonitorIndex
    if ($null -eq $snap) {
        return
    }
    Get-NamesForMonitor $MonitorIndex $snap.Workspaces
    $names = $script:PublishedNames
    $index = Find-NameIndex $names $Name
    if ($index -ge 0) {
        Invoke-Komorebic focus-monitor-workspace $MonitorIndex $index
    }
}

function Close-LeftWorkspace {
    param(
        [int]$MonitorIndex,
        [int]$LeftIndex,
        $Names,
        [string]$DestinationName
    )
    $names = $Names
    if ($null -eq $names -or $names.Count -le 1 -or $LeftIndex -lt 0 -or $LeftIndex -ge $names.Count) {
        return $false
    }
    Invoke-Komorebic focus-monitor-workspace $MonitorIndex $LeftIndex
    Invoke-Komorebic close-workspace
    $state = Get-KomorebiState
    $snap = $null
    if ($null -ne $state) {
        $snap = Get-MonitorSnapshot $state $MonitorIndex
    }
    if ($null -eq $snap -or $snap.Workspaces.Count -ge $names.Count) {
        Focus-WorkspaceByName $MonitorIndex $DestinationName
        return $false
    }
    $kept = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $names.Count; $i++) {
        if ($i -ne $LeftIndex) {
            $kept.Add([string]$names[$i])
        }
    }
    Set-NamesForMonitor $MonitorIndex @($kept)
    Focus-WorkspaceByName $MonitorIndex $DestinationName
    return $true
}

function Ensure-WorkspaceName {
    param($Snapshot, [string]$Number)
    Get-NamesForMonitor $Snapshot.MonitorIndex $Snapshot.Workspaces
    $names = $script:PublishedNames
    $index = Find-NameIndex $names $Number
    if ($index -ge 0) {
        $script:EnsureIndex = $index
        return
    }
    $count = @($Snapshot.Workspaces).Count
    Invoke-Komorebic ensure-workspaces $Snapshot.MonitorIndex ($count + 1)
    Invoke-Komorebic workspace-layout $Snapshot.MonitorIndex $count bsp
    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($label in @($names)) {
        $labels.Add([string]$label)
    }
    $labels.Add($Number)
    Set-NamesForMonitor $Snapshot.MonitorIndex @($labels)
    $script:PublishedNames = $labels
    $script:EnsureIndex = $labels.Count - 1
}

function Invoke-WorkspaceFocus {
    param([string]$Number)
    if ($Number -notmatch '^[1-9]$') {
        Show-Usage
        exit 1
    }
    Enter-OmarchyLock
    $failed = $false
    try {
        $state = Get-KomorebiState
        $snap = Get-FocusedMonitorSnapshot $state
        if ($null -eq $snap) {
            [Console]::Error.WriteLine("Komorebi did not answer.")
            $failed = $true
            return
        }
        $leftIndex = $snap.WorkspaceIndex
        $leftEmpty = Test-WorkspaceEmpty $snap.Workspaces[$leftIndex]
        Ensure-WorkspaceName $snap $Number
        $destIndex = $script:EnsureIndex
        $destNames = $script:PublishedNames
        if ($destIndex -eq $leftIndex) {
            return
        }
        Invoke-Komorebic focus-monitor-workspace $snap.MonitorIndex $destIndex
        if ($leftEmpty) {
            Close-LeftWorkspace $snap.MonitorIndex $leftIndex $destNames $Number | Out-Null
        }
    }
    finally {
        Exit-OmarchyLock
    }
    if ($failed) {
        exit 1
    }
}

function Invoke-WorkspaceMove {
    param([string]$Number)
    if ($Number -notmatch '^[1-9]$') {
        Show-Usage
        exit 1
    }
    Enter-OmarchyLock
    $failed = $false
    try {
        $state = Get-KomorebiState
        $snap = Get-FocusedMonitorSnapshot $state
        if ($null -eq $snap) {
            [Console]::Error.WriteLine("Komorebi did not answer.")
            $failed = $true
            return
        }
        $leftIndex = $snap.WorkspaceIndex
        Ensure-WorkspaceName $snap $Number
        $destIndex = $script:EnsureIndex
        $destNames = $script:PublishedNames
        if ($destIndex -eq $leftIndex) {
            return
        }
        Invoke-Komorebic focus-monitor $snap.MonitorIndex
        Invoke-Komorebic move-to-workspace $destIndex
        $after = Get-KomorebiState
        $leftSnap = $null
        if ($null -ne $after) {
            $leftSnap = Get-MonitorSnapshot $after $snap.MonitorIndex
        }
        if ($null -ne $leftSnap -and $leftIndex -lt @($leftSnap.Workspaces).Count -and (Test-WorkspaceEmpty $leftSnap.Workspaces[$leftIndex])) {
            Close-LeftWorkspace $snap.MonitorIndex $leftIndex $destNames $Number | Out-Null
        }
    }
    finally {
        Exit-OmarchyLock
    }
    if ($failed) {
        exit 1
    }
}

function Invoke-WorkspaceCycle {
    param([string]$Direction)
    $direction = $Direction.ToLowerInvariant()
    if ($direction -ne "next" -and $direction -ne "previous") {
        Show-Usage
        exit 1
    }
    Enter-OmarchyLock
    $failed = $false
    try {
        $state = Get-KomorebiState
        $snap = Get-FocusedMonitorSnapshot $state
        if ($null -eq $snap) {
            [Console]::Error.WriteLine("Komorebi did not answer.")
            $failed = $true
            return
        }
        Get-NamesForMonitor $snap.MonitorIndex $snap.Workspaces
        $names = $script:PublishedNames
        if ($names.Count -le 1) {
            return
        }
        $leftIndex = $snap.WorkspaceIndex
        $leftEmpty = Test-WorkspaceEmpty $snap.Workspaces[$leftIndex]
        $destIndex = $leftIndex + 1
        if ($direction -eq "previous") {
            $destIndex = $leftIndex - 1
        }
        if ($destIndex -ge $names.Count) {
            $destIndex = 0
        }
        if ($destIndex -lt 0) {
            $destIndex = $names.Count - 1
        }
        $destName = [string]$names[$destIndex]
        Invoke-Komorebic focus-monitor-workspace $snap.MonitorIndex $destIndex
        if ($leftEmpty) {
            Close-LeftWorkspace $snap.MonitorIndex $leftIndex $names $destName | Out-Null
        }
    }
    finally {
        Exit-OmarchyLock
    }
    if ($failed) {
        exit 1
    }
}

function Close-EmptyWorkspacesOnAllMonitors {
    $state = Get-KomorebiState
    if ($null -eq $state) {
        return
    }
    $monitorCount = @(Get-RingItems $state.monitors).Count
    for ($monitorIndex = 0; $monitorIndex -lt $monitorCount; $monitorIndex++) {
        for ($pass = 0; $pass -lt 9; $pass++) {
            $current = Get-KomorebiState
            if ($null -eq $current) {
                return
            }
            $snap = Get-MonitorSnapshot $current $monitorIndex
            if ($null -eq $snap) {
                break
            }
            Get-NamesForMonitor $monitorIndex $snap.Workspaces
            $names = $script:PublishedNames
            if ($names.Count -le 1) {
                break
            }
            $keepName = [string]$names[$snap.WorkspaceIndex]
            $closed = $false
            for ($i = $snap.Workspaces.Count - 1; $i -ge 0; $i--) {
                if ($i -eq $snap.WorkspaceIndex) {
                    continue
                }
                if (-not (Test-WorkspaceEmpty $snap.Workspaces[$i])) {
                    continue
                }
                if (Close-LeftWorkspace $monitorIndex $i $names $keepName) {
                    $closed = $true
                    break
                }
            }
            if (-not $closed) {
                break
            }
        }
    }
}

function Read-RegBinary {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
    }
    catch {
        return ""
    }
    $bytes = $item.$Name
    if ($bytes -is [byte[]]) {
        return ([System.BitConverter]::ToString($bytes)).Replace("-", "")
    }
    return ""
}

function Get-VirtualDesktopToken {
    $parts = New-Object System.Collections.Generic.List[string]
    $sessionRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo"
    if (Test-Path -LiteralPath $sessionRoot) {
        foreach ($key in Get-ChildItem -LiteralPath $sessionRoot) {
            $vd = Join-Path $key.PSPath "VirtualDesktops"
            $parts.Add((Read-RegBinary $vd "CurrentVirtualDesktop"))
        }
    }
    $globalKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops"
    $parts.Add((Read-RegBinary $globalKey "CurrentVirtualDesktop"))
    return ($parts -join "|")
}

function Get-ActiveLogPath {
    $logs = @(Get-ChildItem -Path $env:TEMP -Filter "komorebi_plaintext.log.*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($logs.Count -gt 0) {
        return $logs[0].FullName
    }
    return (Join-Path $env:TEMP ("komorebi_plaintext.log." + (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")))
}

function Get-LogLength {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [long]0
    }
    return [long](Get-Item -LiteralPath $Path).Length
}

function Test-LogIgnoresSince {
    param([string]$Path, [long]$Offset)
    $deadline = (Get-Date).AddSeconds(2.5)
    do {
        if (Test-Path -LiteralPath $Path) {
            try {
                $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $start = $Offset
                    if ($stream.Length -lt $start) {
                        $start = 0
                    }
                    $stream.Position = $start
                    $count = [int]($stream.Length - $start)
                    if ($count -gt 0) {
                        $bytes = New-Object byte[] $count
                        [void]$stream.Read($bytes, 0, $count)
                        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                        if ($text -match "ignoring events and commands") {
                            return $true
                        }
                    }
                }
                finally {
                    $stream.Dispose()
                }
            }
            catch {
            }
        }
        if ((Get-Date) -ge $deadline) {
            return $false
        }
        Start-Sleep -Milliseconds 300
    } while ($true)
}

function Stop-KomorebiForRebind {
    if (-not (Get-Process -Name komorebi -ErrorAction SilentlyContinue)) {
        return
    }
    $exe = Get-Komorebic
    & $exe stop | Out-Null
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Process -Name komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
    if (Get-Process -Name komorebi -ErrorAction SilentlyContinue) {
        Stop-Process -Name komorebi -Force -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Process -Name komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
    }
}

function Start-KomorebiForRebind {
    param([switch]$CleanState)
    $komorebic = Get-Komorebic
    $komorebi = Join-Path (Split-Path -Parent $komorebic) "komorebi.exe"
    $config = Join-Path $RepoRoot "config\komorebi.json"
    if (-not (Test-Path -LiteralPath $komorebi)) {
        [Console]::Error.WriteLine("komorebi.exe was not found next to komorebic.exe.")
        return $false
    }
    $launch = "--config `"$config`" --clean-state"
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $komorebi
    $start.Arguments = $launch
    $start.UseShellExecute = $false
    $start.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $start.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($start)
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Get-Process -Name komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
    return [bool](Get-Process -Name komorebi -ErrorAction SilentlyContinue)
}

function Set-BarInsetAndRetile {
    $exe = Get-Komorebic
    & $exe monitor-work-area-offset 0 0 34 0 34 | Out-Null
    & $exe monitor-work-area-offset 1 0 0 0 0 | Out-Null
    & $exe retile | Out-Null
}

function Invoke-TileScript {
    param([string[]]$Arguments = @())
    $script = Join-Path $PSScriptRoot "repair-tiles.py"
    if (-not (Test-Path -LiteralPath $script)) {
        return 1
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $stdout = & $py.Source -3 $script @Arguments
        $code = $LASTEXITCODE
        $stdout | Out-Host
        return $code
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $stdout = & $python.Source $script @Arguments
        $code = $LASTEXITCODE
        $stdout | Out-Host
        return $code
    }
    return 1
}

function Repair-ForeignDesktopTiles {
    $code = Invoke-TileScript
    if ($code -eq 0) {
        Save-DesktopLayout (Get-VirtualDesktopToken)
    }
    return $code
}

function Invoke-DesktopRefresh {
    $code = Invoke-TileScript @("refresh")
    if ($code -eq 0) {
        Save-DesktopLayout (Get-VirtualDesktopToken)
    }
    return $code
}

function Invoke-DesktopRebind {
    param([string]$LeavingId)
    if (Test-SystemOff) {
        Write-Output "System is off."
        return
    }
    Enter-OmarchyLock
    try {
        if (Test-SystemOff) {
            Write-Output "System is off."
            return
        }
        $leaving = $LeavingId
        if ([string]::IsNullOrWhiteSpace($leaving)) {
            $leaving = Get-VirtualDesktopToken
        }
        Save-DesktopLayout $leaving
        $seen = Get-VirtualDesktopToken
        for ($pass = 0; $pass -lt 2; $pass++) {
            Stop-KomorebiForRebind
            if (-not (Start-KomorebiForRebind)) {
                throw "Komorebi did not start."
            }
            $offset = Get-LogLength (Get-ActiveLogPath)
            Set-BarInsetAndRetile
            if (Test-LogIgnoresSince (Get-ActiveLogPath) $offset) {
                Stop-KomorebiForRebind
                if (-not (Start-KomorebiForRebind -CleanState)) {
                    throw "Komorebi did not start."
                }
                Set-BarInsetAndRetile
            }
            $now = Get-VirtualDesktopToken
            if ($now -eq $seen) {
                break
            }
            $seen = $now
        }
        Restore-DesktopLayout (Get-VirtualDesktopToken)
        Close-EmptyWorkspacesOnAllMonitors
        $null = Invoke-DesktopRefresh
        Write-Output "Rebound tiling to this desktop."
    }
    finally {
        Exit-OmarchyLock
    }
}

switch ($Command) {
    "state" {
        $exe = Get-Komorebic
        & $exe state
        exit $LASTEXITCODE
    }
    "layout" {
        $exe = Get-Komorebic
        switch ($Value.ToLowerInvariant()) {
            "bsp" {
                & $exe change-layout bsp
                exit $LASTEXITCODE
            }
            "scrolling" {
                & $exe change-layout scrolling
                exit $LASTEXITCODE
            }
            "cycle" {
                $current = Get-FocusedLayoutName -Exe $exe
                $next = "scrolling"
                if ($current -eq "Scrolling") {
                    $next = "bsp"
                }
                & $exe change-layout $next
                exit $LASTEXITCODE
            }
            default {
                Show-Usage
                exit 1
            }
        }
    }
    "workspace" {
        Invoke-WorkspaceFocus $Value
        exit 0
    }
    "workspace-move" {
        Invoke-WorkspaceMove $Value
        exit 0
    }
    "workspace-cycle" {
        Invoke-WorkspaceCycle $Value
        exit 0
    }
    "move" {
        $code = Invoke-TileScript @("move", $Value)
        exit $code
    }
    "desktop" {
        if ($Value -eq "rebind") {
            Invoke-DesktopRebind -LeavingId $Extra
            exit 0
        }
        if ($Value -eq "refresh") {
            if (Test-SystemOff) {
                exit 0
            }
            Enter-OmarchyLock
            try {
                $null = Invoke-DesktopRefresh
            }
            finally {
                Exit-OmarchyLock
            }
            exit 0
        }
        if ($Value -eq "repair") {
            if (Test-SystemOff) {
                exit 0
            }
            Enter-OmarchyLock
            try {
                $null = Repair-ForeignDesktopTiles
            }
            finally {
                Exit-OmarchyLock
            }
            exit 0
        }
        Show-Usage
        exit 1
    }
    "bar" {
        if ($Value -ne "toggle") {
            Show-Usage
            exit 1
        }
        Set-BarVisible
        exit 0
    }
    "system" {
        if ($Value -ne "toggle") {
            Show-Usage
            exit 1
        }
        Switch-System
    }
    default {
        Show-Usage
        exit 1
    }
}
