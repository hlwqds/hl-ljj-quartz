---
title: "Zeek 深度探索 (二十九)：丢包处理"
date: 2026-04-15
tags:
  - zeek
  - series
  - cluster
  - packet-loss
  - Intel-E810
  - DAG
  - troubleshooting
description: "深入解析 Zeek 丢包处理——丢包检测、Intel E810 配置、DAG 卡、Tee 模式、流量镜像、故障排除"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ... 27. [[2026-04-15-zeek-deep-dive-ch27-communication|第二十七章：通信]] 28. [[2026-04-15-zeek-deep-dive-ch28-load-balancing|第二十八章：负载均衡]] 29. **第二十九章：丢包处理**

---

## 1. 丢包概述

丢包是网络分析系统面临的核心挑战之一，尤其在高吞吐量环境下。

```
┌─────────────────────────────────────────────────────────────┐
│                      丢包类型                                │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. NIC 丢包                                                  │
│     - 硬件队列溢出                                            │
│     - RSS 负载不均                                            │
│     - 校验和错误                                               │
│                                                              │
│  2. 驱动丢包                                                  │
│     - DMA 环形缓冲区满                                         │
│     - 内存映射失败                                             │
│     - 中断节流过度                                             │
│                                                              │
│  3. 内核丢包                                                  │
│     - SO_RCVBUF 不足                                          │
│     - net.core.rmem_max 限制                                  │
│     - BPF 过滤器过载                                           │
│                                                              │
│  4. 应用丢包                                                  │
│     - 用户空间缓冲区满                                         │
│     - 处理速度低于接收速度                                      │
│     - 锁竞争                                                  │
│                                                              │
│  5. 集群丢包                                                  │
│     - Worker 故障转移期间                                      │
│     - Proxy 缓冲溢出                                           │
│     - 网络分区                                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 丢包影响

| 丢包类型      | 影响             | 严重程度 |
| :------------ | :--------------- | :------- |
| 丢连接开始    | 无法跟踪完整会话 | 高       |
| 丢应用层数据  | 丢失关键 payload | 高       |
| 丢 Keep-Alive | 会话超时         | 中       |
| 丢 FIN/RST    | 会话关闭延迟     | 低       |

---

## 2. 丢包检测机制

### 2.1 Zeek 丢包统计

```zeek
# zeek/scripts/base/frameworks/packet-filter/capture-loss.zeek

module CaptureLoss;

export {
    # 丢包统计记录
    type Info: record {
        ts: time;                    # 时间戳
        pkts: count;                # 观察到的包数
        bytes: count;               # 观察到的字节数
        drops: count;               # 检测到的丢包数
        dead_packets: count;        # 无效包数
        offset: count;              # 序列号偏移
    };

    # 全局统计
    global stats: Info;

    # 丢包阈值
    redef capture_loss_threshold = 1e-3;  # 0.1% 丢包率告警阈值
}

# 丢包检测事件
event capture_loss_update(u: count, d: count, i: count)
    {
    local current = network_time();
    local loss_rate = double(d) / double(u + d);

    # 更新统计
    stats$pkts = u;
    stats$drops = d;
    stats$offset = i;

    # 记录到日志
    Log::write(CaptureLoss::LOG, stats);

    # 超过阈值时告警
    if (loss_rate > capture_loss_threshold) {
        NOTICE([$note = CaptureLoss::HighLossRate,
                $msg = fmt("High packet loss: %.2f%% (%d/%d)",
                          loss_rate * 100, d, u + d)]);
    }
    }
```

### 2.2 PF_RING 丢包检测

```cpp
// zeek/packet_analysis/protocol/pf_ring/pf_ring.cc — PF_RING 丢包

void PF_RINGAnalyzer::CheckDrops()
    {
    // 1. 检查 PF_RING 丢包
    uint64_t tot_recv = 0, tot_drop = 0;
    pfring_stats stats;
    pfring_stats_num(handle.ring, &stats);

    tot_recv = stats.recv;
    tot_drop = stats.drop;

    // 2. 计算丢包率
    double drop_rate = 0.0;
    if (tot_recv + tot_drop > 0) {
        drop_rate = (double)tot_drop / (tot_recv + tot_drop);
    }

    // 3. 超过阈值时记录
    if (drop_rate > config.drop_threshold) {
        Reporter::Warning("PF_RING drop rate: %.2f%% (%lu/%lu)",
                         drop_rate * 100, tot_drop, tot_recv);
    }

    // 4. 报告到 Manager
    if (cluster_mode) {
        BrokerComm::Publish("zeek/cluster/packet_drops", {
            broker::data{node_id},
            broker::data{tot_drop},
            broker::data{drop_rate}
        });
    }
    }
