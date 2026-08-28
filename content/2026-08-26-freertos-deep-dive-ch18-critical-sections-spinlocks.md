---
title: "FreeRTOS 深度解析（十八）：临界区实现——关中断、spinlock 与双核总线锁"
date: 2026-08-26
description: "临界区是内核正确性的地基：先看 Vanilla 用关中断实现互斥的单核世界观，再看 SMP 下关中断为何失效、IDF FreeRTOS 如何用 S32C1I 原子指令 + 自旋锁重建互斥，最后实测双核同抢一个计数器的竞态与修复。"
tags: [freertos, rtos, esp32, esp-idf, xtensa, smp, spinlock, critical-section]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 18. **第十八章：临界区实现——关中断、spinlock 与双核总线锁**

# FreeRTOS 深度解析（十八）：临界区实现——关中断、spinlock 与双核总线锁

这一章回答一个问题：**FreeRTOS 凭什么保证"同一时刻只有一个执行流在碰内核数据"**。前几章里它一直以 `taskENTER_CRITICAL()` 的名字反复出场——第 6 章的就绪链表、第 10 章的队列、第 11 章的信号量，所有内核对象的操作都被它包裹。现在把这个宏拆开：Vanilla 里它是"关中断"三个字，简洁到近乎天真；IDF FreeRTOS 里它变成"关中断 + 抢自旋锁"的复合动作，背后是 Xtensa 的 `S32C1I` 原子指令、总线级仲裁和核间中断。理解了这一章，[[2026-08-26-freertos-deep-dive-ch17-xtensa-port-internals|第17章]]的端口层拼图就完整了，[[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|第22章]]的 SMP 改造叙事也有了地基。

---

## 18.1 临界区到底要防谁

先把"敌人"数清楚。一个共享数据结构（比如就绪链表）可能被谁同时访问？

### 1. 单核世界观：两类竞争者

在单核 MCU 上，"同时"只有一种产生方式——**中断打断任务**：

```text
任务 A：读 uxTopReadyPriority ──┐ 被中断打断
                                │  ISR：改了就绪链表
任务 A：          ──────────────┘ 拿到的是旧值 → 链表损坏
```

任务与任务之间**不存在**这种竞争：上下文切换只能发生在指令边界上，切换时寄存器被完整保存恢复，一个"读-改-写"序列跨切换点执行，中间不会有另一个任务插进来。所以在单核 FreeRTOS 里，一段只被任务访问的 `counter++` 其实是安全的，不需要任何保护——这个结论很重要，后面实验会用到它的反面。

于是单核临界区只需要防住一件事：**本核中断**。防法只有一个——关中断。

### 2. 双核世界：竞争者翻倍

ESP32 是双核 SMP，两个核共享同一份内核数据。竞争矩阵变成：

| 竞争组合               | 单核是否存在         | 双核是否存在 | 防御手段          |
| ---------------------- | -------------------- | ------------ | ----------------- |
| 同核：任务 vs 任务     | 否（切换在指令边界） | 否（同理）   | 不需要            |
| 同核：任务 vs 中断     | **是**               | **是**       | 关本核中断        |
| **异核：任务 vs 任务** | 不存在               | **是**       | **原子指令 + 锁** |
| **异核：任务 vs 中断** | 不存在               | **是**       | **原子指令 + 锁** |

后两行是 SMP 带来的全新问题。注意关键的不对称：**关中断是"每核各自"的开关**——核 A 把自己的中断关了，核 B 的中断照样开着，核 B 的代码照样在跑。一个只作用于本核的机制，天生管不住另一个核。

### 3. 内核自己是最大的临界区用户

这不是学术问题。第 6 章看过，调度器的全部状态就是几张链表 + 一个位图；第 10 章的队列、第 12 章的事件组，数据结构全是链表。链表插入是标准的"改两个指针、再改两个 prev/next"多步操作，任何一步被插一只手进来，链表就断了。临界区是内核正确性的承重墙——它在 SMP 上失效，等于整个内核失效。

---

## 18.2 三层 API：从 taskENTER_CRITICAL 到一条汇编指令

FreeRTOS 的临界区 API 是三层嵌套的宏，每一层做一次转发。以 IDF FreeRTOS（默认编入的 `FreeRTOS-Kernel/` 树，Xtensa 端口）为准，自上而下：

| 层         | API                                                    | 定义处           | 落到哪                                                                           |
| ---------- | ------------------------------------------------------ | ---------------- | -------------------------------------------------------------------------------- |
| 应用层包装 | `taskENTER_CRITICAL(&mux)` / `taskEXIT_CRITICAL(&mux)` | `task.h`         | `portENTER_CRITICAL(mux)`                                                        |
| 端口层     | `portENTER_CRITICAL(mux)`                              | `portmacro.h`    | `vPortEnterCritical(mux)` → `xPortEnterCriticalTimeout(mux, portMUX_NO_TIMEOUT)` |
| 实现       | `xPortEnterCriticalTimeout()` / `vPortExitCritical()`  | `port.c`（IRAM） | 抬 INTLEVEL + `spinlock_acquire()` + 嵌套计数                                    |

### 1. taskENTER_CRITICAL：任务上下文的标准入口

```c
/* IDF FreeRTOS 的 task.h —— 注意参数 */
#define taskENTER_CRITICAL( x )            portENTER_CRITICAL( x )
#define taskEXIT_CRITICAL( x )             portEXIT_CRITICAL( x )
```

用法是内核和驱动代码里最常见的形状：先声明一个锁，进临界区时把它的地址交出去：

```c
static portMUX_TYPE my_lock = portMUX_INITIALIZER_UNLOCKED;

portENTER_CRITICAL(&my_lock);
/* ... 独占访问共享数据 ... */
portEXIT_CRITICAL(&my_lock);
```

