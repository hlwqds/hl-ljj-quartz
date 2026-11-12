//! ch16-stack-architecture-zero-copy：哈希时间轮（hashed timer wheel）。
//!
//! ## 为什么不是“一个有序链表 + 每次 tick 从头扫”
//!
//! lwIP 的 `timeouts.c` 用一条按到期时间排序的链表，`sys_check_timeouts()`
//! 每次从表头扫到第一个未到期的元素。连接数少时这没问题；一旦有几千个
//! TCP 重传计时器（RTO）、ARP 老化、DHCP 租期，链表插入退化成 O(n)，
//! 每次 tick 也至少 O(1) 起步但常数随连接数增长。
//!
//! 时间轮把“到期时间”哈希到固定数量的槽里：
//!
//!     bucket = expire_at % slots
//!
//! 每个 tick 只处理 `now % slots` 这一个槽。跨度大于一圈（`slots` 个 tick）
//! 的计时器在被扫到时还没到期，就**原地放回**——因为 `expire_at` 不变，
//! 它的桶号也不变，于是它会在下一圈的同一个槽被再次看到，直到 `expire_at`
//! 与 `now` 对齐。这就是最简单的“级联”：没有层级、没有额外内存，
//! 代价是每个大跨度计时器每圈被看一眼（O(1) 检查，不是 O(n) 扫描）。
//!
//! 这个结构来自 Varghese & Lauck 的 hashed timing wheel（1987；
//! 1997 年 ACM TOCS 的 hierarchical timing wheels 是其多级扩展）。
//!
//! ## 本实现的取舍
//!
//!   - **固定容量**：`Wheel(cap, slots)`，条目从空闲链取，池空即 `error.NoSpace`；
//!   - **句柄带 generation**：`cancel` 传入旧句柄时不会误杀复用同一槽位的新计时器；
//!   - **到期只入队、不回调**：`tick` 不执行任何用户代码，调用方用 `popDue`
//!     取走到期 id。这避免了“回调里再 schedule 导致重入”的经典死锁；
//!   - **tick 单位由调用方定义**：本章用 1 tick = 1 ms，但结构本身不知道时间。
//!
//! ## 与 RTO 的关系
//!
//! RFC 6298 的 RTO 是“从现在起 N 个 tick 后重传”。用时间轮表达就是
//! `schedule(seq, rto_ticks)`；收到 ACK 时 `cancel(handle)`；超时后
//! `popDue()` 得到 seq，重算 RTO 再 `schedule` 一次。这也是 ch20 的地基。

const std = @import("std");

