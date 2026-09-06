---
title: "Kernel Protocol Stack 深度探索 (三十九)：Linux QoS 与流量控制"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    qos,
    tc,
    qdisc,
    htb,
    hfsc,
    fq-codel,
    cake,
    tbf,
    traffic-shaping,
    bandwidth,
  ]
description: "深入解析 Linux QoS 框架——tc（Traffic Control）架构、qdisc 队列规则、class 与 filter 体系、HTB/HFSC 带宽整形、FQ-CoDel/CAKE 缓冲膨胀控制、以及 Kubernetes/容器网络的 QoS 实现"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[kernel-protocol-stack-deep-dive|全栈学习路径总览]] 33. [[ch33-netfilter-hook|第三十三章：Netfilter 框架详解]] 34. [[ch34-iptables-ext|第三十四章：iptables 扩展模块]] 35. [[ch36-nftables|第三十五章：nftables]] 36. [[ch37-conntrack-internals|第三十六章：Conntrack 内部机制]] 37. [[ch38-nat-deep|第三十七章：NAT 深度解析]] 38. [[ch39-xdp-integration|第三十八章：XDP 与高性能网络处理]] 39. **第三十九章：Linux QoS 与流量控制**

---

## 1. QoS 概述

QoS（Quality of Service，服务质量）是网络中保证不同流量的带宽、延迟和丢包率的机制。Linux 的 QoS 框架称为 **tc（Traffic Control）**，是内核中最复杂的子系统之一。

tc 的核心功能：

1. **流量整形（Shaping）**：限制出向流量速率（避免突发导致队列堆积）
2. **流量调度（Scheduling）**：决定多个流的发送顺序（优先级/公平性）
3. **流量管控（Policing）**：对超速流量直接丢弃（入向）
4. **流量分类（Classification）**：将包分配到不同类别，施加不同策略

```
数据包发送路径中的 tc：

ip_output()
    │
    ▼
dev_queue_xmit()
    │
    ▼
qdisc_run()  ← tc qdisc 在这里工作
    │
    ├── qdisc.enqueue()  （入队：分类、整形）
    ├── qdisc.dequeue()  （出队：调度决策）
    │
    ▼
网卡驱动 TX 队列
    │
    ▼
网线
```

---

## 2. tc 三层体系

tc 由三个核心概念构成：

### 2.1 qdisc（队列规则）

qdisc 是 tc 的基本单元，控制包的入队和出队行为：

```
无类 qdisc（classless）：
  pfifo_fast  - 默认 qdisc，3 个优先级带，先入先出
  tbf         - 令牌桶过滤器（速率限制）
  netem       - 网络仿真（模拟延迟/丢包/抖动）
  fq_codel    - 公平队列 + CoDel（控制缓冲膨胀）
  cake        - FQ-CoDel 的改进版（推荐）
  fq          - 公平队列（高性能，最小延迟）

有类 qdisc（classful，支持子类）：
  htb         - 层次令牌桶（最常用的带宽整形）
  hfsc        - 层次公平服务曲线
  cbq         - 基于类的队列（较老，已被 htb 取代）
  drr         - 亏空轮转
  qfq         - 快速公平队列
```

### 2.2 class（类别）

有类 qdisc 可以包含多个 class，每个 class 可以有独立的带宽/优先级参数，甚至嵌套另一个 qdisc：

```
htb 树形结构示例：

root qdisc (htb 1:0)
  ├── class 1:1  (总带宽 100Mbit)
  │     ├── class 1:10  (保障 30Mbit，优先级高 - VoIP)
  │     ├── class 1:20  (保障 50Mbit - HTTP/HTTPS)
  │     └── class 1:30  (保障 10Mbit，可借用 - 其他流量)
  │           └── 子 qdisc (fq_codel)
```

### 2.3 filter（过滤器/分类器）

filter 将数据包分配到对应的 class：

```
常见分类器：
  u32    - 基于包内任意字段匹配（最灵活）
  flower - 基于 L2/L3/L4 字段（支持硬件卸载）
  bpf    - eBPF 程序分类（最可编程）
  fw     - 基于 fwmark（iptables MARK）
  matchall - 匹配所有包
  basic  - 基于 ematch 表达式
```

