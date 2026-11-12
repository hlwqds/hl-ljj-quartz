---
title: "Zig × ESP32-S31 全栈开发（十五）：可观测性、测试与稳定性"
date: 2026-11-28 18:00:00
description: "把“不知道发生了什么”变成可判读的输出：主机侧 zig build test、六组启动自检（链接符号/内存区间/时钟/中断/RTC WDT/trace 环）、可恢复断言与 panic dump 的两条路径、基于 TIMG0 的 24 字节时间戳 trace 环、三层 watchdog，以及一个确定性 30 s 压测的判读口径。"
tags: [zig, esp32-s31, riscv, observability, testing, panics, watchdog, series]
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
> 14. [[ch14-dual-core-smp-ipi|第十四章：双核 SMP 与 IPI]]
> 15. **第十五章：可观测性、测试与稳定性**
> 16. 第十六章：协议栈架构、缓冲与零拷贝（待发布）

# Zig × ESP32-S31 全栈开发（十五）：可观测性、测试与稳定性

前十四章每加一个子系统，就多一个“出问题时不知道从哪查”的角落：链接脚本改了但没生效、时钟分频算错了但程序照样跑、`mtvec` 装到了 flash、RTC WDT 还在后台数秒。这些错误有一个共同点——**它们不会立刻报错，而是让后面所有实验的结论一起变脏**。

本章把“观测”当成一条工程约束来做：启动时用六组自检验证所有隐含假设；运行时用 32 条时间戳 trace 记录最近发生了什么；崩溃时把 trap 现场与 trace 尾部一起打出来；主机侧用 `zig build test` 把纯逻辑先钉死。骨架仍是形态 B，但**本章没有调度器、没有任务切换、没有中断**，`MIE` 恒为 0——这样才能把“观测链”单独讲清楚。

> [!warning] 本章的证据边界
> 本工程**已上板一次（2026-11-13，修复前版本）**。首轮真机结果：
>
> - `check: clock ... measured=1003us ratio=100%`：TIMG0 的 1 MHz 时间基成立；
> - `mtvec` 写入 `0x2f000000`、读回 `0x2f000003`：S31 把 MODE 固定为 3（CLIC 模式），只能比较 BASE；
> - `RTC_WDT CONFIG0=0x8007ee00`：EN=1、STG0..3=0、flashboot=0；这是**旧序列没关掉**的状态（SWD_WPROTECT 未解锁），不是硬件自恢复；
> - `sram stack ok=0` 把三条判据折叠成一个 bit，无法定位；现已拆成独立行 + 6 位 bitmask。
>
> 三个判据已修，**次轮已复跑**：`checks: passed=8 failed=0`（2026-11-13）。文中未标“实测”的行是目标形态，标注“首轮实测/次轮实测”的行才是真机日志。trap 放 flash 会 `CPU_LOCKUP_RESET`、非法指令 `mcause=0x30000002` 等前置事实来自 `BRINGUP-2026-11-12.md` 的历史记录。

---

## 15.1 可观测性不是“多打几行 printf”

先把问题分类。嵌入式项目里“不知道发生了什么”通常不是一种，而是三种：

| 问题               | 典型症状                                   | 本章的答案                            |
| ------------------ | ------------------------------------------ | ------------------------------------- |
| 启动假设错了       | 程序能跑，但某段行为就是不对，改代码也没用 | 六组启动自检，硬判据失败即 panic      |
| 崩溃现场丢了       | 串口停在半行，复位后无法复现               | `trapEntry` + panic dump + trace 尾部 |
| “在跑”但不“有进展” | 心跳还在，业务计数不动                     | 软件 watchdog 绑定业务周期            |

三种问题对应三条证据线，它们的可信度从高到低：

1. **主机侧单测**：确定性最高，可重复，但只能覆盖纯逻辑（环、截止时间）；
2. **启动自检**：直接读寄存器和链接符号，验证“环境与假设一致”；
3. **运行时 trace**：信息最丰富，但容量有限、只能回答“最近发生了什么”。

一个常见的错误是用第 3 条冒充第 1 条：写一堆日志，然后靠肉眼在 10 万行里找异常。日志是**观测的载体**，不是观测本身；真正让日志有价值的是“每条日志对应哪个判据、失败时程序做什么”。

本章的判据全部落成一行可 grep 的前缀：

```text
check: ...     启动自检的每一组
checks: ...    自检汇总（passed/failed/total）
assert: ...    可恢复断言
wdt: ...       软件 watchdog
stress: ...    压测
panic: ...     不可恢复路径与 dump
```

前缀不是装饰：它让“用串口抓一段文本、grep 一个前缀、得到一条结论”成为固定流程，而不是每次重新想“这行输出说明什么”。

---

## 15.2 主机侧单测：先在没有硬件的地方把逻辑钉死

`zig build test` 在本工程里只做一件事：在 x86_64 上编译并运行 `src/host_tests.zig`。

```zig
// src/host_tests.zig
test {
    _ = @import("trace.zig");
    _ = @import("watchdog.zig");
}
```

根文件只 import 两个**纯逻辑**模块，它们不引用 `hw.zig`、`trap.zig`、`main.zig`，因此不需要交叉工具链，也不会因为链接脚本或 ROM 符号而失败。`build.zig` 用宿主目标单独建一个测试模块：

