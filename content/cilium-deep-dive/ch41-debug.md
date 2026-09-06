---
title: "Cilium 深度探索 (41)：故障诊断与排查"
date: 2026-04-14
tags:
  - cilium
  - debugging
  - troubleshooting
  - hubble
  - cilium-cli
  - diagnostics
  - operations
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 38. [[ch38-sockmap|第三十八章：Sockmap]] 39. [[ch39-install|第三十九章：生产级安装指南]] 40. [[ch40-upgrade|第四十章：升级策略]] 41. **第四十一章：故障诊断与排查** ← 42. [[ch42-performance|第四十二章：性能调优]]

---

## 1. 诊断工具概述

Cilium 提供了丰富的诊断工具，从命令行到 Hubble Flow，形成完整的故障排查体系。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Cilium 诊断工具全家桶                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                        CLI 工具                              │   │
│   │                                                             │   │
│   │   cilium CLI           │  kubectl cilium                    │   │
│   │   ─────────────────────┼─────────────────────────           │   │
│   │   • cilium status      │  • kubectl cilium connectivity     │   │
│   │   • cilium endpoint    │  • kubectl cilium bgp             │   │
│   │   • cilium config      │  • kubectl cilium encrypt         │   │
│   │   • cilium bpf         │  • kubectl cilium policy          │   │
│   │   • cilium node        │                                     │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                     Hubble 观测                              │   │
│   │                                                             │   │
│   │   hubble observe    │    hubble CLI     │    Hubble UI      │   │
│   │   ───────────────    │    ──────────     │    ─────────      │   │
│   │   实时流量追踪        │    交互式查询       │    可视化 Flow    │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │                     Sysdump 收集                            │   │
│   │                                                             │   │
│   │   cilium sysdump  →  完整诊断包 (日志 + 状态 + 配置)         │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. cilium CLI 基础

### 2.1 安装 cilium CLI

```bash
# Linux
curl -L --remote-name https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
tar xzf cilium-linux-amd64.tar.gz
sudo mv cilium /usr/local/bin

# macOS
curl -L --remote-name https://github.com/cilium/cilium-cli/releases/latest/download/cilium-darwin-amd64.tar.gz
tar xzf cilium-darwin-amd64.tar.gz
sudo mv cilium /usr/local/bin

# 验证安装
cilium version
```

### 2.2 集群状态检查

```bash
# 基本状态
cilium status

# 详细状态
cilium status --verbose

# 输出示例
    /¯¯\
/¯¯\__/¯¯\    Cilium:         OK
\__/¯¯\__/    Node Monitor:   OK
/¯¯\__/¯¯\    Kubernetes:    OK
\__/¯¯\__/    Cilium ERDS:    OK
    \__/      Hubble:         OK

Deployment        Replicas   Available
cilium-operator   2          2
hubble-relay      1          1

DaemonSet         Desired   Ready
cilium            4         4
```

### 2.3 端点管理

```bash
# 列出所有端点
cilium endpoint list

# 查看特定端点详情
cilium endpoint get 1987

# 查看端点配置
cilium endpoint config 1987

# 查看端点 Labels
cilium endpoint labels 1987
```

---

## 3. Hubble 流量诊断

### 3.1 Hubble CLI

```bash
# 安装 Hubble CLI
curl -L https://github.com/cilium/hubble/releases/latest/download/hubble-linux-amd64.tar.gz | tar xzf -
sudo mv hubble /usr/local/bin

# 端口转发（如果没有 Ingress）
kubectl port-forward -n kube-system svc/hubble-relay 8888:80

# 配置 Hubble CLI 连接
hubble config set address localhost:8888

# 查看连接状态
hubble status
```

### 3.2 流量追踪

```bash
# 实时观测所有流量
hubble observe

# 观测特定 Pod 的流量
hubble observe --pod default/nginx-abc123

# 观测特定命名空间的流量
hubble observe --namespace default

# 观测特定 Service 的流量
hubble observe --to-service default/nginx

# 观测被拒绝的流量
hubble observe --type drop --type denied

# 观测特定 IP 的流量
hubble observe --ip 10.0.0.5

# 观测特定端口的流量
hubble observe --port 80

# 观测 HTTP 流量的详细信息
hubble observe --protocol http
```

### 3.3 过滤表达式

```bash
# 复杂过滤示例
hubble observe \
  --namespace default \
  --type drop \
  --verdict DROP \
  --timestamp

# 观测从特定 Pod 发出的流量
hubble observe --from-pod default/client

# 观测发往外部的流量
hubble observe --to-fqdn example.com

# 观测 DNS 响应
hubble observe --dns-type response
```

### 3.4 Hubble UI

```bash
# 访问 Hubble UI
kubectl get svc -n kube-system svc/hubble-ui

# 本地端口转发
kubectl port-forward -n kube-system svc/hubble-ui 8889:80

# 浏览器访问 http://localhost:8889
```

---

## 4. eBPF 诊断

### 4.1 BPF Map 查看

