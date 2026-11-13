# S31 HIL runner（切片 D）

> 状态：**离线骨架；Zig 未编译、未上板、CLI 未执行**。
> `hil.py` 从未作为 CLI 执行过；仅做过 `python -m py_compile` 语法检查（`__pycache__` 已删除）。
> 所有真实硬件路径（串口、esptool、继电器）均为未验证代码。
> 本切片只写 `tools/s31-production/hil/`，不修改 `content/`、`practice/`、`scripts/`、`quartz/`。

## 1. 目的与边界

提供一个可运营的 HIL（Hardware-in-the-Loop）测试入口：把“构建 → 烧录 → 上电/复位 →
抓串口 → 正则断言”串成一条可干跑、可审计的流水线。

**做**：

- `--dry-run` 只输出计划，不打开串口、不烧录、不吸合继电器、不写文件。
- 真实模式按 JSON 配置调用外部 `esptool`、继电器 CLI、pyserial，逐步骤记录状态。
- 缺配置 / 缺依赖 / 命令失败时返回非零退出码和明确错误，不伪造成功。

**不做**：

- 不实现构建系统；构建是可选外部命令（默认关闭），固件通常由 CI/开发者预先产出。
- 不做签名校验、不解析固件格式、不判断硬件电气安全。
- 不做网络吞吐/时延测量；`link` 层只做串口日志断言。
- 不改动仓库其他目录，不接入 CI 配置。

## 2. 台架拓扑

```text
                 USB（CDC/UART）                 UART0（日志）
  ┌──────────┐  ───────────────────►  ┌──────────────────────┐
  │ 主机 PC   │                        │  DUT: ESP32-S31      │
  │          │  USB（继电器控制）       │                      │
  │ hil.py   │  ───────────────────►  │  EN / 复位 ──┐        │
  └──────────┘                        │  VIN/电源 ──┤        │
                                      └──────────────┼────────┘
                                                     │
                                      ┌──────────────┴────────┐
                                      │ 可编程继电器/开关模块    │
                                      │ 通道1=电源, 通道2=复位  │
                                      └───────────────────────┘
```

- 串口：DUT 日志口（配置项 `port` / `baud`），由 pyserial 打开。
- 继电器：任意可由命令行驱动的继电器模块；`relay.command` 是命令模板，
  用 `{channel}` / `{state}` 占位，状态字符串由 `relay.on_value` / `relay.off_value` 决定。
- 电源与复位通道分离；复位脉冲由 `reset_pulse_ms` 控制。
- 主机、继电器、DUT 的接地与电平匹配由台架负责人保证，本工具不做电气检查。

## 3. 文件与用法

```text
tools/s31-production/hil/
  README.md            # 本文件
  hil.py               # Python 3.10+ 标准库 CLI（真实模式才动态导入 pyserial）
  config.example.json  # 串口/波特率/固件/继电器/断言示例
  artifacts/           # 真实模式运行时生成（不入库、不由 dry-run 创建）
```

```bash
# 查看帮助（不读配置、不接触硬件）
python tools/s31-production/hil/hil.py --help

# 干跑：只打印计划（构建/烧录/上电/抓串口/断言），不执行任何真实动作
python tools/s31-production/hil/hil.py \
    --config tools/s31-production/hil/config.example.json \
    --suite smoke --dry-run

# 真实执行：必须先显式解锁 allow_hardware=true
python tools/s31-production/hil/hil.py \
    --config /path/to/bench.json --suite smoke
```

### 3.1 CLI

| 参数                              | 必填 | 说明                                                       |
| --------------------------------- | ---- | ---------------------------------------------------------- |
| `--config PATH`                   | 是   | JSON 配置路径；缺失时 argparse 直接报错（退出码 2）        |
| `--suite {smoke,fault,link,soak}` | 否   | 默认 `smoke`                                               |
| `--dry-run`                       | 否   | 只打印计划并输出 JSON；不触碰串口/继电器/esptool，不写产物 |
| `--help`                          | 否   | 帮助文本；不会加载配置                                     |

退出码：`0` 成功（dry-run 生成了计划也算成功）；`1` 某个步骤失败；`2` 配置/依赖/参数错误。

### 3.2 JSON 结果

stdout 只输出一个 JSON 对象；人类可读的计划与错误走 stderr，便于管道消费。

```json
{
  "ok": true,
  "suite": "smoke",
  "dry_run": true,
  "steps": [
    {
      "id": "build",
      "kind": "build",
      "name": "构建固件（可选）",
      "status": "planned",
      "detail": "跳过构建（build.enabled=false，使用预构建固件）",
      "params": {}
    }
  ],
  "artifacts": []
}
```

