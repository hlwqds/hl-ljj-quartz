---
title: io_uring 深度探索 Ch3：SQE/CQE 详解与操作码
date: 2026-04-18 19:00:00
tags: [io_uring, Linux, Async IO, High Performance, Kernel, Operation Codes, Linked Chain, Timeout]
description: 详细讲解 io_uring 所有操作码的语义与用法：文件 I/O、网络 I/O、同步机制、timeout、poll、linked chain，以及实战文件复制和 HTTP 请求。
---

# io_uring 深度探索 Ch3：SQE/CQE 详解与操作码

## 1. SQE 字段详解回顾

### 1.1 完整 SQE 结构（64 字节）

```c
struct io_uring_sqe {
    __u8    opcode;         // [1] 操作码（最重要）
    __u8    flags;          // [2] IOSQE_* 标志
    __u16   ioprio;         // [3-4] I/O 优先级
    __s32   fd;             // [5-8] 文件描述符（或 fixed fd 索引）
    __u64   off;            // [9-16] 偏移量（文件内 offset）
    __u64   addr;           // [17-24] 用户缓冲区地址
    __u32   len;            // [25-28] 缓冲区长度
    union {                 // [29-32] 操作特定标志
        __u32  rw_flags;    //   read/write: RWF_* 标志
        __u32  fsync_flags; //   fsync: FSYNC_* 标志
        __u16  poll_events; //   poll: EPOLL* 事件
        __u32  sync_hint;   //   sync hint
        __u32  buf_index;   //   fixed buffer 索引
    };
    __u64   user_data;      // [33-40] 用户数据（CQE 配对）
    union {                 // [41-56] 扩展字段
        struct {
            __u16 buf_index;
            __u16 buf_group;
        } h2c;
        struct {
            __u64 addr2;
            __u64 splice_fd_in;
        };
        struct {
            __u32 cmd_ops_len;
            __u32 cmd_data;
        };
    };
    __u8    buf_index_high; // [57] buf_index 高位（5.13+）
    __u8    pad[5];         // [58-64] padding
};
```

### 1.2 SQE flags 详解

```c
// SQE flags = IOSQE_* 系列

IOSQE_FIXED_FILE   (1 << 0)  // fd 是 fixed fd 索引，不是真实 fd
IOSQE_IO_DRAIN     (1 << 1)  // 排空：等前面所有操作完成后再执行
IOSQE_IO_LINK      (1 << 2)  // 链接：下一个 SQE 依赖当前
IOSQE_ASYNC        (1 << 3)  // 异步：允许并行执行
IOSQE_BUFFER_SELECT (1 << 4)  // 从 buffer group 选择 buffer

// 常用组合
// 1. fixed fd + fixed buffer
sqe->flags = IOSQE_FIXED_FILE;
io_uring_prep_read_fixed(sqe, fixed_fd_idx, ..., buf_index);

// 2. 链接操作（chain）
io_uring_prep_read(sqe1, fd1, buf1, 4096, 0);
sqe1->flags = IOSQE_IO_LINK;
io_uring_prep_write(sqe2, fd2, buf1, 4096, 0);
// sqe2 自动依赖 sqe1 完成后才执行

// 3. 排空（DRAIN）
sqe->flags = IOSQE_IO_DRAIN;
// 等所有之前的 SQE 完成后才执行这个
// 用于 sync/close 前，确保前面所有 I/O 都完成
```

---

## 2. 操作码分类全览

```
io_uring 操作码（按类别）：

文件 I/O：
  IORING_OP_READ              读
  IORING_OP_WRITE             写
  IORING_OP_READV             分散读（readv）
  IORING_OP_WRITEV            聚集写（writev）
  IORING_OP_READ_FIXED        固定缓冲区读
  IORING_OP_WRITE_FIXED       固定缓冲区写

文件管理：
  IORING_OP_OPENAT            打开文件
  IORING_OP_CLOSE             关闭文件
  IORING_OP_STATX             文件状态
  IORING_OP_FALLOCATE         预分配空间
  IORING_OP_FTRUNCATE         截断文件
  IORING_OP_RENAME            重命名
  IORING_OP_UNLINK            删除

同步：
  IORING_OP_FSYNC             文件同步（fsync）
  IORING_OP_SYNC_FILE_RANGE   显式文件同步
  IORING_OP_NOP               空操作
  IORING_OP_TIMEOUT           超时
  IORING_OP_LINK_TIMEOUT      链接超时
  IORING_OP_WAITID            等待进程 ID

网络 I/O（5.3+）：
  IORING_OP_RECV              接收数据
  IORING_OP_SEND              发送数据
  IORING_OP_RECVMSG           接收消息（带 msg_control）
  IORING_OP_SENDMSG           发送消息
  IORING_OP_CONNECT           连接
  IORING_OP_ACCEPT            接受连接

数据移动：
  IORING_OP_SPLICE            零拷贝数据移动（内核内部）
  IORING_OP_TEE               管道复制

轮询：
  IORING_OP_POLL_ADD          添加 poll fd
  IORING_OP_POLL_UPDATE       更新 poll 状态
  IORING_OP_EPOLL_CTL         epoll 控制（5.5+）

其他：
  IORING_OP_URING_CMD         用户命令（5.6+）
  IORING_OP_URING_CMD_FIXED   带固定缓冲区的用户命令
  IORING_OP_SOCKET            创建 socket（5.10+）
```

