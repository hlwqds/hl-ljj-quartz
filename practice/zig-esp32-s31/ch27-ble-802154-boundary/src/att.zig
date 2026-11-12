//! ch27-ble-802154-boundary：ATT 协议最小子集。
//!
//! ATT（Attribute Protocol）是 BLE 的“对象读写”层，跑在 L2CAP 固定通道
//! CID 0x0004 上。它只有两种形状：
//!
//!   * 请求/响应（Require/Response）：client 发，server 必须回；
//!   * 命令/通知（Command/Notification）：单向，不回。
//!
//! 本章实现 8 个操作码，刚好够走通“交换 MTU → 读特征值 → 写特征值 →
//! 订阅通知 → 收通知 → 越界/无权限报错”这条完整路径。
//!
//! 规范出处（Bluetooth Core Specification v5.4）：
//!   * ATT PDU 格式：Vol 3, Part F, §3.3（1 字节 Opcode + 参数）；
//!   * Exchange MTU Request / Response：§3.4.2（0x02 / 0x03）；
//!   * Read Request / Response：§3.4.4（0x0A / 0x0B）；
//!   * Write Request / Response：§3.4.5（0x12 / 0x13）；
//!   * Handle Value Notification：§3.4.7（0x1B）；
//!   * Error Response：§3.4.1（0x01），5 字节固定；
//!   * ATT_MTU 默认 23、上限由实现声明：Vol 3, Part F, §3.2.8/§3.2.9。
//!
//! 操作码与错误码的**本机证据**（IDF v6.1 nimble host，行号为 grep 实测）：
//!   components/bt/host/nimble/nimble/nimble/host/include/host/ble_att.h
//!     :124  BLE_ATT_OP_ERROR_RSP   0x01
//!     :127  BLE_ATT_OP_MTU_REQ     0x02
//!     :130  BLE_ATT_OP_MTU_RSP     0x03
//!     :151  BLE_ATT_OP_READ_REQ    0x0a
//!     :154  BLE_ATT_OP_READ_RSP    0x0b
//!     :175  BLE_ATT_OP_WRITE_REQ   0x12
//!     :178  BLE_ATT_OP_WRITE_RSP   0x13
//!     :199  BLE_ATT_OP_NOTIFY_REQ  0x1b
//!     :269  BLE_ATT_MTU_DFLT       23
//!     :275  BLE_ATT_MTU_MAX        527
//!     :62   BLE_ATT_ERR_INVALID_HANDLE        0x01
//!     :65   BLE_ATT_ERR_READ_NOT_PERMITTED    0x02
//!     :68   BLE_ATT_ERR_WRITE_NOT_PERMITTED   0x03
//!     :71   BLE_ATT_ERR_INVALID_PDU           0x04
//!     :111  BLE_ATT_ERR_INSUFFICIENT_RES      0x11
//!
//! 本节约定的“最小策略”（章节 27.4 会逐条说明哪些是规范、哪些是本实现的
//! 选择）：
//!   1. 请求 MTU < 23 → 直接拒绝（error.MtuTooSmall），不发 PDU；
//!   2. 协商结果 = min(client, server_max)，server 端上限是编译期常量；
//!   3. Read Response 的值被截断到 MTU-1（响应头 1 字节）；
//!   4. Notification 的值被截断到 MTU-3（操作码 1 + 句柄 2）；
//!   5. 截断不是静默的：`stats.truncated` 加一，调用方必须看它。

const std = @import("std");

/// ATT 操作码（只列本章实现的 8 个）。Vol 3, Part F, §3.4。
pub const Op = enum(u8) {
    error_rsp = 0x01,
    mtu_req = 0x02,
    mtu_rsp = 0x03,
    read_req = 0x0a,
    read_rsp = 0x0b,
    write_req = 0x12,
    write_rsp = 0x13,
    notify = 0x1b,
};

/// ATT 错误码。Vol 3, Part F, §3.4.1.1 表 3.3。
pub const Code = enum(u8) {
    invalid_handle = 0x01,
    read_not_permitted = 0x02,
    write_not_permitted = 0x03,
    invalid_pdu = 0x04,
    insufficient_resources = 0x11,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .invalid_handle => "invalid_handle",
            .read_not_permitted => "read_not_permitted",
            .write_not_permitted => "write_not_permitted",
            .invalid_pdu => "invalid_pdu",
            .insufficient_resources => "insufficient_resources",
        };
    }
};

/// 默认 ATT_MTU（未交换时）。Vol 3, Part F, §3.2.8。
pub const default_mtu: u16 = 23;
/// 本章 server 端声明的上限。
///
/// 规范给的 ATT_MTU 上限是 **517**（Vol 3, Part F, §3.2.8）；NimBLE 刻意把它
/// 扩到 527，理由写在 `ble_att.h:270-273`：一个 527 的 MTU 才能让最大的 ATT
/// 命令（Signed Write）装下 512 字节属性值。本章跟 NimBLE 取 527，好处是
/// 「MTU 截断」的判据在边界值附近也能测到（判据 ④ 用的是 23，不是 527）。
pub const max_mtu: u16 = 527;

