---
title: Suricata detect app protocol(ai)
date: 2025-12-02 00:11:00
pin: true
tags: [suricata]
---

> [!abstract] Suricata 引擎研究系列文章
> - [[2025-11-27-suricata-flow-state|Flow 状态机分析]]
> - [[2025-11-27-suricata-proto-detect-done|协议检测标记位]]
> - [[2025-11-27-suricata-ip-reputation|IP 信誉机制]]
> - [[2025-11-27-suricata-prehook-detect|PreFlowHook 挂载点]]
> - [[2025-11-27-suricata-midstream-flow-reverse|Midstream 方向更正]]
> - [[2025-11-27-suricata-disable-detect-fileflags|文件处理禁用逻辑]]
> - [[2025-11-27-suricata-FLOW_TS_APP_UPDATE_NEXT|App 更新标志]]
> - [[2025-12-02-suricata-flow-storage|Flow 存储 API]]
> - [[2025-12-02-suricata-flowworker-to-applayerparserparse|调用链全景图]]
> - [[2025-12-03-suricata-get-app-protocol|端口协议检测]]
> - [[2026-02-09-suricata-advanced-acl-auditing|高级 ACL 审计]]



# Suricata 中基于端口的协议检测：修正后的详细流程

根据我们对 Suricata 源代码的分析，特别是澄清了基于端口的检测在模式匹配（PM）和探测解析器（PP）中的具体作用后，以下是 Suricata 中基于端口的协议检测从注册到使用的详细流程：

---

### Suricata 中基于端口的协议检测：修正后的详细流程

1.  **配置阶段 (Configuration)**
    *   **用户操作**：用户在 Suricata 的配置文件 `suricata.yaml` 中，通过 `app-layer.protocols.<protocol_name>.detection-ports` 项，指定哪些应用层协议预计在哪些端口上被检测。
    *   **目的**：为 Suricata 提供端口与预期协议之间的显式映射关系。

2.  **初始化/注册阶段 (Initialization/Registration - Suricata 启动时)**
    *   **配置解析**：Suricata 启动时，`SCAppLayerProtoDetectPPParseConfPorts` 函数负责解析 `suricata.yaml` 中的端口配置。
    *   **探测解析器注册**：解析完成后，`SCAppLayerProtoDetectPPRegister` 函数会被调用。它接收解析出的 IP 协议（如 TCP）、具体的端口（或端口范围）以及对应的应用层协议 (`AppProto alproto`)，并将其与**相应的探测解析器函数**关联。
    *   **内部数据结构构建**：`SCAppLayerProtoDetectPPRegister` 通过调用 `AppLayerProtoDetectInsertNewProbingParser`，将这些关联信息（IP 协议、端口、应用协议、探测解析器函数）插入到 Suricata 内部的一个高效查找表 (`alpd_ctx.ctx_pp`) 中。这个查找表的作用是：**给定一个 IP 协议和端口，能够快速找到为该组合注册的所有探测解析器**。
    *   **目的**：在 Suricata 启动时，建立一个优化过的查找机制，用于在后续处理中，根据流的端口快速定位到可能适用的**探测解析器集合**。

3.  **流创建阶段 (Flow Creation - 数据包处理时)**
    *   **事件**：当 Suricata 接收到一个网络数据包，并识别出一个新的网络流（例如，一个新的 TCP 连接开始）时。
    *   **信息提取**：Suricata 从数据包头部提取关键信息，包括源/目的 IP 地址、源/目的端口号和传输层协议（TCP/UDP），并创建或更新 `Flow` 对象。
    *   **目的**：建立一个网络流的上下文 (`Flow` 对象)，其中包含了进行协议检测所需的基本信息，包括端口。

