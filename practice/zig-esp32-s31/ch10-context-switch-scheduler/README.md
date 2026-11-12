# ch10 上下文切换与协作调度：把“一个 main”拆成多个任务

> 所属章节：[[ch10-context-switch-cooperative-scheduler|第十章：上下文切换与协作调度]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是形态 B 的第五个工程，骨架完全沿用 `ch04-linker-layout`：Zig 自己产出 ELF、
`linker/s31.ld` 决定段布局、`_start` 是入口、应用镜像由 `esptool elf2image`
生成，IDF 只负责二级 bootloader 与分区表（`idf-bootstrap/`）。

在不变的骨架之上，本章加了三件事：

| 模块              | 做什么                                                      | 可观测量                           |
| ----------------- | ----------------------------------------------------------- | ---------------------------------- |
| `src/context.zig` | 80 字节 trap 帧、64 字节 switch 帧、初始帧构造、`trapEntry` | 帧长编译期断言；`mtvec` 指向与对齐 |
| `src/sched.zig`   | TCB 池、固定就绪队列、`ecall` 让出、`switchTo` 换 sp        | `switches` 计数；任务交错顺序      |
| `src/tasks.zig`   | 三个整数任务：不同轮数/工作量，打印后主动让出               | 每个任务的 `step` 与最终 `done`    |

工程**不做**的事，同样重要：

- 不做抢占：没有 tick、没有时间片，`mstatus.MIE` 全程为 0。一个不调用
  `yield()` 的任务会独占 CPU——这是协作式的定义，不是缺陷。
- 不用 CLIC 软件中断：`ecall` 是同步异常，不需要输入号/优先级/阈值，
  失败时不依赖“中断有没有进”这种难以归因的现象。
- 不用浮点：只做整数上下文。FP 变体（208 字节）的布局与 S31 的三个勘误
  写在正文 10.6 与 `context.zig` 的注释里，属于**待真机验证**。
- 不分配内存：TCB、就绪队列、任务栈全部是 `.bss` 里的静态对象。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行，构建链也没有在本仓执行过。所有涉及
> `ecall`、`mret`、`mtvec` 与任务切换的结论都标为**待真机验证**。
> README 不附 `run.log`，也不贴任何“看起来像实测”的日志。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章不需要示波器；串口的任务交错就是观测面                      |

## 上下文与寄存器地图

本章不新增外设寄存器，只碰 CPU 的 CSR 与两个栈上的帧。

| 项            | 值 / 位置                | 说明                                              |
| ------------- | ------------------------ | ------------------------------------------------- |
| `mtvec`       | `trapEntry`，低 2 位 = 0 | 直接模式；本章只有同步异常（`ecall`）             |
| `mcause`      | `11`                     | environment call from M-mode                      |
| `mepc`        | `ecall` 指令地址         | 返回前必须 `+4`                                   |
| `mstatus.MIE` | bit 3                    | 本章恒为 0；`ecall` 不依赖它                      |
| `mstatus.FS`  | bit[14:13]               | 使用浮点前必须置非零；本工程不碰                  |
| trap 帧       | 80 字节                  | ra、t0–t6、a0–a7、mepc、mstatus、2 字填充         |
| switch 帧     | 64 字节                  | ra、s0–s11、3 字填充（52 字节内容按 16 对齐取整） |
| 浮点变体      | 208 字节                 | 64 + f0–f31(128) + fcsr(4) + 12 填充；**未实现**  |

两个帧的分工：64 字节决定“任务之间换不换得动”，80 字节决定“换回来以后
从哪儿继续”。切换后新任务从它自己的 `switchTo` 调用点返回，逐层回到
`trapEntry` 的 `mret`。

## 文件表

| 路径                                | 角色                                                                                     | 代码浏览                                                                                             |
| ----------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `build.zig`                         | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                                     | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/build.zig)                         |
| `linker/s31.ld`                     | `ENTRY(_start)`、`.app_desc` 先于代码、`.text.trap` 4 字节对齐、`gp` 锚点                | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/linker/s31.ld)                     |
| `src/start.zig`                     | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → 设 sp/gp → 清 `.bss` → 装 `mtvec` | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/src/start.zig)                     |
| `src/context.zig`                   | `TrapFrame`/`SwitchFrame` 布局、`trapEntry`、`switchRaw`、`initTaskStack`                | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/src/context.zig)                   |
| `src/sched.zig`                     | TCB、就绪队列、`schedule()`、`trapDispatch`、`yield`、`start`                            | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/src/sched.zig)                     |
| `src/tasks.zig`                     | 三个整数任务：A/B/C 的轮数与忙等量不同                                                   | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/src/tasks.zig)                     |
| `src/main.zig`                      | 打印 banner 与帧长、建三个任务、把 `main` 变成 idle                                      | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/src/main.zig)                      |
| `idf-bootstrap/CMakeLists.txt`      | 最小 IDF 工程根：只为产出 bootloader 与分区表                                            | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | `main` 组件注册，只有一个空 `app_main.c`                                                 | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | 空 `app_main`，永不被执行；只为让 IDF 构建走完                                           | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | 16 MB Flash + single-app-large（factory 应用槽在 `0x10000`），不启用 PSRAM               | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                           | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/tools/flash.sh)                    |
| `README.md`                         | 本文件                                                                                   | [查看](/static/code/#/zig-esp32-s31/ch10-context-switch-scheduler/README.md)                         |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置的
single-app-large 分区表）、没有 `components/`、没有 `run.log`（真机未跑）。
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
cd practice/zig-esp32-s31/ch10-context-switch-scheduler

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

产物是 `zig-out/bin/app.elf`。`zicsr` 是必须的：`_start` 的 `csrw mtvec`
与 `trapEntry` 的 `csrr mepc/mstatus` 都依赖它。

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
idf.py --preview set-target esp32s31   # v6.1 preview target；--preview 在子命令之前
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
# Linux
sh tools/flash.sh /dev/ttyUSB0

# Windows（Git Bash / MSYS2）
sh tools/flash.sh COM7
```

脚本读 `idf-bootstrap/build/flash_args`，保留 `--flash_mode`/`--flash_freq`/
`--flash_size` 与 bootloader、partition-table 两行（**偏移一律不手抄**），把
`0x10000` 那一行替换成 `app.bin` 的绝对路径，再 `cd` 到该 build 目录执行
esptool（`flash_args` 里的相对路径以 build 目录为基准）。脚本本身**不调用
`idf.py`**。

## 运行

串口按 **115200 8N1** 打开 UART0（GPIO58/59）。应用侧的**目标形态**
（验收目标，不是实测日志）：

```text
ch10-context-switch | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
mtvec: base=0x2f00xxxx mode=0 (0 = direct; only synchronous traps)
frames: trap=80 switch=64 bytes (integer only; FP variant would be 208)
sched: 3 tasks + idle, cooperative yield via ecall
A: step 1
B: step 1
C: step 1
A: step 2
B: step 2
C: step 2
A: step 3
B: step 3
C: done (steps=2)
A: done (steps=3)
B: step 4
B: done (steps=4)
sched: all tasks done, switches=<n>
idle: wfi
```

字段含义：

- `mode=0`：`mtvec` 是直接模式，低 2 位为 0；本章只有 `ecall` 一种同步异常。
- `trap=80` / `switch=64`：不是配置项，是编译期断言的常量；改布局会直接编译失败。
- 任务交错顺序由“创建顺序 + 轮转扫描”决定，因此在协作式下是确定的。
- `switches` 统计真实的 `switchTo` 次数（`next == prev` 时不计数）。
- 最后停在 `wfi`：所有任务 `done`，idle 报告后不再让出。

## 证据与边界

### 1. 为什么 `ra` 必须保存

`ra` 在 psABI 里是 caller-saved，但它是“任务的控制流位置”。两个任务的
`ra` 指向各自调用链的不同位置；不保存就是把两个返回地址混在一起。故障
现象通常是“任务第一次切换后跑飞”，且反汇编看起来完全正常。

### 2. 52 与 64

`ra + s0..s11` 是 13 个字 = 52 字节；帧长取 64 是为了恢复后的 `sp` 仍然
16 字节对齐（psABI 要求）。填充的 3 个字没有任何语义。

### 3. 为什么 `ecall` 之后要 `mepc += 4`

`ecall` 是同步异常，`mepc` 指向 `ecall` 本身。不跳过它，`mret` 回到同一
条指令，任务立刻再次让出——现象是“只有一个任务在刷屏”，而且没有任何
错误信息。中断路径不加 4，两者的语义必须分开写。

### 4. FPU 边界（待真机验证）

`SOC_CPU_HAS_FPU_EXT_ILL_BUG=1`：EXT_ILL 的 CSR 访问不支持 `FLW`/`FSW`，
因此标准 RISC-V 的“懒保存”（`mstatus.FS=0` → 非法指令 → 在异常里保存）
在 S31 上不可行。再加上 `SOC_PM_FPU_RETENTION_BY_SW=1`（休眠不保 FPU），
任何浮点任务都必须**无条件保存全部 32 个 f 寄存器**，帧长 208 字节。
本工程不使用浮点，这三条结论未在本板实测。

### 5. 与 ch07 的关系

本章直接复用 ch07 的结论：`mcause` 在 CLIC 系统上的低位是**输入号**，
但本章只用 `mcause == 11`（同步异常），不涉及 CLIC 输入号、优先级或阈值。
`mtvec` 用 MODE=0；ch07 讲的 MODE=3（CLIC 向量模式）在本章没有启用。

### 6. 排障表

| 环境 | 现象                          | 根因                           | 处置                                                |
| ---- | ----------------------------- | ------------------------------ | --------------------------------------------------- |
| 构建 | `undefined symbol: main`      | `main` 没 `export`             | 用 `pub export fn main`；`nm` 确认符号名            |
| 构建 | `undefined symbol: trapEntry` | 只被汇编字符串引用，Zig 没发射 | `_start` 的 comptime 块里 `_ = &context.trapEntry;` |
| 构建 | `TrapFrame 必须是 80 字节`    | 结构体字段/填充被改动          | 按 `context.zig` 的偏移表恢复 18 个字 + 2 字填充    |
| 运行 | 只有 banner，随后无输出       | 第一次切换的初始帧不对         | 检查 `ra=taskStart`、`s0=入口`、`s1=TCB`            |
| 运行 | 只有一个任务在刷屏            | `ecall` 后没 `mepc += 4`       | 在 `schedule()` 开头加 `frame.mepc += 4`            |
| 运行 | `trap: unexpected cause=0x2`  | 非法指令：入口地址错或对齐错   | 用 `mepc` 反汇编定位；确认任务栈 16 对齐            |
| 运行 | 任务局部变量被别的任务改      | 两个任务共用栈                 | 每个任务一个 `align(16)` 静态数组                   |
| 运行 | `all tasks done` 后立刻复位   | idle 走到 `main` 返回路径      | idle 循环必须 `noreturn`；报告后停在 `wfi`          |
| 运行 | 输出乱码/截断                 | 任务栈太小，格式化缓冲溢出     | 增大 `stack_bytes`；或把格式化移出任务              |

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 产出 `zig-out/bin/app.elf`
- [ ] `readelf -h` 的 entry == `nm` 的 `_start`
- [ ] `nm` 里 `trapEntry` 的地址低 2 位为 0
- [ ] `xxd -s 32 -l 4 zig-out/bin/app.bin` 输出 `32 54 cd ab`（段 #0 以 `esp_app_desc_t` 开头）
- [ ] `esptool elf2image` 与 `image-info` 通过
- [ ] `idf-bootstrap` 在 `--preview` 下产出 bootloader、分区表与 `flash_args`
- [ ] `tools/flash.sh` 替换应用行后一次烧录成功
- [ ] 串口出现 banner 与 `trap=80 switch=64` 自检
- [ ] 三个任务的 `step` 按 A → B → C 交错，各自轮数正确
- [ ] 全部 `done` 后打印 `switches=<n>` 并停在 `wfi`
- [ ] 连续复位 10 次，交错顺序与 `switches` 稳定
- [ ] （后续）浮点任务的 208 字节帧与 `mstatus.FS` 配置另行验证
