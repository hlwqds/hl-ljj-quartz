---
title: Cilium 流量加密实现原理深度解析
date: 2026-03-12
tags: [cilium, encryption, wireguard, ipsec, ebpf, security]
---

> [!abstract] 核心机制
> Cilium 流量加密基于**内核层实现**，对应用完全透明：
>
> - **WireGuard**：现代推荐方案，基于 UDP，性能优秀
> - **IPsec**：传统方案，兼容性好，开销略高
>
> **关键点**：eBPF 负责识别跨节点流量并路由到加密隧道，加密由内核 WireGuard/IPsec 模块完成。

---

## 1. 整体架构

### 1.1 加密数据流

```
同节点 Pod 通信（不加密）：
┌─────────┐         ┌─────────┐
│ Pod A   │ ─────── │ Pod B   │
│ veth    │  eBPF   │ veth    │
└─────────┘  直接   └─────────┘
             转发


跨节点 Pod 通信（加密）：
Node A                                        Node B
┌──────────────────────────┐                 ┌──────────────────────────┐
│                          │                 │                          │
│  Pod A                   │                 │                   Pod B  │
│    │                     │                 │                     │    │
│    ↓                     │                 │                     ↓    │
│  veth                    │                 │                   veth   │
│    │                     │                 │                     │    │
│    ↓                     │                 │                     ↓    │
│  ┌─────────────────┐     │                 │     ┌─────────────────┐  │
│  │  Cilium eBPF    │     │                 │     │  Cilium eBPF    │  │
│  │                 │     │                 │     │                 │  │
│  │ 1. 识别跨节点   │     │                 │     │ 1. 解封装       │  │
│  │ 2. 重定向到 WG  │     │                 │     │ 2. 路由到 Pod   │  │
│  └────────┬────────┘     │                 │     └────────┬────────┘  │
│           │              │                 │              │           │
│           ↓              │                 │              ↓           │
│  ┌─────────────────┐     │                 │     ┌─────────────────┐  │
│  │ WireGuard 设备   │     │                 │     │ WireGuard 设备   │  │
│  │ (cilium_wg0)    │     │                 │     │ (cilium_wg0)    │  │
│  │                 │     │   UDP 51871     │     │                 │  │
│  │ 3. 加密封装     │ ═══════════════════════════ 4. 解密解封装   │  │
│  └────────┬────────┘     │    加密隧道      │     └────────┬────────┘  │
│           │              │                 │              │           │
│           ↓              │                 │              ↓           │
│  ┌─────────────────┐     │                 │     ┌─────────────────┐  │
│  │   物理网卡      │     │                 │     │   物理网卡      │  │
│  │   eth0          │ ═══════════════════════════   eth0          │  │
│  └─────────────────┘     │   物理网络      │     └─────────────────┘  │
│                          │                 │                          │
└──────────────────────────┘                 └──────────────────────────┘
```

### 1.2 组件职责

| 组件               | 职责                             | 运行位置 |
| :----------------- | :------------------------------- | :------- |
| **Cilium eBPF**    | 识别跨节点流量，重定向到加密设备 | 内核     |
| **WireGuard**      | 密钥管理、加密、封装             | 内核模块 |
| **cilium-agent**   | 密钥分发、节点信息同步           | 用户态   |
| **Kubernetes API** | 存储节点公钥、同步信息           | 集群     |

---

## 2. WireGuard 加密详解

### 2.1 WireGuard 基础

```
WireGuard 特点：
├─ 现代加密：ChaCha20-Poly1305
├─ 密钥交换：Curve25519
├─ 哈希：BLAKE2s
├─ 传输：UDP（单个端口）
└─ 代码量：~4000 行（极小）

对比：
├─ IPsec：~400,000 行代码
├─ OpenVPN：~100,000 行代码
└─ WireGuard：~4,000 行代码
```

### 2.2 Cilium WireGuard 实现

