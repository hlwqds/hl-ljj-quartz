/*
 * bad_l2fwd.c — 典型性能陷阱的 L2 转发示例
 *
 * 这份代码故意展示了常见的新手错误：
 *   1. 单包收发（没有 batching）
 *   2. 每包 memcpy（不必要的复制）
 *   3. 所有流量走一个队列（没有 RSS/多队列）
 *   4. NUMA 不对齐（mempool 和网卡不在同一 socket）
 *   5. 没开 offload（软件算 checksum）
 *   6. printf 在数据面（I/O 阻塞）
 *
 * 用 perf/ptype 定位这些瓶颈后，对照 good_l2fwd.c 看 fix。
 *
 * 编译:
 *   gcc -o bad_l2fwd bad_l2fwd.c -lrte_eal -lrte_ethdev -lrte_mbuf -lrte_mempool
 */

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_byteorder.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>

static volatile int quit;

static void
signal_handler(int sig)
{
    (void)sig;
    quit = 1;
}

/*
 * 瓶颈 1: 单包收发
 * ────────────────
 * 每次 rx_burst 只取 1 个包，tx_burst 也只发 1 个。
 * 每次函数调用的固定开销（参数检查、MMIO 写 doorbell）分摊到 1 个包上。
 * 32 个包就要调 64 次函数。
 *
 * 正确做法: 见 good_l2fwd.c，burst=32，一次调用处理 32 包。
 */
static void
main_loop_bad_burst(uint16_t port_in, uint16_t port_out)
{
    struct rte_mbuf *m;

    while (!quit) {
        /* 每次只取 1 个包 */
        uint16_t nb = rte_eth_rx_burst(port_in, 0, &m, 1);
        if (nb == 0)
            continue;

        /*
         * 瓶颈 2: 不必要的 memcpy
         * ────────────────────────
         * L2 转发只需交换 MAC 地址，不需要复制整个 packet。
         * 但这里把整个 payload 拷贝到一个临时 buffer 再拷回来。
         *
         * 正确做法: 就地修改 MAC 地址，见 good_l2fwd.c。
         */
        char tmp[2048];
        struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
        memcpy(tmp, eth, m->pkt_len);          /* 无意义的复制 */
        memcpy(eth, tmp, m->pkt_len);

        /* 交换 MAC */
        struct rte_ether_addr tmp_mac;
        rte_ether_addr_copy(&eth->dst_addr, &tmp_mac);
        rte_ether_addr_copy(&eth->src_addr, &eth->dst_addr);
        rte_ether_addr_copy(&tmp_mac, &eth->src_addr);

        /*
         * 瓶颈 3: printf 在数据面
         * ────────────────────────
         * 每个包都 printf，stdout I/O 会阻塞、刷 cache、打乱流水线。
         *
         * 正确做法: 用统计计数器，定期打印汇总。见 good_l2fwd.c。
         */
        printf("fwd packet len=%u\n", m->pkt_len);

        /* 单包发送 */
        uint16_t sent = rte_eth_tx_burst(port_out, 0, &m, 1);
        if (sent == 0)
            rte_pktmbuf_free(m);
    }
}

/*
 * 瓶颈 4: 单队列 + 没有 RSS
 * ──────────────────────────
 * 只配 1 个 RX queue 和 1 个 TX queue。
 * 所有流量集中在 queue 0 → lcore 0 单核处理。
 * 10Gbps 线速下小包约 14.88 Mpps，单核处理不了。
 *
 * 正确做法: 多队列 + RSS，见 good_l2fwd.c。
 */
static int
port_init_bad(uint16_t port, struct rte_mempool *mp)
{
    struct rte_eth_conf port_conf = {0};  /* 没有启用 RSS */
    struct rte_eth_dev_info dev_info;

    int ret = rte_eth_dev_info_get(port, &dev_info);
    if (ret != 0)
        return ret;

    /* 只开 1 个队列 */
    ret = rte_eth_dev_configure(port, 1, 1, &port_conf);
    if (ret != 0)
        return ret;

    ret = rte_eth_rx_queue_setup(port, 0, 128,
            rte_eth_dev_socket_id(port), NULL, mp);
    if (ret != 0)
        return ret;

    ret = rte_eth_tx_queue_setup(port, 0, 128,
            rte_eth_dev_socket_id(port), NULL);
    if (ret != 0)
        return ret;

    ret = rte_eth_dev_start(port);
    return ret;
}

/*
 * 瓶颈 5: NUMA 不对齐
 * ──────────────────────
 * mempool 可能在 NUMA 0，但网卡在 NUMA 1。
 * 每个 mbuf 分配和释放都跨 NUMA。
 *
 * 这在 port_init_bad() 中体现为: mp 是外部传入的，
 * 调用者可能用了 socket_id 不匹配的 pool。
 *
 * 正确做法: 查 port 所在 NUMA，创建对应的 mempool。
 * 见 good_l2fwd.c 的 per-socket pool。
 */

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

    /*
     * 瓶颈 5 (续): 只创建一个 mempool，不管 NUMA
     * 所有 port 共用一个 pool，NUMA 不匹配时就跨 socket
     */
    struct rte_mempool *mp = rte_pktmbuf_pool_create("bad_pool",
            8191, 250, 0, RTE_MBUF_DEFAULT_BUF_SIZE, 0);

    /* port 0 → port 1 转发 */
    port_init_bad(0, mp);
    port_init_bad(1, mp);

    printf("bad_l2fwd running (intentionally bad for demo)\n");
    main_loop_bad_burst(0, 1);

    rte_eth_dev_stop(0);
    rte_eth_dev_stop(1);
    rte_eal_cleanup();
    return 0;
}
