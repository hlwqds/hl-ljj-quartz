---
title: "lwIP 深度解析（十六）：socket 与 netconn：BSD 语义与 VFS 集成"
date: 2026-08-26
description: "拆到第三层 API 的地基：netconn 的 recvmbox/api_msg/do_* 处理函数水位语义（RECVMBOX_SIZE=6、TCP_SNDLOWAT 只管 socket 可写），sockets.c 的 alloc_socket fd 映射为何从 54 开始（FD_SETSIZE-MAX_SOCKETS），IDF 的 lwip_fops 如何把 read/write/close/poll 挂进 VFS，阻塞 recv 的完整唤醒链、SO_RCVTIMEO/O_NONBLOCK/select 三条逃生路径实测、EMFILE/ENFILE 错误账本与 fd 耗尽回收时延测量。"
tags: [lwip, network, esp32, esp-idf, qemu, sockets, vfs]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 16. **第十六章：socket 与 netconn：BSD 语义与 VFS 集成**

# lwIP 深度解析（十六）：socket 与 netconn：BSD 语义与 VFS 集成

这一章回答三个问题：**一次 BSD socket 调用是怎么一路走到 `tcpip_thread` 的**（把第 13 章的邮箱模型接到你天天写的 `connect()`/`recv()` 上）、**ESP-IDF 为什么要把 socket 挂进 VFS**（让 `read`/`write`/`close`/`poll` 对所有"文件"统一）、**线程阻塞在 `recv()` 里时到底是谁在等谁**（答案是应用任务在等 netconn 的收件邮箱，而 `tcpip_thread` 根本不知道它的存在）。读完它，前十五章拆掉的所有零件应该能在你脑子里第一次完整地转起来。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`components/lwip/lwip/src/api/`）与 IDF 适配层 `components/lwip/port/`；实验工程 `practice/lwip-ch16-socket-netconn-vfs/`。

---

## 16.1 三层模型的总装图：调用链与等待关系

### 1. 一条完整函数链：从 `socket()` 到 `tcpip_thread`

应用代码写的每个 POSIX 名字，实际落点如下（以 `connect()` 为例，其余同理）：

```text
应用任务                          tcpip_thread（唯一的内核执行体）
────────                        ────────────────────────────────
connect(fd,...)
  │   libc/newlib → esp_vfs 分派
  ▼
lwip_connect()            src/api/sockets.c
  │  get_socket(fd) → sockets[] 数组查表（fd 减去 LWIP_SOCKET_OFFSET 得下标）
  ▼
netconn_connect(conn,...)         src/api/lib.c
  │  填一个 struct api_msg{conn, err, msg.bc={ipaddr,port}}
  ▼
netconn_apimsg(lwip_netconn_do_connect, msg)    src/api/api_lib.c
  │  apimsg->op_completed_sem = 本线程私有信号量
  ▼
tcpip_send_msg_wait_sem(fn, msg, sem)           src/api/tcpip.c
  ├─ sys_mbox_post(&tcpip_mbox, TCPIP_MSG_API{fn, msg})   ──投递──▶  取消息执行 fn(msg)
  └─ sys_arch_sem_wait(sem, 0)          ◀──完成信号──   do_bind/do_connect 改 PCB，
       （应用任务在这里睡着）                            TCPIP_APIMSG_ACK 释放信号量
```

四个关键事实让这条链成立：

1. **fd 只是数组下标的偏移值**。`sockets.c` 里是一块静态数组 `static struct lwip_sock sockets[NUM_SOCKETS]`，`alloc_socket()` 扫描空槽后返回 `i + LWIP_SOCKET_OFFSET`。外部看到的一切 fd 都要减回偏移才能用。
2. **每类 `do_*` 处理函数都是纯内核侧代码**：`lwip_netconn_do_connect/bind/listen/accept/recv/send/close...` 在 `api_msg.c` 中实现，唯一合法执行环境是 `tcpip_thread`（这正是第 13 章「core 是单线程世界上帝」规则的应用面）。
3. **同步等待用的是线程本地信号量**。IDF 打开了 `LWIP_NETCONN_SEM_PER_THREAD=1`（`port/include/lwipopts.h`）：每个调 socket/netconn 的线程通过 `sys_thread_sem_get()` 拿一个挂在 pthread TLS key 上的信号量（`port/freertos/sys_arch.c`），完成时由内核侧 `TCPIP_APIMSG_ACK` 归还——而不是像上游默认那样给**每个 netconn 配一个** `op_completed` 信号量。省的是对象数量，换来的是每次 API 调用取放 TLS 指针的开销。
4. **PCB 属于内核，netconn/sock 属于线程**。第 10、11 章解剖过 `udp_pcb/tcp_pcb` 只活在 `tcpip_thread` 的世界里；netconn 是「线程 world 对 PCB 的遥控器」，socket 结构再在外面套一层 BSD 语义皮。

### 2. ESP-IDF 为什么把 socket 挂进 VFS

Vanilla lwIP 自己实现了整套 POSIX 名字冲突方案：`LWIP_COMPAT_SOCKETS` 用宏把 `socket/read/write` 重命名成 `lwip_socket/...`，`LWIP_POSIX_SOCKETS_IO_NAMES` 决定要不要抢走 `read/close` 这些通用名字。这在「进程里只有 lwIP 一个网络栈」的系统里够用。

ESP-IDF 不行。FATFS、SPIFFS、UART、事件通知（eventfd）……全都想要那几个 POSIX 符号。IDF 的解法是把整个 libc 文件描述符空间变成一张 **VFS 注册表**：

- 每个文件系统/设备注册一段 fd 区间；
- libc 的 `read(fd)` 进来按区间分派给对应驱动的 `read_p`。

于是 lwIP 适配层做了一件漂亮的事（`port/esp32xx/vfs_lwip.c` 的 `esp_vfs_lwip_sockets_register()`）：

```c
// components/vfs/include/esp_vfs.h:40
#define MAX_FDS  FD_SETSIZE      /* 为了兼容 fd_set 和 select() */
// vfs_lwip.c 尾部：
ESP_ERROR_CHECK(esp_vfs_register_fd_range(&s_lwip_vfs,
                  ESP_VFS_FLAG_STATIC | ESP_VFS_FLAG_CONTEXT_PTR,
                  NULL /* ctx */,
                  LWIP_SOCKET_OFFSET,   /* 注册区起点：54 */
                  MAX_FDS));            /* 64 */
```

它注册了 `read_p/write_p/close_p/fstat_p/fcntl_p/ioctl_p` 六个入口，全部直接转发给 `lwip_read/lwip_write/lwip_close/lwip_fstat/lwip_fcntl/lwip_ioctl`。效果：

