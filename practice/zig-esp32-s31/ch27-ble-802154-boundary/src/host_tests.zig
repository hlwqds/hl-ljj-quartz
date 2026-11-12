//! ch27-ble-802154-boundary：主机侧单测（x86_64，不碰硬件）。
//!
//! 与板侧自检共用同一批模块：这里的用例更细（边界值、往返、拒绝路径），
//! 板侧只保留 12 条汇总判据。`zig build test --summary all` 会报出用例数。
//!
//! 每个 KAT 的规范出处写在用例注释里；常数与规范一致，不是“跑出来的期望值”。

const std = @import("std");
const testing = std.testing;

const att = @import("att.zig");
const fifteen4 = @import("fifteen4.zig");
const gatt = @import("gatt.zig");
const hci = @import("hci.zig");

// ---------------------------------------------------------------------------
// HCI
// ---------------------------------------------------------------------------

test "hci: ACL header KAT (Vol 4 Part E 5.4.2)" {
    const hdr = hci.AclHeader{
        .handle = 0x042,
        .pb = .complete,
        .bc = .point_to_point,
        .data_len = 5,
    };
    var out: [4]u8 = undefined;
    hdr.encode(&out);
    try testing.expectEqualSlices(u8, &hci.kat_acl_header, &out);

    const back = try hci.AclHeader.decode(&out);
    try testing.expectEqual(@as(u12, 0x042), back.handle);
    try testing.expectEqual(@as(u16, 5), back.data_len);
    try testing.expectEqual(hci.Pb.complete, back.pb);
    try testing.expectEqual(hci.Bc.point_to_point, back.bc);
}

test "hci: ACL roundtrip and strict length" {
    var stats: hci.Stats = .{};
    var buf: [hci.acl_buf_size]u8 = undefined;
    const payload = [_]u8{ 0x03, 0x00, 0x04, 0x00, 0x0a, 0x25, 0x00 };
    const n = try hci.encodeAcl(&buf, 0x0042, .first_flushable, &payload, &stats);
    try testing.expectEqual(hci.acl_header_len + payload.len, n);
    try testing.expectEqual(@as(u32, 1), stats.acl_encoded);

    const pkt = try hci.decodeAcl(buf[0..n], &stats);
    try testing.expectEqualSlices(u8, &payload, pkt.payload);
    try testing.expectEqual(hci.Pb.first_flushable, pkt.header.pb);

    // 多一个字节 = Trailing（不静默忽略），少一个字节 = Short + truncated。
    try testing.expectError(error.Trailing, hci.decodeAcl(buf[0 .. n + 1], &stats));
    try testing.expectError(error.Short, hci.decodeAcl(buf[0 .. n - 1], &stats));
    try testing.expectEqual(@as(u32, 1), stats.truncated);
    try testing.expectEqual(@as(u32, 2), stats.rejected);
}

test "hci: oversize payload is rejected, not clamped" {
    var stats: hci.Stats = .{};
    var buf: [hci.acl_buf_size]u8 = undefined;
    var big: [hci.acl_max_payload + 1]u8 = @splat(0);
    try testing.expectError(error.Oversize, hci.encodeAcl(&buf, 1, .complete, &big, &stats));
    try testing.expectEqual(@as(u32, 1), stats.rejected);
    try testing.expectEqual(@as(u32, 0), stats.acl_encoded);

    // 恰好 251 字节可以通过。
    var edge: [hci.acl_max_payload]u8 = @splat(0);
    const n = try hci.encodeAcl(&buf, 1, .complete, &edge, &stats);
    try testing.expectEqual(hci.acl_buf_size, n);
}

test "hci: LE Set Advertising Enable command (Vol 4 Part E 7.8.9)" {
    var stats: hci.Stats = .{};
    var buf: [16]u8 = undefined;
    const op = hci.opcode(hci.ogf_le_controller, hci.ocf_le_set_adv_enable);
    try testing.expectEqual(@as(u16, 0x200a), op);

    const n = try hci.encodeCommand(&buf, op, &[_]u8{0x01}, &stats);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, &hci.kat_set_adv_enable, buf[0..5]);

    const cmd = try hci.decodeCommand(buf[0..n], &stats);
    try testing.expectEqual(op, cmd.op);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, cmd.params);
}

