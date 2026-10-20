/*
 * LanPlayer native core - internal structure shared by the core sources.
 *
 * Layout of the pipeline:
 *
 *   LpSource -> AVIOContext -> demux thread -> [video|audio|subtitle] packet
 *   queues -> decoder threads -> frame queue / PCM ring -> sinks
 *
 * The demux thread is the only owner of AVFormatContext; a seek is requested
 * from the UI thread and executed there, which is why every queue carries a
 * `serial` that is bumped on seek so that stale frames can be dropped.
 */
#ifndef LANPLAYER_PLAYER_INTERNAL_H
#define LANPLAYER_PLAYER_INTERNAL_H

#include <ctype.h>
#include <errno.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

/* Threads: real pthreads on Android/iOS/macOS/Linux, a small Win32 mapping for
 * native Windows builds (see platform/desktop/win32_pthread.h). */
#if defined(_WIN32) && !defined(LP_HAVE_PTHREAD)
#include "platform/desktop/win32_pthread.h"
#else
#include <pthread.h>
#endif

#include "lanplayer/lp_log.h"
#include "lanplayer/lp_player.h"
#include "lanplayer/lp_source.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__ANDROID__)
#define LP_PLATFORM_ANDROID 1
#elif defined(__APPLE__)
#define LP_PLATFORM_APPLE 1
#else
#define LP_PLATFORM_DESKTOP 1
#endif

#define LP_MAX_QUEUED_PACKETS 4096
#define LP_MAX_PACKET_BYTES (256 * 1024 * 1024)
#define LP_MIN_PACKET_BYTES (512 * 1024)
#define LP_VIDEO_FRAME_QUEUE 24
#define LP_DEFAULT_AUDIO_LATENCY_MS 120
#define LP_POSITION_INTERVAL_US 200000
#define LP_TICK_INTERVAL_US 20000
#define LP_STATS_INTERVAL_US 1000000
#define LP_MAX_SUBTITLE_TRACKS 16
#define LP_MAX_EXTERNAL_SUBS 8
#define LP_MAX_TEXT_BYTES 8192

#define LP_TIME_BASE 1000000.0 /* microseconds per second */

/* ------------------------------------------------------------------ util */

typedef struct LpStr {
    char *p;
    size_t len;
    size_t cap;
} LpStr;

void lp_str_init(LpStr *s);
void lp_str_free(LpStr *s);
void lp_str_reset(LpStr *s);
void lp_str_append(LpStr *s, const char *fmt, ...);
void lp_str_append_json_str(LpStr *s, const char *v); /* NULL -> "" */
char *lp_str_take(LpStr *s);                          /* ownership moves out */
char *lp_str_dup(const char *v);
char *lp_str_printf(const char *fmt, ...);

/* Minimal flat JSON reader for option objects (no nesting except arrays of
 * strings).  Returns 0 on success, -1 when the key is absent. */
int lp_json_get_str(const char *json, const char *key, char *out, size_t outlen);
int lp_json_get_int(const char *json, const char *key, int64_t *out);
int lp_json_get_bool(const char *json, const char *key, int *out);
/* Fills `out` with up to `max` strings; caller frees each with free(). */
int lp_json_get_string_array(const char *json, const char *key, char **out, int max);
/* Collects every string value stored under key (any nesting depth). */
int lp_json_collect_strings(const char *json, const char *key, char **out, int max);

/* ----------------------------------------------------------------- clock */

typedef struct LpClock {
    double pts;         /* last set position, in media seconds */
    double pts_drift;   /* pts - wall at the moment it was set */
    double last_updated;
    double speed;
    int serial;
    int paused;
    pthread_mutex_t mutex;
} LpClock;

void lp_clock_init(LpClock *c);
void lp_clock_destroy(LpClock *c);
void lp_clock_set(LpClock *c, double pts_seconds, int serial);
void lp_clock_set_speed(LpClock *c, double speed);
double lp_clock_get(LpClock *c);
double lp_clock_get_raw(LpClock *c);
void lp_clock_sync(LpClock *c, double pts_seconds); /* gentle drift correction */
void lp_clock_pause(LpClock *c, int paused);

/* ---------------------------------------------------------------- queues */

typedef struct LpPacketNode {
    AVPacket *pkt;
    struct LpPacketNode *next;
} LpPacketNode;

typedef struct LpPacketQueue {
    LpPacketNode *head;
    LpPacketNode *tail;
    int nb_packets;
    int64_t bytes;
    int64_t max_bytes;
    int abort_request;
    int eof;
    int serial;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} LpPacketQueue;

