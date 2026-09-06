---
title: "Suricata 深度探索 (三)：Runmodes 运行模式"
date: 2026-04-15
tags:
  - suricata
  - series
  - runmode
  - nfq
  - worker
  - autofp
description: "深入解析 Suricata 的运行模式：auto/worker/autofp/pcap/nfq 模式配置与源码实现，以及各模式适用场景"
---

> [!info] Suricata 2026 深度探索系列 0. [[suricata-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-overview|第一章：Suricata 概述]]
> 2. [[ch2-config|第二章：Suricata 配置系统]]
> 3. **第三章：Runmodes 运行模式**
> 4. [[ch4-thread-model|第四章：线程模型]]
> 5. [[ch5-capture|第五章：Capture 初始化]]

---

## 1. 运行模式概述

Suricata 支持多种 **Runmode**（运行模式），决定数据包如何被接收、处理、分发：

```yaml
# suricata.yaml — 模式配置
runmode: auto # 可选：auto/worker/autofp/pcap/nfq/netmap/ipfw/dpdk
```

|| 模式 | 说明 | 适用场景 |
|| :--- | :--- | :--- |
| **auto** | 自动选择最优模式 | 默认，生产环境推荐 |
| **worker** | 多线程 Worker，每个线程独立抓包 | 高性能 IDS/IPS |
| **autofp** | 自动分配 Flow 到线程 | 高并发、多核扩展 |
| **pcap** | 单线程 libpcap 抓包 | 调试、简单部署 |
| **nfq** | NFQ Inline IPS 模式 | Linux 本地 IPS |
| **netmap** | netmap 抓包 | 高速网络 |
| **dpdk** | DPDK 抓包 | 100G+ 超高性能 |
| **ipfw** | IPFW 模式 | BSD 系统 |

---

## 2. Runmode 源码结构

### 2.1 模式枚举

```c
// src/runmode.h — 运行模式枚举
typedef enum RunMode {
    RUNMODE_UNKNOWN = 0,
    RUNMODE_PCAP_DEV,        // 1 单网卡模式
    RUNMODE_WORKER,           // 2 多线程 Worker
    RUNMODE_AUTOFP,          // 3 AutoFP 模式
    RUNMODE_SINGLE,          // 4 单线程模式
    RUNMODE_NETMAP,          // 5 netmap 模式
    RUNMODE_AF_PACKET,       // 6 AF-PACKET 模式
    RUNMODE_NFQ,             // 7 NFQ 模式
    RUNMODE_IPFW,            // 8 IPFW 模式
    RUNMODE_DPDK,            // 9 DPDK 模式
    RUNMODE_UNITTEST,        // 10 单元测试
    RUNMODE_LIBRARY,         // 11 库模式
} RunMode;
```

### 2.2 模式注册表

```c
// src/runmode.c — 模式注册
typedef struct RunMode_ {
    const char *name;
    int (*RunModeFunc)(void);           // 主入口函数
    void (*RegisterTests)(void);       // 单元测试注册
    const char *description;
} RunMode;

static RunMode runmodes[] = {
    { "autofp",      RunModeAutoFp,       RegisterTestsRunModeAutoFp,      "Multi-threaded FP mode" },
    { "worker",      RunModeWorker,        RegisterTestsRunModeWorker,      "Multi-threaded worker mode" },
    { "single",     RunModeSingle,        RegisterTestsRunModeSingle,      "Single threaded mode" },
    { "nfq",         RunModeNFQ,           RegisterTestsRunModeNFQ,         "NFQ inline mode" },
    { "af-packet",   RunModeAFPacket,     RegisterTestsRunModeAFPacket,   "AF_PACKET mode" },
    { "pcap",        RunModePcap,          RegisterTestsRunModePcap,       "Pcap mode" },
    { "netmap",      RunModeNetmap,        RegisterTestsRunModeNetmap,     "netmap mode" },
    { "dpdk",        RunModeDpdk,          RegisterTestsRunModeDpdk,       "DPDK mode" },
    { NULL, NULL, NULL, NULL }
};
```

---

## 3. Auto 模式

### 3.1 自动选择逻辑

```yaml
# suricata.yaml
runmode: auto
```