- `ok`：全部步骤成功且无错误。
- `steps[].status`：`planned`（dry-run）/ `ok` / `error` / `skipped`（前序失败后未执行）。
- `artifacts`：真实模式产生的串口日志，元素形如
  `{"kind": "serial_log", "path": "<artifacts_dir>/<runid>-<suite>-<sid>.log"}`；
  dry-run 恒为空数组。
- `error`：仅在失败时出现，给出可读原因。

### 3.3 安全门（两层）

1. **`--dry-run`**：`Runner.run()` 在 dry-run 分支只设置 `status=planned` 与计划描述后返回。
   代码路径不会导入 pyserial、不会启动 `subprocess`、不会 `mkdir`/写日志。
2. **`allow_hardware`**：真实模式要求配置显式 `"allow_hardware": true`，否则退出码 2 并提示。
   示例配置刻意保持 `false`。

## 4. 测试分层

| suite   | 目标                                 | 步骤序列                                                                          |
| ------- | ------------------------------------ | --------------------------------------------------------------------------------- |
| `smoke` | 最短冒烟：能烧、能启动、关键日志出现 | build? → preflight → 上电 → flash → 复位 → capture → assert                       |
| `fault` | 掉电/复位压力下的恢复能力            | build? → preflight → 上电 → flash → N 轮（掉电 → 保持 → 上电 → capture → assert） |
| `link`  | 网络栈启动后的链路/DHCP/在线日志     | build? → preflight → 上电 → flash → 复位 → capture → assert                       |
| `soak`  | 长时间反复复位/启动的稳定性          | build? → preflight → 上电 → flash → N 轮（复位 → capture → assert → 间隔等待）    |

- 每轮 cycle 数、间隔、单轮抓取时长分别由 `fault.*` / `soak.*` 配置；
  `cycles` 上限 `500`，防止误配产生超大计划。
- `build.enabled=false` 时 build 步骤只记录“跳过”，preflight 仍会检查固件文件是否存在。
- 断言窗口 = `max(capture.duration_s, 所有断言 timeout_s)`；全部断言正则命中后提前结束抓取。
- `required=false` 的断言缺失只记录在步骤 detail，不判失败。

## 5. 配置字段（`config.example.json`）

| 字段                                                                              | 说明                                                           |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `allow_hardware`                                                                  | 真实模式总开关，必须显式为 `true`；dry-run 不受影响            |
| `port` / `baud`                                                                   | DUT 串口与波特率                                               |
| `firmware`                                                                        | 固件文件路径（相对仓库根或绝对路径）；esptool 的最后一个参数   |
| `artifacts_dir`                                                                   | 串口日志目录，默认 `tools/s31-production/hil/artifacts`        |
| `build.enabled`                                                                   | 是否运行外部构建命令；默认 `false`                             |
| `build.command` / `build.cwd` / `build.timeout_s`                                 | 构建命令数组、工作目录、超时                                   |
| `flash.esptool`                                                                   | esptool 可执行文件名或路径（示例 `esptool.py`）                |
| `flash.chip` / `flash.baud` / `flash.offset`                                      | 传给 esptool 的芯片、烧录波特率、偏移（字符串，如 `0x10000`）  |
| `flash.extra_args`                                                                | 追加到命令末尾的额外参数                                       |
| `relay.command`                                                                   | 命令数组模板，必须包含 `{channel}` 与 `{state}`                |
| `relay.power_channel` / `relay.reset_channel`                                     | 电源/复位通道号                                                |
| `relay.on_value` / `relay.off_value`                                              | 吸合/释放状态字符串                                            |
| `relay.settle_ms` / `relay.reset_pulse_ms`                                        | 切换后的稳定等待、复位脉冲宽度                                 |
| `capture.duration_s`                                                              | 单次抓取时长上界（秒）                                         |
| `capture.stop_pattern`                                                            | 命中即提前结束的正则（可选）                                   |
| `capture.encoding`                                                                | 串口字节解码编码，默认 `utf-8`                                 |
| `assertions[]`                                                                    | 通用断言：`name` / `pattern`（正则）/ `timeout_s` / `required` |
| `link.assertions[]`                                                               | `link` 套件覆盖断言；缺省回退到通用列表                        |
| `fault.cycles` / `fault.power_off_ms` / `fault.assertions[]`                      | 掉电轮数、掉电保持时间、恢复断言                               |
| `soak.cycles` / `soak.cycle_interval_s` / `soak.duration_s` / `soak.assertions[]` | 浸泡轮数、轮间等待、单轮抓取、启动断言                         |

