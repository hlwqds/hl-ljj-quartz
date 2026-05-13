---
title: io_uring 深度探索 Ch1：架构概述与核心机制
date: 2026-04-18 14:00:00
tags: [io_uring, Linux, Async IO, High Performance, Kernel, Storage, Networking]
description: 深入讲解 io_uring 的核心架构：Ring Buffer 机制、SQE/CQE 结构、三种操作模式、与 epoll/aio 的本质区别，以及基准性能测试。
---

# io_uring 深度探索 Ch1：架构概述与核心机制

## 1. io_uring 是什么

io_uring 是 Linux 5.1（2019）引入的新一代异步 I/O 接口，由 Jens Axboe（block layer maintainer）主导设计。它的目标是：

```
一句话解释：
  io_uring = 绕过传统系统调用开销的异步 I/O 环形队列

传统 I/O 路径（epoll + read/write）：
  用户态 → write() → 内核 → 复制数据 → 返回
           ↑ 每次都要陷入内核（syscall 开销）

io_uring 路径：
  用户态 → 写 SQE → 内核消费 → 读 CQE → 用户态
           ↑ 通过共享内存 Ring Buffer，无须每次 syscall

性能提升来源：
  1. 减少 syscall 次数（批量提交）
  2. 减少数据拷贝（fixed buffer 零拷贝）
  3. 内核旁路（kernel bypass，polling 模式）
```

> [!note]
> io_uring 和 DPDK 是同一类思想的不同实现：
>
> - **DPDK**：网卡 I/O 绕过内核协议栈
> - **io_uring**：磁盘/网络 I/O 绕过传统 syscall
>   都是共享内存 + Ring Buffer + 无锁队列的核心模式

---

## 2. 核心架构：两个 Ring Buffer

### 2.1 两 Ring 的本质

```
io_uring 的核心是两个共享内存 Ring Buffer：

┌─────────────────────────────────────────────────────────┐
│                      User Space                          │
│                                                          │
│   ┌──────────────────────┐   ┌──────────────────────┐   │
│   │  Submission Queue    │   │  Completion Queue    │   │
│   │  (SQ - 写请求)        │   │  (CQ - 结果)         │   │
│   │  [tail = 写入位置]   │   │  [head = 读取位置]   │   │
│   │  [head = 已提交]     │   │  [tail = 写入位置]   │   │
│   └──────────↑───────────┘   └──────────↑───────────┘   │
│              │                            │               │
│              │    kernel ↔ user 共享      │               │
│              │                            │               │
│   ┌──────────┴───────────┐   ┌──────────┴───────────┐   │
│   │  kernel 消费 SQE      │   │  kernel 写入 CQE     │   │
│   │  更新 head            │   │  更新 tail           │   │
│   └───────────────────────┘   └───────────────────────┘   │
│                      Kernel Space                         │
└─────────────────────────────────────────────────────────┘

工作流程：
  1. 用户态写 SQE（submission queue entry）到 SQ
  2. 调用 io_uring_enter() 通知内核（或者用 sqpoll 模式跳过）
  3. 内核消费 SQE，执行 I/O
  4. 内核写 CQE（completion queue entry）到 CQ
  5. 用户态读 CQE 获取结果
```

### 2.2 为什么用两个 Ring

```
分开的好处（设计哲学）：

Submission Queue（单向：用户→内核）：
  - 用户只写（producer）
  - 内核只读（consumer）
  - 完全无锁（只需要更新 tail/head）

Completion Queue（单向：内核→用户）：
  - 内核只写（producer）
  - 用户只读（consumer）
  - 完全无锁

如果合并成一个会怎样：
  - 需要双向同步（生产者+消费者）
  - 需要 CAS（compare-and-swap）原子操作
  - 开销更大

这是经典的"双缓冲"思想：
  - 生产者和消费者不直接交互
  - 通过中间缓冲区解耦
  - 各自独立并发
```

### 2.3 内存模型与 Cache Line

```c
// io_uring 的 ring 结构（简化）
struct io_sqring {
    volatile unsigned *head;      // 内核更新，用户读
    volatile unsigned *tail;      // 用户更新，内核读
    struct io_uring_sqe *sqes;   // SQE 数组
    unsigned nr_entries;          // 队列深度（2的幂）
    unsigned flags;
};

struct io_cqring {
    volatile unsigned *head;     // 用户更新，内核读
    volatile unsigned *tail;     // 内核更新，用户读
    struct io_uring_cqe *cqes;   // CQE 数组
    unsigned nr_entries;
    unsigned *overflow;          // 溢出计数
};

// flags 字段
#define IORING_SQ_NEED_WAKEUP  (1 << 0)  // sqpoll 模式需要手动唤醒
#define IORING_SQ_CQ_OVERFLOW  (1 << 1)  // CQ 溢出标记
```

