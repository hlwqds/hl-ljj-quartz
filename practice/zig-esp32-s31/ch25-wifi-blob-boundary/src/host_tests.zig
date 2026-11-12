//! ch25-wifi-blob-boundary：主机侧单测（`zig build test`）。
//!
//! 被测的是三个纯逻辑模块：`blob_abi.zig`（ABI 契约）、`adapter.zig`
//! （垫片）、`stub_blob.zig`（模拟 blob）。它们不 import 硬件、不 import
//! 串口，所以在 x86_64 上直接跑；板侧 `src/selftest.zig` 用同一批模块把
//! 同样的场景再走一遍（判据行见 `../logs/ch25-boot.log`）。
//!
//! 主机与板侧的**唯一**差别是 `@sizeOf(usize)`：vtable/host api 的长度随
//! 指针宽度变化，所以断言里用公式，不用手算常数；`Event`/`Handle` 是
//! 固定宽度，两侧都是 20/4 字节。

const std = @import("std");
const abi = @import("blob_abi.zig");
const adapter = @import("adapter.zig");
const blob = @import("stub_blob.zig");

fn fresh() void {
    adapter.reset();
    blob.reset();
}

// 每个用例都从“刚上电”开始：模块级全局状态必须显式复位，
// 否则第二个用例会继承第一个用例的队列——这正是 ch25 判据 ⑫ 的动机。
fn resetAll() void {
    fresh();
}

test "abi layout: event 20B, payload@8, handle 4B, vtable 24+5p" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(abi.Event));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(abi.Event, "len"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(abi.Event, "seq"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.Event, "payload"));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(abi.Event));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(abi.Handle));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(abi.Handle, "tag"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(abi.BlobVTable, "init"));
}

test "abi vtable/host api length follow pointer width" {
    const p = @sizeOf(usize);
    try std.testing.expectEqual(@as(usize, 24) + 5 * p, @sizeOf(abi.BlobVTable));
    const expected_host: usize = if (p == 4) 28 else 48;
    try std.testing.expectEqual(expected_host, @sizeOf(abi.HostApi));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.HostApi, "post"));
    try std.testing.expectEqual(abi.host_api_magic, adapter.hostApi().magic);
}

test "abi width and little-endian event header roundtrip" {
    var ev: abi.Event = undefined;
    ev.clear();
    ev.kind = @backingInt(abi.EventKind.sta_connected);
    ev.flags = 0x5A;
    ev.len = 0x0102;
    ev.seq = 0x0403_0201;

    var raw: [8]u8 = undefined;
    abi.encodeEventHeader(&ev, &raw);
    try std.testing.expectEqual(@as(u8, 0x02), raw[2]);
    try std.testing.expectEqual(@as(u8, 0x01), raw[3]);
    try std.testing.expectEqual(@as(u8, 0x01), raw[4]);
    try std.testing.expectEqual(@as(u8, 0x04), raw[7]);

    const back = abi.decodeEventHeader(&raw);
    try std.testing.expectEqual(ev.len, back.len);
    try std.testing.expectEqual(ev.seq, back.seq);
    try std.testing.expectEqual(ev.kind, back.kind);
    try std.testing.expectEqual(@as(u16, 0x0102), abi.readLe16(raw[2..4]));
    try std.testing.expectEqual(@as(u32, 0x0403_0201), abi.readLe32(raw[4..8]));
}

test "register rejects version mismatch, bad size, dirty reserved" {
    resetAll();
    var h: abi.Handle = abi.Handle.invalid;

    var bad_ver = blob.vt;
    bad_ver.abi_version = abi.abi_version ^ 1;
    try std.testing.expectEqual(abi.Errno.version_mismatch, adapter.register(&bad_ver, &h));

    var bad_size = blob.vt;
    bad_size.struct_size = @sizeOf(abi.BlobVTable) - 4;
    try std.testing.expectEqual(abi.Errno.invalid_size, adapter.register(&bad_size, &h));

    var bad_res = blob.vt;
    bad_res.reserved = 1;
    try std.testing.expectEqual(abi.Errno.invalid_arg, adapter.register(&bad_res, &h));

    try std.testing.expectEqual(adapter.max_blobs, adapter.slotsFree());
}

