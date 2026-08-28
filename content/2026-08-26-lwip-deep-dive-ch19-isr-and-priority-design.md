---
title: "lwIP 深度解析（十九）：中断与优先级：ISR、任务与协议栈分工"
date: 2026-08-26
description: "把一次 TCP echo 往返拆成中断、emac_rx、tcpip、应用四类执行流的接力赛：逐站给出上下文切换账单与每包 CPU 成本实测；深拆 lwIP 的 FromISR 通道（sys_mbox_trypost_fromisr/ERR_NEED_SCHED）与 vfs_lwip.c 的 sys_sem_signal_isr 真实消费场景；用双核 QEMU 实测优先级矩阵与高优自旋钉核的崩塌点（占空比 70%~85% 是分水岭），并验证'RX/应用优先级倒挂'在余量充足时为何不可见。"
tags: [lwip, network, esp32, esp-idf, freertos, priority, qemu]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 19. **第十九章：中断与优先级：ISR、任务与协议栈分工**

# lwIP 深度解析（十九）：中断与优先级：ISR、任务与协议栈分工

这一章回答三个问题：**网卡数据到达那一刻到应用拿到数据，中间经过几次上下文切换、每次发生在哪一核**（19.2 逐站记账）；**ISR / 驱动 RX 任务 / tcpip 任务 / 应用任务的优先级怎么排才不倒挂，倒挂了会发生什么、在什么条件下才发生**（19.4 原则 + 19.7 实验 B/C/D 用真实数字回答）；**`sys_sem_signal_isr` 这类 ISR 专用通道到底解决什么问题**（19.3 从 lwIP 上游一直挖到 `vfs_lwip.c` 的 select 打断路径）。读完它，你应该能对着任何一块 ESP32 网络应用的 ps 输出判断"谁挡住了谁"。源码参照：ESP-IDF v6.0.2（`~/esp/esp-idf`），捆绑 lwIP 2.2.0-dev。

---

## 19.1 一张实物表：这套系统里都住着谁

先建立角色表。这是本章实验工程（QEMU openeth + 双核 ESP32 镜像）启动后用 `uxTaskGetSystemState()` 抓的真实任务清单——也就是我们后面所有实验的"被测对象档案"：

```text
### TASKTABLE boot n=11
### T main           prio= 1 core=0  rt=9821     hwm=3012
### T IDLE1          prio= 0 core=1  rt=1113434  hwm=988
### T IDLE0          prio= 0 core=0  rt=1107904  hwm=1088
### T tcpip          prio=18 core=NA rt=12129    hwm=2344   ← 协议栈本体
### T esp_timer      prio=22 core=0  rt=46       hwm=3640
### T ipc1           prio=24 core=1  rt=44307    hwm=572
### T echo_srv       prio= 5 core=0  rt=2225     hwm=3052   ← 我们的应用
### T ctrl_srv       prio=22 core=1  rt=2870     hwm=2992
### T emac_rx        prio=15 core=NA rt=960      hwm=3332   ← 网卡驱动接收任务
### T sys_evt        prio=20 core=0  rt=667      hwm=1760
### T ipc0           prio=24 core=0  rt=43251    hwm=564
```

三点速读：

1. **tcpip（`CONFIG_LWIP_TCPIP_TASK_PRIO` 默认 18）压着 emac_rx（15）和一般应用任务**，但低于事件循环 sys_evt（20）、esp_timer（22）和 IPC 任务（24）。这组数值全部出自 `esp_system/include/esp_task.h` 的公式：`ESP_TASKD_EVENT_PRIO = MAX-5`、`ESP_TASK_TIMER_PRIO = MAX-3`、`ESP_TASK_TCPIP_PRIO = CONFIG_LWIP_TCPIP_TASK_PRIO`，而 `configMAX_PRIORITIES = 25`。
2. **core=NA 表示 tskNO_AFFINITY**：tcpip 和 emac_rx 都没有绑核，这就是 19.5 节"漂移"话题的主角。
3. 这张表里没有中断的名字。ISR 不占任务位子，但它每一次进出都是真实成本，且它是整条链路的起点——下一节开始记账。

把这张表翻译成睡眠图谱更有用——每个执行流睡在哪个内核对象上、由谁唤醒（对象都是前几章的老熟人）：

| 执行流      | 平时睡在哪                                                                            | 被谁唤醒                                | 唤醒后的第一件事                        |
| ----------- | ------------------------------------------------------------------------------------- | --------------------------------------- | --------------------------------------- | --------------------------------- |
| openeth ISR | ——（不睡眠）                                                                          | QEMU/SLIRP 写描述符触发 IRQ             | 读 INT_SOURCE、`vTaskNotifyGiveFromISR` |
| emac_rx(15) | `ulTaskNotifyTake`（任务通知，[[2026-08-26-freertos-deep-dive-ch13-task-notifications | FreeRTOS 第十三章]]的主角）             | ISR 的通知 give                         | 搬帧→组 pbuf→`tcpip_input()` 入箱 |
| tcpip(18)   | `sys_arch_mbox_fetch(tcpip_mbox)`                                                     | mbox trypost：RX 站入包、API 消息、回调 | 按消息类型派发到协议栈本体              |
| 应用任务    | `recv()` → netconn recvmbox / `send()` → API 信号量                                   | tcpip 处理完对应消息后 trypost          | 拷贝数据、继续业务                      |

看懂睡眠图，就看懂了 19.2 切换账单的全部转折点——**每次唤醒都是一个潜在的切换点，切换是否真的发生只取决于唤醒者与沉睡者的优先级账本**。

---

## 19.2 全链路上下文切换账单：从帧进入 QEMU 到 recv 返回

### 1. 逐站推演：一次上行的切换计数

以「主机发来一帧携带新 TCP 数据 → guest 里阻塞在 `recv()` 的应用任务被唤醒」为主线。[[2026-08-26-lwip-deep-dive-ch16-socket-netconn-vfs|第十六章]]给过一张单核视角的唤醒时刻表，这里扩展成**多核视角的切换账单**：

