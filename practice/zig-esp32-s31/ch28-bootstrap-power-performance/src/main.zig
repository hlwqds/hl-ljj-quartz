//! ch28-bootstrap-power-performance：板侧编排。
//!
//! 本章是 28A：**不**实现 form C 的 Zig 二级 bootloader，而是把 bootloader
//! 的选槽决策、A/B 回滚、睡眠预算、性能统计做成可离线判定的模型；真机上
//! 仍由 IDF 的二级 bootloader 装载本应用（与 ch24 相同）。
//!
//! 顺序：
//!   1. banner：说清 28A/28B 边界，以及“没有写 flash / 没有真睡”；
//!   2. `selftest.run()`：12 条 `check: ... ok=1/0` + 读数；
//!   3. 失败 panic；
//!   4. 成功 verdict 后停机。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch28-bootstrap-power-performance | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: otadata pick + a/b rollback + sleep budget + perf stats\n");
    log.raw("scope note: 28A only; no custom 2nd-stage bootloader, no flash write, no real sleep\n");
    log.raw("host: zig build test (pure logic; no board)\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, boot/power/perf models verified off-link (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
