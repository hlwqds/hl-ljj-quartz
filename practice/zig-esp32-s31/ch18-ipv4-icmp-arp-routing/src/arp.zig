//! ch18-ipv4-icmp-arp-routing：ARP 报文编解码 + 缓存状态机。
//!
//! ARP 的报文格式只有 28 个字节，难点全在**缓存的生命周期**：
//!
//!   - 什么时候能相信一条映射？（收到 reply，或收到对方发来的 request 且
//!     `sender IP/MAC` 都在报文里——RFC 826 允许"捎带学习"）
//!   - 什么时候该重发请求？（`incomplete` 态，1 s 一次，最多 3 次）
//!   - 什么时候该怀疑一条映射已经过期？（`reachable` 30 s 后变 `stale`，
//!     下次要发包时先进入 `delay`，确认无人纠正再 `probe`）
//!
//! 这套状态机的命名与 Linux 邻居子系统（`NUD_INCOMPLETE/REACHABLE/STALE/
//! DELAY/PROBE`）一致，方便拿 `ip neigh show` 的输出对照。区别在于 Linux 把
//! `base_reachable_time` 在 [1/2, 3/2] 区间随机化以避免同步风暴，本章用固定
//! 的 30 s / 5 s / 1 s，便于在主机单测里用假时钟推进。
//!
//! ## 为什么 `incomplete` 时不能"先发出去再说"
//!
//! 以太网帧必须有目的 MAC。没有解析结果时，唯一能发的是广播 ARP 请求；
//! 上层数据报必须**排队**（`pending queue`，本章未实现，见 18.11 的边界）
//! 或直接返回"暂时不可达"。很多实现选择"发广播帧试试看"，结果是数据帧
//! 被所有主机收下又丢弃，还污染了对端的连接状态。

const std = @import("std");
const inet = @import("inet.zig");

/// ARP 只处理一种组合：以太网（htype=1）+ IPv4（ptype=0x0800）+ 6/4 字节地址。
pub const htype_ethernet: u16 = 1;
pub const ptype_ipv4: u16 = 0x0800;
pub const hlen: u8 = 6;
pub const plen: u8 = 4;
pub const packet_len = 28;

pub const Op = struct {
    pub const request: u16 = 1;
    pub const reply: u16 = 2;
};

pub const Error = error{
    Truncated,
    ShortBuffer,
    Unsupported,
};

pub const Mac = [6]u8;

pub const Packet = struct {
    op: u16 = Op.request,
    sha: Mac = @splat(0),
    spa: inet.Addr = inet.any,
    tha: Mac = @splat(0),
    tpa: inet.Addr = inet.any,

    /// 写 28 字节。硬件类型/协议类型/地址长度固定写成以太网 + IPv4 的取值。
    pub fn write(self: Packet, buf: []u8) Error![]const u8 {
        if (buf.len < packet_len) return error.ShortBuffer;
        std.mem.writeInt(u16, buf[0..2], htype_ethernet, .big);
        std.mem.writeInt(u16, buf[2..4], ptype_ipv4, .big);
        buf[4] = hlen;
        buf[5] = plen;
        std.mem.writeInt(u16, buf[6..8], self.op, .big);
        buf[8..14].* = self.sha;
        buf[14..18].* = self.spa;
        buf[18..24].* = self.tha;
        buf[24..28].* = self.tpa;
        return buf[0..packet_len];
    }

    /// 解析。只接受 htype=1/ptype=0x0800/hlen=6/plen=4；其它组合返回
    /// `error.Unsupported`（例如 6over4、FireWire ARP）。
    pub fn parse(buf: []const u8) Error!Packet {
        if (buf.len < packet_len) return error.Truncated;
        const htype = std.mem.readInt(u16, buf[0..2], .big);
        const ptype = std.mem.readInt(u16, buf[2..4], .big);
        if (htype != htype_ethernet or ptype != ptype_ipv4 or buf[4] != hlen or buf[5] != plen)
            return error.Unsupported;
        return .{
            .op = std.mem.readInt(u16, buf[6..8], .big),
            .sha = buf[8..14].*,
            .spa = buf[14..18].*,
            .tha = buf[18..24].*,
            .tpa = buf[24..28].*,
        };
    }
};

