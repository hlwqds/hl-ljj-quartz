---
title: "FreeRTOS 深度解析（九）：阻塞、超时与 Idle 任务"
date: 2026-08-26
description: "从 vTaskDelay 与 vTaskDelayUntil 的漂移差异讲到 xTaskIncrementTick 的解锁流水线、延迟链表双缓冲与 tick 溢出，最后解剖 Idle 任务的职责全集——并用任务看门狗实验演示饿死 Idle 的后果。"
tags: [freertos, rtos, esp32, esp-idf, qemu, tick, idle-task, watchdog]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 9. **第九章：阻塞、超时与 Idle 任务**

# FreeRTOS 深度解析（九）：阻塞、超时与 Idle 任务

前两章把"谁能上 CPU"讲完了：就绪链表、最高优先级选择、时间片轮转。这一章补上调度故事的另一半——**任务不在 CPU 上时，都去了哪里**。回答四个问题：阻塞态在内核里如何记账（`vTaskDelay` 系列把任务挂到了什么数据结构上）；tick 中断如何按时刻把到期任务"叫醒"（`xTaskIncrementTick` 的解锁流水线）；tick 计数溢出后延迟链表怎么办（双缓冲切换）；以及当所有任务都在睡时，CPU 在谁手里、它在干什么（Idle 任务，以及饿死它会怎样）。

本章源码参照 v6.0.2 默认编入的 `components/freertos/FreeRTOS-Kernel/`（IDF fork 本体，Vanilla v10.5.1 基线），对照时给出 Vanilla 原版行为。

---

## 9.1 阻塞态的记账：从 API 到延迟链表

### 1. 五个状态，两条"睡"路

`task.h` 的 `eTaskState` 枚举给出五个可观测状态，其中两个"不在运行也不就绪"：

| 状态       | 住处（`tasks.c` 内部链表）                    | 什么时候回来                       |
| ---------- | --------------------------------------------- | ---------------------------------- |
| eReady     | `pxReadyTasksLists[prio]`                     | 调度器选中它（第 6 章）            |
| eBlocked   | `pxDelayedTaskList`（+ 可能同时在某事件链表） | 到期被 tick 叫醒，或等的事件先发生 |
| eSuspended | `xSuspendedTaskList`                          | 只能被 `vTaskResume()` 手动救回    |
| eDeleted   | `xTasksWaitingTermination`                    | 永远不回来，等 Idle 释放内存       |

关键区别：**Blocked 是"有闹钟的睡"，Suspended 是"没有闹钟的睡"**。9.4 节会看到一个有趣的交叉点——`portMAX_DELAY` 参数决定任务进哪条链表。

### 2. vTaskDelay 源码走读

`vTaskDelay()` 是最短的阻塞 API，完整逻辑只有三步（`tasks.c` 的 `vTaskDelay()`）：

```c
void vTaskDelay( const TickType_t xTicksToDelay )
{
    BaseType_t xAlreadyYielded = pdFALSE;

    /* A delay time of zero just forces a reschedule. */
    if( xTicksToDelay > ( TickType_t ) 0U )
    {
        prvENTER_CRITICAL_OR_SUSPEND_ALL( &xKernelLock );
        {
            prvAddCurrentTaskToDelayedList( xTicksToDelay, pdFALSE );
        }
        xAlreadyYielded = prvEXIT_CRITICAL_OR_RESUME_ALL( &xKernelLock );
    }

    if( xAlreadyYielded == pdFALSE )
        portYIELD_WITHIN_API();      /* 把自己换下 CPU */
}
```

三个要点：

1. **`vTaskDelay(0)` 不是延时**，是"立刻让出 CPU"——手册明说这只是一个触发 reschedule 的技巧。想让出 CPU 给同优先级任务，这就是最便宜的写法。
2. 真正的工作全在 `prvAddCurrentTaskToDelayedList()` 里（下一小节）。注意第二个参数传的是 `pdFALSE`——它决定了 `portMAX_DELAY` 的语义，9.4 节展开。
3. Vanilla v10.5.1 的同名函数用的是 `vTaskSuspendAll()` / `xTaskResumeAll()` 保护临界区；IDF fork 换成了内核锁 `xKernelLock`（自旋锁）。这是 SMP 改造的标志性替换——单核关中断就够，双核必须锁总线级的锁（第 18 章主题）。

### 3. prvAddCurrentTaskToDelayedList：入账的每一步

`tasks.c` 的 `prvAddCurrentTaskToDelayedList()` 是**所有**阻塞 API 的公共出口——不管你调的是 `vTaskDelay`、`xQueueReceive` 还是 `xEventGroupWaitBits`，最终都从这里把当前任务挂进延迟链表。它做四件事：

```text
prvAddCurrentTaskToDelayedList(xTicksToWait, xCanBlockIndefinitely)
│
├─ 1. [SMP 特有] 若当前任务已被别的核 vTaskDelete()（进了待回收链表），
│       直接返回——别给死人设闹钟
│
├─ 2. 从就绪链表摘下自己（xStateListItem 是复用的：状态链表和延迟
│       链表共用同一个 ListItem，人只在一张床上）
│
├─ 3. 计算绝对唤醒时刻：xTimeToWake = xTickCount + xTicksToWait
│       写进 xStateListItem.xItemValue
│
└─ 4. 选链表插入：
        ├─ xTimeToWake < xTickCount（溢出！） → 插 pxOverflowDelayedTaskList
        └─ 否则                            → 插 pxDelayedTaskList（按唤醒
                                               时刻有序），若成为新的最早
                                               到期者，顺手刷新 xNextTaskUnblockTime
```

插入用的是 `vListInsert()`——**按 `xItemValue`（唤醒时刻）排序的插入**。这条有序性是 tick 解锁路径能做到 O(到期任务数) 的全部前提（9.3 节）。另外第 4 步对 `xNextTaskUnblockTime` 的维护（"我比之前记录的最早到期还早，就改记录"），让 tick 中断平时连链表头都不用看。

