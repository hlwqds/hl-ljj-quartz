//! ch13-heap-stack-caps：串口输出。
//!
//! 全部走 ROM 的 `esp_rom_printf`（0x2f800024，由链接脚本 PROVIDE）：
//! ROM 已按 115200 8N1 配好 UART0（GPIO58/59），本章不重配串口。
//!
//! 为什么不用 `esp_rom_printf` 的格式串直接打印、而是先 `std.fmt.bufPrint`：
//! ROM 格式化器不支持 Zig 的 `{x}`/`{d:>3}` 等全部语法，而且不可重入。
//! 在 Zig 侧格式化到栈上缓冲、只用 `%s` 输出，两个问题一起消失。

const std = @import("std");

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

/// 一行输出。格式串不需要自带换行；超长的行会被截断（不会越界）。
pub fn line(comptime fmt: []const u8, args: anytype) void {
    // 200 字节正文 + '\n' + 结尾 0。
    var buf: [202:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..200], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    const out: [:0]const u8 = buf[0 .. text.len + 1 :0];
    _ = esp_rom_printf("%s", out.ptr);
}

/// 只输出一段常量（编译期已知，零格式化开销）。
pub fn raw(comptime text: [:0]const u8) void {
    _ = esp_rom_printf("%s", text.ptr);
}