`portMUX_TYPE` 在 IDF 的 Xtensa 端口里就是 `spinlock_t`（`portmacro.h` 里一行 `typedef spinlock_t portMUX_TYPE;`）。**临界区必须指定保护哪个锁**——这是和 Vanilla 最大的 API 差异，18.5 节展开。

### 2. portSET_INTERRUPT_MASK_FROM_ISR：中断版的"裸关中断"

```c
/* IDF FreeRTOS 的 task.h —— FromISR 版本不拿锁！ */
#define taskENTER_CRITICAL_FROM_ISR()      portSET_INTERRUPT_MASK_FROM_ISR()
#define taskEXIT_CRITICAL_FROM_ISR( x )    portCLEAR_INTERRUPT_MASK_FROM_ISR( x )
```

它落到 `portmacro.h` 的 `xPortSetInterruptMaskFromISR()`：

```c
static inline UBaseType_t xPortSetInterruptMaskFromISR(void)
{
    UBaseType_t prev_int_level = XTOS_SET_INTLEVEL(XCHAL_EXCM_LEVEL);
    portbenchmarkINTERRUPT_DISABLE();
    return prev_int_level;
}
```

`XTOS_SET_INTLEVEL(XCHAL_EXCM_LEVEL)` 把 PS 寄存器的 INTLEVEL 字段抬到异常屏蔽级（ESP32 的 LX6 上 `XCHAL_EXCM_LEVEL` 为 3），并**返回旧值**。这族 API 只做一件事：关本核中断、记住之前的状态。它**不拿任何锁**，因此只适合保护"本核私有"或"不会被跨核访问"的数据，典型场景是 ISR 里保护一段不希望被更高优先级中断打断的时序。返回值要在退出时原样传回，恢复到进入前的中断级别（而不是无脑开中断——ISR 可能在嵌套中）。

### 3. portENTER_CRITICAL_SAFE 与 ISR 通用的秘密

IDF 还提供一组 `_SAFE` 和 `_ISR` 变体（`portmacro.h`）：

```c
#define portENTER_CRITICAL_ISR(mux)     vPortEnterCritical(mux)   /* 与任务版同一个函数 */
#define portEXIT_CRITICAL_ISR(mux)      vPortExitCritical(mux)

static inline void vPortEnterCriticalSafe(portMUX_TYPE *mux)      /* 运行时判断上下文 */
{
    xPortInIsrContext() ? portENTER_CRITICAL_ISR(mux) : portENTER_CRITICAL(mux);
}
```

注意 `portENTER_CRITICAL_ISR` 和任务版**是同一个函数**。也就是说在 IDF 里，`portENTER_CRITICAL(&mux)` 在任务和中断上下文里都能用——`portmacro.h` 的注释专门强调这是**非标准 FreeRTOS 行为**。原因很直接：这个临界区既然靠自旋锁互斥，它天然不依赖"从任务还是中断进来"；本核中断一关，谁来都一样排队。Vanilla 里任务版和 ISR 版是严格分开的（任务版在 ISR 里调用会触发 assert）。写跨上下文代码（回调既可能从任务也可能从 ISR 调进来）时用 `_SAFE` 版本。

> [!tip] Vanilla vs ESP-IDF：临界区 API 形状
>
> | 主题               | Vanilla FreeRTOS v10.5.1                     | IDF FreeRTOS（v6.0.2 默认树）            |
> | ------------------ | -------------------------------------------- | ---------------------------------------- |
> | 任务版签名         | `taskENTER_CRITICAL()` 无参数                | `taskENTER_CRITICAL(&mux)` 必须传锁      |
> | ISR 版语义         | `portSET_INTERRUPT_MASK_FROM_ISR()` 只关中断 | 同名宏仍然只关中断（不拿锁）             |
> | 任务版能否用于 ISR | 否，assert 拦截                              | `portENTER_CRITICAL(mux)` 两用（非标准） |
> | 跨上下文保险       | 无                                           | `portENTER_CRITICAL_SAFE()` 按上下文分发 |
>
> 从 Vanilla 代码迁移到 ESP-IDF 时，`taskENTER_CRITICAL()` 少了参数会直接编译错误——这是好事，逼你回答"这段临界区保护哪个锁"。

---

## 18.3 Vanilla 的答案：关中断即独占

现在看 Vanilla 这边怎么实现。Xtensa 端口的 `portmacro.h`（`portable/ThirdParty/XCC/Xtensa/`，IDF fork 的祖先）里：

```c
/* Vanilla Xtensa 端口：这些可以嵌套 */
#define portCRITICAL_NESTING_IN_TCB 1    /* 嵌套计数放在 TCB 里 */
void vTaskEnterCritical(void);
void vTaskExitCritical(void);
#define portENTER_CRITICAL()        vTaskEnterCritical()
#define portEXIT_CRITICAL()         vTaskExitCritical()

/* ISR 版：抬 INTLEVEL 并返回旧值 */
static inline unsigned portENTER_CRITICAL_NESTED() {
    unsigned state = XTOS_SET_INTLEVEL(XCHAL_EXCM_LEVEL);
    portbenchmarkINTERRUPT_DISABLE();
    return state;
}
#define portSET_INTERRUPT_MASK_FROM_ISR()        portENTER_CRITICAL_NESTED()
```

`vTaskEnterCritical()` / `vTaskExitCritical()` 定义在 Vanilla `tasks.c` 里，实现短得可以背下来：

