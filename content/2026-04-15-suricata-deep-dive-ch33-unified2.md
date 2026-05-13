---
title: "Suricata 深度探索 (三十三)：Unified2 输出"
date: 2026-04-15
tags:
  - suricata
  - series
  - unified2
  - outputs
  - barnyard2
  - snort
description: "深入解析 Suricata 的 Unified2 输出系统：unified2 配置、Barnyard2 集成、二进制格式、以及源码实现"
---

> [!info] Suricata 2026 深度探索系列
> 0. [[2026-04-15-suricata-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-suricata-deep-dive-ch1-overview|第一章：Suricata 概述]]
> 2. [[2026-04-15-suricata-deep-dive-ch2-config|第二章：Suricata 配置系统]]
> 3. [[2026-04-15-suricata-deep-dive-ch3-runmodes|第三章：Runmodes 运行模式]]
> 4. [[2026-04-15-suricata-deep-dive-ch4-thread-model|第四章：线程模型]]
> 5. [[2026-04-15-suricata-deep-dive-ch5-capture|第五章：Capture 初始化]]
> 6. [[2026-04-15-suricata-deep-dive-ch6-af-packet|第六章：AF-PACKET 接口]]
> 7. [[2026-04-15-suricata-deep-dive-ch7-pcap|第七章：PCAP 接口]]
> 8. [[2026-04-15-suricata-deep-dive-ch8-nfq|第八章：NFQ 与 PF_RING 模式]]
> 9. [[2026-04-15-suricata-deep-dive-ch9-dpdk|第九章：DPDK 接口]]
> 10. [[2026-04-15-suricata-deep-dive-ch10-loadbalancing|第十章：多线程抓包与负载均衡]]
> 11. [[2026-04-15-suricata-deep-dive-ch11-detect-engine|第十一章：检测引擎架构]]
> 12. [[2026-04-15-suricata-deep-dive-ch12-signatures|第十二章：规则解析]]
> 13. [[2026-04-15-suricata-deep-dive-ch13-mpm|第十三章：多模式匹配]]
> 14. [[2026-04-15-suricata-deep-dive-ch14-filemagic|第十四章：文件识别]]
> 15. [[2026-04-15-suricata-deep-dive-ch15-lua-detect|第十五章：Lua 检测]]
> 16. [[2026-04-15-suricata-deep-dive-ch16-app-layer|第十六章：应用层协议解析]]
> 17. [[2026-04-15-suricata-deep-dive-ch17-http|第十七章：HTTP 协议解析]]
> 18. [[2026-04-15-suricata-deep-dive-ch18-dns|第十八章：DNS 协议解析]]
> 19. [[2026-04-15-suricata-deep-dive-ch19-tls|第十九章：TLS 协议解析]]
> 20. [[2026-04-15-suricata-deep-dive-ch20-smb|第二十章：SMB 协议解析]]
> 21. [[2026-04-15-suricata-deep-dive-ch21-http2|第二十一章：HTTP/2 协议解析]]
> 22. [[2026-04-15-suricata-deep-dive-ch22-flow|第二十二章：Flow 管理]]
> 23. [[2026-04-15-suricata-deep-dive-ch23-flow-timeout|第二十三章：Flow 超时]]
> 24. [[2026-04-15-suricata-deep-dive-ch24-flowbit|第二十四章：Flowbit 与 Flow 变量]]
> 25. [[2026-04-15-suricata-deep-dive-ch25-host|第二十五章：Host 管理]]
> 26. [[2026-04-15-suricata-deep-dive-ch26-stream|第二十六章：Stream 重组引擎]]
> 27. [[2026-04-15-suricata-deep-dive-ch27-stream-policy|第二十七章：TCP 重组策略]]
> 28. [[2026-04-15-suricata-deep-dive-ch28-stream-depth|第二十八章：Stream 深度配置]]
> 29. [[2026-04-15-suricata-deep-dive-ch29-eve|第二十九章：EVE JSON 输出]]
> 30. [[2026-04-15-suricata-deep-dive-ch30-alerts|第三十章：Alerts 输出]]
> 31. [[2026-04-15-suricata-deep-dive-ch31-stats|第三十一章：Stats 统计]]
> 32. [[2026-04-15-suricata-deep-dive-ch32-file-log|第三十二章：File Log]]
> 33. **第三十三章：Unified2**

