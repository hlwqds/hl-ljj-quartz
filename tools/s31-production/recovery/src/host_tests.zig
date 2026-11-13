//! S31 生产化第二增量：故障恢复策略的主机侧测试（`zig build test` 的入口）。
//!
//! 只在 x86_64 主机上跑：不读复位原因寄存器、不读 RTC、不碰 flash、不触发复位。
//! **本次交付未执行**；断言按“可编译、失败可定位”写死，交给主线统一跑。
//!
//! 覆盖范围（对应 SPEC §3.7 的验收）：
//!   - 阈值边界：`failures == threshold` 触发、`threshold - 1` 不触发；
//!   - `threshold == 0` 按 1 处理（干净启动不误判）、`threshold == 255` 的 u8 上限；
//!   - 七个 `ResetReason` 在阈值以下的完整映射；
//!   - `after_rollback` 再次失败的升级路径（回滚后无路可退 → 恢复出厂）；
//!   - 优先级冲突：达阈值压过复位原因，`rollback`/`factory_reset` 压过 `safe_mode`；
//!   - 7 原因 × 2 相位 × 4 计数档的决策矩阵。

const std = @import("std");
const recovery = @import("recovery.zig");

const ResetReason = recovery.ResetReason;
const Phase = recovery.Phase;
const Decision = recovery.Decision;

/// 一条判定用例。`label` 只用于失败时定位，不参与逻辑。
const Case = struct {
    label: []const u8,
    reason: ResetReason,
    failures: u8,
    threshold: u8,
    phase: Phase,
    want: Decision,
};

/// 跑一条用例；失败时先打印完整输入，再交给 `expectEqual` 断言。
fn check(c: Case) !void {
    const got = recovery.classify(c.reason, c.failures, c.threshold, c.phase);
    if (got != c.want) {
        std.debug.print(
            "recovery[{s}]: classify({s}, {d}, {d}, {s}) = {s}，期望 {s}\n",
            .{
                c.label,
                @tagName(c.reason),
                c.failures,
                c.threshold,
                @tagName(c.phase),
                @tagName(got),
                @tagName(c.want),
            },
        );
    }
    try std.testing.expectEqual(c.want, got);
}

fn runTable(cases: []const Case) !void {
    for (cases) |c| try check(c);
}

// ---------------------------------------------------------------------------
// 阈值边界
// ---------------------------------------------------------------------------

test "threshold boundary: equal to threshold triggers, one below does not" {
    // threshold = 3：0、2 不触发，3 触发，4/255 仍然触发（不因超过而改变结论）。
    const cases = [_]Case{
        .{ .label = "0/3 首次启动", .reason = .power_on, .failures = 0, .threshold = 3, .phase = .first_boot, .want = .normal },
        .{ .label = "2/3 首次启动", .reason = .power_on, .failures = 2, .threshold = 3, .phase = .first_boot, .want = .normal },
        .{ .label = "3/3 首次启动", .reason = .power_on, .failures = 3, .threshold = 3, .phase = .first_boot, .want = .rollback },
        .{ .label = "4/3 首次启动", .reason = .power_on, .failures = 4, .threshold = 3, .phase = .first_boot, .want = .rollback },
        .{ .label = "255/3 首次启动", .reason = .power_on, .failures = 255, .threshold = 3, .phase = .first_boot, .want = .rollback },
        .{ .label = "2/3 回滚后", .reason = .power_on, .failures = 2, .threshold = 3, .phase = .after_rollback, .want = .normal },
        .{ .label = "3/3 回滚后", .reason = .power_on, .failures = 3, .threshold = 3, .phase = .after_rollback, .want = .factory_reset },
        .{ .label = "255/3 回滚后", .reason = .power_on, .failures = 255, .threshold = 3, .phase = .after_rollback, .want = .factory_reset },
    };
    try runTable(cases[0..]);
}

