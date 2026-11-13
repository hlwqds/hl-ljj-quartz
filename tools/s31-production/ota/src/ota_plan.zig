//! S31 生产化切片 B：OTA 规划器（纯逻辑，不 import `std`，不依赖 IDF）。
//!
//! 本模块回答两个可以离线判定的问题：
//!
//!   1) **这次复位该启动哪个槽**：`selectSlot` 读两份 16 B 的 `otadata`
//!      条目，CRC 先过、seq 取大，再按状态白名单决定启动 A/B 还是回退
//!      factory（`Decision.slot == null`）；
//!   2) **状态该怎么迁移**：`nextState` 是纯函数，把启动次数预算、连续
//!      失败预算、确认/放弃/重新烧写这些事件映射成下一个槽状态。
//!
//! 清单准入**不在本模块**：44 B `S31M` 头的解析、签名长度下限、版本单调
//! 检查与注入式验签全部在 `manifest.zig`（唯一准入入口）。准入结论如何
//! 与选槽/状态机组合由上层负责。
//!
//! 所有缓冲都是调用方的切片；本模块不分配、不写 flash、不读时钟。
//!
//! 线上格式（`otadata` 条目，16 B）：
//!
//!   | 偏移  | 字段     | 说明                                        |
//!   |-------|----------|---------------------------------------------|
//!   | 0..4  | magic    | `S31B`，用来区分空白 flash（全 0xFF）       |
//!   | 4..8  | seq      | u32 LE，越大越新；回绕不特殊处理             |
//!   | 8     | slot     | 0=A，1=B                                    |
//!   | 9     | state    | 0=new,1=pending,2=valid,3=invalid,4=aborted |
//!   | 10..12| reserved | 必须为 0                                    |
//!   | 12..16| crc32    | CRC-32/ISO-HDLC，覆盖 [0,12)                |

pub const Slot = enum(u1) { a = 0, b = 1 };

/// 与 `esp_ota_img_states_t` 的语义对齐，但去掉了 undefined：
/// 本切片只承认这五个值，其他字节一律视为坏条目。
pub const SlotState = enum(u8) {
    new = 0x0,
    pending = 0x1,
    valid = 0x2,
    invalid = 0x3,
    aborted = 0x4,
};

pub const Reason = enum {
    /// 选中槽状态可启动。
    ok,
    /// 两个扇区都过不了长度/magic/reserved/CRC 校验（含空白 flash）。
    no_valid_sector,
    /// 选出了 seq 最大的条目，但它的状态不允许启动（回退 factory）。
    state_not_bootable,
};

pub const Decision = struct {
    slot: ?Slot,
    reason: Reason,
};

// ---------------------------------------------------------------------------
// otadata 条目
// ---------------------------------------------------------------------------

pub const entry_len: usize = 16;
pub const entry_magic = [4]u8{ 'S', '3', '1', 'B' };

pub const Entry = struct {
    seq: u32,
    slot: Slot,
    state: SlotState,
};

pub const EntryError = error{
    Short,
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

fn magicIs(bytes: []const u8, magic: [4]u8) bool {
    return bytes[0] == magic[0] and
        bytes[1] == magic[1] and
        bytes[2] == magic[2] and
        bytes[3] == magic[3];
}

/// CRC-32/ISO-HDLC（反射多项式 0xEDB88320，初值与最终异或均为 0xFFFFFFFF）。
///
/// 逐位实现而不是用 `std.hash.Crc32`：本模块刻意不 import `std`，
/// 这样同一份代码在 freestanding 目标上不需要任何标准库支持。
/// 条目只有 12 个有效字节，逐位也谈不上慢。
pub fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (bytes) |b| {
        crc ^= b;
        var bit: u5 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB88320 & mask);
        }
    }
    return ~crc;
}

/// 编码一个 16 B 条目（工具/测试/上位机侧使用；bootloader 只读）。
pub fn encodeEntry(out: []u8, entry: Entry) EntryError!usize {
    if (out.len < entry_len) return error.Short;
    @memcpy(out[0..4], &entry_magic);
    writeU32Le(out[4..8], entry.seq);
    out[8] = @intFromEnum(entry.slot);
    out[9] = @intFromEnum(entry.state);
    out[10] = 0;
    out[11] = 0;
    writeU32Le(out[12..16], crc32(out[0..12]));
    return entry_len;
}

/// 严格解码：任何一项不合格都返回具体错误，调用方据此丢弃整个扇区。
/// 只读前 16 字节，允许传入整个 4 KiB flash 扇区的切片。
pub fn decodeEntry(bytes: []const u8) EntryError!Entry {
    if (bytes.len < entry_len) return error.Short;
    if (!magicIs(bytes[0..4], entry_magic)) return error.BadMagic;
    if (bytes[10] != 0 or bytes[11] != 0) return error.BadReserved;
    if (bytes[8] > @intFromEnum(Slot.b)) return error.BadSlot;
    if (bytes[9] > @intFromEnum(SlotState.aborted)) return error.BadState;
    if (readU32Le(bytes[12..16]) != crc32(bytes[0..12])) return error.BadCrc;
    return .{
        .seq = readU32Le(bytes[4..8]),
        .slot = if (bytes[8] == 0) .a else .b,
        .state = @enumFromInt(bytes[9]),
    };
}

