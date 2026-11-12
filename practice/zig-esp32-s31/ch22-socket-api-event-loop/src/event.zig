//! ch22-socket-api-event-loop：事件循环（poll 语义 + 超时轮 + 连接池）。
//!
//! 这一层只有一个问题要回答：**应用怎么在单线程里同时等 N 个 fd。**
//! 三个部件，全部由显式 tick 驱动（本章 `mstatus.MIE = 0`，没有任何时钟
//! 中断，见章节 22.5）：
//!
//!   1. `poll()`  —— 一次调用 = 一个 tick：扫一遍注册表，把“现在能读/能写”
//!      的 fd 填进就绪集。**水平触发**（level-triggered）：只要条件仍成立，
//!      下个 tick 还会报告它。所以应用必须自己把条件消掉（读走数据、
//!      写完缓冲），否则会一直拿到同一个 fd。
//!   2. `Wheel`   —— 相对 tick 的超时轮。不读时钟，`advance(now)` 的 `now`
//!      由调用方给；自检里传常数，因此**不需要真的等**。
//!   3. `Pool`    —— 已接受连接的上限（4 条）与满时策略：
//!      `.reject_new`（拒绝新连接，计数 `rejected`）或
//!      `.evict_oldest`（踢掉 `accept_token` 最小的那条，计数 `evicted`）。
//!      默认拒绝：在固定槽位的设备上，悄悄关掉一条活连接比拒绝新连接更糟。
//!
//! 公平性：`poll()` 的扫描起点每 tick 前进一格（`start = (start+1) % n`）。
//! 就绪项超过一次处理的预算时，队首会在若干个 tick 内轮转，没有 fd 能被
//! 永久饿死。判据在自检 ⑨：两个常驻可读的 fd，8 个 tick 内每个都至少当过
//! 一次队首。
//!
//! 与 `socket.zig` 的分工：`socket.zig` 定义“就绪是什么”（`readable()` /
//! `writable()`），本模块只负责“扫谁、按什么顺序扫、扫完给谁”。改语义时
//! 两边必须一起看。

const std = @import("std");
const socket = @import("socket.zig");

/// 一次 poll 最多返回多少就绪项。板侧是一次 tick 的处理预算：
/// 超出就截断（`truncated` 计数），剩下的下个 tick 再来——
/// 这也正是“轮转起点必须前进”的原因。
pub const poll_cap: usize = 4;
/// 超时轮槽位数。
pub const max_timers: usize = 8;
/// 连接池上限。
pub const pool_cap: usize = 4;

/// 关注的事件集合 / 就绪结果。两个方向共用同一个类型：
/// 注册时是“我想知道什么”，返回时是“现在实际成立什么”。
pub const Mask = struct {
    read: bool = false,
    write: bool = false,
    /// 对端已关闭或 fd 已失效：应用应当把这条连接收掉。
    hup: bool = false,

    pub fn any(self: Mask) bool {
        return self.read or self.write or self.hup;
    }
};

pub const PollFd = struct {
    fd: u8,
    events: Mask = .{ .read = true },
};

pub const Ready = struct {
    fd: u8,
    mask: Mask,
};

/// 一次 `poll()` 的返回值。定长，不分配。
pub const ReadySet = struct {
    items: [poll_cap]Ready = @splat(Ready{ .fd = 0, .mask = .{} }),
    len: usize = 0,

    pub fn reset(self: *ReadySet) void {
        self.len = 0;
    }

    pub fn find(self: *const ReadySet, fd: u8) ?usize {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.items[i].fd == fd) return i;
        }
        return null;
    }

    pub fn hasRead(self: *const ReadySet, fd: u8) bool {
        const i = self.find(fd) orelse return false;
        return self.items[i].mask.read;
    }

    pub fn hasWrite(self: *const ReadySet, fd: u8) bool {
        const i = self.find(fd) orelse return false;
        return self.items[i].mask.write;
    }

    /// 队首 fd（没有就绪项时返回 null）。公平性判据只看这个。
    pub fn head(self: *const ReadySet) ?u8 {
        if (self.len == 0) return null;
        return self.items[0].fd;
    }
};

/// 超时种类。板侧只用前两个，`connect_timeout` 留着给 ch23 的握手超时。
pub const TimerKind = enum(u8) {
    retransmit = 1,
    idle_close = 2,
    connect_timeout = 3,

    pub fn name(self: TimerKind) []const u8 {
        return @tagName(self);
    }
};

