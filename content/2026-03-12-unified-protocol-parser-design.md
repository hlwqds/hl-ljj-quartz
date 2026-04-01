---
title: Suricata 与 DeepFlow 统一协议解析插件设计方案
date: 2026-03-12
tags: [suricata, deepflow, plugin, wasm, protocol-parser]
---

> [!abstract] 核心思路
> 将协议解析逻辑抽离成**独立的核心库**，通过适配层同时支持 Suricata 和 DeepFlow。
>
> - **核心库**：Rust/Go 编写，包含所有协议解析逻辑
> - **Suricata 适配**：C 插件或 Wasm 插件
> - **DeepFlow 适配**：Wasm 插件
>
> **收益**：协议解析逻辑只需维护一份，两边复用。

---

## 1. 为什么要统一协议解析？

### 1.1 现状问题

```
当前状况：

Suricata 插件 (C/Rust)          DeepFlow 插件 (Wasm)
├─ HTTP 解析器                  ├─ HTTP 解析器
├─ MySQL 解析器                 ├─ MySQL 解析器
├─ Redis 解析器                 ├─ Redis 解析器
├─ 自定义协议 A                 ├─ 自定义协议 A
└─ 自定义协议 B                 └─ 自定义协议 B

问题：
├─ 重复开发（同一协议写两遍）
├─ 维护困难（bug 需要修两处）
├─ 行为不一致（可能产生不同结果）
└─ 测试成本翻倍
```

### 1.2 统一后的架构

```
                    ┌─────────────────────┐
                    │  协议解析核心库      │
                    │  (Rust / Go)        │
                    │                     │
                    │  ├─ HTTP Parser     │
                    │  ├─ MySQL Parser    │
                    │  ├─ Redis Parser    │
                    │  └─ Custom Protocol │
                    └──────────┬──────────┘
                               │
              ┌──────────────────┴──────────────────┐
              │                                     │
              ▼                                     ▼
    ┌─────────────────┐                   ┌─────────────────┐
    │ Suricata 适配层  │                   │ DeepFlow 适配层  │
    │ (C Wrapper)     │                   │ (Wasm Wrapper)  │
    └────────┬────────┘                   └────────┬────────┘
             │                                     │
             ▼                                     ▼
    ┌─────────────────┐                   ┌─────────────────┐
    │   Suricata      │                   │   DeepFlow      │
    │   用户态进程     │                   │   Agent         │
    └─────────────────┘                   └─────────────────┘
```

---

## 2. 核心库设计

### 2.1 接口定义

```rust
// protocol-core/src/lib.rs

/// 协议元数据
#[derive(Debug, Clone)]
pub struct ProtocolMetadata {
    /// 协议类型
    pub protocol: ProtocolType,
    /// 请求方法 (GET/POST/SELECT 等)
    pub method: Option<String>,
    /// 请求路径/资源
    pub path: Option<String>,
    /// 响应状态码
    pub status_code: Option<u16>,
    /// 请求体大小
    pub request_size: u64,
    /// 响应体大小
    pub response_size: u64,
    /// 协议版本
    pub version: Option<String>,
    /// 自定义字段 (协议特定)
    pub extra: HashMap<String, String>,
}

/// 协议类型
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProtocolType {
    Http1,
    Http2,
    Mysql,
    Redis,
    Dns,
    Kafka,
    Custom(u16),
    Unknown,
}

/// 解析方向
#[derive(Debug, Clone, Copy)]
pub enum ParseDirection {
    Request,
    Response,
}

/// 解析结果
#[derive(Debug)]
pub struct ParseResult {
    /// 是否需要更多数据
    pub need_more_data: bool,
    /// 解析出的元数据
    pub metadata: Option<ProtocolMetadata>,
    /// 消耗的字节数
    pub consumed_bytes: usize,
    /// 解析错误
    pub error: Option<String>,
}

/// 核心解析器 trait
pub trait ProtocolParser: Send + Sync {
    /// 协议名称
    fn name(&self) -> &str;

    /// 识别协议 (返回置信度 0-100)
    fn detect(&self, data: &[u8], direction: ParseDirection) -> u8;

    /// 解析协议
    fn parse(&self, data: &[u8], direction: ParseDirection) -> ParseResult;

    /// 重置解析器状态 (新连接时调用)
    fn reset(&mut self);
}
```

