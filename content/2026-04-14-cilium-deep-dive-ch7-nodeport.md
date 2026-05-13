---
title: "Cilium 深度探索 (7)：NodePort 与 XDP 直连"
date: 2026-04-14
tags:
  - cilium
  - nodeport
  - xdp
  - dsr
  - ebpf
  - kubernetes
  - networking
  - load-balancer
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]
> 6. [[2026-04-14-cilium-deep-dive-ch6-clusterip|第六章：ClusterIP]]
> 7. **第七章：NodePort** ←

---

## 1. NodePort 概述

NodePort 是 Kubernetes Service 的一种类型，通过在集群所有节点的**静态端口**（30000-32767）上暴露服务，使外部流量可以直接访问集群内部应用：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: NodePort
  selector:
    app: my-app
  ports:
    - port: 80 # Service Port（集群内部访问）
      targetPort: 8080 # Container Port
      nodePort: 30080 # NodePort（静态端口，可选）
      protocol: TCP
```

**传统 kube-proxy 实现的问题**：

```
外部流量 → 物理网卡 → 内核协议栈 → iptables → kube-proxy → Pod
                          ↑
                    （所有包都经过这里）
                    额外延迟 + CPU 开销
```

**Cilium XDP 实现的优势**：

```
外部流量 → 物理网卡 → XDP 程序 → 直接重定向到 Pod
                          ↑
              （在网卡驱动层直接处理，绕过协议栈）
              极低延迟 + 高吞吐量
```

---

## 2. XDP 架构深入

### 2.1 XDP 概述

XDP（Express Data Path）是 Linux 内核中**最早的可编程数据包处理点**，在网卡驱动层、skb 分配之前就处理数据包：

```
数据包到达网卡驱动
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│                     XDP Hook                            │
│                                                          │
│  - 最早可编程点（skb 分配之前）                           │
│  - 直接在 NIC 驱动层处理                                 │
│  - 三种处理模式：                                        │
│    • XDP_PASS - 交给内核协议栈处理                        │
│    • XDP_DROP - 直接丢弃                                 │
│    • XDP_REDIRECT - 重定向到其他队列/接口                │
│                                                          │
└──────────────────────────────────────────────────────────┘
        │
        ▼
  skb 分配（如果需要继续处理）
        │
        ▼
   内核协议栈
```

### 2.2 Cilium NodePort XDP 程序

Cilium 在物理网卡上挂载 XDP 程序处理 NodePort 流量：

```c
// bpf/nodeport_lb.c（简化）

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>

#include "lib/common.h"
#include "lib/drop.h"
#include "lib/lb.h"

// NodePort XDP 处理入口
static __always_inline int
nodeport_lb(struct xdp_md *ctx) {
    void *data     = (void *)(long)ctx->data;
    void *data_end  = (void *)(long)ctx->data_end;

    // 解析以太网头
    struct ethhdr *eth = data;
    if (data + sizeof(*eth) > data_end)
        return XDP_PASS;

    // 仅处理 IPv4
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    // 解析 IP 头
    struct iphdr *ip = data + sizeof(*eth);
    if (data + sizeof(*eth) + sizeof(*ip) > data_end)
        return XDP_PASS;

    // 仅处理 TCP
    if (ip->protocol != IPPROTO_TCP)
        return XDP_PASS;

    // 解析 TCP 头
    struct tcphdr *tcp = (void *)(ip + 1);
    if ((void *)(tcp + 1) > data_end)
        return XDP_PASS;

    // 检查是否是 NodePort 端口
    __u32 nodeport_key = bpf_ntohs(tcp->dest);

    // 查找 cilium_nodeport_services Map
    struct nodeport_service_value *svc;
    svc = bpf_map_lookup_elem(&cilium_nodeport_services, &nodeport_key);

    if (!svc)
        return XDP_PASS;  // 不是 NodePort，交给协议栈

    // 执行负载均衡和 DNAT
    return XDP_REDIRECT;
}
```

### 2.3 XDP 处理模式

Cilium NodePort 支持三种 XDP 模式：

| 模式           | 说明                       | 性能 | 兼容性           |
| :------------- | :------------------------- | :--- | :--------------- |
| **XDPDirect**  | 原生 XDP，直接在驱动层处理 | 最高 | 需要驱动支持 XDP |
| **XDPGeneric** | 通用 XDP，skb 已分配后处理 | 中等 | 所有驱动支持     |
| **XDPOffload** | 硬件卸载到 SmartNIC        | 最高 | 需要硬件支持     |

```bash
# 查看当前 XDP 模式
kubectl -n kube-system exec ds/cilium -- cilium config | grep xdp

