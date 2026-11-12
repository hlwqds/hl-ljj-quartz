//! ch27-ble-802154-boundary：HCI 分帧（host ↔ controller 的唯一缝）。
//!
//! 本章不链接 BLE controller blob，也不驱动射频；这个文件是**字节级**的
//! 编解码器，被三处共用：
//!
//!   * `src/host_tests.zig` —— x86_64 上的 KAT；
//!   * `src/selftest.zig`   —— 同一批用例在 rv32 板上再跑一遍（判据 ①②）；
//!   * `src/gatt.zig` 的调用方 —— 通知帧最终要封进 ACL 包。
//!
//! 规范出处（Bluetooth Core Specification v5.4）：
//!   * H4 传输层包指示符（command 0x01 / ACL 0x02 / event 0x04）
//!     Vol 4, Part A, §2（HCI 传输层）与 Vol 4, Part E, §5.4.1；
//!   * ACL 数据包：4 字节头 = Handle(12b) | PB(2b) | BC(2b) + Data Length(16b)
//!     Vol 4, Part E, §5.4.2；
//!   * Command packet：OpCode(16b, LE) + Parameter_Total_Length(8b) + 参数
//!     Vol 4, Part E, §5.4.1；
//!   * Event packet：Event_Code(8b) + Parameter_Total_Length(8b) + 参数
//!     Vol 4, Part E, §5.4.4；
//!   * LE Meta Event（Event_Code 0x3E）与子事件
//!     Vol 4, Part E, §7.7.65（LE Meta Event）；
//!   * LE Advertising Report（子事件 0x02）
//!     Vol 4, Part E, §7.7.65.2；
//!   * LE Connection Complete（子事件 0x01）
//!     Vol 4, Part E, §7.7.65.1；
//!   * Command Complete（Event_Code 0x0E）
//!     Vol 4, Part E, §7.7.14。
//!
//! 本机可对拍的实现证据（IDF v6.1 源码，行号为 `grep -n` 实测）：
//!   components/bt/host/nimble/nimble/nimble/host/include/host/ble_att.h:124…
//!   是 ATT 操作码；HCI 侧对应的是 components/bt/host/bluedroid/hci/include/
//!   hci/hci_trans_int.h（bluedroid 的 HCI 传输接口）。
//!
//! 所有缓冲区都是调用方给的定长切片：没有分配、没有隐式截断。长度不够时
//! 返回 `error.NoSpace` 并把 `stats.rejected` 加一——判据 ② 就是拿这个
//! 计数当被测对象的。

const std = @import("std");

/// HCI 传输层包指示符（H4）。Vol 4, Part A, §2。
pub const h4_command: u8 = 0x01;
pub const h4_acl: u8 = 0x02;
pub const h4_event: u8 = 0x04;

/// 事件码。Vol 4, Part E, §7.7。
pub const evt_command_complete: u8 = 0x0e;
pub const evt_le_meta: u8 = 0x3e;

/// LE Meta 子事件码。Vol 4, Part E, §7.7.65。
pub const le_connection_complete: u8 = 0x01;
pub const le_advertising_report: u8 = 0x02;

/// ACL 头固定 4 字节：Handle(12b)+PB(2b)+BC(2b)，Data_Length(16b)。
pub const acl_header_len: usize = 4;

/// 本章 ACL 载荷的静态上限。真实 controller 的 ACL MTU 由
/// `HCI_ACL_PKT_LEN` 之类配置决定（LE 数据长度扩展后可达 251+），
/// 这里取 251 作为“一个 LE 数据 PDU 的上界”，够放下 ATT MTU 247 的值。
pub const acl_max_payload: usize = 251;

/// 一个完整 ACL 包（含头）需要的静态缓冲。
pub const acl_buf_size: usize = acl_header_len + acl_max_payload;

