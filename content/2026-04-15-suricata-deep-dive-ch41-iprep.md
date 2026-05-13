---
title: "Suricata 深度探索 (四十一)：IP 信誉系统"
date: 2026-04-15
tags:
  - suricata
  - series
  - ip-reputation
  - reputation
  - threat-intelligence
description: "深入解析 Suricata IP 信誉系统：reputation 配置、IP 信誉数据库格式、分类器（IPCartridge）、SReputation 引擎、动态更新机制、以及与规则系统的集成"
---

> [!info] Suricata 2026 深度探索系列
> 0. [[2026-04-15-suricata-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-suricata-deep-dive-ch1-overview|第一章：Suricata 概述]]
> 2. [[2026-04-15-suricata-deep-dive-ch2-config|第二章：Suricata 配置系统]]
> ...
> 39. [[2026-04-15-suricata-deep-dive-ch39-memory|第三十九章：内存管理]]
> 40. [[2026-04-15-suricata-deep-dive-ch40-hyperscan|第四十章：Hyperscan MPM]]
> 41. **第四十一章：IP 信誉系统**
> 42. [[2026-04-15-suricata-deep-dive-ch42-dataset|第四十二章：Dataset 与动态列表]]
> 43. [[2026-04-15-suricata-deep-dive-ch43-app-layer-register|第四十三章：自定义 Parser]]
> 44. [[2026-04-15-suricata-deep-dive-ch44-rust|第四十四章：Rust 扩展]]
> 45. [[2026-04-15-suricata-deep-dive-ch45-cluster|第四十五章：集群模式]]

---

## 1. IP 信誉概述

Suricata 的 **IP 信誉系统（IP Reputation, IPREP）** 提供基于来源 IP 的威胁情报评分机制。不同于静态规则匹配，IPREP 通过外部情报源对 IP 进行分类评分，使检测引擎能够基于历史行为做出判断。

```
graph TD
    subgraph "IPREP 数据流"
        IP[\"Source IP / Dest IP\"]
        RD[\"Reputation Database<br/>iprep.dat\"]
        CAT[\"IPCartridge<br/>分类器\"]
        SREP[\"SReputation Engine<br/>信誉引擎\"]
        DET[\"Detection Engine<br/>检测引擎\"]
    end

    IP --> CAT
    RD --> SREP
    CAT --> SREP
    SREP --> DET
```

### 1.1 IPREP vs 传统规则

| 特性 | 传统 IP 规则 | IPREP 系统 |
|:---|:---|:---|
| 数据来源 | 规则文件 (sidmsg.map) | 外部数据库 (iprep.dat) |
| 更新方式 | 规则更新 | 动态增量更新 |
| 粒度 | 二元（匹配/不匹配） | 分类 + 置信度 |
| 适用场景 |已知攻击 | 恶意 IP、僵尸网络、Tor 出口节点 |

### 1.2 信誉分类

Suricata 内置多个**情报类别**，每个类别对应不同威胁类型：

```c
// src/util-reputation.h — 信誉类别定义
typedef enum SReputationCat_ {
    SREP_CAT_NOTSET = 0,
    SREP_CAT_WHITELIST = 1,        // 白名单
    SREP_CAT_BLACKLIST = 2,        // 黑名单
    SREP_CAT_BOTH = 3,            // 同时黑白名单
    SREP_CAT_MALWARE = 4,          // 恶意软件
    SREP_CAT_COMMAND = 5,         // C2 命令控制
    SREP_CAT_SPAM = 6,            // 垃圾邮件
    SREP_CAT_SCANNER = 7,         // 扫描器
    SREP_CAT_BOT = 8,             // 僵尸网络
    SREP_CAT_MALICIOUS = 9,       // 综合恶意
    SREP_CAT_TOR = 10,            // Tor 出口节点
    SREP_CAT_SSH = 11,            // SSH 暴力破解
    SREP_CAT_VPN = 12,            // VPN 服务
    SREP_CAT_PROXY = 13,          // 代理服务
    SREP_CAT_ABUSE = 14,          // 综合滥用
} SReputationCat;
```