pub fn Wheel(comptime cap: usize, comptime slots: usize) type {
    return struct {
        const Self = @This();

        pub const capacity = cap;
        pub const slot_count = slots;

        pub const Error = error{
            NoSpace,
            InvalidDelay,
        };

        /// 到期事件：调用方拿到的 id 与它原本的绝对到期 tick。
        pub const Due = struct {
            id: u32,
            at: u32,
        };

        /// 计时器句柄。`generation` 让“取消一个已经到期的旧计时器”变成安全的 no-op。
        pub const Handle = struct {
            index: u16,
            generation: u16,
        };

        const Entry = struct {
            id: u32 = 0,
            expire_at: u32 = 0,
            generation: u16 = 0,
            next: ?u32 = null,
            /// 在槽里等待（active）或已到期等待 popDue（queued）。
            active: bool = false,
            queued: bool = false,
        };

        pub const Stats = struct {
            scheduled: u32 = 0,
            expired: u32 = 0,
            cancelled: u32 = 0,
            /// 大跨度计时器被“原地放回”的次数。它是“圈数”的度量。
            reinserted: u32 = 0,
            exhausted: u32 = 0,
        };

        entries: [cap]Entry = @splat(Entry{}),
        buckets: [slots]?u32 = @splat(null),
        free_head: ?u32 = null,
        now: u32 = 0,

        due_ids: [cap]u32 = @splat(0),
        due_at: [cap]u32 = @splat(0),
        due_index: [cap]u32 = @splat(0),
        due_head: usize = 0,
        due_len: usize = 0,

        stats: Stats = .{},

        /// 建立空闲链。所有条目初始 generation = 0。
        pub fn init() Self {
            var self: Self = .{};
            var i: usize = cap;
            while (i > 0) {
                i -= 1;
                self.entries[i].next = self.free_head;
                self.free_head = @intCast(i);
            }
            return self;
        }

        pub fn activeCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.entries) |e| {
                if (e.active) n += 1;
            }
            return n;
        }

        /// `delay` 必须 >= 1。返回值用于 `cancel`。
        pub fn schedule(self: *Self, id: u32, delay: u32) Error!Handle {
            if (delay == 0) return error.InvalidDelay;
            const idx = self.free_head orelse {
                self.stats.exhausted += 1;
                return error.NoSpace;
            };
            const e = &self.entries[idx];
            self.free_head = e.next;

            const gen = e.generation +% 1;
            const expire = self.now +% delay;
            e.* = .{
                .id = id,
                .expire_at = expire,
                .generation = gen,
                .next = null,
                .active = true,
                .queued = false,
            };
            self.insert(idx, expire);
            self.stats.scheduled += 1;
            return .{ .index = @intCast(idx), .generation = gen };
        }

        /// 取消一个尚未到期的计时器。句柄过期（已到期/已被取消/槽位被复用）时返回 false。
        pub fn cancel(self: *Self, handle: Handle) bool {
            const idx: u32 = handle.index;
            if (idx >= cap) return false;
            const e = &self.entries[idx];
            if (!e.active or e.generation != handle.generation) return false;
            if (!self.unlink(idx)) return false;
            self.release(idx);
            self.stats.cancelled += 1;
            return true;
        }

        /// 推进一个 tick，处理 `now % slots` 槽里的所有到期项。
        pub fn tick(self: *Self) void {
            self.now +%= 1;
            const bucket: usize = @intCast(self.now % slot_count);
            var cur = self.buckets[bucket];
            self.buckets[bucket] = null;

            while (cur) |idx| {
                const e = &self.entries[idx];
                const nxt = e.next;
                e.next = null;

                // 到期的判定必须考虑 u32 回绕：差值的符号位表示“还没到”。
                const delta = e.expire_at -% self.now;
                const due = @as(i32, @bitCast(delta)) <= 0;
                if (due) {
                    e.active = false;
                    e.queued = true;
                    self.pushDue(idx, e.id, e.expire_at);
                    self.stats.expired += 1;
                } else {
                    // 大跨度计时器：expire_at 不变 → 桶号不变 → 下一圈再见。
                    self.insert(idx, e.expire_at);
                    self.stats.reinserted += 1;
                }
                cur = nxt;
            }
        }

        /// 推进 `ticks` 个 tick。到期项进入队列，由 `popDue` 取走。
        pub fn advance(self: *Self, ticks: u32) void {
            var t: u32 = 0;
            while (t < ticks) : (t += 1) self.tick();
        }

        /// 取走一个到期事件（FIFO）。队列空时返回 null。
        pub fn popDue(self: *Self) ?Due {
            if (self.due_len == 0) return null;
            const slot = self.due_head;
            self.due_head = (self.due_head + 1) % cap;
            self.due_len -= 1;

            const id = self.due_ids[slot];
            const at = self.due_at[slot];
            const idx = self.due_index[slot];
            self.entries[idx].queued = false;
            self.release(idx);
            return .{ .id = id, .at = at };
        }

        pub fn pendingDue(self: *const Self) usize {
            return self.due_len;
        }

        /// 最近一个到期 tick（用于 tickless 睡眠：提前醒来）。O(cap)。
        pub fn nextDeadline(self: *const Self) ?u32 {
            var best: ?u32 = null;
            for (self.entries) |e| {
                if (!e.active) continue;
                if (best) |b| {
                    if (@as(i32, @bitCast(e.expire_at -% b)) < 0) best = e.expire_at;
                } else {
                    best = e.expire_at;
                }
            }
            return best;
        }

        fn insert(self: *Self, idx: u32, expire_at: u32) void {
            const bucket: usize = @intCast(expire_at % @as(u32, @intCast(slot_count)));
            self.entries[idx].next = self.buckets[bucket];
            self.buckets[bucket] = idx;
        }

        fn unlink(self: *Self, idx: u32) bool {
            const bucket: usize = @intCast(self.entries[idx].expire_at % @as(u32, @intCast(slot_count)));
            var cur = self.buckets[bucket];
            var prev: ?u32 = null;
            while (cur) |c| {
                if (c == idx) {
                    const nxt = self.entries[c].next;
                    if (prev) |p| {
                        self.entries[p].next = nxt;
                    } else {
                        self.buckets[bucket] = nxt;
                    }
                    return true;
                }
                prev = c;
                cur = self.entries[c].next;
            }
            return false;
        }

        fn release(self: *Self, idx: u32) void {
            const e = &self.entries[idx];
            e.next = self.free_head;
            e.active = false;
            e.queued = false;
            self.free_head = idx;
        }

        fn pushDue(self: *Self, idx: u32, id: u32, at: u32) void {
            const slot = (self.due_head + self.due_len) % cap;
            self.due_ids[slot] = id;
            self.due_at[slot] = at;
            self.due_index[slot] = idx;
            self.due_len += 1;
        }
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "wheel: 精确在 delay 个 tick 后到期（早一 tick 不到）" {
    var w = Wheel(8, 8).init();
    _ = try w.schedule(42, 3);

    w.advance(2);
    try testing.expect(w.popDue() == null);

    w.advance(1);
    const d = w.popDue().?;
    try testing.expectEqual(@as(u32, 42), d.id);
    try testing.expectEqual(@as(u32, 3), d.at);
    try testing.expect(w.popDue() == null);
    try testing.expectEqual(@as(usize, 0), w.activeCount());
}

