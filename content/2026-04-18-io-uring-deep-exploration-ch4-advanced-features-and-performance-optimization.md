---
title: io_uring 深度探索 Ch4：进阶特性与性能优化
date: 2026-04-18 21:00:00
tags:
  [
    io_uring,
    Linux,
    Async IO,
    High Performance,
    Kernel,
    SQPOLL,
    Multishot,
    Memory,
    Benchmark,
    Optimization,
  ]
description: 深入讲解 io_uring 进阶特性：SQPOLL 深度调优、multishot 机制、IORING_SETUP_ATTACH_TASK、内存屏障与 cache line 对齐、perf 火焰图分析，以及性能优化实战。
---

# io_uring 深度探索 Ch4：进阶特性与性能优化

## 1. SQPOLL 深度调优

### 1.1 SQPOLL 内核线程工作原理

```
SQPOLL 模式下的工作流程：

┌─────────────────────────────────────────────────────┐
│  用户空间                                           │
│   while (1) {                                        │
│     sqe = io_uring_get_sqe(&ring);  // 写 SQ tail   │
│     io_uring_submit(&ring);         // 轻量通知     │
│   }                                                 │
│                                                      │
│   while (1) {                                        │
│     io_uring_peek_cqe(&ring, &cqe); // 读 CQ head  │
│   }                                                 │
│                                                      │
│  Kernel Space（sqpoll 线程）                        │
│   while (1) {                                        │
│     if (sq_tail != sq_head) {  // 有新 SQE         │
│       consume_sqe();          // 消费               │
│       process();             // 执行 I/O            │
│       write_cqe();          // 写 CQ              │
│     } else {                                         │
│       schedule(); // 睡眠，等待唤醒                  │
│     }                                                │
│   }                                                 │
│                                                      │
│  唤醒机制：                                          │
│   用户提交新 SQE → 写 sq_tail → 触发 wake_up(sqpoll) │
└─────────────────────────────────────────────────────┘

关键参数：
  sq_thread_idle — 内核线程空闲多久后睡眠（毫秒）
  sq_thread_cpu  — 内核线程绑定到哪个 CPU
```

### 1.2 sq_thread_idle 调优

```c
// sq_thread_idle：内核线程空闲多久后睡眠

// 默认值：1000ms（1秒）

// 场景 1：高频 I/O（iodepth 持续有请求）
// → 设置大一点，避免频繁唤醒/睡眠
params.sq_thread_idle = 5000;  // 5秒后才睡

// 场景 2：低频 I/O（偶尔才有请求）
// → 设置小一点，不浪费 CPU
params.sq_thread_idle = 200;   // 200ms 后就睡

// 场景 3：极低延迟要求（任何时刻都想立即响应）
// → 但又不想一直占用 CPU
params.sq_thread_idle = 100;   // 100ms

// 睡眠后的唤醒：
// 用户提交 SQE 时，发现 sqpoll 在睡眠
// → 设置 IORING_SQ_NEED_WAKEUP 标志
// → 调用 io_uring_enter() 并带 IORING_ENTER_SQ_WAKEUP
if (ring.flags & IORING_SQ_NEED_WAKEUP) {
    io_uring_enter(ring.ring_fd, 0, 0, IORING_ENTER_SQ_WAKEUP, NULL);
}
```

### 1.3 CPU 绑定（sq_thread_cpu）

```c
// sqpoll 线程占用一个 CPU 核心
// 默认：内核调度器决定

// 建议：绑定到专用的 CPU 核心（避免干扰其他任务）
params.flags |= IORING_SETUP_SQ_AFF;  // 启用 CPU 绑定
params.sq_thread_cpu = 3;             // 绑定到 CPU 3

// 配合 isolcpus 使用（BIOS/GRUB 隔离 CPU）：
// isolcpus=3,5,7
// → 这几个 CPU 不会被调度器分配给普通进程
// → sqpoll 独占，不受干扰

// 注意：
// - 绑定后，内核线程固定在 CPU 3
// - 用户线程也可以绑定到 CPU 3（减少跨 CPU 调度）
// - 或者用户线程绑定到其他 CPU（减少竞争）
```

### 1.4 IORING_SETUP_SQ_AFF 完整示例

