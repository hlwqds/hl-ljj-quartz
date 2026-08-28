---
title: "FreeRTOS 深度解析（六）：调度器核心——就绪链表与最高优先级任务选择"
date: 2026-08-26
description: "从 list.c 的侵入式双向链表讲起，拆解 pxReadyTasksLists 就绪队列组织、uxTopReadyPriority 与 taskSELECT_HIGHEST_PRIORITY_TASK 选任务算法、Vanilla 位图优化与 IDF 扫描实现的对照，以及 eTaskGetState 状态机与阻塞/挂起/等待终止链表全景；最后用 uxTaskGetSystemState 打印系统所有任务状态。"
tags: [freertos, rtos, esp32, esp-idf, scheduler, linked-list, tasks-c, source-code]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 6. **第六章：调度器核心——就绪链表与最高优先级任务选择**

# FreeRTOS 深度解析（六）：调度器核心——就绪链表与最高优先级任务选择

第五章拆了 TCB——任务的"身份证"。这一章回答调度器的核心问题：**给定一堆任务，内核靠什么数据结构在微秒级选出"下一个该上 CPU 的任务"？** 答案出奇地朴素：一个 10KB 的链表原语文件（`list.c`）加上一个按优先级分层的链表数组。FreeRTOS 调度器的全部"智能"，就建立在这两样东西上。

先给结论，本章要建立的三层认知：

1. **`list.c` 是内核唯一的数据结构底座**——一个侵入式双向循环链表，节点直接内嵌在 TCB 里，增删都是 O(1)；
2. **"选最高优先级任务" = 从 `uxTopReadyPriority` 往下扫，找到第一个非空的 `pxReadyTasksLists[i]`**——Vanilla 在部分端口上用位图 + CLZ 指令把它优化成一条指令，IDF fork 在 SMP 下退回纯扫描，还要额外跳过"别的核正在跑"的任务；
3. **一个任务处于什么状态，完全由它的 `xStateListItem` 挂在哪条链表上决定**——`eTaskGetState()` 就是"查户口"。

本章源码以 ESP-IDF v6.0.2 默认编译的 `components/freertos/FreeRTOS-Kernel/`（Vanilla v10.5.1 + Espressif SMP 改造，下称 IDF fork）为准，对照原版 Vanilla v10.5.1。实验性的上游 SMP 内核树（`CONFIG_FREERTOS_SMP` 开启才编入）只在对照时点名，[[2026-08-26-freertos-deep-dive-ch4-kernel-source-map|第四章]] 有两棵树的完整说明。

---

## 6.1 先修课：`list.c` 的侵入式双向链表

`tasks.c` 有 27 万字节，`list.c` 只有 1 万——但它被内核里**所有**数据结构引用：就绪队列、阻塞队列、队列的等待名单、事件组的等待名单，全是它。不先吃透它，后面每个机制都要卡壳。

### 1. 三个结构体

`list.h` 里只有三个类型（IDF fork 与 Vanilla v10.5.1 在这里逐字段一致）：

```c
struct xLIST_ITEM                          /* 普通节点 */
{
    configLIST_VOLATILE TickType_t xItemValue;   /* 排序键：多数链表按它升序 */
    struct xLIST_ITEM *volatile pxNext;          /* 双向指针 */
    struct xLIST_ITEM *volatile pxPrevious;
    void *pvOwner;                               /* 回指包含它的对象（通常是 TCB） */
    struct xLIST *volatile pxContainer;          /* 指向所在链表（NULL = 不在任何链表） */
};
typedef struct xLIST_ITEM ListItem_t;

struct xMINI_LIST_ITEM                      /* 迷你节点：省掉 pvOwner/pxContainer */
{
    configLIST_VOLATILE TickType_t xItemValue;
    struct xLIST_ITEM *volatile pxNext;
    struct xLIST_ITEM *volatile pxPrevious;
};
typedef struct xMINI_LIST_ITEM MiniListItem_t;

typedef struct xLIST                        /* 链表头 */
{
    volatile UBaseType_t uxNumberOfItems;   /* 元素个数（不含尾标记） */
    ListItem_t *volatile pxIndex;           /* 遍历游标，见下文 */
    MiniListItem_t xListEnd;                /* 尾标记，值恒为 portMAX_DELAY */
} List_t;
```

三个设计决定值得停下来看：

**第一，链表节点不知道 TCB，TCB 知道链表节点。** `ListItem_t` 是通用节点，通过 `pvOwner` 回指宿主对象；宿主（TCB）把节点作为成员**内嵌**在自己体内。这就是侵入式（intrusive）链表——对比 Linux 的 `list_head`，思路完全相同。

**第二，`pxContainer` 让删除变成 O(1)。** 每个节点记得自己在哪条链表里，`uxListRemove()` 只需要节点指针一个参数，不需要先找到链表再搜索节点。

**第三，`MiniListItem_t` 只给尾标记用。** `xListEnd` 永远不会被移除、不需要 owner，砍掉两个指针省 8 字节——在 `pxReadyTasksLists[25]` 这样成组的链表上，积少成多。

### 2. 尾标记环：为什么"空链表"也有一个节点

`vListInitialise()` 把链表初始化成一个自指的环：

