---
title: "Cilium 深度探索 (9)：ExternalIP 与入口流量"
date: 2026-04-14
tags:
  - cilium
  - externalip
  - ingress
  - gateway-api
  - sk-lookup
  - ebpf
  - kubernetes
  - networking
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]
> 6. [[2026-04-14-cilium-deep-dive-ch6-clusterip|第六章：ClusterIP]]
> 7. [[2026-04-14-cilium-deep-dive-ch7-nodeport|第七章：NodePort]]
> 8. [[2026-04-14-cilium-deep-dive-ch8-loadbalancer|第八章：LoadBalancer]]
> 9. **第九章：ExternalIP** ←

---

## 1. ExternalIP 概述

ExternalIP 是 Kubernetes Service 的一种特殊类型，允许将**任意 IP 地址**（通常是数据中心内部的 IP）绑定到 Service，作为访问入口：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: ClusterIP # 通常是 ClusterIP 或 NodePort
  externalIPs:
    - 192.168.1.100 # 绑定到节点网卡的 IP
    - 192.168.1.101
  ports:
    - port: 80
      targetPort: 8080
```

**ExternalIP 的典型使用场景**：

1. **数据中心入口**：公司内部 IP 作为服务入口
2. **遗留系统迁移**：保持原有 IP 不变
3. **多网络接口**：Pod 通过特定网卡访问
4. **Ingress Controller**：绑定 VIP 到特定服务

### 1.1 ExternalIP vs LoadBalancer

| 特性         | ExternalIP        | LoadBalancer            |
| :----------- | :---------------- | :---------------------- |
| **IP 来源**  | 手动指定/预先分配 | 云厂商/MetalLB 动态分配 |
| **网络位置** | 绑定到节点网卡    | 通过 LB 转发            |
| **依赖**     | 静态路由          | 云厂商 LB 或 MetalLB    |
| **规模**     | 有限（手动管理）  | 可扩展                  |
| **高可用**   | 依赖外部路由      | 原生 HA                 |

---

## 2. ExternalIP 路由机制

### 2.1 内核路由原理

在 Linux 中，当数据包的目标 IP 是节点的网卡 IP 时：

```
Client → 192.168.1.100 (ExternalIP)
         │
         ▼
┌─────────────────────────────────────┐
│         节点 eth0 网卡               │
│                                     │
│  正常路由流程：                      │
│  1. Linux 路由表查找 192.168.1.100 │
│  2. 匹配 local 子网路由              │
│  3. 发送到 local 进程监听端口        │
│  4.kube-proxy iptables 转发         │
└─────────────────────────────────────┘
```

**问题**：传统 kube-proxy 通过 iptables 处理，O(n) 查找，性能差。

### 2.2 Cilium sk_lookup Hook

Cilium 使用 **sk_lookup eBPF hook** 在连接建立时就进行重定向，绕过内核协议栈：

```
┌─────────────────────────────────────────────────────────────┐
│                 sk_lookup Hook 工作原理                      │
│                                                             │
│  应用调用 connect()                                         │
│       │                                                    │
│       ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │           BPF sk_lookup Hook                        │   │
│  │                                                      │   │
│  │  • 在 bind()/connect() 时触发                        │   │
│  │  • 检查目标 IP:Port 是否匹配 Service                 │   │
│  │  • 直接重定向到后端 Pod（无需经过 iptables）         │   │
│  │  • 绕过内核协议栈，直接建立连接                       │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                    │
│       ▼                                                    │
│  Socket 直接连接到 Backend Pod                              │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 cilium_external_ip Map

```c
// bpf/lib/lb.h - ExternalIP Map 结构

struct external_ip_key {
    __u32 addr;         // ExternalIP 地址
    __u16 port;         // Port
    __u8  proto;        // TCP/UDP
    __u8  pad;
};

struct external_ip_value {
    __u32 backend_count;
    __u32 backend_ids[16];
    __u32 flags;
    __u32 src_range_len;
    __u32 src_range[2];
};
```

---

## 3. ExternalIP 处理流程

### 3.1 流量进入路径

```
外部 Client
      │
      │ 1. TCP SYN (dst: 192.168.1.100:80)
      ▼
┌─────────────────────────────────────────────────────────────┐
│                      节点 eth0                               │
│                                                             │
│  正常接收，发送到内核协议栈                                   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Linux 内核协议栈                         │   │
│  │                                                      │   │
│  │  路由查找 → local 子网 → 发送到 local socket         │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              kube-proxy (iptables)                   │   │
│  │                                                      │   │
│  │  匹配 KUBE-EXTERNAL-SERVICES                        │   │
│  │  DNAT → Backend Pod                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│                   Backend Pod                               │
└─────────────────────────────────────────────────────────────┘

OR (with Cilium sk_lookup):

┌─────────────────────────────────────────────────────────────┐
│                      节点 eth0                               │
│                                                             │
│  XDP/TC Hook (cilium_egress / cilium_ingress)             │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              cilium_external_ip Map                  │   │
│  │                                                      │   │
│  │  查找 192.168.1.100:80 → Backend ID                │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  eBPF 直接重定向 → Backend Pod (DSR)                       │
│                         │                                   │
│                         ▼                                   │
│  Backend Pod 直接响应 Client                                │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 sk_lookup 程序示例

```c
// bpf/sk_lookup.c（简化）

