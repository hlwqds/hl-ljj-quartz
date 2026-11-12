//! ch10-context-switch-scheduler：把 `main` 变成 idle 任务，再启动三个任务。
//!
//! 本章没有“主循环”——`main` 最后调用 `sched.start()`，从那一刻起它就是
//! idle 任务（复用 `_stack_top` 那张栈）。全部任务完成后，idle 打印统计
//! 并停在 `wfi`。
//!
//! 任务栈是 `.bss` 里的静态数组，`align(16)` 由 Zig 类型保证；
//! 链接脚本不需要为它们做任何事。

const sched = @import("sched.zig");
const context = @import("context.zig");
const tasks = @import("tasks.zig");

const stack_bytes = 2048;

var stack_a: [stack_bytes]u8 align(16) = undefined;
var stack_b: [stack_bytes]u8 align(16) = undefined;
var stack_c: [stack_bytes]u8 align(16) = undefined;

/// 读 CSR 只用于打印，不参与调度决策。
fn readMtvec() usize {
    return asm volatile ("csrr %[d], mtvec"
        : [d] "=r" (-> usize)
    );
}

pub export fn main() noreturn {
    const mtvec = readMtvec();

    sched.line("ch10-context-switch | form B (Zig ELF + IDF 2nd-stage bootloader)", .{});
    sched.line("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)", .{});
    sched.line("mtvec: base=0x{x} mode={d} (0 = direct; only synchronous traps)", .{
        mtvec & ~@as(usize, 3),
        mtvec & 3,
    });
    sched.line("frames: trap={d} switch={d} bytes (integer only; FP variant would be {d})", .{
        context.trap_frame_bytes,
        context.switch_frame_bytes,
        context.fp_switch_frame_bytes,
    });

    _ = sched.create("A", &stack_a, @intFromPtr(&tasks.workerA));
    _ = sched.create("B", &stack_b, @intFromPtr(&tasks.workerB));
    _ = sched.create("C", &stack_c, @intFromPtr(&tasks.workerC));

    sched.line("sched: {d} tasks + idle, cooperative yield via ecall", .{sched.taskCount()});

    sched.start();
}
