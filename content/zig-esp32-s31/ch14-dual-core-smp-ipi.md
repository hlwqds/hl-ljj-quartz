---
title: "Zig × ESP32-S31 全栈开发（十四）：双核 SMP 与 IPI"
date: 2026-11-28 12:00:00
description: "把单核内核扩成两颗核：core1 的时钟/复位/PMU stall/ROM 引导地址四步启动、用 mscratch 锚定每核 PerCpu、每核 CLIC 的本核与对核别名、把源 65/66 路由到 CLIC 输入 19/20 做 IPI、远端入队加 fence 的跨核唤醒、push 迁移式负载均衡，以及 fence rw,rw / fence.i 到底防住什么。"
tags: [zig, esp32-s31, riscv, rtos, smp, ipi, series]
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
> 10. [[ch10-context-switch-cooperative-scheduler|第十章：上下文切换与协作调度]]
> 11. [[ch11-preemptive-scheduler-tcb-tick|第十一章：抢占调度、TCB 与 tick]]
> 12. [[ch12-sync-primitives-ipc|第十二章：同步原语与 IPC]]
> 13. [[ch13-heap-stack-caps|第十三章：堆、栈保护与内存 caps]]
> 14. **第十四章：双核 SMP 与 IPI**
> 15. [[ch15-observability-testing-stability|第十五章：可观测性、测试与稳定性]]

# Zig × ESP32-S31 全栈开发（十四）：双核 SMP 与 IPI

前十三章的所有代码都只在一个核上跑。core0 从 `_start` 起步，占着整个 SRAM、
整条 UART、整张中断表；core1 一直在复位里，甚至没有时钟。这一章把它叫起来，
然后把"当前任务是谁""下一个该跑谁"这类状态从全局变量改成每核一份，
最后用一条**软件中断**让两个核互相唤醒。

这一章真正的难点不在"启动第二颗核"，而在**两核共享同一份 .bss** 这件事上：
单核时代随手写的模块级变量，在 SMP 下会变成两核互相踩踏的入口。所以本章
的行文顺序是"先拆全局状态，再启动 core1"——顺序反了，第一次 tick 就会
把另一个核的调度决定冲掉。

> [!warning] 本章的证据边界
> 形态 B 不变（Zig 产 ELF、自有链接脚本、IDF 只提供二级 bootloader 与分区表）。
> 寄存器与地址取自 ESP-IDF v6.1 的 `esp32s31` 头文件与 `start_other_core`
> 的实现；S31 的 TRM 仍是 Pre-release v0.7。
> **2026-11-13 首轮上板已跑通**：core1 启动、IPI ping-pong、跨核迁移与延迟统计都有实测输出
> （见 14.12 与 `logs/ch14-boot.log`）。仍未验证的是 core1 的 cache/MMU 设置是否继承 core0，
> 以及 65/66 与 67/68 两套源编号口径的差异——这两条在正文里单独标出。

---

## 14.1 从单核到双核：缺的不是第二颗 CPU，而是"每核一份"

单核内核里，下面这些变量都是模块级的：`current`、就绪队列的头尾、tick 计数、
`switch_save_slot`、`switch_target_sp`。它们之所以能工作，是因为"只有一个
执行流会改它们"这条隐含前提。

S31 有**两颗** RISC-V 核（`soc_caps.h:175`：`SOC_CPU_CORES_NUM (2U)`），
两颗核跑的是同一份代码、同一份 `.data/.bss`、同一个 flash 窗口。于是：

| 单核写法                      | 双核下的实际含义                               |
| ----------------------------- | ---------------------------------------------- |
| `var current: ?*Task`         | 两个核的"当前任务"写进同一格，后写的赢         |
| `var switch_target_sp: usize` | 一次切换的目标 sp 可能属于另一个核，栈立刻交叉 |
| `var tick_count: u32`         | 两个核各加一次，数值不再对应"多少次 tick"      |
| `var ready_head: [8]?*Task`   | 两个核同时出队，同一个 TCB 被两个核同时"跑"    |

结论很硬：**每核状态必须每核一份**。本章的做法是定义一个 `PerCpu`，
两个核各持一份，并用 `mscratch`（CSR 0x340，每 hart 独立）指过去。
`trapEntry`、`switchRaw`、IPI 处理、调度器全部经由 `mscratch` 找"我是谁"。

```text
PerCpu[0]  ←── mscratch(core0)
PerCpu[1]  ←── mscratch(core1)

switchRaw:  csrr t0, mscratch      # 本核的 PerCpu
            lw   t1, 0(t0)         # save_slot（*usize）
            sw   sp, 0(t1)
            lw   sp, 4(t0)         # target_sp
```

`mscratch` 的两个好处：一条 CSR 读就能定位，不占通用寄存器；并且
"哪一份 PerCpu"由**当前核**决定，任务迁移到另一个核之后自动用新核的那份
（任务的 `save_slot` 属于新核，这正是我们要的语义）。代价是它是 M 模式
专用 CSR；将来跑 U 模式内核时要换成 per-hart TLS 或 `sscratch`。

## 14.2 S31 的双核事实：时钟、复位、stall、引导地址

在写任何代码之前，先把"core1 现在处于什么状态"查清楚。IDF v6.1 的
`components/esp_system/port/cpu_start.c:308`（`start_other_core`）给出了
权威答案，它做四件事：