void lp_pq_init(LpPacketQueue *q, int64_t max_bytes);
void lp_pq_destroy(LpPacketQueue *q);
void lp_pq_flush(LpPacketQueue *q);
void lp_pq_abort(LpPacketQueue *q);
void lp_pq_start(LpPacketQueue *q);
/* Takes ownership of `pkt` (refcounted).  Returns 0 or LP_ERR_IO on abort. */
int lp_pq_put(LpPacketQueue *q, AVPacket *pkt, int serial);
/* Blocking unless `block` is 0.  Returns NULL on abort/EOF-empty. */
AVPacket *lp_pq_get(LpPacketQueue *q, int *serial, int block);
void lp_pq_signal_eof(LpPacketQueue *q, int serial);
int lp_pq_size(LpPacketQueue *q);
int lp_pq_eof(LpPacketQueue *q);

/* ------------------------------------------------------------ audio ring */

typedef struct LpAudioMarker {
    int64_t sample;      /* ring play head sample index of the chunk start */
    double pts_seconds;  /* media (content) time of that sample */
    double scale;        /* content seconds per output second (speed factor) */
} LpAudioMarker;

#define LP_AUDIO_MARKERS 64

typedef struct LpAudioRing {
    float *buf; /* interleaved float32, capacity_frames * channels */
    int channels;
    int capacity_frames;
    int read_pos;
    int write_pos;
    int count; /* frames currently buffered */
    int abort_request;
    int paused;
    int flushing;
    int sample_rate;
    double gain;
    int64_t sample_index;      /* frames pulled by the sink since start */
    LpAudioMarker markers[LP_AUDIO_MARKERS];
    int marker_count;
    int marker_head;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} LpAudioRing;

int lp_ring_init(LpAudioRing *r, int channels, int sample_rate, int latency_ms);
void lp_ring_destroy(LpAudioRing *r);
void lp_ring_flush(LpAudioRing *r);
void lp_ring_abort(LpAudioRing *r);
void lp_ring_set_paused(LpAudioRing *r, int paused);
void lp_ring_set_gain(LpAudioRing *r, double gain);
/* Writes `frames`; blocks while full (respecting abort).  `chunk_pts_seconds`
 * is the media time of the first sample and `scale` the content/playback rate
 * ratio (1.0 at normal speed, `speed` when atempo stretched the audio).
 * Returns frames written or LP_ERR_INTERRUPTED. */
int lp_ring_write(LpAudioRing *r, const float *interleaved, int frames,
                  double chunk_pts_seconds, double scale);
/* Pull for the sink thread; zero fills the tail.  Returns frames read. */
int lp_ring_read(LpAudioRing *r, float *out, int frames);
double lp_ring_clock_seconds(LpAudioRing *r);
int lp_ring_buffered_ms(LpAudioRing *r, int sample_rate);

/* ------------------------------------------------------------ audio sink */

typedef struct LpAudioSink LpAudioSink;
struct LpPlayer;

LpAudioSink *lp_audio_sink_create(struct LpPlayer *p);
int lp_audio_sink_start(LpAudioSink *s, int sample_rate, int channels);
void lp_audio_sink_stop(LpAudioSink *s);
void lp_audio_sink_pause(LpAudioSink *s, int paused);
void lp_audio_sink_destroy(LpAudioSink *s);
int lp_audio_sink_latency_us(LpAudioSink *s);
const char *lp_audio_sink_name(LpAudioSink *s);
/* Implemented in audio.c, called from the sink's realtime thread. */
int lp_audio_pull_pcm(struct LpPlayer *p, float *out, int frames);

/* --------------------------------------------------------- hardware decode */

typedef enum LpDecodedKind {
    LP_DEC_SURFACE = 1,      /* Android: output buffer waiting for release */
    LP_DEC_PIXEL_BUFFER = 2, /* Apple: retained CVPixelBufferRef */
    LP_DEC_HW_FRAME = 3,     /* Windows: AVFrame still on the D3D11 device */
} LpDecodedKind;

typedef struct LpDecodedFrame {
    int64_t pts_us;
    void *handle;      /* kind specific */
    int index;         /* Android output buffer index */
    int kind;
    int width;
    int height;
} LpDecodedFrame;

