---
title: "Kernel Protocol Stack 深度探索 (三十三)：Netfilter 框架详解"
date: 2026-04-13
tags: [linux, kernel, networking, series, netfilter, nf-hook, iptables, nf_register_net_hook, packet-filter]
description: "深入解析 Netfilter 框架——5 个钩子点、NF_HOOK 宏展开、优先级机制、钩子注册/注销流程、verdict 处理，以及 Netfilter 与 iptables/nftables/conntrack 的协同关系"
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
> 17. [[2026-04-13-kernel-protocol-stack-deep-dive-ch17-gre|第十七章：GRE 隧道]]
> 18. [[2026-04-13-kernel-protocol-stack-deep-dive-ch18-vxlan|第十八章：VXLAN 覆盖网络]]
> 19. [[2026-04-13-kernel-protocol-stack-deep-dive-ch19-geneve|第十九章：GENEVE 与 OVN]]
> 20. [[2026-04-13-kernel-protocol-stack-deep-dive-ch20-fib-rules|第二十章：FIB Rules 与策略路由]]
> 21. [[2026-04-13-kernel-protocol-stack-deep-dive-ch21-tcp-headers|第二十一章：TCP 协议实现 (上)]]
> 22. [[2026-04-13-kernel-protocol-stack-deep-dive-ch22-tcp-states|第二十二章：TCP 协议实现 (中)]]
> 23. [[2026-04-13-kernel-protocol-stack-deep-dive-ch23-tcp-data-buffer|第二十三章：TCP 协议实现 (下)]]
> 24. [[2026-04-13-kernel-protocol-stack-deep-dive-ch24-tcp-congestion|第二十四章：TCP 拥塞控制]]
> 25. [[2026-04-13-kernel-protocol-stack-deep-dive-ch25-tcp-advanced|第二十五章：TCP 高级特性]]
> 26. [[2026-04-13-kernel-protocol-stack-deep-dive-ch26-udp|第二十六章：UDP 协议实现]]
> 27. [[2026-04-13-kernel-protocol-stack-deep-dive-ch27-raw-socket|第二十七章：RAW Socket 与 ICMP]]
> 28. [[2026-04-13-kernel-protocol-stack-deep-dive-ch28-socket-api|第二十八章：Socket API 概述]]
> 29. [[2026-04-13-kernel-protocol-stack-deep-dive-ch29-inet-sock|第二十九章：Inet Socket 实现]]
> 30. [[2026-04-13-kernel-protocol-stack-deep-dive-ch30-sock-mem|第三十章：Socket 内存管理]]
> 31. [[2026-04-13-kernel-protocol-stack-deep-dive-ch31-netlink|第三十一章：Netlink 通信机制]]
> 32. [[2026-04-13-kernel-protocol-stack-deep-dive-ch32-unix-socket|第三十二章：Unix Domain Socket]]
> 33. **第三十三章：Netfilter 框架详解**

---

## 1. 概述

Netfilter 是 Linux 内核内置的包处理框架，诞生于 1998 年（Rusty Russell），自内核 2.3 起成为标准组件。它通过在协议栈关键位置插入**钩子（hook）**，允许内核模块对数据包执行检查、修改、丢弃、重定向等操作。

Netfilter 是以下功能的基础：
- iptables / ip6tables / arptables / ebtables
- nftables（下一代防火墙框架）
- conntrack（连接跟踪）
- NAT（网络地址转换）
- IPVS（IP 虚拟服务器）
- eBPF TC/XDP（通过 Netfilter 协同）

```
用户空间工具              内核 Netfilter 框架
─────────────          ──────────────────────────────────────
iptables     ──┐       ┌──── NF_INET_PRE_ROUTING  hook point
nftables     ──┤  <──> │     NF_INET_LOCAL_IN      hook point
ip6tables    ──┤       │     NF_INET_FORWARD        hook point
conntrack    ──┘       │     NF_INET_LOCAL_OUT      hook point
                       └──── NF_INET_POST_ROUTING   hook point
```