```c
#include <stdio.h>
#include <stdlib.h>
#include <liburing.h>
#include <sched.h>

int main() {
    struct io_uring ring;
    struct io_uring_params params = {0};

    // 启用 SQPOLL + CPU 绑定
    params.flags = IORING_SETUP_SQPOLL | IORING_SETUP_SQ_AFF;
    params.sq_thread_cpu = 3;       // 绑定到 CPU 3
    params.sq_thread_idle = 2000;   // 2秒空闲后睡眠

    int ret = io_uring_queue_init_params(256, &ring, &params);
    if (ret < 0) {
        perror("io_uring_queue_init_params");
        return 1;
    }

    // 把当前线程绑定到另一个 CPU（避免和 sqpoll 竞争）
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(1, &cpuset);  // 绑定到 CPU 1
    pthread_t tid = pthread_self();
    pthread_setaffinity_np(tid, sizeof(cpu_set_t), &cpuset);

    printf("sqpoll 内核线程在 CPU %d\n", params.sq_thread_cpu);
    printf("当前线程在 CPU 1\n");

    // 正常工作...
    char buf[4096];
    int fd = open("/dev/zero", O_RDONLY);
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf, 4096, 0);
    io_uring_submit(&ring);

    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);
    printf("读取 %d 字节\n", cqe->result);
    io_uring_cqe_seen(&ring, cqe);

    io_uring_queue_exit(&ring);
    close(fd);
    return 0;
}
```

### 1.5 SQPOLL 的 wake_up 机制

```c
// SQPOLL 线程睡眠后，如何唤醒？

// 场景：大量请求后，sqpoll 线程进入睡眠
// 此时用户提交新 SQE：

// 内核处理：
// 1. 用户写 sq_tail++
// 2. 检查 sqpoll 线程是否在睡眠
// 3. 如果在睡眠 → 设置 IORING_SQ_NEED_WAKEUP 不需要
//    （内核自动检测并唤醒）
// 4. 实际上：每次提交都会检查

// 手动唤醒（某些边界情况需要）：
// 比如 fork 后子进程要提交 SQE：
if (params.flags & IORING_SETUP_SQPOLL) {
    // 子进程需要手动唤醒 sqpoll
    io_uring_enter(ring.ring_fd, 0, 0, IORING_ENTER_SQ_WAKEUP, NULL);
}
```

---

## 2. IORING_SETUP_ATTACH_TASK（跨进程共享）

### 2.1 问题：fork 后 sqpoll 归属问题

```
普通 fork + io_uring 的问题：

父进程：创建了 sqpoll ring
  → sqpoll 内核线程属于父进程

fork() 后：
  → 子进程继承 ring fd
  → 子进程可以提交 SQE
  → 但 sqpoll 内核线程还在父进程里！
  → 子进程的 SQE 需要父进程的 sqpoll 处理

这会导致：
  - 父进程退出，sqpoll 线程消失
  - 子进程的 SQE 无人处理
  - 或者：资源泄漏 / 行为不确定
```

### 2.2 IORING_SETUP_ATTACH_TASK 解决

```c
// IORING_SETUP_ATTACH_TASK = 让 ring 附加到创建者的 task

// 父进程：
struct io_uring_params params = {
    .flags = IORING_SETUP_ATTACH_TASK,
};
io_uring_queue_init_params(256, &ring, &params);

// 然后 fork：
pid_t pid = fork();
if (pid == 0) {
    // 子进程
    // ring 附加到父进程的 task
    // sqpoll 线程继续为子进程工作
    // （因为是附加到父进程的 task_struct，不是进程）
}

// 或者另一种用法：线程共享
// 主线程创建 sqpoll ring
// 工作线程共享同一个 ring
// ATTACH_TASK 确保所有线程共享同一个 sqpoll 线程
```

### 2.3 ATTACH_TASK 内部原理

```c
// 内核实现：
struct io_ring_ctx {
    struct task_struct *task;      // 附加到的 task
    struct wait_queue_head *wait;  // 等待队列
    // ...
};

// io_uring_setup() 时：
if (params->flags & IORING_SETUP_ATTACH_TASK) {
    ctx->task = current;  // 附加到当前 task
} else {
    ctx->task = NULL;  // 默认行为：谁创建谁用
}

// io_uring_enter() 时：
// 检查 ctx->task
// 如果不为 NULL → 权限检查
// 确保调用者确实是附加的 task
```

