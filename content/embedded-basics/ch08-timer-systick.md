---
title: "嵌入式硬件基础（八）：定时器——从 SysTick 心跳到 PWM 思想"
date: 2026-08-30 09:00:00
description: "用三问框架拆定时器（数什么/数到几/数到了干什么），推导预分频×重装=分辨率×范围的权衡公式与 16 位 ARR 限制；解剖 RM0090 通用定时器寄存器与三种计数模式；QEMU 双实证：SysTick 轮询 vs 中断两种用法、COUNTFLAG 读清与 delay_us 的 CVR 回绕三坑，以及 CMSDK 双定时器与 SysTick 双时基并行心跳；PWM 思想章给出占空比公式、AF 复用接线与呼吸灯算法（真机占位）。"
tags: [embedded-basics, STM32, RISC-V]
---

> [!info] 嵌入式硬件基础系列 0. [[embedded-basics|系列索引]] · 7. [[ch07-interrupts-nvic|上一章：中断体系 NVIC]] · 8. **第八章：定时器** · 9. [[ch09-riscv-gd32-contrast|下一章：RISC-V 侧起点]]

# 嵌入式硬件基础（八）：定时器——从 SysTick 心跳到 PWM 思想

[[ch07-interrupts-nvic|第七章]]解决了"事件如何打断 CPU"，但留了一个尾巴：中断只回答"发生了之后怎么办"，没回答"怎么按时间发生"。裸机世界里的时间感全靠一件东西——**定时器**：UART 有波特率、任务要延时、PWM 要调光、RTOS 要时间片，底层全是同一种电路在数拍子。

本章的路线：先用"三问"框架把任何定时器拆到不可再分，在纸面上推导 F407 的 PSC/ARR 组合公式；然后解剖 RM0090 的通用定时器；再做两个 QEMU 实证——**SysTick 的轮询/中断双模式**（补齐 ch07 只搭了中断版的另一半）与 **CMSDK 双定时器 + SysTick 双时基并行**；最后讲 PWM 思想与呼吸灯算法（真机占位）。工程在 `practice/hwbasics/ch08-timers/`，基于 [[ch04-baremetal-boot|ch04]] 的模板底座，所有输出均为真实运行（`arm-none-eabi-gcc 15.2.0`、`qemu-system-arm 10.1.5`、`-M mps2-an385`）。

---

## 8.1 定时器三问：数什么、数到几、数到了干什么

见到任何新芯片的定时器，问三个问题就能把它拆穿：

| 三问             | 问的是什么       | SysTick 的回答             | STM32 TIM2-7 的回答                   |
| ---------------- | ---------------- | -------------------------- | ------------------------------------- |
| **数什么**       | 时钟源、一拍多久 | 处理器时钟或参考时钟二选一 | APB 倍频后的定时器时钟，再经 PSC 分频 |
| **数到几**       | 计数范围与重装值 | 24 位固定，回绕即重装      | 16/32 位 ARR，可向上/向下/中央对齐    |
| **数到了干什么** | 终点事件是什么   | 置 COUNTFLAG、可选异常     | 更新中断/DMA 请求/PWM 翻转/捕获时间戳 |

**"数到几"是自由度最大的一问，也是本章的公式核心**。以 STM32 通用定时器为例（RM0090 §18）：计数时钟先过预分频器 PSC 再驱动计数器 CNT，CNT 数到 ARR 重装。于是：

```text
更新事件频率 = TIM_CLK / (PSC + 1) / (ARR + 1)

分辨率（一个计数拍的时长） = (PSC + 1) / TIM_CLK
最大周期（范围）          = 分辨率 × (ARR + 1)
```

这就是**分辨率×范围**的权衡：PSC 分得越粗，单拍时间越长，同样的计数器位数能数的总时长越大，但时间精度越差。PSC 和 ARR 各花掉一个自由度，乘积固定——像用两个齿轮配一个传动比。

### 1. 算例：84MHz 定时器时钟下配 1Hz 中断

F407 典型配置：SYSCLK 168MHz、APB1 分频 ÷4 得 42MHz；**APB 分频不为 1 时，挂在上面的定时器时钟 ×2 = 84MHz**（RM0090 §6.2 时钟树，`RCC_CFGR.TIMPRE`）。TIM2-7 都在 APB1 上，所以"84MHz 定时器时钟"是 F407 定时器计算的标准起点。

