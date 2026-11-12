//! ch15-observability-testing-stability：寄存器、CSR、TIMG0 时间基与停机。
//!
//! 本章只要一个**单调微秒时钟**：TIMG0 的 T0 计数器，源选 XTAL 40 MHz，
//! 分频 40 得到 1 MHz（1 tick = 1 µs）。它比 tick 中断更适合做 trace 时间戳：
//!
//!   - 读寄存器是同步操作，不需要中断参与，`MIE` 全程为 0；
//!   - 64 位计数器（HI 22 位 + LO 32 位）在 1 MHz 下约 4.4 千年回绕一次；
//!   - 没有“ISR 延迟”污染：时间戳就是读数的差，而不是“第几次 tick”。
//!
//! 寄存器来源（ESP-IDF v6.1，esp32s31）：
//!   - `components/soc/esp32s31/register/soc/reg_base.h:71`  DR_REG_TIMERG0_BASE = 0x20580000
//!   - `components/soc/esp32s31/register/soc/reg_base.h:79`  DR_REG_HP_SYS_CLKRST_BASE = 0x20587000
//!   - `components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h:2800`
//!       HP_SYS_CLKRST_TIMERGRP0_CTRL0_REG = base + 0x114
//!       同名文件 :2801 APB_CLK_EN bit0、:2822 T0_SRC_SEL[4:3]、:2829 T0_CLK_EN bit5
//!   - `components/soc/esp32s31/register/soc/timer_group_reg.h:21`
//!       TIMG_T0CONFIG_REG(i) = REG_TIMG_BASE(i) + 0x0
//!       同名文件 :41 DIVIDER[28:13]、:58 INCREASE bit30、:69 EN bit31、
//!       :108 T0UPDATE bit31、:80/:94 T0LO/T0HI
//!
//! 「真机记录」：TIMG0 分频 40 已由 2026-11-13 的首轮实测确认——
//! 1000 µs 的 ROM 忙等对应 `measured=1003us`（ratio=100%），1 MHz 成立。
//! 仍未复核的是 `UPDATE` 快照的自清零语义（见 15.3 的 `clock` 自检项）。

const std = @import("std");

extern fn esp_rom_delay_us(us: u32) void;

// ---------------------------------------------------------------------------
// 通用寄存器访问
// ---------------------------------------------------------------------------

pub inline fn readReg(addr: usize) u32 {
    const p: *const volatile u32 = @ptrFromInt(addr);
    return p.*;
}

pub inline fn writeReg(addr: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = value;
}

