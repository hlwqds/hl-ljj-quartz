//! ch14-dual-core-smp-ipi：每核一个调度器（SMP 的最小正确形态）。
//!
//! 本章没有做“全局就绪队列 + 大内核锁”那种 SMP：那种设计的每一次调度都要
//! 抢同一把锁，两个核会互相拖慢，缓存行也会来回弹。本章采用**每核独立
//! 就绪队列**（per-core runqueue）：
//!
//!   - 队列、当前任务、idle、计数器都在 `PerCpu` 里（src/smp.zig）；
//!   - 本核调度只碰自己的队列，最坏情况是 0 次跨核等待；
//!   - 跨核只做两件事：把任务挂到目标核队列（拿目标核的锁），然后发 IPI。
//!
//! 由此得到一条必须写进注释的锁规则：
//!
//!   **一次只持一把核队列锁，绝不嵌套。** 取锁顺序一旦出现“我拿你的、
//!   你拿我的”，两个核就会在自旋里互等。本章所有路径都遵守：先在目标核
//!   锁内把任务挂好、放锁，然后才发 IPI。
//!
//! 另一个细节：本核锁的持有者从不阻塞（入队/出队都是几条指令），
//! 所以远端自旋者最多等几个周期；但**同一个核上的中断**必须被关掉，
//! 否则“任务持锁 → tick → ISR 里再抢同一把锁”会自死锁。因此任务上下文
//! 的临界区一律 `hw.irqSave()`；trap 上下文本来 MIE=0，不需要再关。

const std = @import("std");
const context = @import("context.zig");
const hw = @import("hw.zig");
const smp = @import("smp.zig");
const clic = @import("clic.zig");
const tick = @import("tick.zig");
const systimer = @import("systimer.zig");
const console = @import("console.zig");

pub const prio_levels: usize = smp.prio_levels;
pub const max_tasks: usize = 12;

pub const State = enum { ready, running, blocked, done };

pub const Kind = enum { supervisor, worker, job, idle };

pub const Task = struct {
    /// 只用于打印；不参与调度。
    name: []const u8,
    /// 挂起时指向 switch 帧；运行中没有意义。
    sp: usize,
    state: State,
    /// 优先级 0..7（越大越优先）。
    prio: u3,
    /// 剩余时间片（tick）。
    slice: u16,
    /// 时间片初值。
    slice_init: u16,
    /// 当前归属的核。迁移时在目标核的锁里改。
    core: u32,
    /// 同优先级就绪链的下一个（环形链）。
    next: ?*Task,
    kind: Kind,
    /// job 任务要跑的轮数。
    budget: u32,
    /// 任务自己维护的进度，只为可观测。
    steps: u32,
    /// 被 tick 命中的累计次数。
    ticks: u32,
    idle: bool,
};

var pool: [max_tasks]Task = undefined;
var pool_len: usize = 0;

/// 每个核的 idle 任务与栈。idle 必须有**自己的**栈：ch11 的真机崩溃
/// （`instruction access fault`，ra 指向栈地址）就是让 idle 复用 main 的
/// `_stack_top` 造成的 —— 栈是“换下之后还会被重新使用”的现场。
var idle_tasks: [smp.hart_count]Task = undefined;
var idle_stacks: [smp.hart_count][1024]u8 align(16) = undefined;

// ---------------------------------------------------------------------------
// 核队列锁
// ---------------------------------------------------------------------------

fn lockCpu(cpu: *smp.PerCpu) void {
    // acquire 语义保证锁内读到的队列状态不早于本次获取；后面再补一条
    // fence 让“先看到锁、后看到数据”在弱内存序的 RISC-V 上也是硬的。
    while (@cmpxchgWeak(u32, &cpu.lock, 0, 1, .acquire, .monotonic) != null) {}
    hw.fenceRwRw();
}

fn unlockCpu(cpu: *smp.PerCpu) void {
    @atomicStore(u32, &cpu.lock, 0, .release);
}

// ---------------------------------------------------------------------------
// 每核就绪队列（环形链，与 ch11/ch12 同构，但每核一份）
// ---------------------------------------------------------------------------

fn enqueueLocked(cpu: *smp.PerCpu, t: *Task) void {
    const p: usize = t.prio;
    if (cpu.head[p]) |h| {
        const tail = cpu.tail[p].?;
        t.next = h;
        tail.next = t;
        cpu.tail[p] = t;
    } else {
        t.next = t;
        cpu.head[p] = t;
        cpu.tail[p] = t;
    }
}

