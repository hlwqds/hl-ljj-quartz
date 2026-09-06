---
title: "Zeek 深度探索 (二十八)：负载均衡"
date: 2026-04-15
tags:
  - zeek
  - series
  - cluster
  - load-balancing
  - pf_ring
  - af_packet
  - flow-hash
  - RSS
description: "深入解析 Zeek 负载均衡——PF_RING 负载均衡、AF_PACKET 负载均衡、Flow 哈希算法、RSS 配置、多队列分发"
---

> [!info] Zeek 2026 深度探索系列 0. [[zeek-deep-dive|全栈学习路径总览]]
> ... 26. [[ch26-cluster-config|第二十六章：集群配置]] 27. [[ch27-communication|第二十七章：通信]] 28. **第二十八章：负载均衡** 29. [[ch29-packet-loss|第二十九章：丢包处理]]

---

## 1. 负载均衡概述

Zeek 集群的**负载均衡**发生在两个层面：

```
┌─────────────────────────────────────────────────────────────┐
│                   Zeek 集群负载均衡                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Layer 1: 数据包级负载均衡                                    │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                                                         │ │
│  │   NIC (RSS/PF_RING)                                     │ │
│  │        ↓                                                │ │
│  │   ┌────┬────┬────┬────┐                                │ │
│  │   │ Q0 │ Q1 │ Q2 │ Q3 │  ← 硬件队列                     │ │
│  │   └──┬─┴──┬┴──┬┴──┬┘                                │ │
│  │      ↓    ↓    ↓    ↓                                   │ │
│  │   ┌────┐┌────┐┌────┐┌────┐                              │ │
│  │   │ W1 ││ W2 ││ W3 ││ W4 │  ← Worker 进程               │ │
│  │   └────┘└────┘└────┘└────┘                              │ │
│  │                                                         │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Layer 2: 事件级负载均衡                                      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                                                         │ │
│  │   Worker 1 ──┐                                          │ │
│  │   Worker 2 ──┼──→ Proxy ──→ Manager                     │ │
│  │   Worker 3 ──┤                                          │ │
│  │   Worker 4 ──┘                                          │ │
│  │                                                         │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 负载均衡方法

| 方法          | 说明                | 适用场景     |
| :------------ | :------------------ | :----------- |
| **PF_RING**   | 基于 DNA 的负载均衡 | 超高性能需求 |
| **AF_PACKET** | 基于 Linux 套接字   | 通用场景     |
| **RSS**       | 硬件 RSS            | 网卡支持 RSS |
| **None**      | 无负载均衡          | 单 Worker    |

---

## 2. PF_RING 负载均衡

### 2.1 PF_RING 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    PF_RING 架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────────┐│
│  │                    PF_RING Cluster                        ││
│  │                                                          ││
│  │   ┌──────────────────────────────────────────────────┐  ││
│  │   │  5-tuple Hash 负载均衡                            │  ││
│  │   │                                                  │  ││
│  │   │   (src_ip, dst_ip, src_port, dst_port, protocol) │  ││
│  │   │                                                  │  ││
│  │   └──────────────────────────────────────────────────┘  ││
│  │                           ↓                             ││
│  │   ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐    ││
│  │   │ VC0 │ VC1 │ VC2 │ VC3 │ VC4 │ VC5 │ VC6 │ VC7 │    ││
│  │   └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘    ││
│  │       ↓       ↓       ↓       ↓       ↓       ↓       ↓   ││
│  │   ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐                       ││
│  │   │ W1  │ │ W2  │ │ W3  │ │ W4  │  ...                 ││
│  │   └─────┘ └─────┘ └─────┘ └─────┘                       ││
│  └──────────────────────────────────────────────────────────┘│
│                           ↓                                  │
│  ┌──────────────────────────────────────────────────────────┐│
│  │                    Network Interface                      ││
│  │   eth0 ───────────────────────────────────────────────→  ││
│  └──────────────────────────────────────────────────────────┘│
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 PF_RING 源码结构

```cpp
// zeek/packet_analysis/protocol/pf_ring/pf_ring.h — PF_RING 分析器

