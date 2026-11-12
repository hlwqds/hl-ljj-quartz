//! ch25-wifi-blob-boundary：板侧自检（13 条判据）。
//!
//! 本章的板侧证据**只有一个来源**：stub blob + 适配层 + ABI 断言在同一块
//! rv32 上跑一遍。没有 Wi-Fi、没有射频、没有 blob 链接、没有 AP——
//! `adapter.linked_real_blob` 恒为 `false`，判据 ⑩ 直接把它当被测对象。
//!
//! 十三条判据（每条一行 `check: ... ok=1/0`）：
//!
//!   ① ABI 布局：Event=20B、payload@8、Handle=4B、tag@2、
//!      BlobVTable=24+5p、HostApi=4+4+4p+4（按 8 对齐）
//!   ② 宽度/字节序假设：u8/u16/u32 宽度、usize=4、事件头小端编解码往返
//!   ③ 版本/长度/保留位：三种坏 vtable 分别被 version_mismatch /
//!      invalid_size / invalid_arg 拒绝
//!   ④ 注册表容量：4 个 blob 全注册成功，第 5 个 no_mem
//!   ⑤ 重复注册：同一 vtable 第二次注册 → duplicate
//!   ⑥ 生命周期顺序：未 attach 就 start → invalid_state；重复 attach → duplicate
//!   ⑦ 事件投递顺序：启动即投递 5 个事件，seq 严格 1..5 且种类正确
//!   ⑧ 队列满：一次投 9 个，前 8 个入队、第 9 个 no_space，drop 计数 +1
//!   ⑨ 错误码映射：9 条 esp_err_t → Errno 逐项对拍（含未知码 → fail）
//!   ⑩ 未链接：callRealBlob()/invalid 句柄/post（无 started blob）全 not_linked
//!   ⑪ 注销语义：stop+deregister 之后上行被拒、旧句柄失效、队列不再增长
//!   ⑫ 泄漏检测：attach 分配 → deinit 归还（alloc_live=0），句柄全部归还
//!   ⑬ 一帧事件闭包：3 个事件走完 poll(now_tick)+dispatch，2 逻辑 tick/帧
//!
//! 另有几行 `read:` 前缀的读数（结构长度、队列/分配计数、tick 总数），
//! 它们不是判据，只是让日志能被人肉眼对拍。
//!
//! 所有状态都在 `.bss` 里的静态变量：板侧没有堆，自检也不该依赖分配失败
//! 才能走到 verdict。

const std = @import("std");

const abi = @import("blob_abi.zig");
const adapter = @import("adapter.zig");
const blob = @import("stub_blob.zig");
const log = @import("log.zig");

var g_passed: u32 = 0;
var g_failed: u32 = 0;

/// dispatch 的落地回调：按顺序抄进 sink 缓冲，供判据 ⑦ 检查。
var sink_buf: [adapter.queue_capacity]abi.Event = undefined;
var sink_n: u32 = 0;

fn sinkFn(ev: *const abi.Event) void {
    if (sink_n < adapter.queue_capacity) sink_buf[sink_n] = ev.*;
    sink_n += 1;
}

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [180]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}

fn errName(e: abi.Errno) []const u8 {
    return switch (e) {
        .ok => "ok",
        .fail => "fail",
        .not_linked => "not_linked",
        .invalid_arg => "invalid_arg",
        .invalid_state => "invalid_state",
        .no_mem => "no_mem",
        .not_supported => "not_supported",
        .invalid_size => "invalid_size",
        .timeout => "timeout",
        .no_space => "no_space",
        .empty => "empty",
        .version_mismatch => "version_mismatch",
        .duplicate => "duplicate",
        .leaked => "leaked",
    };
}

// ---------------------------------------------------------------------------
// ① ABI 布局
// ---------------------------------------------------------------------------