fn dequeueLocked(cpu: *smp.PerCpu, p: usize) ?*Task {
    const h = cpu.head[p] orelse return null;
    const nxt = h.next orelse h;
    if (nxt == h) {
        cpu.head[p] = null;
        cpu.tail[p] = null;
    } else {
        cpu.head[p] = nxt;
        cpu.tail[p].?.next = nxt;
    }
    h.next = null;
    return h;
}

/// 取最高优先级队首，但绝不返回已结束的任务（ch11 真机发现：任务可能在
/// 时间片到期时被重新入队、之后才被标成 done，直接返回队首会“复活”它）。
fn pickNextLocked(cpu: *smp.PerCpu) ?*Task {
    var p: usize = prio_levels;
    while (p > 0) {
        p -= 1;
        while (cpu.head[p] != null) {
            const t = dequeueLocked(cpu, p) orelse break;
            if (t.state == .done) continue;
            return t;
        }
    }
    return null;
}

fn hasReady(cpu: *smp.PerCpu) bool {
    lockCpu(cpu);
    defer unlockCpu(cpu);
    var p: usize = 0;
    while (p < prio_levels) : (p += 1) {
        if (cpu.head[p] != null) return true;
    }
    return false;
}

/// 挂到**本核**队列，不发 IPI。启动路径专用（此时 MIE 还是 0）。
pub fn enqueueLocal(t: *Task) void {
    const cpu = smp.me();
    const old = hw.irqSave();
    lockCpu(cpu);
    t.core = cpu.hart;
    t.state = .ready;
    enqueueLocked(cpu, t);
    unlockCpu(cpu);
    hw.irqRestore(old);
}

/// 唤醒（或迁移）一个任务到 `core`，然后发 IPI。
///
/// `t.state == .blocked` 才入队：已经在队列里的任务不能被挂第二次，
/// 否则同一个 TCB 会在环形链里出现两个位置，出队一次之后仍然“幽灵”可跑。
pub fn wakeRemote(t: *Task, core: u32) void {
    const cpu = &smp.cpus[core];

    // 目标可能**就是本核**（supervisor 把 job 挂到 core0、最后一个 job 唤醒
    // 同核的 supervisor）。拿本核队列锁时必须关中断：tick 恰好落在
    // lockCpu/unlockCpu 之间时，ISR 里的 switchCore 会自旋等这把被中断
    // 持有者占着的锁 —— 永久挂死。远端目标时这次 irqSave 也不是浪费：
    // 它保证“检查 state → 入队”这段不会被本核的调度器插进来。
    const old = hw.irqSave();
    lockCpu(cpu);
    var woke = false;
    if (t.state == .blocked) {
        t.state = .ready;
        t.core = core;
        enqueueLocked(cpu, t);
        woke = true;
    } else if (t.state == .ready and t.core != core) {
        // 已在别的核队列里：本章不做“跨核偷取”，只在 block→ready 时迁移。
        woke = false;
    }
    unlockCpu(cpu);
    hw.irqRestore(old);

    if (!woke) return;

    // 先发布队列改动，再打断对方（sendIpi 内部还有一次 fence）。
    hw.fenceRwRw();
    smp.sendIpi(core);
}

// ---------------------------------------------------------------------------
// 换栈
// ---------------------------------------------------------------------------

/// 队列改动 + 选任务 + 换栈。
///
/// `requeue = true`：当前任务仍可运行（时间片到期），按初值重装后回到
/// 同级链尾；`false`：当前任务已经 blocked/done（或调用者是 idle），不再入队。
fn switchCore(cpu: *smp.PerCpu, requeue: bool) void {
    const prev = cpu.current orelse return;

    lockCpu(cpu);
    if (requeue and prev.state == .running and !prev.idle) {
        prev.slice = prev.slice_init;
        enqueueLocked(cpu, prev);
    }
    const next = pickNextLocked(cpu) orelse (cpu.idle orelse {
        unlockCpu(cpu);
        return;
    });
    if (next == prev) {
        prev.state = .running;
        unlockCpu(cpu);
        return;
    }
    if (!prev.idle and prev.state == .running) prev.state = .ready;
    next.state = .running;
    cpu.current = next;
    cpu.switches +%= 1;
    unlockCpu(cpu);

    // 返回时 CPU 已经在 next 的栈上；对 next 而言，这里就是它上次
    // switchTo 返回后的那条指令。
    context.switchTo(&prev.sp, next.sp);

    // 恢复执行：此刻又回到 prev 的栈上。
    cpu.current = prev;
    prev.state = .running;
}

