---
title: "Cilium 深度探索 (46)：扩展与 Operator 开发"
date: 2026-04-14
tags:
  - cilium
  - operator
  - extensibility
  - crd
  - hubble
  - api
  - plugin
  - developer
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 43. [[ch43-ecosystem|第四十三章：Cilium 生态概述]] 44. [[ch44-bgp|第四十四章：BGP 网络集成]] 45. [[ch45-security|第四十五章：安全生态集成]] 46. **第四十六章：扩展与 Operator** ←

---

## 1. Cilium 扩展架构

Cilium 提供了多层次的扩展机制，允许用户和开发者深度定制和扩展其功能：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Cilium 扩展层次                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  用户层扩展 (User-Facing)                                         │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  Custom Resources (CRD)                                    │ │   │
│   │  │  • CiliumNetworkPolicy                                      │ │   │
│   │  │  • CiliumBGPControlPlane                                   │ │   │
│   │  │  • CiliumL7Policy                                          │ │   │
│   │  │  • CiliumEgressGatewayPolicy                               │ │   │
│   │  │  • CiliumClusterwideNetworkPolicy                          │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  API 层扩展                                                      │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  GraphQL API (Hubble)                                        │ │   │
│   │  │  REST API (Cilium Agent)                                    │ │   │
│   │  │  BPF Program Loader                                          │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  数据面扩展                                                      │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  eBPF Program (自定义)                                       │ │   │
│   │  │  • Custom Probes                                             │ │   │
│   │  │  • Custom Parsers                                            │ │   │
│   │  │  • Custom Actions                                            │ │   │
│   │  │  CNI Chaining (与其他插件组合)                                 │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Operator 层扩展                                                │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  Cilium Operator Plugins                                    │ │   │
│   │  │  Custom Controllers                                          │ │   │
│   │  │  Custom Reconcilers                                         │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Custom Resource Definitions (CRD)

### 2.1 Cilium CRD 概览

Cilium 定义了大量的 CRD 来扩展 Kubernetes：

```bash
# 查看所有 Cilium CRD
kubectl get crd | grep cilium

# 示例输出
ciliumbgpads                                           2024-01-01
ciliumbgpciliumconfigs                                 2024-01-01
ciliumbgppeers                                         2024-01-01
ciliumciliumconfigs                                     2024-01-01
ciliumclusterwidenetworkpolicies                        2024-01-01
ciliumendpoints                                        2024-01-01
ciliumenvoyconfigs                                     2024-01-01
ciliumidentities                                       2024-01-01
ciliuml7policies                                       2024-01-01
ciliumlocalredirectpolicies                            2024-01-01
ciliumnodes                                            2024-01-01
ciliumnetworkpolicies                                   2024-01-01
ciliumperednsnames                                     2024-01-01
ciliumegressgatewaypolicies                            2024-01-01
ciliumegressgatewaysecrets                             2024-01-01
cilium CiliumExternalWorkloads                         2024-01-01
cilium CiliumL7LogSubjects                             2024-01-01
cilium CiliumPodIPPools                                2024-01-01
```

### 2.2 自定义 CRD 示例

```yaml
# 定义一个简单的自定义 Cilium CRD
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ciliuml7policies.cilium.io
spec:
  group: cilium.io
  names:
    kind: CiliumL7Policy
    listKind: CiliumL7PolicyList
    plural: ciliuml7policies
    singular: ciliuml7policy
  scope: Namespaced
  versions:
    - name: v2
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                endpointSelector:
                  type: object
                ingress:
                  type: array
                egress:
                  type: array
```

### 2.3 使用 Cilium Client

