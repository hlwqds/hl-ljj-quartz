---
title: "Cilium 深度探索 (36)：节点加密"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - wireguard
  - ipsec
  - encryption
  - node-to-node
  - kubernetes
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ... 35. [[2026-04-14-cilium-deep-dive-ch35-bandwidth-manager|第三十五章：带宽管理器]] 36. **第三十六章：节点加密** ← 37. [[2026-04-14-cilium-deep-dive-ch37-transparent-encryption|第三十七章：透明加密]] 38. [[2026-04-14-cilium-deep-dive-ch38-sockmap|第三十八章：Sockmap]]

---

## 1. 节点加密概述

Cilium 支持**节点间流量加密**，确保跨节点的 Pod 通信不被窃听或篡改。Cilium 支持两种加密后端：

|               | 方案              | 加密算法         | 性能     | 密钥管理 |
| :------------ | :---------------- | :--------------- | :------- | :------- |
| **WireGuard** | ChaCha20-Poly1305 | 极高（内核原生） | 自动分发 |
| **IPsec**     | AES-GCM           | 高               | 自动分发 |

```
┌────────────────────────────────────────────────────────────────────────┐
│                    节点加密全图                                        │
│                                                                        │
│  Node A 上的 Pod                                                       │
│       │                                                                │
│       ▼ (egress hook)                                                  │
│  [VXLAN 封装]                                                          │
│       │                                                                │
│       ▼                                                                │
│  [加密层] ──── WireGuard 或 IPsec ────► 隧道加密                       │
│       │                                                                │
│       ▼                                                                │
│  [物理网卡] ─────────────────────────────────────────────► Node B      │
│                                                                        │
│  Node B:                                                               │
│  [物理网卡]                                                             │
│       │                                                                │
│       ▼                                                                │
│  [解密层] ──── 验证并解密 ────► [解封装 VXLAN]                         │
│       │                                                                │
│       ▼                                                                │
│  [ingress hook]                                                        │
│       │                                                                │
│       ▼                                                                │
│  Node B 上的 Pod                                                       │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. WireGuard 加密

### 2.1 为什么选择 WireGuard

WireGuard 是专为现代内核设计的轻量级 VPN 协议，相比 IPsec：

- **代码量少**：~4,000 行 vs IPsec 的 ~600,000 行
- **极致性能**：利用内核 Crypt API，接近线速
- **现代加密**：ChaCha20-Poly1305（非 AES 依赖，ARM 友好）
- **快速握手**：减少连接建立延迟

### 2.2 启用 WireGuard

```bash
# Helm 启用 WireGuard 加密
helm upgrade cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --set wireguard.enabled=true \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

# 验证 WireGuard 状态
kubectl -n kube-system exec ds/cilium -- cilium encryption status
```

### 2.3 WireGuard 工作原理

```
WireGuard Handshake (首次建立):

Node A                                                   Node B
   │                                                        │
   │  ──── 1. Initiator (发送公钥 + 随机数) ──────────────►  │
   │                                                        │
   │  ◄── 2. Response (响应公钥 + 随机数 + Session Token) ──  │
   │                                                        │
   │  ──── 3. Response验证 + Cookie ───────────────────►   │
   │                                                        │
   │  ✓ 双方计算出相同的 Session Key                        │
   │                                                        │
   │  数据传输 (使用 ChaCha20-Poly1305 加密)                 │
   │  ──── 加密数据包 ────────────────────────────────────►  │
```

### 2.4 密钥分发机制

Cilium 通过 KVStore（etcd）**自动分发 WireGuard 密钥**，无需手动配置：

```bash
# 查看 WireGuard 公钥
kubectl -n kube-system exec ds/cilium -- \
    cilium debuginfo --.dump | grep -A5 WireGuard

# 查看节点间的 WireGuard 接口
kubectl -n kube-system exec ds/cilium -- \
    ip link show | grep wireguard

# 查看 WireGuard 隧道状态
kubectl -n kube-system exec ds/cilium -- \
    wg show
```

---

## 3. IPsec 加密

### 3.1 何时使用 IPsec

在以下场景优先选择 IPsec：

- 需要与**非 Cilium 节点**互通（IPsec 是标准协议）
- 已有 PKI 基础设施
- 需要 **ESP 隧道模式**与硬件加密卡配合

### 3.2 启用 IPsec

```bash
# Helm 启用 IPsec 加密
helm upgrade cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --set encryption.enabled=true \
  --set encryption.type=ipsec \
  --set encryption.ipsec.algorithm=aes-gcm-128

# 验证 IPsec 状态
kubectl -n kube-system exec ds/cilium -- cilium encryption status
```

### 3.3 IPsec 在 Cilium 中的实现

Cilium 的 IPsec 实现通过 **eBPF + XDP** 完成加密：

```
发送路径:
  Pod → [VXLAN 封装] → [eBPF IPsec 加密] → [物理网卡]

接收路径:
  [物理网卡] → [XDP IPsec 解密] → [eBPF 解封装] → Pod
```

### 3.4 密钥交换

```bash
# 查看 IPsec SA (Security Association)
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf ipsec list

# 查看 IPsec 统计
kubectl -n kube-system exec ds/cilium -- \
    ip -s xfrm state list

