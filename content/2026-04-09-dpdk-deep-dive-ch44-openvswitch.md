---
title: "DPDK 第四十四章：OpenVSwitch OVS-DPDK vs OVS-kernel"
date: 2026-04-09 17:25:00
tags: [dpdk, openvswitch, ovs-dpdk, kernel-datapath, performance]
description: "深入对比 OVS-kernel 与 OVS-DPDK：架构差异、性能对比、部署场景与最佳实践"
---

# DPDK 第四十四章：OpenVSwitch：OVS-DPDK vs OVS-kernel

> [!abstract] 核心要点
> Open vSwitch (OVS) 是最流行的开源虚拟交换机。本章对比 OVS-kernel 与 OVS-DPDK 两种数据通道的架构、性能与适用场景。

## 1. Open vSwitch 概述

### 1.1 什么是 OVS

Open vSwitch 是：

- **多层虚拟交换机**：支持 L2/L3/L4
- **OpenFlow 控制**：SDN 可编程
- **跨平台**：Linux、KVM、Xen、Docker、Kubernetes
- **两种数据通道**：kernel vs userspace (DPDK)

### 1.2 OVS 核心组件

```
┌─────────────────────────────────────────────────────────────┐
│                    Open vSwitch                             │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    vswitchd                          │   │
│  │  (ovsdb-server + ovs-vswitchd)                      │   │
│  │                                                      │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐        │   │
│  │  │ OpenFlow │  │  OVSDB   │  │  Netlink │        │   │
│  │  │ Controller│  │  (config)│  │ (kernel) │        │   │
│  │  └──────────┘  └──────────┘  └──────────┘        │   │
│  └──────────────────────────┬───────────────────────────┘   │
│                            │                               │
│  ┌─────────────────────────▼───────────────────────────┐   │
│  │                    Datapath                          │   │
│  │                                                      │   │
│  │  ┌──────────────────┐  ┌──────────────────┐        │   │
│  │  │  OVS-kernel      │  │  OVS-DPDK        │        │   │
│  │  │  (kernel module) │  │  (userspace)     │        │   │
│  │  │  vswitch.ko     │  │  dpdkvhostuser   │        │   │
│  │  └──────────────────┘  └──────────────────┘        │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 2. OVS-kernel

### 2.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    OVS-kernel Data Path                     │
│                                                              │
│  VM ──▶ virtio-net ──▶ vhost-net ──▶ tap ──▶ kernel vswitch │
│         (frontend)      (kernel)     (kernel)   (vswitch.ko)│
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    vswitch.ko                         │   │
│  │                                                      │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐           │   │
│  │  │  flow   │  │  actions │  │  megaflow│           │   │
│  │  │  table  │  │  cache   │  │  cache   │           │   │
│  │  └─────────┘  └─────────┘  └─────────┘           │   │
│  │       │            │                                │   │
│  │       └────────────┼────────────────────────────────│   │
│  │                    ▼                                 │   │
│  │              ┌──────────┐                          │   │
│  │              │ netdev   │                          │   │
│  │              │ (ethX)   │                          │   │
│  │              └──────────┘                          │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 数据包处理流程

```c
// 内核模块处理流程（简化）
netdev_send(struct net_device *netdev, struct sk_buff *skb)
{
    // 1. 查找 flow
    struct sw_flow *flow = ovs_flow_lookup(datapath, skb);

    if (!flow) {
        // 2. 未命中，上报到 userspace
        upcall = ovs_dp_packet_alloc(sizeof(*upcall));
        ovs_dp_upcall(datapath, skb, upcall);

        // 3. userspace 处理后下发 flow
        // 返回并缓存
    }

    // 4. 执行 actions
    ovs_execute_actions(flow, skb);
}
```

### 2.3 特点

| 特性         | 说明                   |
| ------------ | ---------------------- |
| **性能**     | 受限于内核网络栈       |
| **延迟**     | 较高（skb 分配、中断） |
| **吞吐**     | ~1-2 Mpps/core         |
| **CPU 开销** | 高                     |
| **兼容性**   | 好（原生支持所有 NIC） |

## 3. OVS-DPDK

### 3.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    OVS-DPDK Data Path                       │
│                                                              │
│  VM ──▶ virtio-net ──▶ vhost-user ──▶ DPDK ──▶ OVS-DPDK    │
│                     (shared mem)    (PMD)     (userspace)  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                   OVS-DPDK                           │   │
│  │                                                      │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │              DPDK (EAL + PMD)                 │   │   │
│  │  │  ┌───────┐  ┌───────┐  ┌───────┐           │   │   │
│  │  │  │dpdk0 │  │dpdk1  │  │vhost- │           │   │   │
│  │  │  │(phy) │  │(phy)  │  │user   │           │   │   │
│  │  │  └───────┘  └───────┘  └───────┘           │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                      │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │              OVS Flow Table                   │   │   │
│  │  │  (megaflow + dpdk_ring)                      │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 vhost-user 原理

```
┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 共享内存                       │
│                                                              │
│  ┌────────────────────┐    ┌────────────────────┐          │
│  │       QEMU/KVM     │    │     OVS-DPDK       │          │
│  │                    │    │                    │          │
│  │  ┌────────────┐  │    │  ┌────────────┐   │          │
│  │  │ Virtio Net │ │    │  │ DPDK PMD   │   │          │
│  │  │  Driver    │ │    │  │            │   │          │
│  │  └──────┬─────┘ │    │  └──────┬─────┘   │          │
│  │         │        │    │         │          │          │
│  │         │        │    │         │          │          │
│  │  ┌──────▼─────┐ │    │  ┌──────▼─────┐   │          │
│  │  │ virtqueue  │ │    │  │ vhost-user │   │          │
│  │  │ (shared    │ │◀═══▶│  │ client     │   │          │
│  │  │   mem)     │ │    │  │            │   │          │
│  │  └────────────┘ │    │  └────────────┘   │          │
│  └────────────────────┘    └────────────────────┘          │
│                                                              │
│  Socket: /var/run/openvswitch/vhost-user-<name>.sock       │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 vhost-user 类型

