---
title: "RDMA 第二十一章：带宽优化——最大化 RDMA 吞吐量"
date: 2026-04-13
tags: [rdma, bandwidth, throughput, optimization, inline, qp-depth, mtu]
description: "详解 RDMA 带宽优化：带宽利用率计算、最大 burst、inline data 优化、QP 深度调优、MTU/GSO 影响、多流并行、典型带宽数值。"
---

> [!abstract] 核心要点
> RDMA 的另一核心优势是高吞吐量（带宽利用率）。本章分析如何最大化 RDMA 带宽利用率，涵盖 burst 策略、inline data、QP 深度配置、MTU 影响、以及多流并行等优化技术，帮助达到 100Gbps+ 的线速转发。

---

## 1. 带宽基础

### 1.1 带宽与延迟的关系

带宽和延迟是网络性能的两个维度：

```
带宽 vs 延迟:

  带宽 (Bandwidth): 单位时间内传输的数据量 (bits/s, bytes/s)
  延迟 (Latency):   单次操作的时间 (seconds)

  关系:
    最小传输时间 = 数据量 / 带宽 + 延迟

  示例 (100 Gbps 网络):
    传输 64KB:
      - 带宽利用时间: 64KB / 12.5 GB/s = 5.12 μs
      - 加上延迟 5 μs: 实际约 10 μs
      - 带宽利用率: 51%

    传输 1MB:
      - 带宽利用时间: 1MB / 12.5 GB/s = 80 μs
      - 加上延迟 5 μs: 实际约 85 μs
      - 带宽利用率: 94%
```

### 1.2 线速计算

```
100Gbps 以太网线速计算:

  线速 (Line Rate) = 100 Gbps = 12.5 GB/s

  InfiniBand FDR (56 Gbps) 线速:
    = 56 Gbps / 8 = 7 GB/s

  ConnectX-6 200Gbps:
    = 200 Gbps / 8 = 25 GB/s

  实际可用带宽 (考虑协议开销):
    - IB 4x FDR: ~3.4 GB/s (理论 4 GB/s)
    - RoCE v2 100GbE: ~12.5 GB/s (考虑 CRC overhead)
    - 实际测试通常 ~95% 线速
```

---

## 2. 带宽测量

### 2.1 perftest 带宽测试

```bash
# 基本带宽测试
# 机器 A (服务器)
$ perftest -d mlx5_0

# 机器 B (客户端)
$ perftest -d mlx5_0 <A's IP>

# RC 带宽测试（默认）
$ perftest -d mlx5_0 -c -s 65536 -n 100000

# UD 带宽测试
$ perftest -d mlx5_0 -u -s 4096 -n 500000

# 参数说明:
#   -c: RC 模式 (默认)
#   -u: UD 模式
#   -s: 消息大小 (bytes)
#   -n: 迭代次数
#   -t: 发送队列深度 (tx-depth)
#   -z: zerobytes (测试控制路径)
#   -w: 测试带宽 (而不是延迟)
```

### 2.2 不同消息大小的带宽

```bash
# 测试不同消息大小的带宽
$ for size in 64 256 1024 4096 16384 65536 262144 1048576; do
    echo "=== Size: $size bytes ==="
    perftest -d mlx5_0 -c -s $size -n 50000 -t 64
  done

# 示例输出：
# Size: 65536 bytes
# -------------------------------------------------------------------
# Trafic engine will stop after 50000 iterations
# MB/s> 12288.00
# Avg latency: 43.68 usec
# -------------------------------------------------------------------

# 计算带宽利用率:
# 12288 MB/s = 98.3 Gbps (接近 100 Gbps 线速)
```

### 2.3 完整带宽测试脚本

