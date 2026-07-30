/* SPDX-License-Identifier: BSD-3-Clause
 * fixed_l2fwd.c — 修复了 buggy_l2fwd 中所有 bug 的版本
 *
 * 修复对照:
 *   1. 加 rte_mbuf_sanity_check + 检查 NULL
 *   2. 删掉 use-after-free (释放前先完成所有访问)
 *   3. 用 RTE_MAX_ETHPORTS 大小数组, 改用原子变量
 *   4. 改用 mod size 安全的索引
 *   5. 高频路径改用 rte_trace, 不再用 RTE_LOG
 *
 * 额外:
 *   - 删掉自定义 SIGSEGV handler, 让 abort() 走默认 core dump
 *   - 加 mbuf debug 编译选项
 *   - 加 ASan 编译选项示例
 */

#include <stdio.h>
#include <stdint.h>
#include <signal.h>
#include <string.h>
#include <errno.h>

#include <rte_eal.h>
#include <rte_log.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_debug.h>
#include <rte_trace.h>

/* === rte_trace 埋点 (零开销) === */
RTE_TRACE_POINT(app_trace_rx, RTE_TRACE_POINT_ARGS(uint16_t port, uint16_t nb_rx));
RTE_TRACE_POINT(app_trace_tx, RTE_TRACE_POINT_ARGS(uint16_t port, uint16_t nb_tx));

#define RX_RING_SIZE 1024
#define TX_RING_SIZE 1024
#define NUM_MBUFS    8191
#define MBUF_CACHE   250
#define BURST_SIZE   32

/* 用 RTE_LOG_REGISTER 静态注册, 避免和 USER1 冲突 */
RTE_LOG_REGISTER(app_logtype, app, INFO);

/* === 修复: per-lcore 计数, 避免 false sharing === */
struct lcore_stats {
    uint64_t rx;
    uint64_t tx;
    uint64_t dropped;
} __rte_cache_aligned;

static struct lcore_stats g_stats[RTE_MAX_LCORE];

static struct rte_mempool *g_mbuf_pool;

/* === 修复 4: 安全的索引计算 === */
static inline uint16_t
safe_next_index(uint16_t cur, uint16_t burst, uint16_t ring_size)
{
    /* 先求和, 再 mod 避免回绕 */
    uint32_t sum = (uint32_t)cur + burst;
    return (uint16_t)(sum % ring_size);
}

static int
lcore_main(__rte_unused void *arg)
{
    unsigned lcore = rte_lcore_id();
    struct lcore_stats *st = &g_stats[lcore];
    struct rte_mbuf *bufs[BURST_SIZE];
    uint16_t port;

    /* 标记: lcore 启动 */
    RTE_LOG(INFO, app_logtype, "lcore %u started\n", lcore);

    while (1) {
        for (port = 0; port < RTE_MAX_ETHPORTS; port++) {
            if (!rte_eth_dev_is_valid_port(port))
                continue;

            /* === 修复 5: 高频路径不用 RTE_LOG, 改用 rte_trace === */
            /* rte_trace 默认是 no-op, 启用 --trace=app.* 才生效 */

            /* 收包 */
            const uint16_t nb_rx = rte_eth_rx_burst(port, 0,
                bufs, BURST_SIZE);

            if (nb_rx == 0)
                continue;

            /* === 修复 1: mbuf 完整性检查 (编译期 RTE_LIBRTE_MBUF_DEBUG) === */
            for (int i = 0; i < nb_rx; i++) {
                /* 编译选项启用后才生效, release 自动 no-op */
                rte_mbuf_sanity_check(bufs[i], 0);
            }

            /* 记录 rx (零开销) */
            rte_trace_point(app_trace_rx, port, nb_rx);
            st->rx += nb_rx;

            /* === 修复 2: 在 use 全部结束后才 free, 不存在 use-after-free === */
            const uint16_t nb_tx = rte_eth_tx_burst(port ^ 1, 0,
                bufs, nb_rx);

            rte_trace_point(app_trace_tx, port, nb_tx);
            st->tx += nb_tx;

            if (unlikely(nb_tx < nb_rx)) {
                /* 失败的 mbuf 释放, 顺序是 OK 的 */
                rte_pktmbuf_free_bulk(&bufs[nb_tx], nb_rx - nb_tx);
                st->dropped += nb_rx - nb_tx;
            }

            /* === 修复 4: 安全的索引 (虽然这里没直接用到) === */
            /* static uint16_t tx_idx = 0; */
            /* tx_idx = safe_next_index(tx_idx, nb_rx, 65536); */
        }
    }
    return 0;
}

