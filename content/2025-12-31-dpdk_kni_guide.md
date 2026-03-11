---
title: "DPDK KNI (Kernel NIC Interface) 深度指南"
date: 2025-12-31 00:00:00
pin: true
tags: [dpdk, kni, networking]
---


# DPDK KNI (Kernel NIC Interface) 深度指南

## 1. KNI 是什么？

KNI (Kernel NIC Interface) 是 DPDK 提供的一种特殊的接口机制，旨在解决 DPDK 应用程序独占物理网卡后，Linux 内核无法再访问该网卡的问题。简而言之，KNI 允许在 DPDK 用户态应用和 Linux 内核网络栈之间建立一个**双向数据通道和控制通道**。

## 2. 为什么需要 KNI？

当 DPDK 应用程序接管一个物理网卡时，该网卡将从 Linux 内核的网络设备列表中“消失”。这意味着：
*   **网络功能受限**：标准的 Linux 网络工具和服务（如 `ping`, `ssh`, `iperf`, `dhclient`, `route` 等）将无法通过该网卡进行操作。
*   **管理不便**：无法为该网卡配置 IP 地址、路由规则或进行链路状态监控。

KNI 的出现就是为了弥补这一鸿沟，让 DPDK 应用程序在提供高性能数据面转发的同时，也能与 Linux 内核的强大网络功能和管理工具协同工作。

## 3. KNI 的工作原理

KNI 的实现涉及 DPDK 应用程序（用户态）和 `rte_kni` 内核模块（内核态）之间的协作。

### 3.1. 数据路径

1.  **从 DPDK 到内核**：
    *   DPDK 应用程序识别出需要由内核处理的数据包（例如 ARP 请求、ICMP 包、SSH 流量等）。
    *   DPDK 应用程序调用 `rte_kni_tx_burst()` 或类似 API，将这些数据包发送到 KNI 接口。
    *   `rte_kni` 内核模块接收到这些包，并将其注入到 Linux 内核的网络协议栈中。
    *   内核像收到普通网卡包一样处理这些流量。

2.  **从内核到 DPDK**：
    *   Linux 内核决定通过 KNI 接口发送数据包（例如 `ping` 从 KNI 接口发出）。
    *   `rte_kni` 内核模块从内核接收这些包。
    *   DPDK 应用程序通过调用 `rte_kni_rx_burst()` 或类似 API 从 KNI 接口接收这些包，并像处理物理网卡包一样对待它们。

### 3.2. 控制路径

控制路径允许 Linux 内核通过标准命令（如 `ifconfig`, `ip link`）来控制 DPDK 接管的物理网卡的状态（如 UP/DOWN, MTU 设置）。

1.  **用户操作**：管理员在 Linux 命令行执行 `ifconfig kni0 up` 或 `ip link set kni0 mtu 1500`。
2.  **内核拦截**：`rte_kni` 内核模块拦截这些针对 KNI 设备的网络控制命令。
3.  **事件通知**：`rte_kni` 内核模块将这些控制请求通过共享内存或专门的通信机制，传递给 DPDK 应用程序。
4.  **DPDK 应用处理**：DPDK 应用程序必须在主循环中定期调用 `rte_kni_handle_request()`。这个函数会检测是否有来自内核的控制请求。
5.  **回调函数**：DPDK 应用程序会调用预先注册好的回调函数（例如 `config_network_interface`），在这些函数中执行真正的硬件操作（如 `rte_eth_dev_set_link_up()` 来开启物理网卡）。

## 4. KNI 的典型使用场景

*   **混合模式转发**：
    *   DPDK 应用程序负责高性能数据包转发（例如所有数据流量）。
    *   Linux 内核处理低速的控制面流量（例如 ARP、ICMP、SSH 远程管理、路由协议如 OSPF/BGP、DHCP、DNS 解析）。
    *   **案例**：构建一个 DPDK 路由器，核心转发逻辑在用户态，而路由表的学习和维护、管理界面则依赖 Linux 内核。

*   **调试与监控**：
    *   允许在内核态使用 `tcpdump` 等工具对 KNI 接口进行抓包，监控 DPDK 应用程序处理前后的数据流。
    *   通过 `ping` 或其他标准工具测试 DPDK 应用程序管理的 IP 地址的可达性。

*   **与传统网络服务集成**：使 DPDK 应用程序能够与 `iptables`、NAT、防火墙等 Linux 内核功能协同工作，而无需重新实现这些功能。

## 5. KNI 的性能考量