test "registry capacity: 4 fit, the 5th is no_mem" {
    resetAll();
    var handles: [adapter.max_blobs]abi.Handle = undefined;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &handles[0]));
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try std.testing.expectEqual(abi.Errno.ok, adapter.register(blob.extra(i), &handles[i + 1]));
    }
    var fifth = blob.vt;
    fifth.name = abi.nameOf("stub-e");
    var overflow: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.no_mem, adapter.register(&fifth, &overflow));
    try std.testing.expectEqual(adapter.max_blobs, adapter.handlesOutstanding());
}

test "duplicate registration is rejected" {
    resetAll();
    var h1: abi.Handle = abi.Handle.invalid;
    var h2: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h1));
    try std.testing.expectEqual(abi.Errno.duplicate, adapter.register(&blob.vt, &h2));
    try std.testing.expectEqual(@as(u32, 1), adapter.handlesOutstanding());
    try std.testing.expect(h1.isValid());
}

test "lifecycle order: start before attach is invalid_state" {
    resetAll();
    var h: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h));
    try std.testing.expectEqual(abi.Errno.invalid_state, adapter.start(h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.attach(h));
    try std.testing.expectEqual(abi.Errno.duplicate, adapter.attach(h));
    try std.testing.expectEqual(@as(u32, 1), blob.init_calls);
    try std.testing.expectEqual(@as(i32, 1), adapter.allocLive());
}

test "ring queue keeps FIFO order across wraparound" {
    resetAll();
    var h: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.attach(h));
    blob.cfg.events_on_start = adapter.queue_capacity;
    try std.testing.expectEqual(abi.Errno.ok, adapter.start(h));
    try std.testing.expectEqual(@as(u32, adapter.queue_capacity), adapter.queueLen());

    // 先消费 4 条（head 前进 4），再投 4 条（tail 绕回 0..3）：
    // 如果 head/tail 的取模写错了，这里会覆盖未消费的事件。
    var ev: abi.Event = undefined;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        try std.testing.expectEqual(abi.Errno.ok, adapter.pop(&ev));
        try std.testing.expectEqual(i + 1, ev.seq);
    }
    ev.clear();
    ev.kind = @backingInt(abi.EventKind.custom);
    var seq: u32 = 100;
    i = 0;
    while (i < 4) : (i += 1) {
        ev.seq = seq;
        try std.testing.expectEqual(abi.Errno.ok, adapter.post(&ev));
        seq += 1;
    }
    try std.testing.expectEqual(abi.Errno.no_space, adapter.post(&ev));

    // 剩下的 4 条（seq 5..8）+ 刚投的 4 条（seq 100..103）必须原序出来。
    i = 0;
    while (i < 4) : (i += 1) {
        try std.testing.expectEqual(abi.Errno.ok, adapter.pop(&ev));
        try std.testing.expectEqual(i + 5, ev.seq);
    }
    i = 0;
    while (i < 4) : (i += 1) {
        try std.testing.expectEqual(abi.Errno.ok, adapter.pop(&ev));
        try std.testing.expectEqual(100 + i, ev.seq);
    }
    try std.testing.expectEqual(abi.Errno.empty, adapter.pop(&ev));
    try std.testing.expectEqual(@as(u32, 0), adapter.queueLen());
}

test "event delivery order with sink callback" {
    resetAll();
    const Sink = struct {
        var buf: [adapter.queue_capacity]abi.Event = undefined;
        var n: u32 = 0;
        fn cb(ev: *const abi.Event) void {
            if (n < adapter.queue_capacity) buf[n] = ev.*;
            n += 1;
        }
    };
    Sink.n = 0;
    adapter.setSink(Sink.cb);

    var h: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.attach(h));
    blob.cfg.events_on_start = 5;
    try std.testing.expectEqual(abi.Errno.ok, adapter.start(h));
    try std.testing.expectEqual(@as(u32, 5), adapter.dispatch());
    try std.testing.expectEqual(@as(u32, 5), Sink.n);
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(i + 1, Sink.buf[i].seq);
        try std.testing.expectEqual(@backingInt(abi.EventKind.sta_connected), Sink.buf[i].kind);
    }
}

test "queue full returns no_space and counts drops" {
    resetAll();
    var h: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.attach(h));
    blob.cfg.events_on_start = adapter.queue_capacity + 1;
    try std.testing.expectEqual(abi.Errno.ok, adapter.start(h));
    try std.testing.expectEqual(adapter.queue_capacity, adapter.queueLen());
    try std.testing.expectEqual(@as(u32, 1), adapter.dropCount());

    var ev: abi.Event = undefined;
    ev.clear();
    try std.testing.expectEqual(abi.Errno.no_space, adapter.post(&ev));
    try std.testing.expectEqual(@as(u32, 2), adapter.dropCount());
}

