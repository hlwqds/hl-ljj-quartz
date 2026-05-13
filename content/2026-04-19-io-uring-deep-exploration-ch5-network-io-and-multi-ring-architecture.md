---
title: io_uring 深度探索 Ch5：网络 I/O 与多 ring 架构
date: 2026-04-19 10:00:00
tags: [io_uring, Linux, Network IO, Zero Copy, Multi Ring, epoll, High Performance, TCP, UDP, Connection Pool]
description: 深入讲解 io_uring 网络 I/O：recv/send/accept 深度调优、SO_ZEROCOPY 零拷贝、multishot accept 高并发、per-CPU 多 ring 架构、epoll vs io_uring 对比，以及高性能网络服务器设计。
---

# io_uring 深度探索 Ch5：网络 I/O 与多 ring 架构

## 1. io_uring 网络 I/O 模型

### 1.1 与传统 epoll 的本质区别

```
传统 epoll 模型（同步阻塞）：
┌──────────────────────────────────────────┐
│  线程池                                  │
│  while (1) {                             │
│    epoll_wait(...);  // 阻塞等事件       │
│    for (fd : ready_fds) {                │
│      read/write(fd);  // 同步系统调用     │
│      // 如果数据没准备好，再次阻塞        │
│    }                                     │
│  }                                       │
│                                          │
│  问题：每个连接一个线程 或 事件循环      │
│       连接数多时 → 线程/调度开销大       │
└──────────────────────────────────────────┘

io_uring 模型（真正异步）：
┌──────────────────────────────────────────┐
│  单线程/少量线程                          │
│  while (1) {                             │
│    // 提交一堆 I/O                         │
│    sqe = get_sqe(); read(sqe, fd, ...); │
│    sqe = get_sqe(); write(sqe, fd, ...);│
│    submit();  // 批量提交到内核          │
│                                          │
│    // 收割结果                            │
│    while (cqe = wait_cqe()) {           │
│      process(cqe);  // 真正异步完成       │
│    }                                     │
│  }                                       │
│                                          │
│  优势：                                   │
│  - 内核内部多路复用（比 epoll 更底层）   │
│  - 零拷贝注册内存                        │
│  - 批量提交减少 syscall                  │
└──────────────────────────────────────────┘
```

### 1.2 网络 I/O 操作码全览

```c
// 5.1+ 操作码
IORING_OP_RECV          // 接收数据
IORING_OP_SEND          // 发送数据

// 5.3+ 操作码（更完整的网络支持）
IORING_OP_RECVMSG       // 带 control message 的接收
IORING_OP_SENDMSG       // 带 control message 的发送
IORING_OP_CONNECT       // 发起连接
IORING_OP_ACCEPT        // 接受连接

// 5.5+ 操作码
IORING_OP_EPOLL_CTL     // 直接操作 epoll fd

// 5.19+ 操作码
IORING_OP_SEND_ZEROCOPY // 零拷贝发送（需要 SO_ZEROCOPY）
```

---

## 2. RECV / SEND 深度调优

### 2.1 recv 详解

```c
// 基本 recv
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_RECV;
sqe->fd = sockfd;
sqe->addr = (unsigned long)buf;
sqe->len = 4096;
sqe->rw_flags = 0;  // MSG_* 标志

// MSG_* 标志
sqe->rw_flags = MSG_PEEK;      // 窥探（不删除数据）
sqe->rw_flags = MSG_WAITALL;   // 等待全部数据（len 字节）
sqe->rw_flags = MSG_DONTWAIT;  // 非阻塞（O_NONBLOCK）
sqe->rw_flags = MSG_TRUNC;     // 数据被截断也返回
sqe->rw_flags = MSG_CTRUNC;    // control message 被截断

// 等价 liburing 辅助
io_uring_prep_recv(sqe, sockfd, buf, 4096, MSG_WAITALL);

// CQE result：
//   > 0：收到字节数
//   = 0：对端关闭连接（EOF）
//   < 0：错误码（-EINTR, -EAGAIN 等）

// 与 recv(2) 的区别：
// - io_uring 的 recv 是异步的（不阻塞线程）
// - 可以同时提交多个 recv 到同一个 fd
```

### 2.2 recv 多缓冲接收（buffer selection）

```c
// 问题：不同请求需要不同大小的 buffer
// 解决：buffer selection — 内核自动选择合适 buffer

#define NUM_BUFFERS 4

struct iovec iovs[NUM_BUFFERS];
for (int i = 0; i < NUM_BUFFERS; i++) {
    posix_memalign(&iovs[i].iov_base, 4096, 4096);
    iovs[i].iov_len = 4096;
}
io_uring_register_buffers(&ring, iovs, NUM_BUFFERS);

// 注册 buffer group
io_uring_register_buffers_group(&ring, iovs, NUM_BUFFERS, &group_id);

// 使用 IOSQE_BUFFER_SELECT
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_RECV;
sqe->fd = sockfd;
sqe->addr = 0;  // 内核填充
sqe->len = 4096;  // 最大接收长度
sqe->flags = IOSQE_BUFFER_SELECT;
sqe->buf_group = group_id;
sqe->user_data = RECV_TAG;

// CQE 中获取 buffer index
// cqe->flags >> 16 = buf_index
int buf_index = cqe->flags >> 16;
printf("数据在 buffer %d, 长度 %d\n", buf_index, cqe->result);
```

