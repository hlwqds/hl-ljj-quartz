//! ch16-stack-architecture-zero-copy：pbuf 链、引用计数与所有权模型。
//!
//! 这个模块是整章的“内存宪法”。协议栈里所有跨层传递的报文都长这样：
//!
//!     ┌────────┐   ┌────────┐   ┌────────┐
//!     │ Pbuf   │──▶│ Pbuf   │──▶│ Pbuf   │   next 链
//!     │ len=42 │   │ len=8  │   │ len=512│   tot_len 递减
//!     │ ref=1  │   │ ref=1  │   │ ref=2  │   引用计数
//!     └────────┘   └────────┘   └────────┘
//!
//! 三条不变式（与 lwIP 的 `pbuf.h` 一致，见 16.3/16.4）：
//!
//!   1. `tot_len == len + (next ? next.tot_len : 0)`；
//!   2. `ref` 等于“指向这个 pbuf 的指针数量之和”（应用、协议栈、链上的 next）；
//!   3. `ref` 归零时**只能**归还给分配它的池，不能跨池释放。
//!
//! ## 为什么不用通用分配器
//!
//! 本章的池是编译期定容的（`Pool(node_cap, block_size)`）：每个 pbuf 占一个
//! 定长块，`alloc` 就是拿一块空闲块。这样做换来三件事：
//!
//!   - **可判定**：池耗尽是一个确定的错误（`error.NoSpace`），不是“内存抖动”；
//!   - **可测试**：主机侧不需要任何分配器语义，测试失败时 `inUse()` 一定是 0；
//!   - **可解释**：`PBUF_POOL` 在 lwIP 里就是这种“固定块 + 引用计数”的形态，
//!     而 `PBUF_REF` 那种“payload 指向别人的 buffer”在本章用 `kind = .ref`
//!     表达（同一块存储，但语义上不拥有 payload）。
//!
//! ## 零拷贝发生在哪
//!
//! 只有三个动作不复制字节：`alloc`（从池里切视图）、`eat`（把 payload 的起点
//! 往后推）、`reference`（ref += 1）。`toLinear` 是显式拷贝点，调用方必须
//! 说清楚“我为什么要一块连续内存”（典型原因：链路层 DMA 只接受连续缓冲）。
//!
//! 本模块不引用任何硬件头文件，`zig build test` 在主机上直接跑。

const std = @import("std");

/// pbuf 的分配来源。语义差异只影响“谁负责归还 payload”，不影响链与引用计数。
pub const Kind = enum {
    /// payload 与节点同块（池块），归池所有。
    pool,
    /// payload 指向别人的缓冲（DMA 环、常量、栈），池只归还节点本身。
    ref,
    /// payload 在 ROM/常量区，节点是“视图”。
    rom,
};

/// 一个 pbuf 节点。`payload` 是**当前视图**：长度恒等于 `len`，
/// `cap` 记录块的原始容量，`eat` 只会把视图往后推，不会改变 `cap`。
pub const Pbuf = struct {
    next: ?*Pbuf = null,
    payload: []u8,
    cap: usize,
    len: usize,
    tot_len: usize,
    ref: u16 = 1,
    kind: Kind = .pool,
};

pub const Error = error{
    /// 池已耗尽（固定容量的必然结果，不是 bug）。
    NoSpace,
    /// `eat`/`free` 遇到不是独占的节点。
    Shared,
    /// 链不变式被破坏（长度、环、跨池指针）。
    BadChain,
    NotFromPool,
    BadLength,
    BadTotLen,
    ZeroRef,
    Cycle,
};

