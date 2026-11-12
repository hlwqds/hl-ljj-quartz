//! ch05-clock-reset-wdt：读复位原因、量 CPU 频率、显式喂狗。
//!
//! `main` 由 `_start` 用 `call main` 直接进入（不是 IDF 的 `app_main`），
//! 所以符号名必须就是 `main`——用 `pub export fn`。C 调用约定，不返回。
//!
//! 输出只依赖掩膜 ROM：`esp_rom_printf` 的地址由 linker/s31.ld 的 PROVIDE
//! 提供（0x2f800024，即 ROM 的 `ets_printf`）。ROM 的 printf 支持
//! `%s/%c/%u/%d/%x/%p` 这些基本格式，本章只用其中最小的一组，且只打印
//! 32 位整数——S31 ROM 对 `%llu` 的支持不在本章的验证范围内。
//!
//! 本章的两个“可观测事实”：
//!   1) 复位原因：ROM 的 `rtc_get_reset_reason(0)`，见 src/reset.zig；
//!   2) CPU 频率：mcycle 对 SYSTIMER 的比值，见 src/clock.zig。
//! 两者都不写任何时钟/PLL 寄存器——测的是 bootloader 配置的结果。

const builtin = @import("builtin");

const clock = @import("clock.zig");
const reset = @import("reset.zig");
const wdt = @import("wdt.zig");

comptime {
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch05-clock-reset-wdt 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch05-clock-reset-wdt 需要 eabihf（硬浮点）ABI");
    }
}

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

/// 测量窗口：200 ms。320 MHz 下约 6400 万 cycle，32 位 mcycle 够用，
/// 折算到 1 MHz 的分辨率也足够稳。
const measure_window_us: u32 = 200_000;

/// 主循环的喂狗周期，必须明显小于 RWDT 的实际超时。
const feed_period_us: u32 = 500_000;

/// 超时实验开关：0 表示不做实验（正常喂狗）。改成非 0 的 tick 数
/// （RTC_SLOW_CLK ≈ 136 kHz，3 秒约 408000）后重新构建烧录，应用会在
/// 配置的时间后停止喂狗并被 RWDT 复位；下一次启动时复位原因会变成
/// CPU_RWDT(0x0d) / SYS_RWDT(0x10) 一类，正好用本章打印的那几行证据闭环。
/// 具体编码取决于 stage0 的动作与 PROCPU/APPCPU 使能位，以真机为准。
const demo_timeout_ticks: u32 = 0;

fn printU32(value: u32) void {
    _ = esp_rom_printf("%u", @as(c_uint, value));
}

fn printHex32(value: u32) void {
    _ = esp_rom_printf("%x", @as(c_uint, value));
}

pub export fn main() void {
    // 1) SYSTIMER 是本模块唯一的时间基准，先把它的寄存器时钟与 unit0 打开。
    clock.init();

    // 2) 复位原因：ROM 已经判定好了，这里只是翻译成人能读的名字。
    const reason_code = reset.read();
    const reason = reset.info(reason_code);

    _ = esp_rom_printf("\n=== ch05-clock-reset-wdt ===\n");
    _ = esp_rom_printf("reset reason: code=");
    printHex32(reason_code);
    _ = esp_rom_printf(" (%s, %s)\n", reason.name.ptr, reason.idf.ptr);
    _ = esp_rom_printf("  meaning: %s\n", reset.hint(reason_code).ptr);

    // 3) 量 CPU 频率。这是一次 200 ms 的忙等，只做一次；读数先落到局部量，
    //    再逐段打印，避免在测量窗口里插入 UART 输出。
    const m = clock.measure(measure_window_us);
    _ = esp_rom_printf("clock: cycles=");
    printU32(m.cycles);
    _ = esp_rom_printf(" ticks=");
    printU32(m.ticks);
    _ = esp_rom_printf(" (window ");
    printU32(m.us());
    _ = esp_rom_printf(" us) -> CPU ");
    printU32(m.mhz());
    _ = esp_rom_printf(" MHz\n");
    _ = esp_rom_printf("  expect 320 (CPLL) on this board; 40 means XTAL-only boot\n");

    // 4) 看门狗现状：先看清楚 bootloader 留下了什么，再决定喂还是关。
    const st = wdt.state();
    _ = esp_rom_printf(
        "rwdt: en=%u flashboot=%u stg0=%u stg1=%u stg2=%u stg3=%u hold=",
        @as(c_uint, @intFromBool(st.enabled)),
        @as(c_uint, @intFromBool(st.flashboot_en)),
        @as(c_uint, @intFromEnum(st.stage0)),
        @as(c_uint, @intFromEnum(st.stage1)),
        @as(c_uint, @intFromEnum(st.stage2)),
        @as(c_uint, @intFromEnum(st.stage3)),
    );
    printU32(st.stage0_hold_raw);
    _ = esp_rom_printf("\n");

    if (demo_timeout_ticks != 0) {
        // 超时实验：装配 stage0 = RESET_SYSTEM 后**故意不再喂**。
        wdt.armSystemReset(demo_timeout_ticks);
        _ = esp_rom_printf("DEMO: rwdt armed with stage0 ticks=");
        printU32(demo_timeout_ticks);
        _ = esp_rom_printf(", feeding stopped on purpose\n");
    } else {
        // 正常路径：显式喂一次，确认写保护流程通得过。
        wdt.feed();
    }

    // 5) 主循环：每 500 ms 喂一次狗，打印 boot 后的微秒数与累计 tick 数。
    //    不喂狗的话，bootloader 若把 RWDT 留在使能状态，几秒后就会复位——
    //    这正是下一节“复位原因”要解释的现象。
    var count: u32 = 0;
    while (true) {
        clock.delayUs(feed_period_us);

        if (demo_timeout_ticks == 0) {
            wdt.feed();
        }

        count +%= 1;
        _ = esp_rom_printf("tick ");
        printU32(count);
        _ = esp_rom_printf(" at ");
        printU32(clock.us());
        _ = esp_rom_printf(" us\n");
    }
}
