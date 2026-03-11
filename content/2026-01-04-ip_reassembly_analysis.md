---
title: "DPDK IP Reassembly 示例分析与测试指南"
date: 2026-01-04 00:00:00
pin: true
tags: [dpdk, network, ip-reassembly, fragment, tap]
---

> [!abstract] DPDK 高性能开发系列文章
> - [[2025-12-16-dpdk-open-euler-setup|环境搭建]]
> - [[2026-01-05-dpdk_portable_lab_guide|移动实验环境]]
> - [[2025-12-09-dpdk-mem|内存管理汇总]]
> - [[2025-12-16-dpdk-adjust-nb-rx-tx-desc|描述符调整]]
> - [[2025-12-16-dpdk-tx-offload-mbuf-fast-free|MBUF 快速释放]]
> - [[2025-12-31-dpdk_callbacks_guide|Callbacks 深度指南]]
> - [[2025-12-31-dpdk_mbuf_dynfield_register_guide|动态字段注册]]
> - [[2025-12-31-dpdk_kni_guide|KNI 深度指南]]
> - [[2025-12-31-dpdk_virtual_devices_guide|虚拟网卡指南]]
> - [[2026-01-04-dpdk_ip_fragmentation_guide|IP 分片]]
> - [[2026-01-04-ip_reassembly_analysis|IP 重组]]
> - [[2026-01-04-ipv4_multicast_guide|IPv4 组播]]
> - [[2026-01-04-软件流水线技术详解|软件流水线优化]]
> - [[2026-01-04-dpdk_flow_template_guide|Template API]]
> - [[2026-01-04-dpdk_flow_filtering_verification|流过滤验证]]
> - [[2026-01-05-l2fwd_keepalive_analysis|Keepalive 监控]]





# DPDK IP Reassembly 示例分析与测试指南

本文档详细分析了 DPDK `examples/ip_reassembly/main.c` 的代码逻辑，并提供了使用虚拟网卡 (`net_tap`) 进行验证的完整指南。

## 1. 代码详细分析

`examples/ip_reassembly` 是一个具备 **IP 分片重组** 功能的 L3 转发器示例。

### 1.1 核心功能与流程
程序的生命周期可以概括为：
1.  **初始化 (Init)**：建立内存池、LPM 路由表、配置网卡。
2.  **配置分片表 (Frag Table Setup)**：为每个 RX 队列创建一个重组表 (`rte_ip_frag_tbl`)。
3.  **主循环 (Main Loop)**：在每个 lcore 上不断轮询 RX 队列。
4.  **重组与转发 (Reassemble & Forward)**：检查报文是否分片 -> 尝试重组 -> 查表路由 -> 修改 MAC -> 发送。

### 1.2 关键数据结构

*   **`struct rte_ip_frag_tbl *frag_tbl`**：
    *   DPDK 库提供的核心结构，用于在内存中通过哈希表追踪所有未完成的分片。
    *   由 `rte_ip_frag_table_create` 创建。
    *   `max_flow_num` (最大流数量) 和 `max_flow_ttl` (分片最大生存时间) 决定了它的容量和超时策略。

*   **`struct rte_ip_frag_death_row death_row`**：
    *   辅助结构，用于暂存因超时或错误需要释放的 mbuf。为了性能，DPDK 采用延迟批量释放策略。

*   **路由表 (`l3fwd_ipv4_route_array`)**：
    *   代码中硬编码的简单路由表：
        *   `100.10.x.x` -> Port 0
        *   `100.20.x.x` -> Port 1
        *   ... 以此类推。

### 1.3 核心函数解析

**`main()` 函数：**
*   **`init_mem()`**：创建 LPM 表用于路由查找。
*   **`setup_queue_tbl()`**：**关键步骤**。为每个接收队列创建一个 `frag_tbl`。根据 TTL 计算 `frag_cycles` 用于判断分片超时。

**`reassemble()` 函数 (重组逻辑核心)：**
1.  **判断分片**：使用 `rte_ipv4_frag_pkt_is_fragmented(ip_hdr)` 检查。
2.  **执行重组**：
    *   调用 `rte_ipv4_frag_reassemble_packet(tbl, dr, m, tms, ip_hdr)`。
    *   **返回 NULL**：报文不完整，仍在等待后续分片，函数直接返回。
    *   **返回指针**：重组完成，返回完整的大包（mbuf）。
3.  **路由查找**：
    *   对完整包（或重组后的包）使用 `rte_lpm_lookup` 查找目的端口。
4.  **MAC 修改**：
    *   目的 MAC 修改为 `02:00:00:00:00:xx` (xx 为端口号)。
    *   源 MAC 修改为当前发送端口的 MAC。

**`main_loop()` 函数：**
*   `rte_eth_rx_burst` 批量收包。
*   调用 `reassemble()` 处理。
*   定期调用 `rte_ip_frag_free_death_row()` 清理超时分片。

---

## 2. 使用虚拟网卡 (`net_tap`) 进行测试

使用 Linux 的 TAP 接口模拟物理网卡，验证 DPDK 的重组逻辑。

### 2.1 测试环境准备
假设已编译好 DPDK 示例程序。

### 2.2 启动 DPDK 程序
使用 `--vdev` 创建两个 TAP 接口 (`dtap0`, `dtap1`)。

