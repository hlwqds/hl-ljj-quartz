---
title: "Cilium 深度探索 (37)：透明加密"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - encryption
  - transparent-encryption
  - pod-to-pod
  - wireguard
  - ipsec
  - kubernetes
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 36. [[ch36-node-encryption|第三十六章：节点加密]] 37. **第三十七章：透明加密** ← 38. [[ch38-sockmap|第三十八章：Sockmap]]

---

## 1. 透明加密概述

Cilium 的透明加密（Transparent Encryption）实现**从 Pod 到 Pod 的端到端加密**，完全对应用透明——应用无需修改代码或配置任何 TLS 证书。Cilium 在 eBPF 层完成加解密，零应用改动。

```
┌────────────────────────────────────────────────────────────────────────┐
│                    透明加密：端到端安全                                  │
│                                                                        │
│  Pod A (app=A)              Node A          Node B         Pod B      │
│  ┌───────────┐                                                           │
│  │  App      │◄────── 加密通信 ────────►                                │
│  │ (无感知)  │         │                          │                    │
│  └───────────┘         │                          │                    │
│       │                 ▼                          ▼                    │
│       │          [eBPF 加密层] ──── 隧道加密 ──── [eBPF 解密层]         │
│       │                 │                          │                    │
│       ▼                 ▼                          ▼                    │
│  ┌───────────┐     ┌─────────┐                ┌─────────┐              │
│  │ Cilium    │     │ Cilium  │                │ Cilium  │              │
│  │ Agent     │────►│ eBPF    │                │ eBPF    │              │
│  │ (密钥管理) │     └─────────┘                └─────────┘              │
│  └───────────┘                                                           │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1 透明加密 vs mTLS

|                | 特性           | 透明加密                    | mTLS (Istio) |
| :------------- | :------------- | :-------------------------- | :----------- |
| **加解密位置** | eBPF（内核）   | Sidecar（用户态）           |
| **应用改动**   | 无需改动       | 需要应用支持 ServiceAccount |
| **CPU 开销**   | 极低 (~1%)     | 较高 (~5-15%)               |
| **延迟增加**   | 极低           | 中等                        |
| **密钥管理**   | 自动 (KVStore) | 需 Cert Manager             |
| **覆盖范围**   | Pod ↔ Pod      | Pod ↔ Pod (+外部)           |

---

## 2. 两种加密模式

Cilium 的透明加密支持两种实现方式：

### 2.1 隧道模式（WireGuard / IPsec Tunnel）

所有跨节点流量被封装在**加密隧道**中：

```
Pod A → [原始数据包] → [VXLAN 封装] → [WireGuard 加密] → Node B
                                                            ↓
                                                    [解密 → 解封装]
                                                            ↓
                                                        Pod B
```

### 2.2 传输模式（IPsec Transport）

仅加密数据包**有效载荷**，保持原始 IP 头不变：

```
Pod A → [原始数据包] → [IPsec ESP 加密载荷] → [原始IP头] → Node B
                                                              ↓
                                                        [IPsec ESP 解密]
                                                              ↓
                                                          Pod B
```

---

## 3. 启用透明加密

### 3.1 WireGuard 隧道模式

```bash
# Helm 启用 WireGuard 透明加密
helm upgrade cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set encryption.tunnelMode=wireguard

# 验证状态
kubectl -n kube-system exec ds/cilium -- \
    cilium encryption status
```

### 3.2 IPsec 传输模式

```bash
# Helm 启用 IPsec 传输加密
helm upgrade cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --set encryption.enabled=true \
  --set encryption.type=ipsec \
  --set encryption.tunnelMode=transport

# 可选：指定 IPsec 算法
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set encryption.ipsec.algorithm=aes-gcm-256
```

---

## 4. 加密策略配置

### 4.1 命名空间级别加密

```yaml
# 为特定命名空间启用加密
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    io.cilium.network.encryption: wireguard
```

### 4.2 CiliumEncryptionPolicy

Cilium 1.15+ 支持细粒度的加密策略：

```yaml
# 允许/禁止特定命名空间对之间的加密
apiVersion: cilium.io/v2
kind: CiliumEncryptionPolicy
metadata:
  name: allow-encrypted
spec:
  endpointSelectors:
    - matchLabels:
        namespace: production
  ingressEncryptionModes:
    - wireguard
    - ipsec
  egressEncryptionModes:
    - wireguard
    - ipsec
