---
title: "Zig × ESP32-S31 全栈开发（二）：工具链与第一个可烧录镜像"
date: 2026-11-12 18:00:00
description: "把 Zig 0.17.1 的目标能力钉死，选对 ESP32-S31 的构建形态，用形态 A（Zig 静态库 + IDF 宿主工程）产出第一个可烧录镜像：工程逐文件走读、链接顺序、烧录监视、镜像解析与排错，硬件步骤全部标注待真机验证。"
tags: [zig, esp32-s31, riscv, toolchain, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. **第二章：工具链与第一个可烧录镜像**
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]

# Zig × ESP32-S31 全栈开发（二）：工具链与第一个可烧录镜像

第一章把"要做什么、不做什么"钉死了；这一章开始动手：在一台干净机器上装好 Zig 与 ESP-IDF，让 Zig 为 S31 产出正确的目标代码，再把它塞进 IDF 的构建链，得到一个能烧进 Flash 的镜像。

"能烧"和"能跑"是两件事。本章把验收拆成两层：**工具链层**（目标三元组、ABI、CPU 特性、目标文件）在本仓写作环境实测通过；**硬件层**（烧录、串口输出、镜像解析）必须在真机上完成，文中一律标注「待真机验证」，不预填日志、不假装跑过。

---

## 2.1 目标与验收口径

本章的交付物不是"灯亮了"，而是一条可复现的链路：

```text
干净机器
  ├─ zig 0.17.1
  ├─ ESP-IDF v6.1（esp32s31）
  └─ esptool >= 5.2
        │
        ▼
  idf.py build ──> build/zig_s31_hello.bin
        │
        ▼
  idf.py -p <PORT> flash monitor ──> hello s31 / tick ...
```

这条链路里，每一环都要有**可检查的证据**：

| 环                  | 证据                                             | 本章状态                         |
| ------------------- | ------------------------------------------------ | -------------------------------- |
| Zig 认识 S31 的 ISA | `zig build-lib --show-builtin` 的 `builtin.zig`  | 已验证（2026-11-12，Zig 0.17.1） |
| Zig 能产出目标文件  | `zig build-obj` 成功                             | 已验证（同上）                   |
| IDF 认识 `esp32s31` | `idf.py --preview set-target esp32s31`           | 待真机验证（preview target）     |
| Zig 库被 IDF 链接   | `idf.py build` 产出 `.bin`，无 `app_main` 未定义 | 待真机验证                       |
| 镜像可被工具解析    | `esptool image-info` 通过                        | 待真机验证                       |
| 应用真正运行        | 串口出现 `hello s31` 与周期 `tick`               | 待真机验证                       |

> [!warning] 本章的"已验证"只到编译器
> `builtin.zig` 与 `zig build-obj` 是在 Windows x86_64 主机上、Zig 0.17.1 下实际执行的结果。它证明的是"Zig 的 RISC-V 后端能按 S31 的 ISA/ABI 生成代码"，**不证明**这段代码在 S31 硅片上运行过。凡涉及板子的步骤，读者需要在真机上自行完成并记录。

本章还要回答一个容易被跳过的问题：**为什么要选形态 A**。S31 上至少有三种把 Zig 代码变成固件的做法，它们的差别不在"能不能编译"，而在"谁来负责启动链、镜像头、分区表和烧录"。选错了，后面的调试会把工具链问题和启动问题搅在一起。

---

## 2.2 工具链矩阵

本系列锁定下面这组版本，不追 master：

| 工具          | 版本 / 来源                          | 在本章的角色                                             | 备注                                                             |
| ------------- | ------------------------------------ | -------------------------------------------------------- | ---------------------------------------------------------------- |
| Zig           | 0.17.1 stable（2026-11-02 发布）     | 交叉编译、`build.zig`、目标能力查询                      | 版本锁定；`build.zig` API 随 Zig 大版本变化                      |
| ESP-IDF       | v6.1（`esp32s31` 为 preview target） | `esp32s31` 目标、二级 bootloader、分区表、CMake、esptool | 命令带 `--preview`；纯 Zig 路径里只把它当"镜像供应商 + 对照实现" |
| esptool       | >= 5.2                               | 烧录、`elf2image`、`image-info`                          | S31 支持从 5.2 开始；随 IDF 安装的版本要核对                     |
| esp-emu       | Espressif ESP32 emulator             | 早期 bring-up 冒烟                                       | 外设模型不完整，不能替代真机                                     |
| OpenOCD + GDB | IDF 工具链自带                       | USB Serial/JTAG 调试、断点、panic 回溯                   | 与 UART 日志构成两条观测通道                                     |
| 主机          | Linux 优先；Windows 用 EIM 安装器    | 构建、串口、抓包                                         | 本仓写作环境是 Windows，命令给双平台口径                         |

安装顺序建议是：先 IDF（它自带 Python、交叉 GCC、esptool、OpenOCD），再 Zig（解压即用，不污染 IDF 的 Python 环境），最后核对版本：