```bash
# -l 1: 使用 Core 1 运行业务
# --vdev: 创建虚拟设备
# -- -p 0x3: 启用 Port 0 和 Port 1
sudo ./build/examples/dpdk-ip_reassembly -l 1 \
    --vdev=net_tap0,iface=dtap0 \
    --vdev=net_tap1,iface=dtap1 \
    -- -p 0x3 -q 2
```

### 2.3 配置 Linux 网络环境
在另一个终端中配置 IP 和路由。目标是构造一个需要从 Port 0 进，经 Port 1 出的流量。
代码路由表：`100.20.0.0/16` -> Port 1。

```bash
# 1. 启用接口
sudo ip link set dtap0 up
sudo ip link set dtap1 up

# 2. 配置 IP (作为网关 IP)
sudo ip addr add 192.168.10.1/24 dev dtap0
sudo ip addr add 192.168.20.1/24 dev dtap1

# 3. 添加路由：让去往 100.20.1.1 的包走 dtap0 (即送给 DPDK Port 0)
sudo ip route add 100.20.1.1/32 dev dtap0

# 4. 静态 ARP (重要)：欺骗 Linux 内核，让它能发包
sudo arp -s 100.20.1.1 02:00:00:00:00:00 -i dtap0
```

### 2.4 执行测试与验证

**终端 A (验证接收):**
监听 `dtap1`，看是否收到重组后的大包。
```bash
sudo tcpdump -i dtap1 -n -e -v
```

**终端 B (发送分片包):**
发送 3000 字节的大包。由于 TAP 接口默认 MTU 为 1500，Linux 内核会自动分片。
```bash
ping -s 3000 -c 1 100.20.1.1
```

**预期结果:**
在终端 A 的 `tcpdump` 中，你应该看到一个长度约为 3000+ 字节的 **单个数据包** (Jumbo Frame)，而不是多个分片。这证明 DPDK 成功接收了分片并重组。

---

## 3. 深入理解：为什么会有分片？

**问题**：`ping -s 3000` 是用户态程序，为什么数据包还没到 DPDK 就分片了？

**解答**：
1.  **发送源**：`ping` 调用系统调用发送数据。
2.  **Linux 内核协议栈**：内核处理 IP 层逻辑，查找路由发现出接口是 `dtap0`。
3.  **MTU 检查**：内核发现待发送数据 (3028字节) > `dtap0` 的 MTU (1500字节)。
4.  **内核分片**：**Linux 内核**主动将数据切分为 3 个分片。
5.  **网卡发送**：内核将 3 个分片写入 TAP 设备。
6.  **DPDK 接收**：DPDK 从 TAP 设备读到的就是这 3 个已经切碎的包。

**结论**：DPDK 接收到的分片是由 **Linux 内核** 在发送路径上产生的。DPDK 程序的任务是将它们还原。

如果将 TAP 接口 MTU 改为 4000 (`ip link set dtap0 mtu 4000`)，内核就不会分片，DPDK 将直接收到一个完整的大包，此时 `rte_ipv4_frag_pkt_is_fragmented` 将返回 false，直接转发。

---

## 4. 常见疑问解答

### 4.1 为什么必须配置路由表？不能强制指定 Ping 的网卡吗？

用户常问：*“为什么不能直接用 `ping -I dtap0 ...` 强制发包，而必须配置 `ip route`？”*

**核心原因**：Linux 内核在发包前必须确认“逻辑路径是通的”，否则会拒绝操作。

1.  **不可达检查 (Reachability Check)**：
    *   内核检查目标 IP 是否在当前接口的子网内。
    *   如果不在子网内且没有路由条目，内核会判定为“网络不可达 (Network is unreachable)”，拒绝将包放入网卡队列，即使你指定了 `-I` 参数。

2.  **ARP 解析依赖**：
    *   发包需要封装以太网头，必须知道下一跳的 MAC 地址。
    *   **同子网**：ARP 请求直接发给目标 IP。
    *   **跨子网**：ARP 请求发给网关。
    *   如果没有路由表指示网关或链路关系，内核不知道向谁发 ARP，导致无法封装数据包。

**替代方案**：
如果不配置路由，唯一的办法是将 TAP 接口 IP 配置为与目标 IP **同一网段**（例如给 dtap0 配 `100.20.1.2/24`），这样内核会视为“直连路由”。但配置路由表 (`ip route add`) 是更标准、更灵活的做法。

### 4.2 `rte_ip_frag_death_row` 中元素的删除时机

`death_row` 是 DPDK 为了性能优化设计的**延迟释放**机制。

1.  **何时进入 death_row？**
    *   **分片超时**：流过期，旧分片被移入。
    *   **重组完成**：重组成功后，原始的分片 mbuf 被移入。
    *   **哈希碰撞/驱逐**：为了腾出空间给新流，旧流被强制移入。
    *   *注意：此时 mbuf 尚未真正释放回内存池。*

2.  **何时真正删除（释放）？**
    *   真正释放发生在调用 **`rte_ip_frag_free_death_row()`** 时。
    *   在 `main.c` 中，该函数位于 `main_loop` 的 **RX Burst 循环末尾**。
    *   这意味着：**每处理完一波收包（Burst），统一清理一次垃圾**。

3.  **设计哲学**
    *   **批处理**：减少对内存池 Ring 的频繁操作锁竞争。
    *   **缓存友好**：避免在重组运算密集期频繁切换上下文去操作内存分配器，提高 CPU Cache 命中率。
---
## 外部参考
- [DPDK 官方文档](https://doc.dpdk.org/)
- [Intel 网卡开发者指南](https://www.intel.com/)