---

## 2. reputation 配置详解

### 2.1 基础配置

```yaml
# suricata.yaml
reputation:
  # 启用 IP 信誉系统
  enabled: yes

  # 信誉数据库路径
  default-white-list: reputation/whitelist.txt
  default-black-list: reputation/blacklist.txt

  # 分类配置
  categories:
    - name: "malware"
      id: 4
      feed: "https://feeds.example.com/malware-iprep.dat"
      priority: 10
    - name: "bot"
      id: 8
      feed: "https://feeds.example.com/bot-iprep.dat"
      priority: 8
    - name: "tor"
      id: 10
      feed: "https://feeds.example.com/tor-exit-nodes.dat"
      priority: 7

  # 内存缓存
  sharding:
    # IP 哈希分片数
    shards: 10

  # 刷新间隔
  update-interval: 300          # 5 分钟检查更新
```

### 2.2 完整配置示例

```yaml
# suricata.yaml
reputation:
  enabled: yes

  # 黑白名单文件（本地）
  default-white-list: reputation/whitelist.txt
  default-black-list: reputation/blacklist.txt

  # 动态加载的信誉数据
  data:
    - file: /var/lib/suricata/iprep/malware.dat
      ver: 1
      cats: [4, 9]               # malware + malicious
    - file: /var/lib/suricata/iprep/bot.dat
      ver: 1
      cats: [8]                  # bot
    - file: /var/lib/suricata/iprep/tor.dat
      ver: 1
      cats: [10]                 # tor

  # 自动更新
  auto-update:
    enabled: yes
    interval: 3600               # 每小时检查一次
    url: "https://feeds.example.com/suricata-update.yaml"
```

### 2.3 黑白名单格式

```bash
# whitelist.txt — 白名单（低优先级）
# 格式: IP/CIDR,category,trust_level
10.0.0.0/8,1,100           # 内部网络，完全信任
192.168.1.0/24,1,100        # 内部子网，完全信任

# blacklist.txt — 黑名单（高优先级）
# 格式: IP/CIDR,category,trust_level
1.2.3.4/32,2,100            # 已知恶意 IP
5.6.7.0/24,8,80             # 僵尸网络
```

---

## 3. IPREP 数据格式

### 3.1 iprep.dat 格式

Suricata 使用二进制格式的 IPREP 数据库，加载速度快，适合大文件（百万级 IP）：

```
# Text 格式（suricata-update 输出）
# IP,CATEGORY,TRUST,DESCRIPTION
1.2.3.4,4,100,Known malware server
5.6.7.8,8,90,Botnet C2
9.10.11.12/24,10,85,Tor exit node
```

```c
// src/util-reputation.c — 二进制格式加载
typedef struct SReputationIPv4_ {
    uint32_t ip;              // 网络字节序 IP
    uint8_t category;         // 类别 ID
    uint8_t trust;            // 信任级别 (0-100)
    uint16_t padding;
} SReputationIPv4;

// 支持 CIDR 范围
typedef struct SReputationCIDR4_ {
    uint32_t network;         // 网络地址
    uint32_t netmask;         // 网络掩码
    uint8_t category;
    uint8_t trust;
} SReputationCIDR4;
```

### 3.2 IPCartridge 分类器

**IPCartridge** 是 Suricata 的信誉查询引擎，负责快速 IP 查找：

```c
// src/util-reputation.h — IPCartridge 引擎
typedef struct SReputationCtx_ {
    /* 分类器状态 */
    uint8_t state;
#define SREP_STATE_UNINIT    0
#define SREP_STATE_READY     1
#define SREP_STATE_UPDATE    2

    /* CIDR 前缀树（Radix Tree）*/
    SCTrie_t *trie_v4;        // IPv4 前缀树
    SCTrie_t *trie_v6;        // IPv6 前缀树

    /* 直接 IP 哈希表 */
    SReputationIPv4 *direct_v4;
    uint32_t direct_v4_count;

    /* 黑白名单 */
    SCTrie_t *whitelist;
    SCTrie_t *blacklist;

    /* 类别掩码 */
    uint16_t category_mask;

    /* 引用计数 */
    uint32_t ref;
} SReputationCtx;
```