*   **性能损失**：`KNI` 的主要缺点是**性能开销**。数据包在 DPDK 用户态和内核态之间传递时，涉及至少两次上下文切换和内存拷贝。
*   **适用场景**：因此，`KNI` 适合处理**低速率、控制面**的流量（如几万到几十万 PPS），不适合 DPDK 追求极致性能的高速数据面核心路径。

## 6. KNI 如何创建与使用？

要使用 KNI，您需要结合系统层面和代码层面的操作。

### 6.1. 系统层面：加载 `rte_kni` 内核模块

在您的 Linux 系统上，KNI 功能依赖于一个专门的内核模块 `rte_kni.ko`。在使用 DPDK KNI 应用程序之前，必须加载此模块。

```bash
# 1. 编译 DPDK 后，rte_kni.ko 模块通常位于 build/kernel/linux/kni/ 目录下
#    请确保您已经编译了 KNI 模块。

# 2. 加载模块。
#    kthread_mode=multiple 参数推荐开启，
#    它允许为每个 KNI 接口使用单独的内核线程，有助于提高控制面处理的响应速度和性能。
sudo insmod /path/to/your/dpdk/build/kernel/linux/kni/rte_kni.ko kthread_mode=multiple
```

### 6.2. 代码层面：DPDK 应用程序中创建 KNI 接口

在您的 DPDK 应用程序的 C 代码中，您需要通过 DPDK 提供的 API 来初始化 KNI 子系统并为每个物理端口分配 KNI 接口。

#### (1) 初始化 KNI 子系统

在 `main` 函数的早期阶段，通常在 EAL 初始化 (`rte_eal_init()`) 之后，需要初始化 KNI 子系统。

```c
#include <rte_kni.h>

// 定义 KNI 接口的最大数量
#define MAX_KNI_INTERFACES 8 

// 在 main 函数中
int main(int argc, char *argv[]) {
    // ... EAL 初始化 ...

    // 初始化 KNI 子系统
    // MAX_KNI_INTERFACES 参数指定了可以创建的 KNI 接口的最大数量
    if (rte_kni_init(MAX_KNI_INTERFACES) < 0) {
        rte_exit(EXIT_FAILURE, "Could not init KNI subsystem\n");
    }

    // ... 其他 DPDK 初始化 ...
}
```

#### (2) 配置并分配 KNI 接口

在 DPDK 端口（物理网卡）完成配置并启动 (`rte_eth_dev_start()`) 之后，您可以为每个端口分配一个或多个 KNI 接口。

```c
#include <rte_kni.h>
#include <rte_ethdev.h> // 用于获取端口信息

// 预定义的回调函数 (稍后实现)
static int kni_config_network_interface(uint16_t port_id, uint8_t if_up);
static int kni_config_mac_address(uint16_t port_id, struct rte_ether_addr *mac_addr);

// 为指定端口创建 KNI 接口的函数示例
struct rte_kni* create_kni_interface(uint16_t port_id, struct rte_mempool *pktmbuf_pool) {
    struct rte_kni *kni;
    struct rte_kni_conf conf;
    struct rte_kni_ops ops;

    // 1. 清空配置结构体，防止使用未初始化的值
    memset(&conf, 0, sizeof(conf));

    // 2. 填写 KNI 接口的基本配置
    // name: KNI 接口在 Linux 系统中显示的名字 (如 vEth0, kni0)。必须唯一。
    snprintf(conf.name, RTE_KNI_NAMESIZE, "vEth%d", port_id); 
    conf.group_id = port_id;       // 可选：用于分组 KNI 接口
    conf.mbuf_size = 2048;         // KNI 接口内部使用的 mbuf 大小
    
    // 绑定到哪个 CPU 核心处理 KNI 内核线程，如果 kthread_mode=multiple 则有效
    // 推荐分配独立的核，避免与数据面核心冲突
    conf.core_id = rte_lcore_id(); // 示例：绑定到当前 lcore
    conf.force_bind = 1;           // 强制绑定到指定核心

    // 3. (可选但推荐) 关联物理端口信息
    // 这有助于 KNI 模块在内核中更好地模拟物理接口的属性（如 PCI 地址），
    // 从而更好地支持 ethtool 等命令。
    struct rte_eth_dev_info dev_info;
    rte_eth_dev_info_get(port_id, &dev_info);
    if (dev_info.pci_dev) { // 确保是 PCI 设备
        conf.addr = dev_info.pci_dev->addr;
        conf.id = dev_info.pci_dev->id;
    }

    // 4. 定义操作回调函数
    // 这些函数在 Linux 内核通过 ifconfig 等命令操作 KNI 接口时被 DPDK 应用程序调用。
    memset(&ops, 0, sizeof(ops));
    ops.port_id = port_id;
    ops.config_network_if = kni_config_network_interface; // 当 ifconfig vEth0 up/down 时被调用
    ops.change_mtu = NULL;                                // 当 ifconfig vEth0 mtu X 时被调用
    ops.config_mac_address = kni_config_mac_address;      // 当 ifconfig vEth0 hw ether XX:YY... 时被调用
    ops.config_promisc_mode = NULL;                       // 混杂模式
    ops.config_allmulticast_mode = NULL;                  // 多播模式

    // 5. 真正分配 KNI 接口
    // pktmbuf_pool 是 DPDK 的内存池，用于 KNI 接口内部收发 mbuf
    kni = rte_kni_alloc(pktmbuf_pool, &conf, &ops);

    if (!kni) {
        rte_exit(EXIT_FAILURE, "Fail to create KNI for port %u\n", port_id);
    }
    return kni;
}
```

