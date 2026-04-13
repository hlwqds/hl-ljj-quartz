---
title: "DPDK 第四十七章：NAT 实现 CGNAT、NAT444"
date: 2026-04-09 17:40:00
tags: [dpdk, nat, cgnat, nat444, carrier-grade, napt, ipv4-depletion]
description: "深入解析基于 DPDK 的 NAT 实现：NAPT、CGNAT、NAT444 架构、会话管理、端口块分配与日志合规"
---

# DPDK 第四十七章：NAT 实现 CGNAT、NAT444

> [!abstract] 核心要点
> NAT 是 IPv4 地址紧缺的核心解决方案。CGNAT (Carrier-Grade NAT) 和 NAT444 是运营商级别的 NAT 技术。本章讲解基于 DPDK 的高性能 NAT 实现。

## 1. NAT 概述

### 1.1 NAT 类型

| 类型 | 说明 | 应用 |
|------|------|------|
| **Basic NAT** | 1:1 IP 映射 | 少量公网 IP 分配 |
| **NAPT** | Network Address Port Translation (PAT) | 多个用户共享公网 IP |
| **CGNAT** | Carrier-Grade NAT | 运营商级别大规模 NAT |
| **NAT444** | 两级 NAT (用户 + 运营商) | 解决最后一段 IPv4 |

### 1.2 IPv4 地址紧缺

```
IPv4 地址分配情况：
- 总计：4,294,967,296 (约 40 亿)
- 已分配：~96%
- 可用：~4%

运营商现状：
- 每个用户：1 个公网 IP (越来越少)
- 每个家庭：多设备 (手机/PC/平板/IoT...)
- 解决方案：CGNAT + NAT444
```

### 1.3 NAT 原理

```
┌─────────────────────────────────────────────────────────────┐
│                    NAPT (Network Address Port Translation)   │
│                                                              │
│  内部网络：                                                 │
│  User A: 192.168.1.10:50000 → 203.0.113.1:20001            │
│  User B: 192.168.1.20:30000 → 203.0.113.1:20002            │
│  User C: 192.168.2.15:40000 → 203.0.113.1:20003            │
│                                                              │
│  NAT 设备维护映射表：                                       │
│  ┌─────────────────────────────────────────────┐           │
│  │  Private IP     : Port  ↔  Public IP : Port│           │
│  │  192.168.1.10   : 50000  ↔  203.0.113.1 : 20001│           │
│  │  192.168.1.20   : 30000  ↔  203.0.113.1 : 20002│           │
│  │  192.168.2.15   : 40000  ↔  203.0.113.1 : 20003│           │
│  └─────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

## 2. CGNAT 架构

### 2.1 为什么需要 CGNAT

```
传统方案 vs CGNAT：

传统：每个用户一个公网 IP
  ISP → 用户1 (公网IP) → 用户2 (公网IP) → 用户3 (公网IP)
        1:1 映射，IP 消耗快

CGNAT：多个用户共享一个公网 IP
  ISP → CGNAT → [用户1, 用户2, ..., 用户256] (共享 203.0.113.1)
        256:1 映射，节省 IP
```

### 2.2 CGNAT 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    CGNAT 架构                               │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   BNG (Broadband Network Gateway)     │  │
│  │                    (运营商接入网关)                   │  │
│  └─────────────────────────┬────────────────────────────┘  │
│                            │                                │
│  ┌─────────────────────────▼────────────────────────────┐  │
│  │                     CGNAT                             │  │
│  │                                                      │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐     │  │
│  │  │  NAT Pool  │  │ Port Block │  │  Session   │     │  │
│  │  │  Manager   │  │  Allocator │  │  Table     │     │  │
│  │  └────────────┘  └────────────┘  └────────────┘     │  │
│  │                                                      │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐     │  │
│  │  │  ALG       │  │  Logging   │  │  Filtering │     │  │
│  │  │  (FTP/H.323)│  │  (syslog) │  │  (SPI)     │     │  │
│  │  └────────────┘  └────────────┘  └────────────┘     │  │
│  └─────────────────────────┬────────────────────────────┘  │
│                            │                                │
│  ┌─────────────────────────▼────────────────────────────┐  │
│  │                    Public Internet                    │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 Port Block 分配

CGNAT 按 Port Block 分配，而非单个 Port：

```c
// Port Block 分配
struct port_block {
    uint32_t public_ip;        // 公网 IP
    uint16_t base_port;        // 起始端口 (e.g., 10000)
    uint16_t block_size;       // Block 大小 (e.g., 256/512/1024)
    uint16_t ports_in_use;     // 已用端口数
    uint8_t  state;            // 分配状态
    uint64_t assign_time;      // 分配时间
    uint32_t subscriber_id;     // 关联用户
};