---

## 3. 文件 I/O 操作码

### 3.1 READ / READ_FIXED

```c
// 普通读
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_READ;
sqe->fd = fd;                          // 普通 fd
sqe->addr = (unsigned long)buf;         // 缓冲区地址
sqe->len = 4096;                        // 读多少
sqe->off = 0;                          // 文件偏移（0=从当前）
sqe->user_data = (uint64_t)request_ptr;

// 等价的 liburing 辅助函数
io_uring_prep_read(sqe, fd, buf, len, offset);

// 带 RWF_ 标志的读
sqe->rw_flags = RWF_HIPRI;   // 高优先级（可能跳过队列）
sqe->rw_flags = RWF_DSYNC;   // 等效 O_DSYNC
sqe->rw_flags = RWF_SYNC;    // 等效 O_SYNC
sqe->rw_flags = RWF_NOWAIT;  // 不等待（O_NONBLOCK）
sqe->rw_flags = RWF_APPEND;  // 追加模式

// 固定缓冲区读（零拷贝）
io_uring_prep_read_fixed(sqe, fd, buf, len, offset, buf_index);
// buf_index = 注册的 buffer 索引
// fd = fixed fd 索引（需设置 IOSQE_FIXED_FILE 标志）
sqe->flags |= IOSQE_FIXED_FILE;
```

### 3.2 WRITE / WRITE_FIXED

```c
// 普通写
io_uring_prep_write(sqe, fd, buf, len, offset);
sqe->rw_flags = RWF_APPEND;   // 追加写
sqe->rw_flags = RWF_DSYNC;    // 数据同步
sqe->rw_flags = RWF_SYNC;     // 文件同步

// 固定缓冲区写
io_uring_prep_write_fixed(sqe, fd, buf, len, offset, buf_index);
sqe->flags |= IOSQE_FIXED_FILE;

// 写固定长度
// 用于日志、性能 trace 等固定大小记录
```

### 3.3 READV / WRITEV（分散聚集 I/O）

```c
// readv = 一次读，多个缓冲区（类似 scatter）
struct iovec iov[3];
iov[0].iov_base = buf1; iov[0].iov_len = 1024;
iov[1].iov_base = buf2; iov[1].iov_len = 1024;
iov[2].iov_base = buf3; iov[2].iov_len = 1024;

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_READV;
sqe->fd = fd;
sqe->addr = (unsigned long)iov;   // iovec 数组地址
sqe->len = 3;                      // iovec 数量
sqe->off = 0;

// liburing 辅助
io_uring_prep_readv(sqe, fd, iov, 3, 0);

// writev = 一次写，多个缓冲区（类似 gather）
// 用于写结构体数组、日志等
io_uring_prep_writev(sqe, fd, iov, 3, 0);
```

### 3.4 FSYNC（文件同步）

```c
// fsync = 把文件数据刷到磁盘
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_FSYNC;
sqe->fd = fd;
sqe->off = 0;  // fsync_flags 决定范围
sqe->fsync_flags = 0;  // 0 = 全部数据
// sqe->fsync_flags = FSYNC_FSYNC_RANGE;  // 只刷 range（如果支持）

// 等价于：
//   fsync(fd);  // 阻塞！

// 但 io_uring 的 fsync 是异步的：
//   - 提交后立即返回
//   - 内核在后台刷盘
//   - 通过 CQE 通知完成

// 应用场景：
//   - 日志写入后立即刷盘（db 不丢数据）
//   - 批量写文件后统一 fsync

// 典型模式：
io_uring_prep_write(sqe1, fd, log_buf, log_len, file_off);
sqe1->flags = IOSQE_IO_LINK;  // 链接到 fsync
io_uring_prep_fsync(sqe2, fd, 0, 0);
sqe2->flags = IOSQE_IO_DRAIN;  // 排空，确保写完成后再 fsync
io_uring_submit(&ring);
```

---

## 4. 文件管理操作码

### 4.1 OPENAT（打开文件）

```c
// 异步打开文件
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_OPENAT;
sqe->fd = AT_FDCWD;                       // 目录 fd（AT_FDCWD=当前目录）
sqe->addr = (unsigned long)"/tmp/test";   // 路径
sqe->len = 0;                              // 必须 0
sqe->off = O_RDWR | O_CREAT | O_TRUNC;     // flags
sqe->user_data = OPENAT_REQUEST_ID;

// 等价于：
//   openat(AT_FDCWD, "/tmp/test", O_RDWR | O_CREAT | O_TRUNC, 0644);

// mode 参数在 off 的高位（不同架构）
// liburing 辅助
io_uring_prep_openat(sqe, AT_FDCWD, "/tmp/test", O_RDWR | O_CREAT, 0644);

// 注意：返回的 fd 在 CQE result 中
// result = 打开后的 fd（>= 0 成功，< 0 错误码）
```