### 2.2 HTTP 解析器示例

```rust
// protocol-core/src/parsers/http.rs

use crate::{ParseDirection, ParseResult, ProtocolMetadata, ProtocolParser, ProtocolType};

pub struct Http1Parser {
    state: HttpState,
}

#[derive(Default)]
struct HttpState {
    in_request: bool,
    content_length: Option<u64>,
    chunked: bool,
    body_received: u64,
}

impl ProtocolParser for Http1Parser {
    fn name(&self) -> &str {
        "HTTP/1.x"
    }

    fn detect(&self, data: &[u8], direction: ParseDirection) -> u8 {
        // 简单的协议识别
        if data.len() < 3 {
            return 0;
        }

        match direction {
            ParseDirection::Request => {
                // 检查 HTTP 方法
                if data.starts_with(b"GET ") ||
                   data.starts_with(b"POST ") ||
                   data.starts_with(b"PUT ") ||
                   data.starts_with(b"DELETE ") ||
                   data.starts_with(b"HEAD ") {
                    95
                } else {
                    0
                }
            }
            ParseDirection::Response => {
                // 检查 HTTP/1.x 响应
                if data.starts_with(b"HTTP/1.") {
                    95
                } else {
                    0
                }
            }
        }
    }

    fn parse(&self, data: &[u8], direction: ParseDirection) -> ParseResult {
        // 找到头部结束位置
        let header_end = find_header_end(data);

        if header_end.is_none() {
            return ParseResult {
                need_more_data: true,
                metadata: None,
                consumed_bytes: 0,
                error: None,
            };
        }

        let header_end = header_end.unwrap();
        let header_data = &data[..header_end];

        // 解析头部
        let metadata = self.parse_headers(header_data, direction);

        // 判断是否需要读取 body
        let need_more = self.need_body(data, header_end);

        ParseResult {
            need_more_data: need_more,
            metadata: Some(metadata),
            consumed_bytes: if !need_more {
                self.total_message_size(data, header_end)
            } else {
                0
            },
            error: None,
        }
    }

    fn reset(&mut self) {
        self.state = HttpState::default();
    }
}

impl Http1Parser {
    fn parse_headers(&self, data: &[u8], direction: ParseDirection) -> ProtocolMetadata {
        let header_str = std::str::from_utf8(data).unwrap_or("");
        let mut metadata = ProtocolMetadata {
            protocol: ProtocolType::Http1,
            method: None,
            path: None,
            status_code: None,
            request_size: 0,
            response_size: 0,
            version: None,
            extra: HashMap::new(),
        };

        for line in header_str.lines() {
            match direction {
                ParseDirection::Request => {
                    // 解析请求行: GET /path HTTP/1.1
                    if line.starts_with("GET ") || line.starts_with("POST ") {
                        let parts: Vec<&str> = line.split_whitespace().collect();
                        if parts.len() >= 2 {
                            metadata.method = Some(parts[0].to_string());
                            metadata.path = Some(parts[1].to_string());
                        }
                        if parts.len() >= 3 {
                            metadata.version = Some(parts[2].to_string());
                        }
                    }
                    // 解析 Content-Length
                    if line.to_lowercase().starts_with("content-length:") {
                        metadata.request_size = line.split(':')
                            .nth(1)
                            .and_then(|s| s.trim().parse().ok())
                            .unwrap_or(0);
                    }
                }
                ParseDirection::Response => {
                    // 解析状态行: HTTP/1.1 200 OK
                    if line.starts_with("HTTP/") {
                        let parts: Vec<&str> = line.split_whitespace().collect();
                        if parts.len() >= 2 {
                            metadata.status_code = parts[1].parse().ok();
                            metadata.version = Some(parts[0].to_string());
                        }
                    }
                    // 解析 Content-Length
                    if line.to_lowercase().starts_with("content-length:") {
                        metadata.response_size = line.split(':')
                            .nth(1)
                            .and_then(|s| s.trim().parse().ok())
                            .unwrap_or(0);
                    }
                }
            }
        }

        metadata
    }
}

fn find_header_end(data: &[u8]) -> Option<usize> {
    // 查找 \r\n\r\n
    for i in 0..data.len().saturating_sub(3) {
        if &data[i..i+4] == b"\r\n\r\n" {
            return Some(i + 4);
        }
    }
    None
}
```

