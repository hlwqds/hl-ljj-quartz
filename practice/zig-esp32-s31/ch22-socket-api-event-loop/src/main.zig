//! ch22-socket-api-event-loop：板侧程序编排。
//!
//! 顺序四步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围，并明确写死一句
//!      “所有段都由注入源投递，不是真实网络链路”；
//!   2. `selftest.run()` —— 十二条判据各打印一行 `check: ... ok=1/0`，
//!      外加一行脚本指纹读数；
//!   3. 失败即 panic（打印现场后 `wfi`）；
//!   4. 成功打印 verdict 后停机。
//!
//! **本章板侧不碰网口**：没有 MAC、没有 IP 收发、没有中断与时钟。
//! socket 层的输入全部来自 `netstub` 造的段，事件循环的 tick 全部由
//! 调用方注入。真实 socket 要等 ch17（以太网）+ ch20（状态机）+
//! ch21（拥塞控制）闭环，见章节 22.12 的判据。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch22-socket-api-event-loop | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: fd table + socket states + poll/tick timeouts + conn pool + partial rw\n");
    log.raw("note: every segment is injected by netstub - NOT a real network link\n");
    log.raw("host: 28 unit tests via 'zig build test' (27 named + root container)\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, socket contract verified off-link (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
