//! ch08-timers-dma：SYSTIMER 作为“时间尺子”。
//!
//! ch05 已经用过一次 SYSTIMER：用它的增量去除 mcycle 的增量，把 CPU 频率
//! 量出来。本章把它提升为**全局时间基准**，因为后面两件事都需要一个不受
//! CPU 频率、不受编译器优化影响的时基：
//!
//!   - 测量 `delayUs` 的抖动：起止时刻都取 SYSTIMER；
//!   - 给 DMA 轮询设超时：计满 N 个 tick 就放弃，避免死等。
//!
//! S31 的 SYSTIMER 节拍是固定的 16 MHz（40 MHz XTAL / 2.5），所以
//! 1 µs = 16 ticks，1 tick = 62.5 ns。这个事实来自 IDF：
//!   IDF_PATH/components/esp_hw_support/port/esp32s31/systimer.c
//!   "systimer's clock source is fixed to XTAL (40MHz), and has a fixed
//!    fractional divider (2.5). So the resolution is 40MHz/2.5 = 16MHz."
//!
//! 计数器宽度：S31 的 SYSTIMER 单元是 **52 位**。本文件用 u64 保存读数，
//! 高位为 0，按 52 位理解即可（寄存器 HI 只有低位有效；本章不做“回绕补偿”，
//! 因为 2^52 tick ≈ 8.1 年，远超一次上电的生命周期）。
//!
//! 寄存器（IDF_PATH/components/soc/esp32s31/register/soc/systimer_reg.h，
//! 基址 DR_REG_SYSTIMER_BASE = 0x20399000，见 reg_base.h）：
//!   +0x00 CONF              bit31 clk_en（寄存器时钟常开），bit30 unit0 使能
//!   +0x04 UNIT0_OP          bit30 请求快照，bit29 快照有效
//!   +0x40 UNIT0_VALUE_HI    快照高 32 位
//!   +0x44 UNIT0_VALUE_LO    快照低 32 位
//!   +0x1c/+0x20 TARGET0_HI/LO      比较器 0 的目标值
//!   +0x34 TARGET0_CONF      bit30 周期模式，bit31 选择 unit0/unit1
//!
//! 本章只用计数与忙等；比较器（TARGET0..2）与中断留作练习：
//! 它们需要 ch07 的中断路由，属于「待真机验证」范围。

const systimer_base: usize = 0x2039_9000;

const reg_conf: usize = 0x00;
const reg_unit0_op: usize = 0x04;
const reg_target0_hi: usize = 0x1c;
const reg_target0_lo: usize = 0x20;
const reg_target0_conf: usize = 0x34;
const reg_unit0_value_hi: usize = 0x40;
const reg_unit0_value_lo: usize = 0x44;

const conf_clk_en: u32 = 1 << 31;
const conf_unit0_work_en: u32 = 1 << 30;
const op_update: u32 = 1 << 30;
const op_valid: u32 = 1 << 29;

/// SYSTIMER 计数节拍：16 MHz，即 1 µs = 16 ticks。
pub const ticks_per_us: u32 = 16;

/// 52 位计数器的掩码，用于把“按位取模”的算术写清楚。
pub const counter_mask: u64 = (1 << 52) - 1;

inline fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(systimer_base + offset);
}

/// 打开寄存器时钟与 unit0 计数器。
///
/// bootloader 很可能已经打开（它自己也要计时），这里的写是幂等的：
/// 只置位、不清位，不会把计数器复位，因此不会打乱 bootloader 留下的时间轴。
pub fn init() void {
    const conf = reg(reg_conf);
    conf.* = conf.* | conf_clk_en | conf_unit0_work_en;
}

/// 读 52 位计数（16 MHz）。
///
/// 读法与 IDF 的 `systimer_hal_get_counter_value` 一致：写 update 请求快照、
/// 等 valid 置位、读 LO/HI/LO 并确认两次 LO 相同（防跨 32 位进位撕裂）。
pub fn ticks() u64 {
    reg(reg_unit0_op).* = op_update;
    while ((reg(reg_unit0_op).* & op_valid) == 0) {}

    var lo = reg(reg_unit0_value_lo).*;
    while (true) {
        const hi = reg(reg_unit0_value_hi).*;
        const lo_again = reg(reg_unit0_value_lo).*;
        if (lo_again == lo) {
            const raw = (@as(u64, hi) << 32) | @as(u64, lo);
            return raw & counter_mask;
        }
        lo = lo_again;
    }
}

/// 自 boot 起的微秒数（截到 32 位，约 71 分钟回绕；打印用）。
pub fn us32() u32 {
    return @truncate(ticks() / ticks_per_us);
}

/// 微秒 → tick，向上取整：宁可比要求多等一个 tick，也不要提前返回。
pub fn ticksForUs(us: u32) u64 {
    return @as(u64, us) * ticks_per_us;
}

/// 忙等延时。基准是 SYSTIMER 而不是 ROM 的 `ets_delay_us`：后者的循环次数
/// 是 ROM 按启动时假设的频率标定的，拿它测抖动等于自证。
pub fn delayUs(us: u32) void {
    const start = ticks();
    const delta = ticksForUs(us);
    while (((ticks() -% start) & counter_mask) < delta) {}
}

/// 返回到“现在 + us”为止还需要等的 tick 数；给 DMA 轮询的超时用。
pub fn deadlineAfterUs(us: u32) u64 {
    return (ticks() + ticksForUs(us)) & counter_mask;
}

/// 判断是否已经到达（或越过）某个 deadline。
/// 用无符号相减再取掩码表达回绕：只要提前量小于半个计数器宽度，
/// 这个比较就等价于“时间到了”。
pub fn reached(deadline: u64) bool {
    return ((ticks() -% deadline) & counter_mask) < (1 << 51);
}

/// 配置比较器 0 为非周期模式，目标值 = 当前计数 + `us` 微秒。
///
/// 只写目标与模式，**不**打开中断；比较事件要靠轮询 `TARGET0` 的状态位
/// 或者 ch07 的中断路由来消费。本章正文只把它当“将来时”讲，
/// 代码里保留这个函数是为了让读者能对照手册自己接一步。
pub fn armTarget0In(us: u32) void {
    const target = (ticks() + ticksForUs(us)) & counter_mask;

    // 先写 HI 再写 LO：让比较器看到一对完整的目标值。
    reg(reg_target0_hi).* = @truncate(target >> 32);
    reg(reg_target0_lo).* = @truncate(target);

    // bit31 = 0 选 unit0；bit30 = 0 表示 target 模式（一次性）。
    reg(reg_target0_conf).* = 0;
}
