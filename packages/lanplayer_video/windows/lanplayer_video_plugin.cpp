/*
 * Windows plugin: feeds the LanPlayer FFmpeg core into a Flutter texture.
 *
 * Design notes:
 *   - liblanplayer.dll is loaded at runtime (LoadLibrary + GetProcAddress), so
 *     this plugin has no import library and works with whatever core the app
 *     ships next to its .exe (or points at with LANPLAYER_CORE).
 *   - Frames arrive on the core's video thread; the callback only marks the
 *     texture dirty (MarkTextureFrameAvailable is documented as thread-safe),
 *     the actual pixel copy happens on the raster thread inside CopyPixelBuffer.
 *   - The core renders BGRA (the order GDI's StretchDIBits wants) but
 *     FlutterDesktopPixelBuffer has no format field and the engine always reads
 *     it as RGBA8888, so every frame is swizzled B<->R here. Skipping this is
 *     what makes the picture look severely blue: red and blue are swapped.
 *   - Two pixel buffers with release callbacks implement the "don't overwrite
 *     a buffer the engine is still reading" contract; if both are busy the
 *     frame is dropped rather than blocking the decoder.
 */
#include "include/lanplayer_video/lan_player_video_plugin.h"
#include "include/lanplayer_video/pixel_swizzle.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_view.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <windows.h>
#include <shlobj.h>  /* SHGetKnownFolderPath, SHCreateDirectoryEx */
#include <shobjidl.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "lanplayer/video";

// ---------------------------------------------------------------- core API ---

using FnAbi = int (*)();
using FnCreate = int (*)(void**);
using FnDestroy = void (*)(void*);
using FnSetEventCb = void (*)(void*, void*, void*);
using FnOpen = int (*)(void*, const char*, const char*);
using FnPlay = int (*)(void*);
using FnPause = int (*)(void*);
using FnClose = int (*)(void*);
using FnSeek = int (*)(void*, int64_t);
using FnSetVolume = int (*)(void*, float);
using FnSelectTrack = int (*)(void*, int32_t, int32_t);
using FnAddSubtitle = int (*)(void*, const char*, const char*);
using FnSubtitleDelay = int (*)(void*, int64_t);
using FnInstallFrameCb = int (*)(void*, void (*)(void*), void*);
using FnCopyFrame = int (*)(uint8_t*, size_t, int*, int*, int*);
using FnFrameSize = int (*)(int*, int*, int*);
using FnFrameSerial = int64_t (*)();

struct CoreApi {
  HMODULE module = nullptr;
  FnAbi abi = nullptr;
  FnCreate create = nullptr;
  FnDestroy destroy = nullptr;
  FnSetEventCb set_event_cb = nullptr;
  FnOpen open = nullptr;
  FnPlay play = nullptr;
  FnPause pause = nullptr;
  FnClose close = nullptr;
  FnSeek seek = nullptr;
  FnSetVolume set_volume = nullptr;
  FnSelectTrack select_track = nullptr;
  FnAddSubtitle add_subtitle = nullptr;
  FnSubtitleDelay subtitle_delay = nullptr;
  FnInstallFrameCb install_frame_cb = nullptr;
  FnCopyFrame copy_frame = nullptr;
  FnFrameSize frame_size = nullptr;
  FnFrameSerial frame_serial = nullptr;

