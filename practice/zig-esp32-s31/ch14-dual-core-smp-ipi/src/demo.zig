//! ch14-dual-core-smp-ipi：三个可判读的阶段。
//!
//! ## 阶段 A：IPI ping-pong（跨核唤醒 + 往返延迟）
//!
//!   core0 supervisor            core1 worker
//!   ------------------          -------------
//!   requests += 1               （blocked，等 IPI）
//!   wakeRemote(worker,1) ──IPI──▶ ISR：isr_ts=now, need_resched
//!   blockIf(replies>r)          trap 返回前调度 → worker 恢复
//!                               noteResume：记录 ISR→任务 延迟
//!                               干活；replies += 1
//!   （被 IPI 唤醒）      ◀──IPI── wakeRemote(supervisor,0)
//!   t1 = now；记录往返
//!
//! 两个方向都走 `wakeRemote` → 目标核队列 + IPI，没有任何轮询。
//!
//! ## 阶段 B：负载均衡（push 迁移）
//!
//! 4 个 job 任务创建时都躺在池里（blocked）。supervisor 把 2 个挂到
//! core0、2 个挂到 core1 —— 每次挂载都是一次跨核队列操作 + IPI。
//! 两个核各自从自己的队列取任务，最后打印每核完成数；迁移计数单独打印。
//!
//! 这不是“偷取”（steal）：偷取是空闲核主动从对方的队列尾部拿走一半，
//! 需要对方队列的锁 + 一个“对方是否真的空闲”的判据，失败还要回滚。
//! 本章用 push（有活的一方按目标核空闲状态分一半过去）说明同一条硬件链路，
//! 正文里把两者的差别与代价写清楚。
//!
//! ## 阶段 C：汇总（只在 supervisor 里打印一次）
//!
//! 两个核的 tick/唤醒/IPI 计数、往返延迟、ISR→任务延迟全部从 PerCpu 读，
//! **不在 ISR 里打印** —— 串口是共享设备，中断里打印会遇到“任务持锁、
//! ISR 等同一把锁”的自死锁。

const hw = @import("hw.zig");
const smp = @import("smp.zig");
const sched = @import("sched.zig");
const systimer = @import("systimer.zig");
const console = @import("console.zig");

pub const rounds: u32 = 32;
pub const job_count: u32 = 4;
pub const job_steps: u32 = 6;
const job_work: u32 = 30_000;
const worker_work: u32 = 2_000;

// ---- 阶段 A 的闩（latch）----
// 单纯“检查条件 → 阻塞”会丢唤醒：对方可能正好在两步之间满足条件并发 IPI。
// 这里用两个单调计数 + “先标记 blocked、再复查”的 blockIf 关掉窗口。
var requests: u32 = 0; // supervisor 发布的任务请求
var replies: u32 = 0; // worker 发布的完成信号
var worker_round: u32 = 0; // worker 正在等第几轮请求
var sup_round: u32 = 0; // supervisor 正在等第几轮回复

// ---- 阶段 B ----
var jobs_done: u32 = 0;

var stack_supervisor: [4096]u8 align(16) = undefined;
var stack_worker: [2048]u8 align(16) = undefined;
var stack_jobs: [job_count][2048]u8 align(16) = undefined;

pub var supervisor_task: *sched.Task = undefined;
pub var worker_task: *sched.Task = undefined;
var job_tasks: [job_count]*sched.Task = undefined;

fn replyMet() bool {
    return @atomicLoad(u32, &replies, .acquire) > sup_round;
}

fn requestMet() bool {
    return @atomicLoad(u32, &requests, .acquire) > worker_round;
}

fn jobsAllDone() bool {
    return @atomicLoad(u32, &jobs_done, .acquire) >= job_count;
}

/// core0 的 main 调用：建任务、把 supervisor 挂到 core0 的就绪队列。
pub fn setup() void {
    supervisor_task = sched.create("sup", &stack_supervisor, &supervisor, 5, 4, .supervisor);
    worker_task = sched.create("worker", &stack_worker, &worker, 4, 8, .worker);
    var i: u32 = 0;
    while (i < job_count) : (i += 1) {
        job_tasks[i] = sched.create("job", &stack_jobs[i], &jobRunner, 3, 8, .job);
        job_tasks[i].budget = job_steps;
    }
    sched.enqueueLocal(supervisor_task);
}

