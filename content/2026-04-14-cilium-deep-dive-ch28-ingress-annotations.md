---
title: "Cilium 深度探索 (28)：Ingress 注解详解"
date: 2026-04-14
tags:
  - cilium
  - ingress
  - annotations
  - traffic-shaping
  - cors
  - rate-limiting
  - kubernetes
  - networking
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ...
> 26. [[2026-04-14-cilium-deep-dive-ch26-ingress|第二十六章：Cilium Ingress Controller]]
> 27. [[2026-04-14-cilium-deep-dive-ch27-gateway-api|第二十七章：Gateway API]]
> 28. **第二十八章：Ingress 注解详解** ←

---

## 1. 注解概述

Cilium Ingress 通过注解（Annotations）提供丰富的流量管理功能。注解直接附加在 Ingress 资源上，无需额外的 CRD 或配置，即可实现流量分割、CORS、限速、重写等高级功能。

### 1.1 注解分类

| 类别 | 注解前缀 | 功能 |
|:---|:---|:---|
| 流量管理 | `cilium.io/ingress-` | 流量分割、负载均衡、会话亲和 |
| TLS 配置 | `cilium.io/ingress-tls-` | TLS 版本、加密套件 |
| CORS | `cilium.io/ingress-cors-` | 跨域资源共享配置 |
| 限速 | `cilium.io/ingress-rate-limit-` | 请求速率限制 |
| 代理 | `cilium.io/ingress-proxy-` | 超时、缓冲、重试 |
| 路径 | `cilium.io/ingress-rewrite-` | URL 重写 |
| 注解兼容 | `nginx.ingress.kubernetes.io/` | Nginx Ingress 兼容 |

---

## 2. 流量分割与权重

### 2.1 基础权重路由

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: weighted-route
  annotations:
    # 启用加权负载均衡
    cilium.io/ingress-backend-scheme: weighted
    # 权重配置（服务名: 权重）
    cilium.io/ingress-service-weight: |
      {
        "service-a": 80,
        "service-b": 20
      }
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: weighted-backend
            port:
              number: 80
```

### 2.2 基于 header 的流量分割

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: header-based-route
  annotations:
    # 基于请求头分流到不同服务
    cilium.io/ingress-match-header: |
      [
        {"name": "X-Canary", "value": "true", "backend": "canary-service"},
        {"name": "X-User-Type", "value": "premium", "backend": "premium-service"}
      ]
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: default-service
            port:
              number: 80
```

### 2.3 基于 Cookie 的流量分割

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cookie-based-route
  annotations:
    # 基于 Cookie 值分流
    cilium.io/ingress-match-cookie: |
      [
        {"name": "user_segment", "value": "vip", "backend": "vip-service"},
        {"name": "user_segment", "value": "beta", "backend": "beta-service"}
      ]
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: regular-service
            port:
              number: 80
```

### 2.4 渐进式金丝雀发布

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: canary-deployment
  annotations:
    # 金丝雀权重（逐步增加）
    cilium.io/ingress-canary-weight: "10"
    # 或者基于 header 的金丝雀
    cilium.io/ingress-canary-header: "X-Canary-Release"
    cilium.io/ingress-canary-header-value: "v2"
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: stable-service
            port:
              number: 80
```

---

## 3. 会话亲和性

### 3.1 基于 Cookie 的会话保持

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sticky-session
  annotations:
    # 启用会话亲和
    cilium.io/ingress-session-affinity: cookie
    # Cookie 配置
    cilium.io/ingress-session-cookie-name: session_id
    cilium.io/ingress-session-cookie-hash: sha1    # sha1/sha256/md5
    cilium.io/ingress-session-cookie-path: /
    cilium.io/ingress-session-cookie-max-age: 3600
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: stateful-app
            port:
              number: 80
```

### 3.2 基于 Client-IP 的亲和

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: client-ip-affinity
  annotations:
    cilium.io/ingress-session-affinity: client-ip
    cilium.io/ingress-session-affinity-timeout: 3600
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: sticky-app
            port:
              number: 80
```

---

## 4. CORS 配置

### 4.1 基础 CORS 配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cors-ingress
  annotations:
    # CORS 允许的来源
    cilium.io/ingress-cors-allow-origin: "https://example.com,https://app.example.com"
    # 允许的 HTTP 方法
    cilium.io/ingress-cors-allow-methods: "GET,POST,PUT,DELETE,OPTIONS"
    # 允许的请求头
    cilium.io/ingress-cors-allow-headers: "Authorization,Content-Type,X-Request-ID"
    # 暴露的响应头
    cilium.io/ingress-cors-expose-headers: "X-Response-Time,X-Request-ID"
    # CORS 预检缓存时间
    cilium.io/ingress-cors-max-age: 86400
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