/// 当前任务主动阻塞（等 IPI / 等 job 全部完成）。返回时已被唤醒并重新调度。
pub fn blockCurrent() void {
    const cpu = smp.me();
    const old = hw.irqSave();
    const t = cpu.current orelse {
        hw.irqRestore(old);
        return;
    };
    t.state = .blocked;
    switchCore(cpu, false);
    hw.irqRestore(old);
}

/// 带谓词复查的阻塞：把“标 blocked → 复查条件 → 换栈”放进同一个临界区，
/// 关掉“对方在标志位与阻塞之间完成”的丢唤醒窗口。
///
/// 与 `wakeRemote` 的配合是关键：唤醒方在**目标核的锁**里检查
/// `state == .blocked` 才入队；这里也持同一把锁完成“标 blocked + 复查”。
/// 于是只有两种顺序：
///   - 条件在锁内已满足 → 不阻塞，直接返回；
///   - 条件在锁内未满足 → 必然已 blocked → 对方的 wakeRemote 一定会入队。
pub fn blockIf(pred: *const fn () bool) void {
    const cpu = smp.me();
    const old = hw.irqSave();
    const t = cpu.current orelse {
        hw.irqRestore(old);
        return;
    };

    lockCpu(cpu);
    t.state = .blocked;
    if (pred()) {
        t.state = .running;
        unlockCpu(cpu);
        hw.irqRestore(old);
        return;
    }
    unlockCpu(cpu);

    switchCore(cpu, false);
    hw.irqRestore(old);
}

/// 任务结束：标 done 并让出，永不返回。
pub fn parkCurrent() noreturn {
    const cpu = smp.me();
    const old = hw.irqSave();
    if (cpu.current) |t| t.state = .done;
    switchCore(cpu, false);
    hw.irqRestore(old);
    unreachable;
}

// ---------------------------------------------------------------------------
// 任务创建
// ---------------------------------------------------------------------------

pub fn create(
    name: []const u8,
    stack: []u8,
    entry: *const fn (*Task) callconv(.c) noreturn,
    prio: u3,
    slice: u16,
    kind: Kind,
) *Task {
    std.debug.assert(pool_len < max_tasks);
    std.debug.assert(stack.len >= context.switch_frame_bytes);
    std.debug.assert(slice > 0);

    const t = &pool[pool_len];
    pool_len += 1;
    t.* = .{
        .name = name,
        .sp = context.initTaskStack(stack, @intFromPtr(entry), @intFromPtr(t)),
        .state = .blocked,
        .prio = prio,
        .slice = slice,
        .slice_init = slice,
        .core = 0,
        .next = null,
        .kind = kind,
        .budget = 0,
        .steps = 0,
        .ticks = 0,
        .idle = false,
    };
    return t;
}

pub fn taskCount() usize {
    return pool_len;
}

pub fn task(i: usize) *Task {
    return &pool[i];
}

/// 当前任务（本核）。
pub fn currentTask() ?*Task {
    const cpu = smp.meOrNull() orelse return null;
    return cpu.current;
}

// ---------------------------------------------------------------------------
// 启动与 trap
// ---------------------------------------------------------------------------

fn idleEntry(_: *Task) callconv(.c) noreturn {
    idleLoop();
}

fn idleLoop() noreturn {
    const cpu = smp.me();
    // 到这里 MIE = 1（taskStart 打开的），sp 已经是本核 idle 的栈。
    //
    // 循环体必须先关本核中断：`hasReady`/`switchCore` 都要拿核队列锁，
    // 而 tick 与 IPI 的 ISR 也会在 trap 返回前调用 `switchCore`。
    // MIE=1 时持锁被 tick 打断 → ISR 自旋等同一把锁 → 自死锁（真机上
    // 表现为“tick 计数停在某个值，两个核都不再输出”）。
    while (true) {
        const old = hw.irqSave();
        if (hasReady(cpu)) {
            switchCore(cpu, false);
            hw.irqRestore(old);
        } else {
            // 没有就绪任务：先恢复 MIE 再 wfi。醒来（中断 pending 或到达）
            // 之后重进循环；trap 在返回到这里之前已经做过一次调度检查。
            hw.irqRestore(old);
            hw.wfi();
        }
    }
}

