# netmgr —— S31 网络管理器纯状态机（切片 C）

> 状态：**未编译、未测试、未上板**。本目录只有离线源码与文档，`zig build test` 一次都没有跑过。
> 契约来自 [`../SPEC.md`](../SPEC.md) §3.3，本切片不改动 `content/`、`practice/`、`scripts/`、`quartz/` 与仓库根文件。

## 1. 目的

把「链路起来 → 拿到 IP → 校准时间 → 对外可服务 → 掉链/失败后降级」这条运营路径
从驱动里剥出来，变成一张可以逐格枚举的迁移表：

- 板侧只负责**采集事件**（PHY 中断、`esp_netif` 回调、SNTP 回调）和**执行动作**（起 DHCP、起 SNTP、发通知、兜底复位）；
- 状态判断、动作选择全部在纯函数里，可以脱离硬件在 x86_64 上穷举。

## 2. 目录

```text
tools/s31-production/netmgr/
  README.md          # 本文件
  build.zig          # 只提供 addModule + test 步骤
  src/netmgr.zig     # 纯状态机（无 std 依赖、无分配、无 IO）
  src/host_tests.zig # 主机侧单测：30 格迁移表 + 不变量
```

## 3. 接口（与 SPEC §3.3 一致）

```zig
pub const State = enum { offline, link_up, dhcp, online, degraded };
pub const Event = union(enum) { link_up, link_down, dhcp_ok, dhcp_fail, time_ok, fatal };
pub const Action = enum { none, start_dhcp, start_sntp, notify_online, backoff, reset };
pub const Transition = struct { next: State, action: Action };
pub fn step(state: State, event: Event) Transition;
pub fn initialState() State; // == .offline
```

- `Transition` 是 SPEC 里匿名返回结构体的具名化，字段名仍是 `next` / `action`；
  这样调用方可以存进数组或用 `const` 提领，语义不变。
- 错误事件的 tag 用 `fatal`，不用 Zig 保留字 `error`。
- 两个纯函数没有任何副作用：同样入参永远同样出参，可以随便重放。

## 4. 迁移表

行=当前状态，列=事件；单元格为 `下一状态 / 动作`。

| 状态 \ 事件 | `link_up`                | `link_down`         | `dhcp_ok`               | `dhcp_fail`            | `time_ok`                  | `fatal`             |
| ----------- | ------------------------ | ------------------- | ----------------------- | ---------------------- | -------------------------- | ------------------- |
| `offline`   | `link_up` / `start_dhcp` | `offline` / `none`  | `offline` / `none`      | `offline` / `none`     | `offline` / `none`         | `offline` / `reset` |
| `link_up`   | `link_up` / `none`       | `offline` / `reset` | `dhcp` / `start_sntp`   | `degraded` / `backoff` | `link_up` / `none`         | `offline` / `reset` |
| `dhcp`      | `dhcp` / `none`          | `offline` / `reset` | `dhcp` / `start_sntp`   | `degraded` / `backoff` | `online` / `notify_online` | `offline` / `reset` |
| `online`    | `online` / `none`        | `offline` / `reset` | `online` / `start_sntp` | `degraded` / `backoff` | `online` / `none`          | `offline` / `reset` |
| `degraded`  | `link_up` / `start_dhcp` | `offline` / `reset` | `dhcp` / `start_sntp`   | `degraded` / `backoff` | `degraded` / `none`        | `offline` / `reset` |

语义要点：

1. **非法事件保持原状态且返回 `none`**：`offline` 下的 `dhcp_ok`/`dhcp_fail`/`time_ok`、
   `link_up` 下的 `time_ok`、`dhcp`/`online` 下的 `link_up`、`offline` 下的 `link_down` 都属于此类。
2. **`fatal` 是全局兜底**：任何状态都回 `offline` 并 `reset`，即冷启动链路层；
   `fatal` 不携带原因码，诊断信息由调用方另行记录。
3. **`link_down` 一律回 `offline`**：主链路任意一点掉链都不保留中间态，
   避免「地址还在但链路已断」的假在线。
4. **重复 `dhcp_ok` 只重启校时**：`dhcp`/`online` 下收到续约成功，不会退回 `link_up`，
   但仍要求重新 SNTP（租约变化可能换地址/DNS）。
5. **`degraded` 是唯一的重试态**：由 `dhcp_fail` 进入，可经 `link_up` 重拉 DHCP、
   经 `dhcp_ok` 回到 `dhcp`、经 `link_down`/`fatal` 回 `offline`；
   **不能**经 `time_ok` 直接回 `online`（见下条）。
6. **保守恢复规则（`degraded + time_ok` 停在 `degraded`/`none`）**：本模型没有「是否持有租约」
   标志，`degraded` 至少有三种来源——`link_up + dhcp_fail`（从未拿到地址）、
   `dhcp + dhcp_fail`（已拿到地址、尚未上线时的续约失败）、`online + dhcp_fail`（上线后租约失效）。此时到达的
   `time_ok` 无法证明本机有可用地址，直接 `notify_online` 会把不可服务的设备宣告为在线。
   因此恢复必须走完整链路：`degraded --dhcp_ok--> dhcp --time_ok--> online`。
   若将来引入租约标志，可在新版本里放开这条迁移，但需要单独的事件（如 `lease_lost`）。

## 5. 不变量（单测逐条断言）

- `fatal` ⇒ `offline` + `reset`（5 个状态全覆盖）。
- `backoff` 只能由 `dhcp_fail` 产生，且目标状态必为 `degraded`。
- `reset` 只能由 `fatal`，或非 `offline` 状态下的 `link_down` 产生。
- `notify_online` 只出现在目标状态为 `online` 的迁移上。
- 进入 `online` 的唯一迁移是 `dhcp + time_ok`（其余只能「本来就是 online」）；
  `degraded`/`link_up`/`offline` 永远不是 `online` 的入口 —— 这条断言在 5×6 全表上跑。