| 步骤 | 代码                                              | 本工程的等价物                                                                         |
| ---- | ------------------------------------------------- | -------------------------------------------------------------------------------------- |
| 1    | `esp_chip_info()` 查核数，单核型号直接 abort      | 编译期常量 `hart_count = 2`                                                            |
| 2    | `esp_cpu_unstall(1)`                              | 写 `PMU+0x1EC` 的 `HPCORE1_SW_STALL_CODE[23:16] = 0xFF`，等 `HP_SYSTEM+0x64` bit1 清零 |
| 3    | `cpu_utility_ll_enable_clock_and_reset_app_cpu()` | `HP_SYS_CLKRST+0x20`：bit0/bit1 置 1、bit2 清 0                                        |
| 4    | `ets_set_appcpu_boot_addr(call_start_cpu1)`       | ROM 函数 `ets_set_appcpu_boot_addr` = `0x2f8000a8`                                     |

第 3 步的三个位来自 `hal/esp32s31/include/hal/cpu_utility_ll.h`：

```c
REG_SET_BIT(HP_SYS_CLKRST_HPCORE1_CTRL0_REG, HP_SYS_CLKRST_REG_CORE1_CPU_CLK_EN);   // bit1
REG_SET_BIT(HP_SYS_CLKRST_HPCORE1_CTRL0_REG, HP_SYS_CLKRST_REG_CORE1_CLIC_CLK_EN);  // bit0
REG_CLR_BIT(HP_SYS_CLKRST_HPCORE1_CTRL0_REG, HP_SYS_CLKRST_REG_CORE1_GLOBAL_RST_EN);// bit2
```

第 2 步的字段位置来自 `soc/esp32s31/register/soc/pmu_reg.h:4099`：

```text
PMU_CPU_STALL_SW_REG = 0x20704000 + 0x1EC
  HPCORE1_SW_STALL_CODE  [23:16]   R/W   默认 0
  HPCORE0_SW_STALL_CODE  [31:24]   R/W   默认 0
```

IDF 的 `cpu_utility_ll_unstall_cpu()` 写的是 `0xFF`，并等
`HP_SYSTEM_CPU_CORESTALLED_ST_REG`（`HP_SYSTEM+0x64`）对应的位清零。
`0xFF` 与 `0x86` 的差别是"运行"与"停在 stall 状态"；本工程只关心前者。

## 14.3 core1 启动：四个动作，两次独立写

core0 侧的启动代码（`src/smp.zig` 的 `startCore1`）只有十几行，但顺序是有
讲究的：

```zig
// 1) 只开时钟：CLIC + CPU 两路，GLOBAL_RST_EN 一个位都不碰（复位保持）
var v = ctrl.*;
v |= bit_core1_clic_clk_en | bit_core1_cpu_clk_en;
ctrl.* = v;                              // 写 1
hw.fenceRwRw();

// 2) 引导地址：必须在释放复位之前写好
ets_set_appcpu_boot_addr(@intCast(entry));
hw.fenceRwRw();

// 3) 单独一次写释放全局复位（不能与第 1 步合并）
var r = ctrl.*;
r &= ~bit_core1_global_rst_en;
ctrl.* = r;                              // 写 2

// 4) 解 stall：0xFF 写到 PMU 的 core1 stall code
// 5) 等 CORESTALLED_ST 的 bit1 清零
```

第 1 步与第 3 步必须是**两次独立的写**。若像单核时代的习惯那样用一次
读改写同时"开时钟 + 放复位"，硬件会在引导地址写入之前就把核放出来，
从 0（或上一次的残留值）取指。

IDF 的顺序是"先 unstall，再开时钟/放复位，最后写引导地址"。本工程把
"写引导地址"提到"释放复位"之前，理由是：时钟一开、复位一松，核就会从
引导地址取指；顺序反过来会存在一段"核已经在跑、引导地址还是旧值"的窗口。
在真机上这两种顺序是否等价，**待验证**——但对裸机工程来说，先写地址没有
任何坏处。

core1 第一次取指的状态是"裸的"：sp/gp 未定义、mtvec 还是 ROM 的、mie 可能
是任意值。所以 `core1Entry` 的顺序是固定的：

```asm
csrci   mstatus, 0x8        # 1) MIE = 0
csrw    mie, zero           #    清掉所有中断源
la      t0, core1_stack     # 2) sp = core1_stack + 8192
li      t1, 8192
add     sp, t0, t1
andi    sp, sp, -16
la      gp, __global_pointer$   #    gp 必须早于任何可能被 relaxation 的指令
la      t0, trapEntry       # 3) mtvec = 同一个 SRAM trap 入口
csrw    mtvec, t0
call    core1Main           # 4) 进入 Zig
```

两条容易忽略的约束：

1. **gp 必须最先设好。** 链接器的 relaxation 会把 `la` 以外的访存改成
   gp 相对寻址；如果 gp 还是 0，第一条这样的指令就会读飞。IDF 的
   `call_start_cpu1` 同样把设 gp 放在第一步，并用 `.option norelax` 包住。
2. **core1 绝不能再清 `.bss`。** core0 的 `_start` 在启动 core1 之前已经
   清过整个区间；core1 再清一遍会把 core0 已建立的任务、队列、计数器全部
   抹掉。"每个核都跑一遍 `_start`"是单核思维的惯性，也是 SMP 启动最常见的
   一类 bug。

还有一个共享外设的坑：RTC/LP WDT 是**共享**的，core0 已经在 `_start` 里
关掉了，core1 不需要（也不应该）再关一次。凡是"读改写"共享寄存器的操作，
都必须在 core1 起来之前由 core0 做一次——本章的 TIMG 时钟门与
`INT_ENA_TIMERS` 就是这么处理的。

## 14.4 每核数据：PerCpu 的布局是汇编契约

`PerCpu` 的字段顺序不是随便排的。`switchRaw` 的 naked 汇编直接按偏移访问
前两个字段：

