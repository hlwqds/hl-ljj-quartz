# OTA 规划器（切片 B）

> 状态：**宿主测试已通过（8/8，2026-11-13）；未上板**。本目录交付源码与文档，供主线统一评审；
> 当前没有运行过 `zig build test`，也没有在 ESP32-S31 上读取过真实 `otadata`。
> 生产清单校验（`src/manifest.zig`）同样只有静态审阅：注入式 `Verifier`
> 只被测试替身调用，未接任何 SHA-256 / Ed25519 实现。
>
> **格式口径（重要）**：本目录是 v0 的独立模型，与 `practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/bootslot.zig` 都使用 16 B `S31B`/CRC32 布局，但状态字节策略不同：本模块只接受 `0..4`，`0xFF` 判 `BadState`；ch28 旧模型把 `0xFF` 接受为 `undefined_`（随后不可启动）。**本模块是生产侧候选规范**；在两份实现合并前，不应把两者当作可互换的读写器。迁移任务：ch28 的 bootslot 改为委托本模块，并补共享 KAT 向量。

## 1. 目的

把“OTA 该不该升、复位后该启动谁、连续失败怎么回滚”从教学演示收敛成一份
**可离线判定**的纯逻辑模块：

- `src/ota_plan.zig`：`otadata` 条目解析、双扇区选槽与槽状态机。
  不 import `std`，不分配内存，不读写 flash，不依赖 IDF。
- `src/manifest.zig`：**生产顺序**的清单校验：44 B `S31M` 头 + 尾随
  不透明签名（≥ 64 B），按“结构 → 版本 → 注入式 `Verifier`”准入。
  同样不 import `std`、不分配、不实现密码学。
- `src/host_tests.zig`：`ota_plan.zig` 的主机侧断言。
- `src/manifest_tests.zig`：`manifest.zig` 的主机侧断言。
- `build.zig`：只有 `zig build test` 一个步骤（两个测试根），无第三方依赖。

本切片**不负责**：真正的 SHA-256 / Ed25519 验签、flash 擦写、分区表、
bootloader 集成、回滚时选择物理分区。这些由主线其他切片/后续工作承接。

## 2. 接口（与 `../SPEC.md` §3.2 / §3.5 一致）

```zig
pub const Slot = enum(u1) { a, b };
pub const SlotState = enum(u8) { new, pending, valid, invalid, aborted };
pub const Decision = struct { slot: ?Slot, reason: Reason };

pub fn selectSlot(otadata_a: []const u8, otadata_b: []const u8) Decision;
pub fn canBoot(state: SlotState) bool;
pub fn nextState(state: SlotState, event: Event) SlotState;
```

本切片补充的细化（名字稳定，供上层调用）：

| 名字                          | 语义                                                              |
| ----------------------------- | ----------------------------------------------------------------- |
| `Reason.ok`                   | 选中的槽状态可启动                                                |
| `Reason.no_valid_sector`      | 两个扇区都过不了解码（含空白 flash 全 `0xFF`）                    |
| `Reason.state_not_bootable`   | 选出了 seq 最大的条目，但状态不在白名单                           |
| `Event.stage`                 | 该槽已写入新镜像（状态仍为 `new`）                                |
| `Event.set_boot`              | 把 `new` 槽写进 `otadata`，下一次复位由 bootloader 选中           |
| `Event.boot: Attempt`         | 一次启动，携带 `attempt` / `budget`；只对 `pending`/`valid` 有效  |
| `Event.confirm`               | 自检通过，确认该槽                                                |
| `Event.fail: Failure`         | 一次运行期失败，携带 `consecutive` / `budget`                     |
| `Event.abort`                 | 上层主动放弃该槽                                                  |
| `encodeEntry` / `decodeEntry` | 16 B `otadata` 条目的编解码（工具/测试用）                        |
| `pickEntry`                   | 只做“解码 + seq 取大”，不判状态                                   |
| `manifest.Header`             | `manifest.zig` 的 44 B 头：`version` / `image_len` / `digest[32]` |
| `manifest.decodeHeader`       | 只解析 44 B 头（工具/上位机读元数据）                             |
| `manifest.split`              | 切成 `header`（44 B）与 `signature`（≥ 64 B）                     |
| `manifest.Verifier`           | `(header, image, signature) -> bool`，只返回可信/不可信           |
| `manifest.validateCandidate`  | 生产顺序：结构（长度/magic/签名长度/image_len）→ 版本 → 验签      |

