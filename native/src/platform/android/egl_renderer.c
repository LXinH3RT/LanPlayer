/*
 * Android video output: EGL + GLES2 renderer writing into the ANativeWindow of
 * the Flutter platform view.
 *
 * Used by the software decode path (YUV upload with a 3-plane shader).  The
 * hardware path bypasses this file entirely: MediaCodec renders into the same
 * window directly, so both paths land on the same surface with the same
 * aspect-ratio rules.
 */
#if defined(__ANDROID__)

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <android/native_window.h>

#include <stdlib.h>

#include "player_internal.h"

typedef struct LpEgl {
    int ready;
    EGLDisplay display;
    EGLSurface surface;
    EGLContext context;
    EGLConfig config;
    ANativeWindow *window;
    int view_w;
    int view_h;
    GLuint program;
    GLint attr_pos;
    GLint attr_tex;
    GLuint tex[3];
    int tex_w[3];
    int tex_h[3];
    int frame_w;
    int frame_h;
    int pix_fmt; /* 0 = yuv420p, 1 = nv12 */
    struct SwsContext *sws;
    uint8_t *conv[4];
    int conv_linesize[4];
    int conv_cap;
} LpEgl;

static LpEgl g_egl;
static pthread_mutex_t g_egl_lock = PTHREAD_MUTEX_INITIALIZER;

static const char *kVS =
    "attribute vec4 a_pos;\n"
    "attribute vec2 a_tex;\n"
    "varying vec2 v_tex;\n"
    "void main(){ gl_Position = a_pos; v_tex = a_tex; }\n";

static const char *kFS =
    "precision mediump float;\n"
    "varying vec2 v_tex;\n"
    "uniform sampler2D u_y;\n"
    "uniform sampler2D u_u;\n"
    "uniform sampler2D u_v;\n"
    "uniform int u_nv12;\n"
    "void main(){\n"
    "  vec3 yuv;\n"
    "  yuv.x = texture2D(u_y, v_tex).r - 0.0625;\n"
    "  if (u_nv12 == 1) {\n"
    "    vec2 uv = texture2D(u_u, v_tex).ra - vec2(0.5, 0.5);\n"
    "    yuv.y = uv.x; yuv.z = uv.y;\n"
    "  } else {\n"
    "    yuv.y = texture2D(u_u, v_tex).r - 0.5;\n"
    "    yuv.z = texture2D(u_v, v_tex).r - 0.5;\n"
    "  }\n"
    "  vec3 rgb = mat3(1.164, 1.164, 1.164,\n"
    "                  0.0,  -0.391, 2.018,\n"
    "                  1.596, -0.813, 0.0) * yuv;\n"
    "  gl_FragColor = vec4(rgb, 1.0);\n"
    "}\n";