```c
// 处理 openat 结果
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);

if (cqe->result >= 0) {
    int opened_fd = cqe->result;
    printf("打开文件成功，fd=%d\n", opened_fd);
    // 后续可以用这个 fd 做 I/O
} else {
    printf("打开文件失败: %s\n", strerror(-cqe->result));
}
```

### 4.2 CLOSE（关闭文件）

```c
// 异步关闭文件
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_close(sqe, fd);

// ⚠️ 重要：close 是异步的！
// 关闭后不能立即用同一个 fd

// 错误做法：
io_uring_prep_close(sqe1, fd);
io_uring_prep_openat(sqe2, ..., "/tmp/new", ...);
// ⚠️ fd 可能还没关闭，新文件打开可能复用了 fd

// 正确做法：分两步
// 1. 提交 close
io_uring_prep_close(sqe1, fd);
sqe1->user_data = CLOSE_REQUEST_ID;
sqe1->flags = IOSQE_IO_DRAIN;  // 排空，确保之前的 I/O 完成

// 2. 等 close 完成后再 open
// 等收到 close 的 CQE 后再提交 open

// 或者：提前 open，事后 close
// 不需要等，close 和 open 是并行的
```

### 4.3 STATX（文件状态）

```c
// 异步获取文件元数据
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_STATX;
sqe->fd = AT_FDCWD;
sqe->addr = (unsigned long)"/tmp/test";
sqe->len = 0;
sqe->off = AT_STATX_SYNC_AS_STAT;  // 同步模式
sqe->rw_flags = 0;                 // mask（哪些字段）
// rw_flags 指定要获取的字段：
//   AT_STATX_SYNC_TYPE | AT_STATX_FORCE_SYNC
sqe->user_data = STATX_REQUEST_ID;

// 结果在 CQE result 中
// result 指向 struct statx（需要用户分配）
struct statx statx_buf;
io_uring_wait_cqe(&ring, &cqe);
if (cqe->result >= 0) {
    // 把 result 当指针用（内核写入 statx_buf）
    struct statx *stx = (struct statx *)cqe->user_data;  // 不对！
    // 实际上需要先注册 buffer
}
```

---

## 5. 同步与超时机制

### 5.1 NOP（空操作）

```c
// NOP = 空操作，用于测试或填充队列
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_NOP;
sqe->user_data = NOP_REQUEST_ID;
// CQE 立即返回，result = 0

// 应用：
//   - 测试 ring 是否可用
//   - 占位符（预留队列位置）
//   - 延迟注入（先提交 NOP，隔一段时间再提交真正的操作）
```

### 5.2 TIMEOUT（超时）

```c
// 异步超时（不绑定具体 I/O）
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_TIMEOUT;
sqe->addr = (unsigned long)&ts;   // struct __kernel_timespec
sqe->len = 1;                      // 1 个 timespec
// len=0 时 ts 被解释为绝对时间（CLOCK_MONOTONIC）
// len=1 时 ts 被解释为相对时间

struct __kernel_timespec ts;
ts.tv_sec = 1;       // 1 秒
ts.tv_nsec = 500000000; // +500ms = 1.5s

// 等价于：
//   clock_gettime(CLOCK_MONOTONIC, &ts);
//   ts.tv_sec += 1;
//   nanosleep(&ts, NULL);

// liburing 辅助
io_uring_prep_timeout(sqe, &ts, 0, 0);
// 第三个参数：count（等待多少个 CQE 才触发，0=立即）
// 第四个参数：flags

// 应用：
//   - 实现 I/O 超时
//   - 实现定期任务
//   - 实现心跳检测
```

### 5.3 LINK_TIMEOUT（链接超时）

```c
// 链接超时 = 给 SQE chain 设置超时
// 必须在 IOSQE_IO_LINK 链接中使用

// Step 1: 构造链接的 I/O
struct io_uring_sqe *sqe1 = io_uring_get_sqe(&ring);
io_uring_prep_connect(sqe1, sockfd, &addr, sizeof(addr));
sqe1->flags = IOSQE_IO_LINK;  // 链接

// Step 2: 构造链接超时（必须在链的最后一个）
struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
sqe2->opcode = IORING_OP_LINK_TIMEOUT;
sqe2->addr = (unsigned long)&ts;  // 超时时间
sqe2->len = 0;  // 0 = relative time, 1 = absolute time
// ts.tv_sec = 5;

// 完整示例：connect 超时
struct sockaddr_in addr;
addr.sin_family = AF_INET;
addr.sin_port = htons(80);
inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr);

struct io_uring_sqe *sqe1 = io_uring_get_sqe(&ring);
io_uring_prep_connect(sqe1, sockfd, &addr, sizeof(addr));
sqe1->flags = IOSQE_IO_LINK;
sqe1->user_data = CONNECT_REQUEST_ID;

struct __kernel_timespec ts = { .tv_sec = 3, .tv_nsec = 0 };
struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
io_uring_prep_link_timeout(sqe2, &ts, 0);
sqe2->flags = IOSQE_IO_LINK;  // 也是链接的一部分

io_uring_submit(&ring);
// 如果 3 秒内 connect 没完成 → 整个 chain 取消
```

