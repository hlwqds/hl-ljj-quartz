//! ch05-clock-reset-wdt：RTC 看门狗（RWDT）。
//!
//! S31 上有三只看门狗，作用域不同：
//!   - RWDT（RTC WDT）：在 RTC 域，掉电/睡眠都还在跑，能复位整颗芯片；
//!   - MWDT0 / MWDT1（TIMG 里的两个定时器组观察狗）：APB/XTAL 域，一般用来
//!     复位 CPU 或整系统，IDF 的 task WDT / interrupt WDT 就挂在它们上面；
//!   - SWD（super watchdog）：最高一级，连 RTC 域一起复位。
//! 本章只操作 RWDT：它在 RTC 域，寄存器时钟常开，写起来不依赖任何时钟门控，
//! 是最适合“第一次触碰看门狗”的那一只。MWDT 与 SWD 在章节里讲语义，不写代码。
//!
//! 寄存器（IDF_PATH/components/soc/esp32s31/register/soc/rtc_wdt_reg.h，
//! 基址 DR_REG_RTC_WDT_BASE = 0x20801000，见 reg_base.h）：
//!   +0x00 CONFIG0     bit31 EN, bit12 FLASHBOOT_MOD_EN, bit11 PROCPU_RESET_EN,
//!                     bit10 APPCPU_RESET_EN, bit9 PAUSE_IN_SLP,
//!                     STG3[21:19] STG2[24:22] STG1[27:25] STG0[30:28]
//!   +0x04 CONFIG1     STG0_HOLD（tick 数，带 eFuse 决定的隐含倍率）
//!   +0x08..+0x10      CONFIG2..4 = STG1..3_HOLD
//!   +0x14 FEED        bit31：写 1 喂狗
//!   +0x18 WPROTECT    写 0x50D83AA1 解锁；写 0 上锁
//!
//! 写保护密钥取自 IDF 的 rwdt LL：
//!   IDF_PATH/components/esp_hal_wdt/esp32s31/include/hal/rwdt_ll.h
//!     #define RTC_WDT_WKEY_VALUE 0x50D83AA1
//!
//! 阶段动作编码同样来自该头文件：
//!   0 OFF / 1 INT / 2 RESET_CPU / 3 RESET_SYSTEM / 4 RESET_RTC
//!
//! 所有寄存器访问都必须夹在“解锁 → 写 → 上锁”之间，否则写被硬件丢弃
//! （不会报错，只是没生效——这是新手最容易踩的坑）。

const rwdt_base: usize = 0x2080_1000;

const reg_config0: usize = 0x00;
const reg_config1: usize = 0x04;
const reg_config2: usize = 0x08;
const reg_config3: usize = 0x0C;
const reg_config4: usize = 0x10;
const reg_feed: usize = 0x14;
const reg_wprotect: usize = 0x18;

/// 写保护解锁密钥。
pub const wkey: u32 = 0x50D83AA1;

const bit_en: u32 = 1 << 31;
const bit_flashboot: u32 = 1 << 12;
const bit_procpu_reset: u32 = 1 << 11;
const bit_appcpu_reset: u32 = 1 << 10;
const bit_feed: u32 = 1 << 31;

const stg0_shift: u5 = 28;
const stg1_shift: u5 = 25;
const stg2_shift: u5 = 22;
const stg3_shift: u5 = 19;
const stg_mask: u32 = 0x7;

/// 阶段动作，与 rwdt_ll.h 的 RTC_WDT_STG_SEL_* 一致。
/// 声明成非穷尽枚举（`_`）：3 位字段能装下 5..7 这些保留值，
/// `@enumFromInt` 读到保留值时不能触发未定义行为。
pub const Stage = enum(u3) {
    off = 0,
    interrupt = 1,
    reset_cpu = 2,
    reset_system = 3,
    reset_rtc = 4,
    _,
};

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(rwdt_base + offset);
}

fn unlock() void {
    reg(reg_wprotect).* = wkey;
}

fn lock() void {
    reg(reg_wprotect).* = 0;
}

fn stageBits(config0: u32, shift: u5) u3 {
    return @truncate((config0 >> shift) & stg_mask);
}

