//! ch23-tls-http：TLS 1.3 的密钥派生链（RFC 8446 §7.1）。
//!
//! 这一层没有状态机、没有握手、没有网络：它只回答「给一段共享秘密和
//! 一个转录哈希，能派生出哪些 32 字节密钥」。可测的部分全部是 HKDF：
//!
//!   HKDF-Extract(salt, IKM)               = HMAC(salt, IKM)          （RFC 5869 §2.2）
//!   HKDF-Expand(PRK, info, L)             = T(1)|T(2)|…|T(n) 截断 L  （RFC 5869 §2.3）
//!   HKDF-Expand-Label(Secret, Label, Ctx, L)
//!       = HKDF-Expand(Secret,
//!             HkdfLabel{ L, "tls13 " || Label, Ctx }, L)          （RFC 8446 §7.1）
//!   Derive-Secret(Secret, Label, Msgs)
//!       = HKDF-Expand-Label(Secret, Label, Transcript-Hash(Msgs), Hash.length)
//!
//! `HkdfLabel` 的线上编码是：
//!
//!     uint16 length;                       // 期望输出长度 L
//!     opaque label<7..255> = "tls13 " + Label;
//!     opaque context<0..255> = Context;
//!
//! 于是 label 字段的第 1 个字节是**整个 label 的长度**（含 6 字节前缀），
//! 而不是用户给的那段文字的长度。这是最容易写错的一处，自检专门钉它。
//!
//! 完整链条（本章只实现到 application traffic secret，不实现 Finished 与
//! 实际收发）：
//!
//!     early_secret      = HKDF-Extract(0, 0)
//!     derived           = Derive-Secret(early_secret, "derived", "")
//!     handshake_secret  = HKDF-Extract(derived, ECDHE)
//!     c hs traffic      = Derive-Secret(handshake_secret, "c hs traffic", …)
//!     s hs traffic      = Derive-Secret(handshake_secret, "s hs traffic", …)
//!     derived           = Derive-Secret(handshake_secret, "derived", "")
//!     master_secret     = HKDF-Extract(derived, 0)
//!     c ap traffic      = Derive-Secret(master_secret, "c ap traffic", …)
//!     s ap traffic      = Derive-Secret(master_secret, "s ap traffic", …)
//!     key/iv            = HKDF-Expand-Label(traffic_secret, "key"/"iv", "", len)
//!
//! 本章只到 traffic secret：`key`/`iv` 的派生根 RAEAD 参数有关（AES-128-GCM
//! 是 16/12 字节），留到 23.5 里由 `aead.zig` 接过（它只需 32 字节 secret）。

const std = @import("std");

pub const Hash = std.crypto.hash.sha2.Sha256;
pub const hash_length = Hash.digest_length; // 32
pub const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

/// RFC 8446 §7.1：label 前缀固定 "tls13 "（6 字节，含尾随空格）。
pub const label_prefix = "tls13 ";

pub const max_label = 64;
pub const max_context = 64;
pub const max_info = 2 + 1 + label_prefix.len + max_label + 1 + max_context;

pub const Error = error{ LabelTooLong, ContextTooLong, NoSpace };

pub fn extract(salt: []const u8, ikm: []const u8) [hash_length]u8 {
    return Hkdf.extract(salt, ikm);
}

pub fn expand(out: []u8, prk: [hash_length]u8, info: []const u8) void {
    Hkdf.expand(out, info, prk);
}

pub fn hash(data: []const u8) [hash_length]u8 {
    var out: [hash_length]u8 = undefined;
    Hash.hash(data, &out, .{});
    return out;
}

/// 把 `HkdfLabel` 编码进 `buf`，返回切片。这是 §7.1 的**结构本身**，
/// 单独暴露出来是为了让自检能把它和手工拼的字节逐字节比对。
pub fn encodeInfo(
    buf: []u8,
    out_len: u16,
    label: []const u8,
    context: []const u8,
) Error![]u8 {
    if (label.len > max_label) return Error.LabelTooLong;
    if (context.len > max_context) return Error.ContextTooLong;
    const label_len = label_prefix.len + label.len;
    if (label_len > 255) return Error.LabelTooLong;
    const need = 2 + 1 + label_len + 1 + context.len;
    if (need > buf.len) return Error.NoSpace;

    var w: usize = 0;
    buf[0] = @intCast(out_len >> 8);
    buf[1] = @intCast(out_len & 0xFF);
    w = 2;
    buf[w] = @intCast(label_len);
    w += 1;
    @memcpy(buf[w..][0..label_prefix.len], label_prefix);
    w += label_prefix.len;
    @memcpy(buf[w..][0..label.len], label);
    w += label.len;
    buf[w] = @intCast(context.len);
    w += 1;
    @memcpy(buf[w..][0..context.len], context);
    w += context.len;
    return buf[0..w];
}

