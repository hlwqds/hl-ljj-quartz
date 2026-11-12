//! ch18-ipv4-icmp-arp-routing：ICMPv4 的四种报文与回显。
//!
//! 本章只实现 `ping` 闭环真正需要的四件事：
//!
//!   - **type 8 / 0**：回显请求 / 应答（`ping` 的全部）；
//!   - **type 3 code 4**：目的不可达 / 需要分片（PMTU 发现的唯一来源，RFC 1191）；
//!   - 校验和验证（ICMP 的校验和覆盖**整个报文**，不含 IP 伪首部）；
//!   - 应答策略：目的地址是广播/多播时**可以静默丢弃**（RFC 1122 §3.2.2.6
//!     是 MAY）；本工程选择丢弃，否则一个 `ping 192.168.1.255` 就能把整个
//!     网段变成放大器。
//!
//! ## 三条容易写错的规则
//!
//! 1. ICMP 校验和**没有伪首部**（那是 UDP/TCP 的东西）。把伪首部加进来，
//!    `ping` 会一直"checksum bad"。
//! 2. 错误报文（type 3/11/12）必须带上**触发它的原始 IP 首部 + 至少 8 字节
//!    载荷**（RFC 792）。少带了，对端就无法把错误关联到某条连接。
//! 3. 回显应答要原样带回 `id`、`seq` 与载荷；只改 type 与校验和。
//!    自行改写 id/seq 会让 `ping` 的丢包统计全线错位。

const std = @import("std");
const inet = @import("inet.zig");
const ipv4 = @import("ipv4.zig");

/// ICMP 类型号（RFC 792 / RFC 1191）。
pub const typ = struct {
    pub const echo_reply: u8 = 0;
    pub const dest_unreachable: u8 = 3;
    pub const echo_request: u8 = 8;
    pub const time_exceeded: u8 = 11;
};

/// type 3 里的 code。只有 code 4 携带"下一跳 MTU"字段。
pub const code = struct {
    pub const net_unreachable: u8 = 0;
    pub const host_unreachable: u8 = 1;
    pub const frag_needed: u8 = 4;
};

pub const header_len = 8;

/// RFC 792：错误报文必须引用原始数据报的"首部 + 8 字节"，共 28 字节。
pub const quote_len = ipv4.min_header_len + 8;

pub const Error = error{
    Truncated,
    ShortBuffer,
    NotEcho,
    NotError,
    BadType,
};

/// ICMP 首部的 8 个字节。`id`/`seq` 与 `unused`/`mtu` 共用同一段位置：
/// 回显报文用 id/seq，错误报文用 unused/mtu。这里给两个字段起名并说明复用。
pub const Header = struct {
    type: u8 = typ.echo_request,
    code: u8 = 0,
    checksum: u16 = 0,
    /// 回显：标识符（ping 的进程号）。错误报文：unused，固定 0。
    id: u16 = 0,
    /// 回显：序号。`type=3 code=4`：下一跳 MTU（RFC 1191）。
    seq_or_mtu: u16 = 0,

    pub fn write(self: *Header, buf: []u8) Error!usize {
        if (buf.len < header_len) return error.ShortBuffer;
        buf[0] = self.type;
        buf[1] = self.code;
        std.mem.writeInt(u16, buf[2..4], 0, .big);
        std.mem.writeInt(u16, buf[4..6], self.id, .big);
        std.mem.writeInt(u16, buf[6..8], self.seq_or_mtu, .big);
        self.checksum = inet.of(buf[0..header_len]);
        std.mem.writeInt(u16, buf[2..4], self.checksum, .big);
        return header_len;
    }

    pub fn parse(buf: []const u8) Error!Header {
        if (buf.len < header_len) return error.Truncated;
        return .{
            .type = buf[0],
            .code = buf[1],
            .checksum = std.mem.readInt(u16, buf[2..4], .big),
            .id = std.mem.readInt(u16, buf[4..6], .big),
            .seq_or_mtu = std.mem.readInt(u16, buf[6..8], .big),
        };
    }
};

pub fn isErrorType(t: u8) bool {
    return switch (t) {
        typ.dest_unreachable, typ.time_exceeded, 4, 5, 12 => true, // 3/11/12 是错误；4/5 是已废弃的源抑制/重定向
        else => false,
    };
}

/// 校验和自验证：`bytes` 必须是**恰好**这段 ICMP 报文（首部+数据），
/// 不能把以太网填充也算进来。
pub fn checksumOk(bytes: []const u8) bool {
    return bytes.len >= header_len and inet.verify(bytes);
}