### 5.4 绝对时间 vs 相对时间

```c
// timeout 的 flag 决定时间类型

// 相对时间（推荐，更直观）
struct __kernel_timespec ts = { .tv_sec = 5, .tv_nsec = 0 };
io_uring_prep_timeout(sqe, &ts, 0, 0);
// len = 0 → relative

// 绝对时间（CLOCK_MONTONIC）
struct __kernel_timespec ts_abs;
clock_gettime(CLOCK_MONOTONIC, &ts_abs);
ts_abs.tv_sec += 10;  // 10 秒后
io_uring_prep_timeout(sqe, &ts_abs, 0, IORING_TIMEOUT_ABS);
```

---

## 6. 网络 I/O 操作码（5.3+）

### 6.1 RECV（接收数据）

```c
// 异步 recv
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_RECV;
sqe->fd = sockfd;
sqe->addr = (unsigned long)buf;
sqe->len = 4096;
sqe->rw_flags = 0;  // MSG_* 标志

// rw_flags 支持：
sqe->rw_flags = MSG_PEEK;    // 窥探（不删除数据）
sqe->rw_flags = MSG_WAITALL; // 等待全部数据
sqe->rw_flags = MSG_DONTWAIT; // 非阻塞
sqe->rw_flags = MSG_ERRQUEUE; // 从错误队列接收

// liburing 辅助
io_uring_prep_recv(sqe, sockfd, buf, len, MSG_WAITALL);

// result = 读到的字节数
// result = 0 → 对端关闭
// result < 0 → 错误（-EINTR 等）
```

### 6.2 SEND（发送数据）

```c
// 异步 send
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_SEND;
sqe->fd = sockfd;
sqe->addr = (unsigned long)buf;
sqe->len = 4096;
sqe->rw_flags = 0;

// rw_flags 支持：
sqe->rw_flags = MSG_MORE;     // 后面还有数据（延迟发送）
sqe->rw_flags = MSG_EOR;     // 结束记录
sqe->rw_flags = MSG_DONTWAIT; // 非阻塞

// liburing 辅助
io_uring_prep_send(sqe, sockfd, buf, len, 0);

// result = 发送的字节数
```

### 6.3 RECVMSG / SENDMSG（带元数据的消息）

```c
// recvmsg = 接收带 control message 的数据
// 用于：ancillary data（文件描述符传递、IP_PKTINFO 等）

struct msghdr msg = {0};
msg.msg_name = &addr;       // 发送方地址
msg.msg_namelen = sizeof(addr);
msg.msg_iov = &iov;
msg.msg_iovlen = 1;
msg.msg_control = ctrl_buf;  // control message buffer
msg.msg_controllen = 256;
msg.msg_flags = 0;

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_RECVMSG;
sqe->fd = sockfd;
sqe->addr = (unsigned long)&msg;
sqe->len = 0;  // 0，对应 msg.msg_iov
sqe->rw_flags = 0;
sqe->user_data = RECVMSG_REQUEST_ID;

// sendmsg = 发送带 control message 的数据
io_uring_prep_sendmsg(sqe, sockfd, &msg, 0);
```

### 6.4 CONNECT（连接）

```c
// 异步 connect
struct sockaddr_in addr;
addr.sin_family = AF_INET;
addr.sin_port = htons(80);
inet_pton(AF_INET, "93.184.216.34", &addr.sin_addr);

int sockfd = socket(AF_INET, SOCK_STREAM, 0);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_CONNECT;
sqe->fd = sockfd;
sqe->addr = (unsigned long)&addr;
sqe->len = sizeof(addr);
sqe->user_data = CONNECT_REQUEST_ID;

// 注意：connect 是非阻塞的
// CQE 完成 ≠ 连接建立完成（TCP 三次握手还没完）
// 需要通过 getsockopt(SO_ERROR) 或 POLLOUT 判断

// 更好的方式：用 poll 等待连接完成
struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
sqe2->opcode = IORING_OP_POLL_ADD;
sqe2->fd = sockfd;
sqe2->poll_events = POLLOUT;  // 可写 = 连接建立
sqe2->flags = IOSQE_IO_LINK;
```

### 6.5 ACCEPT（接受连接）