1Hz 要求 `(PSC+1)(ARR+1) = 84,000,000`。约束：**ARR 与 PSC 都是 16 位寄存器**（TIM3/TIM4 等；TIM2/TIM5 例外，见下），即两者+1 都 ≤ 65,536。把组合列成表：

| PSC+1 | ARR+1      | 16 位约束         | 计数拍分辨率 |
| ----- | ---------- | ----------------- | ------------ |
| 1     | 84,000,000 | ✗ ARR 要 26 位    | 11.9 ns      |
| 1280  | 65,625     | ✗ 差 89，越界     | 15.24 µs     |
| 1344  | 62,500     | ✓ 最小可行分频    | 16 µs        |
| 1680  | 50,000     | ✓                 | 20 µs        |
| 8400  | 10,000     | ✓                 | 100 µs       |
| 84000 | 1,000      | ✓（PSC 也在界内） | 1 ms         |

**16 位 ARR 的限制推导**就藏在第三、四行之间：ARR+1 ≤ 65,536 反推出 PSC+1 ≥ 84,000,000/65,536 = 1281.7，即 PSC+1 至少 1282；而 1,282 不是 84,000,000 的因子（84,000,000 = 2⁸·3·5⁶·7），≥1282 的最小因子是 1,344——所以"最小分频的 1Hz"只能是 1,344×62,500，而不是直觉上的 1,282×65,536。第二行的 1,280 恰好卡在界外一档，是新手最常撞上的"差一点"组合（编译不报错、寄存器写入被截断，频率悄悄错几十倍）。

> [!tip] TIM2/TIM5 是 32 位例外
> RM0090 §18（TIM2-TIM5 通用定时器）明确：TIM2/TIM5 的自动重装与计数器是 **32 位**，TIM3/TIM4 是 16 位。所以上表的限制对 TIM3/TIM4 成立；TIM2/TIM5 可以 PSC=0、ARR=83,999,999 直配 1Hz（分辨率 11.9ns 拉满）。TIM6/TIM7 是 16 位基本定时器，没有 PWM 通道，专职时基/DAC 触发（RM0090 §21）。

### 2. SysTick 的同款推导：24 位为什么逼出"软件分频"

把三问套到 SysTick（ARMv7-M ARM DDI 0403E.e §B3.3）：**数什么**——处理器时钟（F407 上 168MHz）或 HCLK/8 二选一（`CLKSOURCE` 位）；**数到几**——**24 位**重装值，没有 PSC；**数到了干什么**——置 COUNTFLAG + 可选 SysTick 异常。

24 位 = 16,777,216。在 F407 的 168MHz 下单周期最长 99.9ms——**配不出 1Hz**！在 QEMU 的 25MHz 下最长 671ms，同样不够。所以 SysTick 天生只适合做高频率时基（RTOS tick 通常 100Hz~1kHz：1kHz 只需 168,000，富余得很），要 1Hz 这类慢节拍就得在中断里再软件分频（handler 里 count++，数满 N 次动作一次）——本章实验一的 1kHz 时基、实验二的 `g_ms` 毫秒计数，都是这个套路。

---

## 8.2 SysTick 与通用定时器的分工

既然 SysTick 这么全能，为什么 F407 还要再放十几个定时器？因为两者的设计目标不同：

| 维度     | SysTick                    | TIM2-7 通用定时器               |
| -------- | -------------------------- | ------------------------------- |
| 位置     | **核内**（PPB 区，ARM 的） | 芯片外设（ST 的，挂 APB1）      |
| 计数器   | 24 位向下，无预分频        | 16/32 位，向上/向下/中央对齐    |
| 预分频   | 无（只能换时钟源）         | PSC 1~65,536 任意               |
| 输出通道 | 无                         | 4 个通道：PWM/输出比较/输入捕获 |
| 中断     | SysTick 异常（编号 15）    | 各自的 NVIC IRQ，可 DMA         |
| 特殊能力 | 所有 Cortex-M 保证存在     | 编码器接口、Hall 传感、触发联动 |
| 典型用途 | **RTOS tick**、1ms 心跳    | PWM 调光/电机、测脉宽、慢时钟   |

关键差异是**通用性**：SysTick 是 ARM 架构标准件，一份代码所有 Cortex-M 通吃——这正是 FreeRTOS 把它选作默认 tick 源的原因（`vPortSetupTimerInterrupt` 直接写 `SYST_RVR = configSYSTICK_CLOCK_HZ/configTICK_RATE_HZ`，见 [[ch16-portmacro-port-contract|FreeRTOS 系列（十六）：portmacro 与 port 契约]]）。而 PWM 需要硬件比较器在 CNT==CCR 的瞬间翻转引脚——**这件事必须由外设定时器干**，CPU 软件模拟不出"微秒级准时翻转还不占 CPU"。

