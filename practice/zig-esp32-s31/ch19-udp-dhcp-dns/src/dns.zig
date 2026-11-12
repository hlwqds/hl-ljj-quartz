//! ch19-udp-dhcp-dns：DNS 报文的编码/解析与 A 记录缓存。
//!
//! DNS 的报文格式（RFC 1035 §4）本身很简单：12 字节头 + 问题区 + 资源记录区。
//! 真正让它成为“协议栈里最容易写崩的解析器”的是两件事：
//!
//!   1. **名字压缩**（§4.1.4）：`0xC0 | offset>>8, offset & 0xFF` 两字节指针，
//!      指向报文里更早出现过的名字。解析器必须能跟随指针，又必须保证**一定会
//!      停下来**——恶意的自指/互指指针能让天真的实现死循环；
//!   2. **大小写与 TTL**：名字比较不区分大小写（§2.3.3），TTL 是 32 位无符号
//!      但 RFC 2181 §8 规定最高位必须当 0 处理，缓存还要设自己的上限。
//!
//! ## 本模块的三条硬规矩
//!
//! - 指针只允许指向**当前位置之前**的字节。这一条同时解决了“环路”和
//!   “前向指针没意义”两个问题：任何跳转都让偏移严格变小，必然终止。
//!   仍然保留跳转次数上限，作为二道防线。
//! - 所有读取都先查边界。`Truncated` 是拒绝，不是“读到哪算哪”。
//! - 缓存键统一转小写；TTL 按 `max_ttl` 钳制（与 lwIP 的 `DNS_MAX_TTL` 同口径）。
//!
//! ## 不做的事
//!
//! 不做递归解析、不做 EDNS0（OPT 记录只跳过）、不做 AAAA 的地址语义
//! （IPv6 栈另有章节）、不生成响应报文（本章只当客户端）。

const std = @import("std");

pub const port: u16 = 53;

pub const Error = error{
    Truncated,
    LabelTooLong,
    NameTooLong,
    EmptyLabel,
    BadPointer,
    CompressionLoop,
    NotResponse,
    IdMismatch,
    RcodeFailure,
    NoAnswer,
    BadRdata,
    NameTooLongForCache,
};

pub const Rcode = enum(u4) {
    success = 0,
    format_error = 1,
    server_failure = 2,
    name_error = 3,
    not_implemented = 4,
    refused = 5,
    _,
};

pub const Type = enum(u16) {
    a = 1,
    ns = 2,
    cname = 5,
    soa = 6,
    ptr = 12,
    mx = 15,
    txt = 16,
    aaaa = 28,
    srv = 33,
    opt = 41,
    any = 255,
    _,
};

pub const Class = enum(u16) { in = 1, _ };

/// 标志字。Zig 的 packed struct 从 bit0 起算，而 RFC 1035 的图画从 bit15 起，
/// 所以字段声明顺序与文档正好**相反**：
///
/// ```text
/// bit:  15 14..11 10  9   8   7   6..4 3..0
///       QR opcode AA  TC  RD  RA  Z    RCODE
/// ```
pub const Flags = packed struct(u16) {
    rcode: u4 = 0,
    z: u3 = 0,
    ra: bool = false,
    rd: bool = false,
    tc: bool = false,
    aa: bool = false,
    opcode: u4 = 0,
    qr: bool = false,
};