```bash
# 列出所有 BPF Maps
cilium bpf map list

# 示例输出
MAPNAME                                MAX_ENTRIES   VALUE_SIZE   NAME
cilium_policy_4                        16384         8            ...
cilium_lb4_services_v2                 65536         48           ...
cilium_lb4_backends_v2                 65536         48           ...
cilium_ipmasq                          65536         16           ...
cilium_tunnel_v4                       65536         16           ...

# 查看特定 Map 内容
cilium bpf map get cilium_lb4_services_v2

# 查看 Map 中的具体条目
cilium bpf map dump cilium_lb4_services_v2
```

### 4.2 BPF Program 查看

```bash
# 列出所有 BPF Programs
cilium bpf prog list

# 查看特定 Program 详情
cilium bpf prog dump xdp cilium_forward

# 查看已加载的 eBPF 程序统计
cilium bpf metrics list
```

### 4.3 连接追踪

```bash
# 查看当前连接
cilium bpf connections list

# 查看 NAT 表
cilium bpf nat list

# 查看 Conntrack 表
cilium bpf conntrack list | head -20
```

---

## 5. 常见故障排查

### 5.1 Pod 无法网络通信

排查流程：

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Pod 网络不通排查流程                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   1. 检查端点是否存在                                                 │
│      cilium endpoint list | grep <pod-ip>                          │
│                                                                     │
│   ├── 端点不存在                                                      │
│   │   → 检查 Cilium Agent 是否运行                                  │
│   │   → 检查 Node 网络配置                                           │
│   │                                                                   │
│   2. 端点存在但非 Ready                                               │
│   │   → 检查 policy 是否允许                                          │
│   │   → hubble observe --pod <pod>                                 │
│   │                                                                   │
│   3. 检查 DNS 解析                                                   │
│      kubectl exec <pod> -- nslookup <service>                      │
│   │                                                                   │
│   4. 检查 Hubble Flow                                                │
│      hubble observe --pod <pod> --type drop                        │
│                                                                     │
│   5. 检查 eBPF Map                                                   │
│      cilium bpf nat list | grep <pod-ip>                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

```bash
# Step 1: 确认端点存在
cilium endpoint list | grep nginx
# 1987   ready   default/nginx-abc123   10.0.0.5    ...

# Step 2: 检查 Hubble 流量
hubble observe --pod default/nginx-abc123 --last 50

# Step 3: 检查网络策略
cilium policy get --怼

# Step 4: 检查端点日志
kubectl logs -n kube-system ds/cilium | grep 1987

# Step 5: 检查 eBPF NAT 表
cilium bpf nat list | grep 10.0.0.5
```

### 5.2 Service 无法访问

```bash
# 检查 Service 是否存在于 LB Map
cilium bpf map dump cilium_lb4_services_v2 | grep <service-ip>

# 检查 Service 是否有后端
kubectl get svc <service-name> -o jsonpath='{.spec.ports}'

# 检查 Endpoint 是否健康
kubectl get endpoints <service-name>

# 检查 Session 亲和
cilium service list

# 测试 Service 连通性
kubectl exec <pod> -- curl -v <service-ip>:<port>
```

### 5.3 NetworkPolicy 不生效

```bash
# 检查策略是否应用
cilium policy get

# 查看策略拒绝的连接
hubble observe --type drop --verdict DENIED

# 检查端点级别策略
cilium endpoint policy 1987

# 检查 L7 策略
cilium fqdn cache list

# 验证策略导入
cilium policy import <policy-file.yaml>
```

### 5.4 节点间通信失败

```bash
# 检查隧道配置
cilium config view | grep tunnel

# 检查节点间加密
cilium encrypt status

# 检查 VXLAN 端点
cilium bpf tunnel list

# 检查节点路由
ip route | grep cilium

# 测试节点间 MTU
ping -M do -s 1400 <node-ip>
```

---

## 6. Sysdump 收集

### 6.1 自动收集

```bash
# 收集完整诊断信息
cilium sysdump

# 指定输出文件
cilium sysdump --output-filename my-cluster-diagnostics

# 收集特定节点信息
cilium sysdump --nodes node-1,node-2

# 收集带时间戳
cilium sysdump --output-filename $(date +%Y%m%d-%H%M%S)-cilium-dump
```

### 6.2 手动收集

```bash
# 收集日志
kubectl logs -n kube-system -l k8s-app=cilium --tail=1000 > cilium-logs.txt
kubectl logs -n kube-system -l k8s-app=cilium-operator --tail=500 > cilium-operator-logs.txt

# 收集状态
cilium status > cilium-status.txt
cilium endpoint list -o json > endpoints.json
cilium node list > nodes.txt
cilium config view > config.txt

# 收集 Hubble 信息
hubble observe --last 10000 -o json > hubble-flows.json

# 收集 BPF 信息
cilium bpf map list > bpf-maps.txt
cilium bpf prog list > bpf-progs.txt

# 收集网络信息
ip addr > ip-addr.txt
ip route > ip-route.txt
ip link > ip-link.txt
```

### 6.3 日志分析

