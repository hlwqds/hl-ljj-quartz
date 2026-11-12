//! ch15-observability-testing-stability：时间戳 trace 环形缓冲。
//!
//! 这个文件是**纯逻辑**：不碰寄存器、不打印、不分配。它同时被三处使用：
//!
//!   1. 真机：`g_ring` 记录启动自检、心跳、断言、watchdog、压测事件；
//!   2. panic dump：trap 处理函数把环形缓冲里最新的若干条打进串口；
//!   3. 主机侧单测：`zig build test` 在 x86_64 上验证覆盖/回绕/顺序。
//!
//! 设计取舍（为什么是“固定容量 + 覆盖最旧”而不是“写满即丢”）：
//!
//!   - 崩溃现场最有价值的是**最近**几十条，而不是最早那几条；
//!   - 覆盖策略只需要两个计数器（`pushed`、`dropped`），没有锁；
//!   - 容量是 2 的幂（32），索引用位掩码，编译器能消掉除法。
//!
//! 单生产者/单消费者时，`pushed` 是唯一需要保护的共享量；本章是单线程
//! （不开中断），所以连关中断都不需要。多核/中断场景下由调用方在临界区里
//! push——这一点写进 README，而不是假装它线程安全。

const std = @import("std");

/// 事件类别。`u8` 足够，且不改变 Record 的 24 字节布局。
pub const Tag = enum(u8) {
    boot,
    check_ok,
    check_fail,
    heartbeat,
    assert_caught,
    watchdog,
    stress,
    panic,
};

/// 一条 trace 记录：24 字节（u64 + tag u8 + 3 填充 + u32 + u32，按 8 对齐）。
pub const Record = extern struct {
    /// 相对启动时刻的微秒数（来自 TIMG0 T0，1 MHz）。
    t_us: u64,
    tag: Tag,
    /// 调用方自定义的两个 32 位载荷（序号、计数、校验和低 32 位……）。
    a: u32,
    b: u32,
};

/// 环形缓冲容量。必须是 2 的幂：索引用 `& (capacity - 1)`。
pub const capacity: u32 = 32;

comptime {
    if (@sizeOf(Record) != 24) @compileError("Record 必须是 24 字节");
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("capacity 必须是 2 的幂");
    }
}

/// 环形缓冲本体。默认值可零初始化，放在 .bss 里不占镜像空间。
pub const Ring = struct {
    recs: [capacity]Record = undefined,
    /// 历史累计 push 次数（不是当前条数）。回绕后仍单调递增。
    pushed: u64 = 0,
    /// 因为覆盖而丢掉的记录数：`pushed <= capacity` 时恒为 0。
    dropped: u64 = 0,

    pub fn reset(self: *Ring) void {
        self.pushed = 0;
        self.dropped = 0;
    }

    /// 追加一条。满了就覆盖最旧的一条，`dropped` 加一。
    pub fn push(self: *Ring, rec: Record) void {
        const idx: u32 = @intCast(self.pushed & (capacity - 1));
        if (self.pushed >= capacity) self.dropped += 1;
        self.recs[idx] = rec;
        self.pushed += 1;
    }

    /// 当前有效条数：`min(pushed, capacity)`。
    pub fn count(self: *const Ring) u32 {
        return @intCast(@min(self.pushed, @as(u64, capacity)));
    }

    /// 按时间顺序取第 i 条（0 = 最旧的一条）。越界返回 null。
    pub fn at(self: *const Ring, i: u32) ?Record {
        const n = self.count();
        if (i >= n) return null;
        const first = self.pushed - n; // 最旧一条的绝对序号
        const idx: u32 = @intCast((first + i) & (capacity - 1));
        return self.recs[idx];
    }

    /// 最新一条；空环返回 null。
    pub fn latest(self: *const Ring) ?Record {
        const n = self.count();
        if (n == 0) return null;
        return self.at(n - 1);
    }

    /// 最早与最新记录的时间差（µs）。少于两条时为 0。
    pub fn spanUs(self: *const Ring) u64 {
        const n = self.count();
        if (n < 2) return 0;
        const first = self.at(0).?.t_us;
        const last = self.at(n - 1).?.t_us;
        return last -| first;
    }
};

