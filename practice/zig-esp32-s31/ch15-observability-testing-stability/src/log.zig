//! ch15-observability-testing-stability：串口输出。
//!
//! 全部走 ROM 的 `esp_rom_printf`（0x2f800024，由链接脚本 PROVIDE）：
//! ROM 已按 115200 8N1 配好 UART0（GPIO58/59），本章不重配串口。
//!
//! 先 `std.fmt.bufPrint` 再 `%s` 输出，而不是把格式串交给 ROM：
//!   - ROM 的格式化器不认识 Zig 的 `{x}`/`{d:>3}` 等语法；
//!   - ROM 的 printf 不可重入，而本章的 panic dump 会从 trap 上下文里调用它。
//!
//! 本章不做行缓冲与异步日志：所有输出都在当前栈上格式化，一次 `%s` 写完。
//! 这条约束换来的是“panic 时也能打印”——日志系统自己不能成为崩溃点。

const std = @import("std");

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

/// 一行输出。格式串不需要自带换行；超长（>200 字节）的行会被截断，不越界。
pub fn line(comptime fmt: []const u8, args: anytype) void {
    // 200 字节正文 + '\n' + 结尾 0。
    var buf: [202:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..200], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    const out: [:0]const u8 = buf[0 .. text.len + 1 :0];
    _ = esp_rom_printf("%s", out.ptr);
}

/// 只输出一段编译期常量（零格式化开销）。
pub fn raw(comptime text: [:0]const u8) void {
    _ = esp_rom_printf("%s", text.ptr);
}
