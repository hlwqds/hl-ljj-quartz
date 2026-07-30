---
title: "DPDK 深度探索 ch39：容器网络与 DPDK——vhost-user、SR-IOV、AF_XDP 三条路径"
date: 2026-04-09 16:40:00
tags:
  [dpdk, container, kubernetes, cni, ovs-dpdk, vhost-user, sriov, af_xdp, multus, hugepages, cnf]
description: "从 DPDK 工程视角解析容器网络：vhost-user/OVS-DPDK 虚拟交换、SR-IOV VF 直通、AF_XDP PMD 三种路径的选型、K8s Device Plugin、Hugepage 管理、NUMA 对齐与 CNF 最佳实践"
---

# DPDK 深度探索 ch39：容器网络与 DPDK——vhost-user、SR-IOV、AF_XDP 三条路径

> [!info] 章节定位
> DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
>
> 关联章节：
>
> - [[2026-04-09-dpdk-deep-dive-ch35-sr-iov|SR-IOV 与 VF 管理]]
> - [[2026-04-09-dpdk-deep-dive-ch37-smartnic|SmartNIC 数据面——Representor、E-Switch 与硬件卸载]]
> - [[2026-04-09-dpdk-deep-dive-ch38-dpdk-ebpf|eBPF/XDP 与 DPDK 协同——AF_XDP PMD]]
> - [[2026-04-09-dpdk-deep-dive-ch38-firewall-dpdk|防火墙数据面——ACL、Conntrack、NAT 与硬件卸载]]

> [!abstract] 核心结论
> 在容器中运行 DPDK 有三条路径，选型取决于 **性能要求、硬件条件和运维复杂度**：
>
> 1. **vhost-user + OVS-DPDK**：Pod 通过 vhost-user socket 连到 OVS-DPDK 虚拟交换机。适合需要虚拟交换、多租户隔离的场景，性能中等但灵活性强；
> 2. **SR-IOV VF 直通**：VF 直接分配给 Pod，接近裸金属性能。适合极致性能要求的 CNF，但 VF 数量受硬件限制；
> 3. **AF_XDP PMD**：Pod 通过 AF_XDP socket 收发包，不独占网卡。适合云环境和混合部署，性能略低于 SR-IOV 但门槛最低。
>
> 三者共同需要：hugepage 管理、CPU 独占、NUMA 对齐、Device Plugin 资源广告。

---

## 1. 容器网络的核心挑战

### 1.1 传统容器网络为什么不够

标准 Kubernetes 网络基于 veth pair + bridge：

```text
标准 K8s 网络：
  Pod eth0 ←→ veth pair ←→ bridge ←→ eth0 (PF) ←→ wire
       │            │           │
       │      内核收包      内核转发
       │      (中断+协议栈)  (bridge FDB)
       │
       └─ 每个包经过 2 次 kernel/user 切换 + 1 次 bridge 查找
          单核吞吐 ~500K-1M pps
          延迟 ~20-50μs
```

DPDK 应用需要：

| 需求               | 传统容器不满足的原因                  |
| ------------------ | ------------------------------------- |
| 零拷贝收包         | veth pair 需要内核参与                |
| Hugepage 内存      | 容器默认不挂载 hugepage               |
| 独占 CPU           | K8s 默认 CPU 共享，上下文切换影响轮询 |
| 直接访问网卡       | 容器网络命名空间隔离了设备            |
| 轮询模式（无中断） | 内核网络栈是中断驱动的                |
| VFIO 设备访问      | 容器默认无 VFIO 权限                  |

### 1.2 三条路径概览

```text
路径 1：vhost-user + OVS-DPDK
═════════════════════════════
  Pod (DPDK) ←→ vhost-user socket ←→ OVS-DPDK ←→ NIC
  · 虚拟交换机在中间，Pod 不直接碰硬件
  · 灵活：OVS 做转发、ACL、隧道
  · 适合：NFV、多租户、需要虚拟交换

路径 2：SR-IOV VF 直通
════════════════════════
  Pod (DPDK) ←→ VF（PCI 直通）←→ E-Switch ←→ wire
  · Pod 直接拥有 VF，不经过任何中间层
  · 性能最接近裸金属
  · 适合：极致性能、低延迟交易、电信级 CNF

路径 3：AF_XDP PMD
══════════════════
  Pod (DPDK) ←→ AF_XDP socket ←→ 内核 XDP ←→ NIC
  · 不独占网卡，与内核协议栈共存
  · 部署最简单，不需要 VFIO 或 VF
  · 适合：云环境、混合部署、渐进式迁移
```