### 2.3 send 详解

```c
// 基本 send
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_SEND;
sqe->fd = sockfd;
sqe->addr = (unsigned long)buf;
sqe->len = 4096;
sqe->rw_flags = 0;

// MSG_* 标志
sqe->rw_flags = MSG_MORE;     // 后面还有数据（延迟发送，攒 batch）
sqe->rw_flags = MSG_EOR;     // 结束记录
sqe->rw_flags = MSG_DONTWAIT; // 非阻塞

// liburing 辅助
io_uring_prep_send(sqe, sockfd, buf, 4096, MSG_MORE);

// CQE result：
//   > 0：发送字节数
//   < 0：错误码

// 注意：send 成功不代表数据到达对端
// 只是数据放入 TCP send buffer
// 要确认对端收到 → 需要应用层 ACK 或 close 检测
```

### 2.4 MSG_MORE 批量发送优化

```c
// MSG_MORE：告诉内核后面还有数据，延迟发送

// 场景：HTTP 响应，分多个部分发送
const char *header =
    "HTTP/1.1 200 OK\r\n"
    "Content-Length: 12345\r\n"
    "\r\n";

const char *body_start = "...";  // 很大的 body

// 第一块：带 MSG_MORE
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_send(sqe, sockfd, header, strlen(header), MSG_MORE);
sqe->user_data = SEND_HDR_TAG;
io_uring_submit(&ring);

// 第二块：不带 MSG_MORE（触发真正发送）
sqe = io_uring_get_sqe(&ring);
io_uring_prep_send(sqe, sockfd, body_start, body_len, 0);
sqe->user_data = SEND_BODY_TAG;
io_uring_submit(&ring);

// 效果：减少 TCP 小包（Nagle 算法优化）
// 等第一块积累后一起发 → 减少包数量
```

---

## 3. ACCEPT 与高并发连接

### 3.1 普通 accept 模式

```c
// 普通 accept（非 multishot）
int listenfd = socket(AF_INET, SOCK_STREAM, 0);
setsockopt(listenfd, SOL_SOCKET, SO_REUSEPORT, ...);
bind(listenfd, ...);
listen(listenfd, 128);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_accept(sqe, listenfd,
                     &client_addr, &addrlen,
                     SOCK_NONBLOCK);
sqe->user_data = ACCEPT_TAG;
io_uring_submit(&ring);

// CQE result = client fd（或错误）
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
if (cqe->result >= 0) {
    int client = cqe->result;
    printf("新连接，fd=%d\n", client);
}
io_uring_cqe_seen(&ring, cqe);

// 问题：每次只能 accept 一个连接
// 要并发 → 需要多次提交 accept SQE
```

### 3.2 multishot accept（5.11+）

```c
// multishot accept = 一次注册，持续 accept

// 提交一次，多个 CQE
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_multishot_accept(sqe, listenfd,
                                NULL, NULL,
                                SOCK_NONBLOCK);
sqe->user_data = ACCEPT_TAG;
io_uring_submit(&ring);

// 之后每个新连接都会产生 CQE
while (1) {
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);

    if (cqe->result >= 0) {
        int client = cqe->result;
        // 处理新连接
        handle_connection(client);
    } else {
        // 错误（通常是 EAGAIN = 暂时没连接）
        // 继续等待下一个 CQE
    }
    io_uring_cqe_seen(&ring, cqe);
}

// 对比：
// 普通 accept：10000 连接 = 10000 次 SQE 提交
// multishot accept：10000 连接 = 1 次 SQE 提交
// → 大幅减少 accept 的 syscall 开销
```

### 3.3 accept 后立即注册 fixed fd