```c
/* Vanilla tasks.c —— 去掉测试标记后的主干 */
void vTaskEnterCritical( void )
{
    portDISABLE_INTERRUPTS();                    /* 抬 INTLEVEL 到 EXCM */
    if( xSchedulerRunning != pdFALSE )
    {
        ( pxCurrentTCB->uxCriticalNesting )++;   /* 嵌套计数 +1 */
        if( pxCurrentTCB->uxCriticalNesting == 1 )
        {
            portASSERT_IF_IN_ISR();              /* ISR 里调用 = bug */
        }
    }
}

void vTaskExitCritical( void )
{
    if( pxCurrentTCB->uxCriticalNesting > 0U )
    {
        ( pxCurrentTCB->uxCriticalNesting )--;
        if( pxCurrentTCB->uxCriticalNesting == 0U )
        {
            portENABLE_INTERRUPTS();             /* 最外层退出才开中断 */
        }
    }
}
```

三个要点：

1. **互斥完全靠 `portDISABLE_INTERRUPTS()`**，即写 PS 寄存器把 INTLEVEL 抬到 3。此后本核不再响应一般中断，tick 停摆、抢占停摆、调度停摆——直到退出。单核上"调度只在中断里发生"，所以关中断等于冻结了整个系统的并发。
2. **嵌套计数放在 TCB 里**（`portCRITICAL_NESTING_IN_TCB = 1`）。临界区可以嵌套：内层退出只减计数，最外层退出才真正开中断。计数跟着任务走，任务切换时自然带着走。
3. **任务版与 ISR 版严格分离**。`vTaskEnterCritical` 里那行 `portASSERT_IF_IN_ISR()` 说明设计上就不允许从 ISR 调用——ISR 想保护数据用 `portSET_INTERRUPT_MASK_FROM_ISR`。

这套设计在单核上是完备的：**关中断即独占**，因为唯一的 CPU 已经在你手里，没有任何人能在你之前碰共享数据。它简洁、零内存开销（一个 TCB 字段）、延迟可控（临界区长度就是中断延迟上界）。问题只在一个地方——它假设了"只有一个 CPU"。

---

## 18.4 SMP 的根本难题：核 A 关中断，核 B 照样进来

把上面的代码原封不动搬到双核上，灾难立刻发生：

```text
   时刻   Core 0                                Core 1
   ──── ────────────────────────────────────── ──────────────────────────
    t1   taskENTER_CRITICAL()
         INTLEVEL ← 3（本核中断关）
         开始改就绪链表 ...
    t2                                          taskENTER_CRITICAL()
                                               INTLEVEL ← 3（关的是 Core 1 自己的中断）
                                               Core 0 的中断状态？与它无关！
                                               开始改同一条就绪链表 ── 💥
    t3   链表已被两头改坏
```

`portDISABLE_INTERRUPTS()` 操作的是**每个核各自的 PS 寄存器**。它是一个"本核视角"的机制：核 0 关掉自己的中断，对核 1 的执行流没有任何约束力——核 1 既不被核 0 的中断状态影响，也不感知核 0 正在临界区里。**关中断不再是互斥**，它退化成了"防止本核中断插队"的局部保护。

要在双核上重建互斥，需要一个**双方都承认的仲裁者**：两个核同时伸手抢同一个东西时，硬件必须裁定谁先谁后，且裁定结果对两核可见。这个仲裁者在 ESP32 上由两样东西组成：

1. **一条原子指令**：Xtensa 的 `S32C1I`（Store Conditional），它对内存的一个字做"比较并交换"，原子性由总线仲裁保证——两个核同时执行它，总线硬件把它们串行化，一先一后，没有平局；
2. **一个基于它的锁协议**：自旋锁（spinlock）——抢不到的核在原地反复尝试（自旋），直到持有者释放。

这正好是操作系统的经典课题："如何在共享内存的多处理器上从无到有构造互斥"。IDF 的实现小而完整，下一节逐行走读。

---

## 18.5 IDF 的答案：自旋锁 + 关中断，逐行走读

### 1. 顶层：xPortEnterCriticalTimeout

IDF Xtensa 端口 `port.c`（注意它被链接脚本钉在 IRAM 里，18.9 节）里的实现：

```c
BaseType_t xPortEnterCriticalTimeout(portMUX_TYPE *mux, BaseType_t timeout)
{
    BaseType_t xOldInterruptLevel = portSET_INTERRUPT_MASK_FROM_ISR();  /* ① */
    if (!spinlock_acquire(mux, timeout)) {                              /* ② */
        portCLEAR_INTERRUPT_MASK_FROM_ISR(xOldInterruptLevel);          /* 超时：还原 */
        return pdFAIL;
    }
    BaseType_t coreID = xPortGetCoreID();
    BaseType_t newNesting = port_uxCriticalNesting[coreID] + 1;         /* ③ */
    port_uxCriticalNesting[coreID] = newNesting;
    if ( newNesting == 1 ) {                                            /* ④ */
        port_uxOldInterruptState[coreID] = xOldInterruptLevel;
    }
    return pdPASS;
}
```

对照 Vanilla，结构上多了"②抢锁"，记账上从 TCB 挪到了**每核数组**（`port_uxCriticalNesting[portNUM_PROCESSORS]`、`port_uxOldInterruptState[portNUM_PROCESSORS]`，都在 `port.c` 顶部定义；`portmacro.h` 里 `portCRITICAL_NESTING_IN_TCB` 为 0）。为什么不能放 TCB？因为 SMP 临界区的"持有者"是**核**不是任务：任务可以在退出临界区前被换出（只要锁还握在手里），嵌套计数必须挂在核上才不会跟丢。

退出侧 `vPortExitCritical(mux)` 是镜像：先 `spinlock_release(mux)`，再减嵌套计数，减到 0 时用 `port_uxOldInterruptState[coreID]` 恢复进入前的中断级别。

### 2. 锁的本体：spinlock_t

锁住在 `esp_hw_support/include/spinlock.h`（FreeRTOS 之外的 IDF 基础设施，端口层直接复用）：