```go
// Go 中使用 Cilium Client
package main

import (
    "context"
    "fmt"
    ciliumv2 "github.com/cilium/cilium/pkg/k8s/apis/cilium.io/v2"
    ciliumclient "github.com/cilium/cilium/pkg/k8s/client/clientset/versioned"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func main() {
    // 创建 client
    client, err := ciliumclient.NewForConfig(cfg)
    if err != nil {
        panic(err)
    }

    // 创建 CiliumNetworkPolicy
    cnp := &ciliumv2.CiliumNetworkPolicy{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "my-policy",
            Namespace: "default",
        },
        Spec: &ciliumv2.CiliumNetworkPolicySpec{
            EndpointSelector: &metav1.LabelSelector{
                MatchLabels: map[string]string{
                    "app": "api",
                },
            },
            Ingress: []ciliumv2.IngressRule{{
                FromEndpoints: []metav1.LabelSelector{{
                    MatchLabels: map[string]string{
                        "app": "frontend",
                    },
                }},
            }},
        },
    }

    // 提交策略
    result, err := client.CiliumV2().CiliumNetworkPolicies("default").Create(
        context.Background(),
        cnp,
        metav1.CreateOptions{},
    )
    fmt.Printf("Created policy: %s\n", result.Name)
}
```

---

## 3. Hubble GraphQL API

### 3.1 Hubble API 概述

Hubble 提供 GraphQL API 用于查询网络流量：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Hubble GraphQL 架构                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Hubble Relay                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                                                                  │   │
│   │   GraphQL Server                                                 │   │
│   │   ┌─────────────────────────────────────────────────────────┐   │   │
│   │   │  Query:                                                   │   │   │
│   │   │    • getFlows (过滤、分页)                                 │   │   │
│   │   │    • getService                                          │   │   │
│   │   │    • getNode                                             │   │   │
│   │   │    • getDNS                                               │   │   │
│   │   │                                                          │   │   │
│   │   │  Mutation:                                                │   │   │
│   │   │    • star收藏流                                           │   │   │
│   │   │    • 添加注释                                             │   │   │
│   │   └─────────────────────────────────────────────────────────┘   │   │
│   │                                                                  │   │
│   │   └─────────────────────────────────────────────────────────────│   │
│   │         │                                                         │   │
│   │         │ gRPC (hubble.v1.FlowService)                          │   │
│   │         │                                                         │   │
│   │         ▼                                                         │   │
│   │   ┌─────────────────────────────────────────────────────────┐   │   │
│   │   │  Flow Aggregation (per Node)                             │   │   │
│   │   │  cilium-agent (per node) → relay                        │   │   │
│   │   └─────────────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   访问方式:                                                              │
│   • CLI: hubble query                                                  │
│   • Web UI: http://hubble-ui                                           │
│   • GraphQL: http://hubble-relay:80/graphql                            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 GraphQL 查询示例

```graphql
# 查询特定 Pod 的流量
query GetPodFlows($namespace: String!, $podName: String!, $limit: Int!) {
  flows(namespace: $namespace, podName: $podName, limit: $limit) {
    time
    verdict
    source {
      id
      namespace
      podName
      labels
    }
    destination {
      id
      namespace
      podName
      labels
    }
    l4 {
      tcp {
        flags
      }
    }
    l7 {
      http {
        method
        path
        code
      }
    }
    kubernetes {
      namespaceName
      podName
    }
  }
}

# 变量
{
  "namespace": "default",
  "podName": "nginx-abc123",
  "limit": 100
}
```

### 3.3 REST API

```bash
# Cilium Agent REST API
# 访问 Agent API (需要在同一个网络或通过 port-forward)
kubectl port-forward -n kube-system ds/cilium 9090:9090

# 获取端点列表
curl http://localhost:9090 Cilium/v1/endpoint

# 获取 Service 列表
curl http://localhost:9090 Cilium/v1/service

# 获取 Node 列表
curl http://localhost:9090 Cilium/v1/node

# 获取 BGP 状态
curl http://localhost:9090 Cilium/v1/bgp/peers

# 获取 IPAM 状态
curl http://localhost:9090 Cilium/v1/ipam
```

---

## 4. Operator 开发

### 4.1 Cilium Operator 架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Cilium Operator 架构                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Cilium Operator (Leader)                                              │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                                                                  │   │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │   │
│   │  │  IPAM      │  │   Node      │  │   BGP      │             │   │
│   │  │  Controller │  │  Controller │  │  Controller │             │   │
│   │  └─────────────┘  └─────────────┘  └─────────────┘             │   │
│   │                                                                  │   │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │   │
│   │  │   ENI      │  │   DNS      │  │  Policy    │             │   │
│   │  │  (AWS)     │  │  Controller │  │  Controller │             │   │
│   │  └─────────────┘  └─────────────┘  └─────────────┘             │   │
│   │                                                                  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                              │                                            │
│                              │ Kubernetes API                             │
│                              ▼                                            │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                        etcd / K8s APIServer                      │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   Cilium Agent (per Node)                                                │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  eBPF Loader ←→ IPAM ←→ Operator                                 │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 自定义 Operator 开发

