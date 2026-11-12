//! ch27-ble-802154-boundary：板侧自检（12 条判据）。
//!
//! 本章板侧**不碰射频**：没有扫描、没有连接、没有读特征值、没有 Thread 入网。
//! controller 归档（libble_app.a 等）一个字节都没链接（见 `tools/symbols.sh`
//! 的产物与章节 27.2/27.11）。被测对象是四段纯逻辑：
//!
//!   `hci.zig`      —— HCI 分帧（ACL / Command / Event / LE Meta）
//!   `att.zig`      —— ATT 8 个操作码的字节布局与 MTU 截断
//!   `gatt.zig`     —— 定长特征表、句柄分配、权限、CCCD 订阅
//!   `fifteen4.zig` —— 802.15.4 FCF/地址 + 6LoWPAN IPHC 解压
//!
//! 12 条判据（每条一行 `check: ... ok=1/0`，数字全部来自实际比较）：
//!
//!   ① ACL 头编码 = 42 30 05 00，且 decode 往返一致
//!   ② ACL 251 字节上限：252 字节被拒（rejected=1），251 字节通过
//!   ③ ATT_MTU 交换：请求 247 → 协商 247 → 响应 03 F7 00；22 被拒
//!   ④ Read Request/Response 字节级 KAT（0A 25 00 / 0B 63 68 32 37）+ MTU 截断
//!   ⑤ 写权限拒绝：只读句柄 → ATT 0x03，Error Response 01 12 02 00 03
//!   ⑥ Notification + CCCD：未订阅不产生字节；订阅后 1B 02 00 't=21'
//!   ⑦ 句柄越界 → Error Response 01 0A 99 00 01
//!   ⑧ GATT 表容量：8 个特征注册成功，第 9 个 table_full，表不变
//!   ⑨ FCF 编码/解码：0x8861（双短）与 0xC861（源长）
//!   ⑩ 短/长地址模式：头长 9 / 15 字节，地址类型可判别
//!   ⑪ 6LoWPAN 解压：两个无状态案例（SAM/DAM=10 与 =11）
//!   ⑫ 不支持的压缩（SAC=1、P≠00、非 IPHC）被拒，rejected 计数准确
//!
//! 所有状态都在 `.bss` 的静态变量里：板侧没有堆，自检也不依赖分配失败。

const std = @import("std");

const att = @import("att.zig");
const fifteen4 = @import("fifteen4.zig");
const gatt = @import("gatt.zig");
const hci = @import("hci.zig");
const log = @import("log.zig");

var g_passed: u32 = 0;
var g_failed: u32 = 0;

var hci_stats: hci.Stats = .{};
var att_stats: att.Stats = .{};
var g4_stats: fifteen4.Stats = .{};
var table: gatt.Table = .{};

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

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `?Error` 与错误字面量的比较：Zig 不允许 `opt == error.Foo`，这里按名字比。
fn isErr(x: anytype, want: anyerror) bool {
    const e = x orelse return false;
    return std.mem.eql(u8, @errorName(e), @errorName(want));
}

fn addChar(uuid: u16, perm: gatt.Perm, initial: []const u8) u16 {
    return switch (table.add(uuid, perm, initial)) {
        .handle => |h| h,
        .err => 0,
    };
}

// ---------------------------------------------------------------------------
// ① ACL 头编码
// ---------------------------------------------------------------------------

fn checkAclHeader() void {
    hci_stats.reset();
    const hdr = hci.AclHeader{
        .handle = 0x042,
        .pb = .complete,
        .bc = .point_to_point,
        .data_len = 5,
    };
    var bytes: [4]u8 = undefined;
    hdr.encode(&bytes);
    const back = hci.AclHeader.decode(&bytes) catch hci.AclHeader{
        .handle = 0,
        .pb = .complete,
        .bc = .point_to_point,
        .data_len = 0,
    };
    const ok = eql(&bytes, &hci.kat_acl_header) and
        back.handle == 0x042 and
        back.data_len == 5 and
        back.pb == .complete;

    var hex_buf: [12]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch "?";
    check(ok, "hci acl header {s} handle=0x{x:0>3} pb={d}", .{
        hex, back.handle, @backingInt(back.pb),
    });
}

