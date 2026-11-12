//! ch06-gpio-uart-log：分级日志。
//!
//! 这一层的全部职责是“一行日志 = 级别标记 + 正文 + 换行”，并且**在编译期**
//! 决定要不要发射正文。它不是 std.log 的封装：std.log 的输出端（writer）在
//! freestanding 上是空的，而且它的格式化会把一大坨 std.fmt 拉进镜像。
//!
//! 级别语义（与 IDF 的 esp_log 同级概念）：
//!   - `err`   程序无法继续：必须人工介入；
//!   - `warn`  还能跑，但状态可疑（例如串口收到帧错误）；
//!   - `info`  正常生命周期的里程碑（启动、配置完成、心跳）；
//!   - `debug` 排错时才打开的过程信息。
//!
//! `level` 是运行期变量，`msg` 之类函数的正文是编译期字符串：
//! 编译器仍然会为每个调用点生成一份字符串常量，但省掉了运行期的格式解析。

const uart = @import("uart.zig");

pub const Level = enum(u8) {
    /// 全部关闭（连 err 也不打印）。只在“绝对不能让串口拖慢时序”时用。
    off = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,
};

/// 当前级别。默认 `info`：正常运行时不必看 debug 的噪声。
pub var level: Level = .info;

/// 该级别的日志此刻会不会输出。`off` 时任何级别都不输出。
pub fn enabled(l: Level) bool {
    if (level == .off) return false;
    return @intFromEnum(l) <= @intFromEnum(level);
}

fn tag(l: Level) u8 {
    return switch (l) {
        .off => ' ',
        .err => 'E',
        .warn => 'W',
        .info => 'I',
        .debug => 'D',
    };
}

fn prefix(l: Level) void {
    uart.putc('[');
    uart.putc(tag(l));
    uart.putc(']');
    uart.putc(' ');
}

/// 一行纯文本日志。`text` 是编译期字符串（必须以 `\x00` 结尾才能直接交给 ROM printf）。
pub fn msg(comptime l: Level, comptime text: [:0]const u8) void {
    if (!enabled(l)) return;
    prefix(l);
    uart.puts(text);
    uart.putc('\n');
}

/// 一行带一个十进制字段的日志：`label=123`。
pub fn dec(comptime l: Level, comptime label: [:0]const u8, v: u32) void {
    if (!enabled(l)) return;
    prefix(l);
    uart.putDec32(label, v);
    uart.putc('\n');
}

/// 一行带一个十六进制字段的日志：`label=0x0000abcd`。
pub fn hex(comptime l: Level, comptime label: [:0]const u8, v: u32) void {
    if (!enabled(l)) return;
    prefix(l);
    uart.putHex32(label, v);
    uart.putc('\n');
}

/// 一行“两个十进制字段”的日志，心跳行用：`label1=.. label2=..`。
pub fn dec2(
    comptime l: Level,
    comptime label1: [:0]const u8,
    v1: u32,
    comptime label2: [:0]const u8,
    v2: u32,
) void {
    if (!enabled(l)) return;
    prefix(l);
    uart.putDec32(label1, v1);
    uart.putc(' ');
    uart.putDec32(label2, v2);
    uart.putc('\n');
}