test "wheel: 跨 tick 的到期事件按到期先后 FIFO 出队" {
    // 三个事件都落在同一个桶（delay 2/10/18，slots=8 → 桶 2），
    // 但到期 tick 不同：推进到 18 之后，出队顺序必须是 1、2、3。
    var w = Wheel(8, 8).init();
    _ = try w.schedule(1, 2);
    _ = try w.schedule(2, 10);
    _ = try w.schedule(3, 18);
    w.advance(18);

    try testing.expectEqual(@as(u32, 3), w.pendingDue());
    try testing.expectEqual(@as(u32, 1), w.popDue().?.id);
    try testing.expectEqual(@as(u32, 2), w.popDue().?.id);
    try testing.expectEqual(@as(u32, 3), w.popDue().?.id);
    try testing.expect(w.popDue() == null);
}

test "wheel: 不同 delay 的事件按到期时间排序" {
    var w = Wheel(8, 8).init();
    _ = try w.schedule(10, 5);
    _ = try w.schedule(20, 1);
    _ = try w.schedule(30, 3);

    w.advance(1);
    try testing.expectEqual(@as(u32, 20), w.popDue().?.id);
    w.advance(2);
    try testing.expectEqual(@as(u32, 30), w.popDue().?.id);
    w.advance(2);
    try testing.expectEqual(@as(u32, 10), w.popDue().?.id);
}

test "wheel: 跨度大于槽数（17 > 8）也能准时到期，并记录放回次数" {
    var w = Wheel(8, 8).init();
    _ = try w.schedule(7, 17);

    w.advance(16);
    try testing.expect(w.popDue() == null);
    try testing.expect(w.stats.reinserted >= 2);

    w.advance(1);
    try testing.expectEqual(@as(u32, 7), w.popDue().?.id);
}

