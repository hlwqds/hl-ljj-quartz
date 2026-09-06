---
title: "嵌入式硬件基础（十二）：收官——FreeRTOS 三架构 port 对照"
date: 2026-08-30 09:00:00
description: "系列收官章：以 FreeRTOS 官方 port 源码为考场，把 Cortex-M（PendSV/BASEPRI/SysTick）、RISC-V（mtvec/mstatus/MIE/中断阈值）、Xtensa（窗口/spinlock，读者已知）三条腿在 port 层会师——四组对照（切换触发、上下文本体、临界区、tick 源）全部摘自本机真实源码，附三架构大总表与裸机毕业自检清单。"
tags: [embedded-basics, STM32, RISC-V]
---

> [!info] 嵌入式硬件基础系列 0. [[embedded-basics|系列索引]] · 11. [[ch11-debug-swd-jtag|第十一章：调试体系]] · 12. **第十二章：FreeRTOS port 对照（收官）**

# 嵌入式硬件基础（十二）：收官——FreeRTOS 三架构 port 对照

前十一章走完，这个系列攒下了两条腿：**ARM 腿**——[[ch03-arm-cortex-m-anatomy|第三章]]在 QEMU 里逐字验证过异常压栈的 8 寄存器帧、MSP/PSP 双栈、EXC_RETURN；[[ch04-baremetal-boot|第四章]]手写过向量表与 Reset_Handler；[[ch07-interrupts-nvic|第七章]]摸过 NVIC；[[ch08-timer-systick|第八章]]源码级跑过 SysTick。**RISC-V 腿**——[[ch09-riscv-gd32-contrast|第九章]]（并行写作中）对照过 mtvec/mepc/mcause 与向量表模型的分野。而读者还有第三条早就长好的腿：**Xtensa 腿**——FreeRTOS 系列的 [[ch7-context-switch-deep-dive|第七章（上下文切换）]]、[[ch16-portmacro-port-contract|第十六章（port 契约）]]、[[ch17-xtensa-port-internals|第十七章（Xtensa 端口深挖）]]已经把一个真实 port 拆到了指令级。

本章是会师点：**把同一个内核（FreeRTOS）在三种架构上的 port 层并排放下，用前十一章攒下的"裸机内部"知识逐格对账**。port 层是全系列知识的最大公约数——向量表、异常压栈、栈布局、中断屏蔽、定时器，前面每一章的实验结论，都能在某个 port 的源码里找到"原来你在这里"的落点。读完后，"把一个 RTOS 移植到新架构"对你不再是玄学，而是一张可以逐项打勾的契约清单。

本章全部摘录来自本机两棵真实源码树（取证见 12.1），无一处凭记忆复写。

---

## 12.1 取证现场：本机两棵树里的 port 层

### 1. 先看货：port 目录实测

写任何对照之前，先确认摘录来源。本机有两棵可用的 FreeRTOS 源码树，`ls` 实测（2026-08）：

**树 A：ESP-IDF v6.0.2 内核树** `~/esp/esp-idf/components/freertos/FreeRTOS-Kernel/portable/`：

```text
linux/    riscv/    xtensa/
```

只有三个目录。**没有 `ThirdParty/`，更没有任何 ARM port**——IDF 只服务 Espressif 自家芯片，ARM 端口根本不进树。每个目录内是 `port.c` + `portasm.S` + `include/freertos/portmacro.h` 的标准三件套（xtensa 还多出 `xtensa_init.c`、`xtensa_overlay_os_hook.c`）。

**树 B：上游 vanilla 内核树 V11.3.0** `~/code/FreeRTOS-Kernel/portable/`（2026-03 的 git tag `V11.3.0`）：

```text
GCC/          ARM_CM0  ARM_CM3  ARM_CM4F  ARM_CM7  ARM_CM33 ... RISC-V（共 40+ 目录）
ThirdParty/   GCC/{RISC-V, Xtensa_ESP32, RP2040, Posix, ATmega...}  XCC/Xtensa（Vanilla Xtensa 老家）
```

这是官方全谱系：Cortex-M 各型号在 `GCC/ARM_CM*`，RISC-V 通用 port 在 `GCC/RISC-V/`（`ThirdParty/GCC/RISC-V/` 里只剩一份 README，注明 MIT 版 port 已迁至 `GCC/RISC-V/`）。

于是本章的取样方案：

| 架构     | 摘录来源（本机真实路径）                                                                                   | 为什么选它                                                                        |
| -------- | ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Xtensa   | `~/esp/esp-idf/.../portable/xtensa/`（IDF 树）                                                             | 读者已在 ch16/17 逐行读过，只作锚点                                               |
| Cortex-M | `~/code/FreeRTOS-Kernel/portable/GCC/ARM_CM4F/`（vanilla 树）                                              | STM32F407=Cortex-M4F 的官方指定 port；同目录风格还有 `ARM_CM3`（mps2-an385 对应） |
| RISC-V   | `~/esp/esp-idf/.../portable/riscv/`（IDF 树）+ `~/code/FreeRTOS-Kernel/portable/GCC/RISC-V/`（vanilla 树） | RV 有两个真实形态，都摘——对照本身比结论更有教学价值                               |

> [!note] 为什么 Cortex-M 摘 vanilla V11.3.0 而不是某个发行版里的旧版
> IDF 树里没有 ARM port 是硬件事实（Espressif 不产 ARM 芯片），不是遗漏。vanilla V11.3.0 是当前主线，`ARM_CM4F/port.c` 与 STM32 生态里流传多年的 V10.x 版本在 PendSV/SysTick/BASEPRI 这些核心机制上逐行同源——本章摘录的每一行都能在读者将来的 STM32 工程里对上。

### 2. port 层契约回顾：移植 = 填一张清单

[[ch16-portmacro-port-contract|FreeRTOS 系列（十六）]]已经把契约面拆完，这里只把清单钉在墙上（后文四组对照都会回指它）：

| 契约槽位                                   | 内核的期待                       | 本章对应小节 |
| ------------------------------------------ | -------------------------------- | ------------ |
| `portYIELD()` / FROM_ISR / WITHIN_API      | 三个上下文里各自"安全地发起切换" | 12.2         |
| `pxPortInitialiseStack()`                  | 新任务的"出生帧"                 | 12.3         |
| `portENTER/EXIT_CRITICAL()`                | 互斥（屏蔽什么、屏蔽到什么程度） | 12.4         |
| `xPortStartScheduler()`                    | tick 源装配 + 首任务启动         | 12.2/12.5    |
| `portSTACK_TYPE`/`GROWTH`/`BYTE_ALIGNMENT` | 栈的单位、方向、对齐             | 12.3         |

