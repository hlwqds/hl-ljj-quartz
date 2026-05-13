---
title: "P4 深度探索 (十四)：Register 与状态——Register、Counter、Gauge、Direct/Indirect 资源"
date: 2026-04-14
tags: [p4, series, register, counter, gauge, state, direct, indirect, p4-16, psa]
description: "P4 Register 与状态管理深度解析——Register、Counter、Gauge、Direct/Indirect 资源、原子操作、状态同步、Packet 和 Byte 计数、PSA 中的状态管理机制"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[2026-04-14-p4-deep-dive-ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[2026-04-14-p4-deep-dive-ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct/tuple]]
> 6. [[2026-04-14-p4-deep-dive-ch6-headers|第六章：Header 与 Packet——Header 定义、Header Stack]]
> 7. [[2026-04-14-p4-deep-dive-ch7-parser|第七章：Parser 编程——状态机、Header 提取、Error 处理]]
> 8. [[2026-04-14-p4-deep-dive-ch8-match-action|第八章：Match-Action 编程——Table、Action、Key]]
> 9. [[2026-04-14-p4-deep-dive-ch9-control|第九章：Control 编程——Control Block、条件判断、Action 调用链]]
> 10. [[2026-04-14-p4-deep-dive-ch10-deparser|第十章：Deparser——包重组、Header 顺序、Checksum 重新计算]]
> 11. [[2026-04-14-p4-deep-dive-ch11-psa|第十一章：PSA 架构——Portable Switch Architecture、Ingress/Egress 管道]]
> 12. [[2026-04-14-p4-deep-dive-ch12-tna|第十二章：TNA 架构——Tofino Native Architecture、高性能流水线]]
> 13. [[2026-04-14-p4-deep-dive-ch13-pipeline|第十三章：Pipeline 设计——Match-Action 流水线、逻辑阶段与物理阶段]]
> 14. **第十四章：Register 与状态——Register、Counter、Gauge、Direct/Indirect 资源**

---

## 1. 概述：P4 中的状态管理

P4 是一种**无状态**的数据包处理语言，但实际网络设备需要**维护动态状态**——如流量统计、会话信息、策略状态等。P4 通过 **Extern 机制**和**状态资源**来实现这些功能。

本章聚焦于三种核心状态管理机制：
- **Register**：通用读写存储
- **Counter**：只增计数
- **Gauge**：可增可减计量

---

## 2. Register 详解

### 2.1 Register 定义

**Register** 是 P4 中最通用的状态资源，类似于通用内存，支持**读写操作**：

```c
// Register 定义
extern Register<W> {
    // 构造函数：指定大小和初始值
    Register(bit<32> size);
    Register(bit<32> size, W initial_data);
    
    // 读取操作
    @atomic
    W read(bit<32> index);
    
    // 写入操作
    @atomic
    void write(bit<32> index, W value);
}
```

### 2.2 Register 基本用法

```c
control Ingress(...) {
    
    // 定义一个 Register: 1024 个 entry，每个 entry 48 bits
    Register<bit<48>, _>(1024) last_seen_time;
    
    // 读取
    action record_arrival() {
        bit<48> current_time;
        bit<48> last_time = last_seen_time.read((bit<32>)h.ethernet.srcAddr);
        // ... 处理逻辑
        last_seen_time.write((bit<32>)h.ethernet.srcAddr, current_time);
    }
    
    apply {
        record_arrival();
    }
}
```

### 2.3 Register 的原子性

Register 操作是**原子的**，在硬件中通过**锁存器 (Latch)** 或 **双端口 SRAM** 实现：

```
原子读写时序:
=============

Read-Modify-Write (对于增量操作):
┌──────────────────────────────────────────────────┐
│  Time ──────────────────────────────────────────>│
│                                                  │
│  Cycle 0: [Read Register[idx]] ──────────────>   │
│                     │                             │
│                     v                             │
│  Cycle 1: [ALU: value + 1] ─────────────────>   │
│                     │                             │
│                     v                             │
│  Cycle 2: [Write Register[idx] = value+1] ───>   │
│                                                  │
└──────────────────────────────────────────────────┘
```

### 2.4 Register 典型应用

| 应用场景 | 描述 |
|----------|------|
| **MAC 学习** | 记录 MAC 地址最后出现的时间/端口 |
| **流量统计** | 记录每个流的包数/字节数 |
| **时间戳** | 记录数据包到达/离开的时间 |
| **会话管理** | TCP 状态跟踪 |
| **限速** | Token Bucket 状态 |
| **Bloom Filter** | 布隆过滤器的位向量 |

