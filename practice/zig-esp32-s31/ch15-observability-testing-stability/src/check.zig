//! ch15-observability-testing-stability：启动自检清单。
//!
//! 六组检查，每组打印一行或两行“可判读”的结果，最后给出 `passed/failed`。
//! 任何一组失败都会让 `main` 直接 `trap.panic`——宁可启动即报，也不要带着
//! 错误的假设跑 1 小时压测，然后对着一条无意义的崩溃日志猜。
//!
//! | 组   | 对照物                                   | 失败意味着                       |
//! | ---- | ---------------------------------------- | -------------------------------- |
//! | syms | 链接符号 vs IDF memory.ld.in 的区间      | 链接脚本/段布局与基座不一致      |
//! | sram | `.bss`/堆/栈边界与 ASSERT 的一致性       | 静态对象吃进栈区，或边界被改错   |
//! | clock| HP_SYS_CLKRST/TIMG0 寄存器 + 1 ms 校准   | 时间基不是 1 MHz，所有 µs 都错   |
//! | irq  | `mtvec/mstatus/mie/CLIC` 寄存器          | 向量没装、模式不对、中断没关     |
//! | wdt  | `RTC_WDT_CONFIG0` 的 EN 位               | 二级 bootloader 的狗还在跑       |
//! | trace| 环形缓冲自身（覆盖/顺序/丢弃计数）       | 观测工具本身有 bug               |
//!
//! 区间常量来自 ESP-IDF v6.1：
//!   `components/esp_system/ld/esp32s31/memory.ld.in:19`  SRAM_START = 0x2F000000
//!   `components/esp_system/ld/esp32s31/ld.hp_mem_defs`    SRAM_SEG_END = 0x2F07AFC0
//!   `components/soc/esp32s31/register/soc/reg_base.h:71`  TIMG0 = 0x20580000
//!   `components/soc/esp32s31/register/soc/reg_base.h:79`  HP_SYS_CLKRST = 0x20587000
//!   `components/soc/esp32s31/include/soc/clic_reg.h:17`   CLIC = 0x10800000
//!   `components/soc/esp32s31/register/soc/rtc_wdt_reg.h:87` WDT_EN bit31
//!
//! 「真机记录」：2026-11-13 首轮已读回 TIMG0（1003 µs/1000 µs）、`mtvec`
//! （写 0x2f000000 得 0x2f000003）、RTC_WDT（`en=1 stg=0`）。修复后的复跑
//! 仍待确认；判据一律打印原始值，别让结论与证据分开。

const hw = @import("hw.zig");
const log = @import("log.zig");
const trace = @import("trace.zig");
const trap = @import("trap.zig");

// ---------------------------------------------------------------------------
// 链接符号（全部由 linker/s31.ld 定义）
// ---------------------------------------------------------------------------

extern const _image_start: u8;
extern const _text_start: u8;
extern const _text_end: u8;
extern const _rodata_start: u8;
extern const _rodata_end: u8;
extern const _trap_start: u8;
extern const _trap_end: u8;
extern const _data_start: u8;
extern const _data_end: u8;
extern const _bss_start: u8;
extern const _bss_end: u8;
extern const _heap_start: u8;
extern const _heap_end: u8;
extern const _stack_bottom: u8;
extern const _stack_top: u8;

fn at(comptime sym: *const u8) usize {
    // 真机首轮 `bounds_bits=0x3a`：`heap_start == bss_end` 与
    // `heap_end == stack_bottom` 在值相等时仍判 0。原因是 LLVM 会把
    // “两个不同全局符号的地址相等”直接折叠成 false（链接脚本符号在
    // 编译期仍是两个不同的 GlobalValue）。用一条空的内联汇编把地址
    // 变成编译器无法推理的运行时值：`"r"` 约束强制它落进寄存器。
    var v: usize = @intFromPtr(sym);
    asm volatile (""
        : [v] "+r" (v),
        :
        : .{});
    return v;
}

