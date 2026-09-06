---
title: "嵌入式硬件基础（四）：裸机启动——自写启动文件、链接脚本与 Reset_Handler"
date: 2026-08-30 09:00:00
description: "从上电三步（取向量→设 MSP→跳 Reset_Handler）出发，逐行写出一个零依赖的 Cortex-M3 启动文件与链接脚本，讲清 .data 从 flash 搬到 RAM 的两段式加载，用 Makefile/CMake 构建，最后在 QEMU mps2-an385 上直写 UART0 寄存器打出系列第一行 hello baremetal（含 gdb 复位状态实证、向量表反汇编与 map 解读）——产出的模板工程是后续章节的技术底座。"
tags: [embedded-basics, STM32, RISC-V]
---

> [!info] 嵌入式硬件基础系列 0. [[embedded-basics|系列索引]] · 3. [[ch03-arm-cortex-m-anatomy|上一章：Cortex-M 解剖]] · 4. **第四章：裸机启动** · 5. [[ch05-gpio-and-mco|下一章：GPIO 与时钟树]]

# 嵌入式硬件基础（四）：裸机启动——自写启动文件、链接脚本与 Reset_Handler

在 [[ch03-arm-cortex-m-anatomy|第三章]] 我们解剖了 Cortex-M3 的寄存器组、双栈和向量表，但那是"解剖学"——躺着的。这一章让它站起来：**不借助任何 SDK、任何启动库、任何 HAL，从零写出上电后运行的第一段代码**，并在 QEMU 里打出这个系列的第一行 `hello baremetal`。

产出是两件东西：

- **知识**：上电三步（取向量 → 设 MSP → 跳 Reset_Handler）、"程序住在 flash 但变量要住 RAM"的两段式加载、链接脚本如何用 LMA/VMA 描述这件事；
- **资产**：`practice/hwbasics/ch04-baremetal-template/`——本系列后续章节（GPIO、中断、定时器）都往这个模板上叠代码，不再重写启动链。

所有输出均来自本章工程的真实运行（工具链 `arm-none-eabi-gcc 15.2.0`、`qemu-system-arm 10.1.5`、`-M mps2-an385`）。

---

## 4.1 上电之后的三步：没有一行软件参与的引导

先回答"开机第一件事"。x86 老手熟悉 reset vector（0xFFFFFFF0 处的第一条指令），Cortex-M 的做法更结构化——**复位本身就是编号 -15 的异常**，走的是和 NVIC 中断同一套向量表分发机制（类比：把"开机"实现成"一次不可屏蔽的中断"）。硬件按顺序做三件事（规范依据：ARMv7-M Architecture Reference Manual，DDI 0403E.e，§B1.5 Exception model）：

1. **取向量表**：从 VTOR（Vector Table Offset Register，复位值 0x00000000）指向的地址取向量表；
2. **设 MSP**：把 `[0x00000000]` 处的 32 位值加载进 SP_main——注意向量表 0 号槽装的是**栈顶地址，不是指令**，这是 Cortex-M 最经典的"第一惊讶"；
3. **跳转**：把 `[0x00000004]` 处的值装入 PC，开始执行——这就是 Reset_Handler 的入口。

三个可观察的细节，每个都对应后文的一个实验证据：

- **Thumb bit**：装入 PC 的值必须是奇数（bit0=1，Thumb 状态），否则 HardFault——所以后面反汇编里你会看到向量表第二项是 `0x000000c1` 而不是 `0x000000c0`；
- **LR = 0xFFFFFFFF**：复位时 LR 装的是 EXC_RETURN 的非法保留值，因为 Reset_Handler"无家可归"，没有调用者可返回；
- **特权 thread mode**：复位后 CPU 在特权级 thread 模式直接跑你的代码，handler 模式留给异常。

> [!tip] 和真机 STM32 的差异：BOOT 引脚与地址重映射
> F407 真机复位后并不是固定从 0x00000000 取向量：BOOT0/BOOT1 引脚选择启动存储器（主 flash / 系统 ROM / SRAM），硬件把所选存储器**重映射到 0x00000000**，向量表机制不变（STM32F4 参考手册 RM0090 §2.3 Memory map：主 flash 物理基址 0x0800 0000）。因主 flash 启动是常态，启动代码通常还会把 `SCB->VTOR` 重设为 `0x08000000`。QEMU 的 mps2-an385 没有这套重映射，VTOR 恒为 0——**模板里代码区就叫 0x0，把"重映射"这一层剥掉了，反而看得更清楚**。

