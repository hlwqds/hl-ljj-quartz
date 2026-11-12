//! ch12-sync-primitives-ipc：定长环形队列（生产者 / 消费者）。
//!
//! 队列比信号量多一件事：**它带数据**。所以除了“有没有空位/有没有元素”，
//! 还要保证“取走的元素刚好是别人放进去的那个”，并且放/取两个方向各有
//! 一条等待链——这是本章唯一同时用到两个等待链的原语。
//!
//! 结构是教科书式的环形缓冲：
//!
//! ```text
//!   head          tail
//!    ↓             ↓
//!  [ 7 ][ - ][ 5 ][ 9 ]   容量 4
//!    len = 3, high_water = 3
//! ```
//!
//! - `tail` 是下一个写入位置，`head` 是下一个读取位置；
//! - `len` 是唯一权威的“有多少个”，不从 head/tail 推导（推导式在环绕时
//!   容易把“满”和“空”混成同一个形状）；
//! - 容量固定：`.bss` 里的静态数组，零分配。容量用满时**阻塞生产者**，
//!   而不是丢数据或覆盖旧数据——静默丢弃会让消费者永远等不到它以为存在的
//!   元素，是比死锁更难查的 bug。
//!
//! 阻塞/唤醒的配对：
//!   - `put` 成功后唤醒一个等 `get` 的消费者；
//!   - `get` 成功后唤醒一个等 `put` 的生产者。
//! 被唤醒者醒来**不保证**立刻拿到名额（可能被别人抢先），所以 `put`/`get`
//! 都是 `while` 循环重新检查条件，而不是 `if`。这是“条件等待”的通用形状。

const std = @import("std");
const sched = @import("sched.zig");

/// 队列容量（元素个数）。4 是小到能在日志里手算、又足以让生产者
/// 真正撞满的数。
pub const capacity: usize = 4;

pub const Queue = struct {
    name: []const u8 = "queue",
    buf: [capacity]u32 = @splat(0),
    /// 下一个读取位置。
    head: usize = 0,
    /// 下一个写入位置。
    tail: usize = 0,
    /// 当前元素个数（唯一权威）。
    len: usize = 0,
    /// 历史最高水位（证据：说明队列真的被填满过）。
    high_water: usize = 0,
    /// 等空位的生产者 / 等元素的消费者。
    put_waiters: sched.WaitList = .{},
    get_waiters: sched.WaitList = .{},
    puts: u32 = 0,
    gets: u32 = 0,
    put_blocks: u32 = 0,
    get_blocks: u32 = 0,
};

pub fn init(name: []const u8) Queue {
    return .{ .name = name };
}

/// 放入一个元素。满了就阻塞。返回被阻塞的次数（诊断用，可选忽略）。
pub fn put(q: *Queue, v: u32) void {
    const old = sched.irqSave();

    // 用 while 而不是 if：被唤醒不等于条件成立（名额可能被别人抢走）。
    while (q.len == capacity) {
        q.put_blocks += 1;
        sched.blockOn(&q.put_waiters, q.name);
    }

    q.buf[q.tail] = v;
    q.tail = (q.tail + 1) % capacity;
    q.len += 1;
    if (q.len > q.high_water) q.high_water = q.len;
    q.puts += 1;

    // 有新元素 → 唤醒一个消费者。
    if (sched.waitPopBest(&q.get_waiters)) |w| {
        sched.wake(w);
        sched.rescheduleIfNeeded();
    }

    sched.irqRestore(old);
}

/// 取出一个元素。空了就阻塞。
pub fn get(q: *Queue) u32 {
    const old = sched.irqSave();

    while (q.len == 0) {
        q.get_blocks += 1;
        sched.blockOn(&q.get_waiters, q.name);
    }

    const v = q.buf[q.head];
    q.head = (q.head + 1) % capacity;
    q.len -= 1;
    q.gets += 1;

    // 有空位 → 唤醒一个生产者。
    if (sched.waitPopBest(&q.put_waiters)) |w| {
        sched.wake(w);
        sched.rescheduleIfNeeded();
    }

    sched.irqRestore(old);
    return v;
}

/// 只读快照（诊断用）。
pub fn depth(q: *const Queue) usize {
    return q.len;
}
