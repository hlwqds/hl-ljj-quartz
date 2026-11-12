//! ch19-udp-dhcp-dns：UDP 数据报的封装/解包、伪首部校验和与端口复用表。
//!
//! UDP 只有 8 字节首部（RFC 768），却承载了本章两个主角：DHCP（67/68）与
//! DNS（53）。它的三个字段各有各的坑：
//!
//!   1. **length** 是“UDP 首部 + 载荷”的长度，不是 IP 载荷长度，也不是
//!      缓冲区长度。三者必须逐一对得上，否则解析出来的载荷就是错的；
//!   2. **checksum 可以是 0**：IPv4 下 0 表示“发送方没算”。接收方此时应该
//!      放行而不是当成校验失败——这是与 TCP 相反的一处；
//!   3. **计算结果是 0 时要发 0xFFFF**：因为 0 已经被“没算”占用了。
//!
//! ## 为什么这里要自己写 `Sum`
//!
//! ch16 的 `checksum.zig` 已经有一份 RFC 1071 求和；本章工程要求**独立可编**，
//! 所以这里只保留 UDP 需要的部分（跨片求和 + 伪首部 + 0/0xFFFF 规则）。
//! 两章的口径必须一致：分片边界不等于 16 位字边界，落单的半个字要留在
//! `odd` 里等下一片。这一点由「分片流式求和等于连续缓冲求和」的用例钉死。
//!
//! ## 校验和的复核判据
//!
//! 发送方算完把结果写进首部；接收方**不需要**把字段清零重算，而是把
//! “伪首部 + 整个数据报（含已填的校验和字段）”再求一次反码和：
//! 结果必须折叠成 `0x0000`。板侧自检打印的 `verified=1` 就是这个判据，
//! 它比“算出来的数字看起来对”可靠得多——因为它同时覆盖了伪首部字段。

const std = @import("std");

pub const Error = error{ Truncated, BadLength };

/// UDP 首部固定 8 字节。
pub const Header = struct {
    pub const len = 8;

    src_port: u16,
    dst_port: u16,
    /// `UDP 首部 + 载荷` 的字节数（含 8 字节首部本身）。
    length: u16,
    /// 只读回填：`write` 原样写出，`seal` 负责计算。
    checksum_value: u16 = 0,

    pub fn write(self: Header, buf: []u8) Error![]u8 {
        if (buf.len < len) return error.Truncated;
        std.mem.writeInt(u16, buf[0..2], self.src_port, .big);
        std.mem.writeInt(u16, buf[2..4], self.dst_port, .big);
        std.mem.writeInt(u16, buf[4..6], self.length, .big);
        std.mem.writeInt(u16, buf[6..8], self.checksum_value, .big);
        return buf[0..len];
    }

    pub fn parse(buf: []const u8) Error!Header {
        if (buf.len < len) return error.Truncated;
        const h = Header{
            .src_port = std.mem.readInt(u16, buf[0..2], .big),
            .dst_port = std.mem.readInt(u16, buf[2..4], .big),
            .length = std.mem.readInt(u16, buf[4..6], .big),
            .checksum_value = std.mem.readInt(u16, buf[6..8], .big),
        };
        if (h.length < len) return error.BadLength;
        return h;
    }

    /// 载荷视图：`dgram[8..length]`，不复制。缓冲区必须真的这么长。
    pub fn payload(self: Header, dgram: []const u8) Error![]const u8 {
        if (self.length < len) return error.BadLength;
        if (dgram.len < self.length) return error.Truncated;
        return dgram[len..self.length];
    }
};

/// 流式 16 位反码和。`add` 的调用边界可以是 pbuf 边界，字节流按连续处理。
pub const Sum = struct {
    acc: u32 = 0,
    /// 上一段落单的高字节（等与本段第一字节配对）。
    odd: ?u8 = null,

    fn absorb(self: *Sum, word: u16) void {
        self.acc += word;
        self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
    }

    pub fn add(self: *Sum, bytes: []const u8) void {
        var i: usize = 0;
        if (self.odd) |hi| {
            if (bytes.len == 0) return;
            self.absorb((@as(u16, hi) << 8) | bytes[0]);
            i = 1;
            self.odd = null;
        }
        while (i + 1 < bytes.len) : (i += 2) {
            self.absorb((@as(u16, bytes[i]) << 8) | bytes[i + 1]);
        }
        if (i < bytes.len) self.odd = bytes[i];
    }

    pub fn addWord(self: *Sum, word: u16) void {
        self.absorb(word);
    }

    pub fn finish(self: Sum) u16 {
        var acc = self.acc;
        if (self.odd) |lo| acc += @as(u16, lo) << 8;
        while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
        return @truncate(~acc);
    }
};