namespace zeek::packet_analysis::pf_ring {

// PF_RING 配置
struct PF_RINGConfig {
    // 集群配置
    uint16_t cluster_id;         // 集群 ID (1-255)
    uint8_t cluster_type;        // 集群类型
                                 // 1 = 5-tuple (TCP/UDP)
                                 // 2 = 2-tuple (IP only)
                                 // 3 = 4-tuple (default)
                                 // 4 = round-robin

    // 捕获配置
    uint32_t snapshot_len;       // 快照长度
    bool promisc;                 // 是否混挂模式
    bool checksum_check;         // 校验和检查

    // 轮询配置
    uint32_t poll_timeout;       // 轮询超时（毫秒）
    uint32_t poll_num_pages;     // 内存页数
};

// PF_RING 句柄
struct PF_RINGHandle {
    pfring* ring;                // PF_RING 句柄
    uint16_t cluster_id;
    uint8_t traffic_index;       // 当前处理的虚拟容器

    // 统计
    uint64_t packets_received;
    uint64_t bytes_received;
    uint64_t drops;
};

// PF_RING 分析器
class PF_RINGAnalyzer : public packet_analysis::PacketAnalyzer {
public:
    PF_RINGAnalyzer(zeek::packet_analysis::Manager* mgr,
                    const std::string& name,
                    std::vector<std::string> args);

    // 初始化
    void Init(const PF_RINGConfig& config);

    // 抓包循环
    void CaptureLoop();

    // 包处理
    void ProcessPacket(const u_char* pkt, int len,
                      const pfring_pkthdr* hdr);

private:
    PF_RINGConfig config;
    PF_RINGHandle handle;

    // 虚拟容器映射
    std::map<uint8_t, ProcessInfo> container_map;
};

} // namespace zeek::packet_analysis::pf_ring
```

### 2.3 PF_RING 初始化

```cpp
// zeek/packet_analysis/protocol/pf_ring/pf_ring.cc — PF_RING 初始化

void PF_RINGAnalyzer::Init(const PF_RINGConfig& config)
    {
    this->config = config;

    // 1. 打开 PF_RING 设备
    handle.ring = pfring_open(config.interface.c_str(),
                              config.snapshot_len,
                              config.promisc);

    if (! handle.ring) {
        throw std::runtime_error("Failed to open PF_RING device: " +
                                  config.interface);
    }

    // 2. 设置集群模式
    int rc = pfring_set_cluster(handle.ring,
                                config.cluster_id,
                                (cluster_type)config.cluster_type);
    if (rc < 0) {
        throw std::runtime_error("Failed to set cluster: " +
                                  std::to_string(rc));
    }

    // 3. 设置轮询参数
    pfring_set_poll_timeout(handle.ring, config.poll_timeout);

    // 4. 启用捕获
    pfring_enable_ring(handle.ring);

    // 5. 获取集群信息
    pfring_version version;
    pfring_get_version(&version);
    }
```

### 2.4 PF_RING 抓包循环

```cpp
// zeek/packet_analysis/protocol/pf_ring/pf_ring.cc — 抓包循环

void PF_RINGAnalyzer::CaptureLoop()
    {
    u_char* pkt = nullptr;
    struct pfring_pkthdr hdr;

    while (! should_stop) {
        // 1. 等待数据包
        int rc = pfring_recv(handle.ring,
                            &pkt,
                            &hdr,
                            true);  // blocking

        if (rc < 0) {
            // 错误处理
            continue;
        }

        if (! hdr.len)
            continue;

        // 2. 获取源虚拟容器索引
        // PF_RING 自动根据 5-tuple hash 分配
        handle.traffic_index = hdr.hash;

        // 3. 处理数据包
        ProcessPacket(pkt, hdr.len, &hdr);

        // 4. 更新统计
        ++handle.packets_received;
        handle.bytes_received += hdr.len;

        if (hdr.dropped) {
            ++handle.drops;
        }
    }

    // 清理
    pfring_close(handle.ring);
    }
