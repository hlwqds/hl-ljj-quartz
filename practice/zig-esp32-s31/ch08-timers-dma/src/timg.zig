//! ch08-timers-dma：TIMG（Timer Group）的通用定时器，轮询版。
//!
//! S31 有两个 TIMG 实例：TIMG0 @ 0x20580000、TIMG1 @ 0x20581000，每组里有
//! 两个通用定时器（T0/T1）加一只 MWDT（main-system watchdog）。ch05 讲过
//! MWDT 的语义；本章只用 **TIMG0 的 T0**，把它当一台“硬件秒表”：
//!
//!   - 计数时钟 = 选定的源 / 预分频（`T0_DIVIDER`，2..65536 合法）；
//!   - 源可选 XTAL 40 MHz、RC_FAST、PLL_F80M（由 HP_SYS_CLKRST 的
//!     `TIMERGRP0_CTRL0.T0_SRC_SEL` 选择，复位值 0 = XTAL）；
//!   - 有一个 54 位递增/递减计数器（LO 32 位 + HI 22 位）；
//!   - 有一个比较器（alarm）：计数值等于 `T0_ALARM_LO/HI` 时置中断原始位，
//!     并把 `T0_ALARM_EN` **自动清零**（所以“下一个闹钟”要重新装）。
//!
//! 本章把预分频设成 40，于是 40 MHz / 40 = 1 MHz，**1 tick = 1 µs**。
//! 这样寄存器里的数就是微秒数，读起来不用换算；代价是分辨率只有 1 µs。
//! 要更高分辨率就把分频改小（最小 2 → 20 MHz，50 ns/tick）。
//!
//! 寄存器来源（IDF v6.1）：
//!   components/soc/esp32s31/register/soc/timer_group_reg.h
//!   components/soc/esp32s31/register/soc/reg_base.h（DR_REG_TIMERG0_BASE）
//!   components/soc/esp32s31/register/soc/hp_sys_clkrst_reg.h（时钟源/门控）
//!   components/esp_hal_timg/esp32s31/include/hal/timer_ll.h（分频范围、
//!     源编码、update 等待语义）
//!
//! 本章**不**打开 TIMG 中断：闹钟只置 `INT_RAW`，由主循环轮询后 `INT_CLR`。
//! 接成中断需要 ch07 的 CLIC 路由，属于「待真机验证」范围。

const timg0_base: usize = 0x2058_0000;
const clkrst_base: usize = 0x2058_7000;

// 时钟/复位控制（HP_SYS_CLKRST_TIMERGRP0_CTRL0，偏移 0x114）
const clkrst_timergrp0_ctrl0: usize = clkrst_base + 0x114;

/// T0_SRC_SEL：XTAL=0、RC_FAST=1、PLL_F80M=2（timer_ll.h 的 switch）。
const src_sel_xtal: u32 = 0;
const t0_src_sel_shift: u5 = 3;
const t0_src_sel_mask: u32 = 0x3 << t0_src_sel_shift;
const t0_clk_en: u32 = 1 << 5;

// 定时器寄存器（TIMG_T0xxx_REG(i) = base + off）
const reg_t0config: usize = timg0_base + 0x00;
const reg_t0lo: usize = timg0_base + 0x04;
const reg_t0hi: usize = timg0_base + 0x08;
const reg_t0update: usize = timg0_base + 0x0c;
const reg_t0alarmlo: usize = timg0_base + 0x10;
const reg_t0alarmhi: usize = timg0_base + 0x14;
const reg_t0loadlo: usize = timg0_base + 0x18;
const reg_t0loadhi: usize = timg0_base + 0x1c;
const reg_t0load: usize = timg0_base + 0x20;
const reg_int_ena: usize = timg0_base + 0x70;
const reg_int_raw: usize = timg0_base + 0x74;
const reg_int_st: usize = timg0_base + 0x78;
const reg_int_clr: usize = timg0_base + 0x7c;
const reg_regclk: usize = timg0_base + 0xfc;

// T0CONFIG 位域
const t0_alarm_en: u32 = 1 << 10;
const t0_divcnt_rst: u32 = 1 << 12;
const t0_divider_shift: u5 = 13;
const t0_divider_mask: u32 = 0xFFFF << t0_divider_shift;
const t0_autoreload: u32 = 1 << 29;
const t0_increase: u32 = 1 << 30;
const t0_en: u32 = 1 << 31;

/// TIMG_REGCLK_REG 的 CLK_EN（bit31）：寄存器时钟常开。
const t0_regclk_en: u32 = 1 << 31;

/// T0 的中断位在 INT_*_TIMERS 里是 bit0（T1 是 bit1，MWDT 是 bit2）。
pub const t0_int_bit: u32 = 1 << 0;

/// 计数器的有效位宽：LO 32 + HI 22 = 54 位。
pub const counter_mask: u64 = (1 << 54) - 1;

/// 输入时钟：XTAL 40 MHz。分频后 tick 频率 = 40 MHz / divider。
pub const source_hz: u32 = 40_000_000;

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

