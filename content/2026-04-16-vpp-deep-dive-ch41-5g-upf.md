---
title: "VPP 深入探讨 ch41：5G UPF 加速"
date: 2026-04-16 11:40:00
tags: [vpp, 5g, upf, 核心网, user-plane, n3, n9, n6, edge, mobile]
description: "深入解析 5G UPF (User Plane Function) 加速：3GPP 架构、N3/N9/N6 接口、VPP UPF 实现、GTP-U 隧道、QoS 映射与边缘部署"
---

# VPP 深入探讨 ch41：5G UPF 加速

> [!abstract] 核心要点
> 5G UPF 是移动核心网用户面的核心组件，的性能直接决定用户QoE。VPP凭借高吞吐、低延迟成为UPF加速的首选方案。本章详解5G UPF架构、VPP UPF设计与实现、以及QoS保障机制。

## 1. 5G 核心网概述

### 1.1 5G 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    5G 系统架构 (Service Based)              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   Data Network (DN)                   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ▲                                 │
│                            │ N6                             │
│  ┌─────────────────────────┼────────────────────────────┐  │
│  │                    UPF (User Plane Function)           │  │
│  │   - 数据包路由/转发                               │  │
│  │   - QoS 处理                                       │  │
│  │   - 策略执行                                       │  │
│  │   - 计费数据生成                                    │  │
│  └─────────────────────────┬────────────────────────────┘  │
│                            │ N9                             │
│                            │                                │
│  ┌─────────────────────────┼────────────────────────────┐  │
│  │                    SMF (Session Management)           │  │
│  │   - 会话管理                                       │  │
│  │   - UP 选择                                        │  │
│  │   - 策略控制                                       │  │
│  └─────────────────────────┬────────────────────────────┘  │
│                            │                                │
│  ┌─────────────────────────┼────────────────────────────┐  │
│  │                    AMF (Access and Mobility)          │  │
│  │   - 注册/连接管理                                 │  │
│  │   - 移动性管理                                    │  │
│  │   - NAS 安全                                      │  │
│  └─────────────────────────┴────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 UPF 角色

```
┌─────────────────────────────────────────────────────────────┐
│                    UPF 核心功能                             │
│                                                              │
│  1. 数据包路由                                                │
│     - N3 (RAN) ──► UPF ──► N6 (Internet)                   │
│     - 本地分流 (Local Breakout)                             │
│     - 锚点转发 (Multi-homing)                               │
│                                                              │
│  2. 协议转换                                                 │
│     - GTP-U 隧道封装/解封装                                  │
│     - PDU Session 处理                                       │
│     - Ethernet vs IP 转换                                    │
│                                                              │
│  3. QoS 执行                                                 │
│     - QFI (QoS Flow ID) 映射                                │
│     - 差异化服务                                            │
│     - 流量整形                                              │
│                                                              │
│  4. 策略执行                                                 │
│     - PCC (Policy & Charging Control)                       │
│     - 门控 (Gating)                                         │
│     - 计费规则                                              │
│                                                              │
│  5. 数据平面优化                                             │
│     - IPv4/IPv6 双栈                                        │
│     - UL CL / DL CL (UL/DL Classifier)                    │
│     - Multi-homed PDU Session                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 接口定义

```
┌─────────────────────────────────────────────────────────────┐
│                    UPF 接口                                  │
│                                                              │
│  N1: UE ──► AMF (NAS 控制面)                               │
│                                                              │
│  N2: RAN ──► AMF (NGAP)                                    │
│                                                              │
│  N3: RAN ──► UPF (GTP-U, 用户面数据)                       │
│                                                              │
│  N4: SMF ──► UPF (PFCP, 控制面)                            │
│                                                              │
│  N6: UPF ──► DN (数据网络)                                 │
│                                                              │
│  N9: UPF ──► UPF (Inter-UPF 传输)                         │
│                                                              │
│  N19: UPF ──► UPF (Local Area Data Network)                │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    GTP-U 隧道                        │   │
│  │   TEID (Tunnel Endpoint ID) ──► 唯一会话标识          │   │
│  │   头: TEID, 序列号, 扩展头                           │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 2. VPP UPF 架构