> [!note] 一个 TCB、两张床
> TCB 里有两个 ListItem：`xStateListItem` 挂状态链表（就绪/延迟/挂起/待回收），`xEventListItem` 挂事件链表（某队列的等待链表）。**阻塞在内核对象上等待超时的任务同时占用两张床**：人在事件链表上排队，闹钟记在延迟链表上。谁先到就由谁把它从另一张床上也叫起来——这正是 9.3 节"解锁路径"里那段事件链表摘除代码的由来。TCB 结构详见[[ch5-task-lifecycle-and-tcb|第五章]]。

---

## 9.2 vTaskDelay vs xTaskDelayUntil：相对与绝对周期

两个 API 只差几个字母，语义却差一个维度：**`vTaskDelay` 锚定"现在"，`xTaskDelayUntil` 锚定"上次的唤醒时刻"**。周期性任务选错 API，周期的稳定性就没了。

### 1. 漂移从哪来：图解

`vTaskDelay(N)` 保证的是"从调用时刻起再睡 N"，但任务醒来 → 干活 → 再睡的循环里，**干活时间是净增项**：

```text
vTaskDelay(20)：周期 = 20 + 每轮执行耗时（相对锚点，必然漂移）

  tick:  0         25         50         75        100  →  实际唤醒时刻
  任务:  醒────────── 醒────────── 醒────────── 醒
         │干5tick活  │ │干5tick活   │ │干5tick活   │
         └───睡20────┘ └───睡20─────┘ └───睡20─────┘
  期望:  0         20         40         60         80  ← 每轮晚 5 tick，累积漂移

xTaskDelayUntil(&last, 20)：唤醒时刻 = last + 20（绝对锚点，不漂）

  tick:  0         20         40         60         80  →  实际唤醒时刻
  任务:  醒────────── 醒────────── 醒────────── 醒
         │干5+睡15   │ │干5+睡15    │ │干5+睡15    │
  锚点:  0         20         40         60         80  ← 钉在栅格上，误差不累积
         （若某轮干活超过 20 tick：锚点已过 → 本轮不睡直接返回，
           错过的周期作废，下一轮照常锚在 last + 20 —— 栅格不乱）
```

- **`vTaskDelay` 的漂移是单向累积的**：每轮周期 = 睡眠 + 执行 + 被抢占，误差只加不减。采样率 100Hz 的传感器任务这么写，实际可能是 87Hz。
- **`xTaskDelayUntil` 的锚点不漂**，但如果某轮执行超时（醒来到调用 `xTaskDelayUntil` 之间超过了周期），**当前这轮不睡直接返回**（错过的截止期不可能追回，但栅格不乱），下一轮照常锚在 `last + 2×20`。它的返回值就是告诉这件事的：返回 `pdTRUE` 表示真的睡了，`pdFALSE` 表示截止期已错过。

### 2. 源码语义：绝对锚点怎么算

`tasks.c` 的 `xTaskDelayUntil()` 核心只有一段（去掉 SMP 锁与断言）：

```c
BaseType_t xTaskDelayUntil( TickType_t * const pxPreviousWakeTime,
                            const TickType_t xTimeIncrement )
{
    TickType_t xTimeToWake;
    BaseType_t xShouldDelay = pdFALSE;

    xTimeToWake = *pxPreviousWakeTime + xTimeIncrement;   /* 绝对锚点 */

    if( xConstTickCount < *pxPreviousWakeTime ) {
        /* tick 已回绕：仅当唤醒时刻也回绕且在当前 tick 之后才睡 */
        if( ( xTimeToWake < *pxPreviousWakeTime ) && ( xTimeToWake > xConstTickCount ) )
            xShouldDelay = pdTRUE;
    } else {
        /* 未回绕：唤醒时刻回绕，或晚于当前 tick，才睡 */
        if( ( xTimeToWake < *pxPreviousWakeTime ) || ( xTimeToWake > xConstTickCount ) )
            xShouldDelay = pdTRUE;
    }
    *pxPreviousWakeTime = xTimeToWake;    /* 无论如何先推进锚点！ */
    if( xShouldDelay != pdFALSE )
        prvAddCurrentTaskToDelayedList( xTimeToWake - xConstTickCount, pdFALSE );

    return xShouldDelay;
}
```

两个容易忽略的细节：

1. **`*pxPreviousWakeTime` 无条件推进**——即使这轮没睡（错过截止期），锚点也已前移。这就是"栅格不乱"的实现：错过的周期作废，不补偿、不累积。
2. **入账时减回相对量**：`prvAddCurrentTaskToDelayedList()` 的入参是"还要睡多久"（`xTimeToWake - xConstTickCount`），函数内部又会加回 tick 得到绝对时刻。API 层面用绝对时刻思考，链表面层用相对量记账，各取所需。

标准的周期任务模板（`task.h` 文档同款）：

```c
void vPeriodicTask( void * pvParameters )
{
    TickType_t xLastWakeTime = xTaskGetTickCount();   /* 首次初始化 */
    const TickType_t xFrequency = pdMS_TO_TICKS( 200 );

    for( ;; )
    {
        do_something();                               /* 干活 */
        xTaskDelayUntil( &xLastWakeTime, xFrequency );/* 睡到下个栅格 */
    }
}
```

`vTaskDelayUntil()` 是兼容旧版的宏，内部调 `xTaskDelayUntil()` 后丢弃返回值——新代码直接用带返回值的版本，用它做截止期监测。