pub const Timer = struct {
    /// 绝对到期 tick（`now >= deadline` 即到期）。无符号，不做环绕。
    deadline: u64,
    fd: u8,
    kind: TimerKind,
};

/// 相对 tick 的超时轮。插入/取消都是线性扫描——槽位只有 8 个，
/// 有序链表在这里是负优化（更别说它需要分配）。
pub const Wheel = struct {
    slots: [max_timers]Timer = undefined,
    len: usize = 0,
    fired: u32 = 0,
    refused: u32 = 0,

    pub fn reset(self: *Wheel) void {
        self.len = 0;
        self.fired = 0;
        self.refused = 0;
    }

    pub fn insert(self: *Wheel, t: Timer) bool {
        if (self.len >= max_timers) {
            self.refused += 1;
            return false;
        }
        self.slots[self.len] = t;
        self.len += 1;
        return true;
    }

    pub fn cancel(self: *Wheel, fd: u8, kind: TimerKind) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.slots[i].fd == fd and self.slots[i].kind == kind) {
                var j = i;
                while (j + 1 < self.len) : (j += 1) {
                    self.slots[j] = self.slots[j + 1];
                }
                self.len -= 1;
                return true;
            }
        }
        return false;
    }

    /// 取出所有 `deadline <= now` 的定时器，按插入顺序写进 `out`。
    /// 返回条数；`out` 不够长时多余的留在轮里（下次还会到期）。
    pub fn advance(self: *Wheel, now: u64, out: []Timer) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.len) {
            const t = self.slots[i];
            if (t.deadline <= now and n < out.len) {
                out[n] = t;
                n += 1;
                self.fired += 1;
                var j = i;
                while (j + 1 < self.len) : (j += 1) {
                    self.slots[j] = self.slots[j + 1];
                }
                self.len -= 1;
                continue; // 同一位置已经是下一个元素，不前进
            }
            i += 1;
        }
        return n;
    }

    /// 最近一次到期时间；空轮返回 null。事件循环用它决定“能不能一觉睡到
    /// 下一个定时器”，这是空闲 tick 唯一的省电依据。
    pub fn nextDeadline(self: *const Wheel) ?u64 {
        var best: ?u64 = null;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const d = self.slots[i].deadline;
            if (best == null or d < best.?) best = d;
        }
        return best;
    }
};

/// 池满时的策略。
///
/// 默认 `reject_new`：在固定槽位的设备上，悄悄关掉一条正在服务的连接
/// （应用之后只会看到 `bad_fd`）比拒绝新连接更难排查——被拒的对端能收到
/// RST/FIN 并自己重试。`evict_oldest` 留给"永远服务最新请求"的场景，
/// 代价是被踢方无从得知。两种策略都必须计数（22.6 的表格）。
pub const Policy = enum { reject_new, evict_oldest };

/// 一次准入的结论。
pub const Admit = enum {
    admitted,
    rejected_full,
    evicted_then_admitted,
};

