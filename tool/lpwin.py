#!/usr/bin/env python3
"""Win32 window, input and screen helpers, without PowerShell.

The screenshot and input scripts used to be PowerShell wrappers around a C#
``Add-Type`` block per file: every script re-declared the same six user32
imports, and the whole thing only ran under Windows PowerShell 5.1 with its
ANSI code page pitfalls.  This module is the same handful of calls through
``ctypes``, so the scripts are plain Python.

Nothing here is Flutter-specific: it finds windows by process id, moves the
cursor, clicks, posts keys, and grabs pixels.  The one thing that has to be
right is DPI: without declaring the process DPI-aware, GetWindowRect returns
virtualised coordinates while BitBlt/BitBlt work in physical pixels, and the
resulting screenshot is cropped at the wrong offset (that bug cost several
rounds of "the capture is black / empty / cut off").
"""
from __future__ import annotations

import ctypes
import os
import subprocess
import time
from ctypes import wintypes
from pathlib import Path

from lpimage import Image

__all__ = [
    "dpi_aware",
    "find_main_window",
    "find_view",
    "window_title",
    "window_rect",
    "client_rect",
    "client_origin",
    "raise_window",
    "move_cursor",
    "cursor_pos",
    "click",
    "wheel",
    "post_key",
    "screen_grab",
    "window_grab",
    "screens_size",
    "start_app",
    "stop_app",
    "find_process_by_name",
    "VK",
]

_user32 = ctypes.WinDLL("user32", use_last_error=True)
_gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

_DPI_AWARE_DONE = False


# ----------------------------------------------------------------------
# bookkeeping
# ----------------------------------------------------------------------
def dpi_aware() -> None:
    """Declare this process DPI-aware (idempotent).

    Per-monitor-v2 is what the Flutter runner itself uses; the older
    SetProcessDPIAware is the fallback for Windows before 1607.
    """
    global _DPI_AWARE_DONE
    if _DPI_AWARE_DONE:
        return
    try:  # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == -4
        _user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except AttributeError:
        pass
    _user32.SetProcessDPIAware()
    _DPI_AWARE_DONE = True


class RECT(ctypes.Structure):
    _fields_ = [("left", wintypes.LONG), ("top", wintypes.LONG),
                ("right", wintypes.LONG), ("bottom", wintypes.LONG)]


class POINT(ctypes.Structure):
    _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]


class GUITHREADINFO(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("hwndActive", wintypes.HWND),
        ("hwndFocus", wintypes.HWND),
        ("hwndCapture", wintypes.HWND),
        ("hwndMenuOwner", wintypes.HWND),
        ("hwndMoveSize", wintypes.HWND),
        ("hwndCaret", wintypes.HWND),
        ("rcCaret", RECT),
    ]


_ENUM_PROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
_user32.EnumWindows.argtypes = [_ENUM_PROC, wintypes.LPARAM]
_user32.EnumChildWindows.argtypes = [wintypes.HWND, _ENUM_PROC, wintypes.LPARAM]
_user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
_user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
_user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(POINT)]
_user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
_user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
_user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]


# ----------------------------------------------------------------------
# windows
# ----------------------------------------------------------------------
def _enum_windows(proc: _ENUM_PROC, parent: int | None = None) -> None:
    if parent is None:
        _user32.EnumWindows(proc, 0)
    else:
        _user32.EnumChildWindows(parent, proc, 0)


def window_title(hwnd: int) -> str:
    length = _user32.GetWindowTextLengthW(hwnd)
    if length <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(length + 1)
    _user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def find_main_window(pid: int, min_size: int = 200, require_title: bool = True) -> int:
    """The visible top-level window owned by ``pid``, or 0.

    Small helper windows (tooltips, the hidden message-only window Flutter
    creates) have to be filtered out by size and, usually, by having a title.
    """
    found = []

    def callback(hwnd, _lparam):
        owner = wintypes.DWORD()
        _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value != pid:
            return True
        if not _user32.IsWindowVisible(hwnd):
            return True
        if require_title and _user32.GetWindowTextLengthW(hwnd) == 0:
            return True
        rect = RECT()
        if not _user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            return True
        if rect.right - rect.left <= min_size or rect.bottom - rect.top <= min_size:
            return True
        found.append(hwnd)
        return False

    _enum_windows(_ENUM_PROC(callback))
    return found[0] if found else 0


