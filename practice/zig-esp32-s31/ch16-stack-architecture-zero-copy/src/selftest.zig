//! ch16-stack-architecture-zero-copy：板侧自检（最小骨架）。
//!
//! 本章的正餐在主机侧：`zig build test` 跑了 54 个具名用例（pbuf 链、校验和、
//! 首部编解码、netif 路径、时间轮）。板侧**只回答一个问题**：同一份首部/校验和/
//! netif 代码在 rv32 + 真实 SRAM 布局下能否走完一条自洽的闭环。
//!
//! 因此这里只做四步（对应 6 条判据）：
//!
//!   1. 在静态缓冲里构造一帧 以太网/IPv4/UDP（校验和真算、真写入）；
//!   2. 经 `netif.Loopback` 发送 → 后备缓冲；
//!   3. 把收到的帧按 以太网 → IPv4 → UDP 逐层解析，验证长度、端口、校验和、载荷；
//!   4. 让 `netif.receive` 再分派一次，确认输入路径认得出这是 IPv4。
//!
//! pbuf 链与时间轮的演示**刻意留在主机侧**（`src/pbuf.zig`、`src/timer_wheel.zig`
//! 的测试）。板侧多做一件事，就多一个“出错但无法归因”的来源；本章的验收也只要求
//! 「一只自检打印 + loopback 帧构造」。
//!
//! 全部输出都是判读行（`check: ... ok=1/0`），最后一行 `checks: passed=..
//! failed=..`。这些值是**目标形态**，尚未上板；README 与章节里都标了
//! 「待真机验证」。不使用堆：帧缓冲与 loopback 后备缓冲都在 `.bss`。

const std = @import("std");

const checksum = @import("checksum.zig");
const headers = @import("headers.zig");
const netif = @import("netif.zig");

const log = @import("log.zig");
const trap = @import("trap.zig");

const frame_cap = 96;

var g_frame: [frame_cap]u8 = undefined;
var g_lo_backing: [frame_cap]u8 = undefined;
var g_lo: netif.Loopback = undefined;

var g_passed: u32 = 0;
var g_failed: u32 = 0;

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

/// 构造一帧以太网/IPv4/UDP。首部写入 `g_frame`，返回整帧切片。
fn buildFrame(payload: []const u8) []const u8 {
    const eth = headers.Eth{
        .dst = .{ 0x02, 0, 0, 0, 0, 0x01 },
        .src = .{ 0x02, 0, 0, 0, 0, 0x02 },
        .ethertype = .ipv4,
    };
    _ = eth.write(&g_frame) catch |err| trap.panic(
        "selftest: eth.write failed: {s}",
        .{@errorName(err)},
    );

    const udp_len: u16 = @intCast(headers.Udp.len + payload.len);
    var ip = headers.Ipv4{
        .total_len = headers.Ipv4.min_len + udp_len,
        .id = 0x1c46,
        .ttl = 64,
        .protocol = .udp,
        .src = .{ 192, 168, 1, 10 },
        .dst = .{ 192, 168, 1, 1 },
    };
    _ = ip.write(g_frame[headers.Eth.len..]) catch |err| trap.panic(
        "selftest: ipv4.write failed: {s}",
        .{@errorName(err)},
    );

    const udp_off = headers.Eth.len + headers.Ipv4.min_len;
    const udp = headers.Udp{
        .src_port = 40000,
        .dst_port = 7,
        .length = udp_len,
    };
    _ = udp.write(g_frame[udp_off..]) catch |err| trap.panic(
        "selftest: udp.write failed: {s}",
        .{@errorName(err)},
    );
    @memcpy(g_frame[udp_off + headers.Udp.len ..][0..payload.len], payload);

    const dgram = g_frame[udp_off .. udp_off + udp_len];
    const sum = checksum.udp(ip.src, ip.dst, dgram);
    std.mem.writeInt(u16, dgram[6..8], sum, .big);

    return g_frame[0 .. headers.Eth.len + ip.total_len];
}

fn runChecks() bool {
    g_passed = 0;
    g_failed = 0;
    g_lo.init(&g_lo_backing, "lo0", 1500);

    const payload = "zig/s31";
    const frame = buildFrame(payload);
    log.line("frame: eth 14 + ipv4 20 + udp 8 + payload {d} = {d}B", .{
        payload.len, frame.len,
    });

    // ---- 1) 发送（loopback）----
    g_lo.netif.send(frame) catch |err| trap.panic(
        "selftest: loopback send failed: {s}",
        .{@errorName(err)},
    );
    check(
        std.mem.eql(u8, g_lo.last(), frame) and g_lo.netif.stats.tx_frames == 1,
        "loopback tx frames={d} bytes={d} identical=1",
        .{ g_lo.netif.stats.tx_frames, g_lo.netif.stats.tx_bytes },
    );

    // ---- 2) 以太网首部 ----
    const eth = headers.Eth.parse(frame) catch |err| trap.panic(
        "selftest: eth.parse failed: {s}",
        .{@errorName(err)},
    );
    const want_dst = [_]u8{ 0x02, 0, 0, 0, 0, 0x01 };
    check(
        eth.ethertype == .ipv4 and std.mem.eql(u8, &eth.dst, &want_dst),
        "eth ethertype=0x{x} dst=02:00:00:00:00:01",
        .{@intFromEnum(eth.ethertype)},
    );

    // ---- 3) IPv4 首部与校验和 ----
    const body = frame[headers.Eth.len..];
    const ip = headers.Ipv4.parse(body) catch |err| trap.panic(
        "selftest: ipv4.parse failed: {s}",
        .{@errorName(err)},
    );
    check(
        ip.total_len == headers.Ipv4.min_len + headers.Udp.len + payload.len and
            ip.verifyChecksum(body),
        "ipv4 ver={d} ihl={d} ttl={d} proto={d} total={d} cksum=0x{x}",
        .{
            ip.version,
            ip.ihl,
            ip.ttl,
            @intFromEnum(ip.protocol),
            ip.total_len,
            ip.checksum_value,
        },
    );

    // ---- 4) UDP 首部与校验和 ----
    const dgram = ip.payload(body) catch |err| trap.panic(
        "selftest: ipv4.payload failed: {s}",
        .{@errorName(err)},
    );
    const udp = headers.Udp.parse(dgram) catch |err| trap.panic(
        "selftest: udp.parse failed: {s}",
        .{@errorName(err)},
    );
    var sum = checksum.pseudoSeed(ip.src, ip.dst, 17, @intCast(dgram.len));
    sum.add(dgram);
    check(
        sum.finish() == 0 and udp.length == dgram.len and udp.dst_port == 7,
        "udp sport={d} dport={d} len={d} cksum=0x{x} verified=1",
        .{ udp.src_port, udp.dst_port, udp.length, udp.checksum_value },
    );

    // ---- 5) 载荷（原帧切片，不复制）----
    check(
        std.mem.eql(u8, dgram[headers.Udp.len..], payload),
        "payload \"{s}\" offset={d}",
        .{ dgram[headers.Udp.len..], headers.Udp.len },
    );

    // ---- 6) 接收路径分类 ----
    const rx = g_lo.netif.receive(frame);
    check(
        rx.kind == .ipv4 and rx.ip.?.src[0] == 192 and g_lo.netif.stats.rx_frames == 1,
        "rx kind={s} src=192.168.1.10 frames={d}",
        .{ @tagName(rx.kind), g_lo.netif.stats.rx_frames },
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
