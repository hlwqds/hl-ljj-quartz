//! ch26-wifi-connection-wpa2-wpa3：主机侧单测（`zig build test`）。
//!
//! 被测的三个模块（`wpa2.zig` / `sae.zig` / `conn.zig`）都不 import 硬件
//! 相关代码，所以同一份实现可以在 x86_64 上跑完。这里的用例与板侧
//! `src/selftest.zig` 的十三条判据是**同一批向量、同一批断言**，只是
//! 主机上还能多测几件板侧嫌贵或嫌啰嗦的事：
//!
//!   * RFC 6070 的 c=4096 与 25 字节输出（板侧只跑 c=1/c=2，省时间）；
//!   * EAPOL 解码的四条坏帧路径（短帧、类型错、descriptor 错、长度不符）；
//!   * 队列回绕后的 pop 顺序（11 推 8 存 3 丢，逐条比对）；
//!   * 4-way 的全绿路径（板侧只测拒绝路径与顺序机入口）。
//!
//! 每个密码学断言都落在 `src/vectors.zig` 的常数上；那批常数的出处见该文件
//! 顶部注释与 `tools/vectors.py`。

const std = @import("std");
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

const conn = @import("conn.zig");
const sae = @import("sae.zig");
const vectors = @import("vectors.zig");
const wpa2 = @import("wpa2.zig");

// ---------------------------------------------------------------------------
// PBKDF2（RFC 6070 §2）
// ---------------------------------------------------------------------------

test "pbkdf2 rfc6070 c=1 and c=2" {
    var dk1: [20]u8 = undefined;
    var dk2: [20]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&dk1, "password", "salt", 1, HmacSha1);
    try std.crypto.pwhash.pbkdf2(&dk2, "password", "salt", 2, HmacSha1);
    try std.testing.expectEqualSlices(u8, &vectors.rfc6070_c1, &dk1);
    try std.testing.expectEqualSlices(u8, &vectors.rfc6070_c2, &dk2);
}

test "pbkdf2 rfc6070 c=4096 and 25-byte output" {
    var dk: [20]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&dk, "password", "salt", 4096, HmacSha1);
    try std.testing.expectEqualSlices(u8, &vectors.rfc6070_c4096, &dk);

    // dkLen=25 跨两个 SHA-1 块（20 + 5），验证分块拼接。
    var dk25: [25]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(
        &dk25,
        "passwordPASSWORDpassword",
        "saltSALTsaltSALTsaltSALTsaltSALTsalt",
        4096,
        HmacSha1,
    );
    try std.testing.expectEqualSlices(u8, &vectors.rfc6070_long, &dk25);
}

test "wpa2 pmk: passphrase/IEEE and length guards" {
    const pmk = try wpa2.derivePmk("password", "IEEE");
    try std.testing.expectEqualSlices(u8, &vectors.pmk_ieee, &pmk);

    // 8 与 63 是合法的两端；7 与 64 越界；SSID 空或 > 32 越界。
    const pw64: [64]u8 = @splat('x');
    const pw63: [63]u8 = @splat('y');
    const ssid33: [33]u8 = @splat('s');

    try std.testing.expectError(error.PassphraseLength, wpa2.derivePmk("1234567", "IEEE"));
    try std.testing.expectError(error.PassphraseLength, wpa2.derivePmk(&pw64, "IEEE"));
    try std.testing.expectError(error.SsidLength, wpa2.derivePmk("password", ""));
    try std.testing.expectError(error.SsidLength, wpa2.derivePmk("password", &ssid33));

    _ = try wpa2.derivePmk("12345678", "IEEE");
    _ = try wpa2.derivePmk(&pw63, "IEEE");
}

// ---------------------------------------------------------------------------
// PRF / PTK
// ---------------------------------------------------------------------------

test "prf is block-serial and prefix-stable" {
    const a: [20]u8 = wpa2.prf(20, "key material", "label", "data");
    const b: [64]u8 = wpa2.prf(64, "key material", "label", "data");
    try std.testing.expectEqualSlices(u8, &a, b[0..20]);

    // 不同标签必须给出不同输出（标签进 HMAC 输入，不是被忽略的参数）。
    const c: [20]u8 = wpa2.prf(20, "key material", "other label", "data");
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}

