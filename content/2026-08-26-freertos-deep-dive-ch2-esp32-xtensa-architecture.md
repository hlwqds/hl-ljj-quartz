---
title: "FreeRTOS 深度解析（二）：ESP32 与 Xtensa 架构速览"
date: 2026-08-26
description: "补齐读 FreeRTOS 端口层前的硬件底座：ESP32 双核 Xtensa LX6 的 SoC 全景、窗口寄存器编程模型、六级中断体系、完整内存映射与双核共享内存的代价——每一项都落回'这对 FreeRTOS 端口层意味着什么'。"
tags: [freertos, rtos, esp32, esp-idf, xtensa, architecture, interrupt, memory-map]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 2. **第二章：ESP32 与 Xtensa 架构速览**

# FreeRTOS 深度解析（二）：ESP32 与 Xtensa 架构速览

FreeRTOS 的内核 C 代码是架构无关的，但它的**端口层**（port）不是。第 7 章要读的上下文切换汇编、第 18 章要拆的临界区实现，每一条指令都在回应一个具体的硬件事实：寄存器怎么组织、中断怎么屏蔽、内存怎么映射、两颗核怎么看到同一份数据。这一章把这些事实一次补齐——不是抄一遍数据手册，而是每个机制都回答同一个问题：**它如何塑造了 FreeRTOS 在这颗芯片上的形状**。

本章的寄存器/地址/端口事实均出自 ESP-IDF v6.0.2 源码实读：CPU 配置来自 `components/xtensa/esp32/include/xtensa/config/core-isa.h`（Tensilica 生成的核心配置头），特殊寄存器编号来自 `components/xtensa/include/xtensa/specreg.h` 与 `corebits.h`，地址边界来自 `components/soc/esp32/include/soc/soc.h`，端口行为来自 IDF FreeRTOS 默认编译树 `components/freertos/FreeRTOS-Kernel/portable/xtensa/`（内核头部自证基线为 V10.5.1 加 Espressif 改造；这棵树与实验性上游 SMP 内核树的关系见 [[2026-08-26-freertos-deep-dive-ch4-kernel-source-map|第 4 章]]）。

---

## 2.1 SoC 全景：把 ESP32 摆上解剖台

### 1. 一块板子上的双核 SMP

ESP32（经典版）的骨架：**两颗对等的 Xtensa LX6 @ 240MHz**、448KB 片内 ROM、520KB 片内 SRAM、外挂 SPI Flash（代码与数据都从它来）、可选外挂 PSRAM，加上 WiFi/BT 射频与常规外设。对 FreeRTOS 而言，关键不是"快"，而是**对称多处理**：两颗核看到同一个物理地址空间、执行同一份内核映像、跑同一个调度器——这正是 Vanilla FreeRTOS 没有准备过的世界。

```text
┌───────────────────────────── ESP32 SoC ────────────────────────────┐
│                                                                    │
│   PRO_CPU / Core 0            APP_CPU / Core 1                     │
│   Xtensa LX6 @ 240MHz         Xtensa LX6 @ 240MHz（对称）           │
│   ├─ 32KB cache               ├─ 32KB cache                        │
│   │  （Flash/PSRAM 都经它访问）│  （两核各一份，彼此不硬件一致）      │
│   └─ 每核私有：中断控制器/     └─ 同款每核私有部件                   │
│      CCOUNT/CCOMPARE/窗口寄存器堆                                     │
│        │                             │                             │
│        └────────────┬────────────────┘                             │
│                  DPORT（系统互连 + 系统/外设寄存器矩阵）              │
│        ┌───────────┼───────────────┬──────────────┬─────────────┐  │
│   片内 SRAM（共享） │ 片内 ROM 448KB │ 外设寄存器窗口 │ RTC 内存     │  │
│   D/IRAM 双视图     │ （一级 boot）  │ UART/SPI/...  │ FAST+SLOW   │  │
│        │           └───────────────┴──────────────┴─────────────┘  │
│   SPI Flash 控制器 ──► 外挂 SPI Flash（代码/rodata，经 cache 映射）  │
│   （可选）SPIRAM   ──► 外部 PSRAM（经 cache 映射到 0x3F800000 窗口）│
└────────────────────────────────────────────────────────────────────┘
```

三件事值得先钉死：

1. **cache 是每核一份的**。地址空间里 PRO/APP 各占 32KB 的 cache 区块（`soc.h` 的 `SOC_CACHE_PRO_LOW`/`SOC_CACHE_APP_LOW`），两核访问 Flash/PSRAM 都要经过自己的那份 cache。
2. **SRAM 是共享的**，但同一个物理存储体在地址空间里有 IRAM、DRAM 两个"视图"（2.4 节展开）。
3. **中断控制器、定时器计数器、寄存器窗口都是每核私有**的——两颗核各自有一套完整的"CPU 状态"，这是理解 SMP 改造中"每核一份调度器状态"的硬件原型。

### 2. DPORT：名字里带 PORT 的系统枢纽

ESP32 的系统寄存器、外设挂载与核间桥都归在 **DPORT** 这个模块名下（它同时是外设寄存器空间的起点，地址 `0x3FF00000`）。它对本系列有一个非常实际的后果：`soc.h` 里专门有一组 `ASSERT_IF_DPORT_REG` 静态断言——在双核模式下，**不允许**用普通 `REG_READ`/`REG_WRITE` 宏直接访问 DPORT 寄存器，必须用 `DPORT_READ_PERI_REG` 这类专用序列。原因是 DPORT 域与 CPU 域时钟/总线不同，双核并发访问需要串行化处理。记住这个约束即可，细节属于第 23 章的跨核同步。

### 3. PRO_CPU / APP_CPU：历史别称