def find_view(frame: int) -> int:
    """Flutter's message handler lives in a child window; fall back to frame."""
    found = []

    def callback(hwnd, _lparam):
        if _user32.IsWindowVisible(hwnd):
            found.append(hwnd)
            return False
        return True

    _enum_windows(_ENUM_PROC(callback), parent=frame)
    return found[0] if found else frame


def window_rect(hwnd: int) -> tuple[int, int, int, int]:
    rect = RECT()
    if not _user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        raise OSError("GetWindowRect failed")
    return rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top


def client_rect(hwnd: int) -> tuple[int, int]:
    rect = RECT()
    if not _user32.GetClientRect(hwnd, ctypes.byref(rect)):
        raise OSError("GetClientRect failed")
    return rect.right - rect.left, rect.bottom - rect.top


def client_origin(hwnd: int) -> tuple[int, int]:
    point = POINT(0, 0)
    if not _user32.ClientToScreen(hwnd, ctypes.byref(point)):
        raise OSError("ClientToScreen failed")
    return point.x, point.y


def raise_window(hwnd: int, settle: float = 0.7) -> None:
    """Bring a window to the front, several ways.

    SetForegroundWindow is only a request the shell may refuse, and a refused
    request means the *desktop* is what a screen copy captures -- which is how
    an all-white "proof" screenshot happened twice.  So ask three times.
    """
    SW_RESTORE = 9
    HWND_TOPMOST = -1
    SWP_NOSIZE, SWP_NOMOVE = 0x0001, 0x0002
    _user32.ShowWindow(hwnd, SW_RESTORE)
    _user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE)
    _user32.BringWindowToTop(hwnd)
    _user32.SetForegroundWindow(hwnd)
    try:
        _user32.SwitchToThisWindow(hwnd, True)
    except AttributeError:
        pass
    time.sleep(settle)


def resize_window(hwnd: int, width: int, height: int, settle: float = 0.9) -> None:
    """Resize without touching the z-order (SWP_NOZORDER) so a raise survives."""
    _user32.SetWindowPos(hwnd, 0, 10, 10, width, height, 0x0004)
    time.sleep(settle)


def find_process_by_name(name: str) -> list[int]:
    """Process ids whose image name matches (without .exe)."""
    out = subprocess.run(
        ["tasklist", "/FI", f"IMAGENAME eq {name}.exe", "/NH", "/FO", "CSV"],
        capture_output=True, text=True, check=False,
    ).stdout
    pids: list[int] = []
    for line in out.splitlines():
        parts = [p.strip('"') for p in line.split('","')]
        if len(parts) >= 2 and parts[0].lower() == f"{name.lower()}.exe":
            try:
                pids.append(int(parts[1]))
            except ValueError:
                continue
    return pids


# ----------------------------------------------------------------------
# input
# ----------------------------------------------------------------------
def move_cursor(x: int, y: int) -> None:
    _user32.SetCursorPos(int(x), int(y))


def cursor_pos() -> tuple[int, int]:
    point = POINT()
    _user32.GetCursorPos(ctypes.byref(point))
    return point.x, point.y


def nudge(x: int, y: int) -> None:
    """Move the pointer to a point and back, so the engine sees a real move.

    Setting the cursor to the position it already occupies produces no
    WM_MOUSEMOVE at all, which is why a single SetCursorPos leaves Flutter's
    transport bar hidden.
    """
    move_cursor(x + 1, y + 1)
    time.sleep(0.06)
    move_cursor(x, y)


def click(x: int, y: int, double: bool = False) -> None:
    MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004
    move_cursor(x, y)
    time.sleep(0.12)
    nudge(x, y)
    time.sleep(0.12)
    rounds = 2 if double else 1
    for i in range(rounds):
        _user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
        time.sleep(0.06)
        _user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
        if i < rounds - 1:
            time.sleep(0.12)


def press_and_hold(x: int, y: int, hold: float = 0.9) -> None:
    """按住在 (x, y) 不放 `hold` 秒，触发 Flutter 的 long-press。

    `click()` 只按下 60ms，够不到 500ms 的长按阈值，所以「长按打开面板」
    这类入口没法用它验证。
    """
    MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004
    move_cursor(x, y)
    time.sleep(0.12)
    nudge(x, y)
    time.sleep(0.12)
    _user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
    time.sleep(hold)
    _user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    time.sleep(0.1)


