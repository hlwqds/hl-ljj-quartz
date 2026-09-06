---
title: "lwIP 深度解析（十五）：raw API：回调式编程的艺术与陷阱"
date: 2026-08-26
description: "逐行走读 raw TCP API 的八个回调挂点与返回值协议（ERR_OK 继续消费、非 OK 进入 refused_data 重投、ERR_ABRT 必须先自行 tcp_abort 的契约），给出官方 tcpecho_raw 同款的 per-connection 状态机模板与三段式拆除法；三大陷阱（回调内阻塞、跨线程再入、长处理反压）逐一配错误代码与 QEMU 实证：busy-wait 200ms 注入让两条并发连接的 RTT 塌缩到 200/400ms 台阶、clean 103 Mbit 流量被压到 0.06 Mbit；CHECK_THREAD_SAFETY=y 后 udp_new 在 app_main 当场断言复位。raw vs socket 同题实测：64B RTT 中位 162 vs 439µs（2.7 倍税）、回显校验吞吐 68 vs 39 Mbit。附一次 livelock 排障实录。"
tags: [lwip, network, esp32, esp-idf, qemu, raw-api, tcp]
---

> [!info] lwIP 深度解析系列 0. [[lwip-deep-dive|系列索引]] 15. **第十五章：raw API：回调式编程的艺术与陷阱**

# lwIP 深度解析（十五）：raw API：回调式编程的艺术与陷阱

这一章回答三个问题：**为什么 raw API 是协议栈的原生 API**（netconn 与 socket 不过是在它外面套信箱和 POSIX 皮）、**一串回调怎么织成一个状态机**（arg 指针携带的 per-connection 状态、八个回调的触发时机与返回值协议）、以及**"最快"要付什么代价**（重入纪律、阻塞禁令、长处理反压）。读完它，你应该能看着任何一段 raw API 代码，指出它哪一行在违反契约、哪一行会在流量洪峰时反噬协议栈线程。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`~/esp/esp-idf/components/lwip/lwip/src`），核心文件 `core/tcp.c`/`core/tcp_in.c`/`core/tcp_out.c`，回调原型文档 `include/lwip/tcp.h`，事件分发宏 `include/lwip/priv/tcp_priv.h`；移植层 `components/lwip/port/include/lwipopts.h`。所有实验数字来自第 15.6 节的 QEMU 实测。

---

## 15.1 核心问题三连

### 1. raw API 为什么是"原生"API

[[ch13-tcpip-thread-mailbox|第十三章]]讲过：整个协议栈活在一个单线程 `tcpip_thread` 里，一切输入处理、定时器、应用请求都在它的邮箱循环里串行。netconn 和 socket 这两层为了进入多任务世界，做了同一件事——**把"内核态"发生的事件从 tcpip_thread 邮寄出来**：

|              | raw API                               | netconn                                                    | socket                                  |
| ------------ | ------------------------------------- | ---------------------------------------------------------- | --------------------------------------- |
| 本质         | **tcpip_thread 内直接执行的函数指针** | raw 回调内 `sys_mbox_trypost(recvmbox)` + 应用任务阻塞收信 | netconn 之上再加 VFS fd 层与 errno 翻译 |
| 事件送达路径 | 协议栈调用点原地调用你的函数          | 包成 netbuf 投递邮箱 ⟳ 任务切换                            | 同 netconn + memcpy                     |
| 谁拥有数据   | **你拿到 pbuf 指针的所有权**          | netbuf 转交所有权                                          | 拷贝进用户缓冲区                        |

[[ch10-udp-pcb-layers|第十章]]已经给这套分层标过价：UDP echo 的 64B RTT 中位数 raw 103µs → netconn 215µs → socket 288µs。也就是说**不是"socket 太慢"，而是"raw 太快"**——它省掉的每一项（两次任务切换、两次拷贝、一层 VFS 间接）正是后两层存在的理由。协议栈内部自己的住户几乎全是 raw API：DNS 解析器用 `udp_new()` 发查询（`core/dns.c`）、SNTP 用 `udp_recv()` 收时间戳（`src/apps/sntp/sntp.c`）、DHCP 客户端把 PCB 一出生就 bind(:68)+connect(:67)。tcp.h 文件头的第一句话就是立场声明：_"TCP API (to be used from TCPIP thread)"_。

### 2. 回调链怎么织成状态机

socket 编程的心智模型是"每个连接一条执行流"；raw API 反转过来：**每个连接只有一份数据（PCB），执行流永远是同一条 tcpip_thread**。所谓"连接的状态"不在栈帧里，必须挂在别处——这就是 `tcp_arg(pcb, es)` 把一个 `es_t*` 缝到 PCB 上、随后每个回调第一件事 `es = arg` 取回的原因。八个回调像八种中断：数据到达（recv）、对端确认（sent）、周期巡检（poll）、致命错误（err）……你的任务是把它们接成一个显式状态机。15.3 节给出官方推荐的织法。

### 3. "最快"的代价是什么

省掉调度的另一面是**没有调度器替你兜底**。三条铁律提前立此存照，每条都是 15.4 节的一个陷阱现场：

1. 回调里不准阻塞——你不是"等待"，你是**堵住了全系统唯一的协议栈线程**；
2. 回调之外碰 raw API 必须经 `tcpip_callback()` 投递——PCB 字段没有锁，裸碰是未定义行为；
3. 回调里干长活等于亲手掐住 ACK 与接收窗口——TCP 的背压会以 RTO 风暴的形式讨回来。

---

## 15.2 raw TCP API 全景走读

### 1. 从 pcb 到 listen：四步搭建

```c
struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
tcp_bind(pcb, IP_ANY_TYPE, PORT_RAW);                 /* 冲突→ERR_USE */
struct tcp_pcb *l = tcp_listen_with_backlog(pcb, 4);  /* 注意！ */
tcp_accept(l, srv_accept_cb);
```