内核主体（`tasks.c`/`queue.c`）一行汇编不写；**所谓移植，就是把这张表在每个槽位上填上一个符合本架构硬件事实的答案**。下面四组对照，就是三种架构在四个最重要槽位上的答案并排。

---

## 12.2 对照一：上下文切换的触发——三种"让切换最后发生"的办法

先给结论大表，再逐列展开：

| 维度          | Xtensa（IDF，读者已知）              | Cortex-M（ARM_CM4F）                          | RISC-V（IDF / vanilla）                            |
| ------------- | ------------------------------------ | --------------------------------------------- | -------------------------------------------------- |
| `portYIELD()` | `vPortYield()` 汇编同步切换          | 写 ICSR 挂起 PendSV，**延迟**到异常返回时切换 | IDF：给自己发软中断再自旋等；vanilla：`ecall` 陷阱 |
| "pend"的载体  | 软件变量 `port_switch_flag[core]`    | **硬件位**：NVIC ICSR 的 PENDSVSET            | `xPortSwitchFlag[core]`                            |
| 切换执行者    | `_frxt_int_exit`（最外层中断退出时） | PendSV 异常处理程序（NVIC 保证最低优先级）    | `rtos_int_exit`（nesting 归零时）                  |
| 首任务启动    | `call0 _frxt_dispatch`               | `svc 0` → SVCall handler 恢复                 | 阈值/中断使能后调 `vPortYield()` 等软中断落地      |

### 1. Cortex-M 列：PendSV 与"故意最低优先级"的完整推导

`ARM_CM4F/portmacro.h` 的 `portYIELD()`，全文三个动作：

```c
#define portYIELD()                                     \
    {                                                   \
        /* Set a PendSV to request a context switch. */ \
        portNVIC_INT_CTRL_REG = portNVIC_PENDSVSET_BIT; \
        __asm volatile ( "dsb" ::: "memory" );          \
        __asm volatile ( "isb" );                       \
    }
/* portNVIC_INT_CTRL_REG  = *(volatile uint32_t *)0xe000ed04  （SCB->ICSR）
   portNVIC_PENDSVSET_BIT = 1UL << 28UL                        */
```

往 `0xE000ED04`（ICSR，[[ch07-interrupts-nvic|第七章]]的 NVIC 寄存器组成员）写 bit28，把 PendSV 异常置为 pending——**然后立刻返回继续执行**。真正的切换发生在 PendSV 被服务的那一刻。为什么这么绕？核心在 `port.c` 启动时的这两行：

```c
/* Make PendSV and SysTick the lowest priority interrupts, and make SVCall
 * the highest priority. */
portNVIC_SHPR3_REG |= portNVIC_PENDSV_PRI;    /* 255 << 16：PendSV = 最低 */
portNVIC_SHPR3_REG |= portNVIC_SYSTICK_PRI;   /* 255 << 24：SysTick = 最低 */
portNVIC_SHPR2_REG = 0;                       /* SVCall = 最高 */
```

PendSV 被故意设成**全系统最低优先级**（255）。推导链条如下：

1. **切换代码假设"现场干净"**。`xPortPendSVHandler` 一进门就读 PSP、往任务栈存 R4-R11——它假设"被打断的是线程模式下的任务代码"。如果 PendSV 能抢占一个跑到一半的外设 ISR，它会把这个半途 ISR 的 MSP 世界误当任务现场，栈账本立刻错乱。
2. **最低优先级 = 永远排在队尾**。任何 ISR 里调 `portYIELD_FROM_ISR()` 只是 pend 一下；NVIC 发现 PendSV 优先级最低，只要还有别的中断活跃/挂起，就不让它上。等**所有**中断退完，PendSV 才执行——此刻 CPU 必然回到线程模式（或即将回到），现场假设成立。
3. **tail-chaining 把队尾等待变成零开销**。[[ch03-arm-cortex-m-anatomy|第三章]]讲过尾部链：ISR 返回瞬间若 PendSV pending，硬件跳过出栈/入栈来回，约 6 周期直接进入 PendSV。"排最后"不仅正确，还几乎免费。
4. **与临界区正交**。PendSV handler 内部调 `vTaskSwitchContext` 前会抬 BASEPRI（见 12.4），屏蔽"内核可管理"的那部分中断防重入；更高优先级中断仍可打断 PendSV 本身——安全，因为按契约它们不碰内核 API。

一个隐藏彩蛋：为什么 SVCall 要最高优先级？它只干一件事——调度器启动时 `prvPortStartFirstTask()` 里的 `svc 0` 触发 `vPortSVCHandler` 恢复第一个任务：

```asm
/* prvPortStartFirstTask（port.c，节选） */
ldr r0, =0xE000ED08      /* VTOR */
ldr r0, [r0]             /* 向量表基址 */
ldr r0, [r0]             /* 表第 0 项 = 初始 MSP */
msr msp, r0              /* MSP 复位回栈顶——启动期的 C 栈作废 */
...
svc 0                    /* 触发 SVCall → vPortSVCHandler 恢复首任务 */
```

首任务恢复路径必须一次跑完不被打断（此刻调度器数据处于"半启动"状态），最高优先级保证了这一点。注意第一行起手式：**从 VTOR 读向量表第 0 项来复位 MSP**——[[ch04-baremetal-boot|第四章]]"向量表 0 号槽是初始 MSP"的知识，在官方 port 里被用来"擦掉启动栈"。

### 2. Xtensa 列：读者已知，只放锚点

Xtensa 的答案你已经拆到指令级（[[ch17-xtensa-port-internals|第十七章]]）：任务态 `vPortYield()` 构造 solicited 帧同步直切；ISR 里 `portYIELD_FROM_ISR()` 只置 `port_switch_flag[core]`，由**最外层中断退出点** `_frxt_int_exit` 消费。和 PendSV 完全同构的语义，只是"保证最后"的手段从硬件优先级换成了软件 flag + 退出点检查。

### 3. RISC-V 列：同一问题的两个真实答案

IDF 的 RV port（跑在 ESP32-C3/C6/P4 等 RV 芯片上）任务态的 `vPortYield()`（`portable/riscv/port.c`）很妙——它**不在调用点切，而是给自己发一个软件中断，然后原地自旋等它落地**：