pub const Error = error{
    /// 输入短于该包型的固定长度。
    Short,
    /// 输入长于声明长度（多出来的字节不被静默丢弃）。
    Trailing,
    /// 输出缓冲放不下。
    NoSpace,
    /// Data_Length 声明超过 `acl_max_payload`。
    Oversize,
    /// 子事件码不是本章实现的那几种。
    UnsupportedEvent,
};

/// 编解码统计：判据要求“能判别错”，所以拒绝必须可数。
pub const Stats = struct {
    acl_encoded: u32 = 0,
    acl_decoded: u32 = 0,
    rejected: u32 = 0,
    truncated: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

/// PB 标志（ACL 分片）。Vol 4, Part E, §5.4.2 表 5.2。
///
/// 位值是规范钉死的，且与 Linux `include/net/bluetooth/hci.h` 的
/// `ACL_START_NO_FLUSH 0x00` / `ACL_CONT 0x01` / `ACL_START 0x02` /
/// `ACL_COMPLETE 0x03` 一致：**0b00 是“不可自动 flush 的首片”，
/// 0b10 才是“可自动 flush 的首片”**。这一对最容易写反。
pub const Pb = enum(u2) {
    /// 0b00：L2CAP PDU 的首片，host 不得自动 flush。
    first_non_flushable = 0b00,
    /// 0b01：续片。
    continuation = 0b01,
    /// 0b10：L2CAP PDU 的首片，host 可自动 flush。
    first_flushable = 0b10,
    /// 0b11：整包（未分片）。
    complete = 0b11,
};

/// BC 标志（ACL 的广播位）。LE 的 ACL 只用 `0b00`（点对点）；另外三个位值在
/// 不同 Core 版本里被解释成 BR/EDR 的 Active/Piconet Broadcast，或被标为保留，
/// 本章不编码它们，所以名称保持中性，避免把某一版的解释写死。
pub const Bc = enum(u2) {
    /// 0b00：点对点。LE 唯一合法的取值。
    point_to_point = 0b00,
    other_01 = 0b01,
    other_10 = 0b10,
    other_11 = 0b11,
};

/// ACL 头的逻辑视图。
pub const AclHeader = struct {
    handle: u12,
    pb: Pb,
    bc: Bc,
    data_len: u16,

    /// 编码成 4 字节小端。第二个字节 = handle 高 4 位 | pb | bc。
    pub fn encode(self: AclHeader, out: *[acl_header_len]u8) void {
        const handle_flags: u16 =
            @as(u16, self.handle) |
            (@as(u16, @backingInt(self.pb)) << 12) |
            (@as(u16, @backingInt(self.bc)) << 14);
        out[0] = @truncate(handle_flags);
        out[1] = @truncate(handle_flags >> 8);
        out[2] = @truncate(self.data_len);
        out[3] = @truncate(self.data_len >> 8);
    }

    pub fn decode(bytes: []const u8) Error!AclHeader {
        if (bytes.len < acl_header_len) return error.Short;
        const handle_flags = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
        const len = @as(u16, bytes[2]) | (@as(u16, bytes[3]) << 8);
        return .{
            .handle = @truncate(handle_flags),
            .pb = @fromBackingInt(@intCast(@as(u2, @truncate(handle_flags >> 12)))),
            .bc = @fromBackingInt(@intCast(@as(u2, @truncate(handle_flags >> 14)))),
            .data_len = len,
        };
    }
};

/// 把一个 L2CAP 载荷封进 ACL 包。返回总长度（4 + payload）。
///
/// 判据 ② 的被测对象：payload 超过 `acl_max_payload` 时**不截断、不静默**，
/// 返回 `error.Oversize`，`stats.rejected += 1`。真实 controller 也有同样的
/// 上限（超出 ACL MTU 时 host 必须在 L2CAP 层分片）。
pub fn encodeAcl(
    out: []u8,
    handle: u12,
    pb: Pb,
    payload: []const u8,
    stats: *Stats,
) Error!usize {
    if (payload.len > acl_max_payload) {
        stats.rejected += 1;
        return error.Oversize;
    }
    const total = acl_header_len + payload.len;
    if (out.len < total) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    const hdr = AclHeader{
        .handle = handle,
        .pb = pb,
        .bc = .point_to_point,
        .data_len = @intCast(payload.len),
    };
    hdr.encode(out[0..acl_header_len]);
    @memcpy(out[acl_header_len..total], payload);
    stats.acl_encoded += 1;
    return total;
}

/// 解出 ACL 包：头部 + 指向 `bytes` 内部的载荷切片。
///
/// 严格模式：`bytes.len` 必须**恰好**等于 4 + Data_Length。多一个字节说明
/// 上层读越界了，少一个说明包被截断——两种都拒绝，并计数。
pub const AclPacket = struct {
    header: AclHeader,
    payload: []const u8,
};

pub fn decodeAcl(bytes: []const u8, stats: *Stats) Error!AclPacket {
    if (bytes.len < acl_header_len) {
        stats.rejected += 1;
        return error.Short;
    }
    const hdr = try AclHeader.decode(bytes);
    if (hdr.data_len > acl_max_payload) {
        stats.rejected += 1;
        return error.Oversize;
    }
    const total = acl_header_len + @as(usize, hdr.data_len);
    if (bytes.len < total) {
        stats.rejected += 1;
        stats.truncated += 1;
        return error.Short;
    }
    if (bytes.len > total) {
        stats.rejected += 1;
        return error.Trailing;
    }
    stats.acl_decoded += 1;
    return .{ .header = hdr, .payload = bytes[acl_header_len..total] };
}

/// 由 OGF/OCF 合成 16 位 OpCode。Vol 4, Part E, §5.4.1：
/// OCF 占低 10 位，OGF 占高 6 位。
pub fn opcode(ogf: u6, ocf: u10) u16 {
    return (@as(u16, ogf) << 10) | @as(u16, ocf);
}

/// LE Controller 命令的 OGF 固定是 0x08。Vol 4, Part E, §7.8.1 起。
pub const ogf_le_controller: u6 = 0x08;

/// LE Set Advertising Enable 的 OCF。Vol 4, Part E, §7.8.9。
pub const ocf_le_set_adv_enable: u10 = 0x000a;

/// Command 包 = H4(1) + OpCode(2, LE) + Parameter_Total_Length(1) + 参数。
pub fn encodeCommand(out: []u8, op: u16, params: []const u8, stats: *Stats) Error!usize {
    if (params.len > 255) {
        stats.rejected += 1;
        return error.Oversize;
    }
    const total = 4 + params.len;
    if (out.len < total) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = h4_command;
    out[1] = @truncate(op);
    out[2] = @truncate(op >> 8);
    out[3] = @intCast(params.len);
    @memcpy(out[4..total], params);
    return total;
}

/// Command 包解析结果。
pub const Command = struct { op: u16, params: []const u8 };

pub fn decodeCommand(bytes: []const u8, stats: *Stats) Error!Command {
    if (bytes.len < 4 or bytes[0] != h4_command) {
        stats.rejected += 1;
        return error.Short;
    }
    const plen = @as(usize, bytes[3]);
    if (bytes.len != 4 + plen) {
        stats.rejected += 1;
        return error.Trailing;
    }
    return .{ .op = @as(u16, bytes[1]) | (@as(u16, bytes[2]) << 8), .params = bytes[4..] };
}

/// Command Complete 事件：num_hci_cmd_packets(1) + command_opcode(2) + 返回参数。
pub const CommandComplete = struct { num_packets: u8, op: u16, ret: []const u8 };

pub fn decodeCommandComplete(evt_params: []const u8, stats: *Stats) Error!CommandComplete {
    if (evt_params.len < 3) {
        stats.rejected += 1;
        return error.Short;
    }
    return .{
        .num_packets = evt_params[0],
        .op = @as(u16, evt_params[1]) | (@as(u16, evt_params[2]) << 8),
        .ret = evt_params[3..],
    };
}

/// LE Advertising Report 的一条报告。Vol 4, Part E, §7.7.65.2：
///   Event_Type(1) Address_Type(1) Address(6) Data_Length(1) Data(…) RSSI(1)
pub const AdvReport = struct {
    event_type: u8,
    addr_type: u8,
    addr: [6]u8,
    data: []const u8,
    rssi: i8,
};

/// 一条报告的最小/最大字节数：1+1+6+1+0+1 = 10，数据最长 31。
pub const adv_report_min: usize = 10;
pub const adv_data_max: usize = 31;

/// 解析一条报告（`bytes` 从 Event_Type 开始，不含 num_reports）。
pub fn decodeAdvReport(bytes: []const u8, stats: *Stats) Error!AdvReport {
    if (bytes.len < adv_report_min) {
        stats.rejected += 1;
        return error.Short;
    }
    const dlen = @as(usize, bytes[8]);
    if (dlen > adv_data_max) {
        stats.rejected += 1;
        return error.Oversize;
    }
    const total = adv_report_min + dlen;
    if (bytes.len < total) {
        stats.rejected += 1;
        return error.Short;
    }
    if (bytes.len > total) {
        stats.rejected += 1;
        return error.Trailing;
    }
    var addr: [6]u8 = undefined;
    @memcpy(&addr, bytes[2..8]);
    return .{
        .event_type = bytes[0],
        .addr_type = bytes[1],
        .addr = addr,
        .data = bytes[9 .. 9 + dlen],
        .rssi = @bitCast(bytes[9 + dlen]),
    };
}

/// 在 AD 结构里找 Complete Local Name（AD Type 0x09）。
/// Vol 3, Part C, §11（GAP 的 AD 类型）与 §12（AD 数据格式）。
///
/// 每个 AD 结构是 Length(1) + Type(1) + Data(Length-1)。Length 为 0 表示
/// 后面的全 0 填充，直接停。
pub fn findLocalName(ad: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < ad.len) {
        const len = @as(usize, ad[i]);
        if (len == 0) return null;
        if (i + 1 + len > ad.len) return null;
        if (ad[i + 1] == 0x09) return ad[i + 2 .. i + 1 + len];
        i += 1 + len;
    }
    return null;
}

