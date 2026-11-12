# Zig × ESP32-S31 实验套件 · 构建规格 v1.1

本文件是 `practice/zig-esp32-s31/` 全部实验工程的实现契约，配套系列为 [[zig-esp32-s31]]。
工程作者动手前必读；章节正文引用的构建产物、镜像字段与串口输出，出处一律是本套件对应
工程的真实构建记录与 `run.log`，本规格不提供任何"预期输出"。

## 1. 定位与目录约定

- **定位**：系列章节的**可构建工程本体**，不是片段代码仓库。每个工程自成一个干净目录，
  README 即文档，复制改名即可作为新项目起点。
- **目录**：`practice/zig-esp32-s31/<工程>/`，工程名 `chNN-<kebab-slug>`，`NN` 两位、与
  章节号一一对应（`ch02-hello`、`ch04-linker-layout`）。模板形态（A/B）不体现在目录名里。
- **只提交源码**：`.zig` / `.c` / `.h` / `CMakeLists.txt` / `sdkconfig.defaults` / 链接脚本 /
  `README.md` / 真实 `run.log`。构建产物、缓存、生成的 `sdkconfig` 一律不入库（§6）。
- **禁止 managed component 在线拉取**：依赖只允许 `${IDF_PATH}` 内的树内组件，或本仓
  相对路径引用；不出现 `idf_component.yml` 的 registry 依赖。形态 B 的工程根本不含
  `components/`，只把 IDF 当"二级 bootloader 与分区表的供应商"。
- **不 vendored IDF**：不复制 `esp-idf` 源码树进仓库；需要引用 IDF 定义时，在注释里写
  `IDF_PATH/components/...` 的文件路径，不复制文件。

章节映射（本规格只锁定 ch02 的完整契约，其余按本规格的命名与模板规则落地）：

| 章    | 工程目录              | 模板 | 产物                                                          |
| ----- | --------------------- | ---- | ------------------------------------------------------------- |
| 1     | `ch01-board-id/`      | 无   | 芯片/Flash 鉴定命令清单、16 MB 备份、风险清单                 |
| 2     | `ch02-hello/`         | A    | `hello s31` + 每秒一行 `tick` 的 UART0 输出                   |
| 3     | `ch03-image-inspect/` | 主机 | 镜像头解析器（Zig 主机程序）+ `image-info` 对照               |
| 4     | `ch04-linker-layout/` | B    | 自有链接脚本 + `_start` + 可启动镜像                          |
| 5–6   | `ch05-*`、`ch06-*`    | B    | 时钟/WDT；GPIO bank0/UART/日志/panic；WS2812/RMT 只做边界论证 |
| 7–15  | `chNN-*`              | B    | CLIC、定时器、Flash、Zig RTOS 各章                            |
| 16–28 | `chNN-*`              | B    | 网络底座、TCP/IP、应用、Wi-Fi blob 边界                       |

> [!note] 模板 A 是脚手架
> A 只用于 ch02：它证明"Zig 能产出可被 IDF 链接的 RISC-V 目标文件、能导出 `app_main`"，
> 跑通即弃，不进入长期架构。自 ch04 起主线一律 B，ch05 之后不再新增 A 形态工程。

## 2. 环境硬事实（引用，不重复论证）

### 2.1 工具链版本钉扎

| 工具          | 版本                                     | 作用                                                                      |
| ------------- | ---------------------------------------- | ------------------------------------------------------------------------- |
| Zig           | **0.17.1 stable**                        | 交叉编译、`build.zig`、主机侧单元测试                                     |
| ESP-IDF       | **v6.1（`esp32s31` 为 preview target）** | `esp32s31` 目标支持、二级 bootloader、分区表、esptool；命令带 `--preview` |
| esptool       | **≥ 5.2**（S31 支持）                    | `elf2image`、`image-info`、烧录、全片备份                                 |
| OpenOCD + GDB | IDF v6.1 自带                            | USB Serial/JTAG 调试（ch07 起使用）                                       |
| esp-emu       | Espressif esp-emulator                   | S31 早期冒烟；外设模型不完整，不能替代真机                                |

版本升级的处置见 §10；**不允许**在工程里写 `latest`、`master`、浮动 tag。

### 2.2 已实测的目标串（2026-11-12，Zig 0.17.1）

```bash
zig build-lib --show-builtin \
  -target riscv32-freestanding-eabihf \
  -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei
```

实测结果：`abi = .eabihf`、`arch = .riscv32`、`model = generic_rv32`，特性集含
`m/a/c/f/i/zicsr/zifencei`（以及由它们推导的 `zaamo/zalrsc/zca/zmmul`）；同参数下
`zig build-obj` 成功产出 RISC-V 目标文件。该结论**只覆盖编译**，不代表任何固件在
S31 上运行过。本套件全部工程统一使用这条目标串，写死、不参数化：

```text
-target riscv32-freestanding-eabihf
-mcpu=generic_rv32+m+a+c+f+zicsr+zifencei
```

`eabihf` 是硬浮点 ABI；IDF 侧实际 ABI 不能凭"有 F"推断，以工具链默认 multilib 与
`build/compile_commands.json` 的 `-mabi=` 为准（S31 Linux 移植文档里 kernel/radio 用
`ilp32f`、用户态用 `ilp32`，同一颗芯片可以并存两种 ABI）。链接 IDF 的 C 侧 blob 或 GCC
目标文件时，浮点参数传递必须逐项核对（ch04 起用 `readelf -A` 对照 `.riscv.attributes`）。

### 2.3 芯片与板卡

