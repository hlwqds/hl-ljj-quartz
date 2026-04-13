---
title: "DPDK 第四十一章：NVIDIA DOCA 与 DPU 编程框架"
date: 2026-04-09 17:00:00
tags: [dpdk, nvidia, doca, dpu, bluefield,-sdk, programming]
description: "深入解析 NVIDIA DOCA SDK：架构、组件、编程模型，以及在 BlueField DPU 上开发 DPDK 应用的方法"
---

# DPDK 第四十一章：NVIDIA DOCA 与 DPU 编程框架

> [!abstract] 核心要点
> DOCA (Data Center On A Chip Architecture) 是 NVIDIA BlueField DPU 的 SDK。本章解析 DOCA 架构、核心组件、与 DPDK 的关系，以及在 DPU 上开发应用的方法。

## 1. DOCA 概述

### 1.1 什么是 DOCA

DOCA 是 NVIDIA 为 BlueField DPU 提供的统一软件开发套件：

- **统一 API**：一套 SDK 访问所有 DPU 硬件能力
- **DPDK 兼容**：原生支持 DPDK ethdev
- **RDMA/UCX**：高性能网络
- **Storage**：NVMe-oF、Object Storage
- **Security**：IPsec、TLS、DPI
- **编译一次**：可在 Arm 和 x86 上运行

### 1.2 BlueField DPU 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      BlueField-3 DPU                        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    ARM Cores (8x A78)                │  │
│  │                                                      │  │
│  │  ┌────────────────────────────────────────────────┐ │  │
│  │  │              DOCA Runtime (on Arm)              │ │  │
│  │  │  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐      │ │  │
│  │  │  │ DPDK │  │ RDMA │  │ SPARK │  │ DOCA │      │ │  │
│  │  │  │      │  │ /UCX │  │(KV)  │  │Flow  │      │ │  │
│  │  │  └──────┘  └──────┘  └──────┘  └──────┘      │ │  │
│  │  └────────────────────────────────────────────────┘ │  │
│  └──────────────────────────┬───────────────────────────┘  │
│                             │                               │
│  ┌──────────────────────────▼───────────────────────────┐  │
│  │              ConnectX-7 (200/400GbE)                │  │
│  │                                                      │  │
│  │  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐    │  │
│  │  │  ETH   │  │  RDMA  │  │ Crypto │  │  DPI   │    │  │
│  │  │ (DPDK) │  │(RoCE) │  │(IPSec) │  │(RegEx) │    │  │
│  │  └────────┘  └────────┘  └────────┘  └────────┘    │  │
│  └──────────────────────────────────────────────────────┘  │
│                             │                               │
│  ┌──────────────────────────▼───────────────────────────┐  │
│  │              PCIe Gen 5.0 x16                         │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 2. DOCA 架构

### 2.1 DOCA 层次结构

```
┌─────────────────────────────────────────────────────────────┐
│                    DOCA SDK                                │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐ │
│  │              High-Level SDKs                           │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐│ │
│  │  │  DPA    │  │ Spark   │  │  DOCA   │  │   gRPC  ││ │
│  │  │ (Flow)  │  │  (KV)   │  │ Storage │  │  (Mgmt) ││ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘│ │
│  └──────────────────────────┬────────────────────────────┘ │
│                             │                              │
│  ┌──────────────────────────▼────────────────────────────┐ │
│  │              Low-Level APIs                           │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐              │ │
│  │  │ DPDK   │  │ UCX     │  │ RegEx   │              │ │
│  │  │ Ethdev │  │(RDMA)  │  │  API   │              │ │
│  │  └─────────┘  └─────────┘  └─────────┘              │ │
│  └──────────────────────────┬────────────────────────────┘ │
│                             │                              │
│  ┌──────────────────────────▼────────────────────────────┐ │
│  │              Hardware Abstraction                      │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐              │ │
│  │  │  DMA    │  │  Crypto │  │ Network │              │ │
│  │  └─────────┘  └─────────┘  └─────────┘              │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 核心组件

| 组件 | 功能 | 底层技术 |
|------|------|----------|
| **DOCA Flow** | 流水线处理 | rte_flow 兼容 |
| **DOCA DPA** | Data Path Architecture | 可编程管线 |
| **DOCA NetFlow** | 网络流导出 | IPFIX |
| **DOCA DPI** | 深度包检测 | RegEx 引擎 |
| **DOCA Crypto** | 加密加速 | IPsec/TLS |
| **DOCA Storage** | 存储加速 | NVMe-oF |
| **DOCA Spark** | 内存数据库 | KV Store |
| **DOCA Comm Net** | 集合通信 | RDMA/UCX |

## 3. DOCA 开发环境

### 3.1 安装 DOCA SDK

```bash
# 1. 下载 DOCA（需要 NVIDIA 开发者账号）
wget https://developer.nvidia.com/networking/doca -O doca_sdk.tar.gz