#### (3) 实现 KNI 回调函数示例

这些回调函数是 KNI 机制中控制路径的关键。它们是您 DPDK 应用程序如何响应 Linux 内核命令的实现。

```c
// 示例：处理 ifconfig vEthX up/down 命令
static int kni_config_network_interface(uint16_t port_id, uint8_t if_up) {
    if (if_up) {
        printf("KNI: Interface vEth%u UP\n", port_id);
        rte_eth_dev_set_link_up(port_id); // 调用 DPDK API 开启物理口链路
    } else {
        printf("KNI: Interface vEth%u DOWN\n", port_id);
        rte_eth_dev_set_link_down(port_id); // 调用 DPDK API 关闭物理口链路
    }
    return 0;
}

// 示例：处理 ifconfig vEthX hw ether XX:YY... 命令
static int kni_config_mac_address(uint16_t port_id, struct rte_ether_addr *mac_addr) {
    printf("KNI: Interface vEth%u set MAC: %02X:%02X:%02X:%02X:%02X:%02X\n",
           port_id, mac_addr->addr_bytes[0], mac_addr->addr_bytes[1],
           mac_addr->addr_bytes[2], mac_addr->addr_bytes[3],
           mac_addr->addr_bytes[4], mac_addr->addr_bytes[5]);
    rte_eth_macaddr_set(port_id, mac_addr); // 调用 DPDK API 设置物理口 MAC
    return 0;
}
```

#### (4) 核心循环中的 KNI 处理

在 DPDK 应用程序的主循环中，除了处理物理网卡的收发包外，您还需要定期调用 KNI 的处理函数，以确保数据和控制命令的及时交换。

```c
// 在主 lcore 的数据处理循环中
while (!force_quit) {
    // 1. 处理 KNI 控制请求 (非常重要，否则 ifconfig 命令不会生效)
    rte_kni_handle_request(kni); 

    // 2. 从 KNI 接收来自内核的包 (例如内核 ping 或发出的数据)
    //    这些包需要被 DPDK 应用转发到物理网卡
    nb_kni_rx = rte_kni_rx_burst(kni, pkts_burst, MAX_PKT_BURST);
    if (nb_kni_rx > 0) {
        // ... 将这些包通过 rte_eth_tx_burst() 发送到物理网卡 ...
    }

    // 3. 从物理网卡接收包
    nb_rx = rte_eth_rx_burst(port_id, queue_id, pkts_burst, MAX_PKT_BURST);
    for (i = 0; i < nb_rx; i++) {
        struct rte_mbuf *m = pkts_burst[i];

        // 4. 判断包是否需要给内核处理
        if (is_control_packet(m)) { // 您的判断逻辑，如 ARP, ICMP, SSH 等
            // 发送给内核
            rte_kni_tx_burst(kni, &m, 1);
        } else {
            // 否则在 DPDK 用户态处理 (如转发)
            // ... fast_path_process(m); ...
        }
    }
}
```

### 7. KNI 示例代码在哪里？

DPDK 官方源码中提供了一个完整的 KNI 示例应用程序，位于 `examples/kni/`。

强烈建议您查阅 `examples/kni/main.c` 文件。它实现了上述所有步骤，并展示了如何优雅地集成 KNI 功能。通过编译和运行这个示例，您可以更好地理解 KNI 的实际工作方式。

```
