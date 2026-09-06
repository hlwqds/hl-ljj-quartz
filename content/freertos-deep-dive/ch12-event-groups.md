---
title: "FreeRTOS 深度解析（十二）：事件组"
date: 2026-08-26
description: "拆解 event_groups.c：EventBits_t 与 EventGroup_t 的结构、控制位如何借道 TCB 事件链表项传递、xEventGroupSetBits 的逐项匹配与延迟清位、xEventGroupWaitBits 的任一/全部语义与超时竞态处理、xEventGroupSync 双向会合的两阶段协议，以及 Vanilla 与 IDF fork 在临界区实现上的分野。"
tags: [freertos, rtos, esp32, esp-idf, qemu, event-groups, ipc, synchronization]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 12. **第十二章：事件组：多事件同步点**

# FreeRTOS 深度解析（十二）：事件组

前两章拆了 `queue.c`：队列搬运数据，信号量与互斥量是队列的退化形态。它们共享一个隐含假设——**每次交互围绕一件事**：一条消息、一个令牌、一把锁。本章的主角 `event_groups.c`（IDF fork 树中约 850 行）专治另一类问题：**多个独立事件的聚合与同步**——"温度采完了、湿度也采完了，才允许上传一批数据"，用信号量你得数令牌、还得防多消费；用事件组，一句话：等两个位都置位。事件组在数据结构上比队列简单得多（一个整数加一条链表），全部精巧都在**把等待条件编码进 TCB 的事件链表项**这一招上；同时它也是观察 Vanilla 与 IDF fork **锁模型分野**的最佳标本——同一个算法，两棵树用完全不同的方式保护。

---

## 12.1 为什么需要事件组：单事件原语的极限

### 1. 队列/信号量语义哪里不够

回顾[[ch10-queue-universal-ipc|第十章]]（队列）与[[ch11-semaphore-mutex-priority-inheritance|第十一章]]（信号量与互斥量）的对象，它们的交互模式都是"单事件 + 消费式"：

| 维度       | 队列           | 二值/计数信号量  | 事件组                                   |
| ---------- | -------------- | ---------------- | ---------------------------------------- |
| 表达的信息 | 一条数据       | 一个计数（0..N） | N 个独立布尔位                           |
| 唤醒语义   | 唤醒一个接收者 | 唤醒一个等待者   | **一次置位可唤醒任意多个等待者**（广播） |
| 是否消费   | 取走即消失     | take 即减计      | **位不因被等待而消失**（除非显式清除）   |
| 等待条件   | "有数据"       | "计数>0"         | 任一位 / 全部位（两种模式）              |
| 传递数据   | 能             | 不能             | 不能（只有位图）                         |

两个结构性缺口促成了事件组：

1. **聚合条件**。"A 或 B 先到"（any）、"A 和 B 都到"（all）——信号量做 any 要两个 take，做 all 要自己维护一个计数器，而计数器的读写又需要额外的保护（回到裸机时代的人肉纪律）。
2. **一对多广播**。队列和信号量每次只放行一个等待者；事件组一次 `xEventGroupSetBits()` 可以把等待链表上所有满足条件的任务一起唤醒，且每个人都能从返回值里看到"事件发生那一刻"的完整位图。

典型场景：多传感器就绪聚合（等"温度位 + 湿度位"都置位再打包上传）、多模块初始化同步（驱动各自置位，主任务等全部位后进入工作态）、任务会合（`xEventGroupSync()` 的本职，12.6 节）、事件路由（一个位图携带多路事件状态，按返回位分派处理者）。

> [!note] 一句话定位
> 队列回答"发生了什么"（带数据），信号量回答"能不能进"（带计数），事件组回答"哪几件事已经发生"（带位图）。需要**同时观察多个独立事件的组合状态**时，事件组是唯一原生选择。

---

## 12.2 数据结构：24 个事件位与一条等待链表

### 1. EventBits_t：为什么只有 24 个可用位

事件位类型就是 `TickType_t`（`event_groups.h` 中一行 `typedef`）。这是一个"历史搭便车"式的设计：内核已经保证 `TickType_t` 的宽度可配置，事件组顺带继承。代价是**最高字节被内核征用**，不能当事件位用：

```c
/* event_groups.c（32 位 tick 配置，ESP-IDF 默认） */
#define eventCLEAR_EVENTS_ON_EXIT_BIT    0x01000000UL  /* 等待者要求：唤醒后清位   */
#define eventUNBLOCKED_DUE_TO_BIT_SET    0x02000000UL  /* 内核标记：因置位而被唤醒 */
#define eventWAIT_FOR_ALL_BITS           0x04000000UL  /* 等待者要求：全部位语义   */
#define eventEVENT_BITS_CONTROL_BYTES    0xff000000UL  /* 控制字节掩码             */
```

于是 `configUSE_16_BIT_TICKS == 0`（ESP-IDF 默认，32 位 tick）时可用事件位是 **bit 0 ~ bit 23 共 24 个**；16 位 tick 配置下只剩 8 个。还有一位另有用途：`tasks.c` 中的 `taskEVENT_LIST_ITEM_VALUE_IN_USE`（32 位配置下为 `0x80000000UL`），标记事件链表项的值当前承载的是"有意义的数据"而非游离状态。