test "errno mapping covers the esp_err_t table" {
    const cases = [_]struct { esp: i32, want: abi.Errno }{
        .{ .esp = adapter.esp_ok, .want = .ok },
        .{ .esp = adapter.esp_fail, .want = .fail },
        .{ .esp = adapter.esp_err_no_mem, .want = .no_mem },
        .{ .esp = adapter.esp_err_invalid_arg, .want = .invalid_arg },
        .{ .esp = adapter.esp_err_invalid_state, .want = .invalid_state },
        .{ .esp = adapter.esp_err_invalid_size, .want = .invalid_size },
        .{ .esp = adapter.esp_err_not_supported, .want = .not_supported },
        .{ .esp = adapter.esp_err_timeout, .want = .timeout },
        .{ .esp = adapter.esp_err_wifi_not_init, .want = .not_linked },
        .{ .esp = 0x4321, .want = .fail },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.want, adapter.mapEsp(c.esp));
    }
}

test "not linked is answered honestly" {
    resetAll();
    var ev: abi.Event = undefined;
    ev.clear();
    try std.testing.expect(!adapter.linked_real_blob);
    try std.testing.expectEqual(abi.Errno.not_linked, adapter.callRealBlob());
    try std.testing.expectEqual(abi.Errno.not_linked, adapter.start(abi.Handle.invalid));
    try std.testing.expectEqual(abi.Errno.not_linked, adapter.pollEvent(abi.Handle.invalid, &ev));
    try std.testing.expectEqual(abi.Errno.not_linked, adapter.post(&ev));
}

test "deregister invalidates handle and rejects uplink" {
    resetAll();
    var h: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.attach(h));
    blob.cfg.events_on_start = 2;
    try std.testing.expectEqual(abi.Errno.ok, adapter.start(h));
    try std.testing.expectEqual(@as(u32, 2), adapter.dispatch());

    try std.testing.expectEqual(abi.Errno.ok, adapter.stop(h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.deregister(h));
    try std.testing.expect(!adapter.isRegistered(h));
    try std.testing.expectEqual(abi.Errno.not_linked, adapter.start(h));

    var ev: abi.Event = undefined;
    ev.clear();
    try std.testing.expectEqual(abi.Errno.not_linked, adapter.post(&ev));
    try std.testing.expectEqual(@as(u32, 0), adapter.queueLen());
    try std.testing.expectEqual(@as(u32, 0), adapter.handlesOutstanding());
}

test "alloc accounting balances and double free is caught" {
    resetAll();
    var h: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.attach(h));

    const ctx = blob.ctx;
    try std.testing.expect(ctx != null);
    const host = adapter.hostApi();
    host.free(ctx);
    try std.testing.expectEqual(@as(i32, 0), adapter.allocLive());
    try std.testing.expectEqual(@as(u32, 1), adapter.freeTotal());

    host.free(ctx); // 重复释放：必须被记账拒绝，而不是静默通过
    try std.testing.expectEqual(@as(u32, 1), adapter.freeErrors());
    try std.testing.expectEqual(@as(u32, 1), adapter.freeTotal());

    blob.ctx = null; // 上面已手工释放，避免 deinit 再释放一次
    try std.testing.expectEqual(abi.Errno.ok, adapter.deinit(h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.deregister(h));
    try std.testing.expectEqual(@as(u32, 0), adapter.handlesOutstanding());
}

test "one event frame closure costs two logical ticks" {
    resetAll();
    var h: abi.Handle = abi.Handle.invalid;
    try std.testing.expectEqual(abi.Errno.ok, adapter.register(&blob.vt, &h));
    try std.testing.expectEqual(abi.Errno.ok, adapter.attach(h));
    blob.cfg.events_pending = 3;
    try std.testing.expectEqual(abi.Errno.ok, adapter.start(h));

    const t0 = adapter.tickNow();
    try std.testing.expectEqual(abi.Errno.ok, adapter.drainBlob(h));
    try std.testing.expectEqual(@as(u32, 3), adapter.queueLen());
    try std.testing.expectEqual(@as(u32, 3), adapter.dispatch());
    const ticks = adapter.tickNow() - t0;

    try std.testing.expectEqual(@as(u32, 6), ticks);
    try std.testing.expectEqual(@as(u32, 2), ticks / 3);
}
