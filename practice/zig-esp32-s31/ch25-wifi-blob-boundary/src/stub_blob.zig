//! ch25-wifi-blob-boundary：模拟 blob（stub）。
//!
//! 它扮演 `libnet80211.a` 的角色，但**只有接口形状是真的**：入口表、版本
//! 字段、结构长度、事件上行、错误码注入全部按 `blob_abi.zig` 的定义来，
//! 内部没有一行 802.11 代码。这样适配层的每一条分支（注册/启动/取事件/
//! 背压/停止/注销/错误注入）都能在主机与板侧各跑一遍，而不需要一个
//! 能连上 AP 的射频。
//!
//! `stub` 的行为由 `Config` 驱动：注入错误码、控制启动时吐几个事件、
//! 让 `poll` 吐出的事件数可数。所有计数器都是全局的（板侧没有堆，
//! 也不该为了自检引入分配）。

const abi = @import("blob_abi.zig");

pub const Config = struct {
    /// 启动时立即通过 HostApi.post 投递的事件数（模拟 blob 的异步回调）。
    events_on_start: u32 = 0,
    /// 之后由 poll 取出的事件数（模拟 blob 的内部队列）。
    events_pending: u32 = 0,
    /// `start` 的返回值（0 = 成功，其它按 esp_err_t 注入）。
    start_rc: i32 = 0,
    /// `stop` 的返回值。
    stop_rc: i32 = 0,
    /// `poll` 的返回值覆盖（<0 表示直接返回该错误，用于注入）。
    poll_rc: i32 = 0,
};

pub var cfg: Config = .{};

pub var api: ?*const abi.HostApi = null;
pub var ctx: ?*anyopaque = null;
pub var started: bool = false;
pub var last_flags: u32 = 0;
pub var seq: u32 = 0;
pub var emitted: u32 = 0;
pub var pending: u32 = 0;
pub var dropped: u32 = 0;

pub var init_calls: u32 = 0;
pub var start_calls: u32 = 0;
pub var stop_calls: u32 = 0;
pub var deinit_calls: u32 = 0;
pub var poll_calls: u32 = 0;

pub fn reset() void {
    cfg = .{};
    api = null;
    ctx = null;
    started = false;
    last_flags = 0;
    seq = 0;
    emitted = 0;
    pending = 0;
    dropped = 0;
    init_calls = 0;
    start_calls = 0;
    stop_calls = 0;
    deinit_calls = 0;
    poll_calls = 0;
    vt = makeVTable("stub-blob");
}

// ---------------------------------------------------------------------------
// 入口表
// ---------------------------------------------------------------------------

fn makeVTable(comptime name: []const u8) abi.BlobVTable {
    return .{
        .abi_version = abi.abi_version,
        .struct_size = @sizeOf(abi.BlobVTable),
        .reserved = 0,
        .name = abi.nameOf(name),
        .init = initFn,
        .start = startFn,
        .stop = stopFn,
        .deinit = deinitFn,
        .poll = pollFn,
    };
}

/// 主入口表。判据 ② 会把它拷一份、改坏版本/长度后要求 `register` 拒绝。
pub var vt: abi.BlobVTable = makeVTable("stub-blob");

/// 额外三份（名字不同、函数相同），供判据 ③ 的容量边界使用。
pub var vt_extra: [3]abi.BlobVTable = .{
    makeVTable("stub-b"),
    makeVTable("stub-c"),
    makeVTable("stub-d"),
};

pub fn extra(i: usize) *const abi.BlobVTable {
    return &vt_extra[i];
}

// ---------------------------------------------------------------------------
// 入口函数（全部 C 调用约定：跨的是 ABI 边界，不是 Zig 模块边界）
// ---------------------------------------------------------------------------

fn nowApi() ?*const abi.HostApi {
    return api;
}

/// 构造一个事件并通过 HostApi.post 上行。返回适配层给的 Errno 整数。
fn emit(kind: abi.EventKind, payload_word: u32) i32 {
    const host = nowApi() orelse return @backingInt(abi.Errno.not_linked);
    seq +%= 1;
    var ev: abi.Event = undefined;
    ev.clear();
    ev.kind = @backingInt(kind);
    ev.len = 4;
    ev.seq = seq;
    abi.writeLe32(ev.payload[0..4], payload_word);
    const rc = host.post(&ev);
    if (rc == 0) {
        emitted += 1;
    } else {
        dropped += 1;
    }
    return rc;
}

fn initFn(api_in: *const abi.HostApi, flags: u32) callconv(.c) i32 {
    init_calls += 1;
    api = api_in;
    last_flags = flags;
    if (api_in.struct_size != @sizeOf(abi.HostApi)) return @backingInt(abi.Errno.invalid_size);
    if (api_in.magic != abi.host_api_magic) return @backingInt(abi.Errno.invalid_size);
    if (api_in.version != abi.abi_version) return @backingInt(abi.Errno.version_mismatch);
    // 像真 blob 一样，申请一块自己的上下文（判据 ⑫ 盯的就是这笔账）。
    ctx = api_in.alloc(64);
    if (ctx == null) return @backingInt(abi.Errno.no_mem);
    return 0;
}

fn startFn(flags: u32) callconv(.c) i32 {
    start_calls += 1;
    last_flags = flags;
    if (cfg.start_rc != 0) return cfg.start_rc;
    started = true;
    pending = cfg.events_pending;
    var i: u32 = 0;
    while (i < cfg.events_on_start) : (i += 1) {
        // 启动时立即投递：这是真 blob 在 init 完成时“顺手 e 告知”的形状。
        _ = emit(.sta_connected, i);
    }
    return 0;
}

fn stopFn() callconv(.c) i32 {
    stop_calls += 1;
    started = false;
    pending = 0;
    return cfg.stop_rc;
}

fn deinitFn() callconv(.c) void {
    deinit_calls += 1;
    if (api) |host| {
        if (ctx) |p| host.free(p);
    }
    ctx = null;
}

fn pollFn(out: *abi.Event) callconv(.c) i32 {
    poll_calls += 1;
    if (!started) return @backingInt(abi.Errno.invalid_state);
    if (cfg.poll_rc < 0) return cfg.poll_rc;
    if (pending == 0) return @backingInt(abi.Errno.empty);
    pending -= 1;
    seq +%= 1;
    out.clear();
    out.kind = @backingInt(abi.EventKind.beacon);
    out.len = 8;
    out.seq = seq;
    abi.writeLe32(out.payload[0..4], seq);
    // 像真 blob 一样给事件打时间戳：这一下 now_tick 是判据 ⑬ 的计时单位
    // （逻辑 tick，不是 wall clock）。
    if (api) |host| {
        abi.writeLe32(out.payload[4..8], host.now_tick());
    }
    emitted += 1;
    return 0;
}
