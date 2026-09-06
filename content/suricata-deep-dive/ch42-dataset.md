---
title: "Suricata 深度探索 (四十二)：Dataset 与动态列表"
date: 2026-04-15
tags:
  - suricata
  - series
  - dataset
  - lua
  - dynamic-list
  - threat-intelligence
description: "深入解析 Suricata Dataset 系统：dataset 配置、Dataset 类型（ip, md5, sha256, string, url）、Atomic 加载、Lua 动态列表、规则关键字（dstlive, filestore）、以及大列表性能优化"
---

> [!info] Suricata 2026 深度探索系列 0. [[suricata-deep-dive|全栈学习路径总览]]
> ... 40. [[ch40-hyperscan|第四十章：Hyperscan MPM]] 41. [[ch41-iprep|第四十一章：IP 信誉系统]] 42. **第四十二章：Dataset 与动态列表** 43. [[ch43-app-layer-register|第四十三章：自定义 Parser]] 44. [[ch44-rust|第四十四章：Rust 扩展]] 45. [[ch45-cluster|第四十五章：集群模式]]

---

## 1. Dataset 概述

Suricata 的 **Dataset** 系统提供**运行时动态列表**能力，允许规则引用内存中的大型数据集（IP、MD5、SHA256、String、URL），并支持增量更新。与传统固定规则不同，Dataset 可以从文件或 Lua 脚本动态加载，适合威胁情报集成、恶意文件哈希同步等场景。

```
graph TD
    subgraph "Dataset 架构"
        CFG[\"suricata.yaml<br/>dataset 配置\"]
        FILE[\"外部文件<br/>ip-blocklist.txt\"]
        LUA[\"Lua 脚本<br/>dynamic_feed.lua\"]
        ENGINE[\"Dataset Engine<br/>检测引擎\"]
        RULE[\"规则<br/>dstlive:&lt;name&gt;,100,200\"]
    end

    CFG --> ENGINE
    FILE --> ENGINE
    LUA --> ENGINE
    ENGINE --> RULE
```

### 1.1 Dataset vs IPREP

| 特性           | IPREP                | Dataset                         |
| :------------- | :------------------- | :------------------------------ |
| **数据类型**   | IP 信誉（类别+分数） | IP/MD5/SHA256/String/URL        |
| **更新粒度**   | 全量替换             | 增量添加/删除                   |
| **Lua 集成**   | 否                   | 是                              |
| **持久化**     | 二进制 .dat          | 文本文件                        |
| **规则关键字** | `iprep`              | `dstlive`, `filemd5`, `urilive` |
| **适用场景**   | 威胁情报             | 动态黑白名单                    |

### 1.2 Dataset 类型

```c
// src/util-dataset.h — Dataset 类型
typedef enum DatasetType_ {
    DATASET_TYPE_NOTSET = 0,
    DATASET_TYPE_IP,              // IPv4/IPv6 地址
    DATASET_TYPE_MD5,             // MD5 哈希（文件）
    DATASET_TYPE_SHA256,          // SHA256 哈希（文件）
    DATASET_TYPE_STRING,          // 任意字符串
    DATASET_TYPE_URL,             // URL 路径
} DatasetType;
```

---

## 2. dataset 配置详解

### 2.1 基础配置

```yaml
# suricata.yaml
datasets:
  # 顶层默认配置
  defaults:
    # 默认类型
    type: string
    # 默认存储路径
    persist-path: /var/lib/suricata/datasets/
    # 默认内存类型（hash/bloom/lmdb）
    mem-limit: 500mb

  # 具体数据集定义
  inputs:
    # IP 黑名单
    - name: "badips"
      type: ip
      persist: yes
      # 文件路径（文件存在则加载）
      load: /var/lib/suricata/datasets/badips.txt
      # 写入路径（新条目追加）
      save: /var/lib/suricata/datasets/badips.txt
      lock: yes # 文件锁

    # MD5 黑名单（恶意文件哈希）
    - name: "malware-hashes"
      type: md5
      persist: yes
      load: /var/lib/suricata/datasets/malware-md5.txt
      save: /var/lib/suricata/datasets/malware-md5.txt
      version: 1

    # SHA256 黑名单
    - name: "malware-sha256"
      type: sha256
      persist: yes
      load: /var/lib/suricata/datasets/malware-sha256.txt
      notifiers: /var/run/suricata/dataset.notif # inotify 通知

    # URL 黑名单
    - name: "malicious-urls"
      type: url
      persist: yes
      load: /var/lib/suricata/datasets/badurls.txt

    # String 白名单
    - name: "whitelisted-domains"
      type: string
      persist: yes
      load: /var/lib/suricata/datasets/whitelist.txt
```