```c
#define SPINLOCK_FREE          0xB33FFFFF      /* 空闲态的魔数（"b33f..."） */
#define SPINLOCK_WAIT_FOREVER  (-1)            /* 对应 portMUX_NO_TIMEOUT */
#define SPINLOCK_NO_WAIT        0              /* 对应 portMUX_TRY_LOCK */

typedef struct {
    volatile uint32_t owner;    /* 谁持有：0xCDCD=Core0，0xABAB=Core1，FREE=空闲 */
    volatile uint32_t count;    /* 同核递归获取的计数 */
} spinlock_t;
```

`owner` 的两个核标识 `0xCDCD` / `0xABAB` 故意不用 0 和 1——0 是内存初始值，用它会分不清"没人持有"和"Core 0 持有"。这两个值与 ESP32 DPORT 寄存器里读出的核 ID 编码一致，所以 `spinlock_acquire` 直接拿 `xt_utils_get_raw_core_id()`（读 PRID 寄存器）的原始值当锁标识，一次比较就完成"是不是我自己持有"的判断。

### 3. 原子性的最底层：S32C1I

`spinlock_acquire` 的抢锁动作最终落在 `xt_utils.h` 的 `xt_utils_compare_and_set()`：

```c
/* components/xtensa/include/xt_utils.h —— 两条指令的 CAS */
FORCE_INLINE_ATTR bool xt_utils_compare_and_set(volatile uint32_t *addr,
                                                uint32_t compare_value,
                                                uint32_t new_value)
{
    uint32_t old_value = new_value;
    __asm__ __volatile__ (
        "WSR    %2, SCOMPARE1 \n"     /* 把期望值放进 SCOMPARE1 特殊寄存器 */
        "S32C1I %0, %1, 0 \n"         /* 条件存储：*addr == SCOMPARE1 才写入 new_value，
                                          返回值 %0 = 内存里的旧值 */
        :"=r"(old_value)
        :"r"(addr), "r"(compare_value), "0"(old_value)
    );
    return (old_value == compare_value);  /* 旧值==期望值 → 我们抢到了 */
}
```

这就是 Xtensa 版的 compare-and-swap：先把"期望值"写进特殊寄存器 `SCOMPARE1`，再执行 `S32C1I`——它原子地完成"读内存、与 SCOMPARE1 比较、相等则写入新值、把旧值送回寄存器"。**当两个核同时对同一地址执行 `S32C1I`，总线仲裁硬件把两次访问串行化**：一先一后，后到者看到的内存已经变了、比较失败、写入不发生。没有平局，没有窗口。这就是本章标题里"总线锁"的实体——`S32C1I` 在执行期间对目标地址的排他性由内存总线保证，对两个核一视同仁。

一个重要的边界条件（`esp_hw_support/cpu.c` 里 `esp_cpu_compare_and_set()` 的实现专门处理）：**`S32C1I` 对外部 PSRAM 地址不可靠**。该函数先判断目标地址是否落在 SPIRAM 区间，是则退化成"关中断 + 一把位于内部 RAM 的全局 CAS 锁"来模拟原子性。结论对写代码的直接指导：**`portMUX_TYPE` 对象永远不要放进 PSRAM**。

### 4. spinlock_acquire 全流程

把上面拼起来，`spinlock_acquire(lock, timeout)` 的完整逻辑：

```text
spinlock_acquire(lock, timeout)
│
├─ 保存当前 INTLEVEL，抬到 EXCM（本核中断关）
├─ 若 lock->owner == 本核 ID            ── 递归获取：count++，直接返回成功
├─ 首次尝试：CAS(&lock->owner, FREE → 本核 ID)
│    └─ 成功（或 timeout==NO_WAIT）→ 跳到收尾
├─ 自旋循环：记录起始 cycle（CCOUNT）
│    循环 { CAS 重试；成功则跳出 }
│    直到成功，或 (当前cycle - 起始cycle) > timeout
│    （timeout == SPINLOCK_WAIT_FOREVER(-1) 则无限等）
└─ 收尾：成功 → count = 1；失败（超时）→ 返回 false
   恢复进入时的 INTLEVEL
```

三个值得停留的细节：

1. **快速路径极短**。锁空闲时（绝大多数情况），整个获取就是"一次 CAS 成功"，自旋循环根本不进入。源码注释明说：把首次尝试单独放在循环外，就是为了省掉记 cycle 的开销。
2. **自旋期间本核中断是关的**。注意调用链：`xPortEnterCriticalTimeout` 先抬了 INTLEVEL，`spinlock_acquire` 进入时再保存一次（保存的是"已关"状态）、离开时恢复到"已关"状态。于是等待锁的整个自旋过程中，等待核的中断一直关着。这换来了正确性（自旋中不会被本核中断打断造成递归加锁），代价是中断延迟（18.9 节）。
3. **默认永远等**。内核用的 `portMUX_NO_TIMEOUT` 就是 `SPINLOCK_WAIT_FOREVER`。带超时的 `portTRY_ENTER_CRITICAL(mux, timeout)` 存在，timeout 单位是 CPU cycle，供不想无限等的场合使用。

### 5. 单核关中断 vs SMP 自旋锁：机制对照图

```text
     单核 Vanilla：关中断即互斥               双核 IDF：关中断 + 自旋锁
  ┌──────────────────────────────┐   ┌──────────────────────────────────────┐
  │ Core 0（唯一的核）            │   │ Core 0                     Core 1    │
  │                              │   │                                      │
  │ taskENTER_CRITICAL()         │   │ taskENTER_CRITICAL(&mux)  taskENTER_ │
  │  ├ INTLEVEL ← 3（关本核中断）│   │  ├ INTLEVEL ← 3(关本核)   _CRITICAL( │
  │  └ TCB.uxCriticalNesting++   │   │  └ S32C1I 抢 mux.owner      &mux)    │
  │                              │   │     ├ 抢到 → owner=Core0    │        │
  │  访问共享数据                 │   │     └ 没抢到 → 自旋重试 ←───┼─ 两核  │
  │  （唯一 CPU，无人能打扰）      │   │       （期间本核中断仍关）   │  抢同  │
  │                              │   │  nesting[core]++           │  一把锁 │
  │ taskEXIT_CRITICAL()          │   │                            │        │
  │  └ nesting--；0 → 开中断      │   │ taskEXIT_CRITICAL(&mux)    │        │
  │                              │   │  └ owner ← FREE；nesting--  │        │
  └──────────────────────────────┘   │    （另一核的下次 CAS 将成功）        │
                                     └──────────────────────────────────────┘
  互斥来源：CPU 只有一个               互斥来源：S32C1I 的总线级原子仲裁
  中断延迟：= 本核临界区长度           中断延迟：= 本核临界区 + 可能的自旋等待
  嵌套计数：TCB 内                    嵌套计数：port.c 的每核数组
```