```c
void vPortYield(void)
{
    BaseType_t coreID = xPortGetCoreID();

    if (port_uxInterruptNesting[coreID]) {
        vPortYieldFromISR();              /* 已在 ISR 里：只置标志 */
    } else {
        esp_crosscore_int_send_yield(coreID);   /* 给自己发软中断 */
        /* 软中断触发有 3~4 条指令延迟；自旋确认它已发生，否则
           vTaskDelay() 可能在真正切换前又执行 1~2 条指令 */
        while (port_xSchedulerRunning[coreID] && port_uxCriticalNesting[coreID] == 0
               && crosscore_int_ll_get_state(coreID) != 0) {}
    }
}

void vPortYieldFromISR( void )            /* "pend" 的全部实现 */
{
    BaseType_t coreID = xPortGetCoreID();
    port_xSchedulerRunning[coreID] = 1;
    xPortSwitchFlag[coreID] = 1;          /* 就这一行，立刻返回 */
}
```

消费点在 `portasm.S` 的 `rtos_int_exit`（中断退出例程）——与 Xtensa 的 `_frxt_int_exit` 逐语义对应：

```asm
/* rtos_int_exit（portasm.S，节选） */
lw      a0, 0(a2)                  /* port_uxInterruptNesting[coreID] */
addi    a0, a0, -1
sw      a0, 0(a2)
bnez    a0, rtos_int_exit_end      /* 还有外层中断：不切 */
...
lw      a1, 0(s6)                  /* a1 = xPortSwitchFlag[coreID] */
bnez    a1, context_switch_requested
...
context_switch_requested:
    call    vTaskSwitchContext      /* 内核选任务 */
    sw      zero, 0(s6)             /* xPortSwitchFlag[coreID] = 0 */
...
    lw      a0, 0(a0)               /* 新 TCB */
    lw      sp, 0(a0)               /* ★ 换栈：sp = 新任务 pxTopOfStack */
```

而 **vanilla 通用 RV port** 给出了第三种答案：`portYIELD()` 就是一条 `ecall`（`GCC/RISC-V/portmacro.h`）——用环境调用陷阱制造一次"同步异常"，在陷阱处理程序里走 save/switch/restore。最朴素，也最符合 RISC-V "trap 统一入口"的架构哲学（[[ch09-riscv-gd32-contrast|第九章]]的 mtvec 直入式分发）。

> [!tip] 三列合读：一个问题，三种硬件答案
> "如何保证上下文切换发生在所有 ISR 之后？"——Cortex-M 用**硬件优先级仲裁**回答（PendSV 焊死在最低档，NVIC 替你排队）；Xtensa 和 RISC-V（IDF 版）没有这件外设，就用**软件 flag + 中断退出点检查**回答（`port_switch_flag` / `xPortSwitchFlag`，谁最后退出中断谁消费）；vanilla RV 干脆用 `ecall` 把切换做成同步陷阱。三种答案殊途同归，而选择哪一种，完全由架构给了你什么硬件决定。

---

## 12.3 对照二：上下文本体——硬件替你存多少，软件补多少

### 1. 三列保存清单

| 保存层     | Xtensa（IDF）                             | Cortex-M（ARM_CM4F）                                | RISC-V（IDF）                                        |
| ---------- | ----------------------------------------- | --------------------------------------------------- | ---------------------------------------------------- |
| 硬件自动存 | **零个**——向量前几条指令手工搬            | **8 个**：R0-R3/R12/LR/PC/xPSR（第三章实测帧）      | **零个**——trap 入口汇编手工搬                        |
| 软件补存   | 窗口 spill（深度相关）+ SAR/ZOL/THREADPTR | R4-R11 + EXC_RETURN（`stmdb r0!, {r4-r11, r14}`）   | **全部 32 个 GPR 槽** + mepc/mstatus/mtvec/mcause 等 |
| FPU/协处理 | CPSA 惰性所有权（协处理器异常驱动）       | lazy stacking：EXC_RETURN bit4 判断，按需补 s16-s31 | 启动即禁用 FPU/DSP/PIE，用时陷阱恢复                 |
| 中断栈     | 每核独立 `port_IntStack`                  | 硬件双栈：PSP（任务）/MSP（handler 自动切换）       | 每核独立 `xIsrStack`（`rtos_int_enter` 换 sp）       |
| 帧大小     | 中断帧 192B / solicited 帧 32B            | 硬件 32B + 软件 36B = **68B**（17 字）              | GPR 区 128B（SAVE_REGS=32）+ CSR 区                  |

### 2. Cortex-M：第三章的 8 字帧 + AAPCS 的 callee-saved

PendSV handler 全文值得整段贴（`ARM_CM4F/port.c`，naked 函数）：

```asm
xPortPendSVHandler:
    mrs   r0, psp                  /* 取任务栈指针（硬件已压好 8 个） */
    isb
    ldr   r3, =pxCurrentTCB
    ldr   r2, [r3]
    tst   r14, #0x10               /* EXC_RETURN bit4=0？→ 任务用过 FPU */
    it    eq
    vstmdbeq r0!, {s16-s31}        /*   是：补存浮点高半区（惰性压栈） */
    stmdb r0!, {r4-r11, r14}       /* ★ 软件补存 callee-saved + EXC_RETURN */
    str   r0, [r2]                 /* pxCurrentTCB->pxTopOfStack = sp */
    stmdb sp!, {r0, r3}
    mov   r0, #<configMAX_SYSCALL_INTERRUPT_PRIORITY>
    msr   basepri, r0              /* 抬 BASEPRI：调度器数据临界区 */
    dsb
    isb
    bl    vTaskSwitchContext       /* 纯 C 选任务（内核侧零汇编） */
    mov   r0, #0
    msr   basepri, r0
    ldmia sp!, {r0, r3}
    ldr   r1, [r3]                 /* 新 TCB */
    ldr   r0, [r1]                 /* 新栈顶 */
    ldmia r0!, {r4-r11, r14}       /* 恢复 callee-saved */
    tst   r14, #0x10
    it    eq
    vldmiaeq r0!, {s16-s31}
    msr   psp, r0                  /* 换回任务栈 */
    isb
    bx    r14                      /* 异常返回：硬件自动出栈 8 个字 */
```

对照 [[ch03-arm-cortex-m-anatomy|第三章]]的知识逐格对账：