---

## 3. Counter 详解

### 3.1 Counter 定义

**Counter** 是**只增**的计数器，适用于流量统计：

```c
// Counter 类型
enum PSA_CounterType_t {
    PACKETS,      // 只计包数
    BYTES,        // 只计字节数
    PACKETS_AND_BYTES  // 同时计数
}

// Counter 定义
extern Counter<W, PSA_CounterType_t> {
    Counter(bit<32> n, PSA_CounterType_t type);
    
    // 计数操作
    void count();  // 使用默认索引 0
    void count(bit<32> index);
}
```

### 3.2 Counter 用法

```c
control Ingress(...) {
    
    // 方式 1: 简单全局计数器
    Counter<bit<64>, PSA_CounterType_t>(1, PSA_CounterType_t.PACKETS) total_packets;
    
    // 方式 2: Per-flow 计数器 (间接)
    Counter<bit<64>, PSA_CounterType_t>(16384, PSA_CounterType_t.PACKETS_AND_BYTES) flow_counters;
    
    // 方式 3: Direct Counter (与表绑定)
    direct counter<bit<64>>(PSA_CounterType_t.PACKETS_AND_BYTES) ip_counter;
    
    table ipv4_fib {
        key = { h.ipv4.dstAddr : lpm; }
        actions = { forward; }
        default_action = forward;
        
        // 绑定 direct counter
        @pdml("counter", "bytes")
        @pdml("counter", "packets")
        counters = ip_counter;
    }
    
    apply {
        // 手动计数
        total_packets.count(0);
        
        // 表查找会自动更新 direct counter
        ipv4_fib.apply();
        
        // Per-flow 计数
        flow_counters.count(hash(srcAddr + dstAddr));
    }
}
```

### 3.3 Direct vs Indirect Counter

| 特性 | Direct Counter | Indirect Counter |
|------|---------------|------------------|
| 索引方式 | 表项自动索引 | 手动指定索引 |
| 存储位置 | 与表项一起存储 | 独立 Register |
| 资源效率 | 高 (表项少时) | 高 (表项多时) |
| 灵活性 | 低 (绑定到特定表) | 高 (任何地方使用) |

```c
// Direct Counter 示例 (绑定到表)
direct counter<bit<64>>(PSA_CounterType_t.PACKETS) my_counter;

table my_table {
    key = { ... }
    actions = { ... }
    counters = my_counter;  // 每个表项一个计数器
}

// Indirect Counter 示例 (独立)
Counter<bit<64>, PSA_CounterType_t>(16384, PSA_CounterType_t.PACKETS) my_indirect_counter;

apply {
    // 任何时候手动计数
    my_indirect_counter.count(metadata.flow_id);
}
```

---

## 4. Gauge 详解

### 4.1 Gauge 定义

**Gauge** 是**可增可减**的计量器，适用于瞬时值测量：

```c
enum PSA_GaugeType_t {
    PACKETS,      // 包数
    BYTES,        // 字节数
    PACKETS_AND_BYTES
}

extern Gauge<W, PSA_GaugeType_t> {
    Gauge(bit<32> n, PSA_GaugeType_t type);
    
    void count(bit<32> index);        // +1
    void count(bit<32> index, W n);   // +n
    void count(bit<32> index, W n, GaugeOp op);
}

enum GaugeOp {
    INCREMENT,
    DECREMENT,
    SET
}
```

### 4.2 Gauge 用法

```c
control Ingress(...) {
    
    // 流量整形: 跟踪每个队列的深度
    Gauge<bit<32>, PSA_GaugeType_t>(1024, PSA_GaugeType_t.PACKETS) queue_depth;
    
    // 统计当前活跃连接数
    Gauge<bit<32>, PSA_GaugeType_t>(1, PSA_GaugeType_t.PACKETS) active_connections;
    
    action track_queue() {
        queue_depth.count((bit<32>)metadata.queue_id);
    }
    
    action connection_opened() {
        active_connections.count(0, 1, GaugeOp.INCREMENT);
    }
    
    action connection_closed() {
        active_connections.count(0, 1, GaugeOp.DECREMENT);
    }
    
    apply {
        // ...
    }
}
```

