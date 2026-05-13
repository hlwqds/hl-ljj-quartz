---
title: "Kernel Protocol Stack 深度探索 (三十四)：iptables 扩展模块"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    iptables,
    netfilter,
    conntrack-match,
    string-match,
    u32-match,
    ipset,
    hashlimit,
    recent,
  ]
description: "深入解析 iptables 扩展模块体系——match/target 扩展架构、conntrack 扩展、string/layer7 匹配、hashlimit 限速、recent 模块、ipset 集合匹配，以及编写自定义 iptables 扩展的完整流程"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-kernel-protocol-stack-deep-dive-ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[2026-04-13-kernel-protocol-stack-deep-dive-ch14-iptables|第十四章：iptables 基础]]
> 3. [[2026-04-13-kernel-protocol-stack-deep-dive-ch15-conntrack|第十五章：连接跟踪 Conntrack]]
> 4. [[2026-04-13-kernel-protocol-stack-deep-dive-ch16-nat|第十六章：NAT 与地址转换]]
> 5. [[2026-04-13-kernel-protocol-stack-deep-dive-ch32-unix-socket|第三十二章：Unix Domain Socket]]
> 6. [[2026-04-13-kernel-protocol-stack-deep-dive-ch33-netfilter-hook|第三十三章：Netfilter 框架详解]]
> 7. **第三十四章：iptables 扩展模块**

---

## 1. iptables 扩展架构概述

iptables 采用插件化设计，核心功能之外的所有匹配和动作均通过**扩展模块（extension）**实现。扩展分两类：

| 类型            | 作用                 | 示例                                    |
| --------------- | -------------------- | --------------------------------------- |
| **Match 扩展**  | 匹配数据包的某个属性 | conntrack, string, multiport, hashlimit |
| **Target 扩展** | 对匹配的包执行动作   | DNAT, SNAT, LOG, REJECT, MARK, TEE      |

### 1.1 内核侧扩展接口

```c
// include/linux/netfilter/x_tables.h

// Match 扩展
struct xt_match {
    struct list_head list;
    const char       name[XT_EXTENSION_MAXNAMELEN];  // 扩展名
    u_int8_t         revision;       // 版本号
    bool (*match)(const struct sk_buff *skb,
                  struct xt_action_param *);   // 匹配函数
    int  (*checkentry)(const struct xt_mtchk_param *);  // 规则加载时检查
    void (*destroy)(const struct xt_mtdtor_param *);    // 规则卸载时清理
    struct module *me;
    const char    *table;            // 限制适用的 table (可为 NULL)
    unsigned int  matchsize;         // match info 结构体大小
    unsigned int  usersize;          // 用户空间看到的大小
    unsigned int  hooks;             // 适用的 hook 掩码
    unsigned short proto;            // 协议 (0=any)
    u_int8_t      family;            // 协议族
};

// Target 扩展
struct xt_target {
    struct list_head list;
    const char       name[XT_EXTENSION_MAXNAMELEN];
    u_int8_t         revision;
    unsigned int (*target)(struct sk_buff *skb,
                           const struct xt_action_param *);  // 执行函数
    int  (*checkentry)(const struct xt_tgchk_param *);
    void (*destroy)(const struct xt_tgdtor_param *);
    struct module *me;
    const char    *table;
    unsigned int  targetsize;
    unsigned int  usersize;
    unsigned int  hooks;
    unsigned short proto;
    u_int8_t      family;
};
```

### 1.2 用户空间侧扩展接口（libxtables）

```c
// xtables-addons/libxt_EXAMPLE.c
static void EXAMPLE_help(void) { ... }
static void EXAMPLE_parse(struct xt_option_call *cb) { ... }
static void EXAMPLE_print(const void *ip, const struct xt_entry_match *match, int numeric) { ... }
static void EXAMPLE_save(const void *ip, const struct xt_entry_match *match) { ... }

static struct xtables_match EXAMPLE_match = {
    .name       = "EXAMPLE",
    .revision   = 0,
    .family     = NFPROTO_IPV4,
    .size       = XT_ALIGN(sizeof(struct xt_example_info)),
    .userspacesize = XT_ALIGN(sizeof(struct xt_example_info)),
    .help       = EXAMPLE_help,
    .x6_parse   = EXAMPLE_parse,
    .print      = EXAMPLE_print,
    .save       = EXAMPLE_save,
    .x6_options = EXAMPLE_opts,
};

void _init(void) { xtables_register_match(&EXAMPLE_match); }
```