| 项       | 事实                                                                           |
| -------- | ------------------------------------------------------------------------------ |
| CPU      | 双核 32 位 RISC-V，最高 320 MHz，RV32IMAF C（单精度 F，无 D）                  |
| 存储     | 512 KB SRAM、320 KB ROM、32 KB LP SRAM；模块 16 MB Flash + 16 MB PSRAM         |
| 中断     | 每核 CLIC 48 路输入、8 个优先级；169 个中断矩阵源；4 个软件中断                |
| 无线     | Wi-Fi 6 1T1R、BT 5.4、802.15.4（射频与 MAC 为厂商 blob）                       |
| 有线     | 1G Ethernet MAC + RGMII（板载 RJ45），无 blob，是本套件的诚实对照路径          |
| 板卡     | ESP32-S31-Function-CoreBoard-1（模块 ESP32-S31-WROOM-3）                       |
| 板载接口 | 千兆 RJ45、USB HS OTG、USB Serial/JTAG、ES8311 codec、可寻址 RGB LED（GPIO60） |
| 引脚     | UART0 = GPIO58(TX)/GPIO59(RX)；BOOT = GPIO61；RGB LED 数据线 = GPIO60          |

> [!warning] RGB LED 不是普通 GPIO
> GPIO60 上挂的是单线可寻址灯珠（WS2812 类），需要 RMT/精确时序驱动，**ch02 不点灯**。
> ch02 的唯一可观测量是 UART0 文本输出；ch06 只做 GPIO bank0/UART 与 WS2812/RMT 边界论证，真正驱动可寻址灯珠留到 RMT/精确定时章节。

### 2.4 镜像格式（形态 B 的唯一判据）

`esptool elf2image` 产出的应用镜像由五段组成：

| 段       | 长度    | 内容                                                              |
| -------- | ------- | ----------------------------------------------------------------- |
| 头       | 8 字节  | `0xE9` 魔数、段数、SPI 模式、SPI 速度/大小、入口地址（LE）        |
| 扩展头   | 16 字节 | WP 引脚、驱动强度、芯片 ID、最低芯片版本、保留位、是否追加 SHA256 |
| 段       | 变长    | 每段 8 字节头（加载地址、长度，LE）+ 数据                         |
| 校验     | 1 字节  | 段数据按 `0xEF` 初值逐字节异或，补齐到 16 字节边界后写入          |
| 校验摘要 | 32 字节 | 可选 SHA256（IDF 默认追加）                                       |

`esptool image-info <bin>` 是这段格式的**验收工具**：段表、入口地址、校验和与 SHA256
必须全部为 valid。ch03 的手写解析器输出必须与它逐字段对齐。

### 2.5 Wi-Fi 边界（只声明，不实现）

`libnet80211` / `libpp` / `libphy` 等厂商二进制依赖 FreeRTOS 与 IDF API 面
（`esp_adapter.c` 一类适配层），**不能**直接跑在裸 Zig 运行时上。本套件在 ch25 之前
不链接任何射频二进制；纯 Zig 路径的网络验证一律走板载千兆以太网。

## 3. 两种模板

### 3.1 模板 A：IDF 托管的 Zig 静态库（ch02）

Zig 编出静态库，IDF 的 CMake 工程负责链接、分区、烧录。IDF 提供启动代码与二级
bootloader，Zig 只提供 `app_main`。

文件清单（顺序即构建依赖顺序）：

| 路径                  | 角色                                                                  |
| --------------------- | --------------------------------------------------------------------- |
| `CMakeLists.txt`      | IDF 工程根：引入 `project.cmake`、`project(zig_s31_hello)`            |
| `sdkconfig.defaults`  | 16 MB Flash + single-app-large 分区表（目标芯片由 `set-target` 生成） |
| `build.zig`           | Zig 侧：`standardTargetOptions` + 静态库 `main_zig`                   |
| `main/CMakeLists.txt` | 查找 Zig、自定义命令、顺序依赖、把 `libmain_zig.a` 挂到组件上         |
| `main/main.zig`       | `export fn app_main`：打印 `hello s31`，之后每秒一行 `tick`           |
| `main/idf_anchor.c`   | 组件锚点：让 `main` 组件有 C 源文件，并提供稳定的 C/Zig 交界点        |
| `README.md`           | 中文：目的、文件表、构建、运行、真实输出、边界                        |

构建流程（路径与产物名即工程实际形态）：

```text
idf.py --preview set-target esp32s31   # v6.1 preview target；转正后可省略
  └─ idf.py build
       ├─ [custom command] zig build -Dtarget=riscv32-freestanding-eabihf
       │        -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
       │        --prefix <build>/main/zig-out
       │     └─ <build>/main/zig-out/lib/libmain_zig.a
       ├─ IDF 编译 main/idf_anchor.c → libmain.a
       └─ 链接：libmain.a + libmain_zig.a + IDF 组件 → <build>/zig_s31_hello.elf / .bin
```

`esp32s31` 在 IDF v6.1 是 **preview target**，`set-target` / `list-targets` 必须带
`--preview`（`--preview` 是 `idf.py` 全局选项，放在子命令之前）；本仓
`practice/onvif-labs` 的 S31 实机基线同样使用该写法。v6.1 正式版转正后可省略。

根 `CMakeLists.txt` 只声明"这是一个 IDF 工程"，Zig 的查找与集成交给
`main/CMakeLists.txt`：

```cmake
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(zig_s31_hello)
```

`main/CMakeLists.txt` 是模板 A 的核心，四条不变量缺一不可：`zig build` 在工程根目录
执行（`build.zig` 在那里）、静态库先产出再链接、`--prefix` 与链接路径逐字符一致、
`.a` 通过 `INTERFACE` 挂到组件上：

