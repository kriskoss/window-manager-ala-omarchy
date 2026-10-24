"""Drop tiles held by windows that are on another Windows virtual desktop.

Komorebi keeps those windows in the tree, but Windows hides them, so their
tiles show the desktop. Windows that are actually on this desktop then
expand to fill the workspace. Komorebi's own cloak (other workspaces) is
left alone.
"""

import copy
import ctypes
import json
import os
import sys
import time
from ctypes import wintypes

SHELL_CLOAK = 2
SOCK = r"C:\Users\krzys\AppData\Local\komorebi\komorebi.sock"
SKIP_EXES = {
    "autohotkey64.exe",
    "explorer.exe",
    "flow.launcher.exe",
    "komorebi.exe",
    "omarchybar.exe",
    "screenclippinghost.exe",
    "screensketch.exe",
    "searchhost.exe",
    "shellexperiencehost.exe",
    "snippingtool.exe",
    "startmenuexperiencehost.exe",
    "textinputhost.exe",
    "wispr flow.exe",
}
SKIP_CLASSES = {
    "Progman",
    "Shell_TrayWnd",
    "WorkerW",
}

ws2 = ctypes.WinDLL("ws2_32", use_last_error=True)
user32 = ctypes.WinDLL("user32", use_last_error=True)
dwmapi = ctypes.WinDLL("dwmapi", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL
kernel32.QueryFullProcessImageNameW.argtypes = [
    wintypes.HANDLE,
    wintypes.DWORD,
    wintypes.LPWSTR,
    ctypes.POINTER(wintypes.DWORD),
]
kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL


class WSAData(ctypes.Structure):
    _fields_ = [
        ("wVersion", wintypes.WORD),
        ("wHighVersion", wintypes.WORD),
        ("szDescription", ctypes.c_char * 257),
        ("szSystemStatus", ctypes.c_char * 129),
        ("iMaxSockets", wintypes.WORD),
        ("iMaxUdpDg", wintypes.WORD),
        ("lpVendorInfo", ctypes.c_char_p),
    ]


def connect():
    data = WSAData()
    if ws2.WSAStartup(0x0202, ctypes.byref(data)) != 0:
        raise OSError("WSAStartup failed")
    sock = ws2.socket(1, 1, 0)
    if sock == ctypes.c_void_p(-1).value or sock < 0:
        raise OSError("socket failed")
    path = SOCK.encode("ascii") + b"\0"
    raw = bytes(ctypes.string_at((ctypes.c_ushort * 1)(1), 2)) + path
    buf = ctypes.create_string_buffer(raw)
    if ws2.connect(sock, buf, len(raw)) != 0:
        raise OSError("connect failed: %s" % ws2.WSAGetLastError())
    millis = ctypes.c_ulong(4000)
    # Give up if Komorebi accepts the socket and then never replies.
    ws2.setsockopt(sock, 0xFFFF, 0x1006, ctypes.byref(millis), ctypes.sizeof(millis))
    ws2.setsockopt(sock, 0xFFFF, 0x1005, ctypes.byref(millis), ctypes.sizeof(millis))
    return sock


def send_all(sock, payload):
    view = payload
    while view:
        n = ws2.send(sock, view, len(view), 0)
        if n <= 0:
            raise OSError("send failed: %s" % ws2.WSAGetLastError())
        view = view[n:]


def query(message):
    sock = connect()
    try:
        send_all(sock, message.encode("utf-8"))
        ws2.shutdown(sock, 1)
        chunks = []
        while True:
            part = ctypes.create_string_buffer(1 << 16)
            n = ws2.recv(sock, part, 1 << 16, 0)
            if n <= 0:
                break
            chunks.append(part.raw[:n])
    finally:
        ws2.closesocket(sock)
    return b"".join(chunks)


def send(message):
    sock = connect()
    try:
        send_all(sock, message.encode("utf-8"))
        ws2.shutdown(sock, 1)
    finally:
        ws2.closesocket(sock)


def on_this_desktop(window):
    hwnd = int(window["hwnd"])
    if not user32.IsWindow(hwnd):
        return False
    value = ctypes.c_int()
    hr = dwmapi.DwmGetWindowAttribute(hwnd, 14, ctypes.byref(value), 4)
    if hr == 0 and (value.value & SHELL_CLOAK):
        return False
    return True


def clamp(ring):
    count = len(ring.get("elements") or [])
    if count == 0:
        ring["focused"] = 0
    elif ring.get("focused", 0) >= count:
        ring["focused"] = count - 1


def filter_windows(ring):
    if not ring or "elements" not in ring:
        return 0
    kept = [item for item in ring["elements"] if on_this_desktop(item)]
    removed = len(ring["elements"]) - len(kept)
    ring["elements"] = kept
    clamp(ring)
    return removed


def repair(state):
    removed = 0
    for monitor in state["monitors"]["elements"]:
        for workspace in monitor["workspaces"]["elements"]:
            containers = workspace["containers"]
            kept = []
            for container in containers["elements"]:
                removed += filter_windows(container["windows"])
                if container["windows"]["elements"]:
                    kept.append(container)
                else:
                    removed += 1
            containers["elements"] = kept
            clamp(containers)
            removed += filter_windows(workspace.get("floating_windows"))
            monocle = workspace.get("monocle_container")
            if monocle:
                removed += filter_windows(monocle.get("windows"))
                if not monocle["windows"]["elements"]:
                    workspace["monocle_container"] = None
                    removed += 1
            maximized = workspace.get("maximized_window")
            if maximized and not on_this_desktop(maximized):
                workspace["maximized_window"] = None
                removed += 1
    return removed


def window_hwnds(state):
    found = set()
    for monitor in state.get("monitors", {}).get("elements") or []:
        for workspace in monitor.get("workspaces", {}).get("elements") or []:
            for container in workspace.get("containers", {}).get("elements") or []:
                for window in container.get("windows", {}).get("elements") or []:
                    found.add(int(window["hwnd"]))
            floating = workspace.get("floating_windows") or {}
            for window in floating.get("elements") or []:
                found.add(int(window["hwnd"]))
            monocle = workspace.get("monocle_container")
            if monocle:
                for window in monocle.get("windows", {}).get("elements") or []:
                    found.add(int(window["hwnd"]))
            maximized = workspace.get("maximized_window")
            if maximized:
                found.add(int(maximized["hwnd"]))
    return found


def keep_window(window, allowed):
    try:
        hwnd = int(window["hwnd"])
    except (KeyError, TypeError, ValueError):
        return False
    if hwnd not in allowed:
        return False
    return bool(user32.IsWindow(hwnd))


def filter_known(ring, allowed, used):
    if not ring or "elements" not in ring:
        return
    kept = []
    for window in ring["elements"]:
        if keep_window(window, allowed):
            kept.append(window)
            used.add(int(window["hwnd"]))
    ring["elements"] = kept
    clamp(ring)


def trim_saved(saved, allowed):
    used = set()
    for monitor in saved["monitors"]["elements"]:
        for workspace in monitor["workspaces"]["elements"]:
            kept = []
            for container in workspace["containers"]["elements"]:
                filter_known(container.get("windows"), allowed, used)
                if container.get("windows", {}).get("elements"):
                    kept.append(container)
            workspace["containers"]["elements"] = kept
            clamp(workspace["containers"])
            filter_known(workspace.get("floating_windows"), allowed, used)
            monocle = workspace.get("monocle_container")
            if monocle:
                before = len(used)
                filter_known(monocle.get("windows"), allowed, used)
                if not monocle.get("windows", {}).get("elements"):
                    workspace["monocle_container"] = None
                elif len(used) == before:
                    workspace["monocle_container"] = None
            maximized = workspace.get("maximized_window")
            if maximized:
                if keep_window(maximized, allowed):
                    used.add(int(maximized["hwnd"]))
                else:
                    workspace["maximized_window"] = None
    return used


def append_new_windows(saved, fresh, used):
    saved_monitors = saved["monitors"]["elements"]
    for index, monitor in enumerate(fresh["monitors"]["elements"]):
        if index >= len(saved_monitors):
            break
        workspaces = saved_monitors[index]["workspaces"]["elements"]
        if not workspaces:
            continue
        focus = saved_monitors[index]["workspaces"].get("focused") or 0
        if focus >= len(workspaces) or focus < 0:
            focus = 0
        target = workspaces[focus]
        for workspace in monitor["workspaces"]["elements"]:
            for container in workspace.get("containers", {}).get("elements") or []:
                windows = [
                    window
                    for window in container.get("windows", {}).get("elements") or []
                    if keep_window(window, {int(window["hwnd"])}) and int(window["hwnd"]) not in used
                ]
                if not windows:
                    continue
                added = copy.deepcopy(container)
                added["windows"]["elements"] = windows
                added["windows"]["focused"] = 0
                target["containers"]["elements"].append(added)
                for window in windows:
                    used.add(int(window["hwnd"]))
            for window in (workspace.get("floating_windows") or {}).get("elements") or []:
                hwnd = int(window["hwnd"])
                if hwnd in used or not keep_window(window, {hwnd}):
                    continue
                target["containers"]["elements"].append(
                    {
                        "id": "new-%s" % hwnd,
                        "locked": False,
                        "windows": {"elements": [copy.deepcopy(window)], "focused": 0},
                    }
                )
                used.add(hwnd)
        clamp(target["containers"])


def merge_layouts(saved, fresh):
    if len(saved.get("monitors", {}).get("elements") or []) != len(
        fresh.get("monitors", {}).get("elements") or []
    ):
        return None
    allowed = set()
    for hwnd in window_hwnds(fresh):
        if user32.IsWindow(hwnd):
            allowed.add(hwnd)
    if not allowed:
        return None
    merged = copy.deepcopy(saved)
    merged["virtual_desktop_id"] = copy.deepcopy(fresh.get("virtual_desktop_id"))
    merged["is_paused"] = fresh.get("is_paused", False)
    used = trim_saved(merged, allowed)
    append_new_windows(merged, fresh, used)
    return merged


def save_main(path):
    raw = query('{"type":"State"}')
    if not raw or b'"monitors"' not in raw:
        print("Komorebi did not answer.")
        return 1
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(raw.decode("utf-8"))
    print("Saved this desktop's tiles.")
    return 0


def restore_main(path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        saved = json.load(handle)
    raw = query('{"type":"State"}')
    if not raw or raw.strip() in (b"", b" "):
        print("Komorebi did not answer.")
        return 1
    fresh = json.loads(raw)
    merged = merge_layouts(saved, fresh)
    if merged is None:
        print("Kept the fresh layout.")
        return 2
    message = json.dumps(
        {"type": "ApplyState", "content": merged},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    send(message + "\n" + '{"type":"Retile"}\n')
    print("Restored this desktop's tiles.")
    return 0


def exe_name(hwnd):
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    handle = kernel32.OpenProcess(0x1000, False, pid.value)
    if not handle:
        return ""
    try:
        size = wintypes.DWORD(520)
        name = ctypes.create_unicode_buffer(520)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(size)):
            return ""
        return name.value.rsplit("\\", 1)[-1]
    finally:
        kernel32.CloseHandle(handle)


def focus_window(hwnd):
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
    user32.AttachThreadInput.restype = wintypes.BOOL
    user32.SwitchToThisWindow.argtypes = [wintypes.HWND, wintypes.BOOL]
    current = user32.GetForegroundWindow()
    current_thread = user32.GetWindowThreadProcessId(current, None)
    target_thread = user32.GetWindowThreadProcessId(hwnd, None)
    attached = False
    if current_thread and target_thread and current_thread != target_thread:
        attached = bool(user32.AttachThreadInput(current_thread, target_thread, True))
    user32.keybd_event(0x12, 0, 0, 0)
    try:
        user32.SwitchToThisWindow(hwnd, True)
        user32.SetForegroundWindow(hwnd)
        for _ in range(12):
            if int(user32.GetForegroundWindow()) == int(hwnd):
                return True
            time.sleep(0.03)
        return False
    finally:
        user32.keybd_event(0x12, 0, 2, 0)
        if attached:
            user32.AttachThreadInput(current_thread, target_thread, False)


def untiled_windows(known):
    found = []

    def visit(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd) or int(hwnd) in known:
            return True
        if user32.GetWindowTextLengthW(hwnd) == 0:
            return True
        cloak = ctypes.c_int()
        if dwmapi.DwmGetWindowAttribute(hwnd, 14, ctypes.byref(cloak), 4) == 0 and cloak.value != 0:
            return True
        class_name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, class_name, 256)
        if class_name.value in SKIP_CLASSES:
            return True
        exe = exe_name(hwnd).lower()
        if exe in SKIP_EXES:
            return True
        rect = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))
        if rect.right - rect.left < 200 or rect.bottom - rect.top < 200:
            return True
        found.append(int(hwnd))
        return True

    user32.EnumWindows(ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)(visit), 0)
    return found