pub fn formatMac(mac: Mac, buf: []u8) Error![]const u8 {
    if (buf.len < 18) return error.ShortBuffer;
    return std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    }) catch return error.ShortBuffer;
}

pub fn isBroadcastMac(mac: Mac) bool {
    for (mac) |b| {
        if (b != 0xFF) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 缓存状态机
// ---------------------------------------------------------------------------

pub const State = enum {
    /// 槽空闲。
    free,
    /// 已发出请求，等应答；MAC 还不可用。
    incomplete,
    /// 最近确认过的映射，可以直接用。
    reachable,
    /// 过了确认期，MAC 仍然可用，但下次使用时要复核。
    stale,
    /// 已进入复核倒计时，还没发探测。
    delay,
    /// 正在发单播 ARP 探测（RFC 5227 风格，目的 MAC 用缓存里的值）。
    probe,
};

pub const Entry = struct {
    state: State = .free,
    ip: inet.Addr = inet.any,
    mac: Mac = @splat(0),
    /// 最后一次"确认"（learn/lookup 推进）的时间。
    updated_ms: u32 = 0,
    /// 下一次应当执行动作（发请求/发探测）的时间。
    next_action_ms: u32 = 0,
    probes: u8 = 0,
};

/// `poll` 输出的动作：上层据此构造并发出一个 ARP 请求。
pub const Action = struct {
    /// `request`：incomplete 态的重发；`probe`：delay/probe 态的复核。
    kind: enum { request, probe },
    target: inet.Addr,
};

pub const Cache = struct {
    pub const capacity = 8;
    /// RFC 1122 §2.3.2.1：请求重传间隔 1 s。
    pub const retransmit_ms: u32 = 1_000;
    pub const max_probes: u8 = 3;
    /// 确认有效期。Linux 默认 `base_reachable_time` 30 s（带随机抖动）；
    /// 这里不抖，便于测试。
    pub const reachable_ms: u32 = 30_000;
    /// `stale` → `delay` 之后先等 5 s（给上层一个"顺带被刷新"的机会）。
    pub const delay_ms: u32 = 5_000;
    /// 探测间隔。
    pub const probe_interval_ms: u32 = 1_000;
    /// `stale` 条目在无人使用后的回收时间。
    pub const stale_gc_ms: u32 = 60_000;

    pub const Stats = struct {
        inserts: u32 = 0,
        hits: u32 = 0,
        misses: u32 = 0,
        learns: u32 = 0,
        requests: u32 = 0,
        probes: u32 = 0,
        expired: u32 = 0,
        failures: u32 = 0,
        evicted: u32 = 0,
    };

    pub const Lookup = struct {
        mac: Mac,
        state: State,
    };

    entries: [capacity]Entry = @splat(Entry{}),
    stats: Stats = .{},

    fn find(self: *Cache, ip: inet.Addr) ?usize {
        for (&self.entries, 0..) |*e, i| {
            if (e.state != .free and inet.eql(e.ip, ip)) return i;
        }
        return null;
    }

    /// 取一个槽：优先空闲，其次回收最久没确认的（`stale`/`delay`/`probe` 优先于
    /// `reachable`，因为它们的 MAC 本来就快要被丢掉）。
    fn alloc(self: *Cache) usize {
        for (&self.entries, 0..) |*e, i| {
            if (e.state == .free) return i;
        }
        var victim: usize = 0;
        for (self.entries, 0..) |e, i| {
            const less_valuable = rank(e.state) < rank(self.entries[victim].state) or
                (rank(e.state) == rank(self.entries[victim].state) and
                    e.updated_ms < self.entries[victim].updated_ms);
            if (less_valuable) victim = i;
        }
        self.stats.evicted += 1;
        self.entries[victim] = .{ .state = .free };
        return victim;
    }

    fn rank(s: State) u8 {
        return switch (s) {
            .free => 0,
            .stale => 1,
            .delay => 2,
            .probe => 3,
            .reachable => 4,
            .incomplete => 5,
        };
    }

    /// 查一条映射。
    ///
    /// `incomplete` 返回 null（MAC 还不可用）；`reachable` 原样返回；
    /// `stale` 返回旧 MAC **并**推进到 `delay`（下次使用前复核）；
    /// `delay`/`probe` 返回旧 MAC，但不刷新计时器。
    pub fn lookup(self: *Cache, ip: inet.Addr, now_ms: u32) ?Lookup {
        const i = self.find(ip) orelse {
            self.stats.misses += 1;
            return null;
        };
        const e = &self.entries[i];
        switch (e.state) {
            .incomplete => {
                self.stats.misses += 1;
                return null;
            },
            .reachable => {
                self.stats.hits += 1;
                return .{ .mac = e.mac, .state = .reachable };
            },
            .stale => {
                e.state = .delay;
                e.next_action_ms = now_ms + delay_ms;
                self.stats.hits += 1;
                return .{ .mac = e.mac, .state = .stale };
            },
            .delay, .probe => {
                self.stats.hits += 1;
                return .{ .mac = e.mac, .state = e.state };
            },
            .free => unreachable,
        }
    }

    /// 发起解析。已存在任何状态都返回 true（"已经在处理了"）。
    /// 否则建一个 `incomplete` 条目并让它立刻到期，由 `poll` 发出第一个请求。
    pub fn resolve(self: *Cache, ip: inet.Addr, now_ms: u32) bool {
        if (self.find(ip)) |i| {
            const e = &self.entries[i];
            if (e.state == .incomplete and e.next_action_ms > now_ms) return true;
            return true;
        }
        const i = self.alloc();
        self.entries[i] = .{
            .state = .incomplete,
            .ip = ip,
            .updated_ms = now_ms,
            .next_action_ms = now_ms,
        };
        self.stats.inserts += 1;
        return false;
    }

    /// 学到/刷新一条映射（收到 reply，或从对方的 request 里捎带学习）。
    /// 这是状态机里唯一能进入 `reachable` 的入口。
    pub fn learn(self: *Cache, ip: inet.Addr, mac: Mac, now_ms: u32) void {
        const i = if (self.find(ip)) |idx| idx else blk: {
            self.stats.inserts += 1;
            break :blk self.alloc();
        };
        self.entries[i] = .{
            .state = .reachable,
            .ip = ip,
            .mac = mac,
            .updated_ms = now_ms,
            .next_action_ms = now_ms + reachable_ms,
            .probes = 0,
        };
        self.stats.learns += 1;
    }

    /// 上层怀疑映射失效（例如 TCP 连续重传失败）时主动降级。
    pub fn markStale(self: *Cache, ip: inet.Addr, now_ms: u32) void {
        if (self.find(ip)) |i| {
            const e = &self.entries[i];
            if (e.state == .reachable) {
                e.state = .stale;
                e.updated_ms = now_ms;
            }
        }
    }

    /// 推进时间并收集"该发出去的 ARP 请求/探测"。返回写入 `out` 的条数。
    ///
    /// 这是整个模块里唯一需要被 tick 驱动的函数：没有它，`incomplete`
    /// 会永远停在"等应答"，`stale` 永远不会被复核。
    pub fn poll(self: *Cache, now_ms: u32, out: []Action) usize {
        var n: usize = 0;
        for (&self.entries) |*e| {
            if (e.state == .free or e.next_action_ms > now_ms) continue;
            switch (e.state) {
                .incomplete => {
                    if (e.probes >= max_probes) {
                        e.state = .free;
                        self.stats.failures += 1;
                        continue;
                    }
                    if (n < out.len) {
                        out[n] = .{ .kind = .request, .target = e.ip };
                        n += 1;
                    }
                    e.probes += 1;
                    e.next_action_ms = now_ms + retransmit_ms;
                    self.stats.requests += 1;
                },
                .delay => {
                    // delay 到期：先发一个探测，进入 probe 态。
                    if (n < out.len) {
                        out[n] = .{ .kind = .probe, .target = e.ip };
                        n += 1;
                    }
                    e.state = .probe;
                    e.probes = 1;
                    e.next_action_ms = now_ms + probe_interval_ms;
                    self.stats.probes += 1;
                },
                .probe => {
                    if (e.probes >= max_probes) {
                        e.state = .free;
                        self.stats.failures += 1;
                        continue;
                    }
                    if (n < out.len) {
                        out[n] = .{ .kind = .probe, .target = e.ip };
                        n += 1;
                    }
                    e.probes += 1;
                    e.next_action_ms = now_ms + probe_interval_ms;
                    self.stats.probes += 1;
                },
                else => {},
            }
        }
        return n;
    }

    /// 老化：`reachable` 超时降为 `stale`；`stale` 无人使用超时后回收。
    /// 返回被改变的条目数。
    pub fn expire(self: *Cache, now_ms: u32) usize {
        var n: usize = 0;
        for (&self.entries) |*e| {
            switch (e.state) {
                .reachable => {
                    if (now_ms -% e.updated_ms >= reachable_ms) {
                        e.state = .stale;
                        e.updated_ms = now_ms;
                        n += 1;
                    }
                },
                .stale => {
                    if (now_ms -% e.updated_ms >= stale_gc_ms) {
                        e.state = .free;
                        self.stats.expired += 1;
                        n += 1;
                    }
                },
                else => {},
            }
        }
        return n;
    }

    /// 诊断：读取某个 IP 的当前状态（不改状态机）。
    pub fn stateOf(self: *const Cache, ip: inet.Addr) State {
        for (self.entries) |e| {
            if (e.state != .free and inet.eql(e.ip, ip)) return e.state;
        }
        return .free;
    }

    pub fn count(self: *const Cache) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (e.state != .free) n += 1;
        }
        return n;
    }
};

