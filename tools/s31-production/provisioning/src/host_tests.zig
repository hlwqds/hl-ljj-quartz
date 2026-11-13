//! provisioning 的主机侧单元测试（x86_64，不涉硬件、不涉射频）。
//!
//! 方式：一张覆盖 7 状态 × 9 事件的完整迁移表 + 按语义命名的用例 + 全表不变量。
//! 迁移表保证没有漏格；不变量保证「为什么这么迁移」不会被后来的改动悄悄破坏。

const std = @import("std");
const provisioning = @import("provisioning.zig");

const State = provisioning.State;
const Event = provisioning.Event;
const Action = provisioning.Action;

const all_states = [_]State{ .idle, .ap, .awaiting_proof, .credentials, .connecting, .connected, .failed };

const all_events = [_]Event{
    .start,
    .client_joined,
    .proof_ok,
    .proof_fail,
    .creds_ok,
    .connect_ok,
    .connect_fail,
    .timeout,
    .cancel,
};

/// 全量迁移表的一行：给定 state/event，必须得到 next/action。
const Case = struct {
    state: State,
    event: Event,
    next: State,
    action: Action,
};

/// 7 × 9 = 63 行，与 src/provisioning.zig 的迁移表逐格对应。
const table = [_]Case{
    // ---- idle：只认 start ----
    .{ .state = .idle, .event = .start, .next = .ap, .action = .start_ap },
    .{ .state = .idle, .event = .client_joined, .next = .idle, .action = .none },
    .{ .state = .idle, .event = .proof_ok, .next = .idle, .action = .none },
    .{ .state = .idle, .event = .proof_fail, .next = .idle, .action = .none },
    .{ .state = .idle, .event = .creds_ok, .next = .idle, .action = .none },
    .{ .state = .idle, .event = .connect_ok, .next = .idle, .action = .none },
    .{ .state = .idle, .event = .connect_fail, .next = .idle, .action = .none },
    .{ .state = .idle, .event = .timeout, .next = .idle, .action = .none },
    // idle 下 cancel 是空操作：没有上下文可拆，不应返回 reset。
    .{ .state = .idle, .event = .cancel, .next = .idle, .action = .none },

    // ---- ap：等客户端接入 ----
    .{ .state = .ap, .event = .start, .next = .ap, .action = .none },
    .{ .state = .ap, .event = .client_joined, .next = .awaiting_proof, .action = .prompt_proof },
    .{ .state = .ap, .event = .proof_ok, .next = .ap, .action = .none },
    .{ .state = .ap, .event = .proof_fail, .next = .ap, .action = .none },
    .{ .state = .ap, .event = .creds_ok, .next = .ap, .action = .none },
    .{ .state = .ap, .event = .connect_ok, .next = .ap, .action = .none },
    .{ .state = .ap, .event = .connect_fail, .next = .ap, .action = .none },
    .{ .state = .ap, .event = .timeout, .next = .idle, .action = .stop_ap },
    .{ .state = .ap, .event = .cancel, .next = .idle, .action = .stop_ap },

    // ---- awaiting_proof：等 PoP 证明 ----
    .{ .state = .awaiting_proof, .event = .start, .next = .awaiting_proof, .action = .none },
    .{ .state = .awaiting_proof, .event = .client_joined, .next = .awaiting_proof, .action = .none },
    .{ .state = .awaiting_proof, .event = .proof_ok, .next = .credentials, .action = .none },
    .{ .state = .awaiting_proof, .event = .proof_fail, .next = .failed, .action = .stop_ap },
    // 没证明就送凭据：忽略，既不前进也不保存。
    .{ .state = .awaiting_proof, .event = .creds_ok, .next = .awaiting_proof, .action = .none },
    .{ .state = .awaiting_proof, .event = .connect_ok, .next = .awaiting_proof, .action = .none },
    .{ .state = .awaiting_proof, .event = .connect_fail, .next = .awaiting_proof, .action = .none },
    .{ .state = .awaiting_proof, .event = .timeout, .next = .failed, .action = .stop_ap },
    .{ .state = .awaiting_proof, .event = .cancel, .next = .idle, .action = .stop_ap },

    // ---- credentials：等 STA 凭据 ----
    .{ .state = .credentials, .event = .start, .next = .credentials, .action = .none },
    .{ .state = .credentials, .event = .client_joined, .next = .credentials, .action = .none },
    .{ .state = .credentials, .event = .proof_ok, .next = .credentials, .action = .none },
    // 证明已通过，迟到的失败不打回 failed。
    .{ .state = .credentials, .event = .proof_fail, .next = .credentials, .action = .none },
    .{ .state = .credentials, .event = .creds_ok, .next = .connecting, .action = .save_creds },
    .{ .state = .credentials, .event = .connect_ok, .next = .credentials, .action = .none },
    .{ .state = .credentials, .event = .connect_fail, .next = .credentials, .action = .none },
    .{ .state = .credentials, .event = .timeout, .next = .failed, .action = .stop_ap },
    .{ .state = .credentials, .event = .cancel, .next = .idle, .action = .stop_ap },

    // ---- connecting：等 STA 连接结果 ----
    .{ .state = .connecting, .event = .start, .next = .connecting, .action = .none },
    .{ .state = .connecting, .event = .client_joined, .next = .connecting, .action = .none },
    .{ .state = .connecting, .event = .proof_ok, .next = .connecting, .action = .none },
    .{ .state = .connecting, .event = .proof_fail, .next = .connecting, .action = .none },
    // 凭据已在进入 connecting 时保存，重复通知不重复保存。
    .{ .state = .connecting, .event = .creds_ok, .next = .connecting, .action = .none },
    .{ .state = .connecting, .event = .connect_ok, .next = .connected, .action = .notify_ok },
    .{ .state = .connecting, .event = .connect_fail, .next = .connecting, .action = .backoff },
    .{ .state = .connecting, .event = .timeout, .next = .connecting, .action = .backoff },
    .{ .state = .connecting, .event = .cancel, .next = .idle, .action = .reset },

    // ---- connected：配网已完成 ----
    .{ .state = .connected, .event = .start, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .client_joined, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .proof_ok, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .proof_fail, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .creds_ok, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .connect_ok, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .connect_fail, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .timeout, .next = .connected, .action = .none },
    .{ .state = .connected, .event = .cancel, .next = .idle, .action = .reset },

    // ---- failed：安全终态，只认 cancel ----
    .{ .state = .failed, .event = .start, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .client_joined, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .proof_ok, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .proof_fail, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .creds_ok, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .connect_ok, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .connect_fail, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .timeout, .next = .failed, .action = .none },
    .{ .state = .failed, .event = .cancel, .next = .idle, .action = .reset },
};