test "threshold zero clamps to one" {
    // threshold = 0 视为 1：0 次失败不触发，1 次失败触发。
    const cases = [_]Case{
        .{ .label = "0 次失败/阈值 0，首次启动", .reason = .power_on, .failures = 0, .threshold = 0, .phase = .first_boot, .want = .normal },
        .{ .label = "0 次失败/阈值 0，回滚后", .reason = .unknown, .failures = 0, .threshold = 0, .phase = .after_rollback, .want = .normal },
        .{ .label = "1 次失败/阈值 0，首次启动", .reason = .power_on, .failures = 1, .threshold = 0, .phase = .first_boot, .want = .rollback },
        .{ .label = "1 次失败/阈值 0，回滚后", .reason = .unknown, .failures = 1, .threshold = 0, .phase = .after_rollback, .want = .factory_reset },
        .{ .label = "panic 且 0 次失败", .reason = .panic, .failures = 0, .threshold = 0, .phase = .first_boot, .want = .safe_mode },
        .{ .label = "brownout 且 0 次失败、回滚后", .reason = .brownout, .failures = 0, .threshold = 0, .phase = .after_rollback, .want = .safe_mode },
        .{ .label = "非零失败/阈值 0", .reason = .software, .failures = 9, .threshold = 0, .phase = .first_boot, .want = .rollback },
    };
    try runTable(cases[0..]);
}

test "threshold 255 keeps exact-boundary behaviour at the u8 limit" {
    const cases = [_]Case{
        .{ .label = "254/255", .reason = .power_on, .failures = 254, .threshold = 255, .phase = .first_boot, .want = .normal },
        .{ .label = "254/255 panic", .reason = .panic, .failures = 254, .threshold = 255, .phase = .first_boot, .want = .safe_mode },
        .{ .label = "255/255", .reason = .power_on, .failures = 255, .threshold = 255, .phase = .first_boot, .want = .rollback },
        .{ .label = "255/255 回滚后", .reason = .power_on, .failures = 255, .threshold = 255, .phase = .after_rollback, .want = .factory_reset },
    };
    try runTable(cases[0..]);
}

// ---------------------------------------------------------------------------
// 各复位原因
// ---------------------------------------------------------------------------

test "every reset reason is classified below threshold in both phases" {
    const reasons = [_]ResetReason{ .power_on, .panic, .watchdog, .brownout, .ota_rollback, .software, .unknown };
    // 未达阈值时只看原因：panic/watchdog/brownout → safe_mode，其余 → normal。
    // 相位在这一档不影响结论（阈值以上才由相位接管）。
    const expected = [_]Decision{ .normal, .safe_mode, .safe_mode, .safe_mode, .normal, .normal, .normal };

    const phases = [_]Phase{ .first_boot, .after_rollback };
    for (phases) |phase| {
        for (reasons, 0..) |reason, i| {
            try check(.{
                .label = "原因映射（未达阈值）",
                .reason = reason,
                .failures = 2,
                .threshold = 3,
                .phase = phase,
                .want = expected[i],
            });
        }
    }
}

// ---------------------------------------------------------------------------
// 回滚后再次失败
// ---------------------------------------------------------------------------

test "another failure streak after rollback goes to factory reset for every reason" {
    // 回滚后的镜像没有下一个槽可退：同一组输入在 first_boot 得到 rollback，
    // 在 after_rollback 必须升级为 factory_reset，且不受复位原因影响。
    const reasons = [_]ResetReason{ .power_on, .panic, .watchdog, .brownout, .ota_rollback, .software, .unknown };
    for (reasons) |reason| {
        try check(.{
            .label = "回滚后再次达阈值",
            .reason = reason,
            .failures = 2,
            .threshold = 2,
            .phase = .after_rollback,
            .want = .factory_reset,
        });
        try check(.{
            .label = "同输入首次启动",
            .reason = reason,
            .failures = 2,
            .threshold = 2,
            .phase = .first_boot,
            .want = .rollback,
        });
    }
}

// ---------------------------------------------------------------------------
// 优先级冲突
// ---------------------------------------------------------------------------