### 2.2 高级配置

```yaml
# suricata.yaml
datasets:
  inputs:
    - name: "large-ip-list"
      type: ip
      # 存储后端
      backend: lmdb
      # LMDB 特定配置
      lmdb:
        map-size: 2gb
        max-readers: 100
      # 文件格式
      format: text # text | binary
      # 字符集（string/url 类型）
      separator: ","

    - name: "real-time-threats"
      type: ip
      # 实时加载，不持久化
      persist: no
      # 非持久化数据集，内存增长后不写入磁盘
      empty: ignore # ignore | create

    - name: "http-useragents"
      type: string
      # Base64 编码输入
      encoding: base64
```

### 2.3 数据文件格式

```bash
# badips.txt — IP 列表
# 格式：IP 或 IP/CIDR（每行一个）
1.2.3.4
5.6.7.8
10.0.0.0/24
2001:db8::1

# malware-md5.txt — MD5 哈希列表
d41d8cd98f00b204e9800998ecf8427e
098f2470bfa8c27d8e9800998ecf8427e

# malware-sha256.txt — SHA256 哈希列表
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
a8d9e9f8b7c6a5d4e3f2g1h0i9j8k7l6m5n4o3p2q1r0s

# badurls.txt — URL 列表
/malicious/path1
/malicious/path2
/example.com/bad/
```

---

## 3. Dataset 核心数据结构

### 3.1 Dataset 结构

```c
// src/util-dataset.h — Dataset 核心结构
typedef struct Dataset_ {
    /* 数据集名称 */
    char *name;

    /* 数据类型 */
    DatasetType type;

    /* 存储后端 */
    DatasetBackendType backend;
#define DATASET_BACKEND_NOTSET      0
#define DATASET_BACKEND_HASH_STRING 1  // 字符串 hash 表
#define DATASET_BACKEND_BLOOM       2  // Bloom filter
#define DATASET_BACKEND_LMDB        3  // LMDB 持久化
#define DATASET_BACKEND_RDB         4  // Redis (实验)
#define DATASET_BACKEND_RADIX       5  // IP radix tree

    /* 内部存储 */
    void *data;

    /* 存储路径 */
    char *load_path;              // 加载文件
    char *save_path;              // 保存文件
    char *persist_path;           // 持久化路径

    /* 标志 */
    uint32_t flags;
#define DATASET_FLAG_PERSIST       0x01  // 持久化
#define DATASET_FLAG_NOTIFY        0x02  // inotify 通知
#define DATASET_FLAG_LOCK          0x04  // 文件锁
#define DATASET_FLAG_Atomic        0x08  // 原子加载
#define DATASET_FLAG_BASE64        0x10  // Base64 编码

    /* 统计 */
    uint64_t count;               // 条目数
    uint64_t memsize;             // 内存占用

    /* 引用计数 */
    uint32_t ref;
} Dataset;
```

### 3.2 Hash Backend

```c
// src/util-hash.h — Hash 表 Dataset
typedef struct DatasetHash_ {
    /* Hash 表 */
    HashTable *hash;

    /* 已删除集合（软删除）*/
    HashTable *deleted;

    /* 数据文件 */
    FILE *fp;
    char *line;                   // 当前行缓冲
    size_t line_size;

    /* 同步锁 */
    SCMutex lock;
} DatasetHash;
```

### 3.3 Radix Backend (IP 类型)

```c
// src/util-radix.h — Radix Tree Dataset（用于 IP）
typedef struct DatasetRadix_ {
    /* Radix 前缀树 */
    SCRadixTree *tree;

    /* 存储数据（每个叶子节点）*/
    void *user;
} DatasetRadix;

// IP 数据集内部表示
typedef struct DatasetRadixIPV4_ {
    uint8_t family;               // AF_INET / AF_INET6
    uint8_t data[32];            // IP 地址
    void *user;                  // 用户数据
} DatasetRadixIPV4;
```

