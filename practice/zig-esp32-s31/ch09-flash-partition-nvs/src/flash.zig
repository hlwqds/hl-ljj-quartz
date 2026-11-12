//! ch09-flash-partition-nvs：SPI flash 的最小封装（只依赖掩膜 ROM）。
//!
//! 三个函数来自 ROM，地址由 linker/s31.ld 的 PROVIDE 提供：
//!   esp_rom_spiflash_read         = 0x2f80016c
//!   esp_rom_spiflash_write        = 0x2f800168
//!   esp_rom_spiflash_erase_sector = 0x2f800160
//! 出处：IDF v6.1 `components/esp_rom/esp32s31/ld/esp32s31.rom.ld`。
//! 签名出处：同上版本的 `esp_rom_spiflash.h`。
//!
//! 本模块只做四件事：
//!   1) 把“偏移”而不是“XIP 地址”作为唯一参数；
//!   2) 在调用前检查 4 字节对齐、长度、边界；
//!   3) 把返回值 0 翻译成 `void`，非 0 翻译成错误；
//!   4) 用一个很短的临界窗口（清 mstatus.MIE）包住写/擦。
//!
//! 关于 cache：本工程所有段都在 SRAM（linker/s31.ld），写/擦期间 CPU 不从
//! flash 取指，所以不需要显式挂起 cache。**这是布局带来的前提，不是通用
//! 结论**：一旦 .text 回到 flash，必须在 write/erase 前后补 cache 挂起/恢复，
//! 否则会在 ROM 例程返回后随机取指失败（待真机验证）。
//!
//! 关于对齐：ROM 的原型是 `uint32_t *`，长度按字节计。所以缓冲必须是
//! `[]u32` 且 4 字节对齐，长度天然是 4 的倍数。用 `[]u8` 调用在 C 侧就是
//! 未对齐访问。

const std = @import("std");

/// 擦除单位：4 KiB。
pub const sector_size: u32 = 0x1000;

/// 模组 ESP32-S31-WROOM-3（N16R16V）的 flash 容量，仅用于边界检查。
pub const flash_size: u32 = 16 * 1024 * 1024;

extern fn esp_rom_spiflash_read(src_address: u32, dst_data: [*]u32, len_bytes: u32) c_int;
extern fn esp_rom_spiflash_write(target_address: u32, src_data: [*]const u32, len_bytes: u32) c_int;
extern fn esp_rom_spiflash_erase_sector(sector_number: u32) c_int;

pub const Error = error{
    UnalignedOffset,
    UnalignedLength,
    OutOfRange,
    ReadFailed,
    WriteFailed,
    EraseFailed,
    VerifyFailed,
};

/// 短临界窗口：写/擦期间不允许中断插进来。
///
/// 这里只动 mstatus.MIE，不碰 mie：恢复时也只把 MIE 还原成进入前的值，
/// 因此不会“顺手”打开某个中断源。CSR 操作用 csrrci/csrsi 的立即数形式，
/// 不依赖任何寄存器分配。
const Critical = struct {
    saved: u32,

    fn begin() Critical {
        var old: u32 = undefined;
        asm volatile ("csrrci %[old], mstatus, 8" : [old] "=r" (old));
        return .{ .saved = old };
    }

    fn end(self: Critical) void {
        if ((self.saved & 0x8) != 0) {
            asm volatile ("csrsi mstatus, 8");
        }
    }
};

fn check(offset: u32, len: u32) Error!void {
    if (offset % 4 != 0) return Error.UnalignedOffset;
    if (len % 4 != 0) return Error.UnalignedLength;
    const end = @as(u64, offset) + @as(u64, len);
    if (end > flash_size) return Error.OutOfRange;
}

/// 读 `dst.len * 4` 字节到 `dst`。`dst` 必须 4 字节对齐。
pub fn read(offset: u32, dst: []u32) Error!void {
    try check(offset, @intCast(dst.len * 4));
    if (esp_rom_spiflash_read(offset, dst.ptr, @intCast(dst.len * 4)) != 0) {
        return Error.ReadFailed;
    }
}

/// 写 `src.len * 4` 字节。目标区域必须已经擦过（全 0xFF）。
pub fn write(offset: u32, src: []const u32) Error!void {
    try check(offset, @intCast(src.len * 4));
    const guard = Critical.begin();
    defer guard.end();
    if (esp_rom_spiflash_write(offset, src.ptr, @intCast(src.len * 4)) != 0) {
        return Error.WriteFailed;
    }
}

/// 擦除包含 `offset` 的整个 4 KiB 扇区。
///
/// ROM 的参数是**扇区号**（offset / 0x1000），不是地址；传地址会擦到
/// 一个完全无关的位置，且控制器不会报错。
pub fn eraseSector(offset: u32) Error!void {
    if (offset % sector_size != 0) return Error.UnalignedOffset;
    if (offset >= flash_size) return Error.OutOfRange;
    const guard = Critical.begin();
    defer guard.end();
    if (esp_rom_spiflash_erase_sector(offset / sector_size) != 0) {
        return Error.EraseFailed;
    }
}

/// 写后立刻读回比对：ROM 的返回码只代表控制器报告完成，
/// 不代表阵列里真的落下了这些字节。
pub fn writeVerified(offset: u32, words: []const u32) Error!void {
    try write(offset, words);

    // 分块读回，避免为任意长度在栈上开大数组。
    var back: [16]u32 align(4) = undefined;
    var i: usize = 0;
    while (i < words.len) {
        const n = @min(words.len - i, back.len);
        try read(offset + @as(u32, @intCast(i * 4)), back[0..n]);
        if (!std.mem.eql(u32, words[i..][0..n], back[0..n])) {
            return Error.VerifyFailed;
        }
        i += n;
    }
}