> [!tip] Vanilla vs ESP-IDF：延迟 API 本体无差异，保护方式不同
> 两个 API 的语义在 Vanilla v10.5.1 与 IDF fork 里完全一致（差异在临界区实现：Vanilla 用 `vTaskSuspendAll()`，IDF 用内核锁）。真正要注意的是**移植层差异**：tick 频率默认值。Vanilla 移植模板常用 1000Hz，IDF 默认 `CONFIG_FREERTOS_HZ=100`（1 tick = 10ms）——`pdMS_TO_TICKS(5)` 在 IDF 里会截断成 0 tick，等于"立刻让出"。周期小于 10ms 的任务要么调高 tick 频率，要么换硬件定时器。

### 3. 实验：亲眼看到漂移

两个周期任务，同样的 200ms 周期、同样的 30ms"工作"，只是一个用 `vTaskDelay`、一个用 `xTaskDelayUntil`。用 `esp_timer_get_time()` 打印每轮醒来的绝对时刻：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_timer.h"

static void busy_work_30ms( void )            /* 约 30ms 的纯计算忙等，模拟“干活” */
{
    uint64_t until = esp_timer_get_time() + 30 * 1000;
    while( esp_timer_get_time() < until ) { }
}

static void drift_task( void *arg )          /* 相对延时版 */
{
    for( ;; ) {
        printf( "[delay ] wake @ %lld ms\n", esp_timer_get_time() / 1000 );
        busy_work_30ms();
        vTaskDelay( pdMS_TO_TICKS( 200 ) );
    }
}

static void anchor_task( void *arg )          /* 绝对锚点版 */
{
    TickType_t last = xTaskGetTickCount();
    for( ;; ) {
        printf( "[until ] wake @ %lld ms\n", esp_timer_get_time() / 1000 );
        busy_work_30ms();
        xTaskDelayUntil( &last, pdMS_TO_TICKS( 200 ) );
    }
}

void app_main( void )
{
    xTaskCreatePinnedToCore( drift_task,  "drift",  2048, NULL, 4, NULL, 0 );
    xTaskCreatePinnedToCore( anchor_task, "anchor", 2048, NULL, 4, NULL, 1 );
}
```

`idf.py qemu monitor` 跑约 10 个周期（输出截取）：

```text
[delay ] wake @ 242 ms
[until ] wake @ 245 ms
[delay ] wake @ 473 ms
[until ] wake @ 445 ms
...
[delay ] wake @ 2559 ms        ← 第 10 轮：晚了约 460 ms
[until ] wake @ 2245 ms        ← 第 10 轮：仍钉在 200ms 栅格上
```

`delay` 版每轮实际间隔 ≈ 230ms（200 睡眠 + 30 工作），漂移线性累积；`until` 版唤醒时刻始终落在 200ms 的整数倍栅格上（±1 tick 抖动来自 tick 粒度，10ms 一格）。要周期稳定，**周期任务一律 `xTaskDelayUntil`**；要"歇一会儿再说"（退避、消抖），用 `vTaskDelay`。

---

## 9.3 xTaskIncrementTick：tick 中断里的解锁流水线

延迟链表是账本，tick 中断是查账的。每 10ms（默认 100Hz），`port_systick.c` 的 `xPortSysTickHandler()` 被定时器中断调用，它调 `tasks.c` 的 `xTaskIncrementTick()`——整个"到点叫醒"机制都在这个函数里。

### 1. 主路径：一次 tick 的完整流水线

`xTaskIncrementTick()` 做的事按序是（省略 SMP 锁与 trace 钩子）：

```text
xTaskIncrementTick()  [仅 Core 0 执行，函数入口有 configASSERT 检查]
│
├─ 1. xTickCount++；若回绕到 0 → taskSWITCH_DELAYED_LISTS()（9.4 节）
│
├─ 2. 快速检查：xTickCount >= xNextTaskUnblockTime ?
│      └─ 否 → 跳过整个解锁扫描（绝大多数 tick 走这里，O(1)）
│
├─ 3. 是 → 沿 pxDelayedTaskList 从头遍历：
│      ├─ 链表头的 xItemValue（唤醒时刻）> 当前 tick
│      │     → 更新 xNextTaskUnblockTime = 头部时刻，停止扫描
│      └─ 头部任务到期：
│            ├─ 从延迟链表摘除 xStateListItem
│            ├─ 若 xEventListItem 还挂在某事件链表上 → 也摘掉
│            │    （这是"队列等待超时"路径：超时和事件二选一先到）
│            └─ prvAddTaskToReadyList() 移入就绪链表
│
├─ 4. [SMP] 每唤醒一个任务，重算两个核的抢占需求：
│      ├─ 能在 Core 0 跑且优先级 > pxCurrentTCBs[0] → 本核 xSwitchRequired
│      ├─ 任务无亲和(xCoreID==tskNO_AFFINITY) 且优先级 > Core 1 当前
│      │     → xYieldPending[1] = pdTRUE（给对核留切换请求）
│      └─ 任务钉在 Core 1 且优先级 > Core 1 当前 → xYieldPending[1]
│
├─ 5. 时间片检查：Core 0 当前优先级的就绪链表长度 > 1 → xSwitchRequired
│      （第 8 章的 Best-Effort Round-Robin 在此驱动）
│
├─ 6. 调 vApplicationTickHook()（若开启）
└─ 返回 xSwitchRequired → 端口层据此 portYIELD_FROM_ISR()
```

第 2 步是性能关键：`xNextTaskUnblockTime` 记着"下一个要醒的任务时刻"，平时 tick 只做一次比较就完事；只有真有任务到期才进扫描，而有序链表保证扫描在第一个未到期任务处停下。**整个解锁机制的复杂度与"本 tick 到期的任务数"成正比，与系统总任务数无关**——几百个任务沉睡的系统，tick 开销照样是微秒级。

第 3 步中"事件链表摘除"值得多看一眼：任务阻塞在 `xQueueReceive(q, &buf, 100)` 上时，它在队列的等待链表和延迟链表各占一床。数据先到（ISR 里 `xQueueSendFromISR`）→ 从两床同时叫走；超时先到（本路径）→ 也是两床同时叫走，返回 `errQUEUE_TIMEOUT`。两条路径互斥，由内核锁/临界区保证不双叫。这套"状态床 + 事件床"的协作是第 10 章队列源码的主戏。

第 4 步是纯 SMP 新增：单核 Vanilla 只需比较"唤醒任务 vs 当前任务"一个优先级；双核必须分别评估两个核，且 Core 0 不能直接替 Core 1 做切换——只能置 `xYieldPending[1]`，等 Core 1 下次检查时自己切。

### 2. 双核分工：Core 0 记账，Core 1 只看表

tick 中断在两个核上**都会**触发（`port_systick.c` 用 SYSTIMER 的两个独立 alarm，源码注释明言两核的 SysTick "shifted by half of period"——刻意错开半个周期），但进内核后各干各的活：

```text
                 xPortSysTickHandler()  [port_systick.c]
                    │
        ┌───────────┴────────────┐
   Core 0 的 tick            Core 1 的 tick
        │                          │
  xTaskIncrementTick()     xTaskIncrementTickOtherCores()
        │                  [esp_additions/freertos_tasks_c_additions.h]
  ├─ xTickCount++                 │
  ├─ 溢出时切换延迟链表        ├─ （不碰 tick 计数、不解锁任务）
  ├─ 解锁到期任务             ├─ 时间片检查：本核当前优先级的
  ├─ Core 0 抢占判定          │   就绪链表 > 1 → 请求切换
  ├─ 给 Core 1 留 xYieldPending├─ 检查 xYieldPending[1]
  ├─ 时间片检查               └─ vApplicationTickHook()
  └─ vApplicationTickHook()