/// IPv4 伪首部（RFC 768 引用 RFC 791 的定义）：
/// src(4) + dst(4) + zero(1) + protocol(1) + udp_length(2)。
/// zero+protocol 在 16 位字里是 `0x0011`（17 = UDP）。
pub fn pseudo(src: [4]u8, dst: [4]u8, length: u16) Sum {
    var s = Sum{};
    s.add(&src);
    s.add(&dst);
    s.addWord(0x0011);
    s.addWord(length);
    return s;
}

/// 计算校验和：`dgram` 里第 6..8 字节必须已经是 0。
/// 结果 0 按 RFC 768 换成 `0xFFFF`。
pub fn checksumOf(src: [4]u8, dst: [4]u8, dgram: []const u8) Error!u16 {
    if (dgram.len < Header.len) return error.Truncated;
    if (dgram.len > 0xFFFF) return error.BadLength;
    var s = pseudo(src, dst, @intCast(dgram.len));
    s.add(dgram);
    return finalize(s.finish());
}

/// RFC 768 的 0 替换规则单独成函数，好让它能被直接测：
/// 反码和算出的 0 与“发送方没算”共用同一个字段值，必须改成 0xFFFF。
pub fn finalize(raw: u16) u16 {
    return if (raw == 0) 0xFFFF else raw;
}

/// 一次写完 length 与 checksum。数据报长度必须 <= 65535。
pub fn seal(src: [4]u8, dst: [4]u8, dgram: []u8) Error!void {
    if (dgram.len < Header.len) return error.Truncated;
    if (dgram.len > 0xFFFF) return error.BadLength;
    std.mem.writeInt(u16, dgram[4..6], @intCast(dgram.len), .big);
    std.mem.writeInt(u16, dgram[6..8], 0, .big);
    const sum = try checksumOf(src, dst, dgram);
    std.mem.writeInt(u16, dgram[6..8], sum, .big);
}

/// 接收方三态：字段为 0（未计算）、复核通过、复核失败。
pub const Verdict = enum { absent, ok, bad };

pub fn check(src: [4]u8, dst: [4]u8, dgram: []const u8) Verdict {
    const h = Header.parse(dgram) catch return .bad;
    if (h.checksum_value == 0) return .absent;
    if (h.length > dgram.len) return .bad;
    var s = pseudo(src, dst, h.length);
    s.add(dgram[0..h.length]);
    return if (s.finish() == 0) .ok else .bad;
}

// ---------------------------------------------------------------------------
// 端口复用：一张静态表 + 三种分派结局
//
// 真实协议栈的 socket 层在 ch22；这里只需要证明“目的端口 → 处理者”这一步
// 是可判读的。三种结局必须显式区分，不能把“没人监听”和“报文畸形”混成
// 同一个丢弃计数——前者是正常的（ICMP port unreachable 的来源），后者是
// 对端/线路的问题。
// ---------------------------------------------------------------------------

pub const Handler = enum { echo, dhcp_client, dhcp_server, dns_client };

pub const Demux = struct {
    pub const max_ports = 12;
    pub const BindError = error{ PortInUse, TableFull, InvalidPort };

    const Entry = struct { port: u16 = 0, handler: Handler = .echo, used: bool = false };

    entries: [max_ports]Entry = @splat(.{}),

    pub fn bind(self: *Demux, port: u16, handler: Handler) BindError!void {
        if (port == 0) return error.InvalidPort;
        for (&self.entries) |*e| {
            if (e.used and e.port == port) return error.PortInUse;
        }
        for (&self.entries) |*e| {
            if (!e.used) {
                e.* = .{ .port = port, .handler = handler, .used = true };
                return;
            }
        }
        return error.TableFull;
    }

    pub fn unbind(self: *Demux, port: u16) bool {
        for (&self.entries) |*e| {
            if (e.used and e.port == port) {
                e.used = false;
                return true;
            }
        }
        return false;
    }

    pub fn lookup(self: *const Demux, port: u16) ?Handler {
        for (self.entries) |e| {
            if (e.used and e.port == port) return e.handler;
        }
        return null;
    }

    pub fn used(self: *const Demux) usize {
        var n: usize = 0;
        for (self.entries) |e| n += @intFromBool(e.used);
        return n;
    }

    pub const Outcome = union(enum) {
        delivered: Handler,
        unbound: u16,
        malformed,
    };

    pub fn dispatch(self: *const Demux, dgram: []const u8) Outcome {
        const h = Header.parse(dgram) catch return .malformed;
        if (h.length > dgram.len) return .malformed;
        if (self.lookup(h.dst_port)) |handler| return .{ .delivered = handler };
        return .{ .unbound = h.dst_port };
    }
};

