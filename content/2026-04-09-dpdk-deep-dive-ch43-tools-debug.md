---
title: "DPDK 深度探索 ch43：调试工具"
date: 2026-04-10 17:00:00
tags: [dpdk, devbind, tool, debugging, dump, trace, debug, ethtool]
description: "深入解析 DPDK 调试工具：dpdk-devbind、pdump、DumpTool、ethdump、十六进制查看与日志配置"
---

# DPDK 深度探索 ch43：调试工具

> [!abstract] 核心要点
> 调试工具是 DPDK 开发的基础。本章深入解析 dpdk-devbind、pdump、rte_flow、ethdump 与日志系统。

## 1. dpdk-devbind

### 1.1 概述

```
dpdk-devbind — 绑定网络设备到 DPDK UIO 驱动：

┌─────────────────────────────────────────────────────────────┐
│                    设备状态                                 │
│                                                              │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐ │
│  │  kernel    │ ←──→ │  igb_uio   │ ←──→ │  vfio-pci  │ │
│  │  driver   │      │            │      │            │ │
│  └─────────────┘      └─────────────┘      └─────────────┘ │
│       (native)            (legacy)             (secure)      │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 基本使用

```bash
# 查看所有网络设备
sudo dpdk-devbind --status

# 示例输出:
# Network devices using DPDK-compatible driver
# ============================================
# 0000:3d:00.0 'Ethernet 10G 4P X520' drv=igb_uio unused=
# 0000:3d:00.1 'Ethernet 10G 4P X520' drv=igb_uio unused=

# Network devices using kernel driver
# ===================================
# 0000:3a:00.0 'I350 Gigabit Network' drv=igb unused=e1000e

# Unused devices
# ==============
# 0000:3b:00.0 'Ethernet 10G 4P X540' drv=unused
```

### 1.3 绑定设备

```bash
# 绑定到 igb_uio
sudo dpdk-devbind --bind=igb_uio 0000:3d:00.0

# 绑定到 vfio-pci
sudo dpdk-devbind --bind=vfio-pci 0000:3d:00.0

# 解除绑定 (回到 kernel)
sudo dpdk-devbind --bind=ixgbe 0000:3d:00.0

# 强制绑定 (用于 VF)
sudo dpdk-devbind --force 0000:3d:00.0

# 绑定多个设备
sudo dpdk-devbind --bind=igb_uio 0000:3d:00.0,0000:3d:00.1
```

### 1.4 脚本示例

```bash
#!/bin/bash
# setup_dpdk.sh

# 加载驱动
modprobe igb_uio
modprobe vfio-pci

# 配置 hugepage
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 绑定 NIC
DEVICES="0000:3d:00.0 0000:3d:00.1"

for DEV in $DEVICES; do
    echo "Binding $DEV..."
    sudo dpdk-devbind --bind=igb_uio $DEV
done

# 显示状态
dpdk-devbind --status
```

## 2. pdump

### 2.1 概述

```
pdump — DPDK 数据包捕获工具：

- 基于 libpcap 的轮询模式
- 零拷贝捕获
- 支持多端口/多队列
- 可选过滤

注意: pdump 需要额外启动一个 pthread 进行捕获
```

### 2.2 编译启用

```bash
# 编译 pdump
cd dpdk
make -C app/pdump

# 或者 meson
meson setup build
ninja -C build app/pdump
```

### 2.3 使用方法

```bash
# 基本捕获
sudo ./build/app/pdump \
    --xstats \
    --total-mask 1 \
    --portmask 0x3 \
    --rx-queue 0

# 捕获指定端口
sudo ./build/app/pdump \
    -d 0000:3d:00.0 \
    --rx-only \
    --capture-file /tmp/capture.pcap

# 显示统计
sudo ./build/app/pdump -s
```

### 2.4 应用集成

```c
// 在应用中启用 pdump
#include <rte_pdump.h>

int
enable_pdump(uint16_t port_id, uint16_t queue_id)
{
    struct rte_pdump_params params = {
        .port = port_id,
        .queue = queue_id,
        .filter = {
            . promisc = 1,  // 混杂模式
        },
    };

    // 启动 pdump server
    return rte_pdump_init(NULL);
}