def adopt_untiled(state):
    known = window_hwnds(state)
    pending = untiled_windows(known)
    if not pending:
        return 0
    previous = int(user32.GetForegroundWindow())
    adopted = 0
    try:
        for hwnd in pending:
            if not focus_window(hwnd):
                continue
            send(json.dumps({"type": "ManageFocusedWindow"}) + "\n")
            for _ in range(10):
                raw = query('{"type":"State"}')
                if not raw or b'"monitors"' not in raw:
                    return adopted
                if hwnd in window_hwnds(json.loads(raw)):
                    adopted += 1
                    break
                time.sleep(0.05)
    finally:
        if previous and user32.IsWindow(previous):
            focus_window(previous)
    if adopted:
        send('{"type":"Retile"}\n')
    return adopted


def focused_placement(state, hwnd):
    for monitor_index, monitor in enumerate(state.get("monitors", {}).get("elements") or []):
        workspace_index = monitor.get("workspaces", {}).get("focused", 0)
        workspaces = monitor.get("workspaces", {}).get("elements") or []
        if workspace_index >= len(workspaces):
            continue
        workspace = workspaces[workspace_index]
        for container_index, container in enumerate(
            (workspace.get("containers") or {}).get("elements") or []
        ):
            for window_index, window in enumerate(
                (container.get("windows") or {}).get("elements") or []
            ):
                if int(window.get("hwnd", 0)) == hwnd:
                    return (monitor_index, workspace_index, container_index, window_index)
    return None