```bash
#!/bin/bash
# bandwidth_test.sh - RDMA 带宽基准测试

DEV=${1:-mlx5_0}
REMOTE_IP=${2:-192.168.1.100}

echo "========================================"
echo "RDMA Bandwidth Benchmark"
echo "Device: $DEV, Remote: $REMOTE_IP"
echo "========================================"

echo ""
echo "RC Bandwidth Test (different message sizes):"
for SIZE in 64 256 1024 4096 16384 65536 262144 1048576; do
    echo -n "Size $(printf '%7d' $SIZE): "
    perftest -d $DEV -c -s $SIZE -n 50000 -t 64 2>&1 | \
        grep -oP 'BW ave=\K[\d.]+'
done

echo ""
echo "UD Bandwidth Test:"
for SIZE in 64 256 1024 4096 16384; do
    echo -n "Size $(printf '%7d' $SIZE): "
    perftest -d $DEV -u -s $SIZE -n 100000 -t 64 2>&1 | \
        grep -oP 'BW ave=\K[\d.]+'
done

echo ""
echo "RDMA Write Bandwidth Test:"
for SIZE in 65536 262144 1048576; do
    echo -n "Size $(printf '%7d' $SIZE): "
    perftest -d $DEV -c -s $SIZE -n 20000 -t 64 -F write 2>&1 | \
        grep -oP 'BW ave=\K[\d.]+'
done
```

---

## 3. 影响带宽的因素

### 3.1 协议开销

```
RDMA 协议开销分析:

  IB 传输层头部: 12 bytes (REQ, ACK, NAK)
  IB  payload:   0-256 bytes

  RoCE v2 头部:
    IP Header:    20 bytes
    UDP Header:   8 bytes
    BTH:         12 bytes
    payload:     0-...

  Ethernet 头部:
    Ethernet:    14 bytes
    VLAN:         4 bytes (optional)
    CRC:          4 bytes
    Inter-packet gap: 12 bytes

  总协议开销:
    - IB: ~12 bytes (minimal)
    - RoCE v2: ~58 bytes (worst case with VLAN)
    - Ethernet: ~38 bytes (worst case)

  影响:
    小消息时协议开销占比大，带宽利用率低
    大消息时开销可忽略，带宽利用率高
```

### 3.2 MTU 的影响

```
MTU vs 带宽利用率:

  MTU = 1500 (标准 Ethernet):
    - 最大 payload: 1460 bytes (TCP)
    - RDMA over IP: 约 1024 bytes (IB payload)
    - 需要多个数据包传输大数据块
    - 额外协议开销累积

  MTU = 9000 ( jumbo frame ):
    - 最大 payload: ~8900 bytes
    - RDMA payload: ~8800 bytes
    - 减少包数量，降低协议开销
    - 带宽利用率提升 ~10%

  MTU = 4096 (InfiniBand):
    - IB MTID: 4096 bytes
    - 适合中等大小消息
    - 最优效率 for HPC
```

### 3.3 消息大小与带宽的关系

```
带宽 vs 消息大小 (100 Gbps RoCE):

  消息大小    每包 payload   包数量/1MB    理论带宽
  ─────────────────────────────────────────────────
  64 bytes       64            16384         8 Gbps
  256 bytes     256             4096        32 Gbps
  1024 bytes   1024             1024        65 Gbps
  4096 bytes   4096              256        90 Gbps
  65536 bytes  65536              16        98 Gbps
  1048576 bytes 1MB                1        99 Gbps

  结论:
    - 消息 < 4KB 时，协议开销显著
    - 消息 >= 64KB 时，带宽利用率 > 95%
```

---

## 4. 带宽优化策略

### 4.1 QP 深度优化

QP 深度直接影响飞行中的数据量：

```c
// QP 深度与带宽关系
struct ibv_qp_init_attr qp_attr = {
    .max_send_wr = 256,    // 增大发送队列深度
    .max_recv_wr = 256,    // 增大接收队列深度
    .max_send_sge = 1,
    .max_recv_sge = 1,
    .qp_type = IBV_QPT_RC,
};

// 深度设置原则:
//   - 带宽测试: max_send_wr = 512-1024
//   - 延迟敏感: max_send_wr = 16-32
//   - 平衡: max_send_wr = 128-256

// 计算 BDP (Bandwidth-Delay Product):
// BDP = 带宽 × 延迟
// 例如: 100 Gbps × 5 μs = 62.5 KB
// 需要的 QP 深度 ≈ BDP / 平均消息大小
```

