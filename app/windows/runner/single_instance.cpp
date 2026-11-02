#include "single_instance.h"

#include <windows.h>

#include <cstdint>
#include <string>

namespace {

// 与 win32_window.cpp 里 kWindowClassName 同一个值。这里不 include 那个文件
// 是因为它把类名放在匿名 namespace 里，本来也拿不到。
//
// 注意：这个类名不是本程序专属的。任何用 Flutter 默认 Windows runner 模板
// 的程序（实测：企业微信的 FlutterPlugins.exe）都用同一个类名，所以下面找
// 窗口时必须再按「窗口所属进程的可执行文件路径」过滤一遍，否则会把别人的
// 隐藏窗口当成自己的提到前台。
constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// mutex 名的主体；后面拼上可执行文件路径的哈希，见 MutexName()。
constexpr const wchar_t kMutexPrefix[] = L"Local\\LanPlayer-2f0f8c4e-5a1d-4bb2-9a63-";

// 进程 pid 的可执行文件是否就是本进程的可执行文件（大小写不敏感）。
bool SameExecutable(DWORD pid) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return false;
  }
  wchar_t theirs[MAX_PATH];
  wchar_t ours[MAX_PATH];
  DWORD theirs_size = MAX_PATH;
  DWORD ours_size = MAX_PATH;
  bool same = false;
  if (::QueryFullProcessImageNameW(process, 0, theirs, &theirs_size) &&
      ::QueryFullProcessImageNameW(::GetCurrentProcess(), 0, ours, &ours_size)) {
    same = ::_wcsicmp(theirs, ours) == 0;
  }
  ::CloseHandle(process);
  return same;
}

struct FindState {
  HWND visible = nullptr;
  HWND hidden = nullptr;
};

// 遍历顶层窗口，只认「类名相同 + 同一个可执行文件」的那个；有可见窗口优先。
BOOL CALLBACK CollectWindow(HWND window, LPARAM param) {
  FindState* state = reinterpret_cast<FindState*>(param);
  wchar_t name[64];
  if (::GetClassNameW(window, name, 64) == 0) {
    return TRUE;
  }
  if (::wcscmp(name, kWindowClassName) != 0) {
    return TRUE;
  }
  DWORD pid = 0;
  ::GetWindowThreadProcessId(window, &pid);
  if (pid == 0 || !SameExecutable(pid)) {
    return TRUE;
  }
  if (::IsWindowVisible(window)) {
    if (state->visible == nullptr) {
      state->visible = window;
    }
    return FALSE;  // 找到可见的那个就可以停了
  }
  if (state->hidden == nullptr) {
    state->hidden = window;
  }
  return TRUE;
}

HWND FindExistingWindow() {
  FindState state;
  ::EnumWindows(&CollectWindow, reinterpret_cast<LPARAM>(&state));
  return state.visible != nullptr ? state.visible : state.hidden;
}

// 命名对象带可执行文件路径的哈希：同一个程序连点两次图标是单实例，但把
// 两个不同目录里的 lanplayer.exe 同时打开仍然是两个独立程序（各自找自己的
// 窗口），安装版与绿色版并存时不会互相把对方踢掉。
std::wstring MutexName() {
  wchar_t path[MAX_PATH];
  DWORD size = MAX_PATH;
  std::wstring name(kMutexPrefix);
  if (!::QueryFullProcessImageNameW(::GetCurrentProcess(), 0, path, &size)) {
    return name + L"default";
  }
  std::wstring lower(path);
  ::CharLowerBuffW(lower.data(), static_cast<DWORD>(lower.size()));
  uint32_t hash = 2166136261u;  // FNV-1a
  for (wchar_t ch : lower) {
    hash ^= static_cast<uint32_t>(ch);
    hash *= 16777619u;
  }
  wchar_t suffix[16];
  ::swprintf_s(suffix, L"-%08x", hash);
  return name + suffix;
}

// 找到已运行实例的窗口就还原并置前。找不到返回 false。
bool RaiseExistingWindow() {
  HWND window = FindExistingWindow();
  if (window == nullptr) {
    return false;
  }
  // 最小化时必须先还原，否则 SetForegroundWindow 对一个最小化的窗口只是闪一下
  // 任务栏，窗口仍然留在下面。
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  // 窗口可能在别的虚拟桌面或已经被隐藏。
  ::ShowWindow(window, SW_SHOW);
  // 前台窗口的拥有者才有资格把别的窗口拎到前台；直接 SetForegroundWindow
  // 会只闪任务栏。先试一次标准做法，不行再用附加输入队列的老办法。
  if (!::SetForegroundWindow(window)) {
    const DWORD foreground_thread =
        ::GetWindowThreadProcessId(::GetForegroundWindow(), nullptr);
    const DWORD target_thread = ::GetWindowThreadProcessId(window, nullptr);
    if (foreground_thread != 0 && target_thread != 0 &&
        foreground_thread != target_thread &&
        ::AttachThreadInput(foreground_thread, target_thread, TRUE)) {
      ::SetForegroundWindow(window);
      ::AttachThreadInput(foreground_thread, target_thread, FALSE);
    }
  }
  ::BringWindowToTop(window);
  ::SetActiveWindow(window);
  return true;
}

}  // namespace

bool ActivateRunningInstance() {
  // 第一次启动时 create_new 为 true，这里就把 mutex 永久地攥在手里 ——
  // 进程退出时系统自动释放，不需要显式 CloseHandle。
  ::CreateMutexW(nullptr, TRUE, MutexName().c_str());
  // CreateMutex 在 mutex 已存在时返回的也是有效句柄（只是 get_last_error
  // 报 ERROR_ALREADY_EXISTS），所以判据只能看 last error。
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }
  // 抢在前一个实例正在启动的窗口还没建好之前点图标，FindExistingWindow 会
  // 空手。这种情况下也让新进程退出，免得出现两个窗口；用户再点一次就好。
  RaiseExistingWindow();
  return true;
}