pub const Header = struct {
    pub const len = 12;

    id: u16 = 0,
    flags: Flags = .{},
    qdcount: u16 = 0,
    ancount: u16 = 0,
    nscount: u16 = 0,
    arcount: u16 = 0,

    pub fn write(self: Header, buf: []u8) Error![]u8 {
        if (buf.len < len) return error.Truncated;
        std.mem.writeInt(u16, buf[0..2], self.id, .big);
        std.mem.writeInt(u16, buf[2..4], @bitCast(self.flags), .big);
        std.mem.writeInt(u16, buf[4..6], self.qdcount, .big);
        std.mem.writeInt(u16, buf[6..8], self.ancount, .big);
        std.mem.writeInt(u16, buf[8..10], self.nscount, .big);
        std.mem.writeInt(u16, buf[10..12], self.arcount, .big);
        return buf[0..len];
    }

    pub fn parse(buf: []const u8) Error!Header {
        if (buf.len < len) return error.Truncated;
        return .{
            .id = std.mem.readInt(u16, buf[0..2], .big),
            .flags = @bitCast(std.mem.readInt(u16, buf[2..4], .big)),
            .qdcount = std.mem.readInt(u16, buf[4..6], .big),
            .ancount = std.mem.readInt(u16, buf[6..8], .big),
            .nscount = std.mem.readInt(u16, buf[8..10], .big),
            .arcount = std.mem.readInt(u16, buf[10..12], .big),
        };
    }
};

/// 编码后的名字最长 255 字节（含根标签）。RFC 1035 §2.3.4。
pub const max_name_wire = 255;
/// 单个标签最长 63 字节（高两位被指针占用了）。RFC 1035 §2.3.4。
pub const max_label = 63;

/// 把 `example.com` 编码进 `buf`（从 `pos` 起），返回新的偏移。
fn encodeName(buf: []u8, pos_in: usize, name: []const u8) Error!usize {
    var pos = pos_in;
    var i: usize = 0;
    while (i < name.len) {
        const start = i;
        while (i < name.len and name[i] != '.') : (i += 1) {}
        const label = name[start..i];
        if (label.len == 0) {
            // 末尾的 "." 是合法的（表示绝对域名）；中间出现空标签则非法。
            if (i == name.len) break;
            return error.EmptyLabel;
        }
        if (label.len > max_label) return error.LabelTooLong;
        if (pos + 1 + label.len + 1 > buf.len) return error.Truncated;
        buf[pos] = @intCast(label.len);
        @memcpy(buf[pos + 1 ..][0..label.len], label);
        pos += 1 + label.len;
        if (i < name.len) i += 1; // 跳过 '.'
    }
    if (pos + 1 > buf.len) return error.Truncated;
    buf[pos] = 0;
    pos += 1;
    return pos;
}

/// 生成一个标准查询（RD=1，QDCOUNT=1）。返回报文总长度。
pub fn encodeQuery(buf: []u8, id: u16, name: []const u8, qtype: Type) Error!usize {
    if (buf.len < Header.len) return error.Truncated;
    if (name.len == 0) return error.EmptyLabel;
    const h = Header{ .id = id, .flags = .{ .rd = true }, .qdcount = 1 };
    _ = try h.write(buf);
    var pos = try encodeName(buf, Header.len, name);
    if (pos > Header.len + max_name_wire) return error.NameTooLong;
    if (pos + 4 > buf.len) return error.Truncated;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(qtype), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(Class.in), .big);
    pos += 4;
    return pos;
}

pub const NameRef = struct {
    /// 点分名字视图，落在调用方给的 `out` 缓冲里。
    name: []const u8,
    /// 名字在本层的下一字节偏移（跟随指针时不改变这个值）。
    next: usize,
};