```

---

## 3. AF_PACKET 负载均衡

### 3.1 AF_PACKET 架构

```
┌─────────────────────────────────────────────────────────────┐
│                   AF_PACKET 架构                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────────┐│
│  │                    AF_PACKET Socket                       ││
│  │                                                          ││
│  │   ┌──────────────────────────────────────────────────┐  ││
│  │   │  TPACKET_V3 环形缓冲区                            │  ││
│  │   │                                                  │  ││
│  │   │   ┌────────────────────────────────────────┐     │  ││
│  │   │   │  Block 1  │  Block 2  │  Block 3  │    │     │  ││
│  │   │   └────────────────────────────────────────┘     │  ││
│  │   │                                                  │  ││
│  │   │   ┌────────────────────────────────────────┐     │  ││
│  │   │   │  Frame 1  │  Frame 2  │ ... │  Frame N │    │  ││
│  │   │   └────────────────────────────────────────┘     │  ││
│  │   │                                                  │  ││
│  │   └──────────────────────────────────────────────────┘  ││
│  └──────────────────────────────────────────────────────────┘│
│                           ↓                                   │
│  ┌──────────────────────────────────────────────────────────┐│
│  │                    Kernel Filter                          ││
│  │   BPF 过滤器 ───────────────────────────────────────────→  ││
│  └──────────────────────────────────────────────────────────┘│
│                           ↓                                   │
│  ┌──────────────────────────────────────────────────────────┐│
│  │                    Network Interface                      ││
│  │   eth0 ───────────────────────────────────────────────→  ││
│  └──────────────────────────────────────────────────────────┘│
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 AF_PACKET 源码结构

```cpp
// zeek/packet_analysis/protocol/af_packet/af_packet.h — AF_PACKET 分析器

namespace zeek::packet_analysis::af_packet {

// AF_PACKET 配置
struct AFPacketConfig {
    // 接口配置
    std::string interface;        // 接口名
    bool promisc;                // 混挂模式

    // 环形缓冲区配置
    uint32_t frame_size;         // 帧大小
    uint32_t num_frames;         // 帧数量
    uint32_t block_size;         // 块大小
    uint32_t num_blocks;         // 块数量

    // TPACKET 版本
    int tp_version;              // TPACKET_V1 / V2 / V3

    // 过滤器
    std::string bpf_filter;      // BPF 过滤表达式

    // 性能优化
    bool enable_zerocopy;        // 启用零拷贝
    uint32_t poll_timeout;       // 轮询超时
};

// AF_PACKET 句柄
struct AFPacketHandle {
    int fd;                      // Socket FD

    // 环形缓冲区
    struct tpacket_req3 req;     // TPACKET_V3 配置
    struct iovec* rx_ring;       // 接收环形缓冲区

    // 内存映射
    uint8_t* mmap_base;          // 映射内存基址
    size_t mmap_size;            // 映射大小

    // 统计
    uint64_t packets_received;
    uint64_t bytes_received;
    uint64_t drops;
};

// AF_PACKET 分析器
class AFPacketAnalyzer : public packet_analysis::PacketAnalyzer {
public:
    AFPacketAnalyzer(Manager* mgr,
                     const std::string& name,
                     std::vector<std::string> args);

    void Init(const AFPacketConfig& config);
    void CaptureLoop();

private:
    AFPacketConfig config;
    AFPacketHandle handle;

    // 处理数据包
    void ProcessRingBatch();
    void ProcessPacket(uint8_t* frame, uint32_t len, uint64_t ts);
};

} // namespace zeek::packet_analysis::af_packet
```

### 3.3 AF_PACKET 初始化

