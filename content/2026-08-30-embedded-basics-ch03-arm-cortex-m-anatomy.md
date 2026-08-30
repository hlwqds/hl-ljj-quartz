---
title: "嵌入式硬件基础（三）：Cortex-M 解剖：寄存器组、栈与向量表"
date: 2026-08-30
description: "寄存器组全景（MSP/PSP 双栈、EXC_RETURN、xPSR）、向量表机制与异常 8 寄存器压栈，全部在 QEMU mps2-an385 上用 gdb 逐字实证：复位 SP=向量表首项、SVC 栈帧魔数对照、异常返回 MSP 复原。"
tags: [embedded, stm32, cortex-m, arm, qemu]
---

> [!info] 嵌入式硬件基础系列 0. [[2026-08-30-embedded-basics-series-index|系列索引]] 2. [[2026-08-30-embedded-basics-ch02-tools-multimeter-la|第二章：工具驯化]] 3. **第三章：Cortex-M 解剖** 4. [[2026-08-30-embedded-basics-ch04-baremetal-boot|第四章：裸机启动]]（并行写作中）

# 嵌入式硬件基础（三）：Cortex-M 解剖：寄存器组、栈与向量表

如果你源码级读过 RTOS 的 port 层，一定见过这些名字：`MSP`、`PSP`、`EXC_RETURN`、`xPSR`、`VTOR`。它们在 `port.c` 里被当作黑盒寄存器名使用，FreeRTOS 的上下文切换、临界区、PendSV 调度全建立在它们之上（[[2026-08-26-freertos-deep-dive-ch16-portmacro-port-contract|portmacro 契约]]一章里我们背过它们的用途，但没看过它们在硬件里长什么样）。

本章把 Cortex-M 的"核心三件套"——寄存器组、栈、向量表——解剖开。更重要的是：**本章建立整个系列的"QEMU 裸机实验"底座**。板子还没到，但 `qemu-system-arm -M mps2-an385` 是一台货真价实的 Cortex-M3：同样的向量表、同样的异常压栈、同样的 gdbstub。本章的每一条关键结论都有一条真实 gdb 会话作证，你可以逐字复现。

先给全章地图：

- **寄存器组**：16 个核内寄存器 + 4 个中断屏蔽寄存器 + CONTROL，其中 SP 一分为二（MSP/PSP）、LR 有神秘的第二职业（EXC_RETURN）；
- **向量表**：不是"跳转指令表"，而是一个函数指针数组，且**第 0 项不是函数指针**——这是全章第一大坑；
- **异常入栈**：硬件在进入异常前自动压 8 个寄存器，这个顺序是 ABI 级契约，RTOS 的上下文切换就是围绕它设计的。

---

## 3.1 寄存器组全景：16 个格子，两种身份

Cortex-M 有 16 个核内寄存器 R0-R15，外加一组特殊功能寄存器。参照 ARMv7-M 架构手册（DDI 0403E.b）§B1.4：

| 寄存器 | 别名 | 身份                                                          | 调用约定角色            |
| ------ | ---- | ------------------------------------------------------------- | ----------------------- |
| R0-R3  | -    | 低组通用寄存器                                                | 参数/返回值，调用者保存 |
| R4-R11 | -    | 高组通用寄存器                                                | 被调者保存              |
| R12    | IP   | intra-procedure-call 暂存（过程内过渡用， veneer 可自由改写） | 调用者保存              |
| R13    | SP   | **栈指针，银行式分为 MSP 和 PSP 两个物理实体**                | -                       |
| R14    | LR   | 链接寄存器；异常入口被硬件改写为 EXC_RETURN                   | 调用者保存              |
| R15    | PC   | 程序计数器                                                    | -                       |
| xPSR   | -    | 状态寄存器（APSR+IPSR+EPSR 三合一视图）                       | -                       |