```c
// 高性能场景：accept 后立即注册到 fixed table

#define MAX_CLIENTS 8192

// 预先注册 fd 数组
int client_fds[MAX_CLIENTS];
for (int i = 0; i < MAX_CLIENTS; i++) client_fds[i] = -1;

// 批量 accept
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_multishot_accept(sqe, listenfd, NULL, NULL, 0);
sqe->user_data = ACCEPT_TAG;
io_uring_submit(&ring);

int next_idx = 0;
while (1) {
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);

    if (cqe->result >= 0) {
        int client = cqe->result;

        // 立即注册为 fixed fd（零查找开销）
        io_uring_register_files_sparse(&ring, &client, 1, next_idx);
        // 但 liburing 不直接支持单 fd 注册...
        // 实际做法：提前分配 fixed fd 表

        // 分配 fixed fd
        int fixed_idx = next_idx++;
        // 注意：io_uring_register_files() 需要预先分配好
        // 所以一般提前分配整个数组

        // 后续 I/O 用 fixed_idx：
        sqe = io_uring_get_sqe(&ring);
        sqe->opcode = IORING_OP_RECV;
        sqe->fd = fixed_idx;  // fixed fd
        sqe->addr = (unsigned long)buf;
        sqe->len = 4096;
        sqe->flags = IOSQE_FIXED_FILE;
        sqe->user_data = RECV_TAG;
    }
}
```

---

## 4. CONNECT 与长连接

### 4.1 异步 connect

```c
// 异步 connect（不阻塞线程）
struct sockaddr_in addr = {
    .sin_family = AF_INET,
    .sin_port = htons(80),
    .sin_addr.s_addr = inet_addr("93.184.216.34"),
};
int sockfd = socket(AF_INET, SOCK_STREAM, 0);
fcntl(sockfd, F_SETFL, O_NONBLOCK);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_connect(sqe, sockfd, &addr, sizeof(addr));
sqe->user_data = CONNECT_TAG;
io_uring_submit(&ring);

// CQE result = 0（成功）或错误码
// 注意：对于非阻塞 socket：
// - result = -EINPROGRESS 表示正在建立连接
// - 需要用 poll 检测连接是否真正建立

struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
if (cqe->result == -EINPROGRESS) {
    printf("正在连接...\n");
    // 需要 poll POLLOUT 确认
    struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
    sqe2->opcode = IORING_OP_POLL_ADD;
    sqe2->fd = sockfd;
    sqe2->poll_events = POLLOUT;
    sqe2->flags = IOSQE_IO_LINK;  // 链接到原 connect
    sqe2->user_data = POLL_TAG;
    io_uring_submit(&ring);
}
```

### 4.2 连接超时控制

```c
// 给 connect 加超时（用 link timeout）
struct sockaddr_in addr = { ... };
int sockfd = socket(AF_INET, SOCK_STREAM, 0);
fcntl(sockfd, F_SETFL, O_NONBLOCK);

struct io_uring_sqe *sqe1 = io_uring_get_sqe(&ring);
io_uring_prep_connect(sqe1, sockfd, &addr, sizeof(addr));
sqe1->flags = IOSQE_IO_LINK;
sqe1->user_data = CONNECT_TAG;

// 超时 SQE（必须在链的最后）
struct __kernel_timespec ts = { .tv_sec = 3, .tv_nsec = 0 };
struct io_uring_sqe *sqe2 = io_uring_get_sqe(&ring);
io_uring_prep_link_timeout(sqe2, &ts, 0);
sqe2->flags = IOSQE_IO_LINK;
sqe2->user_data = TIMEOUT_TAG;

io_uring_submit(&ring);

// 收割
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
printf("user_data=%lu, result=%d\n", cqe->user_data, cqe->result);
io_uring_cqe_seen(&ring, cqe);

io_uring_wait_cqe(&ring, &cqe);
printf("user_data=%lu, result=%d\n", cqe->user_data, cqe->result);
io_uring_cqe_seen(&ring, cqe);

// 超时情况：
// - TIMEOUT CQE 先到达 → connect 被取消
// - CONNECT CQE 可能也到达（如果连接刚好建立）
// - 需要检测 connect 是否真的失败了
```

### 4.3 连接池设计

```c
// 高性能 HTTP 客户端：连接池

#define POOL_SIZE 16
#define MAX_PENDING 256

struct connection {
    int fd;
    int in_use;         // 是否正在使用
    int registered;     // 是否注册到 io_uring
    struct io_uring *ring;  // 关联的 ring
};

// 每个连接一个 ring（per-connection ring）
struct connection_pool {
    struct connection conns[POOL_SIZE];
    struct io_uring rings[POOL_SIZE];
    int num_active;
};

int init_pool(struct connection_pool *pool) {
    for (int i = 0; i < POOL_SIZE; i++) {
        pool->conns[i].fd = -1;
        pool->conns[i].in_use = 0;
        io_uring_queue_init_params(32, &pool->rings[i], &params);
        pool->conns[i].ring = &pool->rings[i];
    }
}

// 获取可用连接
struct connection* get_conn(struct connection_pool *pool) {
    for (int i = 0; i < POOL_SIZE; i++) {
        if (!pool->conns[i].in_use) {
            pool->conns[i].in_use = 1;
            return &pool->conns[i];
        }
    }
    return NULL;  // 池满
}

// 释放连接回池
void release_conn(struct connection *conn) {
    // 不关闭，只是标记为可用
    conn->in_use = 0;
}
```

---

## 5. SO_ZEROCOPY 零拷贝发送

