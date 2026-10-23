package dev.lanplayer.app

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
    private var producer: TextureRegistry.SurfaceProducer? = null
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
                    producer?.setSize(width, height)
                    result.success(null)
                }
                "attachPlayer" -> {
                    playerPtr = (call.argument<Number>("player")?.toLong() ?: 0L)
                    result.success(null)
                }
                "destroyTexture" -> {
                    releaseTexture()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
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
        return mapOf("textureId" to p.id(), "window" to w)
    }

    private fun releaseTexture() {
        if (windowPtr != 0L) {
            VideoTextureBridge.nativeReleaseWindow(windowPtr)
            windowPtr = 0
        }
        producer?.release()
        producer = null
    }

    override fun onDestroy() {
        releaseTexture()
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