/// 已接受连接池。**只管“谁被接受了”**，不持有 socket 本身：
/// fd 是 `socket.Table` 的索引，池是一张 `[4]u8` 的名单。
pub const Pool = struct {
    fds: [pool_cap]u8 = @splat(0),
    len: usize = 0,
    policy: Policy = .reject_new,

    accepted: u32 = 0,
    rejected: u32 = 0,
    evicted: u32 = 0,
    last_evicted_fd: i8 = socket.no_fd,

    pub fn reset(self: *Pool) void {
        self.len = 0;
        self.accepted = 0;
        self.rejected = 0;
        self.evicted = 0;
        self.last_evicted_fd = socket.no_fd;
    }

    pub fn contains(self: *const Pool, fd: u8) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.fds[i] == fd) return true;
        }
        return false;
    }

    pub fn remove(self: *Pool, fd: u8) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.fds[i] == fd) {
                var j = i;
                while (j + 1 < self.len) : (j += 1) {
                    self.fds[j] = self.fds[j + 1];
                }
                self.len -= 1;
                return true;
            }
        }
        return false;
    }

    /// 准入。池满时按 `policy`：
    ///   - `.reject_new`     → `rejected += 1`，把决定权交回调用方（由它关掉
    ///     新连接）。可观测计数就是“被拒了多少次——要不要扩大上限”的依据。
    ///   - `.evict_oldest`   → 找 `accept_token` 最小的那条，`tbl.abort()` 它，
    ///     腾出的槽位给新连接；`evicted += 1`。
    /// 两种策略都必须计数，否则运行期无法回答“池真的满过吗”。
    pub fn admit(self: *Pool, tbl: *socket.Table, fd: u8) Admit {
        if (self.len < pool_cap) {
            self.fds[self.len] = fd;
            self.len += 1;
            self.accepted += 1;
            return .admitted;
        }
        if (self.policy == .reject_new) {
            self.rejected += 1;
            return .rejected_full;
        }
        // evict_oldest：accept_token 越大越新，所以挑最小者。
        var victim: usize = 0;
        var i: usize = 1;
        while (i < self.len) : (i += 1) {
            const a = tbl.socks[self.fds[victim]].accept_token;
            const b = tbl.socks[self.fds[i]].accept_token;
            if (b < a) victim = i;
        }
        const old = self.fds[victim];
        tbl.abort(old);
        self.last_evicted_fd = @intCast(old);
        self.evicted += 1;
        self.fds[victim] = fd;
        self.accepted += 1;
        return .evicted_then_admitted;
    }
};

/// 事件循环本体。全部状态都是整数/定长数组，可以整体放进 `.bss`。
pub const Loop = struct {
    /// 下一 tick 的扫描起点（对注册表索引取模）。这就是公平性的全部实现。
    start: usize = 0,
    ticks: u64 = 0,
    polls: u64 = 0,
    /// 没有任何就绪项的 tick 数。空闲 tick 的“开销”在这里可数：
    /// 一个空 tick = 扫一遍注册表（O(n) 次布尔判断）+ 一次 `wfi`。
    idle_ticks: u64 = 0,
    ready_total: u64 = 0,
    truncated: u64 = 0,

    /// listener 的 fd（本章只有一条）。`accept()` 从这里取。
    listen_fd: i8 = socket.no_fd,
    pool: Pool = .{},
    wheel: Wheel = .{},

    pub fn reset(self: *Loop) void {
        self.start = 0;
        self.ticks = 0;
        self.polls = 0;
        self.idle_ticks = 0;
        self.ready_total = 0;
        self.truncated = 0;
        self.listen_fd = socket.no_fd;
        self.pool.reset();
        self.wheel.reset();
    }

    /// 一个 tick。按轮转顺序扫描 `regs`，把就绪项按 **扫描顺序** 追加到
    /// `out`（顺序是公平性判据要观察的东西，不要排序）。
    ///
    /// 返回值 = 就绪项条数（已被 `poll_cap` 截断）。`out` 由调用方持有，
    /// 本函数先清空它。
    pub fn poll(self: *Loop, tbl: *socket.Table, regs: []const PollFd, out: *ReadySet) usize {
        out.reset();
        self.polls += 1;
        self.ticks += 1;

        const n = regs.len;
        if (n == 0) {
            self.start = 0;
            self.idle_ticks += 1;
            return 0;
        }
        const begin = self.start % n;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const reg = regs[(begin + i) % n];
            if (reg.fd >= socket.max_fds) continue;
            const s = &tbl.socks[reg.fd];
            var mask = Mask{};
            if (reg.events.read and tbl.readyRead(reg.fd)) mask.read = true;
            if (reg.events.write and s.writable()) mask.write = true;
            // HUP 独立于注册的事件：fd 被关闭/对端 RST 时永远要告诉应用。
            if (s.reset_seen or s.state == .closed) mask.hup = true;
            if (!mask.any()) continue;
            if (out.len >= poll_cap) {
                self.truncated += 1;
                continue;
            }
            out.items[out.len] = .{ .fd = reg.fd, .mask = mask };
            out.len += 1;
        }

        // 起点前进一格：下一个 tick 从“这一轮的第二个注册项”开始扫。
        self.start = (begin + 1) % n;
        if (out.len == 0) self.idle_ticks += 1;
        self.ready_total += out.len;
        return out.len;
    }

    /// `accept()` 的完整语义 = “backlog 里有握手完成的连接” + “池准入”。
    /// 池拒绝时由本函数负责关掉新连接（应用看不到它，也就不会泄漏槽位）。
    pub fn accept(self: *Loop, tbl: *socket.Table) socket.Io {
        if (self.listen_fd < 0) return socket.Io.fail(.bad_fd);
        const lfd: u8 = @intCast(self.listen_fd);
        if (tbl.get(self.listen_fd) == null) return socket.Io.fail(.bad_fd);
        const child = tbl.takeReady(lfd) orelse return socket.Io.fail(.again);
        switch (self.pool.admit(tbl, child)) {
            .rejected_full => {
                tbl.abort(child);
                return socket.Io.fail(.pool_full);
            },
            else => return socket.Io.ok(child),
        }
    }

    /// 应用关闭一条连接：先从池名单里摘掉，再走状态机。
    pub fn closeConn(self: *Loop, tbl: *socket.Table, fd: u8) void {
        _ = self.pool.remove(fd);
        tbl.close(fd);
        _ = self.wheel.cancel(fd, .idle_close);
        _ = self.wheel.cancel(fd, .retransmit);
    }
};

