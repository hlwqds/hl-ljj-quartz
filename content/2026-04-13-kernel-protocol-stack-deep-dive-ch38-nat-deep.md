---
title: "Kernel Protocol Stack 深度探索 (三十七)：NAT 深度解析"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    nat,
    snat,
    dnat,
    masquerade,
    fullcone,
    symmetric-nat,
    stun,
    port-reuse,
    hairpin-nat,
  ]
description: "深入解析 Linux NAT 实现原理——NAT 类型（fullcone/restricted-cone/port-restricted/symmetric）、SNAT/DNAT/MASQUERADE、端口冲突解决、TCP 序列号调整、hairpin NAT、以及 STUN 穿透与内核支持"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]] 15. [[2026-04-13-kernel-protocol-stack-deep-dive-ch15-conntrack|第十五章：连接跟踪 Conntrack]] 16. [[2026-04-13-kernel-protocol-stack-deep-dive-ch16-nat|第十六章：NAT 与地址转换]] 36. [[2026-04-13-kernel-protocol-stack-deep-dive-ch37-conntrack-internals|第三十六章：Conntrack 内部机制]] 37. **第三十七章：NAT 深度解析**

---

## 1. NAT 的本质

NAT（Network Address Translation，网络地址转换）通过修改 IP 报文的源/目的地址和端口，解决 IPv4 地址不足问题，并实现内网隔离。

Linux 内核 NAT 的实现依赖 conntrack：

1. conntrack 记录连接的原始 tuple（ORIGINAL 方向）
2. NAT 模块计算转换后的 tuple（REPLY 方向）
3. 后续属于该连接的包，根据 REPLY tuple 自动做反向转换

```
SNAT 示例：
  内网包：  10.0.0.1:12345 → 8.8.8.8:80     (ORIGINAL)
  转换后：203.0.113.1:54321 → 8.8.8.8:80    (经 NAT 修改后)

  conntrack 记录：
    ORIGINAL: src=10.0.0.1:12345  dst=8.8.8.8:80
    REPLY:    src=8.8.8.8:80      dst=203.0.113.1:54321

  回包自动转换（无需额外规则）：
    8.8.8.8:80 → 203.0.113.1:54321  ──NAT反转──►  8.8.8.8:80 → 10.0.0.1:12345
```

---

## 2. NAT 类型分类

根据 RFC 3489（STUN），NAT 行为分为四种：

### 2.1 Full Cone NAT（完全锥形）

```
外部 IP:Port 映射固定，任何外部主机都可通过该映射主动连接内网

  内网 A:1000 ──SNAT──► 公网:5000

  外部任意主机 B:任意 → 公网:5000 → A:1000  ✓ 可穿透
```

### 2.2 Restricted Cone NAT（限制锥形）

```
内网 A:1000 主动连接过 B 后，B 才能主动连接 A

  内网 A:1000 → B:80 映射为 公网:5000
  B 的任意端口 → 公网:5000 → A:1000  ✓
  C（未连接过）→ 公网:5000 → A:1000  ✗
```

### 2.3 Port-Restricted Cone NAT（端口限制锥形）

```
必须是 A 主动连接过的 B:port 才能穿透

  A:1000 → B:80 映射为 公网:5000
  B:80 → 公网:5000  ✓
  B:81 → 公网:5000  ✗（不同端口）
```

### 2.4 Symmetric NAT（对称型）

```
每个目标(IP+Port)分配不同的公网端口

  A:1000 → B:80  映射为  公网:5000
  A:1000 → C:80  映射为  公网:5001  (不同目标，不同映射)

  STUN 穿透失败，需要 TURN 中继
```

### 2.5 Linux 默认 NAT 类型

Linux 的 MASQUERADE/SNAT 是 **Port-Restricted Cone NAT** 行为——相同的（源 IP:源端口→目标 IP:目标端口）四元组会重用同一映射，但不同目标不共享映射（与真正的 Full Cone 不同）。

---

## 3. 内核 NAT 实现

### 3.1 NAT 模块与 Netfilter 集成