/// 打开 TIMG0 T0 的时钟，并把源显式选成 XTAL。
///
/// 复位值本来就是 XTAL + 时钟开，但 bootloader/IDF 可能改过
/// `HP_SYS_CLKRST` 的源选择；显式写回让“1 tick 到底多少 ns”这件事
/// 不依赖别人留下的现场。
pub fn init() void {
    const addr = reg(clkrst_timergrp0_ctrl0);
    var v = addr.*;
    v &= ~t0_src_sel_mask;
    v |= src_sel_xtal << t0_src_sel_shift;
    v |= t0_clk_en;
    addr.* = v;

    // 让 TIMG 的寄存器时钟常开：调试时读计数器不会因为门控而“停一拍”。
    // TIMG_REGCLK_REG 的 CLK_EN 是 bit31（timer_group_reg.h）。
    reg(reg_regclk).* |= t0_regclk_en;
}

/// 计算分频值：`divider` 必须落在 2..=65536。
/// 写 0 表示 65536（硬件约定），本函数不接受 65536 以外的 0 值。
pub fn dividerFor(hz: u32) u32 {
    if (hz == 0) return 65536;
    const d = source_hz / hz;
    if (d < 2) return 2;
    if (d > 65536) return 65536;
    return d;
}

pub const Config = struct {
    /// 2..=65536；写 0 由硬件解释为 65536。
    divider: u32 = 40,
    /// true = 计到 alarm 后自动回到 0（周期）；false = 停在 alarm 值（一次性）。
    auto_reload: bool = false,
};

/// 配置并启动 T0，计数器从 0 开始。
///
/// 顺序：先停 → 写分频/方向/重装 → 复位分频计数器 → 清计数 → 使能。
/// 反过来的话，写分频的那一刻计数器可能正拿着一半旧时钟在跑，
/// 第一个周期会莫名偏长或偏短。
pub fn start(cfg: Config) void {
    stop();

    var d = cfg.divider;
    if (d == 65536) d = 0; // 硬件编码
    if (d != 0) {
        if (d < 2) d = 2;
    }

    var v: u32 = 0;
    v |= (d & 0xFFFF) << t0_divider_shift;
    v |= t0_increase; // 递增计数
    if (cfg.auto_reload) v |= t0_autoreload;
    v |= t0_divcnt_rst; // 复位预分频计数器
    v |= t0_en; // 启动

    reg(reg_t0config).* = v;

    // DIVCNT_RST 是自清零位：下一拍读回应为 0。只是确认写进去了，不等也不影响。
    setCounter(0);
}

/// 停止计数器并关掉闹钟使能（不清 INT_RAW）。
pub fn stop() void {
    const c = reg(reg_t0config);
    c.* = c.* & ~(t0_en | t0_alarm_en);
}

/// 写计数值：LOAD_HI/LOAD_LO 只是暂存，写 T0_LOAD（任意值）才真正装载。
pub fn setCounter(value: u64) void {
    const v = value & counter_mask;
    reg(reg_t0loadhi).* = @truncate(v >> 32);
    reg(reg_t0loadlo).* = @truncate(v);
    reg(reg_t0load).* = 1;
}

/// 读计数值。
///
/// T0 的寄存器在 APB 域、计数器在定时器时钟域：必须先写 `T0_UPDATE` 请求
/// 一次快照，等它自清零后再读 HI/LO，否则可能读到“高 32 位是新的、低 32 位
/// 是旧的”这种撕裂值。这正是 IDF `timer_ll_trigger_soft_capture` 的做法。
pub fn counter() u64 {
    reg(reg_t0update).* = t0_en; // bit31 = UPDATE
    while ((reg(reg_t0update).* & t0_en) != 0) {}

    const hi = reg(reg_t0hi).* & 0x003F_FFFF;
    const lo = reg(reg_t0lo).*;
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// 装闹钟（只写目标值，不使能）。
pub fn setAlarm(value: u64) void {
    const v = value & counter_mask;
    reg(reg_t0alarmhi).* = @truncate(v >> 32);
    reg(reg_t0alarmlo).* = @truncate(v);
}

/// 使能闹钟。硬件在命中的那一刻自动清掉这一位。
pub fn enableAlarm() void {
    reg(reg_t0config).* |= t0_alarm_en;
}

/// 闹钟是否命中（INT_RAW 的 T0 位）。轮询版用它判断“到点了”。
pub fn alarmPending() bool {
    return (reg(reg_int_raw).* & t0_int_bit) != 0;
}

/// 清掉 T0 的中断原始位。写 1 清除（W1C 语义在 INT_CLR 上）。
pub fn clearAlarm() void {
    reg(reg_int_clr).* = t0_int_bit;
}

/// 屏蔽/打开 T0 的中断使能位。本章保持关闭；留接口给 ch07 之后的章节。
pub fn setInterruptEnabled(enabled: bool) void {
    if (enabled) {
        reg(reg_int_ena).* |= t0_int_bit;
    } else {
        reg(reg_int_ena).* &= ~t0_int_bit;
    }
}

/// 忙等到计数器达到 `target`（绝对值）。
///
/// 只适用于“窗口远小于 2^54 tick”的场景；本章的窗口是 1 ms。
/// 用 `counter() < target` 而不是差值，是为了让调用者可以把 target 写成
/// “上一拍 + 周期”，从而测出**绝对时刻**的漂移，而不是每拍重新起算。
pub fn waitUntil(target: u64) void {
    while (counter() < target) {}
}
