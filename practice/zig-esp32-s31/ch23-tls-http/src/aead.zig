//! ch23-tls-http：AEAD —— TLS 1.3 的 AES-128-GCM（RFC 8446 §5.3、RFC 5116）。
//!
//! TLS 1.3 的 `TLSCiphertext` 只剩一个能用的大件：AEAD。它把三样东西
//! 绑定在一起，缺一样都解不出来：
//!
//!     plaintext  = TLSInnerPlaintext = content || content_type(1) || zeros…
//!     additional = TLSCiphertext.opaque_type(1) || legacy_record_version(2) ||
//!                  length(2)                        ← 记录头，**密文长度**
//!     nonce      = iv XOR (0^… || sequence_number)  ← §5.3，写侧 64 位计数
//!
//! 于是「改一个字节的记录头」会直接导致 tag 校验失败——这是把记录层与
//! AEAD 绑死的设计目的，不是巧合。本章的 `additionalData()` 就按这
//! 5 个字节生成，自检第 ⑥ 条专门验证「改 AD 之后 tag 不再通过」。
//!
//! 已知答案取 NIST SP 800-38D 的 AES-128-GCM 例（也是 RFC 5116 附录 B
//! 引用的一组）：
//!
//!   K = 00…00（16 字节）, IV = 00…00（12 字节）, P 为空, A 为空
//!     → T = 58e2fccefa7e3061367f1d57a4e7455a
//!   K = 00…00, IV = 00…00, P = 00…00（16 字节）, A 为空
//!     → C = 0388dace60b6a392f328c2b971b2fe78
//!       T = ab6e47d42cec13bdf53a67b21257bddf
//!
//! 本章只提供两种形状：
//!   - `sealWithNonce` / `openWithNonce`：直接给 nonce（NIST 向量用）；
//!   - `seal` / `open`：给 iv + sequence_number，按 TLS 1.3 的 XOR 规则
//!     生成 nonce（真实记录用）。

const std = @import("std");

pub const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
pub const key_length = Aes128Gcm.key_length; // 16
pub const nonce_length = Aes128Gcm.nonce_length; // 12
pub const tag_length = Aes128Gcm.tag_length; // 16

pub const Error = error{
    /// tag 校验失败（密文/AD/nonce 三者中至少一个不对）。
    AuthenticationFailed,
    /// 明文超过了 AEAD 的单次上限（2^14 字节的记录）。
    MessageTooLarge,
};

/// TLS 1.3 §5.3：nonce = iv XOR (0^32 || seq)，seq 是 64 位大端。
pub fn nonceFor(iv: [nonce_length]u8, sequence: u64) [nonce_length]u8 {
    var nonce = iv;
    var seq_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_bytes, sequence, .big);
    for (seq_bytes, 0..) |b, i| {
        nonce[nonce_length - 8 + i] ^= b;
    }
    return nonce;
}

/// TLSCiphertext 的 additional data：type(1) || legacy_version(2) || length(2)。
pub fn additionalData(ct: u8, ciphertext_len: usize) [5]u8 {
    return .{
        ct,
        0x03,
        0x03,
        @intCast((ciphertext_len >> 8) & 0xFF),
        @intCast(ciphertext_len & 0xFF),
    };
}

/// 直接给 nonce 的加封（NIST 向量、自检用）。
pub fn sealWithNonce(
    ct: []u8,
    tag: *[tag_length]u8,
    plaintext: []const u8,
    ad: []const u8,
    nonce: [nonce_length]u8,
    key: [key_length]u8,
) Error!void {
    if (plaintext.len > ct.len) return Error.MessageTooLarge;
    Aes128Gcm.encrypt(ct[0..plaintext.len], tag, plaintext, ad, nonce, key);
}

/// 直接给 nonce 的解封；tag 不对返回 `AuthenticationFailed`。
///
/// 注意 `std.crypto.aead.aes_gcm` 的 `decrypt` 是**先校验 tag 再写明文**，
/// 所以我们这里不需要「写进临时缓冲再回滚」的套路——但 API 层面仍然要
/// 把错误翻译成本章的 `Error`，不让上层看见 std 的错误集。
pub fn openWithNonce(
    plaintext: []u8,
    ct: []const u8,
    tag: [tag_length]u8,
    ad: []const u8,
    nonce: [nonce_length]u8,
    key: [key_length]u8,
) Error!void {
    if (ct.len > plaintext.len) return Error.MessageTooLarge;
    Aes128Gcm.decrypt(plaintext[0..ct.len], ct, tag, ad, nonce, key) catch return Error.AuthenticationFailed;
}