typedef struct LpVideoDecoder LpVideoDecoder;
typedef struct LpVideoDecoderConfig {
    AVCodecParameters *par;
    enum AVCodecID codec_id;
    int width;
    int height;
    AVRational time_base;
    void *native_window; /* Android ANativeWindow*, may be NULL */
    void *player;        /* LpPlayer*, used by the Apple texture bridge */
} LpVideoDecoderConfig;

LpVideoDecoder *lp_hw_decoder_create(void);
int lp_hw_decoder_init(LpVideoDecoder *d, const LpVideoDecoderConfig *cfg, char *err, size_t errlen);
int lp_hw_decoder_available(void);
const char *lp_hw_decoder_name(void);
int lp_hw_decoder_send(LpVideoDecoder *d, const AVPacket *pkt);
/* 0 = frame out, LP_ERR_AGAIN = more input needed, <0 fatal */
int lp_hw_decoder_receive(LpVideoDecoder *d, LpDecodedFrame *out);
/* Present at the sync deadline (Android releases the buffer; Apple publishes
 * the pixel buffer to the texture bridge). */
int lp_hw_decoder_present(LpVideoDecoder *d, LpDecodedFrame *f);
void lp_hw_decoder_flush(LpVideoDecoder *d);
void lp_hw_decoder_destroy(LpVideoDecoder *d);

/* ------------------------------------------------------------- video out */

typedef enum LpVideoOutKind {
    LP_VOUT_NONE = 0,
    LP_VOUT_ANDROID_WINDOW = 1, /* surface, rendered by EGL or codec */
    LP_VOUT_APPLE_TEXTURE = 2,  /* CVPixelBuffer pulled by Flutter */
} LpVideoOutKind;

typedef struct LpVideoOut {
    LpVideoOutKind kind;
    void *window; /* ANativeWindow* */
    int window_w;
    int window_h;
    int frame_w;
    int frame_h;
    int scale_mode;
    LpFrameCallback frame_cb;
    void *frame_cb_user;
    void *pixel_buffer; /* retained CVPixelBufferRef of the current frame */
    int has_new_frame;
    int64_t frames_published;
    pthread_mutex_t mutex;
} LpVideoOut;

int lp_render_init(LpPlayer *p);
void lp_render_close(LpPlayer *p);
int lp_render_set_window(LpPlayer *p, void *window, int width, int height);
int lp_render_resize(LpPlayer *p, int width, int height);
/* Software path: convert + draw the frame (Android EGL / desktop BGRA). */
int lp_render_draw(LpPlayer *p, AVFrame *frame);
/* Apple path: store a retained CVPixelBufferRef and notify the host. */
int lp_render_publish_pixel_buffer(LpPlayer *p, void *cv_pixel_buffer);
int lp_render_available(void);
const char *lp_render_name(void);

/* -------------------------------------------------------------- subtitle */

typedef struct LpSubStyle {
    char name[64];          /* ASS style name, "Default" when unnamed */
    int bold;
    int italic;
    int underline;
    int strikeout;
    uint32_t color;         /* 0xAARRGGBB */
    uint32_t outline_color; /* 0xAARRGGBB */
    int outline_width;      /* in "units", UI scales by text size */
    int align;              /* ASS alignment 1..9 (2 = bottom center) */
    double pos_x;           /* 0..1, < 0 for automatic */
    double pos_y;
    double font_scale;      /* fraction of video height, default 0.05 */
    char font_name[64];
} LpSubStyle;

/* Bit flags for LpSubRun::flags. */
#define LP_SUB_BOLD 0x1
#define LP_SUB_ITALIC 0x2
#define LP_SUB_UNDERLINE 0x4
#define LP_SUB_STRIKEOUT 0x8

/* One styled span inside a cue.  A cue with nb_runs == 0 is plain text that
 * inherits the whole cue style; otherwise each run carries the inline
 * overrides an ASS line asked for ({\b1}, {\c&H..&}, {\fs..}, ...). */
typedef struct LpSubRun {
    char *text;        /* owned UTF-8, may contain '\n' */
    unsigned flags;    /* LP_SUB_* */
    uint32_t color;    /* 0 = inherit from the cue style */
    double font_scale; /* 0 = inherit from the cue style */
} LpSubRun;

/* One decoded bitmap subtitle rectangle (PGS / VobSub / DVB).  Pixels are
 * straight-alpha RGBA8; x/y/w/h are in the reference video's pixel grid, which
 * is what libavcodec reports. */
typedef struct LpSubBitmap {
    int x;
    int y;
    int w;
    int h;
    uint8_t *rgba; /* owned, w*h*4 bytes */
} LpSubBitmap;

