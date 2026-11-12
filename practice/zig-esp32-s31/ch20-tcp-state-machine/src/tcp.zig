//! ch20-tcp-state-machine：TCP 段编解码 + 序列号算术 + 状态机 + RTO + 重组。
//!
//! 这是 ch16 `headers.zig` 里那个 20 字节 `Tcp` 结构的**超集**：那一版只够
//! “把首部读出来”，本章要真正跑一个连接，于是把它扩成四层：
//!
//!   1. `Header` / `Segment`：20 字节固定首部 + 选项（MSS、WS、SACK-permitted，
//!      后两者只解析不使用）+ 载荷切片；
//!   2. 序列号算术：`seqLt` / `seqLeq` / `seqDiff`，全部在 2^32 模空间里比较，
//!      不用 `<` 直接比 u32；
//!   3. `Conn`：11 个状态、三次握手、四次挥手、TIME_WAIT（2MSL 用注入的
//!      `now_us` 判定，不真睡 60 秒）、重复 ACK 计数、RST 立刻回 CLOSED；
//!   4. `Rto`：RFC 6298 的 SRTT/RTTVAR（α=1/8、β=1/4、K=4），整数定点实现，
//!      下限 1 s、上限 60 s，指数退避；`TxTimer` 是单段重传计时器。
//!
//! 另外两个附属件：
//!
//!   - `planSegments`：把一次 `write` 的载荷按 MSS 切成若干段（纯算术，
//!     不复制字节；真正的发送方按返回的 offset/len 去载荷里取片）；
//!   - `Reasm`：乱序段的有界暂存（固定槽），按 `rcv_nxt` 累积重组。
//!
//! 本模块**不发包、不碰网卡、不开中断**：所有输入都是“已经到达的段”，
//! 所有输出都是“应该发什么”的描述（`Action`）。把这个描述变成以太网帧
//! 是 ch17/ch18 的活，把多个连接排进一个事件循环是 ch21 的活。

const std = @import("std");

pub const Error = error{
    /// 段短于 20 字节，或 data offset 超出缓冲区。
    Truncated,
    /// data offset < 5（小于固定首部）。
    BadOffset,
    /// 选项长度非法（kind 不是 EOL/NOP 却没有长度，或长度越界）。
    BadOption,
    /// 目标缓冲区放不下“首部 + 载荷”。
    BufferTooSmall,
    /// 重组暂存槽已满（有界设计的正常结局，不是 bug）。
    NoSlot,
};

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

pub const MIN_HEADER: usize = 20;
pub const MAX_HEADER: usize = 60;
/// RFC 1122 §4.2.2.6：不协商 MSS 时的默认值 536（576 - 20 - 20）。
pub const MSS_DEFAULT: u16 = 536;
/// 以太网 + IPv4 + TCP 首部都不带选项时的经典 MSS：1500 - 20 - 20。
pub const MSS_ETHERNET: u16 = 1460;
/// RFC 6298 规则 (2.1)：尚未取得 RTT 样本时，RTO 取 1 秒。
pub const INITIAL_RTO_US: u64 = 1_000_000;
/// RFC 6298 规则 (2.4)：每次算出 RTO 后，小于 1 秒就向上取整到 1 秒。
pub const MIN_RTO_US: u64 = 1_000_000;
/// RFC 6298 规则 (2.5)：RTO 上限“至少 60 秒”，这里取 60 秒。
pub const MAX_RTO_US: u64 = 60_000_000;
/// RFC 6298 规则 (2.2)/(2.3)：K = 4，RTO = SRTT + max(G, K × RTTVAR)。
pub const RTO_K: u64 = 4;
/// 演示取值：MSL = 30 秒 → 2MSL = 60 秒。
/// RFC 9293 §3.4.2 把规范的 MSL 取为 2 分钟（engineering choice），
/// lwIP 缺省把 `TCP_MSL` 配成 60000 ms 再乘 2（见 tcp_priv.h:137-138）；
/// 本章取 30 秒只是为了把 2MSL 压到 60 秒，属于本章自己的演示值。
pub const MSL_US: u64 = 30_000_000;
pub const TIME_WAIT_US: u64 = 2 * MSL_US;

// ---------------------------------------------------------------------------
// 标志位与首部
// ---------------------------------------------------------------------------

/// 首部第 13 字节（低 8 位）。LSB 在前，与 ch16 `headers.TcpFlags` 一致。
pub const Flags = packed struct(u8) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,

    pub fn toByte(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) Flags {
        return @bitCast(byte);
    }

    /// 只用于日志：把置位的标志拼成 "SA" / "FA" 这样的短串。
    /// 返回的缓冲由调用方提供（不分配）。
    pub fn name(self: Flags, buf: *[8]u8) []const u8 {
        var n: usize = 0;
        if (self.syn) {
            buf[n] = 'S';
            n += 1;
        }
        if (self.ack) {
            buf[n] = 'A';
            n += 1;
        }
        if (self.fin) {
            buf[n] = 'F';
            n += 1;
        }
        if (self.rst) {
            buf[n] = 'R';
            n += 1;
        }
        if (self.psh) {
            buf[n] = 'P';
            n += 1;
        }
        if (n == 0) {
            buf[n] = '-';
            n += 1;
        }
        return buf[0..n];
    }
};

/// 已解析的选项。SACK-permitted 与 WS 只记录、不参与行为（窗口缩放留 ch21，
/// SACK 的重传选择也留 ch21：本章只有“单段 + 累积 ACK”这一种重传）。
pub const Options = struct {
    /// kind 2，长度 4。
    mss: ?u16 = null,
    /// kind 3，长度 3（shift count，0..14）。
    window_scale: ?u8 = null,
    /// kind 4，长度 2。
    sack_permitted: bool = false,
    /// 选项区实际字节数（含 EOL/NOP 填充，已按 4 字节对齐）。
    bytes: usize = 0,

    pub fn eql(a: Options, b: Options) bool {
        return a.mss == b.mss and
            a.window_scale == b.window_scale and
            a.sack_permitted == b.sack_permitted;
    }
};

pub const Header = struct {
    src_port: u16 = 0,
    dst_port: u16 = 0,
    seq: u32 = 0,
    ack: u32 = 0,
    /// 以 4 字节为单位，最小 5（=20 字节）。
    data_offset: u4 = 5,
    flags: Flags = .{},
    window: u16 = 0,
    checksum_value: u16 = 0,
    urgent: u16 = 0,

    pub fn len(self: Header) usize {
        return @as(usize, self.data_offset) * 4;
    }
};

/// 一个已解析的段。`payload` 指向输入缓冲区，不做复制。
pub const Segment = struct {
    hdr: Header,
    opts: Options,
    payload: []const u8,

    pub fn headerLen(self: Segment) usize {
        return self.hdr.len();
    }

    pub fn seqLen(self: Segment) u32 {
        const data: u32 = @intCast(self.payload.len);
        var n = data;
        if (self.hdr.flags.syn) n += 1;
        if (self.hdr.flags.fin) n += 1;
        return n;
    }
};