分工结论（也是本章两个实验的分工）：**SysTick 管节拍（心跳/时基），通用定时器管波形（PWM/捕获）**。

---

## 8.3 F407 通用定时器解剖（RM0090 §18）

把 TIM2-7 的寄存器骨架画出来（偏移以 TIMx 基址计，RM0090 §18.4 寄存器映射）：

| 偏移   | 寄存器    | 关键位                                                                          |
| ------ | --------- | ------------------------------------------------------------------------------- |
| +0x00  | `CR1`     | CEN(bit0) 计数使能；DIR(bit4) 方向；CMS(bit5-6) 中央对齐；ARPE(bit7) ARR 预装载 |
| +0x0C  | `DIER`    | UIE(bit0) 更新中断使能；CCxIE 捕获/比较中断使能                                 |
| +0x10  | `SR`      | UIF(bit0) 更新标志；**写 0 清除**（对照实验二 INTCLR 的写法）                   |
| +0x14  | `EGR`     | UG(bit0) 软件生成更新事件（重装 CNT/PSC 立即生效的钥匙）                        |
| +0x24  | `CNT`     | 当前计数值（只读为主）                                                          |
| +0x28  | `PSC`     | 预分频（计数时钟 = TIM_CLK/(PSC+1)）                                            |
| +0x2C  | `ARR`     | 自动重装值（周期天花板）                                                        |
| +0x34+ | `CCR1..4` | 捕获/比较值（PWM 的占空比旋钮，8.6 节主角）                                     |

三种计数模式（RM0090 §18.3.1）的时间线：

```text
向上（DIR=0）     0 ─→ ARR ┐重装┌─→ ARR ┐
                          └────┘      └────    更新事件：CNT==ARR 的下一拍

向下（DIR=1）   ARR ─→ 0 ┐重装┌─→ 0 ┐
                        └────┘     └────        更新事件：CNT==0 的下一拍

中央对齐（CMS≠00）0 ⇅ ARR（先上后下三角波）
                  /\    /\    /\
                 /  \  /  \  /  \               更新事件：波峰与波谷各一次
                /    \/    \/    \               → PWM 频率翻倍/无相位突跳
```

中央对齐是 PWM 的进阶姿势：三角波让"比较翻转点"对称分布在周期两侧，电机驱动（互补 PWM 死区）必用它——本章只需知道它是"先上后下、波峰波谷都发更新事件"的混合模式。

> [!warning] QEMU 边界：F407 定时器 QEMU 不仿真
> `mps2-an385` 机型只有 ARM CMSDK 系列定时器模型（见 8.5 节），STM32 的 TIM2-7 外设 QEMU 不仿真。本章对 TIM2-7 的部分是"寄存器级讲解 + 真机占位"（8.6 节），实证环节用 CMSDK 双定时器当"外设定时器替身"——它在 QEMU 里真实可跑，且寄存器风格（LOAD/VALUE/CONTROL/INTCLR）恰好是另一流派的教科书样本，对照着学反而更清楚。

---

## 8.4 QEMU 实证一：SysTick 深入版——轮询、读清与 delay_us 的三个坑

ch07 已经搭过 SysTick 的中断版（TICKINT=1 → `SysTick_Handler`）。这一节补上另一半：**轮询模式**——TICKINT=0，完全不过 NVIC，靠读 `CSR.COUNTFLAG`（bit16）感知"数到 0 了"。寄存器速查（ARMv7-M ARM §B3.3，PPB 区）：

| 地址       | 寄存器  | 要点                                                          |
| ---------- | ------- | ------------------------------------------------------------- |
| 0xE000E010 | `CSR`   | ENABLE(0)/TICKINT(1)/CLKSOURCE(2)/**COUNTFLAG(16，读即清零)** |
| 0xE000E014 | `RVR`   | 24 位重装值，周期 = RVR+1 拍                                  |
| 0xE000E018 | `CVR`   | 当前计数值，**向下**计数；写任意值清零并清 COUNTFLAG          |
| 0xE000E01C | `CALIB` | TENMS 校准值（QEMU 实现见下文输出）                           |

### 1. 轮询打拍与 COUNTFLAG 的"读即清零"

```c
SYST_CSR = 0;                 /* 停表再配置，习惯 */
SYST_RVR = CPU_HZ / 1000 - 1; /* 25MHz: 24999 -> 周期 25000 拍 = 1ms */
SYST_CVR = 0;                 /* 清计数、清标志 */
SYST_CSR = ENABLE | CLKSOURCE;/* 0x5：注意没有 TICKINT —— NVIC 完全不知情 */