/// 收到一个 ARP 报文后的处理结果。
pub const Incoming = struct {
    /// 是否把发送方的 (IP, MAC) 写进了缓存。
    learned: bool,
    /// 写进 `out` 的应答字节数；0 表示不需要回应。
    replied: usize,
};

/// 处理一个以太网载荷（28 字节 ARP 报文）：
///
///   1. `sender IP/MAC` 一律学习——除非 `sender IP` 是 `0.0.0.0`
///      （地址探测，RFC 5227 §2.1.1 明确要求不能学习）；
///   2. 如果 op=request 且 `target IP` 是本机，构造 reply 写进 `out`；
///   3. op=reply 只需学习，不回。
///
/// 广播/多播判定、VLAN 剥离、以太网首部都在调用方（ch17 的收包路径）完成。
pub fn receive(
    cache: *Cache,
    frame: []const u8,
    local_ip: inet.Addr,
    local_mac: Mac,
    now_ms: u32,
    out: []u8,
) Error!Incoming {
    const p = try Packet.parse(frame);
    var learned = false;
    if (!inet.eql(p.spa, inet.any)) {
        cache.learn(p.spa, p.sha, now_ms);
        learned = true;
    }

    var replied: usize = 0;
    if (p.op == Op.request and inet.eql(p.tpa, local_ip)) {
        const reply = Packet{
            .op = Op.reply,
            .sha = local_mac,
            .spa = local_ip,
            .tha = p.sha,
            .tpa = p.spa,
        };
        const bytes = try reply.write(out);
        replied = bytes.len;
    }
    return .{ .learned = learned, .replied = replied };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn macOf(comptime text: []const u8) Mac {
    // 测试里只接受 xx:xx:xx:xx:xx:xx
    var out: Mac = @splat(0);
    var it = std.mem.splitScalar(u8, text, ':');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) out[i] = std.fmt.parseInt(u8, part, 16) catch 0;
    return out;
}