// 与 IDF v6.1 的 esp32s31 内存定义一致（见文件头）。
pub const irom_org: usize = 0x4000_0020;
pub const irom_len: usize = 0x3F000;
pub const drom_org: usize = 0x4002_0020;
pub const drom_len: usize = 0x3F000;
pub const sram_org: usize = 0x2F00_0000;
pub const sram_len: usize = 0x7AFC0;
pub const stack_size: usize = 0x4000;

const timergrp0_ctrl0: usize = 0x2058_7000 + 0x114;
const clic_thresh: usize = 0x1080_0008;
const clic_ctrl_base: usize = 0x1080_1000;
const clic_input_tick: usize = 16;
const rtc_wdt_config0: usize = 0x2080_1000;
const rtc_wdt_wprotect: usize = 0x2080_1018;

// ---------------------------------------------------------------------------
// 计数与判据
// ---------------------------------------------------------------------------

pub const Report = struct {
    passed: u32 = 0,
    failed: u32 = 0,
};

var report: Report = .{};

fn verdict(ok: bool) bool {
    if (ok) {
        report.passed += 1;
    } else {
        report.failed += 1;
    }
    return ok;
}

fn inRange(v: usize, start: usize, len: usize) bool {
    return v >= start and v < start + len;
}

// ---------------------------------------------------------------------------
// 1) 链接符号与 flash 区间
// ---------------------------------------------------------------------------

fn checkFlash() bool {
    const image = at(&_image_start);
    const text_start = at(&_text_start);
    const text_end = at(&_text_end);
    const rodata_start = at(&_rodata_start);
    const rodata_end = at(&_rodata_end);

    const ok = image == irom_org and
        text_start > image and
        text_end > text_start and
        inRange(text_start, irom_org, irom_len) and
        text_end <= irom_org + irom_len and
        rodata_start >= drom_org and
        rodata_end > rodata_start and
        rodata_end <= drom_org + drom_len;

    log.line("check: flash image=0x{x} text=0x{x}..0x{x}", .{ image, text_start, text_end });
    log.line("check: flash drom=0x{x}..0x{x} rodata=0x{x}..0x{x} ok={d}", .{
        drom_org, drom_org + drom_len, rodata_start, rodata_end, @intFromBool(ok),
    });
    return verdict(ok);
}

// ---------------------------------------------------------------------------
// 2) SRAM：trap/.data/.bss/堆/栈的边界
// ---------------------------------------------------------------------------

fn checkSram() bool {
    const trap_start = at(&_trap_start);
    const trap_end = at(&_trap_end);
    const data_start = at(&_data_start);
    const data_end = at(&_data_end);
    const bss_start = at(&_bss_start);
    const bss_end = at(&_bss_end);
    const heap_start = at(&_heap_start);
    const heap_end = at(&_heap_end);
    const stack_bottom = at(&_stack_bottom);
    const stack_top = at(&_stack_top);

    const trap_ok = trap_start % 4 == 0 and
        trap_end > trap_start and
        inRange(trap_start, sram_org, sram_len) and
        trap_end <= sram_org + sram_len;

    // 本镜像的 .data 是空的（所有可变全局都是零初始化，落在 .bss），
    // 所以 `_data_start == _data_end` 是**健康**形态。这里用 >= 而不是 >：
    // 空段合法，重叠才非法。
    const data_ok = data_end >= data_start and
        bss_start >= data_end and
        bss_end > bss_start and
        inRange(bss_start, sram_org, sram_len) and
        bss_end <= sram_org + sram_len;

    // 六个边界条件各占一位，打印成 bitmask：哪一位是 0 就表示哪一条不成立。
    // 首轮真机只看到汇总 ok=0，无法定位失败项；把判据本身拆开打印，是 §15.10
    // “先看汇总再看失败组”原则的自应用。
    const expect_top = sram_org + sram_len;
    var bounds_bits: u8 = 0;
    if (heap_start == bss_end) bounds_bits |= 1 << 0;
    if (bss_end <= heap_end) bounds_bits |= 1 << 1;
    if (heap_end == stack_bottom) bounds_bits |= 1 << 2;
    if (stack_top == expect_top) bounds_bits |= 1 << 3;
    if (stack_top - stack_bottom == stack_size) bounds_bits |= 1 << 4;
    if (stack_top % 16 == 0) bounds_bits |= 1 << 5;
    const bounds_ok = bounds_bits == 0x3F;

    log.line("check: sram trap=0x{x}..0x{x} data=0x{x}..0x{x}", .{
        trap_start, trap_end, data_start, data_end,
    });
    log.line("check: sram bss=0x{x}..0x{x} heap=0x{x}..0x{x}", .{
        bss_start, bss_end, heap_start, heap_end,
    });
    log.line("check: sram stack=0x{x}..0x{x} expect_top=0x{x} size=0x{x}", .{
        stack_bottom, stack_top, expect_top, stack_size,
    });
    log.line("check: sram trap_ok={d} data_ok={d} bounds_bits=0x{x} ok={d}", .{
        @intFromBool(trap_ok),
        @intFromBool(data_ok),
        bounds_bits,
        @intFromBool(bounds_ok),
    });
    _ = verdict(trap_ok);
    _ = verdict(data_ok);
    return verdict(bounds_ok);
}

