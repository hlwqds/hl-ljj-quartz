# ch06 GPIO / UART / 日志 / panic：最小可观测量

> 所属章节：[[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是形态 B 的第二个工程，骨架完全沿用 `ch04-linker-layout`：Zig 自己产出 ELF、
`linker/s31.ld` 决定段布局、`_start` 是入口、应用镜像由 `esptool elf2image`
生成，IDF 只负责二级 bootloader 与分区表（`idf-bootstrap/`）。

在不变的骨架之上，本章加了四件事，每件都有对应的可观测点：

| 模块            | 做什么                                                    | 可观测量                            |
| --------------- | --------------------------------------------------------- | ----------------------------------- |
| `src/uart.zig`  | TX 走 ROM `esp_rom_printf`；RX 轮询 FIFO 搬进环形缓冲     | 启动横幅、字符回显、`p` 的计数      |
| `src/gpio.zig`  | IO_MUX 选 GPIO 功能 + GPIO 输出使能/翻转；输入与上拉      | 演示引脚 1 Hz 翻转（示波器/万用表） |
| `src/log.zig`   | 四级日志（err/warn/info/debug），正文是编译期字符串       | 行首 `[E]/[W]/[I]/[D]` 标记         |
| `src/panic.zig` | `mtvec` 指向自写 trap 向量，打印 mcause/mepc/ra/sp 后停机 | 串口 `t` 命令触发一次可预期的 trap  |

工程**不做**的事，同样重要：

- 不配置时钟、不复位原因、不喂狗（那是前一章的主题）；
- 不打开任何中断：`mie = 0`、`mstatus.MIE = 0`，UART 接收是轮询；
- 不驱动 GPIO60 上的可寻址 RGB LED：那是 WS2812 类单线归零码器件，
  需要 RMT 或严格校准的时序，普通 GPIO 推挽输出点不亮它（见「已知边界」第 3 条）；
- 不实现 `std.log` 后端、不引入 `std.fmt`：日志格式在编译期就定死了。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行，构建链也还没有在本仓执行过。所有涉及寄存器
> 行为、引脚电平、串口输出、trap 现场的结论都标为**待真机验证**。README 不附
> `run.log`，也不贴任何“看起来像实测”的日志。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| USB      | USB-to-UART（烧录/日志）与 USB Serial/JTAG（调试）各一路        |
| 演示引脚 | 本工程默认 **GPIO5**，需按 J2 针脚定义核对（见下）              |

接线：一根 USB-C 到 USB-to-UART 口即可看到全部输出。要观察 GPIO 翻转，用示波器
或逻辑分析仪接 J2 上 GPIO5 对应的排针（**针脚位置以板卡原理图为准**，本仓没有
收录该板的 J2 定义，属于「待真机验证」事项）。

`src/main.zig` 里的 `demo_pin` 是一个常量，换引脚只改这一行。选 GPIO5 的理由只有
一个：它在 IO_MUX 表里是普通的 `U_GPIO5`（偏移 `0x14`），不涉及 USB（GPIO33/34）、
XTAL32K（GPIO0/1）、ADC 组（GPIO42–57）与 strapping（GPIO61）。板上是否有别的
器件挂在 GPIO5 上，必须看原理图。

## 寄存器地图（全部有出处）

地址取自 ESP-IDF v6.1 的 `esp32s31` 头文件与链接片段；S31 的 TRM 仍是
Pre-release v0.7，手册转正后应逐项复核。

| 块      | 基址         | 出处                                                                      |
| ------- | ------------ | ------------------------------------------------------------------------- |
| UART0   | `0x2038A000` | `components/soc/esp32s31/ld/esp32s31.peripherals.ld`（`UART0`）           |
| IO_MUX  | `0x20582000` | `components/soc/esp32s31/register/soc/reg_base.h`（`DR_REG_IO_MUX_BASE`） |
| GPIO    | `0x20583000` | 同上（`DR_REG_GPIO_BASE`）                                                |
| RMT     | `0x20355000` | `esp32s31.peripherals.ld`（`RMT`；`RMTMEM = 0x20355800`）                 |
| LP GPIO | `0x20713000` | 同上（`LP_GPIO`），本章不用                                               |
| LP UART | `0x20810000` | 同上（`LP_UART`），本章不用                                               |

本工程实际触碰的寄存器（偏移来自 `register/soc/uart_reg.h`、`gpio_reg.h`、
`io_mux_reg.h`）：

| 寄存器                       | 偏移 / 计算            | 用途                                   |
| ---------------------------- | ---------------------- | -------------------------------------- |
| `UART_FIFO_REG`              | UART0 + `0x00`         | 读 RX FIFO（低 8 位为数据）            |
| `UART_INT_RAW_REG`           | UART0 + `0x04`         | 只读：`FRM_ERR`（bit 3）粘滞标志       |
| `UART_STATUS_REG`            | UART0 + `0x1c`         | `RXFIFO_CNT`[7:0]、`TXFIFO_CNT`[23:16] |
| `UART_XXX` 的 TX 路径        | 不直接访问             | 全部交给 ROM `esp_rom_printf`          |
| `PERIPHS_IO_MUX_U_<pin>`     | IO_MUX + **pin × 4**   | `MCU_SEL`[14:12]、`FUN_IE` bit 9       |
| `GPIO_OUT_W1TS/W1TC`         | GPIO + `0x08` / `0x0c` | 置位/清零输出电平                      |
| `GPIO_ENABLE_W1TS/W1TC`      | GPIO + `0x38` / `0x3c` | 打开/关闭输出使能                      |
| `GPIO_IN_REG`                | GPIO + `0x64`          | 读引脚真实电平                         |
| `GPIO_FUNCn_OUT_SEL_CFG_REG` | GPIO + `0xaf4` + n × 4 | 写 `256` = `SIG_GPIO_OUT_IDX`          |

两个“看起来像魔法数字”的地方，都能当场自证：

1. **IO_MUX 偏移是 pin × 4**。头文件里 `PERIPHS_IO_MUX_U_GPIO2 = 0x8`、
   `U_GPIO5 = 0x14`、`U_GPIO58 = 0xe8`、`U_GPIO62 = 0xf8`，全部等于引脚号 × 4
   （GPIO0/1 的寄存器在 `0x0/0x4`，名字是 XTAL32K 的两个引脚）。所以代码里
   不需要一张 63 项的表。
2. **`OUT_SEL = 256`**。`gpio_sig_map.h` 的 `SIG_GPIO_OUT_IDX = 256`，
   `gpio_reg.h` 里 `GPIO_FUNC0_OUT_SEL` 的复位值也是 256，注释写明“256 表示
   `GPIO_OUT_REG`/`GPIO_ENABLE_REG` 的第 0 位被选为输出值与输出使能”。
   写它是为了防 bootloader/ROM 改过矩阵。

## 文件表

| 路径                                | 角色                                                                                          | 代码浏览                                                                                  |
| ----------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `build.zig`                         | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                                          | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/build.zig)                         |
| `linker/s31.ld`                     | `ENTRY(_start)`、`.app_desc` 先于代码、`.text.entry` 承载 trap 向量、栈/`.bss` 符号、ROM 别名 | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/linker/s31.ld)                     |
| `src/start.zig`                     | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → 设 sp/gp → 清 `.bss` → 跳 `main`       | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/start.zig)                     |
| `src/main.zig`                      | 横幅、装 trap 向量、配 GPIO、轮询 RX + 回显、单字符命令、1 Hz 翻转                            | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/main.zig)                      |
| `src/uart.zig`                      | TX（ROM printf）、`putHex32`/`putDec32`、RX 轮询、128 字节 SPSC 环形缓冲                      | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/uart.zig)                      |
| `src/gpio.zig`                      | IO_MUX 选 GPIO、输出配置/翻转、输入 + 上拉、读回                                              | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/gpio.zig)                      |
| `src/log.zig`                       | 四级日志与三种行格式（纯文本 / 十进制 / 十六进制）                                            | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/log.zig)                       |
| `src/panic.zig`                     | `mtvec` 安装、naked `trapVector`、`trapReport`、`fatal`、`halt`、`trapDemo`                   | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/src/panic.zig)                     |
| `idf-bootstrap/CMakeLists.txt`      | 最小 IDF 工程根：只为产出 bootloader 与分区表                                                 | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | `main` 组件注册，只有一个空 `app_main.c`                                                      | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | 空 `app_main`，永不被执行；只为让 IDF 构建走完                                                | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | 16 MB Flash + single-app-large（factory 应用槽在 `0x10000`）                                  | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                                | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/tools/flash.sh)                    |
| `README.md`                         | 本文件                                                                                        | [查看](/static/code/#/zig-esp32-s31/ch06-gpio-uart-log/README.md)                         |

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
cd practice/zig-esp32-s31/ch06-gpio-uart-log

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

产物是 `zig-out/bin/app.elf`。`-Dcpu` 里的 `zicsr` 是必须的：`mtvec` 的读写
（`csrw`/`csrr`）与 `_start` 里的 `csrci mstatus` 都靠它。

### 2. 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`elf2image` 读 ELF 的入口地址与 `PT_LOAD` 段表；`.bss` 因为 `NOLOAD` 不占镜像
字节。`--flash-mode dio`/`--flash-size 16MB`/`--flash-freq 80m` 必须与模组一致。

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
ch06-gpio-uart-log | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
demo gpio=5
gpio: IO_MUX MCU_SEL=1 + OUT_SEL=256 + ENABLE=1（待真机验证）
type ? for help; input is polled, not interrupt driven
?  help / p  counters / t  trap demo (halts until reset)
toggles=4 rx drops=0
toggles=8 rx drops=0
```

- 启动横幅恰好一次，在 bootloader 日志之后；
- 输入 `p` 回车，打印 `rx queued` / `rx drops` / `tx fifo` / `rx fifo` 四行；
- 任意可打印字符被原样回显（证明 RX 轮询 + 回显通路）；
- 每约 2 秒一行 `toggles=N`，`N` 每 4 次翻转加 4（1 Hz 方波）；
- 输入 `t` 会**故意**触发一次非法指令异常，串口出现 `---- trap ----` 与
  `mcause=0x00000002`，随后停机，必须按 EN 复位。这是本章唯一“会停机”的操作。

## 真实输出

待真机验证：`run.log` 待真机回填。本工程尚未在任何真机上运行，也未在本仓执行过
构建；README 不贴预期日志冒充实测。真机跑通后，把 UART0 的原始输出存为 `run.log`，
写清日期与板卡序列号，并用真实片段替换上面那一节。

## 已知边界与排障

### 1. 接收是轮询，不是中断

`src/uart.zig` 的 `drainFromFifo()` 是“生产者”，由主循环每 1 ms 调一次。
中断版本需要三件事同时到位：`mtvec` 的 **CLIC 模式**向量表、中断矩阵把 UART0
的源号路由到某个 CPU 通道、以及 `mie`/`mstatus.MIE`。本章只做了异常的
`mtvec`（MODE=0 直接模式），没有做中断路由，所以**收数据只能轮询**。

代价是可量化的：115200 下 1 ms 大约来 11.5 字节，而硬件 FIFO 深度有限；
如果主循环某处卡住几百毫秒，FIFO 就会溢出。本工程把延时切成 1 ms 一片正是
为了避免这件事。收益是数据结构不需要改：后续把 `drainFromFifo` 搬进 ISR，
环形缓冲与主循环的 `pop` 一行都不用动。

### 2. TX 完全依赖 ROM

应用不初始化 UART，所以波特率/帧格式由 ROM 决定（115200 8N1）。想改成别的
波特率，必须自己写 `UART_CLKDIV_SYNC`（+0x14，`CLKDIV`[11:0] 整数部分、
`CLKDIV_FRAG`[23:20] 小数部分）与 `UART_CONF0_SYNC`（+0x20）——这属于后续
章节的内容，本章不做。副作用是：`esp_rom_printf` 之外**不要**直接写 UART0 的
TX FIFO，否则两条路径会抢同一个 FIFO。

### 3. GPIO60 上的 RGB LED 不是普通 GPIO

板载的可寻址 RGB LED 挂 GPIO60，是 WS2812 类**单线归零码**器件：每一位靠
高电平宽度编码（典型 0 码 ≈0.4 µs、1 码 ≈0.8 µs、位周期 ≈1.25 µs，具体以
器件手册为准），对抖动敏感。用 GPIO 推挽输出 + 软件延时去“拼”波形，会同时
受中断、cache、编译器调度影响；正确做法是用 **RMT**（`0x20355000`，通道 RAM 在
`0x20355800`）把波形交给硬件。本章只把它当边界讲清楚，不点灯，也不声称能点。

### 4. trap 只有“现场”，没有“回溯”

`trapReport` 打印 `mcause`/`mepc`/`ra`/`mtval`/`sp` 后停机。没有 `.eh_frame`、
没有帧指针链、不恢复上下文：这是 panic 路径而不是中断路径。真要回溯，用
JTAG/OpenOCD 读栈，比在固件里猜帧布局可靠。

### 5. 排障表

| 环境 | 现象                                     | 根因                                                       | 处置                                                                            |
| ---- | ---------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 构建 | `undefined symbol: main`                 | `main` 没 `export`（成了 `main.main` 一类）                | 用 `pub export fn main`；`nm` 确认符号名                                        |
| 构建 | `undefined symbol: esp_rom_printf`       | 链接脚本没生效，`PROVIDE` 没被解析                         | 确认 `setLinkerScript` 指到 `linker/s31.ld`                                     |
| 构建 | 报 `expected type 'u5', found 'u6'` 一类 | 移位数类型：`u32 << u6` 不合法                             | 先 `@intCast` 到 `u5` 再移位（见 `gpio.zig` 的 `bit`）                          |
| 构建 | 报 `esp_rom_printf` 变参类型错误         | 把 `[]const u8` 切片直接传给了 C 变参                      | 用 `[*:0]const u8`（`%s` 需要 NUL 结尾）                                        |
| 烧录 | `tools/flash.sh` 报找不到 `flash_args`   | `idf-bootstrap` 没构建                                     | 进 `idf-bootstrap/` 执行 `idf.py --preview set-target esp32s31 && idf.py build` |
| 烧录 | 报“没有 0x10000 的应用行”                | 分区表不是 single-app-large                                | 确认 `sdkconfig.defaults`；删 `idf-bootstrap/sdkconfig` 后重新 `set-target`     |
| 运行 | 只有 bootloader 日志，没有横幅           | 入口/符号/`_start` 早期崩溃（形态 B 的三件老问题）         | 查 entry → `nm` 里 `main` 是否为 `T` → `objdump` 前 20 条指令                   |
| 运行 | 横幅正常但输入无回显                     | RX 引脚不是 GPIO59，或终端没打开本地回显                   | 确认接的是 UART0 RX；`p` 里看 `rx fifo` 是否始终 0                              |
| 运行 | 回显乱码                                 | 波特率/线序/电平不匹配                                     | 115200 8N1；`p` 里若 `FRM_ERR` 置位，优先怀疑波特率与接线                       |
| 运行 | 输入 `t` 后没有任何输出                  | `mtvec` 没装上（`panic.install()` 之前就崩），或向量地址错 | 打开 `debug` 级别看 `mtvec=0x...` 是否落在 `.text.entry`                        |
| 运行 | 每次心跳都掉字节                         | 主循环某处阻塞过久，FIFO 溢出                              | 缩短单片延时；或按「已知边界 1」改成中断驱动                                    |
| 运行 | 演示引脚无翻转                           | `demo_pin` 不在 J2 上，或 IO_MUX/矩阵配置被覆盖            | 按原理图核对引脚；用 `GPIO_IN` 回读确认电平真的变了                             |

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 产出 `zig-out/bin/app.elf`
- [ ] `readelf -h` 的 entry == `nm` 的 `_start`；`nm` 里 `trapVector` 落在 `.text.entry`（`0x2F000100` 一带）
- [ ] `readelf -l` 里 `.text`/`.data` 的 VMA 与 LMA 相同
- [ ] `xxd -s 32 -l 4 zig-out/bin/app.bin` 输出 `32 54 cd ab`（段 #0 以 `esp_app_desc_t` 开头）
- [ ] `esptool elf2image` 与 `image-info` 通过（entry、段、校验、SHA256 均有效）
- [ ] `idf-bootstrap` 在 `--preview` 下产出 bootloader、分区表与 `flash_args`
- [ ] `tools/flash.sh` 替换应用行后一次烧录成功
- [ ] 串口 115200 8N1 出现一次启动横幅，行首带 `[I]`
- [ ] 输入 `p` 回车，四行计数打印正常；输入可打印字符被回显
- [ ] 演示引脚（默认 GPIO5，需按 J2 核对）输出 1 Hz 方波，占空比约 50%
- [ ] 输入 `t` 后出现 `---- trap ----` 与 `mcause=0x00000002`、`mepc` 指向触发指令
- [ ] 按 EN 复位后程序重新启动（trap 没有破坏启动链）
- [ ] `run.log` 回填：真机串口原始输出（当前状态：**run.log 待真机回填**）