### 3.4 Bloom Filter Backend

```c
// src/util-bloom.h — Bloom Filter Dataset
typedef struct DatasetBloom_ {
    /* Bloom filter */
    BloomFilter *bloom;

    /* 假阳性处理（精确匹配）*/
    HashTable *hash;              // 假阳性时精确查找

    /* 预期条目数 */
    uint64_t nelems;

    /* 假阳性率 */
    double fpr;
} DatasetBloom;
```

---

## 4. Dataset 引擎核心

### 4.1 创建 Dataset

```c
// src/util-dataset.c — 创建 Dataset
Dataset *DatasetSubscribe(const char *name, DatasetType type,
                          DatasetBackendType backend)
{
    /* 检查是否已存在 */
    Dataset *ds = DatasetFindByName(name);
    if (ds != NULL) {
        SCLogDebug("Dataset %s already exists", name);
        return ds;
    }

    /* 分配 Dataset */
    ds = SCCalloc(1, sizeof(Dataset));
    ds->name = SCStrdup(name);
    ds->type = type;

    /* 初始化后端 */
    switch (backend) {
        case DATASET_BACKEND_HASH_STRING:
            ds->data = DatasetHashInit();
            break;
        case DATASET_BACKEND_BLOOM:
            ds->data = DatasetBloomInit(1000000, 0.001); // 1M 条目
            break;
        case DATASET_BACKEND_RADIX:
            ds->data = DatasetRadixInit();
            break;
        case DATASET_BACKEND_LMDB:
            ds->data = DatasetLmdbInit(ds->persist_path);
            break;
        default:
            ds->data = DatasetHashInit();
            break;
    }

    /* 加载已有数据 */
    if (ds->load_path != NULL) {
        DatasetLoad(ds, ds->load_path);
    }

    /* 注册到全局列表 */
    TAILQ_INSERT_TAIL(&datasets, ds, next);

    return ds;
}
```

### 4.2 加载数据集

```c
// src/util-dataset.c — 从文件加载
int DatasetLoad(Dataset *ds, const char *path)
{
    FILE *fp = fopen(path, "r");
    if (fp == NULL) {
        SCLogWarning("Cannot open dataset file: %s", path);
        return -1;
    }

    char *line = NULL;
    size_t line_size = 0;
    ssize_t linelen;

    /* 加锁 */
    if (ds->flags & DATASET_FLAG_LOCK) {
        LockFile(path, LOCK_SH);
    }

    while ((linelen = getline(&line, &line_size, fp)) != -1) {
        /* 去除换行符 */
        if (line[linelen - 1] == '\n') {
            line[linelen - 1] = '\0';
            linelen--;
        }

        /* 跳过空行和注释 */
        if (linelen == 0 || line[0] == '#') {
            continue;
        }

        /* 解码（如果需要）*/
        if (ds->flags & DATASET_FLAG_BASE64) {
            uint8_t decoded[256];
            int dec_len = DecodeBase64(decoded, line, linelen);
            if (dec_len > 0) {
                DatasetAdd(ds, decoded, dec_len);
            }
        } else {
            DatasetAdd(ds, (uint8_t *)line, linelen);
        }
    }

    free(line);
    fclose(fp);

    if (ds->flags & DATASET_FLAG_LOCK) {
        UnlockFile(path);
    }

    SCLogInfo("Loaded %" PRIu64 " entries into dataset %s",
              ds->count, ds->name);
    return 0;
}
```

### 4.3 添加/查找条目

