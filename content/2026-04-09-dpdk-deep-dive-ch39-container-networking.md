---
title: "DPDK 第三十九章：容器网络 DPDK-CNI、OVS-DPDK"
date: 2026-04-09 16:40:00
tags: [dpdk, container, kubernetes, cni, ovs-dpdk, pod, networking]
description: "深入解析容器网络与 DPDK 的集成：DPDK-CNI、OVS-DPDK、Multus、SR-IOV CNI 与高性能容器网络"
---

# DPDK 第三十九章：容器网络 DPDK-CNI、OVS-DPDK

> [!abstract] 核心要点
> 容器化 DPDK 应用需要特殊的 CNI 插件和网络配置。本章解析 DPDK-CNI、OVS-DPDK、Multus 和 SR-IOV CNI 的集成方案。

## 1. 容器网络概述

### 1.1 传统容器网络 vs DPDK 容器网络

**传统容器网络**：

```
┌──────────────────────────────────────────────────────────┐
│                     Host Namespace                       │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │   Pod A    │    │   Pod B    │    │   Pod C    │   │
│  │  eth0 (veth)│    │  eth0 (veth)│    │  eth0 (veth)│   │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘   │
│         │                  │                  │          │
│         └──────────────────┼──────────────────┘          │
│                            ▼                             │
│                    ┌──────────────┐                      │
│                    │  veth bridge │                      │
│                    └──────┬──────┘                      │
│                           ▼                              │
│                    ┌──────────────┐                      │
│                    │   eth0      │                      │
│                    └──────────────┘                      │
└──────────────────────────────────────────────────────────┘
```

**DPDK 容器网络**：

```
┌──────────────────────────────────────────────────────────┐
│                     Host Namespace                       │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│  │   Pod A    │    │   Pod B    │    │   Pod C    │  │
│  │ DPDK App   │    │ DPDK App   │    │   Normal    │  │
│  │   (hugepage│    │   (hugepage│    │   (veth)   │  │
│  │   mem)     │    │   mem)     │    │            │  │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘  │
│         │                  │                  │         │
│         └──────────────────┼──────────────────┘         │
│                            ▼                             │
│  ┌─────────────────────────────────────────────────────┐│
│  │           OVS-DPDK / DPDK-CNI                       ││
│  │    (pods attach to DPDK-based switch)               ││
│  └─────────────────────┬───────────────────────────────┘│
│                        ▼                                 │
│                 ┌──────────────┐                          │
│                 │   eth0 (PF)  │                          │
│                 └──────────────┘                          │
└──────────────────────────────────────────────────────────┘
```

### 1.2 核心挑战

| 挑战             | 说明                       | 解决方案                   |
| ---------------- | -------------------------- | -------------------------- |
| **Hugepages**    | Pod 需要访问 hugepage 内存 | 安全上下文/hostPath        |
| **设备访问**     | VF/设备透传                | Device Plugin / SR-IOV CNI |
| **网络命名空间** | Pod 独立的网络栈           | CNI 实现                   |
| **多租户**       | 隔离与资源共享             | Resource limits            |

## 2. DPDK-CNI

### 2.1 概述

DPDK-CNI 是 Kubernetes CNI 插件，让 Pod 直接使用 DPDK：

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK-CNI Flow                           │
│                                                              │
│  1. Kubelet calls CNI ADD for Pod                          │
│  2. DPDK-CNI:                                               │
│     - Allocates memseg from hugepages                       │
│     - Creates vhost-user socket                            │
│     - Configures OVS port                                   │
│  3. DPDK App in Pod connects to socket                     │
│  4. Packets flow: NIC → OVS → vhost → Pod                  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 安装 DPDK-CNI

```bash
# 克隆 DPDK-CNI
git clone https://github.com/Intel-Corp/DPDK-CNI.git
cd DPDK-CNI

# 编译
make
sudo make install

# 安装 CNI 配置
sudo mkdir -p /etc/cni/net.d
sudo cp 70-dpdk.conf /etc/cni/net.d/

# 配置示例（/etc/cni/net.d/70-dpdk.conf）
{
    "cniVersion": "0.4.0",
    "name": "dpdk-network",
    "type": "dpdk",
    "ipam": {
        "type": "host-local",
        "subnet": "10.244.0.0/16"
    },
    "dpdk": {
        "socketPath": "/var/run/openvswitch/",
        "dev": "eth0"
    }
}
```