/// 解析选项区 `buf[20..data_offset*4]`。遇到第一个 EOL（0）就停止，
/// 因此“全零填充”不会被当成非法选项。
pub fn parseOptions(buf: []const u8) Error!Options {
    var out = Options{};
    var i: usize = 0;
    while (i < buf.len) {
        const kind = buf[i];
        if (kind == 0) break; // EOL
        if (kind == 1) { // NOP
            i += 1;
            continue;
        }
        if (i + 1 >= buf.len) return error.BadOption;
        const len = buf[i + 1];
        if (len < 2 or i + len > buf.len) return error.BadOption;
        switch (kind) {
            2 => {
                if (len != 4) return error.BadOption;
                out.mss = (@as(u16, buf[i + 2]) << 8) | buf[i + 3];
            },
            3 => {
                if (len != 3) return error.BadOption;
                if (buf[i + 2] > 14) return error.BadOption;
                out.window_scale = buf[i + 2];
            },
            4 => {
                if (len != 2) return error.BadOption;
                out.sack_permitted = true;
            },
            else => {}, // 未知选项按长度跳过（RFC 9293 §3.9.2：MUST ignore 不认识的选项）
        }
        i += len;
    }
    out.bytes = buf.len;
    return out;
}

pub fn parse(buf: []const u8) Error!Segment {
    if (buf.len < MIN_HEADER) return error.Truncated;
    const off_flags = std.mem.readInt(u16, buf[12..14], .big);
    const data_offset: u4 = @truncate(off_flags >> 12);
    if (data_offset < 5) return error.BadOffset;
    const hlen = @as(usize, data_offset) * 4;
    if (hlen > MAX_HEADER or hlen > buf.len) return error.Truncated;

    const hdr = Header{
        .src_port = std.mem.readInt(u16, buf[0..2], .big),
        .dst_port = std.mem.readInt(u16, buf[2..4], .big),
        .seq = std.mem.readInt(u32, buf[4..8], .big),
        .ack = std.mem.readInt(u32, buf[8..12], .big),
        .data_offset = data_offset,
        .flags = Flags.fromByte(@truncate(off_flags & 0xFF)),
        .window = std.mem.readInt(u16, buf[14..16], .big),
        .checksum_value = std.mem.readInt(u16, buf[16..18], .big),
        .urgent = std.mem.readInt(u16, buf[18..20], .big),
    };
    const opts = try parseOptions(buf[MIN_HEADER..hlen]);
    return .{ .hdr = hdr, .opts = opts, .payload = buf[hlen..] };
}

/// 选项区的字节数（含填充），保证是 4 的倍数。
pub fn optionsByteLen(opts: Options) usize {
    var n: usize = 0;
    if (opts.mss != null) n += 4; // kind,len,mss(2)
    if (opts.window_scale != null) n += 4; // kind,len,shift + 1 NOP
    if (opts.sack_permitted) n += 2; // kind,len
    return (n + 3) & ~@as(usize, 3);
}

/// 编码一个完整段（首部 + 选项 + 载荷）到 `buf`，返回总字节数。
/// 校验和字段写成 0：调用方随后用 `checksum.fillTcp` 填。
/// `hdr.data_offset` 会被忽略并重算——它的唯一来源是选项集。
pub fn encode(hdr_in: Header, opts: Options, payload: []const u8, buf: []u8) Error!usize {
    const opt_len = optionsByteLen(opts);
    const hlen = MIN_HEADER + opt_len;
    if (hlen > MAX_HEADER) return error.BadOption;
    const total = hlen + payload.len;
    if (buf.len < total) return error.BufferTooSmall;

    var hdr = hdr_in;
    hdr.data_offset = @intCast(hlen / 4);
    hdr.checksum_value = 0;

    std.mem.writeInt(u16, buf[0..2], hdr.src_port, .big);
    std.mem.writeInt(u16, buf[2..4], hdr.dst_port, .big);
    std.mem.writeInt(u32, buf[4..8], hdr.seq, .big);
    std.mem.writeInt(u32, buf[8..12], hdr.ack, .big);
    const off_flags: u16 = (@as(u16, hdr.data_offset) << 12) | @as(u16, hdr.flags.toByte());
    std.mem.writeInt(u16, buf[12..14], off_flags, .big);
    std.mem.writeInt(u16, buf[14..16], hdr.window, .big);
    std.mem.writeInt(u16, buf[16..18], 0, .big);
    std.mem.writeInt(u16, buf[18..20], hdr.urgent, .big);

    var i: usize = MIN_HEADER;
    if (opts.mss) |mss| {
        buf[i] = 2;
        buf[i + 1] = 4;
        std.mem.writeInt(u16, buf[i + 2 ..][0..2], mss, .big);
        i += 4;
    }
    if (opts.window_scale) |shift| {
        buf[i] = 3;
        buf[i + 1] = 3;
        buf[i + 2] = shift;
        buf[i + 3] = 1; // NOP 填充到 4 字节
        i += 4;
    }
    if (opts.sack_permitted) {
        buf[i] = 4;
        buf[i + 1] = 2;
        i += 2;
    }
    while (i < hlen) : (i += 1) buf[i] = 0; // EOL 填充
    @memcpy(buf[hlen..total], payload);
    return total;
}

// ---------------------------------------------------------------------------
// 序列号算术（RFC 1982 §3.2 的比较定义；RFC 9293 §3.4 的序号空间与 MSL）
//
// 序列号是 2^32 的模空间，不是整数轴。两个判据都不能用 `<`：
//   - 回绕：0xFFFFFFF0 + 0x30 = 0x20，此时 "0x20 > 0xFFFFFFF0" 必须为真；
//   - 半程规则：以 a 为起点，b 落在前半个圆（差值 < 2^31）才算“在 a 之后”。
// 把差值 reinterpret 成 i32 正好实现这个半程比较：符号位就是答案。
// ---------------------------------------------------------------------------

/// 序列号距离（a 在 b 之后为正）。只用于日志与排序键；**不要**用它判断
/// “先后”——差值正好 2^31 时它的符号是有歧义的（i32 的 MIN），而
/// `seqLt` 在这种情形必须两边都返回 false（RFC 1982 §3.2 的未定义区）。
pub fn seqDiff(a: u32, b: u32) i32 {
    return @bitCast(a -% b);
}

/// RFC 1982 的严格形式：
///   a < b  ⇔  (a < b 且 b - a < 2^31) 或 (a > b 且 a - b > 2^31)
/// 相差正好 2^31 时两个方向都不成立——这正是“半程规则”的边界。
pub fn seqLt(a: u32, b: u32) bool {
    if (a == b) return false;
    if (a < b) return (b - a) < 0x8000_0000;
    return (a - b) > 0x8000_0000;
}

pub fn seqLeq(a: u32, b: u32) bool {
    return a == b or seqLt(a, b);
}

pub fn seqGt(a: u32, b: u32) bool {
    return seqLt(b, a);
}

/// `[start, start+len)` 是否覆盖 `x`（模空间）。len 必须 < 2^31。
pub fn seqInRange(x: u32, start: u32, len: u32) bool {
    const off = x -% start;
    return off < len;
}