---

## 2. 五个钩子点

### 2.1 IPv4 钩子点定义

```c
// include/uapi/linux/netfilter.h
enum nf_inet_hooks {
    NF_INET_PRE_ROUTING,   // 0 - 报文进入本机，路由判决前
    NF_INET_LOCAL_IN,      // 1 - 路由判决：本机接收
    NF_INET_FORWARD,       // 2 - 路由判决：转发
    NF_INET_LOCAL_OUT,     // 3 - 本机发出，路由后
    NF_INET_POST_ROUTING,  // 4 - 报文离开本机前
    NF_INET_NUMHOOKS
};
```

### 2.2 数据包完整流程图

```
网卡收包
    │
    ▼
ip_rcv()
    │
    ├──[NF_INET_PRE_ROUTING]──► conntrack/DNAT/raw/mangle
    │
    ▼
ip_rcv_finish() → 路由判决
    │
    ├──目标是本机──────────────────────────────────────────────┐
    │  [NF_INET_LOCAL_IN] → filter/mangle/security            │
    │  → tcp_v4_rcv() / udp_rcv() / icmp_rcv()                │
    │                                                           │
    └──需要转发──────────────────────────────────────────────┐  │
       [NF_INET_FORWARD] → filter/mangle/security            │  │
       → ip_forward_finish()                                 │  │
       [NF_INET_POST_ROUTING] → SNAT/mangle                  │  │
       → 网卡发送                                            │  │
                                                             │  │
本机应用发包                                                 │  │
    │                                                        │  │
    ▼                                                        │  │
ip_local_out()                                               │  │
    │                                                        │  │
    [NF_INET_LOCAL_OUT] → filter/nat/mangle/raw              │  │
    │                                                        │  │
    ▼                                                        │  │
ip_output()                                                  │  │
    [NF_INET_POST_ROUTING] → SNAT/mangle ◄───────────────────┘  │
    → 网卡发送                                                   │
                                                                 │
◄────────────────────────────────────────────────────────────────┘
```

### 2.3 各钩子点的典型用途

| Hook 点 | 典型模块 | 典型操作 |
|---------|---------|---------|
| PRE_ROUTING | conntrack, DNAT, raw | 连接跟踪初始化, DNAT 目标地址转换 |
| LOCAL_IN | filter, mangle, security | 防火墙过滤, SELinux 检查 |
| FORWARD | filter, mangle, security | 转发包过滤, QoS 标记 |
| LOCAL_OUT | filter, nat, mangle, raw | 本机发出包过滤, OUTPUT DNAT |
| POST_ROUTING | SNAT, mangle | 源地址转换, 出口 mangle |

---

## 3. 核心数据结构

### 3.1 nf_hook_ops

```c
// include/linux/netfilter.h
struct nf_hook_ops {
    nf_hookfn       *hook;        // 钩子函数指针
    struct net_device *dev;       // 可选：绑定特定设备
    void            *priv;        // 私有数据
    u8              pf;           // 协议族: NFPROTO_IPV4/IPv6/ARP...
    enum nf_hook_ops_type hook_ops_type; // NF_HOOK_OP_UNDEFINED/NF_HOOK_OP_NF_TABLES
    unsigned int    hooknum;      // 钩子点编号 (NF_INET_PRE_ROUTING 等)
    int             priority;     // 优先级 (越小越先执行)
};
```

### 3.2 钩子函数原型

```c
typedef unsigned int nf_hookfn(void *priv,
                                struct sk_buff *skb,
                                const struct nf_hook_state *state);
```

返回值 (verdict，裁决)：

```c
#define NF_DROP   0    // 丢弃数据包
#define NF_ACCEPT 1    // 继续处理
#define NF_STOLEN 2    // 数据包由钩子函数接管，不继续传递
#define NF_QUEUE  3    // 排队到用户空间 (libnetfilter_queue)
#define NF_REPEAT 4    // 重新从当前钩子点开始处理
#define NF_STOP   5    // 停止继续调用后续钩子 (已废弃，等同 ACCEPT)
```