```zig
const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/host_tests.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }),
});
const run_tests = b.addRunArtifact(tests);
const test_step = b.step("test", "host-side unit tests (trace ring + soft watchdog)");
test_step.dependOn(&run_tests.step);
```

### 被测试的九个具名用例

`zig build test` 的输出是 `All 10 tests passed`：九个具名用例，加上 `host_tests.zig`
里那个把两个模块拉进来的容器 `test` 块（Zig 把空 test 块也算一个测试）。

| 模块     | 用例         | 钉死的语义                                            |
| -------- | ------------ | ----------------------------------------------------- |
| trace    | 空环         | `latest()`/`at(0)` 返回 null，`spanUs()==0`           |
| trace    | 未满时顺序   | `at(i)` 按时间顺序，`dropped==0`                      |
| trace    | 溢出         | 覆盖最旧、`dropped` 精确等于超出量、`at(0)` 是第 8 条 |
| trace    | 尺寸与格式化 | `@sizeOf(Record)==24`，格式化文本逐字匹配             |
| trace    | reset        | 计数归零、`latest()` 回到 null                        |
| watchdog | 未到期/边界  | 恰好等于 deadline **不**算超时                        |
| watchdog | 超过 1 µs    | 到期，`elapsed` 精确                                  |
| watchdog | 喂狗与恢复   | `checkAndRecover` 只计一次 trips 并重置窗口           |
| watchdog | 时钟回退     | 饱和减法使 `elapsed==0`，不误报                       |

主机侧测试**不测**三样东西，而且不能假装测了：

- 链接符号与寄存器（只有真机有）；
- 时间基的频率（`ets_delay_us` 是 ROM 的，主机上没有）；
- trap 路径（非法指令在 x86 上语义不同）。

这条边界必须写进 README，否则“测试全绿”会变成一句没有信息量的话。

### 为什么这两个模块必须是纯的

`trace.zig` 只做 `[32]Record` 的下标运算，`watchdog.zig` 只做 `u64` 减法与比较。没有 `@import("hw.zig")`，没有 `asm`，没有全局寄存器。这样带来两个好处：

1. 主机测试与真机执行的是**同一份**代码，不是“主机版实现”；
2. 任何硬件相关的问题都被挤到 `check.zig` / `hw.zig` 一侧，归因更短。

---

## 15.3 启动自检：把六个隐含假设变成八条硬判据

本章的 `check.zig` 在 `main` 的第一件事就运行。它不修改任何硬件状态，只读链接符号与寄存器，因此可以安全地重复执行。

### 15.3.1 链接符号与 flash 区间

链接脚本导出了全部边界符号：

```ld
_image_start = .;   KEEP(*(.app_desc))       /* 第一个 flash 段开头 */
_text_start  = .;   KEEP(*(.text.trap)) ...
_rodata_start = .;  ...                      /* 第二个 flash 段 */
_trap_start   = .;  KEEP(*(.trap_ram)) ...
_data_start   = .;  ...
_bss_start    = .;  ...  _bss_end = .;
_heap_start = _bss_end;  _heap_end = _stack_bottom;
_stack_bottom = _stack_top - 0x4000;
```

自检把它们的值与 ESP-IDF v6.1 的 esp32s31 内存定义对照：

| 区间          | 期望值             | 来源                                        |
| ------------- | ------------------ | ------------------------------------------- |
| IROM 段起点   | `0x40000020`       | bootloader `rom_index == 2` 约束（BRINGUP） |
| DROM 段起点   | `0x40020020`       | 同上                                        |
| SRAM 起点     | `0x2F000000`       | `memory.ld.in:19`                           |
| SRAM 可用长度 | `0x7AFC0`          | `SRAM_SEG_END(0x2F07AFC0) - SRAM_START`     |
| 栈大小        | `0x4000`（16 KiB） | 本章链接脚本                                |

`syms` 组的判据是：

```zig
const ok = image == irom_org and
    text_start > image and
    text_end > text_start and
    inRange(text_start, irom_org, irom_len) and
    text_end <= irom_org + irom_len and
    rodata_start >= drom_org and
    rodata_end > rodata_start and
    rodata_end <= drom_org + drom_len;
```

`rodata_start` 用 `>=` 而不是 `==`：链接器可能因为对齐在 `.app_desc` 之后插入填充，但 DROM 段的起点不能低于 `0x40020020`。这种“允许对齐填充、不允许越界”的写法，比逐个地址硬比较更耐改。

### 15.3.2 SRAM 的三条边界

`sram` 组拆成三条判据（trap、data/bss、堆栈边界），因为它们失败的含义完全不同：

| 判据     | 内容                                                                                                           | 失败意味着                                     |
| -------- | -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| trap     | `_trap_start % 4 == 0` 且在 SRAM 内，`_trap_end > _trap_start`                                                 | `mtvec` 模式位会吃掉地址低位，或入口跑到 flash |
| data/bss | `_data_end <= _bss_start <= _bss_end` 且在 SRAM 内                                                             | 段顺序被改，或 `.bss` 越出 SRAM                |
| bounds   | `_heap_start == _bss_end`、`_heap_end == _stack_bottom`、`_stack_top == SRAM 末尾`、栈大小 16 KiB、16 字节对齐 | 静态对象吃进栈区，或边界符号被改错             |

