---
title: "VPP 深入探讨 ch08：隧道封装技术"
date: 2026-04-09 22:00:00
tags: [vpp, tunnel, vxlan, nvgre, geneve, gre, ipip, tunnel-encapsulation]
description: "深入解析 VPP 隧道封装：VXLAN、NVGRE、GENEVE、GRE、IPIP、NVGRE/GENEVE 卸载与隧道端点"
---

# VPP 深入探讨 ch08：隧道封装技术

> [!abstract] 核心要点
> VPP 支持多种隧道封装技术，实现 L2/L3 over UDP over IP。本章深入解析 VXLAN、NVGRE、GENEVE、GRE、IPIP 的封装格式、配置与卸载。

## 1. 隧道封装概述

### 1.1 隧道类型

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP 隧道类型                             │
│                                                              │
│  L2 隧道：                                                    │
│  ├─ VXLAN      (L2 over UDP)                               │
│  ├─ NVGRE      (L2 over GRE)                               │
│  ├─ GENEVE     (L2 over UDP)                               │
│  └─ L2TPv3     (L2 over IP)                               │
│                                                              │
│  L3 隧道：                                                    │
│  ├─ GRE        (L3 over IP)                                │
│  ├─ IPIP       (IP over IP)                                │
│  ├─ SIT        (IPv6 over IPv4)                            │
│  └─ IPSec      (加密隧道)                                   │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 封装对比

| 隧道       | 外层协议 | VNI/Key    | 元数据   | UDP 端口 |
| ---------- | -------- | ---------- | -------- | -------- |
| **VXLAN**  | UDP      | 24-bit VNI | 无       | 4789     |
| **NVGRE**  | GRE      | 24-bit VNI | flow_id  | N/A      |
| **GENEVE** | UDP      | 24-bit VNI | 可变选项 | 6081     |
| **GRE**    | IP       | 32-bit key | 无       | N/A      |
| **IPIP**   | IP       | 无         | 无       | N/A      |

## 2. VXLAN

### 2.1 VXLAN 格式

