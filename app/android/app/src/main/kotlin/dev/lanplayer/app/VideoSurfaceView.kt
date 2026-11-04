package dev.lanplayer.app

import android.content.Context
import android.graphics.PixelFormat
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 移动端的视频输出：一块属于本应用的原生 Surface，而不是 Flutter 外部纹理。
 *
 * 为什么不再用纹理：Flutter 引擎只要看到有活跃的外部纹理，就会在每一个
 * vsync 上把整棵 layer tree 重新光栅化一次，与纹理本身有没有更新无关。
 * 120 Hz 屏幕放 30 fps 的内容时，四次合成里有三次在重绘同一张图，栅格线程
 * 与 GPU 被白白占住。这条约束在引擎层面没有开关（`flutter/flutter#188616`、
 * `flutter/flutter#192181` 都在跟踪，维护者明确不打算暴露
 * `CADisplayLink.preferredFrameRateRange`）。
 *
 * [SurfaceView] 的 Surface 直接挂在原生视图层级里：内核往里画，系统合成器按
 * 自己的节奏把它叠在 Flutter 画面之上，完全不经过引擎的合成循环。帧该出现
 * 的时候出现，屏幕刷新多少次与内容帧率无关。
 *
 * 内核那边一行都不用改：`lp_player_set_surface` 收到的就是一个
 * `ANativeWindow*`，它不关心这个窗口是纹理的生产者还是 SurfaceView 的持有者。
 * JNI 的几个函数（见 `native/src/platform/android/jni_bridge.c`）同理。
 */
class VideoSurfaceView(context: Context) : PlatformView {

    private val surfaceView = SurfaceView(context).apply {
        // 不透明：内核画满每一帧，半透明会让系统多叠一层合成。
        holder.setFormat(PixelFormat.OPAQUE)
    }

    private val holder: SurfaceHolder = surfaceView.holder

    private var windowPtr: Long = 0

    private val surfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(h: SurfaceHolder) {
            attach(h.surface)
        }

        override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) {
            // 旋转、分屏、窗口尺寸变化都从这里来。Surface 没换时不必重建窗口
            // 指针，只把新尺寸告诉内核。
            if (windowPtr == 0L) {
                attach(h.surface)
            } else {
                VideoTextureBridge.resizeActive(width, height)
            }
        }

        override fun surfaceDestroyed(h: SurfaceHolder) {
            detach()
        }
    }

    init {
        holder.addCallback(surfaceCallback)
        VideoTextureBridge.attachView(this)
        // 少数机型在 addCallback 之前 Surface 就已可用，这里补接一次。
        if (holder.surface?.isValid == true) {
            attach(holder.surface)
        }
    }

    /**
     * 把内核挂到这块 Surface 上。
     *
     * 顺序不能反：先拿到 `ANativeWindow*`，再让内核实上。`nativeSetSurface`
     * 内部走 `lp_player_set_surface`，窗口换掉会重启硬解视频管线，那一刻窗口
     * 必须已经指向有效内存。
     */
    private fun attach(surface: Surface?) {
        if (surface == null || !surface.isValid) {
            return
        }
        detach()
        val w = VideoTextureBridge.nativeCreateWindow(surface)
        if (w == 0L) {
            Log.w(TAG, "ANativeWindow_fromSurface returned 0")
            return
        }
        windowPtr = w
        // post 到视图线程：此时 SurfaceView 已经过一轮布局，宽高才可信。
        surfaceView.post { bindPlayer(VideoTextureBridge.activePlayer) }
    }

    /**
     * 摘掉内核手里的窗口指针，再释放 `ANativeWindow`。
     *
     * 顺序同样不能反：反过来的话内核可能正拿着它画下一帧，就是 use-after-free。
     */
    private fun detach() {
        val p = VideoTextureBridge.activePlayer
        if (p != 0L) {
            VideoTextureBridge.nativeSetSurface(p, 0L)
        }
        if (windowPtr != 0L) {
            VideoTextureBridge.nativeReleaseWindow(windowPtr)
            windowPtr = 0L
        }
    }

    /**
     * 摘掉一个内核播放器对当前窗口的引用。
     *
     * 换播放器（关页、换成另一集）时调用：只让内核松开这块 Surface，
     * **不释放 `ANativeWindow`** —— 那是视图自己的资源，Surface 还在，下一个
     * 播放器就得接着往上画。真正释放发生在 [surfaceDestroyed] 与 [dispose]。
     */
    fun unbindPlayer(player: Long) {
        if (player == 0L) {
            return
        }
        VideoTextureBridge.nativeSetSurface(player, 0L)
    }

    /**
     * 把一个内核播放器接到当前窗口上。
     *
     * 视图与播放器谁先创建都可能：平台视图在播放页首帧就建好，播放器要等
     * 用户点了某一集才建；换集时又会是同一个视图接新的播放器。所以每次都
     * 按「先换窗口、再对尺寸」的顺序重接一遍，重复调用无副作用。
     */
    fun bindPlayer(player: Long) {
        val w = windowPtr
        if (player == 0L || w == 0L) {
            return
        }
        VideoTextureBridge.nativeSetSurface(player, w)
        VideoTextureBridge.resize(player, surfaceView.width, surfaceView.height)
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        holder.removeCallback(surfaceCallback)
        VideoTextureBridge.detachView(this)
        detach()
    }

    // 视频 Surface 上没有输入法，这两个回调按接口约定留空。
    override fun onFlutterViewAttached(flutterView: View) {}
    override fun onFlutterViewDetached() {}
    override fun onInputConnectionLocked() {}
    override fun onInputConnectionUnlocked() {}

    companion object {
        private const val TAG = "LanPlayerSurface"

        /**
         * 平台视图类型名。
         *
         * 必须与 `packages/lanplayer_video/lib/src/channel.dart` 里的
         * `lanplayerVideoSurfaceViewType` 一字不差：Dart 侧按这个名字找工厂，
         * 找不到就是一块黑屏，而且不会有任何异常。
         */
        const val VIEW_TYPE = "dev.lanplayer/video_surface"
    }
}

/**
 * 平台视图工厂。
 *
 * 播放器指针不走 `creationParams`，而是经 [VideoTextureBridge.activePlayer]
 * 广播给当前存活的视图 —— 视图与播放器的创建先后没有保证，用一个共享的
 * 「当前播放器」比把指针塞进创建参数更容易对上。
 */
class VideoSurfaceViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        VideoSurfaceView(context)
}