### 2.3 配置 Pod 使用 DPDK

```yaml
# dpdk-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-app
  annotations:
    k8s.v1.cni.cncf.io/networks: dpdk-network
spec:
  containers:
    - name: dpdk-app
      image: dpdk-test:latest
      securityContext:
        privileged: true # 需要特权才能访问 hugepages
      resources:
        requests:
          hugepages-2Mi: 1Gi
          memory: 2Gi
          cpu: "2"
        limits:
          hugepages-2Mi: 1Gi
          memory: 2Gi
          cpu: "2"
      volumeMounts:
        - name: hugepgs
          mountPath: /hugepages
  volumes:
    - name: hugepgs
      emptyDir:
        medium: HugePages
```

### 2.4 DPDK-CNI 工作原理

```go
// DPDK-CNI 主要逻辑（简化）
func cmdAdd(args *skel.CmdArgs) error {
    // 1. 解析配置
    config, err := parseConfig(args.StdinData)

    // 2. 分配 hugepage 内存
    mem, err := allocateHugepages(config.MemorySize)

    // 3. 创建 vhost-user 设备
    vhostDev := fmt.Sprintf("%s/%s.sock", config.SocketPath, args.ContainerID)
    err = createVhostUserDevice(vhostDev)

    // 4. 添加到 OVS
    if config.DPDKMode == "ovs" {
        err = ovsAddPort(config.Bridge, vhostDev, args.IfName)
    }

    // 5. 分配 IP
    ip, err := allocateIP(config.IPAM, args.IfName)

    // 6. 配置网络命名空间
    err = setupNamespace(args.Netns, args.IfName, ip)

    return nil
}
```

## 3. OVS-DPDK

### 3.1 OVS-DPDK 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      OVS-DPDK                              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   vswitchd (OVS)                      │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │  │
│  │  │  OpenFlow   │  │   OVSDB    │  │  Netlink    │   │  │
│  │  │  Controller │  │   (config)  │  │  (kernel)   │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘   │  │
│  └──────────────────────────┬───────────────────────────┘  │
│                             │                               │
│  ┌─────────────────────────▼───────────────────────────┐  │
│  │               DPDK (PMD threads)                     │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐│  │
│  │  │  PMD 0  │  │  PMD 1  │  │  PMD 2  │  │  PMD N  ││  │
│  │  │ (lcore) │  │ (lcore) │  │ (lcore) │  │ (lcore) ││  │
│  │  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘│  │
│  └───────┼────────────┼────────────┼────────────┼─────┘  │
│          │            │            │            │         │
│  ┌───────▼────────────▼────────────▼────────────▼──────┐  │
│  │                   DPDK Ports                         │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │  │
│  │  │ dpdk-p0 │  │dpdk-p1  │  │vhostuser-│            │  │
│  │  │(phy)    │  │(phy)    │  │client-0 │            │  │
│  │  └─────────┘  └─────────┘  └─────────┘            │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 安装 OVS-DPDK

```bash
# 1. 安装依赖
sudo apt install -y build-essential pkg-config \
    python3 libunbound-dev libsodium-dev \
    libssl-dev libcap-dev libunwind-dev \
    liblz4-dev liblzma-dev

# 2. 克隆 OVS
git clone https://github.com/openvswitch/ovs.git
cd ovs

# 3. 配置（启用 DPDK）
./boot.sh
./configure --with-dpdk=shared \
    CFLAGS="-g -O2" \
    RTE_SDK=$DPDK_PATH \
    RTE_TARGET=$DPDK_TARGET

# 4. 编译
make -j$(nproc)
sudo make install

# 5. 设置 hugepages
echo 4 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
```

### 3.3 启动 OVS-DPDK

