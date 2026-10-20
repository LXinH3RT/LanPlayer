/* mingw-w64 has no <netdb.h>; getaddrinfo/freeaddrinfo come from ws2tcpip.h. */
#ifndef LIBSMB2_WIN32_NETDB_H
#define LIBSMB2_WIN32_NETDB_H

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

#endif