```cpp
// zeek/packet_analysis/protocol/af_packet/af_packet.cc — AF_PACKET 初始化

void AFPacketAnalyzer::Init(const AFPacketConfig& config)
    {
    this->config = config;

    // 1. 创建 AF_PACKET socket
    handle.fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (handle.fd < 0) {
        throw std::runtime_error("Failed to create socket: " +
                                  strerror(errno));
    }

    // 2. 获取接口索引
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, config.interface.c_str(), IFNAMSIZ-1);
    if (ioctl(handle.fd, SIOCGIFINDEX, &ifr) < 0) {
        throw std::runtime_error("Failed to get interface index");
    }
    int ifindex = ifr.ifr_ifindex;

    // 3. 绑定到接口
    struct sockaddr_ll addr;
    memset(&addr, 0, sizeof(addr));
    addr.sll_family = AF_PACKET;
    addr.sll_ifindex = ifindex;
    addr.sll_protocol = htons(ETH_P_ALL);

    if (bind(handle.fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        throw std::runtime_error("Failed to bind socket");
    }

    // 4. 配置 TPACKET_V3 环形缓冲区
    handle.req.tp_block_size = config.block_size;
    handle.req.tp_block_nr = config.num_blocks;
    handle.req.tp_frame_size = config.frame_size;
    handle.req.tp_frame_nr = config.num_frames;
    handle.req.tp_retire_blk_tov = 64;  // 超时（百毫秒）
    handle.req.tp_feature_req_word = TP_FEATURE_VERSION;

    if (setsockopt(handle.fd, SOL_PACKET, PACKET_RX_RING,
                   &handle.req, sizeof(handle.req)) < 0) {
        throw std::runtime_error("Failed to set RX ring");
    }

    // 5. 内存映射
    handle.mmap_size = config.block_size * config.num_blocks;
    handle.mmap_base = mmap(nullptr,
                            handle.mmap_size,
                            PROT_READ | PROT_WRITE,
                            MAP_SHARED | MAP_LOCKED,
                            handle.fd,
                            0);

    if (handle.mmap_base == MAP_FAILED) {
        throw std::runtime_error("Failed to mmap");
    }

    // 6. 设置混挂模式
    if (config.promisc) {
        strncpy(ifr.ifr_flags, IFF_PROMISC, IFNAMSIZ);
        ioctl(handle.fd, SIOCGIFFLAGS, &ifr);
    }
    }
```

### 3.4 AF_PACKET 抓包循环

```cpp
// zeek/packet_analysis/protocol/af_packet/af_packet.cc — 抓包循环

void AFPacketAnalyzer::CaptureLoop()
    {
    struct iovec* iov = handle.rx_ring;
    int poll_timeout = config.poll_timeout;

    while (! should_stop) {
        // 1. 等待数据包
        struct pollfd pfd;
        pfd.fd = handle.fd;
        pfd.events = POLLIN | POLLERR;
        pfd.revents = 0;

        int ret = poll(&pfd, 1, poll_timeout);

        if (ret <= 0) {
            // 超时或错误
            continue;
        }

        // 2. 处理可用块
        ProcessRingBatch();
    }

    // 清理
    munmap(handle.mmap_base, handle.mmap_size);
    close(handle.fd);
    }

void AFPacketAnalyzer::ProcessRingBatch()
    {
    // 获取当前可用块
    for (int i = 0; i < handle.req.tp_block_nr; ++i) {
        struct tpacket_block_desc* block =
            (struct tpacket_block_desc*)
            (handle.mmap_base + i * config.block_size);

        // 检查块是否可用
        if ((block->hdr.bh1.block_status & TP_STATUS_USER) == 0) {
            continue;
        }

        // 处理块中的所有帧
        char* frame = (char*)block + block->hdr.bh1.offset_to_pkt;
        struct tpacket3_hdr* tp_hdr = (struct tpacket3_hdr*)frame;

        while (tp_hdr) {
            if (tp_hdr->tp_status & TP_STATUS_USER) {
                uint8_t* payload = (uint8_t*)tp_hdr + tp_hdr->tp_mac;
                uint32_t len = tp_hdr->tp_snaplen;
                uint64_t ts = (uint64_t)tp_hdr->tp_sec * 1000000 +
                              tp_hdr->tp_nsec / 1000;

                ProcessPacket(payload, len, ts);

                tp_hdr->tp_status = TP_STATUS_KERNEL;
                ++handle.packets_received;
                handle.bytes_received += len;
            }

            tp_hdr = (struct tpacket3_hdr*)
                     ((uint8_t*)tp_hdr + tp_hdr->tp_next_offset);
        }

        // 解锁块
        block->hdr.bh1.block_status = TP_STATUS_KERNEL;
    }
    }
```

---

## 4. Flow 哈希算法

### 4.1 5-tuple 哈希

