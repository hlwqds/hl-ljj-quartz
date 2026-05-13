---
title: "Suricata 深度探索 (四十三)：自定义协议 Parser 开发"
date: 2026-04-15
tags:
  - suricata
  - series
  - app-layer
  - parser
  - protocol
  - detection
description: "深入解析 Suricata 自定义协议解析器开发：AppLayer Register 框架、State 状态机、Probe 探测、RegisterTosser、Parser 生命周期、以及 Rust 插件集成"
---

> [!info] Suricata 2026 深度探索系列
> 0. [[2026-04-15-suricata-deep-dive-series-index|全栈学习路径总览]]
> ...
> 41. [[2026-04-15-suricata-deep-dive-ch41-iprep|第四十一章：IP 信誉系统]]
> 42. [[2026-04-15-suricata-deep-dive-ch42-dataset|第四十二章：Dataset 与动态列表]]
> 43. **第四十三章：自定义协议 Parser**
> 44. [[2026-04-15-suricata-deep-dive-ch44-rust|第四十四章：Rust 扩展]]
> 45. [[2026-04-15-suricata-deep-dive-ch45-cluster|第四十五章：集群模式]]

---

## 1. AppLayer 框架概述

Suricata 的 **AppLayer** 是应用层协议检测与解析的核心框架。不同于传统 IDS 仅做端口匹配，AppLayer 能深度解析协议（HTTP、DNS、TLS、SMB），提取协议内字段（主机名、SNI、域名、证书），并支持状态跟踪。

```
graph TD
    subgraph "AppLayer 架构"
        PROBE[\"Protocol Probe<br/>协议探测\"]
        REG[\"AppLayer Register<br/>解析器注册\"]
        STATE[\"State Machine<br/>状态机\"]
        DETECT[\"Detection Engine<br/>检测引擎\"]
        LOG[\"Logging<br/>日志输出\"]
    end

    subgraph \"已支持协议\"
        HTTP[\"HTTP/1.1\"]
        DNS[\"DNS\"]
        TLS[\"TLS\"]
        SMB[\"SMB\"]
        SSH[\"SSH\"]
    end

    PROBE --> REG
    REG --> STATE
    STATE --> DETECT
    STATE --> LOG
```

### 1.1 AppLayer 组件

| 组件 | 作用 | 示例 |
|:---|:---|:---|
| **Protocol Detection (Probe)** | 识别协议类型 | HTTP Probing → 检测 "GET/HTTP" |
| **State Machine** | 维护协议状态 | TCP Stream → HTTP Request/Response |
| **Parser** | 解析协议数据 | HTTP POST /files/upload |
| **Logger** | 输出结构化日志 | EVE JSON {event_type: http} |
| **Detector** | 提供检测字段 | http.host, http.uri |

### 1.2 解析流程

```
Packet arrives
    ↓
Decode (Ethernet → IP → TCP)
    ↓
AppLayer Detect (哪个协议?)
    ↓ (if TCP 80)
Probe: HTTP probing
    ↓ (match)
RegisterTosser: "Now I'll handle this flow"
    ↓
State Machine: HTTP/1.1 State
    ↓
Parser: Parse HTTP Request/Response
    ↓
Detection Engine: http.* keywords
    ↓
EVE Logger: JSON {event_type:http}
```

---

## 2. AppLayer 注册框架

### 2.1 注册表结构

```c
// src/app-layer.h — AppLayer 协议注册表
typedef struct AppLayerProtocol_ {
    /* 协议名称 */
    const char *name;

    /* 协议内部 ID */
    uint8_t ipproto;             // IP 协议 (TCP/UDP/SCTP)
    uint16_t port;               // 端口

    /* Probe 函数（协议探测）*/
    AppLayerProbingParserResult (*Probe)(
            void *protocol_stack, uint8_t *input, uint32_t len,
            uint8_t ipproto, void *options);

    /* State 解析器 */
    AppLayerParser *Parser;

    /* State 状态机 */
    AppLayerStateData *(*StateAlloc)(void);
    void (*StateFree)(void *);

    /* 标志 */
    uint32_t flags;
#define APPILER_PROTO_TCP        0x01
#define APPILER_PROTO_UDP        0x02
#define APPILER_PROTO_SCTP       0x04
#define APPILER_PROTO_PARSER     0x10
#define APPILER_PROTO_DETECTOR_TLS 0x20

    /* 后续处理 */
    struct AppLayerProtocol_ *next;
} AppLayerProtocol;
```