---

## 3. 三种操作模式

io_uring 支持三种模式，从"最简单"到"最高性能"：

### 3.1 模式 1：系统调用轮询（syscall polling）

```
最基础的模式，每次 I/O 需要两次 syscall：

io_uring_enter() 两次：
  第一次：通知内核"SQE 已提交"（SYNC_FILE_RANGE 等效）
  第二次：等待 CQE 可读

缺点：
  - 每次都要 syscall
  - 相比 epoll+read/write 优势不大
  - 仅在大量并发时有效（摊薄 syscall 开销）

适用场景：
  - 快速上手 demo
  - debug / 调试
  - 不追求极致性能
```

### 3.2 模式 2：内核轮询（kernel-side polling / SQPOLL）

```
io_uring_setup(entries, &params);
params.flags |= IORING_SETUP_SQPOLL;  // 开启 sqpoll 模式

┌─────────────────────────────────────────────┐
│  User Space                                 │
│   写 SQE → SQ tail++                       │
│                    ↑                        │
│                    │ wake_up()             │
│   读 CQE ← CQ head++                       │
│                                              │
│  Kernel Space                               │
│   内核线程持续轮询 SQ head != tail？        │
│   有活 → 消费 SQE → 写 CQE → 继续轮询        │
│   没活 → 睡眠（可被 wake_up 唤醒）          │
└─────────────────────────────────────────────┘

优点：
  - 完全不需要 syscall 来提交 SQE
  - 内核线程自动处理，用户只管读写 ring
  - 极低延迟（微秒级）

缺点：
  - 占用一个 CPU 核心（内核线程）
  - 额外内存（内核线程栈）
  - 复杂度高（需要处理 wake_up）

适用场景：
  - 高性能存储 I/O（数据库、文件系统）
  - 追求极低延迟（NVMe SSD 场景）
```

### 3.3 模式 3：直接模式（提交侧直接通知）

```
IORING_SETUP_SQ_AFF | IORING_SETUP_SUBMIT_ALL

用户直接写 SQ tail，内核线程自动感知（mmap 共享）

不需要 io_uring_enter() 系统调用：
  - mmap SQ + CQ 到用户空间
  - 用户写 SQE 后，内核线程通过共享内存看到
  - 完全零 syscall（除了 setup 阶段）

这是 io_uring 的最高性能模式。
```

### 3.4 三模式对比

```
模式               syscall/次I/O  CPU占用   延迟   适用场景
─────────────────────────────────────────────────────────
系统调用轮询         2次           低        高     入门/debug
内核轮询(SQPOLL)    ~0次          高(1核)   低     高性能存储
直接模式            0次           中        最低   极致性能
─────────────────────────────────────────────────────────

内存占用：
  - 系统调用轮询：Ring Buffer + sqes（固定）
  - SQPOLL：+ 内核线程栈（8KB~16KB）
  - 所有模式都需要 mmap：CQ * sizeof(cqe) + SQ * sizeof(sqe)
```

---

## 4. SQE / CQE 详解

### 4.1 SQE（Submission Queue Entry）

```c
// struct io_uring_sqe（固定 64 字节）
struct io_uring_sqe {
    __u8    opcode;         // 操作码（read/write/open/close...）
    __u8    flags;          // 标志（IOSQE_*）
    __u16   ioprio;         // I/O 优先级
    __s32   fd;             // 文件描述符
    __u64   off;            // 偏移量（文件内）
    __u64   addr;           // 用户缓冲区地址
    __u32   len;            // 缓冲区长度
    union {
        __u32  rw_flags;    // read/write 标志（ROPRECAT 等）
        __u32  fsync_flags; // fsync 标志
        __u16  poll_events; // poll 事件
        __u16  sync_hint;   // sync hint
        __u32  buf_index;   // 固定缓冲区索引
    };
    __u64   user_data;      // 用户数据（关联 sqe 和 cqe）
    union {
        struct {
            __u16 buf_index;   // 缓冲区索引
            __u16 buf_group;   // 缓冲区组
        } h2c;
        struct {
            __u64 addr2;        // 额外地址
            __u64 splice_fd_in; // splice 源 fd
        };
        struct {
            __u32 cmd_ops_len;  // command 长度
            __u32 cmd_data;     // command 数据
        };
    };
    __u8    buf_index_high;  // 高位 buf_index
    __u8    pad[5];         // padding
};
```