/// LE Connection Complete：status(1) handle(2,LE) role(1) peer_addr_type(1)
/// peer_addr(6) interval(2) latency(2) supervision_timeout(2) mca(1)。
/// Vol 4, Part E, §7.7.65.1。
pub const ConnComplete = struct {
    status: u8,
    handle: u16,
    role: u8,
    peer_addr_type: u8,
    peer_addr: [6]u8,
    interval: u16,
    latency: u16,
    supervision_timeout: u16,
    master_clock_accuracy: u8,
};

pub const conn_complete_len: usize = 18;

pub fn decodeConnComplete(params: []const u8, stats: *Stats) Error!ConnComplete {
    if (params.len < conn_complete_len) {
        stats.rejected += 1;
        return error.Short;
    }
    if (params.len > conn_complete_len) {
        stats.rejected += 1;
        return error.Trailing;
    }
    var peer: [6]u8 = undefined;
    @memcpy(&peer, params[5..11]);
    return .{
        .status = params[0],
        .handle = @as(u16, params[1]) | (@as(u16, params[2]) << 8),
        .role = params[3],
        .peer_addr_type = params[4],
        .peer_addr = peer,
        .interval = @as(u16, params[11]) | (@as(u16, params[12]) << 8),
        .latency = @as(u16, params[13]) | (@as(u16, params[14]) << 8),
        .supervision_timeout = @as(u16, params[15]) | (@as(u16, params[16]) << 8),
        .master_clock_accuracy = params[17],
    };
}