test "ptk: 384/512 vectors and endpoint-order invariance" {
    const pmk = vectors.pmk_ieee;
    const ptk64 = wpa2.derivePtk(64, pmk, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce);
    try std.testing.expectEqualSlices(u8, &vectors.ptk64, &ptk64);

    const ptk48 = wpa2.derivePtk(48, pmk, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce);
    try std.testing.expectEqualSlices(u8, &vectors.ptk48, &ptk48);
    try std.testing.expectEqualSlices(u8, ptk64[0..48], &ptk48);

    // AP/STA 与 ANonce/SNonce 全部对调，结果必须一致。
    const swapped = wpa2.derivePtk(64, pmk, vectors.sta_mac, vectors.ap_mac, vectors.snonce, vectors.anonce);
    try std.testing.expectEqualSlices(u8, &ptk64, &swapped);

    const slices = wpa2.splitPtk(ptk48);
    try std.testing.expectEqualSlices(u8, &vectors.kck16, &slices.kck);
    try std.testing.expectEqualSlices(u8, ptk48[16..32], &slices.kek);
    try std.testing.expectEqualSlices(u8, ptk48[32..48], &slices.tk);
}

// ---------------------------------------------------------------------------
// EAPOL-Key 帧
// ---------------------------------------------------------------------------

