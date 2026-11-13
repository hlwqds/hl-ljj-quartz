//! S31 故障恢复策略：纯函数决策，不触硬件。
//!
//! 本模块只回答一个问题：**这一次复位之后，设备应该走哪条恢复路径**。
//! 输入全部由调用方注入（复位原因、连续失败次数、阈值、当前相位），
//! 输出是一个枚举建议，执行动作（复位、切槽、擦配置、进降级模式）都在调用方：
//!
//!   - 不读复位原因寄存器、不读 RTC / RTC memory，也不读 `otadata`；
//!   - 不写 flash、不擦 NVS、不做复位、不喂狗、不改分区；
//!   - 不持有全局状态，不分配内存，不读时钟；同输入恒得同输出。
//!
//! 这样做的原因：复位原因与连续失败计数是**跨复位**状态，必须落在
//! bootloader / RTC memory / NVS 这些真正持久的地方；把它们做成注入参数，
//! 策略才能在主机上被穷举，也避免和 ch28 的 `bootslot.zig`、`ota/` 的
//! 槽位状态机互相复制一份持久化逻辑。
//!
//! 优先级固定（SPEC §3.7）：
//!
//! 1. `phase == after_rollback` 且 `consecutive_failures >= threshold` → `factory_reset`；
//! 2. `consecutive_failures >= threshold` → `rollback`；
//! 3. `reason ∈ {panic, watchdog, brownout}` → `safe_mode`；
//! 4. 其余 → `normal`。
//!
//! 判定顺序就是短路顺序：第 1 条命中后不再看 `reason`，第 2 条命中后
//! 不再看 `reason`，所以「panic + 达阈值」得到的是 `rollback` 而不是
//! `safe_mode`。这不是遗漏，而是策略：已经确认坏掉的镜像不该再用降级模式
//! 硬撑，先回滚。

/// 最近一次复位的原因，由调用方从启动侧的复位原因寄存器/日志映射而来。
///
/// 本模块不解释这些值的来源，也不区分「冷启动」与「深睡唤醒」——
/// 后者在没有任何复位标志时同样落进 `power_on`，由调用方自己判读。
///
/// - `power_on`：区别于欠压的正常上电冷启动；
/// - `panic`：trap / 非法指令 / 断言失败等软件崩溃（见 ch15 的 `trap.zig`）；
/// - `watchdog`：硬件或软件看门狗超时（见 ch15 的 `watchdog.zig`、RTC WDT）；
/// - `brownout`：欠压复位；
/// - `ota_rollback`：主 bootloader 因新镜像失败而回滚后复位；
/// - `software`：正常软件主动复位（重启命令、配置生效等）；
/// - `unknown`：读不到或无法识别复位原因。
pub const ResetReason = enum { power_on, panic, watchdog, brownout, ota_rollback, software, unknown };

/// 当前镜像所处的恢复相位，由调用方按「还能不能回滚」判断后注入。
///
/// - `first_boot`：当前镜像还有一次回滚额度（正常上电、软件复位，以及
///   刚进入某个镜像、尚未用掉回滚额度的启动）；
/// - `after_rollback`：当前镜像**本身就是回滚后的产物**，没有下一个槽可退；
///   它的连续失败只能以恢复出厂收场。
///
/// `phase` 与 `reason` 是独立的两条信息：`reason` 说明「这一次为什么复位」，
/// `phase` 说明「当前镜像还能不能回滚」。例如回滚刚发生时，bootloader 报告的
/// 原因是 `ota_rollback`，但存活槽是否已经用尽额度只有调用方知道。本模块
/// **不做交叉校验**，也不从 `reason == .ota_rollback` 反推相位。
pub const Phase = enum { first_boot, after_rollback };

/// 策略建议。只描述「该走哪条路」，不含任何执行细节。
///
/// - `normal`：按正常路径继续启动；调用方应在自检通过后清零连续失败计数；
/// - `safe_mode`：降级运行（最小服务、只读/诊断、等待人工介入）；
/// - `rollback`：让 bootloader 切回上一可启动槽并复位；
/// - `factory_reset`：无路可退，恢复出厂（擦配置/凭据后回到已知良好镜像）。
pub const Decision = enum { normal, safe_mode, rollback, factory_reset };

/// 默认相位：还没有发生过回滚。
///
/// 调用方在首次上电、以及自检通过后重新计数时应回到这个值；只有确认
/// 「当前跑的就是回滚结果」时才传 `after_rollback`。
pub fn initialPhase() Phase {
    return .first_boot;
}

/// 复位原因本身是否要求降级运行。
///
/// 这是优先级第 3 条的独立投影，供调用方渲染决策依据、或在别的判定路径里
/// 复用；`classify` 内部也用它，避免两处各写一份原因白名单。
///
/// 注意：`ota_rollback` 不在其中——回滚本身是正常恢复动作，回滚后的镜像
/// 仍可正常启动；是否安全取决于后续运行是否再次失败（第 1/2 条）。
pub fn needsSafeMode(reason: ResetReason) bool {
    return switch (reason) {
        .panic, .watchdog, .brownout => true,
        .power_on, .ota_rollback, .software, .unknown => false,
    };
}

/// 核心判定：给定复位原因与连续失败计数，返回恢复建议。
///
/// - `consecutive_failures`：跨复位累计的连续失败次数，由调用方持久化并注入。
///   本模块只比较、不累加、不清零，也不处理 `u8` 饱和——调用方在到达
///   `threshold` 之后应停止累加（或饱和到 255），否则计数会回绕成小值而
///   让策略误判为「还没到阈值」。
/// - `threshold`：触发回滚/恢复出厂所需的失败次数。`failures == threshold`
///   即触发；`threshold == 0` 视为「至少 1 次」，避免一次干净启动被误判为
///   回滚/恢复出厂。
///
/// 判定顺序即短路顺序，`reason` 只在未达阈值时参与：
///
/// | 相位 \ 计数        | failures < threshold | failures >= threshold |
/// | ------------------ | -------------------- | --------------------- |
/// | `first_boot`       | 按 `reason` 判       | `rollback`            |
/// | `after_rollback`   | 按 `reason` 判       | `factory_reset`       |
///
/// 「按 `reason` 判」= `panic`/`watchdog`/`brownout` → `safe_mode`，其余 → `normal`。
pub fn classify(reason: ResetReason, consecutive_failures: u8, threshold: u8, phase: Phase) Decision {
    if (streakReached(consecutive_failures, threshold)) {
        const decision: Decision = switch (phase) {
            .after_rollback => .factory_reset,
            .first_boot => .rollback,
        };
        return decision;
    }

    if (needsSafeMode(reason)) return .safe_mode;
    return .normal;
}

/// 连续失败是否达到阈值。
///
/// 单独拆出来是为了让「等于即触发」和「`threshold == 0` 按 1 处理」只有
/// 一份实现，测试也能直接盯住边界。
fn streakReached(consecutive_failures: u8, threshold: u8) bool {
    const effective: u8 = if (threshold == 0) 1 else threshold;
    return consecutive_failures >= effective;
}