```c
// vfs_lwip.c:73 —— 库里的 read 系统调用最终走到这
static int lwip_read_r_wrapper(void *ctx, int fd, void *data, size_t size)
{
    return lwip_read(fd, data, size);
}
```

所以 IDF 必须关掉 lwIP 自己的名字劫持（同在 `port/include/lwipopts.h`）：

| 选项                          | IDF 取值 | 含义                                                |
| ----------------------------- | -------- | --------------------------------------------------- |
| `LWIP_COMPAT_SOCKETS`         | 0        | 不把 `socket()` 宏改名                              |
| `LWIP_POSIX_SOCKETS_IO_NAMES` | 0        | `read/write/close` 等名字**完全属于 libc/VFS 世界** |

这是系列暗线 B 的又一个标本：Vanilla 用「编译期改名」解决符号竞争，IDF 用「运行期 fd 注册表」解决——后者让 `printf` 和 `write(sock,...)` 走同一个 syscall 面。

### 3. 阻塞在 recv 时：谁在等谁

把三层各摊一份答案：

| 层             | 谁睡着了                                        | 在等什么                   | 谁能叫醒它                               |
| -------------- | ----------------------------------------------- | -------------------------- | ---------------------------------------- |
| 应用任务       | `sys_arch_mbox_fetch(&conn->recvmbox, ...)`     | 自己 netconn 的收件邮箱    | 只有往这个邮箱 trypost 的 `tcpip_thread` |
| `tcpip_thread` | `sys_mbox_fetch(&tcpip_mbox)` 或内部定时器 tick | 新的 API 消息 / 定时器到期 | RX 路径投递者、API 调用者、tick          |
| 其它无关任务   | 各自阻塞点                                      | ——                         | 与本次 recv 无任何交互                   |

**`tcpip_thread` 甚至不知道有个任务正在等数据**。数据到达时它做的只是把 pbuf 指针塞进 recvmbox（顺便维护事件计数、看看有没有 select/poll 等待者需要信号量叫醒）。这个解耦是整章最重要的一张图，16.4 给出逐拍时序。

---

## 16.2 netconn 层解剖：api*msg、do*\* 处理函数与水位

### 1. struct netconn：PCB 的遥控器

```c
// src/include/lwip/api.h（节选，按 IDF 配置保留的字段）
struct netconn {
  enum netconn_type type;        /* NETCONN_TCP / UDP / RAW */
  enum netconn_state state;
  union {                        /* 内核态协议控制块（只在 tcpip_thread 里动） */
    struct ip_pcb  *ip;
    struct tcp_pcb *tcp;
    struct udp_pcb *udp;
    struct raw_pcb *raw;
  } pcb;
  err_t pending_err;             /* 最近一次未上报的异步错误 */
#if !LWIP_NETCONN_SEM_PER_THREAD
  sys_sem_t op_completed;        /* IDF=1 ⇒ 这个字段不存在！ */
#endif
  sys_mbox_t recvmbox;           /* 收到的 pbuf 指针队列（TCP），或 netbuf（UDP） */
  sys_mbox_t acceptmbox;         /* listen 时创建的新连接队列 */
  union { int socket; } callback_arg;  /* 回指所属 socket fd（初始 -1） */
  u32_t recv_timeout;            /* SO_RCVTIMEO，毫秒 */
  u8_t flags;                    /* NETCONN_FLAG_NON_BLOCKING 等 */
  struct api_msg *current_msg;   /* 半途的写操作状态机句柄 */
  netconn_callback callback;     /* socket 层挂的就是 event_callback */
};
```

要点一：`recvmbox` 是 FreeRTOS 队列，每项放一个指针（TCP 是 `pbuf*`/哨兵，UDP/RAW 是 `netbuf*`），深度来自 Kconfig（下一小节）；要点二：因为 `SEM_PER_THREAD=1`，同步信号量根本不在 netconn 里，这允许同一个 netconn 从多个线程安全地驱动（配合下面的 FULLDUPLEX）；要点三：`callback_arg.socket` 初始 -1，accept 场景里数据比分配 fd 先到会临时再往下减（负数表示“fd 还没出生”），`lwip_accept` 之后统一修正——`event_callback` 里那段对 `< 0` 的特判就是干这个的。

IDF 还打开了 `LWIP_NETCONN_FULLDUPLEX=1`（上游默认 0 且注释自称 alpha）：读用一个线程、写用一个线程、第三个线程负责 close 成为受支持的操作，代价是每个 sock 加 `fd_used/fd_free_pending/mbox_threads_waiting` 计数。后面实验 D 会直接利用它做跨任务 close 解救阻塞 recv。

### 2. api_msg：一条消息打包一次 RPC

```c
// src/include/lwip/priv/api_msg.h（节选）
struct api_msg {
  struct netconn *conn;   /* 必带：里面藏着应答用的手段（IDF 下是 TLS 信号量地址） */
  err_t err;              /* 内核侧的返回值 */
  union {
    struct netbuf *b;                              /* do_send */
    struct { ip_addr_t ipaddr; u16_t port; ...} bc;/* do_bind / do_connect */
    struct { const struct netvector *vector; ... } w;  /* do_write 流式写游标 */
    struct { size_t len; } r;                      /* do_recv */
    struct { u8_t shut; ... } sd;                  /* do_close/shutdown */
    ...
  } msg;
};
```

一次 netconn/socket 调用 = 栈上构造这样一条消息 → 投进 tcpip_mbox → 内核侧处理函数填 `msg->err` 并 ACK。注意 `apimsg->op_completed_sem` 也挂在消息上一起过去（`netconn_apimsg` 里赋值），应答信号量和请求消息走同一张“快递单”。

### 3. do_recv：看似无聊却解释了窗口的一举一动

```c
// src/api/api_msg.c
void lwip_netconn_do_recv(void *m)
{
  struct api_msg *msg = (struct api_msg *)m;
  msg->err = ERR_OK;
  if (msg->conn->pcb.tcp != NULL) {
    if (NETCONNTYPE_GROUP(msg->conn->type) == NETCONN_TCP) {
      size_t remaining = msg->msg.r.len;
      do {
        u16_t recved = (u16_t)((remaining > 0xffff) ? 0xffff : remaining);
        tcp_recved(msg->conn->pcb.tcp, recved);
        remaining -= recved;
      } while (remaining != 0);
    }
  }
  TCPIP_APIMSG_ACK(msg);
}
```

它做的事只有一件：告诉 TCP「我这边消费了 len 字节，可以扩窗口了」。谁调用它？不是读数据的路径，而是**读完之后**：socket 层 `lwip_recv_tcp` 拷完最后一个字节才 `netconn_tcp_recvd(conn, recvd)` 补发这条消息。这就是第 12 章延迟确认与应用侧消费之间的中间层——**读缓冲的 memcpy 完成之前，接收窗口寸步不开**。