四个控制位不是存在事件组里的，而是**打包进每个等待任务的链表项值里**随任务游走——这是下一小节的主角。

### 2. EventGroup_t：本体小得惊人

```c
/* event_groups.c（IDF fork 树，节选自真实结构体） */
typedef struct EventGroupDef_t
{
    EventBits_t uxEventBits;          /* 位图本体：24 个事件位            */
    List_t xTasksWaitingForBits;      /* 等待链表：所有阻塞中的等待者     */

    /* 另有条件编译的 uxEventGroupNumber(trace) / ucStaticallyAllocated 字段 */

    portMUX_TYPE xEventGroupLock;     /* ← IDF 独有：每对象一个自旋锁     */
} EventGroup_t;
```

Vanilla v10.5.1 的同名结构体到 `ucStaticallyAllocated` 为止。IDF fork 多出的 `portMUX_TYPE xEventGroupLock` 是双核改造的直接产物——12.7 节会看到它如何替换 Vanilla 的调度器挂起方案。

### 3. 关键机关：链表项值是设置者与等待者之间的信箱

第 5 章讲过每个 TCB 内嵌两个链表项：`xStateListItem` 挂状态链表（就绪/阻塞/挂起），`xEventListItem` 挂内核对象的事件链表。事件组把 `xEventListItem` 的**项值（item value）当成了双向信箱**：

```text
等待者阻塞时（写入①，诉求）：
  vTaskPlaceOnUnorderedEventList( &xTasksWaitingForBits,
        uxBitsToWaitFor | uxControlBits, xTicksToWait );
  itemValue = [等待位掩码 | CLEAR_ON_EXIT? | WAIT_FOR_ALL?]

设置者命中时（写入②，回执）：
  vTaskRemoveFromUnorderedEventList( pxListItem,
        uxEventBits | eventUNBLOCKED_DUE_TO_BIT_SET );
  itemValue = [唤醒时刻的位图 | UNBLOCKED_DUE_TO_BIT_SET]

等待者醒来后（读取回执）：
  uxReturn = uxTaskResetEventItemValue();
```

设置者遍历等待链表时，从每个项值里**拆出控制字节**判断该任务等的是"任一"还是"全部"、要不要清位；命中后把唤醒时刻的位图连同 `eventUNBLOCKED_DUE_TO_BIT_SET` 写回项值。等待者醒来后用 `uxTaskResetEventItemValue()` 取走这个值，靠那个标记位区分"因置位而醒"还是"超时而醒"——整套机制没有用到事件组结构体之外的任何存储。顺带说明：`vTaskPlaceOnUnorderedEventList()` / `vTaskRemoveFromUnorderedEventList()` 是 `tasks.c` 专为事件组开的两个后门（源码注释明言 "It is used by the event flags implementation"），与队列走的有序事件链表不同——**不按唤醒时间排序**，挂链表尾即可，超时统一交给延迟链表（`prvAddCurrentTaskToDelayedList`）。两个函数入口都有 `configASSERT( uxSchedulerSuspended != 0 )`：调用前必须先持有某种独占权，这正是 12.7 节的主题。

---

## 12.3 创建：xEventGroupCreate

动态创建只有三步，没有任何惊喜：

```c
/* event_groups.c，IDF fork 树 */
EventGroupHandle_t xEventGroupCreate( void )
{
    EventGroup_t * pxEventBits = pvPortMalloc( sizeof( EventGroup_t ) );
    if( pxEventBits != NULL )
    {
        pxEventBits->uxEventBits = 0;
        vListInitialise( &( pxEventBits->xTasksWaitingForBits ) );
        portMUX_INITIALIZE( &pxEventBits->xEventGroupLock );   /* IDF 独有 */
    }
    return pxEventBits;
}
```

静态版本 `xEventGroupCreateStatic()` 接受应用提供的 `StaticEventGroup_t`（与真实结构体等大等对齐，`configASSERT` 运行时校验），多一步标记 `ucStaticallyAllocated = pdTRUE` 供 `vEventGroupDelete()` 决定要不要 `vPortFree`；内存来源与堆组件的关系见第 19、20 章。

API 全家福（本章按此展开）：

| API                                     | 语义                                                                       | 可否 ISR              |
| --------------------------------------- | -------------------------------------------------------------------------- | --------------------- |
| `xEventGroupCreate` / `...CreateStatic` | 创建                                                                       | 否                    |
| `xEventGroupSetBits`                    | 置位（OR）并唤醒匹配者                                                     | 否（用 `...FromISR`） |
| `xEventGroupClearBits`                  | 清位，返回清除前的值                                                       | 否（用 `...FromISR`） |
| `xEventGroupGetBits`                    | 读位图：实为宏 `xEventGroupClearBits(eg, 0)`——借清零个位搭车在临界区里读值 | 否（用 `...FromISR`） |
| `xEventGroupWaitBits`                   | 测试 + 可选阻塞（任一/全部）                                               | 否                    |
| `xEventGroupSync`                       | 双向会合                                                                   | 否                    |
| `vEventGroupDelete`                     | 删除并唤醒全部等待者                                                       | 否                    |

