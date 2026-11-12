//! ch16-stack-architecture-zero-copy：以太网 / IPv4 / UDP / TCP 首部的编解码。
//!
//! 这个模块只做两件事：把结构体变成**网络字节序**的字节，或者反过来。
//! 它不做路由、不做分片、不做状态机——那些属于 ch18/ch19/ch20。
//!
//! ## 为什么首部解析要“严格”
//!
//! 真实网络里遇到的畸形包远比想象的多：版本号写成 6 的、IHL 小于 5 的、
//! `total_length` 比首部还短的、以太网帧被交换机截断的。解析函数必须**拒绝**
//! 它们（返回错误），而不是用默认值猜。协议栈的安全边界就是从这些检查开始的：
//!
//!   1. `len >= 20`（IPv4 最小首部）、`version == 4`、`ihl >= 5`；
//!   2. `ihl * 4 <= total_length`（首部不能比整包长）；
//!   3. `total_length <= buf.len`（缓冲区里必须真的有这么多字节）；
//!   4. UDP/TCP 的端口与长度字段一律按大端读，长度小于首部即拒绝。
//!
//! ## 零拷贝的边界
//!
//! `parse` 返回的是**值**（20 字节左右的小结构），不持有缓冲区；
//! payload 通过 `buf[header_len..total_len]` 这个切片暴露，仍然是原缓冲的视图。
//! 想把它挂到 pbuf 链上时，用 `frames.buildIpv4`（见 netif/frames）而不是复制。

const std = @import("std");
const checksum = @import("checksum.zig");

pub const Error = error{
    Truncated,
    BadVersion,
    BadIhl,
    BadLength,
    BadOffset,
    Unsupported,
};

/// 以太网 II 帧的 EtherType。非穷尽枚举：未识别的值保留下来供上层丢弃统计。
pub const EtherType = enum(u16) {
    ipv4 = 0x0800,
    arp = 0x0806,
    ipv6 = 0x86DD,
    _,
};

/// 14 字节以太网 II 首部。没有 802.1Q VLAN 标签（那会在 0x8100 之上再加 4 字节）。
pub const Eth = struct {
    pub const len = 14;

    dst: [6]u8,
    src: [6]u8,
    ethertype: EtherType,

    pub fn write(self: Eth, buf: []u8) Error![]u8 {
        if (buf.len < len) return error.Truncated;
        @memcpy(buf[0..6], &self.dst);
        @memcpy(buf[6..12], &self.src);
        std.mem.writeInt(u16, buf[12..14], @intFromEnum(self.ethertype), .big);
        return buf[0..len];
    }

    pub fn parse(buf: []const u8) Error!Eth {
        if (buf.len < len) return error.Truncated;
        var eth: Eth = undefined;
        @memcpy(&eth.dst, buf[0..6]);
        @memcpy(&eth.src, buf[6..12]);
        eth.ethertype = @enumFromInt(std.mem.readInt(u16, buf[12..14], .big));
        return eth;
    }
};

/// 分片标志位（首部第 7 个字节的高 3 位）。打包位序是 LSB 在前，
/// 因此字段顺序必须是 mf → df → reserved。
pub const FragFlags = packed struct(u3) {
    mf: bool = false,
    df: bool = false,
    reserved: bool = false,
};

pub const Protocol = enum(u8) {
    icmp = 1,
    tcp = 6,
    udp = 17,
    _,
};

