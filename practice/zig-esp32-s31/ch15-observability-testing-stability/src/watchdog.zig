//! ch15-observability-testing-stability：软件 watchdog（纯逻辑，可主机侧测）。
//!
//! 这里的 watchdog 不是 RTC WDT / MWDT，而是**应用层的心跳截止时间**：
//! 主循环（或调度器 idle）每次转一圈就 `feed()`，任何一次“该喂没喂”都表示
//! 某个环节卡住了。它补的是硬件 watchdog 补不到的那一层：
//!
//!   - RTC WDT 只看“有没有写 FEED 寄存器”，喂狗可以发生在错误的循环里；
//!   - 软件 watchdog 绑定的是**业务进度**（一个完整的观测周期），
//!     能区分“在跑但没进展”和“真的卡死”。
//!
//! 真正的“停机”动作由调用方决定：本章演示里只打印并继续（可恢复路径），
//! 在 `main.zig` 的注释里说明生产环境应换成 `trap.panic`。
//!
//! 时间基是单调的 64 位微秒（`hw.nowUs`），用饱和减法 `-|` 处理回绕/乱序，
//! 保证 `expired()` 不会因为时钟跳变而误报“永远超时”。

const std = @import("std");

pub const Watchdog = struct {
    /// 允许的最长间隔（µs）。
    deadline_us: u64,
    /// 最近一次喂狗的时刻（µs）。
    last_feed_us: u64,
    /// 历史超时次数。生产环境用它做“重启前诊断”，演示里只打印。
    trips: u32 = 0,

    pub fn init(deadline_us: u64) Watchdog {
        return .{ .deadline_us = deadline_us, .last_feed_us = 0 };
    }

    pub fn feed(self: *Watchdog, now_us: u64) void {
        self.last_feed_us = now_us;
    }

    /// 距上次喂狗过去了多久（饱和到 0）。
    pub fn elapsed(self: *const Watchdog, now_us: u64) u64 {
        return now_us -| self.last_feed_us;
    }

    /// 超过 deadline 才算超时；恰好等于 deadline 不算（边界语义写进测试）。
    pub fn expired(self: *const Watchdog, now_us: u64) bool {
        if (self.elapsed(now_us) > self.deadline_us) {
            return true;
        }
        return false;
    }

    /// 超时则计数并重新喂狗，返回是否真的发生过超时。
    /// 调用方负责在返回 true 时打印现场；这里不做 I/O，保持可测试。
    pub fn checkAndRecover(self: *Watchdog, now_us: u64) bool {
        if (!self.expired(now_us)) return false;
        self.trips += 1;
        self.feed(now_us);
        return true;
    }
};

test "not expired before and at the deadline" {
    var wd = Watchdog.init(1000);
    wd.feed(5000);
    try std.testing.expect(!wd.expired(5000));
    try std.testing.expect(!wd.expired(5999));
    try std.testing.expect(!wd.expired(6000)); // 恰好等于 deadline：不算超时
}

test "expired one microsecond past the deadline" {
    var wd = Watchdog.init(1000);
    wd.feed(5000);
    try std.testing.expect(wd.expired(6001));
    try std.testing.expectEqual(@as(u64, 1001), wd.elapsed(6001));
}

test "feed resets the window and checkAndRecover counts trips" {
    var wd = Watchdog.init(100);
    wd.feed(0);
    try std.testing.expect(!wd.checkAndRecover(100));
    try std.testing.expectEqual(@as(u32, 0), wd.trips);
    try std.testing.expect(wd.checkAndRecover(150));
    try std.testing.expectEqual(@as(u32, 1), wd.trips);
    try std.testing.expectEqual(@as(u64, 150), wd.last_feed_us);
    try std.testing.expect(!wd.expired(200));
}

test "clock going backwards does not report a trip" {
    var wd = Watchdog.init(100);
    wd.feed(10_000);
    try std.testing.expectEqual(@as(u64, 0), wd.elapsed(9_000));
    try std.testing.expect(!wd.expired(9_000));
}