---

## 12.4 xEventGroupSetBits 源码走读

这是全章的核心函数。任务语境下的完整逻辑（IDF fork 树，注释为笔者所加）：

```c
EventBits_t xEventGroupSetBits( EventGroupHandle_t xEventGroup,
                                const EventBits_t uxBitsToSet )
{
    ...
    pxList = &( pxEventBits->xTasksWaitingForBits );
    pxListEnd = listGET_END_MARKER( pxList );

    prvENTER_CRITICAL_OR_SUSPEND_ALL( &( pxEventBits->xEventGroupLock ) );   /* ① */
    #if ( configNUMBER_OF_CORES > 1 )
        prvTakeKernelLock();               /* IDF：遍历内核链表前的额外保护 */
    #endif
    {
        pxListItem = listGET_HEAD_ENTRY( pxList );

        pxEventBits->uxEventBits |= uxBitsToSet;          /* ② 置位就是 OR */

        while( pxListItem != pxListEnd )                  /* ③ 遍历等待链表 */
        {
            pxNext = listGET_NEXT( pxListItem );          /* ④ 先取 next！ */
            uxBitsWaitedFor = listGET_LIST_ITEM_VALUE( pxListItem );
            xMatchFound = pdFALSE;

            uxControlBits = uxBitsWaitedFor & eventEVENT_BITS_CONTROL_BYTES;
            uxBitsWaitedFor &= ~eventEVENT_BITS_CONTROL_BYTES;

            if( ( uxControlBits & eventWAIT_FOR_ALL_BITS ) == 0 )
            {
                /* 任一语义：交集非空即命中 */
                if( ( uxBitsWaitedFor & pxEventBits->uxEventBits ) != 0 )
                    xMatchFound = pdTRUE;
            }
            else if( ( uxBitsWaitedFor & pxEventBits->uxEventBits ) == uxBitsWaitedFor )
            {
                /* 全部语义：等待掩码被完全覆盖才命中 */
                xMatchFound = pdTRUE;
            }

            if( xMatchFound != pdFALSE )
            {
                if( ( uxControlBits & eventCLEAR_EVENTS_ON_EXIT_BIT ) != 0 )
                {
                    uxBitsToClear |= uxBitsWaitedFor;     /* ⑤ 暂记，不清！ */
                }
                /* ⑥ 写回执 + 移出事件链表 + 摘出延迟链表 + 进就绪链表 */
                vTaskRemoveFromUnorderedEventList( pxListItem,
                        pxEventBits->uxEventBits | eventUNBLOCKED_DUE_TO_BIT_SET );
            }
            pxListItem = pxNext;                          /* ⑦ 用预取的 next */
        }

        pxEventBits->uxEventBits &= ~uxBitsToClear;        /* ⑧ 循环后才统一清位 */
    }
    #if ( configNUMBER_OF_CORES > 1 )
        prvReleaseKernelLock();
    #endif
    ( void ) prvEXIT_CRITICAL_OR_RESUME_ALL( &( pxEventBits->xEventGroupLock ) );

    return pxEventBits->uxEventBits;                      /* 返回最终位图 */
}
```

五个值得停下来咀嚼的细节：

### 1. 置位是纯 OR；判定逐人进行；next 必须预取

- `uxEventBits |= uxBitsToSet` 一句完成置位，之后**用同一个位图快照逐个测试所有等待者**。同一事件组上可以同时挂着"等任一位"和"等全部位"的混合等待者，互不干扰——判定逻辑从各自链表项值的控制字节里来。
- `vTaskRemoveFromUnorderedEventList()` 会把 `pxListItem` 从事件链表摘下、挂进就绪体系，摘链后 `pxListItem->pxNext` 指向的是就绪链表的邻居。所以**进入循环体第一件事就是保存 `pxNext`**，遍历指针永远走预存值——读内核链表代码时反复出现的模式（第 6 章 `tasks.c` 同款）。

### 2. 步骤⑤⑧：延迟清位——一次唤醒，人人看到同一快照

`xClearOnExit` 的位清除**不发生在命中处，而是累计到 `uxBitsToClear`，整个遍历结束后一次性执行**。效果有两个：

- 同一次 `SetBits` 唤醒的所有等待者，回执里写的是**同一份位图快照**（步骤⑥传入的 `pxEventBits->uxEventBits` 在遍历期间不被清位破坏）；
- 清位动作本身不会在遍历中途改变位图、进而影响后续等待者的判定。

这就是"清位时机"问题的准确答案：**清位发生在所有匹配者都被唤醒之后**，且由设置者一方（而非等待者一方）完成。源码里并不存在名为 `prvTestAndClear` 之类的帮助函数——测试与清除是保护区内的两段显式代码，测试在遍历中，清除在遍历后。

### 3. 唤醒、切换与返回值的三个次序事实