/// 一个事件的完整帧：H4(1) + Event_Code(1) + Parameter_Total_Length(1) + 参数。
pub fn encodeEvent(out: []u8, code: u8, params: []const u8, stats: *Stats) Error!usize {
    if (params.len > 255) {
        stats.rejected += 1;
        return error.Oversize;
    }
    const total = 3 + params.len;
    if (out.len < total) {
        stats.rejected += 1;
        return error.NoSpace;
    }
    out[0] = h4_event;
    out[1] = code;
    out[2] = @intCast(params.len);
    @memcpy(out[3..total], params);
    return total;
}

// ---------------------------------------------------------------------------
// KAT 用的固定字节串（判据 ①② 拿它们逐字节比对）
// ---------------------------------------------------------------------------

/// ACL 头 KAT：handle=0x0042、PB=complete(0b11)、BC=point-to-point、
/// Data_Length=5 → 42 30 05 00。
///
/// 为什么第二字节是 0x30：handle 占低 12 位（0x042），PB 左移 12（0b11 << 12
/// = 0x3000），BC 左移 14（0）。0x0042 | 0x3000 = 0x3042 → 小端 42 30。
pub const kat_acl_header = [4]u8{ 0x42, 0x30, 0x05, 0x00 };

/// LE Set Advertising Enable 的 Command 包（打开广播）：
/// 01 | 0A 20 | 01 | 01。OpCode = OGF 0x08 << 10 | OCF 0x000A = 0x200A。
pub const kat_set_adv_enable = [5]u8{ 0x01, 0x0a, 0x20, 0x01, 0x01 };