test "eapol encode matches the msg2 vector" {
    var frame = wpa2.KeyFrame{
        .key_info = 0x010a,
        .replay = 1,
        .nonce = vectors.snonce,
    };
    @memset(&frame.mic, 0);

    var buf: [160]u8 = undefined;
    const n = try wpa2.encode(frame, &vectors.rsn_ie, &buf);
    try std.testing.expectEqual(@as(usize, 121), n);
    try std.testing.expectEqual(@as(u16, 117), (@as(u16, buf[2]) << 8) | buf[3]);

    // 除 MIC 外必须与向量逐字节相同；MIC 由下面的用例单独算。
    var expected = vectors.eapol_msg2;
    @memset(expected[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    try std.testing.expectEqualSlices(u8, &expected, buf[0..n]);
}

test "eapol decode rejects malformed frames" {
    var good = vectors.eapol_msg2;
    const ok = try wpa2.decode(&good);
    try std.testing.expectEqual(@as(u64, 1), ok.frame.replay);
    try std.testing.expectEqual(@as(u16, 0x010a), ok.frame.key_info);
    try std.testing.expectEqual(@as(u16, 22), ok.key_data_len);
    try std.testing.expectEqualSlices(u8, &vectors.snonce, &ok.frame.nonce);

    // 1) 短于固定部分
    try std.testing.expectError(error.BadFrame, wpa2.decode(good[0..40]));
    // 2) EAPOL type 不是 3
    var bad_type = good;
    bad_type[1] = 0; // EAPOL-EAP
    try std.testing.expectError(error.BadFrame, wpa2.decode(&bad_type));
    // 3) descriptor type 不是 RSN
    var bad_desc = good;
    bad_desc[4] = 1; // WPA1
    try std.testing.expectError(error.BadDescriptor, wpa2.decode(&bad_desc));
    // 4) key data length 与 body length 不符
    var bad_len = good;
    bad_len[97] = 0;
    bad_len[98] = 0x10;
    try std.testing.expectError(error.BadFrame, wpa2.decode(&bad_len));
}

test "eapol mic: vector, tamper, wrong kck" {
    var frame = vectors.eapol_msg2;
    try std.testing.expect(try wpa2.verifyMic(vectors.kck16, &frame));

    var zeroed = frame;
    @memset(zeroed[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    const mic = try wpa2.computeMic(vectors.kck16, &zeroed);
    try std.testing.expectEqualSlices(u8, &vectors.eapol_msg2_mic, &mic);

    // computeMic 不清零入参：同一块缓冲再算一次必须得到同样的结果。
    const mic2 = try wpa2.computeMic(vectors.kck16, &zeroed);
    try std.testing.expectEqualSlices(u8, &mic, &mic2);

    var tampered = frame;
    tampered[119] ^= 0x40;
    try std.testing.expect(!(try wpa2.verifyMic(vectors.kck16, &tampered)));

    var wrong_kck = vectors.kck16;
    wrong_kck[15] ^= 0x01;
    try std.testing.expect(!(try wpa2.verifyMic(wrong_kck, &frame)));

    // MIC 字段本身被改动（而不是 key data）也必须失败。
    var bad_mic = frame;
    bad_mic[wpa2.mic_offset] ^= 0x80;
    try std.testing.expect(!(try wpa2.verifyMic(vectors.kck16, &bad_mic)));
}

test "replay counter is strictly monotonic" {
    try std.testing.expect(wpa2.replayAccept(0, 1));
    try std.testing.expect(wpa2.replayAccept(1, 2));
    try std.testing.expect(!wpa2.replayAccept(2, 2));
    try std.testing.expect(!wpa2.replayAccept(2, 1));
    try std.testing.expect(!wpa2.replayAccept(5, 0));
    // 回绕：u64 最大值之后没有更大的数。
    try std.testing.expect(!wpa2.replayAccept(std.math.maxInt(u64), 0));
}

// ---------------------------------------------------------------------------
// 4-way 顺序机
// ---------------------------------------------------------------------------

fn msg1Frame(replay: u64) wpa2.KeyFrame {
    var f = wpa2.KeyFrame{ .key_info = wpa2.KeyInfo.ack, .replay = replay };
    f.nonce = vectors.anonce;
    return f;
}

fn msg3Frame(replay: u64) wpa2.KeyFrame {
    return .{
        .key_info = wpa2.KeyInfo.ack | wpa2.KeyInfo.mic | wpa2.KeyInfo.install | wpa2.KeyInfo.secure,
        .replay = replay,
        .nonce = vectors.anonce,
    };
}

test "four-way happy path reaches done" {
    var hs = wpa2.FourWay{ .snonce = vectors.snonce };
    try hs.recvMsg1(msg1Frame(1));
    try std.testing.expectEqual(wpa2.HsState.msg1_seen, hs.state);
    try hs.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 });
    try hs.recvMsg3(msg3Frame(2));
    try hs.sendMsg4(.{ .key_info = wpa2.KeyInfo.mic, .replay = 2 });
    try std.testing.expectEqual(wpa2.HsState.done, hs.state);
    try std.testing.expectEqual(@as(u64, 2), hs.last_replay);
    try std.testing.expectEqual(@as(u32, 0), hs.rejects);
}

test "four-way rejects wrong order, stale replay and bad key info" {
    // msg2 before msg1
    var a = wpa2.FourWay{};
    try std.testing.expectError(error.BadOrder, a.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }));

    // msg4 before msg3
    var b = wpa2.FourWay{};
    try b.recvMsg1(msg1Frame(1));
    try b.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 });
    try std.testing.expectError(error.BadOrder, b.sendMsg4(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }));

    // msg1 twice (same replay)
    var c = wpa2.FourWay{};
    try c.recvMsg1(msg1Frame(7));
    try std.testing.expectError(error.BadReplay, c.recvMsg1(msg1Frame(7)));

    // msg1 without ACK
    var d = wpa2.FourWay{};
    try std.testing.expectError(error.BadKeyInfo, d.recvMsg1(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }));

    // msg3 skipping a counter
    var e = wpa2.FourWay{};
    try e.recvMsg1(msg1Frame(1));
    try e.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 });
    try std.testing.expectError(error.BadReplay, e.recvMsg3(msg3Frame(3)));

    // msg3 without Install
    var f = wpa2.FourWay{};
    try f.recvMsg1(msg1Frame(1));
    try f.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 });
    try std.testing.expectError(error.BadKeyInfo, f.recvMsg3(.{
        .key_info = wpa2.KeyInfo.ack | wpa2.KeyInfo.mic,
        .replay = 2,
    }));

    // rejects 计数把五次失败都记下来了（a..f 各自的实例互不影响）
    try std.testing.expectEqual(@as(u32, 1), a.rejects);
    try std.testing.expectEqual(@as(u32, 1), f.rejects);
}

// ---------------------------------------------------------------------------
// SAE
// ---------------------------------------------------------------------------

