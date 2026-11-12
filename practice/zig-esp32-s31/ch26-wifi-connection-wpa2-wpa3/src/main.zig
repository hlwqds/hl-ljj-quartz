//! ch26-wifi-connection-wpa2-wpa3：板侧程序编排。
//!
//! 顺序四步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围，并明确写死一句
//!      「没有射频、没有 AP、没有链路」；
//!   2. `selftest.run()` —— 十三条判据各打印一行 `check: ... ok=1/0`，
//!      外加三行 `read:` 读数（不是判据）；
//!   3. 失败即 panic（打印现场后 `wfi`）；
//!   4. 成功打印 verdict 后停机。
//!
//! **本章板侧不跑 Wi-Fi**：没有 `esp_wifi_init`、没有扫描、没有认证、
//! 没有 4-way handshake 的真实对端。板上跑的是这些协议**能在离线状态下
//! 被断言的那一层**：PBKDF2/PRF/MIC 的字节级结果、EAPOL 帧的编解码、
//! 重放计数与顺序机的拒绝路径、SAE 的哈希派生、连接状态机与退避。
//!
//! 真链路（扫描到 AP、4-way 成功、拿到 IP）依赖 ch17 闭环与 ch25 的真实
//! blob 链接，判据写在章节 26.11；在这之前，任何「连上了」的说法都是假的。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch26-wifi-connection-wpa2-wpa3 | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: wpa2-psk pmk/ptk/mic + 4way order + sae subset + conn fsm (13 checks)\n");
    log.raw("note: no radio, no AP, no link - ch17 ethernet and ch25 blob still pending\n");
    log.raw("host: 20 unit tests via 'zig build test'\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, wifi connection layer verified off-link (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