def move_main(direction):
    names = {"left": "Left", "right": "Right", "up": "Up", "down": "Down"}
    content = names.get(direction.lower())
    if not content:
        print("Use left, right, up, or down.")
        return 2
    hwnd = int(user32.GetForegroundWindow())
    if not hwnd:
        print("No window is focused.")
        return 1
    send(json.dumps({"type": "ManageFocusedWindow"}) + "\n")
    before = None
    for _ in range(10):
        raw = query('{"type":"State"}')
        if not raw or b'"monitors"' not in raw:
            print("Komorebi did not answer.")
            return 1
        before = focused_placement(json.loads(raw), hwnd)
        if before is not None:
            break
        time.sleep(0.05)
    if before is None:
        print("That window is not tiled.")
        return 1
    send(json.dumps({"type": "MoveWindow", "content": content}) + "\n")
    time.sleep(0.05)
    raw = query('{"type":"State"}')
    if not raw or b'"monitors"' not in raw:
        print("Komorebi did not answer.")
        return 1
    after = focused_placement(json.loads(raw), hwnd)
    if after == before:
        send(json.dumps({"type": "CycleMoveContainerToMonitor", "content": "Next"}) + "\n")
        print("Moved the window to the next screen.")
        return 0
    print("Moved the tile.")
    return 0


