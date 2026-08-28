---
title: "lwIP 深度解析（十一）：TCP 状态机：tcp_input 与连接的一生"
date: 2026-08-26
description: "一个 TCP 连接从 SYN 到 TIME_WAIT 由谁驱动？拆解 tcp_pcb_listen 与 tcp_pcb 双家族结构、tcp_input 的三级 PCB 查找瀑布与 tcp_process 状态机全部迁移边；用 QEMU + 编译期 IP4 hook 注入实测：主动/被动关闭状态序列抓拍、TIME_WAIT 堆积 61 并在 120s 后阶梯式泄洪、半打开连接被 keepalive 在 11s 清理（errno=113）、MEMP 池压到 2 时的 SYN 静默丢弃与 SYNRCVD=2 饱和曲线。附 Vanilla lwIP 与 ESP-IDF lwIP 裁剪对照表。"
tags: [lwip, network, esp32, esp-idf, qemu, tcp]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 11. **第十一章：TCP 状态机：tcp_input 与连接的一生**

# lwIP 深度解析（十一）：TCP 状态机：tcp_input 与连接的一生

这一章回答三个问题：**一个 TCP 连接从 SYN 到 TIME_WAIT 要经过哪些状态、谁在驱动迁移**（答案：单线程 `tcpip_thread` 上的"输入包 + 两个定时器"，没有任何锁参与）、**listen backlog 在 lwIP 里到底是什么**（答案是两个字节的计数器，不是队列）、**半打开与异常关闭怎么处理**（答案分"等得起的 keepalive"与"等不起的 RST 路径"两种）。读完它，你应该能对着一份 `netstat` 式的状态分布，准确说出每条连接卡在哪条代码路径上。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`components/lwip/lwip/src`），Vanilla 同版本文件对照。

---

## 11.1 连接的一生：先给全景

### 状态全集

lwIP 的 TCP 状态定义在 `src/include/lwip/tcpbase.h`，就是一个 0~10 的朴素枚举：

```c
enum tcp_state {
  CLOSED = 0, LISTEN = 1, SYN_SENT = 2, SYN_RCVD = 3, ESTABLISHED = 4,
  FIN_WAIT_1 = 5, FIN_WAIT_2 = 6, CLOSE_WAIT = 7, CLOSING = 8,
  LAST_ACK = 9, TIME_WAIT = 10
};
/* ATTENTION: this depends on state number ordering! */
#define TCP_STATE_IS_CLOSING(state) ((state) >= FIN_WAIT_1)
```

### 全景迁移图（观察者视角）

```text
 主动打开(server 视角收 SYN)               主动关闭(client 视角)
┌────────┐ SYN ┌─────────┐ SYN|ACK ┌───────────┐ ACK ┌─────────────┐ close/FIN ┌────────────┐
│ LISTEN │ ──▶ │(fork出) │ ──────▶ │ SYN_RCVD  │ ──▶ │ ESTABLISHED │─────────▶ │ FIN_WAIT_1 │
└────────┘     │ SYN_RCVD│         └───────────┘     └─────────────┘           └─────┬──────┘
   ▲ 收到对端FIN+ACK──┐                 ▲ dup-SYN: 重发SYN|ACK          ACK对端FIN│   │收到对端FIN(未被ACK→CLOSING)
   │                  ▼                  │                              ┌─────────▼───▼┐
   │         （返回 LISTEN 不存在——      │                    ACK ┌────▶│ FIN_WAIT_2   │
   │          PCB 已 fork/销毁）         │                        │     └──────┬───────┘
   │                                    │                     对端FIN          │对端FIN
   │ 被动关闭                            │                        │             ▼
 ┌─┴────────┐ ACK对端FIN ┌──────────┐    │            ┌───────────┴─────────────────┐
 │CLOSE_WAIT│──────────▶ │ LAST_ACK │    │            │ TIME_WAIT （240 tick 后销毁）│
 └──────────┘ (本方close) └────┬─────┘    │            └─────────────────────────────┘
                               │收到ACK    │                          ▲ CLOSING: 收到ACK也来这
                               └──▶ 销毁    └────────────────────────┘（连接异常关闭见 11.3/11.5）
```

### 驱动者：没有神，只有邮箱和两个定时器

状态迁移的全部动力来自 `tcpip_thread` 单线程上的三类事件：

| 动力     | 入口                                                | 典型触发                                              |
| -------- | --------------------------------------------------- | ----------------------------------------------------- |
| 输入段   | `ip_input()` → `tcp_input()`（`src/core/tcp_in.c`） | 收到任何 TCP 段                                       |
| 慢定时器 | `tcp_slowtmr()`（500ms 一拍）                       | RTO 重传、keepalive、TIME_WAIT/LAST_ACK/SYN_RCVD 回收 |
| 快定时器 | `tcp_fasttmr()`（250ms 一拍）                       | 延迟 ACK、搁置中的 FIN（TF_CLOSEPEND）                |

第三种动力是应用回调——但它**不是独立线程**，而是在 `tcp_input` 处理过程中被同步调用（recv/sent/poll 等）。第十三章会专讲 `tcpip_thread` 的邮箱模型；这里只需记住：**遍历 PCB 链表永远是安全的，只要你在 `tcpip_thread` 上下文里做**。本章实验的观测器正是靠 `tcpip_callback()` 把统计函数投递进这个线程（见 11.8）。

### 四张全局链表

PCB 的"容器"比 UDP（[[2026-08-26-lwip-deep-dive-ch10-udp-pcb-layers|第十章]]）复杂一档——四张链表加一条不变式，定义于 `src/include/lwip/priv/tcp_priv.h`：

```c
extern struct tcp_pcb *tcp_bound_pcbs;       /* bind 过但未 listen/connect */
extern union tcp_listen_pcbs_t tcp_listen_pcbs; /* LISTEN 态 */
extern struct tcp_pcb *tcp_active_pcbs;      /* SYN_RCVD..LAST_ACK */
extern struct tcp_pcb *tcp_tw_pcbs;          /* TIME_WAIT 专属 */

#define NUM_TCP_PCB_LISTS_NO_TIME_WAIT  3
#define NUM_TCP_PCB_LISTS               4
extern struct tcp_pcb ** const tcp_pcb_lists[NUM_TCP_PCB_LISTS];
/* Axioms:
   1) Every TCP PCB that is not CLOSED is in one of the lists.
   2) A PCB is only in one of the lists. */
```

