---
title: "Kernel Protocol Stack 深度探索 (三十六)：Conntrack 内部机制"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    conntrack,
    nf-conntrack,
    hash-table,
    timeout,
    gc,
    nat-helper,
    ct-state,
  ]
description: "深入解析 Linux 连接跟踪（conntrack）内部机制——nf_conn 结构、哈希表设计、tuple 计算、状态机、超时与 GC、NAT 辅助模块（ALG）、以及大规模场景调优"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[kernel-protocol-stack-deep-dive|全栈学习路径总览]] 15. [[ch15-conntrack|第十五章：连接跟踪 Conntrack]] 16. [[ch16-nat|第十六章：NAT 与地址转换]] 33. [[ch33-netfilter-hook|第三十三章：Netfilter 框架详解]] 35. [[ch36-nftables|第三十五章：nftables]] 36. **第三十六章：Conntrack 内部机制**

---

## 1. 概述

连接跟踪（Connection Tracking，conntrack）是 Linux 内核中实现**有状态防火墙**和 **NAT** 的基础组件。它追踪每个网络连接的状态，使内核能够：

1. 判断数据包属于新连接还是已有连接（ESTABLISHED/RELATED/INVALID）
2. 为 NAT 提供反向映射（DNAT 建立的连接，回包自动做反向 SNAT）
3. 支持 ALG（应用层网关）处理 FTP/SIP 等需要端口协商的协议
4. 为 iptables/nftables 提供连接状态信息

---

## 2. 核心数据结构

### 2.1 nf_conn（连接条目）

```c
// include/net/netfilter/nf_conntrack.h
struct nf_conn {
    // 引用计数
    struct nf_conntrack   ct_general;

    // 连接 tuple（5元组的双向描述）
    struct nf_conntrack_tuple_hash tuplehash[IP_CT_DIR_MAX];
    // [0] = ORIGINAL  (发起方->应答方方向)
    // [1] = REPLY     (应答方->发起方方向)

    // 连接状态位图
    unsigned long         status;       // IPS_CONFIRMED, IPS_NAT_DONE, etc.

    // 回收机制
    u32                   timeout;      // 超时（jiffies）

    // 网络命名空间
    possible_net_t        ct_net;

    // NAT 信息（CONFIG_NF_NAT 时存在）
    struct nf_conn_nat    *nat;         // NAT 扩展

    // 连接标记（用于策略路由/QoS）
    u32                   mark;         // nf_ct_mark
    u32                   secmark;      // SELinux 安全标记

    // 协议私有数据（TCP/UDP/ICMP 状态）
    union nf_conntrack_proto proto;

    // 扩展区域（extensions: helper, acct, timestamps, etc.）
    struct nf_ct_ext      *ext;
};
```

### 2.2 nf_conntrack_tuple（五元组）

```c
// include/net/netfilter/nf_conntrack_tuple.h
struct nf_conntrack_tuple {
    struct nf_conntrack_man src;  // 源（可以被 NAT 修改）
    struct {
        union nf_inet_addr u3;    // 目标 IP
        union {
            __be16  all;
            struct { __be16 port; } tcp;
            struct { __be16 port; } udp;
            struct { u_int8_t type, code; } icmp;
        } u;
        u_int8_t protonum;        // 协议号
        u_int8_t dir;             // 方向
    } dst;
};

struct nf_conntrack_man {
    union nf_inet_addr u3;        // 源 IP
    union nf_conntrack_man_proto u; // 源端口 / ICMP ID
    u_int16_t l3num;              // 地址族 (AF_INET/AF_INET6)
};
```

### 2.3 连接条目的内存布局

```
nf_conn 内存布局：
┌──────────────────────────────────┐
│ nf_conntrack (ct_general)        │  引用计数
├──────────────────────────────────┤
│ tuplehash[ORIGINAL]              │  hlist_node + 原始方向 tuple
├──────────────────────────────────┤
│ tuplehash[REPLY]                 │  hlist_node + 回复方向 tuple
├──────────────────────────────────┤
│ status, timeout, mark, secmark   │  连接元数据
├──────────────────────────────────┤
│ union nf_conntrack_proto         │  TCP/UDP/ICMP 特定状态
├──────────────────────────────────┤
│ nf_ct_ext (可变长扩展区)          │  helper/acct/timestamp/nat/...
└──────────────────────────────────┘
```

---

## 3. 哈希表设计

### 3.1 双向哈希表

conntrack 维护一张哈希表，同时索引连接的两个方向（ORIGINAL 和 REPLY tuple）：