```bash
# 1. 初始化 OVS
ovsdb-tool create /etc/openvswitch/conf.db \
    vswitchd/vswitch.ovsschema

# 2. 启动 ovsdb-server
ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    --private-key=db:Open_vSwitch,SSL,private_key \
    --certificate=db:Open_vSwitch,SSL,certificate \
    --bootstrap-ca-cert=db:Open_vSwitch,SSL,ca_cert \
    --detach

# 3. 初始化数据库
ovs-vsctl --db=unix:/var/run/openvswitch/db.sock init

# 4. 启动 vswitchd（DPDK 模式）
ovs-vswitchd --dpdk -c 0x1 -n 4 \
    --socket-mem 1024,1024 \
    -- unix:/var/run/openvswitch/db.sock \
    --pidfile \
    --detach

# 5. 查看状态
ovs-vsctl show
ovs-vsctl get Open_vSwitch . dpdk_initialized
```

### 3.4 配置 OVS-DPDK 端口

```bash
# 1. 添加 DPDK 物理端口
ovs-vsctl add-port br0 dpdk0 \
    -- set Interface dpdk0 type=dpdk \
    options:dpdk-devargs=0000:3d:00.0

# 2. 添加 vhost-user 端口（供 Pod 使用）
ovs-vsctl add-port br0 vhost-client-0 \
    -- set Interface vhost-client-0 type=dpdkvhostuserclient \
    options:vhost-server-path=/var/run/vhost/centos:pod1.sock

# 3. 配置 OpenFlow 规则
ovs-ofctl add-flow br0 "in_port=1,actions=output:2"
ovs-ofctl add-flow br0 "in_port=2,actions=output:1"

# 4. 查看端口状态
ovs-vsctl list-ports br0
ovs-ofctl show br0
```

## 4. Multus CNI

### 4.1 Multus 概述

Multus 是 Kubernetes CNI 调度器，支持将多个网络接口分配给 Pod：

```
┌─────────────────────────────────────────────────────────────┐
│                        Pod                                  │
│  ┌────────────────┐  ┌────────────────┐                    │
│  │   eth0 (default)│  │  eth1 (DPDK)   │                    │
│  │   (calico/flannel│ │ (dpdk-cni)   │                    │
│  └────────┬───────┘  └────────┬───────┘                   │
└────────────┼──────────────────┼───────────────────────────┘
             │                  │
             ▼                  ▼
┌─────────────────────────────────────────────────────────────┐
│                      Host Network                           │
│                                                              │
│  ┌────────────────┐      ┌────────────────┐                 │
│  │  calico bridge │      │  OVS-DPDK      │                 │
│  └────────────────┘      └────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 安装 Multus

```bash
# 1. 下载 Multus
git clone https://github.com/k8snetworkplumbingwg/multus-cni.git
cd multus-cni

# 2. 编译
make
sudo make install

# 3. 安装（使用 kustomize）
kubectl apply -k deployments/

# 4. 确认运行
kubectl get pods -n kube-system | grep multus
```

### 4.3 配置 DPDK 网络 CRD

```yaml
# dpdk-network.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: dpdk-net
spec:
  config: '{
      "cniVersion": "0.4.0",
      "name": "dpdk-network",
      "type": "ovs-dpdk",
      "bridge": "br0",
      "vxlanID": 100,
      "logFile": "/var/log/openvswitch/ovn",
      "logLevel": "info",
      "dpdk": {
        "socketPath": "/var/run/openvswitch",
        "dev": "0000:3d:00.0"
      }
  }'
```

### 4.4 Pod 使用 DPDK 网络

```yaml
# dpdk-pod-multus.yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: '[
      {
        "name": "dpdk-net",
        "namespace": "default",
        "interface": "eth1"
      }
    ]'
spec:
  containers:
  - name: dpdk
    image: dpdk-app:latest
    securityContext:
      privileged: true
    resources:
      requests:
        hugepages-2Mi: 2Gi
        memory: 4Gi
        cpu: "4"
      limits:
        hugepages-2Mi: 2Gi
        memory: 4Gi
        cpu: "4"
    env:
    - name: DPDK_ARGS
      value: "-l 0-3 -m 1024 --file-prefix=vhost"
    volumeMounts:
    - name: hugepgs
      mountPath: /hugepages
    - name: vhost
      mountPath: /var/run/openvswitch
  volumes:
  - name: hugepgs
    emptyDir:
      medium: HugePages
  - name: vhost
    hostPath:
      path: /var/run/openvswitch
  restartPolicy: Never