```cpp
// zeek/util/hash.h — Flow 哈希实现

#include <cstdint>
#include <cstring>

// 5-tuple 键
struct FiveTuple {
    uint32_t src_ip;      // 源 IP（网络字节序）
    uint32_t dst_ip;      // 目标 IP（网络字节序）
    uint16_t src_port;    // 源端口（网络字节序）
    uint16_t dst_port;    // 目标端口（网络字节序）
    uint8_t  protocol;    // 协议号（TCP=6, UDP=17）
};

// 5-tuple 哈希函数（用于 PF_RING 集群）
uint32_t HashFiveTuple(const FiveTuple& tuple)
    {
    // 初始哈希值（基于 Golden Ratio）
    uint32_t h = 0x9e3779b9;

    // 混合源 IP
    h ^= tuple.src_ip;
    h ^= (tuple.src_ip >> 17);
    h ^= (tuple.src_ip << 6);
    h ^= (tuple.dst_ip >> 11);
    h ^= (tuple.dst_ip << 4);

    // 混合端口
    h ^= tuple.src_port;
    h ^= (tuple.src_port >> 5);
    h ^= (tuple.dst_port << 3);
    h ^= (tuple.dst_port >> 7);

    // 混合协议
    h ^= tuple.protocol;
    h ^= (h << 13);
    h ^= (h << 23);

    return h;
    }

// 简化版哈希（仅 IP）
uint32_t HashTwoTuple(const FiveTuple& tuple)
    {
    uint32_t h = tuple.src_ip ^ tuple.dst_ip;
    h ^= (h >> 16);
    h *= 0x85ebca6b;
    h ^= (h >> 13);
    h *= 0xc2b2ae35;
    h ^= (h >> 16);
    return h;
    }
```

### 4.2 RSS 配置

```cpp
// zeek/packet_analysis/protocol/rss/rss.h — RSS 配置

namespace zeek::packet_analysis::rss {

// RSS 配置
struct RSSConfig {
    // 哈希函数
    enum class HashFunction {
        TOEPLITZ,          // 默认（Windows）
        SIMPLE_XOR,        // 简单 XOR
        INTEL_RSS          // Intel RSS
    };

    HashFunction hash_func;

    // 哈希类型
    uint32_t hash_types;   // RSS_HASH_TYPE_*
#define RSS_HASH_TYPE_IPV4    (1 << 0)
#define RSS_HASH_TYPE_TCP_IPV4 (1 << 1)
#define RSS_HASH_TYPE_UDP_IPV4 (1 << 2)
#define RSS_HASH_TYPE_IPV6    (1 << 3)
#define RSS_HASH_TYPE_TCP_IPV6 (1 << 4)
#define RSS_HASH_TYPE_UDP_IPV6 (1 << 5)

    // 间接表
    uint32_t indir_mask;   // 间接表大小掩码
    uint16_t indir_table[128];  // 间接表
    uint8_t  indir_size;    // 间接表大小
};

// RSS Toeplitz 哈希
uint32_t RSS_Toeplitz(const uint8_t* key,
                       const uint8_t* data,
                       size_t len)
    {
    uint32_t hash = 0;

    // 38字节的密钥（IPv4）或 40字节（IPv6）
    for (size_t i = 0; i < len; ++i) {
        uint8_t k = key[i];
        uint8_t d = data[i];

        // 处理字节中的每一位
        for (int j = 0; j < 8; ++j) {
            if (d & (1 << j)) {
                hash ^= ((uint32_t*)k)[j];
            }
        }
    }

    return hash;
    }
```

---

## 5. 多队列配置

### 5.1 网卡多队列配置

```bash
# 查看网卡队列
ethtool -l eth0

# 设置队列数
ethtool -L eth0 combined 8

# 查看 RSS 配置
ethtool -x eth0

# 设置 RSS 哈希键
ethtool -X eth0 hfunc toeplitz hks 3c:a6:2f:20:7e:5d:3f:8a:...

# 设置间接表
ethtool -X eth0 weighted_root_rss 0,1,2,3,4,5,6,7

# 设置队列权重
ethtool --set-priv-flags eth0 queue-weight 0:25,1:25,2:25,3:25
```

### 5.2 队列亲和

```bash
# 查看当前队列亲和
cat /proc/interrupts | grep eth0

# 设置 IRQ 亲和
# 假设 eth0-TxRx-0 的 IRQ 是 123
echo "0-7" > /proc/irq/123/smp_affinity_list

# 使用 set_irq_affinity.sh 脚本
./set_irq_affinity.sh all eth0
```

### 5.3 PF_RING 多进程配置