```

对照第 8 章的结论：**计时、解锁、时间片，全局只有一个真相源（Core 0 的 `xTaskIncrementTick`）；Core 1 的 tick 只服务于本核的时间片与 hook**。`xTaskIncrementTickOtherCores()` 的入口断言 `xCoreID != 0`，写反了直接 assert。

> [!tip] Vanilla vs ESP-IDF：tick 职责的分裂
> | 维度 | Vanilla（单核假设） | IDF fork（双核） |
> | --- | --- | --- |
> | tick 计数与解锁 | 唯一 CPU 全权处理 | 仅 Core 0（`xTaskIncrementTick`） |
> | 其他核的 tick | 不存在 | `xTaskIncrementTickOtherCores()`：只查时间片和 yield 标志 |
> | 解锁任务的抢占判定 | 与当前任务比一次 | 逐核评估，可置对核 `xYieldPending` |
> | tick 中断保护 | 调用前关中断（不可嵌套） | 内核锁 `xKernelLock`（自旋锁） |
> | tick 源 | 端口自带（如 Cortex-M 的 SysTick） | `port_systick.c` 统一接 SYSTIMER/CCOUNT |
>
> 记住这个分工会让 9.6 节的看门狗实验输出更容易读：两个核的 Idle 是独立的任务，饿死哪一个、哪一个是正常的，一眼可辨。

---

## 9.4 延迟链表双缓冲与 tick 溢出

`xTimeToWake = xTickCount + xTicksToWait` 是无符号加法，早晚回绕。32 位 tick、100Hz 下，`xTickCount` 从 0 数到 `0xFFFFFFFF` 需要约 **497 天**——听起来遥远，但电表、网关这类常年不断电的设备真的会碰到；16 位 tick（`configUSE_16_BIT_TICKS=1` 的资源受限端口）下只要 **655 秒**。内核必须正确处理"唤醒时刻已回绕"的任务。（tick 宽度在 v10.5.1 里只有 16/32 位两档；上游 v11 起新增 `configTICK_TYPE_WIDTH_IN_BITS`，可配 64 位 tick——IDF 的实验性上游 SMP 内核树有这个选项，默认 fork 树没有。）

### 1. 为什么需要两条链表

延迟链表按唤醒时刻升序排列，依赖"`xItemValue` 越小越早到期"这一比较。tick 回绕后这个比较**失效**：`0x0000_0005`（刚回绕，5 tick 后）其实比 `0xFFFF_FFF0`（回绕前）更早到期，但数值上更小——有序性还在，"头部的下一个到期"却不再成立，tick 中断的快速检查会全部算错。

解法是把时间轴折叠成两段，各放一条链表：

```text
                         时间轴（32 位 tick 回绕）
   …────┬─────────────────────────────┬─────────────────────┬────…
        0                        回绕点(wrap)              2^32-1
        │◄──── 段 A：未回绕唤醒时刻 ────►│◄── 段 B：已回绕时刻 ──►│

  正常期（xTickCount = 0x100，未回绕）：
  ┌────────────────────────┐   ┌───────────────────────────┐
  │ pxDelayedTaskList  ───►│   │ pxOverflowDelayedTaskList►│
  │ 唤醒时刻 ∈ [0x100,wrap) │   │ 唤醒时刻 ∈ [0, 0x100)      │
  │ 按数值升序 = 按时间升序 ✓│   │ （当前周期的"下辈子"任务）   │
  └────────────────────────┘   └───────────────────────────┘
        ▲ 新任务 xTimeToWake ≥ 当前 tick → 入此表
                                 ▲ 新任务 xTimeToWake < 当前 tick（回绕了）→ 入此表

  回绕瞬间（xTickCount 变 0）→ taskSWITCH_DELAYED_LISTS()：
  ┌────────────────────────┐   ┌───────────────────────────┐
  │ pxDelayedTaskList  ───►│◄──┼─ 两指针交换（原溢出表转正）   │
  │ 原溢出表：唤醒时刻∈[0,..) │   │ 原正常表此刻必为空           │
  └────────────────────────┘   └───────────────────────────┘
