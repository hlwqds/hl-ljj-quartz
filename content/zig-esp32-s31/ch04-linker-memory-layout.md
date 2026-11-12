---
title: "Zig × ESP32-S31 全栈开发（四）：链接脚本与内存布局"
date: 2026-11-13 18:00:00
description: "从 IDF 托管切到形态 B：用一份自己写的 S31 链接脚本把 .text/.rodata/.data/.bss 放进 SRAM，用 naked _start 关中断、设栈、清 bss、跳 main，再用 esptool elf2image 生成镜像、由 IDF 二级 bootloader 加载；附 readelf/nm/image-info 的验收口径与真机排错清单。"
tags: [zig, esp32-s31, riscv, linker, memory, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. **第四章：链接脚本与内存布局**
> 5. [[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]

# Zig × ESP32-S31 全栈开发（四）：链接脚本与内存布局

前三章我们一直在回答“镜像从哪来、长什么样”：ch02 用 IDF 的 CMake 工程把 Zig 静态库塞进 `app_main`，ch03 把镜像头、段表、分区表逐字节拆开。这一章换掉最后一根拐杖——**Zig 自己产出 ELF，段的摆放、入口、栈和 `.bss` 边界全部由我们决定**。这是系列路线图里“形态 B”的起点，从这一章起，应用构建链里不再有 `idf.py`、CMake 或任何一个 IDF 组件；IDF 只剩一个身份：二级 bootloader 与分区表的供应商。

这一章的技术含量不在“能编过”，而在“每一段为什么在那个地址”。因此验收不靠“灯亮了”，而靠四份可以互相印证的证据：`readelf` 的段表、`nm` 的符号表、`esptool image-info` 的镜像头、以及串口上那两行文本。前三个在主机上就能核对，最后一个必须在真机上做。

> [!warning] 本章的证据边界
> 链接脚本里的地址来自 ESP-IDF v6.1 的 `esp32s31` 内存定义与 pre-release 手册，Zig 目标串在 Zig 0.17.1 下实测过；本工程已于 2026-11-13 在 ESP32-S31 CoreBoard-1（rev v0.0）**真机跑通**：`hello form B` + 每秒 `tick B`，连跑 14 s 无复位，原始输出见 `../logs/ch04-boot.log`；构建链与两个 flash 段也在本仓执行过。

---

## 4.1 为什么切到形态 B

### 1. 三条链，三份责任

ch02 的形态 A 与本章的形态 B，差别不在“用什么语言写应用”，而在**谁对镜像负责**：

| 环节            | 形态 A（ch02）                       | 形态 B（本章起）                    |
| --------------- | ------------------------------------ | ----------------------------------- |
| 编译            | Zig 静态库 `libmain_zig.a`           | Zig 可执行文件 `app.elf`            |
| 链接            | IDF 的 CMake 工程与 IDF 链接脚本     | 本工程的 `linker/s31.ld`            |
| 入口            | IDF 启动代码 → `app_main`            | 镜像头 entry → `_start`             |
| 段布局          | IDF 决定（IRAM/DRAM/IROM/DROM 全套） | 本工程决定（本章先全部放 SRAM）     |
| 镜像打包        | `idf.py build` 内部调用 esptool      | 显式 `esptool elf2image`            |
| 二级 bootloader | IDF                                  | IDF（供应商步骤，`idf-bootstrap/`） |
| 分区表          | IDF                                  | IDF（同上）                         |
| 构建工具        | CMake + Ninja + `idf.py`             | `zig build`                         |

形态 A 的价值是“把变量减到一个”：第一次上电时只验证 Zig 目标代码、ABI、静态库链接。形态 B 的价值是把控制权拿回来：从这一章起，**每一段的地址、栈的位置、`.bss` 的边界都是我们写的**，出问题时可以逐项对照手册与 `readelf`，而不是在一份几万行的 IDF 链接脚本里找“到底是谁把 `.text` 放到了这里”。

### 2. 形态 B 拿回了什么，又放弃了什么

拿回来的：

- **入口可控**。`ENTRY(_start)` 是唯一入口，镜像头的 entry 字段就是 `_start` 的地址；`_start` 里做什么，读 20 行汇编就全知道。
- **布局可解释**。段顺序、对齐、栈顶、`.bss` 范围都是链接脚本里的一行，改一行就改布局。
- **构建链可移植**。`zig build` 在 Linux/Windows/WSL 上行为一致，不需要 IDF 的 CMake、不需要 Python 环境。

放弃的（本章的诚实边界）：

- **没有 IDF 的启动代码**：没有 `esp_system` 初始化、没有 `esp_timer`、没有 `init_array` 遍历、没有堆初始化。我们只用掩膜 ROM 里的两个函数。
- **没有 IRAM/DRAM 之分**：本章全部段都在 SRAM，等于放弃了“flash 映射 + cache”这条优化路径——这是刻意的，见 4.2 与 4.3。
- **没有中断**：`_start` 第一步就关中断，本章不设 `mtvec`，任何异常都会跳到 bootloader 留下的向量上（行为未定义）。CLIC 与异常处理是 ch07 的事。

### 3. 启动链上到底谁跳到谁

形态 B 的完整链条（括号里是负责人）：

```text
上电
 └─ 掩膜 ROM（芯片，不可改）
     └─ 二级 bootloader @ Flash 0x2000（IDF，idf-bootstrap 产出）
         ├─ 读分区表 @ Flash 0x8000，找到 factory 应用 @ 0x10000
         ├─ 校验镜像（XOR 校验和 / SHA256），按段表把各段搬到装载地址
         └─ 跳到镜像头的 entry 字段
             └─ _start（本工程，SRAM）
                 └─ main（本工程，Zig）
```

这条链里，**我们能改的只有最后两跳**。bootloader 与分区表仍然是 IDF 的二进制，这是形态 B 与形态 C（ch28，自己写 bootloader）的分界线。本章不碰它们，但必须知道它们读什么：镜像头的 entry、段表、校验和——这正是 ch03 拆过的东西。

---

## 4.2 S31 的内存地图

### 1. 五个区间

先钉死本章会用到的地址。它们来自 ESP-IDF v6.1 的 `esp32s31` 内存定义（`components/esp_system/ld/esp32s31/memory.ld.in`）与 pre-release 手册：

| 区域           | 地址范围                  | 大小 / 说明                                | 本章用法           |
| -------------- | ------------------------- | ------------------------------------------ | ------------------ |
| SRAM           | `0x2F000000`–`0x2F07AFC0` | `0x7AFC0`（约 492 KiB）                    | 全部段 + 栈        |
| LP SRAM        | `0x2E000000`–`0x2E008000` | 32 KiB，低功耗域                           | 不用               |
| 掩膜 ROM       | `0x2F800000` 一带         | 320 KiB，出厂固化的函数（`ets_printf` 等） | 只调两个函数       |
| IROM/DROM 窗口 | `0x40000020` 起           | Flash 经 cache/MMU 映射后的取指/只读窗口   | 不用（下一版布局） |
| PSRAM          | `0x50000000` 起           | 16 MB，外部 PSRAM，需初始化                | 不用               |

四个细节值得停一下：

- **SRAM 结束地址是 `0x2F07AFC0` 而不是 `0x2F080000`**。这 `0x40` 字节的尾巴不属于应用可用的 SRAM 段。链接脚本里 `LENGTH = 0x7AFC0` 就是从这个差值来的：`0x2F07AFC0 - 0x2F000000 = 0x7AFC0`。抄地址时**抄区间，不抄“看起来整齐”的 0x80000**。
- **ROM 的基址可以从符号反推**。IDF v6.1 的 `esp32s31.rom.ld` 里，`ets_printf = 0x2f800024`、`ets_delay_us = 0x2f80003c`。两个地址只差 `0x18`，说明它们都在 ROM 的同一小段函数表里，ROM 窗口基址在 `0x2F800000` 一带。这也是为什么本工程的链接脚本可以直接 `PROVIDE` 它们的绝对地址：ROM 是掩膜，地址不会变。
- **LP SRAM 与主 SRAM 不是一个域**。`0x2E000000` 那 32 KiB 在低功耗域，需要单独的时钟/电源配置，不属于“上电就能写的 SRAM”。本章不碰它，也不要把它算进栈的空间。
- **PSRAM 不是内存条**。`0x50000000` 起的 16 MB 要经过 PSRAM 控制器初始化、cache 映射才能访问；未初始化就解引用会取到总线错误。它是后续章节的网络缓冲与素材区。

### 2. “统一 SRAM”意味着什么

ESP32-S3 是 Xtensa，指令与数据有各自的地址窗口（IRAM/DRAM）；S31 是 RISC-V，**SRAM 是统一编址的**：同一个 `0x2F000000` 既能取指也能读写。这带来两个直接后果：

1. **一个 `MEMORY` 区域就够**。本章的链接脚本只声明 `sram (rwx)`，`.text` 与 `.data` 都放进去，不需要 `iram0_0_seg` / `dram0_0_seg` 那套拆分。
2. **但“统一”不等于“免费”**。同一块 SRAM 既要放代码又要放数据还要放栈，所以栈顶、`.bss` 边界、堆起点必须在链接脚本里显式钉住，否则它们会互相踩。

> [!note] 统一编址是本章能写得这么短的原因
> 如果 S31 像 S3 一样分 IRAM/DRAM，本章就得同时处理两个区域、两套 `_stack_top`、以及“哪些函数必须在 IRAM”的问题。统一编址把这些问题推迟到“需要 flash 映射”时才出现——而那是下一版布局的事。

### 3. Cache 与 MMU：为什么先不碰 flash 映射

S31 的代码最终当然要放 Flash（16 MB），但 CPU 不能直接读 Flash 的 SPI 接口。路径是：**Flash → MMU 页表 → cache → CPU 地址窗口**。IDF 的 `memory.ld.in` 里有一行 `IDROM_SEG_SIZE = CONFIG_MMU_PAGE_SIZE << 10`，说的就是这件事：IROM/DROM 窗口的大小按 MMU 页（`CONFIG_MMU_PAGE_SIZE`，单位 KB）为粒度规划，`<< 10` 把 KB 换算成字节。

这条路径有两个硬约束，直接决定了本章的设计：

- **写/擦 Flash 期间 cache 会被关**。此时任何从 flash 取指或读常量的代码都会取到垃圾或直接崩。所以 ISR、flash 驱动、以及“擦写期间还要跑”的代码必须放在 SRAM。这是后面 ch09 的坑，本章先记住结论。
- **cache 有代价**。取指 miss、常量 miss 都是几十个周期的停顿。性能章节会拿它做文章；本章不需要，因为我们**根本不走 cache**。

于是本章的策略很干脆：**先把所有段放进 SRAM，把“链接 + 启动”这一层单独跑通**。这样出问题时，原因只可能在链接脚本、`_start`、镜像打包这三处，不会混进“MMU 页表配错”“cache 没 invalidate”这类问题。等 SRAM-only 的镜像能在真机上稳定打印，再把 `.text`/`.rodata` 迁到 `0x40000020` 起的映射窗口——那是本章末尾预告的“下一版布局”，也是 ch05 之后所有章节的默认形态。

### 4. 栈：从 `_stack_top` 往下长

RISC-V 的栈向低地址增长，`sp` 指向“当前栈顶之上第一个可用字节”。ilp32 ABI 要求 `sp` 在函数入口处 **16 字节对齐**，所以：

- `_stack_top` 取 SRAM 末尾 `0x2F07AFC0`。这个值本身就是 64 字节对齐（低 8 位为 `0xC0`），满足 16 字节要求；
- `.bss` 从 `.text` 之后向上长，`_bss_end` 与 `_stack_top` 之间的空隙就是栈 + 堆的余量；
- 本章不用堆，`_heap_start = _bss_end` 只是留个符号，后续章节接管。

一个必须建立的直觉：**链接脚本不“分配”栈，它只给一个地址**。栈用多少、会不会踩到 `.bss`，链接器不管；它只在 `.bss` 长到 `_stack_top` 附近时才会报“region overflow”。所以栈大小是靠“`.bss` 与 `_stack_top` 的差值”事后核对的，见 4.7。

---

## 4.3 链接脚本的九条不变量

完整脚本在 [`linker/s31.ld`](/static/code/#/zig-esp32-s31/ch04-linker-layout/linker/s31.ld)。它只有九十来行，但每一行都在回答“这一段放哪、符号叫什么”。下面按不变量拆开讲——第 0 条是 IDF 特有的，其余八条是**任何**形态 B 链接脚本都必须成立的，换成 flash 布局也不会变。

### 0. `KEEP(*(.app_desc))`：第一个装载段必须先放 IDF 元数据

这是本章唯一一条“不是 RISC-V 的规矩、而是 IDF bootloader 的规矩”的不变量，也是最容易被忽略的一条：**即使应用完全不用 IDF，bootloader 也要求第一个装载段以 256 字节的 `esp_app_desc_t` 开头**。

理由在 bootloader 的段处理路径上，与“应用是不是 IDF 编译的”无关：

- `process_segment` 在 `SOC_MMU_PAGE_SIZE_CONFIGURABLE` 的芯片上会读段首的魔数与 `mmu_page_size`，用它决定 flash → cache 的映射页大小；读不到就打印 `Failed to fetch app description header!`，这次加载随即失败；
- `bootloader_common_check_efuse_blk_validity` 读同一份描述里的 `min_efuse_blk_rev_full` / `max_efuse_blk_rev_full`，判断 eFuse 块版本是否兼容；
- `process_esp_app_desc_data` 里的魔数校验属于另一条路径（防回滚），同样以这份结构为前提。

所以链接脚本的第一件事不是放代码，而是放元数据：

```ld
    .text : ALIGN(16)
    {
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;
        KEEP(*(.text.entry))
        *(.text .text.*)
        ...
```

三个后果必须接受：

1. **代码区不在 `0x2F000000`**：256 字节描述（加对齐）之后是 `_text_start`（本章 `0x2F000100`）；`_start` 在 `.text` 内，具体地址由链接顺序决定，用 `nm -n` 读。`ENTRY` 指向的是符号而不是偏移，所以“入口在段内哪个位置”只影响读地图，不影响跳转。
2. **`mmu_page_size`（16 = log2 64 KiB）与 `spi_flash_mode`（2 = DIO）必须与 `elf2image` 的参数一致**。描述里的值就是 bootloader 配 flash 与 MMU 的依据；两边打架，表现是校验通过但映射错位。
3. **结构大小必须恰好 256 字节**。这件事由 `src/start.zig` 的 comptime 断言守住（`@sizeOf(AppDesc) == 256` 与几个关键字段的 `@offsetOf`）——**链接脚本管位置，Zig 管布局**，两边各管一半。

还有一个段属性细节：`app_desc` 是只读常量，与 `.text` 同属性，所以两者落在同一个 `PT_LOAD` 段里，描述自然就是段 #0 的开头。如果把它写成可写变量，链接器会按权限切出另一个段，段 #0 就只剩那 256 字节——顺序仍然对，但段表变了，`elf2image` 的段数也跟着变。本章故意让它只读，就是为了“段 #0 = 描述 + 代码”这个干净结构。

`app_elf_sha256` 本章填零：它服务于镜像与 ELF 的对应关系校验（安全启动/回滚路径），本章两项都不启用；需要时再回填。

### 1. `ENTRY(_start)`：入口是数据，不是约定

```ld
ENTRY(_start)
```

`ENTRY` 把 ELF 头里的 `e_entry` 设成 `_start` 符号的地址。这个值会被 `elf2image` 原样写进镜像头的 entry 字段，bootloader 最后就是跳到这个地址。三个后果：

- 如果忘了 `ENTRY`，链接器会退回默认入口（`.text` 的起始地址）——本章那里正好是 `esp_app_desc_t` 的魔数，跳进去必崩，而且串口上一行都不会有；
- 如果 `_start` 被编译器改名（比如写成 `pub fn` 而非 `export fn`），链接期报 `undefined symbol: _start`；
- 验收口径很硬：`readelf -h app.elf` 的 `Entry point address` 必须等于 `nm` 里 `_start` 的地址。两者不等，后面所有调试都是猜。

### 2. `MEMORY`：先声明区间，再谈段

```ld
MEMORY
{
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}
```

三个字段各有含义：`rwx` 是这个区域的权限（读/写/执行），`ORIGIN` 是起点，`LENGTH` 是长度。注意 `LENGTH` 写的是 `0x7AFC0`（区间差值），不是 `0x80000`（“看起来像 512 KB”的整数）。写大了，链接器会把段放到不存在的 SRAM 上，表现为“烧录成功、跳转即崩”。

本章只有一个区域，是因为 SRAM 统一编址；等引入 flash 映射时，这里会变成三个区域（SRAM、IROM、DROM），段的归属也随之改变。

### 3. 段顺序与归属

```ld
    .text : ALIGN(16)
    {
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);
        _text_start = .;
        KEEP(*(.text.entry))
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(16);
        _text_end = .;
    } > sram
```

五个决定：

1. **`.app_desc` 是 `.text` 的第一个输入段**，所以第一个 `PT_LOAD` 从元数据开始；`_text_start` 紧随其后（`0x2F000100`）。`_start` 在 `.text` 内，具体地址由链接顺序决定，读 `nm -n`；入口不在区段首字节是常态——`ENTRY` 指向的是符号，不是偏移。
2. **`.rodata` 跟 `.text` 放一起**。两者都是只读，将来整体迁到 flash 映射窗口时可以一段搬走；现在就拆开只会让布局更难解释。
3. **`KEEP(*(.text.entry))`** 预留给“必须最先放置的入口段”。本章的 `_start` 走 `.text`，这一条是给后续把向量表/入口单独成段时用的钩子——`KEEP` 防止 `--gc-sections` 把它丢掉；上面的 `.app_desc` 同理，不 `KEEP` 就可能被当成“没人引用的常量”丢掉。
4. **段首段尾都 `ALIGN(16)`**。段内指令与数据本身有各自的对齐要求，但段边界对齐到 16 是为了后面 ELF 段（`PT_LOAD`）的页对齐与 `elf2image` 的段切分都干净。
5. **`_image_start` 与 `_text_start` 分开记**。前者是段 #0 的起点（元数据），后者是代码起点；排错时这两个符号能立刻区分“镜像头对不上”和“入口对不上”。

`.data` 与 `.bss` 同理：

```ld
    .data : ALIGN(16)
    {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(16);
        _data_end = .;
    } > sram

    .bss (NOLOAD) : ALIGN(16)
    {
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        _bss_end = .;
    } > sram
```

`.bss` 的 `(NOLOAD)` 是关键：它告诉链接器“这一段在文件里不占字节，只有地址与长度”。这正是为什么镜像里没有 `.bss` 的内容，也是为什么 `_start` 必须自己清零——**没人替你清**。`*(COMMON)` 是 C 的 tentative definition 遗留，Zig 不生成它，但保留一行不花钱。

### 4. `_stack_top`：栈顶是一个符号

```ld
    _stack_top = ORIGIN(sram) + LENGTH(sram);
```

`_start` 里的 `la sp, _stack_top` 取的就是这个值。三件事必须同时成立：

- 它是 **16 字节对齐**的（`0x2F07AFC0` 天然满足）；
- 它**在 SRAM 里**（不是 `0x2F080000` 那种“越界一点点”的地址）；
- 它 `.bss` 之后**留够余量**（见 4.7 的符号差值核对）。

把栈顶交给链接脚本而不是写死在汇编里，好处是换板子、改布局时只改一处；坏处是“符号错了也能链接成功”，所以只能靠 `nm` 核对。

### 5. `_bss_start` / `_bss_end`：清零的范围

`.bss` 的语义是“程序启动时全零”。镜像里没有它的内容（`NOLOAD`），bootloader 也不会替你清，所以 `_start` 必须把 `[_bss_start, _bss_end)` 逐字写零。两个符号因此是**启动代码与链接脚本之间的契约**：

- 少了 `_bss_start`，`_start` 链接失败（`undefined symbol`）；
- 少了末尾的 `ALIGN(4)`，区间长度可能不是 4 的倍数，逐字清零会越过 `_bss_end` 一个字节，踩到 `.bss` 后面的东西（本章后面是 `_heap_start`，暂时无害，但这是运气不是设计）。

> [!tip] 为什么 `.data` 的边界不是“契约”，`.bss` 的边界才是
> `.data` 有初值，镜像里带着内容，bootloader 按段表搬到 VMA 就完事；`.bss` 没有内容，只能靠代码清零。凡是“没人替你做”的事，就必须有符号把范围钉死。

### 6. `_data_*` 与 VMA/LMA：本章为什么不用拷贝

```ld
    _data_load_start = LOADADDR(.data);
    _data_load_end = LOADADDR(.data) + SIZEOF(.data);
```

两个概念必须先分清：

| 概念 | 名字     | 含义                                  | 谁关心                     |
| ---- | -------- | ------------------------------------- | -------------------------- |
| VMA  | 运行地址 | 程序运行时这条指令/这个变量在哪个地址 | CPU、`sp`、取指            |
| LMA  | 装载地址 | 镜像里这份字节应该被搬到哪个地址去    | bootloader / `_start` 搬运 |

本章的脚本没有给 `.data` 指定 `AT>`，所以 **`LOADADDR(.data) == ADDR(.data)`**，也就是 `_data_load_start == _data_start`。因此 `_start` 的第 4 步是空的——不是“忘了写”，而是这个布局里**没有搬运这回事**。

将来把 `.data` 放到 flash（LMA 在 flash，VMA 在 SRAM）时，两个符号就会不同，`_start` 必须补上这段循环：

```text
la t0, _data_load_start     # 源：flash 里的初值
la t1, _data_start          # 目标：SRAM 里的运行地址
la t2, _data_end
循环：lw t3, 0(t0); sw t3, 0(t1); 各加 4; t1 != t2 时继续
```

> [!important] 本章刻意让 LMA == VMA
> 如果一上来就做 flash 布局，`.data` 的搬运、`.rodata` 的 cache 访问、`_start` 里“搬运时不能读 flash”的顺序问题会同时出现。先让 `_data_load_start == _data_start`，就能把“五个步骤”里的第 4 步变成一句注释，其余四步单独验证。

### 7. 对齐：三个层次

链接脚本里的对齐不是仪式，每一处对应一个真实约束：

| 位置                      | 对齐    | 原因                                                 |
| ------------------------- | ------- | ---------------------------------------------------- |
| 段边界（`.text`/`.data`） | 16 字节 | ELF `PT_LOAD` 段切分与 `elf2image` 的段头/校验和边界 |
| `.bss` 起点               | 4 字节  | `_start` 逐字清零，越界写会踩坏后面的数据            |
| `_stack_top`              | 16 字节 | ilp32 ABI：函数入口处 `sp` 必须 16 字节对齐          |

`. = ALIGN(16);` 这种写法把“当前地址向上取整”写进脚本，比手工填地址可靠。要注意的是：`ALIGN` 只改当前地址，不会补字节到镜像里——段之间的空隙在镜像里不存在，只要段的 LMA 正确，bootloader 按段搬就行。

### 8. `0x20`：flash 映射窗口的固定偏移

本章不用 flash 映射，但这个数字必须提前解释，否则下一版布局会变成“抄来的一串神秘地址”。

S31 的 flash 映射窗口基址在 `0x40000000` 一带，但**应用的第一段从窗口基址 + `0x20` 开始**，即 `0x40000020`。也就是说，窗口最前面的 32 字节不拿来放应用内容，链接地址一律带这个偏移。这个约定在所有 ESP 芯片上都成立（ESP32 的 IROM 是 `0x400D0020`，S31 的窗口从 `0x40000020` 起），因此它不是可调参数，而是**链接脚本与 MMU 配置之间的固定常数**。

本章的实用结论只有一句：将来把 `.text` 迁到映射窗口时，`ORIGIN` 要写 `0x40000020`，而不是 `0x40000000`。至于这 32 字节在 ROM 侧到底承担什么语义，以 TRM 的 Flash MMU 章节为准（S31 手册仍是 Pre-release v0.7，转正后复核）。

---

## 4.4 `_start` 的五个步骤

完整代码在 [`src/start.zig`](/static/code/#/zig-esp32-s31/ch04-linker-layout/src/start.zig)。它是全章最短、也最不能错的文件：二十来条指令，任何一条顺序错了都会表现为“静默重启”或“没有输出”。

### 1. 为什么必须是 naked 函数

```zig
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        ...
    );
}
```

`callconv(.naked)` 告诉 Zig：**不要生成序言和收尾**。理由很直接——普通函数的序言会先动 `sp`（保存 `ra`、`s0`），而此刻 `sp` 还是 bootloader 留下的值，甚至可能指向我们即将覆盖的 `.bss`。在“栈还没建立”的时刻，任何编译器生成的序言都是负担。

三个约束：

- **函数体里不要写需要栈的东西**：局部变量、运行时分支、函数调用都不要，逻辑全部写进 `asm`。编译期可判定的 `if`/`switch` 是允许的——Zig 自己的 `std.start` 里的 `_start` 就那么写；但任何会需要序言或栈帧的语句都会被拒绝。
- **`export` 让符号名就是 `_start`**。不加 `export`，Zig 会把函数改名（`start._start` 一类），链接脚本的 `ENTRY` 就找不到它。
- **`asm volatile`**：不写 `volatile`，优化器可能认为这段汇编没有副作用而删掉——那正是我们全部的启动代码。

### 2. 第 1 步：关中断

```asm
csrci   mstatus, 0x8          # mstatus.MIE = 0
csrw    mie, zero             # 关掉所有中断源
```

`mstatus.MIE` 是全局中断使能位（bit 3），`csrci` 用立即数把它清掉；`mie` 是每个中断源的使能位，整体写零是双保险。为什么第一步就做：

- bootloader 跳过来时，中断状态是它留下的，**我们不知道**；
- 本章不设 `mtvec`（异常/中断向量），一旦有中断进来，CPU 会跳到 bootloader 留下的向量上，行为完全不可预期；
- 关中断只花两条指令，放在任何可能触发异常的指令之前最省心。

> [!note] 本章不“打开”中断，也不设向量
> 真正的顺序是“设 `mtvec` → 配 CLIC → 开 `mie` → 开 `mstatus.MIE`”，四步缺一不可。本章一步都不做，原因是应用不需要中断；把这四步留给 ch07，可以让“启动”与“中断”两类问题不混在一起。

### 3. 第 2 步：设置栈指针与 `gp`

```asm
la      sp, _stack_top
la      gp, __global_pointer$
```

`la` 是“load address”伪指令，由汇编器展开成 `auipc` + `addi`，链接期由 `_stack_top` 的最终值填充。这一条之后，函数调用、局部变量、`ra` 保存才有地方放。

`gp` 是 RISC-V 的 small-data 锚点：链接器 relaxation 可能把某些 `la`/全局变量访问优化成 `gp` 相对寻址（±2 KiB）。IDF 的启动代码会设置它，我们的 `_start` 也必须做；链接脚本在 `.data` 内、`.sdata` 之前定义 `__global_pointer$ = . + 0x800`，正好覆盖 small-data 窗口。它归入“设置栈”这一步，不改变本章的五步结构。

顺序上它必须排在第 1 步之后、第 3 步之前：

- 早于第 1 步没有意义（关中断不需要栈）；
- 晚于第 3 步则危险：清零 `.bss` 的循环用了 `t0/t1`，一旦编译器/汇编器需要栈（本章不需要，但换实现就可能需要），`sp` 还是脏值。

`_stack_top` 的 16 字节对齐由链接脚本保证，这里不再 `andi sp, sp, -16`——**对齐应该由布局保证，而不是每条路径都补一次**。

### 4. 第 3 步：清零 `.bss`

```asm
la      t0, _bss_start
la      t1, _bss_end
bgeu    t0, t1, 2f
1:
sw      zero, 0(t0)
addi    t0, t0, 4
bltu    t0, t1, 1b
2:
```

四件事：

- **用 `bgeu`（无符号比较）**：地址是无符号数，`bge` 在有符号语义下遇到高位为 1 的地址会判错。
- **先判断区间是否为空**：`_bss_start == _bss_end` 时（应用没有 `.bss`）直接跳过，避免“先写一个字再判断”的越界写。
- **按 4 字节写**：`.bss` 起点与长度都对齐到 4，逐字写不会越界；逐字节写虽然也不错，但没必要。
- **标签用数字局部标签**（`1:`/`2:`/`1b`/`2f`）：`b` 是 backward，`f` 是 forward，同名标签可以重复出现，不会与其它汇编冲突。

不清 `.bss` 的症状很有辨识度：全局变量初值看起来是随机数、指针变量指向野地址、偶尔第一次上电正常（SRAM 恰好是零）而热复位后崩。这类 bug 在“能打印 hello”的阶段往往被忽略，等引入状态机才爆发。

### 5. 第 4 步：搬运 `.data`（本章为空）

```asm
# 本布局把 .data 也放在 SRAM，LOADADDR(.data) == _data_start，
# 所以没有搬运。
```

这一步在源码里是注释而不是指令，理由在 4.3 第 6 条：LMA == VMA。留这段注释是为了让“五个步骤”的结构完整——**结构比指令重要**，将来换成 flash 布局时，你知道该往哪个位置插循环。

### 6. 第 5 步：调用 `main`

```asm
call    main
3:
wfi
j       3b
```

`call` 把返回地址放进 `ra` 并跳到 `main`。`main` 不应该返回（它是个 `while (true)`），但**防御性写法**必须有：如果它真返回了（比如被改成条件退出），`wfi` 让核进入等待，`j 3b` 保证不会跑飞进未定义的地址。裸机程序没有“退出”这回事，落到随机地址比停机更糟。

### 7. 为什么本章不碰 FPU

`eabihf` 意味着浮点运算会被编译成硬件指令（`fadd.s` 一类），而硬件浮点只有在 `mstatus.FS != 0`（Initial/Clean/Dirty）时才可用。本章的 `_start` **没有设置 `FS`**，`main` 里也**没有任何浮点运算**——两边一致，所以安全。

这个约束必须写进脑子：只要哪天在 `main` 里加一句 `const x: f32 = 1.5;`，编译器可能生成 `fmv.w.x`，而 `FS = 0` 时执行浮点指令会触发 illegal instruction。届时要么在 `_start` 里置 `FS`（并接受上下文切换要保存 F 寄存器），要么坚持整数运算。打开 FPU 与保存 F 寄存器是 ch10（上下文切换）的前置条件，本章不动。

---

## 4.5 工程走读

工程在 `practice/zig-esp32-s31/ch04-linker-layout/`，一共十个文件（含 README）：

```text
ch04-linker-layout/
├── build.zig                      # 目标串 + 链接脚本 + app.elf
├── linker/
│   └── s31.ld                     # ENTRY/MEMORY/段/符号/ROM 别名
├── src/
│   ├── start.zig                  # naked _start
│   └── main.zig                   # hello form B / tick B
├── idf-bootstrap/
│   ├── CMakeLists.txt             # 最小 IDF 工程（只产 bootloader/分区表）
│   ├── sdkconfig.defaults         # 16 MB + single-app-large
│   └── main/
│       ├── CMakeLists.txt
│       └── app_main.c             # 空实现，永不被执行
├── tools/
│   └── flash.sh                   # 读 flash_args、替换应用行、烧录
└── README.md
```

| 文件                               | 代码浏览                                                                                 |
| ---------------------------------- | ---------------------------------------------------------------------------------------- |
| `build.zig`                        | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/build.zig)                        |
| `linker/s31.ld`                    | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/linker/s31.ld)                    |
| `src/start.zig`                    | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/src/start.zig)                    |
| `src/main.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/src/main.zig)                     |
| `idf-bootstrap/CMakeLists.txt`     | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/idf-bootstrap/CMakeLists.txt)     |
| `idf-bootstrap/main/app_main.c`    | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/idf-bootstrap/main/app_main.c)    |
| `idf-bootstrap/sdkconfig.defaults` | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/idf-bootstrap/sdkconfig.defaults) |
| `tools/flash.sh`                   | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/tools/flash.sh)                   |

### 1. `build.zig`：只做三件事

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/start.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    app.setLinkerScript(b.path("linker/s31.ld"));

    const install = b.addInstallArtifact(app, .{ .dest_sub_path = "app.elf" });
    b.getInstallStep().dependOn(&install.step);
}
```

- `standardTargetOptions` / `standardOptimizeOption` 接住 `-Dtarget`、`-Dcpu`、`-Doptimize`，同一个脚本在主机与交叉目标下都能用；
- `root_source_file` 指向 `src/start.zig`（不是 `main.zig`）：根文件决定“哪些文件会被分析”，而 `main.zig` 是通过 `start.zig` 的 `@import` 进来的；
- `setLinkerScript` 是形态 B 与形态 A 最大的一行差别；
- `addInstallArtifact(.{ .dest_sub_path = "app.elf" })` 把产物安装成 `zig-out/bin/app.elf`（默认名是 `app`，不带扩展名，容易和 `.bin` 混）；
- 整个文件里**没有** `idf.py`，这是 CI 会用 grep 断言的纪律项。

### 2. `linker/s31.ld`：完整脚本

```ld
/*
 * ch04-linker-layout —— 形态 B 的最小链接脚本（SRAM-only 布局）
 *
 * 这一版做两件事：
 *   1) 在第一个装载段的最前面放 256 字节的 esp_app_desc_t（IDF bootloader 认
 *      镜像的前提，见 src/start.zig 的 app_desc）；
 *   2) 把 .text/.rodata/.data/.bss 全部放进 SRAM，让 ENTRY(_start) +
 *      esptool elf2image + IDF 二级 bootloader 这条链在最小假设下成立。
 *
 * 所有段的 LMA == VMA，所以 _start 不需要搬运 .data；flash 映射
 * （IROM/DROM 窗口 0x40000020）留到下一版布局。
 *
 * 地址来源：ESP-IDF v6.1 的 esp32s31 内存定义
 *   IDF_PATH/components/esp_system/ld/esp32s31/memory.ld.in
 * 其中 SRAM 段为 0x2F000000 .. SRAM_SEG_END（0x2F07AFC0），长度 0x7AFC0。
 * 本文件只抄录这个区间；段布局是本工程自己写的，不复制 IDF 的链接脚本。
 * S31 的 TRM 仍是 Pre-release v0.7，手册转正后逐项复核。
 */

ENTRY(_start)

MEMORY
{
    /* RISC-V 的 SRAM 是统一编址：取指与读写共用同一地址空间。 */
    sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0
}

SECTIONS
{
    /* 代码与只读数据放在一起：将来整体迁到 flash 映射窗口时只改这一段。 */
    .text : ALIGN(16)
    {
        /*
         * 第一个装载段必须以 esp_app_desc_t 开头：256 字节、魔数 0xABCD5432。
         * 它不是“可选元数据”，而是 IDF bootloader 识别应用的入口信息，
         * 所以必须排在 .text 的所有内容之前。大小由 src/start.zig 的
         * comptime 断言保证（@sizeOf(AppDesc) == 256）。
         */
        _image_start = .;
        KEEP(*(.app_desc))
        . = ALIGN(16);

        _text_start = .;
        KEEP(*(.text.entry))
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(16);
        _text_end = .;
    } > sram

    /* 有初值的可写数据。本布局 LMA == VMA：_data_load_start == _data_start。 */
    .data : ALIGN(16)
    {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(16);
        _data_end = .;
    } > sram

    /* 零初始化数据：NOBITS，镜像里只有地址与长度，内容由 _start 清零。 */
    .bss (NOLOAD) : ALIGN(16)
    {
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        _bss_end = .;
    } > sram

    /* .data 的装载地址。只有 .data 从 flash 装载时它才会不同于 _data_start。 */
    _data_load_start = LOADADDR(.data);
    _data_load_end = LOADADDR(.data) + SIZEOF(.data);

    /* 堆从 .bss 结束处向上长。本章不用堆，只留符号给后续章节接管。 */
    _heap_start = _bss_end;

    /* 栈顶在 SRAM 末尾，向下增长；必须 16 字节对齐（ilp32 ABI 要求）。 */
    _stack_top = ORIGIN(sram) + LENGTH(sram);

    /*
     * 掩膜 ROM 里的两个函数，用绝对地址提供：
     *   IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld
     *     ets_printf   = 0x2f800024
     *     ets_delay_us = 0x2f80003c
     * PROVIDE 只在符号仍未定义时生效，因此这一条不会覆盖真正的定义。
     */
    PROVIDE(esp_rom_printf = 0x2f800024);
    PROVIDE(esp_rom_delay_us = 0x2f80003c);
}
```

逐段对应 4.3 的九条不变量。开头的 `.app_desc` 是第 0 条：**它先于代码**，因为 bootloader 要在搬段之前先从段首读出 MMU 页大小与 eFuse 版本要求。

末尾两个 `PROVIDE` 是整个形态 B 里最“取巧”也最实用的部分：**不用链接 IDF 的 ROM 片段，也能拿到 ROM 函数**。IDF 自己的做法是链接 `esp32s31.rom.ld` + `esp32s31.rom.api.ld`，后者把 `ets_printf` 别名成 `esp_rom_printf`。我们只抄两个地址，语义完全一致。

`PROVIDE` 的语义要说清：它**只在该符号尚未定义时才定义**。所以它既不会与真正的 ROM 定义冲突，也允许后续章节用真实定义覆盖。写在 `SECTIONS` 里只是习惯，位置不影响结果。

### 3. `src/start.zig`：IDF 元数据 + 启动代码

文件里有两块内容，顺序就是它们在镜像里的顺序：先是 256 字节的 `esp_app_desc_t`，再是 `_start`。

```zig
const AppDesc = extern struct {
    magic_word: u32,
    secure_version: u32,
    reserv1: [2]u32,
    version: [32]u8,
    project_name: [32]u8,
    time: [16]u8,
    date: [16]u8,
    idf_ver: [32]u8,
    app_elf_sha256: [32]u8,
    min_efuse_blk_rev_full: u16,
    max_efuse_blk_rev_full: u16,
    /// MMU 页大小的 log2：16 表示 64 KiB。
    mmu_page_size: u8,
    /// SPI flash 模式：2 表示 DIO，必须与 elf2image 的 --flash-mode 一致。
    spi_flash_mode: u8,
    reserv3: u16,
    /// IDF 结构体里这里是 reserv2[18]（18 个 u32，共 72 字节，偏移 184..256）；
    /// 写成 [72]u8 与之一一对应，整个结构正好 256 字节。
    reserv2: [72]u8,
};

/// 把字符串放进定长、零填充的字段。
fn fixed(comptime text: []const u8, comptime size: usize) [size]u8 {
    var out = [_]u8{0} ** size;
    @memcpy(out[0..text.len], text);
    return out;
}

export const app_desc: AppDesc linksection(".app_desc") = .{
    .magic_word = 0xABCD5432,
    .secure_version = 0,
    .reserv1 = .{ 0, 0 },
    .version = fixed("ch04-linker-layout", 32),
    .project_name = fixed("ch04-linker-layout", 32),
    .time = fixed("00:00:00", 16),
    .date = fixed("2026-11-13", 16),
    .idf_ver = fixed("v6.1", 32),
    .app_elf_sha256 = [_]u8{0} ** 32,
    .min_efuse_blk_rev_full = 0,
    .max_efuse_blk_rev_full = 0,
    .mmu_page_size = 16, // log2(64 KiB)
    .spi_flash_mode = 2, // DIO
    .reserv3 = 0,
    .reserv2 = [_]u8{0} ** 72,
};
```

五个要点：

1. **`extern struct` 固定布局**。字段顺序就是内存偏移，编译器不许重排、不许插填充。仅靠“看起来对”不够，所以文件里还有一段 `comptime` 断言：`@sizeOf(AppDesc) == 256`，且 `magic_word` 在 0、`idf_ver` 在 112、`app_elf_sha256` 在 144、`mmu_page_size` 在 180、`spi_flash_mode` 在 181。偏移写错一个，编译期就炸，而不是等到 bootloader 拒绝启动。
2. **`linksection(".app_desc")` 决定“放哪”，`export` 决定“一定被放”**。普通的 `const` 如果没人引用，编译器可能直接不发射；链接脚本里的 `KEEP` 只能防链接器的 GC，防不了编译期。`export const` 两头都保住。
3. **字段值是给 bootloader 读的，不是给人看的**。`magic_word = 0xABCD5432` 是 IDF 的固定魔数；`mmu_page_size = 16` 表示 `log2(64 KiB)`；`spi_flash_mode = 2` 表示 DIO，必须与 `elf2image --flash-mode dio` 一致；`min/max_efuse_blk_rev_full = 0` 表示不限制 eFuse 块版本。
4. **`app_elf_sha256` 填零**。它服务于“镜像 ↔ ELF”的对应校验（安全启动/防回滚路径），本章两项都不启用。真机验证时若要开这些功能，必须回填 ELF 的真实 SHA256。
5. **`reserv2` 是 72 字节而不是 18**。IDF 的结构体里它声明为 `reserv2[18]`——18 个 `u32`，共 72 字节，覆盖偏移 184..256。写成 `[72]u8` 与之一一对应，`@sizeOf` 正好 256，前面所有字段偏移不变。

然后是启动代码：

```zig
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\        # ---- 1) 关全局中断 ----
        \\        csrci   mstatus, 0x8          # mstatus.MIE = 0
        \\        csrw    mie, zero             # 关掉所有中断源
        \\
        \\        # ---- 2) 设置栈指针与 gp ----
        \\        la      sp, _stack_top        # 向下增长；_stack_top 16 字节对齐
        \\        la      gp, __global_pointer$ # 链接器 relaxation 的 small-data 锚点
        \\
        \\        # ---- 3) 清零 .bss ----
        \\        la      t0, _bss_start
        \\        la      t1, _bss_end
        \\        bgeu    t0, t1, 2f
        \\1:
        \\        sw      zero, 0(t0)
        \\        addi    t0, t0, 4
        \\        bltu    t0, t1, 1b
        \\2:
        \\
        \\        # ---- 4) 搬运 .data ----
        \\        # 本布局把 .data 也放在 SRAM，LOADADDR(.data) == _data_start，
        \\        # 所以没有搬运。flash 布局时换成从 _data_load_start 到 _data_start
        \\        # 的逐字拷贝：
        \\        #   la t0, _data_load_start
        \\        #   la t1, _data_start
        \\        #   la t2, _data_end
        \\        #   ... 循环 lw/sw ...
        \\
        \\        # ---- 5) 进入应用 ----
        \\        call    main
        \\
        \\        # main 不应返回；万一返回就停在这里等中断。
        \\3:
        \\        wfi
        \\        j       3b
    );
}
```

文件里还有两段 `comptime` 代码，是本章最容易忽略、也最容易踩坑的地方：

```zig
const builtin = @import("builtin");
const app = @import("main.zig");

comptime {
    if (builtin.cpu.arch != .riscv32) @compileError("必须交叉编译到 riscv32");
    if (builtin.abi != .eabihf) @compileError("需要 eabihf（硬浮点）ABI");

    // 汇编里的 `call main` 对 Zig 的引用图不可见：它只是一个字符串。
    _ = &app.main;
}
```

- 前两条是防呆：用主机目标编译会立刻失败，而不是产出一个“能编不能跑”的 ELF；
- `_ = &app.main;` 解决的是**汇编引用不可见**问题。Zig 只分析“被引用到”的函数；`call main` 是字符串，编译器不知道它引用了 `main.zig` 里的 `main`，于是那个函数不会被分析、不会进目标文件，链接期报 `undefined symbol: main`。取一次函数地址是最轻的强制手段。

### 4. `src/main.zig`：`main` 的名字与约定

```zig
extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
extern fn esp_rom_delay_us(us: u32) void;

pub export fn main() void {
    _ = esp_rom_printf("hello form B\n");

    while (true) {
        esp_rom_delay_us(1_000_000);
        _ = esp_rom_printf("tick B\n");
    }
}
```

四个要点：

- **`pub export`**：`export` 保证符号名就是 `main`、按 C 调用约定调用；`pub` 让 `start.zig` 能 `&app.main` 引用它。只写 `pub fn main`，符号会变成 `main.main` 一类，汇编里的 `call main` 找不到。
- **两个 `extern fn`** 不是 IDF 的声明，而是“链接脚本已经 `PROVIDE` 了绝对地址”的承诺。名字、签名必须与 ROM 里的 C 函数一致（`int printf(const char*, ...)`、`void delay_us(uint32_t)`）。
- **`esp_rom_printf` 写的是 ROM 控制台**，恒定输出到 UART0（GPIO58/59），不受任何 Kconfig 影响。这一点与 ch02 相同。
- **每行以 `\n` 结尾**，因为 ROM 的 `printf` 不会替你补换行。

### 5. `idf-bootstrap/`：只当供应商

```cmake
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(zig_s31_bootstrap)
```

```cmake
idf_component_register(SRCS "app_main.c" INCLUDE_DIRS ".")
```

```c
void app_main(void)
{
}
```

```ini
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_ESPTOOLPY_FLASHSIZE="16MB"

CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=y
```

这四行配置加上一个空 `app_main`，就是全部的 IDF 代码。它存在的唯一理由是：IDF 的构建要求 `main` 组件提供一个 `app_main`，缺了会链接失败；有了它，`idf.py build` 才能走完，从而顺带产出：

```text
idf-bootstrap/build/bootloader/bootloader.bin
idf-bootstrap/build/partition_table/partition-table.bin
idf-bootstrap/build/flash_args
```

**这个工程产出的应用镜像不会被烧进去**：`tools/flash.sh` 会把 `flash_args` 里 `0x10000` 那一行替换成本工程的 `app.bin`。因此 `idf-bootstrap` 里的 `app_main` 永远不执行——它的作用只是让工具链有东西可链接。

目标芯片不写进 `sdkconfig.defaults`：`idf.py --preview set-target esp32s31` 会写进生成的 `sdkconfig`（生成物，不入库），这样同一份 defaults 不会在切目标时打架。

### 6. `tools/flash.sh`：偏移不手抄

烧录的核心不是“记住三个偏移”，而是“**偏移只有一个来源**”：`idf-bootstrap/build/flash_args`。脚本逐行重写它：

```sh
CR=$(printf '\r')
TMP=${TMPDIR:-/tmp}/s31-flash-args.$$
trap 'rm -f "$TMP"' EXIT HUP INT TERM

app_lines=0
: > "$TMP"

while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$CR"}
    case $line in
        '' | '#'*)      continue ;;
        --*)            printf '%s\n' "$line" >>"$TMP" ;;
        0x*)
            offset=${line%% *}
            case $offset in
                0x10000 | 0X10000 | 0x010000) app_lines=$((app_lines + 1)) ;;
                *)                            printf '%s\n' "$line" >>"$TMP" ;;
            esac
            ;;
        *)              printf '%s\n' "$line" >>"$TMP" ;;
    esac
done <"$FLASH_ARGS"

APP=$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")
FLASH_DIR=$(cd "$(dirname "$FLASH_ARGS")" && pwd)
printf '0x10000 %s\n' "$APP" >>"$TMP"
( cd "$FLASH_DIR" && esptool --chip esp32s31 -p "$PORT" -b 921600 write-flash "@$TMP" )
```

五个设计决定：

1. **`--flash_mode`/`--flash_freq`/`--flash_size` 原样保留**：它们来自 IDF 生成的配置，手工抄一遍迟早会与模组不一致。
2. **bootloader 与 partition-table 两行原样保留**：偏移（`0x2000`、`0x8000`）与文件名都来自 `flash_args`，脚本里不出现这两个数字。
3. **只替换 `0x10000` 那一行**：这是 single-app-large 里 factory 应用槽的偏移，也是本工程唯一“我们的东西”要落地的位置。匹配不到就报错退出，而不是猜。
4. **`@$TMP` 传参**：esptool 的 `@file` 语法把参数文件当命令行读，避免在 shell 里拼一长串。
5. **路径重锚**：`flash_args` 里的 bootloader/partition-table 路径是相对其 build 目录的；脚本先把 `app.bin` 锚成绝对路径，再 `cd` 到 `FLASH_DIR` 执行 esptool。否则从工程根执行时会去找 `practice/.../bootloader/bootloader.bin`，烧录第一步就失败。

脚本里没有任何 `idf.py`，也没有任何偏移常量（除了应用槽 `0x10000`）——这正是“形态 B 的应用构建链不依赖 IDF”的可检查形式。

---

## 4.6 构建、镜像与烧录

### 1. 应用 ELF

```bash
cd practice/zig-esp32-s31/ch04-linker-layout

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

产物 `zig-out/bin/app.elf`。三个 `-D` 一个都不能省：漏了 `-Dtarget` 会按主机目标编（`comptime` 里的两条断言会直接拦住），漏了 `-Dcpu` 会用默认 RISC-V 特性集（可能缺 `c`/`f`/`zicsr`，`csrci` 这类指令就编不出来）。

### 2. 镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`elf2image` 从 ELF 里取三样东西：

| 取什么 | 从哪来                           | 写到镜像的哪里                      |
| ------ | -------------------------------- | ----------------------------------- |
| entry  | `ENTRY(_start)` 的最终地址       | 8 字节头里的 entry 字段             |
| 段列表 | `PT_LOAD` 段（`.text`、`.data`） | 每个段的 8 字节头（装载地址、长度） |
| 段内容 | 段的文件内容                     | 段数据本体                          |

然后它补上 16 字节扩展头（WP 引脚、驱动强度、芯片 ID、最低版本、保留位、SHA256 标志）、1 字节 XOR 校验（初值 `0xEF`）与可选的 32 字节 SHA256。`.bss` 因为 `NOLOAD` 不在段表里，所以镜像里没有它的字节——这与 4.3 第 3 条完全对应。

还有一个容易忽略的事实：**段 #0 的第一个字节不是 `_start`，而是 `esp_app_desc_t` 的魔数**。镜像的前 32 字节是 8 字节头 + 16 字节扩展头 + 8 字节段头，因此 `app.bin` 偏移 `0x20` 处正好是 `0xABCD5432`（小端 `32 54 cd ab`）。bootloader 先读它决定 MMU 页大小与 flash 模式，再搬段、最后才跳到 entry。

`--flash-mode dio`/`--flash-size 16MB`/`--flash-freq 80m` 必须与模组一致。这三个参数进了镜像头，bootloader 会按它们配置 SPI flash；填错轻则校验失败，重则启动循环。

### 3. bootloader 与分区表

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

`esp32s31` 在 IDF v6.1 是 **preview target**，`set-target` 与 `list-targets` 必须带 `--preview`，且 `--preview` 是 `idf.py` 的全局选项，位置在子命令之前。本仓已有 S31 实机基线（[[onvif-deep-dive|ONVIF 深度解析系列]]的 [[ch11-esp32s31-lab-plan|第十一章]]与 `practice/onvif-labs/SPEC.md`）用的就是这个写法。

### 4. 烧录

```bash
sh tools/flash.sh COM7                    # Windows（Git Bash / MSYS2）
sh tools/flash.sh /dev/ttyUSB0            # Linux
```

烧录顺序由 `flash_args` 决定：bootloader（`0x2000`）、分区表（`0x8000`）、应用（`0x10000`）。分区表的细节 ch03 拆过：表本身在 `0x8000`，占一个 `0x1000` 扇区，条目 32 字节、魔数 `0xAA50`，应用偏移要求 64 KB 对齐——`0x10000` 正是这个规则下的 factory 槽。

### 5. 预期输出的形态

> [!info] 下面是 2026-11-13 的实测输出（完整见 `../logs/ch04-boot.log`）
> 二级 bootloader 的日志行数与内容随 IDF 版本和 Flash 参数变化，**以实际串口为准**；应用侧确认“一次 `hello form B` + 每秒 `tick B`”。

```text
（二级 bootloader 日志：版本、Flash 模式/大小、分区表、镜像校验，完整见日志）
hello form B
tick B
tick B
tick B
tick B
```

验收点：`hello form B` 恰好一次且在 `tick B` 之前；`tick B` 约每秒一行（节奏由 ROM 忙等决定，不做毫秒级断言）；串口 115200 8N1，走 UART0。

---

## 4.7 验收：哪几份证据

### 1. `readelf -h`：入口对不对

```bash
riscv32-esp-elf-readelf -h zig-out/bin/app.elf
```

看 `Entry point address`，它必须等于：

```bash
riscv32-esp-elf-nm zig-out/bin/app.elf | grep -w _start
```

两个值不等，说明 `ENTRY(_start)` 没生效或 `_start` 被改名。这是排错的第一分叉口——入口错了，后面什么都别谈。

### 2. `readelf -l`：段与 VMA/LMA

```bash
riscv32-esp-elf-readelf -l zig-out/bin/app.elf
```

看每个 `LOAD` 段的 `VirtAddr` 与 `PhysAddr`：本章两者必须相同（LMA == VMA）。段 #0 的 `VirtAddr` 应为 `0x2f000000`，它的**前 256 字节是 `esp_app_desc_t`**，`_text_start` 在 `0x2f000100`；`_start` 在段 #0 内，具体地址读 `nm -n`；`.data` 紧随 `.text`。若 `PhysAddr` 与 `VirtAddr` 不同，说明脚本里出现了 `AT>`，而 `_start` 里没有搬运循环——那就是 4.3 第 6 条被打断了。

> [!note] 关于 map 文件
> Zig 的 `build` 不生成 GNU ld 风格的 `.map`。本章的“地图”由三份输出代替：`readelf -S`（段表与地址）、`readelf -l`（段属性与 VMA/LMA）、`nm -n`（按地址排序的符号表）。需要更细的指令级视图时用 `objdump -d`。这不是妥协——`nm -n` 对“符号落在哪个地址”比 map 文件更直接。

### 3. `nm -n`：栈与 `.bss` 的余量

```bash
riscv32-esp-elf-nm -n zig-out/bin/app.elf | grep -E '_image_start|_text_(start|end)|_data_|_bss_|_stack_top|_heap_start| main$| _start$'
```

这张表要能回答四个问题：

| 检查                                               | 期望                                                                                                               |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `_image_start` / `_text_start` / `_start` / `main` | `_text_start` 应为 0x2f000100；`_start` 在段 #0 内，具体地址由 `nm -n` 读出，不假设等于 `_text_start`；`main` 可达 |
| `_data_load_start`                                 | 等于 `_data_start`（本布局）                                                                                       |
| `_bss_end`                                         | 小于 `_stack_top`，差值就是栈 + 堆的余量                                                                           |
| `esp_rom_printf`                                   | 出现在符号表里（`PROVIDE` 生效），或链接期根本没有未定义符号                                                       |

如果 `_bss_end` 与 `_stack_top` 只差几百字节，要么减小 `.bss`，要么把栈挪到别处（后续章节会显式切任务栈）。本章的应用只有几十字节静态数据，正常应该差出几十万字节。

### 4. `objdump -d`：前二十条指令

```bash
riscv32-esp-elf-objdump -d zig-out/bin/app.elf | head -40
```

`_start` 的第一条指令应该是清 `mstatus.MIE`（`csrci` 或等价的 `csrrc`），第二条是清 `mie`，随后是 `auipc`/`addi` 组合出的 `la sp, _stack_top`。如果开头出现了 `addi sp, sp, -16` 或 `sw ra, ...`，说明函数不是 naked 的——那是链接脚本之外的另一个“入口不对”的原因。

### 5. `objdump -s` / `xxd`：段 #0 的元数据

```bash
riscv32-esp-elf-objdump -s -j .text zig-out/bin/app.elf | head -20
xxd -s 32 -l 4 zig-out/bin/app.bin
# 没有 xxd 时（Windows 原生环境常见）用 od：
od -A x -t x1z -j 32 -N 4 zig-out/bin/app.bin
```

第一条看 ELF 里 `.text` 段的前 16 字节，第二看镜像里同样的位置。镜像的布局是 8 字节头 + 16 字节扩展头 + 8 字节段头 = 32 字节，所以**镜像偏移 `0x20` 正好是段 #0 的第一个字节**，也就是 `esp_app_desc_t` 的 `magic_word`：小端存储下应读到 `32 54 cd ab`。

再往后两个关键字节：

| 镜像偏移 | 字段             | 期望值        | 含义                         |
| -------- | ---------------- | ------------- | ---------------------------- |
| `0x20`   | `magic_word`     | `32 54 cd ab` | `0xABCD5432`，小端           |
| `0xD4`   | `mmu_page_size`  | `10`          | 16 = log2(64 KiB)            |
| `0xD5`   | `spi_flash_mode` | `02`          | 2 = DIO，与 `elf2image` 一致 |

（偏移换算：镜像里段 #0 从 `0x20` 开始，`0x20 + 180 = 0xD4`，`0x20 + 181 = 0xD5`。）这三个字节是“bootloader 会不会认这个镜像”的最短判据：魔数不对，它会先报 `Failed to fetch app description header!`；页大小或 flash 模式不对，镜像能被读进来但映射/时钟会错位。

### 6. `image-info`：镜像头

```bash
esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

五项必须同时成立：魔数 `0xE9`；段数与 ELF 的 `PT_LOAD` 数量一致（本章是 2）；entry 等于 `_start`；校验和 `valid`；SHA256 `valid`。字段名与措辞以 esptool 5.2 的实际输出为准，第一次跑通后把真实片段存进 README。

### 7. 验收状态表

| 检查项                         | 证据                                             | 状态                 |
| ------------------------------ | ------------------------------------------------ | -------------------- |
| Zig 目标能力                   | `--show-builtin`（系列级实测）                   | 已验证（2026-11-12） |
| 应用 ELF 产出                  | `zig build ...` → `zig-out/bin/app.elf`          | 待首次构建回填       |
| 入口与符号一致                 | `readelf -h` 的 entry == `nm` 的 `_start`        | 待首次构建回填       |
| VMA == LMA                     | `readelf -l`                                     | 待首次构建回填       |
| 段 #0 以 `esp_app_desc_t` 开头 | `xxd -s 32 -l 4 app.bin` → `32 54 cd ab`         | 待首次构建回填       |
| 栈与 `.bss` 余量               | `nm -n` 的 `_bss_end` / `_stack_top`             | 待首次构建回填       |
| 镜像字段                       | `esptool image-info`                             | 待首次构建回填       |
| IDF 供应商步骤                 | `idf.py --preview set-target esp32s31` + `build` | 待真机验证           |
| 烧录                           | `sh tools/flash.sh <PORT>`                       | 待真机验证           |
| 应用输出                       | 串口 `hello form B` + 每秒 `tick B`              | 待真机验证           |

---

## 4.8 排错

形态 B 的失败几乎都能归到六类：入口、段地址、符号、镜像头、IDF 元数据、以及“bootloader 与我们的 SRAM 打架”。按这个顺序查，比看串口猜要快。

| 现象                                                    | 最可能的原因                                                                        | 处置                                                                                                            |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 链接报 `undefined symbol: _start`                       | `ENTRY(_start)` 找不到同名符号：函数没 `export`，或名字被改                         | `nm` 看符号名；确认 `export fn _start`                                                                          |
| 链接报 `undefined symbol: main`                         | `main` 没 `export`（成了 `main.main`），或 `start.zig` 没引用它                     | 用 `pub export fn main`；保留 `_ = &app.main;`                                                                  |
| 链接报 `undefined symbol: esp_rom_printf`               | 链接脚本没生效，`PROVIDE` 没被看到                                                  | 确认 `setLinkerScript` 指向 `linker/s31.ld`；`nm` 看是否为绝对地址                                              |
| `readelf -h` 的 entry 不是 `_start` 的地址              | 用了默认链接脚本，或 `ENTRY` 写错大小写/下划线                                      | 对照 `nm` 与 `readelf`；确认脚本被 `setLinkerScript` 使用                                                       |
| 烧录成功但立刻重启、无应用输出                          | 段地址与二级 bootloader 占用的 SRAM 重叠（见下）                                    | 抬高 `sram` 的起点或 `.text` 起点；对照 IDF bootloader 链接脚本的 loader 段范围                                 |
| `image-info` 报校验失败                                 | 镜像被截断，或 flash 参数与实际不符                                                 | 重跑 `elf2image`；确认 dio/16MB/80m                                                                             |
| bootloader 报 `Failed to fetch app description header!` | 段 #0 不是以 `esp_app_desc_t` 开头：`.app_desc` 没放最前、被优化掉、或不足 256 字节 | 确认 `KEEP(*(.app_desc))` 在 `.text` 最前；`export const app_desc`；`xxd -s 32 -l 4 app.bin` 应为 `32 54 cd ab` |
| bootloader 能加载但映射/时钟异常                        | 描述里的 `mmu_page_size`/`spi_flash_mode` 与 `elf2image` 参数不一致                 | 两边统一为 `16` / `2`（DIO），改完重新 `elf2image`                                                              |
| `elf2image` 报段地址非法                                | 段被放到映射窗口却没配 MMU，或脚本里漏了 `ALIGN`                                    | 回到 SRAM-only；检查段的 `ALIGN(16)` 与 `ORIGIN`                                                                |
| `flash.sh` 报找不到 `flash_args`                        | `idf-bootstrap` 没构建                                                              | 在 `idf-bootstrap/` 执行 `idf.py --preview set-target esp32s31 && idf.py build`                                 |
| `flash.sh` 报“没有 0x10000 的应用行”                    | 分区表不是 single-app-large                                                         | 确认 `sdkconfig.defaults`；删 `idf-bootstrap/sdkconfig` 后重新 `set-target`                                     |
| 串口只有 bootloader 日志                                | entry 指错、`main` 没进镜像、或 `_start` 早期崩溃                                   | 依次查 entry → `nm` 里 `main` 是否为 `T` → `objdump` 前 20 条指令                                               |
| 全局变量初值随机、热复位后崩                            | `.bss` 没清零，或清零区间算错                                                       | 检查 `_bss_start/_bss_end` 与 `objdump` 里的清零循环                                                            |
| 串口乱码 / 什么都没有                                   | 选错 USB 口、波特率不对、端口被占用                                                 | 换 UART0（GPIO58/59），115200 8N1；USB Serial/JTAG 不是 ROM 控制台                                              |

### 关于 `0x2F000000` 与 bootloader 的重叠

本章按路线图把应用起点钉在 SRAM 基址 `0x2F000000`。但二级 bootloader 在跳转时**自己还在 SRAM 里跑**（它要先搬段、再跳转），低端 SRAM 很可能被它占着。若真机上表现为“烧录成功、立刻重启、串口没有任何应用输出”，第一件事是核对 IDF 的 `esp32s31` bootloader 链接脚本里 loader 段的结束地址，把 `sram` 的 `ORIGIN`（或 `.text` 的起点）抬到它之上再试。

这一点必须用真机验证，本文不给结论：S31 的手册仍是 Pre-release，bootloader 的段位置以 IDF v6.1 的实际链接脚本为准。

### 两条排错原则

1. **先分层，再看日志**。链接期（符号/入口）、镜像期（段/校验）、运行期（启动/抢占 SRAM）是三层，不要拿运行期现象去猜链接问题。
2. **一次只改一个变量**。链接脚本、`_start`、`elf2image` 参数、`flash_args` 同时动，最后无法归因。本章的验收表就是按“单变量”设计的。

---

## 4.9 下一章预告：时钟、复位与看门狗

本章的 `_start` 只有二十条指令，它默认“CPU 已经跑在某个频率上、外设时钟已经开着、看门狗不会咬人”。这三条假设在真机上一旦不成立，表现都是“跑了一会儿就重启”或“串口输出变乱码”。

下一章会把它们逐个拆开：40 MHz XTAL 如何经 PLL 变成 320 MHz、复位原因寄存器怎么读、SYSTIMER/TIMG 怎么用来量时间、以及看门狗在长延时与调试断点时如何不误咬。届时的 `_start` 会多出两件事——配置时钟与记录复位原因——而本章的五个步骤顺序不变。

---

## 事实来源

| 事实                                                                             | 来源                                                                                                                                                                                                                                                                                                                                          | 备注                                                                                                   |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| S31 双核 RV32IMAF C、320 MHz、512 KB SRAM、320 KB ROM                            | [Espressif ESP32-S31 产品页](https://www.espressif.com/en/products/socs/esp32-s31)                                                                                                                                                                                                                                                            | 与系列索引一致                                                                                         |
| SRAM 区间 `0x2F000000`–`0x2F07AFC0`（`SRAM_SEG_END`）                            | [IDF v6.1 `esp32s31/memory.ld.in`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_system/ld/esp32s31/memory.ld.in)                                                                                                                                                                                                             | 本工程 `LENGTH = 0x7AFC0` 由此差值而来                                                                 |
| LP SRAM `0x2E000000`–`0x2E008000`、PSRAM `0x50000000`                            | 同上（`memory.ld.in` 的区域定义）+ S31 TRM（Pre-release v0.7）                                                                                                                                                                                                                                                                                | LP 域需单独时钟/电源，本章不用                                                                         |
| IROM/DROM 映射窗口从 `0x40000020` 起                                             | 同上 + [IDF 内存类型指南](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s31/api-guides/memory-types.html)                                                                                                                                                                                                                        | `+0x20` 是窗口约定，不是可调参数                                                                       |
| `IDROM_SEG_SIZE = CONFIG_MMU_PAGE_SIZE << 10`                                    | `IDF_PATH/components/esp_system/ld/memory.ld.in`                                                                                                                                                                                                                                                                                              | 窗口按 MMU 页（KB）规划，`<<10` 换算为字节                                                             |
| ROM 符号 `ets_printf = 0x2f800024`、`ets_delay_us = 0x2f80003c`                  | [IDF v6.1 `esp32s31.rom.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.ld)                                                                                                                                                                                                                   | 链接脚本用 `PROVIDE` 抄两个绝对地址                                                                    |
| `esp_rom_printf` / `esp_rom_delay_us` 别名                                       | [IDF v6.1 `esp32s31.rom.api.ld`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_rom/esp32s31/ld/esp32s31.rom.api.ld)                                                                                                                                                                                                           | 别名关系，语义与直接写 `ets_*` 相同                                                                    |
| `esp_app_desc_t` 字段顺序、`magic_word = 0xABCD5432`、总长 256 字节              | [IDF v6.1 `esp_app_desc.h`](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_app_format/include/esp_app_desc.h)                                                                                                                                                                                                                  | 本工程 `AppDesc` 的字段与偏移逐一对应                                                                  |
| bootloader 在段处理路径要求段 #0 带 app 描述                                     | [IDF v6.1 `esp_image_format.c`](https://github.com/espressif/esp-idf/blob/v6.1/components/bootloader_support/src/esp_image_format.c)（`process_segment` / `process_esp_app_desc_data`）、[`bootloader_common_check_efuse_blk_validity`](https://github.com/espressif/esp-idf/blob/v6.1/components/bootloader_support/src/bootloader_common.c) | `SOC_MMU_PAGE_SIZE_CONFIGURABLE` 下读魔数与 `mmu_page_size`；eFuse 检查读 `min/max_efuse_blk_rev_full` |
| 镜像格式：8 字节头 + 16 字节扩展头 + 段 + XOR 校验 + SHA256                      | [esptool Firmware Image Format (ESP32-S31)](https://docs.espressif.com/projects/esptool/en/latest/esp32s31/advanced-topics/firmware-image-format.html)                                                                                                                                                                                        | ch03 逐字段拆过                                                                                        |
| `elf2image` 与 `--flash-mode dio --flash-size 16MB --flash-freq 80m`             | [esptool `elf2image` 文档](https://docs.espressif.com/projects/esptool/en/latest/esp32s31/esptool/elf2image.html)                                                                                                                                                                                                                             | 参数写进镜像头，必须与模组一致                                                                         |
| 分区表 `0x8000`、factory 应用 `0x10000`、条目 32 字节                            | [IDF 分区表指南（ESP32-S31）](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s31/api-guides/partition-tables.html)                                                                                                                                                                                                                | single-app-large 的 factory 槽在 `0x10000`                                                             |
| `esp32s31` 是 IDF v6.1 preview target                                            | [practice/onvif-labs/SPEC.md](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)、[[ch11-esp32s31-lab-plan\|ONVIF 第十一章]]                                                                                                                                                                                        | `set-target`/`list-targets` 必带 `--preview`，且在子命令之前                                           |
| Zig 目标串 `riscv32-freestanding-eabihf` + `generic_rv32+m+a+c+f+zicsr+zifencei` | 系列 2026-11-12 在 Zig 0.17.1 下 `zig build-lib --show-builtin` 的实测输出                                                                                                                                                                                                                                                                    | 只覆盖编译，不覆盖链接与烧录                                                                           |
| `sp` 在函数入口 16 字节对齐                                                      | [RISC-V ELF psABI](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)                                                                                                                                                                                                                                                                      | ilp32 栈对齐约定                                                                                       |
| `mstatus.MIE`、`mie`、`wfi` 的语义                                               | [RISC-V Privileged Spec](https://github.com/riscv/riscv-isa-manual/releases)                                                                                                                                                                                                                                                                  | 关中断两条指令的依据                                                                                   |
| `callconv(.naked)` 的用法与限制                                                  | [Zig 0.17 语言参考](https://ziglang.org/documentation/0.17.1/)                                                                                                                                                                                                                                                                                | 函数体只能是一个 `asm` 表达式                                                                          |

## 自查清单

进入下一章前，确认能回答这些问题：

- [ ] 形态 B 与形态 A 的分界线在哪三个环节？为什么本章仍然需要 IDF（`idf-bootstrap`）？
- [ ] `0x2F07AFC0` 与 `0x2F080000` 差在哪？`LENGTH = 0x7AFC0` 是怎么算出来的？
- [ ] 为什么 SRAM 统一编址让链接脚本只需要一个 `MEMORY` 区域？
- [ ] `_start` 为什么要用 `callconv(.naked)`？普通函数序言在此时会破坏什么？
- [ ] 五个步骤的顺序能不能换？把“设栈”放到“清 `.bss`”之后会怎样？
- [ ] 为什么 `.bss` 必须自己清零，而 `.data` 不用自己搬？本章的 `_data_load_start` 为什么等于 `_data_start`？
- [ ] 为什么“非 IDF 镜像”也要在段 #0 放 `esp_app_desc_t`？bootloader 从里面读哪两个字段做什么？
- [ ] `mmu_page_size = 16`、`spi_flash_mode = 2` 与 `elf2image` 的哪个参数对应？不一致会怎样？
- [ ] `PROVIDE` 的语义是什么？它为什么不会覆盖真正的 ROM 定义？
- [ ] `pub export fn main` 里的 `export` 和 `pub` 各解决什么问题？少一个会报什么错？
- [ ] `tools/flash.sh` 为什么不能手写 `0x8000`/`0x10000`？`flash_args` 是什么时候生成的？
- [ ] 若真机出现“烧录成功但反复重启”，第一件事查什么？
- [ ] 本章为什么不用 FPU？在 `main` 里加一句浮点运算会发生什么？

---

下一章把 `_start` 的“隐含假设”逐条变成代码：40 MHz XTAL 与 PLL 如何把核推到 320 MHz、复位原因寄存器怎么读、SYSTIMER/TIMG 如何做微秒级计时、看门狗在长延时与断点调试时怎么不误咬。时钟配错的表现是乱码与随机重启，因此那一章会先建立“可测量的时间基准”，再动任何外设。[[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]。

系列导航：[[ch03-boot-image-partition|上一章]] · [[zig-esp32-s31|系列索引]]
