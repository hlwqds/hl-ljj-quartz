---
title: "DPDK 第三十二章：pktgen 流量生成与测试场景"
date: 2026-04-09 15:42:00
tags: [dpdk, pktgen, testing, performance, network]
description: "深入解析 DPDK pktgen 流量生成器：架构、命令、脚本编写与真实测试场景"
---

# DPDK 第三十二章：pktgen 流量生成与测试场景

> [!abstract] 核心要点
> pktgen 是 DPDK 官方提供的高速流量生成器，可实现 10Gbps+ 线速发包。本章讲解其架构、命令行使用、 Lua 脚本编写，以及典型的性能测试场景。

## 1. pktgen 简介

**pktgen**（又称 `pktgen-dpdk`）是 DPDK 自带的命令行流量生成器，起源于 `pktgen` 项目，由 Intel 工程师维护。与 `testpmd` 不同，pktgen 专注于**高速流量生成**和**性能基准测试**。

### 核心特性

- **零丢包发送**：基于硬件时间戳精确控制发包速率
- **多流支持**：支持配置多个flows/hash分布
- **统计精确**：实时显示 RX/TX pps、Lbits/s、CPU 利用率
- **脚本化**：内置 Lua 引擎支持复杂测试场景
- ** DPDK 23.11+**：支持 `pktgen` 作为新命令行版本

## 2. 架构解析

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────┐
│                    pktgen CLI                        │
│  (命令解析、Lua 脚本执行、统计显示、键盘交互)         │
└──────────────────┬──────────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────────┐
│              Lua Interpreter                         │
│  (执行 .pkt 文件中的 Lua 脚本)                        │
└──────────────────┬──────────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────────┐
│              Port Manager                            │
│  (每个端口独立线程，绑定 lcore)                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │  Port 0     │  │  Port 1     │  │  Port N     │ │
│  │  TX/RX      │  │  TX/RX      │  │  TX/RX      │ │
│  └─────────────┘  └─────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 2.2 发包流程

```c
// pktgen 支持的发送模式
enum pktgen_send_mode {
    SEND_ARP,       // ARP 请求
    SEND_ROUTE,     // 路由模式
    SEND_PKT,       // 普通数据包
    SEND_RATE,      // 指定速率
    SEND_BURST,     // Burst 发送
};
```

1. **包构造**：Lua 脚本定义 packet template（以太网头、IP头、UDP/TCP头、自定义payload）
2. **速率控制**：通过 `rte_cycles` 和 `hz` 计算每个包发送时间
3. **发送循环**：`rte_eth_tx_burst()` burst 发送
4. **统计更新**：每 N 帧更新一次屏幕统计

### 2.3 核心数据结构

```c
// port_info_t - 每个端口的状态
typedef struct port_info_s {
    uint16_t port_id;
    uint64_t port_mask;
    
    // 发送统计
    uint64_t stats.tx_packets;
    uint64_t stats.tx_bytes;
    uint64_t stats.tx_dropped;
    double   stats.tx_rate;      // pps
    
    // 接收统计  
    uint64_t stats.rx_packets;
    uint64_t stats.rx_bytes;
    uint64_t stats.rx_dropped;
    double   stats.rx_rate;      // pps
    
    // 配置
    uint8_t  send_mode;          // 发送模式
    uint8_t  seq_state[N_PORTS];// 序列号状态
} port_info_t;
```

## 3. 编译与安装

### 3.1 从 DPDK 源码编译

```bash
# 1. 编译 DPDK（如未编译）
cd $DPDK_DIR
meson setup build
ninja -C build

# 2. 编译 pktgen
git clone https://github.com/pktgen/Pktgen.git
cd Pktgen
meson setup build
ninja -C build

# 3. 检查依赖
ls build/app/pktgen
```

### 3.2 依赖项

```bash
# Ubuntu/Debian
sudo apt install -y liblua5.3-dev lua5.3 pkg-config \
    libnuma-dev libpcap-dev meson python3

# Fedora/RHEL
sudo dnf install -y lua-devel numactl-devel \
    libpcap-devel meson python3
```

## 4. 命令行使用

### 4.1 基础启动

```bash
# 经典方式
sudo ./pktgen -l 0,1,2,3 -n 4 -- \
    -P -m [0:1].0 -m [2:3].1

# 参数说明：
# -l 0,1,2,3     : 分配 lcore（lcores 0-3）
# -n 4            : 内存通道数
# -P              : 启用混杂模式
# -m [0:1].0      : lcore 0 收包，lcore 1 发包，端口 0
# -m [2:3].1      : lcore 2 收包，lcore 3 发包，端口 1
```

### 4.2 常用启动参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `-l` | lcore 列表 | `-l 0,1,2,3` |
| `-n` | 内存通道 | `-n 4` |
| `-m` | 端口-lcore 映射 | `-m [0:1].0` |
| `-P` | 混杂模式 | `-P` |
| `--` | 分隔符 | `--` |
| `-T` | 启用彩色输出 | `-T` |
| `-N` | 禁用 NUMA 警告 | `-N` |

