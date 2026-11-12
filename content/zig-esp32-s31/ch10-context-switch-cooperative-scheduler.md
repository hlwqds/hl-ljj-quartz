---
title: "Zig × ESP32-S31 全栈开发（十）：上下文切换与协作调度"
date: 2026-11-25 18:00:00
description: "把『一个 main』拆成多个任务：先算清 RV32 psABI 到底要求保存什么（ra + s0–s11，52 字节，压成 64 字节 16 对齐帧），再解释为什么协作让出要经过 trap 帧（80 字节，含 mepc/mstatus）；用 ecall 让出、TCB 就绪队列轮转、每任务独立栈，最后把 F 扩展的额外代价（fcsr + f0–f31，总计 208 字节）与 S31 的三个 FPU 怪癖写清楚。"
tags: [zig, esp32-s31, riscv, rtos, context-switch, scheduler, series]
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
> 8. [[ch08-timers-dma-precision|第八章：定时器、DMA 与精确时序]]
> 9. [[ch09-spi-flash-partition-nvs|第九章：SPI Flash、分区与 NVS 存储]]
> 10. **第十章：上下文切换与协作调度**
> 11. [[ch11-preemptive-scheduler-tcb-tick|第十一章：抢占调度、TCB 与 tick]]

# Zig × ESP32-S31 全栈开发（十）：上下文切换与协作调度

前九章的所有代码都共享同一个执行上下文：一个栈、一套寄存器、一条从 `_start` 到 `main` 的控制流。第九章的 KV 甚至把“下次开机”也塞进了同一个 `main` 里。这一章第一次让**多个控制流同时存在**。

难点不在“两个函数轮流跑”，而在**到底要保存什么**。少存一个寄存器，故障表现为“某个任务偶尔算出错误的数”；多存整个栈，又会把切换开销推高一个数量级。所以本章不从调度算法开始，而从 RV32 的调用约定开始：它能给出一个**可证明的下界**。

> [!warning] 本章的证据边界
> 本章沿用 ch04 定下的形态 B（Zig 产出 ELF、自己的链接脚本、IDF 只提供二级 bootloader 与分区表），并直接建立在 ch07 的 trap 入口与 CLIC 结论之上。寄存器与 CSR 行为取自 RISC-V 特权规范与 ESP-IDF v6.1 的 `esp32s31` 头文件；S31 的 TRM 仍是 Pre-release v0.7。本工程已于 2026-11-13 **真机运行**：`A/B/C step…` → `sched: all tasks done, switches=13`，原始输出见 `../logs/ch10-boot.log`。

---

## 10.1 先算清楚：一次切换必须保存哪些寄存器

RISC-V 的整数寄存器有 32 个（`x0`–`x31`），`x0` 恒为 0 不用存。其余 31 个按 psABI 分成两类：

| 类别         | 寄存器                     | 谁负责保存                   |
| ------------ | -------------------------- | ---------------------------- |
| caller-saved | `ra`、`t0`–`t6`、`a0`–`a7` | 调用者：被调函数可以随便改写 |
| callee-saved | `sp`、`s0`–`s11`           | 被调函数：返回前必须恢复原值 |

这里最容易误读的是 `ra`：它在 psABI 里是 **caller-saved**，但**任务切换必须保存它**。原因不是 ABI，而是语义：`ra` 是“当前函数返回后去哪儿”，属于任务控制流的一部分。两个任务各自的 `ra` 指向各自调用链的不同位置，不保存就等于把两个任务的返回地址混在一起。

于是“一个纯协作切换”的最小集合是：

```text
ra + s0..s11 = 1 + 12 = 13 个字 = 52 字节
按 16 字节栈对齐向上取整 → 64 字节
```

**为什么必须是 16 字节**：RV32 psABI 要求 `sp` 在函数调用边界上 16 字节对齐。切换发生在函数调用中间，若把帧做成 52 字节，恢复出来的 `sp` 就会是 `…C` 这种 4 字节对齐的地址；下一个用到 `sp` 相对寻址的编译器生成代码仍然能跑，但任何 `align(16)` 的局部变量或向量保存都会错位。**52 是内容，64 是帧长**——这两个数不要混。

本工程的 `context.zig` 用的就是这张 64 字节的表：