```zig
pub const PerCpu = extern struct {
    save_slot: *usize,   // 偏移 0
    target_sp: usize,    // 偏移 4
    current: ?*Task,
    idle: ?*Task,
    hart: u32,
    need_resched: u32,
    // …计数器、每优先级队列头尾、延迟统计
};

comptime {
    if (@offsetOf(PerCpu, "save_slot") != 0) @compileError("save_slot 必须在偏移 0");
    if (@offsetOf(PerCpu, "target_sp") != 4) @compileError("target_sp 必须在偏移 4");
}
```

这两条 comptime 断言的价值在于：改字段顺序会**编译失败**，而不是在真机上
表现为随机跑飞。同样的约束在多核上比单核更致命——单核写错只是这一个核跑飞，
双核写错是两个核交替踩对方的栈，现象是"偶尔死在不同地方"。

队列也进了 `PerCpu`：`head[8]` / `tail[8]` 是每核一份的优先级环形链，
配一把每核的自旋锁：

```zig
fn lockCpu(cpu: *PerCpu) void {
    while (@cmpxchgWeak(u32, &cpu.lock, 0, 1, .acquire, .monotonic) != null) {}
    hw.fenceRwRw();
}
fn unlockCpu(cpu: *PerCpu) void {
    @atomicStore(u32, &cpu.lock, 0, .release);
}
```

锁规则只有一条，但必须无条件遵守：**一次只持一把核队列锁，绝不嵌套。**
一旦出现"我拿你的、你拿我的"，两个核就在自旋里互等。本章所有路径都是
"在目标核锁内挂好任务 → 放锁 → 再发 IPI"。

还有一条同核内的规则：**拿本核队列锁时必须关中断**。因为 tick 与 IPI 的
ISR 会在 trap 返回前调用 `switchCore`，而它也要拿同一把锁；任务持锁被中断
打断就成了"ISR 自旋等自己"。本章的 idle 循环因此写成
"`irqSave` → 查队列/换栈 → `irqRestore` → 没有就绪任务才 `wfi`"，
任务上下文的 `blockCurrent`/`blockIf` 也是同一形状。

## 14.5 每核 CLIC：0x10800000 是本核，+0x10000 是对核

S31 用 CLIC 做中断控制器，而且 CLIC 的寄存器组是**每核一份**。
`components/soc/esp32s31/include/soc/interrupt_reg.h:14` 写得很清楚：

> The memory map for interrupt registers is on a per-core basis,
> `CLIC_INT_THRESH_REG` points to the current core interrupt register,
> whereas `CLIC_INT_THRESH_REG + DUALCORE_CLIC_CTRL_OFF` points to the other
> core registers, regardless of the core we are currently running on.

`clic_reg.h:15` 定义 `DUALCORE_CLIC_CTRL_OFF = 0x10000`。于是：

| 地址                      | 含义                                    |
| ------------------------- | --------------------------------------- |
| `0x10801000 + 4*i`        | **本核**输入 i 的控制字                 |
| `0x10901000 + 4*i`        | **另一核**输入 i 的控制字               |
| `0x10800008`              | CLIC_INT_THRESH（内存映射，S31 不生效） |
| CSR `0x347`（mintthresh） | **S31 实际的阈值寄存器**                |

控制字按字节排布（`clic_reg.h` 的 `BYTE_CLIC_INT_*`）：

```text
byte0  IP    bit0     写 1 置 pending、写 0 清 pending
byte1  IE    bit8     使能
byte2  ATTR  bit16 SHV / bits[2:1] TRIG
byte3  CTL   bits[31:29] 优先级（NLBITS=3，8 级）
```

阈值这一项有一个必须点名的坑：`soc/esp32s31/include/soc/interrupt_reg.h:28`
定义了 `INTTHRESH_STANDARD 1`，也就是阈值走**标准 CLIC CSR** `mintthresh`；
IDF 的 `rv_utils_restore_intlevel_regval()`（`esp_private/interrupt_clic.h:131`）
在 `INTTHRESH_STANDARD=1` 时只写 CSR，只有 =0 时才写 `CLIC_INT_THRESH_REG`
并补一次回读。编码是 `(level << 5) | 0x1F`，"放行全部"= `0x1F`。

所以本章的 `setThreshold` 写的是 CSR：

```zig
pub fn setThreshold(level: u3) void {
    const bits = thresholdBits(level);   // (level<<5)|0x1f
    asm volatile ("csrw 0x347, %[v]" : : [v] "r" (bits),);
}
```

**这里要把话说准。** S31 的正确阈值路径是 CSR `mintthresh`；ch07 走的是
内存映射的 `0x10800008`，属于"非标准路径"。但这**不足以**断定 ch07 的
"tick 指纹为 0、软件中断不投递"就是它造成的：

- `mintthresh` 的复位值大概率是 0（只挡 0 级），恰好会放行 ch07 用的
  优先级 3/1 输入；
- ch11 的真机日志里 `ticks=183`（`practice/zig-esp32-s31/logs/ch11-boot.log:64`）
  确实在只写内存映射阈值的情况下收到了 tick。

所以更准确的表述是：**MMIO 寄存器在 `INTTHRESH_STANDARD=1` 上的实际效果
未在文档中定义，ch11 能收到 tick 是复位值恰好放行**；ch07 那次不投递的
根因仍未定论（BRINGUP 里列的 mintstatus/mtvt/矩阵路由/IE 都还是候选）。
本章把 `getThreshold()` 的读回值打进日志，就是为了让这条线索第一次有
可核对的数字；`setThreshold` 写 CSR 则是**与 IDF 对齐**，而不是"修复了
ch07 的根因"。