```
conntrack 哈希表：
  bucket[hash(orig_tuple)]  → tuplehash[ORIGINAL] → nf_conn
  bucket[hash(reply_tuple)] → tuplehash[REPLY]    → nf_conn

查找时：
  来包 -> 计算 tuple -> 在哈希表中查找
  如果找到 tuplehash[ORIGINAL] -> 这是正向包（发起方）
  如果找到 tuplehash[REPLY]    -> 这是回包（应答方）
```

### 3.2 哈希函数

```c
// net/netfilter/nf_conntrack_core.c
static u32 hash_conntrack_raw(const struct nf_conntrack_tuple *tuple,
                               unsigned int zoneid, const struct net *net)
{
    u64 a, b;
    // SipHash13 对 tuple 进行哈希，种子包含 nf_conntrack_hash_rnd 防止 HashDoS
    get_random_once(&nf_conntrack_hash_rnd, sizeof(nf_conntrack_hash_rnd));
    a = (u64)tuple->src.u3.ip  ^ tuple->dst.u3.ip;
    b = (u64)tuple->src.u.all  ^ tuple->dst.u.all;
    return siphash_2u64(a ^ zoneid, b ^ net_hash_mix(net),
                        &nf_conntrack_hash_rnd);
}
```

### 3.3 哈希表大小配置

```bash
# 查看当前哈希表大小
cat /proc/sys/net/netfilter/nf_conntrack_buckets   # 哈希桶数
cat /proc/sys/net/netfilter/nf_conntrack_max        # 最大连接数

# 调整（通常 nf_conntrack_max = nf_conntrack_buckets * 8）
echo 65536 > /proc/sys/net/netfilter/nf_conntrack_buckets
echo 524288 > /proc/sys/net/netfilter/nf_conntrack_max

# 或通过 sysctl
sysctl -w net.netfilter.nf_conntrack_max=524288
```

---

## 4. 连接跟踪状态机

### 4.1 TCP 状态追踪

```c
// net/netfilter/nf_conntrack_proto_tcp.c
// TCP conntrack 状态（与 TCP 协议状态机不同，这是内核追踪用的）
enum tcp_conntrack {
    TCP_CONNTRACK_NONE,
    TCP_CONNTRACK_SYN_SENT,
    TCP_CONNTRACK_SYN_RECV,
    TCP_CONNTRACK_ESTABLISHED,
    TCP_CONNTRACK_FIN_WAIT,
    TCP_CONNTRACK_CLOSE_WAIT,
    TCP_CONNTRACK_LAST_ACK,
    TCP_CONNTRACK_TIME_WAIT,
    TCP_CONNTRACK_CLOSE,
    TCP_CONNTRACK_LISTEN,
    TCP_CONNTRACK_MAX,
    TCP_CONNTRACK_IGNORE,
    TCP_CONNTRACK_RETRANS,
    TCP_CONNTRACK_UNACK,
    TCP_CONNTRACK_TIMEOUT_MAX
};
```

### 4.2 连接 status 标志

```c
// include/uapi/linux/netfilter/nf_conntrack_common.h
enum ip_conntrack_status {
    IPS_EXPECTED_BIT = 0,      // 由 ALG helper 期望的连接
    IPS_SEEN_REPLY_BIT = 1,    // 已看到回包
    IPS_ASSURED_BIT = 2,       // 连接已确认（双向包均见到）
    IPS_CONFIRMED_BIT = 3,     // 连接已插入哈希表
    IPS_SRC_NAT_BIT = 4,       // 正在做 SNAT
    IPS_DST_NAT_BIT = 5,       // 正在做 DNAT
    IPS_SEQ_ADJUST_BIT = 6,    // TCP 序列号需要调整（ALG）
    IPS_SRC_NAT_DONE_BIT = 7,
    IPS_DST_NAT_DONE_BIT = 8,
    IPS_DYING_BIT = 9,         // 连接正在被销毁
    IPS_FIXED_TIMEOUT_BIT = 10,// 超时时间固定（不随流量重置）
    IPS_TEMPLATE_BIT = 11,     // conntrack 模板（CT action）
    IPS_UNTRACKED_BIT = 12,    // CT NOTRACK（不跟踪）
    IPS_HELPER_BIT = 13,       // helper 指定
    IPS_OFFLOAD_BIT = 14,      // flowtable offload
    IPS_HW_OFFLOAD_BIT = 15,   // 硬件 offload
};
```

### 4.3 从 skb 获取 conntrack 条目

