//! ch14-dual-core-smp-ipi：每核一个 1 ms tick（TIMG0 T0 / T1）。
//!
//! 为什么每核一个通道，而不是共用一个：
//!
//!   - 一个时钟通道只能有一个绝对闹钟和一个中断源，两个核共用会互相
//!     改写对方的闹钟；
//!   - 中断矩阵与 CLIC 都是每核的，所以“同一个源投递到两个核”需要两条
//!     路由（也完全可以做到，但本章的重点是每核独立，不引入共享状态）；
//!   - 各自的 tick 只影响各自的调度决策，这正是 SMP 调度的最小正确形态。
//!
//! 一条 tick 穿过的门（顺序也是 init 的顺序）：
//!
//!   TIMG0 Tn 计数到闹钟
//!     ↓ INT_ENA_TIMERS.bit n（矩阵的输入是 INT_ST = INT_RAW & INT_ENA）
//!   源 25（T0 = ETS_TIMERGRP0_T0_INTR_SOURCE）/ 26（T1 = ..._T1_...）
//!   目标核的中断矩阵 INTERRUPT_COREn[源]：MAP[5:0] = 16
//!     ↓
//!   该核 CLIC 输入 16：优先级 3、IE = 1
//!     ↓ 优先级 3 > mintthresh（0x1F 只挡 0 级）
//!   mstatus.MIE = 1（由 taskStart 打开）
//!
//! 寄存器来源（ESP-IDF v6.1，esp32s31）：
//!   - reg_base.h:77/137/138：INTERRUPT_CORE0 = 0x20585000、_CORE1 = +0x800；
//!     TIMG0 = 0x20580000；HP_SYS_CLKRST = 0x20587000。
//!   - timer_group_reg.h：T0 基（0x00..0x20）、T1 基（0x24..0x44）、
//!     INT_ENA_TIMERS 0x70（bit0/bit1）、INT_CLR_TIMERS 0x7c（W1C）。
//!   - hp_sys_clkrst_reg.h：TIMERGRP0_CTRL0 = +0x114，
//!     T0_SRC_SEL[4:3] / T0_CLK_EN[5]、T1_SRC_SEL[7:6] / T1_CLK_EN[8]。
//!   - hp_sys_clkrst_reg.h：SYSTIMER_CTRL0 = +0x120（见 systimer.zig）。
//!
//! 「待真机验证」：40 分频 + 1000 计数 = 1 ms 是算术结论（XTAL 40 MHz），
//! 实际周期与 ISR 延迟必须上板用 SYSTIMER 对照确认。本工程不提供 run.log。

const hw = @import("hw.zig");
const clic = @import("clic.zig");

pub const period_us: u32 = 1000;

/// XTAL 40 MHz / 40 = 1 MHz，1 计数 = 1 µs。
const divider: u32 = 40;

const timg0: usize = 0x2058_0000;
const clkrst_timergrp0: usize = 0x2058_7000 + 0x114;

const int_ena_timers: usize = timg0 + 0x70;
const int_clr_timers: usize = timg0 + 0x7c;

/// 每个通道的寄存器基（T0 = 0x00，T1 = 0x24；T1 的布局与 T0 逐字段相同，
/// 只是整体后移 0x24）。
const ch_base: [2]usize = .{ timg0 + 0x00, timg0 + 0x24 };

const off_config: usize = 0x00;
const off_lo: usize = 0x04;
const off_hi: usize = 0x08;
const off_update: usize = 0x0c;
const off_alarmlo: usize = 0x10;
const off_alarmhi: usize = 0x14;
const off_loadlo: usize = 0x18;
const off_loadhi: usize = 0x1c;
const off_load: usize = 0x20;

const bit_en: u32 = 1 << 31;
const bit_increase: u32 = 1 << 30;
const bit_alarm_en: u32 = 1 << 10;
const bit_update: u32 = 1 << 31;

/// 源编号：T0 = 25，T1 = 26。
pub fn source(core: u32) usize {
    return 25 + core;
}

fn periodTicks() u64 {
    return period_us;
}

/// 每核的绝对时间轴。ISR 里 `+= period`，不读计数器 —— 迟到量不会积分成漂移。
var next_target: [2]u64 = .{ 0, 0 };