/// HKDF-Expand-Label：先编码 `HkdfLabel`，再把它当 `info` 交给 HKDF-Expand。
pub fn expandLabel(
    out: []u8,
    secret: [hash_length]u8,
    label: []const u8,
    context: []const u8,
) Error!void {
    if (out.len > 0xFFFF) return Error.NoSpace;
    var info_buf: [max_info]u8 = undefined;
    const info = try encodeInfo(&info_buf, @intCast(out.len), label, context);
    expand(out, secret, info);
}

/// Derive-Secret：transcript 先哈希，再作为 context 传给 Expand-Label。
pub fn deriveSecret(
    secret: [hash_length]u8,
    label: []const u8,
    transcript: []const u8,
) Error![hash_length]u8 {
    var out: [hash_length]u8 = undefined;
    try expandLabel(&out, secret, label, &hash(transcript));
    return out;
}

/// 一条完整链的产物。字段名直接对应 RFC 8446 §7.1 的图。
pub const Schedule = struct {
    early_secret: [hash_length]u8,
    handshake_secret: [hash_length]u8,
    client_hs_traffic: [hash_length]u8,
    server_hs_traffic: [hash_length]u8,
    master_secret: [hash_length]u8,
    client_ap_traffic: [hash_length]u8,
    server_ap_traffic: [hash_length]u8,
};

/// 从 ECDHE 共享秘密 + 两个转录哈希走完整条链。
///
/// `hs_transcript` 是 ClientHello…ServerHello 的转录；
/// `ap_transcript` 是 ClientHello…server Finished 的转录。
pub fn buildSchedule(
    shared_secret: []const u8,
    hs_transcript: []const u8,
    ap_transcript: []const u8,
) Error!Schedule {
    const zeros: [hash_length]u8 = @splat(0);
    const empty: []const u8 = "";

    const early = extract(empty, &zeros);
    const derived_early = try deriveSecret(early, "derived", empty);
    const handshake = extract(&derived_early, shared_secret);
    const c_hs = try deriveSecret(handshake, "c hs traffic", hs_transcript);
    const s_hs = try deriveSecret(handshake, "s hs traffic", hs_transcript);
    const derived_hs = try deriveSecret(handshake, "derived", empty);
    const master = extract(&derived_hs, &zeros);
    const c_ap = try deriveSecret(master, "c ap traffic", ap_transcript);
    const s_ap = try deriveSecret(master, "s ap traffic", ap_transcript);

    return .{
        .early_secret = early,
        .handshake_secret = handshake,
        .client_hs_traffic = c_hs,
        .server_hs_traffic = s_hs,
        .master_secret = master,
        .client_ap_traffic = c_ap,
        .server_ap_traffic = s_ap,
    };
}

// ---------------------------------------------------------------------------
// 自测：RFC 5869 附录 A.1 的已知答案 + HkdfLabel 的结构
// ---------------------------------------------------------------------------

// RFC 5869 A.1（SHA-256）：
//   IKM  = 0x0b × 22
//   salt = 0x000102…0c（13 字节）
//   info = 0xf0f1…f9（10 字节）
//   L    = 42
//   PRK  = 077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5
//   OKM  = 3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf
//          34007208d5b887185865
pub const rfc5869_ikm: [22]u8 = @splat(0x0b);
pub const rfc5869_salt = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
pub const rfc5869_info = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9 };
pub const rfc5869_prk = [_]u8{
    0x07, 0x77, 0x09, 0x36, 0x2c, 0x2e, 0x32, 0xdf, 0x0d, 0xdc, 0x3f, 0x0d, 0xc4, 0x7b, 0xba, 0x63,
    0x90, 0xb6, 0xc7, 0x3b, 0xb5, 0x0f, 0x9c, 0x31, 0x22, 0xec, 0x84, 0x4a, 0xd7, 0xc2, 0xb3, 0xe5,
};
pub const rfc5869_okm = [_]u8{
    0x3c, 0xb2, 0x5f, 0x25, 0xfa, 0xac, 0xd5, 0x7a, 0x90, 0x43, 0x4f, 0x64, 0xd0, 0x36, 0x2f, 0x2a,
    0x2d, 0x2d, 0x0a, 0x90, 0xcf, 0x1a, 0x5a, 0x4c, 0x5d, 0xb0, 0x2d, 0x56, 0xec, 0xc4, 0xc5, 0xbf,
    0x34, 0x00, 0x72, 0x08, 0xd5, 0xb8, 0x87, 0x18, 0x58, 0x65,
};