- `vTaskRemoveFromUnorderedEventList()` 内部（SMP 分支）在临界区里调 `prvYieldForTask()` 标记目标核需要切换，**切换不发生在持锁期间**；被唤醒者优先级不够就平稳返回，够则调用者出锁后很快被抢占（第 6~8 章）。
- 事件组是**电平语义而非边沿语义**：位置上后一直保持，直到有人清除。没有等待者时 `SetBits` 退化为一次加锁的 `|=`；后来者的 `WaitBits` 在入口快路径直接命中（12.5 节），不丢事件。
- 步骤⑧在 return 之前执行：返回的位图**已扣掉 `uxBitsToClear`**。想拿"刚置上的位"用入参自己记，别依赖返回值。

### 4. ISR 不能直接调它

遍历等待链表的长度不受限，`SetBits` 是**非确定性操作**。FreeRTOS 铁律：ISR 里只允许确定性操作。于是 `xEventGroupSetBitsFromISR()` 的实现是把真活儿打包给定时器守护任务：`xTimerPendFunctionCallFromISR( vEventGroupSetBitsCallback, ... )`——中断里只是入队一个函数调用请求，真正的置位与唤醒发生在守护任务语境（第 15 章拆解这条管道）。`xEventGroupClearBitsFromISR` 同理（注意它没有 `pxHigherPriorityTaskWoken` 参数——清位不唤醒任何人）。这两个 FromISR 版本的编译受 `configUSE_TIMERS`、`INCLUDE_xTimerPendFunctionCall`、`configUSE_TRACE_FACILITY` 等开关控制。

---

## 12.5 xEventGroupWaitBits：条件判定、阻塞与超时竞态

### 1. prvTestWaitCondition：任一/全部的全部秘密

两种等待模式的判定浓缩在一个八行小函数里，前面 SetBits 走读里的判定就是它的翻版：

```c
static BaseType_t prvTestWaitCondition( const EventBits_t uxCurrentEventBits,
                                        const EventBits_t uxBitsToWaitFor,
                                        const BaseType_t xWaitForAllBits )
{
    BaseType_t xWaitConditionMet = pdFALSE;
    if( xWaitForAllBits == pdFALSE )
    {
        if( ( uxCurrentEventBits & uxBitsToWaitFor ) != 0 )   /* 交集非空 */
            xWaitConditionMet = pdTRUE;
    }
    else
    {
        if( ( uxCurrentEventBits & uxBitsToWaitFor ) == uxBitsToWaitFor ) /* 全覆盖 */
            xWaitConditionMet = pdTRUE;
    }
    return xWaitConditionMet;
}
```

### 2. 三条执行路径

`xEventGroupWaitBits( xEventGroup, uxBitsToWaitFor, xClearOnExit, xWaitForAllBits, xTicksToWait )` 在保护区（IDF fork：本组自旋锁临界区）内三分叉：

```text
xEventGroupWaitBits( xEventGroup, uxBitsToWaitFor, xClearOnExit,
                     xWaitForAllBits, xTicksToWait )   ── 保护区（IDF：本组自旋锁）内 ──

  prvTestWaitCondition( 当前位图, 等待掩码, 任一/全部 ) 命中？
  ├─ 是 →【快路径】返回当前位图；xClearOnExit ? 位图 &= ~等待掩码
  └─ 否 → xTicksToWait == 0 ?
          ├─ 是 →【轮询】返回当前位图（标记超时）
          └─ 否 →【阻塞】itemValue = 等待掩码 | 控制位(CLEAR?/ALL?)
                   挂 xTasksWaitingForBits 尾 + 进延迟链表
                   出锁 → portYIELD_WITHIN_API() → 沉睡…
                   醒来: uxTaskResetEventItemValue() 取回执，剥控制字节
```

快路径里的清位值得注意：它清的是**整个等待掩码**，包括掩码里本来就没置位的位（对 0 清零是空操作，无害）。这带出一个高频意外：**任一模式下 `xClearOnExit = pdTRUE` 会把掩码内所有位一起清掉**，不只是触发唤醒的那一位。等 `BIT_0 | BIT_1`、被 `BIT_0` 唤醒时，`BIT_1` 若恰好同时置位也会被清——想保留就需要 `xClearOnExit = pdFALSE` 加手工清理。

### 3. 超时路径的二次检查：一个真实竞态的善后

阻塞路径醒来后，若回执里**没有** `eventUNBLOCKED_DUE_TO_BIT_SET`，说明是超时叫醒的。天真写法是直接返回当前位图完事，但源码多做了一步（`taskENTER_CRITICAL` 之下）：

```c
uxReturn = pxEventBits->uxEventBits;
/* 超时醒来与真正上 CPU 之间，别的任务可能恰好把位置上了 */
if( prvTestWaitCondition( uxReturn, uxBitsToWaitFor, xWaitForAllBits ) != pdFALSE )
{
    if( xClearOnExit != pdFALSE )
        pxEventBits->uxEventBits &= ~uxBitsToWaitFor;
}
```

竞态窗口在哪：超时到期（tick 中断把任务摘出延迟链表，第 9 章）到任务重新上 CPU 之间，另一核/另一任务可能执行了 `SetBits` 并满足了条件。若不补查，调用者会拿到"条件满足的位图"却被告知超时，且 `xClearOnExit` 的清位约定被打破。这段补查把"醒来后位图已满足"的情形按满足处理——清位、返回位图，语义闭环。这是内核里"检查—行动必须同区"原则的典型善后写法，值得抄进自己的代码库。