fn expectTransition(state: State, event: Event, want_next: State, want_action: Action) !void {
    const got = provisioning.step(state, event);
    if (got.next != want_next or got.action != want_action) {
        std.debug.print(
            "provisioning: {s} + {s} -> {s}/{s}，期望 {s}/{s}\n",
            .{
                @tagName(state),    @tagName(event),
                @tagName(got.next), @tagName(got.action),
                @tagName(want_next), @tagName(want_action),
            },
        );
        return error.UnexpectedTransition;
    }
}

test "迁移表覆盖全部 7 状态 × 9 事件" {
    const combos: usize = all_states.len * all_events.len;
    try std.testing.expectEqual(@as(usize, 63), combos);
    try std.testing.expectEqual(combos, table.len);

    // 每个 (state, event) 组合在表里恰好出现一次（防漏格、防重复）。
    for (all_states) |s| {
        for (all_events) |e| {
            var hits: usize = 0;
            for (table) |c| {
                if (c.state == s and sameTag(c.event, e)) hits += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), hits);
        }
    }
}

test "迁移表逐格成立" {
    for (table) |c| {
        try expectTransition(c.state, c.event, c.next, c.action);
    }
}

test "初始状态为 idle" {
    try std.testing.expectEqual(State.idle, provisioning.initialState());
}

