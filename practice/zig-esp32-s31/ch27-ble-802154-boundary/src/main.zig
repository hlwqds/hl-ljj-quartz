//! ch27-ble-802154-boundary：板侧程序编排。
//!
//! 顺序四步：
//!
//!   1. banner —— 说明这次跑的是哪套骨架、什么范围，并明确写死一句
//!      “没有射频、没有扫描、没有连接、没有入网”；
//!   2. `selftest.run()` —— 十二条判据各打印一行 `check: ... ok=1/0`，
//!      外加四行 `read:` 读数（不是判据）；
//!   3. 失败即 panic（打印现场后 `wfi`）；
//!   4. 成功打印 verdict 后停机。
//!
//! **本章板侧不跑协议栈**：HCI 是字节编解码、ATT/GATT 是定长表、
//! 802.15.4 是帧头变换、6LoWPAN 是无状态解压。真实扫描/连接/读特征值/
//! Thread 入网需要 controller 归档与 PHY 一起链接，判据见章节 27.11。

const hw = @import("hw.zig");
const log = @import("log.zig");
const selftest = @import("selftest.zig");
const trap = @import("trap.zig");

pub export fn main() noreturn {
    log.raw("ch27-ble-802154-boundary | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    log.raw("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");
    log.raw("scope: hci framing + att/gatt server + 802154 fcf + 6lowpan (12 checks)\n");
    log.raw("note: no radio, no scan, no connection, no thread join - controller blobs not linked\n");
    log.raw("host: 20 unit tests via 'zig build test'\n");

    const ok = selftest.run();
    if (!ok) {
        trap.panic("main: selftest failed - refusing to continue", .{});
    }

    log.raw("main: verdict=pass, hci/att/gatt/802154 byte paths verified (wfi)\n");
    hw.delayUs(10_000);
    log.raw("main: halting (wfi)\n");
    hw.halt();
}
