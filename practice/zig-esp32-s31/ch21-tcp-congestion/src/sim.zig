//! ch21-tcp-congestion：**无网络**的确定性丢包仿真器。
//!
//! 这不是协议栈，也不是抓包器。它只回答一个问题：给定一条固定链路
//! （带宽、单程时延、丢包模式、接收窗口），把 `cong.Cwnd` 接上去，
//! 拥塞窗口曲线和有效吞吐会长成什么样。
//!
//! 模型是“单发送端、单接收端、无交叉流量”的教科书链路：
//!
//!   - 时间以 **1 ms tick** 为单位，`tick` 递增驱动一切（无事件堆，可复现）；
//!   - 发送端每 tick 最多灌 `link_bytes_per_tick` 字节（链路速率，串行化）；
//!   - 每个发出的段在 `2 × one_way_ticks` 后“到达”；
//!   - 接收端累积确认：**丢了中间一段时，后续段到达也只是重复 ACK**，
//!     这正是快重传的触发条件；
//!   - 三个重复 ACK → 按 `cong.Cwnd.onDupAck` 的裁决重传队首；
//!   - `rto_ticks` 内没有新确认 → 按 `onTimeout` 收缩窗口，并**丢弃全部在途
//!     段**（go-back-N 式简化；真实栈只重传队首，所以本仿真的超时恢复比
//!     真实实现更悲观——这一点在 21.7 的对照里会体现为“仿真吞吐略低于
//!     Mathis 理论值”）。
//!
//! 丢包两种模式，都是**确定性**的：
//!
//!   - `.periodic(k)`：每第 k 个发出的段丢掉。用它做“吞吐随丢包率单调下降”
//!     的判据：k 越小丢得越狠，而结果不依赖任何随机数；
//!   - `.random(permille)`：自带 xorshift32，种子固定。用它做“同种子两次
//!     结果逐字节一致”的判据。**不**用它做单调性判据——有限样本里随机数
//!     本来就会破单调。
//!
//! 换言之：本文件里出现的每一个字节数、每一条曲线，都只能标注为
//! **仿真数值（非真链路）**；真实链路上的吞吐要等 ch17 的以太网驱动闭环后
//! 才能测，本章不代填。

const std = @import("std");
const cong = @import("cong.zig");

/// 输入参数。默认值就是自检与章节里用的那组：10 Mbit/s、24 ms RTT。
pub const Params = struct {
    /// 字节。段大小（MSS）。
    mss: u32 = cong.mss_default,
    /// 字节/tick。链路速率：1250 B/ms = 10 Mbit/s。
    link_bytes_per_tick: u32 = 1250,
    /// tick（1 ms）。单程时延；RTT = 2 × 它。
    one_way_ticks: u32 = 12,
    /// 字节。接收端通告的窗口（不含缩放）。64 KiB 是 wscale=0 的上界。
    rwnd_bytes: u32 = 64 * 1024,
    /// tick。超时门限。24 ms RTT 的 8 倍左右，留出抖动余量。
    rto_ticks: u32 = 200,
    /// 字节。初始 ssthresh；给一个“能看出慢启动结束点”的值。
    initial_ssthresh: u32 = 32 * 1024,
    /// 字节。要传完的总量。
    total_bytes: u64 = 256 * 1024,
    /// tick。跑不完就停（把死循环变成可判读的截断）。
    max_ticks: u32 = 60_000,
    /// 丢包模式。
    loss: LossMode = .none,
    /// `.random` 的种子。
    seed: u32 = 0x21C0_FFEE,
    /// tick。cwnd 采样间隔；0 表示“每个 RTT 采一次”。
    sample_every: u32 = 0,
};

pub const LossMode = union(enum) {
    /// 不丢包。
    none,
    /// 每第 k 个发出的段丢一个（含重传；k=0 等同 none）。
    periodic: u32,
    /// 千分比随机丢包。
    random: u32,
};

/// 采样上限（结果结构里的静态数组容量）。
pub const sample_cap = 64;