- **硬件压的 8 个**（R0-R3/R12/LR/PC/xPSR）恰好是 AAPCS 的 caller-saved 集——第三章 3.3 说"这不是巧合，是 ABI 与架构的对偶设计"；RTOS port 是这个对偶的直接受益者：**软件只需补 callee-saved 的 R4-R11**，9 条存取指令（含 EXC_RETURN）办完。第三章 gdb 实验里逐字验证过的那 8 个魔数，就是这里硬件替你写进任务栈的前 8 个字。
- **EXC_RETURN 存进帧里**是 Cortex-M port 的独门细节：每个任务自己记住该用哪种异常返回（0xFFFFFFFD=PSP 线程态；FPU 任务是 0xFFFFFFED），恢复时 `bx r14` 让硬件按帧里的值走返回序列——[[ch03-arm-cortex-m-anatomy|第三章]]实测过的 `lr = 0xfffffff9` 魔数，在 port 里成了**逐任务保存的状态字**。
- **FPU 是惰性的**：硬件 lazy stacking（FPCCR 的 ASPEN/LSPEN，启动时 port 显式打开）只在任务真用过 FPU 时（EXC_RETURN bit4=0）才补 64 字节的 s16-s31——与 Xtensa 的协处理器所有权方案（[[ch17-xtensa-port-internals|第十七章]]）异曲同工：不用浮点的任务永远不付这笔钱。

### 3. RISC-V：没有任何硬件代劳，全部软件

IDF RV 的 trap 入口（`components/riscv/vectors.S`）是"全软件保存"的标本：

```asm
.equ SAVE_REGS,  32
.equ CONTEXT_SIZE, (SAVE_REGS * 4)     /* 通用寄存器区 128 字节 */

.macro save_general_regs cxt_size=CONTEXT_SIZE
    addi sp, sp, -\cxt_size
    sw   ra, RV_STK_RA(sp)
    sw   tp, RV_STK_TP(sp)
    sw   t0, RV_STK_T0(sp)
    ...                                  /* t1-t6, s0-s11, a0-a7 逐个存 */
    sw   t6, RV_STK_T6(sp)
    ...
    csrr t0, mepc                         /* CSR 也自己存 */
    sw   t0, RV_STK_MEPC(sp)
    csrr t0, mstatus
    sw   t0, RV_STK_MSTATUS(sp)
    ...
```

RISC-V 的 trap 硬件只做三件事：PC → `mepc`、mstatus → `mcause`/`mstatus`（MIE 挪进 MPIE、MPP 记下来的模式）、跳 `mtvec`——**一个通用寄存器都不存**（对照：Cortex-M 存 8 个，Xtensa 靠窗口机制连"存"的概念都不同）。所以 RV port 的帧最大（GPR 区 128B + CSR 区），但换来帧布局完全软件可控。vanilla RV port（`GCC/RISC-V/portContext.h`）同样是 `x1、x5-x31` 全家桶 + mstatus + 返回地址，两边同理。

### 4. 三列栈帧布局对照图

```text
   Cortex-M（任务被切走时的 PSP 帧）      RISC-V（RvExcFrame，任务栈上）     Xtensa（XtExcFrame）
   高地址                                 高地址                              高地址
   ┌────────────────┐                    ┌────────────────┐                 ┌────────────────┐
   │ xPSR           │ ← 硬件压           │ mtval/mcause.. │ ← trap 汇编存   │ TIE/NCP 扩展区 │
   │ PC             │ ← 硬件压           │ mstatus        │                 │ sar/lbeg/lend  │
   │ LR             │ ← 硬件压           │ mepc           │                 │ a2..a15        │
   │ R12/R3/R2/R1   │ ← 硬件压           │ gp/tp          │                 │ a0/a1/ps/pc    │
   │ R0             │ ← 硬件压           │ t*/s*/a* 全 32 │                 │ exit(派发器)  │
   │ EXC_RETURN     │ ← 软件存           │ 槽（128B）     │                 │ (192B 定长)    │
   │ R4..R11        │ ← 软件存           └────────────────┘                 └────────────────┘
   │ [s16-s31]      │ ← FPU 任务才存     （sp 隐含：恢复帧后 addi sp 回来） （窗口溢出部分散在
   └────────────────┘                                                       各层栈帧 base save 区）
   17 字=68B（整数任务）
```

### 5. 出生帧：`pxPortInitialiseStack()` 三列对照

新任务的栈要伪造成"仿佛刚被打断"。ARM 版（`port.c`）：

```c
*pxTopOfStack = portINITIAL_XPSR;                   /* 0x01000000：T 位=1，其余 0 */
pxTopOfStack--;
*pxTopOfStack = ((StackType_t) pxCode) & portSTART_ADDRESS_MASK;  /* PC */
pxTopOfStack--;
*pxTopOfStack = (StackType_t) portTASK_RETURN_ADDRESS;            /* LR：防任务 return */
pxTopOfStack -= 5;
*pxTopOfStack = (StackType_t) pvParameters;          /* R0：任务参数 */
pxTopOfStack--;
*pxTopOfStack = portINITIAL_EXC_RETURN;              /* 0xfffffffd：PSP 线程态 */
pxTopOfStack -= 8;                                   /* R4-R11 空位 */
```

每一行都是第三章的知识点：`xPSR=0x01000000` 就是那个 bit24 T 位（实测帧值 `0x41000000` 的近亲）；`EXC_RETURN=0xFFFFFFFD` 编码"返回线程态、用 PSP"。RV 版（`portable/riscv/port.c`）则是往 `RvExcFrame` 里填 CSR 与参数寄存器：

```c
frame->mepc = (UBaseType_t)pxCode;          /* mret 后第一条指令 = 任务函数 */
frame->a0   = (UBaseType_t)pvParameters;    /* RV 调用约定：a0 = 第一参数 */
frame->gp   = (UBaseType_t)&__global_pointer$;
frame->tp   = (UBaseType_t)threadptr_reg_init;   /* TLS 基址 */
```

加上栈顶的协处理器保存区与 TLS 区（布局与 Xtensa 的 CPSA/TLS 三层同构，见 [[ch16-portmacro-port-contract|第十六章]] 16.6）。**三种架构用三种帧格式干同一件事：把"从未运行"描述成"恰好停在第一行之前"**——首任务启动因此不需要任何特殊指令（ARM 的 `svc 0`、Xtensa 的 `call0 _frxt_dispatch`、RV 的"等软中断落地"，都只是触发第一次 restore）。

---

## 12.4 对照三：临界区——"关中断"的三种精度

### 1. Cortex-M：BASEPRI，"不是关中断，是关一部分"

`ARM_CM4F/portmacro.h` 的临界区实现是全章最精巧的一段：