// ---------------------------------------------------------------------------
// ② ACL 最大长度（必须能区分“拒绝”与“静默截断”）
// ---------------------------------------------------------------------------

fn checkAclMax() void {
    hci_stats.reset();
    var buf: [hci.acl_buf_size]u8 = undefined;

    const big: [hci.acl_max_payload + 1]u8 = @splat(0xaa);
    var over_err: ?hci.Error = null;
    if (hci.encodeAcl(&buf, 0x042, .complete, &big, &hci_stats)) |_| {} else |e| over_err = e;
    const rejected = hci_stats.rejected;
    const encoded_after_over = hci_stats.acl_encoded;

    const ok_payload: [hci.acl_max_payload]u8 = @splat(0x55);
    const total = hci.encodeAcl(&buf, 0x042, .complete, &ok_payload, &hci_stats) catch 0;
    const back = hci.decodeAcl(buf[0..total], &hci_stats) catch null;

    // 再解一次被砍掉尾巴的包：必须计入 truncated，而不是静默通过。
    var trunc_err: ?hci.Error = null;
    if (hci.decodeAcl(buf[0 .. total - 1], &hci_stats)) |_| {} else |e| trunc_err = e;
    const truncated = hci_stats.truncated;

    const ok = isErr(over_err, error.Oversize) and
        rejected == 1 and
        encoded_after_over == 0 and
        total == hci.acl_header_len + hci.acl_max_payload and
        back != null and back.?.payload.len == hci.acl_max_payload and
        isErr(trunc_err, error.Short) and
        truncated == 1;
    check(ok, "hci acl max={d} oversize_rejected={d} encoded={d} truncated={d}", .{
        hci.acl_max_payload, rejected, hci_stats.acl_encoded, truncated,
    });
}

// ---------------------------------------------------------------------------
// ③ ATT_MTU 交换
// ---------------------------------------------------------------------------

fn checkMtuExchange() void {
    att_stats.reset();
    var buf: [8]u8 = undefined;

    const client = att.decodeMtuReq(&att.kat_mtu_req, &att_stats) catch 0;
    const negotiated = att.negotiate(client, att.max_mtu);
    const rsp_len = att.encodeMtuRsp(&buf, negotiated, &att_stats) catch 0;

    // 22 < 23：**本章更严的自定策略**（规范只规定 23 是默认/最小值，没要求
    // 拒绝；本机 NimBLE 是夹到 23，见 ble_att.c:494-496）。这里选择显式拒绝，
    // 因为这章的判据要一个可判别的失败，而不是静默钳位。
    const small: [3]u8 = .{ 0x02, 0x16, 0x00 };
    var small_err: ?att.Error = null;
    if (att.decodeMtuReq(&small, &att_stats)) |_| {} else |e| small_err = e;
    const exchanges_after_reject = att_stats.mtu_exchanges;

    const ok = client == 247 and
        negotiated == 247 and
        rsp_len == 3 and
        eql(buf[0..3], &att.kat_mtu_rsp) and
        isErr(small_err, error.MtuTooSmall) and
        exchanges_after_reject == 1 and
        att_stats.rejected == 1;
    check(ok, "att mtu req={d} negotiated={d} rsp=03f700 rejected={d} exchanges={d}", .{
        client, negotiated, att_stats.rejected, att_stats.mtu_exchanges,
    });
}

// ---------------------------------------------------------------------------
// ④ Read Request / Response + MTU 截断
// ---------------------------------------------------------------------------

fn checkReadKats() void {
    att_stats.reset();
    var buf: [64]u8 = undefined;

    const req_len = att.encodeReadReq(&buf, 0x0025, &att_stats) catch 0;
    const req_ok = req_len == 3 and eql(buf[0..3], &att.kat_read_req);

    const rsp_len = att.encodeReadRsp(&buf, "ch27", 23, &att_stats) catch 0;
    const rsp_ok = rsp_len == 5 and eql(buf[0..5], &att.kat_read_rsp);

    // 30 字节值、MTU=23 → 只能放 22 字节，截断计数 +1。
    const long: [30]u8 = @splat('x');
    const cut = att.encodeReadRsp(&buf, &long, 23, &att_stats) catch 0;
    const ok = req_ok and rsp_ok and cut == 23 and
        att_stats.truncated == 1 and
        att_stats.reads == 2;
    check(ok, "att read req=0a2500 rsp=0b-ch27 cut={d} truncated={d}", .{
        cut, att_stats.truncated,
    });
}

