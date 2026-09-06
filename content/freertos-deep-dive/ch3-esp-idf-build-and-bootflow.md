---
title: "FreeRTOS 深度解析（三）：ESP-IDF 构建体系与固件启动流程"
date: 2026-08-26
description: "拆解 ESP-IDF 的组件化 CMake 构建模型与 sdkconfig/Kconfig 体系，再沿 ROM bootloader → 二级 bootloader → app 的两阶段启动链实读源码：call_start_cpu0 如何变成 start_cpu0、调度器在哪个调用点启动、双核如何先后入场，以及 app_main 被谁调用、返回之后发生什么。"
tags: [freertos, rtos, esp32, esp-idf, cmake, kconfig, bootloader, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 3. **第三章：ESP-IDF 构建体系与固件启动流程**

# FreeRTOS 深度解析（三）：ESP-IDF 构建体系与固件启动流程

第 1 章写下 `app_main()` 时，我们接受了一个没解释的约定：`main()` 不见了，用户入口叫 `app_main`，而且它**返回了也没事**。这一章把这个约定拆开：从 `idf.py build` 背后的组件化 CMake 模型讲起，沿上电复位一路追到 `app_main()` 被调用的那一行源码，顺路回答三个更根本的问题——**调度器是在哪里、被谁启动的**、**第二个核是怎么进场的**、**app_main 返回之后系统为什么还活着**。

读完本章，ESP32 上"从按下复位键到你的第一行代码"之间的每一跳，你都能说出对应的源码文件。

---

## 3.1 组件化构建模型：CMake 的 ESP 方言

### 1. 项目骨架只有三块积木

一个最小的 ESP-IDF 项目长这样（`idf.py create-project` 生成的形状，与 `examples/get-started/hello_world` 一致）：

```text
my_project/
├── CMakeLists.txt          # ① 顶层：声明"这是一个 ESP-IDF 项目"
├── sdkconfig.defaults      # （可选）配置默认值，3.2 节
└── main/
    ├── CMakeLists.txt      # ② 组件注册：告诉构建系统这里有什么
    └── my_project_main.c   # ③ 你的代码，入口 app_main()
```

①和②的内容加起来不到十行。顶层 `CMakeLists.txt`：

```cmake
cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(my_project)
```

`include($ENV{IDF_PATH}/tools/cmake/project.cmake)` 这一行就是 ESP-IDF 构建体系的注入点：它把 `idf_component_register()`、`idf_build_get_property()` 等一整套扩展函数装进 CMake，并在 `project()` 时自动完成工具链选择、目标芯片检测（`IDF_TARGET`，默认 `esp32`）和全量组件扫描。v6 还支持在顶层加一行 `idf_build_set_property(MINIMAL_BUILD ON)` 做"最小构建"——只编 `main` 及其传递依赖，产物更小、编译更快，`hello_world` 例程默认就这么干。

### 2. 组件：ESP-IDF 的唯一模块单位

ESP-IDF 不用 `add_library()`，一切模块都是**组件**（component）。组件就是任何一个带 `CMakeLists.txt`、里面调用了 `idf_component_register()` 的目录，来源有三处：

- `$IDF_PATH/components/` 下的官方组件（一百多个：`freertos`、`esp_system`、`driver`……）；
- 项目根目录的 `components/` 子目录（项目私有组件）；
- 组件管理器（component manager）从网上拉取的托管组件（`idf_component.yml` 声明依赖）。

`main` 也是一个普通组件，只是被构建系统特殊对待（必然编入）。它的 `CMakeLists.txt` 用 `hello_world` 的真实内容做例子：

```cmake
idf_component_register(SRCS "hello_world_main.c"
                       PRIV_REQUIRES spi_flash
                       INCLUDE_DIRS "")
```

`idf_component_register()` 的常用参数：

| 参数                | 作用                                                      |
| ------------------- | --------------------------------------------------------- |
| `SRCS`              | 源文件列表，生成一个静态库 `lib<组件名>.a`                |
| `INCLUDE_DIRS`      | **公共**头文件目录：依赖本组件的人也能 include            |
| `PRIV_INCLUDE_DIRS` | 私有头文件目录：只有本组件自己的源文件可用                |
| `REQUIRES`          | **公共**依赖：本组件的头文件里 include 了谁，会传染给上层 |
| `PRIV_REQUIRES`     | 私有依赖：只有本组件的 `.c` 文件用到了谁，不传染          |
| `LDFRAGMENTS`       | 链接脚本片段（`.lf` 文件，第 21 章的主题）                |

`REQUIRES` 与 `PRIV_REQUIRES` 的区分是整个依赖模型的灵魂：**公共依赖决定"别人 include 我的头文件时还需要谁"，私有依赖只管"编译我自己的源文件"**。把私有依赖误声明成公共依赖，会造成依赖图的虚假传播，编出一堆用不到的组件；反过来则会在别人 include 你的头文件时编译报错。

还有一个容易注意到的现象：`main` 里没写 `REQUIRES freertos`，却可以直接 `#include "freertos/FreeRTOS.h"`。这是因为构建系统维护了一份**公共依赖清单**（`tools/cmake/build.cmake` 中的 `requires_common`，v6.0.2 内容为 `cxx esp_libc freertos esp_hw_support heap log soc hal esp_rom esp_common esp_system esp_stdio`）——清单里的组件被自动追加给每一个组件，FreeRTOS 位列其中。

### 3. 以 freertos 组件为例：一棵会被挑选的树

看官方组件里最关心的 `components/freertos/CMakeLists.txt`，它演示了"用 sdkconfig 结果挑源码"的典型写法：

```cmake
if(CONFIG_FREERTOS_SMP)
    set(kernel_impl "FreeRTOS-Kernel-SMP")
else()
    set(kernel_impl "FreeRTOS-Kernel")
endif()

# 六大内核文件 + 端口层，全部取自 ${kernel_impl}/
list(APPEND srcs "${kernel_impl}/list.c" "${kernel_impl}/queue.c"
                "${kernel_impl}/tasks.c" "${kernel_impl}/timers.c"
                "${kernel_impl}/event_groups.c" "${kernel_impl}/stream_buffer.c")
```

这里必须把第 1 章的源码地图校准到位（第 4 章会展开成完整地图）：

- **`FreeRTOS-Kernel/` 是默认编入的树**，即 **IDF FreeRTOS 本体**——以 Vanilla FreeRTOS v10.5.1 为基线、由 Espressif 做了双核 SMP 改造的 fork，配套的改造说明在 `FreeRTOS-Kernel/idf_changes.md`；
- **`FreeRTOS-Kernel-SMP/` 是另一棵树**：上游 Amazon FreeRTOS 的 SMP 新内核（v11.x 基线），在 IDF 里处于实验状态，由 `CONFIG_FREERTOS_SMP` 显式开启，Kconfig 里它的提示文本就是 "Run the Amazon SMP FreeRTOS kernel instead (FEATURE UNDER DEVELOPMENT)"，默认 `n`；
- `CONFIG_FREERTOS_UNICORE` **不切树**，它只是把不可见选项 `CONFIG_FREERTOS_NUMBER_OF_CORES` 从 2 改成 1（并联动 `ESP_SYSTEM_SINGLE_CORE_MODE`），跑的还是默认那棵 IDF fork 树。

这个 CMakeLists 还有一个和本章主题直接相关的细节——最后这几行：

```cmake
target_link_libraries(${COMPONENT_LIB} INTERFACE "-u app_main")
```

`-u app_main` 强制链接器保留 `app_main` 符号。因为 `app_main()` 定义在你的 `main` 组件里、调用方却在 `freertos` 组件的启动代码中——freertos 无法预知、也不依赖 main，没有这个标记，链接器很可能把"没人引用"的 `app_main` 裁掉。构建系统和启动流程，在这里第一次握手。

### 4. bootloader 是另一个独立工程

`idf.py build` 的产物不止一个 `my_project.bin`。看 `components/bootloader/CMakeLists.txt` 就明白：bootloader 被组织成一个**独立的 CMake 子工程**单独编译链接，产出 `bootloader.bin`，再由构建系统把它注册进烧录镜像列表：

```cmake
esptool_py_flash_target_image(flash bootloader
    ${CONFIG_BOOTLOADER_OFFSET_IN_FLASH}
    "${BOOTLOADER_BUILD_DIR}/bootloader.bin")
```

也就是说 `idf.py flash` 实际烧的是三样东西：`bootloader.bin`（ESP32 上烧在 Flash `0x1000` 处）、分区表（`0x8000`）、应用镜像（分区表指定的偏移，默认单分区工厂镜像在 `0x10000`）。为什么要这么设计，正是下一节的主题。

---

## 3.2 sdkconfig：一个配置文件的三副面孔

### 1. Kconfig → sdkconfig → sdkconfig.h

ESP-IDF 的所有可配置项（数千个）由 **Kconfig** 语言声明，散布在各组件的 `Kconfig` 文件里。三者关系是一条单向流水线：

```text
 组件里的 Kconfig 文件 ──idf.py menuconfig──► sdkconfig ──构建时生成──► build/config/sdkconfig.h
 （声明选项、默认值、        （项目根目录，        （你改出来的        （#define CONFIG_XXX，
   依赖关系）                  通常不进版本库）        那份配置）           供所有源文件 include）
```

- `idf.py menuconfig`：ncurses 菜单，改完写回 `sdkconfig`；
- `idf.py set-target esp32`：换目标芯片（会重生成 sdkconfig）；
- 构建时若 `sdkconfig` 不存在，按"Kconfig 默认值 + sdkconfig.defaults"重新生成；
- `idf.py save-defconfig`：把当前配置与默认值的**差集**存成最小化的 `sdkconfig.defaults`。

### 2. sdkconfig.defaults：团队协作的正确姿势

`sdkconfig` 是**生成物**，几千行、含大量机器状态，惯例上不进版本库。团队的共享配置放在 `sdkconfig.defaults`，只写和默认值不同的项：

```text
# sdkconfig.defaults
CONFIG_FREERTOS_HZ=1000            # tick 从默认 100Hz 提到 1kHz（第 8 章）
CONFIG_ESP_MAIN_TASK_STACK_SIZE=4096
CONFIG_ESPTOOLPY_FLASHSIZE_4MB=y
```

查找顺序（`tools/cmake/project.cmake` 实现的行为）：环境变量 `SDKCONFIG_DEFAULTS` 显式指定的文件 → 项目根的 `sdkconfig.defaults`。而且**每个文件都可以有按目标芯片命名的变体**：`sdkconfig.defaults.esp32` 会叠加在 `sdkconfig.defaults` 之后，多目标项目靠它隔离差异。

### 3. 你已经在用的几个选项

本章后面会自然遇到这些配置项，先挂号：

| 配置项                            | 默认 | 影响                                    |
| --------------------------------- | ---- | --------------------------------------- |
| `CONFIG_FREERTOS_HZ`              | 100  | tick 频率，默认 1 tick = 10ms           |
| `CONFIG_FREERTOS_UNICORE`         | n    | 核数设为 1，CPU1 不上线                 |
| `CONFIG_FREERTOS_SMP`             | n    | 换用实验性 Amazon SMP 内核树（3.1 节）  |
| `CONFIG_ESP_MAIN_TASK_STACK_SIZE` | 3584 | main 任务栈（另有 +512 的冗余，3.6 节） |
| `CONFIG_ESP_MAIN_TASK_AFFINITY`   | CPU0 | main 任务钉在哪个核                     |

> [!note] Vanilla 视角的错位
> Vanilla FreeRTOS 没有 Kconfig/sdkconfig 这一层，裁剪直接改 `FreeRTOSConfig.h` 里的 `#define`。IDF 把它接进了统一配置系统：`FreeRTOSConfig.h` 由模板包含 `sdkconfig.h`，再按 `CONFIG_FREERTOS_*` 翻译成 `configUSE_*` 宏。所以你 grep 内核源码想找 `configTICK_RATE_HZ` 的值时，终点是 sdkconfig，不是某个头文件里的常量。

---

## 3.3 两阶段启动链：从复位到你的 main 组件

### 1. 为什么是"两阶段"

ESP32 的第一级引导程序烧死在**掩膜 ROM**里，出厂后永远不可修改。如果让它直接加载并运行应用，那么 Flash 时序适配、镜像校验、加密、OTA 回滚这些逻辑就必须全部固化在 ROM 里——无法修 bug，更无法演进。所以 ROM 只做最少的事：**把 Flash 固定偏移处的二级 bootloader 装进 RAM 并跳过去**，剩下的交给可以随固件升级的代码。这就是"两阶段启动"（two-stage boot）。

```text
   上电/复位
      │
      ▼
   第一级：ROM bootloader（掩膜 ROM，不可修改）
      · 复位后 PRO CPU 从 ROM 固定地址开始执行，APP CPU 保持复位
      · 按 strapping 引脚决定启动模式（SPI Flash 启动 / 下载模式）
      · SPI Flash 启动：读 0x1000（ESP32）处的 bootloader 镜像头，
        校验后把各段复制进 IRAM/DRAM，跳到入口地址
      │
      ▼
   第二级：ESP-IDF bootloader（bootloader.bin，可随固件升级）
      bootloader_start.c: call_start_cpu0()
        ├─ bootloader_init()          时钟/UART/MMU/SPI Flash/WDT/RNG
        ├─ select_partition_number()  读分区表 + OTA 状态 → 选 app 分区
        └─ bootloader_utility_load_boot_image()
             └─ load_image() → set_cache_and_start_app()
                  · 校验镜像与 SHA-256
                  · 为 IROM/DROM 段配置 Flash→地址空间的 MMU 映射
                  · 把 .data 等加载段复制进 DRAM
                  · 跳到镜像头里的 entry_addr（应用入口）
      │
      ▼
   应用程序（本章下半场）
```

两个容易忽略的细节。其一，bootloader 的入口函数也叫 `call_start_cpu0()`（`components/bootloader/subproject/main/bootloader_start.c`），与应用侧同名——两个独立工程各自的"第一个 C 函数"，读代码时别搞混。其二，bootloader 运行时 flash cache 尚未就绪、APP CPU 还在复位，这些前置条件写在 `bootloader_start.c` 的注释里，决定了它的代码能做什么、不能做什么。

### 2. 分区表：Flash 的目录页

二级 bootloader 先读的元数据是**分区表**，烧在 `0x8000`（ESP32 默认 `ESP_PARTITION_TABLE_OFFSET`），CSV 源文件在项目里维护：

```text
# Name,   Type, SubType, Offset,  Size,    Flags
nvs,      data, nvs,     0x9000,  0x6000,
phy_init, data, phy,     0xf000,  0x1000,
factory,  app,  factory, 0x10000, 1M,
```

它回答"镜像从哪来"：bootloader 依次检查 otadata（OTA 数据分区）指向的 `ota_0/ota_1`、`factory`（出厂镜像）、`test` 分区，找到第一个可引导的 app 分区（`bootloader_utility.c` 的 `bootloader_utility_load_boot_image()`，选不中就 `bootloader_reset()` 重来）。OTA 升级、回滚、双镜像 A/B 切换的全部地基就是这张表加这段选择逻辑。

### 3. 镜像头：app 长什么样

bootloader 拿到分区后，按 `esp_image_format.h` 定义的结构解析镜像。开头是 `esp_image_header_t`：魔数 `0xE9`、段数量、入口地址 `entry_addr`、Flash 工作模式/频率、芯片 ID 等；随后每个段一个 `esp_image_segment_header_t`（加载地址 + 长度）；末尾可附 SHA-256 摘要。段的处理方式分两类：

| 段类型                                        | 目标地址特征                   | 处理方式                                                                                                       |
| --------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `.flash.text`（IROM）/`.flash.rodata`（DROM） | `0x40xxxxxx` / `0x3Fxxxxxx`    | **不搬运**：在 MMU/flash cache 里建立"虚拟地址 → Flash 物理偏移"映射，CPU 取指/取数时按需缓存（XIP，就地执行） |
| `.data`、`.bss` 相关加载段                    | DRAM 地址（`0x3FFBxxxx` 一带） | **复制**进 RAM；`.bss` 由后续启动代码清零                                                                      |

这正是第 2 章内存映射知识的应用现场：所谓"加载固件"，IROM/DROM 段只是填 MMU 页表，真正搬进 RAM 的只有数据段——这也是为什么 `.rodata` 放 Flash 免 RAM，而可写全局变量每一个字节都要占 DRAM（第 21 章展开链接视角）。

最后，`set_cache_and_start_app()` 取出 `entry_addr`，用 `movsp` 把栈切回 ROM 栈、清理现场，然后一次函数指针跳转（源码里就是 `typedef void (*entry_t)(void); entry();`）——控制权移交应用。这个入口地址指向的就是应用侧的启动汇编，很快会走到我们自己的 `call_start_cpu0()`。

---

## 3.4 应用侧启动：call_start_cpu0 与第二核的入场

### 1. CPU0 的 C 入口

应用的 `call_start_cpu0()` 在 `components/esp_system/port/cpu_start.c`，文件注释一句话交代了处境："bootloader 完成加载后来到这里，硬件大多未初始化，另一个 CPU 还在复位，但我们有栈，可以用 C 干活了。"它依次完成：

1. `init_cpu()`：把中断向量表地址设到 IRAM 中的 `_vector_table`；
2. `init_bss()`：清普通 BSS；若不是深度睡眠唤醒，连 RTC 慢速内存的 BSS 一起清（深度睡眠唤醒时 RTC 内存数据要保留）；
3. `ext_mem_init()` / `mspi_init()`：cache/MMU 初始化、CPU 频率调整、（若有）PSRAM 初始化——从这以后 CPU0 才能通过 cache 访问 Flash 上的代码和常量；
4. `system_early_init()`：杂项早期初始化，**内含 `start_other_core()`**；
5. `SYS_STARTUP_FN()`：跳到 `g_startup_fn[核号]`，即 `start_cpu0()`。

### 2. CPU1 是被 CPU0"拽"起来的

`start_other_core()`（同文件）的三个关键动作：

```c
esp_cpu_unstall(1);                                 // 解除 stall
cpu_utility_ll_enable_clock_and_reset_app_cpu();    // 给 APP CPU 上时钟、解除复位
ets_set_appcpu_boot_addr((uint32_t)call_start_cpu1); // 设置 APP CPU 的启动地址
```

复位释放后，CPU1 从 `call_start_cpu1()` 开始跑（也在 `cpu_start.c`）：清自己的中断矩阵、初始化 cache 错误中断、置 `s_cpu_up[1] = true` 报到，然后**自旋等待 `s_resume_cores`**。而 CPU0 在 `do_secondary_init()` 开头调用 `startup_resume_other_cores()` 把它置真。这个闸门的意义源码注释写得很清楚：CPU0 接下来要做的 CORE 阶段初始化会反复开关 cache（初始化 SPI Flash 驱动等），此时 CPU1 绝不能经 cache 碰 Flash——所以先放它跑无关的部分，再统一放行。

### 3. ESP SYSTEM INIT FN：组件向启动流程注册代码的机制

`start_cpu0_default()`（`components/esp_system/startup.c`）不长，但承重：

```c
static void start_cpu0_default(void)
{
    do_core_init();            // ESP SYSTEM INIT FN: CORE 阶段（需要关 cache 的活）
    __libc_init_array();       // C++ 全局构造函数在这里执行！
    do_secondary_init();       // 放行 CPU1，并行执行 SECONDARY 阶段，等所有核完成
    s_system_full_inited = true;
    esp_startup_start_app();   // → 进入 FreeRTOS 世界（下一节）
}
```

两个重点。**其一，`do_system_init_fn()` 遍历的不是手写的调用清单，而是链接器收集的数组**：任何组件用 `ESP_SYSTEM_INIT_FN(名字, {阶段, 核掩码, 优先级})` 宏定义一个初始化函数，链接脚本把它收进 `_esp_system_init_fn_array`，启动代码按阶段（CORE/SECONDARY）和核掩码（哪些核执行它）过滤调用。这是 IDF 版的 initcall 机制——组件向启动流程注入代码，不必改动 `startup.c`。

**其二，`__libc_init_array()` 在 FreeRTOS 启动之前**。C++ 全局构造函数、C 里 `__attribute__((constructor))` 函数都跑在"没有调度器、没有任务"的世界里，此刻它们连 `vTaskDelay()` 都用不了——写过 C++ ESP32 程序的人踩过的"构造函数里不能用 RTOS API"，根源在这里。

CPU1 那边对应的 `start_cpu_other_cores_default()` 被刻意放在 IRAM：它执行 SECONDARY 阶段初始化后，自旋等 `s_system_full_inited`（CPU0 置位），然后进入 `esp_startup_start_app_other_cores()`——下一节的主角之一。

---

## 3.5 调度器在哪个调用点启动

前面所有阶段都运行在"裸"CPU 上：单一执行流、无任务、无调度。现在把它变成 RTOS。

### 1. CPU0：vTaskStartScheduler 的上游和下游

`components/freertos/app_startup.c` 的 `esp_startup_start_app()` 是 CPU0 侧的总装车间：

```c
void esp_startup_start_app(void)
{
    esp_int_wdt_init();              // 中断看门狗
    esp_int_wdt_cpu_init();
    esp_crosscore_int_init();        // 核间中断（第 23 章的基建）

    BaseType_t res = xTaskCreatePinnedToCore(main_task, "main",
                                             ESP_TASK_MAIN_STACK, NULL,
                                             ESP_TASK_MAIN_PRIO, NULL, ESP_TASK_MAIN_CORE);
    assert(res == pdTRUE);

    if (port_start_app_hook != NULL) // 弱符号，端口层可选实现
        port_start_app_hook();

    vTaskStartScheduler();           // ← 调度器在此启动
}
```

注意顺序：**先创建 main 任务，再启动调度器**。`vTaskStartScheduler()`（默认树 `tasks.c`）内部创建每核一个 Idle 任务、软件定时器任务，做完所有内核全局状态初始化后，调用端口层的 `xPortStartScheduler()`——到这一步为止，CPU0 还在启动栈上以普通函数调用链的形式活着；此后一去不返。

`FreeRTOS-Kernel/portable/xtensa/port.c` 的 `xPortStartScheduler()` 逐行都值得读：

```c
BaseType_t xPortStartScheduler( void )
{
    portDISABLE_INTERRUPTS();        // 关中断；首个任务的栈帧里带着"开中断"的 PS，
                                     // 恢复上下文时中断自然恢复
    _xt_coproc_init();               // 协处理器（FPU）任务级管理初始化（第 17 章）
    vPortSetupTimer();               // tick 定时器（port_systick.c，接到 esp_timer/systimer）

    BaseType_t coreID = xPortGetCoreID();
    port_xSchedulerRunning[coreID] = 1;   // 本核调度器运行标志
    port_uxCoreStartupDone[coreID] = 0;   // "核启动完成"清零，稍后由汇编置位

    xthal_window_spill();            // 冲洗全部寄存器窗口到内存！
    __asm__ volatile ("call0    _frxt_dispatch\n");  // 汇编派发第一个任务，不返回
}
```

`xthal_window_spill()` 不是仪式：Xtensa 的寄存器窗口可能还缓存着引用**启动栈**的窗口（第 2 章、第 17 章的主题），而启动栈稍后会被回收成堆内存。不冲干净就切任务，未来的窗口下溢会把垃圾当上下文恢复。`call0 _frxt_dispatch` 则是端口层汇编的"总出口"——它选中最高优先级就绪任务、恢复其栈帧、跳进去，从此 CPU0 的执行流属于任务世界。`call_start_cpu0 → start_cpu0_default → esp_startup_start_app → vTaskStartScheduler → xPortStartScheduler → _frxt_dispatch`，这条链的每一环都不返回。

### 2. CPU1：绕过 vTaskStartScheduler 的入场

CPU1 走的是另一扇门（`app_startup.c` 的 `esp_startup_start_app_other_cores()`）：

```c
void esp_startup_start_app_other_cores(void)
{
    extern volatile unsigned port_xSchedulerRunning[CONFIG_FREERTOS_NUMBER_OF_CORES];
    while (port_xSchedulerRunning[0] == 0) {
        ;                             // 自旋：等 CPU0 把调度器跑起来
    }
    esp_int_wdt_cpu_init();           // CPU1 的中断看门狗
    esp_crosscore_int_init();         // CPU1 的核间中断
    xPortStartScheduler();            // 直接调端口层，不走 vTaskStartScheduler！
    abort();                          // 到这里说明内核坏了
}
```

为什么 CPU1 可以跳过 `vTaskStartScheduler()`？因为该函数做的内核全局初始化（Idle 任务、定时器任务、链表、内核锁）是**系统级**的，CPU0 已经做完；CPU1 只需要启动**本核**的派发。两者靠 `port_xSchedulerRunning[0]` 这个每核数组握手：CPU1 必须等 CPU0 完成，否则会在半初始化的内核状态上开跑。

于是双核的启动时序是这样的（两个核的视角并排）：

```text
   CPU0 (PRO)                                    CPU1 (APP)
   ─────────────────────────                     ─────────────────────────
   esp_startup_start_app()
     ├─ WDT / crosscore int
     ├─ xTaskCreatePinnedToCore(main_task)
     └─ vTaskStartScheduler()
          ├─ 创建 idle(CPU0/CPU1)、timer 任务
          └─ xPortStartScheduler()
               ├─ port_xSchedulerRunning[0] = 1 ──┐
               └─ _frxt_dispatch ─► main_task     │ 自旋等这个标志
                                                 └┴► xPortStartScheduler()
                                                      └─ _frxt_dispatch ─► idle(CPU1)
   main_task 运行：
     等 port_uxCoreStartupDone[] 全 1  ◄── 置位发生在 _frxt_dispatch 里：
     回收两核启动栈为堆                   每核第一次派发任务时，portasm.S
     ESP_LOGI("Calling app_main()")      把 port_uxCoreStartupDone[核] 置 1
     app_main();  ←★ 你的代码
     vTaskDelete(NULL);
```

`port_uxCoreStartupDone` 的置位位置很精妙：不在 C 代码里，而在 `portasm.S` 的 `_frxt_dispatch` 中——它标记的不是"调度器启动函数返回了"（它永不返回），而是"**这个核真的派发出第一个任务了**"。对 CPU1 来说这尤其关键：main 任务要回收两核启动栈，必须确认两个核都已不再使用它们，这个标志就是凭证。

---

## 3.6 app_main：被谁调用，返回之后发生什么

### 1. main 任务的真实身份

调用 `app_main()` 的 `main_task` 就定义在 `app_startup.c`，把与主线相关的部分抽出来：

```c
static void main_task(void* args)
{
    ESP_LOGI(MAIN_TAG, "Started on CPU%d", (int)xPortGetCoreID());

    reclaim_startup_stack_memory_for_heap();   // 等双核就绪 → 回收启动栈为堆
    /* （此处按配置初始化任务看门狗 TWDT） */

    ESP_LOGI(MAIN_TAG, "Calling app_main()");
    extern void app_main(void);
    app_main();                                // ← 你的入口，被普通函数调用
    ESP_LOGI(MAIN_TAG, "Returned from app_main()");
    vTaskDelete(NULL);                         // main 任务自删除
}
```

它的创建参数全部来自 3.2 节那张配置表（`esp_task.h`）：

| 属性   | 值                                                       | 来源                        |
| ------ | -------------------------------------------------------- | --------------------------- |
| 优先级 | 1（`ESP_TASK_MAIN_PRIO = ESP_TASK_PRIO_MIN + 1`）        | 恰好压 Idle（0）一头        |
| 栈     | `CONFIG_ESP_MAIN_TASK_STACK_SIZE`（默认 3584）+ 512 冗余 | 复杂初始化代码的容错        |
| 亲和   | `CONFIG_ESP_MAIN_TASK_AFFINITY`（默认 CPU0）             | menuconfig 可改 CPU1/不绑定 |
| 名字   | `"main"`                                                 | 日志/GDB 里看到的那个       |

所以准确的说法是：**ESP-IDF 里没有"主线程"，只有一个由框架创建、专职派发 `app_main` 的普通任务**。

### 2. Vanilla vs ESP-IDF：两种入口模型

| 维度           | Vanilla FreeRTOS 传统入口                                                            | ESP-IDF app_main 模型                                                         |
| -------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| 用户入口       | `main()`：自己初始化 HAL/时钟，再 `xTaskCreate` 若干任务                             | `app_main(void)`：拿到手时系统已完全初始化（堆、调度器基建、外设框架）        |
| 调度器启动     | `main()` 末尾**手动**调 `vTaskStartScheduler()`，此后不返回                          | 框架在 `esp_startup_start_app()` 里自动调用，用户不碰                         |
| 启动后原执行流 | `main` 所在的启动栈上下文被抛弃，永远不回来；想"main 当任务用"必须自己 `xTaskCreate` | `main` 任务天然存在，`app_main` 就在任务上下文里跑，可以合法调用任何 RTOS API |
| 入口返回       | `main` 返回即跑飞（启动栈上的调用链没有合法去处）                                    | `app_main` 返回是**定义良好**的：main 任务 `vTaskDelete(NULL)` 自删，系统继续 |
| 第二个核       | 不存在（单核假设）                                                                   | CPU1 经 `esp_startup_start_app_other_cores()` 独立入场（3.5 节）              |
| 双核就绪判定   | 无                                                                                   | `port_xSchedulerRunning[]` / `port_uxCoreStartupDone[]` 两级握手              |

这张表是本章的暗线落点。Vanilla 的 `main()+vTaskStartScheduler()` 模型把"系统初始化"和"应用启动"的全部责任压给用户；IDF 则用一个框架级的 main 任务把两者切开——代价是你必须理解这个任务的生命周期，也就是下一小节。

### 3. app_main 返回之后：后果清单

`vTaskDelete(NULL)` 自删之后：

1. **main 任务从所有内核列表消失**，TCB 与栈进入待回收状态，由 Idle 任务实际释放（延迟回收的机制与原因在第 9 章拆）。它不会复活，也没有句柄可找回。
2. **系统照常运行**——`app_main` 里创建的其他任务、定时器、驱动中断都不知道也不关心 main 任务的存在。串口里会多一行 `main_task: Returned from app_main()`，仅此而已。
3. **栈上的一切随之失效**。在 `app_main` 里 `malloc` 的内存没问题（堆的生命周期是系统级的）；但把**局部数组**的指针交给别的任务或中断使用，返回后就是悬垂指针——新手把"入口函数"当"永久存在的家"写的惯性，在这里会变成偶发崩溃。
4. **常见的正确姿势**：`app_main` 只做初始化 + 创建任务，然后返回。返回比 `while(1) vTaskDelay(...)` 挂着更划算——main 任务自删后，它的约 4KB 栈和 TCB 一并回收。

一个容易混淆的对照：第 1 章说过"任务函数 return 是错误"。普通任务确实如此——任务函数走到末尾等于未定义行为（若开启 `CONFIG_FREERTOS_TASK_FUNCTION_WRAPPER`，端口层会用 wrapper 接住、打日志并 `abort()`）。但 `app_main` 不同：它是被 `main_task` **以普通函数调用方式调用**的，返回地址合法地指回 `main_task` 里。同一个"return"，两重身份。

> [!tip] 在 app_main 里忙等循环，可以但通常不对
> `app_main` 里写 `while (1) { ... }` 不会崩——它阻塞的只是优先级 1 的 main 任务，系统其余部分照常调度。但更常见的需求应该用专门的任务表达：合适的优先级、合适的栈深、清晰的名字。把 `app_main` 当最后一个任务用，等于放弃了为它配置这三样的机会。

---

## 3.7 实验：用 QEMU 读一遍启动日志

理论链路有了，现在用第 1 章的环境亲眼看一遍。复用第 1 章的项目：

```bash
cd ~/freertos-ch1
idf.py qemu monitor
```

启动日志（v6.x 典型输出，行号时间戳因环境而异，截取关键段）：

```text
rst:0x1 (POWERON_RESET), boot:0x13 (SPI_FAST_FLASH_BOOT)     ← ROM：复位原因+启动模式
configsip: 0, SPIWP:0xee                                      ← ROM：Flash 采样配置
load:0x3fff0030,len:1184 ... entry 0x400806f4                 ← ROM：装载 bootloader 并跳转
I (28) boot: ESP-IDF v6.0.2 2nd stage bootloader              ← bootloader_init() 打的横幅
I (28) boot: compile time ...                                 ← 编译时间（可配置打印）
I (30) boot: chip revision: v3.0                              ← bootloader 读芯片版本
I (31) boot: Partition Table:                                 ← 分区表解析结果
I (31) boot: ## Label            Usage          Type ST Offset   Length
I (39) boot:  0 nvs              WiFi data        01 02 0x009000 0x006000
...
I (56) boot: Defaulting to factory image                      ← 无 OTA 数据，选 factory 分区
I (xx) boot: Loaded app from partition at offset 0x10000      ← 校验+映射完成
I (xx) cpu_start: Multicore app                                ← system_early_init()，CPU1 将上线
...
I (xx) main_task: Started on CPU0                             ← main_task 第一行日志
I (xx) main_task: Calling app_main()                          ← ★ 你的代码即将执行
[fast] tick 0 (core 0)                                        ← app_main 创建的任务输出
...
I (xx) main_task: Returned from app_main()                    ← app_main 返回，main 任务自删
[fast] tick 1 (core 0)                                        ← 系统继续运行
```

把日志行钉到源码上，一一对应：

| 日志行                                   | 源码位置                                                                                                  |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `rst:0x1 ...` / `load: ... entry ...`    | ROM bootloader（不在仓库里，烧在芯片中）                                                                  |
| `boot: ESP-IDF ... 2nd stage bootloader` | `bootloader_init.c` 的 `bootloader_print_banner()`（由 `bootloader_esp32.c` 的 `bootloader_init()` 调用） |
| `boot: chip revision: v3.0`              | `bootloader_init.c` 的芯片版本打印（`bootloader_init()` 内）                                              |
| `boot: Partition Table:` 及各行          | `bootloader_utility.c` 的分区表打印                                                                       |
| `boot: Defaulting to factory image`      | `bootloader_utility.c` 的 `selected_boot_partition()`（无 otadata 时选 factory）                          |
| `boot: Loaded app from partition ...`    | `bootloader_utility.c` 的 `try_load_partition()`                                                          |
| `cpu_start: Multicore app`               | `cpu_start.c` 的 `system_early_init()`（紧随其后 `start_other_core()` 拉起 CPU1）                         |
| `main_task: Started on CPU0`             | `app_startup.c` 的 `main_task()` 第一条日志                                                               |
| `main_task: Calling app_main()`          | 同上，pytest 测试框架拿它当"应用开始"的标记（源码注释原话）                                               |
| `main_task: Returned from app_main()`    | `vTaskDelete(NULL)` 之前最后一条日志                                                                      |

> [!note] "Starting scheduler on CPUx" 去哪了
> 老教程里常见的 `cpu_start: Starting scheduler on CPU0/APP CPU`，在 v6 的 `app_startup.c` 里已降为 **DEBUG 级**（`ESP_EARLY_LOGD`），默认 INFO 级别看不到。想看完整启动链，在 menuconfig 里把 Component config → Log level 调到 Debug 再跑一遍——你会看到 `esp_startup_start_app` 两兄弟的每一步。

两个延伸玩法（都在 QEMU 里，无需硬件）：

```bash
idf.py qemu gdb        # 编译 + 起 QEMU(带 GDB server) + 起 GDB，断点演示：
(gdb) b app_main       # 你的入口
(gdb) b xPortStartScheduler   # 调度器启动（CPU0/CPU1 各命中一次）
(gdb) b call_start_cpu1       # CPU1 入场
(gdb) c
```

在 `xPortStartScheduler` 断点处 `bt`，能完整看到 3.5 节那条不返回的调用链。真机对照：`idf.py -p /dev/ttyUSB0 flash monitor`，日志内容一致（QEMU 与真机跑同一份二进制），只有时间戳和外设检测细节的差异。

---

## 3.8 小结

- ESP-IDF 的构建单位是**组件**：`idf_component_register()` 声明源文件与 `REQUIRES`/`PRIV_REQUIRES` 依赖（公共传染、私有不传染），freertos 在自动注入的公共依赖清单里；bootloader 是独立编译的子工程，与应用镜像、分区表一起构成 `idf.py flash` 的三件套。
- 配置走 **Kconfig → sdkconfig → sdkconfig.h** 流水线；版本库里放的是差集形式的 `sdkconfig.defaults`（支持 `.esp32` 目标变体）。内核裁剪不在 `FreeRTOSConfig.h` 里改，而在 menuconfig 里改。
- 启动是**两阶段**：ROM bootloader（不可改）从 Flash 0x1000 装载二级 bootloader（可升级），后者读分区表选镜像、建 MMU 映射（XIP 段不搬运）、复制数据段，跳到 `entry_addr`。
- 应用侧链路：`call_start_cpu0()`（清 BSS、cache/MMU、拉起 CPU1）→ `start_cpu0_default()`（链接器收集的 ESP SYSTEM INIT FN 分 CORE/SECONDARY 两阶段并行执行、`__libc_init_array`）→ `esp_startup_start_app()`。
- **调度器启动点**：CPU0 在 `vTaskStartScheduler()` → 端口层 `xPortStartScheduler()` → 汇编 `_frxt_dispatch` 派发第一个任务，永不返回；CPU1 自旋等 `port_xSchedulerRunning[0]` 后直接调 `xPortStartScheduler()` 入场；`port_uxCoreStartupDone`（由 `_frxt_dispatch` 汇编置位）是 main 任务回收启动栈的凭证。
- `app_main` 运行在框架创建的 main 任务里（优先级 1、默认钉 CPU0）；**返回是合法的**——main 任务 `vTaskDelete(NULL)` 自删、栈与 TCB 交给 Idle 回收，系统继续运行。与 Vanilla"main 末尾手动启动调度器"是两种世界观。

下一章终于要推开内核的大门：拿到完整的 FreeRTOS 源码地图——两棵内核树里每个文件的职责与体量、`FreeRTOSConfig.h` 如何由 sdkconfig 生成、编译产物里内核长什么样，以及读这份源码的正确姿势。[[ch4-kernel-source-map|第四章]]见。
