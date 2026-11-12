//! ch22-socket-api-event-loop：可注入的报文源（没有网卡也能驱动 socket 层）。
//!
//! 本章板侧**不碰网口**：ch17 的以太网驱动尚未闭环，`netstub` 就是那条
//! “假网线”。它做三件事：
//!
//!   1. **线格式**：把一段 TCP 段编码成字节串（10 字节首部 + 载荷），
//!      再解回来。编码/解码是纯整数操作，没有对齐假设、没有字节序歧义
//!      （首部里所有 32 位字段显式小端）。
//!   2. **脚本**：一串已经编码好的段，按顺序 `next()` 吐出来。脚本本身是
//!      普通的字节缓冲，所以“重放”就是“再从头走一遍”，指纹必须一致。
//!   3. **指纹**：FNV-1a 32 位，用来做“同一脚本两次运行结果相同”的判据。
//!
//! 为什么不是“构造真实的以太网帧/IPv4 报文”？因为那会把 ch18/ch20 的首部
//! 布局拖进本章的依赖图，而本章要验证的是 **socket 层的契约**：状态迁移、
//! 就绪集、EAGAIN、部分读写、连接池上限。段是本章自己的抽象——
//! 与 ch20 的同名状态机只是**签名级对应**，不是同一份实现。
//!
//! 线格式（共 10 字节首部，全部小端）：
//!
//! ```text
//!   偏移  0       kind      1 字节（1=syn 2=syn_ack 3=ack 4=data 5=fin 6=rst）
//!         1..4    seq       u32
//!         5..8    ack       u32
//!         9       len       1 字节 = 载荷长度（≤ max_payload）
//! ```
//!
//! 真实 TCP 首部是 20 字节起，这里刻意压到 10：本章只需要“种类 + 序号 +
//! 确认号 + 载荷”，其余字段（窗口、校验和、选项）属于 ch20 的范围。

const std = @import("std");

pub const header_len: usize = 10;
/// 单段载荷上限。板侧的所有脚本缓冲都是静态的，128 字节 × 若干段刚刚好；
/// 更大的数据用多次 `data` 段（这也更接近真实分片）。
pub const max_payload: usize = 128;
/// 一段编码后的最大长度。
pub const max_segment: usize = header_len + max_payload;

pub const Kind = enum(u8) {
    syn = 1,
    syn_ack = 2,
    ack = 3,
    data = 4,
    fin = 5,
    rst = 6,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }

    fn fromByte(b: u8) ?Kind {
        return switch (b) {
            1 => .syn,
            2 => .syn_ack,
            3 => .ack,
            4 => .data,
            5 => .fin,
            6 => .rst,
            else => null,
        };
    }
};

pub const Segment = struct {
    kind: Kind,
    seq: u32 = 0,
    ack: u32 = 0,
    /// 指向调用方缓冲，不复制：编码后立即投递，生命周期由调用方保证。
    payload: []const u8 = &.{},

    pub fn wireLen(self: Segment) usize {
        return header_len + self.payload.len;
    }
};

pub const DecodeError = error{
    TooShort,
    UnknownKind,
    LengthMismatch,
};

fn put32(dst: []u8, v: u32) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
    dst[2] = @truncate(v >> 16);
    dst[3] = @truncate(v >> 24);
}

fn get32(src: []const u8) u32 {
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) |
        (@as(u32, src[3]) << 24);
}

/// 编码到 `out`，返回写入字节数。`out` 不够长时返回 0（不做部分写入：
/// 半截段在接收侧无法分辨，宁可让调用方一眼看到 0）。
pub fn encode(seg: Segment, out: []u8) usize {
    const need = seg.wireLen();
    if (out.len < need or seg.payload.len > max_payload) return 0;
    out[0] = @backingInt(seg.kind);
    put32(out[1..5], seg.seq);
    put32(out[5..9], seg.ack);
    out[9] = @intCast(seg.payload.len);
    @memcpy(out[header_len..need], seg.payload);
    return need;
}

/// 从字节串解出一段。`bytes` 可以比一段长（脚本连续排布），只看第一段。
pub fn decode(bytes: []const u8) DecodeError!Segment {
    if (bytes.len < header_len) return error.TooShort;
    const kind = Kind.fromByte(bytes[0]) orelse return error.UnknownKind;
    const plen: usize = bytes[9];
    if (plen > max_payload) return error.LengthMismatch;
    if (bytes.len < header_len + plen) return error.LengthMismatch;
    return .{
        .kind = kind,
        .seq = get32(bytes[1..5]),
        .ack = get32(bytes[5..9]),
        .payload = bytes[header_len .. header_len + plen],
    };
}

/// FNV-1a 32：指纹用，不是校验和。
pub fn fnv1a(seed: u32, bytes: []const u8) u32 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x0100_0193;
    }
    return h;
}

pub const fnv_offset: u32 = 0x811c_9dc5;

