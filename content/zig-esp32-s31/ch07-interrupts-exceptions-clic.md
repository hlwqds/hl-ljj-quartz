---
title: "Zig × ESP32-S31 全栈开发（七）：中断、异常与 CLIC"
date: 2026-11-15 12:00:00
description: "把 ch06 的轮询接收换成中断：先拆开 trap 入口的五个 CSR 与一次 mret，讲清 mtvec 直接模式与 CLIC 向量模式（mtvt/mode 3）的分界；再把 48 个 CLIC 输入、8 个优先级、169 个矩阵源接成一张可查的分发表，用 UART0 RX 与 SYSTIMER 1 kHz 两个真中断验证；最后用保存/恢复 MIE 的可嵌套临界区，以及 CLIC 阈值版临界区，量出“关中断 5 ms 会丢几个 tick”。"
tags: [zig, esp32-s31, riscv, interrupts, clic, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. [[ch04-linker-memory-layout|第四章：链接脚本与内存布局]]
> 5. [[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]
> 6. [[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]]
> 7. **第七章：中断、异常与 CLIC**
> 8. [[ch08-timers-dma-precision|第八章：定时器、DMA 与精确时序]]

# Zig × ESP32-S31 全栈开发（七）：中断、异常与 CLIC

第六章结尾留了一道闸：`mie = 0`、`mstatus.MIE = 0`、`mtvec` 只接异常不接中断，UART 接收靠主循环每 1 ms 搬一次 FIFO。这一章把闸打开。

打开的方式不是“写几个寄存器把中断使能”，而是**建立一条能返回的控制流**：异常与中断共用一个入口，入口必须保存被打算的上下文、查表、调用处理函数、再原样恢复并 `mret`。任何一步漏掉，症状都不是“中断没进来”，而是“进来之后主程序悄悄算错了”——后者难查得多。

本章的两个真中断是刻意挑的：

- **UART0 接收**：它有“源侧标志”（`RXFIFO_FULL`/`RXFIFO_TOUT`），必须清，属于**电平/超时**语义；
- **SYSTIMER target0，1 kHz**：它在源侧自动重装，属于**周期**语义，正好用来量“关中断会丢几个 tick”。

一个查表分发器同时服务两者，就证明了这张表是通用的，而不是为某一个外设写死的。

> [!warning] 本章的证据边界
> 寄存器地址、位域与复位值全部来自 ESP-IDF v6.1 的 `esp32s31` 头文件与本仓能读到的 IDF 源码（下文逐条给出路径与函数名），S31 的 TRM 仍是 Pre-release v0.7。Zig 侧的写法沿用第四章已建立的目标串与链接脚本。本工程**已于 2026-11-13 真机启动**（`../logs/ch07-boot.log`）：CLIC/CSR 读回正常，但**中断未投递**（`ticks/s=0`、`soft irq=0`），根因待查，详见 `BRINGUP-2026-11-12.md`。

---

## 7.1 轮询的天花板在哪

### 1. 把“1 ms 一片”翻译成数字

第六章的主循环是 `esp_rom_delay_us(1000)` + 一次 `drainFromFifo()`。115200 8N1 下，一个字节占 10 位（起始 + 8 数据 + 停止），所以：

- 位宽 = 1 / 115200 ≈ 8.68 µs；
- 字节率 = 115200 / 10 = 11520 B/s ≈ **11.52 B/ms**；
- 硬件 FIFO 的满阈值 `RXFIFO_FULL_THRHD` 复位值是 **96 字节**（见 6.4），按历史芯片的 128 深度估，余量约 32 字节 ≈ **2.8 ms**。

这三个数字放一起，结论很直接：主循环里**任何一次超过 3 ms 的阻塞**（一次 `printf` 打了 40 个字符 ≈ 3.5 ms、一次 Flash 擦除、一次等 PLL 锁）都会让接收溢出。轮询系统不是“慢”，而是**把采样频率写进了控制流的结构**：你想加一个新功能，先得算它会不会拖过 3 ms。

### 2. 中断换掉的到底是什么

中断不是“更快地轮询”。它换掉的是**责任归属**：

| 维度         | 轮询（ch06）                          | 中断（本章）                               |
| ------------ | ------------------------------------- | ------------------------------------------ |
| 谁来搬 FIFO  | 主循环，按固定节奏                    | 硬件在数据到达时打断 CPU                   |
| 延迟由谁决定 | 主循环最长阻塞时间                    | 中断响应时间 + 更高优先级 ISR 的占用       |
| 加功能的代价 | 每个新功能都要复核“会不会拖过 3 ms”   | 只要 ISR 短，主循环怎么写都不影响接收      |
| 新的风险     | 溢出（可观测：`rx drops`、`FRM_ERR`） | 并发（共享数据要同步）、ISR 里做错事会死锁 |
| 数据结构     | 环形缓冲（SPSC）                      | **同一个**环形缓冲，只是生产者换了         |

最后一行是本章的设计线索：`isr.RxRing` 与 ch06 的 `uart.RingBuffer` 结构完全一致，只多了两样东西——`head`/`tail` 的读要走 volatile，生产与消费之间要插 `fence`。这不是巧合：**中断改造应该只动“谁调用生产者”，不动数据结构**。如果改中断时发现环形缓冲要重写，说明原来的接口把生产者写死了。

### 3. 本章不做什么

- **不做中断嵌套调度**。ISR 里不降阈值，所以同级/低级中断不会在 ISR 内部打断它。CLIC 支持嵌套（阈值是入口），但“谁来嵌套、栈怎么算”是 RTOS 的题（ch10 之后）。
- **不用 CLIC 向量模式**（`mtvec` MODE=3 + `mtvt`）。理由在 7.3，那里会把两条路的差别写清楚，而不是含糊地说“用 CLIC”。
- **不在 ISR 里打印**。TX 走 ROM 的阻塞式 `printf`：打 20 个字符 ≈ 1.7 ms，等于把 1 kHz 的 tick 直接压垮。
- **不碰 DMA、不碰 Flash**（ch08/ch09）。

---

## 7.2 trap 入口：五个 CSR、一次 `mret`

### 1. 硬件在进 trap 时做了什么

RISC-V 的 trap 是**硬件完成一半、软件完成一半**的协议。硬件负责：

| 动作                  | 结果                                         |
| --------------------- | -------------------------------------------- |
| 记录出事/被打断的地址 | `mepc` = 该指令的地址（不是下一条）          |
| 记录原因              | `mcause`：最高位 1 = 中断，低位是原因/中断号 |
| 记录附加信息          | `mtval`：非法指令编码、出错地址、断点地址……  |
| 关中断                | `mstatus.MIE` 清零，`mstatus.MPIE` 保存旧值  |
| 跳到入口              | `pc = mtvec.BASE`（MODE=0）                  |

软件负责剩下的一半：**保存被打算的上下文 → 处理 → 恢复 → `mret`**。`mret` 会把 `pc` 设回 `mepc`、把 `MPIE` 写回 `MIE`。所以在中断路径上**不需要**给 `mepc` 加 4：中断返回的语义就是“回到被打断的那条指令继续执行”。（同步异常才涉及“要不要跳过出错指令”，而本章的异常路径直接停机，不返回。）

### 2. 为什么 `trapVector` 必须保存 16 个寄存器

第六章的 `trapVector` 一条寄存器都没存，因为它**不返回**：打印完就 `wfi`。本章的向量要返回，于是必须遵守调用约定：

- `ra`、`t0`–`t6`、`a0`–`a7` 是 **caller-saved**（易失）：被调用的函数可以随意改写，调用者要自己保存；
- `s0`–`s11` 是 **callee-saved**：`trapDispatch` 及其下游函数会自己保存，向量不用管。

所以最小正确集合就是 **16 个字 = 64 字节**，加上“原始 sp”一个槽位，帧长取 **80 字节**（16 的倍数，保持 ABI 的 16 字节栈对齐）：

| 偏移 | 内容      | 偏移   | 内容         |
| ---- | --------- | ------ | ------------ |
| 0    | `ra`      | 32     | `a0`         |
| 4    | `t0`      | 36     | `a1`         |
| 8    | `t1`      | 40     | `a2`         |
| 12   | `t2`      | 44     | `a3`         |
| 16   | `t3`      | 48     | `a4`         |
| 20   | `t4`      | 52     | `a5`         |
| 24   | `t5`      | 56     | `a6`         |
| 28   | `t6`      | 60     | `a7`         |
| 64   | 原始 `sp` | 68..79 | 未用（对齐） |

```asm
        addi    sp, sp, -80
        sw      ra, 0(sp)
        ...
        sw      a7, 60(sp)
        addi    t0, sp, 80           # 原始 sp
        sw      t0, 64(sp)

        csrr    a0, mcause
        csrr    a1, mepc
        mv      a2, t0
        call    trapDispatch

        lw      ra, 0(sp)
        ...
        lw      a7, 60(sp)
        addi    sp, sp, 80
        mret
```

三个必须写对的细节：

1. **`call` 之前把要用的寄存器全部落到栈上**。`call trapDispatch` 会覆盖 `ra` 与 `t0`–`t6`，之后再想读“被打断时的值”就晚了——这正是第六章强调“先 `mv a2, ra` 再 `call`”的同一条规则，只是本章要保存的寄存器多得多。
2. **恢复顺序无所谓，但 `ra` 与 `sp` 必须在 `addi sp` 之前/之后配好**。`ra` 从帧里恢复，`sp` 用 `addi` 加回去，两者互不依赖。
3. **`mret` 之前不能有 `ret`**。`ret` 用的是 `ra`，会跳回“被中断代码的返回地址”，等于从半路开始执行——这类 bug 的现象是“随机跑飞”，几乎无法归因。

### 3. 分流：中断还是异常

```zig
export fn trapDispatch(cause: u32, mepc: u32, sp: u32) void {
    if ((cause & 0x8000_0000) != 0) {
        const id: clic.Input = @truncate(cause & 0x3F);
        dispatch(id);
        return;                    // 返回，由 trapVector 恢复现场并 mret
    }
    reportException(cause, mepc, sp);
    halt();                        // 异常：打印五个数后停机
}
```

`mcause & 0x3F` 的 6 位从哪里来？两个独立来源互相印证：

- S31 是 CLIC 控制器，中断异常码里放的是 **CLIC 输入号**（0..47），6 位刚好；
- `esp-hal` 的 S31 元数据把 `cpu_mcause_mask` 写成 `0x3f`，与 48 个输入吻合。

这也解释了一个常见困惑：**在 CLIC 系统上，`mcause` 的低位不是 RISC-V 规范里那几个“标准中断编号”（1 = 软件、3 = 定时器、11 = 外部），而是厂商定义的输入号。** 看到 `mcause=0x80000011` 不要去查规范，要去查中断矩阵。

---

## 7.3 直接模式、基本向量模式与 CLIC 向量模式

### 1. `mtvec` 的四种模式

`mtvec` 的低 2 位是模式。第六章给了通用 RISC-V 的 0/1，本章补上 CLIC 实际使用的 3：

| MODE | 含义                                                       | 本章用不用     |
| ---- | ---------------------------------------------------------- | -------------- |
| 0    | 直接：所有异常与中断都跳到 `BASE`                          | **用**         |
| 1    | 基本向量：中断跳到 `BASE + 4 × cause`，异常仍跳 `BASE`     | 不用           |
| 2    | 保留                                                       | —              |
| 3    | CLIC 向量：中断入口取 `mtvt + 4 × 输入号`，异常仍跳 `BASE` | 不用（未验证） |

MODE=3 的依据是 IDF 自己的头文件：`components/riscv/include/riscv/csr_clic.h` 里

```c
#define MTVEC_MODE_CSR  3
#define MTVT_CSR        0x307
```

注释写明：_"Setting mode field to 3 treats `MTVT + 4 _ interrupt_id`as the service entry address for HW vectored interrupts."* 同一个文件还给出`RV_EXTERNAL_INT_COUNT = 32`、`RV_EXTERNAL_INT_OFFSET = 16`、`NLBITS = 3`（阈值与优先级的位宽）。

### 2. 向量模式要付的三笔账

`mtvt` 指向的不是“函数指针数组”，而是**指令数组**：硬件直接跳到 `mtvt + 4 × id` 开始取指。所以：

1. **每项必须是一条完整的 4 字节指令**，通常是 `j handler`；
2. **表必须 64 字节对齐**（CLIC 规范的最低要求，S31 的具体要求待真机确认）；
3. **`j` 的可达范围是 ±1 MB**：处理函数必须落在表附近。形态 B 的布局把 `.text` 放在 `0x2F000000` 起、栈在 SRAM 末尾，目前没问题；但把表放进一个独立段、又把 ISR 放进 flash 映射窗口，就会踩到这条。

还有一个更隐蔽的问题：**向量模式下“未登记输入”没有兜底**。55 号输入挂起时会跳到 `mtvt + 220`，那里可能是任意字节。直接模式下所有输入都进 `trapVector`，可以查表、可以计数、可以关掉肇事输入——对一个正在 bring-up 的芯片，这个性质值钱得多。

### 3. 本章的取舍：能返回的单一入口

```zig
pub fn installDirect(addr: usize) error{Misaligned}!void {
    if (addr & 0x3 != 0) return error.Misaligned;
    asm volatile ("csrw mtvec, %[v]" : : [v] "r" (@as(u32, @intCast(addr))));
}
```

`isr.trapVector` 放在链接脚本的 `.text.entry` 里（`ALIGN(16)` 之后的第一项），地址天然满足 4 字节对齐；`installDirect` 仍然检查一次，因为“链接脚本被改坏”是真实故障，而低两位非零时硬件会按另一种模式解释这个地址，症状是“跳到奇怪的地址”，比直接报错难查一百倍。

MODE=3 的入口也留在 `clic.zig` 里，签名是显式的：

```zig
pub fn installVectored(exception_base: usize, table: usize) error{Misaligned}!void
```

它做两件事：写 `mtvt`（CSR `0x307`）、写 `mtvec = (exception_base & ~3) | 3`。**本工程不调用它**，原因写在函数注释里：向量表要在链接期生成、每项必须是 `j`，而 S31 的 `mcause` 输入号位宽与表项语义本仓没有实测过。

> [!warning] 待真机验证
> MODE=3 的 `mtvec.BASE` 在异常时的精确语义（是否必须与 `mtvt` 同一张表）、`mtvt` 的 64 字节对齐、向量表项是否允许 `j` 之外的指令，都要以 S31 TRM 与上板实测为准。本章不依赖其中任何一条。

### 4. `mstatus.MIE` 与 `mie`：谁才是闸

在 CLIC 系统上，一个外部中断要真正进 CPU，要同时满足：

```text
外设源侧使能（如 UART INT_ENA.RXFIFO_FULL）
      ↓ 矩阵把源投递到某个 CLIC 输入
CLIC 输入的 IE = 1
      ↓ 优先级 > 阈值
mstatus.MIE = 1
```

`mie` 这个 CSR 在这里**不是**外部中断的开关：IDF 的 `rv_utils_intr_get_enabled_mask()` 读的是每个输入的 `CLIC_INT_CTRL.IE`，而 `csr_clic.h` 把“使能中断”定义为“阈值降下来”。本章的 `_start` 仍然执行 `csrw mie, zero`——那是第四章留下的、无害的清零；真正决定“能不能进”的是上面四行里的后两项。

这也是本章初始化顺序的由来：**先把前三级全部配好并清掉挂起，最后才置 `mstatus.MIE`**。反过来的写法（先开 `MIE` 再配外设）几乎必然在配置过程中被一个陈旧标志打断一次，而你还没装好 `mtvec`。

---

## 7.4 48 个输入、8 个优先级、169 个源

### 1. CLIC 的寄存器只有三组

| 寄存器             | 地址                 | 关键字段                                                              |
| ------------------ | -------------------- | --------------------------------------------------------------------- |
| `CLIC_INT_CONFIG`  | `0x10800000 + 0x0`   | `NVBITS`[0]（硬件向量能力，复位 1）、`MNLBITS`[4:1]（优先级位宽）     |
| `CLIC_INT_INFO`    | `+0x4`               | `NUM_INT`[12:0]（复位 48）、`VERSION`[20:13]、`CTLBITS`[24:21]        |
| `CLIC_INT_THRESH`  | `+0x8`               | 阈值在 `[31:24]`                                                      |
| `CLIC_INT_CTRL(i)` | `0x10801000 + 4 × i` | `CTL`[31:24] 优先级、`IE` bit8、`IP` bit0、`SHV` bit16、`TRIG`[18:17] |

`CLIC_INT_INFO.NUM_INT` 就是“48 路”的第一手证据。`MNLBITS` 字段描述的是“优先级有效位数，最大 8”，但它的**复位值是 0**；IDF 在编译期把 `NLBITS` 固定成 3（8 级），所以“8 级”这个结论来自 IDF 的编译期常量，运行期读数只能用来核对、不能当成规格——启动横幅把它原样打出来就是为此：

```text
clic inputs=48
clic priority bits (raw)=<待真机验证>
clic hw vector=1
```

本章的 `clic.zig` 在启动时读它们，但**编码固定按 NLBITS=3 实现**——因为 `csr_clic.h` 就是这么编译的；读出来的值只用于核对，不参与运算。

### 2. 阈值：包含边界，这是最容易搞混的一点

阈值的语义是“**优先级 ≤ 阈值的中断被屏蔽**”，包含等于。`csr_clic.h` 里的编码函数是：

```c
#define NLBITS_TO_BYTE(level)  (((level) << NLBITS_SHIFT) | ((1 << NLBITS_SHIFT) - 1))
#define CLIC_INT_THRESH(l)      NLBITS_TO_BYTE(l)     // NLBITS_SHIFT = 8 - NLBITS = 5
```

代进 NLBITS=3：

| 级别 | 阈值字节 | 含义                     |
| ---- | -------- | ------------------------ |
| 0    | `0x1f`   | 什么都不屏蔽             |
| 1    | `0x3f`   | 屏蔽优先级 0 和 1        |
| 3    | `0x7f`   | 屏蔽 0..3                |
| 7    | `0xff`   | 屏蔽全部（`MIE` 仍为 1） |

低位补 1 不是装饰：硬件拿整个字节与 `CTL` 的高位比较，补 1 让“等于”落在“被屏蔽”一侧。本章的 `encodeThreshold` / `decodeThreshold` 就是这两行 C 宏的 Zig 版。

### 3. 优先级：编码进 `CTL` 的高位

`setPriority` 只改 `CLIC_INT_CTRL` 的 `CTL` 字节（`[31:24]`）的高 3 位，低 5 位保持原样：

```zig
const byte: u32 = (v >> 24) & 0xFF;
const new_byte = (byte & low_mask) | encodeLevel(level);   // low_mask = 0x1f
```

为什么不用 32 位整字段“清零再写”？因为这个字节的低位也有复位值（`0x1f`），而 IDF 的 `interrupt_clic_ll_get_priority()` 用 `CTL >> 5` 取优先级——它默认低位是什么都不影响读数，但如果有人用“整个字节比较”的方式做别的判断，抹掉低位就会得到不同的结果。**能少动一位就少动一位**，这是寄存器编程里最便宜的可维护性。

### 4. 中断矩阵：169 个源与一个 +16 的坑

`INTERRUPT_CORE0` 基址 `0x20585000`（`reg_base.h`），**每个源一个 32 位寄存器，偏移 = 4 × 源编号**：

| 字段         | 位    | 含义                                          |
| ------------ | ----- | --------------------------------------------- |
| `..._MAP`    | [5:0] | 目标中断号——**实测语义是 CLIC 输入号 16..47** |
| `PASS_LEVEL` | [9:8] | 0 关闭 remap；1 走 S 级；2/3 走 M 级          |

源编号来自 `components/soc/esp32s31/include/soc/interrupts.h` 的 `periph_interrupt_t` 枚举，本章用到的几个：

| 源                                 | 编号 | 备注                                         |
| ---------------------------------- | ---- | -------------------------------------------- |
| `ETS_UART0_INTR_SOURCE`            | 9    | 与 `CLIC_EXT_INTR_NUM_OFFSET` 无关，纯枚举序 |
| `ETS_TIMERGRP0_T0_INTR_SOURCE`     | 25   | 即 TIMG0 的 T0（ch08 用）                    |
| `ETS_SYSTIMER_TARGET0_INTR_SOURCE` | 33   | 本章的 1 kHz tick                            |
| `ETS_GPIO_INTR0_SOURCE`            | 61   | 0..3 共四组，按键中断用它                    |
| `ETS_CPU_INTR_FROM_CPU_0_SOURCE`   | 65   | 4 个软件中断源 65..68 的第一个               |

那个坑在这里：

```c
// components/riscv/interrupt_clic.c
void intr_matrix_route(int intr_src, int intr_num) {
    assert_valid_rv_int_num(intr_num);                       // intr_num < 32
    interrupt_clic_ll_route(core_id, intr_src, intr_num + RV_EXTERNAL_INT_OFFSET);
}
```

`interrupt_clic_ll_route()` 再把收到的值整段写进 `MAP`（掩码 63）。所以**寄存器里存的是 16..47，不是 0..31**。写 0..31 的后果不是报错，而是中断被投递到 CLIC 的**内部输入**上（0..15 是内部线），表现得像“中断完全没有发生”。本章的 `route()` 把这一点做成签名：

```zig
pub fn route(source: Source, comptime channel: u6) Input {
    comptime {
        if (channel >= ext_int_count) @compileError("channel 必须 < 32");
    }
    const id = channel + ext_int_offset;
    ...
    p.* = pass | @as(u32, id);
    return id;
}
```

`channel` 用编译期参数，越界就是编译错误；返回值是 CLIC 输入号，直接拿去 `setPriority` / `enableInput` / 分发表。**一个值在整条链上只有一种含义**，是这类代码最有效的防错手段。

第二核的矩阵是同一份布局加 `0x800`（`DR_REG_INTERRUPT_CORE1_BASE = DR_REG_INTR0_BASE + 0x800`），跨核投递是 ch14 的 IPI 主题。本章只用 core0。

### 5. 自动化的“源 → 通道 → 输入”表

```text
源 33 (SYSTIMER_TARGET0) --矩阵[33]--> 通道 0 --> CLIC 输入 16 --> 优先级 3 --> tickIsr
源 9  (UART0)            --矩阵[9]---> 通道 1 --> CLIC 输入 17 --> 优先级 2 --> uart0Isr
（软件）                                     --> CLIC 输入 19 --> 优先级 1 --> softIsr
```

优先级只影响“同时挂起时谁先跑”，不会让低优先级的那个消失。真正会让它消失的是阈值：阈值一旦抬到 2，输入 16 与 19 就被屏蔽了，直到阈值降回 0。

---

## 7.5 ISR 的契约：分发表、清标志、没有 claim/complete

### 1. 一张 48 项的表就是完备的

CLIC 把输入号直接放进 `mcause`，于是“向量表”退化成一次数组索引：

```zig
const table_size: usize = 48;
var table: [table_size]?Handler = [_]?Handler{null} ** table_size;

pub fn dispatch(id: clic.Input) void {
    irq_total +%= 1;
    if (handlerFor(id)) |h| { h(); return; }
    unhandled +%= 1;
    last_unhandled = @as(u32, id);
    clic.disableInput(id);          // 没有登记 → 关掉它
}
```

**未登记输入为什么要关 `IE`**：电平中断只要源侧标志还在，`mret` 之后立刻重新进 trap。如果没有处理函数去清那个标志，CPU 会被钉死在这个输入上，主循环一步都走不动，串口也不会再有任何输出——现场看起来是“烧完就死”，其实芯片在拼命跑 ISR。关掉 `IE` 让系统退化成“少了一个中断源”，而 `p` 命令里的 `irq unhandled` / `last unhandled id` 会告诉你是哪一个。

### 2. CLIC 没有 claim/complete

从 PLIC 迁过来的人最容易在这里栽跟头。PLIC 的流程是“claim 拿一个 id → 处理 → complete 通知控制器”，而 **CLIC 没有这两步**：

- 中断的“接受”就是硬件把 `pc` 设到入口，优先级与嵌套由阈值和硬件栈管理；
- 中断的“完成”就是 `mret`（硬件据此恢复优先级状态）；
- 源侧仍然必须**自己清**：UART 写 `INT_CLR`，SYSTIMER 写 `INT_CLR`；
- **边沿**中断另外有一个动作：写 1 到该输入的 `IP` 位来应答（IDF 的 `rv_utils_intr_edge_ack()` 就是 `REG_SET_BIT(CLIC_INT_CTRL_REG(n), CLIC_INT_IP)`）。

本章的两个中断都是“电平/周期”类，清源侧即可。软件中断（7.7）则必须清 `IP`。

### 3. ISR 里能做什么、不能做什么

| 能做                               | 不能做                                | 原因                                 |
| ---------------------------------- | ------------------------------------- | ------------------------------------ |
| 读/写自己外设的寄存器、清标志      | `printf`（ROM 版是阻塞的）            | 20 个字符 ≈ 1.7 ms，直接把 tick 压垮 |
| 入队到环形缓冲、自增计数器         | 等锁、`while` 等硬件状态              | ISR 的预算是微秒，不是毫秒           |
| 置一个 `volatile` 标志让主循环干活 | 调用可能阻塞的驱动（Flash、WDT 校准） | 会把更高优先级中断的延迟推向不可控   |
| 翻转一个 GPIO（本章用来量 tick）   | 在 ISR 里改中断配置（阈值/优先级）    | 把控制流复杂度搬进了最不该复杂的地方 |

`tickIsr` 就守在这条线上：清标志、自增、翻引脚、记一次时间戳，四件事没有循环也没有等待。

### 4. 分发表的登记时机

`isr.attach()` 必须在对应输入的 `IE` 打开**之前**完成。反过来的话，中断可能在表项还是 `null` 时到来，被 `dispatch()` 当成“未登记”把 `IE` 关掉——于是你明明登记了，却永远收不到中断，而 `unhandled` 恰好是 1。这类“一次性”故障靠日志很难复现，靠顺序预防。

`attach` 返回旧值，本章调用处用 `_ =` 丢掉它；真正严谨的写法是断言 `null`（“这个输入没被别人占用”）。在只有一个应用的裸机工程里，前者的成本更低。

---

## 7.6 临界区：保存/恢复，而不是关掉再打开

### 1. 三种写法的代价

| 写法                                    | 可嵌套 | 恢复到“调用前状态” | 代价                   |
| --------------------------------------- | ------ | ------------------ | ---------------------- |
| `csrci mstatus, 8` / `csrsi mstatus, 8` | 否     | 否                 | 最短                   |
| 保存 `mstatus` → 清零 → 写回            | **是** | **是**             | 一次 CSR 读 + 一次写   |
| CLIC 阈值（`enterLevel`）               | 是     | 是                 | 一次 MMIO 读 + 写 + 读 |

第二种是本工程采用的：

```zig
pub fn enter() u32 {
    const old = mstatus();
    asm volatile ("csrci mstatus, 8");
    return old;
}

pub fn exit(saved: u32) void {
    asm volatile ("csrw mstatus, %[v]" : : [v] "r" (saved));
}
```

为什么不能“无条件打开 `MIE`”：`enter()` 可能是在**已经关中断**的上下文里被调用的。假设外层关了中断，内层又 `enter`/`exit` 一次，如果 `exit` 无条件 `csrsi`，外层剩下的临界区就被打开了——这是一类典型的“只在高负载下才出现”的竞态。

`exit()` 整体写回 `mstatus` 而非只置 bit3，还有一个好处：`MPIE`/`MPP` 等位一起回到调用前的值，在异常返回路径上语义更干净。

### 2. 嵌套测试：用三个布尔量证明

`c` 命令里的 `nestedTest()` 只做一件事——把“我以为的”变成可打印的：

```text
in critical=1                    # enter/enter 之后，MIE=0
still masked after inner exit=1  # 内层 exit 之后仍然是 0
MIE restored=1                   # 外层 exit 之后回到 1
```

如果第二行是 0，说明 `exit()` 写错了（比如无条件打开），而这正是“临界区失效”的最直接证据。

### 3. 关中断的代价是可以数的

`criticalTest()` 关掉 `MIE` 5 ms，同时读两次 tick 计数：

```text
masked window us=5003
masked ticks=0
catch-up ticks=1
```

期望的三行对应三件事：

1. **`masked ticks = 0`**：关中断期间 ISR 一次都没跑（否则临界区不成立）；
2. **`catch-up ticks ≈ 1`**：CLIC 的 `IP` 只有一位，5 次命中被合并成 1 次挂起；`mret` 之后补跑一次，剩下的 4 次**永久丢失**；
3. 所以“关中断会丢 tick”不是形容词，而是可以算的：`lost ≈ window_ms − 1`。

这条结论对实时内核的设计有直接影响：tick 的精度不是由定时器决定，而是由**最长临界区**决定。5 ms 的临界区在 1 kHz tick 下就是 0.5% 的系统时钟误差——这正是 7.1 里“把采样频率写进结构”的另一种形态，只不过这次写进的是临界区长度。

### 4. 阈值版临界区：给嵌套留的门

```zig
pub fn enterLevel(level: u3) u8 {
    const old = thresholdRaw();
    writeThresholdRaw(clic.encodeThreshold(level));
    return old;
}
```

`writeThresholdRaw()` 里有一句看起来多余的读：

```zig
p.* = (v & 0x00FF_FFFF) | (@as(u32, byte) << 24);
_ = p.*;   // 新阈值不会立刻被 CPU 看到
```

依据是 IDF 的 `rv_utils_restore_intlevel_regval()`：写阈值之后要执行约 8 条 `nop` 或做一次内存读，新阈值才对 CPU 生效，然后才能安全地重新打开 `MIE`。少这一步的现象是“`exitLevel` 之后中断延迟了一小会儿才恢复”，在示波器上是一个随机的小凸起——非常难归因。

`thresholdTest()` 把阈值抬到 7 等 2 ms：`threshold 7 ticks` 应为 0，退出后 `clic threshold` 回到 0。**注意它与 `enter()` 的区别**：`MIE` 一直是 1，所以**优先级更高的中断本可以打断它**。本章没有配置更高优先级（最高是 3），所以观测不到差别；但接口在这里，RTOS 的“短临界区 + 高优先级中断不受影响”就是从这里长出来的。

---

## 7.7 把 UART 接收改成中断

### 1. 两个标志，两种用途

| 标志          | 位   | 何时置位                           | 适合什么                 |
| ------------- | ---- | ---------------------------------- | ------------------------ |
| `RXFIFO_FULL` | bit0 | 收到的字节数 ≥ `RXFIFO_FULL_THRHD` | 批量接收（吞吐）         |
| `RXFIFO_TOUT` | bit8 | 停止位之后线上静默超过阈值         | 交互式输入（单键、命令） |

`RXFIFO_FULL_THRHD` 的复位值是 **96**（`UART_CONF1_REG` `[7:0]`）。第六章的轮询版不需要动它，因为它每 1 ms 主动来读一次；中断版**必须**动：如果只留 96，交互式打字要攒够 96 字节才进一次中断，回显会“卡住”到你以为接收坏了。

本章把阈值改成 **1**，同时打开 `RXFIFO_TOUT`：

```zig
const p = reg(uart0_conf1);
p.* = (p.* & ~@as(u32, 0xFF)) | 1;          // 只改低 8 位
reg(uart0_int_ena).* = reg(uart0_int_ena).* | isr.rx_int_bits;   // bit0 | bit8
```

代价与收益都很清楚：

- 阈值 1 意味着**每个字节都可能进一次中断**。115200 下满速连续输入是 11.5 kB/s，也就是每秒一万多次中断——对 320 MHz 的核是可接受的（每次 ISR 几十条指令），但这不是“零成本”；
- 真要吞吐，正确做法是把阈值调回 32 或 64，让中断次数降一个数量级，交互延迟交给 `TOUT`。本章选 1，是因为**教学现场需要“敲一个键立刻回显”**。

`CONF1` 里还有流控与 `TOUT` 阈值，所以这里用读改写只碰低 8 位。整写这个寄存器会顺手把流控关掉、把超时阈值清零——一个典型的“配 A 弄坏 B”。

### 2. ISR 的三步与一个顺序陷阱

```zig
fn uart0Isr() void {
    var pending: u8 = @truncate(reg(uart_status).* & 0xFF);   // RXFIFO_CNT
    while (pending != 0) {
        const b: u8 = @truncate(reg(uart_fifo).* & 0xFF);
        rx_bytes +%= 1;
        _ = rx.push(b);
        pending -= 1;
    }
    reg(uart_int_clr).* = rx_int_bits;                        // 最后才清
}
```

**为什么先读后清**：先清 `INT_CLR` 再读 FIFO，中间到达的字节不会重新置起已经清掉的标志（`FULL` 要等下一次阈值，`TOUT` 要等下一次静默），表现为“偶发丢一两个字符”，而且只在连续输入时出现。反过来（先读完、再清）最坏情况是多进一次中断，代价可以忽略。

`pending` 用 `RXFIFO_CNT` 而不是“读到空为止”：后者要靠 FIFO 返回的状态位判断空，多一次寄存器读；前者是一次读拿到数量，while 里只读数据寄存器。两种都对，前者更省。

### 3. 环形缓冲：结构不变，可见性变了

```zig
pub fn push(self: *RxRing, b: u8) bool {        // 生产者：ISR
    const head = vload(&self.head);
    const tail = vload(&self.tail);
    if (head -% tail >= capacity) { vstore(&self.drops, vload(&self.drops) +% 1); return false; }
    self.buf[@as(usize, head & (capacity - 1))] = b;
    @fence(.seq_cst);
    vstore(&self.head, head +% 1);
    return true;
}

pub fn pop(self: *RxRing) ?u8 {                 // 消费者：主循环
    @fence(.seq_cst);
    const tail = vload(&self.tail);
    const head = vload(&self.head);
    if (head == tail) return null;
    @fence(.seq_cst);
    const b = self.buf[@as(usize, tail & (capacity - 1))];
    vstore(&self.tail, tail +% 1);
    return b;
}
```

三处改动，每一处都有明确的失败模式：

| 改动                              | 不改的后果                                                                               |
| --------------------------------- | ---------------------------------------------------------------------------------------- |
| `head`/`tail`/`drops` 走 volatile | 主循环里的 `while (rx.pop())` 会被优化成“读一次 head，之后一直用旧值” → 永远读不到新数据 |
| 写数据 → `fence` → 写 `head`      | 编译器/硬件可能把 `head` 的更新提到数据写入之前，消费者读到未初始化的槽位                |
| 容量 256、满时丢新并计数          | 阻塞生产者（ISR 里等待）＝ 死锁；覆盖旧数据 ＝ 静默丢命令                                |

单核上 `fence` 挡的主要是**编译器重排**；S31 是双核且有 cache，跨核共享时它才是真屏障。本章先把语义写对，因为“单核所以不用 fence”这种推理会在上 SMP 的那一天集中爆炸（ch14）。

`rx.len()` 与 `rx.dropped()` 都是 volatile 读——它们被主循环反复轮询，非 volatile 的实现会把值提到循环外，症状是“计数停在第一秒”。

---

## 7.8 工程走读

> 完整工程:[ch07-interrupts-clic](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/)

| 文件                                | 查看                                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------------------------- |
| `build.zig`                         | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/build.zig)                         |
| `linker/s31.ld`                     | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/linker/s31.ld)                     |
| `src/clic.zig`                      | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/clic.zig)                      |
| `src/critical.zig`                  | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/critical.zig)                  |
| `src/isr.zig`                       | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/isr.zig)                       |
| `src/main.zig`                      | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/main.zig)                      |
| `src/start.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/start.zig)                     |
| `idf-bootstrap/CMakeLists.txt`      | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/tools/flash.sh)                    |
| `README.md`                         | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/README.md)                         |

### 1. 文件与职责

| 文件               | 职责                                                                | 关键点                                         |
| ------------------ | ------------------------------------------------------------------- | ---------------------------------------------- |
| `src/start.zig`    | `app_desc` + `_start`（关中断 → sp/gp → 清 `.bss` → `call main`）   | 与 ch04/ch06 逐字同构，**不动**                |
| `src/clic.zig`     | 阈值/优先级/IE/IP、矩阵路由、`mtvec` 两模式入口                     | 矩阵写的是 CLIC 输入号；`route()` 用编译期通道 |
| `src/isr.zig`      | naked `trapVector`、`trapDispatch`、48 项表、UART0 RX ISR、环形缓冲 | 保存 16 个易失寄存器；未登记输入关 `IE`        |
| `src/critical.zig` | `enter`/`exit`（`mstatus`）、`enterLevel`/`exitLevel`（阈值）       | 可嵌套；阈值写后要读一次                       |
| `src/main.zig`     | 横幅、初始化顺序、1 kHz 闹钟、命令循环、三组测试                    | ISR 里不打印；`tickIsr` 四件事                 |
| `linker/s31.ld`    | `.app_desc` 先于代码、`.text.entry` 承载 `trapVector`、栈与边界符号 | `ALIGN(16)` 满足 4 字节对齐                    |

### 2. 初始化顺序：八步，顺序即设计

`setupInterrupts()` 的每一步都对应一种失败模式，倒过来做就会踩：

| 步  | 动作                                         | 提前/推后做的后果                                    |
| --- | -------------------------------------------- | ---------------------------------------------------- |
| 1   | 阈值设 0                                     | 阈值留着复位值可能屏蔽低优先级输入                   |
| 2   | 矩阵路由两个源                               | 不路由 → 中断永不发生                                |
| 3   | 登记处理函数                                 | 晚登记 → 首个中断被判“未登记”，`IE` 被关             |
| 4   | `installDirect(mtvec)`                       | 晚装 → 中断进了 bootloader 留下的向量                |
| 5   | 外设侧使能（UART `INT_ENA`、SYSTIMER 闹钟）  | 早开而 `IE` 也开着 → 配置过程中被陈旧标志打断        |
| 6   | 清所有挂起（UART/SYSTIMER/CLIC `IP`）        | 不清 → 一开 `MIE` 就立刻进一次“历史遗留”中断         |
| 7   | 设优先级 + 开 `IE`（UART 2、tick 3、soft 1） | 优先级都在同一级也无妨，但 UART 更高更符合直觉       |
| 8   | `critical.enable()`（`mstatus.MIE = 1`）     | 提前 → 前面七步里任何一步的错误都会变成“随机进 trap” |

保存这份顺序的收益在排错时最明显：如果第 8 步之后完全没有中断，问题只可能在 2/4/5/7 四处；如果第 8 步之后立刻死循环，几乎一定是 6（挂起没清）或某个 ISR 没清源。

### 3. 命令集

| 键  | 动作                                                                         | 观测点                                              |
| --- | ---------------------------------------------------------------------------- | --------------------------------------------------- |
| `?` | 帮助                                                                         | 一行提示                                            |
| `p` | 计数：ticks / tick age / soft / irq / rx / mstatus / threshold / map / mtvec | 一次拿到全部关键状态                                |
| `c` | 临界区三段测试（关 MIE / 嵌套 / 阈值）                                       | `masked ticks`、`MIE restored`、`threshold 7 ticks` |
| `s` | 置软件中断 `IP`                                                              | `soft irq` 加 1                                     |
| `t` | 执行全零指令触发异常（**会停机**）                                           | `mcause=0x00000002`、`mepc`                         |

`p` 里的 `intr map uart0` 应该是 `0x00000011`（= 17），`intr map systimer` 是 `0x00000010`（= 16）。**这两个数就是“矩阵存的是输入号而不是通道号”的现场证据**：如果看到 `0x00000001` 和 `0x00000000`，说明路由写错了，中断一定不会来。

### 4. 软件中断：IPI 的雏形

`s` 命令不做矩阵路由，直接置 CLIC 输入 19 的 `IP` 位：

```zig
clic.raise(soft_id);        // 输入 19，优先级 1
```

它验证两件事：

1. **CLIC 的软件中断不需要外设**：`IP` 就是挂起状态，置它就等价于“有人敲门”；
2. **`IP` 必须由 ISR 清掉**（`softIsr` 里 `clic.clearPending`），否则 `mret` 之后立刻再进一次，形成风暴。

S31 有 4 个硬件软件中断源（`ETS_CPU_INTR_FROM_CPU_0..3`，编号 65..68），跨核唤醒（IPI）就是“核 A 置核 B 的输入 `IP`”。本章单核，只用它做一次“分发器真的能分发”的证明。

---

## 7.9 构建、烧录与验收

### 1. 三条命令

```bash
cd practice/zig-esp32-s31/ch07-interrupts-clic

zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf
```

bootloader 与分区表由 `idf-bootstrap/` 里的 IDF 工程产出（preview target），
烧录用 `sh tools/flash.sh <PORT>`（偏移全部来自 `flash_args`，不手抄）。

### 2. 主机侧能做的静态检查

| 检查                          | 命令                                        | 期望                                      |
| ----------------------------- | ------------------------------------------- | ----------------------------------------- |
| 入口是 `_start`               | `readelf -h zig-out/bin/app.elf`            | `Entry point address` == `nm` 的 `_start` |
| `trapVector` 在 `.text.entry` | `nm -n zig-out/bin/app.elf \| grep -i trap` | 地址落在 `0x2F000100` 一带，4 字节对齐    |
| 段 #0 以应用描述开头          | `xxd -s 32 -l 4 zig-out/bin/app.bin`        | `32 54 cd ab`（小端 `0xABCD5432`）        |
| `mtvec` 目标可执行            | `objdump -d` 看 `_text_start` 附近          | 第一条就是 `addi sp, sp, -80`             |

最后一条值得单说：`mtvec` 装的是一个**地址**，如果 `.text.entry` 被链接脚本放错（比如落到 `.data` 之后），芯片不会报错，只会在第一个中断到来时跳进数据区。上线前用 `objdump` 确认那 4 条指令在，比事后用示波器猜快得多。

### 3. 串口验收：要看到什么

| 观察点               | 判据                                                          | 说明                                              |
| -------------------- | ------------------------------------------------------------- | ------------------------------------------------- |
| 横幅                 | 恰好一次，在 bootloader 日志之后                              | TX 链路通                                         |
| `clic inputs=48`     | 48                                                            | `CLIC_INT_INFO.NUM_INT` 读对                      |
| `clic priority bits` | 读到的值可解释（以 TRM 为准）；本章编码固定按 IDF 的 NLBITS=3 | `CONFIG.MNLBITS` 复位值是 0，运行期读数待真机验证 |
| `clic hw vector=1`   | 1                                                             | 硬件支持向量中断（本章不用）                      |
| `mtvec`              | 落在 `.text.entry`                                            | `installDirect` + 链接脚本                        |
| `uart input id=17`   | 17                                                            | 矩阵路由 = 通道 1 + 16                            |
| `tick input id=16`   | 16                                                            | 矩阵路由 = 通道 0 + 16                            |
| `ticks/s`            | 稳定在 1000 附近                                              | SYSTIMER 周期模式 + 16 MHz 基准                   |
| GPIO5 波形           | ≈500 Hz 方波，占空比 50%                                      | `tickIsr` 每次翻转                                |
| 回显                 | 任意可打印字符立刻回显                                        | UART RX 中断 + TOUT                               |
| `rx drops`           | 打字时 0                                                      | 环形缓冲 256 字节够用                             |
| `irq total`          | 约 1000/s + 输入速率                                          | 分发器在跑                                        |
| `p` 的 `intr map`    | `0x11` / `0x10`                                               | 矩阵里存的是输入号                                |
| `c` 的第一段         | `masked ticks=0`、`catch-up ticks` 个位数                     | 临界区真的关了中断                                |
| `c` 的第二段         | `MIE restored=1`                                              | 保存/恢复正确                                     |
| `c` 的第三段         | `threshold 7 ticks=0`，之后 `clic threshold=0`                | 阈值版临界区生效                                  |
| `s`                  | `soft irq` 每次 +1                                            | 软件中断（IP）可用                                |
| `t`                  | `mcause=0x00000002`，`mepc` 指向触发指令，按 EN 重启          | 异常路径与 `mtvec` 正确                           |

### 4. 证据状态表

| 检查项                          | 证据                                                | 状态               |
| ------------------------------- | --------------------------------------------------- | ------------------ |
| 目标能力（`zicsr` 等）          | 系列 2026-11-12 的 `--show-builtin` 实测            | 已验证（系列级）   |
| CLIC 寄存器与位域               | IDF v6.1 `clic_reg.h`、`csr_clic.h`                 | 已核对（源码级）   |
| 矩阵语义（存输入号）            | IDF v6.1 `interrupt_clic_ll.h` + `interrupt_clic.c` | 已核对（源码级）   |
| 源编号（UART0=9、SYSTIMER=33）  | IDF v6.1 `soc/interrupts.h`                         | 已核对（源码级）   |
| 应用 ELF / 镜像产出             | `zig build` → `elf2image`                           | 待首次构建回填     |
| `trapVector` 位于 `.text.entry` | `nm -n`                                             | 待首次构建回填     |
| 中断真的进来                    | `irq total` / `ticks/s`                             | 待真机验证         |
| 1 kHz 精度                      | `ticks/s`（10 秒）                                  | 待真机验证         |
| 临界区丢 tick 的数量            | `c` 的三段计数                                      | 待真机验证         |
| 阈值的屏蔽边界（是否含等于）    | `threshold 7 ticks=0` 与中间级别实验                | 待真机验证         |
| CLIC 向量模式（MODE=3）         | 未启用                                              | 未验证（明确不做） |
| GPIO5 是否真在 J2 上            | 板卡原理图（本仓未收录）                            | 待真机验证         |

---

## 7.10 排错

### 1. 现象 → 层 → 处置

| 现象                                         | 最可能的层            | 根因与处置                                                                     |
| -------------------------------------------- | --------------------- | ------------------------------------------------------------------------------ |
| `ticks/s=0`，但横幅正常                      | 路由/使能             | `p` 看 `intr map`（应 `0x10`）、`mstatus` bit3、输入 `IE`；三者缺一都不会进    |
| `irq unhandled` 涨，`last unhandled id` < 16 | 矩阵写法              | 写了 0..31 的外部号；`MAP` 要写输入号（16..47），见 7.4 第 4 节                |
| 一开 `MIE` 就死循环                          | 挂起没清 / ISR 不清源 | 先清 `INT_CLR` 与 CLIC `IP` 再开 `MIE`；每个 ISR 必须清自己的源                |
| `ticks/s` 明显偏离 1000                      | 时钟/丢 tick          | 看 `irq total` 增量；临界区是否过长；XTAL 必须 40 MHz（SYSTIMER 固定 16 MHz）  |
| 回显慢半拍                                   | UART 阈值             | 只开了 `FULL` 且阈值 96；改成 1 并打开 `TOUT`（bit8）                          |
| 连续输入偶发丢字节                           | ISR 顺序              | 先清 `INT_CLR` 再读 FIFO；改成“读空 → 最后清”                                  |
| 主循环看不到计数变化                         | volatile              | `head`/`tail`/计数必须 volatile 读，否则被提到循环外                           |
| `c` 的 `masked ticks` ≠ 0                    | 临界区                | `enter()` 后 `mstatus` bit3 必须为 0；`exit()` 必须用同一次 `enter()` 的返回值 |
| `MIE restored=0`                             | 嵌套                  | `exit()` 写回了错误的 `saved`；或中间有人改过 `mstatus`                        |
| `exitLevel` 后中断恢复延迟                   | 阈值写后未读          | 写完阈值要读一次寄存器（IDF 注释要求的强制）                                   |
| 输入 `t` 没有任何输出                        | trap 层               | `mtvec` 没装或 `trapVector` 不在可执行段；用 `objdump` 看 `.text.entry`        |
| `t` 打出 `mcause=0x80000011` 之类            | 意外中断              | 说明中断正在发生；这不是异常路径的现象，别按异常去查                           |
| 第一帧就乱码                                 | 主机侧                | 115200 8N1；ROM 已配好，应用没改                                               |

### 2. 两条原则

1. **先证明“中断能进”，再证明“进来做对了”。** `irq total` 在涨就说明前四级（源、矩阵、`IE`、`MIE`）都通了；剩下的问题一定在 ISR 内部（清标志、缓冲、打印）。反过来，先把 ISR 写复杂再去调“为什么没进来”，会把两类问题搅在一起。
2. **一次只改一个开关。** 矩阵通道、优先级、阈值、`FIFO` 阈值、环形缓冲容量同时改，最后的现场无法归因。本章的验收表按“单变量”排，就是为了这件事。

---

## 7.11 下一章预告：定时器、DMA 与精确时序

本章的 1 kHz 来自 SYSTIMER 的 target 比较，**精度只到“计数对不对”**：`ticks/s=1000` 说明每秒进了一千次，但没告诉你每次晚了多少纳秒。下一章把这条线拉直：

- **TIMG**：预分频器 + 两个 54 位定时器 + 报警 + WDT，它是“可编程周期”的正统来源；本章的 SYSTIMER 是“固定 16 MHz 的时间尺”，两者定位不同；
- **抖动**：用 GPIO 翻转 + 逻辑分析仪量“中断响应时间”的分布，而不是只看平均值；本章的 `tick age us` 只是活性指标，不是抖动指标；
- **DMA**：AHB-DMA/GDMA 的描述符、内存到内存搬运、cache 与 PSRAM 的一致性约束。本章所有数据都走 CPU，下一章要回答“哪些搬运动作不该由 CPU 做”。

同一块板子、同一个串口，下一章会把“看起来对”变成“误差是几个纳秒”。

---

## 事实来源

| 事实                                                                                                                                                 | 来源                                                                                                                                                                                                                                                    | 备注                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| S31：双核 RV32IMAF C @320 MHz、512 KB SRAM、16 MB Flash + 16 MB PSRAM                                                                                | [Espressif ESP32-S31 产品页](https://www.espressif.com/en/products/socs/esp32-s31)                                                                                                                                                                      | 与系列索引一致                                        |
| CLIC：48 输入 / 8 优先级 / 硬件向量能力；`CONFIG`/`INFO`/`THRESH` 的偏移与位域                                                                       | [IDF v6.1 `clic_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/clic_reg.h)                                                                                                                                  | `DR_REG_CLIC_BASE=0x10800000`、`CTRL_BASE=0x10801000` |
| `MTVT_CSR=0x307`、`MTVEC_MODE_CSR=3`、`NLBITS`、`RV_EXTERNAL_INT_COUNT=32`、`OFFSET=16`、阈值编码宏                                                  | [IDF v6.1 `csr_clic.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/riscv/include/riscv/csr_clic.h)                                                                                                                                       | MODE=3 与阈值的唯一依据                               |
| `rv_utils_set_mtvt()` 写 0x307；非标准阈值写后需读一次                                                                                               | [IDF v6.1 `interrupt_clic.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/riscv/include/esp_private/interrupt_clic.h)                                                                                                                     | 本工程 `installVectored`/`writeThresholdRaw` 的依据   |
| 矩阵寄存器每个源 4 字节、`MAP[5:0]`、`PASS_LEVEL[9:8]`                                                                                               | [IDF v6.1 `interrupt_core0_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/interrupt_core0_reg.h)                                                                                                           | `UART0` 的映射寄存器在 `+0x24`                        |
| 矩阵里存的是 `intr_num + 16`（CLIC 输入号）；`interrupt_clic_ll_route` 掩码 63                                                                       | [IDF v6.1 `interrupt_clic_ll.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/hal/include/hal/interrupt_clic_ll.h)、[`interrupt_clic.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/riscv/interrupt_clic.c)                 | 本章最容易写错的一处                                  |
| 中断源枚举：UART0=9、TIMERGRP0_T0=25、SYSTIMER_TARGET0=33、GPIO_INTR0=61、CPU_INTR_FROM_CPU_0=65                                                     | [IDF v6.1 `soc/interrupts.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/include/soc/interrupts.h)                                                                                                                          | 169 项（`ETS_MAX_INTR_SOURCE`）                       |
| `INTERRUPT_CORE1 = INTERRUPT_CORE0 + 0x800`                                                                                                          | [IDF v6.1 `reg_base.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/reg_base.h)                                                                                                                                 | 本章只用 core0                                        |
| UART0 基址 `0x2038A000`；`FIFO`+0x0、`INT_ENA`+0xc、`INT_CLR`+0x10、`STATUS`+0x1c、`CONF1`+0x24；`RXFIFO_FULL` bit0、`RXFIFO_TOUT` bit8、阈值复位 96 | [IDF v6.1 `uart_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/uart_reg.h)、[`esp32s31.peripherals.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/ld/esp32s31.peripherals.ld) | 第六章已核对过 FIFO/STATUS 部分                       |
| SYSTIMER 基址 `0x20399000`；`CONF`+0x0（bit31/30/24）、`TARGET0_HI/LO`+0x1c/+0x20、`TARGET0_CONF`+0x34、`INT_ENA/CLR`+0x64/+0x6c                     | [IDF v6.1 `systimer_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/systimer_reg.h)                                                                                                                         | 周期模式的 `PERIOD[25:0]` + bit30                     |
| SYSTIMER 时钟固定为 XTAL 40 MHz / 2.5 = 16 MHz                                                                                                       | [IDF v6.1 `systimer_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/systimer_reg.h)；IDF 的 `esp32s31` port 注释原文见 [[ch05-clock-reset-watchdog\|第五章]]                                                | 1 tick = 62.5 ns，ch05 已用                           |
| `mtvec` 模式编码、`mcause`/`mepc`/`mtval` 语义、`mret` 行为                                                                                          | [RISC-V Privileged Architecture](https://github.com/riscv/riscv-isa-manual/releases)                                                                                                                                                                    | MODE=0 需 4 字节对齐；中断返回不加 4                  |
| CLIC 规范：输入、优先级、阈值、`mtvt` 与向量表项                                                                                                     | [RISC-V CLIC 规范草案](https://github.com/riscv/riscv-fast-interrupt)                                                                                                                                                                                   | 与 IDF 头文件交叉核对                                 |
| `mcause` 低位是 CLIC 输入号、掩码 `0x3f`                                                                                                             | [esp-hal `esp32s31/soc.toml`](https://github.com/esp-rs/esp-hal/blob/667f8f02/esp-metadata/devices/esp32s31/soc.toml)                                                                                                                                   | `cpu_mcause_mask = 0x3f`、`interrupts = 48`           |
| 全零指令永久保留为非法指令                                                                                                                           | [RISC-V Unprivileged ISA](https://github.com/riscv/riscv-isa-manual/releases)                                                                                                                                                                           | `t` 命令的可预期性依据                                |
| `esp_app_desc_t` 256 字节、魔数 `0xABCD5432`                                                                                                         | [IDF v6.1 `esp_app_desc.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_app_format/include/esp_app_desc.h)                                                                                                                            | 第四章已逐字段拆过，本章沿用                          |
| `esp32s31` 是 IDF v6.1 preview target                                                                                                                | [[ch11-esp32s31-lab-plan\|ONVIF 第十一章]]                                                                                                                                                                                                              | `set-target`/`list-targets` 必带 `--preview`          |
| GPIO/IO_MUX 偏移与 `OUT_SEL=256`                                                                                                                     | [IDF v6.1 `gpio_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/gpio_reg.h)、[`io_mux_reg.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/soc/esp32s31/register/soc/io_mux_reg.h)             | ch06 已逐条核对，本章复用                             |