  bool Load(std::string* error) {
    if (module) {
      return true;
    }
    std::vector<std::wstring> candidates;
    wchar_t env[4096] = {0};
    DWORD env_len = GetEnvironmentVariableW(L"LANPLAYER_CORE", env, 4096);
    if (env_len > 0 && env_len < 4096) {
      candidates.emplace_back(env);
    }
    wchar_t exe[MAX_PATH] = {0};
    if (GetModuleFileNameW(nullptr, exe, MAX_PATH)) {
      std::wstring path(exe);
      size_t slash = path.find_last_of(L"\\/");
      if (slash != std::wstring::npos) {
        candidates.push_back(path.substr(0, slash + 1) + L"lanplayer.dll");
      }
    }
    candidates.emplace_back(L"lanplayer.dll");

    for (const auto& candidate : candidates) {
      // Let the core resolve its own FFmpeg DLLs from the same directory.
      size_t slash = candidate.find_last_of(L"\\/");
      if (slash != std::wstring::npos && slash > 2) {
        SetDllDirectoryW(candidate.substr(0, slash).c_str());
      }
      module = LoadLibraryW(candidate.c_str());
      if (module) {
        break;
      }
    }
    if (!module) {
      if (error) {
        *error = "lanplayer.dll not found (put it next to the app, or set the "
                 "LANPLAYER_CORE environment variable)";
      }
      return false;
    }
    auto get = [this](const char* name) { return GetProcAddress(module, name); };
    abi = reinterpret_cast<FnAbi>(get("lp_abi_version"));
    create = reinterpret_cast<FnCreate>(get("lp_player_create"));
    destroy = reinterpret_cast<FnDestroy>(get("lp_player_destroy"));
    set_event_cb = reinterpret_cast<FnSetEventCb>(get("lp_player_set_event_callback"));
    open = reinterpret_cast<FnOpen>(get("lp_player_open"));
    play = reinterpret_cast<FnPlay>(get("lp_player_play"));
    pause = reinterpret_cast<FnPause>(get("lp_player_pause"));
    close = reinterpret_cast<FnClose>(get("lp_player_close"));
    seek = reinterpret_cast<FnSeek>(get("lp_player_seek"));
    set_volume = reinterpret_cast<FnSetVolume>(get("lp_player_set_volume"));
    select_track = reinterpret_cast<FnSelectTrack>(get("lp_player_select_track"));
    add_subtitle = reinterpret_cast<FnAddSubtitle>(get("lp_player_add_subtitle"));
    subtitle_delay = reinterpret_cast<FnSubtitleDelay>(get("lp_player_set_subtitle_delay"));
    install_frame_cb =
        reinterpret_cast<FnInstallFrameCb>(get("lp_player_install_frame_callback"));
    copy_frame = reinterpret_cast<FnCopyFrame>(get("lp_win32_copy_frame"));
    frame_size = reinterpret_cast<FnFrameSize>(get("lp_win32_frame_size"));
    frame_serial = reinterpret_cast<FnFrameSerial>(get("lp_win32_frame_serial"));
    if (!abi || !create || !destroy || !open || !play || !copy_frame || !frame_size ||
        !install_frame_cb) {
      if (error) {
        *error = "lanplayer.dll is missing required exports (rebuild the core)";
      }
      FreeLibrary(module);
      module = nullptr;
      return false;
    }
    if (abi() != 1) {
      if (error) {
        *error = "lanplayer.dll ABI mismatch (expected 1)";
      }
      FreeLibrary(module);
      module = nullptr;
      return false;
    }
    return true;
  }
};

// --------------------------------------------------------------- texture ---

class VideoTexture {
 public:
  explicit VideoTexture(CoreApi* core) : core_(core) {}

  // Called on the raster thread.
  const FlutterDesktopPixelBuffer* Copy(size_t /*width*/, size_t /*height*/) {
    int w = 0, h = 0, stride = 0;
    if (!core_ || !core_->frame_size || !core_->frame_size(&w, &h, &stride) || w <= 0 || h <= 0) {
      return nullptr;
    }
    const size_t need = static_cast<size_t>(stride) * static_cast<size_t>(h);
    for (size_t i = 0; i < kSlots; ++i) {
      if (!slots_[i].busy.exchange(true)) {
        if (slots_[i].data.size() < need) {
          slots_[i].data.resize(need);
        }
        if (!core_->copy_frame(slots_[i].data.data(), slots_[i].data.size(), &w, &h, &stride)) {
          slots_[i].busy.store(false);
          return nullptr;
        }
        SwizzleToRgba(slots_[i].data.data(), w, h, stride);
        buffers_[i].buffer = slots_[i].data.data();
        buffers_[i].width = static_cast<size_t>(w);
        buffers_[i].height = static_cast<size_t>(h);
        buffers_[i].release_callback = &VideoTexture::Release;
        buffers_[i].release_context = &slots_[i];
        ++frames_taken_;
        return &buffers_[i];
      }
    }
    // Both buffers still held by the engine: drop this frame, but do not let a
    // missed release stall the pipeline forever.
    ++frames_dropped_;
    if (++drops_ > 30) {
      drops_ = 0;
      for (size_t i = 0; i < kSlots; ++i) {
        slots_[i].busy.store(false);
      }
    }
    return nullptr;
  }