```cmake
find_program(ZIG_EXECUTABLE zig REQUIRED)

set(ZIG_OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/zig-out")
set(ZIG_LIB "${ZIG_OUT_DIR}/lib/libmain_zig.a")

idf_component_register(SRCS "idf_anchor.c" INCLUDE_DIRS ".")

add_custom_command(
    OUTPUT "${ZIG_LIB}"
    COMMAND "${ZIG_EXECUTABLE}" build
            -Dtarget=riscv32-freestanding-eabihf
            -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei
            -Doptimize=ReleaseSmall
            --prefix "${ZIG_OUT_DIR}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/../build.zig"
        "${CMAKE_CURRENT_SOURCE_DIR}/main.zig"
    COMMENT "zig build: libmain_zig.a (riscv32-freestanding-eabihf)"
    VERBATIM
)

add_custom_target(zig_main ALL DEPENDS "${ZIG_LIB}")

add_dependencies(${COMPONENT_LIB} zig_main)

target_link_libraries(${COMPONENT_LIB} INTERFACE "${ZIG_LIB}")
```

`build.zig` 用标准选项接住 CMake 传下来的三个 `-D`，不自定义参数：

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "main_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(lib);
}
```

`idf_anchor.c` 不定义 `app_main`，也不制造对它的引用：IDF 的启动代码本身引用
`app_main`，链接器因此会从 `libmain_zig.a` 里取出对应目标文件。锚点只保证组件存在：

```c
/* main/idf_anchor.c
 * 1) main 组件必须至少有一个 C 源文件，IDF 才生成组件静态库；
 * 2) 给后续章节留一个稳定的 C/Zig 交界点（中断入口、链接脚本符号、头文件封装）。 */

void zig_s31_anchor(void);

void zig_s31_anchor(void)
{
}
```

若最终链接报 `undefined reference to 'app_main'`，先查 `libmain_zig.a` 是否真的进了
链接集合（`nm` 看 `app_main` 是否为 `T`），不要去改锚点。

### 3.2 模板 B：纯 Zig ELF + `esptool elf2image` + IDF 二级 bootloader（ch04 起）

Zig 自己产出 ELF（自有链接脚本、自有 `_start`），`esptool` 把它转成 ROM 能加载的应用
镜像；启动链上只有二级 bootloader 来自 IDF。

文件清单：

| 路径             | 角色                                                                 |
| ---------------- | -------------------------------------------------------------------- |
| `build.zig`      | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                 |
| `linker/s31.ld`  | 段布局与入口 `ENTRY(_start)`；区间抄自 IDF 的 `esp32s31` 链接脚本    |
| `src/start.zig`  | `_start`：设栈、清 `.bss`、拷 `.data`、跳 `main`                     |
| `src/main.zig`   | 章节实验主体（ch04 起是裸机代码，不用 `std.os`）                     |
| `idf-bootstrap/` | 最小 IDF 工程，**只为**产出 `bootloader.bin` / 分区表 / `flash_args` |
| `tools/flash.sh` | 读 `flash_args`、替换 app 行、按偏移烧录（偏移不手抄）               |
| `README.md`      | 中文：段布局表、构建/烧录命令、真实输出、边界                        |

`idf-bootstrap/` 内部只有三个文件：根 `CMakeLists.txt`、`main/CMakeLists.txt`、
`main/app_main.c`（空实现，`void app_main(void) {}`）。它**不链接任何 Zig 代码**，只
让 `idf.py build` 顺带产出二级 bootloader、分区表与 `flash_args`；其 `build/` 不入库。

构建流程：

```text
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
  └─ zig-out/bin/app.elf
       └─ esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
            --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
            └─ esptool --chip esp32s31 image-info zig-out/bin/app.bin   # 字段验收
                 └─ tools/flash.sh   # bootloader + 分区表 + app
```

链接脚本的硬约束（只约束"必须有什么"，不写死地址）：

- `ENTRY(_start)`，且 `readelf -h app.elf` 的 `Entry point address` 等于 `_start` 符号地址；
- 定义 `_stack_top`、`_bss_start/_bss_end`、`_data_load_start/_data_start/_data_end`，
  `_start` 只依赖这些符号，不依赖硬编码常量；
- 区分"Flash 期间可执行"的 IRAM 段与"经 cache 取指"的 flash 段，命名与 IDF 的
  `esp32s31` 链接脚本一致，便于对照；
- 具体区间（DRAM/IROM/DROM 基址）**必须**抄自 `IDF_PATH/components/esp_system/ld/`
  下 `esp32s31` 的链接脚本，并在注释里写明来源文件与行号；本规格不复制这些地址，
  避免与 pre-release 手册不一致时两处都要改。

`_start` 的职责按顺序固定为五步：关全局中断 → `sp = _stack_top` → 清 `.bss` →
从 Flash 拷 `.data` → `call main`；`main` 返回后进 `wfi` 死循环（裸机程序没有"退出"）。

`elf2image` 的参数必须与板卡的 16 MB Flash 匹配，写死在 `tools/flash.sh` 里而不是
让使用者临场填：

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf
```

## 4. `ch02-hello` 工程契约（模板 A；ch03–ch11 见 §4.5–§4.13）

### 4.1 文件与职责

根目录 `practice/zig-esp32-s31/ch02-hello/`，**恰好**这七个文件，不多不少：