fn supervisor(_: *sched.Task) callconv(.c) noreturn {
    const me = smp.me();

    console.line("sup: core{d} phase A - ipi ping-pong rounds={d}", .{ me.hart, rounds });

    var r: u32 = 0;
    while (r < rounds) : (r += 1) {
        sup_round = r;
        const t0 = systimer.now();
        _ = @atomicRmw(u32, &requests, .Add, 1, .release);
        sched.wakeRemote(worker_task, 1);

        // 等 core1 的回复。blockIf 会先把自己标成 blocked，再复查一次
        // 谓词，然后才切走 —— 这消掉了“对方在两步之间发 IPI”的丢唤醒。
        while (!replyMet()) sched.blockIf(&replyMet);

        // 被唤醒后先记一次 ISR→任务 的延迟（core0 侧）。
        sched.noteResume(me);
        const t1 = systimer.now();
        smp.recordRoundTrip(me, t1 -% t0);
    }
    console.line("sup: phase A done - core0 pings={d} core1 pings={d}", .{
        smp.cpus[0].pings,
        smp.cpus[1].pings,
    });

    // ---- 阶段 B：把一半的 job push 到 core1 ----
    console.line("bal: push jobs -> core0=2 core1=2 (one IPI per remote enqueue)", .{});
    var migrated: u32 = 0;
    var i: u32 = 0;
    while (i < job_count) : (i += 1) {
        const target: u32 = if (i < 2) 0 else 1;
        sched.wakeRemote(job_tasks[i], target);
        if (target == 1) migrated += 1;
    }
    smp.cpus[0].migrated = migrated;

    while (!jobsAllDone()) sched.blockIf(&jobsAllDone);
    sched.noteResume(me);

    // ---- 阶段 C：汇总 ----
    console.line("jobs: total={d} core0={d} core1={d} migrated={d} steps_each={d}", .{
        job_count,
        smp.cpus[0].jobs,
        smp.cpus[1].jobs,
        migrated,
        job_steps,
    });
    printLatency("rtt", "core0 round-trip (wake->work->wake)", &smp.cpus[0]);
    printWake("isr->task", &smp.cpus[0]);
    printWake("isr->task", &smp.cpus[1]);

    var c: usize = 0;
    while (c < smp.hart_count) : (c += 1) {
        const cpu = &smp.cpus[c];
        console.line("cpu{d}: ticks={d} ipis_in={d} ipis_out={d} wakeups={d} pings={d} switches={d} jobs={d}", .{
            cpu.hart,
            cpu.ticks,
            cpu.ipis_in,
            cpu.ipis_out,
            cpu.wakeups,
            cpu.pings,
            cpu.switches,
            cpu.jobs,
        });
    }
    console.line("barrier: clic mintthresh=0x{x} (0x1f = allow all levels 1..7)", .{
        @import("clic.zig").getThreshold(),
    });
    console.line("result: A/B/C complete (target shape; numbers are 待真机验证)", .{});

    // 结束：supervisor 自己进 done，两个核剩下的只有 idle 的 wfi。
    sched.parkCurrent();
}

fn printLatency(tag: []const u8, what: []const u8, cpu: *smp.PerCpu) void {
    if (cpu.rt_n == 0) {
        console.line("lat[{s}]: na ({s})", .{ tag, what });
        return;
    }
    const avg = cpu.rt_sum / cpu.rt_n;
    console.line("lat[{s}]: {s} min={d} avg={d} max={d} systimer ticks", .{
        tag, what, cpu.rt_min, avg, cpu.rt_max,
    });
    console.line("lat[{s}]: ~ min={d}.{d:0>2} avg={d}.{d:0>2} max={d}.{d:0>2} us (assume {d} MHz)", .{
        tag,
        systimer.ticksToUs(cpu.rt_min),
        systimer.ticksToUsFrac(cpu.rt_min),
        systimer.ticksToUs(avg),
        systimer.ticksToUsFrac(avg),
        systimer.ticksToUs(cpu.rt_max),
        systimer.ticksToUsFrac(cpu.rt_max),
        systimer.nominal_hz / 1_000_000,
    });
}

fn printWake(tag: []const u8, cpu: *smp.PerCpu) void {
    if (cpu.wk_n == 0) {
        console.line("lat[{s}]: cpu{d} na", .{ tag, cpu.hart });
        return;
    }
    const avg = cpu.wk_sum / cpu.wk_n;
    console.line("lat[{s}]: cpu{d} min={d} avg={d} max={d} n={d} systimer ticks", .{
        tag, cpu.hart, cpu.wk_min, avg, cpu.wk_max, cpu.wk_n,
    });
}

/// core1 上的任务：被 IPI 唤醒 → 干活 → 回 IPI。
/// 没有 IPI 时它一直是 blocked，CPU 交给 core1 的 idle（wfi）。
fn worker(_: *sched.Task) callconv(.c) noreturn {
    const me = smp.me();
    while (true) {
        while (!requestMet()) sched.blockIf(&requestMet);

        // 从 ISR 记下的时间戳到这个任务真正恢复，是“跨核唤醒的软件成本”。
        sched.noteResume(me);
        // 口径分开：wakeups 只由 IPI ISR 计数；这里记 ping-pong 的往返次数；
        // jobs 只统计 job 任务。混在一起会把 core1 的 jobs 打成 34。
        me.pings +%= 1;

        hw.burn(worker_work);
        worker_round += 1;

        _ = @atomicRmw(u32, &replies, .Add, 1, .release);
        sched.wakeRemote(supervisor_task, 0);

        // 下一轮请求可能已经在路上；requestMet() 为真时 blockIf 会立即返回。
        if (worker_round >= rounds) {
            // 阶段 A 结束，worker 永久休眠（后面的 job 由 job 任务承担）。
            sched.parkCurrent();
        }
    }
}

fn jobRunner(t: *sched.Task) callconv(.c) noreturn {
    const me = smp.me();
    sched.noteResume(me);

    var i: u32 = 0;
    while (i < t.budget) : (i += 1) {
        hw.burn(job_work);
        t.steps += 1;
        t.ticks +%= 1;
    }
    me.jobs +%= 1;
    t.steps = t.budget;

    const n = @atomicRmw(u32, &jobs_done, .Add, 1, .release) + 1;
    if (n == job_count) {
        // 最后一个完成的 job 唤醒 supervisor（可能在另一个核上）。
        sched.wakeRemote(supervisor_task, 0);
    }
    sched.parkCurrent();
}