### 4.2 高级 CORS 配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: advanced-cors
  annotations:
    # 允许凭证（Cookie/Authorization）
    cilium.io/ingress-cors-allow-credentials: "true"
    # CORS 模式
    cilium.io/ingress-cors-mode: "default"   # default/rewrite
    # 匹配所有来源（生产谨慎使用）
    cilium.io/ingress-cors-allow-origin: "*"
spec:
  ingressClassName: cilium
  rules:
  - host: public-api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: public-api
            port:
              number: 80
```

---

## 5. 速率限制

### 5.1 全局限速

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rate-limited
  annotations:
    # 请求速率限制
    cilium.io/ingress-rate-limit: "100"           # 每窗口请求数
    cilium.io/ingress-rate-limit-window: "1s"     # 时间窗口
    # 限速响应码（默认 429）
    cilium.io/ingress-rate-limit-status-code: "429"
    # 限速响应内容
    cilium.io/ingress-rate-limit-response-body: "Rate limit exceeded"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

### 5.2 基于 IP 的限速

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ip-rate-limit
  annotations:
    # 启用基于 IP 的限速
    cilium.io/ingress-rate-limit-type: "IP"
    # 每个 IP 的限制
    cilium.io/ingress-rate-limit: "10"
    cilium.io/ingress-rate-limit-window: "1s"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

### 5.3 基于 Service 的限速

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: service-rate-limit
  annotations:
    # 每个后端服务的独立限速
    cilium.io/ingress-service-rate-limit: |
      {
        "service-a": {"rate": 100, "window": "1s"},
        "service-b": {"rate": 50, "window": "1s"}
      }
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /a
        pathType: Prefix
        backend:
          service:
            name: service-a
            port:
              number: 80
      - path: /b
        pathType: Prefix
        backend:
          service:
            name: service-b
            port:
              number: 80
```

---

## 6. TLS 配置

### 6.1 TLS 版本控制

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-config
  annotations:
    # 最小 TLS 版本
    cilium.io/ingress-tls-min-version: "TLSv1.3"
    # 最大 TLS 版本
    cilium.io/ingress-tls-max-version: "TLSv1.3"
spec:
  ingressClassName: cilium
  tls:
  - hosts:
    - secure.example.com
    secretName: secure-tls
  rules:
  - host: secure.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: secure-backend
            port:
              number: 80
```

### 6.2 加密套件配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cipher-suite
  annotations:
    # 指定允许的加密套件
    cilium.io/ingress-tls-cipher-suites: |
      TLS_AES_256_GCM_SHA384,
      TLS_CHACHA20_POLY1305_SHA256,
      TLS_AES_128_GCM_SHA256
spec:
  ingressClassName: cilium
  tls:
  - hosts:
    - secure.example.com
    secretName: secure-tls
  rules:
  - host: secure.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: secure-backend
            port:
              number: 80
```

### 6.3 HTTP 到 HTTPS 重定向

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: http-redirect
  annotations:
    # 启用 HTTP 到 HTTPS 重定向
    cilium.io/ingress-http-to-https-redirect: "true"
    # 或者使用 301 重定向
    cilium.io/ingress-ssl-redirect: "true"
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-backend
            port:
              number: 80
```

---

## 7. 路径重写

### 7.1 基础路径重写

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-rewrite
  annotations:
    # 将匹配到的路径重写为目标路径
    cilium.io/ingress-rewrite-target: /api/v1
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /v1
        pathType: ImplementationSpecific
        backend:
          service:
            name: api-backend
            port:
              number: 8080
```

### 7.2 正则路径重写

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: regex-rewrite
  annotations:
    # 使用正则捕获组重写路径
    cilium.io/ingress-regex-template: "^/users/([0-9]+)/.*$"
    cilium.io/ingress-rewrite-target: "/user/$1"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /users
        pathType: ImplementationSpecific
        backend:
          service:
            name: user-api
            port:
              number: 8080
```

### 7.3 Nginx 兼容的路径重写

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-compatible-rewrite
  annotations:
    # Nginx Ingress 风格的重写
    nginx.ingress.kubernetes.io/rewrite-target: /api/v1/$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /v1(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: api-backend
            port:
              number: 8080
```

---

## 8. 代理配置

### 8.1 超时配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: timeout-config
  annotations:
    # 后端连接超时
    cilium.io/ingress-proxy-connect-timeout: "5s"
    # 响应头超时
    cilium.io/ingress-proxy-header-timeout: "30s"
    # 空闲连接超时
    cilium.io/ingress-proxy-idle-timeout: "60s"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

### 8.2 缓冲配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: buffer-config
  annotations:
    # 请求缓冲大小
    cilium.io/ingress-proxy-buffering: "on"
    cilium.io/ingress-proxy-buffer-size: "16k"
    cilium.io/ingress-proxy-buffers: "4"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

