//! ch21-tcp-congestion：拥塞控制律（`cwnd` / `ssthresh` / 快重传 / RTO / BDP / pacing）。
//!
//! 这里**没有任何网络代码**：每个函数只吃“发生了什么”（一个 ACK、一个重复
//! ACK、一次超时）并回答“窗口该怎么变”。这样同一份实现既能在 x86_64 上被
//! `zig build test` 逐字节推演，也能在 rv32 上被 `selftest.zig` 用自造事件
//! 驱动。真正的收发路径在 ch17/ch18/ch20，本章不碰。
//!
//! 单位约定（全模块统一，写在每个字段的注释第一行）：
//!
//!   - 窗口、`ssthresh`、`ca_acked`：**字节**；
//!   - `mss`：字节（默认 1460）；
//!   - 时间：**微秒**（`RttEstimator`）、**tick**（`Pacer`，1 tick = 1 ms）；
//!   - 丢失率：**千分比**（`p_permille`，10 表示 1%）。
//!
//! 为什么窗口内部用字节而不是“段数”：接收窗口（rwnd）本来就是字节，
//! 取小 `min(cwnd, rwnd)` 必须同单位；而历史教材里的 `cwnd` 以 MSS 计数，
//! 换算只需要 `mssCount()`。把单位混在一处，是这类代码最常见的错误来源
//! （表现为“窗口 10，实际发了 14600 字节”）。
//!
//! 控制律的出处：
//!
//!   - 慢启动与拥塞避免：RFC 5681 §3.1（`cwnd < ssthresh` 时每 ACK 加至多
//!     2 SMSS，否则每个 RTT 加 1 SMSS）；
//!   - 快重传/快恢复：RFC 5681 §3.2（三个重复 ACK → 重传；`ssthresh =
//!     max(FlightSize/2, 2*SMSS)`，`cwnd = ssthresh + 3*SMSS`）；
//!   - RTO 后：RFC 5681 §3.1 末段（`cwnd = 1 SMSS`、`ssthresh` 减半）；
//!   - RTT 估计：RFC 6298 §2；
//!   - 窗口缩放：RFC 7323 §2.2（shift 上限 14）；
//!   - Nagle：RFC 896；与延迟 ACK 的互等见 RFC 1122 §4.2.3.2。
//!
//! 与 lwIP 的差异（对照实现见 tcp_in.c/tcp.c/tcp_out.c，行号在章节事实来源表）：
//! RFC 5681 的慢启动按“每 ACK ≤ 2 SMSS”增长，lwIP 另外用 `TF_RTO` 把 RTO 后
//! 的第一个 RTT 限制到 1 SMSS（RFC 3465 §2.2 的补丁）；本章 `Cwnd` 保留前者的
//! 简单形态，本章 `sim.zig` 的仿真器也用同一形态，两边数字才可比。

const std = @import("std");

/// 以太网 1500 字节 MTU 减去 20 字节 IPv4 与 20 字节 TCP 首部。
/// lwIP 的 `TCP_MSS` 默认值同样从这里来（见 lwipopts.h）。
pub const mss_default: u32 = 1460;

/// 窗口缩放的最大位移：RFC 7323 §2.2 明确“必须当作 14 处理”当对方给得更大。
/// 65535 << 14 ≈ 1 GiB，这就是 16 位窗口字段能表达的极限。
pub const wscale_max: u5 = 14;

/// 一个 ACK 最多能“补”多少——RFC 5681 §3.1 的 2 SMSS 上界。
/// 用 2 而不是 `acked` 原值，是为了防止延迟 ACK 批量确认时一次跳过整个窗口。
fn slowStartCap(mss: u32) u32 {
    return 2 * mss;
}

/// 拥塞控制的三种形态。`fast_recovery` 是唯一带“原因”的状态：
/// 它意味着发送端正在重传一个洞，而且 `cwnd` 被临时膨胀了 3 SMSS。
pub const State = enum { slow_start, congestion_avoidance, fast_recovery };

/// `onDupAck` 的回答：要不要立刻重传队首未确认段。
pub const Action = enum { none, retransmit_now };