### 2.1 设计目标

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP UPF 设计目标                          │
│                                                              │
│  性能指标:                                                   │
│  - 吞吐量: > 100 Gbps per server                            │
│  - PPS: > 50 Mpps                                           │
│  - 延迟: < 10μs (per packet)                                │
│  - 抖动: < 100μs                                            │
│  - 丢包率: < 0.001%                                         │
│                                                              │
│  功能目标:                                                   │
│  - 完整 3GPP Release 16/17 支持                            │
│  - N3/N9/N6 接口                                           │
│  - GTP-U v1/v2                                             │
│  - PFCP 协议                                                │
│  - QoS Flow 处理                                           │
│  - Multi-connection / Multi-homing                        │
│  - Ethernet PDU Session                                     │
│                                                              │
│  部署场景:                                                   │
│  - 5G Core (云化)                                          │
│  - Edge (MEC 集成)                                         │
│  - Small Cell Gateway                                      │
│  - Enterprise 5G                                          │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VPP UPF 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP UPF 架构                             │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPP UPF                            │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │              Graph Nodes                      │    │   │
│  │  │                                               │    │   │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐      │    │   │
│  │  │  │gtp-input│  │session- │  │   n6-   │      │    │   │
│  │  │  │         │──▶│lookup   │──▶│output   │      │    │   │
│  │  │  └─────────┘  └─────────┘  └─────────┘      │    │   │
│  │  │      │                                       │    │   │
│  │  │      ▼                                       │    │   │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐      │    │   │
│  │  │  │gtp-     │  │qos-     │  │acl-    │      │    │   │
│  │  │  │decap    │──▶│enforce  │──▶|filter  │      │    │   │
│  │  │  └─────────┘  └─────────┘  └─────────┘      │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │              Session Database                 │    │   │
│  │  │  - PDR (Packet Detection Rule)              │    │   │
│  │  │  - FAR (Forwarding Action Rule)             │    │   │
│  │  │  - QER (QoS Enforcement Rule)               │    │   │
│  │  │  - URR (Usage Reporting Rule)               │    │   │
│  │  │  - BAR (Buffer Action Rule)                  │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPP Infra                        │   │
│  │   - Buffer Management                               │   │
│  │   - Thread Model                                    │   │
│  │   - DPDK PMD                                        │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 核心数据结构

```c
// upf_pdr.h - Packet Detection Rule

typedef struct {
    u32 pdr_id;              // PDR 唯一标识
    u32 session_id;           // 所属会话
    
    // PDI (Packet Detection Information)
    u8  qfi;                  // QoS Flow ID (6 bits)
    u32 teid;                 // GTP-U TEID
    ip46_address_t src_ip;    // 源 IP
    ip46_address_t dst_ip;    // 目标 IP
    u16 src_port_start;        // 源端口范围
    u16 src_port_end;
    u16 dst_port_start;       // 目标端口范围
    u16 dst_port_end;
    u8  protocol;             // IP 协议
    
    // 匹配计数
    u64 packet_count;
    u64 byte_count;
    
    // 关联规则
    u32 far_id;              // Forward Action Rule
    u32 qer_id;              // QoS Enforcement Rule
    u32 urr_id;              // Usage Reporting Rule
    
    // 预处理标志
    u8  need_decap    : 1;
    u8  need_buff     : 1;
    u8  nwi_indicator  : 1;
} upf_pdr_t;

// upf_far.h - Forwarding Action Rule

typedef struct {
    u32 far_id;
    u32 session_id;
    
    // 转发参数
    u8  action;               // DROP, FORWARD, BUFFER, NOTIFY
    
    // 输出信息
    u32 dst_teid;            // 目标 TEID (for N9/N3)
    ip46_address_t dst_ip;   // 目标 IP
    u16 dst_port;            // UDP 端口 (通常 2152)
    
    // 封装参数
    u8  need_encap    : 1;
    u8  need_tos      : 1;
    u8  need_ttl      : 1;
    u8  tos_value;
    u8  ttl_value;
} upf_far_t;

// upf_qer.h - QoS Enforcement Rule

typedef struct {
    u32 qer_id;
    u32 session_id;
    
    // QoS 参数
    u8  qfi;                  // QoS Flow ID
    u32 gbr;                  // Guaranteed Bit Rate (bps)
    u32 mbr;                  // Maximum Bit Rate (bps)
    
    // MBR 以太网上限
    u64 gbr_ul;
    u64 gbr_dl;
    u64 mbr_ul;
    u64 mbr_dl;
    
    // QoS 规则索引
    u32 qos_rule_id;
} upf_qer_t;
```