```bash
# 查看错误日志
kubectl logs -n kube-system -l k8s-app=cilium | grep -i error

# 查看警告日志
kubectl logs -n kube-system -l k8s-app=cilium | grep -i warn

# 实时查看日志
kubectl logs -n kube-system -l k8s-app=cilium -f

# 查看特定端点日志
kubectl logs -n kube-system ds/cilium | grep "endpoint=1987"
```

---

## 7. 网络策略调试

### 7.1 策略导入测试

```bash
# 测试策略导入（不实际应用）
cilium policy import --dry-run policy.yaml

# 导入并查看结果
cilium policy import policy.yaml
cilium policy get
```

### 7.2 追踪策略决策

```bash
# 启用策略跟踪
cilium endpoint policy 1987 --trace

# 查看跟踪结果
cilium policy trace --src-endpoint 1987 --dst-endpoint 2010 --l4-port 80

# 示例输出
 Tracing policies: 1987 → 2010 (port 80/TCP)

✉️  1987 (L3)     : Allow all ingress
✉️  2010 (L3)     : Allow all egress
✅ 1987 → 2010   : Policy allows connection
```

### 7.3 L7 策略调试

```bash
# 检查 DNS 策略
cilium fqdn cache list

# 检查 L7 规则
cilium policy get | grep -A5 "http:"

# 查看允许的 HTTP 方法
cilium endpoint config 1987 | grep L7
```

---

## 8. 性能问题诊断

### 8.1 延迟高

```bash
# 检查数据面延迟
cilium bpf metrics list | grep latency

# 检查是否有限速
cilium bpf bandwidth meter list

# 检查 MTU
ip link | grep -E "cilium|wireguard"

# 使用 Hubble 测量延迟
hubble observe --protocol http --port 80 --last 100 | grep -i latency
```

### 8.2 丢包

```bash
# 检查丢包统计
cilium bpf metrics list | grep drop

# 检查节点接口统计
ip -s link show cilium+ | grep -E "drop|error"

# 检查 conntrack 问题
cilium bpf conntrack list | grep -E "deleted|expired"

# 检查 TC 策略
tc -s filter show dev cilium+ parent ffff:
```

---

## 9. 加密问题诊断

### 9.1 WireGuard 状态

```bash
# 检查 WireGuard 加密状态
cilium encrypt status

# 检查 WireGuard 接口
ip link show | grep wireguard

# 检查 WireGuard 密钥
wg show

# 查看节点间加密流量
hubble observe --type encrypted
```

### 9.2 IPsec 状态

```bash
# 检查 IPsec 状态
cilium encrypt status --output json | jq .

# 检查 IPsec 策略
ip xfrm policy list

# 检查 IPsec 安全关联
ip xfrm state list

# 查看加密/解密统计
cilium bpf metrics list | grep -E "encrypt|decrypt"
```

---

## 10. 多集群问题诊断

### 10.1 Cluster Mesh 状态

```bash
# 检查 Cluster Mesh 状态
cilium clustermesh status

# 检查集群间连接
cilium clustermesh connect --destination-cluster cluster2

# 查看 global service
cilium service list | grep global

# 检查跨集群网络策略
cilium policy get --怼 | grep -E "Cluster|global"
```

### 10.2 跨集群流量问题

```bash
# 检查 tunnel 配置
cilium config view | grep -E "cluster|mesh|tunnel"

# 查看 Hubble 跨集群流量
hubble observe --type REMOTE_CLUSTER

# 检查 global service 端点
cilium global-service list
```

---

## 11. 常见错误码

### 11.1 Hubble Verdict

| Verdict        | 含义     | 可能原因           |
| :------------- | :------- | :----------------- |
| **FORWARDED**  | 正常转发 | -                  |
| **DROPPED**    | 丢包     | 策略拒绝、资源不足 |
| **DENIED**     | 被拒绝   | NetworkPolicy 拒绝 |
| **ERROR**      | 错误     | 解析失败、程序错误 |
| **TRACED**     | 被追踪   | 符合策略规则       |
| **TRANSLATED** | 地址转换 | NAT/Proxy 处理     |

### 11.2 端点状态

| 状态                     | 含义         |
| :----------------------- | :----------- |
| **ready**                | 正常运行     |
| **waiting-for-identity** | 等待身份分配 |
| **init**                 | 初始化中     |
| **regenerating**         | 重建策略     |
| **unhealthy**            | 健康检查失败 |

---

## 12. 排错命令速查

```
# 快速诊断
cilium status                    # 基本状态
cilium sysdump check-requirements  # 环境检查

# 网络连通性
cilium connectivity test        # 连通性测试
hubble observe --last 100       # 最近 100 条流量

# 策略问题
cilium policy get               # 查看已应用策略
hubble observe --type drop      # 查看丢包

# 性能问题
cilium bpf metrics list         # BPF 指标
cilium bpf map list             # BPF Map 列表

# 日志
kubectl logs -n kube-system -l k8s-app=cilium --tail=500 -f
```

---

## 13. 下一步

完成故障诊断后，下一章将讲解 [[ch42-performance| Cilium 性能调优]]，包括 eBPF 性能基准、延迟优化和吞吐量调优。
