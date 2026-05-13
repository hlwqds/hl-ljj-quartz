---
title: "RDMA 第二十五章：Kubernetes RDMA——容器编排下的 RDMA"
date: 2026-04-13
tags:
  [rdma, kubernetes, k8s, device-plugin, rdma-shared, nvidia-rdma, gpu-direct, scheduler-extender]
description: "详解 Kubernetes 环境下 RDMA 的完整部署方案：RDMA Device Plugin、RDMA Shared Device Plugin、NVIDIA GPU Operator、调度器扩展、以及生产环境配置示例。"
---

> [!abstract] 核心要点
> Kubernetes 已成为 AI/HPC 工作负载的首选调度平台。本章系统讲解 Kubernetes 环境下 RDMA 能力的暴露、调度、和管理——从 Device Plugin 机制到 RDMA Shared Device Plugin，再到 GPU Direct RDMA 与 Kubernetes 的集成，以及生产环境部署的最佳实践。

---

## 1. Kubernetes RDMA 架构概述

### 1.1 为什么 Kubernetes 需要 RDMA

Kubernetes 最初设计目标是以容器形式运行无状态微服务，网络模型基于 TCP/IP。然而 AI/ML 训练和 HPC 工作负载需要 RDMA 的超低延迟和超高带宽：

```
Kubernetes + RDMA 架构：

  ┌─────────────────────────────────────────────────────────────────┐
  │                    Kubernetes Cluster                           │
  │  ┌─────────────────────────────────────────────────────────┐   │
  │  │                     Control Plane                        │   │
  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
  │  │  │   API       │  │  Scheduler  │  │ RDMA Scheduler  │  │   │
  │  │  │   Server    │  │  (extender) │  │    Extender     │  │   │
  │  │  └─────────────┘  └─────────────┘  └─────────────────┘  │   │
  │  └─────────────────────────────────────────────────────────┘   │
  │                                                                 │
  │  ┌─────────────────────────────────────────────────────────┐   │
  │  │                     Worker Nodes                         │   │
  │  │  ┌───────────────┐  ┌───────────────┐  ┌────────────┐  │   │
  │  │  │  Node A       │  │  Node B        │  │  Node C    │  │   │
  │  │  │  ┌─────────┐ │  │  ┌─────────┐   │  │ ┌────────┐ │  │   │
  │  │  │  │GPU│RDMA │ │  │  │GPU│RDMA │   │  │ │GPU│RDMA│ │  │   │
  │  │  │  └─────────┘ │  │  └─────────┘   │  │ └────────┘ │  │   │
  │  │  │  RDMA Device │ │  │ RDMA Device  │  │ │RDMA Dev │  │   │
  │  │  │    Plugin    │ │  │   Plugin     │  │ │ Plugin   │  │   │
  │  │  └───────────────┘  └───────────────┘  └────────────┘  │   │
  │  └─────────────────────────────────────────────────────────┘   │
  └─────────────────────────────────────────────────────────────────┘
```

### 1.2 核心组件

Kubernetes RDMA 部署涉及以下核心组件：

```
核心组件及其职责：

  1. RDMA Device Plugin
     - 发现节点上的 RDMA 设备
     - 向 Kubernetes 报告 RDMA 资源 (rdma/hca)
     - 为 Pod 分配 RDMA 设备

  2. CNI Plugin (参见第 24 章)
     - 为 Pod 配置 RDMA 网络接口
     - IP 地址分配

  3. RDMA Shared Device Plugin
     - 支持多个容器共享同一个 RDMA 设备
     - 动态资源分配

  4. NVIDIA GPU Operator (当 GPU + RDMA 时)
     - 统一管理 GPU 和 RDMA 设备
     - 配置 NCCL 插件

  5. RDMA Scheduler Extender
     - 调度时考虑 RDMA 设备可用性
     - 亲和性约束（GPU 与 RDMA 共置）
```

---

## 2. RDMA Device Plugin