/// IPv4 首部（不含选项；选项只体现在 `ihl` 与 `headerLen()` 里）。
pub const Ipv4 = struct {
    pub const min_len = 20;

    version: u4 = 4,
    ihl: u4 = 5,
    dscp: u6 = 0,
    ecn: u2 = 0,
    total_len: u16,
    id: u16 = 0,
    flags: FragFlags = .{ .df = true },
    frag_offset: u13 = 0,
    ttl: u8 = 64,
    protocol: Protocol = .udp,
    /// 只读回填：`write` 会计算并写入，`parse` 原样读出。
    checksum_value: u16 = 0,
    src: [4]u8,
    dst: [4]u8,

    pub fn headerLen(self: Ipv4) usize {
        return @as(usize, self.ihl) * 4;
    }

    pub fn payloadLen(self: Ipv4) usize {
        return @as(usize, self.total_len) - self.headerLen();
    }

    /// 写 20 字节固定首部并计算校验和。选项字节由调用方在返回长度之后自行填充
    /// （本章没有给 IPv4 选项建模，理由见 16.5）。
    pub fn write(self: *Ipv4, buf: []u8) Error!usize {
        if (buf.len < min_len) return error.Truncated;
        self.version = 4;
        self.ihl = 5;
        buf[0] = (@as(u8, self.version) << 4) | @as(u8, self.ihl);
        buf[1] = (@as(u8, self.dscp) << 2) | @as(u8, self.ecn);
        std.mem.writeInt(u16, buf[2..4], self.total_len, .big);
        std.mem.writeInt(u16, buf[4..6], self.id, .big);
        const frag: u16 = (@as(u16, @as(u3, @bitCast(self.flags))) << 13) |
            @as(u16, self.frag_offset);
        std.mem.writeInt(u16, buf[6..8], frag, .big);
        buf[8] = self.ttl;
        buf[9] = @intFromEnum(self.protocol);
        std.mem.writeInt(u16, buf[10..12], 0, .big); // 计算前必须清零
        @memcpy(buf[12..16], &self.src);
        @memcpy(buf[16..20], &self.dst);
        self.checksum_value = checksum.ipv4Header(buf[0..min_len]);
        std.mem.writeInt(u16, buf[10..12], self.checksum_value, .big);
        return min_len;
    }

    pub fn parse(buf: []const u8) Error!Ipv4 {
        if (buf.len < min_len) return error.Truncated;
        const version: u4 = @truncate(buf[0] >> 4);
        const ihl: u4 = @truncate(buf[0] & 0x0F);
        if (version != 4) return error.BadVersion;
        if (ihl < 5) return error.BadIhl;

        const total_len = std.mem.readInt(u16, buf[2..4], .big);
        const header_len = @as(usize, ihl) * 4;
        if (total_len < header_len) return error.BadLength;
        if (total_len > buf.len) return error.Truncated;
        if (header_len > buf.len) return error.Truncated;

        const frag = std.mem.readInt(u16, buf[6..8], .big);
        var ip: Ipv4 = undefined;
        ip.version = version;
        ip.ihl = ihl;
        ip.dscp = @truncate(buf[1] >> 2);
        ip.ecn = @truncate(buf[1] & 0x03);
        ip.total_len = total_len;
        ip.id = std.mem.readInt(u16, buf[4..6], .big);
        ip.flags = @bitCast(@as(u3, @truncate(frag >> 13)));
        ip.frag_offset = @truncate(frag & 0x1FFF);
        ip.ttl = buf[8];
        ip.protocol = @enumFromInt(buf[9]);
        ip.checksum_value = std.mem.readInt(u16, buf[10..12], .big);
        @memcpy(&ip.src, buf[12..16]);
        @memcpy(&ip.dst, buf[16..20]);
        return ip;
    }

    /// 校验和验证：整首部的反码和为 0 表示正确。返回 false 即为坏包。
    pub fn verifyChecksum(self: Ipv4, buf: []const u8) bool {
        const hlen = self.headerLen();
        if (buf.len < hlen) return false;
        return checksum.of(buf[0..hlen]) == 0;
    }

    /// 载荷视图（原缓冲的切片，不复制）。
    pub fn payload(self: Ipv4, buf: []const u8) Error![]const u8 {
        const hlen = self.headerLen();
        if (buf.len < self.total_len or hlen > self.total_len) return error.Truncated;
        return buf[hlen..self.total_len];
    }
};

/// UDP 首部（8 字节）。
pub const Udp = struct {
    pub const len = 8;

    src_port: u16,
    dst_port: u16,
    length: u16,
    checksum_value: u16 = 0,

    pub fn write(self: Udp, buf: []u8) Error![]u8 {
        if (buf.len < len) return error.Truncated;
        std.mem.writeInt(u16, buf[0..2], self.src_port, .big);
        std.mem.writeInt(u16, buf[2..4], self.dst_port, .big);
        std.mem.writeInt(u16, buf[4..6], self.length, .big);
        std.mem.writeInt(u16, buf[6..8], self.checksum_value, .big);
        return buf[0..len];
    }

    pub fn parse(buf: []const u8) Error!Udp {
        if (buf.len < len) return error.Truncated;
        const length = std.mem.readInt(u16, buf[4..6], .big);
        if (length < len) return error.BadLength;
        return .{
            .src_port = std.mem.readInt(u16, buf[0..2], .big),
            .dst_port = std.mem.readInt(u16, buf[2..4], .big),
            .length = length,
            .checksum_value = std.mem.readInt(u16, buf[6..8], .big),
        };
    }
};

/// TCP 标志位（首部第 14 个字节的低 8 位），LSB 在前。
pub const TcpFlags = packed struct(u8) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,
};

