//! ch19-udp-dhcp-dns：板侧自检（最小骨架）。
//!
//! 本章的正餐在主机侧：`zig build test` 跑了 48 个具名用例（UDP 13 + DHCP 17 +
//! DNS 18，另加根文件容器 test，共 49）。板侧**只回答一个问题**：同一份纯逻辑
//! 代码在 rv32 + 真实 SRAM 布局下能不能把两条真实流程走完——
//!
//!   1. DHCP：DISCOVER → OFFER → REQUEST → ACK → T1 续租，外加一次 UDP 封装
//!      与端口分派（证明“报文能进 67/68 的槽”）；
//!   2. DNS：查询编码 → 带压缩指针的响应解析 → A 记录进缓存 → TTL 到期。
//!
//! 所有报文都在 `.bss` 的静态缓冲里构造，**不使用堆**：板侧没有分配器，
//! 也不该让一个自检依赖 `error.OutOfMemory`。
//!
//! 输出全部是判读行（`check: ... ok=1/0`），最后一行 `checks: passed=.. failed=..`。
//! 这些值是 2026-11-13 真机实测（`../logs/ch19-boot.log`）；未覆盖的联调项仍标「待真机验证」。
//! 报文里的 IP、xid、域名都是自造值，不来自任何一次真实抓包。

const std = @import("std");

const dhcp = @import("dhcp.zig");
const dns = @import("dns.zig");
const udp = @import("udp.zig");

const log = @import("log.zig");
const trap = @import("trap.zig");

const mac = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x19 };
const our_ip = [4]u8{ 192, 168, 1, 42 };
const router = [4]u8{ 192, 168, 1, 1 };
const dns_server = [4]u8{ 223, 5, 5, 5 };

var g_client: dhcp.Client = .{};
var g_dhcp_buf: [576]u8 = undefined;
var g_udp_buf: [600]u8 = undefined;
var g_dns_buf: [512]u8 = undefined;
var g_name_buf: [64]u8 = undefined;
var g_cache: dns.Cache = .{};

var g_passed: u32 = 0;
var g_failed: u32 = 0;

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

fn baseMsg(xid: u32, op: dhcp.Op) dhcp.Msg {
    var m = dhcp.Msg{ .xid = xid, .op = op };
    @memcpy(m.chaddr[0..6], &mac);
    return m;
}

fn ipEq(a: [4]u8, b: [4]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

/// 构造一条服务器回包（OFFER 或 ACK），补上客户端最关心的四个选项。
fn buildReply(buf: []u8, xid: u32, msg_type: dhcp.MsgType, lease: u32) []const u8 {
    var b = dhcp.Builder.init(buf, blk: {
        var m = baseMsg(xid, .reply);
        m.yiaddr = our_ip;
        m.siaddr = router;
        break :blk m;
    }) catch |err| trap.panic("selftest: dhcp builder init: {s}", .{@errorName(err)});

    b.option(dhcp.Option.message_type, &.{@intFromEnum(msg_type)}) catch
        trap.panic("selftest: dhcp option 53", .{});
    b.ip(dhcp.Option.server_id, router) catch trap.panic("selftest: dhcp option 54", .{});
    b.ip(dhcp.Option.subnet_mask, .{ 255, 255, 255, 0 }) catch
        trap.panic("selftest: dhcp option 1", .{});
    b.ip(dhcp.Option.router, router) catch trap.panic("selftest: dhcp option 3", .{});
    b.ip(dhcp.Option.dns, dns_server) catch trap.panic("selftest: dhcp option 6", .{});
    b.u32Opt(dhcp.Option.lease_time, lease) catch trap.panic("selftest: dhcp option 51", .{});
    return b.finish() catch |err| trap.panic("selftest: dhcp finish: {s}", .{@errorName(err)});
}

/// 构造一条 DNS 响应：问题区 + 一条 A 记录，记录名用压缩指针指回问题区。
fn buildDnsResponse(buf: []u8, id: u16, name: []const u8, addr: [4]u8, ttl: u32) []const u8 {
    const h = dns.Header{
        .id = id,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = 1,
    };
    _ = h.write(buf) catch trap.panic("selftest: dns header", .{});
    const q_end = dns.encodeQuery(buf, id, name, .a) catch
        trap.panic("selftest: dns encodeQuery", .{});
    // encodeQuery 已经把问题区写好了；把它之后的头部改回“响应”。
    _ = h.write(buf) catch trap.panic("selftest: dns header rewrite", .{});

    var pos = q_end;
    if (pos + 16 > buf.len) trap.panic("selftest: dns buffer too small", .{});
    buf[pos] = 0xC0;
    buf[pos + 1] = @intCast(dns.Header.len);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(dns.Type.a), .big);
    std.mem.writeInt(u16, buf[pos + 4 ..][0..2], @intFromEnum(dns.Class.in), .big);
    std.mem.writeInt(u32, buf[pos + 6 ..][0..4], ttl, .big);
    std.mem.writeInt(u16, buf[pos + 10 ..][0..2], 4, .big);
    @memcpy(buf[pos + 12 ..][0..4], &addr);
    pos += 16;
    return buf[0..pos];
}