### 4. 返回值语义速查

条件满足（含快路径与被唤醒）时返回**唤醒/检查时刻、清位之前**的位图；超时且补查不满足时返回超时时刻的位图（诊断哪些位缺着）；`xTicksToWait = 0` 且不满足时返回当前位图（纯轮询用法）。所有返回值都剥掉了控制字节（`uxReturn &= ~eventEVENT_BITS_CONTROL_BYTES`）。

---

## 12.6 xEventGroupSync：双向会合

### 1. 为什么"先设位再等待"会翻车

会合需求：任务 A、B 各自干完活，**都到达同步点后才能一起继续**。直觉写法：

```c
/* 反例：两个步骤之间存在竞态 */
xEventGroupSetBits( eg, MY_BIT );                    /* 步骤一：亮牌 */
xEventGroupWaitBits( eg, ALL_BITS, pdTRUE, pdTRUE,
                     portMAX_DELAY );                /* 步骤二：等齐 */
```

问题：步骤一与步骤二之间没有原子性。设想 A 先亮牌、B 随后亮牌并从 `WaitBits` 满足返回、清掉全部位；此时 A 才执行 `WaitBits`，看到的是已被清空的位图，永远等不齐。用"先 Wait 后 Set"换序同样有窗口。**设位与条件判定必须在同一保护区里完成**——这正是 `xEventGroupSync` 存在的理由。

### 2. 两阶段实现

```c
EventBits_t xEventGroupSync( EventGroupHandle_t xEventGroup,
                             const EventBits_t uxBitsToSet,     /* 自己的牌   */
                             const EventBits_t uxBitsToWaitFor, /* 等齐的牌   */
                             TickType_t xTicksToWait )
{
    prvENTER_CRITICAL_OR_SUSPEND_ALL( &pxEventBits->xEventGroupLock );  /* ① 全程持锁 */
    {
        uxOriginalBitValue = pxEventBits->uxEventBits;   /* ② 先存旧值！ */
        ( void ) xEventGroupSetBits( xEventGroup, uxBitsToSet );        /* ③ 亮牌   */

        if( ( ( uxOriginalBitValue | uxBitsToSet ) & uxBitsToWaitFor ) == uxBitsToWaitFor )
        {
            /* ④ 我是最后到的：条件已齐，不阻塞 */
            uxReturn = ( uxOriginalBitValue | uxBitsToSet );
            pxEventBits->uxEventBits &= ~uxBitsToWaitFor;  /* 会合位必然清除 */
            xTicksToWait = 0;
        }
        else if( xTicksToWait != 0 )
        {
            /* ⑤ 我先到：挂起等待，硬编码"清位 + 全部"两个控制位 */
            vTaskPlaceOnUnorderedEventList( &pxEventBits->xTasksWaitingForBits,
                    uxBitsToWaitFor | eventCLEAR_EVENTS_ON_EXIT_BIT
                                    | eventWAIT_FOR_ALL_BITS,
                    xTicksToWait );
        }
        else { /* 超时时间为 0：直接返回当前位图 */ }
    }
    xAlreadyYielded = prvEXIT_CRITICAL_OR_RESUME_ALL( &pxEventBits->xEventGroupLock );
    /* ⑥ 之后与 WaitBits 阻塞路径完全同构：yield、取回执、超时补查清位 */
}
```

- **②为什么要先存旧值**：③里嵌套调用的 `SetBits` 会唤醒先到的等待者并**清掉会合位**（他们的 `CLEAR_ON_EXIT` 生效）。等③返回时位图可能已被清空，④的判定必须用 `旧值 | 我设的位` 重建"刚才那一刻"的状态。这个局部变量是对"嵌套调用有副作用"的精确补偿。
- **⑤控制位硬编码**：会合语义固定为"等全部 + 到齐即清"，所以 `CLEAR_ON_EXIT` 与 `WAIT_FOR_ALL` 两个控制位被无条件编进链表项值。先到者的清位诉求由最后到达者的 `SetBits` 遍历统一执行（12.4 节的延迟清位保证了所有先到者拿到同一份满位快照）。
- **IDF 的嵌套同锁**：①已持有本组自旋锁，③再次对同一把锁进入临界区——IDF 的 `portENTER_CRITICAL` 带同核嵌套计数，支持这种写法。Vanilla 侧对应物是 `vTaskSuspendAll()` 天然的嵌套计数（`uxSchedulerSuspended` 是个计数器）。

### 3. 会合状态迁移图

以两任务会合为例（A 占 bit0，B 占 bit1，`uxBitsToWaitFor = 0x3`）。左：事件组位图的状态机；右：单个参与任务的状态机：

```text
 事件组位图状态机（左）              参与任务状态机（右，以 A 为例）
 ═════════════════════              ═══════════════════════════════
                                        ┌────────┐
      {} 清空                           │ 运行中  │
       │ A: Sync(set=0x1)               └───┬────┘
       ▼                                    │ Sync: 设 0x1，测 0x3
    {0x1} ──B: Sync(set=0x2)──► {0x3}       ▼
       ▲                            │   条件满足? ──否──► 阻塞于等待链表
       │                            │     │是              itemValue=0x3|CLEAR|ALL
       │                    最后到达者│     │                    │
       │                    统一清除  │     │              B 到达触发 SetBits
       └────────────────────────────┘     │              回执=0x3|UNBLOCKED
       （回到 {}，可进入下一轮）            ▼                    │
                                      返回(0x3) ◄───────────────┘
                                      继续后半程
```