`soc.h` 开头就写着 `PRO_CPU_NUM (0)`、`APP_CPU_NUM (1)`。PRO = Protocol（协议栈核），APP = Application（应用核），反映 WiFi 时代典型分工：协议栈任务钉在 Core 0，应用钉在 Core 1。文档、启动日志（`cpu_start: Starting scheduler on APP_CPU`）里都会出现这两个词，它们就是核编号。

> [!tip] 落到端口层：SMP 不是"多了一个核"那么简单
> 两核各有私有中断控制器与计数器 → 内核必须有**每核的** tick 处理与中断嵌套状态；共享 SRAM 但 cache 不一致 → 临界区不能只靠关中断，必须加自旋锁（2.5 节）。这两条正是 IDF fork 与 Vanilla 分道的起点（[[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|第 22 章]]）。

---

## 2.2 Xtensa 编程模型：窗口寄存器是最大的异类

### 1. 先回想 ARM 的世界

Cortex-M 的编程模型是"16 个通用寄存器 + 少量特殊寄存器"：`R0–R12` 通用，`R13/R14/R15` 是 SP/LR/PC，`xPSR` 装标志，`PRIMASK/BASEPRI/FAULTMASK` 管中断屏蔽，`MSP/PSP` 两套栈指针分"内核/任务"。函数调用靠软件压栈保存 callee-save 寄存器（`R4–R11`）。上下文切换因此很薄：硬件自动压 8 个寄存器（`R0–R3、R12、LR、PC、xPSR`），PendSV 里再补几个。

Xtensa LX6 的世界几乎每一条都不同。

### 2. 窗口寄存器：64 个物理寄存器，16 个"可见"

`core-isa.h` 记录：`XCHAL_HAVE_WINDOWED 1`、`XCHAL_NUM_AREGS 64`。物理上有 **64 个通用寄存器**（记作 a0–a63），但任何时刻只有**连续 16 个**对软件可见，称为当前窗口。窗口的起点由特殊寄存器 **WINDOWBASE**（编号 72）决定，哪些窗格"已被占用"记录在 **WINDOWSTART**（编号 73）里——两者都是寄存器堆之外的管理状态。

```text
物理寄存器堆：a0 ────────────────────────────────────► a63（共 64 个）
                ┌◀── 当前窗口：16 个可见，仍叫 a0–a15 ──▶┐
                │  a0=返回地址  a1=SP  a2–a7=参数/返回值   │
                │  a8–a15=临时                               │
                └──────────── WINDOWBASE 指向窗口起点 ───────┘

call4  : 窗口起点 +4  （调用者的 a4–a7   变成被调者的 a0–a3）
call8  : 窗口起点 +8  （调用者的 a4–a11  变成被调者的 a0–a7）
call12 : 窗口起点 +12 （调用者的 a4–a15  变成被调者的 a0–a11）
entry 指令 = call4 语义 + SP 预留栈帧；retN 反向旋转回去
rotw n : 显式旋转窗口（不改 PC），中断退出路径用它快速恢复窗口
```

窗口的"溢出/下陷"是这套机制的灵魂：

- **窗口溢出（overflow）**：`callN` 旋转到的新窗格在 WINDOWSTART 里仍标记为占用时，触发溢出异常，由专门的处理代码把旧窗格的寄存器**倒进它们属主函数的栈帧**里，然后放行调用；
- **窗口下陷（underflow）**：`retN` 返回到一个已被倒出的窗格时，触发下陷异常，把寄存器从栈里**捞回来**，然后放行返回。

这两类异常有**六个专属向量槽**（`core-isa.h` 的 `XCHAL_WINDOW_OF4/UF4/OF8/UF8/OF12/UF12_VECOFS`，位于 VECBASE+0x00～0x140，每 0x40 一槽），是全系统最热的异常路径之一——普通 C 程序每次深层调用/返回都可能踩到。它们与 FreeRTOS 无关（属 ABI 层的 OS 无关代码，端口目录的 `readme_xtensa.txt` 原话），但它们**倒寄存器的目的地就是栈**，所以窗口机制与任务栈布局深度耦合。

### 3. 窗口 ABI 的规则与代价

窗口化带来一个 ARM 世界没有的性质：**没有 callee-save 通用寄存器**。被调函数直接换一个新窗格，调用者的寄存器原地不动；跨调用需要保留的状态全在栈上。`readme_xtensa.txt` 对窗口 ABI 的总结可直接引用：a0=返回地址、a1=SP、a2–a7=参数、a8–a15=临时，"There are no callee-save registers"。

派生规则：

| 规则                                      | 出处                                                                             | 对嵌入式工程师的直观冲击                                                                 |
| ----------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| SP 必须 16 字节对齐                       | 窗口 ABI；`portmacro.h` 里 `portBYTE_ALIGNMENT 16`，注释点名 isa_rm 的栈布局要求 | 任务栈大小要对齐到 16 的倍数，否则切换即崩                                               |
| 被调者可在 SP 下方 16 字节有"base save"区 | 溢出异常把调用者 a0–a3 倒到 `[SP-16, SP)`                                        | 栈溢出检测必须给这 16 字节留余量；`alloca`（`movsp` 指令）有专属异常（EXCCAUSE=5）来搬它 |
| `syscall`（a2==0）= 强制全量溢出          | ABI 约定，端口用它做"solicited 切换前清窗"                                       | 上下文切换汇编里能看到这个技巧（第 17 章）                                               |
| 特殊寄存器（SAR 等）按 caller-save 对待   | `readme_xtensa.txt` 明说：solicited 切换不保存它们                               | 内联汇编里攒着的 SAR 状态可能被 API 调用毁掉                                             |