/// 发送端拥塞窗口状态机（纯逻辑，无 I/O）。
pub const Cwnd = struct {
    /// 字节。一个段的大小；取对端通告的 MSS，本章固定 1460。
    mss: u32 = mss_default,
    /// 字节。拥塞窗口。初始 1 SMSS（RFC 5681 §3.1）。
    cwnd: u32 = mss_default,
    /// 字节。慢启动门限。RFC 5681 建议初值任意大；本章自检用显式值，
    /// 免得“慢启动永不结束”把测试变成恒真。
    ssthresh: u32 = 64 * 1024,
    /// 字节。拥塞避免的字节累加器（RFC 3465）：攒够一个 cwnd 才 +1 SMSS。
    ca_acked: u32 = 0,
    /// 连续重复 ACK 计数（RFC 5681 §3.2 只数 3 个）。
    dupacks: u8 = 0,
    state: State = .slow_start,
    /// 统计：快重传次数、超时次数、收到的重复 ACK 总数、delivered 字节。
    fast_retx: u32 = 0,
    timeouts: u32 = 0,
    dupacks_total: u32 = 0,
    acked_bytes: u64 = 0,

    pub fn init(mss: u32, initial_ssthresh: u32) Cwnd {
        return .{
            .mss = mss,
            .cwnd = mss,
            .ssthresh = initial_ssthresh,
        };
    }

    /// 段数视图（只用于打印与判读，不参与计算）。
    pub fn mssCount(self: Cwnd) u32 {
        return self.cwnd / self.mss;
    }

    /// 实际能在途的字节数：拥塞窗口与接收窗口取小（RFC 5681 §4）。
    /// 发送窗口从来不是 `cwnd` 一个数说了算——这是 21.5 的主题。
    pub fn inFlightLimit(self: Cwnd, rwnd_bytes: u32) u32 {
        return @min(self.cwnd, rwnd_bytes);
    }

    /// 收到一个确认了新数据的 ACK（`acked` 字节）。
    ///
    /// 顺序很重要：先处理“退出快恢复”，再增长窗口。反过来的话，同一个 ACK
    /// 既被当成恢复结束的 deflate 又被当成慢启动的增长，窗口会多涨一次。
    pub fn onAck(self: *Cwnd, acked: u32) void {
        self.acked_bytes += acked;
        self.dupacks = 0;

        if (self.state == .fast_recovery) {
            // Reno 的 deflate：确认了重传的那个洞，窗口退回到减半后的 ssthresh。
            // NewReno 在这里还要区分“部分 ACK”：只补了一个洞就回到慢启动，
            // 会在一次窗口里丢多段时把吞吐打成锯齿（见 21.3）。
            self.cwnd = self.ssthresh;
            self.state = .congestion_avoidance;
            self.ca_acked = 0;
            return;
        }

        if (self.cwnd < self.ssthresh) {
            // 慢启动：每个 ACK 至多补 2 SMSS。段大小为 MSS 时，就是每 ACK +1 MSS，
            // 等价于“每个 RTT 翻倍”。
            self.cwnd += @min(acked, slowStartCap(self.mss));
            self.state = .slow_start;
        } else {
            // 拥塞避免：攒够 cwnd 字节的确认才 +1 MSS，即每 RTT +1 MSS。
            self.ca_acked += acked;
            while (self.ca_acked >= self.cwnd) {
                self.ca_acked -= self.cwnd;
                self.cwnd += self.mss;
            }
            self.state = .congestion_avoidance;
        }
    }

    /// 收到一个重复 ACK（不确认新数据、无载荷、窗口没变）。
    ///
    /// `rwnd_bytes` 只用在 `ssthresh` 的取值上：RFC 5681 用的是
    /// “FlightSize/2”，lwIP 实现取 `min(cwnd, snd_wnd)/2`；两者在“窗口被
    /// 接收端卡住”时差别明显，后者更保守。本章跟随 lwIP。
    pub fn onDupAck(self: *Cwnd, rwnd_bytes: u32) Action {
        self.dupacks_total += 1;
        if (self.dupacks < 255) self.dupacks += 1;

        if (self.dupacks == 3) {
            const flight = self.inFlightLimit(rwnd_bytes);
            self.ssthresh = halfWindow(flight, self.mss);
            self.cwnd = self.ssthresh + 3 * self.mss;
            self.state = .fast_recovery;
            self.fast_retx += 1;
            return .retransmit_now;
        }

        // 第四个及以后的重复 ACK：说明又有一段离开了网络，可以把窗口再膨胀
        // 1 SMSS（RFC 5681 §3.2 的 “cwnd = ssthresh + 3*SMSS” 之后的 inflation）。
        if (self.dupacks > 3 and self.state == .fast_recovery) {
            self.cwnd += self.mss;
        }
        return .none;
    }

    /// 重传定时器超时：这是最贵的一次失败。
    ///
    /// 与快重传的区别只有两条，但后果差一个数量级：`cwnd` 直接回到 1 SMSS
    /// （而不是减半后再膨胀），并且整个窗口的数据都要重发（go-back-N 式）。
    pub fn onTimeout(self: *Cwnd, rwnd_bytes: u32) void {
        const flight = self.inFlightLimit(rwnd_bytes);
        self.ssthresh = halfWindow(flight, self.mss);
        self.cwnd = self.mss;
        self.state = .slow_start;
        self.dupacks = 0;
        self.ca_acked = 0;
        self.timeouts += 1;
    }
};