## 3. GTP-U 协议实现

### 3.1 GTP-U 头格式

```
┌─────────────────────────────────────────────────────────────┐
│                    GTP-U v1 头格式                           │
│                                                              │
│   0                   1                   2                   3 │
│   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 │
│  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
│  │Ver│E│S│PN│  MT  │          TEID (Tunnel Endpoint ID)        │
│  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
│  │         Sequence Number (Optional)                          │
│  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
│  │           N-PDU (Optional)                                  │
│  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
│  │         Next Extension Header Type (Optional)               │
│  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
│                                                              │
│  Ver:  版本 (1)                                             │
│  E:    扩展头标志 (1=有扩展)                                  │
│  S:    序列号标志 (1=有序列号)                                │
│  PN:   N-PDU 编号标志                                        │
│  MT:   消息类型 (0xFF = T-PDU)                               │
│  TEID: 隧道端点标识 (32 bits)                                │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 GTP-U 解封装

```c
// gtp_encap.c - GTP-U 处理

static_always_inline u32
gtpu_input (vlib_main_t * vm, vlib_buffer_t * b, gtpuhdr_t * gtp,
            u32 teid, u32 * session_id)
{
    // 1. 验证 GTP-U 头
    if (gtp->ver != 1 || gtp->mt != 0xFF) {
        return GTP_BAD_HEADER;
    }
    
    // 2. 查找 Session
    upf_session_t *s = session_lookup_by_teid(teid);
    if (!s) {
        return GTP_NO_SESSION;
    }
    
    // 3. 检查序列号 (如果 S flag set)
    if (gtp->s) {
        u16 seq = clib_net_to_host_u16(gtp->seq);
        if (!seq_check(s, seq)) {
            return GTP_SEQ_ERROR;
        }
    }
    
    // 4. 移除 GTP-U 头
    u8 ext_len = 0;
    if (gtp->e) {
        // 处理扩展头
        gtp_ext_hdr_t *ext = (gtp_ext_hdr_t *)(gtp + 1);
        ext_len = ext->len * 4;
    }
    
    vlib_buffer_advance(b, sizeof(gtpuhdr_t) + ext_len);
    
    // 5. 查找 PDR
    upf_pdr_t *pdr = pdr_lookup(s, b);
    if (!pdr) {
        return GTP_NO_PDR;
    }
    
    // 6. 更新统计
    pdr->packet_count++;
    pdr->byte_count += vlib_buffer_length_in_chain(vm, b);
    
    *session_id = s->id;
    return GTP_OK;
}
```

### 3.3 GTP-U 封装

```c
// GTP-U 封装 (N6 -> N3)

