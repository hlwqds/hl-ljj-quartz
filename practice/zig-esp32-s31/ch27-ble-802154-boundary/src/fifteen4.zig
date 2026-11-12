//! ch27-ble-802154-boundary：802.15.4 MAC 帧头 + 6LoWPAN 最小解压。
//!
//! 这一半和 BLE 那半**不是同一种东西**：S31 上的 802.15.4 MAC/驱动层没有归档，
//! 驱动是 IDF 里的 C 源码；射频层仍是闭源（`libphy.a` + `libbtbb.a`）。
//! 详见全部 27.2 与 `tools/symbols.sh` 的第 6 节：
//! `components/ieee802154/` 10 个文件 3571 行、`esp_hal_ieee802154/esp32s31`
//! 的 `ieee802154_ll.h`）。本章因此把 802.15.4 侧写成“纯字节变换”：
//!
//!   * MAC 帧头（FCF / 序列号 / 地址模式 / PAN 压缩）——IEEE 802.15.4-2015
//!     §7.2.1（Frame Control）、§7.2.2（Sequence Number）、§7.2.3（Addressing）；
//!   * 6LoWPAN 的 IPHC 解压（只做无状态压缩的 4 个组合）——RFC 6282 §3.1.1；
//!   * UDP NHC（只做 P=00 的两种 C 值）——RFC 6282 §4.3.3；
//!   * IID 推导——RFC 4944 §6 + RFC 2464（EUI-64 → IID 的 U/L 翻转）。
//!
//! **不做** Mesh 头、分片头（RFC 4944 §5.3）、上下文表（RFC 6282 §3.1.2）、
//! MLE（Thread 的 Mesh Link Establishment，见章节 27.7），也不做任何组播
//! 压缩（M=1）。遇到这些，解压器返回 `error.UnsupportedCompression` 并把
//! `stats.rejected` 加一——判据 ⑫ 就是拿这个拒绝路径当被测对象的。
//!
//! FCF 的位序（IEEE 802.15.4-2015 §7.2.1.1，与本文档的 `u16` 小端一致）：
//!
//!   bit0..2   Frame Type     000 beacon / 001 data / 010 ack / 011 command
//!   bit3      Security Enabled
//!   bit4      Frame Pending
//!   bit5      Ack Request
//!   bit6      PAN ID Compression
//!   bit7      Reserved
//!   bit8      Sequence Number Suppression
//!   bit9      IE Present
//!   bit10..11 Destination Addressing Mode  00 none / 10 short / 11 long
//!   bit12..13 Frame Version
//!   bit14..15 Source Addressing Mode
//!
//! 于是“数据帧 + 请求 ACK + PAN 压缩 + 双短地址 + version 0”
//! = 0001 + 0020 + 0040 + 0800 + 8000 = **0x8861**，小端字节序是 `61 88`。
//! 这是判据 ⑨ 的 KAT；同一组位展开成“目标短地址 + 源长地址”就是 0xC861。

const std = @import("std");

pub const Error = error{
    Short,
    NoSpace,
    /// 地址模式是 01（保留）或与 PAN 压缩组合非法。
    BadAddressMode,
    /// 6LoWPAN dispatch 不是 IPHC（011xxxxx）。
    BadDispatch,
    /// IPHC/NHC 的某个组合本章不解（状态压缩、组播、分片、非 UDP）。
    UnsupportedCompression,
};

/// 802.15.4 帧类型。§7.2.1.1 表 7-1。
pub const FrameType = enum(u3) {
    beacon = 0,
    data = 1,
    ack = 2,
    command = 3,
};

/// 地址模式。§7.2.1.1 表 7-2：00 无、10 短（16 位）、11 长（64 位）。
pub const AddrMode = enum(u2) {
    none = 0,
    reserved = 1,
    short = 2,
    long = 3,
};

