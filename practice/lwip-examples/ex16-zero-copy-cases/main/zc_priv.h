/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex16 zero-copy-cases —— 组件内部共享声明（仅本组件可见）
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_timer.h"

#include "lwip/ip_addr.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"

/* ---------------- 端口 ---------------- */
#define PORT_SINK 8330  /* 主服务口（SPEC §4）：基准汇点 / case0 行命令口 */
#define PORT_HOST CONFIG_ZC_HOST_PORT
#define PORT_C_RAW 8332
#define PORT_C_NC 8333
#define PORT_C_SOCK 8334

/* ---------------- 线上记录格式 ----------------
 * magic(4) type(2) seq(4) len(2) hdr_sum(2) body_xsum(4) => 头 18 字节 */
#define REC_HDR_LEN 18
#define REC_HARD_MAX (REC_HDR_LEN + 1448)

#define REC_MAGIC 0x45583136u

#define RT_DATA_A 0x0001u
#define RT_DATA_B 0x0002u
#define RT_CHUNK_D 0x0003u
#define RT_FLAG_E 0x0004u
#define RT_PING_C 0x0005u
#define RT_CTRL_END 0x00F0u
#define RT_CTRL_ACK 0x00F1u
#define RT_VARIANT_ZC 0x8000u

/* 小端字段读写 */
static inline uint16_t zc_rd16(const uint8_t *p)
{
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
static inline uint32_t zc_rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}
static inline void zc_wr16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}
static inline void zc_wr32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

/* 头前 12 字节加权和 / payload 校验和（双方同法） */
uint16_t zc_hdr_sum(const uint8_t *p12);
uint32_t zc_body_xsum(const uint8_t *p, size_t n);

/* 组一条完整记录到 dst；payload==NULL 时为无载荷记录。返回总长。 */
uint16_t zc_build_rec(uint8_t *dst, uint16_t type_cap, uint32_t seq,
                      const uint8_t *payload, uint16_t plen);

/* 确定性模式字节（案例 B/D 载荷生成） */
uint8_t zc_pat_byte(uint32_t i);

/* 校验一条完整记录。成功返回 type（含变体位），失败返回 0xFFFF。 */
uint16_t zc_check_rec(const uint8_t *rec, uint16_t tot, uint32_t *out_seq,
                      const char **why);

/* 握手码编解码（走 END/ACK 的 seq 字段） */
uint32_t zc_end_pack(uint8_t mode, uint32_t stream_len);
uint8_t zc_end_mode(uint32_t code);
uint32_t zc_end_len(uint32_t code);

/* 编译期选定的案例号（main.c 定义） */
extern const int g_case;

/* ---------------- Fletcher-32 ---------------- */
typedef struct
{
    uint32_t s1, s2, nwords_run;
} zc_f32_t;

void zc_f32_init(zc_f32_t *f);
void zc_f32_feed_le(zc_f32_t *f, const uint8_t *p, size_t len /*偶数*/);
uint32_t zc_f32_final(zc_f32_t *f);

/* ---------------- 计时 / 统计 ---------------- */
static inline int64_t zc_now_us(void) { return esp_timer_get_time(); }

#define ZC_SMP_MAX 1200 /* 容量与默认轮次一致；超出容量样本丢弃（README 说明） */

#if CONFIG_ZC_CASE == 0 || CONFIG_ZC_CASE == 4
#define EX16_SMP_POOL_N 1
#else
#define EX16_SMP_POOL_N 3
#endif
typedef struct
{
    int64_t v[ZC_SMP_MAX];
    unsigned n;
} zc_sampler_t;

/* 共享采样器池：每构建最多同时用 3 个（案例独占构建），DRAM 可控。
 *   A: pool[0]=copy pool[1]=zc   B: pool[0]=copy pool[1]=zc
 *   C: pool[0]=raw pool[1]=netconn pool[2]=socket   E: pool[0]=rtt
 * case4（流式校验）与 case0 不使用池，构建里退化为 1 槽占位。 */
extern zc_sampler_t g_smp_pool[EX16_SMP_POOL_N];

void zc_smp_reset(zc_sampler_t *s);
void zc_smp_push(zc_sampler_t *s, int64_t val);
void zc_smp_sort(zc_sampler_t *s);
int64_t zc_smp_med(zc_sampler_t *s); /* 先 sort */
int64_t zc_smp_p95(zc_sampler_t *s); /* 先 sort */
double zc_smp_mean(zc_sampler_t *s); /* µs 带小数：µs 整数网格下用多轮均值恢复分辨率 */
void zc_smp_print(const char *who, zc_sampler_t *s);

void zc_heap_line(const char *at);
int zc_tcpip_hwm(void);

/* 在 tcpip 线程同步执行（编排任务独占口径）。 */
bool zc_run_in_tcpip(void (*fn)(void *), void *arg, int64_t wait_ms);

/* 负载目的地初始化（Batch 8 纪律：严禁自身网卡 IP） */
extern ip_addr_t g_load_dst;
extern uint16_t g_load_port;
void zc_load_target_init(void);

/* 全局失败闸门（任何校验失败置位；所有案例循环检查） */
extern volatile bool g_fail;
void zc_fail(const char *reason);

/* ---------------- 通用监听服务（收帧引擎） ---------------- */

