//! ch25-wifi-blob-boundary：适配层（chapter 的「垫片」）。
//!
//! 这一层的职责一句话说完：**把 blob 的入口表翻译成本工程的调用面，
//! 把 blob 的错误码翻译成本工程的 Errno，把 blob 的上行事件收进一个
//! 定长环形队列，并且在没有任何 blob 链接进来的时候诚实地说 `not_linked`。**
//!
//! ## 并发假设（写清楚，而不是默认）
//!
//! 本章的形态 B 骨架里 `mstatus.MIE = 0`、没有中断、没有调度器、没有堆
//! （见 `src/start.zig` 第 1 步与 `linker/s31.ld` 的堆区注释）。因此本文件
//! **完全不设锁**，所有函数都必须在同一个「主循环」上下文里调用。
//!
//! 真实 IDF 里 blob 会从 Wi-Fi 任务甚至中断里回调（`_queue_send_from_isr`、
//! `_is_from_isr` 就是为这个存在的，见 wifi_os_adapter.h:37-38）。所以本文件
//! 的 `post()` 是唯一一个「会被外部上下文调用」的入口，它的形状刻意做成
//! 单写者环形队列的 push：只要有中断屏蔽（`csrci mstatus,8` / restore）就能
//! 直接升级成 ISR-safe，不需要改数据结构。这条假设是本章的**边界**，不是
//! 实现细节：判据 ⑥（队列满）与判据 ⑫（一帧处理 tick 数）都建立在它上面。
//!
//! ## 分配器
//!
//! `alloc/free` 后面是一个 512 字节的静态 bump 池：每块前面有 8 字节头
//! （魔数 + 长度），`free` 校验魔数、把会计减回去，重复释放会被记成
//! `free_errors` 而不是静默通过。**内存不会被真正复用**（bump 池没有回收
//! 路径），真正的回收发生在 `reset()`。所以这里的「泄漏检测」看的是
//! **会计是否平衡**（判据 ⑫），而不是水位——章节里不夸大这一点。

const abi = @import("blob_abi.zig");

/// 注册表容量。4 是刻意的：一个 WiFi + 一个 coex + 两个预留，
/// 判据 ③ 要求第 5 次注册返回 `no_mem`。
pub const max_blobs = 4;

/// 上行事件队列容量。8 是判据 ⑥ 的边界值。
pub const queue_capacity = 8;

/// 静态分配池：512 字节，8 字节对齐。
pub const pool_size = 512;

/// **本章没有链接任何真实 Wi-Fi blob**。
///
/// 这个常量不是注释，而是判据 ⑨ 的被测对象：它决定了 `callRealBlob()` 的
/// 返回值。等真实 blob 接进来时，只需把它改成 `true` 并接上 vtable 指针，
/// 判据 ⑨ 会自动从「未链接」切换成「已链接」的期望。在这之前，
/// 任何“Wi-Fi 可用”的说法都是假的。
pub const linked_real_blob = false;

const State = enum(u8) { free, registered, started };

const Slot = struct {
    state: State = .free,
    /// 每次回收 +1；旧句柄因此指向“上一个生命周期”而被拒。
    generation: u8 = 0,
    vtable: ?*const abi.BlobVTable = null,
    /// 是否已经把自己的 HostApi 交给 blob（`attach` 完成）。
    attached: bool = false,
    /// 该 slot 累计收到的事件数（诊断用读数）。
    events: u32 = 0,
};

var slots: [max_blobs]Slot = @splat(.{});

var queue_buf: [queue_capacity]abi.Event = undefined;
var queue_head: u32 = 0;
var queue_len: u32 = 0;

var pool: [pool_size]u8 align(8) = undefined;
var pool_used: usize = 0;

var alloc_live: i32 = 0;
var alloc_total: u32 = 0;
var free_total: u32 = 0;
var free_errors: u32 = 0;

var post_count: u32 = 0;
var drop_count: u32 = 0;
var delivered: u32 = 0;
var tick: u32 = 0;

/// 事件落地回调（上层把它们变成状态机迁移）。可为空。
pub const Sink = *const fn (ev: *const abi.Event) void;
var sink: ?Sink = null;

/// 块头：魔数 + 长度。`free` 用它抓重复释放/野指针。
const block_magic: u32 = 0x25B10C4B;

pub const Header = extern struct {
    magic: u32,
    len: u32,
};

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