### 3.3 Radix Tree 加速查找

```c
// src/util-trie.h — 前缀树结构
typedef struct SCTrie_ {
    SCTrieNode *root;
    uint32_t node_count;
    uint32_t ip_count;
} SCTrie;

// 查找复杂度：O(k)，k = IP 前缀长度（最大 32）
SReputationCat SReputationLookupIPv4(SReputationCtx *ctx, uint32_t ip)
{
    /* 先查白名单 */
    if (SCTrieSearch(ctx->whitelist, ip) == SCTRIE_MATCH) {
        return SREP_CAT_WHITELIST;
    }

    /* 再查黑名单 */
    if (SCTrieSearch(ctx->blacklist, ip) == SCTRIE_MATCH) {
        return SREP_CAT_BLACKLIST;
    }

    /* 最后查 CIDR 前缀树 */
    return SCTrieSearch(ctx->trie_v4, ip);
}
```

---

## 4. SReputation 引擎

### 4.1 引擎初始化

```c
// src/reputation.c — 初始化 IPREP 引擎
int SReputationInitCtx(SReputationCtx **ctx)
{
    *ctx = SCCalloc(1, sizeof(SReputationCtx));
    if (*ctx == NULL) {
        return -1;
    }

    SReputationCtx *repc = *ctx;

    /* 初始化前缀树 */
    repc->trie_v4 = SCTrieCreate(AF_INET);
    repc->trie_v6 = SCTrieCreate(AF_INET6);

    /* 初始化黑白名单 */
    repc->whitelist = SCTrieCreate(AF_INET);
    repc->blacklist = SCTrieCreate(AF_INET);

    repc->state = SREP_STATE_READY;

    SCReturnInt(1);
}
```

### 4.2 加载 IPREP 数据

```c
// src/reputation.c — 加载 IPREP 数据库
int SReputationLoadFile(SReputationCtx *ctx, const char *path)
{
    FILE *fp = fopen(path, "r");
    if (fp == NULL) {
        SCLogError("Failed to open IPREP file: %s", path);
        return -1;
    }

    char line[256];
    while (fgets(line, sizeof(line), fp) != NULL) {
        /* 跳过注释和空行 */
        if (line[0] == '#' || line[0] == '\n') {
            continue;
        }

        /* 解析一行 */
        SReputationIP rep_ip;
        if (SReputationParseLine(line, &rep_ip) != 0) {
            continue;
        }

        /* 插入前缀树 */
        if (rep_ip.ip_version == 4) {
            SCTrieInsert(ctx->trie_v4, rep_ip.network, rep_ip.netmask,
                        rep_ip.category, rep_ip.trust);
        } else {
            SCTrieInsert(ctx->trie_v6, rep_ip.network6, rep_ip.netmask6,
                        rep_ip.category, rep_ip.trust);
        }
    }

    fclose(fp);
    SCLogInfo("Loaded IPREP data from %s", path);
    return 0;
}

// 解析一行 IPREP 数据
static int SReputationParseLine(const char *line, SReputationIP *rep_ip)
{
    char ip_str[64], cat_str[16], trust_str[16];

    /* 格式: IP/CIDR,category,trust */
    int n = sscanf(line, "%63[^,],%15[^,],%15[^,\n]",
                   ip_str, cat_str, trust_str);
    if (n != 3) {
        return -1;
    }

    /* 解析 IP/CIDR */
    uint32_t ip, netmask;
    if (strchr(ip_str, ':') == NULL) {
        /* IPv4 */
        rep_ip->ip_version = 4;
        ParseIPv4CIDR(ip_str, &ip, &netmask);
        rep_ip->network = ip;
        rep_ip->netmask = netmask;
    } else {
        /* IPv6 */
        rep_ip->ip_version = 6;
        ParseIPv6CIDR(ip_str, rep_ip->network6, rep_ip->netmask6);
    }

    rep_ip->category = atoi(cat_str);
    rep_ip->trust = atoi(trust_str);

    return 0;
}
```

