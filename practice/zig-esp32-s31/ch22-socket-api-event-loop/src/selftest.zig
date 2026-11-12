//! ch22-socket-api-event-loop：板侧自检（12 条判据）。
//!
//! 板侧**没有任何真实网络**：所有段都由 `netstub` 造出来、直接投给
//! socket 层，所有时间都由调用方注入 tick。这里不做“连上服务器”、
//! 不做“真实 socket 可用”的任何断言——那需要 ch17 以太网闭环 + ch20
//! 状态机 + ch21 控制律一起上线（见章节 22.12）。
//!
//! 十二条判据（每条一行 `check: ... ok=1/0`）：
//!
//!   ① LISTEN + SYN → `syn_rcvd`；再投 ACK → `established`
//!   ② `accept` 返回 fd，连接池不超上限
//!   ③ 非阻塞 `recv` 无数据 → `.again`（EAGAIN 等价物）
//!   ④ `poll` 单 tick 返回正确就绪集合（可写 / 有数据后可读）
//!   ⑤ 超时轮：注入 `now`，只弹出到期的，不真等
//!   ⑥ 部分写：1 KiB 发送缓冲 + 3 KiB 待发 → 返回 1024，再来一次 `.again`
//!   ⑦ 对端 FIN → `close_wait`；本地 `close` → `last_ack`；ACK → `closed`
//!   ⑧ 池满：`reject_new` 拒新连接并计数；`evict_oldest` 踢最旧并计数
//!   ⑨ 公平轮询：两个常驻可读 fd，8 个 tick 内各当 4 次队首
//!   ⑩ 空转 tick：1000 个空 tick 全部计入 `idle_ticks`；来数据后不再空转
//!   ⑪ 注入数据 → 可读；`recv` 部分读两次拿全 200 字节，第三次 `.again`
//!   ⑫ 对端 RST → `recv` 返回 `.conn_reset`，槽位回到 `closed`
//!
//! 所有对象都是 `.bss` 里的静态变量：板侧没有分配器，自检也不该因为
//! `error.OutOfMemory` 而跑不到 verdict。

const std = @import("std");

const event = @import("event.zig");
const netstub = @import("netstub.zig");
const socket = @import("socket.zig");

const log = @import("log.zig");
const trap = @import("trap.zig");

/// FD 表 ≈ 10 KiB、就绪集 80 B、超时轮 128 B：全部在 `.bss`，
/// 不占 16 KiB 主栈（栈上放这张表会直接越过 `_stack_top`，表现为 trap）。
var g_tbl: socket.Table = .{};
var g_lp: event.Loop = .{};
var g_out: event.ReadySet = .{};
var g_payload: [3 * 1024]u8 = undefined;

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) g_passed += 1 else g_failed += 1;
    var buf: [150]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

/// 清空三件全局对象，建一条 listener，返回它的 fd。
fn setup() u8 {
    g_tbl.reset();
    g_lp.reset();
    g_out.reset();
    const lfd = g_tbl.listen();
    g_lp.listen_fd = lfd;
    return @intCast(lfd);
}

/// 走完三步：SYN → 子连接（syn_rcvd）→ ACK → established，
/// 但**留在 backlog** 里（`accept` 的输入）。
fn offer(listen_fd: u8, seq: u32) u8 {
    g_tbl.deliver(listen_fd, .{ .kind = .syn, .seq = seq });
    const l = &g_tbl.socks[listen_fd];
    const newest: u8 = @intCast(l.backlog[l.backlog_len - 1]);
    g_tbl.deliver(newest, .{ .kind = .ack, .seq = seq +% 1, .ack = 1 });
    return newest;
}

/// 握手并出队：返回一条可直接读写的连接。
fn handshake(listen_fd: u8, seq: u32) u8 {
    const child = offer(listen_fd, seq);
    _ = g_tbl.takeReady(listen_fd);
    return child;
}