test "主链路：idle → ap → awaiting_proof → credentials → connecting → connected" {
    const started = provisioning.step(.idle, .start);
    try std.testing.expectEqual(State.ap, started.next);
    try std.testing.expectEqual(Action.start_ap, started.action);

    const joined = provisioning.step(started.next, .client_joined);
    try std.testing.expectEqual(State.awaiting_proof, joined.next);
    try std.testing.expectEqual(Action.prompt_proof, joined.action);

    const proven = provisioning.step(joined.next, .proof_ok);
    try std.testing.expectEqual(State.credentials, proven.next);
    try std.testing.expectEqual(Action.none, proven.action);

    const saved = provisioning.step(proven.next, .creds_ok);
    try std.testing.expectEqual(State.connecting, saved.next);
    try std.testing.expectEqual(Action.save_creds, saved.action);

    const up = provisioning.step(saved.next, .connect_ok);
    try std.testing.expectEqual(State.connected, up.next);
    try std.testing.expectEqual(Action.notify_ok, up.action);
}

test "非法事件保持原状态并返回 none" {
    // 没有 AP 时客户端/证明/连接事件都无从谈起。
    try expectTransition(.idle, .client_joined, .idle, .none);
    try expectTransition(.idle, .creds_ok, .idle, .none);
    try expectTransition(.idle, .connect_ok, .idle, .none);
    try expectTransition(.idle, .timeout, .idle, .none);
    // 重复 start 不重启 AP，避免踢掉已接入的客户端。
    try expectTransition(.ap, .start, .ap, .none);
    // 证明会话尚未建立，证明结果不可信。
    try expectTransition(.ap, .proof_ok, .ap, .none);
    try expectTransition(.ap, .proof_fail, .ap, .none);
    // 已 entered connecting，重复的 creds_ok 不再保存。
    try expectTransition(.connecting, .creds_ok, .connecting, .none);
    // 连接成功后不再接受配网事件。
    try expectTransition(.connected, .start, .connected, .none);
    try expectTransition(.connected, .connect_fail, .connected, .none);
}

test "proof_fail / 证明超时 不得进入 credentials" {
    const failed = provisioning.step(.awaiting_proof, .proof_fail);
    try std.testing.expectEqual(State.failed, failed.next);
    try std.testing.expectEqual(Action.stop_ap, failed.action);

    const timed_out = provisioning.step(.awaiting_proof, .timeout);
    try std.testing.expectEqual(State.failed, timed_out.next);
    try std.testing.expectEqual(Action.stop_ap, timed_out.action);

    // 从 failed 出发，任何非 cancel 事件都回不到 credentials。
    for (all_events) |e| {
        const got = provisioning.step(.failed, e);
        if (!sameTag(e, .cancel)) {
            try std.testing.expect(got.next != .credentials);
        }
    }
}

test "超时不保存凭据：save_creds 只出现在 credentials + creds_ok" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = provisioning.step(s, e);
            if (got.action == .save_creds) {
                try std.testing.expectEqual(State.credentials, s);
                try std.testing.expect(sameTag(e, .creds_ok));
                try std.testing.expectEqual(State.connecting, got.next);
            }
            // 超时永远不是保存凭据的时机，也绝不会把状态**推进**到 connecting
            // （`connecting + timeout` 只是留在原地重试）。
            if (sameTag(e, .timeout)) {
                try std.testing.expect(got.action != .save_creds);
                if (s != .connecting) {
                    try std.testing.expect(got.next != .connecting);
                }
            }
            // 证明失败绝不能把状态**推进**到 credentials；已经在 credentials
            // 里时，迟到的 proof_fail 按设计保持原地（不会降级、也不会重复保存）。
            if (sameTag(e, .proof_fail) and s != .credentials) {
                try std.testing.expect(got.next != .credentials);
            }
        }
    }
}

