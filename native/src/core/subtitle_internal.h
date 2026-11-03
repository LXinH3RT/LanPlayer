/*
 * 字幕子系统内部的共享声明。
 *
 * 上一轮这里只有 subtitle.c 一个 3793 行的文件：ASS/SRT/VTT 解析、样式
 * 继承与 `\r` 覆盖、动画求值、图形字幕的位图管理、轨道状态机、外挂文件
 * 加载，以及给渲染层打包 JSON 全挤在一起。前五轮评审里的字幕缺陷九成
 * 出在这一层，而任何一处改动都要横跨三千行去确认调用方。
 *
 * 现在按职责切成三个编译单元：
 *   subtitle_parse.c —— 解析。纯函数：输入文本或字节，输出 cue 与 run，
 *                       不持锁、不碰播放器状态，可以单独喂数据测。
 *   subtitle_track.c —— 轨道与 overlay。全部在 p->subs.mutex 下运行，
 *                       是这一层唯一有状态的部分。
 *   subtitle.c       —— 打包 JSON 发事件，以及 lp_sub_test_* 行为入口。
 *
 * 下面这些原型由各段的定义行生成，是三条线之间唯一的接口。改动其中任
 * 何一个签名，都意味着一段的类型要跨到另一段去；先想清楚是否真的需要。
 */
#ifndef LP_SUBTITLE_INTERNAL_H
#define LP_SUBTITLE_INTERNAL_H

#include "player_internal.h"

#define LP_SUB_MAX_CUES 200000

/* --------------------------------------------------------------- helpers --- */

/* Context needed to turn ASS script coordinates into something the UI can
 * position: PlayResX/PlayResY from the [Script Info] header. */
typedef struct AssCtx {
    double play_w;
    double play_h;
    const LpSubStyle *base;
} AssCtx;

/* ASS override tags are inline style switches: {\b1}bold{\b0}normal.  Rather
 * than throwing them away (v1 behaviour) we compile a cue into a list of
 * styled runs, which the Flutter overlay renders as TextSpans.  Everything
 * that only affects layout we cannot reproduce (rotation, clipping, blur) is
 * parsed and ignored, which keeps the text itself correct. */

typedef struct SubRunState {
    unsigned flags;
    uint32_t color;         /* 0 = inherit the cue style */
    uint32_t outline_color; /* 0 = inherit; \3c targets this slot */
    uint32_t back_color;    /* 0 = inherit; \4c targets this slot */
    double font_scale; /* 0 = inherit the cue style */
    double scale_x;    /* percent, 0 = inherit */
    double scale_y;    /* percent, 0 = inherit */
    double spacing;    /* script units, 0 = inherit */
    double angle;      /* degrees, 0 = inherit */
    int border;        /* script units, -1 = inherit */
    int shadow;        /* script units, -1 = inherit */
    char font_name[64]; /* empty = inherit the cue style */
    double alpha;       /* 0..1, 1 = opaque */
    /* Karaoke: \k/\kf/\ko accrue durations as the line is walked, so every
     * run knows which slice of the cue it is sung on. */
    double karaoke_cursor_ms;
    double karaoke_pending_ms;
    int karaoke_pending_kind;
    /* \t animations collected on the current run. */
    LpSubAnim *anims;
    int nb_anims;
    int cap_anims;
    /* \clip rectangle in script units. */
    int clip_on;
    int clip_inverse;
    double clip_x1, clip_y1, clip_x2, clip_y2;
    /* \p<n> drawing state. */
    int drawing_scale;
    LpSubPathPoint *path;
    int nb_path;
    int cap_path;
    int path_sub;      /* current subpath index for \p drawings */
} SubRunState;

typedef struct SubRich {
    LpSubCue *cue;
    LpStr plain;
    LpSubRun *runs;
    int nb;
    int cap;
    SubRunState st;
    int drawing; /* inside {\p1} vector drawing: text is coordinates */
} SubRich;

/* ---- 解析段（subtitle_parse.c）---- */
int lp_sub_has_drawing_runs(const LpSubCue *cue);
char *lp_sub_decode_text(const uint8_t *raw, size_t len, size_t *out_len, int *charset_ok);
void lp_sub_rich_init(SubRich *b, LpSubCue *cue);
void lp_sub_rich_free(SubRich *b);
int lp_sub_rich_append(SubRich *b, const char *text, size_t len);
int lp_sub_compile_text(const char *in, LpSubCue *cue, const AssCtx *ctx);
int lp_sub_merge_cue_into(SubRich *dst, LpSubCue *src);
int lp_sub_parse_srt(const char *text, LpSubtitleTrack *t, char *err, size_t errlen);
int lp_sub_parse_ass(const char *text, LpSubtitleTrack *t, char *err, size_t errlen);
int lp_sub_parse_vtt(const char *text, LpSubtitleTrack *t, char *err, size_t errlen);
int lp_sub_split_fields(char *line, char sep, char **fields, int max);
void lp_sub_script_resolution(const char *text, size_t len, double *play_w, double *play_h);

/* ---- 轨道段（subtitle_track.c）---- */
void lp_sub_cue_free(LpSubCue *c);
void lp_sub_style_default(LpSubStyle *s);
int lp_sub_track_ensure_style(LpSubtitleTrack *t, int need);
LpSubStyle *lp_sub_track_style(LpSubtitleTrack *t, int idx);
int lp_sub_track_add_cue_full(LpSubtitleTrack *t, LpSubCue *src);
void lp_sub_track_reset(LpSubtitleTrack *t);
void lp_sub_overlay_reset(LpSubOverlay *ov);
void lp_sub_overlay_update(LpPlayer *p, LpSubtitleTrack *t, int64_t t_now);

#endif /* LP_SUBTITLE_INTERNAL_H */