源码读出来的两个关键性质。其一，`tcp_listen_with_backlog_and_err()`（`core/tcp.c`）并不是"把这个 pcb 改个状态"：它 `memp_malloc` 一个新的 `tcp_pcb_listen`，把端口/地址/callback_arg 拷过去，`tcp_free(pcb)` 释放原 PCB，再把 lpcb 注册到全局链表 `tcp_listen_pcbs.pcbs`。**listen 之后原 pcb 指针即作废**，继续用它等于 use-after-free。其二，`tcp_bind` 的冲突检查扫的是 bound/listen/active 三条链，任一方无 SOF_REUSEADDR 即拒绝——这就是五条 `tcp_pcb_lists[]`（bound/listen/active/tw，见 `include/lwip/priv/tcp_priv.h`）的存在意义之一。

### 2. 八个回调：谁触发、何时触发

服务器侧注册 5 个（accept/recv/sent/poll/err），客户端侧重 connected；加上 arg/listen 共十个常用入口。"八个回调"指完整生命周期里你会与之打交道的成员（含 listen PCB 上的 accept）。逐一对上 `tcp_priv.h` 里 `TCP_EVENT_*` 宏的分发点：

| 回调               | 触发点（源码位置）                                 | 触发时机                           | 你应当做什么                                            |
| ------------------ | -------------------------------------------------- | ---------------------------------- | ------------------------------------------------------- |
| accept             | `tcp_in.c` `tcp_process()` SYN_RCVD→ESTABLISHED    | 三次握手完成的那一个报文里同步调用 | 分配 per-connection 状态并挂钩子；资源不足就拒绝        |
| recv               | `tcp_in.c` `tcp_input()` 中 `TCP_EVENT_RECV`       | 按序数据到达                       | 消费所有权：free 或保存；按需 `tcp_recved` 归还窗口     |
| sent               | `tcp_in.c` 收到 ACK 使 `recv_acked>0` 时           | 对端确认了 len 字节                | 释放发送端资源、补发积压数据（发送泵！）                |
| poll               | `tcp.c` `tcp_slowtmr()` 每 `interval` 个慢定时节拍 | 兜底泵/保活/超时关闭               | 补发、空闲回收；只在返回 ERR_OK 时栈才代跑 `tcp_output` |
| err                | `tcp_in.c` RST 处理、`tcp_slowtmr` 放弃重传等      | RST 或异常死亡                     | **pcb 已被释放**！只许清理自己的 es                     |
| connected          | `tcp_process()` 主动打开 SYN-ACK 到达              | tcp_connect 之后握手完成           | 客户端起点，发首批数据                                  |
| arg                | ——（不是事件）                                     | 绑定状态指针                       | ——                                                      |
| listen/accept 配对 | ——                                                 | 结构上的载体                       | ——                                                      |

三个容易读漏的语义细节：

- **recv 没有 `tcp_recved` 强绑定**。数据交付与窗口归还是两回事：不调 `tcp_recved`，通告窗口（`rcv_ann_wnd`）就会朝零收缩——这既是背压的正道（主动扣住），也是事故的高发区（忘了调）。
- **EOF 也走 recv**：FIN 到达时 `TCP_EVENT_CLOSED` 宏展开为 `recv(arg, pcb, NULL, ERR_OK)`。`p==NULL` 就是"对面写完了"。
- **无 recv 回调时有缺省行为**：未注册时 `TCP_EVENT_RECV` 落到 `tcp_recv_null()`（`core/tcp.c`）：有数据则 `tcp_recved` 后 free，`p==NULL` 则直接 `tcp_close`。内核给的默认体面，恰是你自定义时的义务清单。

### 3. 返回值协议：ERR_OK / 非 OK / ERR_ABRT 三档语义

tcp.h 对每个回调原型的注释都重复同一句硬话："**Only return ERR_ABRT if you have called tcp_abort from within the callback function!**" 结合 `tcp_in.c` 的分支结构，recv 的返回值实际是三档协议：

```text
recv 返回
├─ ERR_OK      继续正常流水线（后续还会问你要不要发数据）
├─ 其他 err    !=ERR_OK 且 !=ERR_ABRT：数据被塞进 pcb->refused_data
│              （tcp_input 原注释:"keep incoming packet, because pcb is full"）
│              由下一轮输入或 fasttmr 经 tcp_process_refused_data() 重投给你
└─ ERR_ABRT    栈完全相信你已经在此回调内调用过 tcp_abort()，
               直接 goto aborted 清场，绝不再碰这个 pcb
```

要点拆解：

1. **ERR_ABRT 是免责声明，不是处决命令**。栈收到它后的动作只是跳转到 `aborted:` 标签并且"Below this line, 'pcb' may not be dereferenced!"——真正 free PCB 的人必须是你在回调里自己调的 `tcp_abort()`。只返 ABRT 不动手，PCB 就悬在那里没人管。
2. **"其他错误"不是失败，是欠条**。返回 `ERR_MEM` 表示"我暂时吃不下"，栈替你把整包存在 `refused_data` 里欠着，下个报文到来或 fast 定时器滴答时重投。这是内核内置的收端背压机关——但它同样会推动通告窗口收缩（窗口不再因 tcp_recved 而扩大），15.4(c) 的故事的另一半在这里。
3. **accept 的返错另有兜底**。`tcp_process()` 里若 accept 返回非 ERR_OK：不是 ABRT 就由**栈自己**补一刀 `tcp_abort(pcb)` 再统一按 ABRT 处理。于是有两种正确姿势：懒人版"随便返个错让栈来杀"，谨慎版"自己 `tcp_abort()` 后返 ERR_ABRT"。但 recv/sent/poll/connected **没有这个兜底**——契约差异务必记住。
4. **err 回调是遗书**。调用它时 PCB 已被核心释放，你唯一能做的是拿回 arg、清理堆内存。试图在里面调 `tcp_close(pcb)` 就是踩尸。