test "wheel: 同一槽内相同 deadline 的顺序是 LIFO（插入到桶头）" {
    var w = Wheel(8, 8).init();
    _ = try w.schedule(100, 4);
    _ = try w.schedule(200, 4);
    w.advance(4);

    // 这是实现细节而非语义承诺：文档写明“同槽内到期顺序不保证”，
    // 测试只钉住当前实现，防止无意改动掩盖回归。
    try testing.expectEqual(@as(u32, 200), w.popDue().?.id);
    try testing.expectEqual(@as(u32, 100), w.popDue().?.id);
}

test "wheel: cancel 之后不再到期，重复 cancel 返回 false" {
    var w = Wheel(8, 8).init();
    const h = try w.schedule(5, 4);
    try testing.expect(w.cancel(h));
    try testing.expect(!w.cancel(h));

    w.advance(8);
    try testing.expect(w.popDue() == null);
    try testing.expectEqual(@as(u32, 1), w.stats.cancelled);
}

test "wheel: 到期后旧句柄的 cancel 不会误杀复用槽位的新计时器" {
    var w = Wheel(4, 4).init();
    const old = try w.schedule(1, 1);
    w.advance(1);
    _ = w.popDue().?; // 旧条目已归还

    const fresh = try w.schedule(2, 2);
    try testing.expectEqual(old.index, fresh.index); // 槽位确实被复用了
    try testing.expect(!w.cancel(old)); // generation 不同 → 拒绝
    try testing.expectEqual(@as(usize, 1), w.activeCount());

    w.advance(2);
    try testing.expectEqual(@as(u32, 2), w.popDue().?.id);
}

test "wheel: 池耗尽返回 NoSpace，并计数" {
    var w = Wheel(2, 4).init();
    _ = try w.schedule(1, 5);
    _ = try w.schedule(2, 6);
    try testing.expectError(error.NoSpace, w.schedule(3, 7));
    try testing.expectEqual(@as(u32, 1), w.stats.exhausted);
}

test "wheel: delay=0 被拒绝（计时器必须至少跨一个 tick）" {
    var w = Wheel(2, 4).init();
    try testing.expectError(error.InvalidDelay, w.schedule(1, 0));
    try testing.expectEqual(@as(u32, 0), w.stats.scheduled);
}

test "wheel: 到期节点归还后可再次调度（长时间循环不泄漏）" {
    var w = Wheel(2, 8).init();
    var round: u32 = 0;
    while (round < 100) : (round += 1) {
        _ = try w.schedule(round, 1 + round % 5);
        // 每一轮推进足够的 tick，保证上一轮一定已经到期并被取走。
        w.advance(5);
        while (w.popDue()) |_| {}
    }
    try testing.expectEqual(@as(usize, 0), w.activeCount());
    try testing.expectEqual(@as(usize, 0), w.pendingDue());
}

test "wheel: nextDeadline 反映最早的到期 tick" {
    var w = Wheel(4, 8).init();
    try testing.expect(w.nextDeadline() == null);
    _ = try w.schedule(1, 6);
    _ = try w.schedule(2, 2);
    try testing.expectEqual(@as(u32, 2), w.nextDeadline().?);
    w.advance(2);
    try testing.expectEqual(@as(u32, 6), w.nextDeadline().?);
}

test "wheel: u32 回绕附近仍然准时（now 接近 0xffffffff）" {
    var w = Wheel(4, 8).init();
    w.now = 0xFFFF_FFFE;
    _ = try w.schedule(9, 4); // 到期于 0x00000002
    w.advance(3);
    try testing.expect(w.popDue() == null);
    w.advance(1);
    const d = w.popDue().?;
    try testing.expectEqual(@as(u32, 9), d.id);
    try testing.expectEqual(@as(u32, 2), d.at);
}
