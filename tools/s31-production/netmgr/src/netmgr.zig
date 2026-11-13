//! S31 网络管理器：纯状态机。
//!
//! 本模块只做「当前状态 × 事件 → 新状态 + 动作」的纯函数推导，用来把
//! 「链路起来 → 拿地址 → 校准时间 → 对外可服务」这条运营路径从硬件里剥出来：
//!
//!   - 不读时钟：超时判定完全由调用方负责，退避只通过 `Action.backoff` 表达；
//!   - 不做退避计算：`backoff` 返回给调用方，具体秒数/重试上限由调用方策略决定；
//!   - 不碰 socket / PHY / lwIP / SNTP / IDF，也不分配内存、不持有全局状态。
//!
//! 主链路：`offline → link_up → dhcp → online`；
//! DHCP 失败进 `degraded`（可重试，但必须先 `dhcp_ok` 才能再谈 `online`），
//! 链路断开或 `fatal` 一律回 `offline` 并 `reset`。

/// 管理器状态。
///
/// - `offline`：无链路（或链路层已复位）。初始状态。
/// - `link_up`：链路已建立，正在等 DHCP 租约。
/// - `dhcp`：已拿到地址，正在等 SNTP 校时。
/// - `online`：地址与时间都就绪，可对外提供服务。
/// - `degraded`：DHCP/续约失败，保留重试能力；必须先重新拿到租约（`dhcp_ok`）
///   才可能经校时回到 `online`——本模型没有「持有租约」标志，不做乐观恢复。
pub const State = enum { offline, link_up, dhcp, online, degraded };

/// 外部输入事件。全部无载荷：错误码、重试计数由调用方自己保存。
///
/// `fatal` 表示不可自愈的本地故障（PHY 初始化失败、驱动内部不变量被破坏等），
/// 它不携带原因码，调用方需要另行记录诊断信息。
pub const Event = union(enum) {
    /// 链路层报告 up（含重复通知）。
    link_up,
    /// 链路层报告 down。
    link_down,
    /// DHCP 拿到/续约到租约。
    dhcp_ok,
    /// DHCP 失败或续约失败（超时判定由调用方给出）。
    dhcp_fail,
    /// SNTP 校时成功。
    time_ok,
    /// 不可自愈故障。
    fatal,
};

/// 状态机要求调用方执行的动作。调用方执行完动作后无需回灌事件，
/// 状态迁移已在本函数内完成。
pub const Action = enum {
    /// 什么都不做。
    none,
    /// 启动（或重启）DHCP 客户端。
    start_dhcp,
    /// 启动（或重启）SNTP 客户端。
    start_sntp,
    /// 对外宣告「已可服务」。回调/hook 由调用方决定。
    notify_online,
    /// 按调用方注入的退避计数安排下一次重试；本模块不产生等待时长。
    backoff,
    /// 拆除所有网络上下文（DHCP 租约、DNS 缓存、定时器），回到干净起点。
    reset,
};

/// `step` 的返回值。字段名与 SPEC 一致：`next` + `action`。
pub const Transition = struct { next: State, action: Action };

/// 初始状态：无链路。
pub fn initialState() State {
    return .offline;
}

/// 单步迁移。非法事件保持原状态并返回 `Action.none`。
///
/// 迁移表（行=状态，列=事件）：
///
/// | 状态 \ 事件 | link_up           | link_down     | dhcp_ok        | dhcp_fail       | time_ok         | fatal         |
/// | ----------- | ----------------- | ------------- | -------------- | --------------- | --------------- | ------------- |
/// | offline     | link_up/start_dhcp| offline/none  | offline/none   | offline/none    | offline/none    | offline/reset |
/// | link_up     | link_up/none      | offline/reset | dhcp/start_sntp| degraded/backoff| link_up/none    | offline/reset |
/// | dhcp        | dhcp/none         | offline/reset | dhcp/start_sntp| degraded/backoff| online/notify_online | offline/reset |
/// | online      | online/none       | offline/reset | online/start_sntp | degraded/backoff | online/none  | offline/reset |
/// | degraded    | link_up/start_dhcp| offline/reset | dhcp/start_sntp| degraded/backoff| degraded/none   | offline/reset |
///
/// 四条全局不变量：
/// 1. `fatal` 在任何状态下都回 `offline` 并 `reset`（冷启动链路层）；
/// 2. `backoff` 只由 `dhcp_fail` 产生（退避节奏归调用方）；
/// 3. `reset` 只由 `fatal` 或非 `offline` 状态下的 `link_down` 产生。
/// 4. 进入 `online` 的唯一迁移是 `dhcp + time_ok`；本模型不带「持有租约」标志，
///    所以 `degraded + time_ok` 保守地停在 `degraded`（`none`），必须先 `dhcp_ok`。
pub fn step(state: State, event: Event) Transition {
    return switch (state) {
        .offline => switch (event) {
            .link_up => .{ .next = .link_up, .action = .start_dhcp },
            .link_down => .{ .next = .offline, .action = .none },
            .dhcp_ok, .dhcp_fail, .time_ok => .{ .next = .offline, .action = .none },
            .fatal => .{ .next = .offline, .action = .reset },
        },

        .link_up => switch (event) {
            .link_up => .{ .next = .link_up, .action = .none },
            .link_down => .{ .next = .offline, .action = .reset },
            .dhcp_ok => .{ .next = .dhcp, .action = .start_sntp },
            .dhcp_fail => .{ .next = .degraded, .action = .backoff },
            // SNTP 尚未启动，此时到达的校时结果不可信 → 维持原状态。
            .time_ok => .{ .next = .link_up, .action = .none },
            .fatal => .{ .next = .offline, .action = .reset },
        },

        .dhcp => switch (event) {
            // 链路抖动/重复通知不应重启 DHCP 客户端，否则会丢掉租约。
            .link_up => .{ .next = .dhcp, .action = .none },
            .link_down => .{ .next = .offline, .action = .reset },
            // 续约成功：地址可能变化，重新校时。
            .dhcp_ok => .{ .next = .dhcp, .action = .start_sntp },
            .dhcp_fail => .{ .next = .degraded, .action = .backoff },
            .time_ok => .{ .next = .online, .action = .notify_online },
            .fatal => .{ .next = .offline, .action = .reset },
        },

        .online => switch (event) {
            .link_up => .{ .next = .online, .action = .none },
            .link_down => .{ .next = .offline, .action = .reset },
            // 租约续约后重新校时，但仍保持对外可服务。
            .dhcp_ok => .{ .next = .online, .action = .start_sntp },
            .dhcp_fail => .{ .next = .degraded, .action = .backoff },
            .time_ok => .{ .next = .online, .action = .none },
            .fatal => .{ .next = .offline, .action = .reset },
        },

        .degraded => switch (event) {
            // 重新拉起 DHCP；是否立即重试由调用方的退避计数决定。
            .link_up => .{ .next = .link_up, .action = .start_dhcp },
            .link_down => .{ .next = .offline, .action = .reset },
            .dhcp_ok => .{ .next = .dhcp, .action = .start_sntp },
            .dhcp_fail => .{ .next = .degraded, .action = .backoff },
            // 保守策略：本模型没有「是否持有租约」标志，degraded 既可能来自
            // 「从没拿到地址」（link_up + dhcp_fail），也可能来自「租约续期失败」。
            // 此时到来的 time_ok 无法证明本地有可用地址，所以不直接恢复 online：
            // 必须先 dhcp_ok 回到 dhcp，再由 time_ok 进 online。
            .time_ok => .{ .next = .degraded, .action = .none },
            .fatal => .{ .next = .offline, .action = .reset },
        },
    };
}
