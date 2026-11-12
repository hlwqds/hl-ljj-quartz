//! ch13-heap-stack-caps：栈哨兵、溢出检测与高水位。
//!
//! 三件事，分别对应"溢出之后才发现 / 溢出当场发现 / 溢出之前就知道快满了"：
//!
//!   1. **哨兵（canary）**：在栈的可增长端的边界上放一个已知字，退出前比对。
//!      只能事后发现，但零成本、零硬件依赖。
//!   2. **高水位（watermark）**：把整段未用栈填成魔数，跑完之后从边界往上找
//!      第一个被改动的字节——它告诉你"最深用到哪里"。
//!   3. **硬件 SP 监视器**（本章只读不配）`bus_monitor`：把 SP 与
//!      `SP_MIN/SP_MAX` 比较，越界即中断。它才是"当场发现"，代价是要开中断、
//!      要接矩阵源 119，寄存器见 `psram.zig` 同级的说明与本章 13.7 节。
//!
//! 本文件同时演示**检测逻辑本身**：`sim_stack` 是一块 .bss 里的 512 字节
//! 数组，扮演"某个任务的栈"。`simulateOverflow()` 故意越过它的边界写 4 个
//! 字节（写的是这块我们自己的缓冲区，不是真栈），`checkSim()` 必须报
//! `overrun`。这是本章唯一"故意制造错误"的地方，也是唯一能证明检测器有效
//! 的方式——一个永远返回 ok 的检测器没有任何价值。

const log = @import("log.zig");
const heap = @import("heap.zig");

/// 填充魔数。0xA5 的位模式交替，写到未初始化内存时肉眼可辨。
pub const fill_byte: u8 = 0xA5;

/// 哨兵字。选 0xDEADBEEF 是因为它在串口里足够刺眼，而且不太可能是合法数据。
pub const canary_word: u32 = 0xDEAD_BEEF;

/// 填充/检查时给当前函数帧留的余量：正在跑的代码自己的栈帧就在 sp 下面，
/// 填到那里会把返回地址写掉。256 字节足够本文件里最深的调用（log.line 的
/// 200 字节缓冲 + 两级帧）。
const frame_margin: usize = 256;

/// 主栈的哨兵位置与记录。
var main_armed: bool = false;
var main_canary_addr: usize = 0;

/// 模拟任务的栈（.bss 里的普通数组，不参与任何真实调用）。
var sim_stack: [512]u8 align(16) = undefined;
var sim_armed: bool = false;

fn readSp() usize {
    return asm volatile ("mv %[d], sp"
        : [d] "=r" (-> usize),
    );
}

fn writeU32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

fn readU32(addr: usize) u32 {
    return @as(*const volatile u32, @ptrFromInt(addr)).*;
}

// ---------------------------------------------------------------------------
// 主栈：填魔数 + 边界哨兵
// ---------------------------------------------------------------------------

/// 给主栈"上膛"：把 [_stack_bottom, sp - margin) 填成魔数，并在物理边界
/// `_stack_bottom` 处放哨兵字。必须在进主循环之前调用——一旦填过，之前的
/// 调用痕迹就没了（这是有意的：我们只关心之后的用量）。
pub fn armMain() void {
    const r = heap.stackRegion();
    const sp = readSp();
    const limit = if (sp > r.low + frame_margin) sp - frame_margin else r.low;

    var a = r.low + 4; // 前 4 字节留给哨兵
    while (a < limit) : (a += 1) {
        @as(*volatile u8, @ptrFromInt(a)).* = fill_byte;
    }
    writeU32(r.low, canary_word);
    main_canary_addr = r.low;
    main_armed = true;
}

/// 哨兵检查：返回 true 表示完好。
pub fn checkMain() bool {
    if (!main_armed) return true;
    return readU32(main_canary_addr) == canary_word;
}

/// 高水位：从哨兵之后往上找第一个不是魔数的字节。返回已用字节数。
pub fn mainHighWater() usize {
    const r = heap.stackRegion();
    const end = readSp();
    var a = r.low + 4;
    while (a < end) : (a += 1) {
        if (@as(*const volatile u8, @ptrFromInt(a)).* != fill_byte) break;
    }
    return a - r.low;
}

/// 一行报告：`stack: main span=… used=… free=… sentinel=ok|overrun`
pub fn reportMain() void {
    const r = heap.stackRegion();
    const span = r.high - r.low;
    const used = mainHighWater();
    const state: []const u8 = if (checkMain()) "ok" else "overrun";
    log.line("stack: main span={d}B used={d}B free={d}B sentinel={s} canary=0x{x}", .{
        span, used, if (span > used) span - used else 0, state, readU32(main_canary_addr),
    });
}

// ---------------------------------------------------------------------------
// 模拟任务栈：证明检测器真的会响
// ---------------------------------------------------------------------------

/// 给模拟栈上膛：整段填魔数，边界放哨兵。
pub fn armSim() void {
    var i: usize = 4;
    while (i < sim_stack.len) : (i += 1) sim_stack[i] = fill_byte;
    writeU32(@intFromPtr(&sim_stack), canary_word);
    sim_armed = true;
}

pub fn checkSim() bool {
    return readU32(@intFromPtr(&sim_stack)) == canary_word;
}

/// 故意越界写 4 字节到模拟栈的边界哨兵上——模拟"某个深层调用把帧压过了栈底"。
/// **这不是 UB**：写的是我们自己的 `sim_stack` 缓冲区，长度 512 字节。
pub fn simulateOverflow(pattern: u32) void {
    writeU32(@intFromPtr(&sim_stack), pattern);
}

/// 恢复哨兵（为了继续演示后续检查）。
pub fn restoreSim() void {
    writeU32(@intFromPtr(&sim_stack), canary_word);
}

/// 一行报告：`stack: sim sentinel=ok|overrun got=0x… `
pub fn reportSim(tag: []const u8) void {
    const got = readU32(@intFromPtr(&sim_stack));
    const state: []const u8 = if (got == canary_word) "ok" else "overrun";
    log.line("stack: {s} sentinel={s} at=0x{x} expect=0x{x} got=0x{x}", .{
        tag, state, @intFromPtr(&sim_stack), canary_word, got,
    });
}

pub fn simBase() usize {
    return @intFromPtr(&sim_stack);
}

pub fn simLen() usize {
    return sim_stack.len;
}