```

## 5. SR-IOV CNI

### 5.1 SR-IOV CNI 概述

SR-IOV CNI 将 VF 直接分配给 Pod：

```
┌─────────────────────────────────────────────────────────────┐
│                         Host                                │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                 SR-IOV CNI                          │   │
│  │                                                      │   │
│  │  VF Pool Manager                                     │   │
│  │  - Allocates VFs to Pods                            │   │
│  │  - Manages VF lifecycle                             │   │
│  └─────────────────────────────────────────────────────┘   │
│                            │                                │
│  ┌─────────────────────────▼───────────────────────────┐   │
│  │               Physical Function (PF)                 │   │
│  └─────────────────────────────────────────────────────┘   │
│       │     │     │     │     │                            │
│       ▼     ▼     ▼     ▼     ▼                            │
│      VF0   VF1   VF2   VF3   VF4                           │
└──────┼─────┼─────┼─────┼─────┼──────────────────────────────┘
       │     │     │     │     │
       ▼     ▼     ▼     ▼     ▼
┌────┬────┬────┬────┬────┐
│Pod1│Pod2│Pod3│Pod4│Pod5│
└────┴────┴────┴────┴────┘
```

### 5.2 安装 SR-IOV CNI

```bash
# 1. 安装 SR-IOV 插件
git clone https://github.com/k8snetworkplumbingwg/sriov-cni.git
cd sriov-cni
make
sudo make install

# 2. 配置 kubecon
kubectl apply -f deployments/config.yaml

# 3. 创建 NetworkAttachmentDefinition
cat <<EOF | kubectl apply -f -
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: sriov-net
spec:
  networkNamespace: default
  ipam: '{"type":"host-local","subnet":"10.56.0.0/16"}'
  vlan: 100
  resourceName: intel_sriov
EOF
```

### 5.3 使用 SR-IOV VF

```yaml
# sriov-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: sriov-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: '[
      {
        "name": "sriov-net",
        "interface": "net1"
      }
    ]'
spec:
  containers:
  - name: app
    image: ubuntu:18.04
    command: ["sleep", "inf"]
    resources:
      limits:
        intel.com/intel_sriov: "1"  # 请求 1 个 VF
```

## 6. 实际案例：VPP CNI

### 6.1 VPP 容器网络

VPP (Vector Packet Processing) 是 CNCF 的高性能数据平面：

```bash
# 1. 安装 Contiv-VPP
kubectl apply -f https://raw.githubusercontent.com/contiv/vpp/master/deploy/k8s/1.17/contiv-vpp.yaml

# 2. 配置 VPP
cat <<EOF > /etc/contiv/config.json
{
  "ettelagen": "default",
  "vppMasterIf": "eth0",
  "vppUplinkOwner": "root"
}
EOF

# 3. Pod 自动使用 VPP
kubectl run --image=nginx nginx
```

## 7. 性能对比

| 方案           | 吞吐量   | 延迟  | CPU 开销 | 复杂度 |
| -------------- | -------- | ----- | -------- | ------ |
| **默认 veth**  | ~500Kpps | ~20us | 高       | 低     |
| **OVS-DPDK**   | ~10Mpps  | ~5us  | 中       | 中     |
| **DPDK-CNI**   | ~15Mpps  | ~3us  | 低       | 高     |
| **SR-IOV CNI** | ~30Mpps  | ~1us  | 极低     | 高     |

## 8. 总结

容器网络与 DPDK 的集成需要：

1. **DPDK-CNI**：Pod 通过 vhost-user 连接 DPDK
2. **OVS-DPDK**：高性能虚拟交换
3. **Multus**：多网络接口支持
4. **SR-IOV CNI**：VF 直通，极致性能

---

## 参考资源

- [DPDK-CNI GitHub](https://github.com/Intel-Corp/DPDK-CNI)
- [OVS-DPDK 文档](https://www.openvswitch.org/support/dist-docs/)
- [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni)
- [SR-IOV CNI](https://github.com/k8snetworkplumbingwg/sriov-cni)
