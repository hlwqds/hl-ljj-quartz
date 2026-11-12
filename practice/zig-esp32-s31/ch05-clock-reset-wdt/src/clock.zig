//! ch05-clock-reset-wdt：把“CPU 到底跑多快”量出来。
//!
//! 本章不写任何 PLL/时钟树寄存器。40 MHz XTAL → CPLL(320 MHz) 的选择是二级
//! bootloader 做的，应用只是继承结果。要证明这个结果，得有一个**独立的**
//! 时间基准，方案是用 SYSTIMER 当尺子、用 `mcycle` 当被测对象：
//!
//!   CPU 频率 = mcycle 增量 / SYSTIMER 走过的时间
//!
//! SYSTIMER 的时钟源在 S31 上是**固定**的 XTAL 40 MHz，并且有一个固定的
//! 2.5 分频，所以计数节拍恒为 16 MHz（1 tick = 62.5 ns）：
//!   IDF_PATH/components/esp_hw_support/port/esp32s31/systimer.c
//!   "systimer's clock source is fixed to XTAL (40MHz), and has a fixed
//!    fractional divider (2.5). So the resolution is 40MHz/2.5 = 16MHz."
//!
//! 因此这条测量链只需要两个前提：XTAL 是 40 MHz（板级事实），以及
//! SYSTIMER 计数器在跑（本文件 init() 里显式打开）。
//!
//! 寄存器（IDF_PATH/components/soc/esp32s31/register/soc/systimer_reg.h，
//! 基址 DR_REG_SYSTIMER_BASE = 0x20399000，见 reg_base.h）：
//!   +0x00 CONF                bit31 clk_en，bit30 unit0 使能
//!   +0x04 UNIT0_OP            bit30 请求快照，bit29 快照有效
//!   +0x40 UNIT0_VALUE_HI      快照高 20 位（64 位计数的高位部分）
//!   +0x44 UNIT0_VALUE_LO      快照低 32 位
//!
//! 计数器的读法照抄 IDF 的 systimer_hal_get_counter_value：写 update、
//! 等 valid、读 LO/HI/LO 并确认两次 LO 相同（防跨 32 位进位撕裂）。

const systimer_base: usize = 0x2039_9000;

const reg_conf: usize = 0x00;
const reg_unit0_op: usize = 0x04;
const reg_unit0_value_hi: usize = 0x40;
const reg_unit0_value_lo: usize = 0x44;

const conf_clk_en: u32 = 1 << 31;
const conf_unit0_en: u32 = 1 << 30;
const op_update: u32 = 1 << 30;
const op_valid: u32 = 1 << 29;

/// SYSTIMER 计数节拍：40 MHz XTAL / 2.5 = 16 MHz，即 1 µs = 16 ticks。
pub const ticks_per_us: u32 = 16;

/// HP_SYS_CLKRST 的 SYSTIMER_CTRL0（+0x120）：两个门控位都要开。
/// 真机发现（2026-11-12）：APB_CLK_EN（bit0）只管寄存器访问，CLK_EN（bit4）
/// 才是计数器时钟；两者复位值均为 0。只开 bit0 时寄存器读得通但恒为 0，
/// 表象是"量出来 0 MHz、measure 的忙等永不结束"。IDF 在
/// `esp_timer_impl_early_init()` 里先 enable_bus_clock 再 enable_sys_clock，
/// 顺序与本函数一致。
const clkrst_systimer_ctrl0: usize = 0x2058_7000 + 0x120;

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(systimer_base + offset);
}

/// 打开 SYSTIMER 的寄存器时钟与 unit0 计数器。
///
/// bootloader 很可能已经打开（它要用 SYSTIMER 计时），这里的写是幂等的：
/// 只置位、不清位，不会把计数器复位，所以不会影响 bootloader 留下的时间轴。
pub fn init() void {
    // 先开总线时钟与计数器时钟（bit0 APB_CLK_EN、bit4 CLK_EN），否则计数值恒为 0。
    const gate: *volatile u32 = @ptrFromInt(clkrst_systimer_ctrl0);
    gate.* = gate.* | (1 << 0) | (1 << 4);

    const conf = reg(reg_conf);
    conf.* = conf.* | conf_clk_en | conf_unit0_en;
}

