/* net_compat.h —— 跨平台网络薄垫层（Windows Winsock2 / POSIX sockets）
 *
 * P2P 实验室的第一个教学点就是它：Berkeley socket 在两个世界的细微差异
 * （初始化、类型、线程、超时选项）被一层薄薄的抽象抹平——这正是 lwIP 的
 * sys_arch 缝合层在宿主机上的微缩版（见 lwIP 系列第十四章）。
 * 各工程自带一份拷贝，保证在代码浏览页里单工程自洽可读。
 */
#ifndef NET_COMPAT_H
#define NET_COMPAT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32

#include <winsock2.h>
#include <ws2tcpip.h>
#include <process.h>
typedef int socklen_t;
#define CLOSE_SOCK(s) closesocket(s)

static void net_init(void)
{
    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
}
static void net_cleanup(void) { WSACleanup(); }

/* 线程：_beginthread 的函数签名恰好是 void(*)(void*) */
static int thread_start(void (*fn)(void *), void *arg)
{
    uintptr_t h = _beginthread(fn, 0, arg);
    return h == (uintptr_t)-1 ? -1 : 0;
}

#else /* POSIX */

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <pthread.h>
typedef int SOCKET;
#define INVALID_SOCKET (-1)
#define CLOSE_SOCK(s) close(s)

static void net_init(void) {}
static void net_cleanup(void) {}

/* 用蹦床函数把 void(*)(void*) 适配成 pthread 要求的 void*(*)(void*) */
struct thread_pair {
    void (*fn)(void *);
    void *arg;
};
static void *thread_trampoline(void *p)
{
    struct thread_pair *t = p;
    t->fn(t->arg);
    free(t);
    return NULL;
}
static int thread_start(void (*fn)(void *), void *arg)
{
    struct thread_pair *t = malloc(sizeof *t);
    if (!t)
        return -1;
    t->fn = fn;
    t->arg = arg;
    pthread_t th;
    if (pthread_create(&th, NULL, thread_trampoline, t) != 0) {
        free(t);
        return -1;
    }
    pthread_detach(th);
    return 0;
}

#endif

/* 接收超时：Windows 用 DWORD 毫秒，POSIX 用 timeval——统一成毫秒入参 */
static int set_rcvtimeo(SOCKET s, int ms)
{
#ifdef _WIN32
    DWORD t = (DWORD)ms;
    return setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&t, sizeof t);
#else
    struct timeval tv = { ms / 1000, (ms % 1000) * 1000 };
    return setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof tv);
#endif
}

#endif /* NET_COMPAT_H */
