---
title: "FreeRTOS 深度解析（七）：上下文切换：从 portYIELD() 到汇编的每一步"
date: 2026-08-26
description: "追踪上下文切换的全部三条触发路径（主动让出、阻塞让出、tick 抢占），拆解 vTaskSwitchContext 的选任务逻辑与 Xtensa 端口从 vPortYield 到 _frxt_dispatch 的完整汇编链路，并用 QEMU+GDB 踩住切换点实地观察。"
tags: [freertos, rtos, esp32, esp-idf, xtensa, context-switch, assembly, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 7. **第七章：上下文切换：从 portYIELD() 到汇编的每一步**

# FreeRTOS 深度解析（七）：上下文切换：从 portYIELD() 到汇编的每一步

第六章读完了就绪链表，知道了"谁该跑"是怎么被记录的。这一章回答下一个问题：**从一个任务切换到另一个任务，CPU 里到底发生了什么**。结论先行：

> 上下文切换 = **两行数据搬运 + 一次函数调用**。把当前任务的 SP 存进它的 TCB（`pxCurrentTCB->pxTopOfStack = sp`），把新任务的 SP 装回 SP 寄存器（`sp = pxCurrentTCB->pxTopOfStack`），中间夹一次 `vTaskSwitchContext()` 选出"新任务是谁"。其余几十行汇编，全部是在为这三件事服务——安全地保存现场、区分恢复方式、处理 Xtensa 特有的寄存器窗口与协处理器。

本章所有源码引用基于 ESP-IDF v6.0.2 默认编入的 IDF FreeRTOS 树（`components/freertos/FreeRTOS-Kernel/`，即 Vanilla v10.5.1 的 SMP 改造版），端口文件位于其 `portable/xtensa/` 下；向量与上下文原语来自共享的 `components/xtensa/` 组件。

---

## 7.1 全景：三条触发路径，一个汇合点

先建立地图，再逐段拆解。切换只有三个入口，但全部汇合到同一个汇编函数 `_frxt_dispatch()`：

```text
 路径① 主动让出                路径② 阻塞让出                       路径③ tick 抢占
 taskYIELD()                   vTaskDelay() / 等队列满             CCOMPARE 比较命中（tick 到点）
    │                              │                                    │  硬件陷阱进向量
    │                              │  当前任务移入 DelayedList           ▼
    │                              │  （已不在就绪表里！）             _xt_lowint1 (xtensa_vectors.S)
    ▼                              │                                    │  在任务栈上建中断帧
 vPortYield()                      │  portYIELD_WITHIN_API()            │  call0 _frxt_int_enter
 构造 solicited 帧                 │  = esp_crosscore_int_send_yield    │    嵌套计数+1
 窗口溢出 xthal_window_spill_nw    │    给【自己】发 CPU-from-CPU 中断   │    切到每核系统栈 port_IntStack
 SP 存入 TCB                       ▼                                    ▼
    │                        esp_crosscore_isr                       dispatch_c_isr
    │                        portYIELD_FROM_ISR()                   _frxt_timer_int (portasm.S)
    │                              │                                  │  重装 CCOMPARE 补拍
    │                        _frxt_setup_switch                      │  call4 xPortSysTickHandler
    │                        port_switch_flag[core] = 1              │    core0: xTaskIncrementTick()
    │                              │                                  │    core1: xTaskIncrementTickOtherCores()
    │                         （此刻不切换！）                         │  需要切换？
    │                              │                                  ▼
    │                              │                            portYIELD_FROM_ISR()
    │                              │                                  │
    │                              ▼                                  ▼
    │                        _frxt_int_exit                     _frxt_setup_switch
    │                        嵌套-1；flag=1? → 切换              port_switch_flag[core] = 1
    │                              │                                  │
    │                              └───────────────┬──────────────────┘
    │                                              ▼
    │                                      vPortYieldFromInt   存 CPENABLE→CPSA，清 CPENABLE
    │                                              │
    └──────────────────┬──────────────（路径①不经 vPortYieldFromInt，直接尾调用）
                       ▼
              _frxt_dispatch()          ←—— 三条路径的唯一汇合点
                       │  call4 vTaskSwitchContext      内核侧：纯 C 选下一个 TCB
                       │  sp = pxCurrentTCBs[core]->pxTopOfStack
                       │  读新栈帧 XT_STK_EXIT 判帧型：
                       │     == 0  solicited 帧 → 恢复最小现场，retw 回到 portYIELD() 调用点
                       │     != 0  中断帧     → _xt_context_restore 全量恢复 → 跳中断退出派发器
                       ▼
                  新任务从"上次停下的那条指令"继续执行
```

三个值得先刻进脑子的观察：

### 1. 内核与端口的分工极其干净

`tasks.c` 里的 `vTaskSwitchContext()` 是纯 C，它**碰不到任何寄存器**——它只做数据结构操作（链表、TCB、优先级），产出"新 TCB 指针"这一个结果。所有碰 SP/PC/PS 的动作都在端口层汇编里。这就是为什么同一份 `tasks.c` 能跑在 40 多种架构上：换 CPU 只换汇编，不换调度逻辑。

### 2. 路径①和②③的保存方式不同

主动让出走 `vPortYield()`，在**任务自己的栈**上构造一个极小的 solicited 帧；中断触发的切换在**任务栈上的中断帧**里保存全量现场。同一个 `_frxt_dispatch()` 恢复时靠帧首的 `XT_STK_EXIT` 字段区分这两种帧（细节在 7.6）。

### 3. 路径②③都是"延迟切换"

在 ISR 里调用 `portYIELD_FROM_ISR()` 并不会立刻切换——它只把 `port_switch_flag[core]` 置 1，真正的切换发生在 `_frxt_int_exit()` 确认这是最外层中断、即将退出时。这是 Xtensa 端口最重要的语义之一，7.4 与 7.8 展开。

---

## 7.2 路径①：任务主动让出，`taskYIELD()` 直达汇编

`taskYIELD()` 是 FreeRTOS 的公共 API（协作式调度的钥匙），它只是 `portmacro.h` 中宏的薄包装。Xtensa 端口里的三行映射（`portable/xtensa/include/freertos/portmacro.h`）：

| 宏                       | 落到哪                                                  | 语义                        |
| ------------------------ | ------------------------------------------------------- | --------------------------- |
| `portYIELD()`            | `vPortYield()`（`portasm.S` 中的汇编函数）              | 任务上下文：立即切换        |
| `portYIELD_FROM_ISR(x)`  | `vPortYieldFromISR()` → `_frxt_setup_switch()`          | 中断上下文：登记延迟切换    |
| `portYIELD_CORE(x)`      | `vPortYieldCore(x)` → `esp_crosscore_int_send_yield(x)` | 让**另一个核**切换          |
| `portYIELD_WITHIN_API()` | `esp_crosscore_int_send_yield(xPortGetCoreID())`        | 内核内部 API 的让出（见下） |

什么时候走路径①？两个典型场景：应用显式调用 `taskYIELD()`（同优先级任务间手工分时）；内核在某些 API 尾部发现"继续跑当前任务已不合适"时。它是最快的一条切换路径——从宏到汇编只有一跳，没有任何中断参与。

> [!tip] Vanilla vs ESP-IDF：`portYIELD_WITHIN_API` 的分道扬镳
> 内核源码里有一类内部让出点（`vTaskDelay()` 尾部、`xTaskRemoveFromEventList()` 唤醒更高优先级任务后……），统一走 `portYIELD_WITHIN_API()`：
>
> | 主题   | Vanilla FreeRTOS（ARM Cortex-M）                                       | IDF FreeRTOS（Xtensa）                                                                                                                                                                              |
> | ------ | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
> | 定义   | `#define portYIELD_WITHIN_API() portYIELD()`，即直接 pend PendSV       | `esp_crosscore_int_send_yield(自核)`——**给自己发一个核间软件中断**                                                                                                                                  |
> | 为什么 | PendSV 天生可延迟，pend 上之后即使当前还在临界区，切换也会等到安全时刻 | 这些让出点发生在**持有内核自旋锁**（`xKernelLock`）的临界区内；若直接调 `vPortYield()` 会在带着锁的状态下切换走，新任务再拿锁必然死锁。改走自核 IPI：中断只在临界区退出后才被响应，切换时机天然安全 |
> | 代价   | 零额外成本                                                             | 多一次自核中断往返（数百 ns 级），换来 SMP 正确性                                                                                                                                                   |
>
> 这是双核化改造里最典型的"语义等价、实现重写"：单核世界的"pend 一个最低优先级中断"没有硬件对应物，IDF 就用 CPU-from-CPU 软中断亲手造了一个。

---

## 7.3 路径②：阻塞让出，`vTaskDelay()` 的完整链路

"任务把自己挂起、CPU 让给别人"是 RTOS 的日常。以 `vTaskDelay()` 为例走一遍（`tasks.c`）：

```c
void vTaskDelay( const TickType_t xTicksToDelay )
{
    BaseType_t xAlreadyYielded = pdFALSE;

    if( xTicksToDelay > ( TickType_t ) 0U )
    {
        configASSERT( taskIS_SCHEDULER_SUSPENDED() == pdFALSE );
        prvENTER_CRITICAL_OR_SUSPEND_ALL( &xKernelLock );      /* 拿内核锁/挂起调度 */
        {
            traceTASK_DELAY();
            /* 把当前任务从就绪链表摘下，按唤醒时刻插入 DelayedList */
            prvAddCurrentTaskToDelayedList( xTicksToDelay, pdFALSE );
        }
        xAlreadyYielded = prvEXIT_CRITICAL_OR_RESUME_ALL( &xKernelLock );
    }

    /* 关键点：此刻当前任务已不在就绪表中，必须强制重调度 */
    if( xAlreadyYielded == pdFALSE )
    {
        portYIELD_WITHIN_API();        /* → esp_crosscore_int_send_yield(自核) */
    }
}
```

### 1. 切换的动因是"自己消失了"

与路径①本质不同：`taskYIELD()` 时当前任务**仍在**就绪链表里（它只是排到队尾）；而 `prvAddCurrentTaskToDelayedList()` 之后，当前任务已经从调度器的候选名单中**除名**。不切换就没人可跑了——这就是函数尾部那句 `portYIELD_WITHIN_API()` 必须存在的原因。`prvEXIT_CRITICAL_OR_RESUME_ALL()` 若在恢复过程中已经触发过让出（返回 `pdTRUE`），就不再重复。

### 2. 接收端：crosscore ISR

`esp_crosscore_int_send_yield()` 在 `components/esp_system/crosscore_int.c` 里：置起 `reason[core] |= REASON_YIELD`，然后触发该核的 CPU-from-CPU 软中断。接收端 `esp_crosscore_isr()`：

```c
if( my_reason_val & REASON_YIELD ) {
    esp_crosscore_isr_handle_yield();   /* → portYIELD_FROM_ISR() */
}
```

于是路径②从此汇入路径③的机制：`_frxt_setup_switch()` 置 `port_switch_flag[core]`，真正的切换延迟到中断退出。

### 3. 为什么"给自己发中断"不是浪费

表面看这是一次绕路（本可以直接调 `vPortYield()`），但它一举解决了两个问题：其一，7.2 提过的**持锁切换**风险；其二，**切换时机统一**——所有"被动切换"（阻塞让出、被抢占、被跨核唤醒）最终都从同一条中断退出路径走，`_frxt_dispatch` 之后的恢复逻辑只有一份。

---

## 7.4 路径③：tick 抢占，从 CCOMPARE 到延迟切换

时间片轮转和超时唤醒都靠 tick 中断驱动。ESP32（经典版）上这条链路是：

### 1. tick 的到达

ESP32 默认用 Xtensa 核内定时器产生 tick（`Kconfig` 的 `FREERTOS_CORETIMER_0` 默认项 → `CONFIG_FREERTOS_SYSTICK_USES_CCOUNT`）：CCOUNT 计数器撞上 CCOMPARE 比较值时触发 6 号 level-1 中断，进入 `xtensa_vectors.S` 的 `_xt_lowint1`，再分发到 `portasm.S` 的 `_frxt_timer_int()`——它先按旧比较值加周期重装 CCOMPARE（防止中断延迟造成时钟漂移，落后多个 tick 时循环补拍），然后调用 `port_systick.c` 的 `xPortSysTickHandler()`。（S3/C3 等新目标改用 SYSTIMER 外设，入口换成 `SysTickIsrHandler`，后续链路相同。）

### 2. 双核的 tick 分工

`xPortSysTickHandler()` 里有一段决定性的分岔：

```c
if (xPortGetCoreID() == 0) {
    xSwitchRequired = xTaskIncrementTick();        /* 核 0：全责 */
} else {
    xSwitchRequired = xTaskIncrementTickOtherCores(); /* 核 1：只查时间片 */
}
...
if (xSwitchRequired != pdFALSE) {
    portYIELD_FROM_ISR();                          /* 延迟切换 */
}
```

两个核**各自**收到 tick 中断，但职责不同（`idf_changes.md` 明文记录的设计决策）：

| 职责                                  | Core 0（`xTaskIncrementTick`）                                                           | Core 1（`xTaskIncrementTickOtherCores`，实现于 `esp_additions/freertos_tasks_c_additions.h`） |
| ------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| 计数 `xTickCount++`、交换溢出延迟链表 | ✅                                                                                       | ❌                                                                                            |
| 到期任务解锁入就绪表                  | ✅                                                                                       | ❌                                                                                            |
| 判断"解锁的任务该抢占谁"              | ✅（本核直接置 `xSwitchRequired`；对端核置 `xYieldPending[1]`，等核 1 自己的 tick 兑现） | ❌（只检查 `xYieldPending[1]`）                                                               |
| 同优先级时间片检查                    | ✅（查核 0 当前任务的就绪链长度）                                                        | ✅（查核 1 的）                                                                               |
| tick hook                             | ✅                                                                                       | ✅                                                                                            |

### 3. `portYIELD_FROM_ISR` 的延迟语义

`xTaskIncrementTick()` 返回 `pdTRUE` 后，`portYIELD_FROM_ISR()` → `vPortYieldFromISR()` → `_frxt_setup_switch()`，而它只做一件事（`portasm.S`）：

```text
_frxt_setup_switch:
    ENTRY(16)
    getcoreid a3
    movi    a2, port_switch_flag
    addx4   a2,  a3, a2          ; &port_switch_flag[coreid]
    movi    a3, 1
    s32i    a3, a2, 0            ; port_switch_flag[coreid] = 1
    RET(16)
```

**置一个标志，立刻返回**。为什么不在 ISR 里直接切？因为此刻可能：中断是嵌套的（外层还有 ISR 没跑完）；C ISR 还在一层层返回、栈还没退到中断入口；甚至马上还有更高优先级中断要来。Xtensa 的窗口式 ABI 要求切换发生在"中断退出、栈完全展开"的那一刻——这个消费 `port_switch_flag` 的时刻就是 `_frxt_int_exit()`（7.7）。用户 ISR 里从 `xQueueReceiveFromISR()` 拿到 `xHigherPriorityTaskWoken == pdTRUE` 后调 `portYIELD_FROM_ISR(x)`，语义完全相同。

---

## 7.5 `vTaskSwitchContext()`：内核选出下一个任务

三条路径汇合后，`_frxt_dispatch()` 第一件正事就是调它（IDF fork 中签名为 `void vTaskSwitchContext(void)`，核号自己读）。骨架（`tasks.c`）：

```c
void vTaskSwitchContext( void )
{
    prvENTER_CRITICAL_SAFE_SMP_ONLY( &xKernelLock );   /* 拿内核自旋锁 */
    {
        const BaseType_t xCurCoreID = portGET_CORE_ID();

        if( uxSchedulerSuspended[ xCurCoreID ] != pdFALSE ) {
            xYieldPending[ xCurCoreID ] = pdTRUE;      /* 本核调度器被挂起：记下，迟点切 */
        }
        else {
            xYieldPending[ xCurCoreID ] = pdFALSE;
            traceTASK_SWITCHED_OUT();
            /* ……运行时统计记账、栈溢出检查、errno 保存进 TCB…… */
            taskSELECT_HIGHEST_PRIORITY_TASK();        /* 核心：选下一个任务 */
            traceTASK_SWITCHED_IN();
            /* ……errno 换载、栈监视点重设、TLS 块切换…… */
        }
    }
    prvEXIT_CRITICAL_SAFE_SMP_ONLY( &xKernelLock );
}
```

三个 SMP 味道浓烈的细节：内核数据用自旋锁 `xKernelLock` 保护而非关中断（第 18 章主题）；`uxSchedulerSuspended[]`/`xYieldPending[]` 都是**每核一份**（`vTaskSuspendAll()` 只挂起当前核）；被挂起时不敢硬切，改为记 `xYieldPending`，等恢复调度时补切——保证临界区原子性。

### 1. `prvSelectHighestPriorityTaskSMP()` 逐步拆解

多核时 `taskSELECT_HIGHEST_PRIORITY_TASK()` 映射到这个函数。它从 `uxTopReadyPriority`（第六章见过的"最高非空优先级缓存"）向下扫描：

```c
for( uxCurPriority = uxTopReadyPriority; uxCurPriority >= 0 && xTaskScheduled == pdFALSE; uxCurPriority-- )
{
    if( listLIST_IS_EMPTY( &( pxReadyTasksLists[ uxCurPriority ] ) ) ) continue;

    /* 重置 pxIndex 到表尾，从头遍历本优先级就绪链表 */
    ...
    do {
        /* ① 被别的核正在跑的任务 → 跳过 */
        for( x = 0; x < configNUMBER_OF_CORES; x++ ) {
            if( x != xCurCoreID && pxCurrentTCBs[ x ] == pxTCBCur ) goto get_next_task;
        }
        /* ② 核亲和不兼容（pin 在另一个核）→ 跳过 */
        if( taskIS_AFFINITY_COMPATIBLE( xCurCoreID, pxTCBCur ) == pdFALSE ) goto get_next_task;

        /* ③ 可跑：选中它 */
        pxCurrentTCBs[ xCurCoreID ] = pxTCBCur;
        xTaskScheduled = pdTRUE;

        /* ④ 把它挪到链表末尾 —— Best-Effort Round-Robin 的全部秘密 */
        listREMOVE_ITEM( &( pxTCBCur->xStateListItem ) );
        listINSERT_END( &( pxReadyTasksLists[ uxCurPriority ] ), &( pxTCBCur->xStateListItem ) );
        break;

get_next_task:
        listGET_OWNER_OF_NEXT_ENTRY( pxTCBCur, ... );   /* 链表转一圈都不可跑则降优先级 */
    } while( pxTCBCur != pxTCBFirst );
}
```

单核版（`configNUMBER_OF_CORES == 1`）是教科书原版：找到最高非空优先级，`listGET_OWNER_OF_NEXT_ENTRY()` 取"轮到下一个"。多核版多了两个过滤器（在别的核上跑、亲和不符），并且**选中即挪尾**。

### 2. 挪尾：IDF 时间片的实现基石

源码注释直言：_"Move the current tasks list item to the back of the list in order to implement best effort round robin"_。被选中的任务挪到链表尾，下次本优先级再有选择机会时，排在前面等更久的任务先被看到。但"核可能跳过链头上正被另一个核执行的任务"，导致轮转不严格均分——这就是官方文档所说 **Best-Effort Round-Robin** 的源码出处，第 8 章用实验量化它。

> [!note] Vanilla vs ESP-IDF：选任务算法对照
>
> | 主题         | Vanilla v10.5.1（单核）                                                                              | IDF fork（SMP）                                           |
> | ------------ | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
> | 选择函数     | 宏 `taskSELECT_HIGHEST_PRIORITY_TASK()`：`uxTopReadyPriority` 下探 + `listGET_OWNER_OF_NEXT_ENTRY()` | `prvSelectHighestPriorityTaskSMP()`：逐优先级、逐任务过滤 |
> | 过滤条件     | 无（唯一核天然可跑所有任务）                                                                         | 不在别的核上运行 + 核亲和兼容                             |
> | 同优先级轮转 | 完美 RR：`pxIndex` 每次精确前进一步，均分时间片                                                      | Best-Effort RR：选中挪尾，但跳过"他核在跑"的任务时会错位  |
> | 当前任务指针 | 单个 `pxCurrentTCB`                                                                                  | 数组 `pxCurrentTCBs[configNUMBER_OF_CORES]`，每核一份     |
> | 并发保护     | 关中断即可（单核）                                                                                   | `xKernelLock` 自旋锁 + 关本核中断                         |

---

## 7.6 汇编现场：`vPortYield()` → `_frxt_dispatch()`

现在钻进 `portasm.S`。`vPortYield()` 是路径①的主体，做四件事（窗口式 ABI 分支）：

```text
vPortYield:
    entry   sp,  XT_SOL_FRMSZ          ; ① 开 solicited 帧（复用调用者的寄存器窗口）
    rsr     a2,  XT_REG_PS             ; ② 保存返回点与最小现场：
    s32i    a0,  sp, XT_SOL_PC         ;    返回地址、PS、THREADPTR（TLS 基址）
    s32i    a2,  sp, XT_SOL_PS         ;    窗口式 ABI 下 a0-a15 都在寄存器窗口里，
    rur.threadptr a2                   ;    无需逐个入栈（见下）
    s32i    a2,  sp, XT_SOL_THREADPTR
    ; …… 关 WOE、置 EXCM 后 call0 xthal_window_spill_nw：把深层窗口强制溢出到栈 ……
    rsil    a2,  XCHAL_EXCM_LEVEL      ; ③ 关低中级中断（切换期间不可被打断）
    call0   _xt_coproc_savecs          ;    惰性保存协处理器 callee-saved 部分
    movi    a2,  pxCurrentTCBs         ; ④ SP 存入 TCB，帧标记为 solicited
    getcoreid a3
    addx4   a2,  a3, a2
    l32i    a2,  a2, 0
    movi    a3,  0
    s32i    a3,  sp, XT_SOL_EXIT       ;    写 0 —— "这是自愿让出的帧"
    s32i    sp,  a2, TOPOFSTACK_OFFS   ;    pxCurrentTCBs[core]->pxTopOfStack = SP
    wsr     a3,  XT_REG_CPENABLE       ;    清协处理器使能（交给新任务按需触发）
    call0   _frxt_dispatch             ; 尾调用派发器，永不返回到这
```

### 1. 窗口式 ABI：为什么不保存 64 个通用寄存器

Xtensa LX6 有 64 个物理通用寄存器，但任何时刻任务只能"看见"其中连续 16 个（一个窗口）。`call4/call8/call12` 指令旋转窗口，旧窗口的寄存器**并不自动入栈**——它们还躺在物理寄存器里，等 `retw` 旋回来或窗口溢出异常时才落栈。于是保存现场不需要 64 次访存：只要保证"窗口链上所有未溢出的寄存器都已经写到栈上"，`sp` 之外的状态就全部安全。`xthal_window_spill_nw()` 干的就是这件事（`_nw` = no window，避免额外窗口旋转的省时钟版本）。恢复时反过来：新任务从自己的 `sp` 开始 `retw`，窗口旋转会触发 underflow 异常把寄存器从栈里捞回来。**上下文切换成本与调用深度成正比，而不是与寄存器总数成正比**——这是 Xtensa 和 ARM 最大的结构性差异（详见[[ch17-xtensa-port-internals|第17章]]）。

### 2. `_frxt_dispatch()`：分派器与两种帧

```text
_frxt_dispatch:
    call4   vTaskSwitchContext         ; 内核选任务（IDF 版无参，核号由函数自查）
    movi    a2, pxCurrentTCBs
    getcoreid a3
    addx4   a2, a3, a2
    l32i    a3,  a2, 0                 ; a3 = 新 TCB
    l32i    sp,  a3, TOPOFSTACK_OFFS   ; ★ 换栈：sp = 新任务保存的栈顶
    s32i    a3,  a2, 0                 ; 提交 pxCurrentTCBs[core] = 新 TCB
    l32i    a2,  sp, XT_STK_EXIT       ; 读新栈帧的"帧类型"字段
    bnez    a2,  .L_frxt_dispatch_stk
```

帧类型分两种，恰好对应"它是怎么睡着的"：

```text
 新任务的栈（高地址在上）
 ┌──────────────────────┐
 │ solicited 帧情形：    │   XT_STK_EXIT == 0
 │  THREADPTR/PS/PC     │   → 任务上次是调 vPortYield() 睡的
 ├──────────────────────┤   → 恢复 THREADPTR、PS、a0 后 retw，
 │ （调用链的旧窗口……）   │      "从 portYIELD() 调用点返回"
 ├──────────────────────┤
 │                      │
 │ 中断帧情形：          │   XT_STK_EXIT == _xt_user_exit 等派发器地址
 │  PC/PS/A0..A15/SAR…  │   → 任务上次是被中断打断的
 │  + 基础保存区         │   → _xt_context_restore 全量恢复后，
 └──────────────────────┘      ret 跳到退出派发器，"从中断返回"
```

一个任务被切走的方式决定了它被切回的方式。第一次调度也利用了这一点——7.8 揭晓。

---

## 7.7 中断侧的切换：`_frxt_int_enter()` / `_frxt_int_exit()`

路径②③共享的中断进出机制，由 `components/xtensa/xtensa_vectors.S` 的通用向量与 FreeRTOS 端口挂钩（`xtensa_rtos.h` 把 `XT_RTOS_INT_ENTER`/`XT_RTOS_INT_EXIT` 定义为 `_frxt_int_enter`/`_frxt_int_exit`）协作完成：

### 1. 入口：任务栈上的中断帧与系统栈切换

`_xt_lowint1`（level-1 中断公共入口）先在被打断任务的栈上建标准中断帧（存 A1/PS/PC/A0，`XT_STK_EXIT` 填 `_xt_user_exit`），然后 `call0 _frxt_int_enter`：

```text
    嵌套计数 port_interruptNesting[core]++
    若是第一层嵌套：
        pxCurrentTCBs[core]->pxTopOfStack = sp   ; 记下任务栈位置
        sp = port_IntStack[core] + configISR_STACK_SIZE   ; 换到本核系统栈
```

此后 ISR 的 C 代码全部跑在**独立的每核中断栈**上（`port.c` 定义 `port_IntStack[portNUM_PROCESSORS][configISR_STACK_SIZE]`），任务栈只需容纳一个中断帧的空间——这就是 IDF 任务栈可以给得比想象小的原因之一（栈预算的完整账本见[[ch21-stack-and-memory-layout|第21章]]）。若已是嵌套中断，则继续用当前系统栈，只加计数。

### 2. 出口：消费 `port_switch_flag` 的那一刻

所有 ISR 返回时经过 `_frxt_int_exit`，它是延迟切换的兑现处：

```text
_frxt_int_exit:
    rsil    a0, XCHAL_EXCM_LEVEL        ; 关中断
    嵌套计数--
    bnez    …… → .Lnesting               ; 还有外层 ISR：直接恢复现场返回
    sp = pxCurrentTCBs[core]->pxTopOfStack   ; 回到任务栈帧
    l32i    a3, [port_switch_flag + core*4]
    beqz    a3, .Lnoswitch              ; flag==0：没人要求切换
    ……清零 flag……
    call4   vPortYieldFromInt            ; 存 CPENABLE→CPSA、清 CPENABLE
    call0   _frxt_dispatch               ; 真正切换，不返回
.Lnoswitch/.Lnesting:
    call0   _xt_context_restore          ; 不切换：原样恢复被打断的任务
    l32i    a0, sp, XT_STK_EXIT
    ret                                  ; 跳回中断退出派发器
```

注意 `vPortYieldFromInt` 在窗口式 ABI 下**只是准备协处理器状态然后返回**，真正的切换由随后的 `_frxt_dispatch` 完成——注释里写得很清楚：_"Windowed ABI defers the actual context switch until the stack is unwound to interrupt entry"_。窗口式 ABI 的栈展开必须完整走完，切换才有正确的落点。

---

## 7.8 首次调度：`xPortStartScheduler()` 与第一个任务的"伪造现场"

调度器启动是切换机制的"第 0 次"应用。双核各自的来路（`components/freertos/app_startup.c` 注释原话）：

```text
Core 0:  main() → esp_startup_start_app() → … → vTaskStartScheduler()
                                          → 创建每核 Idle 任务/定时器任务
                                          → xPortStartScheduler()
Core 1:  start_cpu1 → esp_startup_start_app_other_cores()
                        → esp_crosscore_int_init()   ; 装好核间中断
                        → xPortStartScheduler()      ; 不经过 vTaskStartScheduler
```

`port.c` 的 `xPortStartScheduler()` 收尾只有一行汇编，但前面的铺垫缺一不可：

```c
BaseType_t xPortStartScheduler( void )
{
    portDISABLE_INTERRUPTS();              /* 关中断，赌一个原子启动窗口 */
    _xt_coproc_init();                     /* 初始化协处理器所有权表 */
    vPortSetupTimer();                     /* 装 tick：重置 CCOUNT/CCOMPARE 并开中断源 */
    port_xSchedulerRunning[coreID] = 1;    /* 端口状态：调度器已运行（汇编会查它） */
    xthal_window_spill();                  /* 把启动栈上的旧窗口全部溢出——
                                              main 任务将回收启动栈，残留引用会炸 */
    __asm__ volatile ("call0    _frxt_dispatch\n");   /* ★ 跳进派发器，永不返回 */
    return pdTRUE;                         /* 到不了这里 */
}
```

`call0 _frxt_dispatch` 与运行期切换走的是**同一个派发器**：调 `vTaskSwitchContext()` 选出最高优先级就绪任务，`sp` 换成它的栈，然后按帧类型恢复。妙处在于：此刻"当前任务"还不存在，但派发器根本不在乎——它只消费 `pxCurrentTCBs[core]` 指向的下一个 TCB。

### 1. 第一个任务的现场是伪造的

`pxPortInitialiseStack()`（`port.c`）在 `xTaskCreate` 时就为每个任务备好了"出生帧"，布局为协处理器保存区（CPSA）→ TLS 区 → 一个**伪装成"刚被中断"的完整中断帧**：

| 帧字段              | 初始值                                        | 含图                                                                                 |
| ------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------ |
| `pc`                | 任务函数地址                                  | `_xt_context_restore` 恢复后跳到这——任务的第一条指令                                 |
| `ps`                | `PS_UM \| PS_EXCM \| PS_WOE \| PS_CALLINC(1)` | 用户态 + 窗口使能 + 伪装"被 call4 调用过"（CALLINC=1），`rfe`/退出派发器走完即开中断 |
| `a0`                | 0                                             | 返回地址置 0：任务函数不许返回，也顺便终结 GDB 回溯                                  |
| `a1`                | 帧顶                                          | 任务的第一版栈指针                                                                   |
| `a6`/`a7`           | 参数指针                                      | 窗口式 ABI 下 `call4` 的参数位——伪装的彻底性连参数传递方式都复刻                     |
| `exit`              | `_xt_user_exit`                               | 非零 → `_frxt_dispatch` 认定这是"中断帧"，走全量恢复分支                             |
| THREADPTR（扩展区） | TLS 计算值                                    | 任务局部变量的基址（第 21 章）                                                       |

所以"启动第一个任务"没有任何特殊指令：把一个从未运行过的任务**描述成"曾经运行、只是恰好在第一行前被打断"**，复用统一的恢复路径。这与 Vanilla Cortex-M 用 `SVC 0` 软件中断触发 `vPortSVCHandler` 恢复首任务的思路同源——都是"借用既有机制补完最后一次不对称"。

---

## 7.9 到底保存了什么：寄存器、PS、窗口与协处理器

把"现场"这个词拆开，Xtensa 任务的完整状态分四层，保存位置各不相同：

| 状态层     | 内容                                               | 保存在哪                                                        | 何时保存                                                                                                |
| ---------- | -------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 通用寄存器 | 窗口内 a0–a15 + 深层窗口                           | 任务栈（溢出机制）                                              | solicit：`xthal_window_spill_nw`；中断：`_xt_context_save`（向量入口已存 a0/a1/pc/ps，其余按 ABI 补齐） |
| 特殊寄存器 | PS（处理器状态）、SAR、LBEG/LEND/LCOUNT、THREADPTR | 帧内固定槽位（`xtensa_context.h` 的 `XtExcFrame`/`XtSolFrame`） | 两种帧都存（solicited 帧只存 PS/THREADPTR 等 callee-saved 部分）                                        |
| 协处理器   | FPU 等 CP0–CP7 的寄存器组                          | 任务栈顶的 CPSA 区（`XT_CP_SIZE`）                              | **惰性**：仅"拥有权"随帧迁移，寄存器本体按需搬（见下）                                                  |
| 内核状态   | errno、TLS 指针、运行时统计                        | TCB 字段                                                        | `vTaskSwitchContext` 在 C 层换载                                                                        |

### 1. PS 的特殊性

PS 一个寄存器打包了 INTLEVEL（中断级别）、EXCM（异常禁止）、WOE（窗口使能）、UM（用户态）、CALLINC（调用深度）——恢复 PS 等于**一次性恢复中断开关状态与 ABI 执行模式**。所以汇编里恢复 PS 的时机极其讲究：`_frxt_dispatch` 恢复 solicited 帧时最后一步才 `wsr PS`，注释写着 _"As soon as PS is restored, interrupts can happen"_——写完 PS 这台 CPU 就已经不是切换前的它了。

### 2. 协处理器的惰性切换

FPU 上下文很大（ESP32 的 FPU 寄存器组 + 可能的其他 CP），逐次切换保存是纯浪费。Xtensa 的方案是**所有权机制**：`CPENABLE` 寄存器记录"哪些协处理器当前对任务开放"；切换时 `vPortYield`/`vPortYieldFromInt` 只把 CPENABLE 存进新栈帧对应的 CPSA 并清零；新任务一旦执行 FPU 指令而它不拥有该 CP，硬件触发**协处理器禁用异常**，异常处理程序（`xtensa_vectors.S` 挂接、`portasm.S` 的 `_frxt_task_coproc_state`/`_frxt_coproc_exc_hook` 配合）才真正搬运寄存器组、转移所有权。不用 FPU 的任务永远付不起这笔钱。多核还添了一笔：协处理器所有权绑核，未钉核的任务一旦用了 FPU，`_frxt_coproc_exc_hook` 会当场把它钉到当前核（改写 `TCB.xCoreID`）——浮点任务从此不再迁移，这是第 22 章 SMP 语义的一个伏笔。

> [!note] ISR 里为什么禁用协处理器
> `xtensa_context.h` 注释明说：中断/异常处理程序不得使用协处理器，否则协处理器异常处理会内核恐慌。这是刻意的成本削减——ISR 路径完全不碰 CPSA。想在 ISR 里做浮点运算？改到任务里做（`CONFIG_FREERTOS_FPU_IN_ISR` 是实验性例外，默认不开）。

---

## 7.10 Vanilla vs ESP-IDF：PendSV 与 Xtensa 软中断的两种哲学

读到这里，已经可以精确对比"教科书 Cortex-M"与"本系列的主场 Xtensa"在切换机制上的全部差异。先看 Vanilla ARM_CM4F 端口（`portable/GCC/ARM_CM4F/portmacro.h` / `port.c`，v10.5.1）的三段核心：

```c
/* ① 触发切换 = pend 一个最低优先级异常 */
#define portYIELD()                                 \
{                                                   \
    portNVIC_INT_CTRL_REG = portNVIC_PENDSVSET_BIT; /* 写 ICSR 0xE000ED04 的 bit28 */ \
    __asm volatile ( "dsb" ::: "memory" );          \
    __asm volatile ( "isb" );                       \
}
```

```text
② PendSV 服务程序（xPortPendSVHandler，naked 函数）
    mrs   r0, psp                  ; 取任务栈指针（硬件已把 R0-R3,R12,LR,PC,xPSR 压栈）
    …vstmdbeq r0!, {s16-s31}…      ; FPU 任务才补存浮点高半区（惰性压栈协议）
    stmdb r0!, {r4-r11, r14}       ; 软件补存 callee-saved
    str   r0, [r2]                 ; SP 存入 *pxCurrentTCB
    …msr basepri…bl vTaskSwitchContext…  ; 屏蔽中断调内核选任务
    ldr   r0, [r1]                 ; 新任务栈顶
    ldmia r0!, {r4-r11, r14}       ; 恢复
    msr   psp, r0
    bx    r14                      ; 异常返回，硬件自动出栈 {R0-R3,R12,LR,PC,xPSR}
```

```text
③ 启动首任务（prvPortStartFirstTask）：复位 MSP → svc 0 → vPortSVCHandler 恢复首任务
```

| 维度          | Vanilla ARM Cortex-M（PendSV）                              | IDF Xtensa（软中断 + int_exit）                                 |
| ------------- | ----------------------------------------------------------- | --------------------------------------------------------------- |
| "pend" 的载体 | 硬件位：NVIC ICSR 的 PENDSVSET                              | 软件变量：`port_switch_flag[core]`                              |
| 切换执行者    | PendSV 异常处理程序（NVIC 保证最低优先级、最后执行）        | `_frxt_int_exit`（最外层中断退出时检查 flag）                   |
| 硬件自动保存  | {R0-R3, R12, LR, PC, xPSR} 自动压栈                         | **零自动保存**——向量入口逐条指令手工存                          |
| 软件补存      | R4-R11（+惰性 FPU s16-s31）                                 | 窗口溢出（调用深度相关）+ SAR/循环寄存器等                      |
| 保存成本      | 常数（16~32 字 + 硬件 8 字）                                | 与窗口深度成正比，浅调用链更便宜                                |
| ISR 内触发    | `portYIELD_FROM_ISR(x)` 与任务态同一个宏（pend 天然可延迟） | 独立宏：`_frxt_setup_switch` 置 flag，语义显式延迟到 int_exit   |
| 首任务启动    | `svc 0` → SVCall handler 恢复                               | `call0 _frxt_dispatch` 从启动上下文直接派发                     |
| 中断栈        | MSP 共用一根主栈（任务用 PSP）                              | 每核独立 `port_IntStack`，任务栈只留一帧余量                    |
| 跨核让出      | 不存在（单核）                                              | `portYIELD_CORE(x)` → CPU-from-CPU 软中断 → 对端 ISR → 延迟切换 |
| 切换函数形态  | naked C 函数包内联汇编                                      | 独立 `.S` 汇编文件（`portasm.S`）                               |

为什么 Xtensa 不需要 PendSV？因为 Cortex-M 的 PendSV 本质是在回答"如何让切换在所有中断的**最后**发生"——NVIC 用一个专用最低优先级异常硬件地回答了它；Xtensa 没有这件外设，端口作者就把答案写进软件：**谁最后退出中断，谁负责消费 `port_switch_flag`**。殊途同归，这也再次印证 7.1 的分界：内核逻辑（`vTaskSwitchContext`）两边几乎逐字相同，差异全部沉在端口层。

---

## 7.11 实验：用 QEMU+GDB 踩住切换点

理论读完了，现在把断点钉在 `_frxt_dispatch` 上亲眼看看。全流程无需硬件。

### 1. 准备一个"切换密集"的工程

在第一章工程基础上，把 `main/freertos-ch1.c` 换成同时制造三条路径的最小程序：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static void coop_task(void *arg)            /* 路径①：主动让出 */
{
    for (;;) {
        printf("[%s] yielding on core %d\n", pcTaskGetName(NULL), xPortGetCoreID());
        taskYIELD();
    }
}

static void sleeper_task(void *arg)         /* 路径②③：阻塞让出 + tick 唤醒抢占 */
{
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(200));
        printf("[sleeper] woke up\n");
    }
}