/// 真机侧唯一的环形缓冲。`_start` 会把 .bss 清零，这里不需要额外初始化。
pub var g_ring: Ring = .{};

/// 事件名（打印用；不参与逻辑）。
pub fn tagName(tag: Tag) []const u8 {
    return switch (tag) {
        .boot => "boot",
        .check_ok => "check_ok",
        .check_fail => "check_fail",
        .heartbeat => "hb",
        .assert_caught => "assert",
        .watchdog => "wdt",
        .stress => "stress",
        .panic => "panic",
    };
}

/// 把一条记录格式化成人类可读文本。缓冲不足时返回 "<trace>"。
/// 只用 `std.fmt`，主机侧单测可以逐字比对。
pub fn formatRecord(rec: Record, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "trace: t={d}us tag={s} a=0x{x} b={d}", .{
        rec.t_us,
        tagName(rec.tag),
        rec.a,
        rec.b,
    }) catch "<trace>";
}

// ---------------------------------------------------------------------------
// 主机侧单测（`zig build test`）。这些 test 不看硬件，只验证环形语义。
// ---------------------------------------------------------------------------

test "empty ring has no latest record and zero span" {
    var ring = Ring{};
    try std.testing.expectEqual(@as(u32, 0), ring.count());
    try std.testing.expect(ring.latest() == null);
    try std.testing.expect(ring.at(0) == null);
    try std.testing.expectEqual(@as(u64, 0), ring.spanUs());
}

test "push preserves order below capacity" {
    var ring = Ring{};
    var i: u32 = 0;
    while (i < capacity - 1) : (i += 1) {
        ring.push(.{ .t_us = i * 1000, .tag = .heartbeat, .a = i, .b = 0 });
    }
    try std.testing.expectEqual(capacity - 1, ring.count());
    try std.testing.expectEqual(@as(u64, 0), ring.dropped);
    try std.testing.expectEqual(@as(u32, 0), ring.at(0).?.a);
    try std.testing.expectEqual(@as(u32, 2), ring.at(2).?.a);
    try std.testing.expectEqual(@as(u32, capacity - 2), ring.latest().?.a);
    try std.testing.expectEqual((capacity - 2) * 1000, ring.spanUs());
}

test "overflow overwrites the oldest and counts drops" {
    var ring = Ring{};
    const total: u32 = capacity + 8;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        ring.push(.{ .t_us = i, .tag = .stress, .a = i, .b = 0 });
    }
    try std.testing.expectEqual(capacity, ring.count());
    try std.testing.expectEqual(@as(u64, 8), ring.dropped);
    try std.testing.expectEqual(@as(u32, 8), ring.at(0).?.a);
    try std.testing.expectEqual(total - 1, ring.latest().?.a);
    try std.testing.expectEqual((total - 1) - 8, ring.spanUs());
}

test "records stay 24 bytes and tags round-trip" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Record));
    const rec = Record{ .t_us = 123, .tag = .assert_caught, .a = 0xdead, .b = 7 };
    var buf: [96]u8 = undefined;
    const text = formatRecord(rec, &buf);
    try std.testing.expectEqualStrings("trace: t=123us tag=assert a=0xdead b=7", text);
}

test "reset forgets history" {
    var ring = Ring{};
    var i: u32 = 0;
    while (i < 5) : (i += 1) ring.push(.{ .t_us = i, .tag = .boot, .a = i, .b = 0 });
    ring.reset();
    try std.testing.expectEqual(@as(u32, 0), ring.count());
    try std.testing.expect(ring.latest() == null);
}