### 4.2 Inline Data 优化

Inline data 减少 DMA 访问次数，提高效率：

```c
// Inline Send 优化
struct ibv_send_wr wr, *bad_wr;
struct ibv_sge sge;

memset(&wr, 0, sizeof(wr));
wr.opcode = IBV_WR_SEND;
wr.send_flags = IBV_SEND_INLINE;  // 关键：启用 inline

sge.addr = (uintptr_t)data;
sge.length = 64;  // <= 最大 inline 长度 (通常 512 bytes)
sge.lkey = mr->lkey;

wr.sg_list = &sge;
wr.num_sge = 1;

ibv_post_send(qp, &wr, &bad_wr);

// Inline 优势:
//   1. 避免额外的 DMA 映射查询
//   2. HCA 直接从内存读取数据
//   3. 降低 CPU 开销
//   4. 适合小消息 (< 512 bytes)

// 最大 inline 长度查询:
struct ibv_device_attr attr;
ibv_query_device(ctx, &attr);
printf("Max inline data: %d bytes\n", attr.max_inline_data);
```

### 4.3 Burst 发送策略

```c
// 批量发送最大化带宽
int burst_send(struct ibv_qp *qp, struct ibv_mr *mr,
                char *buf, int msg_size, int batch_size) {
    struct ibv_send_wr wr_array[batch_size];
    struct ibv_send_wr *bad_wr;
    struct ibv_sge sge_array[batch_size];

    // 准备批量 WQE
    for (int i = 0; i < batch_size; i++) {
        memset(&wr_array[i], 0, sizeof(wr_array[i]));
        wr_array[i].opcode = IBV_WR_SEND;
        wr_array[i].send_flags = IBV_SEND_INLINE;
        wr_array[i].next = (i < batch_size - 1) ? &wr_array[i+1] : NULL;

        sge_array[i].addr = (uintptr_t)(buf + i * msg_size);
        sge_array[i].length = msg_size;
        sge_array[i].lkey = mr->lkey;

        wr_array[i].sg_list = &sge_array[i];
        wr_array[i].num_sge = 1;
    }

    // 一次批量提交
    return ibv_post_send(qp, &wr_array[0], &bad_wr);
}

// 使用示例: 发送 1000 条消息，每批 32 条
for (int i = 0; i < 1000; i += 32) {
    int batch = (i + 32 > 1000) ? (1000 - i) : 32;
    burst_send(qp, mr, buf, 4096, batch);

    // 等待完成
    while (poll_completions(cq, batch) < batch) {
        // busy wait
    }
}
```

### 4.4 多流并行

单 QP 无法达到最大带宽，需要多流：

```c
// 多流带宽优化
#define NUM_STREAMS 8

struct stream_context {
    struct ibv_qp *qp;
    struct ibv_cq *cq;
    char *buf;
    struct ibv_mr *mr;
};

struct stream_context streams[NUM_STREAMS];

int init_multi_stream(struct ibv_pd *pd) {
    for (int i = 0; i < NUM_STREAMS; i++) {
        // 为每个流创建独立的 QP 和 CQ
        streams[i].cq = ibv_create_cq(ctx, 128, NULL, NULL, 0);
        streams[i].qp = create_qp(pd, streams[i].cq);

        // 分配独立缓冲区
        streams[i].buf = malloc(BUFFER_SIZE);
        streams[i].mr = ibv_reg_mr(pd, streams[i].buf, BUFFER_SIZE,
                                   IBV_ACCESS_LOCAL_WRITE);
    }
    return 0;
}

// 多流带宽测试
double multi_stream_bw(struct rdma_cm_id *cm_id[], int num_streams) {
    uint64_t start, end;

    start = get_cycles();

    // 并行发送所有流
    for (int i = 0; i < num_streams; i++) {
        post_send(streams[i].qp, ...);
    }

    // 等待所有流完成
    for (int i = 0; i < num_streams; i++) {
        wait_completion(streams[i].cq);
    }

    end = get_cycles();

    double total_bytes = (double)num_streams * ITERATIONS * MSG_SIZE;
    return total_bytes / (end - start) * cycles_per_sec;
}
```