---

## 15.3 回调链状态机模式：官方推荐的织法

### 1. per-connection 状态挂在 arg 上

lwIP 自带示例 `contrib/apps/tcpecho_raw/tcpecho_raw.c` 给出的范式（本章实验工程照抄其骨架）：

```c
typedef struct {
    struct tcp_pcb *pcb;
    /* 状态字段：待发 pbuf 链、生命周期标记、统计…… */
} es_t;

static err_t srv_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    es_t *es = calloc(1, sizeof(*es));
    if (!es) { tcp_abort(newpcb); return ERR_ABRT; }   /* 自己动手 */
    es->pcb = newpcb;
    tcp_arg(newpcb, es);
    tcp_recv(newpcb, rx_cb); tcp_sent(newpcb, sent_cb);
    tcp_err(newpcb, err_cb); tcp_poll(newpcb, poll_cb, 4);
    return ERR_OK;
}
```

设计规则有三条。**其一，es 只在 tcpip 线程里出生入死**——accept 分配、recv 更新、err/poll 回收，全程无需锁；一旦越过线程边界去共享它，就已经掉进陷阱 (b)。**其二，每条路径都要想清楚"谁来 free 谁"**：pbuf 所有权在你手里（交给 `tcp_write(COPY)` 后即可 free；NO_COPY 则必须活到 sent 之后——IDF 因 `TX_SINGLE_PBUF=1` 强制 COPY，见[[ch6-zero-copy-tcp-write|第六章]]）；es 由你管理；pcb 由核心管理。**其三，别指望 recv 单打独斗**：snd_buf 装不下、ACK 未回、FIN 提前到达，都要求状态机横跨多个回调推进。

### 2. 拆除连接的三段式（错误姿势集锦）

```c
/* 错误姿势①：fin 只发 stat，忘 close —— 连接卡死在 CLOSE_WAIT */
static err_t rx_bad(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t e)
{ if (!p) { stats++; return ERR_OK; }   /* 返回值没错，但没人关 pcb */ ... }

/* 错误姿势②：回了 ERR_ABRT 却没调 tcp_abort —— PCB 悬空，泄漏无人认领 */
static err_t rx_bad2(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t e)
{ pbuf_free(p); return ERR_ABRT; }

/* 错误姿势③：调了 tcp_abort 还返 ERR_OK —— 栈继续用已释放的 pcb，UB */
static err_t rx_bad3(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t e)
{ tcp_abort(pcb); return ERR_OK; }
```

正确姿势是把收尾收敛到一个函数，谁最后摸到状态谁负责调用它：

```c
static void teardown_abrt(struct tcp_pcb *pcb, es_t *es)
{
    detatch_callbacks(pcb);   /* tcp_arg/recv/sent/err/poll 全部置 NULL */
    es_release_state(es);     /* 释放 pbuf 链与自己 malloc 的 es */
    tcp_abort(pcb);           /* 再杀 pcb —— 顺序不可颠倒 */
}

/* recv 里见到 ABRT 标记：
 *   先消费数据所有权（pbuf_free），再 teardown_abrt(pcb, es)，最后
 *   return ERR_ABRT —— 契约“return ABRT 之前必须已 tcp_abort”逐字满足。*/
```

detatch 在先的意义：把我们的钩子摘干净之后，无论核心随后怎么处置 pcb，都不会再有任何回调拿着已 free 的 es 指针空降。这也是 tcpecho_raw 在 poll 孤儿分支里 `es==NULL` 就 `tcp_abort + ERR_ABRT` 的同款防御。15.6 实验 B 会把姿势①/②放进 QEMU，用 PCB 链表遍历当场验尸。

> [!tip] 一个判定口诀
> 写完任何 raw TCP 回调，先回答三个问题：**数据的所有权走了吗？窗口还了吗？pcb/es 两个人的身后事安排了吗？** 三问皆稳，才算把状态机的边画完。

---

## 15.4 三大陷阱解剖

### 陷阱 (a)：回调里调用阻塞 API = 全栈停摆

```c
/* 崩坏现场：recv 回调里等互斥量 / 干脆睡一觉 */
static err_t rx(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t e)
{
    xSemaphoreTake(s_db_lock, portMAX_DELAY);  /* 若持有者是低优先级任务… */
    vTaskDelay(pdMS_TO_TICKS(50));             /* 或者干脆直接睡 */
    ...
}
```

你是 tcpip_thread。你 sleeping 的每一毫秒，邮箱里堆积的每一个报文都无法前进：输入停摆、重传定时器停摆、其它全部连接的 ACK 停摆。若再叠一个优先级反转（持有者等着往 socket 里 write，而 write 又依赖 tcpip 线程处理它的请求），就是教科书级死锁。[[ch13-tcpip-thread-mailbox|第十三章]]的停摆实验已经给出过结论形态：**tcpip 线程被钉住几秒，全栈所有 PCB 一起陪葬，而表面现象可能只是"网络偶尔卡一下"**——排障时极难第一时间怀疑到某个无辜的回调。正确的解耦方式只有一个：回调只做"搬运 + 标记"，把活儿交给事件标志/队列送到你自己的工作任务里去慢慢消化。

### 陷阱 (b)：跨线程再入 raw API = 未定义行为

"**我在 tcpip 线程外调 tcp_write 它也工作得好好的啊？**"——是的，直到某天两个线程同时改 `pcb->unsent` 链。raw API 的线程安全性来自**执行位置的单一性**而不是锁：IDF 默认 `LWIP_TCPIP_CORE_LOCKING=0`（Kconfig `CONFIG_LWIP_TCPIP_CORE_LOCKING` 默认 n），`LOCK_TCPIP_CORE()` 展开为空，内核里那二十多处 `LWIP_ASSERT_CORE_LOCKED()` 全部是不设防的哨兵。越权访问的正确通道只有一个：