// ---------------------------------------------------------------------------
// 主机侧单测：就绪集、轮转公平、截断、超时轮、池两种策略
// ---------------------------------------------------------------------------

/// 走完握手，但把子连接**留在 backlog** 里（用来测 `accept` 与池策略）。
fn offer(tbl: *socket.Table, listen_fd: u8, seq: u32) u8 {
    tbl.deliver(listen_fd, .{ .kind = .syn, .seq = seq });
    const newest: u8 = @intCast(tbl.socks[listen_fd].backlog[tbl.socks[listen_fd].backlog_len - 1]);
    tbl.deliver(newest, .{ .kind = .ack, .seq = seq +% 1, .ack = 1 });
    return newest;
}

/// 握手并从 backlog 出队，返回一条“已经建立、可以直接读写”的连接。
fn handshake(tbl: *socket.Table, listen_fd: u8, seq: u32) u8 {
    const child = offer(tbl, listen_fd, seq);
    _ = tbl.takeReady(listen_fd);
    return child;
}

fn newListen(tbl: *socket.Table) u8 {
    const fd = tbl.listen();
    return @intCast(fd);
}

test "poll：空注册表返回 0，计入 idle_ticks" {
    var tbl = socket.Table{};
    var lp = Loop{};
    var out = ReadySet{};
    try std.testing.expectEqual(@as(usize, 0), lp.poll(&tbl, &.{}, &out));
    try std.testing.expectEqual(@as(u64, 1), lp.idle_ticks);
    try std.testing.expectEqual(@as(u64, 1), lp.polls);
}

test "poll：就绪集只含真正可读的 fd，listener 要等握手完成才算可读" {
    var tbl = socket.Table{};
    var lp = Loop{};
    var out = ReadySet{};
    const lfd = newListen(&tbl);
    const regs = [_]PollFd{.{ .fd = lfd, .events = .{ .read = true } }};

    // 只有 SYN：backlog 非空但握手未完成 → 不可读（accept 会 EAGAIN）。
    tbl.deliver(lfd, .{ .kind = .syn, .seq = 10 });
    try std.testing.expectEqual(@as(usize, 0), lp.poll(&tbl, &regs, &out));

    // ACK 之后：可读，且 accept 能拿到 fd。
    const child = tbl.socks[lfd].backlog[0];
    tbl.deliver(@intCast(child), .{ .kind = .ack, .seq = 11 });
    try std.testing.expectEqual(@as(usize, 1), lp.poll(&tbl, &regs, &out));
    try std.testing.expect(out.hasRead(lfd));
    try std.testing.expect(!out.hasWrite(lfd));
}

test "poll：writable 随发送缓冲变化（水平触发）" {
    var tbl = socket.Table{};
    var lp = Loop{};
    var out = ReadySet{};
    const lfd = newListen(&tbl);
    const cfd = handshake(&tbl, lfd, 1);
    const regs = [_]PollFd{.{ .fd = cfd, .events = .{ .read = true, .write = true } }};

    try std.testing.expectEqual(@as(usize, 1), lp.poll(&tbl, &regs, &out));
    try std.testing.expect(out.hasWrite(cfd));

    // 填满发送缓冲 → 不可写，且没有别的就绪项。
    var payload: [socket.tx_cap]u8 = @splat('x');
    const io = tbl.socks[cfd].send(&payload);
    try std.testing.expectEqual(@as(usize, socket.tx_cap), io.n);
    try std.testing.expectEqual(@as(usize, 0), lp.poll(&tbl, &regs, &out));

    // 被吃掉 1 字节 → 立刻又可写。
    _ = tbl.socks[cfd].drainTx(1);
    try std.testing.expectEqual(@as(usize, 1), lp.poll(&tbl, &regs, &out));
    try std.testing.expect(out.hasWrite(cfd));
}