"从链表摘下再挂上另一张"就是状态机的搬家动作：如 `FIN_WAIT_1 → TIME_WAIT` 时执行 `TCP_RMV_ACTIVE(pcb); pcb->state = TIME_WAIT; TCP_REG(&tcp_tw_pcbs, pcb)`（`tcp_in.c` 的 `tcp_process()` 内）。

---

## 11.2 pcb 多家族解剖：tcp_pcb_listen 与 tcp_pcb

### 公共前缀与家族差异

两类 PCB 共享一段前缀，由宏拼接（`src/include/lwip/tcp.h`）：

```c
#define TCP_PCB_COMMON(type) \
  type *next;                /* 链表指针        */ \
  void *callback_arg;        /* 应用上下文      */ \
  TCP_PCB_EXTARGS \
  enum tcp_state state;      /* ★ 状态机本体    */ \
  u8_t prio; \
  u16_t local_port           /* 主机字节序       */
```

listening PCB 只是在此之上多了 accept 回调和 backlog 计数：

```c
struct tcp_pcb_listen {
  IP_PCB;
  TCP_PCB_COMMON(struct tcp_pcb_listen);
#if LWIP_CALLBACK_API
  tcp_accept_fn accept;
#endif
#if TCP_LISTEN_BACKLOG
  u8_t backlog;             /* 半开上限 */
  u8_t accepts_pending;     /* 当前半开数 */
#endif
};
```

而 `struct tcp_pcb`（active 家族）则多出约 40 个字段：远端四元组补全（`remote_port`）、重传账本（`rtime/rto/nrtx`）、RTT 估计（`sa/sv`）、拥塞窗口（`cwnd/ssthresh`）、三个段队列（`unsent/unacked/ooseq`）、keepalive 参数（`keep_idle/keep_intvl/keep_cnt`）……内核名场面字段在 [[2026-08-26-lwip-deep-dive-ch12-tcp-reliability-flow-control|第十二章]]逐一出场。

关键认知：**LISTEN 态 PCB 没有 remote 字段、没有队列、几乎零内存**；fork 出 active PCB 才开始支付完整账单。

### fork 现场：tcp_listen_input()

SYN 到达 LISTEN PCB 后由 `tcp_listen_input()`（`tcp_in.c`）完成"无中生有"。删去条件编译后的骨架：

```c
static void tcp_listen_input(struct tcp_pcb_listen *pcb) {
  if (flags & TCP_RST) return;                       /* RST 直接无视 */
  if (flags & TCP_ACK) {                             /* 孤儿 ACK：回 RST */
    tcp_rst_netif(...); return;
  } else if (flags & TCP_SYN) {
#if TCP_LISTEN_BACKLOG
    if (pcb->accepts_pending >= pcb->backlog) return;/* ① 超限：静默丢 */
#endif
    npcb = tcp_alloc(pcb->prio);
    if (npcb == NULL) {                              /* ② 分配失败：静默丢 */
      TCP_STATS_INC(tcp.memerr);
      TCP_EVENT_ACCEPT(pcb, NULL, pcb->callback_arg, ERR_MEM, err);
      return;                                        /*   “等发送方重传 SYN” */
    }
    pcb->accepts_pending++;
    tcp_set_flags(npcb, TF_BACKLOGPEND);
    ip_addr_copy(npcb->local_ip, *ip_current_dest_addr());
    ip_addr_copy(npcb->remote_ip, *ip_current_src_addr());
    npcb->local_port = pcb->local_port;
    npcb->remote_port = tcphdr->src;
    npcb->state = SYN_RCVD;                          /* ③ 出生即 SYN_RCVD */
    npcb->rcv_nxt = seqno + 1;                       /* ISN+1 */
    iss = tcp_next_iss(npcb); npcb->snd_nxt = iss; ...
    npcb->so_options = pcb->so_options & SOF_INHERITED; /* 继承选项 */
    TCP_REG_ACTIVE(npcb);                            /* ④ 挂入 active 链表 */
    tcp_parseopt(npcb);                              /* MSS/窗口缩放等 */
    rc = tcp_enqueue_flags(npcb, TCP_SYN | TCP_ACK); /* ⑤ 回 SYN|ACK */
    if (rc != ERR_OK) { tcp_abandon(npcb, 0); return; }
    tcp_output(npcb);
  }
}
```

> [!important] accept 回调的时机不在 fork 时
> `TCP_EVENT_ACCEPT` 是在第三次握手的 ACK 到达、`SYN_RCVD → ESTABLISHED` 迁移完成时才触发的（`tcp_process()` 的 `case SYN_RCVD:` 分支）。也就是说，**SYN 洪泛中那些永远不完成握手的半开连接，你的应用一次 accept 都看不到，但它们却实实在在占着 active PCB 的内存配额**——这是理解 11.6 实验 d 的钥匙。另一个细节：如果应用的 accept 回调没有设置（为 NULL），宏会返回 ERR_ARG，PCB 被 abort——裸 API 用户忘挂 `tcp_accept` 会表现为连接"建了又秒断"。
>
> fork 时若 listener 已经被关闭（`pcb->listener == NULL`），SYN_RCVD 完成握手时直接 abort 该新 PCB 并返回 ERR_VAL。

### 孤儿段的三个去向

LISTEN 态收到非 SYN 段的处理值得单独一张表：

| 收到                     | 处理                                    | 出处                                       |
| ------------------------ | --------------------------------------- | ------------------------------------------ |
| RST                      | 忽略（没有连接可复位）                  | `tcp_listen_input()` 开头                  |
| 不带 SYN 也不带 ACK 的段 | 落在 else-if 之外，直接丢弃，无任何反应 | `if (ACK){RST} else if (SYN){fork}` 的空隙 |
| 带 ACK 的段              | 回 RST 给对方                           | 中间分支                                   |

---

## 11.3 tcp_input 主流程走读

`tcp_input()` 是整个协议栈最长的函数之一（2.2.0-dev 中约 480 行），主流程可拆成五段。

### 第一段：头校验（失败即静默丢）

顺序检查：长度不足 20 字节头 → 广播/组播目的地址 → 校验和（`CHECKSUM_CHECK_TCP`）→ 数据偏移声明的头长合法性。全部失败路径只做一件事：`TCP_STATS_INC(tcp.drop / lenerr / chkerr)` 然后 `goto dropped`。**没有 RST、没有日志**——这些是坏包，不是错误。

### 第二段：三级查找瀑布（demultiplexing）

