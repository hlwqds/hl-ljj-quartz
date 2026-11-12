//! ch26-wifi-connection-wpa2-wpa3：WPA2-PSK 与 4-way handshake 的可测部分。
//!
//! 本章**不实现 CCMP/AES**、不实现射频、不链接 Wi-Fi blob。这里只有三层
//! 纯逻辑，全部可以在 x86_64 上跑、也可以在同一块 rv32 上跑：
//!
//!   1. 密钥派生：passphrase + SSID → PMK（PBKDF2-HMAC-SHA1，4096 轮，
//!      IEEE 802.11i Annex H.4），PMK + 两个 nonce + 两个 MAC → PTK
//!      （PRF-384/PRF-512，802.11i 8.5.1.1）；
//!   2. 帧层：EAPOL-Key 描述符的编/解码、MIC 计算与校验（HMAC-SHA1 截断
//!      16 字节，KCK 前 16 字节为密钥）、重放计数比较；
//!   3. 握手：STA 侧的 4-way 顺序机（msg1 → msg2 → msg3 → msg4），把
//!      「顺序错 / 重放旧 / MIC 坏 / key_info 不对」分成四个可断言的错误。
//!
//! 每一条判据的期望值来自 `tools/vectors.py`（CPython 的 hashlib/hmac，
//! 与本文件的 Zig 实现是两份独立实现），公开标准向量（RFC 6070、802.11i
//! 的 password/IEEE PSK）在 `src/host_tests.zig` 里另有一份出处。
//!
//! 本文件不 import hw/log，因此主机侧 `zig build test` 与板侧自检共用同一份代码。

const std = @import("std");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const timing_safe = std.crypto.timing_safe;

// ---------------------------------------------------------------------------
// 长度常数（与 802.11i 8.5.1 / hostap 的 wpa_common.h 一致）
// ---------------------------------------------------------------------------

pub const pmk_len = 32;
pub const nonce_len = 32;
pub const kck_len = 16;
pub const kek_len = 16;
pub const tk_len = 16;
/// CCMP 的 PTK = KCK(16) + KEK(16) + TK(16)。
pub const ptk_ccmp_len = kck_len + kek_len + tk_len;
/// 本章额外算一遍 512 位的 PTK：802.11r/GCMP 用到更长的 PTK，
/// 同一份 PRF 只是取更多块（64 字节 = 4 个 HMAC-SHA1 块）。
pub const ptk_512_len = 64;
pub const mic_len = 16;
pub const pbkdf2_rounds = 4096;
pub const passphrase_min = 8;
pub const passphrase_max = 63;
pub const ssid_max = 32;

/// `Pairwise key expansion` 是 802.11i 8.5.1.1 为 PTK 指定的标签。
/// 0x00 是标签与数据之间的分隔字节，标签本身不含结尾 0。
pub const ptk_label = "Pairwise key expansion";

pub const Wpa2Error = error{
    /// passphrase 长度不在 [8, 63]（64 位十六进制 PSK 走另一条路径，本章不做）。
    PassphraseLength,
    SsidLength,
    /// PBKDF2 的参数被 std 拒绝（轮数为 0 或输出过长），正常输入不会到这。
    Kdf,
    /// 帧短于固定部分（4 + 95 字节）或 key_data_len 与剩余长度不符。
    BadFrame,
    /// 不认识的 descriptor type（本章只做 RSN = 2）。
    BadDescriptor,
};

pub fn passphraseValid(passphrase: []const u8) bool {
    return passphrase.len >= passphrase_min and passphrase.len <= passphrase_max;
}

// ---------------------------------------------------------------------------
// 1) PMK：PBKDF2-HMAC-SHA1(passphrase, SSID, 4096, 32)
// ---------------------------------------------------------------------------

/// 802.11i Annex H.4：PSK = PBKDF2(HMAC-SHA1, passphrase, SSID, 4096, 256 bit)。
///
/// 注意 SSID 就是 salt，**没有**别的字段参与；这也解释了为什么同一个密码
/// 换个 SSID 就是另一把 PMK（常见误解之一）。
pub fn derivePmk(passphrase: []const u8, ssid: []const u8) Wpa2Error![pmk_len]u8 {
    if (!passphraseValid(passphrase)) return error.PassphraseLength;
    if (ssid.len == 0 or ssid.len > ssid_max) return error.SsidLength;
    var pmk: [pmk_len]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&pmk, passphrase, ssid, pbkdf2_rounds, HmacSha1) catch
        return error.Kdf;
    return pmk;
}

// ---------------------------------------------------------------------------
// 2) PRF：802.11i 8.5.1.1 / IEEE 802.11-2020 12.7.1.2
//
//    PRF(K, A, B, len) = HMAC-SHA1(K, A || 0x00 || B || i)，i 从 0 递增，
//    逐块拼接后截断到 len。A 是标签，B 是绑定数据。
// ---------------------------------------------------------------------------

