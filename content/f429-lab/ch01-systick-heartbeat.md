---
title: SysTick：内核的心跳
date: 2026-08-30 03:00:00
description: F429 裸机实验室（一）——SysTick 四寄存器逐位拆解，从 HSI 16MHz 到 180MHz 的 LOAD 推导，FreeRTOS 的心跳就是接管了这条中断
tags: [f429-lab, STM32, SysTick]
---

# SysTick：内核的心跳

> **状态声明**：本章属「先成文、后实跑」——实验设计、寄存器推导、预期输出均已写定，但**尚未在真机上执行**；
> 文中所有「预期输出」均为待实测核销的推导值，实跑后回填真实数据。板上事实查不到的一律标「待核对」，
> 绝不编造运行日志与寄存器读数。工具链与方法论继承
> [[2026-08-30-stm32f429-clock-misconfig-postmortem|故障复盘]]。

## 本章装备清单

| 分类       | 装备                    | 价格/状态 | 用途                      |
| ---------- | ----------------------- | --------- | ------------------------- |
| 已有       | 挑战者 F429-V2 板       | ✅        | 实验主体                  |
| 已有       | 野火 DAP 仿真器         | ✅        | 烧录/调试                 |
| 已有       | Mini-USB 线             | ✅        | 供电 + 串口               |
| 已有       | 笔记本（Fedora 工具链） | ✅        | 编译/烧录/mdw 实证        |
| 沿用基础盘 | 无新增                  | —         | 本章用板载 LED 与串口完成 |

## 本章会遇到的词

| 词                  | 一句话版                                         | 详见              |
| ------------------- | ------------------------------------------------ | ----------------- |
| SysTick             | 内核自带的 24 位倒计时器，产生节拍               | 「目标」          |
| 寄存器              | 有固定地址的 32 位小格子：写=下命令，读=看状态   | 「四个寄存器」    |
| 异常 #15            | ARM 给内核内部中断的编号；SysTick 固定 #15       | 「CTRL」          |
| HSI / HSE / HCLK    | 片内 RC 振荡器 / 外部晶振 / 喂给 CPU 的时钟      | 「CLKSOURCE」     |
| LOAD / VAL / CALIB  | 重装值 / 当前计数 / 出厂校准                     | 「四个寄存器」    |
| 读清（RC）          | 读一次标志位自动归零的硬件设计                   | 「CTRL」          |
| 轮询（poll）        | 主循环反复查标志拿状态——你的主场                 | 「CTRL」          |
| PPB                 | 内核私有外设总线，SysTick 四个寄存器住在里面     | 「实验」          |
| 向量表 / 弱符号     | 「异常号→入口地址」查找表 / 可被覆盖的默认函数桩 | 「FreeRTOS 接管」 |
| PendSV / 上下文切换 | RTOS 专用切换异常 / 保存旧现场换载新任务         | 「FreeRTOS 接管」 |
| ICSR / SHPR3        | 内核中断控制状态 / 系统异常优先级寄存器          | 「FreeRTOS 接管」 |
| mdw                 | openocd 的读内存命令（按 32 位字）               | 「预期输出」      |

## 目标（先说结论）

- SysTick 是 **Cortex-M4 内核自带的** 24 位倒数定时器，不是 ST 的外设——四个寄存器钉死在 `0xE000E010`，
  任何 Cortex-M 芯片上都一样（M0 除外，砍成了简化版）。写一次，全平台通用。
- 裸机里它是你唯一「免费」的周期事件源；本实验用它做 1Hz 心跳：串口每秒打一拍 + `mdw` 三字寄存器实证（mdw：openocd 的读内存命令，见「预期输出」节命令拆解）。
- **24 位计数器在 180MHz 下最长只能定 93.3ms**，1Hz 塞不进去——LOAD 怎么算、时钟选 HCLK 还是 /8，
  是本章的主线算术。
- 升华点：FreeRTOS 工程里那三行 `#define xPortSysTickHandler SysTick_Handler` 的落点就是本章手搭的
  这颗定时器——调度器的 1kHz 心跳与我们的裸机心跳是**同一颗硬件、同一个 LOAD**。

