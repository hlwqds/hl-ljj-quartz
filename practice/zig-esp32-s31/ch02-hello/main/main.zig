//! ch02：形态 A 的最小应用。
//!
//! - `app_main` 由 IDF 的启动代码调用，必须按 C ABI 导出；
//! - 输出走 ROM 的 `esp_rom_printf`，不依赖 IDF 的 UART 驱动与 VFS；
//! - 延时走 ROM 的 `esp_rom_delay_us`，是忙等，只为让输出可读。
//!
//! 本章不碰板载 RGB LED：它是可寻址灯珠，需要 RMT 时序，留到 ch06。

const builtin = @import("builtin");

comptime {
    // 目标错了就立刻失败，而不是产出一个“能编译但不能跑”的库。
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch02-hello 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch02-hello 需要 eabihf（硬浮点）ABI");
    }
}

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
extern fn esp_rom_delay_us(us: u32) void;

export fn app_main() void {
    _ = esp_rom_printf("hello s31\n");

    while (true) {
        esp_rom_delay_us(1_000_000);
        _ = esp_rom_printf("tick\n");
    }
}