static_always_inline void
gtpu_encap (vlib_main_t * vm, vlib_buffer_t * b, 
             ip4_header_t * ip, gtpuhdr_t * gtp,
             u32 teid, u32 seq)
{
    // 1. 保存原始 IP 头
    ip4_header_t inner_ip = *ip;
    u16 inner_total_length = clib_net_to_host_u16(inner_ip.length);
    
    // 2. 构建 GTP-U 头
    gtp->ver = 1;
    gtp->e = 0;        // 无扩展头
    gtp->s = 1;        // 有序列号
    gtp->pn = 0;
    gtp->mt = 0xFF;    // T-PDU
    gtp->teid = clib_net_to_host_u32(teid);
    gtp->seq = clib_net_to_host_u16(seq);
    
    // 3. 构建 UDP 头
    udp_header_t *udp = (udp_header_t *)(gtp + 1);
    udp->src_port = clib_net_to_host_u16(2152);
    udp->dst_port = clib_net_to_host_u16(2152);
    udp->length = clib_net_to_host_u16(
        sizeof(gtpuhdr_t) + sizeof(udp_header_t) + inner_total_length
    );
    udp->checksum = 0;  // UDP 校验和可以忽略
    
    // 4. 构建外层 IP 头
    ip->length = clib_net_to_host_u16(
        sizeof(ip4_header_t) + sizeof(udp_header_t) + 
        sizeof(gtpuhdr_t) + inner_total_length
    );
    ip->ttl = 64;
    ip->protocol = IP_PROTOCOL_UDP;
    // 设置源/目标 IP (来自 FAR)
    
    // 5. 调整 buffer
    vlib_buffer_advance(b, -(sizeof(gtpuhdr_t) + sizeof(udp_header_t) + 
                              sizeof(ip4_header_t)));
}
```

## 4. PFCP 协议

### 4.1 PFCP 概述

```
┌─────────────────────────────────────────────────────────────┐
│                    PFCP 协议 (Packet Forwarding Control)    │
│                                                              │
│  SMF <───PFCP───> UPF                                       │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    PFCP 消息                          │   │
│  │                                                       │   │
│  │  Node Related:                                       │   │
│  │  - Heartbeat Request/Response                       │   │
│  │  - PFD Management Request/Response                  │   │
│  │  - Association Setup Request/Response               │   │
│  │                                                       │   │
│  │  Session Related:                                    │   │
│  │  - Session Establishment Request/Response            │   │
│  │  - Session Modification Request/Response            │   │
│  │  - Session Deletion Request/Response                 │   │
│  │  - Session Report Request/Response                   │   │
│  │                                                       │   │
│  │  PFDs:                                                │   │
│  │  - Application ID                                    │   │
│  │  - Flow Description                                  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 PFCP Session 建立

```bash
# PFCP 消息示例

# 1. Association Setup (UPF 注册到 SMF)
PFCP Association Setup Request:
  Node ID: upf1.5gc.operator.com
  Recovery Time Stamp: 0x12345678
  Features: GTP-U:1, PFCP:1, Load:1

PFCP Association Setup Response:
  Cause: Request accepted
  UPF Features: F-TEID:1, UE IP:1, User Plane IP:1

# 2. Session Establishment (PDU Session 建立)
PFCP Session Establishment Request:
  F-SEID: 0x1234567890ABCDEF (UPF SEID)
  
  Create PDR:
    PDR ID: 1
    PDI:
      Source Interface: N6
      F-TEID: (TEID: 0x100, UE IP: 45.67.89.1)
      Network Instance: vlan100
    
    Outer Header Removal: GTP-U/UDP/IPv4
    
    Create FAR:
      FAR ID: 1
      Action: FORWARD
      Forward Parameters:
        Destination Interface: N3
        F-TEID: (TEID: 0x200, UE IP: 10.0.0.1)
        
    Create QER:
      QER ID: 1
      QFI: 9
      MBR: 1 Gbps
      GBR: 500 Mbps
```

### 4.3 VPP PFCP 实现