test "poll：轮转起点每 tick 前进，两个常驻可读 fd 都会轮到队首" {
    var tbl = socket.Table{};
    var lp = Loop{};
    var out = ReadySet{};
    const lfd = newListen(&tbl);
    const a = handshake(&tbl, lfd, 1);
    const b = handshake(&tbl, lfd, 5);

    // 两条都灌进数据，使它们"常驻可读"。
    tbl.socks[a].onSegment(.{ .kind = .data, .payload = "a" });
    tbl.socks[b].onSegment(.{ .kind = .data, .payload = "b" });

    const regs = [_]PollFd{
        .{ .fd = a, .events = .{ .read = true } },
        .{ .fd = b, .events = .{ .read = true } },
    };

    var head_a: u32 = 0;
    var head_b: u32 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = lp.poll(&tbl, &regs, &out);
        try std.testing.expectEqual(@as(usize, 2), out.len);
        const h = out.head().?;
        if (h == a) head_a += 1;
        if (h == b) head_b += 1;
    }
    try std.testing.expect(head_a > 0 and head_b > 0);
    try std.testing.expectEqual(@as(u32, 4), head_a);
    try std.testing.expectEqual(@as(u32, 4), head_b);
}

test "poll：就绪项超出预算时截断并计数，不丢 fd（下个 tick 还会出现）" {
    var tbl = socket.Table{};
    var lp = Loop{};
    var out = ReadySet{};
    const lfd = newListen(&tbl);

    // 造 5 条可读连接（> poll_cap = 4）。
    var conns: [5]u8 = undefined;
    var i: usize = 0;
    while (i < conns.len) : (i += 1) {
        conns[i] = handshake(&tbl, lfd, @intCast(100 + i * 10));
        tbl.socks[conns[i]].onSegment(.{ .kind = .data, .payload = "z" });
    }
    var regs: [5]PollFd = undefined;
    for (conns, 0..) |c, k| regs[k] = .{ .fd = c, .events = .{ .read = true } };

    const n = lp.poll(&tbl, &regs, &out);
    try std.testing.expectEqual(poll_cap, n);
    try std.testing.expectEqual(@as(u64, 1), lp.truncated);
}

test "超时轮：只弹出到期的，注入 now 不需要真的等" {
    var w = Wheel{};
    try std.testing.expect(w.insert(.{ .deadline = 3, .fd = 1, .kind = .retransmit }));
    try std.testing.expect(w.insert(.{ .deadline = 10, .fd = 2, .kind = .idle_close }));

    var out: [max_timers]Timer = undefined;
    try std.testing.expectEqual(@as(usize, 0), w.advance(2, &out));
    try std.testing.expectEqual(@as(usize, 1), w.advance(3, &out));
    try std.testing.expectEqual(TimerKind.retransmit, out[0].kind);
    try std.testing.expectEqual(@as(u8, 1), out[0].fd);
    try std.testing.expectEqual(@as(usize, 0), w.advance(9, &out));
    try std.testing.expectEqual(@as(usize, 1), w.advance(10, &out));
    try std.testing.expectEqual(@as(u32, 2), w.fired);
    try std.testing.expect(w.nextDeadline() == null);
}

test "超时轮：取消、容量上限、下一到期时刻" {
    var w = Wheel{};
    try std.testing.expect(w.insert(.{ .deadline = 7, .fd = 1, .kind = .idle_close }));
    try std.testing.expect(w.insert(.{ .deadline = 4, .fd = 2, .kind = .retransmit }));
    try std.testing.expectEqual(@as(u64, 4), w.nextDeadline().?);
    try std.testing.expect(w.cancel(1, .idle_close));
    try std.testing.expect(!w.cancel(1, .idle_close));
    try std.testing.expectEqual(@as(u64, 4), w.nextDeadline().?);

    var i: usize = 0;
    while (i < max_timers) : (i += 1) {
        _ = w.insert(.{ .deadline = 100 + i, .fd = 3, .kind = .connect_timeout });
    }
    // 已有一条（fd=2）+ 8 条 = 9 > max_timers(8)：最后一次插入被拒。
    try std.testing.expectEqual(@as(u32, 1), w.refused);
    try std.testing.expectEqual(max_timers, w.len);
}