本镜像的 `.data` 是空的（所有可变全局都是零初始化，落在 `.bss`），所以
`_data_start == _data_end` 是**健康**形态。判据必须写成 `_data_end >= _data_start`：
只有“`.data` 与 `.bss` 重叠”才非法。写成 `>` 会让自检在第一次启动时拒绝一个
完全健康的镜像——这种“检查器自己有 bug”的故障，比它想防的问题更难查。

链接脚本里同时有四条 `ASSERT`，能在链接期挡住明显错误：

```ld
ASSERT(_image_start == ORIGIN(irom), "first flash segment must start at ORIGIN(irom) = 0x40000020")
ASSERT(_trap_start >= ORIGIN(sram) && _trap_end <= ORIGIN(sram) + LENGTH(sram), ".trap_ram must live inside SRAM")
ASSERT(_bss_end <= _stack_bottom, "SRAM exhausted: .bss overlaps the 16 KiB main stack")
ASSERT(_stack_top == ORIGIN(sram) + LENGTH(sram), "_stack_top must be the exclusive end of SRAM")
```

链接期断言与运行期自检不是重复：前者挡“布局写错”，后者挡“布局没变但环境变了”（例如换了 bootloader 版本、SRAM 上限被占）。

### 15.3.3 时钟：寄存器状态 + 1 ms 校准

TIMG0 的 T0 被配置成 1 MHz：

```zig
var ctrl = readReg(timergrp0_ctrl0);      // HP_SYS_CLKRST + 0x114
ctrl |= ctrl_apb_clk_en | ctrl_t0_clk_en; // bit0 = APB，bit5 = T0
ctrl &= ~ctrl_t0_src_sel_mask;            // [4:3] = 0 → XTAL 40 MHz
writeReg(timergrp0_ctrl0, ctrl);

writeReg(t0config, cfg_divider_40 | cfg_increase | cfg_en);
// DIVIDER[28:13] = 40，INCREASE bit30，EN bit31
```

自检把它拆成两层：**寄存器门控是硬判据，1 ms 校准是 advisory**。

```zig
const gate = apb_en and t0_clk_en and src == 0;   // 自己写的门控，必须为真

const t0 = hw.nowUs();
hw.delayUs(1000);
const t1 = hw.nowUs();
const measured = t1 -| t0;
const calibrated = measured >= 800 and measured <= 1200; // 只报告，不 gate
```

为什么校准不能当硬判据：它的参考值 `ets_delay_us` 是 ROM 的忙等，精度取决于
bootloader 留下的 `ticks_per_us` 是否与当前 CPU 频率一致；而“分频 40 = 1 MHz”
要靠实测确认（首轮：1003 µs）。若把它升级成 gate，首次上板一旦校准偏差，就会在心跳/断言/
panic 演示之前 panic——观测器挡住了它要观测的东西。校准仍然打印 `measured` 与
`ratio`，作为第一手证据；±20% 只够发现“数量级错误”，晶振精度要用示波器。

### 15.3.4 中断：`mtvec` 的 BASE 与关闭状态

本章不开中断，但必须证明“确实关着、向量确实指向 SRAM 里的入口”：

```zig
const mtvec = hw.readMtvec();
const base = mtvec & ~@as(usize, 3);
const trap_addr = @intFromPtr(&trap.trapEntry);
const ok = base == trap_addr and
    inRange(base, sram_org, sram_len) and
    (mstatus & 0x8) == 0 and
    mie == 0;
```

首轮真机（2026-11-13）：写入的是 `0x2f000000`，读回 **`0x2f000003`**。
S31 把 `mtvec.MODE` 固定为 3（CLIC 模式；`BRINGUP-2026-11-12.md` 的 ch07
记录过同一现象），所以判据只能比较 BASE（`mtvec & ~3`），不能要求 MODE=0；
MODE 只作为信息打印。三条判据：

1. `base != trapEntry`：向量没装，或者装完被别的代码覆盖；
2. `base` 不在 SRAM：trap 入口跑到 flash，异常投递直接 `CPU_LOCKUP_RESET(0x1a)`；
3. `mstatus.MIE != 0` 或 `mie != 0`：有中断源被意外打开。本章没有 ISR，任何中断都是意外。

同时打印 CLIC 阈值与 tick 输入（16）的原始 CTL 值。本章不配置它，原始值就是证据：如果它不是复位默认值，说明前面的某段代码动过 CLIC。

### 15.3.5 RTC WDT：stage 全 0 才算 disarm

`_start` 按 IDF `wdt_hal_deinit(WDT_RWDT)` 的顺序关狗（寄存器来源 `rtc_wdt_reg.h`）：

```asm
li t0, 0x20801018          # WPROTECT
li t1, 0x50D83AA1          # 写保护键
sw t1, 0(t0)
li t0, 0x20801020          # SWD_WPROTECT，同一把键
sw t1, 0(t0)
fence rw, rw               # 先让解锁可见
li t0, 0x20801014          # FEED
li t1, 0x80000000
sw t1, 0(t0)
li t0, 0x20801000          # CONFIG0
lw t1, 0(t0)
li t2, 0xFFF81000          # 清 EN(31)、STG0..3(30:19)、FLASHBOOT(12)
and t1, t1, t2
sw t1, 0(t0)
fence rw, rw
li t0, 0x20801018
sw zero, 0(t0)             # 恢复写保护
li t0, 0x20801020
sw zero, 0(t0)
```

