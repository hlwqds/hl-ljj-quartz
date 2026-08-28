---
title: "FreeRTOS 深度解析（八）：优先级、时间片与 Round-Robin"
date: 2026-08-26
description: "把'同优先级任务谁先跑'拆到源码级：Vanilla 用链表游标实现的完美 Round-Robin、IDF fork 每核独立选择导致的 Best-Effort 轮转（含官方 AX/B0/C1/D0 案例逐步图解）、vTaskPrioritySet 的立即重调度，以及用 tick 所有权记录器让时间片在 QEMU 里现形的实验。"
tags: [freertos, rtos, esp32, esp-idf, scheduler, time-slicing, round-robin, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 8. **第八章：优先级、时间片与 Round-Robin**

# FreeRTOS 深度解析（八）：优先级、时间片与 Round-Robin

[[2026-08-26-freertos-deep-dive-ch6-scheduler-ready-lists|第 6 章]]把就绪链表与"选最高优先级"的机制拆完，[[2026-08-26-freertos-deep-dive-ch7-context-switch-deep-dive|第 7 章]]跟着一次上下文切换走完了汇编。但调度器的故事还差一角：**当两个任务优先级完全相同，谁先跑？**本章把这个问题拆到源码级——Vanilla 的完美 Round-Robin 靠一条链表游标实现；IDF fork 为什么只能做到 Best-Effort；动态改优先级时内核如何立即重调度。实验部分用一台"tick 所有权记录器"，把每 10ms 一次的时间片轮转换成肉眼可见的日志。

> [!note] 本章源码基线
> IDF 侧引用默认编译的 `components/freertos/FreeRTOS-Kernel/`（IDF fork 本体，Vanilla v10.5.1 加 SMP 改造）；Vanilla 侧引用上游 `V10.5.1`。`FreeRTOS-Kernel-SMP/` 是实验性上游 Amazon SMP 内核（`CONFIG_FREERTOS_SMP`，默认关），两棵树详见第 4、22 章。

## 8.1 固定优先级：创建即定，永不自愈

### 1. 调度不变式与"固定"的含义

FreeRTOS 官方对自己调度器的定性是**固定优先级抢占式调度，带时间片**（fixed priority preemptive scheduling with time slicing）。"固定"的含义要抠清楚：

- 优先级在 `xTaskCreate()` 的 `uxPriority` 参数处一次定型，写进 TCB 的 `uxPriority` 字段（[[2026-08-26-freertos-deep-dive-ch5-task-lifecycle-and-tcb|第 5 章]]）；
- 内核**永远不会**因为"某任务等得太久"而悄悄提它的优先级——没有老化（aging）机制；
- 想改只有两条路：应用自己调 `vTaskPrioritySet()`（8.5 节），或互斥量优先级继承被动地临时改（[[2026-08-26-freertos-deep-dive-ch11-semaphore-mutex-priority-inheritance|第 11 章]]）。

于是调度器每时每刻维护的不变式是：

```text
    「正在 CPU 上运行的任务，优先级 >= 所有就绪任务的优先级」
     等号成立时（同一优先级有多个就绪任务），才轮到时间片说话。
```

本章的全部内容，就是这句"等号成立时"在单核与双核下的两种命运。

### 2. 没有老化，饿死是设计内的风险

固定优先级 + 无老化的直接代价是**饥饿是合法状态**。三种典型成因：

| 成因                    | 场景                         | 结构性对策                                   |
| ----------------------- | ---------------------------- | -------------------------------------------- |
| 高优先级任务永不阻塞    | 忙循环或长计算               | 高优先级任务必须有阻塞点（等队列/延时/事件） |
| 高优先级任务高频短唤醒  | 每 1ms 醒一次干 200µs        | 合并事件、降低唤醒频率、或拉开优先级差距     |
| 同级任务过多 + 亲和不均 | 本章 8.3 的 Best-Effort 轮转 | 同优先级钉同核（8.3.5）                      |

对照 Linux 的 CFS：那边按虚拟运行时间补偿，等得久的任务权重自动上升。FreeRTOS 里这类概念**连存在都没有**——换来的是调度路径极短且完全可分析（第 6、7 章已看到整条路径不过几十条指令）。实时性是设计出来的，内核只保证"不挡路"。

### 3. configMAX_PRIORITIES 与就绪数组的成本

第 6 章讲过，就绪结构是 `pxReadyTasksLists[configMAX_PRIORITIES]` 数组——每个优先级一条链表。本节补上成本账：

| 项       | Vanilla                                              | IDF（默认树）                      |
| -------- | ---------------------------------------------------- | ---------------------------------- |
| 定义处   | 应用的 `FreeRTOSConfig.h` 自定                       | `FreeRTOSConfig.h` 写死为 `( 25 )` |
| 典型取值 | 5~32 按需                                            | 恒 25，无 Kconfig 可调             |
| 每级开销 | 一个 `List_t`（游标指针 + 哨兵 + 计数，20 字节量级） | 同左                               |
| 选择算法 | 从 `uxTopReadyPriority` 向下探；部分端口可 CLZ 优化  | 双核下纯线性向下探                 |

三笔账：一，25 级 ≈ 500+ 字节常驻 RAM，不大但也不是零，Vanilla 应用按需设小是正经优化；二，`uxTopReadyPriority`（`tasks.c` 的全局变量，`taskRECORD_READY_PRIORITY` 宏只升不降地维护它）把"找最高非空级"从 O(数组宽度) 摊薄成 O(活跃跨度)；三，Vanilla 在支持前导零指令的端口（如 Cortex-M）开 `configUSE_PORT_OPTIMISED_TASK_SELECTION` 可把选择压成 O(1)，而 IDF 的对应选项 `CONFIG_FREERTOS_OPTIMIZED_SCHEDULER` **只在单核配置下可用**——双核 ESP32 永远走通用扫描，这正是 8.3 要精读的那段代码。

> [!tip] Vanilla vs ESP-IDF：优先级相关配置面
>
> | 配置                     | Vanilla  | IDF（默认树）          |
> | ------------------------ | -------- | ---------------------- |
> | `configMAX_PRIORITIES`   | 应用自定 | 写死 25                |
> | `configUSE_PREEMPTION`   | 应用自定 | 固定 1（抢占不可关）   |
> | `configUSE_TIME_SLICING` | 应用自定 | 固定 1（时间片不可关） |
> | 端口优化任务选择         | 可选开启 | 双核下不可用           |
>
> 在 IDF 里没有"关时间片做纯固定优先级调度"的配置余地；想模拟这种语义，只能让任务级级优先级不同。

### 4. 优先级怎么分配（工程速查）

- `0` 保留给 Idle（每核一个，钉死）；`1` 是 `main` 任务（`app_main` 所在）与若干系统任务的默认档；
- 数值越大越优先，但别从 0 排满——给"ISR 唤醒的紧急任务"在顶端留 headroom，将来加任务不用整体重排；
- 优先用**同优先级分组**而不是每任务一级——同级才有时间片兜底，级级不同等于亲手关掉了公平性。

---

## 8.2 Vanilla 的时间片：一条游标转出完美轮转

### 1. 时间片发生的三个条件

同时满足才有时间片轮转：`configUSE_PREEMPTION == 1`（开着，默认开）、`configUSE_TIME_SLICING == 1`（开着，默认开），再加一条运行时状态——**当前运行任务的优先级上，就绪链表长度大于 1**（"我这一级人多"）。前两条是配置，第三条由 tick 中断每个周期检查一次。默认 `configTICK_RATE_HZ`（IDF 里即 `CONFIG_FREERTOS_HZ`，默认 100）下，检查每 10ms 发生一次——**时间片长度恒等于一个 tick 周期**，FreeRTOS 没有"可配置片长"的概念。

### 2. Vanilla 的选择器：游标 pxIndex

`vTaskSwitchContext()`（单核）调用 `taskSELECT_HIGHEST_PRIORITY_TASK()` 宏。通用实现（`configUSE_PORT_OPTIMISED_TASK_SELECTION == 0` 分支，V10.5.1 `tasks.c`）：

```c
#define taskSELECT_HIGHEST_PRIORITY_TASK()                                \
{                                                                         \
    UBaseType_t uxTopPriority = uxTopReadyPriority;                       \
    /* Find the highest priority queue that contains ready tasks. */      \
    while( listLIST_IS_EMPTY( &( pxReadyTasksLists[ uxTopPriority ] ) ) ) \
    {                                                                     \
        uxTopPriority--;                                                  \
    }                                                                     \
    /* listGET_OWNER_OF_NEXT_ENTRY indexes through the list, so the tasks \
     * of the same priority get an equal share of the processor time. */  \
    listGET_OWNER_OF_NEXT_ENTRY( pxCurrentTCB, &( pxReadyTasksLists[ uxTopPriority ] ) ); \
    uxTopReadyPriority = uxTopPriority;                                   \
}
```

魔法全在 `listGET_OWNER_OF_NEXT_ENTRY`（`list.h`）：它**不总是取链表头**，而是推进链表自带的游标 `pxIndex`：

```c
( pxConstList )->pxIndex = ( pxConstList )->pxIndex->pxNext;
if( ( pxConstList )->pxIndex == &( ( pxConstList )->xListEnd ) )  /* 撞上哨兵 */
{
    ( pxConstList )->pxIndex = ( pxConstList )->pxIndex->pxNext;  /* 跳过去=回到头部 */
}
( pxTCB ) = ( pxConstList )->pxIndex->pvOwner;
```

于是同优先级链表 `[A, B, C]` 上每次选择依次拿到 A→B→C→A→…，一人一个 tick。注意：**被选中的任务在链表里纹丝不动，轮转完全靠游标走**。这是 Vanilla 与 IDF 实现上最根本的分叉点。

```text
   环形链表（xListEnd 是哨兵，不属于任何任务）:

     xListEnd ⇄ [A] ⇄ [B] ⇄ [C] ⇄ (回到 xListEnd)

   tick N   : pxIndex 推进到 A → 选中 A
   tick N+1 : pxIndex 推进到 B → 选中 B
   tick N+2 : pxIndex 推进到 C → 选中 C
   tick N+3 : pxIndex 撞上哨兵 → 跳过 → 回到 A

   任务不动，游标走。每个任务两次被选中的间隔 === 同级任务数 × 1 tick
```

### 3. tick 中断里的时间片判断

`xTaskIncrementTick()`（V10.5.1 `tasks.c`，节选）——解锁超时任务的主循环之后：

```c
/* Tasks of equal priority to the currently running task will share
 * processing time (time slice) if preemption is on, and the application
 * writer has not explicitly turned time slicing off. */
#if ( ( configUSE_PREEMPTION == 1 ) && ( configUSE_TIME_SLICING == 1 ) )
{
    if( listCURRENT_LIST_LENGTH( &( pxReadyTasksLists[ pxCurrentTCB->uxPriority ] ) )
            > ( UBaseType_t ) 1 )
    {
        xSwitchRequired = pdTRUE;
    }
}
#endif
```

判断对象是**当前运行任务自己那一优先级的就绪链表长度**。返回 `pdTRUE` 后端口层执行 `portYIELD_FROM_ISR()`，走进 `vTaskSwitchContext()`，上面的游标选择器换回"下一个"任务。同函数里还有两个协作角色：解锁任务优先级**严格高于**当前任务（`pxTCB->uxPriority > pxCurrentTCB->uxPriority`）时也置 `xSwitchRequired`（这是抢占路径，不走时间片）；`xYieldPending` 被置位（比如调度器挂起期间欠下的切换）同样折算进来。

> [!note] 一个流传很广的不精确说法
> 不少资料把这个时间片判断描述成"检查 `uxTopReadyPriority` 是否等于 `pxCurrentTCB->uxPriority`"。以 v10.5.1 源码为准：它检查的是**当前任务所在就绪链表的长度**，不是两个优先级数值的比较。多数场景两者结论一致（当前任务通常就处在最高就绪级），但语义不同——链表长度判断把"同级多人"这个真正前提原样包含了进来。

### 4. 完美轮转的时间线

```text
 tick:    100     101     102     103     104     105
          │       │       │       │       │       │
 CPU:     A       B       A       B       A       B      ← 每 tick 必换
          └───────┴───────┴───────┴───────┴───────┴──
 链表:   [A, B] 全程不变（任务不动，游标走）
 前提:   A、B 持续就绪（不阻塞、不被更高优先级压住）

 "完美"的含义：间隔恒定 = 同级任务数 × 1 tick，无饥饿、无例外、可数学归纳
```

---

## 8.3 IDF fork：每核独立选择与 Best-Effort RR

单核世界里"链表头是谁"就决定了轮转顺序；双核世界里**每个核各自做选择**，同一个任务可能被这个核跳过、被那个核选中——完美轮转从此失守。

### 1. 先分清谁在打 tick

两个核各自有独立的 tick 中断（同频、相位可不同）。公共入口 `xPortSysTickHandler()`（`port_systick.c`）按核分派：

```c
#if ( configNUM_CORES > 1 )
    /*
    Multi-core IDF FreeRTOS requires that...
        - core 0 calls xTaskIncrementTick()
        - core 1 calls xTaskIncrementTickOtherCores()
    */
    if( xPortGetCoreID() == 0 ) {
        xSwitchRequired = xTaskIncrementTick();
    } else {
        xSwitchRequired = xTaskIncrementTickOtherCores();
    }
#else
    ...
#endif
```

（`xTaskIncrementTick()` 开头有 `configASSERT( portGET_CORE_ID() == 0 )`，函数级强制。）职责分工：

| 职责                         | Core 0（`xTaskIncrementTick`） | Core 1（`xTaskIncrementTickOtherCores`） |
| ---------------------------- | ------------------------------ | ---------------------------------------- |
| `xTickCount++`、溢出换延迟表 | ✅                             | ❌                                       |
| 解锁超时任务（延迟链表扫描） | ✅                             | ❌                                       |
| 时间片检查                   | ✅（查 Core 0 当前任务）       | ✅（查 Core 1 当前任务）                 |
| 把抢占需求路由给对方核       | ✅（置 `xYieldPending[1]`）    | ❌                                       |
| `vApplicationTickHook`       | ✅                             | ✅                                       |

`xTaskIncrementTickOtherCores()`（`esp_additions/freertos_tasks_c_additions.h`，逻辑全貌几乎就是这段）：

```c
BaseType_t xTaskIncrementTickOtherCores( void )
{
    BaseType_t xCoreID = portGET_CORE_ID();
    BaseType_t xSwitchRequired = pdFALSE;
    configASSERT( xCoreID != 0 );
    ...
    if( uxSchedulerSuspended[ xCoreID ] == ( UBaseType_t ) 0U )
    {
        taskENTER_CRITICAL_ISR( &xKernelLock );
        if( listCURRENT_LIST_LENGTH( &( pxReadyTasksLists[ pxCurrentTCBs[ xCoreID ]->uxPriority ] ) )
                > ( UBaseType_t ) 1 )
        {
            xSwitchRequired = pdTRUE;    /* 时间片：我这一级人多，该轮换了 */
        }
        taskEXIT_CRITICAL_ISR( &xKernelLock );
        if( xYieldPending[ xCoreID ] != pdFALSE )
        {
            xSwitchRequired = pdTRUE;    /* 有人（多半是 Core 0）给我留了抢占请求 */
        }
    }
    ...
    return xSwitchRequired;
}
```

两个细节值得停一下：一，时间片判断与 Vanilla 同形，但对象换成 `pxCurrentTCBs[xCoreID]`——**每个核只问"我自己这一级"**，双核下"同级人多不多"不再有全局答案。二，Core 0 在 `xTaskIncrementTick()` 里发现某个解锁任务应该去 Core 1 跑时，只置 `xYieldPending[1]` 标志、**不打断 Core 1**，后者要到自己的下一个 tick 才看到它（最坏延迟一个 tick）；API 路径（队列解锁、任务通知等）没这么慢——它们经 `taskIS_YIELD_REQUIRED()` → `prvIsYieldRequiredSMP()` 直接 `taskYIELD_CORE(对方核)` 发核间中断（[[2026-08-26-freertos-deep-dive-ch23-cross-core-synchronization|第 23 章]]）。

顺带一提 tick 的相位：SYSTIMER 路径的 `vSystimerSetup()` 刻意把两核告警错开半个周期（源码注释原话 "SysTick of core 0 and core 1 are shifted by half of period"），经典 ESP32 的 CCOUNT 路径则天然不同相。错相让两核的 tick 处理尽量不撞车，也顺便把上面那个"最坏一 tick"的抢占延迟平均压到半 tick。

### 2. 选择器：prvSelectHighestPriorityTaskSMP 精读

每核的 `vTaskSwitchContext()` → `taskSELECT_HIGHEST_PRIORITY_TASK()` →（SMP 分支）`prvSelectHighestPriorityTaskSMP()`。骨架（默认树 `tasks.c`，节选删减）：

```c
static void prvSelectHighestPriorityTaskSMP( void )
{
    BaseType_t uxCurPriority;
    BaseType_t xTaskScheduled = pdFALSE;
    BaseType_t xCurCoreID = portGET_CORE_ID();

    for( uxCurPriority = uxTopReadyPriority;                     /* 从最高就绪级向下探 */
          uxCurPriority >= 0 && xTaskScheduled == pdFALSE; uxCurPriority-- )
    {
        if( listLIST_IS_EMPTY( &( pxReadyTasksLists[ uxCurPriority ] ) ) ) {
            continue;                                            /* 这级没人，降一级 */
        }
        /* 把游标拨回哨兵，从链表头开始走 */
        pxReadyTasksLists[ uxCurPriority ].pxIndex =
            ( ListItem_t * ) &( pxReadyTasksLists[ uxCurPriority ].xListEnd );
        listGET_OWNER_OF_NEXT_ENTRY( pxTCBCur, &( pxReadyTasksLists[ uxCurPriority ] ) );
        pxTCBFirst = pxTCBCur;
        do {
            for( x = 0; x < configNUMBER_OF_CORES; x++ ) {
                if( x != xCurCoreID && pxCurrentTCBs[ x ] == pxTCBCur ) {
                    goto get_next_task;                          /* 别的核正在跑它：跳过 */
                }
            }
            if( taskIS_AFFINITY_COMPATIBLE( xCurCoreID, pxTCBCur ) == pdFALSE ) {
                goto get_next_task;                              /* 亲和不许上本核：跳过 */
            }
            pxCurrentTCBs[ xCurCoreID ] = pxTCBCur;              /* 选中 */
            /* Move the current tasks list item to the back of the list in order
             * to implement best effort round robin. ... */      ← 源码原注释
            listREMOVE_ITEM( &( pxTCBCur->xStateListItem ) );
            listINSERT_END( &( pxReadyTasksLists[ uxCurPriority ] ), &( pxTCBCur->xStateListItem ) );
            break;
get_next_task:
            listGET_OWNER_OF_NEXT_ENTRY( pxTCBCur, &( pxReadyTasksLists[ uxCurPriority ] ) );
        } while( pxTCBCur != pxTCBFirst );                       /* 整条链表走完一圈 */
    }
    configASSERT( xTaskScheduled == pdTRUE );    /* 每核一个钉死的 Idle 兜底，必命中 */
}
```

亲和判断 `taskIS_AFFINITY_COMPATIBLE(核, 任务)` 就一行：`任务->xCoreID == 核 || 任务->xCoreID == tskNO_AFFINITY`（`tskNO_AFFINITY = 0x7FFFFFFF`，即 `xTaskCreatePinnedToCore()` 的"不钉"参数）。

与 Vanilla 的三点本质差异：

1. **每次都从头扫**：每轮选择把 `pxIndex` 拨回哨兵、从链表头重新开始——游标的"记住上次选到哪"被废掉了；
2. **两个跳过条件**：任务正在别的核上跑；任务亲和不允许上本核。被跳过的任务原地不动；
3. **选中即移队尾**：`listREMOVE_ITEM` + `listINSERT_END`。Best-Effort RR 的全部秘密就这两行——源码注释原话 "to implement best effort round robin"。

轮转的机理由此而来：被选中者去队尾 → 队头天然变成"最久没被选的" → 下次从头扫时它们排在最前面。**但它只是尽力而为**：如果队头几个任务对本核都不可运行，扫描会一路跳过，队中靠后的任务就得再等一轮。（兜底：每个核有一个钉死在该核的 Idle 任务，扫描必然命中——这也解释了为什么某级找不到可跑任务时是"降级去跑低优先级"而不是卡死。）

### 3. AX/B0/C1/D0：五步链表演化

这是官方文档（`freertos_idf.rst`）的演示案例，也是理解 Best-Effort 的最好标本。设定：四个**同优先级**就绪任务——`AX` 不钉核（`tskNO_AFFINITY`，两核都能跑）、`B0` 钉 Core 0、`C1` 钉 Core 1、`D0` 钉 Core 0。链表头在左，每一步一个核做一次"选择"（tick 到期或显式 yield 触发），`[0]`/`[1]` 标记**本步被选中**的任务，完整的在跑状态见文末复盘表：

**初始状态**——四人都就绪，无人被选中：

```text
Head [ AX , B0 , C1 , D0 ] Tail
```

**第 1 步：Core 0 选择**。从头扫：`AX` 不在别的核上、亲和 OK → 选中，移到队尾。

```text
Head [ B0 , C1 , D0 , AX ] Tail
                        [0]
```

**第 2 步：Core 1 选择**。从头扫：`B0` 钉 Core 0，亲和不匹配 → **跳过**；`C1` 亲和 OK → 选中，移队尾。

```text
Head [ B0 , D0 , AX , C1 ] Tail
                        [1]
```

**第 3 步：Core 0 时间片到期，再次选择**。从头扫：`B0` 亲和 OK → 选中，移队尾（`AX` 被换下，回到等待）。

```text
Head [ D0 , AX , C1 , B0 ] Tail
                        [0]
```

**第 4 步：Core 1 时间片到期，再次选择**。从头扫：`D0` 钉 Core 0 → **跳过**；`AX` 两核可跑 → 选中，移队尾。注意：**`AX` 从 Core 0 迁到了 Core 1**——不钉核任务的漂移就发生在这一步。

```text
Head [ D0 , C1 , B0 , AX ] Tail
                        [1]      ← 官方演示到此为止
```

**第 5 步：Core 0 再次选择**。从头扫：`D0` 亲和 OK → 选中，移队尾（`B0` 被换下）。

```text
Head [ C1 , B0 , AX , D0 ] Tail
                        [0]
```

五次选择的复盘表：

| 步  | 谁选择 | 跳过 | 选中 | 链表（选择后）  | 在跑       |
| --- | ------ | ---- | ---- | --------------- | ---------- |
| 0   | —      | —    | —    | `[AX,B0,C1,D0]` | —          |
| 1   | Core 0 | —    | AX   | `[B0,C1,D0,AX]` | AX@0       |
| 2   | Core 1 | B0   | C1   | `[B0,D0,AX,C1]` | AX@0, C1@1 |
| 3   | Core 0 | —    | B0   | `[D0,AX,C1,B0]` | B0@0, C1@1 |
| 4   | Core 1 | D0   | AX   | `[D0,C1,B0,AX]` | B0@0, AX@1 |
| 5   | Core 0 | —    | D0   | `[C1,B0,AX,D0]` | D0@0, AX@1 |

读出四个结论：

- **轮转"近似"成立**：每步选中的都是"最久未被选且本核可运行"的任务——队尾机制在起作用；
- **不钉核的任务占便宜**：`AX` 五步被选了两次（步骤 1、4），因为它对两个核都可见；`B0`/`D0` 被 `Core 1` 跳过、`C1` 对 `Core 0` 隐身——**跳过源于链表顺序与核亲和的错配**，这就是 Best-Effort 与完美的全部差距来源；
- **顺序不可预期**：没有任何"按创建顺序轮流"的保证——官方文档明说 Users cannot expect multiple ready-state tasks of the same priority to run sequentially；
- **但不会饿死**：官方文档同样明说 given enough ticks, a task will eventually be given some processing time。队尾机制保证任何"本核可运行"的任务最坏等 O(同级任务数) 次选择后浮到队头。

### 4. 为什么"移到队尾"救不了完美轮转

把 8.2 的完美公式搬到双核就会发现它无处安放：双核每 tick 各做一次选择（共 2 次/tick），摊给 N 个同级任务，且每次选择还可能跳过若干。于是：

- Vanilla 的保证："任务两次上 CPU 间隔 === N × 1 tick"；
- IDF 的现实："间隔有下界（不会饿死），无上界承诺，更无顺序承诺"。

还有一个容易被忽略的推论：**时间片检查照旧触发，只是选择结果未必换人**。两个同优先级任务分钉两核时，每核每 tick 都看到链表长度 2 > 1、都触发重选，但扫描结果永远是自己那个——每 tick 一场"自己换给自己"的空转（行为无害，是否真省掉切换开销取决于端口层实现，第 7、17 章的射程）。

### 5. 想要完美轮转：同优先级全部钉同核

官方文档的处方。机理用本章的源码就能推演：四个任务全钉 Core 0 后——

- 对 Core 1：这一级全员亲和不匹配，扫描自动降级去跑别的（或 Idle），不掺和；
- 对 Core 0：从头扫时**跳过条件永远不成立**（没有任务可能"正在别的核上跑"，亲和全员通过）；
- 于是"选中移队尾 + 从头扫"精确等价于"游标轮转"——完美 RR 回归。

代价是明摆着的：这一级任务共享一个核，另一个核的并行度被放弃。**"公平"与"并行"在 SMP 调度里是一对可交换项**，这是单核 FreeRTOS 从不需要做的取舍。

> [!tip] Vanilla vs ESP-IDF：时间片语义一句话
> Vanilla：链表游标推进，任务不动，轮转严格可证明。IDF：任务被选中后移到队尾、每次从头扫、可能跳过——"每 tick 一换"从**保证**降级成了**倾向**（Best-Effort）。

---

## 8.4 调度语义总对照

本章暗线收拢成一张表（Vanilla v10.5.1 vs IDF 默认树，双核 ESP32）：

| 维度               | Vanilla v10.5.1                               | IDF FreeRTOS（默认树）                                                 |
| ------------------ | --------------------------------------------- | ---------------------------------------------------------------------- |
| 调度算法定性       | 固定优先级抢占 + 完美 RR                      | 固定优先级抢占 + Best-Effort RR                                        |
| 选择器             | `taskSELECT_HIGHEST_PRIORITY_TASK` 宏（游标） | `prvSelectHighestPriorityTaskSMP()`（每核独立调用）                    |
| 同级轮转实现       | `pxIndex` 游标推进，任务位置不变              | 选中任务 `listREMOVE_ITEM` + `listINSERT_END` 移队尾                   |
| 时间片判断对象     | `pxCurrentTCB->uxPriority` 的链表长度         | 每核各查 `pxCurrentTCBs[xCoreID]->uxPriority` 的链表长度               |
| tick 职责          | 单一 tick 全责                                | Core 0 全责；Core 1 只查时间片 + hook                                  |
| 抢占高优任务的传递 | 置 `xSwitchRequired` 即可                     | 本核可跑→本核让；否则 `xYieldPending[]` 或 `taskYIELD_CORE()` 核间中断 |
| 同级饿死可能       | 不可能（严格轮转）                            | 理论上最终必跑，但间隔无上界                                           |
| 想要完美 RR        | 默认就是                                      | 同优先级全部钉同核                                                     |
| 关闭时间片         | `configUSE_TIME_SLICING=0`                    | 配置写死 1，不可关                                                     |

---

## 8.5 vTaskPrioritySet：动态改优先级的立即重调度

固定优先级世界里，`vTaskPrioritySet()` 是应用手里唯一的"运行时改判"工具。它绝不是改一个字段那么简单——一次调用要搬动五样东西。

### 1. 一次调用搬动什么

`vTaskPrioritySet()`（默认树 `tasks.c`）的完整流程：

1. **夹临界区**：IDF 里是 `taskENTER_CRITICAL( &xKernelLock )`——自旋锁而非关中断，双核下另一个核想同时动就绪链表就得自旋等（[[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|第 18 章]]）；
2. **合法性钳位**：`uxNewPriority >= configMAX_PRIORITIES` 直接压到 `configMAX_PRIORITIES - 1`（IDF 即 24）；
3. **决策是否让出**：升/降 × 本核/他核的四象限判断（下一小节）；
4. **改优先级字段**：有互斥量时要尊重继承态——只在 `uxBasePriority == uxPriority`（未处于继承）时才改 `uxPriority`，但 `uxBasePriority` 无论如何都改（第 11 章展开）；
5. **改事件链表排序键 + 迁移就绪链表**：`xEventListItem` 的值更新为 `configMAX_PRIORITIES - 新优先级`（事件链表按"优先级倒序"排，唤醒时高优先级先出队，第 10 章用得上）；任务若在就绪链表里，摘出旧级、`prvAddTaskToReadyList()` 挂进新级（顺带可能抬高 `uxTopReadyPriority`）。

### 2. 升与降、本核与他核：决策表

"立即重调度"体现在第 3 步的决策表上（IDF fork，依据 `vTaskPrioritySet()` 与它调用的 `prvIsYieldRequiredSMP()`）：

| 变更 | 目标任务状态 | 内核动作                                                                                                             |
| ---- | ------------ | -------------------------------------------------------------------------------------------------------------------- |
| 升   | 未运行       | `prvIsYieldRequiredSMP()`：本核可跑且更高 → 本核立刻 `taskYIELD()`；本核跑不了 → `taskYIELD_CORE(对方核)` 发核间中断 |
| 升   | 正在本核跑   | 什么都不做（它已是本核最高）                                                                                         |
| 升   | 正在对方核跑 | 什么都不做（对它所在的核而言它仍最高）                                                                               |
| 降   | 正在本核跑   | `taskYIELD()`——同级或更高任务立刻顶上                                                                                |
| 降   | 正在对方核跑 | `taskYIELD_CORE(对方核)`——**Vanilla 没有的路径**                                                                     |
| 降   | 未运行       | 什么都不做                                                                                                           |

`prvIsYieldRequiredSMP()` 内部就是官方文档"调度器偏向当前核"的源码出处：判断顺序是先看"本核亲和兼容且优先级更高且本核调度器未挂起"→ 让本核；只有本核跑不了才轮到"对方核可跑" → `taskYIELD_CORE()`。函数里还留着一条 Espressif 自己的注释 `Todo: Make fair scheduling a configurable option (IDF-5772)`——"偏向当前核"是省核间中断的务实选择，不是不可辩驳的真理。另一个小差异：Vanilla 升其他任务的让出判断用 `uxNewPriority >= pxCurrentTCB->uxPriority`（**含升到同级**）；IDF 用 `prvIsYieldRequiredSMP(..., xYieldEqualPriority = pdTRUE)`，内部把优先级加一再比，语义等价——升到同级也要让一次，因为时间片从此要在两人之间轮转，"轮到的下家"交给选择器去定。

### 3. 与优先级继承的关系（一句话）

互斥量持有时内核也会改任务的 `uxPriority`（优先级继承），但只动 `uxPriority` 不动 `uxBasePriority`；`vTaskPrioritySet()` 两者都动且会检查继承态避免覆盖。两套改判逻辑共用一套让出决策——坑与细节留给[[2026-08-26-freertos-deep-dive-ch11-semaphore-mutex-priority-inheritance|第 11 章]]。

---

## 8.6 实验：让时间片现形

### 1. 仪器：tick 所有权记录器

忙等任务盯着 `xTaskGetTickCount()`，值一变就打印一行——**谁在哪个 tick 期间拥有 CPU，一目了然**。这是本章的核心仪器：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define OBSERVE_TICKS 40   /* 每个 recorder 记满 40 个 tick 后自删 */

static void recorder_task(void *arg)
{
    const char *name = (const char *)arg;
    TickType_t last = xTaskGetTickCount();
    int seen = 0;
    for (;;) {
        TickType_t now = xTaskGetTickCount();
        if (now != last) {
            last = now;
            printf("[%s] t=%lu\n", name, (unsigned long)now);
            if (++seen >= OBSERVE_TICKS) {
                vTaskDelete(NULL);   /* 自删，给下一组实验让路 */
            }
        }
    }
}
```

两个设计点：recorder **全程不阻塞**（一 `vTaskDelay` 就把本该分到的时间片让出去了，仪器就失真了）；记满 40 个 tick（400ms）自删，方便一组程序里串三组实验。主程序按组创建，组间由 `main` 任务（默认优先级 1，低于 recorder 的 3）睡 600ms 隔开：

```c
void app_main(void)
{
    /* 组 1：两个同优先级任务，都钉 Core 0 */
    xTaskCreatePinnedToCore(recorder_task, "A", 2048, "A", 3, NULL, 0);
    xTaskCreatePinnedToCore(recorder_task, "B", 2048, "B", 3, NULL, 0);
    vTaskDelay(pdMS_TO_TICKS(600));

    /* 组 2：同优先级，一个钉 Core 0、一个钉 Core 1 */
    xTaskCreatePinnedToCore(recorder_task, "A", 2048, "A", 3, NULL, 0);
    xTaskCreatePinnedToCore(recorder_task, "B", 2048, "B", 3, NULL, 1);
    vTaskDelay(pdMS_TO_TICKS(600));

    /* 组 3：复现官方 AX/B0/C1/D0 */
    xTaskCreatePinnedToCore(recorder_task, "AX", 2048, "AX", 3, NULL, tskNO_AFFINITY);
    xTaskCreatePinnedToCore(recorder_task, "B0", 2048, "B0", 3, NULL, 0);
    xTaskCreatePinnedToCore(recorder_task, "C1", 2048, "C1", 3, NULL, 1);
    xTaskCreatePinnedToCore(recorder_task, "D0", 2048, "D0", 3, NULL, 0);
}
```

### 2. 跑起来

```bash
idf.py create-project freertos-ch8 && cd freertos-ch8 && idf.py set-target esp32   # 建项目; main/freertos-ch8.c 换成上面代码
idf.py qemu monitor                                 # QEMU 主线; 真机: idf.py -p /dev/ttyUSB0 flash monitor
```

输出约 1.5 秒后自然安静下来（三组任务全部自删），`Ctrl-]` 退出。

### 3. 组 1 预期：严格交替（完美 RR 回归）

```text
[A] t=101
[B] t=102
[A] t=103
[B] t=104
...
```

解读：同级 + 同核 → Core 0 的每个 tick 看到链表长度 2 → 触发重选 → 从头扫必然选中另一个（它俩谁都不满足跳过条件）→ 移队尾。这正是 8.3.5 的推论"钉同核 = 完美轮转"。Core 1 全程在跑自己的 Idle，不参与。起始 tick 数和谁先打印因启动时刻而异，重要的是**交替**这个模式本身。

### 4. 组 2 预期：轮转消失，各拿一个核

```text
[A] t=210
[B] t=210
[A] t=211
[B] t=211
...
```

每个 tick **两个任务都打印**——它们在两个核上同时跑，谁也不用等谁。时间片机制依然每核每 tick 触发（链表长度 2 > 1），但重选永远扫到自己（唯一亲和兼容的那个），等于 8.3.4 说的"自己换给自己"。"同优先级 ≠ 轮转，还要同核"的证据落袋。

### 5. 组 3 预期：跳过与漂移（Best-Effort 的真面目）

典型输出（每次运行细节都会变，模式稳定）：

```text
[B0] t=331
[C1] t=331
[AX] t=332
[C1] t=332
[D0] t=333
[AX] t=333
[B0] t=334
[C1] t=334
...
```

观察要点，对照 8.3.3 的五步演化：

- `C1`（钉 Core 1）几乎每 tick 都在——Core 1 的扫描里，同级任务中亲和兼容的常常只有它；
- `B0`/`D0` 轮流缺席——Core 0 在它俩与 `AX` 之间轮；
- `AX` 的出现间隔不稳定——它不钉核，两个核都可能选中它（演示里它五步被选两次）；若加打印核号（`xPortGetCoreID()`）还能亲眼看到它在两核间漂移；
- 没有任务连续饿超过几个 tick——"eventually runs" 的承诺兑现。

### 6. 加餐：vTaskPrioritySet 的即时性

前几组看的是时间片；这组看动态优先级的"立即重调度"。两个任务都钉 Core 0（排除双核逃逸，才能看到纯优先级效果）：

```c
static void prio_worker(void *arg)
{
    for (;;) {
        printf("[worker] 低优先级巡航, tick=%lu\n", (unsigned long)xTaskGetTickCount());
        vTaskDelay(pdMS_TO_TICKS(100));
        printf("[worker] 自升至 5, 独占 5 个 tick\n");
        vTaskPrioritySet(NULL, 5);                  /* 自我提升（运行中）：我已是最高 */
        TickType_t t0 = xTaskGetTickCount();
        while (xTaskGetTickCount() - t0 < 5) { }    /* 忙等独占 50ms */
        vTaskPrioritySet(NULL, 1);                  /* 自我降级（本核运行中）：立即让出 */
    }
}

