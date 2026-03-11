---
title: Suricata stream reassemly(ai)
date: 2025-12-02 00:11:00
pin: true
tags: [suricata]
---

# Suricata TCP Stream Reassembly & AppLayer Interaction Analysis

本文档基于对 Suricata 源代码的深入分析，总结了 TCP 流重组（Stream Reassembly）、应用层交互、关键标志位及其背后的设计逻辑。

## 1. 流与数据包关键标志位

### `FLOW_PKT_TOSERVER_FIRST`

- **含义**：标识一个 Flow 在 **To Server**（客户端 -> 服务器）方向上的**第一个**数据包。
- **作用**：
  1.  **协议检测关键点**：许多应用层协议（如 HTTP GET, TLS ClientHello）的关键特征出现在首包。标记它有助于检测引擎优先进行协议识别。
  2.  **状态初始化**：触发流在该方向上的初始化逻辑。
  3.  **性能优化**：避免在后续非首包上重复执行只针对起始包的昂贵检查。
  4.  **Hook 触发**：触发 `SIGNATURE_HOOK_PKT_FLOW_START` 等事件，供其他模块使用。

### `FLOW_WRONG_THREAD` (Packet on Wrong Thread)

- **含义**：同一个流（Flow）的数据包被分发到了不同的处理线程（CPU Core），破坏了流的局部性。
- **两种情况**：
  1.  **同向漂移（Same Direction Mismatch）**：
      - **现象**：同一个方向（如 TS）的包在不同线程。
      - **后果**：**触发 `tcp.pkt_on_wrong_thread` 计数器和 `stream.wrong_thread` 告警**。这是严重的异常，通常意味着哈希计算错误或网卡分发问题。
  2.  **异向分离（Cross Direction Mismatch）**：
      - **现象**：TS 方向在线程 A，TC 方向在线程 B。
      - **后果**：**通常不直接告警**（可能是非对称 RSS 哈希导致），也没有专门的计数器。但这会导致严重的**锁竞争（Mutex Contention）**，因为两个线程需频繁争抢同一个 Flow 的锁，显著降低性能。
- **排查**：检查 `stats.log` 中的 `tcp.pkt_on_wrong_thread` 以及 CPU 使用率（系统态占用高）。

### `FLOW_STATE_ESTABLISHED` vs `PKT_PROTO_DETECT_TS_DONE`

这是一个常见的误区，两者截然不同：

- **`FLOW_STATE_ESTABLISHED`**：
  - **层面**：L3/L4 连接状态。
  - **含义**：TCP 三次握手完成，双向通信建立。
  - **行为**：**安全检测（IDS/IPS）继续进行**。它主要用于切换超时策略（使用更长的 `est_timeout`）和匹配 `flow:established` 规则。
- **`PKT_PROTO_DETECT_TS_DONE`**：
  - **层面**：L7 应用层协议识别。
  - **含义**：协议识别完成（如确认为 HTTP）。
  - **行为**：**协议探测（猜测）停止**，但**内容解析（Parsing）和检测（Detection）继续**。Suricata 不再对后续包进行“这是什么协议”的猜测。

### `FLOW_NOPAYLOAD_INSPECTION`

- **含义**：停止对该 Flow 的后续数据进行**载荷检测（DPI）**。
- **触发场景**：
  1.  **错误熔断**：解析器遇到无法处理的错误或死循环。
  2.  **资源限制**：达到内存限制（Memcap）或异常策略（Exception Policy）触发。
  3.  **加密流量**：确定流量加密且无法解密，继续检查载荷无意义。
- **效果**：后续包只做头部检查和流状态维护，不再送入应用层解析器。

### `STREAMTCP_FLAG_ASYNC`

- **含义**：标识该 TCP 流处于**“异步”或“单向”模式**（通常由 `stream.async-oneside` 配置启用）。
- **背景**：应对非对称路由或 TAP 镜像丢包导致的单向流量。
- **作用**：
  - **放宽检查**：跳过严格的滑动窗口和序列号连续性检查。
  - **容忍缺失**：即使只看到单向流量（如只有 Response），也尝试重组和检测。
  - **自动恢复**：一旦检测到双向流量（Client 和 Server 都有包），自动清除该标志，恢复严格模式。

### `STREAM_PKT_BROKEN_ACK`

- **含义**：异常的 TCP ACK 包。
- **判定条件**：`!(th_flags & TH_ACK) && (ack_seq != 0)`。即 TCP 头部中 `ACK` 标志位未设置，但 `Acknowledgement Number` 字段却不为 0。
- **用途**：记录协议违规，可能指示畸形包、Fuzzing 测试或非标准协议栈实现。

### `STREAMTCP_INIT_FLAG_INLINE`

- **含义**：指示 Suricata 运行在 **IPS (Inline)** 模式。
- **影响**：
  - 激活主动丢包（Drop）相关的流状态维护逻辑。
  - 启用更严格的安全检查（防止 IPS 逃逸）。
  - 改变数据流更新方向策略（倾向于更激进的状态更新）。

---

## 2. TCP 重组与应用层交互核心 (`ReassembleUpdateAppLayer`)

`ReassembleUpdateAppLayer` 是连接 TCP 协议栈（L4）和应用层解析器（L7）的**“网关”**。它负责将 TCP 层的乱序字节流整理成有序数据，投递给应用层。

### 核心工作流程

