---
title: "FreeRTOS 深度解析（十一）：信号量与互斥量"
date: 2026-08-26
description: "从 semphr.h 的宏展开证明信号量只是队列的特例；走读 give/take 的 0 字节特化路径；用三任务实验在 QEMU 上复现优先级翻转，再逐行拆解 xTaskPriorityInherit 的继承与还原；最后解释 ISR 为什么碰不得互斥量、递归互斥量如何计数。"
tags: [freertos, rtos, esp32, esp-idf, qemu, semaphore, mutex, priority-inheritance]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]]
>
> 1. **第十一章：信号量与互斥量（当前章）**

# FreeRTOS 深度解析（十一）：信号量与互斥量

这一章回答四个问题：**信号量到底是什么**（答案短得令人怀疑：它就是队列）、**give/take 在源码里走哪条路**（`uxItemSize == 0` 的特化分支）、**优先级翻转怎么发生、继承怎么救场**（三任务实验 + `xTaskPriorityInherit` 逐行走读）、**为什么 ISR 里不能用互斥量**（一行 `configASSERT` 背后的机制原因）。读完它，`semphr.h` 将不再是一组黑盒 API，而是 `queue.c` 的一层语法糖。源码参照 ESP-IDF v6.0.2 默认编译的内核树 `components/freertos/FreeRTOS-Kernel/`（IDF FreeRTOS 本体，Vanilla v10.5.1 基线 + SMP 改造），与上游差异在 11.8 节集中对照。

---

## 11.1 一切皆队列：信号量的实现戏法

### 1. 打开 semphr.h：满眼都是宏

`semphr.h` 的第一眼就很反常：`SemaphoreHandle_t` 只是一行 typedef——

```c
typedef QueueHandle_t SemaphoreHandle_t;
```

再往下翻，所有"信号量 API"全是宏，没有一个函数。文件顶部三个常量把戏法的关键直接摆在了台面上：

```c
#define semBINARY_SEMAPHORE_QUEUE_LENGTH    ( ( uint8_t ) 1U )
#define semSEMAPHORE_QUEUE_ITEM_LENGTH      ( ( uint8_t ) 0U )
#define semGIVE_BLOCK_TIME                  ( ( TickType_t ) 0U )
```

翻译成人话：**二值信号量 = 长度 1、每项 0 字节的队列**。长度 1 → 只有"空/满"两个状态，正好是二值；项长 0 → 队列里不存任何数据，`uxMessagesWaiting` 从"消息数"变成纯粹的计数器。

### 2. 创建宏的展开：queueQUEUE*TYPE*\* 参数

把六个创建宏排成一张表（均已在 IDF 树 `include/freertos/semphr.h` 中核实）：

| 你写的宏                              | 实际展开为                                                                                                     | 长度 | 项长 |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ---- | ---- |
| `xSemaphoreCreateBinary()`            | `xQueueGenericCreate(1, 0, queueQUEUE_TYPE_BINARY_SEMAPHORE)`                                                  | 1    | 0    |
| `xSemaphoreCreateCounting(max, init)` | `xQueueCreateCountingSemaphore(max, init)` → `xQueueGenericCreate(max, 0, queueQUEUE_TYPE_COUNTING_SEMAPHORE)` | max  | 0    |
| `xSemaphoreCreateMutex()`             | `xQueueCreateMutex(queueQUEUE_TYPE_MUTEX)` → `xQueueGenericCreate(1, 0, …)` 再 `prvInitialiseMutex()`          | 1    | 0    |
| `xSemaphoreCreateRecursiveMutex()`    | `xQueueCreateMutex(queueQUEUE_TYPE_RECURSIVE_MUTEX)`，同上                                                     | 1    | 0    |
| `xSemaphoreCreateBinaryStatic(p)`     | `xQueueGenericCreateStatic(1, 0, NULL, p, queueQUEUE_TYPE_BINARY_SEMAPHORE)`                                   | 1    | 0    |
| `xSemaphoreGive(s)`                   | `xQueueGenericSend(s, NULL, 0, queueSEND_TO_BACK)`                                                             | —    | —    |
| `xSemaphoreTake(s, t)`                | `xQueueSemaphoreTake(s, t)`                                                                                    | —    | —    |

类型常量定义在 `queue.h`：`queueQUEUE_TYPE_BASE`=0、`queueQUEUE_TYPE_MUTEX`=1、`queueQUEUE_TYPE_COUNTING_SEMAPHORE`=2、`queueQUEUE_TYPE_BINARY_SEMAPHORE`=3、`queueQUEUE_TYPE_RECURSIVE_MUTEX`=4。注意 `ucQueueType` 这个字段只在开启 `configUSE_TRACE_FACILITY` 时才真正存进结构体——类型参数的主要用途是调试器/trace 工具区分对象，**运行时的互斥量判定另有暗号**（下一小节）。

计数信号量的初值处理值得看一眼 `queue.c` 的 `xQueueCreateCountingSemaphore()`：先用 `uxMaxCount` 当队列长度创建，然后直接改写计数字段——`( ( Queue_t * ) xHandle )->uxMessagesWaiting = uxInitialCount;`。资源池场景传 `(N, N)` 生于满、事件计数场景传 `(N, 0)` 生于空，全靠这一行后处理。

### 3. Queue_t 的双面人生：一个 union，两种身份

队列和信号量共用 `QueueDefinition` 结构体，诀窍是一个按用途二选一的 union（`queue.c`）：