test "sae pwd-seed and pwd-value vectors" {
    const seed1 = sae.pwdSeed(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 1);
    try std.testing.expectEqualSlices(u8, &vectors.sae_pwd_seed_1, &seed1);

    // 参数与 MAC 顺序无关（内部按 MAX/MIN 重排）
    const reordered = sae.pwdSeed(vectors.ap_mac, vectors.sta_mac, vectors.sae_password, 1);
    try std.testing.expectEqualSlices(u8, &seed1, &reordered);

    // counter 进哈希：1 与 2 必须不同，且 2 命中向量
    const seed2 = sae.pwdSeed(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 2);
    try std.testing.expectEqualSlices(u8, &vectors.sae_pwd_seed_2, &seed2);
    try std.testing.expect(!std.mem.eql(u8, &seed1, &seed2));

    const value = sae.pwdValue(seed1);
    try std.testing.expectEqualSlices(u8, &vectors.sae_pwd_value_1, &value);
    try std.testing.expect(sae.pwdValueUsable(value));
    try std.testing.expectEqualSlices(u8, &value, &sae.pweX(seed1));
}

test "sae F_p reduction edge cases" {
    const all_ff: [32]u8 = @splat(0xff);
    try std.testing.expectEqualSlices(u8, &vectors.modp_all_ff_out, &sae.modP(all_ff));

    const zero: [32]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &zero, &sae.modP(vectors.modp_p));

    var one: [32]u8 = @splat(0);
    one[31] = 1;
    try std.testing.expectEqualSlices(u8, &one, &sae.modP(vectors.modp_p_plus_1));
    try std.testing.expectEqualSlices(u8, &vectors.modp_p_plus_x_out, &sae.modP(vectors.modp_p_plus_x));

    // 2^255 < p，原样返回
    try std.testing.expectEqualSlices(u8, &vectors.two_255, &sae.modP(vectors.two_255));

    // 归约结果必须严格小于 p：随机一批输入逐条验证
    var seed: u32 = 0x1234_5678;
    for (0..16) |_| {
        var x: [32]u8 = undefined;
        for (&x) |*b| {
            seed = conn.lcgNext(&seed);
            b.* = @truncate(seed >> 24);
        }
        try std.testing.expect(sae.cmp(sae.modP(x), sae.prime) == .lt);
    }
}

test "sae scalar add mod n and key derivation vectors" {
    const sum = sae.scalarAddModQ(vectors.sae_scalar_own, vectors.sae_scalar_peer);
    try std.testing.expectEqualSlices(u8, &vectors.sae_scalar_sum, &sum);

    // 交换律
    const sum2 = sae.scalarAddModQ(vectors.sae_scalar_peer, vectors.sae_scalar_own);
    try std.testing.expectEqualSlices(u8, &sum, &sum2);

    // 加 0 不变
    const zero: [32]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &vectors.sae_scalar_own, &sae.scalarAddModQ(vectors.sae_scalar_own, zero));

    // 溢出 256 位：0xff..ff + 1 = 2^256，carry 进第 257 位；结果 = 2^256 mod q。
    // 32 字节输入走不到这条路径（前缀余数恒 < 2^255，见 sae.reduceWide），
    // 只有 33 字节带进位的输入（a+b ≥ 2^256）才会触发——所以这条用例是
    // 唯一能打到「借位从 r[0] 吸收」分支的用例。
    try std.testing.expectEqualSlices(
        u8,
        &vectors.modq_overflow_out,
        &sae.scalarAddModQ(vectors.modq_all_ff, vectors.modq_one),
    );

    const keys = sae.deriveKeys(vectors.sae_k, vectors.sae_scalar_own, vectors.sae_scalar_peer);
    try std.testing.expectEqualSlices(u8, &vectors.sae_keyseed, &keys.keyseed);
    try std.testing.expectEqualSlices(u8, &vectors.sae_kck, &keys.kck);
    try std.testing.expectEqualSlices(u8, &vectors.sae_pmk, &keys.pmk);
    try std.testing.expectEqualSlices(u8, &vectors.sae_pmkid, &keys.pmkid);
    try std.testing.expectEqualSlices(u8, &vectors.sae_scalar_sum, &keys.scalar_sum);
}

