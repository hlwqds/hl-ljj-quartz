---
title: "Zig × ESP32-S31 全栈开发（六）：GPIO、UART、日志与 panic"
date: 2026-11-14 18:00:00
description: "把 S31 的引脚拆成 IO_MUX / GPIO / GPIO 矩阵三层，用寄存器写出最小的输出与输入；把 UART0 拆成帧格式、分频、FIFO 与中断四件事，TX 交给掩膜 ROM 的 printf、RX 用轮询 FIFO 加环形缓冲（并说清为什么还不是中断）；再补上分级日志与基于 mtvec 的 trap 现场打印，最后划清 WS2812 与 RMT 的边界。"
tags: [zig, esp32-s31, riscv, gpio, uart, logging, panic, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. [[ch04-linker-memory-layout|第四章：链接脚本与内存布局]]
> 5. [[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]
> 6. **第六章：GPIO、UART、日志与 panic**
> 7. [[ch07-interrupts-exceptions-clic|第七章：中断、异常与 CLIC]]

# Zig × ESP32-S31 全栈开发（六）：GPIO、UART、日志与 panic

前五章造出来的东西有一个共同点：**只有一个观测通道**——UART0 上的一行行文本。第四章的 `_start` 打完 `hello form B` 就进死循环，第五章把“时间”这件事做实，也是靠串口的节奏去核对。这一章把这个通道从“只能喊”变成“能对话”，再加一条不需要任何外设的电平通道（一个 GPIO 引脚），然后把两条通道组织成一套**能被信任的观测基础**：分级日志、可预期触发的 trap 现场打印。

“能被信任”是这一章的真正目标。裸机上最贵的不是写寄存器，而是**判断寄存器写对没写对**。所以本章的每条结论都配一个可执行的检查：读写哪个地址、期望看到什么位、用什么命令核对。凡是需要板子才能确认的，一律标「待真机验证」。

> [!warning] 本章的证据边界
> 寄存器地址、位域与复位值全部来自 ESP-IDF v6.1 的 `esp32s31` 头文件与链接片段（下文逐条给出路径），S31 的 TRM 仍是 Pre-release v0.7；Zig 侧的写法沿用第四章已建立的目标串与链接脚本。本工程已于 2026-11-13 **真机运行**：非法指令 trap 打印 `mcause/mepc/ra/mtval/sp` 后 `wfi` 停机、不复位，原始输出见 `../logs/ch06-trap.log`；引脚波形未测。

---

## 6.1 一个通道，三种用法

### 1. 从“喊”到“对话”

回看前几章的观测手段，它们全都是单向的：

| 章   | 观测手段                  | 信息方向    | 局限                   |
| ---- | ------------------------- | ----------- | ---------------------- |
| ch02 | `printf("hello s31")`     | 设备 → 主机 | 只能确认“跑到了这一行” |
| ch03 | `esptool image-info`      | 主机侧自检  | 完全不涉及运行         |
| ch04 | `hello form B` + `tick B` | 设备 → 主机 | 只能确认节奏，不能交互 |
| ch05 | 时间基准 + 复位原因       | 设备 → 主机 | 需要人读，不能下命令   |

单向输出有一个硬伤：**你无法在设备运行时改变它的行为**。想“换个引脚试试”“把日志调详细一点”“看看某个计数器现在是多少”，都得重新编译、重新烧录。本章补上反向通道（RX），于是三件事同时变得便宜：

1. **回显**：敲一个字符，设备立刻打回来——这一条就同时验证了 RX 搬运、环形缓冲、命令解析、TX 输出四条路径；
2. **查询**：`p` 打印 FIFO 深度、缓冲占用、丢弃计数，把“看不见的内部状态”变成一行文本；
3. **自伤测试**：`t` 主动执行一条非法指令，验证 trap 向量真的装上了、现场打印真的能出来。这是本章唯一一个“故意让程序崩”的开关，它存在的价值在于：**panic 路径如果不经过一次真实触发，你永远不知道它是否可用**。

### 2. 三条链路与它们的失败模式

本章的工程同时建立三条独立链路，它们失败时的表现完全不同，这正是排错时分层的依据：

```text
                       ┌──────────────────────────────────────┐
   Zig 代码            │  ROM: esp_rom_printf (0x2f800024)    │
   uart.puts/putc ────►│  → UART0 TX FIFO → GPIO58 → USB-UART │──► 主机终端
                       └──────────────────────────────────────┘
                       ┌──────────────────────────────────────┐
   主机按键 ──────────►│ GPIO59 → UART0 RX FIFO → STATUS 轮询  │
                       │  → 环形缓冲 → 回显 / 命令             │
                       └──────────────────────────────────────┘
                       ┌──────────────────────────────────────┐
   主循环 toggle ─────►│ IO_MUX(pin×4) + GPIO OUT_W1TS/W1TC   │──► J2 排针（示波器）
                       └──────────────────────────────────────┘
```

- **TX 断了**：串口一个字都没有，但板子可能在正常运行（bootloader 日志也没有则更早出问题）；
- **RX 断了**：横幅正常、心跳正常，但敲键盘没反应，`p` 里的 `rx fifo` 永远是 0；
- **GPIO 断了**：串口一切正常，示波器上却是直线。

把三条链路分开验证，比“一起上，然后猜哪里错”快一个数量级。本章的验收顺序就按这个来：先横幅，再回显，最后才看波形。

### 3. 本章不做什么

先把边界划清，后面每一节都不会越界：

- **不打开中断**。`_start` 里 `mie = 0`、`mstatus.MIE = 0` 保持不变，UART 接收是轮询。中断需要 CLIC 向量模式、中断矩阵路由、`mie`/`mstatus` 三件事同时到位，那是下一章的主题。在它们没配好之前打开 UART 中断，症状是“永远不进中断”或者“进了中断但跳到 bootloader 留下的向量”，两种都极难归因。
- **不配置时钟**。CPU 频率、UART 时钟分频都由 ROM 与 bootloader 定好；本章只是**读**它们的结果（UART 的默认分频 694 就是证据，见 6.4）。
- **不点 GPIO60 的 RGB LED**。它是 WS2812 类单线归零码器件，需要 RMT 或严格校准的时序；普通 GPIO 推挽输出能翻转电平，但拼不出可靠的位时序。6.8 会把这条边界讲透。
- **不引入 `std.log` / `std.fmt`**。freestanding 目标没有 writer，标准库的日志后端在这里是空的，而它的格式化会把一大坨代码拉进镜像。本章的日志格式在编译期就定死。

---

## 6.2 引脚的三层结构：IO_MUX、GPIO、GPIO 矩阵

### 1. 一颗引脚上叠着三层逻辑

S31 有 63 个 GPIO（编号 0..62，`gpio_reg.h` 里最后一个寄存器是 `GPIO_PIN62_REG`）。每个引脚在硅片上对应三样东西，它们的职责不重叠：

> [!note] 本章代码只实现 bank0
> `GPIO_OUT`/`GPIO_ENABLE`/`GPIO_IN` 是每 32 位一组：GPIO0..31 在 bank0，GPIO32..62 需要 `OUT1`/`ENABLE1`/`IN1` 以及对应的 W1TS/W1TC 寄存器。本章的 `gpio.zig` 只做 bank0（演示引脚 GPIO5 在范围内），bank1 留到后续章节；GPIO60 的 WS2812 本来也不能用普通 GPIO 电平驱动。

| 层            | 管什么                                            | 本章用到的寄存器                           |
| ------------- | ------------------------------------------------- | ------------------------------------------ |
| **IO_MUX**    | 电气属性（上/下拉、驱动强度、输入使能）+ 功能选择 | `IO_MUX + pin × 4`                         |
| **GPIO 外设** | 简单的“输出电平 / 输入电平 / 输出使能”            | `GPIO_OUT`、`GPIO_ENABLE`、`GPIO_IN`       |
| **GPIO 矩阵** | 把 256 个外设信号中的任意一个接到任意引脚上       | `GPIO_FUNCn_OUT_SEL_CFG`、`..._IN_SEL_CFG` |

三者是**串联**的，顺序不能颠倒：

```text
外设信号（UART_TXD / RMT_CH0 / 常量 1 ……）
        │  ① 矩阵：OUT_SEL 选一个信号（0..255），或 256 = 由 GPIO_OUT 位驱动
        ▼
   GPIO 矩阵输出选择
        │  ② GPIO 外设：OUT 位给电平、ENABLE 位给方向
        ▼
   IO_MUX：③ MCU_SEL 决定“引脚交给谁”（1 = GPIO 外设），FUN_IE/FUN_PU 决定电气
        ▼
      引脚焊盘 → 排针
```

任何一层没配好，引脚都不会按你的意思动：矩阵没选对，GPIO_OUT 写了也没用；IO_MUX 没选 GPIO 功能，引脚可能还在输出 UART 或 USB 的波形；输出使能没打开，电平写对了但引脚是高阻。

### 2. IO_MUX：一个引脚一个 32 位寄存器，偏移是 `pin × 4`

IO_MUX 的基址是 `0x20582000`（IDF v6.1 `components/soc/esp32s31/register/soc/reg_base.h` 的 `DR_REG_IO_MUX_BASE`）。引脚 `n` 的寄存器地址是：

```text
IO_MUX_GPIO_n = 0x20582000 + 4 × n
```

这条线性关系可以直接用头文件自证（`components/soc/esp32s31/register/soc/io_mux_reg.h`）：

| 引脚   | 宏                        | 偏移   | 偏移 ÷ 4 |
| ------ | ------------------------- | ------ | -------- |
| GPIO2  | `PERIPHS_IO_MUX_U_GPIO2`  | `0x08` | 2        |
| GPIO5  | `PERIPHS_IO_MUX_U_GPIO5`  | `0x14` | 5        |
| GPIO58 | `PERIPHS_IO_MUX_U_GPIO58` | `0xE8` | 58       |
| GPIO62 | `PERIPHS_IO_MUX_U_GPIO62` | `0xF8` | 62       |

（唯一的“例外”是 GPIO0/1：它们的寄存器在 `0x0`/`0x4`，宏名带 `XTAL32K`，因为这两颗引脚兼作 32 kHz 晶振接口——偏移仍然符合 `pin × 4`。）

因为关系是线性的，代码里不需要手抄 63 项的表，一行乘法就够：

```zig
pub inline fn ioMuxReg(pin: Pin) usize {
    return io_mux_base + @as(usize, pin) * 4;
}
```

位域（同一个头文件，`PIN_FUNC_SELECT(PIN_NAME, FUNC)` 就是往 `MCU_SEL` 里写）：

| 位        | 名称                | 含义                                             |
| --------- | ------------------- | ------------------------------------------------ |
| 0         | `SLP_OE`            | 睡眠模式下的输出使能                             |
| 1         | `SLP_SEL`           | 睡眠模式下的功能选择                             |
| 2 / 3     | `SLP_PD` / `SLP_PU` | 睡眠模式下的下拉 / 上拉                          |
| 4         | `SLP_IE`            | 睡眠模式下的输入使能                             |
| 6:5       | `SLP_DRV`           | 睡眠模式下的驱动强度                             |
| **7**     | **`FUN_PD`**        | 下拉使能（正常工作模式）                         |
| **8**     | **`FUN_PU`**        | 上拉使能（正常工作模式）                         |
| **9**     | **`FUN_IE`**        | 输入使能                                         |
| 11:10     | `FUN_DRV`           | 驱动强度（0..3）                                 |
| **14:12** | **`MCU_SEL`**       | 功能选择；`PIN_FUNC_GPIO = 1` 表示接到 GPIO 外设 |

四个“本章真正会写”的位加粗了。注意 `FUN_IE` 与“方向”不是一回事：`FUN_IE` 是**输入缓冲器**的电源开关，输出引脚也需要它才能回读（`GPIO_IN` 才能反映真实电平）。

### 3. GPIO 外设：为什么输出要写 `W1TS` / `W1TC`

GPIO 的基址是 `0x20583000`（`DR_REG_GPIO_BASE`）。本章用到的寄存器（全部来自 `components/soc/esp32s31/register/soc/gpio_reg.h`）：

| 寄存器                 | 偏移    | 语义                                  |
| ---------------------- | ------- | ------------------------------------- |
| `GPIO_OUT_REG`         | `0x004` | 整个端口的输出电平快照                |
| `GPIO_OUT_W1TS_REG`    | `0x008` | 写 1 的位**置位**（write-1-to-set）   |
| `GPIO_OUT_W1TC_REG`    | `0x00C` | 写 1 的位**清零**（write-1-to-clear） |
| `GPIO_ENABLE_REG`      | `0x034` | 输出使能快照                          |
| `GPIO_ENABLE_W1TS_REG` | `0x038` | 写 1 置位输出使能                     |
| `GPIO_ENABLE_W1TC_REG` | `0x03C` | 写 1 清除输出使能                     |
| `GPIO_IN_REG`          | `0x064` | 引脚的当前电平（输入缓冲器的结果）    |
| `GPIO_STATUS_REG`      | `0x074` | 中断相关状态，本章不用（下一章）      |

“原子置位/清零”不是风格问题。假设你要把 GPIO5 拉高，而另一个模块正在操作 GPIO6：

```text
读-改-写： v = GPIO_OUT; v |= (1<<5); GPIO_OUT = v;
           ↑ 两条指令之间若有中断改过 GPIO6，就会把它改回去
W1TS     ： GPIO_OUT_W1TS = (1<<5);   // 只碰第 5 位，天然原子
```

本章关着中断，所以这条风险暂时不成立；但代码是给下一章的中断版准备的——**用 W1TS/W1TC 的代码不需要在打开中断后返工**。

### 4. GPIO 矩阵：`OUT_SEL = 256` 是什么意思

矩阵的每个输出选择寄存器是 32 位，其中 `OUT_SEL` 占 `[8:0]`（9 位，0..511），复位值是 **256**。头文件对 256 的解释很直白：

> `256: Bit 0 of GPIO_OUT_REG and GPIO_ENABLE_REG are selected as the output value and output enable.`
> —— `components/soc/esp32s31/register/soc/gpio_reg.h`，`GPIO_FUNC0_OUT_SEL_CFG_REG` 的字段注释

也就是说，0..255 是“选一个外设信号”（`gpio_sig_map.h` 里的 `SIG_*`），256 是“选 GPIO 外设自己的位”。IDF 里 `gpio_matrix_out(pin, SIG_GPIO_OUT_IDX, false, false)` 用的正是这个常量（`gpio_sig_map.h`：`#define SIG_GPIO_OUT_IDX 256`）。

既然复位值就是 256，为什么代码还要显式写一遍？因为**复位之后不一定是复位值**：ROM 与二级 bootloader 都动过矩阵（UART0 的 TX 就路由过 GPIO58）。对本章的演示引脚，显式写回 256 是把“这个引脚归我管”这件事钉死的唯一手段，代价是一条 `sw`。

输入侧是另一套寄存器（`GPIO_FUNCn_IN_SEL_CFG_REG`，偏移 `0x2f4 + 4n`），它的索引是**外设信号号**而不是引脚号。普通 GPIO 输入**不需要**碰它：`MCU_SEL = 1` 之后 `GPIO_IN` 直接反映引脚电平。头文件里还写了两个常量，值得记一笔（`components/soc/esp32s31/include/soc/gpio_pins.h`）：

```c
#define GPIO_MATRIX_CONST_ONE_INPUT   (0x80)
#define GPIO_MATRIX_CONST_ZERO_INPUT  (0xC0)
```

高两位为 `10` 表示恒 1、`11` 表示恒 0——调试时可以给某个外设输入“冒充”一个固定电平，不必真的接线。

### 5. 一颗引脚配错的四种典型症状

| 症状                                       | 漏了哪一层                                     | 验证方法                                           |
| ------------------------------------------ | ---------------------------------------------- | -------------------------------------------------- |
| 电平写对了，排针上是高阻（万用表读到浮动） | `GPIO_ENABLE` 没置位                           | 读 `GPIO_ENABLE` 的对应位；再读 `GPIO_IN` 是否跟随 |
| `GPIO_IN` 一直是 0，无论外部怎么拉         | `FUN_IE` 没打开（输入缓冲器关着）              | 读 IO_MUX 的 bit 9                                 |
| 引脚上有波形，但不是你写的电平             | `MCU_SEL` 还指着别的功能（UART/USB/模拟）      | 读 IO_MUX 的 `[14:12]`，应为 1                     |
| 写了 `GPIO_OUT` 但完全没反应               | `OUT_SEL` 不是 256（被矩阵接到了别的外设信号） | 读 `GPIO_FUNCn_OUT_SEL_CFG` 的低 9 位              |

这四条正好按“矩阵 → GPIO → IO_MUX”的顺序排列，也就是排错时应该走的顺序。

---

## 6.3 输出与输入：把配置顺序写对

### 1. 输出配置的四步顺序

```text
① IO_MUX: MCU_SEL = 1（引脚交给 GPIO 外设），FUN_IE = 1（可回读）
② 矩阵:   OUT_SEL = 256（输出值来自 GPIO_OUT 的对应位）
③ GPIO:  OUT_W1TC = bit（先把电平压到 0）
④ GPIO:  ENABLE_W1TS = bit（最后才打开输出使能）
```

第 ③④ 步的顺序是有物理后果的：**打开使能的那一刻，引脚上会出现 OUT 位的当前值**。如果 OUT 位是随机的（复位值 0，但 bootloader 可能动过），你会先看到一个毛刺，再看到目标电平。先把电平压到确定的 0，再使能，毛刺就是“从高阻到低”这一步，对 LED、对示波器触发都更干净。

对应的代码（`src/gpio.zig`）刻意把每一步都写成独立语句，而不是“一次写一个大位域”——排错时能单步停在任何一行：

```zig
pub fn configureOutput(pin: Pin) void {
    if (!inRange(pin)) return;
    selectGpioFunction(pin);          // ① IO_MUX: MCU_SEL=1, FUN_IE=1

    reg(reg_func_out_sel_base + @as(usize, pin) * 4).* = sig_gpio_out_idx; // ② = 256

    reg(reg_out_w1tc).* = bit(@intCast(pin));       // ③ 电平先归 0
    reg(reg_enable_w1ts).* = bit(@intCast(pin));    // ④ 再使能
}
```

### 2. 输入：`FUN_IE`、上拉、以及“读哪个寄存器”

输入配置只有三条：

```zig
pub fn configureInput(pin: Pin, pull_up: bool) void {
    if (!inRange(pin)) return;
    selectGpioFunction(pin);                 // MCU_SEL=1 + FUN_IE=1
    reg(reg_enable_w1tc).* = bit(@intCast(pin)); // 只做输入，关掉输出驱动

    const addr = ioMuxReg(pin);
    var v = reg(addr).*;
    v &= ~(fun_pu | fun_pd);
    if (pull_up) v |= fun_pu;                // 上拉与下拉互斥
    reg(addr).* = v;
}
```

两个容易写错的地方：

- **读 `GPIO_IN` 而不是 `GPIO_OUT`**。`GPIO_OUT` 是你“要求”的电平，`GPIO_IN` 是引脚“实际”的电平。输出被外部器件拉低、或者引脚配成输入时，两者会不同。诊断“我的输出到底有没有生效”，唯一可信的是 `GPIO_IN`。
- **上拉与下拉不能同时开**。`FUN_PU` 与 `FUN_PD` 同时置位不是“加强”，而是把引脚钉在一个由两个等效电阻分压出来的中间电平上——读数会随机跳。

本章的 `gpio.zig` 提供了 `configureInput` / `get`，但演示工程只用输出：板上的 BOOT 按键（GPIO61）虽然是现成的输入源，它同时是 **strapping 引脚**，在启动瞬间被 ROM 采样，用它做实验会把“启动模式”和“按键读取”两件事混在一起。留到有明确需要时再用。

### 3. 引脚选择：为什么是 GPIO5

本章工程需要一颗“能在示波器上看”的引脚，挑选标准是**不承担任何系统职责**：

| 引脚        | 职责                                        | 能不能当演示引脚             |
| ----------- | ------------------------------------------- | ---------------------------- |
| GPIO0 / 1   | 32 kHz 晶振（IO*MUX 里叫 `XTAL32K*\*`）     | 不能，动了会影响 RTC 时钟    |
| GPIO33 / 34 | USB PHY（`PERIPHS_IO_MUX_U_USB_GPIO33/34`） | 不能，USB Serial/JTAG 用得到 |
| GPIO42–57   | ADC 组（`PERIPHS_IO_MUX_U_ADC_GPIO*`）      | 可以，但会引入模拟域的疑问   |
| GPIO58 / 59 | UART0 TX / RX（控制台）                     | 不能，会把日志打断           |
| GPIO60      | 板载可寻址 RGB LED                          | 不能，见 6.8                 |
| GPIO61      | BOOT 按键 / strapping                       | 不建议                       |
| **GPIO5**   | 普通的 `PERIPHS_IO_MUX_U_GPIO5`             | **本章默认**                 |

> [!warning] 演示引脚必须按原理图核对
> 本仓没有收录 ESP32-S31-Function-CoreBoard-1 的 J2 针脚定义，所以“GPIO5 是否在 J2 上、它旁边有没有别的器件”属于「待真机验证」事项。`src/main.zig` 里 `demo_pin` 是一个常量，换引脚只改这一行；换完要同时确认新引脚不在上表的“不能”行里。

---

## 6.4 UART：四个寄存器决定一切

### 1. 帧格式：复位值就是 8N1

UART 的一帧是“起始位 + 数据位 + 可选校验位 + 停止位”。S31 的 UART 把这件事放在 `UART_CONF0_SYNC_REG`（基址 `+0x20`）：

| 位      | 字段                        | 复位值 | 含义                                       |
| ------- | --------------------------- | ------ | ------------------------------------------ |
| 0       | `PARITY`                    | 0      | 校验位极性（偶/奇）                        |
| 1       | `PARITY_EN`                 | 0      | 校验使能                                   |
| 3:2     | `BIT_NUM`                   | **3**  | 数据位：0=5、1=6、2=7、**3=8**             |
| 5:4     | `STOP_BIT_NUM`              | **1**  | 停止位：1=1 位、2=1.5 位、3=2 位（0 无效） |
| 12      | `LOOPBACK`                  | 0      | 自环（TX 直接进 RX，做无接线自测用）       |
| 19      | `AUTOBAUD_EN`               | 0      | 自动波特率检测                             |
| 20      | `MEM_CLK_EN`                | 0      | FIFO 内存时钟使能                          |
| 22 / 23 | `RXFIFO_RST` / `TXFIFO_RST` | 0      | 复位对应 FIFO（写 1 有效，硬件自清）       |

三个复位值连起来读：`BIT_NUM = 3`（8 位数据）、`STOP_BIT_NUM = 1`（1 位停止）、`PARITY_EN = 0`（无校验）——**8N1 是复位默认值**，不是“业界约定”。这解释了为什么 ROM 的 `printf` 不需要我们配任何东西就能打出可读的文本，也解释了 ch02 里“别乱改波特率”的告诫：ROM 只是没改过这些位，不是它替你锁住了。

### 2. 波特率：`CLKDIV` 的复位值泄露了时钟

`UART_CLKDIV_SYNC_REG`（`+0x14`）的字段：

| 位    | 字段          | 复位值  | 含义                   |
| ----- | ------------- | ------- | ---------------------- |
| 11:0  | `CLKDIV`      | **694** | 分频的整数部分         |
| 23:20 | `CLKDIV_FRAG` | 0       | 分频的小数部分（4 位） |

`CLKDIV` 只有 12 位，说明这是一颗**分频比直接等于 `clk / baud`** 的 UART（新式 ESP 芯片的写法），而不是老式 16 倍过采样（那种要把 `clk / (16 × baud)` 填进去）。用复位值反推时钟：

```text
694 × 115200 = 79,948,800 Hz ≈ 79.95 MHz
```

四舍五入到 80 MHz，误差约 0.06%——远小于 UART 允许的 2%~3%。所以这一条可以当作**证据**用：复位后的 UART 时钟在 80 MHz 一带，分频精度够 115200。

> [!note] 这是算术推断，不是手册断言
> 上面这条推导只用了“复位值 694”和“终端看到的是 115200 可读文本”两个事实。S31 的 TRM 还是 Pre-release，UART 时钟源的具体分频链（`UART_CLK_CONF_REG` 的 `SCLK_DIV` 等在 `+0x88`）以手册转正后的描述为准。本章的代码**不写任何时钟寄存器**，所以这条推断即使细节有偏差，也不影响工程行为。

### 3. FIFO：深度、阈值与计数

数据通道只有两个动作，都在 `UART_FIFO_REG`（`+0x00`）：

- **读**：`UART_RXFIFO_RD_BYTE`，`[7:0]` 是数据字节（`uart_reg.h` 的字段注释：“Represents the data UART $n read from FIFO”）；
- **写**：推一个字节进 TX FIFO。

容量与水位在 `UART_CONF1_REG`（`+0x24`）：

| 位   | 字段                 | 复位值 | 含义                   |
| ---- | -------------------- | ------ | ---------------------- |
| 7:0  | `RXFIFO_FULL_THRHD`  | **96** | RX FIFO “满”中断的阈值 |
| 15:8 | `TXFIFO_EMPTY_THRHD` | **96** | TX FIFO “空”中断的阈值 |

阈值默认 96，说明 FIFO 深度**至少** 96 ——历史 ESP 芯片的 UART FIFO 是 128 字节，S31 的具体深度以 TRM 为准（「待真机验证」）。这个数字很重要，它决定了轮询的节奏上限：115200 下 1 ms 大约来 11.52 个字节，128 字节的 FIFO 能容忍约 11 ms 的“没人搬”。本章把主循环切成 1 ms 一片，就是留了 10 倍的余量。

当前占用读 `UART_STATUS_REG`（`+0x1c`）：

| 位    | 字段         | 含义                             |
| ----- | ------------ | -------------------------------- |
| 7:0   | `RXFIFO_CNT` | RX FIFO 里可读的字节数           |
| 15    | `RXD`        | 内部 RX 信号电平（排错时看线序） |
| 23:16 | `TXFIFO_CNT` | TX FIFO 里待发的字节数           |
| 31    | `TXD`        | 内部 TX 信号电平                 |

`RXFIFO_CNT == 0` 就是“现在没数据”的判据——本章的轮询循环只用这一位。

### 4. 中断：四个寄存器，本章只读不写

UART 的中断全部集中在四个连续寄存器里：

| 寄存器             | 偏移    | 作用                             |
| ------------------ | ------- | -------------------------------- |
| `UART_INT_RAW_REG` | `+0x04` | 硬件置的原始标志（不受使能影响） |
| `UART_INT_ST_REG`  | `+0x08` | `RAW & ENA` 之后的“已屏蔽”状态   |
| `UART_INT_ENA_REG` | `+0x0C` | 逐位使能                         |
| `UART_INT_CLR_REG` | `+0x10` | 写 1 清标志                      |

和接收有关的三位：`RXFIFO_FULL`（bit 0）、`FRM_ERR`（bit 3）、`RXFIFO_TOUT`（bit 8）。前两个的语义直白，第三个值得解释：**`RXFIFO_TOUT` 是“接收空闲超时”**——FIFO 里还有数据但线上已经安静了一段时间，硬件就报一次中断。命令行场景里它比 `RXFIFO_FULL` 重要得多：人打字一次只来 1 个字节，永远填不满 96 字节的阈值，靠 `FULL` 触发的中断会让你的命令一直卡在 FIFO 里。

本章**不写** `INT_ENA`，但**读** `INT_RAW`：`FRM_ERR`（bit 3）是粘滞的，读到 1 就说明“曾经出过帧错误”（波特率不对、TX/RX 接反、线上干扰）。把它放进 `p` 命令的输出里，等于给串口链路加了一个免费的自检位。

### 5. 三个还必须知道的寄存器

| 寄存器              | 偏移    | 本章为什么提它                                                      |
| ------------------- | ------- | ------------------------------------------------------------------- |
| `UART_RX_FILT_REG`  | `+0x18` | `GLITCH_FILT` 复位 8、`GLITCH_FILT_EN` 复位 0：窄脉冲滤波，默认关闭 |
| `UART_MEM_CONF_REG` | `+0x60` | FIFO 内存的 `FORCE_PU/PD`（bit 26/25）：低功耗时才需要动            |
| `UART_CLK_CONF_REG` | `+0x88` | `TX_SCLK_EN`/`RX_SCLK_EN` 复位 1；时钟门控与 `SCLK_DIV` 在这里      |

它们的存在本身就是一条纪律：**本章一个都不写**。改波特率要同时动 `CLKDIV_SYNC`（分频）、`CLK_CONF`（时钟源与门控）和终端设置三处，任何一处不一致，表现都是乱码；而乱码在“只有单向 TX”的阶段几乎无法归因。等有了双向通道和 trap 现场（本章后面两节），再改这些寄存器才有排错能力。

---

## 6.5 先发后收：ROM printf 与轮询环形缓冲

### 1. TX：为什么直接借 ROM 的 `printf`

链接脚本里有两条 `PROVIDE`（沿用第四章）：

```ld
PROVIDE(esp_rom_printf = 0x2f800024);
PROVIDE(esp_rom_delay_us = 0x2f80003c);
```

地址来自 `components/esp_rom/esp32s31/ld/esp32s31.rom.ld`（`ets_printf` / `ets_delay_us`），别名关系在 `esp32s31.rom.api.ld` 里。借它的理由有三条，按重要性排序：

1. **它已经配好了 UART0**。引脚复用（GPIO58 的 `MCU_SEL` 指到 UART）、波特率（`CLKDIV = 694`）、帧格式（8N1）都是 ROM 干的；我们一条都不用重做。
2. **它和 bootloader 日志在同一个端口、同一个波特率**。这一点在排错时价值极高：如果 bootloader 的日志能看到、应用的横幅看不到，问题一定在“跳转之后”，而不是“串口链路”。换端口或换波特率会立刻丢掉这个强假设。
3. **它是阻塞式的**。TX FIFO 满时它自己等（ROM 实现是忙等，具体等待行为以实测为准），所以我们不需要轮询 `TXFIFO_CNT`——代价是“打印会占用时间”，这一点在 6.8 讲 WS2812 时会变成硬约束。

代码上只有两个函数：

```zig
extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

pub fn putc(c: u8) void { _ = esp_rom_printf("%c", @as(c_int, c)); }
pub fn puts(s: [*:0]const u8) void { _ = esp_rom_printf("%s", s); }
```

**`[*:0]const u8` 不是随手写的**。Zig 的 `[]const u8` 是“指针 + 长度”的胖指针，传给 C 变参会丢掉长度，`printf` 会一路读到内存里第一个 0 字节为止——轻则打出垃圾，重则越过 `.rodata` 触发访问错误。`[*:0]const u8` 是“以 0 结尾的多项指针”，与 C 的 `const char *` 逐字节对应。

同理，`%c` 的实参要显式转成 `c_int`：C 的默认实参提升把 `char` 提升为 `int`，Zig 不做隐式提升，类型对不上时行为依实现而定。

### 2. 数字打印：为什么不用 `%d`

`%d` 看起来更省事，但它要求实参是 `int`（有符号 32 位）。我们的计数都是 `u32`，语义上大于 `INT_MAX` 的值会被打印成负数；而 `%u`、`%lu` 在不同 libc 里的实际宽度又不同（ROM 的 printf 是精简实现）。这类 bug 不会崩，只会让日志骗人——比崩更难查。

所以 `uart.zig` 自己实现两个打印器：

```zig
pub fn putHex32(label: [*:0]const u8, v: u32) void   // label=0x0000abcd
pub fn putDec32(label: [*:0]const u8, v: u32) void   // label=123
```

十六进制固定 8 位、小写；十进制用 10 字节的栈上缓冲倒序输出。两个函数都不依赖任何 libc，与 ABI 无关，`panic.zig` 里打印 `mcause`/`mepc` 也复用它们——崩溃路径上的代码越少依赖越好。

### 3. RX：为什么先轮询

接收侧的四条事实决定了本章的方案：

| 事实                                                 | 结论                                         |
| ---------------------------------------------------- | -------------------------------------------- |
| `STATUS.RXFIFO_CNT` 直接给出可读字节数               | 轮询只需要读一个寄存器                       |
| FIFO 深度至少 96（阈值复位值），1 ms 只来 ~11.5 字节 | 轮询间隔 1 ms 有 10 倍余量                   |
| 中断需要 CLIC 向量 + 中断矩阵 + `mie`                | 三件事都没做（本章边界）                     |
| 命令行输入是“突发 + 空闲”，不是持续流                | 结构应该按“突发到达”设计，而不是“按字节回调” |

于是接收路径是：

```text
每 1 ms：
  while (STATUS.RXFIFO_CNT != 0)
      读 UART_FIFO → 塞进环形缓冲
  从环形缓冲 pop → 回显 / 解析命令
```

对应的两段代码（`src/uart.zig`）：搬运是 `drainFromFifo()`，环形缓冲是 `RingBuffer`。

```zig
pub fn drainFromFifo(self: *RingBuffer) u32 {
    var moved: u32 = 0;
    while (readByte()) |b| {
        _ = self.push(b);
        moved += 1;
    }
    return moved;
}
```

### 4. 环形缓冲：SPSC、2 的幂、丢新不丢旧

```zig
pub const RingBuffer = struct {
    pub const capacity: usize = 128;   // 必须是 2 的幂
    buf: [capacity]u8 = undefined,
    head: u32 = 0,                     // 生产者推进
    tail: u32 = 0,                     // 消费者推进
    drops: u32 = 0,                    // 满时丢弃计数
};
```

四个设计决定，每一个都能说清“不这样会怎样”：

1. **容量取 2 的幂**，索引用 `& (capacity - 1)` 取模。取模指令在 RV32I 上要调用 `__modsi3` 之类的软件实现（M 扩展有 `remu`，但仍有 3 拍以上延迟），而掩码是一条 `and`。这点差距在中断路径上会被放大：ISR 里的每一条指令都要计入延迟预算。
2. **`head`/`tail` 是单调递增的 `u32`，不是“回绕到 0 的索引”**。这样 `len() = head -% tail` 一行搞定，不需要“留一个空位区分满/空”的技巧；u32 回绕在模 2^32 减法下自动正确（`-%` 是 Zig 的“wrapping 减法”，正是这里要的语义）。
3. **满时丢弃新字节并计数**，而不是覆盖旧数据。命令行场景里丢一个字符，你会立刻发现命令拼错了；悄悄丢掉半条命令，你会以为设备“有时候不理人”。`drops` 出现在心跳行里，把“偶发”变成“可见”。
4. **单生产者 / 单消费者**。现在生产者在主循环，将来在 ISR；无论哪种，只要“只有一个写 head 的、一个写 tail 的”，就不需要关中断或原子操作。这个前提必须写进注释，否则下一个人加第二个生产者时会出现极难复现的竞态。

### 5. 从轮询改成中断，只差三件事

把 `drainFromFifo` 搬进 ISR，代码本身一行都不用改（这正是先做环形缓冲的理由）。缺的是三处配置：

1. **`mtvec` 的 CLIC 模式**。本章的 trap 向量是 MODE=0（直接模式），只接异常；S31 有 `clic_reg.h`，中断走 CLIC 的向量表与优先级，是另一种模式。
2. **中断矩阵**。UART0 的源号要路由到某个 CPU 通道（`interrupt_core0_reg.h` 一类寄存器），否则 CPU 根本不知道“UART0 有话说”。
3. **`mie` / `mstatus.MIE`**。本章把它们清零之后就再没动过；中断版要按“配路由 → 清标志 → 开 `mie` 对应位 → 开 `mstatus.MIE`”的顺序打开。

这三件事是下一章的主线。所以本章的 `p` 命令特意把 `rx fifo`、`rx queued`、`rx drops` 三个数打出来——它们是“轮询版”的健康指标，也是下一章对照“中断版”的基线。

---

## 6.6 日志：级别是运行期的，格式是编译期的

### 1. 四级，外加一个 `off`

```zig
pub const Level = enum(u8) { off = 0, err = 1, warn = 2, info = 3, debug = 4 };
pub var level: Level = .info;
```

语义与 IDF 的 `esp_log` 同级：

| 级别    | 什么时候用                           | 本章的实际用法                 |
| ------- | ------------------------------------ | ------------------------------ |
| `err`   | 程序无法继续，必须人工介入           | trap 报告、`fatal()`           |
| `warn`  | 还能跑，但状态可疑                   | 帧错误提示、trap 演示前的警告  |
| `info`  | 正常生命周期的里程碑                 | 横幅、GPIO 配置完成、心跳      |
| `debug` | 排错时才打开的过程信息               | `mtvec` 地址、配置后的电平回读 |
| `off`   | 全关。只在“绝不能让串口拖慢时序”时用 | 本章不用，但保留它             |

`enabled()` 就是一次整数比较，运行期改 `log.level` 立刻生效——这对“现场调日志详细程度”很有用：不用重烧，改一个变量就行（下一章接上中断后，还能做成串口命令 `v` 切级别）。

### 2. 三个打印原语，恰好覆盖本章所有日志

```zig
log.msg(.info, "ch06-gpio-uart-log | form B ...");   // 纯文本
log.dec(.info, "demo gpio", 5);                       // label=数字
log.hex(.debug, "mtvec", addr);                        // label=0x........
log.dec2(.info, "toggles", n, "rx drops", d);          // 一行两个数字
```

为什么不做一个“万能格式化”函数？因为那需要可变参数转发。Zig 调用 C 变参函数时，**不能把一个 tuple 直接展开成变参列表**（`printf(fmt, args)` 这种写法不成立）；要做只能每个实参单独写一遍。既然每个调用点的参数个数本来就固定，把“一行一个字段”做成具体函数反而最省：调用点一目了然，编译期就能发现参数个数写错。

### 3. 为什么不用 `std.log`

三个理由，任何一个都足够：

1. **没有 writer**。`std.log` 的输出端是 `std.io` 的 writer，freestanding 目标上既没有 `stderr` 也没有文件系统，默认实现等于空操作。
2. **会拉进 `std.fmt`**。`std.fmt` 的格式化是一大坨代码（浮点、宽度、对齐、Unicode……），为了打一行 `[I] hello` 而把它链进一个 SRAM-only 的镜像，性价比是负的。本章的镜像里没有任何 `std.fmt` 的代码。
3. **panic 路径要极简**。崩溃时我们要打印五个十六进制数。用 `std.fmt` 意味着 panic 路径依赖一个可能自己就出问题的格式化器；而 `putHex32` 只有十几行，可以被逐行审阅。

### 4. 编译期裁剪：更激进的省法

现在的实现是“运行期判断级别”，字符串常量始终在 `.rodata` 里。如果镜像尺寸紧张，可以把级别改成编译期常量：

```zig
const compile_max: Level = .info;   // 改成 .warn 就整体裁掉 info
pub fn msg(comptime l: Level, comptime text: [:0]const u8) void {
    if (comptime @intFromEnum(l) > @intFromEnum(compile_max)) return;  // 编译期展开成空
    ...
}
```

此时被裁掉的调用点连字符串都不会进镜像。本章保留运行期版本，理由是“现场可调”比“省几百字节”更重要；这个取舍在缺陷排查和发布固件里会得出相反答案，值得明确写下来而不是偷偷选一个。

---

## 6.7 panic：`mtvec`、现场五个数、以及没有 unwinder

### 1. `mtvec` 的两种模式

RISC-V 的 `mtvec` 低 2 位是模式：

| MODE | 含义                                               | 本章用不用 |
| ---- | -------------------------------------------------- | ---------- |
| 0    | 直接：所有异常/中断都跳到 BASE                     | **用**     |
| 1    | 向量：中断跳到 `BASE + 4 × cause`，异常仍然跳 BASE | 下一章     |
| ≥2   | 保留（S31 的 CLIC 模式另有编码，见 `clic_reg.h`）  | 后续       |

因为 MODE=0 要求 BASE **4 字节对齐**，而 `trapVector` 必须放在一个链接期就能确定的地址上，本章把它放进 `.text.entry`：

```ld
        _image_start = .;
        KEEP(*(.app_desc))        /* 256 字节 esp_app_desc_t */
        . = ALIGN(16);
        _text_start = .;
        KEEP(*(.text.entry))      /* trapVector 在这里，0x2F000100 */
        *(.text .text.*)
```

`ALIGN(16)` 之后的第一项，地址天然是 16 的倍数，满足 4 字节对齐还有余。Zig 侧用 `linksection(".text.entry")` 把函数放进这个输入段：

```zig
export fn trapVector() linksection(".text.entry") callconv(.naked) noreturn { ... }
```

`install()` 只做一件事，外加一道检查：

```zig
pub fn install() void {
    const addr: usize = @intFromPtr(&trapVector);
    if (addr & 0x3 != 0) fatal("mtvec 基址未 4 字节对齐（检查 .text.entry 的放置）");
    asm volatile ("csrw mtvec, %[v]" : : [v] "r" (addr));
}
```

这道检查看着多余——链接脚本明明保证了——但它防的是**链接脚本被人改坏**这种真实故障。低两位非零时硬件会按另一个模式解释 BASE，症状是“异常发生时跳到奇怪的地址”，比直接停机难查一百倍。

### 2. trap 向量：五条指令，为什么要先抓 `ra`

```asm
        csrr    a0, mcause          # 异常原因（bit31=1 表示中断）
        csrr    a1, mepc            # 触发异常的指令地址
        mv      a2, ra              # 触发点的返回地址（call 之前抓）
        csrr    a3, mtval           # 附加信息（非法指令编码 / 出错地址）
        mv      a4, sp              # 当时的栈指针
        call    trapReport          # 普通函数：打印 + 停机
```

三个要点：

- **`ra` 必须在 `call` 之前抓**。`call` 会把返回地址写进 `ra`，一旦调用，触发点的 `ra` 就永久消失。这也解释了为什么这一层必须是 naked 函数：普通函数的序言会先 `addi sp, sp, -16` 并 `sw ra, 12(sp)`，`ra` 与 `sp` 两个现场标记都会被破坏。
- **不保存现场**。这条路径不返回，所以不需要保存/恢复任何寄存器——这正是 panic 路径与中断路径的分界：中断必须恢复，panic 只需要记录。
- **`mtval` 因异常类型而异**：非法指令时是那条指令的编码，访问错误时是出错地址，地址未对齐时是出错的地址。打印它，很多问题一眼就能定位（例如 `mtval=0x00000000` 配合 `mcause=2`，说明执行到了全零指令）。

### 3. `mcause` 的读法

异常/中断编号在低 31 位，最高位区分类型：

| `mcause` | 名称                           | 典型原因                                     |
| -------- | ------------------------------ | -------------------------------------------- |
| 0        | instruction address misaligned | 跳到奇数地址（`ra` 被写坏、函数指针为 0）    |
| 1        | instruction access fault       | 取指越界、访问了未使能的区域                 |
| 2        | illegal instruction            | 执行到全零指令、缺扩展的指令、CSR 不可用     |
| 3        | breakpoint                     | `ebreak`                                     |
| 4        | load address misaligned        | 非对齐读（例如把 `u32` 指到奇数地址）        |
| 5        | load access fault              | 解引用空指针、读未初始化外设                 |
| 6        | store/AMO address misaligned   | 非对齐写                                     |
| 7        | store/AMO access fault         | 写只读区、写不存在的地址                     |
| 11       | environment call from M-mode   | `ecall`（本章不用）                          |
| bit31=1  | 中断                           | 本章 `mie=0`，不该出现；出现说明有人开了中断 |

`trapReport` 把编号翻译成名字再打印，同时保留原始十六进制值——名字方便扫读，原始值方便贴进 issue：

```text
[E] ---- trap ----
cause : illegal instruction
mcause=0x00000002
mepc  =<触发指令地址>
ra    =<触发点的返回地址>
mtval =0x00000000
sp    =<当时的栈指针>
[E] halted: 需要复位（EN）或重新烧录
```

尖括号处**必须由真机填实测值**，不是示例数据：三个地址都取决于链接结果与运行路径，用 `nm -n` 与 `objdump -d` 交叉核对。可判定的只有两条——`mcause` 必须恰好是 `0x00000002`，`mtval` 必须是 `0`（全零指令的编码）。

### 4. 为什么不做栈回溯

栈回溯要靠 `.eh_frame`（异常表）或者帧指针链：

- `.eh_frame` 需要编译器生成 unwind 信息，而 freestanding + `-fno-exceptions` 语义的构建里没有它；就算有，解 `.eh_frame` 的代码本身也是几百行的状态机。
- 帧指针需要 `-fno-omit-frame-pointer`，会让每个函数多两条指令和一个寄存器——在 SRAM 只有 512 KB、还要跑满 320 MHz 的场景里，这是长期的税，只为了一次崩溃打印。

所以本章只给**两个一定正确**的量：`ra`（触发点所在函数的返回地址）与 `sp`（当时的栈顶）。配合 `mepc`，通常已经够判断“崩在哪个函数附近、栈有没有被踩穿”。真要完整回溯，正确工具是 JTAG/OpenOCD：它读的是内存里的真实栈，不需要固件里猜帧布局。

### 5. `trapDemo()`：唯一一个可预期的崩溃

```zig
pub fn trapDemo() noreturn {
    log.msg(.warn, "trap demo: 即将执行 0x00000000（非法指令），板子会停机，需复位");
    asm volatile (".4byte 0x00000000");
    halt();
}
```

选全零指令而不是别的，是因为 RISC-V 规范把**全零指令永久保留为非法指令**：它一定触发 `mcause = 2`，`mepc` 一定指向它自己，`mtval` 一定是 0。这种“结果完全确定”的异常，才适合当测试用例。

三个约束：

- 只挂在串口命令 `t` 上，**不随启动自动执行**——自动执行会让上电流程变成“每次都崩一次”，反而破坏启动链的可观测性；
- 演示前先打印一行警告并说明“会停机、需复位”，否则使用者会以为固件坏了；
- 触发后 `halt()`（`wfi` 死循环）而不是 `unreachable`。`unreachable` 在 `ReleaseSmall` 下允许优化器假设“不会发生”，一旦假设错了就是未定义行为；`wfi` 死循环是确定的。

### 6. 为什么不用 `@panic`

Zig 的 `@panic` 最终走到 `std.debug` 的 panic 实现，它需要一个 stderr writer 与 `std.fmt`；在 freestanding 目标上这两样都不成立。所以本章定义自己的统一停机点：

```zig
pub fn fatal(comptime text: [:0]const u8) noreturn {
    log.msg(.err, text);
    halt();
}
```

它也用在 `install()` 的对齐检查里——**“无法继续”只有一种处置方式**，这让所有失败路径的行为一致、可预期。

---

## 6.8 WS2812 与 RMT：边界在哪

### 1. 为什么 GPIO60 不能“当普通 GPIO 点”

板载的可寻址 RGB LED 挂在 GPIO60 上，是 WS2812 类**单线归零码**器件。它没有时钟线，每一位靠高电平的**宽度**编码（典型值，以板载器件手册为准）：

| 符号   | 含义       | 典型值           |
| ------ | ---------- | ---------------- |
| `T0H`  | 0 码高电平 | 0.35–0.5 µs      |
| `T1H`  | 1 码高电平 | 0.65–0.95 µs     |
| `T0L`  | 0 码低电平 | 0.8–1.0 µs       |
| `T1L`  | 1 码低电平 | 0.2–0.4 µs       |
| 位周期 | `TH + TL`  | 1.25 µs ± 600 ns |
| 复位   | 低电平保持 | > 50 µs          |

把 CPU 频率代进去，误差预算是这样的：320 MHz 下 1 个周期 = 3.125 ns，0.4 µs ≈ 128 个周期。若器件的容差是 ±150 ns，那么允许的抖动只有 **±48 个周期**。一帧 24 位（8 位 × 3 通道）要在 30 µs 内发完，每一位都不能错——错一位，颜色就整片偏掉。

在这个预算下，软件拼波形的三个天敌：

1. **中断**。任何一个 ISR 进来，波形立刻多出几十到几百个周期。这也是为什么真正的 WS2812 驱动要么关中断，要么交给硬件。
2. **Cache 与总线**。取指 miss、总线仲裁都会造成不规则的延迟；第四章的布局是全 SRAM 无 cache，但在 SRAM 里仍有总线争用。
3. **编译器调度**。一段“写高、延时、写低”的循环，优化器完全可以把写操作重排、把延时的循环展开或删除（没有 `volatile` 时），`volatile` 能挡住重排，但挡不住“分支与循环本身的开销”。

结论很硬：**普通 GPIO 推挽输出能翻转电平，但拼不出可靠的归零码波形**。本章的 GPIO5 演示引脚只做 1 Hz 方波（周期 1 秒），误差预算是毫秒级，任何实现都能满足；这正是“先把观测通道做对，再谈时序敏感的外设”的顺序。

### 2. RMT 是这类器件的正确答案

S31 有 RMT（Remote Control Transceiver），基址 `0x20355000`，通道 RAM 在 `0x20355800`（IDF v6.1 `esp32s31.peripherals.ld` 的 `RMT` / `RMTMEM`）。它的工作方式是：

```text
CPU 一次性写好“电平 + 持续多少个时钟周期”的项序列
        ↓
RMT 硬件按项计时，逐位输出，CPU 去干别的
        ↓
发送完成中断（可选）
```

一旦位时序由硬件计时器产生，“中断抖动”“编译期调度”这两个变量就消失了。代价是要学一套新寄存器（通道配置、时钟分频、RAM 写入、发送启动），这也是它没有被塞进本章的原因：本章的目标是把**观测与诊断**这套地基打好，WS2812 只是它的下游用户。

### 3. 本章明确不做的三件事

- **不写 RMT 寄存器**。没验证过的寄存器序列写进文档，比不写更糟。
- **不声称 GPIO60 能亮**。用 `gpio.configureOutput(60)` 之后你会看到引脚电平变化，但 LED 只会显示“随机颜色”或者干脆不亮——那是归零码被当成普通电平的结果，不是“快成功了”。
- **不用忙等凑时序**。即使暂时关中断，`esp_rom_delay_us` 的粒度也不足以稳定产生 0.4 µs/0.8 µs 的差别（ROM 的延时函数以微秒为单位，且自身有调用开销）。

RMT 驱动 WS2812 会在后续章节作为独立工程落地，届时本章的 `log`、`panic`、GPIO 配置都会直接复用。

---

## 6.9 工程走读

工程在 `practice/zig-esp32-s31/ch06-gpio-uart-log/`，共 14 个文件（含 README）：

```text
ch06-gpio-uart-log/
├── build.zig                  # 目标串 + 链接脚本 + app.elf（与 ch04 相同）
├── linker/s31.ld              # .text.entry 承载 trap 向量；其余同 ch04
├── src/
│   ├── start.zig              # app_desc（256 B）+ naked _start（五步不变）
│   ├── main.zig               # 横幅 / 装 mtvec / 配 GPIO / 主循环
│   ├── uart.zig               # TX 走 ROM；RX 轮询；128 B 环形缓冲
│   ├── gpio.zig               # IO_MUX + GPIO 输出/输入
│   ├── log.zig                # 四级日志
│   └── panic.zig              # trapVector / trapReport / fatal / halt / trapDemo
├── idf-bootstrap/             # 只产 bootloader + 分区表（同 ch04）
│   ├── CMakeLists.txt
│   ├── sdkconfig.defaults
│   └── main/{CMakeLists.txt,app_main.c}
├── tools/flash.sh             # 读 flash_args、替换应用行
└── README.md
```

| 文件                               | 代码浏览                                                                                 |
| ---------------------------------- | ---------------------------------------------------------------------------------------- |
| `build.zig`                        | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/build.zig)                        |
| `linker/s31.ld`                    | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/linker/s31.ld)                    |
| `src/start.zig`                    | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/start.zig)                    |
| `src/main.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/main.zig)                     |
| `src/uart.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/uart.zig)                     |
| `src/gpio.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/gpio.zig)                     |
| `src/log.zig`                      | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/log.zig)                      |
| `src/panic.zig`                    | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/panic.zig)                    |
| `idf-bootstrap/CMakeLists.txt`     | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/idf-bootstrap/CMakeLists.txt)     |
| `idf-bootstrap/main/app_main.c`    | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/idf-bootstrap/main/app_main.c)    |
| `idf-bootstrap/sdkconfig.defaults` | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/idf-bootstrap/sdkconfig.defaults) |
| `tools/flash.sh`                   | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/tools/flash.sh)                   |

### 1. 与第四章的差异只有三处

| 项              | ch04                 | ch06                                    |
| --------------- | -------------------- | --------------------------------------- |
| `build.zig`     | 一个可执行、链接脚本 | **不变**（新模块由 `@import` 自动进图） |
| `linker/s31.ld` | `.text.entry` 空置   | 承载 `trapVector`（语义变化，字节不变） |
| `src/start.zig` | 五步启动             | **步骤不变**，只改应用描述里的版本串    |
| 新增            | —                    | `main/uart/gpio/log/panic` 五个文件     |

刻意不动启动代码，是一个**方法论选择**：本章引入的全部是“运行期行为”，一旦启动顺序也改了，出问题就分不清是“外设配错”还是“启动崩了”。第四章已经验证过的那二十条指令，继续原样保留。

### 2. `main.zig`：主循环的节奏就是设计

```zig
    while (true) {
        esp_rom_delay_us(slice_us);          // 1 ms
        _ = rx_ring.drainFromFifo();         // 搬一次 FIFO
        handleInput();                        // 回显 / 解析命令

        slices += 1;
        if (slices >= slices_per_toggle) {   // 500 片 = 500 ms
            slices = 0;
            gpio.toggle(demo_pin);
            toggles +%= 1;
            if (toggles % toggles_per_heartbeat == 0) {
                log.dec2(.info, "toggles", toggles, "rx drops", rx_ring.drops);
            }
        }
    }
