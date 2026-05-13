---
title: "Cilium 深度探索 (17)：Hubble CLI 命令行工具详解"
date: 2026-04-14
tags:
  - cilium
  - hubble
  - cli
  - observability
  - flow
  - kubernetes
  - networking
  - troubleshooting
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
> 14. [[2026-04-14-cilium-deep-dive-ch14-dns|第十四章：DNS 策略]]
> 15. [[2026-04-14-cilium-deep-dive-ch15-categories|第十五章：策略层级]]
> 16. [[2026-04-14-cilium-deep-dive-ch16-hubble-overview|第十六章：Hubble 概述]]
> 17. **第十七章：Hubble CLI** ←

---

## 1. Hubble CLI 概述

Hubble CLI（`hubble`）是 Hubble 观测平台的命令行客户端，提供对集群网络流量的实时监控、历史查询、过滤分析和格式化输出能力。相比 Web UI，CLI 更适合：

- **快速排错**：秒级定位网络问题
- **脚本集成**：与 CI/CD 系统集成
- **精确过滤**：复杂条件组合查询
- **远程调试**：通过 SSH 隧道访问集群

```bash
# 安装 Hubble CLI
# 方法 1: 下载二进制
curl -LO https://github.com/cilium/hubble/releases/latest/download/hubble-linux-amd64.tar.gz
tar xzf hubble-linux-amd64.tar.gz
sudo mv hubble /usr/local/bin/

# 方法 2: via Cilium CLI
cilium hubble enable
cilium hubble status

# 方法 3: kubectl plugin
kubectl hubble
```

### 1.1 基础连接配置

```bash
# 配置 Hubble Server 地址（默认本地）
hubble config server localhost:4244

# 通过 Unix Socket 连接（Agent 节点上）
hubble config server unix:///var/run/cilium/hubble.sock

# 通过 Relay 连接（多节点集群）
hubble config server clusterMesh-hubble-relay:443

# TLS 配置
hubble config tls-insecure false
hubble config tls-ca-cert /var/run/cilium/hubble-server-ca.crt

# 查看配置
hubble config view
```

---

## 2. hubble observe（流量观测）

`hubble observe` 是最核心的命令，用于查看网络流量 Flow：

### 2.1 基础用法

```bash
# 实时监控所有流量
hubble observe

# 只看最近 100 条
hubble observe --last 100

# 监控 30 秒内的流量（然后退出）
hubble observe --duration 30s

# 格式化输出
hubble observe --output json    # JSON 格式
hubble observe --output compact # 紧凑格式
hubble observe --output dict   # key=value 格式
```

### 2.2 过滤器详解

```
┌─────────────────────────────────────────────────────────────┐
│               hubble observe 过滤器                         │
│                                                             │
│  --from-, --to-        源/目标过滤                           │
│  --from-label, --to-label    按标签过滤                     │
│  --from-port, --to-port      按端口过滤                     │
│  --protocol           按协议过滤（tcp/udp/icmp/http/dns）   │
│  --verdict            按判定过滤（forwarded/dropped）       │
│  --type               按类型过滤（flow/drop/audit）          │
│  --ip-version         按 IP 版本过滤（4/6）                  │
│  --port               按端口过滤                            │
│  --service            按服务名过滤                          │
│  --namespace          按命名空间过滤                        │
│  --pod                按 Pod 名过滤                         │
│  --node               按节点名过滤                          │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 源/目标过滤

```bash
# 来自特定 Pod 的流量
hubble observe --from-pod production/frontend-5f9b8c7d6-l3m4n

# 访问特定 Pod 的流量
hubble observe --to-pod production/backend-service-6b7c8d9e4-m2n8p

# 特定命名空间的所有流量
hubble observe --namespace production

# 双向过滤（from 和 to 都匹配）
hubble observe --from-pod production/frontend-5f9b8c7d6-l3m4n --to-pod production/api-gateway-7d8f9c6b5-xk9pq

# 来自特定标签的所有流量
hubble observe --from-label app=frontend

# 访问特定服务账号的流量
hubble observe --to-identity k8s:io.kubernetes.pod.namespace=production
```

### 2.4 协议过滤

```bash
# 只看 HTTP 流量
hubble observe --protocol http