---

## 3. 根 qdisc 操作

```bash
# 查看接口的 qdisc
tc qdisc show dev eth0
# 输出示例：
# qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64

# 替换默认 qdisc 为 fq_codel（推荐家庭/服务器网络）
tc qdisc replace dev eth0 root fq_codel

# 替换为 cake（家庭路由最佳实践）
tc qdisc replace dev eth0 root cake bandwidth 100Mbit besteffort

# 删除 root qdisc（恢复默认）
tc qdisc del dev eth0 root
```

---

## 4. TBF（令牌桶过滤器）

TBF 是最基本的速率限制 qdisc，基于令牌桶算法：

```bash
# 限制 eth0 出向速率为 1Mbit/s，突发 10KB
tc qdisc add dev eth0 root tbf \
    rate 1mbit \
    burst 10kb \
    latency 50ms

# 参数说明：
# rate:    平均速率
# burst:   令牌桶容量（允许的突发量）
# latency: 包在队列中的最大等待时间（超过则丢弃）
```

### 4.1 TBF 内核实现

```c
// net/sched/sch_tbf.c
struct tbf_sched_data {
    u32         limit;      // 队列最大包数
    u64         rate;       // 速率（bytes/ns）
    u64         buffer;     // 令牌桶大小（bytes）
    s64         tokens;     // 当前令牌数（可为负）
    s64         ptokens;    // peak 速率令牌
    s64         t_c;        // 上次令牌更新时间
    // ...
};

static int tbf_enqueue(struct sk_buff *skb, struct Qdisc *sch, ...)
{
    struct tbf_sched_data *q = qdisc_priv(sch);

    if (qdisc_pkt_len(skb) > q->max_size) {
        return qdisc_drop(skb, sch, to_free);  // 包太大直接丢
    }

    return qdisc_enqueue_tail(skb, sch, &q->qdisc, to_free);
}

static struct sk_buff *tbf_dequeue(struct Qdisc *sch)
{
    struct tbf_sched_data *q = qdisc_priv(sch);
    struct sk_buff *skb = qdisc_peek_head(sch);
    s64 now = ktime_get_ns();
    s64 toks;

    // 计算自上次以来积累的令牌
    toks = min_t(s64, now - q->t_c, q->buffer) + q->tokens;
    toks -= (s64)L2T(q, qdisc_pkt_len(skb));

    if (toks >= 0) {
        // 有足够令牌，发送
        q->tokens = toks;
        q->t_c = now;
        return qdisc_dequeue_head(sch);
    }

    // 令牌不足，等待
    qdisc_watchdog_schedule_ns(&q->watchdog,
                                now + max_t(s64, -toks, q->timer_slack));
    return NULL;
}
```

---

## 5. HTB（层次令牌桶）

HTB 是最广泛使用的带宽整形方案，支持层次化的带宽分配和借用：

### 5.1 HTB 配置示例

```bash
# 场景：1Gbit 出口，按业务分配带宽
# VoIP: 保障 50Mbit，可借用到 200Mbit，优先级最高
# Web:  保障 400Mbit，可借用到 800Mbit
# 其他: 保障 100Mbit，剩余可借用

# 1. 创建 HTB root qdisc
tc qdisc add dev eth0 root handle 1: htb default 30

# 2. 创建根类（总带宽 1Gbit）
tc class add dev eth0 parent 1: classid 1:1 htb rate 1gbit ceil 1gbit

# 3. 创建子类
tc class add dev eth0 parent 1:1 classid 1:10 htb \
    rate 50mbit ceil 200mbit prio 1    # VoIP（高优先级）

tc class add dev eth0 parent 1:1 classid 1:20 htb \
    rate 400mbit ceil 800mbit prio 2   # Web

tc class add dev eth0 parent 1:1 classid 1:30 htb \
    rate 100mbit ceil 1gbit prio 3     # 其他（默认）

# 4. 每个类下添加 fq_codel（控制缓冲膨胀）
tc qdisc add dev eth0 parent 1:10 handle 10: fq_codel
tc qdisc add dev eth0 parent 1:20 handle 20: fq_codel
tc qdisc add dev eth0 parent 1:30 handle 30: fq_codel

# 5. 添加分类器（将 VoIP 端口流量分到 1:10）
tc filter add dev eth0 parent 1: protocol ip u32 \
    match ip dport 5060 0xffff flowid 1:10    # SIP
tc filter add dev eth0 parent 1: protocol ip u32 \
    match ip dport 16384 0xfffe flowid 1:10   # RTP

# Web 流量
tc filter add dev eth0 parent 1: protocol ip u32 \
    match ip dport 80 0xffff flowid 1:20
tc filter add dev eth0 parent 1: protocol ip u32 \
    match ip dport 443 0xffff flowid 1:20

# 其余流量走 default class 1:30（htb default 30）
```