> [!note] 为什么还要关中断？
> 有了自旋锁，为什么 SMP 临界区不省掉关中断？两个原因：其一，**本核中断仍会插队**——锁只挡别的核，挡不住自己的 ISR；若 ISR 里也碰这个锁，就会递归获取，语义混乱甚至死锁。其二，**同核上的任务/中断竞争依旧存在**（18.1 节矩阵的第二行）。所以正确配方是两层：关本核中断（管住自己人）+ 自旋锁（管住对面）。

---

## 18.6 内核里的锁地图：从一把大锁到细粒度锁

IDF 对内核源码做 SMP 改造时（官方变更说明 `FreeRTOS-Kernel/idf_changes.md` 的 "Critical Section Changes" 一节），把临界区按保护对象拆成了**细粒度的多把锁**：

| 锁                                 | 保护什么                                    | 所在文件          |
| ---------------------------------- | ------------------------------------------- | ----------------- |
| `xKernelLock`                      | 调度器全局状态（就绪链表、延时表、tick 等） | `tasks.c`         |
| 每个队列一把 `xQueueLock`          | 单个队列/信号量/互斥量的内部状态            | `queue.c`         |
| `xQueueRegistryLock`               | 队列注册表                                  | `queue.c`         |
| 每个事件组一把 `xEventGroupLock`   | 单个事件组的位图与等待链表                  | `event_groups.c`  |
| 每个流缓冲一把 `xStreamBufferLock` | 单个 stream/message buffer                  | `stream_buffer.c` |
| `xTimerLock`                       | 软件定时器队列与状态                        | `timers.c`        |

为什么拆？**两个不相关的队列操作不应该互相等待**。如果全内核共用一把锁，核 0 上 WiFi 任务往队列传数据、核 1 上应用任务只是读个 tick，后者也得自旋等前者——把双核并行度活活锁回串行。细粒度锁让争用只发生在真正共享同一对象的执行流之间。代价是复杂度：哪些路径需要加锁、按什么顺序加锁，都要逐个重新论证——`idf_changes.md` 里专门提到补齐了一批 Vanilla 单核下不需要、SMP 下必须新增的临界区（源码里以 `..._SMP_ONLY()` 标注）。

一个容易忽略的 SMP 化样本是 `vTaskSuspendAll()`。Vanilla 版（18.3 节引文）就是一个光秃秃的自增——单核上关中断都不用（`BaseType_t` 自增在指令边界天然安全）。IDF 版必须先拿 `xKernelLock`：

```c
/* IDF tasks.c 的 vTaskSuspendAll() 主干 */
prvENTER_CRITICAL_SMP_ONLY( &xKernelLock );     /* SMP 下必须进临界区 */
{
    ++uxSchedulerSuspended[ portGET_CORE_ID() ]; /* 挂起计数是每核一个 */
    portMEMORY_BARRIER();
}
prvEXIT_CRITICAL_SMP_ONLY( &xKernelLock );
```

两层变化：计数从全局变量变成**每核数组**（"挂起调度器"是核本地概念，核 0 挂起不影响核 1 继续调度）；自增本身被锁保护（否则两个核同时 `++` 就是 18.10 节要实测的那种竞态）。应用层调用 `vTaskSuspendAll()`/`xTaskResumeAll()` 的语义也随之改变：**它只挂起当前核的调度**，且 IDF 文档不建议应用代码再用它做互斥——需要互斥请直接用临界区或内核对象。

> [!tip] Vanilla vs ESP-IDF：vTaskSuspendAll 的角色变化
>
> | 主题             | Vanilla FreeRTOS                  | IDF FreeRTOS                               |
> | ---------------- | --------------------------------- | ------------------------------------------ |
> | 实现             | 裸 `++uxSchedulerSuspended`，无锁 | 先取 `xKernelLock` 再自增                  |
> | 计数变量         | 全局一个                          | 每核一个（`uxSchedulerSuspended[coreID]`） |
> | 挂起范围         | 整个系统（只有一个核）            | 仅当前核                                   |
> | 作为应用互斥手段 | 教材里常见用法                    | 不推荐：不挡他核、易死锁                   |
>
> 老代码里"`vTaskSuspendAll()` + 访问共享数据 + `xTaskResumeAll()`"的护体套路，搬到 ESP32 双核上是**失效**的——它护不住另一个核。这是从单核教材迁移代码时最隐蔽的一类坑。

---

## 18.7 portYIELD_CORE：持有锁时，怎么让别的核让路

临界区还差最后一块拼图。设想这个场景：

```text
   Core 0（持有 xKernelLock，正在临界区里）         Core 1（正在跑优先级 2 的任务）
   唤醒了优先级 5 的任务 T
   T 不绑核，两个核都能跑
   Core 0 退出临界区后自己会切到 T 吗？未必然——
   更优的选择是让 Core 1 立刻切到 T，Core 0 继续干手头的事
   但 Core 1 正在跑低优先级任务，对这一切毫不知情……
```