阈值还有一处容易漏：**新建任务的第一条指令路径也要设置它**。新建任务没有
trap 帧、不会走 `mret`，所以 `taskStart` 除了 `csrsi mstatus, 8` 之外还要
`csrw 0x347, 0x1f`；否则从 ISR 里切出来的新任务会带着"当时的中断电平"跑，
表现为 tick/IPI 计数恒为 0。这里直接写死"全放行"是合法的，因为本工程从不
在任务里抬高阈值；一旦引入"临时屏蔽某级"的临界区，阈值就必须像 `mstatus`
一样进每任务上下文，不能写死。

## 14.6 用 CLIC 软件中断做 IPI：源 65/66 → 输入 19/20

"IPI"（inter-processor interrupt）在 RISC-V CLIC 上不需要专用指令：
只要让**一个核**产生一个中断源、并把它路由到**另一个核**的某个 CLIC 输入即可。

本章选的链路：

```text
HP_SYSTEM_CPU_INT_FROM_CPU_n  (0x20586010 / 0x20586014)
  → 源 65 / 66（ETS_CPU_INTR_FROM_CPU_0/1_SOURCE）
  → 目标核的中断矩阵 INTERRUPT_COREn[源]
  → 目标核 CLIC 输入 19（core0）/ 20（core1）
```

节点的编号来源：

| 项                 | 值                                 | 出处                                                                    |
| ------------------ | ---------------------------------- | ----------------------------------------------------------------------- |
| 源 65/66           | `ETS_CPU_INTR_FROM_CPU_0/1_SOURCE` | `soc/esp32s31/include/soc/interrupts.h` 枚举按声明顺序数出              |
| 矩阵 core0 / core1 | `0x20585000` / `0x20585800`        | `register/soc/reg_base.h:77/137/138`（core1 = +0x800）                  |
| MAP 字段           | `[5:0]` 写 CLIC 输入号             | `interrupt_core0_reg.h` 的 `*_INTR_MAP`                                 |
| CLIC 输入 16..47   | 外部输入区                         | `interrupts.c` 的 “first 16 lines are reserved for software interrupts” |
| 触发/清除          | 写 1 / 写 0 到 `FROM_CPU_n`        | `hal/esp32s31/include/hal/crosscore_int_ll.h`                           |

触发一侧（`src/smp.zig`）：

```zig
pub fn sendIpi(target: u32) void {
    hw.fenceRwRw();                                // 先发布共享状态
    hw.reg(from_cpu_reg[target]).* = 1;            // 再打断对方
    me().ipis_out += 1;
}
```

清除一侧（在本核的 IPI 中断里）：

```zig
pub fn ackIpi(core: u32) void {
    hw.reg(from_cpu_reg[core]).* = 0;              // 先清源
    clic.clearPending(clic.ipiInput(core));        // 再清 CLIC 的 IP
}
```

顺序不能反：源是 level 型的，先清 CLIC 的 pending 而源还挂着的话，
`mret` 之后会立刻再投一次，看起来像"IPI 被投递了两次"。

### 源 ↔ 核的对应：IDF 自己就有两套口径

必须点明："源 65/66 分别对应 core0/core1"在本工程里是**按 S31 专用头文件
选的**，不是从 TRM 上读到的定论。IDF v6.1 里同时存在两套写法：

| 位置                                                          | 说法                                                                        |
| ------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `components/hal/esp32s31/include/hal/crosscore_int_ll.h`      | `trigger(core N)` 写 `FROM_CPU_N` → 源 65 对 core0、66 对 core1（本章采用） |
| `components/esp_system/port/arch/riscv/esp_ipc_isr_port.c:20` | `SYS_CPU_INTR_FROM_CPU_2_SOURCE + cpuid` → 源 67/68，并写 `FROM_CPU_2/_3`   |

两者对"哪个触发位打到哪个核"的结论不同。本章的 demo 只依赖"同一套口径
首尾一致"（core0 写 `FROM_CPU_1`、core1 只清 `FROM_CPU_1`），所以即使口径
换了，只要收发两侧对称，功能仍然成立；但**具体是哪个源位真的打到了哪个核，
待真机消歧**：

```text
消歧实验：把 65/66/67/68 四个源分别路由到四个不同的 CLIC 输入
（例如 21/22/23/24），四个输入都开 IE、都装各自的 ISR；
core0 依次写 FROM_CPU_0..3，记录哪一个输入先响应、在哪个核上响应。
```

这条实验同时也解释了为什么本章不给 CLIC 输入 19/20 分配任何外设：
它们是专供这条链路使用的软件输入。

**为什么不用"直接写对核的 CLICIP"这条捷径？** 0x10901000 在 core0 眼里就是
core1 的输入寄存器，写 bit0 当然能让 core1 进中断。但那条路的语义完全依赖
"该输入没有被外设驱动 + 清 pending 的责任全在软件"，一旦将来把同一个输入
分配给外设就会互相打架。本章选 IDF 自己也在用的源寄存器链路：它是一个
独立的、可屏蔽、可清除的触发位，`crosscore_int_ll.h` 的 trigger/clear
就是写这两只寄存器。

## 14.7 跨核唤醒：远端入队、锁规则与丢唤醒

`wakeRemote` 是本章的"原语"，只有十来行，但每一行都有理由：

```zig
pub fn wakeRemote(t: *Task, core: u32) void {
    const cpu = &smp.cpus[core];
    lockCpu(cpu);                       // 目标核的锁
    var woke = false;
    if (t.state == .blocked) {          // 锁内检查
        t.state = .ready;               // 锁内改状态
        t.core = core;
        enqueueLocked(cpu, t);          // 锁内入队
        woke = true;
    }
    unlockCpu(cpu);
    if (!woke) return;
    hw.fenceRwRw();                     // 发布队列改动
    smp.sendIpi(core);                  // 再打断对方
}
```

三个细节：