第三章讲过向量表结构和异常入栈八寄存器的顺序，这里不再重复。本章要做的是把这张表**亲手填出来、链到 0 地址、并证明硬件确实按它引导**。

---

## 4.2 内存模型：程序住在 flash，变量要住 RAM

写启动文件前必须先想清楚映像布局。编译器给每个符号两个地址概念：

| 概念    | 全称                            | 谁用                            |
| ------- | ------------------------------- | ------------------------------- |
| **VMA** | Virtual（运行时）Memory Address | CPU 执行时访问的地址            |
| **LMA** | Load Memory Address             | 烧写工具/加载器放置初始值的地址 |

两者何时不同？看三类段的去向：

| 段                  | 内容                          | VMA     | LMA                | 上电后                        |
| ------------------- | ----------------------------- | ------- | ------------------ | ----------------------------- |
| `.text` / `.rodata` | 代码、常量                    | flash   | flash（同 VMA）    | 就位，直接执行                |
| `.data`             | **有非零初值**的全局/静态变量 | **RAM** | **flash**          | Reset_Handler 从 LMA 拷到 VMA |
| `.bss`              | 无初值（或初值为 0）的变量    | RAM     | 无（不占映像体积） | Reset_Handler 清零            |

为什么变量不能直接住 flash？因为 flash 写入按页擦除、有寿命次数、写入期间不能取指——`counter++` 这种随机写只有 RAM 扛得住。但 RAM 掉电即失，初值必须在掉电时保存于 flash。于是有了嵌入式最经典的**两段式加载**：

```text
        flash（掉电保存）                    RAM（随机读写）
  ┌─────────────────────┐            ┌──────────────────────┐
  │ .isr_vector .text   │            │ 0x20000000  .data ←──┼── ①Reset_Handler
  │ .rodata             │            │            .bss  ←──┼── ②清零     │
  │ _sidata→[data 初值] │ ──拷贝──→  │        （栈向下生长） │
  └─────────────────────┘            └────────↑─────────────┘
                                              _estack（MSP 初值）
```

**烧写工具只负责把完整映像写进 flash；把变量搬进 RAM 是你代码自己的事**——这就是 Reset_Handler 存在的另一半理由（前一半是"总得有个上电入口"）。

### 1. mps2-an385 的真实内存映射（QEMU 源码考证）

地址不能靠记忆，考证一遍。QEMU 官方文档（System ARM → MPS2）只列机型不列地址，数字地址在源码注释里——`hw/arm/mps2.c`（v10.1）FPGA_AN385 分支：

| 资源                     | 地址                                       | 容量 | 出处                                         |
| ------------------------ | ------------------------------------------ | ---- | -------------------------------------------- |
| ZBT SSRAM1（代码映像区） | `0x00000000`                               | 4MB  | `make_ram(..., 0x0, 0x400000)`               |
| ZBT SSRAM1 镜像          | `0x00400000`                               | 4MB  | `ssram1_m` alias                             |
| ZBT SSRAM2&3（数据 RAM） | `0x20000000`                               | 4MB  | `make_ram(..., 0x20000000, 0x400000)`        |
| PSRAM                    | `0x21000000`                               | 16MB | `machine->ram`                               |
| UART0（CMSDK APB UART）  | `0x40004000`                               | —    | `uartbase[] = {0x40004000, 0x40005000, ...}` |
| DualTimer / WDT / SCC    | `0x40002000` / `0x40008000` / `0x4002F000` | —    | 同文件                                       |
| SYSCLK / REFCLK          | 25 MHz / 1 MHz                             | —    | `SYSCLK_FRQ` / `REFCLK_FRQ`                  |

结构正是教科书布局：代码区 `0x0...`、SRAM `0x2000_0000...`、外设 `0x4000_0000...`——和 STM32 地址空间的骨架一致（RM0090 §2.3），所以这里学到的东西平移到真机不废。

