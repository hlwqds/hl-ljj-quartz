//! ch26-wifi-connection-wpa2-wpa3：板侧自检（13 条判据）。
//!
//! 每条判据打印一行 `check: ... ok=1/0`，最后一行 `checks: passed=N failed=0
//! total=N`。判据本身与主机侧 `zig build test` 共用同一批模块
//! （`wpa2.zig` / `sae.zig` / `conn.zig`），差别只在宿主 CPU 与运行环境：
//! 板侧没有堆、栈只有 16 KiB、日志走 ROM 的 `esp_rom_printf`。
//!
//! 十三条判据（与 `build.zig`、`src/main.zig`、`linker/s31.ld`、README、章节
//! 26.9–26.10 的条数一致）：
//!
//!   ① PBKDF2 测试向量：RFC 6070 c=1/c=2 逐字节，passphrase 长度拒绝
//!   ② PTK 派生：PRF-512 向量、前 48 字节等于 PTK-384、两端入参顺序无关
//!   ③ EAPOL MIC：整帧 121 字节的向量命中，改一字节后拒绝
//!   ④ 重放计数：相等与回退都被拒（旧帧不能重放）
//!   ⑤ 4-way 顺序：msg2 早于 msg1、msg4 早于 msg3、msg3 跳号，三种错误分开
//!   ⑥ SAE 确定性：pwd-seed / pwd-value 同输入同输出，F_p 归约边界正确
//!   ⑦ 扫描候选：5 条输入 → 3 条（去重 + 滤 open），按 RSSI 降序
//!   ⑧ AUTH→ASSOC：正确顺序通过，错误顺序不迁移
//!   ⑨ 4WAY→CONNECTED：握手完成即 connected，且失败计数清零
//!   ⑩ 重连退避：1000/2000/4000/8000/8000（上限），抖动在 [base, base+125]
//!   ⑪ 重试上限：第 6 次断线 → failed，并投递 gave_up
//!   ⑫ 事件队列：容量 8，投 11 条丢 3 条，队首是第 4 条
//!   ⑬ SAE 派生：keyseed/KCK/PMK/PMKID/confirm 向量命中，篡改 confirm 被拒
//!
//! 另有几行 `read:` 读数（结构长度、状态机计数），不是判据。

const std = @import("std");