另外提一句 Call0 ABI：Xtensa 还有不旋转窗口的 Call0 ABI（16 个固定寄存器、a12–a15 callee-save），ESP32 的**掩膜 ROM 代码**就是按 Call0 编译的（所以能从任意窗口深度被调用），而应用固件用窗口 ABI。FreeRTOS 端口两种都支持，ESP-IDF 默认窗口。

### 4. 特殊寄存器速览

Xtensa 把"非通用寄存器的 CPU 状态"统称特殊寄存器，用 `rsr`/`wsr`/`xsr` 指令访问（读/写/交换）。本系列反复会碰到的几个（编号出自 `specreg.h`）：

| 寄存器（编号）                                             | 作用                                                                                                                                                                          | 在 FreeRTOS 里的戏份                                                             |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **PS**（230）                                              | 处理器状态字：`INTLEVEL[3:0]`、`EXCM[4]`、`UM[5]`、`RING[7:6]`、`OWB[11:8]`（旧窗口基）、`CALLINC[17:16]`（窗口深度）、`WOE[18]`（窗口异常使能）——位定义全部出自 `corebits.h` | **临界区的落点**：`portDISABLE_INTERRUPTS()` 最终就是改 PS 的 INTLEVEL（2.3 节） |
| **SAR**（3）                                               | 移位量寄存器，变长移位/字符串操作用它                                                                                                                                         | 编译器隐式使用，切换时必须保存                                                   |
| **LBEG/LEND/LCOUNT**（0/1/2）                              | 零开销循环：PC 走到 LEND 时若 LCOUNT>0 则跳回 LBEG 并自减                                                                                                                     | `XCHAL_HAVE_LOOPS 1`；同样属任务上下文                                           |
| **WINDOWBASE/WINDOWSTART**（72/73）                        | 窗口管理                                                                                                                                                                      | 切换协处理器的帮手；`rotw` 恢复窗口                                              |
| **CCOUNT**（234）+ **CCOMPARE0/1/2**（240/241/242）        | 每核周期计数器 + 三个比较器，匹配产生 6/15/16 号中断                                                                                                                          | 端口计时基准；IDF 把 tick 换接到 esp_timer（见 2.3）                             |
| **INTERRUPT/INTSET/INTCLEAR/INTENABLE**（226/226/227/228） | 中断挂起/置位/清零/使能                                                                                                                                                       | 2.3 节主角                                                                       |
| **EPC_1..7 / EPS_2..7 / EXCSAVE_1..7**                     | 每个中断级别一组返回 PC/PS/暂存                                                                                                                                               | 中断嵌套的硬件账本（2.3 节）                                                     |
| **EXCCAUSE**（232）/ **EXCVADDR**（238）                   | 一般异常的原因码/出错地址                                                                                                                                                     | 崩溃日志里 `Guru Meditation` 的数据来源（第 24 章）                              |
| **CPENABLE**（224）                                        | 协处理器（含 FPU）使能位图                                                                                                                                                    | 协处理器**惰性切换**的开关（第 17 章）                                           |
| **VECBASE**（231）                                         | 向量表基址，复位值 `0x40000000`（ROM 里）                                                                                                                                     | 2.3 节向量布局的锚点                                                             |

> [!note] SAR 为什么重要到要进上下文
> C 编译器把 `x << n`（n 是变量）编译成"把 n 写进 SAR，再执行移位指令"。所以 SAR 是**隐式**活状态——任务 A 在 SAR 里留着移位量，被切换走再回来，若 SAR 没保存，回来后第一条变长移位就是错的。窗口寄存器保护不了它，端口必须在帧里显式保存。

### 5. 动手：在 QEMU 里摸一摸这些寄存器

