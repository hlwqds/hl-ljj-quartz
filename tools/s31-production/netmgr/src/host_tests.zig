//! netmgr 的主机侧单元测试（x86_64，不涉硬件）。
//!
//! 方式：一张覆盖 5 状态 × 6 事件的完整迁移表 + 若干条按语义命名的用例。
//! 迁移表保证没有漏格，命名用例保证「为什么这么迁移」可读。

const std = @import("std");
const netmgr = @import("netmgr.zig");

const State = netmgr.State;
const Event = netmgr.Event;
const Action = netmgr.Action;

const all_states = [_]State{ .offline, .link_up, .dhcp, .online, .degraded };

const all_events = [_]Event{
    .link_up,
    .link_down,
    .dhcp_ok,
    .dhcp_fail,
    .time_ok,
    .fatal,
};

/// 全量迁移表的一行：给定 state/event，必须得到 next/action。
const Case = struct {
    state: State,
    event: Event,
    next: State,
    action: Action,
};

/// 5 × 6 = 30 行，与 src/netmgr.zig 的迁移表逐格对应。
const table = [_]Case{
    // ---- offline ----
    .{ .state = .offline, .event = .link_up, .next = .link_up, .action = .start_dhcp },
    .{ .state = .offline, .event = .link_down, .next = .offline, .action = .none },
    .{ .state = .offline, .event = .dhcp_ok, .next = .offline, .action = .none },
    .{ .state = .offline, .event = .dhcp_fail, .next = .offline, .action = .none },
    .{ .state = .offline, .event = .time_ok, .next = .offline, .action = .none },
    .{ .state = .offline, .event = .fatal, .next = .offline, .action = .reset },

    // ---- link_up ----
    .{ .state = .link_up, .event = .link_up, .next = .link_up, .action = .none },
    .{ .state = .link_up, .event = .link_down, .next = .offline, .action = .reset },
    .{ .state = .link_up, .event = .dhcp_ok, .next = .dhcp, .action = .start_sntp },
    .{ .state = .link_up, .event = .dhcp_fail, .next = .degraded, .action = .backoff },
    .{ .state = .link_up, .event = .time_ok, .next = .link_up, .action = .none },
    .{ .state = .link_up, .event = .fatal, .next = .offline, .action = .reset },

    // ---- dhcp ----
    .{ .state = .dhcp, .event = .link_up, .next = .dhcp, .action = .none },
    .{ .state = .dhcp, .event = .link_down, .next = .offline, .action = .reset },
    .{ .state = .dhcp, .event = .dhcp_ok, .next = .dhcp, .action = .start_sntp },
    .{ .state = .dhcp, .event = .dhcp_fail, .next = .degraded, .action = .backoff },
    .{ .state = .dhcp, .event = .time_ok, .next = .online, .action = .notify_online },
    .{ .state = .dhcp, .event = .fatal, .next = .offline, .action = .reset },

    // ---- online ----
    .{ .state = .online, .event = .link_up, .next = .online, .action = .none },
    .{ .state = .online, .event = .link_down, .next = .offline, .action = .reset },
    .{ .state = .online, .event = .dhcp_ok, .next = .online, .action = .start_sntp },
    .{ .state = .online, .event = .dhcp_fail, .next = .degraded, .action = .backoff },
    .{ .state = .online, .event = .time_ok, .next = .online, .action = .none },
    .{ .state = .online, .event = .fatal, .next = .offline, .action = .reset },

    // ---- degraded ----
    .{ .state = .degraded, .event = .link_up, .next = .link_up, .action = .start_dhcp },
    .{ .state = .degraded, .event = .link_down, .next = .offline, .action = .reset },
    .{ .state = .degraded, .event = .dhcp_ok, .next = .dhcp, .action = .start_sntp },
    .{ .state = .degraded, .event = .dhcp_fail, .next = .degraded, .action = .backoff },
    // 没有租约标志：degraded 里的 time_ok 不能证明可服务，停在 degraded。
    .{ .state = .degraded, .event = .time_ok, .next = .degraded, .action = .none },
    .{ .state = .degraded, .event = .fatal, .next = .offline, .action = .reset },
};

