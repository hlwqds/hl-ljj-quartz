---
title: "lwIP 深度解析（十三）：tcpip_thread：单线程协议栈与邮箱模型"
date: 2026-08-26
description: "逐行走读 tcpip.c 主循环与 TCPIP_MSG 六类消息，拆解邮箱投递 API 家族的阻塞语义（callback/try_callback/inpkt/send_msg_wait_sem），实测 QEMU 下 tcpip 任务优先级/邮箱时延（空载 24µs 中位 vs 满载长尾 30ms+）、3 秒回调卡死导致的全栈停摆、以及 32 槽邮箱填满时阻塞投递 vs 失败即返两种语义，并给出 Vanilla 与 ESP-IDF lwIP 的移植层对照。"
tags: [lwip, network, esp32, esp-idf, qemu, tcpip-thread]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 13. **第十三章：tcpip_thread：单线程协议栈与邮箱模型**

# lwIP 深度解析（十三）：tcpip_thread：单线程协议栈与邮箱模型

这一章回答三个问题：**为什么 lwIP 核心必须单线程**（无锁的代价与收益到底怎么算）、**一条消息投进邮箱后的一生是什么样**（`tcpip_thread` 主循环逐行走读）、**整个系统的"心跳"由谁驱动**（定时器不是独立线程，而是主循环等待策略的一部分）。读完它，前面十二章里所有"这句话必须在 tcpip 线程上下文里才成立"的伏笔——[[2026-08-26-lwip-deep-dive-ch15-raw-api-callbacks|raw 回调]]、netconn 邮箱、定时器自续——都将在同一个 `while(1)` 里合流。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`components/lwip/lwip/src/api/tcpip.c`、`include/lwip/priv/tcpip_priv.h`）与 IDF 移植层 `components/lwip/port/freertos/sys_arch.c`。全部实验在 QEMU 真实跑通，数字都是实测。

---

## 13.1 为什么 lwIP 核心必须单线程

### 1. 一份没有锁的核心代码

翻开 `src/core/` 目录做一件事：数锁。你会找到临界区宏 `SYS_ARCH_DECL_PROTECT/PROTECT/UNPROTECT`（只在 pbuf/memp 的分配器内部短暂出现），但**没有任何一把保护协议状态数据结构的互斥量**：`pcb` 双向链表、TCP 状态机字段、ARP 缓存表、IP 分片重组队列——全部裸奔。这不是疏忽，是 lwIP 的立身之本。作者 Adam Dunkels 在设计时的判断是：嵌入式系统里 RAM 和 CPU 都太贵，与其让每条核心路径都背上"取锁-检查-释放"的税和一套死锁规避协议，不如规定**这些代码只允许一个执行流触碰**。

于是有了 `tcpip.c` 文件头那句自我介绍：

```c
/**
 * The main lwIP thread. This thread has exclusive access to lwIP core functions
 * (unless access to them is not locked). Other threads communicate with this
 * thread using message boxes.
 * It also starts all the timers to make sure they are running in the right
 * thread context.
 */
```

线程模型的一句话总纲：

```text
其它任何任务/ISR ──(tcpip_msg 消息)──► [tcpip_mbox] ──► tcpip_thread ──► 裸跑 lwIP 核心
      socket/netconn/raw/驱动收包/定时器注册                    唯一持有者
```

### 2. 收益与代价的一笔账

| 维度         | 多线程 + 细粒度锁                     | 单线程 + 邮箱（lwIP 选择）        |
| ------------ | ------------------------------------- | --------------------------------- |
| 代码形态     | 每个 ` pcb→next` 改写都要持锁、防重入 | 状态访问零锁样板，静态可读        |
| RAM          | 每把锁对象 + 锁竞争记录               | 一个 mbox ≈ 一条 FreeRTOS 队列    |
| 关键路径延迟 | 锁争用时调用方原地自旋/睡眠           | 生产者永不进核心区；排队等消费者  |
| 最坏情况     | 死锁、优先级反转要整套治理            | **队头阻塞**：一条慢消息卡住全栈  |
| 吞吐上限     | 受锁分段程度限制                      | 单核吞吐天花板 = tcpip 线程占空比 |

代价就是右下角那条：**排队不解决公平性**。哪个环节慢半拍，整台"机器"就停在哪条消息上——本章 13.7 的两个故障注入实验会把这一点打得非常具象。

---

## 13.2 一条消息的一生：主循环逐行走读

### 1. 信封本身：struct tcpip_msg

消息定义在 `tcpip_priv.h` 里，是典型的"类型标签 + union 载荷"信封：

```c
struct tcpip_msg {
  enum tcpip_msg_type type;      /* 判别标签 */
  union {
    struct { tcpip_callback_fn function; void* msg; } api_msg;     /* TCPIP_MSG_API */
    struct { tcpip_api_call_fn function; struct tcpip_api_call_data *arg;
             sys_sem_t *sem; } api_call;                           /* TCPIP_MSG_API_CALL */
    struct { tcpip_callback_fn function; void *ctx; sys_sem_t *sem; } cb_wait;
    struct { struct pbuf *p; struct netif *netif;
             netif_input_fn input_fn; } inp;                       /* TCPIP_MSG_INPKT */
    struct { tcpip_callback_fn function; void *ctx; } cb;          /* CALLBACK / CALLBACK_STATIC */
    struct { u32_t msecs; sys_timeout_handler h; void *arg; } tmo; /* TIMEOUT / UNTIMEOUT */
  } msg;
};
```

枚举里有八个值，但**编译结果取决于裁剪开关**。IDF 默认配置（`LWIP_TCPIP_CORE_LOCKING=0` 打开 API/API_CALL/CALLBACK_STATIC_WAIT 三类；`LWIP_TCPIP_CORE_LOCKING_INPUT=0` 打开 INPKT；`LWIP_TCPIP_TIMEOUT=0` 关掉 TIMEOUT/UNTIMEOUT 两类）实际编出六类：

