//! ch13-heap-stack-caps：堆的"接线层"。
//!
//! 三件事：
//!   1. 从链接脚本符号取 arena（`_heap_start` / `_heap_end`），喂给 TLSF；
//!   2. 包一层 caps 检查：请求 `dma`/`exec`/`psram` 时先问 caps 表有没有
//!      这样的区间，没有就明确拒绝，而不是先分配再让 DMA 搬不动；
//!   3. 打印预算表与统计（`heap: total=… used=… free=…`）。
//!
//! 裸机里"分配器自己写"的真正含义在这里：没有 `malloc`、没有 libc 的 arena
//! 扩展、没有 `sbrk`。堆就是 `[_heap_start, _heap_end)` 这一块静态区间，
//! 用完了就是 null——没有"向系统再要"的路径。这条约束必须在设计期接受，
//! 而不是在运行期发现。

const tlsf = @import("alloc/tlsf.zig");
const caps = @import("caps.zig");
const log = @import("log.zig");

// ---------------------------------------------------------------------------
// 链接脚本符号
//
// 这些是**地址标记**，不是变量：`&_heap_start` 才是有意义的数。
// 声明成 `extern var u8` 而不是 `extern const u8`，因为 SRAM 段可写；
// 只取地址，从不读写内容。
// ---------------------------------------------------------------------------
extern var _heap_start: u8;
extern var _heap_end: u8;
extern var _stack_top: u8;
extern var _stack_bottom: u8;
extern var _bss_start: u8;
extern var _bss_end: u8;
extern var _data_start: u8;
extern var _data_end: u8;
extern var _trap_start: u8;
extern var _trap_end: u8;
pub extern const _text_start: u8;
pub extern const _text_end: u8;
pub extern const _rodata_start: u8;
pub extern const _rodata_end: u8;
pub extern const _image_start: u8;

/// 唯一的 TLSF 实例。放在 .bss（`= .{}` 让所有字段落到零初始化）。
pub var arena: tlsf.Allocator = .{};

/// 各段起始地址的访问器（main 用它打印地址空间归类，不必自己声明链接符号）。
pub fn addrOfImage() usize {
    return @intFromPtr(&_image_start);
}
pub fn addrOfText() usize {
    return @intFromPtr(&_text_start);
}
pub fn addrOfRodata() usize {
    return @intFromPtr(&_rodata_start);
}
pub fn addrOfTrap() usize {
    return @intFromPtr(&_trap_start);
}
pub fn addrOfData() usize {
    return @intFromPtr(&_data_start);
}
pub fn addrOfBss() usize {
    return @intFromPtr(&_bss_start);
}

pub fn heapStart() usize {
    return @intFromPtr(&_heap_start);
}
pub fn heapEnd() usize {
    return @intFromPtr(&_heap_end);
}

/// 初始化 arena。`.bss` 已被 `_start` 清零，这里再显式建一次块头。
pub fn init() void {
    arena.init(heapStart(), heapEnd());
}

/// 普通分配：内部 SRAM、8 字节对齐、大小无特殊要求。
pub fn alloc(size: usize) ?usize {
    return arena.alloc(size);
}

pub fn allocAligned(size: usize, alignment: usize) ?usize {
    return arena.allocAligned(size, alignment);
}

pub fn free(ptr: usize) bool {
    return arena.free(ptr);
}

pub fn realloc(ptr: usize, size: usize) ?usize {
    return arena.realloc(ptr, size);
}

// ---------------------------------------------------------------------------
// caps 检查
// ---------------------------------------------------------------------------

pub const AllocError = error{
    /// caps 表里没有任何区间满足要求（例如要 PSRAM 但 PSRAM 没初始化）。
    CapsUnsupported,
    /// 区间存在，但没有对应的 arena 接入（本章只接了 SRAM）。
    NoArenaForCaps,
};

/// 按能力分配。本章只有 SRAM 一个 arena，所以这个函数的价值在**拒绝**：
/// 请求 PSRAM 时必须返回 `CapsUnsupported` 并打印原因，而不是悄悄给一块
/// SRAM 让上层以为可以交给 DMA/大缓冲。
pub fn allocCaps(want: caps.Caps, size: usize) AllocError!usize {
    const region = caps.find(want) orelse {
        log.line("caps: alloc(size={d}) REJECTED - no region satisfies caps {s}", .{
            size, caps.tag(want),
        });
        return AllocError.CapsUnsupported;
    };
    if (region.id == .sram) return alloc(size) orelse AllocError.NoArenaForCaps;
    // 其它区间（PSRAM / LP SRAM / flash）本章没有接 arena。
    log.line("caps: alloc(size={d}) region={s} has no arena in this chapter", .{ size, region.name });
    return AllocError.NoArenaForCaps;
}

// ---------------------------------------------------------------------------
// 打印
// ---------------------------------------------------------------------------

fn permille(part: usize, whole: usize) usize {
    if (whole == 0) return 0;
    return part * 1000 / whole;
}

/// `heap: total=… used=… free=… largest=… frag=…‰`
pub fn report(tag: []const u8) void {
    const s = arena.stats();
    // 碎片率：空闲内存里"最大的一块"占了多少。1 - largest/free。
    const frag = if (s.free == 0) 0 else 1000 - permille(s.largest, s.free);
    log.line("heap: total={d} used={d} free={d} largest={d} frag={d}permille blocks={d} tag={s}", .{
        s.arena, s.used, s.free, s.largest, frag, s.free_blocks, tag,
    });
}

/// 一次打印完整的内存预算表（本章的"验收产物"之一）。
pub fn budget() void {
    const text = @intFromPtr(&_text_end) - @intFromPtr(&_text_start);
    const rodata = @intFromPtr(&_rodata_end) - @intFromPtr(&_rodata_start);
    const trap = @intFromPtr(&_trap_end) - @intFromPtr(&_trap_start);
    const data = @intFromPtr(&_data_end) - @intFromPtr(&_data_start);
    const bss = @intFromPtr(&_bss_end) - @intFromPtr(&_bss_start);
    const heap = heapEnd() - heapStart();
    const stack = @intFromPtr(&_stack_top) - @intFromPtr(&_stack_bottom);
    const sram = 0x0008_0000; // 物理 512 KiB
    const sram_app = 0x0007_AFC0; // 应用可用（末尾 0x5040 归 bootloader）

    log.line("budget: image=0x{x} irom.text={d}B drom.rodata={d}B", .{
        @intFromPtr(&_image_start), text, rodata,
    });
    log.line("budget: sram trap={d}B data={d}B bss={d}B heap={d}B stack={d}B", .{
        trap, data, bss, heap, stack,
    });
    log.line("budget: sram_total={d}B app_usable={d}B static={d}B heap={d}permille stack={d}permille", .{
        sram,
        sram_app,
        trap + data + bss,
        permille(heap, sram_app),
        permille(stack, sram_app),
    });
}

/// 结构自检（碎片压测每轮都跑）。失败时打印而不是复位。
pub fn verify(tag: []const u8) bool {
    const ok = arena.verify() and arena.verifyLists() and arena.verifyFlags();
    if (!ok) {
        log.line("heap[{s}]: corrupted (block header/list invariant broken)", .{tag});
    }
    return ok;
}

/// 主栈区间，供 stack_guard 使用（避免两个模块各自声明链接符号）。
pub fn stackRegion() struct { low: usize, high: usize } {
    return .{ .low = @intFromPtr(&_stack_bottom), .high = @intFromPtr(&_stack_top) };
}