// ---------------------------------------------------------------------------
// 主机侧用例
// ---------------------------------------------------------------------------

const testing = std.testing;

test "udp: 8 字节首部按大端写入与读回" {
    var buf: [16]u8 = @splat(0);
    const h = Header{ .src_port = 0x1234, .dst_port = 0x0053, .length = 8 + 5 };
    const out = try h.write(&buf);
    try testing.expectEqual(@as(usize, 8), out.len);
    try testing.expectEqual(@as(u8, 0x12), buf[0]);
    try testing.expectEqual(@as(u8, 0x34), buf[1]);
    try testing.expectEqual(@as(u8, 0x00), buf[2]);
    try testing.expectEqual(@as(u8, 0x53), buf[3]);
    try testing.expectEqual(@as(u8, 0x00), buf[4]);
    try testing.expectEqual(@as(u8, 0x0d), buf[5]);

    const back = try Header.parse(&buf);
    try testing.expectEqual(h.src_port, back.src_port);
    try testing.expectEqual(h.dst_port, back.dst_port);
    try testing.expectEqual(h.length, back.length);
}

test "udp: 解析拒绝短于 8 字节的缓冲区" {
    var buf: [7]u8 = @splat(0);
    try testing.expectError(error.Truncated, Header.parse(&buf));
}

test "udp: length 小于首部长度即拒绝" {
    var buf: [8]u8 = @splat(0);
    std.mem.writeInt(u16, buf[4..6], 7, .big);
    try testing.expectError(error.BadLength, Header.parse(&buf));
}

test "udp: 载荷视图必须落在 length 之内" {
    var buf: [64]u8 = @splat(0);
    const h = Header{ .src_port = 1, .dst_port = 2, .length = 12 };
    _ = try h.write(&buf);
    @memcpy(buf[8..12], "abcd");
    // 缓冲区后面还有垃圾字节：payload 只能取 4 字节。
    try testing.expectEqualStrings("abcd", try h.payload(&buf));

    // length 声称 40 而缓冲区只有 20：必须拒绝，不能越界读。
    const lie = Header{ .src_port = 1, .dst_port = 2, .length = 40 };
    try testing.expectError(error.Truncated, lie.payload(buf[0..20]));
}

test "udp: 伪首部校验和的五元组全是 16 位字" {
    const src = [4]u8{ 192, 168, 1, 10 };
    const dst = [4]u8{ 192, 168, 1, 1 };
    var dgram: [12]u8 = @splat(0);
    const h = Header{ .src_port = 40000, .dst_port = 7, .length = 12 };
    _ = try h.write(&dgram);
    @memcpy(dgram[8..12], "ping");

    try seal(src, dst, &dgram);
    try testing.expectEqual(Verdict.ok, check(src, dst, &dgram));
}

test "udp: 校验和为 0 的字段按“未计算”放行（RFC 768）" {
    const src = [4]u8{ 10, 0, 0, 2 };
    const dst = [4]u8{ 10, 0, 0, 1 };
    var dgram: [11]u8 = @splat(0);
    const h = Header{ .src_port = 68, .dst_port = 67, .length = 11 };
    _ = try h.write(&dgram);
    std.mem.writeInt(u16, dgram[6..8], 0, .big);
    try testing.expectEqual(Verdict.absent, check(src, dst, &dgram));
}

test "udp: 求和恰为 0xFFFF 时发送 0xFFFF（RFC 768，端到端）" {
    // finalize() 本身：0 必须先被换成 0xFFFF，否则会被读成“没算”。
    try testing.expectEqual(@as(u16, 0xFFFF), finalize(0));
    try testing.expectEqual(@as(u16, 0x1234), finalize(0x1234));

    // 真的走到那条分支：构造“伪首部 + 首部 + 1 个整字载荷”之和恰为 0xFFFF 的
    // 数据报。先算前两部分，再令载荷字 = 0xFFFF - P，于是反码和为 0。
    const src = [4]u8{ 10, 1, 2, 3 };
    const dst = [4]u8{ 10, 1, 2, 4 };
    var dgram: [10]u8 = @splat(0); // 8 字节首部 + 2 字节载荷（整字）
    const h = Header{ .src_port = 5353, .dst_port = 53, .length = 10 };
    _ = try h.write(&dgram);

    var s = pseudo(src, dst, 10);
    s.add(dgram[0..6]); // 首部前 6 字节；校验和字段为 0，对求和无贡献
    s.add(dgram[8..10]); // 载荷此时仍是 0
    var acc = s.acc;
    if (s.odd) |lo| acc += @as(u16, lo) << 8;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    const need: u16 = 0xFFFF -% @as(u16, @truncate(acc));
    std.mem.writeInt(u16, dgram[8..10], need, .big);

    // 未替换时反码和是 0，按 RFC 768 必须发 0xFFFF。
    try testing.expectEqual(@as(u16, 0xFFFF), try checksumOf(src, dst, &dgram));
    try seal(src, dst, &dgram);
    try testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, dgram[6..8], .big));
    try testing.expectEqual(Verdict.ok, check(src, dst, &dgram));
}