```c
// src/util-dataset.c — 添加条目
int DatasetAdd(Dataset *ds, const uint8_t *data, uint32_t len)
{
    if (ds == NULL || data == NULL) {
        return -1;
    }

    switch (ds->backend) {
        case DATASET_BACKEND_HASH_STRING: {
            DatasetHash *dh = (DatasetHash *)ds->data;
            SCMutexLock(&dh->lock);
            HashTableAdd(dh->hash, (uint8_t *)data, len);
            ds->count++;
            SCMutexUnlock(&dh->lock);
            break;
        }
        case DATASET_BACKEND_RADIX: {
            DatasetRadix *dr = (DatasetRadix *)ds->data;
            SCRadixAddKey(data, len, dr->tree, ds);
            ds->count++;
            break;
        }
        case DATASET_BACKEND_BLOOM: {
            DatasetBloom *db = (DatasetBloom *)ds->data;
            BloomFilterAdd(db->bloom, data, len);
            ds->count++;
            break;
        }
        case DATASET_BACKEND_LMDB: {
            DatasetLmdb *dlm = (DatasetLmdb *)ds->data;
            DatasetLmdbAdd(dlm, data, len);
            ds->count++;
            break;
        }
    }

    return 0;
}

// 查找条目
bool DatasetLookup(Dataset *ds, const uint8_t *data, uint32_t len)
{
    if (ds == NULL || data == NULL) {
        return false;
    }

    switch (ds->backend) {
        case DATASET_BACKEND_HASH_STRING: {
            DatasetHash *dh = (DatasetHash *)ds->data;
            return HashTableLookup(dh->hash, data, len) != NULL;
        }
        case DATASET_BACKEND_RADIX: {
            DatasetRadix *dr = (DatasetRadix *)ds->data;
            return SCRadixFindKey(data, len, dr->tree, NULL) != NULL;
        }
        case DATASET_BACKEND_BLOOM: {
            DatasetBloom *db = (DatasetBloom *)ds->data;
            return BloomFilterTest(db->bloom, data, len);
        }
        default:
            return false;
    }
}
```

---

## 5. Lua 动态列表集成

### 5.1 Lua 回调接口

Suricata 支持通过 **Lua 脚本** 动态生成数据集条目，实现实时威胁情报拉取：

```c
// src/util-lua-dataset.h — Lua Dataset 接口
typedef struct LuaDataset_ {
    /* Lua 状态 */
    lua_State *L;

    /* 回调函数名 */
    const char *function_name;

    /* 数据集 */
    Dataset *dataset;
} LuaDataset;
```

### 5.2 Lua 脚本示例

```lua
-- dynamic_ip_feed.lua
-- 动态 IP 威胁情报拉取脚本

-- 返回要添加到数据集的 IP 列表
function get_dynamic_ips()
    local ips = {}

    -- 模拟从外部 API 获取
    local response = http.get("https://feeds.example.com/threat-ip-list")

    if response and response.status == 200 then
        -- 解析 JSON
        local data = json.decode(response.body)

        for _, entry in ipairs(data.ips) do
            table.insert(ips, entry.ip)
        end
    end

    return ips
end

-- 可选：返回要删除的 IP
function remove_stale_ips()
    local ips = {}
    -- 返回过期 IP 列表
    return ips
end
```

### 5.3 Lua Dataset 配置

```yaml
# suricata.yaml
datasets:
  inputs:
    # Lua 驱动的动态 IP 列表
    - name: "dynamic-threat-ips"
      type: ip
      persist: yes
      save: /var/lib/suricata/datasets/dynamic-threat-ips.txt
      # Lua 脚本配置
      lua:
        script: /etc/suricata/lua/dynamic_ip_feed.lua
        function: get_dynamic_ips
      # 刷新间隔（秒）
      update-interval: 300

    # Lua 驱动的 MD5 列表
    - name: "dynamic-malware"
      type: md5
      persist: yes
      save: /var/lib/suricata/datasets/dynamic-malware.txt
      lua:
        script: /etc/suricata/lua/malware_feed.lua
        function: get_malware_hashes
      update-interval: 600
```

### 5.4 Lua Dataset 执行流程

