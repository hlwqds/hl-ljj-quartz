---
title: DPDK flow_filtering 虚拟网卡验证与原理深度指南
date: 2026-01-04 00:00:00
pin: true
tags: [DPDK, dpdk, flow_filtering, net_tap, verification]
---

> [!abstract] DPDK 高性能开发系列文章
>
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

# DPDK `flow_filtering` 虚拟网卡验证与原理深度指南

本文档介绍了如何使用虚拟网卡验证 DPDK `flow_filtering` 示例程序，并深入解析了其中的异步提交机制与底层驱动实现。

---

## 1. 验证方案选择：为什么是 `net_tap`？

在没有物理硬件（如 NVIDIA ConnectX 系列网卡）的情况下，验证 `rte_flow` 逻辑需要驱动程序支持流规则仿真。

- **`net_pcap`**：不支持 `rte_flow`，仅能进行简单的包收发。
- **`net_tap`**：支持将 `rte_flow` 规则映射到 Linux 内核的 **TC (Traffic Control) Flower** 分类器。它是验证流规则分流逻辑的最佳虚拟设备。

---

## 2. 核心原理补充：`postpone` 属性

在示例代码的 `rte_flow_async_create` 调用中，没有显式调用 `rte_flow_push`，这是由 `ops_attr` 控制的：

```c
struct rte_flow_op_attr ops_attr = { .postpone = 0 };
```

- **`postpone = 1`**：操作仅进入软件队列，必须调用 `rte_flow_push()` 才会发送给硬件。
- **`postpone = 0`**：驱动程序在接口内部执行隐式提交。对于 `net_tap` 或某些硬件驱动，这意味着规则立即生效。

---

## 3. 验证步骤

### 3.1 流量生成脚本 (`send_traffic.py`)

使用 Python 原始套接字构造匹配与不匹配的数据包。

```python
import socket
import struct
import time

def create_ipv4_packet(dst_ip):
    # Ethernet Header (Dst: 02:00:00:00:00:01, Src: 02:00:00:00:00:02)
    eth = struct.pack('!6s6sH', b'\x02\x00\x00\x00\x00\x01', b'\x02\x00\x00\x00\x00\x02', 0x0800)
    # IPv4 Header (UDP Proto=17)
    iph = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20, 1, 0, 64, 17, 0,
                      socket.inet_aton('10.0.0.1'), socket.inet_aton(dst_ip))
    return eth + iph

def main():
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.bind(("dtap0", 0))

    print("Sending Match Packet (192.168.1.1)...")
    s.send(create_ipv4_packet('192.168.1.1')) # 匹配规则 -> Queue 1

    time.sleep(1)

    print("Sending Non-Match Packet (192.168.1.2)...")
    s.send(create_ipv4_packet('192.168.1.2')) # 不匹配 -> Queue 0
```

### 3.2 运行 DPDK 程序

由于 `net_tap` 暂不支持 Template API，需使用传统模式：

```bash
# 启动程序 (创建 dtap0 接口)
sudo ./build/examples/dpdk-flow_filtering -l 1 -n 4 \
    --vdev=net_tap0,queues=4 -- --non-template

# 在另一个终端启动接口并发送流量
sudo ip link set dtap0 up
sudo python3 send_traffic.py
```

---

## 4. `net_tap` 底层工作原理

### 4.1 TC Flower 映射

`net_tap` 驱动将 `rte_flow` 转换为 Linux 内核的 TC 过滤器：

1.  **解析**: 将 `rte_flow_item` (如 IPv4 Dst) 转换为 Netlink 属性 `TCA_FLOWER_KEY_IPV4_DST`。
2.  **动作**: 将 `RTE_FLOW_ACTION_TYPE_QUEUE` 转换为 `skbedit` 动作。
3.  **提交**: 通过 Netlink 套接字将规则下发至内核。

### 4.2 数据路径

数据从内核到 DPDK 的旅程：

1.  **内核接收**: 数据包到达虚拟接口。
2.  **分流**: 内核 TC 子系统执行 Flower 匹配，`skbedit` 修改数据包的 `queue_mapping`。
3.  **读取**: DPDK PMD 轮询时，通过 `readv()` 系统调用从对应的文件描述符（每个队列一个 FD）中拷贝数据。

---

## 5. 总结

- **性能权衡**: 虚拟网卡验证虽然由于系统调用和内存拷贝性能较低，但能完美复现流规则逻辑。
- **调试建议**: 如果规则未生效，检查内核是否开启了 `CONFIG_NET_CLS_FLOWER` 支持。