```c
// net/netfilter/nf_conntrack_core.c

// 核心查找/创建函数
unsigned int nf_conntrack_in(struct sk_buff *skb,
                              const struct nf_hook_state *state)
{
    enum ip_conntrack_info ctinfo;
    const struct nf_conntrack_l4proto *l4proto;
    struct nf_conn *ct;
    int ret;

    // 1. 解析 L4 头，提取 tuple
    l4proto = nf_ct_l4proto_find(nf_ct_protonum(skb));
    ret = resolve_normal_ct(skb, dataoff, l4proto, &ct, &ctinfo, state);
    if (ret < 0)
        return NF_ACCEPT;

    // 2. 把 ct 指针存入 skb
    // skb->_nfct = (unsigned long)ct | ctinfo;

    // 3. 调用 L4 协议的 packet() 函数（更新状态/超时）
    ret = l4proto->packet(ct, skb, dataoff, ctinfo, state);
    return ret;
}

// 从 skb 获取 ct（只读，其他地方调用）
static inline struct nf_conn *nf_ct_get(const struct sk_buff *skb,
                                         enum ip_conntrack_info *ctinfop)
{
    *ctinfop = skb->_nfct & NFCT_INFOMASK;
    return (struct nf_conn *)(skb->_nfct & NFCT_PTRMASK);
}
```

---

## 5. 超时机制

### 5.1 超时的实现

conntrack 使用**内核定时器**（timer_list）管理连接超时。每次收到属于该连接的包时，定时器会被重置：

```c
// nf_ct_refresh_acct()：刷新超时
void __nf_ct_refresh_acct(struct nf_conn *ct,
                           enum ip_conntrack_info ctinfo,
                           const struct sk_buff *skb,
                           u32 extra_jiffies)
{
    // 更新超时（以 jiffies 为单位）
    nf_ct_set_timeout(ct, extra_jiffies);
}
```

### 5.2 各协议默认超时

```bash
# TCP 超时（秒）
sysctl net.netfilter.nf_conntrack_tcp_timeout_syn_sent     # 120
sysctl net.netfilter.nf_conntrack_tcp_timeout_syn_recv     # 60
sysctl net.netfilter.nf_conntrack_tcp_timeout_established  # 432000 (5天)
sysctl net.netfilter.nf_conntrack_tcp_timeout_fin_wait     # 120
sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait    # 120
sysctl net.netfilter.nf_conntrack_tcp_timeout_close        # 10
sysctl net.netfilter.nf_conntrack_tcp_timeout_close_wait   # 60

# UDP 超时
sysctl net.netfilter.nf_conntrack_udp_timeout               # 30
sysctl net.netfilter.nf_conntrack_udp_timeout_stream        # 180

# ICMP 超时
sysctl net.netfilter.nf_conntrack_icmp_timeout              # 30

# 通用（其他协议）
sysctl net.netfilter.nf_conntrack_generic_timeout           # 600
```

### 5.3 调优建议

```bash
# 高并发 Web 服务器（大量短连接）：降低 TIME_WAIT 超时
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=30

# 防止 conntrack 表满（大量 ESTABLISHED 但实际已断开的连接）
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=86400

# 增大 conntrack 表
sysctl -w net.netfilter.nf_conntrack_max=2000000
sysctl -w net.netfilter.nf_conntrack_buckets=500000
```

---

## 6. GC（垃圾回收）机制

### 6.1 两种 GC 触发方式

```c
// 1. 定时 GC（后台 worker）
// 每隔约 30 秒扫描哈希表，清理过期连接
static void conntrack_gc_work_init(struct conntrack_gc_work *gc_work)
{
    INIT_DELAYED_WORK(&gc_work->dwork, gc_worker);
    gc_work->exiting = false;
}

// 2. 压力触发 GC（表满时）
// 当 nf_conntrack_count >= nf_conntrack_max 时，
// nf_conntrack_alloc() 触发同步 GC
```

### 6.2 连接删除流程

```c
static void nf_ct_delete(struct nf_conn *ct, u32 portid, int report)
{
    // 1. 调用 destroy 事件通知（用户态 conntrack 监听）
    nf_conntrack_event_report(IPCT_DESTROY, ct, portid, report);

    // 2. 从哈希表中移除两个 tuplehash
    nf_ct_del_from_dying_or_unconfirmed_list(ct);

    // 3. 减少引用计数（到 0 时释放内存）
    nf_ct_put(ct);
}
```

---

## 7. NAT 辅助模块（ALG）

某些应用层协议（FTP、SIP、H.323、PPTP）会在载荷中协商第二个连接的 IP 和端口，NAT 必须修改这些载荷。ALG（Application Layer Gateway）正是为此而生：