> [!warning] QEMU 边界：0x0 区不是真 flash
> mps2-an385 的 0x0 区在硬件上是 ZBT SSRAM（可写 RAM），没有非易失性。QEMU 的 ELF 加载器按程序头的 `p_paddr`（LMA）放置各段——所以"flash 保存初值"由加载器代劳，**Reset_Handler 的搬运逻辑与真机完全一致**（4.7 节用输出证明）。另：AN385 实板存在"低 16K 可重映射到 block RAM"的特性，QEMU 明确未实现（文档原话：as if `zbt_boot_ctrl` were zero）。链接脚本取 FLASH 512K / RAM 128K，既在 mps2 的 4MB/4MB 之内，也恰好对齐 F407VET6 的主 flash(512KB) 与 SRAM1+2(128KB)——模板换真机时只改 MEMORY 区的数字。

---

## 4.3 启动文件逐行写：startup.S

启动文件就是"向量表 + Reset_Handler + 兜底异常处理"三件事。全文件 100 行左右（完整版在模板工程），核心逐段拆：

### 1. 向量表：必须躺在映像偏移 0

```asm
.section .isr_vector, "a", %progbits   @ 只读数据段，名字留给链接脚本 KEEP
.align  2
.global _vectors
_vectors:
    .word _estack             @ 0: 初始 MSP，硬件上电自动加载
    .word Reset_Handler       @ 1: 复位向量，硬件上电自动加载为 PC
    .word NMI_Handler         @ 2: NMI
    .word HardFault_Handler   @ 3: HardFault
    .word Default_Handler     @ 4..6: MemManage/BusFault/UsageFault
    ...
    .word SVC_Handler         @ 11: SVCall
    .word PendSV_Handler      @ 14: PendSV（FreeRTOS 上下文切换入口）
    .word SysTick_Handler     @ 15: SysTick（ch07/ch08 实验使用）

    .rept 32                  @ 外部中断 IRQ0..IRQ31
    .word Default_Handler     @ mps2-an385 的 NVIC 恰好 32 条线（num-irq=32）
    .endr
```

三个易踩的坑，都值得单独说：

- **槽 0 是 `_estack` 不是指令**。这个值在链接脚本里定义（RAM 顶端），汇编器只负责把它写成 4 字节。reserved 槽（7~10、13）必须填 `.word 0`，填处理函数反而是错的；
- **Thumb bit 由 `.thumb_func` 保证**。GNU as 只对标记过 `.thumb_func` 的符号在引用时自动置 bit0。漏标的话，向量表里存的是偶数地址，上电即 HardFault——而且这是"开机第一错"，黑屏无输出，新手极难定位；
- **`.rept 32` 的默认兜底**。没实现的异常统一指向 `Default_Handler`，比填 0 安全得多：跳到 0 会把 `0` 当指令执行，而兜底死循环配合 gdb 一眼看穿"你落进了未实现的异常"（把 `pc` 与向量表对一下就知道是几号）。

PendSV 和 SysTick 槽现在指向兜底，但 [[ch07-interrupts-nvic|第七章（中断）]] 和 [[ch08-timer-systick|第八章（SysTick）]] 会直接用强符号覆盖它们——向量表一次写全，后续章节零改动。

### 2. Reset_Handler：上电后执行的第一段软件

```asm
.section .text
.global Reset_Handler
.type Reset_Handler, %function
.thumb_func
Reset_Handler:
    /* 2a. 拷贝 .data：FLASH(_sidata) -> RAM(_sdata.._edata) */
    ldr  r0, =_sidata         @ r0 = 源指针（LMA，位于 FLASH）
    ldr  r1, =_sdata          @ r1 = 目标起点（VMA，位于 RAM）
    ldr  r2, =_edata          @ r2 = 目标终点
1:  cmp  r1, r2
    bhs  2f                   @ 起点追上终点，拷贝完成
    ldr  r3, [r0], #4         @ r3 = *src++
    str  r3, [r1], #4         @ *dst++ = r3
    b    1b

    /* 2b. 清零 .bss */
2:  movs r3, #0
    ldr  r1, =_sbss
    ldr  r2, =_ebss
3:  cmp  r1, r2
    bhs  4f
    str  r3, [r1], #4
    b    3b

4:  bl   main                 @ 进入 C 世界
5:  b    5b                   @ 防御：main 万一返回，挂死而不是乱飞
```

