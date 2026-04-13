---
title: 基于memif的合规流量留存与审计方案
date: 2026-04-10 14:30:00
tags: [memif, DPDK, Suricata, Arkime, 等保2.0, 密评, 合规, 流量留存]
---

> [!abstract] 概述
>
> 本文阐述基于DPDK memif技术的高性能合规流量留存与审计方案。通过memif零拷贝共享内存机制，实现全量流量同时供给Suricata（检测）和Arkime（存储），满足等保2.0、密评、金融/政企流量留存与审计要求。

# 基于memif的合规流量留存与审计方案

## 1. 背景与需求

### 1.1 合规要求

```
┌─────────────────────────────────────────────────────────────────────┐
│                       合规要求概述                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  等保2.0 三级                                                        │
│  ├── 网络边界防火墙                                                  │
│  ├── 入侵检测 (IDS/IPS)                                             │
│  ├── 日志留存 ≥ 6个月                                               │
│  ├── 流量审计                                                       │
│  ├── 完整会话回放                                                   │
│  └── 异常行为告警                                                   │
│                                                                     │
│  密评 (密码应用安全性评估)                                          │
│  ├── TLS流量解密审计                                                │
│  ├── 国密算法支持 (SM2/SM3/SM4)                                     │
│  ├── 加密流量可检索                                                 │
│  └── 密钥生命周期审计                                               │
│                                                                     │
│  金融/政企流量留存                                                  │
│  ├── 全量pcap留存                                                   │
│  ├── 6个月+留存周期                                                │
│  ├── 防篡改 (完整性校验)                                           │
│  ├── 可查询/可回放                                                  │
│  └── 司法取证支持                                                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 传统方案问题

```
传统单网卡分路方案:

DPDK网卡 ──> Suricata (拿走所有包)
              │
              └──> 转发Arkime? ──> 性能差，走协议栈

或:

DPDK网卡 ──> Arkime (拿走所有包)
              │
              └──> 转发Suricata? ──> 不支持

问题:
├── Suricata/Arkime只能绑定网卡收包，不能接收外部推送
├── AF-Packet走内核，性能瓶颈
├── 虚拟网卡 (vhost-user) 性能更差
└── 无法实现全量流量同时检测+存储
```

## 2. 整体架构

### 2.1 架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   高速网络入口                                                       │
│        │                                                            │
│        ▼                                                            │
│   ┌─────────────┐                                                  │
│   │  10G/25G/100G │                                                  │
│   │  DPDK网卡     │                                                  │
│   └──────┬──────┘                                                  │
│          │                                                           │
│          ▼                                                           │
│   ┌─────────────────┐                                               │
│   │   DPDK分流器      │  ← memif master                             │
│   │  (Packet Clone)  │                                              │
│   │                   │                                              │
│   │  ┌─────────────┐  │                                              │
│   │  │  memif Ring │  │  ← 共享内存无锁队列                         │
│   │  │  (大页内存) │  │                                              │
│   │  └─────────────┘  │                                              │
│   └──────────┬────────┘                                              │
│              │                                                       │
│      ┌───────┴───────┐                                               │
│      │               │                                               │
│      ▼               ▼                                               │
│  ┌────────┐    ┌────────┐                                           │
│  │Suricata│    │ Arkime │                                           │
│  │  memif │    │  memif │                                           │
│  │  slave │    │  slave │                                           │
│  └────┬───┘    └────┬───┘                                           │
│       │             │                                                │
│       │             │                                                │
│       ▼             ▼                                                │
│  ┌─────────┐  ┌─────────┐                                           │
│  │ eve.json│  │  pcap   │                                           │
│  │  告警日志│  │  存储   │                                           │
│  └────┬────┘  └────┬────┘                                           │
│       │            │                                                │
│       └─────┬──────┘                                                │
│             ▼                                                        │
│      ┌─────────────┐                                                 │
│      │Elasticsearch│                                                 │
│      │  (元数据)   │                                                 │
│      └──────┬──────┘                                                 │
│             │                                                         │
│             ▼                                                         │
│      ┌─────────────┐                                                 │
│      │   Kibana    │                                                 │
│      │ 合规报告/审计│                                                 │
│      └─────────────┘                                                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 组件职责

```
┌─────────────────────────────────────────────────────────────────────┐
│                         组件职责                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  DPDK分流器 (memif master)                                          │
│  ├── 绑定DPDK网卡，全量收包                                         │
│  ├── memif ring 零拷贝分发                                          │
│  ├── 包克隆 (全量复制)                                               │
│  ├── 支持多memif连接 (扩展到N个消费端)                               │
│  └── 实现: MoonGen / 自研 / Pktgen-DPDK                             │
│                                                                     │
│  Suricata (memif slave)                                             │
│  ├── 从memif ring接收包                                             │
│  ├── IDS/IPS检测                                                    │
│  ├── 输出eve.json告警                                               │
│  ├── 文件提取                                                       │
│  └── 支持国密检测 (TLS1.2/1.3解密)                                  │
│                                                                     │
│  Arkime (memif slave)                                               │
│  ├── 从memif ring接收包                                             │
│  ├── 全量pcap存储                                                   │
│  ├── 元数据索引 (ES)                                                │
│  ├── 完整会话回放                                                   │
│  └── 长期留存 (分层存储)                                            │
│                                                                     │
│  Elasticsearch + Kibana                                             │
│  ├── Suricata告警日志                                               │
│  ├── Arkime元数据                                                   │
│  ├── 合规审计报告                                                   │
│  └── ATT&CK映射                                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 3. memif技术原理