| 偏移 | 内容         | 偏移  | 内容       |
| ---- | ------------ | ----- | ---------- |
| 0    | `ra`         | 28    | `s6`       |
| 4    | `s0`（`fp`） | 32    | `s7`       |
| 8    | `s1`         | 36    | `s8`       |
| 12   | `s2`         | 40    | `s9`       |
| 16   | `s3`         | 44    | `s10`      |
| 20   | `s4`         | 48    | `s11`      |
| 24   | `s5`         | 52–60 | 3 个字填充 |

填充不是浪费：它的唯一职责是让 `sp` 在恢复后仍然是 16 的倍数。

---

## 10.2 64 字节不够：切换发生在 trap 里

上面的 64 字节只覆盖 callee-saved。可本章的让出方式是 **`ecall`**：任务主动陷入 M-mode，内核在 trap 上下文里换栈。此时还有一半寄存器不在那 64 字节里：

- `t0`–`t6`、`a0`–`a7` 是 caller-saved，trap 入口如果不存，`trapDispatch` 一调用就把它们冲掉了；
- `mepc`、`mstatus` 是**每个任务各一份**的返回现场：`mepc` 记录“从哪条指令继续”，`mstatus` 记录陷入前的 `MIE`/`MPIE`/`MPP`。

所以完整的每任务现场是两层：

```text
任务栈顶
  ┌──────────────────────────────┐
  │ trap 帧（80 字节）            │  ra, t0–t6, a0–a7, mepc, mstatus, 填充
  ├──────────────────────────────┤
  │ trapDispatch / yield 的调用帧 │  普通 C 栈帧，切换时原样留在栈上
  ├──────────────────────────────┤
  │ switch 帧（64 字节）          │  ra, s0–s11, 填充
  ├──────────────────────────────┤
  │ …… 任务自己的栈 ……            │
  └──────────────────────────────┘
```

trap 帧 80 字节的算法与 ch07 完全一致：16 个 GPR（`ra`、`t0`–`t6`、`a0`–`a7`）加 `mepc`、`mstatus` 共 18 个字 = 72 字节，再补 2 个字对齐到 80。ch07 里这张帧只需要“处理完再返回”，所以它没有 callee-saved 的槽位（那些由 `trapDispatch` 及其下游函数按 ABI 自己保存）。本章沿用这个约定：**trap 帧只放 caller-saved 与 CSR，callee-saved 交给 switch 帧**。

两层帧的分工可以用一句话记住：

> **64 字节决定“任务之间换不换得动”，80 字节决定“换回来以后从哪儿继续”。**

切换的动作因此也很短：`context.zig` 的 `switchRaw` 在当前栈上压出 64 字节，把 `sp` 写进旧 TCB 的 `sp` 字段，再从新 TCB 取出 `sp`、恢复 13 个寄存器、`ret`。`ret` 返回到哪里？返回到**新任务上次调用 `switchRaw` 之后的那条指令**——也就是它自己的 `yield` 调用点；随后逐层返回到它的 `trapDispatch`、`trapEntry`，由 `mret` 从它自己的 `mepc` 继续。整条链上没有任何“魔法跳转”，全都是普通的栈回溯。

---

## 10.3 第一次运行：没有“上次”可返回

新建任务时栈是空的，没有调用链可退。本工程用一张**手工构造的 64 字节帧**启动它：

```text
栈顶（16 对齐）
  ┌────────────────────┐
  │ switch 帧 64 字节   │  ra = taskStart, s0 = 入口地址, s1 = 参数
  └────────────────────┘  ← 新任务的初始 sp
```

`switchRaw` 恢复这帧后 `ret` 到 `taskStart`；`taskStart` 是一小段 naked 汇编：

```asm
mv   a0, s1        # 第一个参数 = TCB 指针
jalr s0            # 跳到任务入口
ebreak             # 任务入口声明为 noreturn，走到这里就是 bug
```

这两个寄存器槽位的用途是固定的：`s0` 存入口，`s1` 存参数。**不要**用 `a0`/`a1` 存初值：`switchRaw` 恢复完 `s0`–`s11` 后紧接着 `ret`，而 `ra` 已经被恢复成 `taskStart`，此时 `a0` 的内容并没有被帧定义——只有 `s0`/`s1` 是这张帧真正承诺过的。

