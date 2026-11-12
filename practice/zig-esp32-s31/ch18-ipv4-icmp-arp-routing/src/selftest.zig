//! ch18-ipv4-icmp-arp-routing：板侧自检（最小骨架）。
//!
//! 本章的正餐在主机侧：`zig build test` 跑 inet/ipv4/icmp/arp/route 五个纯逻辑
//! 模块。板侧**只回答一个问题**：同一份代码在 rv32 + 真实 SRAM 布局下能否
//! 走完一条自洽的闭环——构造 ICMP 回显 → 按 MTU 分片 → 乱序重组 →
//! 查路由 → ARP 解析/老化 → 从 ICMP frag-needed 学 PMTU。
//!
//! 全部输出都是判读行（`check: ... ok=1/0`），最后一行 `checks: passed=..
//! failed=..`。这些值是 2026-11-13 真机实测（`../logs/` 下有原始输出）；README 与章节已同步，未覆盖项仍标了
//! 「待真机验证」。
//!
//! 不使用堆：原始数据报（3020 B）、三个 1500 B 分片缓冲、重组缓冲
//! （2 × 3020 B）、ARP 缓存、路由表、PMTU 表都是静态数组。镜像实测
//! `.data = 0x180`、`.bss = 0x3810`（≈14.4 KB，`_start` 只清 `.bss`），
//! 加上 16 KiB 主栈，这就是本章板侧对 SRAM 的真实压力。

const std = @import("std");

const arp = @import("arp.zig");
const icmp = @import("icmp.zig");
const inet = @import("inet.zig");
const ipv4 = @import("ipv4.zig");
const route = @import("route.zig");

const log = @import("log.zig");
const trap = @import("trap.zig");

const our_ip_text = "192.168.1.10";
const gw_ip_text = "192.168.1.1";

const dgram_cap = 20 + 8 + 2992; // 首部 20 + ICMP 8 + 载荷 2992 = 3020

var g_src: [dgram_cap]u8 = undefined;
var g_frag0: [1500]u8 = undefined;
var g_frag1: [1500]u8 = undefined;
var g_frag2: [1500]u8 = undefined;
var g_icmp_out: [128]u8 = undefined;
var g_arp_frame: [arp.packet_len]u8 = undefined;
var g_arp_reply: [arp.packet_len]u8 = undefined;

var g_reasm_buf: [ipv4.Reasm.capacity * ipv4.Reasm.stride]u8 = undefined;
var g_reasm: ipv4.Reasm = .{};
var g_cache: arp.Cache = .{};
var g_table: route.Table = .{};
var g_pmtu: ipv4.Pmtu = .{};

var g_passed: u32 = 0;
var g_failed: u32 = 0;

var g_text_ring: [6][16]u8 = undefined;
var g_text_idx: usize = 0;
var g_mac_ring: [2][18]u8 = undefined;
var g_mac_idx: usize = 0;

fn txt(a: inet.Addr) []const u8 {
    const slot = &g_text_ring[g_text_idx % g_text_ring.len];
    g_text_idx += 1;
    return inet.format(a, slot) catch "?";
}

fn mactext(m: arp.Mac) []const u8 {
    const slot = &g_mac_ring[g_mac_idx % g_mac_ring.len];
    g_mac_idx += 1;
    return arp.formatMac(m, slot) catch "?";
}

/// 一条判读行：格式化的正文 + `ok=1/0`，同时累计通过/失败数。
fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

/// 构造「ICMP echo 请求 + IPv4 首部」的数据报，写入 `g_src`。
/// 载荷按 0,1,2,… 填，便于重组后逐字节比对。
fn buildDatagram(payload_len: usize) []const u8 {
    const icmp_len = icmp.header_len + payload_len;
    g_src[20] = icmp.typ.echo_request;
    g_src[21] = 0;
    std.mem.writeInt(u16, g_src[22..24], 0, .big);
    std.mem.writeInt(u16, g_src[24..26], 0x1234, .big);
    std.mem.writeInt(u16, g_src[26..28], 1, .big);
    var i: usize = 0;
    while (i < payload_len) : (i += 1) g_src[28 + i] = @intCast(i & 0xFF);
    const c = inet.of(g_src[20 .. 20 + icmp_len]);
    std.mem.writeInt(u16, g_src[22..24], c, .big);

    var h = ipv4.Header{
        .total_len = @intCast(20 + icmp_len),
        .id = 0x4711,
        .ttl = 64,
        .protocol = ipv4.proto.icmp,
        .src = inet.parse(our_ip_text) catch unreachable,
        .dst = inet.parse(gw_ip_text) catch unreachable,
    };
    _ = h.write(g_src[0..20]) catch |err| trap.panic(
        "selftest: ipv4.write failed: {s}",
        .{@errorName(err)},
    );
    return g_src[0 .. 20 + icmp_len];
}

