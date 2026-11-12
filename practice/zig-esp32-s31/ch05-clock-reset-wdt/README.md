# ch05 clock / reset / wdt：量出频率、读出复位原因、显式喂狗

> 所属章节：[[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

ch04 证明了“Zig 自己产出的 ELF 能被 IDF 二级 bootloader 加载并跳进 `_start`”。
本工程在同一个骨架上加三个新变量，全部围绕“启动时的默认环境到底是什么”：

1. **CPU 频率**：不写任何 PLL 寄存器，用 `mcycle` 对 `SYSTIMER` 把实际频率量出来
   （`src/clock.zig`）。SYSTIMER 的时钟源在 S31 上固定为 XTAL 40 MHz 再 2.5 分频，
   即 16 MHz 节拍，所以这把尺子只依赖“板载晶振是 40 MHz”这一个板级事实。
2. **复位原因**：直接调掩膜 ROM 的 `rtc_get_reset_reason(0)`（地址 `0x2f800018`，
   由链接脚本 `PROVIDE` 接上），把 `soc_reset_reason_t` 编码翻译成名字、IDF 归类
   和一句话解释（`src/reset.zig`）。
3. **看门狗**：读 RWDT 的六个状态字段，然后按“解锁 → 写 → 上锁”的三段式显式喂狗
   （`src/wdt.zig`）。另有一个可控的超时实验开关（默认关闭）。

它验证的是五件事：

1. `PROVIDE(rtc_get_reset_reason = 0x2f800018)` 能像 `esp_rom_printf` 一样生效；
2. SYSTIMER 快照读法（update → valid → LO/HI/LO）在裸机下不需要任何 IDF 代码；
3. `mcycle` 的 `csrr` 读法与 200 ms 窗口能给出 ±1 MHz 的频率；
4. ROM printf 的 C 变参调用在 Zig 侧必须逐个 `c_uint` 化，否则真机上是垃圾；
5. RWDT 的写保护流程走通：喂狗后主循环不再被复位打断。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行，构建链也还没有在本仓执行过。所有涉及产物、
> 串口读数、复位实验、超时实验的步骤都标为**待真机验证 / 待首次构建回填**。
> README 不附 `run.log`，也不贴任何“看起来像实测”的日志。

## 硬件与接线

| 项       | 事实                                                      |
| -------- | --------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                            |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM   |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1             |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位        |
| USB      | USB-to-UART（烧录/日志）与 USB Serial/JTAG（调试）各一路  |
| 本章外设 | 不驱动 GPIO60 的可寻址 RGB LED；唯一可观测量是 UART0 文本 |

接线只要两根 USB-C：一根供电，一根接 USB-to-UART 口，外加按 RST/BOOT 做超时实验。

## 与 ch04 的差异

| 项               | ch04                                   | 本章                                                |
| ---------------- | -------------------------------------- | --------------------------------------------------- |
| 链接脚本         | `.app_desc` 先行 + SRAM                | 同左，多一条 `PROVIDE(rtc_get_reset_reason)`        |
| `_start`         | 五步（关中断/设 sp,gp/清 bss/跳 main） | 完全不变                                            |
| 输出             | 每秒 `tick B`                          | 复位原因 + 频率读数 + RWDT 状态 + 每 500 ms tick    |
| 新增源文件       | —                                      | `src/clock.zig`、`src/reset.zig`、`src/wdt.zig`     |
| 写入的硬件寄存器 | 无                                     | SYSTIMER `CONF`（置位）、RWDT `FEED`/`WPROTECT`     |
| IDF 侧           | bootloader + 分区表                    | 同左，`idf-bootstrap/sdkconfig.defaults` 多一行说明 |

**不写 PLL**是刻意的：二级 bootloader 已经把 CPU 切到 CPLL 320 MHz，应用继承结果。
本章先用一把只依赖 XTAL 的尺子证明这个结果，再谈“要不要自己配时钟”。

## 文件表

| 路径                                | 角色                                                                               | 代码浏览                                                                                    |
| ----------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `build.zig`                         | 目标串 + 链接脚本 + 产物 `zig-out/bin/app.elf`                                     | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/build.zig)                         |
| `linker/s31.ld`                     | `ENTRY(_start)`、`MEMORY`、`.app_desc` 先行、栈/`.bss`/`.data` 符号、三个 ROM 别名 | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/linker/s31.ld)                     |
| `src/start.zig`                     | `esp_app_desc_t`（256 字节）+ naked `_start`（顺序与 ch04 一致）                   | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/start.zig)                     |
| `src/main.zig`                      | 打印复位原因/频率/RWDT 状态，主循环每 500 ms 喂狗；`demo_timeout_ticks` 开关       | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/main.zig)                      |
| `src/clock.zig`                     | SYSTIMER 快照读法、`mcycle` 测量、`measure()`/`delayUs()`                          | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/clock.zig)                     |
| `src/reset.zig`                     | ROM `rtc_get_reset_reason`、编码表、IDF 归类、一句话解释                           | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/reset.zig)                     |
| `src/wdt.zig`                       | RWDT：`feed`/`disable`/`state`/`armSystemReset`，含写保护三段式                    | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/src/wdt.zig)                       |
| `idf-bootstrap/CMakeLists.txt`      | 最小 IDF 工程根：只为产出 bootloader 与分区表                                      | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | `main` 组件注册，只有一个空 `app_main.c`                                           | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | 空 `app_main`，永不被执行；只为让 IDF 构建走完                                     | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | 16 MB Flash + single-app-large（factory 应用槽在 `0x10000`）                       | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                     | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/tools/flash.sh)                    |
| `README.md`                         | 本文件                                                                             | [查看](/static/code/#/zig-esp32-s31/ch05-clock-reset-wdt/README.md)                         |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置的
single-app-large 分区表）、没有 `components/`（不链接任何 IDF 组件）、没有
`run.log`（真机未跑）。生成物 `zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、
`idf-bootstrap/sdkconfig` 都不入库。

## 寄存器与符号来源

本章碰到的每个地址都能在 IDF v6.1 的 `esp32s31` 头文件里找到出处：

| 目标                             | 地址 / 值                                                  | 来源                                                                            |
| -------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `rtc_get_reset_reason`           | `0x2f800018`                                               | `components/esp_rom/esp32s31/ld/esp32s31.rom.ld`                                |
| `esp_rom_printf`（`ets_printf`） | `0x2f800024`                                               | 同上                                                                            |
| `esp_rom_delay_us`               | `0x2f80003c`                                               | 同上                                                                            |
| SYSTIMER 基址                    | `0x20399000`                                               | `components/soc/esp32s31/register/soc/reg_base.h`（`DR_REG_SYSTIMER_BASE`）     |
| `SYSTIMER_CONF`（`+0x00`）       | bit31 `clk_en`、bit30 unit0 使能                           | `.../register/soc/systimer_reg.h`                                               |
| `SYSTIMER_UNIT0_OP`（`+0x04`）   | bit30 请求快照、bit29 快照有效                             | 同上                                                                            |
| `UNIT0_VALUE_HI/LO`              | `+0x40` / `+0x44`                                          | 同上                                                                            |
| SYSTIMER 节拍                    | 40 MHz / 2.5 = 16 MHz                                      | `components/esp_hw_support/port/esp32s31/systimer.c`                            |
| RWDT 基址                        | `0x20801000`                                               | `reg_base.h`（`DR_REG_RTC_WDT_BASE`）                                           |
| RWDT `CONFIG0..4`                | `+0x00`/`+0x04`/`+0x08`/`+0x0C`/`+0x10`                    | `.../register/soc/rtc_wdt_reg.h`                                                |
| RWDT `FEED` / `WPROTECT`         | `+0x14`（bit31）/ `+0x18`                                  | 同上                                                                            |
| RWDT 解锁密钥                    | `0x50D83AA1`                                               | `components/esp_hal_wdt/esp32s31/include/hal/rwdt_ll.h`（`RTC_WDT_WKEY_VALUE`） |
| 阶段动作编码                     | 0 OFF / 1 INT / 2 RESET_CPU / 3 RESET_SYSTEM / 4 RESET_RTC | 同上（`RTC_WDT_STG_SEL_*`）                                                     |
| 复位原因编码                     | `0x01`..`0x1A`                                             | `components/soc/esp32s31/include/soc/reset_reasons.h`                           |
| 编码 → `esp_reset_reason_t`      | —                                                          | `components/esp_system/port/soc/esp32s31/reset_reason.c`                        |

`linker/s31.ld` 用 `PROVIDE` 把前三个 ROM 函数接成绝对地址；`PROVIDE` 只在符号
未定义时生效，因此不会覆盖真正的定义。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥5.2）

| 工具    | 版本要求              | 说明                                                                      |
| ------- | --------------------- | ------------------------------------------------------------------------- |
| Zig     | 0.17.1                | 交叉编译 + 链接脚本；`zig version` 必须精确匹配                           |
| ESP-IDF | v6.1                  | 目标 `esp32s31` 为 preview target；提供二级 bootloader、esptool、binutils |
| esptool | >= 5.2                | `elf2image`、`image-info`、`write-flash`；随 IDF 安装，也可单独安装       |
| 目标板  | ESP32-S31 CoreBoard-1 | ESP32-S31-WROOM-3（N16R16V）                                              |
| 主机    | Linux 或 Windows      | Windows 用 IDF 的 PowerShell 导出脚本；`tools/flash.sh` 用 Git Bash/MSYS2 |

构建前让 `esptool` 与 `riscv32-esp-elf-*` 进入 `PATH`：

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh

# Windows PowerShell
. $env:IDF_PATH\export.ps1
```

## 构建

### 1. 应用 ELF（纯 Zig，无 idf.py）

```bash
cd practice/zig-esp32-s31/ch05-clock-reset-wdt

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

产物是 `zig-out/bin/app.elf`。`build.zig` 只做三件事：解析 `-Dtarget`/`-Dcpu`/
`-Doptimize`、`setLinkerScript(b.path("linker/s31.ld"))`、把可执行文件安装成
`app.elf`。这段命令里**没有** `idf.py`。

### 2. 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`--flash-mode dio`/`--flash-size 16MB`/`--flash-freq 80m` 必须与模组一致；它们同时
决定镜像头里与 `esp_app_desc_t` 配套的 `spi_flash_mode`（2 = DIO）。

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

`idf-bootstrap` 不链接任何 Zig 代码，`app_main.c` 是空实现；它的应用镜像会被
`tools/flash.sh` 丢弃并替换。

## 运行

```bash
# Linux
sh tools/flash.sh /dev/ttyUSB0

# Windows（Git Bash / MSYS2）
sh tools/flash.sh COM7
```

脚本做三件事：

1. 读 `idf-bootstrap/build/flash_args`，保留 `--flash_mode`/`--flash_freq`/`--flash_size`
   等选项行与 bootloader、partition-table 两行（**偏移一律不手抄**）；
2. 丢掉 `flash_args` 里 `0x10000` 那一行（IDF 自己的应用），替换成
   `0x10000 <app.bin 的绝对路径>`；
3. `cd` 到 `flash_args` 所在目录执行
   `esptool --chip esp32s31 -p <PORT> -b 921600 write-flash @<临时args>`——
   因为 `flash_args` 里的 bootloader/partition-table 路径是相对该目录的。

烧录后看日志（115200 8N1，UART0）：

```bash
# Linux
python -m serial.tools.miniterm /dev/ttyUSB0 115200
```

### 输出形态（验收目标，不是已获得的日志）

```text
=== ch05-clock-reset-wdt ===
reset reason: code=1 (CHIP_POWER_ON, ESP_RST_POWERON)
  meaning: 上电或复位键，属于冷启动
clock: cycles=<约 6400 万> ticks=<约 320 万> (window 200000 us) -> CPU 320 MHz
  expect 320 (CPLL) on this board; 40 means XTAL-only boot
rwdt: en=<0 或 1> flashboot=<0 或 1> stg0=<n> stg1=<n> stg2=<n> stg3=<n> hold=<n>
tick 1 at <n> us
tick 2 at <n+500000 左右> us
```

`<...>` 都是待真机回填的占位。`cycles` 与 `ticks` 是原始读数，`-> CPU 320 MHz`
是换算结果；两者的比例必须自洽（`cycles / (ticks/16)` 约等于打印出的 MHz）。

## 证据与超时实验

### 1. 三行必看的读数

| 读数                    | 说明                                                                       |
| ----------------------- | -------------------------------------------------------------------------- |
| `reset reason: code=1`  | 冷启动（RST 键/上电）。若这里是 `0x09`/`0x0D`/`0x10`，说明上一轮被狗咬了   |
| `-> CPU 320 MHz`        | 与 CPLL 一致。若是 `40 MHz`，说明 CPU 停在 XTAL（bootloader 切频失败回退） |
| `rwdt: en=... hold=...` | bootloader 留下的现场；`en=1` 时应用必须自己喂狗                           |

### 2. 超时实验（可选，待真机验证）

把 `src/main.zig` 里的

```zig
const demo_timeout_ticks: u32 = 0;
```

改成非 0 值（RWDT 的 tick 来自 RTC_SLOW_CLK，默认 RC_SLOW 标称约 136 kHz，
3 秒约 `408_000`），重新构建烧录。应用会打印 `DEMO: rwdt armed ...`，随后**停止喂狗**
并继续打印 tick；到点后被 RWDT 复位，串口重新出现 banner，这一次的
`reset reason:` 会落在 `0x09`/`0x0D`/`0x10` 之一（具体取决于 stage0 动作与
PROCPU/APPCPU 复位使能位）。

注意两点：

- STG0 的 hold 在硅片内部还会按 2^(1 + eFuse 的 `WDT_DELAY_SEL`) 放大（见
  `rwdt_ll.h` 的 `rwdt_ll_config_stage`，它在写入前先右移），本工程的
  `armSystemReset` 写的是原始 tick 数，所以实际超时**只会比换算值长**；
  精确标定要用秒表回填；
- 实验做完立刻改回 `0`，否则设备每几秒复位一次。

### 3. 主机侧自检

```bash
riscv32-esp-elf-nm zig-out/bin/app.elf | grep -E ' main$| _start$'
riscv32-esp-elf-nm zig-out/bin/app.elf | grep rtc_get_reset_reason   # 应出现 0x2f800018
od -A x -t x1z -j 32 -N 4 zig-out/bin/app.bin                        # 32 54 cd ab
```

## 已知边界

1. **不写 PLL。** 时钟由二级 bootloader 配置；本工程只测量。自己切 CPU 时钟要
   “切 XTAL → 配 PLL → 等锁定 → 切回”，且切频期间不能在 flash cache 里跑代码，
   属于后续章节（或永远交给 bootloader）。
2. **只操作 RWDT。** MWDT0/1 与 SWD 在章节里讲语义，代码不碰。IDF 把 task WDT
   挂在 MWDT0、interrupt WDT 挂在 MWDT1；本章的应用不注册任何 IDF 组件，所以
   它们的状态完全由 bootloader 决定。
3. **复位原因没有 hint。** `ESP_RST_PANIC`/`ESP_RST_TASK_WDT` 这类值是软件在复位前
   写进 RTC 域的 hint 后叠加上去的；本章没有 panic handler，读到的是硬件原始编码。
   ch06 把 panic handler 写出来之后 hint 才有意义。
4. **`mcycle` 只读低 32 位。** 320 MHz 下 13.4 秒回绕，200 ms 窗口有 67 倍余量。
   要长时间积分必须读 `mcycleh`。
5. **SYSTIMER 的 `us()` 会回绕。** 返回 `u32`，16 MHz 下约 71 分钟回绕；`tick N at
<us> us` 里看到的数在长时间运行后会变小，这是预期行为，不是 bug。
6. **`0x2F000000` 与二级 bootloader 的重叠风险**（与 ch04 相同）：若真机表现为
   “烧录成功但立刻重启、没有任何应用输出”，先核对 IDF 的 `esp32s31` bootloader
   链接脚本里 loader 段的结束地址，再把 `sram` 的 `ORIGIN` 抬上去。

## 排障

| 环境 | 现象                                         | 根因                                              | 处置                                                                            |
| ---- | -------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------- |
| 构建 | `undefined symbol: rtc_get_reset_reason`     | `PROVIDE` 没被看到：链接脚本没生效                | 确认 `setLinkerScript` 指向 `linker/s31.ld`；`nm` 看符号是否 `0x2f800018`       |
| 构建 | `undefined symbol: main`                     | `main` 没 export，或被改名成 `main.main`          | 用 `pub export fn main`；保留 `start.zig` 里的 `_ = &app.main;`                 |
| 构建 | `error: expected type 'c_uint'` 一类变参报错 | ROM printf 是 C 变参，Zig 不做默认实参提升        | 每个整数显式 `@as(c_uint, x)`；字符串用 `[:0]const u8`                          |
| 运行 | 数字/字符串错位                              | 变参类型不对（传了 `u64`/`usize`）                | 同上；只用 32 位整数打印                                                        |
| 运行 | `-> CPU 40 MHz`                              | CPU 停在 XTAL：bootloader 没切到 CPLL             | 看 bootloader 日志；核对 `idf-bootstrap` 的 sdkconfig 与目标芯片                |
| 运行 | `-> CPU 0 MHz`                               | `ticks` 没变：SYSTIMER 未运行或快照轮询死循环     | 单独打印两次 `ticks()` 的差值；确认 `CONF` 是置位而不是赋值                     |
| 运行 | 每几秒重启，复位原因 `0x09`/`0x0D`/`0x10`    | RWDT 超时：应用没喂狗，或喂狗被写保护挡掉         | 确认循环里 `wdt.feed()` 被执行；`feed()` 内部必须 unlock → 写 → lock            |
| 运行 | 喂狗写了但没生效                             | 没解锁就写 `FEED`（写保护静默丢弃，读回仍是旧值） | 三段式；可读回 `WPROTECT` 确认                                                  |
| 运行 | 复位原因总是 `0x03`/`0x0C`                   | 有人在软件复位（含 JTAG 下载后的复位）            | 用 RST 键冷启动再看；USB Serial/JTAG 的复位会记成 `0x16`/`0x17`                 |
| 烧录 | `flash.sh` 报找不到 `flash_args`             | `idf-bootstrap` 没构建                            | 进 `idf-bootstrap/` 执行 `idf.py --preview set-target esp32s31 && idf.py build` |
| 烧录 | `flash.sh` 报“没有 0x10000 的应用行”         | 分区表不是 single-app-large                       | 确认 `sdkconfig.defaults`；删 `idf-bootstrap/sdkconfig` 后重新 `set-target`     |
| 烧录 | `esptool` 连不上                             | 没进下载模式                                      | 按住 BOOT（GPIO61）再按 RST                                                     |
| 串口 | 无输出或乱码                                 | 端口/波特率错，或 bootloader 阶段就失败           | 换 UART0（GPIO58/59）115200 8N1；先确认 ch04 的镜像能出 `hello form B`          |

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 产出 `zig-out/bin/app.elf`
- [ ] `nm` 中 `_start`/`main` 存在，`rtc_get_reset_reason` 解析为 `0x2f800018`
- [ ] `elf2image` + `image-info` 通过（entry、段、校验、SHA256 均有效）
- [ ] `idf-bootstrap` 在 `--preview` 下产出 bootloader、分区表与 `flash_args`
- [ ] `tools/flash.sh` 替换应用行后一次烧录成功
- [ ] 冷启动打印 `code=1 (CHIP_POWER_ON, ESP_RST_POWERON)`
- [ ] `-> CPU 320 MHz`，且 `cycles/(ticks/16)` 与打印的 MHz 自洽
- [ ] `rwdt:` 行六个字段可读，连续 `tick N` 十秒不中断
- [ ] 超时实验（`demo_timeout_ticks != 0`）能复位，且下次启动的复位原因落在 `0x09`/`0x0D`/`0x10`
- [ ] 实验改回 `0` 后恢复长期稳定运行
- [ ] `run.log` 回填：真机串口原始输出（当前状态：**run.log 待真机回填**）