# 只看 DNS 流量
hubble observe --protocol dns

# 只看 TCP 流量
hubble observe --protocol tcp

# 只看 UDP 流量
hubble observe --protocol udp

# 看所有非 HTTP 的 TCP 流量
hubble observe --protocol tcp --not-protocol http

# 看特定端口的流量
hubble observe --port 8080

# 看非 80/443 的流量
hubble observe --not-port 80,443
```

### 2.5 Verdict 过滤

```bash
# 只看被允许的流量
hubble observe --verdict FORWARDED

# 只看被丢弃的流量（重点关注！）
hubble observe --verdict DROPPED

# 查看丢弃原因
hubble observe --verdict DROPPED --last 50

# 组合：查看特定 Pod 的丢弃流量
hubble observe --verdict DROPPED --pod api-gateway-7d8f9c6b5-xk9pq

# 查看审计日志
hubble observe --type audit
```

### 2.6 时间范围过滤

```bash
# 看最近 5 分钟
hubble observe --since 5m

# 看最近 1 小时
hubble observe --since 1h

# 特定时间范围
hubble observe --since 2026-04-14T10:00:00Z --until 2026-04-14T11:00:00Z

# 实时流（Ctrl+C 退出）
hubble observe --follow
```

### 2.7 输出格式化

```bash
# 详细输出（默认）
hubble observe

# 10:30:01.234  IN  10.0.1.45:54321 -> 10.0.2.67:8080 TCP SYN
# 10:30:01.235  OUT 10.0.2.67:8080 -> 10.0.1.45:54321 TCP SYN-ACK
# 10:30:01.250  IN  10.0.1.45:54321 -> 10.0.2.67:8080 TCP ACK
# 10:30:01.251  IN  10.0.1.45:54321 -> 10.0.2.67:8080 HTTP GET /api/v1/users
# 10:30:01.300  OUT 10.0.2.67:8080 -> 10.0.1.45:54321 HTTP 200 OK

# JSON 输出（程序化处理）
hubble observe --output json --last 10

# compact 格式
hubble observe --output compact

# 10:30:01.234  production/frontend -> production/api-gateway:8080 [HTTP GET /api/v1/users]
# 10:30:01.300  production/api-gateway -> production/frontend:54321 [HTTP 200]

# table 格式
hubble observe --output table

# TIME                  SOURCE                       DESTINATION              VERDICT   PROTOCOL
# 10:30:01.234         frontend:54321              api-gateway:8080         FORWARDED TCP
# 10:30:01.251         frontend:54321              api-gateway:8080         FORWARDED HTTP

# 只显示特定字段
hubble observe --output-format '{{.time}} {{.source.pod_name}} -> {{.destination.pod_name}}'
```

---

## 3. hubble status（状态查看）

### 3.1 查看 Hubble Server 状态

```bash
hubble status

# 期望输出
Health: OK (localhost:4244)
Version: 1.12.0
Plugin Version: 1.12.0
TLS: OK (mTLS)
Peer Name: node-1
Node Addresses:
  - 10.0.0.1 (IPv4)
  - fd00::1 (IPv6)
```

### 3.2 查看所有节点状态

```bash
hubble status --all-nodes

# 期望输出
NODE         HEALT   VERSION   PLUGIN    TLS
node-1       OK      1.12.0    1.12.0    OK (mTLS)
node-2       OK      1.12.0    1.12.0    OK (mTLS)
node-3       OK      1.12.0    1.12.0    OK (mTLS)
```

### 3.3 查看连接的对等节点

```bash
hubble status --peer

# 期望输出
Peer:
  ID: 0
  Name: node-1
  Address: 10.0.0.1:4244
  State: PEER_CONNECTED
  Since: 2026-04-14T10:00:00Z
```

---

## 4. hubble list（端点列表）

### 4.1 列出所有网络端点

```bash
hubble endpoint list

# EPOCH   ID         IP                  NODE       STATUS
# 0       512        10.0.1.45          node-1     OK
# 0       513        10.0.2.67          node-2     OK
# 0       514        10.0.3.89          node-3     OK
```

### 4.2 查看特定端点详情

```bash
hubble endpoint get 512