### 2.1 Kubernetes Device Plugin 机制

Device Plugin 是 Kubernetes 扩展机制，让节点向 API Server 报告硬件资源（如 GPU、FPGA、RDMA）：

```
Device Plugin 工作流程：

  1. 注册 (Register)
     Device Plugin 启动时向 kubelet 注册，声明要管理的设备类型

  2. 清单 (ListAndWatch)
     定期向 kubelet 报告可用设备列表

  3. 分配 (Allocate)
     当 Pod 请求设备时，kubelet 调用 Device Plugin 的 Allocate 方法
     Device Plugin 返回设备信息（如 /dev/infiniband/uverbs0）

  4. 监控 (Monitor)
     Device Plugin 监控设备健康状态，异常时更新设备列表
```

### 2.2 RDMA Device Plugin 源码解析

```go
// RDMA Device Plugin 主要结构
package main

import (
    "github.com/k8snetworkplumbingwg/sriov-network-device-plugin/pkg/plugin"
    "golang.org/x/net/context"
    "google.golang.org/grpc"
    pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"
)

// RDMADevicePlugin 实现设备插件接口
type RDMADevicePlugin struct {
    devices     []string           // RDMA 设备列表
    socketPath  string             // Unix socket 路径
    resourceName string           // 资源名称 (rdma/hca)
}

func (p *RDMADevicePlugin) GetDevicePluginOptions(ctx context.Context,
    empty *pluginapi.Empty) (*pluginapi.DevicePluginOptions, error) {
    return &pluginapi.DevicePluginOptions{
        // 支持 Pod 级别的设备分配
        AllowReAllocation: true,
    }, nil
}

func (p *RDMADevicePlugin) PreStartContainer(ctx context.Context,
    request *pluginapi.PreStartContainerRequest) (*pluginapi.PreStartContainerResponse, error) {
    // 容器启动前的钩子，可用于重置设备状态
    return &pluginapi.PreStartContainerResponse{}, nil
}

func (p *RDMADevicePlugin) ListAndWatch(empty *pluginapi.Empty,
    stream pluginapi.DevicePlugin_ListAndWatchServer) error {
    // 定期更新可用设备列表
    for {
        devices := p.discoverRDMADevices()
        stream.Send(&pluginapi.ListAndWatchResponse{
            Devices: devices,
        })
        time.Sleep(5 * time.Second)
    }
}

func (p *RDMADevicePlugin) Allocate(ctx context.Context,
    request *pluginapi.AllocateRequest) (*pluginapi.AllocateResponse, error) {
    // 分配设备给容器
    response := pluginapi.AllocateResponse{}
    for _, req := range request.ContainerRequests {
        devices := p.allocateDevices(req.DevicesIDs)
        response.ContainerResponses = append(response.ContainerResponses,
            &pluginapi.ContainerAllocateResponse{
                Envs: map[string]string{
                    "RDMA_DEVICE": "/dev/infiniband/uverbs0",
                },
                Mounts: []*pluginapi.Mount{
                    {HostPath: "/dev/infiniband", ContainerPath: "/dev/infiniband", Mode: "r"},
                },
            })
    }
    return &response, nil
}
```

### 2.3 部署 RDMA Device Plugin

```yaml
# rdma-device-plugin.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: rdma-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: rdma-device-plugin
  template:
    metadata:
      labels:
        name: rdma-device-plugin
    spec:
      hostNetwork: true
      nodeSelector:
        feature.node.kubernetes.io/rdma: "true"
      containers:
        - name: rdma-plugin
          image: rdma-device-plugin:latest
          securityContext:
            privileged: true
          volumeMounts:
            - name: dev
              mountPath: /dev
            - name: sys
              mountPath: /sys
            - name: cni
              mountPath: /opt/cni/bin
          env:
            - name: RDMA_RESOURCE_NAME
              value: "rdma.hca"
            - name: RDMA_DEVICE_TYPE
              value: "nvidia" # 或 "mellanox"
      volumes:
        - name: dev
          hostPath:
            path: /dev
        - name: sys
          hostPath:
            path: /sys
        - name: cni
          hostPath:
            path: /opt/cni/bin
      tolerations:
        - operator: Exists
```