```c
// Cilium 创建的 WireGuard 设备
// $ ip link show cilium_wg0
cilium_wg0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue
    link/none

// WireGuard 配置
// $ wg show cilium_wg0
interface: cilium_wg0
  public key: ABCD...（节点 A 公钥）
  private key: (hidden)
  listening port: 51871

peer: EFGH...（节点 B 公钥）
  endpoint: 10.0.1.2:51871
  allowed ips: 10.244.1.0/24  ← 节点 B 的 Pod CIDR
  latest handshake: 1 minute ago
  transfer: 1.5 GB received, 2.1 GB sent
```

### 2.3 密钥管理流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                        密钥管理流程                                   │
└─────────────────────────────────────────────────────────────────────┘

1. 节点启动 - 生成密钥对
┌─────────────┐
│ cilium-agent│
│   启动      │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────┐
│ wg genkey > private.key         │  生成私钥
│ wg pubkey < private.key > pubkey│  生成公钥
└─────────────────────────────────┘


2. 注册公钥到 K8s
┌─────────────┐                    ┌─────────────┐
│ cilium-agent│ ── 更新 Node ────→ │  K8s API    │
│   Node A    │    annotations     │   Server    │
└─────────────┘                    └─────────────┘
                                        │
                                        │ 存储内容:
                                        │ cilium.io/wg-pub-key: "ABCD..."
                                       ▼


3. 发现其他节点并建立隧道
┌─────────────┐                    ┌─────────────┐
│ cilium-agent│ ←─ watch Nodes ─── │  K8s API    │
│   Node A    │                    │   Server    │
└──────┬──────┘                    └─────────────┘
       │
       │ 发现 Node B
       │ 读取其公钥: EFGH...
       │ 读取其 IP: 10.0.1.2
       │ 读取其 Pod CIDR: 10.244.1.0/24
       ▼
┌─────────────────────────────────┐
│ wg set cilium_wg0 \             │  添加 Peer
│   peer EFGH... \                │
│   endpoint 10.0.1.2:51871 \     │
│   allowed-ips 10.244.1.0/24     │
└─────────────────────────────────┘


4. 完整的节点互联
                    ┌─────────────┐
                    │  K8s API    │
                    │   Server    │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │   Node A    │ │   Node B    │ │   Node C    │
    │ pubkey: ABCD│ │ pubkey: EFGH│ │ pubkey: IJKL│
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
           │   WireGuard Full Mesh 连接    │
           │◄──────────────┼──────────────►│
           └───────────────┴───────────────┘
```

### 2.4 数据包封装过程

```
原始数据包（Pod A → Pod B）：
┌──────────────────────────────────────────┐
│ 以太网头 │ IP 头 │ TCP 头 │ HTTP Data    │
│          │       │        │              │
│          │ 源: 10.244.0.5 (Pod A)        │
│          │ 目的: 10.244.1.8 (Pod B)      │
└──────────────────────────────────────────┘
                    │
                    ▼ Cilium eBPF 识别跨节点
                    ▼ 重定向到 cilium_wg0


WireGuard 加密后：
┌─────────────────────────────────────────────────────────────────┐
│ 外层以太网 │ 外层IP头 │ UDP头 │ WireGuard头 │ 加密的原始数据包  │
│            │          │       │             │                   │
│            │ 源: 10.0.0.1 (Node A)          │                   │
│            │ 目的: 10.0.1.2 (Node B)        │                   │
│            │          │ 端口: │             │                   │
│            │          │ 51871 │             │                   │
└─────────────────────────────────────────────────────────────────┘

WireGuard 头（32 字节）：
├─ Type (1 byte): 消息类型
├─ Reserved (3 bytes)
├─ Receiver Index (4 bytes): 接收方索引
├─ Counter (8 bytes): 包计数器（防重放）
└─ Poly1305 Tag (16 bytes): 认证标签
```

---

## 3. eBPF 程序的作用

### 3.1 eBPF 程序类型

```
Cilium 用于加密的 eBPF 程序：