```c
typedef struct QueueDefinition
{
    int8_t * pcHead;        /*< 队列存储区起点；互斥量时为 NULL（见下） */
    int8_t * pcWriteTo;     /*< 下一个写入位置 */

    union
    {
        QueuePointers_t xQueue;      /*< 当队列用：pcTail / pcReadFrom */
        SemaphoreData_t xSemaphore;  /*< 当信号量用：xMutexHolder / uxRecursiveCallCount */
    } u;

    List_t xTasksWaitingToSend;     /*< 阻塞在"等空位"上的任务（按优先级排序） */
    List_t xTasksWaitingToReceive;  /*< 阻塞在"等数据"上的任务（按优先级排序） */

    volatile UBaseType_t uxMessagesWaiting; /*< 当前项数 = 信号量计数 */
    UBaseType_t uxLength;                   /*< 容量 = 计数上限 */
    UBaseType_t uxItemSize;                 /*< 项长（信号量为 0） */

    /* …锁定计数、静态分配标记、queue set、trace 字段… */
    portMUX_TYPE xQueueLock;   /*< IDF 加的：每队列一把自旋锁（11.8 节） */
} Queue_t;
```

当队列用时，union 里放 `pcTail`/`pcReadFrom` 两个游标；当互斥量用时，换成 `xMutexHolder`（谁持有我）和 `uxRecursiveCallCount`（递归了几层）。两者永远不会同时需要，所以一个 union 就够了。

那运行时怎么知道眼前这个对象是互斥量？`queue.c` 顶部两行：

```c
#define uxQueueType            pcHead
#define queueQUEUE_IS_MUTEX    NULL
```

`prvInitialiseMutex()` 里执行 `pxNewQueue->uxQueueType = queueQUEUE_IS_MUTEX;`——其实就是**把 `pcHead` 写成 NULL**。而普通信号量虽然项长为 0、没有存储区，`prvInitialiseNewQueue()` 也会把 `pcHead` 指向结构体自身（注释原话："a benign value that is known to be within the memory map"，因为 NULL 被互斥量征用了）。于是全内核的判定就是一句 `pxQueue->uxQueueType == queueQUEUE_IS_MUTEX`，即 `pcHead == NULL` 与否。

### 4. 内存账单

动态创建时 `xQueueGenericCreate()` 只调一次 `pvPortMalloc( sizeof( Queue_t ) + uxQueueLength * uxItemSize )`。对信号量，乘积项是 0——**一个二值信号量只多花一个 `Queue_t` 的钱**，没有任何存储区开销。计数信号量的"容量"也纯粹是 `uxLength` 这个数字，不会预分配任何槽位。这也解释了为什么第 1 小节说"信号量是队列的退化特例"：退化到连数据面都不要了，只留下两张事件等待链表和一个计数器。

---

## 11.2 give/take 源码走读

### 1. give：xQueueGenericSend 的 0 字节特化

`xSemaphoreGive()` 展开成 `xQueueGenericSend(s, NULL, 0, queueSEND_TO_BACK)`——注意第二个参数 `pvItemToQueue` 是 **NULL**。对普通队列这是非法输入（入口处有 `configASSERT` 检查），但对项长为 0 的信号量完全合法：没有数据要拷，"发送"退化为计数加一。

走读 `xQueueGenericSend()` 的主循环（IDF 树，已删除 queue set 分支）：

```c
for( ; ; )
{
    taskENTER_CRITICAL( &( pxQueue->xQueueLock ) );      /* ① 拿本队列的自旋锁 */
    {
        if( ( pxQueue->uxMessagesWaiting < pxQueue->uxLength ) || ... )
        {
            xYieldRequired = prvCopyDataToQueue( pxQueue, pvItemToQueue, xCopyPosition ); /* ② */

            if( listLIST_IS_EMPTY( &( pxQueue->xTasksWaitingToReceive ) ) == pdFALSE )
            {
                if( xTaskRemoveFromEventList( &( pxQueue->xTasksWaitingToReceive ) ) != pdFALSE )
                {
                    queueYIELD_IF_USING_PREEMPTION();    /* ③ 唤醒了更高优先级任务 */
                }
            }
            else if( xYieldRequired != pdFALSE )
            {
                queueYIELD_IF_USING_PREEMPTION();        /* ④ 互斥量归还触发的让路 */
            }

            taskEXIT_CRITICAL( &( pxQueue->xQueueLock ) );
            return pdPASS;
        }
        else { /* 满了：0 超时直接失败返回 errQUEUE_FULL；否则记录时刻准备阻塞 */ }
    }
    ...
}
```

四步：① 进本队列的临界区（SMP 下是拿 `xQueueLock` 自旋锁，见 11.8）；② `prvCopyDataToQueue()` 完成实际写入；③ 若有任务阻塞在 `xTasksWaitingToReceive`（等 take 的人），摘下事件链表表头唤醒，若被唤醒者优先级更高立刻 yield；④ 若没有等待者但 ② 返回了 `pdTRUE`，也要 yield——这是互斥量专用分支，② 里发生了优先级还原。

**② 的内部就是信号量特化的所在**。`prvCopyDataToQueue()` 开头：

```c
if( pxQueue->uxItemSize == ( UBaseType_t ) 0 )
{
    if( pxQueue->uxQueueType == queueQUEUE_IS_MUTEX )
    {
        /* The mutex is no longer being held. */
        xReturn = xTaskPriorityDisinherit( pxQueue->u.xSemaphore.xMutexHolder );
        pxQueue->u.xSemaphore.xMutexHolder = NULL;
    }
}
else if( xPosition == queueSEND_TO_BACK ) { /* memcpy + 游标推进，队列路径 */ }
...
pxQueue->uxMessagesWaiting = uxMessagesWaiting + ( UBaseType_t ) 1;
```

