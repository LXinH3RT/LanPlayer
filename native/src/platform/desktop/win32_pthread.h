/*
 * Minimal pthread compatibility layer for native Windows builds.
 *
 * The mobile targets (Android/iOS) use the real pthreads from their libc.  Zig's
 * bundled mingw-w64 does not ship winpthreads, and we only need threads,
 * mutexes and condition variables, so this header maps them onto Win32
 * primitives instead of pulling in another toolchain:
 *
 *   pthread_mutex_t -> SRWLOCK               (statically initialisable)
 *   pthread_cond_t  -> CONDITION_VARIABLE    (statically initialisable)
 *   pthread_t       -> HANDLE
 *
 * Semantics match what the core relies on: non-recursive mutexes, absolute
 * CLOCK_REALTIME deadlines for pthread_cond_timedwait, and joinable threads.
 */
#ifndef LANPLAYER_WIN32_PTHREAD_H
#define LANPLAYER_WIN32_PTHREAD_H

#if !defined(_WIN32) || defined(LP_HAVE_PTHREAD)
#error "win32_pthread.h is for Windows builds without winpthreads"
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <errno.h>
#include <stdint.h>
#include <time.h>

/* mingw-w64 exposes these as _-prefixed CRT functions. */
#include <io.h>
#include <sys/stat.h>
#ifndef fileno
#define fileno _fileno
#endif
#ifndef fstat
#define fstat _fstat64
#endif
#ifndef strcasecmp
#define strcasecmp _stricmp
#endif
#ifndef strncasecmp
#define strncasecmp _strnicmp
#endif

typedef SRWLOCK pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;
typedef HANDLE pthread_t;

#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT
#define PTHREAD_COND_INITIALIZER CONDITION_VARIABLE_INIT

static inline int pthread_mutex_init(pthread_mutex_t *m, const void *attr)
{
    (void)attr;
    InitializeSRWLock(m);
    return 0;
}

static inline int pthread_mutex_destroy(pthread_mutex_t *m)
{
    (void)m;
    return 0;
}

static inline int pthread_mutex_lock(pthread_mutex_t *m)
{
    AcquireSRWLockExclusive(m);
    return 0;
}

static inline int pthread_mutex_unlock(pthread_mutex_t *m)
{
    ReleaseSRWLockExclusive(m);
    return 0;
}

static inline int pthread_cond_init(pthread_cond_t *c, const void *attr)
{
    (void)attr;
    InitializeConditionVariable(c);
    return 0;
}

static inline int pthread_cond_destroy(pthread_cond_t *c)
{
    (void)c;
    return 0;
}

static inline int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m)
{
    if (!SleepConditionVariableSRW(c, m, INFINITE, 0)) {
        return EINVAL;
    }
    return 0;
}

/* Converts an absolute CLOCK_REALTIME deadline into a relative timeout. */
static inline DWORD lp_win32_ms_until(const struct timespec *deadline)
{
    FILETIME ft;
    ULARGE_INTEGER now;
    GetSystemTimeAsFileTime(&ft);
    now.LowPart = ft.dwLowDateTime;
    now.HighPart = ft.dwHighDateTime;
    /* FILETIME is 100 ns ticks since 1601; timespec is since 1970. */
    const uint64_t epoch_diff = 116444736000000000ULL;
    uint64_t now_ticks = now.QuadPart;
    uint64_t want = (uint64_t)deadline->tv_sec * 10000000ULL +
                    (uint64_t)deadline->tv_nsec / 100ULL + epoch_diff;
    if (want <= now_ticks) {
        return 0;
    }
    uint64_t ms = (want - now_ticks) / 10000ULL;
    return ms > 0xFFFFFFFEULL ? 0xFFFFFFFEUL : (DWORD)ms;
}

static inline int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m,
                                         const struct timespec *deadline)
{
    DWORD ms = lp_win32_ms_until(deadline);
    if (!SleepConditionVariableSRW(c, m, ms, 0)) {
        return (GetLastError() == ERROR_TIMEOUT) ? ETIMEDOUT : EINVAL;
    }
    return 0;
}

static inline int pthread_cond_signal(pthread_cond_t *c)
{
    WakeConditionVariable(c);
    return 0;
}

static inline int pthread_cond_broadcast(pthread_cond_t *c)
{
    WakeAllConditionVariable(c);
    return 0;
}

static inline int pthread_create(pthread_t *thread, const void *attr,
                                 void *(*start)(void *), void *arg)
{
    (void)attr;
    HANDLE h = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)start, arg, 0, NULL);
    if (!h) {
        return EAGAIN;
    }
    *thread = h;
    return 0;
}

static inline int pthread_join(pthread_t thread, void **retval)
{
    (void)retval;
    if (!thread) {
        return EINVAL;
    }
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
    return 0;
}

/* The core never detaches; provided so the API surface looks complete. */
static inline int pthread_detach(pthread_t thread)
{
    if (thread) {
        CloseHandle(thread);
    }
    return 0;
}

/* clock_gettime(CLOCK_REALTIME) -> timespec_get(TIME_UTC).
 * mingw-w64 has no clockid_t, so the id is a plain int here. */
#ifndef LP_WIN32_NO_CLOCK_GETTIME
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#endif
static inline int lp_win32_clock_gettime(int id, struct timespec *ts)
{
    (void)id;
    return timespec_get(ts, TIME_UTC) == TIME_UTC ? 0 : -1;
}
#define clock_gettime(id, ts) lp_win32_clock_gettime((int)(id), (ts))
#endif

#endif /* LANPLAYER_WIN32_PTHREAD_H */