### 5.1 什么是 SO_ZEROCOPY

```
传统 send() 流程（2次拷贝）：
┌─────────────────────────────────────────┐
│  用户空间                               │
│    buf → skb->data (copy 1)            │
│                                         │
│  内核空间                               │
│    skb → NIC DMA 描述符 (copy 2)       │
│    NIC → 网络                          │
└─────────────────────────────────────────┘

SO_ZEROCOPY 流程（0次拷贝）：
┌─────────────────────────────────────────┐
│  用户空间                               │
│    buf → 直接映射到 DMA 描述符          │
│                                         │
│  内核空间                               │
│    DMA 描述符 → NIC                    │
│    NIC → 网络                          │
│                                         │
│  通知机制：                             │
│    - 对端 ACK 后，内核通知用户          │
│    - SO_ZEROCOPY 回调 或 poll MSG_ZEROCOPY │
└─────────────────────────────────────────┘

限制：
- 仅限 send，不支持 recv
- 必须是 TCP（不支持 UDP）
- 需要网卡支持（大多数现代 NIC 支持）
- buffer 必须对齐（通常是 4KB 或 page aligned）
```

### 5.2 启用 SO_ZEROCOPY

```c
// 服务器端：设置 socket 选项
int sockfd = socket(AF_INET, SOCK_STREAM, 0);

// 启用接收端零拷贝通知
int val = 1;
setsockopt(sockfd, SOL_SOCKET, SO_ZEROCOPY, &val, sizeof(val));

// 客户端也可以设置
setsockopt(sockfd, SOL_SOCKET, SO_ZEROCOPY, &val, sizeof(val));

// 检查是否支持
int get_val;
socklen_t len = sizeof(get_val);
getsockopt(sockfd, SOL_SOCKET, SO_ZEROCOPY, &get_val, &len);
printf("支持零拷贝: %d\n", get_val);

// 注意：getsockopt 可能返回 0（不支持）
// 某些网卡可能部分支持
```

### 5.3 使用 IORING_OP_SEND_ZEROCOPY（5.19+）

```c
// 5.19+ 支持专门的零拷贝发送操作码

// 前提：socket 已设置 SO_ZEROCOPY
int sockfd = socket(AF_INET, SOCK_STREAM, 0);
int val = 1;
setsockopt(sockfd, SOL_SOCKET, SO_ZEROCOPY, &val, sizeof(val));

// 缓冲区必须对齐（page aligned）
void *buf;
posix_memalign(&buf, 4096, 65536);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_SEND_ZEROCOPY;
sqe->fd = sockfd;
sqe->addr = (unsigned long)buf;
sqe->len = 65536;
sqe->user_data = SEND_ZC_TAG;
sqe->flags = IOSQE_FIXED_FILE;  // 推荐用 fixed fd
io_uring_submit(&ring);

// CQE result：
//   > 0：发送成功
//   < 0：错误码
// 注意：CQE 完成 ≠ 数据到达对端！
// 只是数据放入 TCP send buffer

// 零拷贝完成通知：
// 需要用 recv 的 MSG_ZEROCOPY 标志接收通知
// 或者：通过 poll 等待零拷贝完成事件
```

### 5.4 零拷贝完成通知机制

```c
// 零拷贝完成通知：需要接收对端的 ACK

// 方式 1：使用 poll 接收通知
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_POLL_ADD;
sqe->fd = sockfd;
sqe->poll_events = POLLERR;  // 零拷贝完成会触发 POLLERR
// 不准确，5.19+ 有更好的方式

// 方式 2：使用 recv 的 MSG_ZEROCOPY（但这是接收端用的）

// 方式 3：设置 SO_ZEROCOPY 后，内核会自动处理
// 数据发送后，TCP 层收到 ACK → 内核释放 skb → 用户可重用 buffer
// 应用程序通过 select/poll 的异常事件得到通知

// 实际应用中：
// - 零拷贝发送是"发射后不管"
// - 如果需要确认对端收到 → 应用层 ACK 协议
// - 大文件传输：分块发送，每块收到 ACK 后再发下一块
```

---

## 6. UDP 支持

### 6.1 UDP send/recv

