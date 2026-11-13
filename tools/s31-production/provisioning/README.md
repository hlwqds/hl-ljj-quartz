# provisioning —— S31 配网纯状态机（生产化第二增量）

> 状态：**宿主测试已通过（18/18，2026-11-13）；未上板**。`zig build test` 已实际执行，
> 也没有在 ESP32-S31 台架上起过 SoftAP、收过凭据或连过 STA。
> 契约来自 [`../SPEC.md`](../SPEC.md) §3.6；本切片不改动 `content/`、`practice/`、`scripts/`、
> `quartz/` 与仓库根文件，也不碰 `ota/`、`netmgr/`、`recovery/` 等其它切片目录。

## 1. 目的

把「起 AP → 客户端接入 → PoP 证明 → 收 STA 凭据 → 保存并连接 → 上线」这条配网路径
从射频/协议栈里剥出来，变成一张可以逐格枚举的迁移表：

- 板侧只负责**采集事件**（SoftAP 接入回调、PoP 校验结果、凭据校验结果、STA 连接回调、计时器）
  和**执行动作**（起停 AP、索取证明、保存凭据、发上线通知、退避、拆除上下文）；
- 状态判断、动作选择全部落在纯函数 `step` 里，可以脱离硬件在 x86_64 上穷举。

本切片**不做**的事（重要）：PoP 密码学校验、凭据持久化实现、STA 关联/DHCP、SoftAP 与协议栈、
超时计时、凭据格式的合法性判定。这些都由调用方执行，本模块只给「该做什么」。

## 2. 目录

```text
tools/s31-production/provisioning/
  README.md          # 本文件
  build.zig          # 只提供 addModule + test 步骤
  src/provisioning.zig   # 纯状态机（无 @import、无分配、无 IO、不读时钟）
  src/host_tests.zig     # 主机侧单测：63 格迁移表 + 不变量 + 负例
```

## 3. 接口（与 SPEC §3.6 一致）

```zig
pub const State = enum { idle, ap, awaiting_proof, credentials, connecting, connected, failed };
pub const Event = union(enum) {
    start, client_joined, proof_ok, proof_fail,
    creds_ok, connect_ok, connect_fail, timeout, cancel,
};
pub const Action = enum {
    none, start_ap, stop_ap, prompt_proof,
    save_creds, notify_ok, backoff, reset,
};
pub const Transition = struct { next: State, action: Action };
pub fn step(state: State, event: Event) Transition;
pub fn initialState() State; // == .idle
```

- `Transition` 是 SPEC 里匿名返回结构体的具名化，字段名仍是 `next` / `action`；
  语义不变，但调用方可以存进数组或用 `const` 提领。
- 两个函数都是纯函数：同样入参永远同样出参，可以随便重放、可以在测试里穷举。
- 全部 `Event` 无载荷：失败原因、重试计数、超时时长都由调用方保存。

## 4. 迁移表

行=当前状态，列=事件；单元格为 `下一状态 / 动作`。

| 状态 \ 事件      | `start`                   | `client_joined`                   | `proof_ok`             | `proof_fail`           | `creds_ok`                  | `connect_ok`              | `connect_fail`            | `timeout`                | `cancel`           |
| ---------------- | ------------------------- | --------------------------------- | ---------------------- | ---------------------- | --------------------------- | ------------------------- | ------------------------- | ------------------------ | ------------------ |
| `idle`           | `ap` / `start_ap`         | `idle` / `none`                   | `idle` / `none`        | `idle` / `none`        | `idle` / `none`             | `idle` / `none`           | `idle` / `none`           | `idle` / `none`          | `idle` / `none`    |
| `ap`             | `ap` / `none`             | `awaiting_proof` / `prompt_proof` | `ap` / `none`          | `ap` / `none`          | `ap` / `none`               | `ap` / `none`             | `ap` / `none`             | `idle` / `stop_ap`       | `idle` / `stop_ap` |
| `awaiting_proof` | `awaiting_proof` / `none` | `awaiting_proof` / `none`         | `credentials` / `none` | `failed` / `stop_ap`   | `awaiting_proof` / `none`   | `awaiting_proof` / `none` | `awaiting_proof` / `none` | `failed` / `stop_ap`     | `idle` / `stop_ap` |
| `credentials`    | `credentials` / `none`    | `credentials` / `none`            | `credentials` / `none` | `credentials` / `none` | `connecting` / `save_creds` | `credentials` / `none`    | `credentials` / `none`    | `failed` / `stop_ap`     | `idle` / `stop_ap` |
| `connecting`     | `connecting` / `none`     | `connecting` / `none`             | `connecting` / `none`  | `connecting` / `none`  | `connecting` / `none`       | `connected` / `notify_ok` | `connecting` / `backoff`  | `connecting` / `backoff` | `idle` / `reset`   |
| `connected`      | `connected` / `none`      | `connected` / `none`              | `connected` / `none`   | `connected` / `none`   | `connected` / `none`        | `connected` / `none`      | `connected` / `none`      | `connected` / `none`     | `idle` / `reset`   |
| `failed`         | `failed` / `none`         | `failed` / `none`                 | `failed` / `none`      | `failed` / `none`      | `failed` / `none`           | `failed` / `none`         | `failed` / `none`         | `failed` / `none`        | `idle` / `reset`   |