```bash
zig version          # 期望输出 0.17.1
idf.py --version     # 期望看到 v6.1
esptool version      # 期望 >= 5.2
```

> [!warning] `esp32s31` 在 IDF v6.1 是 preview target
> 本仓已有 S31 实机基线：[[onvif-deep-dive|ONVIF 深度解析系列]]的 [[ch11-esp32s31-lab-plan|第十一章]]与 `practice/onvif-labs/SPEC.md` 都记录过——`set-target` / `list-targets` 必须带 `--preview`，且 `--preview` 是 `idf.py` 的全局选项，位置在子命令之前：`idf.py --preview set-target esp32s31`。v6.1 正式版转正后可省略；报 `unknown target` 时先补 `--preview`。

### 1. Linux

```bash
# IDF：只装 S31 需要的工具链，省磁盘与下载时间
./install.sh esp32s31
. ./export.sh
```

`install.sh` 的目标参数决定安装哪些交叉工具链；只装 `esp32s31` 足够本章使用。注意 `esp32s31` 是 preview target，可能不在 `install.sh` 的稳定目标列表里：先跑 `idf.py --preview list-targets` 确认目标可见，再按 EIM / `idf_tools.py` 的实际提示安装。导出脚本要写进当前 shell 的启动文件（或每次手动 source），否则 `idf.py` 与 `riscv32-esp-elf-*` 都不在 `PATH`。

### 2. Windows

用 Espressif 的 EIM（ESP-IDF Installer Manager）安装 v6.1，安装完成后从开始菜单进入 **ESP-IDF PowerShell**，或手动导出：

```powershell
. $env:IDF_PATH\export.ps1
```

三个 Windows 特有的坑先记住：

- **路径长度**：工程路径过深时 CMake/Ninja 会碰到 260 字符限制；把仓库放在 `C:\work\` 这类短路径下。
- **杀毒软件**：实时扫描会让 `zig build` 与 CMake 的增量构建明显变慢，必要时给工程目录加排除。
- **两个 USB 口**：Windows 会枚举出两个 COM 口（UART 与 USB Serial/JTAG），烧录与日志要认准 UART 那个。

> [!note] 为什么版本要锁死
> Zig 的 `build.zig` API 在 0.13 → 0.14 → 0.15 之间连续调整过（`root_module` 的引入、安装步骤的变化）。IDF 的 CMake 变量名也会随大版本变动。本章的工程对这两个版本敏感，`zig version` 或 `idf.py --version` 对不上时，先怀疑版本，再怀疑代码。

---

## 2.3 Zig 目标冒烟：先证明编译器认识 S31

在写任何工程之前，先做一次最小验证：让 Zig 打印它为 `riscv32-freestanding-eabihf` 生成的 `builtin.zig`。这条命令不产出文件，只把"编译器眼中的目标"摊开给你看。

```bash
zig build-lib --show-builtin \
  -target riscv32-freestanding-eabihf \
  -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei
```

注意拼写差异：直接调 `zig build-lib` / `zig build-obj` 时是 `-mcpu`，走 `zig build` 时是 `-Dcpu`；两者接受同一条特性串，只是入口不同。

2026-11-12 在 Zig 0.17.1 / Windows x86_64 上实测，`builtin.zig` 里的关键取值是：

```text
abi      = .eabihf
arch     = .riscv32
model    = generic_rv32
features = m, a, c, f, i, zicsr, zifencei
           (+ zaamo, zalrsc, zca, zmmul)