```text
        vListInitialise(&L) 之后：

        ┌──────────────────────────────────┐
        │                                  │
        ▼                                  │
   ┌─────────┐   pxNext   ┌───────────┐    │
   │ xListEnd│ ────────►  │ xListEnd  │    │   uxNumberOfItems = 0
   │ (尾标记)│ ◄────────  │ (自己)    │    │   pxIndex → xListEnd
   └─────────┘   pxPrev  └───────────┘    │
        │                                  │
        └──────────────────────────────────┘
        xItemValue = portMAX_DELAY（永远排在最后）
```

尾标记的 `xItemValue` 是 `portMAX_DELAY`——排序插入时它**天然沉底**，所以任何真实节点都排在它前面。这个哨兵（sentinel）消灭了所有空链表/头尾边界判断：插入永远有"前驱"和"后继"，`pxNext` 永远不为 NULL。

### 3. 关键操作与遍历宏

| API / 宏                                       | 语义                                         | 谁在用                     |
| ---------------------------------------------- | -------------------------------------------- | -------------------------- |
| `vListInsert( pxList, pxItem )`                | 按 `xItemValue` **升序**插入                 | 阻塞链表（按唤醒时刻排序） |
| `vListInsertEnd( pxList, pxItem )`             | 插到 `pxIndex` 之前（即"轮转队列的队尾"）    | 就绪链表（公平性关键！）   |
| `uxListRemove( pxItem )`                       | 自摘链，返回链表剩余元素数                   | 一切状态迁移               |
| `listGET_OWNER_OF_NEXT_ENTRY( pxTCB, pxList )` | `pxIndex` 前进一步，跳过尾标记，取 `pvOwner` | 同优先级轮转选任务         |
| `listGET_OWNER_OF_HEAD_ENTRY( pxList )`        | 取队首节点的 `pvOwner`                       | tick 到期唤醒队首任务      |
| `listLIST_IS_EMPTY( pxList )`                  | `uxNumberOfItems == 0`                       | 选任务扫描循环             |
| `listSET_LIST_ITEM_OWNER( pxItem, pxOwner )`   | 设置回指指针（就是个裸赋值宏）               | 任务创建时绑定 TCB         |

`listGET_OWNER_OF_NEXT_ENTRY()` 值得展开，它是同优先级时间片的基石：

```c
#define listGET_OWNER_OF_NEXT_ENTRY( pxTCB, pxList )                    \
    {                                                                    \
        List_t * const pxConstList = ( pxList );                         \
        ( pxConstList )->pxIndex = ( pxConstList )->pxIndex->pxNext;     \
        if( ( void * ) ( pxConstList )->pxIndex == ( void * ) &( ( pxConstList )->xListEnd ) ) \
        {                                                                \
            ( pxConstList )->pxIndex = ( pxConstList )->pxIndex->pxNext; \
        }                                                                \
        ( pxTCB ) = ( pxConstList )->pxIndex->pvOwner;                   \
    }
```

`pxIndex` 是游标：每调用一次前进一格，**上次被选中过的任务不会再是"下一个"**——一圈轮完才轮回来。这就是 Vanilla 单核 FreeRTOS"同优先级任务精确均分 CPU"的全部机制。记住它，6.4 节会看到 IDF fork 因为 SMP 把这套游标逻辑改成了什么样。

### 4. 为什么用侵入式链表

| 维度       | 侵入式（FreeRTOS/Linux `list_head`） | 非侵入式（节点装 `void*`，堆分配） |
| ---------- | ------------------------------------ | ---------------------------------- |
| 删除复杂度 | O(1)，节点自摘链                     | 先在链表里搜到节点，O(n)           |
| 内存分配   | 零额外分配，节点随宿主生死           | 每次 insert 分配、每次 remove 释放 |
| 内存安全   | 宿主销毁时节点自动消失               | 忘了 remove 就是悬垂指针           |
| 代价       | 一个对象同一时刻只能在一条链表上     | 无此限制                           |

最后一条"代价"正是 FreeRTOS 需要两个节点的原因——见下一节。

> [!tip] Vanilla vs ESP-IDF：`list.c` 几乎零差异，但 IDF 加了两个内联宏
> IDF fork 的 `list.h` 与 Vanilla v10.5.1 逐行一致（仅格式重排），真正的增补是两个"性能补丁"宏：`listREMOVE_ITEM()`（内联版 `uxListRemove`，不返回值）和 `listINSERT_END()`（内联版 `vListInsertEnd`）。注释写明是给 `xTaskIncrementTick()` 的热路径省一次函数调用。**结论：读任何一份 `list.c` 都等于读了两份。** 链表层没有双核问题——这也是 Espressif 能把 SMP 改造限制在 `tasks.c` 内的原因之一。

---

## 6.2 调度器链表全景：任务到底住在哪

`tasks.c` 用一组静态 `List_t` 给所有任务"分宿舍"。一个任务任意时刻**恰好**住在其中一条（或已退房）。这就是 FreeRTOS 任务状态机的物理实现。

### 1. 全景图