```

### 2.3 AF_PACKET 丢包检测

```cpp
// zeek/packet_analysis/protocol/af_packet/af_packet.cc — AF_PACKET 丢包

void AFPacketAnalyzer::CheckDrops()
    {
    // 1. 获取 socket 统计
    struct tpacket_stats_v3 stats;
    socklen_t len = sizeof(stats);
    getsockopt(handle.fd, SOL_PACKET, PACKET_STATISTICS,
               &stats, &len);

    uint64_t tot_recv = stats.pk_pending;
    uint64_t tot_drop = stats.tp_drops;

    // 2. 计算丢包率
    double drop_rate = 0.0;
    uint64_t total = tot_recv + tot_drop;
    if (total > 0) {
        drop_rate = (double)tot_drop / total;
    }

    // 3. 检查环形缓冲区溢出
    if (stats.tp_blk_drops > 0) {
        Reporter::Warning("AF_PACKET block drops: %u",
                         stats.tp_blk_drops);
    }

    if (stats.tp_hwt_drops > 0) {
        Reporter::Warning("AF_PACKET hardware drops: %u",
                         stats.tp_hwt_drops);
    }

    // 4. 记录统计
    handle.packets_received = tot_recv;
    handle.drops = tot_drop;

    // 5. 周期性报告
    static uint64_t last_total = 0;
    uint64_t delta = tot_drop - last_total;
    last_total = tot_drop;

    if (delta > 0 && delta > config.drop_threshold) {
        Reporter::Warning("AF_PACKET drops: %lu (rate: %.2f%%)",
                         delta, drop_rate * 100);
    }
    }
```

---

## 3. Intel E810 配置

### 3.1 Intel E810 概述

Intel E810 是新一代 100GbE 网卡，提供高级丢包检测和优化功能。

```
┌─────────────────────────────────────────────────────────────┐
│                    Intel E810 架构                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────────┐│
│  │                    E810 Features                          ││
│  │                                                          ││
│  │   • 100GbE 吞吐量                                         ││
│  │   • 16 硬件队列（每个方向）                                 ││
│  │   • 动态队列分配（DQA）                                    ││
│  │   • Data Center Bridging (DCB)                           ││
│  │   • 精确时间同步 (IEEE 1588 PTP)                          ││
│  │   • SR-IOV 虚拟化                                          ││
│  │   • 丢包统计 (PDS)                                        ││
│  │   • Flow Director (Intel FDIR)                           ││
│  │   • RSS + FDIR 组合                                       ││
│  │                                                          ││
│  └──────────────────────────────────────────────────────────┘│
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 E810 驱动配置

```bash
# 加载 ice 驱动
modprobe ice

# 查看驱动版本
ethtool -i eth0 | grep driver

# 启用多队列
ethtool -L eth0 combined 16

# 设置 MTU
ip link set eth0 mtu 9000

# 启用 Flow Director（可选）
ethtool -K eth0 ntuple on

# 设置 RSS 哈希
ethtool -X eth0 hfunc toeplitz hks <hash_key>

# 查看 E810 特定统计
ethtool -S eth0 | grep -E 'drop|error|disc'
```

### 3.3 E810 丢包监控

```bash
# 查看完整统计
ethtool -S eth0

# 监控丢包（实时）
watch -n1 'ethtool -S eth0 | grep drop'

# 查看队列统计
ethtool -S eth0 | grep -E 'queue_[0-9]+'

# 查看 DCB 状态
dcbtool show dev eth0

# 查看 PTP 状态
ethtool -T eth0
```

### 3.4 E810 丢包寄存器

