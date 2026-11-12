//! ch09-flash-partition-nvs：分区表解析（只读，不做任何写操作）。
//!
//! 二级 bootloader 从 flash 偏移 `0x8000` 读 `0xC00` 字节的分区表，
//! 本章用同样的参数把这张表读进 SRAM，然后按 32 字节步进解析。
//!
//! 结构（IDF v6.1 `esp_flash_partitions.h` 的 `esp_partition_info_t`）：
//!
//!   偏移  大小  字段
//!   0     2     magic       ESP_PARTITION_MAGIC = 0x50AA，落盘字节是 AA 50
//!   2     1     type        0x00 = app，0x01 = data
//!   3     1     subtype     factory/ota_*、nvs/phy/spiffs...
//!   4     4     offset      分区的 flash 偏移
//!   8     4     size        分区大小
//!   12    16    label       NUL 结尾的 ASCII
//!   28    4     flags
//!
//! `0xC00` = 96 × 32：前 95 个位置放条目，最后 32 字节是表尾
//! （`EB EB` + 14 个 `FF` + 16 字节 MD5）。摘要只覆盖**已用条目的字节**，
//! 与 ch03-image-inspect 的主机解析器一致，不是整块 `0xBE0`。
//! 所以 `0xC00 / 32 - 1 = 95` 就是条目上限；写满 96 条会盖掉表尾，
//! bootloader 会拒绝整张表。本模块只判断表尾魔数是否存在，不重算摘要：
//! 重算属于烧录工具/构建期的职责，运行期做它只会多一份实现。
//!
//! 本模块**不**擦写任何东西：分区表所在的 `0x8000` 是 bootloader 的领地，
//! 应用碰它等于把板子变砖。

const std = @import("std");
const flash = @import("flash.zig");

pub const table_offset: u32 = 0x8000;
pub const table_size: usize = 0xC00;
pub const entry_size: usize = 32;
/// 数值是 0x50AA（IDF 的 ESP_PARTITION_MAGIC），不是 0xAA50：
/// 小端把它写成两个字节 `AA 50`。这里的比较走 u16，因此必须用 0x50AA；
/// 若改成逐字节比较，条件就是 byte[0] == 0xAA and byte[1] == 0x50。
pub const partition_magic: u16 = 0x50AA;
pub const max_entries: usize = table_size / entry_size - 1; // 95

pub const type_app: u8 = 0x00;
pub const type_data: u8 = 0x01;

pub const Entry = struct {
    part_type: u8,
    subtype: u8,
    offset: u32,
    size: u32,
    label: [16]u8,
    flags: u32,

    /// 标签是 NUL 结尾的定长字段；返回值指向本条目内部的字节。
    pub fn labelSlice(self: Entry) []const u8 {
        var n: usize = 0;
        while (n < self.label.len and self.label[n] != 0) : (n += 1) {}
        return self.label[0..n];
    }
};

/// 0xC00 字节的读缓冲，落在 .bss，4 字节对齐（ROM read 要求）。
var raw: [table_size / 4]u32 align(4) = undefined;

var table: [max_entries]Entry = undefined;
pub var count: usize = 0;
pub var md5_present: bool = false;

/// 读并解析分区表。遇到第一个无效条目就停：这既覆盖“表只有几条”的正常
/// 情况，也挡住“读到全 0xFF”的未烧录状态。
pub fn load() flash.Error!void {
    try flash.read(table_offset, &raw);

    const bytes = std.mem.asBytes(&raw);
    count = 0;

    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        const rec = bytes[i * entry_size ..][0..entry_size];
        const magic = std.mem.readInt(u16, rec[0..2], .little);
        if (magic != partition_magic) break;

        const typ = rec[2];
        if (typ != type_app and typ != type_data) break;

        var label: [16]u8 = undefined;
        @memcpy(&label, rec[12..28]);

        table[count] = .{
            .part_type = typ,
            .subtype = rec[3],
            .offset = std.mem.readInt(u32, rec[4..8], .little),
            .size = std.mem.readInt(u32, rec[8..12], .little),
            .label = label,
            .flags = std.mem.readInt(u32, rec[28..32], .little),
        };
        count += 1;
    }

    // 表尾是 `EB EB` + 14 个 FF + 16 字节 MD5。只看魔数：没有魔数说明
    // 这块还没被生成器写过（比如只烧了应用、没烧分区表）。
    const tail = table_size - entry_size;
    md5_present = bytes[tail] == 0xEB and bytes[tail + 1] == 0xEB;
}

/// 按标签查找。返回副本：调用方拿到的条目与全局表解耦。
pub fn find(label: []const u8) ?Entry {
    for (table[0..count]) |e| {
        if (std.mem.eql(u8, e.labelSlice(), label)) return e;
    }
    return null;
}

/// 遍历（供打印用）。
pub fn at(index: usize) ?Entry {
    if (index >= count) return null;
    return table[index];
}