`uxItemSize == 0` 分支不碰任何 `memcpy`，只做两件事：如果这是互斥量，先调用 `xTaskPriorityDisinherit()` 让持有者优先级还原（11.5 节细讲），清空 `xMutexHolder`；然后无条件 `uxMessagesWaiting++`——对二值信号量就是"置位"，对计数信号量就是"加一"。一个隐蔽细节：give 已满的二值信号量返回 `errQUEUE_FULL`（give 一个没人 take 的二值信号量会失败），这个行为直接继承自"向满队列发送"的队列语义。

### 2. take：xQueueSemaphoreTake

`xSemaphoreTake()` 展开为专门的 `xQueueSemaphoreTake()`（不是 `xQueueReceive()`——那个还要走 `pvBuffer` 拷贝路径）。它入口就声明了身份检查：`configASSERT( pxQueue->uxItemSize == 0 );`。

成功路径的核心：

```c
taskENTER_CRITICAL( &( pxQueue->xQueueLock ) );
{
    const UBaseType_t uxSemaphoreCount = pxQueue->uxMessagesWaiting;

    if( uxSemaphoreCount > ( UBaseType_t ) 0 )
    {
        pxQueue->uxMessagesWaiting = uxSemaphoreCount - ( UBaseType_t ) 1;  /* 计数减一 */

        if( pxQueue->uxQueueType == queueQUEUE_IS_MUTEX )
        {
            /* 记录持有者，供优先级继承使用 */
            pxQueue->u.xSemaphore.xMutexHolder = pvTaskIncrementMutexHeldCount();
        }

        if( listLIST_IS_EMPTY( &( pxQueue->xTasksWaitingToSend ) ) == pdFALSE )
        {
            if( xTaskRemoveFromEventList( &( pxQueue->xTasksWaitingToSend ) ) != pdFALSE )
            {
                queueYIELD_IF_USING_PREEMPTION();
            }
        }

        taskEXIT_CRITICAL( &( pxQueue->xQueueLock ) );
        return pdPASS;
    }
    /* 计数为 0：0 超时立即失败；否则走阻塞路径 */
}
```

三件事：计数减一；**如果是互斥量，把当前任务登记进 `xMutexHolder` 并递增其 `uxMutexesHeld`**（`pvTaskIncrementMutexHeldCount()` 一并完成，见 11.5）；如果有人阻塞在"等空位"（计数信号量满了在等 give 空间的场景）则唤醒之。

### 3. 阻塞路径：事件链表 + 优先级继承的挂钩

计数为 0 且带超时时的 SMP 路径（`queueUSE_LOCKS == 0` 分支，见 11.8）：

```c
if( xTaskCheckForTimeOut( &xTimeOut, &xTicksToWait ) == pdFALSE )
{
    #if ( configUSE_MUTEXES == 1 )
    {
        if( pxQueue->uxQueueType == queueQUEUE_IS_MUTEX )
        {
            xInheritanceOccurred = xTaskPriorityInherit( pxQueue->u.xSemaphore.xMutexHolder );  /* ★ */
        }
    }
    #endif
    vTaskPlaceOnEventList( &( pxQueue->xTasksWaitingToReceive ), xTicksToWait );  /* 挂到事件链表 */
    portYIELD_WITHIN_API();   /* 让出 CPU，-blocked- 直到 give 方或超时唤醒 */
}
else
{
    /* 超时：若发生过继承，用 vTaskPriorityDisinheritAfterTimeout() 撤销（11.5.3） */
}
```

标 ★ 的那行是本章下半场的主角：**阻塞在互斥量上之前，先把持有者优先级拉上来**。对二值/计数信号量，这一步被跳过——这个差异是一切语义分化的源头。

> [!note] 与第十章的衔接
> `vTaskPlaceOnEventList()` / `xTaskRemoveFromEventList()`、事件链表按优先级排序、`xItemValue` 存倒序优先级（`configMAX_PRIORITIES - prio`）这些机制，[[2026-08-26-freertos-deep-dive-ch10-queue-universal-ipc|第十章]]已拆解过，本章直接使用结论：**唤醒总是摘链表头 = 唤醒等待者中优先级最高的那个**。

---

## 11.3 二值信号量 vs 互斥量：一字之差，语义之别

### 1. 对照表

| 维度        | 二值信号量 `xSemaphoreCreateBinary()` | 互斥量 `xSemaphoreCreateMutex()`         |
| ----------- | ------------------------------------- | ---------------------------------------- |
| 设计目的    | **同步**（事件通知："事情发生了"）    | **互斥**（资源保护："门锁上了"）         |
| 优先级继承  | ✗ 无                                  | ✓ 有（take 阻塞时临时提权持有者）        |
| 持有者概念  | 无 `xMutexHolder`                     | 有，登记在 `u.xSemaphore.xMutexHolder`   |
| 谁必须 give | 任意任务/ISR 都可 give                | **只有 take 它的任务**（逻辑上必须成对） |
| 出生状态    | **空**（必须先 give 才能 take）       | **满**（第一次 take 直接成功）           |
| ISR 中使用  | ✓ `xSemaphoreGiveFromISR()`           | ✗ 禁止（11.6）                           |
| 递归 take   | 自死锁                                | 递归版支持（11.7）                       |
| 典型误用    | 拿来做互斥 → 优先级翻转无保护         | 拿来做 ISR→任务通知 → 直接断言崩溃       |

出生状态的差异来自创建路径：互斥量的 `prvInitialiseMutex()` 末尾主动调了一次 `xQueueGenericSend()`（"Start with the semaphore in the expected state"），所以生下来 `uxMessagesWaiting == 1`；二值信号量没有这步，生下来是 0。历史包袱：已废弃的 `vSemaphoreCreateBinary()` 宏会创建后补一次 give（生于满），这正是它被废弃的原因之一——两种"生相"造成过无数 bug。

