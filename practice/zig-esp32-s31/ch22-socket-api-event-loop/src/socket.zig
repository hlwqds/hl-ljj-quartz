//! ch22-socket-api-event-loop：套接字对象与 FD 表。
//!
//! 本章要回答的问题是：“有了 ch20 的 TCP 状态机、ch21 的拥塞控制，应用
//! 到底拿到什么？”答案是**一个整数**（fd）和**一套返回值契约**。这个模块
//! 就是那套契约的实现：
//!
//!   - **固定上限的 FD 表**：`max_fds = 8`，索引即 fd，没有分配器、没有
//!     句柄表扩容、没有 `malloc` 失败路径。板侧 8 个槽位的表是 `.bss`
//!     里的静态对象（约 10 KiB），地址恒定。
//!   - **显式状态**：`closed → listen → syn_rcvd → established → close_wait
//!     → last_ack → closed`。迁移只由“投递进来的段”和“本地 API 调用”
//!     触发，没有任何隐式推进。
//!   - **返回值即契约**：`Io{ n, err }`。`err == .again` 是 EAGAIN /
//!     EWOULDBLOCK 的等价物（非阻塞、现在没数据或没空间），**不是错误**
//!     ——事件循环必须把它当成“下次再问”。
//!   - **部分读写**：`send` 只搬得动发送缓冲放得下的部分，`recv` 只吐出
//!     已到达的部分。剩下的由调用方持着（背压），本层不排队、不复制两次。
//!
//! 与 ch20 的关系是**签名级**：`State` 的名字照着 socket API 那一侧取，
//! 但状态迁移表、序号的用法、缓冲结构都是本章自己的一份实现，不 import
//! ch20 的任何符号。理由见章节 22.12：两个工程各自独立重写，任何“调用
//! 对方实现”的说法都是错的。
//!
//! 一个刻意的简化（写进注释而不是藏着）：本章的 `seq`/`ack` 只做“1 字节
//! 序号”的递增记账，够用来验状态与背压，不参与重排/重传——那是 ch20。
//! 三次握手在这里也只走三步（SYN / ACK / ESTABLISHED），没有 SYN_ACK 的
//! 回写路径（那是 ch20 的发送侧工作，本章没有真的发送队列去装它）。

const std = @import("std");
const netstub = @import("netstub.zig");

/// FD 表容量。8 个槽位：一个 listener + 7 条连接/留给池上限 4 的余量。
/// 板侧是 `.bss` 里的固定数组，占用 = 8 × sizeof(Socket) ≈ 10 KiB。
pub const max_fds: usize = 8;
/// 每条连接的接收缓冲。256 字节足够装两段 128 字节的 `netstub` 载荷，
/// 也足够演示“部分读”。
pub const rx_cap: usize = 256;
/// 每条连接的发送缓冲。1 KiB 是本章的背压演示尺寸：待发 3 KiB 时
/// `send` 只接受 1024 字节并返回 1024，其余由调用方持有。
pub const tx_cap: usize = 1024;
/// 每条 listener 的 backlog 深度（尚未被 `accept` 取走的连接）。
pub const backlog_cap: usize = 4;
/// Sentinel：不合法的 fd 值（`i8` 而非 `u8`，因为 `bad_fd` 是合法返回值）。
pub const no_fd: i8 = -1;

/// 套接字状态。名字与 POSIX/BSD socket 的 `ss_` 宏一致，取值只为打印稳定。
pub const State = enum(u8) {
    closed = 0,
    listen,
    syn_rcvd,
    established,
    fin_wait_1,
    close_wait,
    last_ack,
    time_wait,

    pub fn name(self: State) []const u8 {
        return @tagName(self);
    }

    /// 槽位是否被占用。
    pub fn isOpen(self: State) bool {
        return self != .closed;
    }

    /// 能不能收发数据（`close_wait` 仍可 `recv` 到对端已发的数据）。
    pub fn canIo(self: State) bool {
        return self == .established or self == .close_wait;
    }
};

