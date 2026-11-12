//! ch12-sync-primitives-ipc：把同步原语的语义变成可判读的串口证据。
//!
//! 一共四个阶段，全部由 prio 7 的 `supervisor` 串起来——它负责“造场景”，
//! 自己不做任何重活：
//!
//! | 阶段 | 任务                          | 在证明什么                                             |
//! | ---- | ----------------------------- | ------------------------------------------------------ |
//! | 0    | spinA / spinB（prio 2 × 2）   | `lr.w`/`sc.w` 与 `amoadd.w` 在抢占下不丢更新            |
//! | A    | L(1) / M(3) / H(5)，无继承    | 优先级反转：H 被 M 拖住，等待时长 ≈ M 的全部忙等        |
//! | B    | L(1) / M(3) / H(5)，有继承    | 继承把 L 抬到 5，M 无法插队，等待时长 ≈ L 的剩余临界区  |
//! | C    | P1/P2 + C1/C2（prio 2 × 4）   | 队列满/空时双向阻塞；事件组把 4 个完成位合成一个汇合点  |
//!
//! 阶段 A/B 的时间线（相对 tick 计数，全部是**验收目标**，未在真机实测）：
//!
//! ```text
//!  t≈0   L: lock; post(locked)                     ← 被 supervisor 抢占
//!  t≈0   supervisor: create M(3), H(5); wait(done) ← 阻塞，交棒给 H
//!  t≈0   H: t0 = ticks; lock → 阻塞（L 持有）
//!         无继承：提升不了 L，选 M(3)               有继承：L→5，选 L(5)
//!  t≈0   M: busy 60 ticks                         L: sleep 30 ticks（抱着锁睡）
//!  t≈30                                            tick 唤醒 L(5)，抢占 M
//!  t≈60  M 结束；L(1) 才终于能跑                    L: burn 后 unlock
//!  t≈90  L: sleep 30 → burn → unlock               H: t1 = ticks
//!        H 等待 ≈ 60 + 30 + ε                     H 等待 ≈ 30
//! ```
//!
//! 两个数字都由 tick 计数器量化（1 tick = 1 ms），差值就是“继承省下的时间”。
//! 本仓不给具体数值：它必须来自真机。

const sched = @import("sched.zig");
const mutex = @import("mutex.zig");
const sem = @import("sem.zig");
const queue = @import("queue.zig");
const events = @import("events.zig");
const spin = @import("spin.zig");

// ---------------------------------------------------------------------------
// 可调参数（全部在一处，方便真机上改一个数就能重测）
// ---------------------------------------------------------------------------

/// L 在临界区里“睡”的 tick 数。抱着锁睡觉是最糟的临界区写法，
/// 但正因为如此，它才把反转的形状放大到 tick 粒度可见。
pub const cs_sleep_ticks: u32 = 30;

/// L 醒来后补的那段忙等（纯整数 nop 循环，不会被优化掉）。
pub const cs_burn: u32 = 20_000;

/// M 的纯 CPU 忙等长度，单位 tick。它是“插队者”的全部成本。
pub const med_busy_ticks: u32 = 60;

/// 自旋阶段每个任务的迭代次数。
pub const spin_iters: u32 = 500;

/// 每个生产者放入的元素个数（消费者取同样多）。
pub const items_per_task: u32 = 6;

// ---------------------------------------------------------------------------
// 同步对象
// ---------------------------------------------------------------------------

/// 阶段 A：关闭优先级继承。
pub var m_no_pi: mutex.Mutex = .{ .name = "m-no-pi", .pi = false };

/// 阶段 B：打开优先级继承。两个互斥量同时存在，对照才干净。
pub var m_pi: mutex.Mutex = .{ .name = "m-pi", .pi = true };

/// L 拿到锁之后的“我已经持锁”通知（初值 0）。
pub var s_locked: sem.Semaphore = .{ .name = "locked" };

/// 每个任务收尾时 `post` 一次，supervisor 按次数 `wait`。
/// 用它而不是事件位：这里要的是“三个都完成了”，而计数信号量在
/// 没人等待时会累积，正好避免“post 早于 wait”丢事件。
pub var s_done: sem.Semaphore = .{ .name = "done" };