/// 帧控制字段的逻辑视图。
pub const Fcf = struct {
    frame_type: FrameType = .data,
    security: bool = false,
    frame_pending: bool = false,
    ack_request: bool = true,
    pan_compress: bool = true,
    seq_suppress: bool = false,
    ie_present: bool = false,
    dest_mode: AddrMode = .short,
    version: u2 = 0,
    src_mode: AddrMode = .short,

    pub fn encode(self: Fcf) u16 {
        var w: u16 = 0;
        w |= @as(u16, @backingInt(self.frame_type));
        w |= @as(u16, @intFromBool(self.security)) << 3;
        w |= @as(u16, @intFromBool(self.frame_pending)) << 4;
        w |= @as(u16, @intFromBool(self.ack_request)) << 5;
        w |= @as(u16, @intFromBool(self.pan_compress)) << 6;
        w |= @as(u16, @intFromBool(self.seq_suppress)) << 8;
        w |= @as(u16, @intFromBool(self.ie_present)) << 9;
        w |= @as(u16, @backingInt(self.dest_mode)) << 10;
        w |= @as(u16, self.version) << 12;
        w |= @as(u16, @backingInt(self.src_mode)) << 14;
        return w;
    }

    pub fn decode(w: u16) Fcf {
        return .{
            .frame_type = @fromBackingInt(@intCast(@as(u3, @truncate(w)))),
            .security = (w & 0x0008) != 0,
            .frame_pending = (w & 0x0010) != 0,
            .ack_request = (w & 0x0020) != 0,
            .pan_compress = (w & 0x0040) != 0,
            .seq_suppress = (w & 0x0100) != 0,
            .ie_present = (w & 0x0200) != 0,
            .dest_mode = @fromBackingInt(@intCast(@as(u2, @truncate(w >> 10)))),
            .version = @truncate(w >> 12),
            .src_mode = @fromBackingInt(@intCast(@as(u2, @truncate(w >> 14)))),
        };
    }
};

/// 802.15.4 地址。
pub const Addr = union(enum) {
    short: u16,
    long: [8]u8,

    pub fn mode(self: Addr) AddrMode {
        return switch (self) {
            .short => .short,
            .long => .long,
        };
    }
};

/// MAC 头（不含辅助安全头/IE，本章不支持）。
pub const MacHeader = struct {
    fcf: Fcf,
    seq: u8,
    dest_pan: u16,
    dest: Addr,
    src_pan: u16,
    src: Addr,
};

pub const Stats = struct {
    frames_encoded: u32 = 0,
    frames_decoded: u32 = 0,
    decompressed: u32 = 0,
    rejected: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

fn putU16(out: []u8, v: u16) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
}

fn getU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

