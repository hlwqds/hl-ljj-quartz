//! ch12-sync-primitives-ipc：互斥量 + 优先级继承。
//!
//! 与信号量的区别只有两条，但两条都重要：
//!
//!   1. **所有权**：互斥量记得“谁持有”，因此可以在放锁时判断“是否合法放锁”，
//!      也可以做优先级继承。信号量没有所有者，任何任务都能 `post`。
//!   2. **继承**：高优先级任务等锁时，把持有者的有效优先级抬到和自己的
//!      **基础优先级**一样高。这样中优先级任务就无法插队。
//!
//! 为什么抬到 `base_prio` 而不是 `prio`：抬到 `prio` 会把“别人已经给你抬过的
//! 高度”继续传播出去，两层嵌套时优先级会虚高（本工程只做单层，但字段语义
//! 必须一开始就对，否则一加嵌套就错）。
//!
//! 传递方式：**handoff**。放锁时直接把所有权交给等待链上最该跑的那个任务，
//! 被唤醒者醒来即持有，不再重新竞争。这避免了“醒来→发现又被抢→再睡”的
//! 活锁，也让“优先级继承有没有生效”这件事可测量：放锁瞬间就切换。

const std = @import("std");
const sched = @import("sched.zig");

pub const Mutex = struct {
    name: []const u8 = "mutex",
    /// 当前持有者。null = 空闲。
    owner: ?*sched.Task = null,
    /// 等待者链（按有效优先级挑，同级 FIFO）。
    waiters: sched.WaitList = .{},
    /// 是否启用优先级继承。关掉它就能复现反转——这就是本章的对照实验。
    pi: bool = true,
    /// 成功加锁次数。
    locks: u32 = 0,
    /// 放锁时发生继承的次数（证据：无 PI 恒为 0）。
    boosts: u32 = 0,
    /// 因递归加锁被拒绝的次数。
    rejected: u32 = 0,
};

pub fn init(name: []const u8, pi: bool) Mutex {
    return .{ .name = name, .pi = pi };
}

/// 加锁。可能阻塞；返回时一定持有锁。
///
/// 整个“判断 + 继承 + 入等待链 + 换栈”必须在关中断的窗口里完成，
/// 否则会出现丢失唤醒：检查时空闲、真正入链前被别人抢走并放锁、
/// 放锁者看到空等待链直接返回，而我们带着 `blocked` 永远睡下去。
pub fn lock(m: *Mutex) void {
    const old = sched.irqSave();
    const t = sched.currentTask() orelse {
        sched.irqRestore(old);
        return;
    };

    if (m.owner == null) {
        m.owner = t;
        m.locks += 1;
        sched.irqRestore(old);
        return;
    }

    if (m.owner == t) {
        // 本章不支持递归锁：要么实现持有计数，要么明确拒绝。
        // 静默“成功”会让放锁次数与加锁次数不等，最终把锁永久留在别人手里。
        m.rejected += 1;
        sched.line("mutex[{s}]: recursive lock by {s} rejected", .{ m.name, t.name });
        sched.irqRestore(old);
        return;
    }

    if (m.pi) {
        const o = m.owner.?;
        if (t.base_prio > o.prio) {
            // 只抬到“请求者自己的基础优先级”，不是请求者的有效优先级。
            sched.setPrio(o, t.base_prio);
            m.boosts += 1;
            o.boosts += 1;
        }
    }

    sched.blockOn(&m.waiters, m.name);

    // 被 handoff 唤醒：`unlock` 已经把 owner 写成我们了，直接继续。
    m.locks += 1;
    sched.irqRestore(old);
}

/// 放锁。空闲时若无等待者就置空；有等待者就 handoff 给最该跑的，
/// 并在需要时立刻切换（`rescheduleIfNeeded`）。
pub fn unlock(m: *Mutex) void {
    const old = sched.irqSave();
    const t = sched.currentTask() orelse {
        sched.irqRestore(old);
        return;
    };

    if (m.owner != t) {
        sched.line("mutex[{s}]: unlock by non-owner {s} ignored", .{ m.name, t.name });
        sched.irqRestore(old);
        return;
    }

    m.owner = null;

    // 先把自己的优先级还回去，再挑下一个：若顺序反了，`pickNext` 会看到
    // 一个“还带着继承高度”的旧持有者，判断出错误的抢占关系。
    if (t.prio != t.base_prio) sched.setPrio(t, t.base_prio);

    if (sched.waitPopBest(&m.waiters)) |w| {
        // handoff：先把所有权写进 TCB，再让它就绪。
        m.owner = w;
        if (w.prio != w.base_prio) sched.setPrio(w, w.base_prio);
        sched.wake(w);
    }

    // 被唤醒者（或别的就绪任务）优先级高于我们 → 立刻让出。
    // 这一步是“继承有效”的可见机制：没有它，继承只改变字段，
    // 要等下一个 tick 才体现，1 ms 的粒度会把差异淹没。
    sched.rescheduleIfNeeded();
    sched.irqRestore(old);
}