```c
// UDP 也支持 RECV/SEND
int udpfd = socket(AF_INET, SOCK_DGRAM, 0);
bind(udpfd, (struct sockaddr*)&addr, sizeof(addr));

// UDP recv
char buf[65536];
struct sockaddr_in src;
socklen_t src_len = sizeof(src);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_RECV;
sqe->fd = udpfd;
sqe->addr = (unsigned long)buf;
sqe->len = sizeof(buf);
sqe->off = (unsigned long)&src;  // recvmsg 用 addr2 存地址
sqe->rw_flags = 0;
sqe->user_data = UDP_RECV_TAG;
io_uring_submit(&ring);

// 或者用 RECVMSG（获取完整信息）
struct msghdr msg = {0};
msg.msg_name = &src;
msg.msg_namelen = sizeof(src);
msg.msg_iov = &iov;
msg.msg_iovlen = 1;

sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_RECVMSG;
sqe->fd = udpfd;
sqe->addr = (unsigned long)&msg;
sqe->len = 0;
sqe->user_data = UDP_RECVMSG_TAG;
io_uring_submit(&ring);

// UDP send
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_SEND;
sqe->fd = udpfd;
sqe->addr = (unsigned long)buf;
sqe->len = 1024;
sqe->off = (unsigned long)&dest_addr;  // sendmsg 用 addr2 存地址
sqe->user_data = UDP_SEND_TAG;
io_uring_submit(&ring);
```

### 6.2 UDP multicast

```c
// UDP 多播
int mcastfd = socket(AF_INET, SOCK_DGRAM, 0);

// 加入多播组
struct ip_mreq mreq = {
    .imr_multiaddr.s_addr = inet_addr("239.0.0.1"),
    .imr_interface.s_addr = INADDR_ANY,
};
setsockopt(mcastfd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq));

// 设置 reuse
int opt = 1;
setsockopt(mcastfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
bind(mcastfd, ...);

// 接收多播数据
char buf[65536];
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_recv(sqe, mcastfd, buf, sizeof(buf), 0);
sqe->user_data = MCAST_TAG;
io_uring_submit(&ring);

// 多播发送
struct sockaddr_in mcast_addr = {
    .sin_family = AF_INET,
    .sin_port = htons(9999),
    .sin_addr.s_addr = inet_addr("239.0.0.1"),
};
sqe = io_uring_get_sqe(&ring);
sqe->opcode = IORING_OP_SEND;
sqe->fd = mcastfd;
sqe->addr = (unsigned long)send_buf;
sqe->len = send_len;
sqe->off = (unsigned long)&mcast_addr;
sqe->user_data = MCAST_SEND_TAG;
io_uring_submit(&ring);
```

---

## 7. 多 ring 架构（per-CPU / per-Connection）

### 7.1 为什么需要多 ring

```
单 ring 的问题：
  - 多线程共享同一个 ring → 竞争（lock）
  - 单核处理所有 I/O → 无法利用多核
  - 队列深度有限 → 吞吐瓶颈

多 ring 方案：
  - 每个线程独立 ring → 无锁
  - 每个 CPU 独立 ring → 充分利用多核
  - 连接分散到多个 ring → 水平扩展

方案对比：

1. per-CPU ring：
   - 每个 CPU 一个 ring
   - 所有连接分散到所有 ring
   - 适合：短连接、高并发、CPU 密集

2. per-Connection ring：
   - 每个连接一个 ring
   - 连接绑定到某个 ring
   - 适合：长连接、复杂协议、会话一致
```

### 7.2 per-CPU ring 实现

```c
// per-CPU ring：每个 CPU 核心一个 ring

#define NUM_CPU 8

struct per_cpu_ring {
    struct io_uring ring;
    int ring_fd;
} rings[NUM_CPU];

int init_per_cpu_rings() {
    for (int i = 0; i < NUM_CPU; i++) {
        struct io_uring_params params = {
            .flags = IORING_SETUP_SQPOLL,
            .sq_thread_cpu = i,      // 绑定到 CPU i
            .sq_thread_idle = 2000,
        };
        if (io_uring_queue_init_params(256, &rings[i].ring, &params) < 0) {
            perror("queue_init");
            return -1;
        }
        rings[i].ring_fd = rings[i].ring.ring_fd;
    }
    return 0;
}

// 发送请求到哪个 ring？（根据连接选择）
struct per_cpu_ring* get_ring_for_fd(int fd) {
    // 根据 fd 哈希到 CPU
    int cpu = fd % NUM_CPU;
    return &rings[cpu];
}

// 处理连接
void handle_connection(int fd) {
    struct per_cpu_ring *pr = get_ring_for_fd(fd);

    // 提交 recv
    struct io_uring_sqe *sqe = io_uring_get_sqe(&pr->ring);
    io_uring_prep_recv(sqe, fd, buf, 4096, 0);
    sqe->user_data = (uint64_t)fd;
    io_uring_submit(&pr->ring);

    // 收割也在同一个 ring
}

// 主线程：监控所有 ring
void poll_all_rings() {
    for (int i = 0; i < NUM_CPU; i++) {
        struct io_uring_cqe *cqe;
        while (io_uring_peek_cqe(&rings[i].ring, &cqe) == 0) {
            process_cqe(cqe);
            io_uring_cqe_seen(&rings[i].ring, cqe);
        }
    }
}
```

### 7.3 per-Connection ring 实现

