---
title: "嵌入式硬件基础（九）：RISC-V 侧起点——GD32VF103 与双架构对照"
date: 2026-08-30 09:00:00
description: "从 RV32IMAC 逐字母拆解到 CSR 显式编号空间（mtvec/mepc/mcause/mstatus 对照 Cortex-M 的隐形特殊寄存器），核心是两段语义等价的最小异常处理汇编并排对照——Cortex-M 硬件压 8 寄存器 vs RISC-V 软件 trampoline；再如实展开 Nuclei ECLIC 的类向量能力（mtvt 表 + 咬尾，打破'RISC-V 无向量分发'的脸谱）、GD32VF103 与 STM32F103 的寄存器改名对照表（RCC→RCU、CRL/CRH→CTL0/CTL1、无位带），最后以 nuclei-sdk 实证启动文件/链接脚本讲 crt0 差异并预告工具链——本章无板无 RISC-V 工具链，汇编给源码可人工核对，全部锚点来自官方手册原文。"
tags: [embedded-basics, STM32, RISC-V]
---

> [!info] 嵌入式硬件基础系列 0. [[embedded-basics|系列索引]] · 8. [[ch08-timer-systick|上一章：定时器]] · 9. **第九章：RISC-V 侧起点** · 10. [[ch10-i2c-spi-theory|下一章：I2C/SPI 协议理论]]（并行写作中）

# 嵌入式硬件基础（九）：RISC-V 侧起点——GD32VF103 与双架构对照

[[ch01-roadmap-and-boards|第一章]] 说过本系列的学习法：GD32VF103 是 STM32F103 的"寄存器级双胞胎"——兆易创新把 F103 的身体（外设、总线、内存映射）几乎原样保留，心脏换成了芯来科技的 Bumblebee 内核（RV32IMAC，108MHz）。前面八章我们把 Cortex-M 侧从寄存器组、向量表、启动文件一路打到定时器；现在换阵营，同一个问题集在 RISC-V 上重新问一遍——**答案相同的地方是"外设知识"，答案不同的地方就是"架构知识"**。

先交代本章的验证边界（SPEC §3.2）：**本机没有 RISC-V 裸机工具链，也没有 GD32 实体板**。所以本章没有 QEMU 实跑和 gdb 会话，取而代之的是两类硬锚点：

1. **官方手册原文**：Bumblebee 内核《指令架构手册》（芯来，nucleisys/Bumblebee_Core_Doc 仓库 PDF，下称"Bumblebee 手册"，章节号按该版标注）、RISC-V 特权级规范、GD32VF103 用户手册；
2. **官方代码实证**：nuclei-sdk（Nuclei-Software/nuclei-sdk，master 分支）里 GD32VF103 的启动文件 `startup_gd32vf103.S`、链接脚本 `gcc_gd32vf103_flashxip.ld`、设备头 `gd32vf103.h`——这些是官方在真芯片上跑过的代码，比任何博客可信。

汇编示例全部给出可人工核对的源码（语义与 Cortex-M 侧逐条对齐），但不要求本机编译；工具链安装路径见 9.7。所有"真机行为"论断都注明出处，推断处显式标注。

---

## 9.1 RV32IMAC：一个字符串就是一个 ISA

ARM 世界里"芯片支持什么指令"要看架构版本（ARMv7-M）、核型号（Cortex-M3/M4F）两层名字；RISC-V 把这件事压成一个字符串：**RV32IMAC**——32 位基础整数指令集 + 五个标准扩展字母的组合。逐字母拆（Bumblebee 手册 §1.2 原文口径）：

| 字母 | 全称                       | 内容                                                  | 对嵌入式的意义                                            |
| ---- | -------------------------- | ----------------------------------------------------- | --------------------------------------------------------- |
| RV32 | 基础整数指令集（I）        | 约 47 条指令、32 个通用寄存器 x0-x31、load/store 访存 | 一切的地基；注意 x0 **恒为零**，读它永远得 0              |
| M    | 整数乘除（Multiplication） | `mul`/`div`/`rem` 等                                  | 没有它，`a*b` 会链接进 `__mulsi3` 软件例程——慢且费 flash  |
| A    | 原子操作（Atomic）         | LR/SC（`lr.w`/`sc.w`）与 AMO（`amoswap.w` 等）        | 自旋锁、无锁数据结构的地基（单核 MCU 详见下文取舍）       |
| C    | 压缩指令（Compressed）     | 16 位编码的常用指令子集                               | 代码密度提升、取指带宽减半——对标 ARM 的 Thumb             |
| -    | （没有 F/D）               | 无单精度/双精度浮点硬件                               | float 走 `__mulsf3` 等软浮点例程；对照 F407 的 M4F 硬 FPU |

四个字母背后是四个可以对照 ARM 讲的差异点：

1. **x0 恒零是最便宜的"常数 0"**。Cortex-M 想清个寄存器要 `movs r3, #0`；RISC-V 里 `addi a0, zero, 0` 是废话，直接用 `zero` 当源操作数就行——`mv rd, rs` 实际是 `addi rd, rs, 0`，`nop` 是 `addi zero, zero, 0`。没有 NZCV 条件标志寄存器：比较结果直接写进寄存器（`slt`/`blt` 用寄存器对寄存器比较），条件码无处保存也就无处恢复——这是 trampoline 保存集比 ARM 短的原因之一（9.3 节）。

2. **无 FPU 是 GD32 侧与主线 F407 的最大日常差异**。F407（Cortex-M4F）的 float 是硬件指令 + 32 个浮点寄存器；GD32VF103 上 `float` 变量运算编译成一串整数指令和库调用。对 DSP/PID 类代码这是量级差异，也是 ch01 把 CH32V307（RV32 带单精度 FPU）列为"毕业后升级位"的原因。

3. **A 扩展在单核 MCU 上的真实用法**。手册口径明确：A 含原子操作指令（Bumblebee 手册 §1.2 "A：支持原子操作指令"）。但单核裸机里最常用的"原子"仍然是**关中断**（`csrc mstatus, MIE` 一条指令，语义等同 `cpsid i`）——RTOS 的临界区、`count++` 原子化，单核上关中断比 LR/SC 循环更短更可预测。A 的不可替代场景是多核（GD32VF103 单核，用不上）与免关中断的低延迟路径。**真机上 AMO 子集的实际可用性待板到后用 illegal-instruction 探针核实**（小核对 A 的裁剪实现业界并不罕见，如 ESP32-C3 干脆是 RV32IMC 无 A）。

