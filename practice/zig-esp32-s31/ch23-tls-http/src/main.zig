//! ch23-tls-http：板侧程序编排。
//!
//! 顺序四步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围，并明确写死一句
//!      “没有网络、没有真实握手”；
//!   2. `selftest.run()` —— 十三条判据各打印一行 `check: ... ok=1/0`，
//!      外加两行 `read:` 读数（不是判据）；
//!   3. 失败即 panic（打印现场后 `wfi`）；
//!   4. 成功打印 verdict 后停机。
//!
//! **本章板侧不跑协议栈**：没有 MAC、没有 IP 收发、没有 socket、没有中断。
//! 链路层在 ch17（仍未闭环），TCP 在 ch20，socket 与事件循环在 ch22。
//! 本章只交付“TLS 记录层 / 密钥派生 / AEAD / DER 证书 / HTTP 解析”这些
//! 不依赖网络就能判定的部分；真实 HTTPS 收发必须等 ch17 与 ch22 闭环后
//! 另做，本章不代填（判据见章节 23.11）。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch23-tls-http | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: tls1.3 record/keyschedule + x25519 + aes-128-gcm + x509 der + http1.1\n");
    log.raw("note: no network, no real handshake - ch17 link and ch22 event loop pending\n");
    log.raw("host: 32 unit tests via 'zig build test'\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, tls/http primitives verified off-link (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