```
┌─────────────────────────────────────────────────────────────┐
│                    VXLAN 封装格式                           │
│                                                              │
│  Outer Header:                                              │
│  ┌─────────┬─────────┬─────────┬─────────────────────────┐  │
│  │  Outer  │  Outer  │  Outer  │  Outer  │               │  │
│  │   MAC   │   IP    │   UDP   │  UDP    │   VXLAN      │  │
│  │  (14)  │  (20)   │   (8)   │  src/dst │  (8)         │  │
│  └─────────┴─────────┴─────────┴─────────┴───────────────┘  │
│                                                              │
│  Inner Packet:                                              │
│  ┌─────────┬─────────┬─────────┬─────────────────────────┐  │
│  │  Inner  │  Inner  │  Inner  │    Inner Payload       │  │
│  │   MAC   │   IP    │   L4    │                        │  │
│  │  (14)  │  (20)   │  varies │                        │  │
│  └─────────┴─────────┴─────────┴─────────────────────────┘  │
│                                                              │
│  VXLAN Header (8 bytes):                                    │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  Flags(8) | Reserved(24) | VNI(24) | Reserved(8)       │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  Flags:                                                      │
│  - Bit 3 (I): Must be 1 (Valid VNI)                        │
│  - Bits 0-2, 4-7: Reserved (set to 0)                      │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VXLAN 封装处理

```c
// VXLAN 封装 node
VLIB_NODE_FN(vxlan4_encap_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);
        vxlan4_tunnel_t *t = vxlan_tunnels[from_sw_if_index];

        // 1. 预留头部空间
        vlib_buffer_advance(b, -VXLAN_OVERHEAD(t));

        // 2. 写入 Inner Ethernet (保存原始)
        ethernet_header_t *inner_eth =
            vlib_buffer_get_current(b);

        // 3. 写入 Outer UDP
        udp_header_t *outer_udp =
            (udp_header_t *)(inner_eth + 1);
        outer_udp->src_port = ephemeral;  // 随机源端口
        outer_udp->dst_port = VXLAN_PORT; // 4789
        outer_udp->length = ip4_total_length - sizeof(udp);
        outer_udp->checksum = 0;  // UDP checksum 0 in IPv4

        // 4. 写入 Outer IP
        ip4_header_t *outer_ip =
            (ip4_header_t *)(outer_udp + 1);
        outer_ip->version = 4;
        outer_ip->ihl = 5;
        outer_ip->length = ...;
        outer_ip->ttl = 64;
        outer_ip->protocol = IP_PROTOCOL_UDP;
        outer_ip->src_address = t->src_ip;
        outer_ip->dst_address = t->dst_ip;

        // 5. 写入 Outer MAC
        ethernet_header_t *outer_eth =
            vlib_buffer_get_current(b);
        // ... 设置 src/dst MAC

        // 6. 写入 VXLAN Header
        vxlan_header_t *vx = (vxlan_header_t *)
            ((u8 *)outer_udp + sizeof(udp_header_t));

        vx->flags = VXLAN_FLAGS_I;  // I=1
        vx->vx_vni[0] = (t->vni >> 16) & 0xFF;
        vx->vx_vni[1] = (t->vni >> 8) & 0xFF;
        vx->vx_vni[2] = t->vni & 0xFF;
        vx->reserved = 0;
    }

    return n_packets;
}
```

### 2.3 VXLAN 解封装

```c
// VXLAN 解封装 node
VLIB_NODE_FN(vxlan4_input_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);

        // 1. 验证 Outer IP/UDP
        ip4_header_t *outer_ip = vlib_buffer_get_current(b);
        if (outer_ip->protocol != IP_PROTOCOL_UDP) goto drop;

        udp_header_t *outer_udp = (udp_header_t *)(outer_ip + 1);
        if (outer_udp->dst_port != clib_host_to_net_u16(4789)) goto drop;

        // 2. 提取 VXLAN Header
        vxlan_header_t *vx = (vxlan_header_t *)(outer_udp + 1);

        // 3. 验证 VNI
        if (!(vx->flags & VXLAN_FLAGS_I)) goto drop;

        u32 vni = (vx->vx_vni[2] << 16) |
                  (vx->vx_vni[1] << 8) |
                  vx->vx_vni[0];

        // 4. 查找 VNI 对应的 tunnel
        vxlan4_tunnel_t *t = vxlan_lookup_vni(vni);
        if (!t) goto drop;

        // 5. 移除隧道头
        vlib_buffer_advance(b, VXLAN_OVERHEAD(t));

        // 6. 发送到 L2 或 L3 输入
        vlib_put_next_frame(vm, node, VXLAN_NEXT_L2_INPUT, 1);
    }

drop:
    vlib_buffer_free(vm, from, n_packets);
    return 0;
}
```

### 2.4 VXLAN 配置

```bash
# 创建 VXLAN 隧道
vpp# create vxlan tunnel src 10.0.0.1 dst 10.0.0.2 vni 1000

# 创建 VXLAN 隧道 (可指定 UDP 端口)
vpp# create vxlan tunnel src 10.0.0.1 dst 10.0.0.2 vni 1000 port 4789

# 将 VXLAN 接口加入 Bridge Domain
vpp# set interface l2 bridge vxlan_tunnel0 bd_id 10

# 或加入 L3
vpp# set interface ip addr vxlan_tunnel0 192.168.1.1/24

# 查看 VXLAN
vpp# show vxlan
vpp# show vxlan tunnel
```

## 3. NVGRE

### 3.1 NVGRE 格式

```
┌─────────────────────────────────────────────────────────────┐
│                    NVGRE 封装格式                           │
│                                                              │
│  Outer Header:                                              │
│  ┌─────────┬─────────┬─────────┬─────────────────────────┐  │
│  │  Outer  │  Outer  │   GRE   │                         │  │
│  │   MAC   │   IP    │  (4/8)  │   Inner Packet         │  │
│  │  (14)  │  (20)   │         │                        │  │
│  └─────────┴─────────┴─────────┴─────────────────────────┘  │
│                                                              │
│  GRE Header (8 bytes):                                      │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  C|0|K|0|S|0|   Flags   | Ver |   Protocol Type     │  │
│  │  C|0|K|0|S|0|    0x00   |  1  |     0x6558           │  │
│  ├─────────────────────────────────────────────────────────┤ │
│  │                    Key (4 bytes)                       │  │
│  │              VSID (24-bit) | Reserved                  │  │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  Protocol Type: 0x6558 (NVGRE)                              │
│  Key: VSID (Virtual Subnet ID) = VNI                        │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 NVGRE 配置

