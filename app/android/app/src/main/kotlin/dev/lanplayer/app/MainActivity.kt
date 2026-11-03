package dev.lanplayer.app

import android.Manifest
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Build
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Hosts the video surface for the FFmpeg core.
 *
 * The texture is registered with Flutter's surface producer API (not the legacy
 * SurfaceTexture entry).  That matters on Android: with the default Impeller
 * (Vulkan) renderer the legacy path hands out a SurfaceTexture whose frames are
 * never consumed, so MediaCodec keeps dropping every decoded frame
 * (`Render:0 Drop:N` in `dumpsys media.codec`) and the picture stays black even
 * though decoding works.  SurfaceProducer owns the consumer side for us.
 *
 * The Surface is wrapped as an ANativeWindow* and handed to the native layer,
 * which either renders into it with EGL (software decode) or lets MediaCodec
 * render into it directly (hardware decode); Dart draws `Texture(textureId:)`.
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var permChannel: MethodChannel? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    /**
     * Surface 被系统收回时的收尾动作挂在这里。
     *
     * `SurfaceProducer` 的 Surface 不是我们自己造的：进程被压到后台、系统
     * 回收 GPU 资源时它会被销毁，回到前台再给一个新的。旧代码只在
     * `onDestroy` 里释放窗口，中间这段时间内核攥着一个已经 release 的
     * `ANativeWindow*` —— 一恢复播放就是 use-after-free。
     */
    private var surfaceCallback: TextureRegistry.SurfaceProducer.Callback? = null
    private var windowPtr: Long = 0
    private var playerPtr: Long = 0

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
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanplayer/video")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "createTexture" -> {
                    val width = (call.argument<Int>("width") ?: 1920)
                    val height = (call.argument<Int>("height") ?: 1080)
                    result.success(createTexture(flutterEngine, width, height))
                }
                "attachPlayer" -> {
                    playerPtr = (call.argument<Number>("player")?.toLong() ?: 0L)
                    result.success(null)
                }
                "destroyTexture" -> {
                    releaseTexture()
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

    private fun createTexture(engine: FlutterEngine, width: Int, height: Int): Map<String, Any> {
        releaseTexture()
        // FlutterRenderer implements TextureRegistry itself, so there is no
        // separate `textureRegistry` getter on it (that name only exists on the
        // iOS/macOS registrar).
        val p = engine.renderer.createSurfaceProducer()
        p.setSize(width, height)
        val s: Surface = p.surface
        val w = VideoTextureBridge.nativeCreateWindow(s)
        producer = p
        windowPtr = w
        installSurfaceCallback(p)
        return mapOf("textureId" to p.id(), "window" to w)
    }

    /**
     * 让内核在 Surface 换掉之后拿到新的 `ANativeWindow*`。
     *
     * `onSurfaceAvailable` 在创建时和每次重建时都会来一次；`onSurfaceDestroyed`
     * 在系统收回之前来一次。两边的动作都必须短：回调本身在 raster 线程上跑。
     */
    private fun installSurfaceCallback(p: TextureRegistry.SurfaceProducer) {
        val cb = object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                val surface = p.surface
                if (surface == null || producer !== p) {
                    return
                }
                if (windowPtr != 0L) {
                    VideoTextureBridge.nativeReleaseWindow(windowPtr)
                    windowPtr = 0L
                }
                val w = VideoTextureBridge.nativeCreateWindow(surface)
                windowPtr = w
                val handle = playerPtr
                if (handle != 0L) {
                    VideoTextureBridge.nativeSetSurface(handle, w)
                }
            }

            override fun onSurfaceDestroyed() {
                if (producer !== p) {
                    return
                }
                val handle = playerPtr
                if (handle != 0L) {
                    // 先把内核那边的指针摘掉，再释放 ANativeWindow：
                    // 反过来的话内核可能正拿着它画下一帧。
                    VideoTextureBridge.nativeSetSurface(handle, 0L)
                }
                if (windowPtr != 0L) {
                    VideoTextureBridge.nativeReleaseWindow(windowPtr)
                    windowPtr = 0L
                }
            }
        }
        surfaceCallback = cb
        p.setCallback(cb)
    }

    private fun releaseTexture() {
        // 不给 setCallback 传 null：它的参数是不是 @Nullable 取决于引擎版本，
        // 而回调里那句 `producer !== p` 已经能让旧回调自己走空分支。
        surfaceCallback = null
        if (windowPtr != 0L) {
            VideoTextureBridge.nativeReleaseWindow(windowPtr)
            windowPtr = 0L
        }
        producer?.release()
        producer = null
    }

    override fun onDestroy() {
        releaseTexture()
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

/** Must stay in sync with native/src/platform/android/jni_bridge.c. */
object VideoTextureBridge {
    init {
        System.loadLibrary("lanplayer")
    }

    @JvmStatic
    external fun nativeCreateWindow(surface: Surface): Long

    @JvmStatic
    external fun nativeReleaseWindow(window: Long)

    /** 只换窗口指针，不重建播放器；`window == 0` 表示当前没有可用 Surface。 */
    @JvmStatic
    external fun nativeSetSurface(player: Long, window: Long)
}