语义要点：

1. **`idle` 只认 `start`**。没起 AP 时的客户端/证明/连接/超时事件一律 `none`；
   `idle + cancel` 也是 `none`（没有上下文可拆，不应返回 `reset`）。
2. **`ap` 阶段的重复 `start` 不重启 AP**（`ap`/`none`）：重启会踢掉已接入的客户端。
3. **证明不可跳过**：`awaiting_proof + creds_ok` 被忽略——凭据既不进状态也不触发保存；
   `ap + creds_ok` 同理。进入 `credentials` 的唯一迁移是 `awaiting_proof + proof_ok`。
4. **`credentials + proof_fail` 被忽略**：证明已通过，迟到的失败是过期事件，
   不能把已经进入凭据阶段的会话打回 `failed`（否则一次乱序回调就能毁掉整个配网会话）。
5. **超时语义随状态**：
   - `ap + timeout` → `idle`/`stop_ap`：一直没人接入，收回 AP，调用方可稍后重开；
   - `awaiting_proof + timeout`、`credentials + timeout` → `failed`/`stop_ap`：
     本次配网作废，**凭据一定不会被保存**；
   - `connecting + timeout` → `connecting`/`backoff`：等同连接失败，原地重试，不回 AP。
6. **`failed` 是安全终态**：证明失败、证明窗口超时、凭据窗口超时都进这里；
   只有 `cancel` 能回到 `idle`（并 `reset`）。所以「失败后直接跳过证明重试」在状态图里不可能发生。
7. **连接失败在 `connecting` 内重试**：`connecting + connect_fail/timeout → connecting/backoff`。
   凭据已经保存、SoftAP 已经关闭，所以**不回退**到 `idle`/AP 重新配网；
   调用方按自己的退避节奏重发 STA 连接，成功后照旧由 `connect_ok` 进入 `connected`。
   退出连接重试只有 `cancel`（→ `idle`/`reset`）。
8. **`connected` 之后不再接受配网事件**：连上后的掉线/漫游不归本切片
   （由 `netmgr/` 一类的运行时状态机承接）；只有 `cancel` 会拆掉 STA 回 `idle`。

### 4.1 为什么 `creds_ok` 只返回一个动作

`credentials + creds_ok` 实际有三个副作用：**保存凭据**、**停止 SoftAP**、**发起 STA**。
`Action` 一次迁移只能带一个动作，本切片用 `save_creds` 把它们收成一个不可分的步骤：

- 丢凭据是不可接受的（客户端已经断开、需要重新配网），所以保存是第一步；
- 单射频下 SoftAP 与 STA 不能共存，而**迁移表在进入 `connecting` 时不会再发 `stop_ap`**
  （`stop_ap` 只出现在回 `idle` 的路径上），所以停 AP 必须由 `save_creds` 的语义承担；
- 保存成功后立即用新凭据发起 STA，调用方在 `next == .connecting` 时应当处于
  「AP 已关、STA 尝试中」；
- 因此 `Action` 只有 8 个 tag：连接阶段的重试由 `connecting + connect_fail/timeout`
  的 `backoff` 表达，不需要单独的「开始连接」动作。

三步顺序固定为：**持久化凭据 → 停 SoftAP → 发起 STA**，任意一步失败都算这次
`save_creds` 没完成，调用方应自行决定是否 `cancel`（本模块不引入新的失败事件）。

## 5. 不变量（单测逐条在 7×9 全表上断言）

