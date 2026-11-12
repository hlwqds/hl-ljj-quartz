//! ch06-gpio-uart-log：GPIO + UART + 日志 + panic 的最小应用。
//!
//! 主循环做的事情按优先级排列，每一件都对应章节里的一个可观测点：
//!
//!   1. 启动横幅：证明 ROM printf 的 TX 链路通（GPIO58，115200 8N1）；
//!   2. 装 trap 向量：让后续的非法指令/访问错误有地方可去（panic.zig）；
//!   3. 配一个演示引脚为输出并翻转：证明 IO_MUX + GPIO 的最小组合能工作；
//!   4. 轮询 UART RX → 环形缓冲 → 回显：证明接收链路，并且**不打开中断**；
//!   5. 极简单字符命令：`?` 帮助、`p` 打印计数、`t` 触发一次 trap 演示。
//!
//! 为什么主循环不是“睡 1 秒再翻转”：
//! 115200 下 1 ms 大约来 11.5 个字节，而 UART 的硬件 FIFO 深度是有限的
//! （S31 的具体深度以 TRM 的 UART 章节为准）。如果一次 `esp_rom_delay_us`
//! 睡满 500 ms，期间没人搬 FIFO，接收必然溢出。所以这里的节奏是
//! “1 ms 一片”：每片搬一次 FIFO、处理命令，攒够次数再翻一次引脚。
//! 这正是“轮询版驱动”与“中断版驱动”的差别所在：前者把采样频率写进了
//! 主循环结构，后者由硬件在数据到达时打断 CPU。

const gpio = @import("gpio.zig");
const uart = @import("uart.zig");
const log = @import("log.zig");
const panic = @import("panic.zig");

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
extern fn esp_rom_delay_us(us: u32) void;

/// 演示引脚。**必须按板卡原理图核对**：本仓没有收录
/// ESP32-S31-Function-CoreBoard-1 的 J2 针脚定义，这里选 GPIO5 只是因为它
/// 在 IO_MUX 表里是普通的 `U_GPIO5`（偏移 0x14），不涉及 USB/ADC/strapping。
/// 该引脚在 J2 上的实际排针位置、以及板上是否有其它器件挂在它上面，
/// 属于「待真机验证」事项；换引脚只需要改这一个常量。
pub const demo_pin: gpio.Pin = 5;

/// 一轮“翻转节奏”：每 500 片 × 1 ms = 500 ms 翻一次，1 Hz 方波。
const slices_per_toggle: u32 = 500;
const slice_us: u32 = 1_000;

/// 心跳：每 4 次翻转（约 2 秒）打一行。
const toggles_per_heartbeat: u32 = 4;

var rx_ring: uart.RingBuffer = .{};

pub export fn main() void {
    // 1) 横幅。ROM 已经把 UART0 配成 115200 8N1；这里不做任何 UART 初始化。
    _ = esp_rom_printf("\n");
    log.msg(.info, "ch06-gpio-uart-log | form B (Zig ELF + IDF 2nd-stage bootloader)");
    log.msg(.info, "console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)");

    // 2) 装 trap 向量。必须在任何可能触发异常的代码之前。
    panic.install();
    log.hex(.info, "mtvec", @intCast(@intFromPtr(&panic.trapVector)));

    // 3) 演示引脚：先配成输出（低电平），并在启动时读回一次。
    gpio.configureOutput(demo_pin);
    log.dec(.info, "demo gpio", @as(u32, demo_pin));
    log.msg(.info, "gpio: IO_MUX MCU_SEL=1 + OUT_SEL=256 + ENABLE=1（待真机验证）");
    log.dec(.debug, "gpio level after config", @intFromBool(gpio.get(demo_pin)));

    // 4) 打印帮助，然后进主循环。
    log.msg(.info, "type ? for help; input is polled, not interrupt driven");
    printHelp();

    var slices: u32 = 0;
    var toggles: u32 = 0;

    while (true) {
        // 一片 = 1 ms 的延时 + 一次 FIFO 搬运 + 一次命令处理。
        esp_rom_delay_us(slice_us);
        _ = rx_ring.drainFromFifo();
        handleInput();

        slices += 1;
        if (slices >= slices_per_toggle) {
            slices = 0;
            gpio.toggle(demo_pin);
            toggles +%= 1;

            if (toggles % toggles_per_heartbeat == 0) {
                log.dec2(.info, "toggles", toggles, "rx drops", rx_ring.drops);
                if (uart.sawFrameError()) {
                    log.msg(.warn, "uart: INT_RAW 里 FRM_ERR 仍置位（波特率/接线/干扰）");
                }
            }
        }
    }
}

/// 从环形缓冲取字节并回显。
///
/// 回显是本章最省事的“双向链路”证明：你在串口终端敲一个字符，它立刻被
/// 打回来。回显用的是同一个 `uart.putc`（ROM printf），所以 TX 与 RX 两条
/// 路径都被这段代码覆盖到了。
fn handleInput() void {
    while (rx_ring.pop()) |b| {
        switch (b) {
            '\r', '\n' => {
                uart.puts("\r\n");
            },
            '?' => {
                uart.putc('\r');
                printHelp();
            },
            'p' => {
                uart.puts("\r\n");
                log.dec(.info, "rx queued", rx_ring.len());
                log.dec(.info, "rx drops", rx_ring.drops);
                log.dec(.info, "tx fifo", @as(u32, uart.txFifoCount()));
                log.dec(.info, "rx fifo", @as(u32, uart.rxFifoCount()));
            },
            't' => {
                uart.puts("\r\n");
                // 显式、可预期、且**会停机**：文档里写清楚了才允许存在。
                panic.trapDemo();
            },
            else => uart.putc(b),
        }
    }
}

fn printHelp() void {
    log.msg(.info, "?  help / p  counters / t  trap demo (halts until reset)");
}
