//! ch17-ethernet-mac-phy-driver：MMIO 原语、CSR 读取、时间基、停机。
//!
//! 本章只保留四个基础件：
//!
//!   1. `readReg` / `writeReg` —— volatile 读写，编译器不会把两次读合并；
//!   2. `fence()` —— `fence rw, rw`，DMA 描述符交权前后必须用（17.7）；
//!   3. TIMG0 T0 的 1 MHz 时间基 —— MDIO 轮询超时与描述符超时都要它；
//!   4. RTC/LP WDT 的 disarm —— bootloader 交接时它还在数秒，不关约 9 s 复位。
//!
//! 时钟与看门狗的寄存器来源与 ch05/ch15 相同（真机已复核过一遍）：
//!   - `components/soc/esp32s31/register/soc/reg_base.h`
//!       DR_REG_TIMERG0_BASE = 0x20580000、DR_REG_HP_SYS_CLKRST_BASE = 0x20587000
//!   - `hp_sys_clkrst_reg.h` TIMERGRP0_CTRL0 = +0x114：APB_CLK_EN bit0、
//!       T0_SRC_SEL[4:3]、T0_CLK_EN bit5
//!   - `timer_group_reg.h` TIMG_T0CONFIG = +0x0：DIVIDER[28:13]、
//!       INCREASE bit30、EN bit31；T0LO/T0HI = +0x4/+0x8；T0UPDATE = +0xc
//!   - `rtc_wdt_reg.h` CONFIG0 = 0x20801000、FEED = +0x14、
//!       WPROTECT = +0x18、SWD_WPROTECT = +0x20，键 0x50D83AA1
//!
//! TIMG0 分频 40 = 1 MHz 已经在本板实测（ch15 的 `check: clock
//! measured=1003us ratio=100%`），本章直接复用这条结论。

const std = @import("std");

extern fn esp_rom_delay_us(us: u32) void;

// ---------------------------------------------------------------------------
// 通用 MMIO
// ---------------------------------------------------------------------------

pub inline fn readReg(addr: usize) u32 {
    const p: *const volatile u32 = @ptrFromInt(addr);
    return p.*;
}

pub inline fn writeReg(addr: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = value;
}

pub inline fn setBits(addr: usize, mask: u32) void {
    writeReg(addr, readReg(addr) | mask);
}

pub inline fn clearBits(addr: usize, mask: u32) void {
    writeReg(addr, readReg(addr) & ~mask);
}

pub inline fn writeMasked(addr: usize, mask: u32, value: u32) void {
    writeReg(addr, (readReg(addr) & ~mask) | (value & mask));
}

/// `fence rw, rw`：让此前所有读写（含 MMIO posted 写）在此之前对总线可见。
///
/// Zig 0.17 已经删掉 `@fence`，只能用内联汇编（见
/// ../BRINGUP-2026-11-12.md 的 API 变更清单）。
pub inline fn fence() void {
    asm volatile ("fence rw, rw" ::: .{});
}

/// 描述符交权前还要一条 `fence.i` 吗？不需要：`fence.i` 管的是取指，
/// 而描述符/缓冲是数据。取指相关的问题只出现在 `linksection(".trap_ram")`
/// 那条路径上（ch15 讨论过）。这里保留一个空函数名以示区别，避免误用。
pub inline fn fenceInstruction() void {
    asm volatile ("fence.i" ::: .{});
}

