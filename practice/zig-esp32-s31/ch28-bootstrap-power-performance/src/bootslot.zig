//! ch28：二级 bootloader 的“选槽”逻辑（可离线判定）。
//!
//! 本章不实现 form C 的自举 bootloader，只把 bootloader 必须做对的两件事
//! 抽成纯逻辑：
//!
//!   1) `otadata` 两个扇区怎么选：CRC 先过、再比 seq，平手取第一个；
//!   2) 选中的槽连续启动失败怎么回滚：复用 ch24 的 A/B 状态机
//!      （`ota.Rollback`），bootloader 只负责“读状态 + 计数 + 选槽”。
//!
//! 线上格式（16 字节，故意比 IDF 的 `esp_ota_select_entry_t` 简单，
//! 不冒充兼容格式）：
//!
//!   | 偏移 | 字段 | 说明 |
//!   |------|------|------|
//!   | 0    | magic `S31B` | 区分空白 flash（0xFF） |
//!   | 4    | seq  | 越大越新，回绕按无符号比较 |
//!   | 8    | slot | 0=A/ota_0，1=B/ota_1 |
//!   | 9    | state| ch24 的 `ota.SlotState` |
//!   | 10..12 | reserved | 必须为 0 |
//!   | 12   | crc32 | 覆盖 [0,12) |
//!
//! 真实 IDF 的 `otadata` 是 32 位 `ota_seq` + state + CRC，且两个扇区
//! 交替写；这里保留同样的**决策语义**，字段布局只为教学可读。

const std = @import("std");
const ota = @import("ota.zig");

pub const entry_len: usize = 16;
pub const entry_magic = [4]u8{ 'S', '3', '1', 'B' };

pub const Entry = struct {
    seq: u32,
    slot: ota.Slot,
    state: ota.SlotState,
};

pub const Error = error{
    BufferTooSmall,
    BadMagic,
    BadReserved,
    BadSlot,
    BadState,
    BadCrc,
};

fn readU32Le(in: []const u8) u32 {
    return @as(u32, in[0]) |
        (@as(u32, in[1]) << 8) |
        (@as(u32, in[2]) << 16) |
        (@as(u32, in[3]) << 24);
}

fn writeU32Le(out: []u8, v: u32) void {
    out[0] = @intCast(v & 0xFF);
    out[1] = @intCast((v >> 8) & 0xFF);
    out[2] = @intCast((v >> 16) & 0xFF);
    out[3] = @intCast((v >> 24) & 0xFF);
}

/// CRC-32/ISO-HDLC（反射多项式 0xEDB88320，初值/异或 0xFFFFFFFF）。
/// 逐位实现，避免把表放进 `.rodata`；otadata 只有 16 字节，速度无所谓。
pub fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        crc ^= b;
        var i: u5 = 0;
        while (i < 8) : (i += 1) {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return ~crc;
}

pub fn encodeEntry(out: []u8, e: Entry) Error!usize {
    if (out.len < entry_len) return error.BufferTooSmall;
    @memcpy(out[0..4], &entry_magic);
    writeU32Le(out[4..8], e.seq);
    out[8] = @intFromEnum(e.slot);
    out[9] = @intFromEnum(e.state);
    out[10] = 0;
    out[11] = 0;
    writeU32Le(out[12..16], crc32(out[0..12]));
    return entry_len;
}

pub fn decodeEntry(bytes: []const u8) Error!Entry {
    if (bytes.len < entry_len) return error.BufferTooSmall;
    if (!std.mem.eql(u8, bytes[0..4], &entry_magic)) return error.BadMagic;
    if (bytes[10] != 0 or bytes[11] != 0) return error.BadReserved;
    if (bytes[8] > 1) return error.BadSlot;
    if (bytes[9] > @intFromEnum(ota.SlotState.aborted) and bytes[9] != 0xFF) return error.BadState;
    if (readU32Le(bytes[12..16]) != crc32(bytes[0..12])) return error.BadCrc;
    return .{
        .seq = readU32Le(bytes[4..8]),
        .slot = if (bytes[8] == 0) .a else .b,
        .state = @enumFromInt(bytes[9]),
    };
}