```go
// 示例：创建自定义 Cilium Operator 控制器
package main

import (
    "context"
    "fmt"
    "time"

    "github.com/cilium/cilium/pkg/k8s/apis/cilium.io/v2"
    ciliumv2 "github.com/cilium/cilium/pkg/k8s/apis/cilium.io/v2"
    "github.com/cilium/operator/pkg/controller"

    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log/zap"
)

var log = ctrl.Log.WithName("custom-controller")

type CustomReconciler struct {
    client client.Client
    scheme *runtime.Scheme
}

// Reconcile 实现自定义逻辑
func (r *CustomReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log.Info("Reconciling", "resource", req.NamespacedName)

    // 获取 CiliumNetworkPolicy
    var cnp ciliumv2.CiliumNetworkPolicy
    if err := r.client.Get(ctx, req.NamespacedName, &cnp); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 自定义逻辑：检查策略是否合规
    if err := r.validatePolicy(&cnp); err != nil {
        // 更新状态
        cnp.Status = ciliumv2.CiliumNetworkPolicyStatus{
            ImplementatioStatus: ciliumv2.ImplementationStatus{
                Ok:               false,
                Reason:           err.Error(),
                LastUpdateTime:   time.Now(),
            },
        }
        if err := r.client.Status().Update(ctx, &cnp); err != nil {
            return ctrl.Result{}, err
        }
        return ctrl.Result{}, err
    }

    return ctrl.Result{}, nil
}

func (r *CustomReconciler) validatePolicy(cnp *ciliumv2.CiliumNetworkPolicy) error {
    // 示例：检查是否有拒绝规则
    // 实现具体验证逻辑
    return nil
}

func main() {
    // 设置日志
    ctrl.SetLogger(zap.New(zap.UseDevMode(true)))

    // 创建 Manager
    mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
        Scheme:                 ciliumv2.Scheme,
        LeaderElection:         true,
        LeaderElectionID:       "custom-cilium-operator",
        LeaderElectionNamespace: "kube-system",
    })
    if err != nil {
        panic(err)
    }

    // 注册控制器
    r := &CustomReconciler{
        client: mgr.GetClient(),
        scheme: mgr.GetScheme(),
    }

    err = ctrl.NewControllerManagedBy(mgr).
        For(&ciliumv2.CiliumNetworkPolicy{}).
        Complete(r)
    if err != nil {
        panic(err)
    }

    // 启动 Manager
    if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
        panic(err)
    }
}
```

---

## 5. CNI Chaining

### 5.1 CNI Chaining 概览

CNI Chaining 允许 Cilium 与其他 CNI 插件组合使用：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       CNI Chaining 模式                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   模式 1: Calico + Cilium                                                │
│   ─────────────────────────────                                          │
│   kubelet → CNI Chain → calico → cilium-chaining → host-device         │
│                                                                         │
│   模式 2: AWS VPC CNI + Cilium                                           │
│   ─────────────────────────────                                          │
│   kubelet → CNI Chain → aws-cni → cilium-chaining → host-device        │
│                                                                         │
│   模式 3: Flannel + Cilium (Cilium 作为 Policy Only)                    │
│   ─────────────────────────────────────────────────────────────         │
│   kubelet → CNI Chain → flannel → cilium-chaining → host-device        │
│                                                                         │
│   配置:                                                                  │
│   /etc/cni/net.d/05-cilium.conf:                                         │
│   {                                                                     │
│     "cniVersion": "0.3.1",                                              │
│     "name": "cilium",                                                   │
│     "type": "cilium-cni",                                                │
│     "chain": "/opt/cni/bin/calico"                                       │
│   }                                                                     │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 配置示例

