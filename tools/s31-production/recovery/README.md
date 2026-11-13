# 故障恢复策略（recovery）

> 状态：**未编译、未测试、未上板**。本目录只交付源码与文档，供主线统一评审；
> 没有运行过 `zig build test`，没有在 ESP32-S31 上读过真实复位原因，
> 也没有触发过任何复位或恢复出厂动作。
>
> 身份锚点是 SPEC §3.7「故障恢复策略（`recovery/`）」。SPEC §1/§2 的切片表
> 只登记 A–D（baseline/ota/netmgr/hil），那是 v0 第一增量的目录清单；本目录
> **不自行占用切片字母**，父级 README/SPEC 的表格更新由主线负责。

## 1. 目的

把「这次复位之后该走哪条路」从散落在启动代码里的 if/else 收敛成一份
**可离线穷举**的纯函数：

- `src/recovery.zig`：`ResetReason` / `Phase` / `Decision` 与
  `classify`（判定顺序即优先级）。不 import `std`，不分配内存，不读寄存器，
  不写 flash，不依赖 IDF。
- `src/host_tests.zig`：主机侧断言，覆盖阈值边界、七种复位原因、
  回滚后再次失败与优先级冲突。
- `build.zig`：只有 `zig build test` 一个步骤，目标为宿主（`b.graph.host`），
  无第三方依赖。

本切片**不负责**：读取复位原因寄存器、跨复位保存失败计数、擦 NVS/凭据、
切 `otadata`、复位芯片、降级模式的具体内容。这些都留给调用方与相邻切片。

## 2. 接口（与 `../SPEC.md` §3.7 一致）

```zig
pub const ResetReason = enum { power_on, panic, watchdog, brownout, ota_rollback, software, unknown };
pub const Phase = enum { first_boot, after_rollback };
pub const Decision = enum { normal, safe_mode, rollback, factory_reset };
pub fn classify(reason: ResetReason, consecutive_failures: u8, threshold: u8, phase: Phase) Decision;
```

本切片补充的细化（名字稳定，供上层调用）：

| 名字                    | 语义                                                              |
| ----------------------- | ----------------------------------------------------------------- |
| `initialPhase()`        | 返回 `first_boot`，即「还没有发生过回滚」的默认相位               |
| `needsSafeMode(reason)` | 第 3 条的独立投影：只有 `panic`/`watchdog`/`brownout` 返回 `true` |

`classify` 只返回建议，不执行动作。`Decision` 的四个值按调用方职责展开：

| `Decision`      | 调用方应做的事                                                 |
| --------------- | -------------------------------------------------------------- |
| `normal`        | 正常启动；自检通过后把连续失败计数清零                         |
| `safe_mode`     | 降级运行（最小服务/只读诊断/等待人工）；具体策略不在本切片     |
| `rollback`      | 让 bootloader 切回上一可启动槽并复位；槽位状态机由 `ota/` 负责 |
| `factory_reset` | 无路可退：擦配置/凭据并回到已知良好镜像；擦除范围由调用方决定  |

## 3. 判定规则

优先级固定、短路求值：

1. `phase == after_rollback` 且 `consecutive_failures >= threshold` → `factory_reset`；
2. `consecutive_failures >= threshold` → `rollback`；
3. `reason ∈ {panic, watchdog, brownout}` → `safe_mode`；
4. 其余 → `normal`。

等价矩阵：

| 相位 \ 计数      | `failures < threshold`                                       | `failures >= threshold` |
| ---------------- | ------------------------------------------------------------ | ----------------------- |
| `first_boot`     | `panic`/`watchdog`/`brownout` → `safe_mode`；其余 → `normal` | `rollback`              |
| `after_rollback` | 同上（相位不影响这一档）                                     | `factory_reset`         |

### 阈值语义

- `failures == threshold` **即触发**，不是「超过才触发」。
- `threshold == 0` **按 1 处理**：0 次失败不触发，1 次失败才触发。
  否则一次干净启动会被误判成 `rollback`/`factory_reset`；实现在
  `streakReached` 里做 `effective = max(threshold, 1)`，测试覆盖 0/1 边界。
- `failures > threshold` 不再改变结论（例如 `255/3` 与 `3/3` 同类）。

### 相位语义

`Phase` 由调用方按「当前镜像还有没有回滚额度」注入，本模块不从
`reason == .ota_rollback` 反推：

- `first_boot`：当前镜像仍可回滚一次（正常上电、软件复位、刚进入镜像）；
- `after_rollback`：当前镜像本身就是回滚结果，没有下一个槽可退，
  它的连续失败只能恢复出厂。

`reason` 说明「这一次为什么复位」，`phase` 说明「当前镜像还能不能回滚」，
两者是独立输入。**本模块不做一致性校验**：传入
`reason = .ota_rollback, phase = .first_boot` 时，未达阈值仍判 `normal`，
因为回滚本身是正常恢复动作，存活槽仍可启动。

## 4. 与 ch15 / ch28 / HIL 的关系

- **ch15（可观测性、测试与稳定性）**：本章的 `src/trap.zig` 负责 panic dump，
  `src/watchdog.zig` 只做「检测 + 恢复计数」，README 明确写了生产代码应把
  `checkAndRecover` 返回 true 的分支升级为 `trap.panic` 或受控重启。
  本切片补上的是「固化重启之后怎么办」：`panic` / `watchdog` 引发的复位
  在未达阈值时进 `safe_mode`，而不是再次静默重启。ch15 没有实现复位原因
  分类，本切片也**不读**复位原因寄存器，二者通过调用方注入的
  `ResetReason` 对接。ch15 已上板一次并通过 `checks: passed=8 failed=0`，
  但这与本切片无关——本切片没有任何板侧验证。

