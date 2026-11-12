//! ch11-preemptive-scheduler：三个**不主动让出**的任务。
//!
//! 与 ch10 最大的差别：任务体里没有 `sched.yield()`。每个任务只是
//! “忙等一段 → 打印 → 继续”，被换下完全由 tick ISR 决定。
//! 这正是“抢占”的可观测定义：输出交错不依赖任务配合。
//!
//! 优先级与时间片：
//!   - hi   ：prio 5，slice 3 → 启动后立即占 CPU，高优先级期间低优先级无输出；
//!   - loA  ：prio 1，slice 2 ┐ 同级，按 2 tick 轮转；
//!   - loB  ：prio 1，slice 2 ┘
//!
//! 忙等量是“编译器挡不住”的整数 nop 循环：`asm volatile` 保证不被优化掉，
//! 也不引入浮点（FPU 帧是 208 字节，本章不实现）。

const sched = @import("sched.zig");

pub fn spinHigh(t: *sched.Task) callconv(.c) noreturn {
    run(t, 6, 800_000);
}

pub fn spinLowA(t: *sched.Task) callconv(.c) noreturn {
    run(t, 4, 900_000);
}

pub fn spinLowB(t: *sched.Task) callconv(.c) noreturn {
    run(t, 4, 700_000);
}

/// 纯整数忙等：保证循环不会被优化掉。
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
        sched.line("{s}: beat {d} (prio={d} slice={d})", .{
            t.name,
            i + 1,
            t.prio,
            t.slice_init,
        });
    }
    sched.finish(t);
}
