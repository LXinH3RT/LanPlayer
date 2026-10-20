/* String builder and the minimal JSON reader used for option objects. */
#include <ctype.h>
#include <stdarg.h>
#include <stdlib.h>

#include "player_internal.h"

static int lp_str_reserve(LpStr *s, size_t extra)
{
    size_t need = s->len + extra + 1;
    if (need <= s->cap) {
        return 0;
    }
    size_t cap = s->cap ? s->cap : 128;
    while (cap < need) {
        cap *= 2;
    }
    char *p = realloc(s->p, cap);
    if (!p) {
        return -1;
    }
    s->p = p;
    s->cap = cap;
    return 0;
}

void lp_str_init(LpStr *s)
{
    memset(s, 0, sizeof(*s));
}

void lp_str_free(LpStr *s)
{
    free(s->p);
    memset(s, 0, sizeof(*s));
}

void lp_str_reset(LpStr *s)
{
    s->len = 0;
    if (s->p) {
        s->p[0] = '\0';
    }
}

void lp_str_append(LpStr *s, const char *fmt, ...)
{
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n <= 0) {
        va_end(ap2);
        return;
    }
    if (lp_str_reserve(s, (size_t)n) != 0) {
        va_end(ap2);
        return;
    }
    vsnprintf(s->p + s->len, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    s->len += (size_t)n;
}

void lp_str_append_json_str(LpStr *s, const char *v)
{
    lp_str_append(s, "\"");
    if (v) {
        for (const unsigned char *p = (const unsigned char *)v; *p; p++) {
            switch (*p) {
            case '"': lp_str_append(s, "\\\""); break;
            case '\\': lp_str_append(s, "\\\\"); break;
            case '\n': lp_str_append(s, "\\n"); break;
            case '\r': lp_str_append(s, "\\r"); break;
            case '\t': lp_str_append(s, "\\t"); break;
            case '\b': lp_str_append(s, "\\b"); break;
            case '\f': lp_str_append(s, "\\f"); break;
            default:
                if (*p < 0x20) {
                    lp_str_append(s, "\\u%04x", *p);
                } else {
                    lp_str_append(s, "%c", *p);
                }
            }
        }
    }
    lp_str_append(s, "\"");
}

char *lp_str_take(LpStr *s)
{
    char *p = s->p;
    if (!p) {
        return lp_str_dup("");
    }
    s->p = NULL;
    s->len = s->cap = 0;
    return p;
}

char *lp_str_dup(const char *v)
{
    if (!v) {
        return NULL;
    }
    size_t n = strlen(v);
    char *p = malloc(n + 1);
    if (p) {
        memcpy(p, v, n + 1);
    }
    return p;
}

char *lp_str_printf(const char *fmt, ...)
{
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n <= 0) {
        va_end(ap2);
        return NULL;
    }
    char *p = malloc((size_t)n + 1);
    if (p) {
        vsnprintf(p, (size_t)n + 1, fmt, ap2);
    }
    va_end(ap2);
    return p;
}

/* --------------------------------------------------------------- JSON --- */

static const char *skip_ws(const char *p)
{
    while (p && *p && isspace((unsigned char)*p)) {
        p++;
    }
    return p;
}

/* Walks a JSON object and returns the raw value pointer for a top level key. */
static const char *find_key(const char *json, const char *key)
{
    if (!json || !key) {
        return NULL;
    }
    const char *p = json;
    int depth = 0;
    size_t keylen = strlen(key);
    while (*p) {
        if (*p == '"') {
            const char *start = ++p;
            while (*p && *p != '"') {
                if (*p == '\\' && p[1]) {
                    p++;
                }
                p++;
            }
            size_t len = (size_t)(p - start);
            if (*p == '"') {
                p++;
            }
            if (depth == 1 && len == keylen && strncmp(start, key, keylen) == 0) {
                const char *v = skip_ws(p);
                if (*v == ':') {
                    return skip_ws(v + 1);
                }
            }
            continue;
        }
        if (*p == '{' || *p == '[') {
            depth++;
        } else if (*p == '}' || *p == ']') {
            depth--;
        }
        p++;
    }
    return NULL;
}

static int hex4(const char *p, unsigned *out)
{
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') {
            v |= (unsigned)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            v |= (unsigned)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            v |= (unsigned)(c - 'A' + 10);
        } else {
            return -1;
        }
    }
    *out = v;
    return 0;
}