- `save_creds` 只由 `credentials + creds_ok` 产生，目标状态必为 `connecting`；
- `timeout` 在任何状态下都不会产生 `save_creds`，也不会把状态**推进**到 `connecting`
  （`connecting + timeout` 只是原地重试）；
- `proof_fail` 在任何状态下都不会把状态推进到 `credentials`；
- 进入 `credentials` 的唯一迁移是 `awaiting_proof + proof_ok`；
- 进入 `connected` 的唯一迁移是 `connecting + connect_ok`；`notify_ok` 也只出现在这条迁移上；
- `failed` 只能由 `cancel` 退出，且只回 `idle`/`reset`；`connected` 同理；
- `start_ap` 只由 `idle + start` 产生；`stop_ap` 只会从已起过 AP 的状态回到 `idle`；
- `reset` 只从 `connecting`/`connected`/`failed` 回 `idle`；
  `backoff` 只从 `connecting` 产生且目标仍是 `connecting`（连接重试不离开连接阶段）；
- `prompt_proof` 只在 `ap + client_joined` 上出现；
- `Action` 的 8 个 tag 在迁移表里全部可达。

## 6. 调用方职责（本切片刻意不做的事）

| 事情            | 归属   | 说明                                                                                                                                                                          |
| --------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 超时计时与判定  | 调用方 | 本模块不读时钟；证明窗口、凭据窗口、连接超时都由调用方计时后送 `timeout`。                                                                                                    |
| PoP 校验        | 调用方 | `prompt_proof` 只是「去要证明」；证明的密码学验证、错误次数与锁定策略都在调用方。                                                                                             |
| 凭据持久化      | 调用方 | `save_creds` 是命令；写 NVS/文件、掉电一致性、写入失败回滚由调用方实现。                                                                                                      |
| STA 关联 / DHCP | 调用方 | `connect_ok`/`connect_fail` 由 STA 状态与 DHCP 结果翻译而来。                                                                                                                 |
| SoftAP 生命周期 | 调用方 | `start_ap`/`stop_ap` 的执行体（含 SSID、信道、安全模式、配网服务）在板侧。**注意**：进入 `connecting` 不会再收到 `stop_ap`，停 AP 必须发生在执行 `save_creds` 时（见 §4.1）。 |
| 凭据格式校验    | 调用方 | 本模块没有 `creds_fail` 事件：格式/长度非法的凭据**不要**送 `creds_ok`，继续等待直到 `timeout`，或直接 `cancel`。                                                             |
| 重试/退避策略   | 调用方 | `backoff` 只是「请按你的策略退避」；`connecting` 下的退避意味着重试 STA（不重开 AP），秒数与上限在调用方。                                                                    |
| 日志与诊断      | 调用方 | 事件无载荷，失败原因需要调用方自己记录。                                                                                                                                      |

调用侧的最小骨架（示意，未编译）：

```zig
var state = provisioning.initialState();
var retry: u32 = 0;                        // 注入式计数，模块不持有
while (pollEventTimeout(&retry)) |ev| {    // 超时在调用方换算成 Event.timeout
    const t = provisioning.step(state, ev);
    state = t.next;
    switch (t.action) {
        .none => {},
        .start_ap => softap.start(),
        .stop_ap => softap.stop(),
        .prompt_proof => prov.askProofOfPossession(),
        .save_creds => {
            try nvs.save(prov.lastCreds()); // 写失败时调用方自行决定是否 cancel
            softap.stop();                  // 单射频：进入 connecting 前必须停 AP
            sta.begin(prov.lastCreds());    // save_creds 的语义包含「保存→停 AP→发起 STA」
        },
        .notify_ok => hooks.markProvisioned(),
        .backoff => { retry += 1; sta.retry(); }, // 仍在 connecting：退避后重试 STA
        .reset => ctx.teardown(),
    }
}
```

## 7. 台架边界

- **本切片没有「台架」可跑**：没有可执行文件、没有 HIL 用例、不烧录、不打开串口/网卡。
  台架侧（ESP32-S31 + 真实 SoftAP/STA）的验证全部未做。
- **SoftAP/协议栈**：真实 SSID、信道、安全模式、配网服务（HTTP/BLE 等）都未实现；
  `start_ap`/`stop_ap` 只是命令名。
- **单射频**：进入 `connecting` 时 SoftAP 必须已经关闭（由执行 `save_creds` 负责）；
  连接失败/超时只在 `connecting` 内重试 STA，不会重开 AP 重新配网。
  真实的 AP+STA 并发能力（若某颗芯片支持）不在本模型内。
