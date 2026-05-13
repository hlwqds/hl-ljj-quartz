---
title: "Cilium 深度探索 (14)：DNS 策略与 FQDN 控制"
date: 2026-04-14
tags:
  - cilium
  - dns
  - fqdn
  - egress
  - networkpolicy
  - ebpf
  - kubernetes
  - security
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
> 8. [[2026-04-14-cilium-deep-dive-ch8-loadbalancer|第八章：LoadBalancer]]
> 9. [[2026-04-14-cilium-deep-dive-ch9-externalip|第九章：ExternalIP]]
> 10. [[2026-04-14-cilium-deep-dive-ch10-vxlan|第十章：VXLAN]]
> 11. [[2026-04-14-cilium-deep-dive-ch11-cnp|第十一章：CiliumNetworkPolicy]]
> 12. [[2026-04-14-cilium-deep-dive-ch12-networkpolicy|第十二章：NetworkPolicy]]
> 13. [[2026-04-14-cilium-deep-dive-ch13-layer7|第十三章：L7 策略]]
> 14. **第十四章：DNS 策略** ←

---

## 1. DNS 策略概述

DNS 策略是 Cilium 网络策略的重要组成部分，控制 Pod 的 DNS 域名解析行为。通过 DNS 策略，可以实现：

- **出口流量分段**：基于 FQDN（完全限定域名）控制出口流量
- **防止数据泄露**：阻止 Pod 解析恶意域名
- **微服务隔离**：限制只能访问授权的外部服务
- **审计追踪**：记录 DNS 查询用于安全分析

```yaml
# DNS 策略示例
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-egress-policy
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "*.example.com"      # 允许访问 *.example.com
        - matchPattern: "api.internal.net"   # 允许访问内部 API
        - matchPattern: "kubernetes.default" # 允许 K8s API
```

### 1.1 DNS 策略工作原理

```
┌─────────────────────────────────────────────────────────────┐
│                 DNS 策略工作流程                             │
│                                                             │
│  Pod 发起 DNS 查询                                          │
│       │                                                    │
│       ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            eBPF DNS 代理 (Cilium Agent)             │   │
│  │                                                      │   │
│  │  1. 拦截 DNS 查询                                     │   │
│  │  2. 检查目标域名是否匹配 FQDN 规则                   │   │
│  │  3. 匹配 → 允许，解析 IP                             │   │
│  │  4. 不匹配 → 拒绝，返回 NXDOMAIN                     │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                    │
│       ▼                                                    │
│  允许的域名 → 执行实际 DNS 查询                             │
│  拒绝的域名 → 返回错误                                     │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 DNS 策略 vs 传统出口策略

| 特性 | IP 级别出口策略 | DNS 策略 |
|:---|:---|:---|
| **匹配依据** | 固定 IP | 域名（动态 IP） |
| **灵活性** | 静态 | 动态 DNS 响应 |
| **管理复杂度** | 高（需要维护 IP 列表） | 低（基于域名） |
| **云环境适配** | 差（IP 可能变化） | 好（域名不变） |
| **数据泄露防护** | 有限 | 完整 |

---

## 2. FQDN 策略配置

### 2.1 matchPattern 语法

FQDN 策略使用 `matchPattern` 进行域名匹配，支持通配符：

```yaml
# matchPattern 匹配规则
dns:
# 精确匹配
- matchPattern: "api.example.com"

# 单级通配符 (*.example.com)
- matchPattern: "*.example.com"
# 匹配：api.example.com, www.example.com, docs.example.com
# 不匹配：foo.bar.example.com

# 多级通配符 (**.example.com 或 *.api.example.com)
- matchPattern: "*.api.example.com"
# 匹配：v1.api.example.com, v2.api.example.com
# 不匹配：example.com 本身

# 前缀匹配（以特定字符串开头）
- matchPattern: "github.*"
# 匹配：github.com, github.io, githubusercontent.com
```

### 2.2 基本 FQDN 策略

```yaml
# 允许访问特定域名
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-specific-domains
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        # 允许访问 Google API
        - matchPattern: "*.googleapis.com"
        # 允许访问 AWS S3
        - matchPattern: "*.s3.amazonaws.com"
        # 允许访问 GitHub
        - matchPattern: "github.com"
        - matchPattern: "*.github.com"
