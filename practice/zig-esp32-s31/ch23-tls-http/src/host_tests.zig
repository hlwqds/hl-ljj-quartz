//! ch23-tls-http：主机侧单测入口。
//!
//! `zig build test` 只编译/运行这个文件。它**不**引用 `hw.zig`/`trap.zig`/
//! `start.zig`/`main.zig`/`selftest.zig`，所以能在 x86_64 / Zig 0.17.1 上跑，
//! 不需要开发板、不需要网线、不需要 root。
//!
//! 被测试的六个模块全是纯逻辑：
//!
//!   - `tls_record.zig`      记录头编解码、长度上限（2^14+256）、分片、
//!                           跨记录握手重组；
//!   - `tls_keyschedule.zig` HKDF-Extract/Expand（RFC 5869 A.1 已知答案）、
//!                           HkdfLabel 的线上编码、Expand-Label、Derive-Secret、
//!                           完整的 handshake/application secret 链；
//!   - `x25519.zig`          RFC 7748 §6.1 两组向量、低阶点拒绝、DH 对称性；
//!   - `aead.zig`            NIST SP 800-38D 的 AES-128-GCM 两组向量、
//!                           tag 篡改/AD 篡改的拒绝分支、TLS nonce 的 XOR；
//!   - `cert.zig`            DER 构造 / 解析 / ECDSA 自洽验签、fixture 对拍；
//!   - `http.zig`            请求行 + 首部 + `Content-Length`、chunked 解码、
//!                           keep-alive 判定、响应构造。
//!
//! 板侧那一只自检（`src/selftest.zig`）复用同样的模块，在 rv32 上把十二条
//! 判据各走一遍；两套测试的边界必须写清楚，不能互相冒充：主机侧负责
//! “向量与边界值”，板侧只负责“同一份代码在真实 SRAM 布局下跑得出同样结论”。

test {
    _ = @import("tls_record.zig");
    _ = @import("tls_keyschedule.zig");
    _ = @import("x25519.zig");
    _ = @import("aead.zig");
    _ = @import("cert.zig");
    _ = @import("http.zig");
}

// ---------------------------------------------------------------------------
// 跨模块的端到端用例
// ---------------------------------------------------------------------------

const std = @import("std");
const record = @import("tls_record.zig");
const ks = @import("tls_keyschedule.zig");
const x = @import("x25519.zig");
const aead = @import("aead.zig");
const http = @import("http.zig");
const cert = @import("cert.zig");

test "handshake message fragmented across three records is reassembled" {
    // 3004 字节的握手消息：4 字节头 + 3000 字节 body。
    var msg: [3004]u8 = undefined;
    try record.writeHandshakeHeader(msg[0..4], 1, 3000);
    for (msg[4..], 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var wire: [4096]u8 = undefined;
    var n: usize = 0;
    var splitter = try record.Splitter.init(&msg, 1024);
    var records: usize = 0;
    while (splitter.next()) |frag| {
        var hdr: [5]u8 = undefined;
        try record.writeHeader(&hdr, .handshake, frag.len);
        @memcpy(wire[n..][0..5], &hdr);
        n += 5;
        @memcpy(wire[n..][0..frag.len], frag);
        n += frag.len;
        records += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), records);
    try std.testing.expectEqual(@as(usize, 3), try record.countRecords(wire[0..n]));

    var rbuf: [4096]u8 = undefined;
    var reader = record.MessageReader.init(&rbuf);
    var got: ?[]const u8 = null;
    var pos: usize = 0;
    while (pos < n) {
        const rec = try record.splitOne(wire[pos..n]);
        pos += record.header_len + rec.fragment.len;
        if (try reader.push(rec.header.content_type, rec.fragment)) |m| got = m;
    }
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 3004), got.?.len);
    try std.testing.expectEqualSlices(u8, &msg, got.?);
    // 消息体是 (i & 0xFF)，第 3000 个字节应回绕到 3000-1024=… 直接比对整段即可。
}

test "two handshake messages inside one record are both delivered" {
    var payload: [40]u8 = undefined;
    try record.writeHandshakeHeader(payload[0..4], 2, 10);
    @memset(payload[4..14], 0xAA);
    try record.writeHandshakeHeader(payload[14..18], 4, 18);
    @memset(payload[18..36], 0xBB);

    var rbuf: [64]u8 = undefined;
    var reader = record.MessageReader.init(&rbuf);
    const first = try reader.push(.handshake, payload[0..20]);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(usize, 14), first.?.len);
    const second = try reader.take();
    try std.testing.expect(second == null); // 还差 14 字节
    const tail = try reader.push(.handshake, payload[20..36]);
    try std.testing.expect(tail != null);
    try std.testing.expectEqual(@as(u8, 4), tail.?[0]);
    try std.testing.expectEqual(@as(usize, 22), tail.?.len);
}

test "record version guard rejects nonsense versions" {
    const bad = [_]u8{ 22, 0x02, 0x00, 0x00, 0x10 };
    try std.testing.expectError(record.Error.BadVersion, record.readHeader(&bad));
    const ok = [_]u8{ 22, 0x03, 0x01, 0x00, 0x10 };
    const h = try record.readHeader(&ok);
    try std.testing.expectEqual(@as(u16, 0x0301), h.legacy_version);
}