#include <linux/bpf.h>
#include <linux/tcp.h>
#include <netinet/in.h>

#include "lib/common.h"
#include "lib/drop.h"
#include "lib/lb.h"

// sk_lookup 入口
SEC("sk_lookup")
int cilium_sk_lookup(struct bpf_sk_lookup *ctx) {
    struct sock *sk = ctx->sk;
    struct dst_entry *dst = ctx->dst;
    __u32 saddr = dst->rt_spec;
    __u16 sport = dst->rt_sport;

    // 查找 external_ip service
    struct bpf_map *external_ip_map =
        bpf_map_lookup_indirect(&cilium_external_ip_map, 0);

    struct external_ip_key key = {
        .addr = bpf_ntohl(ctx->address),
        .port = bpf_ntohs(ctx->port),
        .proto = IPPROTO_TCP,
    };

    struct external_ip_value *val;
    val = bpf_map_lookup_elem(external_ip_map, &key);

    if (val) {
        // 找到 ExternalIP Service
        __u32 backend_id = select_backend(val);
        struct backend_value *backend;
        backend = bpf_map_lookup_elem(&cilium_backends, &backend_id);

        if (backend) {
            // 重定向到后端
            ctx->new_saddr = backend->addr;
            ctx->new_dport = backend->port;
            return SK_LOOKUP_REDIRECT;
        }
    }

    return SK_LOOKUP_PASS;  // 不匹配，交给默认处理
}
```

---

## 4. Cilium Ingress

### 4.1 Ingress 概述

Ingress 是 Kubernetes 提供 HTTP/HTTPS 访问 Service 的标准方式：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    kubernetes.io/ingress.class: cilium
spec:
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: my-api
                port:
                  number: 80
          - path: /web
            pathType: Prefix
            backend:
              service:
                name: my-web
                port:
                  number: 80
```

### 4.2 Cilium Ingress Controller

Cilium Ingress 基于 **Envoy** 实现，提供 L7 负载均衡和高级路由：

```
┌─────────────────────────────────────────────────────────────┐
│                   Cilium Ingress 架构                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Envoy Sidecar/Proxy                     │   │
│  │                                                      │   │
│  │  • HTTP/HTTPS 路由                                   │   │
│  │  • TLS 终止                                          │   │
│  │  • L7 策略执行                                        │   │
│  │  • 流量分割 / 镜像                                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                         ↑                                   │
│                         │                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Cilium eBPF (L4)                        │   │
│  │                                                      │   │
│  │  • NodePort 接收外部流量                             │   │
│  │  • 转发到 Envoy                                     │   │
│  │  • DSR 支持                                          │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 启用 Cilium Ingress

```bash
# 通过 Helm 启用 Ingress
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ingressController.enabled=true \
    --set ingressController.loadBalancerMode=dedicated

# 或者通过 ConfigMap
kubectl edit configmap cilium-config -n kube-system
```

```yaml
# annotations 配置
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    # Cilium Ingress 特定配置
    cilium.io/ingress.loadbalancer-mode: "dedicated" # 专用 LB
    cilium.io/ingress.backend-protocol: "HTTP" # 后端协议
    cilium.io/ingress.tls: "off" # TLS 配置
spec:
  ingressClassName: cilium
  rules:
    - host: myapp.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

---

## 5. Gateway API

### 5.1 Gateway API 概述

Gateway API 是 Kubernetes 下一代替代 Ingress 的标准，提供更丰富的角色和语义：

```yaml
# GatewayClass - 定义网关类型
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller

---
# Gateway - 创建网关
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: my-cert
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All

---
# HTTPRoute - 路由规则
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-route
spec:
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: my-api
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /web
      backendRefs:
        - name: my-web
          port: 80
```

### 5.2 Cilium Gateway API 支持

Cilium Gateway API 是**生产级实现**，支持：

| 功能              | 支持 | 说明                         |
| :---------------- | :--- | :--------------------------- |
| HTTP Routing      | ✅   | Path/Header/Method 匹配      |
| HTTPS + TLS       | ✅   | 证书管理，Let's Encrypt 集成 |
| TCP/UDP           | ✅   | 非 HTTP 协议                 |
| Traffic Splitting | ✅   | 权重基础流量分割             |
| Header 修改       | ✅   | 添加/移除/修改请求头         |
| Rate Limiting     | ✅   | 基于规则的限流               |
| mTLS              | ✅   | 双向 TLS（via CiliumPolicy） |

### 5.3 Cilium Gateway API 配置

```bash
# 启用 Gateway API
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set gatewayAPI.enabled=true
```

```yaml
# 完整的 Gateway API 配置示例
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cilium-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: my-tls-secret
      allowedRoutes:
        namespaces:
          from: All

---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
spec:
  parentRefs:
    - name: cilium-gateway
  hostnames:
    - "myapp.example.com"
  rules:
    # 流量分割
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: my-app-v1
          port: 80
          weight: 90
        - name: my-app-canary
          port: 80
          weight: 10
```