```cpp
// zeek/packet_analysis/protocol/intel-e810/e810.h — E810 丢包

namespace zeek::packet_analysis::intel_e810 {

// E810 丢包寄存器
struct E810DropStats {
    // 全局丢包
    uint64_t rsv_drop;         // RSVDbuf 丢弃
    uint64_t err_drop;         // Error 丢弃
    uint64_t sec_drop;         # Security 丢弃

    // 队列丢包
    uint64_t q_drop[16];       // 每个队列的丢包

    // FDir 丢包
    uint64_t fdir_drop;        // Flow Director 丢弃

    // NVM 丢包
    uint64_t nvm_sec_drop;     // NVM 错误丢弃
};

// 读取丢包统计
void ReadDropStats(int fd, E810DropStats* stats)
    {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "eth0", IFNAMSIZ);

    // 使用 ethtool 获取统计
    struct ethtool_stats regs;
    regs.cmd = ETHTOOL_GSTATS;
    ifr.ifr_data = &regs;

    if (ioctl(fd, SIOCETHTOOL, &ifr) < 0) {
        throw std::runtime_error("Failed to get stats");
    }

    // 解析统计
    memcpy(stats, regs.data, sizeof(E810DropStats));
    }
```

---

## 4. DAG 卡配置

### 4.1 DAG 卡概述

DAG（Digital Aggregator）卡是 Endace 推出的高速网络捕获卡，专门设计用于**零丢包**数据包捕获。

```
┌─────────────────────────────────────────────────────────────┐
│                      DAG 卡架构                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────────┐│
│  │                    DAG Card                               ││
│  │                                                          ││
│  │   ┌──────────────────────────────────────────────────┐  ││
│  │   │  Hardware Capture Engine                          │  ││
│  │   │  • Zero-copy DMA                                 │  ││
│  │   │  • Hardware timestamping                         │  ││
│  │   │  • Hardware filtering                            │  ││
│  │   │  • Long bubble-free capture                      │  ││
│  │   └──────────────────────────────────────────────────┘  ││
│  │                                                          ││
│  │   ┌──────────────────────────────────────────────────┐  ││
│  │   │  Stream Interface                                │  ││
│  │   │  • PCI Express Gen3/4                           │  ││
│  │   │  • 100GbE+ throughput                           │  ││
│  │   │  • Dual port configuration                      │  ││
│  │   └──────────────────────────────────────────────────┘  ││
│  │                                                          ││
│  └──────────────────────────────────────────────────────────┘│
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 DAG 卡源码结构

```cpp
// zeek/packet_analysis/protocol/dag/dag.h — DAG 分析器

namespace zeek::packet_analysis::dag {

// DAG 配置
struct DAGConfig {
    // 设备路径
    std::string device;         // /dev/dag0, /dev/dag1, etc.

    // 捕获模式
    enum CaptureMode {
        MODE_CAPTURE,           // 正常捕获
        MODE_STATISTICS,        // 仅统计
        MODE_MONITOR,           // 监控模式（镜像）
        MODE_TEE               # Teeproxy（分路）
    };
    CaptureMode mode;

    // 过滤器
    std::string bpf_filter;     // BPF 过滤表达式
    uint32_t filter_flags;      // 硬件过滤器标志

    // 流配置
    bool enable_streaming;      // 启用流模式
    uint32_t stream_buffer_size; // 流缓冲区大小

    // 时间戳
    bool use_hardware_ts;       // 使用硬件时间戳
    uint32_t ts_format;         # TS_FORMAT_* (NSC, NGP, etc.)
};

// DAG 句柄
struct DAGHandle {
    int fd;                     // DAG 设备文件描述符
    dagrec_t* rec;             // 记录描述符
    struct sched_param sched;  # 调度参数

    // 流
    struct {
        void* base;
        size_t size;
    } rx_ring;                 // 接收环形缓冲区

    // 统计
    uint64_t packets_received;
    uint64_t bytes_received;
    uint64_t drops;
    uint64_t errors;
};

// DAG 分析器
class DAGAnalyzer : public PacketAnalyzer {
public:
    DAGAnalyzer(Manager* mgr, const std::string& name);

    void Init(const DAGConfig& config);
    void CaptureLoop();
    void ProcessPacket(const uint8_t* data, uint32_t len, uint64_t ts);

private:
    DAGConfig config;
    DAGHandle handle;
    std::vector<uint8_t> packet_buffer;
};

} // namespace zeek::packet_analysis::dag
```

### 4.3 DAG 卡初始化

```cpp
// zeek/packet_analysis/protocol/dag/dag.cc — DAG 初始化

