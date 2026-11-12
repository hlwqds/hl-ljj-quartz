//! ch19-udp-dhcp-dns：板侧程序编排（最小骨架）。
//!
//! 顺序只有三步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围；
//!   2. `selftest.run()` —— DISCOVER → UDP → 端口分派 → OFFER → ACK → T1 续租，
//!      再走一遍 DNS 查询 → 压缩指针响应 → 缓存命中/过期，每条判据打印一行
//!      `check: ... ok=1/0`；
//!   3. 失败即 panic（打印现场后 `wfi`），成功则打印 verdict 后停机。
//!
//! **本章板侧不实现协议栈运行**：没有 MAC、没有 IP 收发、没有中断与 tick。
//! 链路层在 ch17，IPv4/ICMP/ARP 在 ch18；本章只证明“UDP/DHCP/DNS 的纯逻辑
//! 能被交叉编译进 rv32 镜像，并在真实 SRAM 布局下走完两条自洽的流程”。
//! 真正“从路由器拿到 IP”需要 ch17 + ch18 + 本章三件套一起上板，验收路径
//! 写在章节 19.14。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch19-udp-dhcp-dns | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: udp + dhcp client + dns resolver, no MAC/IPv4/IRQ (host tests are authoritative)\n");
    log.raw("host: 49 unit tests via 'zig build test' (48 named + root container)\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, skeleton idle (board run 待真机验证)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
