//! ch16-stack-architecture-zero-copy：netif 抽象、输出路径与“拷贝点”。
//!
//! ## netif 是什么
//!
//! 在 lwIP 里，`struct netif` 是**协议栈与链路层之间唯一被承认的接口**
//! （`lwip/netif.h` 的 `output`/`linkoutput`）。它的价值不在“多一层抽象”，
//! 而在于把三件事说清楚：
//!
//!   1. **方向**：应用 → 协议栈 → netif → 链路层（发送）；链路层 → netif →
//!      协议栈（接收）。每一层只看见一个函数指针和一段字节。
//!   2. **约束**：MTU、是否 up、链路层要的是“连续缓冲”还是“分部缓冲”。
//!   3. **统计**：帧数、字节数、各类丢弃原因。没有这些计数器，“ping 不通”
//!      只能靠猜。
//!
//! 本章的 netif 只有 7 个字段，但保留了 lwIP 的关键形状：
//! `output_fn(ctx, frame)` 是**唯一**的链路出口，`receive` 是**唯一**的入口。
//!
//! ## 零拷贝的真实边界
//!
//! 协议栈内部可以一直用 pbuf 链（首部一块、载荷一块、甚至载荷分散在 DMA 环的
//! 多个描述符里）。但**链路层通常只接受一段连续内存**：以太网 MAC 的 DMA
//! 描述符要么指向一整帧，要么用 scatter-gather 描述符链——后者在 S31 上属于
//! ch17 的话题。
//!
//! 因此本章把“拷贝点”显式化成 `sendPbuf`：
//!
//!   - 单块 pbuf（`next == null`）：`payload` 本身就是连续的，直接交给
//!     `output_fn`，**零拷贝**，`linearize_copies` 不增加；
//!   - 多块 pbuf：必须把链拼进 `scratch`，这是唯一的一次 `memcpy`，
//!     `linearize_copies += 1`。
//!
//! 这个计数器就是“零拷贝路径图”的度量：一段报文从 socket 到 MAC 到底复制了
//! 几次，不靠读代码猜，靠计数器说。

const std = @import("std");
const pbuf = @import("pbuf.zig");
const headers = @import("headers.zig");

pub const LinkError = error{
    LinkDown,
    MtuExceeded,
    NoSpace,
};

/// 链路层出口。`ctx` 是驱动自己的状态（在 ch17 里会是 MAC 描述符环）。
pub const LinkOutput = *const fn (ctx: *anyopaque, frame: []const u8) LinkError!void;

pub const Stats = struct {
    tx_frames: u32 = 0,
    tx_bytes: u32 = 0,
    rx_frames: u32 = 0,
    rx_bytes: u32 = 0,
    drops_runt: u32 = 0,
    drops_malformed: u32 = 0,
    drops_bad_checksum: u32 = 0,
    drops_ethertype: u32 = 0,
    drops_mtu: u32 = 0,
    /// 发送路径上真正发生过几次“链 → 连续内存”的复制。
    linearize_copies: u32 = 0,
};

pub const DropReason = enum {
    runt,
    malformed,
    bad_ip_checksum,
    unknown_ethertype,
    mtu,
};

pub const RxKind = enum { ipv4, arp, dropped };

/// 一次接收的结果。`ip` 是解析出来的首部**值**，payload 仍在原帧里。
pub const Rx = struct {
    kind: RxKind,
    ip: ?headers.Ipv4 = null,
    reason: ?DropReason = null,
};