```bash
# AWS EKS 上启用 Cilium (使用 AWS VPC CNI Chaining)
# 1. 禁用 AWS VPC CNI 的 ENI 管理
kubectl set env daemonset -n kube-system aws-node ENABLE_POD_ENI=false

# 2. 安装 Cilium 并配置 Chaining
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set cni.chainingMode=aws-vpc \
  --set cni.customNetwork.enabled=true \
  --set ipam.mode=aws

# 3. AWS VPC CNI 作为 Chaining Target
# /etc/cni/net.d/05-cilium.conflist:
{
  "name": "cilium",
  "cniVersion": "0.3.1",
  "type": "cilium-cni",
  "chain": "/var/sdk/bin/aws-cni",
  "mtu": 9001
}
```

---

## 6. eBPF 程序扩展

### 6.1 自定义 eBPF 程序

```c
// 自定义 eBPF 程序示例：记录特定流的统计
#include "bpf_helpers.h"
#include "bpf_ep.h"

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, struct flow_key);
    __type(value, struct flow_stats);
    __uint(max_entries, 10000);
} flow_stats_map SEC(".maps");

SEC("cilium/tc_counter")
int counter(struct __ctx_buff *ctx)
{
    // 获取源和目标信息
    struct iphdr *ip = ctx_data(ctx);
    struct port_key key = {
        .src_ip = ip->saddr,
        .dst_ip = ip->daddr,
        .src_port = *(((u16 *)ip) + sizeof(struct iphdr)),
        .dst_port = *(((u16 *)ip) + sizeof(struct iphdr) + 1),
        .protocol = ip->protocol
    };

    // 更新统计
    struct flow_stats *stats = bpf_map_lookup_elem(&flow_stats_map, &key);
    if (stats) {
        __sync_fetch_and_add(&stats->packets, 1);
        __sync_fetch_and_add(&stats->bytes, ctx->len);
    } else {
        struct flow_stats new_stats = {.packets = 1, .bytes = ctx->len};
        bpf_map_update_elem(&flow_stats_map, &key, &new_stats, BPF_ANY);
    }

    return CTX_ACT_OK;
}
```

### 6.2 加载自定义 eBPF 程序

```bash
# 通过 Cilium 加载自定义 eBPF 程序
# 将程序挂载到 TC 或 XDP hook

# 创建 ConfigMap 存储 eBPF 程序
kubectl create configmap custom-ebpf-programs \
  --from-file=counter.bpf.o \
  --namespace=kube-system

# 配置 Cilium 加载程序
apiVersion: cilium.io/v2
kind: CiliumConfig
metadata:
  name: cilium-custom-ebpf
spec:
  bpf:
    customEbpFPrograms:
      enabled: true
      configMap: custom-ebpf-programs
      programs:
        - name: counter
          attachPoint: tc
          section: cilium/tc_counter
```

---

## 7. Hubble 扩展

### 7.1 自定义 Hubble Observer

```go
// 实现自定义 Hubble Observer
package hubbleext

import (
    "context"
    v1 "github.com/cilium/hubble/pkg/api/v1"
    "github.com/cilium/hubble/pkg/flow"
    "github.com/cilium/hubble/pkg/observer"
)

type CustomObserver struct {
    // 自定义状态
}

func (o *CustomObserver) GetLastEventUID(ctx context.Context) (uint64, error) {
    return 0, nil
}

func (o *CustomObserver) Record(ctx context.Context, e *v1.Flow) error {
    // 自定义处理逻辑
    // 例如：发送到外部 SIEM 系统
    if err := o.sendToSIEM(e); err != nil {
        return err
    }
    return nil
}

func (o *CustomObserver) sendToSIEM(f *flow.Flow) error {
    // 实现 SIEM 集成
    return nil
}
```

---

## 8. 开发环境设置

### 8.1 本地开发环境

```bash
# 使用 Kind 创建开发集群
kind create cluster --name cilium-dev

# 安装 Cilium 开发版本
cd cilium
make install
cilium install --version local

# 启用开发者模式
cilium agent --enable-developer-mode=true

# 运行测试
make TESTFLAGS="-run TestPodConnectivity" test
```

### 8.2 构建 Cilium