逐行值得说的：

- **为什么不用 C 写这段**？拷贝循环本身用 C 完全可行，但"复制 .data"隐含悖论：C 函数可能用到还没复制好的 .data 全局变量（甚至编译器生成的 memcpy 换名）。启动代码的世界里，每条指令依赖什么都必须显式，汇编是最诚实的语言；
- **`ldr r0, =_sidata` 是伪指令**：符号地址放不进 12 位立即数时，汇编器把它存进紧随其后的 literal pool（`.ltorg`），这里生成 `ldr r0, [pc, #40]`——4.6 节反汇编里能看到；
- **`bhs`（无符号高于等于）**做循环边界，r1 追上 r2 即停——经典的 `[ begin, end )` 半开区间；
- **先 .data 后 .bss** 顺序无关紧要，但**必须在 `bl main` 之前**——C 标准要求进入 main 时全局变量已是初值、静态变量已清零，否则"未定义行为"从第一行就开始。

### 3. Default_Handler 与弱符号覆盖

```asm
Default_Handler:
    b    .                          @ 死循环兜底

.weak NMI_Handler
.thumb_set NMI_Handler, Default_Handler
.weak SysTick_Handler
.thumb_set SysTick_Handler, Default_Handler
```

`.weak` + `.thumb_set` 是"默认实现 + 可覆盖"的标准手法（C 里等价 `__attribute__((weak))`）：链接器规则是**强符号覆盖弱符号**。所以应用代码只要写一个同名 C 函数 `void SysTick_Handler(void)`，向量表槽位自动指过去，启动文件一个字都不用改——这正是 STM32 HAL 启动文件的同款机制，你以后打开 `startup_stm32f407xx.s` 会会心一笑。

---

## 4.4 链接脚本逐行写：mps2_an385.ld

链接脚本回答三个问题：**东西放哪（MEMORY）、怎么摆（SECTIONS）、给启动代码留什么路标（符号）**。

### 1. MEMORY 与栈顶

```ld
ENTRY(Reset_Handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 512K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

_estack = ORIGIN(RAM) + LENGTH(RAM);
```

- `ENTRY()` 只标记 ELF 入口点（也给 `--gc-sections` 当根），**不控制硬件从哪启动**——硬件只认向量表；
- MEMORY 是"地皮划分"。名字（FLASH/RAM）只是助记，真正的语义来自属性 `(rx)`/`(rwx)` 和起址长度；
- `_estack = RAM 顶端 = 0x20020000`：栈向下生长，栈底在最高地址——这个值被 startup.S 的向量表 0 槽引用，环环相扣。

### 2. SECTIONS：一行 `.data > RAM AT > FLASH` 的分量

```ld
SECTIONS
{
    .text :
    {
        KEEP(*(.isr_vector))   /* 向量表必须在最前（VTOR 默认 0） */
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
        _etext = .;
    } > FLASH

    _sidata = LOADADDR(.data);     /* LMA：拷贝循环的源 */

    .data :
    {
        . = ALIGN(4);
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH             /* VMA 在 RAM，LMA 在 FLASH */

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss*) *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM
}
```

五处是理解的关键：

- **`KEEP(*(.isr_vector))`**：向量表没有被任何代码"引用"，不加 KEEP 会被 `--gc-sections` 当垃圾回收——映像里向量表消失，上电取到乱码 PC，黑屏。这是裸机构建**第一经典翻车点**；
- **`> RAM AT > FLASH`**：一句话写完两段式加载。`> RAM` 给 VMA，`AT > FLASH` 给 LMA——"住在 RAM，生于 flash"；
- **`_sidata = LOADADDR(.data)`**：LOADADDR 取的是 LMA；不带 LOAD 的 `.` 和 ADDR() 取 VMA。**漏写 LOADADDR（拿到 VMA）时，拷贝循环会"自己拷自己"**，全局变量初值变成随机 RAM 内容——第二经典翻车点；
- **`(NOLOAD)`**：告诉链接器 .bss 不进映像文件。若漏掉，映像里会塞一坨全零字节白白占 flash；
- **`*(COMMON)`**：古老 C 的未初始化全局变量会进 COMMON 块，不收进 .bss 会散落各处，清零循环扫不到。

