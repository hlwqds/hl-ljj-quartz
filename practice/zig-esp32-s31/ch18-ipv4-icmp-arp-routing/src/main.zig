//! ch18-ipv4-icmp-arp-routing：板侧程序编排（最小骨架）。
//!
//! 顺序只有三步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围；
//!   2. `selftest.run()` —— 13 条判据：地址/掩码、ICMP 回显与应答、IPv4 首部、
//!      分片、乱序重组、最长前缀匹配、ARP 解析/学习/老化/应答、PMTU；
//!   3. 失败即 panic（打印现场后 `wfi`），成功则打印 verdict 后停机。
//!
//! **本章板侧不驱动网卡**：没有 MAC、没有中断、没有 tick。链路层在 ch17，
//! 本章只证明"IPv4/ICMP/ARP/路由的纯逻辑能被交叉编译进 rv32 镜像，并且在
//! 真实 SRAM 布局下走完一条自洽的闭环"。真正的 ping 验收需要把 ch17 的
//! 收发包路径接上（见 README 的"待真机验证"清单）。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch18-ipv4-icmp-arp-routing | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: ipv4 header/frag/reasm + icmp echo/frag-needed + arp cache + route lpm\n");
    log.raw("link: no MAC/DMA/IRQ - ch17 owns the ethernet data path\n");
    log.raw("host: 70 unit tests via 'zig build test' (authoritative for all five modules)\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, skeleton idle (board run 待真机验证)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