```c
// upf_pfcp.c - PFCP 处理

/* PFCP 消息类型 */
typedef enum {
    PFCP_HEARTBEAT_REQUEST = 0x01,
    PFCP_HEARTBEAT_RESPONSE = 0x02,
    PFCP_ASSOCIATION_SETUP_REQUEST = 0x01,
    PFCP_ASSOCIATION_SETUP_RESPONSE = 0x02,
    PFCP_SESSION_ESTABLISHMENT_REQUEST = 0x05,
    PFCP_SESSION_ESTABLISHMENT_RESPONSE = 0x06,
    // ...
} pfcp_msg_type_t;

/* PFCP IE 类型 */
typedef enum {
    PFCP_IE_NODE_ID = 0x01,
    PFCP_IE_F_SEID = 0x02,
    PFCP_IE_CREATE_PDR = 0x01,
    PFCP_IE_CREATE_FAR = 0x02,
    PFCP_IE_CREATE_QER = 0x03,
    // ...
} pfcp_ie_type_t;

/* PFCP Session */
typedef struct {
    u64 local_seid;       // SMF SEID
    u64 remote_seid;      // UPF SEID
    
    u32 pdr_count;
    upf_pdr_t *pdrs[8];   // 最多 8 个 PDR
    
    u32 far_count;
    upf_far_t *fars[8];
    
    u32 qer_count;
    upf_qer_t *qers[8];
    
    // 定时器
    u32 heartbeat_interval;  // ms
    u32 heartbeat_timer;
} upf_pfcp_session_t;

/* 处理 PFCP Session 建立请求 */
static int
pfcp_handle_session_establishment(upf_pfcp_t *pfcp, 
                                   pfcp_msg_t *req,
                                   pfcp_msg_t *rsp)
{
    // 1. 解析 F-SEID
    u64 seid = pfcp_get_f_seid(req);
    
    // 2. 创建 Session
    upf_pfcp_session_t *s = session_create(seid);
    
    // 3. 解析并创建 PDR
    pfcp_ie_t *pdr_ie = pfcp_get_ie(req, PFCP_IE_CREATE_PDR);
    foreach pdr_ie {
        upf_pdr_t *pdr = pdr_parse(pdr_ie);
        session_add_pdr(s, pdr);
    }
    
    // 4. 解析并创建 FAR
    pfcp_ie_t *far_ie = pfcp_get_ie(req, PFCP_IE_CREATE_FAR);
    upf_far_t *far = far_parse(far_ie);
    session_add_far(s, far);
    
    // 5. 解析并创建 QER
    pfcp_ie_t *qer_ie = pfcp_get_ie(req, PFCP_IE_CREATE_QER);
    upf_qer_t *qer = qer_parse(qer_ie);
    session_add_qer(s, qer);
    
    // 6. 构建响应
    rsp->cause = PFCP_CAUSE_REQUEST_ACCEPTED;
    rsp->create_far_response = /* FAR response IE */;
    
    return 0;
}
```

## 5. QoS 保障

### 5.1 5G QoS 模型

```
┌─────────────────────────────────────────────────────────────┐
│                    5G QoS Flow                              │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    QoS Flow                           │   │
│  │   - 最小粒度                                          │   │
│  │   - QFI (QoS Flow ID) 标识                          │   │
│  │   - 每个 Flow 独立 QoS                               │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    DRB (Data Radio Bearer)          │   │
│  │   - 无线侧聚合                                       │   │
│  │   - 多个 QoS Flow 映射到一个 DRB                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    PDU Session                       │   │
│  │   - UE 与 UPF 之间                                  │   │
│  │   - 端到端                                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  QoS 参数:                                                   │
│  - QFI: 6-bit 标识                                          │
│  - 5QI: 9-bit QoS Identifier                               │
│  - MBR/GBR: 最大/保证比特率                                 │
│  - ARP: 分配保留优先级                                       │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 VPP QoS 映射

```c
// upf_qos.c - QoS 映射

typedef struct {
    u8   qfi;
    u8  5qi;
    u32  mbr_ul;
    u32  mbr_dl;
    u32  gbr_ul;
    u32  gbr_dl;
    u8   priority;
    u8  arp_priority;
} upf_qos_profile_t;

/* QFI -> 5QI 映射表 */
static upf_qos_profile_t qos_profiles[] = {
    { 1,  1,  0,      0,      64e3,   64e3,   1,  1  },  // Conversational Voice
    { 2,  2,  0,      0,      128e3,  128e3,  2,  2  },  // Conversational Video
    { 3,  3,  0,      0,      384e3,  384e3,  3,  3  },  // Conversational Audio
    { 4,  4,  64e3,   64e3,   64e3,   64e3,   4,  4  },  // V2X
    { 5,  5,  0,      0,      0,      0,      5,  5  },  // IMS Signaling
    { 6,  6,  64e3,   64e3,   64e3,   64e3,   6,  6  },  // Video (Buffered)
    { 7,  7,  64e3,   64e3,   64e3,   64e3,   7,  7  },  // Voice
    { 8,  8,  64e3,   64e3,   64e3,   64e3,   8,  8  },  // Video (Buffered)
    { 9,  9,  64e3,   64e3,   64e3,   64e3,   9,  9  },  // Video (Buffered) - Best Effort
};