---

## 1. Unified2 概述

Unified2 是 Snort IDS 使用的二进制日志格式，Suricata 通过 Unified2 输出兼容 Snort 的告警格式，可以与 Barnyard2 等 Snort 生态工具无缝集成。

```mermaid
graph LR
    subgraph "Suricata"
        A["Alert 生成"]
        U["Unified2 输出"]
    end
    
    subgraph "Snort 生态"
        B["Barnyard2"]
        S["Snort"]
        DB["数据库"]
        W["Web UI"]
    end
    
    subgraph "其他工具"
        B2["Basic Analysis"]
        S2["Sguil"]
        E["Enterprise"
    end
    
    A --> U
    U --> |"unified2.log"| B
    B --> DB
    B2 --> B
    S2 --> B
    E --> DB
    DB --> W
```

---

## 2. Unified2 配置详解

### 2.1 基础配置

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      # 输出文件
      filename: unified2.log
      
      # 每批次记录数
      batch-size: 100
      
      # 是否包含额外数据
      xff:
        enabled: no
        
      # 告警格式
      alert-variant: 2
```

### 2.2 扩展配置

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      filename: /var/log/suricata/unified2.log
      
      # 类型配置
      types:
        - alert:
            # 是否包含数据包
            include-packet-data: yes
            
            # 保存在 unified2 中的数据包数量
            packet-data-limit: 2
            
            # 是否包含应用层数据
            app-layer-event: yes
            
        - file-log:
            # 是否记录文件信息
            enabled: yes
```

### 2.3 Barnyard2 兼容配置

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      # Barnyard2 兼容格式
      filename: unified2.log
      
      # 关闭 Suricata 特有的扩展
      nostamp: yes
      
      # 启用 Barnyard2 兼容模式
      barnyard2:
        enabled: yes
```

---

## 3. Unified2 二进制格式

### 3.1 Unified2 文件头

```c
// src/output-unified2.h — Unified2 头
typedef struct Unified2FileHeader_ {
    /* 文件类型标识 */
    uint32_t type;          // UNIFIED2_FILE_TYPE = 2
    
    /* 版本 */
    uint32_t version;       // UNIFIED2_VERSION = 20141007
    
    /* 传感器 ID */
    uint32_t sensor_id;
    
    /* 签名总数（初始为 0） */
    uint32_t sig_count;
    
    /* 事件总数（初始为 0） */
    uint32_t event_count;
    
} Unified2FileHeader;

/*
 * Unified2 File Header (20 bytes)
 * +----------------+----------------+----------------+----------------+
 * |     Type       |    Version    |   Sensor ID   |   Sig Count   |
 * +----------------+----------------+----------------+----------------+
 * |                          Event Count                              |
 * +----------------+----------------+----------------+----------------+
 */
```

### 3.2 Unified2 Event (Event Type 2)

```c
// src/output-unified2.h — Unified2 Event
typedef struct Unified2Event_ {
    /* 事件类型 */
    uint32_t type;          // UNIFIED2_IDS_EVENT = 2
    
    /* 事件 ID */
    uint32_t event_id;
    
    /* 事件时间戳 */
    uint32_t event_second;   // 秒
    uint32_t event_microsecond;  // 微秒
    
    /* 触发规则信息 */
    uint32_t signature_id;   // 规则 ID (snort g_id/s_id)
    uint32_t generator_id;  // 生成器 ID (snort GID)
    
    /* 签名 revision */
    uint32_t signature_revision;
    
    /* 分类 ID */
    uint32_t classification_id;
    
    /* 优先级 */
    uint32_t priority;
    
    /* 源 IP */
    uint32_t src_ip[4];      // IPv6 支持
    
    /* 目标 IP */
    uint32_t dst_ip[4];      // IPv6 支持
    
    /* 源端口/协议 */
    uint16_t src_port;
    uint8_t  protocol;        // 6=TCP, 17=UDP, 1=ICMP
    
    /* 目标端口/协议 */
    uint16_t dst_port;
    uint8_t  dest_protocol;
    
    /* 触发标志 */
    uint8_t  impact_flag;    // 0=blocked, 1=whitlisted, 2=blacklisted
    
    /* 阻塞标志 */
    uint8_t  blocked;
    
    /* Flow 标签 */
    uint32_t flow_label;
    
} Unified2Event;