---

## 3. Multishot（一次注册，多次完成）

### 3.1 multishot vs 普通单次

```
普通模式：
  SQE → 提交 → 一次 CQE → 完成
  （每次 I/O 都需要一个 SQE）

multishot 模式：
  SQE → 提交 → CQE → CQE → CQE → ... → 取消
  （一个 SQE 持续产生 CQE，直到显式取消）

典型应用：
  1. accept：持续接收多个连接（不用每次都 submit accept）
  2. poll：持续监控文件描述符（不用每次都 submit poll）
```

### 3.2 multishot ACCEPT

```c
// 普通 ACCEPT（单次）
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_accept(sqe, listenfd, &client_addr, &addrlen, 0);
sqe->user_data = ACCEPT_TAG;
io_uring_submit(&ring);
// → 收到一个连接后，产生一个 CQE
// → 如果有多个连接，需要再 submit 新的 accept SQE

// multishot ACCEPT（5.11+）
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_multishot_accept(sqe, listenfd,
                                &client_addr, &addrlen,
                                SOCK_NONBLOCK);  // 常用标志
sqe->user_data = ACCEPT_TAG;
io_uring_submit(&ring);
// → 持续产生 CQE，每次新连接一个 CQE
// → 直到：close(listenfd) 或 unlink sqe

// CQE 格式：
// cqe->result = client fd（或错误）
// cqe->flags = IORING_CQE_F_MORE（后面还有）
```

### 3.3 multishot POLL

```c
// multishot POLL = 持续监控 fd 事件

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_POLL_ADD;
sqe->fd = sockfd;
sqe->poll_events = POLLIN | POLLOUT;
sqe->user_data = POLL_TAG;
// 用 liburing 辅助
io_uring_prep_poll_add(sqe, sockfd, POLLIN);
io_uring_prep_poll_multishot(sqe, POLLIN);  // 5.19+

io_uring_submit(&ring);
// 持续产生 CQE，直到：
// - POLL_REMOVE（手动取消）
// - fd 关闭

// 收到的 CQE：
// cqe->result = 实际触发的事件（POLLIN 等）
```

### 3.4 取消 multishot

```c
// 取消 multishot SQE

// 方法 1：POLL_REMOVE
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_POLL_UPDATE;
sqe->addr = (unsigned long)&remove_args;
sqe->len = 1;
sqe->user_data = REMOVE_TAG;
// remove_args.old_user_data = 原始 poll sqe 的 user_data

// 方法 2：直接 close fd
// POLL_ADD 的 fd 关闭后，自动取消

// 方法 3：不补充 multishot
// 对于 accept：不调用新的 accept SQE
// → 现有的 multishot accept 继续有效
// → 直到 queue 满或出错
```

---

## 4. 内存屏障与 Cache Line 对齐

### 4.1 为什么要关心内存屏障

```
io_uring 使用共享内存（mmap）通信：

用户线程 ←→ 内核线程
（通过 SQ/CQ Ring 共享内存）

如果没有内存屏障：
  用户写 sq_tail++ → 内核可能看到旧值
  内核写 cqe → 用户可能看到旧值

问题场景：
  Thread A（用户）：sq_tail = 5（写入）
  Thread B（内核）：读取 sq_tail → 可能得到 4（旧值）
  → 内核漏读 SQE！

解决方案：内存屏障（Memory Barrier）
  → 确保写入对其他线程可见
```

### 4.2 io_uring 的内存屏障保证

```c
// io_uring 的 Ring Buffer 使用了两种机制：

// 1. volatile 关键字
struct io_sqring {
    volatile unsigned *head;  // 内核写，用户读
    volatile unsigned *tail;  // 用户写，内核读
};

// volatile 的作用：
// - 防止编译器优化掉读写
// - 编译器不会把写操作移到屏障之后
// - 但不保证 CPU 之间的可见性

// 2. 实际解决方案：Store-Store + Load-Load 屏障

// 内核写 CQE 时的屏障：
// smp_wmb() — 确保 CQE 数据在 head 更新前写入

// 用户读 CQE 前的屏障：
// smp_rmb() — 确保 head 更新后才能读数据

// io_uring_sqring_advance()（用户提交 SQE 后）：
//   → 调用 smp_wmb() 确保 sqe 数据在 sq_tail 更新前完成

// io_uring_cqe_get()（用户读 CQE 前）：
//   → 调用 smp_rmb() 确保 head 更新后才能读数据
```