pub const Error = error{
    /// PDU 比该操作码要求的固定长度短（或长）。
    Short,
    /// 长度与声明不符。
    Trailing,
    /// 输出缓冲不够。
    NoSpace,
    /// client 请求的 MTU < 23。
    MtuTooSmall,
    /// MTU 超过本实现声明的上限。
    MtuTooLarge,
    /// 操作码不在本章子集里。
    UnsupportedOp,
};

/// 编解码统计。判据 ③④⑥ 都拿这里的计数当被测对象。
pub const Stats = struct {
    mtu_exchanges: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    notifies: u32 = 0,
    errors_emitted: u32 = 0,
    truncated: u32 = 0,
    rejected: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

fn putU16(out: []u8, v: u16) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
}

fn getU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

// ---------------------------------------------------------------------------
// MTU 交换（判据 ③）
// ---------------------------------------------------------------------------

/// Exchange MTU Request：02 <client_rx_mtu:2, LE>，共 3 字节。
pub fn encodeMtuReq(out: []u8, client_mtu: u16, stats: *Stats) Error!usize {
    if (out.len < 3) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.mtu_req);
    putU16(out[1..3], client_mtu);
    return 3;
}

pub fn decodeMtuReq(pdu: []const u8, stats: *Stats) Error!u16 {
    if (pdu.len < 3) {
        stats.rejected += 1;
        return error.Short;
    }
    if (pdu.len > 3 or pdu[0] != @backingInt(Op.mtu_req)) {
        stats.rejected += 1;
        return error.Trailing;
    }
    const mtu = getU16(pdu[1..3]);
    if (mtu < default_mtu) {
        stats.rejected += 1;
        return error.MtuTooSmall;
    }
    if (mtu > max_mtu) {
        stats.rejected += 1;
        return error.MtuTooLarge;
    }
    return mtu;
}

/// 协商：结果 = min(client, server_max)。client 的请求先过 decodeMtuReq 的
/// 合法性检查，所以这里只做取小。
pub fn negotiate(client_mtu: u16, server_max: u16) u16 {
    return @min(client_mtu, @min(server_max, max_mtu));
}

/// Exchange MTU Response：03 <server_rx_mtu:2, LE>，共 3 字节。
pub fn encodeMtuRsp(out: []u8, server_mtu: u16, stats: *Stats) Error!usize {
    if (out.len < 3) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.mtu_rsp);
    putU16(out[1..3], server_mtu);
    stats.mtu_exchanges += 1;
    return 3;
}

pub fn decodeMtuRsp(pdu: []const u8, stats: *Stats) Error!u16 {
    if (pdu.len != 3 or pdu[0] != @backingInt(Op.mtu_rsp)) {
        stats.rejected += 1;
        return error.Short;
    }
    return getU16(pdu[1..3]);
}

// ---------------------------------------------------------------------------
// Read Request / Response（判据 ④）
// ---------------------------------------------------------------------------

/// Read Request：0A <handle:2, LE>，共 3 字节。
pub fn encodeReadReq(out: []u8, handle: u16, stats: *Stats) Error!usize {
    if (out.len < 3) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.read_req);
    putU16(out[1..3], handle);
    return 3;
}

pub fn decodeReadReq(pdu: []const u8, stats: *Stats) Error!u16 {
    if (pdu.len < 3) {
        stats.rejected += 1;
        return error.Short;
    }
    if (pdu.len > 3 or pdu[0] != @backingInt(Op.read_req)) {
        stats.rejected += 1;
        return error.Trailing;
    }
    return getU16(pdu[1..3]);
}

/// Read Response：0B <value>。值被截断到 `mtu - 1`（响应头占 1 字节）。
/// 返回写入的总长度（1 + 有效值长度）。
pub fn encodeReadRsp(out: []u8, value: []const u8, mtu: u16, stats: *Stats) Error!usize {
    const room = if (mtu > 1) @as(usize, mtu - 1) else 0;
    const n = @min(value.len, room);
    if (out.len < 1 + n) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.read_rsp);
    @memcpy(out[1 .. 1 + n], value[0..n]);
    if (n < value.len) stats.truncated += 1;
    stats.reads += 1;
    return 1 + n;
}

pub fn decodeReadRsp(pdu: []const u8, stats: *Stats) Error![]const u8 {
    if (pdu.len < 1 or pdu[0] != @backingInt(Op.read_rsp)) {
        stats.rejected += 1;
        return error.Short;
    }
    return pdu[1..];
}

