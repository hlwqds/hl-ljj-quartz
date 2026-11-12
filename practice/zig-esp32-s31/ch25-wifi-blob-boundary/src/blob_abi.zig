//! ch25-wifi-blob-boundary：Wi-Fi blob 边界的 ABI 定义。
//!
//! 本章不链接任何真实的 Wi-Fi 二进制（`libnet80211.a` / `libpp.a` /
//! `libcore.a`），而是把「一个闭源协议栈需要调用方提供什么」写成一份
//! 可编译、可断言、可在主机与 rv32 两侧同时校验的接口契约：
//!
//!   HostApi    —— 调用方（我们）提供给 blob 的能力表，blob 只通过它
//!                 拿事件上行通道、内存、逻辑时间。这是 IDF 里
//!                 `wifi_osi_funcs_t`（128 个函数指针 + `_version` +
//!                 `_magic`，见 components/esp_wifi/include/esp_private/
//!                 wifi_os_adapter.h:29-172）的最小可判定子集。
//!   BlobVTable —— blob 暴露给调用方的入口表：带 ABI 版本、结构长度、
//!                 名字，然后是 init/start/stop/deinit/poll 五个函数指针。
//!   Event      —— 上行事件的**值类型**，固定宽度、无指针、无填充歧义，
//!                 所以可以整块 memcpy、可以进环形队列、可以跨调用约定。
//!   Handle     —— 不透明句柄：slot + generation + tag，用来做「注销之后
//!                 旧句柄必须失效」的检查（ch25 判据 ⑩）。
//!
//! 为什么这些结构一律 `extern struct` + 固定宽度整数：
//! blob 是别的编译器（GCC/Clang 的 C 代码）、别的年代产出的，
//! Zig 的普通 struct 允许域重排，`extern struct` 才是 C ABI 的形状。
//! 指针宽度随目标变化（rv32 = 4，x86_64 = 8），所以**结构总长**不是常数，
//! 而是 `头部固定部分 + N × @sizeOf(usize)`；两侧各自的期望值在
//! `comptime` 里用同一个公式算出来，不靠人肉加法。
//!
//! 本文件不 import std，也不碰硬件：主机测试与板侧自检都直接编译它。

const builtin = @import("builtin");

/// ABI 版本：高 16 位 = major，低 16 位 = minor。
///
/// major 不同就是**不兼容**（结构布局可能变了），必须拒绝；
/// minor 只允许「新增字段到尾部 + struct_size 变大」式的兼容扩展，
/// 本章的实现要求精确相等，宁可拒绝也不猜。
pub const abi_version: u32 = 0x0001_0000; // major 1, minor 0
pub const abi_major: u16 = 1;
pub const abi_minor: u16 = 0;

/// 句柄 tag：句柄被整块复制、被 memcpy、被塞进 u32 之后，
/// 只有这个常数还认得它是「我们的」句柄。0x25A5 = 第 25 章。
pub const handle_tag: u16 = 0x25A5;

/// 结构性常数：blob 名字最多 16 字节（不保证以 0 结尾，长度由冒烟测试约定）。
pub const name_len = 16;

/// 事件负载上限（字节）。固定 12 字节：够放 MAC(6) + 通道(1) + RSSI(1)
/// + 一个 u32 序号，也让整个 `Event` 恰好 20 字节——四个事件正好 80 字节，
/// 与 ch07 的 `TrapFrame` 同宽，便于在日志里对齐。
pub const event_payload_max = 12;

/// 统一的错误码（有符号 32 位，和 `esp_err_t` 的位宽一致）。
///
/// 负值 = 失败，0 = 成功；这是本章的「errno 风格」。
/// ESP-IDF 的 `esp_err_t` 是「非 0 即失败、取值多为正数」，映射关系在
/// `adapter.mapEsp`，判据 ⑦ 逐项对拍。
pub const Errno = enum(i32) {
    ok = 0,
    fail = -1,
    /// 没有链接任何 blob 实现——这是诚实答案，不是“成功”。
    not_linked = -2,
    invalid_arg = -3,
    invalid_state = -4,
    no_mem = -5,
    not_supported = -6,
    invalid_size = -7,
    timeout = -8,
    /// 上行事件队列已满（背压，不是崩溃）。
    no_space = -9,
    /// 队列为空（poll 到“暂时没有事件”，不是错误）。
    empty = -10,
    version_mismatch = -11,
    duplicate = -12,
    /// 有句柄/内存没还回来。
    leaked = -13,
};

