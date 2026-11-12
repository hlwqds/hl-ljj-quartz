//! ch11-preemptive-scheduler：TIMG0 T0 的 1 ms tick + CLIC 输入 16。
//!
//! 一条 tick 要穿过六道门（顺序也是 init 的顺序）：
//!
//!   TIMG0 T0 计数到闹钟
//!     ↓ INT_ENA_TIMERS.bit0：矩阵的输入是 INT_ST = INT_RAW & INT_ENA
//!   源 25 = ETS_TIMERGRP0_T0_INTR_SOURCE
//!   中断矩阵 INTERRUPT_CORE0[25]：MAP[5:0] = 通道 + 16 = 16
//!     ↓
//!   CLIC 输入 16：优先级 3、IE = 1
//!     ↓ 优先级 3 > 阈值 0
//!   mstatus.MIE = 1（由 sched.start 打开）
//!
//! 寄存器来源（ESP-IDF v6.1，esp32s31）：
//!   - `reg_base.h`：TIMG0 = 0x20580000、INTERRUPT_CORE0 = 0x20585000、
//!     HP_SYS_CLKRST = 0x20587000、CLIC = 0x10800000。
//!   - `timer_group_reg.h`：T0CONFIG 0x00、T0LO 0x04、T0HI 0x08、
//!     T0UPDATE 0x0c、T0ALARMLO 0x10、T0ALARMHI 0x14、
//!     T0LOADLO 0x18、T0LOADHI 0x1c、T0LOAD 0x20、INT_ENA_TIMERS 0x70、
//!     INT_CLR_TIMERS 0x7c。
//!   - `hp_sys_clkrst_reg.h`：TIMERGRP0_CTRL0 = +0x114，
//!     T0_SRC_SEL[4:3]（0 = XTAL 40 MHz）、T0_CLK_EN[5]。
//!   - `interrupt_core0_reg.h`：每源一个 32 位寄存器，偏移 = 4 × 源编号，
//!     MAP[5:0] 写的是 CLIC 输入号（16..47）。
//!   - `clic_reg.h`：CTRL(i) = 0x10801000 + 4i，CTL[31:24] 优先级、
//!     IE bit8、IP bit0；THRESH 在 0x10800008 的 [31:24]。
//!
//! 「待真机验证」：本仓没有在 S31 上跑过这些写操作。分频 40 = 1 MHz、
//! 闹钟 1000 = 1 ms 是算术结论；实际周期、ISR 延迟与 CLIC 的 IP 清除行为
//! 必须上板用第二时基（SYSTIMER）与示波器确认。

const std = @import("std");

/// 本章的 tick 周期：1 ms。分频 40 时 1 tick = 1 µs。
pub const period_us: u32 = 1000;

/// ETS_TIMERGRP0_T0_INTR_SOURCE。
pub const source: u8 = 25;

/// 矩阵通道 0 + CLIC_EXT_INTR_NUM_OFFSET(16)。
pub const input: u6 = 16;

/// tick 在 CLIC 里的优先级（0..7，越大越优先）。
pub const prio: u3 = 3;

/// 软件中断让出用的 CLIC 输入（ch07 的输入 19）。
pub const soft_input: u6 = 19;

/// XTAL 40 MHz / 40 = 1 MHz。
const divider: u32 = 40;

const timg0: usize = 0x2058_0000;
const clkrst: usize = 0x2058_7000;
const clkrst_timergrp0: usize = clkrst + 0x114;
const matrix0: usize = 0x2058_5000;

const t0config: usize = timg0 + 0x00;
const t0lo: usize = timg0 + 0x04;
const t0hi: usize = timg0 + 0x08;
const t0update: usize = timg0 + 0x0c;
const t0alarmlo: usize = timg0 + 0x10;
const t0alarmhi: usize = timg0 + 0x14;
const t0loadlo: usize = timg0 + 0x18;
const t0loadhi: usize = timg0 + 0x1c;
const t0load: usize = timg0 + 0x20;
const int_ena_timers: usize = timg0 + 0x70;
const int_clr_timers: usize = timg0 + 0x7c;

const clic_ctrl_base: usize = 0x1080_1000;
const clic_thresh: usize = 0x1080_0008;

const bit_t0_en: u32 = 1 << 31;
const bit_t0_increase: u32 = 1 << 30;
const bit_t0_alarm_en: u32 = 1 << 10;
const bit_update: u32 = 1 << 31;

/// 当前周期（µs == T0 ticks，因为 1 MHz）。
var period_ticks: u64 = period_us;

/// 绝对时间轴上的下一个闹钟目标。ISR 里 `+= period_ticks`，不读 now。
var next_target: u64 = 0;

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

inline fn ctrl(id: u6) *volatile u32 {
    return @ptrFromInt(clic_ctrl_base + @as(usize, id) * 4);
}

/// 读计数器：先请求 UPDATE 快照，等它自清零，再按 HI→LO 顺序读。
fn readCounter() u64 {
    const upd = reg(t0update);
    upd.* = bit_update;
    var guard: u32 = 0;
    while ((upd.* & bit_update) != 0 and guard < 10_000) : (guard += 1) {}
    const hi = reg(t0hi).* & 0x003F_FFFF;
    const lo = reg(t0lo).*;
    return (@as(u64, hi) << 32) | lo;
}

fn writeAlarm(target: u64) void {
    reg(t0alarmlo).* = @truncate(target);
    reg(t0alarmhi).* = @truncate(target >> 32);
    const cfg = reg(t0config);
    cfg.* = cfg.* | bit_t0_alarm_en;
}

