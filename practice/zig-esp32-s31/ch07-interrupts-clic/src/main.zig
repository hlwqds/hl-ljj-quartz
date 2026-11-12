//! ch07-interrupts-clic：从轮询走到中断的最小应用。
//!
//! 主线的顺序就是“开机到中断打开”的顺序，每一步都留了可观测点：
//!
//!   1. 横幅（TX 走 ROM printf，UART0/GPIO58，115200 8N1）；
//!   2. 装 trap 向量（`mtvec` MODE=0，异常与中断共用）；
//!   3. 配 CLIC：阈值、路由、优先级、处理函数登记；
//!   4. 配外设侧中断源：SYSTIMER target0（1 kHz）与 UART0 RX（FULL + TOUT）；
//!   5. 清挂起，再开 `IE`，最后 `mstatus.MIE = 1`；
//!   6. 主循环只做“消费环形缓冲 + 打印 + 命令”，接收完全由 ISR 完成。
//!
//! 与 ch06 的差别只有一处，但它是质变：ch06 把“多久搬一次 FIFO”写进了主循环
//! 结构（1 ms 一片），本章把它交给了硬件——主循环可以睡 1 ms、10 ms 还是 1 s，
//! 接收都不再丢字节。代价是并发：`rx` 变成两个上下文共享的数据结构，
//! 于是有了 `critical.zig` 与 `fence`。
//!
//! 「待真机验证」：全部硬件行为。本仓没有在 S31 上运行过本工程。

const clic = @import("clic.zig");
const isr = @import("isr.zig");
const critical = @import("critical.zig");

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

// ---------------------------------------------------------------------------
// 串口输出（TX 侧）：全部经过掩膜 ROM 的 printf
// ---------------------------------------------------------------------------

/// ROM 版 printf：链接脚本 `PROVIDE(esp_rom_printf = 0x2f800024)`。
/// 它是阻塞式的（TX FIFO 满时等待），所以在 ISR 里绝不能调用。
pub fn puts(s: [*:0]const u8) void {
    _ = esp_rom_printf("%s", s);
}

pub fn putc(c: u8) void {
    _ = esp_rom_printf("%c", @as(c_int, c));
}

pub fn putHex32(label: [*:0]const u8, v: u32) void {
    puts(label);
    puts("=0x");
    var shift: u5 = 28;
    while (true) {
        const nibble: u8 = @intCast((v >> shift) & 0xF);
        putc(if (nibble < 10) '0' + nibble else 'a' + (nibble - 10));
        if (shift == 0) break;
        shift -= 4;
    }
}