test "priority: streak outranks reset reason, factory reset outranks rollback" {
    const cases = [_]Case{
        // 第 2 条压过第 3 条：达阈值时 panic 不导向 safe_mode。
        .{ .label = "panic 达阈值", .reason = .panic, .failures = 1, .threshold = 1, .phase = .first_boot, .want = .rollback },
        // 第 1 条压过第 2/3 条：回滚后达阈值直接恢复出厂。
        .{ .label = "panic 达阈值且回滚后", .reason = .panic, .failures = 1, .threshold = 1, .phase = .after_rollback, .want = .factory_reset },
        // 第 3 条在两相位都不受相位影响：未达阈值就只按原因降级。
        .{ .label = "brownout 未达阈值", .reason = .brownout, .failures = 0, .threshold = 1, .phase = .first_boot, .want = .safe_mode },
        .{ .label = "brownout 未达阈值且回滚后", .reason = .brownout, .failures = 0, .threshold = 1, .phase = .after_rollback, .want = .safe_mode },
        // ota_rollback 原因本身不触发任何恢复：回滚是正常恢复动作。
        .{ .label = "ota_rollback 未达阈值", .reason = .ota_rollback, .failures = 0, .threshold = 1, .phase = .first_boot, .want = .normal },
        .{ .label = "ota_rollback 未达阈值且回滚后", .reason = .ota_rollback, .failures = 0, .threshold = 1, .phase = .after_rollback, .want = .normal },
        .{ .label = "software 未达阈值且回滚后", .reason = .software, .failures = 0, .threshold = 2, .phase = .after_rollback, .want = .normal },
    };
    try runTable(cases[0..]);
}

// ---------------------------------------------------------------------------
// 决策矩阵
// ---------------------------------------------------------------------------

test "decision matrix: 7 reasons x 2 phases x 4 failure levels" {
    const reasons = [_]ResetReason{ .power_on, .panic, .watchdog, .brownout, .ota_rollback, .software, .unknown };

    // 未达阈值（0、2）→ 按原因。
    const below = [_]Decision{ .normal, .safe_mode, .safe_mode, .safe_mode, .normal, .normal, .normal };
    // 达阈值（3、4）→ 只按相位。
    const at_first = [_]Decision{ .rollback, .rollback, .rollback, .rollback, .rollback, .rollback, .rollback };
    const at_after = [_]Decision{ .factory_reset, .factory_reset, .factory_reset, .factory_reset, .factory_reset, .factory_reset, .factory_reset };

    const levels = [_]u8{ 0, 2, 3, 4 };
    for (levels) |failures| {
        const reached = failures >= 3;
        for (reasons, 0..) |reason, i| {
            const want_first: Decision = if (reached) at_first[i] else below[i];
            const want_after: Decision = if (reached) at_after[i] else below[i];

            try check(.{
                .label = "矩阵 first_boot",
                .reason = reason,
                .failures = failures,
                .threshold = 3,
                .phase = .first_boot,
                .want = want_first,
            });
            try check(.{
                .label = "矩阵 after_rollback",
                .reason = reason,
                .failures = failures,
                .threshold = 3,
                .phase = .after_rollback,
                .want = want_after,
            });
        }
    }
}

// ---------------------------------------------------------------------------
// 细化接口
// ---------------------------------------------------------------------------

test "needsSafeMode admits exactly panic, watchdog and brownout" {
    try std.testing.expect(recovery.needsSafeMode(.panic));
    try std.testing.expect(recovery.needsSafeMode(.watchdog));
    try std.testing.expect(recovery.needsSafeMode(.brownout));

    try std.testing.expect(!recovery.needsSafeMode(.power_on));
    try std.testing.expect(!recovery.needsSafeMode(.ota_rollback));
    try std.testing.expect(!recovery.needsSafeMode(.software));
    try std.testing.expect(!recovery.needsSafeMode(.unknown));
}

test "initial phase is first_boot" {
    try std.testing.expectEqual(Phase.first_boot, recovery.initialPhase());
}