/// 解析一个（可能压缩的）名字，写进 `out`。
///
/// `next` 永远是“名字**在当前位置**占用的字节数之后”的偏移：如果名字以指针
/// 结束，`next` 指向指针之后，而不是被指向的名字之后——这是 RFC 1035 §4.1.4
/// 的语义，也是资源记录能连续解析的前提。
pub fn decodeName(packet: []const u8, start: usize, out: []u8) Error!NameRef {
    var pos = start;
    var out_len: usize = 0;
    var next: usize = 0;
    var jumped = false;
    var jumps: u8 = 0;

    while (true) {
        if (pos >= packet.len) return error.Truncated;
        const b = packet[pos];

        if ((b & 0xC0) == 0xC0) {
            if (pos + 1 >= packet.len) return error.Truncated;
            if (jumps >= 32) return error.CompressionLoop;
            const ptr = (@as(usize, b & 0x3F) << 8) | packet[pos + 1];
            // 必须严格向前指：任何跳转都让偏移变小，环路不可能成立。
            if (ptr >= pos) return error.BadPointer;
            if (!jumped) {
                next = pos + 2;
                jumped = true;
            }
            pos = ptr;
            jumps += 1;
            continue;
        }
        if ((b & 0xC0) != 0) return error.BadPointer; // 0x40/0x80：保留的标签类型

        if (b == 0) {
            pos += 1;
            if (!jumped) next = pos;
            break;
        }

        const label_len: usize = b;
        if (label_len > max_label) return error.LabelTooLong;
        if (pos + 1 + label_len > packet.len) return error.Truncated;
        if (out_len != 0) {
            if (out_len + 1 >= out.len) return error.NameTooLong;
            out[out_len] = '.';
            out_len += 1;
        }
        if (out_len + label_len >= out.len) return error.NameTooLong;
        @memcpy(out[out_len..][0..label_len], packet[pos + 1 ..][0..label_len]);
        out_len += label_len;
        pos += 1 + label_len;
    }
    return .{ .name = out[0..out_len], .next = next };
}

pub const Record = struct {
    name_off: usize,
    rtype: Type,
    rclass: Class,
    ttl: u32,
    rdata_off: usize,
    rdlength: u16,
};

/// 解析一条资源记录的头（名字 + type/class/ttl/rdlength），不解释 rdata。
pub fn parseRecord(packet: []const u8, off: usize) Error!Record {
    var scratch: [max_name_wire]u8 = undefined;
    const nr = try decodeName(packet, off, &scratch);
    const pos = nr.next;
    if (pos + 10 > packet.len) return error.Truncated;

    const rec = Record{
        .name_off = off,
        .rtype = @enumFromInt(std.mem.readInt(u16, packet[pos..][0..2], .big)),
        .rclass = @enumFromInt(std.mem.readInt(u16, packet[pos + 2 ..][0..2], .big)),
        .ttl = std.mem.readInt(u32, packet[pos + 4 ..][0..4], .big),
        .rdlength = std.mem.readInt(u16, packet[pos + 8 ..][0..2], .big),
        .rdata_off = pos + 10,
    };
    if (@as(usize, rec.rdlength) > packet.len - rec.rdata_off) return error.Truncated;
    return rec;
}

pub const Answer = struct {
    addr: [4]u8,
    ttl: u32,
    /// 为找到 A 记录而跳过的 CNAME 条数（0 表示直接命中）。
    cname_hops: u8,
};

/// 从响应里取第一条 A 记录。
///
/// `expect_id` 为 0 表示“不检查 ID”（只用于抓包回放）。
pub fn findAnswer(packet: []const u8, expect_id: u16, out_name: []u8) Error!Answer {
    const h = try Header.parse(packet);
    if (!h.flags.qr) return error.NotResponse;
    if (expect_id != 0 and h.id != expect_id) return error.IdMismatch;
    if (h.flags.rcode != @intFromEnum(Rcode.success)) return error.RcodeFailure;
    if (h.ancount == 0) return error.NoAnswer;

    var pos: usize = Header.len;
    var scratch: [max_name_wire]u8 = undefined;

    // 跳过问题区：名字 + qtype(2) + qclass(2)。
    var q: u16 = 0;
    while (q < h.qdcount) : (q += 1) {
        const nr = try decodeName(packet, pos, &scratch);
        pos = nr.next + 4;
        if (pos > packet.len) return error.Truncated;
    }

    var hops: u8 = 0;
    var i: u16 = 0;
    while (i < h.ancount) : (i += 1) {
        const rec = try parseRecord(packet, pos);
        pos = rec.rdata_off + @as(usize, rec.rdlength);

        switch (rec.rtype) {
            .a => {
                if (rec.rclass != .in) continue;
                if (rec.rdlength != 4) return error.BadRdata;
                var addr: [4]u8 = undefined;
                @memcpy(&addr, packet[rec.rdata_off..][0..4]);
                if (out_name.len != 0) {
                    _ = decodeName(packet, rec.name_off, out_name) catch
                        NameRef{ .name = "", .next = 0 };
                }
                return .{ .addr = addr, .ttl = rec.ttl, .cname_hops = hops };
            },
            .cname => hops +|= 1,
            else => {},
        }
    }
    return error.NoAnswer;
}