### 4.3 IP 查询接口

```c
// src/reputation.c — 查询 IP 信誉
SReputationResult SReputationLookupIP(
    SReputationCtx *ctx,
    uint8_t ip_version,
    const uint8_t *ip)
{
    SReputationResult result = {
        .category = SREP_CAT_NOTSET,
        .trust = 0,
        .has_match = false
    };

    if (ctx == NULL || ctx->state != SREP_STATE_READY) {
        return result;
    }

    if (ip_version == 4) {
        uint32_t ipv4 = *(uint32_t *)ip;

        /* 白名单检查 */
        if (SCTrieSearch(ctx->whitelist, ipv4) == SCTRIE_MATCH) {
            result.category = SREP_CAT_WHITELIST;
            result.trust = 100;
            result.has_match = true;
            return result;
        }

        /* 黑名单检查 */
        if (SCTrieSearch(ctx->blacklist, ipv4) == SCTRIE_MATCH) {
            result.category = SREP_CAT_BLACKLIST;
            result.trust = 100;
            result.has_match = true;
            return result;
        }

        /* CIDR 前缀树查找 */
        result = SCTrieLookup(ctx->trie_v4, ipv4);
    } else {
        /* IPv6 查找 */
        result = SCTrieLookup(ctx->trie_v6, ip);
    }

    return result;
}
```

---

## 5. 与检测引擎集成

### 5.1 iprep 关键字

Suricata 规则使用 `iprep` 关键字匹配 IP 信誉：

```bash
# 规则示例
alert tcp any any -> any any (msg:"Known malware C2"; \
    iprep:src,4,>,70; sid:1000001;)

alert tcp any any -> any any (msg:"Tor exit node"; \
    iprep:dst,10,=,100; sid:1000002;)

alert tcp any any -> any any (msg:"Botnet C2 communication"; \
    iprep:src,8,>=,80; iprep:dst,8,>=,80; sid:1000003;)
```

### 5.2 iprep 检测逻辑

```c
// src/detect-iprep.c — iprep 关键字匹配
typedef struct DetectIPRepData_ {
    /* IP 来源 */
    uint8_t mode;                  // SRC 或 DST
#define IPREP_MODE_SRC    0
#define IPREP_MODE_DST    1

    /* 类别 */
    SReputationCat cat;

    /* 操作符和阈值 */
    uint8_t op;                    // >, <, =, >=, <=
    uint8_t value;                 // 信任级别阈值
} DetectIPRepData;

static int DetectIPRepMatch(DetectEngineThreadCtx *det_ctx,
                           Packet *p, const void *matcher)
{
    const DetectIPRepData *data = matcher;
    if (data == NULL || p == NULL) {
        return 0;
    }

    /* 获取源/目标 IP */
    uint8_t *ip_addr = NULL;
    uint8_t ip_version = 0;

    if (data->mode == IPREP_MODE_SRC) {
        if (PKT_IS_IPV4(p)) {
            ip_addr = (uint8_t *)&p->ip4h->src_addr;
            ip_version = 4;
        } else if (PKT_IS_IPV6(p)) {
            ip_addr = (uint8_t *)&p->ip6h->src_addr;
            ip_version = 6;
        }
    } else {
        if (PKT_IS_IPV4(p)) {
            ip_addr = (uint8_t *)&p->ip4h->dst_addr;
            ip_version = 4;
        } else if (PKT_IS_IPV6(p)) {
            ip_addr = (uint8_t *)&p->ip6h->dst_addr;
            ip_version = 6;
        }
    }

    /* 查询信誉 */
    SReputationCtx *rep_ctx = det_ctx->reputation_ctx;
    SReputationResult rep_result = SReputationLookupIP(
        rep_ctx, ip_version, ip_addr);

    if (!rep_result.has_match) {
        return 0;
    }

    /* 检查类别 */
    if (rep_result.category != data->cat) {
        return 0;
    }

    /* 比较信任级别 */
    switch (data->op) {
        case DETECT_IPREP_OP_EQ:
            return (rep_result.trust == data->value);
        case DETECT_IPREP_OP_GT:
            return (rep_result.trust > data->value);
        case DETECT_IPREP_OP_LT:
            return (rep_result.trust < data->value);
        case DETECT_IPREP_OP_GTE:
            return (rep_result.trust >= data->value);
        case DETECT_IPREP_OP_LTE:
            return (rep_result.trust <= data->value);
        default:
            return 0;
    }
}
```