# 2. 安装依赖
sudo apt install -y --no-install-recommends \
    build-essential \
    python3-setuptools \
    meson

# 3. 解压安装
sudo tar -xvzf doca_sdk.tar.gz -C /opt/nvidia/
cd /opt/nvidia/doca_sdk/

# 4. 设置环境
source /opt/nvidia/doca_sdk/setup_env.sh

# 5. 验证安装
doca --version
```

### 3.2 编译 DOCA 应用

```bash
# DOCA 使用 meson 构建
export DOCA_DIR=/opt/nvidia/doca_sdk/
export DPDK_DIR=/opt/nvidia/doca_sdk/deps/dpdk/

meson setup build
ninja -C build
```

### 3.3 基础示例

```c
// doca_basic.c
#include <doca_log.h>
#include <doca_ctx.h>

DOCA_LOG_REGISTER(MAIN);

int main(int argc, char *argv[])
{
    // 初始化 DOCA
    struct doca_ctx *ctx = doca_ctx_create();
    if (!ctx) {
        DOCA_LOG_ERR("Failed to create context");
        return -1;
    }

    // 启动 context
    doca_ctx_start(ctx);

    DOCA_LOG_INFO("DOCA initialized successfully");

    // 清理
    doca_ctx_stop(ctx);
    doca_ctx_destroy(ctx);

    return 0;
}
```

## 4. DOCA Flow

### 4.1 DOCA Flow 概述

DOCA Flow 是 DPDK rte_flow 的超集，专为 DPU 设计：

```
┌─────────────────────────────────────────────────────────────┐
│                    DOCA Flow Pipeline                       │
│                                                              │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
│  │ Parser  │─▶│ Match   │─▶│ Action  │─▶│ Forward │        │
│  │         │  │         │  │         │  │         │        │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘        │
│                                                              │
│  支持的 Actions：                                           │
│  - 修改 Header (swap MAC/IP/port)                          │
│  - 计数器 (stats)                                           │
│  - Metering                                                 │
│  - TTL                                                       │
│  - Encapsulation (VXLAN/NVGRE)                             │
│  - Decapsulation                                            │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 DOCA Flow 示例

```c
#include <doca_flow.h>

// 1. 初始化 DOCA Flow
struct doca_flow_cfg cfg = {
    .nr_buffers = 1024,
    .nr_actions = 512,
    .pipe_queue_size = 128,
};
doca_flow_init(&cfg);

// 2. 创建 Port
struct doca_flow_port *port;
struct doca_flow_port_cfg port_cfg = {
    .port_id = 0,
    .type = DOCA_FLOW_PORT_TYPE_DPDK,
};
doca_flow_port_start(&port_cfg, &port);

// 3. 创建 Pipe
struct doca_flow_match match = {
    .out_hdr.eth.type = htons(0x0800),  // IPv4
};
match.out_hdr.ipv4.src_ip = 0x0A000001;  // 10.0.0.1
match.out_hdr.ipv4.dst_ip = 0x0A000002;  // 10.0.0.2
match.out_hdr.l4_type = DOCA_FLOW_L4_TYPE_TCP;

struct doca_flow_fwd fwd = {
    .type = DOCA_FLOW_FWD_PORT,
    .port_id = 1,
};

struct doca_flow_actions actions = {
    .has_changeable = false,
};

struct doca_flow_pipe_cfg pipe_cfg = {
    .name = "example_pipe",
    .match = &match,
    .actions = &actions,
    .fwd = &fwd,
};

struct doca_flow_pipe *pipe;
doca_flow_pipe_create(&pipe_cfg, &pipe);

// 4. 添加规则
doca_flow_pipe_rule_add(pipe, &match, &actions, &fwd, 0);

// 5. 清理
doca_flow_pipe_destroy(pipe);
doca_flow_cleanup();
```

## 5. DOCA 与 DPDK 集成

### 5.1 DPDK Ethdev on DOCA

BlueField 上的 DPDK 应用：