```bash
# 创建 NVGRE 隧道
vpp# create gre tunnel src 10.0.0.1 dst 10.0.0.2 tunnel-type nvgre key 1000

# 查看 GRE
vpp# show gre
```

## 4. GENEVE

### 4.1 GENEVE 格式

```
┌─────────────────────────────────────────────────────────────┐
│                    GENEVE 封装格式                           │
│                                                              │
│  Outer Header:                                              │
│  ┌─────────┬─────────┬─────────┬─────────────────────────┐  │
│  │  Outer  │  Outer  │  Outer  │  GENEVE  │             │  │
│  │   MAC   │   IP    │   UDP   │  Header   │  Options   │  │
│  │  (14)  │  (20)   │   (8)   │   (8)    │  (variable) │  │
│  └─────────┴─────────┴─────────┴─────────┴───────────────┘  │
│                                                              │
│  GENEVE Header (8 bytes + options):                         │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  Ver  | Opt Len | O|C|  Reserved  |   Protocol Type   │  │
│  │   0   |    1   | 0|0|    0x0000   |     0x6558        │  │
│  ├─────────────────────────────────────────────────────────┤ │
│  │               Virtual Network Identifier (VNI)          │  │
│  ├─────────────────────────────────────────────────────────┤ │
│  │                    Options (variable)                   │  │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  GENEVE vs VXLAN 区别：                                      │
│  - GENEVE 有可变长度 Options 字段                            │
│  - 可以携带更多元数据（VM ID, policy ID 等）                 │
│  - 适合 SDNs / OpenStack                                 │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 GENEVE 选项

```c
// GENEVE 选项 TLV
typedef struct {
    u8 class[2];      // IANA assigned class
    u8 type;          // Option type
    u8 length;         // Option data length (multiple of 4)
    u8 data[];        // Option data
} geneve_option_t;

// 常见 GENEVE 选项
// Class 0x0102 (iovisors):
//   Type 0x80: VM UUID
//   Type 0x81: Policy ID
```

### 4.3 GENEVE 配置

```bash
# 创建 GENEVE 隧道
vpp# create geneve tunnel src 10.0.0.1 dst 10.0.0.2 vni 1000

# 创建带选项的 GENEVE (需要底层支持)
vpp# create geneve tunnel src 10.0.0.1 dst 10.0.0.2 vni 1000 options

# 查看 GENEVE
vpp# show geneve
```

## 5. GRE

### 5.1 GRE 格式

```
┌─────────────────────────────────────────────────────────────┐
│                    GRE 封装格式                              │
│                                                              │
│  GRE Header (4 bytes, 无 key):                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  C|R|K|S|s|Recur| Flags | Ver |   Protocol Type     │  │
│  │  0|0|0|0|0|  0   | 0x00  |  0  |     0x0800          │  │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  GRE Header (8 bytes, 有 key):                              │
│  ┌─────────────────────────────────────────────────────────┤ │
│  │  C|R|K|S|s|Recur| Flags | Ver |   Protocol Type     │  │
│  │  0|0|1|0|0|  0   | 0x00  |  0  |     0x0800          │  │
│  ├─────────────────────────────────────────────────────────┤ │
│  │                      Key (4 bytes)                     │  │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  Protocol Type:                                             │
│  - 0x0800: IPv4                                             │
│  - 0x86DD: IPv6                                             │
│  - 0x6558: NVGRE                                           │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 GRE 配置

```bash
# 创建 GRE 隧道
vpp# create gre tunnel src 10.0.0.1 dst 10.0.0.2

# 创建带 key 的 GRE 隧道
vpp# create gre tunnel src 10.0.0.1 dst 10.0.0.2 key 12345

# 创建 IPv6 隧道
vpp# create gre tunnel src 2001::1 dst 2001::2

# 查看 GRE
vpp# show gre
```