/// `max(flightWindow/2, 2*SMSS)`。下限 2 SMSS 是必须的：只剩 1 SMSS 时
/// “三个重复 ACK”永远凑不齐（对端最多只能再发一个段），快重传会退化成
/// 只能靠 RTO——这是 RFC 5681 §3.2 与 lwIP 都显式钳过的边界。
pub fn halfWindow(flight: u32, mss: u32) u32 {
    const half = flight / 2;
    return @max(half, 2 * mss);
}

// ---------------------------------------------------------------------------
// 窗口缩放（RFC 7323）
// ---------------------------------------------------------------------------

/// 把对端通告的 shift 钳到 14。`shift > 14` 不是“更大更好”——14 位位移后
/// 16 位字段已经能表达 1 GiB，再大没有意义，而且会让 32 位窗口算术溢出。
pub fn clampWscale(raw: u8) u5 {
    return @intCast(@min(raw, wscale_max));
}

/// 解码：报文字段是 16 位，真实窗口 = field << shift。
pub fn applyWndScale(field: u16, shift: u5) u32 {
    return @as(u32, field) << shift;
}

/// 编码：真实窗口放回报文时要右移，并且**向下取整**后钳进 16 位。
/// 向上取整会通告一个自己都不打算兑现的窗口。
pub fn encodeWnd(wnd: u32, shift: u5) u16 {
    const scaled = wnd >> shift;
    return @intCast(@min(scaled, 0xFFFF));
}

/// 该 shift 下 16 位字段能表达的最大窗口（字节）。
pub fn wndFieldMax(shift: u5) u32 {
    return @as(u32, 0xFFFF) << shift;
}

// ---------------------------------------------------------------------------
// 带宽时延积（BDP）
// ---------------------------------------------------------------------------

/// BDP = 链路速率 × 往返时延。它回答一个问题：**要让链路不空转，窗口至少要多大**。
/// 返回字节。
pub fn bdpBytes(bits_per_sec: u64, rtt_us: u32) u32 {
    const bytes_per_sec = bits_per_sec / 8;
    const bdp = bytes_per_sec * @as(u64, rtt_us) / 1_000_000;
    return @intCast(@min(bdp, std.math.maxInt(u32)));
}

/// BDP 折算成段数（向上取整：不足一段也得给一段）。
pub fn bdpSegments(bits_per_sec: u64, rtt_us: u32, mss: u32) u32 {
    const bdp = bdpBytes(bits_per_sec, rtt_us);
    return (bdp + mss - 1) / mss;
}

/// 给定链路参数，窗口要开到这个值才不会把链路饿死。
/// 下限 2 SMSS（否则一个丢包就让退化到只能靠 RTO）。
pub fn windowForBdp(bits_per_sec: u64, rtt_us: u32, mss: u32) u32 {
    const segs = bdpSegments(bits_per_sec, rtt_us, mss);
    return @max(segs, 2) * mss;
}