const conn = @import("conn.zig");
const log = @import("log.zig");
const sae = @import("sae.zig");
const vectors = @import("vectors.zig");
const wpa2 = @import("wpa2.zig");

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [186]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn pfx(comptime n: usize, bytes: []const u8, out: []u8) []const u8 {
    var tmp: [n]u8 = undefined;
    @memcpy(&tmp, bytes[0..n]);
    const digits = "0123456789abcdef";
    for (tmp, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return out[0 .. 2 * n];
}

/// 判据里要的不是「失败了」，而是「失败的正好是这一个错误」，所以比较
/// 具体错误值。Zig 不允许直接拿错误联合与错误字面量比较，这里折叠成 bool。
fn isErr(v: anytype, comptime want: anyerror) bool {
    if (v) |_| return false else |e| return e == want;
}

// ---------------------------------------------------------------------------
// ① PBKDF2（RFC 6070 §2）
// ---------------------------------------------------------------------------

fn checkPbkdf2() void {
    var got1: [20]u8 = undefined;
    var got2: [20]u8 = undefined;
    // RFC 6070 用 P="password"、S="salt"，但 802.11i 的入口把 SSID 当 salt，
    // 所以这里直接调 std 的 pbkdf2，绕开 derivePmk 的长度检查。
    const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
    std.crypto.pwhash.pbkdf2(&got1, "password", "salt", 1, HmacSha1) catch unreachable;
    std.crypto.pwhash.pbkdf2(&got2, "password", "salt", 2, HmacSha1) catch unreachable;

    const c1_ok = std.mem.eql(u8, &got1, &vectors.rfc6070_c1);
    const c2_ok = std.mem.eql(u8, &got2, &vectors.rfc6070_c2);
    // 长度检查是第一个"错就要报错"的入口：7 字节与 64 字节都不合法。
    const pw64: [64]u8 = @splat('x');
    const short_err = isErr(wpa2.derivePmk("1234567", "IEEE"), error.PassphraseLength);
    const long_err = isErr(wpa2.derivePmk(&pw64, "IEEE"), error.PassphraseLength);

    var b0: [8]u8 = undefined;
    var b1: [8]u8 = undefined;
    const s0 = pfx(4, &got1, &b0);
    const s1 = pfx(4, &got2, &b1);
    check(c1_ok and c2_ok and short_err and long_err, "pbkdf2 rfc6070 c1={s} c2={s} c1_ok={d} c2_ok={d} bad_len={d}/{d}", .{
        s0,
        s1,
        @intFromBool(c1_ok),
        @intFromBool(c2_ok),
        @intFromBool(short_err),
        @intFromBool(long_err),
    });
}

// ---------------------------------------------------------------------------
// ② PTK（PRF-384 / PRF-512）
// ---------------------------------------------------------------------------

fn checkPtk() void {
    const pmk = vectors.pmk_ieee;
    const got64 = wpa2.derivePtk(64, pmk, vectors.ap_mac, vectors.sta_mac, vectors.anonce, vectors.snonce);

    // 同一组输入，把两端参数对调（AP/STA、ANonce/SNonce 全换位置）：
    // 内部 Min/Max 重排后必须得到同一个 PTK，否则两端永远对不上。
    const swapped = wpa2.derivePtk(64, pmk, vectors.sta_mac, vectors.ap_mac, vectors.snonce, vectors.anonce);

    const vec_ok = std.mem.eql(u8, &got64, &vectors.ptk64);
    const swap_ok = std.mem.eql(u8, &got64, &swapped);
    const prefix_ok = std.mem.eql(u8, got64[0..48], &vectors.ptk48);
    const slices = wpa2.splitPtk(vectors.ptk48);
    const kck_ok = std.mem.eql(u8, &slices.kck, &vectors.kck16);
    const pmk_ok = std.mem.eql(u8, &pmk, &vectors.pmk_ieee);

    var b0: [16]u8 = undefined;
    var b1: [16]u8 = undefined;
    check(vec_ok and swap_ok and prefix_ok and kck_ok and pmk_ok, "ptk prf512={s} prf384_prefix={d} swap_invariant={d} kck={s}", .{
        pfx(8, &got64, &b0),
        @intFromBool(prefix_ok),
        @intFromBool(swap_ok),
        pfx(8, &slices.kck, &b1),
    });
}

// ---------------------------------------------------------------------------
// ③ EAPOL MIC（正例 + 反例）
// ---------------------------------------------------------------------------

fn checkMic() void {
    const frame = vectors.eapol_msg2;
    const mic_ok = wpa2.verifyMic(vectors.kck16, &frame) catch false;

    // MIC 字段清零后重算，必须得到向量里的 16 字节。
    var zeroed = frame;
    @memset(zeroed[wpa2.mic_offset..][0..wpa2.mic_len], 0);
    const computed = wpa2.computeMic(vectors.kck16, &zeroed) catch unreachable;
    const compute_ok = std.mem.eql(u8, &computed, &vectors.eapol_msg2_mic);

    // 反例：改 key data 的最后一个字节（RSN IE 的 group cipher 位）。
    var tampered = frame;
    tampered[tampered.len - 1] ^= 0x01;
    const tamper_rejected = !(wpa2.verifyMic(vectors.kck16, &tampered) catch unreachable);

    // 反例 2：用另一把 KCK（等价于密码错了）。
    var wrong_kck = vectors.kck16;
    wrong_kck[0] ^= 0x80;
    const wrong_kck_rejected = !(wpa2.verifyMic(wrong_kck, &frame) catch unreachable);

    // 解码往返：帧里的 replay/nonce/key_info 必须原样取出。
    const dec = wpa2.decode(&frame) catch unreachable;
    const decode_ok = dec.frame.replay == 1 and
        dec.frame.key_info == 0x010a and
        dec.key_data_len == 22 and
        std.mem.eql(u8, &dec.frame.nonce, &vectors.snonce);

    var b0: [16]u8 = undefined;
    check(mic_ok and compute_ok and tamper_rejected and wrong_kck_rejected and decode_ok, "eapol mic len={d} mic={s} vec={d} verify={d} tamper={d} wrong_kck={d} decode={d}", .{
        frame.len,
        pfx(8, &computed, &b0),
        @intFromBool(compute_ok),
        @intFromBool(mic_ok),
        @intFromBool(tamper_rejected),
        @intFromBool(wrong_kck_rejected),
        @intFromBool(decode_ok),
    });
}

// ---------------------------------------------------------------------------
// ④ 重放计数
// ---------------------------------------------------------------------------

fn checkReplay() void {
    const asc = wpa2.replayAccept(1, 2);
    const same = wpa2.replayAccept(2, 2);
    const back = wpa2.replayAccept(2, 1);

    // 同一条 msg1 再来一遍：state 已前进到 msg2_sent 之后，
    // 但计数相同，必须先被 BadReplay 拦住（而不是被顺序拦）。
    var hs = wpa2.FourWay{ .snonce = vectors.snonce };
    var msg1 = wpa2.KeyFrame{ .key_info = wpa2.KeyInfo.ack, .replay = 1 };
    msg1.nonce = vectors.anonce;
    hs.recvMsg1(msg1) catch unreachable;
    const stale_err = isErr(hs.recvMsg1(msg1), error.BadReplay);
    const rejects = hs.rejects;

    check(asc and !same and !back and stale_err and rejects == 1, "replay accept(1,2)={d} same(2,2)={d} back(2,1)={d} msg1_twice=BadReplay:{d} rejects={d}", .{
        @intFromBool(asc),
        @intFromBool(same),
        @intFromBool(back),
        @intFromBool(stale_err),
        rejects,
    });
}

// ---------------------------------------------------------------------------
// ⑤ 4-way 顺序
// ---------------------------------------------------------------------------

fn checkFourWayOrder() void {
    // (a) msg2 在 msg1 之前
    var a = wpa2.FourWay{ .snonce = vectors.snonce };
    const early_msg2 = isErr(a.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }), error.BadOrder);

    // (b) msg4 在 msg3 之前
    var b = wpa2.FourWay{ .snonce = vectors.snonce };
    var msg1 = wpa2.KeyFrame{ .key_info = wpa2.KeyInfo.ack, .replay = 1 };
    msg1.nonce = vectors.anonce;
    b.recvMsg1(msg1) catch unreachable;
    b.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }) catch unreachable;
    const early_msg4 = isErr(b.sendMsg4(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }), error.BadOrder);

    // (c) msg3 的计数跳号（replay=3 而期望 2）
    var c = wpa2.FourWay{ .snonce = vectors.snonce };
    c.recvMsg1(msg1) catch unreachable;
    c.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }) catch unreachable;
    var msg3 = wpa2.KeyFrame{
        .key_info = wpa2.KeyInfo.ack | wpa2.KeyInfo.mic | wpa2.KeyInfo.install | wpa2.KeyInfo.secure,
        .replay = 3,
    };
    msg3.nonce = vectors.anonce;
    const skip = isErr(c.recvMsg3(msg3), error.BadReplay);

    // (d) msg3 的 key_info 少了 Install 位
    var d = wpa2.FourWay{ .snonce = vectors.snonce };
    d.recvMsg1(msg1) catch unreachable;
    d.sendMsg2(.{ .key_info = wpa2.KeyInfo.mic, .replay = 1 }) catch unreachable;
    var bad_info = msg3;
    bad_info.key_info = wpa2.KeyInfo.ack | wpa2.KeyInfo.mic | wpa2.KeyInfo.secure;
    bad_info.replay = 2;
    const info_err = isErr(d.recvMsg3(bad_info), error.BadKeyInfo);

    check(early_msg2 and early_msg4 and skip and info_err, "4way order msg2_early={d} msg4_early={d} msg3_skip={d} msg3_nokeyinfo={d}", .{
        @intFromBool(early_msg2),
        @intFromBool(early_msg4),
        @intFromBool(skip),
        @intFromBool(info_err),
    });
}