```

逐项解释这张"身份证"：

| 字段 / 特性            | 含义                                                       | 对 S31 的意义                                          |
| ---------------------- | ---------------------------------------------------------- | ------------------------------------------------------ |
| `arch = .riscv32`      | 32 位 RISC-V，指令编码与寄存器模型按 RV32 生成             | 与 S31 的 RV32IMAF C 对齐                              |
| `abi = .eabihf`        | 嵌入式 ABI + 硬浮点：浮点参数走 FPU 寄存器，不落整数寄存器 | IDF 侧实际 ABI 以工具链为准；跨 Zig↔C 传浮点前必须核对 |
| `model = generic_rv32` | 不绑定具体微架构，只按通用 RV32 生成                       | S31 的流水线细节不影响正确性，只影响性能               |
| `m`                    | 整数乘除（`mul`/`div`）                                    | 编译器不会再调用软件乘除 helper                        |
| `a`                    | 原子指令（`lr`/`sc`、`amo*`）                              | 后续自旋锁、引用计数的硬件基础                         |
| `c`                    | 压缩指令（16 位编码）                                      | 代码密度；S31 支持 C 扩展                              |
| `f`                    | 单精度浮点                                                 | S31 只有单精度 F，没有 D                               |
| `i`                    | 基础整数指令集                                             | RV32I 是地板                                           |
| `zicsr`                | CSR 读写指令（`csrrw`/`csrrs` 等）                         | CLIC、CLINT、`mstatus`/`mtvec` 全部依赖它              |
| `zifencei`             | 指令流同步（`fence.i`）                                    | 改完代码/跳转到新写入的指令后必须同步 I-cache          |

输出里还会出现 `zaamo`、`zalrsc`、`zca`、`zmmul`——它们不是额外敲进去的，而是 Zig 对 `a`、`c`、`m` 的规范化展开（A 扩展拆成原子与保留加载/存储两组，C 扩展对应 `zca`，M 的乘法子集对应 `zmmul`）。**以 `--show-builtin` 的实际输出为准**，不要在文章或脚本里硬编码未验证的特性名。

> [!tip] 留档
> 需要把这份输出作为工具链证据时，把标准输出重定向到文件（如 `... --show-builtin > builtin.zig`）。它记录的是"本机 Zig 版本 + 这组目标参数"的组合，换 Zig 版本或改特性串后必须重新生成；不要拿旧文件推断新编译器。

### 1. 为什么是 `eabihf` 而不是裸 `riscv32-freestanding`

`riscv32-freestanding` 也能编译，但它默认走软浮点 ABI。S31 有单精度 FPU；**IDF 侧到底用 `ilp32` 还是 `ilp32f`，不能凭"有 F"推断**——以工具链默认 multilib 与实际编译命令为准（核对：`riscv32-esp-elf-gcc -Q --help=target | grep -E 'mabi|march'`，或看 `build/compile_commands.json` 里的 `-mabi=`）。已知旁证：S31 Linux 移植文档把 kernel/radio 标为 `ilp32f`、用户态标为 `ilp32`，同一颗芯片可以并存两种 ABI。Zig 侧用 `eabihf`；只要跨 Zig↔C 传递 `float`，就必须保证两边 ABI 一致，否则一个参数走 `fa0`、一个走 `a0`，链接不报错而数值错。ch02 没有浮点参数，这是潜伏问题；ch05/ch06 调 IDF 驱动前必须钉死。

> [!note] IDF 侧 ABI 尚未实证
> Linux 移植文档只能说明"同一颗芯片可以并存 `ilp32` 与 `ilp32f`"，不能证明 IDF v6.1 对 S31 的默认 `-mabi`。首次 `idf.py build` 后查 `build/compile_commands.json` 的 `-mabi=`（或 `riscv32-esp-elf-gcc -Q --help=target`）；若与 Zig 的 `eabihf` 不一致，任何跨 Zig↔C 的 `float` 调用都必须在 ch05/ch06 驱动层之前对齐。

### 2. `zig build-obj` 冒烟

`--show-builtin` 只证明参数解析正确，再往前一步，产出一个真正的目标文件：

```bash
zig build-obj main/main.zig \
  -target riscv32-freestanding-eabihf \
  -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -O ReleaseSmall \
  -femit-bin=main.o