  // 诊断计数：内核交来多少帧、真正上屏多少帧、因为两个缓冲都被引擎占着而
  // 丢掉多少帧。真机上「画面卡但声音正常」时，这三个数字能立刻分开
  // 「内核没出帧」和「Flutter 侧来不及取」。
  unsigned long long frames_taken() const { return frames_taken_; }
  unsigned long long frames_dropped() const { return frames_dropped_; }

 private:
  static constexpr size_t kSlots = 2;

  struct Slot {
    std::vector<uint8_t> data;
    std::atomic<bool> busy{false};
  };

  static void Release(void* context) {
    static_cast<Slot*>(context)->busy.store(false);
  }

  // The engine reads pixel-buffer textures as RGBA8888; the core hands us BGRA.
  // The conversion (and why it is the fix for the blue-cast picture) lives in
  // pixel_swizzle.h so the standalone test can exercise the same code.
  static void SwizzleToRgba(uint8_t* data, int width, int height, int stride) {
    lp_bgra_to_rgba(data, width, height, stride);
  }

  CoreApi* core_ = nullptr;
  Slot slots_[kSlots];
  FlutterDesktopPixelBuffer buffers_[kSlots] = {};
  int drops_ = 0;
  unsigned long long frames_taken_ = 0;
  unsigned long long frames_dropped_ = 0;
};

// ---------------------------------------------------------------- plugin ---

class LanPlayerVideoPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    registrar->AddPlugin(std::make_unique<LanPlayerVideoPlugin>(registrar));
  }

  explicit LanPlayerVideoPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {
    // 默认关，只在排查「画面卡」时打开，免得平时往控制台刷无关的行。
    // 用 Win32 读而不是 getenv：MSVC 把 getenv 标成不安全并在 /WX 下报错。
    texture_stats_ = GetEnvironmentVariableA("LANPLAYER_TEXTURE_STATS", nullptr, 0) > 0;
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), kChannelName, &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
          HandleCall(call, std::move(result));
        });

    /*
     * path_provider has no Windows implementation built into this app: in the
     * CMake build `flutter pub get` wires up path_provider_windows (a Dart
     * implementation shipped as a plugin), but the offline cl/link build has no
     * plugin registration for it.  Without it every persistence call throws
     * MissingPluginException and saved servers (and settings) vanish on restart,
     * so the same channel is answered here.
     */
    const char* kPathProviderChannel = "plugins.flutter.io/path_provider";
    fallback_channels_.push_back(
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kPathProviderChannel,
            &flutter::StandardMethodCodec::GetInstance()));
    fallback_channels_.back()->SetMethodCallHandler(
        [](const flutter::MethodCall<flutter::EncodableValue>& call,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
          std::string path = KnownFolderPath(call.method_name());
          if (path.empty()) {
            result->Error("unavailable", "cannot resolve " + call.method_name());
          } else {
            result->Success(flutter::EncodableValue(path));
          }
        });
  }

  ~LanPlayerVideoPlugin() override {
    DestroyTexture();
    if (core_.module) {
      FreeLibrary(core_.module);
      core_.module = nullptr;
    }
  }

 private:
  /*
   * Resolves a Windows known folder for path_provider.  RoamingAppData is the
   * application support directory Flutter uses on Windows, and the app folder
   * is derived from the executable's version resource (company\product) the
   * same way path_provider_windows does it.
   */
  static std::string KnownFolderPath(const std::string& method) {
    PWSTR raw = nullptr;
    GUID id;
    if (method == "getApplicationSupportDirectory") {
      // FOLDERID_RoamingAppData
      id = {0x3EB685DB, 0x65F9, 0x4CF6, {0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D}};
    } else if (method == "getApplicationDocumentsDirectory") {
      // FOLDERID_Documents
      id = {0xFDD39AD0, 0x238F, 0x46AF, {0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7}};
    } else if (method == "getApplicationCacheDirectory") {
      // FOLDERID_LocalAppData
      id = {0xF1B32785, 0x6FBA, 0x4FCF, {0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91}};
    } else if (method == "getDownloadsDirectory") {
      // FOLDERID_Downloads
      id = {0x374DE290, 0x123F, 0x4565, {0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B}};
    } else {
      return std::string();
    }
    if (FAILED(SHGetKnownFolderPath(id, 0, nullptr, &raw)) || raw == nullptr) {
      return std::string();
    }
    std::wstring base(raw);
    CoTaskMemFree(raw);

    // <base>\<company>\<product> (path_provider_windows layout).
    std::string company = VersionString(L"CompanyName");
    std::string product = VersionString(L"ProductName");
    if (product.empty()) {
      product = "lanplayer";
    }
    std::wstring dir = base;
    if (!company.empty()) {
      dir += L"\\";
      dir += UTF8ToWide(company);
    }
    dir += L"\\";
    dir += UTF8ToWide(product);
    // CreateFile-based recursive creation: SHCreateDirectoryEx reports access
    // denied for some profile layouts even when the user owns the tree.
    CreateDirectoryTree(dir);
    return WideToUTF8(dir);
  }

  static std::string VersionString(const wchar_t* key) {
    wchar_t exe[MAX_PATH] = {0};
    if (!GetModuleFileNameW(nullptr, exe, MAX_PATH)) {
      return std::string();
    }
    DWORD size = GetFileVersionInfoSizeW(exe, nullptr);
    if (size == 0) {
      return std::string();
    }
    std::vector<uint8_t> buffer(size);
    if (!GetFileVersionInfoW(exe, 0, size, buffer.data())) {
      return std::string();
    }
    std::wstring query;
    query.append(L"\\StringFileInfo\\040904B0\\").append(key);
    wchar_t* value = nullptr;
    UINT length = 0;
    if (!VerQueryValueW(buffer.data(), query.c_str(), reinterpret_cast<void**>(&value), &length) ||
        value == nullptr || length == 0) {
      return std::string();
    }
    return WideToUTF8(std::wstring(value, length ? length - 1 : 0));
  }

  // Creates every missing component of |path| (like `mkdir -p`).
  static void CreateDirectoryTree(const std::wstring& path) {
    std::wstring current;
    for (size_t i = 0; i < path.size(); ++i) {
      const wchar_t ch = path[i];
      current.push_back(ch);
      const bool separator = (ch == L'\\' || ch == L'/');
      const bool last = (i + 1 == path.size());
      if ((separator || last) && current.size() > 3) {
        CreateDirectoryW(current.c_str(), nullptr);
      }
    }
  }

  static std::wstring UTF8ToWide(const std::string& utf8) {
    if (utf8.empty()) {
      return std::wstring();
    }
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), nullptr, 0);
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), &out[0], n);
    return out;
  }

  static std::string WideToUTF8(const std::wstring& wide) {
    if (wide.empty()) {
      return std::string();
    }
    int n = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), nullptr, 0, nullptr,
                                nullptr);
    std::string out(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), &out[0], n, nullptr, nullptr);
    return out;
  }

  void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    std::string load_error;
    if (!core_.Load(&load_error)) {
      result->Error("core_unavailable", load_error);
      return;
    }
    const std::string& method = call.method_name();
    if (method == "createTexture") {
      CreateTexture();
      flutter::EncodableMap reply;
      reply[flutter::EncodableValue("textureId")] =
          flutter::EncodableValue(texture_id_.load());
      reply[flutter::EncodableValue("window")] = flutter::EncodableValue(0);
      result->Success(flutter::EncodableValue(reply));
    } else if (method == "attachPlayer") {
      AttachPlayer(call.arguments());
      result->Success();
    } else if (method == "resizeTexture") {
      result->Success();  // the texture is laid out by Flutter
    } else if (method == "destroyTexture") {
      DestroyTexture();
      result->Success();
    } else if (method == "setFullscreen") {
      bool on = false;
      if (const auto* flag = std::get_if<bool>(call.arguments())) {
        on = *flag;
      }
      SetFullscreen(on);
      result->Success(flutter::EncodableValue(fullscreen_));
    } else {
      result->NotImplemented();
    }
  }

  /*
   * Real fullscreen for the desktop window: Flutter's SystemChrome only hides
   * the status bar on mobile, so the player asks here instead.  The window is
   * found through the view's HWND (the view is a child of the runner's
   * top-level window), its style and placement are saved so leaving fullscreen
   * restores the exact size and position.
   */
  void SetFullscreen(bool on) {
    HWND hwnd = nullptr;
    if (registrar_) {
      if (flutter::FlutterView* view = registrar_->GetView()) {
        hwnd = GetAncestor(view->GetNativeWindow(), GA_ROOT);
      }
    }
    if (!hwnd || on == fullscreen_) {
      return;
    }
    if (on) {
      saved_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
      saved_placement_.length = sizeof(saved_placement_);
      GetWindowPlacement(hwnd, &saved_placement_);
      MONITORINFO monitor{};
      monitor.cbSize = sizeof(monitor);
      if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
        SetWindowLongPtr(hwnd, GWL_STYLE,
                         (saved_style_ & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW)) |
                             static_cast<LONG_PTR>(WS_POPUP));
        SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                     monitor.rcMonitor.right - monitor.rcMonitor.left,
                     monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        fullscreen_ = true;
      }
    } else {
      SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
      SetWindowPlacement(hwnd, &saved_placement_);
      SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                       SWP_FRAMECHANGED);
      fullscreen_ = false;
    }
  }

  void CreateTexture() {
    DestroyTexture();
    auto texture = std::make_shared<VideoTexture>(&core_);
    texture_ = texture;
    auto* variant = new flutter::TextureVariant(flutter::PixelBufferTexture(
        [texture](size_t w, size_t h) { return texture->Copy(w, h); }));
    texture_id_.store(registrar_->texture_registrar()->RegisterTexture(variant));
  }

  void DestroyTexture() {
    int64_t id = texture_id_.exchange(-1);
    auto keep = texture_;
    texture_.reset();
    if (id >= 0 && registrar_) {
      // Hold a reference until the engine confirms the unregister, so an
      // in-flight CopyPixelBuffer on the raster thread stays valid.
      registrar_->texture_registrar()->UnregisterTexture(id, [keep]() {});
    }
    player_ = nullptr;
  }

  void AttachPlayer(const flutter::EncodableValue* arguments) {
    int64_t player = 0;
    if (arguments) {
      if (const auto* map = std::get_if<flutter::EncodableMap>(arguments)) {
        auto it = map->find(flutter::EncodableValue("player"));
        if (it != map->end()) {
          if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
            player = *v64;
          } else if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
            player = *v32;
          }
        }
      }
    }
    player_ = reinterpret_cast<void*>(player);
    if (!player_ || !core_.install_frame_cb) {
      return;
    }
    core_.install_frame_cb(player_, &LanPlayerVideoPlugin::OnCoreFrame, this);
  }

  static void OnCoreFrame(void* user) {
    auto* self = static_cast<LanPlayerVideoPlugin*>(user);
    if (!self || !self->registrar_) {
      return;
    }
    int64_t id = self->texture_id_.load();
    if (id < 0) {
      return;
    }
    // Documented as safe to call from any thread.
    self->registrar_->texture_registrar()->MarkTextureFrameAvailable(id);

    if (!self->texture_stats_) {
      return;
    }
    // 内核每交一帧就到这里，所以用帧数当节拍器：每 5 秒（或每 120 帧，
    // 取先到的那个）打一行吞吐，用来判断「卡」是内核没出帧还是 Flutter
    // 侧来不及取。
    const ULONGLONG now = GetTickCount64();
    if (now - self->last_report_ms_ < 5000) {
      return;
    }
    self->last_report_ms_ = now;
    self->ReportTextureStats();
  }

  // 每 5 秒往 stderr 打一行纹理吞吐：内核交来多少帧、真的上屏多少帧、
  // 因为两个缓冲都被引擎占着而丢掉多少帧。真机上「画面卡但声音正常」时，
  // 有这行就能直接分出「内核没出帧」和「Flutter 侧来不及取」。
  // 只有设了 LANPLAYER_TEXTURE_STATS=1 才打，平时不刷屏。
  void ReportTextureStats() {
    auto tex = texture_;
    if (!tex) {
      return;
    }
    fprintf(stderr, "[lanplayer_video] texture taken=%llu dropped=%llu\n",
            tex->frames_taken(), tex->frames_dropped());
  }

  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>> fallback_channels_;
  CoreApi core_;
  std::shared_ptr<VideoTexture> texture_;
  std::atomic<int64_t> texture_id_{-1};
  void* player_ = nullptr;
  bool fullscreen_ = false;
  // 纹理吞吐诊断：LANPLAYER_TEXTURE_STATS=1 时才每 5 秒打一行。
  bool texture_stats_ = false;
  unsigned long long last_report_ms_ = 0;
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_{};
};

}  // namespace

void LanPlayerVideoPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  LanPlayerVideoPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