对写过 x86-64 汇编的人，这张表几乎可以直接读作 System V ABI 的 ARM 版：R0-R3 ≈ RDI/RSI/RDX/RCX（传参），R4-R11 ≈ RBX/RBP/R12-R15（callee-saved），LR ≈ 被 call 指令自动压栈的返回地址（只是 Cortex-M 把它放进寄存器）。

真正"嵌入式味"的是后面三处。

### 1. SP 一分为二：MSP 与 PSP

R13 在物理上有两个备份，由 CONTROL 寄存器的 SPSEL 位选择当前生效者：

- **MSP**（Main SP）：复位后默认使用。**Handler 模式（中断/异常处理）永远用 MSP**，没得选；
- **PSP**（Process SP）：Thread 模式可选。典型用法：任务代码用 PSP。

为什么要有两个栈？给软件人一个直白的对照：这相当于内核把"内核栈"和"用户栈"做成了硬件原生支持——

- 中断打在任意任务上时，handler 压栈到 MSP，**不碰任务栈**。任务栈深度预算不用考虑中断嵌套，每个任务可以分配更小、更精确的栈；
- RTOS 上下文切换只需保存任务的 R4-R11 + PSP（R0-R3/R12/LR/PC/xPSR 由异常压栈机制代劳，见 3.3），切换成本被架构压到极低；
- 反过来，如果只用一个栈：中断嵌套的栈消耗全部叠在当前任务头上，栈溢出会随机地"归罪"于恰好被打断的任务——一种最恶心的 Heisenbug。

FreeRTOS 每个 Cortex-M port 的 `xPortPendSVHandler` 本质就是一场围绕 PSP 的寄存器编排（第十二章三架构对照时逐行看）。**记住这句话：中断用 MSP，任务用 PSP——这是 RTOS 在 Cortex-M 上立足的第一块基石。**

### 2. LR 的第二职业：EXC_RETURN

普通代码里 LR 存返回地址。但进入异常时，硬件会把 LR 改写成一个**看起来像地址、实则不可执行**的魔法值：

| EXC_RETURN | 返回到       | 使用的栈 |
| ---------- | ------------ | -------- |
| 0xFFFFFFF1 | Handler 模式 | MSP      |
| 0xFFFFFFF9 | Thread 模式  | MSP      |
| 0xFFFFFFFD | Thread 模式  | PSP      |

（M4F 带浮点上下文时还有 0xFFFFFFE1/E9/ED 变体，帧里多 16 个浮点寄存器+FPSCR，第 3.5 节的实验机器没有 FPU，暂不展开。）

handler 末尾一句 `bx lr` 不是"跳回调用者"，而是触发**硬件异常返回序列**（出栈、模式还原）。这解释了一个常见面试题：为什么 Cortex-M 的中断服务函数可以写成普通 C 函数、以 `bx lr` / `return` 结尾就能正确返回——因为返回语义被编码在 LR 的值里，而不是靠特殊返回指令（对照 x86 的 `iret`）。

### 3. xPSR：三个状态寄存器的叠加视图

xPSR 是一次读出三份信息的合成寄存器：

- **APSR**（应用程序状态）：N/Z/C/V/Q 标志位（bit31-27 附近），加减比较的结果标志，写汇编时靠它们做条件跳转；
- **IPSR**（中断程序状态）：bit8-0，**当前正在处理的异常号**。Thread 模式为 0，handler 里非 0——一段代码想知道"我现在是不是在中断里"，读 IPSR 即可（FreeRTOS 的 `xPortIsInsideInterrupt()` 就是这么实现的）；
- **EPSR**（执行程序状态）：bit24 的 T 位（Thumb 状态，恒为 1）+ ICI/IT 位（被中断的多周期指令/IT 块的执行进度）。

特殊功能寄存器还有一组，先挂账，第七章展开：**PRIMASK**（一键关中断）、**BASEPRI**（关"优先级数字大于等于 N"的中断——FreeRTOS 的临界区实现，比 PRIMASK 温和，允许更高优先级中断穿透）、**FAULTMASK**（连 HardFault 都关）、**CONTROL**（nPRIV 特权位 + SPSEL 栈选择位）。

