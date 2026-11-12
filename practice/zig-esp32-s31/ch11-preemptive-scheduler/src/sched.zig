//! ch11-preemptive-scheduler：抢占式调度器（TCB + 8 级优先级队列 + tick）。
//!
//! 与 ch10 的三处差别：
//!   1. TCB 多了 `prio`、`slice`、`slice_init`、`next`，池仍然是 .bss 里的
//!      静态数组，没有 malloc；
//!   2. 就绪队列按优先级分成 8 条环形链，同级尾插头取，天然轮转；
//!   3. 切换可以由 tick ISR 触发（本章）或 `ecall` 触发（ch10 保留）。
//!
//! 调度规则：最高优先级队首。时间片到期 → 当前任务追加到自己那条链的尾部；
//! 存在更高优先级就绪任务 → 下一个 tick 换它。没有老化、没有优先级继承，
//! 饥饿是严格优先级的已知代价（第十二章处理阻塞与反转）。
//!
//! 临界区覆盖“改队列 + 选下一个 + `switchRaw` 保存 sp”：这四步必须原子，
//! 否则 tick 会在 `current` 已切换、sp 尚未落盘时看到错误的任务组合。
//! MIE 的恢复不在这里：新任务由 `taskStart` 打开，老任务由自己的 `mret` 恢复。

const std = @import("std");
const context = @import("context.zig");
const tick = @import("tick.zig");

pub const max_tasks: usize = 8;
pub const prio_levels: usize = 8;

pub const State = enum { ready, running, done };

pub const Task = struct {
    /// 只用于打印；不参与调度。
    name: []const u8,
    /// 任务栈的只读视图（起始地址 + 长度），诊断用。
    stack: []const u8,
    /// 挂起时指向 switch 帧；运行中没有意义。
    sp: usize,
    state: State,
    /// 0..7，越大越优先。
    prio: u3,
    /// 剩余时间片，单位 = tick。
    slice: u16,
    /// 时间片初值，到期后重装。
    slice_init: u16,
    /// 同优先级就绪链的下一个（环形链）。
    next: ?*Task,
    /// 任务自己维护的进度，只为可观测。
    steps: u32,
    /// 被 tick 命中的累计次数。
    ticks: u32,
    idle: bool,
};

var pool: [max_tasks]Task = undefined;
var pool_len: usize = 0;

/// 每条优先级链的头/尾。空链时两者都是 null。
var ready_head: [prio_levels]?*Task = @splat(null);
var ready_tail: [prio_levels]?*Task = @splat(null);

var current: ?*Task = null;
var switches: u64 = 0;
var tick_count: u64 = 0;