test "hci: LE Advertising Report decodes name and RSSI" {
    var stats: hci.Stats = .{};
    // 参数 = num_reports(1) + 一条报告。
    const params = hci.kat_adv_event_params;
    try testing.expectEqual(@as(u8, 1), params[0]);
    const report = try hci.decodeAdvReport(params[1..], &stats);
    try testing.expectEqual(@as(u8, 0x00), report.event_type);
    try testing.expectEqual(@as(u8, 0x00), report.addr_type);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5 }, &report.addr);
    try testing.expectEqual(@as(i8, -64), report.rssi);
    try testing.expectEqual(hci.kat_adv_data.len, report.data.len);

    const name = hci.findLocalName(report.data) orelse return error.NoName;
    try testing.expectEqualStrings("ch27", name);
}

test "hci: LE Connection Complete (Vol 4 Part E 7.7.65.1)" {
    var stats: hci.Stats = .{};
    const cc = try hci.decodeConnComplete(&hci.kat_conn_complete, &stats);
    try testing.expectEqual(@as(u8, 0), cc.status);
    try testing.expectEqual(@as(u16, 0x0042), cc.handle);
    try testing.expectEqual(@as(u8, 0), cc.role);
    try testing.expectEqual(@as(u16, 6), cc.interval);
    try testing.expectEqual(@as(u16, 0x00c8), cc.supervision_timeout);
    try testing.expectEqual(@as(u8, 0), cc.master_clock_accuracy);

    try testing.expectError(error.Short, hci.decodeConnComplete(hci.kat_conn_complete[0..17], &stats));
    try testing.expectError(error.Trailing, hci.decodeConnComplete(&(hci.kat_conn_complete ++ [_]u8{0}), &stats));
}

// ---------------------------------------------------------------------------
// ATT
// ---------------------------------------------------------------------------

test "att: MTU exchange KAT and floor (Vol 3 Part F 3.4.2)" {
    var stats: att.Stats = .{};
    const client = try att.decodeMtuReq(&att.kat_mtu_req, &stats);
    try testing.expectEqual(@as(u16, 247), client);
    try testing.expectEqual(@as(u16, 247), att.negotiate(client, att.max_mtu));

    var buf: [8]u8 = undefined;
    const n = try att.encodeMtuRsp(&buf, 247, &stats);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &att.kat_mtu_rsp, buf[0..3]);

    // 22 < 23 必须拒绝；527 以上按实现上限拒绝。
    try testing.expectError(error.MtuTooSmall, att.decodeMtuReq(&[_]u8{ 0x02, 0x16, 0x00 }, &stats));
    try testing.expectError(error.MtuTooLarge, att.decodeMtuReq(&[_]u8{ 0x02, 0x11, 0x02 }, &stats));
}

test "att: read request/response KAT and truncation" {
    var stats: att.Stats = .{};
    var buf: [64]u8 = undefined;

    const n1 = try att.encodeReadReq(&buf, 0x0025, &stats);
    try testing.expectEqualSlices(u8, &att.kat_read_req, buf[0..n1]);
    try testing.expectEqual(@as(u16, 0x0025), try att.decodeReadReq(buf[0..n1], &stats));

    const n2 = try att.encodeReadRsp(&buf, "ch27", 23, &stats);
    try testing.expectEqualSlices(u8, &att.kat_read_rsp, buf[0..n2]);
    try testing.expectEqual(@as(u32, 0), stats.truncated);

    // MTU=23 → 最多 22 字节值；30 字节被截断并计数。
    const long: [30]u8 = @splat('x');
    const n3 = try att.encodeReadRsp(&buf, &long, 23, &stats);
    try testing.expectEqual(@as(usize, 23), n3);
    try testing.expectEqual(@as(u32, 1), stats.truncated);
}