void app_main(void)
{
    /* 两个同优先级协作任务都钉在 Core 0：taskYIELD() 在两者间严格交替（路径①） */
    xTaskCreatePinnedToCore(coop_task, "coop_a", 2048, NULL, 3, NULL, 0);
    xTaskCreatePinnedToCore(coop_task, "coop_b", 2048, NULL, 3, NULL, 0);
    /* 不钉核的睡眠者：优先级最高，每 200ms 阻塞一次、再被 tick 唤醒抢占（路径②③） */
    xTaskCreate(sleeper_task, "sleeper", 2048, NULL, 4, NULL);
}
```

`coop_a`/`coop_b` 同优先级且钉在 Core 0，`taskYIELD()` 会在两者间严格交替——路径①的完美样本；`sleeper` 优先级更高但每 200ms 阻塞一次，每次阻塞是路径②、每次被 tick 唤醒抢走 CPU 是路径③。注意 `coop_*` 若不钉核，SMP 调度器可能把它们分到两个核上各自空转，`taskYIELD()` 的交替现象反而看不见——钉核正是为了让实验确定可复现（亲和对调度的影响见[[ch22-smp-refactor-overview|第22章]]）。

### 2. 起 GDB，断在汇合点

```bash
idf.py qemu gdb     # 编译 + QEMU(带 GDB server) + 自动起 xtensa-esp32-elf-gdb
```

GDB 里依次下断点（均在本文拆过的链路上）：

```text
(gdb) break vPortYield          # 路径①的汇编入口
(gdb) break _frxt_setup_switch  # 路径②③的"登记延迟切换"
(gdb) break _frxt_dispatch      # 三条路径的汇合点
(gdb) break _frxt_int_exit      # 延迟切换的兑现处
(gdb) continue
```

### 3. 在 `_frxt_dispatch` 上读出"谁切给了谁"

每次停在汇合点，看三样东西——哪个核在切、新 TCB 是谁、栈换到了哪里：

```text
(gdb) p/x pxCurrentTCBs[0]                # 连续两次停顿对比：哪个下标变了，
(gdb) p/x pxCurrentTCBs[1]                #   切换就发生在哪个核
(gdb) p ((tskTCB *)pxCurrentTCBs[0])->pcTaskName   # tskTCB 是 TCB_t 的 typedef 名
(gdb) p ((tskTCB *)pxCurrentTCBs[1])->pcTaskName
(gdb) p/x $sp                             # 停在函数开头时是【旧任务】的栈；
(gdb) si                                  #   逐条单步，走过 l32i sp, a3, TOPOFSTACK_OFFS
(gdb) si                                  #   （换栈指令）之后，$sp 变成【新任务】的栈
(gdb) info registers sp
```

如果 `tskTCB` 类型在你的构建里不可见（裁剪/优化导致 DWARF 缺失），退一步直接看内存：`pxCurrentTCBs` 数组元素即 TCB 指针，任务名在 TCB 内偏移处，用 `x/s` 试探即可。

### 4. 验证三条路径的判定性现象

- **路径①**：断点 `vPortYield` 命中且 `port_interruptNesting[0]`、`[1]` 均为 0（不在任何 ISR 里）；`bt` 的上一帧就是 `coop_task`——`vPortYield` 是独立汇编函数，中间没有别的帧。
- **路径②**：`_frxt_setup_switch` 命中且 `bt` 里能看到 `esp_crosscore_isr` → 说明这次延迟切换来自核间/自核 yield 中断，不是 tick。
- **路径③**：`_frxt_setup_switch` 命中且 `bt` 显示 `_frxt_timer_int` → `xPortSysTickHandler` →（core 0 上）`xTaskIncrementTick` 返回真。配合 `p xTickCount` 每次停顿 +1，可直接确认 10ms 一次的节拍（默认 `configTICK_RATE_HZ = 100`）。
- **延迟切换语义**：在 `_frxt_setup_switch` 命中后立刻 `p port_switch_flag`（应为 1），`finish` 跳出后它仍是 1——切换此刻尚未发生；直到 `_frxt_int_exit` 断点命中、单步越过清零指令，`_frxt_dispatch` 才随之而来。

### 5. 真机对照

烧到真实 ESP32 上，符号与断点完全一致，只是调试通道换成 JTAG：

```bash
idf.py -p /dev/ttyUSB0 flash monitor    # 串口观察行为一致
idf.py gdb                              # 经 OpenOCD 连真机，断点用法同上
```

QEMU 里看不到的只有真实中断延迟与时序抖动（例如 CCOMPARE 补拍循环的触发频率），逻辑层面两边无差别。更多调试技巧（trace、任务快照、常见翻车案例）在[[ch24-debugging-tracing-pitfalls|第24章]]系统展开。

---

## 7.12 小结

- 上下文切换的内核本质只有三步：存旧 SP 进 TCB、调 `vTaskSwitchContext()` 选新 TCB、装新 SP。其余汇编都在处理"如何安全地做到这三步"。
- 三条触发路径：**主动让出**（`taskYIELD()` → `vPortYield()` 直达汇编）、**阻塞让出**（`vTaskDelay()` 类 API → `portYIELD_WITHIN_API()` → 给自己发核间软中断，规避持锁切换）、**tick 抢占**（CCOMPARE 中断 → 核 0 全责的 `xTaskIncrementTick()` / 核 1 只查时间片的 `xTaskIncrementTickOtherCores()` → `portYIELD_FROM_ISR()`）。
- `vTaskSwitchContext()` 是纯 C 的"选任务"函数：拿 `xKernelLock` 自旋锁、记账、调 `prvSelectHighestPriorityTaskSMP()`——按优先级下探、跳过"他核在跑"与"亲和不符"的任务、选中挪尾（Best-Effort RR 的出处）。
- Xtensa 汇编链路：`vPortYield` 构造 solicited 帧（窗口溢出代替逐寄存器保存）；中断路径在中断帧 + 每核系统栈上工作；`_frxt_int_exit` 在最外层中断退出时消费 `port_switch_flag`，经 `vPortYieldFromInt` 到达唯一汇合点 `_frxt_dispatch`，由它按帧首 `XT_STK_EXIT` 区分恢复方式。
- 首次调度没有魔法：`xPortStartScheduler()` 以 `call0 _frxt_dispatch` 复用派发器，而每个任务的"出生帧"被 `pxPortInitialiseStack()` 伪装成"恰好在第一行指令前被打断"的中断帧。
- 现场分四层保存：寄存器窗口（栈，惰性溢出）、PS/SAR 等特殊寄存器（帧内槽位）、协处理器（栈顶 CPSA，所有权惰性迁移，FPU 任务会被钉核）、内核记账（TCB）。
- 与 Vanilla Cortex-M 的对照：PendSV 用硬件最低优先级异常回答"切换最后发生"，Xtensa 用 `port_switch_flag` + `_frxt_int_exit` 在软件里回答同一问题；硬件自动压栈 vs 手工保存、常数成本 vs 窗口深度相关成本，是两种哲学的分野。

下一章把镜头对准调度器的"价值观"：优先级如何比较、时间片如何切割、Round-Robin 在单核的完美实现与 IDF 双核的 Best-Effort 退化各自长什么样——我们将量化"轮转不均"到底能差多少，以及哪些配置能把风险关进笼子。