fn checkAbiLayout() void {
    const p = @sizeOf(usize);
    const expect_vt = 24 + 5 * p;
    const expect_host: usize = if (p == 4) 28 else 48;
    const ok = @sizeOf(abi.Event) == 20 and
        @offsetOf(abi.Event, "len") == 2 and
        @offsetOf(abi.Event, "seq") == 4 and
        @offsetOf(abi.Event, "payload") == 8 and
        @alignOf(abi.Event) == 4 and
        @sizeOf(abi.Handle) == 4 and
        @offsetOf(abi.Handle, "tag") == 2 and
        @offsetOf(abi.BlobVTable, "init") == 24 and
        @sizeOf(abi.BlobVTable) == expect_vt and
        @sizeOf(abi.HostApi) == expect_host;
    check(ok, "abi layout event=20 payload@8 handle=4 tag@2 vtable={d} hostapi={d}", .{
        @sizeOf(abi.BlobVTable), @sizeOf(abi.HostApi),
    });
}

// ---------------------------------------------------------------------------
// ② 宽度与字节序
// ---------------------------------------------------------------------------

fn checkWidthAndEndian() void {
    var ev: abi.Event = undefined;
    ev.clear();
    ev.kind = @backingInt(abi.EventKind.sta_connected);
    ev.flags = 0x5A;
    ev.len = 0x0102; // 小端字节序下应是 02 01
    ev.seq = 0x0403_0201; // 01 02 03 04

    var raw: [8]u8 = undefined;
    abi.encodeEventHeader(&ev, &raw);
    const back = abi.decodeEventHeader(&raw);

    const ok = @sizeOf(u8) == 1 and @sizeOf(u16) == 2 and @sizeOf(u32) == 4 and
        @bitSizeOf(usize) == 32 and
        raw[0] == 0x02 and raw[1] == 0x5A and
        raw[2] == 0x02 and raw[3] == 0x01 and
        raw[4] == 0x01 and raw[5] == 0x02 and raw[6] == 0x03 and raw[7] == 0x04 and
        back.len == ev.len and back.seq == ev.seq and back.kind == ev.kind and
        abi.readLe16(raw[2..4]) == 0x0102 and abi.readLe32(raw[4..8]) == 0x0403_0201;
    check(ok, "abi width usize={d}B le(u16=0x{x} u32=0x{x}) roundtrip=1", .{
        p_size(), back.len, back.seq,
    });
}

fn p_size() usize {
    return @sizeOf(usize);
}

// ---------------------------------------------------------------------------
// ③ 版本 / 长度 / 保留位
// ---------------------------------------------------------------------------

fn checkAbiRejection() void {
    adapter.reset();
    blob.reset();
    var h: abi.Handle = abi.Handle.invalid;

    var bad_ver = blob.vt;
    bad_ver.abi_version = abi.abi_version ^ 0x0000_0001;
    const r1 = adapter.register(&bad_ver, &h);

    var bad_size = blob.vt;
    bad_size.struct_size = @sizeOf(abi.BlobVTable) - 4;
    const r2 = adapter.register(&bad_size, &h);

    var bad_res = blob.vt;
    bad_res.reserved = 7;
    const r3 = adapter.register(&bad_res, &h);

    const ok = r1 == .version_mismatch and r2 == .invalid_size and r3 == .invalid_arg and
        adapter.slotsFree() == adapter.max_blobs;
    check(ok, "abi reject version={s} size={s} reserved={s} slots_free={d}", .{
        errName(r1), errName(r2), errName(r3), adapter.slotsFree(),
    });
}

// ---------------------------------------------------------------------------
// ④ 注册表容量
// ---------------------------------------------------------------------------

fn checkRegistryCapacity() void {
    adapter.reset();
    blob.reset();
    var handles: [adapter.max_blobs]abi.Handle = undefined;
    var registered: u32 = 0;

    if (adapter.register(&blob.vt, &handles[0]) == .ok) registered += 1;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if (adapter.register(blob.extra(i), &handles[i + 1]) == .ok) registered += 1;
    }
    var fifth = blob.vt;
    fifth.name = abi.nameOf("stub-e");
    var overflow_handle: abi.Handle = abi.Handle.invalid;
    const overflow = adapter.register(&fifth, &overflow_handle);

    const ok = registered == adapter.max_blobs and overflow == .no_mem and
        adapter.handlesOutstanding() == adapter.max_blobs and
        adapter.slotsFree() == 0;
    check(ok, "registry capacity max={d} registered={d} fifth={s} free={d}", .{
        adapter.max_blobs, registered, errName(overflow), adapter.slotsFree(),
    });
}