| 站点 | 执行流      | 发生什么                                                                                                                                                                                                                  | 任务上下文切换                                                                                                                                                                      |
| ---- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| t0   | 硬件中断    | SLIRP 写入 openeth 描述符环，触发 `ETS_ETH_MAC_INTR_SOURCE` 中断（在 `esp_intr_alloc` 分配的那个核上进入）                                                                                                                | 无切换，但有一次完整的 IRQ 进出（寄存器保存/恢复）                                                                                                                                  |
| t1   | ISR         | `emac_opencores_isr_handler()` 读 INT_SOURCE，只做一件事：`vTaskNotifyGiveFromISR(emac_rx)`，随后按 `pxHigherPriorityTaskWoken` 决定是否 `portYIELD_FROM_ISR()`（`components/esp_eth/src/openeth/esp_eth_mac_openeth.c`） | 切换①：被打断的任务 → emac_rx（同核且 emac_rx 更高时立即切；否则挂起延迟结算）                                                                                                      |
| t2   | emac_rx(15) | `ulTaskNotifyTake()` 醒来 → `malloc(1516)` → 组 pbuf → `stack_input()` → `esp_eth.c` 中转 → `netif->input` 即 `tcpip_input()` → `tcpip_inpkt()` 分配 `MEMP_TCPIP_MSG_INPKT` 消息并 `sys_mbox_trypost(&tcpip_mbox, msg)`   | 切换②：邮箱非空唤醒 tcpip(18)，**18 > 15，xQueueSend 内部当场抢占**——emac_rx 可能还没退出本次循环就被换下                                                                           |
| t3   | tcpip(18)   | `sys_arch_mbox_fetch` 取 MSG_INPKT → `ethernet_input → ip4_input → tcp_input` → 数据挂 rcv 队列 → `recv_tcp()` 向 netconn 的 recvmbox trypost 并触发 `event_callback()`                                                   | 切换③：recvmbox 里躺进数据唤醒 echo_hdl(5)，但 5 < 18 **不抢占**，tcpip 继续跑完消息循环、重新阻塞在邮箱上才让出 → 切换④：tcpip → （IDLE 或刚被换下的 emac_rx，取决于哪个还剩活干） |
| t4   | echo_hdl(5) | `sys_arch_mbox_fetch` 返回 pbuf → `pbuf_copy_partial` 拷到用户 buf → 应用拿到数据                                                                                                                                         | 至此 recv() 解除阻塞                                                                                                                                                                |

小口径统计：**这一次上行共 4 次任务级上下文切换 + 1 次 IRQ 往返**。加上回程（`send()` 经 apimsg 投 `do_send` 再阻塞自己、tcpip 执行 `tcp_write/tcp_output`、openeth TX 立刻写回 SLIRP，回包再走一遍 t0~t4）以及 ACK 混流，**一次最小 TCP echo 往返的量级是 ≥10 次任务上下文切换、≥2 次中断往返**。这是量级推导而非精确值——不同站位同时就绪时的先后顺序依运行时状态浮动，但「邮箱交接处的优先级差决定谁当场抢到 CPU」这个模式每次都在重演。

### 2. 实测上半场：回环路径每回合的 CPU 账单

理论站表配一个可复现的测量：实验工程里内置 `bench` 命令——两个应用任务钉在核 0/核 1，通过 `127.0.0.1` 走 lwIP 完整 socket 路径 ping-pong 200 回合（512 字节），测前后各抓一张任务表，diff 出每个任务的 run-time 计数器（`CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS=y` 时 `ulRunTimeCounter` 有效，时钟源 esp_timer 微秒）：

```text
$$$ LOOPMETRICS count=200 size=512 avg_rtt_us=631 min=464 max=2450
$$$ LOOPTASK lb_cli rt_delta=42929 us_per_round=214.65
$$$ LOOPTASK lb_srv rt_delta=45434 us_per_round=227.17
$$$ LOOPTASK tcpip  rt_delta=87091 us_per_round=435.45
$$$ LOOPTASK emac_rx rt_delta=0 us_per_round=0.00        ← 127.0.0.1 不过网卡（第七章的 ip4_route 特判）
```

两个读数方法值得咀嚼：

- **回环 RTT 平均 631 µs，而三个站点加起来 214.7+227.2+435.5 ≈ 877 µs > 631 µs**。不是账错了——lb_cli 在核 0、lb_srv 在核 1，两边的阻塞等待与计算并行铺开，双核对同一份账各记各的，交叉部分被时间墙吸收。
- **tcpip 一个中间商赚走全链路近一半的 CPU**：435 µs/回合 > 任何一个应用站。原因很直白：每个应用站只处理自己的收发，tcpip 却要串行消化双方的 API 消息与双向包——[[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|第十三章]]的单线程模型在这里换算成了可测量的单价。

### 3. 实测下半场：经过网卡的完整路径单价

把负载换成主机经 hostfwd 打进来的开环 paced 流量（128 字节 ×400 包，间隔 5 ms），同样 diff 任务表，得到**每一帧走完 NIC→tcpip→应用全程的真实单价**：

```text
emac_rx   Δrt = 54972 µs / 400 包 ≈ 137 µs/包      ← malloc+pbuf+mbox_post
tcpip     Δrt =119111 µs / 400 包 ≈ 298 µs/包      ← 三层协议解析+TCP 状态机
echo_srv  Δrt = 66407 µs / 400 包 ≈ 166 µs/包      ← recv/send 系统调用往返
（对照组 ctrl_srv 同窗 Δ≈3147 µs，纯噪声）
主机侧 RTT：p50=0.59ms  p90=1.02ms  p99=1.42ms  max=9.08ms
```

合计约 **601 µs CPU/包**，对照 p50 RTT 590 µs：又一次接近抵消——说明这套链路在轻载下的延迟基本由三站的纯计算构成，SLIRP 与调度引入的是尾部（max 9 ms vs p50 0.59 ms）。这张单价表还有个用途：它给出了协议栈每条连接的"转速上限"。想要 1 万包/秒的 echo 服务？光 tcpip 站就要吃掉约 3 个核——先算账再谈优化，这正是本章想传递的习惯。

---

## 19.3 ISR 规则深拆：lwIP 的 FromISR 通道

### 1. 上游给了哪些口子

FreeRTOS 侧的规矩在第 13 章已经立过（[[2026-08-26-freertos-deep-dive-ch13-task-notifications|FromISR 协议]]）：中断里只能调 `_FromISR` 后缀的 API，并把"要不要切换"的决定权交给调用者。lwIP 的 sys 层在内核对象之外提供了两个对口的窄通道：

```c
/* src/include/lwip/sys.h */
err_t sys_mbox_trypost_fromisr(sys_mbox_t *mbox, void *msg);   /* @note: To be used from ISR */

/* src/api/tcpip.c —— 上游唯一把它接进业务的入口 */
err_t tcpip_callbackmsg_trycallback_fromisr(struct tcpip_callback_msg *msg)
{
  return sys_mbox_trypost_fromisr(&tcpip_mbox, msg);
}
```