fn fail(state: State, event: Event, want_next: State, want_action: Action, got: netmgr.Transition) !void {
    if (got.next != want_next or got.action != want_action) {
        std.debug.print(
            "netmgr: {s} + {s} -> {s}/{s}，期望 {s}/{s}\n",
            .{
                @tagName(state),   @tagName(event),
                @tagName(got.next), @tagName(got.action),
                @tagName(want_next), @tagName(want_action),
            },
        );
        return error.UnexpectedTransition;
    }
}

fn expectTransition(state: State, event: Event, want_next: State, want_action: Action) !void {
    try fail(state, event, want_next, want_action, netmgr.step(state, event));
}

test "迁移表覆盖全部 5 状态 × 6 事件" {
    const combos: usize = all_states.len * all_events.len;
    try std.testing.expectEqual(@as(usize, 30), combos);
    try std.testing.expectEqual(combos, table.len);

    // 每个 (state, event) 组合在表里恰好出现一次。
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

test "初始状态为 offline" {
    try std.testing.expectEqual(State.offline, netmgr.initialState());
}

test "主链路：offline → link_up → dhcp → online" {
    const up = netmgr.step(.offline, .link_up);
    try std.testing.expectEqual(State.link_up, up.next);
    try std.testing.expectEqual(Action.start_dhcp, up.action);

    const leased = netmgr.step(up.next, .dhcp_ok);
    try std.testing.expectEqual(State.dhcp, leased.next);
    try std.testing.expectEqual(Action.start_sntp, leased.action);

    const synced = netmgr.step(leased.next, .time_ok);
    try std.testing.expectEqual(State.online, synced.next);
    try std.testing.expectEqual(Action.notify_online, synced.action);
}

test "非法事件保持原状态并返回 none" {
    // 地址/时间都还没有，DHCP/SNTP 结果无从谈起。
    try expectTransition(.offline, .dhcp_ok, .offline, .none);
    try expectTransition(.offline, .dhcp_fail, .offline, .none);
    try expectTransition(.offline, .time_ok, .offline, .none);
    // SNTP 尚未启动，校时结果不可信。
    try expectTransition(.link_up, .time_ok, .link_up, .none);
    // 重复上链通知：不能重启 DHCP，否则丢租约。
    try expectTransition(.dhcp, .link_up, .dhcp, .none);
    try expectTransition(.online, .link_up, .online, .none);
    // 已 offline 时重复下链通知。
    try expectTransition(.offline, .link_down, .offline, .none);
}

test "退化路径：dhcp_fail 进 degraded，只能经 dhcp_ok 恢复" {
    const degraded = netmgr.step(.link_up, .dhcp_fail);
    try std.testing.expectEqual(State.degraded, degraded.next);
    try std.testing.expectEqual(Action.backoff, degraded.action);

    // 重试拿到租约：回 dhcp 并重启校时。
    try expectTransition(.degraded, .dhcp_ok, .dhcp, .start_sntp);
    // 恢复必须走完整链路：dhcp_ok → dhcp，再 time_ok → online。
    const leased = netmgr.step(.degraded, .dhcp_ok);
    const synced = netmgr.step(leased.next, .time_ok);
    try std.testing.expectEqual(State.online, synced.next);
    try std.testing.expectEqual(Action.notify_online, synced.action);
    // 重新上链：回到等待 DHCP。
    try expectTransition(.degraded, .link_up, .link_up, .start_dhcp);
    // 连续失败仍留在 degraded，只是要求调用方再次退避。
    try expectTransition(.degraded, .dhcp_fail, .degraded, .backoff);
}

test "degraded + time_ok 不得直接 online（无租约标志的保守规则）" {
    // 路径一：link_up + dhcp_fail（从未拿到过地址）→ degraded。
    const from_link = netmgr.step(.link_up, .dhcp_fail);
    try std.testing.expectEqual(State.degraded, from_link.next);
    const late_time = netmgr.step(from_link.next, .time_ok);
    try std.testing.expectEqual(State.degraded, late_time.next);
    try std.testing.expectEqual(Action.none, late_time.action);

    // 路径二：dhcp + dhcp_fail（续约失败）→ degraded。
    const from_dhcp = netmgr.step(.dhcp, .dhcp_fail);
    try std.testing.expectEqual(State.degraded, from_dhcp.next);
    const late_time2 = netmgr.step(from_dhcp.next, .time_ok);
    try std.testing.expectEqual(State.degraded, late_time2.next);
    try std.testing.expectEqual(Action.none, late_time2.action);

    // 第三条来源：online + dhcp_fail（租约失效）也一样。
    const from_online = netmgr.step(.online, .dhcp_fail);
    try std.testing.expectEqual(State.degraded, from_online.next);
    const late_time3 = netmgr.step(from_online.next, .time_ok);
    try std.testing.expectEqual(State.degraded, late_time3.next);
    try std.testing.expectEqual(Action.none, late_time3.action);
}

test "退化路径可回到 offline" {
    try expectTransition(.degraded, .link_down, .offline, .reset);
    try expectTransition(.degraded, .fatal, .offline, .reset);

    // 整条主链路任意一点掉链，都直接回 offline。
    try expectTransition(.link_up, .link_down, .offline, .reset);
    try expectTransition(.dhcp, .link_down, .offline, .reset);
    try expectTransition(.online, .link_down, .offline, .reset);
}

test "fatal 在任何状态下都回 offline 并 reset" {
    for (all_states) |s| {
        const got = netmgr.step(s, .fatal);
        try std.testing.expectEqual(State.offline, got.next);
        try std.testing.expectEqual(Action.reset, got.action);
    }
}

test "重复事件幂等：online 维持 online" {
    try expectTransition(.online, .time_ok, .online, .none);
    try expectTransition(.online, .link_up, .online, .none);
    try expectTransition(.link_up, .link_up, .link_up, .none);
}

test "全局不变量：backoff 只由 dhcp_fail 产生" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = netmgr.step(s, e);
            if (got.action == .backoff) {
                try std.testing.expect(sameTag(e, .dhcp_fail));
                try std.testing.expectEqual(State.degraded, got.next);
            }
        }
    }
}