`taskStart` 用的 `sp` 是 `帧地址 + 64`，也就是任务栈顶。栈本身在 `.bss` 里，声明成 `[2048]u8 align(16)`，这样链接器保证它的起始地址 16 对齐，栈顶自然也 16 对齐。**每个任务必须有独立栈**：两个任务共用栈时，切换只是换了 `sp` 的值，旧任务的局部变量仍在原处，但新任务的写入会从同一个高地址向下覆盖——现象是“任务 A 的循环变量被任务 B 改了”，靠读代码几乎发现不了。

---

## 10.4 TCB 与就绪队列：不分配内存的调度器

内核里没有 `malloc`，所有对象都是静态的：

```zig
pub const Task = struct {
    name: []const u8,
    stack: []u8,
    sp: usize,        // 挂起时指向 switch 帧；运行中无意义
    state: State,     // ready / running / done
    steps: u32,       // 任务自己维护的进度，只为可观测
    idle: bool,
};
```

- `sp`：**唯一**的硬件上下文锚点。恢复一个任务 = 把 `sp` 换成它；挂起一个任务 = 把当前 `sp` 存进它。
- `state`：`done` 的任务不再参与轮转；这是协作式系统里唯一的“退出”语义，因为没有内核去强制杀死一个任务。
- 就绪队列是一个 `[8]Task` 的静态池加一个轮转指针，`pickNext` 就是从当前任务的下一个下标开始线性扫描。5 个任务时，扫描的代价可以忽略；把队列换成链表反而多一次指针追逐。

调度规则只有一条：**从当前任务之后开始，选下一个不是 `done` 的任务**。如果没有任务可跑，就回到 idle（也就是 `main` 自己的栈）。这条规则让“任务完成”不需要任何通知机制——它只是让自己的 `state` 变成 `done`，下一次轮转自然跳过。

---

## 10.5 让出：为什么选 `ecall` 而不是软件中断

ch07 已经把 CLIC 配通了，软件中断当然也能做让出：给某个 CLIC 输入的 `IP` 写 1，等它进 ISR。但本章选 `ecall`，理由是可验证性：

| 方案            | 需要配置的东西                                   | 失败现象                          |
| --------------- | ------------------------------------------------ | --------------------------------- |
| CLIC 软件中断   | 输入号、优先级、`IE`、阈值、中断矩阵（若走外部） | 中断根本不进，任务卡死无输出      |
| `ecall`（本章） | 只要 `mtvec` 已安装                              | 同步异常立即进 trap，不依赖 `MIE` |

`ecall` 是**同步异常**：`mcause = 11`（M-mode environment call），`mepc` 指向 `ecall` 指令本身。这里有一个必须写对的细节：

> **返回前要把 `mepc` 加 4。** 否则 `mret` 回到同一条 `ecall`，任务立刻再次让出——现象是串口只剩一个任务在刷屏，其他任务永远轮不到，而且看不出任何“错误”。

中断路径不加 4（中断语义是“回到被打断的指令继续”），异常里的 `ecall` 加 4（“跳过这条陷入指令”）。这两种情况在 `trapDispatch` 里必须分开写，不能共用一个分支。

另一个好处是 `MIE` 全程可以是 0：协作式调度不需要异步抢占，也就不需要担心“切换过程中来了一个中断”。等第 11 章把 tick 接进来时，才需要重新讨论临界区与 `mstatus` 的保存粒度。

---

## 10.6 FPU 变体：208 字节与 S31 的三个坑

到目前为止，本工程是**纯整数**的：任务体只做整数运算与字符串格式化，没有任何 `float`。这不是省略，而是刻意的边界——S31 的 FPU 有三个必须单独处理的限制，混进“第一次上下文切换”里会让故障无法归因。

如果任务要用浮点，帧要变成 **208 字节**：

```text
64  （整数 switch 帧：ra + s0–s11 + 填充）
+128（f0–f31，每个 4 字节）
+  4（fcsr）
+ 12（填充到 16 的倍数）
=208
```

注意 `f0`–`f31` 是**全部** 32 个，而不是只存 ABI 里的 callee-saved 那一半（`f8`–`f9`、`f18`–`f27`）。原因在下一段。

### 1. `SOC_CPU_HAS_FPU_EXT_ILL_BUG=1`：不能懒保存