// ---------------------------------------------------------------------------
// RTT 估计与 RTO（RFC 6298）
// ---------------------------------------------------------------------------

/// RFC 6298 §2 的四个寄存器，整数微秒实现（不引入浮点：板上用 eabihf 也只有
/// 单精度硬件，f64 会拖进 soft-float 库）。
pub const RttEstimator = struct {
    /// 微秒。平滑 RTT。
    srtt_us: u32 = 0,
    /// 微秒。RTT 偏差（平均绝对偏差的 1/4 估计）。
    rttvar_us: u32 = 0,
    /// 微秒。当前 RTO，初值 1 秒（RFC 6298 §2.1）。
    rto_us: u32 = 1_000_000,
    /// 微秒。时钟粒度 G，RFC 6298 取 200 ms 上限的“测量误差下界”。
    clock_granularity_us: u32 = 1000,
    samples: u32 = 0,

    pub const min_rto_us: u32 = 200_000; // Linux 的下界；RFC 6298 是 1 s
    pub const max_rto_us: u32 = 60_000_000;

    /// 新样本到达。第一次样本 `SRTT = R`、`RTTVAR = R/2`；之后
    /// `RTTVAR = 3/4·RTTVAR + 1/4·|SRTT-R|`、`SRTT = 7/8·SRTT + 1/8·R`。
    /// 注意两点：先算 RTTVAR 再用**更新前**的 SRTT；RTO 的公式带
    /// `max(G, 4·RTTVAR)`，漏掉 G 会让局域网里 RTO 缩到毫秒级而抖动爆炸。
    pub fn sample(self: *RttEstimator, rtt_us: u32) void {
        if (self.samples == 0) {
            self.srtt_us = rtt_us;
            self.rttvar_us = rtt_us / 2;
        } else {
            const delta = if (rtt_us > self.srtt_us) rtt_us - self.srtt_us else self.srtt_us - rtt_us;
            self.rttvar_us = (3 * self.rttvar_us + delta) / 4;
            self.srtt_us = (7 * self.srtt_us + rtt_us) / 8;
        }
        self.samples += 1;
        const var_term = @max(self.clock_granularity_us, 4 * self.rttvar_us);
        const rto = self.srtt_us + var_term;
        self.rto_us = std.math.clamp(rto, min_rto_us, max_rto_us);
    }

    /// 超时后的指数退避（RFC 6298 §5.5）：上限 60 s。不清 srtt，因为
    /// 丢包不代表路径变了。
    pub fn backoff(self: *RttEstimator) void {
        self.rto_us = @min(self.rto_us * 2, max_rto_us);
    }
};

// ---------------------------------------------------------------------------
// pacing：把“一个窗口”摊到一整个 RTT 里发
// ---------------------------------------------------------------------------

/// 令牌桶。1 tick = 1 ms；`rate_bytes_per_sec` 由 `pacingRate()` 给出。
/// 纯逻辑：不读时钟，`refill(elapsed_us)` 由调用方驱动。
pub const Pacer = struct {
    /// 字节/秒。目标发送速率。
    rate_bytes_per_sec: u64 = 0,
    /// 字节。当前可用预算（可为 0）。
    tokens: i64 = 0,
    /// 字节。桶容量：一次突发最多攒多少。取 2 MSS 是常见折中——
    /// 容量越大突发越猛（队列瞬间溢出），越小则小段永远发不出去。
    capacity: i64 = 2 * mss_default,

    pub fn init(rate_bytes_per_sec: u64, capacity: i64) Pacer {
        return .{ .rate_bytes_per_sec = rate_bytes_per_sec, .tokens = capacity, .capacity = capacity };
    }

    pub fn refill(self: *Pacer, elapsed_us: u64) void {
        const add: i64 = @intCast(self.rate_bytes_per_sec * elapsed_us / 1_000_000);
        self.tokens = @min(self.tokens + add, self.capacity);
    }

    pub fn allow(self: *Pacer, bytes: u32) bool {
        if (self.tokens < bytes) return false;
        self.tokens -= bytes;
        return true;
    }
};