test "att: write request and notification encoding" {
    var stats: att.Stats = .{};
    var buf: [32]u8 = undefined;

    const n1 = try att.encodeWriteReq(&buf, 0x0028, &[_]u8{ 0x01, 0x00 }, &stats);
    try testing.expectEqualSlices(u8, &att.kat_write_req, buf[0..n1]);

    const wr = try att.decodeWriteReq(buf[0..n1], &stats);
    try testing.expectEqual(@as(u16, 0x0028), wr.handle);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00 }, wr.value);

    // Notification 的值上限是 MTU-3，截断计数独立于 read。
    const n2 = try att.encodeNotify(&buf, 0x0004, "t=21", 23, &stats);
    try testing.expectEqual(@as(usize, 7), n2);
    const big: [25]u8 = @splat('y');
    const n3 = try att.encodeNotify(&buf, 0x0004, &big, 23, &stats);
    try testing.expectEqual(@as(usize, 3 + 20), n3);
    try testing.expectEqual(@as(u32, 1), stats.truncated);
}

test "att: error response is exactly 5 bytes" {
    var stats: att.Stats = .{};
    var buf: [8]u8 = undefined;
    const n = try att.encodeError(&buf, .read_req, 0x0099, .invalid_handle, &stats);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, &att.kat_error_rsp, buf[0..5]);

    const parsed = try att.decodeError(buf[0..n], &stats);
    try testing.expectEqual(@as(u8, 0x0a), parsed.req_op);
    try testing.expectEqual(@as(u16, 0x0099), parsed.handle);
    try testing.expectEqual(@as(u8, 0x01), parsed.code);
}

// ---------------------------------------------------------------------------
// GATT
// ---------------------------------------------------------------------------

test "gatt: handle layout follows declaration/value/cccd" {
    var table: gatt.Table = .{};
    table.reset();
    const h1 = switch (table.add(0x2a00, gatt.Perm.ro(), "a")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    const h2 = switch (table.add(0x2a06, gatt.Perm.rn(), "b")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    try testing.expectEqual(@as(u16, 0x0002), h1);
    try testing.expectEqual(@as(u16, 0x0004), h2);
    // 第二个特征带通知 → 多一个 CCCD 句柄 0x0005。
    try testing.expectEqual(@as(u16, 0x0005), table.chars[1].cccd_handle);
    try testing.expectEqual(@as(u16, 0x0006), table.next_handle);
}

test "gatt: table full rejects the 9th characteristic" {
    var table: gatt.Table = .{};
    table.reset();
    var i: u8 = 0;
    while (i < gatt.max_chars) : (i += 1) {
        const r = table.add(0x2a00 + @as(u16, i), gatt.Perm.ro(), "x");
        try testing.expect(r == .handle);
    }
    const ninth = table.add(0x2a10, gatt.Perm.ro(), "x");
    try testing.expect(ninth == .err);
    try testing.expectEqual(gatt.Err.table_full, ninth.err);
    try testing.expectEqual(@as(u8, gatt.max_chars), table.countOf());
    try testing.expectEqual(@as(u32, 1), table.stats.rejected);
    try testing.expectEqual(@as(u16, 0x0011), table.next_handle);
}

test "gatt: permissions, cccd subscribe and notify" {
    var table: gatt.Table = .{};
    var astats: att.Stats = .{};
    table.reset();
    const h_ro = switch (table.add(0x2a00, gatt.Perm.ro(), "ro")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    const h_rn = switch (table.add(0x2a06, gatt.Perm.rn(), "t=21")) {
        .handle => |h| h,
        .err => return error.AddFailed,
    };
    const cccd = table.chars[1].cccd_handle;

    var buf: [32]u8 = undefined;
    // 写只读特征：Write Not Permitted（0x03）。
    const denied = table.handleWrite(h_ro, "x", &buf, &astats);
    try testing.expect(denied == .err);
    try testing.expectEqual(gatt.Err.write_not_permitted, denied.err);
    try testing.expectEqual(att.Code.write_not_permitted, denied.err.code().?);

    // 未订阅时 notify 是本地错误，不产生字节。
    buf[0] = 0xee;
    const before = table.notify(h_rn, &buf, 23, &astats);
    try testing.expect(before == .err);
    try testing.expectEqual(gatt.Err.not_subscribed, before.err);
    try testing.expectEqual(@as(?att.Code, null), before.err.code());
    try testing.expectEqual(@as(u8, 0xee), buf[0]);

    // 订阅：CCCD 写 {01 00}。
    const sub = table.handleWrite(cccd, &[_]u8{ 0x01, 0x00 }, &buf, &astats);
    try testing.expect(sub == .pdu);
    try testing.expectEqual(@as(u8, 1), table.subCount());
    try testing.expectEqual(@as(u8, 0b10), table.subMask());

    const sent = table.notify(h_rn, &buf, 23, &astats);
    try testing.expect(sent == .pdu);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x1b, 0x04, 0x00, 't', '=', '2', '1' }, buf[0..7]);

    // CCCD 可读：值为 {01 00}。
    const read = table.handleRead(cccd, &buf, 23, &astats);
    try testing.expect(read == .pdu);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0b, 0x01, 0x00 }, buf[0..3]);
}