---

## 2. conntrack Match 扩展

conntrack match 是最常用的扩展之一，允许根据连接状态匹配数据包。

### 2.1 状态匹配

```bash
# 允许已建立/相关连接
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 丢弃无效状态包（防止 TCP 扫描）
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 匹配新连接
iptables -A INPUT -m conntrack --ctstate NEW -p tcp --dport 80 -j ACCEPT
```

### 2.2 conntrack match 支持的字段

```bash
# 匹配原始源地址（NAT 前）
iptables -A FORWARD -m conntrack --ctorigdst 192.168.1.100 -j LOG

# 匹配回复源地址
iptables -A FORWARD -m conntrack --ctreplsrc 10.0.0.1 -j DROP

# 匹配连接标记（ct mark）
iptables -A FORWARD -m conntrack --ctmark 0x100/0x100 -j ACCEPT

# 匹配连接所属协议
iptables -A INPUT -m conntrack --ctproto tcp -j ACCEPT

# 匹配连接方向
iptables -A FORWARD -m conntrack --ctdir ORIGINAL -j LOG
```

### 2.3 内核实现

```c
// net/netfilter/xt_conntrack.c
static bool conntrack_mt(const struct sk_buff *skb,
                          struct xt_action_param *par)
{
    const struct xt_conntrack_mtinfo3 *info = par->matchinfo;
    enum ip_conntrack_info ctinfo;
    struct nf_conn *ct;
    bool inv = false;

    ct = nf_ct_get(skb, &ctinfo);
    if (ct == NULL)
        return info->match_flags & XT_CONNTRACK_STATE ?
               !!(info->state_mask & XT_CONNTRACK_STATE_INVALID) : false;

    // 检查连接状态
    if (info->match_flags & XT_CONNTRACK_STATE) {
        unsigned int statebit = (1 << ctinfo);
        if (ct->status & IPS_CONFIRMED)
            statebit |= XT_CONNTRACK_STATE_BIT(IP_CT_IS_REPLY);
        if (!((info->state_mask ^ inv) & statebit))
            return false;
    }
    // ... 其他字段匹配
    return true;
}
```

---

## 3. multiport Match 扩展

允许在单条规则中匹配多个端口（最多 15 个端口或端口范围）：

```bash
# 匹配多个目标端口
iptables -A INPUT -p tcp -m multiport --dports 22,80,443,8080 -j ACCEPT

# 匹配端口范围
iptables -A INPUT -p tcp -m multiport --dports 1024:65535 -j ACCEPT

# 源/目标端口同时匹配
iptables -A FORWARD -p tcp -m multiport --ports 80,443 -j ACCEPT
```

### 3.1 性能优化：ipset vs multiport

当需要匹配大量 IP/端口时，multiport（线性扫描）性能差，推荐使用 ipset：

```bash
# 创建 IP 集合
ipset create myset hash:ip hashsize 4096

# 批量添加 IP
ipset add myset 192.168.1.1
ipset add myset 10.0.0.0/8

# iptables 使用 ipset 匹配（O(1) 哈希查找）
iptables -A INPUT -m set --match-set myset src -j DROP
```

---

## 4. string Match 扩展

在数据包载荷中搜索字符串模式：

```bash
# 丢弃包含特定字符串的包（HTTP 层过滤）
iptables -A FORWARD -m string --string "BitTorrent" --algo bm -j DROP
iptables -A FORWARD -m string --string "attack_pattern" --algo kmp --from 0 --to 200 -j DROP
```

### 4.1 两种搜索算法

