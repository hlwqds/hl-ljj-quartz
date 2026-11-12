//! ch14-dual-core-smp-ipi：core1 的入口与运行上下文。
//!
//! core1 不是从 `_start` 进来的：core0 把 `core1Entry` 的地址写进 ROM 的
//! appcpu boot addr，解除 PMU stall、打开 core1 时钟并释放全局复位之后，
//! 硬件就从这里开始取指。
//!
//! core1 的起始状态是“裸的”：sp/gp 未定义、mtvec 还是 ROM 的、mie 可能是
//! 任意值。所以 core1Entry 的顺序是：
//!
//!   1. 关 MIE、清 mie       —— 不能带着任何中断进入 Zig 代码；
//!   2. sp / gp              —— 任何函数调用（包括 core1Main 的序言）之前必须有效；
//!   3. mtvec = trapEntry    —— 之后才允许可能陷入的代码；
//!   4. call core1Main       —— 永不返回。
//!
//! `gp` 必须在第一条可能被链接器 relaxation 改写成 gp 相对寻址的指令之前
//! 设好；`.option norelax` 包住 `la gp, ...` 与 IDF 的 `call_start_cpu1`
//! （components/esp_system/port/cpu_start.c:225）完全同构。
//!
//! core1Main 按顺序补完剩下的初始化：
//!
//!   1. `smp.attach()`  —— mscratch = &PerCpu[1]。**必须最先做**：
//!      之后的任何 trap 都要靠它找“我是谁”；
//!   2. IPI 输入 20 与本核矩阵路由（源 66）；
//!   3. TIMG0 T1 的 1 ms tick（源 26 → 本核输入 16）；
//!   4. `markReady()`   —— 告诉 core0“可以发第一个 IPI 了”；
//!   5. `sched.start(1)` —— 换到 core1 的 idle 栈，打开 MIE，开始轮转。
//!
//! 注意这里**不清 .bss**：core0 在启动 core1 之前已经清过一遍，再清一次
//! 会把 core0 已建立的任务、队列、计数器全部抹掉。这是 SMP 启动里最容易
//! 写错的一步 —— “每个核都跑一遍 _start” 是单核思维的惯性。

const hw = @import("hw.zig");
const smp = @import("smp.zig");
const clic = @import("clic.zig");
const tick = @import("tick.zig");
const sched = @import("sched.zig");
const console = @import("console.zig");
const context = @import("context.zig");

/// core1 的入口栈。放 .bss，由 core1Entry 自己把 sp 设到它顶端；
/// 与 core0 的 `_stack_top`（SRAM 末尾）不重叠。
pub export var core1_stack: [8192]u8 align(16) = undefined;

comptime {
    // 下面汇编里的 `call core1Main` / `la t0, trapEntry` 对 Zig 的引用图
    // 不可见（它们只是字符串），必须显式引用，否则符号不会出现在目标文件里。
    _ = &core1Main;
    _ = &context.trapEntry;
}

/// core1 的第一次取指点（core0 把它写进 ROM 的 appcpu boot addr）。
///
/// 它和 trapEntry 一样放进 SRAM 的 `.trap_ram`：core1 起来时 core0 的
/// flash/cache 配置是否对它同样可见，是本工程没有同步过的假设
/// （IDF 在 do_multicore_settings 里把 core0 的 L1 bus mask 复制给 core1）。
/// 入口桩放 SRAM 只是把“第一条指令就要取 flash”这层依赖去掉；
/// `call core1Main` 之后的代码仍在 flash，这条依赖列为待真机验证项。
pub export fn core1Entry() linksection(".trap_ram") callconv(.naked) noreturn {
    asm volatile (
        \\        csrci   mstatus, 0x8
        \\        csrw    mie, zero
        \\
        \\        la      t0, core1_stack
        \\        li      t1, 8192
        \\        add     sp, t0, t1
        \\        andi    sp, sp, -16
        \\
        \\        .option push
        \\        .option norelax
        \\        la      gp, __global_pointer$
        \\        .option pop
        \\
        \\        la      t0, trapEntry
        \\        csrw    mtvec, t0
        \\
        \\        call    core1Main
        \\1:
        \\        wfi
        \\        j       1b
    );
}

pub export fn core1Main() callconv(.c) noreturn {
    smp.attach();

    // 本核的中断骨架：IPI（源 66 → 输入 20）+ 阈值 + MEIE。
    // tick.init(1) 会再补上源 26 → 输入 16。
    clic.route(1, clic.source_from_cpu_1, clic.ipi_input_core1);
    clic.setupIpiInput(1);
    hw.meieEnable();

    tick.init(1);
    clic.setThreshold(0);

    console.line("core1: up hart={d} sp=0x{x} clic_ipi=input {d} tick=TIMG0_T1/input {d}", .{
        hw.hartId(),
        readSp(),
        clic.ipi_input_core1,
        clic.tick_input,
    });

    smp.markReady();
    sched.start(1);
}

fn readSp() usize {
    return asm volatile ("mv %[d], sp"
        : [d] "=r" (-> usize),
    );
}