static void systick_delay_poll_1ms(void)
{
    while (!(SYST_CSR & (1UL << 16)))   /* COUNTFLAG 轮询 */
        ;
}
```

真实输出（`practice/hwbasics/ch08-timers/`，实验一上半场）：

```text
== ch08 exp1: SysTick polling (TICKINT=0) ==
CSR   = 0x00000005 (ENABLE|CLKSOURCE, TICKINT=0)
CALIB = 0x0000270f (TENMS=9999: 10ms @ 1MHz refclk, no SKEW/NOREF)
poll 5 x 200ms by COUNTFLAG:
  t=200ms t=400ms t=600ms t=800ms t=1000ms
  flags read = 1000 (expect 1000)
COUNTFLAG read-clear: first=0x00010000, immediate re-read=0x00000000
```

三个可验尸的细节：

- `flags read = 1000`：5×200ms 共读到 1000 个标志，与 1kHz 配置互证——**标志不会堆积**，因为它电平保持到被读；
- `first=0x00010000, re-read=0x00000000`：读到标志的那次读**顺手清零**，紧接再读为 0。这解释了一个经典坑：如果别的代码（或调试器）在你轮询之前读过 CSR，标志会被"偷走"——所以 COUNTFLAG 只能有一个消费者；
- `CALIB = 0x270f` 即 TENMS=9999：QEMU 按"refclk 10ms 的拍数−1"实打实算出（`hw/timer/armv7m_systick.c`），真机 F407 此处是厂家烧的校准值，供 CLKSOURCE=0 时换算。

### 2. delay_us 与读 CVR 的三个坑

轮询 COUNTFLAG 的粒度是整个重装周期（1ms）。要微秒级延迟得读 `CVR` 本尊——向下计数、回绕点在 `0 → RELOAD`。**坑一（回绕）**：朴素写法在回绕瞬间差值爆成巨大的无符号数：

```c
/* BUG：CVR 从 0 跳回 24999 的瞬间，start - SYST_CVR ≈ 4.29e9 */
while ((start - SYST_CVR) < ticks)
    ;
```

正确姿势是按"同周期/跨周期"分别算：

```c
static uint32_t systick_elapsed(uint32_t start)
{
    uint32_t cvr = SYST_CVR;
    if (start >= cvr)
        return start - cvr;                     /* 同一周期内        */
    return start + (SYST_RELOAD + 1UL) - cvr;   /* 刚跨过 0->RELOAD  */
}
```

**坑二（窄窗）**：等待条件 `elapsed >= chunk` 的"可退出窗口"只有 `(周期 - chunk)` 拍宽。chunk 逼近整周期时窗口窄到一拍，轮询粒度粗一点就整窗跳过，循环白等一个整周期。对策：单段等待压到**不超过半周期**（代码里 `SYST_CHUNK_MAX = 12500`，反汇编能看到 `movw r4, #12500`）。

**坑三（同值二义）**：回绕后"start 与 cvr 差 1 拍"和"差 1 个周期零 1 拍"在减法上无法区分——只读 CVR 的测量是歧义的。要请 COUNTFLAG 作证：它是电平保持的，恰好漏不掉一次回绕：

```c
static uint32_t systick_measure(uint32_t start)
{
    uint32_t flag = SYST_CSR & SYST_CSR_COUNTFLG; /* 先读（读即清，防丢）*/
    uint32_t cvr = SYST_CVR;
    if (flag)
        return start + (SYST_RELOAD + 1UL) - cvr; /* 跨过一个回绕       */
    return start - cvr;
}
```

真实输出（实验一下半场）：

```text
delay_us(1)   =   434 ticks (ideal 25)
delay_us(100) =  2610 ticks (ideal 2500)
delay_us(999) = 25104 ticks (ideal 24975)
1000 x delay_us(1000): flags=1000 (expect ~1000)
```