def wheel(notches: int, x: int, y: int) -> None:
    """滚轮：正数往上、负数往下，一格 = 120（WHEEL_DELTA）。

    `mouse_event` 的 dwData 是有符号的 16 位增量，往下滚要传 -120，也就是
    0xFFFFFF88。这里原来写的是 0xFFFFFB90（= -1136，约等于向上九格半），
    往下滚一格会被应用成「向下九格」，测试里就表现为音量一下掉到底。
    """
    MOUSEEVENTF_WHEEL = 0x0800
    move_cursor(x, y)
    time.sleep(0.1)
    for _ in range(abs(notches)):
        delta = 0xFFFFFF88 if notches < 0 else 0x78  # -120 / +120 per notch
        _user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, delta, 0)
        time.sleep(0.12)


VK = {
    "Space": 0x20, "Left": 0x25, "Up": 0x26, "Right": 0x27, "Down": 0x28,
    "Escape": 0x1B, "F": 0x46, "M": 0x4D, "K": 0x4B, "S": 0x53, "D": 0x44,
    # 浏览器/列表页的「退一层」用得到；补在这里，验证脚本才有键可按。
    "Backspace": 0x08, "Enter": 0x0D, "Tab": 0x09,
}

_WM_KEYDOWN, _WM_KEYUP = 0x0100, 0x0101
_WM_SYSKEYDOWN, _WM_SYSKEYUP = 0x0104, 0x0105


def focus_window(frame: int) -> int:
    """Whatever the window's thread considers focused, else the frame.

    Keys must be posted to the focused child (the Flutter view); posting to the
    top-level frame produces no shortcut handling at all.
    """
    pid = wintypes.DWORD()
    tid = _user32.GetWindowThreadProcessId(frame, ctypes.byref(pid))
    info = GUITHREADINFO()
    info.cbSize = ctypes.sizeof(GUITHREADINFO)
    if _user32.GetGUIThreadInfo(tid, ctypes.byref(info)) and info.hwndFocus:
        return info.hwndFocus
    return frame


def post_key(hwnd: int, name: str) -> None:
    """Post one key down/up pair.  'F' is an Alt combo, the rest are plain.

    lParam 的 bit 16..23 是 **scancode**，Flutter 的 Windows embedder 就是靠
    它认键（`(lparam >> 16) & 0xFF`）。早先这里固定传 0x00000001，scancode
    恒为 0，于是 PostMessage 出去的消息在引擎那边匹配不到任何 KeyboardKey，
    按键等于没按 —— 只有真正走一遍键盘路径才会暴露。
    scancode 用 MapVirtualKeyW 从 VK 反查，不必手写一张表。
    """
    if name not in VK:
        raise ValueError(f"unknown key {name!r}")
    vk = VK[name]
    alt = name == "F"
    down = _WM_SYSKEYDOWN if alt else _WM_KEYDOWN
    up = _WM_SYSKEYUP if alt else _WM_KEYUP
    scan = _user32.MapVirtualKeyW(vk, 0) & 0xFF   # MAPVK_VK_TO_VSC
    # 按下：repeat=1，scancode 就位；抬起：再加上 30/31 位（前一状态 + 转换态）。
    _user32.PostMessageW(hwnd, down, vk, 0x00000001 | (scan << 16))
    time.sleep(0.05)
    _user32.PostMessageW(hwnd, up, vk, 0xC0000001 | (scan << 16))


# ----------------------------------------------------------------------
# pixels
# ----------------------------------------------------------------------
class _BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
        ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]


class _BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", _BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 3)]


def _dib_to_image(hdc: int, hbitmap: int, width: int, height: int) -> Image:
    """Copy a GDI bitmap into RGB24."""
    info = _BITMAPINFO()
    header = info.bmiHeader
    header.biSize = ctypes.sizeof(_BITMAPINFOHEADER)
    header.biWidth = width
    header.biHeight = -height  # negative: top-down rows, which is what we want
    header.biPlanes = 1
    header.biBitCount = 32
    header.biCompression = 0  # BI_RGB
    buf = ctypes.create_string_buffer(width * height * 4)
    got = _gdi32.GetDIBits(hdc, hbitmap, 0, height, buf, ctypes.byref(info), 0)
    if got != height:
        raise OSError(f"GetDIBits returned {got} of {height} rows")
    raw = buf.raw
    out = bytearray(width * height * 3)
    for i in range(width * height):
        b, g, r = raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2]
        out[i * 3] = r
        out[i * 3 + 1] = g
        out[i * 3 + 2] = b
    return Image(width, height, out)


def _grab(function) -> Image:
    """Run a BitBlt-style GDI copy and decode it."""
    return function()


