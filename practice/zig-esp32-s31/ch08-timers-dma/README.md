# ch08 定时器、DMA 与精确时序：把“等一会儿”变成可测量的量

> 所属章节：[[ch08-timers-dma-precision|第八章：定时器、DMA 与精确时序]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是形态 B 的第四个工程，骨架完全沿用 `ch04-linker-layout`：Zig 自己产出 ELF、
`linker/s31.ld` 决定段布局、`_start` 是入口、应用镜像由 `esptool elf2image`
生成，IDF 只负责二级 bootloader 与分区表（`idf-bootstrap/`）。

在不变的骨架之上，本章加了三件事：

| 模块               | 做什么                                                            | 可观测量                                         |
| ------------------ | ----------------------------------------------------------------- | ------------------------------------------------ |
| `src/timg.zig`     | TIMG0 T0：XTAL 40 MHz → 分频 40 → 1 MHz；绝对时刻装闹钟、轮询命中 | 1 ms 周期的命中偏差（min/max/mean_abs，单位 µs） |
| `src/systimer.zig` | SYSTIMER 16 MHz / 52 位：`delayUs`、超时截止时刻                  | `delayUs(500)` 的实际耗时偏差                    |
| `src/dma.zig`      | AHB-GDMA 通道对 0 的内存到内存搬运，2 条描述符，RX DONE 轮询      | 2 KiB 是否逐字节正确、传输耗时的 ns 数           |

工程**不做**的事，同样重要：

- 不打开任何中断：TIMG 闹钟只置 `INT_RAW`，DMA 只置 `IN_INT_RAW`，全部由主循环
  轮询。中断接入（CLIC 模式、路由、`mie`）是前一章的主题，混进来会让“定时器
  不准”和“中断没进”两类故障无法区分。
- 不配置 PLL / 时钟树：TIMG 的源显式选 XTAL（40 MHz），SYSTIMER 的 16 MHz 是
  硬件固定分频。两者都不依赖 CPU 主频。
- 不碰 PSRAM：缓冲与描述符都在内部 SRAM。PSRAM 与 cache 一致性只在正文里讲清
  边界，不在本工程验收。
- 不做 DMA 的 burst 优化：默认 single 模式先证明链路通；incr4/8/16 的开关留在
  `dma.zig` 的 `setBurstMode` 里，供读者自行实验。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行，构建链也没有在本仓执行过。所有涉及寄存器
> 行为、闹钟命中时刻、DMA 完成与耗时的结论都标为**待真机验证**。README 不附
> `run.log`，也不贴任何“看起来像实测”的日志。

## 硬件与接线

| 项       | 事实                                                             |
| -------- | ---------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                   |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM          |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥  |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位               |
| 观测引脚 | 本工程默认 **GPIO5**，每次测量/心跳翻转一次（示波器/逻辑分析仪） |

一根 USB-C 到 USB-to-UART 口即可看到全部输出。要观察抖动，把示波器接 J2 上
GPIO5 对应的排针（**针脚位置以板卡原理图为准**，本仓没有收录该板的 J2 定义，
属于「待真机验证」事项）。`src/main.zig` 里的 `monitor_pin` 是常量，换脚只改
一行。

GPIO5 的选择理由与 ch06 相同：IO_MUX 表里是普通 `U_GPIO5`（偏移 `0x14`），
不涉及 USB、XTAL32K、ADC 组与 strapping。

## 寄存器地图（全部有出处）

地址取自 ESP-IDF v6.1 的 `esp32s31` 头文件与链接片段；S31 的 TRM 仍是
Pre-release v0.7，手册转正后应逐项复核。

| 块            | 基址         | 出处                                                                        |
| ------------- | ------------ | --------------------------------------------------------------------------- |
| TIMG0         | `0x20580000` | `register/soc/reg_base.h`（`DR_REG_TIMERG0_BASE`）                          |
| TIMG1         | `0x20581000` | 同上（`DR_REG_TIMERG1_BASE`）                                               |
| SYSTIMER      | `0x20399000` | 同上（`DR_REG_SYSTIMER_BASE`）                                              |
| AHB-DMA       | `0x20343000` | 同上（`DR_REG_AHB_DMA_BASE`）                                               |
| HP_SYS_CLKRST | `0x20587000` | 同上（`DR_REG_HP_SYS_CLKRST_BASE`）；TIMG 源选择 `+0x114`、DMA 门控 `+0x7c` |
| IO_MUX        | `0x20582000` | 同上（`DR_REG_IO_MUX_BASE`）                                                |
| GPIO          | `0x20583000` | 同上（`DR_REG_GPIO_BASE`）                                                  |

本工程实际触碰的寄存器：

| 寄存器                            | 偏移 / 计算                 | 用途                                                                              |
| --------------------------------- | --------------------------- | --------------------------------------------------------------------------------- |
| `TIMG_T0CONFIG_REG`               | TIMG0 + `0x00`              | `T0_EN`[31]、`AUTORELOAD`[29]、`DIVIDER`[28:13]、`ALARM_EN`[10]、`DIVCNT_RST`[12] |
| `TIMG_T0LO/HI`                    | +`0x04` / +`0x08`           | 计数器低 32 位 / 高 22 位                                                         |
| `TIMG_T0UPDATE_REG`               | +`0x0c`                     | bit31 请求快照，自清零                                                            |
| `TIMG_T0ALARMLO/HI`               | +`0x10` / +`0x14`           | 闹钟目标值                                                                        |
| `TIMG_T0LOADLO/HI`、`TIMG_T0LOAD` | +`0x18` / +`0x1c` / +`0x20` | 暂存并装载计数值                                                                  |
| `TIMG_INT_RAW/CLR_TIMERS`         | +`0x74` / +`0x7c`           | T0 命中位 = bit0                                                                  |
| `TIMG_REGCLK_REG`                 | +`0xfc`                     | bit31 寄存器时钟常开                                                              |
| `HP_SYS_CLKRST_TIMERGRP0_CTRL0`   | CLKRST + `0x114`            | `T0_SRC_SEL`[4:3]、`T0_CLK_EN`[5]                                                 |
| `SYSTIMER_CONF`                   | +`0x00`                     | bit31 寄存器时钟、bit30 unit0 使能                                                |
| `SYSTIMER_UNIT0_OP`               | +`0x04`                     | bit30 update、bit29 valid                                                         |
| `SYSTIMER_UNIT0_VALUE_HI/LO`      | +`0x40` / +`0x44`           | 快照值                                                                            |
| `AHB_DMA_IN_CONF0_CH0`            | DMA + `0x100`               | bit0 RST、bit4 `MEM_TRANS_EN`、burst[7:6]                                         |
| `AHB_DMA_IN_LINK_CH0`             | +`0x110`                    | bit2 START、bit1 STOP                                                             |
| `AHB_DMA_IN_LINK_ADDR_CH0`        | +`0x114`                    | 描述符链头                                                                        |
| `AHB_DMA_IN_PERI_SEL_CH0`         | +`0x138`                    | bit[5:0] M2M 触发号                                                               |
| `AHB_DMA_IN_INT_RAW_CH0`/`CLR`    | +`0x00` / +`0x0c`           | bit0 DONE、bit1 SUC_EOF、bit2/3 错误                                              |
| `AHB_DMA_OUT_CONF0_CH0`           | +`0x180`                    | bit0 RST、bit3 EOF_MODE、burst[9:8]                                               |
| `AHB_DMA_OUT_LINK_CH0`            | +`0x190`                    | bit1 START、bit0 STOP                                                             |
| `AHB_DMA_OUT_PERI_SEL_CH0`        | +`0x1b8`                    | bit[5:0] M2M 触发号                                                               |
| `AHB_DMA_OUT_LINK_ADDR_CH0`       | +`0x194`                    | 描述符链头                                                                        |

两个“容易记错的常量”，都来自头文件而不是手册口述：

1. **分频值直接写**：`timer_ll_set_clock_prescale` 把 `divider` 原样写进
   `tx_divider`，合法范围 2..65536，写 0 表示 65536（`esp_hal_timg/esp32s31/
include/hal/timer_ll.h`）。所以 40 MHz / 40 = 1 MHz 就是把 40 写进去。
2. **M2M 触发号是 9 或 15**：`AHB_DMA_LL_M2M_FREE_PERIPH_ID_MASK = 0x8200`
   （`esp_hal_dma/esp32s31/include/hal/gdma_ll.h`）说明 bit9 与 bit15 是
   M2M 可用的触发号；本工程取 9。真机上若搬运不动，第一步就核对这个号：
   它在 `IN_PERI_SEL`/`OUT_PERI_SEL` 的低 6 位（复位值 63 = 未连接）。

## 文件表

| 路径                                | 角色                                                                                    | 代码浏览                                                                               |
| ----------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `build.zig`                         | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                                    | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/build.zig)                         |
| `linker/s31.ld`                     | `ENTRY(_start)`、`.app_desc` 先于代码、栈/`.bss` 符号、ROM 别名                         | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/linker/s31.ld)                     |
| `src/start.zig`                     | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → 设 sp/gp → 清 `.bss` → 跳 `main` | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/src/start.zig)                     |
| `src/main.zig`                      | 抖动测量（TIMG 周期 / `delayUs`）、DMA 搬运 + CPU 校验、500 ms 心跳与引脚翻转           | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/src/main.zig)                      |
| `src/timg.zig`                      | TIMG0 T0：源选择、分频、计数快照、绝对时刻闹钟、轮询/清除                               | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/src/timg.zig)                      |
| `src/systimer.zig`                  | SYSTIMER：52 位读数、`delayUs`、超时截止时刻                                            | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/src/systimer.zig)                  |
| `src/dma.zig`                       | AHB-GDMA：通道复位、M2M 连接、12 字节描述符链、启动/轮询完成                            | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/src/dma.zig)                       |
| `idf-bootstrap/CMakeLists.txt`      | 最小 IDF 工程根：只为产出 bootloader 与分区表                                           | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | `main` 组件注册，只有一个空 `app_main.c`                                                | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | 空 `app_main`，永不被执行；只为让 IDF 构建走完                                          | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | 16 MB Flash + single-app-large（factory 应用槽在 `0x10000`），不启用 PSRAM              | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                          | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/tools/flash.sh)                    |
| `README.md`                         | 本文件                                                                                  | [查看](/static/code/#/zig-esp32-s31/ch08-timers-dma/README.md)                         |

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
cd practice/zig-esp32-s31/ch08-timers-dma

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

产物是 `zig-out/bin/app.elf`。`-Dcpu` 里的 `zicsr` 是必须的：`_start` 的
`csrci mstatus` 与本章用不到、但链接脚本保留的 `mtvec` 路径都依赖它。

### 2. 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`elf2image` 读 ELF 的入口地址与 `PT_LOAD` 段表；`.bss` 因为 `NOLOAD` 不占镜像
字节（本工程的 DMA 描述符与缓冲都在 `.bss`，不增加镜像体积）。

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
esptool（`flash_args` 里的相对路径以 build 目录为基准）。

## 运行

串口按 **115200 8N1** 打开 UART0（GPIO58/59）。二级 bootloader 会先打印自己的
启动日志（内容随 IDF 版本变化），随后跳到 `_start`。

应用侧的**目标形态**（验收目标，不是实测日志）：

```text
ch08-timers-dma | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
systimer: 16 MHz, boot ticks=<n> us
timg.t0 1ms: samples=64 min=<i> max=<j> mean_abs=<k> last_interval=<l> us
delayUs(500): samples=64 min=<i> max=<j> mean_abs=<k> last_interval=<l> us
dma: chunks=2 verified
  in_raw=0x<n> out_raw=0x<n> rx_done=0x<n> tx_done=0x<n>
  transfer_ns=<n>
round 1: 0 bad, <n> ns
round 2: 0 bad, <n> ns
```

字段含义：

- `timg.t0 1ms` 的 `min/max/mean_abs` 是“实际命中时刻 − 目标时刻”的微秒偏差
  （1 tick = 1 µs）；`last_interval` 是最后一次相邻命中间隔，应接近 1000。
- `delayUs(500)` 的偏差通常比硬件定时器大一个量级：它是软件忙等，包含循环
  开销、取指与流水线影响。
- `dma: chunks=2 verified`：2048 字节被切成 2 条 1024 字节描述符，CPU 逐字节
  比对通过。
- `in_raw` 应包含 bit0（DONE）与 bit1（SUC_EOF）；若只出现 bit0，说明链尾的
  `suc_eof` 没传对。
- `round N` 每 500 ms 一行，`0 bad` 表示这一轮搬运完全一致。

数值具体是多少，取决于真机与编译产物，本仓不预填。

## 证据与边界

### 1. 为什么“1 tick = 1 µs”值得单独说

TIMG 的计数时钟 = 源 / 分频。本工程显式把源选成 XTAL（`T0_SRC_SEL = 0`，
复位值也是 0），分频写 40，于是 40 MHz / 40 = 1 MHz。**这两个前提任何一条
不成立，读出来的数就不是微秒**：

- 若源被 bootloader 改成 PLL_F80M，同样分频 40 得到 2 MHz，所有“µs”要除以 2；
- 若分频写 0，硬件按 65536 解释，得到约 610 Hz，1 ms 周期会变成 1.6 秒。

所以 `timg.zig` 的 `init()` 不是装饰：它把源的选择从“别人的现场”变成“本工程
的显式约定”。

### 2. 抖动与漂移不是一回事

- **抖动（jitter）**：单次命中时刻相对目标时刻的偏差，本工程用 `min/max/mean_abs`
  表达；它主要来自中断、总线竞争、轮询代码的取指延迟。
- **漂移（drift）**：N 次之后累计的时间差，等价于“平均周期 − 目标周期”。
  如果每次都在目标上 `+1000` 而不是“命中后再等 1000”，漂移就只来自时钟源本身
  的误差（XTAL 的 ppm），不会把软件的迟到量积分进去。`measureTimerJitter`
  用的正是绝对时刻。

### 3. 描述符的生命周期

`dma.zig` 的描述符数组是模块级 `var`，落在 `.bss`。这不是风格问题：DMA 是
**异步**引擎，启动后 CPU 立刻返回去轮询状态；如果描述符是函数栈上的临时变量，
函数一返回，栈帧就可能被下一次调用覆盖，硬件读到的就是垃圾。同理，缓冲也必须
在传输期间保持有效——本工程用模块级数组，天然满足。

### 4. `IN_CONF1` 的策略位没有配置

IDF 的 `async_memcpy` 会打开 owner check、描述符回写与 `eof_till_data_popped`。
本工程保持 `IN_CONF1` 复位值，只配 `IN_CONF0`/`LINK`/`PERI_SEL`，用最小的寄存器
集合把链路跑通。若真机出现“前面全对、尾部若干字节不对”，先核对
`register/soc/ahb_dma_reg.h` 里 `IN_CONF1` 的 EOF 策略位（待真机验证）。

### 5. cache 与 PSRAM：本章只划边界

本工程不启用 PSRAM，缓冲在内部 SRAM。若把缓冲换到 PSRAM（S31 有 16 MB），
必须处理 cache 一致性：

- CPU 写源缓冲后，先按 cache line 写回（C2M），DMA 才能读到新数据；
- DMA 写目的缓冲后，CPU 读之前要无效对应 cache line（M2C），否则读到旧值；
- 描述符本身建议放内部 SRAM，避免“硬件读描述符时 cache 还没写回”；
- PSRAM 控制器不支持大于 128 字节的突发（`GDMA_LL_MAX_BURST_SIZE_PSRAM = 128`）。

这些在 IDF 里由 `esp_cache_msync` 与 `async_memcpy` 的拆分逻辑兜底；本工程
没有实现，属于「待真机验证」的后续工作。

### 6. 排障表

| 环境 | 现象                                          | 根因                                                     | 处置                                                                          |
| ---- | --------------------------------------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 构建 | `undefined symbol: main`                      | `main` 没 `export`                                       | 用 `pub export fn main`；`nm` 确认符号名                                      |
| 构建 | 报 `expected type 'u5'` 一类                  | 移位数类型：`u32 << u6` 不合法                           | 先 `@intCast` 到 `u5` 再移位                                                  |
| 构建 | `esp_rom_printf` 变参类型错误                 | 把切片直接传给了 C 变参                                  | `%s` 用 `[*:0]const u8`                                                       |
| 运行 | 串口只有 bootloader 日志                      | 入口/符号/`_start` 早期崩溃                              | 查 entry → `nm` 里 `main` 是否为 `T` → `objdump` 前 20 条指令                 |
| 运行 | 抖动 `last_interval` 远大于 1000              | 分频不是 40，或源不是 XTAL                               | 读回 `T0CONFIG.DIVIDER` 与 `TIMERGRP0_CTRL0.T0_SRC_SEL`；确认 `init()` 被调用 |
| 运行 | 闹钟永远不命中                                | 忘记 `enableAlarm()`，或 `ALARM_EN` 被上次命中自动清掉   | 每次装目标后都重新使能；先读回 `INT_RAW` 的 bit0                              |
| 运行 | 计数器读数不变                                | TIMG 时钟门没开，或 `UPDATE` 等待死循环                  | 确认 `TIMERGRP0_CTRL0.T0_CLK_EN=1`；`UPDATE` 位应自清零                       |
| 运行 | `dma: transfer failed (timeout)`              | M2M 触发号不对、通道没连到内存、或时钟门关了             | 核对 `PERI_SEL=9`、`MEM_TRANS_EN=1`、`AHB_PDMA_CTRL0.SYS_CLK_EN=1`            |
| 运行 | `dma: transfer failed (descriptor/bus error)` | 描述符地址/对齐错，或缓冲不在 DMA 可访问区               | 描述符与缓冲都要 4 字节对齐且在 SRAM；检查 `rx_done_desc` 落在哪个地址        |
| 运行 | `MISMATCH first_bad=0 bad=2048`               | TX 没启动（先 RX 后 TX 的顺序反了）或描述符 owner 没置 1 | 按 `dma.zig` 的顺序；确认 `dw0` 的 bit31 = 1                                  |
| 运行 | `MISMATCH` 且 `bad` 是零星的                  | cache 一致性（换到 PSRAM 后才会出现）                    | 按「证据与边界 5」做写回/无效                                                 |

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 产出 `zig-out/bin/app.elf`
- [ ] `readelf -h` 的 entry == `nm` 的 `_start`
- [ ] `xxd -s 32 -l 4 zig-out/bin/app.bin` 输出 `32 54 cd ab`（段 #0 以 `esp_app_desc_t` 开头）
- [ ] `esptool elf2image` 与 `image-info` 通过
- [ ] `idf-bootstrap` 在 `--preview` 下产出 bootloader、分区表与 `flash_args`
- [ ] `tools/flash.sh` 替换应用行后一次烧录成功
- [ ] 串口出现一次启动横幅，随后是两行抖动统计
- [ ] `timg.t0 1ms` 的 `last_interval` 在 1000 附近（±几十 µs）
- [ ] `delayUs(500)` 的 `mean_abs` 明显大于硬件定时器的对应值
- [ ] `dma: chunks=2 verified`，`in_raw` 同时含 bit0 与 bit1
- [ ] 500 ms 心跳稳定，GPIO5 上可见约 1 Hz 翻转
- [ ] 连续运行 30 分钟，`round N` 的 `0 bad` 不退化（无累计漂移/丢传输）
- [ ] `run.log` 回填：真机串口原始输出（当前状态：**run.log 待真机回填**）