```

四件事按优先级排列，每一件都能独立观察：

1. **先搬 FIFO**（每 1 ms），保证接收不丢；
2. **再处理命令**，保证回显延迟在一两个毫秒内；
3. **后翻转引脚**（每 500 片），1 Hz 方波；
4. **每 4 次翻转打一行心跳**（约 2 秒），把 `drops` 暴露出来。

如果反过来写成“睡 500 ms 再翻转、顺便搬一次 FIFO”，接收窗口就变成 500 ms，128 字节的缓冲在一秒内必溢出——**轮询版驱动的采样频率是主循环结构的一部分**，不能当成“随手插一句”的细节。

### 3. 命令集：只有三个字母

| 输入 | 行为                                                       |
| ---- | ---------------------------------------------------------- |
| `?`  | 打印帮助一行                                               |
| `p`  | 打印 `rx queued` / `rx drops` / `tx fifo` / `rx fifo` 四行 |
| `t`  | trap 演示：打印警告 → 执行全零指令 → 停机（需复位）        |
| 其它 | 原样回显（`\r`/`\n` 转成 `\r\n`，让终端换行正常）          |

命令集刻意做成“一字节一动作”，不做行编辑、不做历史。理由：**行编辑属于“应用层”，本章要验证的是“传输层”**。等下一章中断就绪，把 `handleInput` 从轮询改成 ISR 通知，命令解析的代码一行都不用动。

### 4. `trapVector` 的符号位置怎么核对

```bash
riscv32-esp-elf-nm -n zig-out/bin/app.elf | grep -E '_image_start|_text_start|trapVector| _start$| main$'
```

期望的**相对**关系（绝对地址以实际链接结果为准）：

```text
0x2f000000 _image_start   ← .app_desc 起点（ORIGIN(sram)）
0x2f000100 _text_start    ← ALIGN(16) 之后（0x2F000000 + 256）
0x2f000100 trapVector     ← .text.entry 的第一项，必须与 _text_start 相等
（其后）   _start          ← 在 .text 内，具体地址读 nm -n
（其后）   main            ← 同上，符号类型必须是 T
```

`trapVector` 与 `_text_start` 相等这件事，就是“`mtvec` 指向 16 字节对齐地址”的证据。若 `trapVector` 出现在 `.text` 中间（比如 0x2f0001c4），说明 `linksection` 没生效——此时它仍然 4 字节对齐（RISC-V 指令对齐），本章的功能不受影响，但“入口段固定”的意图就丢了。

---

## 6.10 构建、烧录与验收

### 1. 三条命令

```bash
cd practice/zig-esp32-s31/ch06-gpio-uart-log