### 3.1 memif定义

```
memif = Memory Interface

DPDK官方库: lib/memif

定位: DPDK原生进程间共享内存通信机制

特点:
├── 共享内存环形队列
├── 无锁队列，直接指针操作
├── 全双工通信
├── 零拷贝 (指针传递，不拷贝数据)
└── 专为高速场景设计
```

### 3.2 零拷贝原理

```
┌─────────────────────────────────────────────────────────────────────┐
│                         零拷贝原理                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  传统方式 (多次拷贝):                                                │
│                                                                     │
│  NIC ──DMA──> mbuf ──clone──> mbuf_copy ──virtio──> skb            │
│                                          │                           │
│                                    内核拷贝                         │
│                                                                     │
│  memif方式 (零拷贝):                                                │
│                                                                     │
│  NIC ──DMA──> mbuf (在共享大页内存中)                               │
│                  │                                                   │
│                  │ 指针传递，不拷贝数据                              │
│                  ▼                                                  │
│          ┌───────────────┐                                          │
│          │  memif ring   │  ← 无锁队列，指针数组                     │
│          │  (共享大页)   │                                          │
│          └───────┬───────┘                                          │
│                  │                                                  │
│           ┌──────┴──────┐                                           │
│           │             │                                           │
│           ▼             ▼                                           │
│      Suricata        Arkime                                         │
│      (读指针)        (读指针)                                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.3 性能对比

```
┌─────────────────────────────────────────────────────────────────────┐
│                        延迟对比                                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  AF-Packet:    50-100μs                                            │
│  PF-RING ZC:   10-20μs                                             │
│  memif:        2-5μs                                               │
│  vhost-user:   100-500μs                                           │
│                                                                     │
│  memif vs AF-Packet: ~20x 性能提升                                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                        吞吐能力                                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  10G链路:                                                            │
│  ├── Suricata: ~8Gbps 检测吞吐                                      │
│  ├── Arkime: ~9Gbps 存储吞吐                                        │
│  └── memif延迟: < 2μs                                               │
│                                                                     │
│  25G链路:                                                            │
│  ├── Suricata: ~20Gbps 检测吞吐                                     │
│  ├── Arkime: ~22Gbps 存储吞吐                                       │
│  └── memif延迟: < 3μs                                               │
│                                                                     │
│  100G链路 (2x50G):                                                  │
│  ├── Suricata: ~40Gbps 检测吞吐                                     │
│  ├── Arkime: ~45Gbps 存储吞吐                                       │
│  └── memif延迟: < 5μs                                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 4. 核心配置

### 4.1 DPDK分流器 (master)

