---
title: "VPP 深入探讨 ch06：L2 转发与 Bridge Domain"
date: 2026-04-09 21:00:00
tags: [vpp, l2, bridge-domain, mac-learning, vlan, vxlan, stp, forwarding]
description: "深入解析 VPP L2 转发：Bridge Domain、MAC 学习与老化、VLAN、VXLAN 隧道、STP 与 L2 FIB"
---

# VPP 深入探讨 ch06：L2 转发与 Bridge Domain

> [!abstract] 核心要点
> VPP 的 L2 转发基于 Bridge Domain (BD) 模型。本章深入解析 BD 架构、MAC 学习与老化机制、VLAN 处理、VXLAN 隧道封装以及 L2 FIB 表设计。

## 1. L2 转发概述

### 1.1 L2 vs L3 转发

```
L2 转发 (Bridge)：
  基于 MAC 地址
  同一广播域内转发
  学习源 MAC，泛洪未知目的

L3 转发 (Router)：
  基于 IP 地址
  不同网络间路由
  使用路由表查找

┌─────────────────────────────────────────────────────────────┐
│                    VPP L2 转发模型                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   Bridge Domain                        │  │
│  │  ┌──────────────────────────────────────────────┐    │  │
│  │  │  Port 1 (eth0)     Port 2 (eth1)   Port 3   │    │  │
│  │  │    [MAC-A]           [MAC-B]       [MAC-C]   │    │  │
│  │  │                                              │    │  │
│  │  │  L2 FIB (MAC Table)                         │    │  │
│  │  │  MAC-A → Port 1                             │    │  │
│  │  │  MAC-B → Port 2                             │    │  │
│  │  │  MAC-C → Port 3                             │    │  │
│  │  └──────────────────────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 VPP L2 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP L2 组件                              │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │  Bridge     │  │    L2       │  │    VLAN     │       │
│  │  Domain     │  │    FIB      │  │   (802.1Q)  │       │
│  │             │  │  (MAC Table)│  │             │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   L2TPv3    │  │   VXLAN     │  │    STP      │       │
│  │   Tunnel    │  │   Tunnel    │  │  (Spanning) │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

## 2. Bridge Domain 架构

### 2.1 Bridge Domain 结构

```c
// Bridge Domain 定义
typedef struct {
    // BD ID
    u32 bd_id;

    // L2 FIB 表
    u32 l2fib_hash;
    u32 *l2fib;

    // 接口列表
    u32 *sw_if_indices;

    // flooding 启用
    int uu_flood;

    // Unknown Unicast Flood
    int uf_flood;

    // Broadcast Flood
    int.bc_flood;

    // MAC 学习
    int learn;

    // MAC 年龄
    u32 mac_age;

    // STP 状态
    u8 *stp_state;  // per port
} bridge_domain_t;

// Bridge Domain 表
struct l2_bridge_domain_main_t {
    bridge_domain_t *bridge_domains;
    u32 num_bridge_domains;

    // 统计
    u64 learn_count;
    u64 forward_count;
    u64 flood_count;
};
```

### 2.2 添加接口到 Bridge Domain

```bash
# CLI 配置 Bridge Domain
vpp# bridge-domain create bd_id 10

# 添加接口
vpp# set interface l2 bridge GigabitEthernet0/8/0 bd_id 10
vpp# set interface l2 bridge GigabitEthernet0/8/1 bd_id 10

# 查看 Bridge Domain
vpp# show bridge-domain 10

# 示例输出：
# Bridge-domain 10 (2 ports)
#   Ports:
#     GigabitEthernet0/8/0 (enabled)
#     GigabitEthernet0/8/1 (enabled)
#   MAC learning: enabled
#   Unknown unicast flood: enabled
#   Broadcast flood: enabled
```

### 2.3 Bridge Domain 转发流程

```c
// L2 Input node (处理进入 Bridge Domain 的包)
VLIB_NODE_FN(l2_input_node)
{
    vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);
    ethernet_header_t *eth = vlib_buffer_get_current(b);

    // 获取 BD
    u32 bd_id = sw_if_index_to_bd(sw_if_index);
    bridge_domain_t *bd = &bridge_domains[bd_id];

    // 学习源 MAC
    if (bd->learn) {
        l2fib_learn(bd_id, eth->src_address, sw_if_index);
    }

    // 查找目的 MAC
    l2fib_entry_t *entry = l2fib_lookup(bd, eth->dst_address);

    if (entry) {
        // 已知单播 → 转发到对应端口
        u32 dst_sw_if = entry->sw_if_index;
        vlib_put_next_frame(vm, node, L2_NEXT_OUTPUT, dst_sw_if);
    } else {
        // 未知 → 泛洪
        if (is_broadcast(eth->dst_address) ||
            is_multicast(eth->dst_address)) {
            // 广播/组播
            vlib_put_next_frame(vm, node, L2_NEXT_FLOOD, ...);
        } else {
            // 未知单播
            if (bd->uu_flood) {
                vlib_put_next_frame(vm, node, L2_NEXT_FLOOD, ...);
            } else {
                // 丢弃
                vlib_buffer_free(vm, &bi, 1);
            }
        }
    }
}
```

## 3. L2 FIB (MAC Table)

### 3.1 MAC 学习

```c
// L2 FIB 条目
typedef struct {
    u8 mac[6];               // MAC 地址
    u32 bd_id;              // Bridge Domain ID
    u32 sw_if_index;        // 关联的接口
    u32 timestamp;          // 学习时间
    u8 static_entry;        // 静态条目
    u8 filtered;            // 是否过滤
} l2fib_entry_t;