// ---------------------------------------------------------------------------
// A 记录缓存
//
// 固定容量、无分配器：板侧没有堆，也不该为一个地址缓存引入分配失败路径。
// 淘汰策略是“最早到期者先走”——DNS 缓存的价值与剩余 TTL 成正比，
// 用 LRU 反而会把马上要过期、但刚刚命中的条目留下。
// ---------------------------------------------------------------------------

pub const Cache = struct {
    pub const max_entries = 8;
    pub const name_cap = 64;

    const Entry = struct {
        used: bool = false,
        len: u8 = 0,
        name: [name_cap]u8 = @splat(0),
        addr: [4]u8 = @splat(0),
        expires_at: u64 = 0,
    };

    entries: [max_entries]Entry = @splat(.{}),
    /// TTL 上限（秒）。RFC 2181 §8 规定 TTL 最高 2^31-1；lwIP 用 7 天。
    max_ttl: u32 = 604800,

    fn eqlName(stored: []const u8, query: []const u8) bool {
        if (stored.len != query.len) return false;
        for (stored, query) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
        }
        return true;
    }

    fn find(self: *Cache, name: []const u8) ?usize {
        for (&self.entries, 0..) |*e, i| {
            if (e.used and eqlName(e.name[0..e.len], name)) return i;
        }
        return null;
    }

    pub fn len(self: *const Cache) usize {
        var n: usize = 0;
        for (self.entries) |e| n += @intFromBool(e.used);
        return n;
    }

    /// 清掉已过期条目，返回清掉的数量。
    pub fn purge(self: *Cache, now: u64) u8 {
        var n: u8 = 0;
        for (&self.entries) |*e| {
            if (e.used and now >= e.expires_at) {
                e.used = false;
                n += 1;
            }
        }
        return n;
    }

    /// 写入/覆盖一条 A 记录。TTL 为 0 表示“不要缓存”（RFC 1035 §3.2.1），
    /// 此时会删掉同名旧条目而不是存一条立刻过期的记录。
    pub fn put(self: *Cache, name: []const u8, addr: [4]u8, ttl: u32, now: u64) Error!void {
        if (name.len == 0 or name.len > name_cap) return error.NameTooLongForCache;

        // RFC 2181 §8：TTL 最高位必须当 0 处理。钳制之前先归一化，
        // 否则 0x8000_0000 会被 @min 变成一个“7 天”的长缓存——与规则正相反。
        const eff = if (ttl & 0x8000_0000 != 0) 0 else ttl;

        if (eff == 0) {
            if (self.find(name)) |idx| self.entries[idx].used = false;
            return;
        }

        const slot = self.find(name) orelse blk: {
            for (&self.entries, 0..) |*e, i| {
                if (!e.used) break :blk i;
            }
            // 满了：淘汰最早到期的那个。
            var victim: usize = 0;
            var best: u64 = std.math.maxInt(u64);
            for (self.entries, 0..) |e, i| {
                if (e.expires_at < best) {
                    best = e.expires_at;
                    victim = i;
                }
            }
            break :blk victim;
        };

        const e = &self.entries[slot];
        e.used = true;
        e.len = @intCast(name.len);
        for (name, 0..) |c, i| e.name[i] = std.ascii.toLower(c);
        e.addr = addr;
        e.expires_at = now + @min(eff, self.max_ttl);
    }

    /// 查缓存。命中但已过期时就地释放，返回 null。
    pub fn get(self: *Cache, name: []const u8, now: u64) ?[4]u8 {
        const idx = self.find(name) orelse return null;
        const e = &self.entries[idx];
        if (now >= e.expires_at) {
            e.used = false;
            return null;
        }
        return e.addr;
    }
};