test "未证明前的 creds_ok 不被接受" {
    // 两条可能的「提前送凭据」路径都必须停在原地、且不保存。
    try expectTransition(.ap, .creds_ok, .ap, .none);
    try expectTransition(.awaiting_proof, .creds_ok, .awaiting_proof, .none);
}

test "credentials 阶段的迟到 proof_fail 不打断会话" {
    try expectTransition(.credentials, .proof_fail, .credentials, .none);
    try expectTransition(.credentials, .proof_ok, .credentials, .none);
}

test "凭据窗口超时进 failed 且不保存任何东西" {
    const got = provisioning.step(.credentials, .timeout);
    try std.testing.expectEqual(State.failed, got.next);
    try std.testing.expectEqual(Action.stop_ap, got.action);
    // failed 只能靠 cancel 退出。
    const exit = provisioning.step(got.next, .cancel);
    try std.testing.expectEqual(State.idle, exit.next);
    try std.testing.expectEqual(Action.reset, exit.action);
}

test "连接失败与连接超时留在 connecting 并 backoff，只有 cancel 退出" {
    try expectTransition(.connecting, .connect_fail, .connecting, .backoff);
    try expectTransition(.connecting, .timeout, .connecting, .backoff);
    try expectTransition(.connecting, .cancel, .idle, .reset);

    for ([_]Event{ .connect_fail, .timeout }) |e| {
        const got = provisioning.step(.connecting, e);
        try std.testing.expectEqual(State.connecting, got.next);
        try std.testing.expectEqual(Action.backoff, got.action);
    }
    // 重试过程中又收到超时：仍留在 connecting，不回退到 AP 重新配网。
    const again = provisioning.step(.connecting, .timeout);
    try std.testing.expectEqual(State.connecting, again.next);
    // 重试成功后仍然只能走 connecting + connect_ok 这一个入口。
    const up = provisioning.step(again.next, .connect_ok);
    try std.testing.expectEqual(State.connected, up.next);
    try std.testing.expectEqual(Action.notify_ok, up.action);
    // 退出连接重试只有 cancel 一条路。
    const bail = provisioning.step(.connecting, .cancel);
    try std.testing.expectEqual(State.idle, bail.next);
    try std.testing.expectEqual(Action.reset, bail.action);
}

test "cancel 从任何已启动状态都能回 idle" {
    const cases = [_]struct { s: State, a: Action }{
        .{ .s = .ap, .a = .stop_ap },
        .{ .s = .awaiting_proof, .a = .stop_ap },
        .{ .s = .credentials, .a = .stop_ap },
        .{ .s = .connecting, .a = .reset },
        .{ .s = .connected, .a = .reset },
        .{ .s = .failed, .a = .reset },
    };
    for (cases) |c| {
        try expectTransition(c.s, .cancel, .idle, c.a);
    }
    // idle 下 cancel 是空操作。
    try expectTransition(.idle, .cancel, .idle, .none);
}

test "全局不变量：进入 credentials 的唯一入口是 awaiting_proof + proof_ok" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = provisioning.step(s, e);
            if (got.next == .credentials and s != .credentials) {
                try std.testing.expectEqual(State.awaiting_proof, s);
                try std.testing.expect(sameTag(e, .proof_ok));
            }
        }
    }
}

test "全局不变量：进入 connected 的唯一入口是 connecting + connect_ok" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = provisioning.step(s, e);
            // 不用「s ∈ {connecting, connected}」的宽松写法，免得将来
            // credentials + connect_ok → connected 之类的误改漏过断言。
            if (got.next == .connected and s != .connected) {
                try std.testing.expectEqual(State.connecting, s);
                try std.testing.expect(sameTag(e, .connect_ok));
            }
            if (got.action == .notify_ok) {
                try std.testing.expectEqual(State.connecting, s);
                try std.testing.expect(sameTag(e, .connect_ok));
                try std.testing.expectEqual(State.connected, got.next);
            }
        }
    }
}