```c
// 分流器核心逻辑 - memif_master.c

#include <rte_eal.h>
#include <rte_memzone.h>
#include <rte_mempool.h>
#include <rte_mbuf.h>
#include <rte_ethdev.h>
#include <memif.h>

#define MAX_PKT_BURST 32
#define MEMIF_SHM_SIZE (2UL * 1024 * 1024 * 1024)  // 2GB

struct memif_conn {
    int fd;
    struct memif_conn_shAreaDescription *shm_area;
    struct memif_ring *ring;
    uint16_t head;
    uint16_t tail;
};

static struct memif_socket *sock;
static struct memif_conn *conn_suricata;
static struct memif_conn *conn_arkime;
static struct rte_mempool *mbuf_pool;

int main(int argc, char **argv)
{
    // EAL初始化
    rte_eal_init(argc, argv);

    // 创建大页共享内存
    const struct rte_memzone *mz = rte_memzone_reserve(
        "memif-shm",
        MEMIF_SHM_SIZE,
        rte_socket_id(),
        RTE_MEMZONE_2MB_SHM | RTE_MEMZONE_IOVA_CONTIG
    );

    // 创建memif socket
    memif_socket_create(&sock, "/var/run/memif.sock", 0);

    // 创建到Suricata的连接
    memif_create(&conn_suricata, sock,
                  MEMIF_APP_TYPE_L2_SHIFT,
                  "suricata-conn",
                  0,  // buffer size
                  2048,  // ring size
                  MEMIF_CONN_FLAGS_SERVER);

    // 创建到Arkime的连接
    memif_create(&conn_arkime, sock,
                  MEMIF_APP_TYPE_L2_SHIFT,
                  "arkime-conn",
                  0,
                  2048,
                  MEMIF_CONN_FLAGS_SERVER);

    // DPDK网卡初始化 (省略，具体见DPDK文档)
    dpdk_port_init();

    // 主循环
    while (1) {
        struct rte_mbuf *pkts[MAX_PKT_BURST];
        uint16_t nb_rx = rte_eth_rx_burst(port_id, queue, pkts, MAX_PKT_BURST);

        for (int i = 0; i < nb_rx; i++) {
            // 克隆mbuf (Arkime需要独立副本)
            struct rte_mbuf *clone = rte_pktmbuf_clone(pkts[i], mbuf_pool);

            // 发往Suricata (原始包)
            memif_tx_burst(conn_suricata, &pkts[i], 1);

            // 发往Arkime (克隆包)
            memif_tx_burst(conn_arkime, &clone, 1);
        }

        // 释放原始包
        rte_pktmbuf_free_bulk(pkts, nb_rx);
    }
}
```

### 4.2 Suricata (slave)

```yaml
# suricata.yaml

# 传统DPDK配置
dpdk:
  - enabled: false

# memif slave配置 (需要开发支持或使用PF-RING)
memif:
  enabled: true
  socket: /var/run/memif.sock
  conn-name: suricata
  role: slave
  ring-size: 2048

# 检测输出配置
outputs:
  - eve-log:
      enabled: yes
      type: file
      filename: eve.json
      types:
        - alert
        - http
        - dns
        - tls
        - ssh
        - smb
        - files
        - tls
          extended: yes
        - metadata

  - http-log:
      enabled: yes
      filename: http.log
      payload: yes
      payload-printable: yes

  - dns-log:
      enabled: yes
      filename: dns.log
      query: yes
      answer: yes

  - stats:
      enabled: yes
      interval: 10

# 检测规则
rule-files:
  - /etc/suricata/rules/app-layer-events.rules
  - /etc/suricata/rules/decoder-events.rules
  - /etc/suricata/rules/stream-events.rules
  - /etc/suricata/rules/tls-events.rules

# TLS解密 (满足密评要求)
libhtp:
  default-config:
    personality: IDS
    request-body-limit: 100kb
    response-body-limit: 100kb

# 国密检测规则示例
# /etc/suricata/rules/gms.rules
# alert tls any any -> any any (msg:"国密SM4检测"; tls.subject; content:"CN=*.gms.cn"; sid:1000001;)
```

### 4.3 Arkime (slave)

```ini
# etc/settings.ini

[capture]
# memif配置
memif=true
memifSocket=/var/run/memif.sock
memifConnName=arkime
memifRole=slave
memifRxSize=2048

# 节点配置
nodeName=arkime-node1
```

```ini
# etc/viewer.ini

[elasticsearch]
url=https://elasticsearch:9200
# 基础索引
elasticsearchPrefix=arkime
# 复制份数
es副本数=3
# 分片数
es分片数=5

# Arkime配置
[bulk]
writeSize=10000
flushTimeout=5

[storage]
# 热数据存储 (SSD, 最近3个月)
# 配置Arkime的rotate和保存策略
```

