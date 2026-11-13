//! S31 生产化切片 B：OTA 规划器的主机侧测试（`zig build test` 的入口）。
//!
//! 这些测试只在 x86_64 主机上跑，不打开串口、不写 flash、不接触 IDF。
//! **本次交付未执行**；测试按“可编译、断言明确”写死，留给主线统一跑。
//!
//! 覆盖范围（对应 SPEC §3.2 的验收）：
//!   - CRC-32 已知答案、条目往返、坏字节拒绝；
//!   - magic/reserved/slot/state/长度等字段校验；
//!   - 双扇区选择：seq 取大、平手取 A、单坏扇区容错、双坏回退；
//!   - 状态白名单：只有 pending/valid 可启动；
//!   - 启动次数预算、连续失败回滚、终态粘性与重烧复活；
//!   - 回滚后重写 otadata 指向存活槽。
//!
//! 清单准入（版本单调、注入式验签、签名长度）由 `manifest_tests.zig`
//! 覆盖；本文件不再保留 v0 清单校验的任何断言或替身。

const std = @import("std");
const ota = @import("ota_plan.zig");

// ---------------------------------------------------------------------------
// CRC 与条目格式
// ---------------------------------------------------------------------------

test "crc32 known answer (CRC-32/ISO-HDLC check value)" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), ota.crc32("123456789"));
}

test "entry encode/decode roundtrip" {
    var buf: [ota.entry_len]u8 = undefined;
    const written = try ota.encodeEntry(&buf, .{ .seq = 7, .slot = .b, .state = .pending });

    try std.testing.expectEqual(ota.entry_len, written);
    const entry = try ota.decodeEntry(buf[0..]);
    try std.testing.expectEqual(@as(u32, 7), entry.seq);
    try std.testing.expectEqual(ota.Slot.b, entry.slot);
    try std.testing.expectEqual(ota.SlotState.pending, entry.state);
}

test "entry rejects content corruption via CRC" {
    var buf: [ota.entry_len]u8 = undefined;
    _ = try ota.encodeEntry(&buf, .{ .seq = 1, .slot = .a, .state = .valid });

    buf[5] ^= 0x01;
    try std.testing.expectError(error.BadCrc, ota.decodeEntry(buf[0..]));
}

test "entry rejects short, blank, reserved, bad slot and bad state" {
    const blank: [ota.entry_len]u8 = @splat(0xFF);
    try std.testing.expectError(error.BadMagic, ota.decodeEntry(blank[0..]));
    try std.testing.expectError(error.Short, ota.decodeEntry(blank[0 .. ota.entry_len - 1]));

    var buf: [ota.entry_len]u8 = undefined;
    _ = try ota.encodeEntry(&buf, .{ .seq = 1, .slot = .a, .state = .valid });
    buf[10] = 1;
    try std.testing.expectError(error.BadReserved, ota.decodeEntry(buf[0..]));

    _ = try ota.encodeEntry(&buf, .{ .seq = 1, .slot = .a, .state = .valid });
    buf[8] = 2;
    try std.testing.expectError(error.BadSlot, ota.decodeEntry(buf[0..]));

    _ = try ota.encodeEntry(&buf, .{ .seq = 1, .slot = .a, .state = .valid });
    buf[9] = 5;
    try std.testing.expectError(error.BadState, ota.decodeEntry(buf[0..]));
}

// ---------------------------------------------------------------------------
// 双扇区选择
// ---------------------------------------------------------------------------

test "selectSlot picks the highest sequence" {
    var a: [ota.entry_len]u8 = undefined;
    var b: [ota.entry_len]u8 = undefined;
    _ = try ota.encodeEntry(&a, .{ .seq = 9, .slot = .a, .state = .valid });
    _ = try ota.encodeEntry(&b, .{ .seq = 10, .slot = .b, .state = .pending });

    const decision = ota.selectSlot(a[0..], b[0..]);
    try std.testing.expectEqual(ota.Slot.b, decision.slot.?);
    try std.testing.expectEqual(ota.Reason.ok, decision.reason);

    // 反过来传参也应按 seq 选，而不是按参数位置选。
    const swapped = ota.selectSlot(b[0..], a[0..]);
    try std.testing.expectEqual(ota.Slot.b, swapped.slot.?);
}