### 1.3 选型决策

```text
能否独占硬件（VF/SR-IOV）？
    │
    ├── Yes ──→ 需要虚拟交换（多 Pod 互通、ACL）？
    │               │
    │               ├── Yes ──→ OVS-DPDK + vhost-user（路径 1）
    │               └── No  ──→ SR-IOV VF 直通（路径 2）
    │
    └── No ──→ AF_XDP PMD（路径 3）
                或 vhost-user（由 OVS 管理硬件）
```

---

## 2. 基础设施：Hugepage 与 Device Plugin

无论哪条路径，容器中运行 DPDK 都需要先解决两个基础问题：
hugepage 内存和设备访问。

### 2.1 Hugepage 管理

**节点侧**：预分配 hugepage

```bash
# 分配 1024 个 2MB hugepage = 2GB
echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
echo 1024 > /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages

# 或通过内核启动参数
# default_hugepagesz=2M hugepagesz=2M hugepages=2048

# 确认分配
cat /proc/meminfo | grep Huge
# HugePages_Total:    2048
# HugePages_Free:     2048
# Hugepagesize:       2048 kB
```

**Kubernetes 资源广告**：kubelet 自动将 hugepage 注册为可调度资源

```bash
# 查看节点 hugepage 资源
kubectl describe node worker1 | grep hugepages
# hugepages-2Mi:  2Gi
# hugepages-1Gi:  0
```

**Pod 请求 hugepage**：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-pod
spec:
  containers:
    - name: dpdk-app
      image: dpdk-app:latest
      resources:
        requests:
          hugepages-2Mi: "1Gi" # 请求 1GB hugepage
          memory: "2Gi" # 普通 memory（不含 hugepage）
          cpu: "4"
        limits:
          hugepages-2Mi: "1Gi" # requests == limits（Guaranteed QoS）
          memory: "2Gi"
          cpu: "4"
      volumeMounts:
        - name: hugepages
          mountPath: /dev/hugepages # DPDK 通过此路径访问 hugepage
  volumes:
    - name: hugepages
      emptyDir:
        medium: HugePages # 挂载为 hugepage
```

> [!warning] Hugepage 的关键限制
>
> - `requests` 和 `limits` 必须 **相等**（hugepage 不可超分）
> - hugepage 是 **Pod 级**资源，不是容器级——同一 Pod 内多个容器共享
> - 节点 hugepage 数量是 **静态预分配** 的，运行时修改需要重启 kubelet
> - NUMA 感知：Topology Manager 确保 CPU 和 hugepage 来自同一 NUMA node

### 2.2 CPU 独占与 NUMA 对齐

```yaml
# 必须 Guaranteed QoS（requests == limits）才能获得独占 CPU
spec:
  containers:
    - name: dpdk-app
      resources:
        requests:
          cpu: "4"
          memory: "2Gi"
        limits:
          cpu: "4" # 必须整数，才能获得独占核心
          memory: "2Gi"
```

节点 kubelet 配置：

```bash
# /var/lib/kubelet/config.yaml
cpuManagerPolicy: static        # 独占 CPU 策略
topologyManagerPolicy: best-effort  # 或 single-numa-node
```

```text
CPU Manager static 策略：
  · 整数 CPU 请求的 Pod → 分配独占核心
  · 其他 Pod 不能使用这些核心
  · DPDK 轮询线程不会被其他进程抢占

Topology Manager：
  · best-effort: 尽量 NUMA 对齐，不对齐也能调度
  · restricted: CPU 和设备必须同 NUMA，内存可以跨
  · single-numa-node: 所有资源必须来自同一 NUMA node
  · none: 不做 NUMA 约束（性能最差）