### 4. 接收方向的水位：RECVMBOX_SIZE=6

netconn 创建时按类型选邮箱深度（`netconn_alloc()`，`api_msg.c`）：

```c
case NETCONN_TCP: size = DEFAULT_TCP_RECVMBOX_SIZE; break;   /* = CONFIG_LWIP_TCP_RECVMBOX_SIZE */
...
if (sys_mbox_new(&conn->recvmbox, size) != ERR_OK) goto free_and_return;
```

IDF 的 `CONFIG_LWIP_TCP_RECVMBOX_SIZE` 默认 **6**（Kconfig 允许 6~1024），菜单注释给出的经验公式是 `LWIP_TCP_WND_DEFAULT/TCP_MSS + 2`。6 个槽位 × 平均每个 pbuf 一个 MSS，刚好覆盖满一个未滚动窗口的数据流。超发的后果分协议而异（第 10 章踩过坑）：

| 协议    | recvmbox 满时的行为                                                                                                                                                       |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TCP     | `recv_tcp` 的 trypost 失败则返回 ERR_MEM 且**不释放 pbuf**——由 TCP 核心 fasttmr 周期性地把同一个 pbuf 重新呈递，直到投进为止（数据已 ACK 不能丢）：事实上的**反压重投递** |
| UDP/RAW | `recv_udp/recv_raw` 的 trypost 失败即**静默删除 netbuf**，计数器外无痕迹（第 10 章实测过）                                                                                |

### 5. 发送方向的水位：TCP_SNDLOWAT 只属于 socket

发送泵的燃料来自两个回调（都在 `api_msg.c`）：

- `sent_tcp()`：TCP 每收到 ACK 被触发。若 `conn->state == NETCONN_WRITE/CLOSE` 就继续 `lwip_netconn_do_writemore/do_close_internal` 推进半途写；然后判一次**可写恢复**：

```c
/* 若队列降过低水位线以下，通知 select 可以再次标记可写 */
if ((conn->pcb.tcp != NULL) && (tcp_sndbuf(conn->pcb.tcp) > TCP_SNDLOWAT) &&
    (tcp_sndqueuelen(conn->pcb.tcp) < TCP_SNDQUEUELOWAT)) {
  netconn_clear_flags(conn, NETCONN_FLAG_CHECK_WRITESPACE);
  API_EVENT(conn, NETCONN_EVT_SENDPLUS, len);
}
```

- 第 6 章结论在此落地：**netconn_write 的续传条件只看 sndbuf 是否放得下当前向量**，不看 SNDLOWAT；`TCP_SNDLOWAT/TCP_SNDQUEUELOWAT` 门控的唯一消费者是 `NETCONN_EVT_SENDPLUS` 事件，即 **select/poll 的可写判定**（socket 层专属语义）。IDF 未在 Kconfig 暴露这两个宏，走的还是上游默认公式 `min(max(TCP_SND_BUF/2, 2*MSS+1), TCP_SND_BUF-1)`——默认 `SND_BUF=5760` 时即 2880 字节。

对比记忆卡：

| 水位            | 默认值          | 保护的东西            | 生效范围                                               |
| --------------- | --------------- | --------------------- | ------------------------------------------------------ |
| `RECVMBOX_SIZE` | 6 槽            | 接收路径反压/丢弃边界 | netconn + socket 两层共用（socket 没有自己的缓存队列） |
| `TCP_SNDLOWAT`  | SND_BUF/2=2880B | 可写事件的迟滞回差    | 仅 socket 层可写语义                                   |

---

## 16.3 socket 层解剖：alloc_socket、VFS 表与多路复用

### 1. 为什么你的第一个 socket 是 54 号

三行推导，每一行都已核实：

1. `components/lwip/Kconfig`：`LWIP_MAX_SOCKETS`，默认 **10**（范围 1~253）；
2. 工具链 newlib `sys/select.h`：`FD_SETSIZE` 默认 **64**，且 IDF 特意不覆盖它（Kconfig help 写明超过 61 要自行改 CMake 重定义 FD_SETSIZE）；
3. `port/include/lwipopts.h:996`：

```c
#define LWIP_SOCKET_OFFSET   (FD_SETSIZE - CONFIG_LWIP_MAX_SOCKETS)   /* 64-10 = 54 */
```

动机注释写得直白：fd 0~53 让给非 socket 用户（stdio 占着 0/1/2，还有 FATFS 等），socket 使用最靠顶端的一段号段，使 offset 天然与剩余空间对齐。`vfs_lwip.c` 开头有静态断言兜底：`LWIP_SOCKET_OFFSET >= 6`（stdio 至少要 3 个 fd）且 `[54, 64)` 区间宽度恰好等于 `MAX_SOCKETS`——**fd 号段宽度与协议栈槽数被配置锁死成一致**，两边谁也不会越界。

`alloc_socket()` 的实现印证一切（`src/api/sockets.c`）：

```c
SYS_ARCH_PROTECT(lev);
if (!sockets[i].conn) {
  sockets[i].fd_used = 1;            /* FULLDUPLEX 计数 */
  sockets[i].conn = newconn;
  SYS_ARCH_UNPROTECT(lev);
  ...
  return i + LWIP_SOCKET_OFFSET;     /* ← 对外 fd = 数组下标 + 54 */
}
```

### 2. lwip_fops 这张 VFS 操作表

`vfs_lwip.c` 注册的完整能力矩阵（`esp_vfs_fs_ops_t`）：

| POSIX 入口               | 转发目标                      | 备注                                                         |
| ------------------------ | ----------------------------- | ------------------------------------------------------------ |
| `read(fd,buf,n)`         | `lwip_read` → `lwip_recvfrom` | 应用常用；走的是 libc VFS 而非 lwIP 名字劫持                 |
| `write(fd,buf,n)`        | `lwip_write` → `lwip_sendto`  | 同上                                                         |
| `close(fd)`              | `lwip_close`                  | 触发 netconn 删除链路（见 16.7 实验 C）                      |
| `fstat(fd,st)`           | `lwip_fstat`                  | 无脑返回 `st_mode = S_IFSOCK`                                |
| `fcntl(fd,cmd,arg)`      | `lwip_fcntl`                  | 只实现 `F_GETFL/F_SETFL`，其中 `F_SETFL` 只认 `O_NONBLOCK`   |
| `ioctl(fd,FIONREAD,...)` | `lwip_ioctl`                  | 编译期门控：需 `LWIP_SO_RCVBUF` 或 `LWIP_FIONREAD_LINUXMODE` |

外加 select 四件套（见下）。两张值得停留的细节截图：

