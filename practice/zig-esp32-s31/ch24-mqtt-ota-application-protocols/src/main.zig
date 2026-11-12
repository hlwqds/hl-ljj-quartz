//! ch24-mqtt-ota-application-protocols：板侧程序编排。
//!
//! 顺序四步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围，并明确写死一句
//!      “没有 broker、没有链路、没有写 flash”；
//!   2. `selftest.run()` —— 13 条判据各打印一行 `check: ... ok=1/0`，
//!      外加两行 `read:` 读数（不是判据）；
//!   3. 失败即 panic（打印现场后 `wfi`）；
//!   4. 成功打印 verdict 后停机。
//!
//! **本章板侧不跑网络**：没有 MAC/DMA（ch17 未闭环）、没有 TCP 连接、
//! 没有 TLS/WebSocket，也不写 flash（分区表仍是 single-app-large）。
//! 本章交付的是“MQTT 3.1.1 报文的字节形状 + 会话时序 + OTA 清单的信任链 +
//! A/B 回滚决策”，这些都能在不联网、不擦写 flash 的前提下判定。
//! 真实 broker 连接与真实 OTA 升级的判据写在章节 24.11，要等 ch17 与 ch09
//! 闭环之后才成立。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch24-mqtt-ota-application-protocols | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: mqtt 3.1.1 codec + session tick + ota manifest (sha256/ed25519) + a/b rollback\n");
    log.raw("note: no broker, no link, no flash write - ch17 ethernet and ch09 flash pending\n");
    log.raw("host: 27 unit tests via 'zig build test'\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, mqtt/ota primitives verified off-link (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
