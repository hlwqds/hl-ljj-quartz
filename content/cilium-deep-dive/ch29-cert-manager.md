---
title: "Cilium 深度探索 (29)：Cert-Manager 与 TLS 自动化"
date: 2026-04-14
tags:
  - cilium
  - cert-manager
  - tls
  - lets-encrypt
  - kubernetes
  - security
  - networking
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 27. [[ch27-gateway-api|第二十七章：Gateway API]] 28. [[ch28-ingress-annotations|第二十八章：Ingress 注解详解]] 29. **第二十九章：Cert-Manager 与 TLS 自动化** ←

---

## 1. Cert-Manager 概述

Cert-Manager 是 Kubernetes 中的证书管理控制器，它通过 ACME（Automated Certificate Management Environment）协议与 Let's Encrypt、ZeroSSL 等证书颁发机构集成，自动为 Ingress/Gateway 申请、更新、撤销 TLS 证书。

```
┌────────────────────────────────────────────────────────────┐
│                    Cert-Manager 架构                        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   Cert-Manager Controller             │  │
│  │                                                        │  │
│  │   ┌─────────────┐    ┌─────────────┐    ┌─────────┐  │  │
│  │   │  Issuer/    │    │  Certificate │    │  Order/ │  │  │
│  │   │  ClusterIssuer│    │   Controller  │    │  CRD   │  │  │
│  │   └──────┬──────┘    └──────┬───────┘    └────┬───┘  │  │
│  │          │                  │                  │      │  │
│  │          ▼                  ▼                  ▼      │  │
│  │   ┌─────────────────────────────────────────────────┐  │  │
│  │   │              eBPF/Secret 存储                    │  │  │
│  │   └─────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                │
│         ┌───────────────────┼───────────────────┐          │
│         │                   │                    │          │
│         ▼                   ▼                    ▼          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    │
│  │   Let's     │    │   Vault     │    │   AWS       │    │
│  │   Encrypt   │    │   PKI      │    │   Route53   │    │
│  └─────────────┘    └─────────────┘    └─────────────┘    │
└────────────────────────────────────────────────────────────┘
```

### 1.1 核心 CRD 资源

| CRD                  | 说明                         |
| :------------------- | :--------------------------- |
| `Issuer`             | 命名空间级别的证书颁发者配置 |
| `ClusterIssuer`      | 集群级别的证书颁发者配置     |
| `Certificate`        | 证书请求规范                 |
| `CertificateRequest` | 证书请求记录                 |
| `Order`              | ACME 订单（ACME 协议）       |
| `Challenge`          | ACME DNS/HTTP 验证挑战       |

---

## 2. 部署 Cert-Manager

### 2.1 通过 Helm 安装

```bash
# 添加 Jetstack Helm 仓库
helm repo add jetstack https://charts.jetstack.io
helm repo update

# 安装 cert-manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --set webhook.timeout=30s
```

### 2.2 验证安装

```bash
# 检查 Pod 状态
kubectl get pods -n cert-manager

# 检查 CRD
kubectl get crd | grep cert-manager
```

---

## 3. Issuer 配置

### 3.1 Let's Encrypt 生产环境 Issuer

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # ACME 服务器（生产环境）
    server: https://acme-v02.api.letsencrypt.org/directory
    # 管理员邮箱
    email: admin@example.com
    # 存储 ACME 账户私钥的 Secret
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    # ACME 挑战类型
    solvers:
      # HTTP-01 挑战（通过 Ingress 验证）
      - http01:
          ingress:
            class: cilium
        # DNS-01 挑战（通过 DNS 验证）
      - dns01:
          # CloudFlare DNS 验证
          cloudflare:
            email: cloud@example.com
            apiKeySecretRef:
              name: cloudflare-api-key
              key: api-key
```

### 3.2 Let's Encrypt 测试环境 Issuer

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    # ACME 服务器（测试环境，不受速率限制）
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            class: cilium
```

### 3.3 Vault PKI Issuer

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-issuer
  namespace: default