// MAC 学习函数
static void
l2fib_learn(u32 bd_id, u8 *mac, u32 sw_if_index)
{
    // 计算 MAC 的 hash
    u32 hash = mac_hash(mac, bd_id);

    // 查找现有条目
    l2fib_entry_t *entry = l2fib_lookup(bd_id, mac);

    if (entry) {
        // 已存在 → 更新
        entry->sw_if_index = sw_if_index;
        entry->timestamp = vlib_time_now(vm);
    } else {
        // 新条目 → 添加
        entry = l2fib_add(bd_id, mac, sw_if_index);
        entry->timestamp = vlib_time_now(vm);

        // 检查是否超出容量
        if (l2fib_size > L2FIB_MAX_ENTRIES) {
            // 删除最老的条目
            l2fib_evict_oldest(bd_id);
        }
    }
}
```

### 3.2 MAC 老化

```c
// MAC 老化机制
static void
l2fib_age(bridge_domain_t *bd)
{
    u32 now = vlib_time_now(vm);

    // 遍历 L2 FIB
    for (int i = 0; i < vec_len(bd->l2fib); i++) {
        l2fib_entry_t *entry = &bd->l2fib[i];

        // 跳过静态条目
        if (entry->static_entry) continue;

        // 检查年龄
        u32 age = now - entry->timestamp;

        if (age > bd->mac_age) {
            // 删除老化条目
            l2fib_delete(entry);
        }
    }
}

// 老化线程（定期运行）
static void *
l2fib_age_thread(void *arg)
{
    vlib_main_t *vm = arg;

    while (1) {
        // 每秒检查一次
        sleep(1);

        // 对所有 BD 进行老化
        for (int i = 0; i < num_bridge_domains; i++) {
            if (bridge_domains[i].mac_age > 0) {
                l2fib_age(&bridge_domains[i]);
            }
        }
    }
}
```

### 3.3 MAC 查找

```c
// L2 FIB 查找（基于 hash）
static inline l2fib_entry_t *
l2fib_lookup(u32 bd_id, u8 *mac)
{
    bridge_domain_t *bd = get_bridge_domain(bd_id);

    // 计算 hash
    u32 hash = mac_hash(mac, bd_id);

    // hash 链查找
    l2fib_entry_t *entry = bd->hash_table[hash];

    while (entry) {
        if (memcmp(entry->mac, mac, 6) == 0 &&
            entry->bd_id == bd_id) {
            return entry;
        }
        entry = entry->next_in_hash;
    }

    return NULL;  // 未找到
}

// 批量 MAC 查找优化
static inline void
l2fib_lookup_batch(bridge_domain_t *bd,
                   u8 **macs, u32 n,
                   l2fib_entry_t **results)
{
    for (u32 i = 0; i < n; i++) {
        results[i] = l2fib_lookup(bd_id, macs[i]);
    }
}
```

### 3.4 静态 MAC 条目

```bash
# 添加静态 MAC 条目
vpp# l2fib add bd_id 10 mac aa:bb:cc:dd:ee:ff interface GigabitEthernet0/8/0

# 添加过滤 MAC
vpp# l2fib add bd_id 10 mac aa:bb:cc:dd:ee:ff filter

# 查看 L2 FIB
vpp# show l2fib

# 示例输出：
# BD   MAC Address        Interface              Age   static
# 10   aa:bb:cc:dd:ee:00  GigabitEthernet0/8/0   0    yes
# 10   aa:bb:cc:dd:ee:01  GigabitEthernet0/8/1   120  no
# 10   ff:ff:ff:ff:ff:ff  Flood                   -    -
```

## 4. VLAN 处理

### 4.1 VLAN 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP VLAN 处理                           │
│                                                              │
│  802.1Q VLAN Tag 格式：                                      │
│  ┌─────────┬─────────┬─────────┬─────────────────────────┐  │
│  │  DA(6)  │  SA(6)  │  TPID   │ TCI │  EtherType      │  │
│  │         │         │ (2)    │(2)  │  (2)              │  │
│  └─────────┴─────────┴─────────┴─────┴──────────────────┘  │
│                               │                             │
│                TPID = 0x8100 (VLAN Tag)                   │
│                TCI = PCP(3) + DEI(1) + VID(12)             │
└─────────────────────────────────────────────────────────────┘

VLAN 模式：
  - ACCESS: 移除 VLAN tag
  - TRUNK: 透传 VLAN tag
  - DOT1Q: 单 VLAN (sub-interface)
```