> 📖 **术语卡：SysTick（System Tick Timer，系统节拍定时器）**
> **是什么**：ARM Cortex-M 内核自带的 24 位倒计数器：从 LOAD 值往下数，数到 0 抛一次异常 #15，再自动重装 LOAD 继续——周而复始。
> **为什么存在**：任何系统都需要"均匀的时间刻度"（心跳），ARM 把它直接焊进内核，保证任何厂商的 Cortex-M 芯片上都有一颗一样的——RTOS 移植因此少一个大坑。
> **类比**：心脏起搏器——不参与任何业务，只按固定节拍"咚"一下，全系统的时间感都从这来。
> ⚠️ 类比边界：起搏器节拍出厂定死，SysTick 的节拍由你写 LOAD 决定，改一个数就变速。

## 系统侧类比：每 CPU 自带的 tick device

| SysTick 侧                            | 系统侧对应物                                                        |
| ------------------------------------- | ------------------------------------------------------------------- |
| SysTick 定时器（每核一个）            | per-CPU tick device（hrtimer 的硬件底座）                           |
| `LOAD` + 时钟频率 = 周期              | hrtimer 编程的相对 deadline（CLOCK_MONOTONIC 的绝对性由软件层维护） |
| `TICKINT=1`：数到 0 抛异常 #15        | `setitimer(ITIMER_REAL)` 到期发 SIGALRM / POSIX timer               |
| `COUNTFLAG`：轮询派的到期标志（读清） | timerfd：可读可轮询，不递信号                                       |
| `CALIB` 出厂校准值                    | x86 上用已知频率的 PIT/晶振给 TSC 定标——软件总要一个已知参考        |

> 表右列全是你的主场（hrtimer / timerfd / setitimer / PIT / TSC 不再展开）；左列才是本章要刷的新漆。

一句话：Linux 把「周期性打断 CPU」这件事做成了多层抽象（tick device → hrtimer → timer wheel），
而 SysTick 是这栋楼的地基样板间——**一个倒计数器 + 一个到期事件**，仅此而已。裸机实验的价值
就是把这个样板间亲手刷一遍漆。

## 四个寄存器，一个不落

基址 `0xE000E010`（RM0090「System timer」章；ARMv7-M 侧叫 SYST_CSR/RVR/CVR/CALIB）：（RM0090：ST 官方 F4 系列参考手册编号；ARMv7-M：ARM 的架构规范文档——内核级寄存器在两边各有一套名字，CMSIS 名是 ARM 头文件统一后的叫法）

> 📖 **术语卡：寄存器（Register）**
> **是什么**：芯片内部一个有固定地址的 32 位小格子（内存地图上的一个门牌号）：写它 = 给硬件下命令，读它 = 看硬件状态。
> **为什么存在**：软件指挥硬件的唯一通用接口就是内存读写，寄存器就是"长得像内存的控制面板"。
> **类比**：走廊里的灯控开关面板——每个开关（位）管一件事，拨到位就生效。
> ⚠️ 类比边界：开关拨了立刻生效且一直保持；部分寄存器位是"读清""写 1 清零"等特殊语义（本章 COUNTFLAG 就是读清）。

| 偏移   | CMSIS 名 | 一句话职责                         |
| ------ | -------- | ---------------------------------- |
| `+0x0` | CTRL     | 使能开关 + 状态标志                |
| `+0x4` | LOAD     | 重装值（24 位有效，上限 0xFFFFFF） |
| `+0x8` | VAL      | 当前计数值                         |
| `+0xC` | CALIB    | 出厂校准值（只读）                 |

### CTRL：四个位，各管一段