真机首轮读回 `CONFIG0 = 0x8007ee00`：EN(31)=1、STG0..3=0、flashboot(12)=0。
`BRINGUP-2026-11-12.md:31` 的 ch05 记录（通过）同样是 `rwdt en=1 stg=0`——
**EN 位对软件是可写的**（次轮实测 `before=0xc0000000`→`after=0x0`，EN 与 stage 一起清掉）；真正决定会不会复位的是
四个 stage 选择位\*\*。所以自检的功能判据是：

```zig
const ok = (cfg & hw.rtc_wdt_stage_mask) == 0 and
    (cfg & hw.rtc_wdt_flashboot) == 0 and
    wprotect == 0;
```

`en=` 仍然打印，但只作信息：EN=1 而 stage 全 0 的看门狗没有任何动作可做。
`main` 还会再执行一次同样的 disarm 并打印 before/after，把“关狗确实执行过”
变成一行可核对的证据。真正要防的是**已武装的 stage**——不做，约 9 秒后
复位成 `CHIP_LP_WDT_RESET (rst:0x10)`。

### 15.3.6 trace 环自检

最后一组用一个**局部** `Ring` 跑一次完整生命周期：

```zig
var probe: trace.Ring = .{};
const total: u32 = trace.capacity + 3;
var i: u32 = 0;
while (i < total) : (i += 1) {
    probe.push(.{ .t_us = i * 10, .tag = .check_ok, .a = i, .b = 0 });
}
const ok = probe.count() == trace.capacity and
    probe.dropped == 3 and
    probe.at(0).?.a == 3 and
    probe.latest().?.a == total - 1;
```

它在真机上验证的是“同一份代码在目标 ABI 下的行为”，而不是硬件。主机侧测试已经覆盖同样的语义；真机再跑一次，是为了排除 `@sizeOf`/对齐在 riscv32 上与预期不同的可能。

---

## 15.4 断言的两条路径：可恢复与不可恢复

Zig 的 `std.debug.assert` 在 `ReleaseSmall` 下退化成 `unreachable`，不会打印任何东西，也不会给你选择“继续还是停”。本章因此不用它，而是把断言拆成两个显式 API：

| API                       | 失败时                                                             | 适用场合                                   |
| ------------------------- | ------------------------------------------------------------------ | ------------------------------------------ |
| `check.expect(cond, tag)` | 打印 `assert: caught ... action=recover`，记一条 trace，返回 false | 调用方能安全降级（跳过实验、用保守默认值） |
| `trap.panic(fmt, args)`   | 打印原因 + `mcause/mepc/mtval` + trace 尾部，`wfi` 停机            | 继续执行会产生错误结论或破坏状态           |

```zig
pub fn expect(cond: bool, comptime tag: []const u8) bool {
    if (cond) {
        log.line("assert: ok tag={s}", .{tag});
        return true;
    }
    log.line("assert: caught tag={s} action=recover", .{tag});
    trace.g_ring.push(.{
        .t_us = hw.nowUs(),
        .tag = .assert_caught,
        .a = 0,
        .b = 0,
    });
    return false;
}
```

关键点不是“多了一个返回 bool 的函数”，而是**失败是可见的**：它进了串口，也进了 trace 环。一个返回 false 但什么都不打印的断言，在压测里和没有断言一样。

`main` 里故意触发一次可恢复断言：

```zig
_ = check.expect(trace.capacity == 32, "trace capacity is 32");
const caught = check.expect(false, "demo: injected invariant failure");
log.line("assert: demo caught={d} (recoverable path exercised)", .{@intFromBool(caught)});
```

第二条是本章唯一“故意失败”的断言。它的作用与 ch13 的 `simulateOverflow()` 相同：证明检测路径真的会走，而不是一个永远返回 ok 的摆设。

---

## 15.5 panic dump：把现场与“最近发生了什么”一起打出来

### 15.5.1 80 字节 trap 帧

`trapEntry` 是 naked 函数，自己压 80 字节：

```text
sp+0   ra
sp+4   t0 t1 t2 t3 t4 t5 t6
sp+32  a0 a1 a2 a3 a4 a5 a6 a7
sp+64  mepc
sp+68  mstatus
sp+72  pad[2]
```

只保存 caller-saved 与两个 CSR：callee-saved（`s0`–`s11`）由 C 调用约定保证，`trapDispatch` 及其下游会自己保存。`TrapFrame` 是 `extern struct`，并用 comptime 断言锁死偏移：

```zig
comptime {
    if (@sizeOf(TrapFrame) != 80) @compileError("TrapFrame 必须是 80 字节");
    if (@offsetOf(TrapFrame, "mepc") != 64) @compileError("mepc 必须在偏移 64");
    if (@offsetOf(TrapFrame, "mstatus") != 68) @compileError("mstatus 必须在偏移 68");
}
```

### 15.5.2 `mcause` 只能取低位