### 2. 为什么同步不该用互斥量、互斥不该用信号量

同步语义下，give 方（比如 ISR）和 take 方（处理任务）**是不同的执行流**，而且 take 完不需要归还——"事件被消费掉了"。互斥语义下，take 和 give 必须是同一个任务、临界区成对出现——"锁开锁关"。用 `xMutexHolder` 强制了这个纪律：只有持有者能 give（递归版里显式比对 `xMutexHolder == xTaskGetCurrentTaskHandle()`，普通版靠 `xTaskPriorityDisinherit()` 里的 `configASSERT( pxTCB == pxCurrentTCBs[ portGET_CORE_ID() ] )` 兜底）。

反过来，拿二值信号量保护共享资源在**单核、无中间优先级任务**时看起来能跑——这是它最危险的地方：程序在测试环境一切正常，上线后加了个中等优先级的日志任务，高优先级任务的锁等待时间开始随机变长。11.4 的实验会精确复现这个过程。

> [!tip] 选型口诀
> **"通知用信号量，上锁用互斥量；ISR 只能给信号量。"** 另外记住 `semphr.h` 每个宏的注释都在重复的官方建议：纯任务间同步场景，任务通知（[[2026-08-26-freertos-deep-dive-ch13-task-notifications|第十三章]]）比二值信号量更快、更省内存——它连 `Queue_t` 都不用分配。

---

## 11.4 优先级翻转实验：QEMU 复现

### 1. 实验设计

经典三任务模型：

- **L（低，优先级 1）**：拿到锁，进临界区干慢活（CPU 忙循环约 100ms），give，退出；
- **H（高，优先级 5）**：醒来后 take 锁（阻塞），测自己等了多久；
- **M（中，优先级 3）**：与锁无关的 CPU 大户，忙约 300ms。

灾难链：H 阻塞在 L 手里的锁上 → 若无优先级继承，L 仍是优先级 1 → M 就绪后**抢占 L** → L 迟迟干不完临界区 → **优先级 5 的 H 被优先级 3 的 M 间接卡住**。优先级秩序被翻转了。

两个工程要点：

1. **三个任务全部 `xTaskCreatePinnedToCore(..., 0, ...)` 钉在 Core 0**。否则双核 ESP32 会把 M 调度到 Core 1 上并行跑，抢占关系被掩盖，实验失去确定性（这也是第一次用 SMP 板子做经典翻转实验的人最常踩的坑）；
2. 用 `#define USE_MUTEX` 一键切换锁类型，同一份代码跑两遍对照。

### 2. 完整代码

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_timer.h"

#define USE_MUTEX   1   /* 1 = 互斥量（有优先级继承）；0 = 二值信号量（无） */

#define TS()        ((long long) (esp_timer_get_time() / 1000))   /* 打时间戳 */

static SemaphoreHandle_t xLock;

static void low_task(void *arg)            /* L：持锁干慢活 */
{
    xSemaphoreTake(xLock, portMAX_DELAY);
    printf("[L %6lld ms] got lock, enter critical section\n", TS());
    volatile int dummy = 0;
    for (int i = 0; i < 2000000; i++) {    /* CPU 忙约 100ms（QEMU 下更久） */
        dummy += i;
    }
    printf("[L %6lld ms] leaving, give lock\n", TS());
    xSemaphoreGive(xLock);
    vTaskDelete(NULL);
}

static void mid_task(void *arg)            /* M：不碰锁的 CPU 大户 */
{
    printf("[M %6lld ms] start busy work\n", TS());
    volatile int dummy = 0;
    for (int i = 0; i < 6000000; i++) {    /* CPU 忙约 300ms（QEMU 下更久） */
        dummy += i;
    }
    printf("[M %6lld ms] busy work done\n", TS());
    vTaskDelete(NULL);
}

static void high_task(void *arg)           /* H：等锁，测等待时长 */
{
    int64_t t0 = esp_timer_get_time();
    printf("[H %6lld ms] trying to take lock\n", (long long) (t0 / 1000));
    xSemaphoreTake(xLock, portMAX_DELAY);  /* 阻塞，直到 L give */
    printf("[H %6lld ms] got lock after %lld ms\n", TS(),
           (long long) ((esp_timer_get_time() - t0) / 1000));
    xSemaphoreGive(xLock);
    vTaskDelete(NULL);
}