/// 错误码。整套枚举就是本章的“errno 表”，`again` 是唯一的非致命项。
pub const Errno = enum(u8) {
    ok = 0,
    /// EAGAIN / EWOULDBLOCK：现在不能立即完成，稍后重试。
    again,
    /// EBADF：fd 不在表内或槽位空闲。
    bad_fd,
    /// ENOTCONN：状态不允许这次操作（比如对 listener `send`）。
    not_conn,
    /// ECONNRESET：对端 RST，数据不可再读。
    conn_reset,
    /// EMFILE / ENFILE 的等价物：连接池满且策略是拒绝新连接。
    pool_full,
    /// EINPROGRESS：连接已建立但三次握手尚未完成（`accept` 会再要一次）。
    in_progress,

    pub fn name(self: Errno) []const u8 {
        return @tagName(self);
    }
};

/// 一次 I/O 的结果。`n` 与 `err` 的关系：
///   - `err == .ok and n == 0` → 对方已关闭（EOF），这是正常终止；
///   - `err == .ok and n < 请求长度` → 部分完成，立即重试未完成的部分；
///   - `err == .again` → 什么也没搬，别忙等，等就绪通知。
pub const Io = struct {
    n: usize = 0,
    err: Errno = .ok,

    pub fn ok(n: usize) Io {
        return .{ .n = n, .err = .ok };
    }

    pub fn fail(e: Errno) Io {
        return .{ .n = 0, .err = e };
    }

    pub fn pending(self: Io) bool {
        return self.err == .again;
    }
};

