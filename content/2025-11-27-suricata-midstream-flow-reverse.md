---
title: Suricata midstream direction(ai)
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



# Suricata Midstream Flow Direction Correction Analysis

在 Suricata 中，针对 midstream（流的中途截获）流量方向判断错误的更正，**并没有物理修改 Flow 结构体中的 `sp` 和 `dp` 字段**。相反，它是通过设置一个标志位来进行**逻辑上的更正**。

## 结论

*   **物理存储**：`Flow` 结构体中的 `sp` (Source Port) 和 `dp` (Destination Port) 始终保持流初始化时的值，不会被交换。
*   **逻辑更正**：通过设置 `FLOW_DIR_REVERSED` 标志位来标记流的方向需要被视为反转。

## 详细实现机制

### 1. 核心更正位置：`FlowSwap`

当 Suricata 发现流的方向判断错误时，会调用 `FlowSwap` 函数。

*   **文件路径**: `suricata/src/flow.c`
*   **行为**: 它不交换 `sp` 和 `dp`，而是设置 `FLOW_DIR_REVERSED` 标志，并交换流内部的统计计数器和协议掩码。

```c
// suricata/src/flow.c

void FlowSwap(Flow *f)
{
    // 这里设置了标志位，表示流的方向被反转了
    f->flags |= FLOW_DIR_REVERSED;

    // 交换协议检测掩码
    SWAP_VARS(uint32_t, f->probing_parser_toserver_alproto_masks,
                   f->probing_parser_toclient_alproto_masks);

    // 交换各种标志和计数器，但注意这里没有交换 sp 和 dp
    FlowSwapFlags(f);
    FlowSwapFileFlags(f);
    // ...
}
```

### 2. 触发更正的位置：应用层检测

通常是在应用层协议检测阶段发现方向错误的。主要位于 `TCPProtoDetect`（TCP）或 `AppLayerHandleUdp`（UDP）。

*   **文件路径**: `suricata/src/app-layer.c`
*   **行为**: 当检测到协议特征与当前方向不符，且符合 midstream 条件时，触发翻转。

```c
// suricata/src/app-layer.c

int TCPProtoDetect(ThreadVars *tv, DecodeThreadVars *dtv, Flow *f, TcpSession *ssn, Packet *p)
{
    // ...
    if (reverse_flow &&
            ((ssn->flags & (STREAMTCP_FLAG_MIDSTREAM | STREAMTCP_FLAG_MIDSTREAM_SYNACK)) ==
                    STREAMTCP_FLAG_MIDSTREAM)) {
        
        // 只有当另一方向还未检测出协议时才翻转
        if (*alproto_otherdir == ALPROTO_UNKNOWN) {
            SCLogDebug("reversing flow after proto detect told us so");
            
            // 交换 Packet 的方向标志
            PacketSwap(p);
            
            // 核心：调用 FlowSwap 标记流方向反转
            FlowSwap(f);
            
            // ...
        }
    }
    // ...
}
```

### 3. 更正后的影响 (Usage)

由于 `sp` 和 `dp` 在内存中没变，Suricata 在需要使用端口或 IP 时会检查 `FLOW_DIR_REVERSED` 标志。

#### A. 判断包方向 (`FlowGetPacketDirection`)

*   **文件路径**: `suricata/src/flow.c`
*   **逻辑**: 会检查标志位，如果置位，则返回相反的方向（`TOSERVER` 变 `TOCLIENT`）。

#### B. 输出日志 (`CreateEveHeaderFromFlow`)

*   **文件路径**: `suricata/src/output-json-flow.c`
*   **逻辑**: 在生成 EVE JSON 日志时，会根据标志位决定是否交换显示的 IP 和端口。

```c
// suricata/src/output-json-flow.c

static SCJsonBuilder *CreateEveHeaderFromFlow(const Flow *f)
{
    // ...
    if ((f->flags & FLOW_DIR_REVERSED) == 0) {
        // 正常情况，直接使用 f->sp, f->dp
        sp = f->sp;
        dp = f->dp;
    } else {
        // 反转情况，输出时交换显示
        // src_ip 显示为 dst, dst_ip 显示为 src
        // sp 显示为 f->dp, dp 显示为 f->sp
        sp = f->dp;
        dp = f->sp;
    }
    // ...
}
```
---
## 外部参考
- [Suricata 源代码 (GitHub)](https://github.com/OISF/suricata)
- [Suricata 官方用户指南](https://docs.suricata.io/)