test "sae confirm tokens and tamper rejection" {
    const keys = sae.deriveKeys(vectors.sae_k, vectors.sae_scalar_own, vectors.sae_scalar_peer);

    const own = sae.deriveConfirm(
        keys.kck,
        1,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
    );
    try std.testing.expectEqualSlices(u8, &vectors.sae_confirm_own, &own);

    const peer = sae.deriveConfirm(
        keys.kck,
        2,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
    );
    try std.testing.expectEqualSlices(u8, &vectors.sae_confirm_peer, &peer);

    try std.testing.expect(sae.verifyConfirm(peer, peer));
    var tampered = peer;
    tampered[31] ^= 0x01;
    try std.testing.expect(!sae.verifyConfirm(peer, tampered));
    // send-confirm 的值进哈希：换成 3 必须得到不同的 token
    const other = sae.deriveConfirm(
        keys.kck,
        3,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
    );
    try std.testing.expect(!std.mem.eql(u8, &peer, &other));
}

// ---------------------------------------------------------------------------
// 扫描候选
// ---------------------------------------------------------------------------

test "scan candidates: dedupe, filter open, sort by rssi" {
    const aps = [_]conn.Ap{
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -70, .channel = 6 },
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -52, .channel = 6 },
        .{ .bssid = .{ 2, 2, 2, 2, 2, 2 }, .rssi = -40, .channel = 36, .security = .wpa3_sae },
        .{ .bssid = .{ 3, 3, 3, 3, 3, 3 }, .rssi = -30, .channel = 1, .security = .open },
        .{ .bssid = .{ 4, 4, 4, 4, 4, 4 }, .rssi = -88, .channel = 11 },
    };
    var out: [conn.scan_max]conn.Ap = undefined;
    const n = try conn.selectCandidates(&aps, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(i8, -40), out[0].rssi);
    try std.testing.expectEqual(@as(i8, -52), out[1].rssi); // 合并后的最强值
    try std.testing.expectEqual(@as(i8, -88), out[2].rssi);
    try std.testing.expectEqual(conn.Security.wpa3_sae, out[0].security);

    // 输出缓冲不足时必须报错，而不是越界
    var tiny: [1]conn.Ap = undefined;
    try std.testing.expectError(error.BufferTooSmall, conn.selectCandidates(&aps, &tiny));

    // 同 rssi 时按 channel 升序
    const tie = [_]conn.Ap{
        .{ .bssid = .{ 9, 0, 0, 0, 0, 1 }, .rssi = -50, .channel = 11 },
        .{ .bssid = .{ 9, 0, 0, 0, 0, 2 }, .rssi = -50, .channel = 1 },
    };
    var out2: [conn.scan_max]conn.Ap = undefined;
    const n2 = try conn.selectCandidates(&tie, &out2);
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqual(@as(u8, 1), out2[0].channel);
    try std.testing.expectEqual(@as(u8, 11), out2[1].channel);
}

// ---------------------------------------------------------------------------
// 连接状态机
// ---------------------------------------------------------------------------

test "machine: idle to connected, wrong-order transitions refused" {
    var m = conn.Machine{};
    try std.testing.expectEqual(conn.State.idle, m.state);

    // 顺序错：未扫描就 auth/assoc/fourway 都不迁移
    try std.testing.expect(!m.onAuthOk());
    try std.testing.expect(!m.onAssocOk(0));
    try std.testing.expect(!m.onFourWayOk());
    try std.testing.expectEqual(conn.State.idle, m.state);

    try std.testing.expect(m.start());
    try std.testing.expect(!m.start()); // 重复 start 不迁移
    try std.testing.expectEqual(conn.State.scan, m.state);

    // scan 阶段再收 scan_done 也要先看状态：一次迁移后 state=auth
    try std.testing.expect(m.onScanDone(2));
    try std.testing.expectEqual(conn.State.auth, m.state);
    try std.testing.expect(m.onAuthOk());
    try std.testing.expectEqual(conn.State.assoc, m.state);
    try std.testing.expect(m.onAssocOk(0));
    try std.testing.expectEqual(conn.State.fourway, m.state);
    m.retries = 4;
    try std.testing.expect(m.onFourWayOk());
    try std.testing.expectEqual(conn.State.connected, m.state);
    try std.testing.expectEqual(@as(u8, 0), m.retries); // 成功后清零
}

