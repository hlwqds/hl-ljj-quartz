//! ch10-context-switch-scheduler：协作式调度器。
//!
//! 三件事：
//!   1. 一个静态 TCB 池 + 固定就绪队列（无 malloc，全部在 .bss）；
//!   2. `yield()` 用 `ecall` 陷入，`trapDispatch` 里调用 `schedule()`；
//!   3. `schedule()` 选下一个任务后调用 `context.switchTo`，换掉 sp。
//!
//! 调度策略：从当前任务之后开始线性扫描，跳过 `done`，回到 idle。
//! 没有优先级、没有时间片——这一章只有“自愿让出”，抢占留给第 11 章。
//!
//! 打印走掩膜 ROM 的 `esp_rom_printf`（链接脚本 PROVIDE 到 0x2f800024）。
//! `line()` 先在栈上把内容格式化好再交给 `%s`，避免把 Zig 的可变参数
//! 直接塞进 C 变参列表。

const std = @import("std");
const context = @import("context.zig");

pub const max_tasks: usize = 8;

pub const State = enum { ready, running, done };

pub const Task = struct {
    /// 只用于打印；不参与调度。
    name: []const u8,
    /// 任务栈的只读视图（起始地址 + 长度），诊断用。
    stack: []const u8,
    /// 挂起时指向 switch 帧；运行中没有意义。
    sp: usize,
    state: State,
    /// 任务自己维护的进度，只为可观测。
    steps: u32,
    idle: bool,
};

var pool: [max_tasks]Task = undefined;
var pool_len: usize = 0;
var current: ?*Task = null;
var switches: u64 = 0;

/// `main` 自己的栈就是 idle 的栈：它不占额外 .bss，也不需要初始化 sp。
var idle_task: Task = .{
    .name = "idle",
    .stack = "",
    .sp = 0,
    .state = .running,
    .steps = 0,
    .idle = true,
};

// ---------------------------------------------------------------------------
// 输出
// ---------------------------------------------------------------------------

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

/// 一行输出。格式串不需要自带换行。
pub fn line(comptime fmt: []const u8, args: anytype) void {
    // 190 字节正文 + '\n' + 结尾 0：bufPrint 的空间必须留出后两个字节。
    var buf: [192:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..190], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    const out: [:0]const u8 = buf[0 .. text.len + 1 :0];
    _ = esp_rom_printf("%s", out.ptr);
}

fn halt(cause: usize, mepc: usize) noreturn {
    line("trap: unexpected cause=0x{x} mepc=0x{x}", .{ cause, mepc });
    while (true) {
        asm volatile ("wfi");
    }
}

// ---------------------------------------------------------------------------
// 任务与调度
// ---------------------------------------------------------------------------

pub fn taskCount() usize {
    return pool_len;
}

pub fn create(name: []const u8, stack: []const u8, entry: usize) *Task {
    std.debug.assert(pool_len < max_tasks);
    std.debug.assert(stack.len >= context.switch_frame_bytes);

    const t = &pool[pool_len];
    pool_len += 1;
    t.* = .{
        .name = name,
        .stack = stack,
        .sp = 0,
        .state = .ready,
        .steps = 0,
        .idle = false,
    };
    // 初始 sp 指向栈顶手工构造的 64 字节帧；参数是 TCB 自身。
    t.sp = context.initTaskStack(stack, entry, @intFromPtr(t));
    return t;
}

/// 当前任务主动让出 CPU。
///
/// `ecall` 是同步异常（mcause = 11），不需要 mstatus.MIE，也不需要
/// CLIC 输入号/优先级/阈值。返回时任务从下一条指令继续。
pub noinline fn yield() void {
    asm volatile ("ecall");
}

/// 任务完成：标记 done 并永久让出。之后的轮转不会再选中它。
pub fn finish(t: *Task) noreturn {
    t.state = .done;
    line("{s}: done (steps={d})", .{ t.name, t.steps });
    while (true) yield();
}

fn pickNext(prev: *Task) *Task {
    if (pool_len == 0) return &idle_task;

    var first: usize = 0;
    if (!prev.idle) {
        var i: usize = 0;
        while (i < pool_len and &pool[i] != prev) : (i += 1) {}
        first = if (i < pool_len) (i + 1) % pool_len else 0;
    }

    var scanned: usize = 0;
    while (scanned < pool_len) : (scanned += 1) {
        const cand = &pool[first];
        if (cand.state != .done) return cand;
        first = (first + 1) % pool_len;
    }
    return &idle_task;
}

fn schedule(frame: *context.TrapFrame) void {
    // ecall 是 4 字节指令：不跳过它，mret 会回到同一条 ecall，
    // 任务会立刻再次让出，表现为“只有一个任务在刷屏”。
    frame.mepc += 4;

    const prev = current orelse halt(0, frame.mepc);
    const next = pickNext(prev);
    if (next == prev) return;

    switches += 1;
    if (prev.state == .running) prev.state = .ready;
    next.state = .running;
    current = next;

    // 返回时 CPU 已经在 next 的栈上；对 next 而言，这里就是它上次
    // 调用 switchTo 之后的那条指令。
    context.switchTo(&prev.sp, next.sp);

    // 恢复执行：此刻又回到 prev 的栈上。
    current = prev;
    prev.state = .running;
}

/// trap 入口调用的分发函数（context.zig 的 `call trapDispatch`）。
pub export fn trapDispatch(frame: *context.TrapFrame) void {
    const cause = asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );

    // 中断：本章没有打开 MIE，走到这里说明有配置错误。
    if ((cause & 0x8000_0000) != 0) halt(cause, frame.mepc);

    // 11 = environment call from M-mode。
    if (cause == 11) {
        schedule(frame);
        return;
    }

    // 其它同步异常（未对齐、非法指令……）直接停机，并打印现场。
    halt(cause, frame.mepc);
}

fn allDone() bool {
    var i: usize = 0;
    while (i < pool_len) : (i += 1) {
        if (pool[i].state != .done) return false;
    }
    return true;
}

/// 把 `main` 变成 idle 任务，开始轮转。不返回。
pub fn start() noreturn {
    current = &idle_task;
    idle_task.state = .running;

    while (true) {
        yield();
        if (allDone()) {
            line("sched: all tasks done, switches={d}", .{switches});
            line("idle: wfi", .{});
            while (true) {
                asm volatile ("wfi");
            }
        }
    }
}