pub const Pick = struct {
    entry: Entry,
    index: u2,
};

/// 两个 otadata 扇区的选择规则：
///   1) 先丢掉 magic/CRC 坏的（空白 flash 全 0xFF 直接丢）；
///   2) 剩下的取 seq 最大者；
///   3) seq 相同取下标小者（与 IDF 的“先找到的先用”一致，避免随机性）。
pub fn pick(entries: [2]Entry) ?Pick {
    var best: ?Pick = null;
    for (entries, 0..) |e, i| {
        if (best) |b| {
            if (e.seq > b.entry.seq) best = .{ .entry = e, .index = @intCast(i) };
        } else {
            best = .{ .entry = e, .index = @intCast(i) };
        }
    }
    return best;
}

/// 从两个 16 字节扇区解析并选槽；任一扇区坏不影响另一个。
pub fn pickBytes(a: []const u8, b: []const u8) ?Pick {
    var best: ?Pick = null;
    if (decodeEntry(a)) |e| {
        best = .{ .entry = e, .index = 0 };
    } else |_| {}
    if (decodeEntry(b)) |e| {
        if (best == null or e.seq > best.?.entry.seq) {
            best = .{ .entry = e, .index = 1 };
        }
    } else |_| {}
    return best;
}

// ---------------------------------------------------------------------------
// 启动决策
// ---------------------------------------------------------------------------

pub const Decision = struct {
    slot: ?ota.Slot,
    reason: enum { otadata, factory_fallback, no_bootable },
};

/// bootloader 只允许启动“已确认”或“待验证”的槽；ABORTED/INVALID/UNDEFINED
/// 都不能跳过去试，否则坏固件会被反复启动。
pub fn bootable(state: ota.SlotState) bool {
    return switch (state) {
        .valid, .pending_verify => true,
        else => false,
    };
}

/// bootloader 级决策：选中槽必须是 VALID 或 PENDING_VERIFY；其余状态
/// （ABORTED/INVALID/UNDEFINED）一律回 factory。真实 IDF 在
/// `no bootable app partitions` 时停在 bootloader，这里把 factory 当作
/// 最后的救援槽，教学模型更宽容。
pub fn decide(a: []const u8, b: []const u8) Decision {
    if (pickBytes(a, b)) |p| {
        if (bootable(p.entry.state)) return .{ .slot = p.entry.slot, .reason = .otadata };
    }
    return .{ .slot = null, .reason = .factory_fallback };
}

/// 回滚预算：bootloader 只数“pending_verify 启动了几次”，到点交给 ota 状态机。
pub fn bootAttemptsExceeded(attempts: u8, cfg: ota.AbConfig) bool {
    return attempts > cfg.max_boot_attempts;
}

test "crc32 known answer" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "entry roundtrip and crc rejection" {
    var buf: [entry_len]u8 = undefined;
    _ = try encodeEntry(&buf, .{ .seq = 7, .slot = .b, .state = .pending_verify });
    const e = try decodeEntry(&buf);
    try std.testing.expectEqual(@as(u32, 7), e.seq);
    try std.testing.expectEqual(ota.Slot.b, e.slot);

    buf[5] ^= 1;
    try std.testing.expectError(error.BadCrc, decodeEntry(&buf));
}

test "pick highest sequence and tolerate one bad sector" {
    var a: [entry_len]u8 = undefined;
    var b: [entry_len]u8 = undefined;
    _ = try encodeEntry(&a, .{ .seq = 3, .slot = .a, .state = .valid });
    _ = try encodeEntry(&b, .{ .seq = 4, .slot = .b, .state = .new });
    const p = pickBytes(&a, &b).?;
    try std.testing.expectEqual(ota.Slot.b, p.entry.slot);
    try std.testing.expectEqual(@as(u2, 1), p.index);

    b[12] ^= 0xFF;
    const q = pickBytes(&a, &b).?;
    try std.testing.expectEqual(ota.Slot.a, q.entry.slot);
}