```text
ch02-hello/
├── CMakeLists.txt        # IDF 工程根（§3.1 片段）
├── sdkconfig.defaults    # 16 MB Flash + single-app-large 分区表
├── build.zig             # 静态库 main_zig
├── main/
│   ├── CMakeLists.txt    # 自定义命令 + 顺序依赖 + 链接
│   ├── main.zig          # app_main
│   └── idf_anchor.c      # 组件锚点
└── README.md
```

无 `build.zig.zon`（零 Zig 依赖），无 `run.log`（真机未跑，README 写"run.log 待真机
回填"），无 `partitions.csv`（用 IDF 的 single-app-large 内置分区表）。

`sdkconfig.defaults` 只钉两件与"镜像能否装下、能否正确烧录"直接相关的事——模组是
16 MB Flash，应用分区用 single-app-large；其余保持 IDF 默认（含 115200 的 UART0 控制台）：

```ini
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_ESPTOOLPY_FLASHSIZE="16MB"

CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=y
```

目标芯片不写在这里：`idf.py --preview set-target esp32s31` 会把目标写进生成的 `sdkconfig`
（生成物，不入库）。`sdkconfig.defaults` 只在生成 `sdkconfig` 时生效，改完必须删掉
旧 `sdkconfig` 或走 `menuconfig` 重新确认。

已知边界（README 必须写明）：`esp_rom_printf` 写的是**ROM 控制台**，不受 IDF 的
console Kconfig 影响，恒定 UART0（GPIO58/59）；若只接了 USB Serial/JTAG 口，IDF 自己
的日志跟着 console 配置走，而 `hello s31` 仍只在 UART0 出现——此时应改用 UART0 桥接
口，而不是去改 Zig 代码。

### 4.2 `main/main.zig` 的行为契约

```zig
// main/main.zig —— 形态 A 的最小可烧录应用
const builtin = @import("builtin");

comptime {
    // 目标错了就立刻失败，而不是产出一个"能编译但不能跑"的库
    if (builtin.cpu.arch != .riscv32) @compileError("ch02-hello 必须交叉编译到 riscv32");
    if (builtin.abi != .eabihf) @compileError("ch02-hello 需要 eabihf（硬浮点）ABI");
}

extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
extern fn esp_rom_delay_us(us: u32) void;

export fn app_main() void {
    _ = esp_rom_printf("hello s31\n");

    while (true) {
        esp_rom_delay_us(1_000_000);
        _ = esp_rom_printf("tick\n");
    }
}
```

约束：

1. **只调 ROM 符号**：`esp_rom_printf` / `esp_rom_delay_us` 是芯片掩膜 ROM 里的函数，
   不引入 IDF 头文件、不链接 IDF 库，因此该静态库在 IDF 之外也能单独编出来；库里的
   这两个符号保持未定义，交给 IDF 的最终链接解析。
2. **`app_main` 只打印一次 `hello s31`**，之后每秒一行 `tick`：不维护计数器、不打印
   编号，避免把 `tick` 的节奏与 ROM 延时精度绑成验收条件。
3. **不点灯**：GPIO60 的可寻址灯珠需要 RMT 时序，ch02 不碰；串口文本是唯一可观测量。
4. **不返回**：`app_main` 在 IDF 里返回即删除 main 任务，这里用死循环钉住，行为可预期。
5. **comptime 目标断言**：arch 不是 `riscv32`、ABI 不是 `eabihf` 时直接编译失败，
   防止"用主机 target 编出个能过 CI 但跑不了的库"。

### 4.3 期望输出（真机验收口径）

上电后先看到 IDF 二级 bootloader 日志（版本、Flash 模式、分区表、镜像校验，随 IDF
版本变化），随后是应用输出。应用侧的目标形态如下——这是**验收目标**，不是已获得的
输出（本工程尚未上机）：

```text
hello s31
tick
tick
tick
```

验收点：`hello s31` 恰好出现一次且在 `tick` 之前，之后每秒一行 `tick`。串口 115200
8N1；`tick` 的实际节奏受 ROM 忙等延时精度影响，不做毫秒级断言。

### 4.4 诚实性规则

- 本工程**尚未**在任何真机上运行。README 的"真实输出"小节写「待真机验证：run.log 待
  真机回填」，不得贴伪造日志、不得写"实测通过"。
- 一切涉及烧录、串口、备份的步骤在 README 里带「待真机验证」标记；真机跑通后，用
  `run.log` 摘录替换标记并写明日期与板卡序列号。
- `zig build-lib --show-builtin` 的输出（`builtin.zig`）作为**系列级**证据记在 §2.2 与
  章节正文里，不塞进 ch02 工程——工程严格保持七个文件。

### 4.5 `ch03-image-inspect` 契约（主机侧解析器）

- 文件：`build.zig`、`src/main.zig`、`README.md`；无 `run.log`。
- 输入：应用镜像（`0xE9`）或二进制分区表（`0xAA50`）；输出字段与校验结果；结构错误
  退出 1，参数错误 2。
- 不接触硬件；与 `esptool image-info` 的对拍在真机产物上完成，标「待真机对拍」。
- 扩展头没有独立 magic：第 9 字节是 `wp_pin`（`0xEE` = 禁用）；不要按 `0xEE` 拒绝镜像。

### 4.6 `ch04-linker-layout` 契约（模板 B）

- 文件：`build.zig`、`linker/s31.ld`、`src/start.zig`、`src/main.zig`、`tools/flash.sh`、
  `idf-bootstrap/{CMakeLists.txt,main/CMakeLists.txt,main/app_main.c,sdkconfig.defaults}`、
  `README.md`；无 `run.log`。