```bash
# 部署
kubectl apply -f rdma-device-plugin.yaml

# 验证
$ kubectl describe node <node-name> | grep rdma
  rdma/hca    4   # 4 个 RDMA 设备可用

# 查看设备插件日志
$ kubectl logs -n kube-system rdma-device-plugin-xxxxx
I0414 10:00:00.000001 device_plugin.go:150] Starting RDMA device plugin
I0414 10:00:00.000002 device_plugin.go:180] Found 2 RDMA devices: [mlx5_0 mlx5_1]
I0414 10:00:00.000003 device_plugin.go:200] Registered RDMA device plugin
```

---

## 3. RDMA Shared Device Plugin

### 3.1 为什么需要共享设备插件

标准 Device Plugin 将整个 RDMA 设备分配给单个 Pod。但在 Kubernetes 中：

```
共享场景：

  1. 多容器共享同一网卡
     - 同一个 Pod 内可能有多个容器使用 RDMA
     - 需要共享设备句柄

  2. 资源fractional 分配
     - 100Gbps 网卡可以分给 4 个容器，每个 25Gbps
     - 当前 Kubernetes 不原生支持

  3. 动态资源分配
     - 按需分配，而不是预分配
```

RDMA Shared Device Plugin 解决了这些问题。

### 3.2 NVIDIA RDMA Shared Device Plugin

```yaml
# nvidia-rdma-shared-device-plugin.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-rdma-shared-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-rdma-shared-device-plugin
  template:
    metadata:
      labels:
        name: nvidia-rdma-shared-device-plugin
    spec:
      hostNetwork: true
      containers:
        - name: plugin
          image: nvcr.io/nvidia/k8s-device-plugin:v0.13.0
          args: ["--mig-strategy=combined", "--rdma-shared-device-plugin"]
          securityContext:
            capabilities:
              add: ["IPC_LOCK"]
          resources:
            limits:
              memory: "200Mi"
              cpu: "500m"
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
            - name: dev
              mountPath: /dev
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: dev
          hostPath:
            path: /dev
```

### 3.3 请求共享 RDMA 设备

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rdma-shared-pod
spec:
  containers:
    - name: main
      image: nvidia/cuda:11.8-runtime-ubi8
      resources:
        limits:
          rdma/shared-nvidia: "1" # 请求 1 个共享 RDMA 设备
          nvidia.com/gpu: 2
      env:
        - name: NCCL_SHARED_RDMA
          value: "1"
        - name: NCCL_IB_HCA
          value: "mlx5_0,mlx5_1"
```

### 3.4 共享模式工作原理

```
RDMA Shared Device Plugin 架构：

  ┌──────────────────────────────────────────────────────────────┐
  │                      RDMA Shared Plugin                      │
  │                                                               │
  │  /var/lib/kubelet/device-plugins/                            │
  │  ├── rdma-shared.sock                                        │
  │  └── nvidia-rdma-shared                                      │
  │       └── config.json                                        │
  │                                                               │
  │  共享策略：                                                   │
  │    - 单个 RDMA 设备可以被多个容器使用                         │
  │    - 容器获得 /dev/infiniband/uverbsX 访问权限                │
  │    - 每个容器有独立的 GID（从共享池分配）                   │
  └──────────────────────────────────────────────────────────────┘

  容器内视角：
    /dev/infiniband/uverbs0 (同一物理设备，多个容器共享)
    每个容器有不同的 lkey/rkey
```

---

## 4. NVIDIA GPU Operator 与 RDMA

### 4.1 GPU Operator 概述

NVIDIA GPU Operator 自动管理 GPU 驱动的生命周期，在 Kubernetes 中部署 RDMA 时经常配合使用：

```yaml
# GPU Operator 部署（包含 RDMA 支持）
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator
  namespace: operators
