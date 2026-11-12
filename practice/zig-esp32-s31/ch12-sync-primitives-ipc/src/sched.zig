//! ch12-sync-primitives-ipc：在 ch11 的抢占调度器上补上 blocked 状态。
//!
//! ch11 的任务只有 ready / running / done 三个状态，调度器只需要回答
//! “现在谁最该跑”。本章多了一个状态与两个问题：
//!
//!   1. **blocked**：任务在等一个对象（互斥量、信号量、队列空位、事件位、睡眠到期）。
//!      TCB 需要记住“我在等什么”，内核需要一个挂载这些等待者的链表。
//!   2. **唤醒**：谁有资格把 blocked 变成 ready？答案必须是“持有该对象的人”，
//!      否则唤醒就变成广播，等待者醒来发现条件没满足又得睡下去。
//!
//! 阻塞/唤醒之后才真正出现优先级反转：中优先级任务可以插在
//! “低优先级持有者”和“高优先级等待者”之间，把后者拖住。
//! 修复手段（优先级继承）需要两个新字段：`base_prio`（创建时的值）与
//! `prio`（有效值），以及一次“把任务从就绪链里摘出来重新挂”的动作。
//!
//! 与 ch11 的差别汇总：
//!   - `State` 多了 `blocked`；
//!   - TCB 多了 `base_prio` / `wait_next` / `wait_on` / `sleep_left` / `boosts`；
//!   - 新增 `WaitList`（侵入式单向链，节点就是 TCB，零分配）；
//!   - 新增 `blockOn` / `sleepTicks` / `wake` / `waitPopBest` / `setPrio`；
//!   - 新增“唤醒后是否需要立刻抢占”的判断 `rescheduleIfNeeded`。
//!
//! 不变的东西同样是本章的重点：
//!   - 换栈仍然只有一种方式（`switchTo(&prev.sp, next.sp)`），
//!     ISR、`ecall`、阻塞、唤醒全部最终走 `schedule()`；
//!   - 临界区仍然是 `irqSave/irqRestore` 成对包住“改队列 + 选下一个 + 保存 sp”；
//!   - `mepc += 4` 仍然只在 `ecall` 分支。

const std = @import("std");
const context = @import("context.zig");
const tick = @import("tick.zig");

/// TCB 池大小。本章的最大同时存在任务数：
///   supervisor 1 + 自旋演示 2 + 反转阶段 A 3 + 反转阶段 B 3 + 队列 4 = 13。
pub const max_tasks: usize = 16;

/// 与 ch07/ch11 一致：CLIC 的 NLBITS = 3，8 级优先级。
pub const prio_levels: usize = 8;

pub const State = enum { ready, running, blocked, done };

/// 阻塞队列。先进先出入队，出队时取“有效优先级最高者”（同级取最早入队）。
///
/// 为什么出队要按优先级挑：信号量/队列的语义是“把资源交给最该跑的人”。
/// 若严格 FIFO，高优先级等待者会被低优先级的先来者挡住，等于把反转
/// 从“中优先级插队”换成“等待队列插队”。挑最高优先级是 O(n) 线性扫描，
/// 本章 n ≤ 16，够用；真实内核用按优先级分桶的双向链。
pub const WaitList = struct {
    head: ?*Task = null,
    tail: ?*Task = null,
};