### 2.2 AppLayerParser 结构

```c
// src/app-layer-parser.h — 解析器定义
typedef struct AppLayerParser_ {
    /* 名称 */
    const char *name;

    /* Direction */
    uint8_t dir;                // STREAM_TOCLIENT / STREAM_TOSERVER

    /* 解析函数 */
    AppLayerResult (*Parser)(
            void *protocol_stack, uint8_t *input, uint32_t len);

    /* State 更新 */
    int (*StateUpdate)(void *protocol_stack, uint8_t *input,
                      uint32_t len);

    /* TX 结束检查 */
    int (*TxComplete)(void *protocol_stack);

    /* TX 超时处理 */
    void (*TxTimeout)(void *protocol_stack);

    /* 状态溢出处理 */
    void (*StateOverflow)(void *protocol_stack);

    /* 分离/合并 */
    int (*分离)(void *, void *);
    int (*合并)(void *, void *);
} AppLayerParser;
```

### 2.3 注册函数

```c
// src/app-layer.c — 注册 AppLayer 协议
int AppLayerRegisterProtocol(AppLayerProtocol *protocol)
{
    /* 检查是否已注册 */
    if (AppLayerFindProtocol(protocol->name, protocol->ipproto) != NULL) {
        SCLogWarning("Protocol %s already registered", protocol->name);
        return -1;
    }

    /* 插入链表 */
    protocol->next = app_protocols;
    app_protocols = protocol;

    SCLogInfo("Registered AppLayer protocol: %s", protocol->name);
    return 0;
}

// 查找已注册协议
AppLayerProtocol *AppLayerFindProtocol(const char *name, uint8_t ipproto)
{
    AppLayerProtocol *p = app_protocols;
    while (p != NULL) {
        if (strcmp(p->name, name) == 0 && p->ipproto == ipproto) {
            return p;
        }
        p = p->next;
    }
    return NULL;
}
```

---

## 3. 自定义协议开发

### 3.1 示例：自定义游戏协议 "GameX"

假设我们要开发一个自定义游戏协议检测器，支持：
- 端口 9999
- 消息格式：`[HEADER(4)][TYPE(2)][LEN(4)][DATA(LEN)]`
- HEADER: `0x47 0x58 0x50 0x4C` ("GXPL")

```c
// src/app-layer-gamex.h — GameX 协议头
typedef struct GameXHeader_ {
    uint8_t magic[4];            // "GXPL" = 0x47 0x58 0x50 0x4C
    uint16_t msg_type;           // 消息类型
    uint32_t msg_len;            // 后续数据长度
} __attribute__((packed)) GameXHeader;

#define GAMEX_MAGIC {0x47, 0x58, 0x50, 0x4C}
#define GAMEX_PORT 9999
```

### 3.2 State 定义

```c
// src/app-layer-gamex.h — GameX State
typedef struct GameXState_ {
    /* 解析状态 */
    enum {
        GAMEX_STATE_NEW = 0,     // 初始
        GAMEX_STATE_HEADER,      // 等待 Header
        GAMEX_STATE_DATA,        // 等待 Data
    } state;

    /* 残留数据 */
    uint8_t *buffer;
    uint32_t buffer_len;
    uint32_t buffer_size;

    /* 已解析的事务 */
    TAILQ_HEAD(, GameXTransaction_) tx_list;
    uint64_t tx_count;

    /* 统计 */
    uint64_t total_processed;
    uint64_t total_bytes;
} GameXState;

// 事务
typedef struct GameXTransaction_ {
    uint64_t tx_id;
    uint16_t msg_type;
    uint8_t *data;
    uint32_t data_len;
    TAILQ_ENTRY(GameXTransaction_) next;
} GameXTransaction;
```

### 3.3 State 分配/释放

```c
// src/app-layer-gamex.c — State 管理
static void *GameXStateAlloc(void)
{
    GameXState *state = SCCalloc(1, sizeof(GameXState));
    if (state == NULL) {
        return NULL;
    }

    state->state = GAMEX_STATE_NEW;
    TAILQ_INIT(&state->tx_list);
    state->tx_count = 0;

    return state;
}

static void GameXStateFree(void *p)
{
    GameXState *state = (GameXState *)p;
    if (state == NULL) {
        return;
    }

    /* 释放 buffer */
    if (state->buffer != NULL) {
        SCFree(state->buffer);
    }

    /* 释放事务 */
    GameXTransaction *tx;
    while ((tx = TAILQ_FIRST(&state->tx_list)) != NULL) {
        TAILQ_REMOVE(&state->tx_list, tx, next);
        if (tx->data != NULL) {
            SCFree(tx->data);
        }
        SCFree(tx);
    }

    SCFree(state);
}
```