### 3. 五个符号与拷贝循环的配合

启动文件和链接脚本之间唯一的接口就是这几个符号，对应关系一张表钉死：

| 链接脚本符号      | 值（本章实测）              | 启动代码里的角色        |
| ----------------- | --------------------------- | ----------------------- |
| `_sidata`         | `0x00000368`（flash 内）    | 拷贝源指针 r0           |
| `_sdata`          | `0x20000000`                | 拷贝目标起点 r1         |
| `_edata`          | `0x20000004`                | 拷贝目标终点 r2         |
| `_sbss` / `_ebss` | `0x20000004` / `0x20000008` | 清零区间 [r1, r2)       |
| `_estack`         | `0x20020000`                | 向量表 0 槽（MSP 初值） |

脚本末尾还加了两个 `ASSERT`（flash/RAM 溢出即链接期报错）——把"栈顶之下必须还有 bss 空间"这类布局错误从"上电玄学黑屏"提前到"链接器一行红字"。

---

## 4.5 main.c：0 依赖直写 UART0

点亮仪式的外设是 UART0。寄存器布局同样考证自 QEMU 源码（`hw/char/cmsdk-apb-uart.c`，v10.1）：

| 偏移    | 寄存器    | 关键位                                                   |
| ------- | --------- | -------------------------------------------------------- |
| `+0x00` | DATA      | 写 = 发送一字节（固定 8N1）                              |
| `+0x04` | STATE     | bit0 TXFULL、bit1 RXFULL、bit2/3 溢出                    |
| `+0x08` | CTRL      | bit0 TX_EN、bit1 RX_EN、bit2/3 中断使能                  |
| `+0x0C` | INTSTATUS | W1C                                                      |
| `+0x10` | BAUDDIV   | 波特率 = pclk / BAUDDIV，QEMU 要求 `16 ≤ BAUDDIV ≤ pclk` |

main.c 里不引任何头文件，寄存器就是三个 volatile 指针：

```c
#define UART0_BASE 0x40004000UL              /* hw/arm/mps2.c: uartbase[0] */
#define UART0_DATA  (*(volatile uint32_t *)(UART0_BASE + 0x00))
#define UART0_STATE (*(volatile uint32_t *)(UART0_BASE + 0x04))
#define UART0_CTRL  (*(volatile uint32_t *)(UART0_BASE + 0x08))
#define UART0_DIV   (*(volatile uint32_t *)(UART0_BASE + 0x10))

#define SYSCLK_HZ 25000000UL                 /* mps2.c: SYSCLK_FRQ */
#define UART_BAUDDIV (SYSCLK_HZ / 115200)    /* = 217 */

static void uart_init(void)
{
    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;  /* 源码 uart_transmit():
                                                       TX_EN=0 时写 DATA 直接被丢弃 */
    UART0_DIV  = UART_BAUDDIV;
}

static void uart_putc(char c)
{
    while (UART0_STATE & UART_STATE_TXFULL)  /* 轮询发送缓冲腾空 */
        ;
    UART0_DATA = (uint32_t)c;
}
```

两个细节：

- **`volatile` 不是装饰**：没有它，编译器会把"读 STATE→判断→再读"优化成读一次死循环，或直接删掉看似无副作用的写 DATA——这是"编译器不知道内存映射寄存器有副作用"的经典问题，网上 90% 的"裸机 UART 不工作"帖子死在这里；
- **TX_EN 必须先开**：QEMU 源码里 `uart_transmit()` 开头就检查 `CTRL.TX_EN`，没使能时写 DATA 被静默丢弃（连 TXFULL 都不置位）——"先使能后使用"是外设交互通则，第六章讲 UART 协议时会再展开。

为了证明两段式加载真的发生了，main 里还埋了两个证人性变量：`data_var`（初值 `0x20260830`，落 .data）和 `bss_var`（无初值，落 .bss），加上打印本身用的字符串字面量（落 .rodata）——三个段全齐。

---

## 4.6 构建与解剖：Makefile、map、反汇编

### 1. 构建命令行