---

## 3.2 向量表：中断的路由表

软件人可以这样理解 Cortex-M 的中断派发：**向量表是一张编译期写死在地址 0 的函数指针数组，CPU 是持有这张表的中断分发硬件**。

```c
/* 向量表的本质（示意，真实启动文件里是汇编 .word 序列） */
const void *vector_table[] = {
    (void *)0x20400000,   /* [0]  初始 MSP —— 注意：不是函数指针！ */
    Reset_Handler,        /* [1]  复位                    异常号 1  */
    NMI_Handler,          /* [2]  不可屏蔽中断            异常号 2  */
    HardFault_Handler,    /* [3]                          异常号 3  */
    /* 4-6: MemManage/BusFault/UsageFault, 7-10: 保留 */
    SVC_Handler,          /* [11] SVCall（ supervisor 调用）        */
    DebugMon_Handler,     /* [12]                                */
    0,                    /* [13] 保留                            */
    PendSV_Handler,       /* [14] 可挂起的系统调用——RTOS 调度器住这 */
    SysTick_Handler,      /* [15] 系统节拍                          */
    /* [16] 起：外部中断 IRQ0、IRQ1……芯片厂的外设在这里接进来 */
};
```

三个关键事实：

**事实一：第 0 项是初始 MSP，不是跳转目标。** 这是全章第一大坑。复位后 CPU 做的事是：从 `0x00000000` 读一个字装进 SP，从 `0x00000004` 读一个字装进 PC——**前者是数据，后者才是入口**。没有任何代码会"执行"第 0 项。为什么这么设计？因为复位后第一件事往往就要跑 C 代码/异常处理，而任何 C 代码都离不开栈；硬件先替你把 SP 装好，启动代码就不必手写 `ldr sp, =_estack`。（对照 x86：reset 后 CPU 跳 0xFFFFFFF0 执行 firmware，栈要 firmware 自己搭——两种哲学。）

**事实二：表项是"地址+1"。** Cortex-M 没有 ARM 指令集状态，永远执行 Thumb(16/32 位混合)指令，函数指针一律是"真实地址 | 0x1"（T 位强制为 1）。后面 gdb 会话里你会看到 `0x00000041` 这样的值——0x40 是真实地址，最低位 1 是 Thumb 标记，`bx` 靠它决定指令集状态。

**事实三：VTOR 可以把表搬走。** 向量表基址默认 0，但系统控制空间（SCS）里的 **VTOR**（地址 `0xE000ED08`）可以在运行时改写——bootloader 跳应用程序、应用把中断向量重定位到 RAM 做热补丁，都靠它。约束：表基址需对齐到不小于表大小的 2 的幂（M3/M4 低位地址位保留，至少 128 字节对齐）。STM32F407 的完整向量表（含全部外设中断）见 RM0090 §10.1.3"Interrupt and exception vectors"——本章末尾的 QEMU 实验会现场读一次 VTOR。

> [!note] 对照预告：RISC-V 没有这张表
> RISC-V 的 trap 入口只有一个寄存器 `mtvec`：direct 模式下所有 trap 跳同一个基址，vectored 模式下按 `mcause` 编号偏移——**没有硬件预取的函数指针数组，分发是软件的活**（读 `mcause`、比较、跳转）。GD32VF103 的 ECLIC 在此之上加了自己的向量化机制。这组差异是 [[2026-08-30-embedded-basics-ch09-riscv-gd32-contrast|第九章]] 的主角，此处埋个钩子：**向量表=硬件查表的"中断路由表"，mtvec=软件注册的"统一 trap 入口"**。

---

## 3.3 异常进入：硬件替你压好的 8 字栈帧

中断/异常发生时，Cortex-M 硬件在跳转到 handler 之前，自动把 **8 个寄存器**压入当前的栈（Thread 用 PSP 就是 PSP，用 MSP 就是 MSP；Handler 模式嵌套异常则压 MSP）。顺序是架构契约（DDI 0403E.b §B1.5.6 "Exception entry behavior"），从新栈指针向高地址排：