/*
 * Unified2 IDS Event (72 bytes for IPv4)
 * +----------------+----------------+----------------+----------------+
 * |     Type=2     |   Event ID    |  Event Second  | Event USec    |
 * +----------------+----------------+----------------+----------------+
 * |  Signature ID  |  Generator ID | Sig Revision   |  Class ID     |
 * +----------------+----------------+----------------+----------------+
 * |   Priority     |         Source IP (4 bytes)                       |
 * +----------------+----------------+----------------+----------------+
 * |       ...      |         Dest IP (4 bytes)                         |
 * +----------------+----------------+----------------+----------------+
 * |  Src Port      |  Protocol     |  Dst Port      |  Dest Proto   |
 * +----------------+----------------+----------------+----------------+
 * | Impact Flag    |   Blocked     |    Flow Label                            |
 * +----------------+----------------+----------------+
 */
```

### 3.3 Unified2 Packet 数据

```c
// src/output-unified2.h — Unified2 Packet
typedef struct Unified2Packet_ {
    /* 事件类型 */
    uint32_t type;           // UNIFIED2_IDS_EVENT_PKT = 7
    
    /* 事件 ID */
    uint32_t event_id;
    uint32_t event_second;
    
    /* 包数据长度 */
    uint32_t packet_length;
    
    /* Packet 数据 */
    uint8_t packet_data[65535];  // 实际包数据
    
    /* 原始数据包头 */
    uint32_t original_packet_length;
    
    /* 接口索引 */
    uint32_t ifindex;
    
    /* VLAN ID */
    uint16_t vlan_id;
    
    /* 填充 */
    uint16_t pad;
    
} Unified2Packet;
```

### 3.4 事件与包的关联

```
Unified2 日志结构：