4. **C 与 Thumb 的殊途同归**。ARM 用两种指令集状态（ARM/Thumb）加 interworking 解决代码密度；RISC-V 的 C 是"同一 ISA 内的 16 位编码"，取指单元按指令位模式自动识别 16/32 位混排，没有模式切换这回事。对写启动文件的人，这带来一个实际便利：**RISC-V 向量表里没有 Thumb bit**（对照 ch03 的"表项=地址|1"）——函数指针就是函数地址。

> [!tip] 对照速记
> RV32IMAC ≈ "Cortex-M3 减 FPU 加双倍寄存器减条件标志"。寄存器翻倍（16→32）但其中一个是常数零；没有标志寄存器意味着没有"指令把状态藏进 CPU"这回事——**RISC-V 的哲学是状态要么在通用寄存器里、要么在 CSR 里，明码标价**。这正是下一节。

---

## 9.2 CSR 世界观：把 ARM 的"隐形寄存器"晒在编号空间里

[[ch03-arm-cortex-m-anatomy|第三章]] 里 Cortex-M 的控制状态是这么藏的：

- **MRS/MSR 专用指令访问的"特殊寄存器"**：MSP/PSP（SP 的银行化备份）、PRIMASK/BASEPRI/FAULTMASK、CONTROL——它们不在内存里，没有地址，普通 load/store 碰不到；
- **内存映射的系统控制空间**：NVIC 一族（`0xE000E100` 起）、VTOR（`0xE000ED08`）——有地址，但地址属于 ARM 架构私有保留段。

RISC-V 的答案是一个统一的**12 位编号空间（0~4095）**：每个 CSR 有个编号，全部用 `csrrw`/`csrrs`/`csrrc`（及立即数变体）这一族指令访问。`csrrs rd, csr, rs` 一步完成"读旧值到 rd、按位或写新值"——原子读改写是 CSR 指令的原生语义，所以"置一位"是 `csrs`（csrrs 别名）、"清一位"是 `csrc`，不需要 ARM 侧 `MRS→改→MSR` 的三段式。

机器模式（M-mode，MCU 裸机唯一的家）的标准 CSR 一张表（地址依 nuclei-sdk `riscv_encoding.h`，与特权规范一致）：

| CSR      | 地址  | 作用                                                       | Cortex-M 里的"等价物"                                      |
| -------- | ----- | ---------------------------------------------------------- | ---------------------------------------------------------- |
| mstatus  | 0x300 | 全局状态：MIE(bit3)全局中断使能、MPIE(bit7)、MPP(bit12:11) | PRIMASK（反逻辑：MIE=1 允许/PRIMASK=1 屏蔽）+ 隐式的模式位 |
| mie      | 0x304 | 三个标准中断源使能（MSIE/MTIE/MEIE 位图）                  | NVIC ISER（ECLIC 接管后此 CSR 退居二线，见 9.4）           |
| mtvec    | 0x305 | trap 入口基址 + 模式位                                     | VTOR + 向量表首两项的合体                                  |
| mscratch | 0x340 | 软件自由使用的暂存 CSR                                     | 无——它是软件复刻 MSP/PSP 双栈的关键道具（9.3）             |
| mepc     | 0x341 | trap 返回地址                                              | 栈帧里的 PC 字（+24）                                      |
| mcause   | 0x342 | trap 原因：bit31 中断/异常 + bit11:0 编码码                | IPSR（当前异常号）+ 栈帧 xPSR                              |
| mtval    | 0x343 | 出错地址（访问错时）                                       | BFAR/MMFAR                                                 |
| mip      | 0x344 | 中断挂起位图（含软件写 1 触发的 MSIP）                     | NVIC ISPR——"软件触发中断"两边都有                          |

对照出三个世界观差异：

**一、异常返回三元组 vs EXC_RETURN 魔法值。** Cortex-M 把返回现场编码进 LR 的魔法值（`0xFFFFFFF9`，ch03 实测），`bx lr` 一条指令触发硬件出栈序列。RISC-V 没有魔法值：硬件在进入 trap 时把返回地址写进 **mepc**、原因写进 **mcause**、把 mstatus 的 MIE 摘到 MPIE、MPP 记下先前特权级——**mepc/mcause/mstatus 就是"异常返回三元组"**，返回用专用指令 `mret`（PC←mepc，MIE←MPIE，模式←MPP）。ch03 讲过"返回语义编码在 LR 值里"，这里是"返回语义编码在三个 CSR 里"——前者省寄存器，后者全部可读可改可保存（嵌套处理因此直观）。

**二、mtvec：一个基址，两种模式。** 标准 RISC-V 的 mtvec 是"BASE[31:2] + MODE[1:0]"：MODE=0 直接模式（所有 trap 跳 BASE），MODE=1 向量模式（中断跳 `BASE + 4×cause`，异常仍跳 BASE）。注意标准向量模式的表项里放的是**一条跳转指令**（4 字节只装得下一条 `j`），不是函数指针——与 Cortex-M"表项=数据（地址|1）"是本质不同的两种查表。Bumblebee 对 mtvec 做了扩展（手册表 7-3）：BASE 压缩到 31:6，MODE 扩到 6 位，`MODE=6'b000011`（即 3）选择 **ECLIC 中断模式**（推荐模式），其余值为默认中断模式。这解释了官方启动文件里的著名三行（9.6 节逐行讲）：

```asm
    li      t0, 0x3f
    csrc    CSR_MTVEC, t0          # 清 MODE[5:0]
    csrs    CSR_MTVEC, 0x3         # 置 3 = ECLIC 模式
```

**三、厂商扩展也有编号纪律。** Nuclei 的自定义 CSR 挤在同一编号空间的标准保留区里（地址依 nuclei-sdk `riscv_encoding.h`）：**mtvt**（0x307，ECLIC 向量表基址）、**mnxti**（0x345）、**mintstatus**（0x346，当前中断级别）、**mscratchcsw**（0x348）、**mdcause**（0x7c9，细化 trap 原因）、**mtvt2**（0x7EC，非向量中断公共入口）、**jalmnxti**（0x7ED，"跳转下一中断"，9.4 的主角）、**pushmcause/pushmepc/pushmsubm**（0x7EE/0x7EF/0x7EB，硬件辅助压栈）。它们没有特权规范背书，换一家 RISC-V 厂商（比如 WCH 的 CH32V 用 PFIC）就换成另一套——**"标准件 vs 厂商件"的分界线在这里第一次显形**，9.4 会展开成 ECLIC 整节。