单核上这个问题不存在：唤醒者自己就在调度路径上，退出临界区时顺带切换即可。双核上需要一个**主动通知机制**——`taskYIELD_CORE(xCoreID)`（`tasks.c` 中定义为 `portYIELD_CORE(xCoreID)`），最终落到端口 `port.c` 的 `vPortYieldOtherCore()`：

```c
/* IDF Xtensa port.c */
void vPortYieldOtherCore( BaseType_t coreid )
{
    esp_crosscore_int_send_yield( coreid );     /* 发核间中断 */
}
```

`esp_crosscore_int_send_yield()` 在 `esp_system/crosscore_int.c` 里，机制是 ESP32 的 **from_cpu0 / from_cpu1 软件中断**（两个核各自可以"戳"对方的外设寄存器，触发对方一根中断线）：

```c
/* crosscore_int.c 主干（简化） */
static void esp_crosscore_int_send(int core_id, uint32_t reason_mask)
{
    portENTER_CRITICAL_ISR(&reason_spinlock);   /* reason 位图本身也要锁保护 */
    reason[core_id] |= reason_mask;             /* 写下"为什么要打断你" */
    portEXIT_CRITICAL_ISR(&reason_spinlock);
    crosscore_int_ll_trigger_interrupt(core_id);/* 戳对方核的中断线 */
}

void esp_crosscore_int_send_yield(int core_id)  /* 对外：请求对方切换 */
{
    esp_crosscore_int_send(core_id, REASON_YIELD);
}
```

接收侧的 ISR（同一文件）清掉中断、在 `reason_spinlock` 保护下取走 reason 位图，发现 `REASON_YIELD` 就调用 `portYIELD_FROM_ISR()` 走标准的 ISR 退出切换路径（第 7 章）。位图里还有几个兄弟位：`REASON_FREQ_SWITCH`（DFS 调频）、`REASON_PRINT_BACKTRACE`、`REASON_GDB_CALL`、`REASON_TWDT_ABORT`——同一根中断线被多种核间请求复用，靠位图区分。

`tasks.c` 里新任务就绪、优先级变化时的判断逻辑是它的典型调用点：

```c
/* IDF tasks.c：新就绪任务该让哪个核切换？ */
if ( taskIS_AFFINITY_COMPATIBLE( xCurCoreID, pxTCB ) &&
     uxTaskPriority > pxCurrentTCBs[ xCurCoreID ]->uxPriority ) {
    xYieldRequiredCurrentCore = pdTRUE;        /* 情形一：当前核切 */
} else if ( taskIS_AFFINITY_COMPATIBLE( !xCurCoreID, pxTCB ) &&
            uxTaskPriority > pxCurrentTCBs[ !xCurCoreID ]->uxPriority ) {
    taskYIELD_CORE( !xCurCoreID );             /* 情形二：戳另一个核切 */
}
```

还有一个精妙的自用变体 `portYIELD_WITHIN_API()`：

```c
/* portmacro.h：关着中断时的"延迟 yield" */
#define portYIELD_WITHIN_API() esp_crosscore_int_send_yield(xPortGetCoreID())
```

内核 API 内部经常处于"已关中断"的状态，此时直接 `portYIELD()` 切换是危险的。这个宏**给自己发一根核间中断**：中断在 INTLEVEL 恢复前一直挂起，等临界区退出、中断一开，它立刻触发，切换在安全的时间点完成。同一根 crosscore 中断线，既当"喊别人让路"的喇叭，又当"给自己上闹钟"的定时器。

核间中断与自旋锁的组合在 [[2026-08-26-freertos-deep-dive-ch23-cross-core-synchronization|第23章]]还会展开（包括缓存一致性问题）；本章只需记住结论：**SMP 内核的"请求他核切换"是一条真实的中断路径，有它的成本和时序**。

---

## 18.8 自旋锁下的新风险：死锁、活锁与变了形的优先级反转

互斥重建了，但自旋锁不是免费的午餐。它带来一类单核时代不存在、或形态不同的病症：

### 1. 死锁：嵌套加锁遇上相反顺序

```c
/* 核 0 */                    /* 核 1 */
portENTER_CRITICAL(&a);       portENTER_CRITICAL(&b);
portENTER_CRITICAL(&b);       portENTER_CRITICAL(&a);   /* 💥 */
```

核 0 等 b、核 1 等 a，两个核都在关着中断的状态下无限自旋（`SPINLOCK_WAIT_FOREVER`）。系统没有崩溃日志、没有 panic，只是**安静地停止响应**——两核中断全关，连看门狗的中断都进不来（看门狗最终会以复位收场，[[2026-08-26-freertos-deep-dive-ch24-debugging-tracing-pitfalls|第24章]]的排坑话题）。纪律：需要嵌套持有多把锁时，**全局约定加锁顺序**；应用层尽量避免嵌套 `portENTER_CRITICAL`。

### 2. 优先级反转的自旋形态

第 11 章讲过互斥量的优先级继承。自旋锁**没有也不可能有**优先级继承——持有者正在另一个核上全速执行，等待者除了原地自旋没有任何"催促"手段。于是反转链条变了形：

```text
  Core 0：低优先级任务 L 持有锁，正在临界区里慢慢干活
  Core 1：高优先级任务 H 抢同一个锁 → 自旋 → 关着中断干等
  此刻 Core 1 上任何中断的延迟 = L 的临界区剩余长度
  （如果 L 又被 Core 0 上的中断/更高优先级任务拖延，H 的等待随之延长）
```

单核上的优先级反转至少还能靠继承缓解；自旋形态下唯一的缓解是**把临界区写短**——短到"等一下也无妨"。这也是 IDF 把内核锁拆细（18.6 节）的另一个动机：锁粒度越小，临界区越短。

### 3. 活锁与自旋风暴

