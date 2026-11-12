# ch07 中断、异常与 CLIC：1 kHz tick + UART 接收中断

> 所属章节：[[ch07-interrupts-exceptions-clic|第七章：中断、异常与 CLIC]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是形态 B 的第三个工程，骨架沿用 `ch04-linker-layout`：Zig 产出 ELF、
`linker/s31.ld` 决定段布局、`_start` 是入口、应用镜像由 `esptool elf2image`
生成，IDF 只负责二级 bootloader 与分区表（`idf-bootstrap/`）。

在不变的骨架之上，本章把 ch06 的“轮询接收”换成**中断接收**，并加上一个
**1 kHz 的定时中断**。三件事同时成立才算接对：

1. `mtvec` 指向自己的 trap 向量，且这个向量**能返回**（保存/恢复 + `mret`）；
2. 中断矩阵把外设**源**路由到某个 CPU 通道，CLIC 输入打开了 `IE` 且优先级合理；
3. ISR 只做最小工作并**清掉源侧标志**，主循环通过环形缓冲消费数据。

| 模块               | 做什么                                                                | 可观测量                                  |
| ------------------ | --------------------------------------------------------------------- | ----------------------------------------- |
| `src/clic.zig`     | CLIC 阈值/优先级/IE/IP、矩阵路由、`mtvec`（MODE=0）与 MODE=3 的入口   | 启动时打印的 `clic inputs` / 路由/`mtvec` |
| `src/isr.zig`      | naked `trapVector`（保存 16 个易失寄存器）、48 项分发表、UART0 RX ISR | `irq total` 增长、输入回显、`rx drops`    |
| `src/critical.zig` | 保存/恢复 `mstatus.MIE`；CLIC 阈值版临界区                            | `c` 命令的三段计数                        |
| `src/main.zig`     | SYSTIMER 1 kHz 闹钟、UART RX 中断使能、串口命令、临界区测试           | `ticks/s≈1000`、示波器 500 Hz 方波        |

工程**不做**的事：

- 不使用 CLIC 的**向量模式**（`mtvec` MODE=3 + `mtvt`）：那条路要求一张
  64 字节对齐、每项一条 `j` 的向量表，本仓没有在 S31 上确认过；`clic.zig`
  只给出 `installVectored()` 这个入口，默认路径是 MODE=0；
- 不做中断嵌套调度：`mret` 之前不降阈值，ISR 内部不会再被同级/低级打断；
- 不做 DMA、不做 Flash 操作（ch08/ch09）；
- 不在 ISR 里打印：TX 走 ROM 的阻塞式 `printf`，在 ISR 里调用它等于把中断
  延迟从微秒级推到毫秒级。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行，构建链也还没有在本仓执行过。所有涉及寄存器
> 行为、中断是否真的进来、计时精度、示波器波形的结论都标为**待真机验证**。
> README 不附 `run.log`，也不贴任何“看起来像实测”的日志。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 演示引脚 | 本工程默认 **GPIO5**（tick ISR 翻转），需按 J2 针脚定义核对     |

接线：一根 USB-C 到 USB-to-UART 口即可看到全部输出。要观察 tick，用示波器或
逻辑分析仪接 J2 上 GPIO5 对应的排针（**针脚位置以板卡原理图为准**，本仓没有
收录该板的 J2 定义，属于「待真机验证」事项）。

## 中断是怎么接起来的

| 源                   | 源编号 | 矩阵通道 | CLIC 输入 | 优先级 | 处理函数           |
| -------------------- | ------ | -------- | --------- | ------ | ------------------ |
| `SYSTIMER_TARGET0`   | 33     | 0        | 16        | 3      | `tickIsr`（1 kHz） |
| `UART0`              | 9      | 1        | 17        | 2      | `uart0Isr`（RX）   |
| 软件中断（IPI 预览） | —      | 3        | 19        | 1      | `softIsr`（`s`）   |

两条容易写错、值得单独记住的事实：

1. **矩阵寄存器里存的是 CLIC 输入号，不是 0..31 的外部号**。IDF 的
   `intr_matrix_route()` 先校验 `intr_num < 32`，再把 `intr_num + 16` 交给
   `interrupt_clic_ll_route()`，后者用掩码 63 写进 `MAP[5:0]`。写 0..31 的后果是
   中断落到内部输入上，**永远不会进 ISR**。
2. **CLIC 没有 PLIC 的 claim/complete**。应答是靠“清外设源侧标志”完成的；
   边沿中断另外靠写 1 到输入的 `IP` 位应答（IDF 的 `rv_utils_intr_edge_ack()`）。

## 寄存器地图（全部有出处）

地址取自 ESP-IDF v6.1 的 `esp32s31` 头文件；S31 的 TRM 仍是 Pre-release v0.7，
手册转正后应逐项复核。

| 块                | 基址         | 出处                                                                               |
| ----------------- | ------------ | ---------------------------------------------------------------------------------- |
| CLIC（配置/状态） | `0x10800000` | `components/soc/esp32s31/include/soc/clic_reg.h`（`DR_REG_CLIC_BASE`）             |
| CLIC（每输入）    | `0x10801000` | 同上（`DR_REG_CLIC_CTRL_BASE`，每个输入 4 字节）                                   |
| INTERRUPT_CORE0   | `0x20585000` | `components/soc/esp32s31/register/soc/reg_base.h`（`DR_REG_INTERRUPT_CORE0_BASE`） |
| INTERRUPT_CORE1   | +`0x800`     | 同上（`DR_REG_INTERRUPT_CORE1_BASE = DR_REG_INTR0_BASE + 0x800`）                  |
| SYSTIMER          | `0x20399000` | `esp32s31.peripherals.ld`（`SYSTIMER`）                                            |
| UART0             | `0x2038A000` | 同上（`UART0`）                                                                    |
| IO_MUX            | `0x20582000` | `reg_base.h`（`DR_REG_IO_MUX_BASE`），每引脚偏移 `pin × 4`                         |
| GPIO              | `0x20583000` | `reg_base.h`（`DR_REG_GPIO_BASE`）                                                 |

本工程实际触碰的寄存器：

| 寄存器                   | 偏移 / 计算             | 用途                                                           |
| ------------------------ | ----------------------- | -------------------------------------------------------------- |
| `CLIC_INT_CONFIG`        | CLIC + `0x0`            | `NVBITS[0]`、`MNLBITS[4:1]`                                    |
| `CLIC_INT_INFO`          | CLIC + `0x4`            | `NUM_INT[12:0]`（复位 48）、`VERSION[20:13]`                   |
| `CLIC_INT_THRESH`        | CLIC + `0x8`            | 阈值在 `[31:24]`；写后需读一次                                 |
| `CLIC_INT_CTRL(i)`       | `0x10801000` + 4i       | `CTL[31:24]` 优先级、`IE` bit8、`IP` bit0                      |
| `..._INTR_MAP_REG`       | `0x20585000` + 4 × 源号 | `MAP[5:0]` = CLIC 输入号；`PASS_LEVEL[9:8]`                    |
| `SYSTIMER_CONF`          | SYSTIMER + `0x0`        | `CLK_EN` bit31、`UNIT0_WORK_EN` bit30、`TARGET0_WORK_EN` bit24 |
| `SYSTIMER_UNIT0_OP`      | +`0x4`                  | 快照请求 bit30、有效 bit29                                     |
| `SYSTIMER_TARGET0_HI/LO` | +`0x1c` / +`0x20`       | 首次比较值；LO 最后写                                          |
| `SYSTIMER_TARGET0_CONF`  | +`0x34`                 | `PERIOD[25:0]`、周期模式 bit30、unit 选择 bit31                |
| `SYSTIMER_UNIT0_VALUE_*` | +`0x40` / +`0x44`       | 64 位计数快照                                                  |
| `SYSTIMER_INT_ENA/CLR`   | +`0x64` / +`0x6c`       | `TARGET0_INT` bit0                                             |
| `UART_FIFO`              | UART0 + `0x0`           | 读 RX FIFO（低 8 位）                                          |
| `UART_INT_ENA/CLR`       | +`0xc` / +`0x10`        | `RXFIFO_FULL` bit0、`RXFIFO_TOUT` bit8                         |
| `UART_STATUS`            | +`0x1c`                 | `RXFIFO_CNT[7:0]`                                              |
| `UART_CONF1`             | +`0x24`                 | `RXFIFO_FULL_THRHD[7:0]`（复位 96，本工程改 1）                |
| `GPIO_OUT_W1TS/W1TC`     | GPIO + `0x8` / +`0xc`   | ISR 里翻转引脚（不读改写，不碰别的位）                         |
| `GPIO_FUNC5_OUT_SEL_CFG` | GPIO + `0xaf4` + 5 × 4  | 写 `256` = `SIG_GPIO_OUT_IDX`                                  |

## 文件表

| 路径                                | 角色                                                                                          | 代码浏览                                                                                    |
| ----------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `build.zig`                         | 目标串 + 链接脚本 + 产物 `zig-out/bin/app.elf`                                                | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/build.zig)                         |
| `linker/s31.ld`                     | `ENTRY(_start)`、`.app_desc` 先于代码、`.text.entry` 承载 trap 向量、栈/`.bss` 符号、ROM 别名 | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/linker/s31.ld)                     |
| `src/start.zig`                     | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → 设 sp/gp → 清 `.bss` → 跳 `main`       | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/start.zig)                     |
| `src/main.zig`                      | 横幅、CLIC 初始化顺序、1 kHz 闹钟、UART RX 使能、命令循环、临界区测试                         | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/main.zig)                      |
| `src/clic.zig`                      | 阈值/优先级/IE/IP、矩阵路由（写 CLIC 输入号）、`mtvec` 两种模式的入口                         | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/clic.zig)                      |
| `src/isr.zig`                       | naked `trapVector`、`trapDispatch`、48 项分发表、UART0 RX ISR、256 字节环形缓冲               | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/isr.zig)                       |
| `src/critical.zig`                  | `enter`/`exit`（保存恢复 `mstatus`）、`enterLevel`/`exitLevel`（CLIC 阈值）                   | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/src/critical.zig)                  |
| `idf-bootstrap/CMakeLists.txt`      | 最小 IDF 工程根：只为产出 bootloader 与分区表                                                 | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | `main` 组件注册，只有一个空 `app_main.c`                                                      | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | 空 `app_main`，永不被执行；只为让 IDF 构建走完                                                | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | 16 MB Flash + single-app-large（factory 应用槽在 `0x10000`）                                  | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                                | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/tools/flash.sh)                    |
| `README.md`                         | 本文件                                                                                        | [查看](/static/code/#/zig-esp32-s31/ch07-interrupts-clic/README.md)                         |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置的
single-app-large 分区表）、没有 `components/`（不链接任何 IDF 组件）、
没有 `run.log`（真机未跑）。生成物 `zig-out/`、`.zig-cache/`、
`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 都不入库。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥5.2）

| 工具    | 版本要求              | 说明                                                                      |
| ------- | --------------------- | ------------------------------------------------------------------------- |
| Zig     | 0.17.1                | 交叉编译 + 链接脚本；`zig version` 必须精确匹配                           |
| ESP-IDF | v6.1                  | 目标 `esp32s31` 为 preview target；提供二级 bootloader、esptool、binutils |
| esptool | >= 5.2                | `elf2image`、`image-info`、`write-flash`；随 IDF 安装，也可单独安装       |
| 目标板  | ESP32-S31 CoreBoard-1 | ESP32-S31-WROOM-3（N16R16V）                                              |
| 主机    | Linux 或 Windows      | Windows 用 IDF 的 PowerShell 导出脚本；`tools/flash.sh` 用 Git Bash/MSYS2 |

构建前让 `esptool` 与 `riscv32-esp-elf-*` 进入 `PATH`（它们随 IDF 安装）：

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh

# Windows PowerShell
. $env:IDF_PATH\export.ps1
```

## 构建

### 1. 应用 ELF（纯 Zig，无 idf.py）

```bash
cd practice/zig-esp32-s31/ch07-interrupts-clic

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

产物是 `zig-out/bin/app.elf`。`zicsr` 是必须的：`mtvec`/`mstatus`/`mepc`/`mcause`/
`mtval`/`mtvt` 全是 CSR 指令。

### 2. 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

### 3. bootloader 与分区表（供应商步骤）

在 `idf-bootstrap/` 里用 preview 模式 set-target（目标为 `esp32s31`）后构建，
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
esptool（`flash_args` 里的相对路径以 build 目录为基准）。

## 运行

串口按 **115200 8N1** 打开 UART0（GPIO58/59）。二级 bootloader 会先打印自己的
启动日志，随后跳到 `_start`。

应用侧的**目标形态**（验收目标，不是实测日志）：

```text
ch07-interrupts-clic | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
demo gpio=5
clic inputs=48
clic priority bits (raw)=3
clic version (raw)=<芯片版本，待真机确认>
clic hw vector=1
mtvec=0x2f000100
uart input id=17
tick input id=16
soft input id=19
interrupts on: 1 kHz systimer tick + UART0 rx (polling removed)
?  help / p  counters / c  critical test / s  software irq / t  trap demo
ticks/s=1000
```

- 启动横幅与 CLIC 自述各出现一次；
- 每约 1 秒一行 `ticks/s=`，正常应接近 1000（差值来自测量窗口与丢 tick）；
- 任意可打印字符被原样回显（**这次是中断收的**，主循环只负责取缓冲）；
- `p` 打印计数：`ticks`、`tick age us`、`irq total`、`rx bytes`、`rx drops`、
  `mstatus`、`clic threshold`、两条 `intr map`、`mtvec`、两个输入号；
- `c` 跑三段临界区测试，输出 `masked ticks`（应为 0）、`catch-up ticks`
  （CLIC 的 `IP` 只有一位，多次命中合并成一次）、嵌套与阈值两段；
- `s` 置软件中断的 `IP` 位，`soft irq` 加 1；
- `t` **故意**执行全零指令，串口出现 `[E] ---- exception ----` 与
  `mcause=0x00000002`，随后停机，必须按 EN 复位；
- 示波器：GPIO5 上约 500 Hz 方波（1 kHz 中断每次翻转一次）。

## 真实输出

待真机验证：`run.log` 待真机回填。本工程尚未在任何真机上运行，也未在本仓执行过
构建；README 不贴预期日志冒充实测。真机跑通后，把 UART0 的原始输出存为 `run.log`，
写清日期与板卡序列号，并用真实片段替换上面那一节。

## 已知边界与排障

### 1. 只用 `mtvec` 直接模式，不用 CLIC 向量模式

`mtvec` 低 2 位是模式；本章写 `0`（直接模式），于是异常与中断都进
`isr.trapVector`，再靠 `mcause` 最高位分流。CLIC 的硬件向量模式是
`MODE=3` + `mtvt`（`csr_clic.h` 的 `MTVEC_MODE_CSR = 3`、`MTVT_CSR = 0x307`），
入口是 `mtvt + 4 × 输入号` 处的指令，表必须 64 字节对齐。本工程不启用它：
向量表要在链接期生成、每项必须是一条 ±1 MB 内的 `j`，而 S31 的 `mcause`
输入号位宽与表项语义本仓没有实测过。`clic.installVectored()` 留作入口，
**未验证**。

### 2. `rx drops` 不再是 0 就一定是错

ch06 的 `rx drops` 在打字时恒为 0（主循环每 1 ms 搬一次）。本章的丢弃只可能来自
**环形缓冲满**（256 字节）：`rx drops` 增长意味着主循环被某段代码卡住超过
“256 字节 / 到达速率”。狂粘贴时它会增长，这是设计选择（丢新不丢旧）。

### 3. `tick age us` 是 ISR 的活性指标，不是抖动指标

`tickIsr` 每次都会记录一次 SYSTIMER 微秒值，主循环打印 `now - tick_us`。
1 kHz 中断 + 1 ms 主循环切片，这个值应在 `0..1000+` 之间摆动；显著大于 1000
说明 tick 没进来（或最后一次进来之后就停了）。**抖动**要用 GPIO 翻转 + 逻辑
分析仪测，属于 ch08。

### 4. F 寄存器没有保存

`eabihf` 目标的代码可以用 `f0..f31`。本工程的 `trapVector` 只保存整数易失寄存器
（`ra`/`t0..t6`/`a0..a7`），因为 ISR 路径与主循环都用整数（打印是 ROM 的
整数 `printf`）。**一旦**在 ISR 里出现浮点，或主循环依赖 `f` 寄存器跨中断存活，
就必须把 32 个 F 寄存器一起保存（128 字节）并处理 `mstatus.FS`。这是 ch10
上下文切换的主题，本章明确不做。

### 5. 中断打开之后，`wfi` 不再等于“停机”

ch06 的 `halt()` 是 `wfi` + 跳回，因为中断全关，`wfi` 就是“到此为止”。
本章开中断之后，`wfi` 会被**任意**中断唤醒——tick 每秒 1000 次，所以
`wfi` 循环会一直在转。`t` 的 trap 路径仍然是裸 `wfi` 死循环，这是有意的：
异常报告之后我们不想再被中断打扰。

### 6. 排障表

| 环境 | 现象                                               | 根因                                                       | 处置                                                                       |
| ---- | -------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------- |
| 构建 | `undefined symbol: main` / `trapDispatch`          | 符号没 `export`                                            | 两个都必须是 `export fn`；`nm` 里确认是 `T`                                |
| 构建 | 报 `expected type 'u6', found 'comptime_int'`      | 字面量超出窄整数类型范围                                   | 用 `@as(clic.Input, …)` 或 `@intCast`；路由通道请用 `comptime` 参数        |
| 运行 | 完全没有 tick，`ticks/s=0`                         | 矩阵没写、`IE` 没开、`mstatus.MIE` 没开、`mtvec` 没装      | `p` 看 `intr map`、`mtvec`、`mstatus`（bit3）；再查 `IE`                   |
| 运行 | `irq unhandled` 增长、`last unhandled id` 是 0..15 | 矩阵里写了 0..31 的外部号而不是 16..47 的输入号            | 按 `interrupt_clic_ll.h` 的调用链写 `intr_num + 16`（`clic.route()` 已做） |
| 运行 | 一开中断就卡死/反复进 trap                         | 电平中断没清源侧标志，`mret` 后立即重进                    | 每个 ISR 必须清自己的源（`INT_CLR`）；未登记输入会被自动关 `IE`            |
| 运行 | tick 进得来，但 `ticks/s` 明显偏离 1000            | 不是每 tick 都进了 ISR；或 XTAL 不是 40 MHz                | 先看 `irq total` 的增量；S31 的 SYSTIMER 固定 40 MHz/2.5 = 16 MHz          |
| 运行 | 打字无回显，`rx bytes` 不涨                        | UART 的 `INT_ENA` 没写、或输入 `IE` 没开                   | `p` 看 `intr map uart0`（应为 `0x11`）与 `uart input id`（应为 17）        |
| 运行 | 单个字符要等一会儿才回显                           | 只开了 `RXFIFO_FULL`，阈值大于 1 且没有 `RXFIFO_TOUT`      | `isr.rx_int_bits` 同时含 bit0 与 bit8；`RXFIFO_FULL_THRHD` 改成 1          |
| 运行 | 偶发丢字符，`rx drops` 不涨                        | 先清 `INT_CLR` 再读 FIFO，中间到达的字节要等下一轮         | ISR 里先按 `RXFIFO_CNT` 读完，最后再写 `INT_CLR`（`uart0Isr()` 的顺序）    |
| 运行 | `c` 的 `masked ticks` 不是 0                       | `enter()` 没真的关 `MIE`，或写回时机不对                   | `p` 看 `mstatus`；`critical.enter()` 之后 bit3 必须是 0                    |
| 运行 | `MIE restored=0`                                   | `exit()` 传了错的 `saved`（例如把 `enter()` 的返回值丢了） | 保存/恢复必须成对，且用同一次 `enter()` 的返回值                           |
| 运行 | `s` 之后 `soft irq` 不涨                           | 输入 19 没开 `IE`，或 `IP` 已置位但被阈值屏蔽              | `p` 看 `clic threshold`；`enterLevel` 测试之后要恢复                       |
| 运行 | 输入 `t` 后没有任何输出                            | `mtvec` 没装上就崩了，或 `trapVector` 不在可执行段         | 看启动时打印的 `mtvec` 是否落在 `.text.entry`（`nm -n` 核对）              |

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 产出 `zig-out/bin/app.elf`
- [ ] `readelf -h` 的 entry == `nm` 的 `_start`；`nm` 里 `trapVector` 落在 `.text.entry`（`0x2F000100` 一带）
- [ ] `readelf -l` 里 `.text`/`.data` 的 VMA 与 LMA 相同
- [ ] `xxd -s 32 -l 4 zig-out/bin/app.bin` 输出 `32 54 cd ab`（段 #0 以 `esp_app_desc_t` 开头）
- [ ] `esptool elf2image` 与 `image-info` 通过
- [ ] `idf-bootstrap` 在 preview 模式下产出 bootloader、分区表与 `flash_args`
- [ ] `tools/flash.sh` 替换应用行后一次烧录成功
- [ ] 串口出现一次横幅；`clic inputs=48`、`clic priority bits (raw)=3`、`clic hw vector=1`
- [ ] `mtvec` 指向 `.text.entry`；`uart input id=17`、`tick input id=16`
- [ ] `ticks/s` 稳定在 1000 附近（连续 10 秒）
- [ ] GPIO5 上是约 500 Hz 方波，占空比约 50%
- [ ] 键盘输入被回显，`rx bytes` 增长、`irq total` 以约 1000/s 的速率增长
- [ ] `p` 的 `intr map uart0=0x00000011`、`intr map systimer=0x00000010`
- [ ] `c` 的 `masked ticks=0`，`catch-up ticks` 为个位数，`MIE restored=1`
- [ ] `c` 的 `threshold 7 ticks=0`，退出后 `clic threshold` 回到 0
- [ ] `s` 让 `soft irq` 加 1
- [ ] `t` 打出 `mcause=0x00000002` 与 `mepc` 指向触发指令，按 EN 后重新启动
- [ ] `run.log` 回填：真机串口原始输出（当前状态：**run.log 待真机回填**）