```text
                              tasks.c 的全部任务链表
 ┌───────────────────────────────────────────────────────────────────────────┐
 │                                                                           │
 │   pxReadyTasksLists[ configMAX_PRIORITIES ]   ←── 就绪队列（按优先级分层）  │
 │   ┌─────┐  ┌─────┐  ┌─────┐       ┌─────┐                                 │
 │   │ [0] │  │ [1] │  │ [2] │  ...  │ [24]│   ←── IDF 默认 configMAX_      │
 │   └──┬──┘  └─────┘  └──┬──┘       └─────┘       PRIORITIES = 25          │
 │      │                │                                                   │
 │   Idle0,Idle1      TCB_A ⇄ TCB_B    ←── 每层一条双向环，FIFO 入队         │
 │                                                     uxTopReadyPriority    │
 │                                                        │  指向最高非空层    │
 │   ──────────────────────────────────────────────────  ▼                  │
 │                                                                           │
 │   xDelayedTaskList1 ⇄ xDelayedTaskList2        ←── 阻塞（带超时）         │
 │        ▲            pxDelayedTaskList ────────┐      按"唤醒时刻"升序     │
 │        └── tick 溢出时二者角色互换 ◄───────────┘      （vListInsert）      │
 │                                                                           │
 │   xPendingReadyList[ configNUMBER_OF_CORES ]   ←── "缓刑"队列：调度器     │
 │                                                  被挂起期间变就绪的任务    │
 │                                                  （IDF 为每核一条！）      │
 │   xSuspendedTaskList                           ←── 挂起 / 无限期阻塞      │
 │   xTasksWaitingTermination                     ←── 已删除待回收           │
 │                                                                           │
 │   pxCurrentTCBs[0] / pxCurrentTCBs[1]          ←── 不在链表里：正在跑      │
 └───────────────────────────────────────────────────────────────────────────┘
```

### 2. 每条链表的职责

| 链表                       | 谁会进去                                                  | 进入方式                                                     | 出去方式                                                                                                             |
| -------------------------- | --------------------------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- | ---------- |
| `pxReadyTasksLists[p]`     | 优先级 p 且可立即运行的任务                               | `prvAddTaskToReadyList()`（插队尾）                          | 被选中上 CPU / 开始阻塞 / 被删                                                                                       |
| `pxDelayedTaskList`        | `vTaskDelay()`、等队列带超时的任务                        | `prvAddCurrentTaskToDelayedList()`（按唤醒时刻**有序**插入） | tick 到期由 `xTaskIncrementTick()` 唤醒，或事件先到                                                                  |
| `xPendingReadyList[x]`     | 调度器被 `vTaskSuspendAll()` 挂起期间，ISR 里变就绪的任务 | 中断内不能动就绪链表，先寄存                                 | `xTaskResumeAll()` 统一搬回就绪链表                                                                                  |
| `xSuspendedTaskList`       | `vTaskSuspend()` 的任务、**无限期**等事件的任务           | `vTaskSuspend()` / 无限期阻塞路径                            | `vTaskResume()` / 事件到达                                                                                           |
| `xTasksWaitingTermination` | `vTaskDelete()` 已删除、TCB 和栈还没释放的任务            | `vTaskDelete()` 把 `xStateListItem` 挂进去                   | Idle 任务里 `prvCheckTasksWaitingTermination()` 释放内存（见 [[2026-08-26-freertos-deep-dive-ch9-blocking-delay-idle | 第九章]]） |

### 3. 一个 TCB，两个节点：`xStateListItem` 与 `xEventListItem`

第五章讲过 TCB 的前几个成员，现在它们开始干活了：

```c
typedef struct tskTaskControlBlock
{
    volatile StackType_t *pxTopOfStack;   /* 上下文恢复用，必须是第一个成员 */
    ...
    ListItem_t xStateListItem;            /* 状态节点：决定任务"住在哪" */
    ListItem_t xEventListItem;            /* 事件节点：决定任务"在等谁" */
    UBaseType_t uxPriority;
    ...
} TCB_t;
```

侵入式链表"一个节点同一时刻只能在一条链上"的限制，被这两个节点化解：**状态**和**等待**是两个正交的维度。一个等队列（超时 100ms）的任务，`xStateListItem` 挂在阻塞链表（带唤醒时刻），`xEventListItem` 挂在队列的 `xTasksWaitingToReceive` 链表（带优先级）。谁先满足谁先把它捞走——这正是队列、信号量超时语义的实现基础，[[2026-08-26-freertos-deep-dive-ch10-queue-universal-ipc|第十章]] 展开。

创建任务时（`tasks.c` 的 `prvInitialiseNewTask()`）：

```c
listSET_LIST_ITEM_OWNER( &( pxNewTCB->xStateListItem ), pxNewTCB );
/* 事件链表按优先级降序排序，值取反实现 */
listSET_LIST_ITEM_VALUE( &( pxNewTCB->xEventListItem ),
                         ( TickType_t ) configMAX_PRIORITIES - ( TickType_t ) uxPriority );
listSET_LIST_ITEM_OWNER( &( pxNewTCB->xEventListItem ), pxNewTCB );
```

两个节点从出生起就回指自己的 TCB——之后内核在任何链表里摸到一个节点，一次解引用就能拿到完整任务。

---

## 6.3 就绪队列：`pxReadyTasksLists[configMAX_PRIORITIES]`

### 1. 分层组织

就绪任务按优先级分层，每层一条 FIFO 环：

```c
PRIVILEGED_DATA static List_t pxReadyTasksLists[ configMAX_PRIORITIES ];
PRIVILEGED_DATA static volatile UBaseType_t uxTopReadyPriority = tskIDLE_PRIORITY;
```

IDF 的 `configMAX_PRIORITIES` 固定为 25（`components/freertos/config/include/freertos/FreeRTOSConfig.h`）。`uxTopReadyPriority` 是**缓存的高水位线**：记录"当前有就绪任务的最高优先级"，让选任务不必每次从 24 层傻扫到 0 层。