/// 网络字节序（大端）。6LoWPAN 的 UDP 字段按 RFC 6282 §4.3.3 保持
/// “与 UDP 头里相同的顺序”，也就是网络序；这一点和 802.15.4 自己的
/// 小端字段（PAN/短地址）不同，是最容易写错的一处。
fn getU16Be(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn addrLen(m: AddrMode) Error!usize {
    return switch (m) {
        .none => 0,
        .short => 2,
        .long => 8,
        .reserved => error.BadAddressMode,
    };
}

/// 编码 MAC 头。返回头长度。
///
/// 地址顺序（§7.2.3）：Dest PAN → Dest Address → [Src PAN] → Src Address。
/// `pan_compress` 为真时省略 Src PAN（此时两者必须相同，本章不校验，
/// 因为真实栈在 PIB 层保证）。
pub fn encodeHeader(out: []u8, h: MacHeader, stats: *Stats) Error!usize {
    const dlen = try addrLen(h.dest.mode());
    const slen = try addrLen(h.src.mode());
    const needs_src_pan = !h.fcf.pan_compress and slen > 0;
    const total = 2 + 1 + 2 + dlen + (if (needs_src_pan) @as(usize, 2) else 0) + slen;
    if (out.len < total) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    var i: usize = 0;
    putU16(out[0..2], h.fcf.encode());
    i = 2;
    out[i] = h.seq;
    i += 1;
    putU16(out[i .. i + 2], h.dest_pan);
    i += 2;
    switch (h.dest) {
        .short => |a| {
            putU16(out[i .. i + 2], a);
            i += 2;
        },
        .long => |a| {
            @memcpy(out[i .. i + 8], &a);
            i += 8;
        },
    }
    if (needs_src_pan) {
        putU16(out[i .. i + 2], h.src_pan);
        i += 2;
    }
    switch (h.src) {
        .short => |a| {
            putU16(out[i .. i + 2], a);
            i += 2;
        },
        .long => |a| {
            @memcpy(out[i .. i + 8], &a);
            i += 8;
        },
    }
    stats.frames_encoded += 1;
    return i;
}

/// 解出 MAC 头，返回头与剩余字节（6LoWPAN 载荷）。
pub const Decoded = struct { header: MacHeader, payload: []const u8 };

pub fn decodeHeader(bytes: []const u8, stats: *Stats) Error!Decoded {
    if (bytes.len < 3) {
        stats.rejected += 1;
        return error.Short;
    }
    const fcf = Fcf.decode(getU16(bytes[0..2]));
    if (fcf.security or fcf.ie_present or fcf.seq_suppress) {
        // 辅助安全头、IE、序列号抑制都会改变后续布局，本章不支持。
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    const dlen = try addrLen(fcf.dest_mode);
    const slen = try addrLen(fcf.src_mode);
    const needs_src_pan = !fcf.pan_compress and slen > 0;
    const total = 2 + 1 + 2 + dlen + (if (needs_src_pan) @as(usize, 2) else 0) + slen;
    if (bytes.len < total) {
        stats.rejected += 1;
        return error.Short;
    }
    var i: usize = 3;
    const dest_pan = getU16(bytes[i .. i + 2]);
    i += 2;
    const dest: Addr = switch (fcf.dest_mode) {
        .short => blk: {
            const a = getU16(bytes[i .. i + 2]);
            i += 2;
            break :blk .{ .short = a };
        },
        .long => blk: {
            var a: [8]u8 = undefined;
            @memcpy(&a, bytes[i .. i + 8]);
            i += 8;
            break :blk .{ .long = a };
        },
        .none => .{ .short = 0 },
        .reserved => return error.BadAddressMode,
    };
    var src_pan: u16 = dest_pan;
    if (needs_src_pan) {
        src_pan = getU16(bytes[i .. i + 2]);
        i += 2;
    }
    const src: Addr = switch (fcf.src_mode) {
        .short => blk: {
            const a = getU16(bytes[i .. i + 2]);
            i += 2;
            break :blk .{ .short = a };
        },
        .long => blk: {
            var a: [8]u8 = undefined;
            @memcpy(&a, bytes[i .. i + 8]);
            i += 8;
            break :blk .{ .long = a };
        },
        .none => .{ .short = 0 },
        .reserved => return error.BadAddressMode,
    };
    stats.frames_decoded += 1;
    return .{
        .header = .{
            .fcf = fcf,
            .seq = bytes[2],
            .dest_pan = dest_pan,
            .dest = dest,
            .src_pan = src_pan,
            .src = src,
        },
        .payload = bytes[total..],
    };
}

// ---------------------------------------------------------------------------
// 6LoWPAN IPHC 解压
// ---------------------------------------------------------------------------

/// 解压出的 IPv6 报文：40 字节头 + UDP 头字段 + 应用数据切片。
pub const Ipv6 = struct {
    hdr: [40]u8,
    udp: Udp,
    payload: []const u8,

    pub fn version(self: *const Ipv6) u8 {
        return self.hdr[0] >> 4;
    }
    pub fn payloadLen(self: *const Ipv6) u16 {
        return getU16(self.hdr[4..6]);
    }
    pub fn nextHeader(self: *const Ipv6) u8 {
        return self.hdr[6];
    }
    pub fn hopLimit(self: *const Ipv6) u8 {
        return self.hdr[7];
    }
    pub fn src(self: *const Ipv6) [16]u8 {
        var a: [16]u8 = undefined;
        @memcpy(&a, self.hdr[8..24]);
        return a;
    }
    pub fn dst(self: *const Ipv6) [16]u8 {
        var a: [16]u8 = undefined;
        @memcpy(&a, self.hdr[24..40]);
        return a;
    }
};

pub const Udp = struct {
    src_port: u16,
    dst_port: u16,
    checksum: u16,
    /// false 表示校验和被 6LoWPAN 省略（NHC 的 C=1），值为 0。
    checksum_present: bool,
};

/// 由 16 位短地址推出 IID：0000:00ff:fe00:XXXX。
///
/// 出处是 RFC 6282 §3.1.1（SAM=10 的 16 位内联映射，RFC 6282 §3.2.2 复述）
/// 与 OpenThread 的实现（`mac_frame.hpp` 的 locator 形式）。注意不要把它
/// 说成 RFC 4944 §6 的规则：那一节给的是「PAN ID ‖ 0000 ‖ 短地址」的伪
/// 48 位派生，会把 PAN ID 掺进 IID；本章按 6282 的口径（PAN 不进 IID）。
fn iidFromShort(a: u16, out: *[8]u8) void {
    out.* = .{ 0x00, 0x00, 0x00, 0xff, 0xfe, 0x00, 0x00, 0x00 };
    out[6] = @truncate(a >> 8);
    out[7] = @truncate(a);
}

/// 由 EUI-64 推出 IID：按 RFC 2464 的映射，把 U/L 位（第一个字节的 bit1）
/// 取反。RFC 4944 §6 引用同一条规则（那一节对 EUI-64 地址就是这个做法，
/// 与短地址的 PAN 派生不同）。
fn iidFromLong(a: [8]u8, out: *[8]u8) void {
    out.* = a;
    out[0] ^= 0x02;
}

/// 把 IID 写进 16 字节地址的后 8 字节：源地址偏移 16，目标地址偏移 32
/// （前 8 字节是该地址的 fe80:: 前缀）。
fn writeIid(hdr: *[40]u8, off: usize, iid: [8]u8) void {
    @memcpy(hdr[off .. off + 8], &iid);
}

/// 解压一个无状态 IPHC 报文。
///
/// 支持的组合（全部 RFC 6282 §3.1.1 无状态列）：
///   TF=11（Traffic Class 与 Flow Label 全省）、NH=1（下一个头走 NHC）、
///   HLIM=11（Hop Limit=255）、CID=0、SAC=0、SAM∈{10,11}、
///   M=0、DAC=0、DAM∈{10,11}。
/// 下一个头只支持 UDP NHC（11110CPP，P=00）。
pub fn decompress(lowpan: []const u8, mac: *const MacHeader, stats: *Stats) Error!Ipv6 {
    if (lowpan.len < 2) {
        stats.rejected += 1;
        return error.Short;
    }
    // dispatch：011xxxxx。低 5 位属于 IPHC 编码。
    if ((lowpan[0] & 0xe0) != 0x60) {
        stats.rejected += 1;
        return error.BadDispatch;
    }
    const b0 = lowpan[0];
    const b1 = lowpan[1];
    const tf: u2 = @truncate((b0 >> 3) & 0x03);
    const nh_compressed = (b0 & 0x04) != 0;
    const hlim: u2 = @truncate(b0 & 0x03);
    const cid = (b1 & 0x80) != 0;
    const sac = (b1 & 0x40) != 0;
    const sam: u2 = @truncate((b1 >> 4) & 0x03);
    const m = (b1 & 0x08) != 0;
    const dac = (b1 & 0x04) != 0;
    const dam: u2 = @truncate(b1 & 0x03);

    if (tf != 0x03 or !nh_compressed or hlim != 0x03 or cid or sac or m or dac) {
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    if (sam == 0x00 or dam == 0x00) {
        // 128 位内联地址：合法但本章不解（判据 ⑫ 只用 SAC/sam 组合做拒绝用例）。
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }

    var i: usize = 2;
    var hdr: [40]u8 = @splat(0);
    hdr[0] = 0x60; // version 6, TC/FL 全 0
    hdr[6] = 17; // UDP
    hdr[7] = 255; // HLIM=11
    // 源/目标都是 link-local：fe80::/64。
    hdr[8] = 0xfe;
    hdr[9] = 0x80;
    hdr[24] = 0xfe;
    hdr[25] = 0x80;

    // 源地址
    switch (sam) {
        0x02 => {
            if (lowpan.len < i + 2) {
                stats.rejected += 1;
                return error.Short;
            }
            const short = getU16(lowpan[i .. i + 2]);
            i += 2;
            var iid: [8]u8 = undefined;
            iidFromShort(short, &iid);
            writeIid(&hdr, 16, iid);
        },
        0x03 => {
            const src = mac.src;
            var iid: [8]u8 = undefined;
            switch (src) {
                .short => |s| iidFromShort(s, &iid),
                .long => |l| iidFromLong(l, &iid),
            }
            writeIid(&hdr, 16, iid);
        },
        else => unreachable,
    }

    // 目标地址
    switch (dam) {
        0x02 => {
            if (lowpan.len < i + 2) {
                stats.rejected += 1;
                return error.Short;
            }
            const short = getU16(lowpan[i .. i + 2]);
            i += 2;
            var iid: [8]u8 = undefined;
            iidFromShort(short, &iid);
            writeIid(&hdr, 32, iid);
        },
        0x03 => {
            const dst = mac.dest;
            var iid: [8]u8 = undefined;
            switch (dst) {
                .short => |s| iidFromShort(s, &iid),
                .long => |l| iidFromLong(l, &iid),
            }
            writeIid(&hdr, 32, iid);
        },
        else => unreachable,
    }

    // NHC：11110CPP，只接受 P=00（两个端口都 16 位内联）。
    if (i >= lowpan.len) {
        stats.rejected += 1;
        return error.Short;
    }
    const nhc = lowpan[i];
    if ((nhc & 0xf8) != 0xf0) {
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    const c = (nhc & 0x04) != 0;
    const p: u2 = @truncate(nhc & 0x03);
    if (p != 0x00) {
        stats.rejected += 1;
        return error.UnsupportedCompression;
    }
    i += 1;
    // 端口 4 字节 + 校验和（C=0 时 2 字节）。
    const need = 4 + (if (c) @as(usize, 0) else 2);
    if (lowpan.len < i + need) {
        stats.rejected += 1;
        return error.Short;
    }
    const sport = getU16Be(lowpan[i .. i + 2]);
    const dport = getU16Be(lowpan[i + 2 .. i + 4]);
    i += 4;
    var csum: u16 = 0;
    if (!c) {
        csum = getU16Be(lowpan[i .. i + 2]);
        i += 2;
    }
    const payload = lowpan[i..];

    // IPv6 Payload Length = UDP 头 8 字节 + 数据。
    putU16(hdr[4..6], 8 + @as(u16, @intCast(payload.len)));

    stats.decompressed += 1;
    return .{
        .hdr = hdr,
        .udp = .{
            .src_port = sport,
            .dst_port = dport,
            .checksum = csum,
            .checksum_present = !c,
        },
        .payload = payload,
    };
}

// ---------------------------------------------------------------------------
// KAT 固定字节串
// ---------------------------------------------------------------------------

/// FCF：数据帧 + Ack Request + PAN 压缩 + 双短地址 → 0x8861 → `61 88`。
pub const kat_fcf_short = [2]u8{ 0x61, 0x88 };
/// FCF：同上，但源地址是 64 位 → 0xC861 → `61 c8`。
pub const kat_fcf_long_src = [2]u8{ 0x61, 0xc8 };

/// 帧 A（短/短地址）：FCF + seq(0x2A) + DestPAN(0x1234) + Dest(0x0002) + Src(0x9A3C)。
pub const kat_mac_short = [9]u8{
    0x61, 0x88, // FCF = 0x8861
    0x2a, // sequence number
    0x34, 0x12, // dest PAN 0x1234
    0x02, 0x00, // dest short 0x0002
    0x3c, 0x9a, // src short 0x9A3C
};

/// 帧 A 的 6LoWPAN 载荷：
///   7F 22       IPHC：TF=11 NH=1 HLIM=11 | CID=0 SAC=0 SAM=10 M=0 DAC=0 DAM=10
///   3C 9A       源 16 位
///   02 00       目标 16 位
///   F0          NHC UDP：C=0 P=00
///   12 34 56 78 源端口 0x1234、目标端口 0x5678（网络序）
///   AB CD       校验和 0xABCD
///   6F 6B       "ok"
pub const kat_lowpan_short = [15]u8{
    0x7f, 0x22,
    0x3c, 0x9a,
    0x02, 0x00,
    0xf0, 0x12,
    0x34, 0x56,
    0x78, 0xab,
    0xcd, 'o',
    'k',
};

/// FCF 的完整帧（帧头 + 载荷）——判据 ⑨ 直接对它 encode/decode 往返。
pub const kat_frame_short = kat_mac_short ++ kat_lowpan_short;

/// 帧 B 的 MAC 头：源长地址 02:11:22:33:44:55:66:77，目标短地址 0x0002。
pub const kat_mac_long_src = [15]u8{
    0x61, 0xc8, // FCF = 0xC861
    0x2b,
    0x34, 0x12, // dest PAN
    0x02, 0x00, // dest short
    0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, // src long
};

/// 帧 B 的载荷：地址全省略（SAM=11 DAM=11）→ IPHC 字节 7F 33。
pub const kat_lowpan_elided = [11]u8{
    0x7f, 0x33,
    0xf0,
    0x00, 0x50, 0x00, 0x35, // 源端口 0x0050(80)、目标端口 0x0035(53)
    0x12, 0x34, 'h',  'i',
};

/// 判据 ⑫ 的拒绝帧：SAC=1（状态压缩）、SAM=01 → 需要上下文表。
/// IPHC = 7F 46。
pub const kat_lowpan_stateful = [4]u8{ 0x7f, 0x46, 0x00, 0x00 };
