---
title: "Zig × ESP32-S31 全栈开发（八）：定时器、DMA 与精确时序"
date: 2026-11-15 18:00:00
description: "把“等一会儿”拆成三种实现：软件忙等、TIMG 硬件闹钟、SYSTIMER 全局时基；用 1 MHz 的 TIMG 与 16 MHz 的 SYSTIMER 互测，给出抖动与漂移的可复现口径；再把 AHB-GDMA 的内存到内存搬运拆到 12 字节描述符、M2M 触发号与 cache/PSRAM 边界，最后用一个 2 KiB 搬运 + CPU 逐字节校验的工程把两件事跑通。"
tags: [zig, esp32-s31, riscv, timers, dma, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. [[ch04-linker-memory-layout|第四章：链接脚本与内存布局]]
> 5. [[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]
> 6. [[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]]
> 7. [[ch07-interrupts-exceptions-clic|第七章：中断、异常与 CLIC]]
> 8. **第八章：定时器、DMA 与精确时序**
> 9. [[ch09-spi-flash-partition-nvs|第九章：SPI Flash、分区与 NVS 存储]]

# Zig × ESP32-S31 全栈开发（八）：定时器、DMA 与精确时序

前七章里，“时间”出现过三次，每次都以不同的身份：

- 第五章用它当**尺子**：SYSTIMER 的增量除以 `mcycle` 的增量，量出 CPU 频率；
- 第六章用它当**节奏**：主循环每 1 ms 搬一次 UART FIFO，避免接收溢出；
- 第七章用它当**代价**：中断延迟、临界区长度、ISR 里能写多少代码。

但“1 ms”到底是什么，一直没有被认真对待。本章把这个问题拆开：**软件忙等、硬件定时器、全局时基**是三件不同的事，能力与代价都不同；而“搬运数据”也不必让 CPU 一个字节一个字节地做——DMA 就是为此存在的。

本章的两个可观测目标：

1. 用 TIMG 的 1 MHz 计数器测出“1 ms 周期”的真实偏差，给出**抖动**与**漂移**两个口径；
2. 用 AHB-GDMA 把 2 KiB 从一块 SRAM 搬到另一块，再由 CPU 独立校验，证明“搬运”与“校验”是两条路径。

> [!warning] 本章的证据边界
> TIMG/SYSTIMER/AHB-DMA 的基址、偏移与位域全部来自 ESP-IDF v6.1 的 `esp32s31` 头文件（下文逐条给出路径）；S31 的 TRM 仍是 Pre-release v0.7，手册转正后需逐项复核。本工程**已于 2026-11-13 真机启动**（`../logs/ch08-boot.log`）：TIMG 1 ms 与 `delayUs(500)` 统计正常（`min=0 max=4 mean_abs=0`、`min=2 max=8`）；**DMA M2M 内容不匹配**（`chunks=2 MISMATCH first_bad=0 bad=2040`），详见 `BRINGUP-2026-11-12.md`。

---

## 8.1 三种“等一会儿”，三种精度

### 1. 从最笨的开始

要让两个 GPIO 翻转之间隔 1 ms，至少有四种写法：

| 写法                   | 时间基准             | 典型误差来源                   | 适合的场景                   |
| ---------------------- | -------------------- | ------------------------------ | ---------------------------- |
| `for (0..N) {}` 空循环 | 编译器生成的指令数   | 优化级别、取指、流水线、cache  | 几乎不适合任何需要时间的场景 |
| ROM 的 `ets_delay_us`  | ROM 启动时标定的循环 | CPU 频率、ROM 版本、编译器     | 上电早期的粗延时             |
| TIMG 闹钟              | XTAL 40 MHz / 分频   | 中断关闭时的轮询延迟、总线竞争 | 周期性任务、精确单次触发     |
| SYSTIMER 忙等          | 16 MHz 固定节拍      | 读寄存器的开销（约几个 tick）  | 全局时基、超时判定           |

前两种的误差可以到“几倍”，后两种在微秒量级。**关键不是哪个更准，而是你要证明的是哪一件事**：

- 想证明“我的延时函数写了 1 ms”，就必须有一个独立于该函数的尺子；
- 想证明“硬件定时器准”，就不能用同一个定时器去量它自己。

### 2. 本章的尺子与对象

本章安排了两把尺子、两个被测对象：

```text
        ┌───────────────┐         ┌────────────────────┐
尺子 A  │ SYSTIMER      │  量     │ delayUs(500)       │  软件忙等
        │ 16 MHz, 52 位 │ ──────> │ （systimer 自己）  │
        └───────────────┘         └────────────────────┘

        ┌───────────────┐         ┌────────────────────┐
尺子 B  │ TIMG T0       │  量     │ 1 ms 闹钟命中时刻  │  硬件路径
        │ 1 MHz, 54 位  │ ──────> │ （绝对时刻偏差）   │
        └───────────────┘         └────────────────────┘
```

注意尺子 B 同时充当被测对象：**TIMG 的计数器**是尺子，**TIMG 的闹钟**是被测对象。这不算自证——计数器是自由的运行时钟，闹钟是比较器加中断/轮询路径，两者共享时钟源但走不同的硬件路径；测出来的偏差反映的是“比较与响应”，不是“时钟频率”。

### 3. 为什么把 DMA 放进同一章

因为“精确时序”与“搬运数据”在裸机上是同一个问题的两面：**CPU 的时间花在哪里**。

115200 的串口每毫秒来十几个字节，CPU 轮询搬 FIFO 的代价可以忽略；但 16 MB PSRAM 的一次整块搬运、SPI 屏的一帧 153,600 字节，靠 CPU 逐字节拷就是几十万个周期。DMA 把这些周期从 CPU 手里拿走，代价是：描述符要维护、cache 要同步、完成要等待。本章把这条链路的**最小闭环**做出来，后面 SPI/I2S/摄像头才有地基。

---

## 8.2 TIMG：两个组、四个通用定时器、两只看门狗

### 1. 实例与寄存器地图

S31 有两个 TIMG：

| 实例  | 基址         | 内容                        |
| ----- | ------------ | --------------------------- |
| TIMG0 | `0x20580000` | T0、T1、MWDT0、RTC 校准电路 |
| TIMG1 | `0x20581000` | T0、T1、MWDT1、RTC 校准电路 |

两者的寄存器布局完全相同（`REG_TIMG_BASE(i) = DR_REG_TIMERG0_BASE + i*0x1000`）。本章只用 TIMG0 的 T0：

| 寄存器                    | 偏移            | 关键位域                                                                                                         |
| ------------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------- |
| `TIMG_T0CONFIG_REG`       | `0x00`          | `T0_EN`[31]、`T0_INCREASE`[30]、`T0_AUTORELOAD`[29]、`T0_DIVIDER`[28:13]、`T0_DIVCNT_RST`[12]、`T0_ALARM_EN`[10] |
| `TIMG_T0LO_REG`           | `0x04`          | 计数器低 32 位（只读）                                                                                           |
| `TIMG_T0HI_REG`           | `0x08`          | 计数器高 22 位（只读，合计 54 位）                                                                               |
| `TIMG_T0UPDATE_REG`       | `0x0c`          | bit31：请求一次计数器快照，自清零                                                                                |
| `TIMG_T0ALARMLO/HI_REG`   | `0x10` / `0x14` | 闹钟目标值（54 位）                                                                                              |
| `TIMG_T0LOADLO/HI_REG`    | `0x18` / `0x1c` | 装载值暂存                                                                                                       |
| `TIMG_T0LOAD_REG`         | `0x20`          | 写任意值：把暂存值真正装入计数器                                                                                 |
| `TIMG_INT_RAW_TIMERS_REG` | `0x74`          | T0 命中 = bit0，T1 = bit1，MWDT = bit2                                                                           |
| `TIMG_INT_CLR_TIMERS_REG` | `0x7c`          | 写 1 清除对应位                                                                                                  |
| `TIMG_REGCLK_REG`         | `0xfc`          | bit31：寄存器时钟常开                                                                                            |

`T1` 的块从 `0x24` 开始，布局与 T0 一一对应（`T1CONFIG`、`T1LO`……）。

### 2. 时钟源不在 TIMG 里

TIMG 的计数时钟不是直接写 `T0CONFIG` 决定的，而是先在 **HP_SYS_CLKRST** 里选源、开时钟：

| 字段                        | 位置                    | 含义                                        |
| --------------------------- | ----------------------- | ------------------------------------------- |
| `TIMERGRP0_T0_SRC_SEL`[4:3] | `HP_SYS_CLKRST + 0x114` | 0 = XTAL(40 MHz)、1 = RC_FAST、2 = PLL_F80M |
| `TIMERGRP0_T0_CLK_EN`[5]    | 同上                    | 该定时器的时钟门控（复位值 1）              |
| `TIMERGRP0_APB_CLK_EN`[0]   | 同上                    | APB 侧寄存器访问时钟（复位值 1）            |

这个设计在 S31 上很常见：**外设的“功能时钟”与“寄存器时钟”分开**。只开 APB 时钟，能读写寄存器但计数器不走；只开功能时钟，计数器在跑但读回的值可能不同步。本章的 `timg.zig` 两件都显式做。

### 3. 分频：分辨率与量程的取舍

分频值直接写进 `T0_DIVIDER`，合法范围 **2..65536**，写 `0` 表示 65536（`timer_ll_set_clock_prescale` 的约定）。计数频率：

$$
f_{\text{tick}} = \frac{f_{\text{src}}}{\text{divider}}
$$

以 XTAL 40 MHz 为源：

| 分频  | tick 频率 | 分辨率  | 54 位计数器的量程                       |
| ----- | --------- | ------- | --------------------------------------- |
| 2     | 20 MHz    | 50 ns   | $2^{54}/20\,\text{MHz} \approx 28.5$ 年 |
| 40    | 1 MHz     | 1 µs    | $2^{54}\,\text{µs} \approx 570$ 年      |
| 400   | 100 kHz   | 10 µs   | 约 5700 年                              |
| 65536 | 约 610 Hz | 1.64 ms | 更长，但分辨率已经不适合 ms 级          |

量程在 54 位下根本不是约束，**真正的约束是分辨率**。本章选 40，让 1 tick = 1 µs，寄存器里的数就是微秒数——这是教学上的便利，不是精度上的最优。要测亚微秒级抖动，应选分频 2。

### 4. 计数、装载与快照：三个容易踩的顺序

**(a) 读计数器必须先 UPDATE。**

计数器在定时器时钟域，LO/HI 在 APB 域。直接连读两次可能读到“高 32 位是新的、低 32 位是旧的”撕裂值。正确顺序是：

```text
写 T0UPDATE.bit31 = 1
轮询直到该位自清零
读 T0HI（22 位）、T0LO（32 位）
```

IDF 的 `timer_ll_trigger_soft_capture` 就是这么做的，注释写得很直白：“Timer register is in a different clock domain from Timer hardware logic.”

**(b) 装载计数器要写两次。**

`T0LOADLO/HI` 只是暂存，写 `T0LOAD`（任意值）才触发装载。少写最后一步，计数器纹丝不动。

**(c) 闹钟命中后 `ALARM_EN` 自动清零。**

这是硬件行为，不是 bug：一次命中对应一次比较。要做周期任务，有两条路：

- 打开 `T0_AUTORELOAD`：计数器回 0 重新开始，但闹钟仍要重新使能；
- 本章的做法：每次命中后把目标值 `+= period`，重新 `setAlarm` + `enableAlarm`。这样目标时刻是**绝对时间轴**上的等距点，不会把软件的迟到量积分成漂移。

### 5. 中断还是轮询

`INT_RAW` 是粘滞的：命中后置位，直到写 `INT_CLR` 才清。`INT_ENA` 是另一层开关，决定这个原始位要不要变成 CPU 中断。

本章**不打开** `INT_ENA`：轮询 `INT_RAW` 就够了，而且能把“定时器准不准”与“中断路由通不通”分开。接成中断需要第七章的 CLIC 配置与中断矩阵路由；`timg.zig` 留了 `setInterruptEnabled()` 作为接口，但正文不声称它已在真机验证。

### 6. TIMG 里的另一只狗

同一组寄存器里还有 MWDT（`WDTCONFIG0..5`、`WDTFEED`、`WDTWPROTECT`）。第五章已讲过它的语义：APB/XTAL 域、可复位 CPU 或整系统、IDF 的 task WDT 与 interrupt WDT 都挂在它上面。本章**不碰**它——一旦误写 `WDTCONFIG0.EN`，应用会在几秒后莫名其妙重启，而现象与“DMA 卡死”几乎一样。

---

## 8.3 SYSTIMER：一台 52 位、16 MHz、永不重装的计数器

### 1. 为什么需要第二套定时器

TIMG 是**可编程**的：你可以改分频、改目标、停掉重来。这带来灵活性，也带来一个问题——**它不是全局时间轴**。两个模块各自配置 TIMG，互相之间没有共同的时间原点。

SYSTIMER 补的正是这个缺口：

| 属性   | 值                                          |
| ------ | ------------------------------------------- |
| 位宽   | 52 位                                       |
| 节拍   | 16 MHz（40 MHz XTAL / 2.5，硬件固定分频）   |
| 分辨率 | 62.5 ns                                     |
| 量程   | $2^{52}/16\,\text{MHz} \approx 8.9$ 年      |
| 计数器 | unit0、unit1 两个（本章只用 unit0）         |
| 比较器 | TARGET0/1/2，支持 target 模式与 period 模式 |
| 中断   | 需要 `INT_ENA` + 路由；本章不用             |

“16 MHz 固定”这句话的来源是 IDF 的端口层注释：

```text
IDF_PATH/components/esp_hw_support/port/esp32s31/systimer.c
  "systimer's clock source is fixed to XTAL (40MHz), and has a fixed
   fractional divider (2.5). So the resolution is 40MHz/2.5 = 16MHz."
```

也就是说：**读 SYSTIMER 不需要知道任何配置**。这正是它适合当尺子的原因。

### 2. 快照协议：与 TIMG 同构

| 寄存器                       | 偏移            | 作用                                    |
| ---------------------------- | --------------- | --------------------------------------- |
| `SYSTIMER_CONF`              | `0x00`          | bit31 寄存器时钟常开、bit30 unit0 使能  |
| `SYSTIMER_UNIT0_OP`          | `0x04`          | bit30 update、bit29 valid               |
| `SYSTIMER_UNIT0_VALUE_HI/LO` | `0x40` / `0x44` | 快照值                                  |
| `SYSTIMER_TARGET0_HI/LO`     | `0x1c` / `0x20` | 比较器 0 目标值                         |
| `SYSTIMER_TARGET0_CONF`      | `0x34`          | bit30 period 模式、bit31 选 unit0/unit1 |

读法与 TIMG 一样：写 update、等 valid、读 LO/HI/LO 并确认两次 LO 相同。本章的 `systimer.ticks()` 就是这段逻辑，外加一个 52 位掩码。

### 3. 本章怎么用它

只有两处：

1. `delayUs(us)`：起止都读 SYSTIMER，忙等到差值够；
2. `deadlineAfterUs(us)` + `reached(deadline)`：给 DMA 的轮询设 100 ms 超时。

比较器（TARGET0..2）在本章只做讲解：它们可以产生中断或触发 ETM 事件，但需要第七章的中断路由，`systimer.armTarget0In()` 只写了目标值与模式，没有开中断，正文也不声称它能工作。

---

## 8.4 从 tick 到时间：误差从哪来

### 1. 三个换算

设 tick 频率为 $f$，则：

$$
t_{\text{tick}} = \frac{1}{f}, \qquad
N_{\text{ticks}} = \lceil t \cdot f \rceil, \qquad
t_{\text{measured}} = \frac{N_{\text{ticks}}}{f}
$$

本章的 TIMG 是 $f = 1$ MHz，所以 $N = t$（微秒数）。SYSTIMER 是 $f = 16$ MHz，所以 1 µs = 16 ticks。

### 2. 时钟源本身的误差

| 源       | 标称        | 误差量级                                | 对 1 s 的影响 |
| -------- | ----------- | --------------------------------------- | ------------- |
| XTAL     | 40 MHz      | 晶振 ppm（典型 ±10 ppm，板级未知）      | ±10 µs        |
| RC_FAST  | 约 17.5 MHz | 未校准，随工艺/温度漂移（`..._APPROX`） | 百分比级      |
| PLL_F80M | 80 MHz      | 由 XTAL 倍频，ppm 与 XTAL 同源          | ±10 µs 量级   |

所以：**用 XTAL 或 PLL 派生时钟做时间基准，长期误差由晶振决定；用 RC_FAST，误差大到不能做“精确时序”**。本章的 TIMG 与 SYSTIMER 都锁定 XTAL，这是二者可以互测的前提。

### 3. 量化误差与轮询误差

即使时钟完美，读数的时刻也有误差：

- **量化**：TIMG 1 µs 分辨率意味着单次读数有 ±1 tick 的不确定度；
- **轮询延迟**：`while (!alarmPending()) {}` 从“硬件置位”到“软件读到”之间隔着若干指令与总线访问，典型是几十到几百纳秒，但在有 DMA/中断竞争时会拉长；
- **打印**：一次 `esp_rom_printf` 是 polling UART，115200 下一个字符约 87 µs。**绝不能在测量窗口里打印**——这是本章代码把统计与打印严格分开的原因。

### 4. 抖动与漂移：两个不同的数

设第 $i$ 次的目标时刻为 $T_i$，实际命中时刻为 $A_i$：

$$
\text{deviation}_i = A_i - T_i, \qquad
\text{drift}_N = \frac{1}{N}\sum_{i=1}^{N}(A_i - A_{i-1}) - \text{period}
$$

- 抖动看 $\max_i |\text{deviation}_i|$ 与 $\text{mean}(|\text{deviation}_i|)$；
- 漂移看相邻间隔的均值与标称周期之差。

本章的 `measureTimerJitter` 把目标写成 $T_i = T_{i-1} + 1000$（绝对值），所以：

- `deviation` 的分布 = 抖动；
- `last_interval` 与 1000 的差 = 漂移的瞬时值。

如果改成“命中后再等 1000”，那么每次的迟到都会被带进下一次目标，`last_interval` 恒等于 1000，而 `deviation` 会单调增长——这就是把漂移伪装成抖动的经典错误。

### 5. 用 GPIO 把时间搬到示波器上

软件里的数字再漂亮，也不如一根引脚上的方波直观。本章在每次测量循环与每次心跳时翻转 GPIO5：

```text
测量阶段：每次闹钟命中翻转一次 → 示波器上是一串 1 kHz 方波
心跳阶段：每 500 ms 翻转一次    → 1 Hz 方波
```

看三件事：

1. **周期**是否稳定在 1 ms（抖动）；
2. **有没有偶发的长间隔**（被 DMA/打印打断）；
3. **翻转沿的上升时间**（GPIO 驱动能力与探头负载，与定时器无关）。

> [!note] 观测引脚要按原理图核对
> 本工程默认 GPIO5，与第六章相同。J2 上的实际针脚位置、板上是否有其它器件挂在它上面，属于「待真机验证」事项；换脚只需改 `monitor_pin` 一个常量。

---

## 8.5 AHB-GDMA：把“搬字节”从 CPU 手里拿走

### 1. S31 的三套 DMA

| 引擎       | 基址         | 规模                             | 本章用途     |
| ---------- | ------------ | -------------------------------- | ------------ |
| AHB-DMA    | `0x20343000` | 5 个通道对（pair），PSRAM 可访问 | ✔ 内存到内存 |
| AXI-DMA    | `0x20348000` | 3 个通道对                       | 不涉及       |
| LP-AHB-DMA | `0x20819000` | 2 个通道对，低功耗域             | 不涉及       |

每个 pair 天然包含一个 **RX**（写内存）与一个 **TX**（读内存）通道，通道 `i` 的寄存器块 = 基址 + `i * 0x100`。这种“成对”设计是为了外设全双工：SPI 收与发同时进行，各占一个方向。

### 2. 描述符：12 字节，四个字段说了算

```c
/* components/esp_hal_dma/include/hal/dma_types.h */
struct dma_descriptor_s {
    struct {
        uint32_t size : 12;         /* 缓冲容量 */
        uint32_t length : 12;       /* 有效字节数 */
        uint32_t reversed24_27 : 4;
        uint32_t err_eof : 1;
        uint32_t reserved29 : 1;
        uint32_t suc_eof : 1;       /* 是否链尾 */
        uint32_t owner : 1;         /* 0 = CPU，1 = DMA */
    } dw0;
    void *buffer;
    dma_descriptor_t *next;
} __attribute__((aligned(4)));
```

对应到 Zig（本章 `dma.zig`）：

```zig
pub const Descriptor = extern struct {
    dw0: u32,
    buffer: u32,
    next: u32,
};

// dw0 = size | length << 12 | suc_eof << 30 | owner << 31
```

四个字段的语义，一条一条说：

| 字段      | 谁写      | 含义                                                    |
| --------- | --------- | ------------------------------------------------------- |
| `size`    | CPU       | 这块缓冲能装多少字节（≤4095）                           |
| `length`  | CPU / DMA | TX：要发多少；RX：硬件搬完后回写“实际收到多少”          |
| `suc_eof` | CPU       | 链尾标记。RX 侧靠它产生 `SUC_EOF`；不置则链不会正常结束 |
| `owner`   | CPU / DMA | 1 = 归 DMA。CPU 在启动前置 1，硬件搬完 RX 描述符后清 0  |

`next = 0` + `suc_eof = 1` 表示“到此为止”。本章建链的代码只有二十行：

```zig
chain[n].dw0 = size | (size << 12) |
    (@as(u32, @intFromBool(last)) << 30) |
    (1 << 31); // owner = DMA
chain[n].buffer = addr + @as(u32, @intCast(off));
chain[n].next = if (last) 0 else @intCast(@intFromPtr(&chain[n + 1]));
```

### 3. 内存到内存：两个通道必须“连到同一个触发号”

普通外设 DMA 是“外设 ↔ 内存”：RX 的 `PERI_SEL` 指向 SPI/I2S 的触发号，TX 同理。内存到内存则两边都不接外设，而是：

1. RX 的 `IN_CONF0.MEM_TRANS_EN = 1`（告诉硬件“数据来自内存，不是外设”）；
2. RX 与 TX 的 `PERI_SEL` 写**同一个** M2M 触发号；
3. 先启动 RX，再启动 TX。

第三步的顺序来自 IDF 的 `async_memcpy`：`try_start_pending_transaction` 里先 `gdma_start(rx)` 再 `gdma_start(tx)`。理由是 RX 先就位，TX 推过来的数据才有地方落。

M2M 触发号是多少？`gdma_ll.h` 给了掩码：

```c
#define AHB_DMA_LL_M2M_FREE_PERIPH_ID_MASK (0x8200)  /* bit9 与 bit15 */
```

所以可用号是 **9** 和 **15**，本章取 9。`PERI_SEL` 字段是 6 位，复位值 63 = 未连接；如果你的搬运一直超时，第一个要核对的就是它。

### 4. 启动、完成与错误

本章的 `dma.copy()` 流程：

```text
1. 停两个通道（LINK.STOP）
2. 复位两个通道（CONF0.RST 写 1 再写 0）
3. 配 CONF0：RX 置 MEM_TRANS_EN；两边 burst = single
4. PERI_SEL = 9（两边）
5. 建 RX/TX 描述符链，写 LINK_ADDR
6. 清 INT_RAW
7. 启动：RX（IN_LINK.START）→ TX（OUT_LINK.START）
8. 轮询 IN_INT_RAW：DONE 或 ERR；超时 100 ms
9. 读 DONE_DES_ADDR，停通道，清中断
```

完成位与错误位（IN/OUT 同构）：

| 位  | 名称       | 含义                          |
| --- | ---------- | ----------------------------- |
| 0   | `DONE`     | 该方向传输结束                |
| 1   | `SUC_EOF`  | 遇到链尾描述符（`suc_eof=1`） |
| 2   | `ERR_EOF`  | 链尾但数据有错                |
| 3   | `DSCR_ERR` | 描述符格式/地址错误           |

本章用 `DONE` 判定完成，同时检查 `ERR_EOF|DSCR_ERR` 提前失败；`SUC_EOF` 只作为证据打印。**只等 DONE 不等 SUC_EOF 是有意的**：先把“搬完”与“链尾正确”分成两个观测点，出问题时能立刻区分。

> [!note] 本章没有配置 `IN_CONF1` 的策略位
> IDF 的 `async_memcpy` 会在通道策略里打开 owner check、描述符回写与
> `eof_till_data_popped`。本章保持 `IN_CONF1` 的复位值，用最小的寄存器集合
> 把链路跑通；若真机出现“前面全对、尾部若干字节不对”，第一步是核对
> `ahb_dma_reg.h` 里 `IN_CONF1` 的 EOF 策略位（本章标为「待真机验证」）。

### 5. burst：先 single，再谈性能

`CONF0` 里的 burst 模式：

| 值  | 模式   | 每次突发 |
| --- | ------ | -------- |
| 0   | single | 1 拍     |
| 1   | incr4  | 4 拍     |
| 2   | incr8  | 8 拍     |
| 3   | incr16 | 16 拍    |

burst 越大，总线效率越高，但对齐要求也越高（地址与长度要按突发宽度对齐），PSRAM 还限制单次突发不超过 128 字节（`GDMA_LL_MAX_BURST_SIZE_PSRAM = 128`）。本章默认 single：**先证明链路与描述符正确，再谈吞吐**。`dma.zig` 的 `setBurstMode()` 留了口子。

---

## 8.6 cache、PSRAM 与对齐：DMA 的三个隐形约束

### 1. 缓冲在哪里

S31 模组有 16 MB PSRAM。AHB-DMA 在 S31 上是 PSRAM-capable（`GDMA_LL_AHB_PSRAM_CAPABLE = 1`），但“能访问”不等于“自动一致”：

- CPU 通过 cache 访问 PSRAM；
- DMA 直接访问 PSRAM 控制器背后的内存；
- 两者之间没有硬件一致性协议。

于是必须手动做：

| 方向 | 场景                     | 操作                             |
| ---- | ------------------------ | -------------------------------- |
| C2M  | CPU 写源缓冲，DMA 要读   | 按 cache line 写回（clean）      |
| M2C  | DMA 写目的缓冲，CPU 要读 | 按 cache line 无效（invalidate） |

IDF 的 `async_memcpy` 用 `esp_cache_msync(src, n, ...C2M...)` 与拆分 RX 缓冲到 cache line 对齐来处理这件事。本章的缓冲在内部 SRAM，且链接脚本只映射 SRAM，所以**不需要**这一步；但换到 PSRAM 就必须补上，否则会看到“前 64 字节对、后面全错”或“偶尔对”的现象。

> [!warning] cache line 大小以芯片配置为准
> S31 的 cache line 大小与可配置项需要查 `components/hal/include/hal/cache_hal.h` 与 `cache_types.h`；本章不硬编码具体字节数，只强调“必须按 cache line 对齐与同步”。

### 2. 描述符放哪里

描述符本身也是内存，也要被 DMA 读。放在 PSRAM 会多一次 cache 一致性问题；放在内部 SRAM 最省事。本章的描述符数组是 `.bss` 里的 `align(4)` 静态数组：

```zig
var tx_chain: [max_chunks]Descriptor align(4) = undefined;
var rx_chain: [max_chunks]Descriptor align(4) = undefined;
```

**不要**在函数栈上建描述符然后启动 DMA——函数返回后栈帧失效，硬件读到的是垃圾。这是本章把描述符放模块级 `var` 的唯一原因。

### 3. 对齐与长度

AHB-DMA 的硬约束（来自 `gdma_ll.h` 与 `async_memcpy` 的检查）：

| 约束              | 值                                     | 违反的后果                     |
| ----------------- | -------------------------------------- | ------------------------------ |
| 描述符对齐        | 4 字节（`GDMA_LL_AHB_DESC_ALIGNMENT`） | 描述符错误 / 传输不启动        |
| 单描述符缓冲上限  | 4095 字节                              | `size` 字段截断，数据被切      |
| 内部内存地址/长度 | 4 字节对齐                             | `Misaligned` 或总线错误        |
| PSRAM 突发        | ≤128 字节                              | 控制器行为未定义（手册待核对） |

本章的 `copy()` 在运行时检查地址与长度对齐，违反直接返回 `error.Misaligned`，而不是让硬件去产生一个难以解释的总线错误。

---

## 8.7 工程走读

### 1. 文件与职责

| 文件               | 职责                                                                     |
| ------------------ | ------------------------------------------------------------------------ |
| `src/start.zig`    | `esp_app_desc_t` + naked `_start`（关中断、sp/gp、清 `.bss`、跳 `main`） |
| `src/main.zig`     | 抖动测量、DMA 搬运 + 校验、500 ms 心跳、GPIO5 翻转                       |
| `src/timg.zig`     | TIMG0 T0：源/分频/计数/闹钟/中断位                                       |
| `src/systimer.zig` | SYSTIMER：52 位读数、`delayUs`、超时截止                                 |
| `src/dma.zig`      | AHB-GDMA：复位、M2M 连接、描述符链、启动与轮询                           |
| `linker/s31.ld`    | `ENTRY(_start)`、`.app_desc` 先于代码、栈/`.bss` 边界                    |
| `tools/flash.sh`   | 读 `flash_args`、替换应用行、一次烧录                                    |
| `idf-bootstrap/`   | 只产 bootloader、分区表与 `flash_args`                                   |

### 2. 启动顺序

```text
_start
  ├─ mstatus.MIE = 0, mie = 0
  ├─ sp = _stack_top, gp = __global_pointer$
  ├─ 清 .bss（描述符数组与 DMA 缓冲在这里被清零）
  └─ call main
        ├─ systimer.init()        // 时间基准先就位
        ├─ timg.init()            // 硬件秒表
        ├─ dma.init()             // AHB-PDMA 时钟/复位
        ├─ monitorInit()          // GPIO5 输出
        ├─ measureTimerJitter()   // 64 × 1 ms 绝对时刻
        ├─ measureDelayJitter()   // 64 × delayUs(500)
        ├─ dmaRun()               // 2 KiB 搬运 + 逐字节校验
        └─ while (true) { delayUs(500ms); toggle; dmaRun(); print; }
```

顺序不是随意的：SYSTIMER 必须最先初始化，因为 DMA 的超时与软件延时都用它；`dma.init()` 必须在任何描述符写入之前，否则写进去的寄存器可能被一次模块复位清掉。

### 3. 测量函数的关键片段

```zig
var target: u64 = period_ticks;
while (i < sample_count) : (i += 1) {
    timg.setAlarm(target);
    timg.enableAlarm();
    while (!timg.alarmPending()) {}

    const now = timg.counter();
    const dev = @as(i64, now) - @as(i64, target);
    // 统计 min/max/mean_abs
    timg.clearAlarm();
    monitorToggle();
    target += period_ticks;   // 绝对时刻，不累计迟到
}
```

注意三件事：

1. `timg.counter()` 内部先 UPDATE 再读，所以 `now` 是“发现命中之后”的时刻，包含轮询延迟；
2. 每次命中都 `clearAlarm()`，否则粘滞位会让下一轮立刻“命中”；
3. `target += period_ticks` 而不是 `target = now + period_ticks`。

### 4. DMA 搬运与校验

```zig
const report = try dma.copy(dma_dst[0..dma_len], dma_src[0..dma_len]);
// 用 CPU 逐字节比对，而不是让 DMA 自己证明自己
var bad: usize = 0;
for (dma_src, dma_dst) |a, b| {
    if (a != b) bad += 1;
}
```

`dma_len = 2048`，描述符分段 1024，所以链上有两条描述符。搬运完成后打印：

- `chunks=2`：证明链真的被切开；
- `in_raw` 的 bit0/bit1：证明 DONE 与 SUC_EOF 都到了；
- `rx_done`/`tx_done`：硬件回写的“最后成功描述符地址”，应分别落在 `rx_chain`/`tx_chain` 范围内；
- `transfer_ns`：从启动到观察到 DONE 的 SYSTIMER 差值换算，含软件轮询开销，不是纯硬件吞吐。

### 5. 构建与烧录

```bash
cd practice/zig-esp32-s31/ch08-timers-dma

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall

esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..

sh tools/flash.sh /dev/ttyUSB0     # Windows: sh tools/flash.sh COM7
```

`flash_args` 里的应用行会被替换成 `zig-out/bin/app.bin` 的绝对路径，bootloader 与分区表的偏移一律不手抄。细节见工程 README。

---

## 8.8 验收与证据

### 1. 验收标准

| 编号 | 标准                                                         | 证据                          |
| ---- | ------------------------------------------------------------ | ----------------------------- |
| A1   | TIMG T0 在 1 MHz 下连续命中 64 次，`last_interval` 接近 1000 | 串口 `timg.t0 1ms` 行         |
| A2   | `delayUs(500)` 的 `mean_abs` 明显大于 A1 的对应值            | 串口 `delayUs(500)` 行        |
| A3   | 2 KiB 搬运后 CPU 逐字节比对无差异                            | 串口 `dma: chunks=2 verified` |
| A4   | `IN_INT_RAW` 同时出现 DONE 与 SUC_EOF                        | 串口 `in_raw=0x...`           |
| A5   | 500 ms 心跳稳定，GPIO5 上约 1 Hz 方波                        | 示波器/逻辑分析仪             |
| A6   | 连续 30 分钟无累计错误                                       | `round N` 行持续为 `0 bad`    |

### 2. 输出形态（验收目标，不是实测）

```text
ch08-timers-dma | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
systimer: 16 MHz, boot ticks=<n> us
timg.t0 1ms: samples=64 min=<i> max=<j> mean_abs=<k> last_interval=<l> us
delayUs(500): samples=64 min=<i> max=<j> mean_abs=<k> last_interval=<l> us
dma: chunks=2 verified
  in_raw=0x<n> out_raw=0x<n> rx_done=0x<n> tx_done=0x<n>
  transfer_ns=<n>
round 1: 0 bad, <n> ns
```

尖括号里是**待真机回填**的占位，不是日志。具体偏差取决于板子、编译产物与是否接了调试器；本章不预填任何数值。

### 3. 真机前能做的静态检查

```bash
# 入口必须是 _start
riscv32-esp-elf-readelf -h zig-out/bin/app.elf | grep Entry

# .app_desc 的魔数：镜像偏移 32 处应是 32 54 cd ab（小端 0xABCD5432）
xxd -s 32 -l 4 zig-out/bin/app.bin

# .bss 里的描述符与缓冲不占镜像字节
riscv32-esp-elf-size -A zig-out/bin/app.elf | grep -E '\.bss|\.data'
```

---

## 8.9 排错

| 现象                        | 最可能的原因                                           | 处置                                                                 |
| --------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------- |
| `last_interval` 远大于 1000 | 分频不是 40 / 源不是 XTAL / 时钟门没开                 | 读回 `T0CONFIG.DIVIDER` 与 `TIMERGRP0_CTRL0.T0_SRC_SEL`、`T0_CLK_EN` |
| 闹钟只命中一次              | 命中后 `ALARM_EN` 自动清零，代码没重新使能             | 每轮都 `setAlarm` + `enableAlarm`                                    |
| 计数器读数不变化            | 只开了 APB 时钟；或 UPDATE 等待死循环                  | 确认 `T0_CLK_EN=1`；UPDATE 位必须自清零                              |
| 计数每次差 1                | `UPDATE` 之前读了 LO                                   | 严格按“UPDATE → 等 → 读 HI/LO”                                       |
| `delayUs` 偏差巨大          | SYSTIMER 没使能（`CONF` 的 bit31/bit30）               | 先打印两次 `ticks()` 的差值，确认在增长                              |
| DMA 超时                    | `PERI_SEL` 不是 9/15、`MEM_TRANS_EN` 没置、PDMA 时钟关 | 逐个读回 `IN_CONF0`、`IN/OUT_PERI_SEL`、`AHB_PDMA_CTRL0`             |
| DMA 报 `DSCR_ERR`           | 描述符地址没 4 字节对齐，或不在 SRAM                   | 检查 `align(4)` 与 `.bss` 地址；打印 `LINK_ADDR` 与描述符地址        |
| 全 0 / 全 0xA5              | 只启动了 RX 或只启动了 TX，顺序反了                    | 先 `IN_LINK.START`，再 `OUT_LINK.START`                              |
| 前面对、后面错（PSRAM）     | cache 没写回/无效                                      | 按 cache line 做 C2M/M2C；或先把缓冲放内部 SRAM                      |
| 偶发 `MISMATCH`             | 缓冲生命周期结束（栈上变量）或被别的代码改写           | 描述符与缓冲都放模块级/静态；确认没有复用同一块内存                  |
| 心跳漂到 0.5 s 以外         | 主循环里混入了打印，UART polling 拉长了周期            | 打印与测量分离；或降低打印频率                                       |
| 一上电几秒就重启            | 误写 TIMG 的 MWDT 寄存器（`WDTCONFIG0.EN`）            | 只碰 T0/T1 的寄存器块；对照第五章的 MWDT 章节                        |

---

## 8.10 下一章预告

本章把“时间”与“搬运”握在手里，但它们都还只在 SRAM 里打转：TIMG 与 SYSTIMER 是易失的计数器，DMA 搬的是内存，一掉电全没了。

下一章（第九章：SPI Flash、分区与 NVS 存储）转向**持久化**：

- SPI0/1 控制器与 flash 的读/写/擦命令，为什么“写之前必须先擦”；
- XIP：代码为什么能从 flash 直接取指，cache 在这里扮演什么角色；
- 分区表的结构与解析：`0x10000` 这个偏移是谁定的；
- NVS 的 KV 模型、页结构与掉电安全；
- 一个“配置掉电不丢”的实验：写、复位、读回、校验。

从那一章开始，本系列的工程才第一次拥有“重启之后仍然存在”的状态。

---

## 事实来源

| 事实                                                                                  | 来源                                                                                                                                            | 备注                                                                 |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| S31 双核 RV32IMAF C、320 MHz、40 MHz XTAL、512 KB SRAM、16 MB Flash + 16 MB PSRAM     | [Espressif ESP32-S31 产品页](https://www.espressif.com/en/products/socs/esp32-s31)                                                              | 与系列索引一致                                                       |
| TIMG0 `0x20580000`、TIMG1 `0x20581000`、SYSTIMER `0x20399000`、AHB-DMA `0x20343000`   | [IDF v6.1 `esp32s31/register/soc/reg_base.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/reg_base.h)   | `DR_REG_TIMERG0_BASE`、`DR_REG_SYSTIMER_BASE`、`DR_REG_AHB_DMA_BASE` |
| `REG_TIMG_BASE(i) = DR_REG_TIMERG0_BASE + i*0x1000`，T0 各寄存器偏移与位域            | [IDF v6.1 `timer_group_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/timer_group_reg.h)           | `T0CONFIG`[31:29,28:13,12,10]、`T0LO/HI`、`T0LOAD`、`INT_*_TIMERS`   |
| TIMG 时钟源 XTAL=0 / RC_FAST=1 / PLL_F80M=2，分频 2..65536（0=65536）                 | [IDF v6.1 `esp32s31/hal/timer_ll.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_timg/esp32s31/include/hal/timer_ll.h)    | `_timer_ll_set_clock_source`、`timer_ll_set_clock_prescale`          |
| TIMG 时钟门/源选择 `HP_SYS_CLKRST_TIMERGRP0_CTRL0`（`+0x114`）                        | [IDF v6.1 `hp_sys_clkrst_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h)       | `T0_SRC_SEL`[4:3]、`T0_CLK_EN`[5]                                    |
| SYSTIMER 固定 16 MHz、`CONF`/`UNIT0_OP`/`VALUE`/`TARGET0` 偏移与位域                  | [IDF v6.1 `systimer_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/systimer_reg.h)                 | bit31 clk_en、bit30 unit0、bit29 valid                               |
| SYSTIMER 源固定 XTAL 40 MHz、固定 2.5 分频                                            | [IDF v6.1 `port/esp32s31/systimer.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hw_support/port/esp32s31/systimer.c)        | 16 MHz 节拍的出处                                                    |
| AHB-DMA 通道寄存器偏移（`CH0` 的 IN/OUT、`LINK`、`PERI_SEL`、`INT_*`）                | [IDF v6.1 `ahb_dma_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/ahb_dma_reg.h)                   | `IN_CONF0` `+0x100`、`OUT_CONF0` `+0x180`、步长 `0x100`              |
| DMA 描述符 12 字节、4 字节对齐、`size/length/suc_eof/owner`                           | [IDF v6.1 `hal/dma_types.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_dma/include/hal/dma_types.h)                     | `dma_descriptor_s`                                                   |
| AHB-DMA 5 个 pair、描述符对齐 4B、PSRAM capable、PSRAM burst ≤128B、M2M 掩码 `0x8200` | [IDF v6.1 `esp32s31/hal/gdma_ll.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_dma/esp32s31/include/hal/gdma_ll.h)       | `GDMA_LL_AHB_*`、`AHB_DMA_LL_M2M_FREE_PERIPH_ID_MASK`                |
| M2M 连接语义：RX 置 `MEM_TRANS_EN`、`PERI_SEL` 写同一触发号                           | [IDF v6.1 `esp32s31/hal/ahb_dma_ll.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_dma/esp32s31/include/hal/ahb_dma_ll.h) | `ahb_dma_ll_rx_connect_to_mem` / `tx_connect_to_mem`                 |
| 内存到内存的启动顺序：先 RX 后 TX                                                     | [IDF v6.1 `async_memcpy_gdma.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_driver_dma/src/async_memcpy_gdma.c)              | `try_start_pending_transaction`                                      |
| DMA 时钟门控 `HP_SYS_CLKRST_AHB_PDMA_CTRL0`（`+0x7c`）                                | [IDF v6.1 `hp_sys_clkrst_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h)       | bit0 SYS_CLK_EN、bit1 RST_EN                                         |
| MWDT 与 task WDT/interrupt WDT 的关系                                                 | [IDF v6.1 `esp32s31/hal/mwdt_ll.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_wdt/esp32s31/include/hal/mwdt_ll.h)       | 本章只用 T0，不碰 MWDT                                               |
| `esp_rom_printf = 0x2f800024`、`esp_rom_delay_us = 0x2f80003c`                        | [IDF v6.1 `esp32s31.rom.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.ld)                     | 与第四章一致                                                         |
| `esp32s31` 是 IDF v6.1 preview target                                                 | [[ch11-esp32s31-lab-plan\|ONVIF 第十一章]]、`practice/zig-esp32-s31/SPEC.md`                                                                    | `set-target`/`build` 需 `--preview`                                  |

## 自查清单

进入下一章前，确认能回答这些问题：

- [ ] 软件空转、ROM `ets_delay_us`、TIMG 闹钟、SYSTIMER 忙等，四者的误差来源各是什么？
- [ ] 为什么“用同一个定时器量自己的周期”在逻辑上不成立？本章怎么避免？
- [ ] TIMG 的时钟源为什么要去 `HP_SYS_CLKRST` 里选，而不是写在 `T0CONFIG`？
- [ ] 分频 40 之后 1 tick 是多少？分频写 0 又表示多少？
- [ ] 54 位计数器的高位为什么只有 22 位？LO/HI 拼接时要注意什么？
- [ ] 读计数器前为什么必须写 `UPDATE` 并等它自清零？
- [ ] `T0LOAD` 与 `T0LOADLO/HI` 的分工是什么？少写哪一个会让计数器不动？
- [ ] `ALARM_EN` 为什么在命中后自动清零？周期任务该怎么重新装？
- [ ] 抖动与漂移的定义分别是什么？本章用哪个字段看漂移？
- [ ] 为什么测量窗口里绝对不能打印？一次 `esp_rom_printf` 的字符时间是多少？
- [ ] SYSTIMER 为什么“不需要读配置就知道节拍”？52 位在 16 MHz 下多久回绕？
- [ ] 描述符的 `size` 与 `length` 有什么区别？`owner` 由谁置位、谁清除？
- [ ] 内存到内存为什么要置 `MEM_TRANS_EN`，并且两边 `PERI_SEL` 相同？
- [ ] M2M 触发号从哪个掩码推出来？本工程用了哪一个？
- [ ] 为什么先启动 RX 再启动 TX？反过来会看到什么现象？
- [ ] 描述符为什么不能放函数栈上？缓冲为什么也要活到传输结束？
- [ ] PSRAM 上的 DMA 为什么需要 cache 写回/无效？不做会看到什么样的错误模式？
- [ ] 本章的 `transfer_ns` 包含哪些开销？它能不能当“纯硬件吞吐”用？

---

本章的产出不是“灯闪了”，而是两组**可复现的数字**：1 ms 周期的偏差分布，以及 2 KiB 搬运的 DONE/SUC_EOF 与逐字节校验结果。下一章离开易失的 SRAM，进入 SPI Flash 与分区表——从那里开始，工程才第一次拥有“重启之后还在”的状态。

系列导航：[[ch07-interrupts-exceptions-clic|上一章]] · [[zig-esp32-s31|系列索引]]