/// 一个套接字对象。
///
/// 缓冲内联（而不是指向外部）：`Table` 是一个可以整体放进 `.bss` 的数组，
/// 没有自引用指针，因而没有“表被搬动后指针失效”这一类问题。代价是
/// `Socket` 不能是 `extern struct`——它也不需要。
pub const Socket = struct {
    state: State = .closed,
    /// 非阻塞是本章**唯一**支持的语义；字段保留是为了在自检里把它当
    /// “契约的一部分”打印出来（阻塞模式需要调度器让出 CPU，形态 B 没有）。
    nonblocking: bool = true,

    rx_buf: [rx_cap]u8 = undefined,
    rx_head: usize = 0,
    rx_len: usize = 0,
    /// 对端 FIN 已到且接收缓冲已排空 ⇒ 下一次 `recv` 返回 EOF(ok,0)。
    rx_eof: bool = false,

    tx_buf: [tx_cap]u8 = undefined,
    tx_head: usize = 0,
    tx_len: usize = 0,

    /// listener 的待取连接（fd 索引）。FIFO。
    backlog: [backlog_cap]i8 = @splat(no_fd),
    backlog_len: usize = 0,

    /// 对端标识（本章用注入段的低位冒充），只用于打印。
    peer: u8 = 0,
    /// 本地已发送的字节数（简化序号：每字节 +1）。
    snd_nxt: u32 = 0,
    /// 已交付给应用的字节数（简化确认号）。
    rcv_nxt: u32 = 0,
    /// 连接在池中的准入顺序令牌：越大越新。踢出策略按这个字段挑最旧。
    accept_token: u32 = 0,

    /// 计数器：自检与指纹都读它们。
    sent_bytes: u32 = 0,
    recv_bytes: u32 = 0,
    again_count: u32 = 0,
    /// 接收方向装不下而被丢弃的字节数。本章**没有接收背压**：真实 TCP 用
    /// 窗口与重传解决这类溢出（属 ch20），所以这里只能丢并计数。
    rx_dropped: u32 = 0,
    reset_seen: bool = false,

    /// 回到空闲槽位（只清状态与缓冲，不清计数器——`Table.reset` 管那个）。
    pub fn reset(self: *Socket) void {
        self.state = .closed;
        self.rx_head = 0;
        self.rx_len = 0;
        self.rx_eof = false;
        self.tx_head = 0;
        self.tx_len = 0;
        self.backlog_len = 0;
        self.peer = 0;
        self.snd_nxt = 0;
        self.rcv_nxt = 0;
        self.accept_token = 0;
        self.reset_seen = false;
    }

    pub fn enterListen(self: *Socket) void {
        self.reset();
        self.state = .listen;
    }

    // -- 环形缓冲 ---------------------------------------------------------
    //
    // 定长 + head/len，不做扩容。满时 `push` 返回搬进去的字节数（可能 0），
    // 这正是“部分写”的来源。

    pub fn rxFree(self: *const Socket) usize {
        return rx_cap - self.rx_len;
    }

    pub fn txFree(self: *const Socket) usize {
        return tx_cap - self.tx_len;
    }

    fn rxPush(self: *Socket, src: []const u8) usize {
        const n = @min(self.rxFree(), src.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.rx_buf[(self.rx_head + self.rx_len + i) % rx_cap] = src[i];
        }
        self.rx_len += n;
        return n;
    }

    fn rxPop(self: *Socket, dst: []u8) usize {
        const n = @min(self.rx_len, dst.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = self.rx_buf[(self.rx_head + i) % rx_cap];
        }
        self.rx_head = (self.rx_head + n) % rx_cap;
        self.rx_len -= n;
        return n;
    }

    fn txPush(self: *Socket, src: []const u8) usize {
        const n = @min(self.txFree(), src.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.tx_buf[(self.tx_head + self.tx_len + i) % tx_cap] = src[i];
        }
        self.tx_len += n;
        return n;
    }

    /// 发送侧被传输层“吃掉” n 字节（等价于收到 ACK）。池/事件循环与自检
    /// 都用它来推进背压。
    pub fn drainTx(self: *Socket, n: usize) usize {
        const k = @min(n, self.tx_len);
        self.tx_head = (self.tx_head + k) % tx_cap;
        self.tx_len -= k;
        return k;
    }

    // -- 就绪判定 ---------------------------------------------------------
    //
    // poll 只读这两个函数；它们是“就绪”的唯一定义来源，所以任何语义
    // 变更都要同时改章节 22.4 与主机侧用例。

    /// 可读：接收缓冲有数据，或已到 EOF（`recv` 会返回 0）。
    /// RST 之后也算可读：它保证 `recv` 立即返回 `conn_reset`，不会卡住。
    ///
    /// **listener 不算可读**：`accept` 能不能立刻返回取决于 backlog 队首
    /// 那条子连接是否已完成握手，那是**另一个槽位**的状态。单看 listener
    /// 自己无法回答，所以这个判断在 `Table.readyRead()` 里做。
    pub fn readable(self: *const Socket) bool {
        if (self.reset_seen) return true;
        if (self.rx_len > 0 or self.rx_eof) return true;
        return false;
    }

    /// 可写：连接态且发送缓冲还有空间。
    /// 注意判据是“**有空间**”而不是“空”：1 KiB 缓冲里塞了 1024 字节时
    /// 不可写，被吃掉 1 字节就可写——水平触发，见章节 22.4。
    pub fn writable(self: *const Socket) bool {
        return self.state.canIo() and self.tx_len < tx_cap;
    }

    /// backlog 是否非空（粗粒度）。真正的“能不能 accept”由
    /// `Table.readyRead()` 连带子连接状态一起判断。
    pub fn backlogPending(self: *const Socket) bool {
        return self.state == .listen and self.backlog_len > 0;
    }

    // -- 应用侧 API -------------------------------------------------------

    /// 读。语义与 POSIX `recv(fd, buf, n, MSG_DONTWAIT)` 对齐：
    ///   - 有数据：返回搬走的字节数（可能少于 `dst.len`）；
    ///   - 无数据：`.again`；
    ///   - 已 EOF：`ok(0)`；
    ///   - 已 RST：`.conn_reset`（优先于缓冲里残留的数据，宁可丢掉也不让
    ///     应用读到“过期的正文”后继续当成有效连接）。
    pub fn recv(self: *Socket, dst: []u8) Io {
        if (self.state == .closed and !self.reset_seen) return Io.fail(.bad_fd);
        if (self.reset_seen) return Io.fail(.conn_reset);
        if (!self.state.canIo()) return Io.fail(.not_conn);
        if (self.rx_len > 0) {
            const n = self.rxPop(dst);
            self.recv_bytes += @intCast(n);
            self.rcv_nxt +%= @intCast(n);
            return Io.ok(n);
        }
        if (self.rx_eof) return Io.ok(0);
        self.again_count += 1;
        return Io.fail(.again);
    }

    /// 写。只搬得动发送缓冲放得下的部分：
    ///   - 有空间：返回搬走的字节数（可能少于 `src.len`，调用方持剩余）；
    ///   - 没空间：`.again`（一个字节也没搬）。
    /// 本层不做“排队到有空间再发”，因为那需要分配器；背压由调用方承担，
    /// 这正是非阻塞 API 的核心契约。
    pub fn send(self: *Socket, src: []const u8) Io {
        if (self.state == .closed and !self.reset_seen) return Io.fail(.bad_fd);
        if (self.reset_seen) return Io.fail(.conn_reset);
        if (!self.state.canIo()) return Io.fail(.not_conn);
        if (src.len == 0) return Io.ok(0);
        if (self.tx_len >= tx_cap) {
            self.again_count += 1;
            return Io.fail(.again);
        }
        const n = self.txPush(src);
        self.sent_bytes += @intCast(n);
        self.snd_nxt +%= @intCast(n);
        return Io.ok(n);
    }

    /// 本地主动关闭。两个分支：
    ///   - `established` → `fin_wait_1`（等对端 ACK）
    ///   - `close_wait`  → `last_ack`（对端已 FIN，我们回 FIN）
    /// 其它状态直接回到 `closed`（listener、未完成握手、已关闭）。
    pub fn closeHalf(self: *Socket) void {
        switch (self.state) {
            .established => self.state = .fin_wait_1,
            .close_wait => self.state = .last_ack,
            else => self.state = .closed,
        }
    }

    /// 收到一段。只处理本章需要的迁移：
    ///
    /// | 当前            | 段    | 之后         |
    /// | --------------- | ----- | ------------ |
    /// | syn_rcvd        | ack   | established  |
    /// | established     | data  | established  |
    /// | established     | fin   | close_wait   |
    /// | last_ack        | ack   | closed       |
    /// | fin_wait_1      | ack   | closed（简化：不建模 time_wait 停留）|
    /// | 任意（非listener）| rst  | closed + reset_seen |
    pub fn onSegment(self: *Socket, seg: netstub.Segment) void {
        if (self.state == .listen) return; // listener 的 SYN 由 Table 处理
        switch (seg.kind) {
            .rst => {
                self.reset_seen = true;
                self.state = .closed;
                return;
            },
            .ack => switch (self.state) {
                .syn_rcvd => self.state = .established,
                .last_ack, .fin_wait_1 => self.state = .closed,
                else => {},
            },
            .data => {
                if (!self.state.canIo()) return;
                const n = self.rxPush(seg.payload);
                self.rcv_nxt +%= @intCast(n);
                if (seg.payload.len > n) self.rx_dropped += @intCast(seg.payload.len - n);
            },
            .fin => switch (self.state) {
                .established => {
                    self.rx_eof = true;
                    self.state = .close_wait;
                },
                .fin_wait_1 => self.state = .closed,
                else => {},
            },
            .syn, .syn_ack => {},
        }
    }
};

