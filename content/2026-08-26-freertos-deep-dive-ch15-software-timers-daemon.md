---
title: "FreeRTOS 深度解析（十五）：软件定时器"
date: 2026-08-26
description: "拆解 timers.c：守护任务模型、Timer_t 与两条活跃链表、tick 溢出时的链表切换、命令队列全链路、回调运行在守护任务上下文的铁律，以及定时器精度的真实构成；QEMU 实验观测混合周期定时器的回调延迟。"
tags: [freertos, rtos, esp32, esp-idf, timers, daemon-task, ipc, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 15. **第十五章：软件定时器：守护任务与命令队列**

# FreeRTOS 深度解析（十五）：软件定时器

这一章拆解 `timers.c`（IDF v6.0.2 默认编译的 `FreeRTOS-Kernel/` 树中约 54KB 的那份）。软件定时器是内核六大文件里唯一一个**自身不碰任何硬件**的模块：没有中断、没有寄存器、没有汇编。它全部构建在前几章已经拆过的机制之上——一个普通任务、一条普通队列、两条普通链表。正因为它"什么都是用旧零件攒的"，读它是检验前面章节掌握程度的最好试金石。

先给出全章结论，再逐层展开：

> **FreeRTOS 软件定时器 = 一个名叫 "Tmr Svc" 的普通任务（守护任务）+ 一条命令队列 + 两条按到期时间排序的链表。** 所有定时器 API 都只是往队列里塞消息；所有定时器回调都在守护任务这一个执行流里串行执行。这个设计换来三样东西：回调不在中断里跑、对定时器状态的所有修改天然串行化、无定时器时零开销。代价是一条铁律——**回调里禁止阻塞，否则全部定时器一起卡死**。

---

## 15.1 守护任务模型：定时器为什么长这样

### 1. 两条实现路线

"到点执行一个函数"有两种经典实现。路线 A 是每个定时器配一个**硬件定时器中断**，在中断里调回调：精度 µs 级，但硬件定时器数量有限（ESP32 只有几组）、回调跑在中断上下文不能调阻塞 API、每个中断都是全局延迟源。FreeRTOS 选了路线 B：**一个任务统一记账**——算出最近到期时间，睡到那一刻，醒来执行回调，回到睡眠。数量不限、回调在任务上下文、一套机制服务所有定时器；代价是精度受 tick 与调度限制（15.5 节）。而且它做到了极致——**整个模块连一个独立中断都不占有**，计时完全复用第 9 章的 tick：到期时间以 tick 记账，守护任务用"带超时的阻塞"睡到最近到期点。

### 2. 守护任务架构全景

```text
                ┌────────────────────────────────────────────────────┐
                │       Tmr Svc（守护任务 / daemon task）             │
                │       prvTimerTask()，优先级 configTIMER_TASK_      │
                │       PRIORITY（IDF 默认 1）                       │
                │                                                    │
                │   for (;;) {                                       │
                │     ① prvGetNextExpireTime()      ← 看链表头       │
                │     ② prvProcessTimerOrBlockTask()                 │
                │          ├─ 已到期 → prvProcessExpiredTimer()      │
                │          │             └─ pxCallbackFunction()     │
                │          └─ 未到期 → vQueueWaitForMessage          │
                │                      Restricted(差几tick睡几tick)  │
                │     ③ prvProcessReceivedCommands() ← 排干命令队列  │
                │          └─ 命令若已迟到超一个周期 → 立即回调       │
                │                                                    │
                │   pxCurrentTimerList        pxOverflowTimerList    │
                │   [按到期 tick 升序]         [装着回绕后的到期时间]  │
                └───────────────▲─────────────────────▲─────────────┘
                                │ 命令入队             │ tick 推进到点即唤醒
                  ┌─────────────┴───────────┐ ┌───────┴────────────┐
                  │ 任意任务 / ISR           │ │ tick 中断（第 9 章）│
                  │ xTimerStart/Stop/...    │ │ xTaskGetTickCount() │
                  └─────────────────────────┘ └────────────────────┘
```

三块构件分别回答：**谁在计时**（tick 中断，复用）、**谁在等待**（守护任务自己睡）、**谁在改状态**（命令队列串行化）。守护任务由 `vTaskStartScheduler()`（`tasks.c`）在创建完每核 Idle 任务之后、正式开跑调度之前调用 `xTimerCreateTimerTask()` 创建——只要 `configUSE_TIMERS` 打开（IDF 的 `CONFIG_FREERTOS_USE_TIMERS` 默认 y），你的程序从第一个 tick 起就存在这个任务，与你是否创建过定时器无关。

### 3. 命令流转图

用户态的每一次定时器操作，走的都是同一条路：

```text
 任务上下文                     xTimerQueue（深 10，FIFO）         Tmr Svc
 ──────────                    ─────────────────────────        ──────────────────────────
 xTimerStart(tmr, 0)
   │ 宏展开（timers.h）
   ▼
 xTimerGenericCommand(tmr, tmrCOMMAND_START,
                      xTaskGetTickCount(), NULL, 0)
   │ 组装 DaemonTaskMessage_t{xMessageID=1, {现在时刻, tmr}}
   ▼
 xQueueSendToBack ───────────▶ [msg][msg][msg]... ──▶ ③ prvProcessReceivedCommands()
                                                       ├─ 把 tmr 从所在链表摘下
 ISR 上下文                                            │ ├─ START/RESET → 置 ACTIVE，重算
 xTimerStopFromISR(tmr, &woken)                        │ │   到期=命令时刻+周期，插回链表
   │ xQueueSendToBackFromISR ─▶ 同一条队列              │ ├─ STOP → 清 ACTIVE 位
   ▼                                                   │ ├─ CHANGE_PERIOD → 改周期重插
 portYIELD_FROM_ISR(woken)  ← 唤醒可能的高优先级守护任务  │ └─ DELETE → 动态创建的则 free
                                                       └─ 若入队到处理的延迟 > 周期：
                                                          视为已过期，立即执行回调
```

注意一个精妙的细节：`xTimerStart()` 的"起始时刻"是在**发送端**用 `xTaskGetTickCount()` 盖章、随消息带过去的，而不是守护任务处理时才取。15.3 节展开为什么必须这样做。

### 4. 这个设计买到了什么

| 收益                                             | 机制来源                                       |
| ------------------------------------------------ | ---------------------------------------------- |
| 回调跑在任务上下文，可以调用（不阻塞的）内核 API | 回调由守护任务直接函数调用，不是中断           |
| 定时器状态修改天然串行化，无竞态                 | 所有修改都发生在守护任务这一个执行流里         |
| 无定时器时零 CPU 开销                            | 守护任务在队列上无限期阻塞（和 Idle 一样睡着） |
| 任务与 ISR 都能安全操作定时器                    | 队列本来就是任务/ISR 安全的 IPC（第 10 章）    |

代价同样清晰：所有回调共享一个执行流（一个慢回调拖累所有定时器）、精度受限于 tick 粒度与调度延迟（15.5 节）。这是典型的"用精度换结构和数量"。

---

## 15.2 Timer_t 与两条活跃链表

### 1. Timer_t 解剖

`timers.c` 里的定义（`timers.h` 对外只暴露 `TimerHandle_t` 不透明指针和等大的 `StaticTimer_t`）：

```c
typedef struct tmrTimerControl
{
    const char *pcTimerName;       /* 名字，仅供调试，内核不使用 */
    ListItem_t xTimerListItem;     /* 挂进活跃链表的节点：排序键=到期tick，owner=本结构 */
    TickType_t xTimerPeriodInTicks;/* 周期（timer 的"长短"） */
    void *pvTimerID;               /* 用户 ID：多个定时器共用一个回调时用来区分自己 */
    TimerCallbackFunction_t pxCallbackFunction; /* 到期时调用的函数 */
    #if (configUSE_TRACE_FACILITY == 1)
        UBaseType_t uxTimerNumber; /* trace 工具用的编号 */
    #endif
    uint8_t ucStatus;              /* 状态位图，见下 */
} xTIMER;
typedef xTIMER Timer_t;
```

`ucStatus` 只用三个比特（`timers.c` 顶部的宏）：

| 位   | 宏                                  | 含义                                 |
| ---- | ----------------------------------- | ------------------------------------ |
| 0x01 | `tmrSTATUS_IS_ACTIVE`               | 活动（已 start，挂在某条活跃链表上） |
| 0x02 | `tmrSTATUS_IS_STATICALLY_ALLOCATED` | 由 `xTimerCreateStatic()` 静态创建   |
| 0x04 | `tmrSTATUS_IS_AUTORELOAD`           | 周期定时器（否则 one-shot）          |

对照第 5 章的 TCB：Timer_t 里**没有栈、没有优先级、没有状态机**——定时器不是执行流，只是一条"到期时间 + 回调指针"的记账记录。它甚至不常驻任何链表：`xTimerCreate()` 把 `ucStatus` 清零（dormant 休眠态），此刻的定时器就是堆里一块孤立内存，直到某个 START 命令把它插进活跃链表。`xTimerIsTimerActive()` 只是读一下 ACTIVE 位。另外 `prvInitialiseNewTimer()` 开头有 `configASSERT(xTimerPeriodInTicks > 0)`：**周期为 0 非法**——0 会让"到期时间 = 起点 + 0"立即过期，追赶循环（15.4 节）失去终止条件。

### 2. 有序链表：排序键就是到期时间

活跃定时器住在两条 `List_t` 里（`list.c` 的原语，第 6 章拆过）：

```text
 pxCurrentTimerList（按到期 tick 升序）：
 [LED:1000] → [BTN:1000] → [SENS:1330] → [LCD:2500] → NULL
  同一 tick 到期的按插入顺序排；链表头 = 全场最近到期点
  （prvGetNextExpireTime 只看头，O(1)）
```

`prvInsertTimerInActiveList()` 用 `vListInsert()` 按到期 tick 插入，链表头天然就是最近到期点。这个"排序键放在 ListItem_t 的 value 里"的手法，与第 6 章就绪链表按优先级分桶、第 9 章延时链表按唤醒 tick 排序完全同构——`list.c` 是全内核唯一的链表底座。

### 3. 两条链表与 tick 溢出：prvSwitchTimerLists

`TickType_t` 是无符号整数，tick 计数会回绕：`0xFFFFFFFF → 0x00000000`。到期时间是"当前 tick + 周期"的加法，一旦回绕，"2505 比 1330 晚"这种整数比较就会失效。内核的解法是**双链表轮换**：

```text
 tick 轴：  ...... 0xFFFFFFFE, 0xFFFFFFFF, 0x00000000, 0x00000001 ......

 pxCurrentTimerList                pxOverflowTimerList
 到期落在"回绕前半程"的定时器       到期已回绕（数值变回小值）的定时器
 [0xFFFFFF10] [0xFFFFFF80]          [0x00000064] [0x00000106]
        ▲                                  ▲
        └───────────── 指针互换 ───────────┘
```

判定在 `prvSampleTimeNow()`：它保存上次采样值，一旦发现 `xTimeNow < xLastTime`（tick 变小了 = 回绕发生），调用 `prvSwitchTimerLists()`：先 `while` 循环逐个取头执行 `prvProcessExpiredTimer()`——回绕时还留在"前半程"链表里的定时器必然已过期；再交换 `pxCurrentTimerList ⇄ pxOverflowTimerList`，让"未来的"链表转正。于是比较永远发生在同一回绕周期内部，整数序即时间序。32 位 tick 在 IDF 默认 100Hz 下约 497 天回绕一次，提 tick 到 1000Hz 则约 50 天——听起来遥远，但连续运行多年的设备并不罕见，这是正确性刚需而非优雅装饰。

### 4. prvInsertTimerInActiveList：插入时的四象限判定

一个定时器插进哪条链表、要不要立即过期，由 `prvInsertTimerInActiveList()` 判定（到期时间 = 命令时刻 + 周期）：

```text
 ┌─────────────────────────────┬─────────────────────────────────────────────┐
 │ 到期 > 现在（正常情况）        │ 到期 <= 现在（已经"过期"）                    │
 ├─────────────────────────────┼─────────────────────────────────────────────┤
 │ 未跨回绕 → 插 pxCurrentList  │ (现在-命令时刻) >= 周期 → 返回 pdTRUE：        │
 │ 跨了回绕但到期没跨 → 视为已过  │     命令在队列里躺的时间比周期还长，           │
 │ 期，返回 pdTRUE              │     直接追赶执行（不插链表）                   │
 │                              │ 否则 → 插 pxOverflowList（到期其实在下个周期） │
 └─────────────────────────────┴─────────────────────────────────────────────┘
```

右下角那一格最反直觉：`到期 <= 现在` 但还没超过一个周期，说明这个"到期时间"其实落在回绕之后——插进溢出链表等下个周期。

---

## 15.3 命令队列：xTimerGenericCommand 全链路

### 1. 命令枚举：一张表看懂

`timers.h` 定义了命令编号，**负数是"请守护任务代执行函数"的请求，非负数才是定时器命令**：

| 值  | 命令                                                      | 由哪些 API 发出                   |
| --- | --------------------------------------------------------- | --------------------------------- |
| -2  | `tmrCOMMAND_EXECUTE_CALLBACK_FROM_ISR`                    | `xTimerPendFunctionCallFromISR()` |
| -1  | `tmrCOMMAND_EXECUTE_CALLBACK`                             | `xTimerPendFunctionCall()`        |
| 1   | `tmrCOMMAND_START`                                        | `xTimerStart()`                   |
| 2   | `tmrCOMMAND_RESET`                                        | `xTimerReset()`                   |
| 3   | `tmrCOMMAND_STOP`                                         | `xTimerStop()`                    |
| 4   | `tmrCOMMAND_CHANGE_PERIOD`                                | `xTimerChangePeriod()`            |
| 5   | `tmrCOMMAND_DELETE`                                       | `xTimerDelete()`                  |
| ≥6  | `*_FROM_ISR`（START=6, RESET=7, STOP=8, CHANGE_PERIOD=9） | 各 `*FromISR()` 变体              |

（值 0 的 `tmrCOMMAND_START_DONT_TRACE` 供内部免 trace 使用。）`tmrFIRST_FROM_ISR_COMMAND == 6` 是分水岭：发送端据此选 `xQueueSendToBack()` 还是 `xQueueSendToBackFromISR()`。消息本体是带判别联合的 `DaemonTaskMessage_t`：

```c
typedef struct tmrTimerQueueMessage
{
    BaseType_t xMessageID;          /* 上表的命令编号 */
    union
    {
        TimerParameter_t xTimerParameters;        /* {TickType_t xMessageValue;
                                                    Timer_t *pxTimer;} */
        CallbackParameters_t xCallbackParameters; /* 仅 pended function 用 */
    } u;
} DaemonTaskMessage_t;
```

队列本身在**第一个定时器被创建时**才惰性建立：`prvCheckForValidListAndQueue()` 里 `xQueueCreate(configTIMER_QUEUE_LENGTH, sizeof(DaemonTaskMessage_t))`，并注册进队列注册表，名字就叫 `"TmrQ"`。IDF 默认 `CONFIG_FREERTOS_TIMER_QUEUE_LENGTH=10`。

### 2. 发送端：为什么起始时刻在发送端盖章

公共 API 全是宏，展开后都汇聚到同一个函数 `xTimerGenericCommand()`：

```c
/* timers.h */
#define xTimerStart( xTimer, xTicksToWait ) \
    xTimerGenericCommand( ( xTimer ), tmrCOMMAND_START, \
                          ( xTaskGetTickCount() ), NULL, ( xTicksToWait ) )
#define xTimerReset( xTimer, xTicksToWait ) \
    xTimerGenericCommand( ( xTimer ), tmrCOMMAND_RESET, \
                          ( xTaskGetTickCount() ), NULL, ( xTicksToWait ) )
#define xTimerChangePeriod( xTimer, xNewPeriod, xTicksToWait ) \
    xTimerGenericCommand( ( xTimer ), tmrCOMMAND_CHANGE_PERIOD, \
                          ( xNewPeriod ), NULL, ( xTicksToWait ) )
```

`xMessageValue` 对 START/RESET 装的是**调用时刻的 tick**，对 CHANGE_PERIOD 装的是**新周期**，对 STOP/DELETE 装 0。前者的深意：守护任务处理命令时算 `到期 = xMessageValue + 周期`。如果处理时刻才取当前 tick，"命令在队列里排队的时间"就会被无声抹掉——一个 100ms 定时器的实际首触发会变成"入队延迟 + 100ms"。发送端盖章让延迟显形：`prvInsertTimerInActiveList()` 拿 `(xTimeNow - xCommandTime) >= 周期` 一比，就知道命令已迟到一个周期以上，直接转入追赶执行（15.2 节第 4 小节）。**你调用的 `xTimerStart()` 返回 `pdPASS` 只代表命令进了队列，不代表定时器已经上路**——这是软件定时器与 `vTaskDelay()` 最本质的语义差异。

`xTimerGenericCommand()` 本体极短：装配消息，看调度器是否已启动——已启动则 `xQueueSendToBack(..., xTicksToWait)`（允许调用任务为等队列空间而阻塞）；未启动（`main()` 里调度器开跑前）则强制零等待发送。FromISR 命令走 `xQueueSendToBackFromISR()`，按第 10 章的规矩在退出中断前按 `pxHigherPriorityTaskWoken` 触发切换，唤醒睡着的守护任务。

### 3. 附赠机制：xTimerPendFunctionCall

负数命令是这套队列架构的自然延伸：既然守护任务是一个"醒来就执行工作"的上下文，除了定时器回调，也可以把**任意函数**推给它执行：

```c
/* ISR 里：把 vFlushBuffer 推迟给守护任务执行 */
BaseType_t woken = pdFALSE;
xTimerPendFunctionCallFromISR(vFlushBuffer, buf, len, &woken);
portYIELD_FROM_ISR(woken);   /* 守护任务若被唤醒且够高优先级，退出中断即切过去 */

/* 任务里 */
xTimerPendFunctionCall(vFlushBuffer, buf, len, pdMS_TO_TICKS(100));
```

这是 ISR 后半部（bottom half）的标准姿势之一：中断里只做必须做的事，剩下的打包丢给守护任务，比"为每个中断建一个工作队列任务"省一整个任务的 RAM。IDF 中 `INCLUDE_xTimerPendFunctionCall` 随 `CONFIG_FREERTOS_USE_TIMERS` 默认置 1。注意 `PendedFunction_t` 的签名是 `void (*)(void *, uint32_t)`，与定时器回调不同。

---

## 15.4 守护任务主循环：prvTimerTask

### 1. 三步循环

`prvTimerTask()` 的主循环短到可以整段贴出：

```c
static portTASK_FUNCTION( prvTimerTask, pvParameters )
{
    TickType_t xNextExpireTime;
    BaseType_t xListWasEmpty;

    for( ; ; )
    {
        xNextExpireTime = prvGetNextExpireTime( &xListWasEmpty );      /* ① */
        prvProcessTimerOrBlockTask( xNextExpireTime, xListWasEmpty );  /* ② */
        prvProcessReceivedCommands();                                  /* ③ */
    }
}
```

循环不变式是：**每一圈结束时，链表头总是全场最近的未处理到期点，队列总是空的**。三步各自维护这个不变式的一段。

### 2. ① prvGetNextExpireTime：看一眼链表头

链表有序，"最近到期时间"就是头节点的 value；链表空则返回 0——一个必然不大于当前 tick 的值，迫使第②步立刻进入处理路径，在 `prvSampleTimeNow()` 里检测回绕、切换链表，重新评估。这是"无定时器时也能正确跨过 tick 回绕"的兜底。

### 3. ② prvProcessTimerOrBlockTask：睡到点还是现在就干

```text
 进入"定时器锁"临界区（IDF: prvENTER_CRITICAL_OR_SUSPEND_ALL(&xTimerLock)
                         Vanilla: vTaskSuspendAll()）
   │
   ├─ xTimeNow = prvSampleTimeNow()   ← 可能在此触发链表切换（回绕）
   │
   ├─ 已到期（xNextExpireTime <= xTimeNow）
   │     └─ 解锁 → prvProcessExpiredTimer()：
   │          取头 → 摘链 → 周期型 prvReloadTimer 重插 / one-shot 清 ACTIVE
   │          → 调用 pxCallbackFunction()
   │
   └─ 未到期
         └─ vQueueWaitForMessageRestricted(xTimerQueue,
                xNextExpireTime - xTimeNow, 两链表皆空?)
            解锁 → portYIELD_WITHIN_API() 让出 CPU
```

`vQueueWaitForMessageRestricted()` 是 `queue.c` 提供给内核内部用的接口（第 10 章）：把任务挂到队列的等待链上、**同时**挂上"最多睡 N 个 tick"的延时——哪个先到就先醒。这正是"到点执行"与"随时响应命令"的双路等待，一个原语同时覆盖。醒了之后循环回到①重新看表头（可能命令刚改了最近到期点）。

### 4. ③ prvProcessReceivedCommands：命令分派

`while (xQueueReceive(..., tmrNO_DELAY))` 排干队列，每条消息有个统一前置动作：**把目标定时器从它当前所在的任何链表上摘下来**（`uxListRemove`），然后按命令改状态、重插：

| 命令          | 处理                                                                                              |
| ------------- | ------------------------------------------------------------------------------------------------- |
| START / RESET | 置 ACTIVE；以 `消息里的命令时刻 + 周期` 为到期重插；若已迟到超过一个周期 → 立即执行回调（追赶）   |
| STOP          | 清 ACTIVE（定时器已在入口摘链，无别的动作）                                                       |
| CHANGE_PERIOD | 置 ACTIVE，写入新周期，以 `现在 + 新周期` 重插——**改周期必然同时激活**，这是它和 START 的语义耦合 |
| DELETE        | 入口已摘链；动态创建的定时器在此 `vPortFree()`，静态创建的只清 ACTIVE                             |
| 负数命令      | 不碰定时器，直接调用 pended function                                                              |

两个值得记的语义：**STOP 后再 START，周期从头算**（新的命令时刻）；**CHANGE_PERIOD 对休眠定时器也生效并顺带激活它**——"先 create 再 change period"是不需要预先 start 的启动手法。

### 5. 追赶机制 prvReloadTimer：迟到的账要连本带利还

周期定时器到期后，`prvProcessExpiredTimer()` 调用 `prvReloadTimer()` 重插。注意它的循环形状：

```c
static void prvReloadTimer( Timer_t * const pxTimer,
                            TickType_t xExpiredTime,
                            const TickType_t xTimeNow )
{
    /* 下个到期点若也已过去：推进到期时间，补一次回调，再试 */
    while( prvInsertTimerInActiveList( pxTimer,
             ( xExpiredTime + pxTimer->xTimerPeriodInTicks ),
             xTimeNow, xExpiredTime ) != pdFALSE )
    {
        xExpiredTime += pxTimer->xTimerPeriodInTicks;   /* 对齐到未来 */
        traceTIMER_EXPIRED( pxTimer );
        pxTimer->pxCallbackFunction( ( TimerHandle_t ) pxTimer );  /* 补发！ */
    }
}
```

如果守护任务因故迟到了 3 个周期，醒来后这个循环会**连发 3 次回调**，把到期次数补齐，再把到期时间对齐到未来。所以软件定时器的语义不是"每 N ms 执行一次"（那是理想），而是"**按名义节拍记账、事后集中补课**"。15.7 节的实验会让你亲眼看到补课。如果你的回调是幂等的计数器，这正确；如果你要"错过就跳过"，就得在回调里自己用 `xTimerGetExpiryTime()` 对账。

---

## 15.5 铁律与精度：回调运行在守护任务上下文

### 1. 为什么回调里绝对不能阻塞

回调的调用点只有三处：`prvProcessExpiredTimer()`、`prvProcessReceivedCommands()` 的追赶分支、`prvReloadTimer()` 的补发循环——**全部在守护任务的执行流里**。推演一下回调里阻塞的后果：

```text
 某回调调用 vTaskDelay(100ms)（或任何带超时的阻塞 API）
   → 守护任务进入 Blocked 态 100ms
   → 这 100ms 内：所有定时器的到期无人处理（包括本应到期的其他定时器）
   → 所有命令无人消费：队列 10 格迅速填满
   → 之后任何任务的 xTimerStart() 返回 pdFAIL（队列满、零等待发送失败）
   → pended function 也全部停摆
 症状：定时器"集体失踪"，与出问题的那个定时器毫无关系的功能一起死
```

一个回调的问题**系统性**地传染给全部定时器，因为它们共享唯一的执行流。这不是"可能出问题"，是结构上必然。

### 2. 事故案例：一段看起来无辜的代码

```c
/* 事故现场：按键背光控制。需求：500ms 无操作关背光 */
static void backlight_timer_cb( TimerHandle_t xTimer )
{
    /* 保存亮度设置到 NVS —— 新人觉得"每次关背光时存一下"很合理 */
    nvs_commit(nvs_handle);              /* ✗ Flash 写，内部有锁、有等待 */
    /* 更直白的错误版本：vTaskDelay(pdMS_TO_TICKS(10)); */
    lcd_set_backlight(false);
}

void on_key_pressed(void)
{
    lcd_set_backlight(true);
    xTimerReset(backlight_timer, 0);     /* 续命 500ms */
}
```

`nvs_commit()` 内部走 SPI Flash 驱动，可能在信号量上等待写入完成——本质上就是阻塞。上线后的现象极具迷惑性：**背光功能本身正常，但系统里其他所有周期任务（传感器采样、LED 心跳）每隔几分钟集体停跳几十毫秒**，且停跳时刻与按键操作相关。定位手段：出问题时用 `uxTaskGetSystemState()` 或 GDB（第 24 章）看 "Tmr Svc" 的状态，会发现它 Blocked 在某个队列/信号量上而不是 `TmrQ`。修复模式是把工作转出去：回调里只给专门的工作任务发通知（第 13 章的任务通知是最轻的选择），慢操作在工作任务里做。

### 3. 回调里能做什么、不能做什么

| 可以                                       | 不可以                                                                   |
| ------------------------------------------ | ------------------------------------------------------------------------ |
| 改共享变量（单个对齐字，且无其他写者并发） | 任何会阻塞的调用：`vTaskDelay`、带超时的队列/信号量、NVS/Flash/网络      |
| `xTimerStart/Stop/Reset`，等待时间传 0     | 带**非零**等待时间的定时器 API——队列满时守护任务会等自己消费的队列，死锁 |
| `xTimerChangePeriod`（同样 0 等待）        | `xTimerDelete` 自己——内存随即被守护任务 free，返回后再碰句柄即 UAF       |
| `xTimerPendFunctionCall`（0 等待）         | 拿任何可能被任务长期持有的互斥量                                         |
| 一次性短计算、置事件位、发通知             | `printf` 到慢速 UART（拖累所有定时器的精度）                             |

### 4. one-shot vs periodic

| 维度               | one-shot（`xAutoReload=pdFALSE`）                 | periodic（`xAutoReload=pdTRUE`）    |
| ------------------ | ------------------------------------------------- | ----------------------------------- |
| 到期后             | 清 ACTIVE，回到休眠，需再次 START                 | `prvReloadTimer` 自动重插下个到期点 |
| 回调内续期         | 必须 `xTimerStart(t, 0)` / `xTimerReset(t, 0)`    | 天然连续                            |
| 典型用途           | 超时看门狗、防抖、背光关闭                        | 周期采样、心跳、状态轮询            |
| "每 N ms 一次"语义 | 间隔 = N + 处理延迟 + 重启命令的队列延迟          | 按名义节拍记账、迟到补发（15.4 节） |
| 运行时可切换       | `vTimerSetReloadMode()` / `xTimerGetReloadMode()` | 同左                                |

注意 one-shot 的间隔误差比 periodic 大一截：每次触发都要走一遍"回调发 START 命令 → 入队 → 守护任务下一圈处理"的环路。要紧凑循环触发的场景应该用 periodic。

### 5. 精度模型：定时器精度 = tick 粒度 + 守护任务调度延迟

把一次回调的迟到拆开，来源只有四项，全部可估算：

```text
 实际触发时刻 - 名义到期时刻 = ①tick 粒度
                                + ②唤醒与调度延迟
                                + ③同循环里排在前面的其他回调
                                + ④守护任务优先级导致的排队
 ① tick 粒度：到期按整 tick 记账。IDF 默认 configTICK_RATE_HZ=100
    → 软件定时器分辨率 10ms，pdMS_TO_TICKS(15) 实际是 2 tick=20ms
 ② 唤醒：到期点在 tick 边界，vQueueWaitForMessageRestricted 到点唤醒
    （与 vTaskDelay 同源，第 9 章的唤醒路径）
 ③ 串行代价：所有回调共享一个执行流，前面的回调跑多久，后面的全推迟多久
 ④ 优先级：守护任务默认优先级 1（CONFIG_FREERTOS_TIMER_TASK_PRIORITY），
    任何 ≥1 优先级的任务就绪都能压住它
```

工程结论三条：**要更细的分辨率，提 tick 频率**（代价是更密的时钟中断）；**要更小的抖动，提守护任务优先级**（代价是抢占业务任务）；**要硬实时 µs 级，别用软件定时器**——用硬件定时器中断或 ESP-IDF 的 `esp_timer`（专门的高分辨率定时服务）。另外记住方向性：软件定时器**只会晚、不会早**（插入链表的到期时间严格在未来，判定用 `<=`），"至少不会提前触发"是可以依赖的保证。

---

## 15.6 Vanilla vs ESP-IDF：定时器任务的双核化

软件定时器逻辑本身与核数无关，但 IDF fork（`FreeRTOS-Kernel/`，v10.5.1 基线 + Espressif SMP 改造）在三处动了它：

| 主题                 | Vanilla FreeRTOS v10.5.1                                                | IDF FreeRTOS（v6.0.2 默认树）                                                                                                                            |
| -------------------- | ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 守护任务创建         | `xTaskCreate(prvTimerTask, ...)` / `xTaskCreateStatic(...)`             | `xTaskCreatePinnedToCore(..., configTIMER_SERVICE_TASK_CORE_AFFINITY)` / `xTaskCreateStaticPinnedToCore(...)`（`timers.c` 的 `xTimerCreateTimerTask()`） |
| 守护任务亲和性       | 概念不存在（单核）                                                      | `configTIMER_SERVICE_TASK_CORE_AFFINITY` 只允许 0x0、0x1 或 `tskNO_AFFINITY`，编译期 `#error` 检查；Kconfig 默认 **No affinity**                         |
| 定时器状态的并发保护 | `prvProcessTimerOrBlockTask` 用 `vTaskSuspendAll()`（挂起调度器即独占） | 换成 `prvENTER_CRITICAL_OR_SUSPEND_ALL(&xTimerLock)`；`timers.c` 有独立的 `portMUX_TYPE xTimerLock` 自旋锁                                               |
| 栈深单位             | `configTIMER_TASK_STACK_DEPTH` 以**字**计（典型值 128 = 512B）          | 以**字节**计（`CONFIG_FREERTOS_TIMER_TASK_STACK_DEPTH` 默认 2048B，范围 1536~32768）                                                                     |
| 其余默认值           | 任务名 "Tmr Svc"；优先级/队列深度为 FreeRTOSConfig 编译期常量           | 任务名同左；优先级/队列深度改在 menuconfig（默认 1 / 10）                                                                                                |

> [!tip] 为什么 IDF 要给定时器加自旋锁？
> Vanilla 里"挂起调度器"就能独占定时器状态，因为单核上没人能插进来。双核上不行：守护任务在 Core 1 改链表时，Core 0 上的任务可能正在调 `vTimerSetReloadMode()` / `pvTimerGetTimerID()`（这两个 API 在 IDF 里都包着 `taskENTER_CRITICAL(&xTimerLock)`）。所以 IDF 把"所有定时器"收敛到一把 `xTimerLock`（`idf_changes.md` 明确列为 SMP 细粒度锁之一）：活跃链表本身仍只许守护任务碰，锁只保护状态位与 ID 这类跨核共享字段。自旋锁的代价与实现是第 18 章的主题。
>
> 亲和性默认值（No affinity）也值得留意：守护任务不绑核，可迁到任一核跑，负载自适应但缓存局部性略差；若回调密集触碰某个核上的外设/缓存，可在 menuconfig 里把它钉到对应核。

另有一个源码层差异供对照阅读：ESP-IDF 组件目录下还有一棵实验性的上游 SMP 内核树 `FreeRTOS-Kernel-SMP/`（v11.x 基线，默认不编入），那份 `timers.c` 把 `xTimerGenericCommand()` 拆成了 `...FromTask()` / `...FromISR()` 两个函数。本系列正文以默认树为准，两树的定位在第 4 章与第 22 章展开。

---

## 15.7 实验：混合周期定时器与回调延迟观测

### 1. 实验设计

在 QEMU 里验证本章三个论断：**(a)** 软件定时器只晚不早，常态抖动为 tick 级；**(b)** 守护任务优先级不足时回调延迟暴涨，且周期定时器会"补课"；**(c)** 提高守护任务优先级后抖动收敛。方法：创建混合周期定时器（100ms 周期、330ms 周期、500ms one-shot 自续期），回调里用 `esp_timer_get_time()`（µs 级，不受 tick 粒度限制）对账名义到期时刻；另设一个可调优先级的忙任务制造负载。

### 2. 代码

```c
/* main/freertos-ch15.c —— 软件定时器实验 */
#include <stdio.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/timers.h"
#include "esp_timer.h"

#define TIMER_FAST_MS   100     /* 周期定时器 A */
#define TIMER_ODD_MS    330     /* 周期定时器 B（与 100ms 错相） */
#define TIMER_SHOT_MS   500     /* one-shot C，回调内自续期 */

typedef struct {
    int64_t  expect_us;         /* 名义到期时刻 */
    int64_t  period_us;
    uint32_t count;
    int64_t  lat_sum, lat_max;
    const char *name;
} lat_stat_t;

static lat_stat_t s_fast, s_odd, s_shot;

static void update_stats( lat_stat_t *st )
{
    int64_t lat = esp_timer_get_time() - st->expect_us;   /* 正=迟到 */
    st->count++;
    st->lat_sum += lat;
    if ( lat > st->lat_max ) st->lat_max = lat;

    if ( st->count % 20 == 0 ) {             /* 每 20 次汇报一行 */
        printf("[%-4s] n=%5"PRIu32" avg=%6lld us max=%8lld us\n",
               st->name, st->count,
               (long long)(st->lat_sum / st->count),
               (long long)st->lat_max);
    }
    st->expect_us += st->period_us;          /* 名义节拍自走：迟到的账不冲销 */
}

static void fast_cb( TimerHandle_t t ) { update_stats(&s_fast); (void)t; }
static void odd_cb ( TimerHandle_t t ) { update_stats(&s_odd);  (void)t; }

static void shot_cb( TimerHandle_t t )       /* one-shot：回调里自续期 */
{
    update_stats(&s_shot);
    xTimerStart(t, 0);                       /* 回调内 API：等待必须为 0 */
}

/* 负载任务：busy_ms 忙等 + 50ms 睡眠，占空比可调 */
static void hog_task( void *arg )
{
    int busy_ms = (int)arg;
    for (;;) {
        int64_t until = esp_timer_get_time() + busy_ms * 1000;
        while ( esp_timer_get_time() < until ) { }   /* 忙等 */
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

void app_main(void)
{
    printf("daemon prio = %d, tick = %d Hz\n",
           configTIMER_TASK_PRIORITY, configTICK_RATE_HZ);

    TimerHandle_t h_fast = xTimerCreate("fast100", pdMS_TO_TICKS(TIMER_FAST_MS),
                                        pdTRUE,  NULL, fast_cb);
    TimerHandle_t h_odd  = xTimerCreate("odd330",  pdMS_TO_TICKS(TIMER_ODD_MS),
                                        pdTRUE,  NULL, odd_cb);
    TimerHandle_t h_shot = xTimerCreate("shot500", pdMS_TO_TICKS(TIMER_SHOT_MS),
                                        pdFALSE, NULL, shot_cb);
    int64_t now = esp_timer_get_time();
    s_fast = (lat_stat_t){ .name="fast", .period_us=TIMER_FAST_MS*1000, .expect_us=now+TIMER_FAST_MS*1000 };
    s_odd  = (lat_stat_t){ .name="odd",  .period_us=TIMER_ODD_MS *1000, .expect_us=now+TIMER_ODD_MS *1000 };
    s_shot = (lat_stat_t){ .name="shot", .period_us=TIMER_SHOT_MS*1000, .expect_us=now+TIMER_SHOT_MS*1000 };
    xTimerStart(h_fast, 0); xTimerStart(h_odd, 0); xTimerStart(h_shot, 0);

    /* 阶段一：负载任务优先级 1（与守护任务同级，不压制它） */
    xTaskCreate(hog_task, "hog", 2048, (void *)40, 1, NULL);
}
```

编译运行：

```bash
cd ~/freertos-ch15 && idf.py qemu monitor
```

### 3. 阶段一输出与解读

```text
daemon prio = 1, tick = 100 Hz
[fast] n=   20 avg=  5210 us max=    11000 us
[odd ] n=   20 avg=  5430 us max=    12000 us
[shot] n=   20 avg=  7800 us max=    13000 us
...
```

平均延迟 5~8ms、峰值 1~2 个 tick（10~20ms）：正是 15.5 节精度模型的①+②项——tick 粒度主导、唤醒与调度贡献零头。one-shot 略差，因为它每次都要走"回调发 START → 入队 → 下一圈处理"的环路。所有延迟为正：**只晚不早**得到验证。

### 4. 阶段二：压住守护任务，观察补课

把负载任务提到优先级 3（高于守护任务的 1）、忙等加到 200ms：

```c
    xTaskCreate(hog_task, "hog", 2048, (void *)200, 3, NULL);
```

```text
daemon prio = 1, tick = 100 Hz
[fast] n=   20 avg= 61200 us max=   210000 us     ← 100ms 周期，平均迟到 61ms！
[odd ] n=   20 avg= 58000 us max=   220000 us
[shot] n=   20 avg= 90500 us max=   250000 us
```

平均延迟飙到 60~90ms——守护任务被优先级 3 的忙任务压住，定时器只能在忙任务 `vTaskDelay` 的 50ms 窗口里补跑。更有说服力的是补课现象：在回调里加一行打印相邻两次回调的真实间隔，会看到 100ms 定时器出现**几毫秒间隔的连续触发**（如 3ms、4ms）——那就是 `prvReloadTimer()` 的 while 循环在连发欠下的回调（15.4 节）。统计口径上 `expect_us` 按名义节拍自走，补发不会"洗白"延迟统计，迟到多少记多少。

### 5. 阶段三：提升守护任务优先级

不动代码，改配置后重新编译：

```bash
idf.py menuconfig
# Component config → FreeRTOS → Kernel → configTIMER_TASK_PRIORITY: 1 → 4
idf.py qemu monitor
```

同样的优先级 3 负载下，延迟回到 tick 级（avg ≈ 5ms）：守护任务醒来即可抢占负载任务。代价也当场可见——忙任务每让出一次就被掐走一次，吞吐下降。**优先级 1 的默认值是个"温和"选择：定时器让位于一切业务任务；要准，就得付抢占的价。**

### 6. 排坑表

| 症状                      | 原因                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------- |
| 定时器完全不触发          | 回调链上某个回调阻塞（15.5 节事故案例）；查 "Tmr Svc" 状态而非自己的定时器            |
| `xTimerStart` 返回 pdFAIL | 命令队列（默认深 10）被塞满——守护任务卡住，或短时间内命令暴增                         |
| `configASSERT` 周期为 0   | `xTimerCreate(..., 0, ...)` 非法；用 `pdMS_TO_TICKS` 换算后检查                       |
| 改了周期行为没变          | `xTimerChangePeriod` 传了非零等待且回调里调用导致命令没入队；或忘了它会顺带激活定时器 |

---

## 15.8 小结

- 软件定时器 = **一个守护任务（"Tmr Svc"，默认优先级 1）+ 一条命令队列（"TmrQ"，默认深 10）+ 两条按到期 tick 排序的活跃链表**。模块自身不占任何硬件定时器，计时完全复用 tick。
- 所有公共 API 都是 `xTimerGenericCommand()` 的宏包装：组一条 `DaemonTaskMessage_t` 入队而已；**起始时刻在发送端用 `xTaskGetTickCount()` 盖章**，使"命令排队延迟"可被检测并在处理时追赶。
- `Timer_t` 只是记账记录（名字、链表节点、周期、ID、回调、三位状态图），不是执行流；创建即休眠。两条活跃链表配合 `prvSwitchTimerLists()` 解决 tick 回绕，`prvInsertTimerInActiveList()` 的四象限判定决定插哪条链、是否立即过期。
- 守护任务主循环三步：看链表头取最近到期 → 到期就执行 / 未到期就 `vQueueWaitForMessageRestricted()` 双路等待 → 排干命令队列。周期定时器迟到时由 `prvReloadTimer()` 连发补课。
- 铁律：**回调运行在守护任务上下文，禁止任何阻塞**——一个回调卡住等于所有定时器、所有 pended function 一起停摆。重活外包给工作任务（任务通知是首选信使）。
- 精度 = tick 粒度 + 唤醒调度延迟 + 同循环前序回调 + 守护任务优先级排队；**只晚不早**是可依赖的保证。要分辨率提 tick 频率，要低抖动提 `configTIMER_TASK_PRIORITY`，要 µs 级硬实时用硬件定时器或 `esp_timer`。
- Vanilla vs IDF：守护任务改用 `xTaskCreatePinnedToCore()` + `configTIMER_SERVICE_TASK_CORE_AFFINITY`（默认不绑核）；定时器状态由独立自旋锁 `xTimerLock` 保护；栈深语义同任务一样按字节计。

下一章离开内核对象，进入端口层：`portmacro.h` 里每一个宏（`portYIELD`、`portENTER_CRITICAL`、`portTICK_TYPE`……）背后都站着一条具体的硬件事实。它是内核与 CPU 之间的契约文书，也是读懂后续上下文切换汇编与临界区实现（第 17、18 章）的入场券——见 [[2026-08-26-freertos-deep-dive-ch16-portmacro-port-contract|第十六章]]。