test "连接池：上限之内全部接受，第 5 条按 reject_new 被拒并计数" {
    var tbl = socket.Table{};
    var lp = Loop{};
    const lfd = newListen(&tbl);
    lp.listen_fd = @intCast(lfd);

    var i: usize = 0;
    while (i < pool_cap) : (i += 1) {
        _ = offer(&tbl, lfd, @intCast(10 + i));
        const io = lp.accept(&tbl);
        try std.testing.expectEqual(socket.Errno.ok, io.err);
    }
    try std.testing.expectEqual(pool_cap, lp.pool.len);
    try std.testing.expectEqual(@as(u32, pool_cap), lp.pool.accepted);

    const before = tbl.openCount();
    _ = offer(&tbl, lfd, 90);
    const io = lp.accept(&tbl);
    try std.testing.expectEqual(socket.Errno.pool_full, io.err);
    try std.testing.expectEqual(@as(u32, 1), lp.pool.rejected);
    try std.testing.expectEqual(@as(u32, 0), lp.pool.evicted);
    // 被拒的连接已被关掉：表里的打开数（listener + 4）不变。
    try std.testing.expectEqual(before, tbl.openCount());
}

test "连接池：evict_oldest 踢掉令牌最小的一条，槽位复用且计数可观测" {
    var tbl = socket.Table{};
    var lp = Loop{};
    const lfd = newListen(&tbl);
    lp.listen_fd = @intCast(lfd);
    lp.pool.policy = .evict_oldest;

    var first: u8 = 0;
    var i: usize = 0;
    while (i < pool_cap) : (i += 1) {
        _ = offer(&tbl, lfd, @intCast(20 + i));
        const io = lp.accept(&tbl);
        try std.testing.expectEqual(socket.Errno.ok, io.err);
        if (i == 0) first = @intCast(io.n);
    }
    try std.testing.expectEqual(@as(u32, 0), lp.pool.evicted);

    _ = offer(&tbl, lfd, 99);
    const io = lp.accept(&tbl);
    try std.testing.expectEqual(socket.Errno.ok, io.err);
    try std.testing.expectEqual(@as(u32, 1), lp.pool.evicted);
    try std.testing.expectEqual(@as(u32, 0), lp.pool.rejected);
    try std.testing.expectEqual(@as(i8, @intCast(first)), lp.pool.last_evicted_fd);
    try std.testing.expectEqual(pool_cap, lp.pool.len);
    // 被踢的那条 fd 已回到 closed，且新连接拿到了它（槽位复用）。
    try std.testing.expectEqual(socket.Errno.bad_fd, tbl.socks[first].send("x").err);
    try std.testing.expect(lp.pool.contains(@intCast(io.n)));
}

test "accept：握手未完成时返回 again，不消耗 backlog" {
    var tbl = socket.Table{};
    var lp = Loop{};
    const lfd = newListen(&tbl);
    lp.listen_fd = @intCast(lfd);
    tbl.deliver(lfd, .{ .kind = .syn, .seq = 3 });
    try std.testing.expectEqual(socket.Errno.again, lp.accept(&tbl).err);
    try std.testing.expectEqual(@as(usize, 1), tbl.socks[lfd].backlog_len);

    const child = tbl.socks[lfd].backlog[0];
    tbl.deliver(@intCast(child), .{ .kind = .ack, .seq = 4 });
    try std.testing.expectEqual(socket.Errno.ok, lp.accept(&tbl).err);
    try std.testing.expectEqual(@as(usize, 0), tbl.socks[lfd].backlog_len);
}

test "accept：没有 listener 时返回 bad_fd" {
    var tbl = socket.Table{};
    var lp = Loop{};
    try std.testing.expectEqual(socket.Errno.bad_fd, lp.accept(&tbl).err);
    lp.listen_fd = 7; // 槽位存在但没监听
    try std.testing.expectEqual(socket.Errno.bad_fd, lp.accept(&tbl).err);
}
