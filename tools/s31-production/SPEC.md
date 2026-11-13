# S31 生产化增量 SPEC（v0）

> 状态：**设计/骨架阶段：Zig 未编译/未上板/未跑测试；HIL 仅做过 Python 语法编译，CLI 未执行。**本文件只定义生产化第一刀的边界与契约；
> 不替换 `practice/zig-esp32-s31/SPEC.md` 的章节工程契约，也不改动 ch01–ch28 的既有目录与深链。

## 1. 目标

把“教学全栈”推进到“可运营平台”的第一批可离线交付物：

| 切片     | 交付                                                  | 不做什么               |
| -------- | ----------------------------------------------------- | ---------------------- |
| baseline | 生产基线门禁矩阵 + 只读检查脚本                       | 不执行构建/测试        |
| ota      | 纯逻辑 OTA 规划器（分区/选槽/清单/回滚状态机）        | 不写 flash、不验真签名 |
| netmgr   | 纯逻辑网络管理器状态机（离线/连上/DHCP/在线/退化）    | 不碰 socket/PHY        |
| hil      | HIL runner 骨架（烧录/串口/继电器/断言，`--dry-run`） | 不接触真实硬件         |

## 2. 目录与互斥

```text
tools/s31-production/
  SPEC.md          # 本文件（主线维护）
  baseline/        # 切片 A
  ota/             # 切片 B
  netmgr/          # 切片 C
  hil/             # 切片 D
```

- 每个切片只写自己的目录；**不得**修改 `content/`、`practice/zig-esp32-s31/ch*/`、
  `scripts/`、`quartz/` 或仓库根文件。
- 每个切片交付 `README.md`，写明目的、接口、验收、未验证边界。
- 不运行 `zig build`、`npm run code-site`、Quartz、任何测试或烧录。

## 3. 共享契约

### 3.1 语言/版本

- Zig：0.17.1 语法，纯逻辑模块，不依赖 IDF。
- Python：3.10+ 标准库优先；串口/继电器用可选依赖，缺依赖时给出清晰错误。
- 文档：中文；代码注释中文；标识符英文。

### 3.2 OTA 规划器接口（切片 B 可细化，但保持这些名字）

```zig
pub const Slot = enum(u1) { a, b };
pub const SlotState = enum(u8) { new, pending, valid, invalid, aborted };
pub const Reason = enum { ok, no_valid_sector, state_not_bootable };
pub const Decision = struct { slot: ?Slot, reason: Reason };
pub const Event = union(enum) { stage, set_boot, boot: Attempt, confirm, fail: Failure, abort };
pub fn selectSlot(otadata_a: []const u8, otadata_b: []const u8) Decision;
pub fn canBoot(state: SlotState) bool;
pub fn nextState(state: SlotState, event: Event) SlotState;
```

- 只接受 `valid` / `pending` 启动；`new/invalid/aborted` 回退。
- 生命周期必须显式：`stage` 只把镜像写成 `new`；`set_boot` 才把 `new` 写进 `otadata` 并转 `pending`；`boot` 只对 `pending/valid` 有效。禁止把“首次启动”建模成直接启动 `new`。
- 清单校验用可注入的 `Verifier` 回调，不在本切片实现 Ed25519/SHA-256。
- 验收：主机测试覆盖 CRC/seq/坏扇区/回滚预算/降级拒绝/`stage→set_boot→boot` 顺序；不运行。

### 3.3 网络管理器接口（切片 C 可细化）

```zig
pub const State = enum { offline, link_up, dhcp, online, degraded };
pub const Event = union(enum) { link_up, link_down, dhcp_ok, dhcp_fail, time_ok, fatal };
pub const Action = enum { none, start_dhcp, start_sntp, notify_online, backoff, reset };
pub const Transition = struct { next: State, action: Action };
pub fn step(state: State, event: Event) Transition;
```

- 纯状态机；超时/退避由调用方注入，不读时钟。
- 验收：合法迁移、非法事件保持原状态、退化路径可回到 offline；`degraded + time_ok` 必须保持 `degraded`（无租约标志，不允许乐观恢复 `online`）。

### 3.4 HIL runner 接口（切片 D）

```bash
python tools/s31-production/hil/hil.py --config hil.json --suite smoke --dry-run
```