### 4.3 实际开发需要关心吗？

```
大多数情况不需要关心内存屏障，因为：

1. liburing 帮你处理
   io_uring_submit() / io_uring_wait_cqe() 等 API
   内部已经包含了必要的屏障

2. volatile 字段已经够了
   大多数平台（x86_64 / ARM64）上
   volatile 的顺序已经足够

什么情况需要关心：

1. 自己实现 ring buffer（不用 liburing）
   → 需要手动加屏障

2. 访问 ring 结构但不调用 API
   → 比如直接读 cq_array[head]

3. 极端性能优化
   → 绕过 liburing 直接访问 mmap 区域
   → 但收益很小，不推荐
```

### 4.4 Cache Line 对齐

```
Ring Buffer 的字段如果落在同一个 cache line：
→ 会被其他核的访问影响（false sharing）

io_uring 的 padding 策略：

// kernel 源码中的结构：
struct io_sqring {
    volatile unsigned head;
    volatile unsigned tail;
    unsigned head_cache;   // ← padding，减少 false sharing
    unsigned tail_cache;   // ← padding
    // ...
};

// 最佳实践：应用层也注意对齐

// ✅ 好：分开使用 head 和 tail
unsigned head = *ring->sq.head;  // 读
// 中间做其他事
unsigned tail = *ring->sq.tail;   // 读

// ❌ 不好：连续读 head + tail
if (*ring->sq.head == *ring->sq.tail) // 可能在同一 cache line
    // 编译器可能优化成只读一次

// 实践中：不用管，liburing 已经处理好了
// 除非你直接操作 ring 指针
```

---

## 5. 性能优化实战

### 5.1 批量提交优化

```c
// ❌ 低效：每次 I/O 都单独提交
for (int i = 0; i < 100; i++) {
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fds[i], bufs[i], 4096, 0);
    sqe->user_data = i;
    io_uring_submit(&ring);  // ← 每次都 syscall！
}

// ✅ 高效：批量提交
for (int i = 0; i < 100; i++) {
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fds[i], bufs[i], 4096, 0);
    sqe->user_data = i;
}
// 最后一次性提交
io_uring_submit(&ring);  // ← 1 次 syscall
// 甚至 SQPOLL 模式下：不需要 syscall！

// 性能对比：
// 单次提交：100 次 syscall
// 批量提交：1 次 syscall
// SQPOLL 模式：0 次 syscall
```

### 5.2 队列深度优化

```c
// 队列深度选择原则：

// 太小：I/O 阻塞，吞吐下降
// 太大：内存浪费，延迟增加

// 经验公式：
queue_depth = desired_IOPS × expected_latency

// 示例：
// NVMe SSD：IOPS = 500K，延迟 = 0.2ms = 0.0002s
// queue_depth = 500K × 0.0002 = 100
// → 队列深度 100 就能饱和 500K IOPS

// 实际测试：
// queue_depth=64:  IOPS=480K
// queue_depth=128: IOPS=520K  ← 开始饱和
// queue_depth=256: IOPS=525K  ← 边际收益递减
// queue_depth=512: IOPS=530K  ← 浪费

// 多核场景：
// 每 CPU 独立 ring：
//   total_queue_depth = per_ring_depth × num_cores
//   8核 × 128 = 1024 总队列深度

// 总内存占用：
// queue_depth × sqe_size × 2(rings) + cqes
// 128 × 64 × 2 + 128 × 16 = 20KB / ring
// → 很小，可以多 ring
```

### 5.3 SQE 预填充（Pipeline 模式）