### 4.5 多线程优化

```c
// 每线程独立 QP
void *worker_thread(void *arg) {
    int thread_id = *(int *)arg;
    struct worker_ctx *ctx = &workers[thread_id];

    // 线程绑定到特定 CPU
    cpu_set_t cpus;
    CPU_ZERO(&cpus);
    CPU_SET(thread_id, &cpus);
    sched_setaffinity(0, sizeof(cpu_set_t), &cpus);

    // 创建本地 QP
    ctx->cq = ibv_create_cq(ctx->ctx, 64, NULL, NULL, 0);
    ctx->qp = create_qp(ctx->pd, ctx->cq);
    modify_qp_to_rts(ctx->qp);

    // 本线程带宽测试
    uint64_t start = get_cycles();
    for (int i = 0; i < ITERATIONS; i++) {
        post_send(ctx->qp, ...);
        poll_completion(ctx->cq);
    }
    uint64_t end = get_cycles();

    return (void *)((end - start) / ITERATIONS);
}

int main() {
    pthread_t threads[8];
    int ids[8] = {0, 1, 2, 3, 4, 5, 6, 7};

    // 启动 8 个 worker 线程
    for (int i = 0; i < 8; i++) {
        pthread_create(&threads[i], NULL, worker_thread, &ids[i]);
    }

    // 等待完成
    for (int i = 0; i < 8; i++) {
        void *ret;
        pthread_join(threads[i], &ret);
        printf("Thread %d latency: %lu cycles\n", i, (uint64_t)ret);
    }
}
```

---

## 5. 最大 burst 优化

### 5.1 BDP 计算

```
Bandwidth-Delay Product (BDP):

  BDP = 带宽 × 往返延迟

  示例:
    带宽: 100 Gbps = 12.5 GB/s
    RTT:  10 μs (包含处理时间)
    BDP = 12.5 GB/s × 0.00001 s = 125 KB

  为了达到线速，需要在飞行中的数据 ≥ BDP

  QP 深度计算:
    需要的 max_send_wr ≈ BDP / 平均消息大小

    消息大小 = 64KB:
      max_send_wr ≈ 125 KB / 64 KB ≈ 2

    消息大小 = 1KB:
      max_send_wr ≈ 125 KB / 1 KB ≈ 125
```

### 5.2 max_inline_data 优化

```c
// 查询并设置最大 inline 数据
struct ibv_device_attr attr;
ibv_query_device(ctx, &attr);
printf("Max inline data: %d bytes\n", attr.max_inline_data);

// 在 QP 创建时指定
struct ibv_qp_init_attr qp_init_attr = {
    .cap = {
        .max_send_wr = 256,
        .max_recv_wr = 256,
        .max_send_sge = 1,
        .max_recv_sge = 1,
        .max_inline_data = 512,  // 请求 inline 数据支持
    },
    .qp_type = IBV_QPT_RC,
};

// 验证 QP 支持的 inline 数据
struct ibv_qp_attr attr;
struct ibv_qp_init_attr init_attr;
ibv_query_qp(qp, &attr, IBV_QP_CAP, &init_attr);
printf("Actual max inline: %d\n", init_attr.cap.max_inline_data);
```

### 5.3 发送队列深度调优