```

### 4.3 强制加密

```bash
# 强制所有节点间流量必须加密
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set encryption.required=true
```

---

## 5. 密钥管理

### 5.1 密钥生命周期

```
┌────────────────────────────────────────────────────────────────────────┐
│                    密钥生命周期管理                                      │
│                                                                        │
│  1. 密钥生成                                                            │
│     └── Cilium Agent 为每个节点生成公钥/私钥对                           │
│         - WireGuard: curve25519                                        │
│         - IPsec: ESP 密钥                                              │
│                                                                        │
│  2. 密钥分发                                                            │
│     └── 通过 KVStore (etcd) 分发给所有节点                               │
│         - 节点只获取与其通信的对等节点密钥                                │
│                                                                        │
│  3. 密钥轮换                                                            │
│     └── 定期自动轮换（可配置）                                           │
│         - WireGuard: 每个会话独立重协商                                  │
│         - IPsec: 定时重新生成 SA                                        │
│                                                                        │
│  4. 密钥撤销                                                            │
│     └── 节点离开集群时自动撤销                                           │
│         - 从 KVStore 删除对应密钥                                       │
└────────────────────────────────────────────────────────────────────────┘
```

### 5.2 查看密钥状态

```bash
# WireGuard 密钥
kubectl -n kube-system exec ds/cilium -- \
    wg show

# IPsec SA
kubectl -n kube-system exec ds/cilium -- \
    ip -s xfrm state list

# 查看加密统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf ipsec list
```

### 5.3 手动轮换密钥

```bash
# 强制 WireGuard 密钥重协商
kubectl -n kube-system exec ds/cilium -- \
    cilium encryption rotate wireguard

# 强制 IPsec SA 重新生成
kubectl -n kube-system exec ds/cilium -- \
    cilium encryption rotate ipsec
```

---

## 6. 验证加密生效

### 6.1 流量抓包验证

```bash
# 在节点上抓包，验证流量已加密
# 方法 1: 物理网卡抓包（应看到加密流量）
tcpdump -i eth0 -n host <node-b-ip>

# 方法 2: WireGuard 接口抓包（应看到明文）
tcpdump -i Cilium_wg0 -n

# 对比两端：eth0 看到的是加密数据，Cilium_wg0 看到的是原始数据
```

### 6.2 Hubble 观察加密流量

```bash
# Hubble 可以显示流量是否加密
hubble observe --protocol encrypted

# 查看特定 Pod 的加密状态
hubble observe --from-pod production/app-pod --to-pod production/db-pod
```

### 6.3 测试加密连接

```bash
# 测试 Pod 间连通性（加密通道）
kubectl exec -it app-pod -n production -- \
    curl -v https://db-service.production.svc.cluster.local

# 检查 TLS 握手（如果应用使用 HTTPS）
kubectl exec -it app-pod -n production -- \
    openssl s_client -connect db-service:443
```

---

## 7. 故障排查

### 7.1 常见问题

```bash
# 问题 1: 节点间流量未加密
# 排查:
kubectl -n kube-system exec ds/cilium -- \
    cilium encryption status

# 确认节点密钥交换
kubectl -n kube-system exec ds/cilium -- \
    wg show | grep peer

# 问题 2: 解密失败 (esp in errors)
# 排查:
kubectl -n kube-system exec ds/cilium -- \
    ip -s xfrm policy list

kubectl -n kube-system exec ds/cilium -- \
    ip -s xfrm state list

# 问题 3: WireGuard handshake 失败
# 排查:
dmesg | grep wireguard
cat /var/log/syslog | grep wireguard
```

### 7.2 性能影响评估

```
透明加密性能测试 (iperf3, 1500B MTU):

无加密:
  吞吐量: 9.8 Gbps
  CPU: 1 核 @ 3.2GHz

WireGuard 加密:
  吞吐量: 9.7 Gbps (99% 无加密)
  CPU: 1.2 核 @ 3.2GHz (+20%)
  延迟: +0.05ms

IPsec AES-GCM-256 加密:
  吞吐量: 9.3 Gbps (95% 无加密)
  CPU: 2.5 核 @ 3.2GHz (+150%)
  延迟: +0.15ms
```

> [!tip] 性能优化建议
>
> - 优先使用 WireGuard（ChaCha20 在无 AES-NI 的环境下更快）
> - IPsec 场景下使用 AES-GCM-128（安全性与性能最佳平衡）
> - MTU 合理设置（1500 - WireGuard overhead = 1420）

---

## 8. 章节总结

|                    | 模式               | 适用场景 | 性能 |
| :----------------- | :----------------- | :------- | :--- |
| **WireGuard 隧道** | 高性能数据中心     | 极高     |
| **IPsec 隧道**     | 需要与非 K8s 互通  | 高       |
| **IPsec 传输**     | 需要保持原始 IP 头 | 高       |

**关键优势**：

- 应用完全透明，无需代码改动
- eBPF 层实现，CPU 开销极低
- 自动密钥管理，无需手动配置
- 支持按命名空间/策略细粒度控制

**下一章**：Sockmap——Cilium 如何通过 eBPF 实现 Socket 劫持和 TCP 连接优化。

---

## 参考资料

- [Cilium Transparent Encryption](https://docs.cilium.io/en/stable/operations/encryption/)
- [WireGuard vs IPsec Performance](https://www.wireguard.com/performance/)
- [Cilium Encryption Architecture](https://docs.cilium.io/en/stable/architecture/datapath/)
- [IPsec in Linux](https://www.kernel.org/doc/html/latest/networking/ipsec-concept.html)