```c
#define portDISABLE_INTERRUPTS()    vPortRaiseBASEPRI()
#define portENABLE_INTERRUPTS()     vPortSetBASEPRI( 0 )
#define portSET_INTERRUPT_MASK_FROM_ISR()      ulPortRaiseBASEPRI()
#define portCLEAR_INTERRUPT_MASK_FROM_ISR( x ) vPortSetBASEPRI( x )

portFORCE_INLINE static void vPortRaiseBASEPRI( void )
{
    __asm volatile
    (
        "   mov %0, %1                      \n"
        "   msr basepri, %0                 \n"   /* BASEPRI = configMAX_SYSCALL_INTERRUPT_PRIORITY */
        "   isb                             \n"
        "   dsb                             \n"
        : "=r" ( ulNewBASEPRI )
        : "i" ( configMAX_SYSCALL_INTERRUPT_PRIORITY ) : "memory"
    );
}
```

[[ch03-arm-cortex-m-anatomy|第三章]] 3.1 挂过账的 BASEPRI 在此兑现：**把 BASEPRI 设为阈值 N，优先级数值 ≥ N 的中断全部被屏蔽，数值 < N（更高优先级）的照常穿透**。于是 Cortex-M 的"关中断"其实是"关一部分"：

- `configMAX_SYSCALL_INTERRUPT_PRIORITY` 是一条**可配置的分界线**：线以下（含）的中断允许被内核屏蔽、因此允许调 `...FromISR()` API；线以上的中断永不屏蔽、永不许碰内核——实时性要求极高的中断（电机 PWM 精确关断之类）放在线上面，FreeRTOS 的任何临界区都挡不住它。
- port 还带运行时防护：`vPortValidateInterruptPriority()` 在 FromISR API 入口断言"你的优先级没越线"（`configASSERT_DEFINED=1` 时）。
- 有趣的细节写在 `xPortSysTickHandler` 注释里：SysTick 优先级是最低档（255），**能打断它的中断必然优先级更高，而 BASEPRI 挡不住的恰是这些更高优先级中断**。于是在 SysTick handler 里 DISABLE→ENABLE 一开一关，影响不到任何"本可能抢进来"的中断——才敢省掉保存/恢复旧屏蔽值这一步。

单核 ARM 上"关中断=独占"，临界区只需关中断+嵌套计数（`vPortEnterCritical` 全文四行：DISABLE、`uxCriticalNesting++`、断言不在 ISR；`vPortExitCritical` 减到 0 才 ENABLE）——[[ch18-critical-sections-spinlocks|FreeRTOS 系列（十八）]]对照过的 IDF spinlock 方案（关本核中断 + 原子自旋）在这里是"单核退化形态"。

### 2. Xtensa：`rsil` 抬 INTLEVEL（读者已知）

一条指令的艺术：`rsil` 原子地读旧 PS 并把 `PS.INTLEVEL` 设为 `XCHAL_EXCM_LEVEL`（=3）。分界线焊死在芯片配置里、不可配——与 ARM 的"可配 BASEPRI"是同一概念的一硬一软两种落地（[[ch16-portmacro-port-contract|第十六章]] 16.4 有完整对照表）。

### 3. RISC-V：两个 port，两种答案——这里有个惊喜

**vanilla RV port** 的答案最直白（`GCC/RISC-V/portmacro.h`）：

```c
#define portDISABLE_INTERRUPTS()    __asm volatile ( "csrc mstatus, 8" )   /* 清 MIE */
#define portENABLE_INTERRUPTS()     __asm volatile ( "csrs mstatus, 8" )   /* 置 MIE */
```

mstatus 的 bit3（MIE）一关，机器态全部中断全灭——**全开关，无差别**。这是教科书式的"RISC-V 临界区"。

**但 IDF 的 RV port 不是这么干的**。看 `portable/riscv/portmacro.h`：

```c
#define portDISABLE_INTERRUPTS()   portSET_INTERRUPT_MASK_FROM_ISR()   /* 别名！ */
```

跟进去（`port.c` → `rv_utils.h`/`interrupt_intc.h`）：

```c
UBaseType_t xPortSetInterruptMaskFromISR(void)
{
    UBaseType_t prev_int_level = 0;
    int_level = RVHAL_EXCM_LEVEL;               /* rv_utils.h: RVHAL_EXCM_LEVEL = 4 */
    prev_int_level = rv_utils_set_intlevel_regval(int_level);
    return prev_int_level;
}

/* components/riscv/include/esp_private/interrupt_intc.h */
FORCE_INLINE_ATTR uint32_t rv_utils_set_intlevel_regval(uint32_t intlevel)
{
    uint32_t old_mstatus = RV_CLEAR_CSR(mstatus, MSTATUS_MIE);   /* ① MIE 暂关：原子地改阈值 */
    uint32_t old_thresh = REG_READ(INTERRUPT_CURRENT_CORE_INT_THRESH_REG);
    rv_utils_restore_intlevel_regval(intlevel);                  /* ② 写中断矩阵的阈值寄存器 */
    RV_SET_CSR(mstatus, old_mstatus & MSTATUS_MIE);              /* ③ 恢复 MIE */
    return old_thresh;
}
```

ESP 的 RV 芯片把中断控制器（中断矩阵）做了一个**阈值寄存器**：优先级 ≤ 阈值的中断被挡、更高的放行。IDF 把它抬到 4——**级别 1~3（FreeRTOS 可管理区）挡住，4 级以上穿透**。mstatus.MIE 只在改阈值的一瞬间当原子性护栏用。也就是说：**IDF 在 RISC-V 上手工复刻了一个 BASEPRI/INTLEVEL**——因为 Espressif 和 ARM/Xtensa 一样，需要"高级别中断不被内核挡"的能力，而 vanilla 的 MIE 全开关给不了。

三列临界区对照：

| 维度       | Xtensa（IDF）                | Cortex-M（ARM_CM4F）                   | RISC-V vanilla    | RISC-V（IDF）                         |
| ---------- | ---------------------------- | -------------------------------------- | ----------------- | ------------------------------------- |
| 屏蔽机制   | `rsil` 设 PS.INTLEVEL=3      | BASEPRI 按优先级数值                   | mstatus.MIE 清零  | 中断矩阵 INT_THRESH 寄存器 = 4        |
| 屏蔽精度   | 按级别（1-3 挡，4+ 穿透）    | 按优先级数值（阈值可配）               | 全开关            | 按级别（1-3 挡，4+ 穿透）             |
| 分界线     | 芯片配置固定（EXCM_LEVEL）   | `configMAX_SYSCALL_INTERRUPT_PRIORITY` | 无（全关）        | 固定（RVHAL_EXCM_LEVEL=4）            |
| 越线防护   | 分配器禁止 >3 级挂 C handler | `vPortValidateInterruptPriority()`     | 无                | 高级别中断走另一套汇编向量            |
| 临界区形态 | 关中断 + spinlock（SMP）     | 关中断 + 嵌套计数（单核）              | 关中断 + 嵌套计数 | 关中断 + spinlock（SMP）/计数（单核） |