注意它只会被 `taskRECORD_READY_PRIORITY()` **向上推**：

```c
#define taskRECORD_READY_PRIORITY( uxPriority )  \
    {                                            \
        if( ( uxPriority ) > uxTopReadyPriority ) \
        {                                        \
            uxTopReadyPriority = ( uxPriority ); \
        }                                        \
    }
```

任务离开就绪链表时这个值**不会**立即下降（那需要回扫所有层），它只是暂时"偏高"——选任务循环扫到第一个非空层时顺手修正（见 6.4 节）。惰性更新的取舍很划算：宁可缓存值偶尔偏高多扫几层，也不在每次出队时付回扫成本。

### 2. 进队：`prvAddTaskToReadyList` 与 `prvAddNewTaskToReadyList`

挂入就绪链表是个宏，干两件事：刷新高水位线 + **插到队尾**：

```c
#define prvAddTaskToReadyList( pxTCB )                                                                 \
    traceMOVED_TASK_TO_READY_STATE( pxTCB );                                                           \
    taskRECORD_READY_PRIORITY( ( pxTCB )->uxPriority );                                                \
    listINSERT_END( &( pxReadyTasksLists[ ( pxTCB )->uxPriority ] ), &( ( pxTCB )->xStateListItem ) );
```

为什么必须插队尾而不是 `vListInsert` 有序插入？因为就绪层内**顺序本身就是公平性**：新来的排最后，等这一层轮完才轮到它。如果按值排序，后来的可能插队。`listINSERT_END`（IDF 内联版 `vListInsertEnd`）插在 `pxIndex` 游标之前，恰好实现"所有人轮一遍之前，你排不上"。

新任务创建走的 `prvAddNewTaskToReadyList()` 在宏之外还包了一层 `taskENTER_CRITICAL( &xKernelLock )`（IDF SMP 版内核锁，第十八章讲），负责：第一个任务创建时调 `prvInitialiseTaskLists()` 初始化所有链表；调度器未启动时按亲和性给 `pxCurrentTCBs[0]/[1]` 填"首发任务"；调度器已启动时若有必要立刻触发让出。

### 3. 出队：`uxListRemove` 与 `taskRESET_READY_PRIORITY`

任何状态迁移的第一步都是把 `xStateListItem` 从当前链表摘下来：

```c
if( uxListRemove( &( pxTCB->xStateListItem ) ) == ( UBaseType_t ) 0 )
{
    taskRESET_READY_PRIORITY( pxTCB->uxPriority );   /* 仅位图模式有实体 */
}
```

`uxListRemove` 返回剩余元素数——为 0 说明刚搬空了一层就绪队列。`taskRESET_READY_PRIORITY()` 只有在 Vanilla 位图优化模式下才有实际动作（清位图里对应的位）；泛型扫描模式下它被定义成空宏，因为扫描算法对"偏高"的水位线天然免疫。

---

## 6.4 选任务：`taskSELECT_HIGHEST_PRIORITY_TASK`

调度点（`portYIELD()`、tick、解锁）最终都汇聚到 `vTaskSwitchContext()`，里面的核心就是 `taskSELECT_HIGHEST_PRIORITY_TASK()`。这一节是全章高潮，也是 Vanilla 与 IDF fork **分歧最大**的地方。

### 1. 泛型版（单核）：从水位线向下扫

`configUSE_PORT_OPTIMISED_TASK_SELECTION == 0` 时的单核实现，两棵树逐字符一致：

```c
#define taskSELECT_HIGHEST_PRIORITY_TASK()                            \
    {                                                                 \
        UBaseType_t uxTopPriority = uxTopReadyPriority;               \
                                                                      \
        /* 从高往低找第一个非空的就绪层 */                                \
        while( listLIST_IS_EMPTY( &( pxReadyTasksLists[ uxTopPriority ] ) ) ) \
        {                                                             \
            configASSERT( uxTopPriority );                            \
            --uxTopPriority;                                          \
        }                                                             \
                                                                      \
        /* 游标前进一步取下一个任务 → 同优先级精确轮转 */                    \
        listGET_OWNER_OF_NEXT_ENTRY( pxCurrentTCBs[ 0 ],              \
                                     &( pxReadyTasksLists[ uxTopPriority ] ) ); \
        uxTopReadyPriority = uxTopPriority;   /* 顺手修正水位线 */        \
    }
```

两个要点：空层最多扫几格（水位线缓存保证了起点已经很准）；选中任务**不是取队首**，而是 `listGET_OWNER_OF_NEXT_ENTRY` 游标步进——上次跑过的这轮跳过，时间片公平性由此而来。

### 2. Vanilla 的位图优化：`portRECORD_READY_PRIORITY` 与 CLZ

Vanilla 允许端口提供硬件级加速（`configUSE_PORT_OPTIMISED_TASK_SELECTION == 1`）。以 Cortex-M4F 端口 `portmacro.h` 为例：

