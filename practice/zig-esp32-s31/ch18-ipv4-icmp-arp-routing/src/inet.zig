//! ch18-ipv4-icmp-arp-routing：IPv4 地址运算 + Internet 校验和。
//!
//! 这是本章唯一被所有上层模块依赖的一层：地址的**比较与掩码**、以及
//! RFC 1071 的 16 位反码和。它不 import 任何其它工程（包括 ch16 的
//! `checksum.zig`）——原因写在章节 18.3：每一章必须可以单独 `zig build`，
//! 跨工程的 `@import` 会让"这一章到底依赖哪一版缓冲抽象"变成隐式契约。
//!
//! ## 校验和的两个使用姿势
//!
//! 1. **验证**：把首部（含校验和字段本身）整段喂给 `of`，结果必须是 0。
//!    因为校验和字段的值恰好是其余字之和的反码，加上它自己就等于 0xFFFF。
//! 2. **增量更新**：路由器改 TTL、NAT 改地址时，只改一个 16 位字。
//!    RFC 1624 的公式 `HC' = ~(~HC + ~m + m')` 避免了整包重算，也避免了
//!    RFC 1141 里 `-0` 与 `+0` 混用的经典错误（见 `updateChecksum` 的注释）。
//!
//! ## 为什么这里的 `Sum` 允许跨片累加
//!
//! 16 位求和把字节流按大端两两成组。若一段是 3 字节、下一段是 5 字节，
//! 第 3 个字节必须与下一段的第 1 个字节配对，**跨片连续**。
//! `pending` 记住"落单的高字节"，这就是零拷贝求和的地基：不需要先把
//! pbuf 链拼成一块连续内存。

const std = @import("std");

/// 网络序的 IPv4 地址（4 字节）。刻意不用 `u32`：地址的字节序在协议栈里
/// 是"永远按字节看"的，用数组可以让"误当主机序整数比较"的 bug 编译期就露出来。
pub const Addr = [4]u8;

pub const Error = error{
    BadAddress,
    BadPrefix,
    ShortBuffer,
};

pub const any: Addr = .{ 0, 0, 0, 0 };
pub const broadcast: Addr = .{ 255, 255, 255, 255 };

// ---------------------------------------------------------------------------
// 地址：解析、格式化、掩码
// ---------------------------------------------------------------------------

/// 解析点分十进制。拒绝空段、非纯数字段、超过 3 位的段、>255 的段、
/// 段数不为 4 的输入。刻意不接受前导 `+`、`_` 分隔符、空白与八进制——
/// `inet_aton` 那套宽松规则是历史包袱，而 `std.fmt.parseInt` 会接受前导 `+`
/// 与 `_`，所以这里先逐字符检查 ASCII 数字。
pub fn parse(text: []const u8) Error!Addr {
    var out: Addr = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i == 4) return error.BadAddress;
        if (part.len == 0 or part.len > 3) return error.BadAddress;
        for (part) |c| {
            if (c < '0' or c > '9') return error.BadAddress;
        }
        const v = std.fmt.parseInt(u16, part, 10) catch return error.BadAddress;
        if (v > 255) return error.BadAddress;
        out[i] = @intCast(v);
        i += 1;
    }
    if (i != 4) return error.BadAddress;
    return out;
}

/// 写入 `a.b.c.d`，返回占用的切片。缓冲区至少 16 字节（含结尾 0 的空间由调用方处理）。
pub fn format(addr: Addr, buf: []u8) Error![]const u8 {
    if (buf.len < 16) return error.ShortBuffer;
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        addr[0], addr[1], addr[2], addr[3],
    }) catch return error.ShortBuffer;
}

pub fn eql(a: Addr, b: Addr) bool {
    return std.mem.eql(u8, &a, &b);
}

/// 前缀长度 → 掩码。`/0` 全 0，`/32` 全 1；中间值必须连续（不允许 0b1010…）。
pub fn mask(prefix: u8) Error!Addr {
    if (prefix > 32) return error.BadPrefix;
    var out: Addr = .{ 0, 0, 0, 0 };
    var i: usize = 0;
    var left = prefix;
    while (left >= 8) {
        out[i] = 0xFF;
        i += 1;
        left -= 8;
    }
    if (left > 0) out[i] = @as(u8, 0xFF) << @intCast(8 - left);
    return out;
}

pub fn network(addr: Addr, prefix: u8) Error!Addr {
    const m = try mask(prefix);
    var out: Addr = undefined;
    for (0..4) |i| out[i] = addr[i] & m[i];
    return out;
}

/// `dst` 是否落在 `base/prefix` 里。这是路由查找与"同网段直接投递"的唯一判据。
pub fn inPrefix(base: Addr, prefix: u8, dst: Addr) bool {
    const m = mask(prefix) catch return false;
    for (0..4) |i| {
        if ((base[i] & m[i]) != (dst[i] & m[i])) return false;
    }
    return true;
}