pub var q: queue.Queue = .{ .name = "q" };
pub var eg: events.EventGroup = .{ .name = "eg" };
pub var lk: spin.SpinLock = .{};

// ---------------------------------------------------------------------------
// 测量结果
// ---------------------------------------------------------------------------

pub var wait_ticks_no_pi: u32 = 0;
pub var wait_ticks_pi: u32 = 0;
pub var locked_counter: u32 = 0;
pub var atomic_counter: u32 = 0;
pub var cons_items: [2]u32 = .{ 0, 0 };
pub var cons_sum: [2]u32 = .{ 0, 0 };
pub var cons_bad: [2]u32 = .{ 0, 0 };

// 事件位
pub const ev_prod1: u32 = 1 << 0;
pub const ev_prod2: u32 = 1 << 1;
pub const ev_cons1: u32 = 1 << 2;
pub const ev_cons2: u32 = 1 << 3;
pub const ev_all: u32 = ev_prod1 | ev_prod2 | ev_cons1 | ev_cons2;

// ---------------------------------------------------------------------------
// 栈：每个任务一块，**绝不共用**
// ---------------------------------------------------------------------------
//
// 真机发现（ch11 板级验证，2026-11-11）：ch11 让 idle 复用 main 的 `_stack_top`，
// 全部任务结束后切回 idle 时从被覆盖的帧里恢复 ra，跳到栈地址 → instruction
// access fault。教训：任务被换下后，它的栈里存的就是“下次恢复要用的现场”，
// 因此栈必须独占；复用任何别的东西都等于让两个上下文抢同一块内存。
// 本章的 idle 也因此有自己的一块（见 sched.zig 的 `idle_stack`）。

const stack_bytes = 3072;

var stk_spin_a: [stack_bytes]u8 align(16) = undefined;
var stk_spin_b: [stack_bytes]u8 align(16) = undefined;

var stk_a_low: [stack_bytes]u8 align(16) = undefined;
var stk_a_med: [stack_bytes]u8 align(16) = undefined;
var stk_a_high: [stack_bytes]u8 align(16) = undefined;

var stk_b_low: [stack_bytes]u8 align(16) = undefined;
var stk_b_med: [stack_bytes]u8 align(16) = undefined;
var stk_b_high: [stack_bytes]u8 align(16) = undefined;

var stk_p1: [stack_bytes]u8 align(16) = undefined;
var stk_p2: [stack_bytes]u8 align(16) = undefined;
var stk_c1: [stack_bytes]u8 align(16) = undefined;
var stk_c2: [stack_bytes]u8 align(16) = undefined;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

/// 纯整数忙等：`asm volatile` 保证不被优化掉，也不引入浮点
/// （浮点帧是 208 字节，本系列还没实现）。
fn burn(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        asm volatile ("nop");
    }
}

/// 占着 CPU 忙等到“经过 n 个 tick”。用 tick 计数而不是指令数来定长：
/// 指令数要除以主频才成时间，而主频在 S31 上还不是本章的已知量。
fn busyTicks(n: u32) void {
    const t0 = sched.tickCount();
    // `-%`：计数器是 u32，理论上会回绕（49 天）。用回绕减法让差值始终正确，
    // 而不是让 ReleaseSmall 静默溢出或在 Debug 下 panic。
    while (sched.tickCount() -% t0 < n) {
        asm volatile ("nop");
    }
}

/// 收尾的统一形状：打印 → 标 done → 通知 → 永久让出。
///
/// 顺序很重要：先 `markDone` 再 `post`。反过来的话，被唤醒的高优先级任务
/// 抢占进来时，这个 TCB 还是 `running`，可能被重新选中并继续执行
/// `done` 之后的代码（ch11 真机复现过这种“死任务复活”）。
fn retire(t: *sched.Task, s: *sem.Semaphore) noreturn {
    sched.markDone(t);
    sem.post(s);
    sched.parkForever();
}

