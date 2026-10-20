/*
 * Force-included compat layer for libsmb2 on Windows (mingw-w64 / Zig).
 *
 * Two gaps versus a POSIX libc:
 *   - no srandom()/random()/getlogin_r()
 *   - <netdb.h>, <arpa/inet.h> and <netinet/in.h> live in winsock2.h instead
 *
 * The socket headers are provided as shim files next to this one; the PRNG and
 * login helpers are macro/function shims here.  libsmb2 only uses the PRNG for
 * non-cryptographic identifiers, so mapping it onto rand() is safe.
 */
#ifndef LIBSMB2_WIN32_COMPAT_H
#define LIBSMB2_WIN32_COMPAT_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <stdlib.h>
#include <string.h>
#include <io.h>
#include <process.h>

#include <winsock2.h>
#include <ws2tcpip.h>

#ifndef srandom
#define srandom(seed) srand((unsigned int)(seed))
#endif
#ifndef random
#define random() rand()
#endif
#ifndef getpid
#define getpid() _getpid()
#endif

/* libsmb2 falls back to "Guest" when this fails, which is what we want. */
static __inline int getlogin_r(char *buf, size_t len)
{
    if (buf && len) {
        buf[0] = '\0';
    }
    return -1;
}

#endif /* LIBSMB2_WIN32_COMPAT_H */