/// FD 表：固定数组 + 计数器。索引就是 fd。
pub const Table = struct {
    socks: [max_fds]Socket = @splat(.{}),

    /// 全局计数（跨槽位，用于报警与指纹）。
    connects: u32 = 0,
    backlog_drops: u32 = 0,
    fd_exhausted: u32 = 0,
    ignores: u32 = 0,
    spawn_token: u32 = 0,

    pub fn reset(self: *Table) void {
        self.* = .{};
    }

    pub fn get(self: *Table, fd: i8) ?*Socket {
        if (fd < 0 or @as(usize, @intCast(fd)) >= max_fds) return null;
        const s = &self.socks[@intCast(fd)];
        if (!s.state.isOpen()) return null;
        return s;
    }

    /// 找第一个空闲槽位。返回 `null` = 表满（EMFILE 的等价物）。
    pub fn alloc(self: *Table) ?u8 {
        for (&self.socks, 0..) |*s, i| {
            if (!s.state.isOpen()) return @intCast(i);
        }
        return null;
    }

    pub fn listen(self: *Table) i8 {
        const fd = self.alloc() orelse {
            self.fd_exhausted += 1;
            return no_fd;
        };
        self.socks[fd].enterListen();
        return @intCast(fd);
    }

    pub fn openCount(self: *const Table) usize {
        var n: usize = 0;
        for (&self.socks) |*s| {
            if (s.state.isOpen()) n += 1;
        }
        return n;
    }

    /// 投递一段到一个具体 fd：listener 上的 SYN 会派生一个子连接。
    pub fn deliver(self: *Table, fd: u8, seg: netstub.Segment) void {
        const s = &self.socks[fd];
        if (!s.state.isOpen()) {
            self.ignores += 1;
            return;
        }
        if (s.state == .listen) {
            if (seg.kind == .syn) {
                self.spawnChild(fd, seg);
            } else {
                self.ignores += 1;
            }
            return;
        }
        s.onSegment(seg);
    }

    /// 字节串入口（单段）：解一段并投递。
    pub fn deliverBytes(self: *Table, fd: u8, bytes: []const u8) netstub.DecodeError!void {
        const seg = try netstub.decode(bytes);
        self.deliver(fd, seg);
    }

    /// 字节串入口（脚本）：按顺序把整串拆成段逐段投递，返回段数。
    /// 这是“把一条脚本喂给 socket 层”的唯一入口——重放就是把同一串
    /// 再喂一次。
    pub fn deliverScript(self: *Table, fd: u8, bytes: []const u8) netstub.DecodeError!u32 {
        var script = netstub.Script{ .bytes = bytes };
        var n: u32 = 0;
        while (script.next()) |seg| {
            self.deliver(fd, seg);
            n += 1;
        }
        if (script.errors > 0) return error.LengthMismatch;
        return n;
    }

    /// 跨槽位的可读判定：listener 看“队首子连接是否已完成握手”，
    /// 其它槽位直接问 `Socket.readable()`。`event.poll` 只调这个函数。
    pub fn readyRead(self: *Table, fd: u8) bool {
        const s = &self.socks[fd];
        if (s.state == .listen) {
            if (s.backlog_len == 0) return false;
            const child: u8 = @intCast(s.backlog[0]);
            return self.socks[child].state == .established;
        }
        return s.readable();
    }

    /// SYN 到了：分配一个子槽位，置 `syn_rcvd` 并把它挂到 listener 的
    /// backlog 尾部。backlog 满或表满时**丢弃**而不是覆盖：丢一个未完成
    /// 握手的连接比踢掉一条已建立的更安全。
    fn spawnChild(self: *Table, listen_fd: u8, seg: netstub.Segment) void {
        const l = &self.socks[listen_fd];
        if (l.backlog_len >= backlog_cap) {
            self.backlog_drops += 1;
            return;
        }
        const child = self.alloc() orelse {
            self.fd_exhausted += 1;
            return;
        };
        const c = &self.socks[child];
        c.reset();
        c.state = .syn_rcvd;
        c.nonblocking = true;
        c.peer = @truncate(seg.seq);
        self.spawn_token += 1;
        c.accept_token = self.spawn_token;
        l.backlog[l.backlog_len] = @intCast(child);
        l.backlog_len += 1;
        self.connects += 1;
    }

    /// 从 listener 的 backlog 头部取一个已完成握手的子连接。不涉及池，
    /// 池的准入在 `event.accept` 里做（那是策略层）。
    pub fn takeReady(self: *Table, listen_fd: u8) ?u8 {
        const l = &self.socks[listen_fd];
        if (l.state != .listen or l.backlog_len == 0) return null;
        const child: u8 = @intCast(l.backlog[0]);
        if (self.socks[child].state != .established) return null;
        // 出队。
        var i: usize = 1;
        while (i < l.backlog_len) : (i += 1) {
            l.backlog[i - 1] = l.backlog[i];
        }
        l.backlog_len -= 1;
        l.backlog[l.backlog_len] = no_fd;
        return child;
    }

    /// 优雅关闭（POSIX `close` 的状态机那一半）：按状态迁移。
    /// 想立刻释放槽位（池踢出）用 `abort`。
    pub fn close(self: *Table, fd: u8) void {
        const s = &self.socks[fd];
        if (!s.state.isOpen()) return;
        if (s.state == .listen) {
            s.reset();
            return;
        }
        s.closeHalf();
        if (s.state == .closed) s.reset();
    }

    /// 立即释放（RST 式）：用于池淘汰与测试清理，不发 FIN、不等 ACK。
    pub fn abort(self: *Table, fd: u8) void {
        self.socks[fd].reset();
    }

    /// 指纹：状态、计数器、缓冲长度混在一起。重放同一脚本必须得到同一个值。
    pub fn fingerprint(self: *const Table) u32 {
        var h: u32 = netstub.fnv_offset;
        for (&self.socks) |*s| {
            const tag = [_]u8{ @backingInt(s.state), @intCast(@min(s.rx_len, 255)), @intCast(@min(s.tx_len, 255)) };
            h = netstub.fnv1a(h, &tag);
        }
        const counters = [_]u32{ self.connects, self.backlog_drops, self.fd_exhausted, self.ignores };
        for (counters) |c| {
            const b = [_]u8{ @truncate(c), @truncate(c >> 8) };
            h = netstub.fnv1a(h, &b);
        }
        return h;
    }
};