- 100µs 与 999µs 的实测比理想值多 110~129 拍（4~5µs）——函数调用 + 轮询退出粒度，符合预期；
- `delay_us(1)` 多出的 ~400 拍是 **QEMU TCG 的边界**：模拟器里一次 MMIO 轮询比真机贵一个数量级；真机 84MHz 直排循环约 20~30 拍。顺带一提，第一次执行 delay 路径还有一次性开销（实测 ~1600 拍：QEMU 是 TCG 首译码，真机对应 flash 预取/cache miss，量级小得多）——所以工程里测量前先空跑热身一次；
- `flags=1000`：1000 次 delay_us(1000)（共 1s 忙等）与 1kHz 时基严丝合缝；
- 窄窗对策直接写进了机器码——反汇编里 chunk 上限是个立即数：

```text
000001e2 <delay_us>:
 1e2:  b570       push {r4, r5, r6, lr}
 1e4:  eb00 0680  add.w r6, r0, r0, lsl #2     ← us*5
 1e8:  eb06 0686  add.w r6, r6, r6, lsl #2     ← 再*5 = us*25（M3 无乘法器，
                                                  编译器用移位加合成）
 1ee:  f243 04d4  movw r4, #12500              ← SYST_CHUNK_MAX：单段等待
                                                  不超过半周期
 1f2:  42b4       cmp  r4, r6
 1f4:  bf28       it   cs
 1f6:  4634       movcs r4, r6                 ← chunk = min(12500, 余量)
 1f8:  f04f 23e0  mov.w r3, #0xe000e000
 1fc:  699d       ldr  r5, [r3, #24]           ← 读 SYST_CVR (0xE000E018)
```

### 3. 轮询 vs 中断：怎么选

| 维度     | 轮询 COUNTFLAG/读 CVR                                    | 中断 TICKINT=1                |
| -------- | -------------------------------------------------------- | ----------------------------- |
| CPU 占用 | 100% 忙等（wfi 都进不去）                                | 空闲可 wfi 睡眠               |
| 粒度     | 读 CVR 可到亚拍（真机）                                  | 一个周期一次，handler 开销在  |
| 响应位置 | 主循环指定点                                             | 随时打断（与主流程异步）      |
| 典型场景 | `delay_us` 初始化时序（外设芯片 datasheet 里的 tSU/tHD） | 系统心跳、超时计数、RTOS tick |

规则一句话：**关键路径里的短暂精确定时用轮询，系统级节拍用中断**。真机外设驱动两个都用：I2C 波形间隔（µs 级）轮询读 CVR，超时重试（ms 级）靠中断维护的计数器。

---

## 8.5 QEMU 实证二：CMSDK 双定时器与 SysTick 双时基并行

第二个实验回答分工问题：**两个时基同时跑会怎样？** 用的"外设定时器替身"是 mps2-an385 板上真实存在的 CMSDK 双定时器。地址与 IRQ 不许靠记忆，从 QEMU v10.1.5 源码考证（`hw/arm/mps2.c`）：

| 资源                         | 地址/时钟                       | IRQ | 出处                                      |
| ---------------------------- | ------------------------------- | --- | ----------------------------------------- |
| CMSDK APB Timer0             | 0x40000000                      | 8   | `base = 0x40000000 + i*0x1000; irq = 8+i` |
| CMSDK APB Timer1             | 0x40001000                      | 9   | 同上                                      |
| CMSDK APB DualTimer（SST-2） | 0x40002000，TIMCLK=SYSCLK=25MHz | 10  | 固定映射，合并中断线接 NVIC IRQ10         |
| SysTick（核内）              | 0xE000E010..，cpuclk=25MHz      | -15 | armv7m 的 cpuclk 接 SYSCLK                |
| SysTick 参考时钟             | refclk = 1MHz                   | —   | `REFCLK_FRQ`（CALIB 的换算依据）          |

DualTimer 是 SP804 血统的双通道向下计数器（`hw/timer/cmsdk-apb-dualtimer.c`，Timer1 寄存器偏移 0x00、Timer2 加 0x20）：`LOAD +0x00` 重装值、`VALUE +0x04` 当前值、`CONTROL +0x08`、`INTCLR +0x0C`、`RIS +0x10` 裸状态、`MIS +0x14` 掩码后状态。CONTROL 位定义：ONESHOT(0)、SIZE(1)=32 位、PRESCALE(2..3)=÷1/16/256、INTEN(5)、MODE(6)=周期、ENABLE(7)。与 STM32 TIM 对照着看，两个流派一目了然：