void DAGAnalyzer::Init(const DAGConfig& config)
    {
    this->config = config;

    // 1. 打开 DAG 设备
    handle.fd = open(config.device.c_str(), O_RDONLY);
    if (handle.fd < 0) {
        throw std::runtime_error("Failed to open DAG device: " +
                                  config.device + ": " +
                                  strerror(errno));
    }

    // 2. 获取 DAG 接口版本
    uint32_t dag_version = dagapi_getversion(handle.fd);
    print fmt("DAG version: %u.%u.%u",
              (dag_version >> 16) & 0xFF,
              (dag_version >> 8) & 0xFF,
              dag_version & 0xFF);

    // 3. 配置捕获模式
    switch (config.mode) {
    case DAGConfig::MODE_CAPTURE:
        dagapi_configure_stream(handle.fd, 0,
                               DAG_CONFIG_MODE_CAPTURE, NULL);
        break;
    case DAGConfig::MODE_TEE:
        dagapi_configure_stream(handle.fd, 0,
                               DAG_CONFIG_MODE_TEE, NULL);
        break;
    case DAGConfig::MODE_MONITOR:
        dagapi_configure_stream(handle.fd, 0,
                               DAG_CONFIG_MODE_MONITOR, NULL);
        break;
    }

    // 4. 设置过滤器
    if (! config.bpf_filter.empty()) {
        struct bpf_program bpf;
        if (pcap_compile_nopcap(65535, DLT_EN10MB,
                                 &bpf,
                                 config.bpf_filter.c_str(),
                                 1, 0) == 0) {
            dagapi_set_filter(handle.fd, 0, &bpf);
            pcap_freecode(&bpf);
        }
    }

    // 5. 配置时间戳格式
    if (config.use_hardware_ts) {
        dagapi_set_timestamp_format(handle.fd, 0,
                                   config.ts_format,
                                   NULL);
    }

    // 6. 初始化流缓冲区
    handle.rx_ring.size = config.stream_buffer_size;
    handle.rx_ring.base = dagapi_mmap(handle.fd,
                                       &handle.rx_ring.size);

    if (handle.rx_ring.base == MAP_FAILED) {
        throw std::runtime_error("Failed to mmap DAG device");
    }

    // 7. 设置实时调度
    handle.sched.sched_priority = 51;
    if (pthread_setschedparam(pthread_self(), SCHED_FIFO,
                              &handle.sched) != 0) {
        Reporter::Warning("Failed to set real-time priority");
    }

    // 8. 启动捕获
    dagapi_start(handle.fd, 0);
    }
```

### 4.4 DAG Tee 模式

Tee 模式允许 DAG 卡在**零丢包**捕获的同时，将流量镜像到其他分析工具。

```cpp
// zeek/packet_analysis/protocol/dag/dag.cc — Tee 模式

void DAGAnalyzer::CaptureLoop()
    {
    uint8_t* buffer = (uint8_t*)handle.rx_ring.base;
    size_t buffer_size = handle.rx_ring.size;

    while (! should_stop) {
        // 1. 等待新数据
        int wait_result = dagapi_wait(handle.fd, 0, 1000);
        if (wait_result <= 0) {
            continue;
        }

        // 2. 获取捕获的数据
        struct timeval ts;
        uint16_t len;
        uint8_t* data = dagapi_next(handle.fd, 0, &ts, &len);

        while (data != NULL) {
            // 3. 处理数据包
            ProcessPacket(data, len,
                         (uint64_t)ts.tv_sec * 1000000 +
                         ts.tv_usec);

            // 4. 更新统计
            ++handle.packets_received;
            handle.bytes_received += len;

            // 5. 获取下一个包
            data = dagapi_next(handle.fd, 0, &ts, &len);
        }

        // 6. 释放已处理的内存
        dagapi_release(handle.fd, 0, wait_result);
    }
    }

// 配置 Tee 输出
void ConfigureTeeOutput(const std::string& dag_device,
                       const std::string& output_device)
    {
    // 创建 Tee 流
    struct tee_stream_config config;
    memset(&config, 0, sizeof(config));
    config.output_type = TEE_OUTPUT_UDP;
    config.output_addr = output_device.c_str();
    config.output_port = 9000;
    config.mode = TEE_MODE_MIRROR;

    dagapi_configure_tee_stream(dag_device.c_str(), 0, &config);
    }