const peer_mac = Mac{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
const our_mac = Mac{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };

test "arp: 28 字节报文往返" {
    var buf: [packet_len]u8 = undefined;
    const p = Packet{
        .op = Op.request,
        .sha = peer_mac,
        .spa = try inet.parse("192.168.1.10"),
        .tha = @splat(0),
        .tpa = try inet.parse("192.168.1.1"),
    };
    const bytes = try p.write(&buf);
    try testing.expectEqual(@as(usize, 28), bytes.len);

    const back = try Packet.parse(bytes);
    try testing.expectEqual(Op.request, back.op);
    try testing.expectEqual(peer_mac, back.sha);
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 10 }, &back.spa);
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &back.tpa);
}

test "arp: 截断与非以太网/IPv4 组合被拒绝" {
    var buf: [packet_len]u8 = undefined;
    const p = Packet{ .op = Op.reply, .sha = peer_mac, .spa = try inet.parse("10.0.0.1") };
    _ = try p.write(&buf);
    try testing.expectError(error.Truncated, Packet.parse(buf[0..20]));

    buf[0] = 0;
    buf[1] = 6; // htype = 6（IEEE 802 网络）
    try testing.expectError(error.Unsupported, Packet.parse(&buf));

    buf[0] = 0;
    buf[1] = 1;
    buf[4] = 8; // hlen = 8（不是以太网）
    try testing.expectError(error.Unsupported, Packet.parse(&buf));
}