```c
// 异步 accept
int listenfd = socket(AF_INET, SOCK_STREAM, 0);
bind(listenfd, ...);
listen(listenfd, 128);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_ACCEPT;
sqe->fd = listenfd;
sqe->addr = (unsigned long)&client_addr;  // 对方地址（输出）
sqe->len = sizeof(client_addr);
sqe->off = 0;  // SOCK_NONBLOCK（在 addrlen 高位）
sqe->user_data = ACCEPT_REQUEST_ID;

// off 字段可以用 OR 设置：
//   SOCK_NONBLOCK → 非阻塞 accept
//   SOCK_CLOEXEC  → close-on-exec

// CQE 返回：client fd（>=0）或错误（<0）
io_uring_wait_cqe(&ring, &cqe);
if (cqe->result >= 0) {
    int clientfd = cqe->result;
    printf("收到连接，client fd=%d\n", clientfd);
}
```

---

## 7. 轮询操作码

### 7.1 POLL_ADD（添加 poll fd）

```c
// POLL_ADD = 让 io_uring 帮你 poll 一个 fd
// 相当于 epoll_ctl(ADD) + epoll_wait

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_POLL_ADD;
sqe->fd = sockfd;
sqe->poll_events = POLLIN;  // EPOLLIN
sqe->user_data = POLL_REQUEST_ID;

// poll_events 支持：
sqe->poll_events = POLLIN;     // 可读
sqe->poll_events = POLLOUT;    // 可写
sqe->poll_events = POLLERR;    // 错误
sqe->poll_events = POLLHUP;    // 挂起
sqe->poll_events = POLLREMOVE; // 移除（POLL_UPDATE 时）

// 组合：
sqe->poll_events = POLLIN | POLLOUT;

// 触发时机：
//   POLLIN: fd 可读 / 收到连接 / 有错误
//   POLLOUT: fd 可写 / 连接建立
// CQE result = 触发的 events（实际发生的事件）
```

### 7.2 POLL_UPDATE（更新 poll 状态）

```c
// 更新已添加的 poll fd
// 相当于 epoll_ctl(MOD)

// 需要先有原始 poll_sqe 的地址（通过 user_data 关联）
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_POLL_UPDATE;
sqe->addr = (unsigned long)&update_args;  // struct io_uring_pollevent*
sqe->len = 1;
sqe->user_data = UPDATE_REQUEST_ID;
// addr 指向的参数包含：
//   - old_user_data：原始 poll sqe 的 user_data
//   - new_events：新事件
//   - new_user_data：新 user_data（可选）

// 应用：
//   - socket 状态变化时更新事件
//   - 避免 remove + add 的开销
```

### 7.3 EPOLL_CTL（epoll 控制，5.5+）

```c
// 直接用 io_uring 操作 epoll fd
// 等价于 epoll_ctl()

int epfd = epoll_create1(0);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_EPOLL_CTL;
sqe->fd = epfd;
sqe->addr = (unsigned long)&event);   // struct epoll_event*
sqe->len = op;                          // EPOLL_CTL_ADD/MOD/DEL
sqe->off = target_fd;                    // 要操作的 fd
sqe->user_data = EPOLL_REQUEST_ID;

// 实际用法：
struct epoll_event ev = {
    .events = EPOLLIN,
    .data.fd = sockfd,
};

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_EPOLL_CTL;
sqe->fd = epfd;
sqe->addr = (unsigned long)&ev;
sqe->len = EPOLL_CTL_ADD;  // ADD
sqe->off = sockfd;
```

---

## 8. 零拷贝数据移动

### 8.1 SPLICE（内核内部零拷贝）

```
SPLICE 原理：
  内核内部两个 fd 之间移动数据
  不经过用户空间 → 零拷贝

  ┌────────┐      ┌─────────┐      ┌────────┐
  │  fd1   │ DMA → │ kernel  │ DMA → │  fd2   │
  │(pipe/  │      │ buffer  |      │(pipe/  |
  │ file)  │      │         |      │ file)  │
  └────────┘      └─────────┘      └────────┘
                  无用户空间拷贝

限制：
  - 至少一端必须是 pipe
  - 文件到文件不能直接 splice（需要 pipe 中转）
  - 需要两边都支持 splice（不是所有设备都支持）
```

```c
// splice = 零拷贝数据移动
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_SPLICE;
sqe->fd_in = pipe_fd;      // 源（可以是 pipe 或 file）
sqe->off_in = 0;            // 源偏移（-1=自动）
sqe->fd = target_fd;        // 目标（可以是 pipe 或 file）
sqe->off = 0;              // 目标偏移（-1=自动）
sqe->len = 65536;           // 移动多少字节
sqe->splice_flags = SPLICE_F_MOVE;  // 尝试移动而不是复制页面

// splice_flags：
//   SPLICE_F_MOVE：移动页面（最佳，零拷贝）
//   SPLICE_F_NONBLOCK：非阻塞
//   SPLICE_F_MORE：后面还有更多
//   SPLICE_F_GIFT：gift 页面（谨慎使用）

// 应用：文件到 pipe、pipe 到 socket
```

### 8.2 TEE（管道复制）