```c
// per-connection ring：每个连接一个独立 ring
// 适合复杂协议（HTTP/2, gRPC, WebSocket）

struct conn_ctx {
    int fd;
    struct io_uring ring;  // 这个连接专用的 ring
    int state;             // 连接状态机
    uint8_t stage;         // 协议解析阶段
};

// 每个连接创建时初始化 ring
struct conn_ctx* create_connection(int fd) {
    struct conn_ctx *ctx = malloc(sizeof(*ctx));
    ctx->fd = fd;
    ctx->state = STATE_CONNECTED;

    struct io_uring_params params = {
        .flags = IORING_SETUP_SQPOLL,
        .sq_thread_idle = 1000,
    };
    io_uring_queue_init_params(32, &ctx->ring, &params);

    // 预先提交 recv（持续接收）
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ctx->ring);
    io_uring_prep_recv(sqe, fd, ctx->recv_buf, sizeof(ctx->recv_buf), 0);
    sqe->user_data = RECV_TAG;
    io_uring_submit(&ctx->ring);

    return ctx;
}

// 连接的事件循环
void conn_loop(struct conn_ctx *ctx) {
    while (ctx->state != STATE_CLOSED) {
        struct io_uring_cqe *cqe;
        io_uring_wait_cqe(&ctx->ring, &cqe);

        switch (cqe->user_data) {
        case RECV_TAG:
            handle_recv(ctx, cqe->result);
            // 重新提交 recv
            if (ctx->state != STATE_CLOSED) {
                struct io_uring_sqe *sqe = io_uring_get_sqe(&ctx->ring);
                io_uring_prep_recv(sqe, ctx->fd, ctx->recv_buf,
                                   sizeof(ctx->recv_buf), 0);
                sqe->user_data = RECV_TAG;
                io_uring_submit(&ctx->ring);
            }
            break;
        case SEND_TAG:
            // 发送完成
            ctx->pending_send = 0;
            check_pending_data(ctx);
            break;
        }
        io_uring_cqe_seen(&ctx->ring, cqe);
    }
}
```

### 7.4 跨 ring 通信

```c
// 问题：per-CPU ring 之间如何通信？
// 比如：请求路由（CPU A 收到请求，处理需要 CPU B 的数据）

// 方案 1：消息队列
//   CPU A 发送消息到 CPU B 的队列
//   CPU B 轮询自己的消息队列

// 方案 2：共享内存 + 原子操作
//   用 atomic 变量做 flag
//   CPU B 轮询 flag

// 方案 3：pipe
//   用 pipe 跨 ring 传递数据

// 实际案例：RPC 请求处理
struct rpc_request {
    int target_cpu;      // 目标 CPU
    uint64_t request_id;
    char data[];
};

struct io_uring_sqe* get_sqe_from_ring(int cpu) {
    return io_uring_get_sqe(&rings[cpu].ring);
}

// CPU A：发送请求到 CPU B 的 ring
void send_to_cpu(int target_cpu, struct rpc_request *req) {
    struct io_uring_sqe *sqe = get_sqe_from_ring(target_cpu);
    io_uring_prep_write(sqe, pipe_fds[target_cpu][1],
                        req, sizeof(*req) + req->data_len, 0);
    sqe->user_data = REQ_TAG;
    io_uring_submit(&rings[target_cpu].ring);
}
```

---

## 8. epoll vs io_uring 对比

### 8.1 功能对比

```
功能              epoll            io_uring
─────────────────────────────────────────────────
监控事件          ✓               ✓ (POLL_ADD)
阻塞等待          ✓               ✓ (wait_cqe)
非阻塞            ✓               ✓
水平触发          ✓               ✓
边缘触发          ✓               ✗（io_uring 总是水平触发）
单 fd 多事件      ✓               ✓
批量等待          ✗               ✓ (wait_cqe 一次拿多个)

文件 I/O          ✗               ✓
网络 I/O          ✓               ✓
异步 accept       ✗               ✓ (multishot)
异步 connect      ✗               ✓
异步 read/write   ✗               ✓
异步 fsync        ✗               ✓
超时机制          ✓ (timerfd)     ✓ (timeout/link_timeout)

内存映射          ✗               ✓ (注册内存)
固定 fd           ✗               ✓ (fixed fd)
零拷贝            ✗               ✓ (SPLICE/SEND_ZEROCOPY)

线程安全          ✓               ✓
fork 安全         ✓               ⚠ (需 ATTACH_TASK)
跨进程共享        ✓               ⚠ (需 ATTACH_TASK)

学习曲线          低              高
API 复杂度        低              高
```

### 8.2 性能对比