spec:
  vault:
    path: pki_int/issue/example-dot-com
    server: https://vault.internal:8200
    # Vault 认证
    auth:
      # Kubernetes ServiceAccount 认证
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager
        secretRef:
          name: cert-manager-vault-token
```

---

## 4. Certificate 资源

### 4.1 基本 Certificate 配置

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cafe-tls
  namespace: default
spec:
  # 证书 Secret 名称
  secretName: cafe-tls
  # 证书过期时间
  duration: 2160h # 90天
  # 续期提前时间
  renewBefore: 360h # 15天
  # Subject 信息
  subject:
    organizations:
      - Example Corp
    organizationalUnits:
      - Engineering
  # 要申请的域名
  dnsNames:
    - cafe.example.com
    - "*.cafe.example.com"
  # 证书颁发者
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
    group: cert-manager.io
  # 密钥算法
  privateKey:
    algorithm: ECDSA
    size: 256
```

### 4.2 带有额外配置的 Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: advanced-tls
  namespace: default
spec:
  secretName: advanced-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - api.example.com
    - admin.example.com
  # SANs（Subject Alternative Names）
  altNames:
    - ip: 10.0.0.1
    - email: admin@example.com
  # 密钥用法
  usages:
    - server auth
    - client auth
  # 续期策略
  renewBeforeExpiryDays: 30
  # 证书策略
  policy:
    issuerRef:
      name: letsencrypt-prod
    # 静脉证书吊销列表
    crlDistributionPoints:
      - "http://crl.example.com/ca.crl"
```

---

## 5. 与 Cilium Ingress 集成

### 5.1 自动 TLS 终止

Cert-Manager 与 Cilium Ingress 深度集成，自动为 Ingress 申请证书：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cafe-ingress
  annotations:
    # 启用 cert-manager 签发证书
    cert-manager.io/cluster-issuer: letsencrypt-prod
    # 或者使用 Issuer（命名空间级别）
    cert-manager.io/issuer: letsencrypt-prod
spec:
  ingressClassName: cilium
  tls:
    - hosts:
        - cafe.example.com
      # cert-manager 会自动创建此 Secret
      secretName: cafe-tls
  rules:
    - host: cafe.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cafe-backend
                port:
                  number: 80
```

### 5.2 完整示例：咖啡店 HTTPS

**1. 部署后端服务**

```yaml
# cafe-backend.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cafe-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cafe
  template:
    metadata:
      labels:
        app: cafe
    spec:
      containers:
        - name: cafe
          image: hashicorp/http-echo
          args:
            - "-text=Hello from Cafe HTTPS"
            - "-listen=:8080"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: cafe-backend
spec:
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: cafe
```

**2. 创建 Ingress（触发 cert-manager）**

```yaml
# cafe-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cafe-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    # HTTP-01 挑战使用的 Ingress Class
    cert-manager.io/ingress-shim-class: cilium
spec:
  ingressClassName: cilium
  tls:
    - hosts:
        - cafe.example.com
      secretName: cafe-tls
  rules:
    - host: cafe.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cafe-backend
                port:
                  number: 80
```

### 5.3 证书生命周期

```bash
# 查看 Certificate 状态
kubectl get certificate cafe-tls -o yaml

# 查看生成的 Secret
kubectl get secret cafe-tls -o yaml

# 查看 cert-manager 日志
kubectl logs -n cert-manager -l app=cert-manager

# 手动触发续期
kubectl cert-manager renew cafe-tls
```

---

## 6. 与 Cilium Gateway API 集成

### 6.1 Gateway TLS 配置

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cafe-gateway
  namespace: ingress
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        # 引用 cert-manager 管理的 Secret
        certificateRefs:
          - name: cafe-gateway-tls
            kind: Secret
            namespace: ingress
      allowedRoutes:
        namespaces:
          from: Same
---
# 单独创建 Certificate 资源
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cafe-gateway-tls
  namespace: ingress
spec:
  secretName: cafe-gateway-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - cafe.example.com
