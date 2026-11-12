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

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(systimer_base + offset);
}

/// 打开 SYSTIMER 的寄存器时钟与 unit0 计数器。
///
/// bootloader 很可能已经打开（它要用 SYSTIMER 计时），这里的写是幂等的：
/// 只置位、不清位，不会把计数器复位，所以不会影响 bootloader 留下的时间轴。
pub fn init() void {
    const conf = reg(reg_conf);
    conf.* = conf.* | conf_clk_en | conf_unit0_en;
}

/// 读 SYSTIMER 的 64 位计数（16 MHz，约 36600 年回绕一次）。
pub fn ticks() u64 {
    reg(reg_unit0_op).* = op_update;
    while ((reg(reg_unit0_op).* & op_valid) == 0) {}

    var lo = reg(reg_unit0_value_lo).*;
    while (true) {
        const hi = reg(reg_unit0_value_hi).*;
        const lo_again = reg(reg_unit0_value_lo).*;
        if (lo_again == lo) {
            return (@as(u64, hi) << 32) | @as(u64, lo);
        }
        lo = lo_again;
    }
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

    while (ticks() - start_ticks < window_ticks) {}

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