```

### 2.3 Device Plugin 框架

Device Plugin 是 Kubernetes 将硬件资源广告给 Pod 的标准机制：

```text
kubelet
  │
  ├── Device Plugin: SR-IOV Network Device Plugin
  │   · 发现节点上的 VF
  │   · 注册资源：intel.com/mlxn_sriov_net = 8
  │   · Pod 请求该资源 → kubelet 分配 VF → 传给容器
  │
  ├── Device Plugin: GPU Device Plugin
  │   · 注册 NVIDIA GPU 资源
  │
  └── Built-in: Hugepages
      · 自动注册 hugepages-2Mi / hugepages-1Gi
```

SR-IOV Device Plugin 配置示例：

```yaml
# sriov-device-plugin-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sriov-device-plugin-config
data:
  config.json: |
    {
      "resourceList": [
        {
          "resourceName": "mlxn_sriov_net",
          "selectors": {
            "vendors": ["15b3"],
            "devices": ["101e"],
            "drivers": ["mlx5_core"],
            "pfNames": ["enp3s0f0"]
          }
        }
      ]
    }
```

Pod 请求 VF：

```yaml
spec:
  containers:
    - name: dpdk-app
      resources:
        limits:
          mlxn.com/mlxn_sriov_net: "1" # 请求 1 个 VF
```

---

## 3. 路径 1：vhost-user + OVS-DPDK

### 3.1 架构

```text
┌─────────────────────────────────────────────────────────────┐
│                        Host                                  │
│                                                              │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐               │
│  │  Pod A    │  │  Pod B    │  │  Pod C    │               │
│  │  DPDK App │  │  DPDK App │  │  普通 App  │               │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘               │
│        │              │              │                       │
│   vhost-user     vhost-user       veth pair                 │
│   socket          socket          (标准 K8s)                │
│        │              │              │                       │
│  ┌─────▼──────────────▼──────────────▼───────────────────┐  │
│  │                   OVS-DPDK                             │  │
│  │  vswitchd (控制面: OpenFlow/OVSDB)                     │  │
│  │  DPDK PMD threads (数据面: 转发、ACL、隧道)            │  │
│  └───────────────────────┬────────────────────────────────┘  │
│                          │                                   │
│                    dpdk-p0 (物理端口)                         │
│                          │                                   │
└──────────────────────────┼───────────────────────────────────┘
                           │
                         wire
```

### 3.2 vhost-user 工作原理

```text
vhost-user 是用户态的 virtio 数据路径：

  DPDK App (Pod)                    OVS-DPDK (Host)
  ┌──────────────┐                 ┌──────────────┐
  │ virtio PMD   │                 │ vhost-user   │
  │              │  共享内存       │ backend      │
  │ virtio RX/TX │◄──────────────►│ (PMD)        │
  │ queues       │  (hugepage)    │              │
  └──────────────┘                 └──────────────┘

  数据路径：
  1. OVS 收到物理端口的包
  2. OVS 把包放入共享内存中的 virtio ring
  3. Pod 的 virtio PMD 从 virtio ring 轮询取包
  4. 零拷贝——包数据不离开 hugepage

  关键：
  · 两端都通过 hugepage 共享内存通信
  · 不经过内核（纯用户态）
  · Socket 用于控制面协商（内存布局、特性协商）
```

### 3.3 vhost-user vs vhost-user-client

| 维度          | vhost-user（server 模式） | vhost-user-client（client 模式） |
| ------------- | ------------------------- | -------------------------------- |
| Socket 创建者 | OVS 创建 socket 文件      | Pod/容器创建 socket 文件         |
| OVS 重启影响  | **Pod 必须重连或重启**    | Pod 不受影响，OVS 重连           |
| Pod 重启影响  | OVS 需要清理旧 socket     | Socket 随容器删除                |
| 推荐模式      | 旧方案                    | **推荐**——更健壮                 |
| OVS 端口类型  | `dpdkvhostuser`           | `dpdkvhostuserclient`            |

> [!info] 生产环境用 vhost-user-client
> `dpdkvhostuserclient` 是推荐模式。OVS 作为 client 连接到容器创建的 socket，
> 这样 OVS 升级/重启不会导致容器中的 DPDK 应用中断。

### 3.4 OVS-DPDK 现代配置

```bash
# 1. 启动 ovsdb-server
ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    --detach