```text
              高地址
        ┌──────────────────┐
SP_old →│   xPSR           │  +28   被打断时刻的状态寄存器
        ├──────────────────┤
        │   PC             │  +24   返回地址=被中断指令的下一条
        ├──────────────────┤
        │   LR (R14)       │  +20   被打断代码的返回地址
        ├──────────────────┤
        │   R12 (IP)       │  +16
        ├──────────────────┤
        │   R3             │  +12
        ├──────────────────┤
        │   R2             │  +8
        ├──────────────────┤
        │   R1             │  +4
        ├──────────────────┤
SP_new →│   R0             │  +0
        └──────────────────┘
              低地址
```

细节四则：

1. **为什么恰好是 R0-R3、R12、LR、PC、xPSR 这八个？** 因为 R0-R3/R12/LR 恰好是 AAPCS 调用约定里的"调用者保存"集合（3.1 的表格里标过）。硬件替调用者保存了 caller-saved 寄存器，于是 **handler 可以直接是一个普通 C 函数**：编译器看到的现场干净得像一个刚被 call 进来的函数。这不是巧合，是 ABI 与架构的对偶设计——Cortex-M 的中断零胶水（no wrapper、no naked function）正源于此。
2. 入栈后若栈未 8 字节对齐，硬件会垫一个 4 字节空字，并把栈帧里 xPSR 的 bit9 置 1 作记号，返回时据此丢弃垫片（CCR.STKALIGN 行为）。
3. 栈帧里压的 xPSR 中，IPSR 字段是被打断代码的视角（Thread 里就是 0）；handler 自己的 IPSR 才是本异常号。3.5 的实验会看到栈帧 xPSR=`0x41000000`，逐位拆开就是它。
4. 压完栈，硬件把 LR 装入 EXC_RETURN、IPSR 更新为本异常号、切到 Handler 模式、SP 强制用 MSP，然后才跳转向量表里的 handler。

**异常返回**是对称的出栈：handler 执行 `bx lr`（LR=EXC_RETURN），硬件识别出这是魔法值而非地址，自动弹出 8 字恢复 R0-R3/R12/LR/PC/xPSR，按 EXC_RETURN 编码还原模式和栈选择。两个优化值得知道：

- **尾部链（tail-chaining）**：一个 handler 刚返回、又有异常 pending 时，硬件跳过"出栈再立刻入栈"的来回，直接把栈帧原样移交给下一个 handler——Cortex-M3 的中断进入延迟从约 12 周期降到约 6 周期（Cortex-M3 TRM 数据）。这就是中断风暴下 Cortex-M 依然优雅的原因；
- **晚到（late-arriving）**：入栈进行中来了更高优先级异常，先服务后来者，已压的帧直接复用。

对软件人总结一句：**这套机制 ≈ 内核的"中断上下文"在硬件里的固化**——你在服务器 Linux 里读过的 `entry.S` 抬栈帧逻辑，Cortex-M 用约 12 个时钟周期的硬件电路做完了。

---

## 3.4 操作模式与特权级：2×2 的小矩阵

Cortex-M 用两个独立维度组合出四种状态：

| 模式 \ 特权 | 特权             | 非特权                  |
| ----------- | ---------------- | ----------------------- |
| Thread      | 复位后的默认状态 | 任务沙箱（RTOS 用户态） |
| Handler     | 异常处理所在状态 | （不存在）              |

规则：

- 复位 → **Thread+特权**，用 MSP；
- 任何异常 → **Handler+特权**（没有非特权 Handler），SP 用 MSP；
- Thread 模式可通过写 CONTROL 切到 PSP 和/或非特权，但一旦非特权，想回特权只能**触发 SVC 异常、由特权代码代劳**——这就是 MCU 世界的 syscall；
- 非特权 Thread 访问 SCS/NVIC（`0xE0000000` 起）直接触发 fault，正是隔离边界。