```c
// src/runmode.c — 模式自动选择
const char *RunModeAutoConf(void)
{
    /* 根据网卡类型和数量自动选择 */

    /* 如果是 NFQ 模式（iptables 集成） */
    if (RunmodeIsNFQ()) {
        return "nfq";
    }

    /* 如果有多个网卡且支持 AF-PACKET */
    if (NicHasAFPacket() && NicCount() > 1) {
        return "autofp";  // 多网卡用 autofp
    }

    /* 如果是 DPDK 环境 */
    if (DPDKEnabled()) {
        return "dpdk";
    }

    /* 默认使用 worker 模式 */
    return "worker";
}
```

### 3.2 AutoFP 模式架构

```
┌─────────────────────────────────────────────────────────────┐
│                        AutoFP Mode                          │
│  ┌──────────────┐                                          │
│  │ Capture Thread│                                          │
│  │ (AF-PACKET)   │                                          │
│  └──────┬───────┘                                          │
│         │                                                   │
│         │ Flow Hash                                         │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │ Flow Manager  │ ←── 跨线程分发 Flow                       │
│  │ (AutoFP)      │                                          │
│  └──────┬───────┘                                          │
│         │                                                   │
│    ┌────┴────┬─────────────┐                                │
│    ▼         ▼             ▼                                │
│  ┌────┐   ┌────┐       ┌────┐                              │
│  │ W1 │   │ W2 │  ...  │ Wn │  (Worker 线程池)             │
│  └──┬─┘   └──┬─┘       └──┬─┘                              │
│     │        │            │                                 │
│     ▼        ▼            ▼                                 │
│  ┌─────────────────────────────────┐                        │
│  │     Detect + AppLayer + Log    │                        │
│  └─────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. Worker 模式

### 4.1 配置

```yaml
# suricata.yaml — Worker 模式
runmode: worker
af-packet:
  - interface: eth0
    threads: 4 # 每个接口 4 个线程
    use-structs: yes
    ring-size: 2048
```

### 4.2 源码实现

```c
// src/runmode-af-packet.c — Worker 模式初始化
int RunModeAFPAutoFp(DetectEngineCtx *de_ctx)
{
    /* 创建 AutoFP 模式的抓包线程拓扑 */
    return RunModeSetIPSAutoFp(..., de_ctx);
}

static int RunModeSetIPSAutoFp(..., DetectEngineCtx *de_ctx)
{
    /* 1. 创建抓包线程 */
    ThreadVars *tv_capture = TmThreadCreatePacketHandler("RxPkt#",
        "packetpool", "packetpool",
        "FlowManager",
        "flow-manager");

    /* 2. 设置抓包模块（AF-PACKET）*/
    TmVarSlotSetFunc(tv_capture, "RxAFPacket",
                     TmModuleGetByName("AF_PACKET"));

    /* 3. 设置分发队列 */
    tv_capture->outq = CommonCommitStage("flow.auto.1");

    /* 4. 启动抓包线程 */
    TmThreadSpawn(tv_capture);

    /* 5. 创建 Worker 线程池 */
    for (int i = 0; i < thread_count; i++) {
        ThreadVars *tv_worker = TmThreadCreatePacketHandler(
            "Worker#", "flow.recycler", ...);

        /* 每个 Worker 都有自己的 DetectEngine */
        TmVarSlotSetFunc(tv_worker, "RespondReject", ...);
        TmThreadSpawn(tv_worker);
    }

    return 0;
}
```

### 4.3 Worker 模式 vs AutoFP 模式

|| 特性 | Worker | AutoFP |
|| :--- | :--- | :--- |
| **包分发** | 直接到 Worker | 通过 Flow Hash 分发 |
| **CPU 亲和** | 天然支持 | 需要额外配置 |
| **延迟** | 最低（无中间层） | 略高（多一跳） |
| **吞吐** | 最高 | 高 |
| **Flow 均衡** | 取决于 RSS Hash | 自动均衡 |
| **适用场景** | IDS 单机 | IPS + 多核 |

---

## 5. NFQ 模式

### 5.1 配置

```yaml
# suricata.yaml — NFQ IPS 模式
runmode: nfq
nfq:
  mode: accept # accept=放行, drop=丢弃
  repeat-mark: 1
  repeat-delay: 10
  bypass-mark: 1
```

### 5.2 iptables 集成

```bash
# NFQ 模式需要 iptables 规则
# 示例：将对 80 端口的 HTTP 流量重定向到 Suricata

# 传统模式（每包都检查）
iptables -I INPUT -p tcp --dport 80 -j NFQUEUE --queue-num 0
iptables -I OUTPUT -p tcp --sport 80 -j NFQUEUE --queue-num 0