```c
/* uxTopReadyPriority 被重新解释为 32 位位图：第 i 位 ⇔ 优先级 i 有就绪任务 */
#define portRECORD_READY_PRIORITY( uxPriority, uxReadyPriorities ) \
    ( uxReadyPriorities ) |= ( 1UL << ( uxPriority ) )
#define portRESET_READY_PRIORITY( uxPriority, uxReadyPriorities ) \
    ( uxReadyPriorities ) &= ~( 1UL << ( uxPriority ) )
#define portGET_HIGHEST_PRIORITY( uxTopPriority, uxReadyPriorities )    \
    uxTopPriority = ( 31UL - ( uint32_t ) ucPortCountLeadingZeros( ( uxReadyPriorities ) ) )
```

同一变量换个解释：**第 i 位为 1 ⇔ 优先级 i 有就绪任务**。"找最高非空层"变成"找最高位的 1"，Cortex-M 的 `CLZ` 指令一条周期完成。约束是 `configMAX_PRIORITIES ≤ 32`（位图宽度）。

> [!note] IDF 在 ESP32 上**不启用**这套优化
> 三个证据：Xtensa 端口的 `portmacro.h` 没有定义 `portRECORD_READY_PRIORITY`/`portGET_HIGHEST_PRIORITY`；`FreeRTOS.h` 里 `configUSE_PORT_OPTIMISED_TASK_SELECTION` 默认 0 且 IDF 配置从不改它；Espressif 自己的改造说明 `idf_changes.md` 明确写着 "Disable `configUSE_PORT_OPTIMISED_TASK_SELECTION` for SMP"。原因在下一小节——**位图说不出"这个优先级上的任务哪个核能跑"**，SMP 需要的是逐任务检查，不是逐优先级检查。

### 3. Vanilla vs ESP-IDF：选任务算法对照（本章暗线主场）

| 维度                      | Vanilla v10.5.1（单核）           | IDF fork（默认树，双核 SMP）                                                  |
| ------------------------- | --------------------------------- | ----------------------------------------------------------------------------- |
| 选择算法                  | 水位线下扫 / 位图+CLZ（端口可选） | 恒为扫描（位图优化被禁用）                                                    |
| `uxTopReadyPriority` 语义 | 优先级数（或位图）                | 优先级高水位线，仅向上推，选中时惰性修正                                      |
| 入选判据                  | 该层非空即可                      | 该层非空 **且** 任务没在另一个核上跑 **且** 核亲和兼容                        |
| 同层内取谁                | `pxIndex` 游标步进（精确轮转）    | 从队首遍历，**选中的任务搬到队尾**（Best-Effort 轮转）                        |
| "当前任务"                | 单个 `pxCurrentTCB`               | `pxCurrentTCBs[ configNUMBER_OF_CORES ]`，每核一个                            |
| 本核正在跑的任务          | 直接续跑（游标天然跳过）          | 明确允许重选自己（切换中本来就要让位）                                        |
| 亲和性概念                | 无                                | TCB 内 `xCoreID`（0/1/`tskNO_AFFINITY`），`taskIS_AFFINITY_COMPATIBLE()` 判定 |

最后一行的实现值得单独看——IDF fork 用**单个 `xCoreID` 字段**表达亲和（钉死一个核，或不钉），而实验性的上游 SMP 内核用的是 `uxCoreAffinityMask` 位掩码（可同时钉多个核）。两种建模的取舍在 [[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|第二十二章]] 展开。

### 4. IDF SMP 实现：`prvSelectHighestPriorityTaskSMP()` 逐段读

`configNUMBER_OF_CORES > 1` 时，宏直接转调这个函数（`tasks.c`；下为省略变量声明与 trace 宏后的节选，控制流与源码一致）：

```c
static void prvSelectHighestPriorityTaskSMP( void )
{
    BaseType_t uxCurPriority;
    BaseType_t xTaskScheduled = pdFALSE;
    BaseType_t xCurCoreID = portGET_CORE_ID();

    for( uxCurPriority = uxTopReadyPriority;
         uxCurPriority >= 0 && xTaskScheduled == pdFALSE;
         uxCurPriority-- )
    {
        if( listLIST_IS_EMPTY( &( pxReadyTasksLists[ uxCurPriority ] ) ) ) {
            continue;                          /* 空层直接跳过 */
        }
        /* 第一个非空层：顺手把水位线修正到这里 */
        if( xNewTopPrioritySet == pdFALSE ) {
            xNewTopPrioritySet = pdTRUE;
            uxTopReadyPriority = uxCurPriority;
        }
        /* 游标复位到尾标记，从队首开始走 */
        pxReadyTasksLists[ uxCurPriority ].pxIndex =
            ( ListItem_t * ) &( pxReadyTasksLists[ uxCurPriority ].xListEnd );
        listGET_OWNER_OF_NEXT_ENTRY( pxTCBCur, &( pxReadyTasksLists[ uxCurPriority ] ) );
        pxTCBFirst = pxTCBCur;

        do {
            /* 检查①：该任务是否已在另一个核上运行 */
            for( x = 0; x < configNUMBER_OF_CORES; x++ ) {
                if( x != xCurCoreID && pxCurrentTCBs[ x ] == pxTCBCur ) {
                    goto get_next_task;        /* 别的核正在跑，跳过 */
                }
            }
            /* 检查②：核亲和是否允许在本核运行 */
            if( taskIS_AFFINITY_COMPATIBLE( xCurCoreID, pxTCBCur ) == pdFALSE ) {
                goto get_next_task;            /* 钉死在另一个核，跳过 */
            }
            /* 可运行：登记为本核当前任务 */
            pxCurrentTCBs[ xCurCoreID ] = pxTCBCur;
            xTaskScheduled = pdTRUE;

            /* Best-Effort 轮转：把选中任务搬到队尾 */
            pxReadyTasksLists[ uxCurPriority ].pxIndex =
                ( ListItem_t * ) &( pxReadyTasksLists[ uxCurPriority ].xListEnd );
            listREMOVE_ITEM( &( pxTCBCur->xStateListItem ) );
            listINSERT_END( &( pxReadyTasksLists[ uxCurPriority ] ),
                            &( pxTCBCur->xStateListItem ) );
            break;

get_next_task:
            listGET_OWNER_OF_NEXT_ENTRY( pxTCBCur, &( pxReadyTasksLists[ uxCurPriority ] ) );
        } while( pxTCBCur != pxTCBFirst );     /* 走完一圈为止 */
    }
    configASSERT( xTaskScheduled == pdTRUE );  /* Idle 任务兜底，必然选中 */
}
```

