//! ch21-tcp-congestion：板侧程序编排。
//!
//! 顺序四步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围，并明确写死一句
//!      “吞吐数字来自主机侧仿真，不是真链路”；
//!   2. `selftest.run()` —— 十个判据各打印一行 `check: ... ok=1/0`，
//!      外加三行曲线/指纹读数；
//!   3. 失败即 panic（打印现场后 `wfi`）；
//!   4. 成功打印 verdict 后停机。
//!
//! **本章板侧不跑协议栈**：没有 MAC、没有 IP 收发、没有中断与 tick。
//! 链路层在 ch17（仍未闭环），可靠传输状态机在 ch20，本章只交付
//! “窗口该怎么变”的控制律与它的确定性仿真。真实链路上的吞吐/时延曲线
//! 必须等 ch17 闭环后另做，本章不代填。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch21-tcp-congestion | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: cwnd/ssthresh/rto/bdp/pacing/nagle + deterministic loss sim\n");
    log.raw("note: throughput numbers are host-side simulation, NOT a real link\n");
    log.raw("host: 21 unit tests via 'zig build test' (20 named + root container)\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, congestion control law verified off-link (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