```

### 6.2 GatewayClass 级别的默认 TLS

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
  annotations:
    # 为所有 Gateway 设置默认 ClusterIssuer
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  controllerName: io.cilium/gateway-controller
```

---

## 7. ACME HTTP-01 挑战详解

### 7.1 挑战流程

```
┌─────────────────────────────────────────────────────────────┐
│                 ACME HTTP-01 挑战流程                         │
│                                                             │
│  1. Cert-Manager 创建 Challenge 资源                        │
│         │                                                   │
│         ▼                                                   │
│  2. ACME Server 请求 http://domain/.well-known/acme-challenge/ │
│         │                                                   │
│         ▼                                                   │
│  3. Cert-Manager 创建临时 Ingress 响应挑战                   │
│         │                                                   │
│         ▼                                                   │
│  4. Let's Encrypt 验证器访问验证 URL                         │
│         │                                                   │
│         ▼                                                   │
│  5. 验证成功，颁发证书                                       │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 挑战配置调整

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            class: cilium
          # 挑战超时配置
          config:
            ingressClass: cilium
        # 域名匹配配置
        selector:
          dnsNames:
            - "*.example.com"
            - example.com
```

---

## 8. DNS-01 挑战

### 8.1 CloudFlare DNS

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          cloudflare:
            email: cloud@example.com
            apiKeySecretRef:
              name: cloudflare-api-key
              key: api-key
            # 使用 API Token（更安全）
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

### 8.2 Route53 DNS

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-route53
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          route53:
            region: us-east-1
            # IAM Role 认证
            hostedZoneID: ZONE_ID
            # 或者使用 Access Key
            secretAccessKeySecretRef:
              name: route53-credentials
              key: secret-access-key
```

### 8.3 DNS-01 挑战的优势

| 特性           | HTTP-01        | DNS-01                |
| :------------- | :------------- | :-------------------- |
| **通配符证书** | 不支持         | 支持                  |
| **验证速度**   | 快             | 依赖 DNS 传播         |
| **适用场景**   | 公开 HTTP 服务 | 内部服务/通配符       |
| **配置复杂度** | 低             | 高（需要 DNS 提供商） |

---

## 9. 证书续期与轮换

### 9.1 续期机制

Cert-Manager 自动管理证书续期：

```
                    Certificate 续期时间线

  0天                    75天                    90天
   │                       │                       │
   ▼                       ▼                       ▼
┌──────┐              ┌─────────┐            ┌─────────┐
│ 颁发 │◀─────────────│ 续期触发 │───────────▶│  过期   │
│ 证书 │              │(15天前) │            │         │
└──────┘              └─────────┘            └─────────┘
```

### 9.2 手动续期

```bash
# 列出即将过期的证书
kubectl get certificates --all-namespaces \
  --field-selector 'status.renewalTime<$(date -d "+30 days" +%s)'

# 手动续期指定证书
kubectl cert-manager renew cafe-tls

# 强制续期（忽略续期时间）
kubectl cert-manager renew --all
```

### 9.3 续期策略配置

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cafe-tls
spec:
  renewBefore: 720h # 30天前续期
  # 续期策略
  renewalSchedule: "0 0 * * *" # 每天午夜尝试
```

---

## 10. 故障排除

### 10.1 常见问题

| 问题                                        | 可能原因               | 解决方案              |
| :------------------------------------------ | :--------------------- | :-------------------- |
| `Waiting for HTTP-01 challenge propagation` | Ingress 未正确响应     | 检查 Ingress 配置     |
| `invalid challenge`                         | 域名未正确配置         | 确认 DNS 记录         |
| `connection refused`                        | Let's Encrypt 无法访问 | 检查防火墙规则        |
| `rate limited`                              | 请求过于频繁           | 改用 staging 环境测试 |

### 10.2 调试命令