// ---------------------------------------------------------------------------
// 主机侧单测：FD 表、状态机、部分读写、EAGAIN、背压、指纹确定性
// ---------------------------------------------------------------------------

fn listenAndHandshake(tbl: *Table, seq: u32) u8 {
    const lfd = tbl.listen();
    const l: u8 = @intCast(lfd);
    tbl.deliver(l, .{ .kind = .syn, .seq = seq });
    const child: u8 = @intCast(tbl.socks[l].backlog[0]);
    tbl.deliver(child, .{ .kind = .ack, .seq = seq +% 1, .ack = 1 });
    return child;
}

test "FD 表：容量 8，listen 之后 alloc 一路到满，第 9 个返回 no_fd 并计数" {
    var tbl = Table{};
    var i: usize = 0;
    while (i < max_fds) : (i += 1) {
        try std.testing.expect(tbl.listen() >= 0);
    }
    try std.testing.expectEqual(no_fd, tbl.listen());
    try std.testing.expectEqual(@as(u32, 1), tbl.fd_exhausted);
    try std.testing.expectEqual(max_fds, tbl.openCount());
}

test "FD 表：关闭的槽位被下一个 listener 复用（索引即 fd，无句柄表）" {
    var tbl = Table{};
    const a = tbl.listen();
    const b = tbl.listen();
    try std.testing.expect(a != b);
    tbl.close(@intCast(a));
    const c = tbl.listen();
    try std.testing.expectEqual(a, c);
}