/// 事件种类。用 u8 存放而不是 Zig enum：ABI 里 enum 的位宽是实现定义的，
/// 这里显式声明 `EventKind = enum(u8)`，再在 `Event.kind` 里存 u8。
pub const EventKind = enum(u8) {
    none = 0,
    scan_done = 1,
    sta_connected = 2,
    sta_disconnected = 3,
    beacon = 4,
    tx_done = 5,
    custom = 0xFF,
};

/// 上行事件：值类型，可整块复制。
///
/// ```text
/// offset  field    type   size
///   0     kind     u8      1
///   1     flags    u8      1
///   2     len      u16     2   ← 小端；最大 event_payload_max
///   4     seq      u32     4   ← blob 侧单调序号
///   8     payload  [12]u8 12
/// ------------------------------
///           total 20 字节，无尾填充（4 字节对齐）
/// ```
pub const Event = extern struct {
    kind: u8,
    flags: u8,
    len: u16,
    seq: u32,
    payload: [event_payload_max]u8,

    pub fn kindOf(self: *const Event) EventKind {
        return @fromBackingInt(@intCast(self.kind));
    }

    pub fn clear(self: *Event) void {
        self.* = .{
            .kind = 0,
            .flags = 0,
            .len = 0,
            .seq = 0,
            .payload = @splat(0),
        };
    }
};

/// 不透明句柄：4 字节，全部固定宽度。
///
/// `generation` 每回收一次 slot 自增；旧句柄因此指向「同一 slot 的上一个
/// 生命周期」，校验时按 generation 拒绝（判据 ⑩ 的泄漏/陈旧句柄检查）。
pub const Handle = extern struct {
    slot: u8,
    generation: u8,
    tag: u16,

    pub const invalid = Handle{ .slot = 0xFF, .generation = 0, .tag = 0 };

    pub fn isValid(self: Handle) bool {
        return self.tag == handle_tag and self.slot != 0xFF;
    }
};

// ---------------------------------------------------------------------------
// HostApi：调用方 → blob 的能力表
// ---------------------------------------------------------------------------

/// blob 上行一个事件。返回 0 表示已入队，负值表示背压/拒绝。
pub const PostFn = *const fn (ev: *const Event) callconv(.c) i32;
/// blob 申请内存（IDF 里对应 `_malloc`，走 `heap_caps_malloc`）。
pub const AllocFn = *const fn (bytes: u32) callconv(.c) ?*anyopaque;
/// blob 归还内存（对应 `_free`）。
pub const FreeFn = *const fn (ptr: ?*anyopaque) callconv(.c) void;
/// 逻辑时间（对应 `_timer_arm_us`/`esp_timer_get_time` 那一族）。
/// 本章刻意不接真实定时器：tick 是单调计数器，章节里不声称任何实时性。
pub const TickFn = *const fn () callconv(.c) u32;

/// ```text
/// offset(rv32)  field        type      size
///   0          version       u32        4
///   4          struct_size   u32        4   ← 必须 == @sizeOf(HostApi)
///   8          post          PostFn     4
///  12          alloc         AllocFn    4
///  16          free          FreeFn     4
///  20          now_tick      TickFn     4
///  24          magic         u32        4   ← 0x25A5_0001
/// -------------------------------------------
///                 rv32 total 28 / x86_64 total 48
/// ```
pub const HostApi = extern struct {
    version: u32,
    struct_size: u32,
    post: PostFn,
    alloc: AllocFn,
    free: FreeFn,
    now_tick: TickFn,
    magic: u32,
};