> [!note] 为什么"显式编号空间"是好事
> 给软件人的类比：ARM 的特殊寄存器像 `/proc/sys` 里没有路径的内核变量，只能用专用 syscall（MRS/MSR）摸；RISC-V 的 CSR 像把所有内核旋钮编进一张统一的 sysctl 表——工具（gdb、openocd、性能计数器）可以不认识每个 CSR 的语义，只凭编号就能读写。第十二章看 FreeRTOS RISC-V port 时会发现它的临界区代码只有三条 CSR 指令，可移植性肉眼可见。

---

## 9.3 异常处理路径对照：两段语义等价的汇编（本章核心）

这是双架构分歧最大的一处，值得逐行对。任务定义：**CPU 遇到异常（同步 trap），保存被打断的现场，让一个 C 函数处理，然后无损返回继续执行**。

### 1. Cortex-M 侧：三行用户代码，其余全是硬件

ch03 的 QEMU 实证版本（`-M mps2-an385`，8 个魔数逐字命中），全貌：

```asm
    /* 触发端：SVC 指令 = 主动异常（同步 trap） */
    ldr     r0, =0xAAAA0001        /* 给 caller-saved 寄存器塞魔数   */
    svc     #0                      /* ← 触发 SVCall（异常号 11）      */

    /* 处理端：handler 是普通 C 函数的汇编形态 */
SVC_Handler:
    bx      lr                      /* LR=EXC_RETURN → 硬件出栈返回    */
```

`svc` 与 `bx lr` 之间，硬件隐式完成了 ch03 验尸过的整条序列：取向量表（VTOR→表项 11）→ 压 8 寄存器（R0-R3/R12/LR/PC/xPSR，恰好是 AAPCS 的 caller-saved 集）→ LR←EXC_RETURN、IPSR←11、切 Handler 模式 → 跳转。**用户可见指令 0 条，硬件状态机约 12 周期**（Cortex-M3 TRM 口径）。

### 2. RISC-V 侧：trampoline，每一步都是显式指令

语义等价的最小实现（非嵌套版；寄存器保存集取 RISC-V ABI 的 caller-saved 集：ra、t0-t6、a0-a7 共 16 个——与 Bumblebee 手册 §5.13.1"RV32I 架构需保存 16 个通用寄存器"同一口径）：

```asm
    .section .text
    .align  2                       # mtvec 基址须 4 字节对齐（手册 §7.4.13）
    .global trap_entry
trap_entry:
    addi    sp, sp, -76             # 16 GPR + mepc/mcause/mstatus 各 1 槽
    sw      ra,  0(sp)
    sw      t0,  4(sp)              # 先保存 t0 原值——下面要拿它当暂存
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)              # a0-a7、t3-t6 依次……（省略 8 行 sw）
    sw      t6, 60(sp)
    csrr    t0, mepc                # 此后才动 t0：原值已在栈上
    sw      t0, 64(sp)
    csrr    t0, mcause
    sw      t0, 68(sp)
    csrr    t0, mstatus
    sw      t0, 72(sp)

    csrr    a0, mcause              # C 函数参数：原因码
    call    trap_dispatch           # 读 mcause 分发的 C 函数（轮询读外设标志位等）

    lw      t0, 64(sp)              # 处理器可能改过 mepc（如跳过故障指令）
    csrw    mepc, t0
    lw      t0, 68(sp)
    csrw    mcause, t0
    lw      t0, 72(sp)
    csrw    mstatus, t0
    lw      ra,  0(sp)              # 逆序恢复 16 个 GPR（省略 13 行 lw）
    lw      t6, 60(sp)
    addi    sp, sp, 76
    mret                            # 硬件：PC←mepc, MIE←MPIE, 特权级←MPP
```

### 3. 并排对照表：同一段旅程，两种分工

| 步骤（语义）             | Cortex-M 实现                       | RISC-V 实现                                                     | 谁付代价                      |
| ------------------------ | ----------------------------------- | --------------------------------------------------------------- | ----------------------------- |
| 记录返回地址             | 硬件压栈帧 PC 字（+24）             | 硬件写 mepc，软件再 `sw` 入栈                                   | RISC-V 多 2 条指令            |
| 保存 caller-saved 寄存器 | 硬件压 8 个（R0-R3/R12/LR/PC/xPSR） | 软件 16 个 `sw`（ra/t0-t6/a0-a7）                               | RISC-V 多 ~16 条指令          |
| 保存状态/标志            | xPSR 压栈（1 个字）                 | 无 NZCV 可存；mstatus 由硬件摘到 MPIE/MPP，软件按需入栈         | ARM 表面免费、实绑死 8+1 个字 |
| 知道"我是谁"（原因）     | IPSR 自动更新，handler 甚至可以不读 | 必须显式 `csrr mcause`（分发的依据）                            | RISC-V 必须多 1 条            |
| 找到 handler             | 硬件查向量表（表项=地址）           | 跳 mtvec 基址 + 软件读 mcause 分发（或 ECLIC 硬件向量，见 9.4） | 标准模式下 RISC-V 多数条      |
| 执行用户处理逻辑         | 普通 C 函数（现场已被硬件清干净）   | 普通 C 函数（现场已被 trampoline 清干净）                       | 等价——两边都借了 ABI          |
| 返回                     | `bx lr`（EXC_RETURN 触发硬件出栈）  | 恢复 mepc/mcause/mstatus + 16 个 `lw` + `mret`                  | RISC-V 多 ~20 条指令          |

两句总评：

- **ARM 用晶体管换指令数**：入栈序列固化在硬件里，最快最省代码，但保存集是架构死的（8 个字；浮点上下文另需扩展帧），中间不容软件插手；
- **RISC-V 用代码换灵活性**：保存集可裁剪（handler 不碰 a 寄存器就只存 ra）、可换栈（下一节）、可按需 lazy 保存，代价是每次 trap 多几十条指令的"过路费"。

### 4. mscratch：软件复刻 MSP/PSP 双栈

