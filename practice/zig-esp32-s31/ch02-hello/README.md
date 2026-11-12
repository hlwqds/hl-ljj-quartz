# ch02 hello：第一行 Zig 跑在 S31 上

> 所属章节：[[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是系列的第一个可烧录工程，采用**形态 A**：Zig 编译出静态库并导出 `app_main`，
ESP-IDF 的 CMake 工程负责启动链、分区表、镜像打包与烧录。工程只做一件事——
在 UART0 打印 `hello s31`，之后每秒打印一行 `tick`。

它验证的是一条构建链，而不是某个外设：Zig 能否按 S31 的 ISA/ABI 产出目标代码、
静态库能否被 IDF 正确链接、`app_main` 能否被启动代码调用、镜像能否被烧录并产生
可读输出。

> [!warning] 验证状态
> **已实测（2026-11-13）**：真机输出 `hello s31` + 每秒 `tick`，形态 A 工作正常；为让 ROM 忙等不饿死 IDLE0，`sdkconfig.defaults` 关闭了 `CONFIG_ESP_TASK_WDT_EN/INIT`。

## 硬件与接线

| 项       | 事实                                                       |
| -------- | ---------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                             |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM    |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1              |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位         |
| USB      | USB-to-UART（日志/烧录）与 USB Serial/JTAG（调试）各一路   |
| 本章外设 | 不驱动 GPIO60 的可寻址 RGB LED（需要 RMT 时序，留到 ch06） |

接线只需要两根 USB-C 线：一根供电，一根接 USB-to-UART 口用于烧录与看日志。
本章没有外部器件、没有杜邦线；UART 文本是唯一可观测量。

## 文件表

| 路径                  | 角色                                                              | 代码浏览                                                            |
| --------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------- |
| `CMakeLists.txt`      | IDF 工程入口：引入 `project.cmake`、`project(zig_s31_hello)`      | [查看](/static/code/#/zig-esp32-s31/ch02-hello/CMakeLists.txt)      |
| `sdkconfig.defaults`  | 16 MB Flash + single-app-large 分区表                             | [查看](/static/code/#/zig-esp32-s31/ch02-hello/sdkconfig.defaults)  |
| `build.zig`           | Zig 侧：标准目标选项 + 静态库 `main_zig`                          | [查看](/static/code/#/zig-esp32-s31/ch02-hello/build.zig)           |
| `main/CMakeLists.txt` | 查找 Zig、自定义命令、顺序依赖、把 `libmain_zig.a` 挂到组件上     | [查看](/static/code/#/zig-esp32-s31/ch02-hello/main/CMakeLists.txt) |
| `main/main.zig`       | `export fn app_main`：打印 `hello s31`，之后每秒一行 `tick`       | [查看](/static/code/#/zig-esp32-s31/ch02-hello/main/main.zig)       |
| `main/idf_anchor.c`   | 最小 C 锚点：让 `main` 组件有 C 源文件，并提供稳定的 C/Zig 交界点 | [查看](/static/code/#/zig-esp32-s31/ch02-hello/main/idf_anchor.c)   |
| `README.md`           | 本文件                                                            | [查看](/static/code/#/zig-esp32-s31/ch02-hello/README.md)           |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置的
single-app-large 分区表）、没有 `run.log`（真机未跑）。生成物 `build/`、`zig-out/`、
`.zig-cache/` 都不入库，提交前确认忽略规则覆盖它们。

代码浏览器收录已在 `scripts/gen-code-site.mjs` 的 `PROJECT_GLOBS` 中登记
`practice/zig-esp32-s31/*`，并补上 `.zig` 的 `langOf()` 映射与 Shiki 语法；运行
`npm run code-site` 后生效。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥5.2）

| 工具    | 版本要求              | 说明                                                                   |
| ------- | --------------------- | ---------------------------------------------------------------------- |
| Zig     | 0.17.1                | 上游稳定版；`zig version` 必须精确匹配                                 |
| ESP-IDF | v6.1                  | 目标 `esp32s31` 为 preview target；提供二级 bootloader、esptool、CMake |
| esptool | >= 5.2                | 烧录与 `image-info`；随 IDF 安装，也可单独安装                         |
| 目标板  | ESP32-S31 CoreBoard-1 | ESP32-S31-WROOM-3（N16R16V）                                           |
| 主机    | Linux 或 Windows      | Windows 用 IDF 的 PowerShell 导出脚本；Linux 用 `export.sh`            |

构建前先让 `idf.py`、`esptool`、交叉工具链进入 `PATH`：

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh

# Windows PowerShell
. $env:IDF_PATH\export.ps1
```

Zig 只需解压后把目录加入 `PATH`，不依赖 IDF 的 Python 环境。目标能力用下面的命令
自证（Zig 0.17.1 下实测）：

```bash
zig build-lib --show-builtin \
  -target riscv32-freestanding-eabihf \
  -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei
```

输出中 `abi = .eabihf`、`arch = .riscv32`、`model = generic_rv32`，特性集含
`m/a/c/f/i/zicsr/zifencei`（另推导出 `zaamo/zalrsc/zca/zmmul`）。这证明编译器按
S31 的 ISA/ABI 生成代码；它不证明固件在真机上运行过。需要留档时把标准输出重定向为
`builtin.zig`（生成物，不入库）。

## 构建

```bash
cd practice/zig-esp32-s31/ch02-hello

# 只在本工程第一次构建、或切换芯片目标时需要
idf.py --preview set-target esp32s31   # v6.1 preview target；转正后可省略 --preview

idf.py build
```

`idf.py build` 期间会自动执行一次等价于下面的 Zig 构建（由
`main/CMakeLists.txt` 的 custom command 触发）：

```bash
zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall \
  --prefix build/main/zig-out
```

产物是 `build/main/zig-out/lib/libmain_zig.a`。想单独验证 Zig 侧而不跑 IDF 时，
在工程根目录执行：

```bash
zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall \
  --prefix zig-out

ls zig-out/lib/libmain_zig.a
```

可以用 `nm` 确认符号归属：`app_main` 应为定义（`T`），`esp_rom_printf` 应为
未定义（`U`，留给 IDF 最终链接解析）：

```bash
riscv32-esp-elf-nm zig-out/lib/libmain_zig.a | grep -E "app_main|esp_rom_printf"
```

### 静态库如何被链接

1. **Zig 只产库**。`build.zig` 用 `standardTargetOptions` / `standardOptimizeOption`
   接收 `-Dtarget`、`-Dcpu`、`-Doptimize`，把 `main/main.zig` 编成
   `libmain_zig.a`，不参与最终链接。库里的 `esp_rom_printf`、`esp_rom_delay_us`
   保持未定义，交给 IDF 的链接阶段。
2. **CMake 建立顺序**。`add_custom_command` 声明 `libmain_zig.a` 由 `zig build`
   生成，`add_custom_target(zig_main ALL ...)` 把它挂进默认构建，
   `add_dependencies(${COMPONENT_LIB} zig_main)` 保证 `libmain.a` 链接前 Zig 库已存在。
3. **组件获得 C 源**。`idf_component_register(SRCS "idf_anchor.c" ...)` 让 `main`
   组件成为正常的 IDF 组件；`idf_anchor.c` 不定义 `app_main`，只是最小锚点与后续
   C/Zig 交界点。
4. **符号在最终链接汇合**。`target_link_libraries(${COMPONENT_LIB} INTERFACE
"${ZIG_LIB}")` 把 `.a` 传给链接 `main` 组件的目标；IDF 启动代码引用
   `app_main`，链接器因此从 `libmain_zig.a` 中取出对应的目标文件。若 `.a` 没有
   进入链接集合，表现就是 `undefined reference to 'app_main'`。

## 运行

烧录并监视（`<PORT>` 必须显式给出，自动探测可能选到另一个 USB 口）：

```bash
# Linux
idf.py -p /dev/ttyUSB0 flash monitor

# Windows
idf.py -p COM7 flash monitor
```

`Ctrl+]` 退出监视器。烧录完成后可以用 esptool 解析应用镜像，确认头部、段与校验：

```bash
esptool --chip esp32s31 image-info build/zig_s31_hello.bin
```

监视器会先打印 IDF 二级 bootloader 的启动日志（版本、Flash 模式、分区表、镜像
校验，随 IDF 版本变化），随后是应用输出。应用侧的目标形态为：

```text
hello s31
tick
tick
tick
```

> [!note] 以上是本章的验收目标，不是已获得的输出。串口 115200 8N1；`tick` 的实际
> 节奏受 ROM 忙等延时精度影响，不做毫秒级断言。

## 真实输出

**已实测（2026-11-13）**：真机输出 `hello s31` + 每秒 `tick`（详见 `../logs/`与 `BRINGUP-2026-11-12.md`）。README 不贴预期
日志冒充实测；真机跑通后，把 UART0 的原始输出存为 `run.log` 并在此标注日期与板卡
序列号。

## 已知边界与排障

### ROM 控制台恒定走 UART0

`esp_rom_printf` 写的是 **ROM 控制台**，不受 IDF 的 console Kconfig 影响，恒定输出
到 UART0（GPIO58/59）。如果只接了 USB Serial/JTAG 口，IDF 自己的日志会跟随 console
配置出现在该口，而 `hello s31` 只会在 UART0 出现。遇到这种情况应改用 UART0 桥接口，
而不是修改 Zig 代码。

### 两个 USB 口

| 平台    | UART0（USB-UART 桥接器）       | USB Serial/JTAG（原生 USB） |
| ------- | ------------------------------ | --------------------------- |
| Windows | `COMx`（设备管理器 → 端口）    | 另一个 `COMx`               |
| Linux   | `/dev/ttyUSB0`（`dialout` 组） | `/dev/ttyACM0`              |

规则：本工程的烧录与日志走 UART0；USB Serial/JTAG 留给 OpenOCD/GDB（ch07 起）。
日志固定 115200 8N1；烧录波特率由 IDF 的配置与命令行决定，不影响应用输出。

### 排障

| 环境   | 现象                                   | 根因                                                | 处置                                                                       |
| ------ | -------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------- |
| Shell  | `idf.py: command not found`            | 没有 source IDF 导出脚本                            | `. $IDF_PATH/export.sh` 或 `. $env:IDF_PATH\export.ps1`                    |
| Python | `idf.py` 报包错误或调用错误 Python     | 主机 venv/conda 与 IDF 环境混用                     | 用导出后的 `python`；必要时重跑 `install.sh` 重建环境                      |
| CMake  | 配置阶段报找不到 `zig`                 | Zig 不在 `PATH`，或多个版本混用                     | `zig version` 确认；重启终端或 IDE 让 `PATH` 生效                          |
| 链接   | `undefined reference to 'app_main'`    | Zig 库没进链接集合，或 Zig 构建失败被忽略           | 检查 `build/main/zig-out/lib/libmain_zig.a`；`nm` 看 `app_main` 是否为 `T` |
| 链接   | `undefined reference to '__mulsi3'` 等 | 代码引入了需要 compiler-rt 的运算，而静态库未打包它 | ch02 保持极简；必要时给 Zig 库打开 compiler-rt 打包后重链                  |
| Zig    | `build.zig` API 不匹配                 | Zig 版本不是 0.17.1，或脚本沿用了旧 API             | 对齐版本；删除 `.zig-cache/` 后重试                                        |
| 编译   | target/CPU 非法                        | `-Dtarget`/`-Dcpu` 拼写错误，或特性组合不可用       | 用 `zig build-lib --show-builtin` 复现并核对                               |
| 烧录   | 找不到下载模式                         | 自动复位失败                                        | 按住 BOOT（GPIO61）再复位，然后重试                                        |
| 运行   | `invalid header` / 上电反复重启        | Flash size/mode 与模组不符，或镜像不完整            | 确认 16 MB 配置；`idf.py fullclean` 后重建；用 `image-info` 核对           |
| 运行   | 串口无输出                             | 选错 USB 口、波特率不对、端口被占用                 | 换 UART 口；确认 115200；关闭其他串口工具                                  |
| 运行   | Linux 打不开串口                       | 用户不在 `dialout` 组                               | 加入 `dialout` 后重新登录                                                  |
| 构建   | 切换芯片后异常                         | `sdkconfig` 仍是旧目标                              | `idf.py --preview set-target esp32s31`，必要时先 `idf.py fullclean`        |

### 待真机验证

- [ ] `idf.py build` 在 IDF v6.1 + Zig 0.17.1 下产出 `build/zig_s31_hello.bin`
- [ ] 烧录后监视器出现 `hello s31`，随后每秒一行 `tick`
- [ ] `esptool --chip esp32s31 image-info` 能解析应用镜像
- [ ] 16 MB Flash 与 single-app-large 分区表在 `menuconfig` 中符合预期
- [ ] `run.log` 回填：真机串口原始输出（当前状态：**run.log 待真机回填**）