### 4.4 Arkime存储配置 (满足6个月留存)

```ini
# etc/viewer.ini
[storage]
# 热数据 (SSD, 3个月)
# 配置本地NVMe存储
pcapDir=/data/arkime-hot

# 存储策略
rotateInterval=86400
compress=true
retentionDays=180

# 分层存储 (需要企业版或脚本)
# warmStorage=/data/arkime-warm
# coldStorage=s3://archive-bucket
# 存储切换策略通过外部脚本实现
```

## 5. 分层存储架构

### 5.1 存储分层

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Arkime 分层存储                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  热数据层 (Hot)                                                      │
│  ├── 存储: SSD/NVMe                                                 │
│  ├── 时长: 最近3个月                                                 │
│  ├── 查询: 实时全文搜索                                             │
│  ├── 用途: 日常安全监控/事件响应                                     │
│  └── 容量估算: 10Gbps x 90天 ≈ 10TB                                 │
│                                                                     │
│  温数据层 (Warm)                                                     │
│  ├── 存储: HDD/SAS                                                   │
│  ├── 时长: 3-6个月                                                   │
│  ├── 查询: 较慢 (~分钟级)                                           │
│  ├── 用途: 合规审计/事件追溯                                        │
│  └── 容量估算: 10Gbps x 90天 ≈ 10TB                                 │
│                                                                     │
│  冷数据层 (Cold)                                                     │
│  ├── 存储: 对象存储 (S3/MinIO/Ceph)                                 │
│  ├── 时长: 6个月-1年                                                 │
│  ├── 查询: 需要预提取 (~小时级)                                      │
│  ├── 用途: 归档留存/司法取证                                         │
│  └── 容量估算: 10Gbps x 180天 ≈ 20TB                                │
│                                                                     │
│  存储切换策略:                                                       │
│  ├── hot -> warm: 90天后自动迁移                                    │
│  ├── warm -> cold: 180天后自动迁移                                   │
│  └── cold -> 删除: 365天后(可配置)                                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 存储迁移脚本

```bash
#!/bin/bash
# arkime_migration.sh - Arkime存储迁移脚本

HOT_DIR="/data/arkime-hot"
WARM_DIR="/data/arkime-warm"
COLD_DIR="s3://arkime-archive-bucket"

# 热数据迁移到温数据 (90天前)
migrate_to_warm() {
    find $HOT_DIR -type f -mtime +90 | while read file; do
        mv $file $WARM_DIR/
        # 记录迁移日志
        echo "$(date) migrate $file to warm" >> /var/log/arkime-migration.log
    done
}

# 温数据迁移到冷数据 (180天前)
migrate_to_cold() {
    find $WARM_DIR -type f -mtime +180 | while read file; do
        aws s3 cp $file $COLD_DIR/
        rm $file
        # 记录迁移日志
        echo "$(date) migrate $file to cold" >> /var/log/arkime-migration.log
    done
}

# 每天执行
migrate_to_warm
migrate_to_cold
```

## 6. 完整性校验 (防篡改)

### 6.1 写入时哈希

```
┌─────────────────────────────────────────────────────────────────────┐
│                        证据完整性保护                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. 写入时哈希                                                       │
│     pcap文件 -> SHA256 -> 存储 + 记录到ES                            │
│                                                                     │
│  2. 定期完整性校验                                                   │
│     ┌──────────────────┐                                           │
│     │ 每日定时任务       │                                           │
│     │ 计算当前pcap SHA256│                                           │
│     │ 对比原始记录        │                                           │
│     │ 不一致 -> 告警      │                                           │
│     └──────────────────┘                                           │
│                                                                     │
│  3. 操作审计日志                                                     │
│     谁在什么时间访问了什么pcap                                       │
│     记录到独立的审计ES索引                                           │
│                                                                     │
│  4. WORM存储 (可选)                                                  │
│     写入后不可删除/修改                                              │
│     满足金融监管要求                                                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 6.2 完整性校验脚本

```python
#!/usr/bin/env python3
# integrity_check.py - pcap完整性校验

import hashlib
import elasticsearch
from datetime import datetime, timedelta
import os

ES_HOST = "https://elasticsearch:9200"
PCAP_DIR = "/data/arkime-hot"
INDEX_NAME = "arkimeIntegrity"