/* 执行 QoS 策略 */
static_always_inline u32
qos_enforce (vlib_buffer_t *b, upf_qer_t *qer, u8 direction)
{
    u64 rate;
    u64 burst;
    
    if (direction == UP_DIRECTION_UL) {
        rate = qer->mbr_ul;
        burst = qer->gbr_ul;
    } else {
        rate = qer->mbr_dl;
        burst = qer->gbr_dl;
    }
    
    // 令牌桶限速
    if (!token_bucket_check(b->rate_limit_token, rate, burst)) {
        // 超过 MBR，标记丢弃
        return QOS_DROP;
    }
    
    // 设置 DSCP (可选)
    u8 dscp = qfi_to_dscp(qer->qfi);
    set_dscp(b, dscp);
    
    return QOS_ALLOW;
}
```

## 6. 边缘部署

### 6.1 UPF 部署场景

```
┌─────────────────────────────────────────────────────────────┐
│                    UPF 部署场景                              │
│                                                              │
│  Centralized UPF:                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Core Cloud                         │   │
│  │   ┌─────────────────────────────────────────────┐    │   │
│  │   │                 UPF                           │    │   │
│  │   │  - 大容量                                     │    │   │
│  │   │  - 全功能                                     │    │   │
│  │   │  - 完整计费                                   │    │   │
│  │   └─────────────────────────────────────────────┘    │   │
│  │                          ▲                            │   │
│  │                          │ N2/N3                       │   │
│  │       ┌──────────────────┼──────────────────┐         │   │
│  │       ▼                  ▼                  ▼         │   │
│  │   [gNB 1]           [gNB 2]           [gNB 3]           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  Distributed UPF (Edge):                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Edge Data Center                   │   │
│  │   ┌─────────────────────────────────────────────┐    │   │
│  │   │                 UPF-L (Local)                │    │   │
│  │   │  - 低延迟                                     │    │   │
│  │   │  - 本地分流                                   │    │   │
│  │   └─────────────────────────────────────────────┘    │   │
│  │                          ▲                            │   │
│  │       ┌──────────────────┼──────────────────┐         │   │
│  │       ▼                  ▼                  ▼         │   │
│  │   [gNB A]           [gNB B]           [gNB C]           │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 本地分流

```bash
# UPF-L 配置 (边缘)

# 1. 配置 N6 本地网络
vpp# set interface ip address eth0 192.168.100.1/24

# 2. 配置 UL CL (Uplink Classifier)
vpp# upf ul-cl create id 1
vpp# upf ul-cl rule add id 1 table 100 dst 10.0.0.0/8

# 3. 配置 DL CL (Downlink Classifier)
vpp# upf dl-cl create id 1
vpp# upf dl-cl rule add id 1 table 100 src 10.0.0.0/8

# 4. 配置 PDU Session 本地分流
vpp# upf pdu-session create id 1 ue-ip 45.67.89.100
vpp# upf pdr add session 1 pdr-id 1 \
    n6-network 192.168.100.0/24 \
    qfi 9 \
    far-id 1

# 5. 查看会话
vpp# show upf sessions

# 示例输出:
# Sessions:
#   ID: 1, UE-IP: 45.67.89.100, State: Active
#     PDRs:
#       PDR[1]: QFI=9, N6 192.168.100.0/24
#     FARs:
#       FAR[1]: N3, TEID=0x100
```

### 6.3 Multi-homed PDU Session

```bash
# IPv6 Multi-homed PDU Session

# 1. 创建会话 (UE IP: 2001:db8::1)
vpp# upf pdu-session create id 2 \
    ue-ipv6 2001:db8::1 \
    pdu-type IPv6

# 2. 添加多个锚点 (N9 接口)
vpp# upf far add session 2 far-id 10 \
    action FORWARD \
    n9-ipv6 2001:db8:1::1 \
    n9-teid 0x1000

vpp# upf far add session 2 far-id 11 \
    action FORWARD \
    n9-ipv6 2001:db8:2::1 \
    n9-teid 0x2000

# 3. 配置 Branching (同时转发)
vpp# upf far add session 2 far-id 12 \
    action BRANCH \
    n9-ipv6 2001:db8:1::1 \
    n9-teid 0x1000 \
    n9-ipv6-2 2001:db8:2::1 \
    n9-teid-2 0x2000

# 4. 显示多归属状态
vpp# show upf session id 2

# 示例输出:
# Session 2: IPv6 Multi-homed
#   UE IP: 2001:db8::1
#   Branches:
#     [0] N9 Anchor 1: 2001:db8:1::1, TEID=0x1000
#     [1] N9 Anchor 2: 2001:db8:2::1, TEID=0x2000
#   Active Branch: [0]
```