/// 写一个回显请求（type 8）。校验和覆盖 8 字节首部 + `payload`。
pub fn writeEchoRequest(buf: []u8, id: u16, seq: u16, payload: []const u8) Error!usize {
    return writeEcho(typ.echo_request, buf, id, seq, payload);
}

/// 写一个回显应答（type 0）。
pub fn writeEchoReply(buf: []u8, id: u16, seq: u16, payload: []const u8) Error!usize {
    return writeEcho(typ.echo_reply, buf, id, seq, payload);
}

fn writeEcho(t: u8, buf: []u8, id: u16, seq: u16, payload: []const u8) Error!usize {
    const total = header_len + payload.len;
    if (buf.len < total) return error.ShortBuffer;
    buf[0] = t;
    buf[1] = 0;
    std.mem.writeInt(u16, buf[2..4], 0, .big);
    std.mem.writeInt(u16, buf[4..6], id, .big);
    std.mem.writeInt(u16, buf[6..8], seq, .big);
    @memcpy(buf[header_len..total], payload);
    const c = inet.of(buf[0..total]);
    std.mem.writeInt(u16, buf[2..4], c, .big);
    return total;
}

/// 从收到的回显请求就地生成应答：拷贝 `request` 到 `out`，
/// 把 type 从 8 改成 0，重算校验和。**id/seq/载荷一字不改。**
///
/// 这是 `ping` 的服务端全部逻辑：不需要解析 id/seq，也不需要知道载荷内容。
pub fn echoReplyFrom(request: []const u8, out: []u8) Error![]const u8 {
    if (request.len < header_len) return error.Truncated;
    if (request[0] != typ.echo_request) return error.NotEcho;
    if (out.len < request.len) return error.ShortBuffer;
    @memcpy(out[0..request.len], request);
    out[0] = typ.echo_reply;
    std.mem.writeInt(u16, out[2..4], 0, .big);
    const c = inet.of(out[0..request.len]);
    std.mem.writeInt(u16, out[2..4], c, .big);
    return out[0..request.len];
}

/// 应答策略（RFC 1122 §3.2.2.6 的 MAY）：目的地址是广播或多播的回显请求
/// 可以静默丢弃。本工程选择丢弃——不丢就是反射放大器。（RFC 1122 §4.2.3.10
/// 是 TCP 的同类规则，不适用于 ICMP。）
pub fn mayReply(dst_is_broadcast: bool, dst_is_multicast: bool) bool {
    return !(dst_is_broadcast or dst_is_multicast);
}

/// 写 `type 3 code 4`（fragmentation needed and DF set），
/// 把触发它的原始 IP 报文的前 28 字节抄进去。
pub fn writeFragNeeded(buf: []u8, original: []const u8, mtu: u16) Error!usize {
    const copy_len: usize = @min(original.len, quote_len);
    const total: usize = header_len + copy_len;
    if (buf.len < total) return error.ShortBuffer;
    buf[0] = typ.dest_unreachable;
    buf[1] = code.frag_needed;
    std.mem.writeInt(u16, buf[2..4], 0, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big); // unused
    std.mem.writeInt(u16, buf[6..8], mtu, .big);
    if (copy_len > 0) @memcpy(buf[header_len..total], original[0..copy_len]);
    const c = inet.of(buf[0..total]);
    std.mem.writeInt(u16, buf[2..4], c, .big);
    return total;
}

/// 从收到的 ICMP 报文里取出下一跳 MTU。只接受 `type 3 code 4`。
/// MTU 字段为 0 表示老式（不支持 PMTU 发现）的路由器，由 `Pmtu.learn`
/// 按 RFC 1191 §4 折算成 576。
pub fn parseFragNeeded(bytes: []const u8) Error!u16 {
    const h = try Header.parse(bytes);
    if (h.type != typ.dest_unreachable or h.code != code.frag_needed) return error.NotError;
    return h.seq_or_mtu;
}

