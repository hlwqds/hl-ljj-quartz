---
title: "FreeRTOS 深度解析（二十三）：核间同步机制"
date: 2026-08-26
description: "解剖 ESP32 双核之间如何互相打断：from-CPU 核间中断硬件、portYIELD_CORE 完整链路、自旋锁与核间中断的配合、内部 SRAM 与 SPIRAM 的可见性差异，以及队列/原子/esp_ipc 的跨核通信选型决策表。"
tags: [freertos, rtos, esp32, esp-idf, smp, ipc, spinlock, cache-coherence, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 23. **第二十三章：核间同步机制**

# FreeRTOS 深度解析（二十三）：核间同步机制

第二十二章把 IDF FreeRTOS 的 SMP 改造看了个全景。但有一个问题被反复推迟到本章：**单核世界里，"让别的执行流让路"只需要操纵自己；双核世界里，Core A 的内核代码凭什么能让 Core B 立刻放下手头任务重新调度？** Core A 既碰不到 Core B 的程序计数器，也不能"替"它做上下文切换。

答案是一套完整的垂直栈：硬件层的 **from-CPU 核间中断**、内核层的 **`portYIELD_CORE()` 链路**、与自旋锁临界区的**配合规则**，再往上才是应用层看得见的队列、`esp_ipc_call()`。本章自底向上拆这条链，然后回答每个双核应用都会问的问题：**两个核共享一份数据，到底该用哪把刀？** 最后用三个版本的共享计数器实验，把"错误/原子/消息"三种写法的差异跑出来。

除非特别说明，本章源码引用均指 ESP-IDF v6.0.2 的 `components/freertos/FreeRTOS-Kernel/`（IDF FreeRTOS 默认编译树，Vanilla v10.5.1 基线 + Espressif SMP 改造，改造说明见该目录下 `idf_changes.md`）。

---

## 23.1 from-CPU 中断：核间通信的硬件底座

### 1. 一核如何"拍一下"另一核

核间同步的第一性问题只有一个：**Core A 怎么让 Core B 的执行流被打断？** 常规外设中断帮不上忙——它们的触发源在外设里。ESP32 的答案是 DPORT 里的一组专用寄存器：**from-CPU 中断**。每个核有独立的触发寄存器，写 1 触发、写 0 清除：

```text
DPORT_CPU_INTR_FROM_CPU_0_REG   ← 写入 bit 后，CORE 0 收到一个电平中断
DPORT_CPU_INTR_FROM_CPU_1_REG   ← 写入 bit 后，CORE 1 收到一个电平中断
（FROM_CPU_2 / FROM_CPU_3 同理，见下文 IPC_ISR）
```

它是电平触发的：触发位不清零，中断会一直挂着。所以 ISR 的第一件事永远是写 0 清除。

ESP32 一共提供 **4 个** from-CPU 中断源，IDF 对它们的分工在 `soc/interrupts.h` 的注释里写得明明白白：

| 中断源                      | 送达哪个核 | IDF 中的用途                   |
| --------------------------- | ---------- | ------------------------------ |
| `ETS_FROM_CPU_INTR0_SOURCE` | Core 0     | FreeRTOS crosscore（yield 等） |
| `ETS_FROM_CPU_INTR1_SOURCE` | Core 1     | FreeRTOS crosscore（yield 等） |
| `ETS_FROM_CPU_INTR2_SOURCE` | Core 0     | IPC_ISR（flash、DPORT stall）  |
| `ETS_FROM_CPU_INTR3_SOURCE` | Core 1     | IPC_ISR（flash、DPORT stall）  |

注意命名规则：编号 `n` 对应"送达核 `n`"，而**任何核都可以写**这几个寄存器——Core 0 写 `FROM_CPU_1_REG` 就是在给 Core 1 发中断。这就是全部硬件机制：一次对 DPORT 寄存器的普通外设写。

### 2. crosscore_int.c：给硬件套上"原因"语义

单比特中断太穷——Core B 收到中断时并不知道 A 想干什么。`components/esp_system/crosscore_int.c` 在其上封装了一层**原因码**协议：

```c
/* crosscore_int.c（节选，注释为笔者所加） */
#define REASON_YIELD            BIT(0)   /* 请重新调度 */
#define REASON_FREQ_SWITCH      BIT(1)   /* CPU 频率即将切换 */
#define REASON_PRINT_BACKTRACE  BIT(2)   /* 请打印你的调用栈（panic 用） */
#define REASON_GDB_CALL         BIT(3)   /* GDB stub 更新断点 */
#define REASON_TWDT_ABORT       BIT(4)   /* 任务看门狗要求退出 */

static portMUX_TYPE reason_spinlock = portMUX_INITIALIZER_UNLOCKED;
static volatile uint32_t reason[CONFIG_FREERTOS_NUMBER_OF_CORES];

static void esp_crosscore_int_send(int core_id, uint32_t reason_mask)
{
    portENTER_CRITICAL_ISR(&reason_spinlock);     /* 1. 原子地置位原因码 */
    reason[core_id] |= reason_mask;
    portEXIT_CRITICAL_ISR(&reason_spinlock);
    crosscore_int_ll_trigger_interrupt(core_id);  /* 2. 写 DPORT 寄存器拍人 */
}
```

接收端 `esp_crosscore_isr()`（每核一个，由 `esp_crosscore_int_init()` 在启动时经 `esp_intr_alloc()` 注册）的流程：先 `crosscore_int_ll_clear_interrupt()` 写 0 清挂起位，再在同一把 `reason_spinlock` 保护下取走并清零自己的 `reason[core_id]`，然后逐位分派——`REASON_YIELD` 走 `portYIELD_FROM_ISR()`，`REASON_PRINT_BACKTRACE` 调 `esp_backtrace_print()`，等等。

这套设计有两个值得记住的点。**其一，原因码是"或"上去的**：多个发送者（甚至不同核）可以并发置位不同原因，一次中断全部带走，不丢消息。**其二，`REASON_PRINT_BACKTRACE` 解释了一个常见现象**——panic 时日志里 Core 0 和 Core 1 都能打印 backtrace，正是因为 panic 处理代码在 Core 0 上给 Core 1 发了这个原因码的核间中断，让 Core 1 自己在中断里打印自己的栈。跨核 backtrace 就是本章机制的直接应用（23.6 节还会用到）。

> [!tip] Vanilla vs ESP-IDF：核间中断根本不存在于 Vanilla
> Vanilla FreeRTOS v10.5.1 是单核内核：没有 `portYIELD_CORE()`、没有核间中断、没有 `crosscore_int` 这一层。它的 `portYIELD()` 只负责本核切换。上游仓库 `portable/ThirdParty/GCC/Xtensa_ESP32/` 里那份 Xtensa 端口是 Espressif 反向贡献的 IDF 端口摘录（文件里 `#include "sdkconfig.h"`），仅此而已——内核本体对多核一无所知。核间中断是 IDF fork 为 SMP 新增的整套基础设施。

---

## 23.2 portYIELD_CORE：让另一核重新调度的完整链路

### 1. 触发端：内核什么时候需要"遥控"另一核

先看需求从哪来。IDF FreeRTOS 的 `tasks.c` 中，跨核 yield 的统一入口是宏 `taskYIELD_CORE()`（展开为 `portYIELD_CORE()`），典型调用点有四类：

| 场景                                 | 调用位置（`tasks.c`）     | 语义                                 |
| ------------------------------------ | ------------------------- | ------------------------------------ |
| 高优先级任务就绪，且亲和允许落在对核 | `prvIsYieldRequiredSMP()` | 对核正跑着更低优先级的任务，请它让位 |
| 删除一个正在对核上运行的任务         | `vTaskDelete()`           | 对核必须立刻换下这个马上要消失的 TCB |
| **降低**对核当前任务的优先级         | `vTaskPrioritySet()`      | 降级后对核可能该跑别的任务了         |
| 挂起对核当前任务                     | `vTaskSuspend()`          | 同上，当前任务不再可运行             |

以 `prvIsYieldRequiredSMP()` 为例（双核，`!xCurCoreID` 就是"另一个核"）：

```c
/* tasks.c prvIsYieldRequiredSMP()（节选） */
else if( ( taskIS_AFFINITY_COMPATIBLE( !xCurCoreID, pxTCB ) == pdTRUE ) &&
         ( uxTaskPriority > pxCurrentTCBs[ !xCurCoreID ]->uxPriority ) &&
         ( uxSchedulerSuspended[ !xCurCoreID ] == ( UBaseType_t ) 0U ) )
{
    taskYIELD_CORE( !xCurCoreID );          /* 遥控对核 yield */
    xYieldRequiredCurrentCore = pdFALSE;
}
```

三个条件缺一不可：目标任务的核亲和允许在对核运行、优先级确实压过对核当前任务、且对核没有挂起调度（`vTaskSuspendAll()` 只挂起本核调度器——第二十二章讲过每核独立计数）。

### 2. 一个反直觉细节：内核 API 里 yield 自己，也要发核间中断

IDF 端口的 `portmacro.h` 里有这么一行：

```c
#define portYIELD_WITHIN_API()  esp_crosscore_int_send_yield(xPortGetCoreID())
```

`portYIELD_WITHIN_API()` 是内核 API（`xQueueSend()`、`vTaskDelay()` 等）在持有内核锁的临界区内部请求切换时用的宏。注意它调的是 `esp_crosscore_int_send_yield(本核)`——**给自己发核间中断**。为什么绕这么远，不直接 `vPortYield()` 切换？

因为调用点此刻处于"关中断 + 持自旋锁"的临界区里，直接执行一次主动切换（solicited context switch）意味着**带着锁切出去**——新任务会运行在一个"内核数据结构看似受保护、实际持锁者是别人"的世界里，这是灾难。改用自 IPI 后：中断请求被记录，但 ISR 要等当前临界区退出、中断重新使能后才会送达；真正的上下文切换发生在 **ISR 退出路径**上（`portYIELD_FROM_ISR()` → `_frxt_setup_switch()`），那一刻锁早已释放。一句话：**把"立即切换"降级为"退出临界区后切换"，用硬件中断的天然延迟换取锁纪律**。

### 3. 接收端：ISR 里的三步舞

从-CPU 中断送达后，`esp_crosscore_isr()`（上一节读过）对 `REASON_YIELD` 的处理一行就完事：`portYIELD_FROM_ISR()`。它展开为 `_frxt_setup_switch()`（`portasm.S`）——在当前任务的栈帧里登记"退出中断时需要重新调度"，然后 ISR 正常返回，Xtensa 的中断退出派发代码完成上下文切换（第 7、17 章的领域，这里只需知道：**切换发生在中断退出，不在 ISR 内部**）。

还有一个边角值得知道，`crosscore_int.c` 里 Espressif 自己留了条注释：中断送达时，目标核可能**恰好已经**切到了预期任务（比如时间片刚好先到了）。这时 yield ISR 空跑一趟，`portYIELD_FROM_ISR()` 大概率还是把同一个任务选回来——浪费但无害。这解释了为什么此机制是"尽力而为"而不做精确去重。

### 4. 全链路路径图

```text
【Core A：内核判定 B 该 yield】
 tasks.c (如 prvIsYieldRequiredSMP / vTaskDelete / vTaskPrioritySet / vTaskSuspend)
   └─ taskYIELD_CORE(1)                    # !xCurCoreID
       └─ portYIELD_CORE(1)                # portmacro.h
           └─ vPortYieldOtherCore(1)       # port.c
               └─ esp_crosscore_int_send_yield(1)     # crosscore_int.c
                   ├─ portENTER_CRITICAL_ISR(&reason_spinlock)
                   │    reason[1] |= REASON_YIELD
                   ├─ portEXIT_CRITICAL_ISR(...)
                   └─ crosscore_int_ll_trigger_interrupt(1)
                        写 DPORT_CPU_INTR_FROM_CPU_1_REG = 1   ──┐
                                                                │ 硬件中断线
【Core B：被打断】◀──────────────────────────────────────────────┘
 esp_crosscore_isr()                       # 每核注册一个
   ├─ 写 0 清除 DPORT_CPU_INTR_FROM_CPU_1_REG   （电平中断必须清）
   ├─ 取走并清零 reason[1]（同一把 reason_spinlock）
   └─ REASON_YIELD → portYIELD_FROM_ISR()
                       └─ _frxt_setup_switch()    # portasm.S
                           └─ 中断退出路径上执行 vTaskSwitchContext()
                               → pxCurrentTCBs[1] 换人，B 的低优先级任务让位
```

---

## 23.3 自旋锁与核间中断的配合

### 1. spinlock_t：S32C1I 上的两字段锁

第二十二章提过 IDF 把临界区从"关中断"升级为"关中断 + 自旋锁"。现在下到锁本身：`components/esp_hw_support/include/spinlock.h` 的 `spinlock_t` 只有两个 32 位字段：

```c
typedef struct {
    NEED_VOLATILE_MUX uint32_t owner;   /* 谁持有：SPINLOCK_FREE / 核 ID 魔数 */
    NEED_VOLATILE_MUX uint32_t count;   /* 同核嵌套计数 */
} spinlock_t;

#define SPINLOCK_FREE          0xB33FFFFF
#define SPINLOCK_OWNER_ID_0    0xCDCD    /* Xtensa PRID 寄存器读出的 Core0 原始值 */
#define SPINLOCK_OWNER_ID_1    0xABAB    /* Core1 原始值 */
```

`owner` 的取值有个好玩的事实：Xtensa 上它不存 0/1，而是存 CPU 的 `PRID` 寄存器原始读数 `0xCDCD`/`0xABAB`（`xt_utils_get_raw_core_id()` 直接返回）。选魔数而非 0/1 的动机写在注释里——避免 0 成为合法持有者 ID，让"全零的静态内存"天然等于"未初始化/空闲"之外的状态可区分。

抢锁的原子性由 Xtensa 的条件存储指令保证，`hal/cpu_ll.h` 里就三行：

```asm
WSR     %2, SCOMPARE1      /* 把期望值装进 SCOMPARE1 特殊寄存器 */
S32C1I  %0, %1, 0          /* 若内存 == SCOMPARE1 则写入新值，否则只读旧值到 %0 */
```

`S32C1I`（Store 32-bit Conditional, 1-Indivisible）在总线层面是不可分割的读-比-写，两核同时执行也只有一个成功。`spinlock_acquire()` 先做一次快速尝试（大多数时候锁是空闲的，免得白读周期计数器），失败才进入带超时的自旋循环；期间本核中断被抬到 `XCHAL_EXCM_LEVEL`（level 3），防止自己被 ISR 打断后死锁在自己身上。`spinlock.h` 的文档注释特别强调：**自旋锁本身不构成临界区**（拿到锁后中断会重新放开），真正的临界区语义由操作系统层包一层提供——那正是下一步。

### 2. 临界区 = 关中断 + 自旋锁（各管一半）

`port.c` 的 `xPortEnterCriticalTimeout()` 把两样东西焊在一起：

```c
/* port.c（节选） */
BaseType_t xPortEnterCriticalTimeout(portMUX_TYPE *mux, BaseType_t timeout)
{
    BaseType_t xOldInterruptLevel = portSET_INTERRUPT_MASK_FROM_ISR(); /* ① 抬 intlevel 到 3 */
    if (!spinlock_acquire(mux, timeout)) {                             /* ② 抢自旋锁 */
        portCLEAR_INTERRUPT_MASK_FROM_ISR(xOldInterruptLevel);
        return pdFAIL;
    }
    /* 持锁期间中断保持关闭 …（vPortExitCritical 释放锁并恢复中断） */
}
```

分工是教科书式的：**关中断管本核**（ISR、调度点都进不来，本核不会中途插队），**自旋锁管他核**（对方核想进同一临界区只能在 `S32C1I` 循环里等）。单核世界只需要前者；双核世界缺一不可。所以你写下的每一对 `portENTER_CRITICAL(&mux)`/`portEXIT_CRITICAL(&mux)`，在 SMP 编译里都是这两层的复合。

### 3. 关键配合：临界区里请求他核 yield 会怎样

现在把 23.2 和前两节拼起来，回答本章标题里最微妙的问题。设想：Core A 正在内核临界区里（关中断 + 持内核锁）执行 `prvIsYieldRequiredSMP()`，判定 Core B 该 yield。此时：

1. Core A 调 `taskYIELD_CORE(1)` → `reason[1] |= REASON_YIELD` → 写 `FROM_CPU_1_REG`。注意这一步**不要求**目标核配合——置位和触发都是 Core A 单方面的寄存器写。
2. Core B 如果**没有**在临界区里（intlevel 为 0），核间中断立刻送达，`_frxt_setup_switch()` 登记切换，B 在几微秒内换任务。这就是"临界区内请求他核 yield"的正常结局：请求方不必等对方走出临界区，遥控是异步的。
3. Core B 如果**也在**临界区里（intlevel ≥ 3，比如它正拿着同一把内核锁在自旋或执行），中断请求挂起，等它退出临界区、中断放开的那一瞬间送达。最坏情况是 B 正在等 A 手里那把锁——A 释放锁后还要等自己的临界区完全退出才恢复中断；B 的 `spinlock_acquire()` 成功、走完临界区退出，intlevel 回落的瞬间，pending 的核间中断立即送达并触发切换。链条自洽，不会丢 yield。

`tasks.c` 里那个每核一份的 `xYieldPending[configNUMBER_OF_CORES]` 数组（`idf_changes.md` 明确列为对 Vanilla 单变量版的 SMP 扩展）就是"本核延迟切换"的记账本：临界区里发现该切换时置位，`vTaskSwitchContext()` 或 ISR 退出路径看到置位才真正换人。

> [!note] 为什么不干脆"等对核自己发现"？
> 时间片和 tick 只会唤醒"到期"的任务；优先级抢占、删除、挂起这些事件没有自然的"对核稍后自查"时机。若没有 IPI，对核可能要等到下一个 tick（默认 10ms）才注意到该切换——对"高优先级任务已就绪"的实时语义来说太慢。from-CPU 中断把跨核调度延迟压到微秒级，这是 SMP 抢占实时性的支柱。

> [!tip] Vanilla vs ESP-IDF：同一行宏，两个世界
>
> | 主题                  | Vanilla FreeRTOS v10.5.1  | IDF FreeRTOS                                                |
> | --------------------- | ------------------------- | ----------------------------------------------------------- |
> | `portYIELD()` 语义    | 本核切换                  | 本核切换（`vPortYield()`，不变）                            |
> | 让**另一**核 yield    | 不存在此概念              | `portYIELD_CORE()` → from-CPU 中断                          |
> | 内核 API 内部请求切换 | 直接 `portYIELD()` 当场切 | `portYIELD_WITHIN_API()` = 给自己发核间中断，延迟到出临界区 |
> | 临界区实现            | 关中断（单核足够）        | 关中断 + 自旋锁（`portMUX_TYPE`）                           |
> | 延迟切换记账          | `xYieldPending` 单变量    | `xYieldPending[configNUMBER_OF_CORES]` 每核一份             |

---

## 23.4 共享内存可见性：内部 SRAM、S32C1I 与 SPIRAM 陷阱

锁解决"谁先谁后"，但还有更底层的问题：**一个核写下去的值，另一个核什么时候读得到？** ESP32 上答案因内存区域而截然不同。

### 1. 内部 SRAM：直连、无 cache、总线串行化

520KB 内部 SRAM（DRAM 区）被两个核通过总线仲裁器共享，**数据访问不经过 cache**。这带来三个干净的性质：

1. **可见性即时**：Core A 的对齐 32 位写一旦离开流水线进入总线，Core B 后续的读就能看到。`cache_utils.c` 里双核协调 flash 操作用的 `s_flash_op_can_start`、`s_flash_op_complete` 就是普通 `volatile` 标志 + 忙等——敢这么写，前提就是内部 SRAM 直连。
2. **天然原子**：对齐的 32 位 load/store 在总线上是一次事务，另一核不会观察到"半个字"。
3. **`memw` 兜底序**：Xtensa 是弱序内存模型，编译器和 CPU 都可能重排访存。需要严格顺序的地方（比如"先写数据、再写就绪标志"）在 IDF 源码里随处可见 `memw` 指令——它等待所有未完成写到达内存系统。`cpu.c` 的 PSRAM CAS 回退里就有"先 `memw` 再恢复中断"的用法。

### 2. S32C1I 的总线语义

`S32C1I` 的原子性来自内部 SRAM 的同一条总线串行化：比较和写是一次不可分割的总线事务，两核竞争时总线仲裁器给出一个全序。前提有二：**地址 4 字节对齐**、**目标在内部 SRAM**。第一个前提是 ISA 要求；第二个前提是下面要展开的陷阱。

### 3. SPIRAM：一致性陷阱三连

PSRAM 通过 cache 映射进地址空间（flash 与 PSRAM 共用同一 cache 区域），而**每个核有自己独立的 cache，硬件不维护两核 cache 一致性**。`esp_cache.h` 对 `esp_cache_msync()` 的文档注释还确认了一个关键硬件事实：**ESP32（经典版）的 cache 不支持 writeback**——写操作是写穿（write-through）的，C2M 方向的 msync 在 ESP32 上是空操作。由此推出三个陷阱：

**陷阱一：陈旧读。** Core A 改了 PSRAM 里的变量（写穿到 PSRAM），但 Core B 的 cache 里还留着旧的一行。B 继续读到旧值，直到那行因容量被挤出或被显式失效。内部 SRAM 上"写了就能读到"的直觉在这里**失效**。

**陷阱二：同行的交错写。** cache 行 32 字节。Core A 和 Core B 各写同一行里的不同变量，每次写虽然穿到 PSRAM，但行的粒度交互（脏位、子行写掩码）可能让两核各自视角下的"这行内容"不一致——你会在两个核上观察到同一行数据的两种历史。守则：**两核都要写的 PSRAM 数据，按 32 字节行隔开**（`esp_cache_get_line_size_by_addr()` 可以查行大小）。

**陷阱三：S32C1I 失效。** 条件存储的原子性建立在"直连串行化总线"上，走 cache 的访问无法保证。`esp_hw_support/cpu.c` 的 `esp_cpu_compare_and_set()` 源码直接承认了这一点：地址落在 PSRAM 范围（`SOC_EXTRAM_DATA_LOW`~`HIGH`）时不用原生 CAS，而是回退——`rsil` 抬到 EXCM level，用 `S32C1I` 抢一把**位于内部 SRAM 的**全局 CAS 锁 `external_ram_cas_lock`，抢到后用普通的"读-比-写"完成比较交换，再放锁、`memw`、恢复中断。**也就是说：PSRAM 上的原子操作是拿内部 RAM 的锁模拟的**，竞争激烈时全局串行化，性能远低于内部 RAM 的原生原子。

顺带一提历史坑：ESP32 Rev1 的 PSRAM cache 有硬件缺陷（cache 行回填期间被中断打扰可能丢写），IDF 提供 `SPIRAM_CACHE_WORKAROUND` 编译器修正（`-mfix-esp32-psram-cache-issue`，策略有 MEMW/DUPLDST/NOPS 三档，见 `esp_psram/esp32/Kconfig.spiram`）。v6 里这属于"知道即可"的考古项。

### 4. 守则汇总

| 做法                            | 内部 SRAM                        | SPIRAM                                               |
| ------------------------------- | -------------------------------- | ---------------------------------------------------- |
| 跨核共享标志/计数器             | ✅ `volatile` + 原子或临界区即可 | ⚠️ 能免则免；必须用时保证单写者 + 读侧失效本地 cache |
| `S32C1I` 原子操作               | ✅ 原生支持                      | ❌ `esp_cpu_compare_and_set()` 走内部锁回退          |
| 两核写同一区域                  | ✅ 用锁即可                      | ⚠️ 同一 32 字节行内的双核写要隔行                    |
| `esp_cache_msync()` C2M（写回） | —（无 cache）                    | ESP32 上是 no-op（无 writeback）                     |
| `esp_cache_msync()` M2C（失效） | —                                | ✅ 失效**调用核**本地 cache 行，后续读重新取 PSRAM   |

一句话守则：**跨核共享的同步原语（锁、标志、队列对象的存储）留在内部 RAM；PSRAM 放大块数据。** IDF 自己也是这么做的——`heap_idf.c` 把内核堆整体限定在 `portFREERTOS_HEAP_CAPS`（`MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT`），TCB、任务栈、队列存储因此全部天然落在内部 RAM。

---

## 23.5 应用层跨核通信选型

底座铺完，回到应用视角。两个核上的任务要协作，工具箱里有什么？

### 1. 内核对象：队列、通知、事件组——天然跨核安全

第一选择几乎总是 FreeRTOS 内核对象。前面第 10~14 章拆过它们的实现，这里只补一个 SMP 视角的事实：IDF fork 给 `queue.c` 的每个队列对象加了**自己的自旋锁**——

```c
/* IDF FreeRTOS queue.c（节选）：所有队列操作进各自队列锁的临界区 */
taskENTER_CRITICAL( &( pxQueue->xQueueLock ) );
```

Vanilla v10.5.1 的 `queue.c` 对应位置是**无参数**的 `taskENTER_CRITICAL()`——关中断即临界区，因为单核世界里关中断就挡住了所有人。IDF 版把"所有人"扩展到两个核，代价是每次队列操作多一次 S32C1I 往返。收益是：**任何内核对象，哪个核访问都安全**。Core 0 的 ISR 里 `xQueueSendFromISR()`、Core 1 的任务里 `xQueueReceive()`，不需要你考虑任何核间细节。任务通知（第 13 章）、事件组（第 12 章）、流/消息缓冲（第 14 章，注意其单读单写约束本身与核无关）同理。

### 2. 裸共享变量 + 原子操作：轻，但纪律自负

内部 SRAM 上一条 `S32C1I` 循环（GCC 的 `__atomic` 内建在 Xtensa 上就编译成它）或一段 `portENTER_CRITICAL()`，就能护住一个计数器或标志位。它比队列快一个数量级以上（无系统调用语义、无唤醒链），适合**高频、简单、无阻塞语义**的共享——统计计数、环形缓冲指针（配合内存屏障）、单比特心跳。代价：没有阻塞唤醒，消费者要轮询或另配通知；纪律全靠写的人（忘了原子就是 23.7 节实验一的结局）。

### 3. esp_ipc_call 家族：阻塞式核间"函数调用"

有时你要的不是传数据，而是**让指定核替你执行一段代码**——比如某外设寄存器只能在 Core 0 写，或某操作必须"在对核的上下文里"跑。`components/esp_system/esp_ipc.c` 提供三个 API，实现是每个核一个高优先级 IPC 任务（`ipc0`/`ipc1`，优先级 `configMAX_PRIORITIES - 1`，用 `xTaskCreatePinnedToCore()` 钉死）：

| API                                        | 等待到                | ISR 里可用 | 典型用途             |
| ------------------------------------------ | --------------------- | ---------- | -------------------- |
| `esp_ipc_call(cpu, func, arg)`             | 对核**开始**执行 func | ❌         | 触发型：发令即走     |
| `esp_ipc_call_blocking(cpu, func, arg)`    | 对核**跑完** func     | ❌         | 查询型：要拿返回效果 |
| `esp_ipc_call_nonblocking(cpu, func, arg)` | 不等                  | ✅         | 抢占式：CAS 抢槽位   |

工作流（`esp_ipc_call_blocking` 为例）：调用核拿 IPC 互斥量 → 写好 `s_func[]`/`s_func_arg[]` → `xTaskNotifyGive()` 唤醒对核 IPC 任务 → 自己阻塞在 ack 二值信号量上；对核 IPC 任务醒来执行 func，完成后 `xSemaphoreGive()` 唤醒调用者。`esp_ipc_call_nonblocking` 更妙：用 `esp_cpu_compare_and_set()`（S32C1I）原子抢占对核的回调槽位，抢不到说明上一发还没消化，直接返回失败——因此可以从 ISR 调用。

### 4. esp_ipc_isr：中断上下文级 IPC 与"停核"

比 IPC 任务更低延迟的是 `esp_ipc_isr`（`esp_system/port/esp_ipc_isr.c`）：用 **FROM_CPU_2/3** 中断（就是 23.1 表里 IPC_ISR 那两根线，路由到保留的高优先级中断向量 `ETS_IPC_ISR_INUM`）让对核**在高优先级中断里**执行回调，延迟以微秒计，且完全无视任务调度状态。代价苛刻：Xtensa 上回调**必须用汇编写**（调用约定只给 a2/a3/a4 三个寄存器，见 `esp_ipc_isr.h` 的文档）。它还提供 `esp_ipc_isr_stall_other_cpu()`/`esp_ipc_isr_release_other_cpu()`——把对核**钉死**在一个汇编忙等循环里。谁会需要这么暴力的东西？见下一小节。

### 5. 必须用 IPC 的场景：flash 操作

Flash 擦写期间，映射 flash 的 cache 必须关闭；而 XIP（就地执行）的代码就在 flash 里——**关 cache 的核不能再执行任何 flash 中的代码**。这意味着 flash 操作必须两核**同时**进入"cache 关闭、只在 IRAM 里活动"的状态，单靠自旋锁做不到：自旋锁只能互斥访问，拦不住对核继续执行 cache 化代码（那会在 flash 被写时取指，直接取回垃圾）。`components/spi_flash/cache_utils.c` 的 `spi_flash_disable_interrupts_caches_and_other_cpu()` 是标准答案：

```text
Core A（发起 flash 操作）                     Core B
────────────────────────────                ────────────────────────────
spi_flash_op_lock()  （互斥量串行化 flash 操作）
vTaskSuspendAll()    （本核调度器挂起）
esp_ipc_call_nonblocking(1,
    spi_flash_op_block_func)  ──────────▶   IPC 任务被唤醒，执行
                                             spi_flash_op_block_func()：
                                              esp_intr_noniram_disable()
                                              spi_flash_disable_cache(1)
                                              while (!s_flash_op_complete);  ← IRAM 忙等
while (!s_flash_op_can_start);  ← 忙等对核确认
esp_intr_noniram_disable()
spi_flash_disable_cache(0)
【执行 flash 擦/写——全程 IRAM 代码 + 内部 RAM 数据】
spi_flash_restore_cache(0)
s_flash_op_complete = true;  ──────────▶   跳出忙等，恢复 cache，恢复中断，
                                            任务继续
xTaskResumeAll()
```

三个细节值得咀嚼：其一，这里用的是 `esp_ipc_call_nonblocking` 而非阻塞版——它不需要 func 的返回，且失败可重试（槽位被占就重发）；其二，两核之间的握手标志（`s_flash_op_can_start`/`s_flash_op_complete`）就是 23.4 节说的"内部 SRAM volatile + 忙等"的合法用例——双方都关了中断、停了调度，不存在抢占，也不存在 cache；其三，busy-wait 在这里是**特性**而非偷懒：对核此刻不能被调度（cache 关着，切任务可能执行 flash 代码），唯一安全的形态就是钉在 IRAM 循环里。这也解释了 `esp_ipc_isr_stall_other_cpu()` 的存在意义——DPORT 寄存器访问需要类似的两核协同（历史上用于 DPORT 读保护）。

### 6. 选型决策表

| 需求                        | 首选                                  | 备注                                            |
| --------------------------- | ------------------------------------- | ----------------------------------------------- |
| 跨核传数据/消息             | **队列 / 消息缓冲**                   | 自带阻塞唤醒，多读者多写者安全                  |
| 跨核事件信号（单值）        | **任务通知**                          | 最轻量，唤醒路径远短于队列（第 13 章）          |
| 跨核多事件布尔组合          | **事件组**                            | 第 12 章                                        |
| 高频计数器 / 单标志         | **内部 RAM 原子变量**                 | `__atomic` 或 `portENTER_CRITICAL`，无唤醒语义  |
| 结构体等复合数据 + 紧迫性低 | 复制进消息发队列                      | 避免"共享"，直接转移所有权                      |
| 必须在指定核上下文执行      | **esp_ipc_call(\_blocking)**          | 任务级，可阻塞                                  |
| 必须两核同时静默            | **flash 式协议 / esp_ipc_isr**        | 极少应用层用到，见上文「必须用 IPC 的场景」一节 |
| 共享大数据放哪              | 数据进 SPIRAM，**同步原语进内部 RAM** | 23.4 守则                                       |

---

## 23.6 双核调试技巧

### 1. 两个核 = GDB 里的两个线程

QEMU 的 ESP32 机型仿真两个核，GDB 远程协议把它们暴露为两个线程。`idf.py qemu gdb` 连上后：

```text
(gdb) info threads
  Id   Target Id         Frame
* 1    Thread 1 (cpu0)   xQueueGenericReceive (...)
  2    Thread 2 (cpu1)   prvIdleTask (...)
(gdb) thread 2
(gdb) bt            # Core 1 的调用栈
(gdb) thread apply all bt    # 两核各自完整 backtrace —— 双核排障第一招
```

死锁排查看的就是这张全景：Core 0 的栈顶停在 `spinlock_acquire` 里自旋、Core 1 的栈顶停在持有那把锁的函数里不返回——谁等谁、谁卡谁，一眼定性。真机同理，用 `idf.py gdb` + JTAG（OpenOCD 同样以线程呈现两核）。

### 2. non-stop：只停一个核

默认（all-stop）模式下断点会**同时**冻住两个核。想观察"另一核还在跑时本核的行为"（比如验证核间中断确实打断了对方），用 GDB 的 non-stop 模式——注意它必须在连接目标前设置，放进项目的 `.gdbinit` 最省事：

```text
# .gdbinit（GDB 连接前读取）
set non-stop on
set pagination off
```

之后断点只停命中的那个核，`thread 1` / `thread 2` 各自独立 continue。双核竞态类的观察（23.7 节实验非常适用）经常需要它。

### 3. 直接观察本章机制的内部状态

源码级调试的乐趣在于内核私有变量也能看。几个实用观察点（符号名均来自本章核实过的源码）：

```text
(gdb) p/x reason           # crosscore_int.c 的原因码数组——核间中断"想干什么"
(gdb) p xYieldPending      # tasks.c 每核的延迟切换记账
(gdb) p/x ((spinlock_t*)&my_mux)->owner   # 0xCDCD=Core0 持有, 0xABAB=Core1, 0xB33FFFFF=空闲
```

第三招是排"锁归属"争议的终审：怀疑某把 `portMUX_TYPE` 被谁拿住不放，直接读它的 `owner` 字段——PRID 魔数会告诉你答案。panic 场景则还有一条免费通道：23.1 节的 `REASON_PRINT_BACKTRACE` 机制会自动让两核都吐出自己的 backtrace，串口日志里那些 `CPU1: Backtrace: 0x...` 就是核间中断送达的证据。

---

## 23.7 实验：双核共享计数器三连

同一个需求写三遍：Core 0 和 Core 1 各自把一个共享计数器加 10 万次，最后打印。三版分别是无保护（错误示范）、原子指令（正确的轻量方案）、队列（正确的自然方案）。

```bash
cd ~ && idf.py create-project freertos-ch23 && cd freertos-ch23 && idf.py set-target esp32
```

### 1. 版本一：无保护（错误示范）

```c
/* main/freertos-ch23.c —— 版本一：注定丢更新的裸共享变量 */
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define N_INCR      100000
#define N_CORES     2

static volatile uint32_t g_counter;     /* volatile 只防编译器缓存，不防丢更新 */

static void bump_task(void *arg)
{
    for (int i = 0; i < N_INCR; i++) {
        g_counter++;                    /* L32I / ADDI / S32I —— 三步，非原子 */
    }
    vTaskDelete(NULL);
}

void app_main(void)
{
    for (int core = 0; core < N_CORES; core++) {
        xTaskCreatePinnedToCore(bump_task, "bump", 2048, NULL, 5, NULL, core);
    }
    /* 等 3 秒让两个任务跑完再打印 */
    vTaskDelay(pdMS_TO_TICKS(3000));
    printf("expected %u, got %lu\n", N_INCR * N_CORES, (unsigned long) g_counter);
}
```

`g_counter++` 编译成读-改-写三步。两核同时在跑，交错随时发生：Core 0 读到 500、Core 1 也读到 500，各自加完写回 501——两次自增只生效一次。跑 `idf.py qemu monitor`：

```text
expected 200000, got 138412
```

数字每次不同，但**永远少于**期望值。注意 `volatile` 无力回天——它只保证每次都真的访存，而访存序列本身可以被另一核插进来。这就是 23.5.2 节说的"纪律自负"的违约现场。

### 2. 版本二：原子指令（内部 SRAM 上的 S32C1I）

只改自增那一行：

```c
#include <stdatomic.h>                  /* __atomic 内建由 GCC 提供 */

static volatile uint32_t g_counter;     /* 内部 SRAM：原生 CAS 可用（23.4 节） */

static void bump_task(void *arg)
{
    for (int i = 0; i < N_INCR; i++) {
        __atomic_fetch_add(&g_counter, 1, __ATOMIC_RELAXED);  /* S32C1I 循环 */
    }
    vTaskDelete(NULL);
}
```

`__atomic_fetch_add` 在 Xtensa 上展开为 `WSR SCOMPARE1` + `S32C1I` 的重试循环——正是 23.3 节 `spinlock_acquire()` 用的同一条原子指令。只要变量在内部 SRAM（静态变量天然如此），总线串行化保证两核的 20 万次自增一个不丢：

```text
expected 200000, got 200000
```

等价的另一写法是把自增包进 `portENTER_CRITICAL()`/`portEXIT_CRITICAL()` 临界区（对计数器这种单变量是杀鸡用牛刀，但保护**多条语句**的原子性时它是正解）。

### 3. 版本三：队列（把"共享"变成"传递"）

第三版换思路：根本不共享计数器，两个核各自把"+1"作为消息发进队列，由一个聚合任务独占式地累加——单一写者，无竞争可言：

```c
/* 版本三骨架：共享 -> 传递 */
static QueueHandle_t s_queue;

static void bump_task(void *arg)
{
    uint32_t one = 1;
    for (int i = 0; i < N_INCR; i++) {
        xQueueSend(s_queue, &one, portMAX_DELAY);   /* 哪个核发都安全 */
    }
    vTaskDelete(NULL);
}

static void sum_task(void *arg)                     /* 唯一的计数器持有者 */
{
    uint32_t counter = 0, one;
    for (uint32_t received = 0; received < N_INCR * N_CORES; received++) {
        xQueueReceive(s_queue, &one, portMAX_DELAY);
        counter += one;
    }
    printf("expected %u, got %lu\n", N_INCR * N_CORES, (unsigned long) counter);
    vTaskDelete(NULL);
}

void app_main(void)
{
    s_queue = xQueueCreate(32, sizeof(uint32_t));
    xTaskCreatePinnedToCore(sum_task, "sum", 2048, NULL, 6, NULL, 0);
    for (int core = 0; core < N_CORES; core++) {
        xTaskCreatePinnedToCore(bump_task, "bump", 2048, NULL, 5, NULL, core);
    }
}
```

计数器是 `sum_task` 的局部变量，"共享可变状态"被彻底消灭，正确性由队列的内部自旋锁（23.5.1 节）保证。代价同样清晰：每次自增变成一次队列往返（拷贝、锁、可能的唤醒），吞吐比版本二低一个量级以上。

### 4. 三版对比

| 版本                | 正确性    | 相对开销                      | 换来什么                                     |
| ------------------- | --------- | ----------------------------- | -------------------------------------------- |
| 裸 `volatile`       | ❌ 丢更新 | 1×                            | 什么都没换来——反面教材                       |
| `__atomic` / S32C1I | ✅        | ~1×（原子指令略贵于普通读写） | 无阻塞语义的精确计数                         |
| 队列                | ✅        | 数十倍                        | 解耦、阻塞唤醒、天然跨核、可扩展成传复杂数据 |

选择逻辑收敛为一句话：**能改写成"消息传递"就用内核对象；高频热路径留在内部 SRAM 上用原子；`volatile` 单独出现的地方，永远值得多看一眼。**

---

## 23.8 小结

- **硬件底座**：ESP32 的 DPORT 提供 4 个 from-CPU 中断（FROM_CPU_0~3），写寄存器即向目标核注入电平中断，写 0 清除。FreeRTOS 用 0/1 号做 crosscore yield，2/3 号做 IPC_ISR。
- **crosscore 协议**：`crosscore_int.c` 在单比特中断上叠了原因码（`reason[]` 数组 + 自旋锁），一次中断可携带多种请求；panic 时的对核 backtrace 就是 `REASON_PRINT_BACKTRACE` 的直接应用。
- **portYIELD_CORE 链路**：`tasks.c` 在抢占、删除、降优先级、挂起四类场景遥控对核 → `vPortYieldOtherCore()` → `esp_crosscore_int_send_yield()` → from-CPU 中断 → 对核 ISR → `portYIELD_FROM_ISR()` → 中断退出时切换。内核 API 内部请求本核切换也走自 IPI，把切换推迟到退出临界区之后。
- **锁的配合**：临界区 = 关中断（管本核）+ `S32C1I` 自旋锁（管他核）。`spinlock_t` 的 owner 字段存 PRID 魔数 0xCDCD/0xABAB；跨核 yield 请求是异步的，对核若在临界区里则 pend 到退出，链条不丢。
- **内存可见性**：内部 SRAM 直连无 cache，写即可见、字访问天然原子、`memw` 兜底序；SPIRAM 走每核独立 cache，有陈旧读、同行交错写、`S32C1I` 失效三大陷阱（PSRAM 原子操作靠内部 RAM 锁模拟）。守则：同步原语进内部 RAM，大数据进 PSRAM。
- **应用选型**：内核对象（队列/通知/事件组）天然跨核安全，是第一选择；内部 RAM 原子适合高频单变量；`esp_ipc_call` 家族让指定核替你执行代码（IPC 任务 + 通知 + ack 信号量）；必须两核同时静默的场景（flash 擦写关 cache）用 IPC 驱动的双核停车协议。
- **调试**：两核在 GDB 里是两个线程，`thread apply all bt` 是死锁定性第一招；`.gdbinit` 里 `set non-stop on` 可单核停机观察；`reason`、`xYieldPending`、spinlock 的 `owner` 字段都是可以直接读的内核内部状态。

下一章是系列的收官：把二十三章攒下的机制变成排障工具箱——QEMU+GDB 的系统化用法、内核 trace 与运行时统计、看门狗的正确解读，以及一份"症状 → 根因"的死锁与竞态案例集。[[ch24-debugging-tracing-pitfalls|第二十四章]]见。