```c
// epoll + read/write 测试
int epfd = epoll_create1(0);
struct epoll_event ev = { .events = EPOLLIN, .data.fd = fd };
epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);

struct epoll_event events[128];
while (1) {
    int n = epoll_wait(epfd, events, 128, -1);
    for (int i = 0; i < n; i++) {
        if (events[i].events & EPOLLIN) {
            char buf[4096];
            ssize_t r = read(fd, buf, sizeof(buf));  // 同步系统调用
            // 处理数据
        }
    }
}

// io_uring 测试
struct io_uring ring;
io_uring_queue_init(256, &ring, 0);

struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_recv(sqe, fd, buf, sizeof(buf), 0);
sqe->user_data = RECV_TAG;
io_uring_submit(&ring);

while (1) {
    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);
    // 处理异步完成
    process(cqe);
    io_uring_cqe_seen(&ring, cqe);

    // 立即补充下一个 recv
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_recv(sqe, fd, buf, sizeof(buf), 0);
    sqe->user_data = RECV_TAG;
    io_uring_submit(&ring);
}

// 性能差异：
// epoll: 每个 read() 都是同步系统调用
// io_uring: 批量提交，异步完成

// 基准测试结果（1000 并发连接，4KB 随机读）：
// epoll + read:  ~250K IOPS
// io_uring:      ~480K IOPS（2x 提升）
// io_uring sqpoll: ~520K IOPS（再提升）
```

### 8.3 混合使用：epoll + io_uring

```c
// 场景：已有 epoll 代码，想迁移到 io_uring

// 方案 1：逐步迁移
// - 新代码用 io_uring
// - 旧代码继续用 epoll
// - 共享事件循环

// 方案 2：io_uring 做 I/O，epoll 做监控
int epfd = epoll_create1(0);
struct io_uring ring;
io_uring_queue_init(256, &ring, 0);

// 用 epoll 监控 listenfd
int listenfd = socket(...);
listen(listenfd, 128);
struct epoll_event ev = { .events = EPOLLIN, .data.fd = listenfd };
epoll_ctl(epfd, EPOLL_CTL_ADD, listenfd, &ev);

// 用 io_uring 处理已连接 socket 的 I/O
while (1) {
    // 先处理 io_uring 的 CQE
    struct io_uring_cqe *cqe;
    while (io_uring_peek_cqe(&ring, &cqe) == 0) {
        process_cqe(cqe);
        io_uring_cqe_seen(&ring, cqe);
    }

    // 再处理 epoll 事件（accept 新连接）
    struct epoll_event events[64];
    int n = epoll_wait(epfd, events, 64, 0);  // 非阻塞
    for (int i = 0; i < n; i++) {
        if (events[i].data.fd == listenfd) {
            // 新连接
            int client = accept(listenfd, NULL, NULL);
            // 用 io_uring 处理这个 client
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
            io_uring_prep_recv(sqe, client, buf, 4096, 0);
            sqe->user_data = client;
            io_uring_submit(&ring);
        }
    }
}
```

---

## 9. 高性能网络服务器设计

### 9.1 架构总览

```
┌─────────────────────────────────────────────────────────┐
│                    高性能 HTTP 服务器                     │
│                                                         │
│  ┌─────────────┐                                       │
│  │  Listener   │ ← per-CPU accept 环                   │
│  │  (epoll)    │                                       │
│  └──────┬──────┘                                       │
│         │  accept                                        │
│         ▼                                                │
│  ┌─────────────────────────────────────────┐           │
│  │          Connection Dispatcher          │           │
│  │  (根据 fd 哈希到不同 CPU ring)          │           │
│  └──────┬──────────────────────┬───────────┘           │
│         │                      │                        │
│  ┌──────▼──────┐      ┌───────▼──────┐               │
│  │  CPU 0 Ring │      │  CPU 1 Ring  │               │
│  │  (连接 A-L) │      │  (连接 M-Z)  │               │
│  └──────┬──────┘      └───────▲──────┘               │
│         │                      │                        │
│  ┌──────▼──────┐      ┌───────▼──────┐               │
│  │  Worker 0   │      │  Worker 1    │               │
│  │  (A-L)      │      │  (M-Z)       │               │
│  └─────────────┘      └──────────────┘               │
│                                                         │
│  ┌─────────────────────────────────────────┐           │
│  │           共享内存（请求/响应）          │           │
│  └─────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────┘
```

### 9.2 完整实现

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <liburing.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <sched.h>

#define NUM_RINGS    8
#define QUEUE_DEPTH   256
#define BUF_SIZE     16384
#define MAX_CONNS    8192

// 每个 CPU 一个 ring
struct cpu_ring {
    struct io_uring ring;
    int cpu_id;
} rings[NUM_RINGS];

int create_listen_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    bind(fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(fd, 1024);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    return fd;
}

// 获取 CPU 核心数
int get_cpu_count() {
    return sysconf(_SC_NPROCESSORS_ONLN);
}