/* Encodes a code point as UTF-8. */
static void utf8_put(char *out, size_t cap, size_t *len, unsigned cp)
{
    if (cp < 0x80) {
        if (*len + 1 < cap) out[(*len)++] = (char)cp;
    } else if (cp < 0x800) {
        if (*len + 2 < cap) {
            out[(*len)++] = (char)(0xC0 | (cp >> 6));
            out[(*len)++] = (char)(0x80 | (cp & 0x3F));
        }
    } else {
        if (*len + 3 < cap) {
            out[(*len)++] = (char)(0xE0 | (cp >> 12));
            out[(*len)++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[(*len)++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    out[*len] = '\0';
}

static int decode_json_string(const char *p, char *out, size_t outlen)
{
    if (!p || *p != '"') {
        return -1;
    }
    p++;
    size_t len = 0;
    if (outlen == 0) {
        return -1;
    }
    while (*p && *p != '"') {
        char c = *p++;
        if (c != '\\') {
            if (len + 1 < outlen) {
                out[len++] = c;
            }
            continue;
        }
        char e = *p++;
        switch (e) {
        case '"': c = '"'; break;
        case '\\': c = '\\'; break;
        case '/': c = '/'; break;
        case 'b': c = '\b'; break;
        case 'f': c = '\f'; break;
        case 'n': c = '\n'; break;
        case 'r': c = '\r'; break;
        case 't': c = '\t'; break;
        case 'u': {
            unsigned cp = 0;
            if (hex4(p, &cp) != 0) {
                return -1;
            }
            p += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF && p[0] == '\\' && p[1] == 'u') {
                unsigned lo = 0;
                if (hex4(p + 2, &lo) == 0) {
                    p += 6;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                }
            }
            utf8_put(out, outlen, &len, cp);
            continue;
        }
        default:
            return -1;
        }
        if (len + 1 < outlen) {
            out[len++] = c;
        }
    }
    out[len] = '\0';
    return 0;
}

int lp_json_get_str(const char *json, const char *key, char *out, size_t outlen)
{
    const char *v = find_key(json, key);
    if (!v || !out || outlen == 0) {
        return -1;
    }
    if (*v == '"') {
        return decode_json_string(v, out, outlen);
    }
    size_t len = 0;
    while (*v && *v != ',' && *v != '}' && *v != ']' && !isspace((unsigned char)*v)) {
        if (len + 1 < outlen) {
            out[len++] = *v;
        }
        v++;
    }
    out[len] = '\0';
    return len > 0 ? 0 : -1;
}

int lp_json_get_int(const char *json, const char *key, int64_t *out)
{
    char buf[64];
    if (lp_json_get_str(json, key, buf, sizeof(buf)) != 0) {
        return -1;
    }
    if (strcmp(buf, "true") == 0) {
        *out = 1;
        return 0;
    }
    if (strcmp(buf, "false") == 0) {
        *out = 0;
        return 0;
    }
    char *end = NULL;
    long long v = strtoll(buf, &end, 10);
    if (end == buf) {
        return -1;
    }
    *out = (int64_t)v;
    return 0;
}

int lp_json_get_bool(const char *json, const char *key, int *out)
{
    int64_t v = 0;
    if (lp_json_get_int(json, key, &v) != 0) {
        return -1;
    }
    *out = v != 0;
    return 0;
}

int lp_json_get_string_array(const char *json, const char *key, char **out, int max)
{
    const char *v = find_key(json, key);
    int n = 0;
    if (!v || *v != '[') {
        return 0;
    }
    v++;
    while (*v && *v != ']' && n < max) {
        v = skip_ws(v);
        if (*v != '"') {
            break;
        }
        char buf[1024];
        if (decode_json_string(v, buf, sizeof(buf)) != 0) {
            break;
        }
        out[n] = lp_str_dup(buf);
        if (!out[n]) {
            break;
        }
        n++;
        const char *q = v + 1;
        while (*q && *q != '"') {
            if (*q == '\\' && q[1]) {
                q++;
            }
            q++;
        }
        v = (*q == '"') ? q + 1 : q;
        v = skip_ws(v);
        if (*v == ',') {
            v++;
        } else {
            break;
        }
    }
    return n;
}

/* Collects every JSON string value that follows "\"<key>\":" at any depth.
 * Used to walk directory listings without pulling in a JSON parser. */
int lp_json_collect_strings(const char *json, const char *key, char **out, int max)
{
    if (!json || !key || !out || max <= 0) {
        return 0;
    }
    char pattern[160];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    size_t plen = strlen(pattern);
    int n = 0;
    const char *p = json;
    while (*p && n < max) {
        const char *hit = strstr(p, pattern);
        if (!hit) {
            break;
        }
        const char *v = skip_ws(hit + plen);
        if (*v == ':') { /* value separator */
            v = skip_ws(v + 1);
        }
        if (*v != '"') {
            p = hit + plen;
            continue;
        }
        char buf[2048];
        if (decode_json_string(v, buf, sizeof(buf)) != 0) {
            break;
        }
        out[n] = lp_str_dup(buf);
        if (!out[n]) {
            break;
        }
        n++;
        const char *q = v + 1;
        while (*q && *q != '"') {
            if (*q == '\\' && q[1]) {
                q++;
            }
            q++;
        }
        p = (*q == '"') ? q + 1 : q;
    }
    return n;
}