继电器命令契约：`hil.py` 只负责把占位符替换后以数组形式 `subprocess.run`，
不经过 shell；命令返回码非 0 即判失败。实际模块（USB 继电器、GPIO 工具、智能插座 CLI）
由台架侧提供并保证幂等。

## 6. 依赖

- Python **3.10+**；dry-run / `--help` 只用标准库。
- 真实模式额外需要：
  - `pyserial`（`python -m pip install pyserial`）；
  - `esptool`（`flash.esptool` 可在 PATH 中，或写成绝对路径）；
  - `relay.command[0]` 对应可执行文件（PATH 中或绝对路径）。
- 缺任何依赖时，preflight 或对应步骤给出中文错误，退出码 2/1，不会继续伪装成功。

## 7. 验收（源码级，本切片未运行）

- [x] `hil.py --help` 由 argparse 提供，显示四个 suite 与 JSON 结构提示；不加载配置。
- [x] `--dry-run` 分支在 `Runner.run()` 中直接 return，不进入 build/flash/relay/capture 执行函数；
      这些函数只在 `dry_run=False` 的循环里可达。
- [x] dry-run 不创建 `artifacts_dir`、不写日志、不导入 pyserial。
- [x] 真实模式被 `allow_hardware=false` 挡住；缺配置、缺固件、缺 esptool/pyserial/继电器命令均有明确错误。
- [x] JSON 结果包含 `ok` / `suite` / `steps` / `artifacts`（另有 `dry_run`，失败时加 `error`）。
- [x] 配置示例覆盖串口、波特率、固件、继电器命令、断言列表与四个套件的参数。
- [x] 未修改 `tools/s31-production/hil/` 之外的文件；未执行 `hil.py`、未跑 Zig 构建/测试、未上板。
- [x] 仅做过 `python -m py_compile hil.py` 的 Python 语法检查；这不等于运行验证。

## 8. 未验证边界（重要）

以下内容均为**未在真实硬件上验证**的假设，首次上板前必须逐项确认：

1. **串口读取语义**：依赖 pyserial `read(4096)` + `timeout=0.1` 的阻塞行为；
   USB 转串口驱动、缓冲区大小、DTR/RTS 复位副作用未验证。
2. **esptool 参数顺序**：`--chip/--port/--baud write_flash OFFSET FILE [extra_args]`
   仅按 esptool v4 常见形式拼接；不同版本/芯片的选项差异未验证，`extra_args` 位置可能需调整。
3. **自动下载模式**：未实现 DTR/RTS 自动进入 bootloader 的时序；依赖开发板自身电路或手工操作。
4. **继电器时序**：`settle_ms`、`reset_pulse_ms`、掉电保持时间均为经验值；
   真实继电器抖动、触点回弹、电源掉电斜率未测量。
5. **断言与启动竞态**：抓取窗口从复位后开始，若 DUT 启动早于串口打开，可能漏掉首行日志；
   当前没有“先开后复位”的缓冲策略。
6. **日志解码**：非 UTF-8 输出按 `capture.encoding` 解码并 `errors="replace"`；
   BIN 级输出会含替换字符，断言可能误判。
7. **产物路径**：`run_id` 使用 UTC 时间戳（微秒），并发运行同一 suite 理论可区分；
   未实现日志轮转/清理。
8. **Windows 串口名**：`COMx` 直接交给 pyserial；未做端口占用/权限预检。
9. **套件语义**：`fault` / `soak` 只做“复位/掉电 + 日志断言”，不注入网络故障、
   不测量恢复时间、不统计成功率；这些属于后续增量。
10. **构建步骤**：默认关闭；开启后只执行配置命令，不解析 Zig 目标、不保证产物落在 `firmware`。
11. **继电器命令注入面**：命令模板由配置提供并按数组执行（无 shell），但配置本身属于可信输入；
    不提供沙箱。
12. **未运行**：`--help`、`--dry-run`、真实模式均未在本仓库执行；`config.example.json`
    只做了 JSON 结构检查，未用脚本加载。唯一做过的机器检查是 `python -m py_compile`。

## 9. 与共享 SPEC 的对齐

- 入口与 SPEC §3.4 一致：
  `python tools/s31-production/hil/hil.py --config hil.json --suite smoke --dry-run`。
- `--dry-run` 分离、JSON 四键、缺依赖清晰报错、不执行真实动作，均按 SPEC 实现。
- 不替换 `practice/zig-esp32-s31/SPEC.md` 的章节契约，也不改动 ch01–ch28。