| type                             | 谁投递                                                 | 处理动作（`tcpip_thread_handle_msg()` 内）                                 | 消息内存从哪来到哪去                      |
| -------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------- | ----------------------------------------- |
| `TCPIP_MSG_API`                  | netconn API 封装（`netconn_*` → `api_msg.c`）          | `msg->msg.api_msg.function(...)` 执行 netconn 动作                         | `MEMP_TCPIP_MSG_API`，处理完由发送方 free |
| `TCPIP_MSG_API_CALL`             | `tcpip_api_call()` 同步远程调用                        | 执行并把返回值写入 `arg->err`，`sys_sem_signal()` 叫醒等待者               | 同上                                      |
| `TCPIP_MSG_CALLBACK_STATIC_WAIT` | `tcpip_callback_wait()` 同步回调                       | 执行回调后 `sys_sem_signal()`                                              | **栈变量/静态消息体**，lwIP 从不释放它    |
| `TCPIP_MSG_INPKT`                | 驱动收包路径 `tcpip_input()/tcpip_inpkt()`             | `input_fn(p, netif)`（以太网帧走 `ethernet_input`），失败则 `pbuf_free(p)` | 专用池 `MEMP_TCPIP_MSG_INPKT`             |
| `TCPIP_MSG_CALLBACK`             | 应用 `tcpip_callback()` 异步投递                       | `cb.function(cb.ctx)` 后回收消息内存                                       | `MEMP_TCPIP_MSG_API`，处理完 `memp_free`  |
| `TCPIP_MSG_CALLBACK_STATIC`      | ISR 场景预分配消息（`tcpip_callbackmsg_trycallback*`） | 只执行，**永不 free**（消息体调用方复用）                                  | 调用方自有                                |

> [!note] 大纲之外的事实修正
> 很多资料把消息说成"四类"。以 2.2.0-dev 枚举为准：上限八类，IDF 实际编入六类；`TIMEOUT/UNTIMEOUT` 两类被 `LWIP_TCPIP_TIMEOUT=0` 裁掉——IDF 里跨线程注册定时器不用 `tcpip_timeout()`，要么在 tcpip 线程内直接 `sys_timeout()`，要么（如 esp_netif）通过 IPC 把"注册动作"整体搬进 tcpip 线程执行。

### 2. 主循环：整个协议栈只有这十几行

剥掉调试断言后的 `tcpip_thread()`（`src/api/tcpip.c`）骨架：

```c
static void tcpip_thread(void *arg)
{
  LWIP_MARK_TCPIP_THREAD();            /* 向 sys_arch 登记："我就是那个核心线程" */
  LOCK_TCPIP_CORE();
  if (tcpip_init_done != NULL)
    tcpip_init_done(tcpip_init_done_arg);   /* 通知创建者：邮箱已就绪 */

  while (1) {                          /* MAIN Loop */
    LWIP_TCPIP_THREAD_ALIVE();         /* 看门狗心跳标记 */
    TCPIP_MBOX_FETCH(&tcpip_mbox, (void **)&msg);   /* 取一条消息（见下） */
    if (msg == NULL) continue;         /* 断言路径 */
    tcpip_thread_handle_msg(msg);      /* 上表中的 switch */
  }
}
```

`LWIP_MARK_TCPIP_THREAD()` 是个值得停留的细节：IDF 移植层把它实现为 `sys_thread_tcpip(LWIP_CORE_MARK_TCPIP_TASK)`，即给当前线程打上"我是 tcpip 线程"的全局标记。此后 `esp_netif_lwip_ipc_call()` 里那道 `sys_thread_tcpip(LWIP_CORE_LOCK_QUERY_HOLDER)` 判断全靠它区分"我在栈内还是栈外"——13.3 节展开。

### 3. 取消息的三岔口：等待策略里藏着定时器

`TCPIP_MBOX_FETCH` 在开启 `LWIP_TIMERS` 时展开为 `tcpip_timeouts_mbox_fetch()`，逻辑是个三岔口：

```c
again:
  sleeptime = sys_timeouts_sleeptime();        /* 最近到期定时器还有多久 */
  if (sleeptime == SYS_TIMEOUTS_SLEEPTIME_INFINITE) {
    UNLOCK_TCPIP_CORE();
    sys_arch_mbox_fetch(mbox, msg, 0);         /* 无限睡：什么都没排期 */
    return;
  } else if (sleeptime == 0) {
    sys_check_timeouts();                      /* 已有到期项：先清账 */
    goto again;
  }
  UNLOCK_TCPIP_CORE();
  res = sys_arch_mbox_fetch(mbox, msg, sleeptime);  /* 带期限地睡到最近定时器点 */
  if (res == SYS_ARCH_TIMEOUT)
    goto again;                                /* 没等到消息但定时器到了：清账再循环 */
```

三个分支各有一层含义：

1. **邮箱空且无定时器**——无限期阻塞在 FreeRTOS 队列上，CPU 让给同优先级链上任何人；
2. **有定时器已到期**（`sys_timeouts_sleeptime()==0`）——先执行到期回调，立刻回环；
3. **有定时器未到期**——把"最多睡多久"钉在最近一个定时器的到期时刻上。消息先来就先处理消息；超时醒来则说明"该干活了"，执行 `sys_check_timeouts()`。

`sys_check_timeouts()`（`src/core/timeouts.c`）本体是一条 do-while：摘下所有到期项、`memp_free(MEMP_SYS_TIMEOUT)` 回收节点、逐个调用回调，直到没有欠账。**它是核心状态操作，所以只在 tcpip 线程上下文被调用**（函数入口的 `LWIP_ASSERT_CORE_LOCKED()` 在 `CONFIG_LWIP_CHECK_THREAD_SAFETY=y` 时强制校验这一点）。