File Header (20 bytes)
|
+-- Event Type 2 (72 bytes) --+
|  Event ID = 1234            |
|  Signature ID = 1000001    |
|  Src/Dst IP/Port           |
+-----------------------------+
|
+-- Event Type 7 (Packet) --+
|  Event ID = 1234          |
|  Packet Data              |
+---------------------------+
|
+-- Event Type 7 (Packet) --+
|  Event ID = 1234          |
|  Packet Data              |
+---------------------------+
|
+-- Event Type 2 (Next) --+
|  Event ID = 1235        |
...
```

---

## 4. Unified2 源码实现

### 4.1 Unified2 输出初始化

```c
// src/output-unified2.c — Unified2 初始化
static OutputInitResult OutputUnified2LogInit(ConfNode *conf)
{
    OutputUnified2Context *ctx = SCCalloc(1,
        sizeof(OutputUnified2Context));
    if (ctx == NULL) {
        return ResultInitFail;
    }
    
    /* 获取文件名 */
    const char *filename = ConfNodeLookupChildValue(conf, "filename");
    if (filename != NULL) {
        ctx->filename = SCStrdup(filename);
    } else {
        ctx->filename = SCStrdup("unified2.log");
    }
    
    /* 获取批次大小 */
    const char *batch_str = ConfNodeLookupChildValue(conf, "batch-size");
    if (batch_str != NULL) {
        ctx->batch_size = atoi(batch_str);
    } else {
        ctx->batch_size = 100;
    }
    
    /* 初始化文件 */
    ctx->fp = fopen(ctx->filename, "wb");
    if (ctx->fp == NULL) {
        SCLogError("Failed to open unified2 file: %s",
                   ctx->filename);
        SCFree(ctx);
        return ResultInitFail;
    }
    
    /* 写入文件头 */
    Unified2WriteFileHeader(ctx->fp);
    
    /* 注册输出 */
    OutputRegisterUnified2Logger(&ctx->module, ctx);
    
    return ResultOk;
}
```

### 4.2 文件头写入

```c
// src/output-unified2.c — 写入文件头
static int Unified2WriteFileHeader(FILE *fp)
{
    Unified2FileHeader header;
    
    /* 填充文件头 */
    header.type = UNIFIED2_FILE_TYPE;
    header.version = UNIFIED2_VERSION;
    header.sensor_id = 1;
    header.sig_count = 0;
    header.event_count = 0;
    
    /* 写入文件 */
    if (fwrite(&header, sizeof(header), 1, fp) != 1) {
        return -1;
    }
    
    /* 刷新缓冲区 */
    fflush(fp);
    
    return 0;
}
```

### 4.3 Event 写入

```c
// src/output-unified2.c — Event 写入
static int Unified2WriteEvent(FILE *fp, const Packet *p,
                               const Alert *alert)
{
    Unified2Event event;
    
    /* 填充 Event */
    event.type = UNIFIED2_IDS_EVENT;
    event.event_id = p->pkt_src << 16 | (p->ts.tv_sec & 0xFFFF);
    event.event_second = p->ts.tv_sec;
    event.event_microsecond = p->ts.tv_usec;
    
    /* 规则信息 */
    event.signature_id = alert->signature_id;
    event.generator_id = alert->gid;
    event.signature_revision = alert->rev;
    event.classification_id = alert->class_id;
    event.priority = alert->severity;
    
    /* IP 地址 */
    if (PKT_IS_IPV4(p)) {
        event.src_ip[0] = ntohl(p->src.ipv4);
        event.dst_ip[0] = ntohl(p->dst.ipv4);
        memset(&event.src_ip[1], 0, 12);
        memset(&event.dst_ip[1], 0, 12);
    } else if (PKT_IS_IPV6(p)) {
        /* IPv6 */
        memcpy(event.src_ip, &p->src.ipv6, 16);
        memcpy(event.dst_ip, &p->dst.ipv6, 16);
    }
    
    /* 端口和协议 */
    event.src_port = p->sp;
    event.protocol = IP_GET_IPPROTO(p);
    event.dst_port = p->dp;
    event.dest_protocol = IP_GET_IPPROTO(p);
    
    /* 标志 */
    event.impact_flag = 0;
    event.blocked = (p->verdict == VERDICT_DROP) ? 1 : 0;
    event.flow_label = p->flow_id;
    
    /* 写入文件 */
    if (fwrite(&event, sizeof(event), 1, fp) != 1) {
        return -1;
    }
    
    return 0;
}
```

### 4.4 Packet 数据写入

```c
// src/output-unified2.c — Packet 数据写入
static int Unified2WritePacket(FILE *fp, const Packet *p)
{
    Unified2PacketHeader pkthdr;
    
    /* 检查是否需要记录包数据 */
    if (!PacketAlertCheck(p, PACKET_ALERT_FLAG_DONT_STORE)) {
        return 0;
    }
    
    /* 填充 Packet 头 */
    pkthdr.type = UNIFIED2_IDS_EVENT_PKT;
    pkthdr.event_id = p->pkt_src << 16 | (p->ts.tv_sec & 0xFFFF);
    pkthdr.event_second = p->ts.tv_sec;
    pkthdr.packet_length = p->pkt_len;
    
    /* 写入 Packet 头 */
    if (fwrite(&pkthdr, sizeof(pkthdr), 1, fp) != 1) {
        return -1;
    }
    
    /* 写入包数据 */
    if (p->pkt_len > 0) {
        if (fwrite(p->pkt, p->pkt_len, 1, fp) != 1) {
            return -1;
        }
    }
    
    return 0;
}
```

---

## 5. Barnyard2 集成

### 5.1 Barnyard2 概述

Barnyard2 是 Snort IDS 的快速日志输出器，读取 Unified2 格式日志并输出到数据库或其他目的地。

```
Barnyard2 处理流程：

unified2.log  -->  Barnyard2  -->  MySQL/PostgreSQL
                         |
                         +-->  Splunk
                         |
                         +-->  Sguil
                         |
                         +-->  BASE
```

### 5.2 Barnyard2 配置

```bash
# /etc/barnyard2.conf
config reference_file:      /etc/snort/reference.config
config classification_file: /etc/snort/classification.config
config gen_file:           /etc/snort/gen-msg.map
config sid_file:           /etc/snort/sid-msg.map

# 数据库输出
output database: log, mysql, user=snort password=snort dbname=snort host=localhost

# Unified2 输入
input unified2: /var/log/suricata/unified2.log
```

### 5.3 启动 Barnyard2

```bash
# 手动启动
barnyard2 -c /etc/barnyard2.conf -f unified2.log -D

# 指定传感器 ID
barnyard2 -c /etc/barnyard2.conf -f unified2.log -s 1 -D

