//! ch23-tls-http：X25519（RFC 7748）—— ECDHE 的已知答案与调用面。
//!
//! TLS 1.3 的 (EC)DHE 共享秘密只要求「双方算出同一个 32 字节串」，
//! 曲线运算本身不参与 key schedule。本章用 X25519 做这一层，因为它
//! 在 RFC 7748 §6.1 里给了两份可以直接抄进代码的已知答案：
//!
//!   ┌─────────────────────────────────────────────────────────────┐
//!   │ 输入标量 (a546e36b…) × 输入 u 坐标 (e6db6867…)              │
//!   │   → c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4…   │
//!   │ 输入标量 (4b66e9d4…) × 输入 u 坐标 (e5210f12…)              │
//!   │   → 95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8…   │
//!   └─────────────────────────────────────────────────────────────┘
//!
//! 两条向量都在 `test` 里逐字节比对；板侧自检（`selftest.zig`）用同一份
//! 常量再跑一遍，证明 rv32 上没有把 64 位 limb 的进位写错。
//!
//! **安全边界**（写清楚，免得被当成“完整 DH”）：本章只调用
//! `std.crypto.dh.X25519`，不做：
//!   - 私钥的随机生成（板上没有可信熵源；自检用固定 seed）；
//!   - 低阶点拒绝之外的对端公钥校验（std 在输出全零时返回
//!     `error.IdentityElement`，这正是 RFC 8446 §7.4.2 要求的检查）；
//!   - 密钥的即时擦除（`@memset` 清零只在自检里演示一次）。
//!
//! 共享秘密怎么交给 HKDF：**原样 32 字节，不做任何裁剪**。
//! RFC 8446 §7.4.2 明确规定 `FE2OSP` 的输出对给定字段是定长的，
//! 且 “leading zeros found in this octet string MUST NOT be truncated”，
//! 并特意加了一句“this construction differs from previous versions of TLS
//! which removed leading zeros”——去前导零是 TLS 1.2 的旧规则，TLS 1.3 反过来
//! 要求保留。本章按 TLS 1.3 的做法：`scalarmult()` 的 32 字节输出直接进
//! `tls_keyschedule.buildSchedule()`，长度永远是 32。

const std = @import("std");

pub const Dh = std.crypto.dh.X25519;
pub const key_length = 32;
pub const scalar_length = 32;

pub const Error = error{ LowOrderPoint, ZeroShared };

/// RFC 7748 §6.1 的第一组向量。
pub const rfc7748_1 = struct {
    pub const scalar = [_]u8{
        0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d, 0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
        0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18, 0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
    };
    pub const u = [_]u8{
        0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb, 0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c,
        0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b, 0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c,
    };
    pub const out = [_]u8{
        0xc3, 0xda, 0x55, 0x37, 0x9d, 0xe9, 0xc6, 0x90, 0x8e, 0x94, 0xea, 0x4d, 0xf2, 0x8d, 0x08, 0x4f,
        0x32, 0xec, 0xcf, 0x03, 0x49, 0x1c, 0x71, 0xf7, 0x54, 0xb4, 0x07, 0x55, 0x77, 0xa2, 0x85, 0x52,
    };
};

/// RFC 7748 §6.1 的第二组向量。
pub const rfc7748_2 = struct {
    pub const scalar = [_]u8{
        0x4b, 0x66, 0xe9, 0xd4, 0xd1, 0xb4, 0x67, 0x3c, 0x5a, 0xd2, 0x26, 0x91, 0x95, 0x7d, 0x6a, 0xf5,
        0xc1, 0x1b, 0x64, 0x21, 0xe0, 0xea, 0x01, 0xd4, 0x2c, 0xa4, 0x16, 0x9e, 0x79, 0x18, 0xba, 0x0d,
    };
    pub const u = [_]u8{
        0xe5, 0x21, 0x0f, 0x12, 0x78, 0x68, 0x11, 0xd3, 0xf4, 0xb7, 0x95, 0x9d, 0x05, 0x38, 0xae, 0x2c,
        0x31, 0xdb, 0xe7, 0x10, 0x6f, 0xc0, 0x3c, 0x3e, 0xfc, 0x4c, 0xd5, 0x49, 0xc7, 0x15, 0xa4, 0x93,
    };
    pub const out = [_]u8{
        0x95, 0xcb, 0xde, 0x94, 0x76, 0xe8, 0x90, 0x7d, 0x7a, 0xad, 0xe4, 0x5c, 0xb4, 0xb8, 0x73, 0xf8,
        0x8b, 0x59, 0x5a, 0x68, 0x79, 0x9f, 0xa1, 0x52, 0xe6, 0xf8, 0xf7, 0x64, 0x7a, 0xac, 0x79, 0x57,
    };
};

/// 自检用的固定 seed（不是密钥！只是为了让板侧读数可复现）。
pub const selftest_seed: [32]u8 = @splat(0x23);

/// 一次 X25519。低阶点（输出全零）按 RFC 8446 §7.4.2 直接拒绝。
pub fn scalarmult(secret: [scalar_length]u8, peer: [key_length]u8) Error![key_length]u8 {
    const shared = Dh.scalarmult(secret, peer) catch return Error.LowOrderPoint;
    if (std.mem.allEqual(u8, &shared, 0)) return Error.ZeroShared;
    return shared;
}

pub fn publicKey(secret: [scalar_length]u8) [key_length]u8 {
    return Dh.recoverPublicKey(secret);
}

/// 自检里用的清零：编译器不保证 `@memset` 不被优化掉，所以走一次
/// `std.crypto.secureZero` 的等价物（volatile 写），将来接真实握手时
/// 直接复用。
pub fn wipe(buf: []u8) void {
    for (buf) |*b| {
        const p: *volatile u8 = b;
        p.* = 0;
    }
}

test "RFC 7748 6.1 vector 1" {
    const out = try scalarmult(rfc7748_1.scalar, rfc7748_1.u);
    try std.testing.expectEqualSlices(u8, &rfc7748_1.out, &out);
}

test "RFC 7748 6.1 vector 2" {
    const out = try scalarmult(rfc7748_2.scalar, rfc7748_2.u);
    try std.testing.expectEqualSlices(u8, &rfc7748_2.out, &out);
}

test "all-zero peer key is rejected" {
    const zeros: [32]u8 = @splat(0);
    try std.testing.expectError(Error.LowOrderPoint, scalarmult(selftest_seed, zeros));
}

test "DH symmetry: a*b == b*a" {
    // 固定 seed 派生两对密钥，验证双方算出的共享秘密一致。
    const a_sk = selftest_seed;
    const b_sk: [32]u8 = @splat(0x42);
    const a_pk = publicKey(a_sk);
    const b_pk = publicKey(b_sk);
    const s1 = try scalarmult(a_sk, b_pk);
    const s2 = try scalarmult(b_sk, a_pk);
    try std.testing.expectEqualSlices(u8, &s1, &s2);
}