### 4.3 交互命令

启动后进入交互界面，支持键盘命令：

```
# 常规命令
quit                    # 退出
reset                   # 重置所有统计
cls                     # 清屏

# 发送控制
start <port>            # 启动端口发包
stop <port>             # 停止端口发包
start all               # 启动所有端口
stop all                # 停止所有端口

# 速率配置
set <port> rate <pps>   # 设置发包速率(pps)
set <port> size <size>  # 设置包大小

# 流量配置  
set <port> dst mac <MAC>      # 目标 MAC
set <port> src mac <MAC>      # 源 MAC
set <port> dst ip <IP>        # 目标 IP
set <port> src ip <IP>        # 源 IP
set <port> proto <udp|tcp>    # 协议

# 统计
show <port> stats             # 显示端口统计
show <port> rate              # 显示速率统计
```

## 5. Lua 脚本

pktgen 支持 Lua 脚本，是实现复杂测试场景的关键。

### 5.1 基本脚本

```lua
-- 01-*.pkt - 基本 UDP 发包
package.path = package.path ..";?.lua;./lua/?.lua"

-- 初始化
pktgen.set("all", "seq_cnt", 0)

-- 配置端口 0
pktgen.set_port(0, "dst_mac", "00:00:00:00:00:01")
pktgen.set_port(0, "src_mac", "00:00:00:00:00:02")
pktgen.set_port(0, "dst_ip", "10.0.0.1")
pktgen.set_port(0, "src_ip", "192.168.0.1")
pktgen.set_port(0, "proto", "udp")
pktgen.set_port(0, "port", 8080)

-- 设置发包速率
pktgen.set(0, "rate", 100)  -- 100%

-- 启动
pktgen.start(0)
```

### 5.2 多流/梯度测试脚本

```lua
-- 多流测试：模拟真实网络流量分布
package.path = package.path ..";?.lua;./lua/?.lua"

local mg       = require("mg_common")
local ports    = mg.getPorts()

-- 源/目的 IP 分布（模拟 10K flows）
local src_ip_start = "10.0.1.0"
local dst_ip_start = "172.16.0.0"

functionSetup = function()
    for i, p in ipairs(ports) do
        -- 配置多个 sequence（流）
        for seq = 0, 9 do
            local src_ip = incrementIpAddr(src_ip_start, seq * 256)
            local dst_ip = incrementIpAddr(dst_ip_start, seq * 256)
            
            pktgen.set_port(p, seq ..".dst_mac", "00:00:00:00:00:01")
            pktgen.set_port(p, seq ..".src_mac", "00:1B:21:00:12:34")
            pktgen.set_port(p, seq ..".src_ip", src_ip .."/24")
            pktgen.set_port(p, seq ..".dst_ip", dst_ip)
            pktgen.set_port(p, seq ..".proto", "tcp")
            pktgen.set_port(p, seq ..".dpi", 80)  -- 目标端口
        end
        
        -- 启用全部 sequence
        pktgen.set(p, "seq_cnt", 10)
    end
end

-- 运行时：梯度增加速率
for rate = 10, 100, 10 do
    pktgen.set("all", "rate", rate)
    pktgen.delay(5000)  -- 5秒
end

-- 清理
pktgen.stop("all")
```

### 5.3 发送 Packet Burst

```lua
-- 发送自定义 packet 模板
local eth_vlan = "Ether(dst=\"00:00:00:00:00:01\", type=0x8100)/ \
                 Dot1Q(vlan=100)/ \
                 IP(src=\"192.168.0.1\", dst=\"10.0.0.1\")/ \
                 UDP(sport=1234, dport=5678)/ \
                 Raw(load=\"0123456789\")"

-- 加载 VLAN 模板
pktgen.packet_vlan = load(eth_vlan)

-- 发送 burst
pktgen.start(0)
pktgen.delay(1000)
pktgen.stop(0)
```

## 6. 典型测试场景

### 6.1 吞吐量测试（RFC 2544 Throughput）

```lua
-- throughput-test.lua - 吞吐量测试
package.path = package.path ..";?.lua;./lua/?.lua"
local mg = require("mg_common")

-- 二分查找最优速率
function throughputTest(port, frameSize)
    local low = 0
    local high = 100
    local result = 0
    
    for i = 1, 7 do  -- 二分 7 次
        local mid = math.floor((low + high) / 2)
        
        pktgen.set(port, "size", frameSize)
        pktgen.set(port, "rate", mid)
        
        pktgen.start(port)
        pktgen.delay(5000)  -- 5 秒稳定
        
        local stats = pktgen.get_stats(port)
        local loss_rate = stats.rx_packets / stats.tx_packets
        
        pktgen.stop(port)
        
        if loss_rate < 0.001 then  -- < 0.1% 丢包率
            result = mid
            low = mid
        else
            high = mid
        end
    end
    
    return result
end

-- 测试不同包大小
local sizes = {64, 128, 256, 512, 1024, 1280, 1518}
for _, size in ipairs(sizes) do
    local pps = throughputTest(0, size)
    print(string.format("Size %d: %.2f%% rate", size, pps))
end
```