test "arp: MAC 格式化与广播判定" {
    var buf: [18]u8 = undefined;
    const text = try formatMac(peer_mac, &buf);
    try testing.expectEqualStrings("02:00:00:00:00:01", text);
    try testing.expect(isBroadcastMac(.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }));
    try testing.expect(!isBroadcastMac(peer_mac));
    try testing.expectEqual(peer_mac, macOf("02:00:00:00:00:01"));
}

test "arp: resolve 后由 poll 发出第一个请求，随后按 1 s 重发" {
    var c = Cache{};
    const ip = try inet.parse("192.168.1.1");
    try testing.expect(!c.resolve(ip, 0));
    try testing.expectEqual(@as(?Cache.Lookup, null), c.lookup(ip, 0));

    var acts: [4]Action = undefined;
    try testing.expectEqual(@as(usize, 1), c.poll(0, &acts));
    try testing.expectEqual(Action{ .kind = .request, .target = ip }, acts[0]);
    try testing.expectEqual(@as(usize, 0), c.poll(999, &acts));
    try testing.expectEqual(@as(usize, 1), c.poll(1_000, &acts));
    try testing.expectEqual(@as(u32, 2), c.stats.requests);
    try testing.expectEqual(State.incomplete, c.stateOf(ip));
}

test "arp: 三次请求无应答后放弃（failures 计数）" {
    var c = Cache{};
    const ip = try inet.parse("192.168.1.1");
    _ = c.resolve(ip, 0);
    var acts: [1]Action = undefined;
    var now: u32 = 0;
    var emitted: usize = 0;
    while (now < 10_000) : (now += 500) emitted += c.poll(now, &acts);
    try testing.expectEqual(Cache.max_probes, @as(u8, @intCast(emitted)));
    try testing.expectEqual(@as(u32, 1), c.stats.failures);
    try testing.expectEqual(State.free, c.stateOf(ip));
    try testing.expectEqual(@as(usize, 0), c.count());
}

