# ch04 linker layout：自有链接脚本与 `_start`

> 所属章节：[[ch04-linker-memory-layout|第四章：链接脚本与内存布局]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是系列的第一个**形态 B** 工程：Zig 自己产出 ELF，链接布局由本工程的
`linker/s31.ld` 决定，入口是自写的 `_start`，镜像由 `esptool elf2image` 生成。
ESP-IDF 在这条链里只剩一个角色——二级 bootloader 与分区表的供应商
（`idf-bootstrap/`），应用构建链里没有任何 `idf.py`、CMake 或 IDF 组件。

工程只做一件事：在 UART0 打印一次 `hello form B`，之后每秒一行 `tick B`。
它验证的不是外设，而是五件事：

1. 链接脚本把 `.text/.rodata/.data/.bss` 全部放进 SRAM，第一个装载段以
   256 字节的 `esp_app_desc_t` 开头，`_text_start` 紧随其后（`0x2F000100`）；
   `_start` 在 `.text` 内，具体地址以 `nm -n` 为准；
2. `_start` 能设好栈、清掉 `.bss`、跳到 Zig 的 `main`；
3. `elf2image` 产出的镜像头 entry 字段等于 `_start` 地址；
4. 二级 bootloader 认得出第一段里的 IDF 应用描述（魔数 `0xABCD5432`）；
5. 二级 bootloader 愿意把镜像搬到 SRAM 并跳进来。

> [!warning] 验证状态
> **已实测（2026-11-13）**：`hello form B` + 每秒 `tick B`，连跑 14 s 无复位；
> 镜像含 IROM/DROM 两个 flash 段（`0x40000020` / `0x40020020`），原始输出见 `../logs/ch04-boot.log`。

## 硬件与接线

| 项       | 事实                                                        |
| -------- | ----------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                              |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM     |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1               |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位          |
| USB      | USB-to-UART（烧录/日志）与 USB Serial/JTAG（调试）各一路    |
| 本章外设 | 不驱动 GPIO60 的可寻址 RGB LED；只用 UART0 文本作为可观测量 |

接线只要两根 USB-C：一根供电，一根接 USB-to-UART 口。没有外部器件、没有杜邦线。

## 段布局与链接脚本符号

`linker/s31.ld` 把全部段放在唯一的 `sram` 区域（`0x2F000000 .. 0x2F07AFC0`，
长度 `0x7AFC0`），因此本工程的 LMA（装载地址）与 VMA（运行地址）相同：

| 段          | 属性           | 位置                        | 说明                                       |
| ----------- | -------------- | --------------------------- | ------------------------------------------ |
| `.app_desc` | 只读           | `0x2F000000` 起，256 字节   | `esp_app_desc_t`，第一个装载段必须以它开头 |
| `.text`     | 只读/可执行    | `0x2F000100` 起             | 含 `_start` 与 Zig 生成的代码、`.rodata`   |
| `.data`     | 读写           | 紧接 `.text`（16 字节对齐） | 有初值的全局变量；LMA == VMA               |
| `.bss`      | 读写，`NOLOAD` | 紧接 `.data`                | 镜像里没有内容，由 `_start` 清零           |
| 栈          | 读写           | 从 `_stack_top` 向下增长    | 栈顶 = `0x2F07AFC0`                        |

### 为什么非 IDF 镜像也要带 `esp_app_desc_t`

IDF 的二级 bootloader 对第一个装载段有硬要求：段首必须是 256 字节的
`esp_app_desc_t`（魔数 `0xABCD5432`）。这是无条件的，与“应用是不是 IDF 编译的”
无关：

- 段处理路径在 `SOC_MMU_PAGE_SIZE_CONFIGURABLE` 下要读魔数与 `mmu_page_size`
  决定映射页大小，读不到会报 `Failed to fetch app description header!`；
- `bootloader_common_check_efuse_blk_validity` 读同一份描述里的
  `min/max_efuse_blk_rev_full`，判断 eFuse 块版本是否兼容；
- `process_esp_app_desc_data` 的魔数断言是另一条（防回滚）路径。

因此 `src/start.zig` 里用 `export const app_desc: AppDesc linksection(".app_desc")`
提供这 256 字节，`linker/s31.ld` 用 `KEEP(*(.app_desc))` 把它放在 `.text` 的最前面，
`@sizeOf(AppDesc) == 256` 与各关键偏移由 comptime 断言守住。字段与 elf2image 参数
必须一致：`mmu_page_size = 16`（log2 64 KiB）、`spi_flash_mode = 2`（DIO）。
`app_elf_sha256` 暂填零——本章不启用安全启动与回滚，需要时再回填。

链接脚本对外提供的符号：

| 符号                                  | 含义                                            | 谁用                      |
| ------------------------------------- | ----------------------------------------------- | ------------------------- |
| `_start`（`ENTRY`）                   | ELF 入口，写入镜像头的 entry 字段               | bootloader                |
| `_image_start`                        | 第一个装载段的起点，即 `.app_desc` 的地址       | 地图核对                  |
| `_stack_top`                          | 初始 `sp`，SRAM 末尾，16 字节对齐               | `_start` 第 2 步          |
| `_bss_start` / `_bss_end`             | `.bss` 区间，`_start` 逐字清零                  | `_start` 第 3 步          |
| `_data_start` / `_data_end`           | `.data` 的运行区间（VMA）                       | 校验 / 后续 flash 布局    |
| `_data_load_start` / `_data_load_end` | `.data` 的装载区间（LMA）；本布局与 VMA 相同    | 后续 flash 布局的搬运循环 |
| `_text_start` / `_text_end`           | 代码与只读数据区间                              | 地图核对                  |
| `_heap_start`                         | 堆起点，等于 `_bss_end`                         | 后续章节                  |
| `esp_rom_printf`                      | `PROVIDE` 到 `0x2f800024`（ROM `ets_printf`）   | `src/main.zig`            |
| `esp_rom_delay_us`                    | `PROVIDE` 到 `0x2f80003c`（ROM `ets_delay_us`） | `src/main.zig`            |

## 文件表

| 路径                                | 角色                                                                                            | 代码浏览                                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `build.zig`                         | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                                            | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/build.zig)                         |
| `linker/s31.ld`                     | `ENTRY(_start)`、`MEMORY`、`.app_desc` 先于代码、栈/`.bss`/`.data` 符号、ROM 别名               | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/linker/s31.ld)                     |
| `src/start.zig`                     | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → 设 sp/gp → 清 `.bss` → 跳 `main` → `wfi` | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/src/start.zig)                     |
| `src/main.zig`                      | `pub export fn main`：打印 `hello form B`，之后每秒 `tick B`                                    | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/src/main.zig)                      |
| `idf-bootstrap/CMakeLists.txt`      | 最小 IDF 工程根：只为产出 bootloader 与分区表                                                   | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | `main` 组件注册，只有一个空 `app_main.c`                                                        | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | 空 `app_main`，永不被执行；只为让 IDF 构建走完                                                  | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | 16 MB Flash + single-app-large（factory 应用槽在 `0x10000`）                                    | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                                  | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/tools/flash.sh)                    |
| `README.md`                         | 本文件                                                                                          | [查看](/static/code/#/zig-esp32-s31/ch04-linker-layout/README.md)                         |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置的
single-app-large 分区表）、没有 `components/`（不链接任何 IDF 组件）、没有
`run.log`（真机未跑）。生成物 `zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、
`idf-bootstrap/sdkconfig` 都不入库。

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

Zig 只需解压后加入 `PATH`，不依赖 IDF 的 Python 环境。目标能力可用下面的命令自证
（本系列在 Zig 0.17.1 下实测过；本工程不重复执行）：

```bash
zig build-lib --show-builtin \
  -target riscv32-freestanding-eabihf \
  -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei
```

## 构建

### 1. 应用 ELF（纯 Zig，无 idf.py）

```bash
cd practice/zig-esp32-s31/ch04-linker-layout

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

产物是 `zig-out/bin/app.elf`。`build.zig` 里只有三件事：解析 `-Dtarget`/`-Dcpu`/
`-Doptimize`、`setLinkerScript(b.path("linker/s31.ld"))`、把可执行文件安装成
`app.elf`。这一段命令里**没有** `idf.py`，CI 会用 grep 断言这一点。

### 2. 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`elf2image` 读 ELF 的入口地址与 `PT_LOAD` 段表：entry 来自 `ENTRY(_start)`，
段来自 `.text`（只读/可执行）与 `.data`（读写），`.bss` 因为 `NOLOAD` 不占镜像字节。
`--flash-mode dio`/`--flash-size 16MB`/`--flash-freq 80m` 必须与模组一致。

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

`idf-bootstrap` 不链接任何 Zig 代码，`app_main.c` 是空实现。它的应用镜像会被
`tools/flash.sh` 丢弃并替换——烧进 `0x10000` 的是 `zig-out/bin/app.bin`。

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
   `0x10000 <app.bin 的绝对路径>`（脚本会先把相对路径锚成绝对路径）；
3. 执行 `esptool --chip esp32s31 -p <PORT> -b 921600 write-flash @<临时args>`。
   `flash_args` 里的 bootloader/partition-table 路径相对其 build 目录，脚本会先把
   `app.bin` 锚成绝对路径，再 `cd` 到该 build 目录执行 esptool。

烧录后看日志（115200 8N1，UART0）：

```bash
# Linux
python -m serial.tools.miniterm /dev/ttyUSB0 115200
# 或直接用任意串口工具；监视器的选择不影响应用输出
```

二级 bootloader 会先打印自己的启动日志（版本、Flash 模式与大小、分区表、镜像校验，
随 IDF 版本变化），随后跳到 `_start`。应用侧的目标形态是：

```text
hello form B
tick B
tick B
tick B
```

> [!note] 以上是**验收目标**，不是已获得的输出。`hello form B` 必须恰好一次且在
> `tick B` 之前，之后约每秒一行。`tick B` 的节奏由 ROM 忙等延时决定，不做毫秒级断言。

## 真实输出

**已实测（2026-11-13）**：`hello form B` + 每秒 `tick B`（原始输出 `../logs/ch04-boot.log`）。本工程未在本仓保留 `run.log`，
构建；README 不贴预期日志冒充实测。真机跑通后，把 UART0 的原始输出存为 `run.log`，
写清日期与板卡序列号，并用真实片段替换上面那一节的“目标形态”。

## 已知边界与排障

### 1. `0x2F000000` 与二级 bootloader 的重叠风险

本工程按章节要求把应用起点钉在 SRAM 基址 `0x2F000000`。但二级 bootloader 跳转时
自己仍在 SRAM 里运行（它要先搬段、再跳转），低端 SRAM 很可能被它占着。若真机上
表现为“烧录成功但立刻重启、串口没有任何应用输出”，第一件事是核对 IDF 的
`esp32s31` bootloader 链接脚本里 loader 段的结束地址，把 `sram` 的 `ORIGIN`
（或 `.text` 的起点）抬到它之上再重试。**这一点必须用真机验证，不要凭本文断言。**

### 2. `main` 的符号名与呼叫约定

`_start` 里的 `call main` 是汇编字符串，Zig 的引用图看不见它。两道保险：

- `src/main.zig` 用 `pub export fn main`，符号名就是 `main`（`pub fn` 会被改成
  `main.main` 一类，链接期报 `undefined symbol: main`）；
- `src/start.zig` 在 `comptime` 块里 `_ = &app.main;`，强制把 `main` 分析进目标文件。

### 3. 栈与 `.bss` 的边界

`_stack_top` 固定在 SRAM 末尾，`.bss` 从 `.text` 之后向上长。本章的应用只有几十字节
静态数据，够用；一旦 `.bss` 长到接近 `_stack_top`，栈会踩进 `.bss`。核对办法：
`riscv32-esp-elf-nm -n zig-out/bin/app.elf | grep -E '_bss_end|_stack_top'`，
两者之差就是栈 + 堆的余量。后续章节会把栈显式切成任务栈。

### 4. 排障表

| 环境 | 现象                                                                   | 根因                                                          | 处置                                                                             |
| ---- | ---------------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| 构建 | `undefined symbol: main`                                               | `main` 没 export，或被改成 `main.main` 一类符号               | 用 `pub export fn main`；`nm` 确认符号名是 `main`                                |
| 构建 | `undefined symbol: esp_rom_printf`                                     | 链接脚本没生效，`PROVIDE` 没被解析                            | 确认 `setLinkerScript` 指到 `linker/s31.ld`；`nm` 看符号是否为绝对地址           |
| 构建 | `build.zig` API 报错                                                   | Zig 不是 0.17.1                                               | `zig version` 对齐；删 `.zig-cache/` 重试                                        |
| 构建 | `error: unable to find dynamic system library` 等                      | 漏了 `-Dtarget`/`-Dcpu`，按主机目标编译                       | 用 README 的完整命令；两条 `-D` 都不能省                                         |
| 镜像 | `image-info` 的 entry 不是 `_start` 的地址                             | `ENTRY(_start)` 被删，或用了默认链接脚本                      | `readelf -h` 看 entry，`nm` 找 `_start`，两者必须相等                            |
| 镜像 | `elf2image` 报段地址/对齐错误                                          | 段被改到 flash 窗口但没配 MMU，或脚本里 `. = ALIGN` 缺失      | 回到 SRAM-only 布局；检查 `.text`/`.data` 的 `ALIGN(16)`                         |
| 烧录 | `tools/flash.sh` 报找不到 `flash_args`                                 | `idf-bootstrap` 没构建                                        | 进 `idf-bootstrap/` 执行 `idf.py --preview set-target esp32s31 && idf.py build`  |
| 烧录 | `flash.sh` 报“没有 0x10000 的应用行”                                   | 分区表不是 single-app-large                                   | 确认 `sdkconfig.defaults`；删 `idf-bootstrap/sdkconfig` 后重新 `set-target`      |
| 烧录 | `esptool` 报 `invalid header` / 找不到下载模式                         | 镜像参数与模组不符，或没进下载模式                            | 确认 dio/16MB/80m；按住 BOOT（GPIO61）再复位重试                                 |
| 运行 | 烧录成功但反复重启、无应用输出                                         | 二级 bootloader 与 `0x2F000000` 起的段重叠（见本节第 1 条）   | 抬高应用起点，或先验证 bootloader loader 段的范围                                |
| 运行 | 只有 bootloader 日志，没有 `hello form B`                              | entry 指错、`main` 没被链接、或 `_start` 早期就崩             | 依次查 entry、`nm` 里 `main` 是否为 `T`、反汇编前 20 条指令                      |
| 运行 | bootloader 报 `Failed to fetch app description header!` 或直接拒绝启动 | 第一个装载段不是以 `esp_app_desc_t` 开头（或 256 字节不完整） | 确认 `.app_desc` 在 `KEEP` 的最前面；`xxd -s 32 -l 4 app.bin` 应为 `32 54 cd ab` |
| 运行 | 串口乱码或空                                                           | 端口/波特率不符                                               | 换 UART0 口、115200 8N1；USB Serial/JTAG 口不是 ROM 控制台                       |

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 产出 `zig-out/bin/app.elf`
- [ ] `readelf -h` 的 entry 等于 `nm` 里 `_start` 的地址（`_start` 在 256 字节描述之后）
- [ ] `readelf -l` 里 `.text`/`.data` 两个 `PT_LOAD` 的 VMA 与 LMA 相同
- [ ] `.text` 开头 256 字节是 `esp_app_desc_t`：`xxd -s 32 -l 4 zig-out/bin/app.bin` 输出 `32 54 cd ab`
- [ ] 描述里的 `mmu_page_size = 16`、`spi_flash_mode = 2` 与 `elf2image` 的 `--flash-mode dio` 一致
- [ ] `esptool elf2image` 与 `image-info` 通过（entry、段、校验、SHA256 均有效）
- [ ] `idf-bootstrap` 在 `--preview` 下产出 bootloader、分区表与 `flash_args`
- [ ] `tools/flash.sh` 替换应用行后一次烧录成功
- [ ] 串口出现一次 `hello form B`，之后每秒一行 `tick B`
- [ ] 若出现重启循环，按「已知边界」第 1 条核对 bootloader 与 `0x2F000000` 的重叠
- [ ] `run.log` 回填：真机串口原始输出（当前状态：**run.log 待真机回填**）
