//! ch16-stack-architecture-zero-copy：Internet 校验和（RFC 1071）与伪首部。
//!
//! 校验和是协议栈里唯一“必须逐字节看一遍”的操作，因此它天然是零拷贝设计的
//! 试金石：
//!
//!   - 对**链**求和时不应该把链线性化（`Sum` 支持跨片连续的字流，见 `add`）；
//!   - IPv4 首部校验和只覆盖首部（含选项），UDP/TCP 校验和覆盖
//!     **伪首部 + 传输层首部 + 载荷**（RFC 793 / RFC 768 / RFC 9293）；
//!   - 交换设备会改一个 16 位字（TTL、NAT 地址），此时用 RFC 1624 的增量
//!     更新公式，避免重算整包。
//!
//! ## 一条容易踩的坑：奇数字节不是“每个分片自己补零”
//!
//! 16 位求和把字节流按大端两两成组。若一个 pbuf 是 3 字节、下一个是 5 字节，
//! 那么第 3 个字节必须和下一个 pbuf 的第 1 个字节配成一对——**跨片连续**。
//! `Sum` 用一个 `odd` 字节记住“落单的半个字”，`add` 的边界就是 pbuf 边界，
//! 这一点由 `checksum: 分片流式求和等于连续缓冲求和` 的测试钉死。
//!
//! ## 为什么 UDP 的 0 要变成 0xFFFF
//!
//! RFC 768：UDP 校验和字段为 0 表示“发送方没有计算校验和”。因此当计算结果
//! 恰好是 0 时，必须按 0xFFFF 发送（0xFFFF 的补码和重新验证仍为 0）。
//! `udp` 在返回值里做了这个替换，IPv4/TCP 不做。

const std = @import("std");

/// 流式 16 位反码和。
pub const Sum = struct {
    acc: u32 = 0,
    /// 上一片落单的高字节（等待与本片第一字节配对）。
    odd: ?u8 = null,

    fn absorb(self: *Sum, word: u16) void {
        self.acc += word;
        // 每加一个字就回卷一次，保证 acc 不会溢出 u32（最大 0x1FFFE）。
        self.acc = (self.acc & 0xFFFF) + (self.acc >> 16);
    }

    /// 追加一段字节。调用边界可以是 pbuf 边界，字节流按连续处理。
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

    /// 追加一个 16 位字（大端语义，调用方负责字节序）。
    pub fn addWord(self: *Sum, word: u16) void {
        self.absorb(word);
    }

    /// 折叠并取反，得到可写入首部的 16 位校验和。可重复调用。
    pub fn finish(self: Sum) u16 {
        var acc = self.acc;
        if (self.odd) |lo| acc += @as(u16, lo) << 8;
        while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
        return @truncate(~acc);
    }
};

/// 一段连续字节的校验和（等价于“发送前计算”）。
pub fn of(bytes: []const u8) u16 {
    var s = Sum{};
    s.add(bytes);
    return s.finish();
}

/// 多段字节的校验和（等价于“对一个 pbuf 链求和”，不复制）。
pub fn ofSlices(slices: []const []const u8) u16 {
    var s = Sum{};
    for (slices) |part| s.add(part);
    return s.finish();
}

/// IPv4 伪首部（RFC 791）：src(4) + dst(4) + zero(1) + protocol(1) + length(2)。
pub fn pseudoSeed(src: [4]u8, dst: [4]u8, protocol: u8, length: u16) Sum {
    var s = Sum{};
    s.add(&src);
    s.add(&dst);
    // 伪首部的第 9、10 字节是 zero + protocol，按大端是一个 0x00PP 字。
    s.addWord(@as(u16, protocol));
    s.addWord(length);
    return s;
}

/// IPv4 首部校验和。`header` 必须是「校验和字段已置 0」的首部（含选项）。
pub fn ipv4Header(header: []const u8) u16 {
    return of(header);
}