```text
for each pcb in tcp_active_pcbs:            # ① 先查活动连接
    匹配 remote_ip/remote_port/local_ip/local_port(+netif_idx)
    命中 → 摘下并插回链表头（局部性缓存）    # ↑ 未命中时 prev 指针恰好提供 O(1) 移位
if 未命中: for each pcb in tcp_tw_pcbs:      # ② 再查 TIME_WAIT
    命中 → tcp_timewait_input(pcb)，返回
if 未命中: for each lpcb in tcp_listen_pcbs: # ③ 最后查监听者
    local_port 相同 且 IP 匹配（ANY 优先级低于精确匹配）
    命中 → tcp_listen_input(lpcb)，返回      # SO_REUSE 下 ANY 多个都记录，精确优先
```

三张表查完仍无匹配且来包不是 RST——回一个 RST（`tcp_rst_netif()`），这就是"连接不存在"的标准答复。注意查找顺序的设计含义：**TIME_WAIT 比 LISTEN 优先**。同一五元组若既有 TW PCB 又有监听者，迟到段会命中前者而不是触发新的 SYN——这正是 TIME_WAIT 想要的效果。active 链表的"命中即提头"是 lwIP 少见的自适应优化，`tcp.cachehit` 计数器就是为此而生。

### 第三段：RST 的资格审查（RFC 5961）

`tcp_process()` 开头处理 RST，并非"见到就杀"：

```c
if (flags & TCP_RST) {
  if (pcb->state == SYN_SENT) {
    acceptable = (ackno == pcb->snd_nxt);          /* 必须 ACK 我的 SYN */
  } else {
    if (seqno == pcb->rcv_nxt) acceptable = 1;     /* 精确匹配才接受 */
    else if (TCP_SEQ_BETWEEN(seqno, ...)) tcp_ack_now(pcb); /* 挑战 ACK */
  }
  if (acceptable) { recv_flags |= TF_RESET; ... return ERR_RST; }
}
```

带注释的原话是 _"addresses CVE-2004-0230 (RST spoofing attack)"_——in-window 但不精确的伪造 RST 得到的是挑战 ACK 而不是断连。通过审查的 RST 会置 `TF_RESET`，回到 `tcp_input()` 外层走"err 回调 ERR_RST → 从 active 摘除 → free"的即时清理路径，应用（socket 层）表现为 `recv` 返回错误。**这是全函数里唯一一处输入事件能直接终结 PCB 的地方**——优雅关闭与之相反，要多轮往返。

### 第四段：状态机 switch（迁移边全景表）

`tcp_process()` 中段是一个按 state 分派的 switch，所有迁移边汇总如下（行号指向 2.2.0-dev 源码语义）：

| 当前态                   | 输入条件                              | 动作                                                                  | 下一态              |
| ------------------------ | ------------------------------------- | --------------------------------------------------------------------- | ------------------- | -------- |
| SYN_SENT                 | SYN\|ACK 且 ackno==lastack+1          | 抢答 established，free 掉 unacked 里的 SYN 段，connected 回调，回 ACK | ESTABLISHED         |
| SYN_SENT                 | 只有 ACK（半开残迹）                  | 回 RST + 立即重发 SYN（nrtx<上限）                                    | SYN_SENT            |
| SYN_RCVD                 | 第三次 ACK 合法                       | backlog 收尾（`tcp_backlog_accepted`）、accept 回调、初始化 cwnd      | ESTABLISHED         |
| SYN_RCVD                 | 收到重复 SYN（seqno==rcv_nxt−1）      | 重发 SYN                                                              | ACK（`tcp_rexmit`） | SYN_RCVD |
| SYN_RCVD                 | ackno 非法                            | 回 RST                                                                | —                   |
| SYN_RCVD                 | 带对端 FIN                            | ACK it                                                                | CLOSE_WAIT          |
| ESTABLISHED / CLOSE_WAIT | 收到 FIN                              | ack_now                                                               | CLOSE_WAIT          |
| FIN_WAIT_1               | 对端 FIN 且 ACK 我方 FIN 且 unsent 空 | 清理队列、迁往 tw 链表                                                | **TIME_WAIT**       |
| FIN_WAIT_1               | 对端 FIN 但我方未被 ACK               | ack_now                                                               | CLOSING             |
| FIN_WAIT_1               | 只是 ACK                              | （安静的等待）                                                        | FIN_WAIT_2          |
| FIN_WAIT_2               | 对端 FIN                              | ack_now、迁往 tw 链表                                                 | **TIME_WAIT**       |
| CLOSING                  | ACK 且覆盖我方 FIN                    | 迁往 tw 链表                                                          | **TIME_WAIT**       |
| LAST_ACK                 | ACK 覆盖我方 FIN                      | recv_flags \|= TF_CLOSED（延迟清理）                                  | (CLOSED/free)       |

三点解释：

1. "ACK 且覆盖我方 FIN 且 unsent 空"的三联判定说明：进入 TIME_WAIT 前，lwIP 要求自己发出的最后一个字节已确认且队列干净。
2. 同时关闭（Simultaneous Close）是天然支持的：双方同时发 FIN，就会各自经过 FIN_WAIT_1 → CLOSING → TIME_WAIT 的三拍舞步，而非四拍。
3. `TF_CLOSED` 不立即释放而是设标志、回到 `tcp_input()` 外层由 `tcp_input_delayed_close()` 统一处理——保证释放发生在所有引用让渡之后。

### 第五段：优雅关闭的 FIN 交换时序图

把主动关闭方的视角画成 ASCII（数字标迁移时刻）：

```text
 主动关闭方                                被动关闭方
 ESTABLISHED                             ESTABLISHED
     │ close(): 进队 FIN                      │
  ①  │ ──────────── FIN ──────────────────▶  │
     │                                      recv()==NULL（EOF）
     │ ◀─────────── ACK ───────────────────  │
 FIN_WAIT_1 ── FIN_WAIT_2                     │
     │                                   ② 应用调用 close()
     │                                  CLOSE_WAIT
     │ ◀──────────────────────────────── FIN ── LAST_ACK
     │                                         │
  ③  │ ──────────── ACK ──────────────────▶   │ 收到 ACK：销毁
     │                                       （无 TIME_WAIT！）
 TIME_WAIT
     ×  120 s 后由 tcp_slowtmr() 销毁
```

两个常被忽略的对称性：