```

判据来自 `prvAddCurrentTaskToDelayedList()`：无符号加法 `xTickCount + xTicksToWait` 回绕时结果必然**小于** `xTickCount`，据此进溢出表。`taskSWITCH_DELAYED_LISTS()` 宏做的事：断言当前表已空（到期任务全被解锁了才可能回绕）、交换两个指针、`xNumOfOverflows++`、重算 `xNextTaskUnblockTime`。

两指针（`pxDelayedTaskList` / `pxOverflowDelayedTaskList`）指向两条实体链表（`xDelayedTaskList1` / `xDelayedTaskList2`），交换的只是指针——O(1)，这就是"双缓冲"的含义：**不是搬运任务，而是交换两个缓冲区的身份**。

### 2. 回绕时的边角：xTaskDelayUntil 自己会算

绝对锚点 API 天然跨越回绕点：`xTimeToWake = last + 200` 在 `last` 接近 `0xFFFF_FFFF` 时会回绕，9.2 节源码里那两段"回绕判定"（tick 回绕了而唤醒时刻没回绕 → 不睡，因为那是上辈子的时刻；两者都回绕且唤醒时刻在前 → 睡）就是在处理这种边角。所以周期任务跑在回绕点附近也不会错乱——`uxTaskGetSystemState()` 的遍历也同时扫两条延迟链表（`eBlocked` 状态两段都算）。

### 3. portMAX_DELAY：一个值、两种命运

`portMAX_DELAY` 在 Xtensa 端口（`portmacro.h`，`configUSE_16_BIT_TICKS=0`）是 `0xFFFFFFFF`。把它传给不同 API，行为完全不同：

| 调用方式                                  | 实际行为                                                   | 原因                                                                                                                                       |
| ----------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `vTaskDelay( portMAX_DELAY )`             | 睡 2^32-1 个 tick（IDF 默认 100Hz ≈ **497 天**），到期会醒 | `vTaskDelay` 调 `prvAddCurrentTaskToDelayedList(x, pdFALSE)`，`xCanBlockIndefinitely` 为假，走延迟链表                                     |
| `xQueueReceive( q, &buf, portMAX_DELAY )` | **真正无限等待**，永不超时                                 | 队列等待路径传 `pdTRUE`，命中 `xTicksToWait == portMAX_DELAY && xCanBlockIndefinitely` 分支 → 任务进 `xSuspendedTaskList`，tick 根本不扫它 |

实现就藏在 `prvAddCurrentTaskToDelayedList()` 开头的一段 `#if ( INCLUDE_vTaskSuspend == 1 )`：无限等待在数据结构层面被实现为"挂起"——不占延迟链表的床，`xNextTaskUnblockTime` 也不必为它操心。`eTaskGetState()` 因此把"无限超时阻塞"报告为 `eSuspended`（`task.h` 枚举注释明说：infinite time out 算 Suspended）。

> [!note] 别用 vTaskDelay(portMAX_DELAY) 表示"永远睡"
> 想让任务永久休眠等通知，用 `ulTaskNotifyTake(..., portMAX_DELAY)` 或任意带超时内核对象的 `portMAX_DELAY`（第 13 章的任务通知是最轻的）；`vTaskDelay(portMAX_DELAY)` 只是"睡 497 天"，而且占着延迟链表。反向提醒：`configUSE_16_BIT_TICKS=1` 的小端口上 `portMAX_DELAY` 只有 65535 tick，`vTaskDelay(portMAX_DELAY)` 十分钟就醒了——移植代码时这是经典坑。

---

## 9.5 Idle 任务：优先级 0 的清道夫

所有任务都可能睡，调度器却必须永远有任务可跑——否则"选最高优先级就绪任务"无从选起。Idle 任务就是那个保底：优先级 0（`tskIDLE_PRIORITY`），调度器启动时自动创建，永不删除。它不只是"空转"，而是内核的家务员。

### 1. 职责清单：Idle 循环的每一圈

`tasks.c` 的 `prvIdleTask()` 是一个 `for(;;)` 循环，每圈依次（按编译配置裁剪）：

| 序  | 职责                          | 代码入口                            | 说明                                                                                                           |
| --- | ----------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 1   | **回收已删除任务**            | `prvCheckTasksWaitingTermination()` | 见下小节，最重要的家务                                                                                         |
| 2   | 无抢占时强制让出              | `taskYIELD()`                       | 仅 `configUSE_PREEMPTION==0` 的协作模式                                                                        |
| 3   | 让给同优先级任务              | `taskYIELD()`（若就绪表 >1）        | 仅 `configIDLE_SHOULD_YIELD==1`；**IDF 配置为 0**（见下）                                                      |
| 4   | 应用 idle hook                | `vApplicationIdleHook()`            | `configUSE_IDLE_HOOK==1` 时；**禁止阻塞**                                                                      |
| 5   | IDF idle hook 链 + 低功耗等待 | `esp_vApplicationIdleHook()`        | IDF 无条件编入：跑 `esp_register_idle_hook()` 注册的回调，最后 `esp_cpu_wait_for_intr()`（WAITI 指令，降功耗） |
| 6   | tickless 睡眠                 | `portSUPPRESS_TICKS_AND_SLEEP()`    | 仅 `configUSE_TICKLESS_IDLE!=0`；见下                                                                          |

第 5 条是 IDF 的私货：Vanilla 的 `vApplicationIdleHook` 是单个弱符号函数，IDF 在它之外又挂了一条**每核最多 8 个回调**的 hook 链（`esp_register_freertos_idle_hook()` 注册，回调返回 `false` 可阻止休眠），链尾执行 `esp_cpu_wait_for_intr()`——Xtensa 的 `WAITI` 指令让核进入等中断的低功耗状态。9.6 节的任务看门狗喂狗回调就挂在这条链上。