test "arp: learn 之后 lookup 命中，且收到 reply 时不会重复发请求" {
    var c = Cache{};
    const ip = try inet.parse("192.168.1.10");
    _ = c.resolve(ip, 0);
    c.learn(ip, peer_mac, 10);

    const hit = c.lookup(ip, 20).?;
    try testing.expectEqual(peer_mac, hit.mac);
    try testing.expectEqual(State.reachable, hit.state);
    try testing.expectEqual(@as(u32, 1), c.stats.hits);
    try testing.expectEqual(@as(usize, 1), c.count());

    var acts: [1]Action = undefined;
    try testing.expectEqual(@as(usize, 0), c.poll(1_000, &acts));
}

test "arp: reachable 超时变 stale，lookup 把它推进到 delay" {
    var c = Cache{};
    const ip = try inet.parse("192.168.1.10");
    c.learn(ip, peer_mac, 0);
    try testing.expectEqual(@as(usize, 0), c.expire(Cache.reachable_ms - 1));
    try testing.expectEqual(@as(usize, 1), c.expire(Cache.reachable_ms));
    try testing.expectEqual(State.stale, c.stateOf(ip));

    const hit = c.lookup(ip, Cache.reachable_ms + 1).?;
    try testing.expectEqual(peer_mac, hit.mac);
    try testing.expectEqual(State.stale, hit.state);
    try testing.expectEqual(State.delay, c.stateOf(ip));
}

test "arp: delay 到期转 probe，probe 到期发单播探测" {
    var c = Cache{};
    const ip = try inet.parse("192.168.1.10");
    c.learn(ip, peer_mac, 0);
    _ = c.expire(Cache.reachable_ms);
    _ = c.lookup(ip, Cache.reachable_ms);

    var acts: [1]Action = undefined;
    const due = Cache.reachable_ms + Cache.delay_ms;
    try testing.expectEqual(@as(usize, 0), c.poll(due - 1, &acts));
    try testing.expectEqual(@as(usize, 1), c.poll(due, &acts));
    try testing.expectEqual(Action{ .kind = .probe, .target = ip }, acts[0]);
    try testing.expectEqual(State.probe, c.stateOf(ip));

    try testing.expectEqual(@as(usize, 1), c.poll(due + Cache.probe_interval_ms, &acts));
    try testing.expectEqual(@as(u32, 2), c.stats.probes);
}

test "arp: 探测三次无果后丢弃映射" {
    var c = Cache{};
    const ip = try inet.parse("192.168.1.10");
    c.learn(ip, peer_mac, 0);
    _ = c.expire(Cache.reachable_ms);
    _ = c.lookup(ip, Cache.reachable_ms);

    var acts: [1]Action = undefined;
    var now: u32 = Cache.reachable_ms + Cache.delay_ms;
    var n: usize = 0;
    while (now < Cache.reachable_ms + Cache.delay_ms + 10_000) : (now += 100) n += c.poll(now, &acts);
    try testing.expectEqual(@as(usize, 3), n); // delay→probe 那一次 + 两次重试
    try testing.expectEqual(State.free, c.stateOf(ip));
    try testing.expectEqual(@as(u32, 1), c.stats.failures);
}

test "arp: stale 长期无人使用后被回收" {
    var c = Cache{};
    const ip = try inet.parse("192.168.1.10");
    c.learn(ip, peer_mac, 0);
    _ = c.expire(Cache.reachable_ms);
    try testing.expectEqual(State.stale, c.stateOf(ip));
    try testing.expectEqual(@as(usize, 0), c.expire(Cache.reachable_ms + Cache.stale_gc_ms - 1));
    try testing.expectEqual(@as(usize, 1), c.expire(Cache.reachable_ms + Cache.stale_gc_ms));
    try testing.expectEqual(State.free, c.stateOf(ip));
}