4.  **应用层协议检测阶段 (`AppLayerProtoDetectGetProto` - 顶层协调者)**
    *   `AppLayerProtoDetectGetProto` 是顶层的协议检测函数，它协调多个检测尝试，直到识别出协议或所有方法都失败。

    *   **第一尝试：模式匹配 (Pattern Matching - PM)**
        *   **函数调用**：`AppLayerProtoDetectPMGetProto` 会被调用。
        *   **内部机制**：这个函数主要依赖于**多模式匹配器 (MPM)**。它会利用流的 IP 协议（通过 `f->protomap`）和方向来选择一组预编译的模式进行匹配。例如，TCP 流量只会用 TCP 相关的模式去匹配。
        *   **端口作用**：**端口信息在 `AppLayerProtoDetectPMGetProto` 内部不会直接用于过滤或加速模式匹配。**它的加速来自于模式集的预专门化（按 IP 协议和方向）。
        *   **目的**：快速识别具有明显特征的协议。如果匹配成功，则立即确定协议并返回。

    *   **第二尝试：探测解析器 (Probing Parsers - PP)**
        *   **条件**：如果模式匹配（PM）未能成功识别协议。
        *   **函数调用**：`AppLayerProtoDetectPPGetProto` 会被调用。
        *   **端口作用 (核心)**：**这里就是基于端口的检测发挥关键作用的地方。**
            *   `AppLayerProtoDetectPPGetProto` 会获取当前流的目的端口 (`dp`) 和源端口 (`sp`)。
            *   它会查询在 Suricata 启动时构建的内部查找表 (`alpd_ctx.ctx_pp`)，**根据 `ipproto` 和 `dp/sp` 查找并检索所有已注册的探测解析器。**
            *   **高效筛选**：通过这种方式，`AppLayerProtoDetectPPGetProto` 避免了对所有可能的探测解析器进行盲目尝试，而是只执行那些通过端口信息被认为是**相关且有可能成功**的探测解析器。这极大地提高了效率。
        *   **目的**：如果模式匹配失败，则使用更深入、但通过端口信息预筛选过的探测解析器，尝试解析数据以确定协议。如果匹配成功，则立即确定协议并返回。

    *   **第三尝试：预期列表 (Expectation List - PE)**
        *   **条件**：如果模式匹配（PM）和探测解析器（PP）都未能成功识别协议。
        *   **函数调用**：`AppLayerProtoDetectPEGetProto` 会被咨询。
        *   **目的**：利用流中积累的上下文信息或此前检测到的协议所产生的预期来尝试确定协议。

---

**总结**：

基于端口的检测在 Suricata 的协议识别中扮演了一个**至关重要的“智能筛选器”角色**。它主要通过**预配置和在探测解析器（PP）阶段进行目标性查找**来提高效率，而不是直接加速模式匹配（PM）。这种分层且智能的策略确保了 Suricata 能够高效而准确地识别网络流量中的应用层协议。

---

# Suricata AppLayer 协议识别完整流程

本文档基于 Suricata 7.x/8.x 核心源码，详细解析应用层协议识别（AppLayer Detection）的全过程。

## 1. 总体架构图

```ascii
数据包 (Payload)
      |
      v
+-----------------------------+
| AppLayerProtoDetectGetProto |  <-- 核心入口
+-------------+---------------+
              |
              v
+-----------------------------+
|  阶段 1: Pattern Matcher    |  (src/app-layer-detect-proto.c)
|  (AC 自动机多模匹配)        |
+-------------+---------------+
              |
              +---> [命中特征] ---> 生成候选列表 (Candidate List)
              |
              v
+-----------------------------+
|  阶段 2: 深度探测 (Probing) |  (src/app-layer-detect-proto.c)
|  (遍历候选列表 + 无特征协议)|
+-------------+---------------+
              |
              +---> 调用 Rust/C probe 函数 (如 qhsm_probing_parser)
              |
              v
      [ ALPROTO_XXX ]  (识别成功)
              OR
      [ ALPROTO_UNKNOWN ] (识别失败) -> 等下一个包
```

---

## 2. 详细流程与代码路径

### 阶段 0: 流量入口
当 TCP 流重组出新的 Payload 数据块时，Flow Worker 线程会触发协议检测。

*   **入口函数**: `AppLayerProtoDetectGetProto`
*   **文件位置**: `src/app-layer-detect-proto.c`

### 阶段 1: 模式匹配与即时锁定 (Pattern Matcher Phase)
Suricata 首先运行 AC 自动机扫描 Payload。如果命中特征，逻辑会尝试 **即时锁定**。

1.  **执行 PM**: 调用 `AppLayerProtoDetectPMGetProto`。
2.  **验证签名**: 内部调用 `AppLayerProtoDetectPMMatchSignature`。
    *   如果注册时绑定了探测函数 (`s->PPFunc != NULL`)，则在此处 **立刻执行** 该函数（如 `qhsm_probing_parser`）进行深度校验。
    *   如果校验通过，返回协议 ID。
3.  **直接返回**: 在 `AppLayerProtoDetectGetProto` 中，如果 `pm_matches > 0`，Suricata 会 **直接返回结果并锁定流**，完全跳过后续的 Probing Loop。