### 3.3 nf_hook_state

```c
struct nf_hook_state {
    u8          hook;       // 当前钩子点
    u8          pf;         // 协议族
    struct net_device *in;  // 入接口
    struct net_device *out; // 出接口
    struct sock *sk;        // 关联的 socket (LOCAL_OUT 时有效)
    struct net  *net;       // 网络命名空间
    int         (*okfn)(struct net *, struct sock *, struct sk_buff *);
};
```

---

## 4. NF_HOOK 宏展开

### 4.1 宏定义

```c
// include/linux/netfilter.h
static inline int
NF_HOOK(uint8_t pf, unsigned int hook, struct net *net, struct sock *sk,
        struct sk_buff *skb, struct net_device *in, struct net_device *out,
        int (*okfn)(struct net *, struct sock *, struct sk_buff *))
{
    int ret = nf_hook(pf, hook, net, sk, skb, in, out, okfn);
    if (ret == 1)
        ret = okfn(net, sk, skb);
    return ret;
}
```

### 4.2 nf_hook 核心逻辑

```c
// net/netfilter/core.c
int nf_hook(u_int8_t pf, unsigned int hook, struct net *net,
            struct sock *sk, struct sk_buff *skb,
            struct net_device *indev, struct net_device *outdev,
            int (*okfn)(struct net *, struct sock *, struct sk_buff *))
{
    struct nf_hook_entries *hook_head = NULL;
    int ret = 1;  // 默认 ACCEPT

    // 获取当前协议族/钩子点的 hook 链表
    hook_head = rcu_dereference(net->nf.hooks_ipv4[hook]);
    if (hook_head) {
        struct nf_hook_state state;
        nf_hook_state_init(&state, hook, pf, indev, outdev, sk, net, okfn);
        ret = nf_hook_slow(skb, &state, hook_head, 0);
    }
    return ret;
}
```

### 4.3 nf_hook_slow 遍历钩子链

```c
int nf_hook_slow(struct sk_buff *skb, struct nf_hook_state *state,
                 const struct nf_hook_entries *e, unsigned int s)
{
    unsigned int verdict;
    int ret;

    for (; s < e->num_hook_entries; s++) {
        verdict = nf_hook_entry_hookfn(&e->hooks[s], skb, state);
        switch (verdict & NF_VERDICT_MASK) {
        case NF_ACCEPT:
            break;                // 继续下一个钩子
        case NF_DROP:
            kfree_skb(skb);
            ret = NF_DROP_GETERR(verdict);
            return ret;
        case NF_QUEUE:
            ret = nf_queue(skb, state, s, verdict);
            if (ret == 1)
                continue;
            return ret;
        default:
            return 0;
        }
    }
    return 1;  // 所有钩子均 ACCEPT
}
```

---

## 5. 钩子注册与注销

### 5.1 注册单个钩子

```c
// 注册
int nf_register_net_hook(struct net *net, const struct nf_hook_ops *ops);

// 注销
void nf_unregister_net_hook(struct net *net, const struct nf_hook_ops *ops);

// 批量注册
int nf_register_net_hooks(struct net *net, const struct nf_hook_ops *reg, unsigned int n);
void nf_unregister_net_hooks(struct net *net, const struct nf_hook_ops *reg, unsigned int n);
```

### 5.2 典型模块注册示例

```c
// 一个简单的包计数器 Netfilter 模块
#include <linux/module.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/ip.h>

static atomic64_t pkt_count = ATOMIC64_INIT(0);

static unsigned int my_hook_fn(void *priv, struct sk_buff *skb,
                                const struct nf_hook_state *state)
{
    atomic64_inc(&pkt_count);
    pr_debug("packet #%lld: src=%pI4\n",
             atomic64_read(&pkt_count),
             &ip_hdr(skb)->saddr);
    return NF_ACCEPT;
}

static struct nf_hook_ops my_nf_ops = {
    .hook     = my_hook_fn,
    .pf       = NFPROTO_IPV4,
    .hooknum  = NF_INET_PRE_ROUTING,
    .priority = NF_IP_PRI_FIRST,  // -300: 最高优先级
};

static int __init my_module_init(void)
{
    return nf_register_net_hook(&init_net, &my_nf_ops);
}

static void __exit my_module_exit(void)
{
    nf_unregister_net_hook(&init_net, &my_nf_ops);
}

module_init(my_module_init);
module_exit(my_module_exit);
MODULE_LICENSE("GPL");
```