两条不变式保证协议正确：**清空态是唯一稳态**（每次会合结束位图回到 `{}`，可直接进入下一轮）；**任何时刻条件判定与清位都在同一保护区内**（无第三者插队窗口）。超时同样有善后：先到者超时醒来后，若补查发现位已凑齐（`SetBits` 恰发生在超时唤醒与上 CPU 之间），仍按会合成功处理并清位——先到者不会"冤枉超时"。

### 4. 使用纪律

- **每个参与者必须占独立的一位**：`uxBitsToSet` 互不重叠，`uxBitsToWaitFor` 覆盖全体。若两人共用一位，先到者在④的判定里会因自己的位已置而立即"满足"穿过同步点，会合退化成空气；
- 参与者数量 ≤ 可用位数（24），且不适合"动态加入的 N 方会合"——那是计数信号量或自定义屏障的活；
- 超时者离开后，剩下的人可能永远等不齐——要么 `portMAX_DELAY` 全体无限等，要么设计好超时后的位清理协议。

---

## 12.7 Vanilla vs ESP-IDF：临界区与锁实现

事件组是全系列目前遇到的**锁差异最大的对象**——因为它的主互斥手段不是队列那样的短临界区，而是"挂起调度器级别的长保护区"（要遍历链表、唤醒任意多个任务）。两棵树在这里给出了截然不同的答案。

先看 Vanilla v10.5.1 的做法：`xEventGroupWaitBits/SetBits/Sync` 的主保护区是裸的 `vTaskSuspendAll()` / `xTaskResumeAll()`，超时补查段用无参数的 `taskENTER_CRITICAL()`。这在单核上成立的原因：挂起调度器后本核不会切换任务，事件链表因此独占；中断处理程序**从不直接**碰事件组（ISR 路径全部经定时器任务转交），所以也不需要防中断；其他核不存在。

IDF fork（v6.0.2 默认编译的 `FreeRTOS-Kernel/` 树）要面对双核。它的方案浓缩在 `esp_private/freertos_idf_additions_priv.h` 的一组宏里：

```c
/* 双核构建（!CONFIG_FREERTOS_SMP && configNUM_CORES > 1）：
 * "SMP will always use critical sections (determinism is not supported)" */
#define prvENTER_CRITICAL_OR_SUSPEND_ALL( pxLock )    taskENTER_CRITICAL( ( pxLock ) )
#define prvEXIT_CRITICAL_OR_RESUME_ALL( pxLock )      ( { taskEXIT_CRITICAL( ( pxLock ) ); pdFALSE; } )

/* 单核构建：退回 Vanilla 的调度器挂起 */
#define prvENTER_CRITICAL_OR_SUSPEND_ALL( pxLock )    ( { vTaskSuspendAll(); ( void ) ( pxLock ); } )
#define prvEXIT_CRITICAL_OR_RESUME_ALL( pxLock )      xTaskResumeAll()
```

逐项对照：

| 维度                           | Vanilla v10.5.1                        | IDF fork（默认树，双核构建）                                                                 |
| ------------------------------ | -------------------------------------- | -------------------------------------------------------------------------------------------- |
| `EventGroup_t`                 | 位图 + 等待链表                        | **多一个 `portMUX_TYPE xEventGroupLock`**，创建时 `portMUX_INITIALIZE`                       |
| WaitBits/SetBits/Sync 主保护区 | `vTaskSuspendAll()/xTaskResumeAll()`   | `prvENTER_CRITICAL_OR_SUSPEND_ALL(&xEventGroupLock)` → 带锁临界区（**本核关中断 + 自旋锁**） |
| 超时补查段                     | `taskENTER_CRITICAL()`（无参，全局）   | `taskENTER_CRITICAL(&xEventGroupLock)`（对象锁）                                             |
| ClearBits / GetBitsFromISR     | 无参 `taskENTER_CRITICAL[_FROM_ISR]()` | 同名 API 带对象锁（`prvENTER_CRITICAL_OR_MASK_ISR`）                                         |
| 遍历内核任务链表的额外保护     | 不需要（调度器已挂起）                 | `prvTakeKernelLock()` / `prvReleaseKernelLock()`（`configNUMBER_OF_CORES > 1` 时）           |
| 保护期间的中断延迟             | 小（调度器挂起不屏蔽中断）             | 大（本核中断被屏蔽 + 可能自旋等待）                                                          |
| 锁粒度                         | 全局（单核假设下无所谓）               | **每对象一把锁**——两个不同事件组可并行进入各自的 SetBits                                     |

### 1. 为什么 SMP 不能沿用"挂起调度器"