# 查看网卡上的 XDP 程序
ip link show eth0
# eth0: <BROADCAST,MULTICAST,UP>
#    xdp_drop: eth_xdp_prog()  ← XDP 程序已挂载
#    xdpgeneric: eth_xdp_prog()
#    xdpdrv: eth_xdp_prog()

# 验证 XDP 状态
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf nodeport list
```

---

## 3. Direct Server Return (DSR)

### 3.1 DSR 原理

传统 NodePort 路径（SNAT）：

```
Client → NodePort → DNAT → Pod → SNAT → Client
         ↑                              │
         └──────── 响应经过中转 ────────┘
```

DSR 路径（无 SNAT）：

```
Client → NodePort → DNAT → Pod → 直接响应 Client
                              ↑
                        （不使用 SNAT）
```

**DSR 的核心优势**：

1. **降低延迟**：响应包不经过 NodePort 处理
2. **更高吞吐量**：每个节点吞吐量翻倍
3. **负载均衡改善**：回程路径自然分散到各后端节点

### 3.2 Cilium DSR 实现

```c
// DSR 处理关键逻辑

static __always_inline int
nodeport_lb_dsr(struct xdp_md *ctx, struct dsr_config *cfg) {
    // 1. 选择后端
    __u32 backend_id = lb_select_backend(svc, iphdr->saddr);

    // 2. 获取后端信息
    struct backend_value *backend;
    backend = bpf_map_lookup_elem(&cilium_backends, &backend_id);

    // 3. 修改目标：ServiceIP → BackendIP
    iphdr->daddr = backend->addr;

    // 4. 存储原始目标（用于返回时恢复）
    //    通过 connection tracking 或 IP-in-IP 隧道
    cfg->orig_daddr = service_ip;
    cfg->backend_ip = backend->addr;

    // 5. 封装（DSR 需要某种方式保留原始 Service 信息）
    //    方式1：IP-in-IP 封装
    //    方式2：直接路由（后端能直接访问 Client IP）

    return XDP_REDIRECT;
}
```

### 3.3 DSR 流量路径

```
┌─────────────────────────────────────────────────────────────────┐
│                        外部 Client                               │
│                    Client IP: 203.0.113.50                       │
└─────────────────────────────────────────────────────────────────┘
        │                                              ▲
        │ 1. TCP SYN (dst: NodeIP:30080)              │
        │    Client → 203.0.113.1:30080               │
        ▼                                              │
┌───────────────────────────────────────────────────────────────┐
│                         Node A (物理网卡 eth0)                  │
│                                                               │
│  XDP Hook                                                     │
│  ├── 匹配 NodePort 端口 30080                                 │
│  ├── 查找后端：Backend Pod (Node B: 10.0.2.1:8080)            │
│  ├── DNAT：NodeIP:30080 → 10.0.2.1:8080                       │
│  └── 封装 VXLAN/IP-in-IP（携带原始目标）                       │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │            发送到 Node B（Overlay/VXLAN）               │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
        │
        │ 封装后的包 (outer: NodeA → NodeB, inner: Client → Svc)
        ▼
┌───────────────────────────────────────────────────────────────┐
│                         Node B (Backend 所在节点)              │
│                                                               │
│  TC Ingress Hook                                               │
│  ├── 解封装 VXLAN                                              │
│  ├── 提取原始 Service 信息                                     │
│  ├── DNAT：ServiceIP → Local Pod IP                           │
│  └── 发送到本地 Backend Pod                                    │
│                                                               │
│  Pod (10.0.2.1:8080)                                          │
│        │                                                      │
│        │ 4. TCP SYN                                           │
│        │ ──────────► 直接发送给 Client（无需经过 NodePort）    │
│        │                                                      │
└───────────────────────────────────────────────────────────────┘
        │
        │ 5. TCP SYN-ACK (src: ServiceIP:80 → ClientIP)
        ▼
┌───────────────────────────────────────────────────────────────┐
│                        外部 Client                               │
│            Client 收到响应：ServiceIP:80 → ClientIP            │
└───────────────────────────────────────────────────────────────┘
```

### 3.4 启用/禁用 DSR

```bash
# DSR 默认启用
# 查看 DSR 配置
kubectl -n kube-system exec ds/cilium -- \
    cilium config | grep dsr

# 禁用 DSR（使用 SNAT 模式）
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ebpF.loadBalancer.mode=snat

# DSR vs SNAT 对比
# DSR:   延迟更低，吞吐量更高，但需要回程路由可达
# SNAT:  兼容性更好，所有场景通用，但有额外开销
```

---

## 4. Backend Selection 算法

### 4.1 随机选择（Random）

每个 NodePort 请求随机选择一个后端：

```c
// 随机选择
static __always_inline __u32
lb_select_backend_random(__u32 backend_count) {
    return bpf_get_prandom_u32() % backend_count;
}
```

适用场景：短期连接，无状态服务。

### 4.2 最少连接（Least Connection）

选择当前活动连接数最少的后端：

```c
struct backend_value {
    __u32 addr;
    __u16 port;
    __u32 active_connections;  // 活动连接计数
    __u32 refcount;
};