pub const Netif = struct {
    name: []const u8,
    mtu: u16 = 1500,
    up: bool = true,
    output_fn: ?LinkOutput = null,
    ctx: ?*anyopaque = null,
    stats: Stats = .{},

    /// 发送一段**连续**帧。MTU 检查在这里，不在调用方——否则每个调用点都要记得做。
    pub fn send(self: *Netif, frame: []const u8) LinkError!void {
        if (!self.up) return error.LinkDown;
        if (frame.len > self.mtu) {
            self.stats.drops_mtu += 1;
            return error.MtuExceeded;
        }
        const out = self.output_fn orelse return error.LinkDown;
        const ctx = self.ctx orelse return error.LinkDown;
        try out(ctx, frame);
        self.stats.tx_frames += 1;
        self.stats.tx_bytes += @intCast(frame.len);
    }

    /// 发送一条 pbuf 链。返回真正交给链路层的那段字节：
    /// 单块时是指向 pbuf 存储的视图（零拷贝），多块时是 `scratch` 的前缀。
    pub fn sendPbuf(self: *Netif, p: *const pbuf.Pbuf, scratch: []u8) LinkError![]const u8 {
        if (p.next == null) {
            try self.send(p.payload);
            return p.payload;
        }
        if (scratch.len < p.tot_len) return error.NoSpace;
        var it = pbuf.SliceIter.init(p);
        var offset: usize = 0;
        while (it.next()) |part| {
            @memcpy(scratch[offset .. offset + part.len], part);
            offset += part.len;
        }
        self.stats.linearize_copies += 1;
        const flat = scratch[0..offset];
        try self.send(flat);
        return flat;
    }

    /// 接收一帧：最小以太网输入路径。
    ///
    /// 只做三件事：长度检查、EtherType 分派、IPv4 首部校验和。
    /// 不做分片重组、不做 ARP 缓存、不做 UDP 端口分派——那些属于后续章节。
    pub fn receive(self: *Netif, frame: []const u8) Rx {
        self.stats.rx_bytes += @intCast(frame.len);
        if (frame.len < headers.Eth.len) {
            self.stats.drops_runt += 1;
            return .{ .kind = .dropped, .reason = .runt };
        }
        const eth = headers.Eth.parse(frame) catch {
            self.stats.drops_runt += 1;
            return .{ .kind = .dropped, .reason = .runt };
        };
        self.stats.rx_frames += 1;
        const body = frame[headers.Eth.len..];

        switch (eth.ethertype) {
            .ipv4 => {
                const ip = headers.Ipv4.parse(body) catch |err| switch (err) {
                    error.Truncated => {
                        self.stats.drops_runt += 1;
                        return .{ .kind = .dropped, .reason = .runt };
                    },
                    else => {
                        self.stats.drops_malformed += 1;
                        return .{ .kind = .dropped, .reason = .malformed };
                    },
                };
                if (!ip.verifyChecksum(body[0..ip.headerLen()])) {
                    self.stats.drops_bad_checksum += 1;
                    return .{ .kind = .dropped, .reason = .bad_ip_checksum };
                }
                return .{ .kind = .ipv4, .ip = ip };
            },
            .arp => return .{ .kind = .arp },
            else => {
                self.stats.drops_ethertype += 1;
                return .{ .kind = .dropped, .reason = .unknown_ethertype };
            },
        }
    }
};

