---
title: "嵌入式硬件基础（五）：GPIO 与时钟树——从使能到点灯的完整链路"
date: 2026-08-30 09:00:00
description: "外设操作的第一行代码永远是开时钟——从 RCC 的门控模型、HSE/HSI/PLL 三源到 168MHz 主频的时钟树路径，到 RM0090 GPIO 寄存器族（MODER/OTYPER/OSPEEDR/PUPDR/IDR/ODR/BSRR/AFR）逐个解剖，给出'使能→配模式→写数据'的点灯三步与 CMSIS 风格/裸地址两种写法的反汇编对照；QEMU 侧无 F407 模型，用源码考证 MPS2 FPGAIO（0x40028000）跑等价点灯/读键逻辑，并用 -d unimp 探针实证'cmsdk-ahb-gpio'只是占位设备——模型映射方法论正是无板先行的核心技能。"
tags: [embedded, stm32, cortex-m, gpio, rcc, qemu]
---

> [!info] 嵌入式硬件基础系列 0. [[2026-08-30-embedded-basics-series-index|系列索引]] · 4. [[2026-08-30-embedded-basics-ch04-baremetal-boot|上一章：裸机启动]] · 5. **第五章：GPIO 与时钟树** · 6. [[2026-08-30-embedded-basics-ch06-uart-protocol|下一章：UART 协议]]

# 嵌入式硬件基础（五）：GPIO 与时钟树——从使能到点灯的完整链路

[[2026-08-30-embedded-basics-ch04-baremetal-boot|第四章]] 造好了启动链，QEMU 里打出了 `hello baremetal`——但那只是 CPU 在自说自话。这一章让芯片第一次和外部世界握手：**控制一个引脚的电平，读一个引脚的状态**。同时在 [[2026-08-30-embedded-basics-ch02-tools-multimeter-la|第二章]] 的万用表清单里埋过一句话："把 PA0 配成推挽输出高，测得 ≈3.3V"——当时跳过的"配成"两个字，本章全部兑现。

但在碰 GPIO 之前必须先回答一个更根本的问题：**为什么外设操作的第一行代码永远是开时钟？** 这不是仪式，是 CMOS 数字电路的物理事实。本章路线：时钟树（为什么、在哪开、开多快）→ GPIO 寄存器族逐个解剖（RM0090）→ F407 真寄存器点灯全链路（编译验证）→ QEMU 等价实验（模型考证 + 实跑）→ 真机占位。

工程位于 `practice/hwbasics/ch05-gpio-clock/`，基于 ch04 模板，双目标构建。所有编译/运行输出均来自真实执行（`arm-none-eabi-gcc 15.2.0`、`qemu-system-arm 10.1.5`）。

---

## 5.1 时钟树先行：时钟是外设的生命线

### 1. 为什么复位后"寄存器写不进去"

数字外设的本质是一大坨触发器和组合逻辑，触发器没有时钟沿就不翻转——**没有时钟的外设不是"慢"，是死的**。所以 STM32 复位后为了省电，把几乎所有外设的时钟关掉（时钟门控，clock gating）：寄存器位都还在地址空间里，但写入被直接丢弃，读出往往是 0 或复位值。新手"明明照抄了寄存器地址，GPIO 就是没反应"的第一大原因就是这个。

RCC（Reset and Clock Control）就是这扇门的总闸。它的组织方式和总线架构同构：每条总线一个使能寄存器，F407 上 GPIO 挂在 **AHB1**，所以门在 `RCC_AHB1ENR`（RM0090 §5.3 RCC 寄存器）：

| 寄存器（RM0090 §5.3） | 地址          | 管什么                                                  |
| --------------------- | ------------- | ------------------------------------------------------- |
| `RCC_AHB1ENR`         | `0x4002_3830` | AHB1 外设时钟：GPIOA..H（bit0..7）、DMA、CRC…           |
| `RCC_APB1ENR`         | `0x4002_3840` | APB1 外设时钟：USART2/3、TIM2..7、I2C、PWR…（42MHz 域） |
| `RCC_APB2ENR`         | `0x4002_3844` | APB2 外设时钟：USART1、SPI1、TIM1/8…（84MHz 域）        |

RCC 基址 `0x4002_3800`（RM0090 §2.3 内存映射）。**点灯第一行代码**就是：

```c
RCC->AHB1ENR |= (1UL << 0);   /* GPIOAEN：给 GPIOA 送时钟 */
```

两个细节值得养成习惯：

- **先开时钟，再碰寄存器**——顺序反了，配置全部无效。这和 [[2026-08-30-embedded-basics-ch04-baremetal-boot|第四章]] UART 的 "TX_EN 先使能" 是同一条外设交互铁律的另一个面；
- **使能后读回一次**（`(void)RCC->AHB1ENR;`）：写缓冲和流水线可能让后续访问"跑"到时钟真正生效之前，读回是保守同步手段，各厂商例程的通行写法。

