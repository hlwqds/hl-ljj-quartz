//! ch28：功耗预算模型。
//!
//! 目标不是“猜出 S31 的真实电流”，而是把**睡眠决策**变成可复算的算术：
//! RTC 计数器多少位、慢时钟多少 Hz、一次唤醒要花多少 µs、给定电池容量
//! 能撑多久。真实电流必须用板上的电流表测，本章的 mA 数值全部标成
//! `model_*`，只用于比较 light/deep 两种策略的相对量级。
//!
//! 真机入口（待 ch17/ch28 真机验证）：
//!   - `esp_sleep_enable_timer_wakeup(us)` 设 RTC timer；
//!   - `esp_light_sleep_start()` / `esp_deep_sleep_start()`；
//!   - 醒来后读 `esp_sleep_get_wakeup_cause()`。
//! 本章只建模，不调用任何 IDF 函数，也不写 RTC 寄存器。

const std = @import("std");

pub const Mode = enum { run, light_sleep, deep_sleep };

pub const Model = struct {
    /// 3.3 V 供电下的典型电流（mA）。全部是**模型值**，不是实测值。
    run_ma: f32 = 25.0,
    light_ma: f32 = 1.2,
    deep_ma: f32 = 0.01,
    /// 唤醒到第一条指令的固定开销（µs）。deep 要重新走 bootloader，
    /// 所以远大于 light；数值按“量级”给，真机要测。
    light_wake_us: u32 = 80,
    deep_wake_us: u32 = 12_000,
    /// RTC 慢时钟频率；S31 的 RC_SLOW 标称 136 kHz。
    rtc_hz: u32 = 136_000,
};

pub const Budget = struct {
    mode: Mode,
    sleep_us: u64,
    wake_us: u32,
    total_us: u64,
    avg_ma: f32,
};

/// 给定模式与睡眠时长，算总时长、平均电流与电荷量。
pub fn budget(m: Model, mode: Mode, sleep_us: u64) Budget {
    const wake: u32 = switch (mode) {
        .run => 0,
        .light_sleep => m.light_wake_us,
        .deep_sleep => m.deep_wake_us,
    };
    const sleep_ma: f32 = switch (mode) {
        .run => m.run_ma,
        .light_sleep => m.light_ma,
        .deep_sleep => m.deep_ma,
    };
    const total = sleep_us + wake;
    const awake_us: f32 = @floatFromInt(wake);
    const asleep_us: f32 = @floatFromInt(sleep_us);
    const total_f: f32 = @floatFromInt(total);
    const avg = if (total == 0) sleep_ma else (sleep_ma * asleep_us + m.run_ma * awake_us) / total_f;
    return .{ .mode = mode, .sleep_us = sleep_us, .wake_us = wake, .total_us = total, .avg_ma = avg };
}

/// RTC 计数器是 32 位（S31 的 `esp_sleep` 用 64 位 µs 预算，但硬件比较器
/// 最终落在一个 32 位周期计数上）；返回单次可睡的最大微秒数。
pub fn maxSleepUs(rtc_hz: u32) u64 {
    const cycles: u64 = std.math.maxInt(u32);
    return cycles * 1_000_000 / rtc_hz;
}

/// 电池寿命（小时），按平均电流与容量计算；不含升压/降压损耗。
pub fn batteryHours(avg_ma: f32, capacity_mah: f32) f32 {
    if (avg_ma <= 0) return @bitCast(@as(u32, 0x7F800000));
    return capacity_mah / avg_ma;
}

/// 周期唤醒的平均电流：睡 `sleep_us`、醒 `wake_us`、醒着按 run 电流算。
pub fn dutyAverageMa(m: Model, mode: Mode, sleep_us: u64) f32 {
    return budget(m, mode, sleep_us).avg_ma;
}

test "deep sleep max us at 136 kHz is about 8.8 hours" {
    const us = maxSleepUs(136_000);
    try std.testing.expect(us > 31_500_000_000);
    try std.testing.expect(us < 31_600_000_000);
}

test "deep sleep average current is dominated by wake overhead at short periods" {
    const m = Model{};
    const short = dutyAverageMa(m, .deep_sleep, 1_000_000); // 1 s sleep, 12 ms wake
    const long = dutyAverageMa(m, .deep_sleep, 60_000_000); // 60 s sleep
    try std.testing.expect(short > long);
    try std.testing.expect(long < 0.1);
}