// ---------------------------------------------------------------------------
// 阶段 0：自旋锁与原子加
// ---------------------------------------------------------------------------

fn spinBody(t: *sched.Task) noreturn {
    var i: u32 = 0;
    while (i < spin_iters) : (i += 1) {
        // 关中断 + LR/SC 自旋：单核上第一次必然成功（没有第二个 hart），
        // 所以 retries 应当恒为 0——这是“自旋没打到真竞争”的证据，
        // 而不是“自旋没用”。真正的竞争要等 ch14 的双核。
        const saved = spin.acquire(&lk);
        locked_counter += 1;
        spin.release(&lk, saved);

        // 不需要锁的计数器：amoadd.w 本身就是原子的。
        _ = spin.addOne(&atomic_counter);
    }
    t.steps = spin_iters;
    retire(t, &s_done);
}

pub fn spinA(t: *sched.Task) callconv(.c) noreturn {
    spinBody(t);
}

pub fn spinB(t: *sched.Task) callconv(.c) noreturn {
    spinBody(t);
}

// ---------------------------------------------------------------------------
// 阶段 A/B：优先级反转的两个版本
// ---------------------------------------------------------------------------

/// 低优先级持有者：拿锁 → 通知 → **抱着锁睡觉** → 补一小段忙等 → 放锁。
///
/// 抱着锁睡觉违反“临界区要短”的铁律，是故意的：它把临界区拉长到
/// tick 粒度，让“中优先级插队”这件事在 1 ms 分辨率下可见。
/// 真实代码里应该是“拿锁 → 改几个字节 → 放锁”。
fn lowBody(t: *sched.Task, m: *mutex.Mutex) noreturn {
    mutex.lock(m);
    t.steps = 1; // 标记“已持锁”
    sem.post(&s_locked);

    sched.sleepTicks(cs_sleep_ticks);
    burn(cs_burn);

    mutex.unlock(m);
    t.steps = 2; // 标记“已放锁”
    retire(t, &s_done);
}

/// 中优先级任务：纯 CPU 忙等，**不碰锁**。它是反转的“插队者”：
/// 只要它在跑，prio 1 的持有者就没机会放锁。
fn medBody(t: *sched.Task) noreturn {
    busyTicks(med_busy_ticks);
    t.steps = 1;
    retire(t, &s_done);
}

/// 高优先级等待者：记录“开始等”与“拿到锁”两个 tick 时刻。
/// 差值就是本次反转的代价，单位 ms（tick 周期 1 ms）。
fn highBody(t: *sched.Task, m: *mutex.Mutex, out: *u32) noreturn {
    const t0 = sched.tickCount();
    mutex.lock(m);
    const t1 = sched.tickCount();
    out.* = t1 -% t0;
    t.steps = 1;
    mutex.unlock(m);
    retire(t, &s_done);
}

pub fn lowNoPi(t: *sched.Task) callconv(.c) noreturn {
    lowBody(t, &m_no_pi);
}

pub fn medNoPi(t: *sched.Task) callconv(.c) noreturn {
    medBody(t);
}

pub fn highNoPi(t: *sched.Task) callconv(.c) noreturn {
    highBody(t, &m_no_pi, &wait_ticks_no_pi);
}

pub fn lowPi(t: *sched.Task) callconv(.c) noreturn {
    lowBody(t, &m_pi);
}

pub fn medPi(t: *sched.Task) callconv(.c) noreturn {
    medBody(t);
}

pub fn highPi(t: *sched.Task) callconv(.c) noreturn {
    highBody(t, &m_pi, &wait_ticks_pi);
}

// ---------------------------------------------------------------------------
// 阶段 C：队列（生产者 / 消费者）+ 事件组（汇合点）
// ---------------------------------------------------------------------------

fn producerBody(t: *sched.Task, id: u32) noreturn {
    var i: u32 = 0;
    while (i < items_per_task) : (i += 1) {
        // 高 16 位 = 生产者编号，低 16 位 = 序号（从 1 开始）。
        const v = (id << 16) | (i + 1);
        queue.put(&q, v);
        t.steps += 1;
    }
    sched.markDone(t);
    events.set(&eg, if (id == 1) ev_prod1 else ev_prod2);
    sched.parkForever();
}