/// 一次仿真的完整结果。所有字段都是整数，方便板上用 `{d}` 打印。
pub const Result = struct {
    /// 每 `sample_every` tick 采一个 cwnd（单位：MSS，整数）。
    samples: [sample_cap]u32 = @splat(0),
    sample_len: usize = 0,
    /// 发出的段总数（含重传）。
    sent_segments: u32 = 0,
    /// 重传次数（快重传 + 超时重传）。
    retransmits: u32 = 0,
    /// 被接收端按序确认的字节数。
    acked_bytes: u64 = 0,
    /// 用掉的 tick 数。
    ticks: u32 = 0,
    /// 收到的重复 ACK 总数。
    dupacks: u32 = 0,
    /// 快重传触发次数。
    fast_retx: u32 = 0,
    /// 超时次数。
    timeouts: u32 = 0,
    /// 曲线指纹：对采样与计数器做 FNV-1a。同种子两次必须相同。
    hash: u64 = 0,
    /// 是否传完了（false 表示被 max_ticks 截断）。
    completed: bool = false,

    /// 有效吞吐：字节/tick，保留 3 位小数（毫单位）。
    pub fn throughputMilli(self: Result) u64 {
        if (self.ticks == 0) return 0;
        return self.acked_bytes * 1000 / self.ticks;
    }

    /// 丢包率（千分比），按“重传段 / 发出段”粗算——这是发送端能看到的量，
    /// 也是 Mathis 公式里 p 的可测代理。
    pub fn lossPermille(self: Result) u32 {
        if (self.sent_segments == 0) return 0;
        return self.retransmits * 1000 / self.sent_segments;
    }

    pub fn hashOf(self: Result) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (self.samples[0..self.sample_len]) |s| h = fnv(h, s);
        inline for (.{ self.sent_segments, self.retransmits, self.ticks, self.dupacks, self.fast_retx, self.timeouts }) |f| {
            h = fnv(h, f);
        }
        h = fnv(h, @as(u32, @truncate(self.acked_bytes)));
        return h;
    }
};

fn fnv(h_in: u64, v: u32) u64 {
    var h = h_in;
    var i: u5 = 0;
    while (i < 4) : (i += 1) {
        const byte: u8 = @truncate(v >> (8 * @as(u5, i)));
        h ^= byte;
        h *%= 0x100000001b3;
    }
    return h;
}

/// xorshift32：自己写而不是用 `std.Random.DefaultPrng`，是为了让“同种子同结果”
/// 只依赖这 6 行，而不是依赖标准库版本。
const Rng = struct {
    state: u32,

    fn next(self: *Rng) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    fn permille(self: *Rng) u32 {
        return self.next() % 1000;
    }
};

/// 在途段（按发出顺序排队，同一个 RTT 内 `at` 单调不减）。
const Seg = struct {
    /// 起始序号（字节）。
    seq: u64,
    /// 段长（字节）。尾段可能短于 MSS。
    len: u32,
    /// 预计到达发送端的 tick。
    at: u32,
    /// 这一段在路上丢了：到达事件里不产生 ACK。
    dropped: bool,
};

// ---------------------------------------------------------------------------
// 静态缓冲：仿真器的全部工作内存都在 .bss，不进栈。
//
// 这不是风格问题：主栈只有 16 KiB（见 linker/s31.ld 的 _stack_size），
// 一个 512 段的队列就是 12 KiB，`run()` 加上 main/selftest 的帧立刻越过
// 栈顶——表现是 trap 而不是“结果不对”。两块缓冲提到文件作用域之后，
// `run()` 的栈帧只剩几十字节，与本章“静态缓冲无堆”的口径一致。
const queue_cap = 128; // 64 KiB 接收窗口 = 45 段，128 段留出重传余量
const queue_mask = queue_cap - 1;
const delivered_cap = 4096; // 4096 × 1460 = 5.7 MiB，覆盖 4 MiB 的稳态运行

var g_queue: [queue_cap]Seg = undefined;
var g_delivered: [delivered_cap]bool = @splat(false);

/// 第 `idx` 段的长度（字节）。只有尾段可能短于 MSS。
fn segLen(p: Params, idx: u32) u32 {
    const start: u64 = @as(u64, idx) * p.mss;
    if (start >= p.total_bytes) return 0;
    return @intCast(@min(@as(u64, p.mss), p.total_bytes - start));
}