### 2.3 解析器注册表

```rust
// protocol-core/src/registry.rs

use std::sync::Arc;
use crate::ProtocolParser;

pub struct ParserRegistry {
    parsers: Vec<Arc<dyn ProtocolParser>>,
}

impl ParserRegistry {
    pub fn new() -> Self {
        let mut registry = Self { parsers: Vec::new() };

        // 注册内置解析器
        registry.register_builtin_parsers();

        registry
    }

    fn register_builtin_parsers(&mut self) {
        use crate::parsers::{Http1Parser, MysqlParser, RedisParser};

        self.register(Arc::new(Http1Parser::new()));
        self.register(Arc::new(MysqlParser::new()));
        self.register(Arc::new(RedisParser::new()));
    }

    pub fn register(&mut self, parser: Arc<dyn ProtocolParser>) {
        self.parsers.push(parser);
    }

    /// 自动检测协议
    pub fn detect(&self, data: &[u8], direction: ParseDirection) -> Option<Arc<dyn ProtocolParser>> {
        let mut best_match: Option<(Arc<dyn ProtocolParser>, u8)> = None;

        for parser in &self.parsers {
            let confidence = parser.detect(data, direction);
            if confidence > 50 && confidence > best_match.as_ref().map(|(_, c)| *c).unwrap_or(0) {
                best_match = Some((parser.clone(), confidence));
            }
        }

        best_match.map(|(p, _)| p)
    }
}
```

---

## 3. Suricata 适配层

### 3.1 作为 C 插件

```c
// suricata-plugin/sc_protocol_core.c

#include "suricata-plugin.h"
#include "protocol_core.h"  // Rust 编译的 C 绑定

// 流状态
typedef struct {
    void *rust_parser;      // Rust 解析器实例
    uint64_t flow_id;
    int direction;
} ScProtocolState;

// 插件初始化
static int ScProtocolCoreInit(void) {
    // 初始化 Rust 核心库
    protocol_core_init();
    return 0;
}

// 协议探测
static int ScProtocolCoreProbe(ThreadVars *tv, Packet *p, void *data) {
    uint8_t *payload = p->payload;
    uint32_t len = p->payload_len;

    // 调用 Rust 核心库的探测函数
    int direction = (p->flowflags & FLOW_PKT_TOSERVER) ? 0 : 1;
    const char *protocol = protocol_core_detect(payload, len, direction);

    if (protocol != NULL) {
        return 1;  // 匹配成功
    }
    return 0;
}

// 协议解析
static int ScProtocolCoreParse(
    ThreadVars *tv,
    Packet *p,
    Flow *f,
    void *data,
    uint8_t *payload,
    uint32_t len
) {
    ScProtocolState *state = (ScProtocolState *)data;

    int direction = (p->flowflags & FLOW_PKT_TOSERVER) ? 0 : 1;

    // 调用 Rust 核心库的解析函数
    ProtocolMetadata *metadata = protocol_core_parse(
        state->rust_parser,
        payload,
        len,
        direction
    );

    if (metadata != NULL) {
        // 将元数据附加到流
        // ...
    }

    return 0;
}

// 注册插件
void ScRegisterProtocolCore(void) {
    SCEnter();

    SCPlugin plugin = {
        .name = "protocol-core",
        .init = ScProtocolCoreInit,
        .probe = ScProtocolCoreProbe,
        .parse = ScProtocolCoreParse,
    };

    SCPluginRegister(&plugin);
}
```

