//! ch23-tls-http：TLS 1.3 记录层（RFC 8446 §5）与握手消息分帧（§4）。
//!
//! 这一层只做两件事：
//!
//!   1. **外壳**：`TLSPlaintext` / `TLSCiphertext` 的公共头
//!      `type(1) legacy_record_version(2) length(2) + fragment`。
//!      TLS 1.3 把 `legacy_record_version` 钉成 `0x0303`（§5.1），
//!      即使里面装的是 TLS 1.3 的密文；`length` 的上限是 2^14 + 256
//!      字节（§5.2：明文 2^14，密文允许 256 字节 AEAD 膨胀）。
//!   2. **内芯**：`Handshake` 结构 `msg_type(1) length(3) body`。
//!      握手消息可以跨记录边界，也可以一条记录里塞多条消息，所以
//!      读侧必须按 4 字节头里的长度自己重组。
//!
//! 本章**不做**的事（见 23.11 的边界节）：
//!   - 不校验 MAC（那是 AEAD 层的事，见 `aead.zig`）；
//!   - 不处理 padding（TLS 1.3 的 `Padding` 扩展只影响明文长度）；
//!   - 不实现压缩（TLS 1.3 已删除 compression_method）；
//!   - 不检查 `ChangeCipherSpec` 的兼容模式规则（服务端可能发一条
//!     内容为 `0x01` 的 CCS 记录，本章只把它当合法类型放行）。
//!
//! 所有接口都是「零分配」：分片返回输入切片的子区间，重组用调用方
//! 提供的缓冲。板侧这些缓冲是 `.bss` 静态对象（见 `selftest.zig`）。

const std = @import("std");

pub const header_len = 5;
pub const handshake_header_len = 4;

/// 明文分片上限：2^14。
pub const max_plaintext = 1 << 14;
/// AEAD 允许的膨胀：256。
pub const max_expansion = 256;
/// 记录长度硬上限：2^14 + 256 = 16640（RFC 8446 §5.2）。
pub const max_record_length = max_plaintext + max_expansion;

/// TLS 1.3 记录的 legacy_record_version 固定值（§5.1）。
pub const legacy_record_version: u16 = 0x0303;

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

pub const Error = error{
    Truncated,
    BadContentType,
    BadVersion,
    RecordTooLarge,
    EmptyFragment,
    BadHandshakeLength,
    NoSpace,
    NotHandshake,
    BadMessageType,
};

pub fn contentTypeFromByte(b: u8) Error!ContentType {
    return switch (b) {
        20 => .change_cipher_spec,
        21 => .alert,
        22 => .handshake,
        23 => .application_data,
        else => Error.BadContentType,
    };
}

pub const RecordHeader = struct {
    content_type: ContentType,
    legacy_version: u16,
    length: u16,
};

/// 写一个记录头。`len` 是 fragment 的字节数（不是总数）。
pub fn writeHeader(out: *[header_len]u8, ct: ContentType, len: usize) Error!void {
    if (len > max_record_length) return Error.RecordTooLarge;
    out[0] = @backingInt(ct);
    out[1] = @intCast(legacy_record_version >> 8);
    out[2] = @intCast(legacy_record_version & 0xFF);
    out[3] = @intCast((len >> 8) & 0xFF);
    out[4] = @intCast(len & 0xFF);
}

/// 解析并校验一个记录头。
///
/// `legacy_record_version` 的判定放宽到 `0x0301..0x0304`：TLS 1.3 客户端
/// 的第一条 ClientHello 常带 `0x0301`（§5.1 的注释），只要不是更高版本
/// 就算合法——真正的版本协商看 ClientHello 里的 supported_versions。
pub fn readHeader(in: []const u8) Error!RecordHeader {
    if (in.len < header_len) return Error.Truncated;
    const ct = try contentTypeFromByte(in[0]);
    const version = (@as(u16, in[1]) << 8) | in[2];
    if (version < 0x0301 or version > 0x0304) return Error.BadVersion;
    const length = (@as(u16, in[3]) << 8) | in[4];
    if (length > max_record_length) return Error.RecordTooLarge;
    if (length == 0) return Error.EmptyFragment;
    return .{ .content_type = ct, .legacy_version = version, .length = length };
}

/// 把一段载荷按 `frag_max` 切成若干记录片段。`frag_max` 必须 ≤ 2^14。
pub const Splitter = struct {
    payload: []const u8,
    frag_max: usize,
    pos: usize = 0,

    pub fn init(payload: []const u8, frag_max: usize) Error!Splitter {
        if (frag_max == 0 or frag_max > max_plaintext) return Error.RecordTooLarge;
        return .{ .payload = payload, .frag_max = frag_max };
    }

    /// 取下一片；没有剩余时返回 null。
    pub fn next(self: *Splitter) ?[]const u8 {
        if (self.pos >= self.payload.len) return null;
        const end = @min(self.pos + self.frag_max, self.payload.len);
        const out = self.payload[self.pos..end];
        self.pos = end;
        return out;
    }
};