typedef struct LpSubCue {
    int64_t start_us;
    int64_t end_us;
    int style;
    char *text;       /* UTF-8, '\n' separated, ASS override tags stripped */
    LpSubRun *runs;   /* optional styled spans, owned */
    int nb_runs;
    LpSubBitmap *bitmaps; /* set instead of text for graphics subtitles */
    int nb_bitmaps;
    int align_override; /* ASS 1..9 from {\anN}, 0 = use the style */
    double pos_x;       /* from {\pos(x,y)}, normalised, < 0 = use the style */
    double pos_y;
} LpSubCue;

typedef struct LpSubtitleTrack {
    int index;     /* stream index, or 1000+n for external files */
    int is_external;
    int enabled;   /* selected */
    int embedded;
    char lang[24];
    char title[128];
    char path[512]; /* external source path/url */
    AVCodecContext *avctx; /* embedded text subtitle decoder, may be NULL */
    LpSubCue *cues;
    int nb_cues;
    int cap_cues;
    LpSubStyle *styles;
    int nb_styles;
    int current_cue; /* -1 when nothing on screen */
    int bitmap;      /* graphics subtitles: cues carry LpSubBitmap instead of text */
    int ref_w;       /* reference grid the decoder positions rectangles in */
    int ref_h;
} LpSubtitleTrack;

/* The rectangles currently on screen, flattened into one overlay the renderer
 * blends onto the converted video frame.  Keeping a copy (instead of pointing
 * into the cue array) means history trimming can never invalidate it. */
#define LP_SUB_OVERLAY_MAX 8
typedef struct LpSubOverlayRect {
    int x;
    int y;
    int w;
    int h;
    uint8_t *rgba; /* owned, w*h*4 */
} LpSubOverlayRect;

typedef struct LpSubOverlay {
    LpSubOverlayRect rects[LP_SUB_OVERLAY_MAX];
    int nb;
    int ref_w;
    int ref_h;
    int first; /* index of the first active cue, -1 = nothing on screen */
    int count; /* how many cues were active when this was built */
    int version; /* bumped on every change so renderers can skip the work */
} LpSubOverlay;

typedef struct LpSubtitleState {
    LpSubtitleTrack tracks[LP_MAX_SUBTITLE_TRACKS];
    int nb_tracks;
    int selected;      /* index into tracks, -1 = off */
    int64_t delay_us;
    int dirty;         /* style/selection changed, re-emit */
    LpSubOverlay overlay;
    pthread_mutex_t mutex;
} LpSubtitleState;

/* ----------------------------------------------------------------- video */

typedef struct LpVideoStream {
    int stream_index;
    AVCodecContext *avctx;
    LpPacketQueue pq;
    pthread_t thread;
    int thread_started;
    int64_t last_pts_us;
    double frame_duration;
    int width;
    int height;
    enum AVPixelFormat pix_fmt;
    int hw_active;
    const char *hw_name;
    atomic_int eof;
    int64_t frames_decoded;
    int64_t frames_dropped;
    LpVideoDecoder *hw; /* non-NULL when decoding on the platform decoder */
    /* deinterlace / enhancement filter chain, created lazily */
    AVFilterGraph *fg;
    AVFilterContext *fg_src;
    AVFilterContext *fg_sink;
    AVFrame *filtered;
    double last_fps_sample_t;
    int64_t last_fps_frames;
    double fps;
} LpVideoStream;

typedef struct LpAudioStream {
    int stream_index;
    AVCodecContext *avctx;
    LpPacketQueue pq;
    pthread_t thread;
    int thread_started;
    struct SwrContext *swr;
    int out_rate;
    int out_channels;
    LpAudioRing ring;
    AVFilterGraph *graph; /* atempo chain for speed changes */
    AVFilterContext *filt_src;
    AVFilterContext *filt_sink;
    atomic_int graph_dirty;
    double applied_speed;
    atomic_int eof;
    int draining;
    int64_t frames_decoded;
} LpAudioStream;

/* ---------------------------------------------------------------- player */

typedef enum LpHwMode {
    LP_HW_AUTO = 0,
    LP_HW_SOFTWARE = 1,
    LP_HW_FORCED = 2, /* platform name was given explicitly */
} LpHwMode;

/* Forward declaration: the player owns a transport handle. */
typedef struct LpIo LpIo;

struct LpPlayer {
    pthread_mutex_t lock;
    atomic_int state;
    atomic_int abort_request;
    int opened;
    int playing;