// ---------------------------------------------------------------------------
// ⑤ 写权限拒绝（断言具体错误码）
// ---------------------------------------------------------------------------

fn checkWritePermission() void {
    att_stats.reset();
    table.reset();
    var buf: [32]u8 = undefined;

    // 特征 #1：只读，句柄 0x0001(声明) / 0x0002(值)。
    const h_ro = addChar(0x2a00, gatt.Perm.ro(), "ro");
    // 特征 #2：读写，句柄 0x0003 / 0x0004。
    const h_rw = addChar(0x2a01, gatt.Perm.rw(), "rw");

    const denied = table.handleWrite(h_ro, "nope", &buf, &att_stats);
    var err_pdu: [5]u8 = undefined;
    const denied_ok = switch (denied) {
        .err => |e| blk: {
            if (e != .write_not_permitted) break :blk false;
            const code = e.code() orelse break :blk false;
            if (code != .write_not_permitted) break :blk false;
            _ = att.encodeError(&err_pdu, .write_req, h_ro, code, &att_stats) catch
                break :blk false;
            const expect = [5]u8{ 0x01, 0x12, 0x02, 0x00, 0x03 };
            break :blk eql(&err_pdu, &expect);
        },
        .pdu => false,
    };

    const allowed = table.handleWrite(h_rw, "ok", &buf, &att_stats);
    const allowed_ok = switch (allowed) {
        .pdu => |n| n == 1 and buf[0] == 0x13,
        .err => false,
    };

    const ok = h_ro == 0x0002 and h_rw == 0x0004 and
        denied_ok and allowed_ok and
        att_stats.errors_emitted == 1 and
        table.stats.writes == 1;
    check(ok, "gatt write ro_handle=0x{x:0>4} code=0x{x:0>2} err_pdu=0112020003 ok_writes={d}", .{
        h_ro, @backingInt(att.Code.write_not_permitted), table.stats.writes,
    });
}

// ---------------------------------------------------------------------------
// ⑥ Notification + CCCD 订阅
// ---------------------------------------------------------------------------

fn checkNotify() void {
    att_stats.reset();
    table.reset();
    var buf: [32]u8 = @splat(0xa5);

    // 特征 #1：读 + 通知，值 "t=21"。声明=1 值=2 CCCD=3。
    const h_val = addChar(0x2a06, gatt.Perm.rn(), "t=21");
    const h_cccd = h_val + 1;

    // 未订阅：本地错误，且不得写入任何字节（buf[0] 仍是 0xa5）。
    const unsub = table.notify(h_val, &buf, 23, &att_stats);
    const untouched = buf[0] == 0xa5;
    const unsub_ok = switch (unsub) {
        .err => |e| e == .not_subscribed and e.code() == null,
        .pdu => false,
    };

    // 订阅：写 CCCD {01 00}。
    const sub = table.handleWrite(h_cccd, &[_]u8{ 0x01, 0x00 }, &buf, &att_stats);
    const sub_ok = switch (sub) {
        .pdu => |n| n == 1 and buf[0] == 0x13,
        .err => false,
    };

    buf[0] = 0xa5;
    const sent = table.notify(h_val, &buf, 23, &att_stats);
    const expect = [7]u8{ 0x1b, 0x02, 0x00, 't', '=', '2', '1' };
    const sent_ok = switch (sent) {
        .pdu => |n| n == 7 and eql(buf[0..7], &expect),
        .err => false,
    };

    // 退订：CCCD {00 00}，之后 notify 再次被拒（且不占订阅槽）。
    const unsub_pdu = table.handleWrite(h_cccd, &[_]u8{ 0x00, 0x00 }, &buf, &att_stats);
    const unsub_write_ok = switch (unsub_pdu) {
        .pdu => |n| n == 1,
        .err => false,
    };
    const after = table.notify(h_val, &buf, 23, &att_stats);
    const after_ok = switch (after) {
        .err => |e| e == .not_subscribed,
        .pdu => false,
    };

    const ok = h_val == 0x0002 and h_cccd == 0x0003 and
        untouched and unsub_ok and sub_ok and sent_ok and
        unsub_write_ok and after_ok and
        table.subCount() == 0 and table.stats.subs == 1 and table.stats.unsubs == 1;
    check(ok, "notify unsub_untouched={d} cccd=0x{x:0>4} pdu=1b0200-t21 subs={d}/{d}", .{
        @intFromBool(untouched), h_cccd, table.stats.subs, table.stats.unsubs,
    });
}