```c
/* 从任意任务安全地把操作投递进 tcpip 线程 */
static void send_fn(void *ctx) {            /* 此刻一定运行在 tcpip 线程 */
    tcp_write((struct tcp_pcb *)ctx, "hi", 2, TCP_WRITE_FLAG_COPY);
    tcp_output((struct tcp_pcb *)ctx);
}
tcpip_callback(send_fn, pcb);   /* memp_malloc(MEMP_TCPIP_MSG_API) 打包 +
                                   sys_mbox_post(tcpip_mbox)（邮箱满则阻塞）*/
```

`api/tcpip.c` 里这段实现值得背下来：投递成本是一次 memp 分配加一次邮箱投递，换来的是独占执行权。IDF 其实留了一道可选闸门：Kconfig `CONFIG_LWIP_CHECK_THREAD_SAFETY`（默认 **n**）会把 port 头文件里的

```c
#define LWIP_ASSERT_CORE_LOCKED() \
    do { LWIP_ASSERT("Required to run in TCPIP context!", \
                     sys_thread_tcpip(LWIP_CORE_LOCK_QUERY_HOLDER)); } while (0)
```

激活——tcpip_thread 启动时用 `LWIP_MARK_TCPIP_THREAD()` 自报家门（`api/tcpip.c` 的 `tcpip_thread()` 开头），此后任何回调外的 raw API 调用都会当场断言复位。15.6 实验 D 在两种构建下分别演示了"无声损坏"与"当场击毙"两个世界。

### 陷阱 (c)：回调里长时间处理 = 反压链条全面收紧

假设 recv 回调平均耗时 T 秒。输入是串行的：tcpip 线程每次只能处理一个以太网帧，其余在网络驱动与 tcpip 邮箱里排队。连锁反应逐环收紧：

```text
T 变大 ──► 每秒能处理的分段数 1/T 下滑
       ──► 已经处理过的报文延迟发出 ACK ──► 对端以为丢包 ──► RTO 重传风暴（参第十二~十三章）
       ──► 新到的按序数据占着 rcv_wnd 无法及时归还
            （app 没来得及 tcp_recved / 内核没来得及递给你的 refused_data）
       ──► 通告窗口 rcv_ann_wnd 步步收缩，甚至归零
       ──► 零窗口 persist 探询期开始（ch12 的探询机登场）
       ──► 链路窒息：对方还连着，吞吐趋近于零
```

这与 UDP 形成刺眼对比：UDP 的慢消费者只弄丢自己的包（[[ch10-udp-pcb-layers|第十章]]的 94% 黑洞），TCP 的慢消费者却通过窗口这一根线把对端的发送节奏也拖垮——**TCP 背压是一份必须按时履约的合同**。实验 C 用注入的 busy-wait 把这条链每一环量化到了 µs。

---

## 15.5 Vanilla lwIP 与 ESP-IDF lwIP 对照

围绕 raw API 维度逐项对照（均经源码 grep 实核）：

| 维度               | Vanilla lwIP 2.2.0-dev                                                    | ESP-IDF v6.0.2 移植                                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 回调开关           | `LWIP_CALLBACK_API` 可配 0（此时全靠 event-API/altcp）                    | 固定开启                                                                                                                                                                         |
| 线程安全闸门       | `LWIP_ASSERT_CORE_LOCKED()` 缺省展开为空（opt.h），需移植层自行定义       | port/include/lwipopts.h 定义了带报文的版本，但仅在 `CONFIG_LWIP_CHECK_THREAD_SAFETY=y` 时生效，**该项 Kconfig 默认 n**                                                           |
| core locking       | 可选机制：`LOCK_TCPIP_CORE()` 是真互斥量，允许别的任务拿锁直调内核        | Kconfig 存在但默认 n，普通项目仍是纯邮箱模型                                                                                                                                     |
| 示例应用           | contrib/apps/{tcpecho_raw,udpecho_raw,netio,httpd,lwiperf}，全是 raw 教材 | 源码树随带但 IDF 默认不启用这些 app 的编译宏                                                                                                                                     |
| "谁在生产上用 raw" | httpd/netio 的性能叙事                                                    | **栈自家住户**：dhcpserver、dns.c、sntp、mdns（`CONFIG_LWIP_DNS_SUPPORT_MDNS_QUERIES` 时）；外部组件 esp_http_client/esp_http_server/esp-tls **无一使用 raw**，清一色 BSD socket |
| 危险默认           | 无防护也能跑，出事靠自己                                                  | 同左；多了随时可开的防呆闸门                                                                                                                                                     |

> [!note] 态度解读
> ESP-IDF 生态的事实标准是：应用层一律 socket（可移植性、多任务友好、VFS 统一封装），raw API 只属于"协议栈开发者"与极少数性能据点（例如要在 tcpip 线程里直接桥接两个 PCB 的代理场景）。所以 IDF 连示例都不推 raw——它防的是初学者用 socket 的心智模型写出 threaded 风格的 raw 代码。防呆闸门默认关闭也说得通：真正需要 raw 的人知道自己在干什么，而闸门本身每条内核路径都有一次线程身份查证的成本。

选型决策表（对照官方口径整理）：

| 场景                                      | 推荐                 | 理由                                                               |
| ----------------------------------------- | -------------------- | ------------------------------------------------------------------ |
| 高频小包转发/代理/隧道终结（CPU 是瓶颈）  | **raw**              | 省 2 次切换 + 拷贝/VFS 层，15.6 实测 RTT 2.7 倍差                  |
| 极端内存受限下的海量并发连接              | 视情况               | raw 每 PCB 不付 fd/netconn/recvmbox 成本，但状态机复杂度换人脑 RAM |
| 一般业务逻辑、HTTP/MQTT/TLS               | socket               | 多任务天然、生态组件齐全、可移植 POSIX                             |
| 需要与 ISR/高优先级任务强耦合的低抖动收发 | raw 或"raw+通知"混合 | 甚至可以只剩一台后端引擎跑在 tcpip 线程里，对外仍暴露 socket 门面  |