### 4.2 CQE（Completion Queue Entry）

```c
// struct io_uring_cqe（固定 16 字节）
struct io_uring_cqe {
    __u64 user_data;    // 来自 sqe 的 user_data（用于匹配）
    __s32 result;       // 系统调用返回值（read 返回字节数，负数=错误码）
    __u32 flags;        // 完成标志
};
```

### 4.3 user_data：连接 SQE 和 CQE 的桥梁

```c
// 为什么 CQE 只有 16 字节（而非复制整个 SQE）？
// 答案：user_data 字段

// 用户提交时：
struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
sqe->opcode = IORING_OP_READ;
sqe->fd = fd;
sqe->addr = (unsigned long)buf;
sqe->len = 4096;
sqe->off = file_offset;
sqe->user_data = (uint64_t)my_request_ptr;  // 指向用户上下文

// 完成时：
struct io_uring_cqe *cqe;
io_uring_peek_cqe(ring, &cqe);
printf("result=%d, ctx=%p\n", cqe->result, (void*)cqe->user_data);

// user_data 可以是：
//   - 请求的指针（包含所有上下文）
//   - 请求 ID（整数）
//   - 任意 64-bit 数据
```

### 4.4 操作码（opcode）

```
io_uring 支持的操作码（常用）：

文件 I/O：
  IORING_OP_READ          ← 读文件（替代 read()）
  IORING_OP_WRITE         ← 写文件（替代 write()）
  IORING_OP_FSYNC         ← 文件同步（替代 fsync()）
  IORING_OP_FALLOCATE     ← 预分配空间（替代 fallocate()）
  IORING_OP_STATX         ← 文件状态（替代 statx()）
  IORING_OP_READV         ← 分散读取（替代 readv()）
  IORING_OP_WRITEV        ← 聚集写入（替代 writev()）

文件管理：
  IORING_OP_OPENAT       ← 打开文件（替代 openat()）
  IORING_OP_CLOSE         ← 关闭文件（替代 close()）
  IORING_OP_SPLICE        ← 零拷贝数据移动（替代 splice()）
  IORING_OP_TEE            ← 管道复制（替代 tee()）

网络 I/O（5.3+）：
  IORING_OP_RECVMSG       ← 接收消息
  IORING_OP_SENDMSG       ← 发送消息
  IORING_OP_WRITE_FIXED   ← 固定缓冲区写入
  IORING_OP_READ_FIXED    ← 固定缓冲区读取

同步：
  IORING_OP_NOP           ← 空操作（测试用）
  IORING_OP_TIMEOUT        ← 超时
  IORING_OP_LINK_TIMEOUT   ← 链接超时
  IORING_OP_POLL_UPDATE    ← 更新 poll 状态
  IORING_OP_EPOLL_CTL      ← epoll 控制（5.5+）

其他：
  IORING_OP_POLL_ADD       ← 添加 poll fd（5.6+）
  IORING_OP_CONNECT        ← 连接 socket（5.10+）
  IORING_OP_ACCEPT         ← 接受连接（5.10+）
```

---

## 5. API 详解

### 5.1 完整初始化流程

```c
#include <liburing.h>

int main() {
    struct io_uring ring;
    struct io_uring_params params = {0};

    // 模式选择
    params.flags = IORING_SETUP_SQPOLL;  // 开启内核轮询
    // params.flags = IORING_SETUP_SQPOLL | IORING_SETUP_SQ_AFF; // + CPU 绑定

    // SQPOLL 模式下：内核轮询线程的 CPU ID
    // params sq_thread_cpu = 3;

    // 队列深度（必须是 2 的幂）
    // params.sq_thread_idle = 1000;  // 空闲超时（毫秒）

    // 初始化
    int ret = io_uring_queue_init_params(256, &ring, &params);
    if (ret < 0) {
        perror("io_uring_queue_init_params");
        return 1;
    }

    // 正常 I/O 操作...

    // 清理
    io_uring_queue_exit(&ring);
    return 0;
}
```

### 5.2 同步等待模式