```c
// net/netfilter/nf_nat_core.c

// NAT 钩子注册
static const struct nf_hook_ops nf_nat_ipv4_ops[] = {
    // PREROUTING: DNAT（目标地址转换）
    {
        .hook     = nf_nat_ipv4_pre_routing,
        .pf       = NFPROTO_IPV4,
        .hooknum  = NF_INET_PRE_ROUTING,
        .priority = NF_IP_PRI_NAT_DST,  // -100
    },
    // POSTROUTING: SNAT（源地址转换）
    {
        .hook     = nf_nat_ipv4_out,
        .pf       = NFPROTO_IPV4,
        .hooknum  = NF_INET_POST_ROUTING,
        .priority = NF_IP_PRI_NAT_SRC,  // +100
    },
    // LOCAL_IN: 本机收到的 DNAT 包（端口转发到本机）
    {
        .hook     = nf_nat_ipv4_local_in,
        .pf       = NFPROTO_IPV4,
        .hooknum  = NF_INET_LOCAL_IN,
        .priority = NF_IP_PRI_NAT_DST,
    },
    // LOCAL_OUT: 本机发出的包的 DNAT
    {
        .hook     = nf_nat_ipv4_local_fn,
        .pf       = NFPROTO_IPV4,
        .hooknum  = NF_INET_LOCAL_OUT,
        .priority = NF_IP_PRI_NAT_DST,
    },
};
```

### 3.2 端口分配核心函数

```c
// net/netfilter/nf_nat_core.c
unsigned int nf_nat_setup_info(struct nf_conn *ct,
                                const struct nf_nat_range2 *range,
                                enum nf_nat_manip_type maniptype)
{
    struct nf_conntrack_tuple curr_tuple, new_tuple;

    // 1. 获取当前 REPLY 方向 tuple
    nf_ct_invert_tuple(&curr_tuple, &ct->tuplehash[IP_CT_DIR_REPLY].tuple);

    // 2. 在 range 指定范围内找一个不冲突的 tuple
    find_appropriate_src(ct->net, zone, l3proto, l4proto,
                          &curr_tuple, &new_tuple, range);

    // 3. 将新 tuple 保存到 conntrack 的 REPLY 方向
    nf_conntrack_alter_reply(ct, &new_tuple);

    // 4. 标记 NAT 已完成
    if (maniptype == NF_NAT_MANIP_SRC)
        ct->status |= IPS_SRC_NAT | IPS_SRC_NAT_DONE;
    else
        ct->status |= IPS_DST_NAT | IPS_DST_NAT_DONE;

    return NF_ACCEPT;
}
```

### 3.3 端口冲突解决算法

```
端口分配策略（nf_nat_l4proto_unique_tuple）：

1. 优先尝试保留原始端口（如果不冲突）
2. 在 range [min_port, max_port] 内顺序扫描
3. 找到不与现有 conntrack 条目冲突的端口
4. 如果 range 内无可用端口，返回失败（NAT 失败，包被丢弃）

源端口范围（MASQUERADE 默认）：
  内核取 ip_local_port_range = [32768, 60999] 对应的 NAT 端口范围
  可通过 --to-ports 指定自定义范围
```

---

## 4. SNAT 与 MASQUERADE

### 4.1 SNAT

```bash
# 固定源 IP 的 SNAT（适合固定公网 IP 场景）
iptables -t nat -A POSTROUTING -o eth0 -s 192.168.0.0/24 \
    -j SNAT --to-source 203.0.113.1

# 指定端口范围
iptables -t nat -A POSTROUTING -o eth0 -s 192.168.0.0/24 \
    -j SNAT --to-source 203.0.113.1:1024-65535

# SNAT 到多个 IP（负载均衡出口）
iptables -t nat -A POSTROUTING -o eth0 \
    -j SNAT --to-source 203.0.113.1-203.0.113.3
```

### 4.2 MASQUERADE（动态 SNAT）