语义是精挑过的组合：**trypost（队满即失败，绝不阻塞）+ fromisr（临界区换成 ISR 安全形态）+ `ERR_NEED_SCHED` 握手**。最后一个是 IDF 私有补充，定义在 `port/freertos/include/arch/sys_arch.h`：

```c
/** This is returned by _fromisr() sys functions to tell the outermost function
 * that a higher priority task was woken and the scheduler needs to be invoked.
 */
#define ERR_NEED_SCHED 123
```

IDF port 的实现直译 FreeRTOS 协议（`components/lwip/port/freertos/sys_arch.c`）：

```c
err_t
sys_mbox_trypost_fromisr(sys_mbox_t *mbox, void *msg)
{
  BaseType_t ret;
  BaseType_t xHigherPriorityTaskWoken = pdFALSE;

  ret = xQueueSendFromISR((QueueHandle_t)&(*mbox)->os_mbox, &msg,
                          &xHigherPriorityTaskWoken);
  if (ret == pdTRUE) {
    if (xHigherPriorityTaskWoken == pdTRUE) {
      return ERR_NEED_SCHED;         /* 把 yield 决定权递出去，和 pxHigherPriorityTaskWoken 同构 */
    }
    return ERR_OK;
  } else { ... return ERR_MEM; }     /* 队满照常 ERR_MEM */
}

int
sys_sem_signal_isr(sys_sem_t *sem)
{
    BaseType_t woken = pdFALSE;
    xSemaphoreGiveFromISR(sem, &woken);
    return woken == pdTRUE;           /* 返回"是否叫醒了更高优先级任务" */
}
```

> [!note] 名字澄清
> 本章标题词组里的 "sys_arch_signal_isr" 在源码中并不存在；真实的端口层函数名是 `sys_sem_signal_isr`（FreeRTOS port 私有，上游 `sys.h` 只声明了 `sys_mbox_trypost_fromisr`），它的消费方在下一个小节登场。

### 2. vfs_lwip.c：ISR 信道的真实消费方

先立一张合法性矩阵——不同上下文里各自能用哪些 lwIP 信道（✓ 源码可见的真实用法，∅ 禁止）：

| API                                | 任务                                                  | tcpip 线程 | ISR                                                  |
| ---------------------------------- | ----------------------------------------------------- | ---------- | ---------------------------------------------------- |
| `sys_mbox_post` / `sys_sem_signal` | ✓                                                     | ✓          | ∅（阻塞式/无 ISR 保护）                              |
| `sys_mbox_trypost`                 | ✓                                                     | ✓          | 可用但退化（Vanilla 文档仅承诺 fromisr 版 ISR 安全） |
| `sys_mbox_trypost_fromisr`         | ✓                                                     | ✓          | ✓ → 返回 `ERR_NEED_SCHED` 要求外层补调度             |
| `sys_sem_signal_isr`（IDF 私有）   | 可用但无意义（GiveFromISR 从任务调即退化为普通 give） | ✓          | ✓ → 返回"是否叫醒高优"给 woken 指针                  |

它的存在理由，得从 VFS 的 select 机制留给每个驱动的钩子形状看起：

```c
/* vfs_lwip.c */
static void lwip_stop_socket_select(void *sem)
{
    sys_sem_signal(sem);                      /* 任务上下文版本 */
}

static void lwip_stop_socket_select_isr(void *sem, BaseType_t *woken)
{
    if (sys_sem_signal_isr(sem) && woken) {
        *woken = pdTRUE;                      /* ISR 版本：GiveFromISR + woken 回传 */
    }
}
```

这对函数作为 `.stop_socket_select / .stop_socket_select_isr` 注册进 lwIP 的 VFS 描述符（`esp_vfs_register_fd_range`）。分发链在 `components/vfs/vfs_calls.c`：

```text
任务上下文 close 该 fd                        ISR 上下文（如 UART 驱动中断）
  esp_vfs_close()                              esp_vfs_select_triggered_isr(sem,&woken)
      └→ stop_socket_select(sem)                  └→ stop_socket_select_isr(sem,&woken)
            └→ sys_sem_signal                         └→ sys_sem_signal_isr（GiveFromISR）
                ↓                                          ↓
        同一个 pthread TLS 信号量（select 等待者睡在上面）被点亮，
        阻塞中的 select()/poll() 得以带着结果或错误返回
```

所以这个"ISR 专用信道"解决的问题是：**当正在 `select()` 多个 fd 的任务沉睡在一个属于 lwIP 的 per-thread 信号量上时，任何上下文——包括另一个核的中断——都必须有办法礼貌地叫醒它**。任务侧直接 give 没问题；但从中断上下文给普通信号量 give 就是未定义行为，于是必须有一根从 ISR 语义直通 FreeRTOS GiveFromISR 的专线。语义粒度也严格对齐：`sys_sem_signal_isr` 返回的就是 FreeRTOS 的 `pxHigherPriorityTaskWoken`，vfs 层原样转发给更外层的 ISR 收尾代码——三层接力，责任链没有任何一环越权调度。

### 3. 网络相关的中断住在哪一层

Xtensa 的中断控制器把 ESP32 的外设中断组织成 Level 1~5 加 NMI 的层级（`esp_intr_alloc.h`：`ESP_INTR_FLAG_LEVEL1..LEVEL5/NMI`，注释明确 LEVEL4 以上属 HIGH 带需要汇编入口）；分配器 `get_available_int()` 对没显式指定 level 的申请有一行决定性逻辑：**"Level defaults to any low/med interrupt"**——回落到 `ESP_INTR_FLAG_LOWMED`（Level 1~3 的 C 可处理带）。

openeth 驱动的注册就是典型样本：`esp_intr_alloc(OPENETH_INTR_SOURCE, ESP_INTR_FLAG_IRAM, ...)` 只指定了 IRAM 没指定级别 ⇒ 落在 Level 1~3。对网络这类"每包都中断一次"的外设，低层级的意义正是让中断处理足够短（本例只有二十来行：读状态、通知任务、清标志），把长工作交给任务域——ISR 与 tcpip 站之间隔着的只是那根通知信道。WiFi 的 MAC 中断源同为 level 型（`interrupts.h` 注释 "level"），内部再由 WiFi 库自行分段处理，本章不展开。

---

## 19.4 优先级设计方法论：原则表与三种事故

### 1. 设计原则表