- **bm**（Boyer-Moore）：适合长模式串，预处理快
- **kmp**（Knuth-Morris-Pratt）：适合短模式串，无误报

### 4.2 局限性

string match 仅检查单个 skb 数据段，对于跨越 skb 分片的字符串无法匹配。生产环境推荐使用 Snort/Suricata 等专业 IDPS 系统。

---

## 5. hashlimit Match 扩展

基于令牌桶算法对流量进行限速，支持按 IP、端口维度限速：

```bash
# 限制每个源 IP 的 SYN 包速率：每秒最多 10 个新连接
iptables -A INPUT -p tcp --syn \
    -m hashlimit \
    --hashlimit-name synflood \
    --hashlimit-above 10/sec \
    --hashlimit-burst 20 \
    --hashlimit-mode srcip \
    -j DROP

# 限制每个源 IP+目标端口组合的连接速率
iptables -A INPUT -p tcp \
    -m hashlimit \
    --hashlimit-name http_limit \
    --hashlimit-upto 100/min \
    --hashlimit-burst 50 \
    --hashlimit-mode srcip,dstport \
    --hashlimit-htable-expire 60000 \
    -j ACCEPT
```

### 5.1 内核实现（令牌桶）

```c
// net/netfilter/xt_hashlimit.c
struct dsthash_ent {
    struct hlist_node node;
    struct {
        __be32 src, dst;
        __u16  src_port, dst_port;
        __u8   proto;
    } dst;
    spinlock_t lock;
    // 令牌桶状态
    unsigned long expires;   // 桶过期时间
    struct {
        unsigned long prev;  // 上次更新时间
        u_int32_t credit;    // 当前令牌数
        u_int32_t credit_cap;// 最大令牌数 (burst)
        u_int32_t cost;      // 每包消耗令牌数
    } rateinfo;
};
```

---

## 6. recent Match 扩展

维护一个 IP 地址的最近访问记录，实现基于时间窗口的连接数限制（防暴力破解）：

```bash
# SSH 防暴力破解：60 秒内超过 3 次新连接则拒绝
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --name SSH_BRUTE --update --seconds 60 --hitcount 4 \
    -j DROP

iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -m recent --name SSH_BRUTE --set -j ACCEPT
```

### 6.1 查看 recent 表

```bash
# 查看记录
cat /proc/net/xt_recent/SSH_BRUTE

# 手动清除某个 IP 的记录
echo -192.168.1.100 > /proc/net/xt_recent/SSH_BRUTE
```

---

## 7. MARK / CONNMARK Target

数据包标记用于在多个 iptables 规则间传递信息，或与 tc/routing 协作：

```bash
# 标记来自特定子网的数据包
iptables -t mangle -A PREROUTING -s 10.0.1.0/24 -j MARK --set-mark 0x10

# 将包标记保存到连接标记
iptables -t mangle -A PREROUTING -j CONNMARK --save-mark

# 从连接标记恢复包标记
iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark

# 根据标记进行路由（需配合 ip rule）
ip rule add fwmark 0x10 table 100
ip route add default via 192.168.2.1 table 100
```

---

## 8. LOG / NFLOG Target

```bash
# 经典 LOG（输出到 syslog/dmesg）
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
    -j LOG --log-prefix "SSH-NEW: " --log-level 4 --log-ip-options --log-tcp-options

# NFLOG（通过 netlink 发送到用户态，更高效）
iptables -A FORWARD -j NFLOG --nflog-group 100 --nflog-prefix "FWD: " --nflog-threshold 10

# 用户态接收
ulogd2 # 守护进程，可写入数据库/文件
```

---

## 9. REJECT Target

比 DROP 更友好，向发送方返回 ICMP 错误：

```bash
# 返回 ICMP port-unreachable（UDP 默认）
iptables -A INPUT -p udp --dport 1234 -j REJECT --reject-with icmp-port-unreachable

# 返回 TCP reset（TCP 推荐，快速通知客户端）
iptables -A INPUT -p tcp --dport 8080 -j REJECT --reject-with tcp-reset

# 返回 ICMP admin-prohibited
iptables -A FORWARD -j REJECT --reject-with icmp-admin-prohibited
```