```c
// 方式 1：io_uring_wait_cqe（阻塞等待）
struct io_uring_cqe *cqe;
int ret = io_uring_wait_cqe(&ring, &cqe);
if (ret == 0) {
    printf("完成: result=%d, user_data=%lu\n",
           cqe->result, cqe->user_data);
    io_uring_cqe_seen(&ring, cqe);  // 确认已读
}

// 方式 2：io_uring_peek_cqe（非阻塞，不会等待）
ret = io_uring_peek_cqe(&ring, &cqe);
if (ret == 0) {
    // 有 CQE 可读
    io_uring_cqe_seen(&ring, cqe);
} else {
    // 没有 CQE，继续做其他事
}

// 方式 3：io_uring_wait_cqes（等待多个）
struct io_uring_cqe *cqe[64];
unsigned got;
ret = io_uring_wait_cqes(&ring, cqe, 64, NULL, NULL);
for (int i = 0; i < ret; i++) {
    printf("cqe[%d]: result=%d\n", i, cqe[i]->result);
    io_uring_cqe_seen(&ring, cqe[i]);
}

// 方式 4：带超时等待
struct __kernel_timespec ts;
ts.tv_sec = 0;
ts.tv_nsec = 100000000;  // 100ms
ret = io_uring_wait_cqe(&ring, &cqe, &ts);
```

### 5.3 批量提交

```c
// io_uring 的核心优势：批量提交

// 一次性提交多个 SQE
struct io_uring_sqe *sqe1 = io_uring_get_sqe(&ring);
io_uring_prep_read(sqe1, fd1, buf1, 4096, 0);

struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
io_uring_prep_write(sqe2, fd2, buf2, 4096, 0);

struct io_uring_sqe *sqe3 = io_uring_get_sqe(&ring);
io_uring_prep_openat(sqe3, AT_FDCWD, "/tmp/test", O_RDONLY, 0);

// 一次性提交所有 SQE
ret = io_uring_submit(&ring);
// 返回值 = 提交的 SQE 数量
// 后续用 io_uring_wait_cqe 等结果

// 非阻塞提交（不等待）
ret = io_uring_submit(&ring);  // 直接返回，不阻塞
// 配合 io_uring_peek_cqe 轮询

// 对比 epoll：
// epoll + read/write：每个 I/O = 1 次 syscall
// io_uring：N 个 I/O = 1 次 io_uring_submit()
//   syscall 开销从 N 次 → 1 次
```

### 5.4 liburing 辅助函数

```c
// liburing 提供了高级 API，简化 SQE 填充

// 读文件
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_read(sqe, fd, buf, 4096, 0);
// 等价：
// sqe->opcode = IORING_OP_READ;
// sqe->fd = fd;
// sqe->addr = (unsigned long)buf;
// sqe->len = 4096;
// sqe->off = 0;  // 文件偏移

// 写文件
sqe = io_uring_get_sqe(&ring);
io_uring_prep_write(sqe, fd, buf, 4096, 0);

// 打开文件
sqe = io_uring_get_sqe(&ring);
io_uring_prep_openat(sqe, AT_FDCWD, "/path/to/file", O_RDONLY, 0);

// 关闭文件
sqe = io_uring_get_sqe(&ring);
io_uring_prep_close(sqe, fd);

// recv（网络）
sqe = io_uring_get_sqe(&ring);
io_uring_prep_recv(sqe, sockfd, buf, 1024, 0);

// send（网络）
sqe = io_uring_get_sqe(&ring);
io_uring_prep_send(sqe, sockfd, buf, 1024, 0);

// splice（零拷贝，文件到文件）
sqe = io_uring_get_sqe(&ring);
io_uring_prep_splice(sqe, fd_in, off_in, fd_out, off_out, len, SPLICE_F_MOVE);

// 填好 SQE 后统一提交
io_uring_submit(&ring);
```

---

## 6. 与 epoll / aio 的本质区别

### 6.1 epoll 对比

```
epoll 的问题：
  - 只解决"哪些 fd 有数据"的问题（I/O 多路复用）
  - 读/写还是要用 read/write（每个 I/O 一次 syscall）
  - epoll_wait 本身也是 syscall

epoll + read/write vs io_uring：
                          epoll              io_uring
──────────────────────────────────────────────────────
读 1000 个文件：
  read() syscall         1000 次             0 次（提交时在内核）
  epoll_wait()           1 次 / 多次         0~1 次
  总 syscall 数          1000+              0（sqpoll）或 1（submit）
──────────────────────────────────────────────────────

epoll 的本质：通知机制（谁有数据）
io_uring 的本质：异步执行引擎（I/O 本身）
```

### 6.2 aio 对比