/// 一条 ADV_IND 的广播数据：flags + 16-bit UUID 0x180A + Complete Local Name
/// “ch27”。逐段：02 01 06 | 03 03 0A 18 | 05 09 63 68 32 37，共 13 字节。
pub const kat_adv_data = [13]u8{
    0x02, 0x01, 0x06,
    0x03, 0x03, 0x0a,
    0x18, 0x05, 0x09,
    'c',  'h',  '2',
    '7',
};

/// 一条完整的 LE Advertising Report 参数（含 num_reports）：
///   02 | 00 00 E0 E1 E2 E3 E4 E5 | 0D | <13 字节 AD> | C0
/// num_reports=1（0x02 是 LE Meta 子事件码，这里刻意让读者注意：
/// 子事件码 0x02 与 num_reports 各占一字节，事件参数里是子事件码在前）。
pub const kat_adv_event_params = blk: {
    var p: [1 + 10 + kat_adv_data.len]u8 = undefined;
    p[0] = 0x01; // num_reports
    p[1] = 0x00; // event_type = ADV_IND
    p[2] = 0x00; // address_type = public
    p[3] = 0xe0;
    p[4] = 0xe1;
    p[5] = 0xe2;
    p[6] = 0xe3;
    p[7] = 0xe4;
    p[8] = 0xe5;
    p[9] = kat_adv_data.len; // data_len
    @memcpy(p[10 .. 10 + kat_adv_data.len], &kat_adv_data);
    p[10 + kat_adv_data.len] = 0xc0; // rssi = -64 dBm
    break :blk p;
};

/// LE Connection Complete 的参数 KAT：
/// status=0 handle=0x0042 role=0(central) peer_type=0 peer=E0:E1:E2:E3:E4:E5
/// interval=0x0006(7.5 ms) latency=0 supervision=0x00C8(2 s) mca=0。
pub const kat_conn_complete = [conn_complete_len]u8{
    0x00,
    0x42,
    0x00,
    0x00,
    0x00,
    0xe0,
    0xe1,
    0xe2,
    0xe3,
    0xe4,
    0xe5,
    0x06,
    0x00,
    0x00,
    0x00,
    0xc8,
    0x00,
    0x00,
};
