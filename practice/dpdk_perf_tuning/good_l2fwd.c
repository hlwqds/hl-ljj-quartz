/*
 * good_l2fwd.c — 修复版 L2 转发示例
 *
 * 修复了 bad_l2fwd.c 中的所有性能陷阱：
 *   1. Batching (burst=32)
 *   2. 就地修改，零拷贝
 *   3. 多队列 + RSS
 *   4. per-NUMA mempool
 *   5. 开启 checksum offload
 *   6. 统计计数器，定期打印
 *
 * 编译:
 *   gcc -o good_l2fwd good_l2fwd.c -lrte_eal -lrte_ethdev -lrte_mbuf \
 *       -lrte_mempool -lrte_hash -lrte_ring
 */

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_byteorder.h>
#include <rte_cycles.h>
#include <stdio.h>
#include <signal.h>
#include <stdint.h>

#define BURST_SIZE      32
#define NB_RX_QUEUES    4
#define NB_TX_QUEUES    4
#define NB_RXD          1024
#define NB_TXD          1024
#define MBUF_CACHE_SIZE 250
#define MBUF_POOL_SIZE  (8191 * 2)

static volatile int quit;

static void signal_handler(int sig) { (void)sig; quit = 1; }

/* per-lcore 统计，避免跨核共享 */
struct lcore_stats {
    uint64_t rx_pkts;
    uint64_t tx_pkts;
    uint64_t dropped;
    uint64_t rx_bursts;
    uint64_t rx_empty;
} __rte_cache_aligned;

static struct lcore_stats lcore_stats[RTE_MAX_LCORE];

/* per-socket mempool */
static struct rte_mempool *pools[RTE_MAX_NUMA_NODES];

static struct rte_mempool *
get_pool_for_socket(int socket_id)
{
    if (socket_id < 0)
        socket_id = 0;

    if (pools[socket_id] != NULL)
        return pools[socket_id];

    char name[64];
    snprintf(name, sizeof(name), "pool_s%d", socket_id);

    pools[socket_id] = rte_pktmbuf_pool_create(name,
            MBUF_POOL_SIZE, MBUF_CACHE_SIZE, 0,
            RTE_MBUF_DEFAULT_BUF_SIZE, socket_id);

    return pools[socket_id];
}

/*
 * Fix 3 + Fix 4 + Fix 5: 多队列 + RSS + per-NUMA mempool + offload
 * ──────────────────────────────────────────────────────────────────
 * - 启用 RSS，把流量散到 4 个 queue
 * - 每个 queue 用 port 所在 NUMA 的 mempool
 * - 开启 checksum offload，让网卡算 checksum
 */
static int
port_init_good(uint16_t port)
{
    struct rte_eth_dev_info dev_info;
    int ret = rte_eth_dev_info_get(port, &dev_info);
    if (ret != 0)
        return ret;

    /* RSS 配置 */
    struct rte_eth_conf port_conf = {
        .rxmode = {
            .mq_mode = RTE_ETH_MQ_RX_RSS,
        },
        .rx_adv_conf = {
            .rss_conf = {
                .rss_hf = RTE_ETH_RSS_IP | RTE_ETH_RSS_TCP | RTE_ETH_RSS_UDP,
            },
        },
        .txmode = {
            .offloads = RTE_ETH_TX_OFFLOAD_IPV4_CKSUM
                      | RTE_ETH_TX_OFFLOAD_UDP_CKSUM,
        },
    };

    uint16_t nb_rxq = RTE_MIN(NB_RX_QUEUES, dev_info.max_rx_queues);
    uint16_t nb_txq = RTE_MIN(NB_TX_QUEUES, dev_info.max_tx_queues);

    ret = rte_eth_dev_configure(port, nb_rxq, nb_txq, &port_conf);
    if (ret != 0)
        return ret;

    uint16_t nb_rxd = NB_RXD;
    uint16_t nb_txd = NB_TXD;
    ret = rte_eth_dev_adjust_nb_rx_tx_desc(port, &nb_rxd, &nb_txd);
    if (ret != 0)
        return ret;

    int socket = rte_eth_dev_socket_id(port);
    struct rte_mempool *mp = get_pool_for_socket(socket);
    if (mp == NULL)
        return -1;

    struct rte_eth_rxconf rxq_conf = dev_info.default_rxconf;
    rxq_conf.offloads = port_conf.rxmode.offloads;

    struct rte_eth_txconf txq_conf = dev_info.default_txconf;
    txq_conf.offloads = port_conf.txmode.offloads;

    for (uint16_t q = 0; q < nb_rxq; q++) {
        ret = rte_eth_rx_queue_setup(port, q, nb_rxd, socket,
                &rxq_conf, mp);
        if (ret != 0)
            return ret;
    }

    for (uint16_t q = 0; q < nb_txq; q++) {
        ret = rte_eth_tx_queue_setup(port, q, nb_txd, socket, &txq_conf);
        if (ret != 0)
            return ret;
    }

    ret = rte_eth_dev_start(port);
    if (ret != 0)
        return ret;

    rte_eth_promiscuous_enable(port);
    return 0;
}

