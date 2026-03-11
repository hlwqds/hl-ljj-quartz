---
title: "DPDK ip_fragmentation 深度指南：内存池机制与虚拟化验证"
date: 2026-01-04 00:00:00
pin: true
tags: [dpdk, ip-fragmentation, mbuf, networking]
---


# DPDK `ip_fragmentation` 深度指南：内存池机制与虚拟化验证

本文档详细介绍了 DPDK 中 IP 分片的实现原理，特别是 `direct_pool` 与 `indirect_pool` 的协作机制，并提供了基于虚拟网卡的验证方案。

---

## 1. 核心概念：Direct vs. Indirect Pool

在 `ip_fragmentation` 示例中，定义了两个关键内存池，其区别如下：

| 特性 | `socket_direct_pool` (直接内存池) | `socket_indirect_pool` (间接内存池) |
| :--- | :--- | :--- |
| **Mbuf 类型** | Direct Mbuf | Indirect Mbuf |
| **数据区** | 自带独立的数据缓冲区 (Data Buffer) | **不带数据缓冲区** |
| **数据来源** | 存储完整包或第一个分片的头部+数据 | 通过指针**引用**原始 Direct Mbuf 的数据区 |
| **用途** | 接收数据包、存储第一个分片 | 存储后续分片，实现**零拷贝 (Zero-Copy)** |
| **内存开销** | 较大 (Mbuf头 + Data Buffer) | 极小 (仅 Mbuf 结构体) |

---

## 2. 分片处理流程 (`rte_ipv4_fragment_packet`)

以下是该函数如何利用两个内存池进行高效分片的逻辑流程：

```text
                                  [ 输入大包 (Input Mbuf) ]
                                              |
                                              v
+---------------------------------------------------------------------------------------+
|  rte_ipv4_fragment_packet(input_mbuf, out_pkts[], nb_pkts, mtu, direct_pool, indirect_pool) |
+---------------------------------------------------------------------------------------+
                                              |
                                              v
                               [ 检查: 是否超过 MTU? ]
                                     /                 \
                                   NO                   YES
                                   |                     v
                           [ 直接转发 ]          [ 计算分片数量 N ]
                                                         |
    +----------------------------------------------------+--------------------------------------+
    |                                     分片循环 (i = 0 to N-1)                               |
    +------------------------------------------------------------------------------------------+
    |                                                                                           |
    |   < 索引 i == 0 ? >  --------------------------------------------------+                  |
    |      /          \                                                      |                  |
    |    YES           NO (后续分片)                                          |                  |
    |     |              |                                                   |                  |
    |     v              v                                                   |                  |
    |  [ 申请 mbuf ]   [ 申请 mbuf ]                                          |
    |  来源:           来源:                                                  |
    |  DIRECT POOL     INDIRECT POOL                                         |
    |     |              |                                                   |
    |     v              v                                                   |
    | [ 填充数据 ]     [ 挂载数据 (Attach) ]                                   |
    | - 复制协议头     - 指向 input_mbuf 数据区的特定偏移                      |
    |                  - **零拷贝引用**，不发生数据 memcpy                     |
    |                                                                        |
    |     v              v                                                   |
    | [ 更新 IP 头 ]   [ 更新 IP 头 ]                                          |
    | - 设置 Len/Flags - 设置 Len/Flags (MF=1 或 0)                          |
    | - 设置 Offset    - 设置分片 Offset                                      |
    | - 计算 Checksum  - 计算 Checksum                                         |
    |                                                                        |
    |     +--------------+---------------------------------------------------+                  |
    |                    |                                                                      |
    |                    v                                                                      |
    |          [ 放入 out_pkts[i] 数组 ]                                                     |
    +------------------------------------------------------------------------------------------+
```

---

## 3. 虚拟网卡验证方案 (`net_tap`)

### 3.1 环境准备
使用 `net_tap` 创建两个虚拟端口，分别作为输入和输出。

```bash
# 启动程序
sudo ./build/examples/dpdk-ip_fragmentation -l 1 -n 4 \
    --vdev=net_tap0,iface=dtap0 \
    --vdev=net_tap1,iface=dtap1 \
    -- -p 3 -q 2
```

### 3.2 流量生成脚本 (`send_huge_pkt.py`)
构造超过 1500 字节的包发送至 `dtap0`：

```python
import socket, struct
# 构造以太网头 + 2000 字节载荷的 IPv4 包
# DstIP 需匹配 LPM 表路由 (例如 100.20.0.1 -> Port 1)
def create_large_pkt():
    eth = struct.pack('!6s6sH', b'\x02\x00\x00\x00\x00\x00', b'\x02\x00\x00\x00\x00\x01', 0x0800)
    iph = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 2020, 12345, 0, 64, 17, 0, 
                      socket.inet_aton('100.10.0.1'), socket.inet_aton('100.20.0.1'))
    return eth + iph + b'A' * 2000

# 发送至 dtap0
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind(("dtap0", 0))
s.send(create_large_pkt())
```

### 3.3 验证结果
在 `dtap1` 上使用 `tcpdump` 观察：
```bash
sudo tcpdump -n -i dtap1 ip -v
```
**预期现象**：看到两个分片包，第一个长度约 1500 (Flags [+])，第二个包含剩余数据 (Flags [none])。

---

## 4. 总结
*   `indirect_pool` 是 DPDK 分片性能卓越的核心原因，它通过 mbuf 链表式引用避免了内存的大规模拷贝。
*   分片过程中，原始大包的引用计数会增加，直到所有分片发送完毕后才会真正释放。