ch03 的基石是"中断永远用 MSP、任务用 PSP"。RISC-V 只有一个 `sp`，双栈怎么来？标准配方（FreeRTOS RISC-V port 用的正是它）：

```asm
trap_entry:
    csrrw   sp, mscratch, sp        # 原子互换：sp↔mscratch
    # 现在 sp=handler 栈，mscratch=被打断者的 sp
    sw      ra, 4(sp)               # 把现场保存到 handler 栈……
    # ……处理、恢复……
    csrrw   sp, mscratch, sp        # 换回任务栈
    mret
```

`csrrw` 的原子互换语义在这里刚好好用：一条指令完成"取出暂存值、存入新值"。**mscratch 这个 CSR 的存在理由就是 trap 处理**——特权规范给它派的唯一任务就是"给 trap 入口程序放一个字"。对照：Cortex-M 把"handler 有自己的栈"做成了硬件规则，RISC-V 把它做成了一个 CSR + 两条指令的软件惯例。第十二章 FreeRTOS 三架构 port 对照时，这段会再出现一次。

> [!warning] 语义等价的边界（诚实声明）
> 上面两段汇编在"保存 caller-saved 现场→进 C→恢复→无损返回"这一层语义等价，可人工核对；但 Cortex-M 版天然支持抢占嵌套（硬件自动换 MSP、尾部链），RISC-V 最小版不支持（MIE 已清、mcause 会被新 trap 覆盖）。官方非嵌套入口还要多保存 msubm（Nuclei 的"机器子模式"CSR），并用 9.4 的 jalmnxti 实现咬尾——真机上以 nuclei-sdk `startup_gd32vf103.S` 的 irq_entry 为准。本章示例定位是教学最小版。

---

## 9.4 ECLIC：Nuclei 给 RISC-V 补的 NVIC——以及为什么"RISC-V 无向量分发"是过时脸谱

先把标准 RISC-V 的"贫瘠"说清楚。特权规范给的中断设施只有：mie/mip 两个位图 CSR + 三个预定义源（软件 MSIP、时钟 MTIP、外部 MEIP）+ CLINT 参考内存映射。没有优先级数字、没有电平/边沿配置、没有嵌套控制、向量分发只有 mtvec 那两种模式——**规范故意只写"最小可组合"，剩下的交给厂商扩展**。Nuclei 的答案是 ECLIC（Enhanced Core Local Interrupt Controller），GD32VF103 上它是一块内存映射单元：

- 基址 **0xD2000000**（nuclei-sdk `gd32vf103.h`：`__ECLIC_BASEADDR`）；
- 共 **86 个中断源**（同头文件 `__ECLIC_INTNUM 86`，ID 0~85）：ID 0-18 留给核内（3=机器软件中断、7=机器定时器中断、17=总线错误、18=性能监控，nuclei-sdk 启动文件的向量表注释），**ID 19 起接芯片外设**（19=WWDGT、25=EXTI0、43=TIMER0_BRK、56=USART0……清单镜像 STM32F103 的 IRQ 列表）。注意与 Cortex-M 的编号哲学差异：NVIC 是"16 系统异常 + IRQ0 从 16 起"的**两段式编号**，ECLIC 把核内源和外设 IRQ 编进**同一个连续号空间**——SysTick 的对应物（machine timer）也住在表里。

寄存器布局（Bumblebee 手册表 6-5，与 NMSIS `core_feature_eclic.h` 一致）：

| 寄存器         | 偏移         | 作用                                                                   |
| -------------- | ------------ | ---------------------------------------------------------------------- |
| cliccfg        | 0x0000       | nlbits[4:1]：clicintctl 里"级别"占几位                                 |
| clicinfo       | 0x0004       | 只读：NUM_INTERRUPT[12:0]、CLICINTCTLBITS[24:21]                       |
| mth            | 0x000B       | M 态中断级别阈值                                                       |
| clicintip[i]   | 0x1000 + 4·i | 每中断一管：挂起标志                                                   |
| clicintie[i]   | 0x1001 + 4·i | 每中断一管：使能                                                       |
| clicintattr[i] | 0x1002 + 4·i | trig[2:1] 触发方式（0=电平，2=上升沿，3=下降沿）、shv(bit0) 向量化开关 |
| clicintctl[i]  | 0x1003 + 4·i | 级别+优先级（宽窄由 nlbits/clicintctlbits 决定，GD32VF103 实现 4 位）  |

每中断"一管四小格"（ip/ie/attr/ctl 各 1 字节，按 4 字节步进排布）的布局值得看一眼：NVIC 是"按功能分组、每组长寄存器管 32 线"，ECLIC 是"按中断分组、每线自己的四个属性挤在一管"——配置一个中断只需要碰一个 4 字节对齐的字，多中断并发配置时没有伪共享。

### 1. shv + mtvt：货真价实的硬件向量分发

脸谱化的说法是"RISC-V 中断没有向量表"。如实版：**标准规范确实只有 direct/vectored 两档；但 ECLIC 给了每个中断独立的 shv 开关**——`clicintattr[i].shv=1` 时，硬件响应中断后**直接查询 mtvt 指向的向量表、取出表项里存的函数地址、跳进去**（Bumblebee 手册 §5.13.2"硬件自动查询中断向量表，直接跳入相应的中断服务程序"）。三个此前散落的事实在这里合流：

- mtvt（CSR 0x307）指向的表，**表项存的是 PC 地址（函数指针），不是跳转指令**（手册图 5-6）——形态上这就是一张 Cortex-M 式向量表；对齐要求随中断数增长（65~128 个中断源需 512 字节对齐，手册 §7.4.14）；
- 官方启动文件把这张表（`.text.vtable` 段）放在映像最前、`_start` 紧随其后，表首槽位放一条 `j _start` 指令——**复位时 CPU 从映像第一字开始执行，它恰好是那条跳转**（详见 9.6）；
- 向量模式的延迟口径：**理想约 6 个时钟周期进入 ISR 第一条指令**（手册 §5.13.2.1）——比 Cortex-M 的约 12 周期还短，因为什么都没保存。