## 6. IPIP (IP in IP)

### 6.1 IPIP 格式

```
┌─────────────────────────────────────────────────────────────┐
│                    IPIP 封装格式                            │
│                                                              │
│  IPv4 in IPv4:                                              │
│  ┌─────────┬─────────┬────────────────────────────────────┐ │
│  │  Outer  │  Outer  │          Inner IPv4               │ │
│  │   IP    │   IP    │                                 │ │
│  │  (20)  │  (20)   │                                 │ │
│  └─────────┴─────────┴────────────────────────────────────┘ │
│  Protocol = 4 (IP-in-IP)                                    │
│                                                              │
│  IPv6 in IPv4:                                              │
│  ┌─────────┬─────────┬────────────────────────────────────┐ │
│  │  Outer  │  Outer  │          Inner IPv6               │ │
│  │   IP    │   IP    │                                 │ │
│  │  (20)  │  (20)   │                                 │ │
│  └─────────┴─────────┴────────────────────────────────────┘ │
│  Protocol = 41 (IPv6)                                       │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 IPIP 配置

```bash
# 创建 IPIP 隧道
vpp# create ipip tunnel src 10.0.0.1 dst 10.0.0.2

# 创建 IPIP6 隧道 (IPv6 in IPv4)
vpp# create ipip6 tunnel src 10.0.0.1 dst 10.0.0.2

# 查看 IPIP
vpp# show ipip
```

## 7. 隧道卸载

### 7.1 Checksum Offload

```c
// 隧道封装的 checksum offload
static_always_inline void
tunnel_set_checksum_offload(vlib_buffer_t *b,
                            ip4_header_t *outer_ip,
                            udp_header_t *outer_udp)
{
    // Outer IP: 让硬件计算
    outer_ip->checksum = 0;

    // Outer UDP: IPv4 下可以 offload
    if (outer_ip->dst_address.data_u32 == 0) {
        // 硬件无法计算 UDP checksum（不知道 dst IP）
        outer_udp->checksum = 0;
    } else {
        // IPv6 或已知 IP，可以 offload
        outer_udp->checksum =
            rte_ipv4_udptcp_checksum(outer_ip, outer_udp);
    }
}
```

### 7.2 GSO (Generic Segmentation Offload)

```c
// 隧道 GSO 支持
// 大包在隧道封装的outer层进行分片
static_always_inline void
tunnel_gso(vlib_buffer_t *b, u32 mtu)
{
    if (b->current_length > mtu) {
        // 需要分片
        // ... GSO 处理
    }
}
```

## 8. 总结

隧道封装对比：

| 特性         | VXLAN    | NVGRE   | GENEVE     | GRE        | IPIP     |
| ------------ | -------- | ------- | ---------- | ---------- | -------- |
| **标准化**   | RFC 7348 | MS      | IETF draft | RFC 2890   | RFC 1853 |
| **外层**     | UDP      | GRE     | UDP        | IP         | IP       |
| **VNI**      | 24-bit   | 24-bit  | 24-bit     | 32-bit key | 无       |
| **元数据**   | 无       | flow_id | 可变选项   | 无         | 无       |
| **硬件支持** | 广泛     | 部分    | 新兴       | 广泛       | 广泛     |
| **端口**     | 4789     | N/A     | 6081       | N/A        | N/A      |

选择建议：

```
数据中心 Overlay：
  - VXLAN：最广泛支持
  - GENEVE：需要元数据时
  - NVGRE：微软环境

简单隧道：
  - GRE：需要 key 时
  - IPIP：简单 IP in IP
```

---

## 参考资源

- [VXLAN RFC 7348](https://tools.ietf.org/html/rfc7348)
- [GENEVE IETF Draft](https://datatracker.ietf.org/doc/draft-ietf-nvo3-geneve/)
- [NVGRE Microsoft](https://docs.microsoft.com/en-us/windows-server/networking/sdn/technologies/nvgre-virtualization)
- [GRE RFC 2890](https://tools.ietf.org/html/rfc2890)
