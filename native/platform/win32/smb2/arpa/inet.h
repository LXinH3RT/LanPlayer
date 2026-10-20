/* mingw-w64 has no <arpa/inet.h>; libsmb2 only needs htonl/htonll and friends. */
#ifndef LIBSMB2_WIN32_ARPA_INET_H
#define LIBSMB2_WIN32_ARPA_INET_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

#endif