### 4.3 Gauge vs Counter

| 特性 | Counter | Gauge |
|------|---------|-------|
| 操作 | 只增 | 可增可减 |
| 用途 | 累积统计 | 瞬时测量 |
| 典型场景 | 总流量、会话数 | 队列深度、连接数 |
| 数据导出 | 适合历史分析 | 适合监控告警 |

---

## 5. Register Array 详解

### 5.1 Register Array 定义

**Register Array** 是多个 Register 的组合：

```c
// 多维 Register Array
Register<bit<32>, _>(16384) flow_table_1;
Register<bit<32>, _>(16384) flow_table_2;
Register<bit<64>, _>(1024) timestamp_table;
```

### 5.2 Hash-Direct Indexing

将 Hash 结果直接作为 Register 索引：

```c
control Ingress(...) {
    
    hash<bit<32>>(hash_input, HashAlgorithm.identity)
        (h.ipv4.srcAddr, h.ipv4.dstAddr);
    
    Register<bit<48>, _>(4096) flow_timer;
    
    action get_timer() {
        bit<48> last_time = flow_timer.read(hash_input);
        // ...
    }
    
    apply {
        get_timer();
    }
}
```

### 5.3 布隆过滤器实现

Register 常用于实现布隆过滤器：

```c
control Ingress(...) {
    
    // 多个 Hash 函数 + 多个 Register Bit Arrays
    Register<bit<1>, _>(16384) bf_hash0;
    Register<bit<1>, _>(16384) bf_hash1;
    Register<bit<1>, _>(16384) bf_hash2;
    
    action bloom_check() {
        bit<32> idx0, idx1, idx2;
        
        // 计算 3 个 Hash
        hash<bit<32>>(idx0, HashAlgorithm.hash) (h.ipv4.srcAddr);
        hash<bit<32>>(idx1, HashAlgorithm.hash) (h.ipv4.srcAddr, h.ipv4.dstAddr);
        hash<bit<32>>(idx2, HashAlgorithm.hash) (h.ipv4.srcAddr, h.tcp.srcPort);
        
        // 检查所有 bit 是否为 1
        if (bf_hash0.read(idx0) == 1 &&
            bf_hash1.read(idx1) == 1 &&
            bf_hash2.read(idx2) == 1) {
            // 可能存在
        }
    }
    
    action bloom_add() {
        // 设置 bit
        bf_hash0.write(idx0, 1);
        bf_hash1.write(idx1, 1);
        bf_hash2.write(idx2, 1);
    }
    
    apply {
        bloom_check();
    }
}
```

---

## 6. 状态与控制面同步

### 6.1 状态读取

控制面可以通过 **P4Runtime** 读取数据平面状态：

```python
# P4Runtime gRPC 调用示例
def read_counters():
    req = p4runtime_pb2.ReadRequest()
    entity = req.entities.add()
    
    # 读取 Direct Counter
    counter_entry = entity.counter_entry
    counter_entry.table_entry.entry_id = table_entry_id
    
    for resp in stub.Read(req):
        for entity in resp.entities:
            print(f"Counter: {entity.counter_entry.data.packet_count}")
```

### 6.2 状态写入

控制面可以修改数据平面状态：

```python
# P4Runtime 写入 Register
def write_register(index, value):
    req = p4runtime_pb2.WriteRequest()
    entity = req.entities.add()
    
    register_entry = entity.register_entry
    register_entry.register_id = register_id
    register_entry.index.index = index
    register_entry.data.bit_string = struct.pack('!Q', value)
    
    stub.Write(req)
```

### 6.3 异步状态更新

控制面可以通过 **Digest** 异步接收数据平面消息：

```c
// P4 程序生成 Digest
control Ingress(...) {
    
    digest<mac_learn_digest_t>(1) mac_learn_digest;
    
    action mac_learn() {
        mac_learn_digest.pack({
            srcMac: h.ethernet.srcAddr,
            port: ismd.ingress_port
        });
    }
    
    apply {
        mac_learn();
    }
}
```

```python
# 控制面接收 Digest
def receive_digest():
    for resp in stub.PacketStream(stream_req):
        if resp.HasField('digest'):
            digest_data = DigestEntry()
            digest_data.ParseFromString(resp.digest.data)
            print(f"MAC: {digest_data.srcMac}, Port: {digest_data.port}")
```

---

## 7. 状态资源的原子性保证