- `.app_desc` 必须是第一个 `PT_LOAD` 段的首个内容：256 字节、magic `0xABCD5432`、字段
  偏移见 IDF `esp_app_desc.h`；`KEEP(*(.app_desc))` 放在 `.text` 最前面。
- 链接脚本必须在 `.data` 内、`.sdata` 之前定义 `__global_pointer$ = . + 0x800`；
  `_start` 在设 `sp` 后设 `gp`。RISC-V linker relaxation 可能生成 gp 相对访问，gp 未
  初始化会静默取到错误地址（IDF `ld.dram.sections` 同款定义）。
- `_start` 五步：关中断、设 sp/gp、清 bss、搬 data（本版 LMA == VMA，不搬）、`call main`；
  入口由 `ENTRY(_start)` 指定。
- `tools/flash.sh` 只从 `idf-bootstrap/build/flash_args` 取偏移；执行前先把 `app.bin`
  锚成绝对路径，再 `cd` 到 `flash_args` 所在 build 目录，否则相对路径找不到
  `bootloader/` 与 `partition_table/`。
- 应用构建链不得出现 `idf.py`；`idf-bootstrap` 只用于生成 bootloader、分区表与
  `flash_args`，并走 `idf.py --preview`。

### 4.7 `ch05-clock-reset-wdt` 契约（模板 B）

- 文件：`build.zig`、`linker/s31.ld`、`src/{start,main,clock,reset,wdt}.zig`、
  `tools/flash.sh`、`idf-bootstrap/*`、`README.md`；无 `run.log`。
- 时钟：SYSTIMER（16 MHz 节拍）当尺子、`mcycle` 当被测对象；**不写 PLL/时钟树寄存器**，
  只测量 bootloader 留下的频率。所有读数标「待真机验证」。
- 复位：ROM `rtc_get_reset_reason(0)`；编码表与 IDF 归类分离打印。
- 看门狗：RWDT 写保护 `0x50D83AA1`，`unlock → 写 → lock`；`disable` 必须同时清
  `EN`/`FLASHBOOT` 与四个 stage 字段；超时实验默认关闭，开启后必须能通过复位原因闭环。

### 4.8 `ch06-gpio-uart-log` 契约（模板 B）

- 文件：`build.zig`、`linker/s31.ld`、`src/{start,main,uart,gpio,log,panic}.zig`、
  `tools/flash.sh`、`idf-bootstrap/*`、`README.md`；无 `run.log`。
- GPIO：只实现 **bank0（GPIO0..31）**；`GPIO_OUT/ENABLE/IN` 每 32 位一组，GPIO32..62
  需要 OUT1/ENABLE1/IN1，留到后续章节。GPIO60 的 WS2812 明确不能用普通 GPIO 电平驱动。
- UART：TX 走 ROM `esp_rom_printf`；RX 用轮询 FIFO + 128 B SPSC 环形缓冲，中断版留到
  ch07（CLIC/mtvec 就绪后）。`t` trap 演示必须显式提示“会停机，需复位”。
- panic：`mtvec` 直接模式、naked `trapVector`、打印 `mcause/mepc/ra/mtval/sp` 后停机；
  不做 unwinder。

### 4.9 `ch07-interrupts-clic` 契约（模板 B）

- 文件：`build.zig`、`linker/s31.ld`、`src/{start,main,clic,isr,critical}.zig`、
  `tools/flash.sh`、`idf-bootstrap/*`、`README.md`；无 `run.log`。
- 矩阵：`INTERRUPT_CORE0` 基址 0x20585000，每个源一个 map 寄存器；`route()` 写
  `channel + 16`（CLIC 输入号），不是外部号 0..31。
- 本章用 `mtvec` MODE=0 直接模式 + 矩阵 + UART0 RX ISR；CLIC 向量模式（MTVT/MODE=3）
  只讲入口、标「待真机验证」，不声称已启用。
- 临界区：保存/恢复 `mstatus`（可嵌套）与 CLIC 阈值原语；ISR 只搬字节/清标志，不打印。
- 所有中断/嵌套/阈值行为 待真机验证。

### 4.10 `ch08-timers-dma` 契约（模板 B）

- 文件：`build.zig`、`linker/s31.ld`、`src/{start,main,timg,systimer,dma}.zig`、
  `tools/flash.sh`、`idf-bootstrap/*`、`README.md`；无 `run.log`。
- TIMG0/TIMG1 基址 0x20580000/0x20581000，SYSTIMER 0x20399000，AHB/GDMA 0x20343000；
  寄存器字段以 IDF v6.1 头文件为准。
- 本章用轮询 `INT_RAW` 测 TIMG/SYSTIMER 抖动，不打开 TIMG 中断；GDMA 做 2 KiB
  内存到内存搬运 + CPU 校验，描述符字段不确定处标「待核对」。
- 所有时序/DMA 结果 待真机验证。

### 4.11 `ch09-flash-partition-nvs` 契约（模板 B）

- 文件：`build.zig`、`linker/s31.ld`、`src/{start,flash,partition,kv,main}.zig`、
  `tools/flash.sh`、`idf-bootstrap/{CMakeLists.txt,main/CMakeLists.txt,main/app_main.c,sdkconfig.defaults,partitions.csv}`、
  `README.md`；无 `run.log`。
- ROM flash：`esp_rom_spiflash_erase_sector=0x2f800160`、`_write=0x2f800168`、
  `_read=0x2f80016c`；4 字节对齐、先擦后写、擦除参数是扇区号、flash offset ≠ XIP 地址；
  写/擦前后处理 cache 窗口，全部 待真机验证。