### 7.1 FTP Helper

```
FTP 主动模式（Active Mode）：
  客户端 (10.0.0.1) → NAT → FTP服务器 (1.2.3.4:21)

  客户端发送 PORT 10,0,0,1,12,34（表示监听 10.0.0.1:3106）
  NAT 将载荷改为 PORT <公网IP>,12,34
  同时在 conntrack 中创建 EXPECTED 连接条目：
    预期连接：1.2.3.4:20 → <公网IP>:3106
  当服务器的数据连接到达时，conntrack 识别为 RELATED 并允许通过
```

### 7.2 Helper 注册

```c
// net/netfilter/nf_conntrack_ftp.c
static struct nf_conntrack_helper ftp[MAX_PORTS][2] = {
    {
        .name       = "ftp",
        .l4proto    = IPPROTO_TCP,
        .help       = help,          // 解析 FTP 命令
        .expect_class_max = 1,
    }
};

// 注册
ret = nf_conntrack_helpers_register(ftp[i], 2);
```

### 7.3 期望连接（Expected Connection）

```c
// 创建 EXPECTED 连接条目
struct nf_conntrack_expect *exp;
exp = nf_ct_expect_alloc(ct);
nf_ct_expect_init(exp, class, family,
                  &ct->tuplehash[!dir].tuple.src.u3,
                  &ct->tuplehash[!dir].tuple.dst.u3,
                  IPPROTO_TCP, NULL, &port);
nf_ct_expect_related(exp, flags);
```

---

## 8. 连接跟踪事件（ctnetlink）

conntrack 通过 netlink 向用户空间广播连接状态事件：

```bash
# 监听 conntrack 事件
conntrack -E  # 实时显示所有连接事件

# 输出示例：
# [NEW]     tcp      6 120 SYN_SENT src=192.168.1.1 dst=8.8.8.8 sport=12345 dport=80 ...
# [UPDATE]  tcp      6 60 ESTABLISHED src=192.168.1.1 dst=8.8.8.8 sport=12345 dport=80 ...
# [DESTROY] tcp      6 src=192.168.1.1 dst=8.8.8.8 sport=12345 dport=80 ...
```

---

## 9. 生产调优与监控

### 9.1 关键监控指标

```bash
# 当前连接数 vs 最大值
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 详细统计（含丢包原因）
cat /proc/net/stat/nf_conntrack
# 字段含义：
# entries: 当前条目数
# searched: 哈希查找次数
# found: 查找命中次数
# new: 新建连接数
# invalid: 无效包数（INVALID 状态）
# ignore: 未追踪包数（NOTRACK）
# insert_failed: 插入失败（竞争）
# drop: 因表满丢弃的包
# early_drop: 提前回收连接（ASSURED 降级）
# error: L4 协议层错误

# 连接详情
conntrack -L           # 所有连接
conntrack -L -p tcp    # 仅 TCP
conntrack -L --state ESTABLISHED  # 仅已建立连接
```

### 9.2 性能优化

```bash
# 1. 对 flowtable 卸载的连接，减少 conntrack 开销
# （nftables flowtable 卸载后，conntrack 仍会更新超时，但不再做完整检查）

# 2. 对内部流量关闭 conntrack（节省 CPU 和内存）
iptables -t raw -A PREROUTING -i lo -j NOTRACK
iptables -t raw -A OUTPUT -o lo -j NOTRACK

# 3. 针对已知大流量（如 CDN 回源）关闭跟踪
iptables -t raw -A PREROUTING -s 203.0.113.0/24 -j NOTRACK

# 4. 使用 CPU-affine 的 conntrack（per-CPU 哈希桶，内核 5.9+）
# 自动启用，确保 RPS/XPS 配置合理使同一连接的包在同一 CPU 处理
```

---

## 10. 小结

conntrack 是 Linux 有状态防火墙和 NAT 的基石：

- **双向哈希表** + SipHash 防止 HashDoS 攻击
- **nf_conn** 结构通过扩展机制（ext）支持 NAT、accounting、helper 等可选功能
- **TCP 状态机**追踪 14 个内部状态，精确识别连接生命周期
- **超时机制** + 定期 GC 防止内存泄漏，可根据场景调整超时参数
- **ALG Helper** 处理 FTP/SIP 等需要载荷内容感知的协议
- **ctnetlink** 将连接事件实时推送到用户空间，是 conntrack 工具和 IPVS/HAProxy 的基础

下一章将深入 NAT 的实现原理——fullcone/symmetric NAT 的区别、端口复用策略、以及 STUN/TURN 的内核支持。
