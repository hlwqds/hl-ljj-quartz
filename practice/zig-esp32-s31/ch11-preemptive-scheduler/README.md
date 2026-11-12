# ch11 抢占调度、TCB 与 tick：让调度器不再等任务自觉

> 所属章节：[[ch11-preemptive-scheduler-tcb-tick|第十一章：抢占调度、TCB 与 tick]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是形态 B 的第六个工程，骨架完全沿用 `ch04-linker-layout` 与
`ch10-context-switch-scheduler`：Zig 自己产出 ELF、`linker/s31.ld` 决定段布局、
`_start` 是入口、应用镜像由 `esptool elf2image` 生成，IDF 只负责二级
bootloader 与分区表（`idf-bootstrap/`）。

在不变的骨架之上，本章把 ch10 的“自愿让出”换成“tick 抢占”：

| 模块              | 做什么                                                                      | 可观测量                              |
| ----------------- | --------------------------------------------------------------------------- | ------------------------------------- |
| `src/context.zig` | 80B trap 帧、64B switch 帧、`trapEntry`、`switchRaw`、`taskStart`           | 帧长编译期断言；新任务入口开 MIE      |
| `src/sched.zig`   | TCB、8 条优先级环形链、`onTick`、`schedule`、临界区、idle、软中断接口       | `ticks`/`switches` 计数；任务交错顺序 |
| `src/tick.zig`    | TIMG0 T0 时钟/分频/闹钟/INT_ENA、矩阵[25]、CLIC 输入 16、ISR 清源与绝对重装 | tick 周期；ISR 是否持续进入           |
| `src/tasks.zig`   | 三个**不调用 `yield()`** 的任务：prio 5 一个、prio 1 两个                   | 高优先级独占；同级按 slice 交替       |
| `src/main.zig`    | 打印配置、建任务、`tick.init(1000)`、把 `main` 变成 idle                    | banner 与启动顺序                     |

工程**不做**的事，同样重要：

- **不做完整 tickless**：只在所有任务 `done` 后停 tick；没有“最近 deadline”
  结构，也没有睡眠/阻塞接口。三个前提写在正文 11.9。
- **不做浮点**：只跑整数上下文。FP 变体（208 字节）与 S31 的三个勘误写在
  正文 11.10 与 `context.zig` 注释里，属于**待真机验证**。
- **不做阻塞**：没有 `blocked` 状态、没有信号量/队列；那是第十二章。
- **软件中断 yield 只留接口**：`sched.requestYield()` 写 CLIC 输入 19 的 `IP`，
  本章没有任务调用它；它真正的主场是 ch14 的跨核 IPI。
- **不分配内存**：TCB 池、队列、任务栈全部是 `.bss` 里的静态对象。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行，构建链也没有在本仓执行过。所有涉及
> tick 路由、ISR 换栈、`mstatus` 恢复与时间片交错的结论都标为
> **待真机验证**。README 不附 `run.log`，也不贴任何“看起来像实测”的日志。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 串口看任务交错；测 tick 抖动时另接一个空闲 GPIO 到示波器        |

本章不新增外部接线。GPIO 翻转测抖动用的是排针上的空闲测试点，具体引脚
按板卡丝印选择，代码里留成参数，不在文中硬编码。

## 寄存器地图

| 项                | 值 / 位置                           | 说明                                                                     |
| ----------------- | ----------------------------------- | ------------------------------------------------------------------------ |
| TIMG0             | `0x20580000`                        | T0CONFIG `0x00`、T0LO/HI `0x04/0x08`                                     |
| T0 快照/闹钟/装载 | `0x0c` / `0x10,0x14` / `0x18..0x20` | UPDATE 自清零；ALARM_EN 命中后自动清；AUTORELOAD(bit29) 复位 1、工程清 0 |
| TIMG 中断使能     | `INT_ENA_TIMERS = 0x70`             | T0 = bit0；矩阵输入是 `INT_ST`，必须置 1                                 |
| TIMG 中断清       | `INT_CLR_TIMERS = 0x7c`             | T0 = bit0                                                                |
| TIMG0 时钟源/门控 | `HP_SYS_CLKRST + 0x114`             | `T0_SRC_SEL`[4:3]=0（XTAL）、`T0_CLK_EN`[5]                              |
| 中断矩阵（core0） | `0x20585000 + 4 × 源编号`           | 源 25 的 `MAP`[5:0] 写 CLIC 输入号                                       |
| CLIC 输入 16      | `0x10801000 + 4 × 16`               | `CTL`[31:24] 优先级、`IE` bit8、`IP` bit0                                |
| CLIC 阈值         | `0x10800008` 的 `[31:24]`           | 0 → `0x1f`，什么都不屏蔽                                                 |
| `mstatus.MIE`     | bit 3                               | `tick.init` 后由 `sched.start` 置 1                                      |
| `mcause`（tick）  | `0x80000010`                        | 最高位 = 中断，低 6 位 = 输入号 16                                       |
| `mcause`（ecall） | `11`                                | 同步异常，返回前 `mepc += 4`                                             |
| trap 帧           | 80 字节                             | 中断与异常共用；中断**不加 4**                                           |
| switch 帧         | 64 字节                             | ra + s0–s11 + 3 字填充                                                   |
| 浮点变体          | 208 字节                            | 64 + f0–f31(128) + fcsr(4) + 12 填充；未实现                             |

## 文件表

| 路径                               | 角色                                                                                  | 代码浏览                                                                                        |
| ---------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `build.zig`                        | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                                  | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/build.zig)                        |
| `linker/s31.ld`                    | `ENTRY(_start)`、`.app_desc` 先于代码、`.text.trap` 4 字节对齐、`gp` 锚点             | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/linker/s31.ld)                    |
| `src/start.zig`                    | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → sp/gp → 清 `.bss` → 装 `mtvec` | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/start.zig)                    |
| `src/context.zig`                  | 帧布局、`trapEntry`、`switchRaw`、`taskStart`（开 MIE）、`initTaskStack`              | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/context.zig)                  |
| `src/sched.zig`                    | TCB、优先级队列、`onTick`、`schedule`、`irqSave/Restore`、`start`                     | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/sched.zig)                    |
| `src/tick.zig`                     | TIMG0 T0、矩阵路由、CLIC 输入 16、ISR 的 acknowledge/rearm                            | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/tick.zig)                     |
| `src/tasks.zig`                    | 三个不主动让出的任务：prio 5 × 1、prio 1 × 2                                          | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/tasks.zig)                    |
| `src/main.zig`                     | 打印 banner/帧长/tick 配置、建任务、把 `main` 变成 idle                               | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/main.zig)                     |
| `idf-bootstrap/CMakeLists.txt`     | 最小 IDF 工程根：只为产出 bootloader 与分区表                                         | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/idf-bootstrap/CMakeLists.txt)     |
| `idf-bootstrap/main/*`             | 空 `app_main`，让 IDF 构建走完                                                        | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/idf-bootstrap/main/app_main.c)    |
| `idf-bootstrap/sdkconfig.defaults` | 16 MB Flash + single-app-large（factory 在 `0x10000`），不启用 PSRAM                  | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/idf-bootstrap/sdkconfig.defaults) |
| `tools/flash.sh`                   | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                        | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/tools/flash.sh)                   |
| `README.md`                        | 本文件                                                                                | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/README.md)                        |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置的
single-app-large）、没有 `components/`、没有 `run.log`（真机未跑）。
生成物 `zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig`
都不入库。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥5.2）