IDF fork 的 `vTaskSuspendAll()` **只挂起当前核**的调度器（别的核照常切换任务）。A 核挂着自己的调度器遍历等待链表时，B 核完全可以同时跑一个 `SetBits` 动同一条链表——链表当场撕裂。所以双核必须改用**真正互斥**的手段：自旋锁。代价是锁内本核中断被屏蔽（`taskENTER_CRITICAL(&lock)` 的语义，第 18 章拆到汇编级），等待对端释放期间还会自旋烧 CPU——这就是事件组的 `SetBits` 被列为"非确定性操作"、ISR 禁用的根因：持锁时间随等待者数量增长。

### 2. 为什么还要再加一把"内核锁"

自旋锁保护的是**事件组自己的数据**；但 `vTaskRemoveFromUnorderedEventList()` 会去改 `tasks.c` 的就绪/延迟链表——那是调度器的地盘。单核 Vanilla 靠"调度器挂起"顺带独占了它们；IDF fork 的对象锁管不到，于是 `SetBits`/`vEventGroupDelete` 在双核构建里显式加调 `prvTakeKernelLock()`（源码注释：traversing a task list which is a kernel data structure）。**对象锁管自家，内核锁管公地**——两把锁的分工是读 IDF fork 源码时的重要地图。

### 3. 实验性 SMP 树反其道而行

v6.0.2 还有一棵 `FreeRTOS-Kernel-SMP/`（上游 Amazon SMP 内核，v11.1.0 基线，`CONFIG_FREERTOS_SMP` 开启，默认关）。有趣的是它的 `event_groups.c` **回到了**全局 `vTaskSuspendAll()` 方案——因为在那套内核里调度器挂起是全局语义（`vTaskSuspendAll` 内部先取 task/ISR 两把大锁再递增全局计数），临界区也是无参数的巨型锁（giant lock）模型。即：**IDF fork 的路线是"细粒度对象锁"，上游 SMP 的路线是"全局大锁"**——两条 SMP 化路线的正面交锋在第 22 章全景展开（`porting_notes.md` 与 `idf_changes.md` 是各自的官方自述）。对应用层的一个可感差异：IDF fork 下两个无关的事件组可以并行操作，上游 SMP 树下它们串行。

> [!tip] 写跨平台代码时的一个提醒
> 事件组 API 语义在 Vanilla 与 IDF 之间**完全一致**（本章走读的算法逐行同构），差异全部藏在锁实现里。但有一样间接影响你：持锁期间的中断延迟。若你的系统里有亚毫秒级硬实时中断（且未设在 `configMAX_SYSCALL_INTERRUPT_PRIORITY` 之上），高频 `SetBits` + 长等待链表会直接顶爆它——这在 Vanilla 的"挂起调度器"方案下并不发生。事件组-heavy 的双核设计要评估锁驻留时长。

---

## 12.8 实验：双传感器 + 聚合任务

经典聚合场景：温度任务 500ms 出一帧，湿度任务 1300ms 出一帧；聚合任务先以**任一模式**消费 6 轮（谁先到处理谁），再以**全部模式**等齐 3 轮。创建项目（流程同第 1 章）：

```bash
cd ~ && idf.py create-project freertos-ch12 && cd freertos-ch12 && idf.py set-target esp32
```

`main/freertos-ch12.c`：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"

#define BIT_TEMP   ( 1 << 0 )
#define BIT_HUMI   ( 1 << 1 )
#define BITS_BOTH  ( BIT_TEMP | BIT_HUMI )

static EventGroupHandle_t s_eg;

/* 通用传感器任务：arg 指向 {周期, 位}，按周期置位 */
typedef struct { int period_ms; EventBits_t bit; } sensor_cfg_t;

static void sensor_task( void *arg )
{
    const sensor_cfg_t *cfg = arg;
    for( ;; ) {
        vTaskDelay( pdMS_TO_TICKS( cfg->period_ms ) );
        xEventGroupSetBits( s_eg, cfg->bit );
    }
}

static void report( const char *mode, EventBits_t bits )
{
    if( bits & BIT_TEMP ) printf( "[agg] %s: temp ready\r\n", mode );
    if( bits & BIT_HUMI ) printf( "[agg] %s: humi ready\r\n", mode );
    if( bits == 0 )       printf( "[agg] %s: timeout, no sensor ready\r\n", mode );
}

static void aggregator_task( void *arg )
{
    /* 第一阶段：任一模式——谁先到处理谁，超时 1s */
    for( int i = 0; i < 6; i++ ) {
        EventBits_t bits = xEventGroupWaitBits( s_eg, BITS_BOTH,
                                                pdTRUE,   /* 清位 */
                                                pdFALSE,  /* 任一 */
                                                pdMS_TO_TICKS( 1000 ) );
        report( "any ", bits );
    }
    /* 第二阶段：全部模式——温度湿度都到齐才走，超时 2s */
    for( int i = 0; i < 3; i++ ) {
        EventBits_t bits = xEventGroupWaitBits( s_eg, BITS_BOTH,
                                                pdTRUE, pdTRUE,
                                                pdMS_TO_TICKS( 2000 ) );
        report( "all ", bits );
    }
    printf( "[agg] demo done, deleting myself\r\n" );
    vTaskDelete( NULL );
}