### 3.4 Probing (协议探测)

```c
// src/app-layer-gamex.c — 协议探测
static AppLayerProbingParserResult GameXProbe(
    void *protocol_stack, uint8_t *input, uint32_t len,
    uint8_t ipproto, void *options)
{
    /* 检查最小长度 */
    if (len < sizeof(GameXHeader)) {
        return APP_LAYER_PROBING_PARSER_INCOMPLETE;
    }

    /* 检查 Magic */
    GameXHeader *hdr = (GameXHeader *)input;
    uint8_t expected_magic[] = GAMEX_MAGIC;

    if (memcmp(hdr->magic, expected_magic, 4) == 0) {
        /* 匹配 */
        return APP_LAYER_PROBING_PARSER_OK;
    }

    /* 不匹配，跳过此端口的 GameX 检测 */
    return APP_LAYER_PROBING_PARSER_NOT_FOUND;
}
```

### 3.5 解析器实现

```c
// src/app-layer-gamex.c — 数据解析
static AppLayerResult GameXParseRequest(
    void *protocol_stack, uint8_t *input, uint32_t len)
{
    /* 获取 Stream 和 State */
    Flow *f = (Flow *)protocol_stack;
    GameXState *state = (GameXState *)f->alstate;
    TcpStream *stream = &f->server_stream;  // 或 client_stream

    /* 追加到残留 buffer */
    if (state->buffer_len + len > state->buffer_size) {
        state->buffer_size = state->buffer_len + len + 1024;
        state->buffer = SCRealloc(state->buffer, state->buffer_size);
    }
    memcpy(state->buffer + state->buffer_len, input, len);
    state->buffer_len += len;

    /* 循环解析 */
    while (state->buffer_len >= sizeof(GameXHeader)) {
        GameXHeader *hdr = (GameXHeader *)state->buffer;

        /* 检查 Magic */
        uint8_t expected_magic[] = GAMEX_MAGIC;
        if (memcmp(hdr->magic, expected_magic, 4) != 0) {
            /* 数据错误，跳过一个字节尝试同步 */
            memmove(state->buffer, state->buffer + 1, state->buffer_len - 1);
            state->buffer_len--;
            continue;
        }

        /* 检查完整消息 */
        uint32_t total_msg_len = sizeof(GameXHeader) + hdr->msg_len;
        if (state->buffer_len < total_msg_len) {
            /* 数据不完整，等待更多 */
            break;
        }

        /* 创建事务 */
        GameXTransaction *tx = SCCalloc(1, sizeof(GameXTransaction));
        tx->tx_id = state->tx_count++;
        tx->msg_type = hdr->msg_type;
        tx->data_len = hdr->msg_len;
        tx->data = SCMalloc(hdr->msg_len);
        memcpy(tx->data, state->buffer + sizeof(GameXHeader), hdr->msg_len);

        TAILQ_INSERT_TAIL(&state->tx_list, tx);
        state->total_processed++;

        /* 移动 buffer */
        state->buffer_len -= total_msg_len;
        if (state->buffer_len > 0) {
            memmove(state->buffer, state->buffer + total_msg_len,
                    state->buffer_len);
        }
    }

    return APP_LAYER_OK;
}

static AppLayerResult GameXParseResponse(
    void *protocol_stack, uint8_t *input, uint32_t len)
{
    /* 响应解析（与请求类似）*/
    return GameXParseRequest(protocol_stack, input, len);
}
```

### 3.6 注册协议

```c
// src/app-layer-gamex.c — 注册 GameX
void GameXRegister(void)
{
    /* 分配 Parser */
    AppLayerParser *parser = SCCalloc(1, sizeof(AppLayerParser));
    parser->name = "GameX";
    parser->IPPROTO_TCP = 1;
    parser->Parser[0] = GameXParseRequest;   // TOSERVER
    parser->Parser[1] = GameXParseResponse;  // TOCLIENT
    parser->StateAlloc = GameXStateAlloc;
    parser->StateFree = GameXStateFree;

    /* 注册协议 */
    AppLayerRegisterProtocol(parser);

    /* 注册端口 */
    AppLayerRegisterPort(TCP, GAMEX_PORT, "GameX", parser);

    /* 注册 Probing Parser */
    AppLayerRegisterProbingParser(IPPROTO_TCP, GAMEX_PORT,
                                  "GameX", GameXProbe, 100);

    SCLogInfo("GameX protocol registered on port %d", GAMEX_PORT);
}
```