// ---------------------------------------------------------------------------
// ⑦ 句柄越界 → Error Response
// ---------------------------------------------------------------------------

fn checkHandleRange() void {
    att_stats.reset();
    table.reset();
    var buf: [32]u8 = undefined;
    _ = addChar(0x2a00, gatt.Perm.ro(), "v");

    // 0x0099 从未分配；0x0000 是保留的无效句柄；0x0001 是声明句柄（不可读）。
    const r1 = table.handleRead(0x0099, &buf, 23, &att_stats);
    const r2 = table.handleRead(0x0000, &buf, 23, &att_stats);
    const r3 = table.handleRead(0x0001, &buf, 23, &att_stats);

    var pdu: [5]u8 = undefined;
    const code_ok = switch (r1) {
        .err => |e| blk: {
            const c = e.code() orelse break :blk false;
            if (c != .invalid_handle) break :blk false;
            _ = att.encodeError(&pdu, .read_req, 0x0099, c, &att_stats) catch
                break :blk false;
            break :blk eql(&pdu, &att.kat_error_rsp);
        },
        .pdu => false,
    };
    const both_err = (switch (r2) {
        .err => |e| e == .invalid_handle,
        .pdu => false,
    }) and (switch (r3) {
        .err => |e| e == .invalid_handle,
        .pdu => false,
    });

    check(code_ok and both_err and att_stats.errors_emitted == 1, "gatt handle range 0x0099=01-0a990001 reserved_rejected={d} errors={d}", .{
        @intFromBool(both_err), att_stats.errors_emitted,
    });
}

// ---------------------------------------------------------------------------
// ⑧ GATT 表容量上限
// ---------------------------------------------------------------------------

fn checkTableCapacity() void {
    table.reset();
    var added: u8 = 0;
    var i: u8 = 0;
    while (i < gatt.max_chars) : (i += 1) {
        const h = addChar(0x2a00 + @as(u16, i), gatt.Perm.ro(), "x");
        if (h != 0) added += 1;
    }
    const next_before = table.next_handle;
    const ninth = table.add(0x2a10, gatt.Perm.ro(), "x");
    const full_ok = switch (ninth) {
        .err => |e| blk: {
            if (e != .table_full) break :blk false;
            const c = e.code() orelse break :blk false;
            break :blk c == .insufficient_resources;
        },
        .handle => false,
    };
    const ok = added == gatt.max_chars and
        table.countOf() == gatt.max_chars and
        full_ok and
        table.stats.rejected == 1 and
        // 8 个只读特征 → 16 个句柄，next_handle 停在 0x0011。
        next_before == 0x0011;
    check(ok, "gatt capacity chars={d}/{d} ninth=table_full rejected={d} next=0x{x:0>4}", .{
        table.countOf(), gatt.max_chars, table.stats.rejected, table.next_handle,
    });
}

// ---------------------------------------------------------------------------
// ⑨ 802.15.4 FCF 编码/解码
// ---------------------------------------------------------------------------