/// 回环链路：把发送的帧抄进自己的缓冲，供测试/自检从 `receive` 再喂回去。
///
/// 这是主机侧 TAP 测试的“没有 root 的替身”：形状与真实链路一致（一个
/// `LinkOutput`），但交换发生在进程内。TAP 只是把这个缓冲换成内核网卡。
pub const Loopback = struct {
    buf: []u8,
    len: usize = 0,
    deliveries: u32 = 0,
    netif: Netif = undefined,

    pub fn init(self: *Loopback, buf: []u8, name: []const u8, mtu: u16) void {
        self.* = .{ .buf = buf };
        const ctx: *anyopaque = @ptrCast(self);
        self.netif = .{
            .name = name,
            .mtu = mtu,
            .output_fn = output,
            .ctx = ctx,
        };
    }

    fn output(ctx: *anyopaque, frame: []const u8) LinkError!void {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        if (frame.len > self.buf.len) return error.NoSpace;
        @memcpy(self.buf[0..frame.len], frame);
        self.len = frame.len;
        self.deliveries += 1;
    }

    /// 最后一次“发出去”的帧。
    pub fn last(self: *const Loopback) []const u8 {
        return self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;
const checksum = @import("checksum.zig");

/// 构造一帧完整的以太网/IPv4/UDP（192.168.1.10:40000 → 192.168.1.1:7）。
fn buildFrame(buf: []u8, payload: []const u8) ![]u8 {
    const eth = headers.Eth{
        .dst = .{ 0x02, 0, 0, 0, 0, 0x01 },
        .src = .{ 0x02, 0, 0, 0, 0, 0x02 },
        .ethertype = .ipv4,
    };
    _ = try eth.write(buf);

    const udp_len: u16 = @intCast(headers.Udp.len + payload.len);
    const total: u16 = @intCast(headers.Ipv4.min_len + udp_len);
    var ip = headers.Ipv4{
        .total_len = total,
        .id = 0x1c46,
        .ttl = 64,
        .protocol = .udp,
        .src = .{ 192, 168, 1, 10 },
        .dst = .{ 192, 168, 1, 1 },
    };
    _ = try ip.write(buf[headers.Eth.len..]);

    const udp_off = headers.Eth.len + headers.Ipv4.min_len;
    const udp = headers.Udp{
        .src_port = 40000,
        .dst_port = 7,
        .length = udp_len,
    };
    _ = try udp.write(buf[udp_off..]);
    @memcpy(buf[udp_off + headers.Udp.len ..][0..payload.len], payload);

    const dgram = buf[udp_off .. udp_off + udp_len];
    const c = checksum.udp(ip.src, ip.dst, dgram);
    std.mem.writeInt(u16, dgram[6..8], c, .big);

    return buf[0 .. headers.Eth.len + total];
}

test "netif: 发送的帧原样出现在回环缓冲里，统计正确" {
    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);

    var frame_buf: [64]u8 = undefined;
    const frame = try buildFrame(&frame_buf, "hello");
    try lo.netif.send(frame);

    try testing.expectEqualSlices(u8, frame, lo.last());
    try testing.expectEqual(@as(u32, 1), lo.netif.stats.tx_frames);
    try testing.expectEqual(@as(u32, @intCast(frame.len)), lo.netif.stats.tx_bytes);
}

test "netif: 超过 MTU 的帧被拒绝并计数" {
    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 32);

    var frame_buf: [64]u8 = undefined;
    const frame = try buildFrame(&frame_buf, "0123456789"); // 14+20+8+10 = 52 > 32
    try testing.expectError(error.MtuExceeded, lo.netif.send(frame));
    try testing.expectEqual(@as(u32, 1), lo.netif.stats.drops_mtu);
    try testing.expectEqual(@as(u32, 0), lo.netif.stats.tx_frames);
    try testing.expectEqual(@as(usize, 0), lo.last().len);
}

test "netif: 收到的以太网/IPv4/UDP 帧被正确分类" {
    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);

    var frame_buf: [64]u8 = undefined;
    const frame = try buildFrame(&frame_buf, "hi");

    const rx = lo.netif.receive(frame);
    try testing.expectEqual(RxKind.ipv4, rx.kind);
    const ip = rx.ip.?;
    try testing.expectEqual(@as(u8, 64), ip.ttl);
    try testing.expectEqual(@as(u16, 30), ip.total_len);
    try testing.expectEqual(@as(usize, 10), ip.payloadLen());
    try testing.expect(ip.verifyChecksum(frame[headers.Eth.len..]));

    const udp = try headers.Udp.parse(try ip.payload(frame[headers.Eth.len..]));
    try testing.expectEqual(@as(u16, 7), udp.dst_port);
    try testing.expectEqual(@as(u16, 10), udp.length);
}