# 实时监控新文件
barnyard2 -c /etc/barnyard2.conf -f unified2.log -w /var/log/suricata/unified2.log.idx -D
```

---

## 6. Unified2 与 Suricata 特有功能

### 6.1 Suricata 特有 Event 类型

```c
// Suricata 扩展的 Unified2 Event 类型
#define UNIFIED2_SURI_EVENT_TYPE_FILE     1001
#define UNIFIED2_SURI_EVENT_TYPE_FLOW     1002
#define UNIFIED2_SURI_EVENT_TYPE_SSH      1003
```

### 6.2 Suricata 文件日志扩展

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      types:
        - file-log:
            enabled: yes
            
            # 记录文件信息
            file:
              enabled: yes
              include-hashes: md5,sha1,sha256
              
            # 记录文件内容
            store-files: yes
            store-dir: /var/log/suricata/unified2-files
```

### 6.3 Suricata Flow 扩展

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      types:
        - flow:
            enabled: no
            # Flow 日志需要 Barnyard2 支持
```

---

## 7. Unified2 文件 Rotation

### 7.1 自动 Rotation

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      filename: /var/log/suricata/unified2.log
      
      # Rotation 配置
      limit: 1000  # 文件大小限制（MB）
```

### 7.2 手动 Rotation

```bash
# 发送 USR1 信号
killall -USR1 suricata

# 文件会 rotation 为 unified2.log.1, unified2.log.2, ...
```

### 7.3 Barnyard2 增量读取

```bash
# 使用 -w 参数记录处理位置
barnyard2 -c /etc/barnyard2.conf \
    -f unified2.log \
    -w /var/log/suricata/unified2.log.idx

# Barnyard2 会在索引文件中记录已处理的位置
# 重启后从上次位置继续处理
```

---

## 8. 数据库 Schema

### 8.1 Snort/Barnyard2 Schema

```sql
-- event 表
CREATE TABLE event (
    sid INT UNSIGNED NOT NULL,
    cid INT UNSIGNED NOT NULL,
    signature INT UNSIGNED NOT NULL,
    timestamp DATETIME NOT NULL,
    PRIMARY KEY (sid, cid)
);

-- signature 表
CREATE TABLE signature (
    sig_id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sig_name VARCHAR(255),
    sig_class_id INT UNSIGNED,
    sig_priority INT,
    sig_rev INT UNSIGNED,
    sig_gid INT UNSIGNED
);

-- icmphdr 表
CREATE TABLE icmphdr (
    sid INT UNSIGNED NOT NULL,
    cid INT UNSIGNED NOT NULL,
    icmp_type TINYINT UNSIGNED NOT NULL,
    icmp_code TINYINT UNSIGNED NOT NULL,
    PRIMARY KEY (sid, cid)
);

-- tcphdr 表
CREATE TABLE tcphdr (
    sid INT UNSIGNED NOT NULL,
    cid INT UNSIGNED NOT NULL,
    tcp_sport INT UNSIGNED NOT NULL,
    tcp_dport INT UNSIGNED NOT NULL,
    PRIMARY KEY (sid, cid)
);

-- udphdr 表
CREATE TABLE udphdr (
    sid INT UNSIGNED NOT NULL,
    cid INT UNSIGNED NOT NULL,
    udp_sport INT UNSIGNED NOT NULL,
    udp_dport INT UNSIGNED NOT NULL,
    PRIMARY KEY (sid, cid)
);
```

---

## 9. 性能考虑

### 9.1 写入性能

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      # 批量写入
      batch-size: 500
      
      # 使用缓冲
      buffered: yes
      
      # 异步写入
      async: yes
```

### 9.2 文件大小控制

```yaml
# suricata.yaml
outputs:
  - unified2:
      enabled: yes
      
      # 文件大小限制（MB）
      limit: 100
```

---

## 10. 常见问题

### 10.1 Barnyard2 无法解析

**检查**：
- 确认 unified2 版本兼容
- 检查 `barnyard2 -c /etc/barnyard2.conf --test-unity2 /path/to/file`
- 查看 Barnyard2 版本是否支持 Suricata 扩展

### 10.2 事件丢失

**原因**：
- Rotation 太快
- Barnyard2 处理不及时

**解决**：
```yaml
outputs:
  - unified2:
      enabled: yes
      
      # 增大文件限制
      limit: 5000
```

### 10.3 数据库性能

**优化**：
- 使用批量插入
- 配置合适的索引
- 考虑使用 PostgreSQL 替代 MySQL