pub fn prf(comptime out_len: usize, key: []const u8, label: []const u8, data: []const u8) [out_len]u8 {
    var out: [out_len]u8 = undefined;
    var filled: usize = 0;
    var counter: u8 = 0;
    while (filled < out_len) : (counter +%= 1) {
        var ctx = HmacSha1.init(key);
        ctx.update(label);
        ctx.update(&[_]u8{0});
        ctx.update(data);
        ctx.update(&[_]u8{counter});
        var mac: [HmacSha1.mac_length]u8 = undefined;
        ctx.final(&mac);
        const take = @min(mac.len, out_len - filled);
        @memcpy(out[filled..][0..take], mac[0..take]);
        filled += take;
    }
    return out;
}

/// `Min(a,b) || Max(a,b)`，按字节序比较（不是按 MAC 的数值大小）。
fn appendPair(comptime len: usize, out: []u8, a: [len]u8, b: [len]u8) void {
    const lo, const hi = if (std.mem.order(u8, &a, &b) == .gt) .{ b, a } else .{ a, b };
    @memcpy(out[0..len], &lo);
    @memcpy(out[len..][0..len], &hi);
}

/// PTK = PRF-X(PMK, "Pairwise key expansion",
///            Min(AA,SPA) || Max(AA,SPA) || Min(ANonce,SNonce) || Max(ANonce,SNonce))
///
/// 两个 nonce 与两个 MAC 都必须按「小在前」重排：谁发起握手不重要，
/// 两端算出的 PTK 必须一致，而 AP 侧与 STA 侧的入参顺序天然相反。
pub fn derivePtk(
    comptime out_len: usize,
    pmk: [pmk_len]u8,
    ap: [6]u8,
    sta: [6]u8,
    anonce: [nonce_len]u8,
    snonce: [nonce_len]u8,
) [out_len]u8 {
    var data: [2 * 6 + 2 * nonce_len]u8 = undefined; // 76 字节
    appendPair(6, data[0..12], ap, sta);
    appendPair(nonce_len, data[12..], anonce, snonce);
    return prf(out_len, &pmk, ptk_label, &data);
}

/// PTK 的三段怎么切（802.11i 8.5.1.1 + 8.5.2）：KCK 在前，KEK 其次，TK 最后。
pub const PtkSlices = struct {
    kck: [kck_len]u8,
    kek: [kek_len]u8,
    tk: [tk_len]u8,
};

pub fn splitPtk(ptk: [ptk_ccmp_len]u8) PtkSlices {
    return .{
        .kck = ptk[0..kck_len].*,
        .kek = ptk[kck_len..][0..kek_len].*,
        .tk = ptk[kck_len + kek_len ..][0..tk_len].*,
    };
}

// ---------------------------------------------------------------------------
// 3) EAPOL-Key 帧（802.1X-2010 §11.9 的 Key descriptor）
//
//    偏移  长度  字段
//      0     4   EAPOL 头：version(1) type(1)=3 body_len(2)
//      4     1   descriptor type（2 = RSN）
//      5     2   key info
//      7     2   key length
//      9     8   replay counter（大端）
//     17    32   nonce
//     49    16   IV
//     65     8   RSC
//     73     8   key ID
//     81    16   MIC          <-- 计算 MIC 时这 16 字节先清零
//     97     2   key data length
//     99     N   key data
// ---------------------------------------------------------------------------

pub const eapol_header_len = 4;
pub const key_body_fixed_len = 95;
pub const mic_offset = 81;
pub const key_data_len_offset = 97;

pub const KeyInfo = struct {
    pub const pairwise: u16 = 0x0008;
    pub const install: u16 = 0x0040;
    pub const ack: u16 = 0x0080;
    pub const mic: u16 = 0x0100;
    pub const secure: u16 = 0x0200;
    pub const request: u16 = 0x0800;
    pub const encr_key_data: u16 = 0x1000;
    pub const version_mask: u16 = 0x0007;
};

pub const KeyFrame = struct {
    version: u8 = 2,
    descriptor: u8 = 2, // RSN
    key_info: u16,
    key_len: u16 = 0,
    replay: u64,
    nonce: [nonce_len]u8 = @splat(0),
    mic: [mic_len]u8 = @splat(0),

    /// msg1 的特征：AP 发起、要求 ACK、不带 MIC。
    pub fn isMsg1(self: KeyFrame) bool {
        return (self.key_info & KeyInfo.ack) != 0 and (self.key_info & KeyInfo.mic) == 0;
    }

    /// msg3 的特征：ACK + MIC + Install + Secure。
    pub fn isMsg3(self: KeyFrame) bool {
        const need = KeyInfo.ack | KeyInfo.mic | KeyInfo.install | KeyInfo.secure;
        return (self.key_info & need) == need;
    }
};