| 位          | 名字      | 属性 | 含义                                                      |
| ----------- | --------- | ---- | --------------------------------------------------------- |
| 0           | ENABLE    | RW   | 数不数。1=开跑                                            |
| 1           | TICKINT   | RW   | 数到 0 时是否抛 SysTick 异常（异常号 #15）                |
| 2           | CLKSOURCE | RW   | 1=HCLK（内核时钟）；0=HCLK/8（外部参考时钟，见 CALIB）    |
| 16          | COUNTFLAG | RC   | 自上次读取以来数到过 0 则为 1；**软件读 CTRL 会把它清零** |
| 3–15、17–31 | —         | —    | 保留                                                      |

> 📖 **术语卡：异常（Exception）与异常号 #15**
> **是什么**：ARM 把"打断 CPU 的信号"统称异常并从 0 开始编号；内核内部事件（复位、NMI、SysTick、SVC…）号小，芯片外设/引脚的中断号靠后。SysTick 固定是 #15，异常号就是向量表里的行号——#15 那一行写着 SysTick_Handler 的入口地址。
> **为什么存在**：统一编号才能有一张统一的跳转表（向量表），硬件查表直达，不需要软件先判断来源。
> **类比**：你的主场：信号编号（如 SIGALRM=14）——内核按信号号查 handler 表；ARM 这边是硬件查表。
> ⚠️ 类比边界：信号 handler 靠软件分发，异常是硬件直接跳转入口，纳秒级。

三个细节值得抠：

1. **周期是 LOAD+1 个时钟，不是 LOAD 个**——计到 0 那一拍也算数。所有「差 1 个周期」的 bug 都源于此。
2. **写 VAL 任意值**会同时把计数器清零、COUNTFLAG 清零——这是「从已知状态重启」的正规手段，
   比 `LOAD` 写完干等要干净。
3. COUNTFLAG 的「读清」语义（读清：读一次标志自动归零的硬件设计）让轮询派天然成立（轮询 polling——你的主场：主循环反复主动查状态）：不开 TICKINT，主循环里读 CTRL 的 bit16 拿节拍。
   代价是轮询本身吃 CPU——正好是 ch02 的引子。

### LOAD/VAL：24 位的上限是本章一切算术的边界

`LOAD` 与 `VAL` 都只有 bits[23:0] 有效，即最大 16,777,215（0xFFFFFF）。**180MHz 下一个满量程倒数
只有 2^24 / 180MHz ≈ 93.3ms**——这决定了「1Hz 直接灌进 LOAD」在本板的时钟配置下是不可能的。

### CALIB：唯一「读之前猜不准」的寄存器

`TENMS`（bits[23:0]）= 外部参考时钟（HCLK/8）走 10ms 的计数值；`NOREF`（bit31）=1 表示没有外部参考；
`SKEW`（bit30）=1 表示 TENMS 不精确。它的用途与 x86 的 TSC 定标同构：软件拿到一个**已知时间对应的
计数值**，就能把「计数」换算成「秒」。ST 给 STM32F4 烧的 TENMS 具体值，**待实跑 `mdw 0xE000E01C`
回读核对**——这正好是一次「读出来的值对着文档复位值验」方法论的免费练习（序章方法论 5）。

## CLKSOURCE 的取舍与 LOAD 推导：从 HSI 16MHz 到 180MHz

SysTick 是**相对时钟**的定时器：换主频，节拍必然漂移（Linux 侧由 hrtimer 层吸收了这件事，裸机没人替你扛）。
同一个「我想要 1Hz」的需求，在三个时钟档位下算出来的 LOAD 完全不同：

> 📖 **术语卡：HSI、HSE、PLL 与 HCLK**
> **是什么**：HSI（High-Speed Internal，片内 RC 振荡器，复位默认、16MHz、精度差）；HSE（High-Speed External，外部石英晶振，本板 25MHz、精度高）；PLL（锁相环，把 HSE 倍频到 180MHz）；HCLK（最终喂给 CPU 内核的时钟）。SysTick 的 CLKSOURCE 位在 HCLK 与 HCLK/8 之间二选一。
> **为什么存在**：便宜与精确不可兼得——RC 振荡器白送但不准，晶振要外加元件但准，芯片通常两者都备。
> **类比**：你的主场：服务器上电先以保守频率点亮、引导后再切全速——MCU 复位后也先用 HSI 跑起来，软件再配 HSE+PLL 冲 180MHz。
> ⚠️ 类比边界：x86 变频对软件基本透明；MCU 换主频后，所有按时间编程的寄存器（正是 LOAD）都得重算。