RTOS 的经典姿势全在这张表里：任务跑非特权 Thread+PSP，内核与中断跑特权+MSP，任务请求内核服务走 SVC。第十二章对照 FreeRTOS 三架构 port 时会看到它们各自的落地程度。

本章实验（以及本系列前期所有 QEMU 实验）都跑在 Thread+特权+MSP 的最朴素档位——先把地基摸熟。

---

## 3.5 QEMU 实战：把 3.2/3.3 的每一条砸在实验台上

> [!info] 实验环境（全部本机实测）
> 工具链：`arm-none-eabi-gcc` 15.2.0（Fedora 包）；`qemu-system-arm` 10.1.5；gdb 用的既不是 `arm-none-eabi-gdb` 也不是 `gdb-multiarch`——本机两者都没装，但 **Fedora 原生 gdb 17.1 是多目标构建**，`set architecture arm` 后直连 QEMU 的 ARM gdbstub 一切正常（下述会话全部如此完成）。Debian/Ubuntu 用户装 `gdb-multiarch` 等价。
> 机型：`-M mps2-an385`，ARM 官方 MPS2+ FPGA 开发板的 Cortex-M3 镜像。SPEC 定下的本系列通用实验机：核心异常模型与 STM32F407（M4F）同源，QEMU 完整仿真其内核/NVIC/SysTick/UART；F407 专有外设 QEMU 不管，那些留给真机章节。

### 1. 实验工程：70 行的最小裸机

工程在仓库 `practice/hwbasics/ch03-cortex-m-anatomy/`，无 C 库、无启动文件框架，一个汇编文件说完全部——**本章先把它当工具用，第四章会逐行解剖它并长成完整启动文件**。

`startup.s`（节选，完整版见仓库）：

```asm
.cpu cortex-m3
.thumb
.syntax unified

.section .isr_vector, "a", %progbits
.word _estack           /*  0: 初始 MSP（不是跳转目标！） */
.word Reset_Handler     /*  1: Reset                   */
.word Default_Handler   /*  2: NMI                     */
.word Default_Handler   /*  3: HardFault               */
/*  ……4-10 略……             */
.word SVC_Handler       /* 11: SVCall                  */
/*  ……12-15 略……            */

.section .text
.thumb_func
Reset_Handler:
    /* 给 R0-R3/R12/LR 塞魔数：SVC 触发硬件压栈后，
     * 这些值会原样出现在 MSP 栈帧里，逐字核对压栈顺序 */
    ldr     r0,  =0xAAAA0001
    ldr     r1,  =0xAAAA0002
    ldr     r2,  =0xAAAA0003
    ldr     r3,  =0xAAAA0004
    ldr     r12, =0xAAAA000C
    ldr     lr,  =0x00ED0001   /* 伪造"调用者返回地址" */
    svc     #0                  /* 触发 SVCall（异常号 11） */

after_svc:                     /* 异常返回后落到这里，
                                  栈帧里的 PC 应指向本行 */
    b       after_svc

.thumb_func
SVC_Handler:
    bx      lr                  /* 什么都不做，直接异常返回 */
```

`ch03.ld`（把向量表钉死在地址 0，栈顶取 RAM 末尾）：

```ld
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 4M
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 4M
}

/* 初始 MSP = RAM 末尾（满减栈） */
_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
    .isr_vector : { KEEP(*(.isr_vector)) } > FLASH
    .text       : { *(.text*) *(.rodata*) } > FLASH
}
```

`make` 一把过（`arm-none-eabi-gcc -mcpu=cortex-m3 -mthumb -nostdlib -Os -T ch03.ld startup.s`）。先看反汇编，三个关键地址记在小本本上：