// ---------------------------------------------------------------------------
// ⑥ SAE 确定性 + 基域归约
// ---------------------------------------------------------------------------

fn checkSaeDeterminism() void {
    const seed_a = sae.pwdSeed(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 1);
    const seed_b = sae.pwdSeed(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 1);
    const seed_2 = sae.pwdSeed(vectors.sta_mac, vectors.ap_mac, vectors.sae_password, 2);
    const value = sae.pwdValue(seed_a);

    const seed_ok = std.mem.eql(u8, &seed_a, &vectors.sae_pwd_seed_1);
    const det_ok = std.mem.eql(u8, &seed_a, &seed_b);
    const ctr_ok = std.mem.eql(u8, &seed_2, &vectors.sae_pwd_seed_2);
    const value_ok = std.mem.eql(u8, &value, &vectors.sae_pwd_value_1);
    const usable_ok = sae.pwdValueUsable(value);

    // F_p 归约：2^256−1 必须落到 0x00000000fffffffe...，p 本身落到 0。
    const all_ff = modAllOnes();
    const red_ff = sae.modP(all_ff);
    const red_p = sae.modP(vectors.modp_p);
    const red_p1 = sae.modP(vectors.modp_p_plus_1);
    const red_px = sae.modP(vectors.modp_p_plus_x);
    const red_255 = sae.modP(vectors.two_255);

    const one: [32]u8 = comptime blk: {
        var v: [32]u8 = @splat(0);
        v[31] = 1;
        break :blk v;
    };
    const zero: [32]u8 = @splat(0);

    const red_ok = std.mem.eql(u8, &red_ff, &vectors.modp_all_ff_out) and
        std.mem.eql(u8, &red_p, &zero) and
        std.mem.eql(u8, &red_p1, &one) and
        std.mem.eql(u8, &red_px, &vectors.modp_p_plus_x_out) and
        std.mem.eql(u8, &red_255, &vectors.two_255);

    // 标量加法：own + peer mod n
    const sum = sae.scalarAddModQ(vectors.sae_scalar_own, vectors.sae_scalar_peer);
    const sum_ok = std.mem.eql(u8, &sum, &vectors.sae_scalar_sum);

    // 溢出 256 位：0xff..ff + 1 = 2^256。这是 remainder 唯一会触到 2^256、
    // 也就是唯一要从 r[0]（第 257 位）借位的路径：32 字节输入的前缀余数
    // 恒 < 2^255，移位后碰不到 r[0]，只有 33 字节带进位的输入才会。
    const overflow = sae.scalarAddModQ(vectors.modq_all_ff, vectors.modq_one);
    const overflow_ok = std.mem.eql(u8, &overflow, &vectors.modq_overflow_out);

    var b0: [16]u8 = undefined;
    var b1: [16]u8 = undefined;
    check(seed_ok and det_ok and ctr_ok and value_ok and usable_ok and red_ok and sum_ok and overflow_ok, "sae pwd-seed={s} pwd-value={s} det={d} ctr={d} modp={d} modq={d} ovf={d}", .{
        pfx(8, &seed_a, &b0),
        pfx(8, &value, &b1),
        @intFromBool(det_ok),
        @intFromBool(ctr_ok),
        @intFromBool(red_ok),
        @intFromBool(sum_ok),
        @intFromBool(overflow_ok),
    });
}