def calculate_sha256(filepath):
    """计算文件SHA256"""
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()

def check_integrity():
    """检查所有pcap文件完整性"""
    es = elasticsearch.Elasticsearch([ES_HOST])

    # 查找最近7天的pcap
    pcap_files = []
    for root, dirs, files in os.walk(PCAP_DIR):
        for f in files:
            if f.endswith('.pcap'):
                filepath = os.path.join(root, f)
                mtime = datetime.fromtimestamp(os.path.getmtime(filepath))
                if mtime > datetime.now() - timedelta(days=7):
                    pcap_files.append(filepath)

    # 逐个校验
    for pcap_file in pcap_files:
        current_hash = calculate_sha256(pcap_file)

        # 查询ES中存储的原始哈希
        query = {
            "query": {
                "term": {"filename": os.path.basename(pcap_file)}
            }
        }
        result = es.search(index=INDEX_NAME, body=query)

        if result['hits']['total']['value'] > 0:
            stored_hash = result['hits']['hits'][0]['_source']['sha256']

            if current_hash != stored_hash:
                print(f"[ALERT] 文件被篡改: {pcap_file}")
                # 发送告警
                send_alert(pcap_file, current_hash, stored_hash)
        else:
            # 新文件，记录哈希
            doc = {
                "filename": os.path.basename(pcap_file),
                "sha256": current_hash,
                "checked_at": datetime.now().isoformat(),
                "filepath": pcap_file
            }
            es.index(index=INDEX_NAME, body=doc)

if __name__ == "__main__":
    check_integrity()
```

## 7. 合规报告生成

### 7.1 报告内容

```
┌─────────────────────────────────────────────────────────────────────┐
│                        合规报告模板                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  📊 流量概览                                                         │
│  ├── 总流量大小                                                      │
│  ├── 连接数/会话数                                                   │
│  └── 协议分布 (HTTP/DNS/TLS/SMB等)                                  │
│                                                                     │
│  🚨 安全告警统计                                                     │
│  ├── 告警总数 (按严重程度: 严重/高/中/低)                           │
│  ├── TOP攻击类型                                                     │
│  ├── 失陷主机列表                                                    │
│  └── ATT&CK战术分布                                                  │
│                                                                     │
│  📋 合规状态                                                         │
│  ├── pcap留存天数                                                    │
│  ├── 完整性校验结果                                                  │
│  └── 访问审计记录                                                     │
│                                                                     │
│  🔍 异常行为检测                                                     │
│  ├── Beaconing检测 (C2通信)                                         │
│  ├── 横向移动                                                        │
│  └── 数据外泄可疑流量                                                │
│                                                                     │
│  📝 密评相关                                                         │
│  ├── TLS版本分布                                                     │
│  ├── 国密使用情况                                                    │
│  └── 加密流量占比                                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 7.2 报告生成脚本

```python
#!/usr/bin/env python3
# compliance_report.py - 合规报告生成

from elasticsearch import Elasticsearch
from datetime import datetime, timedelta
from jinja2 import Template
import smtplib
from email.mime.text import MIMEText

ES_HOST = "https://elasticsearch:9200"

def generate_report():
    es = Elasticsearch([ES_HOST])

    # 统计告警
    alert_query = {
        "query": {
            "range": {
                "@timestamp": {
                    "gte": "now-30d",
                    "lte": "now"
                }
            }
        },
        "aggs": {
            "by_severity": {
                "terms": {"field": "alert.signature.severity"}
            },
            "by_type": {
                "terms": {"field": "alert.signature.name", "size": 10}
            }
        }
    }

    # 流量统计
    flow_query = {
        "query": {
            "range": {
                "@timestamp": {
                    "gte": "now-30d",
                    "lte": "now"
                }
            }
        },
        "aggs": {
            "total_bytes": {"sum": {"field": "bytes"}},
            "total_packets": {"sum": {"field": "packets"}}
        }
    }

    # 生成报告
    report = {
        "generate_time": datetime.now().isoformat(),
        "period": "过去30天",
        "alert_stats": es.search(index="suricata*", body=alert_query),
        "flow_stats": es.search(index="arkime*", body=flow_query),
        "integrity_check": check_integrity_status(),
        "recommendations": generate_recommendations()
    }

    return report

def send_report(report):
    """发送报告邮件"""
    template = """
    合规审计报告 - {{ generate_time }}
    ======================================

    报告周期: {{ period }}

    一、流量概览
    -----------
    总流量: {{ flow_stats.total_bytes }} GB
    总会话: {{ flow_stats.total_packets }} 个

    二、安全告警
    -----------
    严重告警: {{ alert_stats.critical }} 个
    高危告警: {{ alert_stats.high }} 个
    中危告警: {{ alert_stats.medium }} 个
    低危告警: {{ alert_stats.low }} 个

    三、完整性校验
    -------------
    校验通过: {{ integrity_check.passed }}
    校验失败: {{ integrity_check.failed }}

    四、建议
    --------
    {% for rec in recommendations %}
    - {{ rec }}
    {% endfor %}
    """

    msg = MIMEText(Template(template).render(**report))
    msg['Subject'] = f"合规审计报告 - {datetime.now().strftime('%Y-%m-%d')}"
    msg['From'] = 'security@company.com'
    msg['To'] = 'compliance@company.com'

    with smtplib.SMTP('smtp.company.com') as server:
        server.send_message(msg)
```

