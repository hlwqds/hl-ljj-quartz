---
title: QHSM 解析器返回值异常导致协议禁用的底层深度分析
date: 2026-01-08 00:00:00
pin: true
tags: [Suricata, debug, AppLayer, FFI, QHSM]
---

## 1. 核心机制：Rust 与 C 的 FFI 交互

当 Rust 插件执行解析并返回结果时，`AppLayerResult` 枚举会跨越 FFI 边界转换为 C 层的 `AppLayerResult` 结构体。

### Rust 定义 (`rust/src/applayer.rs`):

```rust
pub enum AppLayerResult {
    Ok,
    Err,
    Incomplete(u32, u32), // (consumed, needed)
}
```

### C 层接收到的结构 (`src/app-layer-parser.h`):

```c
typedef struct AppLayerResult_ {
    int status;      /* 0: Ok, -1: Err, 1: Incomplete */
    uint32_t consumed;
    uint32_t needed;
} AppLayerResult;
```

## 2. 严苛的校验规则及数学逻辑

在 `src/app-layer-parser.c:987` 中，Suricata 对 `Incomplete` 状态实施了两条铁律，违反任何一条都会导致协议被“判死刑”。

### 规则一：消费溢出 (The Overshoot Rule)

**表达式**：`res.consumed > input_len`

- **含义**：解析器声称消耗的字节数比 Suricata 传递给它的字节数还要多。
- **数学逻辑**：这是物理不可能的。
- **常见成因**：在 Rust 循环解析多个报文时，错误地累加了全局偏移量，或者在计算 `input.len() - start.len()` 时，`input` 指向了错误的起始位置。

### 规则二：提前退出/资源浪费 (The Undershoot/Contradiction Rule)

**表达式**：`res.needed + res.consumed < input_len`

- **含义**：解析器声称当前数据不够（返回了 `needed > 0`），但它“已消耗”和“声称还想要”的总和，竟然比当前 Buffer 里**现成的数据**还要少。
- **数学逻辑**：`input_len - res.consumed` 是当前 Buffer 里剩余的数据。如果 `res.needed` 小于这个剩余量，说明 Suricata 手里已经有你想要的数据了，你却告诉我“数据不够”。
- **悖论例子**：Buffer 长度 100，解析器消耗了 10，声称还需要 20。此时总和 30 < 100。Suricata 认为：我手里还有 90 字节（100-10）没给你看，你却管我要 20 字节并说“不够”，这说明解析器逻辑存在矛盾。

## 3. 协议禁用的连锁反应 (Chain Reaction)

当校验失败跳转至 `error:` 标签时，系统执行“焦土政策”：

1.  **计数器增加**：`AppLayerIncInternalErrorCounter` 增加。这在 `stats.log` 中表现为 `app_layer.internal_error`。
2.  **TCP 流拦截**：`StreamTcpDisableAppLayer(f)` 被调用。
    - 设置 `f->flags |= FLOW_TOSERVER_AL_DISCARD` 和 `FLOW_TOCLIENT_AL_DISCARD`。
    - **后果**：流重组引擎（Stream Engine）在后续收到 ACK 触发数据推送时，会检查此标志。一旦发现 Discard，数据将直接在重组层被丢弃，**永远不会再到达应用层代码**。
3.  **解析器状态封死**：`AppLayerParserSetEOF(pstate)`。
    - 设置 `pstate->flags |= (APP_LAYER_PARSER_EOF_TS | APP_LAYER_PARSER_EOF_TC)`。
    - **后果**：该流被标记为应用层结束，任何后续尝试调用解析器的行为都会被拦截。

## 4. 典型错误场景模拟 (Case Study)

在 `qhsm.rs` 的循环中：

```rust
let mut start = input;
while !start.is_empty() {
    match parser::parse(start, op_code) {
        Ok((rem, qhsm)) => {
            // ... 处理逻辑 ...
            start = rem;
        }
        Err(nom7::Err::Incomplete(_)) => {
            // 错误发生在这里！
            let consumed = input.len() - start.len();
            let needed = start.len() + 1; // 假设逻辑错误：只管要了剩余长度+1
            return AppLayerResult::incomplete(consumed as u32, needed as u32);
        }
    }
}
```

**错误点分析**：如果 `input_len` 是 200，`start` 是在处理了部分数据后的剩余部分（比如长度还剩 50）。
此时 `consumed = 200 - 50 = 150`。
如果代码返回 `needed = 1`。
校验公式：`150 (consumed) + 1 (needed) = 151`。
由于 `151 < 200` (input_len)，触发 **规则二**，协议立即被禁用。

## 5. 调试与排查工具

- **GDB 断点**：
  `b app-layer-parser.c:987`
  通过 `p res` 和 `p input_len` 查看触发禁用的具体数值。
- **Rust Log**：
  在 `qhsm.rs` 中增加 `SCLogDebug!("consumed {} needed {} len {}", consumed, needed, input.len())`，观察哪一包触发了不满足 `consumed + needed >= input_len` 的情况。

## 6. 最终结论

Suricata 核心层对解析器的返回值要求是**严格一致性**的。解析器不能“敷衍”地要求更多数据，必须证明它确实已经看完了当前提供的所有可用数据，或者它要求的增量确实超过了当前 Buffer 的剩余量。正确的做法通常是：
`needed = (原本解析需要的总长度) - (当前 start 的长度)`，且确保这个 `needed` 至少让总请求量超过 `input_len`。
