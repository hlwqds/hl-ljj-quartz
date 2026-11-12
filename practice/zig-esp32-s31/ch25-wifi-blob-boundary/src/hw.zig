//! ch25-wifi-blob-boundary：寄存器/CSR 的最小集合。
//!
//! 本章板侧不做真实时间测量、不配定时器、不开中断：日志里的“tick”全部是
//! 适配层里的逻辑计数器（每处理一个事件加一），不是墙钟。所以自检只需要
//! 三样东西——打印（走 ROM 的 UART）、一个微秒忙等（给串口一点喘息）、
//! 以及停机。
//!
//! 需要可复用的 TIMG0 时间基时看 ch15 的 `hw.zig`；需要门控寄存器清单时
//! 看 ch08/ch15。这里刻意保持最小，避免“协议栈章节”顺带把时钟树再讲一遍。
//!
//! RTC/LP WDT 的关闭在 `_start` 里完成（见 src/start.zig 第 3 步）：
//! 不关的话约 9 s 后复位成 `rst:0x10 CHIP_LP_WDT_RESET`，自检根本跑不完。

extern fn esp_rom_delay_us(us: u32) void;

pub inline fn readMcause() usize {
    return asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMepc() usize {
    return asm volatile ("csrr %[d], mepc"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMtval() usize {
    return asm volatile ("csrr %[d], mtval"
        : [d] "=r" (-> usize),
    );
}

/// ROM 的微秒级忙等（`ets_delay_us`，由链接脚本 PROVIDE 到 0x2f80003c）。
pub fn delayUs(us: u32) void {
    esp_rom_delay_us(us);
}

/// 停机：关全局中断后 `wfi`。正常收尾与 panic 都走这里。
pub fn halt() noreturn {
    asm volatile ("csrci mstatus, 0x8" ::: .{});
    while (true) {
        asm volatile ("wfi");
    }
}
