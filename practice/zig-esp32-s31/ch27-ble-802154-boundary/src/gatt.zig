//! ch27-ble-802154-boundary：GATT 服务/特征表与 CCCD 订阅。
//!
//! GATT（Generic Attribute Profile）把 ATT 的“句柄 → 值”翻译成“服务 →
//! 特征 → 描述符”。本文件只做**服务端**那半边，而且刻意做成定长表：
//!
//!   * `chars`：8 个特征的静态槽（句柄 1、2、4、5、7、8、10、11）；
//!   * `subs` ：4 个订阅槽（每个 notify 特征占一格）；
//!   * 每个特征的值最多 20 字节（这是 ATT_MTU=23 时代最保守的长度，
//!     也是本章刻意选择的“小值”上限；真实栈用 MBUF 池）。
//!
//! 句柄分配规则（Bluetooth Core Specification v5.4, Vol 3, Part G, §3.3）：
//! 每个特征至少占两个属性——Characteristic Declaration 与 Characteristic
//! Value；带通知的特征还要第三个：Client Characteristic Configuration
//! Descriptor（CCCD，UUID 0x2902，见
//! components/bt/host/nimble/nimble/nimble/host/include/host/ble_gatt.h:69
//! `BLE_GATT_DSC_CLT_CFG_UUID16 0x2902`）。
//!
//! 本章的句柄布局（`add()` 的确定性结果，自检直接断言）：
//!
//!   特征 #1（读）         声明=0x01 值=0x02
//!   特征 #2（读+通知）    声明=0x03 值=0x04 CCCD=0x05
//!   特征 #3（写）         声明=0x06 值=0x07
//!   …
//!
//! 权限位与 nimble 的 `BLE_GATT_CHR_F_*` 一一对应
//! （ble_gatt.h:133 READ、:139 WRITE、:142 NOTIFY），但本章不链接 nimble，
//! 只复刻位含义。
//!
//! 所有错误都带**确定的错误码**：句柄越界 → ATT 0x01，读无权限 → 0x02，
//! 写无权限 → 0x03；表满/订阅满/未订阅是**本地错误**，不上线（返回 null）。

const std = @import("std");
const att = @import("att.zig");

/// CCCD 的 16 位 UUID。Vol 3, Part G, §3.3.3.3。
pub const uuid_cccd: u16 = 0x2902;

/// 特征值的静态上限（字节）。
pub const value_max: usize = 20;
/// 特征表容量（固定，判据 ⑧ 打满它）。
pub const max_chars: usize = 8;
/// 订阅表容量（固定，判据 ⑥ 打满它）。
pub const max_subs: usize = 4;

/// 属性权限。位含义同 nimble 的 `BLE_GATT_CHR_F_*`。
pub const Perm = struct {
    read: bool = false,
    write: bool = false,
    notify: bool = false,

    pub fn none() Perm {
        return .{};
    }
    pub fn ro() Perm {
        return .{ .read = true };
    }
    pub fn rw() Perm {
        return .{ .read = true, .write = true };
    }
    pub fn rn() Perm {
        return .{ .read = true, .notify = true };
    }
};

/// 句柄指向的字段类型：特征值本身，还是它的 CCCD。
pub const Field = enum { value, cccd };

/// 一个特征的静态槽。
pub const Char = struct {
    uuid: u16,
    decl_handle: u16,
    value_handle: u16,
    /// 0 表示该特征没有 CCCD（不可通知）。
    cccd_handle: u16,
    perm: Perm,
    value: [value_max]u8,
    value_len: u8,
    subscribed: bool,
};