// ---------------------------------------------------------------------------
// 主机侧用例
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 构造一个响应：问题区 `name` + 若干 A 记录（记录名用压缩指针指回问题区）。
fn buildResponse(
    buf: []u8,
    id: u16,
    name: []const u8,
    answers: []const [4]u8,
    ttl: u32,
) ![]u8 {
    if (buf.len < Header.len) return error.Truncated;
    const h = Header{
        .id = id,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = @intCast(answers.len),
    };
    _ = try h.write(buf);
    const q_end = try encodeName(buf, Header.len, name);
    std.mem.writeInt(u16, buf[q_end..][0..2], @intFromEnum(Type.a), .big);
    std.mem.writeInt(u16, buf[q_end + 2 ..][0..2], @intFromEnum(Class.in), .big);
    var pos = q_end + 4;

    for (answers) |addr| {
        if (pos + 16 > buf.len) return error.Truncated;
        buf[pos] = 0xC0;
        buf[pos + 1] = @intCast(Header.len); // 指回问题区的名字
        std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(Type.a), .big);
        std.mem.writeInt(u16, buf[pos + 4 ..][0..2], @intFromEnum(Class.in), .big);
        std.mem.writeInt(u32, buf[pos + 6 ..][0..4], ttl, .big);
        std.mem.writeInt(u16, buf[pos + 10 ..][0..2], 4, .big);
        @memcpy(buf[pos + 12 ..][0..4], &addr);
        pos += 16;
    }
    return buf[0..pos];
}

test "dns: 12 字节头按大端写入与读回（含标志位顺序）" {
    var buf: [64]u8 = @splat(0);
    const h = Header{
        .id = 0xBEEF,
        .flags = .{ .qr = true, .aa = true, .rd = true, .ra = true, .rcode = 3 },
        .qdcount = 1,
        .ancount = 2,
    };
    const out = try h.write(&buf);
    try testing.expectEqual(@as(usize, 12), out.len);
    try testing.expectEqual(@as(u8, 0xBE), buf[0]);
    try testing.expectEqual(@as(u8, 0xEF), buf[1]);
    // QR=1 AA=1 RD=1 RA=1 RCODE=3：0x8000|0x0400|0x0100|0x0080|0x0003 = 0x8583
    try testing.expectEqual(@as(u16, 0x8583), std.mem.readInt(u16, buf[2..4], .big));

    const back = try Header.parse(&buf);
    try testing.expectEqual(@as(u16, 0xBEEF), back.id);
    try testing.expect(back.flags.qr);
    try testing.expect(back.flags.aa);
    try testing.expectEqual(@as(u4, 3), back.flags.rcode);
    try testing.expectEqual(@as(u16, 2), back.ancount);
}

test "dns: 查询编码 = 标签 + 终止符 + qtype + qclass" {
    var buf: [128]u8 = @splat(0);
    const n = try encodeQuery(&buf, 0x1234, "example.com", .a);
    try testing.expectEqual(@as(usize, 12 + 13 + 4), n);
    try testing.expectEqual(@as(u8, 7), buf[12]);
    try testing.expectEqualStrings("example", buf[13..20]);
    try testing.expectEqual(@as(u8, 3), buf[20]);
    try testing.expectEqualStrings("com", buf[21..24]);
    try testing.expectEqual(@as(u8, 0), buf[24]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[25..27], .big));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[27..29], .big));

    const h = try Header.parse(&buf);
    try testing.expectEqual(@as(u16, 1), h.qdcount);
    try testing.expect(h.flags.rd);
    try testing.expect(!h.flags.qr);
}

test "dns: 末尾点号合法，中间空标签非法" {
    var buf: [128]u8 = @splat(0);
    _ = try encodeQuery(&buf, 1, "example.com.", .a);
    try testing.expectEqual(@as(u8, 0), buf[24]);
    try testing.expectError(error.EmptyLabel, encodeQuery(&buf, 1, "example..com", .a));
    try testing.expectError(error.EmptyLabel, encodeQuery(&buf, 1, "", .a));
}