test "全局不变量：failed 只能由 cancel 退出，且只回 idle" {
    for (all_events) |e| {
        const got = provisioning.step(.failed, e);
        if (sameTag(e, .cancel)) {
            try std.testing.expectEqual(State.idle, got.next);
            try std.testing.expectEqual(Action.reset, got.action);
        } else {
            try std.testing.expectEqual(State.failed, got.next);
            try std.testing.expectEqual(Action.none, got.action);
        }
    }
}

test "全局不变量：connected 只能由 cancel 退出" {
    for (all_events) |e| {
        const got = provisioning.step(.connected, e);
        if (sameTag(e, .cancel)) {
            try std.testing.expectEqual(State.idle, got.next);
            try std.testing.expectEqual(Action.reset, got.action);
        } else {
            try std.testing.expectEqual(State.connected, got.next);
            try std.testing.expectEqual(Action.none, got.action);
        }
    }
}

test "全局不变量：start_ap 只在 idle + start 产生，stop_ap 只关掉已启动的会话" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = provisioning.step(s, e);
            if (got.action == .start_ap) {
                try std.testing.expectEqual(State.idle, s);
                try std.testing.expect(sameTag(e, .start));
                try std.testing.expectEqual(State.ap, got.next);
            }
            if (got.action == .stop_ap) {
                // 只有已起 AP 的状态才需要停 AP；idle/failed/connected 不该出现。
                // 停 AP 后要么回 idle（cancel/AP 超时），要么进 failed（证明/凭据
                // 窗口超时或证明失败）——两者都表示会话已停、等待显式 cancel。
                try std.testing.expect(s == .ap or s == .awaiting_proof or s == .credentials);
                try std.testing.expect(got.next == .idle or got.next == .failed);
            }
            if (got.action == .reset) {
                try std.testing.expectEqual(State.idle, got.next);
                try std.testing.expect(s == .connecting or s == .connected or s == .failed);
            }
            if (got.action == .backoff) {
                // 退避只发生在连接重试中：状态不离开 connecting。
                try std.testing.expectEqual(State.connecting, s);
                try std.testing.expectEqual(State.connecting, got.next);
            }
            if (got.action == .prompt_proof) {
                try std.testing.expectEqual(State.ap, s);
                try std.testing.expectEqual(State.awaiting_proof, got.next);
            }
        }
    }
}

test "Action 使用情况：8 个动作在迁移表里全部可达" {
    const action_count = 8;
    var seen: [action_count]bool = @splat(false);
    for (table) |c| seen[actionIndex(c.action)] = true;

    for (seen) |hit| try std.testing.expect(hit);
}

/// 给 Action 一个稳定的下标，避免依赖 @typeInfo / @intFromEnum 的版本差异。
fn actionIndex(a: Action) usize {
    return switch (a) {
        .none => 0,
        .start_ap => 1,
        .stop_ap => 2,
        .prompt_proof => 3,
        .save_creds => 4,
        .notify_ok => 5,
        .backoff => 6,
        .reset => 7,
    };
}

fn sameTag(a: Event, b: Event) bool {
    return switch (a) {
        .start => switch (b) {
            .start => true,
            else => false,
        },
        .client_joined => switch (b) {
            .client_joined => true,
            else => false,
        },
        .proof_ok => switch (b) {
            .proof_ok => true,
            else => false,
        },
        .proof_fail => switch (b) {
            .proof_fail => true,
            else => false,
        },
        .creds_ok => switch (b) {
            .creds_ok => true,
            else => false,
        },
        .connect_ok => switch (b) {
            .connect_ok => true,
            else => false,
        },
        .connect_fail => switch (b) {
            .connect_fail => true,
            else => false,
        },
        .timeout => switch (b) {
            .timeout => true,
            else => false,
        },
        .cancel => switch (b) {
            .cancel => true,
            else => false,
        },
    };
}