代价也如实：向量模式**默认不嵌套**（响应中断时硬件自动清 MIE），ISR 必须是叶函数——GCC 的 `__attribute__((interrupt))` 修饰符在检测到非叶函数时自动插入保存序列（此时延迟退化到与非向量模式相当，手册原文警告了这一点）。对照 Cortex-M：向量分发+硬件压栈+自动嵌套三件套是默认全家桶；ECLIC 把三件拆开，**每个中断单独选**"快而不嵌套（shv=1）"或"可嵌套可咬尾（shv=0）"——粒度更细，心智负担也更大。

### 2. 非向量模式与 jalmnxti：软件咬尾

shv=0 的中断共享公共入口：mtvec 指定（若 mtvt2[0]=0）或 mtvt2 指定（推荐，mtvt2[0]=1，把中断公共入口和异常入口彻底分开——官方启动文件两处都设了）。公共入口的代码就是 9.3 的 trampoline 加一条魔法指令（手册 §5.13.1 图 5-9）：

```asm
common_entry:
    <保存 mepc/mcause/msubm 入栈>        # msubm 是 Nuclei 的机器子模式 CSR
    <保存 16 个 caller-saved GPR 入栈>
    csrrw   ra, CSR_JALMNXTI, ra         # 读 0x7ED：取下一中断并跳转
    <恢复 GPR>
    <关 MIE 后恢复 mepc/mcause/msubm>    # 手册强调：恢复三元组要原子（先关全局中断）
    mret
```

`csrrw ra, jalmnxti, ra` 一条指令干三件事：无 pending 时是 NOP；有 pending 时直接跳进那个中断的 ISR（硬件开 MIE 允许嵌套），并像 `jal` 一样把返回地址链回 ra——**ISR 返回后回到这条指令重新检查**，于是背靠背的中断省掉一整轮"恢复现场+保存现场"。这就是 Bumblebee 手册 §5.13.1.3 的"中断咬尾"（tail-chaining 的直译）：**Cortex-M 用硬件状态机做的事（ch07 讲的尾部链，12 周期→6 周期），ECLIC 用一条特殊 CSR 指令做到同型效果**。"RISC-V 没有尾部链"这句话，在 Bumblebee 上不成立。

### 3. NVIC vs ECLIC 编程模型对照表

| 维度          | Cortex-M NVIC（ch07）                 | ECLIC（GD32VF103）                                     |
| ------------- | ------------------------------------- | ------------------------------------------------------ |
| 归属          | ARM 架构内建（SCS 0xE000E100 起）     | Nuclei 厂商扩展（0xD2000000）+ 若干 CSR                |
| 使能          | ISER0 写 1（W1S）                     | clicintie[i] = 1                                       |
| 挂起          | ISPR0 写 1（软触发）                  | clicintip[i] = 1（软触发）                             |
| 优先级        | IPR 字节 + AIRCR.PRIGROUP 分组        | clicintctl[i] 按 nlbits 切成 level/priority + mth 阈值 |
| 触发方式      | 无（NVIC 只认电平，边沿靠 EXTI 整形） | clicintattr[i].trig 每线可选电平/上升/下降             |
| 向量化        | 全表向量化（VTOR 表项=地址）          | 每中断 shv 位独立开关；mtvt 表项=地址                  |
| 全局开关      | PRIMASK/BASEPRI（分层屏蔽）           | mstatus.MIE（一层）+ mth 阈值（按级别门槛）            |
| 嵌套          | 硬件自动（优先级仲裁）                | 非向量模式 jalmnxti 开 MIE；向量模式要软件开           |
| 软中断        | PendSV/ISPR                           | msip（SysTimer 单元 +0xFFC 写 1）                      |
| 换一家 RISC-V | 同款（ARM 标准件）                    | 换芯换一套（CH32V 是 WCH 的 PFIC）                     |

一个体感差异值得单说：**ECLIC 有"级别（level）"这个 NVIC 没有一等公民概念**——clicintctl 的高 nlbits 位是级别（决定能否抢占与咬尾），低位是优先级（同级仲裁），mth 是当前允许进入的级别门槛，mintstatus（CSR 0x346）实时记录 M 态当前级别。NVIC 的抢占优先级/子优先级分组（ch07 的 AIRCR.PRIGROUP）在功能上可映射，但 ECLIC 的级别是显式的、可读回的——RTOS 移植层对此的处理方式不同，第十二章见。

### 4. 手把手对照：使能 USART0 中断

同一件事（打开 USART0 的接收中断）两侧的最小代码，感受一下编程模型的形状差异。Cortex-M 侧（ch07 的姿势，寄存器级）：

```c
NVIC_IPR[USART0_IRQn] = 2u << 4;        /* 设优先级（F103 实现 4 位） */
NVIC_ISER0 = 1u << (USART0_IRQn);       /* 使能 IRQ（W1S，直写不清别人） */
USART0_CR1 |= USART_CR1_RXNEIE;         /* 外设侧：事件源上报 NVIC */
```

GD32VF103 侧（官方固件库 API，签名取自 nuclei-sdk `gd32vf103_eclic.h`，寄存器语义即 9.4 开头那张表）：

```c
eclic_priority_group_set(ECLIC_PRIGROUP_LEVEL3_PRIO1);  /* nlbits=3：级别/优先级切分 */
eclic_irq_enable(USART0_IRQn, 1, 1);    /* 设级别+优先级并使能（写 clicintie/clicintctl） */
eclic_global_interrupt_enable();        /* csrs mstatus, MIE —— 对应"PRIMASK 清零" */
USART0_CTL0(USART0) |= USART_CTL0_RBNEIE;  /* 外设侧：事件源上报 ECLIC（GD32 改名：RXNE→RBNE） */
```

三个观察：ECLIC 版**必须记得开全局**（mstatus.MIE 上电默认 0，漏掉则一切静默——症状是"外设标志位在跳、程序毫无反应"，排查时先 `csrr` 读 MIE）；**触发方式要按外设脾气配**（clicintattr 的 trig，USART 这类读后自清的用边沿或电平皆可，GPIO 按键则要配边沿+消抖，细节真机章展开）；**中断函数的写法取决于 shv**——shv=1 向量模式要 `__attribute__((interrupt))` 且当叶函数写，shv=0 非向量模式写普通 C 函数（由公共入口 trampoline 统一保存现场）。Cortex-M 侧"中断函数=普通 C 函数"这条铁律，在 RISC-V 侧被拆成了两选一。

---

## 9.5 GD32VF103 外设侧：F103 的改名对照表与三处如实差异

外设是"身体"的部分，理论上是平移。但平移要过三关：**改名关、位带关、启动关**。