1. tc-ingress (入站)
   ├─ 挂载点：网卡 ingress
   ├─ 功能：解封装，路由到目标 Pod
   └─ 类型：TC clsact/ingress

2. tc-egress (出站)
   ├─ 挂载点：网卡 egress
   ├─ 功能：识别跨节点流量，重定向到 WireGuard
   └─ 类型：TC clsact/egress

3. cgroup-connect (连接)
   ├─ 挂载点：cgroup /sys/fs/cgroup/connect4
   ├─ 功能：socket 级别的策略检查
   └─ 类型：BPF_PROG_TYPE_CGROUP_SOCK_ADDR
```

### 3.2 跨节点流量识别

```c
// 简化的 eBPF 伪代码
// bpf_lxc.c: do_redirect()

static __always_inline int do_redirect(struct __ctx_buff *ctx) {
    struct endpoint_info *ep;
    __u32 dst_ip = ctx_load_meta(ctx, CB_DST_IP);

    // 查找目标 IP 对应的 endpoint
    ep = lookup_ip_to_endpoint(dst_ip);

    if (ep) {
        // 情况 1: 目标在本节点
        if (ep->node_id == LOCAL_NODE_ID) {
            // 直接转发到 veth
            return ctx_redirect(ctx, ep->ifindex, 0);
        }

        // 情况 2: 目标在其他节点
        // 设置 tunnel 端点
        ctx_store_meta(ctx, CB_TUNNEL_DST, ep->node_ip);

        // 如果启用了 WireGuard
        if (wireguard_enabled()) {
            // 重定向到 WireGuard 设备
            return ctx_redirect(ctx, WG_IFINDEX, 0);
        }

        // 如果是 IPsec 或其他 tunnel
        // ...
    }

    return DROP_UNKNOWN_DESTINATION;
}
```

### 3.3 eBPF 与 WireGuard 的配合

```
数据路径：

┌─────────────────────────────────────────────────────────────┐
│ Pod A 发送数据包                                             │
│ sendto(10.244.1.8:80, "GET /")                              │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ veth pair (Pod → Host)                                      │
│ lxc1234 → cilium_host                                       │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Cilium eBPF (tc-ingress on lxc1234)                         │
│ 1. 解析数据包                                                │
│ 2. 查表：10.244.1.8 → Node B                                │
│ 3. 判断：跨节点 → 需要 WireGuard                            │
│ 4. 重定向到 cilium_wg0                                       │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ WireGuard 设备 (cilium_wg0)                                 │
│ 1. 查找 Peer：10.244.1.8 → Node B (10.0.1.2)               │
│ 2. 加密数据包（ChaCha20-Poly1305）                          │
│ 3. UDP 封装（目标端口 51871）                                │
│ 4. 设置外层 IP 头（10.0.0.1 → 10.0.1.2）                    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 物理网卡 eth0                                                │
│ 发送加密后的 UDP 包到 Node B                                 │
└─────────────────────────────────────────────────────────────┘
                           │
                           │  物理网络
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Node B 物理网卡 eth0                                         │
│ 接收 UDP 包（端口 51871）                                    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ WireGuard 设备 (cilium_wg0)                                 │
│ 1. 验证 Poly1305 标签                                        │
│ 2. 解密数据包（ChaCha20-Poly1305）                          │
│ 3. 去除 UDP 封装                                             │
│ 4. 输出原始 IP 包                                            │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Cilium eBPF (tc-ingress on eth0 或 cilium_wg0)              │
│ 1. 解析原始数据包                                            │
│ 2. 查表：10.244.1.8 → veth lxc5678                          │
│ 3. 重定向到 Pod 的 veth                                      │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ veth pair (Host → Pod)                                      │
│ cilium_host → lxc5678                                       │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Pod B 接收数据包                                             │
│ recvfrom(..., "GET /")                                      │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. IPsec 加密详解