fn rearm() void {
    // 绝对重装：迟到量不会积分成漂移。若已落后超过一个周期，
    // 硬件会连续命中补 tick；这是需要记录的证据，不靠调大周期掩盖。
    next_target += period_ticks;
    writeAlarm(next_target);
}

fn setPriority(id: u6, level: u3) void {
    const p = ctrl(id);
    const v = p.*;
    const byte: u32 = (v >> 24) & 0xFF;
    const low_mask: u32 = 0x1F;
    const new_byte = (byte & low_mask) | (@as(u32, level) << 5);
    p.* = (v & 0x00FF_FFFF) | (new_byte << 24);
}

fn enableInput(id: u6) void {
    const p = ctrl(id);
    p.* = p.* | (1 << 8);
}

fn disableInput(id: u6) void {
    const p = ctrl(id);
    p.* = p.* & ~@as(u32, 1 << 8);
}

fn clearPending(id: u6) void {
    const p = ctrl(id);
    p.* = p.* & ~@as(u32, 1);
}

fn setThreshold(level: u3) void {
    // 阈值语义：优先级 ≤ 阈值被屏蔽。0 → 字节 0x1f，什么都不挡。
    const byte: u32 = (@as(u32, level) << 5) | 0x1F;
    const p = reg(clic_thresh);
    const v = p.*;
    p.* = (v & 0x00FF_FFFF) | (byte << 24);
    _ = p.*; // 写后读一次，让新阈值生效（ch07 的结论）
}

/// 配时钟源、分频、闹钟与路由；不打开 MIE。
pub fn init(period: u32) void {
    std.debug.assert(period > 0);

    period_ticks = period;

    // 1) 时钟：T0 源 = XTAL 40 MHz，开 T0 时钟门（保留其它位）。
    const cr = reg(clkrst_timergrp0);
    var crv = cr.*;
    crv &= ~@as(u32, 0x38); // T0_SRC_SEL[4:3] = 0
    crv |= 1 << 5; // T0_CLK_EN
    cr.* = crv;

    // 2) 计数器：递增、分频 40、先不开闹钟。T0CONFIG 的 AUTORELOAD(bit29)
    //    复位默认是 1，这里显式写 0：命中闹钟时从 LOAD(0) 自动回卷会毁掉
    //    绝对时间轴（next_target 是在累加的），重装由 ISR 的 rearm 完成。
    reg(t0config).* = bit_t0_en | bit_t0_increase | (divider << 13);

    // 3) 从 0 装载：LOADLO/HI 只是暂存，写 LOAD 才真正装入。
    reg(t0loadlo).* = 0;
    reg(t0loadhi).* = 0;
    reg(t0load).* = 1;

    // 4) 第一个闹钟：绝对目标 = 当前计数 + period。
    next_target = readCounter() + period_ticks;
    writeAlarm(next_target);

    // 5) 路由：先开 TIMG 的 T0 中断使能——矩阵的输入是 INT_ST
    //    （= INT_RAW & INT_ENA），不置 1 源 25 永远不翻转
    //    （timer_group_reg.h:649 的 TIMG_T0_INT_ENA = bit0，
    //    ch08 正文「INT_ENA 是另一层开关」同结论）。使能前先清一次
    //    残留的原始位，避免 bootloader 时代的旧状态立刻挂到 CLIC 上。
    reg(int_clr_timers).* = 1;
    reg(int_ena_timers).* = reg(int_ena_timers).* | 1;

    // 矩阵[25] = 16（CLIC 输入号，不是通道 0）。
    const map = reg(matrix0 + @as(usize, source) * 4);
    map.* = (map.* & 0x300) | @as(u32, input);

    // 6) CLIC 输入 16：优先级 3、使能；阈值 0。
    setPriority(input, prio);
    enableInput(input);
    clearPending(input);
    setThreshold(0);
}

/// 打开全局中断。必须在 init 之后调用。
pub fn enable() void {
    clearPending(input);
    // _start 里 `csrw mie, zero` 把整张 mie 表清空了；CLIC 的输入 16..47 属
    // “外部中断”类，必须把 mie.MEIE（bit11）重新打开，否则 CLICINTIE 置 1
    // 也不会投递（真机现象：tick 配置打印后一片安静，ticks 不涨）。
    asm volatile ("li t0, 0x800\n\tcsrs mie, t0");
    asm volatile ("csrsi mstatus, 0x8");
}

/// 停 tick：清 T0_EN/ALARM_EN、关 TIMG 的 INT_ENA 与输入 16 的 IE。
/// 用于 idle 的终止状态。
pub fn disable() void {
    const cfg = reg(t0config);
    cfg.* = cfg.* & ~(bit_t0_en | bit_t0_alarm_en);
    reg(int_ena_timers).* = reg(int_ena_timers).* & ~@as(u32, 1);
    disableInput(input);
    clearPending(input);
}

/// ISR 的硬件部分：只处理属于 tick 的中断。
///
/// 返回 true 表示“这是 tick，已经清源并重装”；返回 false 交给调用者停机。
pub fn acknowledge(id: u6) bool {
    if (id != input) return false;

    // 先清 TIMG 的粘滞位，再清 CLIC 的 IP，最后重装闹钟。
    // 顺序反了会让 mret 之后立刻再进一次。
    reg(int_clr_timers).* = 1; // T0 = bit0
    clearPending(input);
    rearm();
    return true;
}

/// 软件中断让出入口（输入 19）：写 IP = 1，不需要外设。
/// 本章不接线；它是 ch14 的 IPI 与“不用 ecall 的让出”的接口。
pub fn requestYield() void {
    const p = ctrl(soft_input);
    p.* = p.* | 1;
}

/// 清软件中断的挂起位。ISR 必须调用，否则 mret 后立刻再进。
pub fn clearSoft() void {
    clearPending(soft_input);
}