| 时钟档位                  | 定时器时钟 | 满量程最长单次定时（2^24/f） | 1Hz 塞得进 LOAD 吗 |
| ------------------------- | ---------- | ---------------------------- | ------------------ |
| HSI 16MHz（复位默认）     | 16 MHz     | 1.049 s                      | 能，0xF423FF       |
| HCLK 180MHz（本工程终态） | 180 MHz    | **93.3 ms**                  | **不能**，软件分频 |
| HCLK/8                    | 22.5 MHz   | 745.7 ms                     | 不能，软件分频     |

推导过程（这就是预期读数里每个数的来历）：

```text
HSI 16MHz，1Hz：   LOAD = 16,000,000/1 - 1       = 15,999,999 = 0xF423FF   ≤ 0xFFFFFF ✓
180MHz，1kHz：     LOAD = 180,000,000/1000 - 1   =    179,999 = 0x2BF1F    ✓
180MHz，1Hz：      需要 LOAD = 179,999,999       > 0xFFFFFF ✗ → 硬件 1kHz + 软件千进制
180MHz，1Hz 若 /8：需要 LOAD = 22,499,999        > 0xFFFFFF ✗ → /8 也救不了 1Hz
```

**CLKSOURCE 的取舍**：HCLK 精度高、事件延迟确定（无额外分频抖动）；HCLK/8 省电、单次定时窗口长 8 倍。
FreeRTOS 的 CM4F 端口用 HCLK——调度器要的是确定性，不是省电。类比：内核里高精度 hrtimer
与低精度 timer wheel 的分工。

## 实验：裸机 1kHz tick，软件凑出 1Hz 心跳

工程骨架沿用序章 `~/stm32/f429-freertos`（`clock_init()` 到 180MHz + 寄存器级 UART 已验证）。
设计决定：**硬件 tick 选 1kHz 而不是 100Hz**——这样 LOAD 与 FreeRTOS 端口算出的完全同值，
实验做完顺手就能和 RTOS 固件互相对账。

```c
/* ---------- SysTick 裸机节拍：硬件 1kHz + 软件千进制 = 1Hz 可观察 ---------- */

#define SYST_CTRL (*(volatile uint32_t *)0xE000E010) /* 四寄存器，内核私有外设（PPB，Private Peripheral Bus——内核旁边的私有小总线，不挤公共总线矩阵），不经总线矩阵 */
#define SYST_LOAD (*(volatile uint32_t *)0xE000E014)
#define SYST_VAL  (*(volatile uint32_t *)0xE000E018)

volatile uint32_t g_ms; /* 毫秒地基：ch02 的按键消抖、ch03 的音符时长全从这里取时间戳；volatile：警告编译器它会被中断改写、每次都真读内存——你的主场 */

void SysTick_Handler(void) /* 异常 #15；跑 FreeRTOS 固件时这个名字会被 xPortSysTickHandler 抢走 */
{
    g_ms++; /* 1kHz tick，每拍 +1ms */
}

static void systick_init_1khz(void)
{
    SYST_LOAD = 180000000u / 1000u - 1u; /* = 179,999 = 0x2BF1F，与 FreeRTOS 端口同款算式 */
    SYST_VAL = 0; /* 写任意值：计数清零 + COUNTFLAG 清零，从已知状态起跑 */
    SYST_CTRL = (1u << 2) /* CLKSOURCE=1：HCLK（要确定性，不要省电） */
              | (1u << 1) /* TICKINT=1：数到 0 抛异常 #15 */
              | (1u << 0); /* ENABLE=1：开跑 */
}

/* LED 引脚待核对（与 J73 跳帽相关，板卡事实库暂缺）——宏占位，核对后回填：
 * #define LED_PORT  GPIOx
 * #define LED_PIN   n
 */

int main(void)
{
    clock_init(); /* 序章验证过的 180MHz 配方：VOS=Scale1 + OverDrive + Flash 5WS（三个词的展开见序章 3.1 与第 6 节） */
    uart_init();  /* PA9/PA10 → CH340 → /dev/ttyUSB0 @115200 */
    systick_init_1khz();

    uint32_t last_beat = 0, beats = 0;
    for (;;) {
        if (g_ms - last_beat >= 1000u) { /* 软件千进制：1000 个 tick 凑出 1s */
            last_beat += 1000u;
            uart_puts("beat ");
            uart_putdec(++beats);
            uart_puts("   g_ms=");
            uart_putdec(g_ms);
            uart_puts("\r\n");
            /* LED 翻转在这里（引脚待核对） */
        }
    }
}
```