工程提供 Makefile 与 CMakeLists 两套（等价，二选一）。核心就一行链接命令：

```bash
arm-none-eabi-gcc -mcpu=cortex-m3 -mthumb -nostdlib -T mps2_an385.ld \
  -Wl,--gc-sections -Wl,-Map=build/ch04-baremetal.map \
  -o build/ch04-baremetal.elf build/startup.o build/main.o
```

| 选项                      | 作用                                                                        |
| ------------------------- | --------------------------------------------------------------------------- |
| `-mcpu=cortex-m3 -mthumb` | M3 只有 Thumb-2，无 ARM 态；漏 `-mthumb` 链接期报 "blx/interworking" 类错误 |
| `-nostdlib`               | 不要 crt0、不要 libc——启动文件我们自己写，本章的立身之本                    |
| `-T mps2_an385.ld`        | 指定链接脚本，覆盖默认布局                                                  |
| `-Wl,--gc-sections`       | 按 section 级裁剪未引用代码（配合 `-ffunction-sections`）                   |
| `-Wl,-Map=...`            | 输出 map 文件，布局的"账本"                                                 |

CMake 路线用 `CMAKE_SYSTEM_NAME=Generic` + 指定交叉编译器即可（README 有完整命令）。构建结果：

```text
$ make
   text	   data	    bss	    dec	    hex	filename
    872	      4	      4	    880	    370	build/ch04-baremetal.elf
```

872 字节代码、4 字节 .data（恰好一个 data_var）、4 字节 .bss——一个"hello world 的完整代价"，对比桌面 Linux 上 glibc 动态链接 hello 的 16KB text + 一堆依赖，这就是裸机的体重。

### 2. readelf：两段式加载的 ELF 证据

`.data > RAM AT > FLASH` 最终落在程序头的 VirtAddr/PhysAddr 分离上：

```text
$ arm-none-eabi-readelf -l build/ch04-baremetal.elf

Program Headers:
  Type           Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align
  LOAD           0x001000 0x00000000 0x00000000 0x00368 0x00368 R E 0x1000
  LOAD           0x002000 0x20000000 0x00000368 0x00004 0x00008 RW  0x1000
```

第二个 LOAD 段 `VirtAddr=0x20000000`（运行时在 RAM）而 `PhysAddr=0x00000368`（初始值紧跟 .text 尾部躺在 flash）——**LMA≠VMA 直接可见**，且 `MemSiz(8) > FileSiz(4)` 的差值正是 .bss（文件里没有，运行时要有）。QEMU 加载器按 PhysAddr 放置映像，扮演了"烧写工具"的角色。

### 3. map 文件：布局的账本

```text
$ grep -E '_sidata|_sdata|_edata|_sbss|_ebss|_estack|isr_vector' build/ch04-baremetal.map
                0x20020000   _estack = (ORIGIN (RAM) + LENGTH (RAM))
 .isr_vector    0x00000000       0xc0 build/startup.o
                0x00000368   _sidata = LOADADDR (.data)
.data           0x20000000        0x4 load address 0x00000368
                0x20000000   _sdata = .
                0x20000004   _edata = .
.bss            0x20000004        0x4 load address 0x0000036c
                0x20000004   _sbss = .
                0x20000008   _ebss = .
```

`.data 0x20000000 ... load address 0x00000368` 一行同时写出 VMA 和 LMA——排查"变量初值不对"时先看这行，确认 `load address` 落在 flash 区间内。

### 4. objdump：向量表与 Reset_Handler的真实形态