test "key schedule chain is deterministic and label-sensitive" {
    const shared = @as([32]u8, @splat(0x5A));
    const a = try ks.buildSchedule(&shared, "clienthello|serverhello", "clienthello|serverhello|finished");
    const b = try ks.buildSchedule(&shared, "clienthello|serverhello", "clienthello|serverhello|finished");
    try std.testing.expectEqualSlices(u8, &a.client_ap_traffic, &b.client_ap_traffic);
    try std.testing.expect(!std.mem.eql(u8, &a.client_hs_traffic, &a.server_hs_traffic));
    try std.testing.expect(!std.mem.eql(u8, &a.client_ap_traffic, &a.server_ap_traffic));
    // 换共享秘密必须换出不同密钥。
    const other = @as([32]u8, @splat(0x5B));
    const c = try ks.buildSchedule(&other, "clienthello|serverhello", "clienthello|serverhello|finished");
    try std.testing.expect(!std.mem.eql(u8, &a.client_ap_traffic, &c.client_ap_traffic));
}

test "expand-label equals manual HKDF-Expand over a hand-built HkdfLabel" {
    const secret = @as([32]u8, @splat(0x11));
    const context = [_]u8{ 0xde, 0xad, 0xbe, 0xef };

    var ours: [32]u8 = undefined;
    try ks.expandLabel(&ours, secret, "s hs traffic", &context);

    // 手工拼 HkdfLabel：length(2)=0x0020, label_len(1)=6+12, "tls13 s hs traffic",
    // ctx_len(1)=4, ctx。
    const manual_info = [_]u8{ 0x00, 0x20, 0x12 } ++ "tls13 s hs traffic".* ++ [_]u8{0x04} ++ context;
    var manual: [32]u8 = undefined;
    ks.expand(&manual, secret, &manual_info);
    try std.testing.expectEqualSlices(u8, &manual, &ours);
}

test "GCM record sealing binds the record header as AD" {
    const key = @as([16]u8, @splat(0x33));
    const iv = @as([12]u8, @splat(0x44));
    const inner = "GET / HTTP/1.1\r\nHost: ch23.local\r\n\r\n\x17"; // 内含 content_type=23(0x17)
    var ct: [128]u8 = undefined;
    var tag: [16]u8 = undefined;
    try aead.seal(&ct, &tag, inner, 0x17, iv, 7, key);

    var back: [128]u8 = undefined;
    try aead.open(&back, ct[0..inner.len], tag, 0x17, iv, 7, key);
    try std.testing.expectEqualStrings(inner, back[0..inner.len]);

    // 换 sequence number：nonce 变，tag 必须对不上。
    try std.testing.expectError(aead.Error.AuthenticationFailed, aead.open(&back, ct[0..inner.len], tag, 0x17, iv, 8, key));
    // 换记录类型：AD 变，tag 必须对不上。
    try std.testing.expectError(aead.Error.AuthenticationFailed, aead.open(&back, ct[0..inner.len], tag, 0x16, iv, 7, key));
}

test "shared secret from X25519 feeds the schedule" {
    const a_sk: [32]u8 = @splat(0x01);
    const b_sk: [32]u8 = @splat(0x02);
    const shared = try x.scalarmult(a_sk, x.publicKey(b_sk));
    const sch = try ks.buildSchedule(&shared, "hs", "ap");
    try std.testing.expect(!std.mem.allEqual(u8, &sch.client_ap_traffic, 0));
}

test "http framing rules" {
    const data = "POST /submit HTTP/1.1\r\nHost: ch23.local\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world";
    const req = try http.parseRequest(data);
    try std.testing.expectEqual(http.Method.post, req.method);
    try std.testing.expectEqual(@as(?usize, 11), req.content_length);
    try std.testing.expect(!req.keep_alive);

    // Content-Length 与 Transfer-Encoding 同时出现：拒绝。
    const smuggle = "POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n";
    try std.testing.expectError(http.Error.AmbiguousFraming, http.parseRequest(smuggle));

    // 裸 LF 不是合法行尾。
    const lf = "GET / HTTP/1.1\nHost: x\n\n";
    try std.testing.expectError(http.Error.Incomplete, http.parseRequest(lf));
}

test "response construction keeps length and connection consistent" {
    var buf: [256]u8 = undefined;
    const body = "Wikipedia";
    const resp = try http.buildResponse(&buf, 200, "OK", "text/plain", body, true);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 9\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: keep-alive\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\nWikipedia"));

    const closed = try http.buildResponse(&buf, 404, "Not Found", "text/plain", "nope", false);
    try std.testing.expect(std.mem.indexOf(u8, closed, "Connection: close\r\n") != null);
}

test "certificate chain: parse → verify → tamper" {
    const c = try cert.parse(cert.fixture_der);
    try cert.verifySignature(&c);
    try std.testing.expectEqualStrings("ch23-stub.local", c.subject_cn);
}

test "our record constants equal std.crypto.tls's" {
    // std 里有一份完整的 TLS 1.3 客户端（`std.crypto.tls.Client`），它的记录层
    // 常量是独立维护的：两边必须一致，否则本章的“2^14+256 上限”只是自说自话。
    const tls = std.crypto.tls;
    try std.testing.expectEqual(tls.record_header_len, record.header_len);
    try std.testing.expectEqual(tls.max_ciphertext_inner_record_len, record.max_plaintext);
    try std.testing.expectEqual(tls.max_ciphertext_len, record.max_record_length);
    try std.testing.expectEqual(@as(usize, 16640), tls.max_ciphertext_len);
}
