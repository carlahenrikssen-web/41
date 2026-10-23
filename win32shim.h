#ifndef TP_WIN32SHIM_H
#define TP_WIN32SHIM_H
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <io.h>
#include <direct.h>
#include <stdint.h>
static __inline int usleep(unsigned __int32 usec)
{
    DWORD ms = (DWORD)(usec / 1000);
    Sleep(ms ? ms : 1);
    return 0;
}
static __inline unsigned sleep(unsigned sec)
{
    Sleep((DWORD)sec * 1000);
    return 0;
}
#endif
#endif