这就回答了第三个问题：**lwIP 没有独立的"定时器线程"**。所谓心跳，是主循环的等待策略把"下一次定时器到期"折算成阻塞时限——定时器是 mailbox 消费者的业余工作，不是同事。

### 4. 心跳的内容物：内嵌定时器的自续调度

系统的周期性维护全在这张表里（`timeouts.c` 的 `lwip_cyclic_timers[]`，按配置条件编入）：

| 循环定时器        | 周期                                             | 干什么                                                                   |
| ----------------- | ------------------------------------------------ | ------------------------------------------------------------------------ |
| `tcp_tmr`         | `TCP_TMR_INTERVAL`（IDF Kconfig 默认改为 250ms） | 重传退避、延迟 ACK、保活、时间戳老化；`tcp_timer_needed()` 按需挂起/唤醒 |
| `etharp_tmr`      | `ARP_TMR_INTERVAL`（10s）                        | ARP 表项老化（第七章实证过 admin-down 才主动清理）                       |
| `dhcp_coarse_tmr` | 60s                                              | DHCP 租约续期调度                                                        |
| `dns_tmr` 等      | 各 1s~30s                                        | DNS 重试等（ESP_LWIP 标志可将若干此类改为"按需启停"）                    |

每个循环定时器的实现套路一致（`lwip_cyclic_timer()`）：干完活立刻 `sys_timeout_abs(next_time, lwip_cyclic_timer, arg)` 把自己重新挂回去——**回调自我续命**。这张表加上应用自己的 `sys_timeout` 条目，共同挂在唯一的一条按到期时间排序的单向链表 `next_timeout` 上，由 13.2.3 的等待策略统一驱动。一旦这条链的管家睡了不该睡的觉……13.7.3 的 3 秒实验会让你亲眼看到 ping 和 TCP 同时断气。

---

## 13.3 投递 API 全景：每种阻塞语义都有自己的领地

### 1. 六个入口一张表

| API                                        | 底层动作                                    | 邮箱满时                                                                                        | 可以在 ISR 用               | 典型调用者                                                    |
| ------------------------------------------ | ------------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------- |
| `tcpip_callback(fn, ctx)`                  | `memp_malloc` + `sys_mbox_post`             | **调用任务永久阻塞**（post 用 `portMAX_DELAY`）                                                 | ✗ 明确禁止                  | 应用任务想把一段代码挪进 tcpip 上下文                         |
| `tcpip_try_callback(fn, ctx)`              | 同上，但 `sys_mbox_trypost`                 | **立即返回 `ERR_MEM`**，不碰队列                                                                | ✓（信号安全取决于 arch 层） | 高频事件投递，丢了能容忍的场景                                |
| `tcpip_inpkt(p, inp, input_fn)`            | `MEMP_TCPIP_MSG_INPKT` + trypost            | **丢包**：free 消息体并返回 `ERR_MEM`，此时 pbuf 未被动过、所有权回到驱动；报文已不在输入路径上 | ✗ 一般在驱动 RX 任务        | 以太网驱动 → 协议栈的正式入口                                 |
| `tcpip_send_msg_wait_sem(fn, apimsg, sem)` | post API 消息后 `sys_arch_sem_wait(sem, 0)` | post 半段永久阻塞，然后无限等 sem                                                               | ✗                           | **netconn/socket 全家**（这是它们的底座）；esp_netif 控制路径 |
| `tcpip_api_call(fn, call)`                 | 同步带返回值的批量参数版                    | 同上                                                                                            | ✗                           | 结构化远程调用（如 IDF 内部组件）                             |
| `tcpip_callback_wait(fn, ctx)`             | CALLBACK_STATIC_WAIT + 每次新建/删除信号量  | 同上                                                                                            | ✗                           | 需要确认"已执行完"的一次性回调                                |

几个非对称性必须咬清楚：

- `tcpip_callback()` 注释原文 _"Blocks until the request is posted... Must not be called from interrupt context!"_——它在 memp 分配（IDF 全堆化后是 libc `malloc`）+ 永久阻塞 post 两处都不允许中断语境。
- `tcpip_try_callback()` 与 `tcpip_inpkt()` 都是 fail-fast，但失手的**后果不同**：前者只是你的通知没送出去（调用方收到 `ERR_MEM` 可以重试），后者意味着**一个真实的网络报文被丢弃**——邮箱深度因此成为输入路径的第一道缓冲闸门，本章实验 D 会量化它的闸门行为。
- 同步三兄弟（send_msg_wait_sem/api_call/callback_wait）的共同结构是"投递 + 在自家信号量上睡觉"，所以它们的最坏等待 = **排队时间 + 目标函数执行时间**，目标函数里若又有 sleep 或阻塞调用，等待方一起遭殃——这正是"同步穿越了异步边界"的本义。

### 2. esp_netif 控制路径：现成的 send_msg_wait_sem 用户

IDF 的 `esp_netif_dhcpc_start/stop`、`esp_netif_set_up/down` 这些控制面接口全都以 `_RUN_IN_LWIP_TASK` 宏封装（`components/esp_netif/lwip/esp_netif_lwip.c`）。以 DHCP 控制为例，最终收敛到这段真实源码：