1.  **获取进度**：读取 `STREAM_APP_PROGRESS`，获知应用层当前处理到了流的哪个绝对位置。
2.  **数据拉取 (`GetAppBuffer`)**：
    - 从重组缓冲区（红黑树）中查找从当前进度开始的连续数据。
    - **GAP 检测**：如果当前位置没数据，但缓冲区里有更靠后的数据块，则返回 `mydata=NULL`，并计算出 **GAP**（缺失数据）的长度。
3.  **ACK 确认 (`AdjustToAcked`)**：
    - **IDS 模式关键策略**：默认情况下，**只投递已被 ACK 确认的数据**。
    - 如果数据在缓冲区里但还没被 ACK，`data_len` 会被截断为 0，系统会等待 ACK。
4.  **GAP 处理 (`CheckGap`)**：
    - 如果 `GetAppBuffer` 返回 GAP，且 `last_ack`（接收方确认号）已经越过了当前进度。
    - **判定**：这是一个**“已被 ACK 但我没抓到”**的 GAP（丢包）。
    - **处理策略**：**“向前看 (Look Forward)”**。
      - 立即调用 `AppLayerHandleTCPData` 通知应用层（`STREAM_GAP`）。
      - **强制推进 `app_progress` 跳过 GAP**。
      - **后果**：后续如果迟到的重传包填补了这个 GAP，Suricata 会因为进度已更新而忽略它。这是为了防止解析器死锁和保证实时性。
    - **`data_required` 消耗**：GAP 在逻辑上也是数据流。如果应用层期待 500 字节，来了 200 字节 GAP，需求量应减为 300。
5.  **数据投递 (`AppLayerHandleTCPData`)**：
    - 将连续、有序、已确认的数据（或 GAP 信号）交给具体协议解析器（HTTP, TLS 等）。
    - 使用 `enum StreamUpdateDir` 指定方向。

### 关键数据结构与宏

#### `StreamingBufferBlock`

- **本质**：数据的**元数据索引**。
- **结构**：红黑树节点，包含 `offset`（绝对偏移）和 `len`。**不存实际数据**（数据在 `StreamingBufferRegion`）。
- **优势**：利用红黑树实现 O(log N) 的乱序插入、查找和合并，高效处理碎片化数据。

#### `STREAM_APP_PROGRESS` (双值设计)

- **公式**：`STREAM_BASE_OFFSET(stream) + stream->app_progress_rel`
- **组成**：
  - **`BASE`**：缓冲区的物理基准偏移。随 **Pruning（清理）** 增加。
  - **`REL`**：窗口内的相对进度。随 **消费** 增加，随 **清理** 减少。
- **设计目的**：支持无限长流的滑动窗口管理，避免在大数据流中频繁更新巨大的绝对整数，同时适应缓冲区的动态滑动。

#### `enum StreamUpdateDir`

- **`UPDATE_DIR_PACKET`**: 更新当前数据包方向的状态。
- **`UPDATE_DIR_OPPOSING`**: 更新相反方向的状态。
  - **IDS 模式默认行为**：当收到 ACK 包时，Suricata 利用这个 ACK 确认并提交**反方向**已发送的数据。这是“延迟提交”策略，确保检测的是真实到达的数据。

---

## 3. 特殊机制与边界情况分析

### `StreamTcpUpdateLastAck` 的越界检测

代码逻辑：

```c
if ((SEQ_LEQ((stream)->last_ack, (stream)->next_seq) && SEQ_GT((ack),(stream)->next_seq)))
```

- **含义**：接收方发来的 ACK 确认号，大于 Suricata 看到的发送方最大序列号（`next_seq`）。
- **推论**：**“接收方确认收到了 Suricata 还没看到的数据”**。
- **结论**：Suricata 发生了**抓包丢失 (Packet Loss)**。系统会记录此异常（`tcp.ack_unseen_data`），这是网络状况恶化或抓包性能不足的直接证据。

### 原始流检测触发 (`SCAppLayerParserTriggerRawStreamInspection`)

- **场景**：应用层解析器决定放弃解析。例如：
  - TLS 握手结束，进入加密传输模式。
  - 协议解析失败（畸形数据）。
  - 协议切换（如 HTTP -> WebSocket，且不支持新协议）。
- **机制**：设置 `STREAMTCP_STREAM_FLAG_TRIGGER_RAW` 标志。
- **注意**：它**不直接更新** `app_progress`。它只是通知通用检测引擎（Raw Inspection）接管剩余的原始数据流。进度的更新由后续 Raw Inspection 模块消费数据时完成。

### 内存清理 (`StreamTcpPruneSession`)

- **触发时机**：数据被应用层成功消费后。
- **计算边界**：`Safe Edge = MIN(AppProgress, RawProgress, LastAck)`。
- **动作**：调用 `StreamingBufferSlideToOffset`。
  - 物理删除红黑树中 `Safe Edge` 之前的节点。
  - 释放对应的内存页。
  - 增加 `STREAM_BASE_OFFSET`，减少 `app_progress_rel`。
- **目的**：防止内存泄漏，维持滑动窗口。

### 应用层不更新进度的后果

- **假设**：应用层收到 GAP 通知后，不更新 `app_progress`，试图等待迟到的数据。
- **实际后果**：
  - `ReassembleUpdateAppLayer` 会检测到进度未更新（`no_progress_update`）。
  - 函数强制退出循环。
  - 下一次包来时，再次进入循环，再次发现 GAP，再次通知应用层。
  - **结果**：流解析陷入**死循环/卡死**状态，消耗 CPU 且无法推进。
- **结论**：Suricata 强制要求应用层处理（消费）GAP，不支持“挂起等待”逻辑，以保证系统的实时性和稳定性。