```
传统 Linux AIO（POSIX aio）：
  - 只支持 O_DIRECT 磁盘 I/O
  - kernel 实现不完善（io_setup/io_submit/io_getevents）
  - bug 多，性能差

io_uring vs Linux AIO：

                Linux AIO            io_uring
──────────────────────────────────────────────────────
磁盘 I/O        ✅ O_DIRECT only     ✅ 任意文件
网络 I/O        ❌ 不支持            ✅ 支持（5.3+）
内存 I/O        ❌ 不支持            ✅ 支持
性能            差（设计过时）       高（现代设计）
易用性          复杂                 简单
批量提交        困难                 原生支持
Fixed Buffer    ❌                   ✅ 零拷贝
kernel polling  ❌                   ✅ SQPOLL
──────────────────────────────────────────────────────

结论：io_uring 是 Linux AIO 的完全替代品
      Linux AIO 已过时，新项目应该用 io_uring
```

### 6.3 直观的架构对比图

```
epoll 架构（同步 I/O）：
  用户态 ←── read() ──→ 内核 ←── I/O ──→ 磁盘/网卡
              ↑
         epoll 告诉你哪个 fd 可读
         但读还是得一次次 syscall

aio 架构（异步，但残缺）：
  用户态 ←── io_submit ──→ 内核（O_DIRECT 限制）
              ↑
         只支持磁盘 O_DIRECT
         网络/普通文件/内存 都不支持

io_uring 架构（真·异步）：
  用户态 ←── SQE 写入共享内存 ──→ 内核 ←── I/O ──→ 任意设备
              ↑
         io_uring_submit() 通知
         完全通过共享内存通信
         无 syscall（sqpoll 模式）
```

---

## 7. 完整示例代码

### 7.1 基础示例：读取文件

```c
#include <stdio.h>
#include <stdlib.h>
#include <liburing.h>
#include <fcntl.h>
#include <unistd.h>

#define ENTRIES_SIZE  256

int main(int argc, char *argv[]) {
    const char *filename = "/etc/passwd";
    if (argc > 1) filename = argv[1];

    // Step 1: 初始化 io_uring
    struct io_uring ring;
    struct io_uring_params params = {0};

    int ret = io_uring_queue_init_params(ENTRIES_SIZE, &ring, &params);
    if (ret < 0) {
        perror("io_uring_queue_init_params");
        return 1;
    }

    printf("io_uring 初始化成功，队列深度=%d\n", ENTRIES_SIZE);

    // Step 2: 打开文件
    int fd = open(filename, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    // Step 3: 分配读缓冲区
    char *buf = malloc(8192);
    if (!buf) {
        perror("malloc");
        return 1;
    }

    // Step 4: 构造 SQE（读操作）
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    if (!sqe) {
        fprintf(stderr, "没有可用的 SQE！\n");
        return 1;
    }

    // 使用 liburing 辅助函数填充
    io_uring_prep_read(sqe, fd, buf, 8192, 0);
    sqe->user_data = 12345;  // 关联 SQE 和 CQE

    // Step 5: 提交 SQE
    ret = io_uring_submit(&ring);
    if (ret < 0) {
        perror("io_uring_submit");
        return 1;
    }
    printf("已提交 %d 个 SQE\n", ret);

    // Step 6: 等待 CQE
    struct io_uring_cqe *cqe;
    ret = io_uring_wait_cqe(&ring, &cqe);
    if (ret < 0) {
        perror("io_uring_wait_cqe");
        return 1;
    }

    // Step 7: 处理结果
    printf("user_data=%lu, result=%d\n", cqe->user_data, cqe->result);
    if (cqe->result > 0) {
        printf("读取了 %d 字节:\n", cqe->result);
        // 找第一个换行，打印前几行
        buf[cqe->result] = '\0';
        char *line = buf;
        for (int i = 0; i < 5 && line; i++) {
            char *next = strchr(line, '\n');
            if (next) *next = '\0';
            printf("  %s\n", line);
            line = next ? next + 1 : NULL;
        }
    } else if (cqe->result < 0) {
        fprintf(stderr, "读取错误: %s\n", strerror(-cqe->result));
    }

    // Step 8: 标记 CQE 已读
    io_uring_cqe_seen(&ring, cqe);

    // Step 9: 清理
    close(fd);
    free(buf);
    io_uring_queue_exit(&ring);

    return 0;
}
```

编译运行：

```bash
gcc -o io_test io_test.c -luring
./io_test
# io_uring 初始化成功，队列深度=256
# 已提交 1 个 SQE
# user_data=12345, result=...
```

