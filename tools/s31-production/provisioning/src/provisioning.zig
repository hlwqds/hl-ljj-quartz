//! S31 配网（Wi-Fi provisioning）：纯状态机。
//!
//! 本模块只做「当前状态 × 事件 → 新状态 + 动作」的纯函数推导，把
//! 「起 AP → 客户端接入 → PoP 证明 → 收凭据 → 连 STA」这条配网路径从射频/协议栈里剥出来：
//!
//!   - 不读时钟：证明窗口/连接超时的计时归调用方，「超时」只以 `Event.timeout` 表达；
//!   - 不碰 socket / PHY / SoftAP / STA / IDF，不分配内存、不持有全局状态；
//!   - PoP（proof of possession）的密码学校验、凭据的持久化、STA 连接本身都由调用方执行，
//!     本模块只给出「该做什么」和「此刻允许进入哪个状态」。
//!
//! 主链路：`idle → ap → awaiting_proof → credentials → connecting → connected`；
//! 证明失败或证明/凭据窗口超时进 `failed`（必须显式 `cancel` 才能重来）；
//! 连接失败/连接超时留在 `connecting` 并 `backoff`（凭据已保存，由调用方按退避节奏重试 STA，
//! 不回退到 AP 重新配网）。
//!
//! 两条安全不变量（单测在 7×9 全表上断言）：
//!   1. 进入 `credentials` 的唯一迁移是 `awaiting_proof + proof_ok`——任何状态都不能
//!      跳过证明直接收凭据；
//!   2. 进入 `connected` 的唯一迁移是 `connecting + connect_ok`——`notify_ok` 也只出现在这条迁移上。

/// 配网状态。
///
/// - `idle`：未开始（或已收尾）。初始状态。
/// - `ap`：SoftAP 与配网服务已启动，等待客户端接入。
/// - `awaiting_proof`：已有一个客户端接入，等待它给出 PoP 证明。
/// - `credentials`：证明已通过，等待客户端提交 STA 凭据。
/// - `connecting`：凭据已保存，调用方正在用它们发起 STA 连接。
/// - `connected`：STA 已连上。配网成功，可对外通知。
/// - `failed`：安全相关的失败（证明失败/证明或凭据窗口超时）。只能由 `cancel` 退出。
pub const State = enum { idle, ap, awaiting_proof, credentials, connecting, connected, failed };

/// 外部输入事件。全部无载荷：失败原因、剩余重试次数、超时时长都由调用方保存。
///
/// `timeout` 不区分「哪一段超时」——由当前状态决定语义（见 `step` 的迁移表），
/// 计时与判定完全在调用方。`cancel` 是唯一的全局出口（人按按钮/上层中止）。
pub const Event = union(enum) {
    /// 开始配网（进入 `ap`）。
    start,
    /// SoftAP 侧报告有客户端接入。
    client_joined,
    /// 调用方完成 PoP 校验且通过。
    proof_ok,
    /// PoP 校验失败（错误次数、锁定策略由调用方决定）。
    proof_fail,
    /// 客户端提交的 STA 凭据已被调用方校验通过。
    creds_ok,
    /// STA 连接成功（含 DHCP，判定归调用方）。
    connect_ok,
    /// STA 连接失败。
    connect_fail,
    /// 当前阶段的等待窗口超时；语义随状态变化。
    timeout,
    /// 中止本次配网，回到 `idle`。
    cancel,
};

/// 状态机要求调用方执行的动作。调用方执行完动作后无需回灌事件，
/// 状态迁移已在本函数内完成。
///
/// 注意：一次迁移只返回**一个**动作；当一步天然包含多个副作用时，
/// 由该动作的定义把顺序写死（目前只有 `save_creds`：保存 → 停 AP → 发起 STA）。
pub const Action = enum {
    /// 什么都不做。
    none,
    /// 启动 SoftAP 与配网服务。
    start_ap,
    /// 关闭 SoftAP 与配网服务。
    stop_ap,
    /// 向已接入的客户端索取 PoP 证明；密码学校验由调用方做。
    prompt_proof,
    /// 持久化凭据，然后**停掉 SoftAP**（单射频下与 STA 不能共存），最后用凭据发起 STA。
    /// 本迁移表把「保存」作为 `credentials + creds_ok` 的返回动作，因为丢凭据是不可接受的；
    /// 停 AP 与发起 STA 都是该语义的固定后续，不是可选动作（迁移表进入 `connecting`
    /// 时不会再发 `stop_ap`）。
    save_creds,
    /// 通知上头/界面：配网成功、设备已上线。
    notify_ok,
    /// 调用方按自己的策略退避（时长、上限、是否指数增长都在调用方）。
    backoff,
    /// 拆除所有上下文（SoftAP、STA、配网会话），回到干净起点。
    reset,
};