四层结构：**层间从高到低扫 → 层内从队首遍历 → 每个候选过两道检查 → 选中后搬队尾**。注意两个精妙处：

1. **"别的核正在跑"只挡别的核**——本核当前任务不在跳过之列，因为它马上就要被切换出去，重选它续跑完全合法；
2. **`configASSERT( xTaskScheduled == pdTRUE )` 之所以敢断言必然选中**，是因为启动调度器时给每个核都创建了钉死的 Idle 任务：扫到优先级 0 时，本核的 Idle 任务永远亲和兼容、永远没在别的核上跑。兜底即正确性。

### 5. "Best-Effort" 到底 best-effort 在哪

Vanilla 的游标轮转保证：同优先级 N 个任务，连续 N 次调度每人恰好一次。IDF fork 把"选中者搬到队尾"，看起来等价，但**扫描可以中途跳过任务**（在别的核上跑 / 亲和不符），被跳过的任务**不会**搬到队尾——它保持原位。于是当那个核稍后让出、本核再扫描时，可能再次先遇到它前面的任务。轮转仍然"最终公平"，但不再"逐拍公平"。官方文档称之为 **Best-Effort Round-Robin**，定量分析留给 [[2026-08-26-freertos-deep-dive-ch8-priority-timeslice-rr|第八章]]。

---

## 6.5 `eTaskGetState()`：从链表位置反推状态

第五章的状态机（Running / Ready / Blocked / Suspended / Deleted）没有独立的状态变量——**状态是链表位置的函数**。`eTaskGetState()` 的实现就是一张判定表：

| `xStateListItem` 挂在哪                     | `xEventListItem` 挂在哪  | 判定                                  |
| ------------------------------------------- | ------------------------ | ------------------------------------- |
| ——（任务在 `pxCurrentTCBs[0]` 或 `[1]` 里） | ——                       | `eRunning`                            |
| 阻塞链表（两选一）                          | 任意（可能等事件）       | `eBlocked`                            |
| `xSuspendedTaskList`                        | `NULL`（不在等任何对象） | `eSuspended`（或等通知 → `eBlocked`） |
| `xSuspendedTaskList`                        | 非 `NULL`（在等某事件）  | `eBlocked`（无限期阻塞）              |
| `xTasksWaitingTermination` 或 `NULL`        | ——                       | `eDeleted`（TCB 尚未释放）            |
| 其他（含 `xPendingReadyList`）              | ——                       | `eReady`                              |

三个容易误判的细节，全部来自源码：

1. **无限期阻塞 = 挂起链表**。`xQueueReceive(q, &buf, portMAX_DELAY)` 的任务物理上就住在 `xSuspendedTaskList`——内核把"没有唤醒期限的等待"与"被挂起"合并存储，靠 `xEventListItem` 是否为空区分。所以 `eTaskGetState()` 要看第二个节点才能给出正确答案。
2. **任务通知是隐式事件**。等通知的任务 `xEventListItem` 也是空的（通知不经过任何内核对象），所以还要补一刀：遍历 `ucNotifyState[]` 数组，有 `taskWAITING_NOTIFICATION` 就改判 `eBlocked`。这是 13 章伏笔。
3. **IDF 的 Running 判定查两个核**。`taskIS_CURRENTLY_RUNNING( pxTCB )` 展开为 `pxTCB == pxCurrentTCBs[0] || pxTCB == pxCurrentTCBs[1]`——SMP 里"在跑"意味着"在任一核上跑"。

整张表在内核锁（`taskENTER_CRITICAL( &xKernelLock )`）里采样：两个节点的 `pxContainer` 必须在同一瞬间读取，否则可能读到任务迁移了一半的中间态。

> [!tip] 调试小抄
> GDB 里手查任务状态：`pxCurrentTCBs[0]`/`[1]` 是在跑的任务；对任意 TCB 打 `xStateListItem.pxContainer`，与 `pxReadyTasksLists[n]`、`xDelayedTaskList1/2`、`xSuspendedTaskList`、`xTasksWaitingTermination` 的地址比对即可定位状态——不需要任何 API。QEMU 下 `idf.py qemu gdb` 断在任意调度点就能练手。

---

## 6.6 谁在搬动这些链表：tick 引擎一句话版