```

### 2.3 Kubernetes 内部域名

```yaml
# 访问 Kubernetes 内部服务
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: k8s-internal-dns
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
  # 允许访问 Kubernetes API
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        # ClusterIP Service
        - matchPattern: "*.svc.cluster.local"
        # kube-dns
        - matchPattern: "kubernetes.default"
        - matchPattern: "kubernetes.default.svc.cluster.local"
        # 特定 Service
        - matchPattern: "api-server.default.svc.cluster.local"
        - matchPattern: "postgres.database.svc.cluster.local"
```

---

## 3. DNS 劫持机制

### 3.1 Cilium DNS 劫持原理

Cilium 通过 eBPF 在 **Tproxy 模式**下拦截出口 DNS 流量，实现 DNS 策略执行：

```
┌─────────────────────────────────────────────────────────────┐
│                 DNS 劫持流程                                │
│                                                             │
│  Pod 发起 DNS 查询 (example.com)                           │
│       │                                                    │
│       ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            eBPF Hook (TC/connect4)                  │   │
│  │                                                      │   │
│  │  检测到目标端口 53 → 重定向到 DNS 代理                │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                    │
│       ▼                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Cilium DNS 代理 (本地进程)                 │   │
│  │                                                      │   │
│  │  1. 检查域名是否匹配 FQDN 规则                        │   │
│  │  2. 匹配 → 转发到上游 DNS                            │   │
│  │  3. 不匹配 → 返回 NXDOMAIN                           │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                    │
│       ▼                                                    │
│  响应返回给 Pod                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 DNS 响应处理

```yaml
# DNS 策略会缓存域名→IP 映射
# 后续访问该 IP 时，eBPF 检查是否来自授权域名
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-with-ip-caching
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "*.example.com"
```

**工作流程**：

1. Pod 查询 `api.example.com` → DNS 策略检查通过
2. Cilium DNS 代理转发到上游 DNS
3. 获取 IP `93.184.216.34`
4. 缓存 `api.example.com` → `93.184.216.34`
5. Pod 访问 `93.184.216.34:443`
6. eBPF 检查该 IP 是否来自授权域名
7. 匹配 → 允许访问

---

## 4. FQDN 出口策略

### 4.1 基础出口控制

```yaml
# 限制出口访问只允许特定域名
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: restricted-egress
spec:
  endpointSelector:
    matchLabels:
      app: restricted-app
  egress:
  # DNS 规则：只允许特定域名解析
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "*.internal.corp"
        - matchPattern: "api.partner.com"
        - matchPattern: "storage.googleapis.com"
  
  # 除了 DNS，还需要允许实际流量
  - toCidrs:
    - "0.0.0.0/0"
    # 需要配合 IP 规则限制
```

### 4.2 完整出口策略示例

```yaml
# 完整出口策略：DNS + IP
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: complete-egress-policy
spec:
  endpointSelector:
    matchLabels:
      app: microservice
  egress:
  # 规则1: DNS 查询（必须）
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        # 内部服务
        - matchPattern: "*.svc.cluster.local"
        - matchPattern: "kubernetes.default"
        # 合作伙伴 API
        - matchPattern: "*.partner-api.io"
        # 云服务
        - matchPattern: "*.s3.amazonaws.com"
        - matchPattern: "*.storage.googleapis.com"
        - matchPattern: "auth0.com"
  
  # 规则2: 允许解析的 IP 访问
  # Cilium 会自动将 DNS 规则转换为 IP 规则
  # 无需手动配置
```

### 4.3 多级域名控制

```yaml
# 精细化多级域名控制
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: multi-level-fqdn
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        # 允许所有 *.com 域名
        - matchPattern: "*.com"
        # 但排除某些域名
        - matchPattern: "!example.com"
        - matchPattern: "!*.example.com"
```

---

## 5. 基于 DNS 的网络分段

### 5.1 微服务出口分段

```yaml
# 微服务只能访问授权的后端服务
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: microservice-segmentation
spec:
  endpointSelector:
    matchLabels:
      app: order-service
  egress:
  # 允许访问用户服务
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "user-service.*"
        - matchPattern: "user-service.default.svc.cluster.local"
  
  # 允许访问产品目录服务
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "catalog-service.*"
  
  # 允许访问支付服务
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "payment-service.*"
  
  # 允许访问数据库
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "postgres.database.svc.cluster.local"
  
  # 允许 DNS
  - toPorts:
    - port: "53"
      protocol: UDP
    toEndpoints:
    - matchLabels:
        k8s-app: kube-dns
```