### 1. 改名对照表（断言依据：nuclei-sdk `gd32vf103_*.h` 头文件与 GD32VF103 用户手册）

| 外设/概念    | STM32F103（RM0008）         | GD32VF103                                      | 备注                             |
| ------------ | --------------------------- | ---------------------------------------------- | -------------------------------- |
| 时钟控制器   | RCC                         | RCU（Reset & Clock Unit）                      | 寄存器族 RCU_APB2EN 等对应改后缀 |
| GPIO 模式    | CRL/CRH（0x00/0x04）        | CTL0/CTL1（0x00/0x04）                         | 偏移一字不差，每引脚 4 bit 同构  |
| GPIO 输入    | IDR（0x08）                 | ISTAT（0x08）                                  |                                  |
| GPIO 输出    | ODR（0x0C）                 | OCTL（0x0C）                                   |                                  |
| GPIO 置位    | BSRR（0x10）                | BOP（0x10）                                    | 高 16 位清、低 16 位置同款       |
| GPIO 复位    | BRR（0x14）                 | BC（0x14）                                     |                                  |
| USART        | SR/DR/BRR/CR1/CR2/CR3       | STAT/DATA/BAUD/CTL0/CTL1/CTL2                  | 偏移完全相同（0x00~0x14）        |
| EXTI         | IMR/EMR/RTSR/FTSR/SWIER/PR  | INTEN/EVEN/RTEN/FTEN/SWIEV/PD                  | 偏移完全相同（0x00~0x14）        |
| 定时器       | TIM1（高级）/TIM2-4（通用） | TIMER0（高级）/TIMER1-3（通用），另有 TIMER4-6 | IRQ 名同步改（TIMER0_BRK 等）    |
| Flash 控制器 | FLASH（KEYR/CR/SR）         | FMC                                            | 页擦写流程同构                   |
| AFIO         | AFIO_EXTICR1-4              | AFIO_EXTISS0-3                                 | EXTI 源选择，功能同名异          |

规律：**布局不变、缩写体系变**——ST 用"名词首字母"（Control Register High→CRH），GD32 用"类型+序号"（CTL1）。把 RM0008 的知识平移过来时，对照这张表查名即可；反过来也说明为什么 ch01 说"手册同源"：GD32VF103 用户手册的章节组织镜像 RM0008。

### 2. 位带：F103 有、GD32VF103 没有

Cortex-M3 的位带（bit-band）把 `0x40000000~0x400FFFFF` 外设区每个 bit 映射成 `0x42000000` 起的一个 32 位字——"置 GPIOA 第 3 脚"可以写成对别名地址的一次 `*(__IO uint32_t *)0x42200198 = 1`，免读改写。**RISC-V 特权架构没有位带这回事**，GD32VF103 用户手册的内存映射里也没有别名区——如实结论：F103 代码里的位带操作迁到 GD32 要么用 BOP/BC（GPIO 专用、写 1 生效，事实上覆盖了点灯场景的绝大多数需求），要么关中断做读改写（通用），要么 lr/sc（有 A 扩展时）。位带的本质是"硬件替你做原子 RMW"，它的缺失把原子性责任还给软件——与 9.1 的 A 扩展讨论接上了。

### 3. 启动差异：映像第一字从"数据"变"指令"

F103 上电三步（ch04：取向量表→MSP←word0→PC←word1|1），word0 是数据、word1 是地址。GD32VF103 没有向量表硬件加载序列：**复位后 PC 从闪存区起点开始执行，映像第一字本身是第一条指令**——官方布局把 ECLIC 向量表放在最前，表首放一条 `j _start`（9.4/9.6 已证）。SP 也不是硬件设的：`_start` 里 `la sp, _sp` 一条指令自己装（对照 ch03 的实测"我们没写任何设 SP 的指令，SP 却已就位"——两架构分歧最直观的一处）。另有一个 F1 同源的细节：GD32VF103 的闪存同时出现在 0x08000000（物理基址，链接脚本用）和 0x00000000（别名区，BOOT 重映射后取指用），官方 `_start` 开头有一段"若从别名区执行则跳回物理地址"的规整跳转（`la a0, _start0800; add a0, a0, 0x08000000; jr a0` 一类，见 startup 文件注释"Jump to logical address first"）——与 ch04 讲 F103 BOOT 重映射是同一套哲学的软件版。

---

## 9.6 crt0 与链接脚本差异：ch04 模板的 RISC-V 镜像

[[ch04-baremetal-boot|第四章]] 的 Cortex-M 启动三件套（向量表+Reset_Handler+ld）在 RISC-V 侧逐件有镜像，但接线不同。以下全部对照 nuclei-sdk 官方文件：`SoC/gd32vf103/Common/Source/GCC/startup_gd32vf103.S` 与 `Board/*/Source/GCC/gcc_gd32vf103_flashxip.ld`。

### 1. 链接脚本骨架（官方 ld 摘录）

```ld
OUTPUT_ARCH( "riscv" )
ENTRY( _start )
__ROM_BASE = 0x08000000;               /* 主闪存物理基址，长 128K */
__RAM_BASE = 0x20000000;               /* SRAM，长 32K */
MEMORY { flash (rxa!w) : ORIGIN = __ROM_BASE, LENGTH = __ROM_SIZE
         ram  (wxa!r) : ORIGIN = __RAM_BASE,  LENGTH = __RAM_SIZE }
SECTIONS
{
  .init : {
    *(.text.vtable)                    /* ECLIC 向量表（mtvt 指向这里） */
    KEEP (*(SORT_NONE(.text.init)))    /* _start 所在段——对应 ch04 的 KEEP(.isr_vector) */
  } >ROM
  .text : { *(.text*) *(.srodata*) *(.rodata*) } >ROM
  .data : {
    *(.data .data.*)
    __global_pointer$ = . + 0x800;     /* gp 相对寻址的锚点（ARM 侧没有的概念） */
    *(.sdata .sdata.*)
  } >RAM AT>ROM                        /* 两段式加载，与 ch04 逐字同款 */
  .bss (NOLOAD) : { *(.sbss*) *(.bss*) *(COMMON) } >RAM
  .stack ORIGIN(RAM) + LENGTH(RAM) - __TOT_STACK_SIZE (NOLOAD) :
  { PROVIDE( _sp = . + __TOT_STACK_SIZE); } >RAM
}
```