# 快速路径模式（已匹配 Flow 跳过 NFQ）
iptables -I INPUT -p tcp --dport 80 -m mark --mark 1 -j ACCEPT
iptables -I OUTPUT -p tcp --sport 80 -m mark --mark 1 -j ACCEPT
iptables -I INPUT -p tcp --dport 80 -j NFQUEUE --queue-num 0
iptables -I OUTPUT -p tcp --sport 80 -j NFQUEUE --queue-num 0

# NFQ 绕过（TTL 匹配）
iptables -I INPUT -p tcp --dport 80 -m ttl --ttl-eq 64 -j ACCEPT
```

### 5.3 NFQ 源码实现

```c
// src/source-nfq.c — NFQ 接收模块
static TmEcode ReceiveNFQ(ThreadVars *tv, Packet *p)
{
    /* 从 NFQ 队列读取数据包 */
    int fd = NFQGetFD();

    ssize_t len = recv(fd, &buf, sizeof(buf), 0);
    if (len > 0) {
        /* 解析 NFQ 元数据（mark, ifindex, verdict）*/
        NFQParsePacket(tv, p, &buf);

        /* 发送给后续处理模块 */
        if (TmModules[TMM_RECEIVENFQ].func(tv, p) == TM_ECODE_OK) {
            /* 调用 verdict 模块 */
            NFQSetVerdict(tv, p, NF_ACCEPT);
        }
    }
    return TM_ECODE_OK;
}

// src/source-nfq.c — NFQ Verdict 模块
static TmEcode VerdictNFQ(ThreadVars *tv, Packet *p)
{
    /* 决定数据包命运：放行或丢弃 */
    if (p->nfq_vf_iif != 0) {
        /* 这是 Inline IPS 模式的包 */
        if (p->action & ACTION_DROP) {
            /* 丢弃包 */
            NFQSendVerdict(p->nfq_vf_iif, NF_DROP, p);
        } else {
            /* 放行包 */
            NFQSendVerdict(p->nfq_vf_iif, NF_ACCEPT, p);
        }
    }
    return TM_ECODE_OK;
}
```

---

## 6. PCAP 模式

### 6.1 配置

```yaml
# suricata.yaml — PCAP 模式
runmode: pcap
pcap:
  - interface: eth0
    buffer-size: 1024
    snaplen: 1514
    promisc: true
```

### 6.2 PCAP 源码

```c
// src/source-pcap.c — PCAP 抓包
static TmEcode ReceivePcap(ThreadVars *tv, Packet *p)
{
    pcap_t *pd = pcap_open_live(iface, snaplen, promisc, 100);

    while (1) {
        /* 阻塞读取 */
        struct pcap_pkthdr *h;
        const u_char *data;
        int rc = pcap_next_ex(pd, &h, &data);

        if (rc == 1) {
            /* 解析为 Packet 结构 */
            PacketCopyData(p, data, h->len);
            p->ts = h->ts;

            /* 分发到处理链 */
            TmSlotFunc(p);
        }
    }
}
```

---

## 7. 模式选择指南

```mermaid
graph TD
    A["需要检测还是阻断?"] --> B{"阻断"}
    B -->|Yes| C["NFQ / AF-PACKET Inline"]
    B -->|No| D["需要高性能?"]
    D -->|Yes| E{"多网卡?"]
    E -->|Yes| F["AutoFP"]
    E -->|No| G["Worker"]
    D -->|No| H["PCAP (调试)"]

    C -->|Linux| I["NFQ"]
    C -->|DPDK网卡| J["AF-PACKET / DPDK"]

    style F fill:#f9f,color:#000
    style G fill:#f9f,color:#000
    style I fill:#9f9,color:#000
    style J fill:#9f9,color:#000
```

---

## 8. 小结

本章解析了 Suricata 的运行模式：

1. **Auto 模式**：自动选择 worker 或 autofp
2. **Worker 模式**：每线程独立抓包 + 检测，最低延迟
3. **AutoFP 模式**：通过 Flow Hash 分发，天然负载均衡
4. **NFQ 模式**：Linux Inline IPS，iptables 集成
5. **PCAP 模式**：libpcap 单线程，调试友好

下一章我们将深入 **线程模型**，解析 `TmThread`、`TmModule` 如何构成 Suricata 的执行流水线。