test "状态机：SYN → syn_rcvd，ACK → established，出队后 backlog 归零" {
    var tbl = Table{};
    const lfd = tbl.listen();
    tbl.deliver(@intCast(lfd), .{ .kind = .syn, .seq = 42 });
    try std.testing.expectEqual(@as(usize, 1), tbl.socks[@intCast(lfd)].backlog_len);
    const child: u8 = @intCast(tbl.socks[@intCast(lfd)].backlog[0]);
    try std.testing.expectEqual(State.syn_rcvd, tbl.socks[child].state);
    // 握手没完成时不可被 accept 取走。
    try std.testing.expect(tbl.takeReady(@intCast(lfd)) == null);
    tbl.deliver(child, .{ .kind = .ack, .seq = 43 });
    try std.testing.expectEqual(State.established, tbl.socks[child].state);
    try std.testing.expectEqual(child, tbl.takeReady(@intCast(lfd)).?);
    try std.testing.expectEqual(@as(usize, 0), tbl.socks[@intCast(lfd)].backlog_len);
}

test "状态机：对端 FIN → close_wait，本地 close → last_ack，ACK → closed" {
    var tbl = Table{};
    const cfd = listenAndHandshake(&tbl, 7);
    tbl.deliver(cfd, .{ .kind = .fin, .seq = 8 });
    try std.testing.expectEqual(State.close_wait, tbl.socks[cfd].state);
    // close_wait 仍可读：对端 FIN 之前发的数据还在缓冲里。
    try std.testing.expect(tbl.socks[cfd].readable());
    tbl.close(cfd);
    try std.testing.expectEqual(State.last_ack, tbl.socks[cfd].state);
    tbl.deliver(cfd, .{ .kind = .ack, .seq = 9 });
    try std.testing.expectEqual(State.closed, tbl.socks[cfd].state);
    try std.testing.expect(tbl.get(@intCast(cfd)) == null);
}