与 ch04 逐点对照：`>RAM AT>ROM` 的 LMA/VMA 语义、`_sidata = LOADADDR(.data)` 那套知识**原封不动平移**（链接器概念与 ISA 无关）；差异集中在四处——

1. **`.init` 段**：GNU 约定的程序入口段。表（vtable）+ 人（`_start`）一起 KEEP 进最前面，合起来扮演 ch04 的 `.isr_vector`；
2. **`.sdata/.sbss` 小数据段**：±2KB 内的变量用 gp 相对寻址（一条指令省掉 32 位地址常量），`__global_pointer$ = . + 0x800` 把 gp 锚在段中间；
3. **栈是显式 section**：`.stack` 划在 RAM 顶端、`_sp` 是符号，软件用它装 sp——而不是向量表 0 槽；
4. **`rxa!w` 这类属性写法**：RISC-V 内存属性用 r/w/x 字母组合（带 `!` 前缀表排除），语义与 ARM 侧 `(rx)` 等价、语法不同。

### 2. \_start 逐行（官方 startup 摘录并注释）

```asm
_start:
    csrc    CSR_MSTATUS, MSTATUS_MIE   # ①关全局中断（对应 Reset_Handler 隐含的干净状态）
    la      a0, _start                 # ②别名区→物理地址规整跳转（9.5.3）
    ...
    .option push;  .option norelax     # ③gp 必须关"松弛优化"再装：
    la      gp, __global_pointer$      #   否则 la gp 会被优化成"gp 相对寻址 gp"死循环
    .option pop
    la      sp, _sp                    # ④软件装栈——对照 ch04"硬件从 word0 装 MSP"
    la      t0, vector_base
    csrw    CSR_MTVT, t0               # ⑤mtvt = ECLIC 向量表基址
    la      t0, irq_entry
    csrw    CSR_MTVT2, t0
    csrs    CSR_MTVT2, 0x1             # ⑥非向量中断公共入口独立于 mtvec（手册推荐）
    la      t0, exc_entry
    csrw    CSR_MTVEC, t0              # ⑦异常/NMI 入口
    li      t0, 0x3f
    csrc    CSR_MTVEC, t0
    csrs    CSR_MTVEC, 0x3             # ⑧MODE=3：切到 ECLIC 中断模式（9.2）
    /* stage 2/3：使能 mcycle、拷 .text（若 LMA≠VMA）、拷 .data、清 .bss、
       SystemInit、__libc_init_array，最后 call main */
```

三处最值得咀嚼：**③的 norelax** 是 RISC-V 特有坑——gp 自举必须关链接器 relaxation，ARM 侧无此概念；**⑤⑥⑦⑧四条 csrw** 说明"中断向量体系"在 RISC-V 上是**软件拼装的**（mtvec/mtvt/mtvt2 三个 CSR 各管一段），对照 Cortex-M 一张 VTOR 表全搞定；**stage 3 的 `.text` 拷贝**（`_text_lma`→`_text`）是 ch04 没有的选项——RISC-V 上代码段也可以 LMA≠VMA（比如从 flash 搬进 RAM 跑零等待），官方 ld 用 `_ilm/_ilm_lma` 符号族支持它（GD32VF103 默认 flash 零等待，可不搬）。

> [!tip] CH32V 一段话简述
> 同为国产 RV32 的 WCH CH32V 系列把中断控制器做成自家 PFIC（不是 ECLIC），启动布局细节另成一套（Flash 物理基址同为 0x08000000，部分型号代码区另有 0x00000000 别名；烧录用 WCH-Link 而非 DFU）。**具体寄存器/地址以 WCH 手册为准，此处只锚定"又一个厂商扩展宇宙"的结论**——ECLIC 学会的"辨认厂商件"手艺可复用。

---

## 9.7 工具链展望：环境待搭清单

> [!warning] 环境待搭
> 本节为真机章（ch11）预铺的下载途径与命令形态，全部**未在本机验证**，装好后回填实测记录。

| 组件                 | 途径                                                                                        | 备注                                                                                                                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| RISC-V 裸机 gcc      | xPack `riscv-none-elf-gcc`（GitHub xpack-dev-tools，新版）或 `riscv-none-embed-gcc`（旧名） | 编译 GD32VF103 用 `-march=rv32imac -mabi=ilp32 -mcmodel=medany`，注意选带 rv32imac/ilp32 multilib 的发行                                                                                  |
| Nuclei 官方工具链    | nucleisys.com/download.php（与 NucleiSDK 配套的预编译包，`setup` 脚本安装）                 | 对 Bumblebee 扩展指令/CSR 头文件最全（`riscv_encoding.h` 一族）                                                                                                                           |
| OpenOCD（Nuclei 线） | 源码 github.com/riscv-mcu/riscv-openocd；预编译同 nucleisys 下载页                          | 在主线之上加了自定义 CSR/flashloader 等支持（Nuclei 官方文档口径）                                                                                                                        |
| OpenOCD（主线）      | `dnf install openocd`                                                                       | RISC-V 调试模块（riscv-debug-spec）主线已支持；tcl 里已含 `interface/ftdi/sipeed-rv-debugger.cfg`（本次核对了 openocd master 源码树）；WCH-Link 支持主线未见（核对 master 无 wlink 驱动） |
| 探针                 | RV Debugger Plus（FTDI 双通道，openocd ftdi 驱动 + sipeed cfg）                             | ST-Link 不可用于 RISC-V（ADIv5 vs DTM/DMI，ch01 已述）                                                                                                                                    |
| WCH-Link(E)          | MounRiver Studio 或开源 ch32-rs/wlink（Rust 实现）                                          | 调试 CH32V 时用；形态待真机验证                                                                                                                                                           |
| 盲烧（无探针）       | `dfu-util -a 0 -d 28e9:0189 -D firmware.bin` 一类                                           | Longan Nano 出厂 USB DFU（ch01），VID:PID 与选项字节以 dfu-util 枚举实测为准                                                                                                              |
| gdb                  | Fedora 原生 gdb 多目标（ch03 经验）或 `riscv32-unknown-elf-gdb`                             | `set architecture riscv:rv32` 后连 openocd gdbserver                                                                                                                                      |

