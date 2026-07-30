/* SPDX-License-Identifier: BSD-3-Clause
 * buggy_l2fwd.c — 故意带 5 类典型 bug 的 L2 转发示例
 *
 * Bug 列表:
 *   1. 忘记检查 mbuf 分配返回值 (NULL deref)
 *   2. 释放 mbuf 后继续使用 (use-after-free)
 *   3. 数组越界访问 (OOB read)
 *   4. ring 索引计算溢出 (integer overflow)
 *   5. RTE_LOG 信息级别塞高频路径, 导致性能塌方
 *
 * 这个文件用于演示 DPDK 调试技术, 编译运行后会触发各种 crash
 * 和性能问题, 配合 buggy_l2fwd.gdb 一起使用
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

#define RX_RING_SIZE 1024
#define TX_RING_SIZE 1024
#define NUM_MBUFS    8191
#define MBUF_CACHE   250
#define BURST_SIZE   32

#define APP_LOG RTE_LOGTYPE_USER1

/* 全局变量: 不放 per-lcore, 故意暴露 cache line bouncing */
static uint64_t g_total_rx;
static uint64_t g_total_tx;

static struct rte_mempool *g_mbuf_pool;

/* Bug 3: 故意写错的 max port 数, 实际 DPDK 支持 32/64 */
#define MAX_PORTS_BUGGY 4  /* 真实环境端口可能超过 4 */

/* Bug 4: 不安全的索引计算 */
static inline uint16_t
bad_next_index(uint16_t cur, uint16_t burst)
{
    /* 当 cur + burst > 65535 时会回绕到 0, 导致乱序写入 */
    return cur + burst;
}

/* 自定义断言: 用于触发崩溃 */
#define CRASH_TRIGGER(cond) do {                            \
    if (!(cond)) {                                          \
        rte_panic("Bug triggered: %s (at %s:%d)\n",        \
                  #cond, __func__, __LINE__);               \
    }                                                       \
} while (0)

/* lcore 处理函数 */
static int
lcore_main(__rte_unused void *arg)
{
    uint16_t port;

    RTE_LOG(INFO, APP_LOG, "lcore %u started\n", rte_lcore_id());

    /* 真实生产代码会做 per-lcore 分配, 这里简化 */
    struct rte_mbuf *bufs[BURST_SIZE];

    while (1) {
        for (port = 0; port < RTE_MAX_ETHPORTS && port < MAX_PORTS_BUGGY; port++) {
            /* Bug 5: 高频路径上用 RTE_LOG(INFO), 性能杀手 */
            RTE_LOG(INFO, APP_LOG,
                "Polling port %u (lcore %u)\n",
                port, rte_lcore_id());

            /* 1. 收包 */
            const uint16_t nb_rx = rte_eth_rx_burst(port, 0,
                bufs, BURST_SIZE);

            if (nb_rx == 0)
                continue;

            /* Bug 1: 没检查 mbuf 指针, 但这里 bufs 数组本身没初始化 */
            for (int i = 0; i < nb_rx; i++) {
                /* Bug 2: 这里模拟 use-after-free */
                if (i == nb_rx - 1) {
                    rte_pktmbuf_free(bufs[i]);
                    /* 释放后继续使用 */
                    RTE_LOG(INFO, APP_LOG,
                        "Free'd mbuf data_len=%u pkt_len=%u\n",
                        bufs[i]->data_len, bufs[i]->pkt_len);
                }

                /* Bug 3: 数组越界 (port_id 可能超过 4) */
                static uint64_t port_pkt_count[4];  /* 应该用 RTE_MAX_ETHPORTS */
                port_pkt_count[port]++;
            }

            /* Bug 4: 不安全索引 */
            static uint16_t g_tx_idx = 0;
            uint16_t new_idx = bad_next_index(g_tx_idx, nb_rx);
            g_tx_idx = new_idx;
            RTE_LOG(DEBUG, APP_LOG, "tx_idx=%u\n", g_tx_idx);

            /* 转发 */
            const uint16_t nb_tx = rte_eth_tx_burst(port ^ 1, 0,
                bufs, nb_rx);
            if (nb_tx < nb_rx)
                rte_pktmbuf_free_bulk(&bufs[nb_tx], nb_rx - nb_tx);

            g_total_rx += nb_rx;
            g_total_tx += nb_tx;
        }
    }
    return 0;
}

/* 故意没安装的 SIGSEGV handler (没有 core dump 信息) */
static void
no_op_handler(int sig)
{
    fprintf(stderr, "Got signal %d, exiting\n", sig);
    _exit(1);
}

int
main(int argc, char **argv)
{
    int ret;
    uint16_t port;

    /* Bug: 装了 no_op handler, 覆盖默认的 core dump 行为 */
    signal(SIGSEGV, no_op_handler);
    signal(SIGBUS,  no_op_handler);
    signal(SIGABRT, no_op_handler);

    ret = rte_eal_init(argc, argv);
    if (ret < 0)
        rte_panic("Cannot init EAL\n");

    argc -= ret;
    argv += ret;

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
            RTE_LOG(ERR, APP_LOG, "lcore %u returned error\n", lcore_id);
    }

    /* 清理 */
    RTE_ETH_FOREACH_DEV(port)
        rte_eth_dev_stop(port);

    rte_eal_cleanup();
    return 0;
}
