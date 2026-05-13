---
title: "Cilium 深度探索 (8)：LoadBalancer 负载均衡"
date: 2026-04-14
tags:
  - cilium
  - loadbalancer
  - l2-lb
  - l4-lb
  - metallb
  - ebpf
  - kubernetes
  - networking
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]
> 6. [[2026-04-14-cilium-deep-dive-ch6-clusterip|第六章：ClusterIP]]
> 7. [[2026-04-14-cilium-deep-dive-ch7-nodeport|第七章：NodePort]]
> 8. **第八章：LoadBalancer** ←

---

## 1. LoadBalancer 概述

LoadBalancer 是 Kubernetes Service 中**最常用的外部访问方式**，它整合了云厂商的负载均衡器，提供一个稳定的外部 IP（通常是公网 IP）访问集群内部服务：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    # 云厂商特定注解
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
  # externalTrafficPolicy: Local
  # sessionAffinity: ClientIP
```

**LoadBalancer 类型 Service 的挑战**：

1. 需要云厂商支持（AWS ELB、GCP Cloud LB、Azure ALB）
2. 在裸金属环境中没有云厂商 LB
3. 传统方案依赖外部负载均衡器（如 HAProxy）

**Cilium 的 LoadBalancer 方案**：

- **云环境**：与云厂商 LB 深度集成（AWS NLB、GCP Cloud LB）
- **裸金属**：通过 **MetalLB** 提供 L2 和 L4 负载均衡
- **内部**：Cilium Cluster LoadBalancer（CCN/CNCM）跨集群服务

---

## 2. L2 vs L4 vs L7 Load Balancing

### 2.1 三层负载均衡对比

| 层次 | 协议 | 例子 | Cilium 支持 |
|:---|:---|:---|:---|
| **L2 (Data Link)** | Ethernet | MetalLB L2 | ✅ |
| **L4 (Transport)** | TCP/UDP | NLB, Cloud LB | ✅ |
| **L7 (Application)** | HTTP/HTTPS | ALB, Ingress | ✅ (via Envoy) |

### 2.2 L2 Load Balancing (ARP/NDP)

L2 模式通过 **ARP（NDP for IPv6）** 欺骗，将 LoadBalancer IP 绑定到某个节点：

```
┌─────────────────────────────────────────────────────────────┐
│                   L2 Load Balancing                        │
│                                                             │
│  Client 请求: 10.0.0.100 (LoadBalancer IP)                 │
│       │                                                    │
│       │ ARP Request: Who has 10.0.0.100?                   │
│       ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              MetalLB Speaker (所有节点)              │   │
│  │                                                      │   │
│  │  Speaker A: ARP Reply (我是 10.0.0.100)             │   │
│  │  ───────────────────────────────────────►           │   │
│  │  (使用 GARP 抢先宣告)                                │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                    │
│       ▼                                                    │
│  所有流量路由到 Node A                                     │
│       │                                                    │
│       ▼                                                    │
│  Node A 的 kube-proxy 或 Cilium 分发到后端 Pod              │
└─────────────────────────────────────────────────────────────┘
```

**L2 模式特点**：

- 简单：仅使用 ARP/NDP，无需额外协议
- 瓶颈：所有流量经过一个节点（选举的 Leader）
- 适用：低流量场景，测试环境

### 2.3 L4 Load Balancing (DSR)

L4 模式在传输层工作，利用 Cilium 的 **XDP + DSR** 实现高性能负载均衡：

```
┌─────────────────────────────────────────────────────────────┐
│                   L4 Load Balancing (DSR)                   │
│                                                             │
│  Client → NLB (10.0.0.100:80)                              │
│       │                                                    │
│       ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              云厂商 Network Load Balancer             │   │
│  │                                                      │   │
│  │  • 外部 Client IP 保持                                │   │
│  │  • 后端选择（云厂商或 Cilium XDP）                   │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                    │
│       ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Node A (XDP)                       │   │
│  │                                                      │   │
│  │  DNAT: 10.0.0.100 → Backend Pod IP                  │   │
│  │  DSR:   Backend 直接响应 Client                      │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                    │
│       ▼                                                    │
│  Backend Pod (直接响应 Client)                              │
└─────────────────────────────────────────────────────────────┘
```

**L4 DSR 特点**：

- 高性能：XDP 在网卡驱动层处理
- 源 IP 保留：Client IP 直接到达后端
- 可扩展：后端跨节点，流量自然分散

### 2.4 L7 Load Balancing (HTTP/HTTPS)

L7 负载均衡在应用层工作，支持 HTTP/HTTPS 路由、Cookie 亲和等高级功能：

```
┌─────────────────────────────────────────────────────────────┐
│                   L7 Load Balancing                         │
│                                                             │
│  Client HTTPS → ALB → /api/* → Service: api                │
│                 → /web/* → Service: web                    │
│                 → /admin/* → Service: admin (mTLS)         │
│                                                             │
│  Cilium 通过 Envoy Sidecar 或 Gateway API 实现             │
└─────────────────────────────────────────────────────────────┘
```

Cilium 支持两种 L7 方式：
1. **Cilium Ingress**：基于 Envoy 的 L7 Ingress Controller
2. **Cilium Gateway API**：标准的 Kubernetes Gateway API 实现

---

## 3. Cilium LoadBalancer 架构

### 3.1 组件架构

```
┌─────────────────────────────────────────────────────────────┐
│                 Kubernetes API Server                        │
│                                                             │
│  Service (type=LoadBalancer)                               │
│       │                                                     │
│       ▼                                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Cilium Agent (每个节点)                   │   │
│  │                                                      │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │           LoadBalancer Controller             │   │   │
│  │  │                                              │   │   │
│  │  │  1. 监听 LoadBalancer Service               │   │   │
│  │  │  2. 向云厂商 LB API 请求分配 IP              │   │   │
│  │  │  3. 配置 NodePort/ExternalIP                 │   │   │
│  │  │  4. 更新 Service Status (Ingress IP)        │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  │                                                      │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │              eBPF Data Plane                   │   │   │
│  │  │                                              │   │   │
│  │  │  • cilium_services (ClusterIP)              │   │   │
│  │  │  • cilium_nodeport (NodePort)               │   │   │
│  │  │  • cilium_external_ip (ExternalIP)          │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          云厂商 LoadBalancer / MetalLB               │   │
│  │                                                      │   │
│  │  • AWS NLB / GCP Cloud LB / Azure ALB              │   │
│  │  • MetalLB (L2 or L4)                               │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 LoadBalancer Service 创建流程

```
1. 用户创建 LoadBalancer Service
       │
       ▼
2. Kubernetes API Server 持久化 Service
       │
       ▼
3. Cilium Agent 监听到 Service 事件
       │
       ▼
4. LoadBalancer Controller 处理：
   a. 分配/请求 LoadBalancer IP
   b. 配置 NodePort（云厂商 LB → NodePort）
   c. 更新 cilium_nodeport_services Map
   d. 向云厂商 API 注册后端健康检查
       │
       ▼
5. 更新 Service Status（.status.loadBalancer.ingress）
       │
       ▼
6. 流量就绪：Client → LB IP → NodePort → Pod
```

### 3.3 eBPF Map 结构

```c
// cilium_load_balancer Map - 统一存储所有 LB 类型
struct lb4_key {
    __u16 proto;          // TCP/UDP
    __u16 port;           // Port
    __u32 addr;           // IP (0.0.0.0 for NodePort)
};

struct lb4_service {
    __u32 count;           // 后端数量
    __u32 backend_ids[16]; // 后端 ID 列表
    __u32 flags;           // 类型标志：NodePort/ClusterIP/LoadBalancer
};

// 扩展支持 IPv6
struct lb6_key {
    __u16 proto;
    __u16 port;
    __u8  addr[16];        // IPv6 地址
};
```

---

## 4. MetalLB 集成

### 4.1 MetalLB 概述

MetalLB 是裸金属 Kubernetes 集群的负载均衡器解决方案，为没有云厂商 LB 的环境提供 L2 和 L4 负载均衡。

**Cilium + MetalBL 组合**：

```
┌─────────────────────────────────────────────────────────────┐
│                  Cilium + MetalLB                          │
│                                                             │
│  Cilium 提供：                                              │
│  • eBPF 数据面（ClusterIP, NodePort）                       │
│  • NetworkPolicy                                            │
│  • Hubble 可观测性                                          │
│  • 跨节点 VXLAN 网络                                        │
│                                                             │
│  MetalLB 提供：                                             │
│  • LoadBalancer IP 分配（L2 模式）                          │
│  • 外部 IP 宣告                                            │
│  • 与云厂商 LB 等效的 Service 访问                          │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 安装 MetalLB

```bash
# 1. 安装 MetalLB（Layer2 模式）
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14/manifests/metallb.yaml

# 2. 配置 IP 地址池
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1alpha1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.240-192.168.1.250  # 可用 IP 范围
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF

# 3. 确保 Cilium 配置正确
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict
```

### 4.3 L2 模式工作原理

```
MetalLB Speaker (每个节点运行)
        │
        │ 选举 Leader
        ▼
┌─────────────────────────────────────────────────────────────┐
│                    Leader Speaker                          │
│                                                             │
│  监听 Service 变化                                          │
│       │                                                     │
│  当 LoadBalancer IP 需要宣告时：                            │
│       │                                                     │
│  1. GARP（Gratuitous ARP）发送                             │
│  │     "IP 192.168.1.100 在我这里"                        │
│  │                                                     │
│  2. ARP Reply 响应                                         │
│       │                                                     │
│  3. 路由器更新 ARP 表                                       │
│       │                                                     │
│  4. 流量路由到 Leader 节点                                   │
└─────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│                   Leader 节点的 Cilium                       │
│                                                             │
│  XDP 处理 NodePort 流量                                     │
│       │                                                     │
│  DNAT → Backend Pod                                        │
│       │                                                     │
│  DSR 直接返回                                               │
└─────────────────────────────────────────────────────────────┘
```

### 4.4 MetalLB + Cilium 协同配置

```yaml
# 创建 LoadBalancer Service
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    metallb.universe.tf/address-pool: default-pool
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
  externalTrafficPolicy: Local  # 保持源 IP
```

```bash
# 查看 LoadBalancer IP 分配
kubectl get svc my-app
# NAME     TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)
# my-app   LoadBalancer   10.96.0.100    192.168.1.240  80:31234/TCP

# 查看 MetalLB 状态
kubectl -n metallb-system get pods -o wide
kubectl logs -n metallb-system -l app=metallb-speaker
```

---

## 5. 云厂商 LoadBalancer 集成

### 5.1 AWS Network Load Balancer (NLB)

Cilium 与 AWS NLB 深度集成：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    # AWS NLB 配置
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
    service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: "*"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "tcp"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  ports:
  - port: 443
    targetPort: 6443
  selector:
    app: my-app
```

**AWS NLB + Cilium 架构**：

```
外部 Client
      │
      ▼
┌─────────────────┐
│   AWS NLB       │
│                 │
│  • TLS 终止     │
│  • 源 IP 保留   │
│  • 健康检查     │
└─────────────────┘
      │
      ▼ NodePort (30000-32767)
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Node                          │
│                                                             │
│  Cilium XDP (eth0)                                         │
│       │                                                     │
│  DNAT: NodePort → Backend Pod                              │
│       │                                                     │
│  DSR: Backend 直接响应 NLB                                  │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 GCP Cloud Load Balancing

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    # GCP BackendConfig（健康检查）
    cloud.google.com/backend-config: '{"ports": {"80": "my-backend"}}'
    # 预取 IP（全球 Anycast）
    networking.gke.io/pre-shared-cidrs: "203.0.113.0/24"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: my-app
```

### 5.3 Azure Load Balancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    # Azure LB SKU
    service.beta.kubernetes.io/azure-load-balancer-mode: "standard"
    # 公共 IP 资源
    service.beta.kubernetes.io/azure-pip-name: "my-publicip"
spec:
  type: LoadBalancer
  loadBalancerIP: 20.0.0.100
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: my-app
```

### 5.4 云厂商集成对比

| 云厂商 | LB 类型 | Cilium 注解 | 源 IP 保留 |
|:---|:---|:---|:---|
| **AWS** | NLB | `aws-load-balancer-type: nlb` | 是 |
| **GCP** | Cloud LB | `cloud.google.com/backend-config` | 是 |
| **Azure** | Standard LB | `azure-load-balancer-mode: standard` | 是 |
| **阿里云** | SLB | `alibaba.cloud.loadbalancerid` | 是 |

---

## 6. Cilium Cluster LoadBalancer

### 6.1 跨集群服务发布

Cilium Cluster LoadBalancer（CCN）或 Cilium Cluster-wide Network Mesh（CNCM）允许跨集群访问 Service：

```
┌─────────────────┐              ┌─────────────────┐
│   Cluster A     │              │   Cluster B     │
│                 │              │                 │
│  Pod A ────────│──────────────│── Pod B        │
│                 │   Cluster    │                 │
│  Svc: 10.96.0.1│   Mesh       │  Svc: 10.96.0.2│
└─────────────────┘              └─────────────────┘
      │                                │
      └────────── VXLAN/Geneve ────────┘
              Cilium Cluster Mesh
```

### 6.2 启用 Cluster Mesh

```bash
# 在所有集群中启用 ClusterMesh
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set clustermesh.enabled=true \
    --set clustermesh.apiserver.service.type=LoadBalancer

# 配置集群对等
cilium clustermesh connect \
    --context cluster1 \
    --destination-context cluster2
```

---

## 7. 健康检查

### 7.1 eBPF 健康检查机制

Cilium 通过 eBPF 实现分布式健康检查：

```c
// bpf/lb.c - 健康检查实现

static __always_inline int
backend_health_check(struct backend_value *backend) {
    // 1. 尝试 TCP 连接
    struct sock *sk = bpf_skc_lookup(
        0,  // 不需要元数据
        backend->addr,
        backend->port,
        IPPROTO_TCP,
        CB_ENFORCE_IDENTITY,
        0
    );

    if (!sk)
        return BACKEND_DOWN;

    // 2. 检查连接状态
    if (tcp_state_established(sk))
        return BACKEND_UP;

    return BACKEND_DOWN;
}
```

### 7.2 健康检查配置

```bash
# 配置健康检查参数
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set ebpF.lb.health检查.enabled=true \
    --set ebpF.lb.health检查.interval=10s
```

---

## 8. 验证与排错

### 8.1 查看 LoadBalancer Service

```bash
# 查看所有 LoadBalancer Service
kubectl get svc -o wide --field-selector spec.type=LoadBalancer

# 查看分配的外部 IP
kubectl get svc my-app -o jsonpath='{.status.loadBalancer.ingress}'
```

### 8.2 查看 Cilium LoadBalancer 状态

```bash
# 查看所有 LB 类型 Service
kubectl -n kube-system exec ds/cilium -- \
    cilium service list | grep -E "LoadBalancer|NodePort"

# 查看 LB 统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf lb list -v
```

### 8.3 测试 LoadBalancer 连通性

```bash
# 获取外部 IP
LB_IP=$(kubectl get svc my-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 测试连通性
curl -v http://$LB_IP:80

# 测试源 IP 保留（externalTrafficPolicy: Local）
curl -v http://$LB_IP:80 \
    -H "X-Forwarded-For: $CLIENT_IP"

# 在后端 Pod 验证源 IP
kubectl exec -it backend-pod -- \
    tcpdump -i eth0 -n | grep $CLIENT_IP
```

### 8.4 常见问题与解决

| 问题 | 原因 | 解决方法 |
|:---|:---|:---|
| LoadBalancer IP 一直 pending | MetalLB 未安装/IP 池耗尽 | 安装 MetalLB，配置 IP 池 |
| 云厂商 LB 无法连接后端 | 健康检查失败 | 检查安全组，开放 NodePort 范围 |
| 源 IP 未保留 | externalTrafficPolicy: Cluster | 改为 Local |
| 跨集群访问失败 | ClusterMesh 未配置 | 配置集群对等连接 |
| MetalLB GARP 不生效 | 交换机过滤 ARP | 使用 L4 模式替代 |

---

## 9. 章节总结

|| 模式 | 适用场景 | 特点 |
|:---|:---|:---|:---|
| **L2 (ARP/NDP)** | 裸金属、小规模 | 简单，所有流量经过 Leader |
| **L4 (DSR/XDP)** | 生产环境、高性能 | XDP 处理，源 IP 保留 |
| **L7 (HTTP)** | Web 服务、路由 | Ingress/Gateway API |
| **云厂商 NLB** | AWS/GCP/Azure | 原生集成，高可用 |
| **MetalLB** | 裸金属 | L2/L4 负载均衡 |

**Cilium LoadBalancer 优势**：

- **eBPF 加速**：NodePort/ExternalIP 均通过 XDP/TC 处理
- **DSR 原生支持**：后端直接响应，无 SNAT 开销
- **源 IP 保留**：externalTrafficPolicy: Local
- **健康检查**：分布式 eBPF 健康探测
- **云厂商集成**：与主流云 LB 无缝对接

**下一章**：ExternalIP——Cilium 如何处理绑定到节点网卡的外部 IP，实现入口路由。

---

## 参考资料

- [Cilium LoadBalancer](https://docs.cilium.io/en/stable/concepts/services/#loadbalancer)
- [MetalLB Documentation](https://metallb.universe.tf/)
- [AWS NLB + Cilium](https://docs.cilium.io/en/stable/gettingstarted/kubeproxy-free/)
- [GCP Cloud Load Balancing](https://cloud.google.com/load-balancing/docs)
- [Azure Load Balancer](https://docs.microsoft.com/en-us/azure/load-balancer/)
