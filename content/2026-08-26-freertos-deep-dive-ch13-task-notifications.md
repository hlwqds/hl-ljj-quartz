---
title: "FreeRTOS 深度解析（十三）：任务通知：最轻量的 IPC"
date: 2026-08-26
description: "任务通知把'邮箱'直接嵌进 TCB：ulNotifiedValue/ucNotifyState 两个数组字段替代一个完整内核对象。拆解 xTaskGenericNotify 五种动作、xTaskNotifyWait 的进入/退出清除、FromISR 的延迟 yield 与跨核抢占、索引通知，给出通知 vs 信号量 vs 队列选型表与 QEMU ping-pong 切换延迟对比实验。"
tags: [freertos, rtos, esp32, esp-idf, ipc, task-notifications, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 13. **第十三章：任务通知：最轻量的 IPC**

# FreeRTOS 深度解析（十三）：任务通知：最轻量的 IPC

这一章回答三个问题：**为什么需要任务通知**（第 10~12 章的内核对象到底贵在哪）、**它怎么工作**（TCB 里那两个字段如何拼出一个"邮箱"）、**什么时候能用什么时候不能用**（一对一的硬限制）。读完它，你应该能对每个"唤醒某个任务"的场景在 30 秒内做出选型判断。源码参照：ESP-IDF v6.0.2 默认编译的内核树 `components/freertos/FreeRTOS-Kernel/`（IDF 对 Vanilla v10.5.1 的 SMP 改造版）的 `tasks.c`/`task.h`，对照 Vanilla v10.5.1 同名文件。

---

## 13.1 设计动机：内核对象的开销账单

### 1. 复盘：一个信号量到底买下了什么

第 11 章已经拆过：二值信号量、计数信号量、互斥量在源码层面全是队列。`xSemaphoreCreateBinary()` 最终调用 `xQueueCreate()`，从堆里分配一个 `Queue_t`（queue.c 的 `QueueDefinition` 结构体）：

```text
Queue_t（32 位 Xtensa 上约 76 字节，不含数据区）
├── pcHead / pcWriteTo / u.xQueue.*      ← 数据区游标
├── xTasksWaitingToSend / ...ToReceive   ← 两个事件链表（各 ~20B，按优先级有序）
├── uxMessagesWaiting / uxLength / uxItemSize / cRxLock / cTxLock
└── ucStaticallyAllocated / ucQueueType ...
```

也就是说，哪怕只想要"唤醒一个任务"这一件事，你也买下了：**约 76 字节堆内存、两个按优先级排序的事件链表、一套锁计数协议、以及创建/删除的完整生命周期**。对象数一多（每个驱动一个信号量很常见），这笔账就变得可观。

### 2. 观察：多数 IPC 其实是"点对点叫醒"

再审视真实代码里这些内核对象的用法，会发现大量场景根本用不到队列的全部能力：

- 中断发生，**叫醒那个**处理任务——发送者明确知道接收者是谁；
- 传一个事件位、一个 32 位值、或一个"又来了一次"的计数——**不需要缓冲多个不同数据**；
- 永远只有一个等待者——**不存在多任务等同一个对象**。

这些场景的共同点：**通信是点对点的，数据量是一个 `uint32_t` 能装下的**。为它付出两个事件链表和 76 字节，是拿大炮打蚊子。

### 3. 思路：任务反正有 TCB，把邮箱嵌进去

既然每个任务生来就有一个 TCB（[[2026-08-26-freertos-deep-dive-ch5-task-lifecycle-and-tcb|第五章]] 解剖过），最省的做法不是再造对象，而是**直接在 TCB 里预留一对字段**当邮箱。`tasks.c` 的 TCB 定义里就是这样一段（由 `configUSE_TASK_NOTIFICATIONS` 控制）：

```c
#if ( configUSE_TASK_NOTIFICATIONS == 1 )
    volatile uint32_t ulNotifiedValue[ configTASK_NOTIFICATION_ARRAY_ENTRIES ];
    volatile uint8_t ucNotifyState[ configTASK_NOTIFICATION_ARRAY_ENTRIES ];
#endif
```

一个 `uint32_t` 通知值加一个 `uint8_t` 通知状态——默认配置（数组长度 1）下**每个任务固定多付 5 字节**，换来一个零分配、零注册、与任务同生共死的私有信箱。对比：

|                | 队列/信号量              | 任务通知                              |
| -------------- | ------------------------ | ------------------------------------- |
| 额外 RAM       | 每对象 ~76B + 数据区     | 每任务 5B（TCB 内嵌，默认数组长度 1） |
| 对象创建/删除  | 需要堆分配与生命周期管理 | 无对象，随任务生灭                    |
| 发送者需要什么 | 队列句柄                 | 目标任务的 `TaskHandle_t`             |
| 等待者数量     | 多个                     | **恰好一个（任务本人）**              |

最后一行就是代价：这个信箱是任务私有的，天生只能一对一。13.7 节展开。

> [!note] 一句话版本
> 任务通知 = 把"信箱"从独立的内核对象搬进 TCB。省掉的是分配、事件链表和锁协议；付出的是"只有本任务能收"的一对一约束。

---

## 13.2 机制解剖：两个数组字段拼出的状态机

通知的全部状态就在 TCB 那两个字段里。先看状态，再看动作。

### 1. ucNotifyState：三态状态机

`tasks.c` 开头定义了状态值（每个数组槽位独立一份）：

```c
#define taskNOT_WAITING_NOTIFICATION   ( ( uint8_t ) 0 ) /* 初值，必须为 0 */
#define taskWAITING_NOTIFICATION       ( ( uint8_t ) 1 )
#define taskNOTIFICATION_RECEIVED      ( ( uint8_t ) 2 )
```

迁移规则（13.3、13.4 节逐行对上源码）：

```text
        wait 开始且尚无通知                 通知到达且任务正在等
  ┌────────────────┐ ────────────→ ┌────────────────┐ ────────────→ ┌────────────────┐
  │  NOT_WAITING   │               │    WAITING     │   解除阻塞并   │   RECEIVED     │
  │     (0)        │               │     (1)        │   置状态为 2   │     (2)        │
  └────────────────┘               └────────────────┘               └────────────────┘
        ↑ ↑                                                                │ │
        │ │        wait 返回（被唤醒或超时），状态无条件复位为 0               │ │ 通知到达但任务没在等：
        │ └────────────────────────────────────────────────────────────────┘ │   状态直接落到 2，值照常更新，
        └────────────────────────────────────────────────────────────────────┘   任务不被搬动（本来就没在等）
```

两条关键性质从图上直接读出：

1. **通知不会丢**：任务还没开始等时通知先到，状态锁在 2（RECEIVED），后续的 `xTaskNotifyWait()` 一进门就发现"已有通知"，立刻返回——不会像裸机标志位那样错过。
2. **状态与值分离**：`ucNotifyState` 回答"有没有通知"，`ulNotifiedValue` 回答"通知带了什么"。`eNoAction` 动作只改状态不碰值，两者正交。

### 2. eNotifyAction：一次通知能做的五种动作

发送侧的全部行为由 `task.h` 的 `eNotifyAction` 枚举决定：

| 动作                        | 对 ulNotifiedValue 的效果            | 语义               | 典型用法                             |
| --------------------------- | ------------------------------------ | ------------------ | ------------------------------------ |
| `eNoAction`                 | 不动                                 | 纯事件："叫你一声" | 唤醒信号，事件发生                   |
| `eSetBits`                  | `value \|= ulValue`                  | 按**位或**置位     | 多个事件源用不同 bit 报告            |
| `eIncrement`                | `value++`                            | 计数 +1            | 事件计数，`xTaskNotifyGive()` 就是它 |
| `eSetValueWithOverwrite`    | `value = ulValue`                    | 直接覆盖旧值       | "最新值生效"的寄存器语义             |
| `eSetValueWithoutOverwrite` | 旧值未读则 `= ulValue`，**已读才写** | 深度为 1 的"信箱"  | 不许覆盖未读消息                     |

注意 `eSetValueWithoutOverwrite` 的判断依据是**旧的通知状态**：发送时发现 `ucNotifyState` 已经是 RECEIVED（上次的通知还没被取走），写入被拒绝并返回 `pdFAIL`。这是通知里最接近"队列不覆盖"语义的动作，但也仅此而已——深度就是 1，装不下第二条。

### 3. xTaskGenericNotify：发送路径逐行看

所有发送 API 最终汇聚到 `tasks.c` 的 `xTaskGenericNotify()`（`task.h` 里的 `xTaskNotify()`、`xTaskNotifyIndexed()`、`xTaskNotifyAndQuery()` 都是对它的宏封装，默认填下标 0）。剥掉 trace 后骨架：

```c
BaseType_t xTaskGenericNotify( TaskHandle_t xTaskToNotify,
                               UBaseType_t uxIndexToNotify, uint32_t ulValue,
                               eNotifyAction eAction,
                               uint32_t * pulPreviousNotificationValue )
{
    pxTCB = xTaskToNotify;
    taskENTER_CRITICAL( &xKernelLock );       /* 内核自旋锁临界区（见 13.6） */
    {
        if( pulPreviousNotificationValue != NULL )
            *pulPreviousNotificationValue = pxTCB->ulNotifiedValue[ uxIndexToNotify ];
        ucOriginalNotifyState = pxTCB->ucNotifyState[ uxIndexToNotify ];
        pxTCB->ucNotifyState[ uxIndexToNotify ] = taskNOTIFICATION_RECEIVED;
        switch( eAction ) { /* 上一小节那张表，逐 case 落到值操作 */ }

        /* 关键：目标正在等通知，才需要解除阻塞 */
        if( ucOriginalNotifyState == taskWAITING_NOTIFICATION )
        {
            listREMOVE_ITEM( &( pxTCB->xStateListItem ) );   /* 从延时/挂起链表摘下 */
            prvAddTaskToReadyList( pxTCB );                  /* 挂上就绪链表 */
            /* 断言：等通知的任务绝不在任何事件链表上 */
            configASSERT( listLIST_ITEM_CONTAINER( &( pxTCB->xEventListItem ) ) == NULL );
            if( taskIS_YIELD_REQUIRED( pxTCB, pdFALSE ) == pdTRUE )
                taskYIELD_IF_USING_PREEMPTION();             /* 视优先级触发 yield */
        }
    }
    taskEXIT_CRITICAL( &xKernelLock );
    return xReturn;
}
```

三件事值得停下咀嚼：

1. **整个动作在一次临界区内完成，且只有目标正在等（原状态为 WAITING）才动链表**——目标没在等就只是改两个字段后返回，成本近乎为零。没有"先锁再改再解锁"的多段协议，一次持锁足够。
2. **无条件先把状态置为 RECEIVED**，再按动作改值。所以哪怕 `eNoAction`，状态也翻转——"叫过你"本身就是通知。
3. **那条断言是通知机制的身份证明**：等通知的任务只待在延时链表（为了超时记账），从不上任何事件链表。`xEventListItem` 完全闲置——这正是它比队列快的结构性原因。

### 4. 为什么快：省掉的那次链表往返

对比两条阻塞路径——等队列/信号量走 `tasks.c` 的 `vTaskPlaceOnEventList()`，等通知直呼 `prvAddCurrentTaskToDelayedList()`：

```text
等一个队列/信号量（vTaskPlaceOnEventList）：       等一个通知：
1. 拿内核锁（IDF SMP 的额外临界区）              1. prvAddCurrentTaskToDelayedList()
2. vListInsert(事件链表) ← 按优先级有序插入（沿链扫描）   （仅此一步：挂延时链表，超时记账）
3. prvAddCurrentTaskToDelayedList()（挂延时链表）
```

解除阻塞侧同理：队列路径要把目标从事件链表摘下、从延时链表摘下、挂上就绪链表（外加队列自身的簿记）；通知路径只有"延时链表摘除 + 就绪链表插入"两次。**一收一发，通知比队列整整少一进一出两次链表操作，其中事件链表的插入还是有序插入**。再叠加：不用解引用一个独立的 `Queue_t`（对 cache 更友好）、没有消息逐字节拷贝、对象创建时零 `pvPortMalloc`——官方文档把"解除阻塞更快"列为通知的首要卖点，量化对比见 13.8 节实验。

> [!tip] Vanilla 与 IDF 在队列锁协议上的分叉
> Vanilla 单核内核为了让"挂事件链表"这段操作确定化，给队列配了一套锁协议（`cRxLock/cTxLock` 计数 + 调度器挂起，临界区里不做链表操作）。IDF 的 SMP 改造干脆弃用了这套协议——queue.c 开头注释写明：SMP 实现本来就是非确定性的，直接用内核锁临界区替换队列锁，换更好的队列性能。所以在 ESP32 上，"通知 vs 队列"的差距主要就是**链表操作次数与对象簿记**，两条路径的锁代价倒是接近的（都用 `xKernelLock`）。

---

## 13.3 等待侧：xTaskNotifyWait 的进入清除与退出清除

### 1. 五个参数，两个掩码

```c
BaseType_t xTaskGenericNotifyWait( UBaseType_t uxIndexToWaitOn,
                                   uint32_t ulBitsToClearOnEntry,   /* 开始等之前清哪些位 */
                                   uint32_t ulBitsToClearOnExit,    /* 等到通知之后清哪些位 */
                                   uint32_t *pulNotificationValue,  /* 回读当前通知值，可 NULL */
                                   TickType_t xTicksToWait );       /* 超时 */
```

`task.h` 把它宏封装成 `xTaskNotifyWait(入口清除, 出口清除, 值指针, 超时)`。返回 `pdTRUE` 表示"收到了通知"，`pdFALSE` 表示超时。两个清除参数是这组 API 最容易用错的部分，先看源码再给用法：

- **进入清除**只在"确实要阻塞"时执行：进门发现状态不是 RECEIVED（没有未读通知），先把 `ulNotifiedValue &= ~ulBitsToClearOnEntry`，再置 WAITING。如果一进门就发现已有通知，**入口清除不会发生**，函数直接走"已有通知"分支返回。
- **退出清除**只在"确实收到通知"时执行：等到通知（状态为 RECEIVED）才做 `ulNotifiedValue &= ~ulBitsToClearOnExit`；超时返回则**不清**。无论哪种结局，最后都把状态复位为 NOT_WAITING。

### 2. 源码骨架：两段临界区，yield 在临界区内

```c
BaseType_t xTaskGenericNotifyWait( ... )
{
    taskENTER_CRITICAL( &xKernelLock );           /* ① 第一段：占位并阻塞 */
    {
        const BaseType_t xCurCoreID = portGET_CORE_ID();  /* 此时不可能被抢占，读核号才安全 */

        if( pxCurrentTCBs[ xCurCoreID ]->ucNotifyState[ uxIndexToWait ] != taskNOTIFICATION_RECEIVED )
        {
            pxCurrentTCBs[ xCurCoreID ]->ulNotifiedValue[ uxIndexToWait ] &= ~ulBitsToClearOnEntry;
            pxCurrentTCBs[ xCurCoreID ]->ucNotifyState[ uxIndexToWait ] = taskWAITING_NOTIFICATION;
            if( xTicksToWait > 0 )
            {
                prvAddCurrentTaskToDelayedList( xTicksToWait, pdTRUE );  /* 挂延时链表（超时记账） */
                portYIELD_WITHIN_API();          /* ← 在临界区内让出 CPU！ */
            }
        }
    }
    taskEXIT_CRITICAL( &xKernelLock );

    /* —— 能走到这里，说明任务已被唤醒（收到通知或超时），或本来就有未读通知 —— */

    taskENTER_CRITICAL( &xKernelLock );           /* ② 第二段：收尾（回读值 → 判定 → 复位） */
    {
        if( pulNotificationValue != NULL )
            *pulNotificationValue = pxCurrentTCBs[ xCurCoreID ]->ulNotifiedValue[ uxIndexToWait ];

        if( ...->ucNotifyState[ uxIndexToWait ] != taskNOTIFICATION_RECEIVED )
            xReturn = pdFALSE;                    /* 超时：不清值 */
        else {
            ...->ulNotifiedValue[ uxIndexToWait ] &= ~ulBitsToClearOnExit;
            xReturn = pdTRUE;                     /* 收到通知：退出清除 */
        }
        ...->ucNotifyState[ uxIndexToWait ] = taskNOT_WAITING_NOTIFICATION;
    }
    taskEXIT_CRITICAL( &xKernelLock );
    return xReturn;
}
```

两个初看反直觉的点，源码注释都给了答案：

1. **"查状态 + 置 WAITING + 挂延时链表"在同一个临界区里原子完成**——否则来自 ISR 的通知会落进检查与占位之间的缝隙而丢失；13.2 节"通知不丢"性质的实现保证就在这里。
2. **临界区内竟然可以 yield**。源码注释原话：所有端口都支持在临界区内 yield——有的立即切换，有的等临界区退出再切。Xtensa 属于后者：`portYIELD_WITHIN_API()` 的定义是 `esp_crosscore_int_send_yield(xPortGetCoreID())`——**给自己发一个软件中断**，此刻中断被关着，它会在 `taskEXIT_CRITICAL()` 恢复使能的瞬间触发，切换在那里完成（机制细节归 [[2026-08-26-freertos-deep-dive-ch7-context-switch-deep-dive|第七章]] 与 [[2026-08-26-freertos-deep-dive-ch17-xtensa-port-internals|第十七章]]）。

### 3. 两个掩码的三种典型配法

```c
/* 配法一：事件位风格（配合 eSetBits）：进门清历史位，出门不清——读出来自己判断 */
xTaskNotifyWait(BIT0 | BIT1,      /* entry: 清历史 */
                0,                /* exit:  不清 */
                &value, portMAX_DELAY);
if (value & BIT0) handle_rx();
if (value & BIT1) handle_tx();

/* 配法二：整值风格（配合 eSetValueWith*）：进门不清，出门全清——一次性取走的消息 */
xTaskNotifyWait(0, 0xFFFFFFFF, &msg, portMAX_DELAY);

/* 配法三：纯事件（配合 eNoAction）：掩码全 0，值从不参与，只当"叫醒铃" */
xTaskNotifyWait(0, 0, NULL, portMAX_DELAY);
```

记法：**进入清除决定"要不要干净地开始等"，退出清除决定"通知值要不要一次性消费掉"**。配错了通常不崩溃，而是多唤醒一次或少唤醒一次——排查时优先检查这两个参数。

### 4. ulTaskNotifyTake：计数信号量的贴身替身

对"纯计数"场景（原来用计数信号量的地方），`ulTaskNotifyTake()` 更顺手。它与 `xTaskNotifyWait()` 的差异在判断依据与消费方式：

- **阻塞条件看值不看状态**：`ulNotifiedValue == 0` 才阻塞（计数信号量语义：计数为 0 拿不到）；
- **返回旧值**，然后按 `xClearCountOnExit` 消费：`pdTRUE` 则清零（二值信号量风格），`pdFALSE` 则减 1（计数信号量风格）；没有任何清除掩码参数——它就是为计数而生的。

配对关系：发送端 `xTaskNotifyGive()`（= `eIncrement`）或 `vTaskNotifyGiveFromISR()`，接收端 `ulTaskNotifyTake()`。这一对加起来，覆盖二值/计数信号量在"单等待者"场景下的全部职能。

---

## 13.4 ISR 侧：xTaskNotifyFromISR 与延迟 yield

### 1. FromISR 版本的三处不同

`xTaskGenericNotifyFromISR()` 的动作部分（状态置 RECEIVED、switch 改值）与任务版一字不差，差异全在外围：

1. **临界区换成 `prvENTER_CRITICAL_OR_MASK_ISR()`**——ISR 安全版：保存并屏蔽当前中断状态，退出时恢复（SMP 实现下同样是拿 `xKernelLock`，第 18 章展开）；
2. **动链表前先过一道闸**：`taskCAN_BE_SCHEDULED(pxTCB)` 通过才直接"延时链表摘下 + 就绪链表挂上"；不通过（本核调度器正被挂起）就退而求其次，把目标任务的 `xEventListItem` 挂到 `xPendingReadyList[xCurCoreID]`（**每核一份**的待就绪链表），等 `xTaskResumeAll()` 恢复调度器时统一搬运。这是 FreeRTOS 全部 FromISR API 的通用防护（Vanilla 同样如此，只是它的 `xPendingReadyList` 是单个链表），通知只是又一次复用；
3. **yield 判定走同一套 SMP 逻辑**：`taskIS_YIELD_REQUIRED(pxTCB, pdFALSE)` 为真才把 `*pxHigherPriorityTaskWoken` 置 `pdTRUE` 并记入 `xYieldPending[xCurCoreID]`。

### 2. pxHigherPriorityTaskWoken 协议

第 3 点是中断里的标准协议——yield 决定权交还给用户：

```c
void IRAM_ATTR gpio_isr_handler(void *arg)
{
    BaseType_t higher_prio_woken = pdFALSE;
    xTaskNotifyFromISR(s_worker, 0x1, eSetBits, &higher_prio_woken);
    /* 更高优先级的任务被弄就绪了？请求退出中断时切换（Xtensa：软件中断形式的挂起切换） */
    if (higher_prio_woken == pdTRUE)
        portYIELD_FROM_ISR();
}
```

为什么不在 API 内部直接切？因为**中断退出本身就要走上下文切换路径**，从 ISR 深处直接调度会双重切换。把"是否需要切"的旗子递出来、在中断最外层收尾时统一处理，一次出入中断只切一次。就算你忘了检查这个参数，内核记在 `xYieldPending` 里的账也会在下一个 tick 被动结算——功能不坏，只是被唤醒的任务晚到最多一个 tick（默认 10ms）。正确写法永远是检查它。

还有一个跨核细节容易误读：13.6 节会看到 `prvIsYieldRequiredSMP()` 在"该让路的是另一个核"时会**当场发核间中断**并返回"本核不需要让"——此时 `pxHigherPriorityTaskWoken` 保持 `pdFALSE` 是正确的，切换发生在另一个核上。

### 3. 与任务版共同保障的"不丢"性质

把 13.3 节的等待路径与 FromISR 路径对齐：等待方在临界区内原子完成"查状态 + 置 WAITING"，发送方（任务或 ISR）在临界区内原子完成"改值 + 置 RECEIVED + 判断要不要搬任务"。两侧各自原子、合起来无窗口——通知先于等待到达则状态锁在 RECEIVED、等待方进门即返；等待先于通知则发送方看到 WAITING、当场解除阻塞。不存在第三种交错，这也是官方把通知推荐为 ISR→任务"首选轻量通道"的底气。

---

## 13.5 索引通知：一个任务多个信箱

### 1. 数组化的 API 族

13.2 节 TCB 定义里两个字段都是数组：`ulNotifiedValue[configTASK_NOTIFICATION_ARRAY_ENTRIES]`。每个下标（index）是一套完全独立的通知值 + 通知状态，互不干扰。于是 API 族分成两档：

| 默认下标版（最常用）       | 带下标版（Indexed）               |
| -------------------------- | --------------------------------- |
| `xTaskNotify()`            | `xTaskNotifyIndexed()`            |
| `xTaskNotifyWait()`        | `xTaskNotifyWaitIndexed()`        |
| `xTaskNotifyFromISR()`     | `xTaskNotifyIndexedFromISR()`     |
| `xTaskNotifyGive()`        | `xTaskNotifyGiveIndexed()`        |
| `ulTaskNotifyTake()`       | `ulTaskNotifyTakeIndexed()`       |
| `xTaskNotifyStateClear()`  | `xTaskNotifyStateClearIndexed()`  |
| `ulTaskNotifyValueClear()` | `ulTaskNotifyValueClearIndexed()` |

默认版全部是对 `tskDEFAULT_INDEX_TO_NOTIFY`（即 0）的宏封装——`task.h` 里 `xTaskNotify(task, val, action)` 展开就是 `xTaskGenericNotify((task), (tskDEFAULT_INDEX_TO_NOTIFY), (val), (action), NULL)`，其余同理。

### 2. 什么时候需要多个下标

单个 `uint32_t` 配 `eSetBits` 已经能表达 32 个事件位，那数组下标的存在价值是什么？**区分发送者与用途，避免位掩码管理**。典型场景：一个工作任务同时服务多个事件源——

```c
#define IDX_FROM_GPIO    0   /* 每个事件源一个专属信箱 */
#define IDX_FROM_TIMER   1

/* 发送方各用各的下标，互不知晓对方 */
xTaskNotifyIndexed(s_worker, IDX_FROM_GPIO,  0, eNoAction);
xTaskNotifyIndexed(s_worker, IDX_FROM_TIMER, 1, eIncrement);

/* 接收方轮询全部信箱，谁先到处理谁 */
for (;;) {
    for (int i = 0; i < IDX_COUNT; i++)
        if (xTaskNotifyWaitIndexed(i, 0, 0xFFFFFFFF, &v, 0) == pdTRUE)
            handle(i, v);
    /* 全空则睡在 0 号信箱上等 GPIO（简化示意） */
}
```

要注意的权衡：等待 API 一次只能等**一个**下标（没有"等任意信箱"的原语）。多个事件源要拼进一次阻塞时，要么用 `eSetBits` 共享下标 0，要么换第 12 章的事件组。数组的正确定位是"互不相干的几路点对点信箱"，不是多路复用等待器。

### 3. 成本与配置

上游 FreeRTOS.h 默认 `configTASK_NOTIFICATION_ARRAY_ENTRIES` 为 1——不为多信箱付一分钱冤枉钱。ESP-IDF 把它接进了 menuconfig：`Component config → FreeRTOS → configTASK_NOTIFICATION_ARRAY_ENTRIES`（Kconfig 选项 `FREERTOS_TASK_NOTIFICATION_ARRAY_ENTRIES`，取值 1~32，默认 1）。

每加一个下标，**每个任务的 TCB 增重 5 字节**（4 值 + 1 状态）——Kconfig 的 help 文本也提醒了这一点：加的是全系统所有任务的税。

---

## 13.6 Vanilla vs ESP-IDF：同一机制，两副骨架

先说相同：**索引通知（数组化）是上游 V10.4.0 引入的特性，IDF 的基线 v10.5.1 天然包含**——五种 `eAction`、三态状态机、数组下标，两个世界的动作语义完全一致。差异在骨架层（对照 Vanilla v10.5.1 与 IDF `FreeRTOS-Kernel/` 的 `tasks.c`）：

| 维度                | Vanilla FreeRTOS (v10.5.1)                                      | IDF FreeRTOS（默认树）                                                          |
| ------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 通知开关            | `configUSE_TASK_NOTIFICATIONS` 可配 0（省掉 TCB 字段）          | FreeRTOSConfig.h **硬编码为 1**，不可关                                         |
| 数组长度配置        | 手改 FreeRTOSConfig.h                                           | menuconfig `FREERTOS_TASK_NOTIFICATION_ARRAY_ENTRIES`（1~32）                   |
| 临界区              | `taskENTER_CRITICAL()`，关中断即可（单核天下）                  | `taskENTER_CRITICAL(&xKernelLock)`，关中断 **+ 内核自旋锁**                     |
| "当前任务"是谁      | 全局唯一的 `pxCurrentTCB`                                       | `pxCurrentTCBs[xCurCoreID]`——每核一个当前任务                                   |
| 发送后的 yield 判定 | 只与当前 CPU 比：`pxTCB->uxPriority > pxCurrentTCB->uxPriority` | `taskIS_YIELD_REQUIRED()` → `prvIsYieldRequiredSMP()`：**两核都看，先看当前核** |
| FromISR 的挂起缓冲  | 单个 `xPendingReadyList`                                        | 每核一份 `xPendingReadyList[configNUMBER_OF_CORES]`                             |
| 跨核通知            | 概念不存在                                                      | 常态：目标该在另一个核跑时发核间中断                                            |

`xKernelLock` 值得单独一提：它是 `tasks.c` 里一个全局的 `portMUX_TYPE`，IDF 把内核态的共享数据（就绪/延时链表、tick、通知字段……）全归这把自旋锁管。通知路径上每一次 `taskENTER_CRITICAL(&xKernelLock)`，在双核环境下都意味着"关本核中断 + 自旋等锁"——另一颗核若正拿着锁，本核就原地转圈。这是 SMP 化的统一税，第 18 章精确拆解。

最后一行的"跨核通知"是 SMP 语义的实质变化，把 `prvIsYieldRequiredSMP()` 的真实判定逻辑画出来：

```text
Core 0（发送方所在核）                             Core 1
────────────────────────────                    ────────────
task_a: xTaskNotify(task_b, ...)
  │
  ├─ 内核锁临界区内：
  │    改 task_b->ulNotifiedValue / ucNotifyState
  │    task_b 原状态是 WAITING → 摘延时链表、挂就绪链表
  │
  └─ prvIsYieldRequiredSMP(task_b)：
       ① task_b 亲和允许本核，且优先级 > 本核当前任务？
            是 → 本核让路（偏向当前核：省一次跨核开销）
       ② 否则：亲和允许另一核，且优先级 > 另一核当前任务？
            是 → vPortYieldOtherCore(1)：核间中断 ─→ 立刻抢占，切换到 task_b
       ③ 都不满足 → 不 yield（task_b 排队等调度）
```

两核都对等扫描、**先问当前核**——能用本核解决就不跨核，这是"高优先级任务就绪且多核可抢占时调度器偏向当前核"这条系列事实在通知路径上的具体形状。`vPortYieldOtherCore()` 底层是 ESP32 的 cross-core interrupt（第 23 章的主角）——**在 ESP32 上，核 0 的一个 `xTaskNotify()` 可以在微秒级把钉在核 1 的高优先级任务拉起来**，这是 Vanilla 单核世界里不存在的能力维度。

> [!tip] 一句话对照
> 动作语义完全一致（五种 eAction、三态状态机、数组下标两边都有）；不同的是"谁被允许被叫醒、怎么叫"——Vanilla 只会跟当前 CPU 比，IDF 两核都对等地看，先偏当前核，必要时跨核开枪，且全程持内核自旋锁。

---

## 13.7 选型：通知 vs 信号量 vs 队列

### 1. 选型表

| 维度         | 任务通知                                      | 二值/计数信号量   | 队列                      |
| ------------ | --------------------------------------------- | ----------------- | ------------------------- |
| 携带数据     | 单个 `uint32_t`（数组下标可扩多路）           | 无（纯计数/门闸） | 任意类型 × N 项，逐项拷贝 |
| 等待者数量   | **1（目标任务本人）**                         | 多个              | 多个                      |
| 缓冲能力     | 无（深度 1：覆盖或拒写，`eIncrement` 可累加） | 计数累积（≤ max） | N 项 FIFO                 |
| ISR 参与发送 | ✓（FromISR 族）                               | ✓                 | ✓                         |
| ISR 参与接收 | ✗（ISR 不能等，任何对象皆然）                 | ✗                 | ✗                         |
| 优先级继承   | ✗                                             | 互斥量 ✓          | ✗                         |
| RAM 开销     | 每任务 5B（内嵌）                             | 每对象 ~76B       | 每对象 ~76B + N×itemSize  |
| 速度         | 最快（少两次链表操作、零分配、零拷贝）        | 中                | 中（多一次数据拷贝）      |
| 解耦程度     | **紧耦合**：发送方须持目标任务句柄            | 松：匿名句柄      | 松：匿名 rendezvous       |
| 典型场景     | 中断→任务唤醒、点对点事件/值/计数             | 资源门闸、同步点  | 生产者-消费者数据流       |

实践口诀：**能一对一就先想通知；要多个等待者或要缓冲数据流才上队列；要做互斥只能上互斥量**。ESP-IDF 自家的很多驱动也用通知做 ISR→任务的唤醒，这个模式值得内化成默认反射。

### 2. 硬限制：一对一的世界

通知的四条天花板，每条都对应一个"别用通知"的信号：

1. **只有一个等待者**。"多个任务等同一个事件"在通知模型里无法表达——信箱是 TCB 私有的，第二个任务没有钥匙。要广播/多等待 → 第 12 章事件组。
2. **没有队列缓冲**。两个值先后来到，`eSetValueWithOverwrite` 只留最后一个、`eSetValueWithoutOverwrite` 拒绝第二个（返回 `pdFAIL`，**调用方必须检查返回值**，否则静默丢消息）、`eIncrement` 把它们坍缩成计数 2。要"先来的先处理、内容不丢" → 队列，或第 14 章的消息缓冲。
3. **不能给 ISR 发通知**（ISR 无法阻塞等待）。方向只有任务→任务和 ISR→任务。
4. **没有优先级继承**。它压根不是锁，别拿它保护共享资源——那是互斥量（第 11 章）的职责。

另有两个行为细节，不知道就会在极端场景下困惑：

- **挂起会作废等待**：对正在等通知的任务调 `vTaskSuspend()`，内核会把它的 WAITING 状态清回 NOT_WAITING（`vTaskSuspend()` 里有一段专门循环扫描全部下标做这件事），等通知的阻塞随之作废——任务恢复运行后 `xTaskNotifyWait()` 以 `pdFALSE` 返回，**剩余超时作废**，即使 `xTicksToWait` 还没走完。反过来，任务被挂起期间收到的通知会正常把状态置成 RECEIVED、值照常更新，任务恢复后一进门就能取到。
- **状态会被查任务的工具如实报告**：`vTaskGetInfo()` 对"正在等通知"的任务报 `eBlocked` 而不是 `eSuspended`——`eTaskGetState()` 里专门扫描全部下标的 `ucNotifyState` 来区分这两者（第 24 章调试时有用）。

还有一个启动期经典坑：任务首次进入等待循环**之前**通知就到了（外设初始化即触发一次中断），状态锁在 RECEIVED，第一次 `xTaskNotifyWait()` 立刻返回——大多数时候这正是不丢事件的优点；若业务上不接受这种"历史通知"，在任务启动时先 `xTaskNotifyStateClear(NULL)` 清一次即可。

---

## 13.8 实验：ping-pong 切换延迟对比

本实验测一个最纯粹的量：**两个同优先级任务互相"发球"一次的手递手（handoff）延迟**——通知版 vs 二值信号量版。两个任务钉在同一个核上，每次发球必然伴随一次上下文切换，量出来的就是"IPC 原语 + 切换"的完整往返成本。

### 1. 代码

```c
#include <stdio.h>
#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_timer.h"

#define ITER 10000
#define PRIO 4
#define CORE 0            /* 钉同一个核：每次发球必切换一次 */

static TaskHandle_t      s_ta, s_tb;
static SemaphoreHandle_t s_sem;
static volatile bool     s_done;
static int64_t           s_t0, s_t1;

static void bench_a(void *arg)      /* 发起方：计时并在结束后汇报 */
{
    int notify = (int)(intptr_t)arg;
    s_t0 = esp_timer_get_time();
    for (int i = 0; i < ITER; i++) {
        if (notify) {
            xTaskNotify(s_tb, 0, eNoAction);
            xTaskNotifyWait(0, 0, NULL, portMAX_DELAY);   /* 接球 */
        } else {
            xSemaphoreGive(s_sem);
            xSemaphoreTake(s_sem, portMAX_DELAY);         /* 接球 */
        }
    }
    s_t1 = esp_timer_get_time();
    printf("[%s] %d handoffs in %lld us -> %.2f us/handoff\n", notify ? "notify" : "semaph",
           ITER * 2, s_t1 - s_t0, (double)(s_t1 - s_t0) / (2.0 * ITER));
    s_done = true;
    vTaskDelete(NULL);
}

static void bench_b(void *arg)      /* 回球方 */
{
    int notify = (int)(intptr_t)arg;
    for (int i = 0; i < ITER; i++) {
        if (notify) {
            xTaskNotifyWait(0, 0, NULL, portMAX_DELAY);
            xTaskNotify(s_ta, 0, eNoAction);
        } else {
            xSemaphoreTake(s_sem, portMAX_DELAY);
            xSemaphoreGive(s_sem);
        }
    }
    vTaskDelete(NULL);
}

void app_main(void)
{
    printf("== ping-pong pinned to core %d, %d iterations/phase ==\n", CORE, ITER);

    for (int notify = 1; notify >= 0; notify--) {   /* 先通知阶段，后信号量阶段 */
        s_done = false;
        if (!notify)
            s_sem = xSemaphoreCreateBinary();
        xTaskCreatePinnedToCore(bench_a, "bench_a", 2048, (void *)(intptr_t)notify,
                                PRIO, &s_ta, CORE);
        xTaskCreatePinnedToCore(bench_b, "bench_b", 2048, (void *)(intptr_t)notify,
                                PRIO, &s_tb, CORE);
        while (!s_done)
            vTaskDelay(1);          /* app_main 让出 CPU 等本阶段结束 */
        vTaskDelay(2);
    }
}
```

两个实现刻意做成镜像：通知版 `xTaskNotify`/`xTaskNotifyWait`，信号量版 `xSemaphoreGive`/`xSemaphoreTake`，其余条件（优先级、绑核、循环次数）完全一致——差异全部来自两条内核路径本身。还有一个刻意的设计：两任务**同优先级**，而 yield 判定要求严格更高优先级才抢占（13.6 节的 `>`），所以发送本身不触发切换，每次切换都由发送方紧接着的阻塞完成——两条路径的测量完全对称。

### 2. 运行

```bash
idf.py qemu monitor
```

输出形如（**绝对数值随宿主机与 QEMU 版本浮动很大，两行的相对差距才是有效信号**；真机上输出稳定得多）：

```text
== ping-pong pinned to core 0, 10000 iterations/phase ==
[notify] 20000 handoffs in 35184 us -> 1.76 us/handoff
[semaph] 20000 handoffs in 54210 us -> 2.71 us/handoff
```

### 3. 解读

1. **差距的来源就是 13.2.4 节的账**：每次"发球+接球"各走一遍原语，通知路径每遍少两次链表操作（事件链表的有序插入与摘除）、少一次 `Queue_t` 簿记与消息拷贝，观察到的 30%~45% 差距就是这部分结构性省减的价格。
2. **官方口径可以互相印证**：FreeRTOS 官方文档对"用通知替代二值信号量直接通知场景"给出的量级是解除阻塞路径约快 45%。若你量出的差距小得反常，先检查两任务是否真的钉在同一核——跨核跑会把核间中断的固定开销掺进来，掩盖原语本身的差异。
3. **真机验证**：同一程序在 ESP32 DevKitC（240MHz）上跑，把命令换成 `idf.py -p /dev/ttyUSB0 flash monitor`，代码零修改；典型结果是两者都在 1~2µs/handoff 量级，通知稳定更快、方差更小。
4. **量级感**：哪怕慢的那个也只有几微秒——"快"不是选通知的第一理由，**零对象、零注册、一对一刚好贴合**才是，快是白送的；但若热路径每秒发几十万次 IPC，这几十个百分点就是实打实的 CPU 预算。

### 4. 扩展实验（留给你）

把宏 `CORE` 改成 `tskNO_AFFINITY`，或两个任务分别钉到核 0/核 1：ping-pong 变成跨核往返，通知路径会经过 13.6 节的 `prvIsYieldRequiredSMP()` + 核间中断，单次延迟上升到几微秒级且方差明显变大——那就是第 23 章的开场实验。

---

## 13.9 小结

- 通知的设计动机：多数 IPC 是"点对点叫醒 + 一个 `uint32_t`"，为它付出 ~76B 的 `Queue_t`、两个事件链表和锁协议不划算。通知把信箱内嵌进 TCB：`ulNotifiedValue[]` + `ucNotifyState[]`，默认每任务 5 字节，零分配、零生命周期。
- 状态机三态（NOT_WAITING/WAITING/RECEIVED）与值操作五种动作（`eNoAction`/`eSetBits`/`eIncrement`/`eSetValueWithOverwrite`/`eSetValueWithoutOverwrite`）正交组合出发送侧全部行为；`xTaskGenericNotify()` 一次内核锁临界区完成，只有目标正在 WAITING 才动链表——且断言保证等通知的任务从不上事件链表。
- `xTaskNotifyWait()` 是两段临界区：第一段原子地"查状态+置 WAITING+挂延时链表+yield"（Xtensa 的 yield 是发给自己的软件中断，临界区退出时起爆），第二段收尾；进入清除只在没有未读通知时发生、退出清除只在真正收到时发生。`ulTaskNotifyTake()` 是计数信号量的贴身替身。FromISR 版本把 yield 决定权交给 `pxHigherPriorityTaskWoken` 协议，调度器挂起时经每核一份的 `xPendingReadyList[]` 延迟搬运。
- 索引通知（上游 V10.4.0 引入，两边基线都有）让一个任务拥有多路独立信箱，menuconfig 可扩到 32 路，每路每任务 5B；但没有"一次等任意下标"的原语。
- Vanilla vs IDF：动作语义一致，骨架不同——IDF 强制开启通知、Kconfig 化数组长度、临界区持全局内核自旋锁 `xKernelLock`、`pxCurrentTCBs[]` 每核一个当前任务、`prvIsYieldRequiredSMP()` 两核对等扫描且偏向当前核、必要时 `vPortYieldOtherCore()` 核间中断抢占另一核上的目标任务。
- 硬限制四条：单等待者、无队列缓冲（深度 1）、不能发往 ISR、无优先级继承。选型口诀：**能一对一先想通知；多等待者或多事件位→事件组；要缓冲数据流→队列；要互斥→互斥量**。
- 实验：同核同优先级 ping-pong，通知与信号量每次手递手差 30%~45%（结构来源：少两次链表操作），绝对值仅几微秒——选通知看中的是贴合度，快是白送的。

下一章离开"值"的世界，进入"流"的世界：`stream_buffer.c` 的流缓冲与消息缓冲——FreeRTOS 最年轻的 IPC 成员，用"单读单写"的约束换来近乎无锁的零拷贝式传递，是通知（事件）与队列（数据）之间的第三条路。见 [[2026-08-26-freertos-deep-dive-ch14-stream-message-buffers|第十四章]]。