# ① 应用 ELF：纯 Zig，没有 idf.py
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

# ② 应用镜像
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

# ③ bootloader + 分区表（供应商步骤）
cd idf-bootstrap && idf.py --preview set-target esp32s31 && idf.py build && cd ..
sh tools/flash.sh COM7        # Linux 用 /dev/ttyUSB0
```

`zicsr` 在这一章从“顺手加的”变成了**必需**：`csrw mtvec`、`csrr mcause`、`_start` 里的 `csrci mstatus` 全靠它。漏了它，编译期就会在第一条 CSR 指令上报错。

### 2. 静态证据（主机上就能做）

| 检查              | 命令                                                     | 期望                                                |
| ----------------- | -------------------------------------------------------- | --------------------------------------------------- |
| 入口 == `_start`  | `readelf -h` 的 entry 与 `nm` 的 `_start`                | 两者相等                                            |
| `trapVector` 位置 | `nm -n app.elf`                                          | 等于 `_text_start`（`0x2F000100` 一带）             |
| 段 #0 带应用描述  | `od -A x -t x1z -j 32 -N 4 zig-out/bin/app.bin`          | `32 54 cd ab`（`0xABCD5432` 小端）                  |
| ROM 符号已解析    | `nm app.elf \| grep -E 'esp_rom_(printf\|delay_us)'`     | 两个绝对地址（不是 `U`）                            |
| 镜像字段          | `esptool --chip esp32s31 image-info zig-out/bin/app.bin` | 魔数 `0xE9`、段数 2、entry 正确、校验与 SHA256 有效 |
| `mtvec` 写入指令  | `objdump -d app.elf \| grep -A2 csrw`                    | `install()` 里能看到 `csrw mtvec`                   |
| 无 `std.fmt` 痕迹 | `nm app.elf \| grep -ci 'fmt'`                           | 0（本章的格式化全是手写的）                         |

### 3. 串口验收：要看到什么

> [!info] 下面是 2026-11-13 的实测输出（完整见 `../logs/ch06-trap.log`）
> 二级 bootloader 的日志行数随 IDF 版本变化，以实际串口为准；trap 现场为真机原文。

```text
（二级 bootloader 自己的日志：版本、Flash 模式/大小、分区表、镜像校验）