```bash
# 查看 Challenge 状态
kubectl get challenge -A

# 查看 Challenge 详情
kubectl describe challenge -n default

# 查看 CertificateRequest
kubectl get certificaterequest -A

# 查看 cert-manager Controller 日志
kubectl logs -n cert-manager -l app=cert-manager --tail=100

# 检查 ACME 账户状态
kubectl get acmeaccount -A
```

### 10.3 HTTP-01 挑战调试

```bash
# 手动验证挑战
curl -I http://cafe.example.com/.well-known/acme-challenge/test-token

# 查看 cert-manager 创建的挑战 Ingress
kubectl get ingress -n cert-manager-dns01-solver

# 查看挑战 Secret
kubectl get secret -n cert-manager | grep acme
```

---

## 11. 高级配置

### 11.1 自定义证书参数

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: custom-tls
spec:
  secretName: custom-tls
  issuerRef:
    name: my-ca-issuer
    kind: Issuer
  commonName: example.com
  dnsNames:
    - example.com
    - "*.example.com"
  # 自定义 OID
  subject:
    countries:
      - US
    provinces:
      - California
    localities:
      - San Francisco
    postalCodes:
      - "94105"
  # CA 约束
  isCA: false
  # 额外配置
  encodeUsagesInRequest: true
```

### 11.2 多域名证书

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: multi-domain-tls
spec:
  secretName: multi-domain-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - cafe.example.com
    - api.example.com
    - admin.example.com
    - "*.example.com"
```

### 11.3 静脉证书

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: internal-tls
spec:
  secretName: internal-tls
  issuerRef:
    name: vault-issuer
    kind: Issuer
  commonName: internal.example.com
  dnsNames:
    - internal.example.com
    - "*.internal.example.com"
  usages:
    - server auth
    - client auth
```

---

## 12. 安全最佳实践

### 12.1 密钥管理

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: secure-tls
spec:
  secretName: secure-tls
  issuerRef:
    name: letsencrypt-prod
  # 使用强加密算法
  privateKey:
    algorithm: ECDSA
    size: 384 # P-384
  # 限制 Secret 使用
  secretTemplate:
    labels:
      app: cafe
      environment: production
    annotations:
      description: "Cafe production TLS certificate"
```

### 12.2 定期轮换

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rotated-tls
spec:
  secretName: rotated-tls
  # 短有效期，提高安全性
  duration: 168h # 7天
  renewBefore: 24h # 1天前续期
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - secure.example.com
```

---

## 13. 监控与告警

### 13.1 Prometheus 指标

```bash
# cert-manager 暴露的指标
kubectl get svc -n cert-manager cert-manager -o yaml

# 关键指标
# - certmanager_certificate_expiration_timestamp_seconds
# - certmanager_certificate_renewal_timestamp_seconds
# - certmanager_http_acme_client_requests
```

### 13.2 Alertmanager 告警配置

```yaml
# 证书即将过期告警
groups:
  - name: cert-manager
    rules:
      - alert: CertificateExpiringSoon
        expr: |
          certmanager_certificate_expiration_timestamp_seconds - time() < 604800  # 7天
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Certificate expiring soon"
          description: "Certificate {{ $labels.namespace }}/{{ $labels.name }} expires in {{ $value | humanizeDuration }}"
```

---

## 14. 总结

本章介绍了 Cert-Manager 与 Cilium Ingress/Gateway API 的集成：

**核心要点**：

- Cert-Manager 通过 ACME 协议自动管理 TLS 证书
- 支持 HTTP-01 和 DNS-01 两种验证方式
- Certificate CRD 声明式管理证书生命周期
- Cilium Ingress 通过注解自动触发证书签发
- Gateway API 通过 Secret 引用 cert-manager 管理的证书

**部署检查清单**：

- [ ] 安装 cert-manager CRD
- [ ] 配置 ClusterIssuer（Let's Encrypt 或 Vault）
- [ ] 为 Ingress 添加 `cert-manager.io/cluster-issuer` 注解
- [ ] 验证证书自动签发和续期

**下一章**：多租户隔离，Tenant 级别的网络策略和资源管理。