`S32C1I` 失败后立刻重试，若多个核高频抢同一把锁，总线上的 CAS 流量互相挤压，可能出现"谁都抢不太到、总功耗和总线带宽先爆"的活锁倾向。两核系统里这更多是性能问题而非活性问题（最终总有人成功），但它解释了两条工程守卫：

- **临界区里绝不做耗时操作**：`printf`、`vTaskDelay`、 Flash 操作、大内存拷贝，一律禁止——18.10 节实验会看到违反的后果；
- **`_SAFE`/`_ISR` 变体虽可用，ISR 里的临界区更要短**：中断上下文自旋时，它背后的整个中断优先级层都被堵住。

---

## 18.9 性能成本：快速路径、中断延迟与 IRAM

### 1. 无争用时很便宜

锁空闲的常态下，`taskENTER_CRITICAL(&mux)` 的成本 ≈ 一次 INTLEVEL 切换（读改写 PS 寄存器）+ 一次成功的 CAS（`WSR SCOMPARE1` + `S32C1I`，两次访存级别的操作）+ 一次计数自增。在 240MHz 的 LX6 上是几十纳秒量级——这就是"细粒度锁 + 短临界区"策略敢在内核高频路径上到处加锁的底气。

### 2. 争用时，账单算在中断延迟上

18.5 节已经指出：**等待者自旋期间，它那个核的中断是全关的**。因此任一核的中断延迟上界从"本核临界区长度"变成了：

```text
中断延迟上界 ≈ 自己所在临界区长度 + 等锁时间（≤ 持锁者临界区长度 + IPI 往返）
```

推论：给硬实时中断预估等待时间时要**假设最坏的持锁者**（另一个核正在临界区里）；不想无限等可用带超时的 `portTRY_ENTER_CRITICAL(mux, timeout_cycles)`，把"永远自旋"换成"等不到就返回 pdFAIL 走降级路径"，代价是要自己处理失败分支。

### 3. IRAM 放置是强制的

`components/freertos/linker.lf` 里对 Xtensa 端口有明确规则——无论是否开启 `CONFIG_FREERTOS_IN_IRAM`，这些函数**永远**放在 IRAM（`noflash_text`）：

```text
port:xPortEnterCriticalTimeout   /* 临界区进入 */
port:vPortExitCritical           /* 临界区退出 */
port:vPortYieldOtherCore         /* 核间 yield */
port:xPortStartScheduler         /* 调度器启动 */
```

原因不难想：临界区代码可能在关中断的状态下执行，而 Flash 访问依赖 cache，cache miss 时的 Flash 读又可能被 cache 一致性机制卡住（其中不乏要拿锁的路径）——让"抢锁的代码"本身需要等锁，就是死锁配方。同理 `port_systick.c` 整个文件常驻 IRAM。另外记住 18.5 节的边界：**锁对象本体绝不能放 PSRAM**（`S32C1I` 对 PSRAM 不可靠，会走"关中断 + 全局 CAS 锁"的慢速模拟路径）。

> [!tip] Vanilla vs ESP-IDF：临界区的性能画像
>
> | 维度           | Vanilla（单核关中断）     | IDF（关中断 + 自旋锁）               |
> | -------------- | ------------------------- | ------------------------------------ |
> | 无争用进入成本 | 一次 PS 写 + TCB 计数自增 | 一次 PS 写 + 一次 CAS + 数组计数自增 |
> | 争用时等待方式 | 不存在（没有"别人"）      | 关中断自旋，等持锁者释放             |
> | 中断延迟上界   | 本核临界区长度            | 本核临界区 + 可能的自旋时长          |
> | 代码放置       | 无特殊要求                | 进出临界区函数强制 IRAM              |
> | 锁对象内存     | 无锁对象                  | 8 字节 `spinlock_t`，必须在内部 RAM  |

---

## 18.10 实验：双核同抢一个计数器

理论齐了，上 QEMU 实测。实验分两步：先复现竞态，再用临界区修复。

### 1. 无保护版本：复现丢更新

```bash
cd ~ && idf.py create-project freertos-ch18 && cd freertos-ch18
idf.py set-target esp32
```

把 `main/freertos-ch18.c` 替换为：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define LOOPS 10000

static volatile uint32_t s_count = 0;   /* 无保护的共享计数器 */

static void hammer_task(void *arg)
{
    uint32_t core = (uint32_t)(uintptr_t)arg;
    for (int i = 0; i < LOOPS; i++) {
        s_count++;                      /* 读-改-写三步，非原子 */
    }
    printf("[core %u] done\n", (unsigned)core);
    vTaskDelete(NULL);
}

void app_main(void)
{
    /* 两个同优先级任务，分别钉死在两个核上，保证真正并行 */
    xTaskCreatePinnedToCore(hammer_task, "hammer0", 2048, (void *)0, 5, NULL, 0);
    xTaskCreatePinnedToCore(hammer_task, "hammer1", 2048, (void *)1, 5, NULL, 1);

    vTaskDelay(pdMS_TO_TICKS(1000));    /* 等两轮锤完 */
    printf("expected %u, got %u, lost %u\n",
           2u * LOOPS, s_count, 2u * LOOPS - s_count);
}
```

`idf.py qemu monitor` 运行，典型输出（丢失量每次运行不同）：

```text
[core 0] done
[core 1] done
expected 20000, got 16433, lost 3567
```

丢了约六分之一。每次都丢、且数目不定——这正是竞态的签名：`s_count++` 编译成 `l32i / addi / s32i` 三条指令，两个核的序列任意交错，凡是"两读同值、两写同值"的交错就吞掉一次自增。两个细节值得咀嚼：

- **把两个任务都钉到同一个核**（第三个参数都给 0）：跑多少次都是完整的 20000。这就是 18.1 节的结论——单核上任务 vs 任务的 `++` 是安全的，上下文切换发生在指令边界，寄存器状态被完整保存。真正的元凶是**第二个核**，不是"多任务"。
- **去掉 `volatile`**（且开优化）：结果可能变成完整 20000，也可能丢得更狠——编译器把循环折叠成 `s_count += LOOPS` 一次访存，竞态窗口形状完全改变。竞态实验必须用 `volatile` 固定访存行为，这也是"竞态 bug 无法靠编译器选项修复"的生动注脚。

### 2. 修复版本：临界区包住读-改-写

```c
static portMUX_TYPE s_count_lock = portMUX_INITIALIZER_UNLOCKED;

