//! ch20-tcp-state-machine：板侧程序编排（最小骨架）。
//!
//! 顺序只有三步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围、证据从哪来；
//!   2. `selftest.run()` —— 十个注入场景，每条判据打印一行
//!      `check: ... ok=1/0`；
//!   3. 失败即 panic（打印现场后 `wfi`），成功则打印 verdict 后停机。
//!
//! **本章板侧不实现协议栈运行**：没有 MAC、没有 IP 收发、没有中断与 tick。
//! 链路层在 ch17，IPv4/ICMP/ARP 在 ch18；本章只证明“TCP 的纯逻辑能被交叉
//! 编译进 rv32 镜像，并在真实 SRAM 布局下走完十个自洽的场景”。
//! 真实链路上的握手/重传联调必须等 ch17 闭环，验收路径写在章节 20.12。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch20-tcp-state-machine | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: tcp segment codec + seq math + state machine + rto + reasm; no MAC/IPv4/IRQ\n");
    log.raw("host: 27 unit tests via 'zig build test' (26 named + root container)\n");
    log.raw("evidence: injected in-memory segments only; real-link handshake 待 ch17 闭环\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, skeleton idle (real link 待真机验证)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