test "dns: 标签超过 63 字节、名字超过 255 字节都拒绝" {
    var buf: [512]u8 = @splat(0);
    var label_buf: [64]u8 = @splat('a');
    try testing.expectError(error.LabelTooLong, encodeQuery(&buf, 1, &label_buf, .a));

    // 4 个 63 字节标签 = 4*64 + 1 = 257 字节，超过 255。
    var name_buf: [4 * 63 + 3]u8 = undefined;
    for (0..4) |i| {
        @memset(name_buf[i * 64 ..][0..63], 'b' + @as(u8, @intCast(i)));
        if (i != 3) name_buf[i * 64 + 63] = '.';
    }
    try testing.expectError(error.NameTooLong, encodeQuery(&buf, 1, &name_buf, .a));
}

test "dns: 解码名字返回正确 next（不含指针时应指向终止符之后）" {
    var buf: [128]u8 = @splat(0);
    _ = try encodeQuery(&buf, 9, "zig.esp32.dev", .a);
    var out: [64]u8 = undefined;
    const nr = try decodeName(&buf, 12, &out);
    try testing.expectEqualStrings("zig.esp32.dev", nr.name);
    // zig(3)+esp32(5)+dev(3) 三个标签共 14 字节，加终止符 1 字节。
    try testing.expectEqual(@as(usize, 12 + 15), nr.next);
}

test "dns: 压缩指针指回问题区，next 在指针之后" {
    var buf: [256]u8 = @splat(0);
    const pkt = try buildResponse(&buf, 7, "example.com", &.{.{ 93, 184, 216, 34 }}, 300);

    var out: [64]u8 = undefined;
    // 答案名在问题区之后：名字 13 字节 + 4 字节 qtype/qclass = 12+17 = 29。
    const nr = try decodeName(pkt, 29, &out);
    try testing.expectEqualStrings("example.com", nr.name);
    try testing.expectEqual(@as(usize, 31), nr.next); // 指针占 2 字节
}

test "dns: 指针必须严格向前指（自指/前向指针都拒绝）" {
    var buf: [32]u8 = @splat(0);
    buf[12] = 0xC0;
    buf[13] = 12; // 指向自己
    var out: [64]u8 = undefined;
    try testing.expectError(error.BadPointer, decodeName(&buf, 12, &out));

    buf[14] = 0xC0;
    buf[15] = 20; // 指向后面
    try testing.expectError(error.BadPointer, decodeName(&buf, 14, &out));
}

test "dns: 标签越界/保留标签类型都被拒绝" {
    var buf: [16]u8 = @splat(0);
    buf[12] = 20; // 声称 20 字节标签，但报文只有 4 字节剩余
    var out: [64]u8 = undefined;
    try testing.expectError(error.Truncated, decodeName(&buf, 12, &out));

    buf[12] = 0x41; // 0x40 类型：保留
    try testing.expectError(error.BadPointer, decodeName(&buf, 12, &out));

    var short: [12]u8 = @splat(0);
    try testing.expectError(error.Truncated, decodeName(&short, 12, &out));
}

test "dns: A 记录解析（TTL/rdata/名字）" {
    var buf: [256]u8 = @splat(0);
    const pkt = try buildResponse(&buf, 0x4242, "example.com", &.{.{ 93, 184, 216, 34 }}, 300);
    var name: [64]u8 = undefined;
    const ans = try findAnswer(pkt, 0x4242, &name);
    try testing.expectEqualSlices(u8, &[_]u8{ 93, 184, 216, 34 }, &ans.addr);
    try testing.expectEqual(@as(u32, 300), ans.ttl);
    try testing.expectEqual(@as(u8, 0), ans.cname_hops);
    try testing.expectEqualStrings("example.com", name[0.."example.com".len]);
}