- **被动关闭方从不进 TIME_WAIT**（它经 CLOSE_WAIT → LAST_ACK 直达销毁）。TIME_WAIT 永远属于先关的那一方——所以谁主动 close，谁付 TIME_WAIT 的账。本章实验 b 正是把这条对称性当作开关使用（11.4）。
- 主动发 FIN 之后接收通道仍是开的：对端继续送来的数据会在 `FIN_WAIT_1/2` 里正常上报（半关闭/half-close 语义）。实验 a 里那行 `srv ACTIVE recv N bytes after our FIN` 就是铁证。

### 异常关闭的另一扇门：tcp_close_shutdown()

应用调 `close()` 并不总是优雅三条腿。`tcp_close_shutdown(pcb, rst_on_unacked_data)` 开头有个短路分支：ESTABLISHED/CLOSE_WAIT 态下，若有未送达应用的数据（`refused_data != NULL` 或接收窗口未复原），直接**先发 RST 再立刻销毁**——用于通知对方"数据没消化完，别假装体面"。这也是 [[2026-08-26-lwip-deep-dive-ch16-socket-netconn-vfs|socket 层]] close() 与 raw 层 tcp_close() 行为差异的来源之一。

---

## 11.4 TIME_WAIT：为什么需要 240 个 tick

### 两条理由，一类危险

RFC 793 要求 TIME_WAIT 停留 `2×MSL`：(1) 保证最后的 ACK 若丢失、对端重发的 FIN 还能被正确应答；(2) 让携带旧序列号的迟报在网络里自然消亡。RFC 1337 进一步警告：跳过它会导致旧连接的重复段污染新连接。

### lwIP 的实现：三段式

TIME_WAIT PCB 已被摘出 active 表（`tcp_process()` 里 purge + 换链表），唯一的任务剩两个——**应答迟到段 + 数秒**。

第 1 段，进入时埋下出生时间戳：其实根本没有独立时间戳字段，`pcb->tmr` 本身就是时钟（每个合法输入段都会刷新它，唯独 TF*RXCLOSED 的半关闭情况除外——源码注释原话 *"(see tcp*shutdown)"*）。

第 2 段，`tcp_timewait_input()` 定义此状态的对外行为（`tcp_in.c`）：

```c
if (flags & TCP_RST) return;                       /* RFC1337: 无视 RST */
if (flags & TCP_SYN) {                             /* 窗口内的 SYN：错！回 RST */
  if (TCP_SEQ_BETWEEN(seqno, pcb->rcv_nxt, pcb->rcv_nxt + pcb->rcv_wnd))
    { tcp_rst(...); return; }
} else if (flags & TCP_FIN) {
  pcb->tmr = tcp_ticks;                            /* 迟到的 FIN：重启计时 */
}
if (tcplen > 0) { tcp_ack_now(pcb); tcp_output(pcb); }  /* 其余照常 ACK */
```

第 3 段，`tcp_slowtmr()` 每 500ms 扫一遍 `tcp_tw_pcbs` 判期：

```c
if ((u32_t)(tcp_ticks - pcb->tmr) > 2 * TCP_MSL / TCP_SLOW_INTERVAL)
  ++pcb_remove;          /* 2*60000/500 = 240 tick ≈ 120 s */
...
tcp_pcb_remove(&tcp_tw_pcbs, pcb); tcp_free(pcb);
```

IDF 的 MSL 通过 menuconfig 可调：`CONFIG_LWIP_TCP_MSL`（默认 60000，`port/include/lwipopts.h` 映射宏）。Linux 默认 60s；lwIP 默认给到 120s，短命嵌入式系统上更容易堆积。

### 端口复用的边界

TIME_WAIT 的每一个 PCB 都还占着自己的本地端口。读两处代码就能得出复用规则：

```c
/* tcp_new_port(): 临时端口分配扫描“全部 4 张链表” */
for (i = 0; i < NUM_TCP_PCB_LISTS; i++)          /* 含 tcp_tw_pcbs */
  for (pcb = *tcp_pcb_lists[i]; ...)
    if (pcb->local_port == tcp_port) goto again;

/* tcp_bind(): 显式绑定时的豁免开关 */
#if SO_REUSE
  if (ip_get_option(pcb, SOF_REUSEADDR))
    max_pcb_list = NUM_TCP_PCB_LISTS_NO_TIME_WAIT; /* 跳过 TW 表查重 */
#endif
```

结论一句话：**作为客户端出站连接，TIME_WAIT 端口永远不会被自动复用；作为服务端想立刻重新 bind 同一个端口，要么开 SO_REUSEADDR，要么等满 120 s**。IDF 的 `CONFIG_LWIP_SO_REUSE` 默认开（y），但 socket 上还得显式 setsockopt 才生效。

### 池子的救援链：tcp_alloc() 的自杀小队

TIME_WAIT PCB 也占 `MEMP_TCP_PBC` 池的一个格子（编号上active/tw/listen 三类共用同一个池门，见第五章的全堆化分析）。池耗尽时 `tcp_alloc()` 不是直接拒绝，而是一路杀过去腾位置：

```c
pcb = memp_malloc(MEMP_TCP_PCB);
if (!pcb) { tcp_handle_closepend();       /* 先抢救挂着 FIN 的 */
  tcp_kill_timewait();      pcb = retry;  /* 杀最老 TIME_WAIT */
  if (!pcb){ tcp_kill_state(LAST_ACK); pcb=retry;
  if (!pcb){ tcp_kill_state(CLOSING); pcb=retry;
#if ESP_LWIP
  if (!pcb){ tcp_kill_state(FIN_WAIT_2); pcb=retry;  /* ← IDF 加长链 */
  if (!pcb){ tcp_kill_state(FIN_WAIT_1); pcb=retry; }}}
#endif
  if (!pcb){ tcp_kill_prio(prio); pcb=retry; } }}
```

Vanilla 只到 CLOSING；ESP-LWIP 版本把 killing 链延伸到 FIN_WAIT_2/FIN_WAIT_1（`#if ESP_LWIP` 包住的两层嵌套额外重试）——对"大量连接卡在半关状态"的嵌入式服务器是个实打实的防饿死补丁。

### 实验 b：55 条短连接的真实堆积与阶梯泄洪

实验设计：QEMU 内 guest 作为 client 连向宿主机 sink 服务（`10.0.2.2:8716`，SLIRP 会把它投递到宿主机 loopback 同端口），发请求、收响应、然后**由 guest 侧先 close**，制造 guest 侧 TIME_WAIT；观测器以 1Hz 快照打印 TW 计数。