// ---------------------------------------------------------------------------
// RTO 估计（RFC 6298 §2 的规则 (2.1)–(2.5)）
//
//   Karn 算法：重传过的段不取样本（RFC 6298 §3；`Conn.retransmit_happened` 守住）；
//   第一次测量（2.2）：SRTT = R，RTTVAR = R/2；
//   之后（2.3）：      RTTVAR = (3·RTTVAR + |SRTT - R|) / 4      （β = 1/4）
//                     SRTT   = (7·SRTT + R) / 8                （α = 1/8）
//   RTO = SRTT + max(G, 4·RTTVAR)，然后按 (2.4)/(2.5) 钳制到 [1 s, 60 s]。
//
// 用整数微秒做定点：除以 8 与 4 都是移位，误差最多 1 µs（可接受，且可复现）。
// ---------------------------------------------------------------------------

pub const Rto = struct {
    srtt_us: u64 = 0,
    rttvar_us: u64 = 0,
    rto_us: u64 = INITIAL_RTO_US,
    have_sample: bool = false,

    pub fn sample(self: *Rto, rtt_us: u64) void {
        if (!self.have_sample) {
            self.srtt_us = rtt_us;
            self.rttvar_us = rtt_us / 2;
            self.have_sample = true;
        } else {
            const diff = if (self.srtt_us > rtt_us) self.srtt_us - rtt_us else rtt_us - self.srtt_us;
            self.rttvar_us = (3 * self.rttvar_us + diff) / 4;
            self.srtt_us = (7 * self.srtt_us + rtt_us) / 8;
        }
        self.rto_us = clampRto(self.srtt_us + RTO_K * self.rttvar_us);
    }

    /// 指数退避：超时重传时调用（RFC 6298 规则 (5.5)：RTO ← RTO × 2）。
    pub fn backoff(self: *Rto) void {
        self.rto_us = @min(self.rto_us * 2, MAX_RTO_US);
    }
};

pub fn clampRto(value: u64) u64 {
    return @min(@max(value, MIN_RTO_US), MAX_RTO_US);
}

/// 单段重传计时器：只有“一个未确认段”的模型（本章刻意不做滑动窗口）。
pub const TxTimer = struct {
    active: bool = false,
    deadline_us: u64 = 0,
    retries: u32 = 0,

    pub fn start(self: *TxTimer, now_us: u64, rto_us: u64) void {
        self.active = true;
        self.deadline_us = now_us + rto_us;
    }

    pub fn stop(self: *TxTimer) void {
        self.active = false;
        self.deadline_us = 0;
    }

    pub fn expired(self: *const TxTimer, now_us: u64) bool {
        return self.active and now_us >= self.deadline_us;
    }

    /// 剩余时间（µs）；未激活时返回 0。
    pub fn remaining(self: *const TxTimer, now_us: u64) u64 {
        if (!self.active) return 0;
        return if (now_us >= self.deadline_us) 0 else self.deadline_us - now_us;
    }
};

// ---------------------------------------------------------------------------
// MSS 分段
// ---------------------------------------------------------------------------

pub const Slice = struct {
    /// 载荷内偏移。
    offset: usize,
    len: usize,
    /// 该段的 seq（第一段以 `start_seq` 起）。
    seq: u32,
};

/// 把 `payload_len` 字节按 `mss` 切成段，写入 `out`，返回段数。
/// `out` 不够时只写前 `out.len` 段并返回被截断的数量（调用方自己保证够大：
/// 一个 3000 字节的写、MSS 1460 只需要 3 个槽）。
pub fn planSegments(start_seq: u32, payload_len: usize, mss: usize, out: []Slice) usize {
    if (payload_len == 0 or mss == 0) return 0;
    var n: usize = 0;
    var off: usize = 0;
    while (off < payload_len and n < out.len) : (n += 1) {
        const len = @min(mss, payload_len - off);
        out[n] = .{
            .offset = off,
            .len = len,
            .seq = start_seq +% @as(u32, @intCast(off)),
        };
        off += len;
    }
    return n;
}

// ---------------------------------------------------------------------------
// 乱序重组：固定槽，按 rcv_nxt 累积交付
// ---------------------------------------------------------------------------

pub const SLOT_MAX: usize = 512;
pub const SLOTS: usize = 4;

const Slot = struct {
    used: bool = false,
    seq: u32 = 0,
    len: usize = 0,
    data: [SLOT_MAX]u8 = undefined,
};

/// 有界重组器。设计取舍写在章节 20.7：
///   - 槽数固定（4），存不下就丢**最老**的一段并计入 `dropped`——接收方的
///     正确反应是继续发累积 ACK 让对方重传，而不是无界增长；
///   - 只交付“从 `expect` 开始连续”的字节，缺口之前的段一律留在槽里；
///   - 交付缓冲由调用方给，重组器自己不持有大块内存（`out` 就是应用读缓冲）。
pub const Reasm = struct {
    expect: u32 = 0,
    slots: [SLOTS]Slot = .{ Slot{}, Slot{}, Slot{}, Slot{} },
    buffered: usize = 0,
    dropped: u32 = 0,

    pub fn init(expect: u32) Reasm {
        return .{ .expect = expect };
    }

    pub fn reset(self: *Reasm, expect: u32) void {
        self.* = .{ .expect = expect };
    }

    /// 插入一段，返回到 `out` 里“新交付”的字节数（0 表示还缺前面的段，
    /// 或这段是重复的老段）。`out` 的容量至少要能装下从 `expect` 起连续的
    /// 所有数据；本章自检给 512 字节。
    pub fn insert(self: *Reasm, seq: u32, data: []const u8, out: []u8) usize {
        if (data.len == 0) return 0;

        var s = seq;
        var bytes = data;

        // 老段（完全在 expect 之前，或与已交付区间重叠）：裁掉前缀。
        if (seqLt(s, self.expect)) {
            const ahead: u32 = self.expect -% s;
            if (ahead >= bytes.len) return 0; // 整段都是旧的
            bytes = bytes[ahead..];
            s = self.expect;
        }

        var produced: usize = 0;
        if (s == self.expect) {
            const take = @min(bytes.len, out.len);
            @memcpy(out[0..take], bytes[0..take]);
            produced = take;
            self.expect +%= @intCast(take);
            if (take < bytes.len) {
                // 调用方缓冲太小：剩余部分进槽，不算错误。
                _ = self.store(s +% @as(u32, @intCast(take)), bytes[take..]);
                return produced;
            }
            // 吸收所有已经接上的槽。
            while (true) {
                var idx: ?usize = null;
                for (self.slots, 0..) |slot, i| {
                    if (slot.used and slot.seq == self.expect) {
                        idx = i;
                        break;
                    }
                }
                const i = idx orelse break;
                const slot = &self.slots[i];
                const room = out.len - produced;
                const take2 = @min(slot.len, room);
                @memcpy(out[produced..][0..take2], slot.data[0..take2]);
                produced += take2;
                self.expect +%= @intCast(take2);
                self.buffered -= slot.len;
                if (take2 < slot.len) {
                    // 极端情况：调用方缓冲不足，剩余留在槽里（就地搬移）。
                    const rest = slot.len - take2;
                    std.mem.copyForwards(u8, slot.data[0..rest], slot.data[take2..slot.len]);
                    slot.len = rest;
                    slot.seq = self.expect;
                    self.buffered += rest;
                    return produced;
                }
                slot.* = Slot{};
            }
            return produced;
        }

        // 未来段：进槽。
        _ = self.store(s, bytes);
        return produced;
    }

    fn store(self: *Reasm, seq: u32, data: []const u8) bool {
        // 先找空槽；没有就丢最老的一段（seq 最小者，模空间比较）。
        var idx: ?usize = null;
        for (self.slots, 0..) |slot, i| {
            if (!slot.used) {
                idx = i;
                break;
            }
        }
        if (idx == null) {
            var victim: usize = 0;
            for (self.slots, 0..) |slot, i| {
                if (seqLt(slot.seq, self.slots[victim].seq)) victim = i;
            }
            idx = victim;
            self.buffered -= self.slots[victim].len;
            self.dropped += 1;
        }
        const slot = &self.slots[idx.?];
        const take = @min(data.len, SLOT_MAX);
        @memcpy(slot.data[0..take], data[0..take]);
        slot.seq = seq;
        slot.len = take;
        slot.used = true;
        self.buffered += take;
        return take == data.len;
    }

    /// 缺口之后仍被暂存的字节数（>0 说明还有段等着前面补上）。
    pub fn pendingBytes(self: *const Reasm) usize {
        return self.buffered;
    }
};

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