pub fn isMulticast(addr: Addr) bool {
    return addr[0] >= 224 and addr[0] <= 239;
}

pub fn isLimitedBroadcast(addr: Addr) bool {
    return eql(addr, broadcast);
}

pub fn isLoopback(addr: Addr) bool {
    return addr[0] == 127;
}

/// 只把最后一个字节置 0xFF（`/24` 下的定向广播地址，RFC 922）。本章只用它
/// 生成测试地址，从不把定向广播当作目的地址发出。
pub fn withLastOctet(addr: Addr, value: u8) Addr {
    return .{ addr[0], addr[1], addr[2], value };
}

// ---------------------------------------------------------------------------
// RFC 1071：16 位反码和
// ---------------------------------------------------------------------------

pub const Sum = struct {
    /// 已累加的 32 位部分和。每次相加后立刻回卷，保证不溢出。
    acc: u32 = 0,
    /// 上一段落单的高字节，等待与本段第一字节配对。
    pending: ?u8 = null,

    fn fold(self: *Sum) void {
        while (self.acc >> 16 != 0) {
            self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
        }
    }

    /// 追加一段字节。调用边界可以任意（首部、载荷、pbuf 链的一环）。
    pub fn add(self: *Sum, bytes: []const u8) void {
        var i: usize = 0;
        if (self.pending) |hi| {
            if (bytes.len == 0) return;
            self.acc += (@as(u32, hi) << 8) | @as(u32, bytes[0]);
            i = 1;
            self.pending = null;
            self.fold();
        }
        while (i + 1 < bytes.len) : (i += 2) {
            self.acc += (@as(u32, bytes[i]) << 8) | @as(u32, bytes[i + 1]);
            self.fold();
        }
        if (i < bytes.len) self.pending = bytes[i];
    }

    /// 追加一个已经在本机序里摆好的 16 位字（例如从 `readInt(..., .big)` 读出来的）。
    pub fn addU16(self: *Sum, word: u16) void {
        self.acc += word;
        self.fold();
    }

    /// 折叠 + 取反。可以重复调用（不消耗状态），因此 `finish` 之后还能继续 `add`。
    pub fn finish(self: Sum) u16 {
        var acc = self.acc;
        if (self.pending) |lo| acc += @as(u32, lo) << 8;
        while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
        return @truncate(~acc);
    }
};

/// 一段连续字节的校验和。
pub fn of(bytes: []const u8) u16 {
    var s = Sum{};
    s.add(bytes);
    return s.finish();
}

/// 多段字节（pbuf 链）的校验和：按流式语义跨片配对，不复制。
pub fn ofSlices(parts: []const []const u8) u16 {
    var s = Sum{};
    for (parts) |p| s.add(p);
    return s.finish();
}

/// 校验和自验证：把一个**已经带着校验和字段**的完整首部（或 ICMP 报文）
/// 整段喂进来，结果必须是 0。
pub fn verify(bytes: []const u8) bool {
    return of(bytes) == 0;
}

/// RFC 1624 的增量更新：把 16 位字 `old_word` 改成 `new_word`，返回新的校验和。
///
/// 推导：`~HC` 就是"除校验和字段外所有字的部分和" `S`。
/// `S' = S - m + m'`（反码算术），而 `-m == ~m`、`+0xFFFF == 0`（反码里 0xFFFF 是 -0）。
/// 于是 `S' = ~HC + ~m + m'`，再取反即得 `HC'`。
///
/// 注意 RFC 1141 的旧公式 `HC' = HC - ~m - m'` 在 `HC == ~m` 时会得到 `-0`（0xFFFF），
/// 而 RFC 1624 明确要求得到 `+0`（0x0000）——差别就在于对"反码零"的处理。
pub fn updateChecksum(checksum: u16, old_word: u16, new_word: u16) u16 {
    var acc: u32 = @as(u32, ~checksum & 0xFFFF) + (@as(u32, ~old_word & 0xFFFF)) + @as(u32, new_word);
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return @truncate(~acc);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "addr: 解析与格式化往返" {
    const a = try parse("192.168.1.10");
    try testing.expectEqual([4]u8{ 192, 168, 1, 10 }, a);

    var buf: [16]u8 = undefined;
    const text = try format(a, &buf);
    try testing.expectEqualStrings("192.168.1.10", text);
}

test "addr: 拒绝畸形输入" {
    try testing.expectError(error.BadAddress, parse(""));
    try testing.expectError(error.BadAddress, parse("192.168.1"));
    try testing.expectError(error.BadAddress, parse("192.168.1.2.3"));
    try testing.expectError(error.BadAddress, parse("192..1.2"));
    try testing.expectError(error.BadAddress, parse("192.168.1.256"));
    try testing.expectError(error.BadAddress, parse("192.168.1.x"));
    try testing.expectError(error.BadAddress, parse("192.168.1.1000"));
    // parseInt 本身接受前导 `+` 与 `_`；地址解析必须先挡住它们
    try testing.expectError(error.BadAddress, parse("+1.2.3.4"));
    try testing.expectError(error.BadAddress, parse("1_0.0.0.1"));
    try testing.expectError(error.BadAddress, parse("0x10.0.0.1"));
}

test "addr: 掩码与网络号" {
    try testing.expectEqual([4]u8{ 255, 255, 255, 0 }, try mask(24));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, try mask(32));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, try mask(0));
    try testing.expectEqual([4]u8{ 255, 255, 255, 128 }, try mask(25));
    try testing.expectEqual([4]u8{ 255, 255, 128, 0 }, try mask(17));
    try testing.expectError(error.BadPrefix, mask(33));

    const net = try network(try parse("10.20.30.40"), 20);
    try testing.expectEqual([4]u8{ 10, 20, 16, 0 }, net);
}