test "gatt: subscription table capacity" {
    var table: gatt.Table = .{};
    var astats: att.Stats = .{};
    table.reset();
    var i: u8 = 0;
    while (i < gatt.max_subs + 1) : (i += 1) {
        const r = table.add(0x2a06, gatt.Perm.rn(), "v");
        try testing.expect(r == .handle);
    }
    var buf: [16]u8 = undefined;
    i = 0;
    while (i < gatt.max_subs) : (i += 1) {
        const cccd = table.chars[i].cccd_handle;
        const r = table.handleWrite(cccd, &[_]u8{ 0x01, 0x00 }, &buf, &astats);
        try testing.expect(r == .pdu);
    }
    const overflow = table.handleWrite(table.chars[gatt.max_subs].cccd_handle, &[_]u8{ 0x01, 0x00 }, &buf, &astats);
    try testing.expect(overflow == .err);
    try testing.expectEqual(gatt.Err.subs_full, overflow.err);
    try testing.expectEqual(att.Code.insufficient_resources, overflow.err.code().?);
    try testing.expectEqual(@as(u8, gatt.max_subs), table.subCount());
}

test "gatt: out-of-range handle is Invalid Handle (0x01)" {
    var table: gatt.Table = .{};
    var astats: att.Stats = .{};
    table.reset();
    _ = table.add(0x2a00, gatt.Perm.ro(), "v");
    var buf: [16]u8 = undefined;
    const r = table.handleRead(0x0099, &buf, 23, &astats);
    try testing.expect(r == .err);
    try testing.expectEqual(gatt.Err.invalid_handle, r.err);
    try testing.expectEqual(att.Code.invalid_handle, r.err.code().?);
    // 声明句柄与 0x0000 同样越界。
    try testing.expect(table.handleRead(0x0001, &buf, 23, &astats) == .err);
    try testing.expect(table.handleRead(0x0000, &buf, 23, &astats) == .err);
}

// ---------------------------------------------------------------------------
// 802.15.4 + 6LoWPAN
// ---------------------------------------------------------------------------

test "ieee802154: FCF bit layout (2015 7.2.1.1)" {
    const a = fifteen4.Fcf{
        .frame_type = .data,
        .ack_request = true,
        .pan_compress = true,
        .dest_mode = .short,
        .src_mode = .short,
    };
    try testing.expectEqual(@as(u16, 0x8861), a.encode());
    const back = fifteen4.Fcf.decode(0x8861);
    try testing.expectEqual(fifteen4.FrameType.data, back.frame_type);
    try testing.expect(back.ack_request);
    try testing.expect(back.pan_compress);
    try testing.expectEqual(fifteen4.AddrMode.short, back.dest_mode);
    try testing.expectEqual(fifteen4.AddrMode.short, back.src_mode);
    try testing.expectEqual(@as(u2, 0), back.version);

    const b = fifteen4.Fcf{ .src_mode = .long };
    try testing.expectEqual(@as(u16, 0xc000), b.encode() & 0xc000);
    try testing.expectEqual(fifteen4.AddrMode.long, fifteen4.Fcf.decode(0xc861).src_mode);
}