```c
// tee = 复制 pipe 的数据到另一个 pipe（不消费原数据）
// 相当于 pipe + dup，但不丢原始数据

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_TEE;
sqe->fd_in = pipe1_fd;    // 源 pipe
sqe->off_in = 0;          // 必须 0
sqe->fd = pipe2_fd;       // 目标 pipe
sqe->off = 0;             // 必须 0
sqe->len = 65536;

// tee vs splice：
//   tee：复制，数据不丢失（源 pipe 仍有数据）
//   splice：移动，数据从源消失（进入目标）
```

---

## 9. Linked Chain（链接操作）

### 9.1 什么是 Linked Chain

```
Linked Chain = 多个 SQE 形成依赖链

原理：
  sqe1->flags = IOSQE_IO_LINK
  sqe2->flags = IOSQE_IO_LINK
  sqe3->flags = IOSQE_IO_DRAIN  // 最后一个用 DRAIN

执行顺序：
  sqe1 → sqe2 → sqe3 → (排空，所有前面完成)

如果链中某个 SQE 失败：
  - 默认行为：链中后续 SQE 被取消
  - 原因：环环相扣，一个错全链废

典型场景：
  1. open → read → close（文件 I/O 生命周期）
  2. write → fsync（写完立即同步）
  3. connect → poll → send（TCP 完整请求）
```

### 9.2 完整示例：文件读写生命周期

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <liburing.h>
#include <fcntl.h>
#include <unistd.h>

#define FILE_SIZE 1024

int main() {
    struct io_uring ring;
    io_uring_queue_init_params(32, &ring, &(struct io_uring_params){0});

    const char *path = "/tmp/io_uring_chain_test.txt";

    // Step 1: OPENAT
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_openat(sqe, AT_FDCWD, path,
                          O_RDWR | O_CREAT | O_TRUNC, 0644);
    sqe->flags = IOSQE_IO_LINK;  // 链接到下一步
    sqe->user_data = OPENAT_TAG;

    // Step 2: WRITE（依赖 open 完成）
    char *buf = malloc(FILE_SIZE);
    memset(buf, 'X', FILE_SIZE);
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_write(sqe, /*fd填0等CQE返回*/, buf, FILE_SIZE, 0);
    sqe->flags = IOSQE_IO_LINK;
    sqe->user_data = WRITE_TAG;

    // 问题：write 的 fd 是多少？
    // 答案：open 的 CQE result = fd
    // 我们需要在 open 完成后再提交 write
    // 所以实际代码要分两批

    // 正确做法：先 open，等结果，再 write，再 fsync，再 close

    // 第一批：OPEN
    io_uring_submit(&ring);
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);
    int fd = cqe->result;
    io_uring_cqe_seen(&ring, cqe);
    printf("文件打开，fd=%d\n", fd);

    // 第二批：WRITE
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_write(sqe, fd, buf, FILE_SIZE, 0);
    sqe->flags = IOSQE_IO_LINK;
    sqe->user_data = WRITE_TAG;

    // 第三批：FSYNC
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_fsync(sqe, fd, 0);
    sqe->flags = IOSQE_IO_DRAIN;  // 排空
    sqe->user_data = FSYNC_TAG;

    io_uring_submit(&ring);

    // 收割 WRITE + FSYNC
    io_uring_wait_cqe(&ring, &cqe);
    printf("WRITE: result=%d\n", cqe->result);
    io_uring_cqe_seen(&ring, cqe);

    io_uring_wait_cqe(&ring, &cqe);
    printf("FSYNC: result=%d\n", cqe->result);
    io_uring_cqe_seen(&ring, cqe);

    // 第四批：CLOSE
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_close(sqe, fd);
    io_uring_submit(&ring);
    io_uring_wait_cqe(&ring, &cqe);
    printf("CLOSE: result=%d\n", cqe->result);
    io_uring_cqe_seen(&ring, cqe);

    // 验证
    fd = open(path, O_RDONLY);
    memset(buf, 0, FILE_SIZE);
    read(fd, buf, FILE_SIZE);
    printf("验证：前10字节 = '%.*s'\n", 10, buf);
    close(fd);

    free(buf);
    io_uring_queue_exit(&ring);
    return 0;
}
```

### 9.3 链接超时实战

```c
// 场景：HTTP 请求超时控制

int sockfd = socket(AF_INET, SOCK_STREAM, 0);
fcntl(sockfd, F_SETFL, O_NONBLOCK);

struct sockaddr_in addr = {
    .sin_family = AF_INET,
    .sin_port = htons(80),
};
inet_pton(AF_INET, "93.184.216.34", &addr.sin_addr);

// 构造 HTTP GET 请求
const char *http_req =
    "GET / HTTP/1.1\r\n"
    "Host: example.com\r\n"
    "Connection: close\r\n"
    "\r\n";
int req_len = strlen(http_req);

// 1. CONNECT（带超时）
struct io_uring_sqe *sqe1 = io_uring_get_sqe(&ring);
io_uring_prep_connect(sqe1, sockfd, &addr, sizeof(addr));
sqe1->flags = IOSQE_IO_LINK;
sqe1->user_data = CONNECT_TAG;