---

## 6. 优先级机制

### 6.1 预定义优先级常量

```c
// include/uapi/linux/netfilter_ipv4.h
enum nf_ip_hook_priorities {
    NF_IP_PRI_FIRST            = INT_MIN, // 最高优先级
    NF_IP_PRI_RAW_BEFORE_DEFRAG = -450,
    NF_IP_PRI_CONNTRACK_DEFRAG  = -400,
    NF_IP_PRI_RAW              = -300,
    NF_IP_PRI_SELINUX_FIRST    = -225,
    NF_IP_PRI_CONNTRACK        = -200,   // conntrack 在过滤前
    NF_IP_PRI_MANGLE           = -150,
    NF_IP_PRI_NAT_DST          = -100,   // DNAT
    NF_IP_PRI_FILTER           =    0,   // 主过滤规则
    NF_IP_PRI_SECURITY         =   50,
    NF_IP_PRI_NAT_SRC          =  100,   // SNAT
    NF_IP_PRI_SELINUX_LAST     =  225,
    NF_IP_PRI_CONNTRACK_HELPER =  300,
    NF_IP_PRI_LAST             = INT_MAX,
};
```

### 6.2 PRE_ROUTING 钩子执行顺序

```
PRE_ROUTING hook 链（按优先级升序）：
  -400  conntrack defrag     (ip_defrag)
  -300  raw table            (iptables raw)
  -200  conntrack            (nf_conntrack_ipv4_in)
  -150  mangle table         (iptables mangle)
  -100  nat DNAT             (iptables nat DNAT)
     0  filter               (iptables filter — 不在 PRE_ROUTING，只在 INPUT/FORWARD/OUTPUT)
```

---

## 7. 多协议族支持

Netfilter 不仅支持 IPv4，还支持多个协议族：

```c
// include/uapi/linux/netfilter.h
#define NFPROTO_UNSPEC       0
#define NFPROTO_INET         1  // IPv4+IPv6 共用 (新特性)
#define NFPROTO_IPV4         2
#define NFPROTO_ARP          3
#define NFPROTO_NETDEV       5  // 网卡级别 (ingress/egress)
#define NFPROTO_BRIDGE       7  // 桥接层
#define NFPROTO_IPV6        10
#define NFPROTO_DECNET      12
```

### 7.1 NFPROTO_NETDEV 钩子（内核 4.2+）

```c
// NFPROTO_NETDEV 钩子点
enum nf_dev_hooks {
    NF_NETDEV_INGRESS,   // 网卡入口（在 RX softirq，早于 IP 层）
    NF_NETDEV_EGRESS,    // 网卡出口（内核 5.16+）
    NF_NETDEV_NUMHOOKS
};
```

NETDEV_INGRESS 在 XDP 之后、TC 之前执行，可用于极早期的丢包/过滤：

```
硬件收包
  → XDP (eBPF)
  → nf_ingress (NFPROTO_NETDEV/NF_NETDEV_INGRESS)
  → tc ingress (cls_bpf/cls_flower)
  → netif_receive_skb → ip_rcv
  → NF_INET_PRE_ROUTING
```

---

## 8. 网络命名空间支持

每个 network namespace 拥有独立的 Netfilter 钩子链表：