- **ioctl/FIONREAD 的默认配置陷阱**：IDF 的 `LWIP_SO_RCVBUF`（Kconfig `LWIP_SO_RCVBUF`）默认 **n**。不开它，`FIONREAD` 分支根本不参与编译，落进兜底分支。我们实测 `ioctl(c, FIONREAD, &n)` 返回 -1、errno=88（ENOTSOCK，兜底分支的误导性报错）——错误码没说谎但说了谎话，排障时先查配置再看 errno。
- **errno 全家桶的小口径差异**：本工具链 `sys/errno.h` 里 `EWOULDBLOCK==EAGAIN==11`、`ENFILE=23`、`EMFILE=24`、`EHOSTUNREACH=118`、`ENOTCONN=128`。POSIX 常量表和其它工具链可能有出入，脚本报错别先入为主。

### 3. select 与 poll 的实现路径

两条不同的路（都已在源码核实）：

**select：lwIP 原生实现 + VFS 选择适配**

```c
// vfs_lwip.c（CONFIG_VFS_SUPPORT_SELECT=y 时）
static const esp_vfs_select_ops_t s_lwip_select_ops = {
    .socket_select              = &lwip_select,          // 直接复用 lwIP 实现
    .stop_socket_select         = &lwip_stop_socket_select,
    .stop_socket_select_isr     = &lwip_stop_socket_select_isr,
    .get_socket_select_semaphore= &lwip_get_socket_select_semaphore,
};
```

`lwip_select()`（`sockets.c`）的两段式算法：先 `lwip_selscan` 扫一遍就绪数；全零则把自己的描述符集与**线程本地信号量**打包成一个 `struct lwip_select_cb` 挂上全局链表 `select_cb_list`，把涉及的每个 sock 的 `select_waiting++` 后再扫一遍（防漏检竞窗），仍无就绪才睡进 `sys_arch_sem_wait(sem)`。数据到达时 `event_callback → select_check_waiters` 遍历等待者、`sys_sem_signal` 叫醒对应线程。IDF 版两个变化：睡觉用的信号量不再新建/销毁而是 TLS 复用；nfds 校验上限 `LWIP_SELECT_MAXNFDS`——IDF 环境里新lib 的 `FD_SET` 先于 lwIP 头文件定义，走 `#else` 分支保持等于外部 `FD_SETSIZE=64`（纯 lwIP 无 libc 头文件的构建才启用「重定义 FD_SETSIZE 为 MEMP_NUM_NETCONN 并加 OFFSET」的那套分支）。

**poll：IDF 偷懒用了仿真层**

```c
// components/esp_libc/src/poll.c
int poll(struct pollfd *fds, nfds_t nfds, int timeout)
{
    ... 循环把 events 映射成 fd_set（含 errorfds）...
    const int select_ret = select(max_fd + 1, &readfds, &writefds, &errorfds, timeout < 0 ? NULL : &tv);
    ... select_ret > 0 时按 FD_ISSET 回填 revents |= POLLIN/POLLOUT/POLLERR ...
}
```

也就是说 IDF 应用层 `poll()` **不会**进入 lwIP 自带的 `lwip_poll`（尽管 `LWIP_SOCKET_POLL=1` 使其存在并编译），而是退化成 select 的参数翻译器。副作用记一笔：就绪计数 `nready` 按「fd×事件维度」累加，POLLIN 与 POLLOUT 同时命中会被算成 2——语义正确的永远是 `revents` 位图，计数仅供“是否≥1”参考（16.7 实验里有现成翻车样例）。

---

## 16.4 阻塞模型全景：一张唤醒链时刻表

### 1. 非 block 三开关

| 开关       | 设置方式                                  | 生效位置                                       |
| ---------- | ----------------------------------------- | ---------------------------------------------- |
| 永久非阻塞 | `fcntl(fd, F_SETFL, O_NONBLOCK)`          | 置 netconn flag `NETCONN_FLAG_NON_BLOCKING`    |
| 单次非阻塞 | `recv(..., MSG_DONTWAIT)`                 | 不改 netconn，仅这次调用加 `NETCONN_DONTBLOCK` |
| 接收超时   | `setsockopt(SOL_SOCKET, SO_RCVTIMEO, tv)` | 写 `conn->recv_timeout`（毫秒）传给 mbox 等待  |
| 发送超时   | `setsockopt(SOL_SOCKET, SO_SNDTIMEO, tv)` | 控制 writemore 状态机的整体预算                |

`SO_RCVTIMEO/SO_SNDTIMEO` 的编译开关是 `LWIP_SO_RCVTIMEO/SNDTIMEO`，IDF 在 `port/include/lwipopts.h` 硬编码为 1（上游默认 0）——想裁剪也关不掉。

非阻塞下的两种失败码区分一下：mbox 空⇒`ERR_WOULDBLOCK`⇒errno 11；RCVTIMEO 到期⇒`ERR_TIMEOUT`⇒errno 也是 11（`err_to_errno` 把 -3 与 -7 都映射到 EWOULDBLOCK）。**调用方无法从 errno 区分“真的设了会马上回来”和“超时才回来”**，只能靠时间差——这不是 bug 而是 lwIP 刻意的简化映射。

### 2. 一次阻塞 recv 的完整复活时序

假设应用任务 T 已阻塞在 `recv()` 里，此刻以太网口来了携带新 TCP 数据的帧：

```text
时间 →   网卡(硬件/SLIRP)         eth rx 路径                tcpip_thread                     应用任务 T
─────  ─────────────────      ─────────────────      ───────────────────────────    ─────────────────────────
 t0    帧 DMA/仿出来，
       触发中断
 t1                          openeth ISR → 驱动任务
                             组装 pbuf
                             tcpip_input(pbuf):
                               mbox_post(tcpip_mbox)   ───▶ 收到 MSG_INPKT
 t2                                                    ethernet_input → ip4_input
                                                       → tcp_input → 状态机
                                                       → 数据挂 rcv 队列
 t3                                                    recv_tcp():
                                                          mbox_post(recvmbox,pbuf)  ───▶  (T 仍在睡)
                                                          API_EVENT(RCVPLUS,len)
                                                            = event_callback()
                                                              rcvevent++
                                                              select_check_waiters():
                                                                有 select 等待者？
                                                                是→sys_sem_signal(tls_sem)
                                                                否→只改计数就返回
 t4                                                                                       mbox_fetch 返回 pbuf*
                                                                                          pbuf_copy_partial()
                                                                                          拷贝进用户 buf
 t5                                                                                       netconn_tcp_recvd()
                                                                                            经 apimsg 投递 do_recv(len)
                                                       tcp_recved() 扩接收窗口
 t6                                                                                       recv() 返回字节数
```

三个停顿点：