| 规则                                        | 理由                                                                                               | 反面案例                                                             |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| 协议栈在应用之上：tcpip(18) > 应用(默认≤10) | 保证「无论应用干什么」，已到达的数据都被及时消费、ACK 被及时发出；否则整个栈的吞吐被最慢的应用拖住 | 应用满速 spin 处理业务，tcpip 抢不到 CPU → 所有连接一起饿            |
| 驱动 RX 在 tcpip 之下但别太远：emac_rx(15)  | 入箱代价低（137µs/包，见 19.2），低于 tcpip 可被立刻抢占回栈内处理；但高于一般应用保证"帧先进系统" | emac_rx 低于高频应用：帧堆积描述符环（仅 4×1600B），ISR 报 BUSY 丢帧 |
| 比协议栈更高的应用必须有界且论证过          | 高于 tcpip 的应用每一微秒 CPU 都在挤压所有连接的处理预算                                           | 无界 busy-wait 的"高优业务"实际是全机网络故障                        |
| 测量/诊断探针必须压过全链路最高站           | Batch 4 实测陷阱：低优探针会被 NO_AFFINITY 高优自旋饿住，产出"系统没有阻塞"的假象                  | 探针 prio 5 混在一堆 prio 20+ 的任务群里看股票行情                   |
| 绑核是第二维优先级：粘性任务是确定性工具    | 关键路径钉核后延迟方差骤降；NO_AFFINITY 漂移带来 cache 弹跳                                        | 全系统 NO_AFFINITY，热点结构在两核 L1 间反复搬家                     |

### 2. 「RX > tcpip > 应用」为什么成立，什么时候要倒过来

经典排布的前提是**应用的处理不可预测而协议处理是有界的**。tcpip 站的单价有数据支撑（298µs/包），RX 站更短（137µs/包）——它们短平快，理应插队；应用事务可能一个 if 就返回也可能滚动几千次循环，让它睡在最低档，等得起。这排布真正想买的东西只有一样：**头部阻塞不上移**。应用再烂，烂在栈的下游，网络整体的脉搏还在。

什么时候要把某个应用抬到 tcpip 之上？

1. **该应用自身就是协议的一部分**：硬实时控制环从传感器读取到写网必须 <1ms 完成，且对延迟抖动比对吞吐敏感。抬上去的同时必须给它加上界的纪律（无阻塞调用、预算有限的循环），否则违反第一张表的第三行。
2. **多核分工下对称抬升是安全的**：关键应用钉核 1，tcpip/emac_rx 通过亲和配置留在核 0（见 19.5），物理上互不相碰——这是比调整优先级更强的隔离手段。
3. **它才是真正的紧急事件源**：例如安全停机逻辑需要在网络风暴时仍然每秒运行一次。

### 3. 三种典型的优先级事故

| #   | 形态                                           | 机理                                                                                                                                                                                                                                    | 出处/证据                                             |
| --- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------- |
| 一  | **RX 站被拖垮**：邮箱满 → 驱动层丢帧           | tcpip 站被长期占用（比如被上面的事故二冻结），`tcpip_inpkt()` 的 `sys_mbox_trypost(&tcpip_mbox)` 返回 ERR_MEM，pbuf 就地释放——帧进了系统却死在门口                                                                                      | 本系列第五章堆耗尽实验直接观察过驱动层丢帧刷屏        |
| 二  | **tcpip 被应用堵死**：单线程模型的阿喀琉斯之踵 | tcpip 只有一个人干活。raw/netconn 回调里忙等、或者持有 `lock_tcpip_core` 做慢操作，都会让全局邮箱排队——一条连接慢，全体跟着慢。系列实测：一个连接 recv 回调 busy-wait 200ms，第二条连接吞吐从 103 Mbit 跌到 0.06 Mbit                   | [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox | 第十三章]] 停摆实证 |
| 三  | **应用被"饿"是假的，测量被饿是真的**           | 双核 + NO_AFFINITY 环境：低优先级测量任务撞上高处自旋的 NO_AFFINITY 任务会完全得不到时间片，产出的"数值"其实是采样饥饿的产物。镜像教训：真被饿死的从来不是 timer 站（22 的 esp_timer 几乎不可能被应用饿），而是你以为在看系统的低优探针 | Batch 4 双核测量陷阱原文                              |

前两种是真实故障，第三种是"以为看见了故障"的测量学事故——后者更隐蔽，因为它给出的是自信的错数字。

---

## 19.5 多核分工：亲和性 Kconfig 与 NO_AFFINITY 的漂移税

### 1. 那个 Kconfig 到底叫什么、管到哪

grep 实际拼写（v6.0.2 `components/lwip/Kconfig`）：

```kconfig
choice LWIP_TCPIP_TASK_AFFINITY
    prompt "TCP/IP task affinity"
    default LWIP_TCPIP_TASK_AFFINITY_NO_AFFINITY
    ...
config LWIP_TCPIP_TASK_AFFINITY_NO_AFFINITY   /* 不绑核（默认） */
config LWIP_TCPIP_TASK_AFFINITY_CPU0          /* hex 默认 0x0 */
config LWIP_TCPIP_TASK_AFFINITY_CPU1          /* hex 默认 0x1 */

config LWIP_TCPIP_TASK_AFFINITY
    hex
    default FREERTOS_NO_AFFINITY if LWIP_TCPIP_TASK_AFFINITY_NO_AFFINITY
```

注意两个容易脑补错的细节。其一，名字是 `LWIP_TCPIP_TASK_AFFINITY`（没有单数的 AFFINITY**IES**，也不是 PINNED_TO_CORE），输出类型是 hex。其二，**作用范围比直觉广**：它不在 menuconfig 里各自可配，而是在 port 层一次性覆盖 lwIP 自己创建的所有线程——`sys_thread_new()` 的实现（`port/freertos/sys_arch.c`）把传参的 stack/prio 原样使用、affinity 却硬替换成这个 Kconfig：

```c
ret = xTaskCreatePinnedToCore(thread, name, stacksize, arg, prio, &rtos_task,
        CONFIG_LWIP_TCPIP_TASK_AFFINITY);
```

对比之下，eth 驱动的 emac_rx 有自己独立的两段式策略：`ETH_MAC_DEFAULT_CONFIG()` 给出 rx_task_prio=15/rx_task_stack_size=4096 的默认值供应用覆盖，亲和则由 `ETH_MAC_FLAG_PIN_TO_CORE` 标志单独控制（置位时钉在初始化线程当前核，否则 tskNO_AFFINITY）。**两条曲线互不知道对方的存在**——想让 tcpip 和 emac_rx 各就各位，要在 menuconfig 和 MAC 配置两个地方分别开口。还有个边角料：Kconfig 的 help 文本写着该选项"TCP/IP task and Ping task"都适用，但 v6 源码里 ping 应用实际用的是裸 `xTaskCreate(prio=2)`（`apps/ping/ping_sock.c`），亲和从未接到这条路上——文档与实现的滞后也算 Vanilla-vs-IDF 差异的一种利息。