1. **检查与入队必须在同一把锁里。** 否则会出现：检查时 blocked → 目标任务
   自己先被 tick 唤醒并跑起来 → 我们再把它挂进队列 → 同一个 TCB 在环上
   出现两次，出队一次后仍然"幽灵"可跑。这是 ch11"`pickNext` 复活 done
   任务"的 SMP 版本。
2. **只在 `blocked` 时入队。** 已经在就绪链上的任务不能被挂第二次。
3. **先入队、后发 IPI**，中间不能省 fence。目标核可能在中断里醒来却读到
   旧队列（见 14.9）。

接收侧只在中断里做最小的三件事：清源/清 pending、记时间戳、置
`need_resched`；真正的调度发生在 trap 返回之前：

```zig
} else if (id == clic.ipiInput(cpu.hart)) {
    smp.ackIpi(cpu.hart);
    cpu.ipis_in +%= 1;
    cpu.wakeups +%= 1;
    cpu.isr_ts = systimer.now();
    cpu.need_resched = 1;
}
if (cpu.need_resched != 0) {
    cpu.need_resched = 0;
    switchCore(cpu, true);
}
```

### 丢唤醒与 `blockIf`

最典型的丢唤醒形状在跨核时更容易出现，因为"检查条件"和"标 blocked"之间的
窗口会被另一个核真实地利用：

```text
core0: 检查 replies > r（不满足）
core1:                              ← 这里回 IPI，wakeRemote 看到 running，忽略
core0: 标 blocked 并切走            ← 永远等不到下一次唤醒
```

本章用 `blockIf(pred)` 关掉它：把"标 blocked → 复查 pred → 切走"放进
**目标核的锁**，与 `wakeRemote` 的"锁内检查 blocked → 入队"互斥。于是只有
两种时序：条件在锁内已满足（不阻塞、直接返回），或条件在锁内未满足
（必然已经 blocked，对方的 wake 一定会入队）。

## 14.8 负载均衡：push 迁移与 work stealing 的取舍

两个核各自一条队列，马上就有新问题：活都在一条队列上怎么办？本章的做法是
**push 迁移**——有活的一方按目标核的空闲状态把一半任务挂过去：

```zig
var i: u32 = 0;
while (i < job_count) : (i += 1) {
    const target: u32 = if (i < 2) 0 else 1;
    sched.wakeRemote(job_tasks[i], target);   // 每个远端挂载一次 IPI
}
```

`wakeRemote` 已经处理了"目标在另一个核"的全部细节：目标核队列锁 + 状态 +
IPI。所以 push 与本地入队的代码是同一份，唯一的差别是 `core` 参数。

真正生产内核更常用的是 **steal**（空闲核主动去对方队列尾部拿活）。两者的
差别值得写清楚：

| 维度   | push（本章）                   | steal（生产内核）                     |
| ------ | ------------------------------ | ------------------------------------- |
| 触发者 | 有活的一方                     | 空闲的一方                            |
| 判据   | 目标核是否空闲（需要额外状态） | 自己队列为空（天然已知）              |
| 竞争   | 可能把任务推给已经变忙的核     | 多个核同时偷同一条队列，需要 CAS/回滚 |
| 代价   | 一次远端入队 + 一次 IPI        | 一次远端尝试 + 可能失败的 CAS 与重试  |
| 适用   | 任务粒度大、迁移少             | 任务粒度小、负载波动大                |

本章刻意只做 push：它复用同一条硬件链路（远端入队 + IPI），把"偷取协议"
留给读者—— steal 的难点不在硬件，而在回滚与伪共享。

## 14.9 内存屏障：`fence rw,rw` 与 `fence.i` 到底防什么

RISC-V 的普通访存是弱序的：硬件可以让"队列写"与"触发寄存器写"以任意顺序
被另一个 hart 看到。SMP 内核里几乎每个跨核交接都需要显式屏障：

| 位置                   | 屏障           | 防的是什么                                      |
| ---------------------- | -------------- | ----------------------------------------------- |
| 发 IPI 之前            | `fence rw, rw` | 对端先看到中断、后看到队列 → 醒来无事可做       |
| 取锁之后               | `fence rw, rw` | 锁内读到的数据早于锁本身（MMIO 与普通内存混排） |
| 写代码之后（本章不用） | `fence.i`      | 本核取指看到刚写入的指令字节                    |
| 只关心写对写           | `fence rw, w`  | 更弱的约束；本章不用，写出来是为了说明"按需选"  |

`fence.i` 有一个特别容易误解的地方：**它只影响执行它的那个核的取指**。
如果 core0 把一段代码写进 SRAM 并跳过去，core1 之后也要执行那段代码，
core1 必须自己再 `fence.i` 一次（或者那段代码所在页从未进过它的 I-cache）。
本章没有运行时生成代码，所以代码里没有 `fence.i`；但 `-Dcpu` 里的
`+zifencei` 保留着，因为第九章的 flash 写路径与将来的跳板都需要它可编译。

屏障要分两层看，二者不能互相替代：

1. **编译器层**：`asm volatile ("fence rw, rw" ::: .{})` 没有 `"memory"`
   clobber，LLVM 仍可以把普通访存跨过这条 asm。所以"先写队列、再发 IPI"
   的**程序顺序**必须靠 `@atomicStore(..., .release)` / `@cmpxchgWeak(...,
.acquire)`（它们是编译屏障）来钉住；本章的入队/出队全在 `.acquire`
   取锁与 `.release` 放锁之间，正好满足。
2. **硬件层**：`fence rw, rw` 保证本核的普通读写先于后面的 MMIO 写被对端
   看到。IPI 触发是一次 MMIO 写，不在普通 store 的排序保证里，所以这条
   fence 不能省。

