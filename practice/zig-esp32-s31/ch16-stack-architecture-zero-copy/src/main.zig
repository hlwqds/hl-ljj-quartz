//! ch16-stack-architecture-zero-copy：板侧程序编排（最小骨架）。
//!
//! 顺序只有三步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围；
//!   2. `selftest.run()` —— 构造帧 → loopback → pbuf 链 → 时间轮 → MTU 拒绝，
//!      每条判据打印一行 `check: ... ok=1/0`；
//!   3. 失败即 panic（打印现场后 `wfi`），成功则打印 verdict 后停机。
//!
//! **本章板侧不实现协议栈运行**：没有 MAC、没有中断、没有 tick。
//! 真正的链路层在 ch17，IPv4/ARP 在 ch18，UDP/DHCP/DNS 在 ch19。
//! 这里只证明“纯逻辑模块能被交叉编译进 rv32 镜像，并且在真实 SRAM 布局下
//! 走完一条自洽的闭环”。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch16-stack-architecture-zero-copy | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: netif + eth/ipv4/udp headers + checksum, no MAC/IRQ (pbuf/wheel are host-only)\n");
    log.raw("host: 55 unit tests via 'zig build test' (authoritative for pbuf/wheel/checksum)\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, skeleton idle (board run 待真机验证)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