S31 的 `mcause` 高位带 CLIC 附加字段。ch12 的板级记录（2026-11-12）给出
`ecall = 0x3800000b`；`BRINGUP-2026-11-12.md:56` 单独记录非法指令
`mcause = 0x30000002`，并按 `raw & 0x1F` 查表。两种掩码对这两个值结果一致
（`0x0b` 与 `0x02`），本章统一用 `& 0x3F`（与 ch12 的 `trapDispatch` 一致）；
中断侧低 6 位则是 CLIC 输入号。所以判断异常码必须先掩码：

```zig
const cause = hw.readMcause();
if ((cause & 0x8000_0000) != 0) {
    const input: usize = cause & 0x3F;     // 中断：低 6 位是 CLIC 输入号
    ...
} else {
    const code: usize = cause & 0x3F;      // 同步异常：高位是脏字段
    ...
}
```

直接写 `if (cause == 11)` 会漏掉 ecall，写 `if (cause == 2)` 会漏掉非法指令——这两个坑在 ch07 都已经踩过，本章用同一条口径。

### 15.5.3 故意崩一次：`trip()`

```zig
pub fn trip() noreturn {
    log.raw("panic: injecting illegal instruction 0x00000000\n");
    trace.g_ring.push(.{ .t_us = hw.nowUs(), .tag = .panic, .a = 2, .b = 0 });
    asm volatile (".word 0x00000000" ::: .{});
    log.raw("panic: illegal instruction did not trap\n");
    hw.halt();
}
```

`0x0000` 在 RISC-V 里定义为非法指令，会以 `cause=2` 进入 `trapEntry`。最后两行是防御：如果工具链把 `.word` 解释成了别的东西、或者异常没有发生，串口会明确说“没有 trap”，而不是静默跑飞。

这条路径必须由**链接脚本 + `mtvec` + `.trap_ram`** 三者同时正确才成立，因此它本身就是一次端到端自检。

### 15.5.4 dump 的结构

`trapDispatch` 打印的顺序是固定的：

```text
panic: exception code=2 (illegal instruction) cause=0x30000002
panic: mepc=0x... mtval=0x... mstatus=0x...
panic: ra=0x... a0=0x... a1=0x... a2=0x...
trace: t=...us tag=hb a=0x7 b=2000
trace: t=...us tag=assert a=0x0 b=0
trace: t=...us tag=panic a=0x2 b=0
dump: trace shown=3/3 pushed=3 dropped=0
panic: halted (wfi)
```

为什么要把 trace 放在寄存器之后：寄存器回答“最后一条指令是什么”，trace 回答“最后几个业务事件是什么”。前者定位故障指令，后者定位故障**阶段**。两者缺一不可。

`mepc` 指向出错指令的地址。对非法指令来说，它就是 `.word 0` 所在的位置；对访问故障来说，它是发起访问的指令。`mtval` 在非法指令时通常为 0，在访问故障时是出错地址——这两个值的组合能快速区分“代码跑飞”和“指针被写坏”。

---

## 15.6 时间戳与 trace 环

### 15.6.1 为什么不用 tick 计数

用“第几次 tick”当时间戳有三个问题：

1. 精度被 tick 周期锁死（1 ms tick 无法分辨 200 µs 的间隔）；
2. tick 是中断，需要一个能安全运行的 ISR，而本章想保持 `MIE=0`；
3. tick 会丢：中断被屏蔽、ISR 迟到，计数就少了，而时间戳没有“少一次”的概念。

TIMG0 的 T0 是一个 64 位自由计数器（HI 22 位 + LO 32 位），1 MHz 下约 4.4 千年回绕一次。读它是同步操作：

```zig
pub fn nowUs() u64 {
    writeReg(t0update, cfg_update);       // 请求快照（bit31，自清零）
    var guard: u32 = 0;
    while ((readReg(t0update) & cfg_update) != 0 and guard < 10_000) : (guard += 1) {}

    const hi: u64 = readReg(t0hi) & 0x003F_FFFF;
    const lo: u64 = readReg(t0lo);
    return (hi << 32) | lo;
}
```

`UPDATE` 的作用是把计数器原子地锁进 LO/HI 两个寄存器，避免“读 LO 之后、读 HI 之前刚好进位”的撕裂。等待有上限（10 000 次），避免寄存器行为异常时把自检本身卡死。

### 15.6.2 环的取舍：覆盖最旧，而不是拒绝写入

```zig
pub fn push(self: *Ring, rec: Record) void {
    const idx: u32 = @intCast(self.pushed & (capacity - 1));
    if (self.pushed >= capacity) self.dropped += 1;
    self.recs[idx] = rec;
    self.pushed += 1;
}
```

崩溃现场最有价值的是**最近**的记录，所以满了就覆盖最旧。`pushed` 是历史累计次数（不是当前条数），`dropped` 精确记录被覆盖的数量。容量 32 是 2 的幂，索引用位掩码，编译器能消掉除法。

按时间顺序取第 i 条时，需要把“相对序号”换算成“绝对序号”：

```zig
const first = self.pushed - self.count();     // 最旧一条的绝对序号
const idx: u32 = @intCast((first + i) & (capacity - 1));
```

这个换算是主机侧测试的重点：溢出后 `at(0)` 必须等于第 `total - capacity` 条，而不是 0。

### 15.6.3 一条记录为什么是 24 字节

