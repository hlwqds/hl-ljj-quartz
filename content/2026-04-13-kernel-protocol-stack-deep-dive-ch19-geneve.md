---
title: "Kernel Protocol Stack 深度探索 (十九)：GENEVE 通用网络虚拟化封装"
date: 2026-04-13
tags: [linux, kernel, networking, series, geneve, tunnel, virtualization, sdn, network-virtualization]
description: "深入解析 Linux GENEVE 协议——GENEVE 头部结构、与 VXLAN 对比、TLV 扩展机制、OVN/OVS 实现、以及 GENEVE 在容器网络中的应用"
---

> [!info] Kernel Protocol Stack 深度探索系列
> 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-kernel-protocol-stack-deep-dive-ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[2026-04-13-kernel-protocol-stack-deep-dive-ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[2026-04-13-kernel-protocol-stack-deep-dive-ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. [[2026-04-13-kernel-protocol-stack-deep-dive-ch5-napi|第五章：NAPI 与轮询模式]]
> 6. [[2026-04-13-kernel-protocol-stack-deep-dive-ch6-ethernet|第六章：Ethernet 与 MAC 层]]
> 7. [[2026-04-13-kernel-protocol-stack-deep-dive-ch7-bridge|第七章：网桥与 Switchdev]]
> 8. [[2026-04-13-kernel-protocol-stack-deep-dive-ch8-vlan|第八章：VLAN 与 802.1Q]]
> 9. [[2026-04-13-kernel-protocol-stack-deep-dive-ch9-macvlan|第九章：MACVLAN 与虚拟网卡]]
> 10. [[2026-04-13-kernel-protocol-stack-deep-dive-ch10-bonding|第十章：Bonding 与 teamd]]
> 11. [[2026-04-13-kernel-protocol-stack-deep-dive-ch11-ip-framing|第十一章：IP 协议封装]]
> 12. [[2026-04-13-kernel-protocol-stack-deep-dive-ch12-routing|第十二章：路由与 FIB]]
> 13. [[2026-04-13-kernel-protocol-stack-deep-dive-ch13-neighbor|第十三章：Neighbor 与 ARP]]
> 14. [[2026-04-13-kernel-protocol-stack-deep-dive-ch14-iptables|第十四章：iptables 基础]]
> 15. [[2026-04-13-kernel-protocol-stack-deep-dive-ch15-conntrack|第十五章：连接跟踪 Conntrack]]
> 16. [[2026-04-13-kernel-protocol-stack-deep-dive-ch16-nat|第十六章：NAT 与地址转换]]
> 17. [[2026-04-13-kernel-protocol-stack-deep-dive-ch17-gre|第十七章：GRE 隧道协议]]
> 18. [[2026-04-13-kernel-protocol-stack-deep-dive-ch18-vxlan|第十八章：VXLAN 虚拟可扩展局域网]]
> 19. **第十九章：GENEVE 通用网络虚拟化封装**

---

## 1. 概述：GENEVE 是什么

GENEVE（Generic Network Virtualization Encapsulation，通用网络虚拟化封装）是由 Microsoft、Red Hat、Intel 等公司联合提出的新一代网络虚拟化封装协议，在 2020 年作为 RFC 8926 正式发布。

**GENEVE 解决了什么问题：**

| 问题 | VXLAN | GENEVE 解决方案 |
|------|-------|----------------|
| 固定头部 | 无法扩展 | TLV 选项机制支持灵活扩展 |
| 元数据携带 | 有限 | 支持任意类型的元数据 |
| 硬件兼容性 | 差 | 设计即考虑硬件卸载 |
| 标准化 | IETF 标准 | RFC 8926 正式标准化 |

**GENEVE 核心特点：**

1. **24-bit VNI**：与 VXLAN 相同，支持 16M 独立网络
2. **TLV 选项**：支持可变长的协议扩展
3. **Protocol 字段**：UDP 目的端口区分封装协议
4. **设计目标**：硬件友好、支持元数据、可扩展

---

## 2. GENEVE 头部结构

### 2.1 封装格式

```
+-----------------+------------------+------------------+------------------+------------------+
|  Outer IP Header | Outer UDP Header | GENEVE Header    |  GENEVE Options  |   Inner Frame   |
|    (20 bytes)     |   (8 bytes)      |   (8 bytes)      |   (可变长度)      |  (Ethernet)     |
+-----------------+------------------+------------------+------------------+------------------+
```

### 2.2 GENEVE Header

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|        Ver  |O|    Reserved   |          Protocol Type        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         Virtual Network Identifier (VNI)       |    Reserved |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Options (variable length)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段 | 位宽 | 说明 |
|------|------|------|
| Ver (Version) | 2 | 版本号，必须为 0 |
| O (Options) | 1 | 1 表示存在 Options，0 表示无 Options |
| Reserved | 5 | 保留字段 |
| Protocol Type | 16 | 载荷协议类型（Ethernet Type） |
| VNI | 24 | Virtual Network Identifier |
| Reserved | 8 | 保留字段 |
| Options | 可变 | TLV 格式的选项 |

### 2.3 GENEVE 选项（Options）

```
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Option Class |   Type   |   Flags   |        Length        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Option Data (variable)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段 | 位宽 | 说明 |
|------|------|------|
| Option Class | 16 | 选项类（IANA 分配，如 0x0109 = Open Virtual Networking） |
| Type | 8 | 特定于类的选项类型 |
| Flags | 8 | P=1 表示必须理解，C=1 表示在复制时复制 |
| Length | 8 | 选项数据长度（4 字节的倍数） |
| Option Data | 可变 | 实际选项数据 |

### 2.4 内核 GENEVE 头结构

```c
// include/uapi/linux/genetlink.h & drivers/net/geneve.c
struct genevehdr {
    __u8    ver;           // 版本 (2 bits)
    __u8    opt_len;       // 选项长度，4字节倍数 (6 bits)
    __u8    oam;           // OAM 包标志
    __be16  protocol;      // 协议类型
    __u8    vni[3];        // VNI
    __u8    reserved;      // 保留
};

// GENEVE 选项头
struct geneve_opt {
    __be16  option_class;  // 选项类
    __u8    type;          // 选项类型
    __u8    length;        // 数据长度（4字节倍数）
    __u32   data[];        // 选项数据
};

// GENEVE 端口（IANA 分配）
#define GENEVE_PORT         6081
```

---

## 3. GENEVE vs VXLAN vs GRE

### 3.1 协议对比

| 特性 | GRE | VXLAN | GENEVE |
|------|-----|-------|--------|
| 标准化 | RFC 1701/2784 | RFC 7348 | RFC 8926 |
| 封装位置 | IP 层 | UDP 层 | UDP 层 |
| VNI 宽度 | 无 | 24-bit | 24-bit |
| 隧道标识 | Key (32-bit) | VNI (24-bit) | VNI + Options |
| 元数据支持 | Key | 无 | TLV Options |
| 硬件友好 | 一般 | 好 | 最好 |
| 组播支持 | 是 | 是 | 是 |
| 最小头部 | 4B | 8B | 8B |
| 最大选项 | 0 | 0 | 64KB |

### 3.2 GENEVE 的优势

**1. TLV 扩展性：**
```bash
# GENEVE 可以携带任意元数据
# 例如：Open vSwitch 流表信息
Option Class: 0x0109 (OVN)
Type: 1 (Traffic ID)
Data: <任意元数据>
```

**2. 硬件卸载友好：**
```
VXLAN 头:
  - 固定字段，硬件解析简单
  - 但无法携带额外信息

GENEVE 头:
  - TLV 格式，硬件可跳过未知选项
  - Flags 中的 P 位保证关键选项被处理
```

**3. 协议类型清晰：**
```c
// GENEVE 使用标准 EtherType
protocol = eth_type_trans(skb, dev);  // 自动识别内层协议
```

---

## 4. Linux GENEVE 配置

### 4.1 创建 GENEVE 接口

```bash
# 基本 GENEVE 配置
ip link add geneve0 type geneve \
    id 100 \
    remote 192.168.2.10 \
    local 192.168.1.10

# 设置 IP
ip addr add 10.0.0.1/24 dev geneve0
ip link set geneve0 up

# 验证
ip -d link show geneve0
bridge fdb show dev geneve0
```

### 4.2 带选项的 GENEVE

```bash
# 使用 ip link 创建带选项的 GENEVE
ip link add geneve0 type geneve \
    id 100 \
    remote 192.168.2.10 \
    local 192.168.1.10 \
    ttl 64 \
    tos inherit

# 添加选项（通过 iproute2 扩展）
ip link add geneve0 type geneve id 100 \
    remote 192.168.2.10 local 192.168.1.10 \
    option class 0x0109 type 0x01 data 0x00000001
```

### 4.3 与网桥集成

```bash
# 将 GENEVE 添加到网桥
brctl addbr br0
brctl addif br0 geneve0
ip link set br0 up

# 查看网桥学习到的 MAC
bridge fdb show dev geneve0
```

### 4.4 查看 GENEVE 状态

```bash
# 查看 GENEVE 接口详情
ip -d link show type geneve

# 查看统计信息
ip -s link show geneve0

# 查看 GENEVE 隧道
ip -d tunnel show type geneve
```

---

## 5. OVS/OVN 中的 GENEVE

### 5.1 OVS GENEVE 实现

```bash
# OVS 创建 GENEVE 端口
ovs-vsctl add-port br-int geneve0 \
    -- set interface geneve0 type=geneve \
    options:remote_ip=192.168.2.10 \
    options:key=100

# 查看 OVS 端口类型
ovs-vsctl list port geneve0
```

### 5.2 OVN 逻辑网络

```bash
# OVN 逻辑交换机使用 GENEVE 封装
ovn-nbctl ls-add ls0
ovn-nbctl lsp-add ls0 lsp0
ovn-nbctl lsp-set-addresses lsp0 "00:11:22:33:44:55 10.0.0.10"

# OVN 自动配置 GENEVE 隧道
ovn-nbctl set logical_switch ls0 \
    other_config:encaps-type=geneve
ovn-nbctl set logical_switch ls0 \
    other_config:隧道选项
```

### 5.3 OVS 流表与 GENEVE

```bash
# 在 OVS 中匹配 GENEVE 元数据
ovs-ofctl add-flow br-int \
    "table=0,priority=100,actions=move:NXM_NX_TUN_ID[]->NXM_NX_REG0[]"

# 查看 GENEVE 隧道 ID
ovs-ofctl dump-flows br-int | grep tun_id
```

---

## 6. GENEVE 封装解封装

### 6.1 封装流程

```c
// drivers/net/geneve.c - GENEVE 封装
static netdev_tx_t geneve_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct geneve_sock *gs = rcu_dereference(geneve->gs);
    struct geneve_config *cfg = &geneve->cfg;
    struct flowi4 fl;
    struct rtable *rt;
    __be32 dst_ip;
    __be16 src_port, dst_port;
    struct genevehdr *gh;
    int min_mtu = geneve->min_mtu;
    int opt_len = cfg->options_len;
    
    // 1. 获取远端 VTEP IP
    dst_ip = geneve->remote_ip;
    dst_port = GENEVE_PORT;
    
    // 2. 添加 GENEVE 头部
    skb = skb_cow_head(skb, sizeof(*gh) + opt_len);
    if (!skb)
        return NETDEV_TX_OK;
    
    gh = (struct genevehdr *)skb_push(skb, sizeof(*gh) + opt_len);
    
    // 填充 GENEVE 头
    gh->ver = 0;
    gh->opt_len = opt_len / 4;  // 4字节倍数
    gh->oam = 0;
    gh->protocol = skb->protocol;
    memcpy(gh->vni, &geneve->vni, 3);
    
    // 复制选项
    if (opt_len)
        memcpy(gh + 1, cfg->options, opt_len);
    
    // 3. 发送
    udp_tunnel_xmit_skb(rt, gs->sock->sk, skb,
                        geneve->local_ip, dst_ip,
                        cfg->tos, cfg->ttl, 0,
                        src_port, dst_port, false);
    
    return NETDEV_TX_OK;
}
```

### 6.2 解封装流程

```c
// drivers/net/geneve.c - GENEVE 接收
static int geneve_udp_encap_recv(struct sock *sk, struct sk_buff *skb)
{
    struct genevehdr *geneveh;
    struct geneve_sock *gs;
    struct geneve_config *cfg;
    __u8 vni[3];
    int hdr_len;
    
    // 1. 检查 GENEVE 头部长度
    if (!pskb_may_pull(skb, GENEVE_HLEN))
        return -EINVAL;
    
    geneveh = (struct genevehdr *)skb->data;
    
    // 2. 验证版本
    if (geneveh->ver != 0)
        return -EINVAL;
    
    // 3. 计算头部总长度
    hdr_len = GENEVE_HLEN + geneveh->opt_len * 4;
    if (!pskb_may_pull(skb, hdr_len))
        return -EINVAL;
    
    // 4. 移除 GENEVE 头
    skb_pull(skb, hdr_len);
    
    // 5. 查找对应的 geneve socket
    memcpy(vni, geneveh->vni, 3);
    gs = geneve_lookup_sock(skb->sk, vni);
    if (!gs)
        return -ENOENT;
    
    cfg = &gs->cfg;
    
    // 6. 更新 MAC 表
    geneve_fdb_update(gs, eth_hdr(skb)->h_source,
                      geneveh->protocol, vni, ...);
    
    // 7. 交付到网络层
    skb->protocol = geneveh->protocol;
    skb_scrub_packet(skb, false);
    netif_rx(skb);
    
    return 0;
}
```

---

## 7. GENEVE 选项处理

### 7.1 常见选项类

| Option Class | 用途 | 示例 |
|-------------|------|------|
| 0x0109 | Open Virtual Networking | OVN 流表 ID |
| 0x0002 | NIC Switch | 硬件卸载信息 |
| 0x010B | Intel | 容器元数据 |

### 7.2 处理选项

```c
// 遍历 GENEVE 选项
struct geneve_opt *opt = (struct geneve_opt *)(gh + 1);
int opt_len = geneveh->opt_len * 4;

while (opt_len > 0) {
    __be16 opt_class = opt->option_class;
    __u8 opt_type = opt->type;
    __u8 opt_data_len = opt->length * 4;
    
    // 处理特定选项
    if (opt_class == 0x0109 && opt_type == 1) {
        // OVN Traffic ID
        __u32 traffic_id = *( __u32 *)opt->data;
    }
    
    opt = (struct geneve_opt *)((char *)opt + sizeof(*opt) + opt_data_len);
    opt_len -= sizeof(*opt) + opt_data_len;
}
```

---

## 8. 容器网络中的 GENEVE

### 8.1 Kubernetes CNI

```bash
# 配置 CNI 使用 GENEVE（通过 OVS）
# /etc/cni/net.d/ovn-kubernetes.conf
{
    "cniVersion": "0.3.1",
    "type": "ovn-kube",
    "overlay": {
        "encapsulation": "geneve"
    },
    "mtu": 1400
}
```

### 8.2 OVN-Kubernetes

```bash
# OVN-Kubernetes 使用 GENEVE 作为默认封装
# 部署时配置
OVN_GENEVE=1

# 查看 OVN 隧道
ovn-sbctl list Tunnel

# 示例输出
_uuid               : 1234-5678
chassis             : chassis-1
external_ip         : "192.168.1.10"
transport           : geneve
```

### 8.3 性能对比

```bash
# 测试不同封装的性能
# 使用 iperf3 测试

# GRE: ~980 Mbps
# VXLAN: ~950 Mbps
# GENEVE: ~940 Mbps

# GENEVE 开销略高但灵活性更好
# 在高性能场景差异可忽略
```

---

## 9. 故障排查

### 9.1 常见问题

```bash
# 1. GENEVE 接口无法创建
# 检查内核模块是否加载
modprobe geneve
lsmod | grep geneve

# 2. GENEVE 隧道不通
# 检查防火墙
iptables -L -n | grep 6081
# 或者
firewall-cmd --add-port=6081/udp

# 3. MTU 问题
# GENEVE 需要额外 58 字节头部
# 外层 MTU 至少 1558 (1500 + 58)
ip link set geneve0 mtu 1400
```

### 9.2 抓包分析

```bash
# 抓取 GENEVE 流量
tcpdump -i eth0 udp port 6081 -n

# 查看 GENEVE 头部
# 目的端口 6081
# Protocol Type: 0x6558 (Transparent Ethernet Bridging)
# VNI: 24-bit 标识
```

### 9.3 调试命令

```bash
# 查看 geneve sockets
cat /proc/net/geneve

# 查看详细统计
ip -s link show geneve0

# 查看路由
ip route show dev geneve0

# 查看网桥 MAC 表
bridge fdb show dev geneve0
```

---

## 10. 总结

GENEVE 是网络虚拟化的新一代标准协议：

**关键要点：**
1. RFC 8926 正式标准化，解决 VXLAN 扩展性问题
2. TLV 选项机制支持任意元数据扩展
3. 设计即考虑硬件卸载
4. 与 OVN/OVS 深度集成
5. UDP 封装支持 ECN 和负载均衡

**与 VXLAN 选择指南：**

| 场景 | 推荐协议 |
|------|----------|
| 简单 L2 隧道 | VXLAN |
| 需要元数据 | GENEVE |
| OVN/Kubernetes | GENEVE |
| 硬件卸载优先 | GENEVE |
| 传统数据中心 | VXLAN |

**典型应用场景：**
- OVN/OVS 网络虚拟化
- Kubernetes 容器网络
- 多租户云环境
- SDN overlay 网络