`Decision.slot == null` 表示**调用方必须回退 factory**；本模块不返回
factory 的地址，也不知道分区表。

## 3. `otadata` 条目（16 B）

| 偏移   | 字段     | 说明                                                          |
| ------ | -------- | ------------------------------------------------------------- |
| 0..4   | magic    | `S31B`（`0x53 0x33 0x31 0x42`）                               |
| 4..8   | seq      | u32 小端，越大越新                                            |
| 8      | slot     | `0` = A，`1` = B                                              |
| 9      | state    | `0` new / `1` pending / `2` valid / `3` invalid / `4` aborted |
| 10..12 | reserved | 必须为 `0`                                                    |
| 12..16 | crc32    | CRC-32/ISO-HDLC，覆盖 `[0,12)`，小端存放                      |

解码顺序（任一步失败即丢弃整个扇区）：

1. 长度 ≥ 16（允许传入整个 4 KiB flash 扇区，只读前 16 B）；
2. magic 等于 `S31B`；
3. reserved 两个字节都为 0；
4. slot ≤ 1；
5. state ≤ 4；
6. `crc32(bytes[0..12])` 等于 `bytes[12..16]` 的小端值。

`selectSlot` 的选择规则：

1. 两个扇区**各自独立**解码，坏的直接丢；
2. 剩余条目取 `seq` 最大者，平手取 `otadata_a`（参数顺序即扇区顺序），
   保证同样的输入永远得到同样的结果；
3. 最高 seq 条目的状态必须通过 `canBoot`；否则
   `Decision{ .slot = null, .reason = .state_not_bootable }`；
4. 两个都坏 → `Decision{ .slot = null, .reason = .no_valid_sector }`。

> 注意：这里不做“最高 seq 不可启动就退而求其次选另一个扇区”的回退。
> 另一扇区通常是更旧的记录，跳过去等于绕过失败结论。正确做法是上层把
> 存活槽写成**更高 seq** 的新条目（见 §6），再复位。

`seq` 按无符号大小直接比较，不处理 `u32` 回绕；生产上由写入方保证
“回绕前先擦除重排”，本切片不建模该策略。

## 4. 状态机

`canBoot` 只放行 `pending` / `valid`；`new` 尚未通过任何启动验证，
`invalid` / `aborted` 是失败结论，都返回 `false`。

`nextState(state, event)` 迁移表：

| 当前 \ 事件 | `stage` | `set_boot` | `boot`                      | `confirm` | `fail`                      | `abort`   |
| ----------- | ------- | ---------- | --------------------------- | --------- | --------------------------- | --------- |
| `new`       | `new`   | `pending`  | `new`（未被选中）           | `new`     | `new`                       | `aborted` |
| `pending`   | `new`   | 不变       | `pending`，超预算 `aborted` | `valid`   | `pending`，超预算 `invalid` | `aborted` |
| `valid`     | `new`   | 不变       | `valid`                     | `valid`   | `valid`，超预算 `invalid`   | `aborted` |
| `invalid`   | `new`   | 不变       | `invalid`                   | `invalid` | `invalid`                   | `invalid` |
| `aborted`   | `new`   | 不变       | `aborted`                   | `aborted` | `aborted`                   | `aborted` |

预算语义（由调用方持久化计数器，事件里携带）：

- `boot`：`attempt > budget` 判超预算。`budget = 2` 允许第 1、2 次启动，
  第 3 次复位进 bootloader 即 `aborted`。
- `fail`：`consecutive >= budget` 判超预算。`budget = 3` 时前两次失败仍
  留在原状态，第三次失败转 `invalid`。
- 计数器不进 `SlotState`：同一个纯函数既能用于启动期（只读 `otadata`），
  也能用于运行期自检，避免把两份计数逻辑写成两套。
- `invalid` / `aborted` 是粘性的，只有 `stage`（重烧该槽）回到 `new`。
- `stage` 表示目标槽已被覆盖写，旧判定一律失效并回到 `new`。
- 调用方必须只对**非活动槽** stage；本模块不知道当前 active 槽，覆盖运行中的分区由上层拒绝。

## 5. 清单与注入式验签

清单布局（44 B 头 + 不透明签名）：