/// 把全局状态恢复到上电态。主机测试每个用例前调用；板侧只在自检开头调用。
pub fn reset() void {
    slots = @splat(.{});
    queue_head = 0;
    queue_len = 0;
    pool_used = 0;
    alloc_live = 0;
    alloc_total = 0;
    free_total = 0;
    free_errors = 0;
    post_count = 0;
    drop_count = 0;
    delivered = 0;
    tick = 0;
    sink = null;
}

pub fn setSink(f: ?Sink) void {
    sink = f;
}

fn findSlot(h: abi.Handle) ?usize {
    if (!h.isValid()) return null;
    if (h.slot >= max_blobs) return null;
    const idx: usize = h.slot;
    if (slots[idx].state == .free) return null;
    if (slots[idx].generation != h.generation) return null;
    return idx;
}

/// 注册一个 blob 的入口表。
///
/// 校验顺序是刻意的：先版本，再长度，再保留位，最后才找 slot。
/// 这样判据 ② 能区分「版本不兼容」和「注册表满了」——两者都是拒绝，
/// 但运维含义完全不同。
pub fn register(vt: *const abi.BlobVTable, out: *abi.Handle) abi.Errno {
    if (vt.abi_version != abi.abi_version) return .version_mismatch;
    if (vt.struct_size != @sizeOf(abi.BlobVTable)) return .invalid_size;
    if (vt.reserved != 0) return .invalid_arg;

    // 同一个 vtable 重复注册 = 调用方 bug（真机上是双份初始化，必炸）。
    for (slots) |s| {
        if (s.state != .free and s.vtable == vt) return .duplicate;
    }

    var free_idx: ?usize = null;
    for (&slots, 0..) |*s, i| {
        if (s.state == .free) {
            free_idx = i;
            break;
        }
    }
    const idx = free_idx orelse return .no_mem;

    slots[idx].state = .registered;
    slots[idx].vtable = vt;
    slots[idx].events = 0;
    out.* = .{
        .slot = @intCast(idx),
        .generation = slots[idx].generation,
        .tag = abi.handle_tag,
    };
    return .ok;
}

/// 注销。要求先 `stop`：在 started 状态下直接注销会把 blob 的定时器/任务
/// 留在半初始化态——真实 IDF 里这就是“卸载 Wi-Fi 驱动”那类事故。
pub fn deregister(h: abi.Handle) abi.Errno {
    const idx = findSlot(h) orelse return .not_linked;
    switch (slots[idx].state) {
        .started => return .invalid_state,
        .free => return .not_linked,
        .registered => {},
    }
    slots[idx].state = .free;
    slots[idx].vtable = null;
    slots[idx].attached = false;
    slots[idx].generation +%= 1;
    return .ok;
}

/// 把调用方的能力表交给 blob。这是“垫片”真正开始工作的时刻：
/// blob 从这里拿到 `post/alloc/free/now_tick` 四个入口，此后它的所有外部
/// 交互都只能走这张表（对应 IDF 里 `esp_wifi_init_internal(config)` 之后
/// blob 通过 ROM 的 `g_osi_funcs_p` 找到 `g_wifi_osi_funcs`）。
pub fn attach(h: abi.Handle) abi.Errno {
    const idx = findSlot(h) orelse return .not_linked;
    if (slots[idx].state != .registered) return .invalid_state;
    if (slots[idx].attached) return .duplicate;
    const vt = slots[idx].vtable orelse return .not_linked;
    const rc = vt.init(hostApi(), 0);
    if (rc != 0) return errnoFromInt(rc);
    slots[idx].attached = true;
    return .ok;
}

pub fn start(h: abi.Handle) abi.Errno {
    const idx = findSlot(h) orelse return .not_linked;
    if (slots[idx].state != .registered) return .invalid_state;
    if (!slots[idx].attached) return .invalid_state;
    const vt = slots[idx].vtable orelse return .not_linked;
    // 先把状态置成 started 再进 blob：真 blob 在 start 期间就会开始上行
    // （连接完成事件往往在“启动函数返回之前”就已经投递）。失败时回滚。
    slots[idx].state = .started;
    const rc = vt.start(0);
    if (rc != 0) {
        slots[idx].state = .registered;
        return errnoFromInt(rc);
    }
    return .ok;
}