### 6.2 延迟测试

```lua
-- latency-test.lua - 测量端到端延迟
-- 需要收发双向路径

local seq = 0
local tx_port = 0
local rx_port = 1

-- 配置反射模式（发出去的包从对面环回）
pktgen.set(tx_port, "反射", "enable")
pktgen.set(tx_port, "反射_port", rx_port)

function latencyTest(duration)
    pktgen.start(tx_port)
    
    local count = 0
    local total_latency = 0
    
    while count < duration do
        local stats = pktgen.get_stats(tx_port)
        
        -- 计算平均延迟
        if stats.latency > 0 then
            total_latency = total_latency + stats.latency
            count = count + 1
        end
        
        pktgen.delay(1000)
    end
    
    pktgen.stop(tx_port)
    
    return total_latency / count
end

local avg_lat = latencyTest(10000)
print(string.format("Average latency: %.2f us", avg_lat))
```

### 6.3 丢包率测试

```lua
-- loss-test.lua - 丢包率曲线
package.path = package.path ..";?.lua;./lua/?.lua"

local rates = {100, 90, 80, 70, 60, 50, 40, 30, 20, 10}
local results = {}

for _, rate in ipairs(rates) do
    -- 重置统计
    pktgen.reset()
    
    -- 设置速率
    pktgen.set("all", "rate", rate)
    pktgen.set("all", "size", 64)
    
    -- 发送 10 秒
    pktgen.start("all")
    pktgen.delay(10000)
    pktgen.stop("all")
    
    -- 收集统计
    local tx = 0
    local rx = 0
    for _, p in ipairs(mg.getPorts()) do
        local s = pktgen.get_stats(p)
        tx = tx + s.tx_packets
        rx = rx + s.rx_packets
    end
    
    local loss = 100 * (1 - rx / tx)
    results[rate] = loss
    
    print(string.format("Rate: %d%% Loss: %.3f%%", rate, loss))
end

-- 输出 CSV
print("Rate,LossPct")
for r, l in pairs(results) do
    print(string.format("%d,%.3f", r, l))
end
```

## 7. 与 testpmd 对比

| 特性 | pktgen | testpmd |
|------|--------|---------|
| **定位** | 流量生成/测试 | 转发/桥接 |
| **脚本支持** | Lua 原生支持 | 无内置脚本 |
| **统计精度** | 实时精确 | 基础统计 |
| **CPU 开销** | 低（专注发送） | 较高（转发逻辑） |
| **适用场景** | 性能基准测试 | 功能验证 |
| **命令行** | 交互式 + 脚本 | 交互式命令 |

## 8. 常见问题排查

### 8.1 端口无法启动

```bash
# 检查端口状态
pktgen> show 0 stats

# 常见错误：
# - EAL: not enough memory -> 增加 -m 参数
# - No such device -> 检查 NIC 是否被绑定
# - Port already used -> 确认没有其他程序占用
```

### 8.2 绑定 NIC 到 DPDK

```bash
# 查看网卡
dpdk-devbind.py --status

# 绑定
sudo dpdk-devbind.py -b igb_uio 0000:01:00.0

# 或使用 vfio-pci
sudo modprobe vfio-pci
sudo dpdk-devbind.py -b vfio-pci 0000:01:00.0
```

### 8.3 性能调优

```bash
# 禁用 IRQ 合并
ethtool -C <iface> rx-usecs 0 rx-frames 1

# 隔离 CPU cores
sudo isolcpus=1,2,3

# 启动时指定更多大页
sudo ./pktgen -l 0,1,2,3 -n 4 -- \
    --socket-mem 1024,1024 \
    --file-prefix pg \
    -m [0:1].0 -m [2:3].1
```

## 9. 进阶用法

### 9.1 Packet Template 导入

```lua
-- 导入外部 pcap 文件
pktgen.pcap = "traffic.pcap"

-- 生成随机 payload
pktgen.set(0, "payload", "rand")

-- 自定义 payload 内容
pktgen.set(0, "payload", "0123456789ABCDEF0123456789")
```

### 9.2 流量回放

```lua
-- 从 pcap 回放
pktgen.pcap = "session.pcap"
pktgen.set(0, "pcap_mode", "loop")  -- 循环回放
pktgen.start(0)
```

## 10. 总结

pktgen 是 DPDK 生态中不可或缺的测试工具：

1. **高速发包**：可达 10Gbps+ 线速
2. **精确控制**：支持包大小、速率、突发控制
3. **Lua 脚本**：实现复杂测试场景自动化
4. **实时统计**：精确的 pps、Mpps、Lbits/s 统计

**下章预告**：`ch33 - 调试技巧：日志、assert、crash 分析`

---

## 参考资源

- [pktgen-dpdk 官方文档](https://pktgen.readthedocs.io/)
- [DPDK 测试工具](https://doc.dpdk.org/guides/tools/index.html)
- [RFC 2544 - Benchmarking Methodology](https://datatracker.ietf.org/doc/rfc2544/)
