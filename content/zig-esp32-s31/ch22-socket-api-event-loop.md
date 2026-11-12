---
title: "Zig × ESP32-S31 全栈开发（二十二）：Socket API 与事件循环"
date: 2026-12-08 18:00:00
description: "从「有 TCP 状态机」到「应用能写代码」：固定上限 FD 表为什么比分配器更适合裸机、非阻塞返回值就是接口契约（EAGAIN 不是错误）、poll 的水平触发与就绪集语义、轮转起点如何避免饥饿、为什么本章一个时钟中断都不用（MIE=0）、连接池的上限与两种踢出策略、部分读写与背压的三层链、以及 EAGAIN/EINTR/ECONNRESET 在无中断裸机上的等价物。全部结论来自注入报文的自检，不含任何真链路断言。"
tags: [zig, esp32-s31, riscv, socket, event-loop, poll, nonblocking, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 上一章：[[ch21-tcp-congestion-throughput|第二十一章：TCP 拥塞控制与吞吐]]
>
> **本章：第二十二章：Socket API 与事件循环**
>
> 下一章：[[ch23-tls-http|第二十三章：TLS 与 HTTP]]

# Zig × ESP32-S31 全栈开发（二十二）：Socket API 与事件循环

前四章（ch18–ch21）把一条 TCP 连接在协议内部该有的东西做完了：IPv4 的
报头与校验、TCP 状态机与重传、拥塞窗口与 RTO。到这里，协议栈"自己"已经
能工作了——如果它愿意的话。

但应用写不了代码。应用没有办法对着一个 `tcb` 结构体说"帮我读 100 字节"，
也没办法问"这两个连接里哪个先来数据"。**协议机制和应用可用之间隔着三层
接口**，这三层就是本章的全部内容：

| 缺口                  | 应用需要的东西                   | 本章交付                                     |
| --------------------- | -------------------------------- | -------------------------------------------- |
| 没有句柄              | 一个整数，能存进数组、能当学号用 | `max_fds = 8` 的固定 FD 表（`socket.zig`）   |
| 没有返回值契约        | "现在能不能读"必须是可判断的布尔 | `Io{ n, err }` 与 7 个 errno（`socket.zig`） |
| 没有"同时等 N 个连接" | 一次系统调用回答"谁准备好了"     | `poll` + 就绪集 + 超时轮（`event.zig`）      |

罗列出来像是三件小事，但每一件都有"教科书没写、上板才炸"的细节：

- FD 表为什么必须是固定数组而不是"按需长"的链表或堆分配；
- `EAGAIN` 为什么**不是错误**，以及为什么把它当错误处理的代码一定会
  在真机上丢连接；
- `poll` 是水平触发还是边缘触发，这个选择如何决定"应用可以忘记什么、
  不能忘记什么"；
- 一个 `MIE = 0`（关中断）的裸机程序里，"超时"到底从哪里来；
- 连接池满了以后，拒绝新连接和踢掉最旧的一条，哪个更像在骂用户。

本章把它们逐个钉死，并且**每一条都有板侧判据**。判据不依赖网卡：
所有段由 `netstub` 造出来、直接投给 socket 层，所有 tick 由自检注入。

> [!warning] 证据边界（重要）
>
> 本章**没有真实链路**。ch17 的以太网驱动尚未闭环（DMA 软复位超时、
> MDIO 扫不到 PHY、TX 超时，见 `practice/zig-esp32-s31/logs/ch17d-boot.log`），
> 因此本章不可能、也不允许给出任何下列结论：
>
> - "板子连上了服务器"；
> - "真实 socket 可用，能收发 HTTP"；
> - "事件循环驱动了真实连接"。
>
> 本章的全部证据只有两种：
>
> 1. **主机侧**：`zig build test` → `28/28 tests passed`（x86_64 / Zig 0.17.1），
>    覆盖就绪集、超时轮、连接池踢出、部分读写、EAGAIN 等边界；
> 2. **板侧**：同一份模块交叉编译到 rv32、上板跑 12 条自检判据，
>    原始输出在 `practice/zig-esp32-s31/logs/ch22-boot.log`。
>
> 板侧每一段都由注入源投递，**没有任何一字节来自网口**。真实链路上的
> socket 行为要等 ch17 + ch20 + ch21 一起闭环，判据写在 22.12。

---

## 22.1 从"有 TCP 状态机"到"能用"：缺的是哪一层

### 22.1.1 协议内部视角与应用视角

ch20 结束时，协议栈内部的写法大概是这样：

```text
收到一段 → 解析首部 → 查 tcb 表（key = 四元组） → 按状态迁移
        → 数据进接收队列 → 回 ACK → 必要时触发重传定时器
```

这段代码对"协议"完全正确，对"应用"完全不可用。应用关心的是另一组问题：

| 应用想问的                 | 协议内部能回答吗                     |
| -------------------------- | ------------------------------------ |
| "我的连接是几号？"         | 不能：四元组有 12 字节，还不能当索引 |
| "现在有数据吗？"           | 能，但要读 tcb 内部字段              |
| "能读多少而不阻塞？"       | 不能：没有"阻塞"这个概念             |
| "三个连接哪个先有数据？"   | 不能：这是跨连接的问题               |
| "读到一半对端关了怎么办？" | 能，但语义埋在 `rx_eof` 之类的地方   |

于是协议栈必须再长出一层**门面**（facade）。这层门面在 POSIX 里的名字
是 socket API：`socket` / `bind` / `listen` / `accept` / `connect` /
`send` / `recv` / `close`，外加 `select` 或 `poll` 做等待。

### 22.1.2 三个契约，而不是三组函数

把函数名抄全很容易，难的是**每个函数的返回值契约**。本章把契约拆成三块，
每块都是独立的、可单独测试的东西：

1. **句柄契约**：fd 是 `[0, max_fds)` 的整数索引。合法 fd 一定指向一个
   开着的槽位；关闭后同一编号可能被复用（POSIX 允许，测试里专门验）。
2. **返回契约**：一次调用有且只有四种结局——完成一部分、完成全部、
   现在不能完成（`.again`）、不能完成且以后也不能（其它 errno）。
   应用只需要按这四种分别写代码。
3. **等待契约**：`poll` 回答"注册的这些 fd 里，现在哪些可读/可写"。
   它不回答"多久之后"，那是超时轮的事；它也不回答"发生了什么事件"，
   因为本章不支持边缘触发。

### 22.1.3 为什么"阻塞"这条路在本系列走不通

POSIX 的阻塞 socket 是这么工作的：`recv()` 在没数据时**把线程挂起**，
等数据到了由内核唤醒。这要求两样东西：

- 一个调度器（能挂起/恢复上下文）；
- 一个能打断当前执行的机制（中断或自愿让出）。

本章的形态 B 两样都没有：`mstatus.MIE = 0`、`mie = 0`、没有 TCB、
没有抢占（ch10/ch11 的调度器没有被本章引用）。所以本章只实现**非阻塞 +
事件循环**这一种组合，`Socket.nonblocking` 字段恒为 `true`，它存在的意义
是把"契约的一部分"打印出来而不是真的可切换。

这不是妥协，而是这类设备的主流写法：一个 while 循环 + 一张注册表，代码量
是阻塞版的三分之一，且没有栈切换、没有锁（ch12 的临界区在这里完全用不上）。

### 22.1.4 本章的最小可用集合

| 能力     | 本章实现                                    | 不做                    |
| -------- | ------------------------------------------- | ----------------------- |
| 句柄     | `Table.alloc/listen`，索引即 fd             | fd 继承、`dup`、`fcntl` |
| 建立连接 | 注入 SYN/ACK → `established`（服务端方向）  | 真实的 SYN 发送与重传   |
| 接受连接 | `accept` + backlog 深度 4 + 池上限 4        | 多 listener、`SO_REUSE` |
| 读       | `recv`：部分读、EOF、EAGAIN                 | `MSG_PEEK`、带外数据    |
| 写       | `send`：部分写、背压、EAGAIN                | 发送队列、`TCP_NODELAY` |
| 关闭     | `close`：`fin_wait_1` / `last_ack` 两条路径 | `shutdown(SHUT_WR)`     |
| 等待     | `poll`：注册表 + 就绪集 + 轮转公平          | `select`、`epoll`       |
| 超时     | 相对 tick 的 8 槽超时轮                     | 真实时钟源              |
| 连接上限 | fd 表 8、backlog 4、连接池 4，三处计数      | 动态扩缩                |

---

## 22.2 FD 表与套接字对象：固定上限为什么是优点

### 22.2.1 "索引即 fd"

`src/socket.zig:119` 起的 `Socket` 是一个**内联缓冲**的结构体：接收
环形缓冲、发送环形缓冲、backlog、计数器全在它自己内部，没有指向外部
内存的指针。整个表就是：

```zig
pub const Table = struct {
    socks: [max_fds]Socket = @splat(.{}),
    // 全局计数
    connects: u32 = 0,
    backlog_drops: u32 = 0,
    fd_exhausted: u32 = 0,
    ignores: u32 = 0,
    spawn_token: u32 = 0,
};
```

（节选自 `src/socket.zig:359`，注释略。）

`fd` 就是这个数组的下标。于是：

- `Table.get(fd)` = 下标检查 + `state.isOpen()`，两次比较；
- 没有句柄表查找、没有哈希、没有"fd 到对象"的映射层；
- 表可以被整体搬动（没有自引用指针），所以能作为 `.bss` 里的一个变量存在。

### 22.2.2 三个尺寸从哪来

```zig
pub const max_fds: usize = 8;     // 1 个 listener + 7 条连接
pub const rx_cap: usize = 256;    // 两段 128 字节载荷 + 部分读的余量
pub const tx_cap: usize = 1024;   // 背压演示：待发 3 KiB 时只收 1 KiB
pub const backlog_cap: usize = 4; // 未 accept 的连接队列
```

（`src/socket.zig:34-42`。）

每个尺寸都不是拍脑袋：

- `max_fds = 8`：连接池上限是 4，加一个 listener，再留三个空位给
  "刚 accept 还没入池 / 刚关闭还没复用"的过渡态。**表容量必须大于池容量**，
  否则"池拒绝新连接"这条路径根本走不到——fd 表会先满。
- `rx_cap = 256`：`netstub` 单段载荷上限 128 字节，两段正好 256；
  判据 ⑪ 注入 200 字节后分两次读，一次 100、一次 100，第三次 EAGAIN。
- `tx_cap = 1024`：判据 ⑥ 的输入是 3072 字节（= 3 × 1024），
  这样"接受 1024、剩下 2048 还在调用方手里"的数字最直观。
- `backlog_cap = 4`：与池同宽，便于解释"两次上限"的区别（见 22.6）。

### 22.2.3 内存账本

`sizeof(Socket)` 的主要项（本机 `@sizeOf` 实测 **1360 字节**）：

| 字段         | 字节 |
| ------------ | ---: |
| `rx_buf`     |  256 |
| `tx_buf`     | 1024 |
| `backlog[4]` |    4 |
| 计数器与状态 |  ~60 |
| 对齐填充     |  ~16 |

8 × 1360 B = 10 880 B，整张表 `@sizeOf(socket.Table) = 10904` 字节
（含四个全局计数器与对齐）≈ **10.6 KiB**，全部在 `.bss`。链接脚本给 SRAM
的长度是 `0x7AFC0` = **503 744 字节（约 492 KiB）**（`linker/s31.ld` 的
`sram` 段，`:38`），这张表占约 **2.2%**。主栈 16 KiB
（`_stack_size = 0x4000`，`linker/s31.ld:116`）在 SRAM 末尾，两者不重叠
——链接期有 `ASSERT(_bss_end <= _stack_bottom)` 兜底。

**这张表绝不能放栈上。** 放上去会怎样？`main → selftest.run → runChecks`
的帧里多出 10.9 KiB，加上 `g_out`（就绪集）、`g_payload`（3 KiB）之类，
直接越过 `_stack_top`（0x2F07AFC0）。表现不是"结果不对"，而是
`rst:0x1a CPU_LOCKUP_RESET` 或者一个莫名其妙的 `store access fault`。

所以 `src/selftest.zig:37` 起是文件作用域变量：

```zig
var g_tbl: socket.Table = .{};
var g_lp: event.Loop = .{};
var g_out: event.ReadySet = .{};
var g_payload: [3 * 1024]u8 = undefined;
```

### 22.2.4 固定上限换来了什么

| 性质       | 固定数组                   | 动态分配                   |
| ---------- | -------------------------- | -------------------------- |
| 失败路径   | 只有"表满"，返回 `?u8`     | 每次分配都可能 OOM         |
| 地址       | 编译期恒定，`objdump` 可见 | 运行期浮动                 |
| 碎片       | 不存在                     | 长时间运行必然面对         |
| 最坏耗时   | 常数次比较                 | 分配器不可预测（可能合并） |
| 可观测     | `openCount()` 一数就知道   | 要问分配器                 |
| 上限从哪来 | 代码里的一行常量           | 通常是猜的                 |

对一个 8 连接就够用的设备来说，最后一行是决定性的：上限写在代码里、
写在注释里、写在自检判据里，而不是"取决于堆还剩多少"。

lwIP 走的是同一条路：`MEMP_NUM_NETCONN` 默认 4（`opt.h:525`），
ESP-IDF 把它改成跟随 `CONFIG_LWIP_MAX_SOCKETS`
（`components/lwip/port/include/lwipopts.h:124`），而后者在
`components/lwip/Kconfig:137` 里默认 10、范围 1–253。也就是说：**即使是
跑在 16 MB PSRAM 上的 IDF，socket 数量的默认值也是个位数到十位数**，
不是"能开多少开多少"。

### 22.2.5 槽位复用与指纹

关闭一个槽位后，下一个 `listen()` 会拿到同一个编号——主机侧用例
`FD 表：关闭的槽位被下一个 listener 复用` 钉住了这一点。这是 POSIX 允许
的行为，也是"索引即 fd"的必然结果：

```text
a = listen()  -> 0
b = listen()  -> 1
close(a)      -> 槽位 0 变 closed
c = listen()  -> 0   （复用）
```

代价是：应用不能把"fd 编号"当成"连接身份"长期保存。真实 POSIX 也一样
（关闭后同一个编号可能被新连接占用），所以正确的做法是在应用层分配一个
自己的连接序号——本章的 `accept_token` 就是这个角色（22.6 用它挑最旧的
连接）。

`Table.fingerprint()`（`src/socket.zig:512`）把 8 个槽位的状态、缓冲长度
和四个全局计数器混成一个 32 位 FNV-1a 值。它的用途只有一个：**重放判据**
——同一串注入脚本跑两遍，指纹必须相同。本章板侧打印：

```text
sim: netstub segs=3 payload=5 hash=0x52816f06 replay=0x52816f06 equal=1
```

这行不是判据（`checks:` 只汇总 12 条），但它是"确定性"的直接证据。

---

## 22.3 阻塞 vs 非阻塞：返回值就是接口契约

### 22.3.1 四种结局

本章的每次 I/O 调用都返回同一个结构（`src/socket.zig:97`）：

```zig
pub const Io = struct {
    n: usize = 0,
    err: Errno = .ok,
};
```

`n` 与 `err` 的组合恰好覆盖四种结局：

| 结局                 | 表示              | 应用该做什么                   |
| -------------------- | ----------------- | ------------------------------ |
| 全部完成             | `err=.ok, n=len`  | 继续下一步                     |
| 部分完成             | `err=.ok, n<len`  | 立即处理未完成的部分（不必等） |
| 现在不能完成         | `err=.again, n=0` | 去 `poll` 等可读/可写，别忙等  |
| 不能完成且以后也不能 | 其它 errno        | 收掉连接、记录、释放应用侧状态 |

**第三行是整章的核心。** `EAGAIN` / `EWOULDBLOCK` 在 POSIX 里是 errno，
但它不是"错误"——它是"还没到时候"。把它当错误处理的代码会这样坏掉：

```text
recv() -> EAGAIN
应用：记录错误、关闭连接   ← 一个正常的空连接被当成异常
```

正确写法是把 `.again` 当作正常分支：

```zig
switch (sock.recv(buf)) {
    .err = .ok, .n = 0 => { /* EOF：对端关闭 */ },
    .err = .ok, .n = n => { /* 处理这 n 字节 */ },
    .err = .again => { /* 等到 poll 说可读再来 */ },
    else => |e| { /* 真正的错误 */ },
}
```

### 22.3.2 `recv` 的语义分层

`src/socket.zig:269`：

```zig
pub fn recv(self: *Socket, dst: []u8) Io {
    if (self.state == .closed and !self.reset_seen) return Io.fail(.bad_fd);
    if (self.reset_seen) return Io.fail(.conn_reset);
    if (!self.state.canIo()) return Io.fail(.not_conn);
    if (self.rx_len > 0) {
        const n = self.rxPop(dst);
        self.recv_bytes += @intCast(n);
        self.rcv_nxt +%= @intCast(n);
        return Io.ok(n);
    }
    if (self.rx_eof) return Io.ok(0);
    self.again_count += 1;
    return Io.fail(.again);
}
```

判断顺序不是随意的：

1. **先看 fd 是否还存在**（`bad_fd`）——否则后面的状态判断没有意义；
2. **再看 RST**（`conn_reset`）——它**优先于缓冲里残留的数据**。
   理由：对端发 RST 意味着"这段连接废了"，让应用先读完旧数据再报错，
   等于让应用拿过期正文去做业务决策。真实 TCP 也有"RST 丢弃未读数据"
   的行为；
3. **再看状态**（`not_conn`）——listener 上不能 `recv`，`syn_sent` 也不行；
4. **有数据就搬**（可能少于请求长度）；
5. **已 EOF 返回 `ok(0)`**——POSIX 的"读到 0 字节 = 对端关闭"；
6. **最后才是 `.again`**，并计数 `again_count`。

`again_count` 是可观测性的一部分：判据 ③ 打印 `again_count=1`，说明
"这一次确实走了 EAGAIN 分支"，而不是碰巧拿了别的原因返回 0。

### 22.3.3 `send` 的语义分层

`src/socket.zig:289`：

```zig
pub fn send(self: *Socket, src: []const u8) Io {
    if (self.state == .closed and !self.reset_seen) return Io.fail(.bad_fd);
    if (self.reset_seen) return Io.fail(.conn_reset);
    if (!self.state.canIo()) return Io.fail(.not_conn);
    if (src.len == 0) return Io.ok(0);
    if (self.tx_len >= tx_cap) {
        self.again_count += 1;
        return Io.fail(.again);
    }
    const n = self.txPush(src);
    self.sent_bytes += @intCast(n);
    self.snd_nxt +%= @intCast(n);
    return Io.ok(n);
}
```

`send` 比 `recv` 多一个细节：**发送缓冲完全满时返回 `.again`（一个字节
也没搬），没满时尽量搬、搬多少算多少**。这两条规则不能混：

- 若"没满也返回 again"，应用会以为连一个字节都没写进去，重复发送会导致
  数据重复（真实 TCP 里就是流错位）；
- 若"满了也返回部分成功"，应用会以为还有空间，下一次调用会拿到 0 ——
  但"0 字节发送成功"在 POSIX 里没有定义（`send` 返回 0 才是错误）。

### 22.3.4 与 lwIP 的对照

lwIP 的 netconn 层是同一套思路，只是错误码换成了负数：

| 本章           | lwIP                                     | POSIX                    |
| -------------- | ---------------------------------------- | ------------------------ |
| `.again`       | `ERR_WOULDBLOCK = -7`（`err.h:69`）      | `EAGAIN` / `EWOULDBLOCK` |
| `.bad_fd`      | `ERR_CLSD` / `ERR_ARG`                   | `EBADF` / `ENOTSOCK`     |
| `.not_conn`    | `ERR_CONN`                               | `ENOTCONN`               |
| `.conn_reset`  | `ERR_RST`                                | `ECONNRESET`             |
| `.pool_full`   | （`socket()` 返回 `-1`，`errno=ENOMEM`） | `EMFILE`                 |
| `.in_progress` | `ERR_INPROGRESS = -5`                    | `EINPROGRESS`            |

非阻塞语义的落点在 `api_lib.c:505`：

```c
if (netconn_is_nonblocking(conn)) {
    if (sys_arch_mbox_tryfetch(&conn->acceptmbox, &accept_ptr) == SYS_MBOX_EMPTY) {
        ...
        return ERR_WOULDBLOCK;
    }
}
```

`tryfetch` 不等待、失败立刻返回——这就是 `EAGAIN` 的来源。注意 lwIP 的
netconn 是**带 mailbox 与信号量的**，它的"非阻塞"建立在 `LWIP_NETCONN`
的 API 事件机制上（`api.h:161-176` 的 RCVPLUS/RCVMINUS 计数，下一节还会
用到）；本章没有 mailbox，就地把"能不能立刻返回"算成两个布尔判断。

---

## 22.4 `poll` 语义：水平触发、就绪集、单 tick 开销

### 22.4.1 三个数据结构

| 结构       | 谁填        | 内容                                   |
| ---------- | ----------- | -------------------------------------- |
| `PollFd`   | 应用        | `{ fd, events: Mask }`——"我想知道什么" |
| `ReadySet` | `poll` 返回 | `{ items[4], len }`——"现在成立什么"    |
| `Mask`     | 两边共用    | `{ read, write, hup }`                 |

`poll_cap = 4`（`src/event.zig:33`）是一次 tick 的处理预算：就绪项超过 4 个
时，第 5 个起**不返回**（`truncated += 1`），下个 tick 还会出现——因为
就绪状态没有被消费，只是没被报告。

### 22.4.2 水平触发意味着什么

本章**只有水平触发**（level-triggered）：只要条件成立，`poll` 每个 tick
都会报告它。这是裸机上的唯一选择，理由很实际：

- 边缘触发需要"事件队列"来记住"上次到现在之间发生过什么"，
  而队列要内存、要溢出策略；
- 水平触发只需要**当下状态**——`rx_len > 0`、`tx_len < tx_cap`，
  两个比较就够；
- 代价是应用必须自己把条件消掉：读到没有数据为止，或写到缓冲满为止。
  忘记读，就会每个 tick 都拿到同一个 fd，CPU 空转但不"卡死"。

判据 ④ 就是这个语义的直接体现：

```text
check: poll tick write_only=1 read_after_data=1 ready_total=2 ok=1
```

第一行 `write_only=1` 说明：刚建立的连接可写（发送缓冲空）但不可读
（没数据）——`poll` 报告的是一个精确集合，不是"有任何事发生"。

### 22.4.3 就绪的定义只有一处

`poll` 不自己判断"可读"，它调 `Table.readyRead()`（`src/socket.zig:445`）：

```zig
pub fn readyRead(self: *Table, fd: u8) bool {
    const s = &self.socks[fd];
    if (s.state == .listen) {
        if (s.backlog_len == 0) return false;
        const child: u8 = @intCast(s.backlog[0]);
        return self.socks[child].state == .established;
    }
    return s.readable();
}
```

listener 那一支是这一章最容易被忽略的坑。`poll` 对 listener 说"可读"的
含义是"`accept` 不会返回 EAGAIN"；而这件事取决于 **backlog 队首那条
子连接**是否已完成握手——那是**另一个槽位**的状态。只看 listener 自己
的 `backlog_len > 0` 会怎样？判据 ④ 的兄弟用例（主机侧
`poll：就绪集只含真正可读的 fd...`）就是这样抓到的：只投了 SYN 没投 ACK，
就绪集里已经出现了 listener，而应用随后 `accept` 拿到了 `.again`——
**就绪通知与操作结果不一致**，这是事件循环最典型的 bug 形态。

修法不是让 `poll` 特判，而是把"跨槽位"的判断收进一个函数，让
`poll`、`accept`、自检三处都调同一个（板侧判据 ② 与 ④ 因此必然一致）。

### 22.4.4 单 tick 的开销

`Loop.poll`（`src/event.zig:316`）的一个 tick 是：

```text
out.reset()
polls += 1, ticks += 1
begin = start % n
for i in 0..n:                      ← O(n)，n ≤ 8
    reg = regs[(begin + i) % n]
    mask.read  = reg.events.read  && tbl.readyRead(reg.fd)
    mask.write = reg.events.write && s.writable()
    mask.hup   = s.reset_seen || s.state == .closed
    if mask.any() && out.len < 4: 追加
start = (begin + 1) % n
idle_ticks += (out.len == 0)
```

- 注册表长度上限是 `socket.max_fds = 8`，所以一个 tick 最多 8 次
  布尔判断 + 一次缓冲写入；
- 没有分配、没有循环里的函数指针、没有排序（**顺序就是公平性的证据**，
  见 22.4.5）；
- 空 tick 的成本 = 8 次判断 + 一次 `wfi`（如果调用方决定睡）。

板侧判据 ⑩ 用可数的方式钉住"空转"：

```text
check: idle empty_ticks=1000 after_wakeup idle=1000 ready=1 polls=1001 ok=1
```

1000 个空 tick 全部计入 `idle_ticks`；第 1001 个 tick 有数据，
`idle_ticks` 不再增长而 `polls` 变成 1001。"唤醒条件"因此是可观测的：
**注册表里任意一项的 `readable`/`writable`/`hup` 成立**。

### 22.4.5 公平轮转

`start` 每个 tick 前进一格（`self.start = (begin + 1) % n`）。这不是
"负载均衡"，而是**避免饥饿**：如果应用每个 tick 只处理一个就绪 fd
（很常见，一个 tick 的预算就是一次回调），那么永远从下标 0 开始扫的
循环会让后面的 fd 永远排在队首之后——它一直"就绪"，但一直没被处理。

判据 ⑨ 的数字：

```text
check: fair-rotation ticks=8 head_a=4 head_b=4 start=0 ok=1
```

两个常驻可读的 fd、8 个 tick：各当 4 次队首，`start` 转一圈回到 0。
主机侧用例把 `head_a == 4 and head_b == 4` 写成断言，所以"轮转起点前进"
这条性质一旦被改坏（比如把 `start` 忘了），用例立刻红。

lwIP 的 `lwip_pollscan`（`api/sockets.c:2249`）也是**按数组顺序**扫的
（`for (fdi = 0; fdi < nfds; fdi++)`，`:2257`），它把"谁先被处理"交给
应用自己排数组顺序；本章多做一步：起点自己转，应用不用管。

### 22.4.6 `hup` 为什么要独立于注册的事件

即使应用只注册了 `read`，fd 被关闭或对端 RST 时必须告诉它——否则应用会
永远等一个不会再有事件的连接。所以：

```zig
if (s.reset_seen or s.state == .closed) mask.hup = true;
```

这一行与注册的 `events` 无关。应用收到 `hup` 的正确动作是：`recv` 一次
（拿到 `conn_reset` 或 EOF）、记录错误码、关闭连接。板侧判据 ⑫ 走的就是
这条路：

```text
check: peer-rst recv=conn_reset state=closed slot_open=0 ok=1
```

---

## 22.5 超时与 tick：为什么本章一个时钟中断都不用

### 22.5.1 "超时"在没有中断的机器上是什么

POSIX 的 `poll(fds, n, timeout_ms)` 会让内核在超时后唤醒线程。本章的
`poll` 没有 `timeout` 参数——它只处理"现在"。超时是另一件独立的事：

```zig
pub const Timer = struct {
    deadline: u64,   // 绝对到期 tick，now >= deadline 即到期
    fd: u8,
    kind: TimerKind, // retransmit / idle_close / connect_timeout
};
```

（`src/event.zig:107`。）

`Wheel.advance(now, out)`（`src/event.zig:155`）把 `deadline <= now` 的
定时器弹出来。**`now` 是参数，不是从任何寄存器读的**——这就是"注入
tick"的含义：自检传常数，主机测试传常数，未来接上真实时钟时传
`mtime` 换算值。

### 22.5.2 为什么不用时钟中断

本系列 ch07 已经把 CLIC 讲完、ch08 把 TIMG0 讲完，技术上完全可以用
`mtimer` 中断驱动一个 tick 计数器：中断里 `ticks += 1`，主循环读
`ticks` 判断超时。本章刻意**不**这么做，三个理由：

1. **它会破坏"全轮询"的可见性。** 一旦有中断，`Socket` 里每个字段都
   可能被异步改写，所有读写都要考虑临界区（ch12）。本章的所有判据
   都在"没有并发"的前提下成立；加中断等于把每个判据的证明难度乘以二。
2. **它把最坏耗时变成不可测。** 健康检查、看门狗喂狗、串口输出都可能
   在中断里被推迟；`mtvec` 一旦被真实异常命中，栈上多一帧，本章
   80 字节的 trap 帧会变得紧张。
3. **它没有必要。** `poll` 的一次 tick 是 O(8) 次比较（22.4.4），
   主循环跑 1000 个空 tick 的成本远低于一次中断进出。要用"睡"省电时，
   用 `nextDeadline()` 算出最近到期时刻，再 `wfi` 到那一刻即可——
   不需要中断参与。

第 3 点就是 `Wheel.nextDeadline()` 的全部用途（`src/event.zig`）：

```zig
pub fn nextDeadline(self: *const Wheel) ?u64 {
    var best: ?u64 = null;
    var i: usize = 0;
    while (i < self.len) : (i += 1) {
        const d = self.slots[i].deadline;
        if (best == null or d < best.?) best = d;
    }
    return best;
}
```

空轮返回 `null`，含义是"没有任何到期时间，可以无限睡到下一个外部事件"。

### 22.5.3 8 槽线性扫描，不是时间轮

名字叫 `Wheel`，实现是"8 个槽 + 线性扫描"。真正的哈希时间轮在
O(1) 插入/到期上有优势，但：

- 槽位只有 8 个，线性扫描最多 8 次比较；
- 插入/取消的语义更简单（找、删、移动）；
- 不需要"桶指针推进"，也就不会出现"指针走得太快漏了定时器"这类 bug。

容量满时 `insert` 返回 `false` 并 `refused += 1`——**拒绝插入并计数**，
而不是覆盖某个已有定时器。覆盖会让一个正在等重传的 fd 永久卡住。

### 22.5.4 判据 ⑤ 的读数

```text
check: wheel now=2:0 now=3:1(retransmit) now=10:1 fired=2 left=0 ok=1
```

读法：

- `now=2:0`——第二个 tick 之前，一个都不到期；
- `now=3:1(retransmit)`——`now = 3` 时只弹出 `deadline = 3` 那个；
- `now=10:1`——`now = 10` 时弹出第二个；
- `fired=2 left=0`——两个都到期了，轮里剩 0 个。

"注入 now"意味着这个判据**不需要真的等 10 个 tick**——在板子上跑完
整个自检只用了几百微秒（`main` 里最后才 `delayUs(10_000)` 给串口
留时间）。

---

## 22.6 连接池：上限、踢出策略与可观测计数

### 22.6.1 三个"满"是三件不同的事

很多实现把"连接满了"当成一个错误，结果把三种完全不同的情况混在一起：

| 满了的东西            | 本章的返回值                              | 为什么不同                                           |
| --------------------- | ----------------------------------------- | ---------------------------------------------------- |
| FD 表（8 槽）         | `listen()` 返回 `no_fd`，`fd_exhausted++` | 内部资源耗尽，属于**编程错误**（池上限该小于表容量） |
| listener backlog（4） | 丢弃新 SYN，`backlog_drops++`             | 对端还没完成握手，丢掉它代价最小                     |
| 连接池（4）           | `.pool_full`（reject）或踢最旧（evict）   | 已在服务中的连接，取舍要看产品                       |

板侧判据 ⑧ 只打了后两种，第一种由主机用例
`FD 表：容量 8，listen 之后 alloc 一路到满，第 9 个返回 no_fd 并计数` 覆盖。

### 22.6.2 两种策略

```zig
pub const Policy = enum { reject_new, evict_oldest };
```

**`reject_new`（默认）**：池满时 `rejected += 1`，把新连接关掉，应用拿到
`.pool_full`。

- 好处：已在服务的连接绝不被静默中断；被拒的对端会收到 RST/FIN，
  可以重试或报错——**失败是可见的**。
- 代价：一个长时间占着池的慢连接会让新连接一直进不来。

**`evict_oldest`**：挑 `accept_token` 最小的连接，`Table.abort()` 掉，
新连接接管槽位。

- 好处：永远服务最新的请求（对"网页控制台"这类场景合理）。
- 代价：被踢的那条连接的应用层完全不知道发生了什么——除非应用每次
  `recv/send` 都检查 errno，而它在被踢之后只会看到 `bad_fd`。

本章默认拒绝，理由写在代码注释里：**在固定槽位的设备上，悄悄关掉一条
活连接比拒绝新连接更糟**。一份会让用户"页面突然白掉"的固件，比一份
"提示连接数已满，请稍后再试"的固件难排查得多。

### 22.6.3 计数必须齐全

```zig
pub const Pool = struct {
    fds: [pool_cap]u8 = @splat(0),
    len: usize = 0,
    policy: Policy = .reject_new,
    accepted: u32 = 0,
    rejected: u32 = 0,
    evicted: u32 = 0,
    last_evicted_fd: i8 = socket.no_fd,
};
```

（`src/event.zig:206`。）

四个计数分别回答四个运维问题：

| 计数              | 回答的问题                             |
| ----------------- | -------------------------------------- |
| `accepted`        | 一共有多少条连接被接受过（含被踢的）   |
| `rejected`        | 池满拒了多少次——要不要扩大上限？       |
| `evicted`         | 踢出策略触发了几次——踢谁？             |
| `last_evicted_fd` | 最近被踢的是哪条（排障时最有用的一条） |

没有 `rejected` 这个计数，"池是不是太小"就永远是个猜测。

### 22.6.4 准入函数

`src/event.zig:253`：

```zig
pub fn admit(self: *Pool, tbl: *socket.Table, fd: u8) Admit {
    if (self.len < pool_cap) {
        self.fds[self.len] = fd;
        self.len += 1;
        self.accepted += 1;
        return .admitted;
    }
    if (self.policy == .reject_new) {
        self.rejected += 1;
        return .rejected_full;
    }
    // evict_oldest：accept_token 越大越新，所以挑最小者。
    var victim: usize = 0;
    var i: usize = 1;
    while (i < self.len) : (i += 1) {
        const a = tbl.socks[self.fds[victim]].accept_token;
        const b = tbl.socks[self.fds[i]].accept_token;
        if (b < a) victim = i;
    }
    const old = self.fds[victim];
    tbl.abort(old);
    self.last_evicted_fd = @intCast(old);
    self.evicted += 1;
    self.fds[victim] = fd;
    self.accepted += 1;
    return .evicted_then_admitted;
}
```

两个细节：

1. **谁负责关掉被拒的新连接？** `Loop.accept()`（`src/event.zig:357`）：

   ```zig
   switch (self.pool.admit(tbl, child)) {
       .rejected_full => {
           tbl.abort(child);
           return socket.Io.fail(.pool_full);
       },
       else => return socket.Io.ok(child),
   }
   ```

   应用只看到 `.pool_full`，永远拿不到一个"进了池但没被承认"的 fd。
   如果让应用自己关，忘记关就是一次 fd 泄漏——而泄漏在 8 槽的表里
   意味着四次之后就再也接不了新连接。

2. **为什么用 `abort` 而不是 `close`？** `close` 走优雅关闭（`established
→ fin_wait_1`），槽位仍然被占用、还要等对端 ACK 才能真正释放；
   `abort` 直接 `reset()` 回 `closed`，槽位立即可复用。踢出策略的目的
   就是腾位置，用 `close` 会"踢了但还是满"。

### 22.6.5 判据 ⑧ 的读数

```text
check: pool full reject=pool_full rejected=1 evict fd=1 evicted=1 len=4 ok=1
```

一行里同时验证了两条策略：

- `reject=pool_full rejected=1`：第 5 条连接被拒，计数加一；
- 切换策略后：`evict fd=1 evicted=1 len=4`——被踢的是 fd 1（最早被
  accept 的那条，`accept_token` 最小），池长度仍然是 4（新连接接管）。

主机侧还有一条用例专门验证"被踢的 fd 真的不可用了"（`send` 返回
`bad_fd`），防止"踢了但没释放"。

### 22.6.6 与 lwIP 的 accept 语义对照

lwIP 的 `lwip_accept`（`api/sockets.c:666`）背后是 netconn 的 accept
mailbox，它的"有多少次 accept 不会阻塞"是**显式计数**的
（`api.h:171`）：

> They are counted in sockets - three RCVPLUS events for accept mbox means
> you are safe to call netconn_accept 3 times without being blocked.

也就是说 lwIP 用"事件计数"表达本章用 `backlog_len` + 子连接状态表达的
同一件事：**在 accept 之前，你必须知道有几个连接已经握完手**。
本章的 `Table.readyRead()` 就是那个"知道"的入口。

TCP 层的 backlog 在 lwIP 里是可选功能：`TCP_LISTEN_BACKLOG` 默认 0
（`opt.h:1471`），开启后 `TCP_DEFAULT_LISTEN_BACKLOG` 默认 255
（`opt.h:1480`）。本章的 4 是同一个概念的小号版本：队列满就丢 SYN，
让对端自己重试。

---

## 22.7 部分读写与背压

### 22.7.1 为什么 `send` 不"排队到有空间再发"

最简单的实现看起来是：`send(3 KiB)` 时把 3 KiB 全收下，等传输层能发时
再发。这需要两样东西：

- 一个能增长的发送队列（在本章 = 分配器或固定大缓冲）；
- 一个"数据还没真正发出"的语义——应用以为发出去了，其实没有。

本章拒绝这条路：**`send` 只搬得动当前放得下的部分，剩下的还在调用方
手里**。这叫背压（backpressure），它把"内存不够"从"栈内部悄悄丢数据"
变成了"应用必须处理部分写"——一个显式的、可测试的状态。

### 22.7.2 判据 ⑥ 的算术

```text
check: partial-send req=3072 accepted=1024 retry_n=0 retry=again ok=1
```

- `req=3072` = 3 × `tx_cap`（`g_payload` 是 3072 字节，`@memset` 成 0x41）；
- `accepted=1024` = `tx_cap`，一次搬满；
- `retry_n=0` + `retry=again`：立刻再调一次，一个字节也搬不动（缓冲仍满）。

应用的两种正确写法：

```zig
// 写法 A：记剩余，等 writable
var sent: usize = 0;
while (sent < data.len) {
    const io = sock.send(data[sent..]);
    switch (io.err) {
        .ok => sent += io.n,
        .again => break,          // 等 poll 说可写，再继续
        else => return io.err,
    }
}

// 写法 B：拒绝超长请求（HTTP 响应用得多）
if (data.len > sock.txFree()) return error.TooLarge;
_ = sock.send(data);
```

写法 A 是通用的；写法 B 在"响应大小已知且可控"时更简单，但要求应用自己
知道缓冲上限（`txFree()` 就是给它看的）。

### 22.7.3 部分读：`rx_cap` 装不下时

`rxPush` 只搬放得下的字节，**多出来的部分被丢弃在段边界上**（不留在
任何队列里），并且**计入 `rx_dropped`**：`onSegment` 的 data 分支里
`if (seg.payload.len > n) self.rx_dropped += seg.payload.len - n`。
本章的接收缓冲是 256 字节而段最大 128 字节，正常投递永远装得下；
主机侧用例 `背压：接收缓冲 256 字节，超出部分被丢弃并计数（本章无接收
背压）` 故意投递 2 × 200 字节，断言 `rx_len == 256` 且
`rx_dropped == 144`——"装不下就丢"是显式行为，丢弃量也是可读的数字，
不是悄悄发生的事。

**这就是接收方向与发送方向的不对称**：发送方向有背压（`send` 只接受
放得下的部分，剩下的留在应用手里）；接收方向没有背压，只能在缓冲满时
丢数据并计数。真实 TCP 不允许丢（会破坏字节流），它靠三选一解决：给
发送方回更小的接收窗口、丢弃并让对端重传、或把段挂到接收队列上
（ch20 的 `tcp.zig` 里 `Reasm` 用的是第三种：固定槽 + `insert`，`pendingBytes` 报缺口）。本章选"截断 + 计数 + 保持
`rx_len <= rx_cap`"，因为这三种替代都需要 ch20 的窗口与重传机制，
而本章的判据只能覆盖到 socket 层自己的契约。

### 22.7.4 背压的三层

```text
应用缓冲                 tx 缓冲（1 KiB）            传输层（ch20）
   │  send() 搬走一部分       │  drainTx(n) 吃掉 n        │
   ▼                          ▼                           ▼
 剩余数据仍在应用手里      满了 → .again            真的发到链路上
```

三层每一层都必须能"说不"：应用层说"我一次只给一个段的量"、tx 缓冲说
"满了，等可写"、传输层说"拥塞窗口只允许这么多"（ch21）。任何一层允许
无限排队，另一层的反馈就失效了。

### 22.7.5 结果矩阵

| `send` 调用              | `err`         | `n` | 应用动作        |
| ------------------------ | ------------- | --- | --------------- |
| 缓冲空、数据 100 B       | `.ok`         | 100 | 完成            |
| 缓冲剩 300 B、数据 1 KiB | `.ok`         | 300 | 记住 724 B 待发 |
| 缓冲满                   | `.again`      | 0   | 等 `writable`   |
| 对端 RST                 | `.conn_reset` | 0   | 收掉连接        |
| 已关闭的 fd              | `.bad_fd`     | 0   | 应用侧编程错误  |

| `recv` 调用            | `err`         | `n` | 应用动作             |
| ---------------------- | ------------- | --- | -------------------- |
| 缓冲有 200 B、请求 100 | `.ok`         | 100 | 再读一次（还有 100） |
| 缓冲有 200 B、请求 512 | `.ok`         | 200 | 完成                 |
| 缓冲空、未 EOF         | `.again`      | 0   | 等 `readable`        |
| 缓冲空、已 EOF         | `.ok`         | 0   | 关闭连接（正常结束） |
| 对端 RST               | `.conn_reset` | 0   | 记错误、收掉连接     |

---

## 22.8 错误模型：EAGAIN / EINTR / ECONNRESET 的等价物

### 22.8.1 本章的 7 个 errno

```zig
pub const Errno = enum(u8) {
    ok = 0,
    again,        // EAGAIN / EWOULDBLOCK
    bad_fd,       // EBADF
    not_conn,     // ENOTCONN
    conn_reset,   // ECONNRESET
    pool_full,    // EMFILE / ENFILE 的等价物
    in_progress,  // EINPROGRESS
};
```

（`src/socket.zig:73`。）

用 `enum` 而不是负数有三个好处：

1. 不能"顺手返回一个随便的数"——类型系统替你排除；
2. `switch` 的穷尽检查会强制你在加新错误码时改完所有调用点；
3. 打印时 `@tagName` 直接得到可读名字（自检里就是这么打日志的）。

代价是它不能直接传给 C 接口；真要传给 POSIX 代码，用一个
`fn toErrno(e: Errno) std.posix.E` 映射即可（本章不做，因为没有 C 接口
需要喂）。

### 22.8.2 EAGAIN 是"再来一次"，不是"失败"

已经在 22.3 说过一次，这里是它的完整定义：

- `recv` 的 `.again` 意味着"缓冲空且未 EOF"；
- `send` 的 `.again` 意味着"一个字节也没搬，缓冲满"；
- `accept` 的 `.again` 意味着"backlog 空，或者队首还没握完手"。

三种情况下 `again_count` 都会 +1。这个计数的用途是让"我们确实走了这条
路径"变成可打印的事实，而不是从行为反推。

### 22.8.3 EINTR 在本章不存在，但要知道它为什么在 POSIX 里存在

POSIX 的 `poll` 会因为信号中断返回 `EINTR`。Zig 的 `std.posix.poll`
直接把它当"重试"处理（`std/posix.zig:1009` 起）：

```zig
pub fn poll(fds: []pollfd, timeout: i32) PollError!usize {
    ...
    while (true) {
        const rc = system.poll(fds.ptr, fds_count, timeout);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            ...
            .INTR => continue,
            ...
        }
    }
}
```

这段代码值得读两遍：它把 `EINTR` 吞掉并**重新调用 `poll`**——因为
`poll` 的语义允许这样（超时值需要应用自己重算，std 的封装选择了最简单的
"从头再等"）。本章没有信号、没有中断，所以 `EINTR` 这个错误码根本不
存在；但如果你把本章的循环套到带中断的系统上，第一件要做的事就是
**补上这个 `continue`**。

### 22.8.4 ECONNRESET 优先于残留数据

这是本章唯一"宁可丢数据"的地方，理由在 22.3.2 说过：RST 意味着连接
作废，让应用读完旧数据只会让它拿过期内容做决定。判据 ⑫ 特意先投一段
数据再投 RST：

```text
check: peer-rst recv=conn_reset state=closed slot_open=0 ok=1
```

`slot_open=0` 说明槽位确实回收了（`state == .closed`），而不是"报错了但
还占着"。8 个槽位的表里，泄漏四次就再也接不了新连接——这类 bug 在开发
时只表现为"跑久了就不行"。

### 22.8.5 错误码对照表

| 本章           | POSIX         | lwIP                   | 场景                 |
| -------------- | ------------- | ---------------------- | -------------------- |
| `.again`       | `EAGAIN`      | `ERR_WOULDBLOCK = -7`  | 现在不能完成         |
| `.bad_fd`      | `EBADF`       | `ERR_CLSD` / `ERR_ARG` | 槽位空 / 编号越界    |
| `.not_conn`    | `ENOTCONN`    | `ERR_CONN`             | listener 上收发      |
| `.conn_reset`  | `ECONNRESET`  | `ERR_RST`              | 对端 RST             |
| `.pool_full`   | `EMFILE`      | `-1` + `errno=ENOMEM`  | 连接池满且策略是拒绝 |
| `.in_progress` | `EINPROGRESS` | `ERR_INPROGRESS = -5`  | 握手未完成           |
| （无）         | `EINTR`       | （无）                 | 本章没有信号         |

---

## 22.9 工程走读

站内代码浏览（不离开站点看高亮源码）：

| 文件                 | 角色                                                                    | 代码浏览                                                                           |
| -------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`                                    | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界、四条 ASSERT                      | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                               | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/main.zig)       |
| `src/socket.zig`     | FD 表、状态机、`recv/send/close`、就绪判定、部分读写（730 行）          | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/socket.zig)     |
| `src/event.zig`      | `poll` 就绪集、轮转公平、超时轮、连接池两种策略（617 行）               | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/event.zig)      |
| `src/netstub.zig`    | 段线格式（编码/解码）、脚本投递、FNV-1a 指纹（275 行）                  | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/netstub.zig)    |
| `src/selftest.zig`   | 板侧 12 条判据与一行脚本指纹读数                                        | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/selftest.zig)   |
| `src/host_tests.zig` | `zig build test` 的根：只 import 三个纯逻辑模块                         | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/host_tests.zig) |
| `src/hw.zig`         | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                              | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/hw.zig)         |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump（80 字节帧）                              | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/trap.zig)       |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                               | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/src/log.zig)        |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用          | [查看](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/tools/flash.sh)     |

完整工程（入口为工程 README，可再进目录树）：[ch22-socket-api-event-loop](/static/code/#/zig-esp32-s31/ch22-socket-api-event-loop/README.md)

深链由 `npm run code-site` 生成（`scripts/gen-code-site.mjs` 的
`PROJECT_GLOBS` 已覆盖 `practice/zig-esp32-s31/*`），浏览页收录本章工程的全部源文件。

### 22.9.1 四个模块的职责边界

```text
netstub.zig   只做两件事：段 ⇄ 字节串、脚本顺序吐段。不知道自己被谁用。
                ↑
socket.zig    FD 表 + 状态机 + 就绪判定 + 被投递时怎么迁移。
              依赖 netstub 的 Segment 类型；不知道 poll、不知道池。
                ↑
event.zig     poll 怎么扫、超时怎么弹、池怎么准入。
              依赖 socket.Table（索引 + readyRead + abort）；不知道段。
                ↑
selftest.zig  板侧使用者：拼脚本、投递、断言、打印。
host_tests.zig 主机侧使用者：只 import 上面三个，不编译 selftest。
```

三个模块没有一个是"知道全局"的。`socket.zig` 里没有 `std.time`、没有
分配器、没有 `std.fs`；`event.zig` 里没有段格式。这条边界是主机侧
28 个用例能跑在 x86_64 上的前提。

### 22.9.2 静态缓冲与 16 KiB 栈

`src/selftest.zig:37` 的四个全局变量加起来约 13.7 KiB（表 10.6 + 载荷 3 +
循环与就绪集）。它们必须在 `.bss`：

- 表里 8 × 1360 B 的 `Socket` 如果进栈，`run()` 的帧重达 10.9 KiB；
- 加上 `g_payload`（3072 B）与 `g_out`（80 B），总和超过 16 KiB 栈；
- 链接脚本的 `ASSERT(_bss_end <= _stack_bottom)` 只在**链接期**检查
  `.bss`，检查不到栈帧——所以这个错误只会在运行时表现为 trap。

顺便解释一个"为什么主机测试发现不了"的问题：x86_64 上默认栈是 8 MiB，
把表放局部变量完全没事；只有交叉编译 + 上板才会炸。这类问题必须靠
"自检也在 rv32 上跑一遍"这条流程兜住。

### 22.9.3 与 ch21 工程的结构差异

两个工程都是形态 B、都有 `linker/` + `start.zig` + `idf-bootstrap/` +
`tools/flash.sh`，差别只在 `src/` 的内容：

| 文件             | ch21                  | ch22                                  |
| ---------------- | --------------------- | ------------------------------------- |
| `cong.zig`       | 拥塞控制律            | —                                     |
| `sim.zig`        | 确定性丢包仿真        | —（`netstub.zig` 是它的近亲）         |
| `socket.zig`     | —                     | FD 表与状态机                         |
| `event.zig`      | —                     | poll / 超时轮 / 池                    |
| `netstub.zig`    | —                     | 段线格式与脚本                        |
| `host_tests.zig` | import `cong` + `sim` | import `netstub` + `socket` + `event` |

`start.zig`、`trap.zig`、`hw.zig`、`log.zig`、链接脚本都是**照抄后改注释与
`app_desc` 名称**——第 22.10 节会看到 `image-info` 打印的
`Project name: ch22-socket-api-event-loop`，那就是 `app_desc` 生效的证据。

---

## 22.10 上板自检输出（真实日志）

烧录与抓取：`flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'`，
串口 115200 8N1（UART0，GPIO58/59）。原始输出在
`practice/zig-esp32-s31/logs/ch22-boot.log`，下面是判据相关的部分原文：

```text
ch22-socket-api-event-loop | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: fd table + socket states + poll/tick timeouts + conn pool + partial rw
note: every segment is injected by netstub - NOT a real network link
host: 28 unit tests via 'zig build test' (27 named + root container)
check: handshake listen=listen syn=syn_rcvd ack=established fd=1 ok=1
check: accept fd=1 got=1 pool=1/4 accepted=1 ok=1
check: recv-nodata err=again n=0 again_count=1 ok=1
check: poll tick write_only=1 read_after_data=1 ready_total=2 ok=1
check: wheel now=2:0 now=3:1(retransmit) now=10:1 fired=2 left=0 ok=1
check: partial-send req=3072 accepted=1024 retry_n=0 retry=again ok=1
check: fin-path peer_fin=close_wait local_close=last_ack final_ack=closed ok=1
check: pool full reject=pool_full rejected=1 evict fd=1 evicted=1 len=4 ok=1
check: fair-rotation ticks=8 head_a=4 head_b=4 start=0 ok=1
check: idle empty_ticks=1000 after_wakeup idle=1000 ready=1 polls=1001 ok=1
check: inject-data readable=1 recv1=100 recv2=100 recv3=again total=200 ok=1
check: peer-rst recv=conn_reset state=closed slot_open=0 ok=1
sim: netstub segs=3 payload=5 hash=0x52816f06 replay=0x52816f06 equal=1
checks: passed=12 failed=0 total=12
main: verdict=pass, socket contract verified off-link (wfi)
main: halting (wfi)
```

banner 第一行是本章的身份证明：`ch22-socket-api-event-loop`。两块 agent
共用一块板时，"抓到别人日志"是最容易犯的错，所以判读第一步永远是看
这一行。

### 22.10.1 十二条判据逐条读

| #   | 判据                                           | 原文读数                                                             | 说明                                             |
| --- | ---------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------ |
| ①   | LISTEN + SYN → `syn_rcvd`；ACK → `established` | `handshake listen=listen syn=syn_rcvd ack=established fd=1`          | 子连接在槽位 1；三次握手只走本章需要的三步       |
| ②   | `accept` 返回 fd 且池不超限                    | `accept fd=1 got=1 pool=1/4 accepted=1`                              | `pool=1/4` 同时验证"进了池"和"没超过 `pool_cap`" |
| ③   | 非阻塞 `recv` 无数据 → `.again`                | `recv-nodata err=again n=0 again_count=1`                            | `again_count=1` 证明走的是 EAGAIN 分支           |
| ④   | `poll` 单 tick 的就绪集                        | `poll tick write_only=1 read_after_data=1 ready_total=2`             | 先"只可写"，投数据后"可读 + 可写"                |
| ⑤   | 超时轮注入 `now`                               | `wheel now=2:0 now=3:1(retransmit) now=10:1 fired=2 left=0`          | 只弹到期的；`left=0` 表示清空                    |
| ⑥   | 部分写：3 KiB → 1 KiB                          | `partial-send req=3072 accepted=1024 retry_n=0 retry=again`          | 第二次一个字节也搬不动                           |
| ⑦   | FIN → `close_wait` → `last_ack` → `closed`     | `fin-path peer_fin=close_wait local_close=last_ack final_ack=closed` | 三个状态按顺序迁移                               |
| ⑧   | 池满两种策略                                   | `pool full reject=pool_full rejected=1 evict fd=1 evicted=1 len=4`   | 拒绝计数 + 踢出计数 + 池长度不变                 |
| ⑨   | 轮转公平                                       | `fair-rotation ticks=8 head_a=4 head_b=4 start=0`                    | 两个 fd 各当 4 次队首                            |
| ⑩   | 空转 tick 与唤醒                               | `idle empty_ticks=1000 after_wakeup idle=1000 ready=1 polls=1001`    | 1000 个空 tick 全计数；来数据后不再空转          |
| ⑪   | 注入数据 → 部分读                              | `inject-data readable=1 recv1=100 recv2=100 recv3=again total=200`   | 200 字节分两次读完，第三次 EAGAIN                |
| ⑫   | 对端 RST                                       | `peer-rst recv=conn_reset state=closed slot_open=0`                  | 错误码 + 槽位回收                                |

最后两行：

```text
checks: passed=12 failed=0 total=12
main: verdict=pass, socket contract verified off-link (wfi)
```

`(wfi)` 表示 `main` 在打印完之后执行 `csrci mstatus, 0x8` + `wfi` 循环，
不会自己复位；`main: halting (wfi)` 是停机前的最后一行。

### 22.10.2 `sim:` 行是读数，不是判据

```text
sim: netstub segs=3 payload=5 hash=0x52816f06 replay=0x52816f06 equal=1
```

这一行把同一串脚本（SYN + `"hello"` + FIN）投递两遍，比指纹：
`hash` 与 `replay` 相同、`equal=1`。它**不计入** `checks:` 的 12 条，
因为它验证的是"注入源可重放"，属于工具性质；把它算进判据会让"12 条"
这个数字失去意义。这个区分在 22.11 会再用一次。

### 22.10.3 判读顺序（出问题时按这个顺序看）

1. **banner 第一行**是不是 `ch22-socket-api-event-loop`——不是就重抓，
   别分析别人的日志；
2. `check:` 行数是不是 **12**，有没有 `ok=0`；
3. 若 ① 失败 → 先看 `Table.spawnChild`（`src/socket.zig`）有没有把子
   连接挂进 backlog，再看 `onSegment` 的 `ack` 分支；
4. 若 ② 失败 → 看 `pool.admit` 与 `takeReady` 是否都返回了同一个 fd；
5. 若 ④ 失败 → 先看 `Table.readyRead` 的 listener 分支（22.4.3 那个坑），
   再看注册的 `events` 掩码；
6. 若 ⑤ 失败 → 看 `Wheel.advance` 的 `deadline <= now` 比较与"删除后
   不前进"的那行 `continue`；
7. 若 ⑥ 失败 → 看 `txPush` 的 `@min(txFree(), src.len)`；
8. 若 ⑧ 失败 → 看 `offer` 是否真的把连接留在 backlog 里（走丢队列的
   话 `accept` 会 EAGAIN 而不是 `pool_full`）；
9. 若 ⑨ 失败 → 看 `Loop.start` 是否每 tick 前进；
10. 若 ⑫ 失败 → 看 `recv` 里 `reset_seen` 的分支顺序（必须在
    `state.canIo()` 之前）。

---

## 22.11 主机侧回归测试怎么搭

### 22.11.1 28 个用例的分布

```text
netstub.zig   5 个：编码解码往返、三种解码错误、out 太短的返回 0、脚本重放指纹、
                   脚本改动后指纹必变
socket.zig   11 个：FD 表容量/复用、两条状态机路径、recv 语义、send 背压、
                   errno 契约、接收缓冲截断、backlog 丢弃、脚本投递指纹、忽略路径
event.zig    11 个：空注册表、就绪集、水平触发可写、轮转公平、截断、
                   超时轮到期/取消/容量、池 reject_new、池 evict_oldest、
                   accept 的 again 与 bad_fd
根文件容器    1 个：host_tests.zig 的 `test { ... }`（把三个模块的用例拉进来）
```

`zig build test --summary all` 的输出：

```text
Build Summary: 3/3 steps succeeded; 28/28 tests passed
test success
+- run test 28 pass (28 total) 5ms MaxRSS:4M
   +- compile test debug native success 339ms MaxRSS:182M
```

### 22.11.2 覆盖边界：主机测试不等于板侧判据

`src/host_tests.zig` 只 import 三个纯逻辑模块，**不编译
`src/selftest.zig`**。所以：

- 主机侧的 28 个用例证明的是"边界值与策略组合"；
- 板侧的 12 条判据证明的是"同一份代码在 rv32 + 真实 SRAM 布局下能跑完
  并给出同样结论"；
- 两者有交集（比如轮转公平两边都测），但没有包含关系——例如
  `g_tbl` 在 `.bss` 里、`g_payload` 3 KiB 不越栈，这条只有板侧能验。

把 28 读成"12 条判据已被主机覆盖"是错的，README 里专门写了一句提醒。

### 22.11.3 注入源怎么做到可重放

`netstub` 的脚本是一个普通字节缓冲，`Script` 只记住"读到哪"：

```zig
pub const Script = struct {
    bytes: []const u8,
    at: usize = 0,
    errors: u32 = 0,
    ...
};
```

（`src/netstub.zig:140`。）重放 = `rewind()` 之后再 `next()` 一遍，
得到同样的段序列。指纹由 `Script.drain()` 用 `fnv1a` 逐段混入
**kind + seq + ack + 载荷长度 + 载荷字节** 得到（不是只混段种类：
只混种类的话，"改了一个字节的正文"和"没改"会算出同一个指纹），因此：

- 脚本字节不变 → 段序列不变 → 指纹不变（板侧判据里 `equal=1`）；
- 改任意一段的 kind / seq / ack / 载荷 → 指纹必变
  （主机侧用例 `脚本指纹：改动任意一段的 kind/seq/载荷都会改变指纹，重放则不变`
  把同一脚本里的一个载荷字节、一个 seq 字节各改一次，两处都必须变）。

这条性质让"板侧跑出来的读数"和"主机侧跑出来的断言"可以互相引用：
两边用的是同一个 `hash`。

### 22.11.4 一个真实用例的形状

以 `poll：轮转起点每 tick 前进，两个常驻可读 fd 都会轮到队首` 为例：

```zig
var head_a: u32 = 0;
var head_b: u32 = 0;
var i: usize = 0;
while (i < 8) : (i += 1) {
    _ = lp.poll(&tbl, &regs, &out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    const h = out.head().?;
    if (h == a) head_a += 1;
    if (h == b) head_b += 1;
}
try std.testing.expect(head_a > 0 and head_b > 0);
try std.testing.expectEqual(@as(u32, 4), head_a);
try std.testing.expectEqual(@as(u32, 4), head_b);
```

三个断言分层：

1. 每 tick 都有 2 个就绪项（前置条件，失败说明数据没灌进去）；
2. 两个 fd 都当过队首（公平性的弱断言）；
3. 各 4 次（强断言，钉住"起点每 tick 前进一格"这个具体实现）。

只写第 2 条也能过——把 `start` 改成"只在有空闲时前进"也会满足"都当过
队首"。强断言的价值就是让这种"看起来公平"的实现无法混过去。

### 22.11.5 为什么要有一个 `offer` 与一个 `handshake`

测试里有两种"建立连接"的需求：

- **测 `accept` / 池策略**：连接必须留在 backlog 里等 `accept` 取走；
- **测读写 / `poll`**：连接必须已经出队，才不会被后续握手覆盖。

所以 `selftest.zig` 与 `event.zig` 各有一对辅助函数：

```zig
fn offer(listen_fd: u8, seq: u32) u8   // 握手完成，留在 backlog
fn handshake(listen_fd: u8, seq: u32) u8 // 握手完成 + takeReady 出队
```

早期版本只写了 `handshake`，用它连续建两条连接时，第二次握手仍然在
`backlog[0]` 上操作——结果两条"不同"的连接其实是同一个 fd，轮转公平
的用例就以 `head_a=8 head_b=0` 的形式失败了。这个 bug 正好说明：
**测试辅助函数的语义和被测代码的语义一样需要被钉住**。

---

## 22.12 边界：真实 socket 需要 ch17 + ch20/ch21，本章不接真实网卡

### 22.12.1 本章验证了什么、没验证什么

| 已验证（板侧 12 条 + 主机 28 个） | 未验证（明确留空）                 |
| --------------------------------- | ---------------------------------- |
| FD 表索引与槽位复用               | 真实四元组到 fd 的映射             |
| 状态机的两条主路径                | SYN 的重传与 `syn_sent` 超时       |
| 非阻塞返回值契约                  | 阻塞语义（需要调度器）             |
| 就绪集的正确性与轮转公平          | 真实中断驱动的唤醒                 |
| 相对 tick 的超时轮                | 时钟源（TIMG/mtime）的换算         |
| 池的两种策略与计数                | 真实连接数压力测试                 |
| 部分读写与背压                    | 真实链路上的发送队列与拥塞窗口联动 |

### 22.12.2 接上真链路要补什么

1. **传输层**：把 `Socket.send` 搬进 tx 缓冲的字节真正交给 ch20 的
   状态机，并把 `drainTx(n)` 的调用点放在"收到 ACK"处（ch20 的
   `Conn.onSegment()` 内部会调私有 `processAck()`）。
2. **接收路径**：ch17/ch18 收到的段解析后投给 `Table.deliver`，替代
   `netstub` 的注入。段格式要扩成真实 TCP 首部（20 字节起，带窗口、
   校验和）。
3. **时钟**：把 `Wheel.advance(now, ...)` 的 `now` 接上 ch08 的 TIMG0
   计数（或 `mtime`），并决定是否引入中断——如果引入，22.5.2 的三条
   理由就要重新评估，且 `socket.zig` 里所有字段都要重审并发访问。
4. **监听队列**：`backlog_cap = 4` 要跟 ch20 的 SYN 队列对齐（真实实现
   里 SYN 与已完成握手的连接是两个队列）。
5. **拥塞控制**：发送侧一次能搬多少字节，最终要受
   `min(cwnd, rwnd)` 限制（ch21），本章的 `tx_cap` 只是内存上限。

### 22.12.3 到时需要的判据（跑什么、看什么、算过）

| 判据               | 怎么跑                                               | 看什么                                                            | 算过                       |
| ------------------ | ---------------------------------------------------- | ----------------------------------------------------------------- | -------------------------- |
| 真实握手           | 板子连一台 Linux 主机跑 `nc -l 8080`，板侧 `connect` | 对端 `ss -tn` 出现 `ESTAB`；板侧打印 `connect: state=established` | 三次握手在 3 个 RTT 内完成 |
| 真实 `accept`      | 主机 `nc <板IP> 8080` 连板子                         | 板侧 `accept fd=N pool=n/4`；主机收到 banner                      | fd 不重复、池计数单调增    |
| 真实 `recv` 部分读 | 主机一次发 4096 字节                                 | 板侧连续 `recv` 累加等于 4096，期间出现 ≥1 次 `.again`            | 字节数完全一致（无丢无重） |
| 真实背压           | 板侧连发 64 KiB，主机慢速读                          | 板侧 `send` 返回 `.again` 的次数 > 0；`drainTx` 总和 = 64 KiB     | 无数据重复、无越界         |
| 真实 RST           | 主机 `recv` 后立刻 `close` 带 RST（`SO_LINGER 0`）   | 板侧 `recv` 返回 `conn_reset`，槽位回收                           | `slot_open=0`，fd 可复用   |
| 真实公平性         | 两条连接持续灌数据                                   | 两条连接的处理次数差 < 10%                                        | 无饥饿                     |

这些判据**本章一条都没有跑**。等 ch17 闭环后再补，补齐之前 22.10 的
日志只能读作"注入路径下的契约验证"。

### 22.12.4 与 ch23 的关系

ch23 要在本章之上做 TLS 与 HTTP。它需要的接口恰好是本章的三件东西：

- 一个 fd（`accept` 之后拿到）；
- `recv`/`send` 的部分读写语义（TLS 记录可能分片到达）；
- "现在该读还是该写"的状态机（TLS 握手有一半时间在等对端）。

所以 ch23 会**签名级依赖**本章（`Io`、`Errno`、`poll` 就绪集），
但同样不会 import 本章的实现——每一章都自带一份可独立编译的代码。

### 22.12.5 本章与 ch20/ch21 的关系：独立重写，只有签名级依赖

仓库里 ch18–ch23 的每一章都是**各自独立重写一份实现**，本章也不例外：

| 与谁 | 关系       | 具体表现                                                                                                           |
| ---- | ---------- | ------------------------------------------------------------------------------------------------------------------ |
| ch20 | 签名级依赖 | `State` 的名字（`syn_rcvd`/`established`/`close_wait`/`last_ack`）与它对齐；状态迁移表、序号用法都是本章自己的一份 |
| ch21 | 签名级依赖 | 本章的 `tx_cap` 是内存上限，真实链路上届时要换乘 `min(cwnd, rwnd)`；本章不 import `cong.zig` 的任何符号            |
| ch19 | 无依赖     | `netstub` 的 10 字节首部不是 UDP/DNS 首部，也不复用它们                                                            |
| ch16 | 无依赖     | `headers.zig` 只到 UDP；本章不用 `pbuf`，段载荷直接进环形缓冲                                                      |

"独立重写"不是偷懒，而是测试纪律：如果本章 import 了 ch20 的状态机，
那么"本章的状态机是否正确"就变成了"ch20 有没有 bug"的问题，
主机侧的 28 个用例就不再是对本章的独立证据。写成两份实现，两份都必须
各自通过自己的判据，任何一边改坏都只在自己那章红掉。

---

## 事实来源

本章的接口语义来自 POSIX/lwIP 的公开定义，对照实现来自本地 ESP-IDF v6.1
自带的 lwIP（路径相对 `~/esp/esp-idf/`）与 Zig 0.17.1 的 std，行号逐条
grep 过。

| #   | 事实                                                                                   | 路径与位置                                                                                                           |
| --- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 1   | lwIP 的 `ERR_WOULDBLOCK = -7`，注释为 "Operation would block"                          | `components/lwip/lwip/src/include/lwip/err.h:69`                                                                     |
| 2   | 非阻塞 netconn 的 `accept` 用 `sys_arch_mbox_tryfetch` 试取，失败返回 `ERR_WOULDBLOCK` | `components/lwip/lwip/src/api/api_lib.c:505`、`:509`                                                                 |
| 3   | 非阻塞 recv 在 FIN 未处理完时也返回 `ERR_WOULDBLOCK`                                   | `components/lwip/lwip/src/api/api_lib.c:753`                                                                         |
| 4   | accept 的 "RCVPLUS 计数"：3 个事件 = 可安全 `netconn_accept` 3 次而不阻塞              | `components/lwip/lwip/src/include/lwip/api.h:161-176`（关键句在 `:171`）                                             |
| 5   | `lwip_accept` 入口                                                                     | `components/lwip/lwip/src/api/sockets.c:666`                                                                         |
| 6   | `lwip_pollscan` 按数组顺序扫描（`for (fdi = 0; fdi < nfds; fdi++)`）                   | `components/lwip/lwip/src/api/sockets.c:2249`、`:2257`                                                               |
| 7   | `lwip_poll` 先 `lwip_pollscan(fds, nfds, LWIP_POLLSCAN_CLEAR)` 再决定是否等待          | `components/lwip/lwip/src/api/sockets.c:2375`、`:2393`                                                               |
| 8   | `POLLIN 0x1` / `POLLOUT 0x2`，`struct pollfd` 与 `lwip_poll` 声明                      | `components/lwip/lwip/src/include/lwip/sockets.h:504-505`、`:516`、`:623`                                            |
| 9   | ESP-IDF 的 `LWIP_MAX_SOCKETS` 默认 10、范围 1–253                                      | `components/lwip/Kconfig:137`（`default 10` 在 `:140`）                                                              |
| 10  | lwIP 的 `MEMP_NUM_NETCONN` 默认 4                                                      | `components/lwip/lwip/src/include/lwip/opt.h:525`                                                                    |
| 11  | ESP-IDF 把 `MEMP_NUM_NETCONN` 改成跟随 `CONFIG_LWIP_MAX_SOCKETS`                       | `components/lwip/port/include/lwipopts.h:124`                                                                        |
| 12  | `TCP_LISTEN_BACKLOG` 默认关闭；开启后默认 backlog 255                                  | `components/lwip/lwip/src/include/lwip/opt.h:1471`、`:1480`                                                          |
| 13  | `tcp_listen_with_backlog_and_err` 的存在与断言（backlog 参数进入 pcb）                 | `components/lwip/lwip/src/core/tcp.c:855`、`:864-865`                                                                |
| 14  | Zig 的 `std.posix.poll(fds, timeout)` 把 `EINTR` 吞掉并重新调用                        | `<zig>/lib/std/posix.zig:1009`（`.INTR => continue` 在 `:1019`）                                                     |
| 15  | `std.posix.pollfd` 与 `POLL` 是 `system` 的别名                                        | `<zig>/lib/std/posix.zig:178`、`:114`                                                                                |
| 16  | 没有 poll 的目标（freestanding/无 libc）上 `pollfd = void`，所以本章自带一份 poll      | `<zig>/lib/std/posix.zig:61`（`else` 分支）、`:44`（PSP 分支）                                                       |
| 17  | Linux 的 `POLL.IN/OUT/ERR/HUP/NVAL` 取值                                               | `<zig>/lib/std/os/linux.zig:8438-8442`                                                                               |
| 18  | `E.AGAIN = 11`，注释 "Also used for WOULDBLOCK"                                        | `<zig>/lib/std/os/linux.zig:3599-3600`                                                                               |
| 19  | 本章 FD 表容量、收发缓冲、backlog 深度的定义                                           | `practice/zig-esp32-s31/ch22-socket-api-event-loop/src/socket.zig:34`、`:37`、`:40`、`:42`                           |
| 20  | 本章 `recv` / `send` / `onSegment` / `readyRead` 的实现位置                            | `src/socket.zig:269`、`:289`、`:326`、`:445`                                                                         |
| 21  | 本章 `poll` / `accept` / `admit` / `Wheel.advance` 的实现位置                          | `src/event.zig:316`、`:357`、`:253`、`:155`                                                                          |
| 22  | 段线格式：10 字节首部（kind/seq/ack/len）+ 载荷，`max_payload = 128`                   | `src/netstub.zig:32`、`:64`、`:98`、`:110`                                                                           |
| 23  | 板侧全局对象（FD 表、循环、就绪集、3 KiB 载荷）都在文件作用域                          | `src/selftest.zig:37`、`:38`、`:39`、`:40`                                                                           |
| 24  | 主栈 16 KiB 与 SRAM 长度，`ASSERT(_bss_end <= _stack_bottom)`                          | `practice/zig-esp32-s31/ch22-socket-api-event-loop/linker/s31.ld`（`_stack_size = 0x4000`、`sram LENGTH = 0x7AFC0`） |

> [!note] 口径
> 第 1–13 行是**对照实现**，不是本章的依赖：本章不链接 lwIP，也没有在
> 真链路上跑过它。凡属本章自己的判断（`max_fds = 8`、`rx_cap = 256`、
> `tx_cap = 1024`、默认 `reject_new`、水平触发、8 槽超时轮），都在正文
> 里给了理由与判据，而不是引用权威。
>
> 第 19–24 行是本章自己的代码位置，行号在 `zig fmt` 之后重新核对过；
> 引用时以 `src/` 下的实际文件为准。

---

## 自查清单

静态部分（本机 2026-11-13 实测，宿主 x86_64 / Zig 0.17.1）：

- [x] `zig build test` 全绿：`28/28 tests passed`（27 个具名用例 + 根文件容器 test）
- [x] 覆盖边界已核对：`host_tests.zig` 只 import `netstub`/`socket`/`event`，
      **不编译 `selftest.zig`**；12 条板侧判据只由 rv32 交叉编译 + 上板运行验证
      （不要把 28 个用例读成"12 条板侧判据已被主机测试覆盖"）
- [x] 必需的主机覆盖齐备：事件循环就绪集、超时轮、连接池踢出、部分读写、EAGAIN
- [x] `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 的段表里 `DROM, IROM` 行数**正好 2**（`0x40000020`、`0x40020020`），
      且 `Project name: ch22-socket-api-event-loop`
- [x] `bash -n tools/flash.sh` 退出 0
- [x] `socket.zig` / `event.zig` / `netstub.zig` 均无 `std.time`、无分配器、无浮点
- [x] 静态对象不进栈：FD 表与 3 KiB 载荷都在文件作用域（`.bss`）

上板部分（2026-11-13，`practice/zig-esp32-s31/logs/ch22-boot.log`）：

- [x] banner 五行完整（含 `note: every segment is injected by netstub - NOT a real network link`
      与 `host: 28 unit tests via 'zig build test' (27 named + root container)`）
- [x] 12 条 `check:` 全部 `ok=1`，逐行与日志一致：
      `handshake`、`accept`、`recv-nodata`、`poll tick`、`wheel`、`partial-send`、
      `fin-path`、`pool full`、`fair-rotation`、`idle`、`inject-data`、`peer-rst`
- [x] `sim: netstub segs=3 payload=5 hash=0x52816f06 replay=0x52816f06 equal=1`
      （脚本重放确定性）
- [x] `checks: passed=12 failed=0 total=12`
- [x] `main: verdict=pass` 之后停在 `wfi`，复位可重复
- [x] banner 第一行是 `ch22-socket-api-event-loop`（排除串板拿到其他 agent 的日志）

未闭环（不代填）：

- [ ] 真实 socket：需 ch17 以太网闭环（DMA 软复位、MDIO、TX）+ ch20 状态机
- [ ] 真实握手/`accept`/部分读/背压/RST 的链路验证：判据见 22.12.3
- [ ] 时钟源接入（TIMG0/mtime）与"是否引入 tick 中断"的决策
- [ ] 真实 SYN 队列与本章 backlog 的分层（SYN 队列 vs 已握手队列）
- [ ] 发送侧受 `min(cwnd, rwnd)` 限制（ch21 联动）

失败时的第一反应（按顺序排查，不要跳步）：

1. `check:` 行数不是 12 → 先看 `selftest.run()` 是否被 `main` 调用、
   有没有中途 panic（panic 会打印 `panic:` 然后停机）；
2. ① 失败 → `spawnChild` 是否把子连接挂进 `backlog`，`onSegment(ack)` 是否
   把 `syn_rcvd` 推到 `established`；
3. ② 失败 → `takeReady` 返回的是不是 `accept` 的那个 fd；池的 `fds[]` 与
   fd 是否对得上；
4. ④ 失败 → `readyRead` 的 listener 分支（只投 SYN 时不应就绪）；
5. ⑤ 失败 → `advance` 里删除元素后那行 `continue`（少了它会漏掉下一个）；
6. ⑥ 失败 → `txPush` 的 `@min(txFree(), src.len)`；`tx_cap` 是否真是 1024；
7. ⑧ 失败 → `offer` 有没有留在 backlog；`evict_oldest` 挑的是不是
   `accept_token` 最小的；
8. ⑨ 失败 → `Loop.start` 是否每 tick 前进一格；
9. ⑫ 失败 → `recv` 里 `reset_seen` 的分支顺序（必须在 `canIo` 之前）。

---

## 下一章预告

下一章（[[ch23-tls-http|第二十三章：TLS 与 HTTP]]）在这套 socket 之上做两件事：

- **TLS 记录层**：AEAD、密钥派生、证书与 DER 解析，全部用 known-answer
  自检（不依赖真链路）；
- **HTTP 报文层**：请求行/首部的解析与响应的分块组装，同样只做纯逻辑
  与注入路径的验证。

它需要的接口正好是本章交付的三件东西：一个 fd、`recv`/`send` 的部分读写
语义、以及"现在该读还是该写"的就绪集。完整的 TLS 握手与真实 HTTPS GET
要等 ch17 + 本章（+ ch20/ch21）闭环之后才能做，下一章会把判据写清楚。

> 下一章：[[ch23-tls-http|第二十三章：TLS 与 HTTP]]
>
> 上一章：[[ch21-tcp-congestion-throughput|第二十一章：TCP 拥塞控制与吞吐]]

系列导航：[[ch21-tcp-congestion-throughput|上一章：TCP 拥塞控制与吞吐]] ·
[[ch23-tls-http|下一章：TLS 与 HTTP]] · [[zig-esp32-s31|系列索引]]