/// 本地错误。`code()` 返回 null 表示“这个错误不该出现在 ATT 线上”。
pub const Err = enum {
    invalid_handle,
    read_not_permitted,
    write_not_permitted,
    table_full,
    subs_full,
    not_subscribed,
    notify_not_permitted,
    value_too_long,
    invalid_value,

    pub fn name(self: Err) []const u8 {
        return switch (self) {
            .invalid_handle => "invalid_handle",
            .read_not_permitted => "read_not_permitted",
            .write_not_permitted => "write_not_permitted",
            .table_full => "table_full",
            .subs_full => "subs_full",
            .not_subscribed => "not_subscribed",
            .notify_not_permitted => "notify_not_permitted",
            .value_too_long => "value_too_long",
            .invalid_value => "invalid_value",
        };
    }

    /// 映射到 ATT Error Response 的错误码；null = 本地错误，不上线。
    pub fn code(self: Err) ?att.Code {
        return switch (self) {
            .invalid_handle => .invalid_handle,
            .read_not_permitted => .read_not_permitted,
            .write_not_permitted => .write_not_permitted,
            .table_full, .subs_full => .insufficient_resources,
            .not_subscribed, .notify_not_permitted => null,
            .value_too_long, .invalid_value => .invalid_pdu,
        };
    }
};

/// 处理结果：要么是该写进 out 的 PDU 长度，要么是一个待编码的错误。
pub const Reply = union(enum) {
    pdu: usize,
    err: Err,
};

/// 注册结果：分配的 value_handle，或一个带原因的拒绝。
pub const Added = union(enum) {
    handle: u16,
    err: Err,
};