```zig
pub const Record = extern struct {
    t_us: u64,   // 8
    tag: Tag,    // 1 (enum(u8))
    a: u32,      // 4
    b: u32,      // 4
};
```

按 RISC-V ILP32 的 psABI，`u64` 需要 8 字节对齐，所以 `tag` 后面有 3 字节填充，整个结构是 `8 + 1 + 3 + 4 + 4 = 20`，再按 8 对齐取整到 **24**。硬塞成 16 字节只有两条路：把时间戳降成 `u32`（71 分钟回绕），或去掉一个载荷。本章选择诚实的 24 字节，并用 comptime 断言锁住：

```zig
if (@sizeOf(Record) != 24) @compileError("Record 必须是 24 字节");
```

32 条记录占 768 字节 `.bss`，对 SRAM 来说可以忽略。

### 15.6.4 并发边界

`Ring` 不是线程安全的。本章是单线程（`MIE=0`、无调度器），所以不需要保护。如果要在中断或多核里 push，调用方必须在临界区里完成 `push`；`pushed` 是唯一需要原子性的量，但索引写与记录写也必须一起被保护，否则读者可能看到“新下标 + 旧记录”。这条边界写在 `trace.zig` 的文件注释里，而不是靠读者猜。

---

## 15.7 watchdog：三层不是一个东西

| 层               | 看什么               | 恢复动作               | 本章                                         |
| ---------------- | -------------------- | ---------------------- | -------------------------------------------- |
| RTC WDT / LP WDT | stage 是否武装       | 芯片复位（`rst:0x10`） | `_start` + `main` disarm，自检核 `stages==0` |
| MWDT（TIMG）     | 有没有喂某个定时器组 | 中断或复位             | 不使用                                       |
| 软件 watchdog    | 业务周期有没有推进   | 打印 + 计数（演示）    | `watchdog.zig`                               |

### 15.7.1 为什么 RTC WDT 必须关

二级 bootloader 交接时 RTC WDT 仍在跑。裸机应用不喂狗，约 9 秒后复位成 `CHIP_LP_WDT_RESET`。这个现象最迷惑人的地方是：**它会伪装成“程序跑飞了”**——串口停住、板子重启，看起来像代码 bug。ch05 已经把寄存器序列讲清楚，本章只是把它变成自检项。

### 15.7.2 软件 watchdog 的语义

```zig
pub fn elapsed(self: *const Watchdog, now_us: u64) u64 {
    return now_us -| self.last_feed_us;   // 饱和减法
}

pub fn expired(self: *const Watchdog, now_us: u64) bool {
    if (self.elapsed(now_us) > self.deadline_us) {
        return true;
    }
    return false;
}
```

三个边界值得强调：

1. **恰好等于 deadline 不算超时**。这样 `deadline=100 ms` 的语义是“间隔最多 100 ms”，而不是“99.999 ms 就开始报”；
2. **用饱和减法 `-|`**：时钟回退或时间戳乱序时 `elapsed` 变成 0，不会误报“永远超时”；
3. **`checkAndRecover` 返回是否发生过超时**，并把 `trips` 加一。生产代码应把这个 true 分支升级为 `trap.panic` 或受控重启；本章演示只打印，因为演示流程要继续走到 panic 路径。

### 15.7.3 喂狗必须绑定业务进度

“喂狗”这个动作最容易被放进错误的位置：主循环每转一圈喂一次，看起来永远健康，但业务可能已经卡在某个子步骤里。正确的绑定是**一个完整的观测周期结束**（本章是每 250 ms 心跳 + 自检汇总），而不是“任意一行代码执行过”。

本章的演示把截止时间设成 100 ms，先喂一次、等 30 ms（未到期）、再等 90 ms（到期并恢复），用两次读数把边界走一遍：

```text
wdt: deadline=100ms early_expired=0 recovered=1 trips=1
```

---

## 15.8 压测：30 秒里到底看什么

`-Dstress=true` 时，程序在 watchdog 演示之后跑 30 秒。压测不是“让 CPU 忙起来”，而是给观测链加压，看四个判据：

| 判据         | 观测点                                   | 失败意味着                    |
| ------------ | ---------------------------------------- | ----------------------------- |
| 时间基稳定   | 每秒一条 `stress: t=...ms`，绝对时刻不漂 | 分频/时钟源有问题             |
| trace 仍工作 | `dropped` 单调增长，不卡住               | 环的下标或计数有 bug          |
| 无长卡顿     | `chunk_gap` 最大值 ≤ 2 ms                | 某段代码偶发长时间关中断/忙等 |
| 结果可复现   | 相同的 `sum=0x...`                       | 有未初始化状态或异步干扰      |

### 15.8.1 绝对时刻报告，而不是“上次 + 1 秒”

```zig
var next_report = t_start + report_period_us;
...
if (chunk_end >= next_report) {
    while (next_report <= chunk_end) next_report += report_period_us;
    ...
}
```

如果写成 `next_report = chunk_end + 1s`，每次迟到的量会累积成漂移；绝对时刻只会在落后时补报，不会把误差积分下去。

### 15.8.2 确定性 LCG

```zig
checksum = checksum *% 1664525 +% 1013904223;
checksum ^= checksum >> 13;
checksum *%= 2654435761;
```

