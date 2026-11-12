//! ch23-tls-http：板侧自检（13 条判据）。
//!
//! 本章没有可用的真实链路（ch17 的以太网驱动未闭环：DMA 软复位超时、
//! MDIO 扫不到 PHY），也没有事件循环与 socket（ch22 已交付，但只有注入路径、无真实链路）。
//! 因此板侧的**唯一**证据形态是：把与协议有关的确定性部分各走一遍，
//! 打印判读行。这里没有“连接”、没有“握手”、没有“GET 成功”——
//! 任何声称“板子访问了某个 URL”的读数都是伪造的。
//!
//! 十三条判据（每条一行 `check: ... ok=1/0`）：
//!
//!   ① 记录层分片/重组：3004 字节握手消息 → 3 条记录（1024/1024/956）
//!      → 跨记录重组回原样
//!   ② 记录长度上限：16640 收，16641 拒；原始头 0x4101 也拒
//!   ③ HKDF-Extract：RFC 5869 A.1 的 PRK 逐字节一致
//!   ④ HKDF-Expand-Label：HkdfLabel 编码 == 手工拼的字节；输出 ==
//!      `std` 的 HKDF-Expand（info 由本模块构造）；label 长度字节 = 6+len
//!   ⑤ X25519：RFC 7748 §6.1 两组向量 + 全零对端拒绝
//!   ⑥ AES-128-GCM：NIST SP 800-38D 两组向量 + tag 篡改 + AD 篡改
//!   ⑦ DER 证书解析：subject/issuer CN、SAN 三条、有效期两年
//!   ⑧ 验签：fixture 自洽验签通过；翻一个字节后必须失败
//!   ⑨ HTTP 请求解析：方法/路径/query/首部数/keep-alive
//!   ⑩ chunked 解码：`4 Wiki 5 pedia 0` → "Wikipedia"，坏长度行被拒
//!   ⑪ keep-alive 矩阵：1.1/1.1+close/1.0/1.0+keep-alive
//!   ⑫ 响应构造：状态行 + Content-Length 与 body 长度一致 + Connection
//!   ⑬ RFC 8448 §3：early/derived/handshake/c hs/s hs 五项逐字节一致
//!
//! 另有几行 `read:` 前缀的读数（密钥材料前缀、曲线公钥长度等），
//! 它们不是判据，只是让日志能被人肉眼对拍。
//!
//! 所有缓冲都是 `.bss` 里的静态对象：板侧没有分配器，自检也不该依赖
//! `error.OutOfMemory` 才能跑到 verdict。

const std = @import("std");

const record = @import("tls_record.zig");
const ks = @import("tls_keyschedule.zig");
const x = @import("x25519.zig");
const aead = @import("aead.zig");
const cert = @import("cert.zig");
const http = @import("http.zig");

const log = @import("log.zig");

// ---------------------------------------------------------------------------
// 静态工作区（.bss）
// ---------------------------------------------------------------------------
var g_msg: [3004]u8 = undefined; // 一条 4+3000 字节的握手消息
var g_wire: [3300]u8 = undefined; // 分片后的记录串
var g_reasm: [3200]u8 = undefined; // 跨记录重组缓冲
var g_cert: [cert.max_cert_len]u8 = undefined; // fixture 的可写副本
var g_http: [512]u8 = undefined; // 响应缓冲
var g_chunk: [64]u8 = undefined; // chunked 解码输出
var g_plain: [128]u8 = undefined; // GCM 解密输出

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [180]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

/// 把前 4 个字节打成 8 个十六进制字符（日志里对拍用）。
/// `err == error.X` 的统一写法：成功返回 false，失败时比对错误值。
fn failedWith(err: anytype, expected: anyerror) bool {
    if (err) |_| return false else |e| return e == expected;
}

fn hex4(buf: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    const n: usize = @min(bytes.len, 4);
    for (bytes[0..n], 0..) |b, i| {
        buf[i * 2] = digits[b >> 4];
        buf[i * 2 + 1] = digits[b & 0xF];
    }
    return buf[0 .. n * 2];
}