```text
$ arm-none-eabi-objdump -d build/ch04-baremetal.elf

00000000 <_vectors>:
   0:  20020000  .word 0x20020000     ← 槽0：初始 MSP（= _estack）
   4:  000000c1  .word 0x000000c1      ← 槽1：Reset_Handler(0xc0) | Thumb bit
   8:  000000eb  .word 0x000000eb      ← NMI → Default_Handler(0xea)|1
   c:  000000eb  .word 0x000000eb      ← HardFault（后略，兜底槽同值）
  ...
  3c:  000000eb                          ← 槽15 SysTick（暂指向兜底）

000000c0 <Reset_Handler>:
  c0:  480a      ldr  r0, [pc, #40]     ← =_sidata（literal pool）
  c2:  490b      ldr  r1, [pc, #44]     ← =_sdata
  c4:  4a0b      ldr  r2, [pc, #44]     ← =_edata
  c6:  4291      cmp  r1, r2
  c8:  d204      bcs.n d4 ...
  ca:  f850 3b04 ldr.w r3, [r0], #4     ← *src++
  ce:  f841 3b04 str.w r3, [r1], #4     ← *dst++ = r3
  d2:  e7f8      b.n  c6                ← .data 拷贝循环
  ...
  e4:  f000 f840 bl   168 <main>        ← 进入 C 世界
  e8:  e7fe      b.n  e8                ← 防御死循环
```

对照检查三件事：向量表确实在 0 地址、槽 0 是 `0x20020000`、槽 1 的 `0xc1` 末位是 1（Thumb）。main 里的 UART 轮询也能在反汇编里直接看到硬件地址：

```text
0000010e <uart_putc>:
 10e:  f04f 2340  mov.w r3, #1073758208  @ 0x40004000   ← UART0 基址
 112:  685b       ldr   r3, [r3, #4]                    ← 读 STATE
 114:  f013 0f01  tst.w r3, #1                          ← TXFULL?
 118:  d1f9       bne.n 10e                             ← 忙等
 11a:  f04f 2340  mov.w r3, #0x40004000
 11e:  6018       str   r0, [r3, #0]                    ← 写 DATA
```

**"直写 0x40004000"不再是一个说法，而是反汇编里可见的立即数**。

---

## 4.7 点亮仪式：QEMU 里的第一行输出

### 1. 运行

```bash
cd practice/hwbasics/ch04-baremetal-template
make run        # = qemu-system-arm -M mps2-an385 -kernel build/ch04-baremetal.elf -nographic
```

退出 QEMU：`Ctrl-A` 然后 `X`。批量记录输出用 `-display none -serial stdio` 配 `timeout`（README 有现成命令）。真实输出：

```text
hello baremetal
text  : FLASH 0x00000000 .. _etext 0x00000368
.data : copy 0x00000368 (LMA in FLASH) -> 0x20000000 (VMA in RAM)
.bss  : zero 0x20000004 .. 0x20000008
data_var @ 0x20000000 = 0x20260830 (reset copy OK)
bss_var  @ 0x20000004 = 0x00000000 (zero OK)
stack  : MSP top 0x20020000
```

逐行验尸：

- `data_var = 0x20260830`——**初值正确就是 .data 拷贝成功的证明**：QEMU 把初值放在 0x368（LMA），是 Reset_Handler 把它搬到了 0x20000000（VMA）。如果拷贝循环有 bug（比如 `_sidata` 误用 VMA），这里会打出 RAM 上电随机值；
- `bss_var = 0x00000000`——清零循环工作的证明（QEMU 的 RAM 复位值恰好也是 0，此项真机上更有意义；更硬的证据是 readelf 的 FileSiz < MemSiz）；
- `stack: MSP top 0x20020000`——与向量表槽 0、readelf、map 三方互证。

### 2. gdb 实证："设 MSP、跳 Reset_Handler 是硬件干的"

4.1 的三步引导是文档断言，现在用 gdb 变成观察事实。`make gdb` 起 `-S -s`（CPU 冻结在复位后第一条指令前），另一终端连接：

```text
$ gdb -batch -ex "set architecture arm" -ex "target remote :1234" \
      -ex "x/4wx 0" -ex "info registers sp pc lr" -ex "x/i $pc"

== memory dump 0x0 (vector table) ==
0x0:  0x20020000  0x000000c1  0x000000eb  0x000000eb
== registers BEFORE first instruction ==
sp   0x20020000
pc   0xc0        ← Reset_Handler（gdb 显示时剥掉 Thumb bit）
lr   0xffffffff  ← 复位保留值，无调用者可返回
=> 0xc0: ldr r0, [pc, #40]
```

关键推理：**我们写的映像里没有任何一条指令写过 SP**（可回看 Reset_Handler 反汇编），但第一条指令执行前 `SP` 已经等于 `[0x0]` 的值 `0x20020000`、`PC` 已指向槽 1 的目标——除了硬件，没有别人干得了这件事。这就是"上电三步"的全部实证，也是第三章向量表知识的落点。