> [!tip] 一条主线串起三架构
> 临界区的本质问题是"内核需要一段不可打断的窗口，但硬实时中断不能陪葬"。ARM 用 BASEPRI 回答，Xtensa 用 INTLEVEL 回答，Espressif 的 RISC-V 用外设阈值寄存器回答——**而 RISC-V ISA 本身（vanilla port 的 MIE 全开关）没有回答**。port 层的功力，恰恰体现在架构没给答案时，port 作者用什么硬件拼出一个来。

---

## 12.5 对照四：tick 源——每个架构送的那块"表"

RTOS 需要一块周期性中断的表。三种架构送的表不一样：

| 维度       | Cortex-M                         | Xtensa（IDF）                        | RISC-V                                   |
| ---------- | -------------------------------- | ------------------------------------ | ---------------------------------------- |
| tick 外设  | **SysTick**（核内，架构标配）    | SYSTIMER 外设（默认）/ CCOUNT 比较器 | mtime/mtimecmp（CLINT）；IDF 用 SYSTIMER |
| 位置       | SCS 私有外设区 0xE000E010 起     | 芯片级外设                           | CLINT 内存映射 / 芯片级外设              |
| 计数器位数 | 24 位（`portMAX_24_BIT_NUMBER`） | SYSTIMER 52 位                       | mtime 64 位（port 里分高低 32 位两半读） |
| 中断号     | 向量表 15 号（架构保留）         | 外设中断，经分配器挂电平 1/3         | machine timer 中断（ECLIC/CLINT 编号）   |

### 1. Cortex-M：SysTick 是"标配礼物"，这就是第八章学的理由

ARM_CM4F port 自带完整的 SysTick 驱动——寄存器组就是 [[ch08-timer-systick|第八章]]源码级跑过的那三个（CTRL `0xE000E010` / LOAD `0xE000E014` / VAL `0xE000E018`）：

```c
#define portNVIC_SYSTICK_CTRL_REG           ( *( ( volatile uint32_t * ) 0xe000e010 ) )
#define portNVIC_SYSTICK_LOAD_REG           ( *( ( volatile uint32_t * ) 0xe000e014 ) )
#define portNVIC_SYSTICK_CURRENT_VALUE_REG  ( *( ( volatile uint32_t * ) 0xe000e018 ) )
```

tick 中断处理（`xPortSysTickHandler`）是整个 Cortex-M port 最能体现设计品味的函数：

```c
void xPortSysTickHandler( void )
{
    /* The SysTick runs at the lowest interrupt priority, so when this interrupt
     * executes all interrupts must be unmasked. */
    portDISABLE_INTERRUPTS();
    {
        if( xTaskIncrementTick() != pdFALSE )
        {
            portNVIC_INT_CTRL_REG = portNVIC_PENDSVSET_BIT;  /* pend PendSV，延迟切换 */
        }
    }
    portENABLE_INTERRUPTS();
}
```

tick 到点 → `xTaskIncrementTick()`（内核记账）→ 需要切换就 pend PendSV（12.2 的机制）。tick 自身优先级最低——晚几个周期无妨，时间已经在计数器里；真正的切换由 PendSV 兜底。**"SysTick 是 Cortex-M 的标配礼物"**：任何厂商的 Cortex-M 芯片都有这三个寄存器，port 因此零改动通吃全系列——这正是[[ch08-timer-systick|第八章]]花一整章学它的回报：学完那章，你已经能逐行读懂官方 port 的 tick 装配（`vPortSetupTimerInterrupt()`：LOAD = 时钟/Hz - 1，CTRL = CLK|TICKINT|ENABLE）。

### 2. Xtensa 与 RISC-V：没有标配，各显神通

Xtensa 没有 SysTick 等价物，IDF 默认接 SYSTIMER 外设、每核一个 alarm（老路径 CCOUNT/CCOMPARE 保留在 `portasm.S`，带"追赶循环"补拍——[[ch17-xtensa-port-internals|第十七章]] 17.7）。

RISC-V 的标准答案是 **machine timer**：vanilla port（`GCC/RISC-V/port.c`）要求 FreeRTOSConfig.h 提供 `configMTIME_BASE_ADDRESS` / `configMTIMECMP_BASE_ADDRESS`，port 自己读写 64 位 mtime/mtimecmp 生成 tick——GD32VF103 走的就是这一族（mtime 经 ECLIC 的 machine timer 中断进 CPU，[[ch09-riscv-gd32-contrast|第九章]]对照过 ECLIC 与 NVIC 的分野）。vanilla 树 `GCC/RISC-V/chip_specific_extensions/` 里的 `RISCV_MTIME_CLINT_no_extensions` 等目录，就是"不同芯片的 mtime 长在哪"的适配清单——RISC-V 的外设不在架构规范里，port 必须为每块芯片回答"表在哪"。IDF 的 RV 芯片则统一用 SYSTIMER（`port_systick.c`，`CONFIG_FREERTOS_SYSTICK_USES_SYSTIMER`），与 Xtensa 侧共用同一份文件。

---

## 12.6 三架构 port 对照总表

收官大表——四组对照浓缩成一张，全部条目可在 12.1 的两棵树里复核：