/// pacing 速率 = `cwnd / RTT`。这是“发送端自认为的公平份额”：
/// 窗口决定了一个 RTT 内能发多少，RTT 决定分摊到多长时间。
/// 返回字节/秒。
pub fn pacingRateBytesPerSec(cwnd_bytes: u32, rtt_us: u32) u64 {
    if (rtt_us == 0) return 0;
    return @as(u64, cwnd_bytes) * 1_000_000 / rtt_us;
}

// ---------------------------------------------------------------------------
// Nagle
// ---------------------------------------------------------------------------

/// Nagle（RFC 896）：**没有未确认数据时才允许发小段**。
/// 也就是说 “在途 ≤ 1 个未确认小段”。返回 true 表示可以发。
///
/// 这条规则与“延迟 ACK”叠在一起就是经典互等：发送端等 ACK 才发下一段，
/// 接收端等第二段才 ACK——两边各等 40 ms / 200 ms，小包应用的吞吐塌到
/// 个位数。lwIP 的判据在 tcp_priv.h 的 `tcp_do_output_nagle` 宏里：
/// `unacked == NULL || TF_NODELAY || TF_INFR || 未发段 ≥ MSS`。
pub fn nagleAllows(unacked_bytes: u32, pending_bytes: u32, mss: u32, nodelay: bool) bool {
    if (nodelay) return true;
    if (unacked_bytes == 0) return true;
    // 够一整段就可以发：Nagle 只压“小段”，不压满段。
    return pending_bytes >= mss;
}

// ---------------------------------------------------------------------------
// 吞吐模型（Mathis 等人, 1997）
// ---------------------------------------------------------------------------

/// 整数平方根（牛顿法）。板上没有 libm，也不该为一次开方引入 f64。
pub fn isqrt(n: u64) u64 {
    if (n < 2) return n;
    var x: u64 = n;
    var y: u64 = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}

/// Mathis 公式：`BW ≈ (MSS/RTT) · sqrt(3/(2p))`，把 p 用千分比代入：
/// `3/(2p) = 1500/p_permille`。返回值单位是 **毫段/RTT**（毫，即 ×1000），
/// 这样整数运算就够了：真实值除以 1000。
pub fn mathisSegPerRttMilli(p_permille: u32) u64 {
    if (p_permille == 0) return std.math.maxInt(u32);
    const num: u64 = 1500 * 1_000_000 / p_permille;
    return isqrt(num);
}

/// 把 Mathis 的“段/RTT”换成仿真器的“字节/tick”，同样保留 3 位小数。
/// `rtt_ticks` 是 1 ms tick 数；结果 = 毫字节/tick。
pub fn mathisBytesPerTickMilli(p_permille: u32, mss: u32, rtt_ticks: u32) u64 {
    if (rtt_ticks == 0) return 0;
    return mathisSegPerRttMilli(p_permille) * mss / rtt_ticks;
}

// ---------------------------------------------------------------------------
// 主机侧单测（由 src/host_tests.zig 引入；只测纯逻辑，不碰硬件）
// ---------------------------------------------------------------------------

test "慢启动：每个 RTT 翻倍 1 -> 2 -> 4 -> 8" {
    var c = Cwnd.init(1460, 1 << 20);
    var seen: [4]u32 = undefined;
    seen[0] = c.mssCount();
    var rtt: usize = 1;
    while (rtt < 4) : (rtt += 1) {
        const n = c.mssCount();
        var i: u32 = 0;
        // 一个 RTT 内收到 n 个 ACK（每个 ACK 确认一个 MSS）。
        while (i < n) : (i += 1) c.onAck(c.mss);
        seen[rtt] = c.mssCount();
    }
    try std.testing.expectEqual(@as(u32, 1), seen[0]);
    try std.testing.expectEqual(@as(u32, 2), seen[1]);
    try std.testing.expectEqual(@as(u32, 4), seen[2]);
    try std.testing.expectEqual(@as(u32, 8), seen[3]);
    try std.testing.expectEqual(State.slow_start, c.state);
}