```text
00000040 <Reset_Handler>:        ← Reset 入口，向量表第 1 项
  40: 4805       ldr  r0, [pc, #20]
  ……
  50: df00       svc  0          ← SVC 指令在 0x50

00000052 <after_svc>:            ← 栈帧 PC 应指向 0x52
  52: e7fe       b.n  52 <after_svc>

00000054 <SVC_Handler>:
  54: 4770       bx   lr         ← 断点位置

00000056 <Default_Handler>:      ← 向量表第 2/3/14/15 项
20400000 R _estack               ← 初始 MSP（nm 输出）
```

### 2. 实验一：复位瞬间，SP 和 PC 是谁给的

QEMU 挂起启动（`-S`）+ gdbstub（`-s` 是 `-gdb tcp::1234` 的简写；写本文时本机还跑着另一章的 QEMU 占了 1234，故用 1235），gdb 接上时 CPU 恰好停在复位后的第一条指令，寄存器处于"硬件刚做完复位序列"的原始状态：

```bash
qemu-system-arm -M mps2-an385 -nographic -kernel build/ch03.elf -S -gdb tcp::1235 &
gdb --batch -ex 'set architecture arm' -ex 'file build/ch03.elf' \
    -ex 'target remote localhost:1235' \
    -ex 'info registers pc sp' -ex 'x/16wx 0x0' -ex 'x/wx 0xE000ED08' \
    -ex 'detach'
```

真实输出：

```text
The target architecture is set to "arm".
0x00000040 in Reset_Handler ()
pc             0x40                0x40 <Reset_Handler>
sp             0x20400000          0x20400000
0x0:    0x20400000  0x00000041  0x00000057  0x00000057
0x10:   0x00000057  0x00000057  0x00000057  0x00000000
0x20:   0x00000000  0x00000000  0x00000000  0x00000055
0x30:   0x00000057  0x00000000  0x00000057  0x00000057
0xe000ed08:  0x00000000
[Inferior 1 (process 1) detached]
```

逐字验尸：

- **`sp = 0x20400000`，而地址 0x0 处的字恰好也是 `0x20400000`**——复位瞬间"0 地址首项=初始 MSP"实锤。它同时是链接脚本里 `_estack`（`ORIGIN+LENGTH`），一根线从 ld 文件牵到 CPU 寄存器；
- **`pc = 0x40 <Reset_Handler>`，地址 0x4 处是 `0x00000041`**——第二项=复位入口，最低位 1 是 Thumb 标记（3.2 事实二）；
- 表第 11 项（0x2C 处）`0x00000055` = SVC_Handler(0x54)|1，第 15 项 `0x00000057` = Default_Handler(0x56)|1（SysTick），与反汇编三处地址互相咬合；
- `0xE000ED08`（VTOR）读出 0——向量表就在 0，3.2 事实三的默认值。

> [!tip] 两个真实的坑
> 若 gdb 不先 `file build/ch03.elf` 就 `target remote`，gdbstub 不会自动识别目标架构，QEMU 连接后行为混乱并伴随 `No executable has been specified` 警告。先 file、后 connect，顺序别反。
> 另一个：gdb 的 `detach` 会**放行**QEMU 继续跑——实验一的 detach 一执行，裸机程序就自己跑进 `after_svc` 死循环了，下一个 gdb 会话连上来时 CPU 处于运行态，`break` 直接报 `Cannot execute this command while the target is running`。想保持暂停用 `disconnect`；本文实验二、三干脆重启一台带 `-S` 的 QEMU、共用同一次会话跑完。

### 3. 实验二：SVC 栈帧，8 个魔数逐字对账

重启一台 QEMU（原因见上框），断在 SVC_Handler 入口——此刻硬件刚完成压栈，`$sp` 正好指着栈帧第一格。实验二、三共用这一次会话：

```bash
gdb --batch -ex 'set architecture arm' -ex 'file build/ch03.elf' \
    -ex 'target remote localhost:1235' \
    -ex 'break SVC_Handler' -ex 'continue' \
    -ex 'info registers pc sp lr' -ex 'x/8wx $sp' \
    -ex 'break after_svc' -ex 'continue' \
    -ex 'info registers pc sp r0 r1 r2 r3 r12' \
    -ex 'detach'
```

