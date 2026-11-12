//! ch20-tcp-state-machine：TCP 校验和（伪首部 + 段）。
//!
//! 每一章自带一份校验和实现，理由与 ch18 的 `inet.zig` 相同：**单章必须能
//! 独立 `zig build`**。`@import` 另一个章的源文件会把“这一章依赖哪一版
//! 缓冲抽象”变成隐式契约；本章的 `tcp.zig` 是 ch16 `headers.zig` 的超集，
//! 校验和也是同一套 RFC 1071 的独立实现（与 ch16 `checksum.zig` 逐字节一致，
//! 由已知向量钉死）。三者的关系写在章节 20.8。
//!
//! TCP 与 UDP 的两个差别：
//!
//!   1. **伪首部必须算**。IPv4 下 TCP 校验和字段没有“0 = 未计算”的豁免
//!      （那是 UDP 的约定，RFC 768），接收方必须校验（RFC 9293 §3.1）。
//!   2. **不做 0 → 0xFFFF 替换**。TCP 的 16 位反码和可以是 0，它就是一个
//!      合法值；UDP 才需要把 0 改写成 0xFFFF 以免被读成“没算”。
//!
//! 伪首部（RFC 9293 §3.1，IPv4 形态）：
//!
//!     0        8       16               31
//!     +--------+--------+----------------+
//!     |           源地址 (4 字节)        |
//!     +----------------------------------+
//!     |          目的地址 (4 字节)       |
//!     +--------+--------+----------------+
//!     |  0x00  | proto  |   TCP 长度     |
//!     +--------+--------+----------------+

const std = @import("std");

/// 流式 16 位反码和。字节按大端两两成组；落单的高字节记在 `odd` 里，
/// 等下一片的第一字节配对——这是“跨片连续”的地基。
pub const Sum = struct {
    acc: u32 = 0,
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

pub fn of(bytes: []const u8) u16 {
    var s = Sum{};
    s.add(bytes);
    return s.finish();
}

pub fn ofSlices(parts: []const []const u8) u16 {
    var s = Sum{};
    for (parts) |part| s.add(part);
    return s.finish();
}

/// IPv4 伪首部的种子：src(4) + dst(4) + 0x00 + proto + length(2)。
pub fn pseudoSeed(src: [4]u8, dst: [4]u8, protocol: u8, length: u16) Sum {
    var s = Sum{};
    s.add(&src);
    s.add(&dst);
    s.addWord(@as(u16, protocol)); // 高字节 0x00 已在 addWord 里补
    s.addWord(length);
    return s;
}

/// TCP 段的校验和。`segment` 的校验和字段必须为 0（或已经填入本函数上次
/// 的返回值——`finish` 对已校验的段再算一次会得到 0）。
pub fn tcp(src: [4]u8, dst: [4]u8, segment: []const u8) u16 {
    var s = pseudoSeed(src, dst, 6, @intCast(segment.len));
    s.add(segment);
    return s.finish();
}

/// 把校验和写进 `segment[16..18]`，返回写入的值。
/// 调用前 `segment` 的校验和字段必须是 0；重复调用是安全的（先清零）。
pub fn fillTcp(src: [4]u8, dst: [4]u8, segment: []u8) u16 {
    if (segment.len < 18) return 0;
    std.mem.writeInt(u16, segment[16..18], 0, .big);
    const c = tcp(src, dst, segment);
    std.mem.writeInt(u16, segment[16..18], c, .big);
    return c;
}

/// 校验：伪首部 + 整段（含校验和字段）的反码和必须为 0。
pub fn verifyTcp(src: [4]u8, dst: [4]u8, segment: []const u8) bool {
    if (segment.len < 20) return false;
    var s = pseudoSeed(src, dst, 6, @intCast(segment.len));
    s.add(segment);
    return s.finish() == 0;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "checksum: RFC 1071 示例向量" {
    const bytes = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try testing.expectEqual(@as(u16, 0x220d), of(&bytes));
    try testing.expectEqual(@as(u16, 0xbc2d), of("hello"));
    const zeros: [4]u8 = @splat(0);
    try testing.expectEqual(@as(u16, 0xffff), of(&zeros));
}

test "checksum: 分片流式求和等于连续缓冲求和" {
    const flat = "0123456789abcdefg"; // 17 字节：故意奇数
    var whole = Sum{};
    whole.add(flat);
    var split = Sum{};
    split.add("0");
    split.add("1234567");
    split.add("89abcdefg");
    try testing.expectEqual(whole.finish(), split.finish());
    try testing.expectEqual(of(flat), ofSlices(&.{ "0", "1234567", "89abcdefg" }));
}

test "checksum: TCP 已知向量（SYN 20 字节段 = 0xeca5）" {
    var seg = [_]u8{
        0x1f, 0x90, 0x00, 0x50, // sport 8080, dport 80
        0x00, 0x00, 0x00, 0x01, // seq
        0x00, 0x00, 0x00, 0x00, // ack
        0x50, 0x02, 0x20, 0x00, // offset 5, SYN, window 8192
        0x00, 0x00, 0x00, 0x00, // checksum 0, urgent 0
    };
    const src = [4]u8{ 192, 168, 1, 10 };
    const dst = [4]u8{ 192, 168, 1, 1 };
    try testing.expectEqual(@as(u16, 0xeca5), tcp(src, dst, &seg));

    const written = fillTcp(src, dst, &seg);
    try testing.expectEqual(@as(u16, 0xeca5), written);
    try testing.expect(verifyTcp(src, dst, &seg));

    // 翻一个载荷外的标志位：校验必须失败。
    seg[13] ^= 0x10; // ACK 位
    try testing.expect(!verifyTcp(src, dst, &seg));
}

test "checksum: 伪首部里的地址/长度参与计算（改 dst 即失配）" {
    var seg = [_]u8{
        0x00, 0x50, 0x1f, 0x90,
        0x00, 0x00, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x12, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
        'o',  'k',
    };
    const src = [4]u8{ 10, 0, 0, 1 };
    const dst = [4]u8{ 10, 0, 0, 2 };
    _ = fillTcp(src, dst, &seg);
    try testing.expect(verifyTcp(src, dst, &seg));
    try testing.expect(!verifyTcp(src, .{ 10, 0, 0, 3 }, &seg));

    // 长度必须覆盖“首部 + 载荷”，少一个字节也要失配。
    try testing.expect(!verifyTcp(src, dst, seg[0 .. seg.len - 1]));
}

test "checksum: 奇数字节载荷（跨片半字配对）" {
    var seg = [_]u8{
        0x00, 0x50, 0x1f, 0x90,
        0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x18, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
        'a',  'b',  'c', // 3 字节：总和为奇数长度
    };
    const src = [4]u8{ 172, 16, 0, 1 };
    const dst = [4]u8{ 172, 16, 0, 2 };
    _ = fillTcp(src, dst, &seg);
    try testing.expect(verifyTcp(src, dst, &seg));

    // 与“分两片加”的结果一致（模拟 pbuf 链）。
    var s = pseudoSeed(src, dst, 6, @intCast(seg.len));
    s.add(seg[0..21]);
    s.add(seg[21..]);
    try testing.expectEqual(@as(u16, 0), s.finish());
}