test "recv：无数据是 again，有数据部分读，EOF 是 ok(0)" {
    var tbl = Table{};
    const cfd = listenAndHandshake(&tbl, 11);
    const s = &tbl.socks[cfd];
    var dst: [64]u8 = undefined;
    try std.testing.expectEqual(Errno.again, s.recv(&dst).err);
    try std.testing.expectEqual(@as(u32, 1), s.again_count);

    s.onSegment(.{ .kind = .data, .seq = 12, .payload = "0123456789" });
    const io = s.recv(dst[0..4]);
    try std.testing.expectEqual(@as(usize, 4), io.n);
    try std.testing.expectEqualStrings("0123", dst[0..4]);
    try std.testing.expectEqual(@as(usize, 6), s.rx_len);

    s.onSegment(.{ .kind = .fin, .seq = 22 });
    const rest = s.recv(&dst);
    try std.testing.expectEqual(@as(usize, 6), rest.n);
    try std.testing.expectEqualStrings("456789", dst[0..6]);
    const eof = s.recv(&dst);
    try std.testing.expectEqual(Errno.ok, eof.err);
    try std.testing.expectEqual(@as(usize, 0), eof.n);
}

test "send：部分写把缓冲填满，再来一次是 again，drain 后恢复" {
    var tbl = Table{};
    const cfd = listenAndHandshake(&tbl, 1);
    const s = &tbl.socks[cfd];
    var big: [3 * tx_cap]u8 = undefined;
    @memset(&big, 'q');
    const io = s.send(&big);
    try std.testing.expectEqual(Errno.ok, io.err);
    try std.testing.expectEqual(@as(usize, tx_cap), io.n);
    try std.testing.expectEqual(@as(usize, 0), s.txFree());

    const again = s.send(&big);
    try std.testing.expectEqual(Errno.again, again.err);
    try std.testing.expectEqual(@as(usize, 0), again.n);

    try std.testing.expectEqual(@as(usize, 100), s.drainTx(100));
    const resumed = s.send(&big);
    try std.testing.expectEqual(@as(usize, 100), resumed.n);
    // 三次调用一共被接受 1124 字节，其余仍在调用方手里（背压）。
    try std.testing.expectEqual(@as(u32, tx_cap + 100), s.sent_bytes);
}

test "send/recv：listener 与非连接态返回 not_conn，RST 之后返回 conn_reset" {
    var tbl = Table{};
    const lfd = tbl.listen();
    try std.testing.expectEqual(Errno.not_conn, tbl.socks[@intCast(lfd)].send("x").err);
    var dst: [4]u8 = undefined;
    try std.testing.expectEqual(Errno.not_conn, tbl.socks[@intCast(lfd)].recv(&dst).err);

    const cfd = listenAndHandshake(&tbl, 5);
    tbl.socks[cfd].onSegment(.{ .kind = .data, .seq = 6, .payload = "abc" });
    tbl.deliver(cfd, .{ .kind = .rst, .seq = 20 });
    try std.testing.expectEqual(Errno.conn_reset, tbl.socks[cfd].recv(&dst).err);
    try std.testing.expectEqual(Errno.conn_reset, tbl.socks[cfd].send("x").err);
    try std.testing.expectEqual(State.closed, tbl.socks[cfd].state);
    // 已关闭且没有 RST 痕迹的槽位只报 bad_fd。
    tbl.abort(cfd);
    try std.testing.expectEqual(Errno.bad_fd, tbl.socks[cfd].recv(&dst).err);
}