fn runChecks() bool {
    // ---- ① 记录层分片与重组 ----
    {
        record.writeHandshakeHeader(g_msg[0..4], 1, 3000) catch {};
        for (g_msg[4..], 0..) |*b, i| b.* = @intCast(i & 0xFF);

        var n: usize = 0;
        var lens: [4]usize = undefined;
        var records: usize = 0;
        var splitter = record.Splitter.init(&g_msg, 1024) catch unreachable;
        while (splitter.next()) |frag| {
            var hdr: [record.header_len]u8 = undefined;
            record.writeHeader(&hdr, .handshake, frag.len) catch {};
            @memcpy(g_wire[n..][0..record.header_len], &hdr);
            n += record.header_len;
            @memcpy(g_wire[n..][0..frag.len], frag);
            n += frag.len;
            if (records < lens.len) lens[records] = frag.len;
            records += 1;
        }
        const counted = record.countRecords(g_wire[0..n]) catch 0;

        var reader = record.MessageReader.init(&g_reasm);
        var complete = false;
        var same = false;
        var pos: usize = 0;
        while (pos < n) {
            const rec = record.splitOne(g_wire[pos..n]) catch break;
            pos += record.header_len + rec.fragment.len;
            if (reader.push(rec.header.content_type, rec.fragment) catch null) |msg| {
                complete = true;
                same = std.mem.eql(u8, msg, &g_msg) and msg.len == g_msg.len;
            }
        }
        check(
            records == 3 and counted == 3 and complete and same and
                lens[0] == 1024 and lens[1] == 1024 and lens[2] == 3004 - 2048,
            "record frag records={d} lens={d},{d},{d} reasm={d}",
            .{ records, lens[0], lens[1], lens[2], @intFromBool(same) },
        );
    }

    // ---- ② 记录长度上限 ----
    {
        var hdr: [record.header_len]u8 = undefined;
        const exact_err = record.writeHeader(&hdr, .application_data, record.max_record_length);
        const over_err = record.writeHeader(&hdr, .application_data, record.max_record_length + 1);
        // 手工造一个声称 16641 字节的记录头。
        const raw = [_]u8{ 23, 0x03, 0x03, 0x41, 0x01 };
        const raw_res = record.readHeader(&raw);
        var max_hdr: [record.header_len]u8 = undefined;
        record.writeHeader(&max_hdr, .application_data, record.max_record_length) catch {};
        const parsed = record.readHeader(&max_hdr);
        const ok = !failedWith(exact_err, error.RecordTooLarge) and failedWith(over_err, error.RecordTooLarge) and
            failedWith(raw_res, error.RecordTooLarge) and !failedWith(parsed, error.RecordTooLarge) and
            record.max_record_length == 16640;
        check(
            ok,
            "record limit max={d} exact=1 over=0 raw=0",
            .{record.max_record_length},
        );
    }

    // ---- ③ HKDF-Extract（RFC 5869 A.1）----
    {
        const prk = ks.extract(&ks.rfc5869_salt, &ks.rfc5869_ikm);
        var hbuf: [8]u8 = undefined;
        check(
            std.mem.eql(u8, &prk, &ks.rfc5869_prk),
            "hkdf-extract rfc5869 prk={s}",
            .{hex4(&hbuf, &prk)},
        );
    }

    // ---- ④ HKDF-Expand-Label（RFC 8446 §7.1）----
    {
        var info_buf: [ks.max_info]u8 = undefined;
        const info = ks.encodeInfo(&info_buf, 32, "key", &[_]u8{ 0x01, 0x02 }) catch &[_]u8{};

        // 手工拼 HkdfLabel：length=0x0020、label_len=0x09、tls13 key、ctx_len=2、01 02
        const manual = [_]u8{ 0x00, 0x20, 0x09, 't', 'l', 's', '1', '3', ' ', 'k', 'e', 'y', 0x02, 0x01, 0x02 };
        const info_ok = std.mem.eql(u8, info, &manual);

        const secret = ks.rfc5869_prk;
        var ours: [32]u8 = undefined;
        ks.expandLabel(&ours, secret, "key", &[_]u8{ 0x01, 0x02 }) catch {};
        var manual_out: [32]u8 = undefined;
        ks.expand(&manual_out, secret, &manual);
        const out_ok = std.mem.eql(u8, &ours, &manual_out);

        // 不同 label 必须给出不同输出。
        var other: [32]u8 = undefined;
        ks.expandLabel(&other, secret, "iv", &[_]u8{ 0x01, 0x02 }) catch {};
        const distinct = !std.mem.eql(u8, &ours, &other);

        var hbuf: [8]u8 = undefined;
        check(
            info_ok and out_ok and distinct and info.len == 15 and manual[2] == 9,
            "hkdf-expand-label label_len={d} info_len={d} out={s} manual={d}",
            .{ manual[2], info.len, hex4(&hbuf, &ours), @intFromBool(out_ok) },
        );
    }

    // ---- ⑤ X25519（RFC 7748 §6.1）----
    {
        const v1 = x.scalarmult(x.rfc7748_1.scalar, x.rfc7748_1.u) catch @as([32]u8, @splat(0));
        const v2 = x.scalarmult(x.rfc7748_2.scalar, x.rfc7748_2.u) catch @as([32]u8, @splat(0));
        const zeros: [32]u8 = @splat(0);
        const low = x.scalarmult(x.selftest_seed, zeros);

        var b1: [8]u8 = undefined;
        var b2: [8]u8 = undefined;
        check(
            std.mem.eql(u8, &v1, &x.rfc7748_1.out) and std.mem.eql(u8, &v2, &x.rfc7748_2.out) and
                failedWith(low, error.LowOrderPoint),
            "x25519 rfc7748 v1={s} v2={s} loworder=rejected",
            .{ hex4(&b1, &v1), hex4(&b2, &v2) },
        );
    }

    // ---- ⑥ AES-128-GCM（NIST SP 800-38D）----
    {
        const zero_key: [16]u8 = @splat(0);
        const zero_iv: [12]u8 = @splat(0);

        var tag: [aead.tag_length]u8 = undefined;
        var empty_ct: [0]u8 = undefined;
        aead.sealWithNonce(&empty_ct, &tag, "", "", zero_iv, zero_key) catch {};
        const empty_ok = std.mem.eql(u8, &tag, &aead.nist_empty_tag);

        const pt: [16]u8 = @splat(0);
        var ct: [16]u8 = undefined;
        var tag16: [aead.tag_length]u8 = undefined;
        aead.sealWithNonce(&ct, &tag16, &pt, "", zero_iv, zero_key) catch {};
        const vec_ok = std.mem.eql(u8, &ct, &aead.nist_16_ct) and std.mem.eql(u8, &tag16, &aead.nist_16_tag);

        var back: [16]u8 = undefined;
        aead.openWithNonce(&back, &ct, tag16, "", zero_iv, zero_key) catch {};
        const open_ok = std.mem.eql(u8, &back, &pt);

        var bad_tag = tag16;
        bad_tag[aead.tag_length - 1] ^= 1;
        const tag_rejected =
            failedWith(aead.openWithNonce(&back, &ct, bad_tag, "", zero_iv, zero_key), error.AuthenticationFailed);
        const ad_rejected =
            failedWith(aead.openWithNonce(&back, &ct, tag16, &[_]u8{0x17}, zero_iv, zero_key), error.AuthenticationFailed);

        var b1: [8]u8 = undefined;
        var b2: [8]u8 = undefined;
        check(
            empty_ok and vec_ok and open_ok and tag_rejected and ad_rejected,
            "aes-gcm nist tag={s} ct={s} tamper={d}/2",
            .{ hex4(&b1, &tag16), hex4(&b2, &ct), @as(u32, @intFromBool(tag_rejected)) + @as(u32, @intFromBool(ad_rejected)) },
        );
    }

    // ---- ⑦ DER 证书解析 ----
    {
        const c = cert.parse(cert.fixture_der) catch null;
        if (c) |cert_v| {
            const cn_ok = std.mem.eql(u8, cert_v.subject_cn, "ch23-stub.local");
            const issuer_ok = std.mem.eql(u8, cert_v.issuer_cn, "ch23-stub.local");
            const san_ok = cert_v.san_len == 3 and
                std.mem.eql(u8, cert_v.sanAt(0), "ch23.local") and
                std.mem.eql(u8, cert_v.sanAt(1), "www.ch23.local") and
                std.mem.eql(u8, cert_v.sanAt(2), &[_]u8{ 0x7F, 0x00, 0x00, 0x01 });
            const nb_ok = cert_v.not_before.year == 2026 and cert_v.not_before.month == 1 and cert_v.not_before.day == 1;
            const na_ok = cert_v.not_after.year == 2027;
            check(
                cn_ok and issuer_ok and san_ok and nb_ok and na_ok,
                "x509 der cn={s} issuer={s} san={d} first={s} nb={d}-{d:0>2}-{d:0>2}",
                .{ cert_v.subject_cn, cert_v.issuer_cn, cert_v.san_len, cert_v.sanAt(0), cert_v.not_before.year, cert_v.not_before.month, cert_v.not_before.day },
            );
        } else {
            check(false, "x509 der parse=failed", .{});
        }
    }

    // ---- ⑧ 验签（fixture 自洽 + 篡改拒绝）----
    {
        const good = cert.parse(cert.fixture_der) catch null;
        const verify_ok = if (good) |*c| !failedWith(cert.verifySignature(c), error.SignatureVerificationFailed) else false;

        // 拷进可写缓冲，翻掉 subject CN 的首字母，再解析一次。
        @memcpy(g_cert[0..cert.fixture_der.len], cert.fixture_der);
        const idx = std.mem.indexOf(u8, g_cert[0..cert.fixture_der.len], "ch23-stub.local").?;
        g_cert[idx] = 'd';
        const bad = cert.parse(g_cert[0..cert.fixture_der.len]) catch null;
        const tamper_rejected = if (bad) |*c| failedWith(cert.verifySignature(c), error.SignatureVerificationFailed) else false;

        var hbuf: [8]u8 = undefined;
        const fp = cert.fingerprint(cert.fixture_der);
        check(
            verify_ok and tamper_rejected,
            "x509 verify ok={d} tampered={s} fp={s}",
            .{ @intFromBool(verify_ok), if (tamper_rejected) "rejected" else "accepted", hex4(&hbuf, &fp) },
        );
    }

    // ---- ⑨ HTTP 请求解析 ----
    {
        const req_text =
            "GET /index.html?x=1 HTTP/1.1\r\n" ++
            "Host: ch23.local\r\n" ++
            "User-Agent: s31\r\n" ++
            "Accept: */*\r\n" ++
            "\r\n";
        const req = http.parseRequest(req_text) catch null;
        if (req) |r| {
            check(
                r.method == .get and std.mem.eql(u8, r.path, "/index.html") and
                    std.mem.eql(u8, r.query, "x=1") and r.header_len == 3 and r.keep_alive and
                    std.mem.eql(u8, r.header("host").?, "ch23.local"),
                "http request {s} {s} q={s} hdrs={d} keep={d}",
                .{ r.method_text, r.path, r.query, r.header_len, @intFromBool(r.keep_alive) },
            );
        } else {
            check(false, "http request parse=failed", .{});
        }
    }

    // ---- ⑩ chunked 解码 ----
    {
        const body = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
        const n = http.decodeChunked(body, &g_chunk) catch 0;
        const decoded = n == 9 and std.mem.eql(u8, g_chunk[0..n], "Wikipedia");
        const bad = failedWith(http.decodeChunked("zz\r\n", &g_chunk), error.BadChunkSize);
        check(
            decoded and bad,
            "http chunked decoded={d} body={s} bad={s}",
            .{ n, g_chunk[0..@as(usize, @min(n, 9))], if (bad) "rejected" else "accepted" },
        );
    }

    // ---- ⑪ keep-alive 矩阵 ----
    {
        const a = http.keepAlive(.http_1_1, "");
        const b = http.keepAlive(.http_1_1, "close");
        const c = http.keepAlive(.http_1_0, "");
        const d = http.keepAlive(.http_1_0, "keep-alive");
        check(
            a and !b and !c and d,
            "http keepalive 1.1={d} 1.1+close={d} 1.0={d} 1.0+keep={d}",
            .{ @intFromBool(a), @intFromBool(b), @intFromBool(c), @intFromBool(d) },
        );
    }

    // ---- ⑫ 响应构造 ----
    {
        const body = "Wikipedia";
        const resp = http.buildResponse(&g_http, 200, "OK", "text/plain", body, true) catch &[_]u8{};
        const has_status = std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n");
        const has_len = std.mem.indexOf(u8, resp, "Content-Length: 9\r\n") != null;
        const has_conn = std.mem.indexOf(u8, resp, "Connection: keep-alive\r\n") != null;
        const has_body = std.mem.endsWith(u8, resp, body);

        const closed = http.buildResponse(&g_http, 404, "Not Found", "text/plain", "nope", false) catch &[_]u8{};
        const close_ok = std.mem.indexOf(u8, closed, "Connection: close\r\n") != null;

        check(
            has_status and has_len and has_conn and has_body and close_ok,
            "http response status=200 cl={d} total={d} conn=keep-alive close=1",
            .{ body.len, resp.len },
        );
    }

    // ---- ⑬ RFC 8448 §3 的 handshake 密钥链 ----
    {
        const chain = ks.rfc8448Chain() catch null;
        if (chain) |c| {
            var b1: [8]u8 = undefined;
            var b2: [8]u8 = undefined;
            var b3: [8]u8 = undefined;
            check(
                c.matches(),
                "rfc8448 chain early={s} hs={s} c_hs={s} ok_all=1",
                .{ hex4(&b1, &c.early), hex4(&b2, &c.handshake), hex4(&b3, &c.client_hs) },
            );
        } else {
            check(false, "rfc8448 chain derivation=failed", .{});
        }
    }

    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();

    // 非判据读数：一条 KeySchedule 链的前 4 字节 + 一块曲线公钥长度。
    {
        const shared: [32]u8 = @splat(0x23);
        const sch = ks.buildSchedule(&shared, "hs", "ap") catch null;
        if (sch) |s| {
            var b1: [8]u8 = undefined;
            var b2: [8]u8 = undefined;
            var b3: [8]u8 = undefined;
            log.line("read: traffic c_ap={s} s_ap={s} master={s}", .{
                hex4(&b1, &s.client_ap_traffic),
                hex4(&b2, &s.server_ap_traffic),
                hex4(&b3, &s.master_secret),
            });
        }
        const pk = x.publicKey(x.selftest_seed);
        var hbuf: [8]u8 = undefined;
        log.line("read: x25519 pub(len={d})={s}", .{ pk.len, hex4(&hbuf, &pk) });
    }

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