| 工具    | 版本要求              | 说明                                                                      |
| ------- | --------------------- | ------------------------------------------------------------------------- |
| Zig     | 0.17.1                | 交叉编译 + 链接脚本；`zig version` 必须精确匹配                           |
| ESP-IDF | v6.1                  | `esp32s31` 为 preview target；提供二级 bootloader、esptool、binutils      |
| esptool | >= 5.2                | `elf2image`、`image-info`、`write-flash`                                  |
| 目标板  | ESP32-S31 CoreBoard-1 | ESP32-S31-WROOM-3（N16R16V）                                              |
| 主机    | Linux 或 Windows      | Windows 用 IDF 的 PowerShell 导出脚本；`tools/flash.sh` 用 Git Bash/MSYS2 |

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh

# Windows PowerShell
. $env:IDF_PATH\export.ps1
```

## 构建

### 1. 应用 ELF（纯 Zig，无 idf.py）

```bash
cd practice/zig-esp32-s31/ch11-preemptive-scheduler

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

`zicsr` 是必须的：`_start` 的 `csrw mtvec`、`trapEntry` 的 `csrr mepc/mstatus`、
`taskStart` 的 `csrsi mstatus` 都依赖它。

### 2. 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

### 3. bootloader 与分区表（供应商步骤）

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