test "dns: 跳过 CNAME 继续找 A 记录，并统计跳数" {
    var buf: [512]u8 = @splat(0);
    const h = Header{
        .id = 5,
        .flags = .{ .qr = true },
        .qdcount = 1,
        .ancount = 2,
    };
    _ = try h.write(&buf);
    const q_end = try encodeName(&buf, Header.len, "www.example.com");
    std.mem.writeInt(u16, buf[q_end..][0..2], @intFromEnum(Type.cname), .big);
    std.mem.writeInt(u16, buf[q_end + 2 ..][0..2], 1, .big);
    var pos = q_end + 4;

    // 第一条：CNAME 指回问题区的名字（rdata 是压缩指针）。
    buf[pos] = 0xC0;
    buf[pos + 1] = 12;
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(Type.cname), .big);
    std.mem.writeInt(u16, buf[pos + 4 ..][0..2], 1, .big);
    std.mem.writeInt(u32, buf[pos + 6 ..][0..4], 60, .big);
    std.mem.writeInt(u16, buf[pos + 10 ..][0..2], 2, .big);
    buf[pos + 12] = 0xC0;
    buf[pos + 13] = 12;
    pos += 14;

    // 第二条：A 记录。
    buf[pos] = 0xC0;
    buf[pos + 1] = 12;
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(Type.a), .big);
    std.mem.writeInt(u16, buf[pos + 4 ..][0..2], 1, .big);
    std.mem.writeInt(u32, buf[pos + 6 ..][0..4], 120, .big);
    std.mem.writeInt(u16, buf[pos + 10 ..][0..2], 4, .big);
    @memcpy(buf[pos + 12 ..][0..4], &[_]u8{ 1, 2, 3, 4 });
    pos += 16;

    var none: [0]u8 = .{};
    const ans = try findAnswer(buf[0..pos], 5, &none);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &ans.addr);
    try testing.expectEqual(@as(u8, 1), ans.cname_hops);
    try testing.expectEqual(@as(u32, 120), ans.ttl);
}

test "dns: 响应校验（QR/ID/RCODE/ancount/rdlength）" {
    var none: [0]u8 = .{};
    var buf: [256]u8 = @splat(0);
    const pkt = try buildResponse(&buf, 0x1000, "a.b", &.{.{ 10, 0, 0, 1 }}, 60);
    try testing.expectError(error.IdMismatch, findAnswer(pkt, 0x1001, &none));

    // 问题区：12 + 名字(1+1+1+1+1=5) + 4 = 21，A 记录从 21 开始。
    const ans_off = Header.len + 5 + 4;

    // QR=0：这是一条查询，不是响应。
    var as_query: [256]u8 = @splat(0);
    @memcpy(as_query[0..pkt.len], pkt);
    as_query[2] &= 0x7F;
    try testing.expectError(error.NotResponse, findAnswer(as_query[0..pkt.len], 0x1000, &none));

    // RCODE=3（NXDOMAIN）。
    var nx: [256]u8 = @splat(0);
    @memcpy(nx[0..pkt.len], pkt);
    nx[3] |= 0x03;
    try testing.expectError(error.RcodeFailure, findAnswer(nx[0..pkt.len], 0x1000, &none));

    // ancount=0。
    var empty: [256]u8 = @splat(0);
    @memcpy(empty[0..pkt.len], pkt);
    std.mem.writeInt(u16, empty[6..8], 0, .big);
    try testing.expectError(error.NoAnswer, findAnswer(empty[0..pkt.len], 0x1000, &none));

    // rdlength != 4 的 A 记录必须报错，而不是读 4 字节越界。
    var bad: [256]u8 = @splat(0);
    @memcpy(bad[0..pkt.len], pkt);
    bad[ans_off + 10] = 0;
    bad[ans_off + 11] = 3;
    try testing.expectError(error.BadRdata, findAnswer(bad[0..pkt.len], 0x1000, &none));
}

test "dns: 缓存命中、大小写不敏感、TTL 过期" {
    var c: Cache = .{};
    try c.put("example.com", .{ 1, 2, 3, 4 }, 100, 1000);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &c.get("example.com", 1000).?);
    // DNS 名字比较不区分大小写（RFC 1035 §2.3.3）。
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &c.get("Example.COM", 1050).?);
    // 到 1100 正好过期。
    try testing.expectEqual(@as(?[4]u8, null), c.get("example.com", 1100));
    try testing.expectEqual(@as(usize, 0), c.len());
}