pub inline fn readMstatus() usize {
    return asm volatile ("csrr %[d], mstatus"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMtvec() usize {
    return asm volatile ("csrr %[d], mtvec"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMcause() usize {
    return asm volatile ("csrr %[d], mcause"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMtval() usize {
    return asm volatile ("csrr %[d], mtval"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMepc() usize {
    return asm volatile ("csrr %[d], mepc"
        : [d] "=r" (-> usize),
    );
}

pub fn delayUs(us: u32) void {
    esp_rom_delay_us(us);
}

// ---------------------------------------------------------------------------
// TIMG0 T0：1 MHz 单调计数
// ---------------------------------------------------------------------------

const timg0: usize = 0x2058_0000;
const clkrst: usize = 0x2058_7000;
const timergrp0_ctrl0: usize = clkrst + 0x114;

const t0config: usize = timg0 + 0x00;
const t0lo: usize = timg0 + 0x04;
const t0hi: usize = timg0 + 0x08;
const t0update: usize = timg0 + 0x0c;

const ctrl_apb_clk_en: u32 = 1 << 0;
const ctrl_t0_src_sel_mask: u32 = 0b11 << 3;
const ctrl_t0_clk_en: u32 = 1 << 5;

const cfg_divider_40: u32 = 40 << 13;
const cfg_increase: u32 = 1 << 30;
const cfg_en: u32 = 1 << 31;
const cfg_update: u32 = 1 << 31;

pub const tick_hz: u32 = 1_000_000;

pub fn initTimer() void {
    var ctrl = readReg(timergrp0_ctrl0);
    ctrl |= ctrl_apb_clk_en | ctrl_t0_clk_en;
    ctrl &= ~ctrl_t0_src_sel_mask;
    writeReg(timergrp0_ctrl0, ctrl);
    writeReg(t0config, cfg_divider_40 | cfg_increase | cfg_en);
}

pub fn nowUs() u64 {
    writeReg(t0update, cfg_update);
    var guard: u32 = 0;
    while ((readReg(t0update) & cfg_update) != 0 and guard < 10_000) : (guard += 1) {}

    const hi: u64 = readReg(t0hi) & 0x003F_FFFF;
    const lo: u64 = readReg(t0lo);
    return (hi << 32) | lo;
}

/// 自 `since` 起过了多少微秒。64 位计数器在 1 MHz 下不回绕。
pub fn elapsedUs(since: u64) u64 {
    return nowUs() - since;
}

// ---------------------------------------------------------------------------
// RTC/LP watchdog
// ---------------------------------------------------------------------------

const rtc_wdt_config0: usize = 0x2080_1000;
const rtc_wdt_feed: usize = 0x2080_1014;
const rtc_wdt_wprotect: usize = 0x2080_1018;
const rtc_wdt_swd_wprotect: usize = 0x2080_1020;
const rtc_wdt_wkey: u32 = 0x50D83AA1;

const rtc_wdt_en: u32 = 1 << 31;
const rtc_wdt_stage_mask: u32 = 0x7FF8_0000;
const rtc_wdt_flashboot: u32 = 1 << 12;

pub const WdtAttempt = struct {
    before: u32,
    after: u32,
    tries: u32,
};

/// 关掉 RTC WDT 的四个 stage 与 flashboot 模式，并回读。
///
/// 判据是“没有武装的 stage”（EN 位在 S31 上对软件写表现为 WARL，
/// ch15 首轮实测 CONFIG0 的 EN 仍为 1 但 STG0..3 全 0 —— 功能上已经关掉）。
pub fn disableRtcWdt() WdtAttempt {
    const before = readReg(rtc_wdt_config0);
    const clear = rtc_wdt_en | rtc_wdt_stage_mask | rtc_wdt_flashboot;
    var tries: u32 = 0;
    var after = before;

    while (tries < 3) : (tries += 1) {
        writeReg(rtc_wdt_wprotect, rtc_wdt_wkey);
        writeReg(rtc_wdt_swd_wprotect, rtc_wdt_wkey);
        fence();
        writeReg(rtc_wdt_feed, 0x8000_0000);
        writeReg(rtc_wdt_config0, readReg(rtc_wdt_config0) & ~clear);
        fence();
        after = readReg(rtc_wdt_config0);
        writeReg(rtc_wdt_wprotect, 0);
        writeReg(rtc_wdt_swd_wprotect, 0);
        if ((after & (rtc_wdt_stage_mask | rtc_wdt_flashboot)) == 0) break;
    }

    return .{ .before = before, .after = after, .tries = tries + 1 };
}

pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

// ---------------------------------------------------------------------------
// 小工具（主机侧也可用）
// ---------------------------------------------------------------------------

/// 字节数组 → u32（小端）。打印 MAC 地址、拼描述符时用。
pub fn leU32(bytes: []const u8) u32 {
    var v: u32 = 0;
    var i: usize = 0;
    while (i < 4 and i < bytes.len) : (i += 1) {
        v |= @as(u32, bytes[i]) << @intCast(8 * i);
    }
    return v;
}

test "leU32 packs little endian" {
    const b = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    try std.testing.expectEqual(@as(u32, 0x4433_2211), leU32(&b));
    try std.testing.expectEqual(@as(u32, 0x2211), leU32(b[0..2]));
}