### 3.2 作为 Wasm 插件 (Suricata 7.0+)

```rust
// suricata-plugin/src/wasm_adapter.rs

use protocol_core::{ParseDirection, ParserRegistry, ProtocolParser};
use wasm_bindgen::prelude::*;

static REGISTRY: once_cell::sync::Lazy<ParserRegistry> =
    once_cell::sync::Lazy::new(ParserRegistry::new);

#[wasm_bindgen]
pub struct SuricataParser {
    inner: Box<dyn ProtocolParser>,
}

#[wasm_bindgen]
impl SuricataParser {
    #[wasm_bindgen(constructor)]
    pub fn new(protocol_name: &str) -> Option<SuricataParser> {
        // 从注册表获取解析器
        REGISTRY.get(protocol_name)
            .map(|p| SuricataParser { inner: p.clone_box() })
    }

    #[wasm_bindgen]
    pub fn probe(&self, data: &[u8], is_request: bool) -> u8 {
        let direction = if is_request {
            ParseDirection::Request
        } else {
            ParseDirection::Response
        };
        self.inner.detect(data, direction)
    }

    #[wasm_bindgen]
    pub fn parse(&self, data: &[u8], is_request: bool) -> Option<JsValue> {
        let direction = if is_request {
            ParseDirection::Request
        } else {
            ParseDirection::Response
        };

        let result = self.inner.parse(data, direction);
        if result.metadata.is_some() {
            Some(JsValue::from_serde(&result.metadata).ok()?)
        } else {
            None
        }
    }
}
```

---

## 4. DeepFlow 适配层

```rust
// deepflow-plugin/src/lib.rs

use protocol_core::{ParseDirection, ParserRegistry, ProtocolMetadata};
use wasm_bindgen::prelude::*;
use serde::Serialize;

static REGISTRY: once_cell::sync::Lazy<ParserRegistry> =
    once_cell::sync::Lazy::new(ParserRegistry::new);

/// DeepFlow Wasm 插件入口
#[wasm_bindgen]
pub struct DeepFlowParser {
    registry: &'static ParserRegistry,
}

#[derive(Serialize)]
pub struct DfParseResult {
    pub protocol: String,
    pub method: Option<String>,
    pub path: Option<String>,
    pub status_code: Option<u16>,
    pub request_size: u64,
    pub response_size: u64,
    pub need_more_data: bool,
    pub consumed_bytes: usize,
}

#[wasm_bindgen]
impl DeepFlowParser {
    #[wasm_bindgen(constructor)]
    pub fn new() -> DeepFlowParser {
        DeepFlowParser {
            registry: &REGISTRY,
        }
    }

    /// 协议探测
    #[wasm_bindgen]
    pub fn detect(&self, data: &[u8], is_request: bool) -> Option<String> {
        let direction = if is_request {
            ParseDirection::Request
        } else {
            ParseDirection::Response
        };

        self.registry
            .detect(data, direction)
            .map(|p| p.name().to_string())
    }

    /// 解析协议
    #[wasm_bindgen]
    pub fn parse(&self, data: &[u8], is_request: bool) -> Option<JsValue> {
        let direction = if is_request {
            ParseDirection::Request
        } else {
            ParseDirection::Response
        };

        // 自动检测协议
        let parser = self.registry.detect(data, direction)?;

        // 解析
        let result = parser.parse(data, direction);

        // 转换为 DeepFlow 格式
        let df_result = result.metadata.map(|m| DfParseResult {
            protocol: format!("{:?}", m.protocol),
            method: m.method,
            path: m.path,
            status_code: m.status_code,
            request_size: m.request_size,
            response_size: m.response_size,
            need_more_data: result.need_more_data,
            consumed_bytes: result.consumed_bytes,
        });

        df_result.map(|r| JsValue::from_serde(&r).ok()).flatten()
    }

    /// 注册自定义协议
    #[wasm_bindgen]
    pub fn register_custom(&mut self, name: &str, detect_fn: js_sys::Function, parse_fn: js_sys::Function) {
        // 允许用户注册自定义协议
        // ...
    }
}
```