| 偏移   | 字段      | 说明                                   |
| ------ | --------- | -------------------------------------- |
| 0..4   | magic     | `S31M`                                 |
| 4..8   | version   | u32 小端，候选必须严格大于当前版本     |
| 8..12  | image_len | u32 小端，必须等于实际收到的镜像字节数 |
| 12..44 | digest    | 32 B 摘要（本切片不解释）              |
| 44..   | signature | 不透明签名，长度 **≥ 64 B**            |

本模块是清单准入的**唯一入口**（`ota_plan.zig` 不导出清单解析或验签函数）：

```zig
pub const header_len: usize = 44;
pub const min_signature_len: usize = 64;

pub const Verifier = struct {
    ctx: ?*anyopaque = null,
    verifyFn: *const fn (
        ctx: ?*anyopaque,
        header: []const u8,
        image: []const u8,
        signature: []const u8,
    ) bool,
};

pub fn split(manifest: []const u8) Error!Parts;      // header 44 B + signature ≥ 64 B
pub fn decodeHeader(bytes: []const u8) Error!Header; // 只解析头
pub fn validateCandidate(
    verifier: Verifier,
    manifest_bytes: []const u8,
    image: []const u8,
    current_version: u32,
) Error!Header;
```

`validateCandidate` 的准入顺序是契约：

1. 总长度 ≥ 44 B，magic 为 `S31M`；
2. 尾随签名 ≥ 64 B；
3. `image_len` 与实际镜像字节数一致；
4. `candidate > current`（同版本按降级拒绝）；
5. 调用 `Verifier`，原样传入 44 B 头、镜像切片、尾随签名字节。

**第 1–3 步（结构）或第 4 步（版本）失败时绝不调用 `Verifier`**：
不合格输入不消耗验签算力，未验签的版本号也不参与任何策略判断。

`Verifier` 只返回 `bool`；本切片不实现 SHA-256 / Ed25519，不解释 `digest`，
不限制签名算法。签名长度下限（64 B）是结构契约，不是密码学参数。

版本规则由 `validateCandidate` 固化：`candidate <= current` 一律拒绝
（同版本重放也按降级处理），A/B 重装同版本必须显式提升版本号；
版本检查先于验签，失败时 `Verifier` 不会被调用。

历史上 `ota_plan.zig` 曾导出 `decodeManifest` / `Verifier` / `checkVersion` /
`verifyCandidate`；按合并前清理要求已整体移除，本目录不再保留第二套准入实现。

## 6. 回滚流程（本模块建模的部分）

1. 新镜像写入**非活动槽** → `stage`，该槽为 `new`（旧 `valid` 判定作废）；
2. `set_boot`：上层写 `otadata`（`slot` 指向新槽、`state = pending`、`seq + 1`）；
3. 复位：`selectSlot` 选中新槽（`pending` 可启动）→ 每次启动 `nextState(.pending, .boot)`
   计数，在预算内继续 `pending`；
4. 自检通过 → `confirm` → `valid`；写 `otadata` 的 `valid` 条目；
5. 自检/运行期连续失败达预算 → `invalid`；启动次数超预算 → `aborted`；
6. 上层把存活槽写成 `valid` 且 `seq` 更大的新条目；下一次 `selectSlot`
   返回存活槽，完成回滚；
7. 失败槽在重烧之前一直不可启动；`stage` 后才回到 `new`。

第 3～5 步的计数器由调用方保存（`otadata` 只有 16 B，本模块不扩展它）。

## 7. 验收（测试已写，本次**未运行**）

`src/host_tests.zig` 覆盖（`ota_plan.zig`）：

| 测试                                                           | 断言                             |
| -------------------------------------------------------------- | -------------------------------- |
| `crc32 known answer`                                           | `"123456789"` → `0xCBF43926`     |
| `entry encode/decode roundtrip`                                | 16 B 往返，字段一致              |
| `entry rejects content corruption via CRC`                     | 改一字节 → `BadCrc`              |
| `entry rejects short, blank, reserved, bad slot and bad state` | 五种坏条目各自报错               |
| `encodeEntry rejects a buffer that is too short`               | 编码缓冲不足                     |
| `selectSlot picks the highest sequence`                        | 与参数位置无关地取 seq 最大      |
| `equal sequence prefers sector a`                              | 平手取 A                         |
| `one bad sector ... two bad sectors ...`                       | 单坏容错；双坏 `no_valid_sector` |
| `blank flash never boots anything`                             | 全 `0xFF` 不启动                 |
| `canBoot only admits pending and valid`                        | 状态白名单                       |
| `selectSlot refuses new, invalid and aborted entries`          | 非白名单状态回退 factory         |
| `pending boot budget aborts ...`                               | 启动次数预算                     |
| `zero boot budget aborts the first boot`                       | 边界预算                         |
| `stage then set_boot is the only path from new to pending`     | 首次启动前必须先写 otadata       |
| `consecutive failures roll ...`                                | 连续失败回滚                     |
| `terminal states stay unbootable until restaged`               | 终态粘性 + `stage` 复活          |
| `confirm and abort transitions`                                | 确认/放弃/覆盖保护               |
| `rollback re-points otadata at the surviving slot`             | 回滚写新 seq 后选存活槽          |