## 8. 部署拓扑

```
┌─────────────────────────────────────────────────────────────────────┐
│                        生产环境部署                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│     路由器/防火墙                                                    │
│          │                                                           │
│          │ 10G/25G光纤                                               │
│          ▼                                                           │
│   ┌──────────────┐                                                  │
│   │   TAP分光器   │  ← 可选: 如果需要物理隔离                        │
│   └──────┬───────┘                                                  │
│          │                                                           │
│          ▼                                                           │
│   ┌──────────────┐                                                  │
│   │  服务器 (2U)  │                                                  │
│   │              │                                                  │
│   │  ┌────────┐  │                                                  │
│   │  │ DPDK NIC│  │  ← 100G CX6 / Mellanox ConnectX                │
│   │  └────────┘  │                                                  │
│   │       │      │                                                  │
│   │       ▼      │                                                  │
│   │  ┌────────┐  │                                                  │
│   │  │分流器   │  │  ← memif master                                 │
│   │  │(自研)  │  │                                                  │
│   │  └────┬───┘  │                                                  │
│   │       │      │                                                  │
│   │  ┌────┴────┐ │                                                  │
│   │  │         │ │                                                  │
│   │  ▼         ▼ │                                                  │
│   │ Suricata  Arkime│                                                │
│   │  (检测)   (存储)│                                                │
│   │  32核      32核 │                                                │
│   │  64GB     128GB │                                                │
│   │              │                                                  │
│   │  ┌─────────┴─┐ │                                                  │
│   │  │   本地SSD  │ │  ← Arkime热数据 (1TB NVMe)                   │
│   │  └───────────┘ │                                                  │
│   └───────────────┘                                                  │
│                                                                     │
│   ┌──────────────┐                                                  │
│   │ 存储服务器    │                                                  │
│   │              │                                                  │
│   │  ┌─────────┐ │                                                  │
│   │  │  Ceph   │ │  ← Arkime温冷数据 (PB级)                        │
│   │  └─────────┘ │                                                  │
│   └──────────────┘                                                  │
│                                                                     │
│   ┌──────────────┐                                                  │
│   │ ES集群 (3节点)│                                                  │
│   │              │                                                  │
│   │ Suricata eve │                                                  │
│   │ Arkime meta  │                                                  │
│   │ 审计日志      │                                                  │
│   └──────────────┘                                                  │
│                                                                     │
│   ┌──────────────┐                                                  │
│   │ Kibana       │                                                  │
│   │ 合规报告/仪表盘│                                                  │
│   └──────────────┘                                                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 9. 合规能力映射

```
┌─────────────────────────────────────────────────────────────────────┐
│                       合规要求满足                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  等保2.0 三级                                                        │
│  ├── ✅ 网络边界防火墙     (通过架构设计)                           │
│  ├── ✅ 入侵检测IDS/IPS     (Suricata实时检测)                      │
│  ├── ✅ 日志留存≥6个月     (Arkime分层存储)                         │
│  ├── ✅ 流量审计           (全量pcap + 元数据)                      │
│  ├── ✅ 完整会话回放       (Arkime session replay)                  │
│  └── ✅ 异常行为告警       (Suricata规则 + ML)                      │
│                                                                     │
│  密评                                                                │
│  ├── ✅ TLS流量解密审计    (Suricata TLS decryption)                │
│  ├── ✅ 国密算法支持       (SM2/SM3/SM4 检测规则)                   │
│  ├── ✅ 加密流量可检索     (Arkime元数据索引)                       │
│  └── ✅ 密钥生命周期审计   (日志留存)                               │
│                                                                     │
│  金融/政企流量留存                                                   │
│  ├── ✅ 全量pcap留存       (Arkime PB级存储)                        │
│  ├── ✅ 6个月+留存周期    (分层存储策略)                           │
│  ├── ✅ 防篡改             (完整性校验)                             │
│  ├── ✅ 可查询/可回放     (Arkime搜索+回放)                        │
│  ├── ✅ 司法取证支持       (哈希校验+证据链)                        │
│  └── ✅ 每日完整性报告     (自动化报告生成)                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 10. 实施步骤

