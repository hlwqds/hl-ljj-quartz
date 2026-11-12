//! ch04-linker-layout：形态 B 的最小应用。
//!
//! 与 ch02 的区别只在“谁调用它”：这里的 `main` 不是 IDF 的 `app_main`，
//! 而是 `_start` 用 `call main` 直接进入的普通函数。因此：
//!   - 符号名必须就是 `main`，所以用 `export`（`pub fn` 会被 Zig 改名为
//!     `main.main` 一类，汇编里的 `call main` 就找不到它）；
//!   - 按 C 调用约定进入，不能返回（返回后 _start 会停在 wfi 循环里）。
//!
//! 输出仍然只依赖掩膜 ROM：`esp_rom_printf` / `esp_rom_delay_us` 的地址由
//! linker/s31.ld 里的 PROVIDE 提供（0x2f800024 / 0x2f80003c），不链接任何
//! IDF 组件、不用 newlib、不用堆。

const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch04-linker-layout 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch04-linker-layout 需要 eabihf（硬浮点）ABI");
    }
}

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
extern fn esp_rom_delay_us(us: u32) void;

pub export fn main() void {
    _ = esp_rom_printf("hello form B\n");

    while (true) {
        esp_rom_delay_us(1_000_000);
        _ = esp_rom_printf("tick B\n");
    }
}