`src/manifest_tests.zig` 覆盖（`manifest.zig`，唯一清单准入入口）：

| 测试                                                                       | 断言                                           |
| -------------------------------------------------------------------------- | ---------------------------------------------- |
| `header decode exposes version, image_len and raw digest`                  | 头字段/摘要解析，`split` 切出 ≥ 64 B 签名      |
| `short header is rejected before the verifier`                             | 43 B → `ShortHeader`，verifier 调用 0 次       |
| `bad magic is rejected before the verifier`                                | 坏 magic → `BadMagic`，verifier 调用 0 次      |
| `signature shorter than 64 B is rejected before the verifier`              | 63 B 签名 → `SignatureTooShort`，verifier 0 次 |
| `image_len mismatch is rejected before the verifier`                       | 长度不符 → `LengthMismatch`，verifier 0 次     |
| `equal and lower versions are rejected before the verifier`                | 同版本/降级 → `Downgrade`，verifier 0 次       |
| `verifier rejection surfaces as Rejected after structure and version pass` | 拒签 → `Rejected`，verifier 恰好 1 次          |
| `verifier receives the original header, image and trailing signature`      | 44 B 头、镜像、原始签名字节逐字节透传          |

后续验证命令（本次**没有**执行）：

```bash
cd tools/s31-production/ota
zig build test
```

`build.zig` 只定义 `test` 步骤，目标为宿主（`b.graph.host`）、`Debug` 优化，
无第三方依赖；不会构建固件、不会链接 IDF。

## 8. 未验证边界

- **已编译、宿主测试 8/8；未上板**：Zig 0.17.1 下的
  实际编译结果未确认。
- **未接真实 flash / `otadata` 分区**：不写、不擦、不读物理扇区；
  16 B 布局是本项目自定义格式，不声称与 `esp_ota_select_entry_t` 二进制兼容。
- **无密码学实现**：SHA-256 / Ed25519 / 密钥管理全部由 `Verifier` 调用方
  提供；本模块只固化调用顺序与错误分类。签名“≥ 64 B”只是结构门槛，
  不代表任何具体算法或安全强度。
- **单一准入入口**：`manifest.validateCandidate` 是唯一清单准入 API；
  `ota_plan.zig` 只导出 `otadata` 选槽与槽状态机，不再保留任何清单
  解析、版本检查或验签函数。
- **未与真实签名器联调**：`Verifier` 只被测试替身调用过（且测试未运行），
  没有与 Ed25519 实现、密钥存储或镜像摘要计算对接。
- **无 bootloader / 分区表集成**：factory 回退只以 `slot == null` 表达，
  不解析分区表，不跳转镜像。
- **无掉电/并发模型**：两个扇区的擦写原子性、写一半掉电、双写并发均未建模；
  这些属于后续 flash 写入层的职责。
- **无 `seq` 回绕策略**：按无符号大小比较，回绕行为未验证。
- **无真实计时/看门狗集成**：`boot` / `fail` 计数由调用方注入。
- **未接入 CI**：没有 `build.zig.zon`，不参与仓库现有构建流程。

## 9. 目录边界

本切片只写 `tools/s31-production/ota/`：

```text
ota/
  README.md               # 本文
  build.zig               # 仅 test 步骤（两个测试根）
  src/ota_plan.zig        # otadata 选槽与槽状态机，无 std / IDF 依赖
  src/host_tests.zig      # ota_plan 的主机侧测试（未运行）
  src/manifest.zig        # 唯一清单准入入口（结构 → 版本 → 注入式 Verifier）
  src/manifest_tests.zig  # manifest 的主机侧测试（未运行）
```

不修改 `content/`、`practice/`、`scripts/`、`quartz/` 或仓库根文件；
不执行构建、测试、`code-site`、Quartz 或任何烧录动作。