// 分配 Port Block 给用户
static struct port_block *
allocate_port_block(struct nat_context *ctx, uint32_t subscriber_ip)
{
    // 查找已有的 block
    struct port_block *block = find_block_by_subscriber(ctx, subscriber_ip);
    if (block && block->ports_in_use < block->block_size) {
        return block;
    }

    // 分配新的 block
    block = get_free_block(ctx);
    if (!block) {
        return NULL;  // 没有可用 block
    }

    block->subscriber_ip = subscriber_ip;
    block->ports_in_use = 0;
    block->assign_time = rte_get_tsc_Hz();

    return block;
}

// 从 block 分配一个 port
static uint16_t
allocate_port_from_block(struct port_block *block)
{
    // 简单的 bitmap 查找
    uint16_t port = find_free_port(block->bitmap);
    if (port > 0) {
        set_bit(block->bitmap, port - block->base_port);
        block->ports_in_use++;
    }
    return port;
}
```

## 3. NAT444

### 3.1 NAT444 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      NAT444                                │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │                   Public Internet                   │    │
│  └────────────────────────┬───────────────────────────┘    │
│                           │ 203.0.113.1-254                 │
│  ┌────────────────────────▼───────────────────────────┐    │
│  │              CGNAT (运营商 NAT)                     │    │
│  │              100.64.0.0/10 ↔ 203.0.113.x            │    │
│  └────────────────────────┬───────────────────────────┘    │
│                           │ 100.64.x.x                      │
│  ┌────────────────────────▼───────────────────────────┐    │
│  │              CPE NAT (家庭网关 NAT)                 │    │
│  │              192.168.1.0/24 ↔ 100.64.x.x            │    │
│  └────────────────────────┬───────────────────────────┘    │
│                           │ 192.168.1.x                      │
│         ┌─────────────────┼─────────────────┐            │
│         ▼                 ▼                 ▼            │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐     │
│  │   User A   │    │   User B   │    │   User C   │     │
│  │  192.168.1 │    │  192.168.1 │    │ 192.168.1  │     │
│  └────────────┘    └────────────┘    └────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 双重 NAT 处理

```c
// NAT444 需要跟踪两层 NAT
struct nat444_entry {
    // 第一层：用户侧 NAT (CPE)
    uint32_t private_ip;       // 192.168.1.10
    uint16_t private_port;    // 50000

    // 第二层：CGNAT
    uint32_t shared_ip;       // 100.64.0.10
    uint16_t shared_port;     // 30000

    // 公网侧
    uint32_t public_ip;       // 203.0.113.1
    uint16_t public_port;     // 20001

    uint8_t  protocol;
    uint64_t create_time;
    uint64_t last_active;
};

// 完整的 NAT444 转换流程
static void
process_nat444_outbound(struct nat_context *ctx, struct rte_mbuf *pkt)
{
    struct ipv4_hdr *ip = get_ip_header(pkt);
    struct tcpudp_hdr *l4 = get_l4_header(ip);

    // Step 1: CPE NAT (已有，通常不处理)
    // private_ip:port → shared_ip:port

    // Step 2: CGNAT (我们需要处理的)
    // shared_ip:port → public_ip:port

    // 查找或创建映射
    struct nat444_entry *entry = find_or_create_nat444_entry(ctx,
        ip->src_addr,
        l4->src_port);

    // 修改包
    ip->src_addr = entry->public_ip;
    l4->src_port = entry->public_port;

    // 重新计算 checksum
    recalc_checksums(ip, l4);

    // 记录日志（合规要求）
    log_nat_entry(ctx, entry, LOG_TYPE_CREATE);
}
```

## 4. 会话管理

### 4.1 NAT 表设计

```c
// NAT 会话表
struct nat_session {
    // Key: 5-tuple
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  protocol;

    // NAT 后的值
    uint32_t nat_ip;
    uint16_t nat_port;

    // 元数据
    uint64_t create_time;
    uint64_t last_active;
    uint32_t bytes_in;
    uint32_t bytes_out;
    uint32_t pkts_in;
    uint32_t pkts_out;
    uint8_t  state;  // TCP state or ALIVE/EXPIRY
};