### 2. 时钟树全景：从 8MHz 晶体到 168MHz 主频

时钟从哪来、多快？F407 的三源选择（RM0090 §5.2 Clocks）：

| 时钟源  | 频率            | 说明                                        |
| ------- | --------------- | ------------------------------------------- |
| HSI     | 16 MHz          | 内部 RC 振荡器，复位默认就是它，精度差(±1%) |
| HSE     | 8 MHz(典型)     | 外部晶体，精确；频率以板子原理图为准        |
| PLL     | 倍频到 VCO      | 把 HSE/HSI 加工成高频系统时钟               |
| LSE/LSI | 32.768kHz/32kHz | RTC 与独立看门狗的低速旁路域（本篇不用）    |

复位后 CPU 跑在 HSI 16MHz——这就是"没配时钟也能点灯"的原因（点灯不需要 168MHz）。要上主频，标准路径是 HSE → PLL（分频/倍频参数在 `RCC_PLLCFGR`，选择切换在 `RCC_CFGR` 的 SW/SWS 位）。WeAct F407 板载晶振常见 8MHz，168MHz 满频配置是所有 F407 教程的公约数：

```text
  HSE 8 MHz(晶振)──┐
  HSI 16 MHz(默认)─┴→  /PLLM = 1 MHz ──×PLLN → VCO 336 MHz
                                            ├─ /PLLP(=2) → SYSCLK 168 MHz
                                            │      ├─ /AHB(=1)  → HCLK  168 MHz (CPU/GPIO/DMA)
                                            │      ├─ /APB1(=4) → PCLK1  42 MHz (定时器时钟 ×2 = 84 MHz)
                                            │      └─ /APB2(=2) → PCLK2  84 MHz (定时器时钟 ×2 = 168 MHz)
                                            └─ /PLLQ(=7) → 48 MHz (USB OTG FS / SDIO)
```

三个要点：

- **GPIO 挂在 AHB1 上，吃 HCLK 168MHz**——F4 把 GPIO 从 F1 的 APB2（≤72MHz）挪到了 AHB1，引脚翻转速率上限随之大涨，这是 F4 "快速 IO" 卖点的来源，也解释了门控寄存器为什么是 `AHB1ENR`；
- **APB 定时器倍频规则**：APB 预分频不是 1 时，挂在它上面的定时器时钟 = PCLK×2（RM0090 §5.2 时钟树图）——[[2026-08-30-embedded-basics-ch08-timer-systick|第八章]] 算定时器分频时直接用这条；
- 上 168MHz 还要同步配 Flash 等待周期（168MHz@3.3V → 5 WS，RM0090 第 3 章 Flash 等待周期表），否则取指跟不上。本章点灯不碰 PLL，保持复位默认 HSI 16MHz 即可。

> [!tip] 对照预告：GD32 的 RCU（ch09 伏笔）
> GD32VF103 把同样的门控逻辑叫 **RCU**（Reset and Clock Unit），GPIO 时钟使能在 `RCU_AHBEN`（位名 PAEN/GPEN），对应这里的 `RCC_AHB1ENR`/GPIOAEN。寄存器换了名字、换了总线组织，"外设先开时钟"这条物理规律不变。[[2026-08-30-embedded-basics-ch09-riscv-gd32-contrast|第九章]] 在 RISC-V 侧重做本章实验时会看到完整对照。

---

## 5.2 GPIO 寄存器族解剖：一张路由表 + 一组属性位

RM0090 §8.4 定义了 GPIO 的寄存器族。每个 GPIO 端口（GPIOA..H，各 16 引脚）一组，GPIOA 基址 `0x4002_0000`（§2.3），端口间距 0x400：

| 偏移    | 寄存器      | 位宽/引脚    | 职责                                        |
| ------- | ----------- | ------------ | ------------------------------------------- |
| `+0x00` | `MODER`     | 2 bit        | 模式：00 输入 / 01 输出 / 10 复用 / 11 模拟 |
| `+0x04` | `OTYPER`    | 1 bit        | 输出类型：0 推挽 / 1 开漏                   |
| `+0x08` | `OSPEEDR`   | 2 bit        | 输出速度：00 低 / 01 中 / 10 高 / 11 极高   |
| `+0x0C` | `PUPDR`     | 2 bit        | 上下拉：00 无 / 01 上拉 / 10 下拉           |
| `+0x10` | `IDR`       | 1 bit(只读)  | 输入数据：引脚实际电平                      |
| `+0x14` | `ODR`       | 1 bit        | 输出数据                                    |
| `+0x18` | `BSRR`      | 2×16 bit(写) | 原子置位/复位：低 16 位置 1，高 16 位清 0   |
| `+0x1C` | `LCKR`      | —            | 配置锁定（误配保护，本篇不用）              |
| `+0x20` | `AFRL/AFRH` | 4 bit        | 复用功能选择 AF0..AF15（引脚 0-7 / 8-15）   |
| `+0x28` | `BRR`       | 16 bit(写)   | 仅复位（BSRR 高 16 位的独立镜像）           |