test "全局不变量：reset 只由 fatal 或非 offline 的 link_down 产生" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = netmgr.step(s, e);
            if (got.action == .reset) {
                try std.testing.expectEqual(State.offline, got.next);
                const ok = sameTag(e, .fatal) or
                    (sameTag(e, .link_down) and s != .offline);
                try std.testing.expect(ok);
            }
        }
    }
}

test "全局不变量：只有 online 状态会收到 notify_online" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = netmgr.step(s, e);
            if (got.action == .notify_online) {
                try std.testing.expectEqual(State.online, got.next);
            }
        }
    }
}

test "全局不变量：进入 online 的唯一入口是 dhcp + time_ok" {
    for (all_states) |s| {
        for (all_events) |e| {
            const got = netmgr.step(s, e);
            // 非 online 状态想进 online，必须且只能是 dhcp + time_ok。
            // 这里不用「s ∈ {dhcp, online}」的宽松写法，否则将来 dhcp + link_up → online
            // 之类的误改会漏过断言。
            if (got.next == .online and s != .online) {
                try std.testing.expectEqual(State.dhcp, s);
                try std.testing.expect(sameTag(e, .time_ok));
            }
            // notify_online 的来源同样唯一。
            if (got.action == .notify_online) {
                try std.testing.expectEqual(State.dhcp, s);
                try std.testing.expect(sameTag(e, .time_ok));
            }
        }
    }
}

/// 给 Action 一个稳定的下标，避免依赖 @typeInfo / @intFromEnum 的版本差异。
const action_count = 6;

fn actionIndex(a: Action) usize {
    return switch (a) {
        .none => 0,
        .start_dhcp => 1,
        .start_sntp => 2,
        .notify_online => 3,
        .backoff => 4,
        .reset => 5,
    };
}

test "所有 Action 都可达" {
    var seen: [action_count]bool = @splat(false);
    for (table) |c| seen[actionIndex(c.action)] = true;
    for (seen) |hit| try std.testing.expect(hit);
}

fn sameTag(a: Event, b: Event) bool {
    return switch (a) {
        .link_up => switch (b) {
            .link_up => true,
            else => false,
        },
        .link_down => switch (b) {
            .link_down => true,
            else => false,
        },
        .dhcp_ok => switch (b) {
            .dhcp_ok => true,
            else => false,
        },
        .dhcp_fail => switch (b) {
            .dhcp_fail => true,
            else => false,
        },
        .time_ok => switch (b) {
            .time_ok => true,
            else => false,
        },
        .fatal => switch (b) {
            .fatal => true,
            else => false,
        },
    };
}
