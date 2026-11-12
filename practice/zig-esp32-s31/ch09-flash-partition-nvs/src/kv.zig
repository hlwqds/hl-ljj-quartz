//! ch09-flash-partition-nvs：一个 16 字节记录的追加式 KV。
//!
//! **不是 IDF NVS 格式，也不与它兼容。** 这里没有页头、没有 32 字节条目、
//! 没有命名空间、没有键名。它只回答一个问题：“掉电之后，最后一个完整的
//! 值还在不在？”
//!
//! 记录布局（16 字节，4 字节对齐）：
//!
//!   +-----------------+--------+--------+--------+
//!   | w0: magic (u16) |  w1    |  w2    |  w3    |
//!   | 低 16 位 = 0x4B56|  seq   | value  | crc32  |
//!   | 高 16 位 = 0     |  u32   |  u32   |  u32   |
//!   +-----------------+--------+--------+--------+
//!        CRC32 覆盖 w0..w2 共 12 字节
//!
//! 记录按 4 个 u32 落盘，所以 seq 在字节 4..8、value 在 8..12、CRC 在 12..16；
//! magic 虽然语义上是 u16，但占满第一个 32 位字（高半字为 0），这样三个
//! ROM 函数看到的永远是整齐的 4 字节字。
//!
//! 追加式日志的规则：
//!   - 一个 4 KiB 扇区 = 256 条；
//!   - 挂载时从槽 0 顺序扫描：`0xFFFF` 是“空白尾部”，魔数/CRC 不符是
//!     “撕裂尾部”，两者都立即停止；
//!   - 写入只追加到下一个空槽，绝不原地改；
//!   - 写满后压缩：只保留最新一条，擦扇区、写回槽 0、再校验。
//!
//! 为什么需要 CRC：magic 只有 16 位，一个被擦了一半的扇区很可能留下
//! 正确的 magic 而 value 已经残缺。CRC32（IEEE）覆盖前 12 字节，能把
//! 这种“看起来完整”的记录挡掉。
//!
//! 为什么不需要事务/双缓冲：一条记录只有 16 字节，且 flash 的最小写入
//! 单位是 4 字节字，一条记录落在 4 个字里。掉电最坏只会破坏最后一条，
//! 而它本来就没有被计入“已完成”的序列（下次扫描会把它判成撕裂尾部）。

const std = @import("std");
const flash = @import("flash.zig");

pub const magic: u16 = 0x4B56;
pub const record_bytes: usize = 16;
pub const record_words: usize = record_bytes / 4;
pub const slots_per_sector: usize = @as(usize, flash.sector_size) / record_bytes; // 256

pub const Record = struct {
    seq: u32,
    value: u32,
};

pub const Scan = struct {
    /// 完整且 CRC 正确的记录条数。
    records: usize = 0,
    last_seq: u32 = 0,
    last_value: u32 = 0,
    /// 尾部是写到一半的记录（魔数对、CRC 错，或魔数就不是 0x4B56）。
    torn: bool = false,
    /// 256 条全部有效，下一次追加必须先压缩。
    full: bool = false,
};

/// 一次读整个扇区（4 KiB / 4 = 1024 个字），比逐条 read 少 255 次 ROM 调用。
var sector_buf: [flash.sector_size / 4]u32 align(4) = undefined;

/// 组装一条记录；CRC 覆盖前 12 字节。
fn encode(seq: u32, value: u32) [record_words]u32 {
    var w: [record_words]u32 = .{ magic, seq, value, 0 };
    w[3] = std.hash.Crc32.hash(std.mem.asBytes(&w)[0..12]);
    return w;
}

/// 扫描一个扇区。`base` 必须是 4 KiB 对齐的分区起始偏移。
pub fn scan(base: u32) flash.Error!Scan {
    try flash.read(base, &sector_buf);

    const bytes = std.mem.asBytes(&sector_buf);
    var out = Scan{};

    var i: usize = 0;
    while (i < slots_per_sector) : (i += 1) {
        const rec = bytes[i * record_bytes ..][0..record_bytes];
        const m = std.mem.readInt(u16, rec[0..2], .little);

        // 空白尾部：擦除后的 0xFF。立即停止，不视为损坏。
        if (m == 0xFFFF) break;

        if (m != magic) {
            out.torn = true;
            break;
        }

        const seq = std.mem.readInt(u32, rec[4..8], .little);
        const value = std.mem.readInt(u32, rec[8..12], .little);
        const crc = std.mem.readInt(u32, rec[12..16], .little);
        if (crc != std.hash.Crc32.hash(rec[0..12])) {
            out.torn = true;
            break;
        }

        out.records += 1;
        out.last_seq = seq;
        out.last_value = value;
    }

    out.full = !out.torn and out.records == slots_per_sector;
    return out;
}

/// 追加一条记录并读回校验。`value` 由调用方决定（本章是开机计数 + 1）。
///
/// 返回新记录的 `Record`；失败时 flash 里的内容可能处于三种状态之一
/// （未写、写了一部分、写完整但校验失败），下一次 `scan` 会把后两种
/// 判成撕裂尾部——这正是我们期望的“失败不推进序列”。
pub fn append(base: u32, state: Scan, value: u32) flash.Error!Record {
    // 写只能把 1 变 0，所以撕裂槽不能直接覆盖：那里已经有被写成 0 的位。
    // 扇区写满同理。两种情况都走“擦 + 写回槽 0”的压缩路径。
    if (state.full or state.torn) return compact(base, state, value);

    const next_seq = state.last_seq + 1;
    const slot = encode(next_seq, value);
    const offset = base + @as(u32, @intCast(state.records * record_bytes));

    // 16 字节天然 4 字节对齐；扇区边界由 slots_per_sector 保证。
    try flash.writeVerified(offset, &slot);
    return .{ .seq = next_seq, .value = value };
}

/// 压缩：保留最新值，擦整扇区，把它写回槽 0。
/// 触发条件有两种：256 条写满，或尾部撕裂（不可能原地覆盖）。
///
/// 注意顺序：先在 RAM 里组好记录，再擦，再写。擦除之后如果掉电，扇区是
/// 全 0xFF，下一次扫描得到 `records=0`——数据退化为“没有记录”，但不会
/// 读到半条垃圾。NVS 用双页 + 状态位解决同一问题；本章刻意保持最小。
pub fn compact(base: u32, state: Scan, value: u32) flash.Error!Record {
    const next_seq = state.last_seq + 1;
    const slot = encode(next_seq, value);

    try flash.eraseSector(base);
    try flash.writeVerified(base, &slot);
    return .{ .seq = next_seq, .value = value };
}