### 2. 漂移的代价：cache 弹跳与测量陷阱

NO_AFFINITY 不是免费的随机数。跳一次核，上一跳攒热的包头结构、PCB、缓冲区在另一核的 cache 里全是冷的；对每包 600µs 量级的总预算来说，几次 miss 是零头，真正的风险在高频路径上的方差放大。而它最常见的"战绩"是搞砸测量：Batch 4 原话——**低优先级探针会被 NO_AFFINITY 高优先级自旋饿住造成"没有阻塞"假象，测量任务优先级要压过 tcpip(18)**；外加 **QEMU 吞吐受宿主机负载影响 ±50%，性能对比务必同时段开机配对测量**。本章实验 B/C/D 的所有对照组全部遵守这两条纪律（同实例内交错测、三轮取分布）。

内核侧的机制背景——为什么 NO_AFFINITY 任务会被随意搬运、跨核唤醒怎么打核间中断——归 [[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|FreeRTOS 第二十二章]] 与 [[2026-08-26-freertos-deep-dive-ch23-cross-core-synchronization|第二十三章]]。本章只需要它的工程投影：**漂移给了你两份算力，收走了单核确定性；预算紧张的关键路径应该显式钉核。**

---

## 19.6 Vanilla lwIP 与 ESP-IDF lwIP 对照：单核假设如何长出多核守卫

上游 lwIP 的世界观里只有一张嘴：一切核心操作要么发生在 tcpip 线程，要么由 `SYS_ARCH_PROTECT` 这种轻量关中断垫背。IDF 接手双核现实后改造集中在"边界守卫"，分五层看：

| 维度         | 上游 vanilla (2.2.0-dev)                                         | ESP-IDF v6 (port/esp32xx + freertos port)                                                |
| ------------ | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| 线程模型     | 单核假设成立，tcpip_thread 全局唯一即可安全                      | 同样保持唯一 tcpip 线程（IDF 对 tcpip.c 本体零改动），但其余任意任务都可能同时在跑       |
| core locking | `LWIP_TCPIP_CORE_LOCKING` 可选特性                               | Kconfig 化（`CONFIG_LWIP_TCPIP_CORE_LOCKING`），**默认 n**，仍走邮箱消息模型             |
| 误用检测     | 只有文档劝告 + contrib 示例里的 `LWIP_ASSERT_CORE_LOCKED` 空架子 | `CONFIG_LWIP_CHECK_THREAD_SAFETY=y` 时在每个要求持锁的入口插入断言（默认 n，构建期可选） |
| 断言的实现   | 用户自定义函数查询"我持有锁吗"                                   | IDF 用一套 5 态查询协议 `sys_thread_tcpip()` 实现（见下）                                |
| FromISR      | `sys_mbox_trypost_fromisr` + `ERR_NEED_SCHED`(若 port 支持)      | 照单实现，另加私有 `sys_sem_signal_isr` 支撑 VFS select 打断链路                         |

那个"五态查询"值得展开。上游建议用户实现 `LWIP_ASSERT_CORE_LOCKED()` 来自查线程安全，IDF 把这个检查具体化成一个带枚举参数的状态查询函数（`arch/sys_arch.h` 枚举五个值，实现在 `sys_arch.c`）：

```c
typedef enum {
    LWIP_CORE_LOCK_QUERY_HOLDER,       /* 我（当前任务）是否持有 core lock */
    LWIP_CORE_LOCK_MARK_HOLDER,        /* LOCK_TCPIP_CORE 拿锁后登记持有者 */
    LWIP_CORE_LOCK_UNMARK_HOLDER,      /* UNLOCK_TCPIP_CORE 摘销登记 */
    LWIP_CORE_MARK_TCPIP_TASK,         /* tcpip 线程出生时留下指纹 */
    LWIP_CORE_IS_TCPIP_INITIALIZED,    /* 协议栈起了没有 */
} sys_thread_core_lock_t;

bool sys_thread_tcpip(sys_thread_core_lock_t type);
```

配合 `port/include/lwipopts.h` 的两种断言形态：core locking 开启时查"持锁者是不是我"；关闭时退化成"当前上下文必须是 tcpip 任务本身"。一句话：**上游给的是一句箴言，IDF 把箴言铸成了一把带五个齿的钥匙**。这也解释了为什么 `udp_new` 敢在错误任务里直接断言复位——见第十四章与 [[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|FreeRTOS 第十八章（临界区与自旋锁）]] 对临界区成本的分析：这些断言每入口一次布尔查询，换来的是把一类跨线程事故从"偶发内存踩踏"降维成"稳定复现的 assert"。

---

## 19.7 实验：切换账单、优先级矩阵与两次故障注入

> [!info] 实验环境
> 工程：`practice/lwip-ch19-isr-and-priority-design/`（基于第三章模板改）。Kconfig 三件套：`FREERTOS_USE_TRACE_FACILITY` / `GENERATE_RUN_TIME_STATS` / `VTASKLIST_INCLUDE_COREID`。QEMU 启动脚本 `tools/run_qemu.sh` 带 `-nic user,model=open_eth,hostfwd=tcp::8022-:8888,hostfwd=tcp::8023-:9999`（8019/8020/8027 已被其他章节占用）。固件内一个 TCP 控制服务器（guest :9999）接受命令动态改变 echo 任务/emac_rx/tcpip 的运行时优先级（`vTaskPrioritySet`）、启停自旋注入、跑内置回环基准——单一烧录覆盖全部实验。

### 1. 实验 A：账单复现

```bash
python3 tools/ch19ctl.py bench                 # 触发 127.0.0.1 回环 ping-pong
python3 tools/ch19ctl.py stats                 # dump 任务表
python3 tools/bench_openloop.py --port 8022 --count 400 --pace-ms 5 --label nic-baseline
```

数据与分析见 19.2 节——那是本轮跑出的原始数字：回环每回合 `cli 215 / srv 227 / tcpip 435 µs`；NIC 全程 `emac 137 / tcpip 298 / app 166 µs`，host 侧 RTT p50 0.59ms。**解读**的骨架是一句方法论：优先级争论之前先看单价——如果每包 600µs 里 tcpip 占一半，那么"保护应用不被协议栈打扰"的叙事就该反过来先问"谁打扰了 tcpip"。