---

## 5. 数据流差异处理

### 5.1 Suricata 数据特点

```
Suricata 看到的数据：
├─ 已经是重组后的 TCP 流
├─ 可能包含多个请求/响应（HTTP pipelining）
├─ 数据可能不完整（流还在传输中）
└─ 需要处理流状态

适配层需要：
├─ 维护流状态机
├─ 处理分段传输
└─ 支持请求/响应配对
```

### 5.2 DeepFlow 数据特点

```
DeepFlow 看到的数据：
├─ syscall 层面的应用数据
├─ 一次 syscall 可能包含多个请求
├─ 或者一个请求跨多次 syscall
└─ 需要缓冲和边界识别

适配层需要：
├─ 跨 syscall 缓冲
├─ 边界识别
└─ 请求/响应关联
```

### 5.3 统一处理

```rust
// protocol-core/src/buffer.rs

/// 流缓冲区 - 统一处理两种场景
pub struct StreamBuffer {
    data: Vec<u8>,
    max_size: usize,
}

impl StreamBuffer {
    /// 追加数据
    pub fn append(&mut self, data: &[u8]) {
        if self.data.len() + data.len() <= self.max_size {
            self.data.extend_from_slice(data);
        }
    }

    /// 尝试解析一个完整消息
    pub fn try_parse<F>(&mut self, parser: &dyn ProtocolParser, direction: ParseDirection) -> Option<ProtocolMetadata> {
        let result = parser.parse(&self.data, direction);

        if !result.need_more_data && result.metadata.is_some() {
            // 消耗已解析的数据
            self.data.drain(..result.consumed_bytes);
            return result.metadata;
        }

        None
    }

    /// 重置缓冲区（新连接）
    pub fn reset(&mut self) {
        self.data.clear();
    }
}
```

---

## 6. 构建和部署

### 6.1 项目结构

```
unified-protocol-parser/
├── protocol-core/           # 核心解析库
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── parser.rs        # trait 定义
│   │   ├── registry.rs      # 解析器注册表
│   │   ├── buffer.rs        # 流缓冲
│   │   └── parsers/         # 内置解析器
│   │       ├── mod.rs
│   │       ├── http.rs
│   │       ├── mysql.rs
│   │       └── redis.rs
│   └── cbindgen.toml        # C 绑定配置
│
├── suricata-plugin/         # Suricata 适配
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── wasm_adapter.rs  # Wasm 适配
│   │   └── c_adapter.rs      # C 适配
│   └── build.rs
│
├── deepflow-plugin/         # DeepFlow 适配
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs
│
└── tests/
    ├── test_http.rs
    ├── test_mysql.rs
    └── integration/
        ├── suricata_test.rs
        └── deepflow_test.rs
```

### 6.2 构建脚本

```bash
#!/bin/bash
# build.sh

set -e

# 1. 构建核心库
cd protocol-core
cargo build --release

# 2. 生成 C 绑定（用于 Suricata C 插件）
cbindgen --config cbindgen.toml --crate protocol-core --output protocol_core.h

# 3. 构建 Suricata Wasm 插件
cd ../suricata-plugin
cargo build --release --target wasm32-unknown-unknown
wasm-opt -Oz -o suricata_protocol_parser.wasm \
    target/wasm32-unknown-unknown/release/suricata_plugin.wasm

# 4. 构建 DeepFlow Wasm 插件
cd ../deepflow-plugin
cargo build --release --target wasm32-unknown-unknown
wasm-opt -Oz -o deepflow_protocol_parser.wasm \
    target/wasm32-unknown-unknown/release/deepflow_plugin.wasm

echo "Build complete!"
```

### 6.3 部署配置

```yaml
# Suricata 配置
# /etc/suricata/suricata.yaml

app-layer:
  protocols:
    custom:
      enabled: yes
      wasm-plugin: /path/to/suricata_protocol_parser.wasm

# DeepFlow 配置
# /etc/deepflow-agent/config.yaml

l7-protocol-parser:
  wasm-plugins:
    - /path/to/deepflow_protocol_parser.wasm
```