def pass_once():
    raw = query('{"type":"State"}')
    if not raw or raw.strip() in (b"", b" ") or b'"monitors"' not in raw:
        return None
    state = json.loads(raw)
    removed = repair(state)
    if removed:
        message = json.dumps(
            {"type": "ApplyState", "content": state},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        send(message + "\n" + '{"type":"Retile"}\n')
        raw = query('{"type":"State"}')
        if raw and b'"monitors"' in raw:
            state = json.loads(raw)
    adopted = adopt_untiled(state)
    return removed, adopted


def report(removed, adopted):
    if removed == 0 and adopted == 0:
        print("Tiles already match this desktop.")
        return 0
    if removed:
        print("Closed %s empty tile(s) from other desktops." % removed)
    if adopted:
        print("Tiled %s window(s) that were outside the layout." % adopted)
    return 0


def main():
    result = pass_once()
    if result is None:
        print("Komorebi did not answer.")
        return 1
    return report(*result)


def refresh_main():
    removed_total = 0
    adopted_total = 0
    stable = 0
    previous = None
    started = time.time()
    while True:
        result = pass_once()
        if result is None:
            if removed_total or adopted_total:
                break
            print("Komorebi did not answer.")
            return 1
        removed, adopted = result
        removed_total += removed
        adopted_total += adopted
        raw = query('{"type":"State"}')
        if not raw or b'"monitors"' not in raw:
            break
        free = tuple(untiled_windows(window_hwnds(json.loads(raw))))
        if free == previous and removed == 0 and adopted == 0:
            stable += 1
        else:
            stable = 0
        previous = free
        if (stable >= 2 and not free) or time.time() - started > 2.4:
            break
        time.sleep(0.35)
    if removed_total or adopted_total:
        send('{"type":"Retile"}\n')
    return report(removed_total, adopted_total)


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "refresh":
            sys.exit(refresh_main())
        if len(sys.argv) > 1 and sys.argv[1] == "move":
            if len(sys.argv) < 3:
                print("Use left, right, up, or down.")
                sys.exit(2)
            sys.exit(move_main(sys.argv[2]))
        if len(sys.argv) > 1 and sys.argv[1] in ("restore", "save"):
            if len(sys.argv) < 3:
                print("Missing layout file.")
                sys.exit(2)
            if sys.argv[1] == "save":
                sys.exit(save_main(sys.argv[2]))
            sys.exit(restore_main(sys.argv[2]))
        sys.exit(main())
    except Exception as error:
        print(error)
        sys.exit(1)