/// `step` 的返回值。字段名与 SPEC 一致：`next` + `action`。
pub const Transition = struct { next: State, action: Action };

/// 初始状态：未开始配网。
pub fn initialState() State {
    return .idle;
}

/// 单步迁移。非法/迟到事件保持原状态并返回 `Action.none`。
///
/// 迁移表（行=状态，列=事件），单元格为 `下一状态 / 动作`：
///
/// | 状态 \ 事件      | start        | client_joined    | proof_ok         | proof_fail     | creds_ok         | connect_ok        | connect_fail    | timeout        | cancel        |
/// | ---------------- | ------------ | ---------------- | ---------------- | -------------- | ---------------- | ----------------- | --------------- | -------------- | ------------- |
/// | idle             | ap/start_ap  | idle/none        | idle/none        | idle/none      | idle/none        | idle/none         | idle/none       | idle/none      | idle/none     |
/// | ap               | ap/none      | awaiting_proof/prompt_proof | ap/none | ap/none      | ap/none          | ap/none           | ap/none         | idle/stop_ap   | idle/stop_ap  |
/// | awaiting_proof   | awaiting_proof/none | awaiting_proof/none | credentials/none | failed/stop_ap | awaiting_proof/none | awaiting_proof/none | awaiting_proof/none | failed/stop_ap | idle/stop_ap |
/// | credentials      | credentials/none | credentials/none | credentials/none | credentials/none | connecting/save_creds | credentials/none | credentials/none | failed/stop_ap | idle/stop_ap |
/// | connecting       | connecting/none | connecting/none  | connecting/none  | connecting/none | connecting/none  | connected/notify_ok | connecting/backoff | connecting/backoff | idle/reset    |
/// | connected        | connected/none | connected/none   | connected/none   | connected/none | connected/none   | connected/none    | connected/none  | connected/none | idle/reset    |
/// | failed           | failed/none  | failed/none      | failed/none      | failed/none    | failed/none      | failed/none       | failed/none     | failed/none    | idle/reset    |
///
/// 语义要点：
///
/// 1. **`idle` 只认 `start`**：其余事件一律 `none`；`idle` 下 `cancel` 是空操作
///    （没有可拆的上下文，返回 `none` 而不是 `reset`）。
/// 2. **`ap` 阶段的重复 `start` 不重启 AP**：避免已接入的客户端被踢下线。
/// 3. **`awaiting_proof + creds_ok` 被忽略**：没证明就不能收凭据，凭据既不入状态也不触发保存。
/// 4. **`credentials + proof_fail` 被忽略**：证明已通过，迟到的失败是过期事件，
///    不能把已经进入凭据阶段的会话打回 `failed`。
/// 5. **超时语义随状态**：`ap` 等客户端超时 → 回 `idle` 收 AP；`awaiting_proof`/`credentials`
///    超时 → `failed` 并停 AP（此时凭据一定不会被保存）；`connecting` 超时等同于连接失败。
/// 6. **`failed` 是安全终态**：证明失败、证明窗口超时、凭据窗口超时都进这里；
///    只有 `cancel` 能回到 `idle`（并 `reset`），因此「绕过证明重试」不可能发生。
/// 7. **连接失败在 `connecting` 内重试**：`connecting + connect_fail/timeout → connecting/backoff`。
///    凭据已经保存、SoftAP 已经关闭，所以不回退到 `idle`/AP 重新配网；
///    调用方按自己的退避节奏重发 STA 连接，成功后再等 `connect_ok`。
///    只有 `cancel` 才拆掉 STA 回 `idle`。
/// 8. **`connected` 之后的事件全部忽略**：连上之后的掉线/漫游不归本切片管
///    （由 `netmgr/` 一类的运行时状态机承接）；`cancel` 才会拆掉 STA 回 `idle`。
pub fn step(state: State, event: Event) Transition {
    return switch (state) {
        .idle => switch (event) {
            .start => .{ .next = .ap, .action = .start_ap },
            // 没起 AP，任何客户端/证明/连接事件都无从谈起。
            .client_joined,
            .proof_ok,
            .proof_fail,
            .creds_ok,
            .connect_ok,
            .connect_fail,
            .timeout,
            .cancel,
            => .{ .next = .idle, .action = .none },
        },

        .ap => switch (event) {
            // 重复 start：不重启 AP，防止已接入的客户端被踢掉。
            .start => .{ .next = .ap, .action = .none },
            .client_joined => .{ .next = .awaiting_proof, .action = .prompt_proof },
            // 还没有证明/凭据/连接会话，这些结果不可信。
            .proof_ok,
            .proof_fail,
            .creds_ok,
            .connect_ok,
            .connect_fail,
            => .{ .next = .ap, .action = .none },
            // 一直没有客户端接入：收回 AP，由调用方按自己的节奏重新 start。
            .timeout => .{ .next = .idle, .action = .stop_ap },
            .cancel => .{ .next = .idle, .action = .stop_ap },
        },

        .awaiting_proof => switch (event) {
            .start => .{ .next = .awaiting_proof, .action = .none },
            // 单客户端模型：重复/第二个接入通知不改变会话。
            .client_joined => .{ .next = .awaiting_proof, .action = .none },
            .proof_ok => .{ .next = .credentials, .action = .none },
            .proof_fail => .{ .next = .failed, .action = .stop_ap },
            // 证明没过就送凭据：直接忽略，不保存、不前进。
            .creds_ok => .{ .next = .awaiting_proof, .action = .none },
            .connect_ok,
            .connect_fail,
            => .{ .next = .awaiting_proof, .action = .none },
            // 证明窗口超时：本次配网作废，且必须显式 cancel 才能重来。
            .timeout => .{ .next = .failed, .action = .stop_ap },
            .cancel => .{ .next = .idle, .action = .stop_ap },
        },

        .credentials => switch (event) {
            .start => .{ .next = .credentials, .action = .none },
            .client_joined => .{ .next = .credentials, .action = .none },
            // 证明已经通过，迟到/重复的证明结果不再改变会话。
            .proof_ok,
            .proof_fail,
            => .{ .next = .credentials, .action = .none },
            .creds_ok => .{ .next = .connecting, .action = .save_creds },
            .connect_ok,
            .connect_fail,
            => .{ .next = .credentials, .action = .none },
            // 凭据窗口超时：不保存任何东西，本次配网作废。
            .timeout => .{ .next = .failed, .action = .stop_ap },
            .cancel => .{ .next = .idle, .action = .stop_ap },
        },

        .connecting => switch (event) {
            .start,
            .client_joined,
            .proof_ok,
            .proof_fail,
            // 凭据已在进入 connecting 时保存；重复的 creds_ok 不重复保存。
            .creds_ok,
            => .{ .next = .connecting, .action = .none },
            .connect_ok => .{ .next = .connected, .action = .notify_ok },
            // 连接失败/超时：凭据已保存、AP 已关，留在 connecting 让调用方退避后重试 STA。
            .connect_fail => .{ .next = .connecting, .action = .backoff },
            .timeout => .{ .next = .connecting, .action = .backoff },
            .cancel => .{ .next = .idle, .action = .reset },
        },

        .connected => switch (event) {
            // 连上之后不再接受任何配网事件；掉线重连不归本切片。
            .start,
            .client_joined,
            .proof_ok,
            .proof_fail,
            .creds_ok,
            .connect_ok,
            .connect_fail,
            .timeout,
            => .{ .next = .connected, .action = .none },
            .cancel => .{ .next = .idle, .action = .reset },
        },

        .failed => switch (event) {
            // 安全终态：必须 cancel 才能重来，防止失败后直接跳过证明。
            .start,
            .client_joined,
            .proof_ok,
            .proof_fail,
            .creds_ok,
            .connect_ok,
            .connect_fail,
            .timeout,
            => .{ .next = .failed, .action = .none },
            .cancel => .{ .next = .idle, .action = .reset },
        },
    };
}
