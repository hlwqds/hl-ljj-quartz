//! ch08-timers-dma：定时器精度与 DMA 搬运的最小可观测应用。
//!
//! `main` 由 `_start` 用 `call main` 直接进入（不是 IDF 的 `app_main`），
//! 所以符号名必须就是 `main`：`pub export fn main`。C 调用约定，不返回。
//!
//! 本章只做两件可观测的事，顺序固定：
//!
//!   1. **抖动测量**：TIMG0 T0 配成 1 MHz（1 tick = 1 µs），以 1 ms 为周期
//!      连续装 64 次闹钟，记录每次“实际命中时刻 - 目标时刻”的偏差；
//!      再用 SYSTIMER 量 64 次 `delayUs(500)` 的实际耗时偏差。
//!      前者是硬件路径的抖动，后者是软件忙等的抖动，两者对比就是本章
//!      8.5 节的核心结论。
//!   2. **DMA 搬运**：AHB-GDMA 通道对 0 把 512 字节从 `dma_src` 搬到
//!      `dma_dst`（2 个 256 字节描述符？不——1024 字节一段，512 字节只需
//!      1 段；为了真正走链表，这里用 2 段 × 256 字节），然后逐字节比对。
//!
//! 之后主循环每 500 ms 重复一次 DMA 搬运并打印一行心跳：
//!   翻转一次观测引脚（示波器上看周期是否稳），再跑一次搬运。
//!
//! 串口输出只依赖掩膜 ROM 的 `esp_rom_printf`（链接脚本 PROVIDE 到
//! 0x2f800024）；本章不自己配 UART，也不开中断。

const builtin = @import("builtin");

const systimer = @import("systimer.zig");
const timg = @import("timg.zig");
const dma = @import("dma.zig");

comptime {
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch08-timers-dma 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch08-timers-dma 需要 eabihf（硬浮点）ABI");
    }
}

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

// ---------------------------------------------------------------------------
// 观测引脚（GPIO5）：用来把“软件时刻”搬到示波器上。
//
// 与 ch06 相同的三层配置：IO_MUX 选 GPIO 功能 → OUT_SEL = 256 →
// 打开输出使能。寄存器出处：
//   components/soc/esp32s31/register/soc/gpio_reg.h
//   components/soc/esp32s31/register/soc/io_mux_reg.h
// 引脚在 J2 上的实际位置需按板卡原理图核对（待真机验证）。
// ---------------------------------------------------------------------------
const gpio_base: usize = 0x2058_3000;
const io_mux_base: usize = 0x2058_2000;

const monitor_pin: u5 = 5;
const monitor_bit: u32 = 1 << monitor_pin;

const reg_out_w1ts: usize = gpio_base + 0x08;
const reg_out_w1tc: usize = gpio_base + 0x0c;
const reg_out: usize = gpio_base + 0x04;
const reg_enable_w1ts: usize = gpio_base + 0x38;
const reg_func_out_sel_base: usize = gpio_base + 0xaf4;

const fun_ie: u32 = 1 << 9;
const mcu_sel_shift: u5 = 12;
const mcu_sel_mask: u32 = 0x7 << mcu_sel_shift;
const pin_func_gpio: u32 = 1;
const sig_gpio_out_idx: u32 = 256;

