//! ch14-dual-core-smp-ipi：SYSTIMER 作为**跨核共享**的时间轴。
//!
//! 为什么不用 `mcycle`：mcycle 是每 hart 一份的周期计数器，两个核的
//! 计数值不可比（各自的启动时刻不同、DFS 时还会停），所以“core0 发出 IPI
//! 到 core1 被唤醒”这段延迟根本不能用 mcycle 跨核相减。SYSTIMER 是全局
//! 外设，两个核读的是同一个 52 位计数器 —— 这是本章唯一正确的时间基。
//!
//! 代价是：读计数器要经过一个**共享的**快照寄存器。
//!   - 写 UNIT0_OP.UPDATE(bit30) 请求把当前计数搬到 UNIT0_VALUE_HI/LO；
//!   - HI 在 0x40（20 位有效），LO 在 0x44。
//! 两个核同时请求时，本核可能在“读 HI”与“读 LO”之间被对方的快照替换。
//! 单靠一次 HI/LO 读无法发现撕裂，所以本章用 **HI→LO→HI** 复读：
//! 前后两次 HI 相同才接受；不同就重试。若两次 HI 相同，LO 即便来自稍晚的
//! 快照也不会跨越 2^32 回绕，时间戳只会略偏大（可接受）。
//!
//! 时钟门（真机约束 6）：`HP_SYS_CLKRST + 0x120`
//!   bit0 = SYSTIMER_APB_CLK_EN，bit4 = SYSTIMER_CLK_EN，两个都要置 1；
//! CONF(0x00).bit31 = SYSTIMER_CLK_EN 也必须在计数前置位。
//!
//! 频率：S31 的 TRM 仍是 Pre-release v0.7。本工程按同族 P4 的固定 2.5 分频
//! 推算（XTAL 40 MHz / 2.5 = 16 MHz，即 1 tick = 62.5 ns），但**没有在 S31
//! 真机上校准过**：日志里同时打印 tick 数与按 16 MHz 折算的 µs，换算系数
//! 待真机用示波器或第二时基确认。

const hw = @import("hw.zig");

const base: usize = 0x2039_9000;
const conf: usize = base + 0x00;
const unit0_op: usize = base + 0x04;
const unit0_hi: usize = base + 0x40;
const unit0_lo: usize = base + 0x44;

const clkrst_systimer: usize = 0x2058_7000 + 0x120;

const bit_conf_clk_en: u32 = 1 << 31;
const bit_unit_update: u32 = 1 << 30;
const hi_mask: u32 = 0x000F_FFFF;

/// 标称 tick 频率（待真机校准）。
pub const nominal_hz: u32 = 16_000_000;

pub fn init() void {
    // 1) 时钟门：bit0 APB + bit4 CLK_EN（约束 6）。
    const cr = hw.reg(clkrst_systimer);
    cr.* = cr.* | 0x11;
    hw.fenceRwRw();

    // 2) 计数器使能。
    const c = hw.reg(conf);
    c.* = c.* | bit_conf_clk_en;
    hw.fenceRwRw();
}

/// 读 52 位计数（HI→LO→HI 复读，检测跨核快照撕裂）。
pub fn now() u64 {
    var attempt: u32 = 0;
    while (attempt < 8) : (attempt += 1) {
        const op = hw.reg(unit0_op);
        op.* = bit_unit_update;

        // 等本次快照落定（该位是 WT，通常立刻回读为 0；给个上界防死等）。
        var guard: u32 = 0;
        while ((op.* & bit_unit_update) != 0 and guard < 1_000) : (guard += 1) {}

        const hi_a = hw.reg(unit0_hi).* & hi_mask;
        const lo = hw.reg(unit0_lo).*;
        const hi_b = hw.reg(unit0_hi).* & hi_mask;
        if (hi_a == hi_b) {
            return (@as(u64, hi_a) << 32) | @as(u64, lo);
        }
    }
    // 连续 8 次都被对方打断：返回最后一次读到的组合，并在调用方可见地偏大。
    return (@as(u64, hw.reg(unit0_hi).* & hi_mask) << 32) | @as(u64, hw.reg(unit0_lo).*);
}

/// tick → 微秒（整数部分）。标称 16 MHz 时 1 tick = 1/16 µs。
pub fn ticksToUs(ticks: u64) u64 {
    return ticks / (nominal_hz / 1_000_000);
}

/// tick → 微秒的小数部分（百分之一微秒），只用于打印。
pub fn ticksToUsFrac(ticks: u64) u64 {
    const per_us: u64 = nominal_hz / 1_000_000;
    return ((ticks % per_us) * 100) / per_us;
}