### 7.1 硬件原子性机制

硬件必须保证状态更新的原子性：

| 机制 | 描述 | 适用场景 |
|------|------|----------|
| **双端口 SRAM** | 同时支持读写 | 简单读写 |
| **读-修改-写** | 原子执行 RMW | 增量更新 |
| **比较-交换 (CAS)** | 原子比较并交换 | 锁-free 算法 |
| **队列串行化** | 所有更新经队列 | 复杂状态 |

### 7.2 原子操作语义

```c
// P4 中的原子性由编译器/硬件保证

// 这个操作是原子的：读-增-写在一个原子事务中完成
action increment_counter() {
    // 编译器生成: atomic { reg[idx] = reg[idx] + 1; }
    my_counter.count(idx);  // PSA/Gauge 的 count() 是原子的
}
```

### 7.3 并发冲突处理

```
并发冲突场景:
=============

Core 0 ──> Read[Reg[5]]=100 ──> +1 ──> Write[Reg[5]]=101
Core 1 ──> Read[Reg[5]]=100 ──> +1 ──> Write[Reg[5]]=101

问题: 结果应该是 102，但实际是 101 (丢失一次更新)

解决方案:
1. 硬件原子操作 (读-修改-写 不可分割)
2. 队列串行化 (所有更新经 FIFO)
3. 软件分布式锁
```

---

## 8. 状态管理最佳实践

### 8.1 资源规划

| 资源类型 | 容量限制 | 规划建议 |
|----------|----------|----------|
| Register | 受限于 BRAM/DRAM | 估算: entries × width |
| Counter | 受限于 BRAM | 合并低频计数器 |
| Gauge | 受限于 BRAM | 按需创建 |

### 8.2 性能优化

```c
// 优化 1: 使用直接索引代替 Hash
// 慢: Hash 计算
hash<bit<32>>(idx) (h.ipv4.srcAddr);

// 快: 直接使用端口号作为索引
bit<32> idx = (bit<32>)ismd.ingress_port;


// 优化 2: 批量更新代替多次写入
// 慢: 多次写
register0.write(idx0, val0);
register1.write(idx1, val1);

// 快: 合并到同一 Cycle (如果硬件支持)
// 编译器会尽可能并行化独立的 Register 操作
```

### 8.3 状态持久化

```python
# 定期同步状态到控制面
def sync_state_periodically():
    while True:
        # 读取所有 Counter
        for flow_id in flows:
            count = read_counter(flow_id)
            store_to_database(flow_id, count)
        
        # 清零 (如果需要)
        reset_counters()
        
        sleep(sync_interval)
```

---

## 9. PSA 中的状态资源

### 9.1 PSA Intrinsic Metadata 中的状态信息

```c
struct psa_egress_input_metadata_t {
    bit<9>  egress_port;
    bit<8>  class_of_service;
    bit<32> enq_timestamp;       // 入队时间戳
    bit<16> enq_qid;           // 队列 ID
    bit<3>  enq_qdepth;        // 入队时队列深度
    bit<19> deq_qdepth;        // 出队时队列深度
}
```

### 9.2 使用队列深度的 QoS

```c
control Ingress(...) {
    
    // 使用队列深度做动态限速
    Register<bit<32>, _>(256) queue_limit;
    
    action dynamic_throttle() {
        bit<9> qid = (bit<9>)ismd.enq_qid;
        bit<32> limit = queue_limit.read(qid);
        bit<19> depth = (bit<19>)esm.deq_qdepth;  // 来自 egress metadata
        
        if (depth > limit) {
            // 超限丢包
            drop();
        }
    }
    
    apply {
        dynamic_throttle();
    }
}
```

---

## 10. 总结

Register、Counter 和 Gauge 是 P4 中管理状态的三大核心机制：

1. **Register**：通用读写存储，支持任意位宽，用于 MAC 学习、时间戳、布隆过滤器等
2. **Counter**：只增计数，适用于流量统计，分 Direct 和 Indirect 两种模式
3. **Gauge**：可增可减，适用于瞬时值测量，如队列深度、连接数

状态管理涉及：
- **原子性保证**：硬件确保并发更新的正确性
- **控制面同步**：通过 P4Runtime 读写状态
- **资源规划**：合理估算所需资源

理解状态管理是编写复杂 P4 程序的基础，下一章我们将讨论 Checksum——如何在数据包处理中验证和重新计算校验和。
