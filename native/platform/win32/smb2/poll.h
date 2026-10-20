/* <poll.h> for libsmb2 on mingw-w64: WSAPoll with the POSIX signature. */
#ifndef LIBSMB2_WIN32_POLL_H
#define LIBSMB2_WIN32_POLL_H

#include <sys/socket.h>

static __inline int lp_win_poll(struct pollfd pfd[], uint32_t size, int timeout_ms)
{
    return WSAPoll(pfd, size, timeout_ms);
}

#define poll(fds, nfds, timeout) lp_win_poll((fds), (nfds), (timeout))

#endif