static void prio_ctrl(void *arg)
{
    for (;;) {
        printf("[ctrl]   tick=%lu\n", (unsigned long)xTaskGetTickCount());
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

void app_main(void)
{
    xTaskCreatePinnedToCore(prio_worker, "worker", 2048, NULL, 1, NULL, 0);
    xTaskCreatePinnedToCore(prio_ctrl,   "ctrl",   2048, NULL, 3, NULL, 0);
}
```

预期：`ctrl` 每 10ms 一行；从 worker 自升那一刻起，`ctrl` 的行停摆约 5 行（50ms）——它每次从 `vTaskDelay` 醒来都撞上"最高就绪是 5 级的 worker"，根本上不了 CPU；worker 自降到 1 的**同一个调用里**触发 `taskYIELD()`，`ctrl` 立刻恢复打印，误差不超过一次切换的微秒级耗时。对照 8.5 决策表："升-运行中-本核 → 什么都不做"与"降-运行中-本核 → 立即让出"两条路径一次看全。

### 7. 常见翻车点

| 症状                          | 原因                                                                              |
| ----------------------------- | --------------------------------------------------------------------------------- |
| 组 1 不交替，一个任务连续打印 | 两个任务优先级写岔了——差 1 就没有时间片什么事，纯抢占                             |
| 组 2 仍然交替                 | 忘了钉核，或都钉了同一核；`xTaskCreatePinnedToCore()` 最后一个参数才是核号        |
| 任务跑在意料之外的核上        | 用了不带 `PinnedToCore` 的 `xTaskCreate()`——那是 `tskNO_AFFINITY`，漂移是正常现象 |
| 打印淹没观察                  | 把 `OBSERVE_TICKS` 调小，或 recorder 里改成 `if (now % 5 == 0)` 才打印            |

---

## 8.7 小结

- **固定优先级是全部分析的起点**：创建即定、无老化、饿死是设计内的合法状态；`configMAX_PRIORITIES` 决定就绪数组宽度（IDF 写死 25），IDF 里抢占与时间片硬编码开启、不可关。
- **Vanilla 的完美 RR**：`taskSELECT_HIGHEST_PRIORITY_TASK()` 用链表游标 `pxIndex` 推进、任务不动；tick 里检查"当前任务所在就绪链表长度 > 1"就请求切换——间隔恒等于同级任务数 × 1 tick，可数学归纳。
- **IDF 的 Best-Effort RR**：tick 职责 Core 0 全责、Core 1 只查自己核的时间片（`xTaskIncrementTickOtherCores()`）；每核独立地"从头扫 + 跳过（他核在跑/亲和不符）+ 选中移队尾"（`prvSelectHighestPriorityTaskSMP()`）。
- **AX/B0/C1/D0 五步演化**是理解跳过机理的最短路径：跳过源于链表顺序与核亲和的错配；不钉核任务对两核可见、被选机会更多；顺序无承诺、但不会饿死。想完美 RR 就同优先级全钉同核——公平与并行在 SMP 里是一对可交换项。
- **`vTaskPrioritySet()`**：升/降 × 本核/他核的决策表决定立即让出还是发核间中断（`taskYIELD_CORE`，降对方核任务是 Vanilla 没有的路径）；"偏向当前核"写在 `prvIsYieldRequiredSMP()` 的判断顺序里。
- 实验三连用"tick 所有权记录器"验证：钉同核 = 严格交替；分钉两核 = 并行无轮转；混合亲和 = 跳过与漂移。

时间片轮转的前提是任务会持续就绪；真实系统里任务大部分时间在**睡**。下一章（[[2026-08-26-freertos-deep-dive-ch9-blocking-delay-idle|第九章：阻塞、超时与 Idle 任务]]）拆解睡着的路径——`vTaskDelay` 系与延迟链表、超时唤醒的记账、以及全员沉睡时 Idle 任务在替谁回收内存。
