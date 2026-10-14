/* sockproxy.h —— socket 代理：宿主侧 ws_* API + S3 侧 socket 表（ch06）
 *
 * 控制命令走 ch05 TLV（复用 0x20 段），数据走 DATA 帧；S3 侧表项含
 * 接收水位（背压闸门 1）。本工程两半跑在同一进程：以内存回环传输层
 * 相连（fr_pack/fr_feed 双向），真机只替换传输层实现。
 */
#ifndef SOCKPROXY_H
#define SOCKPROXY_H

#include <stddef.h>
#include <stdint.h>

enum {
    CMD_SOCK_OPEN = 0x20,
    CMD_SOCK_CONNECT,
    CMD_SOCK_SEND,
    CMD_SOCK_RECV,
    CMD_SOCK_CLOSE,
};

/* ---- S3 侧 socket 表（s3sim.c 维护） ---- */
#define S3_MAX_SOCKS 8
#define S3_RX_HIGH_WM 8192 /* 背压闸门 1：停读水位（字节） */
#define S3_RX_LOW_WM 2048

struct s3_sock {
    int used;
    uint16_t sid;
    int connected;
    uint32_t rx_bytes;      /* 累计入缓冲 */
    uint32_t rx_watermark;  /* 观测：最高瞬时水位 */
    int paused;             /* 水位触发的停读标志 */
};

/* ---- 宿主侧 API（ws_*） ---- */
/* 简化同步模型：每个调用内部"打包→过线→等应答"，由 pump 驱动；
 * 真机版换成阻塞信号量/任务，语义同形。 */
struct ws_ctx; /* 前置 */

struct ws_ctx *ws_init(void);
int ws_socket(int type /*0=TCP 1=UDP*/);
int ws_connect(int sid, const uint8_t ip[4], uint16_t port);
int ws_send(int sid, const void *buf, size_t len); /* 全部入队才返回 */
int ws_recv(int sid, void *buf, size_t len);       /* 0=EOF；<0=错误码 */
int ws_close(int sid);
int ws_dns(const char *name, uint8_t ip[4]);

/* 观测口（测试背压用） */
uint32_t ws_peer_watermark(int sid);
uint32_t ws_dropped_udp(int sid);

#endif