// TCP 状态跟踪
enum nat_tcp_state {
    NAT_TCP_CLOSED,
    NAT_TCP_SYN_SENT,
    NAT_TCP_SYN_RECV,
    NAT_TCP_ESTABLISHED,
    NAT_TCP_FIN_WAIT,
    NAT_TCP_CLOSE_WAIT,
    NAT_TCP_CLOSING,
};
```

### 4.2 高效查找

```c
// 使用 rte_hash 进行 O(1) 查找
struct nat_table {
    struct rte_hash *outbound_hash;   // 原始 → NAT
    struct rte_hash *inbound_hash;    // NAT → 原始
    struct rte_mempool *session_pool;
    uint32_t max_sessions;
};

// 创建 NAT 表
struct nat_table *
nat_table_create(uint32_t max_sessions)
{
    struct nat_table *table = rte_malloc(NULL, sizeof(*table), 0);

    // Outbound 查找表
    struct rte_hash_parameters out_params = {
        .name = "nat_outbound",
        .entries = max_sessions,
        .key_len = sizeof(struct nat_5tuple),
        .hash_func = rte_hash_crc,
    };
    table->outbound_hash = rte_hash_create(&out_params);

    // Inbound 查找表 (公网回来时用)
    struct rte_hash_parameters in_params = {
        .name = "nat_inbound",
        .entries = max_sessions,
        .key_len = sizeof(struct nat_inbound_key),
        .hash_func = rte_hash_crc,
    };
    table->inbound_hash = rte_hash_create(&in_params);

    table->session_pool = rte_mempool_create("nat_sessions",
        max_sessions, sizeof(struct nat_session),
        0, 0, NULL, NULL, NULL, NULL, SOCKET_ID_ANY, 0);

    return table;
}
```

### 4.3 会话超时

```c
// 会话超时配置
struct nat_timeout {
    uint32_t tcp_established;   // TCP established: 3600s
    uint32_t tcp_transitory;     // TCP transitory: 120s
    uint32_t udp;                // UDP: 300s
    uint32_t icmp;               // ICMP: 60s
};

// 清理过期会话
static void
cleanup_expired_sessions(void *arg)
{
    struct nat_context *ctx = arg;
    uint64_t now = rte_get_tsc_Hz();

    while (ctx->running) {
        // 遍历会话（实际用更高效的方法，如超时链表）
        for (int i = 0; i < ctx->nat_table->num_entries; i++) {
            struct nat_session *s = &ctx->nat_table->sessions[i];

            uint32_t timeout = get_timeout(&ctx->timeouts, s);

            if (now - s->last_active > timeout) {
                // 删除会话
                nat_session_delete(ctx->nat_table, s);
                log_nat_entry(ctx, s, LOG_TYPE_DELETE);
            }
        }

        rte_delay_ms(1000);  // 每秒检查一次
    }
}
```

## 5. ALG (Application Layer Gateway)

### 5.1 常见 ALG 需求

| 协议 | 挑战 | NAT 处理 |
|------|------|----------|
| **FTP** | IP 在 PORT 命令中 | ALG 修改 IP |
| **H.323** | 动态端口 | ALG 打开端口 |
| **SIP** | IP/Port 在 SDP 中 | ALG 修改 SDP |
| **RTSP** | 端口在 DESCRIBE 中 | ALG 修改 |
| **P2P** | 打洞 | STUN/TURN |

### 5.2 FTP ALG

```c
// FTP PORT/EPRT 处理
static int
process_ftp_alg(struct nat_context *ctx, struct rte_mbuf *pkt,
                uint8_t *payload, uint32_t payload_len)
{
    // FTP PORT 命令格式：PORT h1,h2,h3,h4,p1,p2
    // h1-h4 = IP 地址 (192,168,1,10)
    // p1,p2 = 端口号 (高位*256 + 低位)

    if (payload_len < 6) return 0;

    // 检测 PORT 命令
    if (memcmp(payload, "PORT ", 5) == 0) {
        uint8_t ip[4];
        uint16_t port;

        // 解析 IP 和端口
        sscanf(payload + 5, "%hhu,%hhu,%hhu,%hhu,%hu,%hu",
               &ip[0], &ip[1], &ip[2], &ip[3], &port_high, &port_low);
        port = (port_high << 8) | port_low;

        // 分配新的公网端口
        uint16_t new_port = allocate_nat_port(ctx);

        // 修改 payload 中的 IP 和端口
        uint32_t nat_ip = ctx->nat_ip;
        snprintf(new_payload, sizeof(new_payload),
                 "PORT %d,%d,%d,%d,%d,%d",
                 (nat_ip >> 0) & 0xFF,
                 (nat_ip >> 8) & 0xFF,
                 (nat_ip >> 16) & 0xFF,
                 (nat_ip >> 24) & 0xFF,
                 (new_port >> 8) & 0xFF,
                 new_port & 0xFF);

        // 替换
        memcpy(payload + 5, new_payload + 5, strlen(new_payload) - 5);

        // 创建 DATA 通道映射
        create_ftp_data_channel_mapping(ctx, new_port);
    }

    // 检测 PASV 命令（服务器返回 IP:Port）
    if (memcmp(payload, "227 ", 4) == 0) {
        // 类似处理...
    }

    return 0;
}
```

## 6. 合规与日志

### 6.1 法律合规

```
NAT 日志要求（各国法律不同）：