### 5.2 防止数据泄露

```yaml
# 防止敏感数据外泄
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: data-exfiltration-prevention
spec:
  endpointSelector:
    matchLabels:
      app: secure-app
  egress:
  # 只允许访问已知的白名单域名
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        # 内部服务
        - matchPattern: "*.internal.corp"
        # 已批准的云服务
        - matchPattern: "*.office365.com"
        - matchPattern: "*.microsoftonline.com"
        
  # 显式拒绝其他所有出口
  - toCidrs:
    - "0.0.0.0/0"
    # 这将阻止所有其他 IP 流量
```

### 5.3 开发/生产环境隔离

```yaml
# 生产环境严格出口策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: production-egress-policy
spec:
  endpointSelector:
    matchLabels:
      app: production-app
      environment: production
  egress:
  # 只允许内部服务
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "*.prod.svc.cluster.local"
        - matchPattern: "*.svc.cluster.local"
        - matchPattern: "kubernetes.default"
  
  # 外部 API（白名单）
  - toPorts:
    - port: "443"
      protocol: TCP
      rules:
        dns:
        - matchPattern: "api.stripe.com"
        - matchPattern: "*.pagerduty.com"
```

---

## 6. DNS 策略与 IP 规则的转换

### 6.1 自动转换机制

Cilium 自动将 FQDN 规则转换为 IP 规则：

```
┌─────────────────────────────────────────────────────────────┐
│              FQDN → IP 自动转换                               │
│                                                             │
│  FQDN 规则:                                                 │
│    matchPattern: "*.example.com"                            │
│       │                                                    │
│       ▼                                                    │
│  DNS 查询 (运行时):                                         │
│    *.example.com → [93.184.216.34, 93.184.216.35]          │
│       │                                                    │
│       ▼                                                    │
│  IP 规则 (自动生成):                                        │
│    toCidrs: ["93.184.216.34/32", "93.184.216.35/32"]        │
│       │                                                    │
│       ▼                                                    │
│  eBPF Map 存储:                                             │
│    DNS cache: example.com → {93.184.216.34, 93.184.216.35}  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 DNS 缓存机制

```bash
# 查看 DNS 缓存
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn cache list

# 查看特定域名的 IP 解析
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn cache list | grep example.com

# 清除 DNS 缓存
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn cache delete example.com

# 查看 FQDN 策略状态
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn policy
```

### 6.3 动态 IP 更新

```yaml
# DNS 策略支持动态 IP 更新
# 当域名 IP 变化时，Cilium 自动更新 eBPF 规则
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dynamic-fqdn
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
  - toPorts:
    - port: "443"
      protocol: TCP
      rules:
        dns:
        - matchPattern: "api.example.com"
        # Cilium 会自动跟踪 IP 变化
```

---

## 7. 递归 DNS 查询

### 7.1 上游 DNS 配置

```yaml
# 配置上游 DNS 服务器
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: upstream-dns
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "*"
          # 允许所有域名解析
          # 使用系统配置的 DNS 服务器
```

### 7.2 指定上游 DNS

```bash
# 在 Cilium ConfigMap 中配置上游 DNS
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  # 替换 DNS 服务器
  fqdn-regexp-limiter: ""     # 限制并发 regex 数量
  max-controller-interval: "5" # 最大重同步间隔
```

### 7.3 DNS 查询流程

```
┌─────────────────────────────────────────────────────────────┐
│                 递归 DNS 查询流程                            │
│                                                             │
│  Pod 查询 api.example.com                                   │
│       │                                                    │
│       ▼                                                    │
│  Cilium DNS 代理接收请求                                     │
│       │                                                    │
│       ▼                                                    │
│  检查 FQDN 策略规则                                         │
│       │                                                    │
│       ▼                                                    │
│  匹配 → 转发到上游 DNS (CoreDNS)                           │
│       │                                                    │
│       ▼                                                    │
│  上游 DNS 递归查询 → 返回 IP                                │
│       │                                                    │
│       ▼                                                    │
│  缓存 IP → FQDN 映射                                        │
│       │                                                    │
│       ▼                                                    │
│  返回 IP 给 Pod                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 8. 实际应用示例

