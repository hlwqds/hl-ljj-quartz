---
title: "Kernel Protocol Stack 深度探索 (三十五)：nftables 新一代防火墙框架"
date: 2026-04-13
tags:
  [linux, kernel, networking, series, nftables, nft, set, map, flowtable, verdict-map, netfilter]
description: "深入解析 nftables——全新的内核防火墙框架，统一的表/链/规则模型、set/map 数据结构、flowtable 硬件卸载、verdict map、原子规则更新，以及与 iptables 的对比迁移指南"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]] 33. [[2026-04-13-kernel-protocol-stack-deep-dive-ch33-netfilter-hook|第三十三章：Netfilter 框架详解]] 34. [[2026-04-13-kernel-protocol-stack-deep-dive-ch34-iptables-ext|第三十四章：iptables 扩展模块]] 35. **第三十五章：nftables 新一代防火墙框架**

---

## 1. 为什么需要 nftables？

iptables 存在诸多架构缺陷：

| 问题         | iptables 现状                               | nftables 解决方案                        |
| ------------ | ------------------------------------------- | ---------------------------------------- |
| 规则原子更新 | iptables-restore 整表替换，非原子           | 批量事务（netlink batch）                |
| 规则扫描效率 | O(n) 线性扫描                               | set/map O(1) 哈希/O(log n) rbtree        |
| 多协议族     | 分散：iptables/ip6tables/arptables/ebtables | 统一：单一 nft 命令                      |
| 数据类型     | 无类型系统，字符串拼接                      | 强类型：ipv4_addr/inet_proto/tcp_port... |
| 动态更新集合 | 需要 ipset 外部工具                         | 原生 set/map 支持动态增删                |
| 性能         | iptables 规则越多越慢                       | flowtable 可绕过 Netfilter 快速转发      |

nftables 于 Linux 3.13 合并主线，内核 5.x+ 已基本完善。

---

## 2. 基本概念

### 2.1 层次结构

```
nftables 层次：
  table (表)
    └── chain (链)
          └── rule (规则)
                └── expression (表达式)

对比 iptables：
  table (filter/nat/mangle/raw)
    └── chain (INPUT/OUTPUT/FORWARD/PREROUTING/POSTROUTING)
          └── rule (match + target)
```

### 2.2 表（Table）

```bash
# nftables 中 table 只关联协议族，不关联 hook
nft add table ip   mytable       # IPv4
nft add table ip6  mytable6      # IPv6
nft add table inet mytable_dual  # IPv4 + IPv6 共用
nft add table arp  myarp_table   # ARP
nft add table bridge mybr_table  # Bridge

# 列出所有表
nft list tables
```

### 2.3 链（Chain）

```bash
# 基础链（base chain）：绑定到 Netfilter hook
nft add chain ip mytable INPUT \
    { type filter hook input priority 0 \; policy drop \; }

# 常规链（regular chain）：不绑定 hook，需被 jump/goto 调用
nft add chain ip mytable MY_SERVICES

# 链类型
# type filter  → 包过滤
# type nat     → NAT（PREROUTING/POSTROUTING）
# type route   → 路由策略（OUTPUT hook）
```

### 2.4 规则（Rule）

```bash
# 添加规则（语法：条件 + 动作）
nft add rule ip mytable INPUT \
    ip protocol tcp tcp dport 22 accept

# 在规则位置前插入
nft insert rule ip mytable INPUT \
    position 10 tcp dport 80 accept

# 删除规则（需要规则 handle）
nft list ruleset -a  # 显示 handle
nft delete rule ip mytable INPUT handle 5
```

---

## 3. 表达式系统

nftables 规则由**表达式（expression）**组成，表达式是强类型的：

```bash
# 常用表达式示例

# IP 地址匹配
nft add rule ip filter INPUT ip saddr 192.168.1.0/24 accept
nft add rule ip filter INPUT ip daddr 10.0.0.1 drop

# 传输层端口
nft add rule ip filter INPUT tcp dport { 22, 80, 443 } accept
nft add rule ip filter INPUT udp sport 53 accept

# 接口
nft add rule ip filter INPUT iifname "eth0" accept
nft add rule ip filter OUTPUT oifname "lo" accept

# conntrack 状态
nft add rule ip filter INPUT ct state { established, related } accept
nft add rule ip filter INPUT ct state invalid drop

# 包标记
nft add rule ip mangle PREROUTING meta mark set 0x100
nft add rule ip filter INPUT meta mark 0x100 accept

# 速率限制（令牌桶）
nft add rule ip filter INPUT \
    tcp dport 22 ct state new \
    limit rate 10/minute burst 5 packets accept

# 日志
nft add rule ip filter INPUT drop log prefix "DROPPED: " level warn
```

---