/// TCP 首部（20 字节，无选项）。
pub const Tcp = struct {
    pub const min_len = 20;

    src_port: u16 = 0,
    dst_port: u16 = 0,
    seq: u32 = 0,
    ack: u32 = 0,
    data_offset: u4 = 5,
    flags: TcpFlags = .{},
    window: u16 = 0,
    checksum_value: u16 = 0,
    urgent: u16 = 0,

    pub fn headerLen(self: Tcp) usize {
        return @as(usize, self.data_offset) * 4;
    }

    pub fn write(self: Tcp, buf: []u8) Error![]u8 {
        if (buf.len < min_len) return error.Truncated;
        std.mem.writeInt(u16, buf[0..2], self.src_port, .big);
        std.mem.writeInt(u16, buf[2..4], self.dst_port, .big);
        std.mem.writeInt(u32, buf[4..8], self.seq, .big);
        std.mem.writeInt(u32, buf[8..12], self.ack, .big);
        const off_flags: u16 = (@as(u16, self.data_offset) << 12) |
            @as(u16, @as(u8, @bitCast(self.flags)));
        std.mem.writeInt(u16, buf[12..14], off_flags, .big);
        std.mem.writeInt(u16, buf[14..16], self.window, .big);
        std.mem.writeInt(u16, buf[16..18], self.checksum_value, .big);
        std.mem.writeInt(u16, buf[18..20], self.urgent, .big);
        return buf[0..min_len];
    }

    pub fn parse(buf: []const u8) Error!Tcp {
        if (buf.len < min_len) return error.Truncated;
        const off_flags = std.mem.readInt(u16, buf[12..14], .big);
        const data_offset: u4 = @truncate(off_flags >> 12);
        if (data_offset < 5) return error.BadOffset;
        if (@as(usize, data_offset) * 4 > buf.len) return error.Truncated;
        return .{
            .src_port = std.mem.readInt(u16, buf[0..2], .big),
            .dst_port = std.mem.readInt(u16, buf[2..4], .big),
            .seq = std.mem.readInt(u32, buf[4..8], .big),
            .ack = std.mem.readInt(u32, buf[8..12], .big),
            .data_offset = data_offset,
            .flags = @bitCast(@as(u8, @truncate(off_flags & 0xFF))),
            .window = std.mem.readInt(u16, buf[14..16], .big),
            .checksum_value = std.mem.readInt(u16, buf[16..18], .big),
            .urgent = std.mem.readInt(u16, buf[18..20], .big),
        };
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "eth: 14 字节首部的双向编解码" {
    const eth = Eth{
        .dst = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        .src = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 },
        .ethertype = .ipv4,
    };
    var buf: [16]u8 = undefined;
    const out = try eth.write(&buf);
    try testing.expectEqual(@as(usize, 14), out.len);
    try testing.expectEqual(@as(u8, 0x08), buf[12]);
    try testing.expectEqual(@as(u8, 0x00), buf[13]);

    const back = try Eth.parse(&buf);
    try testing.expectEqualSlices(u8, &eth.dst, &back.dst);
    try testing.expectEqualSlices(u8, &eth.src, &back.src);
    try testing.expectEqual(EtherType.ipv4, back.ethertype);
}

test "eth: 未知 EtherType 保留原值，短帧被拒绝" {
    var buf: [14]u8 = @splat(0);
    buf[12] = 0x90;
    buf[13] = 0x00; // 0x9000：未知
    const eth = try Eth.parse(&buf);
    try testing.expectEqual(@as(u16, 0x9000), @intFromEnum(eth.ethertype));
    try testing.expectError(error.Truncated, Eth.parse(buf[0..13]));
}

test "ipv4: 写出的首部能被解析回来，校验和字段自洽" {
    var ip = Ipv4{
        .total_len = 33,
        .id = 0x1c46,
        .flags = .{ .df = true },
        .ttl = 64,
        .protocol = .udp,
        .src = .{ 192, 168, 1, 10 },
        .dst = .{ 192, 168, 1, 1 },
    };
    var buf: [40]u8 = undefined;
    const n = try ip.write(&buf);
    try testing.expectEqual(@as(usize, 20), n);
    try testing.expectEqual(@as(u16, 0x9b2a), ip.checksum_value);
    try testing.expectEqual(@as(u8, 0x45), buf[0]);
    try testing.expectEqual(@as(u8, 0x40), buf[6]); // DF
    try testing.expectEqual(@as(u8, 0x40), buf[8]); // ttl 64
    try testing.expectEqual(@as(u8, 17), buf[9]);

    const back = try Ipv4.parse(buf[0..33]);
    try testing.expectEqual(@as(u16, 33), back.total_len);
    try testing.expectEqual(@as(u16, 0x1c46), back.id);
    try testing.expect(back.flags.df);
    try testing.expectEqual(@as(u13, 0), back.frag_offset);
    try testing.expectEqual(@as(usize, 20), back.headerLen());
    try testing.expectEqual(@as(usize, 13), back.payloadLen());
    try testing.expect(back.verifyChecksum(buf[0..n]));
}

test "ipv4: 首部校验和被篡改即验证失败" {
    var ip = Ipv4{
        .total_len = 20,
        .src = .{ 10, 0, 0, 1 },
        .dst = .{ 10, 0, 0, 2 },
    };
    var buf: [20]u8 = undefined;
    _ = try ip.write(&buf);
    buf[8] = 63; // 只改 TTL，不更新校验和
    const back = try Ipv4.parse(&buf);
    try testing.expect(!back.verifyChecksum(&buf));
}

test "ipv4: 带 4 字节选项（ihl=6）的解析与载荷视图" {
    var buf: [24]u8 = @splat(0);
    buf[0] = 0x46; // version 4, ihl 6
    std.mem.writeInt(u16, buf[2..4], 24, .big);
    buf[8] = 32;
    buf[9] = 1; // ICMP
    const ip = try Ipv4.parse(&buf);
    try testing.expectEqual(@as(usize, 24), ip.headerLen());
    try testing.expectEqual(@as(usize, 0), ip.payloadLen());
    const payload = try ip.payload(&buf);
    try testing.expectEqual(@as(usize, 0), payload.len);
}

test "ipv4: 拒绝版本错误、IHL<5、总长过短、缓冲区截断" {
    var buf: [20]u8 = @splat(0);
    buf[0] = 0x45;
    std.mem.writeInt(u16, buf[2..4], 20, .big);
    _ = try Ipv4.parse(&buf);

    buf[0] = 0x65; // version 6
    try testing.expectError(error.BadVersion, Ipv4.parse(&buf));
    buf[0] = 0x44; // ihl 4
    try testing.expectError(error.BadIhl, Ipv4.parse(&buf));
    buf[0] = 0x45;
    std.mem.writeInt(u16, buf[2..4], 19, .big);
    try testing.expectError(error.BadLength, Ipv4.parse(&buf));
    std.mem.writeInt(u16, buf[2..4], 21, .big); // 声称比缓冲多 1 字节
    try testing.expectError(error.Truncated, Ipv4.parse(&buf));
    try testing.expectError(error.Truncated, Ipv4.parse(buf[0..19]));
}

test "udp: 8 字节首部往返，长度小于 8 被拒绝" {
    const udp = Udp{ .src_port = 40000, .dst_port = 7, .length = 13 };
    var buf: [8]u8 = undefined;
    _ = try udp.write(&buf);
    try testing.expectEqual(@as(u8, 0x9c), buf[0]);
    try testing.expectEqual(@as(u8, 0x40), buf[1]);

    const back = try Udp.parse(&buf);
    try testing.expectEqual(@as(u16, 40000), back.src_port);
    try testing.expectEqual(@as(u16, 7), back.dst_port);
    try testing.expectEqual(@as(u16, 13), back.length);

    var bad = buf;
    std.mem.writeInt(u16, bad[4..6], 7, .big);
    try testing.expectError(error.BadLength, Udp.parse(&bad));
}

test "tcp: 标志位与 data offset 的位序（SYN=0x02, ACK=0x10）" {
    const seg = Tcp{
        .src_port = 8080,
        .dst_port = 80,
        .seq = 1,
        .flags = .{ .syn = true, .ack = true },
        .window = 8192,
    };
    var buf: [20]u8 = undefined;
    _ = try seg.write(&buf);
    try testing.expectEqual(@as(u8, 0x50), buf[12]);
    try testing.expectEqual(@as(u8, 0x12), buf[13]);

    const back = try Tcp.parse(&buf);
    try testing.expect(back.flags.syn);
    try testing.expect(back.flags.ack);
    try testing.expect(!back.flags.fin);
    try testing.expectEqual(@as(u4, 5), back.data_offset);
    try testing.expectEqual(@as(u16, 8192), back.window);
    try testing.expectEqual(@as(usize, 20), back.headerLen());
}

test "tcp: data offset < 5 被拒绝" {
    var buf: [20]u8 = @splat(0);
    buf[12] = 0x40;
    try testing.expectError(error.BadOffset, Tcp.parse(&buf));
    try testing.expectError(error.Truncated, Tcp.parse(buf[0..19]));
}