test "dns: 同名覆盖只占一个槽，TTL 被上限钳制" {
    var c: Cache = .{};
    c.max_ttl = 3600;
    try c.put("a.example", .{ 1, 1, 1, 1 }, 10, 0);
    try c.put("a.example", .{ 2, 2, 2, 2 }, 999999, 0);
    try testing.expectEqual(@as(usize, 1), c.len());
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 2, 2, 2 }, &c.get("a.example", 0).?);
    // 钳制到 3600：3599 仍有效，3600 已过期。
    try testing.expect(c.get("a.example", 3599) != null);
    try testing.expectEqual(@as(?[4]u8, null), c.get("a.example", 3600));
}

test "dns: 缓存容量满时淘汰最早到期者" {
    var c: Cache = .{};
    var name_buf: [16]u8 = undefined;
    // 8 个槽，TTL 依次 80、70、…、10（最后一个最早到期）。
    var i: usize = 0;
    while (i < Cache.max_entries) : (i += 1) {
        const n = try std.fmt.bufPrint(&name_buf, "h{d}", .{i});
        try c.put(n, .{ 10, 0, 0, @intCast(i) }, @intCast(80 - i * 10), 0);
    }
    try testing.expectEqual(Cache.max_entries, c.len());
    // 新条目挤掉 expires_at 最小的 h7（TTL=10）。
    try c.put("new", .{ 10, 0, 0, 99 }, 200, 0);
    try testing.expectEqual(Cache.max_entries, c.len());
    try testing.expectEqual(@as(?[4]u8, null), c.get("h7", 0));
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 99 }, &c.get("new", 0).?);
    try testing.expect(c.get("h0", 0) != null);
}

test "dns: TTL=0 表示不缓存，并删除同名旧条目" {
    var c: Cache = .{};
    try c.put("ttl0.example", .{ 9, 9, 9, 9 }, 300, 0);
    try testing.expect(c.get("ttl0.example", 0) != null);
    try c.put("ttl0.example", .{ 8, 8, 8, 8 }, 0, 1);
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(@as(?[4]u8, null), c.get("ttl0.example", 1));
}

test "dns: TTL 最高位置 1 时按 0 处理（RFC 2181 §8），不进缓存" {
    var c: Cache = .{};
    try c.put("highbit.example", .{ 7, 7, 7, 7 }, 0x8000_0000, 0);
    try testing.expectEqual(@as(usize, 0), c.len());
    try testing.expectEqual(@as(?[4]u8, null), c.get("highbit.example", 0));

    // 同名的旧条目同样被删掉，而不是被“高位 TTL”覆盖成长缓存。
    try c.put("highbit.example", .{ 6, 6, 6, 6 }, 300, 0);
    try testing.expect(c.get("highbit.example", 0) != null);
    try c.put("highbit.example", .{ 5, 5, 5, 5 }, 0xFFFF_FFFF, 1);
    try testing.expectEqual(@as(?[4]u8, null), c.get("highbit.example", 1));
}

test "dns: purge 只清理过期条目并返回数量" {
    var c: Cache = .{};
    try c.put("a", .{ 1, 0, 0, 1 }, 10, 0);
    try c.put("b", .{ 1, 0, 0, 2 }, 100, 0);
    try testing.expectEqual(@as(u8, 1), c.purge(10));
    try testing.expectEqual(@as(usize, 1), c.len());
    try testing.expectEqual(@as(u8, 0), c.purge(50));
    try testing.expectEqual(@as(u8, 1), c.purge(100));
    try testing.expectEqual(@as(usize, 0), c.len());
}

test "dns: 缓存键过长被拒绝" {
    var c: Cache = .{};
    var long: [Cache.name_cap + 1]u8 = @splat('x');
    try testing.expectError(error.NameTooLongForCache, c.put(&long, .{ 1, 1, 1, 1 }, 10, 0));
}