| 维度     | CMSDK DualTimer      | STM32 TIM2-7               |
| -------- | -------------------- | -------------------------- |
| 计数方向 | 只向下               | 向上/向下/中央对齐         |
| 分频     | 只有 ÷1/16/256 三档  | PSC 任意 1..65536          |
| 重装     | LOAD 直接是周期      | ARR，另有预装载/影子寄存器 |
| 清中断   | **写 INTCLR 任意值** | **写 0 到 SR.UIF**         |
| 波形能力 | 无                   | CCR×4 → PWM/输入捕获       |

配置代码（完整版在工程 `main.c`）：

```c
/* 时基 A：SysTick 切中断模式，1kHz 维护 g_ms（RTOS tick 姿势） */
SYST_CSR = 0; SYST_RVR = SYST_RELOAD; SYST_CVR = 0; g_ms = 0;

/* 时基 B：CMSDK DualTimer Timer1，1Hz */
NVIC_ISER0 = (1UL << 10);   /* 开 IRQ10（对照 ch07 的 NVIC 使能）   */
DT1_LOAD   = 25000000;      /* TIMCLK 25MHz -> 1s                    */
DT1_CTRL   = 0xE2;          /* ENABLE|PERIODIC|SIZE32|INTEN          */

SYST_CSR = ENABLE | TICKINT | CLKSOURCE;  /* 0x7：现在心跳走中断了 */

/* 主循环：wfi 睡到中断醒，每 250ms 打印 dualtimer 倒计数值 */
```

`CMSDK_DUALTIMER_IRQHandler` 里先读 `VALUE`（给本次中断盖"双时基时间戳"），打印后写 `INTCLR` 清标志——**不写中断电平不撤**，会立刻重入（RISC-V 侧没有这个硬件电平，ch09 对照）。

两个处理函数都真的挂在向量表上（`arm-none-eabi-objdump -d`）：

```text
00000000 <_vectors>:
   ...
  3c:  0000022d  .word 0x0000022d   ← 槽15 SysTick -> 0x22c|Thumb bit
  ...
  68:  00000529  .word 0x00000529   ← 槽26 = 16+IRQ10 -> dualtimer 处理函数
  ...

0000022c <SysTick_Handler>:          ← 1kHz tick 的全部成本：
 22c:  4a02       ldr  r2, [pc, #8] ← &g_ms（literal pool 取地址）
 22e:  6813       ldr  r3, [r2]
 230:  3301       adds r3, #1       ← g_ms++
 232:  6013       str  r3, [r2]
 234:  4770       bx   lr           ← 5 条指令 + 硬件自动出入栈 12 周期
```

槽号的算法是 ch07 的知识：向量表前 16 槽是系统异常，IRQn 落在 16+n——dualtimer 的 IRQ10 就在偏移 0x40+0x28=0x68，末位的 1 是 Thumb bit。`SysTick_Handler` 只有 5 条指令，是"时基中断必须短"的第一课：它每 1ms 都要抢一次 CPU，做多了系统就被心跳吃掉。

真实输出（节选，完整见工程 README）：

```text
== ch08 exp2: dual timebase ==
[systick ms=250] dt.VALUE=18742311
[systick ms=500] dt.VALUE=12492648
[systick ms=750] dt.VALUE=6243246
[dt irq 1 @ ms=999] VALUE=24995960 RIS=1 MIS=1 -> after-clear MIS=0
[systick ms=1000] dt.VALUE=24989755
[systick ms=1250] dt.VALUE=18743418
[systick ms=1500] dt.VALUE=12493145
[systick ms=1750] dt.VALUE=6241898
[dt irq 2 @ ms=1999] VALUE=24995641
[systick ms=2000] dt.VALUE=24992035
[systick ms=2500] dt.VALUE=12494221
[dt irq 3 @ ms=2999] VALUE=24999373
[systick ms=3750] dt.VALUE=6238106
[dt irq 4 @ ms=3998] VALUE=24998974
[systick ms=4750] dt.VALUE=6217509
[dt irq 5 @ ms=4998] VALUE=24999148
summary: 5 dt irqs, ms(first)=999 ms(last)=4998 -> period=999ms (expect 1000)
[dt irq 6 @ ms=5999] VALUE=24986444
[dt irq 7 @ ms=6998] VALUE=24999192
```

两路心跳交错，逐行验尸能读出四层信息：