```

---

## 5. 流量镜像 (Tee)

### 5.1 Tee 模式原理

```
┌─────────────────────────────────────────────────────────────┐
│                      Tee 模式原理                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   SPAN / TAP                                                 │
│       │                                                      │
│       ├──────────────────────────────────────┐               │
│       │                                      │               │
│       ↓                                      ↓               │
│  ┌─────────┐                          ┌─────────┐             │
│  │  Zeek   │                          │  IDS    │             │
│  │ Worker  │  ←─ copy ──             │ (Suricata)           │
│  └─────────┘                          └─────────┘             │
│       │                                                      │
│       └──────────────────────────────────────┐               │
│                                              ↓               │
│                                        ┌─────────┐             │
│                                        │ Storage │             │
│                                        │ (PCAP)  │             │
│                                        └─────────┘             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Linux Traffic Tee

```bash
# 使用 ipvsadm 进行流量镜像（测试环境）
# 注意：这种方式会引入延迟，不适合生产

# 创建虚拟接口
ip link add name tee0 type dummy
ip link set tee0 up

# 使用 tc 镜像流量到 tee0
tc qdisc add dev eth0 ingress
tc filter add dev eth0 parent ffff: \
    action mirred egress mirror dev tee0

# 查看 tc 规则
tc filter show dev eth0 parent ffff:
```

### 5.3 Suricata NFQ Tee

```yaml
# suricata.yaml — Suricata Tee
# 注意：Zeek 集群中通常不使用 Suricata Tee
# 而是使用硬件 TAP 或镜像交换机

# NFQ 模式下的流量镜像
# ... (Suricata 配置)
```

---

## 6. 丢包故障排除

### 6.1 诊断流程

```
┌─────────────────────────────────────────────────────────────┐
│                    丢包诊断流程                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Step 1: 确认丢包                                            │
│  ├─ → 检查 Zeek capture_loss.log                           │
│  ├─ → 检查系统 dmesg                                         │
│  └─ → 检查 NIC 统计 ethtool -S eth0                         │
│                                                              │
│  Step 2: 定位丢包层级                                        │
│  ├─ → NIC 层: 硬件队列溢出、校验和错误                        │
│  ├─ → 驱动层: DMA 环形缓冲区满                                │
│  ├─ → 内核层: SO_RCVBUF、netdev backlog                      │
│  └─ → 应用层: 用户缓冲区、处理延迟                            │
│                                                              │
│  Step 3: 针对性优化                                          │
│  └─ → 根据定位结果调整参数                                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 诊断命令

```bash
# ===== 系统层面 =====

# 检查 dmesg 中的网络错误
dmesg | grep -iE 'eth|net|ring|dma|drop|error'

# 查看网络接口统计
ip -s link show eth0

# 查看 TCP 缓冲统计
ss -s

# 查看网络缓冲
netstat -an | grep -E 'Mem|buf'

# 查看中断统计
cat /proc/interrupts | head -20

# 查看 CPU 使用
top -bn1 | head -20

# ===== NIC 层面 =====

# 查看 NIC 统计（Intel）
ethtool -S eth0 | grep -E 'drop|error|ovf'

# 查看 PF_RING 统计
cat /proc/net/pf_ring/dev/eth0/stats

# 查看 AF_PACKET 统计
cat /proc/net/packet

# 查看 RSS 分布
ethtool -S eth0 | grep rss

# ===== Zeek 层面 =====

# 检查 capture_loss.log
grep -v "^#" capture_loss.log | tail -20

# 检查 zeek diag 输出
zeekctl diag worker-1

# 查看 zeek 进程状态
ps aux | grep zeek

# 查看 zeek 内存使用
ps -o rss,vsz $(pidof zeek-worker) | awk '{print "RSS: " $1 " KB, VSZ: " $2 " KB"}'
```

### 6.3 常见问题与解决方案

| 问题           | 原因         | 解决方案            |
| :------------- | :----------- | :------------------ |
| PF_RING 丢包   | DMA 缓冲区小 | 增加 `pf_ring` 内存 |
| AF_PACKET 丢包 | 环形缓冲区小 | 增加 `num_blocks`   |
| RSS 不均       | 哈希分布问题 | 调整 `indir_table`  |
| 处理延迟       | CPU 瓶颈     | 增加 Worker 数      |
| 中断风暴       | 多核调度问题 | CPU 亲和            |
| 内存不足       | mmap 过大    | 调整缓冲区大小      |
| 连接超时       | Proxy 过载   | 增加 Proxy 数       |

### 6.4 优化参数

```bash
# ===== 内核参数优化 =====