### 5.2 HTB 借用机制

```
HTB 调度原理：

1. 当 class 发送速率 < rate：可以立即发送（GREEN 状态）
2. 当 rate <= 发送速率 <= ceil：可以向父类借用令牌（YELLOW 状态）
3. 当 发送速率 > ceil：必须等待（RED 状态）

借用规则：
- 子类可以向父类借用未使用的令牌
- 父类的 ceil 是所有子类可借用的上限
- 同优先级下，GREEN > YELLOW（本轮流中）
```

---

## 6. FQ-CoDel 与 CAKE

传统队列（pfifo/HTB）存在**缓冲膨胀（Bufferbloat）**问题：队列过深导致延迟剧增。

### 6.1 CoDel（Controlled Delay）

CoDel 的目标：保持队列延迟在 5ms 以内。

```
CoDel 算法：
- 监控包在队列中的等待时间（sojourn time）
- 如果延迟持续超过 target（5ms），开始丢包
- 丢包间隔从 interval（100ms）开始，逐渐缩短
- 通过丢包信号让发送方降速（TCP 拥塞控制响应）
```

### 6.2 FQ-CoDel（公平队列 + CoDel）

```bash
# FQ-CoDel：按流哈希分桶，每个流独立 CoDel 队列
tc qdisc replace dev eth0 root fq_codel \
    limit 10240 \        # 总队列限制（包数）
    flows 1024 \         # 哈希桶数（流数）
    quantum 1514 \       # 每轮出队的字节数
    target 5ms \         # 目标延迟
    interval 100ms \     # CoDel 控制间隔
    ecn                  # 启用 ECN（而非丢包）

# 查看统计
tc -s qdisc show dev eth0
# 输出包含：packets/bytes/drops/overlimits/requeues/backlog 等
```

### 6.3 CAKE（最推荐的家庭/边缘网络 qdisc）

```bash
# CAKE = 综合了 FQ-CoDel + 流量整形 + AQM + DSCP
tc qdisc add dev eth0 root cake \
    bandwidth 95mbit \   # 出口带宽（设为 ISP 速率的 95%）
    overhead 22 \        # PPPoE 头部开销
    besteffort \         # 单一优先级（或 diffserv4/diffserv8）
    nat \                # CAKE 感知 NAT（按原始 IP 做公平队列）
    wash                 # 清洗 DSCP 标记（防止 ISP 差异化）

# 查看 CAKE 详细统计
tc -s qdisc show dev eth0
```

---

## 7. eBPF 分类器（cls_bpf）

eBPF 程序可以作为 tc filter，实现完全可编程的包分类和处理：

```c
// tc eBPF 程序（直接操作 skb）
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>

SEC("classifier")
int tc_cls(struct __sk_buff *skb)
{
    // 读取 IP 目的地址
    __u32 dst_ip;
    bpf_skb_load_bytes(skb, ETH_HLEN + offsetof(struct iphdr, daddr),
                        &dst_ip, 4);

    // 设置流量类别（用于 HTB 分类）
    if (dst_ip == bpf_htonl(0xC0A80101))  // 192.168.1.1
        skb->tc_classid = TC_H_MAKE(1, 10);  // 1:10

    return TC_ACT_OK;  // 放行
}

// 返回值：
// TC_ACT_OK      (0) - 继续处理
// TC_ACT_SHOT    (2) - 丢弃
// TC_ACT_REDIRECT(7) - 重定向到另一接口
```