```ini
# node.cfg — PF_RING 多进程配置
[worker-1]
type = worker
host = worker-node-1.example.com
interface = eth0
lb_method = pf_ring
lb_procs = 8

# PF_RING 集群配置
pf_ring.cluster_id = 42
pf_ring.cluster_type = 3    # 5-tuple hash
pf_ring.cluster_per_flow = 2  # 每个 flow 使用 2 个 slot
```

---

## 6. 负载均衡策略

### 6.1 一致性哈希

```cpp
// zeek/util/consistent_hash.h — 一致性哈希

template<typename T>
class ConsistentHash {
public:
    // 添加节点
    void AddNode(const std::string& key, T value, int vnodes = 100)
        {
        // 为每个物理节点创建虚拟节点
        for (int i = 0; i < vnodes; ++i) {
            std::string vnode_key = key + "#" + std::to_string(i);
            uint32_t hash = Hash(vnode_key);
            ring[hash] = value;
        }
        nodes.insert(key);
        sorted = false;
        }

    // 移除节点
    void RemoveNode(const std::string& key, int vnodes = 100)
        {
        for (int i = 0; i < vnodes; ++i) {
            std::string vnode_key = key + "#" + std::to_string(i);
            uint32_t hash = Hash(vnode_key);
            ring.erase(hash);
        }
        nodes.erase(key);
        sorted = false;
        }

    // 查找节点
    T GetNode(const std::string& key)
        {
        if (ring.empty()) {
            throw std::runtime_error("No nodes available");
        }

        if (! sorted) {
            // 重建有序环
            sorted_keys.clear();
            for (auto& [hash, _] : ring) {
                sorted_keys.push_back(hash);
            }
            std::sort(sorted_keys.begin(), sorted_keys.end());
            sorted = true;
        }

        uint32_t hash = Hash(key);

        // 二分查找
        auto it = std::upper_bound(sorted_keys.begin(),
                                   sorted_keys.end(),
                                   hash);
        if (it == sorted_keys.end()) {
            it = sorted_keys.begin();
        }

        return ring[*it];
        }

private:
    uint32_t Hash(const std::string& key)
        {
        // MurmurHash3 或 FNV-1a
        return util::hash::MurmurHash3(key);
        }

    std::map<uint32_t, T> ring;
    std::vector<uint32_t> sorted_keys;
    std::set<std::string> nodes;
    bool sorted = false;
};
```

### 6.2 动态负载均衡

```cpp
// zeek/cluster/DynamicLB.h — 动态负载均衡

class DynamicLoadBalancer {
public:
    // 节点负载信息
    struct NodeLoad {
        std::string node_id;
        double cpu_usage;        // CPU 使用率 (0-1)
        double memory_usage;    // 内存使用率 (0-1)
        double queue_depth;     // 队列深度
        uint64_t pkts_per_sec;  // 每秒包数
        double load_score;      // 综合负载评分
    };

    // 更新节点负载
    void UpdateNodeLoad(const std::string& node_id,
                        const NodeLoad& load)
        {
        std::lock_guard<std::mutex> lock(mutex);
        node_loads[node_id] = load;
        CalculateLoadScores();
        }

    // 选择最佳节点
    std::string SelectNode(const FiveTuple& tuple)
        {
        std::lock_guard<std::mutex> lock(mutex);

        // 计算 flow hash
        uint32_t hash = HashFiveTuple(tuple);

        // 一致性哈希选择
        std::string target = consistent_hash.GetNode(
            std::to_string(hash));

        // 检查负载是否均衡
        if (NeedsRebalance()) {
            target = SelectLeastLoadedNode();
        }

        return target;
        }

private:
    // 计算综合负载评分
    double CalculateLoadScore(const NodeLoad& load)
        {
        // 加权平均
        return 0.4 * load.cpu_usage +
               0.2 * load.memory_usage +
               0.3 * load.queue_depth +
               0.1 * (load.pkts_per_sec / 1000000.0);
        }

    // 是否需要重平衡
    bool NeedsRebalance()
        {
        double max_load = 0, min_load = 1;
        for (auto& [_, load] : node_loads) {
            max_load = std::max(max_load, load.load_score);
            min_load = std::min(min_load, load.load_score);
        }
        return (max_load - min_load) > 0.3;  // 负载差距 > 30%
        }

    std::map<std::string, NodeLoad> node_loads;
    ConsistentHash<std::string> consistent_hash;
    std::mutex mutex;
};
```

