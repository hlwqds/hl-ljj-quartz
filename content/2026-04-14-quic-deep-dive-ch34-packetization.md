---
title: "QUIC 深度探索 ch34 - Packetization"
date: 2026-04-14
description: "深入解析 QUIC Packetization：MTU/MSS 计算、分片策略（Fragmentation）、PMTUD（路径MTU发现）、包大小与性能关系、coalescing 机制"
tags:
  - quic
  - series
  - packetization
  - MTU
  - MSS
  - fragmentation
  - PMTUD
---

# QUIC 深度探索 ch34 - Packetization

> [!tip] 本章内容
> 本章深入剖析 QUIC 的 Packetization 机制，涵盖 MTU/MSS 的计算与协商、分片策略（Fragmentation）、PMTUD 路径 MTU 发现、QUIC 包大小与性能关系，以及包 coalescing 机制。

---

## 1. Packetization 概述

Packetization 是将应用层数据封装为网络包的过程。QUIC 的 Packetization 有几个关键考量：

1. **MTU 限制**：每个包不能超过路径 MTU
2. **加密开销**：头部保护、Crypto 帧的开销
3. **分片控制**：避免 IP 层分片
4. **Coalescing**：合并多个包减少开销

```
QUIC Packetization 流程：

应用层数据
     |
     v
+------------------------+
| 分片为 STREAM 帧        |
+------------------------+
     |
     v
+------------------------+
| 封装到 CRYPTO 帧       |
+------------------------+
     |
     v
+------------------------+
| 封装到 QUIC 包         |
| (加头部、加密、保护)      |
+------------------------+
     |
     v
+------------------------+
| 封装到 UDP 数据报       |
+------------------------+
     |
     v
IP 层
```

---

## 2. MTU 与 MSS

### 2.1 基本概念

| 概念 | 定义 |
|------|------|
| MTU (Maximum Transmission Unit) | 网络层能传输的最大数据包大小 |
| MSS (Maximum Segment Size) | TCP/IP 层的最大载荷大小 |
| 路径 MTU (PMTU) | 路径上所有设备的最小 MTU |

常见 MTU 值：

| 网络类型 | MTU (bytes) |
|---------|-------------|
| 以太网 | 1500 |
| PPPoE | 1492 |
| VPN (overhead) | 1400-1500 |
| 最小建议值 | 1280 (IPv6) |

### 2.2 QUIC MTU 计算

QUIC 包的实际大小受以下因素限制：

```
QUIC MTU 计算公式：

UDP Payload Max = Path MTU - UDP Header - IP Header
                = Path MTU - 8 - 20 (IPv4) / 40 (IPv6)
                
QUIC Packet Max = UDP Payload Max - QUIC Header Overhead
                - Encryption Overhead
                - Packet Number Length

典型计算（以太网 MTU=1500）：
  UDP Payload Max = 1500 - 8 - 20 = 1472 bytes
  QUIC Packet Max ≈ 1472 - 40 - 16 = 1416 bytes
  （40 bytes: Long Header, 16 bytes: AEAD overhead）
```

### 2.3 QUIC 头部开销

**Long Header 开销**：

```
Long Header 格式开销：

+---------------------------+
| 1st byte (version + type) |  1 byte
+---------------------------+
| Version                    |  4 bytes
+---------------------------+
| DCID Length                |  1 byte
+---------------------------+
| DCID                      |  0-20 bytes
+---------------------------+
| SCID Length                |  1 byte
+---------------------------+
| SCID                      |  0-20 bytes
+---------------------------+
| Token Length (i)           |  0-8 bytes
+---------------------------+
| Token (optional)           |  0-256 bytes
+---------------------------+
| Length (i)                 |  0-8 bytes
+---------------------------+
| Packet Number             |  1-4 bytes
+---------------------------+
| Payload                  |  variable
+---------------------------+
| Authentication Tag        |  16 bytes (AES-GCM)
+---------------------------+

Long Header 总开销：约 40-50 bytes（不含 Token）
```

**Short Header 开销**：

```
Short Header 格式开销：

+---------------------------+
| 1st byte (type + key phase)|  1 byte
+---------------------------+
| Connection ID (if present)|  0-20 bytes
+---------------------------+
| Packet Number             |  1-4 bytes
+---------------------------+
| Payload                  |  variable
+---------------------------+
| Authentication Tag        |  16 bytes (AES-GCM)
+---------------------------+

Short Header 总开销：约 18-40 bytes
```

### 2.4 MTU 协商

QUIC 不在协议中直接协商 MTU，但传输参数可以携带建议值：

```python
# 传输参数：max_udp_payload_size
# 建议值：1200-1500 bytes
# 作用：通知对端不要发送大于此值的包
```

