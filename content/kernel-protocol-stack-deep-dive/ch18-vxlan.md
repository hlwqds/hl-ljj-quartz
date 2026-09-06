---
title: "Kernel Protocol Stack 深度探索 (十八)：VXLAN 虚拟可扩展局域网"
date: 2026-04-13
tags:
  [linux, kernel, networking, series, vxlan, tunnel, virtualization, sdn, network virtualization]
description: "深入解析 Linux VXLAN 隧道协议——VXLAN 头部结构、封装解封装、VTEP、BUM 流量处理、组播映射、以及与 VLAN 的对比"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[kernel-protocol-stack-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. [[ch5-napi|第五章：NAPI 与轮询模式]]
> 6. [[ch6-ethernet|第六章：Ethernet 与 MAC 层]]
> 7. [[ch7-bridge|第七章：网桥与 Switchdev]]
> 8. [[ch8-vlan|第八章：VLAN 与 802.1Q]]
> 9. [[ch9-macvlan|第九章：MACVLAN 与虚拟网卡]]
> 10. [[ch10-bonding|第十章：Bonding 与 teamd]]
> 11. [[ch11-ip-framing|第十一章：IP 协议封装]]
> 12. [[ch12-routing|第十二章：路由与 FIB]]
> 13. [[ch13-neighbor|第十三章：Neighbor 与 ARP]]
> 14. [[ch14-iptables|第十四章：iptables 基础]]
> 15. [[ch15-conntrack|第十五章：连接跟踪 Conntrack]]
> 16. [[ch16-nat|第十六章：NAT 与地址转换]]
> 17. [[ch17-gre|第十七章：GRE 隧道协议]]
> 18. **第十八章：VXLAN 虚拟可扩展局域网**

---

## 1. 概述：VXLAN 是什么

VXLAN（Virtual Extensible LAN，虚拟可扩展局域网）是一种网络虚拟化技术，由 VMware、Cisco、Arista 等公司联合提出，在 2014 年作为 RFC 7348 发布。

**VXLAN 解决的问题：**

| 问题             | 传统方案           | VXLAN 解决方案      |
| ---------------- | ------------------ | ------------------- |
| VLAN ID 数量不足 | 最多 4094 个 VLAN  | 1600 万个 VNI       |
| 多租户网络隔离   | VLAN 隔离          | VNI + VRF 隔离      |
| 虚拟机迁移限制   | 同一 VLAN 内       | 跨三层网络迁移      |
| STP 阻塞问题     | 生成树协议限制路径 | 基于 UDP 的等价路由 |

**VXLAN 核心特点：**

1. **24-bit VNI（VXLAN Network Identifier）**：支持 16M 独立网络
2. **UDP 封装**：利用 UDP 的多路径负载均衡能力
3. **VTEP（VXLAN Tunnel End Point）**：隧道端点负责封装/解封装
4. **组播/单播复制**：处理 BUM（Broadcast, Unknown Unicast, Multicast）流量
5. **MAC-in-UDP**：将 Ethernet 帧封装在 UDP 内部

---

## 2. VXLAN 头部结构

### 2.1 VXLAN 封装格式

```
+-----------------+------------------+------------------+------------------+
|  Outer IP Header | Outer UDP Header |  VXLAN Header   |   Inner Frame   |
|    (20 bytes)     |   (8 bytes)      |   (8 bytes)     |  (Ethernet)     |
+-----------------+------------------+------------------+------------------+
```

### 2.2 VXLAN Header

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|R|R|R|R|I|R|R|R|             Reserved                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                VXLAN Network Identifier (VNI)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Reserved                                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段       | 位宽 | 说明                         |
| ---------- | ---- | ---------------------------- |
| I (I flag) | 1    | 1 表示存在 VNI，0 表示未使用 |
| Reserved   | 95   | 保留字段                     |
| VNI        | 24   | VXLAN Network Identifier     |
| Reserved   | 8    | 保留字段                     |

### 2.3 内核 VXLAN 头结构

```c
// include/uapi/linux/vxlan.h
struct vxlanhdr {
    __be32 vx_flags;          // 8 bytes, I flag is bit 3
    __be32 vx_vni;            // Network Identifier
};

#define VXLAN_HLEN             (sizeof(struct vxlanhdr))

struct vxlanhdr_basic {
    __u8  vx_flags;
    __u8  vx_reserved[3];
    __u8  vx_vni[3];
    __u8  vx_reserved2;
};

// VNI 字段处理
#define vxlan_vni_id(vni)      ((vni)[0] << 16 | (vni)[1] << 8 | (vni)[2])
#define vxlan_vni_size(vni)    (ntohl(vni) & 0xFFFFFF)
```

### 2.4 Outer UDP 头

```c
// VXLAN 使用 UDP 目的端口 4789
#define VXLAN_PORT             4789

struct udphdr {
    __be16 source;         // 随机源端口（用于 ECN）
    __be16 dest;           // 固定 4789
    __be16 len;
    __be16 check;
};
```

---

## 3. VTEP 与封装解封装

### 3.1 VTEP（VXLAN Tunnel End Point）

VTEP 是 VXLAN 隧道的端点，负责：

- 将本地 VM 的 Ethernet 帧封装为 VXLAN 包
- 将接收到的 VXLAN 包解封装为 Ethernet 帧
- 维护 MAC-to-VTEP 的映射表（MAC 表）
- 处理 BUM 流量的复制

```
+------------------+         VXLAN Tunnel          +------------------+
|     VTEP A       | ============================> |     VTEP B       |
| 192.168.1.10     |                              | 192.168.2.10     |
+------------------+                              +------------------+
       |                                                  |
  +----+----+                                     +----+----+
  | VM1 | VM2|                                     | VM3 | VM4|
  +----+----+                                     +----+----+
  VNI 100                                        VNI 100
```

### 3.2 封装流程（Encapsulation）

```c
// drivers/net/vxlan.c - VXLAN 封装
static netdev_tx_t vxlan_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vxlan_config *config = &vxlan->cfg;
    struct vxlan_fdb *fdb;
    __be32 dst_ip;
    __be16 src_port, dst_port;
    int min_mtu = vxlan->min_mtu;

    // 1. 获取目标 VTEP IP（通过 MAC 表查找或组播）
    fdb = vxlan_fdb_find(vxlan, eth_hdr(skb)->h_dest);
    if (fdb) {
        dst_ip = fdb->remote_ip;
        dst_port = VXLAN_PORT;
    } else {
        // 未知单播或 BUM 流量 -> 组播/广播
        dst_ip = config->group_addr;
        dst_port = config->port;
    }

    // 2. 添加 VXLAN 头部
    if (!skb_inner_mac_header(skb))
        skb_set_inner_mac_header(skb, -ETH_HLEN);

    vxlan_build_skb(skb, vxlan->sock, sizeof(struct vxlanhdr),
                     vni, dst_ip, src_port, dst_port);

    // 3. 添加外层 IP 头
    udp_tunnel_xmit_skb(rt, vxlan->sock->sk, skb,
                        src_ip, dst_ip, protocol,
                        tos, ttl, df, src_port, dst_port, false);

    return NETDEV_TX_OK;
}
```

### 3.3 解封装流程（Decapsulation）

```c
// drivers/net/vxlan.c - VXLAN 解封装
static int vxlan_rcv(struct sock *sk, struct sk_buff *skb)
{
    struct vxlanhdr *vxh;
    struct vxlan_sock *vs;
    struct vxlan_config *cfg;
    __be32 vni;
    int err;

    // 1. 解析 VXLAN 头部
    if (!pskb_may_pull(skb, VXLAN_HLEN))
        return -EINVAL;

    vxh = (struct vxlanhdr *)skb->data;
    if (!(vxh->vx_flags & VXLAN_HF_VNI))
        return -EINVAL;

    vni = vxlan_vni(vxh->vx_vni);
    skb_pull(skb, VXLAN_HLEN);

    // 2. 查找对应的 vxlan socket
    vs = vxlan_lookup_sock(skb->sk, vni);
    if (!vs)
        return -ENOENT;
    cfg = &vs->cfg;

    // 3. 更新 MAC 表
    vxlan_fdb_update(vs, src_mac, src_ip, vni, ...);

    // 4. 设置网络层头并交付给上层
    skb->protocol = eth_type_trans(skb, dev);
    skb_scrub_packet(skb, false);

    netif_rx(skb);
    return 0;
}
```

---

## 4. Linux VXLAN 配置

### 4.1 创建 VXLAN 接口

```bash
# 基本 VXLAN 配置
ip link add vxlan0 type vxlan \
    id 100 \
    dstport 4789 \
    local 192.168.1.10 \
    remote 192.168.2.10 \
    dev eth0

# 设置 IP
ip addr add 10.0.0.1/24 dev vxlan0
ip link set vxlan0 up

# 验证
ip -d link show vxlan0
bridge fdb show dev vxlan0
```

### 4.2 使用组播配置（多播复制）

```bash
# 使用组播组进行 BUM 流量复制
ip link add vxlan0 type vxlan \
    id 100 \
    group 239.1.1.1 \
    dstport 4789 \
    dev eth0

# 多个 VTEP 加入同一组播组
ip link add vxlan0 type vxlan \
    id 100 \
    local 192.168.1.10 \
    group 239.1.1.1 \
    dstport 4789 \
    dev eth0
```

### 4.3 与网桥集成

```bash
# 将 VXLAN 接口添加到网桥
brctl addbr br0
brctl addif br0 vxlan0
ip link set br0 up

# 或者使用网桥的 VXLAN 端口
bridge link add dev vxlan0 master br0 vlan_filtering 1
```

### 4.4 查看 VXLAN 状态

```bash
# 查看 VXLAN 隧道
ip -d link show type vxlan

# 查看 MAC 表
bridge fdb show dev vxlan0

# 添加静态 MAC 表项
bridge fdb add 00:11:22:33:44:55 dev vxlan0 \
    dst 192.168.2.10 vni 100

# 查看 VXLAN 统计
ip -s link show vxlan0
```

---

## 5. BUM 流量处理

### 5.1 BUM 流量类型

| 类型            | 说明                  | 处理方式            |
| --------------- | --------------------- | ------------------- |
| Broadcast       | 广播帧（如 ARP 请求） | 组播复制到所有 VTEP |
| Unknown Unicast | 目的 MAC 未知的帧     | 组播复制或泛洪      |
| Multicast       | 组播帧                | 依赖组播路由        |

### 5.2 组播映射

```
ARP Request (Broadcast)
       |
       v
+------------------+
|  VXLAN 封装      |
|  VNI: 100        |
|  目的: 239.1.1.1 |
+------------------+
       |
       v
组播网络复制到所有 VTEP
       |
       +----> VTEP 1 (解封装，泛洪到本地 LAN)
       +----> VTEP 2 (解封装，泛洪到本地 LAN)
       +----> VTEP 3 (解封装，泛洪到本地 LAN)
```

### 5.3 Head-end Replication

```bash
# 配置单播复制列表（避免组播依赖）
ip link add vxlan0 type vxlan id 100 local 192.168.1.10 dev eth0

# 手动添加远端 VTEP
bridge fdb add 00:11:22:33:44:55 dev vxlan0 \
    dst 192.168.2.10 via eth0

# 查看 replication list
bridge fdb show dev vxlan0
```

---

## 6. MAC 表与学习

### 6.1 MAC 表结构

```c
// drivers/net/vxlan.c
struct vxlan_fdb {
    struct hlist_node hlist;       // 哈希表链表
    unsigned long   used;          // 上次使用时间
    __be32          remote_ip;     // 远端 VTEP IP
    unsigned char   eth_addr[ETH_ALEN];  // 远端 MAC
    __u32           vni;           // VNI
    __u16           state;         // 状态
    bool            offloaded;    // 是否硬件卸载
};
```

### 6.2 MAC 学习流程

```c
// MAC 学习：当收到远端 VTEP 的包时
static void vxlan_fdb_update(struct vxlan_sock *vs,
                             const unsigned char *mac,
                             __be32 ip, __u32 vni, ...)
{
    struct vxlan_fdb *fdb;

    fdb = vxlan_fdb_find(vs, mac, vni);
    if (fdb) {
        // 更新已有的 MAC 表项
        fdb->remote_ip = ip;
        fdb->used = jiffies;
    } else {
        // 创建新的 MAC 表项
        fdb = kmalloc(sizeof(*fdb), GFP_ATOMIC);
        fdb->eth_addr = mac;
        fdb->remote_ip = ip;
        fdb->vni = vni;
        hlist_add_head(&fdb->hlist, &vs->fdb_head[vni % FDB_HASH_SIZE]);
    }
}
```

---

## 7. VXLAN 与 VLAN 对比

### 7.1 核心差异

| 特性     | VLAN           | VXLAN              |
| -------- | -------------- | ------------------ |
| 标识宽度 | 12-bit (4094)  | 24-bit (16M)       |
| 网络范围 | 二层广播域     | 跨三层网络         |
| 封装方式 | 无（纯以太网） | MAC-in-UDP         |
| 隧道端点 | 交换机/路由器  | VTEP（网卡/软件）  |
| 组播支持 | 原生           | 需要组播或单播复制 |
| 硬件支持 | 广泛           | 有限（智能网卡）   |
| 迁移能力 | 受限           | 跨三层自由迁移     |

### 7.2 典型组网对比

```
VLAN 组网:
+------------------+       +------------------+
|    Switch        |       |    Switch        |
|   VLAN 100       |       |   VLAN 100       |
|   10.0.1.0/24    |       |   10.0.2.0/24    |
+--------+---------+       +--------+---------+
         |                         |
+--------+---------+       +--------+---------+
|   Trunk (802.1Q) |=======|   Trunk (802.1Q) |
+--------+---------+       +--------+---------+

VXLAN 组网:
+------------------+       VXLAN Tunnel       +------------------+
|     VTEP A       | ========================> |     VTEP B       |
|   192.168.1.10   |                          |   192.168.2.10   |
+------------------+                          +------------------+
         |                                            |
+--------+---------+                          +--------+---------+
|   Local LAN      |                          |   Local LAN     |
|   VNI 100        |                          |   VNI 100        |
+--------+---------+                          +--------+---------+
```

---

## 8. 内核实现架构

### 8.1 数据结构

```c
// drivers/net/vxlan.c
struct vxlan_sock {
    struct socket      *sock;         // UDP socket
    struct dst_entry   *dst;          // 路由缓存
    struct vxlan_config cfg;          // 配置
    refcount_t          refcnt;       // 引用计数
    struct hlist_node   hlist;        // 全局链表
};

struct vxlan_config {
    __u32              vni;           // VNI
    __u32              flags;         // 配置标志
    __be32             group_addr;    // 组播地址
    __be32             local_addr;    // 本地 VTEP IP
    __u16              port_min;      // 源端口范围
    __u16              port_max;
    struct device      *dev;          // 关联的网络设备
};
```

### 8.2 接收处理流程

```c
// UDP 接收 -> VXLAN 特定端口处理
static int vxlan_udp_encap_recv(struct sock *sk, struct sk_buff *skb)
{
    struct vxlanhdr *vxh;

    // 检查端口和版本
    if (!vxlan_get_sk_family(vs) == AF_INET)
        return 1;  // 不处理

    // 解析 VNI
    vxh = (struct vxlanhdr *)(udp_hdr(skb) + 1);
    if (!(vxh->vx_flags & VXLAN_HF_VNI))
        return 1;

    // 解封装并交付
    return vxlan_rcv(sk, skb);
}

// 注册 UDP 端口处理
udp_register_offload(port, vxlan_udp_encap_recv);
```

---

## 9. 高级配置

### 9.1 多个 VNI

```bash
# 创建多个 VXLAN 接口（每个 VNI 一个）
ip link add vxlan100 type vxlan id 100 dev eth0 local 192.168.1.10
ip link add vxlan200 type vxlan id 200 dev eth0 local 192.168.1.10
ip link add vxlan300 type vxlan id 300 dev eth0 local 192.168.1.10
```

### 9.2 QoS 配置

```bash
# 设置 TOS/DSCP
ip link add vxlan0 type vxlan id 100 \
    dstport 4789 \
    local 192.168.1.10 \
    remote 192.168.2.10 \
    dev eth0 \
    tos inherit

# 或设置固定值
ip link add vxlan0 type vxlan id 100 \
    dstport 4789 \
    local 192.168.1.10 \
    remote 192.168.2.10 \
    dev eth0 \
    tos 0x20  # CS6 - 网络控制
```

### 9.3 统计监控

```bash
# 查看 VXLAN 统计
ip -s link show vxlan0

# 使用 ethtool
ethtool -S vxlan0

# 使用 bridge fdb 统计
bridge -statistics fdb show dev vxlan0
```

---

## 10. 总结

VXLAN 是现代数据中心网络虚拟化的核心协议：

**关键要点：**

1. 24-bit VNI 支持 1600 万个隔离网络
2. UDP 封装支持 ECN 和负载均衡
3. VTEP 负责封装解封装和 MAC 学习
4. BUM 流量通过组播或单播复制处理
5. 需要配合 SDN 控制器或手动配置 MAC 表
6. 硬件卸载支持越来越好（智能网卡）

**典型应用场景：**

- 数据中心多租户网络隔离
- 虚拟机/容器跨主机通信
- 容器编排平台（Kubernetes CNI）
- 软件定义网络（OVS + VXLAN）