对比 F1 时代的 `CRL/CRH`（模式+速度挤在一个寄存器），F4 的拆分是"每关注点一个寄存器"：**模式、输出结构、速度、上下拉、数据**互相正交，配置时不用在脑内拼位图。逐个看：

### 1. MODER：一个引脚的四种人生

- **输入（00）**：输出驱动器断开，引脚只进不出。复位默认，最安全；
- **输出（01）**：ODR/BSRR 驱动引脚电平——点灯用这个；
- **复用（10）**：引脚交给片上外设（UART、SPI、定时器…），电平由外设决定——CPU 写 ODR 无效。**"配了 GPIO 却不出波形"的经典坑就是 MODER 配了输出而没配复用**；
- **模拟（11）**：数字输入缓冲器也断开（施密特触发器关闭），给 ADC/DAC 用。省电且防模拟电平在阈值附近抖动产生毛刺中断。

注意复位值不是全 0：GPIOA 的 PA13/PA14 复位即复用模式——它们是 SWD 调试口（SWDIO/SWCLK，AF0），[[2026-08-30-embedded-basics-ch11-debug-swd-jtag|第十一章]] 再展开。**随手把 PA13/PA14 改成输出会当场失去调试连接**，真机排障名场面。

### 2. OTYPER：推挽与开漏（回收第二章）

[[2026-08-30-embedded-basics-ch02-tools-multimeter-la|第二章]] 万用表实验的"推挽输出高 ≈3.3V"就是这里 bit=0 的形态：

- **推挽（0）**：高电平由上管接 VDD 驱动、低电平由下管接 GND 驱动，两个方向都是"硬"驱动——驱动 LED、SPI 这类点对点信号；
- **开漏（1）**：只有下管，高电平靠外部上拉电阻"拉"上去。芯片只能把线拉低或松手——I²C 总线（线与、多主机仲裁）、电平转换（上拉到 5V 得 5V 逻辑）全靠它。开漏时读 IDR 读到的是**线上实际电平**，不是你想输出的电平，I²C 用这个特性检测时钟拉伸。

### 3. OSPEEDR 与 PUPDR：属性位

OSPEEDR 控输出边沿斜率（压摆率），不是"引脚上的时钟频率"。高速档边沿陡、能跑高波特率，但过冲和 EMI 也大——**引脚速度按需配置**是 EMC 基本功，LED 点灯用低速完全够。PUPDR 决定引脚悬空时的归宿（见 5.4）。复位后 PUPDR=00 无上下拉，此时引脚悬空就是"天线"。

### 4. IDR/ODR 与 BSRR：为什么"位设置/复位"是中断安全的写法

输出路径：CPU → ODR（每引脚 1 bit）→ 输出驱动器。输入路径：引脚 → 输入缓冲器 → IDR。看起来用 `ODR` 读写就够了，但 **`ODR ^= bit` 是读-改-写三条指令**，F407 目标的反汇编（真实编译产物）：

```text
08000158 <led_toggle_odr>:
 800015a:  6953       ldr  r3, [r2, #20]     ← 读 ODR（+0x14）
 800015c:  f083 0301  eor.w r3, r3, #1      ← 改
 8000160:  6153       str  r3, [r2, #20]     ← 写回 ODR
```

三条指令之间可以插入中断。设主循环翻转 bit0、中断里翻转 bit1，两个都写 ODR：

```text
main: ldr ODR      → 读到 0x0000（bit0=0, bit1=0）
  ── IRQ 打断 ──   ldr ODR(0x0000); eor(0x0002); str ODR=0x0002   ← 中断点亮 bit1
main: eor(0x0001)  → 基于旧值 0x0000 算出 0x0001
main: str ODR=0x0001                                    ← bit1 的更新被覆盖，中断白干
```

这就是**丢失更新**（lost update），和数据库并发写一个字段一模一样。`BSRR`（bit set/reset register）为它而生：**一次写操作，硬件直接置位/清零目标位**——写低 16 位的 BSx 把对应 ODR 位置 1，写高 16 位的 BRx 清 0（两者同时写时 BS 优先，RM0090 §8.4）。各管各的 bit field，天然无竞态：

```c
GPIOA->BSRR = 1UL << 0;      /* 置位 PA0 —— 单写，不可分割 */
GPIOA->BSRR = 1UL << 16;     /* 复位 PA0 —— 单写 */
```

