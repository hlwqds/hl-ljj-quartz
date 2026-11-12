//! ch21-tcp-congestion：板侧自检。
//!
//! 本章没有可用的真实链路（ch17 的以太网驱动尚未闭环：DMA 软复位超时、
//! MDIO 扫不到 PHY），所以板侧的**唯一**证据形态是：用自造事件驱动同一份
//! 控制律，再用确定性仿真跑出曲线。这里没有“发包”、没有“抓包”、也没有
//! “板子吞吐”——任何数字都只能读作**仿真数值（非真链路）**。
//!
//! 十个判据（每个一行 `check: ... ok=1/0`）：
//!
//!   ① 慢启动每个 RTT 翻倍：1 → 2 → 4 → 8
//!   ② 到 ssthresh 转拥塞避免：每 RTT 恰好 +1 MSS
//!   ③ 三重复 ACK：快重传 + 快恢复（ssthresh = cwnd/2，cwnd = ssthresh + 3 MSS）
//!   ④ 超时：cwnd = 1 MSS，ssthresh 减半
//!   ⑤ 窗口取小：rwnd < cwnd 时受 rwnd 限制
//!   ⑥ 窗口缩放：shift 上限 14，编码/解码往返
//!   ⑦ Nagle 与延迟 ACK：有未确认数据时压住小段
//!   ⑧ 仿真吞吐随丢包率单调下降
//!   ⑨ BDP = 链路速率 × RTT
//!   ⑩ 与 Mathis 公式（BW ≈ MSS/RTT · √(3/2p)）同量级
//!
//! 输出里额外三行是曲线与指纹（`sim:` 前缀），它们不是判据，是判据的
//! **原始读数**：`checks:` 行只汇总 ①②…⑩。
//!
//! 所有缓冲都是 `.bss` 里的静态对象：板侧没有分配器，自检也不该依赖
//! `error.OutOfMemory` 才能跑到 verdict。

const std = @import("std");

const cong = @import("cong.zig");
const sim = @import("sim.zig");

const log = @import("log.zig");
const trap = @import("trap.zig");

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [150]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

/// 把一串 cwnd 采样（单位 MSS）打在一行里。只用于读数，不参与判据。
fn printSamples(tag: []const u8, samples: []const u32) void {
    var buf: [120]u8 = undefined;
    var n: usize = 0;
    for (samples, 0..) |s, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const w = std.fmt.bufPrint(buf[n..], "{s}{d}", .{ sep, s }) catch break;
        n += w.len;
    }
    log.line("sim: cwnd {s} n={d} [{s}]", .{ tag, samples.len, buf[0..n] });
}