| 类型                   | 说明                        | 用途     |
| ---------------------- | --------------------------- | -------- |
| **vhost-user**         | 服务端模式，OVS 作为 server | VM 连接  |
| **vhost-user-client**  | 客户端模式，OVS 作为 client | 容器连接 |
| **vhost-user-blaster** | 测试用，模拟丢包/延迟       | 调试     |

### 3.4 OVS-DPDK 配置

```bash
# 1. 启动 ovsdb-server
ovsdb-tool create /etc/openvswitch/conf.db \
    /usr/share/openvswitch/vswitch.ovsschema

ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    --private-key=db:Open_vSwitch,SSL,private_key \
    --certificate=db:Open_vSwitch,SSL,certificate \
    --bootstrap-ca-cert=db:Open_vSwitch,SSL,ca_cert \
    --detach

# 2. 初始化
ovs-vsctl --db=unix:/var/run/openvswitch/db.sock init

# 3. 启动 vswitchd (DPDK 模式)
ovs-vswitchd --dpdk -c 0x1 -n 4 \
    --socket-mem 1024,1024 \
    -- unix:/var/run/openvswitch/db.sock \
    --pidfile --detach

# 4. 配置
ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true
ovs-vsctl set Open_vSwitch . other_config:dpdk-socket-mem=1024,1024

# 5. 添加端口
# DPDK 物理端口
ovs-vsctl add-port br0 dpdk0 \
    -- set Interface dpdk0 type=dpdk \
    options:dpdk-devargs=0000:3d:00.0

# vhost-user 端口（VM）
ovs-vsctl add-port br0 vhost-user-1 \
    -- set Interface vhost-user-1 type=vhost-user
```

## 4. 性能对比

### 4.1 延迟对比

```
OVS-kernel 延迟：
  VM → virtio → vhost-net → tap → vswitch.ko → NIC
         ~5us        ~10us      ~5us      ~10us
         Total: ~30-50us

OVS-DPDK 延迟：
  VM → virtio → vhost-user → DPDK PMD → NIC
         ~2us        ~1us       ~5us
         Total: ~8-15us
```

### 4.2 吞吐量对比

| 指标              | OVS-kernel     | OVS-DPDK         | 提升 |
| ----------------- | -------------- | ---------------- | ---- |
| **吞吐**          | ~1-2 Mpps/core | ~10-15 Mpps/core | 10x  |
| **延迟**          | ~30-50us       | ~8-15us          | 3-5x |
| **CPU 开销**      | 高             | 低               | 5x   |
| **抖动**          | 高             | 低               | 稳定 |
| **抖动 (jitter)** | >100us         | <10us            | 10x  |

### 4.3 选型指南