```c
// 高性能 I/O Pipeline：

// 思路：在等待 CQE 的同时，预填充 SQ

#define DEPTH 256

char bufs[DEPTH][4096];
struct io_uring_sqe *sqes[DEPTH];

// Step 1: 预先分配所有 SQE
for (int i = 0; i < DEPTH; i++) {
    sqes[i] = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqes[i], fd, bufs[i], 4096, file_offset[i]);
    sqes[i]->user_data = i;
}
io_uring_submit(&ring);

// Step 2: 处理完成的同时，补充新的 SQE
int head = 0;
while (running) {
    // 收割已完成的 CQE
    struct io_uring_cqe *cqe;
    while (io_uring_peek_cqe(&ring, &cqe) == 0) {
        int idx = cqe->user_data;
        process_buf(idx, bufs[idx], cqe->result);
        io_uring_cqe_seen(&ring, cqe);

        // 立即补充新的 SQE（复用相同 buffer）
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
        if (sqe) {
            io_uring_prep_read(sqe, fd, bufs[idx], 4096, new_offset[idx]);
            sqe->user_data = idx;
        }

        head++;
    }
    io_uring_submit(&ring);
}
```

### 5.4 固定 FD + 固定 Buffer 极致优化

```c
// 极致性能配置：
struct io_uring_params params = {
    .flags = IORING_SETUP_SQPOLL    // 内核轮询
             | IORING_SETUP_SQ_AFF // CPU 绑定
             | IORING_SETUP_ATTACH_TASK, // 进程共享
    .sq_thread_cpu = 3,      // CPU 3
    .sq_thread_idle = 1000,  // 1秒空闲
};

io_uring_queue_init_params(DEPTH, &ring, &params);

// 注册所有 FD
int num_fds = 16;
int fds[num_fds];
for (int i = 0; i < num_fds; i++) {
    fds[i] = open(files[i], O_RDONLY | O_DIRECT);
}
io_uring_register_files(&ring, fds, num_fds);

// 注册所有 buffer
struct iovec iovs[DEPTH];
for (int i = 0; i < DEPTH; i++) {
    posix_memalign(&iovs[i].iov_base, 4096, 4096);
    iovs[i].iov_len = 4096;
}
io_uring_register_buffers(&ring, iovs, DEPTH);

// 使用：
// - fd = fixed fd index（0~num_fds-1）
// - buf = buf index（0~DEPTH-1）
// - 零 syscall，零拷贝，零查找
```

---

## 6. perf 火焰图分析

### 6.1 安装工具

```bash
# 安装 perf
# Debian/Ubuntu
apt install linux-tools-$(uname -r) linux-tools-common

# 安装火焰图工具
git clone https://github.com/brendangregg/FlameGraph.git
export PATH=$PATH:/path/to/FlameGraph

# 检查权限
perf version
perf list | head
```

### 6.2 采集 io_uring 程序的数据

```bash
# 找到进程 PID
./my_io_uring_app &
PID=$!

# 采集 30 秒 CPU profile
perf record -F 99 -p $PID -g -- sleep 30

# 或者：采集特定事件
perf record -e cycles -p $PID -g -- sleep 30

# 查看报告
perf report

# 生成火焰图
perf script | ./FlameGraph/stackcollapse-perf.pl | \
    ./FlameGraph/flamegraph.pl > io_app.svg
```

### 6.3 解读火焰图

```
火焰图怎么看：

          [main]                    ← 栈顶（当前 CPU 在哪）
             │
             ├── io_uring_submit    ← 提交
             ├── io_uring_wait_cqe  ← 等待
             └── [kernel]           ← 内核态

宽度 = 采样中出现在该层的比例（越多越宽 = 越热）

优化目标：
  → 找最宽的"平顶山"（热点）
  → 越宽 = 越占用 CPU

io_uring 程序常见的热点：

1. submit 单次调用（频繁提交）
   → 应该批量提交
   → flame 看到 submit 占了 30%+
   → 改用 batch submit 后降到 5%

2. cqring 轮询忙等（没有 sleep）
   while (io_uring_peek_cqe() == -EAGAIN) { } // 忙等
   → CPU 100%，但没做事
   → 应该用 io_uring_wait_cqe()（阻塞等待）

3. memcpy（数据拷贝）
   → 应该用 fixed buffer

4. access_ok()（用户地址验证）
   → 应该用 fixed buffer
```

### 6.4 分析具体瓶颈