```bash
# MASQUERADE：自动使用出接口的当前 IP（适合 DHCP/PPPoE 场景）
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# 指定端口范围
iptables -t nat -A POSTROUTING -o eth0 \
    -j MASQUERADE --to-ports 1024-65535

# MASQUERADE 与 SNAT 的区别：
# - MASQUERADE 每个包都查询接口 IP（有额外开销，但接口 IP 变化时自动适配）
# - SNAT 静态记录，IP 变化不会自动更新已有连接
```

### 4.3 nftables 中的 MASQUERADE/SNAT

```bash
# nftables MASQUERADE
nft add rule ip nat POSTROUTING oif eth0 masquerade

# nftables SNAT
nft add rule ip nat POSTROUTING oif eth0 \
    snat to 203.0.113.1

# 带端口范围
nft add rule ip nat POSTROUTING oif eth0 \
    snat to 203.0.113.1:1024-65535

# 源 IP 映射表（不同内网段走不同公网 IP）
nft add map ip nat SNAT_MAP { type ipv4_addr : ipv4_addr \; }
nft add element ip nat SNAT_MAP { 192.168.1.0/24 : 203.0.113.1, 192.168.2.0/24 : 203.0.113.2 }
nft add rule ip nat POSTROUTING oif eth0 snat ip saddr map @SNAT_MAP
```

---

## 5. DNAT 与端口转发

### 5.1 DNAT（目标地址转换）

```bash
# 端口转发（将公网 80 转发到内网服务器）
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 \
    -j DNAT --to-destination 192.168.1.100:8080

# 转发到不同端口
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 443 \
    -j DNAT --to-destination 192.168.1.100:443

# 同时转发 TCP 和 UDP（DNS）
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 53 \
    -j DNAT --to-destination 192.168.1.53
iptables -t nat -A PREROUTING -i eth0 -p udp --dport 53 \
    -j DNAT --to-destination 192.168.1.53

# FORWARD 规则允许转发（还需要）
iptables -A FORWARD -i eth0 -d 192.168.1.100 -p tcp --dport 8080 \
    -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
```

### 5.2 REDIRECT（本机端口重定向）

```bash
# 将进入 eth0 的 80 端口流量重定向到本机 3128（透明代理）
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 \
    -j REDIRECT --to-port 3128

# 本机发出的流量也重定向（用于本机透明代理）
iptables -t nat -A OUTPUT -p tcp --dport 80 \
    -j REDIRECT --to-port 3128
```

---

## 6. Hairpin NAT（发卡 NAT）

Hairpin NAT 解决内网主机通过公网 IP 访问同一内网服务器的问题：

```
问题场景：
  客户端 192.168.1.2 → 公网 IP 203.0.113.1:80
  公网 IP 应该 DNAT 到内网服务器 192.168.1.100:80
  但数据包来自内网，路由器可能无法正确处理

解决：Hairpin SNAT
```

```bash
# 方法一：MASQUERADE + DNAT（两个规则）
# DNAT：公网 IP → 内网服务器
iptables -t nat -A PREROUTING -d 203.0.113.1 -p tcp --dport 80 \
    -j DNAT --to-destination 192.168.1.100

# Hairpin SNAT：内网访问时，SNAT 源地址（防止回包路由问题）
iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -d 192.168.1.100 \
    -p tcp --dport 80 -j MASQUERADE

# 方法二：nftables（更清晰）
nft add rule ip nat PREROUTING ip daddr 203.0.113.1 tcp dport 80 \
    dnat to 192.168.1.100:80
nft add rule ip nat POSTROUTING ip saddr 192.168.1.0/24 \
    ip daddr 192.168.1.100 tcp dport 80 masquerade
```

---

## 7. TCP 序列号调整

当 NAT ALG 修改了 TCP 载荷长度（如 FTP PORT 命令中 IP 地址从 IPv4 短写到长写），必须调整后续包的 TCP 序列号：