static void hammer_task(void *arg)
{
    uint32_t core = (uint32_t)(uintptr_t)arg;
    for (int i = 0; i < LOOPS; i++) {
        portENTER_CRITICAL(&s_count_lock);   /* 18.2~18.5 的全部机制在此生效 */
        s_count++;
        portEXIT_CRITICAL(&s_count_lock);
    }
    printf("[core %u] done\n", (unsigned)core);
    vTaskDelete(NULL);
}
```

`app_main` 不变，重新 `idf.py qemu monitor`：

```text
[core 0] done
[core 1] done
expected 20000, got 20000, lost 0
```

一个不丢。每次自增的读-改-写整体处在"关本核中断 + 握有 `s_count_lock`"的保护下：同核中断进不来，对面核在同一行的 `portENTER_CRITICAL` 里自旋等待。两个核的 20000 次自增被彻底串行化——这正是当初内核保护链表所要求的那份互斥。

代价也可以顺手量一下：修复版明显跑得更久（两个核高频对撞一把锁，自旋占了大量时间）。把 `portENTER_CRITICAL/EXIT` 挪到 `for` 循环外面（一次加锁做完 10000 次自增）会快几个数量级——**锁的粒度是正确性与并行度的平衡**，内核拆细粒度锁（18.6 节）就是在做同一件事。

### 3. 扩展实验：把临界区写坏的 N 种方式

留三个动手题（都在 QEMU 可完成）：

1. **临界区里加 `printf`**：在 `portENTER_CRITICAL` 和 `portEXIT_CRITICAL` 之间打印一句话，观察另一个核的吞吐骤降与整体运行时间暴涨——自旋等待的直观体验（18.9 节）。
2. **临界区里加 `vTaskDelay`**：结果不是变慢而是**死机**——`vTaskDelay` 内部要走调度路径，调度路径又要拿 `xKernelLock`，在持有用户锁且关中断的状态下触发内核 assert 或自锁（18.8 节）。记住铁律：临界区里不阻塞、不打印、不做任何耗时事。
3. **两把锁反向嵌套**：写两个任务分别以 `a→b` 和 `b→a` 的顺序抢两把锁，看系统如何无声地停摆，再用 `Ctrl-]` 退出后对照 18.8 节的死锁分析。

真机对照：以上实验在真实 ESP32 上行为一致（QEMU 与真机跑同一份二进制）；真机上竞态丢失比例通常更高，因为真实总线时序比 QEMU 的两个 vCPU 线程交错得更密集。

---

## 18.11 小结

- 临界区要防的竞争者：单核只有"本核任务 vs 中断"一类（任务 vs 任务在指令边界切换下天然安全）；双核新增"异核任务 vs 任务/中断"两类，且**关中断只作用于本核，天生挡不住对面**。
- 三层 API：`taskENTER_CRITICAL(&mux)` → `portENTER_CRITICAL(mux)` → `xPortEnterCriticalTimeout()`；ISR 专用的 `portSET_INTERRUPT_MASK_FROM_ISR()` 只关本核中断、不拿锁；`_SAFE` 变体按上下文自动分发；IDF 的临界区任务/ISR 两用是非标准行为。
- Vanilla 的实现是纯关中断（INTLEVEL 抬到 EXCM=3），嵌套计数放 TCB；单核上"关中断即独占"完备且优雅。
- IDF 的实现是"先关本核中断，再抢自旋锁"：`spinlock_t{owner,count}`，抢锁靠 `S32C1I` 条件存储（配 `SCOMPARE1`），原子性由总线仲裁保证；等待核在自旋期间保持关中断；嵌套计数移到端口的每核数组（持有者是核不是任务）。
- 内核锁地图是细粒度的：`xKernelLock` + 每队列/事件组/流缓冲一把 + `xTimerLock`；`vTaskSuspendAll()` 在 SMP 下要先拿 `xKernelLock` 且只挂起当前核——老代码拿它当互斥用是失效的。
- `portYIELD_CORE` 靠 crosscore 软件中断请求他核切换，reason 位图复用同一根中断线；`portYIELD_WITHIN_API` 用"给自己发中断"实现关中断状态下的延迟 yield。
- 新风险：反向嵌套双锁 = 无声死锁；自旋锁无优先级继承，高优先级任务的等待上界是持锁者（可能更低优先级）的临界区长度；临界区里 printf/delay 是事故高发区。
- 性能画像：无争用时一次 CAS 级别；争用时成本体现为等待核的中断延迟；进出临界区的函数被链接脚本强制放 IRAM；锁对象禁止放 PSRAM。
- 实验验证：双核各万次自增的无保护计数器稳定丢更新（同核则一个不丢），`portENTER_CRITICAL` 修复后分毫不差。

下一章离开端口层，进入 Part V 的内存世界：FreeRTOS 官方的五个堆分配器 `heap_1` ~ `heap_5`——为什么最简单的 `heap_1`（只分配、永不释放）至今仍是嵌入式的正确答案，`heap_4` 的合并算法如何对抗碎片，而 `heap_5` 又是怎样跨越多段内存的。你会看到，堆分配器的每一步也在和本章的临界区打交道：分配路径必须在关中断/锁的保护下改堆元数据，而这回要保护的，是两个核同时 `malloc` 时那同一个空闲链表。[[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison|第19章]]见。