pub const host_api_magic: u32 = 0x25A5_0001;

// ---------------------------------------------------------------------------
// BlobVTable：blob → 调用方的入口表
// ---------------------------------------------------------------------------

/// `api` 是调用方提供的能力表；`flags` 是调用方的启动选项（保留）。
pub const InitFn = *const fn (api: *const HostApi, flags: u32) callconv(.c) i32;
pub const StartFn = *const fn (flags: u32) callconv(.c) i32;
pub const StopFn = *const fn () callconv(.c) i32;
pub const DeinitFn = *const fn () callconv(.c) void;
/// 返回 0 = 取到一个事件（写进 `out`）；返回 `@intFromEnum(Errno.empty)` =
/// 暂时没有；其它负值 = 错误。**不允许返回 0 却不写 `out`**。
pub const PollFn = *const fn (out: *Event) callconv(.c) i32;

/// ```text
/// offset  field        type      size
///   0     abi_version  u32        4   ← 必须 == blob_abi.abi_version
///   4     struct_size  u16        2   ← 必须 == @sizeOf(BlobVTable)
///   6     reserved     u16        2   ← 必须为 0
///   8     name         [16]u8    16
///  24     init         InitFn     p
///  24+p   start        StartFn    p
///  24+2p  stop         StopFn     p
///  24+3p  deinit       DeinitFn   p
///  24+4p  poll         PollFn     p
/// -------------------------------------
///        rv32 total 44 / x86_64 total 64
/// ```
pub const BlobVTable = extern struct {
    abi_version: u32,
    struct_size: u16,
    reserved: u16,
    name: [name_len]u8,
    init: InitFn,
    start: StartFn,
    stop: StopFn,
    deinit: DeinitFn,
    poll: PollFn,
};

/// 把名字拷进 16 字节字段（不补 0 之后的语义：调用方按 ASCII 前缀比较）。
pub fn nameOf(text: []const u8) [name_len]u8 {
    var out: [name_len]u8 = @splat(0);
    const n = if (text.len > name_len) name_len else text.len;
    @memcpy(out[0..n], text[0..n]);
    return out;
}

// ---------------------------------------------------------------------------
// 固定宽度与小端假设
//
// 这些不是“注释里的约定”：blob 与调用方共享的是**字节**，不是 Zig 类型。
// 任何一个宽度假设错了，事件里的 `len`/`seq` 就会读成天书。判据 ①②⑪ 分别
// 在编译期与运行期把这几条钉住。
// ---------------------------------------------------------------------------

/// 写小端 u16。
pub fn writeLe16(dst: *[2]u8, value: u16) void {
    dst[0] = @truncate(value & 0xFF);
    dst[1] = @truncate((value >> 8) & 0xFF);
}

/// 写小端 u32。
pub fn writeLe32(dst: *[4]u8, value: u32) void {
    dst[0] = @truncate(value & 0xFF);
    dst[1] = @truncate((value >> 8) & 0xFF);
    dst[2] = @truncate((value >> 16) & 0xFF);
    dst[3] = @truncate((value >> 24) & 0xFF);
}

/// 读小端 u16。
pub fn readLe16(src: *const [2]u8) u16 {
    return @as(u16, src[0]) | (@as(u16, src[1]) << 8);
}

/// 读小端 u32。
pub fn readLe32(src: *const [4]u8) u32 {
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) |
        (@as(u32, src[3]) << 24);
}

/// 事件头在字节流里的编码（blob 侧就是按这 8 个字节下发的）。
pub fn encodeEventHeader(ev: *const Event, dst: *[8]u8) void {
    dst[0] = ev.kind;
    dst[1] = ev.flags;
    writeLe16(dst[2..4], ev.len);
    writeLe32(dst[4..8], ev.seq);
}

/// 从 8 字节头还原出 kind/flags/len/seq（payload 由调用方另取）。
pub fn decodeEventHeader(src: *const [8]u8) Event {
    var ev: Event = undefined;
    ev.clear();
    ev.kind = src[0];
    ev.flags = src[1];
    ev.len = readLe16(src[2..4]);
    ev.seq = readLe32(src[4..8]);
    return ev;
}