pub const State = enum {
    closed,
    listen,
    syn_sent,
    syn_rcvd,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    closing,
    time_wait,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .closed => "CLOSED",
            .listen => "LISTEN",
            .syn_sent => "SYN_SENT",
            .syn_rcvd => "SYN_RCVD",
            .established => "ESTABLISHED",
            .fin_wait_1 => "FIN_WAIT_1",
            .fin_wait_2 => "FIN_WAIT_2",
            .close_wait => "CLOSE_WAIT",
            .last_ack => "LAST_ACK",
            .closing => "CLOSING",
            .time_wait => "TIME_WAIT",
        };
    }
};

/// 一次状态迁移的“输出”：应该往对面发什么。
/// 注意这不是报文——没有端口、没有选项；端口由连接固定，选项只在握手时发。
pub const Action = struct {
    send: bool = false,
    retransmit: bool = false,
    seq: u32 = 0,
    ack: u32 = 0,
    flags: Flags = .{},
    payload_len: usize = 0,
    /// 触发这次输出的迁移（日志/判读用）。
    to: State = .closed,
};

pub const Conn = struct {
    state: State = .closed,
    iss: u32 = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    /// 已发送过的最高序列号（含 SYN/FIN）。`snd_una == snd_max` 即“全部确认”。
    snd_max: u32 = 0,
    rcv_nxt: u32 = 0,
    /// 对方通告的接收窗口（本章只记录，不做窗口管理）。
    snd_wnd: u16 = 0,
    /// 有效 MSS：取对端 SYN 里的选项，缺省 536。
    mss: u16 = MSS_DEFAULT,
    /// 握手时自己通告的 MSS（以太网 1460）。
    our_mss: u16 = MSS_ETHERNET,
    rto: Rto = .{},
    timer: TxTimer = .{},
    dup_acks: u8 = 0,
    fast_retransmits: u32 = 0,
    /// 是否发生过重传：Karn 算法据此拒绝 RTT 样本。
    retransmit_happened: bool = false,
    /// 单段模型下“已发出但未确认”的载荷长度。
    unacked_len: usize = 0,
    /// TIME_WAIT 的到期时刻（注入时钟，不真等）。
    time_wait_until_us: u64 = 0,
    last: Action = .{},

    // -- 建立 ---------------------------------------------------------------

    /// 被动打开：进入 LISTEN。`iss` 是本次连接的初始序列号。
    pub fn listen(self: *Conn, iss: u32) void {
        self.* = .{ .state = .listen, .iss = iss, .snd_una = iss, .snd_nxt = iss, .snd_max = iss };
    }

    /// 主动打开：CLOSED → SYN_SENT，返回要发的 SYN。
    pub fn activeOpen(self: *Conn, iss: u32, now_us: u64) Action {
        self.* = .{ .state = .syn_sent, .iss = iss, .snd_una = iss, .snd_nxt = iss +% 1, .snd_max = iss +% 1 };
        self.timer.start(now_us, self.rto.rto_us);
        self.last = .{
            .send = true,
            .seq = iss,
            .ack = 0,
            .flags = .{ .syn = true },
            .to = .syn_sent,
        };
        return self.last;
    }

    /// 应用请求关闭（主动关闭或 CLOSE_WAIT 里的被动关闭收尾）。
    pub fn appClose(self: *Conn, now_us: u64) Action {
        switch (self.state) {
            .established => {
                self.snd_nxt +%= 1;
                self.snd_max = self.snd_nxt;
                self.state = .fin_wait_1;
                self.retransmit_happened = false;
                self.timer.start(now_us, self.rto.rto_us);
                self.last = .{ .send = true, .seq = self.snd_nxt -% 1, .ack = self.rcv_nxt, .flags = .{ .fin = true, .ack = true }, .to = .fin_wait_1 };
            },
            .close_wait => {
                self.snd_nxt +%= 1;
                self.snd_max = self.snd_nxt;
                self.state = .last_ack;
                self.retransmit_happened = false;
                self.timer.start(now_us, self.rto.rto_us);
                self.last = .{ .send = true, .seq = self.snd_nxt -% 1, .ack = self.rcv_nxt, .flags = .{ .fin = true, .ack = true }, .to = .last_ack };
            },
            else => self.last = .{ .to = self.state },
        }
        return self.last;
    }

    /// 应用写入数据（单段模型：一次写完，长度 ≤ MSS）。
    pub fn sendData(self: *Conn, len: usize, now_us: u64) Action {
        if (self.state != .established and self.state != .close_wait) {
            self.last = .{ .to = self.state };
            return self.last;
        }
        const start = self.snd_nxt;
        self.snd_nxt +%= @intCast(len);
        self.snd_max = self.snd_nxt;
        self.unacked_len = len;
        self.retransmit_happened = false;
        self.timer.start(now_us, self.rto.rto_us);
        self.last = .{
            .send = true,
            .seq = start,
            .ack = self.rcv_nxt,
            .flags = .{ .ack = true, .psh = true },
            .payload_len = len,
            .to = self.state,
        };
        return self.last;
    }

    /// 收到一个段，返回应发的段（可能为空）。
    pub fn onSegment(self: *Conn, seg: Segment, now_us: u64) Action {
        self.last = .{ .to = self.state };
        const h = seg.hdr;

        // RST 在任何状态下都优先：立刻回 CLOSED，且不回任何东西。
        if (h.flags.rst) {
            self.state = .closed;
            self.timer.stop();
            self.unacked_len = 0;
            self.last = .{ .to = .closed };
            return self.last;
        }

        switch (self.state) {
            .closed => {},
            .listen => {
                if (h.flags.syn and !h.flags.ack) {
                    self.rcv_nxt = h.seq +% 1;
                    self.snd_una = self.iss;
                    self.snd_nxt = self.iss +% 1;
                    self.snd_max = self.snd_nxt;
                    self.snd_wnd = h.window;
                    self.mss = seg.opts.mss orelse MSS_DEFAULT;
                    self.state = .syn_rcvd;
                    self.timer.start(now_us, self.rto.rto_us);
                    self.last = .{
                        .send = true,
                        .seq = self.iss,
                        .ack = self.rcv_nxt,
                        .flags = .{ .syn = true, .ack = true },
                        .to = .syn_rcvd,
                    };
                }
            },
            .syn_sent => {
                if (h.flags.syn and h.flags.ack and h.ack == self.snd_max) {
                    self.rcv_nxt = h.seq +% 1;
                    self.snd_una = h.ack;
                    self.snd_wnd = h.window;
                    self.mss = seg.opts.mss orelse MSS_DEFAULT;
                    self.state = .established;
                    self.timer.stop();
                    self.last = .{ .send = true, .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = .{ .ack = true }, .to = .established };
                }
            },
            .syn_rcvd => {
                if (h.flags.ack and h.ack == self.snd_max) {
                    self.snd_una = h.ack;
                    self.state = .established;
                    self.timer.stop();
                    self.last = .{ .to = .established };
                }
            },
            .established, .close_wait => {
                if (h.flags.ack) self.processAck(h.ack, now_us);
                var reply = Action{ .to = self.state };
                if (seg.payload.len > 0) {
                    // 累积确认：只要落在窗口内就“收下”，这里用 rcv_nxt 判定。
                    if (seqLeq(h.seq, self.rcv_nxt) and seqLt(self.rcv_nxt, h.seq +% @as(u32, @intCast(seg.payload.len)))) {
                        self.rcv_nxt = h.seq +% @as(u32, @intCast(seg.payload.len));
                    }
                    reply = .{ .send = true, .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = .{ .ack = true }, .to = self.state };
                }
                if (h.flags.fin) {
                    self.rcv_nxt +%= 1;
                    if (self.state == .established) self.state = .close_wait;
                    reply = .{ .send = true, .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = .{ .ack = true }, .to = self.state };
                }
                // 三次重复 ACK：快速重传（不进入慢启动，序号不后退）。
                if (self.dup_acks >= 3 and self.state == .established) {
                    self.dup_acks = 0;
                    self.fast_retransmits += 1;
                    self.retransmit_happened = true;
                    self.timer.start(now_us, self.rto.rto_us);
                    reply = .{
                        .send = true,
                        .retransmit = true,
                        .seq = self.snd_una,
                        .ack = self.rcv_nxt,
                        .flags = .{ .ack = true, .psh = true },
                        .payload_len = self.unacked_len,
                        .to = self.state,
                    };
                }
                self.last = reply;
            },
            .fin_wait_1 => {
                if (h.flags.ack) self.processAck(h.ack, now_us);
                var reply = Action{ .to = self.state };
                const fin_acked = h.flags.ack and h.ack == self.snd_max;
                if (h.flags.fin) {
                    self.rcv_nxt +%= 1;
                    if (fin_acked) {
                        self.state = .time_wait;
                        self.time_wait_until_us = now_us + TIME_WAIT_US;
                    } else {
                        self.state = .closing;
                    }
                    reply = .{ .send = true, .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = .{ .ack = true }, .to = self.state };
                } else if (fin_acked) {
                    self.state = .fin_wait_2;
                }
                self.last = reply;
            },
            .fin_wait_2 => {
                if (h.flags.fin) {
                    self.rcv_nxt = h.seq +% 1;
                    self.state = .time_wait;
                    self.time_wait_until_us = now_us + TIME_WAIT_US;
                    self.last = .{ .send = true, .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = .{ .ack = true }, .to = .time_wait };
                }
            },
            .last_ack => {
                if (h.flags.ack and h.ack == self.snd_max) {
                    self.state = .closed;
                    self.timer.stop();
                    self.last = .{ .to = .closed };
                }
            },
            .closing => {
                if (h.flags.ack and h.ack == self.snd_max) {
                    self.state = .time_wait;
                    self.timer.stop();
                    self.time_wait_until_us = now_us + TIME_WAIT_US;
                    self.last = .{ .to = .time_wait };
                }
            },
            .time_wait => {
                // 对方重传 FIN：重发最后一个 ACK，2MSL 重新起算
                // （RFC 9293 §3.10.7.4 的 TIME-WAIT 处理）。
                if (h.flags.fin) {
                    self.rcv_nxt = h.seq +% 1;
                    self.time_wait_until_us = now_us + TIME_WAIT_US;
                    self.last = .{ .send = true, .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = .{ .ack = true }, .to = .time_wait };
                }
            },
        }
        return self.last;
    }

    fn processAck(self: *Conn, ack: u32, now_us: u64) void {
        if (seqGt(ack, self.snd_max)) return; // ACK 超出已发送范围：忽略（不做 RST）
        if (ack == self.snd_max) {
            if (seqLt(self.snd_una, ack)) {
                self.snd_una = ack;
                self.unacked_len = 0;
                self.dup_acks = 0;
                self.timer.stop();
            }
            return;
        }
        if (seqLt(self.snd_una, ack)) {
            // 部分确认：推进 snd_una，计时器按当前 RTO 重起。
            const acked: u32 = ack -% self.snd_una;
            self.snd_una = ack;
            if (@as(usize, acked) <= self.unacked_len) {
                self.unacked_len -= acked;
            } else {
                self.unacked_len = 0;
            }
            self.dup_acks = 0;
            if (self.snd_una == self.snd_max) {
                self.timer.stop();
            } else {
                self.timer.start(now_us, self.rto.rto_us);
            }
            return;
        }
        // ack == snd_una 且仍有未确认数据 → 重复 ACK（duplicate ACK）。
        // 没有未确认数据时的“重复 ACK”只是对端在重复确认同一个窗口，不计。
        if (ack == self.snd_una and self.snd_una != self.snd_max) {
            self.dup_acks +|= 1;
        }
    }

    /// 取一个 RTT 样本（Karn：重传过的段不给样本）。
    pub fn sampleRtt(self: *Conn, rtt_us: u64) bool {
        if (self.retransmit_happened) return false;
        self.rto.sample(rtt_us);
        return true;
    }

    /// 时钟推进：重传 / TIME_WAIT 到期。返回要发的段（可能为空）。
    pub fn tick(self: *Conn, now_us: u64) Action {
        self.last = .{ .to = self.state };
        if (self.state == .time_wait) {
            if (now_us >= self.time_wait_until_us) {
                self.state = .closed;
                self.last = .{ .to = .closed };
            }
            return self.last;
        }
        if (!self.timer.expired(now_us)) return self.last;

        self.timer.retries +|= 1;
        self.retransmit_happened = true;
        self.rto.backoff();
        self.timer.start(now_us, self.rto.rto_us);

        const out: Action = switch (self.state) {
            .syn_sent => .{ .send = true, .retransmit = true, .seq = self.iss, .ack = 0, .flags = .{ .syn = true }, .to = .syn_sent },
            .syn_rcvd => .{ .send = true, .retransmit = true, .seq = self.iss, .ack = self.rcv_nxt, .flags = .{ .syn = true, .ack = true }, .to = .syn_rcvd },
            .established, .close_wait => .{ .send = true, .retransmit = true, .seq = self.snd_una, .ack = self.rcv_nxt, .flags = .{ .ack = true, .psh = true }, .payload_len = self.unacked_len, .to = self.state },
            .fin_wait_1, .last_ack, .closing => .{ .send = true, .retransmit = true, .seq = self.snd_una, .ack = self.rcv_nxt, .flags = .{ .fin = true, .ack = true }, .to = self.state },
            else => .{ .to = self.state },
        };
        self.last = out;
        return out;
    }

    /// 供日志：当前是否“全部确认”。
    pub fn allAcked(self: *const Conn) bool {
        return self.snd_una == self.snd_max;
    }
};