### 4.1 IPsec 模式

```
Cilium IPsec 使用 ESP (Encapsulating Security Payload) 隧道模式：

┌─────────────────────────────────────────────────────────────┐
│ ESP 隧道模式封装                                             │
│                                                             │
│ ┌─────────┬─────────┬──────────┬───────────┬─────────────┐ │
│ │ 外层 IP │ ESP 头  │ 原始 IP  │ TCP/Data  │ ESP Trailer │ │
│ │         │         │ + Data   │           │ + Auth      │ │
│ └─────────┴─────────┴──────────┴───────────┴─────────────┘ │
│                                                             │
│ 外层 IP: Node A → Node B                                    │
│ ESP 头: SPI (Security Parameter Index) + 序列号             │
│ 加密部分: 原始 IP + TCP/Data                                 │
│ ESP Trailer: Padding + Next Header                          │
│ Auth: ICV (Integrity Check Value)                           │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 IPsec 配置

```yaml
# Cilium IPsec 配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  enable-ipsec: "true"
  ipsec-key-file: "/etc/ipsec/keys" # 预共享密钥
```

```
# 预共享密钥文件格式
# /etc/ipsec/keys
10.0.0.1 10.0.1.2 aes256sha1 0x1234567890abcdef...
10.0.0.1 10.0.2.3 aes256sha1 0xabcdef1234567890...
```

### 4.3 IPsec vs WireGuard 对比

| 特性           | WireGuard          | IPsec             |
| :------------- | :----------------- | :---------------- |
| **加密算法**   | ChaCha20-Poly1305  | AES-GCM / AES-CBC |
| **密钥交换**   | Curve25519（内置） | 需要配置或 IKE    |
| **代码复杂度** | ~4,000 行          | ~400,000 行       |
| **CPU 开销**   | 低                 | 中等              |
| **NAT 穿透**   | 原生支持           | 需要额外配置      |
| **内核要求**   | Linux 5.6+ / 模块  | 所有内核          |
| **配置复杂度** | 简单               | 复杂              |
| **调试难度**   | 容易               | 困难              |

---

## 5. 配置与部署

### 5.1 启用 WireGuard 加密

```yaml
# Helm values.yaml
encryption:
  enabled: true
  type: wireguard

# 或使用 cilium-cli 安装
# cilium install --encryption=wireguard
```

### 5.2 验证加密状态

```bash
# 1. 检查 WireGuard 设备
$ ip link show cilium_wg0
cilium_wg0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1420

# 2. 检查 WireGuard 状态
$ wg show cilium_wg0
interface: cilium_wg0
  public key: ABCD...
  listening port: 51871

peer: EFGH...
  endpoint: 10.0.1.2:51871
  allowed ips: 10.244.1.0/24
  latest handshake: 30 seconds ago
  transfer: 1.2 GiB received, 1.8 GiB sent

# 3. 检查 Cilium 状态
$ cilium status
    /¯¯\
 /¯¯\__/¯¯\    Cilium:         OK
 \__/¯¯\__/    Operator:       OK
 /¯¯\__/¯¯\    Hubble:         OK
 \__/¯¯\__/    ClusterMesh:    OK
    \__/
DaemonSet         cilium             Desired: 3, Ready: 3/3
Encryption:       WireGuard          [Node: OK, Pod: OK]

# 4. 检查节点密钥
$ kubectl get node node-1 -o yaml | grep cilium.io/wg-pub-key
cilium.io/wg-pub-key: "ABCD1234..."
```

### 5.3 抓包验证加密

```bash
# 在物理网卡抓包
# 应该看到 UDP 51871 端口的加密流量
$ tcpdump -i eth0 udp port 51871 -nn
12:34:56.789 IP 10.0.0.1.51871 > 10.0.1.2.51871: UDP, length 140
12:34:56.790 IP 10.0.1.2.51871 > 10.0.0.1.51871: UDP, length 140