```c
// src/util-lua-dataset.c — Lua Dataset 加载
static int LuaDatasetLoad(LuaDataset *lua_ds)
{
    lua_State *L = lua_ds->L;

    /* 调用 Lua 函数 */
    lua_getglobal(L, lua_ds->function_name);
    if (lua_pcall(L, 0, 1, 0) != 0) {
        SCLogError("Lua function %s failed: %s",
                   lua_ds->function_name, lua_tostring(L, -1));
        lua_pop(L, 1);
        return -1;
    }

    /* 获取返回表 */
    if (!lua_istable(L, -1)) {
        SCLogError("Lua function %s must return a table",
                   lua_ds->function_name);
        lua_pop(L, 1);
        return -1;
    }

    /* 遍历表并添加到数据集 */
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        const char *value = lua_tostring(L, -1);
        if (value != NULL) {
            DatasetAdd(lua_ds->dataset, (uint8_t *)value, strlen(value));
        }
        lua_pop(L, 1);  // 弹出 value，保留 key
    }

    lua_pop(L, 1);  // 弹出返回表

    return 0;
}

// 定期刷新 Lua Dataset
static void *LuaDatasetRefresh(void *arg)
{
    LuaDataset *lua_ds = (LuaDataset *)arg;

    while (!g_running) {
        sleep(lua_ds->update_interval);

        /* 重新加载 Lua 数据 */
        LuaDatasetLoad(lua_ds);

        /* 如果配置了持久化，则保存 */
        if (lua_ds->dataset->save_path) {
            DatasetSave(lua_ds->dataset, lua_ds->dataset->save_path);
        }
    }

    return NULL;
}
```

---

## 6. 规则关键字

### 6.1 dstlive / srclive

```bash
# dstlive: 目标 IP 在数据集中
alert tcp any any -> any any (msg:"Blocked dest IP"; \
    dstlive:badips,100,200; sid:1000001;)

# srclive: 源 IP 在数据集中
alert tcp any any -> any any (msg:"Blocked source IP"; \
    srclive:known-attackers,90,100; sid:1000002;)
```

### 6.2 filemd5 / filesha256

```bash
# 文件 MD5 匹配
alert http any any -> any any (msg:"Malware download detected"; \
    filemd5:malware-hashes; sid:1000003;)

# 文件 SHA256 匹配
alert http any any -> any any (msg:"Known malicious file"; \
    filesha256:malware-sha256; sid:1000004;)
```

### 6.3 urilive

```bash
# URL 路径匹配
alert http any any -> any any (msg:"Malicious URL access"; \
    urilive:malicious-urls; sid:1000005;)
```

### 6.4 检测逻辑实现

```c
// src/detect-dataset.c — dataset 关键字检测
typedef struct DetectDatasetData_ {
    char *name;                   // Dataset 名称
    Dataset *dataset;             // 指向数据集
    uint8_t mode;                // SRC / DST
    uint8_t op;                  // 操作符
    uint64_t value;              // 阈值（可选）
} DetectDatasetData;

static int DetectDatasetMatch(DetectEngineThreadCtx *det_ctx,
                              Packet *p, const void *matcher)
{
    const DetectDatasetData *data = matcher;
    if (data == NULL || data->dataset == NULL) {
        return 0;
    }

    /* 获取 IP */
    uint8_t *ip = NULL;
    if (data->mode == DATASET_MODE_DST) {
        if (PKT_IS_IPV4(p)) {
            ip = (uint8_t *)&p->ip4h->dst_addr;
        } else if (PKT_IS_IPV6(p)) {
            ip = (uint8_t *)&p->ip6h->dst_addr;
        }
    } else {
        if (PKT_IS_IPV4(p)) {
            ip = (uint8_t *)&p->ip4h->src_addr;
        } else if (PKT_IS_IPV6(p)) {
            ip = (uint8_t *)&p->ip6h->src_addr;
        }
    }

    if (ip == NULL) {
        return 0;
    }

    /* 查找数据集 */
    uint32_t ip_len = PKT_IS_IPV4(p) ? 4 : 16;
    bool found = DatasetLookup(data->dataset, ip, ip_len);

    /* 带阈值的匹配 */
    if (found && data->op == DATASET_OP_SET) {
        /* 匹配即触发 */
        return found;
    } else if (found) {
        /* 检查阈值 */
        return (data->dataset->count >= data->value);
    }

    return 0;
}
```

---

## 7. filestore Dataset

### 7.1 概述

`filestore` 数据集用于**文件哈希持久化存储**，当检测到可疑文件时，将哈希存入列表供后续检测：

```yaml
# suricata.yaml
outputs:
  - files:
      # 启用文件存储
      enabled: yes
      # 存储目录
      directory: /var/log/suricata/files/
```

### 7.2 文件哈希采集