```bash
# 加载 tc eBPF 分类器
tc qdisc add dev eth0 clsact
tc filter add dev eth0 ingress bpf direct-action obj tc_prog.o sec classifier
tc filter add dev eth0 egress  bpf direct-action obj tc_prog.o sec classifier
```

---

## 8. ingress qdisc 与 policing

tc 默认只控制出向（egress）流量，ingress policing 用于限制入向速率（直接丢包，不缓冲）：

```bash
# 在 eth0 的 ingress 上限速 500Mbit（超速直接丢弃）
tc qdisc add dev eth0 handle ffff: ingress

tc filter add dev eth0 parent ffff: protocol ip u32 \
    match ip src 0.0.0.0/0 \
    police rate 500mbit burst 1mb drop flowid :1

# 或使用 IFB（Intermediate Functional Block）将 ingress 转为 egress 整形
modprobe ifb
ip link set ifb0 up
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: protocol all u32 \
    match u32 0 0 action mirred egress redirect dev ifb0

# 现在在 ifb0 上做 egress 整形（效果等同于 ingress 整形）
tc qdisc add dev ifb0 root handle 1: htb default 10
tc class add dev ifb0 parent 1: classid 1:10 htb rate 500mbit
```

---

## 9. DSCP 与服务差异化

DSCP（Differentiated Services Code Point，IP 头 ToS 字段高 6 位）是网络设备间传递 QoS 意图的标准方式：

```bash
# iptables 设置 DSCP（Expedited Forwarding：低延迟，用于语音）
iptables -t mangle -A OUTPUT -p udp --dport 5060 \
    -j DSCP --set-dscp-class EF

# iptables 设置 DSCP（Assured Forwarding AF41：视频会议）
iptables -t mangle -A OUTPUT -p tcp --dport 8443 \
    -j DSCP --set-dscp-class AF41

# tc 基于 DSCP 分类
tc filter add dev eth0 parent 1: protocol ip \
    handle 0xb8/0xfc fw flowid 1:10  # EF (0xB8) → VoIP class
```

### 9.1 常见 DSCP 值

| DSCP 类别 | 数值 | 用途                                |
| --------- | ---- | ----------------------------------- |
| CS0 / BE  | 0    | 默认（Best Effort）                 |
| AF11      | 10   | 低优先级数据                        |
| AF21      | 18   | 普通数据                            |
| AF31      | 26   | 流媒体                              |
| AF41      | 34   | 视频会议                            |
| CS5       | 40   | 语音信令                            |
| EF        | 46   | 语音/低延迟（Expedited Forwarding） |
| CS6       | 48   | 网络控制（BGP/OSPF）                |
| CS7       | 56   | 最高优先级（网络管理）              |

---

## 10. Kubernetes/容器 QoS

### 10.1 Kubernetes QoS 类别

```yaml
# Guaranteed（最高 QoS）：requests == limits
resources:
  requests:
    memory: "1Gi"
    cpu: "500m"
  limits:
    memory: "1Gi"
    cpu: "500m"

# Burstable：requests < limits
resources:
  requests:
    memory: "512Mi"
    cpu: "200m"
  limits:
    memory: "1Gi"
    cpu: "500m"

# BestEffort（最低 QoS）：不设 requests/limits
```

Kubernetes QoS 类别影响 OOM Kill 顺序（BestEffort 最先被杀），但**不直接控制网络带宽**。

### 10.2 CNI 网络 QoS（bandwidth plugin）

```json
// /etc/cni/net.d/10-mynet.conflist
{
  "plugins": [
    {
      "type": "bridge",
      "name": "mynet"
    },
    {
      "type": "bandwidth",
      "ingressRate": 104857600, // 100Mbit 入向限速
      "ingressBurst": 20971520, // 20MB 突发
      "egressRate": 52428800, // 50Mbit 出向限速
      "egressBurst": 10485760 // 10MB 突发
    }
  ]
}
```

CNI bandwidth plugin 使用 tbf qdisc + IFB 实现双向限速：