void app_main(void)
{
#if USE_MUTEX
    xLock = xSemaphoreCreateMutex();
    printf("=== MUTEX (priority inheritance ON) ===\n");
#else
    xLock = xSemaphoreCreateBinary();
    printf("=== BINARY SEMAPHORE (no inheritance) ===\n");
#endif
    xTaskCreatePinnedToCore(low_task,  "low",  2048, NULL, 1, NULL, 0);
    vTaskDelay(pdMS_TO_TICKS(20));         /* 让 L 先拿到锁、进入临界区 */
    xTaskCreatePinnedToCore(high_task, "high", 2048, NULL, 5, NULL, 0);
    vTaskDelay(pdMS_TO_TICKS(30));         /* H 醒来，阻塞在锁上 */
    xTaskCreatePinnedToCore(mid_task,  "mid",  2048, NULL, 3, NULL, 0);
}
```

运行（环境搭建见[[2026-08-26-freertos-deep-dive-ch1-from-bare-metal-to-rtos|第一章]]）：

```bash
idf.py create-project freertos-ch11 && cd freertos-ch11 && idf.py set-target esp32
# 用上面内容替换 main/freertos-ch11.c，然后：
idf.py qemu monitor
```

### 3. 观察到什么

`USE_MUTEX = 0`（二值信号量）的典型输出（时间数值为示意，随 QEMU 版本与主机浮动）：

```text
=== BINARY SEMAPHORE (no inheritance) ===
[L     31 ms] got lock, enter critical section
[H     51 ms] trying to take lock
[M     81 ms] start busy work
[M    690 ms] busy work done                 ← M 抢占了 L，一路跑完
[L    810 ms] leaving, give lock             ← L 才被恢复，磨完临界区
[H    810 ms] got lock after 759 ms          ← 优先级 5 等了 759ms！
```

`USE_MUTEX = 1`（互斥量）的典型输出：

```text
=== MUTEX (priority inheritance ON) ===
[L     31 ms] got lock, enter critical section
[H     51 ms] trying to take lock
[M     81 ms] start busy work
[L    145 ms] leaving, give lock             ← L 被提到优先级 5，M 抢不动
[H    145 ms] got lock after 94 ms           ← H 只等了 L 的临界区时长
[M    690 ms] busy work done                 ← M 排在 H 后面才轮到
```

同一段持锁代码，H 的等待从 ~760ms 掉到 ~90ms——差额正好是 M 插队运行的时间。想看"真饿死"：把 M 的循环改成 `for(;;)`，二值信号量版本里 H 将**永远**拿不到锁（QEMU 里盯着监视器等一分钟就可以 Ctrl-] 退场了）；互斥量版本里 H 照样在临界区结束时准点拿到锁。

### 4. 时序图：翻转与继承的对照

无继承（二值信号量）——H 的等待被无关的 M 拉长：

```text
 优先级
    5 | H  ██ blocked on sem ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ██ got lock
    3 | M                             ██████████████████
    1 | L   [持锁，干慢活 ░░░░░ 被M抢占 ░░░░░░░ 恢复磨完] ▓▓ give
      -----+-----------+----------------+-------------+---------> 时间
          t0         t1                t2            t3        t4
          L取锁      H取锁失败阻塞     M就绪抢占L     M跑完     L给锁,H醒
                     <---------------- H 实际等待 ---------------->
                      = L 剩余临界区(被拉长) + M 全程运行
```

有继承（互斥量）——L 临时升到 5，M 插不进来：

```text
 优先级
    5 | H  ██ blocked ░░░░░░░░░░░░░░░░ ██ got lock
    3 | M                        (就绪也只能等)  ██████████████
  1→5| L   [持锁，优先级被提为 5 █████████████] ▓▓ give（优先级回落为 1）
      -----+-----------+-----------+-----+-----------------------> 时间
          t0         t1           t2'  t3'
          L取锁      H阻塞,L继承5   L给锁,H立即醒   M 这才有机可乘
                     <---- H 等待 ---->
                      ≈ L 剩余临界区（不被打断）