```c
// net/netfilter/nf_nat_proto_tcp.c 简化版
void nf_nat_tcp_seq_adjust(struct sk_buff *skb, struct nf_conn *ct,
                             u32 ctinfo, int off)
{
    struct tcphdr *tcph = tcp_hdr(skb);

    if (off == 0)
        return;

    // 记录序列号偏移量（保存在 nf_conn_seqadj 扩展中）
    struct nf_conn_seqadj *seqadj = nfct_seqadj(ct);
    seqadj->corrections[CTINFO2DIR(ctinfo)].offset_after = off;

    // 调整当前包的序列号
    if (ctinfo == IP_CT_ESTABLISHED_REPLY) {
        tcph->ack_seq = htonl(ntohl(tcph->ack_seq) - off);
    } else {
        tcph->seq = htonl(ntohl(tcph->seq) + off);
    }

    nf_nat_csum_recalc(skb);
}
```

---

## 8. NAT 与 conntrack zone

在多租户场景（如 OpenStack Neutron），不同租户可能使用相同的私有 IP 段。conntrack zone 允许对不同网络命名空间/VLAN 使用独立的 conntrack 表：

```bash
# 为不同 VLAN 设置不同的 conntrack zone
iptables -t raw -A PREROUTING -i eth0.100 \
    -j CT --zone 100 --zone-orig

iptables -t raw -A PREROUTING -i eth0.200 \
    -j CT --zone 200 --zone-orig

# 不同 zone 中相同的 10.0.0.1 被视为不同的端点
```

---

## 9. 全锥型 NAT 实现（内核 5.9+ nftables）

标准 Linux 是 Port-Restricted Cone，某些 P2P 应用（游戏、WebRTC）需要 Full Cone：

```bash
# 使用 nftables 实现近似 Full Cone（内核 5.9 引入 nft_nat 增强）
# 所有来自内网 A:port 的连接映射到同一公网 port

nft add rule ip nat POSTROUTING \
    ip saddr 192.168.0.0/16 oif eth0 \
    snat to 203.0.113.1 persistent  # persistent: 相同内网地址复用相同映射
```

---

## 10. NAT 性能优化

### 10.1 conntrack + flowtable 卸载

```bash
# nftables flowtable 让已建立的 NAT 连接绕过 Netfilter
nft add flowtable ip nat ft {
    hook ingress priority -1
    devices = { eth0, eth1 }
}

nft add rule ip filter FORWARD \
    ct state established flow add @ft
```

### 10.2 避免端口耗尽

```bash
# 监控 NAT 端口使用情况
conntrack -L -p tcp | grep ESTABLISHED | wc -l

# 扩大 NAT 端口范围
echo "1024 65535" > /proc/sys/net/ipv4/ip_local_port_range

# 使用多个公网 IP 做 SNAT（负载均衡）
iptables -t nat -A POSTROUTING -o eth0 \
    -j SNAT --to-source 203.0.113.1-203.0.113.10
```

### 10.3 NAT 表满的处理

```bash
# 查看 NAT 连接是否满
watch -n1 'echo "CT: $(cat /proc/sys/net/netfilter/nf_conntrack_count) / $(cat /proc/sys/net/netfilter/nf_conntrack_max)"'

# NAT 表满时的内核日志
dmesg | grep "nf_conntrack: table full"

# 解决：增大 conntrack_max + 减少超时
sysctl -w net.netfilter.nf_conntrack_max=2000000
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
```

---

## 11. 小结

Linux NAT 是基于 conntrack 的有状态地址转换系统：

- **SNAT/MASQUERADE/DNAT/REDIRECT** 覆盖了所有典型 NAT 场景
- **端口冲突算法**保证同一公网 IP 下大量并发连接不冲突
- **Hairpin NAT** 解决了内网访问公网 IP 的路由回环问题
- **TCP 序列号调整** 保证 ALG 修改载荷后 TCP 可靠传输不受影响
- **conntrack zone** 在多租户场景下隔离不同网络的连接跟踪
- **flowtable** 将热点 NAT 连接卸载，显著降低转发延迟

下一章将介绍 **XDP 与 Netfilter 的协同**——XDP 如何作为 Netfilter 的高性能前置处理层，以及 XDP redirect、AF_XDP、以及两者在 DDoS 防护中的分工。
