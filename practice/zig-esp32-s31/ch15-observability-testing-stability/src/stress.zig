//! ch15-observability-testing-stability：可选的 30 s 压测。
//!
//! 压测的目的不是“跑满 30 秒”，而是**在持续负载下检查观测链本身**：
//!
//!   1. 时间基还准吗（每 1 s 的绝对时刻报告，不靠累计误差）？
//!   2. trace 环还会覆盖吗（`dropped` 必须单调递增，不能卡住）？
//!   3. 有没有单次循环卡顿（`chunk_gap` 的最大值）？
//!   4. 计算是否可复现（LCG 的校验和是确定性的，复位后必须一样）？
//!
//! 轮询式忙等 + 纯整数运算，不分配、不阻塞、不开中断。这样“压测不动点”
//! 只剩 CPU 与时间基，出了异常就能直接归因到这两者之一。
//!
//! 通过构建选项开启（默认关闭，避免演示流程被 30 s 占据）：
//!   zig build ... -Dstress=true

const hw = @import("hw.zig");
const log = @import("log.zig");
const trace = @import("trace.zig");

/// 单次内循环的迭代数。4096 次整数运算约几毫秒，足以让每个 chunk 都可观测。
const chunk_iters: u32 = 4096;

/// 一秒钟一个报告点。用绝对时刻（`start + k * 1s`）而不是“上次 + 1s”，
/// 迟到的 chunk 不会把漂移积分下去。
const report_period_us: u64 = 1_000_000;

/// chunk 间隔超过这个值就认为发生了卡顿（2 ms，两倍报告周期）。
pub const stall_threshold_us: u64 = 2000;

pub fn run(seconds: u32) void {
    const duration_us: u64 = @as(u64, seconds) * report_period_us;
    const t_start = hw.nowUs();
    const deadline = t_start + duration_us;

    log.line("stress: begin duration={d}s budget={d}us chunk={d} iters", .{
        seconds, duration_us, chunk_iters,
    });
    trace.g_ring.push(.{
        .t_us = hw.nowUs(),
        .tag = .stress,
        .a = 0,
        .b = seconds,
    });

    // 确定性 LCG：同一次构建、同一块板子，checksum 必须逐位一致。
    var checksum: u32 = 0x1357_9BDF;
    var iterations: u64 = 0;
    var max_gap: u64 = 0;
    var next_report = t_start + report_period_us;
    var seq: u32 = 0;

    while (true) {
        const chunk_start = hw.nowUs();
        if (chunk_start >= deadline) break;

        var i: u32 = 0;
        while (i < chunk_iters) : (i += 1) {
            checksum = checksum *% 1664525 +% 1013904223;
            checksum ^= checksum >> 13;
            checksum *%= 2654435761;
        }
        iterations += chunk_iters;

        const chunk_end = hw.nowUs();
        const gap = chunk_end -| chunk_start;
        if (gap > max_gap) max_gap = gap;

        if (chunk_end >= next_report) {
            while (next_report <= chunk_end) next_report += report_period_us;
            seq += 1;
            const elapsed = chunk_end -| t_start;
            log.line("stress: t={d}ms iters={d} sum=0x{x} chunk={d}us dropped={d}", .{
                elapsed / 1000, iterations, checksum, gap, trace.g_ring.dropped,
            });
            trace.g_ring.push(.{
                .t_us = elapsed,
                .tag = .stress,
                .a = seq,
                .b = @truncate(iterations),
            });
        }
    }

    const elapsed = hw.nowUs() -| t_start;
    log.line("stress: end elapsed={d}ms iters={d} sum=0x{x} reports={d}", .{
        elapsed / 1000, iterations, checksum, seq,
    });
    log.line("stress: gap max={d}us threshold={d}us verdict={s}", .{
        max_gap,
        stall_threshold_us,
        if (max_gap <= stall_threshold_us) "pass" else "fail",
    });
    trace.g_ring.push(.{
        .t_us = elapsed,
        .tag = .stress,
        .a = @truncate(iterations),
        .b = @truncate(max_gap),
    });
}