### 3. 黑屏排查三连（真实踩坑顺序）

无输出时按概率查：一查 `KEEP(*(.isr_vector))`（map 里找不到 .isr_vector 段 = 被 gc 了）；二查向量表槽 1 的 Thumb bit（objdump 看 0x4 处是否奇数，`.thumb_func` 漏标）；三查外设先使能后使用（TX_EN/BAUDDIV 顺序）。前两条链接产物可查，第三条需要 `-d guest_errors` 让 QEMU 报"guest 错误"。

---

## 4.8 对照：这就是 ESP-IDF 把你"包起来"的部分

写完这 100 行，回头看你更熟悉的 ESP-IDF 世界，会发现本章造的每个轮子都在框架里有个对应物：

| 本章手写的                       | 框架里的对应物                                     |
| -------------------------------- | -------------------------------------------------- |
| startup.S 向量表                 | IDF 组件里的向量表 + 二级 bootloader 搬好的入口    |
| Reset_Handler 拷 .data/清 .bss   | bootloader 映射 flash 后、`app_start` 前的启动搬运 |
| mps2_an385.ld 的 MEMORY/SECTIONS | IDF 的 `sections.ld`（由 `esp32_out.ld` 等生成）   |
| Makefile 的 `-T`/`-nostdlib`     | 构建系统里隐藏的同款选项                           |

读过 [[ch3-esp-idf-build-and-bootflow|FreeRTOS 系列（三）：ESP-IDF 构建与启动流程]] 的读者现在可以精确对上：ROM 固化代码 → 二级 bootloader → 应用入口那条链，本质上就是本章"上电三步"的多级放大——ROM 是芯片厂写死的 Reset_Handler，bootloader 是 Espressif 写的 Reset_Handler，你手写的这个才是最底层赤裸的形态。[[ch1-from-bare-metal-to-rtos|FreeRTOS 系列（一）]] 从裸机讲起、[[ch21-stack-and-memory-layout|系列（二十一）的内存布局]] 讲任务栈，本章的 `_estack`/两段式加载正是它们的物理地基。

> [!tip] 本系列的 STM32/GD32 主线定位
> 上述 ESP-IDF 只作为"框架包了什么"的对照参照（读者已从 FreeRTOS 系列熟悉它），本章主线自始至终是 Cortex-M3 + mps2-an385，后续外设实验不再涉及 ESP。

RISC-V 侧预告一句：GD32VF103 上电没有"从 0 地址取向量表设两个寄存器"这套——取而代之的是 `mtvec`（\_trap 入口基址）、`a0/mhartid` 传参和一段 C 启动例程（crt0）干的同类活。同一件事两套架构解法，[[ch09-riscv-gd32-contrast|第九章（RISC-V 侧起点）]] 对照展开——届时本章模板里每一个符号（\_sidata/向量表/Default_Handler）都会有它的 RISC-V 镜像。

---

## 4.9 小结与预告

本章把 Cortex-M 的"开机"拆到了不可再分的三步硬件行为，然后逐行造出承接它的全部软件：向量表（.isr_vector + Thumb bit + 弱符号兜底）、Reset_Handler（.data 拷贝 + .bss 清零 + bl main）、链接脚本（MEMORY/SECTIONS/`AT >`/LOADADDR 五符号）、最小构建（-nostdlib -T），最后用 0 依赖的 UART0 直写打出了 `hello baremetal`，并用 gdb 把"硬件设 SP/PC"钉成了观察事实。

拿到手的最重要资产是 **`practice/hwbasics/ch04-baremetal-template/`**：后续章节只往里加外设代码——GPIO、NVIC、SysTick、定时器，启动链一章永逸。裸机世界从此有了"开屏第一行"，接下来补它缺的两样东西：时钟（多快？）和引脚（怎么动？）。下一章 [[ch05-gpio-and-mco|嵌入式硬件基础（五）：GPIO 与时钟树]]——RCC 时钟树怎么从一棵外部 8MHz 晶体长成 168MHz 系统时钟，以及 RM0090 里 GPIO 寄存器的点灯读写。