### 4.2 VLAN 配置

```bash
# 创建 VLAN sub-interface
vpp# create sub GigabitEthernet0/8/0.100
vpp# set interface l2 bridge GigabitEthernet0/8/0.100 bd_id 10

# 配置 TRUNK
vpp# set interface l2 trunk GigabitEthernet0/8/0
vpp# set interface l2 trunk GigabitEthernet0/8/0 allow bd_id 10,20,30

# 配置 VLAN 过滤
vpp# bridge-domain set bd_id 10 input filter enable

# 查看 VLAN
vpp# show vlan
```

### 4.3 VLAN 标签处理

```c
// VLAN 标签剥离
static_always_inline void
vlan_untag(vlib_buffer_t *b)
{
    ethernet_vlan_header_t *vlan =
        (ethernet_vlan_header_t *)vlib_buffer_get_current(b);

    // VLAN 标签的位置
    u16 vlan_id = vlan->type_clib & 0xFFF;

    // 移动数据指针，移除 VLAN
    vlib_buffer_advance(b, sizeof(ethernet_vlan_header_t));

    // 更新 Ethernet 类型
    ethernet_header_t *eth = vlib_buffer_get_current(b);
    eth->type = vlan->type;  // 内层 EtherType
}

// VLAN 标签添加
static_always_inline void
vlan_tag(vlib_buffer_t *b, u16 vlan_id)
{
    // 预留 VLAN 头空间
    vlib_buffer_advance(b, -sizeof(ethernet_vlan_header_t));

    ethernet_header_t *eth = vlib_buffer_get_current(b);
    ethernet_vlan_header_t *vlan =
        (ethernet_vlan_header_t *)(eth + 1);

    // 设置 VLAN
    vlan->type_clib = vlan_id & 0xFFF;
    vlan->type = eth->type;
    eth->type = 0x8100;  // VLAN TPID
}
```

## 5. VXLAN 隧道

### 5.1 VXLAN 概述

```
VXLAN (Virtual Extensible LAN)：
- L2 over L3 隧道
- 24-bit VNI (Virtual Network Identifier)
- 支持 16M 虚拟网络

┌─────────────────────────────────────────────────────────────┐
│                    VXLAN 封装                              │
│                                                              │
│  Outer Header:                                              │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┐       │
│  │  Outer  │  Outer  │  Outer  │  VXLAN  │  Inner  │     │
│  │   MAC   │   IP    │   UDP   │  Header  │ Packet  │     │
│  │  (14)  │  (20)   │   (8)   │  (8)    │         │     │
│  └─────────┴─────────┴─────────┴─────────┴─────────┘       │
│                                                              │
│  VXLAN Header:                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Flags(8) | Reserved(24) | VNI(24) | Reserved(8)   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 VXLAN 配置

```bash
# 创建 VXLAN 隧道
vpp# create vxlan tunnel src 10.0.0.1 dst 10.0.0.2 vni 1000

# 将 VXLAN 接口加入 Bridge Domain
vpp# set interface l2 bridge vxlan_tunnel0 bd_id 10

# 查看 VXLAN
vpp# show vxlan
```

### 5.3 VXLAN 封装/解封装

```c
// VXLAN 解封装 (receive path)
VLIB_NODE_FN(vxlan_input_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);

        // 获取 UDP 头
        udp_header_t *udp = get_udp(b);

        // 获取 VXLAN 头
        vxlan_header_t *vx = (vxlan_header_t *)(udp + 1);

        // 提取 VNI
        u32 vni = (vx->vx_vni[2] << 16) |
                  (vx->vx_vni[1] << 8) |
                  vx->vx_vni[0];

        // 移除隧道头
        vlib_buffer_advance(b, sizeof(udp_header_t) +
                                 sizeof(vxlan_header_t));

        // 查找 VNI 对应的 BD
        u32 bd_id = vxlan_vni_to_bd(vni);

        // 发送到 BD
        vlib_put_next_frame(vm, node, VXLAN_NEXT_L2_INPUT, ...);
    }
}