// 客户端连接
// rte_pdump客户端需要在另一个进程中运行
```

## 3. DumpTool

### 3.1 十六进制导出

```bash
# 使用 testpmd 导出数据包
testpmd> set verbose 1
testpmd> start
testpmd> show port all roundrobin
testpmd> stop
testpmd> quit
```

### 3.2 自定义 Dump

```c
// DPDK 数据包导出
#include <rte_hexdump.h>

void
dump_packet(struct rte_mbuf *pkt)
{
    uint8_t *data = rte_pktmbuf_mtod(pkt, uint8_t *);
    uint16_t len = rte_pktmbuf_data_len(pkt);

    // 打印十六进制
    rte_hexdump(stdout, "Packet", data, len);

    // 打印 Ethernet 头
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(pkt,
                              struct rte_ether_hdr *);
    printf("Src MAC: %02x:%02x:%02x:%02x:%02x:%02x\n",
           eth->src_addr.addr_bytes[0],
           eth->src_addr.addr_bytes[1],
           eth->src_addr.addr_bytes[2],
           eth->src_addr.addr_bytes[3],
           eth->src_addr.addr_bytes[4],
           eth->src_addr.addr_bytes[5]);

    // 打印 IP 头
    struct rte_ipv4_hdr *ip =
        (struct rte_ipv4_hdr *)(eth + 1);
    printf("Src IP: %s\n", inet_ntoa(ip->src_addr));
}

// 打印 mbuf 信息
void
dump_mbuf(struct rte_mbuf *pkt)
{
    printf("mbuf: off=%u len=%u pkt_len=%u ref=%u\n",
           pkt->data_off,
           pkt->data_len,
           pkt->pkt_len,
           rte_pktmbuf_get_refcnt(pkt));
}
```

## 4. ethtool

### 4.1 网卡信息

```bash
# 查看接口信息
ethtool eth0

# 示例输出:
# Settings for eth0:
#     Speed: 10000Mb/s
#     Duplex: Full
#     Port: Fiber
#     PHYAD: 0
#     Transceiver: external
#     Auto-negotiation: off
#     Wake-on: d
#     Link detected: yes
```

### 4.2 队列配置

```bash
# 查看队列
ethtool -l eth0

# 配置队列
ethtool -L eth0 combined 4

# 查看队列环
ethtool -g eth0

# 配置 ring size
ethtool -G eth0 rx 4096 tx 4096
```

### 4.3 offload 配置

```bash
# 查看 offload
ethtool -k eth0

# 示例:
# tcp-segment-offload: on
# udp-fragmentation-offload: off [fixed]
# generic-segment-offload: on [fixed]
# generic-receive-offload: on
# large-receive-offload: on

# 启用/禁用 offload
ethtool -K eth0 tcp-segment-offload on
ethtool -K eth0 gro on
ethtool -K eth0 gso on

# 查看 flow control
ethtool -a eth0

# 配置 flow control
ethtool -A eth0 tx on rx on
```

### 4.4 统计

```bash
# 查看统计
ethtool -S eth0

# 监控
watch -n 1 'ethtool -S eth0 | grep -E "(rx_|tx_)"'
```

## 5. rte_flow 调试

### 5.1 Flow 规则查看

```bash
# 使用 testpmd 查看 flow rules
testpmd> flow list 0

# 显示所有规则
testpmd> show flow list 0

# 验证规则
testpmd> flow validate 0 group 1 ingress \
    pattern eth type is 0x0800 / ipv4 / tcp / end \
    actions rss queues 0 1 / mark id 0 / end