test "addr: 前缀匹配只比对掩码覆盖的位" {
    const base = try parse("10.0.0.0");
    try testing.expect(inPrefix(base, 8, try parse("10.255.1.1")));
    try testing.expect(!inPrefix(base, 8, try parse("11.0.0.1")));
    try testing.expect(inPrefix(try parse("172.16.0.0"), 12, try parse("172.31.255.254")));
    try testing.expect(!inPrefix(try parse("172.16.0.0"), 12, try parse("172.32.0.1")));
    try testing.expect(inPrefix(base, 0, try parse("203.0.113.9")));
}

test "addr: 特殊地址分类" {
    try testing.expect(isMulticast(try parse("224.0.0.251")));
    try testing.expect(!isMulticast(try parse("223.255.255.255")));
    try testing.expect(isLimitedBroadcast(broadcast));
    try testing.expect(isLoopback(try parse("127.0.0.1")));
    try testing.expectEqual([4]u8{ 192, 168, 1, 255 }, withLastOctet(try parse("192.168.1.10"), 255));
}

test "checksum: RFC 1071 示例得出 0x220d" {
    // RFC 1071 §3 的示例字节流：00 01 f2 03 f4 f5 f6 f7
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try testing.expectEqual(@as(u16, 0x220d), of(&data));
}

test "checksum: 奇数字节按高位补零" {
    try testing.expectEqual(@as(u16, 0xFF00), ~@as(u16, 0x00FF));
    const one = [_]u8{0x12};
    try testing.expectEqual(@as(u16, 0xEDFF), of(&one));
}

test "checksum: 跨片求和等于连续缓冲求和" {
    const data = "the quick brown fox jumps over the lazy dog";
    var whole = Sum{};
    whole.add(data);

    var split = Sum{};
    split.add(data[0..3]);
    split.add(data[3..3]);
    split.add(data[3..17]);
    split.add(data[17..]);
    try testing.expectEqual(whole.finish(), split.finish());
}

test "checksum: 自带校验和的缓冲区验证为 0" {
    var buf = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06, 0, 0, 192, 168, 1, 10, 192, 168, 1, 1 };
    const c = of(&buf);
    std.mem.writeInt(u16, buf[10..12], c, .big);
    try testing.expect(verify(&buf));
    buf[8] = 63;
    try testing.expect(!verify(&buf));
}

test "checksum: RFC 1624 增量更新等于整包重算（TTL 递减）" {
    var buf = [_]u8{ 0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x11, 0, 0, 192, 168, 1, 10, 192, 168, 1, 1 };
    const before = of(&buf);
    std.mem.writeInt(u16, buf[10..12], before, .big);

    const old_word = std.mem.readInt(u16, buf[8..10], .big);
    const new_word: u16 = (63 << 8) | 17;
    const patched = updateChecksum(before, old_word, new_word);

    buf[8] = 63;
    std.mem.writeInt(u16, buf[10..12], patched, .big);
    try testing.expect(verify(&buf));
    try testing.expectEqual(patched, blk: {
        buf[10] = 0;
        buf[11] = 0;
        break :blk of(&buf);
    });
}

test "checksum: 增量更新结果不依赖调用顺序（两字各改一次）" {
    var buf = [_]u8{ 0x45, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x40, 0x01, 0, 0, 10, 0, 0, 1, 10, 0, 0, 2 };
    const c0 = of(&buf);
    const w1_old = std.mem.readInt(u16, buf[2..4], .big);
    const w2_old = std.mem.readInt(u16, buf[8..10], .big);
    const c1 = updateChecksum(c0, w1_old, 0x0200);
    const c2 = updateChecksum(c1, w2_old, 0x3f01);

    std.mem.writeInt(u16, buf[2..4], 0x0200, .big);
    buf[8] = 0x3f;
    std.mem.writeInt(u16, buf[10..12], c2, .big);
    try testing.expect(verify(&buf));
}