void app_main( void )
{
    static const sensor_cfg_t temp_cfg = { 500,  BIT_TEMP };   /* 500ms 一帧  */
    static const sensor_cfg_t humi_cfg = { 1300, BIT_HUMI };   /* 1300ms 一帧 */
    s_eg = xEventGroupCreate();
    xTaskCreate( sensor_task, "temp", 2048, (void *) &temp_cfg, 4, NULL );
    xTaskCreate( sensor_task, "humi", 2048, (void *) &humi_cfg, 4, NULL );
    xTaskCreate( aggregator_task, "agg", 2048, NULL, 5, NULL );
}
```

```bash
idf.py qemu monitor
```

典型输出（节选；行序与时隙因调度而异）：

```text
[agg] any : temp ready
[agg] any : temp ready
[agg] any : humi ready
[agg] any : temp ready
[agg] any : humi ready
[agg] any : temp ready
[agg] all : temp ready          ← all 模式：temp 与 humi 总是成对出现
[agg] all : humi ready
[agg] all : temp ready
[agg] all : humi ready
[agg] all : temp ready
[agg] all : humi ready
[agg] demo done, deleting myself
```

值得亲手验证的四个观察点：

1. **任一模式的节律**。温度 500ms 一帧、湿度 1300ms 一帧，任一模式下聚合任务大约按 500ms 节奏醒（每次都被温度位喂饱），偶尔一轮同时看到两个位（500 与 1300 的公倍数时刻）——输出里 `temp` 与 `humi` 同现的行就是 12.4 节"同一快照唤醒"的肉眼证据。
2. **全部模式的节律变成 1300ms**。快的传感器被慢的拖住：第 1~2 帧温度位置上后没人清（等待者要的是"全部"，`SetBits` 遍历不命中，延迟清位集合为空），位图里温度位一直亮着；湿度位每 1300ms 亮起瞬间凑齐、唤醒、清空。电平语义在支撑这一切。
3. **超时路径**。把聚合任务超时改成 200ms（小于最快传感器周期），任一模式会打出 `timeout, no sensor ready`——返回的位图指示缺谁。
4. **clear-on-exit 的掩码级清除**。任一模式下若改为 `pdFALSE` 并观察第二次等待立即返回（位还亮着），体会 12.5 节讲的掩码级清位/不清位语义。

想把 12.6 节的状态图跑起来：在同一工程里加一个新事件组，再写两个任务（参数用小结构体封装周期与自己的位），循环"`vTaskDelay(各自周期)` → `xEventGroupSync(eg, 自己的位, 两位全等, portMAX_DELAY)` → 打印 rendezvous 序号"。让一个 300ms 到、另一个 800ms 到，输出里**每轮两条 passed 总是紧邻成对出现**——快的一方在会合点睡等慢的一方，然后同帧放行。再故意让两个任务设同一位试试协议如何失效（12.6 节第 4 条纪律的直接复现）。

---

## 12.9 小结

- 事件组补上了队列/信号量表达不了的两块拼图：**多事件聚合条件**（任一/全部）与**一对多广播**；位是电平语义，不因被等待而消耗。
- 数据结构极简：`EventBits_t uxEventBits` + `List_t xTasksWaitingForBits`（+ IDF 的 `portMUX_TYPE xEventGroupLock`）；32 位 tick 下可用位 24 个，最高字节是内核控制位。
- 全部精巧在**链表项值即信箱**：等待者把"等哪些位 + 任一/全部 + 要不要清"编码进 `xEventListItem` 的值；设置者命中后把"唤醒时刻位图 + 已唤醒标记"写回同一位置。`vTaskPlaceOnUnorderedEventList` / `vTaskRemoveFromUnorderedEventList` / `uxTaskResetEventItemValue` 是这套交接的三根管道。
- `xEventGroupSetBits` 遍历等待链表逐项判定、`xClearOnExit` 的位**延迟到遍历结束后统一清除**，保证一次唤醒的所有等待者看到同一位图快照；不存在 `prvTestAndClear` 之类的原子帮助函数，测试与清除是保护区内的两段显式代码。
- `xEventGroupWaitBits` 三路径（快路径/轮询/阻塞）；超时醒来的**二次条件检查**处理"超时唤醒与上 CPU 之间条件恰好凑齐"的真实竞态。
- `xEventGroupSync` = 保护区内的"亮牌 + 判齐"，控制位硬编码为"全部 + 到齐即清"；旧值快照补偿嵌套 `SetBits` 的清位副作用；每参与者占独立一位，清空态是唯一稳态。
- 暗线：Vanilla 用**调度器挂起**（单核假设），IDF fork 用**每对象自旋锁临界区**（外加遍历内核链表时的内核锁），实验性上游 SMP 树回到**全局大锁**。API 语义不变，锁模型三样——中断延迟特性随之不同。

下一章进入 Part III 的收官对象：[[ch13-task-notifications|第十三章]]的**任务通知**。它是唯一不创建任何内核对象的 IPC——通知值与等待状态直接长在 TCB 身上，因而更快、更省。你会看到它如何用 32 位通知值模拟出事件组的位语义（`ulTaskNotifyValueBits` 一族），以及"不共享、只点对点"这一设计约束换来的是什么。带着本章的问题去读：事件组的广播能力，任务通知为什么给不了？