// ---------------------------------------------------------------------------
// 3) 时钟：T0 时钟门控、源选择、1 ms 校准
// ---------------------------------------------------------------------------

fn checkClock() bool {
    const ctrl = hw.readReg(timergrp0_ctrl0);
    const apb_en = (ctrl & (1 << 0)) != 0;
    const t0_clk_en = (ctrl & (1 << 5)) != 0;
    const src = (ctrl >> 3) & 0b11;

    // 硬件门控是自己写的，必须为真；它失败说明时钟根本没打开。
    const gate = apb_en and t0_clk_en and src == 0;

    const t0 = hw.nowUs();
    hw.delayUs(1000);
    const t1 = hw.nowUs();
    const measured = t1 -| t0;
    const ratio_pct = measured * 100 / 1000;
    const calibrated = measured >= 800 and measured <= 1200;

    log.line("check: clock ctrl=0x{x} apb_en={d} t0_clk_en={d} src={d} ok={d}", .{
        ctrl, @intFromBool(apb_en), @intFromBool(t0_clk_en), src, @intFromBool(gate),
    });
    // 1 ms 校准只是 advisory：参考值是 ROM 的 ets_delay_us，它的精度取决于
    // bootloader 留下的 ticks_per_us 是否与当前 CPU 频率一致；“分频 40 = 1 MHz”
    // 首轮 1003 µs 已确认 1 MHz；把它升级成硬判据会让首次上板在心跳/断言/panic 演示
    // 之前就 panic——那正是本章最不想看到的“观测器挡住观测”。
    log.line("check: clock delay=1000us measured={d}us ratio={d}% advisory={s}", .{
        measured, ratio_pct, if (calibrated) "ok" else "out-of-range",
    });
    return verdict(gate);
}

// ---------------------------------------------------------------------------
// 4) 中断：mtvec 模式/对齐/目标、MIE、mie、CLIC 阈值
// ---------------------------------------------------------------------------

fn checkInterrupts() bool {
    const mtvec = hw.readMtvec();
    const base = mtvec & ~@as(usize, 3);
    const trap_addr = @intFromPtr(&trap.trapEntry);
    const mstatus = hw.readMstatus();
    const mie = hw.readMie();
    const thresh = (hw.readReg(clic_thresh) >> 24) & 0xF;
    const tick_ctl = hw.readReg(clic_ctrl_base + 4 * clic_input_tick);

    // 真机首轮（2026-11-13）：写进去的是 0x2f000000，读回 0x2f000003。
    // S31 把 mtvec.MODE 固定成 3（CLIC 模式，BRINGUP ch07 已记录同一现象），
    // 所以只能比较 BASE；同步异常仍然从 base 进入（ch06 实测）。
    const ok = base == trap_addr and
        inRange(base, sram_org, sram_len) and
        (mstatus & 0x8) == 0 and
        mie == 0;

    log.line("check: irq mtvec=0x{x} base=0x{x} trapEntry=0x{x} mode={d} (info)", .{
        mtvec, base, trap_addr, mtvec & 3,
    });
    log.line("check: irq MIE={d} mie=0x{x} thresh={d} clic[{d}]=0x{x} ok={d}", .{
        (mstatus >> 3) & 1, mie, thresh, clic_input_tick, tick_ctl, @intFromBool(ok),
    });
    return verdict(ok);
}

