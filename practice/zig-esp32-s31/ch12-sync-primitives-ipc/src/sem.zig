//! ch12-sync-primitives-ipc：计数信号量。
//!
//! 信号量只有两个操作、一个计数器，没有所有者。它同时承担两种完全不同的
//! 用途，混用是死锁的常见来源：
//!
//!   1. **互斥**（初值 1）：`wait` 拿走唯一的名额，`post` 还回来。
//!      能用，但不要这么做——没有所有权就没有继承，反转只能靠运气。
//!   2. **计数 / 顺序**（初值 0）：生产者 `post`、消费者 `wait`。
//!      这才是信号量的主场：它表达“某件事已经发生了 N 次”。
//!
//! 本章用它做两件事：
//!   - `sem_locked`（初值 0）：低优先级任务“我已经拿到锁了”的通知，
//!     让 supervisor 不用轮询就能在正确时刻创建中/高优先级任务；
//!   - `sem_phase_done`（初值 0）：三个任务各自 `post` 一次，
//!     supervisor `wait` 三次。计数可以在没人等待时累积，
//!     这正是“信号量 ≠ 事件”的地方：事件是状态，信号量是次数。
//!
//! 唤醒策略：取等待链上**有效优先级最高**的任务（同级 FIFO）。

const std = @import("std");
const sched = @import("sched.zig");

pub const Semaphore = struct {
    name: []const u8 = "sem",
    /// 当前可用名额。非负是信号量的语义要求。
    count: u32 = 0,
    waiters: sched.WaitList = .{},
    /// 统计：阻塞次数 / post 次数。
    blocks: u32 = 0,
    posts: u32 = 0,
    /// 没有等待者时 post 直接累加的次数（可累积性的证据）。
    accumulated: u32 = 0,
};

pub fn init(name: []const u8, count: u32) Semaphore {
    return .{ .name = name, .count = count };
}

/// 取一个名额。没有就阻塞，直到有人 `post`。
pub fn wait(s: *Semaphore) void {
    const old = sched.irqSave();
    if (s.count > 0) {
        s.count -= 1;
        sched.irqRestore(old);
        return;
    }
    s.blocks += 1;
    // blockOn 返回时，名额已经被 post 那边“代扣”掉了：
    // post 直接把它交给我们，而不是先加回计数器再让别人抢走。
    sched.blockOn(&s.waiters, s.name);
    sched.irqRestore(old);
}

/// 释放一个名额：有等待者就直接交给最该跑的那个，没有就累加。
pub fn post(s: *Semaphore) void {
    const old = sched.irqSave();
    s.posts += 1;
    if (sched.waitPopBest(&s.waiters)) |w| {
        // 直接交接：不加计数器，避免“刚 post 就被第三个任务抢走”。
        sched.wake(w);
        sched.rescheduleIfNeeded();
    } else {
        s.count += 1;
        s.accumulated += 1;
    }
    sched.irqRestore(old);
}

/// 只读当前计数（诊断用；读它本身不是同步操作）。
pub fn value(s: *const Semaphore) u32 {
    return s.count;
}

/// 非阻塞取名额：有就取走并返回 true，没有立刻返回 false。
///
/// 本章的 supervisor 用它做**有上界的轮询**，而不是无限阻塞等待。
/// 理由来自真机：一次“通知丢了”（post 与 wait 的配对在重构中被写错、
/// 或等待者根本不在链上）会让整场演示变成静默挂死，而静默是本章
/// 最难查的失败型——没有日志、没有 trap、只有不再变化的那一行。
/// 有界等待至少能打印“超时了多少个 tick”。
pub fn tryWait(s: *Semaphore) bool {
    const old = sched.irqSave();
    const ok = s.count > 0;
    if (ok) s.count -= 1;
    sched.irqRestore(old);
    return ok;
}
