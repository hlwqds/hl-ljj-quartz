---
title: "Zig × ESP32-S31 全栈开发（五）：时钟、复位与看门狗"
date: 2026-11-14 12:00:00
description: "从 ch04 的 `_start` 往前一步：把 bootloader 留下的时钟当成待测事实，用 mcycle 对 SYSTIMER 量出 CPU 频率；用 ROM 的 rtc_get_reset_reason 读复位原因并翻译成 IDF 归类；把 RWDT 的写保护、喂狗与超时语义拆开，解释为什么“跑几秒就重启”通常不是代码崩了而是狗咬人。附 S31 各路看门狗的寄存器与语义对照。"
tags: [zig, esp32-s31, riscv, clock, reset, watchdog, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. [[ch04-linker-memory-layout|第四章：链接脚本与内存布局]]
> 5. **第五章：时钟、复位与看门狗**
> 6. [[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]]

# Zig × ESP32-S31 全栈开发（五）：时钟、复位与看门狗

ch04 的 `_start` 只有二十条指令：关中断、设 `sp`/`gp`、清 `.bss`、跳 `main`。它能跑起来，靠的是三条**从没写进代码、却必须成立**的假设：

1. CPU 已经跑在某个确定的频率上（**本板实测 80 MHz**；S31 最高 320 MHz，但需要应用自己配 CPLL）；
2. 复位原因已经被 ROM 判定好，只是我们没去读；
3. 看门狗不会在应用跑到一半时咬人。

这三条假设在真机上一旦不成立，表现都长一个样：**串口输出乱码、或者跑几秒就重启、或者什么都没打印**。本章把它们逐条变成代码与可测量的证据。做完之后，`main` 开头那几行输出会同时回答三个问题：这次是怎么启动的、CPU 现在多快、看门狗现在什么状态。

> [!warning] 本章的证据边界
> 时钟树分工、SYSTIMER 的固定分频、复位原因编码、看门狗寄存器与写保护密钥，全部来自 ESP-IDF v6.1 的 `esp32s31` 头文件与源码（每一条在「事实来源」里给了路径）。本工程**已于 2026-11-13 真机运行**（原始输出见 `../logs/ch05-boot.log`）：复位原因 `CHIP_POWER_ON`、CPU 实测 **80 MHz**、RWDT 读回 `en=1 stg0..3=0 hold=612000`（bootloader 留下的使能位，未武装任何 stage）。超时实验与示波器波形未测；S31 的 TRM 仍是 Pre-release，手册转正后需逐项复核。

---

## 5.1 为什么下一步是时钟、复位与看门狗

### 1. 三条假设各自对应的失败模式

| 假设                       | 被打破时看到的现象                           | 本章怎么处理                            |
| -------------------------- | -------------------------------------------- | --------------------------------------- |
| CPU 频率确定               | 串口波特率错位 → 乱码；`delay_us` 的时长不对 | 用 mcycle/SYSTIMER 把频率**量**出来     |
| 复位原因可读               | 反复重启却不知道为什么；误以为是代码 bug     | 调 ROM 的 `rtc_get_reset_reason` 并翻译 |
| 看门狗不会咬人             | 跑几秒 ~ 几十秒后重启，复位原因指向 WDT      | 显式读状态、喂狗；做一个超时实验        |
| 外设时钟已开（隐含第四条） | 写外设寄存器没反应、读回全 0                 | 本章只碰 RTC 域的 RWDT，不踩这个坑      |

### 2. 为什么先测、不先写 PLL

很多教程在这一步会直接给你一串 PLL 寄存器写入，把 CPU “设成” 320 MHz。本章**故意不这么干**，理由有两个：

- **PLL 不是写几个数就完事**。S31 的 CPLL（CPU*PLL）从 40 MHz XTAL 倍频到 320 MHz，切换 CPU 时钟源时要经过“切到 XTAL → 配 PLL → 等锁定 → 切回 PLL”的序列，锁频失败还得回退。IDF 把这些封装在 `clk_ll_cpll*\*`/`rtc_clk_cpu_set_to_default_config()` 里，并且切频期间不能有代码在 cache 里跑（否则取指会踩到正在被改的时钟）。
- **bootloader 只保证“能跑”**。二级 bootloader 按 `CONFIG_BOOTLOADER_CPU_CLK_FREQ_MHZ`（默认 80）把 CPU 留在 **80 MHz**，320 MHz 的 CPLL 切换由 IDF 应用启动时自己做；形态 B 的裸机应用没有那一步，所以**量到的是 80 MHz**。对形态 B 来说，“配时钟”不是必需动作，“**证明时钟是什么**”才是。

于是本章的做法是：**不写任何一个时钟寄存器，只装一把尺子**。尺子的读数是可信的（它只依赖 XTAL 40 MHz 这个板级事实），量出来的结果如果和预期对不上（本板预期 80 MHz），问题就定位在“bootloader 配置”或“XTAL 不是 40 MHz”，而不是“我的 PLL 写错了”。

这条原则在本系列后面反复出现：**先建立可测量的基准，再动被测量的对象。**

### 3. 本章在路线图里的位置

Part II「裸机运行时」的第一章。ch04 拿回了内存布局，本章拿回**时间与复位语义**，ch06 再把串口从“ROM 的 printf”升级成“自己的 UART + 中断 + 环形缓冲”。顺序不能换：没有可信的时间基准，ch06 的波特率、ch07 的中断时延、ch08 的定时器都无从验收。

---

## 5.2 S31 的时钟树

### 1. 根时钟：只有 40 MHz XTAL 是“硬”事实

S31 的时钟树由 `soc/clk_tree_defs.h` 描述，根时钟分四类：两个外部时钟（XTAL / XTAL32K），两个片内 RC（RC_FAST / RC_SLOW）。

| 根时钟        | 频率             | 来源                                   |
| ------------- | ---------------- | -------------------------------------- |
| `XTAL_CLK`    | 40 MHz           | 板载晶振，`SOC_XTAL_FREQ_40M = 40`     |
| `XTAL32K_CLK` | 32768 Hz（可选） | 外部 32 kHz 晶振                       |
| `RC_FAST_CLK` | 约 17.5 MHz      | 片内 RC，`SOC_CLK_RC_FAST_FREQ_APPROX` |
| `RC_SLOW_CLK` | 约 136 kHz       | 片内 RC，`SOC_CLK_RC_SLOW_FREQ_APPROX` |

注意 `RC_FAST` / `RC_SLOW` 是“约”：RC 振荡器的绝对值随工艺与温度漂移，IDF 对它们只给 `..._APPROX` 宏，精确值要靠校准（`esp_clk_tree` 的 `PRELIMINARY` 精度档位）。**这就是本章不用片上 RC 当基准的原因**——用它量 CPU 频率，误差会直接叠进结果里。

### 2. 四个 PLL 与它们各自的用途

`clk_tree_defs.h` 的注释写得很清楚，照抄并整理：

| PLL   | 频率    | 用途                                                                                           |
| ----- | ------- | ---------------------------------------------------------------------------------------------- |
| CPLL  | 320 MHz | CPU_PLL：**CPU**、MSPI-Flash、MSPI-PSRAM                                                       |
| BBPLL | 480 MHz | SYS_PLL（AXI/AHB）：直接供 MSPI-Flash、GPSPI；再分频出 PLL_F240M / F160M / F120M / F80M / F20M |
| MPLL  | 可配置  | MSPI-PSRAM；再分频出 PLL_F50M / F25M 给外设                                                    |
| APLL  | 可配置  | 音频类外设（I2S、LCD、CAM 等）                                                                 |

CPU 的时钟源选择是一个枚举：

| `soc_cpu_clk_src_t`         | 值  | 含义                                                              |
| --------------------------- | --- | ----------------------------------------------------------------- |
| `SOC_CPU_CLK_SRC_XTAL`      | 0   | 直接用 40 MHz XTAL                                                |
| `SOC_CPU_CLK_SRC_CPLL`      | 1   | CPLL（可到 320 MHz）；**本板 bootloader 未选它**，实测停在 80 MHz |
| `SOC_CPU_CLK_SRC_PLL_F240M` | 3   | 用 BBPLL 分频出来的 240 MHz                                       |

所以“CPU 320 MHz”这句话的完整版本是：**XTAL 40 MHz → CPLL 倍频到 320 MHz → CPU 时钟源选 CPLL**。本章实测到的是 **PLL_F80M 的 80 MHz**（`SOC_CPU_CLK_SRC_PLL` 的 80 MHz 档），说明 bootloader 之后没有人再切 CPLL；IDF 应用会在 `cpu_start` 里切到 320。

### 3. APB 与外设时钟

`components/soc/esp32s31/include/soc/soc.h` 里有一行容易被忽略的宏：

```c
#define  APB_CLK_FREQ   ( 40*1000000 )
```

APB 是绝大多数外设（UART、TIMG、GPIO、I2C…）的总线时钟。它的实际频率由 CPU 时钟源分频得到，运行时可用 `clk_hal_apb_get_freq_hz()` 读到。对本章有意义的是下面这张分发表——每一行都决定了“1 个 tick 是多少纳秒”，也就决定了后面所有超时参数：

| 外设/用途           | 时钟源（默认）               | 每 tick 的时间        | 依据                                             |
| ------------------- | ---------------------------- | --------------------- | ------------------------------------------------ |
| CPU                 | CPLL 320 MHz                 | 3.125 ns              | `soc_cpu_clk_src_t`（本板实测 80 MHz → 12.5 ns） |
| SYSTIMER            | XTAL 40 MHz，固定 2.5 分频   | 62.5 ns（16 MHz）     | `port/esp32s31/systimer.c`                       |
| MWDT（TIMG 看门狗） | 只允许 XTAL 40 MHz           | 25 ns                 | `mwdt_ll_set_clock_source()` 断言只有 XTAL       |
| RWDT（RTC 看门狗）  | RTC_SLOW_CLK（默认 RC_SLOW） | 约 7.35 µs（136 kHz） | `SOC_CLK_RC_SLOW_FREQ_APPROX`                    |
| UART 波特率源       | PLL_F80M（默认）             | —                     | `SOC_UART_CLKS` / `UART_SCLK_DEFAULT`            |
| RMT（WS2812 用）    | PLL_F80M（默认）             | —                     | `SOC_RMT_CLKS` / `RMT_CLK_SRC_DEFAULT`           |

“UART 用 PLL_F80M”这一行值得记住：ch06 里自己算波特率分频时，被除数不是 40 MHz 也不是 320 MHz，而是 80 MHz。而 ROM 的 `ets_printf` 用的是 bootloader 早先配好的 UART 参数，**它不受我们的 CPU 频率影响**——这也是本章在量频率时还能看到正常输出的原因。

### 4. SYSTIMER 为什么适合当尺子

SYSTIMER 在 S31 上的时钟链是**固定**的，IDF 的实现文件里只有两句话：

```text
systimer's clock source is fixed to XTAL (40MHz), and has a fixed fractional
divider (2.5). So the resolution of the systimer is 40MHz/2.5 = 16MHz.
```

固定意味着：**不需要读任何配置就能知道 1 tick = 62.5 ns**。它唯一的外部依赖是“XTAL 是 40 MHz”，而这是板卡事实（`SOC_XTAL_FREQ_40M`，且模组上焊的是 40 MHz 晶振）。用它当尺子量 CPU，误差来源只剩晶振本身的 ppm 级偏差，比用 `RC_FAST` 或“数循环”好几个数量级。

SYSTIMER 还有一条对本系列很重要的性质：它的门控与源选择挂在 `HP_SYS_CLKRST` 的 `systimer_ctrl0`（`+0x120`）上，属于 HP 域的常规外设，重配的代价低，后续章节的 tick、超时、DMA 时间戳都可以挂在它上面。ch08 会回到它。

---

## 5.3 怎么测量：mcycle 对 SYSTIMER

### 1. 原理

RISC-V 有两个 64 位的机器态计数器：

- `mcycle`：**执行过的周期数**（per-hart）；
- `minstret`：退休的指令数。

在 RV32 上，它们各占两个 CSR：`mcycle`（低 32 位，0xB00）/ `mcycleh`（高 32 位，0xB80），`minstret`/`minstreth` 同理。`mcycle` 数的是**时钟周期**而不是墙钟时间，所以：

```text
CPU 频率 = Δmcycle / Δt
```

`Δt` 由 SYSTIMER 给出（16 MHz，1 tick = 62.5 ns），于是：

```text
CPU 频率 = Δmcycle / (ΔSYSTIMER_ticks / 16)
```

两个计数器同一次读、同一个窗口，除法的结果就是频率。窗口取 200 ms 时，80 MHz 的 CPU 大约走 1600 万个 cycle——32 位 `mcycle` 在 80 MHz 下约 53.7 秒才回绕一次，所以**只读低 32 位**是安全的，用不着处理 64 位拼接与进位。

### 2. SYSTIMER 的读法：为什么不是直接读两个寄存器

SYSTIMER 的计数器是 64 位、双寄存器（`UNIT0_VALUE_HI` / `UNIT0_VALUE_LO`）。直接“先读高再读低”会在两次读之间发生进位，得到一个差了 2^32 的值。IDF 的 `systimer_hal_get_counter_value()` 用三步解决：

1. 往 `UNIT0_OP.timer_unit_update` 写 1，请求一次快照；
2. 轮询 `UNIT0_OP.timer_unit_value_valid`，等快照完成；
3. 读 LO、读 HI、再读 LO，**两次 LO 相同**才认为没有撕裂，否则重来。

`clock.zig` 的 `ticks()` 就是这三步的 Zig 版本（省掉了高位的后续使用，只拼 64 位整体返回）。

寄存器与位域（基址 `DR_REG_SYSTIMER_BASE = 0x20399000`）：

| 偏移   | 寄存器              | 用到的位                                     |
| ------ | ------------------- | -------------------------------------------- |
| `0x00` | `SYSTIMER_CONF`     | bit31 `clk_en`，bit30 unit0 使能             |
| `0x04` | `SYSTIMER_UNIT0_OP` | bit30 请求快照（WT），bit29 快照有效（R/SS） |
| `0x40` | `UNIT0_VALUE_HI`    | 快照高 32 位                                 |
| `0x44` | `UNIT0_VALUE_LO`    | 快照低 32 位                                 |

`clk_en` 这一位要显式置 1：IDF 的 `systimer_hal_init()` 里唯一的动作就是 `systimer_ll_enable_clock(dev, true)`，也就是写这一位。bootloader 几乎一定已经打开了它（bootloader 自己要用 SYSTIMER 计时），我们的写是幂等的**置位**，不会把计数器清零，所以不会打断已有的时间轴。

### 3. 代码走读

`src/clock.zig` 的对外面很小：五个函数加一个结果结构 `Measurement`。

| 函数                 | 作用                                         |
| -------------------- | -------------------------------------------- |
| `init()`             | 置 `CONF.clk_en` 与 unit0 使能，幂等         |
| `ticks() u64`        | 快照 + 三步读法，返回 16 MHz 计数            |
| `us() u32`           | `ticks()/16`，低 32 位（约 71 分钟回绕）     |
| `measure(window_us)` | 同一窗口内同时取 mcycle 增量与 SYSTIMER 增量 |
| `delayUs(us)`        | 用 SYSTIMER 忙等，不依赖 ROM 标定的延时      |

`measure` 的核心是这一段：

```zig
const start_ticks = ticks();
const start_cycles = cycleCounter();

while (ticks() - start_ticks < window_ticks) {}

const end_cycles = cycleCounter();
const end_ticks = ticks();
```

三个细节决定了它可信：

1. **`mcycle` 用 `csrr` 直接读**，不经过任何库函数：

   ```zig
   inline fn cycleCounter() u32 {
       return asm volatile ("csrr %[dst], mcycle"
           : [dst] "=r" (-> u32),
       );
   }
   ```

2. **两种减法写法不同，各有理由**：`ticks()` 是 `u64`，窗口内不会回绕，普通 `-` 就是对的；`mcycle` 是 `u32`，用 `-%`（wrapping）显式声明“允许回绕”，比依赖“不会溢出”的假设更诚实，也让编译器不必插入溢出检查。
3. **延时不用 ROM 的 `ets_delay_us`**：那个函数的循环次数是 ROM 在启动时按“假设的 CPU 频率”标定的。用它当尺子，等于用一个未验证的频率去验证同一个频率，测不出任何偏差。`delayUs` 改用 SYSTIMER 的绝对 tick 比较，链条上只有一个未验证量（XTAL）。

### 4. 换算与分辨率

```zig
pub fn mhz(self: Measurement) u32 {
    const window_us = self.us();
    if (window_us == 0) return 0;
    return (self.cycles + window_us / 2) / window_us;
}
```

窗口 200 ms 时，`window_us = 200000`，读数精度是 ±1 MHz（整数除法）。对“到底是 80 还是 320 MHz”这个问题足够了；要更高精度就把窗口拉长到 1 秒（32 位 `mcycle` 在 80 MHz 下 53.7 秒回绕，1 秒窗口安全）。

真机实测（2026-11-13，coreboard）：`cycles=16000012`、`ticks=3200030`、窗口 `200001 us` → **80 MHz**。不同 CPU 源对应的量级：

| CPU 源                  | `cycles`（200 ms 窗口） | `mhz()` |
| ----------------------- | ----------------------- | ------- |
| PLL_F80M 80 MHz（本板） | 约 16,000,000           | 80      |
| CPLL 320 MHz            | 约 64,000,000           | 320     |
| PLL_F240M 240 MHz       | 约 48,000,000           | 240     |
| XTAL 40 MHz             | 约 8,000,000            | 40      |

如果读到 40 MHz，说明 CPU 停在 XTAL 上（bootloader 切 PLL 失败后会回退到 XTAL），此时“代码能跑但慢 8 倍”，而串口仍然正常——这正是“测出来”比“假设它”有价值的地方。

### 5. 这条测量链的三个天花板

诚实地列出它量不到的东西：

- **量不到 PLL 的锁定质量**。频率对了不代表抖动小；抖动的验收要 GPIO 翻转 + 示波器（ch08）。
- **量不到单个外设的时钟**。我们只测 CPU。UART/TIMG 的实际分频要么读配置寄存器，要么用外设自身验证（ch06 用波特率回环验）。
- **量不到多核**。S31 是双核，`mcycle` 是 per-hart 的；本章只跑 PRO_CPU（`cpu_no = 0`），APP_CPU 的启动要等后面 RTOS 部分的 SMP 章节。

---

## 5.4 复位原因：ROM 已经判定好了

### 1. 为什么这件事不该自己猜

复位原因不是一个“应用自己记账”的问题：上电、欠压、看门狗、JTAG、CPU lockup 这些事件发生时，应用还**没在跑**。判定必须在 ROM 里完成，ROM 把结论留在 RTC 域的寄存器里，应用只负责读。

S31 的 ROM 提供了一个函数：

```text
IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld
  rtc_get_reset_reason = 0x2f800018;

IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.api.ld
  PROVIDE ( esp_rom_get_reset_reason = rtc_get_reset_reason );
```

原型在 `esp_rom/esp32s31/include/esp32s31/rom/rtc.h`：

```c
RESET_REASON rtc_get_reset_reason(int cpu_no);
```

于是形态 B 的项目只需要在链接脚本里加一行：

```ld
PROVIDE(rtc_get_reset_reason = 0x2f800018);
```

`PROVIDE` 的语义是“仅在符号未定义时生效”，因此它不会覆盖将来某个真正的定义，也不会和 IDF 的别名冲突。

### 2. 编码表

返回值是 `soc_reset_reason_t` 的编码，定义在 `components/soc/esp32s31/include/soc/reset_reasons.h`。**这张表必须照着源码抄，不要凭 ESP32 的经验记**——S31 的编码与老芯片不同，例如 `0x05` 在这里同时表示“深睡唤醒”和“PMU 掉电复位”。

| 编码   | `soc_reset_reason_t`                    | IDF 归类（`esp_reset_reason_t`）    |
| ------ | --------------------------------------- | ----------------------------------- |
| `0x01` | `CHIP_POWER_ON`                         | `ESP_RST_POWERON`                   |
| `0x03` | `CORE_SW`                               | `ESP_RST_SW`（若有 hint 则用 hint） |
| `0x05` | `CORE_DEEP_SLEEP` / `CORE_PMU_PWR_DOWN` | `ESP_RST_DEEPSLEEP`                 |
| `0x06` | `CPU_PMU_PWR_DOWN`                      | `ESP_RST_DEEPSLEEP`                 |
| `0x07` | `CORE_MWDT0`                            | `ESP_RST_TASK_WDT`                  |
| `0x08` | `CORE_MWDT1`                            | `ESP_RST_INT_WDT`                   |
| `0x09` | `CORE_RWDT`                             | `ESP_RST_WDT`                       |
| `0x0B` | `CPU_MWDT`                              | `ESP_RST_WDT`                       |
| `0x0C` | `CPU_SW`（旧名 `CPU0_SW`）              | `ESP_RST_SW`                        |
| `0x0D` | `CPU_RWDT`                              | `ESP_RST_WDT`                       |
| `0x0F` | `SYS_BROWN_OUT`                         | `ESP_RST_BROWNOUT`                  |
| `0x10` | `SYS_RWDT`                              | `ESP_RST_WDT`                       |
| `0x12` | `SYS_SUPER_WDT`                         | `ESP_RST_WDT`                       |
| `0x13` | `CORE_PWR_GLITCH`                       | `ESP_RST_PWR_GLITCH`                |
| `0x14` | `CORE_EFUSE_CRC`                        | `ESP_RST_EFUSE`                     |
| `0x16` | `CORE_USB_JTAG`                         | `ESP_RST_USB`                       |
| `0x17` | `CORE_USB_UART`                         | `ESP_RST_USB`                       |
| `0x18` | `CPU_JTAG`                              | `ESP_RST_JTAG`                      |
| `0x1A` | `CPU_LOCKUP`                            | `ESP_RST_CPU_LOCKUP`                |

归类规则来自 `components/esp_system/port/soc/esp32s31/reset_reason.c`。两层都要打印：**编码回答“具体是谁”，归类回答“对应用意味着什么”**。例如 `0x09`/`0x0D`/`0x10` 都归到 `ESP_RST_WDT`，但一个是 RTC WDT 复位了核心，一个是复位了 CPU，一个是复位了系统——排障时这三者的处置完全不同。

### 3. 一个容易忽略的细节：hint

IDF 的 `ESP_RST_PANIC` / `ESP_RST_TASK_WDT` / `ESP_RST_INT_WDT` 这几个值**不来自硬件编码**，而是软件在复位前写进 RTC 域的“hint”寄存器（`RTC_RESET_CAUSE_REG`，也就是 `LP_SYSTEM_REG_LP_STORE6_REG`），启动后再读回来叠加到归类上。形态 B 的项目没有 IDF 的 panic handler，所以本章读到的永远是硬件的原始编码——这也正是我们想看的。ch06 把 panic handler 写出来之后，hint 才有意义。

---

## 5.5 看门狗：四路寄存器，两种作用域

### 1. 四路看门狗的分工

S31 上与复位相关、能被“喂”的看门狗有四个寄存器块（MWDT0、MWDT1、RWDT、SWD），作用域各不相同：

| 看门狗           | 所在域 | 计数时钟                   | 能复位什么          | IDF 里的身份                |
| ---------------- | ------ | -------------------------- | ------------------- | --------------------------- |
| MWDT0（TIMG0）   | HP/APB | XTAL 40 MHz（25 ns/tick）  | CPU / 系统          | **task WDT**（`0x07`）      |
| MWDT1（TIMG1）   | HP/APB | XTAL 40 MHz                | CPU / 系统          | **interrupt WDT**（`0x08`） |
| RWDT（RTC_WDT）  | RTC    | RTC_SLOW_CLK（约 136 kHz） | CPU / 系统 / RTC 域 | `0x09` / `0x0D` / `0x10`    |
| SWD（super WDT） | RTC    | RTC_SLOW_CLK               | 连 RTC 域一起复位   | `0x12`                      |

这个映射不是我归纳的，是 IDF 自己的归类表写的：`CORE_MWDT0 → ESP_RST_TASK_WDT`、`CORE_MWDT1 → ESP_RST_INT_WDT`、`CORE_RWDT`/`CPU_RWDT`/`SYS_RWDT` → `ESP_RST_WDT`。

为什么 task WDT 用 MWDT0 而不是 RTC 那只？因为 task WDT 要“按毫秒计时、超时先中断再复位”，MWDT 的 40 MHz 时钟给得起这个分辨率；RWDT 在 RTC 域，7 µs 一个 tick，适合做“最后一道防线”——连 HP 域都挂了（比如 flash 读死锁）它还在跑。

### 2. RWDT 的寄存器与写保护

RWDT 的寄存器块在 `DR_REG_RTC_WDT_BASE = 0x20801000`：

| 偏移   | 寄存器     | 内容                                                                                                                                                                 |
| ------ | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0x00` | `CONFIG0`  | bit31 `EN`、bit12 `FLASHBOOT_MOD_EN`、bit11 `PROCPU_RESET_EN`、bit10 `APPCPU_RESET_EN`、bit9 `PAUSE_IN_SLP`、`STG3[21:19]` `STG2[24:22]` `STG1[27:25]` `STG0[30:28]` |
| `0x04` | `CONFIG1`  | `STG0_HOLD`（tick 数，带 eFuse 决定的隐含倍率）                                                                                                                      |
| `0x08` | `CONFIG2`  | `STG1_HOLD`                                                                                                                                                          |
| `0x0C` | `CONFIG3`  | `STG2_HOLD`                                                                                                                                                          |
| `0x10` | `CONFIG4`  | `STG3_HOLD`                                                                                                                                                          |
| `0x14` | `FEED`     | bit31：写 1 喂狗                                                                                                                                                     |
| `0x18` | `WPROTECT` | 写 `0x50D83AA1` 解锁；写 0 上锁                                                                                                                                      |

**写保护是这一节最重要的知识点**（也是新手最容易踩的坑）：未解锁时写 `CONFIG*`/`FEED` 会被硬件**静默丢弃**——不报错、读回还是旧值，表现为“我明明喂狗了却还是被复位”。所以每次访问都是三段式：

```zig
unlock();                       // WPROTECT = 0x50D83AA1
reg(reg_feed).* = bit_feed;     // 真正的写
lock();                         // WPROTECT = 0
```

密钥 `0x50D83AA1` 来自 `esp_hal_wdt/esp32s31/include/hal/rwdt_ll.h` 的 `RTC_WDT_WKEY_VALUE`（MWDT 用同一个值，见 `mwdt_ll.h`）。

### 3. 四个阶段与动作编码

RWDT 不是“一个超时”，而是**四级串联**：STG0 超时后执行动作，若动作是 `INT`，中断被触发而计数继续进 STG1；只有动作是复位类时，复位才真正发生。动作编码：

| 值  | 动作           | 说明                          |
| --- | -------------- | ----------------------------- |
| 0   | `OFF`          | 该阶段不做任何事              |
| 1   | `INT`          | 只置中断，不喂就一直往后走    |
| 2   | `RESET_CPU`    | 只复位 CPU 核                 |
| 3   | `RESET_SYSTEM` | 复位整个数字系统              |
| 4   | `RESET_RTC`    | 连 RTC 域一起复位（更深一层） |

这就是“为什么有时候是先打印警告、过一会儿才重启”：常见的配法是第一级 `INT`（给你在中断里打印/落盘），第二级才 `RESET_SYSTEM`。IDF 的 task WDT 正是这个结构——STAGE0 在 `timeout_ms` 处 `INT`，STAGE1 在 2 倍时间处 `RESET_SYSTEM`（`components/esp_system/task_wdt/task_wdt_impl_timergroup.c`）。本章为了把语义讲干净，只实现最简单的一种：**STG0 = `RESET_SYSTEM`，其余阶段 OFF**。

### 4. STG0 的隐含倍率

`CONFIG1` 写进去的 tick 数**不一定是实际 tick 数**。`rwdt_ll_config_stage()` 对 STG0 有这么一段：

```c
hw->config1.val = timeout_ticks >> (1 + REG_GET_FIELD(EFUSE_RD_REPEAT_DATA1_REG, EFUSE_WDT_DELAY_SEL));
```

也就是说硅片内部还有一个 `1 << (1 + sel)` 的隐含倍率，`sel` 来自 eFuse（出厂标定，用来补偿不同批次的 RC 慢时钟偏差）。带来的后果是：

- 想精确控制“几秒”的，必须**读 eFuse 的 `WDT_DELAY_SEL` 再换算**（IDF 的做法是写入前右移）；
- 本章的 `armSystemReset(stage0_ticks)` 直接写原始 tick 数，没有右移，所以**实际超时是 `stage0_ticks << (1 + sel)` 个 tick，比预期只长不短**。换句话说，实验里看到的复位时刻只会晚于换算值。

这一点在代码注释里写明了，真机标定时要用秒表回填，不要照抄注释里的数字。

### 5. 「几秒后重启」的几种可能

看到“跑几秒就重启”，复位原因会告诉你是哪一种：

| 复位原因               | 含义                           | 先查什么                                   |
| ---------------------- | ------------------------------ | ------------------------------------------ |
| `0x07` `CORE_MWDT0`    | task WDT 超时                  | 有没有长临界区/关中断超时/大块 flash 操作  |
| `0x0B` `CPU_MWDT`      | MWDT 复位了 CPU                | 主循环里有没有“超过喂狗周期”的阻塞         |
| `0x09`/`0x0D`/`0x10`   | RWDT 超时（核心 / CPU / 系统） | 应用有没有喂 RWDT；bootloader 有没有留下它 |
| `0x12` `SYS_SUPER_WDT` | SWD 复位                       | 前面所有狗都失效了，属于最后一道防线       |
| `0x0F` `SYS_BROWN_OUT` | 欠压                           | 供电、USB 线、外设电流                     |

本章的工程在 `main` 里**显式喂 RWDT**（每 500 ms 一次），所以即使 bootloader 把 RWDT 留在使能状态，应用也不会被咬。这是“接手别人的现场”的正确姿势：先看清状态（`wdt.state()` 打印六个字段），再决定喂还是关。

---

## 5.6 工程走读：`ch05-clock-reset-wdt`

### 1. 文件表

| 路径             | 角色                                                           | 代码浏览                                                                               |
| ---------------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `build.zig`      | 目标串 + 链接脚本 + 产物 `zig-out/bin/app.elf`                 | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/build.zig)                    |
| `linker/s31.ld`  | 与 ch04 同布局；多 `PROVIDE(rtc_get_reset_reason)`             | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/linker/s31.ld)                |
| `src/start.zig`  | `esp_app_desc_t` + naked `_start`（顺序与 ch04 一致）          | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/start.zig)                |
| `src/main.zig`   | 打印复位原因、量频率、打印 RWDT 状态、每 500 ms 喂狗           | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/main.zig)                 |
| `src/clock.zig`  | SYSTIMER 读法 + `mcycle` 测量 + `delayUs`                      | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/clock.zig)                |
| `src/reset.zig`  | ROM `rtc_get_reset_reason` + 编码表 + IDF 归类 + 一句话解释    | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/reset.zig)                |
| `src/wdt.zig`    | RWDT：解锁/上锁、`feed`、`disable`、`state`、`armSystemReset`  | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/wdt.zig)                  |
| `tools/flash.sh` | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用 | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/tools/flash.sh)               |
| `idf-bootstrap/` | 只产二级 bootloader、分区表与 `flash_args` 的最小 IDF 工程     | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/idf-bootstrap/CMakeLists.txt) |
| `README.md`      | 构建/烧录/证据/边界的完整说明                                  | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/README.md)                    |

工程仍然没有 `build.zig.zon`（零依赖）、没有 `components/`、没有 `run.log`。`app_desc` 在最前面、`gp = __global_pointer$`、`flash_args` 路径锚定这三处沿用 ch04，未做改动——这是刻意的：**每章只引入本章的一个新变量**。

### 2. `main` 的执行顺序

```text
clock.init()                 // 打开 SYSTIMER（幂等）
reset.read() → info()/hint() // ROM 已判定，翻译并打印
clock.measure(200_000)       // mcycle 对 SYSTIMER
wdt.state()                  // 打印 EN/FLASHBOOT/STG0..3/HOLD
wdt.feed()                   // 正常路径：喂一次，确认写保护流程通
loop: delay 500 ms → feed → 打印 tick 与 us()
```

顺序有意义：**先读状态、再动寄存器**。如果先喂狗再打印状态，你看到的就不是 bootloader 留下的现场了——而“bootloader 留下了什么”恰恰是本章最想知道的事实之一。

### 3. 三个容易写错的地方

**（1）`main` 的符号名。** `_start` 里的 `call main` 是汇编字符串，Zig 的引用图看不见它。`src/main.zig` 必须用 `pub export fn main`，且 `start.zig` 的 `comptime` 块里要有 `_ = &app.main;`。少任何一个，链接期报 `undefined symbol: main`。

**（2）变参 printf 的类型。** ROM 的 `ets_printf` 是 C 变参函数。Zig 调用 C 变参时**不做默认实参提升**，所以每个整数都要显式 `@as(c_uint, x)`；字符串要传 `[*:0]const u8`（所以 `reset.zig` 的字段类型是 `[:0]const u8`，保证 `.ptr` 带哨兵语义）。混用 `usize`/`u64` 会在真机上打出垃圾——而且是“有时对有时错”，非常难查。

**（3）`mcycle` 的窗口。** 32 位 `mcycle` 在 80 MHz 下约 53.7 秒回绕。200 ms 窗口余量充足；若为了精度拉到 10 秒，仍要留意回绕，超过 53 秒就必须改成 `mcycleh`/`mcycle` 的 64 位读法。

---

## 5.7 验收与证据

### 1. 主机侧（不需要板子）

| 检查项                      | 命令                                                                          | 期望                                        |
| --------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------- |
| 符号进入镜像                | `riscv32-esp-elf-nm zig-out/bin/app.elf \| grep -E ' main$\| _start$'`        | 两个符号都是 `T`（代码段）                  |
| ROM 符号被解析              | `riscv32-esp-elf-nm zig-out/bin/app.elf \| grep rtc_get_reset_reason`         | 出现绝对地址 `0x2f800018`（`PROVIDE` 生效） |
| 段 #0 仍是 `esp_app_desc_t` | `od -A x -t x1z -j 32 -N 4 zig-out/bin/app.bin`                               | `32 54 cd ab`                               |
| 栈与 `.bss` 余量            | `riscv32-esp-elf-nm -n zig-out/bin/app.elf \| grep -E '_bss_end\|_stack_top'` | `_bss_end` 远小于 `_stack_top`              |
| 入口地址                    | `riscv32-esp-elf-readelf -h zig-out/bin/app.elf`                              | `Entry point` 等于 `nm` 里的 `_start`       |

### 2. 真机侧（待真机验证）

| 检查项       | 观察点                                                                                              | 状态       |
| ------------ | --------------------------------------------------------------------------------------------------- | ---------- |
| 复位原因打印 | 冷启动首行应为 `code=1 (CHIP_POWER_ON, ESP_RST_POWERON)`                                            | 待真机验证 |
| CPU 频率     | `-> CPU 80 MHz`（200 ms 窗口下 `cycles=16000012`，实测）                                            | 已实测     |
| RWDT 状态    | `en=`/`flashboot=`/`stg0..3=`/`hold=` 六个字段能打印出来                                            | 待真机验证 |
| 喂狗有效     | 连续 `tick N` 计数不中断，10 分钟无重启                                                             | 待真机验证 |
| 超时实验     | 把 `demo_timeout_ticks` 改成非 0 后应被复位；下次启动复位原因落在 `0x09`/`0x0D`/`0x10` 之一         | 待真机验证 |
| 复位键       | 按 RST 后重新打印 banner；复位原因应落在 `0x01`（上电/复位键路径）或 `0x0F`（欠压），以真机读数为准 | 待真机验证 |

超时实验的做法：把 `src/main.zig` 里的

```zig
const demo_timeout_ticks: u32 = 0;
```

改成例如 `408_000`（≈3 秒，按 RC_SLOW 136 kHz 粗算；实际只会更晚，见 5.5 节的隐含倍率），重新构建烧录。应用会打印 `DEMO: rwdt armed ...` 后停止喂狗；到点复位，串口重新出现 banner，此时 `reset reason:` 那一行就是本章最有力的证据——**它证明复位原因链路与看门狗链路同时是通的**。

> [!warning] 不要把这个实验留在长期运行的分支里
> 开着的设备会被反复复位。验完就改回 0。实验期间 `tick` 输出仍会继续（用来观察“停止喂狗之后还能活多久”），但循环里**不再调用 `wdt.feed()`**——这正是这个分支的意义。

### 3. 输出形态（2026-11-13 实测）

```text
=== ch05-clock-reset-wdt ===
reset reason: code=1 (CHIP_POWER_ON, ESP_RST_POWERON)
  meaning: 上电或复位键，属于冷启动
clock: cycles=16000012 ticks=3200030 (window 200001 us) -> CPU 80 MHz
  expect 80 on this board (IDF bootloader default); 40 means XTAL-only boot
rwdt: en=1 flashboot=0 stg0=0 stg1=0 stg2=0 stg3=0 hold=612000
tick 1 at 706683 us
tick 2 at 1206845 us
```

以上是 2026-11-13 真机原文（完整见 `../logs/ch05-boot.log`）；`hold=612000` 是 bootloader 留下的初值。

---

## 5.8 排错

| 现象                                            | 最可能的原因                                                     | 处置                                                                            |
| ----------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 链接报 `undefined symbol: rtc_get_reset_reason` | `linker/s31.ld` 里的 `PROVIDE` 没生效（脚本没被使用）            | 确认 `setLinkerScript` 指向 `linker/s31.ld`；`nm` 看是否出现 `0x2f800018`       |
| 打印的数字是垃圾/字符串错位                     | 变参类型不对（传了 `u64`/`usize` 而非 `c_uint`），或字符串没哨兵 | 逐个参数 `@as(c_uint, …)`；字符串字段用 `[:0]const u8`                          |
| `-> CPU 40 MHz`                                 | CPU 停在 XTAL 上：bootloader 切 CPLL 失败后回退                  | 看 bootloader 日志有没有 `cpu freq` 相关警告；用 `idf.py menuconfig` 查默认频率 |
| `-> CPU 0 MHz`                                  | `ticks` 没变化：SYSTIMER 没跑（`clk_en` 没置上）或快照轮询死循环 | 先单独打印 `ticks()` 两次的差值；确认 `CONF` 的写是置位而不是赋值               |
| `cycles` 明显偏小但频率“看起来对”               | 窗口内被中断切断（本章不开中断，正常不会发生）                   | 确认 `mstatus.MIE=0` 仍是 `_start` 的第一步                                     |
| 每 3 秒左右重启一次                             | 超时实验忘了改回 0，或 RWDT 由 bootloader 使能而应用没喂         | 把 `demo_timeout_ticks` 改回 0；确认 `wdt.feed()` 在循环里被执行到              |
| 喂狗“没反应”、仍然复位                          | 没解锁就写 `FEED`（写保护静默丢弃）                              | 三段式：`unlock → 写 → lock`；读回 `WPROTECT` 确认                              |
| 复位原因总是 `0x03`/`0x0C`                      | 有人在用软件复位（含 JTAG 下载后的复位）                         | 换真复位键/拔插电源；USB Serial/JTAG 侧的复位会记成 `0x16`/`0x17`               |
| `esptool` 连不上                                | 没进下载模式                                                     | 按住 BOOT（GPIO61）再按 RST，或长按 BOOT 后上电                                 |
| 串口无输出                                      | 端口/波特率错；或 bootloader 阶段就失败                          | 换 UART0（GPIO58/59）115200 8N1；先确认 ch04 的镜像能出 `hello form B`          |

---

## 5.9 下一章预告

本章把“时间”和“复位语义”握在手里，但输出仍然只有一个来路：ROM 的 `ets_printf`。它有三个硬限制——**只能写、不能读**；格式串是 ROM 的一个子集；出错时你没有任何办法知道“应用跑到哪一行就没声了”。

下一章（[[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]]）把这根管子换成自己的：

- **GPIO/IO_MUX/GPIO 矩阵**三层结构，为什么同一个引脚有三套寄存器；
- **UART** 的帧格式、波特率分频（源是 PLL_F80M，不是 APB）、FIFO 阈值与中断；
- **环形缓冲 + 中断收发**，写一个能回显的串口 shell；
- **分级日志**与 **panic handler**：把 `mcause`/`mepc`/`ra` 与栈回溯打出来，让“无声崩溃”变成可读的一屏；
- **WS2812/RMT 的边界**：GPIO60 上的可寻址 RGB LED 为什么不能用普通 GPIO 翻转驱动，RMT 留到什么时候做。

那一章之后，本系列的调试能力才真正脱离“猜”。

---

## 事实来源

| 事实                                                                                          | 来源                                                                                                                                                                                                                                                                      | 备注                                                           |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| S31 双核 RV32IMAF C、320 MHz、40 MHz XTAL、512 KB SRAM                                        | [Espressif ESP32-S31 产品页](https://www.espressif.com/en/products/socs/esp32-s31)                                                                                                                                                                                        | 与系列索引一致                                                 |
| 时钟树：CPLL 320 MHz（CPU/MSPI）、BBPLL 480 MHz 及其派生、MPLL、APLL                          | [IDF v6.1 `esp32s31/clk_tree_defs.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/clk_tree_defs.h)                                                                                                                                 | 文件头注释逐条给出 PLL 用途                                    |
| `RC_FAST ≈ 17.5 MHz`、`RC_SLOW ≈ 136 kHz`、`XTAL32K = 32768`                                  | 同上（`SOC_CLK_RC_FAST_FREQ_APPROX` / `SOC_CLK_RC_SLOW_FREQ_APPROX` / `SOC_CLK_XTAL32K_FREQ_APPROX`）                                                                                                                                                                     | “APPROX” 即未校准值                                            |
| CPU 时钟源：XTAL=0、CPLL=1、PLL_F240M=3                                                       | 同上（`soc_cpu_clk_src_t`）                                                                                                                                                                                                                                               | 打印里“40 MHz 说明停在 XTAL”的依据                             |
| `APB_CLK_FREQ = 40 MHz`                                                                       | [IDF v6.1 `esp32s31/soc.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/soc.h)                                                                                                                                                     | APB 总线时钟宏                                                 |
| SYSTIMER 源固定 XTAL 40 MHz、固定 2.5 分频、节拍 16 MHz                                       | [IDF v6.1 `port/esp32s31/systimer.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hw_support/port/esp32s31/systimer.c)                                                                                                                                  | `systimer_ticks_to_us` 用 `/16`                                |
| SYSTIMER 基址 `0x20399000`，`CONF`/`UNIT0_OP`/`VALUE_HI`/`VALUE_LO` 偏移                      | [IDF v6.1 `soc/esp32s31/register/soc/reg_base.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/reg_base.h)、[`systimer_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/systimer_reg.h) | `clk_en` = bit31、unit0 使能 = bit30                           |
| 快照协议：写 update、等 valid、读 LO/HI/LO 比对                                               | [IDF v6.1 `esp_hal_systimer/systimer_hal.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_systimer/systimer_hal.c)                                                                                                                                   | `systimer_hal_get_counter_value`                               |
| SYSTIMER 时钟门/源选择寄存器 `HP_SYS_CLKRST_SYSTIMER_CTRL0`（`+0x120`）                       | [IDF v6.1 `hp_sys_clkrst_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h)                                                                                                                                 | 本章不用；留作 ch08 参考                                       |
| `rtc_get_reset_reason = 0x2f800018`                                                           | [IDF v6.1 `esp32s31.rom.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.ld)                                                                                                                                               | 链接脚本 `PROVIDE` 的来源                                      |
| `esp_rom_get_reset_reason` 是它的别名                                                         | [IDF v6.1 `esp32s31.rom.api.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.api.ld)                                                                                                                                       | `PROVIDE ( esp_rom_get_reset_reason = rtc_get_reset_reason );` |
| 复位原因编码表 `0x01..0x1A`                                                                   | [IDF v6.1 `soc/reset_reasons.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/reset_reasons.h)                                                                                                                                      | `reset.zig` 的表逐行对应                                       |
| 编码 → `esp_reset_reason_t` 的归类，以及 hint 机制                                            | [IDF v6.1 `port/esp32s31/reset_reason.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_system/port/soc/esp32s31/reset_reason.c)                                                                                                                          | hint 存在 `LP_STORE6`                                          |
| `RESET_REASON rtc_get_reset_reason(int cpu_no)` 原型                                          | [IDF v6.1 `esp32s31/rom/rtc.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/include/esp32s31/rom/rtc.h)                                                                                                                                    | 参数是 CPU 号，返回枚举                                        |
| RWDT 基址 `0x20801000`、`CONFIG0..4`/`FEED`/`WPROTECT` 偏移与位域                             | [IDF v6.1 `rtc_wdt_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/rtc_wdt_reg.h)                                                                                                                                             | `FEED` bit31、`EN` bit31、`STG0[30:28]`                        |
| RWDT 写保护密钥 `0x50D83AA1`、阶段动作编码、STG0 隐含倍率                                     | [IDF v6.1 `esp32s31/hal/rwdt_ll.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_wdt/esp32s31/include/hal/rwdt_ll.h)                                                                                                                                 | `RTC_WDT_WKEY_VALUE`、`RTC_WDT_STG_SEL_*`                      |
| MWDT：基址 `0x20580000`、`WDTCONFIG0/1`、`WDTFEED`（写任意值）、`WDTWPROTECT`、只允许 XTAL 源 | [IDF v6.1 `timer_group_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/timer_group_reg.h)、[`esp32s31/hal/mwdt_ll.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_hal_wdt/esp32s31/include/hal/mwdt_ll.h)   | `STG0[30:29]`、`EN` bit31                                      |
| MWDT 的时钟门 `HP_SYS_CLKRST_TIMERGRP0_CTRL0`（`+0x114`，bit11，默认 1）                      | [IDF v6.1 `hp_sys_clkrst_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h)                                                                                                                                 | 默认已开，本章不写                                             |
| task WDT 用 STAGE0=`INT`、STAGE1=`RESET_SYSTEM`（2 倍超时）                                   | [IDF v6.1 `task_wdt_impl_timergroup.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_system/task_wdt/task_wdt_impl_timergroup.c)                                                                                                                         | “先警告后复位”这种配法的出处                                   |
| SWD 寄存器 `SWD_CONFIG`(`+0x1c`)/`SWD_WPROTECT`(`+0x20`)                                      | [IDF v6.1 `rtc_wdt_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/rtc_wdt_reg.h)                                                                                                                                             | `SWD_DISABLE` bit30、`SWD_FEED` bit31                          |
| `mcycle`（0xB00）/`mcycleh`（0xB80）语义与 RV32 分段                                          | [RISC-V Privileged Spec](https://github.com/riscv/riscv-isa-manual/releases)                                                                                                                                                                                              | 32 位回绕周期由此推算                                          |
| ROM `ets_printf = 0x2f800024`、`ets_delay_us = 0x2f80003c`                                    | [IDF v6.1 `esp32s31.rom.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.ld)                                                                                                                                               | 与 ch04 一致                                                   |
| `Zig` 的 `asm` 表达式输出写法 `-> T`                                                          | [Zig 0.17 语言参考（inline assembly）](https://ziglang.org/documentation/0.17.1/)                                                                                                                                                                                         | `csrr` 读 mcycle 的写法依据                                    |
| `esp32s31` 是 IDF v6.1 preview target                                                         | [[ch11-esp32s31-lab-plan\|ONVIF 第十一章]]、`practice/onvif-labs/SPEC.md`                                                                                                                                                                                                 | `set-target`/`build` 需 `--preview`                            |

## 自查清单

进入下一章前，确认能回答这些问题：

- [ ] 为什么本章**不**写 PLL 寄存器？“先测后配”在工程上换来的是什么？
- [ ] “CPU 320 MHz”这句话的完整链路是哪三步？本板实测 80 MHz 时 `SOC_CPU_CLK_SRC_*` 停在哪一档？
- [ ] SYSTIMER 的节拍是多少 MHz？这个数字为什么“不需要读配置就知道”？
- [ ] 读 64 位 SYSTIMER 为什么不能直接“先高后低”？IDF 的三步协议解决了什么？
- [ ] 用 `ets_delay_us` 当基准去测 CPU 频率，为什么逻辑上是自证？
- [ ] 32 位 `mcycle` 在 80 MHz 下多久回绕？200 ms 与 10 秒窗口各自的余量是多少？
- [ ] 复位原因是谁判定的？为什么应用不可能自己判断上电复位？
- [ ] `0x07`、`0x0B`、`0x0D` 分别是什么？它们在 IDF 里被归到哪些 `ESP_RST_*`？
- [ ] RWDT 的写保护不解锁会发生什么？为什么不报错？
- [ ] RWDT 的四个阶段是什么关系？`INT` 动作之后为什么还会继续计时？
- [ ] RWDT 的 STG0 为什么有“隐含倍率”？它对“精确到秒”的超时意味着什么？
- [ ] task WDT 与 interrupt WDT 各用哪只硬件狗？依据是哪一行归类代码？
- [ ] 串口输出用的是谁？它会不会因为 CPU 频率改变而乱码？
- [ ] 为什么 `main` 必须先读 RWDT 状态、再喂狗？顺序反了会看不到什么？

---

本章的产出不是“灯亮了”，而是三行**可复现的数字**：复位原因的编码、CPU 的 MHz、RWDT 的六个状态字段。下一章把这根只有单向、只有 ROM 格式串的管子，换成自己的 UART、分级日志与能打印 `mcause`/`mepc` 的 panic handler——从那时起，调试不再靠猜。

系列导航：[[ch04-linker-memory-layout|上一章]] · [[zig-esp32-s31|系列索引]]
