/*
 * JNI bridge for the Android texture host.
 *
 * ANativeWindow_fromSurface needs a JNIEnv, which Dart cannot provide, so the
 * Kotlin side calls these two functions and hands the resulting pointer to Dart
 * through the method channel.
 */
#if defined(__ANDROID__)

#include <android/native_window_jni.h>
#include <jni.h>

#include "player_internal.h"

JNIEXPORT jlong JNICALL
Java_dev_lanplayer_app_VideoTextureBridge_nativeCreateWindow(JNIEnv *env, jobject thiz,
                                                             jobject surface)
{
    (void)thiz;
    if (!surface) {
        return 0;
    }
    ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
    return (jlong)(intptr_t)window;
}

JNIEXPORT void JNICALL
Java_dev_lanplayer_app_VideoTextureBridge_nativeReleaseWindow(JNIEnv *env, jobject thiz,
                                                             jlong window)
{
    (void)env;
    (void)thiz;
    if (window) {
        ANativeWindow_release((ANativeWindow *)(intptr_t)window);
    }
}

/*
 * Surface 重建时换掉内核记着的窗口。
 *
 * 这里只摘指针、不碰解码器：`lp_player_set_surface` 在「原来没有窗口、现在有」
 * 时会重启视频流水线，Surface 回来了正好走这条路；传 0 只是让内核停止往一个
 * 即将被销毁的窗口上画。
 *
 * 用 `lp_player_set_surface_size` 之外的两个接口而不是直接改 `p->vout.window`：
 * 内核可能在别的线程用这个指针。
 */
JNIEXPORT void JNICALL
Java_dev_lanplayer_app_VideoTextureBridge_nativeSetSurface(JNIEnv *env, jobject thiz,
                                                           jlong player, jlong window)
{
    (void)env;
    (void)thiz;
    if (!player) {
        return;
    }
    LpPlayer *p = (LpPlayer *)(intptr_t)player;
    lp_player_set_surface(p, (void *)(intptr_t)window, p->vout.window_w, p->vout.window_h);
}

/*
 * 窗口尺寸变了（旋转、分屏、SurfaceView 重新布局）。
 *
 * SurfaceView 的 Surface 尺寸由系统在布局时定下来，和 Dart 侧算出来的纹理
 * 尺寸是两回事：以前那条路是 Dart 按屏幕长边/短边算出数字再调
 * `lp_player_set_surface_size`，现在窗口本身就有真实尺寸，宿主的
 * `surfaceChanged` 直接把它交过来更准。
 */
JNIEXPORT void JNICALL
Java_dev_lanplayer_app_VideoTextureBridge_nativeResizeSurface(JNIEnv *env, jobject thiz,
                                                             jlong player, jint width,
                                                             jint height)
{
    (void)env;
    (void)thiz;
    if (!player || width <= 0 || height <= 0) {
        return;
    }
    LpPlayer *p = (LpPlayer *)(intptr_t)player;
    lp_player_set_surface_size(p, width, height);
}

#endif /* __ANDROID__ */
