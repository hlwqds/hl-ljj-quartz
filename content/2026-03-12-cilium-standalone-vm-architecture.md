---
title: Cilium Standalone & VM 虚拟机安全架构白皮书
date: 2026-03-12
tags: [cilium, vm, architecture, ebpf, security, standalone]
---

> [!abstract] 核心摘要
> 本文档深入研究 Cilium 在非 Kubernetes 环境下（Standalone/VM）的集成方案。核心结论指出：通过解耦控制面与数据面，可实现基于 eBPF 的企业级分布式微隔离架构，为虚拟机环境提供纳秒级的流量审计与透明加密。

---

## 1. 核心架构发现 (Core Discoveries)

### 1.1 Standalone 策略引擎

在没有 Kubernetes CRD 的情况下，Cilium 通过以下方式实现策略下发：

- **静态目录监控 (`--static-cnp-path`)**: Agent 监听本地 YAML 文件，实现 GitOps 式的策略管理。
- **REST API 注入**: 通过 `PUT /policy` 接口，外部管理平台可以实时、编程化地向各个 Agent 批量推送 BPF 规则。

### 1.2 身份识别机制 (Identity System)

- **标签映射**: VM 及其内部进程通过 `Labels` 进行身份化。
- **IPCache**: 宿主机通过维护 `IP -> Identity` 的内存 Map，实现纳秒级的流量审计与拦截，无需修改原始数据包。

---

## 2. 部署模式深度对比 (Deployment Modes)

| 特性             | Cilium-on-Host (代管模式)                  | Cilium-in-Guest (独立模式)                   |
| :--------------- | :----------------------------------------- | :------------------------------------------- |
| **部署位置**     | 宿主机内核                                 | 虚拟机 Guest 内核                            |
| **信任边界**     | **宿主机为王**。宿主机破防则 VM 全线失守。 | **虚拟机自治**。宿主机仅为不可信管道。       |
| **同机 VM 加密** | **不支持** (BPF 路由优化会跳过加密)。      | **支持** (每个 VM 拥有独立 WireGuard 隧道)。 |
| **管理开销**     | 极低 (一机一 Agent)。                      | 较高 (一 VM 一 Agent)。                      |
| **性能损耗**     | 极低 (接近原生网络)。                      | 中等 (每个 VM 都要处理加密封包)。            |

---

## 3. 通信与加密策略 (Communication & Encryption)

### 3.1 跨外网 WireGuard 隧道

- **触发条件**: 目的地 IP 属于远程节点。
- **优势**: 自动处理 NAT 穿透，在 Linux 内核层实现透明加密。
- **局限**: 默认不保护同宿主机内的 VM 交互流量。

### 3.2 节点间 mTLS (Mutual Auth)

- **控制面**: 宿主机 Agent 互换证书。
- **数据面**: BPF Map (`AUTH_MAP`) 动态授权。
- **应用**: 在 `on-host` 模式下，VM 零感知即可享受节点间的身份准入。

---

## 4. 自动化接入方案 (Automation Implementation)

### 4.1 宿主机动态探测逻辑

虚拟机启动时通过以下逻辑寻找控制面（宿主机 IP）：

```bash
# 获取默认网关地址作为宿主机 API 入口
HOST_IP=$(ip route get 1.1.1.1 | grep -oP 'via \K\S+')

# 动态生成 Agent 配置
cilium-agent --kvstore etcd --kvstore-opt etcd.address=${HOST_IP}:2379 \
             --clustermesh-config=/etc/cilium/clustermesh/
```

---

## 5. 安全攻防边界 (Security Boundaries)

### 5.1 宿主机沦陷场景 (Host Compromise)

- 在 `Cilium-on-host` 模式下，攻击者拥有宿主机 Root 权限后可以：
  - 通过 `tap`设备抓取所有 VM 的明文流量。
  - 修改 BPF 规则绕过防火墙。
- **对策**: 核心敏感业务必须升级为 `Cilium-in-guest` 模式。

### 5.2 爆炸半径控制 (Blast Radius)

- 即使 VM 被攻破，Cilium 的**默认拒绝（Default Deny）**策略能确保黑客无法在内网进行横向扫描（Lateral Movement）。
- 控制器应集成 **Hubble API**，实现“异常流量 -> 自动隔离”的闭环审计。
