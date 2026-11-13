# S31 生产化增量

> 状态：**骨架阶段 + 宿主测试已跑通（2026-11-13）：netmgr 15/15、ota 8/8、provisioning 18/18、recovery 9/9；全部未上板；HIL CLI 未执行、inventory.py 未运行。**

四个切片并行落地，契约见 [SPEC.md](SPEC.md)；OS/TCP-IP 组件拆分见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 切片

| 切片   | 目录                   | 内容                         | 状态             |
| ------ | ---------------------- | ---------------------------- | ---------------- |
| A 基线 | [baseline/](baseline/) | 生产门禁矩阵 + 只读工程盘点  | 已落盘（未验证） |
| B OTA  | [ota/](ota/)           | 分区/选槽/清单/回滚纯逻辑    | 已落盘（未验证） |
| C 网络 | [netmgr/](netmgr/)     | 链路→DHCP→在线→退化状态机    | 已落盘（未验证） |
| D HIL  | [hil/](hil/)           | 烧录/串口/继电器/断言 runner | 已落盘（未验证） |

## 第二增量

| 能力     | 目录                                         | 内容                                                          | 状态             |
| -------- | -------------------------------------------- | ------------------------------------------------------------- | ---------------- |
| OTA 清单 | [ota/src/manifest.zig](ota/src/manifest.zig) | 44 B 头 + 尾随签名，结构→版本→注入式 verifier（唯一准入入口） | 已落盘（未验证） |
| 配网     | [provisioning/](provisioning/)               | SoftAP/PoP/凭据/STA 纯状态机；STA 失败原地退避                | 已落盘（未验证） |
| 故障恢复 | [recovery/](recovery/)                       | 复位原因 + 连续失败 → normal/safe_mode/rollback/factory_reset | 已落盘（未验证） |

## 边界

- 不替换 `practice/zig-esp32-s31/` 的章节工程，不改既有深链。
- 不做 code-site/highlighted、不跑 Quartz；Zig 不编译/不跑测试，HIL 只允许已披露的 `python -m py_compile` 语法检查，不执行 CLI、不烧录。
- 真实链路的 ch17 依赖、ch07/08/12 缺陷、ch28 上板验证仍按 `practice/zig-esp32-s31/BRINGUP-2026-11-12.md` 的结论处理。

## 使用顺序

1. 先看 [baseline/matrix.md](baseline/matrix.md)，确认哪些门禁未绿；
2. 纯逻辑模块的主机测试（待允许后）：`ota`（选槽/清单）、`netmgr`、`provisioning`、`recovery`；
3. HIL runner 先用 `--dry-run` 校验计划，再接台架。