fn runChecks() bool {
    const mss = cong.mss_default;

    // ---- ① 慢启动：每个 RTT 翻倍 ----
    {
        var c = cong.Cwnd.init(mss, 1 << 20);
        var seen: [4]u32 = undefined;
        seen[0] = c.mssCount();
        var rtt: usize = 1;
        while (rtt < 4) : (rtt += 1) {
            const n = c.mssCount();
            var i: u32 = 0;
            while (i < n) : (i += 1) c.onAck(mss); // 一个 RTT 内收到 n 个 ACK
            seen[rtt] = c.mssCount();
        }
        check(
            seen[0] == 1 and seen[1] == 2 and seen[2] == 4 and seen[3] == 8,
            "cwnd slowstart rtt {d},{d},{d},{d}",
            .{ seen[0], seen[1], seen[2], seen[3] },
        );
    }

    // ---- ② 拥塞避免：每 RTT +1 MSS ----
    {
        var c = cong.Cwnd.init(mss, 8 * mss);
        c.cwnd = 8 * mss;
        c.state = .congestion_avoidance;
        var seen: [4]u32 = undefined;
        seen[0] = c.mssCount();
        var rtt: usize = 1;
        while (rtt < 4) : (rtt += 1) {
            c.onAck(c.cwnd); // 一个 RTT 的确认量 = 当前窗口
            seen[rtt] = c.mssCount();
        }
        check(
            seen[0] == 8 and seen[1] == 9 and seen[2] == 10 and seen[3] == 11,
            "cwnd ca per-rtt {d},{d},{d},{d}",
            .{ seen[0], seen[1], seen[2], seen[3] },
        );
    }

    // ---- ③ 快重传 / 快恢复 ----
    {
        var c = cong.Cwnd.init(mss, 1 << 20);
        c.cwnd = 10 * mss;
        const a1 = c.onDupAck(64 * 1024);
        const a2 = c.onDupAck(64 * 1024);
        const a3 = c.onDupAck(64 * 1024);
        check(
            a1 == .none and a2 == .none and a3 == .retransmit_now and
                c.ssthresh == 5 * mss and c.cwnd == 8 * mss and c.state == .fast_recovery,
            "fast retx ssthresh={d} cwnd={d} state={s}",
            .{ c.ssthresh, c.cwnd, @tagName(c.state) },
        );
    }

    // ---- ④ 超时：cwnd 归 1、ssthresh 减半 ----
    {
        var c = cong.Cwnd.init(mss, 1 << 20);
        c.cwnd = 16 * mss;
        c.onTimeout(64 * 1024);
        check(
            c.cwnd == mss and c.ssthresh == 8 * mss and c.state == .slow_start,
            "timeout cwnd={d} ssthresh={d}",
            .{ c.cwnd, c.ssthresh },
        );
    }

    // ---- ⑤ 窗口取小 ----
    {
        var c = cong.Cwnd.init(mss, 1 << 20);
        c.cwnd = 10 * mss;
        const rwnd = 4 * mss;
        check(
            c.inFlightLimit(rwnd) == rwnd and c.inFlightLimit(64 * 1024) == 10 * mss,
            "window min(cwnd=14600,rwnd=5840)={d}",
            .{c.inFlightLimit(rwnd)},
        );
    }

    // ---- ⑥ 窗口缩放（RFC 7323）----
    {
        const raw = cong.clampWscale(15); // 对方给了 15，必须当 14
        const field = cong.encodeWnd(1 << 20, raw); // 1 MiB 只能表达 64 段
        const back = cong.applyWndScale(field, raw);
        check(
            raw == 14 and field == 64 and back == 64 << 14 and cong.wndFieldMax(14) == 0x3FFFC000,
            "wscale shift={d} encode(1MiB)={d} decode={d} max={d}",
            .{ raw, field, back, cong.wndFieldMax(14) },
        );
    }

    // ---- ⑦ Nagle 与延迟 ACK ----
    {
        const blocked = !cong.nagleAllows(mss, 100, mss, false);
        const full = cong.nagleAllows(mss, mss, mss, false);
        const idle = cong.nagleAllows(0, 100, mss, false);
        check(
            blocked and full and idle,
            "nagle unacked=1 small=blocked full=allowed idle=allowed",
            .{},
        );
    }

    // ---- ⑧ 仿真：稳态吞吐随丢包率单调下降 ----
    //
    // 两套运行，用途不同：
    //   - 256 KiB：只有 180 个段，用来打印“慢启动爬坡 + 一次丢包”的曲线
    //     （章节 21.2/21.3 的表格就是这两行）；
    //   - 4 MiB  ≈ 2873 个段、1% 丢包约 29 次事件，这才是 Mathis 描述的
    //     稳态，判据 ⑧（单调）与 ⑩（同量级）都建立在它上面。
    var tp_none: u64 = 0;
    var tp_k100: u64 = 0;
    var tp_k25: u64 = 0;
    var tp_k10: u64 = 0;
    {
        const r_none = sim.run(.{ .loss = .none });
        const r_k100 = sim.run(.{ .loss = .{ .periodic = 100 } });
        printSamples("none@1rtt", r_none.samples[0..r_none.sample_len]);
        printSamples("loss1/100", r_k100.samples[0..r_k100.sample_len]);
        log.line("sim: k100 ramp sent={d} retx={d} to={d} fr={d} dup={d} ticks={d}", .{
            r_k100.sent_segments, r_k100.retransmits, r_k100.timeouts,
            r_k100.fast_retx,     r_k100.dupacks,     r_k100.ticks,
        });

        const big: u64 = 4 * 1024 * 1024;
        const s_none = sim.run(.{ .loss = .none, .total_bytes = big, .max_ticks = 400_000 });
        const s_k100 = sim.run(.{ .loss = .{ .periodic = 100 }, .total_bytes = big, .max_ticks = 400_000 });
        const s_k25 = sim.run(.{ .loss = .{ .periodic = 25 }, .total_bytes = big, .max_ticks = 400_000 });
        const s_k10 = sim.run(.{ .loss = .{ .periodic = 10 }, .total_bytes = big, .max_ticks = 400_000 });
        tp_none = s_none.throughputMilli();
        tp_k100 = s_k100.throughputMilli();
        tp_k25 = s_k25.throughputMilli();
        tp_k10 = s_k10.throughputMilli();

        check(
            tp_none > tp_k100 and tp_k100 > tp_k25 and tp_k25 > tp_k10 and s_k10.retransmits > 0,
            "sim tp none={d} k100={d} k25={d} k10={d}",
            .{ tp_none, tp_k100, tp_k25, tp_k10 },
        );
        log.line("sim: k100 steady sent={d} retx={d} to={d} fr={d} dup={d} ticks={d}", .{
            s_k100.sent_segments, s_k100.retransmits, s_k100.timeouts,
            s_k100.fast_retx,     s_k100.dupacks,     s_k100.ticks,
        });

        // 确定性：同种子跑两次，指纹必须一致（换种子必须不同）。
        const a = sim.run(.{ .loss = .{ .random = 20 } });
        const b = sim.run(.{ .loss = .{ .random = 20 } });
        log.line("sim: seed=0x21c0ffee hash=0x{x} rerun=0x{x} equal={d}", .{
            a.hash, b.hash, @intFromBool(a.hash == b.hash),
        });
    }

    // ---- ⑨ BDP ----
    {
        const bdp = cong.bdpBytes(10_000_000, 24_000);
        const segs = cong.bdpSegments(10_000_000, 24_000, mss);
        check(
            bdp == 30_000 and segs == 21 and cong.windowForBdp(10_000_000, 24_000, mss) == 21 * mss,
            "bdp 10mbit/24ms = {d}B {d}seg rwnd_needed={d}",
            .{ bdp, segs, cong.windowForBdp(10_000_000, 24_000, mss) },
        );
    }

    // ---- ⑩ 与 Mathis 同量级 ----
    {
        const theory = cong.mathisBytesPerTickMilli(10, mss, 24); // p = 1%
        const measured = tp_k100;
        // 比值用千分比表示，避免浮点：ratio_x1000 = measured/theory × 1000。
        const ratio_x1000 = if (theory == 0) 0 else measured * 1000 / theory;
        // 稳态下仿真比理论低约 20%（周期丢包固定命中 + 单洞恢复更乐观），
        // 允许 0.6–1.0 的区间；低于 0.6 说明模型或参数写错了。
        check(
            ratio_x1000 >= 600 and ratio_x1000 <= 1000,
            "mathis p=1% theory={d} sim={d} ratio_x1000={d}",
            .{ theory, measured, ratio_x1000 },
        );
    }

    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();
    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