一个小插曲本身就是教学点：第一版 sink 收完回复立即 close，结果大部分连接里 **sink 的 FIN 反而先到**，guest 变成了被动关闭方，走了 CLOSE_WAIT→LAST_ACK，TW 几乎堆不起来。改成"sink 阻塞读直到 EOF 再关"消除竞态后才得到教科书曲线。

真实 run.log 关键帧（guest 串口输出，逐字节选 PCBS 行）：

```text
t≈270s 注入 55 条完成
PCBS t=270697 BND=0 LIST=2 ACT=1 TW=57 | SYNRCVD=0 EST=0 FINW1=0 FINW2=1 CWAIT=0 CLOSING=0 LASTACK=0 MEMERR=0
PCBS t=380697 BND=0 LIST=2 ACT=0 TW=61 | SYNRCVD=0 EST=0 FINW1=0 FINW2=0 CWAIT=0 CLOSING=0 LASTACK=0 MEMERR=0   ← 平台期峰值
PCBS t=381697 BND=0 LIST=2 ACT=0 TW=54 | ...                                                                    ← 开始泄洪
PCBS t=383697 BND=0 LIST=2 ACT=0 TW=37 | ...
PCBS t=385697 BND=0 LIST=2 ACT=0 TW=21 | ...
PCBS t=455697 BND=0 LIST=2 ACT=0 TW=5  | ...
PCBS t=456697 BND=0 LIST=2 ACT=0 TW=0  | ...                                                                   ← 清空
```

三个读数：堆积速度约等于注入速率；平台期严格等于 `2×MSL`（第一批创建于 ≈260.6 s、第一批过期于 ≈381.7 s）；回收不是瞬间清零而是**按入池顺序的阶梯泄洪**——每个 PCB 的 `tmr` 记录的是各自 FIN 到达时刻，谁先进池谁先满期，曲线的斜率恰好复现了当初的注入斜率。配套地，`tcp_new_port` 因为绕开 TW 表，55 条连接用的是 55 个不同的临时端口——不存在端口冲突，但也意味着突发短连场景下 ephemeral 端口的消耗速率是平时的 120 s 倍。

---

## 11.5 半打开与僵尸连接

### 场景定义

对端崩溃（拔电、内核 panic、NAT 表项超时）之后，本端可能拿着一个对它而言完全健康的 ESTABLISHED PCB——收不到任何东西，也没有任何机制告诉你对面已经没了。lwIP 的应对只有两把刷子：keepalive 探测（被动检测）与写操作 RTO（主动试错的副产品）。

### keepalive 的三参数 plumbing

IDF 把 upstream 的 `LWIP_TCP_KEEPALIVE` 直接硬编码为 1（`port/include/lwipopts.h`），不需要 Kconfig 打开。socket 层单位是**秒**，netconn/raw 层是毫秒（源码注释原话 _"Note that TCP_KEEPIDLE and TCP_KEEPINTVL have to be set in seconds"_）；默认值在 `priv/tcp_priv.h`：

```c
#define TCP_KEEPIDLE_DEFAULT 7200000UL  /* 2 小时：默认根本等不起 */
#define TCP_KEEPINTVL_DEFAULT 75000UL
#define TCP_KEEPCNT_DEFAULT   9U
```

慢定时器里的判断骨架（`tcp_slowtmr()`）：

```c
if (ip_get_option(pcb, SOF_KEEPALIVE) &&
    (pcb->state == ESTABLISHED || pcb->state == CLOSE_WAIT)) {
  if (ticks - pcb->tmr > (keep_idle + keep_cnt*keep_intvl)/TCP_SLOW_INTERVAL) {
    ++pcb_remove; ++pcb_reset;           /* 彻底放弃：杀 PCB 并回 RST */
  } else if (ticks - pcb->tmr > (keep_idle + keep_cnt_sent*keep_intvl)/...) {
    err = tcp_keepalive(pcb);            /* 发探测包 */
    if (err == ERR_OK) pcb->keep_cnt_sent++;
  }
}
```

探测包本身很吝啬：`tcp_keepalive()`（`tcp_out.c`）发送 seqno=`snd_nxt − 1` 的空载 ACK——故意重复上一个已确认的字节号，若对端健在会用重复 ACK 应答且不干扰序号流。

注意停顿：如果期间收到了该 PCB 的任何合法段，`tcp_process()` 会刷新 `pcb->tmr`，整条倒计时归零。**keepalive 探测的是"这条连接沉默多久了"，不是"对端进程死没死"**。

### 实验 c：亲眼看 PCB 被缓慢处决

对端的 kill -9 若让它发不出 FIN/RST（真实世界的断电、防火墙吞包皆如此），就有机会观察到完整的"僵尸处决"流程。难点在于怎么确定性制造"真正的静默"：宿主机和 QEMU 的 SLIRP 之间还有一个"两阶段代理"，在主机层 iptables 拦不到 guest 协议栈看见的东西。

解法是**应用内注入**（工程自带，见 11.8）：通过根 CMakeLists 的 `-include` 把 `LWIP_HOOK_IP4_INPUT` 强制注入 lwIP 组件编译，hook 拿到"武装令"（VICTARM/VICTFIRE 两阶段）后，捕获受害者元组并**吞掉其全部入向段——包括对端死后 SLIRP 送来的 FIN/RST**。于是 guest 协议栈眼里的世界和对端真的消失一模一样：

```text
（宿主机）VICTARM → python 客户端连入并发 12B → echo 成功 → VICTFIRE → kill -9 -SIGKILL 子进程

I (15302) ch11lab: srv PASSIVE recv 12 bytes
W (15882) ch11lab: INJECT swallow inbound 10.0.2.2:46954 flags=0x11 len=10   ← 对端重传的数据+FIN 全被吞
W (16722) ch11lab: INJECT swallow inbound 10.0.2.2:46954 flags=0x11 len=10
PCBS t=15159 BND=0 LIST=2 ACT=1 TW=5 | SYNRCVD=0 EST=1 FINW1=0 FINW2=0 CWAIT=0 CLOSING=0 LASTACK=0 MEMERR=0   ← EST 卡死不动
PCBS t=20159 ... ACT=1 TW=5 | SYNRCVD=0 EST=1 ...                                                            ← 10 秒过去仍未察觉
W (24722) ch11lab: INJECT swallow inbound 10.0.2.2:46954 flags=0x11 len=10    ← 对端的 EOF 还在撞墙
PCBS t=25159 ... ACT=1 TW=5 | SYNRCVD=0 EST=1 ...                            ← 第 3 次探测均已发出
W (26722) ch11lab: srv PASSIVE recv ABORTED len=-1 errno=113 (keepalive timeout path)
I (27322) ch11lab: srv PASSIVE closed fd=56                                   ← PCB 已由 slowtmr 清理
PCBS t=27159 BND=0 LIST=2 ACT=0 TW=5 | SYNRCVD=0 EST=0 FINW1=0 FINW2=0 CWAIT=0 CLOSING=0 LASTACK=0 MEMERR=0   ← 无任何中间态快照被拍到
```