### 7.2 进阶示例：批量读取多个文件

```c
#include <stdio.h>
#include <stdlib.h>
#include <liburing.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

#define BUF_SIZE   4096
#define MAX_FILES  8

typedef struct {
    char filename[256];
    char *buf;
    int fd;
    int index;
} file_request_t;

int main() {
    const char *files[] = {
        "/etc/passwd", "/etc/hosts", "/etc/group", "/etc/issue"
    };
    int num_files = 4;

    struct io_uring ring;
    int ret = io_uring_queue_init_params(256, &ring,
        &(struct io_uring_params){0});
    if (ret < 0) return 1;

    // 分配请求结构
    file_request_t *reqs = calloc(num_files, sizeof(file_request_t));
    char *bufs = calloc(num_files, BUF_SIZE);

    // Step 1: 打开所有文件（批量提交 open）
    for (int i = 0; i < num_files; i++) {
        reqs[i].buf = bufs + i * BUF_SIZE;
        reqs[i].fd = open(files[i], O_RDONLY);
        reqs[i].index = i;
        strncpy(reqs[i].filename, files[i], 255);

        if (reqs[i].fd < 0) {
            perror(files[i]);
            continue;
        }

        // 构造读 SQE
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
        io_uring_prep_read(sqe, reqs[i].fd, reqs[i].buf, BUF_SIZE, 0);
        sqe->user_data = (unsigned long)&reqs[i];  // 传指针
    }

    // Step 2: 一次性提交所有读请求
    ret = io_uring_submit(&ring);
    printf("提交了 %d 个读请求\n", ret);

    // Step 3: 等待并处理所有完成事件
    int completed = 0;
    while (completed < ret) {
        struct io_uring_cqe *cqe;
        ret = io_uring_wait_cqe(&ring, &cqe);
        if (ret < 0) continue;

        file_request_t *req = (file_request_t *)cqe->user_data;
        printf("[%s] ", req->filename);

        if (cqe->result > 0) {
            printf("读取 %d 字节\n", cqe->result);
        } else if (cqe->result == 0) {
            printf("EOF\n");
        } else {
            printf("错误: %s\n", strerror(-cqe->result));
        }

        io_uring_cqe_seen(&ring, cqe);
        completed++;
    }

    // Step 4: 关闭所有文件
    for (int i = 0; i < num_files; i++) {
        if (reqs[i].fd >= 0) close(reqs[i].fd);
    }

    free(reqs);
    free(bufs);
    io_uring_queue_exit(&ring);

    return 0;
}
```

### 7.3 SQPOLL 高性能模式

```c
#include <stdio.h>
#include <stdlib.h>
#include <liburing.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

int main() {
    struct io_uring ring;
    struct io_uring_params params = {
        .flags = IORING_SETUP_SQPOLL,    // 开启内核轮询
        .sq_thread_idle = 1000,          // 空闲 1s 后睡眠
    };

    int ret = io_uring_queue_init_params(1024, &ring, &params);
    if (ret < 0) {
        perror("io_uring_queue_init_params");
        return 1;
    }

    // SQPOLL 模式下，内核线程已启动
    // 不需要每次 submit 都 syscall
    // 直接写 SQE + io_uring_submit()

    // 测试：提交 N 个读操作
    int fd = open("/dev/zero", O_RDONLY);
    char buf[4096];

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf, 4096, 0);
    sqe->user_data = 1;

    // 不需要 io_uring_enter()！
    // 内核线程自动发现 sqe
    ret = io_uring_submit(&ring);
    printf("提交结果: %d\n", ret);

    // 但第一次可能需要唤醒（如果内核线程在睡眠）
    if (params.flags & IORING_SETUP_SQ_NEED_WAKEUP) {
        io_uring_ring_dontfork(&ring);  // 安全 fork
        ret = io_uring_enter(ring.ring_fd, 1, 0,
                           IORING_ENTER_SQ_WAKEUP, NULL);
    }

    // 等待完成
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);
    printf("完成: result=%d\n", cqe->result);
    io_uring_cqe_seen(&ring, cqe);

    close(fd);
    io_uring_queue_exit(&ring);
    return 0;
}
```

---

## 8. 性能基准测试

### 8.1 测试环境假设

```
测试环境：
  CPU:    AMD EPYC 7702P（64核）
  RAM:    256GB DDR4
  Disk:   Samsung 980 PRO 1TB NVMe
  OS:     Linux 6.1.0
  Kernel: io_uring enabled

测试工具：
  - fio（支持 io_uring）
  - 编译：fio --enable-io_uring
```