```

### 5. 机制回放

把输出对回 11.2 的源码：t1 时刻 H 调 `xSemaphoreTake()`，计数为 0，走阻塞路径；`USE_MUTEX=1` 时那行 `xTaskPriorityInherit(pxQueue->u.xSemaphore.xMutexHolder)` 把 L 的 `uxPriority` 从 1 改写成 5 并搬进优先级 5 的就绪链表；t2 时刻 M 就绪，`prvSelectHighestPriorityTaskSMP` 找到的是"优先级 5 的 L"而不是 3 的 M，L 无损跑完；give 时 `prvCopyDataToQueue()` 的互斥量分支调 `xTaskPriorityDisinherit()` 把 L 还原回 1、唤醒 H。`USE_MUTEX=0` 时 ★ 行不存在，L 原地不动地当他的优先级 1，被 M 反复碾压。

---

## 11.5 优先级继承机制源码

优先级继承（priority inheritance）的定义：**低优先级任务持有高优先级任务需要的锁时，临时以"等它的任务中最高的优先级"运行**。FreeRTOS 的实现分布在 `tasks.c` 三个函数 + `queue.c` 两个挂钩上，全部实读核实如下。

### 1. 数据基础：TCB 里的两个字段

`tasks.c` 的 TCB（`configUSE_MUTEXES == 1` 时）：

```c
UBaseType_t uxBasePriority;   /*< 基准优先级：创建时分配的，继承机制的"存根" */
UBaseType_t uxMutexesHeld;    /*< 当前持有的互斥量个数 */
```

`uxPriority` 是调度器实际使用的优先级，继承改的就是它；`uxBasePriority` 永远记着出厂值，还原时抄回来；`uxMutexesHeld` 是判断"能不能还原"的依据。

### 2. take 阻塞时：xTaskPriorityInherit

调用点在 11.2.3 的 ★ 行。函数主干（IDF 树）：

```c
BaseType_t xTaskPriorityInherit( TaskHandle_t const pxMutexHolder )
{
    TCB_t * const pxMutexHolderTCB = pxMutexHolder;
    BaseType_t xReturn = pdFALSE;

    prvENTER_CRITICAL_SMP_ONLY( &xKernelLock );      /* SMP：拿内核锁 */
    {
        const BaseType_t xCurCoreID = portGET_CORE_ID();

        if( pxMutexHolder != NULL )
        {
            if( pxMutexHolderTCB->uxPriority < pxCurrentTCBs[ xCurCoreID ]->uxPriority )
            {
                /* 事件链表项的值跟着改成新优先级（倒序编码），保证唤醒顺序正确 */
                listSET_LIST_ITEM_VALUE( &( pxMutexHolderTCB->xEventListItem ),
                    ( TickType_t ) configMAX_PRIORITIES - pxCurrentTCBs[ xCurCoreID ]->uxPriority );

                /* 持有者在就绪态 → 从旧优先级链表摘下，改优先级，挂到新链表 */
                if( listIS_CONTAINED_WITHIN( &( pxReadyTasksLists[ pxMutexHolderTCB->uxPriority ] ),
                                             &( pxMutexHolderTCB->xStateListItem ) ) != pdFALSE )
                {
                    uxListRemove( &( pxMutexHolderTCB->xStateListItem ) );
                    pxMutexHolderTCB->uxPriority = pxCurrentTCBs[ xCurCoreID ]->uxPriority;
                    prvAddTaskToReadyList( pxMutexHolderTCB );
                }
                else
                {
                    pxMutexHolderTCB->uxPriority = pxCurrentTCBs[ xCurCoreID ]->uxPriority;  /* 仅改号 */
                }

                xReturn = pdTRUE;    /* 发生了继承 */
            }
            else if( 持有者基准优先级低于当前任务 ) { xReturn = pdTRUE; }  /* 已被继承过：只记账不动人 */
        }
    }
    prvEXIT_CRITICAL_SMP_ONLY( &xKernelLock );

    return xReturn;
}
```

要点三条：

1. **比较对象是当前任务**（`pxCurrentTCBs[xCurCoreID]`，即正在 take 的 H）的优先级。持有者优先级更低才提权，且**提到 H 的优先级**——不是加一，也不是天花板；
2. 持有者若在就绪链表里，要**物理搬家**到新优先级的链表（`uxListRemove` + `prvAddTaskToReadyList`，链表组织见[[2026-08-26-freertos-deep-dive-ch6-scheduler-ready-lists|第六章]]）；若在阻塞/挂起态，改个号即可，醒来自动进对的链表；
3. 返回值 `xReturn` 交给调用方记账（就是 11.2.3 的 `xInheritanceOccurred`），超时路径要靠它决定是否撤销。

注意持有者可能同时被多个等待者"继承"——第二次进入时若它已处于更高优先级，走 `else if` 分支只记账。继承取的是**等待者中的最高优先级**（更高优先级的等待者会先到：低优先级等待者提权不动它）。

### 3. give 时：xTaskPriorityDisinherit

调用点在 give 路径 `prvCopyDataToQueue()` 的互斥量分支。主干：

```c
BaseType_t xTaskPriorityDisinherit( TaskHandle_t const pxMutexHolder )
{
    prvENTER_CRITICAL_SMP_ONLY( &xKernelLock );
    {
        if( pxMutexHolder != NULL )
        {
            /* 能 give 互斥量的只有持有者自己 = 当前正在运行的任务 */
            configASSERT( pxTCB == pxCurrentTCBs[ portGET_CORE_ID() ] );
            configASSERT( pxTCB->uxMutexesHeld );
            ( pxTCB->uxMutexesHeld )--;                          /* 持锁数减一 */

            if( pxTCB->uxPriority != pxTCB->uxBasePriority )     /* 被继承过？ */
            {
                if( pxTCB->uxMutexesHeld == ( UBaseType_t ) 0 )  /* 手里没别的锁了？ */
                {
                    uxListRemove( &( pxTCB->xStateListItem ) );  /* 摘出就绪链表 */
                    pxTCB->uxPriority = pxTCB->uxBasePriority;   /* ★ 还原为基准优先级 */
                    listSET_LIST_ITEM_VALUE( &( pxTCB->xEventListItem ),
                        ( TickType_t ) configMAX_PRIORITIES - pxTCB->uxPriority );
                    prvAddTaskToReadyList( pxTCB );              /* 挂回低优先级链表 */

                    xReturn = pdTRUE;   /* 提示调用方可能需要 yield */
                }
            }
        }
    }
    prvEXIT_CRITICAL_SMP_ONLY( &xKernelLock );
    return xReturn;
}
```

两个精妙处：

- **`uxMutexesHeld == 0` 才还原**：任务同时持有 A、B 两把锁时，先 give A 不还原——因为 B 的等待者可能还要求它保持高优先级。只有最后一把锁交出去才降回 `uxBasePriority`。这就是 11.2.1 步骤④ 的来源：give 完优先级骤降，若此刻有比新优先级高的任务就绪（比如刚被唤醒的 H），必须立刻 yield；
- 顶部那行 `configASSERT( pxTCB == pxCurrentTCBs[portGET_CORE_ID()] )` 顺带回答了"能不能 give 别人持有的互斥量"——断言直接崩给你看。

### 4. 超时路径：vTaskPriorityDisinheritAfterTimeout

H 带超时等锁、超时到了还没拿到：H 曾经把 L 提到 5，现在 H 撤了，L 该降到几？**不能无脑降回 1**——可能还有个优先级 4 的 H2 也在等同一把锁。`queue.c` 的 `prvGetDisinheritPriorityAfterTimeout()` 负责算这个值：取 `xTasksWaitingToReceive` 链表头（仍是等待者中最高优先级，倒序编码所以要 `configMAX_PRIORITIES -` 还原），没人等则 `tskIDLE_PRIORITY`。然后 `tasks.c` 的 `vTaskPriorityDisinheritAfterTimeout(holder, uxHighestWaitingPriority)` 把持有者优先级设为 `max(uxBasePriority, 最高等待者优先级)`——注意它内部有个简化：只在 `uxMutexesHeld == 1`（恰好持一把锁）时才动优先级，多锁嵌套场景维持现状，属于工程上的保守取舍。

### 5. 边界与局限

- 这是**基本的优先级继承**（不是优先级天花板/PCP）：能阻断"中优先级抢占持锁低优先级任务"这一种翻转，不能防死锁——两个任务交叉持锁互等，继承只会让双方原地升到天上去，死锁要靠锁序纪律解决（[[2026-08-26-freertos-deep-dive-ch24-debugging-tracing-pitfalls|第二十四章]]死锁案例集）；也没有传递性——H 等 A（持有者 M）、M 又在等 B（持有者 L）时，继承只提 M 不提 L，锁链末端的低优先级任务照样可能被卡；
- 继承只作用于**任务**，中断没有优先级继承这回事——这正是下一节。

---

## 11.6 为什么 ISR 里不能用互斥量

### 1. 源码里的明文禁令

ISR 侧的 give 接口是 `xQueueGiveFromISR()`（`xSemaphoreGiveFromISR` 的展开目标），它入口处有一条专门的断言：

```c
/* Normally a mutex would not be given from an interrupt, especially if
 * there is a mutex holder, as priority inheritance makes no sense for an
 * interrupts, only tasks. */