/// 编译期定容的 pbuf 池。
///
/// `node_cap` 是节点数，`block_size` 是每个节点 payload 的最大字节数。
/// 池对象本身必须是静态的（全局或长生命周期栈帧）：`alloc` 返回的指针指向
/// 池内部的数组，池被按值复制后指针就悬空了。
pub fn Pool(comptime node_cap: usize, comptime block_size: usize) type {
    return struct {
        const Self = @This();

        pub const nodes = node_cap;
        pub const block = block_size;

        const Node = struct {
            pbuf: Pbuf = undefined,
            storage: [block_size]u8 = undefined,
        };

        pub const Stats = struct {
            allocs: u32 = 0,
            releases: u32 = 0,
            /// 池空导致的失败次数：判读“池够不够大”的唯一数字。
            exhausted: u32 = 0,
            /// 请求长度超过块大小导致的失败次数。这是调用方的编程错误，
            /// 与池大小无关，所以单独计数，不污染 exhausted。
            oversized: u32 = 0,
            /// toLinear 真正复制过几次。
            linearize_copies: u32 = 0,
            high_water: u32 = 0,
        };

        nodes_storage: [node_cap]Node = undefined,
        in_use: [node_cap]bool = @splat(false),
        stats: Stats = .{},

        pub fn init() Self {
            return .{};
        }

        /// 当前占用的节点数。
        pub fn inUse(self: *const Self) usize {
            var n: usize = 0;
            for (self.in_use) |used| {
                if (used) n += 1;
            }
            return n;
        }

        /// 是否还有空节点（输入路径在收包前用它做快速判断）。
        pub fn hasRoom(self: *const Self) bool {
            return self.inUse() < node_cap;
        }

        /// 切一块 `len` 字节的 payload 视图。`len > block` 直接失败，不截断。
        pub fn alloc(self: *Self, len: usize) Error!*Pbuf {
            if (len > block_size) {
                self.stats.oversized += 1;
                return error.NoSpace;
            }
            var i: usize = 0;
            while (i < node_cap) : (i += 1) {
                if (self.in_use[i]) continue;
                self.in_use[i] = true;
                const node = &self.nodes_storage[i];
                node.pbuf = .{
                    .next = null,
                    .payload = node.storage[0..len],
                    .cap = block_size,
                    .len = len,
                    .tot_len = len,
                    .ref = 1,
                    .kind = .pool,
                };
                self.stats.allocs += 1;
                const used: u32 = @intCast(self.inUse());
                if (used > self.stats.high_water) self.stats.high_water = used;
                return &node.pbuf;
            }
            self.stats.exhausted += 1;
            return error.NoSpace;
        }

        /// 按 `lens` 依次分配并串成链。失败时已分配的块全部归还，不留半条链。
        pub fn allocChain(self: *Self, lens: []const usize) Error!*Pbuf {
            if (lens.len == 0) return error.NoSpace;
            var head: ?*Pbuf = null;
            var tail: ?*Pbuf = null;
            var total: usize = 0;
            errdefer {
                if (head) |h| _ = self.free(h);
            }
            for (lens) |len| {
                const p = try self.alloc(len);
                if (head == null) {
                    head = p;
                } else {
                    tail.?.next = p;
                }
                tail = p;
                total += len;
            }
            // tot_len 只能从后往前算：链尾的 tot_len 是它自己的 len。
            var cur: ?*Pbuf = head;
            var rest = total;
            while (cur) |q| {
                q.tot_len = rest;
                rest -= q.len;
                cur = q.next;
            }
            return head.?;
        }

        /// 归还整条链：每个节点 ref -= 1，归零的节点回到池里。
        /// 返回真正释放的节点数。
        ///
        /// 注意：这是**整链**操作。若某个节点还有其他持有者（ref > 1），
        /// 它保持分配且 `next` 不动——这与 lwIP `pbuf_free` 的渐进语义一致，
        /// 但本实现不做“部分链断开”，调用方不应依赖半释放后的链结构。
        pub fn free(self: *Self, p: *Pbuf) u32 {
            var freed: u32 = 0;
            var cur: ?*Pbuf = p;
            while (cur) |q| {
                const nxt = q.next;
                if (q.ref <= 1) {
                    self.releaseNode(q);
                    freed += 1;
                } else {
                    q.ref -= 1;
                }
                cur = nxt;
            }
            return freed;
        }

        /// 把整条链复制进 `out`，返回实际写入的前缀。这是**显式拷贝点**。
        pub fn toLinear(self: *Self, p: *const Pbuf, out: []u8) Error![]const u8 {
            const need = p.tot_len;
            if (out.len < need) return error.NoSpace;
            var offset: usize = 0;
            var cur: ?*const Pbuf = p;
            while (cur) |q| {
                @memcpy(out[offset .. offset + q.len], q.payload);
                offset += q.len;
                cur = q.next;
            }
            if (need != 0) self.stats.linearize_copies += 1;
            return out[0..offset];
        }

        /// 零拷贝地“吃掉”链首的 `n` 字节，返回新的链头（可能为 null）。
        ///
        /// 这是收包路径剥首部的关键动作：IPv4 首部 20 字节、UDP 首部 8 字节，
        /// 全部通过移动 payload 视图完成，没有一次 `memcpy`。
        ///
        /// 被完全吃掉的节点必须独占（`ref == 1`）才能归还；有别的持有者时
        /// 返回 `error.Shared`——否则另一条链会突然指向池里的空闲块。
        pub fn eat(self: *Self, p: *Pbuf, n: usize) Error!?*Pbuf {
            const total = p.tot_len;
            if (n >= total) {
                var probe: ?*Pbuf = p;
                while (probe) |q| {
                    if (q.ref != 1) return error.Shared;
                    probe = q.next;
                }
                _ = self.free(p);
                return null;
            }

            var skip = n;
            var head: *Pbuf = p;
            while (skip >= head.len) {
                if (head.ref != 1) return error.Shared;
                const nxt = head.next orelse return null;
                skip -= head.len;
                self.releaseNode(head);
                head = nxt;
            }
            if (skip > 0) {
                head.payload = head.payload[skip..];
                head.len -= skip;
            }
            head.tot_len = total - n;
            return head;
        }

        /// 校验链不变式。测试与断言用；输入路径上不要每包都跑。
        pub fn check(self: *Self, p: *const Pbuf) Error!void {
            var cur: ?*const Pbuf = p;
            var guard: usize = 0;
            while (cur) |q| {
                guard += 1;
                if (guard > node_cap) return error.Cycle;
                if (!self.isLive(q)) return error.NotFromPool;
                if (q.ref == 0) return error.ZeroRef;
                if (q.len > q.cap or q.payload.len != q.len) return error.BadLength;

                // tot_len 必须等于“从本节点到链尾”的长度和。
                var sum: usize = 0;
                var inner: usize = 0;
                var it: ?*const Pbuf = q;
                while (it) |r| {
                    inner += 1;
                    if (inner > node_cap) return error.Cycle;
                    sum += r.len;
                    it = r.next;
                }
                if (sum != q.tot_len) return error.BadTotLen;
                cur = q.next;
            }
        }

        fn isLive(self: *const Self, p: *const Pbuf) bool {
            for (0..node_cap) |i| {
                if (!self.in_use[i]) continue;
                if (&self.nodes_storage[i].pbuf == p) return true;
            }
            return false;
        }

        fn releaseNode(self: *Self, p: *Pbuf) void {
            for (0..node_cap) |i| {
                if (!self.in_use[i]) continue;
                const node = &self.nodes_storage[i];
                if (&node.pbuf != p) continue;
                self.in_use[i] = false;
                node.pbuf = .{
                    .next = null,
                    .payload = node.storage[0..0],
                    .cap = block_size,
                    .len = 0,
                    .tot_len = 0,
                    .ref = 0,
                    .kind = .pool,
                };
                self.stats.releases += 1;
                return;
            }
        }
    };
}