// VXLAN 封装 (output path)
static_always_inline void
vxlan_encap(vlib_buffer_t *b,
            ip4_address_t *src_ip, ip4_address_t *dst_ip,
            u32 vni)
{
    // 预留头部空间
    vlib_buffer_advance(b, -sizeof(vxlan_header_t) -
                             sizeof(udp_header_t) -
                             sizeof(ip4_header_t) -
                             sizeof(ethernet_header_t));

    // 写入 Outer Ethernet
    ethernet_header_t *outer_eth = vlib_buffer_get_current(b);
    // ... 设置 src/dst MAC

    // 写入 Outer IP
    ip4_header_t *outer_ip = (ip4_header_t *)(outer_eth + 1);
    outer_ip->dst_address = *dst_ip;
    outer_ip->src_address = *src_ip;

    // 写入 UDP
    udp_header_t *udp = (udp_header_t *)(outer_ip + 1);
    udp->dst_port = VXLAN_PORT;  // 4789
    udp->src_port = ephemeral;

    // 写入 VXLAN
    vxlan_header_t *vx = (vxlan_header_t *)(udp + 1);
    vx->vx_flags = VXLAN_FLAGS;
    vx->vx_vni[0] = vni & 0xFF;
    vx->vx_vni[1] = (vni >> 8) & 0xFF;
    vx->vx_vni[2] = (vni >> 16) & 0xFF;
}
```

## 6. Spanning Tree Protocol (STP)

### 6.1 STP 概述

```
802.1D Spanning Tree：

- 防止 L2 环路
- 自动计算最优树
- 端口状态：Blocking → Listening → Learning → Forwarding

VPP 支持：
- STP (802.1D)
- RSTP (802.1D-2004)
- MSTP (802.1Q-2022)
```

### 6.2 STP 配置

```bash
# 在 Bridge Domain 上启用 STP
vpp# bridge-domain set bd_id 10 stp enable

# 设置端口 STP 成本
vpp# set interface l2 bridge GigabitEthernet0/8/0 bd_id 10 cost 100

# 设置端口优先级
vpp# set interface l2 bridge GigabitEthernet0/8/0 bd_id 10 priority 128

# 查看 STP 状态
vpp# show bridge-domain 10 stp
```

### 6.3 STP 端口状态

```c
// STP 端口状态
enum stp_state {
    STP_STATE_DISABLED = 0,
    STP_STATE_BLOCKING = 1,
    STP_STATE_LISTENING = 2,
    STP_STATE_LEARNING = 3,
    STP_STATE_FORWARDING = 4,
};

// L2 输入根据 STP 状态过滤
static_always_inline u32
l2_input_stp_filter(vlib_buffer_t *b, u32 sw_if_index)
{
    bridge_domain_t *bd = get_bd_for_interface(sw_if_index);
    u8 stp_state = bd->stp_state[sw_if_index];

    switch (stp_state) {
    case STP_STATE_BLOCKING:
    case STP_STATE_DISABLED:
        // 丢弃
        return L2_INPUT_DROP;

    case STP_STATE_LISTENING:
        // 只收 BPDU
        if (!is_bpdu(b)) {
            return L2_INPUT_DROP;
        }
        // fall through

    case STP_STATE_LEARNING:
        // 可以学习 MAC，但不能转发
        return L2_INPUT_LEARN_ONLY;

    case STP_STATE_FORWARDING:
        // 完全转发
        return L2_INPUT_FORWARD;
    }

    return L2_INPUT_FORWARD;
}
```

## 7. 性能优化

### 7.1 MAC Table 大小

```bash
# 配置 L2 FIB 表大小
# /etc/vpp/startup.conf
buffers {
    # L2 FIB 默认大小
    # l2-fib-size 8192
}
```

### 7.2 批量学习

```c
// 批量 MAC 学习（提高吞吐量）
static_always_inline void
l2fib_learn_batch(bridge_domain_t *bd,
                  u8 **macs, u32 *sw_if_indices,
                  u32 n)
{
    for (u32 i = 0; i < n; i++) {
        l2fib_learn(bd->bd_id, macs[i], sw_if_indices[i]);
    }
}
```

## 8. 总结

VPP L2 转发核心概念：

| 组件 | 功能 | 关键点 |
|------|------|--------|
| **Bridge Domain** | L2 广播域 | 隔离不同虚拟网络 |
| **L2 FIB** | MAC 表 | Hash 查找、学习、老化 |
| **VLAN** | 虚拟 LAN | Access/Trunk 模式 |
| **VXLAN** | L2 over L3 | 24-bit VNI |
| **STP** | 环路防止 | 802.1D/Q |

转发决策流程：

```
Incoming L2 Frame
        ↓
    学习源 MAC
        ↓
    查找目的 MAC
    /          \
   /            \
已知 Unicast   Unknown
    ↓              ↓
   转发          泛洪 (if enabled)
                  or 丢弃
```

---

## 参考资源

- [VPP L2 文档](https://wiki.fd.io/view/VPP/L2_Features)
- [VXLAN RFC 7348](https://tools.ietf.org/html/rfc7348)
- [802.1Q VLAN](https://ieee802.org/1/pages/802.1Q.html)