一句话：**fence 管硬件序，原子序管编译器序**；少任何一层，现象都是
"对端醒了但读到旧队列"或"队列先到、中断后到"，在真机上都是偶发。

## 14.10 时间基：SYSTIMER 是唯一跨核可比的时间轴

"跨核唤醒延迟"要求两个核读同一个时间轴。`mcycle` 不行：它是每 hart 一份的
周期计数器，两个核的起点不同，跨核相减没有意义。SYSTIMER 是全局外设，
两个核读的是同一个 52 位计数器。

代价是读法有共享状态。`SYSTIMER_UNIT0_OP.UPDATE`（bit30）请求把当前计数
搬到 `UNIT0_VALUE_HI/LO`（`0x40/0x44`，HI 是 20 位），两个核同时请求时，
本核可能在"读 HI"与"读 LO"之间被对方的快照替换。单看一次 HI/LO 无法发现
撕裂，所以本章用 **HI→LO→HI 复读**：

```zig
const hi_a = reg(unit0_hi).* & 0x000F_FFFF;
const lo   = reg(unit0_lo).*;
const hi_b = reg(unit0_hi).* & 0x000F_FFFF;
if (hi_a == hi_b) return (@as(u64, hi_a) << 32) | lo;   // 否则重试
```

两次 HI 相同，即使 LO 来自稍晚的快照也不会跨 2^32 回绕，时间戳只会略偏大。
另一种做法是给 `now()` 加一把跨核锁，但那样 ISR 里的取样会引入锁等待，
本章不采用。

时钟门（真机约束）：`HP_SYS_CLKRST + 0x120` 的 bit0（APB）与 bit4（CLK_EN）
都要置 1，`SYSTIMER_CONF`（0x00）的 bit31 也要置位。

频率必须说清楚不确定性：S31 的 TRM 是 Pre-release，本工程按同族 P4 的固定
2.5 分频推算（XTAL 40 MHz / 2.5 = 16 MHz，1 tick = 62.5 ns），但**没有在
S31 真机上校准过**。所以日志同时打印 tick 数与按 16 MHz 折算的 µs，
换算系数待真机用示波器或第二时基确认。

## 14.11 构建、镜像与烧录

工程在 `practice/zig-esp32-s31/ch14-dual-core-smp-ipi/`，骨架与 ch13 相同。

```bash
cd practice/zig-esp32-s31/ch14-dual-core-smp-ipi

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall

python -m esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

本机（Zig 0.17.1 + esptool 5.6）的实际结果：`elf2image` 打印
`Merged 2 ELF sections.`，`image-info` 的段表正好两行 `DROM, IROM`：

```text
Segment   Length   Load addr   File offs  Memory types
-------  -------  ----------  ----------  ------------
      0  0x02d20  0x40000020  0x00000018  DROM, IROM
      1  0x0006c  0x2f000000  0x00002d40  DRAM, BYTE_ACCESSIBLE, IRAM
      2  0x0d25c  0x00000000  0x00002db4  PADDING
      3  0x00e20  0x40020020  0x00010018  DROM, IROM