# 2. 初始化
ovs-vsctl --no-wait init

# 3. 配置 DPDK 参数（通过 ovs-vsctl，不是启动参数）
ovs-vsctl set Open_vSwitch . \
    other_config:dpdk-init=true \
    other_config:dpdk-socket-mem="2048,2048" \
    other_config:pmd-cpu-mask=0xff00

# 4. 启动 vswitchd
ovs-vswitchd unix:/var/run/openvswitch/db.sock --detach

# 5. 创建 bridge
ovs-vsctl add-br br0 -- set bridge br0 datapath_type=netdev

# 6. 添加物理端口
ovs-vsctl add-port br0 dpdk-p0 \
    -- set Interface dpdk-p0 type=dpdk \
    options:dpdk-devargs="0000:3d:00.0" \
    options:n_rxq=2 \
    options:n_txq=2

# 7. 添加 vhost-user-client 端口（供 Pod 使用）
ovs-vsctl add-port br0 vhost-client-0 \
    -- set Interface vhost-client-0 type=dpdkvhostuserclient \
    options:vhost-server-path=/var/run/vhost/pod-a.sock

# 8. 配置 OpenFlow 规则
ovs-ofctl add-flow br0 "in_port=1,actions=output:2"
```

> [!warning] PMD CPU Mask
> `pmd-cpu-mask` 指定哪些 CPU 核用于 OVS-DPDK PMD 轮询线程。
> 这些核心必须与 Pod 的 DPDK 核心分开，否则会互相抢占。
> 建议用十六进制掩码精确分配核心。

### 3.5 Pod 通过 vhost-user 连接 OVS

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-pod-vhost
  annotations:
    k8s.v1.cni.cncf.io/networks: dpdk-net
spec:
  containers:
    - name: dpdk-app
      image: dpdk-app:latest
      securityContext:
        capabilities:
          add: ["IPC_LOCK", "NET_ADMIN"] # IPC_LOCK 用于 hugepage
      resources:
        requests:
          hugepages-2Mi: "1Gi"
          memory: "1Gi"
          cpu: "2"
        limits:
          hugepages-2Mi: "1Gi"
          memory: "1Gi"
          cpu: "2"
      volumeMounts:
        - name: hugepages
          mountPath: /dev/hugepages
        - name: vhost-sock
          mountPath: /var/run/vhost # vhost socket 路径
  volumes:
    - name: hugepages
      emptyDir:
        medium: HugePages
    - name: vhost-sock
      hostPath:
        path: /var/run/vhost # 宿主机 socket 路径
```

容器内的 DPDK 应用使用 vhost-user PMD：

```bash
# 容器内启动 DPDK 应用
dpdk-testpmd -l 0-1 --no-pci -- \
    --vdev net_virtio_user0,path=/var/run/vhost/pod-a.sock,server=1 \
    -- -i
```

---

## 4. 路径 2：SR-IOV VF 直通

### 4.1 架构

```text
┌──────────────────────────────────────────────────────────┐
│                        Host                               │
│                                                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │  Pod A   │  │  Pod B   │  │  Pod C   │  │  Host   │ │
│  │ DPDK App │  │ DPDK App │  │ Kernel   │  │ 管理    │ │
│  │   VF0    │  │   VF1    │  │   VF2    │  │   PF    │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬────┘ │
│       │              │              │              │      │
│  ┌────▼──────────────▼──────────────▼──────────────▼───┐ │
│  │              E-Switch (硬件内部)                     │ │
│  │   硬件转发表 / ACL / VLAN / 隧道                    │ │
│  └──────────────────────┬─────────────────────────────┘ │
│                         │                                │
│                   Physical Port                          │
└─────────────────────────┼────────────────────────────────┘
                          │
                        wire
```

### 4.2 SR-IOV Network Operator

推荐使用 SR-IOV Network Operator 管理 VF 生命周期：