# 无法看到原始 Pod IP 或 HTTP 内容
# 证明已加密
```

---

## 6. 性能分析

### 6.1 开销分解

```
WireGuard 加密开销（单核，AES-NI 支持）：

操作                    延迟
─────────────────────────────────
加密（ChaCha20）         ~0.5 µs
认证（Poly1305）         ~0.2 µs
UDP 封装                 ~0.1 µs
总计（加密）             ~0.8 µs

解密 + 验证              ~0.8 µs
─────────────────────────────────
往返加密开销             ~1.6 µs

吞吐量影响（10Gbps NIC）：
├─ 无加密：~9.5 Gbps
├─ WireGuard：~8.5 Gbps (-10%)
└─ IPsec：~7.0 Gbps (-26%)
```

### 6.2 CPU 开销测试

```
测试环境：8 核 CPU / 10 Gbps NIC / 1 Gbps 流量

场景                    CPU 使用
─────────────────────────────────
无加密                   5%
WireGuard 加密           7% (+2%)
IPsec 加密               10% (+5%)
─────────────────────────────────
```

### 6.3 MTU 影响

```
WireGuard 封装开销：
├─ 外层 IP 头：20 字节
├─ UDP 头：8 字节
├─ WireGuard 头：32 字节
└─ 总计：60 字节

MTU 计算：
├─ 默认 MTU：1500 字节
├─ WireGuard MTU：1500 - 60 = 1440 字节
└─ cilium_wg0 默认：1420 字节（保守配置）

注意：
├─ Pod 内应用应使用 1420 或更小 MTU
├─ 或依赖 Path MTU Discovery
└─ 大包可能被分片（性能下降）
```

---

## 7. 故障排查

### 7.1 常见问题

```
问题 1: WireGuard 设备不存在
─────────────────────────────────
检查：
$ ip link show cilium_wg0
Device "cilium_wg0" does not exist.

解决：
# 检查内核模块
$ modprobe wireguard
$ lsmod | grep wireguard

# 检查 Cilium 配置
$ kubectl exec -it cilium-xxx -n kube-system -- cilium-dbg status


问题 2: 节点间无法建立隧道
─────────────────────────────────
检查：
$ wg show cilium_wg0
# 没有显示 peer 或 handshake 一直失败

解决：
# 检查防火墙（需要开放 UDP 51871）
$ iptables -L -n | grep 51871

# 检查节点连通性
$ ping <peer-node-ip>

# 检查公钥同步
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,WGKEY:.metadata.annotations.cilium\.io/wg-pub-key


问题 3: Pod 间通信失败
─────────────────────────────────
检查：
# 进入 Cilium Pod
$ kubectl exec -it cilium-xxx -n kube-system -- bash

# 查看 eBPF 状态
$ cilium-dbg bpf tunnel list

# 查看路由
$ ip route show table all | grep cilium

# 查看 endpoint
$ cilium-dbg endpoint list
```

### 7.2 调试命令

```bash
# 查看 Cilium 加密状态
$ cilium-dbg encrypt status
Encryption: WireGuard
Node to Node encryption: Enabled
Pod to Pod encryption: Enabled

# 查看 WireGuard 日志
$ dmesg | grep wireguard

# 抓包调试
# 在 WireGuard 接口抓包（解密后）
$ tcpdump -i cilium_wg0 -nn

# 在物理网卡抓包（加密后）
$ tcpdump -i eth0 udp port 51871 -nn

# 查看 eBPF map
$ cilium-dbg bpf ipcache list
IP PREFIX/ADDRESS   IDENTITY   TUNNEL ENDPOINT
10.244.1.0/24       1234       10.0.1.2
```

---

## 8. 安全特性

### 8.1 加密强度

```
WireGuard 加密套件：
├─ 身份认证：Curve25519 (ECDH)
├─ 对称加密：ChaCha20
├─ 消息认证：Poly1305
├─ 密钥派生：HKDF-BLAKE2s
└─ 哈希函数：BLAKE2s