```
Phase 1: 基础设施 (2-4周)
├── 服务器/网卡采购
├── DPDK环境部署
├── memif环境验证
└── 共享内存配置

Phase 2: 核心开发 (4-8周)
├── DPDK分流器开发 (memif master)
├── Suricata memif slave支持 (patch/开发)
├── Arkime memif slave支持 (patch/开发)
└── 连通性测试

Phase 3: 存储部署 (2-4周)
├── Elasticsearch集群部署
├── Arkime存储配置
├── 分层存储脚本
└── 完整性校验

Phase 4: 检测配置 (2-4周)
├── Suricata规则调优
├── 告警阈值配置
├── ATT&CK映射
└── 国密规则

Phase 5: 合规配置 (1-2周)
├── 合规报告模板
├── 审计日志配置
├── 权限控制
└── 演练测试

总工期: 3-4个月
```

## 11. 总结

```
┌─────────────────────────────────────────────────────────────────────┐
│                        方案总结                                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  架构:                                                               │
│  DPDK网卡 -> memif master -> Suricata (检测)                        │
│                   └> Arkime (存储)                                  │
│                                                                     │
│  合规满足:                                                           │
│  ├── 等保2.0: 全量留存+IDS检测+6个月+会话回放                        │
│  ├── 密评: TLS解密+国密规则+密钥审计                                 │
│  └── 金融/政企: PB级存储+分层归档+防篡改+司法取证                    │
│                                                                     │
│  核心优势:                                                           │
│  ├── memif零拷贝，接近线速                                           │
│  ├── 全量流量同时检测+存储                                           │
│  ├── 分层存储降低成本                                                 │
│  └── 完整性校验满足取证要求                                          │
│                                                                     │
│  关键技术:                                                           │
│  ├── memif: DPDK原生共享内存，无锁队列，零拷贝                       │
│  ├── Suricata: IDS检测，告警输出                                     │
│  ├── Arkime: pcap存储，元数据索引                                    │
│  └── ES+Kibana: 日志聚合，合规报告                                  │
│                                                                     │
│  注意事项:                                                           │
│  ├── memif需Suricata/Arkime开发支持                                 │
│  ├── 现阶段可考虑PF-RING作为替代                                    │
│  └── 分层存储需定期测试恢复                                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

> [!ref] 参考资料
>
> - [DPDK memif Documentation](https://doc.dpdk.org/guides/prog_guide/memif.html)
> - [Suricata DPDK Support](https://suricata.readthedocs.io/en/latest/Setting_up敦煌DPDK for Suricata.html)
> - [Arkime Documentation](https://arkime.com/)
> - [MITRE ATT&CK](https://attack.mitre.org/)
> - [[2026-04-10-apt-detection-and-ml|APT检测与机器学习]]
> - [[2026-04-10-security-incident-forensics|安全事件溯源与取证]]
> - [[2026-04-10-network-performance-analysis|网络性能分析与瓶颈定位]]

## 关联文档

- [[2026-04-10-apt-detection-and-ml|APT检测与机器学习]] - APT检测、横向移动、数据泄漏、异常外联
- [[2026-04-10-security-incident-forensics|安全事件溯源与取证]] - 攻击链还原、取证流程、时间线重建、DFIR工具链
- [[2026-04-10-network-performance-analysis|网络性能分析与瓶颈定位]] - 网络卡顿、应用响应慢、带宽拥塞定位