/// `main` 自己的栈就是 idle 的栈：不占额外 .bss，也不需要初始化 sp。
var idle_task: Task = .{
    .name = "idle",
    .stack = "",
    .sp = 0,
    .state = .running,
    .prio = 0,
    .slice = 1,
    .slice_init = 1,
    .next = null,
    .steps = 0,
    .ticks = 0,
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
// 中断闸门
// ---------------------------------------------------------------------------

/// 读 mstatus 并清 MIE，返回旧值（用于嵌套恢复）。
pub inline fn irqSave() usize {
    const v = asm volatile ("csrr %[d], mstatus"
        : [d] "=r" (-> usize),
    );
    asm volatile ("csrci mstatus, 0x8");
    return v;
}

/// 整字写回旧 mstatus：恢复 MIE，也恢复被清掉的其它位。
pub inline fn irqRestore(old: usize) void {
    asm volatile ("csrw mstatus, %[v]"
        :
        : [v] "r" (old),
    );
}

// ---------------------------------------------------------------------------
// 就绪队列
// ---------------------------------------------------------------------------

fn enqueue(t: *Task) void {
    if (t.idle or t.state == .done) return;
    const p: usize = t.prio;
    if (ready_head[p]) |h| {
        const tail = ready_tail[p].?;
        t.next = h;
        tail.next = t;
        ready_tail[p] = t;
    } else {
        t.next = t;
        ready_head[p] = t;
        ready_tail[p] = t;
    }
}

fn dequeue(p: usize) ?*Task {
    const h = ready_head[p] orelse return null;
    const nxt = h.next orelse h;
    if (nxt == h) {
        ready_head[p] = null;
        ready_tail[p] = null;
    } else {
        ready_head[p] = nxt;
        ready_tail[p].?.next = nxt;
    }
    h.next = null;
    return h;
}

fn pickNext() ?*Task {
    var p: usize = prio_levels;
    while (p > 0) {
        p -= 1;
        if (ready_head[p] != null) return dequeue(p);
    }
    return null;
}

fn higherReady(prio: u3) bool {
    var p: usize = @as(usize, prio) + 1;
    while (p < prio_levels) : (p += 1) {
        if (ready_head[p] != null) return true;
    }
    return false;
}

fn anyReady() bool {
    var p: usize = 0;
    while (p < prio_levels) : (p += 1) {
        if (ready_head[p] != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 任务与调度
// ---------------------------------------------------------------------------

pub fn taskCount() usize {
    return pool_len;
}

pub fn create(name: []const u8, stack: []const u8, entry: usize, prio: u3, slice: u16) *Task {
    std.debug.assert(pool_len < max_tasks);
    std.debug.assert(stack.len >= context.switch_frame_bytes);
    std.debug.assert(slice > 0);

    const t = &pool[pool_len];
    pool_len += 1;
    t.* = .{
        .name = name,
        .stack = stack,
        .sp = 0,
        .state = .ready,
        .prio = prio,
        .slice = slice,
        .slice_init = slice,
        .next = null,
        .steps = 0,
        .ticks = 0,
        .idle = false,
    };
    t.sp = context.initTaskStack(stack, entry, @intFromPtr(t));
    enqueue(t);
    return t;
}

/// 当前任务主动让出 CPU（同步异常，mcause = 11）。
pub noinline fn yield() void {
    asm volatile ("ecall");
}

/// 任务完成：先打印再标记 done 并永久让出。
///
/// 顺序不能反：`done` 之后任务不再入队，若这时还停在 `esp_rom_printf`
/// 内部，一次 tick 就会把它永久停在半行输出上。先打印完，再置 done。
pub fn finish(t: *Task) noreturn {
    line("{s}: done (steps={d})", .{ t.name, t.steps });
    t.state = .done;
    while (true) yield();
}

/// 队列改动 + 选任务。`requeue` 表示“当前任务的时间片到期/主动让出”，
/// 要把自己按初始时间片追加到同级链尾。
///
/// **换栈也在临界区里**：如果 `current = next` 之后、`switchRaw` 保存 sp 之前
/// 放中断进来，tick 会看到 `current = next` 却仍在 prev 的栈上，把 prev 的
/// sp 存进 next.sp——两个任务共用一张栈。这是内核原语，必须原子。
///
/// MIE 不在这里恢复给新任务：trap 上下文里 `old.MIE = 0`，换过去之后
///   - 新建任务由 `taskStart` 显式 `csrsi mstatus, 8`；
///   - 被抢占的任务逐层返回自己的 trapEntry，由 `mret` 用 MPIE 恢复 MIE。
/// 两条路径都由“任务自己的现场”决定中断状态，而不是由切换代码代劳。
fn schedule(requeue: bool) void {
    const prev = current orelse return;
    const old = irqSave();

    if (requeue and prev.state == .running and !prev.idle) {
        prev.slice = prev.slice_init;
        enqueue(prev);
    }

    // 队列全空时回到 idle。idle 不在 ready_head 里，但它是一个有效 TCB：
    // 第一次被换走时 `switchTo(&prev.sp, ...)` 已经把它的 sp 存好。
    const next = pickNext() orelse &idle_task;
    if (next == prev) {
        prev.state = .running;
        irqRestore(old);
        return;
    }

    switches += 1;
    if (prev.state == .running) prev.state = .ready;
    next.state = .running;
    current = next;

    // 返回时 CPU 已经在 next 的栈上；对 next 而言，这里就是它上次
    // 调用 switchTo 之后的那条指令。临界区跨过换栈，直到回到本栈才放开。
    context.switchTo(&prev.sp, next.sp);

    // 恢复执行：此刻又回到 prev 的栈上。
    current = prev;
    prev.state = .running;
    irqRestore(old);
}

/// tick 的软件部分：递减时间片，必要时调度。
pub fn onTick(_: *context.TrapFrame) void {
    tick_count += 1;
    const prev = current orelse return;

    prev.ticks += 1;
    if (prev.slice > 0) prev.slice -= 1;

    if (prev.idle) {
        if (anyReady()) schedule(false);
        return;
    }
    if (prev.state == .done) {
        schedule(false);
        return;
    }
    if (prev.slice > 0 and !higherReady(prev.prio)) return;

    schedule(true);
}

/// 软件中断让出的调度路径（CLIC 输入 19）。本章不接线，保留接口。
fn softYield() void {
    tick.clearSoft();
    schedule(true);
}

/// 软件中断让出入口：写 CLIC 输入 19 的 `IP`。
pub fn requestYield() void {
    tick.requestYield();
}

/// trap 入口调用的分发函数（context.zig 的 `call trapDispatch`）。
pub export fn trapDispatch(frame: *context.TrapFrame) void {
    const cause = asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );

    if ((cause & 0x8000_0000) != 0) {
        // CLIC 系统上，mcause 低 6 位是输入号，不是规范里的中断编号。
        const id: u6 = @truncate(cause & 0x3F);
        if (tick.acknowledge(id)) {
            onTick(frame);
            return;
        }
        if (id == tick.soft_input) {
            softYield();
            return;
        }
        halt(cause, frame.mepc);
    }

    // 11 = environment call from M-mode。同步异常要跳过这条指令；
    // tick 中断绝不能加 4（那会随机跳过被打断的指令）。
    if (cause == 11) {
        frame.mepc += 4;
        schedule(true);
        return;
    }

    halt(cause, frame.mepc);
}

fn allDone() bool {
    var i: usize = 0;
    while (i < pool_len) : (i += 1) {
        if (pool[i].state != .done) return false;
    }
    return true;
}

/// 把 `main` 变成 idle 任务，打开 MIE，开始轮转。不返回。
pub fn start() noreturn {
    current = &idle_task;
    idle_task.state = .running;
    idle_task.slice = idle_task.slice_init;

    tick.enable();

    while (true) {
        yield();
        if (allDone()) {
            line("sched: all tasks done ticks={d} switches={d}", .{ tick_count, switches });
            tick.disable();
            line("idle: wfi", .{});
            while (true) {
                asm volatile ("wfi");
            }
        }
    }
}