1. **t1 的中转箱是全协议栈的咽喉**。tcpip_mbox（`CONFIG_LWIP_TCPIP_RECVMBOX_SIZE` 默认 32 深）既是所有 API 消息又是所有输入包的入口，栈内任何一层堵塞都会表现成这里排队。
2. **t3 的 event_callback 就是“套娃信令总线”**。socket 层没有自己的中断，全靠 netconn 层回调顺带检查有没有 select/poll 客户。回调发生在 `tcpip_thread` 上下文里，绝不能在这里做多线程阻塞动作——设计上它也确实只做计数加加与信号量 give。
3. **t5 揭示了为什么 recv 阻塞期间窗口不扩张**：窗口推进在拷贝完成后手动发起，所以慢消费者天然拖累整条链路的滑动窗口（对应 16.2 do_recv 小节）。

### 3. 对端永远不发数据时的窒息

应用任务 sleep 在 `recvmbox` 上，除非 pbuf 入箱或错误消息入箱（`err_tcp()` 会向 recvmbox/acceptmbox `trypost` 错误哨兵），否则**没有任何人会唤醒它**。网线拔了也是同理：link-down 只影响新包收发，坐等的 recv 一无所知——这是嵌入式 socket 服务最常见的悬挂事故。逃生三条路各自的实现差异与实测见 16.7 实验 D；先记住成本谱系：**非阻塞自旋 < select 盯梢 < SO_RCVTIMEO（per-call 计时）< 跨任务 close 解救**。

---

## 16.5 错误语义账本：谁在哪一层产生了哪个 errno

### 1. 基础映射表：err_t → errno

lwIP 自己的错误枚举经 `err_to_errno()`（`src/api/err.c`）翻译，全表如下（可直接当速查贴纸上墙）：

| err_t             | errno             | 产生场景举例                                                 |
| ----------------- | ----------------- | ------------------------------------------------------------ |
| ERR_OK 0          | 0                 | 成功                                                         |
| ERR_MEM -1        | ENOMEM            | 内存不足（写缓冲不够等）                                     |
| ERR_BUF -2        | ENOBUFS           | 构造包时字段缓冲异常                                         |
| ERR_TIMEOUT -3    | EWOULDBLOCK(11)   | RCVTIMEO/SNDTIMEO 到期                                       |
| ERR_RTE -4        | EHOSTUNREACH(118) | 无路由可达（如没拿到 IP 就发包）                             |
| ERR_INPROGRESS -5 | EINPROGRESS       | connect 正在后台进行                                         |
| ERR_VAL -6        | EINVAL            | 参数非法                                                     |
| ERR_WOULDBLOCK -7 | EWOULDBLOCK(11)   | 非阻塞时空手而归                                             |
| ERR_USE -8        | EADDRINUSE        | bind 已占用端口                                              |
| ERR_ALREADY -9    | EALREADY          | connect 已在途中重复调                                       |
| ERR_ISCONN -10    | EISCONN           | 连接已建立再来 connect                                       |
| ERR_CONN -11      | ENOTCONN(128)     | 未连接就干活                                                 |
| ERR_IF -12        | -1（裸值！）      | 底层 netif 报错；注意映射表此格写着 `-1`，会穿透成非法 errno |
| ERR_ABRT -13      | ECONNABORTED(113) | 内核主动中止连接                                             |
| ERR_RST -14       | ECONNRESET(104)   | 对端发 RST                                                   |
| ERR_CLSD -15      | ENOTCONN(128)     | 连接已被优雅关闭后再操作                                     |
| ERR_ARG -16       | EIO               | 内核内部参数错                                               |

### 2. 但有三个特殊号码另有出处

这三个经常在事故报告里背锅，定位时要看对楼层：

| errno | 名字   | 唯一制造者                                                                                 | 触发条件                                                                                          |
| ----- | ------ | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| 23    | ENFILE | **lwIP** `alloc_socket()` 失败路径（`lwip_socket`/`lwip_accept` 统一 `set_errno(ENFILE)`） | sockets[] 数组无空槽（即触达 `CONFIG_LWIP_MAX_SOCKETS` 上限，扣掉已被占用的槽位就是还能开的个数） |
| 24    | EMFILE | **不存在于 2.2.0-dev 的 sockets.c**（grep 零命中）                                         | 由某些老版本或上游 Unix 语境迁来的惯性认知；在 ESP-IDF v6.0.2 下永远不会看到 lwIP 吐它            |
| 28    | ENOSPC | lwIP 中仅 `inet_ntop()` 缓冲太小一处                                                       | `snprintf` 家族的容量警察，跟内存压力毫无关系                                                     |

推论合并入第 7~12 章 Batch 的旧观察就能解开谜团：

> [!note] 与前面章节的交叉印证
>
> - **fd 槽位上限才是真正的硬闸**：第 10 章发现改大 `CONFIG_LWIP_MAX_UDP_PCBS` 后仍在同一数量级上撞墙——因为 UDP/RAW sockets 同样消耗 slots[]；Batch 3 观察到的“第 16 个 socket 才 ENFILE”，在本章干净环境下重测变回恰好第 `NUM_SOCKETS − 已占槽 + 1` 个失败（详见 16.7 C），两次现象完全同构，差别只是开机时已有多少隐藏占用（DNS 探针、listen 队列残留等）。
> - **accept 撞监听队列耗尽**的 `errno=113`：编号在此工具链中实为 `ECONNABORTED`（新宏表 150 行），对应 listen PCB 因内存压力 aborted 之后的 accept 尝试——编号与当时笔记中“EHOSTDOWN”的叫法不同，语义上 abort 更贴合，这也是「常量数值必须以工具链头文件为准」的又一实证。
> - **EPIPE 缺席**：POSIX 程序员习惯性预期的 broken pipe (EPIPE) 在 lwIP 三层里都不存在——断连一律坍缩成 ECONNRESET/ENOTCONN，也没有 SIGPIPE 这种东西可杀掉任务。

### 3. ioctl 兜底分支的错误码谎言

上面说过 `FIONREAD` 在 `LWIP_SO_RCVBUF=n` 时落进兜底分支报 ENOTSOCK(errno 88)。这提醒我们对 errno 保持职业怀疑：**先怀疑配置/层间错配，再怀疑资源状态，最后才怀疑协议对端行为**。

---

## 16.6 Vanilla lwIP 与 ESP-IDF lwIP 对照

### 1. sockets.c / vfs 集成的分叉