/// 时钟门是**共享**寄存器：两个通道的 SRC_SEL/CLK_EN 以及 INT_ENA 的两位
/// 只能由一个核在 core1 启动之前写一次。两个核各写一次会因为读改写竞争
/// 丢掉对方的位（典型 SMP 初始化错误）。
pub fn initSharedGates() void {
    // 1) 时钟：T0/T1 都选 XTAL，都开门。清 SRC_SEL 字段再置 CLK_EN 位。
    const cr = hw.reg(clkrst_timergrp0);
    var v = cr.*;
    v &= ~@as(u32, 0x38); // T0_SRC_SEL[4:3] = 0（XTAL）
    v &= ~@as(u32, 0xC0); // T1_SRC_SEL[7:6] = 0（XTAL）
    v |= 1 << 5; // T0_CLK_EN
    v |= 1 << 8; // T1_CLK_EN
    cr.* = v;
    hw.fenceRwRw();

    // 2) 两个通道的中断使能一次置好（同一只寄存器，读改写只做一次）。
    //    先清残留原始位，避免 bootloader 时代的旧状态立刻挂到 CLIC 上。
    hw.reg(int_clr_timers).* = 0b11;
    hw.reg(int_ena_timers).* = hw.reg(int_ena_timers).* | 0b11;
}

fn regCh(core: u32, off: usize) *volatile u32 {
    return hw.reg(ch_base[core] + off);
}

/// 读本通道计数器：请求 UPDATE 快照，等它落定，再按 HI→LO 读。
fn readCounter(core: u32) u64 {
    const upd = regCh(core, off_update);
    upd.* = bit_update;
    var guard: u32 = 0;
    while ((upd.* & bit_update) != 0 and guard < 10_000) : (guard += 1) {}
    const hi = regCh(core, off_hi).* & 0x003F_FFFF;
    const lo = regCh(core, off_lo).*;
    return (@as(u64, hi) << 32) | lo;
}

fn writeAlarm(core: u32, target: u64) void {
    regCh(core, off_alarmlo).* = @truncate(target);
    regCh(core, off_alarmhi).* = @truncate(target >> 32);
    const cfg = regCh(core, off_config);
    cfg.* = cfg.* | bit_alarm_en;
}

fn rearm(core: u32) void {
    next_target[core] += periodTicks();
    writeAlarm(core, next_target[core]);
}

/// 配本核的通道（core0 → T0，core1 → T1）与本核的矩阵/CLIC 输入 16。
/// 不打开 MIE。共享门必须先由 `initSharedGates()` 配好。
pub fn init(core: u32) void {
    hw.fenceRwRw();

    // 1) 计数器：递增、分频 40、先不开闹钟。AUTORELOAD(bit29) 复位默认 1，
    //    这里显式写 0：命中闹钟时从 LOAD 回卷会毁掉绝对时间轴。
    regCh(core, off_config).* = bit_en | bit_increase | (divider << 13);

    // 2) 从 0 装载（LOADLO/HI 只是暂存，写 LOAD 才真正装入）。
    regCh(core, off_loadlo).* = 0;
    regCh(core, off_loadhi).* = 0;
    regCh(core, off_load).* = 1;

    // 3) 第一个闹钟 = 当前计数 + period。
    next_target[core] = readCounter(core) + periodTicks();
    writeAlarm(core, next_target[core]);

    // 4) 路由：矩阵[源] = 16。矩阵是每核的，所以必须由本核自己写。
    clic.route(core, source(core), clic.tick_input);

    // 5) 本核 CLIC 输入 16：优先级、使能、清 pending。
    clic.setupTickInput();
    clic.setThreshold(0);
}

/// ISR 的硬件部分。返回 true 表示“这是本核的 tick，已清源并重装”。
///
/// 清源顺序：TIMG 的 W1C（只写本通道那一位，不读改写 ——
/// 两个核共用 INT_CLR_TIMERS，读改写会擦掉对方刚清的位），
/// 再清 CLIC IP，最后重装闹钟。
pub fn acknowledge(core: u32, id: u6) bool {
    if (id != clic.tick_input) return false;

    hw.reg(int_clr_timers).* = @as(u32, 1) << @intCast(core);
    clic.clearPending(clic.tick_input);
    rearm(core);
    return true;
}

/// 停 tick（本核）：清 EN/ALARM_EN、关本通道 INT_ENA 与输入 16 的 IE。
pub fn disable(core: u32) void {
    const cfg = regCh(core, off_config);
    cfg.* = cfg.* & ~(bit_en | bit_alarm_en);
    // W1C 寄存器不能按位清零：INT_ENA 是普通 R/W，读改写只影响自己那一位
    // 之外的值保持不变，但两个核同时写仍可能丢位 —— 停机路径只有本核在写。
    hw.reg(int_ena_timers).* = hw.reg(int_ena_timers).* & ~(@as(u32, 1) << @intCast(core));
    clic.disableInput(clic.tick_input);
    clic.clearPending(clic.tick_input);
}