```c
// src/util-hash.h — 文件哈希
typedef struct FileHash_ {
    char *md5;
    char *sha256;
    char *sha1;
    uint64_t size;
    char *filename;
    TAILQ_ENTRY(FileHash) next;
} FileHash;
```

### 7.3 filestore 配置

```yaml
# suricata.yaml
filestore:
  # 存储类型
  type: sha256
  # 索引文件
  index: /var/lib/suricata/filestore.idx
  # 存储路径
  save-path: /var/lib/suricata/filestore/
  # 最大存储数量
  max-file-size: 100mb
  max-size: 10gb
```

---

## 8. 性能优化

### 8.1 Atomic 文件加载

大文件使用 **Atomic 加载**避免阻塞检测：

```c
// src/util-dataset.c — Atomic 加载
typedef struct DatasetAtomicLoad_ {
    char *tmp_path;
    char *final_path;
    pid_t pid;
    time_t start_time;
} DatasetAtomicLoad;

static int DatasetAtomicLoad(Dataset *ds, const char *path)
{
    char tmp_path[PATH_MAX];
    snprintf(tmp_path, sizeof(tmp_path), "%s.%d.tmp",
             path, getpid());

    /* 创建临时文件 */
    FILE *tmp_fp = fopen(tmp_path, "w");
    if (tmp_fp == NULL) {
        return -1;
    }

    /* 写入临时文件 */
    FILE *src_fp = fopen(path, "r");
    if (src_fp == NULL) {
        fclose(tmp_fp);
        unlink(tmp_path);
        return -1;
    }

    char line[1024];
    while (fgets(line, sizeof(line), src_fp) != NULL) {
        fputs(line, tmp_fp);
    }

    fclose(src_fp);
    fclose(tmp_fp);

    /* 原子重命名 */
    if (rename(tmp_path, path) != 0) {
        unlink(tmp_path);
        return -1;
    }

    /* 重新加载 */
    return DatasetLoad(ds, path);
}
```

### 8.2 LMDB 后端

对于超大列表（>1M 条目），使用 **LMDB** 持久化后端：

```c
// src/util-dataset-lmdb.h — LMDB Dataset
typedef struct DatasetLmdb_ {
    /* LMDB 环境 */
    MDB_env *env;
    /* LMDB 事务 */
    MDB_txn *txn;
    MDB_dbi dbi;
    /* 路径 */
    char *path;
} DatasetLmdb;

static DatasetLmdb *DatasetLmdbInit(const char *path)
{
    DatasetLmdb *lmdb = SCCalloc(1, sizeof(DatasetLmdb));

    /* 创建 LMDB 环境 */
    mdb_env_create(&lmdb->env);
    mdb_env_set_mapsize(lmdb->env, 2UL * 1024 * 1024 * 1024); // 2GB
    mdb_env_open(lmdb->env, path, MDB_CREATE, 0664);

    /* 开始读事务 */
    mdb_txn_begin(lmdb->env, NULL, MDB_RDONLY, &lmdb->txn);

    /* 打开数据库 */
    mdb_open(lmdb->txn, NULL, 0, &lmdb->dbi);

    return lmdb;
}

static int DatasetLmdbAdd(DatasetLmdb *lmdb,
                         const uint8_t *key, uint32_t klen)
{
    MDB_txn *txn;
    mdb_txn_begin(lmdb->env, NULL, 0, &txn);

    MDB_val k = { .mv_size = klen, .mv_data = (void *)key };
    MDB_val v = { .mv_size = 0, .mv_data = NULL };

    int rc = mdb_put(txn, lmdb->dbi, &k, &v, 0);
    mdb_txn_commit(txn);

    return (rc == 0) ? 0 : -1;
}
```

---

## 9. 小结

本章解析了 Suricata 的 Dataset 系统：

1. **Dataset 类型**：IP、MD5、SHA256、String、URL
2. **存储后端**：Hash、Bloom、Radix、LMDB
3. **配置**：suricata.yaml → datasets.{inputs, defaults}
4. **Lua 集成**：lua.script + lua.function 动态拉取
5. **规则关键字**：dstlive、srclive、filemd5、filesha256、urilive
6. **性能优化**：Atomic 加载、LMDB 大表、Bloom Filter 假阳性处理
7. **filestore**：文件哈希持久化存储