```text
SR-IOV Network Operator 管理链：

SriovNetworkNodePolicy         SriovNetwork              Pod
  (哪些 NIC 分配 VF)            (如何连接网络)            (使用 VF)
        │                           │                      │
        ▼                           ▼                      ▼
  SR-IOV Device Plugin         SR-IOV CNI            VF 出现在
  · 发现 VF 资源                · 将 VF 移入           容器中
  · 注册为 K8s 资源              Pod 的网络命名空间
  · 分配给 Pod
```

SriovNetworkNodePolicy 示例：

```yaml
# 配置节点上的 SR-IOV VF
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: dpdk-vf-policy
  namespace: sriov-network-operator
spec:
  resourceName: intel_nic_dpdk # Device Plugin 资源名
  nodeSelector:
    kubernetes.io/os: linux
  numVfs: 8 # 该 PF 分配 8 个 VF
  nicSelector:
    vendor: "8086" # Intel
    deviceID: "158b" # E810 设备 ID
    pfNames: ["ens2f0"]
  deviceType:
    vfio-pci # DPDK 模式：绑定到 vfio-pci
    # netdevice = 内核模式
```

> [!info] deviceType 决定 VF 的使用方式
>
> - `vfio-pci`：VF 绑定到 VFIO 驱动，DPDK 应用通过 `rte_eth_dev` 直接访问
> - `netdevice`：VF 使用内核驱动，应用通过 socket 访问
> - DPDK 场景 **必须** 使用 `vfio-pci`

SriovNetwork 示例：

```yaml
# 定义网络：Pod 如何通过 VF 接入
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: dpdk-network
  namespace: sriov-network-operator
spec:
  networkNamespace: default
  ipam: |
    {
      "type": "host-local",
      "subnet": "10.56.0.0/16",
      "rangeStart": "10.56.1.100",
      "rangeEnd": "10.56.1.200"
    }
  resourceName: intel_nic_dpdk # 对应 SriovNetworkNodePolicy
  vlan: 100 # 可选：VLAN tag
```

### 4.3 Pod 使用 SR-IOV VF

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-sriov-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: dpdk-network
spec:
  containers:
    - name: dpdk-app
      image: dpdk-app:latest
      securityContext:
        capabilities:
          add: ["IPC_LOCK", "NET_ADMIN", "SYS_RESOURCE"]
      resources:
        requests:
          hugepages-2Mi: "2Gi"
          memory: "2Gi"
          cpu: "4"
          intel.com/intel_nic_dpdk: "1" # 请求 1 个 VF
        limits:
          hugepages-2Mi: "2Gi"
          memory: "2Gi"
          cpu: "4"
          intel.com/intel_nic_dpdk: "1"
      volumeMounts:
        - name: hugepages
          mountPath: /dev/hugepages
  volumes:
    - name: hugepages
      emptyDir:
        medium: HugePages
```

容器内 DPDK 应用直接使用 VF：

```bash
# VF 已经通过 SR-IOV CNI 移入容器的网络命名空间
# 绑定到 vfio-pci 驱动
# DPDK 应用直接使用 PCI 地址

dpdk-testpmd -l 0-3 -n 4 -- \
    -a 0000:3d:00.2 \        # VF 的 PCI 地址（自动发现）
    -- -i
```

### 4.4 SR-IOV 的局限

| 局限                  | 说明                                              |
| --------------------- | ------------------------------------------------- |
| VF 数量有限           | 通常 32-256 个/VF，受 NIC 硬件限制                |
| 无虚拟交换            | Pod 间通信需要经过 E-Switch 或外部交换机          |
| VF 热迁移困难         | VF 绑定到特定 NUMA node，Pod 迁移时 VF 不可迁移   |
| 设备管理复杂          | Operator + Device Plugin + CNI 三层协调           |
| 不支持 Pod 间本地通信 | 两个 VF 在同一 host 上也需要经过 E-Switch 或 wire |

---

## 5. 路径 3：AF_XDP PMD

### 5.1 为什么 AF_XDP 适合容器

AF_XDP PMD 的优势正好解决了容器的痛点：

```text
  不需要 VFIO      → 容器中不需要 privileged 模式
  不需要独占网卡    → 不影响其他 Pod 和宿主机网络
  不需要 SR-IOV    → 任何支持 XDP 的网卡都能用
  标准 DPDK API    → 应用代码不用改