装好后的第一件事（届时回填）：把 9.3 的 trampoline 和 9.6 的链接脚本拼成最小工程，`-march=rv32imac` 编译、objdump 反汇编人工核对 CSR 指令序列，再上真板验证 ECLIC 向量模式与咬尾行为的口径。

---

## 9.8 小结与下一章

本章以官方手册与 nuclei-sdk 源码为锚，把 RISC-V 侧的地基打完。六维对照总表（兑现 ch01 的预告）：

| 维度       | Cortex-M3（STM32F103/F407 侧）           | RISC-V（GD32VF103/Bumblebee 侧）                                       |
| ---------- | ---------------------------------------- | ---------------------------------------------------------------------- |
| 指令集     | Thumb-2（16/32 位混排），16 寄存器+NZCV  | RV32IMAC：32 寄存器（x0 恒零）、无标志位、C 压缩、A 原子、无 FPU       |
| 控制状态   | 隐形特殊寄存器（MRS/MSR）+SCS 内存映射   | CSR 显式 12 位编号空间（csrrw/csrs/csrc），厂商扩展同场发号            |
| 异常路径   | 硬件取向量+自动压 8 寄存器，`bx lr` 返回 | trampoline 软件保存 16 GPR+mepc/mcause，`mret` 返回；mscratch 复刻双栈 |
| 中断控制器 | NVIC（架构内建标准件）                   | ECLIC（厂商件）：每中断 shv 向量开关+mtvt 函数指针表+jalmnxti 咬尾     |
| 启动       | 向量表 0 槽=SP、1 槽=PC（硬件加载）      | 映像首字=指令（`j _start`），软件装 sp/gp/mtvec/mtvt/mtvt2             |
| 调试/烧录  | SWD/JTAG（ADIv5）+ST-Link                | JTAG 调试模块+Nuclei openocd/RV Debugger；DFU 盲烧兜底                 |

三句压舱的话：**架构把复杂度放在哪，决定你写什么代码**——ARM 放在硬件序列里（你写 0 条保存指令），RISC-V 放在软件入口里（你写 30 条）；**厂商扩展是 RISC-V 的第二战场**——ECLIC/PFIC 各成宇宙，"标准件识别力"是新技能；**外设知识全平移**——RCU/CTL0/BOP 那张改名表就是 F1 学历在 RISC-V 板上的签证。

下一章 [[ch10-i2c-spi-theory|嵌入式硬件基础（十）：I2C/SPI 协议理论]] 回到**架构无关**的领域：芯片之间的总线协议。时序图、地址与 ACK、CPOL/CPHA——这些知识在两块板上长着同一张脸，因为它们住在比 ISA 更低的层：电气与协议层。读完 ch10，你离"从比特到引脚"的全栈就只差调试体系（[[ch11-debug-swd-jtag|第十一章]]）和 RTOS 会师（[[ch12-freertos-port-contrast|第十二章]]，PendSV vs machine timer 的终局对照）了。

---

## 参考

- 芯来《Bumblebee 内核指令架构手册》（nucleisys/Bumblebee_Core_Doc 仓库 PDF）：§1.2 指令子集（RV32IMAC 逐字母）、§2 特权模式（M 必选/U 可选）、§3.4 异常从 mtvec 取 PC、§5.8 中断向量表（mtvt，表项=函数地址）、§5.9 进出中断无硬件保存上下文、§5.13 向量/非向量处理模式与中断咬尾（jalmnxti、约 6 周期向量延迟）、§6.1 TIMER 单元（mtime_lo/hi=0x0/0x4、mtimecmp=0x8/0xC、mstop=0xFF8、msip=0xFFC）、§6.2 ECLIC 单元（表 6-5 寄存器偏移、cliccfg nlbits、clicintattr trig/shv）、§7.4 CSR 详述（mtvec 表 7-3：ADDR[31:6]/MODE[5:0]=000011 ECLIC 模式、mtvt 0x307、mscratch、mepc/mcause）、§7.5 Nuclei 自定义 CSR（jalmnxti 0x7ED 等）
- RISC-V Privileged Architecture（特权级规范）：mstatus（MIE/MPIE/MPP）、mepc/mcause/mtval、mtvec direct/vectored 模式、mret 行为、mscratch 用途
- nuclei-sdk（Nuclei-Software/nuclei-sdk，master）：`SoC/gd32vf103/Common/Source/GCC/startup_gd32vf103.S`（\_start 三阶段、vtable 布局、mtvec MODE=3 写法）、`Board/*/Source/GCC/gcc_gd32vf103_flashxip.ld`（ROM 0x08000000/RAM 0x20000000、`__global_pointer$ = . + 0x800`）、`Common/Include/gd32vf103.h`（`__ECLIC_BASEADDR 0xD2000000`、`__ECLIC_INTNUM 86`、`__SYSTIMER_BASEADDR 0xD1000000`、IRQn 表）、`gd32vf103_gpio.h`/`gd32vf103_usart.h`/`gd32vf103_exti.h`（改名对照表的依据）、`NMSIS/Core/Include/riscv_encoding.h`（CSR 地址）、`NMSIS/Core/Include/core_feature_eclic.h`、`core_feature_timer.h`
- GD32VF103 用户手册（兆易创新）：内存映射（无位带别名区）、外设章节组织镜像 RM0008 的对应关系
- ST RM0008（STM32F103 参考手册）：CRL/CRH、BSRR/BRR、SR/DR/BRR/CR1、IMR/RTSR/PR——GD32 侧对照的基准
- 本系列 [[ch03-arm-cortex-m-anatomy|第三章]]（异常 8 寄存器压栈实测、EXC_RETURN、MSP/PSP）、[[ch04-baremetal-boot|第四章]]（Reset_Handler/链接脚本/两段式加载）、[[ch07-interrupts-nvic|第七章]]（NVIC 寄存器族）、[[ch08-timer-systick|第八章]]（SysTick 与 machine timer 流派）
- 工具链途径：xpack-dev-tools/riscv-none-elf-gcc、riscv-mcu/riscv-openocd、ch32-rs/wlink、nucleisys.com/download.php；openocd master 源码树（`tcl/interface/ftdi/sipeed-rv-debugger.cfg` 存在性已核对）
- FreeRTOS 系列衔接：[[ch16-portmacro-port-contract|portmacro 契约]]、[[ch17-xtensa-port-internals|Xtensa 端口深挖]]（第十二章三架构对照的前置）