| 维度                  | Vanilla lwIP 2.2.0-dev                                             | ESP-IDF v6.0.2 适配层                                                                            |
| --------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| POSIX 符号提供方式    | `LWIP_COMPAT_SOCKETS` 宏改名 / `LWIP_POSIX_SOCKETS_IO_NAMES` 抢名  | 双双置 0；POSIX 名字归 libc/VFS，靠 `esp_vfs_register_fd_range` 挂钩                             |
| fd 起点               | `LWIP_SOCKET_OFFSET` 默认 0（socket fd 从 0 起步混用系统 fd 空间） | `(FD_SETSIZE-CONFIG_LWIP_MAX_SOCKETS)`=54，特意留低段给别人                                      |
| read/write/close 身份 | lwIP 亲生                                                          | VFS 表六函数转发（`vfs_lwip.c` 的 read_p/write_p/…）                                             |
| select                | 应用直呼 `lwip_select`，select_cb 全局链表                         | 经 VFS select_ops 转交同名实现；同时被 eventfd 等别的 VFS 共享一套框架                           |
| poll                  | `lwip_poll` + `lwip_pollscan`（原生）                              | **弃用**；`esp_libc/src/poll.c` 用 select 仿真                                                   |
| per-thread 信号量     | `LWIP_NETCONN_SEM_PER_THREAD` 默认 0，每 netconn 一个 op_completed | 强制 1，pthread TLS 挂载（`sys_thread_sem_get`）                                                 |
| 全双工支持            | `LWIP_NETCONN_FULLDUPLEX` 默认 0（alpha）                          | 强制 1（跨线程读写+第三方 close 受支持）                                                         |
| sockets.c 内部微补丁  | ——                                                                 | `ESP_LWIP` 条件块：free_socket 时清 `select_waiting`、tryget 前额外校验 `ret->conn` 非空等防悬垂 |
| FIONREAD              | 需要 `LWIP_SO_RCVBUF` 或 LINUXMODE                                 | `LWIP_SO_RCVBUF` Kconfig 默认 n ⇒ 功能默认死                                                     |

### 2. CONFIG*LWIP_SO*\* 快查清单

grep 自 `components/lwip/Kconfig` + `port/include/lwipopts.h`：

| 选项                                      | Kconfig 暴露                 | 默认     | 说明                                      |
| ----------------------------------------- | ---------------------------- | -------- | ----------------------------------------- |
| `LWIP_SO_LINGER`                          | 是 (`CONFIG_LWIP_SO_LINGER`) | **n**    | SO_LINGER 关闭行为不可用                  |
| `LWIP_SO_REUSE`                           | 是                           | y        | SO_REUSEADDR 可用                         |
| `LWIP_SO_REUSE_RXTOALL`                   | 是 (依赖 REUSE)              | y        | 广播/组播复制给所有匹配 socket            |
| `LWIP_SO_RCVBUF`                          | 是                           | **n**    | 关：FIONREAD 死、UDP 发送缓冲水位不可调   |
| `LWIP_SO_RCVTIMEO`                        | **否**                       | 硬编码 y | 必开                                      |
| `LWIP_SO_SNDTIMEO`                        | **否**                       | 硬编码 y | 必开                                      |
| `LWIP_SOCKET_SELECT` / `LWIP_SOCKET_POLL` | 否（内部 opt，默认 1）       | 1/1      | 上游机制本身在编，但 poll 被 IDF 替换使用 |

一句话点评：IDF 鼓励你依赖 select/rcvtimeo/sndtimeo（默认开），同时悄悄收走了 FIONREAD 与 SO_LINGER 这些 Unix 老朋友——移植 Linux 代码过来时这两处最容易在编译期踩雷。

---

## 16.7 实验：分层成本标定 / VFS 验证 / fd 耗尽 / 窒息逃生