static GLuint compile(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        LP_ERROR("egl", "shader compile failed: %s", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static int egl_build_program(void)
{
    GLuint vs = compile(GL_VERTEX_SHADER, kVS);
    GLuint fs = compile(GL_FRAGMENT_SHADER, kFS);
    if (!vs || !fs) {
        return -1;
    }
    GLuint p = glCreateProgram();
    glAttachShader(p, vs);
    glAttachShader(p, fs);
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(p, sizeof(log), NULL, log);
        LP_ERROR("egl", "program link failed: %s", log);
        glDeleteProgram(p);
        return -1;
    }
    g_egl.program = p;
    g_egl.attr_pos = glGetAttribLocation(p, "a_pos");
    g_egl.attr_tex = glGetAttribLocation(p, "a_tex");
    glUseProgram(p);
    glUniform1i(glGetUniformLocation(p, "u_y"), 0);
    glUniform1i(glGetUniformLocation(p, "u_u"), 1);
    glUniform1i(glGetUniformLocation(p, "u_v"), 2);
    glGenTextures(3, g_egl.tex);
    for (int i = 0; i < 3; i++) {
        glBindTexture(GL_TEXTURE_2D, g_egl.tex[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    return 0;
}

static int egl_make_current(void)
{
    if (!g_egl.display || !g_egl.context) {
        return -1;
    }
    if (!eglMakeCurrent(g_egl.display, g_egl.surface, g_egl.surface, g_egl.context)) {
        LP_ERROR("egl", "eglMakeCurrent failed: 0x%x", eglGetError());
        return -1;
    }
    return 0;
}

static int egl_init_display(ANativeWindow *window)
{
    if (g_egl.window != window) {
        if (g_egl.surface != EGL_NO_SURFACE) {
            eglMakeCurrent(g_egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroySurface(g_egl.display, g_egl.surface);
            g_egl.surface = EGL_NO_SURFACE;
        }
        g_egl.window = window;
    }
    if (!g_egl.display) {
        g_egl.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (g_egl.display == EGL_NO_DISPLAY || !eglInitialize(g_egl.display, NULL, NULL)) {
            LP_ERROR("egl", "eglInitialize failed");
            return -1;
        }
        const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
                                EGL_RED_SIZE,        8,
                                EGL_GREEN_SIZE,      8,
                                EGL_BLUE_SIZE,       8,
                                EGL_ALPHA_SIZE,      8,
                                EGL_DEPTH_SIZE,      0,
                                EGL_NONE};
        EGLint num = 0;
        if (!eglChooseConfig(g_egl.display, attrs, &g_egl.config, 1, &num) || num == 0) {
            LP_ERROR("egl", "eglChooseConfig failed");
            return -1;
        }
    }
    if (!g_egl.context) {
        const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
        g_egl.context = eglCreateContext(g_egl.display, g_egl.config, EGL_NO_CONTEXT, ctx_attrs);
        if (g_egl.context == EGL_NO_CONTEXT) {
            LP_ERROR("egl", "eglCreateContext failed");
            return -1;
        }
    }
    if (g_egl.surface == EGL_NO_SURFACE && g_egl.window) {
        g_egl.surface = eglCreateWindowSurface(g_egl.display, g_egl.config, g_egl.window, NULL);
        if (g_egl.surface == EGL_NO_SURFACE) {
            LP_ERROR("egl", "eglCreateWindowSurface failed: 0x%x", eglGetError());
            return -1;
        }
    }
    if (egl_make_current() != 0) {
        return -1;
    }
    if (!g_egl.ready) {
        if (egl_build_program() != 0) {
            return -1;
        }
        g_egl.ready = 1;
    }
    return 0;
}

static void egl_upload_plane(GLuint tex, int idx, const uint8_t *data, int w_stride, int h,
                             GLenum format, int w)
{
    glActiveTexture(GL_TEXTURE0 + (GLenum)idx);
    glBindTexture(GL_TEXTURE_2D, tex);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    if (g_egl.tex_w[idx] != w || g_egl.tex_h[idx] != h) {
        glTexImage2D(GL_TEXTURE_2D, 0, format, w, h, 0, format, GL_UNSIGNED_BYTE, data);
        g_egl.tex_w[idx] = w;
        g_egl.tex_h[idx] = h;
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, format, GL_UNSIGNED_BYTE, data);
    }
    (void)w_stride;
}

/* Converts anything that is not YUV420P/NV12 into YUV420P. */
static AVFrame *prepare_frame(LpPlayer *p, AVFrame *frame)
{
    if (frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P ||
        frame->format == AV_PIX_FMT_NV12) {
        return frame;
    }
    if (!g_egl.sws) {
        g_egl.sws = sws_getContext(frame->width, frame->height, (enum AVPixelFormat)frame->format,
                                   frame->width, frame->height, AV_PIX_FMT_YUV420P, SWS_BILINEAR,
                                   NULL, NULL, NULL);
        if (!g_egl.sws) {
            return NULL;
        }
    }
    int w = frame->width, h = frame->height;
    if (g_egl.conv_cap < w * h * 2 || !g_egl.conv[0]) {
        free(g_egl.conv[0]);
        g_egl.conv_cap = w * h * 2;
        g_egl.conv[0] = malloc((size_t)g_egl.conv_cap);
        if (!g_egl.conv[0]) {
            return NULL;
        }
    }
    g_egl.conv[1] = g_egl.conv[0] + (size_t)w * h;
    g_egl.conv[2] = g_egl.conv[1] + (size_t)(w / 2) * (h / 2);
    g_egl.conv[3] = NULL;
    g_egl.conv_linesize[0] = w;
    g_egl.conv_linesize[1] = w / 2;
    g_egl.conv_linesize[2] = w / 2;
    g_egl.conv_linesize[3] = 0;
    sws_scale(g_egl.sws, (const uint8_t *const *)frame->data, frame->linesize, 0, h, g_egl.conv,
              g_egl.conv_linesize);

    static AVFrame tmp;
    av_frame_unref(&tmp);
    tmp.format = AV_PIX_FMT_YUV420P;
    tmp.width = w;
    tmp.height = h;
    tmp.data[0] = g_egl.conv[0];
    tmp.data[1] = g_egl.conv[1];
    tmp.data[2] = g_egl.conv[2];
    tmp.linesize[0] = g_egl.conv_linesize[0];
    tmp.linesize[1] = g_egl.conv_linesize[1];
    tmp.linesize[2] = g_egl.conv_linesize[2];
    (void)p;
    return &tmp;
}

int lp_render_init(LpPlayer *p)
{
    (void)p;
    return LP_OK;
}

int lp_render_available(void)
{
    return 1;
}

const char *lp_render_name(void)
{
    return "egl";
}

int lp_render_set_window(LpPlayer *p, void *window, int width, int height)
{
    (void)p;
    pthread_mutex_lock(&g_egl_lock);
    g_egl.view_w = width;
    g_egl.view_h = height;
    /* 只记下窗口，不在这里 eglCreateWindowSurface。
     *
     * SurfaceTexture 同时只允许一个生产者连上去。硬解路径由 MediaCodec 直接
     * 渲染进这个窗口，如果这里抢先连一次 EGL，MediaCodec 的 configure 就会
     * 拿到 `BufferQueueProducer: connect: already connected (cur=1 req=3)` +
     * `surfaceConnectWithListener returned an error: Invalid argument (-22)`，
     * 硬解整个起不来。软解路径在 lp_render_draw() 里按需初始化 EGL（那里已经
     * 有 egl_init_display 的兜底），所以延迟连接对两条路径都成立。
     *
     * 这个缺陷在 Windows/macOS 上不会出现（那边走的是 FlutterTexture 帧回调，
     * 没有 ANativeWindow），只有 Android 真机能暴露。 */
    if (g_egl.window != window) {
        if (g_egl.surface != EGL_NO_SURFACE && g_egl.display != EGL_NO_DISPLAY) {
            eglMakeCurrent(g_egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroySurface(g_egl.display, g_egl.surface);
            g_egl.surface = EGL_NO_SURFACE;
        }
        g_egl.window = (ANativeWindow *)window;
        g_egl.ready = 0;
    }
    pthread_mutex_unlock(&g_egl_lock);
    return LP_OK;
}

int lp_render_resize(LpPlayer *p, int width, int height)
{
    (void)p;
    pthread_mutex_lock(&g_egl_lock);
    g_egl.view_w = width;
    g_egl.view_h = height;
    if (g_egl.surface != EGL_NO_SURFACE) {
        eglMakeCurrent(g_egl.display, g_egl.surface, g_egl.surface, g_egl.context);
        eglQuerySurface(g_egl.display, g_egl.surface, EGL_WIDTH, &g_egl.view_w);
        eglQuerySurface(g_egl.display, g_egl.surface, EGL_HEIGHT, &g_egl.view_h);
    }
    pthread_mutex_unlock(&g_egl_lock);
    return LP_OK;
}

int lp_render_draw(LpPlayer *p, AVFrame *frame)
{
    if (!frame) {
        return LP_ERR_ARGUMENT;
    }
    pthread_mutex_lock(&g_egl_lock);
    if (!g_egl.ready || g_egl.surface == EGL_NO_SURFACE) {
        if (g_egl.window && egl_init_display(g_egl.window) == 0) {
            /* ready now */
        } else {
            pthread_mutex_unlock(&g_egl_lock);
            return LP_ERR_AGAIN;
        }
    }
    AVFrame *f = prepare_frame(p, frame);
    if (!f) {
        pthread_mutex_unlock(&g_egl_lock);
        return LP_ERR_CODEC;
    }
    int w = f->width, h = f->height;
    int nv12 = f->format == AV_PIX_FMT_NV12;
    glActiveTexture(GL_TEXTURE0);
    egl_upload_plane(g_egl.tex[0], 0, f->data[0], f->linesize[0], h, GL_LUMINANCE, w);
    if (nv12) {
        egl_upload_plane(g_egl.tex[1], 1, f->data[1], f->linesize[1], h / 2, GL_LUMINANCE_ALPHA,
                         w / 2);
    } else {
        egl_upload_plane(g_egl.tex[1], 1, f->data[1], f->linesize[1], h / 2, GL_LUMINANCE, w / 2);
        egl_upload_plane(g_egl.tex[2], 2, f->data[2], f->linesize[2], h / 2, GL_LUMINANCE, w / 2);
    }

    int vw = g_egl.view_w > 0 ? g_egl.view_w : w;
    int vh = g_egl.view_h > 0 ? g_egl.view_h : h;
    glViewport(0, 0, vw, vh);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    float sx = 1.f, sy = 1.f;
    float fit = 1.f;
    float fw = (float)w, fh = (float)h;
    float scale_w = (float)vw / fw;
    float scale_h = (float)vh / fh;
    switch (p->vout.scale_mode) {
    case LP_SCALE_FILL: fit = scale_w > scale_h ? scale_w : scale_h; break;
    case LP_SCALE_STRETCH:
        sx = 1.f;
        sy = 1.f;
        break;
    default: fit = scale_w < scale_h ? scale_w : scale_h; break;
    }
    if (p->vout.scale_mode != LP_SCALE_STRETCH) {
        sx = (fw * fit) / (float)vw;
        sy = (fh * fit) / (float)vh;
    }

    const float verts[] = {
        -sx, -sy, 0.f, 1.f, /* pos, tex */
        sx,  -sy, 1.f, 1.f,
        -sx, sy,  0.f, 0.f,
        sx,  sy,  1.f, 0.f,
    };
    glUseProgram(g_egl.program);
    glUniform1i(glGetUniformLocation(g_egl.program, "u_nv12"), nv12 ? 1 : 0);
    glVertexAttribPointer((GLuint)g_egl.attr_pos, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), verts);
    glEnableVertexAttribArray((GLuint)g_egl.attr_pos);
    glVertexAttribPointer((GLuint)g_egl.attr_tex, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          verts + 2);
    glEnableVertexAttribArray((GLuint)g_egl.attr_tex);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    eglSwapBuffers(g_egl.display, g_egl.surface);

    g_egl.frame_w = w;
    g_egl.frame_h = h;
    g_egl.pix_fmt = nv12;
    pthread_mutex_unlock(&g_egl_lock);

    p->vout.frame_w = w;
    p->vout.frame_h = h;
    p->vout.frames_published++;
    return LP_OK;
}

int lp_render_publish_pixel_buffer(LpPlayer *p, void *cv_pixel_buffer)
{
    (void)p;
    (void)cv_pixel_buffer;
    return LP_ERR_UNSUPPORTED;
}

void lp_render_close(LpPlayer *p)
{
    (void)p;
    pthread_mutex_lock(&g_egl_lock);
    if (g_egl.display) {
        eglMakeCurrent(g_egl.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_egl.surface != EGL_NO_SURFACE) {
            eglDestroySurface(g_egl.display, g_egl.surface);
            g_egl.surface = EGL_NO_SURFACE;
        }
        if (g_egl.context) {
            eglDestroyContext(g_egl.display, g_egl.context);
            g_egl.context = EGL_NO_CONTEXT;
        }
        if (g_egl.ready) {
            glDeleteTextures(3, g_egl.tex);
            if (g_egl.program) {
                glDeleteProgram(g_egl.program);
                g_egl.program = 0;
            }
        }
        eglTerminate(g_egl.display);
        g_egl.display = EGL_NO_DISPLAY;
    }
    if (g_egl.sws) {
        sws_freeContext(g_egl.sws);
        g_egl.sws = NULL;
    }
    free(g_egl.conv[0]);
    g_egl.conv[0] = NULL;
    g_egl.ready = 0;
    g_egl.window = NULL;
    pthread_mutex_unlock(&g_egl_lock);
}

void *lp_player_copy_pixel_buffer(LpPlayer *p)
{
    (void)p;
    return NULL;
}

#endif /* __ANDROID__ */