### 5.3 注册 iprep 关键字

```c
// src/detect-iprep.c — 注册关键字
void DetectIPRepRegister(void)
{
    /* 注册 keyword "iprep" */
    sigmatch_table[DETECT_IPREP].name = "iprep";
    sigmatch_table[DETECT_IPREP].desc =
        "match against IP reputation data";
    sigmatch_table[DETECT_IPREP].url = DOC_URL "/rules/ip-reputation-rules";
    sigmatch_table[DETECT_IPREP].Match = DetectIPRepMatch;
    sigmatch_table[DETECT_IPREP].Setup = DetectIPRepSetup;
    sigmatch_table[DETECT_IPREP].Free = DetectIPRepFree;

    /* 优先级：高于普通检测 */
    sigmatch_table[DETECT_IPREP].priority = PRIORITY_HIGH;
}
```

---

## 6. 动态更新机制

### 6.1 suricata-update 集成

Suricata 支持通过 **suricata-update** 工具动态更新 IPREP 数据：

```bash
# 安装 suricata-update
pip install suricata-update

# 更新规则和信誉数据
suricata-update

# 列出可用源
suricata-update list-sources

# 启用特定源
suricata-update enable-source et/open
suricata-update enable-source abuse.ch/sslbl
suricata-update enable-source abuse.ch/urlhaus

# 合并并更新
suricata-update
```

### 6.2 自动更新配置

```yaml
# suricata.yaml — 自动更新
reputation:
  auto-update:
    enabled: yes
    interval: 3600               # 每小时检查

    # 本地缓存
    cache-dir: /var/lib/suricata/update/
    cache-size: 1024             # MB

    # 源配置
    sources:
      - name: "et-open"
        type: "suricata-update"
        enabled: yes
      - name: "abuse-sslbl"
        type: "suricata-update"
        enabled: yes
      - name: "my-custom-feed"
        type: "json"
        path: "/etc/suricata/my-iprep.json"
        format: "json"
```

### 6.3 运行时更新流程

```c
// src/reputation.c — 运行时更新
typedef struct SReputationUpdate_ {
    char *source_path;           // 新数据源
    time_t last_update;          // 上次更新时间
    uint32_t version;             // 数据版本
    int status;                  // 更新状态
} SReputationUpdate;

int SReputationReload(SReputationCtx *old_ctx)
{
    /* 创建临时上下文 */
    SReputationCtx *new_ctx = NULL;
    if (SReputationInitCtx(&new_ctx) != 0) {
        return -1;
    }

    /* 从文件重新加载 */
    const char *data_files[] = {
        "/var/lib/suricata/iprep/malware.dat",
        "/var/lib/suricata/iprep/bot.dat",
        "/var/lib/suricata/iprep/tor.dat",
    };

    for (int i = 0; i < 3; i++) {
        if (SReputationLoadFile(new_ctx, data_files[i]) != 0) {
            SCLogWarning("Failed to load %s", data_files[i]);
        }
    }

    /* 原子切换 */
    SCCtrlLock(&reputation_lock);
    SReputationCtx *tmp = g_reputation_ctx;
    g_reputation_ctx = new_ctx;
    SCCtrlUnlock(&reputation_lock);

    /* 释放旧上下文 */
    if (tmp != NULL) {
        SReputationFreeCtx(tmp);
    }

    SCLogInfo("IPREP database reloaded successfully");
    return 0;
}
```