第 3 条值得注意：IDF 的 `FreeRTOSConfig.h` 把 `configIDLE_SHOULD_YIELD` 硬编码为 0（Vanilla 的推荐默认是 1）。效果上的差异：Vanilla 的 Idle 看到 idle 优先级就绪链表里还有别的任务，会在时间片结束前**主动**让出；IDF 的 Idle 不主动让，idle 优先级任务与 Idle 的分时完全交给第 8 章的时间片机制（tick 到点、就绪链表长度 >1 → 请求切换）。对应用层的含义是一样的——**别把任务放在优先级 0 和 Idle 抢时间**：那条链表里所有人加起来才分到一个核的周期性时间片。

第 6 条 tickless 是可选的低功耗机制：Idle 先用 `prvGetExpectedIdleTime()` 估算"距离下一个任务到期还有多久"（= `xNextTaskUnblockTime - xTickCount`，若有更高优先级任务就绪则返回 0），超过阈值（`configEXPECTED_IDLE_TIME_BEFORE_SLEEP`）才挂起调度器、停掉 tick、进深度睡眠，醒来后用 `vTaskStepTick()` 一次性补账 tick。ESP-IDF 里它由电源管理组件（`esp_pm`）接管，本章不展开，记住入口在 Idle 即可。

### 2. 家务员的核心工作：回收已删除任务

`vTaskDelete(NULL)`（任务删自己）为什么不能当场释放自己的栈和 TCB？因为**释放的内存里正躺着当前任务的上下文**——`vPortFree` 一返回，执行流脚下就是废墟。所以删除自己的任务只是"登记死亡"：

```text
vTaskDelete(pxTCB)  [tasks.c]
│
├─ 目标任务正在运行（自己删自己，或删另一个核上正在跑的任务）
│    ├─ vListInsertEnd( &xTasksWaitingTermination, &pxTCB->xStateListItem )
│    ├─ ++uxDeletedTasksWaitingCleanUp          ← 给 Idle 留的字条
│    ├─ [跨核删除] taskYIELD_CORE( 对核 )        ← 让对核把它换下去
│    └─ 触发调度（自己已不在就绪表中）
│
└─ 目标任务不在运行 → 当场 prvDeleteTCB()（释放 TCB+栈），无需等 Idle
```

之后 Idle 每圈开头调 `prvCheckTasksWaitingTermination()`：只要 `uxDeletedTasksWaitingCleanUp > 0`，就在 `xTasksWaitingTermination` 链表上找可以释放的任务。**IDF 的 SMP 版本多一层小心**：逐个检查候选任务是否仍在某个核上运行（`taskIS_CURRENTLY_RUNNING`），还在跑就跳过找下一个——因为另一个核可能刚通过跨核 `vTaskDelete` 把它登记进来，而它还没真正被换下 CPU。找到安全的就摘链、`prvDeleteTCB()` 释放。Vanilla 单核版没有这层检查，直接取链表头。

这解释了一个经典现象：**频繁创建/删除任务的应用，内存回收的节奏由 Idle 的运行频率决定**。Idle 被饿死（9.6 节），不只是 CPU 占比难看——已删除任务的 TCB 和栈会堆积，堆悄悄被吃掉。

### 3. Vanilla 单 Idle vs IDF 双 Idle

Vanilla 的 Idle 是全局唯一：`xIdleTaskHandle` 是单变量，名字 `configIDLE_TASK_NAME`（默认 `"IDLE"`）——单核世界里"唯一"和"每核一个"是同一件事。IDF fork 把它按核实例化：

| 维度         | Vanilla v10.5.1                            | IDF FreeRTOS（v6.0.2 默认树）                                                       |
| ------------ | ------------------------------------------ | ----------------------------------------------------------------------------------- |
| 实例数       | 1 个（单核假设）                           | `configNUMBER_OF_CORES` 个，ESP32 上 2 个                                           |
| 句柄存储     | `TaskHandle_t xIdleTaskHandle`（单变量）   | `xIdleTaskHandle[ configNUMBER_OF_CORES ]`（数组）                                  |
| 任务名       | `"IDLE"`                                   | `"IDLE0"` / `"IDLE1"`（`configIDLE_TASK_NAME` + 核号，`prvCreateIdleTasks()` 拼接） |
| 亲和性       | 不适用                                     | `xTaskCreateStaticPinnedToCore(..., xCoreID)` **硬钉在各自核上**                    |
| 静态内存来源 | 应用提供 `vApplicationGetIdleTaskMemory()` | `port_common.c` 提供实现：从 FreeRTOS 堆 `pvPortMalloc` 分配（每核各一份）          |
| Idle 栈大小  | `configMINIMAL_STACK_SIZE`（**字**）       | `CONFIG_FREERTOS_IDLE_TASK_STACKSIZE`（默认 1536 **字节**）+ 栈开销                 |
| 内存回收     | 取待回收链表头直接释放                     | 逐项检查"是否还在某核上运行"再释放                                                  |
| 低功耗       | `portSUPPRESS_TICKS_AND_SLEEP`（可选）     | hook 链尾 `esp_cpu_wait_for_intr()`（WAITI）+ 可选 tickless/esp_pm                  |
| 获取句柄     | `xTaskGetIdleTaskHandle()`                 | `xTaskGetIdleTaskHandleForCore(xCoreID)`（无参版返回当前核的）                      |

顺带一提栈单位差异的根：Xtensa 端口的 `portmacro.h` 里 `portSTACK_TYPE` 是 `uint8_t`——`StackType_t` 就是字节，所以 `xTaskCreate` 的栈深参数天然按字节计（[[ch16-portmacro-port-contract|第十六章]]展开端口类型契约）。