pub inline fn readMtvec() usize {
    return asm volatile ("csrr %[d], mtvec"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMstatus() usize {
    return asm volatile ("csrr %[d], mstatus"
        : [d] "=r" (-> usize),
    );
}

pub inline fn readMie() usize {
    return asm volatile ("csrr %[d], mie"
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

/// ROM 的微秒级忙等。本章用它产生“已知的墙钟间隔”，用来给时间基做自检。
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

const cfg_divider_shift: u5 = 13;
const cfg_divider_40: u32 = 40 << cfg_divider_shift;
const cfg_increase: u32 = 1 << 30;
const cfg_en: u32 = 1 << 31;
const cfg_update: u32 = 1 << 31;

/// XTAL 40 MHz / 40 = 1 MHz → 1 tick = 1 µs。
pub const tick_hz: u32 = 1_000_000;

/// 配置并启动 T0。幂等：重复调用只是把同样的值再写一遍。
pub fn initTimer() void {
    // 1) 打开 TIMG0 的 APB 时钟与 T0 时钟，源选 XTAL（SEL = 0）。
    var ctrl = readReg(timergrp0_ctrl0);
    ctrl |= ctrl_apb_clk_en | ctrl_t0_clk_en;
    ctrl &= ~ctrl_t0_src_sel_mask;
    writeReg(timergrp0_ctrl0, ctrl);

    // 2) 分频 40、递增、使能。AUTORELOAD 保持默认（本用法不设闹钟）。
    writeReg(t0config, cfg_divider_40 | cfg_increase | cfg_en);
}

/// 读 64 位计数。先请求 UPDATE 快照，等它自清零，再按 HI→LO 读。
/// 等待有上限（10 000 次），避免寄存器行为异常时死锁在自检路径上。
pub fn nowUs() u64 {
    writeReg(t0update, cfg_update);
    var guard: u32 = 0;
    while ((readReg(t0update) & cfg_update) != 0 and guard < 10_000) : (guard += 1) {}

    const hi: u64 = readReg(t0hi) & 0x003F_FFFF;
    const lo: u64 = readReg(t0lo);
    return (hi << 32) | lo;
}

// ---------------------------------------------------------------------------
// RTC/LP watchdog：真机关过，但要能证明
// ---------------------------------------------------------------------------
//
// 真机首轮（2026-11-13）读回 `CONFIG0 = 0x8007ee00`：pause_in_slp=1、
// appcpu/procpu_reset_en=1、sys/cpu_reset_length=7、STG0..3=0、flashboot=0，
// 只有 EN(bit31) 仍是 1。BRINGUP 的 ch05 记录同样是 `rwdt en=1 stg=0`：
// 这颗芯片上 EN 位对软件写入表现为 WARL/自恢复，**真正决定会不会复位的是
// 四个 stage 选择位**（[30:28]/[27:25]/[24:22]/[21:19]，全 0 = OFF）。
//
// 所以这里的判据是“没有已武装的 stage + flashboot 关闭”，而不是 EN=0。
// 下面的 disable 仍然按 IDF `wdt_hal_deinit(WDT_RWDT)` 的顺序做一遍：
// 解锁 → feed → 清 EN/STG0..3/flashboot → 回读 → 重新上锁，并最多重试 3 次。
// 回读值会由 `main` 打印出来，作为“关狗确实执行过”的证据。
//
// 寄存器（IDF v6.1，`rtc_wdt_reg.h` / `rtc_wdt_struct.h`）：
//   CONFIG0 +0x00（EN bit31、STG0 [30:28]…STG3 [21:19]、FLASHBOOT bit12）
//   FEED    +0x14（bit31）
//   WPROTECT +0x18、SWD_WPROTECT +0x20，键 0x50D83AA1

const rtc_wdt_config0: usize = 0x2080_1000;
const rtc_wdt_feed: usize = 0x2080_1014;
const rtc_wdt_wprotect: usize = 0x2080_1018;
const rtc_wdt_swd_wprotect: usize = 0x2080_1020;
const rtc_wdt_wkey: u32 = 0x50D83AA1;

pub const rtc_wdt_en: u32 = 1 << 31;
/// STG0 [30:28] + STG1 [27:25] + STG2 [24:22] + STG3 [21:19]。
pub const rtc_wdt_stage_mask: u32 = 0x7FF8_0000;
pub const rtc_wdt_flashboot: u32 = 1 << 12;

pub const WdtAttempt = struct {
    before: u32,
    after: u32,
    tries: u32,
};

/// 关闭 RTC/LP WDT 的四个 stage 与 flashboot 模式，返回前后读回值。
pub fn disableRtcWdt() WdtAttempt {
    const before = readReg(rtc_wdt_config0);
    const clear = rtc_wdt_en | rtc_wdt_stage_mask | rtc_wdt_flashboot;
    var tries: u32 = 0;
    var after = before;

    while (tries < 3) : (tries += 1) {
        writeReg(rtc_wdt_wprotect, rtc_wdt_wkey);
        writeReg(rtc_wdt_swd_wprotect, rtc_wdt_wkey);
        // MMIO 写是 posted 的：先让解锁可见，再写 CONFIG0。
        asm volatile ("fence rw, rw" ::: .{});
        writeReg(rtc_wdt_feed, 0x8000_0000);
        writeReg(rtc_wdt_config0, readReg(rtc_wdt_config0) & ~clear);
        asm volatile ("fence rw, rw" ::: .{});
        after = readReg(rtc_wdt_config0);
        writeReg(rtc_wdt_wprotect, 0);
        writeReg(rtc_wdt_swd_wprotect, 0);
        // 功能判据：没有武装的 stage、flashboot 关闭。EN 可能仍是 1（WARL）。
        if ((after & (rtc_wdt_stage_mask | rtc_wdt_flashboot)) == 0) break;
    }

    return .{ .before = before, .after = after, .tries = tries + 1 };
}

/// 停机：关中断（已经是 0）后 `wfi`。panic 与正常收尾都走这里。
pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