其中 errno=113 (EHOSTDOWN) 这个语义错位的错码，第五章在 TCP 背景下已经见过一次（accept 侧）——两次现身皆是 ERR_ABRT 类事件的 socket 化身，记牢它能省掉不少排障时间。整个过程的时间线：`fire → idle 5 s → 第 1~3 次探测间隔 2 s → 第 4 tick slowtmr 命中判据（合计 ~11.5 s）→ pcb_reset 回 RST → 事件回调`,与代码推演完全一致。事后看 `ACT 1→0` 的跳变同样印证：**slowtmr 是唯一有资格杀死健康-looking PCB 的执行者，而它的工作方式是快照之外的瞬移**——1Hz 观测器一帧都追不上 CLOSE_WAIT 之前的过渡态。

配套的另一半知识：若没开 keepalive，僵尸 PCB 将活到你下一次 write 并且 RTO 退避打满 `TCP_MAXRTX`（IDF 默认 12 次、配合指数退避总时长可达分钟级，第十二章实测过 3000 ms 台阶）。两条路都通向同一个结局：`ERR_ABRT`/`EHOSTDOWN` 类错误码 + PCB 静默蒸发。

---

## 11.6 listen backlog 的 lwIP 语义与 SYN 积压

### 一个词，三种实现

| 实现层面    | 本质                                                      | 上限判定                         |
| ----------- | --------------------------------------------------------- | -------------------------------- |
| BSD Linux   | 半开队列（syn queue）+ 全连接队列                         | `ss` 可见的 drop 计数、溢出日志  |
| lwIP 裸 API | `lpcb->backlog`(u8) vs `accepts_pending`(u8) 两个整数比较 | `tcp_backlog_set()` 撞的就是它们 |
| socket API  | `listen(fd, n)` → netconn 转存到 backlog 字段             | idem                             |

没有独立的队列对象，甚至没有 packet 缓冲。三次握手的 SYNLedger 只体现在两个字节的差值上（`TCP_LISTEN_BACKLOG=1`，IDF 硬编码启用）。应用接受一条（`accept()` 或 raw 回调完成后调 `tcp_backlog_accepted`），差值减一。

### SYN_RCVD 也要吃整份口粮

每个 SYN 不论是否完成握手都占用一个完整的 `tcp_pcb`（memp 池一格）。IDF 把 `MEMP_NUM_TCP_PCB` 直接绑到 `CONFIG_LWIP_MAX_ACTIVE_TCP`（默认 16，范围 1~1024），listener 单独有 `CONFIG_LWIP_MAX_LISTENING_TCP`（默认 16）。**因此"backlog + 常驻连接 + TIME_WAIT 尾巴"三者共享同一个池子**，全堆化下池容量是它们共同的镣铐（参见第五章）。

兜底机制在慢定时器里：

```c
if (pcb->state == SYN_RCVD) {
  if (tcp_ticks - pcb->tmr > TCP_SYN_RCVD_TIMEOUT / TCP_SLOW_INTERVAL)
    ++pcb_remove;        /* 20 s 必须毕业或死亡 */
}
```

### 超额时的两个静默分支

结合 11.2 的代码，SYN 过量时有两条互斥的静默出口：

1. `accepts_pending >= backlog` → 直接 return（连统计都不动，只有 debug 日志）；
2. `tcp_alloc()` 失败 → `memerr++` 后 return（注释原文说"指望发送方稍后重传 SYN"）。

两者都**不发 RST**。攻击侧看来是无响应黑洞，只能靠自己的 SYN 重传来摸天花板；而每次重传又会再次撞在墙上累计 memerr。与传统 BSD 不同的是，**lwIP 没有任何 syncookie 类的无状态防御**（grep 全树无此概念），但胜在小 PCB 内存代价低 + 20 s 硬顶。另外 IDL 把 SYN_RCVD 的 RTO 退避豁免纳入了 ESP_LWIP 补丁（下一节展开），半连接的 SYN|ACK 不会随 nrtx 指数拉爆占用时长——20 s 定时才是主导毕业率的关键。

### 实验 d：池压到 2，目击黑洞

变体固件 `build_d` 把 `CONFIG_LWIP_MAX_ACTIVE_TCP` 设为 2。FREEZE 模式（又一个 hook 规则）会吞掉去往 ：8814 的纯 ACK——也就是三次握手的最后一脚，从而人为冻结全部 handshake 完成，制造无限半开积压。

构建与执行命令（完整版见 README）：

```bash
idf.py -B build_d -D SDKCONFIG=sdkconfig.d11 \
  -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.ch11d.defaults" build
idf.py -B build_d qemu monitor < /dev/null || true    # 出镜像
# 启 QEMU（同 README 命令，file= 换成 build_d/...）后：
python3 scripts/exp11.py --phase d
```

脚本动作：FREEZE ON → 宿主机 6 条连接陆续 connect（宿主内核眼里全部成功）→ 持锁跨越 20 s 自愈边界 → thaw → STAT。真实观测三联（guest 串口 + 驱动端输出）：

**现象一：SYNRCVD 饱和在池盖子上，不多不少**

```text
PCBS t=16165 BND=0 LIST=2 ACT=2 TW=0 | SYNRCVD=2 EST=0 FINW1=0 FINW2=0 CWAIT=0 CLOSING=0 LASTACK=0 MEMERR=3
PCBS t=30165 附近 14 行连续 PCBS：ACT=2 TW=0 | SYNRCVD=2 EST=0 ... MEMERR 从 4 爬到 8 再到 10
```

**现象二：超额 SYN 进入黑洞，memerr 成为唯一心跳**