---

## 4. AppLayer 注册到检测引擎

### 4.1 注册检测字段

```c
// src/detect-gamex.h — GameX 检测字段
typedef enum GameXDetectMatch_ {
    GAMEX_DETECT_TYPE = 0,
    GAMEX_DETECT_DATA,
} GameXDetectMatch;

static int DetectGameXTypeSetup(DetectEngineCtx *de_ctx,
                                Signature *s, const char *optstr)
{
    /* 获取类型值 */
    int type = atoi(optstr);

    DetectGameXData *data = SCCalloc(1, sizeof(DetectGameXData));
    data->type = (uint16_t)type;

    if (SigMatchAppendSMToList(de_ctx, s, DETECT_GAMEX_TYPE,
                               data, g_gamex_list_id) == NULL) {
        SCFree(data);
        return -1;
    }

    return 0;
}

static int DetectGameXTypeMatch(DetectEngineThreadCtx *det_ctx,
                                 Packet *p, const void *matcher)
{
    const DetectGameXData *data = matcher;
    GameXState *state = (GameXState *)p->flow->alstate;

    /* 遍历事务查找匹配类型 */
    GameXTransaction *tx;
    TAILQ_FOREACH(tx, &state->tx_list, next) {
        if (tx->msg_type == data->type) {
            return 1;
        }
    }
    return 0;
}

/* 注册关键字 */
void DetectGameXRegister(void)
{
    /* 注册 keyword */
    sigmatch_table[DETECT_GAMEX_TYPE].name = "gamex.type";
    sigmatch_table[DETECT_GAMEX_TYPE].desc = "GameX message type";
    sigmatch_table[DETECT_GAMEX_TYPE].Match = DetectGameXTypeMatch;
    sigmatch_table[DETECT_GAMEX_TYPE].Setup = DetectGameXTypeSetup;
    sigmatch_table[DETECT_GAMEX_TYPE].Free = DetectGameXTypeFree;

    /* 注册字段到 app-layer */
    AppLayerRegisterMatch("gamex.type", DetectGameXTypeMatch);
}
```

### 4.2 规则示例

```bash
# 检测 GameX 特定消息类型
alert gamex any any -> any any (msg:"GameX Login Request"; \
    gamex.type:1; sid:1000001;)

# 检测包含特定数据的 GameX 消息
alert gamex any any -> any any (msg:"GameX Admin Command"; \
    gamex.data; content:"admin|00|"; sid:1000002;)
```

---

## 5. EVE JSON 日志输出

### 5.1 Logger 注册

```c
// src/output-gamex.h — GameX Logger
typedef struct OutputGameXCtx_ {
    /* 日志输出上下文 */
    LogFileCtx *file_ctx;
    uint32_t flags;
} OutputGameXCtx;

static int GameXLogger(ThreadVars *tv, void *thread_data,
                       const Packet *p, Flow *f, void *state,
                       uint8_t *data, uint32_t data_len)
{
    OutputGameXCtx *ctx = (OutputGameXCtx *)thread_data;
    GameXState *gx_state = (GameXState *)state;

    /* 遍历事务输出 JSON */
    GameXTransaction *tx;
    TAILQ_FOREACH(tx, &gx_state->tx_list, next) {
        /* 构建 JSON */
        json_t *js = json_object();
        json_object_set_new(js, "timestamp", json_string(TimeGet()));
        json_object_set_new(js, "src_ip", json_string(FlowPrintSrcIP(f)));
        json_object_set_new(js, "dest_ip", json_string(FlowPrintDstIP(f)));
        json_object_set_new(js, "msg_type", json_integer(tx->msg_type));
        json_object_set_new(js, "tx_id", json_integer(tx->tx_id));

        if (tx->data_len > 0) {
            json_object_set_new(js, "data",
                json_string_n((char *)tx->data, tx->data_len));
        }

        /* 输出到 EVE */
        OutputJSON(js, ctx->file_ctx);

        json_object_clear(js);
    }

    return 0;
}

/* 注册 Logger */
void GameXLogRegister(void)
{
    /* 注册输出类型 */
    OutputRegisterPacketLog(LOGGER_GAMEX, "GameX",
                            GameXLoggerInit, NULL, GameXLogger);

    /* 配置 EVE 输出 */
    EveGameXAddConfig();
}
```