pub fn run(p: Params) Result {
    var r = Result{};
    const rtt = p.one_way_ticks * 2;
    const sample_every = if (p.sample_every == 0) rtt else p.sample_every;

    var cw = cong.Cwnd.init(p.mss, p.initial_ssthresh);
    var rng = Rng{ .state = if (p.seed == 0) 1 else p.seed };

    const q = &g_queue;
    var q_head: usize = 0;
    var q_len: usize = 0;

    // 接收端：`delivered[i]` 表示第 i 段已经收到（可能乱序）。累积确认靠
    // “从 una_idx 起连续为 true 的前缀”推进——这就是接收缓冲的意义：
    // 乱了序的段不会重复发送，只会在洞被填上时一次性推进。
    @memset(&g_delivered, false); // 上一次运行的状态不能漏进这一次
    const delivered = &g_delivered;
    var una_idx: u32 = 0;

    var next_seq: u64 = 0;
    var snd_una: u64 = 0;
    var last_advance: u32 = 0;
    var loss_counter: u32 = 0;
    // 链路串行化信用：1250 B/tick 的链路发一个 1460 B 的段要跨两个 tick，
    // 所以预算必须能累积，否则“每 tick 最多 1250 B”会永远发不出整段。
    var tx_credit: u32 = 0;
    // 快重传已经发出、还没等到新确认：避免每个重复 ACK 都重传一次。
    var fast_retx_inflight = false;

    var tick: u32 = 0;
    while (tick < p.max_ticks) : (tick += 1) {
        // ---- 1) 到达事件：按发出顺序处理（`at` 单调不减） ----
        while (q_len > 0) {
            const seg = q[q_head];
            if (seg.at > tick) break;
            q_head = (q_head + 1) & queue_mask;
            q_len -= 1;
            if (seg.dropped) continue; // 路上丢了，发送端什么也收不到

            const idx: u32 = @intCast(seg.seq / p.mss);
            if (idx >= delivered_cap) continue;
            delivered[idx] = true;

            // 累积确认：把从 una_idx 起的连续前缀一次性推进。
            var advanced: u32 = 0;
            while (una_idx < delivered_cap and delivered[una_idx]) : (una_idx += 1) {
                advanced += segLen(p, una_idx);
            }

            if (advanced > 0) {
                snd_una += advanced;
                cw.onAck(advanced);
                last_advance = tick;
                fast_retx_inflight = false;
                if (next_seq < snd_una) next_seq = snd_una;
            } else {
                // 洞还在：这一段只能换来一个重复 ACK。
                r.dupacks += 1;
                if (cw.onDupAck(p.rwnd_bytes) == .retransmit_now and !fast_retx_inflight) {
                    fast_retx_inflight = true;
                    r.retransmits += 1;
                    if (q_len < queue_cap) {
                        const tail = (q_head + q_len) & queue_mask;
                        q_len += 1;
                        q[tail] = .{
                            .seq = snd_una,
                            .len = segLen(p, una_idx),
                            .at = tick + rtt,
                            .dropped = decideDrop(&p, &rng, &loss_counter),
                        };
                    }
                }
            }
        }

        // ---- 2) 超时：没有新确认的时间超过 RTO ----
        if (snd_una < next_seq and tick - last_advance >= p.rto_ticks) {
            cw.onTimeout(p.rwnd_bytes);
            r.timeouts += 1;
            r.retransmits += 1;
            // go-back-N：在途段全部视为丢失，发送序号回退到 snd_una。
            // 接收端的 delivered[] 不清：它已经收到的数据不会因为发送端
            // 重发而“忘掉”，这也让超时恢复只需要重发一次就够。
            q_len = 0;
            q_head = 0;
            next_seq = snd_una;
            last_advance = tick;
            fast_retx_inflight = false;
        }

        // ---- 3) 发送：受 min(cwnd, rwnd) 与链路速率双重限制 ----
        tx_credit = @min(tx_credit + p.link_bytes_per_tick, 4 * p.mss);
        var budget = tx_credit;
        while (budget > 0 and next_seq < p.total_bytes) {
            const inflight = next_seq - snd_una;
            const limit = cw.inFlightLimit(p.rwnd_bytes);
            if (inflight + p.mss > limit) break;
            const len: u32 = @intCast(@min(@as(u64, p.mss), p.total_bytes - next_seq));
            if (len > budget) break; // 这一 tick 的串行化时间用完了
            if (q_len >= queue_cap) break;

            const tail = (q_head + q_len) & queue_mask;
            q_len += 1;
            q[tail] = .{
                .seq = next_seq,
                .len = len,
                .at = tick + rtt,
                .dropped = decideDrop(&p, &rng, &loss_counter),
            };
            next_seq += len;
            budget -= len;
            r.sent_segments += 1;
        }
        tx_credit = budget;

        // ---- 4) 采样 ----
        if (tick % sample_every == 0 and r.sample_len < sample_cap) {
            r.samples[r.sample_len] = cw.mssCount();
            r.sample_len += 1;
        }

        if (snd_una >= p.total_bytes) {
            r.completed = true;
            r.ticks = tick + 1;
            break;
        }
    }
    if (r.ticks == 0) r.ticks = p.max_ticks;

    r.acked_bytes = snd_una;
    r.fast_retx = cw.fast_retx;
    r.timeouts = cw.timeouts;
    r.hash = r.hashOf();
    return r;
}

fn decideDrop(p: *const Params, rng: *Rng, counter: *u32) bool {
    counter.* += 1;
    return switch (p.loss) {
        .none => false,
        .periodic => |k| k != 0 and (counter.* % k) == 0,
        .random => |permille| rng.permille() < permille,
    };
}

// ---------------------------------------------------------------------------
// 主机侧单测
// ---------------------------------------------------------------------------