fn checkFcf() void {
    const a = fifteen4.Fcf{
        .frame_type = .data,
        .ack_request = true,
        .pan_compress = true,
        .dest_mode = .short,
        .src_mode = .short,
    };
    const wa = a.encode();
    const back_a = fifteen4.Fcf.decode(wa);

    const b = fifteen4.Fcf{
        .frame_type = .data,
        .ack_request = true,
        .pan_compress = true,
        .dest_mode = .short,
        .src_mode = .long,
    };
    const wb = b.encode();

    const le_a = [2]u8{ @truncate(wa), @truncate(wa >> 8) };
    const le_b = [2]u8{ @truncate(wb), @truncate(wb >> 8) };
    const ok = wa == 0x8861 and
        eql(&le_a, &fifteen4.kat_fcf_short) and
        wb == 0xc861 and
        eql(&le_b, &fifteen4.kat_fcf_long_src) and
        back_a.frame_type == .data and
        back_a.ack_request and
        back_a.pan_compress and
        back_a.dest_mode == .short and
        back_a.src_mode == .short and
        back_a.version == 0;
    check(ok, "ieee802154 fcf short=0x{x:0>4} long_src=0x{x:0>4} acks=1 pancomp=1", .{
        wa, wb,
    });
}

// ---------------------------------------------------------------------------
// ⑩ 短地址 / 长地址模式
// ---------------------------------------------------------------------------

fn checkAddressModes() void {
    g4_stats.reset();
    var buf: [32]u8 = undefined;

    const short_hdr = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .short,
        },
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    const n_short = fifteen4.encodeHeader(&buf, short_hdr, &g4_stats) catch 0;
    const short_ok = n_short == 9 and eql(buf[0..9], &fifteen4.kat_mac_short);

    const long_hdr = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .long,
        },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    const n_long = fifteen4.encodeHeader(&buf, long_hdr, &g4_stats) catch 0;
    const long_ok = n_long == 15 and eql(buf[0..15], &fifteen4.kat_mac_long_src);

    // 解码回来：地址类型必须一致（短/长可判别，不是“都是 8 字节”）。
    const decoded = fifteen4.decodeHeader(&fifteen4.kat_frame_short, &g4_stats) catch null;
    const type_ok = if (decoded) |d|
        (d.header.src == .short) and (d.header.dest == .short) and
            d.payload.len == fifteen4.kat_lowpan_short.len and
            d.header.seq == 0x2a and d.header.dest_pan == 0x1234
    else
        false;

    const ok = short_ok and long_ok and type_ok and
        g4_stats.frames_encoded == 2 and
        g4_stats.frames_decoded == 1;
    check(ok, "ieee802154 hdr short={d}B long={d}B decoded={d} src=short", .{
        n_short, n_long, g4_stats.frames_decoded,
    });
}

// ---------------------------------------------------------------------------
// ⑪ 6LoWPAN 解压（两个无状态案例）
// ---------------------------------------------------------------------------

fn checkLowpan() void {
    g4_stats.reset();

    const hdr_a = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .short,
        },
        .seq = 0x2a,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    var a_ok = false;
    var a_len: u16 = 0;
    if (fifteen4.decompress(&fifteen4.kat_lowpan_short, &hdr_a, &g4_stats)) |v| {
        const want_src = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x9a, 0x3c,
        };
        const want_dst = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x00, 0x02,
        };
        const src = v.src();
        const dst = v.dst();
        a_len = v.payloadLen();
        a_ok = v.version() == 6 and
            v.payloadLen() == 10 and
            v.nextHeader() == 17 and
            v.hopLimit() == 255 and
            eql(&src, &want_src) and
            eql(&dst, &want_dst) and
            v.udp.src_port == 0x1234 and
            v.udp.dst_port == 0x5678 and
            v.udp.checksum == 0xabcd and
            v.udp.checksum_present and
            eql(v.payload, "ok");
    } else |_| {}

    // 第二个案例：地址全省略（SAM=11 DAM=11），源是长地址 → IID 的 U/L 位翻转。
    const hdr_b = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{
            .frame_type = .data,
            .ack_request = true,
            .pan_compress = true,
            .dest_mode = .short,
            .src_mode = .long,
        },
        .seq = 0x2b,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .long = .{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 } },
    };
    var b_ok = false;
    if (fifteen4.decompress(&fifteen4.kat_lowpan_elided, &hdr_b, &g4_stats)) |v| {
        const want_src = [16]u8{
            0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        };
        const src = v.src();
        b_ok = v.version() == 6 and
            v.payloadLen() == 10 and
            eql(&src, &want_src) and
            v.udp.src_port == 0x0050 and
            v.udp.dst_port == 0x0035 and
            eql(v.payload, "hi");
    } else |_| {}

    check(a_ok and b_ok and g4_stats.decompressed == 2, "lowpan stateless={d} ports=0x1234/0x5678 plen={d} ul_flip_ok={d}", .{
        g4_stats.decompressed, a_len, @intFromBool(b_ok),
    });
}