// ---------------------------------------------------------------------------
// 测试（主机侧；`zig build test` 跑这一组）
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tcp: 20 字节首部双向编解码（ch16 同构）" {
    const hdr = Header{
        .src_port = 8080,
        .dst_port = 80,
        .seq = 0x01020304,
        .ack = 0x05060708,
        .flags = .{ .syn = true, .ack = true },
        .window = 8192,
        .urgent = 0,
    };
    var buf: [64]u8 = undefined;
    const n = try encode(hdr, .{}, "hi", &buf);
    try testing.expectEqual(@as(usize, 22), n);
    const seg = try parse(buf[0..n]);
    try testing.expectEqual(@as(u16, 8080), seg.hdr.src_port);
    try testing.expectEqual(@as(u16, 80), seg.hdr.dst_port);
    try testing.expectEqual(@as(u32, 0x01020304), seg.hdr.seq);
    try testing.expectEqual(@as(u32, 0x05060708), seg.hdr.ack);
    try testing.expectEqual(@as(u4, 5), seg.hdr.data_offset);
    try testing.expect(seg.hdr.flags.syn and seg.hdr.flags.ack);
    try testing.expectEqualStrings("hi", seg.payload);
}

test "tcp: 选项编码/解析（MSS + WS + SACK-permitted，4 字节对齐）" {
    const opts = Options{ .mss = 1460, .window_scale = 7, .sack_permitted = true };
    try testing.expectEqual(@as(usize, 12), optionsByteLen(opts));
    var buf: [64]u8 = undefined;
    const n = try encode(.{ .src_port = 1, .dst_port = 2, .flags = .{ .syn = true } }, opts, "", &buf);
    try testing.expectEqual(@as(usize, 32), n);
    const seg = try parse(buf[0..n]);
    try testing.expectEqual(@as(u4, 8), seg.hdr.data_offset);
    try testing.expectEqual(@as(?u16, 1460), seg.opts.mss);
    try testing.expectEqual(@as(?u8, 7), seg.opts.window_scale);
    try testing.expect(seg.opts.sack_permitted);
    try testing.expectEqual(@as(usize, 12), seg.opts.bytes);
}