真实输出（完整会话，实验三从 `Breakpoint 2` 处接续）：

```text
The target architecture is set to "arm".
0x00000040 in Reset_Handler ()
Breakpoint 1 at 0x54

Breakpoint 1, 0x00000054 in SVC_Handler ()
pc             0x54                0x54 <SVC_Handler>
sp             0x203fffe0          0x203fffe0
lr             0xfffffff9          -7
0x203fffe0:  0xaaaa0001  0xaaaa0002  0xaaaa0003  0xaaaa0004
0x203ffff0:  0xaaaa000c  0x00ed0001  0x00000052  0x41000000
```

对着 3.3 的栈帧图逐字对账：

| 栈地址 | 读数       | 应为 | 判定                                                              |
| ------ | ---------- | ---- | ----------------------------------------------------------------- |
| +0 SP  | 0xaaaa0001 | R0   | 命中                                                              |
| +4     | 0xaaaa0002 | R1   | 命中                                                              |
| +8     | 0xaaaa0003 | R2   | 命中                                                              |
| +12    | 0xaaaa0004 | R3   | 命中                                                              |
| +16    | 0xaaaa000c | R12  | 命中                                                              |
| +20    | 0x00ed0001 | LR   | 命中（塞进去的"调用者返回地址"）                                  |
| +24    | 0x00000052 | PC   | 命中（=`after_svc`，SVC 的下一条指令）                            |
| +28    | 0x41000000 | xPSR | 命中（bit30 Z=1 为复位后标志残留；bit24 T=1；IPSR=0=Thread 视角） |

两个额外的细节：

- `sp = 0x203fffe0`，恰是 `0x20400000 - 0x20`——32 字节=8 个字，分毫不差；且已 8 字节对齐，无垫片（3.3 细节 2）；
- **`lr = 0xfffffff9`**：handler 里看到的 LR 不是返回地址，是 EXC_RETURN。解码：bit2=0 → 用 MSP，bit3=1 → 返回 Thread 模式，即表中的 `0xFFFFFFF9`。我们是在 Thread+MSP 里触发的 SVC，硬件给出的编码严丝合缝。

### 4. 实验三：异常返回，一切复原

继续同一会话：在 `after_svc` 加断点并 continue，handler 的 `bx lr` 触发出栈序列后停住：

```text
Breakpoint 2 at 0x52

Breakpoint 2, 0x00000052 in after_svc ()
pc             0x52                0x52 <after_svc>
sp             0x20400000          0x20400000
r0             0xaaaa0001          -1431699455
r1             0xaaaa0002          -1431699454
r2             0xaaaa0003          -1431699453
r3             0xaaaa0004          -1431699452
r12            0xaaaa000c          -1431699444
[Inferior 1 (process 1) detached]
```

- `pc = 0x52`：从栈帧的"返回地址"字（+24）恢复，正是 `after_svc`；
- `sp = 0x20400000`：MSP 精确复原（出栈 0x20 字节）；
- `r0-r3/r12`：魔数一个不少回到寄存器——被中断代码完全无感，这就是"硬件保存中断上下文"的全部含义。_FreeRTOS 换掉 PSP 再走一遍这套序列，就是任务切换。_

### 5. 这套实验意味着什么

三个实验合起来，把 3.2/3.3 的架构图变成了可触摸的寄存器与内存。而且注意：**全程没有实体板、没有烧录器、printf 一个都没有**——gdbstub + `-S`/`-s` 就是裸机世界的 tcpdump，是本系列后续每章的标配工位。完整工程、复现命令与 gdb 交互版会话见 `practice/hwbasics/ch03-cortex-m-anatomy/README.md`。

---

## 3.6 NVIC 一瞥：向量表的"可编程前端"