fn runChecks() bool {
    g_passed = 0;
    g_failed = 0;
    g_reasm.attach(&g_reasm_buf) catch |err| trap.panic(
        "selftest: reasm.attach failed: {s}",
        .{@errorName(err)},
    );

    const our_ip = inet.parse(our_ip_text) catch unreachable;
    const gw_ip = inet.parse(gw_ip_text) catch unreachable;
    const our_mac = arp.Mac{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };
    const gw_mac = arp.Mac{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const peer_ip = inet.parse("192.168.1.50") catch unreachable;
    const peer_mac = arp.Mac{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x0A };

    // ---- 1) 地址与掩码 ----
    const net = inet.network(our_ip, 24) catch unreachable;
    check(
        inet.eql(net, inet.parse("192.168.1.0") catch unreachable) and
            inet.inPrefix(net, 24, peer_ip) and
            !inet.inPrefix(net, 24, inet.parse("8.8.8.8") catch unreachable),
        "addr {s}/24 net={s} same-subnet(.50)=1 same-subnet(8.8.8.8)=0",
        .{ our_ip_text, txt(net) },
    );

    // ---- 2) ICMP 回显请求/应答 ----
    const req_len = icmp.writeEchoRequest(&g_icmp_out, 0x1234, 7, "zig-s31") catch |err| trap.panic(
        "selftest: writeEchoRequest failed: {s}",
        .{@errorName(err)},
    );
    check(
        req_len == 15 and icmp.checksumOk(g_icmp_out[0..req_len]),
        "icmp echo-request len={d} type={d} cksum-ok=1",
        .{ req_len, g_icmp_out[0] },
    );

    const reply = icmp.echoReplyFrom(g_icmp_out[0..req_len], &g_frag0) catch |err| trap.panic(
        "selftest: echoReplyFrom failed: {s}",
        .{@errorName(err)},
    );
    check(
        reply[0] == icmp.typ.echo_reply and icmp.checksumOk(reply) and
            std.mem.eql(u8, reply[8..], "zig-s31"),
        "icmp echo-reply len={d} type={d} payload-copied=1",
        .{ reply.len, reply[0] },
    );

    // ---- 3) IPv4 首部 + 分片 ----
    const dg = buildDatagram(2992);
    const hdr = ipv4.Header.parseChecked(dg) catch |err| trap.panic(
        "selftest: ipv4.parse failed: {s}",
        .{@errorName(err)},
    );
    check(
        hdr.version == 4 and hdr.ihl == 5 and hdr.protocol == ipv4.proto.icmp and
            hdr.total_len == 3020 and hdr.payloadLen() == 3000,
        "ipv4 ver=4 ihl=5 proto=1 total={d} payload={d} cksum-ok=1",
        .{ hdr.total_len, hdr.payloadLen() },
    );

    var frags = [3]ipv4.Fragment{
        .{ .buf = &g_frag0, .len = 0 },
        .{ .buf = &g_frag1, .len = 0 },
        .{ .buf = &g_frag2, .len = 0 },
    };
    const nfrag = ipv4.fragment(dg, 1500, &frags) catch |err| trap.panic(
        "selftest: fragment failed: {s}",
        .{@errorName(err)},
    );

    var offsets: [3]usize = @splat(0);
    var mfs: [3]bool = @splat(false);
    var lens: [3]usize = @splat(0);
    for (frags[0..nfrag], 0..) |f, i| {
        const fh = ipv4.Header.parseChecked(f.buf[0..f.len]) catch |err| trap.panic(
            "selftest: frag parse failed: {s}",
            .{@errorName(err)},
        );
        offsets[i] = fh.offsetBytes();
        mfs[i] = fh.mf;
        lens[i] = f.len;
    }
    check(
        nfrag == 3 and offsets[0] == 0 and offsets[1] == 1480 and offsets[2] == 2960 and
            mfs[0] and mfs[1] and !mfs[2] and lens[2] == 60,
        "ipv4 frag mtu=1500 n={d} off={d}/{d}/{d} mf=1/1/0 last-len={d}",
        .{ nfrag, offsets[0], offsets[1], offsets[2], lens[2] },
    );

    // ---- 4) 乱序重组 ----
    var done: ?[]const u8 = null;
    const order = [3]usize{ 2, 0, 1 };
    for (order, 0..) |idx, step| {
        const f = frags[idx];
        const fh = ipv4.Header.parseChecked(f.buf[0..f.len]) catch |err| trap.panic(
            "selftest: reasm parse failed: {s}",
            .{@errorName(err)},
        );
        const p = fh.payload(f.buf[0..f.len]) catch |err| trap.panic(
            "selftest: reasm payload failed: {s}",
            .{@errorName(err)},
        );
        switch (g_reasm.insert(fh, p, @intCast(step * 10)) catch |err| trap.panic(
            "selftest: reasm insert failed: {s}",
            .{@errorName(err)},
        )) {
            .complete => |bytes| done = bytes,
            .accepted => {},
            .duplicate => {},
        }
    }
    const reasm_ok = done != null and done.?.len == 3020 and std.mem.eql(u8, done.?, dg);
    check(
        reasm_ok and g_reasm.stats.completed == 1,
        "ipv4 reasm order=2,0,1 len={d} identical=1 completed={d}",
        .{ if (done) |d| d.len else 0, g_reasm.stats.completed },
    );

    // ---- 5) 路由表 ----
    g_table.add(.{ .dst = inet.parse("192.168.1.0") catch unreachable, .prefix = 24 }) catch |err| trap.panic(
        "selftest: route.add connected failed: {s}",
        .{@errorName(err)},
    );
    g_table.add(.{ .dst = inet.any, .prefix = 0, .gateway = gw_ip }) catch |err| trap.panic(
        "selftest: route.add default failed: {s}",
        .{@errorName(err)},
    );

    const on_link = g_table.lookup(peer_ip);
    check(
        on_link != null and on_link.?.on_link and inet.eql(on_link.?.via, peer_ip),
        "route {s} on-link=1 via-self=1 prefix={d}",
        .{ "192.168.1.50", if (on_link) |nh| nh.prefix else 0 },
    );

    const remote = g_table.lookup(inet.parse("8.8.8.8") catch unreachable);
    check(
        remote != null and !remote.?.on_link and inet.eql(remote.?.via, gw_ip),
        "route 8.8.8.8 on-link=0 via={s} prefix={d}",
        .{ if (remote) |nh| txt(nh.via) else "?", if (remote) |nh| nh.prefix else 0 },
    );

    // ---- 6) ARP：未解析 → 请求 → 应答 → reachable ----
    const first = g_cache.resolve(gw_ip, 0);
    var acts: [2]arp.Action = undefined;
    const emitted = g_cache.poll(0, &acts);
    check(
        !first and emitted == 1 and acts[0].kind == .request and inet.eql(acts[0].target, gw_ip),
        "arp resolve miss=1 request target={s}",
        .{txt(gw_ip)},
    );

    const reply_pkt = arp.Packet{
        .op = arp.Op.reply,
        .sha = gw_mac,
        .spa = gw_ip,
        .tha = our_mac,
        .tpa = our_ip,
    };
    _ = reply_pkt.write(&g_arp_frame) catch |err| trap.panic(
        "selftest: arp reply write failed: {s}",
        .{@errorName(err)},
    );
    const learned = arp.receive(&g_cache, &g_arp_frame, our_ip, our_mac, 100, &g_arp_reply) catch |err| trap.panic(
        "selftest: arp.receive failed: {s}",
        .{@errorName(err)},
    );
    const hit = g_cache.lookup(gw_ip, 101);
    check(
        learned.learned and learned.replied == 0 and hit != null and
            std.mem.eql(u8, &hit.?.mac, &gw_mac) and hit.?.state == .reachable,
        "arp learn state=reachable mac={s} lookup-hit=1",
        .{if (hit) |h| mactext(h.mac) else "?"},
    );

    // ---- 7) ARP 老化：+31 s 变 stale ----
    _ = g_cache.expire(31_101);
    check(
        g_cache.stateOf(gw_ip) == .stale,
        "arp expire +31s state={s}",
        .{@tagName(g_cache.stateOf(gw_ip))},
    );

    // ---- 8) ARP：收到问本机地址的请求 → 回 reply ----
    const ask = arp.Packet{
        .op = arp.Op.request,
        .sha = peer_mac,
        .spa = peer_ip,
        .tha = @splat(0),
        .tpa = our_ip,
    };
    _ = ask.write(&g_arp_frame) catch |err| trap.panic(
        "selftest: arp ask write failed: {s}",
        .{@errorName(err)},
    );
    const served = arp.receive(&g_cache, &g_arp_frame, our_ip, our_mac, 32_000, &g_arp_reply) catch |err| trap.panic(
        "selftest: arp serve failed: {s}",
        .{@errorName(err)},
    );
    const answer = arp.Packet.parse(g_arp_reply[0..served.replied]) catch arp.Packet{};
    check(
        served.replied == arp.packet_len and answer.op == arp.Op.reply and
            std.mem.eql(u8, &answer.sha, &our_mac) and inet.eql(answer.tpa, peer_ip),
        "arp serve reply op=2 sha={s} tpa={s} len={d}",
        .{ mactext(answer.sha), txt(answer.tpa), served.replied },
    );

    // ---- 9) PMTU：从 ICMP frag-needed 学到 1400 ----
    const far = inet.parse("8.8.8.8") catch unreachable;
    g_pmtu.learn(far, 1400, 40_000);
    check(
        g_pmtu.mtuFor(far) == 1400 and ipv4.needsFragment(1500, g_pmtu.mtuFor(far)),
        "pmtu dst=8.8.8.8 mtu={d} needs-frag(1500)=1",
        .{g_pmtu.mtuFor(far)},
    );

    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();
    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