fn consumerBody(t: *sched.Task, idx: usize) noreturn {
    var got: u32 = 0;
    var sum: u32 = 0;
    var bad: u32 = 0;
    while (got < items_per_task) : (got += 1) {
        const v = queue.get(&q);
        const who = (v >> 16) & 0xFFFF;
        const seq = v & 0xFFFF;
        if (who == 0 or who > 2 or seq == 0 or seq > items_per_task) bad += 1;
        sum +%= v;
        t.steps += 1;
    }
    cons_items[idx] = got;
    cons_sum[idx] = sum;
    cons_bad[idx] = bad;

    sched.markDone(t);
    events.set(&eg, if (idx == 0) ev_cons1 else ev_cons2);
    sched.parkForever();
}

pub fn prod1(t: *sched.Task) callconv(.c) noreturn {
    producerBody(t, 1);
}
pub fn prod2(t: *sched.Task) callconv(.c) noreturn {
    producerBody(t, 2);
}
pub fn cons1(t: *sched.Task) callconv(.c) noreturn {
    consumerBody(t, 0);
}
pub fn cons2(t: *sched.Task) callconv(.c) noreturn {
    consumerBody(t, 1);
}

// ---------------------------------------------------------------------------
// supervisor：唯一的编排者（prio 7）
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// monitor：心跳任务（prio 6）
// ---------------------------------------------------------------------------
//
// 真机教训（2026-11-13）：两次“静默停住”都只留下一行不再变化的串口输出，
// 而静默对应的可能是三种完全不同的故障：
//   (a) tick ISR 死了           → 心跳不再前进；
//   (b) 某任务永久阻塞           → 心跳照走，blocked 名单里躺着它；
//   (c) 就绪链被写坏             → 心跳照走，ready 计数与预期不符。
// idle 里的 STALL 只能覆盖“一个就绪任务都没有”的那种，而 (b)/(c) 常见形态是
// **CPU 100% 忙**——idle 根本轮不到，STALL 永远不会打印。
//
// 所以加一个每 50 tick 打一行快照的心跳任务：它自己不碰互斥量、不碰信号量、
// 不碰队列，只用 `sleepTicks(50)` + 只读探针。它是最后一个可能说谎的东西：
// 心跳停了而睡链里明明有它，就说明 tick 或睡眠链断了。
/// 心跳要带的中断侧状态：`mie`（MEIE 在 bit11）与 `mstatus`（MIE 在 bit3）。
///
/// 为什么心跳里必须有这两项：真机上“tick 不再来”只有四种可能——
/// CLIC 输入被关、矩阵映射被改、`mie.MEIE` 被清、`mstatus.MIE` 被清。
/// 前两种只能靠寄存器转储，后两种这一行就能看出来。上一轮查“静默停住”时
/// 缺的正是这个信息。
fn readMie() usize {
    return asm volatile ("csrr %[d], mie"
        : [d] "=r" (-> usize),
    );
}

fn readMstatus() usize {
    return asm volatile ("csrr %[d], mstatus"
        : [d] "=r" (-> usize),
    );
}

pub fn monitor(t: *sched.Task) callconv(.c) noreturn {
    var n: u32 = 0;
    while (n < 10) : (n += 1) {
        sched.sleepTicks(50);
        sched.line("mon#{d}: tick={d} cur={s} ready=[{d} {d} {d} {d} {d} {d} {d} {d}] blocked={d} sleep={d} mie=0x{x} mst=0x{x}", .{
            n,               sched.tickCount(), sched.currentName(),
            sched.readyCount(0), sched.readyCount(1),
            sched.readyCount(2), sched.readyCount(3),
            sched.readyCount(4), sched.readyCount(5),
            sched.readyCount(6), sched.readyCount(7),
            sched.blockedCount(), sched.sleepCount(),
            readMie(), readMstatus(),
        });
    }
    t.steps = 10;
    sched.markDone(t);
    sched.parkForever();
}