// ---------------------------------------------------------------------------
// 握手消息分帧
// ---------------------------------------------------------------------------

pub fn handshakeLength(header: []const u8) Error!usize {
    if (header.len < handshake_header_len) return Error.Truncated;
    return (@as(usize, header[1]) << 16) | (@as(usize, header[2]) << 8) | header[3];
}

pub fn writeHandshakeHeader(out: *[handshake_header_len]u8, msg_type: u8, len: usize) Error!void {
    if (len > 0xFF_FFFF) return Error.BadHandshakeLength;
    out[0] = msg_type;
    out[1] = @intCast((len >> 16) & 0xFF);
    out[2] = @intCast((len >> 8) & 0xFF);
    out[3] = @intCast(len & 0xFF);
}

/// 跨记录重组的握手读侧。
///
/// 用法：每收到一条 `content_type == handshake` 的记录就 `push()` 它的
/// fragment；返回非 null 时表示一条完整握手消息已经拼好。多条消息可以
/// 连续出现在同一条记录里，`push()` 只交出一条，剩余的留在内部缓冲。
pub const MessageReader = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) MessageReader {
        return .{ .buf = buf };
    }

    pub fn reset(self: *MessageReader) void {
        self.len = 0;
    }

    /// 追加一段 fragment，必要时返回一条完整消息（借用内部缓冲）。
    pub fn push(self: *MessageReader, ct: ContentType, fragment: []const u8) Error!?[]const u8 {
        if (ct != .handshake) return Error.NotHandshake;
        if (fragment.len > self.buf.len - self.len) return Error.NoSpace;
        @memcpy(self.buf[self.len..][0..fragment.len], fragment);
        self.len += fragment.len;
        return self.take();
    }

    /// 缓冲区里已经够一条完整消息时把它交出来（否则返回 null）。
    /// 一条记录里塞了两条消息时，`push()` 之后连续调用它即可。
    pub fn take(self: *MessageReader) Error!?[]const u8 {
        if (self.len < handshake_header_len) return null;
        const msg_len = try handshakeLength(self.buf[0..handshake_header_len]);
        if (msg_len > self.buf.len - handshake_header_len) return Error.BadHandshakeLength;
        const total = handshake_header_len + msg_len;
        if (self.len < total) return null;

        const msg = self.buf[0..total];
        // 把同一记录里剩下的字节挪到最前面，供下一次 push 之前的检查用。
        const rest = self.len - total;
        if (rest > 0) std.mem.copyForwards(u8, self.buf[0..rest], self.buf[total..self.len]);
        self.len = rest;
        return msg;
    }
};

/// 一条记录头 + fragment 的便捷视图（不做拷贝）。
pub const Record = struct {
    header: RecordHeader,
    fragment: []const u8,
};

pub fn splitOne(in: []const u8) Error!Record {
    const header = try readHeader(in);
    if (in.len < header_len + header.length) return Error.Truncated;
    return .{ .header = header, .fragment = in[header_len..][0..header.length] };
}

/// 校验「一批记录」的总长度与每条记录的长度字段是否自洽。
/// 返回记录条数。用于自检：把 Splitter 的产物串起来再读一遍。
pub fn countRecords(payload: []const u8) Error!usize {
    var n: usize = 0;
    var pos: usize = 0;
    while (pos < payload.len) {
        if (pos + header_len > payload.len) return Error.Truncated;
        const header = try readHeader(payload[pos..]);
        pos += header_len;
        if (pos + header.length > payload.len) return Error.Truncated;
        pos += header.length;
        n += 1;
    }
    return n;
}

test "record header roundtrip" {
    var hdr: [header_len]u8 = undefined;
    try writeHeader(&hdr, .application_data, 1024);
    const h = try readHeader(&hdr);
    try std.testing.expectEqual(ContentType.application_data, h.content_type);
    try std.testing.expectEqual(legacy_record_version, h.legacy_version);
    try std.testing.expectEqual(@as(u16, 1024), h.length);
}

test "record length limit is 2^14+256" {
    try std.testing.expectEqual(@as(usize, 16640), max_record_length);
    var hdr: [header_len]u8 = undefined;
    try std.testing.expectError(Error.RecordTooLarge, writeHeader(&hdr, .handshake, max_record_length + 1));

    // 手工造一个声称 16641 字节的记录头：必须被 readHeader 拒掉。
    const bad = [_]u8{ 22, 0x03, 0x03, 0x41, 0x01 };
    try std.testing.expectError(Error.RecordTooLarge, readHeader(&bad));
}