# ID: 512
# IP: 10.0.1.45
# Node: node-1
# Status: OK
# Pod: production/frontend-5f9b8c7d6-l3m4n
# Labels: app=frontend,version=v2
# Policy: 
#   Ingress: ALLOWED (2 rules)
#   Egress: ALLOWED (1 rule)
```

---

## 5. hubble servcie（服务列表）

### 5.1 列出所有服务

```bash
hubble service list

# ID    FRONTEND              TYPE       BACKEND
# 1     10.96.0.1:443         ClusterIP  3 endpoints
# 2     10.96.0.10:53         ClusterIP  2 endpoints
# 3     10.96.0.20:8080       ClusterIP  backend-service:8080
```

### 5.2 查看服务详情

```bash
hubble service get 3

# ID: 3
# Name: backend-service
# Type: ClusterIP
# Frontend: 10.96.0.20:8080
# Backends:
#   - 10.0.2.67:8080 (node-2, port 8080)
#   - 10.0.3.89:8080 (node-3, port 8080)
```

---

## 6. hubble policy（策略查看）

### 6.1 查看已应用的策略

```bash
hubble policy get

# CILIUM NETWORK POLICY
# Name: api-gateway-policy
# UID: 123e4567-e89b
# Spec:
#   EndpointSelector:
#     matchLabels: app=api-gateway
#   Ingress:
#     - FromEndpoints:
#         - matchLabels: app=frontend
#       ToPorts:
#         - Port: 8080
#           Protocol: TCP
#           Rules:
#             HTTP:
#               - Method: GET
#                 Path: /api/.*
```

### 6.2 查看特定端点的策略

```bash
hubble policy get --endpoint 512

# Endpoint 512 (10.0.1.45):
#   Ingress Policy: ALLOWED
#   Egress Policy: ALLOWED
```

---

## 7. hubble recorded（录制与回放）

Hubble 支持录制流量到文件供后续分析：

### 7.1 录制流量

```bash
# 录制 60 秒流量到文件
hubble record --duration 60s --output /tmp/hubble-recording.gz

# 持续录制到循环缓冲区
hubble record --ring-buffer-size 10000 --output /tmp/hubble-recording.gz
```

### 7.2 回放录制

```bash
# 回放录制的流量
hubble play /tmp/hubble-recording.gz

# 只回放特定过滤条件
hubble play /tmp/hubble-recording.gz --verdict DROPPED

# 导出为 JSON
hubble play /tmp/hubble-recording.gz --output json > /tmp/flows.json
```

---

## 8. hubble filter（过滤表达式）

Hubble 支持高级过滤表达式：

### 8.1 逻辑组合

```bash
# AND 组合
hubble observe 'source.pod_name="frontend-*" AND destination.port=8080'

# OR 组合
hubble observe 'verdict="DROPPED" OR verdict="ERROR"'

# NOT 过滤
hubble observe 'NOT source.namespace="kube-system"'

# 复杂表达式
hubble observe 'source.namespace="production" AND (destination.port=80 OR destination.port=443) AND verdict="FORWARDED"'
```

### 8.2 正则匹配

```bash
# Pod 名正则匹配
hubble observe 'source.pod_name=~/frontend-.*/'

# 路径正则匹配（需要 L7 可见性）
hubble observe 'l7.http.path=~/\\/api\\/v[12]\/.*/'
```

### 8.3 字段选择

```bash
# 只显示特定字段
hubble observe --print-raw-flow 'source.pod_name destination.pod_name verdict'

# 时间戳格式
hubble observe --timestamp-format rfc3339

# 颜色输出（默认终端）
hubble observe --color always
hubble observe --color never
```

---

## 9. 高级用法与脚本集成

### 9.1 统计流量

```bash
# 统计源/目标 Pod 对的流量次数
hubble observe --last 1000 --output json | jq -r '
  .source.pod_name + " -> " + .destination.pod_name
' | sort | uniq -c | sort -rn | head -20

# Top 流量 Pod
hubble observe --last 10000 --output json | jq -r '
  if .source then .source.pod_name else "unknown" end
' | sort | uniq -c | sort -rn | head -10

# 统计丢弃原因
hubble observe --verdict DROPPED --last 1000 --output json | jq -r '
  .drop_reason
