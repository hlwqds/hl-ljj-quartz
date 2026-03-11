---
title: Suricata detect prehook(ai)
date: 2025-11-26 00:11:00
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



# Suricata PreFlowHook 配置与原理说明

`PreFlowHook` 是 Suricata 内部的一个挂载点，位于流（Flow）建立或查找之前。利用该 Hook 可以在极早的阶段处理数据包，非常适合高性能的黑名单丢弃或白名单放行。

## 1. 怎样配置 Rules 和 Suricata

你不需要在 `suricata.yaml` 中开启特定的“开关”来启用 `PreFlowHook`。**只要你的规则文件中包含了指定 `pre_flow` 的规则，Suricata 引擎就会自动启用这个挂载点。**

### 第一步：编写规则 (Rules)

要让规则命中 `PreFlowHook`，你需要使用特殊的协议修饰符语法：`protocol:pre_flow`。

例如，创建一个名为 `preflow.rules` 的文件：

```suricata
# 示例 1: 在流建立前丢弃特定 IP 的 TCP 包 (性能极高，因为不消耗流内存)
drop tcp:pre_flow 1.2.3.4 any -> any any (msg:"Drop attacker early"; sid:1000001; rev:1;)

# 示例 2: 在流建立前检查特定标志位的包
alert tcp:pre_flow any any -> any any (msg:"SYN packet in pre_flow"; flags:S; sid:1000002; rev:1;)

# 示例 3: 针对所有 IP 包的预流检测
pass ip:pre_flow 192.168.1.1 any -> any any (msg:"Pass trusted host early"; sid:1000003; rev:1;)
```

**关键点：**
*   核心语法是 `tcp:pre_flow`、`udp:pre_flow` 或 `ip:pre_flow`。
*   通常用于 `drop` (丢弃) 或 `pass` (放行) 操作，因为这能最大程度利用其“在流处理之前”的性能优势。

### 第二步：配置 suricata.yaml

确保你的 `suricata.yaml` 加载了上述规则文件。

```yaml
default-rule-path: /etc/suricata/rules

rule-files:
  - suricata.rules
  - preflow.rules  <-- 添加你的规则文件
```

## 2. 什么样的包能够命中 PreFlowHook？

**所有匹配规则协议的包都会命中，但时机非常早。**

*   **时机**：在**解码 (Decode)** 之后，但在**流查找/创建 (Flow Lookup/Update)** 之前。
*   **状态**：此时 Suricata **还没有**为该数据包分配 `Flow` 对象。因此，你无法使用与流相关的关键字（如 `flow:established`、`stream_size` 等）。
*   **命中条件**：
    1.  规则中必须显式声明 `:pre_flow`。
    2.  数据包协议必须匹配（例如 `tcp:pre_flow` 只能匹配 TCP 包）。
    3.  适用于单包检测逻辑（Stateless）。

## 3. 原理图解

下图展示了数据包处理流程中 `PreFlowHook` 的确切位置：

```mermaid
graph TD
    Packet[网络数据包进入] --> Decode[Decode (解码器)]
    Decode --> PreCheck{是否存在<br>PreFlow规则?}
    
    PreCheck -- 是 --> PreFlowHook[PreFlowHook 挂载点]
    
    subgraph "PreFlowHook 逻辑"
        PreFlowHook --> Match{规则匹配?}
        Match -- 匹配(Drop) --> Drop[丢弃数据包<br>(不创建流，不消耗内存)]
        Match -- 匹配(Pass) --> FlowLookup
        Match -- 无匹配 --> FlowLookup
    end
    
    PreCheck -- 否 --> FlowLookup
    
    FlowLookup[Flow Worker<br>(流表查找/新建流)] --> Stream[TCP Stream 重组]
    Stream --> AppLayer[AppLayer Parsers<br>(HTTP, TLS, DNS...)]
    AppLayer --> Detect[Detect Engine<br>(常规规则检测)]
```

## 4. 总结

1.  **配置**：在规则协议后加上 `:pre_flow` 后缀（如 `tcp:pre_flow`）。
2.  **命中**：解码完成但尚未进入流表的数据包。
3.  **优势**：这是 Suricata 中处理性能最高的阶段之一。如果你想用 Suricata 做高性能的防火墙（黑名单/白名单），在这个阶段进行 `drop` 是最高效的，因为它完全跳过了昂贵的流重组和应用层解析开销。
---
## 外部参考
- [Suricata 源代码 (GitHub)](https://github.com/OISF/suricata)
- [Suricata 官方用户指南](https://docs.suricata.io/)