---

## 3. 分片策略（Fragmentation）

### 3.1 IP 分片 vs QUIC 分片

QUIC 避免 IP 层分片，因为：
- IP 分片增加丢包代价（一片丢失，整个包丢失）
- IP 分片可能被防火墙拦截
- QUIC 需要更细粒度的丢包检测

```
IP 分片 vs QUIC 分片：

IP 分片：
  大包被网络设备分片
  - 丢失一片 -> 重组失败 -> 整个包丢失
  - 触发重传 -> 浪费带宽
  
QUIC 避免 IP 分片：
  QUIC 在应用层控制包大小
  - 包大小 < Path MTU
  - 丢包只丢一个 QUIC 包
  - 更精确的丢包检测
```

### 3.2 STREAM 帧分片

STREAM 数据可能被分片到多个 STREAM 帧：

```python
# 应用发送 100KB 数据
app_data = b"x" * 100000

# STREAM 帧 offset=0, length=50000  # 第一片
# STREAM 帧 offset=50000, length=50000  # 第二片

# QUIC 保证按序交付，但可以在多个包中传输
```

### 3.3 CRYPTO 帧分片

CRYPTO 数据也可能被分片：

```python
# TLS 消息可能被分片
tls_message = b"TLS handshake data..."

# CRYPTO 帧 offset=0, length=1000
# CRYPTO 帧 offset=1000, length=1000
# CRYPTO 帧 offset=2000, length=500

# 关键：CRYPTO 数据必须按 offset 顺序交付
```

### 3.4 分片重组

接收端需要重组分片：

```python
class Stream reassembly:
    def __init__(self):
        self.buffers = {}  # stream_id -> ReassemblyBuffer
        
    def receive_chunk(self, stream_id, offset, data):
        """接收 STREAM 帧分片"""
        if stream_id not in self.buffers:
            self.buffers[stream_id] = {}
        
        self.buffers[stream_id][offset] = data
        
        # 按 offset 排序并重组
        sorted_offsets = sorted(self.buffers[stream_id].keys())
        
        # 检查连续性
        reassembled = b""
        for off in sorted_offsets:
            chunk = self.buffers[stream_id][off]
            if off == len(reassembled):
                reassembled += chunk
            else:
                break  # 等待中间的分片
        
        return reassembled
```

---

## 4. PMTUD（路径 MTU 发现）

### 4.1 PMTUD 概述

PMTUD 是一种动态发现路径 MTU 的机制。QUIC 使用类似 TCP 的探针机制。

```
PMTUD 核心思想：

1. 假设初始 MTU（如 1280）
2. 发送探测包（带 DF 位）
3. 如果探测包到达且不被分片 -> 增大 MTU
4. 如果收到 ICMP "packet too big" -> 减小 MTU
```

### 4.2 QUIC PMTUD 策略

RFC 9000 建议的 QUIC PMTUD 策略：

```
PMTUD 状态机：

                  +-----------+
                  | Probing   |
                  +-----------+
                        |
                        | 探测包到达
                        v
                  +-----------+     ICMP/丢包
                  | Success   | -------------> 增大 MTU
                  +-----------+     
                        |
                        | 持续成功
                        v
                  +-----------+
                  | Stable    |
                  +-----------+     ICMP/丢包
                        | -------------> 减小 MTU
                        v
                  +-----------+
                  | Reduce    |
                  +-----------+
```

### 4.3 PROBE 帧

QUIC 使用 PING 帧作为 PMTUD 探针：

```python
# 发送 PING 作为 MTU 探针
def send_mtu_probe(size):
    """
    发送 MTU 探测包
    """
    # 确保包大小接近目标 MTU
    padding = size - calculate_header_overhead()
    
    frames = [
        PING(),  # PING 帧触发 ACK
        PADDING(padding),  # 填充到目标大小
    ]
    
    send_packet(frames)

# 收到 ACK 后：
#   - 如果 ACK 到达 -> MTU 可用，增加
#   - 如果丢包/ICMP -> MTU 减小
```

### 4.4 MTU 与拥塞控制的关系

MTU 选择影响拥塞控制：

```python
# MTU 影响 cwnd 的包数量

cwnd_bytes = 10000  # cwnd = 10KB
mtu = 1500  # 每个包 1500 bytes

pkt_count = cwnd_bytes / mtu  # ≈ 6.67 个包

# 如果 MTU 太小
mtu = 500
pkt_count = cwnd_bytes / mtu  # = 20 个包

# 更多的小包 -> 
# - 更多的包头开销
# - 更频繁的 ACK
# - 更高的处理开销
```

---

## 5. 包大小与性能