' | sort | uniq -c | sort -rn

# HTTP 状态码分布
hubble observe --protocol http --last 1000 --output json | jq -r '
  .l7.http.code
' | sort | uniq -c | sort -rn
```

### 9.2 延迟分析

```bash
# 计算平均 HTTP 延迟（纳秒转毫秒）
hubble observe --protocol http --last 100 --output json | jq -r '
  select(.l7 and .l7.http and .l7.http.latency_ns) | .l7.http.latency_ns | tonumber / 1000000
' | awk '{sum+=$1; count++} END {print "Avg HTTP latency: " sum/count "ms"}'

# P99 延迟
hubble observe --protocol http --last 1000 --output json | jq -r '
  select(.l7 and .l7.http and .l7.http.latency_ns) | .l7.http.latency_ns | tonumber
' | sort -n | awk 'BEGIN {n=1000*0.99} {a[int(NR-1)]=$1} END {print "P99 latency: " a[int(n)]/1000000 "ms"}'
```

### 9.3 CI/CD 集成

```bash
#!/bin/bash
# check-dropped-traffic.sh - CI/CD 中检查异常丢弃流量

set -e

MAX_DROPPED=${MAX_DROPPED:-100}
NAMESPACE=${NAMESPACE:-production}

echo "Checking for dropped traffic in namespace: $NAMESPACE"

DROPPED=$(hubble observe \
  --namespace "$NAMESPACE" \
  --verdict DROPPED \
  --since 5m \
  --output json | jq -s 'length')

echo "Dropped flows in last 5 minutes: $DROPPED"

if [ "$DROPPED" -gt "$MAX_DROPPED" ]; then
  echo "ERROR: Dropped traffic exceeds threshold ($MAX_DROPPED)"
  hubble observe --namespace "$NAMESPACE" --verdict DROPPED --last 10
  exit 1
fi

echo "OK: Dropped traffic within acceptable range"
```

### 9.4 Kubernetes Events 集成

```bash
# watch-drops.sh - 监控丢弃流量并生成 K8s Event
#!/bin/bash

hubble observe --verdict DROPPED --follow --output json | while read flow; do
  DROP_REASON=$(echo "$flow" | jq -r '.drop_reason // "UNKNOWN"')
  SOURCE=$(echo "$flow" | jq -r '.source.pod_name // "unknown"')
  DEST=$(echo "$flow" | jq -r '.destination.pod_name // "unknown"')
  
  kubectl create event \
    --namespace production \
    --message "Dropped traffic from $SOURCE to $DEST: $DROP_REASON" \
    --reason NetworkDrop \
    --type Warning \
    --source api-gateway 2>/dev/null || true
done
```

---

## 10. 常见问题排查

### 10.1 连接问题

```bash
# 检查 Hubble Server 是否可达
curl -s https://localhost:4244/v1/flows?stream=false | jq

# 检查 TLS 证书
hubble config view
openssl s_client -connect localhost:4244 </dev/null 2>/dev/null | openssl x509 -text

# 通过 Node IP 连接（替代 localhost）
hubble config server 10.0.0.1:4244
```

### 10.2 权限问题

```bash
# 检查 RBAC 权限
kubectl auth can-i list pods --as=system:serviceaccount: kube-system:hubble

# 查看 Hubble ServiceAccount
kubectl get sa -n kube-system hubble -o yaml
```

### 10.3 性能问题

```bash
# 减少观察的流量量
hubble observe --last 100  # 限制条数
hubble observe --namespace production  # 限制命名空间

# 使用过滤器减少处理
hubble observe --protocol http  # 只看 HTTP
```

---

## 11. 总结

Hubble CLI 提供了强大的命令行流量分析能力：

1. **hubble observe**：实时流量监控和历史查询
2. **hubble status**：Hubble Server 状态检查
3. **hubble endpoint list**：端点列表
4. **hubble service list**：服务列表
5. **hubble policy get**：策略查看
6. **hubble record/play**：流量录制回放

CLI 工具特别适合：
- 快速排错和调试
- 脚本化和自动化
- CI/CD 集成
- 远程 SSH 访问

下一章我们将介绍 **Hubble UI**，学习如何通过 Web 界面可视化服务拓扑和流量。