全部是 `*%`/`+%`（环绕算术），没有随机源、没有未初始化内存。连续复位 10 次，`sum` 必须逐位一致；不一致就说明有异步状态混进来了——这比“跑一小时没崩”更有诊断价值。

### 15.8.3 为什么不用 sleep

本章没有调度器，也没有 `wfi` 唤醒源。压测用忙等（每 4096 次迭代读一次时间），这样“chunk 间隔”直接反映 CPU 被谁占住。如果将来接入调度器，压测应改成“让出 + 被唤醒”，否则它会独占 CPU，把别的任务饿死。

---

## 15.9 构建、镜像与烧录

### 15.9.1 应用 ELF

```bash
zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

成功时没有输出，退出码 0。

> [!note] 两个构建选项
> 默认 `-Dpanic-demo=true`：跑完心跳/断言/watchdog 演示后故意执行非法指令并**停机**。
> 要跑稳定性或 30 s 压测时必须加 `-Dpanic-demo=false`；`-Dstress=true` 的压测在
> panic 演示之前执行，二者可以组合（`-Dstress=true -Dpanic-demo=false`）。`--summary all` 会打印：

```text
Build Summary: 4/4 steps succeeded
install success
+- install app cached
   +- compile exe app small riscv32-freestanding-eabihf cached
      +- options cached
```

### 15.9.2 镜像必须正好两个 flash 段

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf
```

输出必须包含 `Merged 2 ELF sections.`。然后：

```bash
esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`Segments Information` 里应看到两行 `DROM, IROM`：

```text
      0  0x02df0  0x40000020  0x00000018  DROM, IROM
      3  0x00e94  0x40020020  0x00010018  DROM, IROM
