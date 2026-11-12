//! ch20-tcp-state-machine：板侧自检（注入路径，不开网卡）。
//!
//! 本章的正餐在主机侧：`zig build test` 覆盖段编解码、seq 算术、状态机、
//! RTO/退避、重组。板侧**只回答一个问题**：同一份纯逻辑在 rv32 + 真实 SRAM
//! 布局下，能不能把十个场景各走一遍——
//!
//!   ① 三次握手（主动与被动）        ② MSS 分段（3000 B → 3 段）
//!   ③ 单段丢失 + 注入 tick 重传      ④ 乱序到达的有界重组
//!   ⑤ 重复 ACK 与快速重传           ⑥ 主动关闭 → TIME_WAIT（注入 2MSL）
//!   ⑦ 被动关闭 CLOSE_WAIT → LAST_ACK ⑧ RST 立刻回 CLOSED
//!   ⑨ 已知样例的 TCP 校验和          ⑩ seq 回绕比较
//!
//! 外加两条结构判据：选项解析（MSS/WS/SACK）与段编解码往返。
//!
//! **所有段都是内存里的自造字节数组**：没有 MAC、没有 IP 收发、没有中断。
//! 因此“TCP 在你的网络里能握手”**不是**本章的结论——那要 ch17（MAC/DMA）
//! 与 ch18（IPv4/ARP）闭环之后才能验；本章只证明状态机与算术本身。
//!
//! 输出是判读行（`check: ... ok=1/0`），最后一行 `checks: passed=.. failed=..`。
//! 这些值来自 2026-11-13 的真机串口
//! （`practice/zig-esp32-s31/logs/ch20-boot.log`）。

const std = @import("std");

const checksum = @import("checksum.zig");
const tcp = @import("tcp.zig");

const log = @import("log.zig");
const trap = @import("trap.zig");

/// 自造的四元组。地址只用于伪首部，报文不会离开内存。
const src_ip = [4]u8{ 192, 168, 1, 10 };
const dst_ip = [4]u8{ 192, 168, 1, 1 };
const cli_port: u16 = 50000;
const srv_port: u16 = 8000;
const cli_iss: u32 = 0x1000;
const srv_iss: u32 = 0x9000;

var g_seg: [600]u8 = undefined;
var g_seg2: [600]u8 = undefined;
var g_out: [512]u8 = undefined;
var g_seq_plan: [8]tcp.Slice = undefined;

var g_passed: u32 = 0;
var g_failed: u32 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

/// 造一个客户端 → 服务端的段（已填好校验和），返回切片。
fn buildClient(buf: []u8, seq: u32, ack: u32, flags: tcp.Flags, payload: []const u8) !usize {
    const n = try tcp.encode(.{
        .src_port = cli_port,
        .dst_port = srv_port,
        .seq = seq,
        .ack = ack,
        .flags = flags,
        .window = 8192,
    }, .{}, payload, buf);
    _ = checksum.fillTcp(src_ip, dst_ip, buf[0..n]);
    return n;
}

/// 造一个服务端 → 客户端的段。`opts` 只在 SYN/SYN-ACK 里给。
fn buildServer(buf: []u8, seq: u32, ack: u32, flags: tcp.Flags, opts: tcp.Options, payload: []const u8) !usize {
    const n = try tcp.encode(.{
        .src_port = srv_port,
        .dst_port = cli_port,
        .seq = seq,
        .ack = ack,
        .flags = flags,
        .window = 65535,
    }, opts, payload, buf);
    _ = checksum.fillTcp(dst_ip, src_ip, buf[0..n]);
    return n;
}