对应的反汇编（同样来自真实编译产物）——**点一个灯只要"取址 + 置立即数 + 存"三条指令，对 ODR 的读-改-写根本不存在**：

```text
0800013c <led_on>:
 800013c:  4b01       ldr  r3, [pc, #4]      ← literal pool: 0x40020000 (GPIOA)
 800013e:  2201       movs r2, #1            ← BS0 = 1
 8000140:  619a       str  r2, [r3, #24]     ← 写 BSRR（+0x18），完事

08000148 <led_off>:
 800014a:  f44f 3280  mov.w r2, #65536       ← BR0（bit16）= 1
 800014e:  619a       str  r2, [r3, #24]
```

这是嵌入式 C 的基本功：**共享状态的更新要么原子指令、要么关中断、要么换"写即生效"的寄存器接口**。[[2026-08-30-embedded-basics-ch07-interrupts-nvic|第七章]] 进中断后会拿这个例子当回放素材。

### 5. AFR：引脚与外设的路由表

一个物理引脚（如 PA2）背后最多 16 个复用功能（AF0..AF15），AFR 每 4 bit 选一个。它是一张**路由表**：MODER=10（复用）只说"这个引脚交给外设"，AFR 的数值才说"交给哪个"。PA2 的 AF7 是 USART2_TX、PA3 的 AF7 是 USART2_RX（RM0090 §8.3 的 AF 映射表）——5.5 节预演，[[2026-08-30-embedded-basics-ch06-uart-protocol|第六章]] 实战。

---

## 5.3 点灯全链路：使能 → 配模式 → 写数据（F407 真寄存器）

完整链路三步，每步一个寄存器：`RCC_AHB1ENR`（开门）→ `MODER`（选输出模式）→ `BSRR`（写数据）。工程 `f407_gpio.c` 用 **CMSIS 风格结构体**实现（与官方 `stm32f4xx.h` 同构，零依赖手写）：

```c
typedef struct {
    volatile uint32_t MODER;   /* +0x00 模式：2bit/引脚 */
    volatile uint32_t OTYPER;  /* +0x04 输出类型：1bit/引脚 */
    volatile uint32_t OSPEEDR; /* +0x08 输出速度：2bit/引脚 */
    volatile uint32_t PUPDR;   /* +0x0C 上拉/下拉：2bit/引脚 */
    volatile uint32_t IDR;     /* +0x10 输入数据（只读） */
    volatile uint32_t ODR;     /* +0x14 输出数据 */
    volatile uint32_t BSRR;    /* +0x18 原子置位/复位 */
    volatile uint32_t LCKR;    /* +0x1C 配置锁定 */
    volatile uint32_t AFR[2];  /* +0x20/+0x24 复用功能选择 */
    volatile uint32_t BRR;     /* +0x28 仅复位 */
} GPIO_TypeDef;

typedef struct {
    volatile uint32_t CR;       /* +0x00 HSI/HSE/PLL 使能与就绪 */
    volatile uint32_t PLLCFGR;  /* +0x04 PLL 参数 */
    volatile uint32_t CFGR;     /* +0x08 时钟切换/分频 */
    volatile uint32_t _r0;      /* +0x0C 保留 */
    volatile uint32_t AHB1RSTR; /* +0x10 ..APB2RSTR +0x24 外设复位 */
    volatile uint32_t AHB2RSTR; /* +0x14 */
    volatile uint32_t AHB3RSTR; /* +0x18 */
    volatile uint32_t _r1;      /* +0x1C 保留 */
    volatile uint32_t APB1RSTR; /* +0x20 */
    volatile uint32_t APB2RSTR; /* +0x24 */
    volatile uint32_t _r2;      /* +0x28 保留 */
    volatile uint32_t _r3;      /* +0x2C 保留（连续两个，见下方排障） */
    volatile uint32_t AHB1ENR;  /* +0x30 AHB1 时钟使能 */
} RCC_TypeDef;

#define GPIOA ((GPIO_TypeDef *)0x40020000UL)
#define RCC   ((RCC_TypeDef *)0x40023800UL)

static void led_init(void)
{
    RCC->AHB1ENR |= 1UL << 0;              /* ① GPIOAEN：开 GPIOA 时钟 */
    (void)RCC->AHB1ENR;                    /*    读回同步 */

    GPIOA->MODER = (GPIOA->MODER & ~(3UL << 0)) | (1UL << 0); /* ② PA0=01 输出 */
    GPIOA->OTYPER &= ~(1UL << 0);          /* ③ 推挽 */
    GPIOA->OSPEEDR |= 3UL << 0;            /* ④ 极高速（LED 场景随意） */
    GPIOA->PUPDR &= ~(3UL << 0);           /* ⑤ 无上下拉（推挽自驱动） */
}

static void led_on(void)  { GPIOA->BSRR = 1UL << 0;  } /* ⑥ 点亮 */
static void led_off(void) { GPIOA->BSRR = 1UL << 16; } /* ⑦ 熄灭 */
```