spec:
  channel: stable
  name: gpu-operator
  source: operatorhub-io-catalog
```

```bash
# 使用 Helm 部署 GPU Operator
helm install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    --set driver.rdma=true \
    --set driver.repository=nvidia/drivers \
    --set toolkit.enabled=true \
    --set toolkit.version=v0.13.0
```

### 4.2 RDMA 与 GPU 的协同

AI 训练需要 GPU 与 RDMA 紧耦合：

```
GPU Direct RDMA + Kubernetes：

  Container
  ┌───────────────────────────────────────┐
  │  GPU Memory ←→ CUDA ↑                 │
  │                  │                     │
  │                  │ GPU Direct RDMA      │
  │                  ↓                     │
  │  ┌───────────────────────────────┐    │
  │  │  NCCL 通信                    │    │
  │  │  - GPU→GPU 通过 RDMA 直接传输 │    │
  │  │  - 无需 CPU 参与              │    │
  │  └───────────────────────────────┘    │
  │                  │                     │
  │                  │ PCIe ↑              │
  │  ┌───────────────▼───────────────┐    │
  │  │         HCA (ConnectX)       │    │
  │  └───────────────────────────────┘    │
  └───────────────────────────────────────┘
              ↓
         Network (RDMA)
```

### 4.3 NCCL 插件集成

```yaml
# nvidia-device-plugin 配置 (NCCL + RDMA)
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-container-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    nvidia:
     features:
        plugin:
          kind: nvidia
          config:
            nvidia:
              rdma:
                enabled: true
                devices: all
            nccl:
              provider: rdma
              transport:
                - IB
                - CUDA
---
apiVersion: v1
kind: Pod
metadata:
  name: nccl-test
spec:
  nodeSelector:
    nvidia.com/gpu: "true"
  containers:
    - name: nccl-test
      image: nvcr.io/nvidia/nccl-tests:11.0
      args: ["mpi_universe_size=2"]
      resources:
        limits:
          nvidia.com/gpu: 2
          rdma/hca: 1
      env:
        - name: NCCL_IB_HCA
          value: "mlx5_0,mlx5_1"
        - name: NCCL_NET_GDR_LEVEL
          value: "IB"
        - name: CUDA_VISIBLE_DEVICES
          value: "0,1"
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
```

---

## 5. RDMA 调度器扩展

### 5.1 为什么需要调度器扩展

Kubernetes 默认调度器不了解 RDMA 资源的拓扑和亲和性需求。AI 训练作业需要：

```
RDMA 调度需求：

  1. GPU-RDMA 共置
     - GPU 和 RDMA 设备必须在同一节点
     - 或在同一 NUMA 域

  2. RDMA 网络拓扑感知
     - 同一 GPU 集群的节点应调度在一起
     - 避免跨叶交换机的大流量

  3. 资源预留
     - 训练作业需要同时占用 GPU 和 RDMA
     - 避免部分资源被占用导致死锁

  4. 公平调度
     - 多个训练作业共享 RDMA 带宽
     - 避免单作业占满所有带宽
```

### 5.2 Scheduler Extender 配置

```yaml
# scheduler-policy-config.yaml
{
  "kind": "Policy",
  "apiVersion": "v1",
  "extenders":
    [
      {
        "urlPrefix": "http://rdma-scheduler-extender:9000",
        "filterVerb": "filter",
        "prioritizeVerb": "prioritize",
        "bindVerb": "bind",
        "weight": 1,
        "enableHttps": false,
        "nodeCacheCapable": true,
        "managedResources": ["rdma/hca"],
        "ignoreResourceCollection": false,
      },
    ],
}
```

```go
// RDMA Scheduler Extender 实现
type RDMAScheduler struct {
    rdmaResources map[string][]string  // node -> available RDMA devices
}