- 分区：表在 `0x8000`（`0xC00`/`0x1000`/32B/95 条/`0xAA50`/MD5）；按 **label** 查找
  `storage`（CSV 中 `0x300000` + `0x10000`），不硬编码偏移；绝不写 nvs/bootloader/分区表。
- KV：append-only、magic `0x4B56` + seq + CRC32、`0xFF` 空白尾 vs 撕裂尾、压缩恢复；
  **不是 IDF-NVS 兼容格式**，不得指向 nvs 分区。

### 4.12 `ch10-context-switch-scheduler` 契约（模板 B）

- 文件：`build.zig`、`linker/s31.ld`、`src/{start,context,sched,tasks,main}.zig`、
  `tools/flash.sh`、`idf-bootstrap/*`、`README.md`；无 `run.log`。
- 上下文帧：整数版 64 字节（`ra`+`s0`–`s11`，16 对齐）；FPU 版 208 字节（`fcsr`+`f0`–`f31`）。
  S31 是单精度 F、`SOC_CPU_HAS_FPU_EXT_ILL_BUG=1`（EXT_ILL 不支持 FLW/FSW，不能做惰性保存）、
  `SOC_PM_FPU_RETENTION_BY_SW=1`；启用 FP 前 `mstatus.FS` 必须非 0。
- 协作调度：每任务独立栈 + TCB + 就绪表；yield 走软件中断/`ecall`，trap 帧携带每任务
  `mepc/mstatus`；所有硬件行为 待真机验证。
- 若示例为纯整数，必须在 README/章节明确 F 保存路径未启用。

### 4.13 `ch11-preemptive-scheduler` 契约（模板 B，抢占式）

- 文件：`build.zig`、`linker/s31.ld`、`src/{start,context,sched,tasks,tick,main}.zig`、
  `tools/flash.sh`、`idf-bootstrap/*`、`README.md`；无 `run.log`。
- tick：TIMG0 T0（`0x20580000`），时钟源选 XTAL 40 MHz（`HP_SYS_CLKRST + 0x114` 的
  `T0_SRC_SEL[4:3] = 0`、`T0_CLK_EN[5]`），分频 40 → 1 MHz，闹钟 1000 → 1 ms；
  命中清 `INT_CLR_TIMERS(+0x7c)` bit0 后用「上次目标 + 周期」绝对重装（不是 now + 周期）；
  **必须置 `INT_ENA_TIMERS(+0x70)` bit0**（复位 0，ch08 轮询时不用），否则 `INT_RAW` 出不了 TIMG；
  并显式清 `T0CONFIG.AUTORELOAD`（bit29，复位 1），否则命中后计数器回卷、绝对时间轴失效。
- 路由：源 25（`ETS_TIMERGRP0_T0_INTR_SOURCE`）→ 矩阵 `0x20585000 + 4×25`，`MAP[5:0]` 写
  **CLIC 输入号 16**（不是外部通道 0；写 0 会投递到内部输入，现象是「中断完全没发生」）→
  CLIC 输入 16（`0x10801000 + 4i`）优先级 3、`IE` bit8、阈值 0（`0x10800008` 的 [31:24]）。
- 调度：TCB 在 ch10 基础上加 `prio(u3)`/`slice`/`slice_init`/`next`；8 条优先级单向环形链，
  尾插头取，严格优先级 + 同级时间片（单位 = tick）。无 `blocked`、无老化、无优先级继承。
- 换栈边界：tick ISR 复用 ch10 的 80B trap 帧 + 64B switch 帧与 `switchTo`；`mepc += 4` **只**
  属 `ecall` 分支；临界区覆盖「入队 + 选任务 + 改 `current` + `switchRaw` 保存 sp」；新任务由
  `taskStart` 开 MIE，被抢占任务由自己的 `mret`（MPIE）恢复。
- 证据口径：ISR 内换栈、tick 周期/漂移/抖动、CLIC `IP` 清除行为全部 待真机验证；
  正文与 README 不得预填这些数字。

## 5. 构建与运行命令

### 5.1 通用前置

```bash
# Linux / macOS
. $HOME/esp/esp-idf/export.sh
# Windows PowerShell
& $HOME\esp\esp-idf\export.ps1
```

Zig 必须在 `PATH` 里（`zig version` 输出 `0.17.1`）。目标串在 §2.2，任何命令都不得
省略 `-Dcpu`。

### 5.2 模板 A（ch02）

```bash
cd practice/zig-esp32-s31/ch02-hello
idf.py --preview set-target esp32s31   # v6.1 preview target；转正后可省略 --preview
idf.py build                    # 内部触发 zig build，产出 libmain_zig.a
idf.py -p <PORT> flash monitor  # 烧录并看 UART0 日志

# 镜像字段验收（应用镜像名取自 project(zig_s31_hello)）
esptool --chip esp32s31 image-info build/zig_s31_hello.bin
```

`idf.py build` 内部执行的 Zig 命令与产物：

```bash
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall \
  --prefix build/main/zig-out
# → build/main/zig-out/lib/libmain_zig.a
```

不经 IDF 的 Zig 侧自检（验证静态库能独立编出、`app_main` 是定义符号）：

```bash
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall --prefix zig-out
ls zig-out/lib/libmain_zig.a
riscv32-esp-elf-nm zig-out/lib/libmain_zig.a | grep -E "app_main|esp_rom_printf"
```

期望：`app_main` 为 `T`（定义），`esp_rom_printf` 为 `U`（未定义，留给 IDF 链接）。

### 5.3 模板 B（ch04 起）