另一种是**裸地址风格**——不定义结构体，宏即寄存器：

```c
#define GPIOA_MODER (*(volatile uint32_t *)(0x40020000UL + 0x00))
#define GPIOA_BSRR  (*(volatile uint32_t *)(0x40020000UL + 0x18))
#define RCC_AHB1ENR (*(volatile uint32_t *)(0x40023800UL + 0x30))

static void led_on_addr(void)
{
    GPIOA_BSRR = 1UL << 0;   /* 与 led_on() 生成完全相同的机器码 */
}
```

两种写法**没有优劣**：结构体把偏移关系编码进类型（RCC 基址只写一次），裸地址把"这个寄存器在哪"写在脸上。ch04 的 UART 用的就是裸地址风格。选哪种是团队口味，但写错哪种都会在反汇编里现形——正好，编译验证环节就抓到一个真 bug。

### 编译验证与一次真实的排障

QEMU 没有 F407 机型（下一节考证），所以 F407 目标的验证层次是：**交叉编译链接通过 + 反汇编核对寄存器地址**（SPEC 的验证纪律层次 b）。构建（Makefile 双目标，同一份 startup.S 以 `-mcpu=cortex-m3`/`cortex-m4` 分别汇编）：

```text
$ make
   text	   data	    bss	    dec	    hex	filename
   1060	      0	      0	   1060	    424	build/ch05-gpio-qemu.elf
    600	      0	      0	    600	    258	build/ch05-gpio-f407.elf
```

反汇编 `led_init`（真实输出，节选）：

```text
08000100 <led_init>:
 8000100:  4b0c       ldr  r3, [pc, #48]     ← literal: 0x40023800 (RCC)
 8000102:  6b1a       ldr  r2, [r3, #48]     ← 读 AHB1ENR（+0x30）
 8000104:  f042 0201  orr.w r2, r2, #1       ← GPIOAEN
 8000108:  631a       str  r2, [r3, #48]     ← 写回
 800010a:  6b1b       ldr  r3, [r3, #48]     ← 读回同步
 800010c:  4b0a       ldr  r3, [pc, #40]     ← literal: 0x40020000 (GPIOA)
 800010e:  681a       ldr  r2, [r3, #0]      ← 读 MODER
 ...
 8000134:  40023800  .word 0x40023800
 8000138:  40020000  .word 0x40020000
```

初版的这段反汇编里，AHB1ENR 的访问是 `ldr r2, [r3, #44]`——**0x2C，不是 0x30**。原因：RCC 寄存器映射里 APB2RSTR（0x24）与 AHB1ENR（0x30）之间有**两个**连续保留字（0x28、0x2C），我的结构体只写了一个 `_r2`，后面所有成员整体错位 4 字节——时钟开的是 0x4002382C，一个保留地址。CMSIS 头文件里 `RESERVED2`、`RESERVED3` 双保留不是装饰。修正后回到 `[r3, #48]`。这就是结构体映射法的暗坑：**编译器不会校验你的偏移，反汇编会**。手写寄存器结构体的工程，把 objdump 摘录当提交前检查项。

---

## 5.4 输入与上拉下拉：读一个按键

输出讲完了，输入是镜像问题：引脚电平 → IDR。悬空输入引脚的电平由静电决定（漂移的"天线"），所以输入必须有确定的默认电平——**上拉/下拉**二选一（PUPDR），或外部电阻。最省料的按键电路：按键一端接引脚、一端接 GND，引脚配内部上拉——**空闲 1，按下 0**，"低有效"由此而来：

```c
static void button_init(void)
{
    GPIOA->MODER &= ~(3UL << 2);                        /* PA1 = 00 输入 */
    GPIOA->PUPDR = (GPIOA->PUPDR & ~(3UL << 2)) | (1UL << 2); /* 01 上拉 */
}

static int button_pressed(void)
{
    return (GPIOA->IDR & (1UL << 1)) == 0;              /* 读 IDR，0 = 按下 */
}
```

`button_pressed` 的反汇编干净得像教材——`ubfx` 位域提取 + `eor #1` 取反，IDR 的 +0x10 偏移清晰可见（真实输出）：

```text
08000184 <button_pressed>:
 8000186:  6918       ldr  r0, [r3, #16]     ← 读 IDR（+0x10）
 8000188:  f3c0 0040  ubfx r0, r0, #1, #1    ← 抽取 bit1
 800018c:  f080 0001  eor.w r0, r0, #1       ← 取反：0 → 1（按下）
```