每核一个 Idle 的动机在[[ch22-smp-refactor-overview|第二十二章]]有系统论述，这里给直观版：调度器是每核独立选任务的，若只有一个 Idle 且它恰好在 Core 0 的就绪表里，Core 1 空转时将无任务可选——要么让 Idle 可迁移并接受核间弹跳的开销，要么每核配一个保底。IDF 选了后者，代价是每核约 1.5KB 栈 + 一个 TCB 的常驻内存。

---

## 9.6 饿死 Idle：任务看门狗实验

"Idle 只是保底"不等于它可以被牺牲。ESP-IDF 默认给两个核的 Idle 都戴了**任务看门狗（TWDT）**，Idle 拿不到运行时间，看门狗就咬。这个实验把它演示出来，再用 `uxTaskGetSystemState()` 量化 Idle 的 CPU 占比。

### 1. TWDT 为什么盯 Idle

设计逻辑写在 `esp_system` 的 Kconfig 帮助文本里：Idle 得不到运行通常是 **CPU 饿死**的症状，而 FreeRTOS 的家务（9.5 节的内存回收）依赖 Idle 定期运行。机制（`components/esp_system/task_wdt.c`）：

```text
启动时 subscribe_idle()：
  esp_task_wdt_add( xTaskGetIdleTaskHandleForCore(core) )   ← Idle 进监视名单
  esp_register_freertos_idle_hook_for_cpu( idle_hook_cb )   ← 喂狗回调挂上 hook 链

Idle 每跑一圈 → esp_vApplicationIdleHook() → idle_hook_cb() → esp_task_wdt_reset()  ← 喂狗

超时（CONFIG_ESP_TASK_WDT_TIMEOUT_S，默认 5s）没喂 → task_wdt_isr()：
  打印未喂狗名单 + 各核当前正在运行的任务 → （默认）仅打印告警，不重启
```

默认配置（`idf.py menuconfig` → Component config → ESP Task Watchdog）：`CONFIG_ESP_TASK_WDT_INIT=y`、`ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0=y`、`ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1=y`、超时 5 秒、`ESP_TASK_WDT_PANIC=n`（只打印不崩溃；开启 PANIC 则触发 panic handler 重启）。

注意 TWDT 与中断看门狗（INT_WDT）是两回事：前者监视**任务**（本质是"Idle 有没有跑"），后者监视**中断是否霸占 CPU**。本实验触发的是前者。

### 2. 实验：饿死 Core 0 的 Idle

一个钉在 Core 0 的高优先级任务忙等，IDLE0 从此没有运行机会：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static void hog_task( void *arg )
{
    for( ;; ) { }                 /* 忙等：不让出 CPU，也不睡眠 */
}

void app_main( void )
{
    xTaskCreatePinnedToCore( hog_task, "hog", 2048, NULL, 5, NULL, 0 );
    /* app_main 返回后 main 任务自删 —— 也等着 IDLE0 收尸，但它等不到了 */
}
```

`idf.py qemu monitor`，约 5 秒后（输出截取，时间戳因环境而异）：

```text
E (5312) task_wdt: Task watchdog got triggered. The following tasks/users did not reset the watchdog in time:
E (5312) task_wdt:  - IDLE0 (CPU 0)
E (5312) task_wdt: Tasks currently running:
E (5312) task_wdt: CPU 0: hog
E (5312) task_wdt: CPU 1: IDLE1
```

每 5 秒重复一次告警（PANIC 未开）。三处可读的信息：

1. **`- IDLE0 (CPU 0)`**：没喂狗的是 Core 0 的 Idle；`IDLE1` 不在名单里——Core 1 的 Idle 正常运行，正常喂狗。每核独立 Idle（9.5 节）在这里直接可观察。
2. **`CPU 0: hog`**：Core 0 此刻正在跑的就是肇事者。这行是排查饿死问题的钥匙——看门狗不仅报"谁饿了"，还报"谁在吃"。
3. **另一个隐形后果**：`app_main` 返回后 main 任务自删，尸体躺在 `xTasksWaitingTermination` 里等 IDLE0 回收——而 IDLE0 永远不会运行。删除堆积 + 栈不释放，内存缓慢泄漏。这正是把 Idle 纳入看门狗监视的理由。

修复方向（按优雅度排序）：忙等改为阻塞等待（事件/队列/通知，第 10~13 章）；必须轮询则周期性 `vTaskDelay(1)` 让出；短期无法改的代码，用 `esp_task_wdt_delete(xTaskGetIdleTaskHandleForCore(0))` 摘掉该核 Idle 的监视（治标，最后的手段）。第 24 章会把"看门狗触发后的系统化排查"作为调试专题展开。

### 3. 实验：uxTaskGetSystemState 量化 Idle 占比

告警是定性的，`uxTaskGetSystemState()` 给定量答案：每个任务的运行时间计数。先打开运行时统计（`idf.py menuconfig` → Component config → FreeRTOS）：

```text
[*] Enable FreeRTOS to collect run time stats   (CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS)
    时钟源选默认 ESP Timer（esp_timer_get_time()，微秒精度）
```

该选项会自动选中 `configUSE_TRACE_FACILITY`（`uxTaskGetSystemState` 的前提）与格式化函数。`uxTaskGetSystemState()` 拿原始数据自己算（`task.h` 文档推荐生产代码这么用）；`vTaskGetRunTimeStats()` 是它之上的格式化封装，一行一任务直接打印，快速排查时更顺手。写一个监控任务，两次采样求差算占比：

```c
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define MAX_TASKS 12