pub fn stop(h: abi.Handle) abi.Errno {
    const idx = findSlot(h) orelse return .not_linked;
    if (slots[idx].state != .started) return .invalid_state;
    const vt = slots[idx].vtable orelse return .not_linked;
    const rc = vt.stop();
    slots[idx].state = .registered;
    if (rc != 0) return errnoFromInt(rc);
    return .ok;
}

/// 让 blob 释放自己的上下文。此后仍需 `deregister` 归还 slot。
pub fn deinit(h: abi.Handle) abi.Errno {
    const idx = findSlot(h) orelse return .not_linked;
    if (slots[idx].state != .registered) return .invalid_state;
    if (!slots[idx].attached) return .invalid_state;
    const vt = slots[idx].vtable orelse return .not_linked;
    vt.deinit();
    slots[idx].attached = false;
    return .ok;
}

pub fn isRegistered(h: abi.Handle) bool {
    return findSlot(h) != null;
}

// ---------------------------------------------------------------------------
// 数据面
// ---------------------------------------------------------------------------

/// 从 blob 取一个事件。返回 `empty` 表示“暂时没有”，不是失败。
pub fn pollEvent(h: abi.Handle, out: *abi.Event) abi.Errno {
    const idx = findSlot(h) orelse return .not_linked;
    if (slots[idx].state != .started) return .invalid_state;
    const vt = slots[idx].vtable orelse return .not_linked;
    out.clear();
    const rc = vt.poll(out);
    if (rc != 0) return errnoFromInt(rc);
    if (out.len > abi.event_payload_max) return .invalid_size;
    return .ok;
}

/// 把 blob 当前所有就绪事件拉进上行队列（调用方侧的“收包”）。
/// 返回入队的事件数；遇到真实错误时返回该错误。
pub fn drainBlob(h: abi.Handle) abi.Errno {
    var n: u32 = 0;
    while (true) {
        var ev: abi.Event = undefined;
        const rc = pollEvent(h, &ev);
        switch (rc) {
            .ok => {
                const prc = post(&ev);
                if (prc != .ok) return prc;
                n += 1;
            },
            .empty => return if (n == 0) .empty else .ok,
            else => return rc,
        }
    }
}

/// blob 上行一个事件（由 HostApi.post 指针间接调用）。
///
/// 这是本文件唯一为“外部上下文”准备的入口：FIFO push + 满则背压。
pub fn post(ev: *const abi.Event) abi.Errno {
    post_count += 1;
    if (activeStartedSlot() == null) return .not_linked;
    if (queue_len == queue_capacity) {
        drop_count += 1;
        return .no_space;
    }
    const tail = (queue_head + queue_len) % queue_capacity;
    queue_buf[tail] = ev.*;
    queue_len += 1;
    return .ok;
}

/// 取队首事件（不经过 sink）。每条消耗 1 个逻辑 tick。
pub fn pop(out: *abi.Event) abi.Errno {
    if (queue_len == 0) return .empty;
    out.* = queue_buf[queue_head];
    queue_head = (queue_head + 1) % queue_capacity;
    queue_len -= 1;
    tick +%= 1;
    delivered += 1;
    return .ok;
}

/// 把队列里的所有事件交给 sink。返回交付条数；每条消耗 1 个逻辑 tick。
pub fn dispatch() u32 {
    var n: u32 = 0;
    var ev: abi.Event = undefined;
    while (pop(&ev) == .ok) {
        n += 1;
        if (sink) |f| f(&ev);
    }
    return n;
}

fn activeStartedSlot() ?usize {
    for (&slots, 0..) |*s, i| {
        if (s.state == .started) return i;
    }
    return null;
}

/// 本章的“真实 blob 入口”。
///
/// `linked_real_blob == false` 时它只能返回 `not_linked`——不伪装成功，
/// 也不返回一个假的事件流。这是判据 ⑨ 的全部内容。
pub fn callRealBlob() abi.Errno {
    if (!linked_real_blob) return .not_linked;
    return .not_supported; // 真接进来之前不编造路径
}

// ---------------------------------------------------------------------------
// 错误码映射：esp_err_t → 本章 Errno
// ---------------------------------------------------------------------------