pub const State = struct {
    enabled: bool,
    flashboot_en: bool,
    procpu_reset_en: bool,
    appcpu_reset_en: bool,
    stage0: Stage,
    stage1: Stage,
    stage2: Stage,
    stage3: Stage,
    /// STG0 的 hold 原始值；实际超时 tick 数 = 该值 << (1 + eFuse 倍率选择)。
    stage0_hold_raw: u32,
};

/// 读当前 RWDT 配置。读寄存器不需要解锁。
pub fn state() State {
    const config0 = reg(reg_config0).*;
    return .{
        .enabled = (config0 & bit_en) != 0,
        .flashboot_en = (config0 & bit_flashboot) != 0,
        .procpu_reset_en = (config0 & bit_procpu_reset) != 0,
        .appcpu_reset_en = (config0 & bit_appcpu_reset) != 0,
        .stage0 = @enumFromInt(stageBits(config0, stg0_shift)),
        .stage1 = @enumFromInt(stageBits(config0, stg1_shift)),
        .stage2 = @enumFromInt(stageBits(config0, stg2_shift)),
        .stage3 = @enumFromInt(stageBits(config0, stg3_shift)),
        .stage0_hold_raw = reg(reg_config1).*,
    };
}

pub fn isEnabled() bool {
    return (reg(reg_config0).* & bit_en) != 0;
}

/// 喂狗：解锁 → 写 FEED.bit31 → 上锁。
///
/// 喂狗只把“喂狗阶段”的计时清零，不改变配置；如果 STG0 配的是 INT，
/// 喂狗同时清中断与计数，不会触发后续阶段。
pub fn feed() void {
    unlock();
    reg(reg_feed).* = bit_feed;
    lock();
}

/// 关狗：清 EN、清 flashboot 使能、把四个阶段全部置 OFF，再上锁。
///
/// 只清 EN 是不够的：FLASHBOOT_MOD_EN 是独立的一路使能（本意是让 WDT 在
/// flash 启动阶段也能复位），它不会随 EN 一起清掉。
pub fn disable() void {
    unlock();
    const config0 = reg(reg_config0).*;
    reg(reg_config0).* = config0 & ~(bit_en | bit_flashboot |
        (stg_mask << stg0_shift) | (stg_mask << stg1_shift) |
        (stg_mask << stg2_shift) | (stg_mask << stg3_shift));
    lock();
}

/// 装配一次“stage0 超时 → 复位整系统”。
///
/// 顺序必须是：先关、再写 hold、最后使能。若反过来，一旦 EN 之前已经是 1，
/// 写入 hold 的那一刻可能正好越过旧超时，复位就发生在配置中途。
///
/// `stage0_ticks` 是 tick 数，tick 来自 RTC_SLOW_CLK（S31 默认 RC_SLOW，
/// 标称约 136 kHz，见 soc/clk_tree_defs.h 的 SOC_CLK_RC_SLOW_FREQ_APPROX）。
/// 注意 CONFIG1 写入的值会被硅片按 2^(1 + eFuse.WDT_DELAY_SEL) 再放大
/// （IDF 的 rwdt_ll_config_stage 因此在写入前先右移），本函数写的是原始值，
/// 所以**实际超时只会比 stage0_ticks 长**；精确标定要以真机秒表为准。
pub fn armSystemReset(stage0_ticks: u32) void {
    unlock();

    // 1) 先关：清 EN 与四段动作（保留 flashboot 位原状地一并清掉）。
    const config0 = reg(reg_config0).*;
    reg(reg_config0).* = config0 & ~(bit_en | bit_flashboot | (stg_mask << stg0_shift) |
        (stg_mask << stg1_shift) | (stg_mask << stg2_shift) | (stg_mask << stg3_shift));

    // 2) 写 STG0 的 hold 与动作，其余阶段保持 OFF。
    reg(reg_config1).* = stage0_ticks;
    const armed = (reg(reg_config0).* & ~(stg_mask << stg0_shift)) |
        (@as(u32, @intFromEnum(Stage.reset_system)) << stg0_shift);

    // 3) 使能：EN 与 STG0 动作在同一次写里生效。
    reg(reg_config0).* = armed | bit_en;

    lock();
}