```

用 `readelf -h main.o` 应看到 ELF32、小端、RISC-V 机器类型；`readelf -A main.o` 的架构属性应记录 `rv32imafc_zicsr_zifencei` 一类的 ISA 串（具体展示形式取决于 binutils 版本）。这一步在写作环境已成功执行；它不链接、不烧录，只回答"能不能为目标产出一个合法的 ELF 目标文件"。

### 3. 为什么不用 Xtensa 分支

ESP32-S3 是 Xtensa LX7，上游 Zig 不支持该架构，只能用 Espressif 维护的 LLVM 分支，或者用 `zig cc` 包一层 Xtensa GCC。两条路都意味着：工具链带厂商补丁、版本跟进滞后、社区问题难以复现。

S31 是 RISC-V，`std.Target.riscv` 里的三元组、CPU 模型、特性集都是上游一线维护的。本系列因此不需要维护编译器分支——需要自己写的是启动代码、链接脚本、CLIC/CLINT、RTOS 与协议栈，这些恰好是教学内容，而不是工具链债。

---

## 2.4 三种构建形态：A、B、C

"Zig 写 ESP32"不是一种做法，而是三种，区别在于**谁负责启动链与镜像**：

| 形态 | 做法                                                                                      | 谁负责启动链        | 用在哪                 | 代价 / 收益                                    |
| ---- | ----------------------------------------------------------------------------------------- | ------------------- | ---------------------- | ---------------------------------------------- |
| A    | Zig 编静态库，IDF CMake 工程链接；`app_main` 由 Zig 导出                                  | IDF 二级 bootloader | 本章（ch02）；跑通即弃 | 最快跑通；构建链仍有 IDF/CMake                 |
| B    | Zig 直接产出 ELF + 自定义链接脚本；`esptool elf2image` 生成镜像；IDF 二级 bootloader 加载 | IDF 二级 bootloader | ch04 起成为主线        | 构建链纯 Zig；需要自己处理启动、段布局、镜像头 |
| C    | Zig 写二级 bootloader + 应用；自带分区、校验、回滚                                        | 自己的 bootloader   | ch28 收官（可选）      | 最彻底；风险最高，放在最后                     |

### 1. 为什么本章选 A

三个理由，按重要性排序：

1. **把变量减到一个**。第一次上电时，可能出问题的地方有：工具链、链接顺序、启动链、Flash 参数、串口。形态 A 把启动链、分区表、镜像打包、烧录全部交给 IDF——它支持 `esp32s31`（preview target），启动链久经使用——只留下"Zig 目标代码 + C ABI + 链接"这三个变量。
2. **最快拿到可观测输出**。`idf.py flash monitor` 一条命令完成烧录与串口监视；应用只要 `esp_rom_printf` 就能打印。此时任何异常都能被快速归类，而不是在自制 bootloader 的静默启动里猜。
3. **它天然演示 Zig ↔ C 的边界**。`app_main` 的导出、静态库的符号解析、`eabihf` 与 IDF 侧实际 ABI 的对齐，这些是后面所有章节都要复用的基本功。形态 B 只是把"链接谁"换掉，ABI 与调用约定不变。

形态 A 的定位是**脚手架**：只用于本章的 bring-up；ch03 用主机侧程序解析镜像格式与启动链，ch04 用最小 `_start` 与链接脚本切到形态 B，此后不再新增 A 形态工程。形态 A 的工程不会进入长期架构，但它的 Zig 源码、`build.zig`、ABI 约定会一路沿用。

### 2. 形态 B 与 C 的边界先划清

- **形态 B** 仍然借 IDF 的二级 bootloader：ROM 加载 bootloader，bootloader 按分区表把应用镜像搬到正确位置并跳转。Zig 负责的是应用 ELF 的段布局与镜像头，`elf2image` 负责把 ELF 变成 ROM/bootloader 认识的格式。
- **形态 C** 才替换二级 bootloader 本身，要自己实现分区解析、镜像校验、OTA 选择与回滚。
- **Wi-Fi 不在任何形态的"纯 Zig"里**：`libnet80211`/`libpp`/`libphy` 等厂商二进制依赖 FreeRTOS/IDF 的 API（`esp_adapter.c` 是直接证据），不能直接跑在裸 Zig 运行时上。这条边界从 ch25 开始处理，本章不引入任何无线组件。

---

## 2.5 形态 A 工程走读

工程在 `practice/zig-esp32-s31/ch02-hello/`，一共七个文件（含 README）：

```text
ch02-hello/
├── CMakeLists.txt        # IDF 工程入口
├── sdkconfig.defaults    # 16 MB Flash + single-app-large 分区
├── build.zig             # Zig 静态库定义
├── main/
│   ├── CMakeLists.txt    # Zig ↔ IDF 的集成点
│   ├── main.zig          # app_main 与串口输出
│   └── idf_anchor.c      # 最小 C 锚点
└── README.md             # 复现命令与真机验收状态
```

### 1. `build.zig`：只产库，不链接

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

四个要点：

- `standardTargetOptions` 解析 `-Dtarget` 与 `-Dcpu`，`standardOptimizeOption` 解析 `-Doptimize`。IDF 的 CMake 自定义命令把三个参数原样传进来，所以 `build.zig` 里不写死芯片。
- `addStaticLibrary` 产出静态库，**不做最终链接**。库中的 `esp_rom_printf` 保持未定义符号，等 IDF 链接阶段解析。
- `installArtifact` 把产物安装到 `--prefix` 下，即 `<prefix>/lib/libmain_zig.a`。
- 目标三元组由命令行决定，`build.zig` 不假设宿主平台；同一份脚本在 Linux 与 Windows 上行为一致。

### 2. `main/main.zig`：最小应用

```zig
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .riscv32) {
        @compileError("ch02-hello 必须交叉编译到 riscv32");
    }
    if (builtin.abi != .eabihf) {
        @compileError("ch02-hello 需要 eabihf（硬浮点）ABI");
    }
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

逐行说明：

- 文件顶部的 `comptime` 检查是"防呆"：如果谁把工程当主机程序编，`arch`/`abi` 不匹配会直接编译失败，而不是产出一个能编不能跑的库。
- `export fn` 默认使用 C 调用约定，导出符号名就是 `app_main`。IDF 的启动代码按 C ABI 调用它，所以签名必须是 `void app_main(void)`。
- `esp_rom_printf` 是掩膜 ROM 里的格式化输出函数，直接走 UART0 的输出路径，不经过 IDF 的 VFS、UART 驱动或 newlib 锁。bring-up 阶段它是最轻的观测手段；代价是没有缓冲管理、没有线程安全保证，正式产品应换成 IDF 的日志设施。
- `esp_rom_delay_us` 是忙等延时。本章没有 RTOS 任务，忙等一秒只是为了让 `tick` 可读；后续章节会用定时器与调度器替换它。
- 没有任何堆分配、没有 `std` 运行时、没有 LED 操作。

> [!note] 为什么输出是 UART 而不是 LED
> 板载 RGB LED 接在 GPIO60，是可寻址灯珠（WS2812 一类），需要 RMT 外设产生精确的归零/置位时序。在 ch02 同时引入"Zig 静态库 + IDF 链接 + RMT 时序"会把两类失败混在一起。UART 是本章唯一需要的可观测量，LED 留到后续 RMT/时序章节（ch06 只做 WS2812/RMT 边界论证）。

