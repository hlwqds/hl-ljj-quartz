---
title: "FreeRTOS 深度解析（二十二）：IDF FreeRTOS 的 SMP 改造全景"
date: 2026-08-26
description: "以 FreeRTOS-Kernel/idf_changes.md 与 tasks.c 源码为材料，整体拆解 IDF FreeRTOS 相对 Vanilla v10.5.1 的 SMP 改造：数据结构从单份到每核一份、每核独立调度循环、偏向当前核的抢占决策、Best-Effort Round-Robin 的实现、tick 职责划分与每核 Idle，并用四任务实验复现官方调度序列。"
tags: [freertos, rtos, esp32, esp-idf, smp, scheduler, multicore, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 22. **第二十二章：IDF FreeRTOS 的 SMP 改造全景**

# FreeRTOS 深度解析（二十二）：IDF FreeRTOS 的 SMP 改造全景

前面二十一章读的都是"一个调度器"的内核：就绪链表一份、当前任务指针一个、tick 计数一个。但 ESP32 是双核 SoC，而 Vanilla FreeRTOS v10.5.1 的每一个全局状态都建立在"只有一个 CPU"的假设上。本章把 IDF FreeRTOS 相对 Vanilla 的 SMP 改造**整体摊开**：改了哪些数据结构、调度循环怎么变成每核一个、抢占与时间片语义退化了什么、tick 在两核间怎么分工。

主材料有两份：`components/freertos/FreeRTOS-Kernel/idf_changes.md`（Espressif 自己维护的改造清单，逐条列出了对 v10.5.1 的每处修改）和 `tasks.c` 源码本身。读完本章，第 8 章里"Best-Effort Round-Robin"这个行为学描述会落到具体的 `listINSERT_END()` 调用上。

---

## 22.1 改造的动机、边界与两棵内核树

### 1. 动机：单核内核放不上双核

Vanilla FreeRTOS 的单核假设渗透在三层，每一层都必须动：

| 层       | 单核假设                                                 | 双核现实                                       |
| -------- | -------------------------------------------------------- | ---------------------------------------------- |
| 全局状态 | `pxCurrentTCB` 一个指针就是"正在运行的任务"              | 两个核各有各的当前任务                         |
| 互斥手段 | 关中断即可进入临界区——CPU 只有一个，关了中断就没人能打扰 | 关本核中断挡不住另一核，需要自旋锁（第 18 章） |
| 调度算法 | "选最高优先级就绪任务"语义唯一                           | 每个核独立选任务，还要避免两个核选中同一个任务 |

第三层最微妙：它意味着**调度语义必然改变**。"完美 Round-Robin"这类单核下天然成立的性质，在"每核独立选择 + 亲和约束"的世界里做不到——这不是实现瑕疵，是数学。

### 2. 边界：三条硬约束

Espressif 的改造在三条约束下进行，理解它们就理解了改造的形状：

1. **基线钉死 v10.5.1**。IDF fork 的每个源文件头部都标注 `FreeRTOS Kernel V10.5.1 (ESP-IDF SMP modified)`——它是"在旧版上打 SMP 补丁"，不是重写。API 面保持兼容，你在官方教材学的 `xTaskCreate`/`xQueueSend` 原样可用。
2. **最多两个核**。`configNUMBER_OF_CORES` 只接受 1 或 2（超出直接报错）。改造里大量出现 `!xCurCoreID` 这种"另一个核"写法——双核假设被硬编码进了实现（22.4 节会见到）。
3. **可回退单核，且单核构建剥离 SMP 数据**。`CONFIG_FREERTOS_UNICORE` 不切换源码树，只是把 `CONFIG_FREERTOS_NUMBER_OF_CORES` 设为 1。此时所有 SMP 改造被 `#if ( configNUMBER_OF_CORES > 1 )` 编译期裁掉：TCB 里没有 `xCoreID` 成员、没有每核数组、临界区内不再遍历链表，调度算法回归 Vanilla——包括完美 Round-Robin 的恢复。SMP API 仍可调用但退化为单核等价物（`...PinnedToCore()` 忽略 `xCoreID` 参数）。

### 3. 目录事实：默认树与实验树

把第 1 章的目录速览精确化（构建事实以 `components/freertos/CMakeLists.txt` 与 `Kconfig` 为准）：

```text
components/freertos/
├── FreeRTOS-Kernel/          # IDF FreeRTOS（默认编入这棵）
│   ├── tasks.c               # ~273KB：v10.5.1 + SMP 改造，本章主战场
│   ├── idf_changes.md        # Espressif 维护的逐条改造清单
│   └── ...
└── FreeRTOS-Kernel-SMP/      # 上游 Amazon SMP 新内核（实验性）
    ├── tasks.c               # ~353KB：v11.x 基线重写
    └── porting_notes.md      # Amazon SMP 内核的移植说明
```

关键事实：**两棵树都是 SMP capable**，但实现完全不同。默认的 `FreeRTOS-Kernel/` 是 v10.5.1 加改造补丁；`FreeRTOS-Kernel-SMP/` 是上游 Amazon 官方 SMP 化的新内核（v11.x 基线），由 `CONFIG_FREERTOS_SMP` 开关控制、**默认关闭**（v6.0.2 中标记为 FEATURE UNDER DEVELOPMENT，且不支持 P4/H4）。本章讲前者——它是所有 ESP32 出厂固件实际跑的内核；后者在 22.10 节作为"这场改造的下一代"一瞥。

> [!tip] Vanilla vs ESP-IDF：两种 SMP 化路线
> 同一个"把 FreeRTOS 改成 SMP"的需求，世界上存在两份工业级答案，都在你的 ESP-IDF 里：
>
> | 维度       | IDF fork（v10.5.1 + 补丁）                   | Amazon SMP 内核（v11.x 重写）        |
> | ---------- | -------------------------------------------- | ------------------------------------ |
> | 亲和模型   | 每任务一个 `xCoreID`（0/1/`tskNO_AFFINITY`） | 每任务一个**亲和掩码**，可任意核组合 |
> | 临界区     | 细粒度自旋锁（内核/队列/事件组各一把）       | 巨锁（task lock + ISR lock）         |
> | 调度器挂起 | 每核独立挂起                                 | 全局挂起                             |
> | 状态跟踪   | 无运行态字段，靠 `pxCurrentTCBs[]` 比对      | TCB 内置 `xTaskRunState`             |
>
> 前者求"最小改动、API 兼容"，后者求"架构正确"。对照着读，能看到工程约束如何塑造设计。

---

## 22.2 核心数据结构改造：从单份到每核一份

`idf_changes.md` 的 "Data Structure Changes" 一节是本章的地图：**六个全局状态被扩展为每核一份，TCB 新增一个字段，就绪链表却保持共享**。

### 1. 改造前后对照表

| 状态             | Vanilla v10.5.1                             | IDF FreeRTOS（SMP 构建）                           | 为什么要每核一份         |
| ---------------- | ------------------------------------------- | -------------------------------------------------- | ------------------------ |
| 当前任务         | `pxCurrentTCB`（单个指针）                  | `pxCurrentTCBs[ configNUMBER_OF_CORES ]`           | 每核各自在跑谁           |
| 让出标志         | `xYieldPending`（BaseType_t）               | `xYieldPending[ cores ]`                           | 一核请求切换不影响另一核 |
| 调度器挂起计数   | `uxSchedulerSuspended`                      | `uxSchedulerSuspended[ cores ]`                    | 每核独立挂起（22.7 节）  |
| 挂起期就绪链表   | `xPendingReadyList`                         | `xPendingReadyList[ cores ]`                       | 唤醒的任务按核分流       |
| Idle 任务句柄    | `xIdleTaskHandle`                           | `xIdleTaskHandle[ cores ]`                         | 每核一个 Idle（22.7 节） |
| 运行时间统计基准 | `ulTaskSwitchedInTime`                      | `ulTaskSwitchedInTime[ cores ]`                    | 每核独立记账换入时刻     |
| TCB 亲和         | （无此概念）                                | `TCB_t.xCoreID`（`tskNO_AFFINITY` = `0x7FFFFFFF`） | 调度校验的依据           |
| 内核互斥         | 关中断即可                                  | `xKernelLock`（`portMUX_TYPE` 自旋锁）             | 挡住另一核（第 18 章）   |
| **就绪链表**     | `pxReadyTasksLists[ configMAX_PRIORITIES ]` | **仍是同一份共享数组**                             | 见下                     |

源码速览（`tasks.c`，节选）：

```c
portDONT_DISCARD PRIVILEGED_DATA TCB_t * volatile pxCurrentTCBs[ configNUMBER_OF_CORES ] = { NULL };

PRIVILEGED_DATA static List_t pxReadyTasksLists[ configMAX_PRIORITIES ];  /* 共享！ */
PRIVILEGED_DATA static List_t xPendingReadyList[ configNUMBER_OF_CORES ];
PRIVILEGED_DATA static volatile BaseType_t xYieldPending[ configNUMBER_OF_CORES ];
PRIVILEGED_DATA static volatile UBaseType_t uxSchedulerSuspended[ configNUMBER_OF_CORES ];
PRIVILEGED_DATA static portMUX_TYPE xKernelLock = portMUX_INITIALIZER_UNLOCKED;

/* TCB_t 内（#if configNUMBER_OF_CORES > 1 包裹）： */
BaseType_t xCoreID;    /* 该任务钉在哪个核；tskNO_AFFINITY 表示不限 */
```

### 2. 就绪链表为什么不拆分

这是改造里最值得停下来想的一个决定。备选方案是"每核一套就绪链表"（Linux 的 per-CPU runqueue 路线），IDF fork 没有走，而是**共享一份按优先级组织的链表，把"SMP 约束"推迟到选择时刻校验**。代价与收益：

- **代价**：选任务时可能要沿链表跳过"钉在别的核"或"正被他核运行"的任务——临界区内出现最坏 O(链表长度) 的遍历（单核 Vanilla 的选择是 O(1) 的）。这也是 SMP 构建必须关掉 `configUSE_PORT_OPTIMISED_TASK_SELECTION`（硬件 CLZ 快速选顶）的原因：优化路径没有亲和校验的立足点。
- **收益**：任务在两个核之间**天然可迁移**——它就躺在公共链表里，谁挑中谁跑，不需要任何"迁移"操作。同时优先级结构只有一份真相，`xTaskIncrementTick()` 的超时扫描逻辑几乎不用改。

`idf_changes.md` 对每个数组的说明是同一句话的变体："indexed by `xCoreID` if in SMP, or set to `0` in single core"——单核构建里这些数组长度为 1，访问代码不用变。

### 3. "正在他核运行"怎么判断

注意 TCB 里**没有**运行状态字段。判断"这个任务是否正被另一个核执行"的方式是逐槽比对：

```c
/* prvSelectHighestPriorityTaskSMP() 内部逻辑 */
for( x = 0; x < configNUMBER_OF_CORES; x++ )
{
    if( x == xCurCoreID )       /* 本核槽位不算——当前任务可以被本核重新选中 */
    {
        continue;
    }
    else if( pxCurrentTCBs[ x ] == pxTCBCur )
    {
        goto get_next_task;     /* 他核正在跑这个任务，跳过 */
    }
}
```

源码在此处留着一条 Espressif 自己的 Todo 注释：_Each task can store a xTaskRunState, instead of needing to check each core_——上游 Amazon SMP 内核正是这么做的（TCB 内置 `xTaskRunState`），这也是 22.10 节对照表里"状态跟踪"一行的出处。亲和校验则封装成一个宏：

```c
#define taskIS_AFFINITY_COMPATIBLE( xCore, pxTCB ) \
    ( ( ( ( pxTCB )->xCoreID == xCore ) ||          \
        ( ( pxTCB )->xCoreID == tskNO_AFFINITY ) ) ? pdTRUE : pdFALSE )
```

> [!note] 启动期的"铺位"逻辑
> 调度器还没启动时（`app_main` 里逐个 `xTaskCreate` 的阶段），`prvAddNewTaskToReadyList()` 会直接把新任务填进**空着的** `pxCurrentTCBs[]` 槽位：先试 Core 0（亲和兼容才填），再试 Core 1，都满了才走"请求某核让出"的常规路径。所以最先创建的一两个任务会在首个 tick 之前就"占好座位"——22.9 节实验的初始状态正是这么来的。

---

## 22.3 每核独立的调度循环

### 1. 入口：vTaskSwitchContext 先拿内核锁

单核 Vanilla 里 `vTaskSwitchContext()` 在关中断状态下被端口层调用；SMP 版多了第一步——拿 `xKernelLock` 自旋锁，因为即将访问的就绪链表和 `pxCurrentTCBs[]` 是两核共享的。锁内逻辑对每核对称：若本核调度器被挂起，只置位 `xYieldPending[]` 记下"欠一次切换"，恢复时补；否则调用 `taskSELECT_HIGHEST_PRIORITY_TASK()` 选任务——SMP 构建下这个宏指向 `prvSelectHighestPriorityTaskSMP()`（单核构建仍是 Vanilla 原版，一字未改）。

### 2. prvSelectHighestPriorityTaskSMP 走读

这是 SMP 调度的心脏，值得逐行读（骨架节选，注释为本文所加）：

```c
static void prvSelectHighestPriorityTaskSMP( void )
{
    BaseType_t xCurCoreID = portGET_CORE_ID();
    BaseType_t xTaskScheduled = pdFALSE;

    for( uxCurPriority = uxTopReadyPriority;               /* 从最高就绪优先级向下扫 */
         uxCurPriority >= 0 && xTaskScheduled == pdFALSE;
         uxCurPriority-- )
    {
        if( listLIST_IS_EMPTY( &pxReadyTasksLists[ uxCurPriority ] ) )
        {
            continue;                                      /* 本级没人，降一级 */
        }
        /* pxIndex 复位到尾哨兵，使遍历从链表头开始 */
        pxReadyTasksLists[ uxCurPriority ].pxIndex = &pxReadyTasksLists[ uxCurPriority ].xListEnd;
        listGET_OWNER_OF_NEXT_ENTRY( pxTCBCur, &pxReadyTasksLists[ uxCurPriority ] );
        pxTCBFirst = pxTCBCur;

        do {
            /* 校验一：没有正在其他核上跑（22.2 节的逐槽比对） */
            ...
            /* 校验二：亲和兼容 */
            if( taskIS_AFFINITY_COMPATIBLE( xCurCoreID, pxTCBCur ) == pdFALSE )
            {
                goto get_next_task;
            }
            /* 两关都过：选中 */
            pxCurrentTCBs[ xCurCoreID ] = pxTCBCur;
            xTaskScheduled = pdTRUE;
            /* Best-Effort RR 的实现点：选中者搬到同优先级链表尾 */
            listREMOVE_ITEM( &pxTCBCur->xStateListItem );
            listINSERT_END( &pxReadyTasksLists[ uxCurPriority ], &pxTCBCur->xStateListItem );
            break;

get_next_task:
            listGET_OWNER_OF_NEXT_ENTRY( pxTCBCur, &pxReadyTasksLists[ uxCurPriority ] );
        } while( pxTCBCur != pxTCBFirst );                 /* 绕整圈仍无解则降优先级 */
    }
    configASSERT( xTaskScheduled == pdTRUE );              /* 大不了落到 prio0 的 Idle */
}
```

三个结构性要点：

1. **两重校验**（他核未运行 + 亲和兼容）**任一不过即跳过**——这就是官方文档"每个核独立选择它能运行的最高优先级任务"的全部含义。
2. **选中即搬尾**。`listREMOVE_ITEM` + `listINSERT_END` 两行就是 Best-Effort Round-Robin 的实现本体（22.5 节展开）。
3. **兜底是 Idle**。循环扫到优先级 0 必然命中本核的 pinned Idle（22.7 节），所以末尾的断言"必须选中一个"成立。

### 3. 调度决策流程图

把本核一次完整的选任务过程画成图：

```text
 tick 中断 / portYIELD()
        │
        ▼
 vTaskSwitchContext() ──► 取 xKernelLock 自旋锁（两核互斥）
        │
        ▼
 本核 uxSchedulerSuspended[] > 0 ？
        ├─ 是 ─► xYieldPending[本核] = pdTRUE，欠一次切换，结束
        └─ 否
           ▼
   prvSelectHighestPriorityTaskSMP()
        │
        ▼
   for prio = uxTopReadyPriority ─ downto 0：
        │
        ▼
   该优先级就绪链表空？ ──是──► 降一级，继续 for
        │ 否
        ▼
   从链表头开始逐个任务：
        ├─ 正被【其他核】运行 ──► 跳过，取下一个
        ├─ 亲和不兼容（钉在别核）──► 跳过，取下一个
        └─ 两关都过 ──► pxCurrentTCBs[本核] = 该任务
                        │  该任务搬到链表尾（Best-Effort RR）
                        ▼
                  整圈都被跳过？──是──► 降一级，继续 for
                  （优先级 0 必有本核 Idle 兜底）
```

### 4. 直接推论：优先级前两名不一定在跑

官方文档给的反例值得记住：任务 A（优先级 10，钉 Core 0）、任务 B（优先级 9，钉 Core 0）、任务 C（优先级 8，钉 Core 1）同时就绪时，结果是 **A 跑在 Core 0、C 跑在 Core 1，第二高的 B 一步都跑不到**。Core 1 在自己的循环里跳过 A 和 B（亲和不兼容）后命中 C——"每核选自己能跑的最高优先级"不等于"全局按优先级取前两名填充两核"。这是从单核迁移过来的直觉里最容易踩的坑。

---

## 22.4 抢占决策：偏向当前核

### 1. prvIsYieldRequiredSMP 的两级判断

当一个高优先级任务被唤醒（事件到来、超时到期、优先级被抬高），内核要决定"打扰哪个核"。`tasks.c` 里的 `prvIsYieldRequiredSMP()` 是决策核心：

```c
static BaseType_t prvIsYieldRequiredSMP( TCB_t * pxTCB,
                                         UBaseType_t uxTaskPriority,
                                         BaseType_t xYieldEqualPriority )
{
    const BaseType_t xCurCoreID = portGET_CORE_ID();
    ...
    /* 第一优先：当前核亲和兼容 && 优先级更高 && 本核调度器未挂起 */
    if( ( taskIS_AFFINITY_COMPATIBLE( xCurCoreID, pxTCB ) == pdTRUE ) &&
        ( uxTaskPriority > pxCurrentTCBs[ xCurCoreID ]->uxPriority ) &&
        ( uxSchedulerSuspended[ xCurCoreID ] == 0U ) )
    {
        return pdTRUE;                    /* 调用方就地 yield，零额外成本 */
    }
    /* 第二优先：另一个核条件满足 → 发跨核中断请它让出 */
    else if( ( taskIS_AFFINITY_COMPATIBLE( !xCurCoreID, pxTCB ) == pdTRUE ) &&
             ( uxTaskPriority > pxCurrentTCBs[ !xCurCoreID ]->uxPriority ) &&
             ( uxSchedulerSuspended[ !xCurCoreID ] == 0U ) )
    {
        taskYIELD_CORE( !xCurCoreID );    /* portYIELD_CORE() → 核间中断（第 23 章） */
    }
    return pdFALSE;
}
```

**当前核永远先被检查**：如果两个核都满足抢占条件（典型场景：新任务未钉核且优先级高于两核当前任务），返回值让本核直接切换，另一核根本不会被通知。

### 2. 为什么偏向当前核

两个原因，一浅一深：

- **浅层是成本**。让当前核切换只是把已发生的函数调用链顺势走完（`portYIELD_WITHIN_API()` 级别）；让另一核切换要走 `portYIELD_CORE()` → 核间中断 → 对端 ISR → 对端调度——一整套跨核往返（第 23 章拆解），延迟和总线流量都高一个量级。
- **深层是唤醒局部性**。唤醒高优先级任务的代码（比如往队列里发数据的 `xQueueSend`）就运行在当前核上，被唤醒的任务大概率马上要处理当前核刚产生的数据。让它在当前核立刻开跑，比把它"快递"到另一核更符合数据流向。

官方文档的示例：任务 A（优先级 8）跑在 Core 0、任务 B（优先级 9）跑在 Core 1，B 唤醒了未钉核的任务 C（优先级 10）——结果是 **C 抢占 B**（B 所在的 Core 1 正是唤醒发生地），A 在 Core 0 不受打扰，尽管 A 的优先级更低。"谁唤醒谁让路"。

### 3. 一个有趣的硬编码

`!xCurCoreID`——"另一个核"用逻辑非表达，只在核数为 2 时正确。这不是疏忽，而是 22.1 节"最多两核"约束的直接体现：双核世界里 `!x` 就是最快的"取另一个"。上游 Amazon SMP 内核改用掩码遍历，代价是通用性换来的几条指令。读到这类代码，能清晰感到"补丁式改造"与"重新设计"的气质差异。

---

## 22.5 Best-Effort Round-Robin：从行为到实现

第 8 章从行为层面描述过：IDF FreeRTOS 的同优先级时间片是 Best-Effort 的。现在实现已经摊开，把因果链补全。

### 1. 为什么"完美"不可能

Vanilla 的时间片轮转之所以完美，是因为单核下"当前优先级就绪链表里的任务"就是"轮流上 CPU 的任务"全集。SMP 下这个等式破了，一个任务可能因为两个原因在本核的轮转里缺席：

1. 它钉在另一个核（亲和不兼容，`taskIS_AFFINITY_COMPATIBLE` 为假）；
2. 它未钉核，但**此刻正被另一个核运行**（逐槽比对命中）。

于是本核找下一个轮转对象时可能跳过若干任务，甚至降级到更低的优先级。轮转的"环"在两个核的并行选择下不再闭合。

### 2. 实现本体：选中即搬尾

`prvSelectHighestPriorityTaskSMP()` 末尾的两行——

```c
listREMOVE_ITEM( &pxTCBCur->xStateListItem );
listINSERT_END( &pxReadyTasksLists[ uxCurPriority ], &pxTCBCur->xStateListItem );
```

——就是全部。刚被选中运行的任务搬到链表尾，**没被选中的任务相对前移**。下一个 tick 或 yield 时，链表头部的任务是"最久没被选中"的那个：无论中间被跳过多少次、被哪个核跳过，只要它还在链表里，队头位置终会轮到它。这就是"Best-Effort"的准确含义——**不保证顺序完美，但保证饿不死**（官方文档的原话：given enough ticks, a task will eventually be given some processing time）。

> [!tip] Vanilla vs ESP-IDF：同优先级时间片的实现对照
>
> | 维度     | Vanilla v10.5.1                                            | IDF FreeRTOS（SMP 构建）            | IDF 单核构建      |
> | -------- | ---------------------------------------------------------- | ----------------------------------- | ----------------- |
> | 轮转机制 | `pxIndex` 游标走 `listGET_OWNER_OF_NEXT_ENTRY`，纯指针推进 | 选中者 `REMOVE` + `INSERT_END` 搬尾 | 恢复 Vanilla 原版 |
> | 语义     | 完美 Round-Robin，严格按序                                 | Best-Effort，可能跳过/降级          | 完美 Round-Robin  |
> | 饿死风险 | 无                                                         | 无（搬尾保证最终轮到）              | 无                |
>
> 实践守则（官方文档明说）：想要理想轮转，把**同优先级的所有任务钉到同一个核**——此时"另一核正在运行它"和"亲和不兼容"两个跳过条件对其他核都不再干扰本核，完美 RR 在单核语义下自然回归。

### 3. 与第 8 章的衔接

第 8 章的实验观察（同优先级任务的输出顺序偶有交错不均）在这里得到了机制解释：每次调度都发生搬尾，但两核的 tick 相位独立（22.6 节），谁在哪个 tick 挑走队头任务是概率性的。行为上的"毛刺"是数据结构上那两行搬尾代码在双核竞争下的直接投影。

---

## 22.6 tick 职责划分：Core 0 全责的深意

### 1. 入口：同一个 ISR，两条岔路

每核都有周期相同（默认 100Hz）、但**相位可以不同**的硬件 tick 中断。`components/freertos/port_systick.c` 的 `xPortSysTickHandler()` 是共同入口（节选自默认的 IDF fork 分支；`CONFIG_FREERTOS_SMP` 实验内核分支下 Core 1 干得更少，见 22.10 节）：

```c
BaseType_t xPortSysTickHandler( void )
{
    esp_vApplicationTickHook();                    /* 两核都执行：喂中断看门狗 */
    BaseType_t xSwitchRequired;
    if( xPortGetCoreID() == 0 ) {
        xSwitchRequired = xTaskIncrementTick();           /* Core 0：全责 */
    } else {
        xSwitchRequired = xTaskIncrementTickOtherCores(); /* Core 1：时间片 + hook */
    }
    if( xSwitchRequired != pdFALSE ) {
        portYIELD_FROM_ISR();
    }
    return xSwitchRequired;
}
```

### 2. 两核职责对照

| tick 职责                                  | Core 0（`xTaskIncrementTick`）                               | Core 1（`xTaskIncrementTickOtherCores`） |
| ------------------------------------------ | ------------------------------------------------------------ | ---------------------------------------- |
| 递增 `xTickCount`                          | ✅（函数开头 `configASSERT( portGET_CORE_ID() == 0 )` 把关） | ❌                                       |
| 解除超时任务阻塞、维护延迟链表             | ✅                                                           | ❌                                       |
| 时间片检查                                 | ✅ 检查 **Core 0 当前任务**优先级的链表长度                  | ✅ 检查自己当前任务的                    |
| `vApplicationTickHook()`                   | ✅                                                           | ✅                                       |
| 挂起期补账（`xPendedTicks`）               | ✅（只有它管计数）                                           | ❌                                       |
| `esp_vApplicationTickHook()`（喂中断 WDT） | ✅                                                           | ✅（各自喂各自的）                       |

`xTaskIncrementTickOtherCores()` 定义在 `esp_additions/freertos_tasks_c_additions.h`（IDF 附加代码不进内核文件），函数开头同样有 `configASSERT( xCoreID != 0 )`——两个函数互斥地认领两核，职责表就是两张 assert 的并集。

### 3. 深意：单一时间基准的代价与收益

为什么不让每核各自计时？**收益**是全系统只有一个时间真相：`xTickCount`、延迟链表、`vTaskDelay` 超时全都不需要两核同步，第 9 章读过的超时扫描逻辑几乎原样保留。**代价**写在官方文档的警告里：

> Core 0 is solely responsible for keeping time... anything that prevents Core 0 from incrementing the tick count, such as suspending the scheduler on Core 0, will cause the entire scheduler's timekeeping to lag behind.

Core 0 的调度器一旦挂起，全系统的"表"就停了——Core 1 的 `vTaskDelay` 精度、时间片节奏全部跟着滞后。还有一个不易察觉的推论：Core 0 解锁任务时要替 Core 1 做"远程抢占"决策——如果唤醒的任务只比 **Core 1** 的当前任务优先级高，代码会置位 `xYieldPending[ 1 ]`，让 Core 1 在自己的下一个 tick 里切换：

```c
/* xTaskIncrementTick() 内部（节选）：唤醒 pxTCB 后 */
if( taskIS_AFFINITY_COMPATIBLE( 0, pxTCB ) == pdTRUE ) {
    if( pxTCB->uxPriority > pxCurrentTCBs[ 0 ]->uxPriority ) {
        xSwitchRequired = pdTRUE;              /* Core 0 自己切 */
    } else if( pxTCB->xCoreID == tskNO_AFFINITY ) {
        if( pxTCB->uxPriority > pxCurrentTCBs[ 1 ]->uxPriority ) {
            xYieldPending[ 1 ] = pdTRUE;       /* 替 Core 1 记一笔"该切了" */
        }
    }
}
```

注意这与 22.4 节不矛盾：这里是 tick 上下文里的"记账"，Core 1 真正切换要等自己的时间片检查发现标志位——不做跨核中断，用延迟换成本。

---

## 22.7 Idle、调度器挂起与跨核生命周期

### 1. 每核一个 pinned Idle

`vTaskStartScheduler()` 调用 `prvCreateIdleTasks()`，循环 `configNUMBER_OF_CORES` 次，每核创建一个**钉死在该核**的 Idle（`xTaskCreatePinnedToCore( prvIdleTask, "IDLE0/1", ..., xCoreID )`），句柄存进 `xIdleTaskHandle[]`。任务名带核编号后缀这个细节是从上游 backport 的（`idf_changes.md` 明确记录）。每核 pinned 的原因很直接：任何一个核陷入"无事可做"时，它的兜底任务必须保证能跑——若 Idle 未钉核，可能出现两个核同时空转却互相谦让 Idle 的死锁（22.3 节的断言也就不再成立）。

Idle 的职责（回收被删任务内存、跑 idle hook、可选的低功耗处理）与 Vanilla 相同，详见第 9 章。差异在删除的跨核协作，见第 3 小节。

### 2. vTaskSuspendAll 只挂起当前核

```c
void vTaskSuspendAll( void )
{
    prvENTER_CRITICAL_SMP_ONLY( &xKernelLock );
    {
        ++uxSchedulerSuspended[ portGET_CORE_ID() ];   /* 只动本核的计数 */
    }
    prvEXIT_CRITICAL_SMP_ONLY( &xKernelLock );
}
```

挂起的后果清单（官方文档逐条列出，这里提炼）：

- 只有**本核**停止切换、禁用时间片；另一核照常调度。中断不关，tick 中断照发。
- 挂起期间被中断唤醒的任务进**本核的** `xPendingReadyList[]`（钉死本核的）或能跑的核的正常就绪链表（未钉核且另一核没挂起的）——`xTaskResumeAll()` 时再搬运。
- 若挂起的是 Core 0，tick 计数冻结、`xPendedTicks` 递增，恢复时补账——全系统时间整体滞后（22.6 节的代价）。

最重要的推论是官方的 Warning 原意：**调度器挂起不再是互斥手段**。单核 FreeRTOS 里"`vTaskSuspendAll()` + 访问共享数据"是教材级惯用法（比如 `event_groups.c` 在任务上下文就这么干）；SMP 下它只锁住一个核，另一核的任务随时插进来。要互斥，用互斥量或自旋锁（第 11、18 章）。`idf_changes.md` 还记录了一个连带修改：事件组等内核对象原本靠挂起调度器保护的路径，在 SMP 构建里补加了 `xEventGroupLock` 等自旋锁。

### 3. 删除与迁移：跨核的生命周期尾巴

`idf_changes.md` 对 `vTaskDelete()` 的 SMP 修改说明只有三行，信息量却很大：

- 删除一个**正跑在另一核**的任务时，先向那核发 yield（`taskYIELD_CORE()`），内存回收交给该核的 Idle——你无法安全地直接释放一个正在被执行的栈；
- 任务不在任何核上运行时，内存立即释放，与 Vanilla 相同；
- `prvCheckTasksWaitingTermination()`（Idle 的回收循环）补了检查：跳过"仍在他核运行"的待回收任务。

至于**任务迁移**——搜索整个内核你也找不到 `vTaskMigrate()` 之类的函数，因为它不需要存在：任务上下文（栈、TCB）在共享 SRAM 里，对两个核等价可见；未钉核的任务每次被调度时"落在哪个核"完全由 `prvSelectHighestPriorityTaskSMP()` 的选择决定。第 1 章实验里 `(core 0)`/`(core 1)` 交替输出，就是任务在被重新选中的瞬间自然换了核——迁移的全部成本只是一次普通的上下文切换，外加 cache 局部性的损失。唯一不会发生的是"运行中途换核"：任务必须先被切出（阻塞/被抢占），才谈得上在别处被切入。

---

## 22.8 核亲和 API 使用守则

### 1. API 族全景

| API                                                    | 作用                            | 备注                                                                  |
| ------------------------------------------------------ | ------------------------------- | --------------------------------------------------------------------- |
| `xTaskCreatePinnedToCore(..., xCoreID)`                | 创建时指定亲和                  | `xCoreID` 取 `0` / `1` / `tskNO_AFFINITY`                             |
| `xTaskCreateStaticPinnedToCore(..., xCoreID)`          | 静态创建版                      | 同上                                                                  |
| `xTaskCreate()` / `xTaskCreateStatic()`                | Vanilla 原名                    | 内部转调 PinnedToCore 版、传 `tskNO_AFFINITY`（头文件里可见这条内联） |
| `xTaskGetCoreID(handle)`                               | 查任务的**亲和**                | 未钉核返回 `tskNO_AFFINITY`（`0x7FFFFFFF`），不是"当前所在核"！       |
| `xPortGetCoreID()`                                     | 查**当前执行流**所在核          | 端口层实现，任务/ISR 均可调                                           |
| `xTaskGetIdleTaskHandleForCore()` 等 `...ForCore()` 族 | 按核查 Idle 句柄/当前任务句柄等 | 单核构建只接受 `0`                                                    |

> [!note] 高频误用：xTaskGetCoreID ≠ xPortGetCoreID
> 两个名字像一对，语义完全不同。`xTaskGetCoreID(h)` 读的是 TCB 的 `xCoreID` 字段——**亲和属性**，对未钉核任务返回哨兵值 `tskNO_AFFINITY`；`xPortGetCoreID()` 问的是"此刻这条执行流在哪个核上"——**运行时事实**。想观察迁移用后者（第 1 章实验正是这么写的），想做亲和断言用前者。`idf_changes.md` 里也有一句 Todo：`tskNO_AFFINITY` 的值将来要从 `0x7FFFFFFF` 改成 `-1`——上游 Amazon SMP 内核已经是 `-1`，又一个两树差异。

### 2. 现实惯例：WiFi/BT 钉 Core 0

Core 0 / Core 1 的别称 **PRO_CPU / APP_CPU**（第 1 章提过）就是亲和惯例的化石：ESP-IDF 的 WiFi/蓝牙协议栈任务默认钉在 Core 0（PRO = Protocol），应用任务建议钉 Core 1（APP = Application）。落地守则：

1. **实时/高频任务**：钉核。免去"被另一核上恰好就绪的同优先级任务分走时间片"的不确定性，时间行为可分析。
2. **同优先级成组任务**：全组钉同一核（22.5 节，换回完美 RR）。
3. **轻量后台任务**：不钉（`tskNO_AFFINITY`），让调度器填空闲核——吞吐最优。
4. **别把重活堆上 Core 0**：WiFi/BT、系统事件循环、多数 IDF 服务默认都在 Core 0；应用侧的默认选项应是 Core 1 或不钉。例外也要知道：`menuconfig` 里定时器服务任务的亲和可配（`Component config → FreeRTOS → Timer task affinity`，对应 `FREERTOS_TIMER_TASK_AFFINITY_*`，这个可配置性本身是从上游 backport 的）。
5. **怀疑缓存/外设竞争问题时**：先试钉核隔离——这是双核排坑的第一反应（第 24 章的案例集会用到）。

---

## 22.9 实验：复现官方文档的 Best-Effort 调度序列

官方文档用四个同优先级任务演示 Best-Effort RR：**AX（不钉核）、B0（钉 Core 0）、C1（钉 Core 1）、D0（钉 Core 0）**。我们把它变成可运行的程序：四个任务同优先级纯忙等（不阻塞，让时间片成为唯一切换源），tick hook 计片，每个任务在新时间片里第一次上 CPU 时记一条 trace，记满后打印序列。

### 1. 工程与配置

```bash
cd ~ && idf.py create-project freertos-ch22 && cd freertos-ch22
echo "CONFIG_FREERTOS_USE_TICK_HOOK=y" >> sdkconfig.defaults   # 先写 defaults，再 set-target 让其生效
idf.py set-target esp32
```

### 2. 完整代码（main/freertos-ch22.c）

```c
#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define TRACE_LEN   32      /* 记录条数 */
#define SPIN_PRIO   3       /* 四个任务同优先级，高于 Idle */

static portMUX_TYPE s_trace_lock = portMUX_INITIALIZER_UNLOCKED;
static volatile int  s_slice;        /* 时间片序号：Core 0 的 tick hook 维护 */
static volatile int  s_trace_idx;
static volatile bool s_done;

struct trace_entry {
    int  slice;
    char task;
    int  core;
};
static struct trace_entry s_trace[TRACE_LEN];

/* tick hook 在两核的中断上下文都会进；只让 Core 0 计片（它是唯一的计时者） */
void vApplicationTickHook(void)
{
    if (xPortGetCoreID() == 0) {
        s_slice++;
    }
}

static void dump_trace(void)
{
    printf("\n slice task core\n");
    for (int i = 0; i < s_trace_idx; i++) {
        printf(" %5d %4c %4d\n",
               s_trace[i].slice, s_trace[i].task, s_trace[i].core);
    }
    printf("trace done, tasks self-deleting\n");
}

static void spin_task(void *arg)
{
    const char me = (char)(intptr_t)arg;
    int last_slice = -1;

    for (;;) {
        if (s_done) {
            vTaskDelete(NULL);               /* 收工：自删除，只剩每核 Idle */
        }
        if (s_slice != last_slice) {         /* 新时间片里第一次上 CPU */
            last_slice = s_slice;
            bool should_dump = false;
            portENTER_CRITICAL(&s_trace_lock);   /* trace 是双核共享数据 */
            if (s_trace_idx < TRACE_LEN) {
                s_trace[s_trace_idx].slice = s_slice;
                s_trace[s_trace_idx].task  = me;
                s_trace[s_trace_idx].core  = xPortGetCoreID();
                s_trace_idx++;
                should_dump = (s_trace_idx == TRACE_LEN);
            }
            portEXIT_CRITICAL(&s_trace_lock);
            if (should_dump) {               /* 恰好填满最后一个槽的任务负责汇总 */
                dump_trace();
                s_done = true;
            }
        }
    }
}

void app_main(void)
{
    xTaskCreatePinnedToCore(spin_task, "AX", 2048, (void *)(intptr_t)'A', SPIN_PRIO, NULL, tskNO_AFFINITY);
    xTaskCreatePinnedToCore(spin_task, "B0", 2048, (void *)(intptr_t)'B', SPIN_PRIO, NULL, 0);
    xTaskCreatePinnedToCore(spin_task, "C1", 2048, (void *)(intptr_t)'C', SPIN_PRIO, NULL, 1);
    xTaskCreatePinnedToCore(spin_task, "D0", 2048, (void *)(intptr_t)'D', SPIN_PRIO, NULL, 0);
}
```

三个设计说明：任务里**没有** `vTaskDelay`——任何阻塞都会引入时间片之外的切换源，污染序列；trace 写入用自旋锁临界区保护（第 18 章的 API 在双核共享缓冲上的标准用法）；dump 发生在 trace 记满之后，此时 printf 的阻塞怎么折腾都不影响已捕获的数据。

### 3. 跑起来

```bash
idf.py qemu monitor
```

### 4. 典型输出与逐步解读

两核 tick 相位独立，你看到的行序会与下面略有出入（个别行的先后可能相差一拍）——我们观察的是**分配模式**，不是指令级时间戳：

```text
 slice task core
     1    A    0
     1    C    1
     2    B    0
     2    A    1
     3    D    0
     3    C    1
     4    B    0
     4    A    1
     ...
trace done, tasks self-deleting
```

对照官方文档的四步走读（列表从 Head 到 Tail）：

```text
启动铺位后:  Head [ AX , B0 , C1 , D0 ] Tail        A 在 Core0, C 在 Core1（22.2 节铺位逻辑）

Core 0 tick: 选中 A，搬到尾
              Head [ B0 , C1 , D0 , AX ] Tail

Core 1 tick: B 亲和不兼容，跳过 → 选中 C，搬到尾
              Head [ B0 , D0 , AX , C1 ] Tail

Core 0 tick: 选中 B，搬到尾
              Head [ D0 , AX , C1 , B0 ] Tail

Core 1 tick: D 钉在 Core0，跳过 → 选中 A（A 此刻不在任何核上跑），搬到尾
              Head [ D0 , C1 , B0 , AX ] Tail
```

从输出里逐项核验本章的机制：

| 观察点                                   | 对应机制                                                          |
| ---------------------------------------- | ----------------------------------------------------------------- |
| `core` 列：B、D 永远是 0，C 永远是 1     | `taskIS_AFFINITY_COMPATIBLE()` 亲和校验（22.3 节校验二）          |
| 同一 slice 里 A 从不同时出现在两核       | "正被他核运行则跳过"（22.3 节校验一）                             |
| A 的 `core` 在 0/1 间漂移                | 无钉核任务在重新被选中时自然迁移（22.7 节）                       |
| Core 0 上 A→B→D 轮转、Core 1 上 C↔A 交替 | 选中即搬尾的 Best-Effort RR（22.5 节）                            |
| 长跑统计：A、C 的条数多于 B、D           | A 被两核分抢、C 独占 Core 1 的兼容任务位——"Best-Effort"不等于均分 |

最后一条最值得咀嚼：四个同优先级任务并不各得 25% CPU。B、D 只能在 Core 0 的轮转环里排队（各约 1/3 个 Core 0），C 独享 Core 1 的一半时间片，A 被两核轮流挑走。**同优先级 ≠ 等量 CPU**，这是从单核直觉带过来的第二个坑（第一个是 22.3 节的"前两名"）。

### 5. 变体实验：把 C 也钉到 Core 0

把 `C1` 的创建参数从 `1` 改成 `0` 再跑。此时 Core 1 唯一能运行的非 Idle 任务是 A（其余三个都钉 Core 0）：Core 0 认真轮转 A→B→C→D，Core 1 在 A 没被 Core 0 占用的片隙里反复捡起 A。输出特征：`core` 列里 C 从此只出现 0，A 大量出现在 1。一个参数的改动，调度图景完全重排——这就是亲和约束的力量，也是 22.8 节守则 2"同优先级任务钉同核"的现场教学。

---

## 22.10 上游的 SMP 化进展：Amazon SMP 内核一瞥

IDF fork 是"在 v10.5.1 上打补丁"，FreeRTOS 官方随后在 upstream 做了正统的 SMP 化（`FreeRTOS-Kernel` 的 smp 分支，v11.x 基线）。ESP-IDF v6.0.2 把它整个收进 `FreeRTOS-Kernel-SMP/`，用 `CONFIG_FREERTOS_SMP` 开关（默认关、实验性）。对照 `porting_notes.md`，与我们本章读过的 fork 在关键处分歧明显：

| 主题             | IDF fork（本章主角）                                               | Amazon SMP 内核                                                                                                                                   |
| ---------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 亲和模型         | 单值 `xCoreID`（0/1/无）                                           | 掩码 `uxCoreAffinityMask`，可"只在 0 和 1 跑"这类组合；配套 `vTaskCoreAffinitySet()`、`xTaskCreateAffinitySet()`（后者还是 Espressif 上游的贡献） |
| 调度器挂起       | 每核独立                                                           | **全局**：一核挂起，他核再想阻塞或调 API 就得关中断自旋等锁。IDF 为此把内部调用换成了新的 `vTaskPreemptionDisable()` 语义                         |
| 临界区           | 细粒度自旋锁（每队列/事件组/定时器各一把，两核可并行进不同临界区） | 巨锁（task/ISR 两把），且**临界区内检测状态变化**：发现更高优先级任务就绪会先退出让出再重进                                                       |
| Idle 任务        | 每核一个、钉核                                                     | 一个主动 Idle + N-1 个被动 Idle，全部**不钉核**、先到先得                                                                                         |
| tick             | Core 0 全责，Core 1 自查时间片                                     | 仅 Core 0 调 `xTaskIncrementTick()`，由它通过 `prvYieldCore()` 遥控**所有核**的时间片                                                             |
| 运行状态         | 无字段，比对 `pxCurrentTCBs[]`                                     | TCB 内置 `xTaskRunState`                                                                                                                          |
| `tskNO_AFFINITY` | `0x7FFFFFFF`（计划改 `-1`）                                        | `( UBaseType_t ) -1`                                                                                                                              |

为什么 Espressif 要引入第二棵树？`porting_notes.md` 的 Todo 部分给出了答案的一半：评估巨锁对 WiFi/BT 等时敏感组件的性能影响，可接受则整体迁移，不可接受则把 IDF 式细粒度临界区独立成 API 继续用。换句话说，**IDF fork 的"补丁"路线有一天会被上游的"正统"路线取代，而性能数据是裁决者**。对本系列读者，这意味着读两棵树的能力是保值的：fork 教你 SMP 改造的工程权衡，upstream 教你 SMP 的架构正解。

---

## 22.11 小结

- IDF FreeRTOS = Vanilla v10.5.1 + SMP 补丁，边界三条：基线钉死、最多两核、`CONFIG_FREERTOS_UNICORE` 可在**同一棵树**内回退单核（编译期剥离全部 SMP 数据、恢复完美 RR）。目录上是"默认树（IDF fork）+ 实验性上游 Amazon SMP 树"，两棵都 SMP capable，路线不同。
- 数据结构改造一句话：**状态每核一份、就绪链表仍然共享**。`pxCurrentTCBs[]`/`xYieldPending[]`/`uxSchedulerSuspended[]`/`xPendingReadyList[]`/`xIdleTaskHandle[]` 逐核化，TCB 新增 `xCoreID`；共享链表换来了天然迁移能力，代价是选择时刻的两重校验（亲和兼容 + 未在他核运行）和临界区内的遍历。
- 调度循环每核独立：`prvSelectHighestPriorityTaskSMP()` 自顶向下扫优先级、沿链表跳过不合规任务、**选中即搬尾**（Best-Effort RR 的实现本体）。推论一：全局优先级前两名不一定都在跑；推论二：同优先级 ≠ 等量 CPU。
- 抢占决策偏向当前核（`prvIsYieldRequiredSMP()` 先查本核、不行才对另一核发 `taskYIELD_CORE()` 跨核中断）——省 IPI 成本，也贴合"谁唤醒谁让路"的数据局部性。
- tick 职责不对称：Core 0 全责（计时、解锁、时间片、hook、补账），Core 1 只查自己的时间片并跑 hook。单一时间基准省掉了两核对时，代价是 Core 0 挂起即全系统时间冻结；Core 1 的远程抢占用 `xYieldPending[1]` 记账、延迟兑现。
- Idle 每核一个且钉核（兜底必须永远可达）；`vTaskSuspendAll()` 只挂起本核——**不再是互斥手段**；删除他核任务靠"发 yield + Idle 回收"；迁移没有专门 API，它就是未钉核任务被重新选中时的自然结果。
- 亲和守则：实时任务钉核、同优先级成组钉同核、后台任务不钉、应用默认上 Core 1（Core 0 住着 WiFi/BT，PRO_CPU/APP_CPU 之名由此而来）；`xTaskGetCoreID()` 查的是亲和（未钉核返回 `tskNO_AFFINITY`），`xPortGetCoreID()` 查的是当前核，别混用。
- 实验：四任务 AX/B0/C1/D0 复现了官方 Best-Effort 序列——亲和合规、无重复占用、搬尾轮转、不均分配四个机制全部肉眼可见；把 C 改钉 Core 0 的变体重演了"亲和约束重排调度图景"。

下一章进入双核世界剩下的最后一块硬骨头：**核间同步机制**。`taskYIELD_CORE()` 发出的那个跨核中断究竟怎么送达另一核、自旋锁在 Xtensa 上靠什么原子指令实现、两个核看同一片内存时 cache 一致性由谁保证——第 23 章（[[ch23-cross-core-synchronization|第23章]]）把 18 章埋下的 spinlock 伏笔和本章的 IPI 伏笔一并收回。
