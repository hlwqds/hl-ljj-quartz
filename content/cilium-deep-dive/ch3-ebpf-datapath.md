---
title: "Cilium 深度探索 (3)：eBPF 数据面"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - datapath
  - xdp
  - tc
  - socket
  - kubernetes
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
>
> 1. [[ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[ch2-architecture|第二章：Cilium 架构]]
> 3. **第三章：eBPF 数据面** ←
> 4. [[ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[ch5-cni|第五章：CNI 集成]]

---

## 1. eBPF 数据面全图

Cilium 的数据面完全构建在 eBPF 之上，从数据包到达网卡到最终被 Pod 接收，整个路径上的**每个关键点都可以通过 eBPF 程序干预**。

```
┌────────────────────────────────────────────────────────────────────────┐
│                          数据包生命周期                                  │
│                                                                        │
│  [NIC 硬件]                                                            │
│       │                                                                │
│       ▼                                                                │
│  ┌─────────┐  ★ XDP (最早可编程点)                                     │
│  │  NIC    │    - DDoS 防护：在 skb 分配之前就丢弃恶意包                │
│  │ Driver  │    - 负载均衡：Direct Server Return (DSR)                  │
│  └────┬────┘    - 快速重定向：绕过内核协议栈                             │
│       │                                                                │
│       ▼                                                                │
│  [分配 skb - 分配内存描述符]                                           │
│       │                                                                │
│       ▼                                                                │
│  ┌─────────┐  ★ TC Ingress (流量控制入口)                               │
│  │ 路由    │    - Service 查找：cilium_services Map O(1) 查找          │
│  │ 检查    │    - 策略执行：L3/L4/L7 策略                                │
│  └────┬────┘    - 身份验证：Security Identity                           │
│       │         - 隧道解封装：VXLAN/Geneve                             │
│       ▼                                                                │
│  ┌─────────┐  ★ Socket 层（connect/bind/sendmsg 劫持）                 │
│  │  进程   │    - 进程级别安全策略                                      │
│  │  Socket │    - Sockmap：TCP 连接优化                                 │
│  └────┬────┘    - 透明加速：绕过协议栈直接转发                           │
│       │                                                                │
│       ▼                                                                │
│  [协议栈处理：TCP/UDP/ICMP]                                            │
│       │                                                                │
│       ▼                                                                │
│  ┌─────────┐  ★ TC Egress (流量控制出口)                               │
│  │  路由   │    - NAT：Source NAT / Dest NAT                           │
│  │ 决策    │    - 策略检查：出口方向策略                                 │
│  └────┬────┘    - 隧道封装：VXLAN/Geneve                                │
│       │                                                                │
│       ▼                                                                │
│  [NIC 驱动]                                                            │
│       │                                                                │
│       ▼                                                                │
│  [NIC 硬件]                                                            │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. XDP：极致性能的秘密

### 2.1 什么是 XDP？

XDP（Express Data Path）是 Linux 内核中**最早的可编程点**，位于网卡驱动收到数据包之后、**分配 skb（socket buffer）之前**。

```
传统网络路径（不经过 XDP）：
  NIC 驱动 → 分配 skb → 放入内核协议栈 → 路由查找 → iptables → ...

XDP 路径：
  NIC 驱动 → [XDP 程序执行] → 分配 skb → 放入内核协议栈 → ...

XDP 快速路径（Drop/Redirect）：
  NIC 驱动 → [XDP 程序执行] → 直接丢弃或重定向 → 【不分配 skb】
```

关键优势：**XDP 在不分配 skb 的情况下就能处理数据包**，因此可以以接近线速（wire-speed）执行。

### 2.2 XDP 的三种处理模式

```c
// XDP 程序的返回值决定数据包命运

enum xdp_action {
    XDP_DROP,      // 直接丢弃 - 用于 DDoS 防护
    XDP_PASS,      // 交给内核协议栈处理
    XDP_REDIRECT,  // 重定向到其他网卡或 AF_XDP socket
    XDP_TX,        // 从同一网卡发回（需要多队列网卡）
    XDP_ABORTED,   // 异常丢弃（触发 tracepoint）
};
```

**典型使用场景：**

| 场景                 | XDP 处理               | 说明                             |
| :------------------- | :--------------------- | :------------------------------- |
| **DDoS 防护**        | XDP_DROP               | 在 skb 分配前丢弃，节省 CPU      |
| **LoadBalancer DSR** | XDP_REDIRECT           | 直接重定向到后端 Pod，绕过协议栈 |
| **包镜像**           | XDP_PASS + 克隆        | 复制一份到镜像接口               |
| **限速**             | XDP_DROP（基于令牌桶） | 丢弃超过阈值的包                 |

### 2.3 Cilium 中的 XDP

Cilium 在 XDP 层实现了 **NodePort DSR（Direct Server Return）**：

```bash
# 查看当前 Cilium 的 XDP 程序状态
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list

# 示例输出：
# FRONTEND              SERVICE ID   BACKEND
# 10.96.0.1:443          1            192.168.1.10:6443 (active)
#                        1            192.168.1.11:6443 (active)
# 10.96.89.173:80        2            10.0.0.1:8080 (active)
#                                   10.0.0.2:8080 (active)
```

NodePort 外部流量到达时，XDP 程序直接将包重定向到目标 Pod，无需经过 Service IP → Endpoint 的两次转换。

---

## 3. TC（Traffic Control）Ingress

### 3.1 TC Ingress 在数据包路径中的位置

TC Ingress 位于**路由决策之后**，在内核分配 skb 并完成基本解析之后执行。此时数据包已经经过了：

- NIC 驱动
- XDP（如果启用了 XDP）
- skb 分配
- MAC 地址解析
- 路由查找（决定包的去向：本地还是转发）

```
数据包到达
    ↓
[skb 分配]
    ↓
[MAC 层处理]
    ↓
[路由查找] ──── 本地 → TC Ingress ────→ 传输层（TCP/UDP）
    │                         ↑
    │                         │
    └────── 转发 ──── TC Egress ──→ NIC
```

### 3.2 TC Ingress 的核心职责

**Cilium 在 TC Ingress 中完成了大部分数据面工作：**

1. **Service 查找**：查询 `cilium_services` Map，将 Service IP 转换为 Backend Pod IP
2. **策略检查**：执行 L3/L4/L7 安全策略
3. **身份验证**：确认数据包的发送方具有合法身份
4. **隧道解封装**：处理来自其他节点的 VXLAN 包

### 3.3 eBPF 代码结构（简化）

```c
// cilium/bpf/lib/drop.h - 定义丢弃宏
#define DROP咚_咕咕咕_咕咕咕_咕咕咕_咕咕咕_咕咕咕_咕咕咕 DROP_RSOURCE

// cilium/bpf/lib/lb.h - 负载均衡核心
static __always_inline int
lb4_lookup(struct ctlum_tuplehash *ht, struct ctlum_entry *val) {
    // 从 ctlum_services map 中查找 Service
    struct ctlum_service_key key = {
        .addr = val->addr,
        .port = val->port,
    };
    return map_lookup_elem(&cilium_services, &key);
}

// cilium/bpf/progs/desc-op-internal.h - 端点处理
static __always_inline int
handle_ingress_ipv4(struct ctlum_hdr *hdr) {
    // 1. 查找目标 Endpoint
    struct ctlum_endpoint_key ep_key = {};
    ep_key.ip4 = hdr->dst;

    struct ctlum_endpoint_value *ep = map_lookup_elem(&cilium_endpoints, &ep_key);
    if (!ep)
        return CTLM_FRAME_DROP;

    // 2. 验证发送方身份
    if (!validate_identity(hdr->src))
        return CTLM_FRAME_DROP_POLICY;

    // 3. 执行 L7 策略（如有）
    if (ep->l7_policy)
        return handle_l7_policy(hdr, ep);

    // 4. 转发到本地 Pod
    return redirect(ep->ifindex);
}
```

### 3.4 查看 TC 程序

```bash
# 列出所有加载的 eBPF 程序
kubectl -n kube-system exec ds/cilium -- cilium bpf prog list

# 查看特定节点的 endpoint 映射
kubectl -n kube-system exec ds/cilium -- cilium bpf endpoint get <pod-id>

# 查看 Service 映射内容
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list
```

---

## 4. Socket 劫持（Socket-level Policy）

### 4.1 什么是 Socket 劫持？

Cilium 可以在**进程级别**拦截 `connect()`、`bind()`、`sendmsg()` 等 socket 系统调用，在应用程序**不知道的情况下**执行策略或透明加速。

```
传统 connect()：
  App → connect() → 内核协议栈 → 建立 TCP 连接

被 Cilium 劫持的 connect()：
  App → connect() → [Cilium eBPF 拦截] → 检查策略
                                      → 如允许 → 透明加速（绕过协议栈）
                                      → 如拒绝 → 返回 EPERM
```

### 4.2 两种 Socket 劫持模式

| 模式                | Hook 点                | 用途                                          |
| :------------------ | :--------------------- | :-------------------------------------------- |
| **socket redirect** | `sockops` 或 `sk_msg`  | 将 TCP/UDP 连接重定向到 Sockmap，实现透明加速 |
| **socket policy**   | `connect()` / `bind()` | 在连接建立前检查策略，决定是否允许            |

### 4.3 Sockmap：TCP 连接优化

Sockmap 允许 Cilium 将两个 socket 直接映射在一起，让数据**在两个 socket 之间直接复制**，绕过协议栈：

```
未使用 Sockmap：
  Pod A (进程) → send() → 内核协议栈 → TCP 协议处理 → NIC →
              ← recv() ← 内核协议栈 ← TCP 协议处理 ← NIC ← Pod B

使用 Sockmap（Cilium 透明加速）：
  Pod A (进程) → send() → [eBPF 劫持] → 直接复制到 Pod B 的 socket buffer
                                   ↑
  Pod B (进程) ← recv() ←───────────┘
```

这种方式对于**同节点上 Pod 之间的通信**特别有效，可以将延迟降低 50%+。

```bash
# 检查 Sockmap 状态
kubectl -n kube-system exec ds/cilium -- cilium bpf socklist

# 查看 socket 统计
kubectl -n kube-system exec ds/cilium -- cilium bpf sockstats
```

---

## 5. Host Routing（宿主机路由）

### 5.1 Host Routing 的作用

当数据包需要**跨越节点边界**时，Cilium 通过 Host Routing 处理宿主机层面的转发逻辑：

```
Node A 上的 Pod → 访问 Node B 上的 Pod
    ↓
Node A 的 TC Egress：封装VXLAN 包
    ↓
Node A 的物理网卡发出
    ↓
Node B 的物理网卡接收
    ↓
Node B 的 XDP/TC Ingress：解封装 VXLAN
    ↓
Node B 内核路由：查找 cilium_host（dummy 接口）
    ↓
Node B 的 TC Ingress：转发到目标 Pod
```

### 5.2 cilium_host 接口

`cilium_host` 是一个 **dummy 类型**的虚拟网络接口，所有发往宿主机上 Cilium 管理范围的数据包都会经过它：

```bash
# 查看 cilium_host 接口
ip link show cilium_host

# 示例输出：
# 14: cilium_host@NONE: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500
#     link/ether 12:34:56:78:9a:bc brd ff:ff:ff:ff:ff:ff
#     inet 10.244.0.254/32 scope link cilium_host
```

**为什么用 dummy 接口而不是真实设备？**

- `cilium_host` 不对应任何物理设备，只作为路由目标
- 所有发往 Pod 的包都通过这条路由到达 TC 层
- 避免了真实网卡层面的复杂配置

---

## 6. 端到端数据包流程

### 6.1 同节点 Pod 间通信

```
Pod A (10.0.0.1) → Pod B (10.0.0.2)

1. Pod A 通过 veth pair 发送包
2. Node A 的 phys → veth pair → TC Ingress
3. TC Ingress 查找 cilium_endpoints → 找到 Pod B 的 veth
4. 转发到 Pod B 的 veth
5. Pod B 接收
```

### 6.2 跨节点 Pod 间通信（VXLAN）

```
Pod A (Node A, 10.0.0.1) → Pod B (Node B, 10.0.0.3)

1. Pod A 发包到 10.0.0.3
2. Node A 路由查找发现目标不在本地
3. TC Egress 从 cilium_services 查找 Service（如有）
4. TC Egress 执行 VXLAN 封装（目标 MAC = Node B 的 MAC）
5. 通过物理网卡发出
6. Node B 物理网卡接收
7. XDP → TC Ingress：解封装 VXLAN
8. TC Ingress 查找 cilium_endpoints → 找到 Pod B
9. 转发到 Pod B
```

### 6.3 外部访问 Service（NodePort + DSR）

```
External Client → NodePort → Pod

1. 外部流量到达 Node B 的 NodePort (例如 30080)
2. XDP 程序直接重定向到目标 Pod（绕过内核协议栈）
3. Pod 直接响应客户端（Source NAT 由 Pod 自己完成）
```

---

## 7. eBPF Map 与数据面状态

### 7.1 核心 Map 速查

| Map                 | 类型       | Key                   | Value                      | 用途            |
| :------------------ | :--------- | :-------------------- | :------------------------- | :-------------- |
| `cilium_services`   | Hash / LPM | `{addr, port, proto}` | `svc_val` (backends)       | Service 查找    |
| `cilium_endpoints`  | Hash       | `{ip}`                | `{ifindex, mac, identity}` | Endpoint 元数据 |
| `cilium_ipcache`    | LPM Trie   | `{ip/prefix}`         | `{identity, node_ip}`      | IP → Identity   |
| `cilium_policy`     | LPM Trie   | `{identity, port}`    | `policy_result`            | 安全策略        |
| `cilium_tunnel_map` | Hash       | `{node_ip}`           | `{tunnel_endpoint}`        | 隧道端点        |

### 7.2 Map 查找性能

eBPF Map 使用**哈希表或基数树**实现，查找复杂度为 **O(1)**，不受规则数量影响：

```bash
# 查看 Map 统计（命中率）
kubectl -n kube-system exec ds/cilium -- cilium bpf map list

# 查看特定 Map 的内容
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf map dump cilium_services
```

---

## 8. 章节总结

| eBPF Hook       | 位置             | Cilium 职责                        |
| :-------------- | :--------------- | :--------------------------------- |
| **XDP**         | 网卡驱动，最早点 | DDoS 防护、NodePort DSR            |
| **TC Ingress**  | 路由决策后       | Service 查找、策略执行、隧道解封装 |
| **Socket Hook** | 系统调用层       | 进程级策略、Sockmap 加速           |
| **TC Egress**   | 发出前           | NAT、隧道封装、出口策略            |

**下一章**：Kube-Proxy 替代——Cilium 如何用 eBPF 实现比 kube-proxy 更高效的 Service 负载均衡。

---

## 参考资料

- [Cilium Datapath Architecture](https://docs.cilium.io/en/stable/architecture/datapath/)
- [XDP Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [Cilium BPF Maps](https://docs.cilium.io/en/stable/bpf/)
- [Linux TC (Traffic Control) Howto](https://tldp.org/HOWTO/Traffic-Control-HOWTO/)