func (s *RDMAScheduler) filter(args map[string]interface{}) ([]string, error) {
    pod := args["pod"].(*v1.Pod)
    nodes := args["nodes"].([]string)

    requestedRDMA := getRDMARequest(pod)
    filteredNodes := []string{}

    for _, node := range nodes {
        availableRDMA := s.rdmaResources[node]
        if len(availableRDMA) >= requestedRDMA {
            filteredNodes = append(filteredNodes, node)
        }
    }
    return filteredNodes, nil
}

func (s *RDMAScheduler) prioritize(args map[string]interface{}) map[string]int {
    pod := args["pod"].(*v1.Pod)
    nodes := args["nodes"].([]string)

    scores := map[string]int{}
    for _, node := range nodes {
        // 优先选择 RDMA 设备数量多的节点
        scores[node] = len(s.rdmaResources[node])
    }
    return scores
}

func (s *RDMAScheduler) bind(args map[string]interface{}) error {
    pod := args["pod"].(*v1.Pod)
    node := args["node"].(string)

    // 将 pod 绑定到选定的节点
    return bindPodToNode(pod, node)
}
```

### 5.3 亲和性调度配置

```yaml
# Pod 亲和性配置示例
apiVersion: v1
kind: Pod
metadata:
  name: gpu-rdma-job
spec:
  nodeSelector:
    feature.node.kubernetes.io/rdma: "true"
  affinity:
    # 与其他 GPU 作业靠近
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: gpu-training
          topologyKey: kubernetes.io/hostname
    # 远离非 GPU 节点
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - matchExpressions:
            - key: nvidia.com/gpu
              operator: Exists
  containers:
    - name: main
      image: pytorch:latest
      resources:
        limits:
          nvidia.com/gpu: 4
          rdma/hca: 1
```

---

## 6. 生产环境配置示例

### 6.1 多节点 RDMA 集群

```
生产环境 RDMA Kubernetes 集群架构：

  Control Plane (3 nodes)
  ├── kube-apiserver (HA)
  ├── kube-scheduler (with RDMA extender)
  └── etcd (HA)

  Worker Nodes (每节点配置)
  ├── 2x NVIDIA A100/H100 GPU
  ├── 2x ConnectX-6/7 RDMA NIC (100/200Gbps)
  ├── 2x NUMA node
  └── 768GB+ RAM

  网络
  ├── GPU RDMA 网络 (叶交换机互联)
  ├── Storage 网络 (另一套 RDMA)
  └── Management 网络 (Ethernet)
```

```yaml
# cluster-wide RDMA 配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: rdma-config
  namespace: kube-system
data:
  config.yaml: |
    rdma:
      enabled: true
      devices:
        - vendor: mellanox
          model: ConnectX-6
          count: 2
      cluster:
        type: roce
        dcbx: true
        pfc:
          enabled: true
          priority: 3
      limits:
        max_qp_per_node: 1024
        max_mr_size: 128GB
      cni:
        type: host-device
        devices:
          - mlx5_0
          - mlx5_1
```

### 6.2 节点配置脚本

```bash
#!/bin/bash
# setup_rdma_node.sh - 在每个 RDMA 节点上执行

set -e

# 1. 启用巨页 (RDMA 需要)
echo 64 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 2. 加载 RDMA 内核模块
modprobe -a mlx5_ib mlx5_core ib_uverbs

# 3. 配置 IPoIB (RoCE)
ip link add ib0 type ipoib mode connected
ip addr add 192.168.100.0/24 dev ib0
ip link set ib0 mtu 65520

# 4. 配置 PFC
ethtool --set-pfc ib0 rx 3 on tx 3 on

# 5. 启用 DCBX
ethtool --set-dcbx ib0 mode 2
ethtool --set-dcb ib0 forward on

# 6. 设置 sysctl 参数
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.core.rmem_max=124928000
sysctl -w net.core.wmem_max=124928000

