/*
 * pcapx —— lwIP 可插拔抓包模块（契约头）
 *
 * 规格：docs/spec/pcapx.md（本文件是其「行为契约」的代码化，冻结接口；
 *       实现侧需要偏离时必须在交付报告中说明理由）
 * 运行环境：ESP-IDF v6.0.2 / lwIP 2.2.0-dev / FreeRTOS SMP（esp32, Xtensa LX6）
 *
 * 线性契约：
 *  - pcapx_attach() 一次性绑定一个 netif（多 netif 并发为本迭代 non-goal）
 *  - tap 路径（netif->input / netif->linkoutput 的换装函数）禁止阻塞、
 *    禁止动态分配；只做 时间戳 + pbuf_copy_partial(snaplen) + 入 SPSC 环
 *  - writer 专职任务出环写 sink；环满丢新帧并累计 dropped
 *  - pcap 格式：µs 魔数 0xa1b2c3d4、LINKTYPE_ETHERNET(1)、全局头由 core
 *    在 sink open 后首先写出
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "lwip/netif.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------- 方向与过滤 ---------------- */

#define PCAPX_DIR_RX 0x01
#define PCAPX_DIR_TX 0x02

/* 硬过滤：全 0 字段 = 通配。端口按网络序比较，命中 src 或 dst 任一即可 */
typedef struct {
    uint16_t ethertype; /* 主机序，0=任意（含非 IP 帧，如 ARP=0x0806） */
    uint8_t  ip_proto;  /* 0=任意；1=ICMP 6=TCP 17=UDP */
    uint16_t port;      /* 网络序，0=任意 */
} pcapx_filter_t;

/* ---------------- sink 后端（可插拔轴之二） ---------------- */

struct pcapx_sink {
    const char *name; /* 契约日志 ATTACH 行里 sink=<name> 的取值来源 */
    /* open：attach 时调用一次；返回非 ESP_OK → ATTACH_FAIL reason=sink_open */
    esp_err_t (*open)(struct pcapx_sink *s);
    /* 顺序写（core 已先写全局头）；writer 任务上下文，允许阻塞 */
    esp_err_t (*write)(struct pcapx_sink *s, const void *buf, size_t len);
    /* detach 时调用；之后 sink 内存由 core 以 free_fn 释放 */
    esp_err_t (*close)(struct pcapx_sink *s);
    void (*free_fn)(struct pcapx_sink *s);
};

typedef struct pcapx_sink pcapx_sink_t;

/* sink 构造器（各实现文件提供；返回对象由模块接管生命周期） */
pcapx_sink_t *pcapx_sink_semihost_new(const char *host_path); /* QEMU -semihosting 直写宿主文件 */
pcapx_sink_t *pcapx_sink_ram_new(size_t cap_bytes);           /* RAM 暂存，console 导出 */
pcapx_sink_t *pcapx_sink_uart_new(int uart_num, int baud);    /* 帧协议流，宿主收集 */

/* ---------------- 配置与统计 ---------------- */

typedef struct {
    struct netif *netif;     /* 目标网卡（须已 up） */
    uint8_t direction;       /* PCAPX_DIR_RX|PCAPX_DIR_TX */
    uint32_t snaplen;        /* 每包最大捕获字节数，超出截断并计 truncated */
    pcapx_filter_t filter;   /* 全 0 = 抓全部 */
    size_t ring_bytes;       /* SPSC 环容量（字节）；0 → 用 Kconfig 默认 */
    pcapx_sink_t *sink;      /* 所有权移交模块，detach 时 close+free */
} pcapx_config_t;

typedef struct {
    uint32_t rx, tx;         /* tap 收到的帧数（过滤前） */
    uint32_t filtered;       /* 被硬过滤排除的帧数 */
    uint32_t dropped;        /* 环满丢弃（丢新） */
    uint32_t truncated;      /* 超 snaplen 截断 */
    uint32_t written;        /* writer 已写入 sink 的帧数 */
    uint32_t ring_high_wm;   /* 环占用峰值（字节） */
} pcapx_stats_t;

/* ---------------- API（契约见 spec 第 4 节） ---------------- */

/* 成功：换装 netif->input / netif->linkoutput（wrap 常驻，原子 flag 门控捕获）
 * 失败：ESP_ERR_INVALID_ARG（参数）/ ESP_ERR_INVALID_STATE（netif 未 up 或已 attach）
 *      / ESP_ERR_NO_MEM / sink_open 失败透传
 * 日志：I pcapx: ATTACH netif=st mode=rx+tx snap=128 sink=semihost:/tmp/cap.pcap
 *      E pcapx: ATTACH_FAIL netif=st reason=down|busy|sink_open|arg */
esp_err_t pcapx_attach(const pcapx_config_t *cfg);

/* 恢复原始指针（存在竞态窗口：建议链路静默期调用，spec 已注明）
 * 日志：I pcapx: DETACH netif=st rx=120 tx=88 drop=3 trunc=12 */
esp_err_t pcapx_detach(void);

bool pcapx_is_attached(void);

/* 任意时刻可调；未 attach 时返回全 0 */
void pcapx_get_stats(pcapx_stats_t *out);

#ifdef __cplusplus
}
#endif