const Entry = *const fn (*sched.Task) callconv(.c) noreturn;

const Phase = struct {
    tag: []const u8,
    m: *mutex.Mutex,
    stk_low: []u8,
    stk_med: []u8,
    stk_high: []u8,
    n_low: []const u8,
    n_med: []const u8,
    n_high: []const u8,
    low: Entry,
    med: Entry,
    high: Entry,
    out: *u32,
};

/// 等 L 真的持锁之后的一次校验。
///
/// 这里**不再轮询**：`sem.wait(&s_locked)` 由 L 在 `lock` 之后 `post`，
/// 走 handoff 直接唤醒 supervisor（poster 当场换栈，不依赖 tick）。
/// 真机上“靠 tick 轮询”的那一版会让 supervisor 停在第一次 sleep 里
/// （见 README「为什么等待必须由 post 驱动」），所以等待一律交回
/// 阻塞式信号量：它由**生产者**驱动，不由时间驱动。
///
/// `m.owner` 只用来复核“信号量说的事是真的”：通知可能丢，事实不会。
fn verifyOwner(m: *mutex.Mutex) bool {
    return m.owner != null;
}

/// 跑一次反转演示：
///   create L(1) → 等它真的持锁 → create M(3) → create H(5) → 等三个都完成。
///
/// **“等 L 持锁”这一步不能省。** 高优先级任务先跑；如果 H 在 L 之前
/// 尝试加锁，锁是空的，H 直接拿到——整个反转根本不发生，
/// 而日志会“看起来正常”。
///
/// 这一步的判据是 `m.owner`（事实），不是“收到过一条 post”（通知）：
/// 真机上通知与等待的配对一旦出错，阻塞式等待就再也不会返回。
fn runPhase(p: Phase) void {
    const t0 = sched.tickCount();
    const boosts_before = p.m.boosts;

    sched.line("phase {s}: begin, creating {s}(prio 1)", .{ p.tag, p.n_low });
    _ = sched.create(p.n_low, p.stk_low, @intFromPtr(p.low), 1, 2);

    // L 拿到锁之后 post 一次；这里阻塞等待，由 post 当场唤醒（handoff）。
    sem.wait(&s_locked);
    if (verifyOwner(p.m)) {
        sched.line("phase {s}: {s} holds {s}", .{ p.tag, p.n_low, p.m.name });
    } else {
        sched.line("phase {s}: WARN locked signal but owner=none", .{p.tag});
    }

    _ = sched.create(p.n_med, p.stk_med, @intFromPtr(p.med), 3, 2);
    _ = sched.create(p.n_high, p.stk_high, @intFromPtr(p.high), 5, 2);
    sched.line("phase {s}: {s}(3) and {s}(5) created", .{ p.tag, p.n_med, p.n_high });

    // 三个任务各 post 一次。计数信号量可以在没人等时累积，
    // 所以“post 早于 wait”不会丢事件。
    sem.wait(&s_done);
    sem.wait(&s_done);
    sem.wait(&s_done);

    const t1 = sched.tickCount();
    sched.line("phase {s}: high_wait={d} ticks boosts={d} span={d} ticks", .{
        p.tag, p.out.*, p.m.boosts - boosts_before, t1 -% t0,
    });
}

