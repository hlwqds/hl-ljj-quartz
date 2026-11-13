//! ch28：主机侧单测入口。
//!
//! `zig build test` 只跑这个根，不引用 `start.zig`/`hw.zig`/`trap.zig`/
//! `main.zig`/`selftest.zig`，因此不需要开发板。四个模块全部是纯逻辑：
//! `bootslot.zig`、`power.zig`、`perf.zig`、复用 ch24 的 `ota.zig`。
//!
//! 本章不验证真实 flash 布局、真实睡眠电流或真实 CPU 频率；这些必须在
//! 28.9 的真机清单里用电流表/示波器/`esp_sleep_get_wakeup_cause()` 取证。

test {
    _ = @import("bootslot.zig");
    _ = @import("power.zig");
    _ = @import("perf.zig");
    _ = @import("ota.zig");
}

const std = @import("std");
const testing = std.testing;

const bootslot = @import("bootslot.zig");
const ota = @import("ota.zig");
const power = @import("power.zig");

test "decide prefers a valid otadata winner" {
    var a: [bootslot.entry_len]u8 = undefined;
    var b: [bootslot.entry_len]u8 = undefined;
    _ = try bootslot.encodeEntry(&a, .{ .seq = 1, .slot = .a, .state = .valid });
    _ = try bootslot.encodeEntry(&b, .{ .seq = 2, .slot = .b, .state = .pending_verify });
    const d = bootslot.decide(&a, &b);
    try testing.expectEqual(ota.Slot.b, d.slot.?);
    try testing.expect(d.reason == .otadata);
}

test "decide falls back to factory when both sectors are erased" {
    const erased: [bootslot.entry_len]u8 = @splat(0xFF);
    const d = bootslot.decide(&erased, &erased);
    try testing.expectEqual(@as(?ota.Slot, null), d.slot);
    try testing.expect(d.reason == .factory_fallback);
}

test "bootable admits only valid and pending_verify" {
    try testing.expect(bootslot.bootable(.valid));
    try testing.expect(bootslot.bootable(.pending_verify));
    try testing.expect(!bootslot.bootable(.new));
    try testing.expect(!bootslot.bootable(.invalid));
    try testing.expect(!bootslot.bootable(.aborted));
    try testing.expect(!bootslot.bootable(.undefined_));
}

test "battery life is capacity over average current" {
    try testing.expectApproxEqAbs(@as(f32, 100.0), power.batteryHours(20.0, 2000.0), 0.001);
    try testing.expect(power.batteryHours(0.0, 2000.0) == @as(f32, @bitCast(@as(u32, 0x7F800000))));
}

test "duty cycle average never exceeds run current" {
    const m = power.Model{};
    inline for ([_]power.Mode{ .light_sleep, .deep_sleep }) |mode| {
        inline for ([_]u64{ 1_000, 1_000_000, 60_000_000 }) |us| {
            try testing.expect(power.dutyAverageMa(m, mode, us) <= m.run_ma);
        }
    }
}