```bash
cd practice/zig-esp32-s31/ch04-linker-layout
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf
esptool --chip esp32s31 image-info zig-out/bin/app.bin

# 供应商步骤：只取 IDF 的二级 bootloader 与分区表（不构建 IDF 应用）
( cd idf-bootstrap && idf.py --preview set-target esp32s31 && idf.py build )
./tools/flash.sh <PORT>
```

`tools/flash.sh` 的行为固定为：读 `idf-bootstrap/build/flash_args`，把其中的 app 行
替换成本工程的 `zig-out/bin/app.bin`，bootloader 与分区表两行原样保留，再执行
`esptool --chip esp32s31 -p <PORT> -b 921600 write-flash @<临时args>`。**偏移不得手抄**，
`flash_args` 是唯一口径；其内部文件路径相对 build 目录，脚本会先把 `app.bin` 锚成
绝对路径，再 `cd` 到 `flash_args` 所在目录执行 esptool。

### 5.4 端口选择

板上同时暴露两个串口设备，`idf.py`/`esptool` 的自动探测会选错，**必须显式 `-p`**：

| 平台    | UART0（USB-UART 桥接器）       | USB Serial/JTAG（原生 USB） |
| ------- | ------------------------------ | --------------------------- |
| Windows | `COMx`（设备管理器 → 端口）    | 另一个 `COMx`               |
| Linux   | `/dev/ttyUSB0`（`dialout` 组） | `/dev/ttyACM0`              |

规则：ch02 的日志与烧录走 **UART0 口**（`esp_rom_printf` 输出到 ROM 控制台，即 UART0）；
USB Serial/JTAG 口留给 OpenOCD/GDB（ch07 起）。烧录波特率 921600，日志 115200。
Windows 下列端口：

```powershell
Get-CimInstance Win32_SerialPort | Select-Object DeviceID, Description
```

### 5.5 镜像字段验收

`image-info` 输出必须同时满足：魔数 `0xE9`、段数与 ELF 段表一致、入口地址等于
`_start`（模板 B）或 IDF 应用入口（模板 A）、校验和一项为 `valid`、SHA256 校验一项为
`valid`。字段名与措辞以 esptool 5.2 的实际输出为准，工程 README 粘贴**真实**输出片段。

## 6. 日志与入库规则

- **只提交源码**：`*.zig`、`*.c`、`*.h`、`CMakeLists.txt`、`sdkconfig.defaults`（及
  `.ci`/`.debug` 变体）、链接脚本、`README.md`、`run.log`。
- **`run.log` 必须是真实输出**：程序/串口重定向的原文，禁止编辑、拼接、美化。真机未跑
  时**不建**该文件，README 写"run.log 待真机回填"。
- **超过 1 MB 必须截断**：保留首 5000 行 + 关键证据行（`assert failed` / `panic` /
  `abort()` / `Guru Meditation` / `Backtrace` / `rst:0x`）+ 末 500 行，并在文件末尾写：

  ```text
  [LOG TRUNCATED: 原始 1234567 行 / 45.2 MiB；保留首 5000 行 + 关键证据行 + 末 500 行；
   完整日志不入库，复现命令见 README]
  ```

  原始行数与体积必须是 `wc -l` / `stat` 的真实值，不得估算。

- **已被 `.gitignore` 命中的路径**（集成已落地；工程作者不自行改动全局忽略表）：

  ```text
  practice/zig-esp32-s31/**/.zig-cache/
  practice/zig-esp32-s31/**/zig-out/
  practice/zig-esp32-s31/**/build*/
  practice/zig-esp32-s31/**/managed_components/
  practice/zig-esp32-s31/**/sdkconfig
  practice/zig-esp32-s31/**/sdkconfig.old
  ```

  注意 `build*/` 用通配：构建目录历史上出现过 `build`、`build_d`、`build-dbg`。单个
  IDF `build/` 可达数十 MB，禁止整目录 `git add`。

## 7. 代码站收录

代码浏览站（`quartz/static/code/`）按 `scripts/gen-code-site.mjs` 的 `PROJECT_GLOBS`
逐套件收录。本套件的收录改动**已落地**（`.zig` 不再被静默丢弃）；后续新增套件按同样步骤检查：

1. `PROJECT_GLOBS` 已加一条（列表末尾，`practice/lwip-labs` 之后）：

   ```js
   "practice/zig-esp32-s31/*", // Zig × ESP32-S31 章节工程（形态 A/B）
   ```

2. `langOf()` 的扩展名表已加 `.zig`；没有它会返回 `null`，文件不进 `files.json`：

   ```js
   ".zig": "zig",
   ```

3. `SKIP_DIRS` 已加 Zig 生成物目录（`.zig-cache`、`zig-out`）：

   ```js
   ".zig-cache",
   "zig-out",
   ```

`SHIKI_LANGS` 已加 `"zig"`（Shiki 自带 `@shikijs/langs/dist/zig.mjs`；已确认存量 md
无 ```zig 围栏，加载集变化不影响既有片段）。

本批已执行 `npm run code-site` 重新生成（4172 文件 / 78 个项目，覆盖 ch01–ch11；约 3 分钟；脚本先
`rmSync` 整个 `html/`，中途被杀会留下 git 可见的 deleted 状态）。后续修改工程后重跑，
正文深链格式为：

```text
/static/code/#/zig-esp32-s31/<工程>/<文件>
```

例：`/static/code/#/zig-esp32-s31/ch02-hello/main/main.zig`。深链只在文件确实被收录后
使用；文章里贴链接前先跑一次生成并核对 `files.json`。

## 8. CI 与验收