test "RFC 5869 A.1 extract" {
    try std.testing.expectEqualSlices(u8, &rfc5869_prk, &extract(&rfc5869_salt, &rfc5869_ikm));
}

test "RFC 5869 A.1 expand" {
    var okm: [42]u8 = undefined;
    expand(&okm, rfc5869_prk, &rfc5869_info);
    try std.testing.expectEqualSlices(u8, &rfc5869_okm, &okm);
}

test "HkdfLabel layout carries the tls13 prefix and lengths" {
    var buf: [max_info]u8 = undefined;
    const info = try encodeInfo(&buf, 32, "key", &[_]u8{ 0x01, 0x02 });
    // length(2) = 0x0020
    try std.testing.expectEqual(@as(u8, 0x00), info[0]);
    try std.testing.expectEqual(@as(u8, 0x20), info[1]);
    // label<.. 的 length 字节 = 6 + 3 = 9
    try std.testing.expectEqual(@as(u8, 9), info[2]);
    try std.testing.expectEqualStrings("tls13 key", info[3..12]);
    try std.testing.expectEqual(@as(u8, 2), info[12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, info[13..15]);
    try std.testing.expectEqual(@as(usize, 15), info.len);
}

// ---------------------------------------------------------------------------
// RFC 8448 §3（Simple 1-RTT Handshake）的中间值
//
// 这是全章唯一一组“不是我们自己算出来的”密钥材料：它来自 RFC 8448 正文，
// 覆盖 early/derived/handshake 三段 Extract 与 c/s hs traffic 两条
// Expand-Label。把它当判据的价值在于：RFC 5869 A.1 只钉住了 HKDF 本身，
// 而这里钉住的是**标签、长度、转录哈希三者拼起来的形状**——也就是 §7.1
// 那张图。写错一个 `"c hs traffic"` 里的空格，这组值立刻对不上。
// ---------------------------------------------------------------------------
pub const rfc8448 = struct {
    /// §3 的 ECDHE 共享秘密（X25519，32 字节原样）。
    pub const shared = [_]u8{
        0x8b, 0xd4, 0x05, 0x4f, 0xb5, 0x5b, 0x9d, 0x63, 0xfd, 0xfb, 0xac, 0xf9, 0xf0, 0x4b, 0x9f, 0x0d,
        0x35, 0xe6, 0xd6, 0x3f, 0x53, 0x75, 0x63, 0xef, 0xd4, 0x62, 0x72, 0x90, 0x0f, 0x89, 0x49, 0x2d,
    };
    /// HKDF-Extract(0, 0)。
    pub const early_secret = [_]u8{
        0x33, 0xad, 0x0a, 0x1c, 0x60, 0x7e, 0xc0, 0x3b, 0x09, 0xe6, 0xcd, 0x98, 0x93, 0x68, 0x0c, 0xe2,
        0x10, 0xad, 0xf3, 0x00, 0xaa, 0x1f, 0x26, 0x60, 0xe1, 0xb2, 0x2e, 0x10, 0xf1, 0x70, 0xf9, 0x2a,
    };
    /// Derive-Secret(early_secret, "derived", "")。
    pub const derived_early = [_]u8{
        0x6f, 0x26, 0x15, 0xa1, 0x08, 0xc7, 0x02, 0xc5, 0x67, 0x8f, 0x54, 0xfc, 0x9d, 0xba, 0xb6, 0x97,
        0x16, 0xc0, 0x76, 0x18, 0x9c, 0x48, 0x25, 0x0c, 0xeb, 0xea, 0xc3, 0x57, 0x6c, 0x36, 0x11, 0xba,
    };
    /// HKDF-Extract(derived_early, shared)。
    pub const handshake_secret = [_]u8{
        0x1d, 0xc8, 0x26, 0xe9, 0x36, 0x06, 0xaa, 0x6f, 0xdc, 0x0a, 0xad, 0xc1, 0x2f, 0x74, 0x1b, 0x01,
        0x04, 0x6a, 0xa6, 0xb9, 0x9f, 0x69, 0x1e, 0xd2, 0x21, 0xa9, 0xf0, 0xca, 0x04, 0x3f, 0xbe, 0xac,
    };
    /// ClientHello…ServerHello 的转录哈希。
    pub const hs_transcript_hash = [_]u8{
        0x86, 0x0c, 0x06, 0xed, 0xc0, 0x78, 0x58, 0xee, 0x8e, 0x78, 0xf0, 0xe7, 0x42, 0x8c, 0x58, 0xed,
        0xd6, 0xb4, 0x3f, 0x2c, 0xa3, 0xe6, 0xe9, 0x5f, 0x02, 0xed, 0x06, 0x3c, 0xf0, 0xe1, 0xca, 0xd8,
    };
    /// Derive-Secret(handshake_secret, "c hs traffic", …)。
    pub const client_hs_traffic = [_]u8{
        0xb3, 0xed, 0xdb, 0x12, 0x6e, 0x06, 0x7f, 0x35, 0xa7, 0x80, 0xb3, 0xab, 0xf4, 0x5e, 0x2d, 0x8f,
        0x3b, 0x1a, 0x95, 0x07, 0x38, 0xf5, 0x2e, 0x96, 0x00, 0x74, 0x6a, 0x0e, 0x27, 0xa5, 0x5a, 0x21,
    };
    /// Derive-Secret(handshake_secret, "s hs traffic", …)。
    pub const server_hs_traffic = [_]u8{
        0xb6, 0x7b, 0x7d, 0x69, 0x0c, 0xc1, 0x6c, 0x4e, 0x75, 0xe5, 0x42, 0x13, 0xcb, 0x2d, 0x37, 0xb4,
        0xe9, 0xc9, 0x12, 0xbc, 0xde, 0xd9, 0x10, 0x5d, 0x42, 0xbe, 0xfd, 0x59, 0xd3, 0x91, 0xad, 0x38,
    };
};

pub const Rfc8448Chain = struct {
    early: [hash_length]u8,
    derived: [hash_length]u8,
    handshake: [hash_length]u8,
    client_hs: [hash_length]u8,
    server_hs: [hash_length]u8,

    /// 五项全部与 RFC 8448 §3 一致时返回 true。
    pub fn matches(self: *const Rfc8448Chain) bool {
        return std.mem.eql(u8, &self.early, &rfc8448.early_secret) and
            std.mem.eql(u8, &self.derived, &rfc8448.derived_early) and
            std.mem.eql(u8, &self.handshake, &rfc8448.handshake_secret) and
            std.mem.eql(u8, &self.client_hs, &rfc8448.client_hs_traffic) and
            std.mem.eql(u8, &self.server_hs, &rfc8448.server_hs_traffic);
    }
};

/// 用 RFC 8448 §3 的共享秘密与转录哈希走一遍（不含实际握手）。
///
/// 与 `buildSchedule` 的区别：转录哈希由 RFC 直接给出，不再对消息求哈希；
/// 这样这组值只检验 §7.1 的派生形状，不掺入“消息序列化是否正确”。
pub fn rfc8448Chain() Error!Rfc8448Chain {
    const zeros: [hash_length]u8 = @splat(0);
    const early = extract("", &zeros);
    const derived = try deriveSecret(early, "derived", "");
    const handshake = extract(&derived, &rfc8448.shared);

    var c_hs: [hash_length]u8 = undefined;
    var s_hs: [hash_length]u8 = undefined;
    try expandLabel(&c_hs, handshake, "c hs traffic", &rfc8448.hs_transcript_hash);
    try expandLabel(&s_hs, handshake, "s hs traffic", &rfc8448.hs_transcript_hash);

    return .{ .early = early, .derived = derived, .handshake = handshake, .client_hs = c_hs, .server_hs = s_hs };
}

test "RFC 8448 3: handshake key schedule matches the trace" {
    const chain = try rfc8448Chain();
    try std.testing.expect(chain.matches());
    try std.testing.expectEqualSlices(u8, &rfc8448.early_secret, &chain.early);
    try std.testing.expectEqualSlices(u8, &rfc8448.handshake_secret, &chain.handshake);
    try std.testing.expectEqualSlices(u8, &rfc8448.client_hs_traffic, &chain.client_hs);
    try std.testing.expectEqualSlices(u8, &rfc8448.server_hs_traffic, &chain.server_hs);
}

test "RFC 8448 3: empty-transcript hash is the SHA-256 of the empty string" {
    const h = hash("");
    const expected = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    try std.testing.expectEqualSlices(u8, &expected, &h);
}