// 超时（3秒）
struct __kernel_timespec ts = { .tv_sec = 3, .tv_nsec = 0 };
struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
io_uring_prep_link_timeout(sqe2, &ts, 0);
sqe2->flags = IOSQE_IO_LINK;  // 链接到 chain

io_uring_submit(&ring);

// 等待连接完成
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
printf("CONNECT CQE: user_data=%lu, result=%d\n",
       cqe->user_data, cqe->result);
io_uring_cqe_seen(&ring, &cqe);

// 2. SEND（连接成功后发请求）
char recv_buf[4096];
sqe = io_uring_get_sqe(&ring);
io_uring_prep_send(sqe, sockfd, (void*)http_req, req_len, 0);
sqe->user_data = SEND_TAG;
io_uring_submit(&ring);
io_uring_wait_cqe(&ring, &cqe);
printf("SEND CQE: result=%d\n", cqe->result);
io_uring_cqe_seen(&ring, &cqe);

// 3. RECV（接收响应）
sqe = io_uring_get_sqe(&ring);
io_uring_prep_recv(sqe, sockfd, recv_buf, sizeof(recv_buf), 0);
sqe->user_data = RECV_TAG;
io_uring_submit(&ring);

int total_recv = 0;
while (1) {
    io_uring_wait_cqe(&ring, &cqe);
    if (cqe->result <= 0) break;
    total_recv += cqe->result;
    io_uring_cqe_seen(&ring, &cqe);
}
printf("收到 %d 字节\n", total_recv);
```

---

## 10. CQE flags 与进阶用法

### 10.1 CQE flags 详解

```c
// CQE 的 flags 字段

IORING_CQE_F_BUFFER     (1 << 0)  // 用了固定 buffer（buf_select 时）
IORING_CQE_F_MORE      (1 << 1)  // 还有更多 CQE（在 multishot 中）
IORING_CQE_F_SOCK_NONBLOC (1 << 2) // socket 是 nonblocking 的

// 检查 flags
if (cqe->flags & IORING_CQE_F_BUFFER) {
    // 这个 CQE 使用了固定 buffer
    // cqe->flags >> 16 = buf_index
    int buf_index = cqe->flags >> 16;
    printf("使用了 buffer index %d\n", buf_index);
}
```

### 10.2 multishot（一次完成多个）

```c
// multishot = 一次注册，多次完成（用于 accept/poll）

// 普通 accept：
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_accept(sqe, listenfd, &client_addr, &addrlen, 0);
// 每次连接只触发一次 CQE

// multishot accept（5.11+）：
sqe = io_uring_get_sqe(&ring);
io_uring_prep_multishot_accept(sqe, listenfd, &client_addr, &addrlen, 0);
// 第一次 CQE 之后自动继续 accept
// 后续连接会持续产生 CQE，直到你取消或关闭 listenfd

// multishot poll（5.6+）：
sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_POLL_ADD;
sqe->fd = sockfd;
sqe->poll_events = POLLIN;
io_uring_prep_poll_multishot(sqe, POLLIN);
// POLLIN 有数据时，持续产生 CQE
```

### 10.3 IOSQE_BUFFER_SELECT（自动选择 buffer）

```c
// buffer select = 从 buffer group 自动选择可用 buffer

// Step 1: 注册 buffer group（多个 buffer）
struct iovec iovs[16];
for (int i = 0; i < 16; i++) {
    posix_memalign(&iovs[i].iov_base, 4096, 4096);
    iovs[i].iov_len = 4096;
}
io_uring_register_buffers_group(&ring, iovs, 16, &group_id);

// Step 2: 使用 IOSQE_BUFFER_SELECT
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_READ;
sqe->fd = fd;
sqe->addr = 0;  // 内核自动填充
sqe->len = 4096;
sqe->off = 0;
sqe->flags = IOSQE_BUFFER_SELECT;
sqe->buf_group = group_id;  // buffer group ID
sqe->user_data = READ_TAG;

