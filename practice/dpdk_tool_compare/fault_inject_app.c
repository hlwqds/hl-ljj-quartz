/* SPDX-License-Identifier: BSD-3-Clause
 * fault_inject_app.c — 故意触发 4 类典型问题, 用于演示工具差异
 *
 * 场景:
 *   1. 端口 0: 正常跑 (基线)
 *   2. 端口 1: mbuf 泄漏 — 收到包不归还 mempool
 *   3. 端口 2: TX 队列满 — 故意不消费 TX done
 *   4. 端口 3: 单 lcore 处理 — 模拟不均衡 (RSS 关掉)
 *
 * 跑起来后用 ethtool / ss / ip / dpdk-procinfo 分别看,
 * 体会"网卡被 DPDK 拥有后, 其他工具失明" 的效果.
 *
 * 注意: 本程序依赖 DPDK 24.x 真实环境, 需要 4 个端口或
 * 改用 pcap PMD 模拟. 演示场景在脚本里通过 fault_flags 控制.
 */

#include <stdio.h>
#include <stdint.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

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

/* 全局故障开关 (命令行覆盖) */
static int g_fault_mbuf_leak   = 0;  /* 1 = 收到包不归还 */
static int g_fault_tx_backlog  = 0;  /* 1 = TX 不消费 */
static int g_fault_no_rss      = 0;  /* 1 = 单 lcore 跑所有队列 */
static int g_run_seconds       = 60; /* 默认跑 60 秒, 0 = 无限 */

RTE_LOG_REGISTER(app_logtype, app, INFO);

static struct rte_mempool *g_mbuf_pool;

static void
signal_handler(int sig)
{
    if (sig == SIGINT || sig == SIGTERM) {
        RTE_LOG(INFO, app_logtype, "Caught signal %d, exiting\n", sig);
        rte_eal_cleanup();
        _exit(0);
    }
}

static int
lcore_main(__rte_unused void *arg)
{
    unsigned lcore = rte_lcore_id();
    struct rte_mbuf *bufs[BURST_SIZE];
    uint16_t port, qid;
    uint16_t nb_rx, nb_tx;

    RTE_LOG(INFO, app_logtype, "lcore %u started\n", lcore);

    while (1) {
        /* RSS 关闭时: 所有 lcore 跑所有 port+queue, 模拟不均衡 */
        if (g_fault_no_rss) {
            /* 单 lcore 跑全部 */
            if (lcore != 1) continue;  /* 只让 lcore 1 干活 */
            for (port = 0; port < RTE_MAX_ETHPORTS; port++) {
                if (!rte_eth_dev_is_valid_port(port)) continue;
                for (qid = 0; qid < 1; qid++) {
                    nb_rx = rte_eth_rx_burst(port, qid, bufs, BURST_SIZE);
                    if (nb_rx == 0) continue;

                    /* Fault: mbuf 泄漏 */
                    if (g_fault_mbuf_leak && port == 1) {
                        /* 故意不 free, 让 mempool 耗尽 */
                        continue;
                    }

                    nb_tx = rte_eth_tx_burst(port ^ 1, 0, bufs, nb_rx);
                    if (nb_tx < nb_rx)
                        rte_pktmbuf_free_bulk(&bufs[nb_tx], nb_rx - nb_tx);
                }
            }
        } else {
            /* 正常: 每个 lcore 负责一对 port+queue */
            port = lcore % RTE_MAX_ETHPORTS;
            qid  = lcore % 1;
            if (!rte_eth_dev_is_valid_port(port)) continue;

            nb_rx = rte_eth_rx_burst(port, qid, bufs, BURST_SIZE);
            if (nb_rx == 0) continue;

            if (g_fault_mbuf_leak && port == 1) {
                /* 故意不 free */
                RTE_LOG(WARNING, app_logtype,
                    "Leaking %u mbufs on port 1\n", nb_rx);
                continue;
            }

            if (g_fault_tx_backlog && port == 2) {
                /* 故意不 TX, 模拟发不出去 */
                rte_pktmbuf_free_bulk(bufs, nb_rx);
                RTE_LOG(WARNING, app_logtype,
                    "Backlogged %u mbufs on port 2\n", nb_rx);
                continue;
            }

            nb_tx = rte_eth_tx_burst(port ^ 1, 0, bufs, nb_rx);
            if (nb_tx < nb_rx)
                rte_pktmbuf_free_bulk(&bufs[nb_tx], nb_rx - nb_tx);
        }
    }
    return 0;
}

int
main(int argc, char **argv)
{
    int ret;
    uint16_t port;

    /* 解析自定义 fault flags (在 EAL init 之前) */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fault-mbuf-leak"))
            g_fault_mbuf_leak = 1;
        else if (!strcmp(argv[i], "--fault-tx-backlog"))
            g_fault_tx_backlog = 1;
        else if (!strcmp(argv[i], "--fault-no-rss"))
            g_fault_no_rss = 1;
        else if (!strncmp(argv[i], "--run-seconds=", 14))
            g_run_seconds = atoi(argv[i] + 14);
    }

    signal(SIGINT,  signal_handler);
    signal(SIGTERM, signal_handler);

    ret = rte_eal_init(argc, argv);
    if (ret < 0)
        rte_panic("Cannot init EAL\n");
    argc -= ret;
    argv += ret;

    RTE_LOG(INFO, app_logtype,
        "Faults: mbuf_leak=%d tx_backlog=%d no_rss=%d run=%ds\n",
        g_fault_mbuf_leak, g_fault_tx_backlog,
        g_fault_no_rss, g_run_seconds);

    /* mbuf pool */
    g_mbuf_pool = rte_pktmbuf_pool_create("MBUF_POOL",
        NUM_MBUFS, MBUF_CACHE, 0,
        RTE_MBUF_DEFAULT_BUF_SIZE,
        rte_socket_id());
    if (g_mbuf_pool == NULL)
        rte_panic("Cannot create mbuf pool\n");

    /* 配置所有端口 */
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

    /* 跑指定秒数后自动退出 */
    if (g_run_seconds > 0) {
        sleep(g_run_seconds);
        RTE_LOG(INFO, app_logtype, "Auto-exit after %d seconds\n", g_run_seconds);
        rte_eal_cleanup();
        return 0;
    }

    RTE_LCORE_FOREACH_SLAVE(lcore_id) {
        rte_eal_wait_lcore(lcore_id);
    }

    RTE_ETH_FOREACH_DEV(port)
        rte_eth_dev_stop(port);

    rte_eal_cleanup();
    return 0;
}