```bash
# 查看 QP 深度限制
$ ibv_devinfo -d mlx5_0
  max_qp_wr:    16384
  max_cq:       16384
  max_qp_init_rd_atom: 128

# perftest 测试不同队列深度
$ for depth in 8 16 32 64 128 256 512; do
    echo "TX Depth: $depth"
    perftest -d mlx5_0 -c -s 65536 -n 50000 -t $depth
  done

# 观察带宽随深度变化:
#   - 深度过低 (< 16): 无法达到最大带宽
#   - 深度过高 (> 256): 收益递减，内存增加
#   - 最佳点通常在 64-128
```

---

## 6. 硬件 Offload 与带宽

### 6.1 Checksum Offload

```c
// 启用 checksum offload (如果 HCA 支持)
struct ibv_qp_init_attr qp_attr = {
    .cap = {
        .max_send_wr = 256,
        .max_inline_data = 512,
    },
    .qp_type = IBV_QPT_RC,
    // ...
};

// 检查 HCA 能力
struct ibv_device_attr attr;
ibv_query_device(ctx, &attr);
printf("Device capabilities:\n");
printf("  checksum offload: %s\n",
       (attr.device_cap_flags & IBV_DEVICE_RAW_PACKET) ? "yes" : "no");
```

### 6.2 TSO (Transmit Segmentation Offload)

```bash
# 检查 TSO 支持
$ ethtool -k eth0 | grep tso
tcp-segmentation-offload: on

# 启用 TSO (通常已默认启用)
$ ethtool -K eth0 tso on

# TSO 对 RDMA 的影响:
#   - RDMA 本身已经处理分片
#   - TSO 主要影响 TCP offload
#   - 对 RDMA 带宽直接影响小
```

### 6.3 Scatter-Gather 支持

```c
// Scatter-Gather 优化
struct ibv_sge sg_list[4];
struct ibv_send_wr wr;

// 使用 scatter-gather 合并多个内存段
for (int i = 0; i < 4; i++) {
    sg_list[i].addr = (uintptr_t)(buf_base + i * PAGE_SIZE);
    sg_list[i].length = PAGE_SIZE;
    sg_list[i].lkey = mr->lkey;
}

wr.sg_list = sg_list;
wr.num_sge = 4;
wr.opcode = IBV_WR_SEND;
wr.send_flags = IBV_SEND_INLINE;  // 可组合

// 优势:
//   - 避免连续内存限制
//   - 减少内存拷贝
//   - 提高大消息效率
```

---

## 7. 带宽基准测试最佳实践

### 7.1 测试配置检查清单

```bash
#!/bin/bash
# bandwidth_check.sh - 带宽测试前检查

echo "=== Bandwidth Test Pre-check ==="

# 1. 检查链路速度
echo "[1] Link Speed:"
ethtool eth0 | grep Speed

# 2. 检查全双工
echo "[2] Duplex:"
ethtool eth0 | grep Duplex

# 3. 检查 MTU
echo "[3] MTU:"
ip link show eth0 | grep mtu

# 4. 检查 HCA 速率
echo "[4] HCA Rate:"
ibv_devinfo -d mlx5_0 | grep rate

# 5. 检查 PCIe 带宽
echo "[5] PCIe Link:"
lspci -vvv -s $(ibv_devinfo -d mlx5_0 | grep "pci-bus" | awk '{print $2}') | \
    grep -E "LnkSta|CurrentSpeed"

# 6. 关闭节能
echo "[6] Power Management:"
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/policy*; do
    echo performance > $cpu/cpufreq/scaling_governor 2>/dev/null
done

# 7. 验证拥塞控制
echo "[7] Congestion Control:"
cat /sys/class/infiniband/mlx5_0/ports/1/cc_state
```

### 7.2 典型带宽参考值

```
RDMA 带宽参考值（ConnectX-6, 100Gbps）：

  配置                    理论        实际        效率
  ──────────────────────────────────────────────────────────
  RC, 64KB, single QP     100 Gbps   95-98 Gbps   95-98%
  RC, 1MB, single QP      100 Gbps   98-99 Gbps   98-99%
  RC, 64KB, 4 streams     100 Gbps   96-99 Gbps   96-99%
  UD, 4KB, single QP      100 Gbps   40-60 Gbps   40-60%
  RDMA Write, 64KB        100 Gbps   95-98 Gbps   95-98%
  RDMA Read, 64KB         100 Gbps   85-95 Gbps   85-95%

  注意:
    - UD 带宽较低是因为每个包都需要独立处理
    - RDMA Read 带宽通常低于 Write（需要额外 ACK）
    - 多流可以提高稳定性但不一定提高总量
```