pub fn supervisor(t: *sched.Task) callconv(.c) noreturn {
    sched.line("ch12: sync primitives & IPC - blocked state, PI, queue, events", .{});
    sched.line("cfg: cs_sleep={d} tick, cs_burn={d} nop, med_busy={d} tick, spin_iters={d}", .{
        cs_sleep_ticks, cs_burn, med_busy_ticks, spin_iters,
    });
    sched.line("cfg: queue cap={d}, items/task={d}, prios L=1 M=3 H=5 supervisor=7", .{
        queue.capacity, items_per_task,
    });

    // ---- 阶段 0 -----------------------------------------------------------
    _ = sched.create("spinA", &stk_spin_a, @intFromPtr(&spinA), 2, 2);
    _ = sched.create("spinB", &stk_spin_b, @intFromPtr(&spinB), 2, 2);
    sem.wait(&s_done);
    sem.wait(&s_done);
    sched.line("spin: locked={d} atomic={d} expected={d} acq={d} lr_sc_retries={d}", .{
        locked_counter,
        atomic_counter,
        2 * spin_iters,
        spin.acquisitions,
        spin.retries,
    });

    // ---- 阶段 A：无优先级继承 --------------------------------------------
    runPhase(.{
        .tag = "no-pi",
        .m = &m_no_pi,
        .stk_low = &stk_a_low,
        .stk_med = &stk_a_med,
        .stk_high = &stk_a_high,
        .n_low = "L1",
        .n_med = "M1",
        .n_high = "H1",
        .low = &lowNoPi,
        .med = &medNoPi,
        .high = &highNoPi,
        .out = &wait_ticks_no_pi,
    });

    // ---- 阶段 B：有优先级继承 --------------------------------------------
    runPhase(.{
        .tag = "pi",
        .m = &m_pi,
        .stk_low = &stk_b_low,
        .stk_med = &stk_b_med,
        .stk_high = &stk_b_high,
        .n_low = "L2",
        .n_med = "M2",
        .n_high = "H2",
        .low = &lowPi,
        .med = &medPi,
        .high = &highPi,
        .out = &wait_ticks_pi,
    });

    // ---- 阶段 C：队列 + 事件组 -------------------------------------------
    _ = sched.create("P1", &stk_p1, @intFromPtr(&prod1), 2, 2);
    _ = sched.create("P2", &stk_p2, @intFromPtr(&prod2), 2, 2);
    _ = sched.create("C1", &stk_c1, @intFromPtr(&cons1), 2, 2);
    _ = sched.create("C2", &stk_c2, @intFromPtr(&cons2), 2, 2);

    // 先演示 any（谁先完成都算），再演示 all（四个都完成才继续）。
    // `.any` 返回后立刻打一行**部分**统计：若队列阶段后面卡住，
    // 这行能区分“生产者写不进去”与“消费者取不出来”。
    const first = events.wait(&eg, ev_all, .any);
    sched.line("events: any -> bits=0x{x} (first finisher)", .{first});
    sched.line("queue(partial): puts={d} gets={d} high={d}/{d} pb={d} gb={d}", .{
        q.puts, q.gets, q.high_water, queue.capacity, q.put_blocks, q.get_blocks,
    });
    const allv = events.wait(&eg, ev_all, .all);
    sched.line("events: all -> bits=0x{x} reblocks={d}", .{ allv, eg.reblocks });

    sched.line("queue: puts={d} gets={d} high_water={d}/{d} put_blocks={d} get_blocks={d}", .{
        q.puts, q.gets, q.high_water, queue.capacity, q.put_blocks, q.get_blocks,
    });
    sched.line("queue: C1 items={d} sum=0x{x} bad={d} | C2 items={d} sum=0x{x} bad={d}", .{
        cons_items[0], cons_sum[0], cons_bad[0],
        cons_items[1], cons_sum[1], cons_bad[1],
    });

    // ---- 结论 -------------------------------------------------------------
    sched.line("sem: locked(blocks={d}) done(posts={d} blocks={d} accumulated={d})", .{
        s_locked.blocks, s_done.posts, s_done.blocks, s_done.accumulated,
    });
    sched.line("result: inversion wait no_pi={d} tick vs pi={d} tick (lower is better)", .{
        wait_ticks_no_pi, wait_ticks_pi,
    });
    if (wait_ticks_no_pi > wait_ticks_pi) {
        sched.line("result: inheritance saved {d} tick (~{d} ms)", .{
            wait_ticks_no_pi -% wait_ticks_pi,
            wait_ticks_no_pi -% wait_ticks_pi,
        });
    } else {
        sched.line("result: UNEXPECTED - no inversion observed; check med_busy >= cs_sleep", .{});
    }

    t.steps = 4; // 四个阶段
    sched.line("supervisor: 4 phases complete, handing over to idle", .{});
    sched.markDone(t);
    sched.parkForever();
}