产物：

```text
idf-bootstrap/build/bootloader/bootloader.bin
idf-bootstrap/build/partition_table/partition-table.bin
idf-bootstrap/build/flash_args
```

### 4. 烧录

```bash
sh tools/flash.sh /dev/ttyUSB0     # Linux
sh tools/flash.sh COM7             # Windows（Git Bash / MSYS2）
```

脚本读 `flash_args`，保留 `--flash_mode`/`--flash_freq`/`--flash_size` 与
bootloader、partition-table 两行（**偏移一律不手抄**），把 `0x10000` 那一行
替换成 `app.bin` 的绝对路径，再 `cd` 到该 build 目录执行 esptool。脚本本身
**不调用 `idf.py`**。

## 运行

串口按 **115200 8N1** 打开 UART0（GPIO58/59）。应用侧的**目标形态**
（验收目标，不是实测日志）：

```text
ch11-preemptive-scheduler | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
mtvec: base=0x2f00xxxx mode=0 (0 = direct)
frames: trap=80 switch=64 bytes (integer only; FP variant would be 208)
tick: 1000 us via TIMG0 T0 (source 25) -> clic input 16 prio 3
sched: 3 tasks + idle, preemptive (slice in ticks); soft-yield input 19 not wired
hi: beat 1 (prio=5 slice=3)
...
hi: done (steps=6)
loA: beat 1 (prio=1 slice=2)
loB: beat 1 (prio=1 slice=2)
loA: beat 2 (prio=1 slice=2)
loB: beat 2 (prio=1 slice=2)
...
sched: all tasks done ticks=<n> switches=<m>
idle: wfi
```

字段含义：

- `hi` 在跑时 `loA`/`loB` 没有任何输出：严格优先级，不是时间片轮转。
- `hi` 结束后两个 prio 1 任务按 `slice=2` 交替；任务体里**没有 `yield()`**，
  交替完全由 tick 造成。
- `ticks` 是 tick ISR 的命中次数，`switches` 是真实换栈次数（`next == prev`
  不计）。两者都由硬件/调度路径产生，不是预填常量。
- 最后停在 `wfi`：所有任务 `done` 后 idle 打印统计、`tick.disable()`、停住。

## 证据与边界

### 1. 为什么新任务要在 `taskStart` 开 MIE

tick 到来时硬件清 `MIE`、把旧值放进 `MPIE`。被抢占的任务恢复后会逐层返回
自己的 `trapEntry`，由 `mret` 把 `MPIE` 写回 `MIE`；但**新建任务没有 trap
帧**，它从 `taskStart` 开始，永远不会 `mret`。所以 `taskStart` 的第一条
指令是 `csrsi mstatus, 8`。少了它，第一次抢占之后新任务带着 `MIE=0` 跑，
系统再也不会有第二个 tick——现象是“只交错了一次，然后各跑各的”。

### 2. 换栈必须在临界区里

`schedule()` 先改 `current`，再 `switchTo` 保存 sp。若中间放中断进来，tick
会看到 `current = next` 却仍在 prev 的栈上，把 prev 的 sp 存进 `next.sp`：
两个任务共用一张栈。所以 `irqSave` 到 `switchTo` 返回之间不放开中断；
MIE 的恢复交给各任务的现场（`taskStart` 或 `mret`），不由 `schedule` 代劳。

### 3. 闹钟绝对重装

`ALARM_EN` 命中后自动清零，每次 ISR 都要重装。目标用
`last_target += period`，不是 `now + period`：后者把每次 ISR 的迟到量积分
成长期漂移。若迟到超过一个周期，目标落在过去，硬件会连续补 tick——这是
需要记录的证据，不是靠调大周期掩盖。

### 4. tickless 的三个前提

1. 可读的单调时基（SYSTIMER 52 位 / TIMG 快照）；
2. 把“最近 deadline”写进一次性闹钟，而不是周期闹钟；
3. 新任务就绪或中断到来时能改写闹钟（唤醒路径）。

本章只做“全部任务结束后停 tick”：没有 deadline 结构、没有睡眠接口，
所以它是终止状态，不是低功耗模式。

### 5. tick 漂移/抖动的测量口径