```bash
# 克隆仓库
git clone https://github.com/cilium/cilium.git
cd cilium

# 安装依赖
make dev-env

# 构建
make -j$(nproc)

# 构建 Docker 镜像
make docker-image
make push DOCKER_IMAGE_TAG=latest

# 交叉编译 eBPF 程序
make -j$(nproc) -C bpf/headers
make -j$(nproc) -C bpf/
```

---

## 9. 测试框架

### 9.1 单元测试

```bash
# 运行单元测试
go test ./pkg/...

# 运行特定包的测试
go test -v ./pkg/bpf/

# 运行 eBPF 相关测试
go test -v ./bpf/tests/

# 代码覆盖率
go test -coverprofile=coverage.out ./pkg/...
go tool cover -html=coverage.out
```

### 9.2 集成测试

```bash
# 使用 Ginkgo 运行集成测试
cd test
ginkgo --nodes=4 --focus="Connectivity" --randomizeSuites

# 测试特定场景
ginkgo --focus="BPF" it-only

# 运行 Runtime 测试
make runtime-tests
```

### 9.3 E2E 测试

```bash
# 运行完整的 E2E 测试套件
make e2e-tests

# 运行特定 E2E 测试
ginkgo --focus="K8s.*Policy" tests/

# 单个测试
ginkgo --focus="Check that policy audit mode works" tests/
```

---

## 10. 调试与日志

### 10.1 调试模式

```bash
# 启用调试
cilium config set debug true

# 查看调试日志
kubectl logs -n kube-system ds/cilium | grep -i debug

# 启用 eBPF 调试
cilium bpf lb list -o json | jq .

# 端点调试
cilium endpoint log 1987
```

### 10.2 火焰图

```bash
# 使用 perf 生成火焰图
# 1. 在节点上运行 perf
perf record -F 99 -a -g -- sleep 60

# 2. 生成火焰图
git clone https://github.com/brendangregg/FlameGraph.git
perf script | ./FlameGraph/stackcollapse-perf.pl | ./FlameGraph/flamegraph.pl > cilium.svg
```

---

## 11. 总结与后续学习

### 11.1 关键要点

1. **CRD 扩展**：通过自定义资源定义扩展 Kubernetes API
2. **API 层**：Hubble GraphQL 和 REST API 提供丰富的编程接口
3. **Operator 开发**：可以构建自定义 Operator 来扩展 Cilium 的控制平面
4. **CNI Chaining**：与其他 CNI 插件无缝协作
5. **eBPF 扩展**：通过自定义 eBPF 程序扩展数据面能力

### 11.2 学习路径

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     Cilium 开发者学习路径                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Level 1: 用户                                                          │
│   ──────────                                                            │
│   • 使用 CiliumNetworkPolicy                                           │
│   • 配置 Hubble 观测                                                     │
│   • 故障排查                                                             │
│                                                                         │
│   Level 2: 管理员                                                        │
│   ─────────────                                                         │
│   • 部署与配置                                                           │
│   • BGP 集成                                                             │
│   • 加密配置                                                             │
│   • 性能优化                                                             │
│                                                                         │
│   Level 3: 开发者                                                        │
│   ─────────────                                                         │
│   • CRD 开发                                                            │
│   • Operator 开发                                                       │
│   • API 集成 (GraphQL/REST)                                             │
│   • CNI Chaining                                                        │
│                                                                         │
│   Level 4: eBPF 专家                                                     │
│   ────────────────                                                      │
│   • eBPF 程序编写                                                        │
│   • 内核探测点                                                           │
│   • BPF Map 设计                                                        │
│   • 性能优化                                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 11.3 资源

- GitHub: https://github.com/cilium/cilium
- Documentation: https://docs.cilium.io
- Slack: #cilium on Slack
- Mailing List: cilium-users@cilium.io

---

## 结语

本系列文章从 Cilium 的基础架构开始，逐步深入到 eBPF 数据面、网络策略、服务发现、可观测性、性能优化、BGP 集成、安全生态和扩展开发等多个方面。

Cilium 作为云原生网络的事实标准，正在重新定义 Kubernetes 网络和安全。通过 eBPF 技术，它提供了前所未有的可编程性和性能，同时保持了与 Kubernetes 原生 API 的深度集成。

希望这个系列能帮助你更好地理解和使用 Cilium。祝你在云原生之路上探索愉快！
