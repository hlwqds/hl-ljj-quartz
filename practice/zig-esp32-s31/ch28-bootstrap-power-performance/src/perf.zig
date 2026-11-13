//! ch28：性能剖析的纯逻辑部分。
//!
//! 板侧用 SYSTIMER 读时间戳（ch08 已验证过读数路径），这里只负责把一串
//! 样本变成可解释的统计量：
//!   - 最小/最大/均值；
//!   - p50/p95（排序后取最近秩，不做插值）；
//!   - 吞吐与每字节周期；
//!   - CPU 频率切换后的折算（80/160/320 MHz 三档）。
//!
//! 注意：`p50`/`p95` 会原地排序样本，调用方要接受顺序被破坏；板侧自检
//! 传的是栈上副本，主机测试显式检查排序后的值。

const std = @import("std");

pub const Summary = struct {
    n: usize,
    min: u64,
    max: u64,
    mean: u64,
    p50: u64,
    p95: u64,
};

pub const Error = error{Empty};

/// 最近秩百分位：`ceil(p/100 * n)`，1-based，再转 0-based。
pub fn percentile(sorted: []const u64, p: u8) u64 {
    if (sorted.len == 0) return 0;
    if (p == 0) return sorted[0];
    const n: u64 = @intCast(sorted.len);
    var rank = (n * p + 99) / 100;
    if (rank == 0) rank = 1;
    if (rank > n) rank = n;
    return sorted[@intCast(rank - 1)];
}

/// 插入排序：样本数只有几十个，避免依赖 std.sort 的跨版本签名。
fn sortAsc(items: []u64) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const v = items[i];
        var j = i;
        while (j > 0 and items[j - 1] > v) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = v;
    }
}

pub const inf_f64: f64 = @bitCast(@as(u64, 0x7FF0000000000000));

/// 对 `samples` 原地升序排序后统计。空切片返回 `error.Empty`。
pub fn summarize(samples: []u64) Error!Summary {
    if (samples.len == 0) return error.Empty;
    sortAsc(samples);

    var sum: u128 = 0;
    for (samples) |s| sum += s;
    return .{
        .n = samples.len,
        .min = samples[0],
        .max = samples[samples.len - 1],
        .mean = @intCast(sum / samples.len),
        .p50 = percentile(samples, 50),
        .p95 = percentile(samples, 95),
    };
}

/// 吞吐：`bytes` / `ns` → MiB/s（1 MiB = 1<<20）。
pub fn mibPerSecond(bytes: u64, ns: u64) f64 {
    if (ns == 0) return inf_f64;
    const bytes_f: f64 = @floatFromInt(bytes);
    const ns_f: f64 = @floatFromInt(ns);
    return (bytes_f / (1024.0 * 1024.0)) / (ns_f / 1_000_000_000.0);
}

/// 每字节周期：`cycles` / `bytes`，保留 f64 供比较。
pub fn cyclesPerByte(cycles: u64, bytes: u64) f64 {
    if (bytes == 0) return inf_f64;
    const c: f64 = @floatFromInt(cycles);
    const b: f64 = @floatFromInt(bytes);
    return c / b;
}

/// 把在 `from_mhz` 下测得的周期数折算到 `to_mhz`。周期数与频率成正比，
/// 所以 80 MHz 下 1000 周期，在 320 MHz 下同一条代码约 4000 周期。
pub fn scaleCycles(cycles: u64, from_mhz: u32, to_mhz: u32) u64 {
    if (from_mhz == 0) return 0;
    return cycles * to_mhz / from_mhz;
}

/// 固定工作量下，提高频率只能缩短执行时间，不改变周期数；这个函数把
/// “时间”折算成新频率下的时间，用于和实测对比。
pub fn scaleNs(ns: u64, from_mhz: u32, to_mhz: u32) u64 {
    if (to_mhz == 0) return 0;
    return ns * from_mhz / to_mhz;
}

test "percentile uses nearest rank" {
    const s = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(u64, 5), percentile(&s, 50));
    try std.testing.expectEqual(@as(u64, 10), percentile(&s, 95));
    try std.testing.expectEqual(@as(u64, 1), percentile(&s, 0));
}

test "summarize sorts in place and reports min/max/mean" {
    var s = [_]u64{ 30, 10, 20 };
    const r = try summarize(&s);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 30 }, &s);
    try std.testing.expectEqual(@as(u64, 10), r.min);
    try std.testing.expectEqual(@as(u64, 30), r.max);
    try std.testing.expectEqual(@as(u64, 20), r.mean);
}

test "throughput and cycle scaling" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), mibPerSecond(1 << 20, 1_000_000_000), 0.0001);
    try std.testing.expectEqual(@as(u64, 4000), scaleCycles(1000, 80, 320));
    try std.testing.expectEqual(@as(u64, 250), scaleNs(1000, 80, 320));
}