**漂移** = 长期平均周期相对 1 ms 的偏差；**抖动** = 单次间隔的分布宽度。

- **第二时基**：ISR 入口读 SYSTIMER（16 MHz），与上次差值累加；每 1000 个
  tick 打印 `min/avg/max`。16 counts = 1 µs。
- **GPIO 翻转 + 示波器**：ISR 入口/出口各翻一次，高电平宽度 = ISR 执行时间，
  相邻上升沿 = tick 周期。不占串口，不受打印延迟影响。

测量时关掉 `line()` 打印。本仓不给任何“±X µs”的数字——它们必须在真机上测。

### 6. 与 ch07/ch08/ch10 的关系

- ch07 提供 CLIC 输入号、优先级/阈值语义与矩阵 `+16` 的结论；本章只用到
  输入 16（tick）与输入 19（软中断接口）。
- ch08 提供 TIMG0 的寄存器与分频口径；本章把“轮询 INT_RAW”换成“使能中断
  并路由”，并补上绝对闹钟重装。
- ch10 提供两层帧与 `switchRaw`；本章只改变触发者，并把 `mepc += 4`
  严格限制在 `ecall` 分支。

### 7. 排障表

| 环境 | 现象                          | 根因                                                           | 处置                                                           |
| ---- | ----------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------- |
| 构建 | `undefined symbol: main`      | `main` 没 `export`                                             | 用 `pub export fn main`；`nm` 确认符号名                       |
| 构建 | `undefined symbol: trapEntry` | 只被汇编字符串引用                                             | `_start` 的 comptime 块里 `_ = &context.trapEntry;`            |
| 构建 | `TrapFrame 必须是 80 字节`    | 结构体字段/填充被改动                                          | 按 `context.zig` 的偏移表恢复 18 字 + 2 字填充                 |
| 运行 | 只有 banner，任务不跑         | `MIE` 没开，或 `irqRestore` 把 0 写回                          | 打印 `mstatus`；确认恢复的是进入临界区前的值                   |
| 运行 | 顺序等于创建顺序              | tick 没进：矩阵写成 0..31、`INT_ENA` 没置、`IE` 没置、阈值 ≥ 3 | 读回矩阵[25]=16、`INT_ENA(0x70).bit0`、`CTRL(16).bit8`、阈值 0 |
| 运行 | 第一次抢占后再无 tick         | `taskStart` 没开 MIE                                           | `csrsi mstatus, 0x8` 放在 `taskStart` 第一条                   |
| 运行 | 每个任务都跳过一条指令        | `mepc += 4` 也应用到了中断路径                                 | 加 4 只放在 `ecall` 分支                                       |
| 运行 | tick 后立刻又进 ISR           | `INT_CLR` 或 CLIC `IP` 没清                                    | 先清 `INT_CLR_TIMERS.bit0`，再清 `IP`，最后重装                |
| 运行 | `all tasks done` 后立刻复位   | idle 退出后回到 `_start` 的返回路径                            | idle 循环 `noreturn`；统计后停在 `wfi`                         |

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 产出 `zig-out/bin/app.elf`
- [ ] `readelf -h` 的 entry == `nm` 的 `_start`
- [ ] `nm` 里 `trapEntry` 的地址低 2 位为 0
- [ ] `xxd -s 32 -l 4 zig-out/bin/app.bin` 输出 `32 54 cd ab`（段 #0 以 app_desc 开头）
- [ ] `esptool elf2image` 与 `image-info` 通过
- [ ] `idf-bootstrap` 在 `--preview` 下产出 bootloader、分区表与 `flash_args`
- [ ] `tools/flash.sh` 替换应用行后一次烧录成功
- [ ] 串口出现 banner、`trap=80 switch=64`、`tick ... input 16 prio 3`
- [ ] `hi` 运行期间低优先级任务无输出
- [ ] `loA`/`loB` 按 slice 交替，且任务体里没有 `yield()`
- [ ] 全部 `done` 后打印 `ticks=<n> switches=<m>` 并停在 `wfi`
- [ ] 连续复位 10 次，交错顺序与 `switches` 稳定
- [ ] SYSTIMER 统计的 tick `min/avg/max` 落在可解释范围（记录实测值）
- [ ] GPIO 翻转 + 示波器测得的 ISR 宽度 < 1 个 tick
- [ ] （后续）浮点任务的 208 字节帧与 `mstatus.FS` 配置另行验证