```c
static inline esp_err_t esp_netif_lwip_ipc_call_msg(esp_netif_api_msg_t *msg)
{
    if (!sys_thread_tcpip(LWIP_CORE_LOCK_QUERY_HOLDER)) {
        /* 栈外任务：把工作包装成回调，经 tcpip_send_msg_wait_sem 进 tcpip 线程 */
#if LWIP_TCPIP_CORE_LOCKING
        tcpip_send_msg_wait_sem((tcpip_callback_fn)esp_netif_api_cb, msg, NULL);
#else
        sys_arch_sem_wait(&api_lock_sem, 0);       /* 序列化多个控制调用 */
        tcpip_send_msg_wait_sem((tcpip_callback_fn)esp_netif_api_cb,
                                msg, &api_sync_sem);
        sys_sem_signal(&api_lock_sem);
#endif
        return msg->ret;
    }
    return msg->api_fn(msg);   /* 已在 tcpip 线程内：直呼函数，避免自己等自己 */
}
```

三个看点：第一，`LWIP_TCPIP_CORE_LOCKING=n`（IDF 默认）时走的是消息路径，`api_sync_sem` 由 tcpip 线程内的 `esp_netif_api_cb()` 在执行完真正的 DHCP 函数后 signal——一次标准的同步跨界；第二，`api_lock_sem` 把并发到达的多个控制调用**串行化**，防止两条消息交错写 `msg->ret`；第三，也是最容易被忽略的：如果调用者**已经在 tcpip 线程里**（比如你在 raw 回调里调 `esp_netif_dhcpc_stop()`），本函数直呼本地分支——否则 `tcpip_send_msg_wait_sem` 投出去的消息永远轮不到自己消费（自己正睡着等信号量），**系统就此死锁**。这个判断就是 13.5 规则清单第 3 条的官方实现。

> [!tip] Batch 1 结论呼应
> 第一章实验里踩过的坑"socket/netconn 创建必须在 `esp_netif_init()` 之后，否则 assert 崩溃复位"，本质就是：`esp_netif_init()` 内部执行 `tcpip_init()` 创建 tcpip_mbox 与 tcpip 任务；没有这一步，第一条 `TCPIP_MSG_API` 连信箱都找不到。现在你能在源码里给那次崩溃画出行号级因果链了。

### 3. 邮箱生态的两端：一次 socket send 与它的回信

把 `TCPIP_MBOX` 放大看：单线程模型下应用与栈之间不止一条队列，而是一对方向相反的邮路。以 socket 发送为例（第十六章逐行走读，这里只立骨架）：

```text
app 任务                                tcpip 线程
────────                              ──────────
send(fd,buf,len)
  └─ lwip_send → netconn_write族       TCPIP_MSG_API 出队
      api_msg 填参 + 本线程信号量   ◄── do_send(...)  ←  tcp_write/output 在此同步完成
      sys_arch_sem_wait(sem) ──────────►  执行完 sys_sem_signal(sem) 叫醒等待者
                                          │
（反向）收到对端报文时：                 │  tcp_input → tcp_recv 回调
    recv(fd) 从 conn->recvmbox 取货 ◄────┘  recv_tcp: netconn trypost 进 recvmbox
                                            （CONFIG_LWIP_TCP_RECVMBOX_SIZE=6，满则静默丢——Batch 3 已实证）
```

于是整张图的拓扑是三排邮箱：`tcpip_mbox`（全局唯一，进核心）+ 每连接一套 `recvmbox/acceptmbox`（出核心，netconn 所有）。**tcpip 线程同时是前者的唯一消费者和后者的唯一生产者**——它与全系统所有任务的联络都靠 FreeRTOS 队列的一投一收。这也是为什么[[2026-08-26-freertos-deep-dive-ch10-queue-universal-ipc|《FreeRTOS 深度解析》第十章]]说队列是万能 IPC 之后，lwIP 是它最苛刻的工业级用户：一个协议栈的全部并发正确性，押在几条深度只有 6~32 的队列上。

---

## 13.4 与 RTOS 的对接细节：IDF 移植层实测账目

### 1. 邮箱就是一条 FreeRTOS 队列

`port/freertos/sys_arch.c` 里没有任何神秘成分：

```c
sys_mbox_new(mbox, size)     → xQueueCreate(size, sizeof(void *))
sys_mbox_post(mbox, msg)     → xQueueSendToBack(q, &msg, portMAX_DELAY)   /* 满 = 阻塞到底 */
sys_mbox_trypost(mbox, msg)  → xQueueSend(q, &msg, 0)                     /* 满 = errQUEUE_FULL */
sys_mbox_trypost_fromisr(...)→ xQueueSendFromISR(q, &msg, &hpw)           /* ISR 版 trypost */
sys_arch_mbox_fetch(...)     → xQueueReceive(q, &msg, timeout) 包一层 SYS_ARCH_TIMEOUT 记账
```

一封"信"就是一个 8 字节指针，队列深度就是邮箱容量。**第九章讲过的"消息不是并发，是排队"在这里一字不改地成立。**

### 2. 三件套的实测值

| 参数     | 宏/Kconfig                                                                  | 本环境实测/默认值                                |
| -------- | --------------------------------------------------------------------------- | ------------------------------------------------ |
| 任务名   | `TCPIP_THREAD_NAME`（`port/include/lwipopts.h:859`）                        | `"tcpip"`（`uxTaskGetSystemState` 输出原样可见） |
| 优先级   | `CONFIG_LWIP_TCPIP_TASK_PRIO`（范围 1~24）                                  | **18**（默认 18；下方日志原文）                  |
| 栈大小   | `CONFIG_LWIP_TCPIP_TASK_STACK_SIZE`(3072) + `TASK_EXTRA_STACK_SIZE`(512)    | 3584B 配置；实测高水位从未低于 ~2296B            |
| 邮箱深度 | `CONFIG_LWIP_TCPIP_RECVMBOX_SIZE`（范围 6~64/1024，需 WND_SCALE 才能超 64） | **32**                                           |
| CPU 亲和 | `CONFIG_LWIP_TCPIP_TASK_AFFINITY`（默认 NO_AFFINITY）                       | 不绑核，可在两核间漂移                           |
| 核心锁   | `CONFIG_LWIP_TCPIP_CORE_LOCKING`（Kconfig 默认 n）                          | n：消息模式                                      |