---

## 7. 负载均衡监控

### 7.1 统计收集

```cpp
// zeek/cluster/LBStats.h — 负载均衡统计

struct LBStats {
    // 总体统计
    uint64_t total_packets;
    uint64_t total_bytes;
    uint64_t total_drops;

    // 每 Worker 统计
    std::map<std::string, WorkerStats> worker_stats;

    // 哈希分布
    std::vector<uint32_t> hash_distribution;  // 直方图
};

struct WorkerStats {
    std::string worker_id;
    uint64_t packets;
    uint64_t bytes;
    uint64_t drops;
    double cpu_usage;
    double queue_utilization;
};

// 获取统计
LBStats GetLBStats()
    {
    LBStats stats;

    // 从每个 Worker 获取统计
    for (auto& worker : workers) {
        WorkerStats ws;
        ws.worker_id = worker.id;

        // 通过 RPC 获取
        auto reply = Broker::Call(worker.address,
                                 "worker.get_stats",
                                 {});
        if (reply) {
            auto result = broker::get<broker::record>(*reply);
            ws.packets = result["packets"];
            ws.bytes = result["bytes"];
            ws.drops = result["drops"];
            ws.cpu_usage = result["cpu_usage"];
            ws.queue_utilization = result["queue_util"];
        }

        stats.worker_stats[worker.id] = ws;
        stats.total_packets += ws.packets;
        stats.total_bytes += ws.bytes;
        stats.total_drops += ws.drops;
    }

    return stats;
    }
```

### 7.2 哈希分布可视化

```bash
# 使用 zeekctl 查看负载分布
$ zeekctl show Load

Load Balancing Distribution:
  Worker 1 (worker-1): ████████████ 24.8%
  Worker 2 (worker-2): █████████████ 25.1%
  Worker 3 (worker-3): ████████████ 24.9%
  Worker 4 (worker-4): ████████████ 25.2%

  Total Packets: 1,234,567,890
  Total Drops: 12,345
  Drop Rate: 0.001%
```

---

## 8. 负载均衡故障排除

### 8.1 常见问题

```
问题 1: Worker 负载不均衡
原因: 哈希分布不均 / 单个 large flow 倾斜
解决: 调整 cluster_type 或使用动态负载均衡

问题 2: 包丢失率高
原因: 队列溢出 / CPU 瓶颈 / NIC 饱和
解决: 增加 Worker 数 / 优化 BPF 过滤 / 升级硬件

问题 3: Flow 被分割到不同 Worker
原因: PF_RING 集群 ID 冲突 / NAT 环境
解决: 检查集群 ID 唯一性 / 使用 2-tuple hash

问题 4: 性能低于预期
原因: 锁竞争 / 内存带宽瓶颈 / 中断处理
解决: CPU 亲和 / NUMA 优化 / 轮询模式
```

### 8.2 调试命令

```bash
# PF_RING 统计
cat /proc/net/pf_ring/info

# 查看 PF_RING 集群
cat /proc/net/pf_ring/dev/eth0/cluster

# AF_PACKET 统计
cat /proc/net/packet

# RSS 配置
ethtool -S eth0 | grep rss

# 查看中断分布
cat /proc/interrupts | grep -E 'eth0|NIC'

# 使用 perf 分析热点
perf top -ag -p $(pidof zeek-worker)
```

---

## 9. 总结

本章介绍了 Zeek 集群负载均衡的核心内容：

| 负载均衡方法   | 说明                | 关键参数                 |
| :------------- | :------------------ | :----------------------- |
| **PF_RING**    | 高性能 DNA 负载均衡 | cluster_id, cluster_type |
| **AF_PACKET**  | Linux 通用套接字    | block_size, num_blocks   |
| **RSS**        | 硬件加速哈希        | hash_types, indir_table  |
| **一致性哈希** | 分布式节点选择      | vnodes 数量              |

下一章我们将讨论**丢包处理**，包括丢包检测机制、Intel E810 / DAG 卡配置、以及故障排除方法。

---

> [!previous] 上一章：[[ch27-communication|第二十七章：通信]]
> [!next] 下一章：[[ch29-packet-loss|第二十九章：丢包处理]]