test "慢启动：单个 ACK 至多加 2 SMSS" {
    var c = Cwnd.init(1460, 1 << 20);
    c.onAck(1460 * 5); // 一个批量 ACK 确认了 5 段
    try std.testing.expectEqual(@as(u32, 1460 * 3), c.cwnd); // 1 + 2, 不是 1 + 5
}

test "拥塞避免：每 RTT 恰好 +1 MSS" {
    var c = Cwnd.init(1460, 8 * 1460);
    c.cwnd = 8 * 1460;
    c.state = .congestion_avoidance;
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const window = c.cwnd;
        c.onAck(window); // 一个 RTT 的确认量 = 当前窗口
    }
    try std.testing.expectEqual(@as(u32, 11 * 1460), c.cwnd);
    try std.testing.expectEqual(State.congestion_avoidance, c.state);
}

test "快重传：三个重复 ACK，ssthresh 减半，cwnd = ssthresh + 3 MSS" {
    var c = Cwnd.init(1460, 1 << 20);
    c.cwnd = 10 * 1460;
    try std.testing.expectEqual(Action.none, c.onDupAck(64 * 1024));
    try std.testing.expectEqual(Action.none, c.onDupAck(64 * 1024));
    try std.testing.expectEqual(Action.retransmit_now, c.onDupAck(64 * 1024));
    try std.testing.expectEqual(@as(u32, 5 * 1460), c.ssthresh);
    try std.testing.expectEqual(@as(u32, 8 * 1460), c.cwnd);
    try std.testing.expectEqual(State.fast_recovery, c.state);
    // 第四个重复 ACK：膨胀 1 MSS，状态不变。
    try std.testing.expectEqual(Action.none, c.onDupAck(64 * 1024));
    try std.testing.expectEqual(@as(u32, 9 * 1460), c.cwnd);
}

test "快重传：ssthresh 下限是 2 MSS" {
    var c = Cwnd.init(1460, 1 << 20);
    c.cwnd = 1460; // 1 MSS，减半后是 730 字节
    _ = c.onDupAck(1460);
    _ = c.onDupAck(1460);
    _ = c.onDupAck(1460);
    try std.testing.expectEqual(@as(u32, 2 * 1460), c.ssthresh);
    try std.testing.expectEqual(@as(u32, 5 * 1460), c.cwnd);
}

test "快恢复收敛：新 ACK 把 cwnd 退回 ssthresh" {
    var c = Cwnd.init(1460, 1 << 20);
    c.cwnd = 10 * 1460;
    _ = c.onDupAck(64 * 1024);
    _ = c.onDupAck(64 * 1024);
    _ = c.onDupAck(64 * 1024);
    c.onAck(1460);
    try std.testing.expectEqual(@as(u32, 5 * 1460), c.cwnd);
    try std.testing.expectEqual(State.congestion_avoidance, c.state);
    try std.testing.expectEqual(@as(u8, 0), c.dupacks);
}

test "超时：cwnd 回到 1 MSS，ssthresh 减半" {
    var c = Cwnd.init(1460, 1 << 20);
    c.cwnd = 16 * 1460;
    c.onTimeout(64 * 1024);
    try std.testing.expectEqual(@as(u32, 1460), c.cwnd);
    try std.testing.expectEqual(@as(u32, 8 * 1460), c.ssthresh);
    try std.testing.expectEqual(State.slow_start, c.state);
    try std.testing.expectEqual(@as(u32, 1), c.timeouts);
}

test "窗口取小：rwnd < cwnd 时受 rwnd 限制" {
    var c = Cwnd.init(1460, 1 << 20);
    c.cwnd = 10 * 1460;
    try std.testing.expectEqual(@as(u32, 4 * 1460), c.inFlightLimit(4 * 1460));
    try std.testing.expectEqual(@as(u32, 10 * 1460), c.inFlightLimit(64 * 1024));
}