1. **两个时基都活着**：250ms 粒度的 `[systick]` 行与 1s 粒度的 `[dt irq]` 行互不干扰，NVIC 同时服务异常 15（SysTick）与 IRQ10；
2. **频率严格同源**：连续 dt 中断的时间戳差为 999/1000/1000/1000/1001/999…平均恰 1000ms——两个定时器最终接同一个 25MHz SYSCLK，**只有相位差、没有频率漂移**；
3. **相位差有出处**：dt 首中断在 ms=999 而非 1000，因为代码先启动 dualtimer、打了三行 banner（~1ms）才启动 SysTick——起跑线错开的 1ms 之后永远保持。真实多时基系统里，"对表"（同时启动/软件校准相位）是正经课题；
4. **倒计数值可反推验证**：ms=250 时 VALUE=18,742,311 ≈ 25e6×(1−0.2512)——把相位差算进去正好对上。另外 dt 中断里 VALUE 已是 2499 万（刚重装），说明从中断发生到 handler 执行隔了几百 µs：这是 **QEMU 主循环粒度的中断延迟**，真机上是异常入口 12 周期+流水线冲刷，亚微秒级。

> [!warning] QEMU 边界
> 上表的 VALUE 读取精度与中断延迟受 QEMU 虚拟时钟/主循环调度影响（百 µs 级）；真机上这些数值会小两个数量级。结论性数据（频率同源、相位恒定）不受影响。

---

## 8.6 PWM 思想：CCR 比较匹配（真机占位）

定时器三问的第三问"数到了干什么"，PWM 是最漂亮的答案：**让计数器在数的过程中，再和一个比较值 CCR 比一比，比较结果直接驱动引脚**——CPU 从此对波形零参与。

```text
CNT（向上）  ARR ┤     ╭──╮          ╭──╮
                   │   ╱    ╲        ╱    ╲        ← 数到 ARR 重装（更新事件）
                CCR┤──╪──────╪──────╪──────╪──     ← CNT==CCR 翻转点
                   │ ╱        ╲    ╱        ╲
                 0 ┤╯          ╰──╯          ╰─
                   └──────────────────────────────→ t
PWM 输出      ┌─────┐          ┌─────┐
（PWM模式1）  │ 高  │    低    │ 高  │   低        CNT < CCR 时输出有效
              └─────┘          └─────┘
              |<-CCR->|<-ARR-CCR->|               周期 = ARR+1 个计数拍
```

RM0090 §18.3.9（PWM 模式，OCxM=110）：向上计数且 PWM 模式 1 时，`CNT < CCR` 期间通道有效。两个公式：

```text
PWM 频率 = TIM_CLK / (PSC + 1) / (ARR + 1)
占空比   = CCR / (ARR + 1)          （CCR: 0..ARR，duty: 0..ARR/(ARR+1)）
```

算例（84MHz 定时器时钟）：要 1kHz、分辨率尽量细，取 PSC+1=10、ARR+1=8400 → 频率 84e6/10/8400 = 1kHz，占空比步进 1/8400 ≈ 0.012%。同 8.1 的权衡：PWM 频率每升一档，分辨率就少一档位数。

### 1. 真机接线与预期现象

> [!warning] 真机待验证（板到后回填实测）
> 以下接线与现象依据 RM0090 §18.3.9（PWM 模式行为）、STM32F407 datasheet（GPIO 驱动能力 ±25mA，LED 限流建议 ≤8mA）与人眼闪烁融合特性推断，暂无实物验证。

接线（F407VET6）：

```text
TIM3_CH1（PA6，AF2）──[470Ω]──[LED 正向]──GND
                        限流电流 ≈ (3.3-2.0)V / 470Ω ≈ 2.8mA（安全）
若用板载 LED：查各自板卡原理图把通道换到对应引脚（如 TIM4_CH1=PB6 同为 AF2）
```

PA6 复用到 TIM3 的依据是 RM0090 的 AF 映射表（§8.4，AF2 列）：写 `GPIOA->AFR[0]` 的 AFRL6=2，再配 MODER=AF 方向——正是 [[ch05-gpio-and-mco|第五章]] AFR 的实战回收。寄存器序列（TIM3 基址 0x40000400，RM0090 §18.4）：