// ---------------------------------------------------------------------------
// ⑫ 不支持的压缩被拒（断言拒绝计数）
// ---------------------------------------------------------------------------

fn checkRejections() void {
    g4_stats.reset();
    const hdr = fifteen4.MacHeader{
        .fcf = fifteen4.Fcf{},
        .seq = 0,
        .dest_pan = 0x1234,
        .dest = .{ .short = 0x0002 },
        .src_pan = 0x1234,
        .src = .{ .short = 0x9a3c },
    };
    // 先成功解一个，确保 rejected 与 decompressed 是两个独立计数。
    if (fifteen4.decompress(&fifteen4.kat_lowpan_short, &hdr, &g4_stats)) |_| {} else |_| {}
    const ok_before = g4_stats.decompressed;

    // (a) SAC=1 / SAM=01：需要上下文表。
    var e1: ?fifteen4.Error = null;
    if (fifteen4.decompress(&fifteen4.kat_lowpan_stateful, &hdr, &g4_stats)) |_| {} else |e| e1 = e;
    // (b) NHC 端口压缩 P=01：本章不解。
    const p_compressed = [8]u8{ 0x7f, 0x22, 0x3c, 0x9a, 0x02, 0x00, 0xf1, 0x35 };
    var e2: ?fifteen4.Error = null;
    if (fifteen4.decompress(&p_compressed, &hdr, &g4_stats)) |_| {} else |e| e2 = e;
    // (c) 非 IPHC dispatch（分片头 11000xxx）。
    const frag = [3]u8{ 0xc0, 0x2a, 0x00 };
    var e3: ?fifteen4.Error = null;
    if (fifteen4.decompress(&frag, &hdr, &g4_stats)) |_| {} else |e| e3 = e;

    const ok = isErr(e1, error.UnsupportedCompression) and
        isErr(e2, error.UnsupportedCompression) and
        isErr(e3, error.BadDispatch) and
        g4_stats.rejected == 3 and
        g4_stats.decompressed == ok_before and
        ok_before == 1;
    var names_buf: [96]u8 = undefined;
    const names = std.fmt.bufPrint(&names_buf, "{s}+{s}+{s}", .{
        @errorName(e1.?), @errorName(e2.?), @errorName(e3.?),
    }) catch "?";
    check(ok, "lowpan reject stateful+ports+frag rejected={d} decompressed={d} ({s})", .{
        g4_stats.rejected, g4_stats.decompressed, names,
    });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

fn runChecks() bool {
    checkAclHeader();
    checkAclMax();
    checkMtuExchange();
    checkReadKats();
    checkWritePermission();
    checkNotify();
    checkHandleRange();
    checkTableCapacity();
    checkFcf();
    checkAddressModes();
    checkLowpan();
    checkRejections();
    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();

    log.line("read: hci acl_buf={d} max_payload={d} encoded={d} decoded={d} rejected={d}", .{
        hci.acl_buf_size,      hci.acl_max_payload, hci_stats.acl_encoded,
        hci_stats.acl_decoded, hci_stats.rejected,
    });
    log.line("read: att mtu={d}/{d} exchanges={d} reads={d} writes={d} notifies={d} errors={d} trunc={d}", .{
        att.default_mtu,          att.max_mtu,         att_stats.mtu_exchanges,
        att_stats.reads,          att_stats.writes,    att_stats.notifies,
        att_stats.errors_emitted, att_stats.truncated,
    });
    log.line("read: gatt chars={d} subs={d} mask=0x{x:0>2} lowpan_len={d}", .{
        table.countOf(),               table.subCount(), table.subMask(),
        fifteen4.kat_lowpan_short.len,
    });
    log.line("read: 154 frames={d}/{d} decompressed={d} rejected={d}", .{
        g4_stats.frames_encoded, g4_stats.frames_decoded,
        g4_stats.decompressed,   g4_stats.rejected,
    });

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