| 维度                   | Xtensa（IDF v6.0.2）           | Cortex-M（vanilla V11.3.0 ARM_CM4F）        | RISC-V（IDF / vanilla）                |
| ---------------------- | ------------------------------ | ------------------------------------------- | -------------------------------------- |
| `portSTACK_TYPE`       | `uint8_t`（栈深=字节）         | `uint32_t`（栈深=字）                       | IDF `uint8_t` / vanilla `uint32_t`     |
| 栈对齐                 | 16（窗口 ABI）                 | 8                                           | 16                                     |
| 切换触发               | 软中断 + `port_switch_flag`    | PendSV（ICSR bit28）+ 最低优先级            | 软中断 + `xPortSwitchFlag` / `ecall`   |
| 切换执行者             | `_frxt_int_exit`               | `xPortPendSVHandler`                        | `rtos_int_exit`                        |
| 首任务启动             | `call0 _frxt_dispatch`         | `svc 0` → SVCall（最高优先级）              | 使能中断后 `vPortYield()` 等软中断落地 |
| 硬件自动保存           | 0 个                           | 8 个（caller-saved 全集）                   | 0 个                                   |
| 软件保存               | 窗口 spill + 特殊寄存器        | R4-R11 + EXC_RETURN                         | 全部 GPR + mepc/mstatus 等             |
| 整数任务帧             | 192B（中断）/ 32B（solicited） | 68B（17 字）                                | ~128B+（32 GPR 槽 + CSR）              |
| FPU 策略               | 协处理器所有权，惰性           | lazy stacking（EXC_RETURN bit4）            | 启动禁用，用时陷阱恢复                 |
| 双栈                   | 软件切每核 `port_IntStack`     | 硬件 MSP/PSP                                | 软件切每核 `xIsrStack`                 |
| 关中断                 | `rsil` INTLEVEL=3              | BASEPRI=可配阈值                            | vanilla：MIE 全开关；IDF：INT_THRESH=4 |
| ISR/内核 API 分界      | EXCM_LEVEL（固定）+ 分配器     | `configMAX_SYSCALL_INTERRUPT_PRIORITY`+断言 | MIE 无分界 / IDF 阈值（固定）          |
| 临界区                 | 关中断+spinlock（SMP）         | 关中断+嵌套计数                             | 同 Xtensa（IDF）/ 同 ARM（vanilla）    |
| tick 源                | SYSTIMER / CCOUNT              | SysTick（核内标配）                         | mtime/mtimecmp；IDF SYSTIMER           |
| 计数器位数             | 52 / 32 位                     | 24 位                                       | 64 位                                  |
| `portYIELD_WITHIN_API` | 跨核软中断（借中断重开时机）   | `portYIELD()`（pend 天然可延迟）            | IDF `portYIELD()`（内含软中断+自旋）   |
| SMP 形态               | 双核原生（每核数组）           | 单核（上游 SMP 树另算）                     | IDF 多核原生 / vanilla 单核            |

读表的两个规律与 [[ch16-portmacro-port-contract|第十六章]] 16.9 一致并再进一层：**架构事实决定下限**（有无硬件压栈、有无按级屏蔽、有无标配定时器，直接决定 port 的形状），**生态需求决定上限**（SMP、高级别中断穿透、字节栈单位，是厂商在架构没给的地方亲手造出来的）。IDF 的 RISC-V port 尤其值得回味：它在"最精简的 ISA"上复刻出了 BASEPRI 和 PendSV 语义——**port 层是架构不足之处的补全层**。

---

## 12.7 裸机毕业检查清单与系列回顾

### 1. 五项自测：不看资料，你能回答几题

系列承诺的"裸机内部"知识，收敛为五项。每项给一道判定性问题，答案都在前文链接的章节里：

| #   | 主题       | 自测问题                                                                                        | 出处                                                                   |
| --- | ---------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| 1   | 向量表     | Cortex-M 向量表第 0 项是什么？RISC-V 对应物是什么？Thumb bit 在哪一位？                         | [[ch03-arm-cortex-m-anatomy\|ch3]] / [[ch09-riscv-gd32-contrast\|ch9]] |
| 2   | 启动文件   | `.data` 的 LMA 与 VMA 分别在哪？谁在什么时候搬运？Reset_Handler 为什么必须汇编写 `.data` 拷贝？ | [[ch04-baremetal-boot\|ch4]]                                           |
| 3   | 链接脚本   | `> RAM AT > FLASH` 一行做了什么声明？`KEEP` 和 `LOADADDR` 各防哪个经典翻车？                    | [[ch04-baremetal-boot\|ch4]]                                           |
| 4   | 上下文切换 | 一个任务被切走时，Cortex-M 硬件存哪 8 个、软件补哪些？RISC-V 为什么全软件？                     | ch3 / 本章 12.3                                                        |
| 5   | 临界区     | BASEPRI/INTLEVEL/INT_THRESH/MIE 各屏蔽"哪一部分"中断？为什么高级别中断必须穿透？                | 本章 12.4                                                              |

五题全过，你就具备了一个 port 维护者的底层视野：再遇到"任务栈溢出但查不到"、"ISR 里调 API 死机"、"换芯片 port 起不来"，你能从帧布局、屏蔽阈值、tick 装配这三层往下怀疑，而不是停在应用层猜。

### 2. 系列回顾：从万用表到 port 对照的知识弧线

- **[[ch01-roadmap-and-boards|第一章]]**定下双架构学习法时，"PendSV vs machine timer"只是清单上的一行字；现在它是 12.2/12.5 里两份真实汇编的对垒。
- **[[ch02-tools-multimeter-la|第二章]]**驯化万用表与逻辑分析仪（tcpdump 思维）；**[[ch06-uart-protocol|第六章]]**拆 UART 成帧——观测工具贯穿始终，本章虽以源码为主，gdbstub 仍是同一家族。
- **[[ch03-arm-cortex-m-anatomy|第三章]]**实测的 8 字异常帧 → 12.3 PendSV handler 的前 8 个字；**[[ch04-baremetal-boot|第四章]]**的向量表 0 号槽 → `prvPortStartFirstTask` 的 MSP 复位起手式；**[[ch07-interrupts-nvic|第七章]]**的 NVIC → ICSR/SHPR3/BASEPRI；**[[ch08-timer-systick|第八章]]**的 SysTick → 12.5 的官方 tick 驱动。
- **[[ch09-riscv-gd32-contrast|第九章]]**的 mtvec/mepc/mcause → 12.3 的 RvExcFrame 与 vanilla ecall；**[[ch10-i2c-spi-theory|第十章]]**（I2C/SPI）与**[[ch11-debug-swd-jtag|第十一章]]**（SWD/JTAG）是外设与调试两翼，真机回填后与本章知识合成完整闭环。
- 软件侧的会师：FreeRTOS 系列（[[ch7-context-switch-deep-dive|切换]]、[[ch16-portmacro-port-contract|契约]]、[[ch17-xtensa-port-internals|Xtensa 端口]]、[[ch18-critical-sections-spinlocks|临界区]]）给了我们一条腿和一整套方法论——本章把另外两条腿接上，三足鼎立。

从"万用表怎么读电压"到"三个架构怎么答同一份 port 契约"，这就是本系列"从比特到引脚再回到 RTOS"的完整弧线。