### 8.1 Web 应用出口策略

```yaml
# Web 应用：只允许访问已知的外部 API
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-app-egress
spec:
  endpointSelector:
    matchLabels:
      app: web-frontend
  egress:
  # DNS 查询
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        # 内部 K8s 服务
        - matchPattern: "*.svc.cluster.local"
        - matchPattern: "kubernetes.default"
        # 外部 API（白名单）
        - matchPattern: "api.stripe.com"
        - matchPattern: "*.auth0.com"
        - matchPattern: "cdn.jsdelivr.net"
        - matchPattern: "fonts.googleapis.com"
        - matchPattern: "*.googleapis.com"
```

### 8.2 数据库只读副本访问

```yaml
# 数据库客户端出口策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: database-client-egress
spec:
  endpointSelector:
    matchLabels:
      app: database-client
  egress:
  # DNS 查询（只允许数据库域名）
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "postgres-primary.database.svc.cluster.local"
        - matchPattern: "postgres-replica.database.svc.cluster.local"
  
  # 数据库端口
  - toPorts:
    - port: "5432"
      protocol: TCP
    toEndpoints:
    - matchLabels:
        app: postgres
```

### 8.3 CI/CD 部署策略

```yaml
# CI/CD Runner 出口策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: cicd-runner-egress
spec:
  endpointSelector:
    matchLabels:
      app: cicd-runner
  egress:
  # DNS
  - toPorts:
    - port: "53"
      protocol: UDP
      rules:
        dns:
        - matchPattern: "registry-*.docker.io"
        - matchPattern: "ghcr.io"
        - matchPattern: "*.github.com"
        - matchPattern: "*.githubusercontent.com"
        - matchPattern: "kubernetes.default"
  
  # Docker Registry
  - toPorts:
    - port: "443"
      protocol: TCP
      rules:
        dns:
        - matchPattern: "*.docker.io"
        - matchPattern: "ghcr.io"
  
  # Git
  - toPorts:
    - port: "22"
      protocol: TCP
    toCidrs:
    - "0.0.0.0/0"
    # 限制特定 IP 范围更好
```

---

## 9. 监控与故障排除

### 9.1 Hubble DNS 监控

```bash
# 查看 DNS 查询
hubble observe --type l7 --protocol dns

# 查看被拒绝的 DNS 查询
hubble observe --type drop --protocol dns

# 查看特定 Pod 的 DNS 查询
hubble observe --from-label app=webserver --type l7 --protocol dns

# 实时 DNS 查询流
hubble observe --follow --protocol dns
```

### 9.2 FQDN 策略调试

```bash
# 查看 FQDN 策略状态
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn policy

# 查看 DNS 缓存统计
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn cache stats

# 查看活跃的 FQDN 规则
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn cache list

# 测试域名是否被允许
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbgfqdn match pattern "api.example.com" to-port 53
```

### 9.3 常见问题

```bash
# 问题1: DNS 查询被拒绝
# 原因: 域名不在白名单中
# 解决: 添加对应的 matchPattern

# 问题2: DNS 解析成功但连接被拒绝
# 原因: FQDN 规则正确但 IP 规则缺失
# 解决: 确保 DNS 规则存在且包含目标端口

# 问题3: DNS 缓存导致策略不即时生效
# 解决: 
#    kubectl -n kube-system exec ds/cilium -- \
#        cilium-dbgfqdn cache delete <domain>

# 问题4: 性能问题
# 解决: 减少正则表达式复杂性，使用固定域名而非通配符
```

---

## 10. 总结

DNS 策略是 Cilium 出口流量控制的核心：

| 功能 | 说明 |
|:---|:---|
| **FQDN 匹配** | 支持通配符和精确匹配 |
| **DNS 劫持** | eBPF 拦截 DNS 查询并执行策略 |
| **动态 IP 转换** | 自动将域名转换为 IP 规则 |
| **缓存管理** | 维护域名→IP 映射缓存 |
| **L7 检测** | 基于域名的细粒度出口控制 |

DNS 策略使得**基于域名而非 IP** 的出口控制成为可能，大大简化了云原生环境中的网络安全策略管理。