fn writeU16Be(out: []u8, v: u16) void {
    out[0] = @truncate(v >> 8);
    out[1] = @truncate(v);
}

fn readU16Be(in: []const u8) u16 {
    return (@as(u16, in[0]) << 8) | in[1];
}

fn writeU64Be(out: []u8, v: u64) void {
    var shift: u6 = 56;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[i] = @truncate(v >> shift);
        shift -%= 8;
    }
}

fn readU64Be(in: []const u8) u64 {
    var v: u64 = 0;
    for (in[0..8]) |b| v = (v << 8) | b;
    return v;
}

/// 写出一整帧（含 EAPOL 头与 key data）。`out` 至少
/// `eapol_header_len + key_body_fixed_len + key_data.len` 字节。
/// MIC 字段按 `frame.mic` 原样写；要算 MIC 就传全 0 再回填。
pub fn encode(frame: KeyFrame, key_data: []const u8, out: []u8) Wpa2Error!usize {
    const total = eapol_header_len + key_body_fixed_len + key_data.len;
    if (out.len < total) return error.BadFrame;
    if (key_data.len > std.math.maxInt(u16)) return error.BadFrame;

    out[0] = frame.version;
    out[1] = 3; // EAPOL-Key
    writeU16Be(out[2..4], @intCast(total - eapol_header_len));

    const body = out[eapol_header_len..total];
    body[0] = frame.descriptor;
    writeU16Be(body[1..3], frame.key_info);
    writeU16Be(body[3..5], frame.key_len);
    writeU64Be(body[5..13], frame.replay);
    @memcpy(body[13..][0..nonce_len], &frame.nonce);
    @memset(body[45..61], 0); // IV
    @memset(body[61..69], 0); // RSC
    @memset(body[69..77], 0); // key ID
    @memcpy(body[77..][0..mic_len], &frame.mic);
    writeU16Be(body[93..95], @intCast(key_data.len));
    @memcpy(body[95..], key_data);

    std.debug.assert(total == eapol_header_len + key_body_fixed_len + key_data.len);
    std.debug.assert(mic_offset == eapol_header_len + 77);
    std.debug.assert(key_data_len_offset == eapol_header_len + 93);
    return total;
}

/// 只解固定部分；key data 由调用方按返回的长度自行处理（本章只校验长度）。
pub fn decode(buf: []const u8) Wpa2Error!struct { frame: KeyFrame, key_data_len: u16 } {
    if (buf.len < eapol_header_len + key_body_fixed_len) return error.BadFrame;
    if (buf[1] != 3) return error.BadFrame;
    const body_len = readU16Be(buf[2..4]);
    if (body_len < key_body_fixed_len) return error.BadFrame;
    if (buf.len < eapol_header_len + @as(usize, body_len)) return error.BadFrame;

    const body = buf[eapol_header_len..];
    if (body[0] != 2) return error.BadDescriptor;
    const kd_len = readU16Be(body[93..95]);
    if (key_body_fixed_len + @as(usize, kd_len) != body_len) return error.BadFrame;

    var frame = KeyFrame{
        .key_info = readU16Be(body[1..3]),
        .key_len = readU16Be(body[3..5]),
        .replay = readU64Be(body[5..13]),
    };
    @memcpy(&frame.nonce, body[13..][0..nonce_len]);
    @memcpy(&frame.mic, body[77..][0..mic_len]);
    return .{ .frame = frame, .key_data_len = kd_len };
}

// ---------------------------------------------------------------------------
// 4) MIC：HMAC-SHA1(KCK, EAPOL 帧，MIC 字段清 0)[0..16]
// ---------------------------------------------------------------------------

/// 计算 MIC。`frame` 是**完整帧**且 MIC 字段已经清零（`encode` 传全 0 即可）。
/// 不修改入参：主机侧测试拿同一块缓冲反复算，改入参会掩盖顺序依赖。
pub fn computeMic(kck: [kck_len]u8, frame: []const u8) Wpa2Error![mic_len]u8 {
    if (frame.len < mic_offset + mic_len) return error.BadFrame;
    var ctx = HmacSha1.init(&kck);
    ctx.update(frame[0..mic_offset]);
    const zeros: [mic_len]u8 = @splat(0);
    ctx.update(&zeros);
    ctx.update(frame[mic_offset + mic_len ..]);
    var full: [HmacSha1.mac_length]u8 = undefined;
    ctx.final(&full);
    return full[0..mic_len].*;
}

/// 校验 MIC：常量时间比较。`frame` 里带的是收到的 MIC（不清零）。
pub fn verifyMic(kck: [kck_len]u8, frame: []const u8) Wpa2Error!bool {
    if (frame.len < mic_offset + mic_len) return error.BadFrame;
    const got = frame[mic_offset..][0..mic_len].*;
    const expect = try computeMic(kck, frame);
    return timing_safe.eql([mic_len]u8, got, expect);
}

