package dev.lanplayer.app

import android.Manifest
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformViewRegistry

/**
 * 宿主入口：方法通道、权限、方向，以及视频平台视图的注册。
 *
 * 视频画面不再走 Flutter 外部纹理，而是 [VideoSurfaceView] 里那块原生
 * Surface。原因见那个类的注释：引擎只要看到有活跃的外部纹理就会在每个 vsync
 * 上重绘整棵 layer tree，与纹理有没有更新无关，120 Hz 屏幕上放 30 fps 内容
 * 时四分之三的合成是白做的。
 *
 * 通道上的 `createTexture` 现在只回答「这块画面由平台视图提供」，真正的
 * `ANativeWindow*` 由平台视图自己交给内核；`attachPlayer` 仍然要收，因为内核
 * 播放器是 Dart 侧建的，宿主得知道该把这个指针接到哪块 Surface 上。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var permChannel: MethodChannel? = null
    private var pendingPermission: MethodChannel.Result? = null

    /**
     * 不参与「进程重建时恢复界面」。
     *
     * `FlutterActivity` 默认返回 true：Activity 被系统回收（从最近任务里划掉
     * 卡片、系统在后台杀掉进程）之后重新进来，引擎会拿到上次存下的
     * InstanceState，连 Dart 侧的导航栈一起恢复 —— 用户看到的是「一开就回到
     * 上次那个播放页」。那个页面此刻往往已经不可用：SMB 源换了网或没开机，
     * 屏幕上只剩一句连接失败，还得先返回一次才能用。
     *
     * 上次看到哪儿由 `ProgressStore` 记着，首页那一行会显示「已看 xx%」。
     * 界面本身不需要恢复，所以这里直接关掉，每次进来都从首页开始。
     */
    override fun shouldRestoreAndSaveState(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupPermissions(flutterEngine)
        registerVideoSurface(flutterEngine)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanplayer/video")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "createTexture" -> {
                    // 画面由平台视图提供：没有 Flutter 纹理 id，也没有需要
                    // Dart 转交的窗口指针。`platformView` 让 Dart 侧知道该建
                    // 平台视图而不是 `Texture`。
                    result.success(createPlatformSurfaceReply())
                }
                "attachPlayer" -> {
                    val player = call.argument<Number>("player")?.toLong() ?: 0L
                    VideoTextureBridge.setPlayer(player)
                    result.success(null)
                }
                "destroyTexture" -> {
                    VideoTextureBridge.setPlayer(0L)
                    result.success(null)
                }
                "lockLandscape" -> {
                    lockLandscape(call.arguments as? Boolean ?: false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 注册视频平台视图工厂。
     *
     * 视图类型名必须与 `packages/lanplayer_video/lib/src/channel.dart` 的
     * `lanplayerVideoSurfaceViewType` 一致，`tool/check_all.py` 会逐字比对。
     */
    private fun registerVideoSurface(engine: FlutterEngine) {
        val registry: PlatformViewRegistry = engine.platformViewsController.registry
        registry.registerViewFactory(VideoSurfaceView.VIEW_TYPE, VideoSurfaceViewFactory())
    }

    /**
     * `createTexture` 的回包。
     *
     * 键名与 `packages/lanplayer_video/lib/src/channel.dart` 的 `TextureReplyKey`
     * 对应。`textureId` 用 -1 明确表示「没有纹理」，`window` 用 0 表示
     * 「Dart 不要调 `lp_player_set_surface`」—— 窗口由平台视图自己交给内核。
     */
    private fun createPlatformSurfaceReply(): Map<String, Any> = mapOf(
        "textureId" to -1,
        "window" to 0,
        "platformView" to true
    )

    /**
     * 播放页要锁横屏时用这一档。
     *
     * Dart 的 `SystemChrome.setPreferredOrientations([landscapeLeft,
     * landscapeRight])` 到 Android 上变成 `SCREEN_ORIENTATION_FULL_USER`。那一档
     * 只保证窗口是横的，仍然受系统「自动旋转」开关管：用户在控制中心把自动旋转
     * 关掉之后，播放页会钉死在进入时的那个横向上，把机身翻到另一侧画面不动，
     * 只有把机器立起来再放平才会重排 —— 这正是「不跟陀螺仪转」的观感。
     *
     * `SCREEN_ORIENTATION_SENSOR_LANDSCAPE` 不看那个开关，只听加速度计与陀螺仪，
     * 并且不会让画面变成竖的。Flutter 没有暴露这一档，所以由宿主直接调。
     *
     * 传 false 时还原成 `UNSPECIFIED`：让 Dart 侧随后那次
     * `setPreferredOrientations(DeviceOrientation.values)` 重新决定方向。
     *
     * iOS 侧同名方法走的是另一条路（`requestGeometryUpdate`），见 Runner/
     * AppDelegate.swift。
     */
    private fun lockLandscape(on: Boolean) {
        requestedOrientation = if (on) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

    /**
     * Runtime media permissions.
     *
     * Declaring READ_MEDIA_VIDEO in the manifest is not enough: since Android 6
     * (and stricter since 13, where the storage permission split into per-type
     * media permissions) the user has to grant them at runtime.  Without this
     * the "local storage" entry point reads an empty directory on a fresh
     * install, which looks like a browser bug rather than a permission prompt.
     */
    private fun setupPermissions(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "lanplayer/permissions")
        permChannel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestMedia" -> requestMedia(result)
                "status" -> result.success(permissionState())
                else -> result.notImplemented()
            }
        }
    }

    private fun mediaPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // API 33+ : ask for the video grant only.  Adding READ_MEDIA_AUDIO
            // to the same request pops a second dialog ("音乐和音频") before the
            // one that matters, which reads as a bug to the user.
            arrayOf(Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            // API 26..32 : one storage permission covers everything.
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    /** True when the browser can actually list media files. */
    private fun hasMediaPermission(): Boolean =
        checkSelfPermission(mediaPermissions()[0]) == PackageManager.PERMISSION_GRANTED

    /**
     * Android 14 introduced partial access: "选择部分" grants
     * READ_MEDIA_VISUAL_USER_SELECTED only.  The app then sees just the items the
     * user picked, which for a folder browser means whole directories are
     * missing -- worth telling the user about instead of showing a half-empty
     * list with no explanation.
     */
    private fun hasPartialPermission(): Boolean =
        Build.VERSION.SDK_INT >= 34 &&
            checkSelfPermission("android.permission.READ_MEDIA_VISUAL_USER_SELECTED") ==
            PackageManager.PERMISSION_GRANTED

    private fun permissionState() = mapOf(
        "granted" to hasMediaPermission(),
        "partial" to hasPartialPermission()
    )

    private fun requestMedia(result: MethodChannel.Result) {
        if (hasMediaPermission()) {
            result.success(permissionState())
            return
        }
        if (pendingPermission != null) {
            // A dialog is already up; do not stack a second one.
            result.success(mapOf("granted" to false, "partial" to false))
            return
        }
        pendingPermission = result
        requestPermissions(mediaPermissions(), MEDIA_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == MEDIA_REQUEST_CODE) {
            // Re-read the grants instead of trusting grantResults: on Android 14
            // the partial grant comes back as a denial for READ_MEDIA_VIDEO plus
            // a separate READ_MEDIA_VISUAL_USER_SELECTED grant.
            pendingPermission?.success(permissionState())
            pendingPermission = null
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        VideoTextureBridge.setPlayer(0L)
        channel?.setMethodCallHandler(null)
        channel = null
        permChannel?.setMethodCallHandler(null)
        permChannel = null
        super.onDestroy()
    }

    companion object {
        private const val MEDIA_REQUEST_CODE = 0x4C50
    }
}

/**
 * 内核播放器与当前存活平台视图之间的接线板。
 *
 * 视图和播放器的创建顺序没有保证：平台视图在播放页首帧就建好（`build` 里
 * 立刻要出一块画面区域），播放器要等用户点了某一集、Dart 侧 `initialize()`
 * 之后才有指针；换集时又是同一个视图接一个新的播放器。所以两边都往这里
 * 登记，谁后到谁负责把线接上。
 *
 * 所有方法都可能在任意线程被调（Dart 的通道回调在 UI 线程，Surface 回调在
 * 各自线程），因此只做短小的同步块，不做任何等待。
 */
object VideoTextureBridge {
    init {
        System.loadLibrary("lanplayer")
    }

    private val lock = Any()
    private var player: Long = 0
    private val views = mutableListOf<VideoSurfaceView>()

    /** 当前内核播放器指针；0 表示还没有。 */
    val activePlayer: Long
        get() = synchronized(lock) { player }

    /** 换播放器：把新指针接到每一块还活着的视图上，旧播放器先摘干净。 */
    fun setPlayer(ptr: Long) {
        val live: List<VideoSurfaceView>
        val previous: Long
        synchronized(lock) {
            if (player == ptr) return
            previous = player
            player = ptr
            live = views.toList()
        }
        for (v in live) {
            v.unbindPlayer(previous)
            if (ptr != 0L) {
                v.bindPlayer(ptr)
            }
        }
    }

    fun attachView(view: VideoSurfaceView) {
        val ptr: Long
        synchronized(lock) {
            views.add(view)
            ptr = player
        }
        if (ptr != 0L) {
            view.bindPlayer(ptr)
        }
    }

    fun detachView(view: VideoSurfaceView) {
        synchronized(lock) { views.remove(view) }
    }

    /** Surface 尺寸变了，但窗口指针没变：只更新内核的渲染目标尺寸。 */
    fun resizeActive(width: Int, height: Int) {
        val ptr = activePlayer
        if (ptr != 0L) {
            resize(ptr, width, height)
        }
    }

    fun resize(ptr: Long, width: Int, height: Int) {
        if (ptr == 0L || width <= 0 || height <= 0) {
            return
        }
        nativeResizeSurface(ptr, width, height)
    }

    /** Must stay in sync with native/src/platform/android/jni_bridge.c. */
    @JvmStatic
    external fun nativeCreateWindow(surface: android.view.Surface): Long

    @JvmStatic
    external fun nativeReleaseWindow(window: Long)

    /** 只换窗口指针，不重建播放器；`window == 0` 表示当前没有可用 Surface。 */
    @JvmStatic
    external fun nativeSetSurface(player: Long, window: Long)

    /** 窗口尺寸变化；内核据此重设 EGL 视口或硬解缓冲区。 */
    @JvmStatic
    external fun nativeResizeSurface(player: Long, width: Int, height: Int)
}