/// 顺序脚本：一段接一段地喂给 socket 层。
///
/// 这个结构是“注入源”的最小形态：不持有缓冲（`bytes` 由调用方提供），
/// 只记住读到哪。把它放在 `.bss`/栈上都是一次性开销。
pub const Script = struct {
    bytes: []const u8,
    at: usize = 0,
    /// 脚本里是否出现过解码失败（自检据此否决“脚本本身写错了”）。
    errors: u32 = 0,

    pub fn remaining(self: *const Script) usize {
        return if (self.at >= self.bytes.len) 0 else self.bytes.len - self.at;
    }

    pub fn next(self: *Script) ?Segment {
        if (self.at >= self.bytes.len) return null;
        const seg = decode(self.bytes[self.at..]) catch {
            self.errors += 1;
            self.at = self.bytes.len;
            return null;
        };
        self.at += seg.wireLen();
        return seg;
    }

    pub fn rewind(self: *Script) void {
        self.at = 0;
    }

    /// 顺序消费整条脚本，返回 (段数, 累计载荷字节, 指纹)。
    ///
    /// 指纹覆盖每一段的 **kind + seq + ack + 载荷长度 + 载荷字节**，
    /// 所以"改脚本中间某个字段 → 指纹必变"，而不只是"段种类变了才变"。
    /// 重放（`rewind` 后再 `drain`）必须得到同一个值——两个方向都有用例。
    pub fn drain(self: *Script) struct { segs: u32, payload: u32, hash: u32 } {
        var segs: u32 = 0;
        var payload: u32 = 0;
        var hash: u32 = fnv_offset;
        while (self.next()) |seg| {
            segs += 1;
            payload += @intCast(seg.payload.len);
            var head: [9]u8 = undefined;
            head[0] = @backingInt(seg.kind);
            put32(head[1..5], seg.seq);
            put32(head[5..9], seg.ack);
            hash = fnv1a(hash, &head);
            hash = fnv1a(hash, &[_]u8{@intCast(seg.payload.len)});
            hash = fnv1a(hash, seg.payload);
        }
        return .{ .segs = segs, .payload = payload, .hash = hash };
    }
};

// ---------------------------------------------------------------------------
// 主机侧单测：线格式往返、边界、脚本重放确定性
// ---------------------------------------------------------------------------

test "线格式：编码与解码往返，载荷逐字节一致" {
    const payload = "GET / HTTP/1.0\r\n\r\n";
    var buf: [max_segment]u8 = undefined;
    const n = encode(.{ .kind = .data, .seq = 0x11223344, .ack = 0x55667788, .payload = payload }, &buf);
    try std.testing.expectEqual(header_len + payload.len, n);
    // 显式小端：第一个字节是 kind，seq 的 LSB 紧跟在后面。
    try std.testing.expectEqual(@as(u8, 4), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x44), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x88), buf[5]);

    const seg = try decode(buf[0..n]);
    try std.testing.expectEqual(Kind.data, seg.kind);
    try std.testing.expectEqual(@as(u32, 0x11223344), seg.seq);
    try std.testing.expectEqual(@as(u32, 0x55667788), seg.ack);
    try std.testing.expectEqualStrings(payload, seg.payload);
}

test "线格式：截断、未知种类、长度不符都被拒绝" {
    var buf: [max_segment]u8 = undefined;
    const n = encode(.{ .kind = .fin, .seq = 7 }, &buf);
    try std.testing.expect(n == header_len);
    try std.testing.expectError(error.TooShort, decode(buf[0..5]));

    var bad_kind = buf;
    bad_kind[0] = 9;
    try std.testing.expectError(error.UnknownKind, decode(bad_kind[0..n]));

    var bad_len = buf;
    bad_len[9] = 20;
    try std.testing.expectError(error.LengthMismatch, decode(bad_len[0..n]));
}

test "线格式：out 太短时 encode 返回 0，不写半截" {
    var small: [4]u8 = undefined;
    const n = encode(.{ .kind = .syn, .seq = 1 }, &small);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "脚本：顺序吐段，重放后指纹一致，越界返回 null" {
    var buf: [3 * max_segment]u8 = undefined;
    var at: usize = 0;
    at += encode(.{ .kind = .syn, .seq = 100 }, buf[at..]);
    at += encode(.{ .kind = .data, .seq = 101, .payload = "abc" }, buf[at..]);
    at += encode(.{ .kind = .fin, .seq = 104 }, buf[at..]);

    var script = Script{ .bytes = buf[0..at] };
    const first = script.drain();
    try std.testing.expectEqual(@as(u32, 3), first.segs);
    try std.testing.expectEqual(@as(u32, 3), first.payload);
    try std.testing.expect(script.remaining() == 0);
    try std.testing.expect(script.next() == null);

    script.rewind();
    const second = script.drain();
    try std.testing.expectEqual(first.hash, second.hash);
    try std.testing.expectEqual(@as(u32, 0), script.errors);
}

test "脚本指纹：改动任意一段的 kind/seq/载荷都会改变指纹，重放则不变" {
    var buf: [3 * max_segment]u8 = undefined;
    var at: usize = 0;
    at += encode(.{ .kind = .syn, .seq = 100 }, buf[at..]);
    at += encode(.{ .kind = .data, .seq = 101, .ack = 5, .payload = "abc" }, buf[at..]);
    at += encode(.{ .kind = .fin, .seq = 104 }, buf[at..]);

    var base = Script{ .bytes = buf[0..at] };
    const h0 = base.drain().hash;
    base.rewind();
    try std.testing.expectEqual(h0, base.drain().hash);

    // 段布局：syn 占 [0,10)，data 占 [10,23)（载荷在 [20,23)），fin 占 [23,33)。
    // 只改载荷（等长、同 seq/ack）：指纹必须变。
    var only_payload = buf;
    only_payload[2 * header_len] = 'X';
    var s1 = Script{ .bytes = only_payload[0..at] };
    try std.testing.expect(s1.drain().hash != h0);

    // 只改中间段的 seq（小端首字节）：指纹必须变。
    var only_seq = buf;
    only_seq[header_len + 1] = 0x7f;
    var s2 = Script{ .bytes = only_seq[0..at] };
    try std.testing.expect(s2.drain().hash != h0);
}