// ---------------------------------------------------------------------------
// 5) 看门狗：RTC WDT 必须已被 _start 关掉
// ---------------------------------------------------------------------------

fn checkWatchdog() bool {
    const cfg = hw.readReg(rtc_wdt_config0);
    const wprotect = hw.readReg(rtc_wdt_wprotect);
    const en = (cfg & hw.rtc_wdt_en) != 0;
    const stages = cfg & hw.rtc_wdt_stage_mask;
    const flashboot = (cfg & hw.rtc_wdt_flashboot) != 0;
    // EN 在这颗芯片上读回 1（WARL/自恢复），但四个 stage 全 0 时看门狗
    // 没有任何动作可做——ch05 的板级记录就是 `rwdt en=1 stg=0`，且通过。
    // 因此功能判据是“没有武装 stage + flashboot 关闭”，EN 只作信息打印。
    const ok = stages == 0 and !flashboot and wprotect == 0;

    log.line("check: wdt cfg=0x{x} en={d} stages=0x{x} flashboot={d} wprotect=0x{x} ok={d}", .{
        cfg,
        @intFromBool(en),
        stages,
        @intFromBool(flashboot),
        wprotect,
        @intFromBool(ok),
    });
    return verdict(ok);
}

// ---------------------------------------------------------------------------
// 6) trace 环自检（不依赖硬件）
// ---------------------------------------------------------------------------

fn checkTrace() bool {
    var probe: trace.Ring = .{};
    const total: u32 = trace.capacity + 3;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        probe.push(.{ .t_us = i * 10, .tag = .check_ok, .a = i, .b = 0 });
    }
    const ok = probe.count() == trace.capacity and
        probe.dropped == 3 and
        probe.at(0).?.a == 3 and
        probe.latest().?.a == total - 1;

    log.line("check: trace cap={d} count={d} dropped={d} oldest=0x{x} newest=0x{x} ok={d}", .{
        trace.capacity,
        probe.count(),
        probe.dropped,
        probe.at(0).?.a,
        probe.latest().?.a,
        @intFromBool(ok),
    });
    return verdict(ok);
}

// ---------------------------------------------------------------------------
// 可恢复断言
// ---------------------------------------------------------------------------

/// 可恢复断言：条件不成立时打印 + 记 trace，但**继续执行**。
/// 与 `trap.panic` 的分界线：调用方能在失败后安全降级（跳过该实验、
/// 用保守默认值），就用它；否则用 panic。
pub fn expect(cond: bool, comptime tag: []const u8) bool {
    if (cond) {
        log.line("assert: ok tag={s}", .{tag});
        return true;
    }
    log.line("assert: caught tag={s} action=recover", .{tag});
    trace.g_ring.push(.{
        .t_us = hw.nowUs(),
        .tag = .assert_caught,
        .a = 0,
        .b = 0,
    });
    return false;
}

// ---------------------------------------------------------------------------
// 总控
// ---------------------------------------------------------------------------

/// 跑完六组自检，返回是否全部通过。失败时仍会把六组都跑完再返回，
/// 这样串口里能一次看到所有问题，而不是“修一个、重启、再看下一个”。
pub fn runAll() bool {
    report = .{};
    log.raw("check: begin - symbols, regions, clock, interrupt, watchdog, trace\n");

    _ = checkFlash();
    _ = checkSram();
    _ = checkClock();
    _ = checkInterrupts();
    _ = checkWatchdog();
    _ = checkTrace();

    const ok = report.failed == 0;
    log.line("checks: passed={d} failed={d} total={d} advisory=1 (clock calibration)", .{
        report.passed, report.failed, report.passed + report.failed,
    });
    trace.g_ring.push(.{
        .t_us = hw.nowUs(),
        .tag = if (ok) .check_ok else .check_fail,
        .a = report.passed,
        .b = report.failed,
    });
    return ok;
}