fn runChecks() bool {
    g_passed = 0;
    g_failed = 0;
    g_client = .{};
    g_cache = .{};

    // ---- 1) DISCOVER：固定字段 + 魔数 ----
    var b = dhcp.Builder.init(&g_dhcp_buf, baseMsg(0x3D00_0001, .request)) catch
        trap.panic("selftest: builder init", .{});
    b.option(dhcp.Option.message_type, &.{@intFromEnum(dhcp.MsgType.discover)}) catch
        trap.panic("selftest: option 53", .{});
    b.option(dhcp.Option.param_list, &dhcp.default_param_list) catch
        trap.panic("selftest: option 55", .{});
    const discover = b.finish() catch trap.panic("selftest: finish", .{});

    check(
        discover.len > dhcp.options_off and discover[discover.len - 1] == dhcp.Option.end,
        "dhcp discover len={d} last=END({d})",
        .{ discover.len, discover[discover.len - 1] },
    );
    check(
        std.mem.readInt(u32, discover[dhcp.fixed_len..dhcp.options_off], .big) == dhcp.magic_cookie,
        "dhcp cookie=0x{x}",
        .{std.mem.readInt(u32, discover[dhcp.fixed_len..dhcp.options_off], .big)},
    );

    var opts: dhcp.Options = .{};
    dhcp.parseOptions(discover, &opts) catch trap.panic("selftest: parseOptions", .{});
    check(
        opts.message_type.? == .discover,
        "dhcp option53=discover({d})",
        .{@intFromEnum(opts.message_type.?)},
    );

    // ---- 2) 包进 UDP 并复核校验和，再走一次端口分派 ----
    const ip_len: u16 = @intCast(udp.Header.len + discover.len);
    const uh = udp.Header{
        .src_port = dhcp.client_port,
        .dst_port = dhcp.server_port,
        .length = ip_len,
    };
    _ = uh.write(&g_udp_buf) catch trap.panic("selftest: udp write", .{});
    // uh.write 只覆盖前 8 字节；载荷紧跟在首部之后。
    @memcpy(g_udp_buf[udp.Header.len..][0..discover.len], discover);
    const dgram = g_udp_buf[0..ip_len];
    udp.seal(.{ 0, 0, 0, 0 }, .{ 255, 255, 255, 255 }, dgram) catch
        trap.panic("selftest: udp seal", .{});
    check(
        udp.check(.{ 0, 0, 0, 0 }, .{ 255, 255, 255, 255 }, dgram) == .ok,
        "udp sport={d} dport={d} len={d} verified=ok",
        .{ uh.src_port, uh.dst_port, ip_len },
    );

    var demux: udp.Demux = .{};
    demux.bind(dhcp.server_port, .dhcp_server) catch trap.panic("selftest: bind 67", .{});
    demux.bind(dns.port, .dns_client) catch trap.panic("selftest: bind 53", .{});
    const routed = demux.dispatch(dgram);
    check(
        std.meta.activeTag(routed) == .delivered and routed.delivered == .dhcp_server,
        "udp demux dport=67 delivered=dhcp_server ports={d}",
        .{demux.used()},
    );

    // ---- 3) 状态机：DISCOVER → OFFER → REQUEST ----
    check(
        g_client.poll(0) == .send_discover and g_client.state == .selecting,
        "dhcp state=selecting xid=0x{x}",
        .{g_client.xid},
    );

    const offer_pkt = buildReply(&g_dhcp_buf, g_client.xid, .offer, 3600);
    const offer_msg = dhcp.parseFixed(offer_pkt) catch trap.panic("selftest: offer parse", .{});
    var offer_opts: dhcp.Options = .{};
    dhcp.parseOptions(offer_pkt, &offer_opts) catch trap.panic("selftest: offer options", .{});
    const act = g_client.onReply(&offer_msg, &offer_opts, 1) catch
        trap.panic("selftest: offer reject", .{});
    check(
        act == .send_request and ipEq(g_client.offered_ip, our_ip),
        "dhcp offer yiaddr={d}.{d}.{d}.{d} -> send_request",
        .{ our_ip[0], our_ip[1], our_ip[2], our_ip[3] },
    );

    // ---- 4) ACK → bound，T1/T2 换算 ----
    const ack_pkt = buildReply(&g_dhcp_buf, g_client.xid, .ack, 3600);
    const ack_msg = dhcp.parseFixed(ack_pkt) catch trap.panic("selftest: ack parse", .{});
    var ack_opts: dhcp.Options = .{};
    dhcp.parseOptions(ack_pkt, &ack_opts) catch trap.panic("selftest: ack options", .{});
    _ = g_client.onReply(&ack_msg, &ack_opts, 2) catch trap.panic("selftest: ack reject", .{});
    check(
        g_client.state == .bound and g_client.lease_secs == 3600 and
            g_client.t1_secs == 1800 and g_client.t2_secs == 3150,
        "dhcp bound ip={d}.{d}.{d}.{d} lease={d} t1={d} t2={d}",
        .{
            g_client.lease.ip[0], g_client.lease.ip[1],
            g_client.lease.ip[2], g_client.lease.ip[3],
            g_client.lease_secs,  g_client.t1_secs,
            g_client.t2_secs,
        },
    );
    check(
        ipEq(g_client.lease.router, router) and ipEq(g_client.lease.dns, dns_server),
        "dhcp options gw={d}.{d}.{d}.{d} dns={d}.{d}.{d}.{d}",
        .{
            g_client.lease.router[0], g_client.lease.router[1],
            g_client.lease.router[2], g_client.lease.router[3],
            g_client.lease.dns[0],    g_client.lease.dns[1],
            g_client.lease.dns[2],    g_client.lease.dns[3],
        },
    );

    // ---- 5) T1 到期 → 单播续租 ----
    const renew = g_client.poll(g_client.t1_at);
    check(
        renew == .send_renew and g_client.state == .renewing,
        "dhcp t1={d} renew state={s}",
        .{ g_client.t1_at, @tagName(g_client.state) },
    );

    // ---- 6) DNS 查询编码 ----
    const q_len = dns.encodeQuery(&g_dns_buf, 0x4A21, "example.com", .a) catch
        trap.panic("selftest: dns query", .{});
    const qh = dns.Header.parse(&g_dns_buf) catch trap.panic("selftest: dns header", .{});
    check(
        q_len == 29 and qh.qdcount == 1 and qh.flags.rd and !qh.flags.qr,
        "dns query len={d} qd={d} rd=1 labels=2",
        .{ q_len, qh.qdcount },
    );

    // ---- 7) 压缩指针响应 → A 记录 ----
    const resp = buildDnsResponse(&g_dns_buf, 0x4A21, "example.com", .{ 93, 184, 216, 34 }, 300);
    const ans = dns.findAnswer(resp, 0x4A21, &g_name_buf) catch
        trap.panic("selftest: dns findAnswer", .{});
    check(
        ipEq(ans.addr, .{ 93, 184, 216, 34 }) and ans.ttl == 300 and ans.cname_hops == 0,
        "dns a={d}.{d}.{d}.{d} ttl={d} cname_hops={d}",
        .{ ans.addr[0], ans.addr[1], ans.addr[2], ans.addr[3], ans.ttl, ans.cname_hops },
    );

    // ---- 8) 缓存：命中与 TTL 到期 ----
    g_cache.put("example.com", ans.addr, ans.ttl, 10) catch
        trap.panic("selftest: cache put", .{});
    const hit = g_cache.get("Example.COM", 10 + 299);
    check(
        hit != null and ipEq(hit.?, ans.addr),
        "dns cache hit=1 ttl_left=1 entries={d}",
        .{g_cache.len()},
    );
    check(
        g_cache.get("example.com", 10 + 300) == null and g_cache.len() == 0,
        "dns cache expired=1 entries={d}",
        .{g_cache.len()},
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