### 8.2 fio 配置对比

```bash
# 对比 3 种 I/O 模式的吞吐量

# 1. 传统 sync（baseline）
[fio-sync]
filename=/tmp/testfile
rw=read
bs=4k
size=1g
ioengine=sync
direct=0
runtime=10

# 2. libaio（异步，Linux AIO）
[fio-libaio]
filename=/tmp/testfile
rw=read
bs=4k
size=1g
ioengine=libaio
direct=1
runtime=10
iodepth=64

# 3. io_uring（最新异步 I/O）
[fio-io_uring]
filename=/tmp/testfile
rw=read
bs=4k
size=1g
ioengine=io_uring
direct=1
runtime=10
iodepth=64

# 运行
fio fio-sync.fio
fio fio-libaio.fio
fio fio-io_uring.fio
```

### 8.3 预期结果

```
单线程 4K 随机读，iodepth=64：

模式        IOPS        延迟(avg)   延迟(p99)
────────────────────────────────────────────────
sync        ~150K       6.7ms       13ms
libaio      ~450K       0.14ms      0.3ms
io_uring    ~520K       0.12ms      0.25ms
io_uring    ~580K*      0.11ms      0.22ms
  (sqpoll)

* io_uring + sqpoll 相比 libaio 提升 ~25-30%

多线程（16线程）4K 随机读：
  libaio:    ~2.8M IOPS
  io_uring:  ~3.5M IOPS（提升 ~25%）
```

### 8.4 syscall 开销对比

```bash
# 用 strace 统计 syscall 次数
strace -c fio fio-sync.fio 2>&1 | grep -E "read|write|ioctl|poll"
strace -c fio fio-io_uring.fio 2>&1 | grep -E "read|write|ioctl|poll"

# sync 模式（每个 I/O 一次 read）：
# % time     seconds  usecs/call     calls    errors syscall
# ------  ----------- ----------- --------- --------- -------
# 70.00    0.700000      1000      700     -         read

# io_uring 模式（批量提交 + 零 syscall）：
# % time     seconds  usecs/call     calls    errors syscall
# ------  ----------- ----------- --------- --------- -------
# 5.00     0.050000      1000        50     -         io_uring_enter
#                                          （大幅减少！）
```

---

## 9. 内核实现浅析

### 9.1 sys_io_uring_setup

```c
// 用户调用 io_uring_setup(entries, params)
// 内核创建两个 ring buffer + 一些辅助结构

struct io_ring_ctx {
    struct {
        struct io_ring_hdr *hdr;       // 队列头信息
        struct io_uring_sq *sq;        // SQ ring
        struct io_uring_sqe *sq_sqes;  // SQE 数组
        ...
    } sq;
    struct {
        struct io_uring_cq *cq;         // CQ ring
        struct io_uring_cqe *cq_cqes;  // CQE 数组
        ...
    } cq;

    struct wait_queue_head       sq_wait;   // SQ 等待队列
    struct task_struct          *sq_thread; // SQPOLL 内核线程

    struct list_head            submit_list; // 待处理的 SQE 链表
    ...
};
```

### 9.2 sys_io_uring_enter

```c
// 用户调用 io_uring_enter(fd, to_submit, min_complete, flags, sig)
// 告诉内核："有 to_submit 个 SQE 已提交，请处理"

SYSCALL_DEFINE6(io_uring_enter, int, fd, unsigned, to_submit,
    unsigned, min_complete, unsigned, flags, const sigset_t __user *, sig,
    size_t, sigsz)
{
    struct io_ring_ctx *ctx;
    struct file *file;
    int ret;

    // 1. 获取 ring fd 对应的 struct file
    file = fget(fd);
    ctx = file->private_data;

    // 2. 如果有新的 SQE，唤醒 sqpoll 线程
    if (to_submit)
        io_uring_ring_drainage_wake(ctx);

    // 3. 如果需要等待完成
    if (min_complete)
        ret = io_uring_wait_cqes(ctx, ...);
    else
        ret = to_submit;

    fput(file);
    return ret;
}
```

### 9.3 SQE 处理流程