## 7. 性能优化

### 7.1 调优参数

```bash
# VPP UPF 性能调优

# /etc/vpp/startup.conf
unix {
  nodaemon
  log /var/log/vpp/upf.log
  cli-listen /run/vpp/cli.sock
}

cpu {
  main-core 0
  corelist-workers 1-15
  workers-thread-count 15
}

dpdk {
  socket-mem 8192,8192
  no-tx-checksum-offload
  
  # NIC 配置
  dev 0000:3b:00.0 {
    rx-queue-size 4096
    tx-queue-size 4096
  }
  
  dev 0000:3b:00.1 {
    rx-queue-size 4096
    tx-queue-size 4096
  }
}

upf {
  # 会话表大小
  session-table-size 1000000
  
  # 缓冲区大小
  buffer-size 65536
  
  # GTP 并行处理
  gtpusize 2048
  
  # 心跳间隔
  heartbeat 10000
}
```

### 7.2 性能数据

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP UPF 性能基准                          │
│                                                              │
│  测试环境:                                                   │
│  - Server: 2x Intel Xeon Gold 6348 (56 cores total)         │
│  - NIC: 2x 100GbE QSFP28                                    │
│  - Memory: 256GB DDR4                                        │
│                                                              │
│  单核性能:                                                   │
│  - Packet Size    │    PPS      │    Throughput             │
│  - 64B            │   28 Mpps   │    14.9 Gbps              │
│  - 128B           │   22 Mpps   │    23.5 Gbps              │
│  - 256B           │   16 Mpps   │    32.8 Gbps              │
│  - 512B           │   10 Mpps   │    40.9 Gbps              │
│  - 1024B          │   5.5 Mpps  │    45.1 Gbps              │
│  - 1400B          │   4.2 Mpps  │    47.1 Gbps              │
│                                                              │
│  多核扩展:                                                   │
│  - 4 cores:   ~100 Gbps                                     │
│  - 8 cores:   ~200 Gbps                                     │
│  - 16 cores:  ~400 Gbps                                     │
│                                                              │
│  延迟 (64B, single flow):                                    │
│  - Average: ~5μs                                           │
│  - P99:      ~8μs                                           │
│  - P999:     ~12μs                                          │
└─────────────────────────────────────────────────────────────┘
```

## 8. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP UPF 总结                             │
│                                                              │
│  核心价值:                                                   │
│  - 高性能: >100 Gbps per server                            │
│  - 低延迟: <10μs per packet                                │
│  - 高扩展: 线性多核扩展                                     │
│  - 标准兼容: 3GPP Release 16/17                           │
│                                                              │
│  关键功能:                                                   │
│  - GTP-U 隧道处理                                          │
│  - PFCP 控制面                                             │
│  - QoS Flow 映射                                          │
│  - 本地分流 (UL/DL CL)                                    │
│  - Multi-homed PDU Session                                 │
│                                                              │
│  接口支持:                                                  │
│  - N3: RAN 接入                                            │
│  - N4: SMF 控制                                            │
│  - N6: 数据网络                                            │
│  - N9: UPF 间传输                                          │
│                                                              │
│  部署场景:                                                  │
│  - Central UPF (核心云)                                    │
│  - UPF-L (边缘)                                            │
│  - Enterprise 5G                                          │
│  - Small Cell Gateway                                      │
│                                                              │
│  生态集成:                                                  │
│  - Free5GC, Open5GS (开源核心网)                           │
│  - OAI (Open Air Interface)                                │
│  - srsRAN                                                  │
│  - Kubernetes (MANO)                                       │
└─────────────────────────────────────────────────────────────┘
```

---

## 参考资源

- [3GPP TS 23.501 - 5G System Architecture](https://www.3gpp.org/)
- [3GPP TS 23.502 - Procedures for 5G Systems](https://www.3gpp.org/)
- [3GPP TS 29.244 - Interface at the UPF](https://www.3gpp.org/)
- [VPP UPF Plugin](https://wiki.fd.io/view/VPP/UPF)
- [Free5GC](https://www.free5gc.org/)
- [OAI 5G RAN](https://www.openairinterface.org/)