// ---------------------------------------------------------------------------
// ⑤ 重复注册
// ---------------------------------------------------------------------------

fn checkDuplicate() void {
    adapter.reset();
    blob.reset();
    var h1: abi.Handle = abi.Handle.invalid;
    var h2: abi.Handle = abi.Handle.invalid;
    const first = adapter.register(&blob.vt, &h1);
    const second = adapter.register(&blob.vt, &h2);
    const ok = first == .ok and second == .duplicate and
        adapter.handlesOutstanding() == 1 and h1.tag == abi.handle_tag;
    check(ok, "duplicate first={s} second={s} outstanding={d}", .{
        errName(first), errName(second), adapter.handlesOutstanding(),
    });
}

// ---------------------------------------------------------------------------
// ⑥ 生命周期顺序
// ---------------------------------------------------------------------------

fn checkLifecycleOrder() void {
    adapter.reset();
    blob.reset();
    var h: abi.Handle = abi.Handle.invalid;
    _ = adapter.register(&blob.vt, &h);

    const start_early = adapter.start(h);
    const attach1 = adapter.attach(h);
    const attach2 = adapter.attach(h);
    const ok = start_early == .invalid_state and attach1 == .ok and attach2 == .duplicate and
        blob.init_calls == 1 and adapter.allocLive() == 1;
    check(ok, "lifecycle start_before_attach={s} attach={s} attach_again={s} init={d}", .{
        errName(start_early), errName(attach1), errName(attach2), blob.init_calls,
    });
}

// ---------------------------------------------------------------------------
// ⑦ 事件投递顺序
// ---------------------------------------------------------------------------

fn checkEventOrder() void {
    adapter.reset();
    blob.reset();
    sink_n = 0;
    adapter.setSink(sinkFn);

    var h: abi.Handle = abi.Handle.invalid;
    _ = adapter.register(&blob.vt, &h);
    _ = adapter.attach(h);
    blob.cfg.events_on_start = 5;

    const sr = adapter.start(h);
    const queued = adapter.queueLen();
    const delivered = adapter.dispatch();

    var ordered = true;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        if (sink_buf[i].seq != i + 1) ordered = false;
        if (sink_buf[i].kind != @backingInt(abi.EventKind.sta_connected)) ordered = false;
    }
    const ok = sr == .ok and queued == 5 and delivered == 5 and sink_n == 5 and ordered and
        adapter.queueLen() == 0;
    check(ok, "event order queued={d} delivered={d} seq=1..5 ordered={d}", .{
        queued, delivered, @intFromBool(ordered),
    });
}

// ---------------------------------------------------------------------------
// ⑧ 队列满
// ---------------------------------------------------------------------------

fn checkQueueFull() void {
    adapter.reset();
    blob.reset();
    var h: abi.Handle = abi.Handle.invalid;
    _ = adapter.register(&blob.vt, &h);
    _ = adapter.attach(h);

    blob.cfg.events_on_start = adapter.queue_capacity + 1;
    const sr = adapter.start(h);
    const drops_after_start = adapter.dropCount();

    var probe: abi.Event = undefined;
    probe.clear();
    probe.kind = @backingInt(abi.EventKind.custom);
    probe.len = 0;
    probe.seq = 999;
    const direct = adapter.post(&probe);

    const ok = sr == .ok and
        adapter.queueLen() == adapter.queue_capacity and
        drops_after_start == 1 and
        blob.dropped == 1 and
        direct == .no_space and
        adapter.dropCount() == drops_after_start + 1;
    check(ok, "queue full capacity={d} queued={d} dropped={d} direct={s}", .{
        adapter.queue_capacity, adapter.queueLen(), drops_after_start, errName(direct),
    });
}