[I] ch06-gpio-uart-log | form B (Zig ELF + IDF 2nd-stage bootloader)
[I] console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
[I] demo gpio=5
[I] gpio: IO_MUX MCU_SEL=1 + OUT_SEL=256 + ENABLE=1（真机实测）
[I] type ? for help; input is polled, not interrupt driven
[I] ?  help / p  counters / t  trap demo (halts until reset)
[I] toggles=4 rx drops=0
[I] toggles=8 rx drops=0
```

逐条验收：

| 观察点        | 判据                                                    | 说明                                   |
| ------------- | ------------------------------------------------------- | -------------------------------------- |
| 横幅          | 恰好一次，且在所有 `toggles=` 之前                      | TX 链路通                              |
| 行首标记      | `[I]`、`[E]`、`[W]`、`[D]` 与级别对应                   | `log.zig` 生效                         |
| `demo gpio=5` | 与 `main.zig` 的 `demo_pin` 一致                        | 十进制打印器正确（排除 `%d` 符号问题） |
| 回显          | 任意可打印字符被原样打回                                | RX 搬运 + 环形缓冲 + TX 全通           |
| `p` 的四行    | `rx queued` / `rx drops` / `tx fifo` / `rx fifo` 都有数 | 状态寄存器读得对                       |
| 心跳          | 每约 2 秒一行，`toggles` 每次 +4                        | 主循环节奏                             |
| `rx drops`    | 打字时保持 0（狂粘贴可能非 0）                          | FIFO 没溢出                            |
| `t` 的 trap   | `---- trap ----` + `mcause=0x00000002` + `mepc` 非零    | `mtvec` + 现场打印可用                 |
| `t` 之后      | 板子停机，按 EN 后重新出现横幅                          | panic 路径没有破坏启动链               |
| 示波器        | 演示引脚 1 Hz 方波，占空比约 50%                        | IO_MUX + GPIO 配置正确                 |

### 4. 证据状态表

| 检查项                          | 证据                                     | 状态             |
| ------------------------------- | ---------------------------------------- | ---------------- |
| 目标能力（`zicsr` 等）          | 系列 2026-11-12 的 `--show-builtin` 实测 | 已验证（系列级） |
| 寄存器地址与位域                | IDF v6.1 `esp32s31` 头文件（见事实来源） | 已核对（源码级） |
| 应用 ELF / 镜像产出             | `zig build` → `elf2image`                | 待首次构建回填   |
| `trapVector` 位于 `.text.entry` | `nm -n`                                  | 待首次构建回填   |
| 段 #0 应用描述                  | `od -j 32 -N 4`                          | 待首次构建回填   |
| 启动横幅与心跳                  | UART0 115200 8N1                         | 待真机验证       |
| 字符回显与 `p`/`?` 命令         | 同上                                     | 待真机验证       |
| `t` 的 trap 现场                | `mcause=0x00000002`                      | 待真机验证       |
| 演示引脚 1 Hz 方波              | 示波器 / 逻辑分析仪                      | 待真机验证       |
| 演示引脚是否真在 J2 上          | 板卡原理图（本仓未收录）                 | 待真机验证       |

---

## 6.11 排错

### 1. 现象 → 层 → 处置

| 现象                                  | 最可能的层              | 根因与处置                                                                 |
| ------------------------------------- | ----------------------- | -------------------------------------------------------------------------- |
| 连 bootloader 日志都没有              | 烧录/镜像               | 检查 `flash_args` 是否被正确替换、`--flash-mode dio` 是否与模组一致        |
| bootloader 日志有，应用无输出         | 启动链（形态 B 老问题） | 查 entry == `_start`、`nm` 里 `main` 是否为 `T`、`objdump` 前 20 条指令    |
| 横幅出现但每个字符都变成 `?` 或方块   | 主机侧                  | 终端编码/波特率；`115200 8N1`，与 ROM 默认一致                             |
| 横幅正常、键盘无反应                  | RX 层                   | 确认接的是 GPIO59（UART0 RX）；`p` 里 `rx fifo` 是否始终 0                 |
| 回显了，但字符乱                      | 帧层                    | 波特率不匹配、TX/RX 接反；`p` 里若 `FRM_ERR` 置位优先怀疑这两条            |
| `p` 里 `rx drops` 持续增长            | 主循环节奏              | 单片延时太长或有阻塞打印；缩短 `slice_us` 或减少日志                       |
| `t` 无任何输出且板子像死机            | trap 层                 | `mtvec` 未装上，或 `trapVector` 落在不可执行区域；先看 `debug` 级 `mtvec=` |
| `t` 打出 `mcause=0x00000006` 之类     | trap 层（意外）         | 说明不是全零指令引发：检查是否改过 `trapDemo`，或栈已被踩穿                |
| 演示引脚无波形                        | GPIO 层                 | 按 6.2 第 5 节的顺序查：`ENABLE` → `FUN_IE` → `MCU_SEL` → `OUT_SEL`        |
| 引脚电平正确但读回不对                | GPIO 层                 | `FUN_IE` 没开（`GPIO_IN` 靠输入缓冲器）；或被外部器件拉住                  |
| 提示 `undefined symbol: main`         | 构建                    | `export` 丢了；`start.zig` 的 `_ = &app.main;` 被删                        |
| 提示 `expected type 'u5', found 'u6'` | 构建                    | 移位量类型：`u32 << u6` 不合法，先 `@intCast` 到 `u5`（见 `gpio.zig`）     |
| 串口出现一堆 `%s` 之后的垃圾字符      | 构建                    | 把 `[]const u8` 切片传给了 `%s`；要用 `[*:0]const u8`                      |

### 2. 两条原则

1. **先验证通道，再验证功能**。横幅 → 回显 → 命令 → 引脚，每一级都独立成立再往下走。跳过“回显”直接调 `t`，你会在一个不知道 RX 是否可用的系统上诊断 trap。
2. **一次只改一个变量**。波特率、引脚号、日志级别、`slice_us` 同时改，最后无法归因；本章的验收表就是按“单变量”排的。

---

## 6.12 下一章预告：中断与向量表

本章的 `mtvec` 只接了**异常**，而且故意关着所有中断。这留下三个悬空的问题，正好是下一章的主线：

- **`mtvec` 的另一种模式**。S31 有 CLIC（`components/soc/esp32s31/include/soc/clic_reg.h`），中断的向量表、优先级、嵌套规则与 MODE=0 完全不同；
- **中断从哪来**。外设的中断源要经**中断矩阵**（`interrupt_core0_reg.h` 一类寄存器）路由到 CPU 通道，`mie` 只是最后一道闸；本章 `drainFromFifo` 缺的就是这条链路；
- **ISR 的契约**。进入 ISR 要保存什么、`mepc` 要不要加 4、什么时候清中断标志、能不能在里面打印（不能——ROM printf 是阻塞的，会把中断延迟推到毫秒级）。

下一章会把本章的轮询路径原样保留，在旁边加上中断路径，然后用 `p` 命令对比两者的 `rx drops` 与延迟——同一个数据结构、两个生产者，这是验证中断是否真的接对了最直接的办法。

---

## 事实来源

| 事实                                                                                                                                                                      | 来源                                                                                                                                                                                                                                                         | 备注                                                     |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------- |
| S31：双核 RV32IMAF C @320 MHz、512 KB SRAM、320 KB ROM、16 MB Flash + 16 MB PSRAM                                                                                         | [Espressif ESP32-S31 产品页](https://www.espressif.com/en/products/socs/esp32-s31)                                                                                                                                                                           | 与系列索引一致                                           |
| GPIO 编号 0..62                                                                                                                                                           | [IDF v6.1 `gpio_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/gpio_reg.h)（最后一个引脚寄存器为 `GPIO_PIN62_REG`）                                                                                             | 63 个引脚                                                |
| 外设基址：`UART0 = 0x2038A000`、`RMT = 0x20355000`、`RMTMEM = 0x20355800`、`LP_UART = 0x20810000`                                                                         | [IDF v6.1 `esp32s31.peripherals.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/ld/esp32s31.peripherals.ld)                                                                                                                      | 链接片段里的 `PROVIDE ( ... = 0x... )`                   |
| `DR_REG_IO_MUX_BASE = 0x20582000`、`DR_REG_GPIO_BASE = 0x20583000`、`REG_UART_BASE(i) = DR_REG_UART_BASE + i*0x1000`                                                      | [IDF v6.1 `reg_base.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/reg_base.h)、[`soc.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/soc.h)                                 | 本章所有寄存器地址的根                                   |
| IO_MUX 每引脚寄存器偏移 = `pin × 4`；`MCU_SEL`[14:12]、`FUN_IE` bit9、`FUN_PU` bit8、`FUN_PD` bit7；`PIN_FUNC_GPIO = 1`                                                   | [IDF v6.1 `io_mux_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/io_mux_reg.h)                                                                                                                                  | GPIO2→0x8、GPIO5→0x14、GPIO58→0xe8、GPIO62→0xf8 逐一吻合 |
| `GPIO_OUT_W1TS/W1TC`、`GPIO_ENABLE_W1TS/W1TC`、`GPIO_IN`、`GPIO_STATUS` 的偏移                                                                                            | [IDF v6.1 `gpio_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/gpio_reg.h)                                                                                                                                      | 0x8/0xc、0x38/0x3c、0x64、0x74                           |
| `GPIO_FUNCn_OUT_SEL_CFG = 0xaf4 + 4n`；`OUT_SEL`[8:0] 复位值 256；256 = 由 `GPIO_OUT`/`GPIO_ENABLE` 位驱动                                                                | [IDF v6.1 `gpio_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/gpio_reg.h)（字段注释）                                                                                                                          | 与 `SIG_GPIO_OUT_IDX = 256` 一致                         |
| `SIG_GPIO_OUT_IDX = 256`、`GPIO_MATRIX_CONST_ONE_INPUT = 0x80`、`..._ZERO_INPUT = 0xC0`                                                                                   | [IDF v6.1 `gpio_sig_map.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/gpio_sig_map.h)、[`gpio_pins.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/gpio_pins.h)              | 常量输入用高两位编码                                     |
| UART 寄存器偏移：FIFO 0x0、INT_RAW 0x4、INT_ENA 0xc、INT_CLR 0x10、CLKDIV_SYNC 0x14、RX_FILT 0x18、STATUS 0x1c、CONF0_SYNC 0x20、CONF1 0x24、MEM_CONF 0x60、CLK_CONF 0x88 | [IDF v6.1 `uart_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/uart_reg.h)                                                                                                                                      | 本章只碰 FIFO/STATUS/INT_RAW 三个                        |
| `BIT_NUM`[3:2] 复位 3 = 8 位、`STOP_BIT_NUM`[5:4] 复位 1 = 1 位、`PARITY_EN` 复位 0 → 8N1 是复位默认                                                                      | 同上（`UART_CONF0_SYNC_REG` 字段注释含 0..3 的取值表）                                                                                                                                                                                                       | 解释“ROM printf 为什么不用配帧格式”                      |
| `CLKDIV`[11:0] 复位 694、`CLKDIV_FRAG`[23:20]                                                                                                                             | 同上（`UART_CLKDIV_SYNC_REG`）                                                                                                                                                                                                                               | 694 × 115200 ≈ 79.95 MHz，推断 UART 时钟 ~80 MHz         |
| `RXFIFO_CNT`[7:0]、`TXFIFO_CNT`[23:16]、`RXD`[15]、`TXD`[31]                                                                                                              | 同上（`UART_STATUS_REG`）                                                                                                                                                                                                                                    | 轮询判据                                                 |
| `RXFIFO_RD_BYTE`[7:0]                                                                                                                                                     | 同上（`UART_FIFO_REG`）                                                                                                                                                                                                                                      | 读 FIFO 的低 8 位就是数据                                |
| `RXFIFO_FULL_THRHD` 复位 96、`TXFIFO_EMPTY_THRHD` 复位 96                                                                                                                 | 同上（`UART_CONF1_REG`）                                                                                                                                                                                                                                     | 推断 FIFO 深度 ≥ 96；历史芯片 128，S31 以 TRM 为准       |
| `RXFIFO_FULL` bit0、`FRM_ERR` bit3、`RXFIFO_TOUT` bit8                                                                                                                    | 同上（`UART_INT_RAW/ST/ENA/CLR` 段）                                                                                                                                                                                                                         | 本章只读 `INT_RAW` 的 `FRM_ERR`                          |
| UART0 引脚：`U0TXD_GPIO_NUM = 58`、`U0RXD_GPIO_NUM = 59`、`U0TXD_MUX_FUNC = 0`                                                                                            | [IDF v6.1 `uart_pins.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/uart_pins.h)                                                                                                                                     | 与板上 USB-UART 桥一致                                   |
| ROM 符号 `ets_printf = 0x2f800024`、`ets_delay_us = 0x2f80003c`；别名 `esp_rom_printf`/`esp_rom_delay_us`                                                                 | [IDF v6.1 `esp32s31.rom.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.ld)、[`esp32s31.rom.api.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.api.ld)      | 链接脚本 `PROVIDE` 两个绝对地址                          |
| `mtvec` 模式编码、`mcause` 编号表、`wfi` 语义                                                                                                                             | [RISC-V Privileged Architecture](https://github.com/riscv/riscv-isa-manual/releases)                                                                                                                                                                         | MODE=0 直接模式、BASE 需 4 字节对齐                      |
| 全零指令永久保留为非法指令                                                                                                                                                | [RISC-V Unprivileged ISA](https://github.com/riscv/riscv-isa-manual/releases)                                                                                                                                                                                | `trapDemo()` 用 `.4byte 0x00000000` 的可预期性依据       |
| `esp_app_desc_t` 256 字节、魔数 `0xABCD5432`、bootloader 要求段 #0 携带                                                                                                   | [IDF v6.1 `esp_app_desc.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_app_format/include/esp_app_desc.h)、[`esp_image_format.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/bootloader_support/src/esp_image_format.c)    | 第四章已逐字段拆过，本章沿用                             |
| 分区表 `0x8000`、factory 应用 `0x10000`、bootloader `0x2000`                                                                                                              | [IDF 分区表指南（ESP32-S31）](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s31/api-guides/partition-tables.html)                                                                                                                               | `flash_args` 是偏移的唯一来源                            |
| `esp32s31` 是 IDF v6.1 preview target                                                                                                                                     | [practice/onvif-labs/SPEC.md](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)、[[ch11-esp32s31-lab-plan\|ONVIF 第十一章]]                                                                                                       | `set-target`/`list-targets` 必带 `--preview`             |
| S31 有 CLIC（`clic_reg.h`）与中断矩阵（`interrupt_core0_reg.h`）                                                                                                          | [IDF v6.1 `clic_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/clic_reg.h)、[`interrupt_core0_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/interrupt_core0_reg.h) | 下一章的主线，本章不配                                   |
| WS2812 类归零码时序（T0H/T1H/周期/复位）                                                                                                                                  | 器件手册（板载型号待确认），典型值 T0H 0.35–0.5 µs、T1H 0.65–0.95 µs、周期 1.25 µs、复位 >50 µs                                                                                                                                                              | 「待真机验证」：以板载器件手册与示波器实测为准           |
| `callconv(.naked)` 的函数体只能是一个 `asm`；`linksection` 放在 `callconv` 之前                                                                                           | [Zig 0.17 语言参考](https://ziglang.org/documentation/0.17.1/)                                                                                                                                                                                               | `_start` 与 `trapVector` 都依赖它                        |

## 自查清单

进入下一章前，确认能回答这些问题：

- [ ] IO_MUX、GPIO 外设、GPIO 矩阵各管什么？为什么"矩阵没配、GPIO_OUT 写了也没用"？
- [ ] IO_MUX 的偏移为什么是 `pin × 4`？GPIO0/1 的"例外"例外在哪？
- [ ] `OUT_SEL = 256` 的含义是什么？它的复位值已经是 256，为什么代码还要写一遍？
- [ ] 输出配置的四步为什么要按"选功能 → 选信号 → 定电平 → 开使能"排列？换个顺序会看到什么毛刺？
- [ ] 为什么读电平要读 `GPIO_IN` 而不是 `GPIO_OUT`？为什么输出引脚也要开 `FUN_IE`？
- [ ] S31 的 UART 帧格式"复位即 8N1"是哪三个位域的复位值共同决定的？
- [ ] `CLKDIV` 复位值 694 与 115200 能反推出什么？为什么说这是"算术推断"而不是手册结论？
- [ ] FIFO 深度"至少 96"是从哪个寄存器的复位值推出来的？它如何决定本章的轮询节奏？
- [ ] 为什么命令行输入更依赖 `RXFIFO_TOUT` 而不是 `RXFIFO_FULL`？
- [ ] TX 为什么先借 ROM 的 `printf`？这条选择在排错时保留了哪个强假设？
- [ ] 为什么 `%s` 的实参必须是 `[*:0]const u8`？传 `[]const u8` 会发生什么？
- [ ] 环形缓冲为什么取 2 的幂、为什么用单调 `u32` 而不是回绕索引？满时为什么丢新不丢旧？
- [ ] 从轮询改成中断，缺的是哪三件事？为什么 `drainFromFifo` 本身不用改？
- [ ] `mtvec` 的 MODE=0 对 BASE 有什么要求？本章怎么保证？那道运行时检查在防什么？
- [ ] `trapVector` 为什么必须先 `mv a2, ra` 再 `call`？普通（非 naked）函数会破坏哪两个现场标记？
- [ ] `mcause = 2`、`mtval = 0`、`mepc` 指向全零字——这三条如何互相印证？
- [ ] 为什么不做栈回溯？真要做该用什么工具？
- [ ] `trapDemo` 为什么用全零指令，而不是随便写一条非法编码？为什么它不随启动自动执行？
- [ ] GPIO60 上的 RGB LED 为什么不能当普通 GPIO 点？算一下 ±150 ns 在 320 MHz 下是多少个周期。
- [ ] 本章的日志为什么不用 `std.log`？运行期级别与编译期裁剪各自的取舍是什么？

---

下一章把本章故意留着的那道闸打开：`mtvec` 的 CLIC 模式、中断矩阵的路由、`mie` 与 `mstatus.MIE` 的打开顺序，以及一个 ISR 的契约（保存什么、`mepc` 要不要 +4、标志在哪清、为什么不能在 ISR 里打印）。本章的轮询路径会原样保留，作为中断路径的对照基线——同一个 `RingBuffer`，两个生产者，用 `rx drops` 与延迟说话。

系列导航：[[ch05-clock-reset-watchdog|上一章]] · [[zig-esp32-s31|系列索引]]