---

## 7. EVE JSON 输出

### 7.1 IPREP 事件记录

```json
{
  "timestamp": "2026-04-15T10:30:00.000000+0000",
  "event_type": "alert",
  "src_ip": "1.2.3.4",
  "dest_ip": "192.168.1.100",
  "alert": {
    "signature_id": 1000001,
    "signature": "Known malware C2",
    "category": "Potentially Bad Traffic",
    "rev": 1
  },
  "reputation": {
    "src_ip": {
      "ip": "1.2.3.4",
      "category": ["malware", "bot"],
      "trust": 85
    }
  }
}
```

### 7.2 输出配置

```yaml
# suricata.yaml
outputs:
  - eve-log:
      enabled: yes
      filename: eve.json
      types:
        - alert:
            # 包含信誉信息
            reputation: yes
        - http:
            # HTTP 日志也包含信誉
           强盗: yes
```

---

## 8. 性能优化

### 8.1 分片策略

对于大表（>10M IP），使用 **一致性哈希分片** 减少锁竞争：

```c
// src/reputation.c — 分片查找
static SReputationCtx *SReputationGetShard(SReputationCtx *main_ctx,
                                          uint32_t ip_hash)
{
    /* 简单取模分片 */
    uint32_t shard_idx = ip_hash % main_ctx->shard_count;
    return main_ctx->shards[shard_idx];
}

SReputationResult SReputationLookupIPSharded(
    SReputationCtx *main_ctx,
    uint8_t ip_version,
    const uint8_t *ip)
{
    /* 计算 IP 哈希 */
    uint32_t ip_hash = hash32(ip, ip_version == 4 ? 4 : 16);

    /* 获取分片 */
    SReputationCtx *shard = SReputationGetShard(main_ctx, ip_hash);

    /* 分片内查找 */
    return SReputationLookupIP(shard, ip_version, ip);
}
```

### 8.2 缓存热点 IP

```c
// src/reputation.c — LRU 缓存热点 IP
typedef struct SReputationCache_ {
    SReputationResult entries[1024];  // 1K 缓存条目
    uint32_t ip_hashes[1024];
    uint32_t hits;
    uint32_t misses;
} SReputationCache;

static __thread SReputationCache t_iprep_cache;

SReputationResult SReputationLookupIPCached(
    SReputationCtx *ctx, uint8_t ip_version, const uint8_t *ip)
{
    uint32_t ip_hash = hash32(ip, ip_version == 4 ? 4 : 16);

    /* 查缓存 */
    for (int i = 0; i < 1024; i++) {
        if (t_iprep_cache.ip_hashes[i] == ip_hash) {
            t_iprep_cache.hits++;
            return t_iprep_cache.entries[i];
        }
    }

    /* 缓存未命中，查主数据库 */
    SReputationResult result = SReputationLookupIP(ctx, ip_version, ip);

    /* 插入缓存（简单 FIFO）*/
    static uint32_t cache_idx = 0;
    t_iprep_cache.ip_hashes[cache_idx % 1024] = ip_hash;
    t_iprep_cache.entries[cache_idx % 1024] = result;
    cache_idx++;
    t_iprep_cache.misses++;

    return result;
}
```

---

## 9. 小结

本章解析了 Suricata 的 IP 信誉系统：

1. **IPREP 数据流**：外部情报 → iprep.dat → IPCartridge → 检测引擎
2. **数据结构**：Radix Tree（CIDR 前缀树）+ 直接 IP 哈希表
3. **配置**：reputation.{categories, auto-update}
4. **规则集成**：`iprep:src/dst,category,op,value`
5. **动态更新**：suricata-update 集成，原子切换
6. **性能优化**：分片策略 + LRU 热点缓存