---

## 12.8 尾声：真机篇与综合项目愿景

### 1. 板到之后：占位章的回填计划

先行章的理论底座已经完备，真机到位后按序激活：

1. **[[ch05-gpio-and-mco|第五章]]**点灯占位 → F407 真机 RCC/GPIO 实测（QEMU 不仿真 F407 外设的部分在此补齐）；
2. **[[ch06-uart-protocol|第六章]]**双板通信 → STM32↔GD32 的 3.3V TTL 直连实测、逻辑分析仪抓帧；
3. **[[ch11-debug-swd-jtag|第十一章]]**openocd → `dnf install openocd` 后 SWD/JTAG 真机调试流程；
4. 本章的延伸实验：真机 F407 上跑 FreeRTOS（任意发行版），gdb 断在 `xPortPendSVHandler`，把 12.3 的帧布局逐字对账——QEMU 时代练的 gdbstub 功夫直接复用。

回填时旧的 `> [!warning] 真机待验证` 标注逐个换成实测数据，系列从"无板先行"转正为"实证完整"。

### 2. 综合项目愿景：WiFi 协处理器架构

系列开篇预告的综合项目在此成形：**STM32F407 做主控（实时控制、传感器聚合——本系列 ARM 腿的全部用武之地），ESP32 做 WiFi 协处理器（网络栈——读者在 FreeRTOS/lwIP 两系列里源码级读过的那套软件，跑在 Xtensa port 上）**，两芯片用第六章设计的成帧协议 over UART 互联。这个架构里：

- 主控侧：本章 12.2-12.5 的 Cortex-M port 知识 + FreeRTOS 单核调度——读者可以选择裸机状态机或 RTOS，两条路都已铺好；
- 协处理器侧：ESP32 上 reader 已知的 IDF/Xtensa/lwIP 全栈，AT 式或 RPC 式封装随协议定；
- 双架构学习法的最终兑现：同一个"收传感器数据→上网报送"任务，你能在两种架构上各自实现并说出每一层的差异——这比任何单架构教程都更接近"嵌入式"的本义。

ESP32 在本系列的角色到本章为止仍是"对照与协处理器"（SPEC 铁律），但读者已具备把它的 port 层（三条腿中最复杂的一条）完整读下来的全部前置知识——收官的另一个含义是：**没有黑盒留下了**。

---

## 12.9 小结

- 取证结论：IDF v6.0.2 内核树的 `portable/` 下只有 `linux/`、`riscv/`、`xtensa/` 三个 port，无 ARM；Cortex-M 摘录来自本机 vanilla 树 V11.3.0 的 `portable/GCC/ARM_CM4F/`。四组对照全部基于真实文件。
- 切换触发：ARM 用 PendSV + 硬件最低优先级保证"切换最后发生"；Xtensa/RV(IDF) 用软件 flag + 最外层中断退出点兑现；vanilla RV 用 `ecall` 同步陷阱。Cortex-M 首任务启动借 `svc 0` 与向量表 0 号槽复位 MSP。
- 上下文本体：Cortex-M 硬件存 8 个（恰为 AAPCS caller-saved）+ 软件补 R4-R11/EXC_RETURN（68B）；RISC-V 全软件（32 GPR 槽 + CSR）；Xtensa 窗口 spill（192B/32B）。三种出生帧都是"伪装成刚被打断"。
- 临界区：ARM BASEPRI"关一部分"（阈值可配+运行时断言）；Xtensa `rsil` INTLEVEL=3（固定）；vanilla RV mstatus.MIE 全开关；IDF RV 用中断矩阵阈值寄存器复刻 BASEPRI 语义——port 层是架构不足之处的补全层。
- tick：Cortex-M 的 SysTick 是核内标配（24 位，port 自带驱动，第八章知识的兑现）；Xtensa/RV 各接外设（SYSTIMER/mtime），"表在哪"每芯片一答。
- 五项毕业自测（向量表/启动文件/链接脚本/上下文切换/临界区）全过，即具备 port 维护者视野；系列知识弧线从万用表闭合到 port 对照。

真机篇见。

---

## 参考

- 本章摘录来源（本机真实文件，路径截取自两棵树）：
  - `~/esp/esp-idf/components/freertos/FreeRTOS-Kernel/portable/`（IDF v6.0.2）：`xtensa/`、`riscv/{port.c, portasm.S, include/freertos/portmacro.h}`、`linux/`
  - `~/code/FreeRTOS-Kernel/portable/GCC/ARM_CM4F/{port.c, portmacro.h}`（vanilla V11.3.0，git tag 实测）；同系 `ARM_CM3/` 为无 FPU 版
  - `~/code/FreeRTOS-Kernel/portable/GCC/RISC-V/{port.c, portmacro.h, portContext.h, portASM.S}`（vanilla RV 通用 port）
  - `~/esp/esp-idf/components/riscv/vectors.S`（RV trap 入口与帧保存）、`include/riscv/rvruntime-frames.h`（帧布局权威定义）
  - `~/esp/esp-idf/components/riscv/include/esp_private/interrupt_intc.h`（`rv_utils_set_intlevel_regval`）、`include/riscv/rv_utils.h`（`RVHAL_EXCM_LEVEL=4`）
  - `~/esp/esp-idf/components/freertos/port_systick.c`（Xtensa/RV 共用 tick 装配）
- ARMv7-M Architecture Reference Manual（DDI 0403E.b）：§B1.5.6 异常入栈、EXC_RETURN 编码、§B3.2 SCS（ICSR/SHPR/BASEPRI/SysTick）——即[[ch03-arm-cortex-m-anatomy|第三章]]参照的同源锚点
- RISC-V Privileged Architecture（mstatus/mepc/mcause/mtvec/mtime）与 GD32VF103 用户手册（ECLIC/machine timer）——[[ch09-riscv-gd32-contrast|第九章]]展开
- 读者已读的 port 知识基座：[[ch7-context-switch-deep-dive|FreeRTOS 系列（七）]]、[[ch16-portmacro-port-contract|（十六）]]、[[ch17-xtensa-port-internals|（十七）]]、[[ch18-critical-sections-spinlocks|（十八）]]
- FreeRTOS 官方文档：Using FreeRTOS on RISC-V（`portable/GCC/RISC-V/` 内 Documentation.url 指向）、RTOS-Cortex-M3-M4 FAQ（BASEPRI 与 `configMAX_SYSCALL_INTERRUPT_PRIORITY`，port.c 注释内引用）