test "无丢包：跑完，曲线从 1 段起步，峰值落在 BDP 附近" {
    const r = run(.{ .loss = .none });
    try std.testing.expect(r.completed);
    try std.testing.expectEqual(@as(u64, 256 * 1024), r.acked_bytes);
    try std.testing.expectEqual(@as(u32, 0), r.retransmits);
    try std.testing.expectEqual(@as(u32, 0), r.timeouts);
    try std.testing.expectEqual(@as(u32, 1), r.samples[0]);
    var peak: u32 = 0;
    for (r.samples[0..r.sample_len]) |s| peak = @max(peak, s);
    // 10 Mbit/s × 24 ms ≈ 21 段；rwnd 64 KiB = 44 段。
    try std.testing.expect(peak >= 20 and peak <= 45);
}

test "确定性：同种子两次运行逐字节一致，换种子必变" {
    const a = run(.{ .loss = .{ .random = 20 } });
    const b = run(.{ .loss = .{ .random = 20 } });
    try std.testing.expectEqual(a.hash, b.hash);
    try std.testing.expectEqual(a.sent_segments, b.sent_segments);
    try std.testing.expectEqual(a.acked_bytes, b.acked_bytes);
    try std.testing.expectEqual(a.sample_len, b.sample_len);
    try std.testing.expect(std.mem.eql(u32, a.samples[0..a.sample_len], b.samples[0..b.sample_len]));
    const c = run(.{ .loss = .{ .random = 20 }, .seed = 0xDEAD_BEEF });
    try std.testing.expect(a.hash != c.hash);
}

test "周期丢包：稳态吞吐随丢包率严格单调下降（4 MiB 传输）" {
    const big: u64 = 4 * 1024 * 1024;
    const base = run(.{ .loss = .none, .total_bytes = big, .max_ticks = 400_000 });
    const mild = run(.{ .loss = .{ .periodic = 100 }, .total_bytes = big, .max_ticks = 400_000 });
    const mid = run(.{ .loss = .{ .periodic = 25 }, .total_bytes = big, .max_ticks = 400_000 });
    const harsh = run(.{ .loss = .{ .periodic = 10 }, .total_bytes = big, .max_ticks = 400_000 });
    try std.testing.expect(base.throughputMilli() > mild.throughputMilli());
    try std.testing.expect(mild.throughputMilli() > mid.throughputMilli());
    try std.testing.expect(mid.throughputMilli() > harsh.throughputMilli());
    try std.testing.expect(mild.retransmits > 0);
    try std.testing.expect(harsh.retransmits > mid.retransmits);
}

test "丢包时两种恢复机制都被触发过" {
    const r = run(.{ .loss = .{ .periodic = 10 } });
    try std.testing.expect(r.fast_retx > 0);
    try std.testing.expect(r.dupacks >= 3 * r.fast_retx);
    try std.testing.expect(r.retransmits >= r.fast_retx);
}

test "吞吐被接收窗口卡住：rwnd 8 MSS 时吞吐 ≤ rwnd/RTT" {
    const wide = run(.{ .loss = .none, .rwnd_bytes = 64 * 1024 });
    const narrow = run(.{ .loss = .none, .rwnd_bytes = 8 * 1460 });
    // 上界：8 段 / 24 tick = 486.7 字节/tick。cwnd 会自己涨过 rwnd，
    // 所以在途字节才是判据，不是 cwnd 的采样值。
    try std.testing.expect(narrow.throughputMilli() <= 500_000);
    try std.testing.expect(narrow.throughputMilli() < wide.throughputMilli());
}

test "仿真稳态吞吐与 Mathis 同量级（4 MiB 传输，1% 与 10%）" {
    // 必须跑够长：256 KiB 只有 180 段、1% 丢包平均不到 2 次事件，
    // 那种运行根本没有进入 Mathis 描述的稳态（锯齿），比值落在 1 附近
    // 只是“爬坡均值”的巧合。4 MiB ≈ 2873 段、29 次丢包才算稳态。
    const big: u64 = 4 * 1024 * 1024;
    const r1 = run(.{ .loss = .{ .periodic = 100 }, .total_bytes = big, .max_ticks = 400_000 });
    const t1 = cong.mathisBytesPerTickMilli(10, 1460, 24);
    // 1% 丢包：仿真比理论低约 20%（周期丢包固定命中 + 单洞恢复更乐观，
    // 两个方向叠加的净值见章节 21.7.3），仍同量级。
    try std.testing.expect(r1.throughputMilli() * 10 >= t1 * 7);
    try std.testing.expect(r1.throughputMilli() <= t1);

    const r10 = run(.{ .loss = .{ .periodic = 10 }, .total_bytes = big, .max_ticks = 400_000 });
    const t10 = cong.mathisBytesPerTickMilli(100, 1460, 24);
    // 10% 丢包：go-back-N 式超时恢复让仿真比理论更悲观，但仍同量级。
    try std.testing.expect(r10.throughputMilli() * 2 >= t10);
    try std.testing.expect(r10.throughputMilli() <= t10);
}