---

## 15.6 实验：同题竞技、返回值验尸、故障双注入

工程：`practice/lwip-ch15-raw-api-callbacks/`（基于 ch3 联网模板 + DHCP）。开机后三个服务同时就位：

```text
8017/tcp  raw   API echo（per-connection 状态机 + snd_buf 背压队列）
8517/tcp  socket API echo（独立任务 ch15_sock，对照组）
8027/udp  控制口（raw UDP）：pcbs/st=遍历 PCB 链表与统计快照；
          leak:on|off=EOF 是否"忘记 close"；busy:<ms>=recv 内 busy-wait 注入；
          xt=野 tcp_new 循环；xtw=野 tcp_write 直写在役 PCB
```

构建与启动（完整可复制；端口号遵守系列约定 8000+章号=8017）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch15-raw-api-callbacks
idf.py set-target esp32 && idf.py build
idf.py qemu monitor < /dev/null || true        # 生成 qemu_flash.bin/qemu_efuse.bin

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 600 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8017-:8017,hostfwd=tcp::8517-:8517,\
hostfwd=udp::8027-:8027 \
  -nographic -no-reboot 2>&1 | tee logs/run_fast.log
# 等 run 出现 CH15-READY 再开始主机侧测试
```

主机侧统一用 `host/tcp_bench.py`（payload 含 magic+seq+填充，回显逐字节校验；`create_connection` 设超时、SO_RCVBUF 拉满以隔离主机排队因素）。

开机实拍（logs/run_fast.log 原文）：

```text
CH15-FACT sizeof(struct tcp_pcb)=208 MSS=1440 WND=5760 SND_BUF=5760 TCPIP_RECVMBOX=32 MAX_ACTIVE_TCP=16 SLOW_TMR=250 FAST_TMR=250 CHECK_THREAD_SAFETY=0 CORE_LOCKING=0
CH15-SERVER ctrl port=8027 started
CH15-SERVER api=raw port=8017 listening (runs in tcpip thread)
CH15-SERVER api=socket port=8517 fd=48 listening (task=ch15_sock)
CH15-READY raw=8017 sock=8517 ctrl_udp=8027 keepalive=600s
```

数一遍 FACT 行的门道：`sizeof(struct tcp_pcb)=208` 对比第十章 `udp_pcb` 的 80 字节，多出的 128B 是七态状态机、rcv/snd 记账与 unsent/unacked/ooseq 三队列的头寸；SND_BUF/WND 都是 4×MSS=5760，本章故意不动它们，好让 `ERR_MEM` 背压与窗口收缩真实可见。

### 实验 A：raw vs socket 同题基准（TCP 版分层税）

**方法学**。RTT：顺序 ping-pong，64B × 400/轮 × 3 轮，RTT 用主机 `time.monotonic_ns()`，交替覆盖两个端口摊平台漂移。吞吐：1200B × 1200 blocks、16 深度流水，echo 逐字节验证凑齐为止（可靠口径；对比第十章 UDP 突发口径恒掉尾巴 12 个的记录）。

**RTT 结果**（host/tcp_bench.py 输出原文，logs/exp_a_rtt_raw.log 与 exp_a_rtt_sock.log）：

```text
LAT label=raw_r1 port=8017 size=64 n=400 ok=400 avg_us=348.3 med_us=220 min_us=96 max_us=7907 p95_us=936
LAT label=raw_r2 port=8017 size=64 n=400 ok=400 avg_us=235.5 med_us=146 min_us=95 max_us=5026 p95_us=584
LAT label=raw_r3 port=8017 size=64 n=400 ok=400 avg_us=244.2 med_us=121 min_us=103 max_us=8607 p95_us=610
LAT label=socket_r1 port=8517 size=64 n=400 ok=400 avg_us=657.6 med_us=538 min_us=236 max_us=5104 p95_us=1346
LAT label=socket_r2 port=8517 size=64 n=400 ok=400 avg_us=394.8 med_us=359 min_us=274 max_us=5562 p95_us=573
LAT label=socket_r3 port=8517 size=64 n=400 ok=400 avg_us=448.0 med_us=419 min_us=266 max_us=5836 p95_us=629
```

| API    | 第 1 轮 median | 第 2 轮 median | 第 3 轮 median | 三轮均值   |
| ------ | -------------- | -------------- | -------------- | ---------- |
| raw    | 220            | 146            | 121            | **162 µs** |
| socket | 538            | 359            | 419            | **439 µs** |

**吞吐结果**（exp_a_tput_raw.log / exp_a_tput_sock.log 原文）：

```text
TPUT label=raw_r1 port=8017 size=1200 window=16 blocks=1200 echoed=1200 missing_tail=0 secs=0.136 mbit=84.86
TPUT label=raw_r2 port=8017 size=1200 window=16 blocks=1200 echoed=1200 missing_tail=0 secs=0.339 mbit=33.96
TPUT label=raw_r3 port=8017 size=1200 window=16 blocks=1200 echoed=1200 missing_tail=0 secs=0.136 mbit=84.40
TPUT label=socket_r1 port=8517 size=1200 window=16 blocks=1200 echoed=1200 missing_tail=0 secs=0.352 mbit=32.74
TPUT label=socket_r2 port=8517 size=1200 window=16 blocks=1200 echoed=1200 missing_tail=0 secs=0.294 mbit=39.20
TPUT label=socket_r3 port=8517 size=1200 window=16 blocks=1200 echoed=1200 missing_tail=0 secs=0.258 mbit=44.68
```

| API    | 第 1 轮 | 第 2 轮 | 第 3 轮 | 均值          | 尾部丢失 |
| ------ | ------- | ------- | ------- | ------------- | -------- |
| raw    | 84.9    | 34.0    | 84.4    | **67.7 Mbit** | 0        |
| socket | 32.7    | 39.2    | 44.7    | **38.9 Mbit** | 0        |

**解读四点**。

1. **TCP 侧的分层税与 ch10 的 UDP 结论同构**：中位 RTT raw/socket = 162/439 ≈ **2.7 倍**，与 UDP 的 103/288 ≈ 2.8 倍几乎一致——分层的价目表是结构性的，跟传输层协议无关。绝对值整体抬高的部分（raw 103→162µs）主要来自 TCP 每次回显都要走一轮 ACK 驱动的 `sent` 回调往返，这正是"可靠"的单价。
2. **回显校验口径下尾部零丢失**：同样 1200-block 突发，第十章 UDP 三家恒掉最后 12 个（SLIRP 缓冲伪影），本章 TCP 全部收齐——重传机器把仿真层的尾巴一口吞了。这也解释了为什么本实验不需要再做"补发版"：TCP 就是那个补发版。
3. **raw 吞吐的双峰**（84.9/84.4 与夹在中间的 34.0）：第二轮恰逢 socket 端口测试之间的调度扰动叠加，是环境噪声不是 API 差异。按"相对序比单点可信"的纪律记录三轮全貌；即便取保守下界，raw 的劣势轮也与 socket 的最好轮相当。
4. **别忘了天花板**：SLIRP 用户态转发的管道上限约 120 Mbit（第五/六章沉淀），raw 的高峰轮已贴近该上限——留给 socket 的问题从来不是"能不能更快的代码"，而是"要不要为别人的快买单"。

### 实验 B：返回值协议验尸（ERR_ABRT 正确姿势 vs 忘记 close）

**设计**。固件提供 leak:on/off 两档 EOF 策略。主机脚本 `eofcycle` 每轮：connect → 发 128B → `shutdown(SHUT_WR)` 制造 FIN → 等 EOF。leak:off 时 recv 收到 `p==NULL` 走"登出回调→释放 es→tcp_close"的标准拆除；leak:on 时故意记一笔 `leak_events++` 然后 `return ERR_OK` 了事。另用特殊 payload `ABRT` 触发"`tcp_abort()` + `return ERR_ABRT`"的正确终止路径。全程用控制口 `st`（内含 `dump_tcp_pcbs()`）遍历四条 PCB 链表取证。

**结果**（guest 侧日志原文）：

```text
── leak:off，3 轮 eofcycle ──
CH15-FIN lport=8017 rport=38802 close-path
CH15-CLOSE lport=8017 rx=128 tx=128 (graceful)
CH15-FIN lport=8017 rport=38804 close-path
CH15-CLOSE lport=8017 rx=128 tx=128 (graceful)
CH15-FIN lport=8017 rport=38806 close-path
CH15-CLOSE lport=8017 rx=128 tx=128 (graceful)
CH15-PCBSUM bound=0 listen=2 tw=0 sizeof(tcp_pcb)=208 leak_events=0 aborts=0 busy_ms=0 leak_eof=0
CH15-PCBDONE active=0