pub const Task = struct {
    /// 只用于打印；不参与调度。
    name: []const u8,
    /// 任务栈的只读视图（起始地址 + 长度），诊断用。
    stack: []const u8,
    /// 挂起时指向 switch 帧；运行中没有意义。
    sp: usize,
    state: State,
    /// 有效优先级（0..7）：优先级继承会临时抬高它。
    prio: u3,
    /// 创建时的优先级：继承结束后恢复到这里。
    base_prio: u3,
    /// 剩余时间片，单位 = tick。
    slice: u16,
    /// 时间片初值，到期后重装。
    slice_init: u16,
    /// 同优先级就绪链的下一个（环形链）。
    next: ?*Task,
    /// 等待链上的下一个。只在 `blocked` 时有意义，且与 `next` 互斥使用。
    wait_next: ?*Task,
    /// 正在等什么（对象名或 "sleep"），只为打印。
    wait_on: []const u8,
    /// 睡眠剩余 tick；0 表示不在睡眠链上。
    sleep_left: u32,
    /// 是否在睡眠链上。**必须**与链的实际成员关系一致：
    /// 同一个任务被压进链两次会让链成环，而 `sleepTick` 在 ISR 里遍历它——
    /// 成环等于冻住整个 tick（CPU 100% 忙、无输出、无 STALL），
    /// 真机上正是这么“静默停住”的。
    sleeping: bool,
    /// 被优先级继承抬高的次数（证据，不是调度依据）。
    boosts: u32,
    /// 任务自己维护的进度，只为可观测。
    steps: u32,
    /// 被 tick 命中的累计次数。
    ticks: u32,
    idle: bool,
};

var pool: [max_tasks]Task = undefined;
var pool_len: usize = 0;

/// 每条优先级链的头/尾。空链时两者都是 null。链是**环形**的：
/// `ready_tail[p].next == ready_head[p]`。
var ready_head: [prio_levels]?*Task = @splat(null);
var ready_tail: [prio_levels]?*Task = @splat(null);

var current: ?*Task = null;

/// 睡眠链。按“入链顺序”串起来，每个 tick 全链递减一次。
/// 本章不做“按到期时间排序”的堆——任务数太少，排序省下的遍历
/// 比插入维护还贵，而且这里要的是可读而不是最优。
var sleep_head: ?*Task = null;

/// 三个计数器都是 **u32**，不是 u64。理由在 RV32 上很硬：64 位读是两条 `lw`，
/// tick ISR 若在两个半字之间更新，读到的是一个从未存在过的值。
/// 循环里用 `now -% t0 < n` 比较时，这种撕裂会让差值偏 2^32，
/// 把“等 60 个 tick”直接变成等 4294967 个 tick。u32 单条 `lw` 天然原子，
/// 2^32 个 tick（约 49 天）也远超人能观察到的时间尺度。
var switches: u32 = 0;
var tick_count: u32 = 0;
var block_events: u32 = 0;

/// **idle 必须有自己的栈。** 真机发现（ch11 板级验证，2026-11-11）：
/// ch11 让 idle 复用 `main` 的 `_stack_top`，所有任务结束后切回 idle 时，
/// `switchRaw` 从被后来者覆盖过的帧里恢复 `ra`，跳到了 0x2f07af18（一个栈地址），
/// 报 `instruction access fault`。栈是“换下之后还会被重新使用”的现场，
/// 复用别的东西（哪怕是 main 的栈）等于让两个上下文共用同一块内存。
var idle_stack: [4096]u8 align(16) = undefined;

