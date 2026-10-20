/*
 * <sys/socket.h> for libsmb2 on mingw-w64.
 *
 * Replaces libsmb2's include/msvc/sys/socket.h, whose `inline int close()`
 * definitions create an external symbol in every translation unit (ISO C inline
 * semantics) and collide at link time.  Here the wrappers are named lp_win_*
 * and exposed through macros, so no symbol is emitted.
 */
#ifndef LIBSMB2_WIN32_SYS_SOCKET_H
#define LIBSMB2_WIN32_SYS_SOCKET_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <stdint.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <libsmb2.h> /* t_socket */

#ifndef EBADF
#define EBADF WSAENOTSOCK
#endif

typedef SSIZE_T ssize_t;

struct iovec {
    unsigned long iov_len;
    void *iov_base;
};

static __inline int lp_win_writev(t_socket sock, struct iovec *iov, int nvecs)
{
    DWORD written = 0;
    if (WSASend(sock, (LPWSABUF)iov, (DWORD)nvecs, &written, 0, NULL, NULL) == 0) {
        return (int)written;
    }
    return -1;
}

static __inline int lp_win_readv(t_socket sock, struct iovec *iov, int nvecs)
{
    DWORD read = 0;
    DWORD flags = 0;
    if (WSARecv(sock, (LPWSABUF)iov, (DWORD)nvecs, &read, &flags, NULL, NULL) == 0) {
        return (int)read;
    }
    return -1;
}

static __inline int lp_win_close(t_socket sock)
{
    return closesocket(sock);
}

#define writev(sock, iov, nvecs) lp_win_writev((sock), (iov), (nvecs))
#define readv(sock, iov, nvecs) lp_win_readv((sock), (iov), (nvecs))
#define close(sock) lp_win_close((sock))

#endif