```c
// include/net/netns/netfilter.h
struct netns_nf {
    // 每个协议族/钩子点的 hook_entries 数组
    struct nf_hook_entries __rcu *hooks_ipv4[NF_INET_NUMHOOKS];
    struct nf_hook_entries __rcu *hooks_ipv6[NF_INET_NUMHOOKS];
    struct nf_hook_entries __rcu *hooks_arp[NF_ARP_NUMHOOKS];
    struct nf_hook_entries __rcu *hooks_bridge[NF_BR_NUMHOOKS];
    struct nf_hook_entries __rcu *hooks_netdev[NF_NETDEV_NUMHOOKS];
    // ...
};
```

iptables/nftables 的规则也是按 netns 隔离的，容器（Docker/Kubernetes pod）内的防火墙规则不影响宿主机。

---

## 9. 用户态队列（NFQUEUE）

Netfilter 支持将数据包交给用户空间程序判决：

```c
// 内核钩子返回 NF_QUEUE 时触发
// 用户态通过 libnetfilter_queue 接收并判决

// 用户态示例（libnetfilter_queue）
#include <libnetfilter_queue/libnetfilter_queue.h>

static int cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
              struct nfq_data *nfa, void *data)
{
    uint32_t id;
    struct nfqnl_msg_packet_hdr *ph = nfq_get_msg_packet_hdr(nfa);
    id = ntohl(ph->packet_id);

    // 分析包内容...
    unsigned char *payload;
    int len = nfq_get_payload(nfa, &payload);

    // 判决：接受或丢弃
    return nfq_set_verdict(qh, id, NF_ACCEPT, 0, NULL);
}

// iptables 规则将包送入 queue 0
// iptables -I INPUT -p tcp --dport 80 -j NFQUEUE --queue-num 0
```

---

## 10. Netfilter 与 eBPF 的关系

```
传统 Netfilter 路径：
  NF_HOOK → nf_hook_slow → iptables/nftables rules → verdict

eBPF 路径（绕过 Netfilter）：
  XDP hook → BPF program → XDP_PASS/XDP_DROP/XDP_REDIRECT
  TC hook  → cls_bpf → BPF program → TC_ACT_OK/TC_ACT_SHOT

两者协同（bpf_skb_change_type + nf_conntrack）：
  XDP 快速丢弃 DDoS 攻击包
  Netfilter 处理需要状态跟踪的连接
```

性能对比（10GbE 转发，单核）：

| 框架 | 包转发速率 | 延迟 |
|------|-----------|------|
| iptables (规则 1000 条) | ~1.2 Mpps | ~800ns |
| nftables (等效规则) | ~2.1 Mpps | ~470ns |
| XDP (eBPF) | ~14 Mpps | ~70ns |

---

## 11. 调试与观测

```bash
# 查看 netfilter 钩子注册情况（通过 /proc）
cat /proc/net/ip_tables_names    # 已注册的 iptables 表
cat /proc/net/nf_conntrack       # conntrack 表
cat /proc/net/nf_conntrack_stat  # conntrack 统计

# 使用 nftrace 追踪包处理（需 nftables）
nft add rule ip filter INPUT meta nftrace set 1
nft monitor trace

# perf 追踪 Netfilter 内部函数
perf probe --add nf_hook_slow
perf record -e probe:nf_hook_slow -ag -- sleep 5
perf script

# 使用 bpftrace 追踪
bpftrace -e 'kprobe:nf_hook_slow { @[kstack] = count(); }'
```

---

## 12. 小结

Netfilter 是 Linux 网络安全与策略处理的核心基础设施：

- **5 个钩子点**覆盖数据包从进入到离开本机的完整路径
- **优先级机制**确保 conntrack/NAT/filter 按正确顺序执行
- **多协议族**支持从 L2（ARP/Bridge）到 L3（IPv4/IPv6）再到网卡级（NETDEV）
- **网络命名空间**隔离使容器化部署安全可靠
- **NF_QUEUE** 桥接内核与用户空间，支持复杂的应用层过滤
- eBPF/XDP 作为 Netfilter 的高性能补充，二者各有适用场景

下一章将深入 **iptables 扩展模块**——conntrack match、string match、u32 match 等高级匹配器的实现原理。