机械按键的抖动（接触弹跳，毫秒级电平跳变）本章先不管——轮询读 IDR 只会看到抖动期间电平乱跳；硬件 RC 滤波、软件消抖/状态机是 [[2026-08-30-embedded-basics-ch07-interrupts-nvic|第七章]] EXTI 中断实验的正菜。真机接线与预期现象见 5.7。

---

## 5.5 AFR 实战预演：把 PA2/PA3 交给 USART2（ch06 伏笔）

复用配置三件套：**MODER=复用 + AFR=编号 + 速度**。PA2/PA3 配 USART2（AF7）：

```c
static void uart2_pins_init(void)
{
    GPIOA->MODER = (GPIOA->MODER & ~(3UL << 4 | 3UL << 6)) /* PA2/PA3 清模式 */
                   | (2UL << 4) | (2UL << 6);               /* 10 = 复用 */
    GPIOA->AFR[0] = (GPIOA->AFR[0] & ~(0xFUL << 8 | 0xFUL << 12))
                    | (7UL << 8) | (7UL << 12);             /* nibble2/3 = AF7 */
    GPIOA->OSPEEDR |= 3UL << 4 | 3UL << 6;                  /* 高速 */
}
```

反汇编（真实输出）里 AFR 的位操作肉眼可查——清 `0xff00`、置 `0x7700`，正是 nibble2/3 写 7：

```text
080001a6:  6a1a       ldr  r2, [r3, #32]     ← 读 AFR[0]（+0x20）
080001a8:  f422 427f  bic.w r2, r2, #65280   ← 清 nibble2/3（0xff00）
080001ac:  f442 42ee  orr.w r2, r2, #30464   ← 写 0x7700（AF7<<8 | AF7<<12）
080001b0:  621a       str  r2, [r3, #32]
```

第六章的 UART 只剩外设侧没讲：`RCC_APB1ENR` 开 USART2 时钟、波特率寄存器、状态位轮询。引脚这条腿已经迈出去了。

---

## 5.6 QEMU 实证：没有 F407 模型的世界里怎么验证

SPEC 验证纪律的诚实前提：**mps2-an385 是 Cortex-M3 通用机型，没有 F407 的 GPIO 模型**。本章策略是"两条腿"：F407 代码做编译验证（上三节），QEMU 侧找**同一抽象层次**的等价逻辑实跑。而"QEMU 机上到底有什么模型"本身就是必须考证的事——这一节的方法论比实验结果更值钱。

### 1. 模型考证：名字像模型的未必是模型

翻 QEMU v10.1 源码 `hw/arm/mps2.c` 的 FPGA_AN385 分支，与本章相关的三块：

| mps2-an385 上的资源      | 地址                         | QEMU 实现                                     |
| ------------------------ | ---------------------------- | --------------------------------------------- |
| `cmsdk-ahb-gpio`（4 个） | `0x4001_0000`..`0x4001_3000` | **占位设备**（`create_unimplemented_device`） |
| MPS2 FPGAIO              | `0x4002_8000`                | 真模型（`hw/misc/mps2-fpgaio.c`）             |
| CMSDK APB UART0..4       | `0x4000_4000`..              | 真模型（ch04 已用）                           |

两个关键发现：

- 名字里带 "gpio" 的 `cmsdk-ahb-gpio` 是**占位设备**：QEMU 只在内存映射表里登记了这段地址（对应真实 AN385 板的地址图），读写行为是"吞写、读返 0、打日志"——不是模型。仿真器照抄地址图但不实现全部设备时，这是通行做法；
- 真正能"点灯"的是 **FPGAIO**——MPS2 板上 FPGA 的一块杂项 IO（LED/按键/计数器）。寄存器表（`hw/misc/mps2-fpgaio.c`，REG32 宏逐个核对）：

| 偏移    | 寄存器   | 行为                                      |
| ------- | -------- | ----------------------------------------- |
| `+0x00` | LED0     | 读写；bit_i = 用户 LED_i（`num-leds=2`）  |
| `+0x08` | BUTTON   | 只读恒 0——源码注释明说"不仿真用户按键"    |
| `+0x10` | CLK1HZ   | 只读，1Hz 自由计数器（QEMU 虚拟时钟驱动） |
| `+0x14` | CLK100HZ | 只读，100Hz 自由计数器                    |
| `+0x28` | SWITCH   | 只读恒 0（拨码开关同样不仿真）            |

### 2. 映射：F407 概念 → FPGAIO 概念

无板先行不是"在 QEMU 上跑 F407 代码"，而是**把同一套操作语义映射到 QEMU 真有的模型上**：

