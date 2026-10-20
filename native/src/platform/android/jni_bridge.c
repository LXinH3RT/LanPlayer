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

#endif /* __ANDROID__ */