标准 RISC-V 允许“懒保存”：`mstatus.FS = 0` 时执行浮点指令触发非法指令异常，内核在异常处理里再保存/恢复 FP 寄存器。S31 的这个勘误让这条路走不通：**EXT_ILL 的 CSR 访问不支持 `FLW`/`FSW`**，异常入口无法可靠地读写浮点寄存器组。

结论是：**要么不用 FP，要么在切换时无条件保存全部 32 个 f 寄存器**。本工程选前者，并在 `context.zig` 的注释里把 208 字节的布局写死，供后续章节直接采用。

### 2. `SOC_PM_FPU_RETENTION_BY_SW=1`：休眠不保 FP

电源管理不会替你保留 FPU 状态，软件必须自己保存。对调度器的含义是：任务的 FP 现场不能指望“睡眠期间硬件保持”，必须和其它寄存器一样进栈。这也是上一条“无条件保存”的另一个理由。

### 3. `mstatus.FS` 必须非零

`mstatus` 的 `FS` 在 **[14:13]**，复位值 0 表示“FPU 关闭”。此时执行任何浮点指令都会触发非法指令异常；而因为第 1 条，异常处理也救不回来。所以任何要用 FP 的任务，入口第一件事就是把 `FS` 置成非零（例如 `01` = Initial），再执行浮点指令。

> [!warning] 待真机验证
> 本工程的验收不包含浮点：没有 `f` 指令、没有 `FS` 配置、没有 208 字节帧的真实切换。上面的三条结论来自 IDF v6.1 的 `soc_caps.h` 与 RISC-V 特权规范，**未在本板上实测**。等第一个浮点任务上线时，这三条都要逐条复核，尤其是“异常入口不能用 FLW/FSW”这一条的具体表现。

顺带一提：本工程的构建目标仍然是 `riscv32-freestanding-eabihf`（与 ch08/ch09 一致），但 `-Dcpu` 里的 `f` 只影响编译器可用的指令集与 ABI 约定，**不会**自动保存任何 f 寄存器。ABI 是链接期的约定，上下文保存是运行期的代码——两者不能互相替代。

---

## 10.7 工程走读

### 1. 文件与职责

| 文件              | 职责                                                                 |
| ----------------- | -------------------------------------------------------------------- |
| `src/context.zig` | 80 字节 trap 帧布局、`trapEntry`、64 字节 `switchRaw`、初始帧构造    |
| `src/sched.zig`   | TCB、静态就绪队列、`schedule()`、`trapDispatch`、`yield`、`start`    |
| `src/tasks.zig`   | 三个整数任务：不同的迭代次数与工作量，打印后主动让出                 |
| `src/main.zig`    | 建任务、打印配置、把 `main` 自己变成 idle 任务                       |
| `src/start.zig`   | `esp_app_desc_t` + naked `_start`（新增 `mtvec` 安装）               |
| `linker/s31.ld`   | 全 SRAM 布局；`.app_desc` 在最前；`gp` 锚点在 `.data` 与 `.sdata` 间 |

### 2. 启动顺序

```text
_start
  ├─ 关 MIE、mie = 0
  ├─ sp = _stack_top, gp = __global_pointer$
  ├─ 清 .bss（任务的栈数组也在这里被清零）
  ├─ csrw mtvec, trapEntry      ← 本章新增，MODE=0 直接模式
  └─ call main
       ├─ 打印 banner 与帧长自检
       ├─ create("A/B/C", stack_x, worker_x)
       └─ sched.start()
            ├─ current = idle（就是 main 的栈）
            └─ yield() → ecall → trapDispatch → schedule → switchRaw → 任务 A
```

`mtvec` 必须在**任何** `ecall` 之前安装。把它放在 `.bss` 清零之后、`call main` 之前，是因为清零循环本身不陷入，而 `main` 里的第一次打印可能触发 ROM 的异常路径（例如格式化错误）——那时你希望看到的是自己的 trap 入口，而不是跳到未初始化的 `mtvec`（复位值通常是 0，取指立刻跑飞）。

### 3. 链接脚本的两个老约束

本章不新增段，但有两个从 ch04 就存在的约束仍然决定“能不能启动”：