---

## 6. ExternalIP 与 NetworkPolicy

### 6.1 ExternalIP 的安全风险

ExternalIP 可以绕过正常的安全边界，攻击者可能：

1. 创建 ExternalIP Service，劫持集群入口流量
2. 通过 ExternalIP 访问集群内部服务
3. 利用 ExternalIP 绕过 NetworkPolicy

### 6.2 Cilium 的 ExternalIP 控制

Cilium 通过 **CiliumNetworkPolicy** 控制 ExternalIP 访问：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: restrict-externalip
spec:
  endpointSelector:
    matchLabels:
      app: my-app
  ingress:
    # 允许来自 ExternalIP 的流量
    - fromEntities:
        - remote-node
    # 或者基于 IP CIDR
    - fromCIDR:
        - 192.168.1.0/24
    # 拒绝其他 ExternalIP
    - toPorts:
        - ports:
            - port: "80"
              protocol: TCP
```

### 6.3 限制 ExternalIP 使用

```bash
# Kubernetes RBAC 限制谁能创建 ExternalIP Service
kubectl edit clusterrole system::node-proxier

# 仅允许 admin 创建 externalIPs
kubectl auth can-i create service/externalIP --as=system:serviceaccount:default:default
```

---

## 7. 验证与排错

### 7.1 查看 ExternalIP Service

```bash
# 查看所有带 ExternalIP 的 Service
kubectl get svc -o wide | grep -v "^NAME" | awk '{if($3=="ClusterIP" && $5!="<none>") print}'

# 或者
kubectl get svc -o jsonpath='
  {.items[?(@.spec.externalIPs)]}' | jq
```

### 7.2 查看 Cilium ExternalIP 配置

```bash
# 查看 external_ip Map
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf lb list | grep -E "external|EXTERNAL"

# 查看 Ingress 状态
kubectl get ingress
kubectl describe ingress my-app-ingress

# 查看 Gateway
kubectl get gateway
kubectl get httproute
```

### 7.3 测试 ExternalIP 访问

```bash
# 获取 ExternalIP
EXTERNAL_IP=$(kubectl get svc my-app -o jsonpath='{.spec.externalIPs[0]}')

# 测试访问
curl -v http://$EXTERNAL_IP:80

# 验证流量通过 Cilium
kubectl -n kube-system exec ds/cilium -- \
    cilium monitor --type l7 -v
```

### 7.4 常见问题与解决

| 问题                      | 原因            | 解决方法            |
| :------------------------ | :-------------- | :------------------ |
| ExternalIP 无法访问       | 路由未配置      | 配置静态路由或 BGP  |
| sk_lookup 不生效          | 内核版本不支持  | 升级内核至 5.10+    |
| Ingress 404               | 路由规则错误    | 检查 HTTPRoute 配置 |
| TLS 证书错误              | 证书未正确引用  | 检查 Secret 和证书  |
| Gateway 不 Ready          | 监听端口冲突    | 检查端口占用        |
| ExternalIP 流量绕过了策略 | eBPF 程序未加载 | 重启 cilium-agent   |

---

## 8. 章节总结

|                    | 主题                       | 关键点                      |
| :----------------- | :------------------------- | :-------------------------- |
| **ExternalIP**     | 绑定任意 IP 到 Service     | 绕过 LoadBalancer，直接路由 |
| **sk_lookup Hook** | 连接建立时重定向           | eBPF 在 bind/connect 时处理 |
| **Cilium Ingress** | Envoy-based L7 Ingress     | TLS 终止、路由、L7 策略     |
| **Gateway API**    | 标准 Kubernetes Ingress    | 角色分离、声明式路由        |
| **安全控制**       | ExternalIP + NetworkPolicy | 限制 ExternalIP 访问        |

**ExternalIP + Ingress 组合**：

```
外部 Client
      │
      │ 1. HTTPS → Ingress IP (ExternalIP)
      ▼
┌─────────────────────────────────────────────────────────────┐
│                      节点 eth0                               │
│                                                             │
│  Cilium eBPF (sk_lookup)                                    │
│  │ 匹配 ExternalIP:443 → Ingress Controller                 │
│  ▼                                                          │
│  Envoy (TLS 终止)                                            │
│  │ URL 路由 /api/* → my-api Service                        │
│  │ /web/* → my-web Service                                 │
│  ▼                                                          │
│  ClusterIP (eBPF) → Backend Pod                             │
└─────────────────────────────────────────────────────────────┘
```

**下一章**：VXLAN——Cilium Overlay 网络实现，跨节点 Pod 通信原理。

---

## 参考资料

- [Cilium ExternalIP](https://docs.cilium.io/en/stable/concepts/services/#externalips)
- [Cilium Ingress](https://docs.cilium.io/en/stable/concepts/ingress/)
- [Cilium Gateway API](https://docs.cilium.io/en/stable/concepts/gateway-api/)
- [sk_lookup BPF Hook](https://www.kernel.org/doc/html/latest/networking/sk_lookup.html)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