/*
 * Fix 1: Batching
 * Fix 2: 零拷贝
 * Fix 6: 统计计数器
 * ──────────────────────────────────────
 */
static void
main_loop_good(uint16_t port_in, uint16_t port_out, uint16_t queue_id)
{
    struct rte_mbuf *rx_bufs[BURST_SIZE];
    struct rte_mbuf *tx_bufs[BURST_SIZE];
    struct lcore_stats *stats = &lcore_stats[rte_lcore_id()];
    uint64_t last_print = rte_rdtsc();
    uint64_t print_interval = rte_get_timer_hz();  /* 每秒打印一次 */

    while (!quit) {
        /*
         * Fix 1: 一次收 BURST_SIZE 个包
         * 函数调用开销从 N 次降到 1 次
         */
        uint16_t nb_rx = rte_eth_rx_burst(port_in, queue_id,
                rx_bufs, BURST_SIZE);

        if (nb_rx == 0) {
            stats->rx_empty++;
            continue;
        }

        stats->rx_bursts++;
        stats->rx_pkts += nb_rx;

        uint16_t nb_tx = 0;
        for (uint16_t i = 0; i < nb_rx; i++) {
            struct rte_mbuf *m = rx_bufs[i];

            /*
             * Fix 2: 零拷贝，就地修改 MAC 地址
             * 不做 memcpy，只交换 12 字节 MAC
             */
            struct rte_ether_hdr *eth =
                rte_pktmbuf_mtod(m, struct rte_ether_hdr *);

            struct rte_ether_addr tmp;
            rte_ether_addr_copy(&eth->dst_addr, &tmp);
            rte_ether_addr_copy(&eth->src_addr, &eth->dst_addr);
            rte_ether_addr_copy(&tmp, &eth->src_addr);

            tx_bufs[nb_tx++] = m;
        }

        /* 批量发送 */
        uint16_t sent = rte_eth_tx_burst(port_out, queue_id,
                tx_bufs, nb_tx);

        stats->tx_pkts += sent;

        /* 释放未发送的 */
        for (uint16_t i = sent; i < nb_tx; i++)
            rte_pktmbuf_free(tx_bufs[i]);

        if (sent < nb_tx)
            stats->dropped += (nb_tx - sent);

        /*
         * Fix 6: 定期打印统计，不是每包 printf
         */
        uint64_t now = rte_rdtsc();
        if (now - last_print > print_interval) {
            printf("lcore %u q%u: rx=%lu tx=%lu drop=%lu\n",
                    rte_lcore_id(), queue_id,
                    stats->rx_pkts, stats->tx_pkts, stats->dropped);
            last_print = now;
        }
    }
}

int
main(int argc, char *argv[])
{
    signal(SIGINT, signal_handler);

    int ret = rte_eal_init(argc, argv);
    if (ret < 0)
        return -1;

    uint16_t nb_ports = rte_eth_dev_count_avail();
    if (nb_ports < 2) {
        printf("need at least 2 ports\n");
        return -1;
    }

    /* Fix 4: 每个 port 初始化时自动创建 NUMA 匹配的 pool */
    port_init_good(0);
    port_init_good(1);

    /* 简单场景: 单 lcore 轮询 queue 0 */
    unsigned lcore_id;
    RTE_LCORE_FOREACH_WORKER(lcore_id) {
        if (rte_eal_wait_lcore(lcore_id) == 0)
            break;
    }

    printf("good_l2fwd running on lcore %u\n", rte_lcore_id());
    main_loop_good(0, 1, 0);

    rte_eth_dev_stop(0);
    rte_eth_dev_stop(1);
    rte_eal_cleanup();
    return 0;
}