/// UDP 校验和：伪首部 + UDP 首部（校验和字段为 0）+ 载荷。
/// 计算结果为 0 时返回 0xFFFF（RFC 768 的“零即无校验和”约定）。
pub fn udp(src: [4]u8, dst: [4]u8, udp_datagram: []const u8) u16 {
    var s = pseudoSeed(src, dst, 17, @intCast(udp_datagram.len));
    s.add(udp_datagram);
    const computed = s.finish();
    return if (computed == 0) 0xFFFF else computed;
}

/// TCP 校验和：伪首部 + TCP 段（校验和字段为 0）。不做 0→0xFFFF 替换。
pub fn tcp(src: [4]u8, dst: [4]u8, segment: []const u8) u16 {
    var s = pseudoSeed(src, dst, 6, @intCast(segment.len));
    s.add(segment);
    return s.finish();
}

/// RFC 1624 公式 (3)：`HC' = ~(~HC + ~m + m')`。
///
/// 用于“只改了一个 16 位字”的场景（TTL 递减、NAT 改写地址、payload 局部更新）。
/// 朴素的 `HC' = HC - m + m'` 在结果为 -0 时会得到 +0，而 -0 与 +0 在反码里
/// 是两个不同的编码（0x0000 与 0xFFFF）——这正是 RFC 1624 存在的理由。
pub fn update(old_checksum: u16, old_word: u16, new_word: u16) u16 {
    var acc: u32 = @as(u16, ~old_checksum);
    acc += @as(u16, ~old_word);
    acc += new_word;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return @truncate(~acc);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "checksum: RFC 1071 的示例（00 01 f2 03 f4 f5 f6 f7 → 0x220d）" {
    const bytes = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try testing.expectEqual(@as(u16, 0x220d), of(&bytes));
}

test "checksum: 奇数字节按高字节补零（hello → 0xbc2d）" {
    try testing.expectEqual(@as(u16, 0xbc2d), of("hello"));
}

test "checksum: 全零 → 0xffff；全 0xff → 0x0000" {
    const zeros: [4]u8 = @splat(0);
    const ones: [4]u8 = @splat(0xff);
    try testing.expectEqual(@as(u16, 0xffff), of(&zeros));
    try testing.expectEqual(@as(u16, 0x0000), of(&ones));
}

test "checksum: 分片流式求和等于连续缓冲求和（含奇数长度片）" {
    const flat = "0123456789abcdefg"; // 17 字节：故意是奇数
    var whole = Sum{};
    whole.add(flat);

    var split = Sum{};
    split.add("0");
    split.add("1234567");
    split.add("89abcdefg");

    try testing.expectEqual(whole.finish(), split.finish());
    try testing.expectEqual(of(flat), ofSlices(&.{ "0", "1234567", "89abcdefg" }));
}

test "checksum: IPv4 首部向量（192.168.1.10 → .1, UDP 33 字节）" {
    var header = [_]u8{
        0x45, 0x00, 0x00, 0x21, // ver/ihl, tos, total_len
        0x1c, 0x46, 0x40, 0x00, // id, flags/frag (DF)
        0x40, 0x11, 0x00, 0x00, // ttl 64, proto 17, checksum=0
        192,  168,  1,    10,
        192,  168,  1,    1,
    };
    const c = ipv4Header(&header);
    try testing.expectEqual(@as(u16, 0x9b2a), c);
    header[10] = @truncate(c >> 8);
    header[11] = @truncate(c & 0xff);
    // 把校验和写回去之后，整首部的反码和必须是 0。
    try testing.expectEqual(@as(u16, 0), of(&header));
}

test "checksum: UDP 校验和向量与 0→0xffff 规则" {
    var datagram = [_]u8{
        0x9c, 0x40, 0x00, 0x07, // sport 40000, dport 7
        0x00, 0x0d, 0x00, 0x00, // length 13, checksum=0
        'h',  'e',  'l',  'l',  'o',
    };
    const src = [4]u8{ 192, 168, 1, 10 };
    const dst = [4]u8{ 192, 168, 1, 1 };
    const c = udp(src, dst, &datagram);
    try testing.expectEqual(@as(u16, 0x9c5e), c);
    datagram[6] = @truncate(c >> 8);
    datagram[7] = @truncate(c & 0xff);

    var s = pseudoSeed(src, dst, 17, @intCast(datagram.len));
    s.add(&datagram);
    try testing.expectEqual(@as(u16, 0), s.finish());

    // 构造一个“计算结果是 0”的数据报：src/dst 全 0、proto=17、长度 10，
    // 伪首部与首部已贡献 17+10=0x1b，载荷补 0xffe4 正好凑成 0xffff → 取反得 0。
    var edge: [10]u8 = @splat(0);
    edge[8] = 0xff;
    edge[9] = 0xe4;
    const zero_addr = [4]u8{ 0, 0, 0, 0 };
    try testing.expectEqual(@as(u16, 0xFFFF), udp(zero_addr, zero_addr, &edge));
}

test "checksum: TCP 校验和向量（SYN, 20 字节段）" {
    var seg = [_]u8{
        0x1f, 0x90, 0x00, 0x50, // ports
        0x00, 0x00, 0x00, 0x01, // seq
        0x00, 0x00, 0x00, 0x00, // ack
        0x50, 0x02, 0x20, 0x00, // data offset 5, SYN, window 8192
        0x00, 0x00, 0x00, 0x00, // checksum=0, urgent
    };
    const c = tcp(.{ 192, 168, 1, 10 }, .{ 192, 168, 1, 1 }, &seg);
    try testing.expectEqual(@as(u16, 0xeca5), c);
    seg[16] = @truncate(c >> 8);
    seg[17] = @truncate(c & 0xff);
    var s = pseudoSeed(.{ 192, 168, 1, 10 }, .{ 192, 168, 1, 1 }, 6, 20);
    s.add(&seg);
    try testing.expectEqual(@as(u16, 0), s.finish());
}

test "checksum: 增量更新等于整包重算（TTL 64 → 63）" {
    const header = [_]u8{
        0x45, 0x00, 0x00, 0x21,
        0x1c, 0x46, 0x40, 0x00,
        0x40, 0x11, 0x00, 0x00,
        192,  168,  1,    10,
        192,  168,  1,    1,
    };
    const c = ipv4Header(&header);
    const incremental = update(c, 0x4011, 0x3f11);

    var changed = header;
    changed[8] = 63;
    changed[10] = @truncate(incremental >> 8);
    changed[11] = @truncate(incremental & 0xff);
    try testing.expectEqual(@as(u16, 0), of(&changed));

    // 增量结果必须与“校验和字段清零后整包重算”逐字节一致（这里是 0x9c2a）。
    try testing.expectEqual(@as(u16, 0x9c2a), incremental);
}

test "checksum: 增量更新对地址改写的正确性" {
    const header = [_]u8{
        0x45, 0x00, 0x00, 0x21,
        0x1c, 0x46, 0x40, 0x00,
        0x40, 0x11, 0x00, 0x00,
        10,   0,    0,    1,
        192,  168,  1,    1,
    };
    const c = ipv4Header(&header);
    // 改 src 的高 16 位：10.0 → 172.16
    const inc = update(c, 0x0a00, 0xac10);
    var changed = header;
    changed[12] = 172;
    changed[13] = 16;
    changed[10] = @truncate(inc >> 8);
    changed[11] = @truncate(inc & 0xff);
    try testing.expectEqual(@as(u16, 0), of(&changed));
}

test "checksum: Sum.finish 可重复调用（不消耗内部状态）" {
    var s = Sum{};
    s.add("abc");
    const a = s.finish();
    const b = s.finish();
    try testing.expectEqual(a, b);
    try testing.expectEqual(of("abc"), a);
}