```c
#include <rte_ethdev.h>

int main(int argc, char **argv)
{
    // 标准 DPDK EAL
    rte_eal_init(argc, argv);

    // 枚举端口
    uint16_t port_id = rte_eth_find_free_port();
    printf("Found port: %u\n", port_id);

    // 端口配置（与标准 DPDK 相同）
    struct rte_eth_conf conf = {
        .rxmode = {
            .mq_mode = RTE_ETH_MQ_RX_NONE,
        },
    };

    rte_eth_dev_configure(port_id, 1, 1, &conf);

    // 设置 RX/TX 队列
    struct rte_eth_rxconf rxconf;
    struct rte_eth_txconf txconf;

    rte_eth_rx_queue_setup(port_id, 0, 256, 0, NULL,
                             rte_pktmbuf_pool_create(...));
    rte_eth_tx_queue_setup(port_id, 0, 256, 0, NULL);

    // 启动端口
    rte_eth_dev_start(port_id);

    // 标准 DPDK 收发包循环
    struct rte_mbuf *pkts[32];
    while (1) {
        uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, pkts, 32);
        // 处理...
        uint16_t nb_tx = rte_eth_tx_burst(port_id, 0, pkts, nb_rx);
    }
}
```

### 5.2 在 DPU 上运行 vs 在 Host 上运行

```bash
# 方式 1：在 DPU Arm 核心上运行
# 直接在 BlueField 的 ARM 上执行
ssh ubuntu@bf-host
sudo ./myapp -l 0-3 -n 4

# 方式 2：从 Host 透明卸载到 DPU
# Host 上的流量被 DPU 处理
ethtool -U eth0 flow-type tcp4 dst-ip 10.0.0.1 action 1
# 流量被 DPU 接管
```

## 6. DOCA 安全

### 6.1 DOCA IPsec

```c
#include <doca_ipsec.h>

// 1. 创建 IPsec 关联
struct doca_ipsec_sa_cfg sa_cfg = {
    .crypto.algo = DOCA_IPSEC_SA_CRYPTO_ALGO_AES_GCM_128,
    .crypto.key = {0x00, 0x01, ...},
    .spi = 1000,
    .direction = DOCA_IPSEC_SA_DIR_ENCAP,
};

struct doca_ipsec_sa *sa;
doca_ipsec_sa_create(&sa_cfg, &sa);

// 2. 应用到 Flow
doca_flow_ipsec_sa_attach(sa, pipe);
```

### 6.2 DOCA TLS

```c
#include <doca_tls.h>

// TLS/DTLS 卸载类似
struct doca_tls_cfg tls_cfg = {
    .crypto_algo = DOCA_TLS_CRYPTO_ALGO_AES_GCM_128,
    .tls_hdr_type = DOCA_TLS_HDR_TYPE_TRANSITIONAL,
};

struct doca_tls_context *tls_ctx;
doca_tls_context_create(&tls_cfg, &tls_ctx);
```

## 7. DOCA Storage

### 7.1 NVMe-oF Target

```c
#include <doca_storage.h>

// 在 DPU 上提供 NVMe-oF 存储
struct doca_storage_export_cfg export_cfg = {
    .transport = DOCA_STORAGE_TRANSPORT_RDMA,
    .export_port = 4420,
};

struct doca_storage_backend *backend;
doca_storage_backend_create(&export_cfg, &backend);

// 导出本地 NVMe 设备
doca_storage_export_add_nvme(backend, "/dev/nvme0n1");
doca_storage_export_start(backend);

// Host 可以通过 RDMA 访问
```

## 8. DOCA 与其他框架对比

| 特性 | DOCA | IPDK | P4 |
|------|------|------|-----|
| **厂商** | NVIDIA | Intel (开源) | 通用 |
| **硬件** | BlueField | E810/FlexRip | Tofino/软件 |
| **语言** | C/DPDK/P4 | P4+YANG | P4 |
| **Flow** | DOCA Flow | SDE/PDK | P4 |
| **生态** | NVIDIA AI/Cloud | 开放网络 | 多厂商 |

## 9. 总结

DOCA 是 BlueField DPU 的完整 SDK：

1. **统一 API**：一套 SDK 访问所有 DPU 能力
2. **DPDK 兼容**：标准 DPDK 应用可在 DPU 上运行
3. **硬件加速**：IPsec、TLS、DPI、RDMA 原生支持
4. **DOCA Flow**：强大的流水线处理能力
5. **适用场景**：云原生、安全、存储、AI/ML

---

## 参考资源

- [NVIDIA DOCA 文档](https://docs.nvidia.com/doca/)
- [DOCA SDK 下载](https://developer.nvidia.com/networking/doca)
- [BlueField 文档](https://docs.nvidia.com/networking/category/bluefield)