### 5.1 最佳包大小

理论上，最佳包大小 = 路径 MTU。但实际选择需要权衡：

| 包大小 | 优点 | 缺点 |
|--------|------|------|
| 大包 (接近 MTU) | 效率高、包头开销低 | 丢包代价大、重传多 |
| 小包 | 丢包代价小、低延迟 | 效率低、拥塞窗口填满慢 |

### 5.2 握手阶段的包大小

握手阶段包大小特别重要：

```
Initial 包大小建议：

1. 最小 Initial 包：1200 bytes（RFC 9000 要求的最小值）
   - 包含 crypto 数据和传输参数
   - 确保路径 MTU 足够
   
2. 典型 Initial 包：1200-1500 bytes
   - 携带完整的 TLS ClientHello
   - 最大化握手效率
   
3. Initial 包过小的影响：
   - TLS 数据分片多
   - 握手延迟增加
```

### 5.3 数据传输阶段的包大小

```
数据传输阶段包大小策略：

1. 优先填满 MTU：
   - 最大化吞吐量
   - 减少包头开销
   
2. 低延迟场景使用小包：
   - 交互式应用（SSH、游戏）
   - 语音/视频数据
   - 使用 PING 帧探测 RTT
   
3. 丢包后的包大小：
   - 丢包后可能切换到更小的包
   - 避免连续丢包
```

### 5.4 包大小统计

```python
class PacketSizeStats:
    def __init__(self):
        self.sent_sizes = []  # 发送的包大小
        self.ack_sizes = []   # 收到的 ACK 包大小
        
    def record_sent(self, size):
        self.sent_sizes.append(size)
        
    def analyze(self):
        """分析包大小分布"""
        import statistics
        return {
            "avg_size": statistics.mean(self.sent_sizes),
            "median_size": statistics.median(self.sent_sizes),
            "p90_size": statistics.quantiles(self.sent_sizes, n=10)[9],
            "p10_size": statistics.quantiles(self.sent_sizes, n=10)[0],
        }
```

---

## 6. Coalescing 机制

### 6.1 Coalescing 概述

Coalescing 允许在一个 UDP 数据报中发送多个 QUIC 包，减少开销。

```
Coalescing 示例：

UDP Datagram:
  +--------+--------+--------+
  | 包 1   | 包 2   | 包 3   |  <- 3 个 QUIC 包
  |(Long)  |(Long)  |(Short) |
  +--------+--------+--------+

约束：
  1. 第一个包必须是 Long Header
  2. 包必须按长度编码（Length prefix）
  3. 接收端按长度解析
```

### 6.2 Coalescing 规则

RFC 9000 定义的 Coalescing 规则：

```
Coalescing 约束：

1. 类型限制：
   - 第一个包：Long Header（Initial/Handshake/0-RTT）
   - 后续包：任意类型（Short Header 可以）
   
2. 加密级别：
   - Initial 之后只能是 Initial（不同 token）
   - Handshake 之后只能是 Handshake 或 Initial
   - 1-RTT 之后可以是 1-RTT 或 Initial
   
3. 长度编码：
   - 每个包必须有 Length 前缀
   - 接收端按长度解析
   
4. Packet Number：
   - 每个包有独立的 Packet Number
```

### 6.3 Coalescing 典型场景

**Initial + Handshake Coalescing**：

```
同一 UDP 数据报：

+-------------------------+-------------------------+
| Initial 包              | Handshake 包            |
| [Initial Header]        | [Handshake Header]      |
| [CRYPTO: ClientHello]  | [CRYPTO: ServerHello]   |
| Length: 1200            | Length: 800             |
+-------------------------+-------------------------+
```

**Initial + 0-RTT Coalescing**：

```
同一 UDP 数据报：

+-------------------------+-------------------------+
| Initial 包              | 0-RTT 包                |
| [Initial Header]        | [0-RTT Header]         |
| [CRYPTO: ClientHello]  | [CRYPTO: EarlyData]     |
+-------------------------+-------------------------+
```

### 6.4 Coalescing 实现

```python
def coalesce_packets(*packets):
    """
    将多个包合并到一个 UDP 数据报
    
    规则：
    1. 第一个包必须是 Long Header
    2. 每个包必须有 Length 字段
    """
    result = b""
    
    for i, pkt in enumerate(packets):
        # 确保第一个包是 Long Header
        if i == 0:
            assert is_long_header(pkt), "First packet must be long header"
        
        # 添加 Length 前缀
        pkt_with_length = encode_length(pkt)
        result += pkt_with_length
        
    return result

def parse_coalesced(udp_payload):
    """
    解析 Coalesced 包
    """
    packets = []
    offset = 0
    
    while offset < len(udp_payload):
        # 读取 Length
        length, length_bytes = read_varint(udp_payload, offset)
        
        # 提取包
        pkt_end = offset + length_bytes + length
        pkt = udp_payload[offset:pkt_end]
        packets.append(pkt)
        
        offset = pkt_end
        
    return packets
```