- **单客户端模型**：`ap + client_joined` 只建模一个客户端；第二个接入通知在
  `awaiting_proof` 下被忽略（`none`）。多客户端并发配网需要另行建模（例如按会话实例化）。
- **连接后生命周期**：`connected` 之后的掉线、漫游、重连不在本切片；本模块也不会因为
  `timeout` 把已连接的 STA 踢掉。
- **并发**：`step` 不是线程安全的共享状态机；状态变量归调用方，跨任务使用时由调用方加锁
  或固定到单一事件循环任务。
- **顺序假设**：调用方按单一事件队列串行投递事件；乱序/重放事件只会被忽略或保持原状态
  （见 §4 要点 3、4、8），不会跳阶段。

## 8. 验收

| 项                                                               | 状态                                                      |
| ---------------------------------------------------------------- | --------------------------------------------------------- |
| 接口名与 SPEC §3.6 一致（`State`/`Event`/`Action`/`step`）       | 已实现，已编译（2026-11-13）                              |
| 主链路 `idle→ap→awaiting_proof→credentials→connecting→connected` | 单测已跑（18/18）                                         |
| 非法事件保持原状态 + `none`                                      | 单测已跑（18/18）                                         |
| `proof_fail`/`timeout` 不保存凭据、不进入 `credentials`          | 单测已跑（18/18；credentials 态迟到 proof_fail 保持原地） |
| `connected` 唯一入口是 `connecting + connect_ok`                 | 单测已跑（18/18）                                         |
| 失败可回 `idle`（仅 `cancel`）                                   | 单测已跑（18/18）                                         |
| 连接失败/超时留在 `connecting` 并 `backoff`，不回 AP             | 单测已跑（18/18）                                         |
| `Action` 无死 tag（8 个全部可达）                                | 单测已跑（18/18）                                         |
| 无硬件 / 无 IDF / 无时钟 / 无 socket 依赖                        | 源码级可核对（`src/provisioning.zig` 无 `@import`）       |
| `zig build test` 可跑                                            | **18/18 通过**（2026-11-13）                              |
| 上板联调（真 SoftAP/STA/PoP）                                    | **未做**                                                  |

`src/host_tests.zig` 的内容：

- 63 格迁移表逐格断言，并检查每个 `(state, event)` 组合恰好出现一次（防漏格、防重复）；
- 命名用例：主链路、非法事件、`cancel` 各类出口、`failed` 退出约束、
  连接失败/超时留在 `connecting` 重试、`cancel` 从 `connecting` 拆回 `idle`；
- 负例（回归防护）：
  - `ap + creds_ok`、`awaiting_proof + creds_ok` 都必须停在原地且不 `save_creds`；
  - `credentials + timeout` → `failed`，且全表任何 `timeout` 都不产生 `save_creds`；
  - `credentials + proof_fail` 停在 `credentials`（迟到事件不能毁掉会话）；
  - `failed` 下除 `cancel` 外任何事件都回不到 `credentials`；
- 全局不变量：`save_creds`/`start_ap`/`stop_ap`/`reset`/`backoff`/`prompt_proof`/`notify_ok`
  的来源与目标约束，进入 `credentials`/`connected` 的入口约束，`Action` 使用情况。

## 9. 未验证边界（必须明说）

1. **已编译**（宿主测试 18/18）：`build.zig` 用的是 0.17.1 的 `b.addModule` / `b.createModule` / `b.addTest` /
   `b.graph.host` 写法，与同目录其它切片同风格；没有跑过 `zig build`。
2. **未测试**：`src/host_tests.zig` 没有执行过，测试数量、断言结果都未确认。
3. **未上板**：没有真实 SoftAP、没有真实 STA、没有 PoP 校验、没有 NVS 写入；
   迁移表只表达设计意图。
4. **未接 IDF**：没有 `esp_wifi` / `esp_event` / `esp_netif` / `nvs_flash` 适配层。
   将来接入时 `Event` 是唯一契约面：把 WiFi 事件、证明结果、连接结果翻译成这 9 个 tag。
5. **未定义凭据内容**：SSID/口令的编码、长度上限、多网口（WiFi + 以太网）回落都不在本切片；
   凭据只是调用方手里的一段数据。
6. **未定义多客户端/会话隔离**：只建模单客户端、单会话；并发接入需要新的模型。