configASSERT( !( ( pxQueue->uxQueueType == queueQUEUE_IS_MUTEX ) &&
                 ( pxQueue->u.xSemaphore.xMutexHolder != NULL ) ) );
```

开了断言的构建里，ISR give 一个**正被持有**的互斥量直接 panic；没开断言则是更阴险的静默数据结构破坏。take 侧更根本：FromISR 系 API 全部不允许阻塞，而互斥量的整个意义就是"拿不到就等"，`xQueueSemaphoreTake` 根本没有 FromISR 版本。

### 2. 机制原因：互斥量的三根支柱在 ISR 里全都不存在

| 支柱                | 任务                      | ISR                                        |
| ------------------- | ------------------------- | ------------------------------------------ |
| `xMutexHolder` 登记 | 指向 TCB                  | 中断没有 TCB，"持有者"无处登记             |
| 优先级继承          | 提升持有者的 `uxPriority` | 中断优先级由硬件决定，内核改不了也不该改   |
| 阻塞等待            | 挂到事件链表让出 CPU      | 中断不能阻塞——让出什么？它不是被调度的实体 |

顺带一提，`xQueueGetMutexHolderFromISR()` 这个函数存在且合法——查一下谁持着锁是可以的，不能的是在 ISR 里 take/give。

### 3. 正确姿势

ISR→任务的方向用二值/计数信号量：ISR 里 `xSemaphoreGiveFromISR(s, &woken)`，任务里 `xSemaphoreTake()`。同步语义（"事件发生了，去处理"）本来就不需要继承和归还。函数体里那句注释也很坦白：ISR give 时"可以假定没有互斥量持有者、无需考虑优先级还原，简单地把计数加一就行"。任务间纯同步则优先考虑任务通知（[[2026-08-26-freertos-deep-dive-ch13-task-notifications|第十三章]]），连队列对象的分配都省了。

---

## 11.7 递归互斥量与 uxRecursiveCallCount

### 1. 问题：同任务重复 take 自己持有的锁

驱动层拿锁后调用上层函数，上层函数又去拿同一把锁——普通互斥量下这是自死锁：第二次 take 阻塞等第一次 give，而 give 永远不会来。递归互斥量允许**持有者反复 take 自己的锁**，内部靠 `u.xSemaphore.uxRecursiveCallCount`（那个 union 里的第二个字段）计数。

### 2. 源码：计数配平

`xSemaphoreTakeRecursive()` → `xQueueTakeMutexRecursive()`（`queue.c`）：

```c
if( pxMutex->u.xSemaphore.xMutexHolder == xTaskGetCurrentTaskHandle() )
{
    ( pxMutex->u.xSemaphore.uxRecursiveCallCount )++;   /* 已经是我的：只计数 */
    xReturn = pdPASS;
}
else
{
    xReturn = xQueueSemaphoreTake( pxMutex, xTicksToWait );  /* 走正常 take 路径 */
    if( xReturn != pdFAIL )
    {
        ( pxMutex->u.xSemaphore.uxRecursiveCallCount )++;   /* 首次获得：计数为 1 */
    }
}
```

`xSemaphoreGiveRecursive()` → `xQueueGiveMutexRecursive()`：

```c
if( pxMutex->u.xSemaphore.xMutexHolder == xTaskGetCurrentTaskHandle() )
{
    ( pxMutex->u.xSemaphore.uxRecursiveCallCount )--;

    if( pxMutex->u.xSemaphore.uxRecursiveCallCount == ( UBaseType_t ) 0 )
    {
        /* 计数归零才真正归还：唤醒等待者 */
        ( void ) xQueueGenericSend( pxMutex, NULL, queueMUTEX_GIVE_BLOCK_TIME, queueSEND_TO_BACK );
    }
    xReturn = pdPASS;
}
else
{
    xReturn = pdFAIL;    /* 不是持有者，拒绝 */
}
```

take 五次就必须 give 恰好五次，计数归零那一次才真正走 `xQueueGenericSend` 归还。注意两处设计：

- **身份判定无锁化**：源码注释解释了为什么不加临界区——`xMutexHolder` 只有持有者会改写，非持有者比较必然失败，天然单写者；持有者自己的比较必然成功且无竞争。这个"只有一个任务能通过比较"的论证是内核里少见的无锁读；
- **非持有者的 take 走的是 `xQueueSemaphoreTake`**：所以递归互斥量同样参与优先级继承（它创建时走的是 `xQueueCreateMutex`，`pcHead == NULL` 同样成立），超时语义也在。

调用方无从感知嵌套深度，所以递归互斥量经常被批评为**掩盖设计问题**（本该拆开的层次被一把可重入锁糊住）；但在"库函数无法控制调用者是否已持锁"的场景（日志、内存分配器的可重入保护）它是务实解。别和 11.5.3 的"多锁计数"混淆：`uxMutexesHeld` 在 TCB 上、跨多把锁计数；`uxRecursiveCallCount` 在队列对象上、对一把锁计数。

---

## 11.8 Vanilla vs ESP-IDF：本章主题的对照

暗线时间。信号量这一层 API 面 Vanilla 与 IDF 完全一致（宏展开一字不差），差异全部沉在实现里——而且正落在 11.2 走读过的那些代码行上：

| 主题                                 | Vanilla v10.5.1                                                                           | IDF FreeRTOS（v6.0.2 默认树）                                                                                                                                              |
| ------------------------------------ | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Queue_t` 结构                       | 无锁字段                                                                                  | 末尾多一个 `portMUX_TYPE xQueueLock`（每队列一把自旋锁）                                                                                                                   |
| 临界区写法                           | `taskENTER_CRITICAL()`——全局关中断                                                        | `taskENTER_CRITICAL(&pxQueue->xQueueLock)`——按对象加锁                                                                                                                     |
| 队列锁机制（cRxLock/cTxLock）        | 恒启用：阻塞路径靠 `vTaskSuspendAll()` + `prvLockQueue()` 让 ISR 访问不摘事件链表、只记数 | `queueUSE_LOCKS` 在 `configNUMBER_OF_CORES > 1` 时为 0，**整体弃用**：阻塞直接发生在持自旋锁的临界区内。源码注释自陈动机："SMP 实现反正已非确定性，不如用临界区换队列性能" |
| `xTaskPriorityInherit` 的保护        | **零锁**——依赖"调用时调度器已被挂起"这一队列锁路径的隐含约定；操作单数 `pxCurrentTCB`     | `prvENTER_CRITICAL_SMP_ONLY(&xKernelLock)` 显式拿内核锁；用 `pxCurrentTCBs[portGET_CORE_ID()]` 按核索引                                                                    |
| 优先级继承算法                       | 提到等待者优先级、`uxBasePriority` 存根、`uxMutexesHeld` 计数                             | 同左——算法原样保留，只换了保护方式                                                                                                                                         |
| `xSemaphoreCreate*` / give / take 宏 | —                                                                                         | 展开完全一致，应用代码零改动                                                                                                                                               |