test "ieee802154: header encode/decode for short and long source" {
    var stats: fifteen4.Stats = .{};
    var buf: [32]u8 = undefined;

    const short = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    const n = try fifteen4.encodeHeader(&buf, short, &stats);
    try testing.expectEqual(@as(usize, 9), n);
    try testing.expectEqualSlices(u8, &fifteen4.kat_mac_short, buf[0..n]);

    const d = try fifteen4.decodeHeader(buf[0..n], &stats);
    try testing.expectEqual(@as(u8, 0x2a), d.header.seq);
    try testing.expectEqual(@as(u16, 0x1234), d.header.dest_pan);
    try testing.expectEqual(@as(u16, 0x0002), d.header.dest.short);
    try testing.expectEqual(@as(u16, 0x9a3c), d.header.src.short);

    const long = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{ .src_mode = .long },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    const n2 = try fifteen4.encodeHeader(&buf, long, &stats);
    try testing.expectEqual(@as(usize, 15), n2);
    try testing.expectEqualSlices(u8, &fifteen4.kat_mac_long_src, buf[0..n2]);
}

test "lowpan: stateless IPHC decompression (RFC 6282 3.1.1)" {
    var stats: fifteen4.Stats = .{};
    const mac = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    const v = try fifteen4.decompress(&fifteen4.kat_lowpan_short, &mac, &stats);
    try testing.expectEqual(@as(u8, 6), v.version());
    try testing.expectEqual(@as(u16, 10), v.payloadLen());
    try testing.expectEqual(@as(u8, 17), v.nextHeader());
    try testing.expectEqual(@as(u8, 255), v.hopLimit());

    const src = v.src();
    try testing.expectEqualSlices(u8, &[_]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x9a, 0x3c,
    }, &src);
    const dst = v.dst();
    try testing.expectEqualSlices(u8, &[_]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x00, 0x02,
    }, &dst);
    try testing.expectEqual(@as(u16, 0x1234), v.udp.src_port);
    try testing.expectEqual(@as(u16, 0x5678), v.udp.dst_port);
    try testing.expectEqual(@as(u16, 0xabcd), v.udp.checksum);
    try testing.expect(v.udp.checksum_present);
    try testing.expectEqualStrings("ok", v.payload);
    try testing.expectEqual(@as(u32, 1), stats.decompressed);
}

test "lowpan: elided addresses invert the U/L bit (RFC 4944 6)" {
    var stats: fifteen4.Stats = .{};
    const mac = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{ .src_mode = .long },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    const v = try fifteen4.decompress(&fifteen4.kat_lowpan_elided, &mac, &stats);
    const src = v.src();
    try testing.expectEqualSlices(u8, &[_]u8{
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    }, &src);
    try testing.expectEqualStrings("hi", v.payload);
}

test "lowpan: unsupported compression is rejected" {
    var stats: fifteen4.Stats = .{};
    const mac = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    try testing.expectError(error.UnsupportedCompression, fifteen4.decompress(&fifteen4.kat_lowpan_stateful, &mac, &stats));
    try testing.expectEqual(@as(u32, 1), stats.rejected);

    const p_compressed = [_]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xf1, 0x35 };
    try testing.expectError(error.UnsupportedCompression, fifteen4.decompress(&p_compressed, &mac, &stats));

    const frag = [_]u8{ 0xc0, 0x2a, 0x00 };
    try testing.expectError(error.BadDispatch, fifteen4.decompress(&frag, &mac, &stats));

    const not_udp = [_]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xe0, 0x00 };
    try testing.expectError(error.UnsupportedCompression, fifteen4.decompress(&not_udp, &mac, &stats));
    try testing.expectEqual(@as(u32, 4), stats.rejected);
    try testing.expectEqual(@as(u32, 0), stats.decompressed);
}