```

详细原理见 [[2026-04-09-dpdk-deep-dive-ch38-dpdk-ebpf|ch38：eBPF/XDP 与 DPDK 协同]]，
这里只讲容器场景的特殊配置。

### 5.2 容器中使用 AF_XDP PMD

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-afxdp-pod
spec:
  containers:
    - name: dpdk-app
      image: dpdk-app:latest
      securityContext:
        capabilities:
          add: ["IPC_LOCK", "NET_ADMIN", "NET_RAW", "BPF"]
      resources:
        requests:
          hugepages-2Mi: "1Gi"
          memory: "1Gi"
          cpu: "2"
        limits:
          hugepages-2Mi: "1Gi"
          memory: "1Gi"
          cpu: "2"
      volumeMounts:
        - name: hugepages
          mountPath: /dev/hugepages
  volumes:
    - name: hugepages
      emptyDir:
        medium: HugePages
```

容器内启动：

```bash
# AF_XDP PMD 不需要 PCI 设备
dpdk-testpmd -l 0-1 --no-pci -- \
    --vdev net_af_xdp,iface=eth0,start_queue=0,queue_count=1 \
    -- -i
```

### 5.3 AF_XDP vs 其他路径

| 维度           | AF_XDP PMD           | vhost-user + OVS    | SR-IOV VF             |
| -------------- | -------------------- | ------------------- | --------------------- |
| 性能           | 中高（~15-25 Mpps）  | 中（~10-15 Mpps）   | 最高（~30+ Mpps）     |
| 延迟           | 中低                 | 中                  | 最低                  |
| 硬件要求       | 任何 XDP capable NIC | 不限                | SR-IOV capable NIC    |
| 网卡独占       | **不独占**           | OVS 独占            | Pod 独占 VF           |
| 内核协议栈共存 | ✅                   | ❌（OVS 接管）      | ✅（PF 走内核）       |
| 部署复杂度     | 最低                 | 高（OVS 部署+配置） | 高（Operator+Plugin） |
| 运维复杂度     | 最低                 | 高（OVS 调优）      | 中（VF 生命周期管理） |
| 适合场景       | 云环境、混合部署     | NFV、多租户虚拟交换 | 极致性能 CNF          |

---

## 6. Multus：多网络接口编排

### 6.1 为什么需要 Multus

标准 K8s 每个 Pod 只有一个网络接口（eth0）。DPDK Pod 通常需要 **两个网络**：

- **eth0**：管理网络（SSH、监控、日志）——走标准 veth pair
- **net1**：数据网络（DPDK 高速收发）——走 vhost-user / SR-IOV / AF_XDP

Multus 是 CNI meta-plugin，允许 Pod 同时拥有多个网络接口。

### 6.2 工作原理

```text
kubelet 创建 Pod
    │
    ▼
Multus (CNI meta-plugin)
    │
    ├── 调用默认 CNI（calico/flannel）→ eth0（管理网络）
    │
    └── 读取 annotations 中的网络列表
        │
        ├── 调用 SR-IOV CNI → net1（VF 直通）
        └── 调用 OVS CNI   → net2（vhost-user）

  最终 Pod 有 3 个接口：eth0 + net1 + net2
```

### 6.3 NetworkAttachmentDefinition

```yaml
# 定义一个 SR-IOV DPDK 网络
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: sriov-dpdk-net
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "name": "sriov-dpdk",
      "type": "sriov",
      "ipam": {
        "type": "host-local",
        "subnet": "10.56.0.0/16"
      }
    }
```

### 6.4 Pod 使用多网络

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cnf-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [
        {
          "name": "sriov-dpdk-net",
          "namespace": "default",
          "interface": "net1"
        }
      ]
spec:
  containers:
    - name: cnf-app
      image: cnf-app:latest
      resources:
        requests:
          hugepages-2Mi: "2Gi"
          cpu: "4"
          intel.com/intel_nic_dpdk: "1"
        limits:
          hugepages-2Mi: "2Gi"
          cpu: "4"
          intel.com/intel_nic_dpdk: "1"
      volumeMounts:
        - name: hugepages
          mountPath: /dev/hugepages
  volumes:
    - name: hugepages
      emptyDir:
        medium: HugePages