test "tcp: 未知选项按长度跳过，EOL 之后全是填充" {
    const buf = [_]u8{ 99, 6, 0, 0, 0, 0, 2, 4, 0x05, 0xb4, 0, 0 };
    const opts = try parseOptions(&buf);
    try testing.expectEqual(@as(?u16, 1460), opts.mss);
    try testing.expectEqual(@as(?u8, null), opts.window_scale);
}

test "tcp: 非法选项长度被拒绝" {
    const bad = [_]u8{ 2, 3, 0, 0 }; // MSS 必须是 4
    try testing.expectError(error.BadOption, parseOptions(&bad));
    const short = [_]u8{2};
    try testing.expectError(error.BadOption, parseOptions(&short));
    const ws = [_]u8{ 3, 3, 15, 1 }; // shift > 14
    try testing.expectError(error.BadOption, parseOptions(&ws));
}

test "tcp: data offset < 5 与截断被拒绝" {
    var buf: [20]u8 = @splat(0);
    buf[12] = 0x40; // offset 4
    try testing.expectError(error.BadOffset, parse(&buf));
    const short: [19]u8 = @splat(0);
    try testing.expectError(error.Truncated, parse(&short));
}

test "tcp: seq 回绕比较（0xFFFFFFF0 < 0x10 为真）" {
    try testing.expect(seqLt(0xFFFF_FFF0, 0x0000_0010));
    try testing.expect(!seqLt(0x0000_0010, 0xFFFF_FFF0));
    try testing.expect(seqGt(0x0000_0010, 0xFFFF_FFF0));
    try testing.expectEqual(@as(i32, 0x20), seqDiff(0x0000_0010, 0xFFFF_FFF0));
    try testing.expectEqual(@as(i32, -0x20), seqDiff(0xFFFF_FFF0, 0x0000_0010));
    // 半程规则：相差正好 2^31 时不算“之后”
    try testing.expect(!seqLt(0, 0x8000_0000));
    try testing.expect(!seqGt(0, 0x8000_0000));
    try testing.expect(seqInRange(0x0000_0005, 0xFFFF_FFF0, 0x20));
    try testing.expect(!seqInRange(0x20, 0xFFFF_FFF0, 0x20));
}

test "tcp: MSS 分段（3000 字节 / MSS 1460 → 3 段）" {
    var plan: [8]Slice = undefined;
    const n = planSegments(1000, 3000, 1460, &plan);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 0), plan[0].offset);
    try testing.expectEqual(@as(usize, 1460), plan[0].len);
    try testing.expectEqual(@as(u32, 1000), plan[0].seq);
    try testing.expectEqual(@as(usize, 1460), plan[1].offset);
    try testing.expectEqual(@as(u32, 2460), plan[1].seq);
    try testing.expectEqual(@as(usize, 2920), plan[2].offset);
    try testing.expectEqual(@as(usize, 80), plan[2].len);
    try testing.expectEqual(@as(u32, 3920), plan[2].seq);

    const one = planSegments(7, 100, 1460, &plan);
    try testing.expectEqual(@as(usize, 1), one);
    try testing.expectEqual(@as(usize, 100), plan[0].len);
}

test "tcp: RFC 6298 RTO 估计（初值 1s、K=4、钳制）" {
    var rto = Rto{};
    try testing.expectEqual(INITIAL_RTO_US, rto.rto_us);
    rto.sample(2_000_000);
    try testing.expectEqual(@as(u64, 2_000_000), rto.srtt_us);
    try testing.expectEqual(@as(u64, 1_000_000), rto.rttvar_us);
    try testing.expectEqual(@as(u64, 6_000_000), rto.rto_us); // 2s + 4*1s

    rto.sample(1_000_000);
    try testing.expectEqual(@as(u64, 1_875_000), rto.srtt_us); // (7*2+1)/8
    try testing.expectEqual(@as(u64, 1_000_000), rto.rttvar_us); // (3*1+1)/4
    try testing.expectEqual(@as(u64, 5_875_000), rto.rto_us);

    var tiny = Rto{};
    tiny.sample(10_000); // 10ms → 计算值 30ms，必须被抬到 1s
    try testing.expectEqual(MIN_RTO_US, tiny.rto_us);

    tiny.backoff();
    try testing.expectEqual(@as(u64, 2_000_000), tiny.rto_us);
    var huge = Rto{ .rto_us = MAX_RTO_US };
    huge.backoff();
    try testing.expectEqual(MAX_RTO_US, huge.rto_us);
}