test "machine: backoff sequence, jitter bounds and tick" {
    var seed: u32 = 0x2026_1113;
    try std.testing.expectEqual(@as(u32, 1000), conn.backoffMs(1));
    try std.testing.expectEqual(@as(u32, 2000), conn.backoffMs(2));
    try std.testing.expectEqual(@as(u32, 4000), conn.backoffMs(3));
    try std.testing.expectEqual(@as(u32, 8000), conn.backoffMs(4));
    try std.testing.expectEqual(@as(u32, 8000), conn.backoffMs(5));
    try std.testing.expectEqual(@as(u32, 8000), conn.backoffMs(200));
    try std.testing.expectEqual(@as(u32, 0), conn.backoffMs(0));

    for (1..6) |retry| {
        const base = conn.backoffMs(@intCast(retry));
        const v = conn.backoffWithJitter(@intCast(retry), &seed);
        try std.testing.expect(v >= base and v <= base + conn.jitter_span_ms);
    }

    // 同一 seed 的抖动序列可复现
    var s1: u32 = 42;
    var s2: u32 = 42;
    try std.testing.expectEqual(conn.backoffWithJitter(2, &s1), conn.backoffWithJitter(2, &s2));

    // 断线 → reconnect，到点前 tick 不动，到点后回 scan
    var m = conn.Machine{ .state = .connected };
    const t0: u64 = 5000;
    const due = m.onLinkLost(t0);
    try std.testing.expectEqual(conn.State.reconnect, m.state);
    try std.testing.expect(due > t0 and due <= t0 + 1125);
    try std.testing.expect(!m.tick(due - 1));
    try std.testing.expectEqual(conn.State.reconnect, m.state);
    try std.testing.expect(m.tick(due + 10));
    try std.testing.expectEqual(conn.State.scan, m.state);
}

test "machine: gives up after max_retries" {
    var m = conn.Machine{ .state = .connected };
    var now: u64 = 0;
    for (0..conn.max_retries) |_| {
        now = m.onLinkLost(now);
        try std.testing.expectEqual(conn.State.reconnect, m.state);
    }
    try std.testing.expectEqual(@as(u8, conn.max_retries), m.retries);
    _ = m.onLinkLost(now);
    try std.testing.expectEqual(conn.State.failed, m.state);
    try std.testing.expectEqual(@as(u8, conn.max_retries + 1), m.retries);

    // 最后一次投递的事件是 gave_up
    var last: ?conn.Event = null;
    while (m.pop()) |ev| last = ev;
    try std.testing.expect(last != null);
    try std.testing.expectEqual(conn.EventKind.gave_up, last.?.kind);
}

test "queue drops the oldest when full and keeps order" {
    var q = conn.EventQueue{};
    for (0..11) |i| {
        _ = q.push(.{ .kind = .scan_done, .arg = @intCast(i) });
    }
    try std.testing.expectEqual(@as(u32, 8), q.len);
    try std.testing.expectEqual(@as(u32, 11), q.pushed);
    try std.testing.expectEqual(@as(u32, 3), q.dropped);
    try std.testing.expectEqual(@as(u32, 3), q.at(0).?.arg);
    try std.testing.expectEqual(@as(u32, 10), q.at(7).?.arg);

    // pop 顺序：3,4,...,10，然后空
    for (3..11) |expected| {
        const ev = q.pop().?;
        try std.testing.expectEqual(@as(u32, @intCast(expected)), ev.arg);
    }
    try std.testing.expectEqual(@as(u32, 0), q.len);
    try std.testing.expect(q.pop() == null);

    // 回绕之后仍然按 FIFO
    _ = q.push(.{ .kind = .auth_ok, .arg = 100 });
    _ = q.push(.{ .kind = .assoc_ok, .arg = 101 });
    try std.testing.expectEqual(@as(u32, 100), q.pop().?.arg);
    try std.testing.expectEqual(@as(u32, 101), q.pop().?.arg);
}
