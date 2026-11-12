//! ch15-observability-testing-stability：程序编排。
//!
//! 顺序是固定的，每一步都为下一步提供前提：
//!
//!   1. `hw.initTimer()`      —— 后面所有时间戳都来自它；
//!   2. banner + build 选项   —— 让串口第一行就说明“这次跑的是哪种形态”；
//!   3. `check.runAll()`      —— 六组启动自检，硬判据失败即 panic（时钟校准只是 advisory）；
//!   4. 心跳 + trace           —— 8 个 250 ms 周期，打印时间戳与环状态；
//!   5. 可恢复断言            —— `check.expect` 故意失败一次并继续；
//!   6. 软件 watchdog          —— 演示“到期检测 + 恢复计数”；
//!   7. 可选压测               —— `-Dstress=true` 时跑 30 s；
//!   8. panic 路径             —— `-Dpanic-demo=true`（默认）时故意执行非法指令，
//!                               走 trapEntry → trapDispatch → dump → wfi。
//!
//! **本章没有调度器、没有任务切换**：单线程顺序执行，`MIE` 恒为 0。
//! 因此这里不涉及任何 switch 帧/上下文恢复的写法（那部分见 ch10–ch12）。

const build_options = @import("build_options");

const check = @import("check.zig");
const hw = @import("hw.zig");
const log = @import("log.zig");
const stress = @import("stress.zig");
const trace = @import("trace.zig");
const trap = @import("trap.zig");
const watchdog = @import("watchdog.zig");

const heartbeat_period_us: u32 = 250_000;
const heartbeat_count: u32 = 8;

fn heartbeat(boot_us: u64) void {
    var seq: u32 = 0;
    while (seq < heartbeat_count) : (seq += 1) {
        hw.delayUs(heartbeat_period_us);
        const now = hw.nowUs();
        const rel = now -| boot_us;
        trace.g_ring.push(.{
            .t_us = rel,
            .tag = .heartbeat,
            .a = seq,
            .b = @truncate(rel / 1000),
        });
        log.line("hb: seq={d} t={d}ms ring={d}/{d} span={d}us", .{
            seq,
            rel / 1000,
            trace.g_ring.count(),
            trace.capacity,
            trace.g_ring.spanUs(),
        });
    }
}

fn watchdogDemo() void {
    // 截止时间 100 ms：先喂一次，30 ms 后必须“未到期”，再等 90 ms 必须到期。
    var wd = watchdog.Watchdog.init(100_000);
    wd.feed(hw.nowUs());
    hw.delayUs(30_000);
    const early = wd.expired(hw.nowUs());
    hw.delayUs(90_000);
    const recovered = wd.checkAndRecover(hw.nowUs());

    log.line("wdt: deadline=100ms early_expired={d} recovered={d} trips={d}", .{
        @intFromBool(early), @intFromBool(recovered), wd.trips,
    });
    log.raw("wdt: demo only - production should escalate to trap.panic\n");
    trace.g_ring.push(.{
        .t_us = hw.nowUs(),
        .tag = .watchdog,
        .a = wd.trips,
        .b = @intFromBool(recovered),
    });
    // 可恢复断言：early 必须为 false、recovered 必须为 true。
    _ = check.expect(!early and recovered, "watchdog deadlines");
}

fn assertDemo() void {
    // 第一条必须通过；第二条是故意失败，用来证明“捕获 + 继续”这条路径真的存在。
    _ = check.expect(trace.capacity == 32, "trace capacity is 32");
    const caught = check.expect(false, "demo: injected invariant failure");
    log.line("assert: demo caught={d} (recoverable path exercised)", .{@intFromBool(caught)});
}

pub export fn main() noreturn {
    hw.initTimer();
    const boot_us = hw.nowUs();

    log.raw("ch15-observability-testing-stability | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.line("build: stress={d} panic_demo={d} trace_cap={d}", .{
        @intFromBool(build_options.stress),
        @intFromBool(build_options.panic_demo),
        trace.capacity,
    });
    log.raw("clock: TIMG0 T0 1MHz (XTAL 40MHz / 40), MIE=0, no scheduler\n");
    trace.g_ring.push(.{ .t_us = 0, .tag = .boot, .a = 15, .b = 0 });

    // `_start` 已经关过一次；这里再按 IDF 的顺序做一遍并回读，
    // 让“关狗”从一段看不见的汇编变成一行可核对的证据。
    const wdt = hw.disableRtcWdt();
    log.line("wdt: rtc before=0x{x} after=0x{x} tries={d}", .{
        wdt.before, wdt.after, wdt.tries,
    });

    if (!check.runAll()) {
        trap.panic("check: failed - refusing to run with a broken assumption", .{});
    }

    heartbeat(boot_us);
    assertDemo();
    watchdogDemo();

    if (build_options.stress) {
        stress.run(30);
    } else {
        log.raw("stress: skipped (build with -Dstress=true for the 30 s soak)\n");
    }

    if (build_options.panic_demo) {
        log.raw("main: panic demo - next instruction is illegal (0x00000000)\n");
        trap.trip();
    }

    log.raw("main: soak complete (panic demo disabled), halting\n");
    hw.halt();
}