链表是静态结构，让它动起来的发动机是 tick 中断（默认 100Hz，1 tick = 10ms）。与本章相关的只有一件事：**到期唤醒**。`xTaskIncrementTick()`（`tasks.c`）里，`pxDelayedTaskList` 因按唤醒时刻有序插入，队首就是最早该醒的任务——比较 `xTickCount` 与队首的 `xItemValue`，没到就更新 `xNextTaskUnblockTime` 收工（一次比较搞定"无事可做"的 tick），到了就把队首摘链、`prvAddTaskToReadyList()` 送回就绪队列。

双核分工（`idf_changes.md` 原文）：**每个核都收到 tick 中断，但只有 Core 0 调 `xTaskIncrementTick()`**（计时 + 解锁 + 时间片 + hook 全在 Core 0），**Core 1 调 `xTaskIncrementTickOtherCores()`**——定义在 `components/freertos/esp_additions/freertos_tasks_c_additions.h`，只做时间片检查、`xYieldPending` 检查和 tick hook。这个函数之所以住在 `esp_additions/`，是因为它要访问 `tasks.c` 的文件级静态变量，只能通过 `freertos_tasks_c_additions.h` 机制**文本注入**进 `tasks.c` 编译——一个"内核没有暴露钩子，就把自己塞进内核源文件"的工程手法。tick 分工的完整时序留到第八、九章。

---

## 6.7 实验：用 `uxTaskGetSystemState()` 打印任务全景

读了一章链表，现在亲眼验证"任务住在链表里"。`configUSE_TRACE_FACILITY` 打开后，`uxTaskGetSystemState()` 会对**每条链表**做一次快照（内部正是遍历 `pxReadyTasksLists` 各层 + 两条阻塞链表 + 挂起 + 等待终止，逐任务调 `vTaskGetInfo()` 填 `TaskStatus_t`），把结果交给你打印。

### 1. 打开配置

`CONFIG_FREERTOS_USE_TRACE_FACILITY` 在 v6.0.2 默认是关的，需要显式打开（顺带打开 CoreID 列，方便看亲和）：

```bash
idf.py menuconfig
# Component config -> FreeRTOS ->
#   [*] configUSE_TRACE_FACILITY
#   [*] Add core id to task list   (CONFIG_FREERTOS_VTASKLIST_INCLUDE_COREID)
```

或者直接写 `sdkconfig.defaults`：

```text
CONFIG_FREERTOS_USE_TRACE_FACILITY=y
CONFIG_FREERTOS_VTASKLIST_INCLUDE_COREID=y
```

### 2. 实验程序

设计一组任务，让 6.2 节的每条链表**在同一时刻都有住户**：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

static TaskHandle_t s_nap_handle;
static SemaphoreHandle_t s_never_given;

/* 住户①：周期延时 → 大部分时间住阻塞链表 */
static void delay_task(void *arg)
{
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(300));
    }
}

/* 住户②③：同优先级忙等+让出 → 在就绪层内轮转 */
static void spin_task(void *arg)
{
    for (;;) {
        taskYIELD();               /* 主动让出，留在就绪链表 */
    }
}

/* 住户④：无限期等一个永不给出的信号量。
 * 注意：vTaskDelay(portMAX_DELAY) 不走这条路——它传入的是"不许无限期阻塞"，
 * 任务会带着一个巨大的唤醒时刻睡在阻塞链表；真正住进挂起链表的是
 * 等内核对象 + portMAX_DELAY 的任务（prvAddCurrentTaskToDelayedList 的
 * xCanBlockIndefinitely 分支）。 */
static void nap_task(void *arg)
{
    for (;;) {
        xSemaphoreTake(s_never_given, portMAX_DELAY);
    }
}