```bash
# 场景：程序 CPU 100% 但 IOPS 不高

# Step 1: 采样
perf record -F 999 -p $PID -g -- sleep 10

# Step 2: 看热点
perf report -g --stdio | head -100

# 输出示例：
#  Overhead  Command          Shared Object          Symbol
#  30.00%    my_app    [kernel.kallsyms]    [k] io_uring_enter
#  20.00%    my_app    [kernel.kallsyms]    [k] sys_io_uring_enter
#  15.00%    my_app    libc.so.6            [.] __memcpy_avx_unaligned

# 分析：
# 30% 在 io_uring_enter → 频繁 syscall
# 15% 在 memcpy → 数据拷贝多
# → 应该用 fixed buffer + sqpoll

# Step 3: 加上 call graph
perf report -g --stdio | grep -A50 "io_uring"
# 看调用链
```

---

## 7. 系统参数调优

### 7.1 /proc/sys/fs/io_uring 调优

```bash
# 查看当前限制
ls /proc/sys/fs/io_uring/
# files  max_user_files  max注册-user-buffers

# 查看具体值
cat /proc/sys/fs/io_uring/max_user_files
# 默认：32768

cat /proc/sys/fs/io_uring/max注册-user-buffers
# 默认：8388608（约 8M）

# 调大（高并发场景）
echo 65536 > /proc/sys/fs/io_uring/max_user_files

# 如果遇到 EMFILE（too many open files）
# 先检查
ulimit -n  # soft limit
# 如果太小：
# /etc/security/limits.conf:
# * soft nofile 1048576
# * hard nofile 1048576
```

### 7.2 kernel.bpf_stats_enabled

```bash
# 启用后可以用 bpftool 查看 BPF 程序运行统计
echo 1 > /proc/sys/kernel/bpf_stats_enabled

# 如果有 io_uring + BPF 混合程序
# 可以看到每个 BPF 程序的：
# - run_time_ns：总运行时间
# - run_cnt：调用次数
# - avg_time_ns：平均单次运行时间
bpftool prog show --json | jq '.[] | {name, run_cnt, run_time_ns}'
```

### 7.3 网络参数（io_uring 网络 I/O 时）

```bash
# 如果用 io_uring 做网络 I/O，可能需要调整：

# TCP buffer
echo 16777216 > /proc/sys/net/core/rmem_max
echo 16777216 > /proc/sys/net/core/wmem_max

# 连接队列
# 对于 accept 场景，listen backlog 要够大
# setsockopt(listenfd, SOL_TCP, TCP backlog, &backlog, sizeof(backlog));

# SO_REUSEPORT（多进程/多线程负载均衡）
# setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, ...);
```

---

## 8. 常见性能问题与解法

### 8.1 问题：IOPS 上不去

```c
// 症状：队列深度已经很大，但 IOPS 很低

// 可能原因 1：syscall 瓶颈
// 每次 submit 都调用 io_uring_enter()
while (1) {
    io_uring_submit(&ring);  // ← 每次都要 syscall
}

// 解法：SQPOLL 模式
params.flags |= IORING_SETUP_SQPOLL;

// 可能原因 2：buffer 分配阻塞
sqe = io_uring_get_sqe(&ring);
sqe->addr = malloc(4096);  // ← malloc 可能阻塞！
io_uring_prep_read(...);

// 解法：预分配 + 对齐
posix_memalign(&buf, 4096, 4096);
io_uring_register_buffers(&ring, &iov, 1);

// 可能原因 3：文件 fd 瓶颈
// 每个 I/O 都要查 fd → file* → 文件系统
// 解法：固定 fd
io_uring_register_files(&ring, &fd, 1);
sqe->flags |= IOSQE_FIXED_FILE;
```

### 8.2 问题：延迟抖动

```c
// 症状：延迟忽高忽低，不稳定

// 可能原因 1：GC/内存压缩
// malloc 触发内核内存压缩，延迟尖峰
// 解法：提前分配所有 buffer（不用 malloc）

// 可能原因 2：CPU 调度
// sqpoll 线程被其他进程抢占
// 解法：isolcpus 隔离 + CPU 绑定
params.sq_thread_cpu = 3;
sched_setaffinity(0, sizeof(cpu_set_t), &cpuset);

// 可能原因 3：网络栈延迟
// TCP retransmit / Nagle 算法
// 解法：
int flag = 1;
setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
setsockopt(sockfd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof(buf));

// 可能原因 4：Page Cache
// 读文件时，page fault 延迟
// 解法：用 O_DIRECT（绕过 page cache）
fd = open(path, O_RDONLY | O_DIRECT);
```