── leak:on，3 轮 eofcycle 后 dump ──
CH15-FIN lport=8017 rport=36220 leak-mode: 返回 ERR_OK 且不 close（教科书式泄漏：PCB 卡在 CLOSE_WAIT）
CH15-FIN lport=8017 rport=48724 leak-mode: ...（另两条同型，略）
CH15-PCBSUM bound=0 listen=2 tw=0 sizeof(struct tcp_pcb)=208 leak_events=3 aborts=0 ...
CH15-PCBACT idx=0 state=CLOSE_WAIT lport=8017 rport=55434 sndbuf=5760 rcv_wnd=5760 ann_wnd=5631
CH15-PCBACT idx=1 state=CLOSE_WAIT lport=8017 rport=48724 sndbuf=5760 rcv_wnd=5760 ann_wnd=5631
CH15-PCBACT idx=2 state=CLOSE_WAIT lport=8017 rport=36220 sndbuf=5760 rcv_wnd=5760 ann_wnd=5631
CH15-PCBDONE active=3

── ABRT 标记探测之后 ──
CH15-ABRTMARK lport=8017: 见 ABRT 标记 -> 先释放 pbuf 再 tcp_abort()+return ERR_ABRT
CH15-PCBSUM bound=0 listen=2 tw=0 ... leak_events=3 aborts=1 ...
CH15-PCBDONE active=3          ← 三具尸体还在，但没有新增第四具
```

**解读三点**。

1. **active=0 vs active=3 的对照即协议的价值**：三条 CLOSE_WAIT 尸体精确到远程端口号可指认，且各自白占 208B PCB + es + pbuf 相关账目。这不是理论威胁——只要有人复制粘贴了一份"懒得处理 EOF"的 echo，连接一多 `MEMP_NUM_TCP_PCB` 闸门（IDF 唯一保留计数闸的类型）就开始冷血拒新，`tcp_listen_input` 静默吞 SYN 的老故事（第五章）就要重演。
2. **ABRT 路径零残留**：abort 计数 +1 而 active 列表纹丝不动——"已终止者不再登记"。配合主机侧观察：`recv` 表现为 orderly EOF 或立即 reset（SLIRP 对 RST 的翻译有些微噪声，如实标注），但 guest 侧的链表才是权威证据。
3. **顺带的巧合知识**：dump 里 `listen=2`——第二个 listen pcb 不是我们的，而是 socket 版 echo 的 `listen()` 在 netconn 层生成的 listen PCB。三层 API 底下同一条河床，又一次得到实拍。

### 实验 C：故障注入·回调长处理（单线程排队的 TCP 实证）

**注入器**：`ctrl busy:<ms>` 让 recv 回调在处理每个到达分段前忙转指定毫秒（真实阻塞 tcpip 线程，不做任何宏模拟）。两组测量：

**C1 双连接 RTT 恶化**。主机起 A/B 两条常驻连接以 50ms 间隔 ping-pong；基线跑 6s，然后同样负载下在第 4s 注入 `busy:200`(持续 1.2s)、第 8s 注入 `busy:200`(持续 1.5s)。输出按秒聚合（节选自 logs/exp_c_baseline.log 与 exp_c_busy.log）：

```text
基线（每行格式：sec A(med,max,n) B(med,max,n)，单位 µs）
DRTT-SEC sec=3 A(med=534,max=929,n=20)    B(med=579,max=833,n=20)