# 增加网络缓冲区
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.rmem_default=67108864
sysctl -w net.core.netdev_max_backlog=50000
sysctl -w net.core.somaxconn=4096

# 增加文件描述符
sysctl -w fs.file-max=2097152

# 减少内核日志
sysctl -w kernel.printk="3 4 1 3"

# 启用 RPS（Receive Packet Steering）
echo f > /sys/class/net/eth0/queues/rx-0/rps_cpus

# ===== PF_RING 参数 =====

# 增加 DMA 缓冲区
echo 4096 > /proc/sys/net/pf_ring/max_buff_size
echo 4096 > /proc/sys/net/pf_ring/buff_size

# ===== NIC 参数 =====

# 启用 adaptive rx/tx
ethtool -C eth0 rx-usecs 50 tx-usecs 50 adaptive-rx on adaptive-tx on

# 设置中断节流
ethtool -C eth0 rx-usecs 50

# 启用 Generic Receive Offload
ethtool -K eth0 gro on

# 启用 Generic Segmentation Offload
ethtool -K eth0 gso on
```

---

## 7. 高可用丢包防护

### 7.1 多路径捕获

```cpp
// zeek/cluster/MultiPathCapture.h — 多路径捕获

class MultiPathCapture {
public:
    // 添加捕获点
    void AddCapturePoint(const CapturePoint& cp)
        {
        capture_points.push_back(cp);
        }

    // 发送数据包到所有捕获点
    void SendToAll(const Packet* pkt)
        {
        for (auto& cp : capture_points) {
            if (cp.IsHealthy()) {
                cp.Send(pkt);
            }
        }
        }

    // 检查健康状态
    void CheckHealth()
        {
        for (auto& cp : capture_points) {
            if (! cp.IsHealthy()) {
                // 尝试重新连接
                cp.Reconnect();
            }
        }
        }

private:
    std::vector<CapturePoint> capture_points;
};
```

### 7.2 故障转移配置

```zeek
# site/failover-capture.zeek — 故障转移配置

@load base/frameworks/cluster

# 定义备用捕获点
redef CaptureLoss::backup_capture_points = {
    [$interface = "eth1", $weight = 0.2],
    [$interface = "eth2", $weight = 0.1]
};

# 配置故障转移阈值
redef CaptureLoss::failover_threshold = 0.01;  # 1% 丢包率触发

# 配置健康检查间隔
redef CaptureLoss::health_check_interval = 30sec;

# 配置自动故障转移
redef CaptureLoss::auto_failover = T;
```

---

## 8. 总结

本章介绍了 Zeek 集群丢包处理的核心内容：

| 丢包类型     | 检测方法               | 解决方案      |
| :----------- | :--------------------- | :------------ |
| **NIC 丢包** | ethtool 统计           | 调整队列、RSS |
| **驱动丢包** | PF_RING/AF_PACKET 统计 | 增加缓冲区    |
| **内核丢包** | /proc/net/\*           | 调整 sysctl   |
| **应用丢包** | capture_loss.log       | 增加 Worker   |
| **集群丢包** | Broker 状态            | HA 配置       |

丢包处理的核心是**监控 -> 定位 -> 优化**的循环过程。通过合理的架构设计和参数调优，可以将丢包率控制在极低水平（< 0.01%）。

---

## Part V 总结

本部分（第二十五至二十九章）系统介绍了 Zeek 集群的核心内容：

| 章节     | 主题     | 关键点                           |
| :------- | :------- | :------------------------------- |
| **ch25** | 集群架构 | Manager/Proxy/Worker/Logger 角色 |
| **ch26** | 集群配置 | node.cfg、cluster-layout.zeek    |
| **ch27** | 通信     | Broker 通信框架、发布订阅、RPC   |
| **ch28** | 负载均衡 | PF_RING、AF_PACKET、Flow 哈希    |
| **ch29** | 丢包处理 | 丢包检测、Intel E810、DAG 卡     |

---

> [!previous] 上一章：[[2026-04-15-zeek-deep-dive-ch28-load-balancing|第二十八章：负载均衡]]
> [!next] 下一章：[[2026-04-15-zeek-deep-dive-ch30-script-plugin|第三十章：脚本插件]]