/// 选择逻辑本身：先各自解码（CRC 在解码里已过），再取 seq 最大者；
/// seq 相同取 `otadata_a`（下标小者），避免每次复位随机换槽。
/// 只返回有效条目，双坏返回 null。
pub fn pickEntry(otadata_a: []const u8, otadata_b: []const u8) ?Entry {
    var best: ?Entry = null;
    if (decodeEntry(otadata_a)) |entry| {
        best = entry;
    } else |_| {}
    if (decodeEntry(otadata_b)) |entry| {
        if (best == null or entry.seq > best.?.seq) best = entry;
    } else |_| {}
    return best;
}

/// bootloader 级决策：选中槽必须是 `valid` 或 `pending`；其余状态
/// （new / invalid / aborted）一律不尝试，返回 `slot == null` 让调用方
/// 落到 factory。`reason` 区分“没读到好条目”和“读到了但不让启动”。
pub fn selectSlot(otadata_a: []const u8, otadata_b: []const u8) Decision {
    const entry = pickEntry(otadata_a, otadata_b) orelse
        return .{ .slot = null, .reason = .no_valid_sector };
    if (!canBoot(entry.state)) {
        return .{ .slot = null, .reason = .state_not_bootable };
    }
    return .{ .slot = entry.slot, .reason = .ok };
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

/// `boot` 的载荷：本次是第几次启动，以及允许启动的总次数。
/// 语义：`attempt > budget` 判超预算。budget=2 时允许第 1、2 次启动，
/// 第 3 次复位进 bootloader 即判 aborted。
pub const Attempt = struct {
    attempt: u8,
    budget: u8,
};

/// `fail` 的载荷：含本次在内的连续失败次数，以及容忍上限。
/// 语义：`consecutive >= budget` 判超预算。budget=3 时前两次失败仍留在
/// 原状态，第三次失败才转 invalid。
pub const Failure = struct {
    consecutive: u8,
    budget: u8,
};

pub const Event = union(enum) {
    /// 该槽已被写入一份新镜像（物理上应写非活动槽）。
    stage,
    /// 把 `new` 槽写进 otadata，下一次复位由 bootloader 选中它。
    set_boot,
    /// 复位后 bootloader 选中该槽并启动了一次。
    boot: Attempt,
    /// 应用自检通过，确认该槽。
    confirm,
    /// 运行期一次失败（自检不过/看门狗复位/关键任务挂死）。
    fail: Failure,
    /// 上层主动放弃该槽（例如清单被撤销）。
    abort,
};

/// 只有 `valid` 与 `pending` 可启动；`new` 尚未通过任何启动验证，
/// `invalid`/`aborted` 是失败结论，都不能再试。
pub fn canBoot(state: SlotState) bool {
    return switch (state) {
        .pending, .valid => true,
        .new, .invalid, .aborted => false,
    };
}

/// 纯状态迁移。计数器不进状态（本模块不持久化），由调用方放在事件里；
/// 这样同一个函数既能用于启动期（只读 otadata），也能用于运行期自检。
///
/// | 当前    | stage | set_boot | boot            | confirm | fail                    | abort   |
/// |---------|-------|----------|-----------------|---------|-------------------------|---------|
/// | new     | new   | pending  | new（未选中）    | new     | new                     | aborted |
/// | pending | new   | 不变     | pending/aborted | valid   | pending（预算内）/invalid | aborted |
/// | valid   | new   | 不变     | valid           | valid   | valid（预算内）/invalid   | aborted |
/// | invalid | new   | 不变     | invalid         | invalid | invalid                 | invalid |
/// | aborted | new   | 不变     | aborted         | aborted | aborted                 | aborted |
///
/// - `stage` 表示“该槽已被覆盖写”，旧判定一律失效，统一回到 `new`；
/// - 调用方必须只对**非活动槽** stage；本模块不知道当前 active 槽，
///   覆盖运行中的分区由上层拒绝（真实实现会拒绝擦除运行中的分区）。
pub fn nextState(state: SlotState, event: Event) SlotState {
    return switch (event) {
        .stage => .new,
        .set_boot => switch (state) {
            .new => .pending,
            .pending, .valid => state,
            .invalid, .aborted => state,
        },
        .boot => |a| switch (state) {
            .pending => if (a.attempt > a.budget) .aborted else .pending,
            .valid => .valid,
            .new => .new, // 未写 otadata 的槽不会被 bootloader 选中
            .invalid, .aborted => state,
        },
        .confirm => switch (state) {
            .pending, .valid => .valid,
            .new, .invalid, .aborted => state,
        },
        .fail => |f| switch (state) {
            .pending, .valid => if (f.consecutive >= f.budget) .invalid else state,
            .new, .invalid, .aborted => state,
        },
        .abort => switch (state) {
            .new, .pending, .valid => .aborted,
            .invalid, .aborted => state,
        },
    };
}