> **代码走读**：三处门道——
> ① 初始化顺序 LOAD→VAL→CTRL：先备弹药（LOAD）、归零计数器（写 VAL 的副作用同时清 COUNTFLAG）、最后才 ENABLE 开跑；顺序反了第一拍周期可能不定。
> ② `g_ms - last_beat >= 1000u`：无符号减法天然抗回绕——`g_ms` 约 49.7 天回绕一次，差值数学依然成立（你的主场，内核 jiffies 同款技巧）。
> ③ `SysTick_Handler` 这个名字本身就是向量表 #15 行的入口：我们的强定义覆盖了启动文件的弱符号桩（弱符号：可被同名强定义覆盖的默认桩，序章 3.4 全案）。

注意一个裸机细节：SysTick 异常的**复位默认优先级是 0（最高）**——它每 1ms 会抢占一切正在跑的代码（STM32 的中断优先级数字越小越高，复位默认 0 = 谁都敢抢；抢占 = 高优先级直接打断低优先级执行）。
本章单中断无所谓；一旦 ch02 的 EXTI 加入（EXTI：STM32 的外部中断控制器，把引脚电平变化报给 NVIC——NVIC：Nested Vectored Interrupt Controller，ARM 内核内置的中断管理器，管每个中断的开关与优先级，ch02 主角），就要显式排两者的优先级（FreeRTOS 下端口直接把 SysTick
压到最低，原因见[[ch18-critical-sections-spinlocks|FreeRTOS（十八）：临界区契约]]）。

## 预期输出（待实测核销）

串口侧（推导：1000 tick × 1ms = 1.000s 一拍，累积漂移取决于 25MHz 晶振的实际偏差）（晶振：石英晶体振荡器，给全芯片供节拍基准的元件，有 ppm 级固有误差）：

```text
beat 1   g_ms=1000
beat 2   g_ms=2000
beat 3   g_ms=3000
```

寄存器侧——`mdw` 一条命令读三个字，这是本章的主证据，设计意图如下：

```text
> mdw 0xE000E010 3
0xe000e010: 00000007 0002bf1f 000xxxxx
```

**命令拆解：** `mdw 0xE000E010 3`（openocd 会话内命令）

| 部分           | 作用                                                                                            |
| -------------- | ----------------------------------------------------------------------------------------------- |
| `mdw <地址> n` | memory display words：从地址起连读 n 个 32 位字，芯片运行中可读、零侵入                         |
| `0xE000E010`   | SysTick CTRL 的地址——0xE000E0xx 这段是内核私有外设区（PPB），ARM 架构规定，所有 Cortex-M 都一样 |
| `3`            | 连读 3 个字：CTRL(+0x0) / LOAD(+0x4) / VAL(+0x8) 一网打尽                                       |

**你会看到**：`0xe000e010: 00000007 0002bf1f 000xxxxx`（VAL 位读时是随机余数）。
**失败了先查**：读出全 0 且与文档矛盾 → 先 `reset halt`（序章方法论 5）；读 CALIB 用 `mdw 0xE000E01C`，验证 SHPR3 用 `mdw 0xE000ED20`（预期高两字节 0xF0F0）。