| F407（真机语义）           | mps2-an385（QEMU 语义）                                |
| -------------------------- | ------------------------------------------------------ |
| `RCC_AHB1ENR` 开 GPIO 时钟 | 无对应——FPGAIO 恒在总线时钟域（模型不实现门控）        |
| `MODER` 选输出模式         | 无对应——LED0 寄存器专职专用，无模式选择                |
| `BSRR` 写 1 点亮           | `LED0 = 1`（同样"写即生效"，读回可验证）               |
| `IDR` 读按键               | `BUTTON` 读（恒 0，模型边界）；`CLK100HZ` 读（真变化） |
| `OTYPER/OSPEEDR/PUPDR`     | 无对应——模型无电气层                                   |

映射表右列的"无对应"正是教学价值：它标出了仿真器的抽象边界——**QEMU 验证的是寄存器交互逻辑（编程模型），电气属性（推挽强度、边沿斜率、上下拉）永远属于真机**。

### 3. 实跑：等价点灯/读键（qemu_main.c）

固件逻辑（`qemu_main.c`，UART 打印沿用 ch04）：LED0 写 0/写 1 并读回 → 闪 5 次 → 读 BUTTON → 间隔读两次 CLK100HZ → 往占位设备 0x40010000 写值再读回。真实运行输出（`make run-log`，`-d guest_errors,unimp`）：

```text
$ make run-log
ch05 gpio on qemu mps2-an385 (fpgaio 0x40028000)
[1] LED0 <- 0x0        readback 0x00000000
[1] LED0 <- 0x1        readback 0x00000001
[2] blink x5 ..... done (final LED0=0x00000000)
[3] BUTTON readback   0x00000000 (QEMU 不仿真按键, 恒 0)
[4] CLK100HZ t0=0x00000022 t1=0x00000025 delta=0x00000003
cmsdk-ahb-gpio: unimplemented device write (size 4, offset 0x000, value 0x0000a55a)
[5] stub 0x40010000 <- 0xa55a readback cmsdk-ahb-gpio: unimplemented device read  (size 4, offset 0x000)
0x00000000 (unimplemented: 吞写返 0)
done
```

逐行验尸（第 5 步两行是 QEMU stderr 日志与串口 stdout 交错的原样记录，CLK100HZ 各次运行不同）：

- **[1] 读回 0x1**：写 LED0 经模型状态机落账，读回证明"写真的生效"——等价于真机用万用表测引脚电压，只是探针从表笔换成了读寄存器；
- **[2] 闪 5 次**：F407 `while(1){亮;延时;灭;延时;}` 循环的 QEMU 等价物，忙等延时（TCG 下按宿主速度跑，量级感知即可，精确延时是 [[2026-08-30-embedded-basics-ch08-timer-systick|第八章]] SysTick 的正菜）；
- **[3] BUTTON=0**：模型边界如实呈现——输入路径在 QEMU 上只能证明"寄存器可读"，不能证明"按键按下会被看见"；
- **[4] delta=3**：100Hz 自由计数器走了约 30ms——**一个真正"外部世界驱动、软件只能读"的输入寄存器**，等价 IDR 读到了外部事件，这是 QEMU 上能拿到的最接近"读键"的实证；
- **[5] 占位设备探针**：写入被日志点名（`unimplemented device write`），读回 0——**负向验证**完成，和第 1 节的源码考证互证。另注：本机 QEMU 10.1.5 无 `query-leds` QMP 命令（实测 CommandNotFound），LED 状态只能靠固件读回，不能从宿主侧查询。

### 4. 方法论沉淀：模型考证三步

把本章的考证过程提炼成可复用的清单（同样适用于换用其他 QEMU 机型/Renode 的场合）：

1. **查机型源码/文档**：设备清单和地址以仿真器源码为准（`hw/arm/mps2.c` 这类），文档常常只列机型不列地址；`create_unimplemented_device` 的名字再像模型也不是模型；
2. **对寄存器表**：找到真模型后逐偏移核对（`mps2-fpgaio.c` 的 REG32 宏），别拿真板手册的寄存器表想当然套上去——FPGAIO 是 MPS2 的板级器件，不是 F407 的 GPIO；
3. **负向验证**：故意写一个"以为有模型"的地址，开 `-d unimp,guest_errors` 看仿真器怎么说——被点名 unimplemented 就死心，比看任何二手资料都可靠。

> [!warning] QEMU 边界
> 本章 QEMU 实验验证的是"寄存器交互逻辑"：写 LED0 生效、计数器可读、占位设备吞写。F407 侧的时钟门控、MODER 四模式、电气属性在 QEMU 上无对应物——它们只能靠编译产物核对（5.3~5.5）与真机验证（5.7）。

---

## 5.7 真机占位：WeAct F407 点灯与按键（板到后回填）

> [!warning] 真机待验证
> 本节接线与现象均为**依据 RM0090 寄存器语义和通用电路常识的推断**，尚未在实体板上执行。板到后按本节步骤回填实测。