/// 把调用者（core0 的 main 或 core1 的 core1Main）变成本核的 idle，
/// 打开 MIE，开始轮转。不返回。
///
/// 顺序上的硬约束（与 ch12 相同）：**先换到 idle 自己的栈，再打开 MIE**。
/// 反过来的话，开中断之后、switchTo 之前来一次中断，schedule 会把
/// 调用者的 sp 存进 idle 的 TCB，把刚构造好的 idle 帧冲掉。
pub fn start(core: u32) noreturn {
    const cpu = &smp.cpus[core];
    const idle = &idle_tasks[core];
    idle.* = .{
        .name = "idle",
        .sp = context.initTaskStack(&idle_stacks[core], @intFromPtr(&idleEntry), 0),
        .state = .running,
        .prio = 0,
        .slice = 1,
        .slice_init = 1,
        .core = core,
        .next = null,
        .kind = .idle,
        .budget = 0,
        .steps = 0,
        .ticks = 0,
        .idle = true,
    };
    cpu.idle = idle;
    cpu.current = idle;

    // 单向换栈：`abandoned` 落在调用者的栈上，本函数不返回，之后不再读它。
    var abandoned: usize = 0;
    context.switchTo(&abandoned, idle.sp);
    unreachable;
}

fn halt(cause: usize, mepc: usize) noreturn {
    // 这里是“锁可能已经坏了”的路径：用不走锁的 raw 输出。
    console.raw("trap: unexpected cause=0x{x} mepc=0x{x}", .{ cause, mepc });
    while (true) {
        hw.wfi();
    }
}

/// trap 入口调用的分发函数（context.zig 的 `call trapDispatch`）。
///
/// CLIC 的两个坑（ch07/ch11 真机发现）都在这里处理：
///   1) 中断时 `mcause` 最高位是 1，低 **6 位**是 CLIC 输入号，不是规范里的
///      中断编号；
///   2) 同步异常的 `mcause` 高位还带 CLIC 附加字段（实测 ecall=0x3800000b、
///      非法指令=0x30000002），所以异常码只在低位，先按 6 位取，
///      再补一次 5 位读法兼容“脏位落进 bit5”。
pub export fn trapDispatch(frame: *context.TrapFrame) void {
    const cause = asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );

    if ((cause & 0x8000_0000) != 0) {
        const id: u6 = @truncate(cause & 0x3F);
        const cpu = smp.meOrNull() orelse {
            console.raw("trap: irq id={d} before mscratch attach (mcause=0x{x})", .{ id, cause });
            halt(cause, frame.mepc);
        };

        if (tick.acknowledge(cpu.hart, id)) {
            cpu.ticks +%= 1;
            cpu.need_resched = 1;
        } else if (id == clic.ipiInput(cpu.hart)) {
            smp.ackIpi(cpu.hart);
            cpu.ipis_in +%= 1;
            // wakeups 不在这里加：它统计“任务真正被唤醒”的次数，
            // 在 noteResume 里加，保证一个事件只记一次。
            // ISR 与“任务真正恢复”之间的差：跨核唤醒的软件成本。
            cpu.isr_ts = systimer.now();
            cpu.need_resched = 1;
        } else {
            halt(cause, frame.mepc);
        }

        if (cpu.need_resched != 0) {
            cpu.need_resched = 0;
            switchCore(cpu, true);
        }
        return;
    }

    const code: usize = cause & 0x3F;
    if (code == 11 or (code & 0x1F) == 11) {
        // M 模式 ecall：跳过这条指令。中断分支绝不能 +4。
        frame.mepc += 4;
        switchCore(smp.me(), true);
        return;
    }

    halt(cause, frame.mepc);
}

/// 任务恢复时调用：把“ISR 到任务”的延迟记进本核统计，并记一次任务级唤醒。
///
/// 口径：`ipis_in` = IPI 到达数（ISR 里加）；`wakeups` = 因 IPI 而真正恢复
/// 执行的任务次数（这里加，每个被唤醒的任务各记一次）。两者不在同一处
/// 自增，避免同一个事件被数两遍。
pub fn noteResume(cpu: *smp.PerCpu) void {
    if (cpu.isr_ts == 0) return;
    cpu.wakeups +%= 1;
    const now = systimer.now();
    smp.recordWakeLatency(cpu, now -% cpu.isr_ts);
    cpu.isr_ts = 0;
}