中国：
- 留存 6 个月
- 记录：源 IP、源端口、时间、目标 IP、目标端口
- 合规：网络安全法

欧盟：
- GDPR 合规
- 数据保护

美国：
- CALEA 要求
- ISP 自愿保留
```

### 6.2 日志格式 (IPFIX/NetFlow)

```c
// IPFIX NAT 日志格式
struct nat_ipfix_log {
    uint32_t sourceIPv4Address;      // 源 IP
    uint32_t destinationIPv4Address; // 目标 IP
    uint16_t sourceTransportPort;    // 源端口
    uint16_t destinationTransportPort; // 目标端口
    uint8_t  natEvent;               // 事件类型
    uint64_t flowStartMilliseconds;  // 开始时间
    uint64_t flowEndMilliseconds;    // 结束时间
    uint32_t postNATSourceIPv4Address; // NAT 后源 IP
    uint16_t postNATSourceTransportPort; // NAT 后源端口
    uint8_t  protocolIdentifier;     // 协议
    uint64_t octetDeltaCount;        // 字节数
    uint64_t packetDeltaCount;       // 包数
};
```

## 7. 性能优化

### 7.1 批量 NAT 处理

```c
// 批量处理出向包
static uint16_t
process_batch_outbound(struct nat_context *ctx,
                       struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    uint16_t nb_sent = 0;

    for (uint16_t i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *pkt = pkts[i];

        // NAT 处理
        if (nat_outbound(ctx, pkt) == 0) {
            pkts[nb_sent++] = pkt;
        }
    }

    return nb_sent;
}

// 批量处理入向包
static uint16_t
process_batch_inbound(struct nat_context *ctx,
                      struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    uint16_t nb_sent = 0;

    for (uint16_t i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *pkt = pkts[i];

        if (nat_inbound(ctx, pkt) == 0) {
            pkts[nb_sent++] = pkt;
        }
    }

    return nb_sent;
}
```

### 7.2 连接性检测

```c
// 检测 NAT 是否可用
static int
check_nat_available(struct nat_context *ctx)
{
    // 检查可用端口数
    uint32_t available = ctx->nat_pool->total_ports -
                         ctx->nat_pool->used_ports;

    if (available < ctx->config.min_free_ports) {
        RTE_LOG(WARNING, NAT, "NAT pool exhausted: %u/%u ports used\n",
                ctx->nat_pool->used_ports,
                ctx->nat_pool->total_ports);
        return -1;
    }

    return 0;
}
```

## 8. 总结

NAT 实现要点：

1. **NAPT**：1:N 端口映射，核心是会话表
2. **CGNAT**：Port Block 分配，运营商级规模
3. **NAT444**：双重 NAT，用户侧 + 运营商侧
4. **会话管理**：rte_hash 高效查找 + 超时清理
5. **ALG**：FTP/SIP 等协议需要特殊处理
6. **合规日志**：IPFIX/NetFlow 格式留存

---

## 参考资源

- [RFC 2663 - NAT](https://tools.ietf.org/html/rfc2663)
- [RFC 6888 - CGNAT](https://tools.ietf.org/html/rfc6888)
- [RFC 6598 - Shared Address Space (100.64/10)](https://tools.ietf.org/html/rfc6598)