static void stats_task( void *arg )
{
    static TaskStatus_t prev_stat[MAX_TASKS], cur_stat[MAX_TASKS];
    static configRUN_TIME_COUNTER_TYPE prev_total, cur_total;
    static UBaseType_t prev_n;

    prev_n = uxTaskGetSystemState( prev_stat, MAX_TASKS, &prev_total );  /* 基准快照 */

    for( ;; )
    {
        vTaskDelay( pdMS_TO_TICKS( 5000 ) );                 /* 采样窗口 5s */

        UBaseType_t cur_n = uxTaskGetSystemState( cur_stat, MAX_TASKS, &cur_total );
        unsigned long long dtotal = cur_total - prev_total;

        printf( "\n==== CPU share over window (%%, x2 cores) ====\n" );
        for( UBaseType_t i = 0; i < cur_n; i++ )
        {
            unsigned long long drt = 0;
            for( UBaseType_t j = 0; j < prev_n; j++ )        /* 按句柄对齐两次快照 */
                if( prev_stat[j].xHandle == cur_stat[i].xHandle )
                    { drt = cur_stat[i].ulRunTimeCounter - prev_stat[j].ulRunTimeCounter; break; }
            printf( "%-10s prio=%2lu state=%d  %5llu.%02llu%%\n",
                    cur_stat[i].pcTaskName,
                    (unsigned long)cur_stat[i].uxCurrentPriority,
                    (int)cur_stat[i].eCurrentState,
                    drt * 100 / dtotal, drt * 10000 / dtotal % 100 );
        }

        /* 当前快照整体变成下一轮的基准 */
        memcpy( prev_stat, cur_stat, sizeof( TaskStatus_t ) * cur_n );
        prev_total = cur_total;  prev_n = cur_n;
    }
}

void app_main( void )
{
    xTaskCreate( stats_task, "stats", 4096, NULL, 3, NULL );
}
```

正常系统（无 hog 任务）的典型输出：

```text
==== CPU share over window (%, x2 cores) ====
stats      prio= 3 state=1   0.03%
IDLE0      prio= 0 state=1  99.31%
IDLE1      prio= 0 state=2  99.52%
Tmr Svc    prio= 1 state=2   0.01%
```

把 9.6 第 2 小节的 `hog` 任务加回来（钉 Core 0），再看：

```text
==== CPU share over window (%, x2 cores) ====
hog        prio= 5 state=1  99.94%
stats      prio= 3 state=1   0.05%
IDLE0      prio= 0 state=1   0.00%     ← 被饿死，TWDT 告警同时出现
IDLE1      prio= 0 state=2  99.50%
```

读数的三个门道：

1. **`eCurrentState` 是采样瞬间的快照**（1=Ready、2=Blocked，枚举见 `task.h` 的 `eTaskState`），占比才是时间维度的真相；`usStackHighWaterMark`（同一结构体里）则是栈余量，[[ch21-stack-and-memory-layout|第二十一章]]的实验会用到它。
2. **双核下各任务占比之和上限是 200%**：运行时间按"任务在哪个核上跑了多久"分别累计（`vTaskSwitchContext` 里按核记账），分母是墙钟总量，两个核各贡献最多 100%。所以 IDLE0 99% + IDLE1 99% 是健康读数。
3. **计数器会回绕**：默认 `configRUN_TIME_COUNTER_TYPE` 为 `uint32_t`，esp_timer 微秒计数约 71.6 分钟回绕一次（源码注释明言无溢出保护）。长时间观测请在 menuconfig 选 64 位（`FREERTOS_RUN_TIME_COUNTER_TYPE_U64`），或像本实验那样用短窗口差分。

---

## 9.7 小结

- **阻塞的记账**：所有阻塞 API 最终经 `prvAddCurrentTaskToDelayedList()` 入账——算绝对唤醒时刻、按序插入延迟链表、必要时刷新 `xNextTaskUnblockTime`。任务阻塞在内核对象上时"双床并存"：状态床（延迟链表）+ 事件床（对象等待链表），谁先到期谁叫人。
- **相对 vs 绝对**：`vTaskDelay` 锚"现在"，周期含执行时间、误差单向累积；`xTaskDelayUntil` 锚上次唤醒时刻，栅格不漂，错过截止期返回 `pdFALSE` 且不补偿。周期任务一律用后者。
- **解锁流水线**：`xTaskIncrementTick()` 靠 `xNextTaskUnblockTime` 快速路径把常态开销压到 O(1)，真有到期才沿有序链表扫描。双核下 Core 0 独揽计时与解锁，Core 1 的 `xTaskIncrementTickOtherCores()` 只查时间片和 yield 标志。
- **溢出双缓冲**：tick 回绕靠 `xDelayedTaskList1/2` 双链表 + 指针交换（`taskSWITCH_DELAYED_LISTS`）解决，32 位 tick@100Hz 约 497 天回绕一次。`portMAX_DELAY` 在 `vTaskDelay` 里是"睡 497 天"，在带超时的对象等待里才是真无限（进挂起链表，`eTaskGetState` 报 `eSuspended`）。
- **Idle 是家务员**：每圈回收已删除任务的 TCB 与栈（`prvCheckTasksWaitingTermination`）、跑 idle hook 链、`WAITI` 低功耗等待、可选 tickless。IDF 每核一个硬钉的 Idle（`IDLE0`/`IDLE1`），内存回收多一层"是否还在对核运行"的检查。
- **饿死 Idle 有实锤代价**：默认配置下任务看门狗（TWDT）监视两个核的 Idle，喂狗回调就挂在 IDF idle hook 链上；5 秒不喂即告警（默认不重启），且已删除任务的内存无人回收。`uxTaskGetSystemState()` 能把 Idle 占比量化出来，双核下占比总和上限 200%。

下一章进入 Part III：队列。`xQueueReceive()` 的超时参数就是本章的 `portMAX_DELAY` 语义在对象等待上的应用，而"事件床与状态床二选一先到"的双床模型将在 `queue.c` 里展开成完整的阻塞/唤醒协议——那是 FreeRTOS 万能 IPC 的地基。