// ---------------------------------------------------------------------------
// ⑨ 错误码映射
// ---------------------------------------------------------------------------

const MapCase = struct { esp: i32, want: abi.Errno };

fn checkErrorMapping() void {
    const cases = [_]MapCase{
        .{ .esp = adapter.esp_ok, .want = .ok },
        .{ .esp = adapter.esp_fail, .want = .fail },
        .{ .esp = adapter.esp_err_no_mem, .want = .no_mem },
        .{ .esp = adapter.esp_err_invalid_arg, .want = .invalid_arg },
        .{ .esp = adapter.esp_err_invalid_state, .want = .invalid_state },
        .{ .esp = adapter.esp_err_invalid_size, .want = .invalid_size },
        .{ .esp = adapter.esp_err_not_supported, .want = .not_supported },
        .{ .esp = adapter.esp_err_timeout, .want = .timeout },
        .{ .esp = adapter.esp_err_wifi_not_init, .want = .not_linked },
        .{ .esp = 0x1234, .want = .fail },
    };
    var bad: u32 = 0;
    for (cases) |c| {
        if (adapter.mapEsp(c.esp) != c.want) bad += 1;
    }
    check(bad == 0, "errno map cases={d} mismatched={d} esp_wifi_not_init(0x{x})=not_linked", .{
        cases.len, bad, adapter.esp_err_wifi_not_init,
    });
}

// ---------------------------------------------------------------------------
// ⑩ 未链接
// ---------------------------------------------------------------------------

fn checkNotLinked() void {
    adapter.reset();
    blob.reset();
    var ev: abi.Event = undefined;
    ev.clear();

    const real = adapter.callRealBlob();
    const start_invalid = adapter.start(abi.Handle.invalid);
    const poll_invalid = adapter.pollEvent(abi.Handle.invalid, &ev);
    const post_none = adapter.post(&ev);
    const ok = !adapter.linked_real_blob and
        real == .not_linked and
        start_invalid == .not_linked and
        poll_invalid == .not_linked and
        post_none == .not_linked;
    check(ok, "not linked linked_real={d} real={s} start={s} poll={s} post={s}", .{
        @intFromBool(adapter.linked_real_blob),
        errName(real),
        errName(start_invalid),
        errName(poll_invalid),
        errName(post_none),
    });
}

// ---------------------------------------------------------------------------
// ⑪ 注销语义
// ---------------------------------------------------------------------------

fn checkDeregister() void {
    adapter.reset();
    blob.reset();
    sink_n = 0;
    adapter.setSink(sinkFn);

    var h: abi.Handle = abi.Handle.invalid;
    _ = adapter.register(&blob.vt, &h);
    _ = adapter.attach(h);
    blob.cfg.events_on_start = 2;
    _ = adapter.start(h);
    const first_batch = adapter.dispatch();

    const stop_rc = adapter.stop(h);
    const dereg_rc = adapter.deregister(h);
    const stale_start = adapter.start(h);
    const still_known = adapter.isRegistered(h);

    // 注销之后 blob 再上行：必须 not_linked，且队列不增长。
    var ev: abi.Event = undefined;
    ev.clear();
    ev.kind = @backingInt(abi.EventKind.beacon);
    ev.seq = 77;
    const after = adapter.post(&ev);
    const queued_after = adapter.queueLen();

    const ok = stop_rc == .ok and dereg_rc == .ok and
        first_batch == 2 and
        stale_start == .not_linked and !still_known and
        after == .not_linked and queued_after == 0 and
        adapter.handlesOutstanding() == 0;
    check(ok, "deregister batch={d} stop={s} dereg={s} stale={s} post={s} queued={d}", .{
        first_batch,    errName(stop_rc), errName(dereg_rc), errName(stale_start),
        errName(after), queued_after,
    });
}

// ---------------------------------------------------------------------------
// ⑫ 泄漏检测（分配会计 + 句柄归还）
// ---------------------------------------------------------------------------