- `--dry-run` 必须只打印计划，不打开串口、不烧录、不吸合继电器。
- JSON 结果：`{"ok":bool,"suite":str,"steps":[...],"artifacts":[...]}`。
- 验收：`--help` 与 `--dry-run` 可读；缺配置/缺依赖时报错清晰；不执行真实动作。

### 3.5 OTA 清单校验（扩展 `ota/`）

- 结构：44 B 头（`S31M`、`version:u32`、`image_len:u32`、`digest[32]`）+ 尾部不透明签名字节（≥64 B）。
- 顺序：长度/magic/`image_len` → 版本单调（拒绝 `candidate <= current`）→ 把头部与镜像交给注入的
  `Verifier`；**结构检查通过前不得调用 verifier**。
- `Verifier` 只返回 bool，不实现 SHA-256/Ed25519；签名长度/算法由后续密码学切片负责。
- 验收：坏 magic、短头、长度不符、同版本/降级、verifier 拒绝、verifier 接收原始尾字节；不运行。

### 3.6 配网状态机（`provisioning/`）

```zig
pub const State = enum { idle, ap, awaiting_proof, credentials, connecting, connected, failed };
pub const Event = union(enum) { start, client_joined, proof_ok, proof_fail, creds_ok, connect_ok, connect_fail, timeout, cancel };
pub const Action = enum { none, start_ap, stop_ap, prompt_proof, save_creds, notify_ok, backoff, reset };
pub fn step(state: State, event: Event) struct { next: State, action: Action };
```

- 纯状态机；PoP 证明与 STA 连接由调用方执行，不读时钟、不碰 socket。
- `connected` 只能由 `connecting + connect_ok` 进入；`proof_fail`/`timeout` 不得跳过证明。
- `save_creds` 是组合动作：持久化凭据 → 停 SoftAP → 发起 STA。
- `connecting + connect_fail/timeout` 保持 `connecting` 并返回 `backoff`（凭据已保存，调用方重试 STA）；只有 `cancel` 回 `idle/reset`，不得退回 SoftAP 重新配网。
- 验收：非法事件保持原状态；失败可回 `idle`；超时不自动保存凭据。

### 3.7 故障恢复策略（`recovery/`）

```zig
pub const ResetReason = enum { power_on, panic, watchdog, brownout, ota_rollback, software, unknown };
pub const Phase = enum { first_boot, after_rollback };
pub const Decision = enum { normal, safe_mode, rollback, factory_reset };
pub fn classify(reason: ResetReason, consecutive_failures: u8, threshold: u8, phase: Phase) Decision;
```

- 纯策略，优先级固定：
  1. `phase == after_rollback` 且 `consecutive_failures >= threshold` → `factory_reset`；
  2. `consecutive_failures >= threshold` → `rollback`；
  3. `reason` ∈ {`panic`/`watchdog`/`brownout`} → `safe_mode`；
  4. 其余 → `normal`。
- 阈值边界：`failures == threshold` 即触发；`threshold == 0` 按 1 处理（干净启动不触发回滚/恢复出厂）。
- 不写 flash、不读 RTC；计数与复位原因由调用方注入。
- 验收：阈值边界、各复位原因、回滚后再次失败；不运行。

### 3.8 已知跨增量差异（不在本批修复）

`ota/` 与 ch28 的 `bootslot.zig` 共享 16 B `S31B` + CRC32 布局，但状态字节策略不同：
`ota/` 只接受 `0..4`（`0xFF` = `BadState`），ch28 把 `0xFF` 接受为 `undefined_` 后拒绝启动。
本批把 `ota/` 标为生产侧候选规范，**不修改 ch28**；迁移任务单列：ch28 bootslot 委托 `ota/`，
共享 KAT 向量，更新两侧 README/SPEC。详见 `ota/README.md` 顶部提示。

## 4. 验收（主线统一）

1. 逐切片核对文件存在、README 边界、接口名与 SPEC 一致。
2. 不跑 Zig 构建/测试、不跑 HIL CLI、不上板；HIL 切片仅做过 `python -m py_compile` 语法检查，必须在总结中与“未运行验证”区分。
3. 不提交；不把工作区里 lwip/onvif/wifi-basics 等既有改动带入。