test "tcp: 三次握手（主动）" {
    var conn = Conn{};
    const syn = conn.activeOpen(0x1000, 0);
    try testing.expectEqual(State.syn_sent, conn.state);
    try testing.expect(syn.send and syn.flags.syn and !syn.flags.ack);
    try testing.expectEqual(@as(u32, 0x1000), syn.seq);

    var buf: [64]u8 = undefined;
    const n = try encode(.{
        .src_port = 80,
        .dst_port = 5000,
        .seq = 0x9000,
        .ack = 0x1001,
        .flags = .{ .syn = true, .ack = true },
        .window = 65535,
    }, .{ .mss = 1460 }, "", &buf);
    const seg = try parse(buf[0..n]);
    const ack = conn.onSegment(seg, 1_000);
    try testing.expectEqual(State.established, conn.state);
    try testing.expectEqual(@as(u32, 0x1001), conn.snd_una);
    try testing.expectEqual(@as(u32, 0x9001), conn.rcv_nxt);
    try testing.expectEqual(@as(u16, 1460), conn.mss);
    try testing.expect(ack.send and ack.flags.ack and !ack.flags.syn);
    try testing.expectEqual(@as(u32, 0x9001), ack.ack);
    try testing.expectEqual(@as(u32, 0x1001), ack.seq);
    try testing.expect(!conn.timer.active);
}

test "tcp: 三次握手（被动）" {
    var conn = Conn{};
    conn.listen(0x2000);
    try testing.expectEqual(State.listen, conn.state);

    var buf: [64]u8 = undefined;
    var n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x7000, .flags = .{ .syn = true }, .window = 1024 }, .{ .mss = 1400 }, "", &buf);
    const syn_ack = conn.onSegment(try parse(buf[0..n]), 0);
    try testing.expectEqual(State.syn_rcvd, conn.state);
    try testing.expectEqual(@as(u32, 0x7001), conn.rcv_nxt);
    try testing.expectEqual(@as(u16, 1400), conn.mss);
    try testing.expect(syn_ack.send and syn_ack.flags.syn and syn_ack.flags.ack);

    n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x7001, .ack = 0x2001, .flags = .{ .ack = true } }, .{}, "", &buf);
    const done = conn.onSegment(try parse(buf[0..n]), 10);
    try testing.expectEqual(State.established, conn.state);
    try testing.expect(!done.send); // 第三次握手不带数据时不回包
    try testing.expect(!conn.timer.active);
}

test "tcp: 乱序到达的有界重组（后段先到，交付后逐字节相同）" {
    var reasm = Reasm.init(1000);
    var out: [512]u8 = undefined;

    const a: [100]u8 = blk: {
        var tmp: [100]u8 = undefined;
        for (&tmp, 0..) |*b, i| b.* = @intCast(i % 251);
        break :blk tmp;
    };
    const b: [100]u8 = blk: {
        var tmp: [100]u8 = undefined;
        for (&tmp, 0..) |*x, i| x.* = @intCast((i + 100) % 251);
        break :blk tmp;
    };

    // 后段先到：只进槽，不交付。
    try testing.expectEqual(@as(usize, 0), reasm.insert(1100, &b, &out));
    try testing.expectEqual(@as(usize, 100), reasm.pendingBytes());
    // 前段到达：一次交付 200 字节。
    try testing.expectEqual(@as(usize, 200), reasm.insert(1000, &a, &out));
    try testing.expectEqual(@as(u32, 1200), reasm.expect);
    try testing.expectEqual(@as(usize, 0), reasm.pendingBytes());

    var expected: [200]u8 = undefined;
    @memcpy(expected[0..100], &a);
    @memcpy(expected[100..200], &b);
    try testing.expectEqualSlices(u8, expected[0..200], out[0..200]);
    try testing.expectEqual(@as(u32, 0), reasm.dropped);
}

test "tcp: 重复段不重复交付；重叠段裁掉前缀" {
    var reasm = Reasm.init(100);
    var out: [64]u8 = undefined;
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expectEqual(@as(usize, 8), reasm.insert(100, &data, &out));
    try testing.expectEqual(@as(usize, 0), reasm.insert(100, &data, &out));
    try testing.expectEqual(@as(usize, 0), reasm.insert(96, &data, &out));
    // 从 104 开始、长 8 的重叠段：前 4 字节已在 104..108 交付过，只交后 4 字节。
    try testing.expectEqual(@as(usize, 4), reasm.insert(104, &data, &out));
    try testing.expectEqual(@as(u32, 112), reasm.expect);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, out[0..4]);
}

test "tcp: 重组槽满时丢最老段（有界设计）" {
    var reasm = Reasm.init(0);
    var out: [64]u8 = undefined;
    const one = [_]u8{0xAA};
    var i: u32 = 0;
    while (i < SLOTS + 2) : (i += 1) {
        try testing.expectEqual(@as(usize, 0), reasm.insert(100 + i * 10, &one, &out));
    }
    try testing.expectEqual(@as(u32, 2), reasm.dropped);
    try testing.expectEqual(@as(usize, SLOTS), reasm.pendingBytes());
}

test "tcp: 单段丢失触发 RTO 重传，退避且 Karn 拒绝其样本" {
    var conn = Conn{};
    _ = conn.activeOpen(0x100, 0);
    var buf: [64]u8 = undefined;
    const n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9000, .ack = 0x101, .flags = .{ .syn = true, .ack = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 1000);
    try testing.expectEqual(State.established, conn.state);

    const rto_before = conn.rto.rto_us;
    _ = conn.sendData(100, 1000);
    try testing.expectEqual(@as(u32, 0x101 + 100), conn.snd_max);

    // 未到点：没有动作。
    var act = conn.tick(1000 + rto_before - 1);
    try testing.expect(!act.send);

    act = conn.tick(1000 + rto_before);
    try testing.expect(act.send and act.retransmit);
    try testing.expectEqual(@as(u32, 0x101), act.seq); // go-back-N：从 snd_una 重发
    try testing.expectEqual(@as(usize, 100), act.payload_len);
    try testing.expectEqual(rto_before * 2, conn.rto.rto_us);
    try testing.expectEqual(@as(u32, 1), conn.timer.retries);
    // Karn：重传后的样本必须被拒。
    try testing.expect(!conn.sampleRtt(500));
    try testing.expectEqual(rto_before * 2, conn.rto.rto_us);

    // ACK 到齐后停表、清空未确认长度。
    const ackn = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9001, .ack = 0x101 + 100, .flags = .{ .ack = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..ackn]), 9000);
    try testing.expect(conn.allAcked());
    try testing.expect(!conn.timer.active);
}

test "tcp: 三个重复 ACK 触发快速重传" {
    var conn = Conn{};
    var buf: [64]u8 = undefined;
    var n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9000, .ack = 0x101, .flags = .{ .syn = true, .ack = true } }, .{}, "", &buf);
    _ = conn.activeOpen(0x100, 0);
    _ = conn.onSegment(try parse(buf[0..n]), 1000);
    _ = conn.sendData(100, 1000);

    var act = Action{};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9001, .ack = 0x101, .flags = .{ .ack = true } }, .{}, "", &buf);
        act = conn.onSegment(try parse(buf[0..n]), 2000 + i);
    }
    try testing.expectEqual(@as(u32, 1), conn.fast_retransmits);
    try testing.expect(act.send and act.retransmit);
    try testing.expectEqual(@as(u32, 0x101), act.seq);
}