### 8.3 重试配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: retry-config
  annotations:
    # 重试次数
    cilium.io/ingress-proxy-retry-count: "3"
    # 重试超时
    cilium.io/ingress-proxy-retry-timeout: "5s"
    # 可重试的状态码
    cilium.io/ingress-retry-conditions: "gateway-error,connect-failure,reset"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

---

## 9. 请求/响应头修改

### 9.1 请求头修改

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: request-header-modify
  annotations:
    # 添加请求头
    cilium.io/ingress-request-header-add: |
      [
        {"name": "X-Forwarded-Proto", "value": "https"},
        {"name": "X-Request-Start", "value": "t=${time_iso8601}"}
      ]
    # 移除请求头
    cilium.io/ingress-request-header-remove: "X-Debug-Token"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

### 9.2 响应头修改

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: response-header-modify
  annotations:
    # 添加响应头
    cilium.io/ingress-response-header-add: |
      [
        {"name": "X-Served-By", "value": "cilium-gateway"},
        {"name": "Strict-Transport-Security", "value": "max-age=31536000"}
      ]
    # 移除响应头
    cilium.io/ingress-response-header-remove: "X-Powered-By"
spec:
  ingressClassName: cilium
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-backend
            port:
              number: 80
```

---

## 10. 安全注解

### 10.1 内容安全策略

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: csp-ingress
  annotations:
    # 内容安全策略
    cilium.io/ingress-content-security-policy: |
      default-src 'self';
      script-src 'self' 'unsafe-inline';
      style-src 'self' 'unsafe-inline';
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-backend
            port:
              number: 80
```

### 10.2 X-Frame-Options

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: frame-options
  annotations:
    cilium.io/ingress-x-frame-options: "DENY"
    cilium.io/ingress-x-content-type-options: "nosniff"
    cilium.io/ingress-x-xss-protection: "1; mode=block"
spec:
  ingressClassName: cilium
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-backend
            port:
              number: 80
```

---

## 11. 完整示例：咖啡店 API Gateway

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cafe-api-gateway
  annotations:
    # TLS 配置
    cilium.io/ingress-tls-min-version: "TLSv1.3"
    
    # 流量分割（金丝雀 10%）
    cilium.io/ingress-canary-weight: "10"
    
    # CORS
    cilium.io/ingress-cors-allow-origin: "https://cafe.example.com"
    cilium.io/ingress-cors-allow-methods: "GET,POST,PUT,DELETE,OPTIONS"
    cilium.io/ingress-cors-allow-headers: "Authorization,Content-Type"
    cilium.io/ingress-cors-max-age: "3600"
    
    # 限速
    cilium.io/ingress-rate-limit: "1000"
    cilium.io/ingress-rate-limit-window: "1s"
    
    # 代理超时
    cilium.io/ingress-proxy-connect-timeout: "5s"
    cilium.io/ingress-proxy-header-timeout: "30s"
    
    # 安全头
    cilium.io/ingress-x-frame-options: "DENY"
    cilium.io/ingress-content-security-policy: "default-src 'self'"
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
      - path: /tea
        pathType: Prefix
        backend:
          service:
            name: tea-svc
            port:
              number: 80
      - path: /coffee
        pathType: Prefix
        backend:
          service:
            name: coffee-svc
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port:
              number: 80
```

---

## 12. 注解调试

### 12.1 查看生效的注解

```bash
# 查看 Ingress 注解
kubectl describe ingress cafe-api-gateway

# 查看 Cilium Agent 解析的注解
kubectl exec -n kube-system ds/cilium -- cilium ingress get
```

### 12.2 常见问题

| 问题 | 可能原因 | 解决方案 |
|:---|:---|:---|
| 限速不生效 | 注解格式错误 | 检查 JSON/YAML 格式 |
| CORS 失败 | 来源不匹配 | 确认 origin 列表正确 |
| 路径重写失败 | 正则不匹配 | 使用 `kubectl logs` 检查 |
| TLS 错误 | 证书未加载 | 检查 Secret 是否存在 |

---

## 13. 总结

本章详细介绍了 Cilium Ingress 的各类注解配置：

**核心要点**：

- 流量管理注解实现加权路由、金丝雀发布、会话亲和
- CORS 注解支持跨域资源共享配置
- 限速注解保护后端服务
- TLS 注解控制安全连接参数
- 代理注解调整超时、缓冲、重试行为

**注解速查表**：

| 类别 | 常用注解 |
|:---|:---|
| 流量分割 | `cilium.io/ingress-canary-weight` |
| 会话亲和 | `cilium.io/ingress-session-affinity` |
| CORS | `cilium.io/ingress-cors-allow-origin` |
| 限速 | `cilium.io/ingress-rate-limit` |
| TLS | `cilium.io/ingress-tls-min-version` |
| 路径重写 | `cilium.io/ingress-rewrite-target` |

**下一章**：Cert-Manager 集成，自动化 TLS 证书管理。
