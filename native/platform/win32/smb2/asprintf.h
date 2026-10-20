/*
 * Replaces libsmb2's include/asprintf.h on mingw-w64.
 *
 * The upstream header guards its fallback implementations with `#ifndef
 * vasprintf`, which only tests for a *macro*; mingw's <stdio.h> declares real
 * functions with those names, so the static inline definitions collide.  Here
 * the fallbacks live under lp_* names and the POSIX names are macros, which
 * keeps call sites in libsmb2 unchanged and avoids the conflict.
 */
#ifndef LIBSMB2_WIN32_ASPRINTF_H
#define LIBSMB2_WIN32_ASPRINTF_H

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

static __inline int lp_vasprintf(char **strp, const char *fmt, va_list ap)
{
    va_list copy;
    va_copy(copy, ap);
    int len = vsnprintf(NULL, 0, fmt, copy);
    va_end(copy);
    if (len < 0) {
        return -1;
    }
    char *buf = malloc((size_t)len + 1);
    if (!buf) {
        return -1;
    }
    if (vsnprintf(buf, (size_t)len + 1, fmt, ap) < 0) {
        free(buf);
        return -1;
    }
    *strp = buf;
    return len;
}

static __inline int lp_asprintf(char **strp, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = lp_vasprintf(strp, fmt, ap);
    va_end(ap);
    return r;
}

#define vasprintf(strp, ap) lp_vasprintf((strp), (ap))
#define asprintf(...) lp_asprintf(__VA_ARGS__)

#endif