```

### 5.2 Flow 规则创建

```c
// 创建丢弃规则
int
create_drop_rule(uint16_t port_id, uint32_t src_ip)
{
    struct rte_flow_attr attr = {
        .ingress = 1,
        .priority = 1,
    };

    struct rte_flow_item pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = &(struct rte_flow_item_ipv4) {
                .hdr.src_addr = src_ip,
            },
            .mask = &(struct rte_flow_item_ipv4) {
                .hdr.src_addr = UINT32_MAX,
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_DROP,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    struct rte_flow *flow = rte_flow_create(
        port_id, &attr, pattern, actions, NULL);

    return flow ? 0 : -1;
}
```

## 6. 日志系统

### 6.1 日志级别

```c
#include <rte_log.h>

// 日志级别
// RTE_LOG_EMERG   = 0  系统不可用
// RTE_LOG_ALERT   = 1  需要立即处理
// RTE_LOG_CRIT    = 2  严重错误
// RTE_LOG_ERR     = 3  错误
// RTE_LOG_WARNING = 4  警告
// RTE_LOG_NOTICE  = 5  需要注意
// RTE_LOG_INFO    = 6  信息
// RTE_LOG_DEBUG   = 7  调试

// 设置全局日志级别
rte_log_set_global_level(RTE_LOG_INFO);

// 设置特定类型日志
RTE_LOG(INFO, USER1, "Message: %s\n", "test");

// 自定义日志类型
RTE_LOG_REGISTER(my_logtype, user.myapp, INFO);
#define MY_LOG(level, ...) RTE_LOG(level, USER1, __VA_ARGS__)
```

### 6.2 日志输出

```c
// 配置日志
int
setup_logging(const char *name)
{
    // 设置日志级别
    rte_log_set_global_level(RTE_LOG_DEBUG);

    // 设置类型级别
    struct rte_log_dynamic_reg {
        uint32_t logtype;
        int level;
    };

    // 动态日志
    int level = rte_log_register(name);
    rte_log_set_level(level, RTE_LOG_INFO);

    return 0;
}

// 日志到文件
FILE *
open_log_file(const char *path)
{
    FILE *f = fopen(path, "a");
    if (f) {
        rte_openlog_stream(f);
    }
    return f;
}
```

## 7. 调试技巧

### 7.1 常见问题

```
DPDK 常见问题：

1. 设备无法绑定
   - 检查 IOMMU 是否启用
   - 检查驱动是否加载
   - 尝试 --force

2. 内存不足
   - 增加 hugepage
   - 检查其他进程内存占用

3. 性能低
   - 检查 CPU 绑定
   - 检查 NUMA
   - 查看 Cache miss

4. 丢包
   - 增加 rx/tx descriptor
   - 检查 flow control
   - 使用 pdump 抓包分析
```

### 7.2 调试命令汇总

```bash
# 系统
cat /proc/interrupts | grep -i eth
cat /proc/softirqs
cat /proc/vmstat

# 内存
cat /proc/meminfo | grep -i huge
ls -la /mnt/hugepages

# 网络
ip link show
ip addr show
route -n
ss -s

# DPDK
dpdk-devbind --status
ethtool -i eth0
ethtool -g eth0
ethtool -l eth0
```

## 8. 总结

调试工具链：

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK 调试工具                            │
│                                                              │
│  设备管理:                                                  │
│  dpdk-devbind ──── 绑定/解绑设备                          │
│                                                              │
│  数据捕获:                                                  │
│  pdump ──────── pcap 格式捕获                             │
│  ethtool ─────── 网卡统计                                 │
│                                                              │
│  运行时调试:                                               │
│  testpmd ────── 交互式测试                                │
│  rte_flow ───── Flow 规则                                │
│                                                              │
│  日志系统:                                                  │
│  rte_log ──────── 日志记录                                │
└─────────────────────────────────────────────────────────────┘
```

调试流程：

```
发现问题 → 确认范围 → 抓取数据 → 分析原因 → 验证修复
   ↓           ↓            ↓           ↓           ↓
 syslog    dpdk-devbind   pdump    hexdump     testpmd
```

---

## 参考资源

- [DPDK Tools](https://doc.dpdk.org/guides/tools/)
- [dpdk-devbind](https://doc.dpdk.org/guides/linux_gsg/linux_drivers.html)
- [pdump](https://doc.dpdk.org/guides/tools/pdump.html)