```

> [!info] Pod 内的网络接口
>
> - `eth0`：由默认 CNI（calico 等）创建，用于管理流量
> - `net1`：由 Multus 调用 SR-IOV CNI 创建，DPDK 应用使用此接口
> - 两个网络完全隔离，互不影响

---

## 7. CNF 性能调优最佳实践

### 7.1 容器运行时性能检查清单

```text
□ 1. CPU Manager: static 策略
     kubelet --cpu-manager-policy=static

□ 2. Topology Manager: restricted 或 single-numa-node
     kubelet --topology-manager-policy=restricted

□ 3. Guaranteed QoS
     Pod 的 requests == limits（所有资源）

□ 4. 整数 CPU
     cpu: "4"（不是 "4.5" 或 "500m"）

□ 5. Hugepage 预分配
     节点上 hugepage 数量满足 Pod 请求

□ 6. NUMA 对齐
     CPU、hugepage、NIC 在同一 NUMA node

□ 7. IRQ 亲和
     网卡中断离开 DPDK 核心
     irqbalance 关闭或配置 ban list

□ 8. CPU 性能模式
     cpupower frequency-set -g performance

□ 9. 容器特权
     CAP_IPC_LOCK（hugepage mmap）
     CAP_NET_ADMIN（网络配置）
     CAP_SYS_RESOURCE（如需要）
     CAP_BPF + CAP_NET_RAW（AF_XDP 场景）

□ 10. 镜像优化
      最小化容器镜像，减少启动时间
      预编译 DPDK 应用，不依赖开发工具
```

### 7.2 容器对 DPDK 性能的影响

```text
容器带来的额外开销：

  · 命名空间切换：几乎为零（cgroups v2 优化后）
  · 网络命名空间：不影响 VFIO 直通（设备直接在容器中）
  · cgroup CPU 限制：static 策略下无影响（独占核心）
  · seccomp：默认 profile 不影响 DPDK（但需要确认）
  · hugepage 访问：通过 emptyDir 挂载，无额外开销
  · VFIO 访问：通过 Device Plugin，设备文件直接出现在容器中

  结论：正确配置后，容器中 DPDK 的性能与裸金属差异 < 5%。
  主要差异来自：
  · 容器镜像拉取和启动延迟（不影响运行时）
  · K8s 调度延迟（Pod 重启时需要重新调度）
  · 日志和监控的 sidecar 可能占用少量 CPU
```

### 7.3 Pod 级 DPDK 参数调优

```yaml
spec:
  containers:
    - name: dpdk-app
      env:
        # DPDK EAL 参数（通过环境变量传入）
        - name: DPDK_ARGS
          value: "-l 0-3 -n 4 --file-prefix=containerized"

        # 指定 hugepage 挂载路径
        - name: RTE_HUGEPAGE_DIR
          value: "/dev/hugepages"

      # 启动命令
      command: ["/bin/sh", "-c"]
      args:
        - |
          # 确保 VFIO 设备可访问
          ls /dev/vfio/

          # 启动 DPDK 应用
          ./my-dpdk-app $(DPDK_ARGS) \
            -a $(PCI_DEV) \
            -- -p 0x1