    char *url;
    char *options_json;
    LpSourceOptions sopts;

    LpIo *io; /* custom AVIO for SMB/local; NULL for FFmpeg native protocols */
    AVFormatContext *fmt;

    LpEventCallback event_cb;
    void *event_user;

    pthread_t demux_thread;
    int demux_started;
    pthread_t open_thread;
    int open_started;
    pthread_t tick_thread;
    int tick_started;
    int64_t read_timeout_ms;

    LpVideoStream video;
    LpAudioStream audio;
    LpSubtitleState subs;
    int subs_inited;
    LpAudioSink *sink;

    LpClock ac;
    LpClock extc;
    int sync_mode; /* 0 = audio master (default), 1 = external clock */
    double speed;
    float volume;
    int muted;

    LpVideoOut vout;
    int deinterlace;
    int hw_mode;
    char hw_forced_name[32];

    int64_t duration_us;
    int64_t start_us;      /* container start_time, used to normalise timestamps */
    int64_t seek_start_us; /* position requested by the caller on open */
    atomic_int serial;

    /* seek request, consumed by the demux thread */
    atomic_int seek_req;
    int64_t seek_target_us;
    atomic_llong position_us;

    atomic_int eos_demux;
    int eos_audio;
    int eos_video;

    /* stats */
    int64_t stats_frames;
    int64_t stats_dropped;
    double stats_fps;
    double stats_av_diff;
    int64_t stats_last_emit_us;
    int64_t stats_last_frames;
    double stats_last_time;
    int buffering;
};

/* player.c helpers used by the other modules */
void lp_emit_event(LpPlayer *p, int event, const char *json_fmt, ...);

void lp_set_state(LpPlayer *p, LpState state);
LpState lp_get_state(LpPlayer *p);
void lp_emit_error(LpPlayer *p, int code, const char *fmt, ...);
char *lp_media_info_json(LpPlayer *p);
void lp_note_position(LpPlayer *p, int64_t position_us);
int64_t lp_master_clock_us(LpPlayer *p);
void lp_request_seek(LpPlayer *p, int64_t target_us);
int lp_is_abort(LpPlayer *p);
void lp_emit_buffering(LpPlayer *p, int buffering, int percent);

/* demux.c */
int lp_demux_open(LpPlayer *p);

void *lp_demux_thread_fn(void *arg);

/* video.c */
int lp_video_start(LpPlayer *p);
void lp_video_stop(LpPlayer *p);
void *lp_video_thread_fn(void *arg);


/* audio.c */
int lp_audio_start(LpPlayer *p);
void lp_audio_stop(LpPlayer *p);
void *lp_audio_thread_fn(void *arg);
double lp_audio_clock_seconds(LpPlayer *p);
void lp_audio_rebuild_graph(LpPlayer *p);
int lp_audio_buffered_ms(LpPlayer *p);

/* subtitle.c */
int lp_subtitle_open(LpPlayer *p);
void lp_subtitle_close(LpPlayer *p);
void lp_subtitle_tick(LpPlayer *p, int64_t now_us);
int lp_subtitle_add_file(LpPlayer *p, const char *url, const char *options_json);
void lp_subtitle_select(LpPlayer *p, int track_index);
void lp_subtitle_set_delay(LpPlayer *p, int64_t delay_ms);
void lp_subtitle_seek(LpPlayer *p, int64_t pos_us);
void lp_subtitle_feed_packet(LpPlayer *p, int stream_index, AVPacket *pkt);
/* Blends the graphics-subtitle overlay onto a converted BGRA picture.  The
 * renderer calls this right after sws_scale, with no other locks held. */
void lp_sub_overlay_blend(LpPlayer *p, uint8_t *bgra, int w, int h, int stride);

/* source layer (see src/source) */
typedef struct LpIo LpIo;
LpIo *lp_io_open(const char *url, const LpSourceOptions *opts, char *err, size_t errlen);
void lp_io_close(LpIo *io);
int lp_io_read(LpIo *io, uint8_t *buf, int size);
int64_t lp_io_seek(LpIo *io, int64_t offset, int whence);
int64_t lp_io_size(LpIo *io);
/* Attach as AVFormatContext custom IO; returns 0 on success. */
int lp_io_attach_avio(LpIo *io, AVFormatContext **fmt, char *err, size_t errlen);
int lp_io_interrupt(void *user);
void lp_io_abort(LpIo *io);

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_PLAYER_INTERNAL_H */