### 5.2 EVE JSON 格式

```json
{
  "timestamp": "2026-04-15T10:30:00.000000+0000",
  "event_type": "gamex",
  "src_ip": "192.168.1.100",
  "src_port": 54321,
  "dest_ip": "10.0.0.1",
  "dest_port": 9999,
  "gamex": {
    "tx_id": 1,
    "msg_type": 1,
    "data": "..."
  }
}
```

---

## 6. State 超时与清理

### 6.1 TX 超时处理

```c
// src/app-layer-gamex.c — TX 超时
static void GameXTxTimeout(void *p)
{
    GameXState *state = (GameXState *)p;

    /* 清理超时事务（超过 60 秒）*/
    uint64_t now = TimeGet();
    GameXTransaction *tx, *tmp;
    TAILQ_FOREACH_SAFE(tx, &state->tx_list, next, tmp) {
        if (now - tx->timestamp > 60) {
            TAILQ_REMOVE(&state->tx_list, tx, next);
            if (tx->data) SCFree(tx->data);
            SCFree(tx);
        }
    }
}
```

### 6.2 State 溢出处理

```c
// src/app-layer-gamex.c — 状态溢出
static void GameXStateOverflow(void *p)
{
    GameXState *state = (GameXState *)p;

    /* 记录警告 */
    SCLogWarning("GameX state overflow on flow, clearing state");

    /* 清空所有未完成事务 */
    GameXTransaction *tx;
    while ((tx = TAILQ_FIRST(&state->tx_list)) != NULL) {
        TAILQ_REMOVE(&state->tx_list, tx, next);
        if (tx->data) SCFree(tx->data);
        SCFree(tx);
    }

    /* 重置 buffer */
    if (state->buffer) {
        SCFree(state->buffer);
        state->buffer = NULL;
    }
    state->buffer_len = 0;
    state->buffer_size = 0;
    state->state = GAMEX_STATE_NEW;
}
```

---

## 7. 多线程安全

### 7.1 Per-State 锁

```c
// src/app-layer-gamex.h — State 锁
typedef struct GameXState_ {
    /* ... 其他字段 ... */

    /* State 锁（多线程安全）*/
    SCMutex lock;
} GameXState;

// 线程安全解析
static AppLayerResult GameXParseRequestTS(void *protocol_stack,
                                           uint8_t *input, uint32_t len)
{
    Flow *f = (Flow *)protocol_stack;
    GameXState *state = (GameXState *)f->alstate;

    SCMutexLock(&state->lock);
    AppLayerResult ret = GameXParseRequest(protocol_stack, input, len);
    SCMutexUnlock(&state->lock);

    return ret;
}
```

### 7.2 无锁设计（推荐）

大多数情况下，**每个 Flow 只有一个线程处理**，无需额外锁：

```c
// src/app-layer-gamex.c — Flow 锁模型
/*
 * Flow 锁保护：
 * - 主线程 (Stream Splitter) → 单线程解析
 * - 异步事件线程 → 只读访问
 *
 * 结论：只要 Stream Splitter 正确同步，无需额外锁
 */
```

---

## 8. 配置启用

### 8.1 suricata.yaml 配置

```yaml
# suricata.yaml
app-layer:
  protocols:
    gamex:
      enabled: yes
      # 端口配置
      port: 9999
      # 检测配置
      detection:
        enabled: yes
        trace: no              # 调试追踪
      # 日志配置
      log:
        enabled: yes
        extented: yes          # 详细日志
```

### 8.2 编译集成

```bash
# 将 gamex.c 添加到 Makefile.am
src_app_SOURCES += \
    app-layer-gamex.c \
    app-layer-gamex.h

# 或在 CMakeLists.txt 中
# src/CMakeLists.txt
# add_module(gamex app-layer-gamex.c app-layer-gamex.h)
```

---

## 9. 小结

本章解析了 Suricata 自定义协议 Parser 开发：

1. **AppLayer 框架**：Probe → Register → State Machine → Parser → Logger
2. **协议探测**：Magic 匹配、端口注册
3. **State 管理**：StateAlloc/StateFree、残留数据处理
4. **Parser 实现**：Stream Splitter 模式、完整消息处理
5. **检测集成**：注册关键字、规则编写
6. **EVE 输出**：JSON Logger、完整事务追踪
7. **超时与清理**：TxTimeout、StateOverflow
8. **多线程安全**：Flow 锁模型、无锁设计原则