```

另外两行是 SRAM 段（`0x2f000000`，`.trap_ram`）与 PADDING 段。它们不是 flash 装载段，不影响 bootloader 的 `rom_index == 2` 断言。判据是“`DROM, IROM` 行数 == 2”，不是“总段数 == 2”。

### 15.9.3 烧录

```bash
sh tools/flash.sh /dev/ttyUSB0
```

脚本从 `idf-bootstrap/build/flash_args` 读偏移，保留 bootloader 与分区表行，把 `0x10000` 的应用行替换成本工程的 `app.bin`。偏移不手抄——手抄的偏移在换分区表时会静默错位。

---

## 15.10 判读手册

目标输出（验收形态，非实测）：

```text
ch15-observability-testing-stability | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
build: stress=0 panic_demo=1 trace_cap=32
clock: TIMG0 T0 1MHz (XTAL 40MHz / 40), MIE=0, no scheduler
wdt: rtc before=0xc0000000 after=0x0 tries=1
check: begin - symbols, regions, clock, interrupt, watchdog, trace
check: flash image=0x40000020 text=0x40000120..0x4000xxxx
check: flash drom=0x40020020..0x4005f020 rodata=0x40020020..0x400208a0 ok=1
check: sram trap=0x2f000000..0x2f00006c data=0x2f000070..0x2f000070
check: sram bss=0x2f000070..0x2f000390 heap=0x2f000390..0x2f076fc0
check: sram stack=0x2f076fc0..0x2f07afc0 expect_top=0x2f07afc0 size=0x4000
check: sram trap_ok=1 data_ok=1 bounds_bits=0x3f ok=1
check: clock ctrl=0x... apb_en=1 t0_clk_en=1 src=0 ok=1
check: clock delay=1000us measured=<n>us ratio=<n>% advisory=ok
check: irq mtvec=0x2f000003 base=0x2f000000 trapEntry=0x2f000000 mode=3 (info)
check: irq MIE=0 mie=0x0 thresh=<n> clic[16]=0x... ok=1
check: wdt cfg=0x... en=1 stages=0x0 flashboot=0 wprotect=0x0 ok=1
check: trace cap=32 count=32 dropped=3 oldest=0x3 newest=0x22 ok=1
checks: passed=8 failed=0 total=8 advisory=1 (clock calibration)
hb: seq=0 t=250ms ring=3/32 span=<n>us
...
```

常见失败对照：

| 现象                                   | 最可能的原因                       | 先看哪里                         |
| -------------------------------------- | ---------------------------------- | -------------------------------- |
| `clock ... measured` 远大于 1000       | 分频没写进去（advisory，不 panic） | `T0CONFIG` 的 `DIVIDER[28:13]`   |
| `clock ... measured` 约为 0            | T0 没使能，或 `UPDATE` 一直忙      | `EN` bit31、`T0UPDATE` 自清零    |
| `irq ... base != trapEntry`            | `mtvec` 没装，或被覆盖             | `_start` 第 5 步、`.trap_ram`    |
| `wdt ... stages != 0` 或 `flashboot=1` | disarm 没写进去/被重新武装         | `CONFIG0` 的 `[30:19]`、bit12    |
| `wdt ... en=1` 但 `stages=0`           | 旧序列没解 SWD_WPROTECT，EN 没清掉 | 解锁两个 WPROTECT 后重写 CONFIG0 |
| `check: trace ... ok=0`                | 环的下标/计数逻辑在目标 ABI 下不同 | `@sizeOf(Record)`、`capacity`    |
| `panic:` 之后没有 `panic: halted`      | trap 入口不在 SRAM / `mtvec` 错    | `.trap_ram`、链接脚本            |

判读原则：**先看 `checks:` 汇总，再看失败组，最后才看单行数值**。`advisory=` 是报告项而不是失败：`advisory=out-of-range` 时程序继续跑，但所有 µs 时间戳都要打问号；只有硬判据失败才 panic。“自检失败但程序继续跑”在这里是不可能的。

---

## 15.11 证据边界与稳定性报告的写法

本章的验收产物是“1 小时稳定性报告”，但本工程只提供 30 s 压测。这个差距不是偷懒，而是把报告拆成可复现的最小单元：

| 报告项     | 本工程能给的                                       | 还缺什么                         |
| ---------- | -------------------------------------------------- | -------------------------------- |
| 启动一致性 | `checks: passed=8 failed=0 advisory=1` × 10 次复位 | 无（复位 10 次即可）             |
| 时间基     | `measured` 的均值/极值                             | 示波器对照晶振                   |
| 心跳       | 8 条 `hb` 的 `t` 单调性                            | 更长时间需要 `-Dstress`          |
| 压测       | 30 s 的 `iters/sum/gap`                            | 1 小时需要改 `stress.run` 的秒数 |
| 崩溃路径   | 一次 `panic` dump（首轮未走到，自检先失败）        | 还没跑过 panic dump              |

### 首轮真机（2026-11-13）：判据也会错

首轮日志证明时间基是对的，同时把三条“硬件正常行为”误判成失败：

```text
check: clock delay=1000us measured=1003us ratio=100% advisory=ok
check: irq mtvec=0x2f000003 base=0x2f000000 trapEntry=0x2f000000 mode=3
check: wdt rtc_config0=0x8007ee00 en=1 wprotect=0x0
checks: passed=5 failed=3
```

四条修正（复跑前必须确认烧的是当前 `app.bin`：`>` 与 `>=` 生成的指令长度相同，`text=` 大小无法区分版本）：

1. `measured=1003us` 说明 1 MHz 成立；校准从硬判据降为 advisory，但继续打印；
2. `mtvec.MODE` 是 WARL 固定值 3（CLIC），判据只比较 BASE；
3. RTC WDT 的 EN 可写但旧序列没解锁 SWD_WPROTECT；次轮 `after=0x0` 证明 disarm 生效；`_start` 与 `main` 各
   disarm 一次并回读打印；
4. `sram` 的汇总位拆成 `trap_ok` / `data_ok` / `bounds_bits` 三行，
   六个边界条件各占一位。

这条经历本身就是本章的论点：**自检代码也需要被观测**。一个把三条判据折叠成
一个 `ok=0` 的检查器，和没有检查器的区别只是多了一行无法归因的输出。

次轮真机把 `sram` 定位到 `bounds_bits=0x3a`：缺 bit0（`heap_start == bss_end`）
与 bit2（`heap_end == stack_bottom`），而打印出来的地址明明相等。根因不在链接
脚本，而在优化器：LLVM 会把“两个不同全局符号的地址相等”直接折叠成 false
（链接脚本符号在编译期仍是两个不同的 GlobalValue）。修法是在 `at()` 里用一条
空的内联汇编把地址清洗成编译器无法推理的运行时值：

```zig
fn at(comptime sym: *const u8) usize {
    var v: usize = @intFromPtr(sym);
    asm volatile ("" : [v] "+r" (v) : : .{});
    return v;
}
```

这也是“自检需要被观测”的第二层含义：判据本身可能被编译器改写成恒假/恒真，
所以失败时必须能打印**参与比较的值**，而不只是结论。

### 写“待真机验证”而不是“已验证”

本章首轮未覆盖、尚未复跑的结论仍标「待真机验证」，理由不是谨慎，而是**证据链必须可追溯**：

- 寄存器地址来自 IDF v6.1 头文件（可查）；
- 分频 40 = 1 MHz 是算术（可算）；
- “写进去之后真的是 1 MHz”已测：1000 µs 请求 → 1003 µs（2026-11-13 首轮）；
- 自检结论已测：首轮 5/8，定位到「sram 判据被 LLVM 折叠 / irq 检查过早 / RWDT 未关」后修复，
  次轮 `checks: passed=8 failed=0`；
- panic 路径已测：`panic: exception code=2 (illegal instruction) cause=0x30000002` 后 `halted (wfi)`；
- 仍未跑的是：UPDATE 快照语义、30 s 压测（需 `-Dstress=true -Dpanic-demo=false`）。

把这三层分开写，读者才知道哪一层可以信、哪一层需要自己复验。反过来，把“应该”写成“实测”，会让后来的人在错误的前提下继续搭东西。

---

## 15.12 下一章预告

本章的三件套——主机侧单测、启动自检、时间戳 trace——不是 ESP32 专属。下一章进入网络底座：协议栈架构、缓冲与零拷贝、`pbuf` 所有权、校验和、timer wheel，以及**主机侧 TAP 测试骨架**。

那章会把本章的方法放大：用 TAP 在 Linux 上跑真实的以太网帧收发测试（不需要开发板），用启动自检验证 MAC/PHY 的时钟与复位，用 trace 记录每个描述符环的状态变化。如果本章的 `zig build test` 让你觉得“测试可以先于硬件”，下一章就是它的第一次大规模应用。

---