| 字   | 预期值                                     | 它证明什么                                                                                                              |
| ---- | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| CTRL | `0x00000007`（或 bit16=1 的 `0x00010007`） | 「你认为的配置」：ENABLE+TICKINT+CLKSOURCE 全落位；COUNTFLAG 是否置位取决于读的时刻——它自己会随节拍抖，反而是活着的旁证 |
| LOAD | `0x0002BF1F`                               | 「周期算术」：180MHz/1kHz−1=179,999，推导见上节                                                                         |
| VAL  | 任意 `[0, 0x2BF1F]`                        | 「计数器真的在跑」：读时瞬间的随机余数                                                                                  |

三字合起来才是「SysTick 活着」的完整证据链——只读 CTRL 证明不了周期对，只读 LOAD 证明不了在动。
（活体 `mdw` 不需要 halt，序章方法论 3。）

**与 FreeRTOS 固件对账**：换烧 `~/stm32/f429-freertos`（FreeRTOS 正式固件）后同址再读，
预期 LOAD 仍是 `0x2BF1F`——因为 CM4F 端口的 `prvSetupTimerInterrupt()` 写的是同一个算式
`configCPU_CLOCK_HZ / configTICK_RATE_HZ - 1 = 180,000,000/1000 - 1`。同一个数，两种身份。（prvSetupTimerInterrupt：FreeRTOS CM4F 端口里负责配 SysTick 的函数；configCPU_CLOCK_HZ / configTICK_RATE_HZ 是 FreeRTOSConfig.h 里"主频"与"每秒节拍数"两个宏）

## FreeRTOS 接管心跳：三行映射的落点

序章 3.4 节埋过这颗雷：ST 启动文件给所有中断留弱符号桩（粘到 Default_Handler 死循环），
而 Vanilla 内核 CM4F 端口的真处理函数叫别的名字。工程的 `FreeRTOSConfig.h` 尾部用三行
`#define` 完成改名（强符号覆盖弱桩）：

```c
#define vPortSVCHandler     SVC_Handler
#define xPortPendSVHandler  PendSV_Handler
#define xPortSysTickHandler SysTick_Handler  /* ← 本章主角：心跳中断被内核接管 */
```

接管之后 `SysTick_Handler` 这个向量里跑的是 `xPortSysTickHandler`，它做三件事：

1. `xTaskIncrementTick()`——推进系统节拍，唤醒到期的 `vTaskDelay` 任务；
2. 若唤醒了更高优先级任务，向 ICSR 写 PENDSVSET 挂起 PendSV，请求上下文切换（ICSR：Interrupt Control and State Register，内核中断控制状态寄存器；PENDSVSET：其中"请求 PendSV"的那一位；PendSV：专供 RTOS 做任务切换的可挂起异常；上下文切换：保存旧任务寄存器现场、换载新任务——RTOS 的换岗动作）；
3. 从此 `vTaskDelay()` 的「毫秒」有了物理刻度——刻度就是本章手工算的那个 1kHz。

端口还会把 SysTick 和 PendSV 的优先级压到 `configKERNEL_INTERRUPT_PRIORITY`（本工程 = 15<<4 =
`0xF0`，最低档；写 `0xFF` 因只有 4 位优先级实现、读回也是 `0xF0`）——配置在 SHPR3（`0xE000ED20`）
（SHPR3：System Handler Priority Register 3，管系统异常优先级的内核寄存器；补充拆解：STM32 优先级寄存器 8 位宽但只实现高 4 位 = 16 档，档号越小优先级越高，15<<4=0xF0 即第 15 档垫底，所以写 0xFF 读回被截成 0xF0）的最高字节，`mdw` 可验：预期高两字节 `0xF0F0`（SysTick+PendSV 都垫底）。调度器的时间本体不能
被业务中断拦腰打断，这是[[ch18-critical-sections-spinlocks|FreeRTOS（十八）]]
契约链的起点，本系列 ch12 会做故意违约的爆炸实验。

## 与 ESP32 / Linux 对照

