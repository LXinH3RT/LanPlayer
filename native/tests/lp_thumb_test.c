/* Thumbnail regression test — 守住「打开含视频的文件夹卡死」这一类缺陷。
 *
 *   lp_thumb_test <media>...
 *
 * 对每个文件调用 lp_source_thumbnail()，断言：
 *   1. 在预算时间内返回（绝不允许挂起）；
 *   2. 返回的尺寸合法（0 < w <= max_width，h > 0）；
 *   3. 像素不全是同一个值（纯黑/纯空的占位帧算失败）。
 *
 * 为什么单独写一个：用户报的「打开含 .flv 的文件夹卡死」根因在
 * lp_io_read() 的缓存边界空转 + av_seek_frame 传错时间基，只有真拿一个
 * flv 跑一遍才暴露。smoke test 只测播放路径，覆盖不到封面路径。
 *
 * 退出码：0 全部通过；1 有失败。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lanplayer/lp_log.h"
#include "lanplayer/lp_player.h"

#if defined(_WIN32)
#include <windows.h>
#endif

/* 单个封面的墙钟预算。内核内部也有 4 s 的中断预算，这里留一点余量。
 * 超过这个时间就说明又出现了死循环。 */
#define LP_THUMB_TEST_BUDGET_MS 8000

static int64_t now_ms(void)
{
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <media>...\n", argv[0]);
        return 2;
    }

    int failures = 0;
    for (int i = 1; i < argc; i++) {
        const char *path = argv[i];
        void *pixels = NULL;
        int32_t w = 0, h = 0;
        int64_t t0 = now_ms();
        int32_t rc = lp_source_thumbnail(path, NULL, 128, &pixels, &w, &h);
        int64_t dt = now_ms() - t0;

        if (dt > LP_THUMB_TEST_BUDGET_MS) {
            fprintf(stderr, "FAIL %s: took %lld ms (budget %d ms) -- 可能又是死循环\n",
                    path, (long long)dt, LP_THUMB_TEST_BUDGET_MS);
            failures++;
            if (pixels) lp_pixels_free(pixels);
            continue;
        }
        if (rc != 0 || !pixels) {
            fprintf(stderr, "FAIL %s: rc=%d (%lld ms)\n", path, (int)rc, (long long)dt);
            failures++;
            continue;
        }
        if (w <= 0 || w > 128 || h <= 0) {
            fprintf(stderr, "FAIL %s: bad size %dx%d\n", path, (int)w, (int)h);
            lp_pixels_free(pixels);
            failures++;
            continue;
        }
        /* 像素不能是一整片同色：那通常是没解出真帧的占位图。 */
        const uint8_t *p = (const uint8_t *)pixels;
        int differs = 0;
        for (int32_t y = 0; y < h && !differs; y++) {
            for (int32_t x = 0; x < w; x++) {
                const uint8_t *px = p + ((size_t)y * w + x) * 4;
                if (px[0] != p[0] || px[1] != p[1] || px[2] != p[2]) {
                    differs = 1;
                    break;
                }
            }
        }
        if (!differs) {
            fprintf(stderr, "FAIL %s: uniform pixels (占位帧)\n", path);
            lp_pixels_free(pixels);
            failures++;
            continue;
        }
        printf("ok   %s -> %dx%d in %lld ms\n", path, (int)w, (int)h, (long long)dt);
        lp_pixels_free(pixels);
    }

    if (failures) {
        fprintf(stderr, "\n%d case(s) failed\n", failures);
        return 1;
    }
    printf("\nall thumbnail cases passed\n");
    return 0;
}