// CQE 中：
// result = 读到的字节数
// flags >> 16 = buf_index（用了哪个 buffer）
int buf_index = cqe->flags >> 16;
printf("用了 buffer %d\n", buf_index);
```

---

## 11. 完整实战：高性能 HTTP 服务器

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <liburing.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define PORT        8080
#define QUEUE_DEPTH 256
#define BUF_SIZE    4096
#define NUM_FILES   8

struct request_ctx {
    int client_fd;
    int file_fd;
    char buf[BUF_SIZE];
    int stage;  // 0=accepting, 1=reading, 2=writing, 3=closing
};

struct io_uring ring;
struct request_ctx ctxs[QUEUE_DEPTH];

int create_listen_socket() {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(PORT),
        .sin_addr.s_addr = INADDR_ANY,
    };
    bind(fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(fd, 128);
    return fd;
}

void handle_cqe(struct io_uring_cqe *cqe) {
    struct request_ctx *ctx = (void*)cqe->user_data;

    if (cqe->result < 0) {
        fprintf(stderr, "错误: %s\n", strerror(-cqe->result));
        if (ctx->client_fd >= 0) close(ctx->client_fd);
        ctx->stage = 0;
        return;
    }

    switch (ctx->stage) {
    case 0:  // accept 阶段
        ctx->client_fd = cqe->result;
        printf("新连接，fd=%d\n", ctx->client_fd);
        // 提交读请求
        {
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
            io_uring_prep_recv(sqe, ctx->client_fd, ctx->buf,
                               BUF_SIZE, 0);
            sqe->user_data = (unsigned long)ctx;
            io_uring_submit(&ring);
        }
        ctx->stage = 1;
        break;

    case 1:  // read 阶段
        if (cqe->result == 0) {
            // 对端关闭
            close(ctx->client_fd);
            ctx->stage = 0;
        } else {
            printf("收到 %d 字节\n", cqe->result);
            // 简单处理：返回 "HTTP/1.1 200 OK\r\n\r\n"
            const char *resp =
                "HTTP/1.1 200 OK\r\n"
                "Content-Length: 13\r\n"
                "Connection: close\r\n"
                "\r\n"
                "Hello, world!";
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
            io_uring_prep_send(sqe, ctx->client_fd, resp, strlen(resp), 0);
            sqe->user_data = (unsigned long)ctx;
            io_uring_submit(&ring);
            ctx->stage = 2;
        }
        break;

    case 2:  // write 阶段
        // 发送完成，关闭
        close(ctx->client_fd);
        ctx->stage = 0;
        break;
    }
}

int main() {
    int listenfd = create_listen_socket();

    struct io_uring_params params = {
        .flags = IORING_SETUP_SQPOLL,
        .sq_thread_idle = 1000,
    };
    io_uring_queue_init_params(QUEUE_DEPTH, &ring, &params);

    // 初始化 ctx 池
    for (int i = 0; i < QUEUE_DEPTH; i++) {
        ctxs[i].stage = 0;
        ctxs[i].client_fd = -1;
        ctxs[i].file_fd = -1;
    }

    // 初始：提交 NUM_FILES 个 accept
    for (int i = 0; i < NUM_FILES; i++) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
        io_uring_prep_accept(sqe, listenfd, NULL, NULL, 0);
        sqe->user_data = (unsigned long)&ctxs[i % QUEUE_DEPTH];
        ctxs[i % QUEUE_DEPTH].stage = 0;
        ctxs[i % QUEUE_DEPTH].client_fd = -1;
    }
    io_uring_submit(&ring);

    printf("HTTP 服务器启动，监听端口 %d\n", PORT);

    // 主循环
    while (1) {
        struct io_uring_cqe *cqe;
        int ret = io_uring_wait_cqe(&ring, &cqe);
        if (ret < 0) continue;

        handle_cqe(cqe);
        io_uring_cqe_seen(&ring, cqe);
    }

    io_uring_queue_exit(&ring);
    close(listenfd);
    return 0;
}
```

---

## 12. 小结

```
SQE 核心字段：
  opcode      — 做什么（read/write/connect/accept...）
  fd          — 文件描述符（或 fixed fd 索引）
  addr        — 缓冲区地址（或 iovec 数组）
  len         — 长度（或 iovec 数量）
  off         — 偏移量（文件/Socket）
  flags       — IOSQE_*（LINK/DRAIN/FIXED_FILE/BUFFER_SELECT）
  user_data   — 配对标识

CQE 核心字段：
  user_data   — 来自 SQE
  result      — 操作结果（字节数或错误码）
  flags       — IORING_CQE_F_*（buffer/multishot）

SQE flags：
  IOSQE_IO_LINK      — 链接下一个 SQE
  IOSQE_IO_DRAIN     — 排空（等前面都完）
  IOSQE_FIXED_FILE   — fd 是 fixed fd 索引
  IOSQE_ASYNC        — 允许并行执行
  IOSQE_BUFFER_SELECT — 从 buffer group 选

链式操作：
  LINK 链接：保证顺序（上一个完才下一个）
  DRAIN 排空：等所有前面的 SQE 完再执行
  超时：LINK_TIMEOUT 给链加时间限制

网络操作（5.3+）：
  RECV/SEND/RECVMSG/SENDMSG/CONNECT/ACCEPT
  需要 SOCK_STREAM（SOCK_NONBLOCK）
  POLL_ADD/POLL_UPDATE 等待事件
```

---

## 延伸阅读

- `linux/io_uring.h` — 完整类型定义
- `liburing` 源码: `src/setup.c`, `src/syscall.c`
- `man io_uring_enter` — 核心系统调用
- LWN: "io_uring poll and accept" (5.11): https://lwn.net/Articles/854908/
- LWN: "io_uring and timeouts": https://lwn.net/Articles/810071/
- Kernel: `fs/io_uring/rw.c`, `fs/io_uring/sysmsg.c`, `fs/io_uring/net.c`