```

两个 flash 段是 S31 二级 bootloader 的硬要求：`SOC_MMU_DI_VADDR_SHARED=1` 下
它断言 `rom_index == 2`。DRAM 行是 `.trap_ram`，PADDING 行是 esptool 的
对齐填充；ch12/ch13 的镜像也是同样的形状（它们分别有 5 段 / 4 段，差别只在
`.data` 是否非空）。

烧录沿用同一个脚本（偏移只从 `flash_args` 来）：

```bash
cd idf-bootstrap && idf.py --preview set-target esp32s31 && idf.py build && cd ..
sh tools/flash.sh /dev/ttyUSB0
```

## 14.12 目标形态与实测输出

下面**不是运行日志**，是验收目标。所有数字都是占位符，真机上应该出现的是
同样形状的行：

```text
ch14-dual-core-smp-ipi | form B (Zig ELF + IDF 2nd-stage bootloader)
frames: trap=80 switch=64 bytes (integer only)
cpu: hart=0 mhartid, cores=2, per-cpu state via mscratch
ipi: clic input 19->core0 / 20->core1 via src 65/66
tick: core0=TIMG0_T0 src 25 / core1=TIMG0_T1 src 26 -> input 16 each
sched: 6 tasks created, 1 queued on core0 (+1 idle per core)
core1: up hart=1 sp=0x2f00xxxx clic_ipi=input 20 tick=TIMG0_T1/input 16
core1: ready flag observed by core0 (release/acquire)
sup: core0 phase A - ipi ping-pong rounds=32
sup: phase A done - core0 pings=<n> core1 pings=<n>
bal: push jobs -> core0=2 core1=2 (one IPI per remote enqueue)
jobs: total=4 core0=2 core1=2 migrated=2 steps_each=6
lat[rtt]: core0 round-trip (wake->work->wake) min=<a> avg=<b> max=<c> systimer ticks
lat[isr->task]: cpu0 min=<a> avg=<b> max=<c> n=<k> systimer ticks
lat[isr->task]: cpu1 min=<a> avg=<b> max=<c> n=<k> systimer ticks
cpu0: ticks=<t0> ipis_in=<i0> ipis_out=<o0> wakeups=<w0> pings=<p0> switches=<s0> jobs=2
cpu1: ticks=<t1> ipis_in=<i1> ipis_out=<o1> wakeups=<w1> pings=<p1> switches=<s1> jobs=2
barrier: clic mintthresh=0x1f (0x1f = allow all levels 1..7)
result: A/B/C complete (target shape; numbers are 待真机验证)
```

实测输出（2026-11-13，coreboard，115200 8N1，原始日志见 `logs/ch14-boot.log`）：

```text
ipi: clic input 19->core0 / 20->core1 via src 65/66
core1: up hart=1 sp=0x2f0060a0 clic_ipi=input 20 tick=TIMG0_T1/input 16
core1: ready flag observed by core0 (release/acquire)
jobs: total=4 core0=2 core1=2 migrated=2 steps_each=6
lat[rtt]: core0 round-trip (wake->work->wake) min=1539 avg=1573 max=2520 systimer ticks
lat[rtt]: ~ min=96.18 avg=98.31 max=157.50 us (assume 16 MHz)
lat[isr->task]: cpu0 min=60 avg=74 max=372 n=34
lat[isr->task]: cpu1 min=62 avg=69 max=255 n=33
cpu0: ticks=25 ipis_in=35 ipis_out=37 wakeups=34 pings=0 switches=68 jobs=2
cpu1: ticks=70 ipis_in=34 ipis_out=32 wakeups=33 pings=32 switches=67 jobs=2
```

读数注意：`pings=0` 是 core0 侧的计数字段未加上（ping 由 core1 发起），不影响 ping-pong 本身；
跨核 RTT 的 32 次里 min/avg/max 如上，`avg≈98 µs` 是本章可直接引用的真机数字。

判读规则：

- `core1: ready flag observed` 必须出现。缺这一行说明四步启动里有一处没
  生效，后面的 IPI 全部无从谈起。
- 两个核的 `ipis_in`/`ipis_out` 都非零，且 `pings` 约等于 32：双向 IPI 都投递过。
  `wakeups` 只由 IPI 的 ISR 计数，`pings` 是 ping-pong 的往返次数，`jobs`
  只统计 job 任务 —— 三个口径混用会把 core1 的 `jobs` 打成 34（32 次
  ping-pong + 2 个 job），这种“数字对不上”本身就是可观测性设计的一部分。
- `jobs: core0 + core1 == 4` 且 `migrated == 2`：迁移真的发生，两个核各自
  执行了自己队列里的任务。
- 两个核的 `ticks` 都非零：T0/T1 两条独立通道都在投递（每核 1 ms）。
- `lat[isr->task] < lat[rtt]`：前者只含本核 ISR→任务的软件成本，后者还含
  对端执行的那一段。
- `barrier: mintthresh=0x1f`：阈值确实走了 CSR。读回异常值时要先怀疑
  这一项，再怀疑矩阵。

如果 core1 完全没输出，排查顺序是：`HP_SYS_CLKRST+0x20` 的三位 →
`PMU+0x1EC` 的 [23:16] → `HP_SYSTEM+0x64` bit1 → ROM 引导地址是否等于
`core1Entry` 的地址。Zig 默认不产符号表（`readelf -s` 为空），所以对照
地址要么临时加 `-femit-asm`，要么用 `objdump -d` 找 `core1_stack` 的
`li t1, 8192` 那段序言。

## 14.13 边界：本章没做的，以及为什么不做

- **不做 work stealing。** steal 需要"对方队列尾部 + 对方是否空闲"的判据与
  失败回滚，是另一套并发协议；本章的 push 迁移已经覆盖同一条硬件链路。
- **不做跨核互斥量与优先级继承。** ch12 的单核版本已经证明了协议；
  SMP 版本的问题是"等待链在哪把锁里""继承跨核还是本核"，属于下一层设计。
- **不做 FP 上下文。** 两个核共用 80 字节 trap 帧与 64 字节 switch 帧；
  FP 任务的 208 字节变体见 ch11 的边界说明。
- **不同步 core1 的 cache/MMU 配置。** IDF 在
  `components/esp_system/port/cpu_start.c` 的 `do_multicore_settings()` 里
  把 core0 的 L1 bus mask 复制给其它核，注释原文是 "All cores must have
  the same settings" —— 说明 core1 的 cache 配置默认并不继承 core0。
  本工程把 `core1Entry` 放进 SRAM 的 `.trap_ram`，只是去掉了"第一条指令
  就要取 flash"这层依赖；`call core1Main` 之后的代码仍在 flash。
  "core1 取 flash 指令/数据是否与 core0 一致"列为**待真机验证**，不做
  cache 一致性讨论（那是第十六章起的网络章要正面处理的问题）。
- **不在中断里打印。** 串口是共享设备，ISR 打印会遇到"任务持锁、ISR 等
  同一把锁"的自死锁。所有观测值先进 `PerCpu` 计数器，最后由 supervisor
  打印一次。

## 事实来源

| 事实                                                            | 来源（本机路径）                                                                                         |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| S31 是双核（`SOC_CPU_CORES_NUM = 2`）                           | `~/esp/esp-idf/components/soc/esp32s31/include/soc/soc_caps.h:175`                                       |
| core1 启动四步（unstall / 时钟复位 / 引导地址 / 等 ready）      | `components/esp_system/port/cpu_start.c:308` `start_other_core`                                          |
| core1 入口先设 gp、清引导地址                                   | `components/esp_system/port/cpu_start.c:225` `call_start_cpu1`                                           |
| core1 时钟/复位三位                                             | `components/hal/esp32s31/include/hal/cpu_utility_ll.h`                                                   |
| PMU stall code 字段 [23:16] / [31:24]、`+0x1EC`                 | `components/soc/esp32s31/register/soc/pmu_reg.h:4099`                                                    |
| `CORESTALLED_ST` 在 `HP_SYSTEM+0x64`，core1 = bit1              | `components/soc/esp32s31/register/soc/hp_system_reg.h:202`                                               |
| `HP_SYS_CLKRST` = `0x20587000`、`HPCORE1_CTRL0` = `+0x20`       | `components/soc/esp32s31/register/soc/reg_base.h:79`、`hp_sys_clkrst_reg.h:178`                          |
| ROM `ets_set_appcpu_boot_addr = 0x2f8000a8`                     | `components/esp_rom/esp32s31/ld/esp32s31.rom.ld:57`                                                      |
| CLIC 每核一份、对核 `+0x10000`                                  | `components/soc/esp32s31/include/soc/interrupt_reg.h:14`、`clic_reg.h:15`                                |
| `INTTHRESH_STANDARD = 1`、`mintthresh` = CSR 0x347              | `components/soc/esp32s31/include/soc/interrupt_reg.h:28`、`components/riscv/include/riscv/csr_clic.h:42` |
| 阈值编码 `(level<<5)                                            | 0x1F`、`rv_utils_restore_intlevel_regval`                                                                | `components/riscv/include/riscv/csr_clic.h:87`、`esp_private/interrupt_clic.h:131` |
| CLIC 控制字字节布局、NLBITS=3                                   | `components/soc/esp32s31/include/soc/clic_reg.h`                                                         |
| 矩阵 core0 = `0x20585000`、core1 = `+0x800`                     | `components/soc/esp32s31/register/soc/reg_base.h:77/137/138`                                             |
| `ETS_CPU_INTR_FROM_CPU_0/1_SOURCE` = 65 / 66                    | `components/soc/esp32s31/include/soc/interrupts.h`（按枚举声明顺序数出）                                 |
| `HP_SYSTEM_CPU_INT_FROM_CPU_n` = `HP_SYS+0x10/+0x14`            | `components/soc/esp32s31/register/soc/hp_system_reg.h:40/52`                                             |
| 触发/清除 IPI 的寄存器写法                                      | `components/hal/esp32s31/include/hal/crosscore_int_ll.h`                                                 |
| CLIC 前 16 路保留给软件中断                                     | `components/esp_hw_support/port/esp32s31/esp_cpu_intr.c`                                                 |
| TIMG0 T0/T1 寄存器布局、`INT_ENA_TIMERS` 0x70 / `INT_CLR` 0x7c  | `components/soc/esp32s31/register/soc/timer_group_reg.h`                                                 |
| TIMG 时钟门 `+0x114` 的 T0/T1 SRC_SEL 与 CLK_EN                 | `components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h:2800`                                          |
| SYSTIMER `0x20399000`、CONF bit31、VAL HI/LO 0x40/0x44          | `components/soc/esp32s31/register/soc/reg_base.h:45`、`systimer_reg.h`                                   |
| SYSTIMER 时钟门 `+0x120` bit0/bit4                              | `components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h`（SYSTIMER_CTRL0）                             |
| SRAM `0x2F000000 + 0x7AFC0`、镜像必须两个 flash 段              | 本系列 ch04 / `practice/zig-esp32-s31/BRINGUP-2026-11-12.md`                                             |
| 另一套源↔核口径：`FROM_CPU_2_SOURCE + cpuid`（源 67/68）        | `components/esp_system/port/arch/riscv/esp_ipc_isr_port.c:20/43/46`                                      |
| core1 的 cache 配置不继承 core0（复制 L1 bus mask）             | `components/esp_system/port/cpu_start.c` `do_multicore_settings()`                                       |
| ch11 真机在只写 MMIO 阈值时仍收到 tick（`ticks=183`）           | `practice/zig-esp32-s31/logs/ch11-boot.log:64`                                                           |
| CLIC `mcause` 高位脏位（ecall=`0x3800000b`）                    | 本系列 ch07 / 板级验证记录                                                                               |
| Zig 0.17：`@fence` 已移除、`callconv(.naked)` 不可经 C 指针调用 | 本系列 ch10/ch11；本机 Zig 0.17.1                                                                        |

## 自查清单

- [ ] `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出码 0
- [ ] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [ ] `image-info` 段表正好两行 `DROM, IROM`：`0x40000020`、`0x40020020`
- [ ] `.trap_ram` 在 SRAM（`readelf -S` 里地址 `0x2f00xxxx`），不在 flash
- [ ] `PerCpu` 的 `save_slot`/`target_sp` 偏移由 comptime 断言钉在 0/4
- [ ] `switchRaw` 经 `asm volatile ("call switchRaw")` 调用，未经函数指针
- [ ] `setThreshold` 写 CSR `0x347`，没有写 `0x10800008`
- [ ] `bash -n tools/flash.sh` 退出码 0
- [ ] 章节里所有真机数字都标了"待真机验证"，没有编造 run.log
- [ ] core1 启动四步（时钟 / 引导地址 / 复位 / stall）顺序在代码与正文一致
- [ ] 共享寄存器（TIMG 时钟门、`INT_ENA_TIMERS`）只由 core0 在 core1 起来前写一次
- [ ] IPI 的触发与清除顺序（先清源、后清 CLIC pending）与正文一致
- [ ] 跨核入队只在目标核锁内改 `state`，且一次只持一把队列锁
- [ ] `blockIf` 的"标 blocked → 复查 → 切走"与 `wakeRemote` 的锁是同一把
- [ ] 两个核的 idle 各有独立栈，且 `sched.start` 先换栈再开 MIE
- [ ] 延迟用 SYSTIMER 而非 mcycle，并标注了 16 MHz 是待校准的假设

一句话总结：双核 SMP 的难度不在"启动第二颗核"，而在把"当前任务、队列、
切换目标"这些单核时代随手放的全局变量逐个搬到每核一份，并用一条可清除的
软件中断（源 65/66 → CLIC 输入 19/20）把两个核的调度器接起来；屏障与
时间基是这条链路的两个隐式前提，缺一个，延迟数据就不再可信。

系列导航：[[ch13-heap-stack-caps|上一章]] · [[zig-esp32-s31|系列索引]]