```

---

## 8. 常见问题与排障

| 现象                          | 可能原因                                      | 排查方向                                   |
| ----------------------------- | --------------------------------------------- | ------------------------------------------ |
| Pod 启动失败：hugepage 不足   | 节点 hugepage 已被其他 Pod 占满               | `kubectl describe node` 看 hugepage 分配   |
| VF 不出现在容器中             | SR-IOV Operator 未配置或 Device Plugin 未运行 | 检查 SriovNetworkNodePolicy 状态           |
| DPDK 初始化失败：no hugepages | hugepage 未挂载到容器                         | 检查 volumes.emptyDir.medium = HugePages   |
| vhost-user 连接失败           | Socket 文件不存在或权限不对                   | 检查 OVS 端口和 socket 路径                |
| DPDK 性能低于预期             | NUMA 不对齐、CPU 未独占、IRQ 干扰             | 检查 Topology Manager、CPU Manager 状态    |
| AF_XDP PMD 收不到包           | 内核不支持 XDP 或容器无 BPF 权限              | 检查内核版本、capabilities                 |
| Pod 重启后 VF 消失            | SR-IOV Device Plugin 未回收 VF                | 检查 Operator 日志、VF 状态                |
| OVS-DPDK 端口统计全零         | PMD CPU mask 未正确设置                       | `ovs-appctl dpif-netdev/pmd-rxq-show`      |
| 多 Pod 互相不能通信           | E-Switch/bridge 缺少转发规则                  | 检查 OVS flow 或 E-Switch representor 配置 |
| 容器内看不到 PCI 设备         | Device Plugin 未正确分配                      | `kubectl describe pod` 看资源分配          |

---

## 9. 总结

```text
容器中运行 DPDK 的核心要素：

  硬件访问 ──── Device Plugin / VFIO / vhost-user socket
  内存 ──────── Hugepage（emptyDir + medium: HugePages）
  CPU ───────── CPU Manager static + Topology Manager
  网络 ──────── Multus + CNI（SR-IOV / OVS / AF_XDP）

  三条路径：
  ┌──────────────┬─────────────┬──────────────┐
  │ vhost-user   │  SR-IOV VF  │  AF_XDP PMD  │
  │ + OVS-DPDK   │  直通       │  不独占网卡   │
  │              │             │              │
  │ 灵活+虚拟交换│ 极致性能    │ 最低门槛      │
  │ 中等性能     │ VF 数量受限  │ 中高性能      │
  │ 高运维复杂度 │ 高部署复杂度 │ 低运维复杂度  │
  └──────────────┴─────────────┴──────────────┘
```

关键要点：

1. **三条路径不是互斥的**——同一集群可以混用：管理网走 veth，数据网走 SR-IOV
2. **Hugepage 是前提**——所有路径都需要，必须预分配并通过 Pod resources 请求
3. **CPU 独占是性能保障**——static 策略 + Guaranteed QoS + 整数 CPU
4. **NUMA 对齐决定实际性能**——Topology Manager single-numa-node 最严格但最安全
5. **vhost-user-client 比 vhost-user 更健壮**——OVS 重启不影响 Pod
6. **AF_XDP 是云环境的新选择**——不独占网卡、部署简单、性能够用
7. **Multus 解决多网络需求**——管理网 + 数据网分离

> **容器中运行 DPDK 最重要的不是选哪条路径，而是先把基础设施（hugepage、CPU、NUMA、Device Plugin）配对，再根据场景选路径。基础设施不对，哪条路径都不会有好性能。**

---

## 参考资料

### Kubernetes + DPDK

- [Kubernetes Device Plugin Framework](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- [Kubernetes CPU Manager](https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/)
- [Kubernetes Topology Manager](https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/)
- [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni)

### SR-IOV

- [SR-IOV Network Operator](https://github.com/k8snetworkplumbingwg/sriov-network-operator)
- [SR-IOV CNI](https://github.com/k8snetworkplumbingwg/sriov-cni)
- [SR-IOV Device Plugin](https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin)

### OVS-DPDK

- [OVS with DPDK](https://docs.openvswitch.org/en/latest/intro/install/dpdk/)
- [OVS vhost-user](https://docs.openvswitch.org/en/latest/topics/dpdk/vhost-user/)
- [DPDK virtio-user PMD](https://doc.dpdk.org/guides-26.03/nics/virtio.html)

### AF_XDP

- [DPDK AF_XDP PMD](https://doc.dpdk.org/guides-26.03/nics/af_xdp.html)
- [AF_XDP Kernel Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)

### CNF 最佳实践

- [CNF Test Suite](https://github.com/cncf/cnf-testsuite)
- [NFD (Node Feature Discovery)](https://github.com/kubernetes-sigs/node-feature-discovery)
- [ANANKE — DPDK Container Networking](https://doc.dpdk.org/guides-26.03/howto/containers.html)