---

## 7. 测试策略

### 7.1 单元测试

```rust
// tests/test_http.rs

use protocol_core::{Http1Parser, ParseDirection, ProtocolParser};

#[test]
fn test_http_request_parsing() {
    let parser = Http1Parser::new();

    let request = b"GET /api/users?id=123 HTTP/1.1\r\n\
                   Host: api.example.com\r\n\
                   Content-Length: 0\r\n\
                   \r\n";

    // 协议探测
    assert!(parser.detect(request, ParseDirection::Request) > 90);

    // 解析
    let result = parser.parse(request, ParseDirection::Request);
    assert!(!result.need_more_data);

    let meta = result.metadata.unwrap();
    assert_eq!(meta.method, Some("GET".to_string()));
    assert_eq!(meta.path, Some("/api/users?id=123".to_string()));
}

#[test]
fn test_http_chunked_response() {
    let mut parser = Http1Parser::new();

    let response = b"HTTP/1.1 200 OK\r\n\
                   Transfer-Encoding: chunked\r\n\
                   \r\n\
                   5\r\n\
                   hello\r\n\
                   0\r\n\
                   \r\n";

    let result = parser.parse(response, ParseDirection::Response);

    let meta = result.metadata.unwrap();
    assert_eq!(meta.status_code, Some(200));
    // 确认完整消息被识别
    assert!(!result.need_more_data);
}
```

### 7.2 集成测试

```rust
// tests/integration/suricata_test.rs

use suricata_plugin::SuricataParser;

#[test]
fn test_suricata_wasm_plugin() {
    let parser = SuricataParser::new("http").expect("Failed to create parser");

    let request = b"POST /login HTTP/1.1\r\nHost: example.com\r\n\r\n";

    assert!(parser.probe(request, true) > 50);

    let result = parser.parse(request, true);
    assert!(result.is_some());
}

// tests/integration/deepflow_test.rs

use deepflow_plugin::DeepFlowParser;

#[test]
fn test_deepflow_wasm_plugin() {
    let parser = DeepFlowParser::new();

    let request = b"GET /health HTTP/1.1\r\n\r\n";

    let protocol = parser.detect(request, true);
    assert_eq!(protocol, Some("HTTP/1.x".to_string()));

    let result = parser.parse(request, true);
    assert!(result.is_some());
}
```

---

## 8. 总结

### 8.1 架构优势

```
统一协议解析核心库
├─ ✅ 代码只写一次
├─ ✅ Bug 只修一处
├─ ✅ 行为完全一致
├─ ✅ 测试成本减半
└─ ✅ 新协议支持两边同时获得
```

### 8.2 工作量估算

| 任务              | 工作量     | 说明                  |
| :---------------- | :--------- | :-------------------- |
| **核心解析库**    | 2-4 周     | HTTP/MySQL/Redis 解析 |
| **Suricata 适配** | 1 周       | Wasm 插件封装         |
| **DeepFlow 适配** | 1 周       | Wasm 插件封装         |
| **测试**          | 1 周       | 单元测试 + 集成测试   |
| **总计**          | **5-7 周** | 一次性投入            |

### 8.3 维护成本对比

```
传统方式（各自开发）：
├─ 新协议支持：2× 开发时间
├─ Bug 修复：2× 修复时间
├─ 行为不一致：持续调试
└─ 总维护成本：2×

统一方案：
├─ 新协议支持：1× 开发时间
├─ Bug 修复：1× 修复时间
├─ 行为一致：无需额外调试
└─ 总维护成本：1×（节省 50%）
```

---

## 外部参考

- [Suricata Wasm Plugin](https://suricata.readthedocs.io/en/suricata-7.0/wasm-plugin.html)
- [DeepFlow Wasm Plugin](https://deepflow.io/docs/zh/advanced-integration/wasm-plugin/)
- [cbindgen - C bindings for Rust](https://github.com/mozilla/cbindgen)
- [wasm-bindgen](https://rustwasm.github.io/wasm-bindgen/)