```c
TIM3->PSC  = 9;              /* 84MHz/10 = 8.4MHz 计数拍            */
TIM3->ARR  = 8399;           /* 周期 8400 拍 = 1ms -> 1kHz          */
TIM3->CCR1 = 4200;           /* 初始 50% 占空比                     */
TIM3->CCMR1 = OC1M_PWM1 | OC1PE; /* PWM 模式 1 + 预装载              */
TIM3->CCER = CC1E;           /* 通道 1 输出使能                     */
TIM3->EGR  = UG;             /* 软件更新事件：让 PSC/ARR 立即生效   */
TIM3->CR1  = CEN | ARPE;     /* 开表                                */
```

### 2. 呼吸灯：PWM 思想的最小应用

**算法**：SysTick 1kHz 时基（本章实验代码原样复用），每 10ms 更新一次 CCR：`CCR += step`（亮→灭时 `step=-84`，灭→亮时 `step=+84`，CCR 在 0..8400 往返）。占空比每步变化 1%，单程 100 步 = 1s，呼吸全周期 2s。

**预期现象**（推断依据）：PWM 载波 1kHz 远高于人眼闪烁融合阈值（一般引用 50~90Hz，亮度越高阈值越高），视觉暂留把 1000 次/秒的亮暗积分成平均亮度——看到的不是闪烁而是 CCR 曲线决定的平滑渐亮渐灭。验证手段：[[ch02-tools-multimeter-la|第二章]] 的 PulseView 抓 PA6，应看到 1kHz 方波且占空比随呼吸相位滑动；万用表直流档读出的是平均值 3.3V×duty（方波均值等效，普通档位精度有限，作辅助证据）。

PWM 思想的扩展方向（本系列后续用到再展开）：CCR 不止能输出——输入捕获模式让 CNT 在**外部信号边沿**锁存进 CCR，这就是测脉宽/超声波测距/红外解码的硬件底座；编码器接口模式则直接把正交编码器的两相边沿变成 CNT 增减。

---

## 8.7 时间片与调度：定时器是 RTOS 的心脏

回头看本章两个 QEMU 实验的分工，恰好预演了 RTOS 的两根时间轴：

- **SysTick 1kHz 中断**就是 RTOS 的 tick：[[ch8-priority-timeslice-rr|FreeRTOS 系列（八）：优先级与时间片轮转]]里 `xTaskIncrementTick()` 在 tick 中做的一切——同优先级任务的轮转计数、阻塞任务的超时唤醒——物理起点都是实验二那个 `SysTick_Handler` 里的 `g_ms++`，只是换了计数对象；
- **外设定时器**负责硬实时波形（PWM 电机、输入捕获测距），RTOS 决不该用任务翻转 GPIO 模拟它——正是 8.2 分工结论的系统级版本。

tick 到了之后发生什么？`xPortSysTickHandler` → 需要切换上下文时 PendSV 置起 → [[ch07-interrupts-nvic|ch07 的 NVIC 知识]]接管异常分发 → [[ch7-context-switch-deep-dive|FreeRTOS 系列（七）：上下文切换]]拆的那套入栈/换栈/出栈。软件定时器则是把"定时"继续上翻一层（[[ch15-software-timers-daemon|系列（十五）：软件定时器守护任务]]）。你现在已经握着这条链的最底端：**一个每秒数 25,000,000 拍的电路**。

---

## 8.8 小结与预告

本章把"时间"拆成了三问：数什么（时钟源）、数到几（PSC×ARR 的分辨率×范围权衡，16 位 ARR 下 1Hz 的组合表与 1282/1344 的因子推导）、数到了干什么（标志/中断/PWM 比较输出）。SysTick 深入版补齐了轮询用法：COUNTFLAG 读即清零、delay_us 的回绕/窄窗/同值二义三个坑及对策（单段不超半周期、请 COUNTFLAG 消歧）；双时基实证验证了 SysTick 异常 15 与 CMSDK DualTimer IRQ10 并行、同源时钟只差相位不差频率；PWM 思想章给出占空比公式、AF2 接线与呼吸灯算法（真机占位待验）。工程资产：`practice/hwbasics/ch08-timers/`。

下一章换阵营：[[ch09-riscv-gd32-contrast|嵌入式硬件基础（九）：RISC-V 侧起点——GD32 与架构对照]]。GD32VF103 是 STM32F103 的寄存器级近亲，但心脏换血：向量表变 `mtvec`、NVIC 变 ECLIC、SysTick 变 machine timer（`mtime`/`mtimecmp`，64 位向上计数+比较，与本章"向下数+重装"正好是另一流派）——定时器三问在 RISC-V 上的三个回答，就是下一章的开局。