fn checkLeaks() void {
    adapter.reset();
    blob.reset();
    var h: abi.Handle = abi.Handle.invalid;
    _ = adapter.register(&blob.vt, &h);
    const attach_rc = adapter.attach(h);
    const live_after_attach = adapter.allocLive();
    _ = adapter.start(h);
    _ = adapter.stop(h);
    const deinit_rc = adapter.deinit(h);
    const live_after_deinit = adapter.allocLive();
    const dereg_rc = adapter.deregister(h);

    const ok = attach_rc == .ok and deinit_rc == .ok and dereg_rc == .ok and
        live_after_attach == 1 and live_after_deinit == 0 and
        adapter.allocTotal() == 1 and adapter.freeTotal() == 1 and
        adapter.freeErrors() == 0 and
        adapter.handlesOutstanding() == 0 and
        adapter.slotsFree() == adapter.max_blobs;
    check(ok, "leaks alloc_live={d}->{d} total={d} freed={d} errors={d} outstanding={d}", .{
        live_after_attach,   live_after_deinit,    adapter.allocTotal(),
        adapter.freeTotal(), adapter.freeErrors(), adapter.handlesOutstanding(),
    });
}

// ---------------------------------------------------------------------------
// ⑬ 一帧事件闭包的 tick 计量
// ---------------------------------------------------------------------------

fn checkFrameTicks() void {
    adapter.reset();
    blob.reset();
    sink_n = 0;
    adapter.setSink(sinkFn);

    var h: abi.Handle = abi.Handle.invalid;
    _ = adapter.register(&blob.vt, &h);
    _ = adapter.attach(h);
    blob.cfg.events_pending = 3;
    _ = adapter.start(h);

    const t0 = adapter.tickNow();
    const drain_rc = adapter.drainBlob(h);
    const queued = adapter.queueLen();
    const delivered = adapter.dispatch();
    const t1 = adapter.tickNow();

    const ticks = t1 - t0;
    // 每个事件：poll 里 1 次 now_tick + dispatch 里 1 次记账 = 2 个逻辑 tick。
    // 这不是墙钟时间，章节里不把它当性能结论。
    const per_frame = if (delivered == 0) 0 else ticks / delivered;
    const ok = drain_rc == .ok and queued == 3 and delivered == 3 and
        ticks == 6 and per_frame == 2;
    check(ok, "frame ticks={d} frames={d} per_frame={d} (logical, not wall clock)", .{
        ticks, delivered, per_frame,
    });
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

fn runChecks() bool {
    checkAbiLayout();
    checkWidthAndEndian();
    checkAbiRejection();
    checkRegistryCapacity();
    checkDuplicate();
    checkLifecycleOrder();
    checkEventOrder();
    checkQueueFull();
    checkErrorMapping();
    checkNotLinked();
    checkDeregister();
    checkLeaks();
    checkFrameTicks();
    return g_failed == 0;
}

pub fn run() bool {
    const ok = runChecks();

    // 非判据读数：把几个长度/计数摊开，便于和对端日志对拍。
    log.line("read: sizes event={d} handle={d} vtable={d} hostapi={d} ptr={d}", .{
        @sizeOf(abi.Event),   @sizeOf(abi.Handle), @sizeOf(abi.BlobVTable),
        @sizeOf(abi.HostApi), @sizeOf(usize),
    });
    log.line("read: counters post={d} drop={d} delivered={d} alloc={d}/{d} free_errors={d} tick={d}", .{
        adapter.postCount(),  adapter.dropCount(), adapter.deliveredCount(),
        adapter.allocTotal(), adapter.freeTotal(), adapter.freeErrors(),
        adapter.tickNow(),
    });
    log.line("read: stub init={d} start={d} stop={d} deinit={d} poll={d} emitted={d}", .{
        blob.init_calls,   blob.start_calls, blob.stop_calls,
        blob.deinit_calls, blob.poll_calls,  blob.emitted,
    });

    log.line("checks: passed={d} failed={d} total={d}", .{
        g_passed, g_failed, g_passed + g_failed,
    });
    return ok;
}