test "netif: 坏校验和的 IP 包被丢弃，计数器加一" {
    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);

    var frame_buf: [64]u8 = undefined;
    const frame = try buildFrame(&frame_buf, "hi");
    var broken: [64]u8 = undefined;
    @memcpy(broken[0..frame.len], frame);
    broken[headers.Eth.len + 8] = 63; // 改 TTL 不更新校验和

    const rx = lo.netif.receive(broken[0..frame.len]);
    try testing.expectEqual(RxKind.dropped, rx.kind);
    try testing.expectEqual(DropReason.bad_ip_checksum, rx.reason.?);
    try testing.expectEqual(@as(u32, 1), lo.netif.stats.drops_bad_checksum);
}

test "netif: 短帧与未知 EtherType 分别走不同的丢弃计数" {
    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);

    const runt = lo.netif.receive("short");
    try testing.expectEqual(DropReason.runt, runt.reason.?);

    var other: [16]u8 = @splat(0);
    std.mem.writeInt(u16, other[12..14], 0x9000, .big);
    const unknown = lo.netif.receive(&other);
    try testing.expectEqual(DropReason.unknown_ethertype, unknown.reason.?);
    try testing.expectEqual(@as(u32, 1), lo.netif.stats.drops_ethertype);
}

test "netif: 单块 pbuf 的发送是零拷贝（返回的切片指向 pbuf 存储）" {
    var pool: pbuf.Pool(4, 64) = .{};
    const p = try pool.alloc(16);
    defer _ = pool.free(p);
    p.payload[0..4].* = .{ 1, 2, 3, 4 };

    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);
    var scratch: [64]u8 = undefined;

    const sent = try lo.netif.sendPbuf(p, &scratch);
    try testing.expect(@intFromPtr(sent.ptr) == @intFromPtr(p.payload.ptr));
    try testing.expectEqual(@as(u32, 0), lo.netif.stats.linearize_copies);
    try testing.expectEqualSlices(u8, p.payload, lo.last());
}

test "netif: 多块 pbuf 必须线性化，计数一次、字节顺序正确" {
    var pool: pbuf.Pool(4, 64) = .{};
    const chain = try pool.allocChain(&.{ 14, 20, 8, 3 });
    defer _ = pool.free(chain);
    for (chain.payload, 0..) |*b, i| b.* = @intCast(i);
    for (chain.next.?.payload, 0..) |*b, i| b.* = @intCast(100 + i);
    for (chain.next.?.next.?.payload, 0..) |*b, i| b.* = @intCast(200 + i);
    for (chain.next.?.next.?.next.?.payload, 0..) |*b, i| b.* = @intCast(250 + i);

    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);
    var scratch: [64]u8 = undefined;

    const sent = try lo.netif.sendPbuf(chain, &scratch);
    try testing.expectEqual(@as(usize, 45), sent.len);
    try testing.expectEqual(@as(u32, 1), lo.netif.stats.linearize_copies);
    try testing.expect(@intFromPtr(sent.ptr) == @intFromPtr(&scratch));
    try testing.expectEqual(@as(u8, 0), sent[0]);
    try testing.expectEqual(@as(u8, 100), sent[14]);
    try testing.expectEqual(@as(u8, 200), sent[34]);
    try testing.expectEqual(@as(u8, 250), sent[42]);
    try testing.expectEqualSlices(u8, sent, lo.last());
}

test "netif: scratch 不够大时返回 NoSpace，不发送半帧" {
    var pool: pbuf.Pool(4, 64) = .{};
    const chain = try pool.allocChain(&.{ 8, 8 });
    defer _ = pool.free(chain);

    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);
    var scratch: [8]u8 = undefined;

    try testing.expectError(error.NoSpace, lo.netif.sendPbuf(chain, &scratch));
    try testing.expectEqual(@as(usize, 0), lo.last().len);
    try testing.expectEqual(@as(u32, 0), lo.netif.stats.tx_frames);
}

test "netif: down 状态下不发送" {
    var backing: [128]u8 = undefined;
    var lo: Loopback = undefined;
    lo.init(&backing, "lo0", 1500);
    lo.netif.up = false;
    try testing.expectError(error.LinkDown, lo.netif.send("frame"));
}