// ---------------------------------------------------------------------------
// 编译期断言：布局一旦漂移就编译不过，而不是“板子上跑一遍才知道”
//
// 指针宽度 p 在 rv32 是 4、x86_64 是 8；两侧用同一个公式，没有手算常数。
// ---------------------------------------------------------------------------

const ptr_size = @sizeOf(usize);

/// `HostApi` 的期望长度：4 + 4 + 4p + 4。
fn expectedHostApiSize(p: comptime_int) comptime_int {
    // 对齐：x86_64 下 4*8+12 = 44 → 向上取 8 = 48；rv32 下 28 已对齐。
    const raw = 4 + 4 + 4 * p + 4;
    const gran = if (p == 8) @as(comptime_int, 8) else 4;
    return (raw + gran - 1) / gran * gran;
}

/// `BlobVTable` 的期望长度：24 + 5p（24 已满足 4/8 对齐）。
fn expectedVTableSize(p: comptime_int) comptime_int {
    return 24 + 5 * p;
}

comptime {
    if (@sizeOf(Event) != 20) @compileError("Event 必须是 20 字节（kind/flags/len/seq/payload[12]）");
    if (@offsetOf(Event, "len") != 2) @compileError("Event.len 必须在偏移 2");
    if (@offsetOf(Event, "seq") != 4) @compileError("Event.seq 必须在偏移 4");
    if (@offsetOf(Event, "payload") != 8) @compileError("Event.payload 必须在偏移 8");
    if (@alignOf(Event) != 4) @compileError("Event 必须 4 字节对齐");

    if (@sizeOf(Handle) != 4) @compileError("Handle 必须是 4 字节（slot/generation/tag）");
    if (@offsetOf(Handle, "tag") != 2) @compileError("Handle.tag 必须在偏移 2");

    if (@offsetOf(BlobVTable, "abi_version") != 0) @compileError("abi_version 必须在偏移 0");
    if (@offsetOf(BlobVTable, "struct_size") != 4) @compileError("struct_size 必须在偏移 4");
    if (@offsetOf(BlobVTable, "name") != 8) @compileError("name 必须在偏移 8");
    if (@offsetOf(BlobVTable, "init") != 24) @compileError("init 必须在偏移 24");
    if (@sizeOf(BlobVTable) != expectedVTableSize(ptr_size))
        @compileError("BlobVTable 长度必须是 24 + 5*sizeof(ptr)");

    if (@offsetOf(HostApi, "version") != 0) @compileError("HostApi.version 必须在偏移 0");
    if (@offsetOf(HostApi, "struct_size") != 4) @compileError("HostApi.struct_size 必须在偏移 4");
    if (@offsetOf(HostApi, "post") != 8) @compileError("HostApi.post 必须在偏移 8");
    if (@sizeOf(HostApi) != expectedHostApiSize(ptr_size))
        @compileError("HostApi 长度与公式不符（4+4+4*sizeof(ptr)+4，按 8 对齐）");

    // 固定宽度：blob 眼里只有字节。
    if (@sizeOf(u8) != 1 or @sizeOf(u16) != 2 or @sizeOf(u32) != 4) @compileError("整数宽度不是 1/2/4");
    if (@bitSizeOf(u16) != 16 or @bitSizeOf(u32) != 32) @compileError("整数位宽不对");
    if (ptr_size != 4 and ptr_size != 8) @compileError("只支持 32/64 位指针目标");

    // 目标 ABI：rv32 必须 4 字节指针、eabihf；否则本章的“固定 20 字节事件”
    // 一跨调用约定就可能被对齐规则改掉。
    if (builtin.cpu.arch == .riscv32) {
        if (ptr_size != 4) @compileError("riscv32 上指针必须是 4 字节");
        if (@alignOf(u64) != 8) @compileError("riscv32 ilp32 上 u64 对齐应为 8");
    }
}