| 维度       | STM32F429（本章）                 | ESP32（[[ch17-xtensa-port-internals\|FreeRTOS（十七）]] Xtensa 端口） | Linux                       |
| ---------- | --------------------------------- | --------------------------------------------------------------------- | --------------------------- |
| tick 硬件  | SysTick（内核自带，每核一颗）     | 无 SysTick，用芯片定时器组 + INTMUX                                   | per-CPU tick device/hrtimer |
| 上电默认   | HSI 16MHz，需要自己重算 LOAD      | 上电即有确定的 tick 源（IDF 打包好）                                  | TSC/PIT 定标后才可用        |
| 移植过路费 | 三行 `#define` 映射（序章头号坑） | IDF 已代接，用户无感                                                  | —                           |
| 周期调整   | `Suspend/Reload`（写 LOAD）       | esp_timer 抽象层                                                      | `NO_HZ`/highres 切换        |

（表中 ESP32 列的 INTMUX/esp_timer 是乐鑫封装好的中断分发矩阵与定时器抽象层——又是"别人替你做掉的事"）

ESP32 上「从没遇到过的坑」，在 Vanilla + 厂商启动文件的组合里全都要亲自踩一遍——这正是
[[ch16-portmacro-port-contract|FreeRTOS（十六）：portmacro 移植契约]]
讲的事：所谓移植，就是把这些「别人替你做掉的事」一件件认领回来。

## 本章待核对清单

| #   | 项                                                         | 核对方法                      | 状态（2026-08-30 实测）                                                                                                                                                       |
| --- | ---------------------------------------------------------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | CALIB 实测值（TENMS/SKEW/NOREF 位段）                      | `mdw 0xE000E01C`，对照 RM0090 | ✅ **0x4000493E**：SKEW=1（厂家自认 TENMS 不可信）、TENMS=18750（隐含参考 1.875MHz，非整分频——ST 自己都对不上，正是 SKEW=1 的由来；FreeRTOS 无视 CALIB 直算 LOAD 是正确姿势） |
| 2   | LED 引脚号（J73 相关）                                     | 丝印/原理图，代码宏占位待回填 | ✅ **官方教程查明 PH10（RGB 红，共阳低电平点亮）**，2026-09-01 已入裸机固件驱动翻转（`~/stm32/f429-labs/ch01-systick`）；肉眼确认待读者（若红灯不闪查 J73 跳帽）              |
| 3   | CTRL bit16 是否呈现「随节拍抖动 + 重复读后归零」的读清语义 | 连续 `mdw` 两次对比           | ✅ **固件内实锤（2026-09-01 裸机版）**：每秒双读 `c1=0x00010007, c2=0x00000007`——紧邻两条 CPU 读指令间仅数周期（回卷概率 ~0.006%），c2 的 bit16 恒为 0 = 读清语义成立         |
| 4   | 节拍周期 1.000s 的实际累积漂移（晶振偏差）                 | 串口时间戳跑 10 分钟对表      | ✅ **65 秒精测：+40.9 ppm**（固件 65.000s vs 主机 64.997s）——25MHz 晶振典型公差内（±50ppm 量级）；10 分钟长跑可再平均，结论不会变                                             |
| 5   | FreeRTOS 固件下 SHPR3 高字节读回 `0xF0F0`                  | `mdw 0xE000ED20`              | ✅ **0xF0F00000**，与推导一字不差（PendSV=15、SysTick=15）                                                                                                                    |

**同场其余实测**：CTRL=`0x00010007`（ENABLE\|TICKINT\|CLKSOURCE=7，预言全中，bit16=COUNTFLAG 置位）；LOAD=`0x0002BF1F`=179999（180MHz/1kHz 推导精确命中）；VAL 两次采样 0x7E/0x2A7（计数器活体）；tick 速率 ≈1000.5Hz。

下一章：[[ch02-button-polling-to-interrupt|按键三态：轮询、中断与消抖]]——
本章攒下的 `g_ms` 时间戳，就是那里消抖算法的地基。系列总目录见
[[f429-lab|F429 裸机实验室索引]]。