test "背压：接收缓冲 256 字节，超出部分被丢弃并计数（本章无接收背压）" {
    var tbl = Table{};
    const cfd = listenAndHandshake(&tbl, 3);
    const s = &tbl.socks[cfd];
    var chunk: [200]u8 = undefined;
    @memset(&chunk, 'r');
    s.onSegment(.{ .kind = .data, .seq = 4, .payload = &chunk });
    s.onSegment(.{ .kind = .data, .seq = 204, .payload = &chunk });
    // 200 + 200 只装得下 256：第二次只进 56 字节，余下 144 字节被丢弃并计数。
    try std.testing.expectEqual(rx_cap, s.rx_len);
    try std.testing.expectEqual(@as(usize, 0), s.rxFree());
    try std.testing.expectEqual(@as(u32, 144), s.rx_dropped);
    try std.testing.expect(s.readable());
}

test "backlog：深度 4，第 5 个 SYN 被丢弃并计数，不覆盖已排队的连接" {
    var tbl = Table{};
    const lfd: u8 = @intCast(tbl.listen());
    var i: usize = 0;
    while (i < backlog_cap) : (i += 1) {
        tbl.deliver(lfd, .{ .kind = .syn, .seq = @intCast(100 + i) });
    }
    const first_child: i8 = tbl.socks[lfd].backlog[0];
    tbl.deliver(lfd, .{ .kind = .syn, .seq = 999 });
    try std.testing.expectEqual(@as(u32, 1), tbl.backlog_drops);
    try std.testing.expectEqual(@as(usize, backlog_cap), tbl.socks[lfd].backlog_len);
    try std.testing.expectEqual(first_child, tbl.socks[lfd].backlog[0]);
}

test "deliverBytes：同一字节串脚本两次投递得到同一指纹（可重放）" {
    var tbl = Table{};
    const lfd: u8 = @intCast(tbl.listen());

    var wire: [4 * netstub.max_segment]u8 = undefined;
    var at: usize = 0;
    at += netstub.encode(.{ .kind = .syn, .seq = 500 }, wire[at..]);
    const syn_bytes = wire[0..at];

    try tbl.deliverBytes(lfd, syn_bytes);
    const child: u8 = @intCast(tbl.socks[lfd].backlog[0]);

    var at2: usize = 0;
    var second: [2 * netstub.max_segment]u8 = undefined;
    at2 += netstub.encode(.{ .kind = .ack, .seq = 501 }, second[at2..]);
    at2 += netstub.encode(.{ .kind = .data, .seq = 502, .payload = "GET /" }, second[at2..]);
    const script = second[0..at2];

    const delivered = try tbl.deliverScript(child, script);
    try std.testing.expectEqual(@as(u32, 2), delivered);
    const h1 = tbl.fingerprint();
    const rx1 = tbl.socks[child].rx_len;

    // 同样两步在干净表上重放：指纹必须一致（状态与计数都可确定复现）。
    var tbl2 = Table{};
    const lfd2: u8 = @intCast(tbl2.listen());
    try tbl2.deliverBytes(lfd2, syn_bytes);
    const child2: u8 = @intCast(tbl2.socks[lfd2].backlog[0]);
    _ = try tbl2.deliverScript(child2, script);
    try std.testing.expectEqual(h1, tbl2.fingerprint());
    try std.testing.expectEqual(rx1, tbl2.socks[child2].rx_len);
    try std.testing.expectEqualStrings("GET /", tbl2.socks[child2].rx_buf[0..5]);
    try std.testing.expectEqual(@as(usize, 5), rx1);
}

test "deliver/close：未知 fd 计数忽略，listener 上非 SYN 段被忽略" {
    var tbl = Table{};
    tbl.deliver(3, .{ .kind = .data, .payload = "x" });
    try std.testing.expectEqual(@as(u32, 1), tbl.ignores);
    const lfd: u8 = @intCast(tbl.listen());
    tbl.deliver(lfd, .{ .kind = .data, .payload = "x" });
    try std.testing.expectEqual(@as(u32, 2), tbl.ignores);
    tbl.close(lfd);
    try std.testing.expectEqual(@as(usize, 0), tbl.openCount());
}