/// 读 SYSTIMER 的 64 位计数（16 MHz，约 36600 年回绕一次）。
///
/// 真机发现（2026-11-12）：先写 `UNIT0_OP.UPDATE` 再等 `VALID` 的写法在本板
/// 会永久挂住（VALID 一直是 0）——IDF 的 `systimer_ll_get_counter_value_*`
/// 根本不走这条快照路径，而是直接读 LO/HI。这里改成 LO→HI→LO 的两读一致
/// 检查（防 32 位进位撕裂），与 IDF 的取值口径一致。
pub fn ticks() u64 {
    const hi_mask: u64 = 0x000F_FFFF; // UNIT0_VALUE_HI 只有 20 位

    // 先走 IDF 的快照路径：写 UPDATE → 等 VALID → 读 HI/LO。
    // 真机观察：门控没开时 VALID 永远不为 1，所以必须有上限。
    reg(reg_unit0_op).* = op_update;
    var spins: u32 = 0;
    while ((reg(reg_unit0_op).* & op_valid) == 0) : (spins += 1) {
        if (spins > 10_000) break;
    }
    const hi = reg(reg_unit0_value_hi).*;
    const lo = reg(reg_unit0_value_lo).*;
    if (lo != 0 or hi != 0) return ((@as(u64, hi) & hi_mask) << 32) | @as(u64, lo);

    // 退路：直接读（两读一致防进位撕裂）。
    var lo2 = reg(reg_unit0_value_lo).*;
    var guard: u32 = 0;
    while (guard < 1024) : (guard += 1) {
        const hi2 = reg(reg_unit0_value_hi).*;
        const lo3 = reg(reg_unit0_value_lo).*;
        if (lo3 == lo2) return ((@as(u64, hi2) & hi_mask) << 32) | @as(u64, lo2);
        lo2 = lo3;
    }
    return ((@as(u64, reg(reg_unit0_value_hi).*) & hi_mask) << 32) | @as(u64, reg(reg_unit0_value_lo).*);
}

/// 自 boot 起的微秒数（低 32 位，约 71 分钟回绕）。
pub fn us() u32 {
    return @truncate(ticks() / ticks_per_us);
}

/// 读 `mcycle` 的低 32 位。320 MHz 下约 13.4 秒回绕，本章的测量窗口是 200 ms。
inline fn cycleCounter() u32 {
    return asm volatile ("csrr %[dst], mcycle"
        : [dst] "=r" (-> u32),
    );
}

pub const Measurement = struct {
    /// 测量窗口内 mcycle 的增量（32 位，窗口必须远小于 13.4 秒）。
    cycles: u32,
    /// 同一窗口内 SYSTIMER 的增量（16 MHz 计数）。
    ticks: u32,

    pub fn us(self: Measurement) u32 {
        return self.ticks / ticks_per_us;
    }

    /// 折算出的 CPU 频率，四舍五入到 1 MHz。
    pub fn mhz(self: Measurement) u32 {
        const window_us = self.us();
        if (window_us == 0) return 0;
        return (self.cycles + window_us / 2) / window_us;
    }
};

/// 在 `window_us` 微秒的窗口里同时量 SYSTIMER 增量与 mcycle 增量。
///
/// 窗口 200 ms 时，320 MHz 的 CPU 大约走 6400 万个 cycle，32 位够用；
/// 窗口也不能太小，否则整除了 1 MHz 的分辨率会让结果抖。
pub fn measure(window_us: u32) Measurement {
    const window_ticks: u64 = @as(u64, window_us) * ticks_per_us;

    const start_ticks = ticks();
    const start_cycles = cycleCounter();

    // 防御性上限：SYSTIMER 若没有走动，绝不在这里死循环（真机排障最怕静默挂死）。
    var spins: u64 = 0;
    while (ticks() - start_ticks < window_ticks) : (spins += 1) {
        if (spins > 50_000_000) break;
    }

    const end_cycles = cycleCounter();
    const end_ticks = ticks();

    return .{
        .cycles = end_cycles -% start_cycles,
        .ticks = @truncate(end_ticks - start_ticks),
    };
}

/// 忙等延时。用 SYSTIMER 而不是 ROM 的 `ets_delay_us`：后者的循环次数是 ROM
/// 按启动时假设的频率标定的，用它测频率等于自证，测不出偏差。
pub fn delayUs(delay_us: u32) void {
    const delta: u64 = @as(u64, delay_us) * ticks_per_us;
    const start = ticks();
    while (ticks() - start < delta) {}
}