---

## 7. MTU 与加密开销

### 7.1 AEAD 开销

QUIC 使用 AEAD 加密，主要开销：

| AEAD 类型 | 认证标签大小 | 说明 |
|-----------|------------|------|
| AES-GCM-128 | 16 bytes | 常用 |
| AES-GCM-256 | 16 bytes | 更安全 |
| ChaCha20-Poly1305 | 16 bytes | 移动设备友好 |

### 7.2 头部保护开销

```
头部保护（Header Protection）：

QUIC 包结构：

+------------------+------------------------+
|  Protected Header |  Protected Payload     |
+------------------+------------------------+
|  混淆的头部字段    |  加密的负载            |
+------------------+------------------------+
        |
        v
   +----------------+
   | 移除保护后      |
   +----------------+
   
实际 packetization：
  Protected Header = [移除保护的头部 XOR sample]
```

### 7.3 MTU 计算示例

```
完整 MTU 计算示例：

路径 MTU = 1500 bytes (以太网)

UDP Header = 8 bytes
IP Header = 20 bytes (IPv4)
UDP Payload = 1500 - 8 - 20 = 1472 bytes

Long Header QUIC：
  Header (40) + Payload + AEAD Tag (16) = 1472
  Payload = 1472 - 40 - 16 = 1416 bytes
  
Short Header QUIC：
  Header (20) + Payload + AEAD Tag (16) = 1472
  Payload = 1472 - 20 - 16 = 1436 bytes
```

---

## 8. 实现考量

### 8.1 MTU 发现实现

```python
class PMTUDState:
    def __init__(self):
        self.current_mtu = 1280  # 初始值
        self.probe_size = 1280
        self.state = "probing"
        self.probe_count = 0
        
    def send_probe(self):
        """发送 MTU 探测包"""
        if self.probe_count >= 3:
            logger.warning("MTU 探测失败次数过多，停止探测")
            return False
            
        # 发送接近目标大小的 PING+PADDING
        probe_packet = create_packet(
            frames=[PING(), PADDING(self.probe_size - overhead)],
            size=self.probe_size
        )
        
        send_packet(probe_packet)
        self.probe_count += 1
        
        # 设置探测超时
        schedule_timeout(
            delay=self.RTT * 2,
            callback=self.on_probe_timeout
        )
        
        return True
    
    def on_probe_success(self):
        """探测成功，增大 MTU"""
        self.current_mtu = self.probe_size
        self.probe_size = min(self.probe_size + 100, 1500)
        self.probe_count = 0
        self.state = "stable"
        
    def on_probe_failure(self):
        """探测失败，减小 MTU"""
        self.probe_size = max(self.probe_size - 100, 1280)
        self.probe_count = 0
```

### 8.2 包大小选择策略

```python
class PacketSizer:
    def __init__(self, mtu, congestion_window):
        self.mtu = mtu
        self.cwnd = congestion_window
        
    def should_pad(self, packet_size):
        """
        是否填充到 MTU
        """
        if packet_size >= self.mtu:
            return False  # 已经足够大
        
        # 低延迟场景不填充
        if self.is_interactive():
            return False
            
        # 拥塞窗口未填满时填充
        if self.cwnd > packet_size * 2:
            return True
            
        return False
    
    def calculate_optimal_size(self, data_size):
        """
        计算最优包大小
        """
        # 尽量填满 MTU
        max_payload = self.mtu - self.overhead()
        
        if data_size >= max_payload:
            return max_payload
            
        # 数据小于 MTU，根据场景决定
        if self.should_pad(data_size):
            return max_payload  # 填充
            
        return data_size  # 不填充
```

---

## 9. 小结

本章深入解析了 QUIC Packetization 机制：

1. **MTU/MSS 计算**：路径 MTU 限制、QUIC 包头开销、加密开销

2. **分片策略**：避免 IP 分片、STREAM/CRYPTO 帧分片与重组

3. **PMTUD**：动态发现路径 MTU 的探针机制

4. **包大小与性能**：最佳包大小选择、低延迟场景策略

5. **Coalescing**：多个包合并到同一 UDP 数据报，减少网络开销

理解 Packetization 对于优化 QUIC 性能至关重要。Part VII 连接管理到此结束，下一部分我们将进入 Part VIII：落地实现（Implementations），深入分析主流 QUIC 库。