安全特性：
├─ 前向 secrecy：每次握手生成新密钥
├─ 防重放：64 位计数器 + 滑动窗口
├─ 完美前向保密：定期密钥轮换
└─ 抗降级：固定算法，无协商
```

### 8.2 密钥轮换

```
WireGuard 密钥轮换机制：

Initiator                    Responder
    │                            │
    │──── Initiation ────────────▶│
    │    (Ephemeral Key)         │
    │                            │
    │◀─── Response ──────────────│
    │    (Ephemeral Key)         │
    │                            │
    │    双方计算出相同的         │
    │    对称密钥 (ChaCha20 key) │
    │                            │
    │◀══════════════════════════▶│
    │    每 2-3 分钟重新握手      │
    │    生成新的对称密钥         │
    │                            │

重新握手条件：
├─ 时间：2-3 分钟无数据传输
├─ 数据量：达到一定阈值
├─ 或一方发起重握手
└─ 保证前向保密
```

---

## 9. 高级场景

### 9.1 混合云/多云场景

```
AWS VPC                    本地数据中心
┌─────────────┐           ┌─────────────┐
│  Node A     │           │  Node D     │
│  Pod CIDR:  │           │  Pod CIDR:  │
│  10.244.0.0/24          │  10.244.3.0/24
└──────┬──────┘           └──────┬──────┘
       │                         │
       │    WireGuard over       │
       │    Internet/VPN         │
       │ ◐══════════════════════◐ │
       │                         │
┌──────┴──────┐           ┌──────┴──────┐
│  Node B     │           │  Node E     │
└─────────────┘           └─────────────┘

配置要点：
├─ 确保节点间网络可达
├─ 开放 UDP 51871 端口
├─ 注意 MTU（可能需要调小）
└─ 考虑公网场景的额外安全
```

### 9.2 部分加密（仅特定流量）

```yaml
# 使用 CiliumNetworkPolicy 选择性加密
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: encrypt-sensitive
spec:
  endpointSelector:
    matchLabels:
      app: sensitive-service
  egress:
    - toEndpoints:
        - matchLabels:
            app: database
      # 此流量会被加密
```

---

## 10. 总结

### 10.1 架构总结

```
Cilium 流量加密 = eBPF + WireGuard/IPsec

┌─────────────────────────────────────────┐
│              应用层                      │  无感知
├─────────────────────────────────────────┤
│              Socket 层                   │  无感知
├─────────────────────────────────────────┤
│         Cilium eBPF (tc/bpf)            │  识别跨节点
├─────────────────────────────────────────┤
│         WireGuard/IPsec                 │  加密/解密
├─────────────────────────────────────────┤
│              TCP/IP                     │
├─────────────────────────────────────────┤
│              网卡                        │
└─────────────────────────────────────────┘
```

### 10.2 选型建议

| 场景                  | 推荐      |
| :-------------------- | :-------- |
| **新部署，内核 5.6+** | WireGuard |
| **旧内核兼容**        | IPsec     |
| **性能敏感**          | WireGuard |
| **NAT 环境频繁**      | WireGuard |
| **合规要求特定算法**  | IPsec     |

### 10.3 一句话总结

**Cilium 流量加密通过 eBPF 识别跨节点流量并重定向到 WireGuard 设备，由内核 WireGuard 模块完成加密封装，对应用完全透明，开销约 2-5%。**

---

## 外部参考

- [Cilium Encryption Documentation](https://docs.cilium.io/en/stable/security/network/encryption/)
- [WireGuard Protocol](https://www.wireguard.com/protocol/)
- [Linux IPsec HOWTO](https://www.ipsec-howto.org/)
- [eBPF and Cilium](https://ebpf.io/)