/// `main` 交出控制权后由这块独立栈承载 idle 循环。
var idle_task: Task = .{
    .name = "idle",
    .stack = "",
    .sp = 0,
    .state = .running,
    .prio = 0,
    .base_prio = 0,
    .slice = 1,
    .slice_init = 1,
    .next = null,
    .wait_next = null,
    .wait_on = "",
    .sleep_left = 0,
    .sleeping = false,
    .boosts = 0,
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
// 中断闸门（与 ch11 逐字相同）
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
// 就绪队列（与 ch11 相同，多了“blocked 不进队列”的守卫）
// ---------------------------------------------------------------------------

fn enqueue(t: *Task) void {
    if (t.idle or t.state == .done or t.state == .blocked) return;
    const p: usize = t.prio;
    const head = ready_head[p];
    const tail = ready_tail[p];
    if (head != null and tail != null) {
        t.next = head;
        tail.?.next = t;
        ready_tail[p] = t;
    } else {
        // 头尾不一致时重建而不是在 `ready_tail[p].?` 上踩空：
        // 这条路径正常永远不会走到，它只是一次防御——宁可丢掉一条
        // 已经写坏的链，也不要让内核在 `.?` 上掉进 unreachable。
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

/// 把 `t` 从它**当前**的优先级链里摘掉（用 `t.prio` 定位，所以必须在
/// 改 `prio` 之前调用）。环形链没有双向指针，只能线性找前驱；
/// 环最多 `max_tasks` 个节点。
fn unlinkReady(t: *Task) void {
    const p: usize = t.prio;
    const head = ready_head[p] orelse return;
    var prev: *Task = ready_tail[p] orelse return;
    var cur: *Task = head;
    var guard: usize = 0;
    while (guard < max_tasks) : (guard += 1) {
        if (cur == t) {
            const nx = cur.next orelse head;
            if (ready_head[p] == t and nx == t) {
                // 链上只有它自己。
                ready_head[p] = null;
                ready_tail[p] = null;
            } else {
                if (ready_head[p] == t) ready_head[p] = nx;
                if (ready_tail[p] == t) ready_tail[p] = prev;
                prev.next = nx;
            }
            t.next = null;
            return;
        }
        prev = cur;
        cur = cur.next orelse return;
    }
}

/// 取最高优先级队首，但**绝不返回已结束的任务**。
///
/// 真机发现（ch11 板级验证，2026-11-11）：任务在时间片到期时被重新入队，
/// 之后才被标成 `done`（“打印 → 置 done → 让出”之间的窗口正好被 tick 穿过）。
/// 若 `pickNext` 直接返回队首，这个已经结束的 TCB 会被重新调度上 CPU，
/// 于是“复活的死任务”继续执行它 `done` 之后的代码。
/// 处置：出队后检查状态，`done` 的直接丢弃，继续找下一个。
fn pickNext() ?*Task {
    var p: usize = prio_levels;
    while (p > 0) {
        p -= 1;
        while (ready_head[p] != null) {
            const t = dequeue(p) orelse break;
            if (t.state == .done) continue;
            return t;
        }
    }
    return null;
}

/// 是否存在优先级**严格高于** `prio` 的就绪任务。
pub fn hasHigherReady(prio: u3) bool {
    var p: usize = @as(usize, prio) + 1;
    while (p < prio_levels) : (p += 1) {
        if (ready_head[p] != null) return true;
    }
    return false;
}

pub fn hasReady() bool {
    var p: usize = 0;
    while (p < prio_levels) : (p += 1) {
        if (ready_head[p] != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 等待链（本章新增）
// ---------------------------------------------------------------------------

fn waitPush(list: *WaitList, t: *Task) void {
    t.wait_next = null;
    if (list.tail) |tail| {
        tail.wait_next = t;
    } else {
        list.head = t;
    }
    list.tail = t;
}

/// 摘掉有效优先级最高的等待者（同级取队首）。
pub fn waitPopBest(list: *WaitList) ?*Task {
    const head = list.head orelse return null;
    var best: *Task = head;
    var best_prev: ?*Task = null; // null 表示 best 就是 head
    var prev: ?*Task = null;
    var cur: ?*Task = head;
    var guard: usize = 0;
    while (cur) |c| {
        // 等待链成环时，这里同样会死循环；上限保护比“看起来优雅”重要。
        guard += 1;
        if (guard > max_tasks) break;
        if (c.prio > best.prio) {
            best = c;
            best_prev = prev;
        }
        prev = c;
        cur = c.wait_next;
    }
    if (best_prev) |bp| {
        bp.wait_next = best.wait_next;
    } else {
        list.head = best.wait_next;
    }
    if (list.tail == best) list.tail = best_prev;
    best.wait_next = null;
    return best;
}

/// 把一个 blocked 任务变回 ready 并挂到它**当前优先级**的链上。
///
/// 必须已经关中断（调用者都在临界区里）：这里改的是就绪链。
pub fn wake(t: *Task) void {
    if (t.state != .blocked) return;
    // 不变量：一个任务只能在一个链上。若它还在睡眠链上（理论上不该发生），
    // 先摘掉，否则它会同时被 tick 与信号量两个唤醒源抢着唤醒。
    sleepRemove(t);
    t.state = .ready;
    t.wait_on = "";
    t.wait_next = null;
    t.sleep_left = 0;
    enqueue(t);
}

/// 从等待链上取最该跑的一个并唤醒；空链返回 null。
pub fn wakeBest(list: *WaitList) ?*Task {
    const t = waitPopBest(list) orelse return null;
    wake(t);
    return t;
}

/// 改有效优先级。若任务正在就绪链上，必须先摘下来再按新优先级挂回去，
/// 否则链的归属和 `prio` 字段会打架：`pickNext` 按链找、任务却宣布自己是另一级。
pub fn setPrio(t: *Task, p: u3) void {
    if (t.prio == p) return;
    const in_ready = t.state == .ready and !t.idle;
    if (in_ready) unlinkReady(t);
    t.prio = p;
    if (in_ready) enqueue(t);
}

// ---------------------------------------------------------------------------
// 任务与调度
// ---------------------------------------------------------------------------

pub fn taskCount() usize {
    return pool_len;
}

pub fn currentTask() ?*Task {
    return current;
}

/// 读 tick 计数。**必须经 volatile 指针**：普通全局 load 会被编译器当作
/// 循环不变式提到循环外（`asm volatile ("nop")` 声明不了“我读内存”），
/// 于是 `busyTicks` 那种 `while (now - t0 < n) { nop; }` 会变成死循环。
/// 这不是理论风险——LICM 的标准目标就是这种循环，是否触发取决于内联与周边代码。
pub fn tickCount() u32 {
    const p: *volatile u32 = &tick_count;
    return p.*;
}

pub fn switchCount() u32 {
    const p: *volatile u32 = &switches;
    return p.*;
}

pub fn blockCount() u32 {
    const p: *volatile u32 = &block_events;
    return p.*;
}

// ---------------------------------------------------------------------------
// 只读探针（给 monitor 心跳任务用）
//
// 这些函数**不参与任何调度决策**，只让外部把内核状态打成一行。
// 它们的价值在真机：一个“静默停住”的系统无法区分三种完全不同的故障——
//   (a) tick ISR 死了（心跳不再前进）；
//   (b) 某个任务永久阻塞（心跳前进，但 blocked 名单里躺着它）；
//   (c) 就绪链被写坏（心跳前进，ready 计数与预期不符）。
// 没有心跳时这三种都表现为“串口不动”。
// ---------------------------------------------------------------------------

/// 第 i 级优先级的就绪任务数（环形链长度）。
pub fn readyCount(i: usize) u32 {
    if (i >= prio_levels) return 0;
    const head = ready_head[i] orelse return 0;
    var n: u32 = 0;
    var cur: ?*Task = head;
    while (cur) |t| {
        n += 1;
        const nx = t.next orelse break;
        if (nx == head) break;
        cur = nx;
        if (n > max_tasks) break; // 环被写坏时不要死循环
    }
    return n;
}

pub fn blockedCount() u32 {
    var i: usize = 0;
    var n: u32 = 0;
    while (i < pool_len) : (i += 1) {
        if (pool[i].state == .blocked) n += 1;
    }
    return n;
}

pub fn sleepCount() u32 {
    var n: u32 = 0;
    var cur: ?*Task = sleep_head;
    while (cur) |t| {
        n += 1;
        if (n > max_tasks) break;
        cur = t.wait_next;
    }
    return n;
}

pub fn currentName() []const u8 {
    const c = current orelse return "none";
    return c.name;
}

/// 计数器的**写侧** volatile 视图，与上面三个读函数配对。
///
/// 读侧 volatile、写侧普通 store 是常见的半套做法：模型上“ISR 写、任务读”
/// 只要一边是 volatile 就够跑，但把它写成一对，编译器在两侧都不可能
/// 合并/提升/消除，读代码的人也不必再判断“这里到底谁在写”。
fn bump(p: *volatile u32) void {
    p.* = p.* +% 1; // +%：显式回绕，Debug 下也不会因溢出而 panic
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
        .base_prio = prio,
        .slice = slice,
        .slice_init = slice,
        .next = null,
        .wait_next = null,
        .wait_on = "",
        .sleep_left = 0,
        .sleeping = false,
        .boosts = 0,
        .steps = 0,
        .ticks = 0,
        .idle = false,
    };
    t.sp = context.initTaskStack(stack, entry, @intFromPtr(t));

    // 本章允许在任务上下文里 create（supervisor 就是这么干的），
    // 所以入队要自己关中断。ch11 只在 MIE = 0 的启动阶段 create。
    const old = irqSave();
    enqueue(t);
    irqRestore(old);
    return t;
}

/// 当前任务主动让出 CPU（同步异常，mcause = 11）。
pub noinline fn yield() void {
    asm volatile ("ecall");
}

/// 打印并标记完成。之后这个 TCB 再也不会被选中（不在任何链上）。
/// 标记 done 必须发生在“通知别人”之前：否则唤醒的高优先级任务
/// 抢占进来时，可能看到一个已经让出却还在跑的 TCB。
pub fn markDone(t: *Task) void {
    line("{s}: done steps={d} prio={d}/{d} boosts={d} ticks={d}", .{
        t.name, t.steps, t.prio, t.base_prio, t.boosts, t.ticks,
    });
    t.state = .done;
}

/// 永久停住：一直 `ecall`，而 `schedule` 不会再把 done 的任务入队。
pub fn parkForever() noreturn {
    while (true) yield();
}

/// 队列改动 + 选任务 + 换栈。`requeue` 表示“当前任务仍可运行，
/// 只是时间片到期/主动让出”，要按初始时间片追加回同级链尾。
///
/// 阻塞路径传 `requeue = false`：任务已被标记 `blocked` 并挂进某条等待链，
/// 再入就绪链就会同时出现在两处——那是本章最容易写出的内核 bug。
///
/// **换栈也在临界区里**，理由与 ch11 相同：`current = next` 之后、
/// `switchRaw` 保存 sp 之前放开中断，tick 会把 prev 的 sp 存进 next.sp。
fn schedule(requeue: bool) void {
    const prev = current orelse return;
    const old = irqSave();

    if (requeue and prev.state == .running and !prev.idle) {
        prev.slice = prev.slice_init;
        enqueue(prev);
    }

    // 队列全空时回到 idle。idle 不在 ready_head 里，但它是一个有效 TCB。
    const next = pickNext() orelse &idle_task;
    if (next == prev) {
        prev.state = .running;
        irqRestore(old);
        return;
    }

    bump(&switches);
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

/// 在等待链上阻塞当前任务。返回时它已经被某个 `wake` 唤醒并再次被调度。
///
/// **调用者必须已经关中断**（或接受一次额外的关/开）：`irqSave` 到
/// `schedule` 返回之间不允许有 tick 插进来，否则任务可能在被挂进等待链
/// 之前就被别人 wake——wake 看到 `state != .blocked` 直接忽略，这个任务
/// 就永远醒不过来了（丢失唤醒）。
pub fn blockOn(list: *WaitList, what: []const u8) void {
    const t = current orelse return;
    const old = irqSave();
    t.state = .blocked;
    t.wait_on = what;
    t.sleep_left = 0;
    waitPush(list, t);
    bump(&block_events);

    // requeue = false：blocked 的任务不能回到就绪链。
    schedule(false);

    // 到这里说明有人 wake 了我们，并且我们又被调度上了 CPU。
    irqRestore(old);
}

/// 睡眠 `n` 个 tick。睡眠也是一种阻塞：等待对象是“时间”，
/// 唤醒源是 tick ISR 里的 `sleepTick`。
pub fn sleepTicks(n: u32) void {
    if (n == 0) return;
    const t = current orelse return;
    const old = irqSave();
    if (t.sleeping or t.state == .done) {
        // 已经在睡眠链上（或已结束）：绝不再压一次，否则链成环。
        irqRestore(old);
        return;
    }
    t.state = .blocked;
    t.wait_on = "sleep";
    t.sleep_left = n;
    t.sleeping = true;
    t.wait_next = sleep_head;
    sleep_head = t;
    bump(&block_events);

    schedule(false);

    irqRestore(old);
}

/// 每个 tick 递减睡眠链；到期的任务从链上摘掉并 wake。
/// 只在 tick ISR 里调用（此时 MIE = 0，不需要再关中断）。
/// 把 `t` 从睡眠链上摘掉（若它在链上）。
fn sleepRemove(t: *Task) void {
    if (!t.sleeping) return;
    var prev: ?*Task = null;
    var cur: ?*Task = sleep_head;
    var guard: usize = 0;
    while (cur) |c| {
        guard += 1;
        if (guard > max_tasks) {
            sleep_head = null; // 链已损坏：整体丢弃，不要在这里死循环
            t.sleeping = false;
            t.sleep_left = 0;
            return;
        }
        if (c == t) {
            if (prev) |p| {
                p.wait_next = c.wait_next;
            } else {
                sleep_head = c.wait_next;
            }
            break;
        }
        prev = c;
        cur = c.wait_next;
    }
    t.sleeping = false;
    t.sleep_left = 0;
    t.wait_next = null;
}

fn sleepTick() void {
    var prev: ?*Task = null;
    var cur: ?*Task = sleep_head;
    var guard: usize = 0;
    while (cur) |t| {
        // 上限保护：链一旦成环，这里就是 tick ISR 里的死循环——
        // CPU 100% 忙、没有任何输出、连 STALL 都打不出来（idle 轮不到）。
        guard += 1;
        if (guard > max_tasks) {
            sleep_head = null;
            return;
        }
        const nx = t.wait_next;
        if (t.sleep_left > 0) t.sleep_left -= 1;
        if (t.sleep_left == 0) {
            if (prev) |p| {
                p.wait_next = nx;
            } else {
                sleep_head = nx;
            }
            t.wait_next = null;
            t.sleeping = false;
            wake(t);
        } else {
            prev = t;
        }
        cur = nx;
    }
}

/// 唤醒之后决定要不要立刻切换。
///
/// 必须在临界区里调用：它可能换栈。语义与 ch11 的“下一个 tick 才抢占”
/// 不同——同步原语释放资源时，等着的那个任务此刻就绪，让出 CPU 是
/// 唯一能证明“继承有效”的做法，否则高低优先级之间的关系要等 1 ms
/// 才体现出来，测量会被 tick 粒度淹没。
pub fn rescheduleIfNeeded() void {
    const cur = current orelse return;
    if (cur.idle) {
        if (hasReady()) schedule(false);
        return;
    }
    if (hasHigherReady(cur.prio)) schedule(true);
}

/// tick 的软件部分：先处理睡眠到期，再递减时间片，必要时调度。
pub fn onTick(_: *context.TrapFrame) void {
    bump(&tick_count);
    sleepTick();

    const prev = current orelse return;

    prev.ticks += 1;
    if (prev.slice > 0) prev.slice -= 1;

    if (prev.idle) {
        if (hasReady()) schedule(false);
        return;
    }
    if (prev.state == .done or prev.state == .blocked) {
        schedule(false);
        return;
    }
    if (prev.slice > 0 and !hasHigherReady(prev.prio)) return;

    schedule(true);
}

/// 软件中断让出的调度路径（CLIC 输入 19）。本章仍不接线，
/// 保留接口给 ch14 的跨核 IPI。
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
    // 真机发现（2026-11-12）：S31 的 mcause 高位带 CLIC 附加字段
    // （实测 ecall = 0x3800000b、非法指令 = 0x30000002，高位还见过 0x7f），
    // 异常码只在低位。CLIC 输入号是 6 位字段，所以先按 6 位取；
    // 再补一次 5 位读法，兼容“脏位落进 bit5”的情形。
    const code: usize = cause & 0x3F;
    if (code == 11 or (code & 0x1F) == 11) {
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

/// 诊断：有任务 blocked 而没有任何就绪任务 = 无人能唤醒它。
/// 只打印一次，避免刷屏。
fn reportStall(attempt: u32) void {
    line("sched: STALL #{d} - no ready task, no sleeper, blocked tasks follow", .{attempt});
    var i: usize = 0;
    while (i < pool_len) : (i += 1) {
        const t = &pool[i];
        if (t.state == .blocked) {
            line("  blocked: {s} prio={d} on=\"{s}\" sleep_left={d}", .{
                t.name, t.prio, t.wait_on, t.sleep_left,
            });
        }
    }
}

/// 把 `main` 变成 idle 任务，打开 MIE，开始轮转。不返回。
///
/// 顺序上的两个硬约束：
///   1. **先换到 idle 的独立栈，再打开 MIE。** 反过来的话，`tick.enable()`
///      之后、`switchTo` 之前来一次 tick，`schedule` 会把 `main` 的 sp 存进
///      `idle_task.sp`，把刚构造好的 idle 帧冲掉（这正是 ch11 真机崩溃的形状）。
///   2. `MIE` 只在 idle 自己的栈上打开：所有 trap 帧从此都压在 idle 栈上。
pub fn start() noreturn {
    idle_task.sp = context.initTaskStack(&idle_stack, @intFromPtr(&idleEntry), 0);
    idle_task.stack = &idle_stack;
    idle_task.state = .running;
    idle_task.slice = idle_task.slice_init;
    current = &idle_task;

    // 单向换栈：`abandoned` 落在 main 的栈上，本函数不返回，之后不再读它。
    // switchRaw 恢复 idle 帧后 `ret` 到 taskStart，在那里打开 MIE。
    var abandoned: usize = 0;
    context.switchTo(&abandoned, idle_task.sp);
    unreachable;
}

/// idle 的入口（跑在 `idle_stack` 上，由 `taskStart` 调用）。
fn idleEntry() callconv(.c) noreturn {
    idleLoop();
}

fn idleLoop() noreturn {
    // 到这里 MIE = 1（taskStart 打开的），而 sp 已经是 idle 自己的栈。
    tick.enable();

    // 停滞诊断的三个条件缺一不可：
    //   1. 没有就绪任务；
    //   2. 确实有任务在等；
    //   3. **睡眠链是空的**——只要还有人在睡，tick 就会把他叫醒，
    //      这不是死锁。真机教训（2026-11-13）：漏掉第 3 条会在
    //      “L 正常睡着、H 正常等锁”的时刻误报 STALL，把真正的
    //      问题掩盖在同一条日志里。
    // 最多报 3 次，且一旦重新出现就绪任务就解锁，这样第二次死锁
    // 不会因为“已经报过”而被永久静音。
    var stall_count: u32 = 0;
    var stall_latched = false;
    while (true) {
        yield();
        if (allDone()) {
            line("sched: all tasks done ticks={d} switches={d} blocks={d}", .{
                tick_count, switches, block_events,
            });
            tick.disable();
            line("idle: wfi", .{});
            while (true) {
                asm volatile ("wfi");
            }
        }
        const stuck = !hasReady() and hasBlocked() and sleep_head == null;
        if (stuck) {
            if (!stall_latched and stall_count < 3) {
                stall_count += 1;
                stall_latched = true;
                reportStall(stall_count);
            }
        } else {
            stall_latched = false;
        }
    }
}

fn hasBlocked() bool {
    var i: usize = 0;
    while (i < pool_len) : (i += 1) {
        if (pool[i].state == .blocked) return true;
    }
    return false;
}