// ---------------------------------------------------------------------------
// 5) 重放计数：只接受严格递增
// ---------------------------------------------------------------------------

/// 802.11i 的 replay counter 随每一条新的 EAPOL-Key 帧递增；重传帧带同一个
/// 计数，但重传帧必须逐字节相同（MIC 也相同），否则就是重放攻击。
/// 本章采用最保守的规则：**严格大于**才接受。重复计数会被判 stale，
/// 这条规则让「同一帧重放」和「乱序」都变成同一个可断言的错误。
pub fn replayAccept(last: u64, incoming: u64) bool {
    return incoming > last;
}

// ---------------------------------------------------------------------------
// 6) STA 侧的 4-way 顺序机
// ---------------------------------------------------------------------------

pub const HsState = enum { idle, msg1_seen, msg2_sent, msg3_seen, done };

pub const HsError = error{
    /// 顺序错：例如 msg3 在 msg2 之前到达、msg2 在 msg1 之前发出。
    BadOrder,
    /// 重放计数没有严格递增（旧帧、重复帧、回绕）。
    BadReplay,
    /// key_info 的位与消息号不匹配（缺 ACK / 缺 MIC / 多了 Install）。
    BadKeyInfo,
    /// MIC 校验失败（密码不一致，或者帧被改过）。
    BadMic,
};

pub const FourWay = struct {
    state: HsState = .idle,
    /// 已接受的最大重放计数（STA 侧只跟踪 AP 发来的 msg1/msg3）。
    last_replay: u64 = 0,
    /// 从 msg1 里抄下来的 ANonce，用于派生 PTK。
    anonce: [nonce_len]u8 = @splat(0),
    /// 自己生成的 SNonce（本章由自检填固定值，真实实现用 TRNG）。
    snonce: [nonce_len]u8 = @splat(0),
    /// 握手过程中累积的错误计数，便于日志一行打印。
    rejects: u32 = 0,

    pub fn reset(self: *FourWay) void {
        self.* = .{};
    }

    fn reject(self: *FourWay, err: HsError) HsError {
        self.rejects += 1;
        return err;
    }

    /// 收到 msg1（AP → STA）：ACK=1、MIC=0、重放计数必须前进。
    pub fn recvMsg1(self: *FourWay, frame: KeyFrame) HsError!void {
        if (!frame.isMsg1()) return self.reject(error.BadKeyInfo);
        if (!replayAccept(self.last_replay, frame.replay))
            return self.reject(error.BadReplay);
        if (self.state != .idle and self.state != .msg1_seen)
            return self.reject(error.BadOrder);
        self.anonce = frame.nonce;
        self.last_replay = frame.replay;
        self.state = .msg1_seen;
    }

    /// 发出 msg2（STA → AP）：重放计数沿用 msg1 的值，必须带 MIC。
    pub fn sendMsg2(self: *FourWay, frame: KeyFrame) HsError!void {
        if (self.state != .msg1_seen) return self.reject(error.BadOrder);
        if ((frame.key_info & KeyInfo.mic) == 0) return self.reject(error.BadKeyInfo);
        if (frame.replay != self.last_replay) return self.reject(error.BadReplay);
        self.state = .msg2_sent;
    }

    /// 收到 msg3（AP → STA）：必须是 msg2 之后的新计数（last + 1），
    /// 且 ACK|MIC|Install|Secure 全置位。
    pub fn recvMsg3(self: *FourWay, frame: KeyFrame) HsError!void {
        if (self.state != .msg2_sent) return self.reject(error.BadOrder);
        if (!frame.isMsg3()) return self.reject(error.BadKeyInfo);
        if (!replayAccept(self.last_replay, frame.replay))
            return self.reject(error.BadReplay);
        if (frame.replay != self.last_replay + 1) return self.reject(error.BadReplay);
        self.last_replay = frame.replay;
        self.state = .msg3_seen;
    }

    /// 发出 msg4（STA → AP）：沿用 msg3 的计数，带 MIC，之后即 CONNECTED。
    pub fn sendMsg4(self: *FourWay, frame: KeyFrame) HsError!void {
        if (self.state != .msg3_seen) return self.reject(error.BadOrder);
        if ((frame.key_info & KeyInfo.mic) == 0) return self.reject(error.BadKeyInfo);
        if (frame.replay != self.last_replay) return self.reject(error.BadReplay);
        self.state = .done;
    }
};

// ---------------------------------------------------------------------------
// 7) 工具：把 [N]u8 打印成十六进制（自检与主机测试共用）
// ---------------------------------------------------------------------------

pub fn hexLower(comptime len: usize, bytes: [len]u8, out: *[2 * len]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return out[0 .. 2 * len];
}