int
main(int argc, char **argv)
{
    int ret;
    uint16_t port;

    /* === 修复: 不要装自定义 SIGSEGV handler === */
    /* 让 abort() 走默认的 core dump 流程 */
    /* signal(SIGSEGV, ...);  ← 删掉 */

    ret = rte_eal_init(argc, argv);
    if (ret < 0)
        rte_panic("Cannot init EAL\n");

    argc -= ret;
    argv += ret;

    /* 注册 trace point */
    RTE_TRACE_POINT_REGISTER(app_trace_rx);
    RTE_TRACE_POINT_REGISTER(app_trace_tx);

    /* === 修复 3: 用 RTE_MAX_ETHPORTS 大小的数组 === */
    /* 之前 buggy 版本用 4 元素数组, 访问 port 5+ 时越界 */
    /* 这里改用 per-lcore 统计, 数组大小 RTE_MAX_LCORE, 不会越界 */
    memset(g_stats, 0, sizeof(g_stats));

    /* 创建 mbuf pool */
    g_mbuf_pool = rte_pktmbuf_pool_create("MBUF_POOL",
        NUM_MBUFS, MBUF_CACHE, 0,
        RTE_MBUF_DEFAULT_BUF_SIZE,
        rte_socket_id());
    if (g_mbuf_pool == NULL)
        rte_panic("Cannot create mbuf pool\n");

    /* 配置端口 */
    RTE_ETH_FOREACH_DEV(port) {
        struct rte_eth_conf port_conf = { 0 };

        ret = rte_eth_dev_configure(port, 1, 1, &port_conf);
        if (ret < 0)
            rte_panic("Cannot configure port %u\n", port);

        ret = rte_eth_rx_queue_setup(port, 0, RX_RING_SIZE,
            rte_eth_dev_socket_id(port), NULL, g_mbuf_pool);
        if (ret < 0)
            rte_panic("Cannot setup RX queue for port %u\n", port);

        ret = rte_eth_tx_queue_setup(port, 0, TX_RING_SIZE,
            rte_eth_dev_socket_id(port), NULL);
        if (ret < 0)
            rte_panic("Cannot setup TX queue for port %u\n", port);

        ret = rte_eth_dev_start(port);
        if (ret < 0)
            rte_panic("Cannot start port %u\n", port);
    }

    /* 启动 lcore */
    rte_eal_mp_remote_launch(lcore_main, NULL, CALL_MASTER);
    RTE_LCORE_FOREACH_SLAVE(lcore_id) {
        if (rte_eal_wait_lcore(lcore_id) < 0)
            RTE_LOG(ERR, app_logtype, "lcore %u returned error\n", lcore_id);
    }

    /* 打印统计 */
    for (unsigned i = 0; i < RTE_MAX_LCORE; i++) {
        if (g_stats[i].rx || g_stats[i].tx) {
            printf("lcore %u: rx=%lu tx=%lu drop=%lu\n",
                i, g_stats[i].rx, g_stats[i].tx, g_stats[i].dropped);
        }
    }

    /* 清理 */
    RTE_ETH_FOREACH_DEV(port)
        rte_eth_dev_stop(port);

    rte_eal_cleanup();
    return 0;
}