/// 记录级加封：nonce 由 iv + seq 生成，AD 由记录头生成。
pub fn seal(
    ct: []u8,
    tag: *[tag_length]u8,
    plaintext: []const u8,
    record_type: u8,
    iv: [nonce_length]u8,
    sequence: u64,
    key: [key_length]u8,
) Error!void {
    const ad = additionalData(record_type, plaintext.len + tag_length);
    try sealWithNonce(ct, tag, plaintext, &ad, nonceFor(iv, sequence), key);
}

pub fn open(
    plaintext: []u8,
    ct: []const u8,
    tag: [tag_length]u8,
    record_type: u8,
    iv: [nonce_length]u8,
    sequence: u64,
    key: [key_length]u8,
) Error!void {
    const ad = additionalData(record_type, ct.len + tag_length);
    try openWithNonce(plaintext, ct, tag, &ad, nonceFor(iv, sequence), key);
}

/// TLS 1.3 §7.3：traffic secret → key/iv。
/// AES-128-GCM 的 key 16 字节、iv 12 字节，用 HKDF-Expand-Label 派生。
pub fn deriveKeyIv(
    secret: [32]u8,
    out_key: *[key_length]u8,
    out_iv: *[nonce_length]u8,
) void {
    const ks = @import("tls_keyschedule.zig");
    // 这里的 label 不带 "tls13 " 前缀——`encodeInfo` 会补。
    ks.expandLabel(out_key, secret, "key", "") catch unreachable;
    ks.expandLabel(out_iv, secret, "iv", "") catch unreachable;
}

// ---------------------------------------------------------------------------
// NIST SP 800-38D / RFC 5116 向量
// ---------------------------------------------------------------------------

const zero_key: [16]u8 = @splat(0);
const zero_iv: [12]u8 = @splat(0);

pub const nist_empty_tag = [_]u8{
    0x58, 0xe2, 0xfc, 0xce, 0xfa, 0x7e, 0x30, 0x61, 0x36, 0x7f, 0x1d, 0x57, 0xa4, 0xe7, 0x45, 0x5a,
};
pub const nist_16_ct = [_]u8{
    0x03, 0x88, 0xda, 0xce, 0x60, 0xb6, 0xa3, 0x92, 0xf3, 0x28, 0xc2, 0xb9, 0x71, 0xb2, 0xfe, 0x78,
};
pub const nist_16_tag = [_]u8{
    0xab, 0x6e, 0x47, 0xd4, 0x2c, 0xec, 0x13, 0xbd, 0xf5, 0x3a, 0x67, 0xb2, 0x12, 0x57, 0xbd, 0xdf,
};

test "NIST GCM: empty plaintext tag" {
    var tag: [tag_length]u8 = undefined;
    var ct: [0]u8 = undefined;
    try sealWithNonce(&ct, &tag, "", "", zero_iv, zero_key);
    try std.testing.expectEqualSlices(u8, &nist_empty_tag, &tag);
}

test "NIST GCM: 16 zero bytes" {
    const pt: [16]u8 = @splat(0);
    var ct: [16]u8 = undefined;
    var tag: [tag_length]u8 = undefined;
    try sealWithNonce(&ct, &tag, &pt, "", zero_iv, zero_key);
    try std.testing.expectEqualSlices(u8, &nist_16_ct, &ct);
    try std.testing.expectEqualSlices(u8, &nist_16_tag, &tag);

    var back: [16]u8 = undefined;
    try openWithNonce(&back, &ct, tag, "", zero_iv, zero_key);
    try std.testing.expectEqualSlices(u8, &pt, &back);

    // 改 1 bit tag：必须失败。
    var bad = tag;
    bad[tag_length - 1] ^= 1;
    try std.testing.expectError(Error.AuthenticationFailed, openWithNonce(&back, &ct, bad, "", zero_iv, zero_key));

    // 改 AD：必须失败（这就是“记录头被绑进 tag”的机制）。
    try std.testing.expectError(Error.AuthenticationFailed, openWithNonce(&back, &ct, tag, &[_]u8{0x17}, zero_iv, zero_key));
}

test "nonce XORs only the low 8 bytes" {
    const iv = @as([12]u8, @splat(0xAA));
    const n = nonceFor(iv, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xAA, 0xAA, 0xAA }, n[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAB }, n[4..12]);
}