// ---------------------------------------------------------------------------
// Write Request / Response（判据 ⑤）
// ---------------------------------------------------------------------------

/// Write Request：12 <handle:2, LE> <value…>。
pub fn encodeWriteReq(out: []u8, handle: u16, value: []const u8, stats: *Stats) Error!usize {
    const total = 3 + value.len;
    if (out.len < total) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.write_req);
    putU16(out[1..3], handle);
    @memcpy(out[3..total], value);
    return total;
}

pub const WriteReq = struct { handle: u16, value: []const u8 };

pub fn decodeWriteReq(pdu: []const u8, stats: *Stats) Error!WriteReq {
    if (pdu.len < 3) {
        stats.rejected += 1;
        return error.Short;
    }
    if (pdu[0] != @backingInt(Op.write_req)) {
        stats.rejected += 1;
        return error.Trailing;
    }
    stats.writes += 1;
    return .{ .handle = getU16(pdu[1..3]), .value = pdu[3..] };
}

/// Write Response：13，单字节，无参数。
pub fn encodeWriteRsp(out: []u8, stats: *Stats) Error!usize {
    if (out.len < 1) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.write_rsp);
    return 1;
}

// ---------------------------------------------------------------------------
// Handle Value Notification（判据 ⑥）
// ---------------------------------------------------------------------------

/// Notification：1B <handle:2, LE> <value…>。值被截断到 `mtu - 3`。
pub fn encodeNotify(out: []u8, handle: u16, value: []const u8, mtu: u16, stats: *Stats) Error!usize {
    const room = if (mtu > 3) @as(usize, mtu - 3) else 0;
    const n = @min(value.len, room);
    const total = 3 + n;
    if (out.len < total) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.notify);
    putU16(out[1..3], handle);
    @memcpy(out[3..total], value[0..n]);
    if (n < value.len) stats.truncated += 1;
    stats.notifies += 1;
    return total;
}

pub fn decodeNotify(pdu: []const u8, stats: *Stats) Error!WriteReq {
    if (pdu.len < 3 or pdu[0] != @backingInt(Op.notify)) {
        stats.rejected += 1;
        return error.Short;
    }
    return .{ .handle = getU16(pdu[1..3]), .value = pdu[3..] };
}

// ---------------------------------------------------------------------------
// Error Response（判据 ⑤⑦）
// ---------------------------------------------------------------------------

/// Error Response：01 <req_opcode:1> <handle:2, LE> <error_code:1>，共 5 字节。
/// Vol 3, Part F, §3.4.1.1。句柄为 0x0000 表示错误与具体属性无关。
pub fn encodeError(
    out: []u8,
    req_op: Op,
    handle: u16,
    code: Code,
    stats: *Stats,
) Error!usize {
    if (out.len < 5) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = @backingInt(Op.error_rsp);
    out[1] = @backingInt(req_op);
    putU16(out[2..4], handle);
    out[4] = @backingInt(code);
    stats.errors_emitted += 1;
    return 5;
}

pub const ErrorRsp = struct { req_op: u8, handle: u16, code: u8 };

pub fn decodeError(pdu: []const u8, stats: *Stats) Error!ErrorRsp {
    if (pdu.len < 5) {
        stats.rejected += 1;
        return error.Short;
    }
    if (pdu.len > 5) {
        stats.rejected += 1;
        return error.Trailing;
    }
    return .{ .req_op = pdu[1], .handle = getU16(pdu[2..4]), .code = pdu[4] };
}

// ---------------------------------------------------------------------------
// KAT 固定字节串（判据 ③④⑥⑦ 逐字节比对）
// ---------------------------------------------------------------------------

/// Exchange MTU Request：client 报 247（0x00F7）→ 02 F7 00。
pub const kat_mtu_req = [3]u8{ 0x02, 0xf7, 0x00 };

/// Exchange MTU Response：server 回 247 → 03 F7 00。
pub const kat_mtu_rsp = [3]u8{ 0x03, 0xf7, 0x00 };

/// Read Request：句柄 0x0025 → 0A 25 00。
pub const kat_read_req = [3]u8{ 0x0a, 0x25, 0x00 };

/// Read Response：值 “ch27” → 0B 63 68 32 37。
pub const kat_read_rsp = [5]u8{ 0x0b, 'c', 'h', '2', '7' };

/// Write Request：句柄 0x0028、值 {0x01, 0x00}（CCCD 打开通知）
///   → 12 28 00 01 00。
pub const kat_write_req = [5]u8{ 0x12, 0x28, 0x00, 0x01, 0x00 };

/// Error Response：对 Read Request、句柄 0x0099、Invalid Handle
///   → 01 0A 99 00 01。
pub const kat_error_rsp = [5]u8{ 0x01, 0x0a, 0x99, 0x00, 0x01 };