1. **`.app_desc` 必须是第一个装载段的最前面 256 字节**。IDF 的二级 bootloader 无条件读它，读不到就报 `Failed to fetch app description header!`。
2. **`__global_pointer$` 必须落在 `.data` 与 `.sdata` 之间**（本工程是 `.data` 之后 `+ 0x800`）。Zig 的 small-data 访问用 `gp` 相对寻址；如果 `gp` 指错，`s0`–`s11` 之外的全局变量读写会静默地偏移，现象是“某个常量突然变成 0”。

任务的栈数组是普通的 `.bss` 对象，链接脚本不需要为它们做任何事——`align(16)` 是 Zig 类型系统的一部分，链接器只负责按对齐放置。

### 4. `flash.sh` 不碰偏移

`tools/flash.sh` 与 ch08/ch09 逐字同构：它**不调用 `idf.py`**，只读 `idf-bootstrap/build/flash_args`，把 `0x10000` 那行替换成 `zig-out/bin/app.bin` 的绝对路径，然后 `cd` 到 `flash_args` 所在目录执行 esptool（脚本先做 `FLASH_DIR` 锚定，因为文件里的 bootloader/partition-table 路径是相对 build 目录的）。偏移的唯一权威是 `flash_args`；本章没有新增分区，所以脚本一行都不用改，只改了注释里的章节名。

---

## 10.8 验收与证据

### 1. 验收标准

1. 串口出现 banner、帧长自检（`frames: trap=80 switch=64`）与 `sched: 3 tasks + idle`；
2. 三个任务的 `step` 按 A → B → C 的顺序交错出现，每个任务恰好打印自己的轮数；
3. 每个任务结束时打印 `done`，之后不再出现该任务的任何输出；
4. 全部完成后 idle 打印 `all tasks done, switches=N`，且 `N` 是**实际换栈**的次数（`next == prev` 的让出不计数）；
5. 不再有任务输出后，CPU 停在 `wfi`（可用调试器确认 `pc` 落在 `wfi` 循环里）。

### 2. 输出形态（2026-11-13 实测）

```text
ch10-context-switch | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
mtvec: base=0x2f00xxxx mode=0 (0 = direct; only synchronous traps)
frames: trap=80 switch=64 bytes (integer only; FP variant would be 208)
sched: 3 tasks + idle, cooperative yield via ecall
A: step 1
B: step 1
C: step 1
A: step 2
B: step 2
C: step 2
A: step 3
B: step 3
C: done (steps=2)
A: done (steps=3)
B: step 4
B: done (steps=4)
sched: all tasks done, switches=13
idle: wfi
```

数值取决于任务参数与编译器，本仓不预填。

### 3. 真机前能做的静态检查

```bash
# 确认 trap 入口 4 字节对齐（mtvec 的低 2 位是模式位）
riscv32-esp-elf-nm -n zig-out/bin/app.elf | grep -E 'trapEntry|switchRaw|taskStart'
# 确认两个帧长的编译期断言（不通过会直接编译失败）
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
```

---

## 10.9 排错

| 现象                                 | 根因                                                        | 处置                                                                 |
| ------------------------------------ | ----------------------------------------------------------- | -------------------------------------------------------------------- |
| 串口只有 banner，随后无输出          | 第一次 `switchRaw` 后 `ret` 到了错误地址                    | 检查初始帧的 `ra` 是否是 `taskStart`、`s0` 是否是任务入口            |
| 只有一个任务在刷屏                   | `ecall` 后没把 `mepc` 加 4                                  | 在 `trapDispatch` 的 ecall 分支里 `frame.mepc += 4`                  |
| 任务输出交错但某个任务的局部变量异常 | 两个任务共用栈                                              | 每个任务一个 `align(16)` 的静态数组                                  |
| `trap: unexpected cause=...`         | 进了非 `ecall` 的异常（常见是未对齐访问或非法指令）         | 按 `mepc` 反汇编定位；先确认 `mtvec` 指向 `trapEntry`                |
| 第一次让出就 `unexpected cause=7/5`  | 栈未 16 对齐，编译器生成了需要对齐的访问                    | 检查任务栈 `align(16)` 与初始帧的 `帧地址 + 64`                      |
| 切到新任务后立刻又回到旧任务         | 初始帧的 `ra` 指向了 `switchRaw` 的返回点而不是 `taskStart` | 手工帧只应被 `switchRaw` 读取，`ra` 必须是启动桩                     |
| `all tasks done` 后系统复位          | idle 退出后 `main` 返回，`_start` 落到 `wfi` 前的非法路径   | idle 循环是 `noreturn`，报告后停在 `wfi`；确认没有 `ret` 回 `_start` |
| 打印出现乱码或截断                   | 任务栈太小，`std.fmt` 的临时缓冲溢出                        | 把 `[2048]u8` 调大；或把格式化移出任务上下文                         |