/// 整链加一次引用（ref += 1），返回链头。
/// 这是“零拷贝地共享同一块报文”的唯一合法方式：谁要长期持有就 reference，
/// 不要 `toLinear` 出第二份。
pub fn reference(p: *Pbuf) *Pbuf {
    var cur: ?*Pbuf = p;
    while (cur) |q| {
        if (q.ref < std.math.maxInt(u16)) q.ref += 1;
        cur = q.next;
    }
    return p;
}

/// 把链当作**一段连续的字节流**遍历，不复制。
/// 校验和、TAP 抓包、调试打印都走这个迭代器。
pub const SliceIter = struct {
    cur: ?*const Pbuf,

    pub fn init(p: *const Pbuf) SliceIter {
        return .{ .cur = p };
    }

    pub fn next(self: *SliceIter) ?[]const u8 {
        const q = self.cur orelse return null;
        self.cur = q.next;
        return q.payload;
    }
};

// ---------------------------------------------------------------------------
// 测试：全部在主机侧跑，不需要分配器，也不碰硬件。
// ---------------------------------------------------------------------------

const testing = std.testing;

test "alloc: 单块 pbuf 的 len/tot_len/ref 与视图容量" {
    var pool: Pool(4, 32) = .{};

    const p = try pool.alloc(10);
    try testing.expectEqual(@as(usize, 10), p.len);
    try testing.expectEqual(@as(usize, 10), p.tot_len);
    try testing.expectEqual(@as(usize, 32), p.cap);
    try testing.expectEqual(@as(u16, 1), p.ref);
    try testing.expect(p.next == null);
    try pool.check(p);
    try testing.expectEqual(@as(usize, 1), pool.inUse());
    _ = pool.free(p);
    try testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "alloc: 超长请求返回 NoSpace，不截断、不消耗节点、不计入 exhausted" {
    var pool: Pool(2, 16) = .{};
    try testing.expectError(error.NoSpace, pool.alloc(17));
    try testing.expectEqual(@as(usize, 0), pool.inUse());
    // 池里还有 2 个空节点，所以这不是“池耗尽”，而是请求本身非法。
    try testing.expectEqual(@as(u32, 0), pool.stats.exhausted);
    try testing.expectEqual(@as(u32, 1), pool.stats.oversized);
}

test "allocChain: tot_len 从链尾往前累加" {
    var pool: Pool(8, 64) = .{};
    const chain = try pool.allocChain(&.{ 14, 20, 8, 4 });
    defer _ = pool.free(chain);

    try testing.expectEqual(@as(usize, 46), chain.tot_len);
    const ip = chain.next.?;
    const udp = ip.next.?;
    const payload = udp.next.?;

    try testing.expectEqual(@as(usize, 14), chain.len);
    try testing.expectEqual(@as(usize, 46), chain.tot_len);
    try testing.expectEqual(@as(usize, 32), ip.tot_len);
    try testing.expectEqual(@as(usize, 12), udp.tot_len);
    try testing.expectEqual(@as(usize, 4), payload.tot_len);
    try pool.check(chain);
}

test "allocChain: 中途失败会把已分配节点全部归还" {
    // 3 个节点装 4 段：第 4 段必然失败。
    var pool: Pool(3, 16) = .{};
    try testing.expectError(error.NoSpace, pool.allocChain(&.{ 1, 1, 1, 1 }));
    try testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "reference: ref=2 时一次 free 只减引用，节点仍在" {
    var pool: Pool(4, 32) = .{};
    const p = try pool.alloc(8);
    p.payload[0] = 0xAA;

    _ = reference(p);
    try testing.expectEqual(@as(u16, 2), p.ref);

    try testing.expectEqual(@as(u32, 0), pool.free(p));
    try testing.expectEqual(@as(usize, 1), pool.inUse());
    try testing.expectEqual(@as(u16, 1), p.ref);
    try testing.expectEqual(@as(u8, 0xAA), p.payload[0]);

    try testing.expectEqual(@as(u32, 1), pool.free(p));
    try testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "reference: 整链加引用，free 两次才全部归还" {
    var pool: Pool(4, 32) = .{};
    const chain = try pool.allocChain(&.{ 4, 4 });
    defer _ = pool.free(chain);

    _ = reference(chain);
    try testing.expectEqual(@as(u16, 2), chain.ref);
    try testing.expectEqual(@as(u16, 2), chain.next.?.ref);
    try testing.expectEqual(@as(u32, 0), pool.free(chain));
    try testing.expectEqual(@as(usize, 2), pool.inUse());
    try testing.expectEqual(@as(usize, 2), pool.free(chain));
    try testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "eat: 剥掉 14 字节以太网首部，payload 是原存储的视图" {
    var pool: Pool(4, 64) = .{};
    const frame = try pool.allocChain(&.{ 14, 20, 8 });

    for (frame.payload, 0..) |*b, i| b.* = @intCast(i);
    for (frame.next.?.payload, 0..) |*b, i| b.* = @intCast(100 + i);
    for (frame.next.?.next.?.payload, 0..) |*b, i| b.* = @intCast(200 + i);

    const ip = try pool.eat(frame, 14);
    const head = ip.?;
    try testing.expectEqual(@as(usize, 28), head.tot_len);
    try testing.expectEqual(@as(usize, 20), head.len);
    try testing.expectEqual(@as(u8, 100), head.payload[0]);
    try pool.check(head);

    const udp = try pool.eat(head, 20);
    try testing.expectEqual(@as(usize, 8), udp.?.tot_len);
    try testing.expectEqual(@as(u8, 200), udp.?.payload[0]);
    _ = pool.free(udp.?);
    try testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "eat: 跨块剥首部（首部被拆在两个 pbuf 里）" {
    var pool: Pool(4, 32) = .{};
    const chain = try pool.allocChain(&.{ 10, 10, 8 });
    defer _ = pool.free(chain);

    for (chain.payload, 0..) |*b, i| b.* = @intCast(i);
    for (chain.next.?.payload, 0..) |*b, i| b.* = @intCast(10 + i);
    for (chain.next.?.next.?.payload, 0..) |*b, i| b.* = @intCast(20 + i);

    const rest = (try pool.eat(chain, 14)).?;
    try testing.expectEqual(@as(usize, 14), rest.tot_len);
    try testing.expectEqual(@as(usize, 6), rest.len); // 第一块剩 6 字节
    try testing.expectEqual(@as(u8, 14), rest.payload[0]);
    try testing.expectEqual(@as(u8, 20), rest.next.?.payload[0]);
    try pool.check(rest);
    _ = pool.free(rest);
}

test "eat: 吃满整条链返回 null 并把节点全部归还" {
    var pool: Pool(4, 32) = .{};
    const chain = try pool.allocChain(&.{ 4, 6 });
    const rest = try pool.eat(chain, 10);
    try testing.expect(rest == null);
    try testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "eat: 被共享的节点不能归还（error.Shared）" {
    var pool: Pool(4, 32) = .{};
    const chain = try pool.allocChain(&.{ 4, 6 });
    _ = reference(chain);
    try testing.expectError(error.Shared, pool.eat(chain, 10));
    // 一次 free 只降引用，链依然完整。
    try testing.expectEqual(@as(u32, 0), pool.free(chain));
    try testing.expectEqual(@as(usize, 2), pool.inUse());
    _ = pool.free(chain);
    try testing.expectEqual(@as(usize, 0), pool.inUse());
}

test "toLinear: 链被还原成连续字节，且计数一次拷贝" {
    var pool: Pool(4, 32) = .{};
    const chain = try pool.allocChain(&.{ 3, 2 });
    defer _ = pool.free(chain);
    chain.payload[0..3].* = .{ 1, 2, 3 };
    chain.next.?.payload[0..2].* = .{ 4, 5 };

    var out: [8]u8 = undefined;
    const flat = try pool.toLinear(chain, &out);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, flat);
    try testing.expectEqual(@as(u32, 1), pool.stats.linearize_copies);

    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, pool.toLinear(chain, &tiny));
}

test "SliceIter: 按链序产出 payload，不复制" {
    var pool: Pool(4, 32) = .{};
    const chain = try pool.allocChain(&.{ 2, 3 });
    defer _ = pool.free(chain);

    var it = SliceIter.init(chain);
    const first = it.next().?;
    const second = it.next().?;
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqual(@as(usize, 3), second.len);
    try testing.expect(@intFromPtr(first.ptr) == @intFromPtr(chain.payload.ptr));
}

test "check: 手工破坏 tot_len 会被发现" {
    var pool: Pool(2, 16) = .{};
    const p = try pool.alloc(8);
    defer _ = pool.free(p);
    p.tot_len = 9;
    try testing.expectError(error.BadTotLen, pool.check(p));
}

test "stats: high_water 记录峰值占用" {
    var pool: Pool(4, 16) = .{};
    const a = try pool.alloc(1);
    const b = try pool.alloc(1);
    const c = try pool.alloc(1);
    try testing.expectEqual(@as(u32, 3), pool.stats.high_water);
    _ = pool.free(a);
    _ = pool.free(b);
    _ = pool.free(c);
    try testing.expectEqual(@as(u32, 3), pool.stats.high_water);
    try testing.expect(pool.hasRoom());
}