新建项目（或在 [[2026-08-26-freertos-deep-dive-ch1-from-bare-metal-to-rtos|第一章]] 项目上改 `main.c`），用内联汇编直接读特殊寄存器：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define READ_SREG(reg, out)  asm volatile("rsr." #reg " %0" : "=r"(out))

/* 深一层的不打印的函数：只读窗口基就返回，用来量 call4 的开销 */
static uint32_t deep_one(void)
{
    uint32_t wb;
    READ_SREG(windowbase, wb);
    return wb;
}

static void reg_task(void *arg)
{
    uint32_t ps, wb, wb2, ccount1, ccount2, configid;
    for (;;) {
        READ_SREG(ps, ps);
        READ_SREG(windowbase, wb);
        READ_SREG(configid0, configid);
        printf("[reg] PS=0x%08lx windowbase=%u configid0=0x%08lx\n",
               (unsigned long)ps, wb, (unsigned long)configid);

        READ_SREG(ccount, ccount1);
        wb2 = deep_one();               /* call4：窗口应 +1 */
        READ_SREG(ccount, ccount2);
        printf("[reg] windowbase(depth+1)=%u, call4+rsr = %lu cycles\n",
               wb2, (unsigned long)(ccount2 - ccount1));

        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

void app_main(void)
{
    xTaskCreate(reg_task, "reg", 2048, NULL, 5, NULL);
}
```

`idf.py qemu monitor` 跑起来，典型输出（数值随构建与仿真环境变化）：

```text
[reg] PS=0x00050400 windowbase=4 configid0=0xc2bcfffe
[reg] windowbase(depth+1)=5, call4+rsr = 38 cycles
```

可以读出三层信息：

1. **PS 的解剖**：`0x00050400` = bit18 `WOE=1`（窗口异常使能）+ bit16 `CALLINC=1`（当前处于一层 call4 深度）+ `OWB=4`（bits 11:8）+ `INTLEVEL=0`。任务级代码就该长这样——没有 `EXCM`、没有 `UM`（IDF 跑在 ring0）。
2. **窗口真的在转**：`deep_one()` 里的 windowbase 比调用者大 1——一次 `call4` 就是一次窗口旋转，肉眼可见；开销只有几十个周期（若旋转触发溢出异常，会明显变大）。
3. **configid0 与源码对账**：`0xc2bcfffe` 正是 `core-isa.h` 里 `XCHAL_HW_CONFIGID0` 的值——你在运行时读到了这颗 CPU 的"配置指纹"（LX6.0.3，`esp32_v3_49_prod` 配置）。

CCOUNT 是每核每周期 +1 的自由计数器，两次读之间的差值就是这段代码的周期开销——后面做性能对比时它会反复出场（QEMU 的周期数是仿真值，量级供参考，绝对数值以真机为准）。

### 6. 中断帧长什么样：`xtensa_context.h` 的答案

`components/xtensa/include/xtensa_context.h` 用一组 `STRUCT_FIELD` 宏同时生成 C 结构体与汇编偏移，定义了中断/异常发生时端口要保存的帧（`XtExcFrame`）：`exit`（分发返回点）、`PC`、`PS`、**a0–a15 全部 16 个窗口寄存器**、`SAR`、`EXCCAUSE`、`EXCVADDR`、`LBEG/LEND/LCOUNT`，帧大小按 16 字节对齐再留余量（`XT_STK_FRMSZ`）。对照 2.2 节的特殊寄存器表，你会发现**帧里保存的正是"编译器会隐式用到、窗口又保护不了"的那部分状态**——SAR 与 loop 寄存器是任务活状态，EXCCAUSE/EXCVADDR 是异常现场证据。

### 7. Xtensa LX6 vs ARM Cortex-M：一张表对齐两套世界观

本系列读者多半从 STM32 过来，这张表以后会经常回看：

| 维度        | Xtensa LX6（ESP32）                                           | ARM Cortex-M（如 M4）                   |
| ----------- | ------------------------------------------------------------- | --------------------------------------- |
| 通用寄存器  | 64 个物理 + 16 个可见（窗口旋转）                             | 16 个固定（R0–R15）                     |
| callee-save | **无**（换窗即隔离，状态在栈上）                              | R4–R11（软件压栈）                      |
| 函数调用    | `entry`/`call4/8/12` 硬件换窗，溢出/下陷异常搬寄存器          | `BL` + 软件压栈                         |
| 栈对齐      | 强制 16 字节（窗口 ABI）                                      | 8 字节（AAPCS）                         |
| 中断屏蔽    | PS.INTLEVEL（级别阈值）+ PS.EXCM                              | PRIMASK/BASEPRI/FAULTMASK               |
| 中断向量    | 按级别分向量（2–5 级专属）+ 窗口异常 6 槽；level 1 走异常分流 | NVIC 每个外设一个向量（表驱动）         |
| 硬件压栈    | **无**（入口桩软件保存，帧即 `XtExcFrame`）                   | 自动压 8 寄存器（xPSR/PC/LR/R12/R0–R3） |
| 栈指针      | 单一 SP（a1）                                                 | MSP + PSP 双栈                          |
| 原子操作    | S32C1I 条件存储（配 SCOMPARE1）                               | LDREX/STREX 对                          |
| 多核        | 对称双核，无硬件缓存一致性                                    | M4 单核（M7+ 可多核带一致性）           |
| 定制性      | 可配置 ISA（TIE 扩展、协处理器、FPU 可选配）                  | 固定 ISA                                |
| 任务切换帧  | 全部软件保存（`xtensa_context.h` 布局）                       | 半硬件（异常帧 + PendSV 补充）          |

> [!tip] 落到端口层：上下文切换的成本形状
> Cortex-M 上"切换"有硬件帮忙压栈；Xtensa 上**一切都是软件**——端口的汇编入口桩要把当前窗口 16 个寄存器、SAR、loop 寄存器、PS 逐个存进任务栈的 `XtExcFrame`（`portasm.S` 的 `_frxt_int_enter` 开头两句就是在存 a12/a13）。窗口 ABI 也送了一份礼：因为没有 callee-save 寄存器，**主动切换**（任务调 API 让出）要保存的东西比**被动切换**（中断打断）少得多——端口为此维护两种帧，被挂起任务的栈顶永远是这两种帧之一（`readme_xtensa.txt`）。逐指令拆解是 [[2026-08-26-freertos-deep-dive-ch7-context-switch-deep-dive|第 7 章]] 和 [[2026-08-26-freertos-deep-dive-ch17-xtensa-port-internals|第 17 章]] 的事。

---

## 2.3 中断体系：等级即秩序

### 1. 32 条中断线，六个级别

`core-isa.h` 给出 ESP32 LX6 的中断配置：共 **32 条中断**（26 条外部输入），实现 **6 个中断级别**（`XCHAL_NUM_INTLEVELS 6`，不含 0 级）+ Debug（级别 6）+ NMI（级别 7）。值得注意：PS.INTLEVEL 字段是 4 位（理论上可编码 0–15），但这颗配置只实现了 6 级——"中断级别 1–15"是 ISA 的编码上限，不是 ESP32 的现实。

几条有身份的中断线（编号→级别）：

| 中断号 | 级别 | 身份                      |
| ------ | ---- | ------------------------- |
| 6      | 1    | CCOMPARE0（核内比较器 0） |
| 7      | 1    | 软件中断 0（核内自触发）  |
| 15     | 3    | CCOMPARE1                 |
| 16     | 5    | CCOMPARE2                 |
| 29     | 3    | 软件中断 1                |
| 14     | 7    | **NMI**                   |
| 11     | 3    | profiling                 |

外设中断不直接进核，而是先进 SoC 的**中断矩阵**（interrupt matrix）被重新路由到某条核中断线上——所以"UART0 用几号中断"由软件分配决定（IDF 里是 `esp_intr_alloc()`，按级别和源动态分配）。`soc.h` 里能看到系统保留号：WiFi/BT 用 0/1/4，中断看门狗 24 或 26，跨核 IPC 用 28 或 31（取决于 `CONFIG_ESP_SYSTEM_CHECK_INT_LEVEL_*`）。

### 2. 屏蔽模型：INTLEVEL 与 EXCM 两条旋钮

Xtensa 的中断屏蔽不是 NVIC 那种每源使能的思路，而是**级别阈值**：只有"级别 > 当前阈值"的中断能进。阈值由 PS 里两个字段合成（`portmacro.h` 的 `xPortCanYield()` 注释把公式写得明明白白）：

```text
CINTLEVEL（实际阈值）= max( EXCM ? XCHAL_EXCM_LEVEL : 0 , INTLEVEL )
                                  └── ESP32 上 = 3 ──┘
```

- **PS.INTLEVEL**（bits 3:0）：软件写级别阈值，`RSIL` 类指令（读 PS 并置 INTLEVEL）一条指令原子完成"读旧值+抬阈值"——这就是临界区的硬件原语；
- **PS.EXCM**（bit 4）：异常模式位。置 1 等于把阈值一次性抬到 `XCHAL_EXCM_LEVEL`（= 3），供异常处理路径使用。

由此得出 FreeRTOS 端口层的核心事实（`portmacro.h` 原文，一行不省）：

```c
#define portDISABLE_INTERRUPTS()  do { XTOS_SET_INTLEVEL(XCHAL_EXCM_LEVEL); portbenchmarkINTERRUPT_DISABLE(); } while (0)
```

`portDISABLE_INTERRUPTS()` = 把 INTLEVEL 抬到 3。于是：

- **级别 1–3 的中断**会被内核临界区挡住——内核数据结构在被保护期间是安全的；
- **级别 4/5/Debug/NMI 挡不住**。它们的处理函数因此**永远不允许调用 FreeRTOS API**（内核没法保护自己），`readme_xtensa.txt` 把这个边界称为高优先级中断：必须纯汇编写、几条指令进出的模板。IDF 里对应 `esp_intr_alloc()` 的最高档级别，普通驱动不会碰。

### 3. 中断寄存器组与每级账本

核内中断状态全在特殊寄存器里（编号出自 `specreg.h`）：

| 寄存器                          | 作用                                                     |
| ------------------------------- | -------------------------------------------------------- |
| INTERRUPT（226，别名 INTSET）   | 只读：当前挂起的中断位图                                 |
| INTCLEAR（227）                 | 写 1 清挂起                                              |
| INTENABLE（228）                | 每源使能位图（软件控制，内核不代管）                     |
| EPC_1..EPC_7（177–183）         | 每级一份"返回 PC"                                        |
| EPS_2..EPS_7（194–199）         | 每级一份"返回 PS"                                        |
| EXCSAVE_1..EXCSAVE_7（209–215） | 每级一个暂存槽，入场第一件事就是把要用的工作寄存器存这里 |

**每个级别一组 EPC/EPS/EXCSAVE** 是 Xtensa 嵌套的硬件账本：level 5 打断 level 3 时，各自的返回状态互不覆盖，不需要软件立刻压栈。对比 Cortex-M 的每异常一帧硬件压栈，Xtensa 给的是"每级一个信封，剩下自己动手"。

### 4. 向量 vs 非向量：级别决定待遇

VECBASE（复位值 `0x40000000`，落在 ROM 里）开始的向量布局（偏移出自 `core-isa.h`）：

```text
VECBASE+0x000 ─ 窗口溢出/下陷 6 槽（0x000–0x140，OF4/UF4/OF8/UF8/OF12/UF12）
        +0x180 ─ INTLEVEL 2 向量          ┐
        +0x1C0 ─ INTLEVEL 3 向量          │ 每级一个专属向量，
        +0x200 ─ INTLEVEL 4 向量          │ 入口桩跳到 RAM 里的分发器
        +0x240 ─ INTLEVEL 5 向量          ┘
        +0x280 ─ Debug（级别 6）
        +0x2C0 ─ NMI（级别 7）
        +0x300 ─ Kernel 异常
        +0x340 ─ User 异常     ← 所有"一般异常"都落这里
        +0x3C0 ─ Double 异常   ← 异常中又异常（内核 bug 的味道）
```

两级待遇：

- **级别 2–5：向量式**。每级有专属入口（向量槽很小，放一个 stub 跳到 RAM 的分发器；`components/xtensa/xtensa_vectors.S` 提供分发框架，应用经 `xt_set_interrupt_handler()` 或 IDF 封装的 `esp_intr_alloc()` 装填按中断号索引的处理表）。
- **级别 1：非向量式**。它走的是**一般异常**路径：落入 User 向量后，处理代码读 **EXCCAUSE**，看到值 4（`EXCCAUSE_LEVEL1_INTERRUPT`，`corebits.h`）才知道"这是 level 1 中断"，再读 INTERRUPT 位图找挂起源、查 INTENABLE 找已使能源，分发到 C 处理函数。`EXCCAUSE` 的其他取值对应 syscall(1)、alloca(5)、除零(6)、非法指令(0)、协处理器未使能(32+n)等异常——也就是说 **level 1 中断与"崩溃类异常"共用一条入口**，这是 Xtensa 与 ARM 直觉差异最大的一点。

ESP32 上这些向量槽的缺省实现在 ROM 里，ROM 桩再桥接到 RAM 中可安装的分发结构——所以应用能重装中断处理函数而不动 ROM。

### 5. 嵌套秩序与 tick 的位置

规则一句话（`readme_xtensa.txt`）：**严格按级别嵌套**——高级可打断低级，同级不互相打断（同级并发挂起时按软件定义的次序处理完再放行低级）。配合 2.2 的每级 EPC/EPS 账本，中断栈深度的最坏情形可以静态推出来——readme 特别强调这给了确定性的时延与栈深上界。

最后是 tick 的落点：虽然核内有 CCOMPARE0/1/2（级别 1/3/5 各一），**IDF 没有直接用它们当 FreeRTOS 的 tick**，而是把 tick 源接到 `esp_timer` 组件（挂接代码在 `components/freertos/port_systick.c`），经中断矩阵以普通外设中断的身份进核。默认 `configTICK_RATE_HZ = 100`，1 tick = 10ms。为什么绕这一道、双核下 tick 归谁管，是 [[2026-08-26-freertos-deep-dive-ch8-priority-timeslice-rr|第 8 章]] 与第 22 章的话题。

> [!tip] 落到端口层：临界区与 FromISR 的合法域
> 把 2.2–2.3 串起来：`portENTER_CRITICAL()` 的 Xtensa 实现是 `RSIL`/`XTOS_SET_INTLEVEL(3)`（`portmacro.h` 已读），屏蔽级别 ≤3 的中断；因此**所有可能调用 `...FromISR()` API 的中断处理函数都必须跑在级别 ≤3**。ARM 上同类约束由 `configMAX_SYSCALL_INTERRUPT_PRIORITY` 表达，Xtensa 上这个值不是配置项，而是烧在 CPU 配置里的 `XCHAL_EXCM_LEVEL=3`。第 18 章会看到双核模式下这层"关中断"外面还要再套自旋锁。

---

## 2.4 内存映射：一张图装下整个地址空间

### 1. 全景图

ESP32 的地址空间按"高地址放代码、中地址放数据、低地址放只读映射"组织（边界全部出自 `soc.h`）：

```text
0x40400000 ┬─────────────────────────────────────────────┐ 上界
0x400D0000 │ IROM：Flash 代码经 cache 映射（XIP 执行区）  │
0x400C2000 ├─────────────────────────────────────────────┤
0x400C0000 │ RTC FAST 8KB（IRAM 侧视图）                  │
0x400C0000 ├─────────────────────────────────────────────┤
0x400A0000 │ D/IRAM 高段（IRAM 视角）════════════════╗    │
0x40080000 │ IRAM（SRAM0 指令 RAM）                  ║同一│
           ├─────────────────────────────────────────║物理│
0x40078000 │ APP(CPU1) cache 32KB（地址被占用）       ║存储│
0x40070000 │ PRO(CPU0) cache 32KB（同上）             ║不同│
0x40000000 │ Mask ROM 448KB（一级 boot；VECBASE 复位值═╝视图│
           │   = 0x40000000，复位向量 0x40000400）           │
0x40000000 ├─────────────────────────────────────────────┤
0x3FFAE000 │ DRAM：静态数据 + 堆（含 0x3FFE0000 起的    │
0x3FF90000 │   D/IRAM DRAM 视角，字节可访问自 0x3FF90000）│
0x3FF82000 ├─────────────────────────────────────────────┤
0x3FF80000 │ RTC FAST 8KB（DRAM 侧视图）                 │
0x3FF7FFFF ├─────────────────────────────────────────────┤
0x3FF00000 │ 外设寄存器窗口（DPORT 在 0x3FF00000，       │
           │   UART/SPI/GPIO… 散布其间）                  │
0x3FC00000 ├─────────────────────────────────────────────┤
0x3F800000 │ 外部 PSRAM 窗口（经 cache）                 │
0x3F800000 ├─────────────────────────────────────────────┤
0x3F400000 │ DROM：Flash 只读数据经 cache 映射           │
0x3F400000 ┴─────────────────────────────────────────────┘ 下界
另：0x50000000–0x50002000 RTC SLOW 8KB（深度睡眠仍保留，双核共享）
```

### 2. 分区导览（带 FreeRTOS 关切）

| 区域                   | 物理来源   | 经 cache？ | 对 FreeRTOS/IDF 的意义                                                            |
| ---------------------- | ---------- | ---------- | --------------------------------------------------------------------------------- | ------------ |
| IROM `0x400D0000+`     | 外挂 Flash | 是（每核） | 绝大部分代码住这里，XIP 执行；`IRAM_ATTR` 函数例外                                |
| DROM `0x3F400000+`     | 外挂 Flash | 是（每核） | `const` 大数据、字符串；访问走慢路径                                              |
| IRAM `0x40080000+`     | 片内 SRAM  | 否         | 中断处理函数、禁 cache 期间必须存活的代码（见下）                                 |
| DRAM `0x3FFAE000+`     | 片内 SRAM  | 否         | 全局变量 + 系统堆主体；任务栈从这里分配                                           |
| D/IRAM 双视图          | 同一 SRAM  | 否         | 一段物理存储的 IRAM/DRAM 两个别名（2.4.3）                                        |
| PSRAM `0x3F800000+`    | 外挂       | 是（每核） | 大缓冲区去处；分配需 caps（[[2026-08-26-freertos-deep-dive-ch20-idf-heap-and-caps | 第 20 章]]） |
| RTC FAST/SLOW          | 专属小 RAM | 否         | 深度睡眠保留区、ULP 协处理器的工作内存                                            |
| 外设窗口 `0x3FF00000+` | MMIO       | 否         | `volatile` 寄存器访问；DPORT 段有访问限制（2.1）                                  |

### 3. D/IRAM：同一块 SRAM 的两张脸

`0x400A0000–0x400C0000`（IRAM 视角）与 `0x3FFE0000–0x40000000`（DRAM 视角）映射到**同一块物理 SRAM**：取指令时用 0x4 前缀地址，读写数据用 0x3F 前缀地址。一个冷知识：`SOC_DIRAM_INVERTED` 标明这两个视图的**字节序是反转的**（字内字节序镜像，硬件连线所致），链接脚本因此对两个视图分别生成加载地址。这张"双脸"是 ESP32 内存紧张的解法——同一块 RAM 既可以当指令也可以当数据使。

### 4. XIP 与 cache：代码其实在 Flash 里

"程序在 Flash 里跑"的准确含义是：Flash 内容被映射进 IROM/DROM 窗口，CPU 取指/取数经过**每核 32KB 的 cache**。地址空间里 0x40070000–0x40080000 那两段被 PRO/APP cache 硬件占走，也直观提醒你 cache 的存在。

对 FreeRTOS 工程的三个直接后果：

1. **写 Flash 时必须先禁 cache**（SPI Flash 写操作与取指冲突），而 cache 一禁，任何还没执行到的 IROM 代码就是"取指即崩"。因此约定：**要在这期间存活的中断处理函数必须 `IRAM_ATTR` 放进 IRAM，其触碰的数据必须 `DRAM_ATTR`**。OTA 升级、NVS 大量写入时这条纪律就是生死线（第 24 章的排坑案例会回到这里）。
2. **两核各一份 cache 且无硬件一致性**（`XCHAL_DCACHE_IS_COHERENT 0`），对 Flash/PSRAM 的共享视图要靠软件维护（2.5 节）。
3. **哪些 Flash 页映射到哪个窗口由 flash MMU 决定**，bootloader 启动时配好——这是第 3 章启动流程的一环。

### 5. RTC 内存：掉电世界的保留地

RTC FAST 8KB（双视图 `0x3FF80000`/`0x400C0000`，深度睡眠保留、仅 CPU 可用）与 RTC SLOW 8KB（`0x50000000`，深度睡眠保留、ULP 协处理器也能访问）。FreeRTOS 的常规堆不在这里，但深度睡眠前"托孤"数据、ULP 唤醒逻辑都靠它——记地址不如记能力：**活过深度睡眠的只有这两块**。

> [!tip] 落到端口层：栈去哪、代码去哪，内核说了算
> `portSTACK_GROWTH = -1`（满递减栈，`portmacro.h`），任务栈从 DRAM 堆分配；任务函数本体多半在 IROM（经 cache），但**中断栈与切换汇编常驻 IRAM**——切换路径如果在 cache 里，禁 cache 的窗口期内连调度都做不了。栈溢出检测（栈涂 pattern、看门狗式水线）与"为什么栈大小要对齐 16"都在 [[2026-08-26-freertos-deep-dive-ch21-stack-and-memory-layout|第 21 章]] 展开。

---

## 2.5 双核对称性与共享内存的代价

### 1. "对称"到底对称在哪

PRO/APP 两颗 LX6 是**完全对称**的：同一份地址映射、同一套指令集（含各自的可选配置）、各自私有的中断控制器/INTENABLE/CCOUNT/CCOMPARE/寄存器窗口堆。没有主从——IDF 里 Core 0 承担更多系统杂务（tick、WiFi）是**软件约定**，不是硬件偏心。

推论：所有"每核一份"的 CPU 状态（PS、窗口、中断账本）天然隔离，而**所有内存天然共享**。SMP 的全部难题都长在这个交界面上。

### 2. 没有硬件缓存一致性

`core-isa.h` 明确：`XCHAL_DCACHE_IS_COHERENT 0`。两核各自的 cache 不会互相失效——核 A 改了 PSRAM/Flash 映射里的数据，核 B 的 cache 里可能还是旧值。片内 SRAM（DRAM/IRAM）不经 cache，天然强一致；麻烦集中在**经 cache 的窗口**（IROM/DROM/PSRAM）上。这就是"改了代码段/共享 PSRAM 缓冲，另一个核看不懂"一类灵异事件的物理根源，第 23 章的缓存一致性主题会给出工程解法。

### 3. 原子指令：S32C1I 与它的搭档

`core-isa.h`：`XCHAL_HAVE_S32C1I 1`（条件存储）与 `XCHAL_HAVE_RELEASE_SYNC 1`（带 acquire/release 语义的 L32AI/S32RI 访问）。**S32C1I**（Store Conditional，与 SCOMPARE1 寄存器编号 12 配合）是 Xtensa 的 LL/SC 等价物：

```text
wsr.scompare1  expected      ; 把期望值放进 SCOMPARE1
s32c1i         newval, addr  ; 若 *addr == expected 则写入 newval，
                             ; 否则把 *addr 的当前值读进寄存器
                             ; （失败不重试，由软件循环）
```

对比 ARM 的 LDREX/STREX（独占监视器、STREX 失败重试），S32C1I 是**总线级原子比较交换**——它对片内 SRAM 生效（PSRAM/外设窗口上行为另论，细节归第 23 章）。IDF 的自旋锁（`spinlock_t`）正是用它实现的，而 `portmacro.h` 里 `portMUX_TYPE` 就是 `spinlock_t` 的别名——**FreeRTOS 临界区的双核版本 = RSIL(3) 关本核中断 + S32C1I 自旋锁**，第 18 章逐行拆。

### 4. 核间怎么"喊话"

两核没有共享的中断控制器，要打断对方只能走 SoC 级机制：`portmacro.h` 里 `portYIELD_CORE(x)` 映射到 `vPortYieldOtherCore(x)`（`port.c`），后者一行调用 `esp_crosscore_int_send_yield(coreid)`——通过核间中断给目标核发信号，对端在处理函数里响应"该让出 CPU 了"。同一条路径还有个巧妙复用：`portYIELD_WITHIN_API()` 直接 `esp_crosscore_int_send_yield(xPortGetCoreID())` 给**自己**发——注释解释说，API 内部关着中断时让出会被推迟，借核间中断做"开中断后补切换"的触发器。调度器每次把高优先级任务唤醒到另一颗核时都要喊这一嗓子，这条路径的延迟直接影响 SMP 的调度品质（[[2026-08-26-freertos-deep-dive-ch23-cross-core-synchronization|第 23 章]]）。

> [!tip] 落到端口层：临界区宏带了一把锁
> 单核 Vanilla 的 `portENTER_CRITICAL()` 无参，关中断即全局安全；IDF 树的签名是 `portENTER_CRITICAL(mux)`——带一个 `portMUX_TYPE *` 参数。`portmacro.h` 的文档注释写得直白：进入 SMP 临界区 = **先关本核中断，再拿自旋锁**。内核内部用全局自旋锁保护调度器数据，驱动用各自的局部锁。这就是"硬件没有一致性协议"逼出来的软件税，逐行实现第 18 章见。

---

## 2.6 Vanilla vs ESP-IDF：一个内核，两种硬件世界观

本章暗线收拢。Vanilla FreeRTOS 的 Xtensa 端口假设的是"单颗可配置 Xtensa 核"；IDF 面对的是"双核 LX6 + 无 cache 一致性 + 每核私有中断"。同一个内核契约，长出两种端口：

| 主题         | Vanilla FreeRTOS（单核假设） | IDF FreeRTOS（双核现实）                                                                 |
| ------------ | ---------------------------- | ---------------------------------------------------------------------------------------- |
| 临界区       | `RSIL(3)` 关中断即全局安全   | 关中断只保护**本核**，`portENTER_CRITICAL(mux)` 再套 S32C1I 自旋锁                       |
| 当前任务指针 | `pxCurrentTCB` 单变量        | `pxCurrentTCBs[]` 每核一个（`portasm.S` 里 `.extern pxCurrentTCBs`）                     |
| 让出另一核   | 概念不存在                   | `portYIELD_CORE()` → `vPortYieldOtherCore()` → `esp_crosscore_int_send_yield()` 核间中断 |
| 核号         | 无                           | `portGET_CORE_ID()` → `esp_cpu_get_core_id()`                                            |
| ISR 临界区   | 关中断即安全                 | 同一把锁的任务/ISR 两用版本（`vPortEnterCritical` 同时被两者复用）                       |
| 中断屏蔽边界 | `XCHAL_EXCM_LEVEL` 硬编码    | 同样基于 `XCHAL_EXCM_LEVEL=3`，但 FromISR 的合法域要按"另一核可能同时进内核"重新论证     |

更深一层的观察：这些差异**全部来自本章的硬件事实**——没有一致性协议所以要自旋锁，核私有中断控制器所以每核一份 `pxCurrentTCBs`，无共享向量所以核间喊话走 DPORT。第 22 章讲 SMP 改造全景时，你会发现改造清单就是本章清单的软件投影。

---

## 2.7 小结

- ESP32 = 对称双核 Xtensa LX6 @240MHz + 共享 SRAM + 每核 32KB cache（**无硬件一致性**，`XCHAL_DCACHE_IS_COHERENT 0`）+ 经 cache 映射的 Flash/PSRAM。PRO_CPU/APP_CPU 是 Core 0/1 的历史别称。
- Xtensa 编程模型的核心异类是**窗口寄存器**：64 个物理寄存器、16 个可见、`call4/8/12` 硬件换窗、溢出/下陷异常搬栈、无 callee-save、SP 强制 16 字节对齐。它决定了上下文切换"全软件、两种帧"的形状（`xtensa_context.h` 的 `XtExcFrame`：PC/PS/a0–a15/SAR/EXCCAUSE/EXCVADDR/loop 三件套）。
- 中断是**级别阈值**模型：32 线 6 级 + Debug/NMI，`CINTLEVEL = max(EXCM?3:0, INTLEVEL)`；端口用 `XTOS_SET_INTLEVEL(XCHAL_EXCM_LEVEL)` 做临界区，因此 **FromISR 只对级别 ≤3 合法**；级别 2–5 向量式、级别 1 走 User 异常按 `EXCCAUSE=4` 分流；每级一组 EPC/EPS/EXCSAVE 支持严格按级嵌套。
- 内存映射一图流：IROM/DROM/PSRAM 经 cache，IRAM/DRAM 直连，D/IRAM 是同一 SRAM 的双视图（字节序反转），RTC 两块 8KB 活过深度睡眠；**写 Flash 禁 cache 期间只有 IRAM 代码能跑**，这就是 `IRAM_ATTR`/`DRAM_ATTR` 纪律的由来。
- 双核的"税"：S32C1I 原子指令是自旋锁的地基，核间让渡靠 crosscore 中断（还复用为"API 内关中断期的延迟让出"触发器）；临界区宏因此带上了 `portMUX_TYPE` 参数——Vanilla 与 IDF 的端口差异全部可以追溯到这些硬件事实。
- 实验：内联汇编 `rsr.*` 读 PS/WINDOWBASE/CONFIGID0/CCOUNT，亲眼看到窗口随 `call4` 旋转、PS 的 WOE/CALLINC/OWB 位、以及与 `core-isa.h` 对得上号的配置指纹。

硬件底座补齐了。但固件从上电到 `app_main` 之间还隔着一整段旅程：ROM 里的一级 boot、Flash 里的二级 bootloader、分区表、flash MMU 映射、两颗核怎么先后爬起来、`main` 任务从哪被创建——这些系统级机制不弄清，后面读内核初始化代码时会处处踩空。下一章进入 [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow|第三章：ESP-IDF 构建体系与固件启动流程]]。