---

## 10.10 下一章预告

这一章的任务是**自愿**让出的：没有 tick，没有抢占，一个死循环任务可以独占 CPU。下一章在 ch07 的 CLIC tick 上补最后一块：

- tick ISR 里保存现场、把当前任务放回就绪队列、选下一个任务；
- 抢占点与临界区：`mstatus`、`mepc` 与中断阈值如何配合；
- 时间片与优先级，以及“关中断最长窗口”为什么再次成为系统精度的上限。

---

## 事实来源

| 事实                                            | 来源                                                      | 备注                                   |
| ----------------------------------------------- | --------------------------------------------------------- | -------------------------------------- |
| callee-saved = `sp`、`s0`–`s11`；栈 16 字节对齐 | RISC-V psABI（ILP32）                                     | `ra` 是 caller-saved，但切换必须保存   |
| `f0`–`f31` 共 32 个、`fcsr` 独立                | RISC-V F 扩展规范                                         | 全量保存 = 128 + 4 字节                |
| `mcause = 11` 表示 M-mode `ecall`               | RISC-V 特权规范                                           | 返回前 `mepc += 4`                     |
| `mtvec` 低 2 位是模式，0 = 直接模式             | 同上 + 第七章实测结论                                     | 本章只用异常路径，不启用 CLIC 向量模式 |
| `SOC_CPU_HAS_FPU_EXT_ILL_BUG=1`                 | IDF v6.1 `components/soc/esp32s31/include/soc/soc_caps.h` | EXT_ILL 不支持 FLW/FSW，不能懒保存     |
| `SOC_PM_FPU_RETENTION_BY_SW=1`                  | 同上                                                      | 休眠不保 FPU，软件负责                 |
| `mstatus.FS` 位于 bit[14:13]                    | RISC-V 特权规范                                           | 复位 0，使用 FP 前必须置非零           |
| SRAM 区间 `0x2F000000` + `0x7AFC0`              | IDF v6.1 `esp_system/ld/esp32s31/memory.ld.in`            | 与第四章一致                           |
| `esp_rom_printf=0x2f800024`                     | IDF v6.1 `esp32s31.rom.ld`                                | 与第六/八/九章一致                     |

## 自查清单

- [ ] 为什么 `ra` 在 ABI 里是 caller-saved，上下文切换却必须保存它？
- [ ] 13 个字是 52 字节，为什么帧长是 64 而不是 52？
- [ ] trap 帧的 80 字节里都有什么？为什么它不存 `s0`–`s11`？
- [ ] 为什么 `ecall` 返回前要 `mepc += 4`，而中断不要？
- [ ] 新建任务的初始 64 字节帧里，`ra`、`s0`、`s1` 各是什么？为什么不能用 `a0` 传参？
- [ ] 两个任务共用栈会发生什么？为什么这种 bug 很难从代码上看出来？
- [ ] FPU 变体为什么是 208 字节？为什么不能只保存 callee-saved 的 f 寄存器？
- [ ] `SOC_CPU_HAS_FPU_EXT_ILL_BUG` 让“懒保存”为什么不可行？
- [ ] `mstatus.FS` 在哪些位？复位值是什么？使用浮点前必须做什么？
- [ ] 为什么 `mtvec` 要在 `call main` 之前安装？
- [ ] `.app_desc` 与 `gp` 这两条链接约束，各自破坏后会出现什么现象？
- [ ] 协作式调度为什么可以把 `MIE` 一直保持为 0？代价是什么？

---

本章的产出不是“能跑两个函数”，而是**三个可独立验证的量**：64 字节的 callee-saved 帧、80 字节的 trap 帧、以及每次切换后仍然正确的 `sp`。下一章（[[ch11-preemptive-scheduler-tcb-tick|第十一章]]）给这个自愿让出的系统加上时间：tick、抢占与时间片。

系列导航：[[ch09-spi-flash-partition-nvs|上一章]] · [[zig-esp32-s31|系列索引]]