启动后的任务清单（实验 A 现场，`uxTaskGetSystemState` 输出节选）：

```text
[tasks]   main             prio= 1 hwm= 2884
[tasks]   tcpip            prio=18 hwm= 2328     ← 主角
[tasks]   emac_rx          prio=15 hwm= 3336     ← openeth 驱动收包任务（生产 INPKT 的一方）
[tasks]   echo_srv         prio= 5 hwm= 2564     ← 应用自建 socket 服务任务
```

tcpip 任务比驱动收包任务优先级高 3 档——对单线程消费者来说这是个刻意的设计倾向：宁可生产端堆积，也要尽快清空消费者面前的队列，为后续报文腾槽位。

### 3. 锁模式 vs 邮箱模式的取舍

上游 opt.h 里 `LWIP_TCPIP_CORE_LOCKING` 的默认值其实是 1，IDF 却显式配成 0（`port/include/lwipopts.h` 的 `#else` 分支：`#define LWIP_TCPIP_CORE_LOCKING 0`）。两种模式的正面对决：

| 维度                   | 锁模式（locking=1）                                 | 邮箱模式（IDF 默认 locking=0）              |
| ---------------------- | --------------------------------------------------- | ------------------------------------------- |
| 栈外任务进入核心的方式 | 直接 `LOCK_TCPIP_CORE()` 抢全局互斥量后裸调核心 API | 全部打成消息排队等 tcpip 线程消费           |
| 定时器触发             | 主循环可解锁期间被抢占执行                          | 只在 fetch 循环内结算                       |
| 输入路径               | 可选 `CORE_LOCKING_INPUT=1` 直接抢锁入栈            | 必须经 INPKT 消息排队                       |
| 最坏侵入               | 锁持有者一句话不还，全员等锁                        | 队头一条长消息卡全栈（本意相同，位置不同）  |
| 上下文切换开销         | 抢锁失败时任务级切换                                | **每条消息都注定两次**（投递唤醒/消费归还） |

IDF 选邮箱模式的理由藏在工程权衡里：锁模式下任何第三方组件都能合法持有全局锁，review 成本陡增；邮箱模式则让"谁会碰核心状态"在架构上一目了然——只有一个线程，顺序看得见。顺带的代价正是 13.7 要测的东西：跨界成本成为常态。

---

## 13.5 单线程模型的后果清单

以上一切机制落回工程实践，凝成四条纪律：

1. **回调里不能调任何阻塞的 socket/netconn API。** 你的回调在 tcpip 线程内执行；而 `send()` 这类调用要把 `TCPIP_MSG_API` 投进同一个邮箱再睡信号量——信只能由 tcpip 线程自己送，此时它却在替你跑回调。**结论：瞬间死锁**，连超时都救不了你（信号量的等待是无限的）。这不是理论推演，是把 13.3 的表读两遍就能得到的必然。
2. **回调里的长处理会饿死一切。** 网络包解析、定时器、别人的 socket 调用，全部排在你的消息后面。echo 服务里一个 50ms 的业务处理 × N 个并发连接，ping 的 ICMP 回复就要在第 N×50ms 之后才出门。想在里面干重活？标准答案是投递回自己的工作队列，让 tcpip 线程只当邮差。
3. **在同一线程上下文里不得"同步等自己"。** raw 回调内禁止调用 `esp_netif_*` 等 IPC 包装？不必禁——esp_netif 已经替你想好了 `sys_thread_tcpip(QUERY)` 直呼分支（13.3.2）。但自己写的代码没有这道保险，写之前问一句：我现在是不是就是那只信箱的主人？
4. **一切"异步"的本质是排队，不是并行。** `tcpip_callback()` 返回 OK 只代表"信塞进了邮筒"；回调何时执行取决于队列里有多少前面的邮件、每封多少耗时。空载 24µs 的往返可以因负载膨胀到几十毫秒（下一节数字），这中间没有任何魔法缓冲，只有同一条队列。

---

## 13.6 Vanilla lwIP 与 ESP-IDF lwIP 对照

| 维度                           | Vanilla lwIP（NO_SYS=0 标准形态）                                           | ESP-IDF lwIP（v6.0.2 实测）                                                                                                                                                                                      |
| ------------------------------ | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 编译形态                       | 用户从 `contrib/ports/<arch>/` 自选移植层，自行提供 sys_arch                | IDF 打包成组件：`components/lwip/lwip/src` + `components/lwip/port/{freertos,esp32xx}/`，Kconfig 生成 lwipopts                                                                                                   |
| `LWIP_TCPIP_CORE_LOCKING` 默认 | opt.h 默认 **1**（上游推荐锁模式）                                          | Kconfig 默认 **n**，锁定 IPC 走消息路径                                                                                                                                                                          |
| 邮箱容量来源                   | `TCPIP_MBOX_SIZE` 手工给定                                                  | `CONFIG_LWIP_TCPIP_RECVMBOX_SIZE`（menuconfig，默认 32）                                                                                                                                                         |
| 消息内存                       | memp 静态池（`MEMP_NUM_TCPIP_MSG_API/INPKT`，opt.h 默认各 8，满了 err_mem） | IDF 全堆化（Batch 1 已验证 `MEM_LIBC_MALLOC=1 && MEMP_MEM_MALLOC=1`），消息分配走 libc 堆且计数闸门只覆盖 MEMP_TCP_PCB —— 容量的唯一硬约束变成邮箱槽位数 32                                                      |
| tcpip 任务参数                 | `TCPIP_THREAD_NAME/STACKSIZE/PRIO` 三宏手改                                 | Kconfig 化：`LWIP_TCPIP_TASK_PRIO`(1~24)、`TASK_STACK_SIZE`(+512 extra)、`TASK_AFFINITY` 三态选择                                                                                                                |
| 定时器裁剪                     | 全部循环定时器无条件常驻                                                    | `ESP_LWIP_DHCP_FINE_TIMERS_ONDEMAND`、`ESP_LWIP_DNS_TIMERS_ONDEMAND`、`ESP_LWIP_IP4_REASSEMBLY_TIMERS_ONDEMAND` 等标志改为按需启停（timeouts.c 现场可 grep）；另有 `TCP_TMR_INTERVAL` 改 250ms（Batch 3 已验证） |
| esp_netif 集成                 | 无此概念                                                                    | 控制面 API 全部 `_RUN_IN_LWIP_TASK` IPC 强制进 tcpip 线程（13.3.2），并用 `sys_thread_tcpip()` 标记/查询当前上下文                                                                                               |
| VFS socket                     | 需要用户接 syscall                                                          | `port/esp32xx/vfs_lwip.c` 自动挂钩（第十六章主场）                                                                                                                                                               |