# 查看 IPsec 策略
ip -s xfrm policy list
```

---

## 4. 节点身份与加密

### 4.1 节点身份（Node Identity）

Cilium 为每个节点分配一个 **Security Identity**，用于加密时的对端验证：

```bash
# 查看节点身份
kubectl -n kube-system exec ds/cilium -- \
    cilium node list

# 示例输出:
# NODE             ENDPOINT-ID   HOST-IP         INTERVAL          IDENTIT
# node-1           28182         192.168.1.10    10s                5782
# node-2           28183         192.168.1.11    10s                5783
```

### 4.2 加密策略

Cilium 支持**按流量类型选择加密**：

```yaml
# 加密所有节点间流量
apiVersion: cilium.io/v2
kind: CiliumClusterwideEncryptionPolicy
metadata:
  name: encrypt-all
spec:
  endpointSelector:
    matchLabels:
      # 匹配所有节点上的 Cilium managed endpoints
  tunnel: true # WireGuard 模式
  # OR
  ipsecMode: tunnel # IPsec tunnel 模式
```

---

## 5. WireGuard vs IPsec 对比

### 5.1 性能对比

```
测试环境: 2x 10Gbps 节点, 1500B MTU, iperf3

WireGuard:
  吞吐量: 9.8 Gbps (98% 线速)
  CPU 开销: 1 核 @ 3.2GHz (0.8% 利用率)
  延迟增加: 0.05ms

IPsec (AES-GCM-128):
  吞吐量: 9.4 Gbps (94% 线速)
  CPU 开销: 2 核 @ 3.2GHz (1.5% 利用率)
  延迟增加: 0.12ms

IPsec (AES-GCM-256):
  吞吐量: 9.1 Gbps (91% 线速)
  CPU 开销: 3 核 @ 3.2GHz (2.1% 利用率)
  延迟增加: 0.18ms
```

### 5.2 选型建议

| 场景                     | 推荐方案  | 原因                   |
| :----------------------- | :-------- | :--------------------- |
| 高性能数据中心           | WireGuard | 极低开销，原生多核     |
| 与非 K8s 节点互通        | IPsec     | 标准协议，兼容性更好   |
| 已有 TPM/Hardware crypto | IPsec     | 可利用硬件加速         |
| 低延迟敏感业务           | WireGuard | 更低的延迟增加         |
| ARM/M1 节点              | WireGuard | ChaCha20 而非 AES 优化 |

---

## 6. 监控与调试

### 6.1 查看加密状态

```bash
# 查看全局加密状态
kubectl -n kube-system exec ds/cilium -- cilium encryption status

# 示例输出:
# Encryption: WireGuard (enabled)
# Mode: tunnel
# Nodes: 5/5 encrypted

# 查看 WireGuard 隧道 peer
kubectl -n kube-system exec ds/cilium -- wg show
```

### 6.2 排查加密问题

```bash
# 问题：节点间流量未加密
# 排查步骤：

# 1. 确认加密已启用
kubectl -n kube-system exec ds/cilium -- \
    cilium encryption status | grep -i enabled

# 2. 确认节点密钥已交换
kubectl -n kube-system exec ds/cilium -- \
    wg show | grep -c "peer"

# 3. 检查 IPsec SA
kubectl -n kube-system exec ds/cilium -- \
    ip -s xfrm state list | grep -c "auth-trunc"

# 4. 测试加密连通性
# 使用 ping + tcpdump 验证加密
tcpdump -i wireguard Cilium_ns_1 -n | head

# 5. 查看加密错误统计
kubectl -n kube-system exec ds/cilium -- \
    cilium debuginfo --error-codes | grep -i encryption
```

### 6.3 性能调优

```bash
# WireGuard 性能调优

# 1. 启用 Multi-Queue（利用多核）
# 在 /etc/modules 中添加:
wireguard

# 2. 调整 MTU（减少分片）
# Cilium 自动设置: 1500 - WireGuard overhead (80B) = 1420
ip link set Cilium_wg0 mtu 1420

# 3. 调整 Endpoint 缓存大小
cilium config EndpointRRSize=8192
```

---

## 7. 章节总结

|                | 特性              | WireGuard      | IPsec |
| :------------- | :---------------- | :------------- | :---- |
| **加密算法**   | ChaCha20-Poly1305 | AES-GCM        |
| **性能**       | 极高              | 高             |
| **密钥分发**   | 自动 (KVStore)    | 自动 (KVStore) |
| **兼容性**     | Cilium 节点间     | 可与第三方设备 |
| **代码复杂度** | 极低              | 高             |
| **推荐场景**   | 高性能数据中心    | 多厂商互通     |

**下一章**：透明加密——Cilium 如何实现从 Pod 到 Pod 的端到端加密，无需修改应用代码。

---

## 参考资料

- [Cilium WireGuard Encryption](https://docs.cilium.io/en/stable/operations/encryption/)
- [WireGuard Official Site](https://www.wireguard.com/)
- [Cilium IPsec Guide](https://docs.cilium.io/en/stable/configuration/)
- [WireGuard Performance](https://www.wireguard.com/performance/)