typedef struct zc_sink
{
    struct tcp_pcb *lpcb;
    struct tcp_pcb *conn;
    void *owner; /* 所属 zc_svc_t（引擎助手用） */
    uint8_t pend[REC_HARD_MAX];
    uint16_t pend_len;
    volatile bool end_seen;      /* 收到 RT_CTRL_END 且已回 ACK */
    uint32_t end_reason;         /* END 的 seq 字段（握手码） */
    volatile bool awaiting_reply;/* 回声欠账未清（sndbuf 满挂起），由 sent 唤醒 */
    /* 行协议模式（case0 命令口专用） */
    bool line_mode;
    char linebuf[192];
    uint16_t linelen;
} zc_sink_t;

/* 记录消费回调：rec 为完整记录基址；span=true 表示经过了跨段拼装。
 * 返回 false = 致命协议错误（引擎将 abort 连接并置 g_fail）。 */
typedef bool (*zc_sink_on_rec_t)(zc_sink_t *k, const uint8_t *rec, uint16_t tot,
                                 bool span);

/* 行协议回调（仅 line_mode 服务） */
typedef void (*zc_sink_on_line_t)(zc_sink_t *k, const char *line);

/* 服务描述符（静态分配，实例数最多 2） */
typedef struct
{
    zc_sink_t k;
    zc_sink_on_rec_t on_rec;
    zc_sink_on_line_t on_line;
    const char *name;
} zc_svc_t;

bool zc_svc_listen(zc_svc_t *svc, uint16_t lport); /* 经 run_in_tcpip 执行 */

/* 实例化的两个服务（common 定义） */
extern zc_svc_t g_svc_main;  /* PORT_SINK */
extern zc_svc_t g_svc_cecho; /* PORT_C_RAW */

/* END 记录的引擎侧公共处理（回 ACK + 翻门）。案例 on_rec 开头调用。 */
bool zc_engine_handle_end(zc_sink_t *k, const uint8_t *rec, uint16_t tot);

/* 派生助手：把已验证的记录原样回写到当前连接 */
err_t zc_sink_echo_cur(zc_sink_t *k, const uint8_t *rec, uint16_t tot);

/* ---------------- raw 客户端连接 ---------------- */

/*
 * 接收通道：common 先用自己的微型定帧器从字节流里切出完整记录——
 *   1) 记录是 RT_CTRL_ACK 且 seq == 当前等待值 => 点亮 ACK 信号灯；
 *   2) 其余完整记录复制进 scratch 后回调 on_data（回调不得持有指针）。
 * 发送通道与数据通道解耦：on_sent 由案例注入自己的节奏器。
 */
#define ZC_CLI_CONSUMED 12345

typedef struct
{
    struct tcp_pcb *pcb;
    SemaphoreHandle_t estab;
    volatile bool estab_fail;
    volatile bool peer_closed;
    volatile bool fatal;

    void (*on_data)(void *uctx_r, const uint8_t *rec, uint16_t tot, uint16_t type,
                    uint32_t seq);
    void *uctx_r;
    void (*on_sent)(void *uctx_s, struct tcp_pcb *pcb, u16_t len);
    void *uctx_s;

    /* 定帧器状态（common 内部使用） */
    uint8_t scratch[REC_HARD_MAX];
    uint16_t pend_len;
} zc_cli_t;

extern zc_cli_t g_cli_main; /* 主基准连接（案例 1/2/4/5 复用） */

/* 反射器模式编译期常量（Kconfig bool 未开时宏不存在） */
#if CONFIG_ZC_HOST_REFLECTOR
#define EX16_REFLECTOR 1
#else
#define EX16_REFLECTOR 0
#endif

bool zc_cli_open_ext(zc_cli_t *c, const char *who, uint16_t dport,
                     int64_t timeout_ms);
#define zc_cli_open(c, who, to) zc_cli_open_ext(c, who, g_load_port, to)
void zc_cli_close(zc_cli_t *c);

/* 阻塞发送整条记录并等待 RT_CTRL_ACK(seq)。仅用于小控制帧（END 等）。 */
bool zc_cli_send_ack_wait(zc_cli_t *c, uint16_t type, uint32_t seq,
                          const uint8_t *payload, uint16_t plen,
                          int64_t timeout_ms);

/* 当前是否有挂起的 ACK 等待命中（案例轮询用） */
bool zc_cli_poll_ctrl_done(void);
bool zc_cli_last_ack_ok(void);
void zc_cli_arm_ack_wait(uint32_t seq);

/* 非阻塞投递整条记录（sndbuf 不足返回 ERR_INPROGRESS；成功后立刻冲刷输出） */
err_t zc_cli_post(zc_cli_t *c, const uint8_t *rec, uint16_t tot, u8_t apiflags);

/* ---------------- 案例 README 数字支撑工具 ---------------- */
void zc_print_pair_result(const char *cs, const char *metric, long long copy_med,
                          long long copy_p95, long long zc_med, long long zc_p95,
                          unsigned n_copy, unsigned n_zc);

/* ---------------- 案例入口 ---------------- */
bool ex16_caseA_run(void);
bool ex16_caseB_run(void);
bool ex16_caseC_run(void);
bool ex16_caseD_run(void);
bool ex16_caseE_run(void);
void ex16_case5_cite_lines(void);
void ex16_caseA_reset(void);
void ex16_caseB_reset(void);
void ex16_caseD_reset(void);

/* ---------------- 案例入口声明注记 ----------------
 * A/B/D 的 reset 与 run 分离是为了让编译器在非本案例构建中剔除大缓冲
 * （arena 等）；reset 只操作小状态，无条件保留无害。
 */