值得强调的是：IDF **保留了**上游 tcpip.c 的主体结构不动（本章全部逐行引用的就是捆绑的 2.2.0-dev 原文件，无一处 ESP_LWIP 补丁——grep 可证），改造集中在**外围的选项注入与移植层**。这是一个健康 vendor fork 的典型形状。

---

## 13.7 实验：QEMU 上给单线程心脏做全套体检

实验工程 `practice/lwip-ch13-tcpip-thread-mailbox/`（基于 ch3 openeth 模板，hostfwd `tcp::8015-:8888`），main 里依次执行 A（上下文证明）/ B（时延测量）/ C（卡死注入）/ D（邮箱满注入）四组。

构建与运行的标准流程（v6.0.2，已验证）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch13-tcpip-thread-mailbox
idf.py set-target esp32          # 仅首次；改 sdkconfig.defaults 后须删 sdkconfig 重建
idf.py build
idf.py qemu monitor < /dev/null || true     # 仅用于生成 qemu_flash.bin/qemu_efuse.bin
./run_exp.sh                     # 后台起 QEMU，自动打探针，结束后精确 kill
```

其中 `run_exp.sh` 的 QEMU 行是：

```bash
timeout 90 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8015-:8888 \
  -nographic -no-reboot > run.log 2>&1 &
```

> [!warning] 一个新发现的 QEMU 启动坑
> CONVENTIONS 第 3 节的模板里还有一条 `-global driver=nvram.esp32.efuse,property=drive,value=efuse`。在本机这版 QEMU（esp_develop_9.2.2_20250817）上，带着这条参数启动会出现：
>
> ```text
> qemu-system-xtensa: warning: requested NIC (anonymous, model openeth) was not created (not supported by this machine?)
> ```
>
> NIC 未创建，openeth 寄存器窗口无设备响应，guest 在 `esp_eth_mac_new_openeth()` 初始化 DMA 描述符时直接 `LoadStorePIFAddrError` 复位（backtrace 已用 addr2line 解码核实）。**去掉该 `-global` 行即可正常 bring-up**；回写 CONVENTIONS 待办。

### 实验 A：执行上下文证明——"我的代码到底跑在哪个任务里"

目的：验证 13.1 的线程模型——不管入口是 raw API、`tcpip_callback` 还是定时器，出口都在同一个任务。方法：在各执行路径里打印 `pcTaskGetName(NULL)/uxTaskPriorityGet(NULL)/xPortGetCoreID()`；其中 raw UDP 回调由 loopback 自发自收触发（发在普通任务、收必须进 tcpip），socket accept 则作为对照组预期看到**非** tcpip 任务。关键代码（完整见 `main/lab_main.c` 的 `probe_ctx()` 及四个触发点）：

```c
static void probe_ctx(const char *label)
{
    ESP_LOGI(TAG, "[ctx] %-24s task='%s' prio=%u core=%ld",
             label, pcTaskGetName(NULL),
             (unsigned)uxTaskPriorityGet(NULL), (long)xPortGetCoreID());
}
/* 触发点① app_main 直呼 ② tcpip_callback(probe) ③ sys_timeout(700ms, probe)
 * ④ udp_new()+udp_recv() 的接收回调（socket 发 loopback 报文触发）
 * 对照组⑤ socket echo server 的 accept() 返回点 */