这张表是全系列暗线的一个典型样本：**IDF 的 SMP 改造不动机制内核，动的是机制周围的保护结构**——补上单核世界用不上的锁（每队列自旋锁、内核锁），拆掉单核世界赖以为生的顺序假设（队列锁的确定性没了，干脆不用）。对写应用的实用结论只有一句：单核教程里"互斥量临界区时间可精确计算"这类断言，在 ESP32 默认双核配置下要打折扣——优先级继承救得了翻转，救不了另一个核把锁多持了一会儿。自旋锁的实现在[[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|第十八章]]，SMP 改造全景见[[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|第二十二章]]。

---

## 11.9 小结

- 信号量是队列的退化特例：`uxItemSize = 0` 砍掉数据面，`uxLength` 当计数上限，`uxMessagesWaiting` 当计数值。`semphr.h` 全是宏，`xSemaphoreCreate*` 一路展开到 `xQueueGenericCreate(长度, 0, queueQUEUE_TYPE_*)`；
- `Queue_t` 的 union 让同一块内存按用途切换身份：队列时放游标，互斥量时放 `xMutexHolder` + `uxRecursiveCallCount`；互斥量的运行时判定是 `pcHead == NULL`；
- 二值信号量管**同步**（谁都能 give、生于空、ISR 可用），互斥量管**互斥**（只有持有者 give、生于满、带继承）。拿信号量当锁用，单核测试能过、上线遇翻转；
- 三任务实验（全钉 Core 0）在 QEMU 上复现：无继承时高优先级等待被无关中优先级任务拉长约一个数量级；互斥量把 H 的等待压回"临界区本长"；
- 继承的实现账本：TCB 的 `uxBasePriority`（存根）+ `uxMutexesHeld`（计数）。take 阻塞时 `xTaskPriorityInherit` 把持有者提到等待者优先级并物理搬家就绪链表；give 时 `xTaskPriorityDisinherit` 在最后一把锁交出后还原；超时用 `prvGetDisinheritPriorityAfterTimeout` 折算剩余等待者的最高优先级再降；
- ISR 不能用互斥量：持有者无处登记、中断优先级不可继承、ISR 不能阻塞，`xQueueGiveFromISR` 的 `configASSERT` 是明文禁令。方向改成二值信号量 + `GiveFromISR`；
- 递归互斥量用 `uxRecursiveCallCount` 做 take/give 配平，身份比较靠"只有持有者能通过"的单写者性质免锁；
- Vanilla 与 IDF 在这一层 API 零差异、实现三层差异：每队列自旋锁、SMP 弃用队列锁、继承函数显式拿内核锁。

下一章离开"单值"世界，进入**事件组**（`event_groups.c`）：一个 24 位的标志字如何同时等待多个事件、又如何实现"全都到齐"与"任一到齐"两种汇合语义——它将是任务通知登场前，FreeRTOS 最后一个重量级同步原语，见[[2026-08-26-freertos-deep-dive-ch12-event-groups|第十二章]]。（本章源码引用均实读自 ESP-IDF v6.0.2 `components/freertos/FreeRTOS-Kernel/` 与上游 FreeRTOS-Kernel V10.5.1 同名文件。）