/// 服务端统计。
pub const Stats = struct {
    chars_registered: u32 = 0,
    rejected: u32 = 0,
    subs: u32 = 0,
    unsubs: u32 = 0,
    notifies: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

/// 特征表（全部状态都在这里，没有任何堆）。
pub const Table = struct {
    chars: [max_chars]Char = undefined,
    count: u8 = 0,
    /// 下一个可用属性句柄。0x0001 起（0x0000 是保留的“无效句柄”）。
    next_handle: u16 = 0x0001,
    stats: Stats = .{},

    pub fn reset(self: *Table) void {
        self.count = 0;
        self.next_handle = 0x0001;
        self.stats.reset();
    }

    /// 注册一个特征。返回 value_handle。
    ///
    /// 句柄按声明/值/CCCD 顺序递增；带 notify 的特征自动多分配一个 CCCD。
    /// 表满时返回 `error`，`stats.rejected` 加一，表**不被修改**（判据 ⑧
    /// 断言 count 仍是 8）。
    pub fn add(
        self: *Table,
        uuid: u16,
        perm: Perm,
        initial: []const u8,
    ) Added {
        if (self.count >= max_chars) {
            self.stats.rejected += 1;
            return .{ .err = .table_full };
        }
        if (initial.len > value_max) {
            self.stats.rejected += 1;
            return .{ .err = .value_too_long };
        }
        const decl = self.next_handle;
        const value_handle = decl + 1;
        const cccd: u16 = if (perm.notify) value_handle + 1 else 0;

        var ch = Char{
            .uuid = uuid,
            .decl_handle = decl,
            .value_handle = value_handle,
            .cccd_handle = cccd,
            .perm = perm,
            .value = @splat(0),
            .value_len = @intCast(initial.len),
            .subscribed = false,
        };
        @memcpy(ch.value[0..initial.len], initial);

        self.chars[self.count] = ch;
        self.count += 1;
        self.next_handle = value_handle + 1 + @intFromBool(perm.notify);
        self.stats.chars_registered += 1;
        return .{ .handle = value_handle };
    }

    pub fn countOf(self: *const Table) u8 {
        return self.count;
    }

    /// 按句柄查找。句柄 0x0000 永远无效。
    pub fn resolve(self: *Table, handle: u16) ?struct { ch: *Char, field: Field } {
        if (handle == 0) return null;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const ch = &self.chars[i];
            if (ch.value_handle == handle) return .{ .ch = ch, .field = .value };
            if (ch.cccd_handle != 0 and ch.cccd_handle == handle) {
                return .{ .ch = ch, .field = .cccd };
            }
        }
        return null;
    }

    /// 处理一个 Read Request（PDU 由调用方解码好）。成功时把 Read Response
    /// 写进 out 并返回长度。
    pub fn handleRead(
        self: *Table,
        handle: u16,
        out: []u8,
        mtu: u16,
        astats: *att.Stats,
    ) Reply {
        const hit = self.resolve(handle) orelse return .{ .err = .invalid_handle };
        const ch = hit.ch;
        switch (hit.field) {
            .value => {
                if (!ch.perm.read) return .{ .err = .read_not_permitted };
                self.stats.reads += 1;
                const n = att.encodeReadRsp(out, ch.value[0..ch.value_len], mtu, astats) catch
                    return .{ .err = .value_too_long };
                return .{ .pdu = n };
            },
            // CCCD 可读，值为 2 字节订阅位。Vol 3, Part G, §3.3.3.3。
            .cccd => {
                const two = [2]u8{
                    @intFromBool(ch.subscribed),
                    0x00,
                };
                self.stats.reads += 1;
                const n = att.encodeReadRsp(out, &two, mtu, astats) catch
                    return .{ .err = .value_too_long };
                return .{ .pdu = n };
            },
        }
    }

    /// 处理一个 Write Request。成功时把 Write Response 写进 out 并返回 1。
    ///
    /// CCCD 写：值必须是 {0x01,0x00}（订阅）或 {0x00,0x00}（退订），其它长度/内容
    /// 一律 `invalid_value`。订阅表满 → `subs_full`（ATT 0x11
    /// Insufficient Resources），重复订阅不占新槽。
    pub fn handleWrite(
        self: *Table,
        handle: u16,
        data: []const u8,
        out: []u8,
        astats: *att.Stats,
    ) Reply {
        const hit = self.resolve(handle) orelse return .{ .err = .invalid_handle };
        const ch = hit.ch;
        switch (hit.field) {
            .value => {
                if (!ch.perm.write) return .{ .err = .write_not_permitted };
                if (data.len > value_max) return .{ .err = .value_too_long };
                @memcpy(ch.value[0..data.len], data);
                ch.value_len = @intCast(data.len);
                self.stats.writes += 1;
                const n = att.encodeWriteRsp(out, astats) catch return .{ .err = .invalid_value };
                return .{ .pdu = n };
            },
            .cccd => {
                if (data.len != 2) return .{ .err = .invalid_value };
                // 只接受 {0x01,0x00}（开启 Notification）与 {0x00,0x00}（关闭）；
                // 其余位（含 bit1 Indication，本章不支持）一律 invalid_value。
                if (!(data[0] == 0x00 and data[1] == 0x00) and
                    !(data[0] == 0x01 and data[1] == 0x00))
                    return .{ .err = .invalid_value };
                const on = data[0] == 0x01;
                if (on and !ch.subscribed and self.subCount() >= max_subs) {
                    self.stats.rejected += 1;
                    return .{ .err = .subs_full };
                }
                if (on and !ch.subscribed) {
                    ch.subscribed = true;
                    self.stats.subs += 1;
                } else if (!on and ch.subscribed) {
                    ch.subscribed = false;
                    self.stats.unsubs += 1;
                }
                self.stats.writes += 1;
                const n = att.encodeWriteRsp(out, astats) catch return .{ .err = .invalid_value };
                return .{ .pdu = n };
            },
        }
    }

    /// 发起一次通知（服务端内部事件，不是 ATT 请求）。未订阅 → 本地错误，
    /// 不产生任何字节（判据 ⑥ 断言源缓冲未被写过）。
    pub fn notify(
        self: *Table,
        handle: u16,
        out: []u8,
        mtu: u16,
        astats: *att.Stats,
    ) Reply {
        const hit = self.resolve(handle) orelse return .{ .err = .invalid_handle };
        const ch = hit.ch;
        if (hit.field != .value) return .{ .err = .invalid_handle };
        if (!ch.perm.notify) return .{ .err = .notify_not_permitted };
        if (!ch.subscribed) return .{ .err = .not_subscribed };
        self.stats.notifies += 1;
        const n = att.encodeNotify(out, handle, ch.value[0..ch.value_len], mtu, astats) catch
            return .{ .err = .value_too_long };
        return .{ .pdu = n };
    }

    pub fn subCount(self: *const Table) u8 {
        var n: u8 = 0;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            if (self.chars[i].subscribed) n += 1;
        }
        return n;
    }

    /// 订阅位图（最多 8 个特征，正好一字节）。日志里打印它。
    pub fn subMask(self: *const Table) u8 {
        var m: u8 = 0;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            if (self.chars[i].subscribed) m |= @as(u8, 1) << @intCast(i);
        }
        return m;
    }
};