## 4. Set 与 Map

### 4.1 Named Set（命名集合）

```bash
# 创建 IP 集合（匿名）
nft add rule ip filter INPUT ip saddr { 1.2.3.4, 5.6.7.8 } drop

# 创建命名集合（可动态修改）
nft add set ip filter BLACKLIST { type ipv4_addr \; flags dynamic \; }

# 向集合添加元素
nft add element ip filter BLACKLIST { 1.2.3.4 }
nft add element ip filter BLACKLIST { 10.0.0.0/8 }

# 使用集合
nft add rule ip filter INPUT ip saddr @BLACKLIST drop

# 动态：连接超速时自动加入黑名单（meter + set）
nft add rule ip filter INPUT \
    ip saddr @WHITELIST accept
nft add rule ip filter INPUT \
    meter http_meter { ip saddr limit rate 100/second } \
    add @BLACKLIST { ip saddr timeout 60s }
```

### 4.2 Map（映射）

Map 允许根据键获取值，实现高效的规则分发：

```bash
# verdict map：根据目标端口跳转到不同链
nft add map ip filter PORT_DISPATCH {
    type inet_service : verdict \;
}
nft add element ip filter PORT_DISPATCH {
    22 : jump SSH_CHAIN,
    80 : jump HTTP_CHAIN,
    443 : jump HTTPS_CHAIN
}
nft add rule ip filter INPUT tcp dport vmap @PORT_DISPATCH

# nat map：根据源 IP 选择不同的出口 IP 做 SNAT
nft add map ip nat SNAT_MAP {
    type ipv4_addr : ipv4_addr \;
}
nft add element ip nat SNAT_MAP {
    192.168.1.0/24 : 203.0.113.1,
    192.168.2.0/24 : 203.0.113.2
}
nft add rule ip nat POSTROUTING \
    snat to ip saddr map @SNAT_MAP
```

### 4.3 Interval Set（区间集合）

```bash
# 端口区间集合
nft add set ip filter PRIVILEGED_PORTS {
    type inet_service \;
    flags interval \;
    elements = { 0-1023 }
}

# IP 地址区间
nft add set ip filter RFC1918 {
    type ipv4_addr \;
    flags interval \;
    elements = {
        10.0.0.0/8,
        172.16.0.0/12,
        192.168.0.0/16
    }
}
```

---

## 5. Flowtable（流表快速转发）

Flowtable 是 nftables 最重要的性能特性，允许绕过完整的 Netfilter 处理路径，直接在 L3/L4 层转发已建立的连接：

### 5.1 工作原理

```
常规路径（每包都经过 Netfilter）：
  RX → PRE_ROUTING hook → routing → FORWARD hook → POST_ROUTING hook → TX
  约 ~500ns/包

Flowtable 快速路径（已知连接直接转发）：
  RX → flowtable lookup → 直接转发 → TX
  约 ~100ns/包（跳过所有 Netfilter 规则）
```

### 5.2 配置示例

```bash
# 声明 flowtable，关联 ingress hook 和网卡
nft add flowtable ip mytable MY_FLOWTABLE {
    hook ingress priority -1 \;
    devices = { eth0, eth1 } \;
}

# 已建立的连接卸载到 flowtable
nft add rule ip mytable FORWARD \
    ct state established \
    flow add @MY_FLOWTABLE

# 效果：后续已建立连接的包绕过 iptables/nftables 规则直接转发
```

### 5.3 硬件 Flowtable Offload（内核 5.13+）

```bash
# 支持智能网卡硬件卸载
nft add flowtable ip mytable HW_FLOWTABLE {
    hook ingress priority -1 \;
    devices = { eth0 } \;
    flags offload \;  # 硬件卸载
}
```

---

## 6. 内核实现架构

### 6.1 nftables 内核模块结构

```
net/netfilter/
├── nf_tables_core.c     # 核心规则评估引擎
├── nf_tables_api.c      # netlink API（用户态交互）
├── nft_immediate.c      # ACCEPT/DROP/RETURN 等立即动作
├── nft_cmp.c            # 比较表达式
├── nft_lookup.c         # set 查找表达式
├── nft_dynset.c         # 动态 set 操作
├── nft_meta.c           # 元数据（iif/oif/mark/pkttype）
├── nft_ct.c             # conntrack 表达式
├── nft_nat.c            # NAT target
├── nft_limit.c          # 速率限制
├── nft_log.c            # 日志
├── nft_hash.c           # 哈希 set 实现
├── nft_rbtree.c         # rbtree set（区间/排序）
└── nft_pipapo.c         # 多维匹配（IP+端口元组）
```

### 6.2 规则评估虚拟机

nftables 规则被编译为**字节码**，由内核中的 nft 虚拟机执行：