```bash
# 内部实现（对容器 veth 接口）
tc qdisc add dev veth_pod egress root tbf rate 50mbit burst 10mb latency 25ms
tc qdisc add dev ifb0     root   tbf rate 100mbit burst 20mb latency 25ms
tc qdisc add dev veth_pod ingress handle ffff: mirred redirect dev ifb0
```

---

## 11. tc 统计与调试

```bash
# 查看 qdisc 统计
tc -s qdisc show dev eth0
# 字段说明：
# Sent X bytes Y pkt    - 发送统计
# dropped Z             - 丢包数（超队列 / policing）
# overlimits W          - 超出速率限制次数
# requeues              - 重新入队次数（htb 令牌等待）
# backlog               - 当前队列积压

# 查看 class 统计（htb）
tc -s class show dev eth0

# 查看 filter 统计
tc -s filter show dev eth0

# 使用 ss 查看连接的实际吞吐
ss -i dst 8.8.8.8  # 显示 rtt/cwnd/bytes_acked 等

# 使用 iperf3 测试带宽整形效果
iperf3 -c 192.168.1.1 -t 30 -P 4

# 使用 tc-nat（tc filter 中的 NAT 动作，用于 DSR）
tc filter add dev eth0 parent ffff: protocol ip u32 \
    match ip dst 203.0.113.1/32 \
    action nat ingress 203.0.113.1/32 192.168.1.100
```

---

## 12. 完整的家庭路由器 QoS 配置

```bash
#!/bin/bash
# 完整的家庭路由器 QoS（100Mbit 宽带）

WAN=eth0
LAN=eth1
BW=95mbit   # 95% 避免 ISP 侧缓冲膨胀

# 清空现有配置
tc qdisc del dev $WAN root 2>/dev/null
tc qdisc del dev $LAN root 2>/dev/null

# 出向（WAN）使用 CAKE
tc qdisc add dev $WAN root cake \
    bandwidth $BW \
    diffserv4 \        # 4 个 DSCP 优先级桶
    nat \              # NAT 感知
    wash \             # 清洗 DSCP
    overhead 22        # PPPoE

# 入向（WAN ingress -> IFB）
modprobe ifb
ip link set ifb0 up
tc qdisc add dev $WAN handle ffff: ingress
tc filter add dev $WAN parent ffff: protocol all u32 \
    match u32 0 0 action mirred egress redirect dev ifb0
tc qdisc add dev ifb0 root cake \
    bandwidth $BW \
    diffserv4 \
    nat \
    ingress \          # 告知 CAKE 这是 ingress 方向（翻转 src/dst）
    overhead 22

echo "QoS 配置完成"
echo "出向：CAKE $BW on $WAN"
echo "入向：CAKE $BW on ifb0 (via $WAN ingress)"
```

---

## 13. 小结

Linux tc QoS 框架提供了从简单限速到复杂层次带宽管理的完整工具集：

- **TBF** 简单高效的出向限速，适合单一速率整形
- **HTB** 层次化带宽分配，支持保障/借用机制，适合多租户/多业务 QoS
- **FQ-CoDel/CAKE** 通过 AQM 控制缓冲膨胀，是家庭/边缘网络的最佳选择
- **cls_bpf** 用 eBPF 实现完全可编程的分类策略，无需重新编译内核
- **DSCP** 提供端到端的 QoS 信令，配合 tc 实现语音/视频优先
- **ingress + IFB** 将入向限速转换为出向整形，绕过 tc 只能控制出向的限制
- Kubernetes CNI bandwidth plugin 基于 tbf+IFB 为容器提供双向带宽限制

至此，**Part VI：Netfilter 与安全**全部 7 章完成。本 Part 从 Netfilter 基础框架到 iptables 扩展、nftables 新框架、conntrack 内部实现、NAT 深度原理、XDP 高性能处理，最终到 QoS 流量控制，构成了 Linux 网络安全与策略处理的完整知识体系。

下一 Part（Part VII：高级特性与优化）将深入 GRO/GSO、RSS/RPS、TSO/UFO、BPF 网络钩子与硬件 offload。