```text
W (15999) ch11lab: INJECT drop ACK3 41216->8814        ← 共命中 45 次（grep -c）
...
PCBS t=44165 BND=0 LIST=2 ACT=2 TW=0 | SYNRCVD=2 EST=0 FINW1=0 FINW2=0 CWAIT=0 CLOSING=0 LASTACK=0 MEMERR=11
STAT  recv=36 xmit=59 drop=0 chkerr=0 lenerr=0 memerr=13    （驱动端收到的应答）
```

宿主 shell 连"撤退"命令都被卡空（thaw 响应为空串）：此刻 guest 的 TCP 资源全部窒息，连我们控制通道的新建连接都得排队——黑洞连自己在吞噬什么都顾不上申报。而 `drop` 计数始终是 0：**真正沉默的死法，不会在任何 drop 类计数器里留下墓碑，只会在 memerr 里加息**。

**现象三：拆卸波完成清空**

```text
PCBS t=45165 BND=0 LIST=2 ACT=2 TW=0 | SYNRCVD=2 EST=0 FINW1=0 FINW2=0 CWAIT=0 CLOSING=0 LASTACK=0 MEMERR=11
PCBS t=46165 BND=0 LIST=2 ACT=2 TW=0 | SYNRCVD=0 EST=0 FINW1=0 FINW2=0 CWAIT=2 CLOSING=0 LASTACK=0 MEMERR=13
```

持锁端 close 后 THAW，对端拆卸段涌入：一帧之内 SYNRCVD 清零、memerr 落定 13、两格 CLOSE_WAIT 是拆卸波的残影——下一帧池子彻底复原，STAT 命令重新可以应答。三条证据链合起来把"半开洪水自愈周期"完整钉死在了日志上。

一份反直觉补充：由于 STATE 化的 fork 需要 listener 前提，冻结窗口内 `backlog` 门根本没机会成为瓶颈（alloc 早一步先把 SYN 拒了）。想要专门踩中 backlog 路径，需要放大 active 池并精确维持 accepts_pending≥backlog 的窄边界——日常配置下，memerr 分支几乎总是先牺牲的那个。

顺带交代调试时的经典弯路：起初 FREEZE 死不生效，打印段原始头发现 `p->tot_len=50` 而 IP 头 Total Length 仅 40——openeth 收包路径会把以太网填充一并计入 pbuf。**协议头字段的权威永远是 IPv4 header 自己报的总长，不要信任链路层的货箱尺寸**。这也再次证明入向问题必须抓包层次化排查——从 pbuf 到 ip 到 tcp 各自的头长度契约彼此独立。

---

## 11.7 Vanilla vs ESP-IDF：TCP 状态相关的裁剪清单

| 维度                          | Vanilla lwIP 2.2.0-dev                     | ESP-IDF v6 lwIP                                                                                                          | 出处（grep 得证）        |
| ----------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ | ------------------------ |
| TCP 定时器间隔                | `TCP_TMR_INTERVAL` 250ms                   | 同值，Kconfig `CONFIG_LWIP_TCP_TMR_INTERVAL` 可调                                                                        | Kconfig TCP 菜单         |
| MSL（TIME_WAIT 半衰期的一半） | `TCP_MSL` 60000ms 手改 opt                 | `CONFIG_LWIP_TCP_MSL` 可调（默认 60000 → TW 120s）                                                                       | port lwipopts.h          |
| FIN_WAIT_2 死亡线             | 20000ms                                    | `CONFIG_LWIP_TCP_FIN_WAIT_TIMEOUT` 同默认                                                                                | idem                     |
| `TCP_LISTEN_BACKLOG`          | opt.h 默认 0                               | **硬编码 1**（backlog 功能必开）                                                                                         | port/include/lwipopts.h  |
| MEMP 门（活动/监听）          | memp 静态计数                              | `CONFIG_LWIP_MAX_ACTIVE_TCP`(≤1024)/`_LISTENING_TCP`(≤1024)，默认均 16；实际 MEMP 静态数组因全堆化而不存在，仅计数器有效 | Kconfig + 第五章         |
| keepalive 功能开关            | `LWIP_TCP_KEEPALIVE` 手改                  | **硬编码 1**（`TCP_KEEPIDLE` 等选项开箱可用）                                                                            | port/include/lwipopts.h  |
| keepalive 默认参数            | 2h/75s/9 次 RFC1122 原味                   | 同 vanilla 默认，需应用自行缩短                                                                                          | priv/tcp_priv.h          |
| RTO 退避豁免                  | 只豁免 `SYN_SENT`                          | **ESP_LWIP 补丁扩展到 SYN_SENT && SYN_RCVD**（`if (pcb->state != SYN_SENT && pcb->state != SYN_RCVD)`）                  | core/tcp.c tcp_slowtmr() |
| tcp_alloc 杀戮链升级          | TIME_WAIT → LAST_ACK → CLOSING → kill_prio | 增加 FIN_WAIT_2 / FIN_WAIT_1 两级（ESP_LWIP 包裹的双层嵌套重试）                                                         | core/tcp.c tcp_alloc()   |
| SO_REUSEADDR                  | 默认关闭                                   | `CONFIG_LWIP_SO_REUSE` 默认 y                                                                                            | components/lwip/Kconfig  |
| LWIP_HOOK_IP4_INPUT           | opt.h 文档型钩子                           | 保持上游可用（本项目用它做入向故障注入）                                                                                 | 本章实践                 |

两句话总结暗线 B：IDF 对 TCP 状态机的改造集中在"资源有界嵌入式"口味——**把时间常数变成 Kconfig、把功能的可用性焊死、把逃生链延长**；协议行为本身（所有迁移边）未动一字。

---

## 11.8 实验台：如何给单线程状态机装监控

### 工程布局

`practice/lwip-ch11-tcp-state-machine/`（完整构建/运行命令在该 README，此处给出最小集）：

```bash
. ~/esp/esp-idf/export.sh && cd practice/lwip-ch11-tcp-state-machine
idf.py set-target esp32 && idf.py build                      # 主固件
idf.py qemu monitor </dev/null || true                       # 出镜像
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
$QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8014-:8814,hostfwd=tcp::9014-:8813 \
  -nographic -no-reboot > logs/exp.log 2>&1 &
python3 scripts/exp11.py --phase a_passive                   # a_active/b/c/d
```

端口纪律遵守系列公约：章节专用 `8014`（演示服务），另有控制通道 `9014→guest:8813`（避开已占用的 8003/8005/8006/8009/8010~8012/8019）。

### 观测器：借助 tcpip_callback 回家