## 19.7 实验：切换账单、优先级矩阵与两次故障注入

> [!info] 实验环境
> 工程：`practice/lwip-ch19-isr-and-priority-design/`（基于第三章模板改）。Kconfig 三件套：`FREERTOS_USE_TRACE_FACILITY` / `GENERATE_RUN_TIME_STATS` / `VTASKLIST_INCLUDE_COREID`。QEMU 启动脚本 `tools/run_qemu.sh` 带 `-nic user,model=open_eth,hostfwd=tcp::8022-:8888,hostfwd=tcp::8023-:9999`（8019/8020/8027 已被其他章节占用）。固件内一个 TCP 控制服务器（guest :9999）接受命令动态改变 echo 任务/emac_rx/tcpip 的运行时优先级（`vTaskPrioritySet`）、启停自旋注入、跑内置回环基准——单一烧录覆盖全部实验。

### 0. 准备：从零到可注入的运行现场

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch19-isr-and-priority-design
idf.py set-target esp32            # 首次；sdkconfig.defaults 含 openeth 与统计三件套
idf.py build
idf.py qemu monitor < /dev/null || true   # 仅用于生成 build/qemu_flash.bin/qemu_efuse.bin
./tools/run_qemu.sh &                     # 串口落 run.log；hostfwd 见上方 info 框
# 等 run.log 出现 "TASKTABLE boot" 且控制通道可答：
python3 tools/ch19ctl.py hello            # 应答 "$$$ ch19 ready"
```

主机侧三个工具：`ch19ctl.py`（控制通道客户端，一条连接一条命令）、`bench_openloop.py`（开环 paced 探针，输出 CONN/BENCH/RTTms 三行指标，connect 超时会显式报 CONNECT_FAIL 而不是挂死）、`hammer.py`（时长模式闭环锤子，结束时打印速率）。所有对照轮次都在**同一 QEMU 实例内交错执行**（Batch 4 纪律：宿主机负载会让吞吐漂 ±50%，跨实例对比不可信）。

### 1. 实验 A：账单复现

**目的**：给 19.2 的理论站表配上可复现的数字——每回合 RTT、每个执行流分摊到的 CPU 微秒数。runtime stats 快照 diff（`uxTaskGetSystemState` + `ulRunTimeCounter`）就是这里的主角：它量不了"切换了几次"，但能量出"每个站花了多少电"，后者对容量规划更有用。

```bash
python3 tools/ch19ctl.py bench                 # 触发 127.0.0.1 回环 ping-pong（200 回合×512B）
python3 tools/ch19ctl.py stats                 # dump 任务表
python3 tools/bench_openloop.py --port 8022 --count 400 --pace-ms 5 --label nic-baseline
```

数据与分析见 19.2 节——那是本轮跑出的原始数字：回环每回合 `cli 215 / srv 227 / tcpip 435 µs`；NIC 全程 `emac 137 / tcpip 298 / app 166 µs`，host 侧 RTT p50 0.59ms。**解读**的骨架是一句方法论：优先级争论之前先看单价——如果每包 600µs 里 tcpip 占一半，那么"保护应用不被协议栈打扰"的叙事就该反过来先问"谁打扰了 tcpip"。

### 2. 实验 B：优先级矩阵——经验法则在余量面前失灵

**目的**：验证/证伪「应用永远不该高于 tcpip」这条经验法则的实际影响面——同一条负载在 app prio 低于/等于/高于 tcpip=18 三档下的 RTT 分布差异。

```bash
# 一轮完整扫描（工具与第三章模板同级放在 practice/lwip-ch19-isr-and-priority-design/tools/）：
for ROUND in 1 2 3; do
  for P in 18 12 21; do                        # 交错顺序抵消时间漂移
    python3 tools/ch19ctl.py prio $P           # 设 handler 优先级（新连接生效）
    python3 tools/hammer.py --port 8022 --size 512 --dur 6 &   # 可选背景负载
    python3 tools/bench_openloop.py --port 8022 --count 400 \
        --pace-ms 5 --size 128 --label "p${P}-r${ROUND}"
    wait; sleep 1
  done