## 自查清单

进入下一章前，确认能回答这些问题：

- [ ] 115200 8N1 下一个字节占多少位、多少微秒？为什么 FIFO 阈值 96 意味着“主循环不能卡超过约 3 ms”？
- [ ] 中断换掉的到底是“速度”还是“责任归属”？为什么数据结构可以一行不改？
- [ ] 硬件在进 trap 时替你做了哪五件事？软件必须补上什么？
- [ ] 为什么中断返回时 `mepc` 不需要 +4，而某些同步异常处理需要？
- [ ] `trapVector` 为什么必须保存 `ra`/`t0`–`t6`/`a0`–`a7`，而不用保存 `s0`–`s11`？帧长为什么取 80 而不是 64？
- [ ] `mcause` 在 CLIC 系统上的低位是什么？为什么不能按 RISC-V 规范的“标准中断编号”去查？
- [ ] `mtvec` 的四种模式各是什么？MODE=3 的入口地址怎么算？向量表项为什么必须是 `j`？
- [ ] 向量模式的三笔账（条目形式、对齐、±1 MB）分别会在什么情况下咬人？
- [ ] 阈值 `0x1f`、`0x3f`、`0xff` 各屏蔽哪些优先级？为什么低位要补 1？
- [ ] 中断矩阵寄存器里存的是通道号还是 CLIC 输入号？证据是哪两个 IDF 文件？
- [ ] 为什么 `IE` 要在“登记处理函数、清挂起”之后才打开？提前会看到什么现象？
- [ ] CLIC 有没有 claim/complete？没有的话“应答”由谁来做完？
- [ ] 未登记的中断为什么要关掉 `IE`，而不是只计数返回？
- [ ] `enter()` 为什么必须返回旧 `mstatus`？无条件 `csrsi mstatus, 8` 会在什么场景下出错？
- [ ] 关 5 ms 中断为什么只补回 1 个 tick？“丢 4 个”这个数字由什么机制决定？
- [ ] 阈值版临界区与关 `MIE` 的本质区别是什么？它给谁留了门？
- [ ] UART 为什么同时需要 `RXFIFO_FULL` 与 `RXFIFO_TOUT`？只留 FULL 且阈值 96 时会看到什么？
- [ ] ISR 里为什么必须“先读 FIFO、后清 `INT_CLR`”？反过来会丢什么？
- [ ] 环形缓冲的 `head`/`tail` 为什么必须 volatile 读？两处 `fence` 各挡的是什么重排？
- [ ] `p` 里 `intr map uart0=0x11` 这个数是怎么来的？如果是 `0x1` 说明什么？
- [ ] 软件中断的 `IP` 为什么必须由 ISR 清？不清会怎样？

---

下一章把本章的“计数正确”推进到“时序精确”：TIMG 的预分频与报警、用 GPIO 翻转量中断响应的抖动分布、以及 AHB-DMA/GDMA 的描述符搬运。本章的 `tick age us` 只回答“最近一次中断离现在多久”，下一章要回答“每次中断晚了多少纳秒，为什么”。

系列导航：[[ch06-gpio-uart-logging-panic|上一章]] · [[zig-esp32-s31|系列索引]]