- 6 个 `Action` 在迁移表里都至少被用到一次。

## 6. 调用方职责（本切片刻意不做的事）

| 事情                        | 归属   | 说明                                                                        |
| --------------------------- | ------ | --------------------------------------------------------------------------- |
| 超时判定                    | 调用方 | 本模块不读时钟，DHCP/SNTP 是否「失败」由调用方计时后送 `dhcp_fail`。        |
| 退避时长与重试上限          | 调用方 | `Action.backoff` 只是「请按你的策略退避」，秒数、指数倍数、上限都在调用方。 |
| 重试计数                    | 调用方 | 需要计数时用调用方自己的变量（注入式），本模块不持有状态。                  |
| socket / lwIP / `esp_netif` | 调用方 | `start_dhcp`/`start_sntp`/`reset` 都是命令，执行体在板侧。                  |
| PHY 中断、链路检测          | 调用方 | 由 PHY 驱动翻译成 `link_up`/`link_down`。                                   |
| 日志与诊断                  | 调用方 | `fatal` 不带原因码，毁机现场由调用方保存。                                  |

调用侧的最小骨架（示意，未编译）：

```zig
var state = netmgr.initialState();
var retry: u32 = 0;                       // 注入式计数，模块不持有
while (pollEventTimeout(&retry)) |ev| {   // 超时在调用方换算成 dhcp_fail
    const t = netmgr.step(state, ev);
    state = t.next;
    switch (t.action) {
        .none => {},
        .start_dhcp => netif.startDhcp(),
        .start_sntp => sntp.restart(),
        .notify_online => hooks.markServing(),
        .backoff => retry += 1,           // 时长策略由调用方决定
        .reset => netif.teardown(),
    }
}
```

## 7. 与真实 PHY / DHCP / SNTP 的边界

- **PHY/链路层**：本模块只认 `link_up`/`link_down` 两个事件。真实 ESP32-S31 上它们应当来自
  PHY 驱动的链路状态回调（ch17 的 MAC/PHY 路径尚未上板验证，见
  `practice/zig-esp32-s31/BRINGUP-2026-11-12.md`）；本切片**没有**实现任何 PHY 读写。
- **DHCP**：`start_dhcp` 是给 `esp_netif`（或自研 lwIP DHCP 客户端）的指令，
  租约有效期、续约时机、`dhcp_fail` 的超时阈值都由调用方计时；本切片**没有**报文编解码。
- **SNTP**：`start_sntp` 同上；`time_ok` 表示「校时成功」，是否接受某个时间源、
  抖动容差如何判定，本模块不管。
- **动作幂等性**：`start_dhcp`/`start_sntp` 可能被重复发出（如续约后重启校时），
  执行体必须是可重复调用而不崩溃的；这一条约束在调用方，测试覆盖不到。
- **并发**：`step` 不是线程安全的「共享状态机」，状态变量归调用方所有；
  跨任务使用时由调用方加锁或固定到单一事件循环任务。

## 8. 验收

| 项                                                         | 状态                                          |
| ---------------------------------------------------------- | --------------------------------------------- |
| 接口名与 SPEC §3.3 一致（`State`/`Event`/`Action`/`step`） | 已实现，未编译                                |
| `Event` 用 `fatal` 而非 `error`                            | 已实现，未编译                                |
| 主链路 `offline→link_up→dhcp→online`                       | 单测已写，未运行                              |
| 非法事件保持原状态 + `none`                                | 单测已写，未运行                              |
| 退化/恢复与回到 `offline`                                  | 单测已写，未运行                              |
| 无硬件 / 无 IDF / 无时钟 / 无 socket 依赖                  | 源码级可核对（`src/netmgr.zig` 无 `@import`） |
| `zig build test` 可跑                                      | **未执行**（本切片禁止构建）                  |
| 上板联调                                                   | **未做**                                      |

`src/host_tests.zig` 的内容：

- 30 格迁移表逐格断言，并检查每个 `(state, event)` 组合恰好出现一次（防漏格、防重复）；
- 命名用例：主链路、非法事件、`backoff` 语义、退化与恢复、`fatal` 兜底、重复事件幂等；
- 负例（回归防护）：`link_up→dhcp_fail→degraded→time_ok`、`dhcp→dhcp_fail→degraded→time_ok`、
  `online→dhcp_fail→degraded→time_ok` 三条路径都必须停在 `degraded`/`none`，不得进 `online`；
- 全局不变量：`backoff`/`reset`/`notify_online` 的来源约束、进入 `online` 的入口约束
  （只允许 `dhcp + time_ok`；`degraded`/`link_up`/`offline` 永远不是入口）、`Action` 全覆盖。

## 9. 未验证边界（必须明说）

1. **未编译**：`build.zig` 用的是 0.17.1 的 `b.createModule` / `b.addTest` / `b.graph.host`
   写法，与 `practice/zig-esp32-s31/ch20-tcp-state-machine/build.zig` 同风格；没有跑过 `zig build`。
2. **未测试**：`src/host_tests.zig` 没有执行过，测试数量、断言结果都未确认。
3. **未上板**：没有任何 PHY/DHCP/SNTP 的真实集成，迁移表只表达设计意图。
4. **未接 IDF**：没有 `esp_netif`/`esp_event` 适配层；将来接入时需要新增一层事件翻译，
   届时 `Event` 是唯一契约面。
5. 本模块不处理 IPv6/多网口/漫游（WiFi↔以太网切换）：多接口需要按接口实例化多份状态变量，
   而不是复用同一份，本切片没有建模。