3.2 的向量表回答了"去哪执行"，但没回答"允不允许执行、谁先执行"。这两个问题归 **NVIC**（Nested Vectored Interrupt Controller，嵌套向量中断控制器）管——它和 CPU 核同在 `0xE0000000` 起的系统控制空间里，是一块紧耦合的"中断路由器"。

用软件人的 IRQ 子系统做类比，一张表对齐概念（第七章展开细节）：

| Linux IRQ 子系统            | Cortex-M 对应物                             |
| --------------------------- | ------------------------------------------- |
| irq_desc[] 分发表           | 向量表（编译期固化在 Flash）                |
| 中断控制器（APIC/IOAPIC）   | NVIC（使能/挂起/优先级寄存器组）            |
| request_irq() 动态注册      | 没有——写中断函数=改向量表项，链接期"注册"   |
| request_threaded_irq 下半部 | 尾部链 + PendSV"排到最低优先级"的软中断技巧 |
| /proc/interrupts            | NVIC 的 pending/active 寄存器（gdb 直接读） |

最有"嵌入式味"的是倒数第二行：Linux 把中断下半部交给线程调度，Cortex-M 的 RTOS 则把 PendSV 设为最低优先级，让内核工作"沉底"到所有硬中断之后执行——同一种"中断顶半部尽量短"的哲学，两种实现。这套机制第七章用 SysTick 在 QEMU 上实跑。

---

## 3.7 小结与下一章

本章解剖了 Cortex-M 的骨架，每条结论都有 QEMU 实证背书：

- **寄存器组**：R0-R15 分工与 AAPCS 对齐；SP 银行化为 MSP/PSP（中断 MSP、任务 PSP，RTOS 基石）；LR 在异常入口变身为 EXC_RETURN（实测 `0xfffffff9`）；xPSR 三合一（实测栈帧值 `0x41000000`：Z 位+T 位）；
- **向量表**：0 地址首项=初始 MSP（实测 SP=`0x20400000`==word0），第二项=Reset 入口（+Thumb 位），VTOR 可重定位（实测读出 0）；
- **异常模型**：硬件压 8 寄存器（实测 8 个魔数逐字命中 R0/R1/R2/R3/R12/LR/PC/xPSR），返回时自动出栈（实测 MSP 复原、寄存器复原），尾部链优化嵌套；
- **模式与特权**：Thread/Handler × 特权/非特权，SVC 是 MCU 的 syscall；
- **NVIC**：向量表的可编程前端，细节留给第七章。

这些名词从今天起不再是 `port.c` 里的咒语，而是你在 gdb 里亲手摸过的寄存器。

下一章 [[2026-08-30-embedded-basics-ch04-baremetal-boot|第四章：裸机启动]] 把本章 70 行的实验工具拆开重装：`.data`/`.bss` 为什么要手工初始化、链接脚本的 MEMORY/SECTIONS 在编译到运行的链条里各自管什么、启动文件的标准套路，最后在同一个 `mps2-an385` 上让 UART 吐出第一个字符——不靠任何 SDK，靠的就是本章这张向量表和这套栈。

---

## 参考

- ARMv7-M Architecture Reference Manual（DDI 0403E.b）：§B1.4 Registers（寄存器组）、§B1.5.6 Exception entry behavior（8 寄存器压栈顺序与栈帧）、§B1.5.8 Exception return behavior（EXC_RETURN 编码）、§B3.2 System Control Space（VTOR，0xE000ED08）
- ARM Cortex-M3 Technical Reference Manual：中断延迟与尾部链周期数据
- ST RM0090（STM32F407 参考手册）：§10.1.3 Interrupt and exception vectors（F407 完整向量表）
- ST PM0214（STM32F3/F4 Cortex-M4 编程手册）：内核寄存器与异常模型的 ST 官方转述
- 本系列 SPEC：`practice/hwbasics/SPEC.md` §3 验证纪律（`-M mps2-an385` 实验机约定）
- 本章实验工程：`practice/hwbasics/ch03-cortex-m-anatomy/`（含 README 与完整复现命令）