实验工程 `practice/lwip-ch16-socket-netconn-vfs/` 基于 ch3 联网模板（openeth bring-up + DHCP 等待），QEMU 启动命令按公约第 3 节，hostfwd 用 `hostfwd=tcp::8018-:8888`：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch16-socket-netconn-vfs
idf.py build
idf.py qemu monitor < /dev/null || true     # 生成 qemu_flash.bin/qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 150 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8018-:8888 -nographic -no-reboot 2>&1 | tee run.log
```

所有测量在 guest 内部 `127.0.0.1` 回环完成（2.2.0-dev 已无独立 loopif，特判内建于 `ip4_route`），彻底排除 SLIRP 干扰——测的就是 API 层深度本身。计时用 `esp_timer_get_time()`（µs 级）。

### 实验 a：调用链成本标定（socket vs netconn）

方法：客户端与服务端各起两套——socket 版（`sockets.c` + echo server）与 netconn 版（`api_lib` 直调 + 对称 echo server），端口 9001/9002。每组配置跑 3 轮：

- **64B RTT**：每轮 150 次一发一收严格 ping-pong，报告平均往返耗时；
- **吞吐**：每轮 24 组 × (3 块 × 1460B) 的**有界流水线**（每组在途 4380B < 默认 SND_BUF 5760B）。第一次设计成 20 块连续直灌时发生了教科书级的全双工互锁：单向压 29.2KB 的同时对方回显反向灌满我方接收窗口，两端 send/recv 互相等死（等待 110 秒无输出，`timeout` 截停）——这正是 16.2 水位小节的活教材，改为流水线后消除。

同一份二进制前后多次开机验证（宿主机并行构建负载波动会让绝对值整体漂移，但相对序每轮不变）。代表性一次运行的原文摘录：

```text
===== PHASE A: layering cost =====
[A-rtt-sock] begin (64B x 150 x 3 rounds)
[A-rtt-sock] round1 avg=986.2 us/RTT
[A-rtt-sock] round2 avg=969.5 us/RTT
[A-rtt-sock] round3 avg=645.4 us/RTT
[A-rtt-netconn] begin (64B x 150 x 3 rounds)
[A-rtt-netconn] round1 avg=485.5 us/RTT
[A-rtt-netconn] round2 avg=1416.6 us/RTT      ← 宿主机抖动离群轮（多次运行均偶发）
[A-rtt-netconn] round3 avg=525.3 us/RTT
[A-thput] socket client <-> socket echo server:
[A-thput-sock] round1 102KB in 139932 us -> 6.01 Mbit
[A-thput-sock] round2 102KB in 72870 us -> 11.54 Mbit
[A-thput-sock] round3 102KB in 84558 us -> 9.95 Mbit
[A-thput] netconn client <-> netconn echo server:
[A-thput-nc] round1 102KB in 66789 us -> 12.59 Mbit
[A-thput-nc] round2 102KB in 73326 us -> 11.47 Mbit
[A-thput-nc] round3 102KB in 85327 us -> 9.86 Mbit
```

跨启动汇总（三次完整开机；剔除各轮第 1 轮预热与两个明显离群轮（1416/1113 µs）后，每场开机取 r2/r3 同轮位对比）：

| 指标                | socket 栈       | netconn 栈      | socket 相对开销                      |
| ------------------- | --------------- | --------------- | ------------------------------------ |
| 64B RTT（稳定区间） | 465 ~ 969 µs    | 340 ~ 525 µs    | +23% ~ +54%（同场配对，典型约 +40%） |
| 105KB 回显吞吐      | 6.0 ~ 15.3 Mbit | 9.9 ~ 18.2 Mbit | 低约 7% ~ 22%（高噪声轮次偶见持平）  |

解读：

1. **净排序在每一轮、每一次开机都成立**：RTT 上 netconn 更快，吞吐上 netconn 更高。附加的一层 = 每次 `send/recv` 多走一段 VFS 包装 + `sockets[]` 查表 + errno 事务 + pbuf→用户缓冲的一次 memcpy（16.1 已引 `pbuf_copy_partial` 源码）；64B 小包场景这些固定摊销占比最大，所以差距在 RTT 维度上最刺眼。
2. 测量口径与第 10 章不同：**ch10 的 raw/netconn/socket 102.9/214.8/287.6µs 走的是 SLIRP 外网 UDP、64B datagram；本章是 127.0.0.1 回环 TCP 流**。两者绝对值不可换算，相对序却互相印证——「越接近 core 越快」。系列建议读者记住的三档量级：**raw ≈ 0.4x · netconn ≈ 0.7x · socket ≈ 1.0x**（以 socket 为基准）。
3. SLIRP/宿主机负载是 QEMU 平台最大的噪声源：同样二进制在不同时段绝对值漂移可达 ±50%，比较任何两组数字必须同一场开机。

### 实验 b：VFS 集成验证

流程：四个服务任务先建立（socket echo @9001 打印其 listen fd），随后主任务发起一条 socket 连接并依次检验 fd 值域、fstat 类型、POSIX read/write、双连接 poll、FIONREAD。真实输出：

```text
[VFS] listen fd=54 (expect >= LWIP_SOCKET_OFFSET)
===== PHASE B: VFS integration =====
[B] ==== VFS integration checks ====
[B] client fd=57 (>=54? yes), FD_SETSIZE=64
[B] fstat(fd) rc=0 mode=0xc000 S_IFSOCK? yes
[B] POSIX write()->15 read()->15 echoed="vfs-posix-write"
[B] poll(nready=3): [fd=57 revents=0x9 POLLIN?1 POLLOUT?1] [fd=59 revents=0x8 POLLIN?0 POLLOUT?1]
[B] ioctl(FIONREAD) on fd=57 -> rc=-1 avail=-1 errno=88 (LWIP_SO_RCVBUF gated)
[B] done
```

逐行兑现本章承诺：

1. **fd=54 起、client fd=57**：三个监听者吃掉 54/55/56（netconn server 不占 fd！），第四个可用槽正落在 57——`alloc_socket = i + 54` 的直接现场证据。
2. **fstat 报 S_IFSOCK（mode 0xc000）**：libc `stat` 系统能正常把 socket 当文件描述，正是 fstat_p 挂进 VFS 的意义。
3. **write()/read() 直接吃了 socket**：与 `int c = socket(...)` 的调用方视角完全一致，任何遗留的「lwip_write 才是真名」的执念都可以放下了。
4. **poll 现场抓包 nready=3**：fd57 命中 POLLIN|POLLOUT 两个维度（0x9），fd59 命中 POLLOUT（0x8），`2+1=3`——精确演示了 esp_libc 仿真层的计数口径；判断“是否有事发生”请永远只认 `revents`。
5. **FIONREAD 默认阵亡**：errno 88 (ENOTSOCK) 的兜底分支完美示范“错误码会说谎”。

### 实验 c：故障注入·fd 耗尽

前置状态刻意贴近真实服务进程：保持 4 个长命服务任务在运行。循环 `socket()` 直到失败，然后 close 一个槽位并立即重扫回收延迟：

```text
===== PHASE C: fd exhaustion =====
[C] ==== fd exhaustion ====
[C] #1 socket() ok fd=57
[C] #2 socket() ok fd=58
[C] #3 socket() ok fd=59
[C] #4 socket() ok fd=60
[C] #5 socket() ok fd=61
[C] #6 socket() ok fd=62
[C] #7 socket() ok fd=63
[C] #8 socket() FAIL errno=23 (ENFILE=23 EMFILE=24)
[C] #9 retry socket() FAIL errno=23
[C] #10 retry socket() FAIL errno=23
[C] #11 retry socket() FAIL errno=23
[C] closing last slot fd=63 ...
[C] after close, socket() again OK fd=63, failed_attempts_before=0, delta=157 us
[C] cleanup 7 fds, done
```

收获四条硬结论：

1. **上限数字终于对上了**：`NUM_SOCKETS=10`，现场已有 3 个监听 socket 占据 54/55/56，因此干净可分配槽恰为 **7 个**——第 8 次 `socket()` 亲手砸出 ENFILE。批注 Batch 3 “第 16 个 socket ENFILE”：当年进程隐含占用了更多槽位，公式 `max_fds = NUM_SOCKETS − busy_slots` 不变量从未改变。
2. **fd 序列终结于 63**：`54+10-1=63`，恰好等于 FD_SETSIZE-1；想要更多 socket 必须同时动 `CONFIG_LWIP_MAX_SOCKETS` 并接受 LWIP_SOCKET_OFFSET 公式带来的新号段（Kconfig help 明示 >61 要重定义 FD_SETSIZE）。
3. **连续重试不掉坑也不消耗**：#9~#11 稳定 ENFILE 而不是 EMFILE/ENOMEM 轮换——失败路径在 netconn_delete 清理后才返回，无泄漏。
4. **close → 槽位回收近乎同步**：`failed_attempts_before=0`，close 返回后立刻的第一次 `socket()` 就成功（delta≈157µs 只是 socket() 本身成本）。原理：`lwip_close` 内部的 `netconn_delete` 通过 do_delconn 与 tcpip_thread 完成握手才释放槽位，调用者是阻塞等结果的；全堆化 IDF 不会留下老式 memp 池的异步撕裂。ch1 时代“瞬时撞顶”感受的真实成因更可能是 listen backlog 或 TIME_WAIT 挤占了 PCB 而**不是 fd 槽**——两层限额别混淆。

### 实验 d：故障注入·阻塞 recv 的窒息

silent server（@9004 只 accept 不回发）制造死寂连接。四种处境逐一实测（同一份日志摘录）：

```text
[D1-block] task blocking in recv(fd=57) forever...
[D1-close] another task calls close(fd=57) ...
[D1-block] recv RETURNED n=-1 errno=128 (Socket is not connected)
[D1-close] worker woke, close->wake latency=300 us
[D2-timeo] setsockopt(SO_RCVTIMEO,1500ms) rc=0
[D2-timeo] recv#1 -> -1 errno=11 elapsed=1498 ms
[D2-timeo] recv#2 -> -1 errno=11 elapsed=1499 ms
[D2-timeo] recv#3 -> -1 errno=11 elapsed=1499 ms
[D3-nonblock] O_NONBLOCK armed (F_GETFL=0x2)
[D3-nonblock] recv#1 -> -1 errno=11 elapsed=124 us
[D3-nonblock] recv#2 -> -1 errno=11 elapsed=63 us
[D3-nonblock] recv#3 -> -1 errno=11 elapsed=32 us
[D4-select] silent server, waiting 2 x 2s ...
[D4-select] #1 -> 0 elapsed=2002 ms
[D4-select] #2 -> 0 elapsed=2009 ms
[D4-select] with pending echo data -> 1 elapsed=461 us (immediate=YES)
```

对照读法（三次开机延时均在同一量级，逐项可复现）：

| 逃生方式          | 实测成本                            | 返回语义              | 适用面                                                  |
| ----------------- | ----------------------------------- | --------------------- | ------------------------------------------------------- |
| 干等（对照组）    | ∞（16.4 窒息机理）                  | 永不返回直至出错入箱  | 反模式                                                  |
| SO_RCVTIMEO=1.5s  | **1498~1499 ms/次**（超时精度极好） | -1 / errno 11         | 周期性心跳最友好；缺点是对每个 fd 生效一个值            |
| O_NONBLOCK 自旋   | **32~124 µs/次**                    | -1 / errno 11         | 低延迟轮询；空转烧 CPU，通常配合 vTaskDelay             |
| select(timeout)   | **2002~2009 ms** 精确归零           | 0（超时）/ >0（就绪） | 多 fd 盯梢；醒来只需 µs 级（回环到货路径 461µs 即返回） |
| 跨任务 close 解救 | **300µs（另两轮 455/884µs）**       | -1 / errno 128        | 救火专用道；IDF FULLDUPLEX=1 保证这是定义良好的行为     |

几个值得咀嚼的点：

1. **errno 128 的正确打开姿势**：worker 醒来拿到的不是 EBADF 也不是 EINTR，而是 ENOTCONN(128)。机制（源码坐实）：跨线程 `close()` 在 FULLDUPLEX 下走 `netconn_prepare_delete → lwip_netconn_do_delconn → netconn_mark_mbox_invalid()`，后者按 `mbox_threads_waiting` 计数向 recvmbox trypost 等量的 `&netconn_deleted` 哨兵指针；睡眠中的 `netconn_recv_data` 取到哨兵（MBOXINVALID 已置位）即返回 `ERR_CONN` → errno 128。别忘了各工具链编号差异（16.5 所述）。
2. **close→wake 300~900µs 曲折在哪**：两次跨核/跨优先级调度（coordinator→tcpip_thread 处理 delconn→worker 醒）＋一次邮箱进出，微秒量级完全符合 16.1 的链路账单。
3. **select 的两副面孔**：无人喂数据时它是最守时的看门狗（2002ms≈2000ms 目标）；一旦真有事发生又是最快的哨兵（461µs 就绪回报）。它是「多路 + 有界等待」的正确组合拳。
4. 生产建议组合：**服务外圈 select/poll 带时限、业务读用短 SO_RCVTIMEO、永不调用无限期阻塞 recv**；跨任务 close 仅作为摘除僵尸连接的最后手段，并依赖 IDF FULLDUPLEX 保证。

---

## 16.8 小结

- 三层真相：应用写 POSIX → libc/VFS 按号段分派（socket 在 [54,64)）→ `lwip_*` 包装 BSD 语义 → netconn 把请求打包成 `struct api_msg` 经 `tcpip_send_msg_wait_sem` 投递 → `tcpip_thread` 执行 `do_*` 唯一真正触碰 PCB。等待方只有应用线程自己（TLS 信号量 = 应答回执，`LWIP_NETCONN_SEM_PER_THREAD=1`）。
- netconn 是 PCB 遥控器 + 两个邮箱（recvmbox/acceptmbox，深度 `CONFIG_LWIP_TCP_RECVMBOX_SIZE` 默认 6）+ 事件回调指针；`do_recv` 就是`tcp_recved` 的内核侧马甲，读后扩窗发生在用户态拷贝之后。TCP 消费速度、窗口、mbox 深度三位一体，mailbox 满对 UDP 是静默丢包、对 TCP 是反压。
- 水位分家：`TCP_SNDLOWAT/SNDQUEUELOWAT`（默认公式给出 2880B）只喂养 `NETCONN_EVT_SENDPLUS`，也就是 **socket 层可写判定**；netconn 写路径从不看它。`TCP_SNDLOWAT 只影响 socket 可写`由此实锤。
- fd = 数组下标 + `LWIP_SOCKET_OFFSET = FD_SETSIZE(64) − CONFIG_LWIP_MAX_SOCKETS(10) = 54`；号段宽度即槽数。POSIX `read/write/close/fstat/fcntl/ioctl` 全部经 `vfs_lwip.c` 六函数表进入 lwIP；`poll()` 是 esp_libc 的 select 仿真而非 lwIP 原生 `lwip_poll`；select 则直接借道原生 `lwip_select`。
- 阻塞 recv 的生死簿写在 recvmbox 上：pbuf 入箱或错误哨兵入箱之外无解；逃生的性能阶梯是 O_NONBLOCK(几十µs) < select(醒来µs级/值守ms级精确) < SO_RCVTIMEO(per-call 精确) < 永远阻塞(危险)；跨任务 close 解救（FULLDUPLEX 功劳）仅需数百µs 并送回 errno 128。
- 错误账本三条铁律：ENFILE(23) 是 lwIP 唯一的“槽数爆了”信号（EMFILE 缺席、ENOSPC 只管 inet_ntop、EPIPE 根本不存在）；`err_to_errno` 十七格表照抄即可；兜底分支会用 ENOTSOCK(88) 说谎，先查配置。
- Vanilla 与 IDF 的改造哲学差异浓缩在一个点上：**编译期改名换成运行期注册表**，加上 per-thread semaphore 与 FULLDUPLEX 两个强制开启的多线程强化，socket 层成为 IDF 改造力度仅次于 hooks 的板块。

到这里，**Part IV「顺序 API 与操作系统接口」正式收官**：第 14 章 sys_arch、第 15 章 raw 回调、本章 socket/VFS——三种编程界面在同一颗单线程核心上的三维投影已经全部画完。raw 最快但要自管状态机，netconn 是平衡木，socket 最舒适也最贵——而 comfort 从来不是免费的，本章把它标价到了微秒。

Part V 进入移植篇：下一次不再是拆 lwIP 自己的房间，而是给它搬家具——[[2026-08-26-lwip-deep-dive-ch17-ethernetif-porting-guide|第十七章《ethernetif 移植指南》]]将从那张空白的 `struct ethernetif` 出发，讲清楚 `low_level_init/output/input` 三件套如何把任意 MAC 拽进 lwIP 的世界，也将顺手回答本章留的一个悬念：openeth 驱动的接收路径到底站在这次时序图的哪一格。