### 3. `main/idf_anchor.c`：C 锚点

```c
void zig_s31_anchor(void);

void zig_s31_anchor(void)
{
}
```

它不定义 `app_main`，作用有两个：

1. `idf_component_register` 需要一个真实的 C 源文件来生成 `main` 组件的静态库；没有源文件时组件注册会退化，后续的链接关系也不直观。
2. 给后续章节留一个稳定的 C/Zig 交界点：中断入口、链接脚本符号、IDF 头文件封装都可以先落在这个文件里，而不必马上改 Zig 构建。

### 4. `main/CMakeLists.txt`：集成点

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

这段 CMake 做了四件事：

1. **找 Zig**：`find_program(... REQUIRED)` 在配置阶段失败，而不是等到链接时才发现 `zig` 不存在。
2. **声明产物**：`add_custom_command(OUTPUT ...)` 声明 `libmain_zig.a` 由 `zig build` 生成。`WORKING_DIRECTORY` 指向工程根目录（`build.zig` 所在处），`--prefix` 落在 CMake 的二进制目录内，`idf.py fullclean` 能一并清掉，不会污染源码树。
3. **建立顺序**：`zig_main` 是 `ALL` 目标，`add_dependencies(${COMPONENT_LIB} zig_main)` 保证 `main` 组件开始构建前 Zig 库已就绪。`DEPENDS` 让 `build.zig` 或 `main.zig` 变化时重新执行，而不是永远复用旧库。
4. **挂到组件上**：`target_link_libraries(... INTERFACE "${ZIG_LIB}")` 把绝对路径的 `.a` 作为 `main` 组件的接口依赖，最终链接时会出现在链接行里。

构建目录的选择有实际意义：`${CMAKE_CURRENT_BINARY_DIR}` 是 `build/main/`，Zig 的缓存与产物都在 IDF 的构建树内。`idf.py fullclean` 删除 `build/` 后，Zig 库也一起消失，下一次构建重新触发，不会出现"源码改了但链接的是旧库"。

### 5. 根 `CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(zig_s31_hello)
```

IDF 的标准入口：引入 `project.cmake`，声明工程名。工程名决定最终镜像名 `build/zig_s31_hello.bin`。`IDF_PATH` 必须已导出，否则第一行 `include` 就失败。

### 6. `sdkconfig.defaults`

```text
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_ESPTOOLPY_FLASHSIZE="16MB"

CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=y
```

只钉住两件事：

- **16 MB Flash**：模组是 ESP32-S31-WROOM-3 N16R16V。Flash 大小填错，镜像头里的参数与真实芯片不符，轻则烧录校验失败，重则启动循环。
- **single-app-large 分区表**：给应用更大的连续空间，本章不需要 OTA 双槽。分区表类型与 Flash 参数最终以 `idf.py menuconfig` 和生成后的 `sdkconfig` 为准；`sdkconfig.defaults` 只在生成 `sdkconfig` 时生效，已有 `sdkconfig` 时要删除或重新确认。

目标芯片不写在这里：`idf.py --preview set-target esp32s31` 会把目标写进生成的 `sdkconfig`（生成物，不入库）。这样同一份 defaults 不会在切换目标时与 `set-target` 打架。

### 7. 链接顺序：符号是怎么汇合的

把上面几件事串起来看最终链接：

```text
IDF 启动代码 (esp_system)
      │  引用 app_main
      ▼
libmain.a  ──INTERFACE──>  libmain_zig.a
 (idf_anchor.o)              (main.zig 编译出的目标文件)
      │                          │
      │                          ├─ 定义 app_main
      │                          └─ 未定义 esp_rom_printf / esp_rom_delay_us
      ▼                          ▼
            最终链接：libmain_zig.a 提供 app_main；
            ROM 符号由 IDF 的 esp_rom 组件解析