| 关卡 | 命令                                                                                                               | 通过条件                                                                      |
| ---- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| 主机 | `zig build test`（主机 target）                                                                                    | 单元测试全绿；只测纯逻辑（解析器、缓冲区、状态机）                            |
| 交叉 | `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` | 产出 `libmain_zig.a`（A）或 `app.elf`（B）；不设零警告门槛，但不得有 error    |
| 镜像 | `esptool --chip esp32s31 image-info <bin>`                                                                         | §5.5 五项全部成立                                                             |
| 冒烟 | esp-emu 加载镜像，跑到第一条 UART 输出                                                                             | 出现 `hello s31`（ch02）；模拟器不支持 S31 时记 `emulator.log` 并降级为非阻塞 |
| 真机 | `idf.py -p <PORT> flash monitor`（A）/ `tools/flash.sh`（B）                                                       | 串口出现章节验收行；产出 `run.log`。**可选、夜间跑**，不作为每次提交的门槛    |

纪律项（一票否决）：

1. 纯 Zig 路径（形态 B）的 app 构建链**不得**调用 `idf.py`；`idf.py` 只允许出现在
   `idf-bootstrap/` 的供应商步骤里。CI 用 grep 断言 `tools/flash.sh`、`build.zig` 中
   无 `idf.py`。
2. 主机测试不得依赖串口、网络或真机；需要硬件的一律标 `待真机验证` 并跳过。
3. 任何"实测数字"必须能在 `run.log` 里找到对应行；找不到即视为编造。
4. 冒烟失败不等于可提交：先修，或在 README「已知边界」写清失败现象与复现命令。

## 9. 命名、README 与许可

### 9.1 命名

- 目录：`chNN-<kebab-slug>`，全小写、连字符分隔、不与章节号脱节；`NN` 补零两位。
- Zig 文件：`snake_case.zig`；导出给 C 的符号用 C 侧习惯（`app_main`）。
- 目标/产物名：静态库 `main_zig`（`libmain_zig.a`）；模板 A 的 IDF 应用名 `zig_s31_hello`
  （`zig_s31_hello.bin`）；模板 B 的可执行 `app`（`app.elf`/`app.bin`）。不出现
  `main`、`firmware`、`test` 这类会与 IDF 约定撞名的产物名。

### 9.2 README 章节（顺序固定）

```text
# ch02 hello —— 第一行 Zig 跑在 S31 上
> 所属章节：[[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]

## 目的
## 硬件与接线
## 文件表
## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥5.2）
## 构建
## 运行（完整可复制，含 -p <PORT>）
## 真实输出（未跑则写"待真机验证：run.log 待真机回填"）
## 已知边界与排障
```

- 反向 wikilink 只指向**已存在**的页面：章节页已落地的（ch01、ch02）直接链章节页，
  同时链系列索引 `[[zig-esp32-s31]]`；章节页尚未落地的写纯文本标题，不造 wikilink。
  目标名以实际文件名（去 `.md`）为准，不按章节号猜。
- 拓扑/接线用 ASCII 图或 Markdown 表格，不用 HTML。
- 排障条目写"环境 → 现象 → 根因 → 处置"，不写"应该是……"。

### 9.3 许可

仓库整体 MIT（见 `LICENSE.txt`），本套件源码随仓库同许可。若某文件抄录或改编了 IDF
源码（例如链接脚本区间、寄存器定义），在该文件头部注明来源路径与 Apache-2.0，并在
README 的「已知边界」里列出，不把第三方代码混进"原创"叙述。

## 10. 状态与变更政策

- 规格版本：**v1.1**，日期 **2026-11-26**。v1 锁定 ch02 的完整契约（模板 A）与模板 B
  的骨架；ch03 起按本规格推进，实现细节在各章工程内展开。v1.1 增补 ch11 抢占调度契约（§4.13）。
- 变更记录：

  | 版本 | 日期       | 变更                                                                                            |
  | ---- | ---------- | ----------------------------------------------------------------------------------------------- |
  | v1   | 2026-11-12 | 首版：目录/命名、环境钉扎、模板 A/B、ch02 契约、CI 与收录规则                                   |
  | v1.1 | 2026-11-26 | 增补 §4.13 `ch11-preemptive-scheduler`（tick/INT_ENA/路由/TCB/换栈边界）；§4 标题范围 ch03–ch11 |

- **必须同步更新本文件的触发条件**：模板 A 或 B 的文件清单、构建命令、目标串、镜像
  参数发生变化；CI 关卡增减；`PROJECT_GLOBS`/`langOf` 的收录规则变化。只改章节工程
  不改本规格 = 规格失效，下一章会照旧抄错。
- **版本钉扎**：Zig 0.17.1、IDF v6.1、esptool ≥5.2 三件套任一升级，都必须重跑
  §2.2 的目标串冒烟与 §8 的镜像关卡，并把新的 `builtin.zig` 与 `image-info` 输出存进
  受影响工程，再更新本文件 §2 的表格。
- **S31 数据手册仍是 Pre-release**：本规格不写死内存区间、CLIC 路数与中断号，一律以
  IDF v6.1 的 `esp32s31` 头文件/链接脚本为准；手册转正式版后，逐项复核 §2.3 与
  §3.2 的链接脚本来源注释。
- 事实来源：[[zig-esp32-s31]] 系列索引；Zig 0.17.1 目标串实测记录（2026-11-12，
  `zig build-lib --show-builtin` / `zig build-obj`）；ESP-IDF v6.1 `esp32s31` 目标与
  链接脚本；esptool 5.2 镜像格式与 `image-info` 输出；仓库 `AGENTS.md` 的
  practice 入库与日志截断政策。