### 8.3 问题：程序卡死

```c
// 症状：io_uring_submit() 或 wait_cqe() 卡住

// 可能原因 1：ring 队列满
// get_sqe 返回 NULL
while (!(sqe = io_uring_get_sqe(&ring))) {
    // 队列满
    io_uring_submit(&ring);  // 提交腾出空间
    usleep(1);
}

// 解法：检查 sqe 是否可用
if (io_uring_sq_space_left(&ring) < 1) {
    // 队列快满了，先提交
    io_uring_submit(&ring);
}

// 可能原因 2：SQPOLL 线程崩溃
// kernel bug 或 OOM
// 解法：监控 sqpoll 线程状态
// /proc/<pid>/wchan 可以看到 sqpoll 在等什么

// 可能原因 3：fd 泄漏
// close() 没有正确处理
// 解法：确保每个 open 都有对应的 close
// 并且 close 的 CQE 完成后才复用 fd

// 可能原因 4：死锁
// 两个 ring 互相等待
// 解法：避免环形依赖
```

---

## 9. 基准测试工具

### 9.1 liburing 带的 bench 工具

```bash
# libuing 源码里有基准测试工具
git clone https://github.com/axboe/liburing.git
cd liburing
./configure
make -j$(nproc)

# sqpoll vs 非 sqpoll 对比
./src/sqthread-cpp -s /dev/sda -d 256 -r 5 -w 5
# -s: 设备
# -d: 队列深度
# -r: 读深度
# -w: 写深度

# 基础带宽测试
./src/sqchat-cpp /dev/sda1
# 测试顺序读/写的带宽和 IOPS
```

### 9.2 fio 配置示例

```ini
# io_uring 测试配置 fio_uring.ini

[global]
ioengine=io_uring
direct=1
blocksize=4k
runtime=30
time_based=1

# 测试 1：普通 io_uring
[job_uring]
filename=/dev/sda1
rw=randread
iodepth=64
numjobs=1

# 测试 2：io_uring + fixed buffer
[job_uring_fixed]
filename=/dev/sda1
rw=randread
iodepth=64
numjobs=1
registerfiles=1
fixedbufs=1

# 测试 3：io_uring + sqpoll
[job_uring_sqpoll]
filename=/dev/sda1
rw=randread
iodepth=64
numjobs=1
sqthread_poll=1
sqthread_poll_cpu=3

# 测试 4：顺序读大文件
[job_seq]
filename=/dev/sda1
rw=read
blocksize=1m
iodepth=32
numjobs=1

# 运行
fio fio_uring.ini --group_reporting
```

### 9.3 自己写基准测试