```

三个容易出错的点：

- **静态库按需取用**。链接器只把"被引用且能解决未定义符号"的目标文件从 `.a` 里拉出来。IDF 启动代码引用 `app_main`，所以 `main.zig` 的目标文件会被取用；如果某个函数没人引用，它不会进最终镜像。
- **`.a` 必须在链接集合里**。`INTERFACE` 依赖负责这一点；漏掉它的典型症状是 `undefined reference to 'app_main'`，而不是编译错误。
- **`app_main` 只能有一个定义**。`idf_anchor.c` 不定义它；如果读者额外加了一个 C 的 `app_main`，链接期会报重复符号。这也是本章坚持"C 锚点只做锚点"的原因。

---

## 2.6 构建、烧录、监视与验收

### 1. 构建

```bash
cd practice/zig-esp32-s31/ch02-hello
idf.py --preview set-target esp32s31   # v6.1 preview target；转正后可省略 --preview
idf.py build
```

`set-target` 会生成/重置 `sdkconfig`，把目标固定为 `esp32s31`。只在首次构建或切换芯片时执行；日常增量构建直接 `idf.py build`。

构建过程中应能看到 CMake 打印的 `zig build: libmain_zig.a (riscv32-freestanding-eabihf)`，随后是 IDF 的编译与链接。产物：

```text
build/zig_s31_hello.bin     # 可烧录的应用镜像
build/zig_s31_hello.elf     # 带符号的 ELF，供 GDB/objdump 使用
build/zig_s31_hello.map     # 链接映射，核对段布局
```

### 2. 烧录与监视

```bash
idf.py -p <PORT> flash monitor
```

`<PORT>` 在 Linux 上是 `/dev/ttyUSB0` 一类，在 Windows 上是 `COM7` 一类。板上有两路 USB：**USB-to-UART**（UART0，GPIO58/59）与 **USB Serial/JTAG**。本章日志走 UART0，端口要选 UART 那一侧；`Ctrl+]` 退出监视器。

这里有一条容易误判的边界：`esp_rom_printf` 写的是 **ROM 控制台**，恒定输出到 UART0，不受 IDF 的 console Kconfig 影响。若只接了 USB Serial/JTAG，IDF 自己的日志可能出现在该口，而 `hello s31` 仍只在 UART0 出现——此时应换 UART 桥接口，而不是修改 Zig 代码。

### 3. 预期输出

IDF 的二级 bootloader 会先打印自己的启动日志（版本、Flash 模式与大小、分区表、镜像校验结果），随后跳转到应用。应用侧预期为：

```text
hello s31
tick
tick
tick
```

> [!warning] 预期 ≠ 实测
> 上面的应用输出是代码的直接结果，但**尚未在真机回填**。bootloader 日志的行数与内容随 IDF 版本和 Flash 参数变化，以实际串口为准。真机跑通后，把原始输出存为工程内的 `run.log` 并在 README 标注。

### 4. 镜像解析

```bash
esptool --chip esp32s31 image-info build/zig_s31_hello.bin
```

`image-info` 读取的是镜像本身，不接触芯片。它会打印 8 字节镜像头（magic、段数、Flash 模式/大小/频率、入口地址）、扩展头、各段地址与长度，以及校验和/哈希字段。这是 ch03 手写镜像解析器的对照基线：工具的输出必须和你按格式文档算出来的一致。

### 5. 验收清单

| 检查项       | 命令 / 观察                                         | 状态                 |
| ------------ | --------------------------------------------------- | -------------------- |
| Zig 版本     | `zig version` → `0.17.1`                            | 已验证（写作环境）   |
| 目标能力     | `zig build-lib --show-builtin ...` 的 `builtin.zig` | 已验证（2026-11-12） |
| 目标文件     | `zig build-obj ...` 成功                            | 已验证（同上）       |
| IDF 目标     | `idf.py --preview set-target esp32s31` 无报错       | 待真机验证           |
| 固件构建     | `idf.py build` 产出 `build/zig_s31_hello.bin`       | 待真机验证           |
| 烧录与日志   | 串口出现 `hello s31`，随后每秒 `tick`               | 待真机验证           |
| 镜像解析     | `esptool image-info` 通过                           | 待真机验证           |
| Flash / 分区 | `menuconfig` 为 16 MB、single-app-large             | 待真机验证           |

---

## 2.7 为什么本章不点灯

板上有一颗 RGB LED，接在 GPIO60。它不是"给高电平就亮"的普通 LED，而是可寻址灯珠：颜色与亮度编码在一串脉冲宽度里，需要 RMT（Remote Control Transceiver）按精确时序发送，还要处理复位间隔与刷新周期。

本章的目标是验证**构建链**，不是验证**外设驱动**。如果把 LED 拉进来，一次失败可能来自四个地方：Zig 库没链接、`app_main` 没被调用、RMT 时钟/通道配错、灯珠时序不对。四个变量同时存在时，排错成本远高于收益。

UART 的优势是：ROM 里已有 `esp_rom_printf`，应用不需要初始化任何外设驱动（UART0 已由 IDF 的启动链配置为控制台），不需要额外引脚，输出直接可读。它是 bring-up 阶段最合适的"第一观测点"。

LED 会在后续 RMT/时序章节正式出现：那里会把 RMT 通道、时序参数逐项拆开讲，并用逻辑分析仪验证脉宽。ch06 只做 WS2812/RMT 边界论证，不声称 GPIO60 能亮。到那时，构建链已经被本章验证过，失败只会来自驱动本身。

---

## 2.8 排错

| 现象                                            | 可能原因                                                      | 处理                                                                  |
| ----------------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------- |
| `idf.py: command not found`                     | 没有 source IDF 导出脚本                                      | `. $IDF_PATH/export.sh` 或 `. $env:IDF_PATH\export.ps1`               |
| `idf.py` 报 Python 包错误 / 调用了错误的 Python | 主机 venv、conda 或系统 pip 与 IDF 环境混用                   | 用 IDF 导出后的 `python`；必要时重跑 `install.sh` 重建 Python 环境    |
| 两个 USB 口分不清                               | UART（GPIO58/59）与 USB Serial/JTAG 各枚举一个端口            | 烧录/日志选 UART；调试器选 USB Serial/JTAG；以设备管理器/`lsusb` 为准 |
| CMake 配置阶段报找不到 `zig`                    | Zig 不在 `PATH`，或多个 Zig 版本混用                          | `zig version` 确认；重启终端或 IDE 让 `PATH` 生效                     |
| `undefined reference to 'app_main'`             | Zig 库没进链接集合，或 Zig 构建失败被忽略                     | 检查 `build/main/zig-out/lib/libmain_zig.a`；用 `nm` 看 `app_main`    |
| `undefined reference to '__mulsi3'` 等 builtin  | 代码引入了需要 compiler-rt 的运算，而静态库没打包 compiler-rt | ch02 保持极简；必要时给 Zig 库打开 compiler-rt 打包后重新链接         |
| Zig 报 `build.zig` API 不匹配                   | 版本不是 0.17.1，或脚本沿用了旧 API                           | 对齐版本；删除 `.zig-cache/` 后重试                                   |
| 编译报 target/CPU 非法                          | `-Dtarget`/`-Dcpu` 拼写错误，特性导致不可用组合               | 直接用 `zig build-lib --show-builtin` 复现并核对                      |
| `invalid header` / 上电反复重启                 | Flash size/mode 与模组不符，或镜像不完整                      | 确认 16 MB 配置；`idf.py fullclean` 后重建；用 `image-info` 核对      |
| 烧录时进不了下载模式                            | 自动复位失败                                                  | 按住 BOOT（GPIO61）再复位进入下载模式，然后重试                       |
| 串口无输出                                      | 选错 USB 口、波特率不对、端口被占用                           | 换 UART 口；确认 115200；关闭其他串口工具                             |
| Linux 打开串口权限不足                          | 用户不在 `dialout` 组                                         | 加入 `dialout` 后重新登录                                             |
| 监视器无法退出                                  | 快捷键不熟或终端拦截                                          | `Ctrl+]`；Windows 终端里确认没有被其它程序占用按键                    |
| 切换芯片后构建异常                              | `sdkconfig` 仍是旧目标                                        | `idf.py --preview set-target esp32s31`，必要时先 `idf.py fullclean`   |
| `set-target` 报 `unknown target` / 找不到目标   | v6.1 的 `esp32s31` 仍是 preview target                        | 用 `idf.py --preview set-target esp32s31`；`--preview` 在子命令之前   |

两条排错原则：

1. **先分层，再看日志**。配置期错误（CMake/Zig 参数）、编译期错误（类型/API）、链接期错误（符号/顺序）、运行期错误（启动/外设）是四层，不要拿运行期现象去猜配置问题。
2. **一次只改一个变量**。版本、参数、源码、硬件接线同时动，最后无法归因。本章的清单就是按"单变量"设计的。

---

## 2.9 形态 B 预览：从静态库到自己的镜像

形态 A 跑通后，下一步是把"镜像怎么来"从 IDF 手里接过来。形态 B 的三块拼图：

1. **自定义链接脚本**：显式定义 IROM/DROM/IRAM/DRAM 的段布局、栈顶符号、`.data` 的加载地址与运行地址、`.bss` 的清零范围。IDF 的链接脚本是现成参照，但不再是唯一来源。
2. **`_start`**：复位后第一条指令。它要设置栈指针、清零 `.bss`、把 `.data` 从 Flash 拷到 DRAM、必要时初始化 FPU/中断向量，然后调用 Zig 的入口。RISC-V 的 `_start` 很短，但每一步都要和链接脚本对齐。
3. **`esptool elf2image`**：把 Zig 产出的 ELF 转成 ROM/bootloader 认识的镜像格式：8 字节头 + 扩展头 + 段 + 校验和/SHA256。`image-info` 负责把生成结果读回来核对。

这三块分别在 ch03 与 ch04 展开：

- **ch03** 讲启动链与镜像格式：ROM → 二级 bootloader → 应用，镜像头每个字节的含义，分区表与 OTA 槽的关系；产出是一个手写的镜像解析器，输出必须与 `image-info` 对得上。
- **ch04** 讲链接脚本与内存布局：IRAM/DRAM/IROM/DROM、cache/MMU 约束、PSRAM 初始化、`.data/.bss`、栈，以及最小 `_start`。形态 B 在这一章落地，并从 ch04 起成为主线。

> [!note] 不要跳过 ch03
> 形态 B 最常见的失败不是"代码写错"，而是镜像头/段布局与 bootloader 的期望不一致：入口地址偏了、段长度没对齐、校验和算错。这些问题在串口上通常只表现为一句 `invalid header` 或静默重启。先把格式读明白，再写生成器。

---

## 事实来源

| 事实                                            | 来源                                                                                                                                                                                                                                   | 备注                                                              |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| S31 双核 RV32IMAF C、320 MHz、512 KB SRAM       | [Espressif ESP32-S31 产品页](https://www.espressif.com/en/products/socs/esp32-s31)                                                                                                                                                     | 与系列索引一致                                                    |
| 模组 16 MB Flash + 16 MB PSRAM                  | [ESP32-S31-WROOM-3 Datasheet](https://documentation.espressif.com/esp32-s31-wroom-3_wroom-3u_datasheet_en.pdf)                                                                                                                         | CoreBoard-1 为 N16R16V                                            |
| 板卡接口：千兆以太网、USB HS、USB Serial/JTAG   | [ESP32-S31-Function-CoreBoard-1 User Guide](https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s31/esp32-s31-function-coreboard-1/user_guide.html)                                                                        | UART0 GPIO58/59、RGB LED GPIO60、BOOT GPIO61                      |
| IDF v6.1 支持 `esp32s31`                        | [ESP-IDF v6.1 Get Started (ESP32-S31)](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s31/get-started/index.html)                                                                                                          | `esp32s31` 为 preview target；命令带 `--preview`                  |
| esptool >= 5.2 支持 S31                         | [esptool v5.2.0 Release](https://github.com/espressif/esptool/releases/tag/v5.2.0)                                                                                                                                                     | `--chip esp32s31`、`elf2image`、`image-info`                      |
| Zig 0.17.1 stable                               | [Zig Download](https://ziglang.org/download/)                                                                                                                                                                                          | 2026-11-02 发布                                                   |
| `builtin.zig` 的 `arch/abi/model/features` 取值 | 本章 2026-11-12 在 Zig 0.17.1 / Windows x86_64 上执行 `zig build-lib --show-builtin` 的实测输出                                                                                                                                        | 含 `m/a/c/f/i/zicsr/zifencei` 与推导特性                          |
| `zig build-obj` 可产出 RISC-V 目标文件          | 同上实测                                                                                                                                                                                                                               | 不涉及链接与烧录                                                  |
| 镜像格式：8 字节头 + 扩展头 + 段 + 校验/SHA256  | [esptool Firmware Image Format (ESP32-S31)](https://docs.espressif.com/projects/esptool/en/latest/esp32s31/advanced-topics/firmware-image-format.html)                                                                                 | ch03 逐字段展开                                                   |
| Wi-Fi blob 依赖 FreeRTOS/IDF API                | [IDF v6.1 esp_wifi CMakeLists](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_wifi/CMakeLists.txt)、[esp32s31/esp_adapter.c](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_wifi/esp32s31/esp_adapter.c) | 边界说明，本章不引入无线组件                                      |
| CLIC 48 路/8 级、169 个中断源                   | [esp-hal esp32s31 SoC metadata](https://github.com/esp-rs/esp-hal/blob/667f8f02/esp-metadata/devices/esp32s31/soc.toml)                                                                                                                | 与 TRM 交叉核对；后续章节使用                                     |
| `esp32s31` 是 IDF v6.1 preview target           | [practice/onvif-labs/SPEC.md](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)、[ONVIF 第十一章](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/content/onvif-deep-dive/ch11-esp32s31-lab-plan.md)        | `set-target`/`list-targets` 必带 `--preview`；转正后可省略        |
| S31 的 `ilp32` / `ilp32f` 并存                  | [ESP32-S31 Linux: Instruction set and ABI](https://grieferpig.github.io/esp32-s31-linux-docs/en/hw-reference/isa.html)                                                                                                                 | kernel/radio 用 ilp32f，用户态用 ilp32；IDF 侧以实际 `-mabi` 为准 |

## 自查清单

进入下一章前，确认能回答这些问题：

- [ ] 为什么目标三元组要用 `riscv32-freestanding-eabihf`，而不是裸 `riscv32-freestanding`？如何核对 IDF 侧的实际 ABI（`-mabi`）？
- [ ] `builtin.zig` 里的 `zicsr`、`zifencei` 分别支撑后续哪类操作？`zaamo`/`zca`/`zmmul` 为什么会出现？
- [ ] 形态 A、B、C 的分界线是什么？为什么第一次上电选 A？
- [ ] `app_main` 的定义在哪个文件？C 锚点为什么不能也定义它？
- [ ] `zig build` 的 `--prefix` 为什么指向 `${CMAKE_CURRENT_BINARY_DIR}/zig-out`，而不是源码树里的 `zig-out`？
- [ ] 如果最终链接报 `undefined reference to 'app_main'`，按什么顺序排查？
- [ ] `esp_rom_printf` 与 IDF 的 `printf` 有什么区别？为什么 bring-up 阶段先用前者？
- [ ] 为什么本章不驱动 GPIO60 的 RGB LED？

---

下一章把镜头对准镜像本身：ROM 如何把控制权交给二级 bootloader、bootloader 如何按分区表加载应用、8 字节头与扩展头里每个字段的含义、校验和与 SHA256 各自保护什么。产物是一个手写的镜像解析器，它的输出要与 `esptool image-info` 逐字段对得上——这是形态 B 的前置条件。[[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]。

系列导航：[[ch01-goal-boundary-hardware|上一章]] · [[zig-esp32-s31|系列索引]]
