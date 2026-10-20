package dev.lanplayer.app

import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Hosts the video surface for the FFmpeg core.
 *
 * A SurfaceTexture is registered with the Flutter texture registry, wrapped in a
 * Surface and handed to the native layer as an ANativeWindow*.  The native core
 * then either renders into it with EGL (software decode) or lets MediaCodec
 * render into it directly (hardware decode), and Dart just draws
 * `Texture(textureId: ...)`.
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var windowPtr: Long = 0
    private var playerPtr: Long = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanplayer/video")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "createTexture" -> {
                    val width = (call.argument<Int>("width") ?: 1920)
                    val height = (call.argument<Int>("height") ?: 1080)
                    result.success(createTexture(flutterEngine, width, height))
                }
                "resizeTexture" -> {
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    entry?.surfaceTexture()?.setDefaultBufferSize(width, height)
                    result.success(null)
                }
                "attachPlayer" -> {
                    playerPtr = (call.argument<Number>("player")?.toLong() ?: 0L)
                    result.success(null)
                }
                "destroyTexture" -> {
                    release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun createTexture(engine: FlutterEngine, width: Int, height: Int): Map<String, Any> {
        release()
        val e = engine.renderer.textureRegistry.createSurfaceTexture()
        e.surfaceTexture().setDefaultBufferSize(width, height)
        val s = Surface(e.surfaceTexture())
        val w = VideoTextureBridge.nativeCreateWindow(s)
        entry = e
        surface = s
        windowPtr = w
        return mapOf("textureId" to e.id(), "window" to w)
    }

    private fun release() {
        if (windowPtr != 0L) {
            VideoTextureBridge.nativeReleaseWindow(windowPtr)
            windowPtr = 0
        }
        surface?.release()
        surface = null
        entry?.release()
        entry = null
    }

    override fun onDestroy() {
        release()
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
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
}