```

run.log 真实输出摘录：

```text
I (3091) ch13lab: [ctx] app_main (direct)        task='main' prio=1 core=0
I (3091) ch13lab: [ctx] via tcpip_callback       task='tcpip' prio=18 core=0
I (3791) ch13lab: [ctx] sys_timeout cb           task='tcpip' prio=18 core=0
I (4191) ch13lab: [ctx] udp_raw recv cb          task='tcpip' prio=18 core=0
I (29511) ch13lab: [ctx] socket accept           task='echo_srv' prio=5 core=0   ← 对照组
```

解读：前四路殊途同归，全部落在 `task='tcpip' prio=18`——包括"发送时明明在别的任务"的 loopback raw 回调和独立于邮箱之外的 sys_timeout 回调。唯一的例外是对照组：socket API 是薄壳，accept 就发生在调用者自己的任务里。这就是"线程安全的 API 全靠搬家"的直观证据。

### 实验 B：邮箱时延测量——空载与满载各 1000 次

目的：量化 13.5 第 4 条"异步即排队"的价格。方法（真实测量声明）：两种口径各测 1000 次，`esp_timer_get_time()` 打点，排序取分位——

- **sync RTT**：`tcpip_callback_wait(noop)`，含每次调用建/删一对信号量的固定开销，反映"确认送达并执行完"的全额成本；
- **async one-way**：`tcpip_callback(stamp_cb, &stamp)`，回调在**被执行瞬间**自行盖时间戳，测量方拿 `stamp - t0`，不含等待唤醒的成本，更接近纯投递延迟。

满载通过常驻 hammer 任务无节流地补投 noop 回调实现（本次运行累计投递 909,628 条，tcpip 线程全程跑满）。输出原文：

```text
[bench] idle sync RTT(wait)    n=1000 min=19 med=25  p95=31    p99=80    max=473   avg=27.9 us
[bench] idle async 1-way       n=1000 min=18 med=20  p95=23    p99=26    max=68    avg=20.8 us
[bench] loaded sync RTT(wait)  n=1000 min=22 med=1118 p95=29845 p99=59933 max=220142 avg=7241.3 us
[bench] loaded async 1-way     n=1000 min=17 med=810  p95=25086 p99=47215 max=80046 avg=5450.4 us
```

| 口径               | 中位   | P95    | P99    | max   |
| ------------------ | ------ | ------ | ------ | ----- |
| 空载 sync RTT      | 25µs   | 31µs   | 80µs   | 473µs |
| 空载 async one-way | 20µs   | 23µs   | 26µs   | 68µs  |
| 满载 sync RTT      | 1118µs | 29.8ms | 59.9ms | 220ms |
| 满载 async one-way | 810µs  | 25.1ms | 47.2ms | 80ms  |

解读三点：其一，空载数字就是"一次消息跨界"的真实单价——**~20µs 投递 + ~25µs 带确认**（QEMU TCG 数值偏大，真机通常低一半以上，相对结构不变）；其二，满载下中位与 P95 相差近 30 倍，P99 进入几十毫秒区间——长尾完全来自排在队伍前面的其他消息（hammer 用数百微秒级的补给节奏把 32 个槽位维持在常满状态），**分布式系统里"p99 比 avg 更诚实"的原则在这里换了个说法：p99 比 median 诚实**；其三，请记住满载 QEMU 消化速率 ≈ 90 万条/20 秒 ≈ 22µs/条，这正是 13.7.3 中 3 秒卡死后积压水位的换算基准。

### 实验 C：故障注入·单线程卡死——"心脏停跳"3 秒实录

目的：证明 13.2.4 的推断——回调睡觉 = 全栈停摆（含 ICMP/TCP/定时器）。方法：往邮箱里投一个 `vTaskDelay(3000ms)` 的回调；同时两侧观测——guest 侧 esp_ping 会话横贯窗口（250ms 间隔，事件回调也在 tcpip 线程触发），主机侧 python 每 300ms 经 hostfwd 8015 对 echo 服务建连+回显并计时。（注意 SLIRP 不支持指向 guest 的入向 ICMP，故主机侧 ping 不可用作观测量，ICMP 观测放在 guest 侧完成。）stall 回调全文就五行：

```c
static void stall_cb(void *arg)
{
    ESP_LOGI(TAG, "[C] stall BEGIN inside '%s' ...", pcTaskGetName(NULL));
    vTaskDelay(pdMS_TO_TICKS(STALL_MS));   /* 3000 ms：在协议栈的心脏里睡觉 */
    ESP_LOGI(TAG, "[C] stall END -- heart beating again");
}
```

run.log 时间线原文（Boot 后毫秒数保留原始值）：

```text
I (26474) ch13lab: [C-ping] reply seq=2 time=0 us        ← 卡死前：250ms 一跳，节奏正常
I (26924) ch13lab: [C] baseline done, about to post stall callback
I (26924) ch13lab: [C] stall BEGIN inside 'tcpip' (sleeping 3000 ms) -- whole stack frozen
I (26924) ch13lab: [C] post took 423 us (fire-and-forget)
（……整整 3000 毫秒，run.log 零输出：ping、TCP、定时器全体静默……）
I (29924) ch13lab: [C] stall END -- heart beating again
I (29924) ch13lab: [C-ping] reply seq=4 time=3 us        ← 积压冲账开始：seq4..10 同毫秒回收
I (29934) ch13lab: [C-ping] reply seq=15 time=0 us       ← 到 29934 止 seq4..15 共 12 发全部冲完
I (30224) ch13lab: [C-ping] reply seq=17 time=0 us       ← 此后恢复 250ms 正常节律
```

主机侧建连探针 `probe_tcp.log` 同屏对照：

```text
02:31:48 connect OK rtt=2.955s data=b'hello-ch13'   ← 恰好落在卡死窗内的连接
02:31:48 connect OK rtt=0.009s data=b'hello-ch13'   ← stall END 后的每一次
02:31:51 connect OK rtt=0.003s data=b'hello-ch13'
```

解读三条：第一，**停止的证据是"空白 + 孤立大样本"**——3 秒窗口内 run.log 一行都没有，主机侧 echo 建连 rtt 从常态的个位数毫秒暴涨为孤立的 2955ms；第二，**恢复的证据是"集中冲账"**——卡死期间 esp_ping 发出的请求被扣在 mbox 里排队，心跳恢复后 seq4..15 十二发回复在 10 毫秒内批量回收（29924→29934），这与 13.2.3 的"睡眠到最近定时器点"模型严丝合缝；第三，为什么 ping 会话本身**没有被超时判死**（没有出现 TIMEOUT 行）：esp_ping 的超时结算同样经由事件回调进入 tcpip 线程消费——心脏停跳期间，连"宣布死亡"这件事也被冻结了。

### 实验 D：故障注入·邮箱满——阻塞 vs 失败即返的终局对决

目的：实证 13.3 表格的两条语义边界（`tcpip_callback` 满时永久阻塞；`tcpip_try_callback` 满时返回 `ERR_MEM`）。方法：先投一个睡眠 1500ms 的 blocker 占住 tcpip 线程制造稳定水位，然后并发两路轰炸——flood 任务顺序调用 `tcpip_callback` 80 次（>32 槽位）并在每次前后计时；tryflood 任务以最快速度调用 `tcpip_try_callback`（上限 4000 次）。run.log 原文关键行：

```text
I (33024) ch13lab: [D] blocker running in 'tcpip', hogging tcpip thread 1500 ms
I (33104..33174) ch13lab: [D] flood[00..31] instant (15~59 us)      ← 前 32 发：填满全部 32 个槽位
I (33174) ch13lab: [D] try_callback while saturated:
                          OK=0 ERR_MEM(full)=4000                   ← try 路线 4000/4000 全灭
