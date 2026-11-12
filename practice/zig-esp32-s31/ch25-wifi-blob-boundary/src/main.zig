//! ch25-wifi-blob-boundary：板侧程序编排。
//!
//! 顺序四步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围，并明确写死一句
//!      “没有射频、没有 Wi-Fi 连接、没有真实 blob 链接”；
//!   2. `selftest.run()` —— 十三条判据各打印一行 `check: ... ok=1/0`，
//!      外加三行 `read:` 读数（不是判据）；
//!   3. 失败即 panic（打印现场后 `wfi`）；
//!   4. 成功打印 verdict 后停机。
//!
//! **本章板侧不跑 Wi-Fi**：`adapter.linked_real_blob` 恒为 `false`，
//! `adapter.callRealBlob()` 只会返回 `not_linked`。链路层在 ch17（仍未闭环），
//! 真实 blob 的链接与 `esp_wifi_init` 路径是本章明确留给后续的边界
//! （判据见章节 25.12）。本章只交付“边界本身”：ABI 布局、版本拒绝、
//! 注册表、事件队列、错误码映射、生命周期、泄漏检测。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch25-wifi-blob-boundary | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: blob abi v1.0 + adapter shim + stub blob (13 checks)\n");
    log.raw("note: no radio, no wifi link, no real blob linked - ch17 link pending\n");
    log.raw("host: 15 unit tests via 'zig build test'\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, blob boundary verified with stub blob (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