// 初始化 per-CPU ring
int init_rings() {
    int cpu_count = get_cpu_count();
    int rings_to_use = cpu_count < NUM_RINGS ? cpu_count : NUM_RINGS;

    for (int i = 0; i < rings_to_use; i++) {
        struct io_uring_params params = {
            .flags = IORING_SETUP_SQPOLL,
            .sq_thread_cpu = i,
            .sq_thread_idle = 2000,
        };
        if (io_uring_queue_init_params(QUEUE_DEPTH, &rings[i].ring, &params) < 0) {
            perror("queue_init");
            return -1;
        }
        rings[i].cpu_id = i;
    }
    return rings_to_use;
}

// 提交 accept（每个 ring 都监听同一个 listenfd）
void submit_accepts(int listenfd, int num_rings) {
    for (int i = 0; i < num_rings; i++) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&rings[i].ring);
        io_uring_prep_multishot_accept(sqe, listenfd, NULL, NULL, SOCK_NONBLOCK);
        io_uring_submit(&rings[i].ring);
    }
}

// 处理连接 I/O
void handle_connection(int fd, struct cpu_ring *ring) {
    char *buf;
    posix_memalign(&buf, 4096, BUF_SIZE);

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring->ring);
    io_uring_prep_recv(sqe, fd, buf, BUF_SIZE, 0);
    sqe->user_data = (uint64_t)fd;
    io_uring_submit(&ring->ring);
}

// 主循环
void main_loop(int listenfd, int num_rings) {
    printf("服务器启动，监听 fd=%d, %d 个 ring\n", listenfd, num_rings);

    while (1) {
        // 轮询所有 ring 的 CQE
        for (int i = 0; i < num_rings; i++) {
            struct io_uring_cqe *cqe;

            // 批量收割
            int head, cyc = 0;
            unsigned int mask = rings[i].ring.cq.ring_mask;

            while (io_uring_peek_cqe(&rings[i].ring, &cqe) == 0) {
                int fd = (int)cqe->user_data;

                if (cqe->result < 0) {
                    // 错误，关闭连接
                    close(fd);
                    io_uring_cqe_seen(&rings[i].ring, cqe);
                    continue;
                }

                if (cqe->result == 0) {
                    // 对端关闭
                    close(fd);
                    io_uring_cqe_seen(&rings[i].ring, cqe);
                    continue;
                }

                // 处理请求
                char *recv_buf = NULL;  // 从哪里获取 buffer？
                // 实际中需要通过 user_data 关联 buffer

                // 简单 HTTP 响应
                const char *resp =
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Length: 5\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    "Hello";
                struct io_uring_sqe *sqe = io_uring_get_sqe(&rings[i].ring);
                io_uring_prep_send(sqe, fd, resp, strlen(resp), 0);
                sqe->user_data = (uint64_t)fd | (1ULL << 32);  // 标记为 send
                io_uring_submit(&rings[i].ring);

                io_uring_cqe_seen(&rings[i].ring, cqe);
            }
        }

        // 短暂让出 CPU
        sched_yield();
    }
}

int main() {
    int listenfd = create_listen_socket(8080);
    int num_rings = init_rings();
    submit_accepts(listenfd, num_rings);
    main_loop(listenfd, num_rings);
    return 0;
}
```

---

## 10. 小结

```
网络 I/O 与多 ring 架构：

RECV/SEND：
  - MSG_WAITALL：等全部数据
  - MSG_PEEK：窥探不删除
  - MSG_MORE：批量发送延迟
  - IOSQE_BUFFER_SELECT：自动选 buffer

ACCEPT：
  - 普通 accept：每次一个连接
  - multishot accept（5.11+）：一次注册持续 accept
  - 配合 SOCK_NONBLOCK 使用

CONNECT：
  - 异步 connect + poll POLLOUT 判断完成
  - link timeout 控制超时
  - 连接池设计

SO_ZEROCOPY：
  - 需要网卡支持
  - buffer 必须 page aligned
  - IORING_OP_SEND_ZEROCOPY（5.19+）
  - 发射后不管，需要应用层 ACK 确认

UDP 支持：
  - RECV/SEND/RECVMSG/SENDMSG 都支持
  - multicast 同样支持
  - 适合 DNS / QUIC / 实时音视频

多 ring 架构：
  - per-CPU ring：短连接高并发
  - per-connection ring：长连接复杂协议
  - 跨 ring 通信：消息队列 / pipe / 共享内存

epoll vs io_uring：
  - epoll：成熟简单，适合监控
  - io_uring：异步 I/O，高吞吐，低延迟
  - 可以混合使用
```

---

## 延伸阅读

- Kernel 源码: `net/ipv4/tcp.c`, `net/core/sock.c`
- `man 7 socket` — SO_ZEROCOPY 文档
- LWN: "io_uring and networking": https://lwn.net/Articles/810071/
- LWN: "io_uring for network servers": https://lwn.net/Articles/827062/
- RFC 8290: "TCP Fast Open"
- io_uring talk: "Writing High-Performance Networking Servers" (axboe)
- Nginx io_uring 模块: `ngx_io_uring.c`