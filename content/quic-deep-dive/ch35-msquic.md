---
title: "QUIC 深度探索 ch35 - Microsoft msquic"
date: 2026-04-14
description: "深入解析 Microsoft msquic：QUIC 协议栈架构、msquic 的核心设计理念、UWP/WinRT 集成、架构分层（注册层/会话层/流层）、芦山（芦山）优化、生产环境部署"
tags:
  - quic
  - series
  - msquic
  - implementation
  - microsoft
  - windows
  - uwp
---

# QUIC 深度探索 ch35 - Microsoft msquic

> [!tip] 本章内容
> 本章深入剖析 Microsoft 的 QUIC 实现——msquic。涵盖 msquic 的架构设计、核心组件（注册层/会话层/流层）、芦山优化、生产环境部署，以及在 Windows 生态系统中的集成方式。

---

## 1. msquic 概述

msquic 是 Microsoft 主导开发的开源 QUIC 协议栈，最初随 Windows Server 2022 和 Windows 11 内核集成，后来独立为 [microsoft/msquic](https://github.com/microsoft/msquic) 项目。它是 Windows 系统中 QUIC 的核心实现，支撑了 HTTP/3 (MSHTML)、Azure QUIC 存储传输、Azure Data Lake Storage 等关键场景。

msquic 的设计哲学：

1. **内核级集成**：与 Windows 网络堆栈深度结合，减少上下文切换
2. **异步 I/O 模型**：全面拥抱 Windows IOCP（I/O Completion Ports）
3. **芦山优化**：芦山（芦山）是微软内部的 RDMA 和网络优化项目，msquic 与之深度集成
4. **跨平台**：虽然源自 Windows，但代码库支持 Linux，正在向 macOS 移植

---

## 2. 架构分层

msquic 采用清晰的四层架构：

```
+------------------------+
|     API Layer          |  ← 应用层接口
+------------------------+
|   Session Layer        |  ← 连接会话管理
+------------------------+
|   Connection Layer     |  ← 连接状态机
+------------------------+
|    Packet Layer        |  ← 打包/解包、加密
+------------------------+
|   Transport Layer      |  ← 可靠传输、拥塞控制
+------------------------+
```

### 2.1 注册层（Registration）

注册层是 msquic 的入口点，负责：

- 全局库初始化（`MsQuicLibraryInit`）
- Registration 对象的创建与管理
- 多个独立 QUIC 应用程序的隔离

```c
// 注册层 API
typedef struct QUIC_REGISTRATION_CONFIG {
    const char* AppName;
    QUIC_EXECUTION_PROFILE Profile;  // LOW_LATENCY / THROUGHPUT / SCAVENGER
} QUIC_REGISTRATION_CONFIG;

QUIC_STATUS
MsQuicLibraryInit(
    const QUIC_LIBRARY_INFO* Info
);

QUIC_STATUS
MsQuicOpen(
    _Out_ QUIC_API_TABLE** ApiTable
);
```

### 2.2 会话层（Session）

Session 对应一个 UDP 端口上的 QUIC 连接集合：

```c
// Session 创建
QUIC_STATUS
QuicSessionStart(
    _In_ QUIC_SESSION* Session,
    _In_ uint32_t Timeout
);

// Session 配置
QUIC_STATUS
QuicSessionSetConfiguration(
    _In_ QUIC_SESSION* Session,
    _In_ QUIC_CONFIGURATION* Config
);

QUIC_STATUS
QuicSessionSetTLSSettings(
    _In_ QUIC_SESSION* Session,
    _In_ const QUIC_TLS_SETTINGS* Settings
);
```

### 2.3 连接层（Connection）

连接层管理单个 QUIC 连接的状态：

```c
// 连接建立
QUIC_STATUS
QuicConnectionStart(
    _In_ QUIC_CONNECTION* Connection,
    _In_ QUIC_ADDRESS_FAMILY Family,
    _In_ const char* ServerName,
    _In_ uint16_t ServerPort
);

// 连接关闭
QUIC_STATUS
QuicConnectionShutdown(
    _In_ QUIC_CONNECTION* Connection,
    _In_ uint32_t Flags,
    _In_ uint64_t ErrorCode
);
```

### 2.4 流层（Stream）

流层对应 QUIC 的逻辑字节流：

```c
// Stream 操作
QUIC_STATUS
QuicStreamOpen(
    _In_ QUIC_CONNECTION* Connection,
    _In_ uint32_t Flags,
    _In_ QUIC_STREAM_CALLBACK_HANDLER Handler,
    _In_ void* Context,
    _Out_ QUIC_STREAM** Stream
);

QUIC_STATUS
QuicStreamStart(
    _In_ QUIC_STREAM* Stream,
    _In_ uint32_t Flags
);

QUIC_STATUS
QuicStreamShutdown(
    _In_ QUIC_STREAM* Stream,
    _In_ uint32_t Flags,
    _In_ uint64_t ErrorCode
);
```

---

## 3. 核心数据结构

### 3.1 QUIC_PACKET

msquic 的包结构设计考虑了内核旁路和高效内存管理：

```c
// 包头结构（对应 RFC 9000 Long Header）
typedef struct QUIC_PACKET_HEADER {
    uint8_t Flags;              // 包类型标志
    uint32_t Version;            // QUIC 版本
    QUIC_CONNECTION_ID DestCid; // 目标 Connection ID
    QUIC_CONNECTION_ID SrcCid;   // 源 Connection ID
    uint8_t TokenLength;         // Token 长度
    uint8_t* Token;              // 地址验证 Token
    uint8_t* CryptoData;         // CRYPTO 帧数据
} QUIC_PACKET_HEADER;

// 包上下文（per-packet metadata）
typedef struct QUIC_SENT_PACKET_METADATA {
    QUIC_RECV_DATA* const Packet;     // 指向包的指针
    uint64_t QueuedTime;              // 发送队列时间戳
    uint64_t SentTime;                // 实际发送时间
    uint16_t Mtu;                    // 路径 MTU
    QUIC_PATH Budget;                 // 路径预算
} QUIC_SENT_PACKET_METADATA;
```

### 3.2 加密上下文

msquic 使用 BoringSSL（与 Chromium 相同）进行加密：

```c
typedef struct QUIC_SEC_CONFIG {
    QUIC_SEC_AEAD Aead;              // AES-128-GCM/AES-256-GCM/ChaCha20-Poly1305
    QUIC_SEC_KEX KeyExchange;        // TLS 1.3 密钥交换
    uint8_t WriteKey[32];           // 写密钥
    uint8_t WriteIv[12];            // 写 IV
    uint8_t ReadKey[32];            // 读密钥
    uint8_t ReadIv[12];             // 读 IV
} QUIC_SEC_CONFIG;
```

---

## 4. 发送与接收流程

### 4.1 发送路径

```
应用层数据
    |
    v
QuicStreamSend() → STREAM 帧入队
    |
    v
Connection 级别 batching（合并同方向多个 STREAM 帧）
    |
    v
Crypto 帧封装（分片 TLS record）
    |
    v
Packet 打包（添加头部、加密、HP 保护）
    |
    v
Datagram 提交到 UDP send path
    |
    v
内核 Winsock API（WSASendMsg）
```

msquic 的发送端有一个独特的 **batching 机制**：它会在一个连接内批量处理多个 STREAM 帧，减少包头开销。具体逻辑在 `ConnectionSend()` 中实现：

```c
// batching 发送伪代码
while (TRUE) {
    // 收集所有待发送的 STREAM 数据
    uint32_t StreamBytes = 0;
    for (each active stream) {
        StreamBytes += stream->SendQueue.Bytes;
    }

    // 按 MTU 限制打包
    while (BytesRemaining > 0) {
        uint16_t MaxSendSize = Min(Mtu - Overhead, BytesRemaining);
        QuicPacketWrapAndEncrypt(
            PacketBuffer,
            MaxSendSize,
            &Frames,    // PADDING/ACK/STREAM/CRYPTO 帧列表
            FrameCount
        );
    }
}
```

### 4.2 接收路径

```
UDP receive notification (Winsock / kernel callback)
    |
    v
Datagram 解析 → QUIC 包头解码
    |
    v
Connection 查找（按 DCID 路由）
    |
    v
Packet 验签和解密（按包类型选择密钥）
    |
    v
帧解析与递送（Frame dispatch）
    |
    v
Stream 数据交付应用层
    |
    v
ACK 生成与发送
```

---

## 5. 芦山（芦山）优化

芦山（Lushan）是微软内部的 RDMA 和网络优化框架，msquic 与之深度集成：

### 5.1 RDMA 支持

msquic 可以将 QUIC 流映射到底层 RDMA 传输：

```
传统路径：QUIC → UDP → kernel → NIC
芦山路径：QUIC →芦山 → RDMA NIC（零拷贝）
```

### 5.2 SR-IOV 集成

msquic 支持 SR-IOV 虚拟函数，允许多个 QUIC 连接直接访问物理网卡：

```c
// msquic 的 SR-IOV 配置
QUIC_STATUS
QuicSetNetworkInterface(
    _In_ QUIC_HANDLE Handle,
    _In_ const QUIC_NETWORK_INTERFACE* Interface
);
```

### 5.3 内核旁路发送（Kernel Bypass）

msquic 通过 Windows Hyper-V IO Virtualization (IOV) 实现部分内核旁路，减少 VM 间的数据复制。

---

## 6. 性能特性

### 6.1 高吞吐量

msquic 在 Windows 环境下通过以下方式实现高吞吐量：

1. **IOCP 异步模型**：避免线程阻塞，最大化 CPU 利用率
2. **MDL（Memory Descriptor List）**：减少内存复制
3. **NDK（Network Direct Kernel）集成**：支持 RDMA
4. **GRO（Generic Receive Offload）配合**：与 Windows 网络堆栈的 GRO 协同

### 6.2 低延迟

msquic 的低延迟优化：

1. **pacing**：平滑发送，避免 burst
2. **ACK 频率控制**：动态调整 ACK 发送频率
3. **0-RTT 优化**：会话恢复减少 RTT 开销
4. **芦山低延迟路径**：对延迟敏感流走快速路径

---

## 7. 与 Windows 生态的集成

### 7.1 WinRT API

msquic 为 UWP 应用提供 WinRT API：

```csharp
using Windows.Networking.HQUIC;

// 创建 QUIC 连接
var listener = new QUICListener();
await listener.StartAsync(port);

// 接受连接
var connection = await listener.AcceptConnAsync();

// 打开流
var stream = await connection.OpenStreamAsync();
await stream.SendAsync(data);
```

### 7.2 HTTP/3 集成

Windows 的 HTTP/3 支持（MSHTML，即 Edge 的 HTTP stack）底层使用 msquic：

```
Edge Browser → HTTP.SYS (HTTP/3 handler) → msquic → UDP
```

### 7.3 Azure 场景

Azure Data Lake Storage 使用 msquic 作为传输层：

- 跨区域大数据传输
- 持久化 QUIC 连接
- 芦山加速的 RDMA 路径

---

## 8. 部署与配置

### 8.1 msquic 的配置参数

```c
// 连接级别的配置
QUIC_CONN_CONFIG ConnConfig = {
    .Mtu = 1500,
    .MaxStreamData = 1024 * 1024,     // 单流最大流量
    .MaxData = 10 * 1024 * 1024,      // 连接最大流量
    .IdleTimeout = 30000,             // 30s idle timeout
    .CongestionControl = QUIC_CONGESTION_CONTROL_CUBIC
};
```

### 8.2 性能调优

```bash
# Windows 注册表调优（示例）
# 设置 UDP 接受窗口
netsh int tcp set global autotuninglevel=normal

# 启用 ECN
netsh int tcp set global ecncapability=enabled

# QUIC 相关 sysctl（Linux 版 msquic）
sysctl -w net.core.rmem_max=2500000
sysctl -w net.core.wmem_max=2500000
```

---

## 9. 局限性

1. **Windows 依赖**：核心部分仍依赖 Windows API，Linux 版本的完整功能集仍有差距
2. **调优复杂度**：芦山优化需要专业知识，参数调优困难
3. **文档相对匮乏**：相比开源社区项目，官方文档较少
4. **内存占用**：相比轻量级实现（如 lsquic），内存占用偏高

---

## 10. 总结

msquic 是微软在 QUIC 领域的核心投入，它与 Windows 生态的深度集成使其成为 Windows 平台上 QUIC 的事实标准。芦山优化和 RDMA 集成为 Azure 和高性能场景提供了独特优势，但同时也带来了跨平台兼容性和复杂性的挑战。对于在 Windows 环境中部署 QUIC 的开发者，msquic 是首选方案；对于跨平台需求，需要权衡是否使用平台无关的库（如 ngtcp2、quiche）。

---

> [!note] 下章预告
> 下一章我们将探讨 Cloudflare 的 Rust 实现——quiche，分析其内存安全设计、tokio 异步集成，以及在生产环境中的大规模部署经验。
