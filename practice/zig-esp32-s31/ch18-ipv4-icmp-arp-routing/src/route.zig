//! ch18-ipv4-icmp-arp-routing：路由表与最长前缀匹配（LPM）。
//!
//! 一个 IPv4 主机的转发决策只有三步：
//!
//!   1. 在路由表里找**前缀最长**的匹配项（最长前缀匹配）；
//!   2. 有网关 → 下一跳是网关，ARP 解析网关的 MAC；
//!      无网关（connected 路由）→ 下一跳就是目的地址本身，ARP 解析目的地址；
//!   3. 查不到 → 没有路由，回 `ICMP net unreachable`，不要"猜一个默认网关"。
//!
//! ## 为什么这章用线性扫描而不是 trie
//!
//! 主机路由表只有几条到几十条（connected + 默认路由 + 少量静态路由）。
//! 对 16 条表项做 16 次「掩码比较」比维护一棵 multibit trie 更简单、
//! 更容易证明正确，而且**表项数变化时不需要重建**。路由器有几十万条前缀，
//! 才需要 trie/TCAM——那是另一个量级的问题（见 18.8 的边界）。
//!
//! ## 两个经典 bug，都在 `add` 里被挡掉
//!
//! 1. **主机位不为 0**：加 `192.168.1.10/24` 而不是 `192.168.1.0/24`。
//!    线性扫描用掩码比较其实也能匹配，但"表里存着带主机位的网络号"会让
//!    打印、去重、与 `ip route` 的输出对不上。这里直接返回 `error.HostBits`。
//! 2. **相同前缀不同 metric**：`add` 允许重复添加同一 (dst,prefix) 并覆盖，
//!    而不是留下两条互相遮蔽的表项——否则"到底走了哪条"取决于插入顺序。

const std = @import("std");
const inet = @import("inet.zig");

/// 网络接口索引。本章只有一块网卡，但接口是路由表的一等字段：
/// 多网口时"从哪个口出去"与"下一跳是谁"同等重要。
pub const Iface = u8;
pub const eth0: Iface = 0;

pub const Error = error{
    TableFull,
    BadPrefix,
    HostBits,
};

pub const Route = struct {
    /// 网络地址（主机位必须为 0）。
    dst: inet.Addr,
    prefix: u8,
    /// null = connected（on-link）；非 null = 经网关。
    gateway: ?inet.Addr = null,
    iface: Iface = eth0,
    /// 数值越小优先级越高。相同前缀时用它决胜。
    metric: u16 = 0,
};

pub const NextHop = struct {
    /// 真正要做 ARP 的地址：on-link 时是目的地址，否则是网关。
    via: inet.Addr,
    iface: Iface,
    on_link: bool,
    /// 命中的那条路由的前缀长度（判读用）。
    prefix: u8,
    gateway: ?inet.Addr,
};