---

## 10. TEE Target（包镜像）

将数据包复制一份发送到指定网关，用于流量镜像/监控：

```bash
# 将所有进入 eth0 的包镜像到监控主机 192.168.99.1
iptables -t mangle -A PREROUTING -i eth0 -j TEE --gateway 192.168.99.1
```

---

## 11. 编写自定义 iptables Match 扩展

### 11.1 内核模块（xt_mymatch.c）

```c
#include <linux/module.h>
#include <linux/netfilter/x_tables.h>
#include "xt_mymatch.h"  // 自定义 info 结构

struct xt_mymatch_info {
    __u32 flags;
    __u32 value;
};

static bool mymatch_mt(const struct sk_buff *skb,
                        struct xt_action_param *par)
{
    const struct xt_mymatch_info *info = par->matchinfo;
    // 实现匹配逻辑...
    return (skb->mark & info->flags) == info->value;
}

static int mymatch_mt_check(const struct xt_mtchk_param *par)
{
    // 规则加载时的参数校验
    return 0;
}

static struct xt_match mymatch_match = {
    .name       = "mymatch",
    .revision   = 0,
    .family     = NFPROTO_IPV4,
    .matchsize  = sizeof(struct xt_mymatch_info),
    .match      = mymatch_mt,
    .checkentry = mymatch_mt_check,
    .me         = THIS_MODULE,
};

static int __init mymatch_init(void)
{
    return xt_register_match(&mymatch_match);
}

static void __exit mymatch_exit(void)
{
    xt_unregister_match(&mymatch_match);
}

module_init(mymatch_init);
module_exit(mymatch_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("xt_mymatch: custom match example");
```

### 11.2 Makefile

```makefile
obj-m := xt_mymatch.o
KDIR := /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	cp libxt_mymatch.so /usr/lib/xtables/
```

---

## 12. iptables 规则性能优化

### 12.1 规则顺序优化

```bash
# 高频流量规则放前面
iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 使用链跳转减少规则数量
iptables -N SERVICES
iptables -A INPUT -p tcp -j SERVICES
iptables -A SERVICES -p tcp --dport 22 -j ACCEPT
iptables -A SERVICES -p tcp --dport 80 -j ACCEPT
```

### 12.2 ipset 替代多条规则

```bash
# 不好的做法（线性扫描 1000 条规则）
# iptables -A INPUT -s 1.2.3.1 -j DROP
# iptables -A INPUT -s 1.2.3.2 -j DROP
# ... 重复 1000 次

# 正确做法（O(1) 哈希查找）
ipset create blacklist hash:ip maxelem 65536
ipset add blacklist 1.2.3.1
ipset add blacklist 1.2.3.2
# ...
iptables -A INPUT -m set --match-set blacklist src -j DROP
```

### 12.3 迁移到 nftables

iptables 存在线性规则扫描、无原子批量更新等缺陷。生产环境推荐迁移至 nftables（下一章详解）：

```bash
# 将现有 iptables 规则转换为 nftables 格式
iptables-save | iptables-restore-translate
# 或整个表转换
iptables-translate -A INPUT -p tcp --dport 22 -j ACCEPT
# 输出：nft add rule ip filter INPUT tcp dport 22 accept
```

---

## 13. 小结

iptables 扩展模块体系通过 match/target 插件化设计，在不修改核心代码的前提下实现了丰富的防火墙功能：

- **conntrack match** 实现有状态防火墙，是现代防火墙规则的基础
- **hashlimit/recent** 提供速率限制和防暴力破解能力
- **ipset** 用 O(1) 哈希查找替代线性规则扫描
- **MARK/CONNMARK** 在防火墙、路由、QoS 之间传递元数据
- **NFQUEUE** 将判决委托给用户空间（IDS/IPS 系统的实现基础）

下一章将介绍 nftables——一个从零设计的下一代防火墙框架，解决了 iptables 的架构局限。
