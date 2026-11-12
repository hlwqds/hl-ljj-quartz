//! ch12-sync-primitives-ipc：建一个 supervisor 任务，然后把 `main` 交给 idle。
//!
//! 本章没有“主循环”。`main` 只做三件事：打印配置、创建 supervisor（prio 7）、
//! 调用 `sched.start()`。从那一刻起控制权归调度器，`main` 的栈被放弃，
//! idle 循环跑在它自己的独立栈上（见 sched.zig 的 `start`/`idleLoop`）。
//!
//! 启动顺序的三个硬约束（与 ch11 相同，本章一条都没放松）：
//!   1. `tick.init()` 必须在 `MIE = 1` 之前；
//!   2. `mtvec` 已在 `_start` 里装好，早于任何 `ecall` 与 tick；
//!   3. 本章额外一条：**切到 idle 的栈必须在打开 MIE 之前**，
//!      否则第一次 tick 会把 main 的 sp 存进 idle 的 TCB（ch11 的崩溃形状）。

const sched = @import("sched.zig");
const context = @import("context.zig");
const tasks = @import("tasks.zig");
const tick = @import("tick.zig");
const mutex = @import("mutex.zig");
const sem = @import("sem.zig");
const queue = @import("queue.zig");
const events = @import("events.zig");
const spin = @import("spin.zig");

/// supervisor 的栈（其余任务的栈在 tasks.zig）。
var stack_supervisor: [4096]u8 align(16) = undefined;

/// 心跳任务的栈。它只打印一行、不调用任何同步原语，
/// 单独一块是为了“它挂掉”这件事本身能被读出来。
var stack_monitor: [2048]u8 align(16) = undefined;

fn readMtvec() usize {
    return asm volatile ("csrr %[d], mtvec"
        : [d] "=r" (-> usize),
    );
}

/// CLIC 的向量表基址（CSR 0x307）。`mtvec.MODE = 3` 是 CLIC 模式；
/// 若某次上板看到 mode=3，就必须同时看 mtvt 才能判断中断到底从哪里进。
fn readMtvt() usize {
    // 汇编器不认识 `mtvt` 这个名字（没有 ziclic 扩展），用 CSR 编号 0x307。
    return asm volatile ("csrr %[d], 0x307"
        : [d] "=r" (-> usize),
    );
}

fn readMie() usize {
    return asm volatile ("csrr %[d], mie"
        : [d] "=r" (-> usize),
    );
}

pub export fn main() noreturn {
    const mtvec = readMtvec();

    sched.line("ch12-sync-primitives-ipc | form B (Zig ELF + IDF 2nd-stage bootloader)", .{});
    sched.line("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)", .{});
    // 本章 `_start` 写的是 `csrw mtvec, trapEntry`，trapEntry 4 字节对齐，
    // 因此软件只会写进 mode=0。若这里读回 mode=3，说明 mode 位由硬件决定
    // （CLIC 模式）或被别处改过——那就必须连 mtvt 一起看，
    // 判断中断是按“单一入口”还是“向量表”投递。
    sched.line("mtvec: base=0x{x} mode={d} mtvt=0x{x} mie=0x{x}", .{
        mtvec & ~@as(usize, 3),
        mtvec & 3,
        readMtvt(),
        readMie(),
    });
    sched.line("frames: trap={d} switch={d} bytes (integer only)", .{
        context.trap_frame_bytes,
        context.switch_frame_bytes,
    });
    sched.line("tick: {d} us via TIMG0 T0 (source {d}) -> clic input {d} prio {d}", .{
        tick.period_us,
        tick.source,
        tick.input,
        tick.prio,
    });
    sched.line("pool: max_tasks={d} prio_levels={d} idle_stack=4096B own stack", .{
        sched.max_tasks,
        sched.prio_levels,
    });

    // 这些引用保证同步原语的符号一定被发射（本章的用法全部经由 tasks.zig，
    // 但把类型打印出来能让“谁在用哪些原语”在日志里有据可查）。
    sched.line("prims: mutex(pi={s}) sem(count) queue(cap={d}) events(32 bits) spin(A ext)", .{
        if (tasks.m_pi.pi) "on" else "off",
        queue.capacity,
    });
    _ = &mutex.init;
    _ = &sem.init;
    _ = &queue.init;
    _ = &events.init;
    _ = &spin.acquire;

    // monitor 先建：它是“系统还活着”的唯一证据，必须比 supervisor 更早存在。
    _ = sched.create("mon", &stack_monitor, @intFromPtr(&tasks.monitor), 6, 1);
    _ = sched.create("sup", &stack_supervisor, @intFromPtr(&tasks.supervisor), 7, 4);
    sched.line("sched: {d} task created (+idle), preemptive, blocked-capable", .{
        sched.taskCount(),
    });

    tick.init(tick.period_us);
    sched.start();
}