/// 把 ICMP 报文里的被引用报文段取出来（`[8..]`），用于把错误关联到连接。
pub fn quoted(bytes: []const u8) Error![]const u8 {
    if (bytes.len < header_len) return error.Truncated;
    return bytes[header_len..];
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "icmp: 回显请求往返，校验和覆盖载荷" {
    var buf: [64]u8 = undefined;
    const payload = "zig-s31-ping";
    const n = try writeEchoRequest(&buf, 0x1234, 7, payload);
    try testing.expectEqual(@as(usize, 8 + payload.len), n);
    try testing.expect(checksumOk(buf[0..n]));

    const h = try Header.parse(buf[0..n]);
    try testing.expectEqual(typ.echo_request, h.type);
    try testing.expectEqual(@as(u16, 0x1234), h.id);
    try testing.expectEqual(@as(u16, 7), h.seq_or_mtu);
    try testing.expectEqualStrings(payload, buf[8..n]);
}

test "icmp: 应答只改 type 与校验和，id/seq/载荷原样带回" {
    var req: [64]u8 = undefined;
    const rn = try writeEchoRequest(&req, 0x4711, 42, "abcdefg");
    var rep: [64]u8 = undefined;
    const reply = try echoReplyFrom(req[0..rn], &rep);

    try testing.expect(reply.len <= rep.len);
    try testing.expectEqual(typ.echo_reply, reply[0]);
    try testing.expect(checksumOk(reply));
    try testing.expectEqual(@as(u16, 0x4711), std.mem.readInt(u16, reply[4..6], .big));
    try testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, reply[6..8], .big));
    try testing.expectEqualStrings("abcdefg", reply[8..]);
    try testing.expectEqual(req.len, rep.len);
}

test "icmp: 非回显请求不能生成应答" {
    var buf: [32]u8 = undefined;
    const n = try writeEchoReply(&buf, 1, 1, "x");
    var out: [32]u8 = undefined;
    try testing.expectError(error.NotEcho, echoReplyFrom(buf[0..n], &out));
}

test "icmp: 奇数字节载荷的校验和仍然自洽" {
    var buf: [32]u8 = undefined;
    const n = try writeEchoRequest(&buf, 0x0102, 9, "12345");
    try testing.expect(checksumOk(buf[0..n]));
    // 破坏一个字节 → 校验失败
    buf[8] ^= 0xFF;
    try testing.expect(!checksumOk(buf[0..n]));
}

test "icmp: 零长度载荷的回显（只有 8 字节首部）" {
    var buf: [8]u8 = undefined;
    const n = try writeEchoRequest(&buf, 1, 2, "");
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expect(checksumOk(buf[0..n]));
    const h = try Header.parse(&buf);
    try testing.expectEqual(@as(u16, 2), h.seq_or_mtu);
}

test "icmp: 缓冲区不足时报 ShortBuffer，不越界" {
    var small: [8]u8 = undefined;
    try testing.expectError(error.ShortBuffer, writeEchoRequest(&small, 1, 1, "x"));
    try testing.expectError(error.Truncated, Header.parse(small[0..4]));
}

test "icmp: frag needed 携带下一跳 MTU 与 28 字节引用" {
    var orig: [60]u8 = undefined;
    var oh = ipv4.Header{ .total_len = 60, .id = 0x7777, .df = true, .protocol = ipv4.proto.udp };
    _ = try oh.write(&orig);

    var buf: [64]u8 = undefined;
    const n = try writeFragNeeded(&buf, &orig, 1400);
    try testing.expectEqual(@as(usize, 8 + quote_len), n);
    try testing.expect(checksumOk(buf[0..n]));
    try testing.expectEqual(typ.dest_unreachable, buf[0]);
    try testing.expectEqual(code.frag_needed, buf[1]);
    try testing.expectEqual(@as(u16, 1400), try parseFragNeeded(buf[0..n]));
    try testing.expectEqualSlices(u8, orig[0..28], try quoted(buf[0..n]));
}

test "icmp: 原始报文不足 28 字节时按实际长度引用" {
    var orig: [20]u8 = undefined;
    var oh = ipv4.Header{ .total_len = 20, .id = 1, .protocol = ipv4.proto.icmp };
    _ = try oh.write(&orig);
    var buf: [32]u8 = undefined;
    const n = try writeFragNeeded(&buf, &orig, 1200);
    try testing.expectEqual(@as(usize, 8 + 20), n);
    try testing.expect(checksumOk(buf[0..n]));
    try testing.expectEqual(@as(usize, 20), (try quoted(buf[0..n])).len);
}

test "icmp: parseFragNeeded 拒绝其它 ICMP 报文" {
    var buf: [16]u8 = undefined;
    const n = try writeEchoRequest(&buf, 1, 1, "abc");
    try testing.expectError(error.NotError, parseFragNeeded(buf[0..n]));
}

test "icmp: 错误类型分类与应答策略" {
    try testing.expect(isErrorType(typ.dest_unreachable));
    try testing.expect(isErrorType(typ.time_exceeded));
    try testing.expect(!isErrorType(typ.echo_request));
    try testing.expect(!isErrorType(typ.echo_reply));
    try testing.expect(mayReply(false, false));
    try testing.expect(!mayReply(true, false));
    try testing.expect(!mayReply(false, true));
}