fn modAllOnes() [32]u8 {
    return @splat(0xff);
}

// ---------------------------------------------------------------------------
// ⑦ 扫描候选：去重 + 过滤 + 排序
// ---------------------------------------------------------------------------

fn checkScan() void {
    const aps = [_]conn.Ap{
        // bssid                    rssi  ch  security
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -70, .channel = 6, .security = .wpa2_psk },
        // 同一个 BSSID 的第二次出现（更强的信号），必须合并成一条
        .{ .bssid = .{ 1, 1, 1, 1, 1, 1 }, .rssi = -52, .channel = 6, .security = .wpa2_psk },
        .{ .bssid = .{ 2, 2, 2, 2, 2, 2 }, .rssi = -40, .channel = 36, .security = .wpa3_sae },
        .{ .bssid = .{ 3, 3, 3, 3, 3, 3 }, .rssi = -30, .channel = 1, .security = .open },
        .{ .bssid = .{ 4, 4, 4, 4, 4, 4 }, .rssi = -88, .channel = 11, .security = .wpa2_psk },
    };
    var out: [conn.scan_max]conn.Ap = undefined;
    const n = conn.selectCandidates(&aps, &out) catch 0;

    const count_ok = n == 3;
    const merged_ok = count_ok and out[1].bssid[0] == 1 and out[1].rssi == -52;
    const order_ok = count_ok and out[0].rssi == -40 and out[1].rssi == -52 and out[2].rssi == -88;
    const open_ok = count_ok and out[0].security == .wpa3_sae and out[2].security == .wpa2_psk;

    check(count_ok and merged_ok and order_ok and open_ok, "scan in={d} out={d} merged_rssi={d} order={d},{d},{d} open_dropped={d}", .{
        aps.len,
        n,
        if (count_ok) out[1].rssi else 0,
        if (count_ok) out[0].rssi else 0,
        if (count_ok) out[1].rssi else 0,
        if (count_ok) out[2].rssi else 0,
        @intFromBool(open_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑧ AUTH → ASSOC 迁移
// ---------------------------------------------------------------------------

fn checkAuthAssoc() void {
    var m = conn.Machine{};
    const started = m.start();
    const scan = m.onScanDone(3);
    const auth = m.onAuthOk();
    const state_ok = m.state == .assoc;
    // 顺序反了必须拒绝：现在已经在 assoc，再收一个 auth_ok 不该迁移。
    const again = m.onAuthOk();
    const idle_auth = blk: {
        var fresh = conn.Machine{};
        break :blk fresh.onAuthOk(); // idle 下直接 auth_ok
    };

    check(started and scan and auth and state_ok and !again and !idle_auth, "fsm auth->assoc start={d} scan={d} auth={d} state={s} reauth={d} idle_auth={d}", .{
        @intFromBool(started),
        @intFromBool(scan),
        @intFromBool(auth),
        m.state.name(),
        @intFromBool(again),
        @intFromBool(idle_auth),
    });
}

// ---------------------------------------------------------------------------
// ⑨ 4WAY → CONNECTED
// ---------------------------------------------------------------------------

fn checkFourWayToConnected() void {
    var m = conn.Machine{};
    _ = m.start();
    _ = m.onScanDone(1);
    _ = m.onAuthOk();
    const assoc = m.onAssocOk(0); // status 0 = success
    const state_fourway = m.state == .fourway;
    // 人为抬高失败计数，再走一次真正的 4-way 完成：成功后必须清零。
    m.retries = 3;
    const done = m.onFourWayOk();
    const connected = m.state == .connected;
    const reset_ok = m.retries == 0;
    // 已经 connected，再收一个 fourway_ok 不应迁移，也不该动计数。
    const done2 = m.onFourWayOk();
    const extra_ok = (!done2) and m.retries == 0;

    check(assoc and state_fourway and done and connected and reset_ok and extra_ok, "fsm fourway->connected assoc={d} fourway={d} done={d} state={s} reset={d} extra={d}", .{
        @intFromBool(assoc),
        @intFromBool(state_fourway),
        @intFromBool(done),
        m.state.name(),
        @intFromBool(reset_ok),
        @intFromBool(extra_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑩ 退避序列与抖动
// ---------------------------------------------------------------------------

fn checkBackoff() void {
    var seed: u32 = 0x2026_1113;
    const j1 = conn.backoffWithJitter(1, &seed);
    const j2 = conn.backoffWithJitter(2, &seed);
    const j3 = conn.backoffWithJitter(3, &seed);
    const j4 = conn.backoffWithJitter(4, &seed);
    const j5 = conn.backoffWithJitter(5, &seed);

    const base_ok = conn.backoffMs(1) == 1000 and conn.backoffMs(2) == 2000 and
        conn.backoffMs(3) == 4000 and conn.backoffMs(4) == 8000 and
        conn.backoffMs(5) == 8000 and conn.backoffMs(9) == 8000;
    const jitter_ok = inRange(j1, 1000) and inRange(j2, 2000) and
        inRange(j3, 4000) and inRange(j4, 8000) and inRange(j5, 8000);

    check(base_ok and jitter_ok, "backoff base=1000/2000/4000/8000/8000 jitter={d}/{d}/{d}/{d}/{d} span<=125 cap={d}", .{
        j1, j2, j3, j4, j5, conn.backoff_cap_ms,
    });
}

fn inRange(v: u32, base: u32) bool {
    return v >= base and v <= base + conn.jitter_span_ms;
}

// ---------------------------------------------------------------------------
// ⑪ 超过重试上限 → FAILED
// ---------------------------------------------------------------------------

fn checkGiveUp() void {
    var m = conn.Machine{};
    var now: u64 = 1000;
    var i: u8 = 0;
    while (i < conn.max_retries) : (i += 1) {
        now = m.onLinkLost(now);
    }
    const still_reconnect = m.state == .reconnect;
    const retries_at_cap = m.retries;
    const sixth = m.onLinkLost(now);
    const failed = m.state == .failed;
    // 最后一次等待必须是上限 8000（第 5 次的重试间隔）。
    const capped = (sixth == now) and (conn.backoffMs(retries_at_cap) == conn.backoff_cap_ms);

    check(still_reconnect and failed and capped and m.retries == conn.max_retries + 1, "retries max={d} at_cap_state={s} retries={d} 6th={s} capped={d}", .{
        conn.max_retries,
        if (still_reconnect) conn.State.reconnect.name() else m.state.name(),
        m.retries,
        m.state.name(),
        @intFromBool(capped),
    });
}

// ---------------------------------------------------------------------------
// ⑫ 事件队列满 → 丢最旧
// ---------------------------------------------------------------------------

fn checkQueueOverflow() void {
    var q = conn.EventQueue{};
    var i: u32 = 0;
    var last: conn.PushResult = .queued;
    while (i < 11) : (i += 1) {
        last = q.push(.{ .kind = .scan_done, .arg = i });
    }
    const len_ok = q.len == conn.queue_capacity;
    const dropped_ok = q.dropped == 3 and q.pushed == 11;
    const head_ok = if (q.at(0)) |ev| ev.arg == 3 else false;
    const tail_ok = if (q.at(conn.queue_capacity - 1)) |ev| ev.arg == 10 else false;
    const full_result = last == .dropped_oldest;

    check(len_ok and dropped_ok and head_ok and tail_ok and full_result, "queue cap={d} pushed={d} dropped={d} head_arg={d} tail_arg={d} push_full={s}", .{
        conn.queue_capacity,
        q.pushed,
        q.dropped,
        if (q.at(0)) |ev| ev.arg else 999,
        if (q.at(conn.queue_capacity - 1)) |ev| ev.arg else 999,
        @tagName(last),
    });
}

// ---------------------------------------------------------------------------
// ⑬ SAE 派生：keyseed / KCK / PMK / PMKID / confirm
// ---------------------------------------------------------------------------

fn checkSaeDerive() void {
    const keys = sae.deriveKeys(vectors.sae_k, vectors.sae_scalar_own, vectors.sae_scalar_peer);
    const keyseed_ok = std.mem.eql(u8, &keys.keyseed, &vectors.sae_keyseed);
    const kck_ok = std.mem.eql(u8, &keys.kck, &vectors.sae_kck);
    const pmk_ok = std.mem.eql(u8, &keys.pmk, &vectors.sae_pmk);
    const pmkid_ok = std.mem.eql(u8, &keys.pmkid, &vectors.sae_pmkid);

    const confirm_own = sae.deriveConfirm(
        keys.kck,
        1,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
    );
    const confirm_peer = sae.deriveConfirm(
        keys.kck,
        2,
        vectors.sae_scalar_peer,
        vectors.sae_element_peer,
        vectors.sae_scalar_own,
        vectors.sae_element_own,
    );
    const own_ok = std.mem.eql(u8, &confirm_own, &vectors.sae_confirm_own);
    const peer_ok = std.mem.eql(u8, &confirm_peer, &vectors.sae_confirm_peer);

    // 篡改一位：verify 必须拒绝（常量时间比较，但结果只有一个 bool）。
    var tampered = confirm_peer;
    tampered[0] ^= 0x01;
    const tamper_rejected = !sae.verifyConfirm(confirm_peer, tampered);
    const self_ok = sae.verifyConfirm(confirm_peer, confirm_peer);

    var b0: [16]u8 = undefined;
    var b1: [16]u8 = undefined;
    check(keyseed_ok and kck_ok and pmk_ok and pmkid_ok and own_ok and peer_ok and tamper_rejected and self_ok, "sae derive kck={s} pmkid={s} kdf={d}/{d}/{d}/{d} confirm={d}/{d} tamper_rej={d}", .{
        pfx(8, &keys.kck, &b0),
        pfx(8, &keys.pmkid, &b1),
        @intFromBool(keyseed_ok),
        @intFromBool(kck_ok),
        @intFromBool(pmk_ok),
        @intFromBool(pmkid_ok),
        @intFromBool(own_ok),
        @intFromBool(peer_ok),
        @intFromBool(tamper_rejected),
    });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

fn runChecks() bool {
    checkPbkdf2();
    checkPtk();
    checkMic();
    checkReplay();
    checkFourWayOrder();
    checkSaeDeterminism();
    checkScan();
    checkAuthAssoc();
    checkFourWayToConnected();
    checkBackoff();
    checkGiveUp();
    checkQueueOverflow();
    checkSaeDerive();
    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();

    // 非判据读数：结构长度、SAE 子集边界、状态机计数。
    log.line("read: sizes pmk={d} ptk={d} mic={d} eapol={d} sae_scalar={d} sae_elem={d}", .{
        wpa2.pmk_len,            wpa2.ptk_ccmp_len, wpa2.mic_len,
        wpa2.key_body_fixed_len, sae.scalar_len,    sae.element_len,
    });
    log.line("read: sae subset implemented={d} unimplemented={d} (EC ops, h2e, groups: see ch26 26.5)", .{
        sae.implemented.len, sae.unimplemented.len,
    });
    log.line("read: fsm states={d} events={d} backoff cap={d}ms max_retries={d}", .{
        @typeInfo(conn.State).@"enum".field_names.len,
        @typeInfo(conn.EventKind).@"enum".field_names.len,
        conn.backoff_cap_ms,
        conn.max_retries,
    });

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