fn runChecks() bool {
    // ---- ① 三次握手的三步 ----
    {
        const lfd = setup();
        g_tbl.deliver(lfd, .{ .kind = .syn, .seq = 1000 });
        const child = g_tbl.socks[lfd].backlog[0];
        const after_syn = g_tbl.socks[@intCast(child)].state;
        g_tbl.deliver(@intCast(child), .{ .kind = .ack, .seq = 1001, .ack = 1 });
        const after_ack = g_tbl.socks[@intCast(child)].state;
        check(
            after_syn == .syn_rcvd and after_ack == .established,
            "handshake listen={s} syn={s} ack={s} fd={d}",
            .{ g_tbl.socks[lfd].state.name(), after_syn.name(), after_ack.name(), child },
        );
    }

    // ---- ② accept 返回 fd，池不超限 ----
    {
        const lfd = setup();
        const cfd = offer(lfd, 2000);
        const io = g_lp.accept(&g_tbl);
        check(
            io.err == .ok and io.n == @as(usize, cfd) and g_lp.pool.len == 1 and g_lp.pool.len <= event.pool_cap,
            "accept fd={d} got={d} pool={d}/{d} accepted={d}",
            .{ cfd, io.n, g_lp.pool.len, event.pool_cap, g_lp.pool.accepted },
        );
    }

    // ---- ③ 非阻塞 recv 无数据 → EAGAIN ----
    {
        const lfd = setup();
        const cfd = handshake(lfd, 3000);
        var dst: [16]u8 = undefined;
        const io = g_tbl.socks[cfd].recv(&dst);
        check(
            io.err == .again and io.n == 0 and io.pending() and g_tbl.socks[cfd].again_count == 1,
            "recv-nodata err={s} n={d} again_count={d}",
            .{ io.err.name(), io.n, g_tbl.socks[cfd].again_count },
        );
    }

    // ---- ④ poll 单 tick 的就绪集 ----
    {
        const lfd = setup();
        const cfd = handshake(lfd, 4000);
        const regs = [_]event.PollFd{.{ .fd = cfd, .events = .{ .read = true, .write = true } }};
        const n0 = g_lp.poll(&g_tbl, &regs, &g_out);
        const write_only = n0 == 1 and g_out.hasWrite(cfd) and !g_out.hasRead(cfd);
        g_tbl.socks[cfd].onSegment(.{ .kind = .data, .seq = 4001, .payload = g_payload[0..5] });
        const n1 = g_lp.poll(&g_tbl, &regs, &g_out);
        const both = n1 == 1 and g_out.hasRead(cfd) and g_out.hasWrite(cfd);
        check(
            write_only and both,
            "poll tick write_only=1 read_after_data=1 ready_total={d}",
            .{g_lp.ready_total},
        );
    }

    // ---- ⑤ 超时轮：注入 now，只到期弹 ----
    {
        _ = setup();
        _ = g_lp.wheel.insert(.{ .deadline = 3, .fd = 1, .kind = .retransmit });
        _ = g_lp.wheel.insert(.{ .deadline = 10, .fd = 2, .kind = .idle_close });
        var out: [event.max_timers]event.Timer = undefined;
        const at2 = g_lp.wheel.advance(2, &out);
        const at3 = g_lp.wheel.advance(3, &out);
        const kind = out[0].kind;
        const at10 = g_lp.wheel.advance(10, &out);
        check(
            at2 == 0 and at3 == 1 and kind == .retransmit and at10 == 1 and g_lp.wheel.len == 0,
            "wheel now=2:{d} now=3:{d}({s}) now=10:{d} fired={d} left={d}",
            .{ at2, at3, kind.name(), at10, g_lp.wheel.fired, g_lp.wheel.len },
        );
    }

    // ---- ⑥ 部分写：3 KiB → 1 KiB 缓冲 ----
    {
        const lfd = setup();
        const cfd = handshake(lfd, 6000);
        @memset(&g_payload, 0x41);
        const io1 = g_tbl.socks[cfd].send(&g_payload); // 3072 字节待发
        const io2 = g_tbl.socks[cfd].send(&g_payload);
        const held = g_payload.len - io1.n; // 调用方手里还剩多少
        check(
            io1.err == .ok and io1.n == socket.tx_cap and
                io2.err == .again and held == g_payload.len - socket.tx_cap,
            "partial-send req={d} accepted={d} retry_n={d} retry={s}",
            .{ g_payload.len, io1.n, io2.n, io2.err.name() },
        );
    }

    // ---- ⑦ 对端 FIN → CLOSE_WAIT → 本地 close → LAST_ACK → CLOSED ----
    {
        const lfd = setup();
        const cfd = handshake(lfd, 7000);
        g_tbl.deliver(cfd, .{ .kind = .fin, .seq = 7001 });
        const after_fin = g_tbl.socks[cfd].state;
        g_lp.closeConn(&g_tbl, cfd);
        const after_close = g_tbl.socks[cfd].state;
        g_tbl.deliver(cfd, .{ .kind = .ack, .seq = 7002, .ack = 1 });
        const after_ack = g_tbl.socks[cfd].state;
        check(
            after_fin == .close_wait and after_close == .last_ack and after_ack == .closed,
            "fin-path peer_fin={s} local_close={s} final_ack={s}",
            .{ after_fin.name(), after_close.name(), after_ack.name() },
        );
    }

    // ---- ⑧ 池满：两条策略各走一次 ----
    {
        const lfd = setup();
        var i: usize = 0;
        while (i < event.pool_cap) : (i += 1) {
            _ = offer(lfd, @intCast(8000 + i * 10));
            _ = g_lp.accept(&g_tbl);
        }
        _ = offer(lfd, 8900);
        const rejected_io = g_lp.accept(&g_tbl);
        const reject_ok = rejected_io.err == .pool_full and g_lp.pool.rejected == 1 and
            g_lp.pool.len == event.pool_cap;

        g_lp.pool.policy = .evict_oldest;
        const newest = offer(lfd, 8990);
        const evict_io = g_lp.accept(&g_tbl);
        const evict_ok = evict_io.err == .ok and evict_io.n == @as(usize, newest) and
            g_lp.pool.evicted == 1 and g_lp.pool.len == event.pool_cap;
        check(
            reject_ok and evict_ok,
            "pool full reject={s} rejected={d} evict fd={d} evicted={d} len={d}",
            .{ rejected_io.err.name(), g_lp.pool.rejected, g_lp.pool.last_evicted_fd, g_lp.pool.evicted, g_lp.pool.len },
        );
    }

    // ---- ⑨ 公平轮询：队首在 8 个 tick 内轮转 ----
    {
        const lfd = setup();
        const a = handshake(lfd, 9000);
        const b = handshake(lfd, 9100);
        g_tbl.socks[a].onSegment(.{ .kind = .data, .seq = 9001, .payload = "a" });
        g_tbl.socks[b].onSegment(.{ .kind = .data, .seq = 9101, .payload = "b" });
        const regs = [_]event.PollFd{
            .{ .fd = a, .events = .{ .read = true } },
            .{ .fd = b, .events = .{ .read = true } },
        };
        var head_a: u32 = 0;
        var head_b: u32 = 0;
        var t: usize = 0;
        while (t < 8) : (t += 1) {
            _ = g_lp.poll(&g_tbl, &regs, &g_out);
            if (g_out.head()) |h| {
                if (h == a) head_a += 1;
                if (h == b) head_b += 1;
            }
        }
        check(
            head_a == 4 and head_b == 4,
            "fair-rotation ticks=8 head_a={d} head_b={d} start={d}",
            .{ head_a, head_b, g_lp.start },
        );
    }

    // ---- ⑩ 空转 tick 与唤醒条件 ----
    {
        const lfd = setup();
        const cfd = handshake(lfd, 10_000);
        var t: usize = 0;
        while (t < 1000) : (t += 1) {
            _ = g_lp.poll(&g_tbl, &.{}, &g_out);
        }
        const idle_after_empty = g_lp.idle_ticks;
        const regs = [_]event.PollFd{.{ .fd = cfd, .events = .{ .read = true } }};
        g_tbl.socks[cfd].onSegment(.{ .kind = .data, .seq = 10_001, .payload = "wake" });
        const n = g_lp.poll(&g_tbl, &regs, &g_out);
        check(
            idle_after_empty == 1000 and n == 1 and g_lp.idle_ticks == 1000,
            "idle empty_ticks={d} after_wakeup idle={d} ready={d} polls={d}",
            .{ idle_after_empty, g_lp.idle_ticks, n, g_lp.polls },
        );
    }

    // ---- ⑪ 注入数据 → 可读 → 部分读 ----
    {
        const lfd = setup();
        const cfd = handshake(lfd, 11_000);
        @memset(g_payload[0..200], 0x42);
        g_tbl.socks[cfd].onSegment(.{ .kind = .data, .seq = 11_001, .payload = g_payload[0..200] });
        const readable = g_tbl.socks[cfd].readable();
        var dst: [200]u8 = undefined;
        const io1 = g_tbl.socks[cfd].recv(dst[0..100]);
        const io2 = g_tbl.socks[cfd].recv(dst[0..200]);
        const io3 = g_tbl.socks[cfd].recv(dst[0..10]);
        check(
            readable and io1.n == 100 and io2.n == 100 and io3.err == .again and
                g_tbl.socks[cfd].recv_bytes == 200,
            "inject-data readable=1 recv1={d} recv2={d} recv3={s} total={d}",
            .{ io1.n, io2.n, io3.err.name(), g_tbl.socks[cfd].recv_bytes },
        );
    }

    // ---- ⑫ 对端 RST → ECONNRESET，槽位回收 ----
    {
        const lfd = setup();
        const cfd = handshake(lfd, 12_000);
        g_tbl.socks[cfd].onSegment(.{ .kind = .data, .seq = 12_001, .payload = "stale" });
        g_tbl.deliver(cfd, .{ .kind = .rst, .seq = 12_100 });
        var dst: [16]u8 = undefined;
        const io = g_tbl.socks[cfd].recv(&dst);
        const state = g_tbl.socks[cfd].state;
        check(
            io.err == .conn_reset and state == .closed and g_tbl.socks[cfd].reset_seen,
            "peer-rst recv={s} state={s} slot_open={d}",
            .{ io.err.name(), state.name(), @intFromBool(state.isOpen()) },
        );
    }

    // ---- 读数：脚本重放指纹（不是判据，是确定性证据）----
    {
        var wire: [4 * netstub.max_segment]u8 = undefined;
        var at: usize = 0;
        at += netstub.encode(.{ .kind = .syn, .seq = 1 }, wire[at..]);
        at += netstub.encode(.{ .kind = .data, .seq = 2, .payload = "hello" }, wire[at..]);
        at += netstub.encode(.{ .kind = .fin, .seq = 7 }, wire[at..]);
        var s1 = netstub.Script{ .bytes = wire[0..at] };
        const r1 = s1.drain();
        var s2 = netstub.Script{ .bytes = wire[0..at] };
        const r2 = s2.drain();
        log.line(
            "sim: netstub segs={d} payload={d} hash=0x{x} replay=0x{x} equal={d}",
            .{ r1.segs, r1.payload, r1.hash, r2.hash, @intFromBool(r1.hash == r2.hash) },
        );
    }

    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();
    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