pub fn run() bool {
    // -----------------------------------------------------------------
    // ⑨ 已知 TCP 校验和（ch16 的 SYN 向量，独立实现必须复现同一值）
    // -----------------------------------------------------------------
    {
        const known = [_]u8{
            0x1f, 0x90, 0x00, 0x50,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x50, 0x02, 0x20, 0x00,
            0x00, 0x00, 0x00, 0x00,
        };
        var buf: [20]u8 = undefined;
        @memcpy(&buf, &known);
        const c = checksum.fillTcp(src_ip, dst_ip, &buf);
        const verified = checksum.verifyTcp(src_ip, dst_ip, &buf);
        check(c == 0xeca5 and verified,
            "checksum syn_seg=0x{x} verify={d} known=0xeca5",
            .{ c, @intFromBool(verified) });
    }

    // -----------------------------------------------------------------
    // ⑩ seq 回绕比较：0xFFFFFFF0 < 0x10 必须在模空间里为真
    // -----------------------------------------------------------------
    {
        const lt = tcp.seqLt(0xFFFF_FFF0, 0x0000_0010);
        const gt = tcp.seqGt(0x0000_0010, 0xFFFF_FFF0);
        const d = tcp.seqDiff(0x0000_0010, 0xFFFF_FFF0);
        check(lt and gt and d == 0x20,
            "seq wrap 0xfffffff0<0x10={d} diff=0x{x}",
            .{ @intFromBool(lt), d });
    }

    // -----------------------------------------------------------------
    // 选项解析 + 段编解码往返（结构判据）
    // -----------------------------------------------------------------
    {
        const opts = tcp.Options{ .mss = 1460, .window_scale = 7, .sack_permitted = true };
        const n = buildServer(&g_seg, srv_iss, 0, .{ .syn = true }, opts, "") catch
            trap.panic("selftest: build syn", .{});
        const seg = tcp.parse(g_seg[0..n]) catch trap.panic("selftest: parse syn", .{});
        const ok = seg.opts.mss == 1460 and seg.opts.window_scale == 7 and
            seg.opts.sack_permitted and seg.hdr.data_offset == 8 and
            seg.hdr.seq == srv_iss and seg.payload.len == 0;
        check(ok, "options mss={d} ws={d} sack={d} hdr={d}B roundtrip=1", .{
            seg.opts.mss orelse 0,
            seg.opts.window_scale orelse 0,
            @intFromBool(seg.opts.sack_permitted),
            seg.headerLen(),
        });
    }

    // -----------------------------------------------------------------
    // ① 三次握手（主动打开）
    // -----------------------------------------------------------------
    {
        var conn = tcp.Conn{};
        const syn = conn.activeOpen(cli_iss, 0);
        const syn_ok = syn.send and syn.flags.syn and !syn.flags.ack and conn.state == .syn_sent;

        const n = buildServer(&g_seg, srv_iss, cli_iss + 1, .{ .syn = true, .ack = true }, .{ .mss = 1460 }, "") catch
            trap.panic("selftest: build syn-ack", .{});
        const seg = tcp.parse(g_seg[0..n]) catch trap.panic("selftest: parse syn-ack", .{});
        const ack = conn.onSegment(seg, 1_000);

        const ok = syn_ok and conn.state == .established and
            conn.snd_una == cli_iss + 1 and conn.rcv_nxt == srv_iss + 1 and
            ack.send and ack.flags.ack and ack.seq == cli_iss + 1 and ack.ack == srv_iss + 1;
        check(ok, "handshake state={s} snd_una=0x{x} rcv_nxt=0x{x} third=ACK", .{
            conn.state.name(), conn.snd_una, conn.rcv_nxt,
        });
    }

    // -----------------------------------------------------------------
    // ② MSS 分段：3000 字节载荷 / MSS 1460 → 3 段（1460 + 1460 + 80）
    // -----------------------------------------------------------------
    {
        const count = tcp.planSegments(0x2000, 3000, 1460, &g_seq_plan);
        const ok = count == 3 and
            g_seq_plan[0].offset == 0 and g_seq_plan[0].len == 1460 and
            g_seq_plan[1].offset == 1460 and g_seq_plan[1].len == 1460 and
            g_seq_plan[2].offset == 2920 and g_seq_plan[2].len == 80 and
            g_seq_plan[2].seq == 0x2000 + 2920;
        check(ok, "mss segs={d} lens={d}/{d}/{d} last_seq=0x{x}", .{
            count,
            g_seq_plan[0].len,
            g_seq_plan[1].len,
            if (count > 2) g_seq_plan[2].len else 0,
            if (count > 2) g_seq_plan[2].seq else 0,
        });
    }

    // -----------------------------------------------------------------
    // ③ RTO 估计 + 单段丢失（注入 tick，不真等）
    // -----------------------------------------------------------------
    {
        var conn = tcp.Conn{};
        _ = conn.activeOpen(cli_iss, 0);
        const n = buildServer(&g_seg, srv_iss, cli_iss + 1, .{ .syn = true, .ack = true }, .{ .mss = 1460 }, "") catch
            trap.panic("selftest: rto syn-ack", .{});
        _ = conn.onSegment(tcp.parse(g_seg[0..n]) catch trap.panic("selftest: rto parse", .{}), 100);

        // 一个 2 s 的 RTT 样本：SRTT=2s、RTTVAR=1s、RTO=6s（K=4）。
        _ = conn.sampleRtt(2_000_000);
        const rto_first = conn.rto.rto_us;
        _ = conn.sendData(100, 1_000);
        const before = conn.tick(1_000 + rto_first - 1);
        const fire = conn.tick(1_000 + rto_first);
        const ok = before.send == false and fire.send and fire.retransmit and
            fire.seq == cli_iss + 1 and fire.payload_len == 100 and
            rto_first == 6_000_000 and conn.rto.rto_us == 12_000_000 and
            conn.timer.retries == 1 and !conn.sampleRtt(500);
        check(ok, "rto srtt={d}us rttvar={d}us first_rto={d}us backoff={d}us retrans=1", .{
            conn.rto.srtt_us, conn.rto.rttvar_us, rto_first, conn.rto.rto_us,
        });
    }

    // -----------------------------------------------------------------
    // ④ 乱序到达：后段先到、前段补上后一次交付 200 字节且逐字节相同
    // -----------------------------------------------------------------
    {
        var payload: [200]u8 = undefined;
        for (&payload, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 251);

        var reasm = tcp.Reasm.init(0x3000);
        const late = reasm.insert(0x3000 + 100, payload[100..200], &g_out);
        const early = reasm.insert(0x3000, payload[0..100], &g_out);
        const identical = early == 200 and std.mem.eql(u8, payload[0..200], g_out[0..200]);
        check(late == 0 and identical and reasm.pendingBytes() == 0,
            "reasm out_of_order late={d} delivered={d} identical={d}",
            .{ late, early, @intFromBool(identical) });
    }

    // -----------------------------------------------------------------
    // ⑤ 重复 ACK：三个才能触发快速重传
    // -----------------------------------------------------------------
    {
        var conn = tcp.Conn{};
        _ = conn.activeOpen(cli_iss, 0);
        var n = buildServer(&g_seg, srv_iss, cli_iss + 1, .{ .syn = true, .ack = true }, .{}, "") catch
            trap.panic("selftest: dupack syn-ack", .{});
        _ = conn.onSegment(tcp.parse(g_seg[0..n]) catch trap.panic("selftest: dupack parse", .{}), 0);
        _ = conn.sendData(200, 0);

        var act = tcp.Action{};
        var i: u32 = 0;
        while (i < 3) : (i += 1) {
            n = buildServer(&g_seg2, srv_iss + 1, cli_iss + 1, .{ .ack = true }, .{}, "") catch
                trap.panic("selftest: dupack build", .{});
            act = conn.onSegment(tcp.parse(g_seg2[0..n]) catch trap.panic("selftest: dupack parse2", .{}), 100 + i);
        }
        const ok = conn.fast_retransmits == 1 and act.send and act.retransmit and
            act.seq == cli_iss + 1 and conn.snd_una == cli_iss + 1;
        check(ok, "dupack n=3 fast_retransmit={d} seq=0x{x}", .{
            conn.fast_retransmits, act.seq,
        });
    }

    // -----------------------------------------------------------------
    // ⑥ 主动关闭 → TIME_WAIT；2MSL 用注入时钟判定（不真等 60 s）
    // -----------------------------------------------------------------
    {
        var conn = tcp.Conn{};
        _ = conn.activeOpen(cli_iss, 0);
        var n = buildServer(&g_seg, srv_iss, cli_iss + 1, .{ .syn = true, .ack = true }, .{}, "") catch
            trap.panic("selftest: close syn-ack", .{});
        _ = conn.onSegment(tcp.parse(g_seg[0..n]) catch trap.panic("selftest: close parse", .{}), 0);

        const fin = conn.appClose(1_000);
        const fw1 = conn.state == .fin_wait_1 and fin.flags.fin;
        n = buildServer(&g_seg2, srv_iss + 1, fin.seq + 1, .{ .ack = true }, .{}, "") catch
            trap.panic("selftest: close ack fin", .{});
        _ = conn.onSegment(tcp.parse(g_seg2[0..n]) catch trap.panic("selftest: close parse2", .{}), 2_000);
        const fw2 = conn.state == .fin_wait_2;

        n = buildServer(&g_seg2, srv_iss + 1, fin.seq + 1, .{ .fin = true, .ack = true }, .{}, "") catch
            trap.panic("selftest: close fin", .{});
        const ack = conn.onSegment(tcp.parse(g_seg2[0..n]) catch trap.panic("selftest: close parse3", .{}), 3_000);
        const tw = conn.state == .time_wait and ack.send;

        // 差 1 µs 还在 TIME_WAIT；到 2MSL 才回 CLOSED。
        _ = conn.tick(3_000 + tcp.TIME_WAIT_US - 1);
        const still = conn.state == .time_wait;
        _ = conn.tick(3_000 + tcp.TIME_WAIT_US);
        const closed = conn.state == .closed;

        check(fw1 and fw2 and tw and still and closed,
            "close active FIN_WAIT_1->2->TIME_WAIT 2msl={d}us closed={d}",
            .{ tcp.TIME_WAIT_US, @intFromBool(closed) });
    }

    // -----------------------------------------------------------------
    // ⑦ 被动关闭：CLOSE_WAIT → LAST_ACK → CLOSED
    // -----------------------------------------------------------------
    {
        var conn = tcp.Conn{};
        conn.listen(srv_iss);
        var n = buildClient(&g_seg, cli_iss, 0, .{ .syn = true }, "") catch
            trap.panic("selftest: passive syn", .{});
        _ = conn.onSegment(tcp.parse(g_seg[0..n]) catch trap.panic("selftest: passive parse", .{}), 0);
        n = buildClient(&g_seg2, cli_iss + 1, srv_iss + 1, .{ .ack = true }, "") catch
            trap.panic("selftest: passive ack", .{});
        _ = conn.onSegment(tcp.parse(g_seg2[0..n]) catch trap.panic("selftest: passive parse2", .{}), 10);
        const est = conn.state == .established;

        n = buildClient(&g_seg2, cli_iss + 1, srv_iss + 1, .{ .fin = true, .ack = true }, "") catch
            trap.panic("selftest: passive fin", .{});
        const ack = conn.onSegment(tcp.parse(g_seg2[0..n]) catch trap.panic("selftest: passive parse3", .{}), 20);
        const cw = conn.state == .close_wait and conn.rcv_nxt == cli_iss + 2;

        const fin = conn.appClose(30);
        const la = conn.state == .last_ack and fin.flags.fin;
        n = buildClient(&g_seg2, cli_iss + 2, fin.seq + 1, .{ .ack = true }, "") catch
            trap.panic("selftest: passive lastack", .{});
        _ = conn.onSegment(tcp.parse(g_seg2[0..n]) catch trap.panic("selftest: passive parse4", .{}), 40);

        check(est and cw and la and ack.send and conn.state == .closed,
            "close passive CLOSE_WAIT->LAST_ACK->CLOSED rcv_nxt=0x{x}", .{conn.rcv_nxt});
    }

    // -----------------------------------------------------------------
    // ⑧ RST：立刻回 CLOSED，且不回任何段
    // -----------------------------------------------------------------
    {
        var conn = tcp.Conn{};
        _ = conn.activeOpen(cli_iss, 0);
        const n = buildServer(&g_seg, srv_iss, cli_iss + 1, .{ .rst = true, .ack = true }, .{}, "") catch
            trap.panic("selftest: rst build", .{});
        const act = conn.onSegment(tcp.parse(g_seg[0..n]) catch trap.panic("selftest: rst parse", .{}), 0);
        const ok = conn.state == .closed and !act.send and !conn.timer.active;
        check(ok, "rst state={s} replied={d} timer={s}", .{
            conn.state.name(), @intFromBool(act.send), if (conn.timer.active) "on" else "off",
        });
    }

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return g_failed == 0;
}