```
场景选型：

延迟敏感（< 100us）：
    │
    ▼
  OVS-DPDK

吞吐优先（> 5 Mpps）：
    │
    ▼
  OVS-DPDK

开发测试、简单场景：
    │
    ▼
  OVS-kernel

需要内核功能（iptables、tc）：
    │
    ▼
  OVS-kernel（混合模式）
```

## 5. 混合部署

### 5.1 OVS-DPDK + OVS-kernel 混合

```bash
# 创建两个 bridge
ovs-vsctl add-br br0 -- set Bridge br0 datapath_type=netdev  # DPDK
ovs-vsctl add-br br1 -- set Bridge br1 datapath_type=system   # kernel

# 连接两个 bridge
ovs-vsctl add-port br0 patch-to-br1 \
    -- set Interface patch-to-br1 type=patch options:peer=patch-to-br0

ovs-vsctl add-port br1 patch-to-br0 \
    -- set Interface patch-to-br0 type=patch options:peer=patch-to-br1
```

### 5.2 DPDK 物理端口 + kernel 端口

```bash
# DPDK 端口连接外部网络
ovs-vsctl add-port br0 dpdk-phy0 \
    -- set Interface dpdk-phy0 type=dpdk \
    options:dpdk-devargs=0000:3d:00.0

# kernel 端口用于管理
ovs-vsctl add-port br1 eth1
```

## 6. Flow 规则

### 6.1 OpenFlow 规则

```bash
# 添加 basic 规则
ovs-ofctl add-flow br0 "in_port=1,actions=output:2"

# 添加 L3 规则
ovs-ofctl add-flow br0 "ip,nw_dst=10.0.0.1,actions=output:3"

# 添加 ACL 规则
ovs-ofctl add-flow br0 "tcp,tcp_dst=80,actions=drop"
ovs-ofctl add-flow br0 "tcp,tcp_dst=80,actions=mod_dl_dst:00:00:00:00:00:01,output:2"

# 查看流表
ovs-ofctl dump-flows br0
```

### 6.2 DPDK Flow (rte_flow)

```bash
# OVS-DPDK 支持 rte_flow 卸载
ovs-vsctl set port dpdk0 \
    other_config:dpdk-flow-rule="eth_type=0x0800,ip_dst=10.0.0.0/24,action=output:2"

# 硬件卸载验证
ovs-appctl dpif-netdev/miniflow-parser-stats br0
```

## 7. 常见问题

### 7.1 OVS-DPDK 启动失败

```bash
# 检查 hugepages
cat /proc/meminfo | grep Huge
# HugePages_Total: 16
# Hugepagesize: 2048 kB

# 如果不够
echo 32 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 检查 NIC 绑定
dpdk-devbind.py --status
```

### 7.2 vhost-user 连接失败

```bash
# QEMU 配置
qemu-system-x86_64 \
    -mem-path /hugepages \
    -mem-prealloc \
    -chardev socket,id=char0,path=/var/run/openvswitch/vhost-user-1.sock,server \
    -netdev type=vhost-user,id=netdev0,chardev=char0 \
    -device virtio-net-pci,netdev=netdev0,mac=00:00:00:00:00:01
```

### 7.3 性能调优

```bash
# 1. 增加 PMD threads
ovs-vsctl set Open_vSwitch . other_config:dpdk-lcore-mask=0xFF

# 2. 设置 socket memory
ovs-vsctl set Open_vSwitch . other_config:dpdk-socket-mem="2048,2048"

# 3. 调整 mbuf
ovs-vsctl set Open_vSwitch . other_config:dpdk-extra="--socket-limit=2048"

# 4. 查看统计
ovs-appctl bridge/dump-flows br0
ovs-ofctl show br0
```

## 8. 总结

| 维度         | OVS-kernel        | OVS-DPDK         |
| ------------ | ----------------- | ---------------- |
| **数据路径** | 内核 (vswitch.ko) | 用户态 (DPDK)    |
| **延迟**     | ~30-50us          | ~8-15us          |
| **吞吐**     | ~1-2 Mpps         | ~10-15 Mpps      |
| **CPU 开销** | 高                | 低               |
| **兼容性**   | 好                | 受限于 DPDK 驱动 |
| **适用场景** | 开发测试          | 生产高性能       |

---

## 参考资源

- [Open vSwitch 官方文档](https://www.openvswitch.org/)
- [OVS-DPDK 指南](https://docs.openvswitch.org/en/latest/intro/install/dpdk/)
- [DPDK OVS GitHub](https://github.com/openvswitch/ovs)