test "equal sequence prefers sector a" {
    var a: [ota.entry_len]u8 = undefined;
    var b: [ota.entry_len]u8 = undefined;
    _ = try ota.encodeEntry(&a, .{ .seq = 5, .slot = .a, .state = .valid });
    _ = try ota.encodeEntry(&b, .{ .seq = 5, .slot = .b, .state = .valid });

    const decision = ota.selectSlot(a[0..], b[0..]);
    try std.testing.expectEqual(ota.Slot.a, decision.slot.?);
}

test "one bad sector falls back to the other, two bad sectors fall back to factory" {
    var good: [ota.entry_len]u8 = undefined;
    var bad: [ota.entry_len]u8 = undefined;
    _ = try ota.encodeEntry(&good, .{ .seq = 3, .slot = .a, .state = .valid });
    _ = try ota.encodeEntry(&bad, .{ .seq = 4, .slot = .b, .state = .valid });

    // 高 seq 的扇区 CRC 坏：丢掉它，用另一个。
    bad[12] ^= 0xFF;
    const single = ota.selectSlot(good[0..], bad[0..]);
    try std.testing.expectEqual(ota.Slot.a, single.slot.?);
    try std.testing.expectEqual(ota.Reason.ok, single.reason);

    // 另一个也坏：没有任何可读条目。
    good[15] ^= 0xFF;
    const both = ota.selectSlot(good[0..], bad[0..]);
    try std.testing.expect(both.slot == null);
    try std.testing.expectEqual(ota.Reason.no_valid_sector, both.reason);
}

test "blank flash never boots anything" {
    const blank: [ota.entry_len]u8 = @splat(0xFF);
    const decision = ota.selectSlot(blank[0..], blank[0..]);
    try std.testing.expect(decision.slot == null);
    try std.testing.expectEqual(ota.Reason.no_valid_sector, decision.reason);
}

// ---------------------------------------------------------------------------
// 状态白名单
// ---------------------------------------------------------------------------

test "canBoot only admits pending and valid" {
    try std.testing.expect(ota.canBoot(.pending));
    try std.testing.expect(ota.canBoot(.valid));
    try std.testing.expect(!ota.canBoot(.new));
    try std.testing.expect(!ota.canBoot(.invalid));
    try std.testing.expect(!ota.canBoot(.aborted));
}

test "selectSlot refuses new, invalid and aborted entries" {
    var sector: [ota.entry_len]u8 = undefined;
    const blank: [ota.entry_len]u8 = @splat(0xFF);

    for ([_]ota.SlotState{ .new, .invalid, .aborted }) |state| {
        _ = try ota.encodeEntry(&sector, .{ .seq = 1, .slot = .b, .state = state });
        const decision = ota.selectSlot(sector[0..], blank[0..]);
        try std.testing.expect(decision.slot == null);
        try std.testing.expectEqual(ota.Reason.state_not_bootable, decision.reason);
    }

    for ([_]ota.SlotState{ .pending, .valid }) |state| {
        _ = try ota.encodeEntry(&sector, .{ .seq = 1, .slot = .b, .state = state });
        const decision = ota.selectSlot(blank[0..], sector[0..]);
        try std.testing.expectEqual(ota.Slot.b, decision.slot.?);
        try std.testing.expectEqual(ota.Reason.ok, decision.reason);
    }
}

// ---------------------------------------------------------------------------
// 状态机：启动预算 / 失败回滚 / 终态
// ---------------------------------------------------------------------------

test "pending boot budget aborts after the allowed attempts" {
    // budget=2：第 1、2 次启动留在 pending，第 3 次判 aborted。
    try std.testing.expectEqual(
        ota.SlotState.pending,
        ota.nextState(.pending, .{ .boot = .{ .attempt = 1, .budget = 2 } }),
    );
    try std.testing.expectEqual(
        ota.SlotState.pending,
        ota.nextState(.pending, .{ .boot = .{ .attempt = 2, .budget = 2 } }),
    );
    try std.testing.expectEqual(
        ota.SlotState.aborted,
        ota.nextState(.pending, .{ .boot = .{ .attempt = 3, .budget = 2 } }),
    );
}

test "zero boot budget aborts the first boot" {
    try std.testing.expectEqual(
        ota.SlotState.aborted,
        ota.nextState(.pending, .{ .boot = .{ .attempt = 1, .budget = 0 } }),
    );
}