pub fn putDec32(label: [*:0]const u8, v: u32) void {
    puts(label);
    putc('=');
    if (v == 0) {
        putc('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x != 0) {
        buf[n] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
        n += 1;
    }
    while (n != 0) {
        n -= 1;
        putc(buf[n]);
    }
}

fn logMsg(tag: u8, text: [*:0]const u8) void {
    putc('[');
    putc(tag);
    puts("] ");
    puts(text);
    putc('\n');
}

fn logHex(tag: u8, label: [*:0]const u8, v: anytype) void {
    const x: u32 = @intCast(v);
    putc('[');
    putc(tag);
    puts("] ");
    putHex32(label, x);
    putc('\n');
}

fn logDec(tag: u8, label: [*:0]const u8, v: anytype) void {
    const x: u32 = @intCast(v);
    putc('[');
    putc(tag);
    puts("] ");
    putDec32(label, x);
    putc('\n');
}

// ---------------------------------------------------------------------------
// SYSTIMER：时间基准（16 MHz，1 tick = 62.5 ns）与 1 kHz 的 tick 源
// ---------------------------------------------------------------------------

const systimer_base: usize = 0x2039_9000;

const st_conf: usize = systimer_base + 0x00;
const st_unit0_op: usize = systimer_base + 0x04;
const st_target0_hi: usize = systimer_base + 0x1c;
const st_target0_lo: usize = systimer_base + 0x20;
const st_target0_conf: usize = systimer_base + 0x34;
const st_unit0_value_hi: usize = systimer_base + 0x40;
const st_unit0_value_lo: usize = systimer_base + 0x44;
const st_int_ena: usize = systimer_base + 0x64;
const st_int_clr: usize = systimer_base + 0x6c;

/// CONF：CLK_EN bit31、TIMER_UNIT0_WORK_EN bit30（复位值 1）、TARGET0_WORK_EN bit24。
/// 位号来自 IDF v6.1 `systimer_reg.h`（`SYSTIMER_CONF_REG` 段）。
const st_conf_clk_en: u32 = 1 << 31;
const st_conf_unit0_en: u32 = 1 << 30;
const st_conf_target0_en: u32 = 1 << 24;

/// UNIT0_OP：UPDATE bit30（写 1 请求快照）、VALID bit29（快照有效）。
const st_op_update: u32 = 1 << 30;
const st_op_valid: u32 = 1 << 29;

/// 计数节拍：XTAL 40 MHz 经固定 2.5 分频 = 16 MHz。
const ticks_per_us: u32 = 16;
/// 1 kHz 的周期：1 ms = 16000 tick。
const tick_period: u32 = 1_000 * ticks_per_us;

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

/// HP_SYS_CLKRST 的 SYSTIMER_CTRL0（+0x120）：bit0 APB 时钟、bit4 计数器时钟。
/// 真机发现（2026-11-12）：两位复位值都是 0；不先开，计数值恒为 0 / VALID 永不置位。
const clkrst_systimer_ctrl0: usize = 0x2058_7000 + 0x120;

fn systimerInit() void {
    const gate: *volatile u32 = @ptrFromInt(clkrst_systimer_ctrl0);
    gate.* = gate.* | (1 << 0) | (1 << 4);
    const p = reg(st_conf);
    p.* = p.* | st_conf_clk_en | st_conf_unit0_en;
}

/// 读 64 位计数：请求快照 → 等 valid → 读 LO/HI/LO 防撕裂（ch05 的做法）。
fn systimerTicks() u64 {
    // 快照路径要等 VALID；给上限，避免 SYSTIMER 未就绪时死循环。
    reg(st_unit0_op).* = st_op_update;
    var spins: u32 = 0;
    while ((reg(st_unit0_op).* & st_op_valid) == 0) : (spins += 1) {
        if (spins > 10_000) break;
    }
    const hi = reg(st_unit0_value_hi).* & 0x000F_FFFF;
    const lo = reg(st_unit0_value_lo).*;
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

fn systimerUs() u32 {
    return @truncate(systimerTicks() / ticks_per_us);
}

fn delayUs(us: u32) void {
    const delta: u64 = @as(u64, us) * ticks_per_us;
    const start = systimerTicks();
    while (systimerTicks() - start < delta) {}
}

// ---------------------------------------------------------------------------
// GPIO：只为一个观测点（示波器上看 tick）
// ---------------------------------------------------------------------------

const gpio_base: usize = 0x2058_3000;
const io_mux_base: usize = 0x2058_2000;

const gpio_out: usize = gpio_base + 0x04;
const gpio_out_w1ts: usize = gpio_base + 0x08;
const gpio_out_w1tc: usize = gpio_base + 0x0c;
const gpio_enable_w1ts: usize = gpio_base + 0x38;
const gpio_func_out_sel_base: usize = gpio_base + 0xaf4;

const fun_ie: u32 = 1 << 9;
const mcu_sel_gpio: u32 = 1 << 12;
const sig_gpio_out_idx: u32 = 256;

/// 演示引脚。选 GPIO5 的理由与 ch06 相同：IO_MUX 偏移 `0x14`，不涉及
/// USB/ADC/XTAL32K/strapping。板上是否有别的器件挂在它上面，**以原理图为准**。
const demo_pin: u5 = 5;
const demo_mask: u32 = @as(u32, 1) << demo_pin;

fn gpioInit() void {
    const mux = io_mux_base + @as(usize, demo_pin) * 4;
    reg(mux).* = (reg(mux).* & ~@as(u32, 0x7 << 12)) | mcu_sel_gpio | fun_ie;
    reg(gpio_func_out_sel_base + @as(usize, demo_pin) * 4).* = sig_gpio_out_idx;
    reg(gpio_out_w1tc).* = demo_mask;
    reg(gpio_enable_w1ts).* = demo_mask;
}

inline fn gpioToggle() void {
    if ((reg(gpio_out).* & demo_mask) != 0) {
        reg(gpio_out_w1tc).* = demo_mask;
    } else {
        reg(gpio_out_w1ts).* = demo_mask;
    }
}

// ---------------------------------------------------------------------------
// 中断处理函数（登记进 isr 的分发表）
// ---------------------------------------------------------------------------

/// CLIC 通道号：0 → SYSTIMER tick，1 → UART0 RX，3 → 软件中断（IPI 预览）。
/// 通道是“外部中断号 0..31”，CLIC 输入号 = 通道 + 16。
const tick_channel: u6 = 0;
const uart_channel: u6 = 1;
const soft_channel: u6 = 3;

var tick_id: clic.Input = clic.ext_int_offset;
var uart_id: clic.Input = clic.ext_int_offset + 1;
var soft_id: clic.Input = clic.ext_int_offset + 3;

/// 1 kHz tick 计数。主循环用 volatile 读，ISR 直接自增。
var tick_count: u32 = 0;
/// 最近一次 tick 的 SYSTIMER 微秒值：主循环用它算“距上次 tick 多久”。
var tick_us: u32 = 0;
/// 软件中断次数。
var soft_count: u32 = 0;

inline fn loadShared(p: *const u32) u32 {
    const vp: *const volatile u32 = @ptrFromInt(@intFromPtr(p));
    return vp.*;
}

/// SYSTIMER target0 的 ISR：清标志、计数、翻引脚、记时间戳。
///
/// 四件事都很便宜：一次 `INT_CLR` 写、一次自增、一次 GPIO 写、一次 4 次 MMIO 的
/// 时间戳。没有打印、没有等待、没有循环——ISR 的预算按“微秒”算，不按“行”算。
fn tickIsr() void {
    reg(st_int_clr).* = 1; // TARGET0_INT_CLR，写 1 清除
    tick_count +%= 1;
    tick_us = systimerUs();
    gpioToggle();
}

/// 软件中断 ISR：`clic.raise()` 置 IP 后进来，清 IP 再返回。
fn softIsr() void {
    clic.clearPending(soft_id);
    soft_count +%= 1;
}

// ---------------------------------------------------------------------------
// 中断初始化：顺序就是设计
// ---------------------------------------------------------------------------

fn setupInterrupts() void {
    // ---- 1) 阈值 0：优先级 0..7 全部不屏蔽 ----
    clic.setThreshold(0);

    // ---- 2) 中断矩阵：外设源 → CPU 通道 → CLIC 输入 ----
    tick_id = clic.route(.systimer_target0, tick_channel);
    uart_id = clic.route(.uart0, uart_channel);
    // 软件中断不经过矩阵：它的“源”就是 CPU 自己，直接置输入的 IP 位。
    soft_id = soft_channel + clic.ext_int_offset;

    // ---- 3) 登记处理函数（分发表） ----
    _ = isr.attach(tick_id, &tickIsr);
    _ = isr.attachUart0(uart_id);
    _ = isr.attach(soft_id, &softIsr);

    // ---- 4) 装 mtvec：MODE=0 直接模式，异常与中断共用 trapVector ----
    clic.installDirect(@intFromPtr(&isr.trapVector)) catch {
        logMsg('E', "mtvec 基址未 4 字节对齐（检查 .text.entry 的放置）");
        isr.halt();
    };

    // ---- 5) 外设侧：先让源能产生中断，但此时 IE 还没开 ----
    uartSetupRx();
    systimerArm();

    // ---- 6) 清掉配置过程中可能已经积起来的挂起 ----
    reg(uart0_int_clr).* = isr.rx_int_bits;
    reg(st_int_clr).* = 1;
    clic.clearPending(tick_id);
    clic.clearPending(uart_id);
    clic.clearPending(soft_id);

    // ---- 7) 优先级 + IE：UART 比 tick 高一级 ----
    //
    // 为什么 UART 更高：tick 丢一次只是计数少 1，接收丢字节则整条命令消失。
    // 优先级只在“同时挂起”时决定谁先跑；S31 的输入是电平/边沿中断，
    // 低优先级的那个不会消失，只是晚一点。
    clic.setPriority(uart_id, 2);
    clic.enableInput(uart_id);
    clic.setPriority(tick_id, 3);
    clic.enableInput(tick_id);
    clic.setPriority(soft_id, 1);
    clic.enableInput(soft_id);

    // ---- 8) 最后一步：开 mstatus.MIE ----
    // 放在最后是因为前七步里任何一步出错，都还没有中断能打断初始化。
    critical.enable();
}

// ---------------------------------------------------------------------------
// UART0 RX 侧（TX 侧只有 ROM printf）
// ---------------------------------------------------------------------------

const uart0_base: usize = 0x2038_A000;
const uart0_conf1: usize = uart0_base + 0x24;
const uart0_int_ena: usize = uart0_base + 0x0c;
const uart0_int_clr: usize = uart0_base + 0x10;

/// 配 UART0 的接收中断。
///
/// `RXFIFO_FULL_THRHD`（CONF1[7:0]，复位值 96）改成 1：复位值意味着“攒够 96 字节
/// 才打扰 CPU”，交互式打字会一直没反应；改成 1 后每个字节都可能进中断，
/// 代价是中断次数上升。`RXFIFO_TOUT`（超时）负责“最后一个字节之后线上静默”，
/// 它的阈值字段不动，用复位值。
///
/// 只改 CONF1 的低 8 位：这个寄存器里还有流控与 TOUT 阈值，整写会碰掉它们。
fn uartSetupRx() void {
    const p = reg(uart0_conf1);
    p.* = (p.* & ~@as(u32, 0xFF)) | 1;
    reg(uart0_int_ena).* = reg(uart0_int_ena).* | isr.rx_int_bits;
}

/// 把 SYSTIMER target0 配成 1 kHz 周期闹钟。
///
/// `TARGET0_CONF`（+0x34）：PERIOD[25:0]、PERIOD_MODE bit30（1 = 周期模式，
/// 命中后硬件自动把 target 加 period）、TIMER_UNIT_SEL bit31（0 = unit0）。
/// 首次 target = 当前计数 + period；写 HI 再写 LO（LO 是最后落地的那个）。
fn systimerArm() void {
    const p = reg(st_conf);
    p.* = p.* | st_conf_target0_en;

    reg(st_target0_conf).* = (tick_period & 0x03FF_FFFF) | (1 << 30);

    const target = systimerTicks() + tick_period;
    reg(st_target0_hi).* = @truncate(target >> 32);
    reg(st_target0_lo).* = @truncate(target);

    reg(st_int_clr).* = 1;
    reg(st_int_ena).* = reg(st_int_ena).* | 1;
}

// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

fn printHelp() void {
    logMsg('I', "?  help / p  counters / c  critical test / s  software irq / t  trap demo");
}

fn printCounters() void {
    logDec('I', "ticks", loadShared(&tick_count));
    logDec('I', "tick age us", systimerUs() -% loadShared(&tick_us));
    logDec('I', "soft irq", loadShared(&soft_count));
    logDec('I', "irq total", isr.totalIrqs());
    logDec('I', "irq unhandled", isr.unhandledCount());
    logHex('I', "last unhandled id", isr.lastUnhandledId());
    logDec('I', "rx bytes", isr.rxBytesSeen());
    logDec('I', "rx queued", isr.rx.len());
    logDec('I', "rx drops", isr.rx.dropped());
    logHex('I', "mstatus", critical.mstatus());
    logDec('I', "clic threshold", critical.level());
    logHex('I', "intr map uart0", clic.mapValue(.uart0, 0));
    logHex('I', "intr map systimer", clic.mapValue(.systimer_target0, 0));
    logHex('I', "mtvec", clic.mtvec());
    logDec('I', "uart input id", uart_id);
    logDec('I', "tick input id", tick_id);
}

/// 临界区测试：关中断 5 ms，看 tick 有没有被“吞掉”。
///
/// 期望的形态（待真机验证）：
///   - `masked ticks` 为 0：关中断期间 ISR 一次都没跑；
///   - 退出后 `catch-up` 约等于 1：CLIC 的 IP 只有一位，5 次命中被合并成 1 次挂起；
///   - 因此“关中断会丢 tick”不是猜测，而是可数的：`lost ≈ window_ms - 1`。
///
/// 这也是为什么实时内核的临界区要按“微秒”而不是“毫秒”来写。
fn criticalTest() void {
    const before = loadShared(&tick_count);
    const saved = critical.enter();
    const t_start = systimerUs();
    delayUs(5_000);
    const t_end = systimerUs();
    const masked = loadShared(&tick_count);
    critical.exit(saved);

    delayUs(2_000);
    const after = loadShared(&tick_count);

    logMsg('I', "critical: MIE 关了 5 ms（待真机验证）");
    logDec('I', "masked window us", t_end - t_start);
    logDec('I', "masked ticks", masked -% before);
    logDec('I', "catch-up ticks", after -% masked);
}

/// 嵌套的保存/恢复：进两次、出两次，检查 `MIE` 回来了没有。
fn nestedTest() void {
    const outer = critical.enter();
    const inner = critical.enter();
    const in_crit = !critical.enabled();
    critical.exit(inner);
    const still_off = !critical.enabled();
    critical.exit(outer);
    const restored = critical.enabled();

    logMsg('I', "nested: enter/enter/exit/exit");
    logDec('I', "in critical", @intFromBool(in_crit));
    logDec('I', "still masked after inner exit", @intFromBool(still_off));
    logDec('I', "MIE restored", @intFromBool(restored));
}

/// 阈值版临界区：把阈值抬到 7，等价于“屏蔽全部优先级”，但 `MIE` 仍是 1。
/// 与 `enter()` 的区别在于高优先级中断仍可放行（本章未配置更高优先级，
/// 所以这里观测不到差别；接口先立住）。
fn thresholdTest() void {
    const old = critical.enterLevel(7);
    const before = loadShared(&tick_count);
    delayUs(2_000);
    const after = loadShared(&tick_count);
    critical.exitLevel(old);

    logDec('I', "threshold 7 ticks", after -% before);
    logDec('I', "threshold restored to", critical.level());
}

// ---------------------------------------------------------------------------
// 应用入口
// ---------------------------------------------------------------------------

pub export fn main() void {
    _ = esp_rom_printf("\n");
    logMsg('I', "ch07-interrupts-clic | form B (Zig ELF + IDF 2nd-stage bootloader)");
    logMsg('I', "console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)");

    systimerInit();
    gpioInit();
    logDec('I', "demo gpio", @as(u32, demo_pin));

    // CLIC 能力自述：这三个数就是“48 路 / 8 级 / 版本”的第一手证据。
    logDec('I', "clic inputs", clic.inputCount());
    logDec('I', "clic priority bits (raw)", clic.priorityBitsRaw());
    logHex('I', "clic version (raw)", clic.versionRaw());
    logDec('I', "clic hw vector", @intFromBool(clic.hasHardwareVector()));

    setupInterrupts();

    logHex('I', "mtvec", clic.mtvec());
    logDec('I', "uart input id", uart_id);
    logDec('I', "tick input id", tick_id);
    logDec('I', "soft input id", soft_id);
    logMsg('I', "interrupts on: 1 kHz systimer tick + UART0 rx (polling removed)");
    printHelp();

    // 1 ms 一片：这个节奏现在只影响“命令响应”，不再影响“会不会丢字节”。
    const slice_us: u32 = 1_000;
    var slices: u32 = 0;
    var last_second_ticks: u32 = loadShared(&tick_count);

    while (true) {
        delayUs(slice_us);
        handleInput();

        slices += 1;
        if (slices >= 1000) {
            slices = 0;
            const now_ticks = loadShared(&tick_count);
            logDec('I', "ticks/s", now_ticks -% last_second_ticks);
            last_second_ticks = now_ticks;
        }
    }
}

fn handleInput() void {
    while (isr.rx.pop()) |b| {
        switch (b) {
            '\r', '\n' => putc('\n'),
            '?' => printHelp(),
            'p' => printCounters(),
            'c' => {
                criticalTest();
                nestedTest();
                thresholdTest();
            },
            's' => {
                clic.raise(soft_id);
                logDec('I', "raised software irq", soft_id);
            },
            't' => {
                logMsg('W', "trap demo: 执行全零指令，板子会停机，需复位");
                // RISC-V 规定全零指令永久保留为非法指令 → mcause=2。
                asm volatile (".4byte 0x00000000");
                isr.halt();
            },
            else => putc(b),
        }
    }
}

comptime {
    // `_start` 用字符串 `call main` 引用本函数；这里再显式取一次地址，
    // 保证它一定被发射（与 ch04/ch06 同款保险）。
    _ = &main;
}
