//! ch14-dual-core-smp-ipi：两个核共用一条 UART，所以打印必须串行化。
//!
//! ESP32-S31 的 ROM 已经把 UART0（GPIO58 TX / GPIO59 RX，115200 8N1）配好，
//! 应用侧直接用 `esp_rom_printf`。问题是它**不可重入**：两个核同时往里写，
//! 字符会在 FIFO 里交错，行被撕成两半。
//!
//! 本章的做法是一把最朴素的自旋锁（`@cmpxchgWeak`，A 扩展），并且刻意
//! 遵守一条规则：**中断处理程序永不打印**。否则同一核上会出现
//! “任务持锁 → tick 中断 → ISR 打印 → 等同一把锁”的自死锁。
//! 跨核的等待是安全的：持有者一定在跑（没有阻塞调用），会很快释放。
//!
//! 这也是为什么本章所有观测值都是先写进 PerCpu 的计数器、最后只在
//! supervisor 里打印一次：串口不是并发安全的观测设备。

const std = @import("std");

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;

var lock: u32 = 0;

fn acquire() void {
    // 成功返回 null；失败返回当时看到的值。
    while (@cmpxchgWeak(u32, &lock, 0, 1, .acquire, .monotonic) != null) {}
}

fn release() void {
    @atomicStore(u32, &lock, 0, .release);
}

/// 一行输出。格式串不需要自带换行。
pub fn line(comptime fmt: []const u8, args: anytype) void {
    // 222 字节正文 + '\n' + 结尾 0：bufPrint 的空间必须留出后两个字节。
    var buf: [224:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..222], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    const out: [:0]const u8 = buf[0 .. text.len + 1 :0];

    acquire();
    _ = esp_rom_printf("%s", out.ptr);
    release();
}

/// 不走锁的原始输出，只给“锁本身可能已经坏了”的路径用（trap 早期）。
pub fn raw(comptime fmt: []const u8, args: anytype) void {
    var buf: [224:0]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0..222], fmt, args) catch return;
    buf[text.len] = '\n';
    buf[text.len + 1] = 0;
    _ = esp_rom_printf("%s", buf[0..text.len + 1 :0].ptr);
}