test "tcp: 主动关闭走 FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT → CLOSED" {
    var conn = Conn{};
    var buf: [64]u8 = undefined;
    var n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9000, .ack = 0x101, .flags = .{ .syn = true, .ack = true } }, .{}, "", &buf);
    _ = conn.activeOpen(0x100, 0);
    _ = conn.onSegment(try parse(buf[0..n]), 0);
    try testing.expectEqual(State.established, conn.state);

    const fin = conn.appClose(1000);
    try testing.expectEqual(State.fin_wait_1, conn.state);
    try testing.expect(fin.flags.fin and fin.flags.ack);
    const fin_seq = fin.seq;

    // 对方 ACK 我们的 FIN → FIN_WAIT_2
    n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9001, .ack = fin_seq + 1, .flags = .{ .ack = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 2000);
    try testing.expectEqual(State.fin_wait_2, conn.state);

    // 对方 FIN → TIME_WAIT，并回 ACK
    n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9001, .ack = fin_seq + 1, .flags = .{ .fin = true, .ack = true } }, .{}, "", &buf);
    const ackfin = conn.onSegment(try parse(buf[0..n]), 3000);
    try testing.expectEqual(State.time_wait, conn.state);
    try testing.expect(ackfin.send and ackfin.flags.ack);
    try testing.expectEqual(@as(u32, 0x9002), ackfin.ack);

    // 2MSL 用注入时钟判定：差 1 µs 还在 TIME_WAIT，到点回 CLOSED。
    try testing.expectEqual(State.time_wait, conn.tick(3000 + TIME_WAIT_US - 1).to);
    try testing.expectEqual(State.time_wait, conn.state);
    _ = conn.tick(3000 + TIME_WAIT_US);
    try testing.expectEqual(State.closed, conn.state);
}

test "tcp: 被动关闭 CLOSE_WAIT → LAST_ACK → CLOSED" {
    var conn = Conn{};
    conn.listen(0x3000);
    var buf: [64]u8 = undefined;
    var n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x8000, .flags = .{ .syn = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 0);
    n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x8001, .ack = 0x3001, .flags = .{ .ack = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 0);
    try testing.expectEqual(State.established, conn.state);

    // 对方先 FIN：我方 ESTABLISHED → CLOSE_WAIT
    n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x8001, .ack = 0x3001, .flags = .{ .fin = true, .ack = true } }, .{}, "", &buf);
    const ack = conn.onSegment(try parse(buf[0..n]), 100);
    try testing.expectEqual(State.close_wait, conn.state);
    try testing.expectEqual(@as(u32, 0x8002), ack.ack);
    try testing.expectEqual(@as(u32, 0x8002), conn.rcv_nxt);

    // 应用关闭 → LAST_ACK
    const fin = conn.appClose(200);
    try testing.expectEqual(State.last_ack, conn.state);
    try testing.expect(fin.flags.fin);

    n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x8002, .ack = fin.seq + 1, .flags = .{ .ack = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 300);
    try testing.expectEqual(State.closed, conn.state);
    try testing.expect(!conn.timer.active);
}

test "tcp: RST 在任何状态立刻回 CLOSED 且不回包" {
    var conn = Conn{};
    conn.listen(0x4000);
    var buf: [64]u8 = undefined;
    var n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x8000, .flags = .{ .syn = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 0);
    try testing.expectEqual(State.syn_rcvd, conn.state);

    n = try encode(.{ .src_port = 5000, .dst_port = 80, .seq = 0x8001, .flags = .{ .rst = true } }, .{}, "", &buf);
    const act = conn.onSegment(try parse(buf[0..n]), 10);
    try testing.expectEqual(State.closed, conn.state);
    try testing.expect(!act.send);
    try testing.expect(!conn.timer.active);
}

test "tcp: 从 ESTABLISHED 收到 RST 也立刻关闭（丢弃未确认数据）" {
    var conn = Conn{};
    var buf: [64]u8 = undefined;
    var n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9000, .ack = 0x101, .flags = .{ .syn = true, .ack = true } }, .{}, "", &buf);
    _ = conn.activeOpen(0x100, 0);
    _ = conn.onSegment(try parse(buf[0..n]), 0);
    _ = conn.sendData(50, 0);
    try testing.expect(!conn.allAcked());

    n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9001, .ack = 0x101, .flags = .{ .rst = true, .ack = true } }, .{}, "", &buf);
    const act = conn.onSegment(try parse(buf[0..n]), 10);
    try testing.expectEqual(State.closed, conn.state);
    try testing.expect(!act.send);
    try testing.expectEqual(@as(usize, 0), conn.unacked_len);
    try testing.expectEqual(@as(u32, 0), conn.timer.retries);
}

test "tcp: 同时关闭走 CLOSING（双方 FIN 竞争）" {
    var conn = Conn{};
    var buf: [64]u8 = undefined;
    // 先正常建立（SYN_SENT → ESTABLISHED），再让双方同时发 FIN：
    // 我方 appClose 进 FIN_WAIT_1，随后收到对端 FIN 且它还没 ACK 我方 FIN。
    var n = try encode(.{ .src_port = 5000, .dst_port = 5000, .seq = 0x9000, .ack = 0x101, .flags = .{ .syn = true, .ack = true } }, .{}, "", &buf);
    _ = conn.activeOpen(0x100, 0);
    _ = conn.onSegment(try parse(buf[0..n]), 0);
    const fin = conn.appClose(100); // 我方 FIN_WAIT_1
    try testing.expectEqual(State.fin_wait_1, conn.state);
    // 对方 FIN 先到、但尚未 ACK 我方 FIN → CLOSING
    n = try encode(.{ .src_port = 5000, .dst_port = 5000, .seq = 0x9001, .ack = 0x101, .flags = .{ .fin = true, .ack = true } }, .{}, "", &buf);
    const ack = conn.onSegment(try parse(buf[0..n]), 200);
    try testing.expectEqual(State.closing, conn.state);
    try testing.expect(ack.send);
    try testing.expectEqual(@as(u32, 0x9002), conn.rcv_nxt);
    // ACK 到齐后进 TIME_WAIT
    n = try encode(.{ .src_port = 5000, .dst_port = 5000, .seq = 0x9002, .ack = fin.seq + 1, .flags = .{ .ack = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 300);
    try testing.expectEqual(State.time_wait, conn.state);
}

test "tcp: TIME_WAIT 里收到重传 FIN 会重发 ACK 并重置 2MSL" {
    var conn = Conn{};
    var buf: [64]u8 = undefined;
    var n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9000, .ack = 0x101, .flags = .{ .syn = true, .ack = true } }, .{}, "", &buf);
    _ = conn.activeOpen(0x100, 0);
    _ = conn.onSegment(try parse(buf[0..n]), 0);
    const fin = conn.appClose(1000);
    n = try encode(.{ .src_port = 80, .dst_port = 5000, .seq = 0x9001, .ack = fin.seq + 1, .flags = .{ .fin = true, .ack = true } }, .{}, "", &buf);
    _ = conn.onSegment(try parse(buf[0..n]), 2000);
    try testing.expectEqual(State.time_wait, conn.state);
    const deadline = conn.time_wait_until_us;

    const again = conn.onSegment(try parse(buf[0..n]), 2000 + 1_000_000);
    try testing.expectEqual(State.time_wait, conn.state);
    try testing.expect(again.send);
    try testing.expect(conn.time_wait_until_us > deadline);
}