# 7. 配置 RDMA 网卡资源限制
echo 1024 > /sys/class/infiniband/mlx5_0/limits/max_qp
echo 65536 > /sys/class/infiniband/mlx5_0/limits/max_cq

# 8. 标记节点
kubectl label node $(hostname) feature.node.kubernetes.io/rdma=true
```

### 6.3 RDMA Pod 配额

```yaml
# ResourceQuota - 限制 RDMA 资源使用
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rdma-quota
  namespace: gpu-jobs
spec:
  hard:
    rdma/hca: "8" # 最多 8 个 RDMA 设备
    nvidia.com/gpu: "16"
---
# LimitRange - Pod 资源限制
apiVersion: v1
kind: LimitRange
metadata:
  name: gpu-job-limits
  namespace: gpu-jobs
spec:
  limits:
    - max:
        rdma/hca: 4
        nvidia.com/gpu: 8
      min:
        rdma/hca: 1
        nvidia.com/gpu: 1
      type: Pod
```

---

## 7. 监控与故障排除

### 7.1 RDMA 指标暴露

```yaml
# prometheus 抓取 RDMA 指标
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rdma
data:
  rdma-monitor.yaml: |
    global:
      scrape_interval: 15s
    scrape_configs:
    - job_name: 'rdma'
      static_configs:
      - targets: ['rdma-exporter:9800']
        labels:
          group: 'rdma'
---
apiVersion: v1
kind: Service
metadata:
  name: rdma-exporter
  namespace: kube-system
spec:
  ports:
    - port: 9800
      name: metrics
  selector:
    name: rdma-device-plugin
```

```bash
# 常用 RDMA 指标
#   - rdma_hca_num_active: 活跃 HCA 数量
#   - rdma_hca_total_latency: 总延迟
#   - rdma_qp_num: QP 数量
#   - rdma_cq_overflow: CQ 溢出次数
#   - rdma_port_phy_rate: 物理端口速率
```

### 7.2 常见问题与解决

```
RDMA Pod 启动失败排查：

  问题 1: RDMA 设备未发现
  原因：
    - 节点未标记 rdma label
    - Device Plugin 未运行
  解决：
    $ kubectl label node <node> feature.node.kubernetes.io/rdma=true
    $ kubectl get pods -n kube-system -l name=rdma-device-plugin

  问题 2: RDMA 设备分配失败
  原因：
    - 设备已被其他 Pod 占用
    - 资源配额耗尽
  解决：
    $ kubectl describe node <node> | grep rdma
    $ kubectl get resourcequota -n <namespace>

  问题 3: 容器内无法访问 /dev/infiniband
  原因：
    - securityContext 缺少 privileged
    - volumeMount 未正确配置
  解决：
    检查 Pod spec:
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      volumeMounts:
      - name: dev
        mountPath: /dev/infiniband

  问题 4: RDMA 通信失败
  原因：
    - 网络配置错误（PFC/ECN）
    - GID 不匹配
  解决：
    $ kubectl exec -it <pod> -- ibstat
    $ kubectl exec -it <pod> -- ibv_rc_pingpong -d mlx5_0 -g 0 <target-gid>
```

---

## 8. 小结

```
本章要点：

  1. Kubernetes Device Plugin 是 RDMA 设备暴露的标准机制，通过 ListAndWatch/Allocate 接口管理设备

  2. RDMA Device Plugin 向 Kubernetes 报告 rdma/hca 资源，Pod 通过 limits.rdma/hca 请求

  3. RDMA Shared Device Plugin 支持多容器共享同一 RDMA 设备，适合高密度部署

  4. NVIDIA GPU Operator 提供 GPU + RDMA 的统一管理，是 AI 训练集群的标准选择

  5. RDMA Scheduler Extender 实现 GPU-RDMA 共置、RDMA 拓扑感知等高级调度策略

  6. 生产环境需要综合考虑网络拓扑、资源配额、监控和故障恢复

  7. 常见问题包括设备发现失败、资源竞争、权限不足和网络配置错误
```