/* 快照打印者 */
static void monitor_task(void *arg)
{
    for (;;) {
        UBaseType_t n = uxTaskGetSystemState(NULL, 0, NULL);  /* 第一次：只要数量 */
        TaskStatus_t *stats = pvPortMalloc(n * sizeof(TaskStatus_t));
        if (stats != NULL) {
            configRUN_TIME_COUNTER_TYPE total = 0;
            n = uxTaskGetSystemState(stats, n, &total);       /* 第二次：真拿数据 */
            printf("%-12s %-4s %-8s %-6s %s\n", "NAME", "CORE", "STATE", "PRIO", "STACK");
            for (UBaseType_t i = 0; i < n; i++) {
                printf("%-12s %-4d %-8d %-6d %u\n",
                       stats[i].pcTaskName,
                       stats[i].xCoreID,
                       stats[i].eCurrentState,
                       stats[i].uxCurrentPriority,
                       (unsigned)stats[i].usStackHighWaterMark);
            }
            vPortFree(stats);
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

void app_main(void)
{
    s_never_given = xSemaphoreCreateBinary();  /* 创建后为空，永远没人 give */
    xTaskCreate(delay_task, "delay", 2048, NULL, 3, NULL);
    xTaskCreate(spin_task, "spin_a", 2048, NULL, 2, NULL);
    xTaskCreate(spin_task, "spin_b", 2048, NULL, 2, NULL);
    xTaskCreate(nap_task, "nap", 2048, NULL, 4, &s_nap_handle);
    vTaskDelay(pdMS_TO_TICKS(50));             /* 等 nap 睡进挂起链表 */
    vTaskSuspend(s_nap_handle);                /* 再把它"真挂起"：拔掉事件等待 */
    xTaskCreate(monitor_task, "monitor", 4096, NULL, 5, NULL);
}
```

### 3. 跑起来

```bash
idf.py qemu monitor
```

典型输出（每 2 秒一轮，数值随快照时刻浮动）：

```text
NAME         CORE STATE     PRIO   STACK
monitor      -1   0         5      1298
nap          -1   3         4      1966
delay        -1   2         3      1934
spin_a       -1   1         2      1042
spin_b       -1   1         2      1044
ipc0         0    1         1      746
IDLE0        0    1         1      634
IDLE1        1    1         1      634
...
```

（STATE 列直接打印了枚举数值：`eRunning=0`、`eReady=1`、`eBlocked=2`、`eSuspended=3`、`eDeleted=4`，见 `task.h` 的 `eTaskState`。CORE 列是**绑定核**而非"当前正在哪个核上跑"：`-1` 即 `tskNO_AFFINITY`——用 `xTaskCreate` 创建的任务不绑核；`IDLE0`/`IDLE1`/`ipc0` 钉核所以显示 0/1。`...` 处还有随配置增减的系统任务，如 `esp_timer`、`main` 等。）

### 4. 观察点

对着 6.2 的全景图逐条验证：

1. **`nap` 显示 `eSuspended`（3）**——它正被 `vTaskSuspend()` 挂起。做个对照实验：把 `app_main` 里 `vTaskSuspend()` 那行注释掉，`nap` 会变成 `eBlocked`（2）——**但它的 `xStateListItem` 仍挂在同一条 `xSuspendedTaskList` 上**（6.5 节的合并存储）。区分这两种"住户"的正是 `xEventListItem` 是否为空，`eTaskGetState()` 内部就是这么判的。
2. **`delay` 显示 `eBlocked`（2）**——快照时刻它大概率睡在 `pxDelayedTaskList` 里。偶尔会抓到 `eReady`（1）：正好在唤醒瞬间。
3. **`monitor` 显示 `eRunning`（0），而"另一个核正在跑的任务"只会显示 `eReady`**——`vTaskGetInfo()` 只把**调用者本核**的 `pxCurrentTCBs[ portGET_CORE_ID() ]` 标为 Running；快照时刻无法证明另一核的任务在跑，它人如其名地待在就绪链表里。想看两个 spinner 分踞两核，给 `spin_task` 加一行 `printf("[spin] core %d\n", xPortGetCoreID())`——通常一个 0 一个 1，这正是 6.4 节"跳过别的核正在跑的任务"的效果：Core 0 选走 `spin_a` 后，Core 1 扫描时跳过它、选中 `spin_b`。
4. **两个 `IDLE`**——`IDLE0`、`IDLE1` 各钉一个核（CORE 列 0/1），`prvSelectHighestPriorityTaskSMP()` 末尾那个"必然选中"断言的兜底。
5. **STACK 列是最小剩余栈（高水位）**——顺手白拿一个栈监控工具，原理在 [[2026-08-26-freertos-deep-dive-ch21-stack-and-memory-layout|第二十一章]]。

> [!note] 为什么调两次 `uxTaskGetSystemState()`
> 第一次传 `NULL` 数组只为拿到任务总数（返回值即数量），据此分配 `TaskStatus_t` 数组后再调一次取真数据。两次调用之间任务数可能变化，第二次的返回值应以实际填入数为准。这也是官方文档示范的惯用法。

---

## 6.8 小结

- `list.c` 是内核唯一的数据结构底座：侵入式双向循环链表，节点内嵌宿主、`pvOwner` 回指、`pxContainer` 自描述，增删 O(1)；尾标记哨兵消灭一切边界判断。IDF fork 在此文件上与 Vanilla v10.5.1 几乎零差异，仅加热路径内联宏。
- 调度器全景五类链表：分层就绪队列 `pxReadyTasksLists[25]`、按唤醒时刻有序的双阻塞链表（tick 溢出对翻）、每核一条的 `xPendingReadyList`、`xSuspendedTaskList`（兼收无限期阻塞）、`xTasksWaitingTermination`（等 Idle 回收）。一个 TCB 靠 `xStateListItem`/`xEventListItem` 双节点同时表达"住在哪"和"在等谁"。
- 选任务 = 从 `uxTopReadyPriority` 向下扫第一个非空就绪层。Vanilla 可用位图 + CLZ 把找层做成一条指令；IDF fork 禁用位图，SMP 下每层内逐任务检查"是否在别的核上跑"与"核亲和"，选中者搬到队尾实现 Best-Effort 轮转；每核钉死的 Idle 任务保证扫描必然命中。
- `eTaskGetState()` 是链表位置的判定表：查两个节点的 `pxContainer` 即可反推状态；无限期阻塞与挂起同住一条链表，靠 `xEventListItem`（和通知状态）区分。
- 实验：`CONFIG_FREERTOS_USE_TRACE_FACILITY` + `uxTaskGetSystemState()` 两次调用法打印全系统任务快照，在 QEMU 里亲眼看到每条链表的"住户"，并白拿栈高水位监控。

链表选出了下一个该跑的任务，但它只是把 `pxCurrentTCBs[core]` 指针换了个人。从"指针换了"到"CPU 真的在跑新任务的代码"，中间还隔着整个上下文切换：寄存器现场怎么保存恢复、切换在哪段汇编里发生、为什么 Xtensa 要小心翼翼地对待它的寄存器窗口。下一章 [[2026-08-26-freertos-deep-dive-ch7-context-switch-deep-dive|第七章：上下文切换]] 把这条路径走到底。