fn io(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

fn monitorInit() void {
    const io_mux = io(io_mux_base + @as(usize, monitor_pin) * 4);
    var v = io_mux.*;
    v &= ~mcu_sel_mask;
    v |= (pin_func_gpio << mcu_sel_shift) | fun_ie;
    io_mux.* = v;

    io(reg_func_out_sel_base + @as(usize, monitor_pin) * 4).* = sig_gpio_out_idx;
    io(reg_out_w1tc).* = monitor_bit;
    io(reg_enable_w1ts).* = monitor_bit;
}

fn monitorToggle() void {
    const high = (io(reg_out).* & monitor_bit) != 0;
    if (high) {
        io(reg_out_w1tc).* = monitor_bit;
    } else {
        io(reg_out_w1ts).* = monitor_bit;
    }
}

// ---------------------------------------------------------------------------
// 极简打印：ROM printf 的变参对 32 位整数最稳，u64 一律先截到 u32。
// ---------------------------------------------------------------------------
fn printU32(v: u32) void {
    _ = esp_rom_printf("%u", @as(c_uint, v));
}

fn printHex32(v: u32) void {
    _ = esp_rom_printf("%x", @as(c_uint, v));
}

fn printI32(v: i32) void {
    if (v < 0) {
        _ = esp_rom_printf("-");
        printU32(@intCast(-v));
    } else {
        printU32(@intCast(v));
    }
}

const line = "\n";

// ---------------------------------------------------------------------------
// 抖动测量
// ---------------------------------------------------------------------------

const sample_count: u32 = 64;
/// TIMG 的闹钟周期：1 ms = 1000 个 1 µs tick。
const period_ticks: u32 = 1_000;
/// 软件延时：500 µs。
const soft_delay_us: u32 = 500;

const Jitter = struct {
    min: i32,
    max: i32,
    mean_abs: u32,
    /// 最后一次观察到的“相邻两次命中的间隔”，用来发现累计漂移。
    last_interval: u32,
    samples: u32,
};

/// 硬件定时器抖动：每次把闹钟装在**绝对时刻** `target` 上，命中后读计数器。
///
/// 为什么用绝对时刻而不是“命中后再等一个周期”：后者会把每次的迟到量
/// 累加进去，测到的是“软件调度延迟的积分”，而不是定时器本身的抖动。
fn measureTimerJitter() Jitter {
    timg.start(.{ .divider = timg.dividerFor(1_000_000), .auto_reload = false });
    timg.clearAlarm();
    timg.setCounter(0);

    var min_dev: i32 = 1_000_000;
    var max_dev: i32 = -1_000_000;
    var sum_abs: u64 = 0;

    var target: u64 = period_ticks;
    var last_now: u64 = 0;
    var last_interval: u32 = 0;

    var i: u32 = 0;
    while (i < sample_count) : (i += 1) {
        timg.setAlarm(target);
        timg.enableAlarm();

        // 忙等命中。这里不做任何打印：串口输出会把测量窗口拉长几个数量级。
        while (!timg.alarmPending()) {}

        const now = timg.counter();
        const dev: i32 = @intCast(@as(i64, @intCast(now)) - @as(i64, @intCast(target)));
        if (dev < min_dev) min_dev = dev;
        if (dev > max_dev) max_dev = dev;
        sum_abs += @intCast(if (dev < 0) -dev else dev);

        if (i != 0) {
            last_interval = @intCast(now - last_now);
        }
        last_now = now;

        timg.clearAlarm();
        monitorToggle();

        target += period_ticks;
    }

    timg.stop();

    return .{
        .min = min_dev,
        .max = max_dev,
        .mean_abs = @intCast(sum_abs / sample_count),
        .last_interval = last_interval,
        .samples = sample_count,
    };
}

/// 软件延时抖动：起止都用 TIMG 计数器读（1 µs 分辨率）。
/// 期望值就是 `soft_delay_us`；偏差来自循环开销、编译器调度与取指。
fn measureDelayJitter() Jitter {
    timg.start(.{ .divider = timg.dividerFor(1_000_000), .auto_reload = false });
    timg.setCounter(0);

    var min_dev: i32 = 1_000_000;
    var max_dev: i32 = -1_000_000;
    var sum_abs: u64 = 0;
    var last_interval: u32 = 0;

    var prev_end: u64 = 0;

    var i: u32 = 0;
    while (i < sample_count) : (i += 1) {
        const t0 = timg.counter();
        systimer.delayUs(soft_delay_us);
        const t1 = timg.counter();

        const elapsed: i32 = @intCast(t1 - t0);
        const dev: i32 = elapsed - @as(i32, @intCast(soft_delay_us));
        if (dev < min_dev) min_dev = dev;
        if (dev > max_dev) max_dev = dev;
        sum_abs += @intCast(if (dev < 0) -dev else dev);

        if (i != 0) {
            last_interval = @intCast(@as(i64, @intCast(t1)) - @as(i64, @intCast(prev_end)));
        }
        prev_end = t1;
    }

    timg.stop();

    return .{
        .min = min_dev,
        .max = max_dev,
        .mean_abs = @intCast(sum_abs / sample_count),
        .last_interval = last_interval,
        .samples = sample_count,
    };
}

// ---------------------------------------------------------------------------
// DMA 搬运 + 校验
// ---------------------------------------------------------------------------

/// 2048 字节 = 2 段 × 1024 字节：正好让描述符链真的有两条，
/// 这样 `report.chunks` 与 `rx_eof_desc` 才不是摆设。
const dma_len: usize = 2048;

var dma_src: [dma_len]u8 align(4) = undefined;
var dma_dst: [dma_len]u8 align(4) = undefined;

fn fillPattern() void {
    var i: usize = 0;
    while (i < dma_len) : (i += 1) {
        dma_src[i] = @truncate((i *% 7) +% 3);
    }
    i = 0;
    while (i < dma_len) : (i += 1) {
        dma_dst[i] = 0xA5;
    }
}

const DmaResult = struct {
    copied: bool,
    first_bad: usize,
    bad_count: usize,
    report: dma.Report,
};

/// 搬一次并逐字节比对。这段比对**故意**用 CPU 做：DMA 只负责搬，
/// 正确性由 CPU 独立验证，避免“用同一个引擎证明它自己搬对了”。
fn dmaRun() DmaResult {
    fillPattern();

    const report = dma.copy(dma_dst[0..dma_len], dma_src[0..dma_len]) catch |err| {
        _ = esp_rom_printf("dma: transfer failed (");
        switch (err) {
            error.Empty => _ = esp_rom_printf("empty"),
            error.TooLarge => _ = esp_rom_printf("too large"),
            error.Misaligned => _ = esp_rom_printf("misaligned"),
            error.DmaError => _ = esp_rom_printf("descriptor/bus error"),
            error.Timeout => _ = esp_rom_printf("timeout"),
        }
        _ = esp_rom_printf(")\n");
        return .{ .copied = false, .first_bad = 0, .bad_count = dma_len, .report = .{
            .in_raw = 0,
            .out_raw = 0,
            .rx_done_desc = 0,
            .tx_done_desc = 0,
            .rx_eof_desc = 0,
            .chunks = 0,
            .elapsed_ticks = 0,
        } };
    };

    var first_bad: usize = 0;
    var bad: usize = 0;
    var i: usize = 0;
    while (i < dma_len) : (i += 1) {
        if (dma_src[i] != dma_dst[i]) {
            if (bad == 0) first_bad = i;
            bad += 1;
        }
    }

    return .{
        .copied = bad == 0,
        .first_bad = first_bad,
        .bad_count = bad,
        .report = report,
    };
}

fn printDma(r: DmaResult) void {
    _ = esp_rom_printf("dma: chunks=%u ", @as(c_uint, r.report.chunks));
    if (r.copied) {
        _ = esp_rom_printf("verified\n");
    } else {
        _ = esp_rom_printf("MISMATCH first_bad=%u bad=%u\n", @as(c_uint, @intCast(r.first_bad)), @as(c_uint, @intCast(r.bad_count)));
    }

    _ = esp_rom_printf("  in_raw=0x");
    printHex32(r.report.in_raw);
    _ = esp_rom_printf(" out_raw=0x");
    printHex32(r.report.out_raw);
    _ = esp_rom_printf(" rx_done=0x");
    printHex32(r.report.rx_done_desc);
    _ = esp_rom_printf(" tx_done=0x");
    printHex32(r.report.tx_done_desc);
    _ = esp_rom_printf(line);

    // SYSTIMER 62.5 ns/tick → tick × 125 / 2 ns。
    const ns: u32 = @truncate((r.report.elapsed_ticks * 125) / 2);
    _ = esp_rom_printf("  transfer_ns=");
    printU32(ns);
    _ = esp_rom_printf(line);
}

fn printJitter(comptime name: [:0]const u8, j: Jitter) void {
    _ = esp_rom_printf("%s", name.ptr);
    _ = esp_rom_printf(": samples=%u min=", @as(c_uint, j.samples));
    printI32(j.min);
    _ = esp_rom_printf(" max=");
    printI32(j.max);
    _ = esp_rom_printf(" mean_abs=");
    printU32(j.mean_abs);
    _ = esp_rom_printf(" last_interval=");
    printU32(j.last_interval);
    _ = esp_rom_printf(" us");
    _ = esp_rom_printf(line);
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

pub export fn main() void {
    _ = esp_rom_printf("\n");
    _ = esp_rom_printf("ch08-timers-dma | form B (Zig ELF + IDF 2nd-stage bootloader)\n");
    _ = esp_rom_printf("console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)\n");

    // 三个外设各就各位：时间基准、硬件秒表、DMA 时钟。
    systimer.init();
    timg.init();
    dma.init();
    monitorInit();

    _ = esp_rom_printf("systimer: 16 MHz, boot_us=");
    printU32(systimer.us32());
    _ = esp_rom_printf("\n");

    // 1) 硬件定时器抖动
    const jt = measureTimerJitter();
    printJitter("timg.t0 1ms", jt);

    // 2) 软件延时抖动（同样用 1 µs 分辨率的 TIMG 读）
    const jd = measureDelayJitter();
    printJitter("delayUs(500)", jd);

    // 3) DMA 搬运 + CPU 校验
    var r = dmaRun();
    printDma(r);

    // 4) 心跳：每 500 ms 翻一次引脚、搬一次 512 字节。
    var round: u32 = 0;
    while (true) {
        systimer.delayUs(500_000);
        monitorToggle();
        round +%= 1;

        r = dmaRun();

        _ = esp_rom_printf("round ");
        printU32(round);
        _ = esp_rom_printf(": ");
        printU32(if (r.copied) @as(u32, 0) else @as(u32, @intCast(r.bad_count)));
        _ = esp_rom_printf(" bad, ");
        printU32(@truncate((r.report.elapsed_ticks * 125) / 2));
        _ = esp_rom_printf(" ns\n");
    }
}