```c
// include/net/netfilter/nf_tables.h
struct nft_regs {
    union {
        u32 data[NFT_REG32_NUM];  // 通用寄存器
        // ...
    };
};

// 表达式接口
struct nft_expr_ops {
    void (*eval)(const struct nft_expr *expr,
                 struct nft_regs *regs,
                 const struct nft_pktinfo *pkt);
    int  (*init)(const struct nft_ctx *ctx,
                 const struct nft_expr *expr,
                 const struct nlattr * const tb[]);
    void (*destroy)(const struct nft_ctx *ctx,
                    const struct nft_expr *expr);
    // ...
};
```

---

## 7. 原子批量更新

nftables 通过 netlink batch 支持原子规则更新，这是 iptables 不具备的关键特性：

```bash
# 方法一：nft -f 文件（整个文件作为一个事务）
cat > /etc/nftables.conf << 'EOF'
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        tcp dport { 22, 80, 443 } accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
nft -f /etc/nftables.conf  # 原子加载

# 方法二：使用 { } 块批量更新
nft -f - << 'EOF'
add element ip filter BLACKLIST { 1.2.3.4 }
add element ip filter BLACKLIST { 5.6.7.8 }
delete element ip filter BLACKLIST { 9.10.11.12 }
EOF
```

---

## 8. 与 iptables 的互操作性

```bash
# 兼容层：iptables-nft（使用 iptables 语法，但实际操作 nftables）
# 现代 Linux 发行版中 iptables 命令实际上是 iptables-nft 的符号链接

# 查看当前 iptables 后端
update-alternatives --list iptables

# iptables 规则翻译为 nftables
iptables-translate -A INPUT -p tcp --dport 80 -j ACCEPT
# 输出：nft add rule ip filter INPUT tcp dport 80 accept

# 整个规则集迁移
iptables-save | iptables-restore-translate -f /etc/nftables.conf
```

---

## 9. 调试与监控

```bash
# 监控 nftables 规则/集合变化事件
nft monitor

# 开启包追踪（nftrace）
nft add rule ip filter INPUT meta nftrace set 1
nft monitor trace

# 追踪输出示例：
# trace id 9a3f0001 ip filter INPUT packet: ... ip saddr 1.2.3.4 ...
# trace id 9a3f0001 ip filter INPUT rule tcp dport 22 accept (rule-handle 3)
# trace id 9a3f0001 ip filter INPUT verdict accept

# 查看规则集计数器
nft list ruleset
# 带 counter 关键字的规则会显示匹配包数和字节数
nft add rule ip filter INPUT counter tcp dport 80 accept
```

---

## 10. 完整示例：家庭路由器防火墙

```bash
#!/usr/sbin/nft -f
flush ruleset

define WAN_IF = "eth0"
define LAN_IF = "eth1"
define LAN_NET = 192.168.1.0/24

table inet firewall {
    # 黑名单集合（动态）
    set BLACKLIST {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1h
    }

    # 允许的服务端口
    set ALLOWED_PORTS {
        type inet_service
        elements = { 22, 80, 443 }
    }

    # Flowtable（已建立连接快速转发）
    flowtable ft {
        hook ingress priority -1
        devices = { eth0, eth1 }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept comment "loopback"
        ct state invalid drop comment "drop invalid"
        ct state { established, related } accept comment "allow established"

        # SSH 防暴力破解
        tcp dport 22 ct state new \
            limit rate 5/minute burst 10 packets accept

        # 黑名单
        ip saddr @BLACKLIST drop

        # 允许 LAN 访问服务
        iif $LAN_IF tcp dport @ALLOWED_PORTS accept

        # ICMP
        icmp type { echo-request, echo-reply } limit rate 10/second accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state invalid drop
        ct state { established, related } flow add @ft  # flowtable 加速
        ct state { established, related } accept

        # LAN -> WAN 允许
        iif $LAN_IF oif $WAN_IF accept

        # WAN -> LAN 仅允许已建立连接（由 established 规则处理）
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100;
        oif $WAN_IF masquerade
    }
}
```

---

## 11. 小结

nftables 是 iptables 的现代替代品，在架构和性能上均有显著改进：

- **统一框架**：一个工具取代 iptables/ip6tables/arptables/ebtables
- **set/map**：O(1) 哈希匹配，替代线性规则扫描
- **flowtable**：绕过完整 Netfilter 路径，已建立连接转发性能提升 5x+
- **原子更新**：netlink batch 事务，规则变更不影响正在处理的包
- **表达式 VM**：规则编译为字节码，评估高效且可扩展
- **强类型系统**：减少配置错误，提高可读性

下一章将深入 conntrack 的内部实现——哈希表结构、超时机制、连接回收、以及 conntrack 在大规模场景下的调优方法。