### 阶段 2: 端口探测循环 (Probing Loop Phase)
只有当 **阶段 1 没有任何命中** 时，才会进入此阶段。这是一个基于“端口映射”的搜索。

1.  **查找端口**: 调用 `AppLayerProtoDetectPPGetProto`。
    *   该函数会根据流的 `dp` (目标端口) 或 `sp` (源端口) 去查找已注册的探测器。
2.  **执行遍历**: 在 `PPGetProto` 函数内，通过一个 `while(pe != NULL)` 循环遍历该端口下的所有协议探测器。
3.  **锁定**: 只要有一个探测器返回成功，即锁定协议并返回。

---

## 3. 关键总结：架构逻辑的真相

根据 `src/app-layer-detect-proto.c` 的源码，目前的架构设计如下：

| 特性 | **Pattern Matcher (PM)** | **Probing Parser (PP)** |
| :--- | :--- | :--- |
| **触发时机** | 数据包到达的首选方案 | 仅在 PM 无命中的情况下触发 |
| **匹配依据** | 预定义的字节特征 (指纹) | 端口号 (Port Map) |
| **验证逻辑** | 如果注册了 `PPFunc`，则在 PM 时同步执行校验 | 遍历该端口下挂载的所有探测器函数 |
| **性能优势** | 快速排除法，命中即锁定 | 精准缩小范围 (只扫特定端口的嫌疑协议) |

---

## 4. 针对 QHSM 的架构建议 (基于最新源码分析)

基于“命中即返回”的特性，QHSM 存在两种配置策略：

### 方案 A：纯 Probing 模式 (当前现状)
*   **不注册 Pattern**。
*   **流程**：PM 阶段跳过 -> 进入 Probing 阶段 -> 检查端口是否为 6666 -> 是 -> 执行 `qhsm_probing_parser`。
*   **优点**：最安全，逻辑最清晰。

### 方案 B：PM + Probing 联合模式 (优化建议)
*   **注册 Pattern** (`|00 00|` at offset 2) 并 **必须绑定** `qhsm_probing_parser`。
*   **流程**：PM 阶段扫描到 `00 00` -> 在 PM 内部立即调用 `qhsm_probing_parser` 校验 -> 校验成功 -> 直接返回并锁定。
*   **优点**：如果 QHSM 跑在非 6666 端口，这种方式可以比纯 Probing 模式更早、更高效地识别出协议。
*   **注意**：这种模式下，如果包里没有 `00 00`，QHSM 将永远不会被探测（即使端口是 6666）。

---

## 5. 架构权衡：为什么 QHSM 可能不适合注册 Pattern

在 Suricata 架构下，注册 Pattern (宽口) 是一把双刃剑。针对 QHSM 协议，建议 **不要注册 Pattern**，原因如下：

### 1. "饿死" 风险 (Starvation)
Suricata 的探测逻辑是：如果一个协议注册了 Pattern 但在数据包中未匹配，该流将 **永久失去** 被该协议探测的机会。如果 QHSM 存在任何不包含 `00 00` 的变体包头，或者未来协议升级，注册 Pattern 会导致严重的漏检。

### 2. "泛滥" 风险 (Generic Pattern)
`00 00` 特征过于宽泛。在全量流量中，大量的非 QHSM 数据包（如加密流、二进制文件传输）在 offset 2 位置都可能随机出现 `00 00`。
*   这会导致 QHSM 的 `probe` 函数频繁被无效触发。
*   相比之下，不注册 Pattern，流量只有在过滤掉 HTTP/TLS/SSH 等强特征协议后才会进入 QHSM 探测，反而可能更清净。

### 3. 兼容性风险 (Forward Compatibility)
如果您计划未来支持 **Midstream (流中识别)**，Pattern Matcher 通常只能匹配固定位置的特征（如 offset 2）。这会限制解析器在流的任意位置寻找合法同步头的能力。

### 结论与建议
对于 QHSM 这种二进制私有协议：
*   **最佳实践**：保持不注册 Pattern，利用 Suricata 的兜底探测机制。
*   **优化手段**：将核心识别逻辑写在 `qhsm_probing_parser` 内部，通过校验 Length 字段的合法性、OpCode 范围以及 CRC（如果有）来实现高精度识别。
---
## 外部参考
- [Suricata 源代码 (GitHub)](https://github.com/OISF/suricata)
- [Suricata 官方用户指南](https://docs.suricata.io/)