注入窗口期（同一负载、同样两台"客户端"）：
DRTT-SEC sec=4 A(med=350595,max=400990,n=2) B(med=200811,max=350476,n=2)
DRTT-SEC sec=5 A(med=619, max=350571,n=13)  B(med=693, max=350527,n=13)
DRTT-SEC sec=8 A(med=535, max=200841,n=10)  B(med=519, max=400940,n=10)
DRTT-SEC sec=9 A(med=350349,max=350509,n=3) B(med=350369,max=350494,n=2)
DRTT-SEC sec=6 A(med=496, max=680, n=19) ← 第二窗口结束后的恢复
```

逐条原始记录更能说明问题（exp_c_busy.log 原文）：

```text
DRTT id=B idx=79 mono=313979.302 us=200811.7
DRTT id=A idx=79 mono=313979.503 us=400990.6
DRTT id=B idx=80 mono=313979.703 us=350476.9
DRTT id=A idx=80 mono=313979.903 us=350596.0
```

同时 guest 侧打印的两连接交替处理序列与通告窗口收缩（run_fast.log 原文）：

```text
CH15-BUSY enter 200ms rport=53262 len=64 rcv_wnd=5696 ann=5056
CH15-BUSY exit after 200029us rport=53262 rcv_wnd=5696 ann=5056
CH15-BUSY enter 200ms rport=53260 len=64 rcv_wnd=5696 ann=5056   ← 换另一条连接了
CH15-BUSY enter 200ms rport=53262 ... ann=4992                    ← 通告窗口 -64
CH15-BUSY enter 200ms rport=53262 ... ann=4928                    ← 继续收缩
```

**C2 吞吐窒息**。先测干净底噪：1200B 满速流稳定在 ~103 Mbit；然后挂着 `busy:200` 重灌同样流量：

```text
FLOODTP t=1.0s rx_bytes=11089440 rate_mbit=88.71      ← 干净基线（爬坡到 103 平台）
FLOODTP t=5.0s rx_bytes=64571040 rate_mbit=103.31
---
FLOODTP t=1.0s rx_bytes=7200 rate_mbit=0.06           ← busy:200 挂住后
FLOODTP t=8.0s rx_bytes=57600 rate_mbit=0.06          ← 7200B/s ÷ 1200B = 6 pkt/s
FLOODTP-DONE dur=8.0 rx=57600 errs=['timed out']
```

**解读三点**。

1. **RTT 塌缩在 200ms 的整数倍台阶上**：350ms/401ms/200ms——不是"变慢了一点"，而是**量化成注入时长的倍数**。因为两条连接的报文在同一条队伍里排队，排在后面那个的等待时间必然叠加在前者的处理时长上。A/B 的尖峰交替出现在同一秒（id=79 A 400µs 窗口隔壁就是 B 200ms），就是队首轮换的直接痕迹。
2. **反压链条肉眼可见地收紧**：ann=5056→4992→4928，每包 -64 恰是一个报文的窗口量——ACK 迟滞期间新报文持续抵港而旧账迟迟不平，通告窗口被一步步吃掉；放到真人应用上，下一步就是对端 persist 探询与 RTO 风暴（ch12 的机器全部会到场）。
3. **窒息比拖慢更致命**：0.06 Mbit ≈ 每 200ms 吐一个包，吞吐量剩基线的万分之六——窗口还没归零，链路已经事实上瘫痪。回调长处理的计费单位因此从来不是"这一次慢了多少"，而是"全部连接一起赔了多少"。对照第十章：UDP 慢消费者丢弃的是自己的datagram，TCP 慢消费者拖垮的是对端的发送曲线——合同义务总要对价。

### 实验 D：故障注入·跨线程误用（无声损坏 vs 当场击毙）

**默认构建**（`CHECK_THREAD_SAFETY=0`，守卫编译为空）。应用任务在 tcpip 线程外做两类违法操作，同时主机侧维持 A/B 双连接流量作完整性监控：

```text
CH15-XT BEGIN task=ch15_xt （非 tcpip 上下文直接调 tcp_new()）
CH15-XT n=2000 仍存活
...
CH15-XT END 存活 20000 次（CHECK_THREAD_SAFETY 未开时可能无感）

CH15-XTW BEGIN 对在役 PCB 0x3ffbbxxx 非法 tcp_write()
CH15-XTW i=100000 仍存活
CH15-XTW END 共 100000 次越权写入完成（后果未定义）
```

代价当然会有——主机侧完整性监控逮到一次流污染（exp_d_xtw.log 原文）：

```text
DRTT id=B idx=80 mono=314065.251 us=1178.1
DRTT id=A idx=80 mono=314065.251 us=1371.0
DRTT-CORRUPT id=B idx=81            ← B 连接的 echo 流出现了不属于协议的字节序
DRTT id=A idx=81 mono=314065.303 us=1550.8
```

野写的目标恰好是最近 accept 的那条连接——八万次乱序 tcp_write 里有一次把外部字节挤进了 B 的回显序列。系统没有崩，日志没有红色，但协议承诺被打破了：**未定义行为的常态是沉默**。

**守卫构建**（`SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.thrcheck"`，其中 `CONFIG_LWIP_CHECK_THREAD_SAFETY=y`）。这次守卫活着，而且比预想的更加六亲不认——它抓的不是我们派出去的野任务，而是 app_main 里惯例的初始化序列（logs/run_thrcheck3.log 原文，每次开机必现）：