def screen_grab() -> Image:
    """Copy the whole primary screen.

    A window-rect copy can miss the client area entirely on a scaled display,
    where the Flutter view is composited at a different offset than
    GetWindowRect reports.  Whole-screen plus a crop always contains it.
    """
    dpi_aware()
    screen = _user32.GetDC(0)
    memdc = _gdi32.CreateCompatibleDC(screen)
    width = _user32.GetSystemMetrics(0)
    height = _user32.GetSystemMetrics(1)
    bitmap = _gdi32.CreateCompatibleBitmap(screen, width, height)
    _gdi32.SelectObject(memdc, bitmap)
    try:
        if not _gdi32.BitBlt(memdc, 0, 0, width, height, screen, 0, 0, 0x00CC0020):
            raise OSError("BitBlt failed")
        return _dib_to_image(memdc, bitmap, width, height)
    finally:
        _gdi32.DeleteObject(bitmap)
        _gdi32.DeleteDC(memdc)
        _user32.ReleaseDC(0, screen)


def window_grab(hwnd: int) -> Image:
    """PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT).

    Fast, works while the window is behind another one -- but Flutter windows
    that are not in the foreground come out with a black client area, because
    ANGLE/D3D swaps are not replayed.  Use it for "did a window appear at the
    expected size", not for "what does the UI look like".
    """
    dpi_aware()
    left, top, width, height = window_rect(hwnd)
    if width <= 0 or height <= 0:
        raise OSError("window has no area")
    screen = _user32.GetDC(hwnd)
    memdc = _gdi32.CreateCompatibleDC(screen)
    bitmap = _gdi32.CreateCompatibleBitmap(screen, width, height)
    _gdi32.SelectObject(memdc, bitmap)
    try:
        if not _user32.PrintWindow(hwnd, memdc, 2):
            raise OSError("PrintWindow failed")
        return _dib_to_image(memdc, bitmap, width, height)
    finally:
        _gdi32.DeleteObject(bitmap)
        _gdi32.DeleteDC(memdc)
        _user32.ReleaseDC(hwnd, screen)


# ----------------------------------------------------------------------
# child processes
# ----------------------------------------------------------------------
def start_app(exe: str | Path, env: dict[str, str] | None = None,
              stdout=None, stderr=None, stdin=None, cwd: str | Path | None = None
              ) -> subprocess.Popen:
    """Launch the runner with the given environment and redirects."""
    exe = Path(exe)
    return subprocess.Popen(
        [str(exe)],
        cwd=str(cwd or exe.parent),
        env=env,
        stdout=stdout,
        stderr=stderr,
        stdin=stdin,
    )


def stop_app(proc, grace: float = 1.0) -> None:
    from lpscript import kill_tree

    kill_tree(proc, grace=grace)


def wait_for_window(pid: int, timeout: float = 15.0, min_size: int = 200,
                    require_title: bool = True) -> int:
    """Poll for the app's main window; 0 when it never appears."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        hwnd = find_main_window(pid, min_size=min_size, require_title=require_title)
        if hwnd:
            return hwnd
        time.sleep(0.25)
    return 0


def app_env(base: dict[str, str] | None = None, *, state_dir: str | Path | None = None,
            open_media: str | None = None, browse: str | None = None,
            user: str | None = None, password: str | None = None,
            ui: str | None = None, autoscan: bool = False) -> dict[str, str]:
    """Environment for the runner's ``LANPLAYER_*`` test hooks.

    These are the same hooks the app reads in main.dart; a hook that is not
    requested is removed rather than set to an empty string, because the app
    checks for presence and an empty LANPLAYER_OPEN still counts.
    """
    env = dict(base if base is not None else os.environ)
    for key in ("LANPLAYER_STATE_DIR", "LANPLAYER_OPEN", "LANPLAYER_BROWSE",
                "LANPLAYER_USER", "LANPLAYER_PASS", "LANPLAYER_UI",
                "LANPLAYER_AUTOSCAN"):
        env.pop(key, None)
    if state_dir is not None:
        env["LANPLAYER_STATE_DIR"] = str(Path(state_dir).resolve())
    if open_media:
        env["LANPLAYER_OPEN"] = str(open_media)
    if browse:
        env["LANPLAYER_BROWSE"] = str(browse)
    if user:
        env["LANPLAYER_USER"] = user
    if password:
        env["LANPLAYER_PASS"] = password
    if ui:
        env["LANPLAYER_UI"] = ui
    if autoscan:
        env["LANPLAYER_AUTOSCAN"] = "1"
    return env
