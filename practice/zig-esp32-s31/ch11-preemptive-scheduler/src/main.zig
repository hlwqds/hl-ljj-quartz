//! ch11-preemptive-scheduler：建三个任务、初始化 tick，把 `main` 变成 idle。
//!
//! 本章没有“主循环”——`main` 最后调用 `sched.start()`，从那一刻起它就是
//! idle 任务（复用 `_stack_top` 那张栈）。全部任务完成后，idle 打印统计、
//! 停 tick，并停在 `wfi`。
//!
//! 任务栈是 `.bss` 里的静态数组，`align(16)` 由 Zig 类型保证；
//! 链接脚本不需要为它们做任何事。
//!
//! 启动顺序的两个硬约束：
//!   1. `tick.init()` 必须在 `sched.start()`（它才打开 MIE）之前；
//!   2. `mtvec` 已在 `_start` 里装好，早于任何 `ecall` 与 tick。

const sched = @import("sched.zig");
const context = @import("context.zig");
const tasks = @import("tasks.zig");
const tick = @import("tick.zig");

const stack_bytes = 2048;

var stack_hi: [stack_bytes]u8 align(16) = undefined;
/// idle 的独立栈：不复用 main 的栈（见 sched.start 的注释）。
var stack_idle: [stack_bytes]u8 align(16) = undefined;
var stack_lo_a: [stack_bytes]u8 align(16) = undefined;
var stack_lo_b: [stack_bytes]u8 align(16) = undefined;

/// 读 CSR 只用于打印，不参与调度决策。
fn readMtvec() usize {
    return asm volatile ("csrr %[d], mtvec"
        : [d] "=r" (-> usize)
    );
}

pub export fn main() noreturn {
    const mtvec = readMtvec();

    sched.line("ch11-preemptive-scheduler | form B (Zig ELF + IDF 2nd-stage bootloader)", .{});
    sched.line("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)", .{});
    sched.line("mtvec: base=0x{x} mode={d} (0 = direct)", .{
        mtvec & ~@as(usize, 3),
        mtvec & 3,
    });
    sched.line("frames: trap={d} switch={d} bytes (integer only; FP variant would be {d})", .{
        context.trap_frame_bytes,
        context.switch_frame_bytes,
        context.fp_switch_frame_bytes,
    });
    sched.line("tick: {d} us via TIMG0 T0 (source {d}) -> clic input {d} prio {d}", .{
        tick.period_us,
        tick.source,
        tick.input,
        tick.prio,
    });

    _ = sched.create("hi", &stack_hi, @intFromPtr(&tasks.spinHigh), 5, 3);
    _ = sched.create("loA", &stack_lo_a, @intFromPtr(&tasks.spinLowA), 1, 2);
    _ = sched.create("loB", &stack_lo_b, @intFromPtr(&tasks.spinLowB), 1, 2);

    sched.line("sched: {d} tasks + idle, preemptive (slice in ticks); soft-yield input {d} not wired", .{
        sched.taskCount(),
        tick.soft_input,
    });

    tick.init(tick.period_us);
    sched.start(&stack_idle);
}