test "arp: 收到问本机地址的请求 → 学习对方并回 reply" {
    var c = Cache{};
    const local_ip = try inet.parse("192.168.1.1");
    const peer_ip = try inet.parse("192.168.1.10");
    const req = Packet{
        .op = Op.request,
        .sha = peer_mac,
        .spa = peer_ip,
        .tha = @splat(0),
        .tpa = local_ip,
    };
    var frame: [packet_len]u8 = undefined;
    _ = try req.write(&frame);

    var out: [packet_len]u8 = undefined;
    const r = try receive(&c, &frame, local_ip, our_mac, 100, &out);
    try testing.expect(r.learned);
    try testing.expectEqual(@as(usize, 28), r.replied);

    const reply = try Packet.parse(out[0..r.replied]);
    try testing.expectEqual(Op.reply, reply.op);
    try testing.expectEqual(our_mac, reply.sha);
    try testing.expectEqual(local_ip, reply.spa);
    try testing.expectEqual(peer_mac, reply.tha);
    try testing.expectEqual(peer_ip, reply.tpa);

    try testing.expectEqual(peer_mac, c.lookup(peer_ip, 101).?.mac);
}

test "arp: 问别人地址的请求只学习、不回应" {
    var c = Cache{};
    const req = Packet{
        .op = Op.request,
        .sha = peer_mac,
        .spa = try inet.parse("192.168.1.10"),
        .tpa = try inet.parse("192.168.1.20"),
    };
    var frame: [packet_len]u8 = undefined;
    _ = try req.write(&frame);
    var out: [packet_len]u8 = undefined;
    const r = try receive(&c, &frame, try inet.parse("192.168.1.1"), our_mac, 0, &out);
    try testing.expect(r.learned);
    try testing.expectEqual(@as(usize, 0), r.replied);
}

test "arp: 收到 reply 直接进入 reachable" {
    var c = Cache{};
    const reply = Packet{
        .op = Op.reply,
        .sha = peer_mac,
        .spa = try inet.parse("192.168.1.10"),
        .tha = our_mac,
        .tpa = try inet.parse("192.168.1.1"),
    };
    var frame: [packet_len]u8 = undefined;
    _ = try reply.write(&frame);
    var out: [packet_len]u8 = undefined;
    const r = try receive(&c, &frame, try inet.parse("192.168.1.1"), our_mac, 5, &out);
    try testing.expectEqual(@as(usize, 0), r.replied);
    try testing.expectEqual(State.reachable, c.stateOf(try inet.parse("192.168.1.10")));
}

test "arp: sender IP 为 0.0.0.0 的地址探测不学习（RFC 5227）" {
    var c = Cache{};
    const probe = Packet{
        .op = Op.request,
        .sha = peer_mac,
        .spa = inet.any,
        .tha = @splat(0),
        .tpa = try inet.parse("192.168.1.10"),
    };
    var frame: [packet_len]u8 = undefined;
    _ = try probe.write(&frame);
    var out: [packet_len]u8 = undefined;
    const r = try receive(&c, &frame, try inet.parse("192.168.1.1"), our_mac, 0, &out);
    try testing.expect(!r.learned);
    try testing.expectEqual(@as(usize, 0), c.count());
}

test "arp: 缓存满了优先踢掉 stale，再踢 reachable" {
    var c = Cache{};
    var i: u8 = 0;
    while (i < Cache.capacity) : (i += 1) {
        const ip = inet.withLastOctet(try inet.parse("10.0.0.0"), i + 1);
        c.learn(ip, Mac{ 0x02, 0, 0, 0, 0, i + 1 }, i);
    }
    try testing.expectEqual(Cache.capacity, c.count());

    // 让第一个条目变 stale
    _ = c.expire(Cache.reachable_ms);
    try testing.expectEqual(State.stale, c.stateOf(try inet.parse("10.0.0.1")));

    const new_ip = try inet.parse("10.0.0.99");
    _ = c.resolve(new_ip, Cache.reachable_ms + 1);
    try testing.expectEqual(State.incomplete, c.stateOf(new_ip));
    try testing.expectEqual(State.free, c.stateOf(try inet.parse("10.0.0.1")));
    try testing.expectEqual(@as(u32, 1), c.stats.evicted);
}