```
用户态写 SQE 到 SQ ring：
  sqe->opcode = IORING_OP_READ;
  sqe->fd = open(...);
  sqe->addr = buf_addr;
  sqe->len = 4096;
  sq_ring->tail++;  // 更新 tail

内核消费 SQE（两种路径）：

路径 A（sqpoll 模式）：
  内核线程轮询 sq_ring->head != sq_ring->tail？
    → 读取 sq_ring->sqes[sq_ring->head & mask]
    → 解析 opcode
    → 分发到具体处理函数
    → 写 CQE 到 cq_ring
    → sq_ring->head++

路径 B（用户通知）：
  io_uring_enter() 系统调用
    → 检查 sq_ring 是否有新 SQE
    → 分发处理
    → 写 CQE
```

---

## 10. 常见问题与注意事项

### 10.1 SQE 用完怎么办

```c
// io_uring_get_sqe() 返回 NULL = 没有可用 SQE
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
if (!sqe) {
    // 方案 1：先提交已有的，再获取新的
    io_uring_submit(&ring);
    // 然后再获取
    sqe = io_uring_get_sqe(&ring);
}

// 方案 2：用 io_uring_peek_batch（一次获取多个）
struct io_uring_sqe *sqes[64];
int got = io_uring_peek_batch(&ring, sqes, 64);
// got = 实际获取的数量
```

### 10.2 CQ 溢出处理

```c
// 如果完成的 CQE 数量 > CQ 队列深度，CQ 会溢出
// 溢出时：内核把溢出数写入 overflow 字段

unsigned *overflow;
ret = io_uring_mqesize(&ring, &overflow);
// 如果 overflow > 0，需要处理溢出

// 解决方案：
// 1. 增大 CQ 队列深度
// 2. 及时消费 CQE（不要积压）
// 3. 使用 IORING_SETUP_CQINSIZE（自动扩大 CQ）
```

### 10.3 多线程安全

```c
// io_uring 是线程安全的，但有注意事项：

// ✅ 安全：多个线程共享同一个 ring
// io_uring 内部使用原子操作
struct io_uring ring;
pthread_t threads[4];
for (int i = 0; i < 4; i++)
    pthread_create(&threads[i], NULL, worker, &ring);

// ✅ 安全：每个线程独立的 ring
struct io_uring ring_per_thread[4];

// ❌ 不安全：sqpoll 模式 + 多进程
// 同一个 ring 不能被多个进程 fork 后的子进程共享
// 如果要 fork + io_uring，需要：
io_uring_ring_dontfork(&ring);
```

### 10.4 文件描述符生命周期

```c
// ⚠️ 注意：io_uring 提交 close 操作后，
//    不能立即再次使用同一个 fd！

// 错误示例：
sqe = io_uring_get_sqe(&ring);
io_uring_prep_close(sqe, fd);
io_uring_submit(&ring);
// ❌ 此时 fd 可能已经被关闭
// 但 io_uring 的 close 是异步执行的
// 其他 SQE 如果使用了同一个 fd，可能出问题

// 正确做法：close 后不要再用 fd，直到收到 CQE
```

---

## 11. 小结

```
io_uring = Linux 5.1+ 的新一代异步 I/O 接口

核心思想：
  两个 Ring Buffer（SQ + CQ）
  共享内存通信，零拷贝
  用户提交 SQE → 内核执行 → 用户读 CQE

三种模式：
  系统调用轮询：每次提交 2 次 syscall（入门）
  SQPOLL：内核轮询，0 次 syscall（高性能）
  直接模式：mmap + 共享内存，极致性能

优势对比：
  vs epoll：批量提交减少 syscall
  vs Linux AIO：支持所有 I/O 类型（文件/网络/内存）

关键 API：
  io_uring_queue_init_params() — 初始化
  io_uring_get_sqe()           — 获取 SQE
  io_uring_prep_read/write/... — 填充 SQE
  io_uring_submit()            — 提交
  io_uring_wait_cqe()          — 等待完成
  io_uring_cqe_seen()          — 确认消费

user_data：
  SQE 和 CQE 通过 user_data 字段配对
  可以是指针、ID 或任意 64-bit 数据

下一个章节：
  Ch2：注册机制与零拷贝（fixed buffer / fixed fd）
```

---

## 延伸阅读

- `man io_uring_setup` — 系统调用手册
- liburing 源码: `https://github.com/axboe/liburing`
- Linux 内核源码: `fs/io_uring.c`
- Jens Axboe（作者）: https://git.kernel.org/pub/scm/linux/kernel/git/axboe/linux-block.git/
- fio（支持 io_uring）: `https://github.com/axboe/fio`
- LWN 文章: "Async I/O and io_uring" (https://lwn.net/Articles/810071/)
- Benchmark: https://github.com/axboe/liburing/tree/master/src/bench