test "udp: 奇数字节载荷跨片求和等于连续缓冲求和" {
    const src = [4]u8{ 172, 16, 0, 5 };
    const dst = [4]u8{ 172, 16, 0, 9 };
    var whole: [8 + 7]u8 = @splat(0);
    const h = Header{ .src_port = 5353, .dst_port = 53, .length = 15 };
    _ = try h.write(&whole);
    @memcpy(whole[8..15], "zig/s31");
    const expect = try checksumOf(src, dst, &whole);

    // 同一个字节流切成 8 + 3 + 4：分片边界必须对结果无影响。
    var s = pseudo(src, dst, 15);
    s.add(whole[0..8]);
    s.add(whole[8..11]);
    s.add(whole[11..15]);
    try testing.expectEqual(expect, s.finish());
}

test "udp: 单字节翻转被校验和抓住" {
    const src = [4]u8{ 192, 168, 0, 2 };
    const dst = [4]u8{ 192, 168, 0, 3 };
    var dgram: [16]u8 = @splat(0);
    const h = Header{ .src_port = 1234, .dst_port = 9999, .length = 16 };
    _ = try h.write(&dgram);
    @memcpy(dgram[8..16], "01234567");
    try seal(src, dst, &dgram);
    try testing.expectEqual(Verdict.ok, check(src, dst, &dgram));

    dgram[12] ^= 0x01;
    try testing.expectEqual(Verdict.bad, check(src, dst, &dgram));
}

test "udp: 伪首部里的地址参与校验（换源地址必须失败）" {
    const src = [4]u8{ 192, 168, 1, 10 };
    const dst = [4]u8{ 192, 168, 1, 1 };
    var dgram: [8]u8 = @splat(0);
    const h = Header{ .src_port = 68, .dst_port = 67, .length = 8 };
    _ = try h.write(&dgram);
    try seal(src, dst, &dgram);
    try testing.expectEqual(Verdict.ok, check(src, dst, &dgram));

    const wrong = [4]u8{ 192, 168, 1, 11 };
    try testing.expectEqual(Verdict.bad, check(wrong, dst, &dgram));
}

test "udp: 端口复用表拒绝重复绑定与 0 端口" {
    var d: Demux = .{};
    try d.bind(67, .dhcp_server);
    try testing.expectError(error.PortInUse, d.bind(67, .echo));
    try testing.expectError(error.InvalidPort, d.bind(0, .echo));
    try d.bind(53, .dns_client);
    try testing.expectEqual(@as(usize, 2), d.used());
    try testing.expectEqual(Handler.dns_client, d.lookup(53).?);
    try testing.expect(d.unbind(53));
    try testing.expect(!d.unbind(53));
    try testing.expectEqual(@as(?Handler, null), d.lookup(53));
}

test "udp: 端口表满时报 TableFull，不覆盖已有绑定" {
    var d: Demux = .{};
    var port: u16 = 1000;
    while (port < 1000 + Demux.max_ports) : (port += 1) {
        try d.bind(port, .echo);
    }
    try testing.expectError(error.TableFull, d.bind(2000, .echo));
    try testing.expectEqual(Handler.echo, d.lookup(1000).?);
}

test "udp: 分派区分 delivered / unbound / malformed" {
    var d: Demux = .{};
    try d.bind(68, .dhcp_client);

    var dgram: [8]u8 = @splat(0);
    const h = Header{ .src_port = 67, .dst_port = 68, .length = 8 };
    _ = try h.write(&dgram);
    const hit = d.dispatch(&dgram);
    try testing.expectEqual(Handler.dhcp_client, hit.delivered);

    var miss_buf: [8]u8 = @splat(0);
    const m = Header{ .src_port = 67, .dst_port = 69, .length = 8 };
    _ = try m.write(&miss_buf);
    const miss = d.dispatch(&miss_buf);
    try testing.expectEqual(@as(u16, 69), miss.unbound);

    // length 声称得比缓冲区大：畸形，而不是“没人监听”。
    var bad: [8]u8 = @splat(0);
    const bh = Header{ .src_port = 1, .dst_port = 68, .length = 64 };
    _ = try bh.write(&bad);
    try testing.expectEqual(Demux.Outcome.malformed, d.dispatch(&bad));
}