test "stage then set_boot is the only path from new to pending" {
    try std.testing.expectEqual(ota.SlotState.new, ota.nextState(.new, .stage));
    try std.testing.expectEqual(ota.SlotState.pending, ota.nextState(.new, .set_boot));
    try std.testing.expectEqual(
        ota.SlotState.new,
        ota.nextState(.new, .{ .boot = .{ .attempt = 1, .budget = 2 } }),
    );
    try std.testing.expectEqual(ota.SlotState.pending, ota.nextState(.pending, .set_boot));
}

test "consecutive failures roll pending and valid slots to invalid" {
    // budget=3：前两次失败仍留在原状态，第三次才回滚。
    try std.testing.expectEqual(
        ota.SlotState.pending,
        ota.nextState(.pending, .{ .fail = .{ .consecutive = 2, .budget = 3 } }),
    );
    try std.testing.expectEqual(
        ota.SlotState.invalid,
        ota.nextState(.pending, .{ .fail = .{ .consecutive = 3, .budget = 3 } }),
    );
    try std.testing.expectEqual(
        ota.SlotState.valid,
        ota.nextState(.valid, .{ .fail = .{ .consecutive = 2, .budget = 3 } }),
    );
    try std.testing.expectEqual(
        ota.SlotState.invalid,
        ota.nextState(.valid, .{ .fail = .{ .consecutive = 3, .budget = 3 } }),
    );
}

test "terminal states stay unbootable until restaged" {
    for ([_]ota.SlotState{ .invalid, .aborted }) |state| {
        try std.testing.expectEqual(
            state,
            ota.nextState(state, .{ .boot = .{ .attempt = 1, .budget = 4 } }),
        );
        try std.testing.expectEqual(state, ota.nextState(state, .confirm));
        try std.testing.expectEqual(
            state,
            ota.nextState(state, .{ .fail = .{ .consecutive = 9, .budget = 3 } }),
        );
        try std.testing.expectEqual(state, ota.nextState(state, .abort));
        try std.testing.expectEqual(ota.SlotState.new, ota.nextState(state, .stage));
        try std.testing.expect(!ota.canBoot(state));
    }
}

test "confirm and abort transitions" {
    try std.testing.expectEqual(ota.SlotState.valid, ota.nextState(.pending, .confirm));
    try std.testing.expectEqual(ota.SlotState.valid, ota.nextState(.valid, .confirm));
    try std.testing.expectEqual(ota.SlotState.new, ota.nextState(.new, .confirm));

    try std.testing.expectEqual(ota.SlotState.aborted, ota.nextState(.new, .abort));
    try std.testing.expectEqual(ota.SlotState.aborted, ota.nextState(.pending, .abort));
    try std.testing.expectEqual(ota.SlotState.aborted, ota.nextState(.valid, .abort));

    // stage 是覆盖写：旧判定作废，即使目标槽曾是 valid/pending。
    try std.testing.expectEqual(ota.SlotState.new, ota.nextState(.valid, .stage));
    try std.testing.expectEqual(ota.SlotState.new, ota.nextState(.pending, .stage));
    try std.testing.expectEqual(ota.SlotState.new, ota.nextState(.new, .stage));
}

test "rollback re-points otadata at the surviving slot" {
    var failed_b: [ota.entry_len]u8 = undefined;
    var good_a: [ota.entry_len]u8 = undefined;
    _ = try ota.encodeEntry(&failed_b, .{ .seq = 21, .slot = .b, .state = .invalid });
    _ = try ota.encodeEntry(&good_a, .{ .seq = 20, .slot = .a, .state = .valid });

    // 最高 seq 指向已判 invalid 的 B：不做“跳到 A 试试”，直接回 factory。
    const before = ota.selectSlot(good_a[0..], failed_b[0..]);
    try std.testing.expect(before.slot == null);
    try std.testing.expectEqual(ota.Reason.state_not_bootable, before.reason);

    // 上层完成回滚：把 A 写成更高 seq 的 otadata 条目。
    var promoted_a: [ota.entry_len]u8 = undefined;
    _ = try ota.encodeEntry(&promoted_a, .{ .seq = 22, .slot = .a, .state = .valid });
    const after = ota.selectSlot(promoted_a[0..], failed_b[0..]);
    try std.testing.expectEqual(ota.Slot.a, after.slot.?);
    try std.testing.expectEqual(ota.Reason.ok, after.reason);
}

test "encodeEntry rejects a buffer that is too short" {
    var small: [ota.entry_len - 1]u8 = undefined;
    const bytes: []u8 = &small;
    try std.testing.expectError(
        error.Short,
        ota.encodeEntry(bytes, .{ .seq = 1, .slot = .a, .state = .new }),
    );
}