pub const esp_ok: i32 = 0x0;
pub const esp_fail: i32 = -1;
pub const esp_err_no_mem: i32 = 0x101;
pub const esp_err_invalid_arg: i32 = 0x102;
pub const esp_err_invalid_state: i32 = 0x103;
pub const esp_err_invalid_size: i32 = 0x104;
pub const esp_err_not_supported: i32 = 0x106;
pub const esp_err_timeout: i32 = 0x107;
/// `ESP_ERR_WIFI_BASE + 1`：Wi-Fi 还没被 `esp_wifi_init` 装起来。
/// 它在语义上就是本章的 `not_linked`。
pub const esp_err_wifi_not_init: i32 = 0x3001;

/// blob 入口表返回的是**本章的** errno（负数）；真实 IDF 代码返回的是
/// `esp_err_t`（正数或 -1）。两种都认：正数走 ESP 映射，-1..-13 直接就是
/// 本章的枚举值（`ESP_FAIL == -1` 与 `.fail` 恰好同值，不冲突）。
pub fn errnoFromInt(rc: i32) abi.Errno {
    if (rc == 0) return .ok;
    if (rc > 0) return mapEsp(rc);
    if (rc >= -13 and rc <= -1) return @fromBackingInt(@intCast(rc));
    return .fail;
}

pub fn mapEsp(err: i32) abi.Errno {
    return switch (err) {
        esp_ok => .ok,
        esp_fail => .fail,
        esp_err_no_mem => .no_mem,
        esp_err_invalid_arg => .invalid_arg,
        esp_err_invalid_state => .invalid_state,
        esp_err_invalid_size => .invalid_size,
        esp_err_not_supported => .not_supported,
        esp_err_timeout => .timeout,
        esp_err_wifi_not_init => .not_linked,
        else => .fail,
    };
}

// ---------------------------------------------------------------------------
// HostApi 的实现（调用方 → blob）
// ---------------------------------------------------------------------------

fn hostPost(ev: *const abi.Event) callconv(.c) i32 {
    return @backingInt(post(ev));
}

fn hostAlloc(bytes: u32) callconv(.c) ?*anyopaque {
    const need: usize = @as(usize, bytes) + @sizeOf(Header);
    const aligned = (pool_used + 7) & ~@as(usize, 7);
    if (aligned + need > pool_size) return null;
    const base: [*]u8 = @ptrCast(&pool[aligned]);
    const hdr: *Header = @ptrCast(@alignCast(base));
    hdr.magic = block_magic;
    hdr.len = bytes;
    pool_used = aligned + need;
    alloc_total += 1;
    alloc_live += 1;
    return @ptrCast(base + @sizeOf(Header));
}

fn hostFree(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const raw: [*]u8 = @ptrCast(p);
    const base = raw - @sizeOf(Header);
    const hdr: *Header = @ptrCast(@alignCast(base));
    if (hdr.magic != block_magic) {
        free_errors += 1;
        return; // 重复释放或野指针：记账拒绝，不静默通过
    }
    hdr.magic = 0;
    free_total += 1;
    alloc_live -= 1;
}

fn hostNowTick() callconv(.c) u32 {
    tick +%= 1;
    return tick;
}

var host_api: abi.HostApi = .{
    .version = abi.abi_version,
    .struct_size = @sizeOf(abi.HostApi),
    .post = hostPost,
    .alloc = hostAlloc,
    .free = hostFree,
    .now_tick = hostNowTick,
    .magic = abi.host_api_magic,
};

pub fn hostApi() *const abi.HostApi {
    return &host_api;
}

// ---------------------------------------------------------------------------
// 读数（自检打印用，不参与判定）
// ---------------------------------------------------------------------------

pub fn queueLen() u32 {
    return queue_len;
}
pub fn deliveredCount() u32 {
    return delivered;
}
pub fn postCount() u32 {
    return post_count;
}
pub fn dropCount() u32 {
    return drop_count;
}
pub fn allocLive() i32 {
    return alloc_live;
}
pub fn allocTotal() u32 {
    return alloc_total;
}
pub fn freeTotal() u32 {
    return free_total;
}
pub fn freeErrors() u32 {
    return free_errors;
}
pub fn tickNow() u32 {
    return tick;
}
pub fn handlesOutstanding() u32 {
    var n: u32 = 0;
    for (slots) |s| {
        if (s.state != .free) n += 1;
    }
    return n;
}
pub fn slotsFree() u32 {
    return max_blobs - handlesOutstanding();
}
pub fn slotEvents(idx: usize) u32 {
    return slots[idx].events;
}
pub fn noteEvent(h: abi.Handle) void {
    if (findSlot(h)) |idx| slots[idx].events += 1;
}