```text
I (2963) esp_netif_handlers: eth ip: 10.0.2.15, mask: 255.255.255.0, gw: 10.0.2.2
assert failed: udp_new /IDF/components/lwip/lwip/src/core/udp.c:1239
               (Required to run in TCPIP context!)
Backtrace: 0x40086319:0x3ffb6ab0 0x400862e1:0x3ffb6ad0 0x400860b1:0x3ffb6af0 ...

ELF file SHA256: b6e011703...

Rebooting...
```

**解读三点**。

1. **两个世界的对比就是这道 Kconfig 的存在意义**：默认关闭是因为守卫在每条内核入口都插了一次"当前线程是不是 tcpip 本人"的身份核验；打开后连最无辜的"应用任务里建个监听 pcb"都会被当场枪毙——因为 `sys_thread_tcpip(LWIP_CORE_LOCK_QUERY_HOLDER)` 只认 `tcpip_thread()` 开头那句 `LWIP_MARK_TCPIP_THREAD()` 登记的名字（`api/tcpip.c`）。要注意我们全书几乎所有实验工程都在 app_main 里 happy 地 udp_new/tcp_new 过——它们只是活在守卫缺席的世界。
2. **沉默与尖叫之间**：默认世界里 UB 的表现谱系极宽——本次捕获的是流污染，上一分钟还是 N 万次全身而退；换个时序就可能是 `unsent` 断链、双重 free、在调试器里永远复现不出的现场。跨线程的规矩不是"小心一点"，是物理规律。
3. **守住正门就不会踩雷**：所有跨线程需求都能化成 `tcpip_callback(fn, ctx)` 的一次投递——一次 memp 分配 + 一次邮箱阻塞投递（见 15.4(b)），价格与第十章量过的邮箱税同级。第十四章的 sys_arch 移植视角里，这条通道正是 RTOS 世界接入协议栈的唯一合法渡口。

> [!warning] 附赠案例：一次 livelock 排障实录（诚实标注）
> 本章初版 raw echo 曾把顺序写成"先 `tcp_write` 回写、后 `tcp_recved` 归窗"。后果可复现得可怕：64B ping-pong 每次都恰在累计约两个接收窗口（~168 包）处整个 tcpip 线程楔死，openeth 驱动以 ~13k 帧/秒刷"no mem for receive buffer"，gdb 附着看到 CPU0 卡死在控制台锁释放路径，自由堆却纹丝不动（267104B 全程恒定）。改成官方范例（tcpecho_raw）的顺序——**进门先 `tcp_recved` 签收、再决定写什么**——并只在 `ERR_MEM` 时入队，同样的 1200 次 ping-pong 全绿。根因的 lwIP 内部机理未能完全定论（如实标注），但它给出的教训确定无疑：**回调里你对 pcb 的每一笔"债"（未经 recved 的数据、未输出的 ACK）都要在自己的调用内结清，别赌下一个回调来得足够快**。

---

## 15.7 小结

- raw API 之所以是原生 API：它是 tcpip_thread 里的**函数指针直调**，netconn/socket 只是往外邮寄事件的包装层。十层账本里它独享零切换零拷贝——TCP echo 实测 64B RTT 中位 **162µs vs 439µs（2.7 倍税）**、回显校验吞吐 **67.7 vs 38.9 Mbit（1.74 倍）**，与 ch10 UDP 侧 2.8 倍的结构性阶梯互相印证。
- 状态机的织法是官方钦点的三件套：`tcp_arg` 挂 per-connection 结构、accept 出生配齐五个钩子、sent/poll 双泵推进积压。**listen 之后原 pcb 作废**；EOF 走 `recv(pcb, NULL, ERR_OK)`；未注册 recv 时内核的 `tcp_recv_null` 代劳的正是你的义务清单。
- 返回值三档协议：ERR_OK 继续、非 OK 进 `refused_data` 待重投（背压正门）、**ERR_ABRT 的前提是你已在回调内亲自 `tcp_abort()`**（栈只是相信你）；accept 是唯一由栈兜底 abort 的特例；err 回调抵达时 pcb 已火化，只能自扫 es 门前雪。
- 三大陷阱全部有实测画像：(a) 阻塞回调=全栈停摆；(b) 跨线程裸调是 UB，守卫 `CONFIG_LWIP_CHECK_THREAD_SAFETY`（默认 n）打开后连 app_main 里惯常的 `udp_new()` 都会当场断言——正道唯有 `tcpip_callback`；(c) 回调长处理使 ann 窗口步步收缩（实测 5056→4928）、双连接 RTT 塌缩到 200/400ms 台阶、满速流从 103 Mbit 窒息至 0.06 Mbit——TCP 的背压是对端的发送曲线，违约必被追索。
- Vanilla vs IDF：闸门两种都留（守卫与 core locking 都是 opt-in），默认世界靠纪律；IDF 生产性用户全是栈自家（DHCP/DNS/SNTP/mDNS），应用组件清一色 socket，raw 在 ESP-IDF 生态里是"我们知道它最快，也知道谁配用它"的位置。

下一章给这三层世界收口：从 netconn 信箱、socket 的 VFS 伪装到 lwIP 如何把自己嵌进 ESP-IDF 的 POSIX 面——`/dev/socket` 背后那张 fd 映射表、`select` 如何同时值守 socket 与普通 fd，将在 [[ch16-socket-netconn-vfs|第十六章《socket / netconn / VFS》]] 展开。