// 最少连接选择
static __always_inline __u32
lb_select_backend_least_conn(__u32 backend_count) {
    __u32 min_conn = -1;
    __u32 selected = 0;

    for (__u32 i = 0; i < backend_count; i++) {
        struct backend_value *backend = ...;
        if (backend->active_connections < min_conn) {
            min_conn = backend->active_connections;
            selected = i;
        }
    }
    return selected;
}
```

适用场景：长连接服务（数据库、RPC）。

### 4.3 Session Affinity（会话保持）

基于源 IP 的一致性哈希：

```c
// Maglev 哈希选择（详见 ClusterIP 章节）
static __always_inline __u32
lb_select_backend_maglev(__u32 src_ip, __u32 backend_count) {
    __u32 h1 = hash_1(src_ip);
    __u32 h2 = hash_2(src_ip);

    // Maglev 查找表查询
    __u32 idx = (h1 + h2 * ...) % M;
    return maglev_table[idx] % backend_count;
}
```

适用场景：需要会话保持的服务（购物车、用户会话）。

### 4.4 本地优先（Local Backend First）

优先选择本地节点的后端，减少跨节点流量：

```bash
# 配置本地优先
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ebpF.loadBalancer.mode=hybrid
    # hybrid 模式：本地后端直接处理，跨节点使用 DSR
```

---

## 5. 外部流量路径详解

### 5.1 流量进入节点

```
外部流量
    │
    ▼
┌─────────────────────────────────────┐
│         物理网卡 eth0               │
│                                     │
│  XDP 程序（nodeport_lb）           │
│                                     │
│  1. 解析包头（Eth + IP + TCP）      │
│  2. 检查目标端口是否是 NodePort     │
│  3. 查找 cilium_nodeport_services   │
│                                     │
│  匹配成功 → DSR/DNAT + 重定向       │
│  匹配失败 → XDP_PASS → 协议栈      │
│                                     │
└─────────────────────────────────────┘
```

### 5.2 NodePort Service Map

```c
// cilium_nodeport_services Map 结构
struct nodeport_key {
    __u32 addr;        // 0.0.0.0（监听所有接口）
    __u16 port;        // NodePort (e.g., 30080)
    __u8  proto;       // TCP/UDP
    __u8  pad;
};

struct nodeport_value {
    __u32 cluster_service_id;  // 关联的 ClusterIP Service ID
    __u32 backend_count;
    __u32 backend_ids[16];
    __u32 flags;               // DSR / SNAT / Local
};
```

### 5.3 完整请求流程

```
Client                           Node A                          Pod
   │                                │                              │
   │  TCP SYN                       │                              │
   │  dst: NODE_A:30080            │                              │
   │  src: CLIENT:54321            │                              │
   │ ─────────────────────────────►│                              │
   │                                │                              │
   │                                │ XDP (网卡驱动层)              │
   │                                │ ├─ 匹配端口 30080             │
   │                                │ ├─ 查找后端: 10.0.2.1:8080    │
   │                                │ ├─ DNAT: NODE_A → 10.0.2.1   │
   │                                │ └─ 封装VXLAN/直接路由        │
   │                                │                              │
   │                                │ VXLAN Encapped               │
   │                                │ dst: NODE_B                  │
   │                                │ inner: CLIENT → 10.0.2.1     │
   │ ──────────────────────────────────────────────────────────────►│
   │                                │                              │
   │                                │          Node B (TC Ingress) │
   │                                │          ├─ 解封装 VXLAN     │
   │                                │          ├─ DNAT → Local Pod │
   │                                │          └─ 转发 Pod         │
   │                                │                              │
   │                                │         TCP SYN              │
   │                                │ ─────────────────────────────►│
   │                                │                              │
   │                                │                              │
   │                                │         TCP SYN-ACK          │
   │                                │ ◄─────────────────────────────│
   │                                │                              │
   │                                │  DSR: 直接响应 Client         │
   │   TCP SYN-ACK                  │◄─────────────────────────────│
   │ ◄─────────────────────────────│                              │
   │   src: 10.0.2.1:8080          │                              │
   │   dst: CLIENT:54321           │                              │
```

---

## 6. NodePort 配置与优化

### 6.1 端口范围配置

NodePort 默认范围：30000-32767

```bash
# Kubernetes API Server 配置
# --service-node-port-range=30000-32767

# 查看当前范围
kubectl get pod kube-apiserver -n kube-system -o yaml | grep service-node-port-range