从普通任务遍历 PCB 链表是数据竞争；正确姿势是把快照函数投进 `tcpip_thread` 自己的队列：

```c
static void observer_task(void *arg) {
  while (1) {
    tcpip_callback(pcb_snapshot_cb, NULL);     /* 在 tcpip 上下文执行 */
    vTaskDelay(pdMS_TO_TICKS(s_obs_period_ms));
  }
}
```

快照输出两行式：一行直方概览（`PCBS t=.. BND=.. LIST=.. ACT=.. TW=.. | SYNRCVD=.. EST=.. ... MEMERR=..`），一至八行明细（`PCBD`，含远端四元组与 `age_ms=(tcp_ticks-pcb->tmr)*TCP_SLOW_INTERVAL`）。四条链表逐一走访即可写出 `netstat`-界面的嵌入式孪生兄弟。

### 故障注入：不入库的 hook

劫持入向流的候选方案有三个：改编译期支持的 `LWIP_HOOK_IP4_INPUT` 宏（本项目采用：根 CMakeLists 用 `-include` 强塞头文件声明宏+原型，spare 组件目录零污染）；替换 `netif->input` 函数指针（第七章镜像手法的 RX 版，但 openeth 项目的真实入站未必途经这一跳，实测发现不可靠才切换方案）；在驱动入口筛查（侵入最深）。hook 的返回约定见 `opt.h`：非 0 表示消费该 pbuf（所有权移交，须自行 `pbuf_free`），否则返回 0 放行。**另一个实战教训已经写在代码注释里：判断载荷是否为零要用 IPv4 头里的 Total Length 字段，openeth 上行的 pbuf 可能携带以太网填充**（`p->tot_len=50` vs `iph_tot=40` 一案）。

四种模式对应四个实验：PASSIVE/ACTIVE 决定演示服务器的关闭姿态；GW 驱动 guest 出向风暴；VICTARM+VICTFIRE 制造真半打开；FREEZE 吃掉第三次握手制造 SYN 黑洞。

---

## 11.9 小结

- **驱动模型**：TCP 状态机的每一次跳动都发生在 `tcpip_thread`：输入段驱动 `tcp_input→tcp_process` 的 switch，`tcp_slowtmr`(500ms) 负责 RTO/keepalive/TIME_WAIT(2MSL)/LAST_ACK(2MSL)/SYN_RCVD(20s)/FIN_WAIT_2(20s,需TF_RXCLOSED) 六类时限，`tcp_fasttmr`(250ms) 补延迟 ACK 和搁浅 FIN。应用回调全程被同步调度，不引入第二个执行流。
- **双家族结构**：`tcp_pcb_listen` 是带 accept/backlog 的轻壳；SYN 到达时 `tcp_listen_input` fork 出完整 `tcp_pcb`（出生态 SYN_RCVD、`TCP_REG_ACTIVE` 入列、继承 SOF_INHERITED 选项）；accept 回调要到第三次 ACK 才响。超额两条静默路：backlog 满与 tcp_alloc 失败（memerr++），一律不回 RST。
- **demux 瀑布**：active → TIME-WAIT → LISTEN 三级匹配，命中提头缓存；no-match 非 RST 段回 RST。RST 需资格审查（SYN_SENT 认 ACK 里的 snd_nxt、他态认 rcv_nxt 精确、窗口内给挑战 ACK，RFCC 5961 防 CVE-2004-0230）；通过的 RST 是唯一能即刻终结 PCB 的输入。
- **关闭不对称律**：TIME_WAIT 只归属先动手关闭的一方，走 FIN_WAIT_1/{FIN_WAIT_2,CLOSING} 系；被动方走 CLOSE_WAIT→LAST_ACK 直达销毁。入 TIME_WAIT 的前提是自己最后字节全被 ACK；同时关闭自然诞生 CLOSING 边。`.shutdown(WR)` 半关闭后仍可继续收数据。
- **TIME_WAIT 实现**：tw PCB 只有两件事（应答迟到 FIN/乱窗 SYN、按 tmr 判期销毁）；IDF 默认 `2*CONFIG_LWIP_TCP_MSL`=120s；到期回收不是整齐清零而是按各自入池时刻的阶梯泄洪。临时端口分配扫描含 tw 的全部四链表，bind 侧 SO_REUSEADDR 能跳过 tw 表查重；tcp_alloc 缺格时按 TIME-WAIT→LAST-ACK→CLOSING→(IDF+)FIN_WAIT_2→FIN_WAIT_1→低优先级 依次击杀腾位。
- **半打开处置**：keepalive（seq=snd_nxt−1 的空 ACK）三参数 sockets 层单位秒、raw 层毫秒，IDF 默认 2h/75s/9 基本只能靠手动缩小才实用；判据基于 PCB 沉默时长（任何来段都会刷新 tmr），超限即 abort+回 RST，socket 层常见 EHOSTDOWN/ECONNRESET 语义错位。无 keepalive 则僵尸活到下次写操作 RTO 退避打满为止。
- **backlog 与 SYN 积压**：lwIP 的 backlog 就是两个 u8 的比较，没有队列实体；每半开连接消耗完整 `tcp_pcb` 配额（与其他 PCB 共池）；20 秒 SYN_RCVD 硬顶 + slirp 无 cookie，池耗尽表现为纯静默黑洞，`tcp.memerr` 是唯一可观测化石。
- **Vanilla/IDF 差异集中在刀刃外**：时间常 Kconfig 化、功能（backlog/keepalive）硬编码启用、RTO 退避豁免扩至 SYN_RCVD、alloc 杀戮链延长两级；协议迁移边零改动。入向观测/注入推荐编译期 `LWIP_HOOK_IP4_INPUT` + `-include` 注入法，并以 IP 总长字段为准裁剪载荷判定。
- **实验战绩**：a(双关闭姿态序列抓拍)、b(TW 堆 61 与 120 s 悬崖)、c(hook 真吞 RST/FIN + keepalive 11 s 处决 + errno=113)、d(SYNRCVD=2 饱和/memerr 心跳/黑窗/恢复)。四个故事的每个转折都在 run.log 留了指纹。

下一章走进 TCP 的"内容世界"：重传如何记账、RTT 如何估摸、cwnd 如何爬坡，以及接收窗口如何反向塑造发送方的心跳——可靠性追求的细节数不胜数，见 [[2026-08-26-lwip-deep-dive-ch12-tcp-reliability-flow-control|第十二章：TCP 可靠性与流量控制]]。
