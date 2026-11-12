//! ch10-context-switch-scheduler：三个整数任务。
//!
//! 每个任务都遵守同一条契约：做一点事 → 打印 → 主动让出 → 重复。
//! 任务体是 `callconv(.c) noreturn`，唯一参数是调度器分配的 TCB 指针
//! （由 context.zig 的 taskStart 从 s1 搬进 a0）。
//!
//! 这里刻意只用整数与字符串：浮点会把 switch 帧从 64 字节推到 208 字节，
//! 还会踩到 S31 的 FPU 勘误（见 context.zig 的注释）。
//! 三个任务的轮数/工作量不同，是为了让“轮转”在串口上肉眼可见。

const sched = @import("sched.zig");

pub fn workerA(t: *sched.Task) callconv(.c) noreturn {
    run(t, 3, 40);
}

pub fn workerB(t: *sched.Task) callconv(.c) noreturn {
    run(t, 4, 10);
}

pub fn workerC(t: *sched.Task) callconv(.c) noreturn {
    run(t, 2, 70);
}

/// 纯整数忙等：`asm volatile ("nop")` 保证循环不会被优化掉。
fn burn(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        asm volatile ("nop");
    }
}

fn run(t: *sched.Task, rounds: u32, work: u32) noreturn {
    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        burn(work);
        t.steps = i + 1;
        sched.line("{s}: step {d}", .{ t.name, i + 1 });
        sched.yield();
    }
    sched.finish(t);
}