### 1. 板载 LED：以板丝印为准（不编造）

WeAct F407 板载 LED 接在哪个引脚，网上说法不一，我未见到官方原理图前**不给出具体引脚**——这正是"锚点必须可核实"的场合。定位办法（五分钟）：① 看板丝印/官方原理图；② 找不到就万用表二极管档：红表笔 LED、黑表笔 GND，压降 1.x V 发微光者即正向，再顺着 PCB 走线或逐端口试探。**下文用外接 LED 方案，与板上 LED 无关**。

### 2. 外接 LED + 按键接线图

沿用 ch02 万用表实验的 PA0（推挽输出、高电平点亮），按键用 PA1（内部上拉、低有效）：

```text
   STM32F407VET6                        面包板
  ┌──────────────┐
  │ PA0 ─────────┼──[330Ω]──▶|── GND     LED：长脚(正)接电阻侧
  │ PA1 ─────────┼─────┐
  │ GND ─────────┼─────┤                   轻触按键
  └──────────────┘     └──o o── GND       按下 = PA1 接地
```

- LED 限流电阻：(3.3V − 2V) / 330Ω ≈ 4mA，F407 引脚灌/拉电流上限 25mA（数据手册 I/O 特性），安全；
- 固件即 `f407_gpio.c` 的 `led_init` + `button_init` + 主循环（空闲闪、按住快翻）——烧录后无需改引脚。

### 3. 预期现象（回填清单）

| 实验        | 预期（依据：5.2/5.3 寄存器语义 + ch02 同款电路）          | 探针         |
| ----------- | --------------------------------------------------------- | ------------ |
| LED 闪烁    | PA0 对 GND 电压 0V ↔ 3.3V 交替（频率=延时参数）           | 万用表 DC 档 |
| 按住按键    | LED 进入快翻模式；PA1 对地 ≈0V，松开 ≈3.3V（上拉生效）    | 万用表       |
| BSRR 原子性 | 示波器/逻辑分析仪看翻转干净无毛刺（对比 ODR 读改写版本）  | ch02 的 LA   |
| MCO 输出    | PA8（AF0=MCO1）可输出 HSE/PLL 时钟，LA 测频验证时钟树配置 | LA 测频      |

MCO（microcontroller clock output）是"把时钟树变得可观察"的官方后门：`RCC_CFGR` 选 MCO1 源与分频，PA8 复用输出。它是 5.1 时钟树简图的实证工具——配完 PLL 用 LA 在 PA8 上量出 168MHz（或分频后的可测频率），时钟树才算真的跑通。详细配置留待需要时钟树的章节展开。

### 4. 排障表（按概率排序）

| 症状                       | 首查                                                         |
| -------------------------- | ------------------------------------------------------------ |
| 引脚电压恒 0，怎么写都不动 | `RCC_AHB1ENR` 忘开（5.1 的第一大坑）；MODER 没配输出         |
| MODER 写不进/读回错        | 时钟开了但立刻访问（读回同步）；或结构体偏移错位（5.3 排障） |
| 电压 3.3V 但 LED 不亮      | LED 接反（长脚应接电阻侧）；电阻选成 10kΩ 以上               |
| 按键读数乱跳               | PUPDR 没配上拉（悬空天线）；机械抖动（ch07 消抖）            |
| 烧录后 SWD 连不上          | 动了 PA13/PA14（SWD 引脚，5.2 的名场面）                     |

---

## 5.8 小结与预告

本章把"动一个引脚"拆成了三层纪律：**时钟层**（外设的生命线——先开 `RCC_AHB1ENR` 的 GPIOAEN，读回同步）；**配置层**（MODER 四模式、OTYPER 推挽/开漏、OSPEEDR/PUPDR、AFR 路由表）；**数据层**（输出用 BSRR 单写原子操作、输入读 IDR）。全链路口诀：**开时钟 → 选模式 → 写数据**，六步点灯、三步读键，全部经真实编译产物逐寄存器核对，其中还顺手用反汇编抓出一个结构体保留字错位的真 bug。

无板先行的核心收获是**映射方法论**：F407 代码做编译验证（gcc + objdump 是免费的严格审阅者），QEMU 侧考证模型（`cmsdk-ahb-gpio` 是占位、FPGAIO 才是真模型）后跑等价逻辑，负向探针（`-d unimp`）钉死边界。板子到手后，5.7 节的接线图和回填清单等着实测。

下一章 [[2026-08-30-embedded-basics-ch06-uart-protocol|嵌入式硬件基础（六）：UART 协议]]——第一个"复用功能"外设实战：PA2/PA3 的 AF7 路由本章已配好，剩下 `RCC_APB1ENR` 开 USART2 时钟、波特率分频计算与容差分析、双板成帧协议设计。点灯是单调的，串口会说话。