# Cilium 也支持自定义范围
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set nodePort.range=30000-32767
```

### 6.2 监听地址配置

```yaml
# 默认：监听所有接口 (0.0.0.0)
# 可配置为仅监听内部网络

apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: NodePort
  externalTrafficPolicy: Local # 仅路由到本地后端
  ports:
    - port: 80
      nodePort: 30080
```

**externalTrafficPolicy**：

| 策略        | 说明                       | SNAT | 源 IP 保留 |
| :---------- | :------------------------- | :--- | :--------- |
| **Cluster** | 流量可分布到任何节点的后端 | 是   | 否         |
| **Local**   | 流量仅路由到本地后端       | 否   | 是         |

```bash
# Local 模式下的 Cilium 处理
# XDP 检查后端是否在本地
# 若无本地后端 → ICMP No NodePort Local Endpoint
# 若有本地后端 → 直接 DNAT + DSR（无 SNAT）
```

### 6.3 性能调优

```bash
# 1. 启用 XDP 加速（推荐）
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ebpF.loadBalancer.mode=hybrid

# 2. 调整 BPF Map 大小
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set ebpF.lbMapMax=1000000

# 3. 查看当前 XDP 状态
kubectl -n kube-system exec ds/cilium -- \
    cilium nodeport list

# 4. 监控 XDP 统计
ip -s link show eth0
# xdp_drop: 0  ← 丢弃计数
# xdp_pass: 12345  ← 通过计数
```

---

## 7. 验证与排错

### 7.1 查看 NodePort Service

```bash
# 查看所有 NodePort Service
kubectl get svc -o wide --field-selector spec.type=NodePort

# 查看 Service 详情
kubectl describe svc my-app
```

### 7.2 查看 Cilium NodePort 状态

```bash
# 列出所有 NodePort 配置
kubectl -n kube-system exec ds/cilium -- \
    cilium nodeport list

# 输出示例：
# NODEPORT     FRONTEND            SERVICE         BACKEND
# 30080        0.0.0.0:30080       my-app:80       1/2 active
# 30081        0.0.0.0:30081       my-app:443      1/1 active
```

### 7.3 测试 NodePort 连通性

```bash
# 从集群外部测试
curl http://<NODE_IP>:30080

# 使用 hostNetwork Pod 测试
kubectl run test --image=busybox --restart=Never -it -- \
    wget -q -O- http://<NODE_IP>:30080

# 验证 DSR（抓包分析）
# 在后端 Pod 所在节点抓包
tcpdump -i eth0 -n "tcp port 30080"

# 应该看到源 IP 是 Client IP（而非 Node IP）
```

### 7.4 常见问题与解决

| 问题              | 原因              | 解决方法                           |
| :---------------- | :---------------- | :--------------------------------- |
| NodePort 无法访问 | XDP 未启用        | 检查 `cilium agent` 日志，启用 XDP |
| 外部无法访问      | 防火墙阻止        | 开放 30000-32767 端口              |
| DSR 不生效        | 后端跨节点        | 启用 Local externalTrafficPolicy   |
| 后端连接失败      | SNAT 导致回程不通 | 确认网络拓扑支持 DSR               |
| 部分节点不通      | XDP 程序未加载    | 重启该节点 cilium-agent            |

---

## 8. 章节总结

|                           | 主题                 | 关键点                     |
| :------------------------ | :------------------- | :------------------------- |
| **XDP 架构**              | 网卡驱动层处理       | 最早可编程点，绕过协议栈   |
| **DSR**                   | Direct Server Return | 后端直接响应，无 SNAT 开销 |
| **Backend Selection**     | Random/LC/Maglev     | 支持多种负载均衡算法       |
| **Local Priority**        | 本地后端优先         | 减少跨节点流量，降低延迟   |
| **externalTrafficPolicy** | Cluster/Local        | 控制流量分布策略           |

**性能对比**：

| 实现                | 吞吐量       | 延迟 | CPU 开销 |
| :------------------ | :----------- | :--- | :------- |
| kube-proxy iptables | ~500 Kpps    | 高   | 高       |
| kube-proxy IPVS     | ~800 Kpps    | 中   | 中       |
| Cilium XDP DSR      | ~2,000+ Kpps | 低   | 低       |

**下一章**：LoadBalancer——Cilium 如何与云厂商 LB 集成，实现 L2/L4 负载均衡。

---

## 参考资料

- [Cilium NodePort XDP](https://docs.cilium.io/en/stable/concepts/services/#nodeport)
- [XDP Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [Cilium DSR Mode](https://docs.cilium.io/en/stable/concepts/services/#direct-server-return)
- [BPF XDP Tutorial](https://www.bpf.dev/subsets/xdp)