```c
// simple_bench.c — 简单基准测试

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <liburing.h>

#define IOSIZE      4096
#define DEPTH       256
#define TOTAL_OPS   100000

int64_t get_nsec() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

int main(int argc, char *argv[]) {
    const char *path = argv[1] ? argv[1] : "/dev/zero";
    int is_direct = (argc > 2 && strcmp(argv[2], "direct") == 0);

    struct io_uring ring;
    struct io_uring_params params = {0};
    if (argc > 3 && strcmp(argv[3], "poll") == 0)
        params.flags = IORING_SETUP_SQPOLL;

    io_uring_queue_init_params(DEPTH, &ring, &params);

    // 注册 fixed buffer（如果可用）
    int use_fixed = 0;
    char *buf;
    struct iovec iov;
    if (is_direct) {
        posix_memalign(&buf, 4096, IOSIZE);
        iov.iov_base = buf;
        iov.iov_len = IOSIZE;
        io_uring_register_buffers(&ring, &iov, 1);
        use_fixed = 1;
    } else {
        buf = malloc(IOSIZE);
    }

    // Warmup
    for (int i = 0; i < DEPTH; i++) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
        if (use_fixed) {
            io_uring_prep_read_fixed(sqe, 0, buf, IOSIZE, 0, 0);
        } else {
            io_uring_prep_read(sqe, 0, buf, IOSIZE, 0);
        }
        sqe->user_data = i;
    }
    io_uring_submit(&ring);
    struct io_uring_cqe *cqe;
    for (int i = 0; i < DEPTH; i++)
        io_uring_wait_cqe(&ring, &cqe), io_uring_cqe_seen(&ring, cqe);

    // Benchmark
    int fd = open(path, O_RDONLY | (is_direct ? O_DIRECT : 0));
    int64_t start = get_nsec();

    int completed = 0;
    int submitted = 0;
    while (completed < TOTAL_OPS) {
        // 填充队列
        while (submitted < TOTAL_OPS &&
               submitted - completed < DEPTH) {
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
            if (use_fixed) {
                io_uring_prep_read_fixed(sqe, fd, buf, IOSIZE, 0, 0);
            } else {
                io_uring_prep_read(sqe, fd, buf, IOSIZE, 0);
            }
            sqe->user_data = submitted++;
        }
        io_uring_submit(&ring);

        // 收割
        while (io_uring_peek_cqe(&ring, &cqe) == 0) {
            if (cqe->result < 0)
                fprintf(stderr, "error: %d\n", cqe->result);
            io_uring_cqe_seen(&ring, cqe);
            completed++;
        }
    }

    int64_t end = get_nsec();
    double duration = (end - start) / 1e9;
    double iops = completed / duration;
    double bw = iops * IOSIZE / 1e9;

    printf("模式: %s %s\n",
           is_direct ? "O_DIRECT" : "cached",
           (params.flags & IORING_SETUP_SQPOLL) ? "SQPOLL" : "SYSCALL");
    printf("总操作数: %d\n", completed);
    printf("耗时: %.2fs\n", duration);
    printf("IOPS: %.0f\n", iops);
    printf("带宽: %.2f GB/s\n", bw);

    close(fd);
    free(buf);
    io_uring_queue_exit(&ring);
    return 0;
}
```

编译运行：

```bash
gcc -o bench bench.c -luring -O2

# 测试各种模式
./bench /dev/zero cached syscall
./bench /dev/zero direct syscall
./bench /dev/zero direct poll
./bench /dev/sda1 direct poll

# 预期结果：
# /dev/zero cached SYSCALL: ~500K IOPS
# /dev/zero direct SYSCALL: ~480K IOPS
# /dev/zero direct SQPOLL: ~520K IOPS
# /dev/sda1 direct SQPOLL: ~450K IOPS（受 SSD 限制）
```

---

## 10. 小结

```
进阶特性与优化：

SQPOLL 调优：
  sq_thread_idle：空闲多久后睡眠
    - 高频 I/O → 大（5s）
    - 低频 I/O → 小（200ms）
  sq_thread_cpu：CPU 绑定
    - isolcpus 隔离，独占核心
  IORING_SETUP_SQ_AFF：启用 CPU 绑定
  IORING_SETUP_ATTACH_TASK：fork 后共享 ring

Multishot：
  - 一次注册，持续产生 CQE
  - ACCEPT：持续接收连接
  - POLL：持续监控事件
  - 减少 SQE 提交次数

内存与 Cache：
  - volatile 字段处理可见性
  - Cache line 对齐避免 false sharing
  - 实践中 liburing 已经处理好了

性能优化核心：
  1. 批量提交（1 次 syscall 替代 N 次）
  2. SQPOLL（0 次 syscall）
  3. 固定 FD + 固定 Buffer（零验证 + 零拷贝）
  4. 队列深度 = IOPS × latency
  5. Pipeline：预填充 SQ，收割时补充

Perf 火焰图：
  - 找最宽的"平顶山"（热点）
  - submit 占高 → 批量或 sqpoll
  - memcpy 占高 → fixed buffer
  - 忙等占高 → 改用 wait 而非 peek

系统调优：
  /proc/sys/fs/io_uring/max_user_files
  /proc/sys/fs/io_uring/max注册-user-buffers
  ulimit -n
  TCP 参数（网络 I/O 时）
```

---

## 延伸阅读

- `perf stat` / `perf record`: `man perf-record`
- FlameGraph: https://github.com/brendangregg/FlameGraph
- liburing bench: `https://github.com/axboe/liburing/tree/master/src`
- fio io_uring engine: `engines/io_uring.c` (fio 源码)
- LWN: "io_uring multishot accept": https://lwn.net/Articles/854908/
- LWN: "io_uring performance": https://lwn.net/Articles/827062/
- Kernel tuning: `Documentation/admin-guide/sysctl/fs.rst`
