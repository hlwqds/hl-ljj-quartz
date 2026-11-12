//! ch12-sync-primitives-ipc：事件组（位掩码 + 唤醒全部再复核）。
//!
//! 事件组与信号量的差别不在“等不等”，而在**等的是什么**：
//!
//! | 原语     | 语义                     | 唤醒策略                 | 会丢失吗             |
//! | -------- | ------------------------ | ------------------------ | -------------------- |
//! | 信号量   | 计数（发生了 N 次）      | 取一个等待者             | 不丢：没人等就累加   |
//! | 事件组   | 状态（某些位已经置位）   | **全部唤醒**，各自复核   | 不丢：位一直留在那里 |
//! | 队列     | 数据（有 N 个元素）      | 取一个等待者             | 不丢：元素留在队列里 |
//!
//! 事件组最省事的实现就是“唤醒全部 + 等待者自己重新检查谓词”。代价是
//! 惊群（thundering herd）：一次 `set` 可能让 10 个任务全都醒一遍、
//! 检查一遍、9 个再睡回去。本章 n 很小，可读性优先；
//! 真实内核要么按位索引等待者，要么用条件变量式的谓词回调。
//!
//! 为什么不能“只唤醒可能满足的那个”：一位被 `set` 之后，某个等待者的
//! `(bits & mask) == mask` 才成立，而这个判断依赖它自己的 mask 与 all/any
//! 模式。内核若替它算，就得把每个等待者的谓词都存下来——那已经是在实现
//! 条件变量了。唤醒全部把这段逻辑留在等待者一侧，正确性最好论证。

const std = @import("std");
const sched = @import("sched.zig");

pub const Mode = enum {
    /// 所有请求位都置位才返回。
    all,
    /// 任意一位置位就返回。
    any,
};

pub const EventGroup = struct {
    name: []const u8 = "events",
    /// 32 个事件位。位是“状态”，set 之后一直保持，直到显式 clear。
    bits: u32 = 0,
    waiters: sched.WaitList = .{},
    sets: u32 = 0,
    waits: u32 = 0,
    wakeups: u32 = 0,
    /// 被唤醒后复核不通过、又睡回去的次数（惊群代价的证据）。
    reblocks: u32 = 0,
};

pub fn init(name: []const u8) EventGroup {
    return .{ .name = name };
}

/// 置位并唤醒**所有**等待者。
pub fn set(eg: *EventGroup, mask: u32) void {
    const old = sched.irqSave();
    eg.bits |= mask;
    eg.sets += 1;

    var woke: u32 = 0;
    while (sched.waitPopBest(&eg.waiters)) |w| {
        sched.wake(w);
        woke += 1;
    }
    eg.wakeups += woke;

    if (woke > 0) sched.rescheduleIfNeeded();
    sched.irqRestore(old);
}

/// 清位。注意：清位不会唤醒任何人，只会让已经在等的任务多睡一会儿。
pub fn clear(eg: *EventGroup, mask: u32) void {
    const old = sched.irqSave();
    eg.bits &= ~mask;
    sched.irqRestore(old);
}

/// 等待位。返回返回时的完整位图（调用者可以从中读到自己关心的位）。
///
/// 用 `while` 而不是 `if`：被唤醒只是“可能可以前进了”，
/// 谓词必须每次重新求值。
pub fn wait(eg: *EventGroup, mask: u32, mode: Mode) u32 {
    const old = sched.irqSave();
    eg.waits += 1;

    while (true) {
        const v = eg.bits;
        const ok = switch (mode) {
            .all => (v & mask) == mask,
            .any => (v & mask) != 0,
        };
        if (ok) {
            sched.irqRestore(old);
            return v;
        }
        eg.reblocks += 1;
        sched.blockOn(&eg.waiters, eg.name);
        // 醒来后仍持有进入时的中断状态（外层 irqSave 的效应），直接复核。
    }
}

/// 只读快照（诊断用）。
pub fn peek(eg: *const EventGroup) u32 {
    return eg.bits;
}