done
```

设计要点：同一实例内交错三轮 × 三个 echo handler 优先级（12 低于 / 18 等于 / 21 高于 tcpip），每组均为主机开环 paced 打流取 RTT 分布（同时符合配对测量纪律）；echo 服务是 per-connection handler 模型，`prio` 命令只对新建连接生效，保证受试者"出生即带优先级"。两组背景条件各测一遍：

无背景负载（pace 5ms、128B；三轮流水分位数，单位 ms）：

| app prio | avg                | p50                | p90                | p99                | max   |
| -------- | ------------------ | ------------------ | ------------------ | ------------------ | ----- |
| 12 (<18) | 0.44 / 0.56 / 0.85 | 0.40 / 0.52 / 0.87 | 0.63 / 0.75 / 1.20 | 0.96 / 1.15 / 1.44 | ≤2.90 |
| 18 (=)   | 0.90 / 0.66 / 0.62 | 0.91 / 0.54 / 0.59 | 1.18 / 1.32 / 0.83 | 1.55 / 1.82 / 1.26 | ≤2.83 |
| 21 (>18) | 0.70 / 0.79 / 0.71 | 0.65 / 0.73 / 0.62 | 0.99 / 1.14 / 1.10 | 1.41 / 1.49 / 2.01 | ≤3.08 |

再加一台持续打满的"锤子"连接作背景（同 handler 优先级，512B 闭环高速流约 2700 回合/s；pace 2ms、256B 探针）：

| app prio | avg                | p50                | p90                | p99                |
| -------- | ------------------ | ------------------ | ------------------ | ------------------ |
| 12       | 0.62 / 0.68 / 0.66 | 0.60 / 0.63 / 0.62 | 0.81 / 0.93 / 0.88 | 1.18 / 1.28 / 1.32 |
| 18       | 0.68 / 0.64 / 0.64 | 0.67 / 0.63 / 0.63 | 0.90 / 0.83 / 0.84 | 1.27 / 1.26 / 1.12 |
| 21       | 0.67 / 0.54 / 0.55 | 0.56 / 0.49 / 0.51 | 0.94 / 0.79 / 0.83 | 2.54 / 1.35 / 1.25 |

**结果与本来的预期相反——三档在噪声里彼此不分家**（21>18 组 r1 的 p99=2.54 是孤例，另两轮回落到与其他组相同的 ~1.3ms 平台）。连同 experiment D 一起看（D 场景同样不见分化），这不是实验失败而是有效结论的前半句：

> [!important] 实验 B 结论
> 在「应用的 recv/send 都是礼貌阻塞、CPU 未饱和」的世界里，app 高于还是低于 tcpip 对延迟分布**没有可测量的影响**——固定优先级调度只在资源紧张区表态，余量充足区人人生而平等。"应用永远不该高于 tcpip"作为规范仍然成立（防御未来的饱和），但它防御的风险要到 19.7.3 那种条件下才会现形：**危害 = 高优先级 × 处理时长 × 频率，三者缺一则无事发生**。

### 3. 实验 C：故障注入·优先级倒挂——量出崩塌的临界线

**目的**：制造一个真正的高优先级长处理任务，定量找出"协议栈心跳开始停摆"的临界条件——不是问"倒挂会不会出事"，而是问"占空比涨到多少开始出事"。

```bash
python3 tools/ch19ctl.py spin 0 23 70        # 核 0、prio 23、占空比 70%
python3 tools/bench_openloop.py --port 8022 --count 100 --pace-ms 5 --timeout 5
python3 tools/ch19ctl.py spinstop            # 务必回收；必要时加 timeout 重试
```

这次不用争优先级，直接造一个。控制命令 `spin <core> <prio> <duty>` 在指定核创建更高优先级自旋任务（100ms 周期、duty% 忙转，铁律式纯计算无阻塞调用），然后扫描 duty：

| spinner（core0，prio23=全系统最高） | connect                       | p50  | p99  | max   | 判定                                 |
| ----------------------------------- | ----------------------------- | ---- | ---- | ----- | ------------------------------------ |
| 无（基线）                          | 0.8ms                         | 0.69 | 2.76 | 4.46  | 健康                                 |
| duty=50%                            | 0.8ms                         | 0.68 | 1.75 | 29.89 | 存活，尾部出现 ~30ms 尖刺            |
| duty=70%                            | 0.8ms                         | 0.65 | 3.03 | 32.94 | 存活但 p99/max 劣化 ~×5/~×7          |
| duty=85%                            | **>5s（探针整体超时被终止）** | –    | –    | –     | 事实瘫痪：新连接分钟级窗口才能挤进去 |
| duty=95%                            | 同上瘫痪                      | –    | –    | –     | 同上                                 |
| duty=100%                           | 30s 内 probe 一个请求都没完成 | –    | –    | –     | 全死                                 |

duty=100 时串口唯一输出是注入与回收命令的应答（run.log 原文摘录）：

```text
$$$ SPIN start core=0 prio=23 duty=100 rc=1
（30 秒 probe 窗口：serial 静默，无 panic、无 watchdog、无丢帧日志）
$$$ SPIN stopped                                    ← spinstop 从核 1 的 ctrl_srv 溜进来救场
```

自旋期间的活体证据（`stats` 快照,`spinner` 一个任务在 ~5s 窗口内吃掉 2.66s run-time；此时其余站点 rt 明显变瘦）：

```text
### T spinner   prio=23 core=0  rt=2661669 hwm=2600
### T tcpip     prio=18 core=NA rt=275174 hwm=2296
### T emac_rx   prio=15 core=NA rt=82971  hwm=3248
### T IDLE0     prio=0  core=0  rt=79445470 hwm=976
```

> [!warning] 三件诊断事实
> ① **恶化是无声的**：整个 duty 扫描期 serial 上没有一行报错——没有丢帧日志、没有 panic。"系统活着但已经没法用"在日志上表现为空白。
> ② **Task Watchdog 在本配方静音**：虽然工程里 `CONFIG_ESP_TASK_WDT_INIT=y` 且监听两个 IDLE，但 CONVENTIONS 规定的 QEMU 启动行把 timg WDT 全局关闭了（`wdt_disable=true`），TWDT 依赖的中断根本不存在。真机上同样的注入会在超时（默认 5s）后打出经典的 `Task watchdog got triggered: IDLE0 (CPU 0)` 并附各任务 PC/backtrace——那一幕在 QEMU 复现不出来，需真机补票。
> ③ **控制通道是被测路径的一部分**：85%/95% 时连"停止注入"这条救命命令都要在旋转缝隙里挤几秒到几十秒才能送达（第一次注入实验因此被观测卡死过）。做故障注入时控制平面永远设计在受害者带宽之外——本工程的 ctrl_srv 钉在核 1、prio 22，靠的就是"至少还有一个核是清白的"，但当注入钉上两核时连它也会失效，唯一的救法只剩复位。诊断建议的组合拳：外部探针周期差（connect/RTT 超限告警）→ `stats` 看 spinner 的 run-time 增速 → 真机上 TWDT + backtrace 定位元凶 PC。

### 4. 实验 D：故障注入·RX 任务饿死——再一次"无事发生"，以及为什么

**目的**：检验「RX 任务被低优先级化后会丢帧/劣化」这条常被背诵的结论在本环境的真实触发条件——把 emac_rx 一路压到 IDLE 档再看吞吐、延迟与驱动层丢帧计数。

```bash
python3 tools/ch19ctl.py rxprio 4                      # 运行时改 emac_rx 优先级
timeout 20 python3 tools/hammer.py --port 8022 --size 512 --dur 5 &
timeout 20 python3 tools/hammer.py --port 8022 --size 512 --dur 5 &
sleep 0.2
python3 tools/bench_openloop.py --port 8022 --count 200 --pace-ms 3 --label rx4
wait
grep -c "RX frame dropped" run.log                     # 驱动层丢帧计数（OPENETH_INT_BUSY）
python3 tools/ch19ctl.py rxprio 15                     # 收摊还原
```

emac_rx 的运行时优先级可以用 `rxprio <n>` 直接改（扫任务表按名找句柄 `vTaskPrioritySet`——CH19 工程不需要改 IDF 代码，因为 `eth_mac_config_t.rx_task_prio` 本来就是应用可配的，运行时改则靠 `vTaskPrioritySet`）。固定双锤子背景（2×512B 闭环，合计约 2700 回合/s）加开环探针，扫描 emac_rx 优先级：

| emac_rx prio                | 锤子合计速率 (rounds/s) | 探针 p50 | 探针 p99 | OPENETH "RX frame dropped" 计数增量 |
| --------------------------- | ----------------------- | -------- | -------- | ----------------------------------- |
| 15（出厂）                  | 1013+1751 = 2764        | 0.69ms   | 1.14     | 0                                   |
| 10                          | 1184+1728 = 2912        | 0.57     | 1.38     | 0                                   |
| 6                           | 1110+1662 = 2772        | 0.54     | 1.39     | 0                                   |
| 4                           | 1663+1100 = 2763        | 0.52     | 1.13     | 0                                   |
| 1（等于 IDLE 档！人人可抢） | 1083+1615 = 2698        | 0.63     | 1.08     | 0                                   |

压到 IDLE 级都不掉吞吐——用 19.2 的单价表算笔账就通了：2700 回合/s × 全链 ~600µs ≈ 1.6 个核当量，仍低于 2；**加上 NO_AFFINITY 的迁移自由度，RX 站总能找到空隙搬帧**。空的优先级表态当然不起作用。要让 RX 真的饿死需要两件事之一：把总需求推过 2 核容量（本环境下先撞墙的是 SLIRP 转发能力，见第六章 ~120Mbit 天花板），或剥夺迁移自由（两个核各钉一个中等优先级的强占者——这正是实验 C 证明会在 duty 70~85% 区间引爆的情形，只是 C 的受害者是全链路而不仅是 RX）。另外别忘了 openeth 描述符环只有 4×1600B（`ETH_OPENETH_DMA_RX_BUFFER_NUM` 默认 4）：洪峰一旦超过驱动消化速度，最先溢出的就是它，ISR 的 `OPENETH_INT_BUSY` 会打印 "RX frame dropped"——本实验全程计数为 0，说明流量离这个水位还很远。真要制造帧级丢弃，与其拨优先级不如直接注流量（第五章的经验）。

**D 的结论与 B 互为印证：优先级排布的价值不在抢来的那点余量，而在饱和拐点之后的事情排序权**——C 实验展示了拐点的位置感（单核 70%~85% 占空比之间），而生产系统的正确动作是在拐点到来之前主动保留余地：钉核隔离、为高频路径减负、把"高优先级"当作稀缺品签发。

---

## 19.8 小结

- 角色表与全家桶优先级：tcpip(18)、emac_rx(15)、sys_evt(20)、esp_timer(22) 分别来自 `CONFIG_LWIP_TCPIP_TASK_PRIO`、`ETH_MAC_DEFAULT_CONFIG().rx_task_prio`、`ESP_TASKD_EVENT_PRIO/TIMER PRIO = configMAX_PRIORITIES-5/-3`（MAX=25）；ISR 不占任务位但每次进出一轮中断往返。
- 上下文切换账单：一次上行（帧→recv 返回）≈4 次任务级切换 +1 次 IRQ 往返，量级 ≥10 次切换/最小 echo 往返；切换的决胜点全在邮箱交接处——谁的优先级高谁当场接管 CPU（tcpip 18>15 当场抢 emac_rx；echo_hdl 5<18 等 tcpip 睡了才轮到）。
- 实测单价：NIC 全程 ~601µs CPU/包（emac 137 / tcpip 298 / app 166）；回环 RTT 均值 631µs 其中 tcpip 一站独吞 435µs——双核对账 sum>wall 不是误差。
- FromISR 通道三件套：`sys_mbox_trypost_fromisr`（trypost+ISR 安全+`ERR_NEED_SCHED`=123 转述 yield 责任）、`tcpip_callbackmsg_trycallback_fromisr`（上游唯一接入点）、`sys_sem_signal_isr`（IDF 私有）——后者的唯一消费者是 `vfs_lwip.c` 的 `stop_socket_select_isr`，串起"任意上下文叫醒 select 等待者"的责任链。
- 中断层位：`esp_intr_alloc` 未指定 level 时落到 LOWMED（1~3，C 可处理带）；openeth 以 `ESP_INTR_FLAG_IRAM` 注册即落此带，ISR 仅读状态+通知任务+清标志二十行——长工作的正确去处是任务域。
- 亲和性：`CONFIG_LWIP_TCPIP_TASK_AFFINITY`（hex，NO_AFFINITY/CPU0/CPU1）经 `sys_thread_new()` 强制套用于 lwIP 自建线程；emac_rx 由 `ETH_MAC_FLAG_PIN_TO_CORE` 另行控制；ping 任务实际裸 `xTaskCreate`（help 文本与实现脱节）。NO_AFFINITY 给双份算力收走确定性，钉核是比调优先级更强的隔离。
- 多核守卫：`CONFIG_LWIP_CHECK_THREAD_SAFETY` 把上游箴言 `LWIP_ASSERT_CORE_LOCKED` 铸成 `sys_thread_tcpip()` 五态查询（QUERY/MARK/UNMARK/MARK_TCPIP_TASK/IS_INITIALIZED），把跨线程误用降维成稳定 assert。
- 实验结论三连：**B**——礼貌阻塞且 CPU 未饱和时，app 相对 tcpip 的优先级不影响 RTT 分布（三档两轮噪声内持平）；**C**——伤害公式 = 高优先级×时长×频率，prio23 自旋钉核的存活分水岭在占空比 70%~85%，100% 全灭且全程 serial 无声；**D**——emac_rx 压到 IDLE 级在 ~1.6 核当量负载下吞吐纹丝不动，真正的丢帧阀在描述符环（4×1600B）与 SLIRP 天花板，不在优先级表上。
- 方法论：改动前先算单价账；对照组必须同实例交错配对；故障注入的控制平面要活在受害者带宽之外；"高优先级"是稀缺品，签发即负债。

至此 Part V「并发与集成」收官。从第十三章 tcpip_thread 的邮箱心跳，到第十四章 sys_arch 适配层，再到第十五章 raw API 的 callback 世界、第十六章 socket/VFS 的阻塞与逃生、第十七章移植指南、第十八章 WiFi 的参天大树——一路走来都是同一个主题的变奏：**单线程协议栈如何在多任务的世界里守住自己的节奏**。本章把节拍器的摆锤拆给你看了：中断给速度，优先级定秩序，affinity 给确定性。

Part VI 进入应用实战，第一站是每个嵌入式工程师都绕不开的 HTTP server：`esp_http_server` 组件站在 lwIP socket 之上的位置与角色、listen backlog 与 recv 节奏、URI 表匹配如何把一串字节路由到处理函数、以及第一个 404 的诞生。19.2 节那张每包 600µs 的账单，马上要在"每次 HTTP 请求值多少钱"的语境里重新报价。见 [[2026-08-26-lwip-deep-dive-ch20-http-server|第二十章]]。