pub const Table = struct {
    pub const capacity = 16;

    routes: [capacity]?Route = @splat(null),
    count: usize = 0,

    /// 添加一条路由。相同 `(dst, prefix)` 的旧表项被**替换**（含 iface 变化）。
    /// 检查：前缀 ≤ 32；网络号必须没有主机位。
    pub fn add(self: *Table, r: Route) Error!void {
        if (r.prefix > 32) return error.BadPrefix;
        const net = inet.network(r.dst, r.prefix) catch return error.BadPrefix;
        if (!inet.eql(net, r.dst)) return error.HostBits;

        for (&self.routes) |*slot| {
            if (slot.*) |existing| {
                if (existing.prefix == r.prefix and inet.eql(existing.dst, r.dst)) {
                    slot.* = r;
                    return;
                }
            }
        }
        for (&self.routes) |*slot| {
            if (slot.* == null) {
                slot.* = r;
                self.count += 1;
                return;
            }
        }
        return error.TableFull;
    }

    pub fn remove(self: *Table, dst: inet.Addr, prefix: u8) bool {
        for (&self.routes) |*slot| {
            if (slot.*) |existing| {
                if (existing.prefix == prefix and inet.eql(existing.dst, dst)) {
                    slot.* = null;
                    self.count -= 1;
                    return true;
                }
            }
        }
        return false;
    }

    /// 最长前缀匹配。同前缀时取 metric 更小的；metric 也相同则取先插入的
    /// （数组顺序稳定，结果可复现）。
    pub fn lookupRoute(self: *const Table, dst: inet.Addr) ?Route {
        var best: ?Route = null;
        for (self.routes) |maybe| {
            const r = maybe orelse continue;
            if (!inet.inPrefix(r.dst, r.prefix, dst)) continue;
            if (best) |b| {
                if (r.prefix < b.prefix) continue;
                if (r.prefix == b.prefix and r.metric >= b.metric) continue;
            }
            best = r;
        }
        return best;
    }

    pub fn lookup(self: *const Table, dst: inet.Addr) ?NextHop {
        const r = self.lookupRoute(dst) orelse return null;
        if (r.gateway) |gw| {
            return .{
                .via = gw,
                .iface = r.iface,
                .on_link = false,
                .prefix = r.prefix,
                .gateway = gw,
            };
        }
        return .{
            .via = dst,
            .iface = r.iface,
            .on_link = true,
            .prefix = r.prefix,
            .gateway = null,
        };
    }

    pub fn clear(self: *Table) void {
        for (&self.routes) |*slot| slot.* = null;
        self.count = 0;
    }

    /// 是否有一条"目的网段直连"的路由。DHCP 之后判断"默认网关是否 on-link"
    /// 用的就是它。
    pub fn hasConnected(self: *const Table, addr: inet.Addr) bool {
        for (self.routes) |maybe| {
            const r = maybe orelse continue;
            if (r.gateway == null and inet.inPrefix(r.dst, r.prefix, addr)) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn ip(comptime text: []const u8) inet.Addr {
    return inet.parse(text) catch unreachable;
}

fn basicTable() !Table {
    var t = Table{};
    try t.add(.{ .dst = ip("192.168.1.0"), .prefix = 24 }); // connected
    try t.add(.{ .dst = ip("0.0.0.0"), .prefix = 0, .gateway = ip("192.168.1.1") });
    return t;
}

test "route: 直连路由命中后 on-link，ARP 目标是目的地址本身" {
    const t = try basicTable();
    const nh = t.lookup(ip("192.168.1.20")).?;
    try testing.expect(nh.on_link);
    try testing.expectEqualSlices(u8, &ip("192.168.1.20"), &nh.via);
    try testing.expectEqual(@as(u8, 24), nh.prefix);
}

test "route: 非直连走默认网关，ARP 目标是网关" {
    const t = try basicTable();
    const nh = t.lookup(ip("8.8.8.8")).?;
    try testing.expect(!nh.on_link);
    try testing.expectEqualSlices(u8, &ip("192.168.1.1"), &nh.via);
    try testing.expectEqual(@as(u8, 0), nh.prefix);
}

test "route: 最长前缀匹配：/32 > /24 > /16 > /0" {
    var t = Table{};
    try t.add(.{ .dst = ip("0.0.0.0"), .prefix = 0, .gateway = ip("10.0.0.1") });
    try t.add(.{ .dst = ip("10.0.0.0"), .prefix = 8, .gateway = ip("10.0.0.2") });
    try t.add(.{ .dst = ip("10.1.0.0"), .prefix = 16, .gateway = ip("10.0.0.3") });
    try t.add(.{ .dst = ip("10.1.2.3"), .prefix = 32 });

    try testing.expectEqual(@as(u8, 32), t.lookup(ip("10.1.2.3")).?.prefix);
    try testing.expectEqual(@as(u8, 16), t.lookup(ip("10.1.9.9")).?.prefix);
    try testing.expectEqual(@as(u8, 8), t.lookup(ip("10.9.9.9")).?.prefix);
    try testing.expectEqual(@as(u8, 0), t.lookup(ip("11.0.0.1")).?.prefix);
}

test "route: 插入顺序不影响 LPM 结果" {
    var a = Table{};
    try a.add(.{ .dst = ip("10.1.0.0"), .prefix = 16, .gateway = ip("192.0.2.1") });
    try a.add(.{ .dst = ip("0.0.0.0"), .prefix = 0, .gateway = ip("192.0.2.2") });

    var b = Table{};
    try b.add(.{ .dst = ip("0.0.0.0"), .prefix = 0, .gateway = ip("192.0.2.2") });
    try b.add(.{ .dst = ip("10.1.0.0"), .prefix = 16, .gateway = ip("192.0.2.1") });

    try testing.expectEqualSlices(u8, &ip("192.0.2.1"), &a.lookup(ip("10.1.5.5")).?.via);
    try testing.expectEqualSlices(u8, &ip("192.0.2.1"), &b.lookup(ip("10.1.5.5")).?.via);
}

test "route: 同前缀按 metric 决胜，metric 相同取先插入的" {
    var t = Table{};
    try t.add(.{ .dst = ip("172.16.0.0"), .prefix = 12, .gateway = ip("192.0.2.9"), .metric = 20 });
    try t.add(.{ .dst = ip("172.16.0.0"), .prefix = 12, .gateway = ip("192.0.2.1"), .metric = 5 });
    try testing.expectEqualSlices(u8, &ip("192.0.2.1"), &t.lookup(ip("172.16.1.1")).?.via);

    // 相同 (dst,prefix) 再 add 是替换，不是新增
    try testing.expectEqual(@as(usize, 1), t.count);
    try t.add(.{ .dst = ip("172.16.0.0"), .prefix = 12, .gateway = ip("192.0.2.2"), .metric = 1 });
    try testing.expectEqual(@as(usize, 1), t.count);
    try testing.expectEqualSlices(u8, &ip("192.0.2.2"), &t.lookup(ip("172.16.1.1")).?.via);
}

test "route: 没有匹配时不返回任何下一跳（不要猜默认网关）" {
    var t = Table{};
    try t.add(.{ .dst = ip("192.168.1.0"), .prefix = 24 });
    try testing.expect(t.lookup(ip("8.8.8.8")) == null);
}

test "route: 前缀边界严格（10/8 不匹配 11.x，172.16/12 不匹配 172.32）" {
    var t = Table{};
    try t.add(.{ .dst = ip("10.0.0.0"), .prefix = 8 });
    try t.add(.{ .dst = ip("172.16.0.0"), .prefix = 12 });
    try testing.expect(t.lookup(ip("11.0.0.1")) == null);
    try testing.expect(t.lookup(ip("172.32.0.1")) == null);
    try testing.expect(t.lookup(ip("172.31.255.254")) != null);
}

test "route: 带主机位的网络号被拒绝" {
    var t = Table{};
    try testing.expectError(error.HostBits, t.add(.{ .dst = ip("192.168.1.10"), .prefix = 24 }));
    try testing.expectError(error.BadPrefix, t.add(.{ .dst = ip("192.168.1.0"), .prefix = 33 }));
    try testing.expectEqual(@as(usize, 0), t.count);
}

test "route: 表满返回 TableFull，删除后可复用" {
    var t = Table{};
    var i: u16 = 0;
    while (i < Table.capacity) : (i += 1) {
        const dst = inet.Addr{ 10, @intCast(i), 0, 0 };
        try t.add(.{ .dst = dst, .prefix = 16 });
    }
    try testing.expectError(error.TableFull, t.add(.{ .dst = ip("192.168.0.0"), .prefix = 16 }));

    try testing.expect(t.remove(.{ 10, 3, 0, 0 }, 16));
    try testing.expect(!t.remove(.{ 10, 3, 0, 0 }, 16));
    try t.add(.{ .dst = ip("192.168.0.0"), .prefix = 16 });
    try testing.expectEqual(Table.capacity, t.count);
}

test "route: 默认路由与 connected 判定（DHCP 后检查网关是否 on-link）" {
    const t = try basicTable();
    try testing.expect(t.hasConnected(ip("192.168.1.77")));
    try testing.expect(!t.hasConnected(ip("8.8.8.8")));

    var t2 = Table{};
    try t2.add(.{ .dst = ip("0.0.0.0"), .prefix = 0, .gateway = ip("10.0.0.1") });
    try testing.expect(!t2.hasConnected(ip("10.0.0.1")));
    try testing.expectEqual(@as(usize, 1), t2.count);
}

test "route: clear 清空表" {
    var t = try basicTable();
    try testing.expectEqual(@as(usize, 2), t.count);
    t.clear();
    try testing.expectEqual(@as(usize, 0), t.count);
    try testing.expect(t.lookup(ip("192.168.1.1")) == null);
}