I (34524) ch13lab: [D] blocker done
W (34524) ch13lab: [D] flood[32] BLOCKED 1415539 us waiting for mbox slot
I (34524) ch13lab: [D] flood summary: instant=79 blocked=1 worst=1415539 us
I (35534) ch13lab: [D] backlog drained, system back to normal
```

解读四条：其一，**flood[00..31] 全部 instant、唯独第 33 发（下标 [32]）被吊了 1.42 秒**——与 `TCPIP_MBOX_SIZE=32` 严丝合缝地对应：FreeRTOS 队列深度就是邮箱容量，一条不多一条不少。其二，blocked 的时长精确等于"剩余卡死时间+排队"，且 block 结束的瞬间同一毫秒内连放十余条——这正是 `xQueueSendToBack(portMAX_DELAY)` 被消费者的取货逐个唤醒的现场（FreeRTOS 第十章的级联唤醒）。其三，try路线 4000 连败且全程零阻塞，两种语义的分野在实践中就是**"背压"与"丢弃"的取舍**：`tcpip_callback` 给调用者施压（哪怕代价是丢自己的实时性），`tcpip_try_callback` 给调用者决定权（代价是自己得处理失败分支）。其四，INPKT 走的也是 trypost——把这个实验平移到输入路径，flood 的角色换成网络洪峰，"邮箱满 = 真实报文被丢弃"就是第十九章拥塞与前传设计的起点。

> [!tip] 实验复现注意事项
> （1）改 `sdkconfig.defaults`（如 `CONFIG_FREERTOS_USE_TRACE_FACILITY=y`）后必须删 `sdkconfig` 再重新 set-target；（2）`idf.py monitor` 在本环境因无 TTY 失败属预期，镜像生成即可；（3）并行章节作者在场时，kill QEMU 必须按 `$!` 精确 kill 或按 hostfwd 特征定位进程，禁止 pkill。

---

## 13.8 小结

- lwIP 核心是**零互斥**的世界：全局协议状态只属于一个线程——`tcpip_thread`。其它任务/ISR 一律通过 `tcpip_mbox`（IDF 实现 = 深度 32 的 FreeRTOS 队列）投递指针尺寸的消息信封 `struct tcpip_msg`。
- 主循环只有"取消息-分发"两件事；`TCPIP_MBOX_FETCH` 把等待策略、定时器结算编织在一起：无定时器则无限睡，有到期定时器先 `sys_check_timeouts()`，否则睡到最近的到期点。**心跳不是独立线程，而是主循环的副产品**；`lwip_cyclic_timers[]` 的成员靠"回调自续 `sys_timeout`"保持周期。
- IDF 默认配置下实际编入六类消息（API/API_CALL/CALLBACK_STATIC_WAIT/INPKT/CALLBACK/CALLBACK_STATIC）；`TIMEOUT/UNTIMEOUT` 被 `LWIP_TCPIP_TIMEOUT=0` 裁掉。
- 投递 API 的本质区别在**阻塞语义**：`tcpip_callback`（满则永久阻塞，禁 ISR）/ `tcpip_try_callback`（满则 ERR_MEM 即返，ISR 可用）/ `tcpip_inpkt`（驱动入口，满即丢真包）/ `tcpip_send_msg_wait_sem`（同步穿越，netconn-socket 底座，esp_netif 控制路径同款）/ `tcpip_api_call`、`tcpip_callback_wait`（带确认版本）。
- IDF 的移植层账目：任务名 "tcpip"、优先级 **18**（Kconfig 1~24）、栈 3072+512B、亲和默认不绑核；`LWIP_TCPIP_CORE_LOCKING=n` 意味着一切跨界皆消息（上游 opt.h 默认反而是锁模式）；IDF 全堆化使消息内存不受 vanilla 的 8 格 memp 池约束，**邮箱槽位数成了容量的唯一硬约束**。IDF 对 tcpip.c 本体零改动，改造全部在外围（grep `ESP_LWIP` 于 tcpip.c 为零命中，实锤）。
- 后果清单：回调里调阻塞 socket API = 无救死锁；回调长处理饿死全栈；已在 tcpip 上下文时不得再同步等邮箱（esp_netif 用 `sys_thread_tcpip(QUERY)` 特判）；一切异步的本质是排队。
- 实测数字锚点：空载回调往返中位 25µs / 单向 20µs；满载 P95 到 30ms、max 220ms（90 万条/20s ≈ 22µs/条的消化速率）；3 秒回调卡死 → echo 建连 9ms→2955ms、ICMP 会话整整 3 秒零进展、恢复后 12 发回复同毫秒冲账；邮箱满时 `tcpip_callback` 精确在第 33 发阻塞 1.42s、`tcpip_try_callback` 4000 连败即时返。

真正的重心戏在幕后：这一切发生在 ESP-IDF 里时，"tcpip 线程"是谁创建的？`sys_arch_mbox_fetch` 的超时如何落到 FreeRTOS tick？`sys_now()` 用的是什么时钟？ESP_LWIP 补丁到底动了哪些文件？下一章把这些对接层的钉子一颗颗拔出来。见 [[2026-08-26-lwip-deep-dive-ch14-sys-arch-freertos-adapter|第十四章]]。