---

## 8. 带宽与拥塞控制

### 8.1 ECN 对带宽的影响

```bash
# 测试 ECN 对带宽的影响
# 关闭 ECN
$ sysctl -w net.ipv4.tcp_ecn=0
$ perftest -d mlx5_0 -c -s 65536 -n 50000

# 开启 ECN
$ sysctl -w net.ipv4.tcp_ecn=1
$ perftest -d mlx5_0 -c -s 65536 -n 50000 -F ecn

# 观察拥塞窗口变化
# ECN 会在拥塞时降低速率
```

### 8.2 PFC 对带宽的影响

```
PFC 对带宽的影响:

  优点:
    - 消除丢包
    - 保证无损传输
    - 拥塞时维持带宽

  缺点:
    - Pause/Resume 周期引入延迟波动
    - 可能在重负载下触发 pause storm
    - 增加平均延迟

  建议:
    - AI 训练: 启用 PFC，最大化带宽
    - 延迟敏感: 使用 ECN 或自适应算法
```

---

## 9. 常见带宽问题

### 9.1 带宽不达标排查

| 症状           | 可能原因          | 解决方案               |
| -------------- | ----------------- | ---------------------- |
| 带宽 < 50 Gbps | QP 深度不足       | 增加 max_send_wr       |
| 带宽波动大     | NUMA 不匹配       | 绑定 CPU 和内存        |
| UD 带宽低      | 正常，UD overhead | 使用 RC 或增加消息大小 |
| 多流无提升     | 单流已饱和        | 检查 QP 深度           |
| 带宽随时间下降 | 内存碎片          | 预注册大内存区域       |

### 9.2 优化 checklist

```
RDMA 带宽优化要点:

  [ ] 使用 RC 传输类型
  [ ] 消息大小 >= 64KB（最大化效率）
  [ ] QP 深度 64-256
  [ ] 启用 inline data（小于 512 字节）
  [ ] 多流并行（每流独立 QP）
  [ ] MTU 设置 9000 (jumbo frame)
  [ ] NUMA 亲和性配置
  [ ] 关闭 transparent hugepage
  [ ] PCIe Gen 3 x8 或更高
  [ ] 使用多线程，每线程独立 QP
```

---

## 10. 总结

### 10.1 带宽 vs 延迟权衡

```
带宽和延迟的权衡:

  追求最低延迟:
    - QP 深度: 16-32
    - 轮询: 忙等待
    - 消息: 小消息 (< 4KB)
    - CPU: 满载

  追求最高带宽:
    - QP 深度: 128-512
    - 轮询: 批量轮询
    - 消息: 大消息 (>= 64KB)
    - 多流: 8-16 并行流

  最佳实践:
    - 基础延迟优化（NUMA, 注册内存）
    - 根据场景选择配置
    - 测试验证实际效果
```

### 10.2 性能公式

```
RDMA 带宽计算:

  实际带宽 = 线速 × 效率因子

  效率因子 ≈ f(消息大小, MTU, 协议开销)

  简化公式:
    效率 ≈ 1 / (1 + 协议开销/消息大小)

  示例:
    消息大小 = 64KB = 65536 bytes
    协议开销 = 58 bytes (RoCE v2)
    效率 = 1 / (1 + 58/65536) = 99.91%

    实际带宽 ≈ 100 Gbps × 99.91% ≈ 99.9 Gbps

  结论:
    消息越大，效率越高，带宽越接近线速
```

下一章我们将讨论 CPU 利用率优化，降低 RDMA 的 CPU 开销。