- **ch28（自举、功耗、性能与综合项目）**：ch28 的 `src/bootslot.zig` 做 16 B
  `otadata` 解析、双扇区选槽，并在「没有可启动槽 / 选中槽
  ABORTED/INVALID」时回退 factory；其自检判据 ⑥ 是「连续运行失败触发
  A/B 回滚」，真机验收要求「连续三次失败后确认回滚到旧槽」。本切片补的是
  **策略层**：失败计数与相位由调用方注入，输出 `rollback` / `factory_reset`
  建议。两者的 factory 含义不同，不可互换：
  `bootslot.zig` 的 factory 回退是「结构上无槽可启动」，本切片的
  `factory_reset` 是「策略上不许再回滚」。ch28 本身未编译、未上板，
  上述真机验收均未执行。

- **`ota/` 切片**：本切片的 `rollback` 只表达意图，真正的槽位写入、
  状态迁移与预算判定在 `ota/`（其 README 已标注为生产侧候选规范）。
  回滚计数与启动预算由 `ota/` 承接，本切片不重复实现。

- **HIL（切片 D）**：`hil.py` 的 `fault` / `soak` suite 通过串口正则断言
  观察复位循环（例如 `config.example.json` 里的 `boot: recovery #1`）。
  本切片**不定义**日志格式、不新增打印、不改 `hil.py`；如果后续固件要把
  `Decision` 打到串口，由主线统一约定文案后再接 HIL 断言。

## 5. 验收（测试已写，本次**未运行**）

`src/host_tests.zig` 覆盖：

| 测试                                                                           | 断言                                                                                                                  |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `threshold boundary: equal to threshold triggers, one below does not`          | `2/3` 不触发、`3/3` 触发、`4/3` 与 `255/3` 同结论；两相位各判                                                         |
| `threshold zero clamps to one`                                                 | `threshold = 0` 按 1 处理：0 次失败不触发，1 次失败在 `first_boot` 为 `rollback`、`after_rollback` 为 `factory_reset` |
| `threshold 255 keeps exact-boundary behaviour at the u8 limit`                 | `254/255` 与 `255/255` 的边界；`u8` 上限不回绕                                                                        |
| `every reset reason is classified below threshold in both phases`              | 七种原因 × 两相位的未达阈值映射                                                                                       |
| `another failure streak after rollback goes to factory reset for every reason` | 回滚后再次失败升级为 `factory_reset`，同输入 `first_boot` 仍是 `rollback`                                             |
| `priority: streak outranks reset reason, factory reset outranks rollback`      | 达阈值压过原因；`factory_reset` 压过 `rollback`；`ota_rollback` 本身不触发恢复                                        |
| `decision matrix: 7 reasons x 2 phases x 4 failure levels`                     | 7 × 2 × 4 全格矩阵，防止优先级被写反                                                                                  |
| `needsSafeMode admits exactly panic, watchdog and brownout`                    | 第 3 条的原因白名单                                                                                                   |
| `initial phase is first_boot`                                                  | 默认相位                                                                                                              |

后续验证命令（本次**没有**执行）：

```bash
cd tools/s31-production/recovery
zig build test
```

`build.zig` 只定义 `test` 步骤，不构建固件、不链接 IDF。

## 6. 未验证边界

- **未编译、未测试、未上板**：`zig build test` 未运行，Zig 0.17.1 下的实际
  编译结果未确认；没有任何板侧复位实验。
- **不读复位原因**：`ResetReason` 是调用方映射出来的值；哪些复位源在 S31 上
  可区分（冷启动、深睡唤醒、RTC WDT、欠压、软件复位）本切片不判定，
  也不声称映射完整。`unknown` 必须由调用方保守处理（本模块把它当
  `normal`，调用方若认为不可接受，应在传入前自行改判）。
- **不持久化计数**：连续失败计数、阈值、相位都不进 flash/NVS/RTC memory；
  `u8` 饱和与清零时机（自检通过？稳定运行 N 分钟？）由调用方决定。
  计数回绕是调用方的责任：本模块不做饱和，只做比较。
- **不执行任何动作**：不写 flash、不擦 NVS、不切槽、不复位、不喂狗、
  不进省电模式；`Decision` 到动作的映射由板侧代码承担。
- **不含时间维度**：不区分瞬时掉电与慢性故障，没有「N 秒内连续 N 次」的
  时间窗、没有防抖、没有重启冷却；`brownout` 与 `power_on` 的区分完全依赖
  调用方给出的原因。
- **不做相位一致性校验**：`reason` 与 `phase` 的矛盾组合不会被拒绝（见 §3），
  这是有意的策略边界，不是漏洞修复项。
- **不接 bootloader / 分区表 / IDF**：`rollback` 与 `factory_reset` 只是枚举，
  不解析 `otadata`、不跳转镜像、不调用 `esp_ota_set_boot_partition`。
- **未接入 CI**：没有 `build.zig.zon`，不参与仓库现有构建流程。

## 7. 目录边界

本切片只写 `tools/s31-production/recovery/`：

```text
recovery/
  README.md            # 本文
  build.zig            # 仅 test 步骤
  src/recovery.zig     # 纯逻辑，无 std / IDF / 硬件依赖
  src/host_tests.zig   # 主机侧测试（未运行）
```

不修改 `content/`、`practice/`、`scripts/`、`quartz/`、仓库根文件，
也不改 `tools/s31-production/` 下的其他切片目录。