test "窗口缩放：shift 钳到 14，解码/编码往返" {
    try std.testing.expectEqual(@as(u5, 14), clampWscale(14));
    try std.testing.expectEqual(@as(u5, 14), clampWscale(15));
    try std.testing.expectEqual(@as(u5, 0), clampWscale(0));
    try std.testing.expectEqual(@as(u32, 0xFFFF), applyWndScale(0xFFFF, 0));
    try std.testing.expectEqual(@as(u32, 0x3FFFC000), applyWndScale(0xFFFF, 14));
    // 1 MiB 在 shift=14 下只能表达 64 段（向下取整），放回解码是 64<<14。
    try std.testing.expectEqual(@as(u16, 64), encodeWnd(1 << 20, 14));
    try std.testing.expectEqual(@as(u32, 64 << 14), applyWndScale(64, 14));
    // shift=0 时超过 65535 的窗口必须钳住，不能回绕。
    try std.testing.expectEqual(@as(u16, 0xFFFF), encodeWnd(1 << 20, 0));
    try std.testing.expectEqual(@as(u32, 0x3FFFC000), wndFieldMax(14));
}

test "Nagle：有未确认数据时压住小段，满段放行" {
    try std.testing.expect(nagleAllows(0, 100, 1460, false)); // 没有在途数据
    try std.testing.expect(!nagleAllows(1460, 100, 1460, false)); // 100 字节小段被压住
    try std.testing.expect(nagleAllows(1460, 1460, 1460, false)); // 满段放行
    try std.testing.expect(nagleAllows(1460, 100, 1460, true)); // TCP_NODELAY
}

test "BDP：10 Mbit/s × 24 ms = 30 KB，约 21 段" {
    try std.testing.expectEqual(@as(u32, 30_000), bdpBytes(10_000_000, 24_000));
    try std.testing.expectEqual(@as(u32, 21), bdpSegments(10_000_000, 24_000, 1460));
    try std.testing.expectEqual(@as(u32, 21 * 1460), windowForBdp(10_000_000, 24_000, 1460));
    // 100 Mbit/s × 24 ms = 300 KB，接收窗口不放大就永远跑不满。
    try std.testing.expectEqual(@as(u32, 300_000), bdpBytes(100_000_000, 24_000));
}

test "RTT 估计：首次样本给 srtt=r、rttvar=r/2，RTO 落在下界" {
    var e = RttEstimator{};
    e.sample(24_000);
    try std.testing.expectEqual(@as(u32, 24_000), e.srtt_us);
    try std.testing.expectEqual(@as(u32, 12_000), e.rttvar_us);
    try std.testing.expectEqual(RttEstimator.min_rto_us, e.rto_us); // 24+48=72ms 被钳到 200ms
    e.sample(26_000);
    try std.testing.expectEqual(@as(u32, 24_250), e.srtt_us); // 7/8*24000 + 1/8*26000
    e.backoff();
    try std.testing.expectEqual(@as(u32, 400_000), e.rto_us);
}

test "pacing：令牌桶按时间补充，不超过容量" {
    var p = Pacer.init(1_000_000, 2920); // 1 MB/s，桶 2 MSS
    try std.testing.expect(p.allow(2920));
    try std.testing.expect(!p.allow(1));
    p.refill(1_000_000); // 1 秒 -> 补 1 MB，但被容量钳住
    try std.testing.expectEqual(@as(i64, 2920), p.tokens);
    try std.testing.expect(p.allow(1460));
    try std.testing.expect(p.allow(1460));
    try std.testing.expect(!p.allow(1460));
    // cwnd=30KB、RTT=24ms 时 pacing 速率约 1.25 MB/s。
    try std.testing.expectEqual(@as(u64, 1_250_000), pacingRateBytesPerSec(30_000, 24_000));
}

test "Mathis：1% 丢包约 12.2 段/RTT，与会话 21.7 的数字同源" {
    const seg_milli = mathisSegPerRttMilli(10); // p = 10‰ = 1%
    try std.testing.expect(seg_milli >= 12_240 and seg_milli <= 12_250);
    // 12.24 × 1460 / 24 ≈ 745 字节/tick（毫单位 744,xxx）。
    const bytes_milli = mathisBytesPerTickMilli(10, 1460, 24);
    try std.testing.expect(bytes_milli >= 744_000 and bytes_milli <= 746_000);
    try std.testing.expectEqual(@as(u64, 2), isqrt(4));
    try std.testing.expectEqual(@as(u64, 12), isqrt(150));
}
