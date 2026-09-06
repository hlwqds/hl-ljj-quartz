---
title: "ESP32-S3-BOX-3 工程实战（四）：工程解剖与组件体系"
date: 2026-08-26 12:00:00
description: "从 hello_world 的三行 CMakeLists 到 factory_demo 的分区表、组件注册表依赖与 sdkconfig.defaults：逐层解剖一个 ESP-IDF 工程，看清组件从哪来、依赖怎么解析、一块板子的硬件约束如何浓缩进一个配置文件。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（四）：工程解剖与组件体系

第一章我们把 factory_demo 编译烧录跑了起来，但没有回答一个问题：**这个工程凭什么能被构建出来**。本章做一次完整的工程解剖——从最小工程 hello_world 的三行 CMakeLists 开始，到 factory_demo 的分区表、三种组件来源、Kconfig 三角，最后落在"一块板子的全部硬件约束都写在一个文件里"这个结论上。所有引用的文件内容均为本地实地读取（esp-idf v6.0.2、esp-box 仓库），非凭记忆转述。

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch3-idf-toolchain|第三章：idf.py 背后——工具链与命令面]]
> **第四章：工程解剖与组件体系**（当前章）
> 下一章：[[ch5-image-and-flashing|第五章：编译产物与烧录链路]]

---

## 4.1 最小工程解剖：hello_world 总共只有六个文件

先看本地 `$IDF_PATH/examples/get-started/hello_world/` 的真实清单（目录实地核对）：

```text
hello_world/
├── CMakeLists.txt            # 工程级：声明"这是一个 ESP-IDF 工程"
├── README.md
├── pytest_hello_world.py     # CI 测试脚本，与构建无关
├── sdkconfig.ci              # CI 专用配置片段（4.5 节展开）
└── main/
    ├── CMakeLists.txt        # 组件级：注册 main 组件
    └── hello_world_main.c    # app_main() 住在这里
```

注意：**没有** `sdkconfig`（首次构建才生成）、**没有** `idf_component.yml`（无托管依赖）、**没有** `dependencies.lock`。这三者的缺席本身就是信息——最小工程不需要它们中的任何一个。

### 1. 顶层 CMakeLists.txt：三行必需 + 一行可选

```cmake
cmake_minimum_required(VERSION 3.22)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# "Trim" the build. Include the minimal set of components, main, and anything it depends on.
idf_build_set_property(MINIMAL_BUILD ON)
project(hello_world)
```

| 语句                                                | 作用                                                                        |
| --------------------------------------------------- | --------------------------------------------------------------------------- |
| `cmake_minimum_required(VERSION 3.22)`              | 声明最低 CMake 版本，必须在第一行；v6 要求 3.22+                            |
| `include($ENV{IDF_PATH}/tools/cmake/project.cmake)` | 导入 ESP-IDF 构建系统本体：组件检索、工具链选择、目标芯片设定全在这之后发生 |
| `idf_build_set_property(MINIMAL_BUILD ON)`          | 可选（v6 新示例才有）：只编 main 及其依赖，砍掉无关组件加速构建             |
| `project(hello_world)`                              | 创建工程；工程名直接决定产物文件名 `hello_world.elf` / `hello_world.bin`    |

`project.cmake` 里具体做了什么（组件怎么被收集、`EXTRA_COMPONENT_DIRS` 怎么生效、bootloader 为什么是独立工程）在 [[ch3-esp-idf-build-and-bootflow|FreeRTOS 系列第三章]] 已按源码走读，本章不重复，只从**使用视角**取结论。

### 2. main/：一个名字特殊的组件

官方文档原话：**"main 目录是一个特殊的组件"**。特殊在两点：

1. 它被自动加入构建，无需在 `EXTRA_COMPONENT_DIRS` 里声明；
2. 它**自动依赖所有其他组件**——所以 main 里的代码 `#include` 任何组件的头文件都不需要写 `REQUIRES`。

`main/CMakeLists.txt` 全文只有三行有效内容：

```cmake
idf_component_register(SRCS "hello_world_main.c"
                       PRIV_REQUIRES spi_flash
                       INCLUDE_DIRS "")
```

`idf_component_register` 是组件向构建系统报到的唯一入口（参数语义 4.3 节详表）。这里有个值得琢磨的细节：既然 main 自动依赖一切，为什么还要写 `PRIV_REQUIRES spi_flash`？答案就在上面那行 `MINIMAL_BUILD`——裁剪构建后"自动依赖所有组件"的特权没了，main 必须像普通组件一样显式声明依赖，否则 spi_flash 根本不会进构建。最小示例与最简依赖在这里形成了自洽。

---

## 4.2 对照真实工程：factory_demo 比 hello_world 多了什么

### 1. 顶层 CMakeLists.txt 的增量

factory_demo 的工程级 CMakeLists（实地读取，esp-box 仓库）：

```cmake
cmake_minimum_required(VERSION 3.5)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

set(EXTRA_COMPONENT_DIRS
    ../../components
    )

add_compile_options(-fdiagnostics-color=always
                    -Wno-ignored-qualifiers
                    -Wno-deprecated-declarations
                    -Wno-unused-but-set-variable)

project(factory_demo)
```

与 hello_world 逐项对照：

| 差异                                         | 含义                                                                                                                                      |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `cmake_minimum_required(VERSION 3.5)`        | 版本要求更旧——esp-box 的 CI 矩阵覆盖 release-v5.1 到 v5.5 五个 IDF 版本，示例要迁就下限                                                   |
| `set(EXTRA_COMPONENT_DIRS ../../components)` | 把 `esp-box/components/` 纳入组件搜索路径，那里面住着 `bsp` 组件（第十四章走读对象）——相对路径以工程目录为基准，指向仓库根下的 components |
| `add_compile_options(...)`                   | 全工程编译选项：强制彩色诊断 + 压制三类警告（示例代码 pragmatism）                                                                        |
| 没有 `MINIMAL_BUILD`                         | 恰恰相反，factory_demo 要吃下几十个组件                                                                                                   |

### 2. main/CMakeLists.txt：真实工程的组件注册长什么样

```cmake
file(GLOB_RECURSE LV_DEMOS_SOURCES ./*.c)

idf_component_register(
    SRC_DIRS
        "."
        "app"
        "gui"
        "gui/font"
        "gui/image"
        "rmaker"

    INCLUDE_DIRS
        "."
        "gui"
        "app"
        "rmaker")

target_compile_options(${COMPONENT_LIB} PRIVATE "-Wno-format" "-Wno-deprecated-declarations")
target_compile_definitions(${COMPONENT_TARGET} PRIVATE "-D RMAKER_DEMO_PROJECT_NAME=\"${CMAKE_PROJECT_NAME}\"")
set_source_files_properties(${LV_DEMOS_SOURCES} PROPERTIES COMPILE_OPTIONS -DLV_LVGL_H_INCLUDE_SIMPLE)

spiffs_create_partition_image(storage ../spiffs FLASH_IN_PROJECT)
```

比 hello_world 多出的每一件都对应一个真实需求：

- **`SRC_DIRS` 替代 `SRCS`**：源文件多到不想逐个列（gui/image 下有三十多个图标 C 文件），直接按目录收编；
- **`target_compile_definitions`**：把工程名注入 RainMaker demo；
- **`spiffs_create_partition_image(storage ../spiffs FLASH_IN_PROJECT)`**：构建期用 `spiffsgen.py` 把 `../spiffs/` 目录（两首 MP3、八段中英文提示音 wav）打包成 SPIFFS 镜像；`FLASH_IN_PROJECT` 使 `idf.py flash` 时一并烧进 `storage` 分区。此函数定义在 `$IDF_PATH/components/spiffs/project_include.cmake`，实现已实地核实——它还会向分区表查询该分区的 offset/size 来决定镜像参数。

### 3. partitions.csv：一张分区表读懂整机布局

factory_demo 使用自定义分区表（由 `sdkconfig.defaults` 中 `CONFIG_PARTITION_TABLE_CUSTOM=y` 启用）。逐行解读：

```csv
# Name,   Type, SubType, Offset,  Size, Flags
sec_cert, data, ,        0xd000,  0x3000,
nvs,      data, nvs,     0x10000, 0x6000,
otadata,  data, ota,     ,        0x2000,
phy_init, data, phy,     ,        0x1000,
fctry,    data, nvs,     ,        0x6000,
ota_0,    app,  ota_0,   ,        4200K,
# ota_1,    app,  ota_1,   ,        2700K,
storage,  data, spiffs,  ,        2600K,
model,    data, spiffs,  ,        8600K,
```

| 分区       | 类型        | 大小          | 作用                                                                                                                                   |
| ---------- | ----------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `sec_cert` | data        | 12KB @0xd000  | RainMaker 自声明（self-claim，见 defaults 里 `CONFIG_ESP_RMAKER_SELF_CLAIM=y`）写入的设备证书；挤在分区表（0x8000）与 nvs 之间的夹缝里 |
| `nvs`      | data/nvs    | 24KB @0x10000 | 系统键值存储：WiFi 凭据、用户设置（第七章实验主角）                                                                                    |
| `otadata`  | data/ota    | 8KB           | OTA 启动数据：记录从哪个 ota 分区启动、回滚状态                                                                                        |
| `phy_init` | data/phy    | 4KB           | RF 校准数据，每块板出厂/首启标定                                                                                                       |
| `fctry`    | data/nvs    | 24KB          | 第二个 nvs 分区，存出厂数据（RainMaker claiming 相关的 UUID 等）                                                                       |
| `ota_0`    | app         | 4200KB        | 应用本体，全工程唯一 app 分区                                                                                                          |
| `storage`  | data/spiffs | 2600KB        | 资源分区：构建期由 `spiffs/` 目录生成的提示音/MP3                                                                                      |
| `model`    | data/spiffs | 8600KB        | esp-sr 语音模型分区（见 4.5 节 CONFIG*SR*\* 选项）                                                                                     |

三个观察：

1. **`ota_1` 被注释掉了**。OTA 双分区是标准姿势，但 16MB Flash 塞不下双 app + 双模型，作者做了空间换功能的取舍——注释而非删除，说明这是有意识的裁剪。
2. **model 分区（8600K）比应用本体（4200K）大一倍**。这是边缘 AI 设备的直观一课：唤醒词 + 中英文命令词模型的体积超过全部业务代码。分区名 `model` 与 esp-sr 的模型加载约定对应。
3. **Offset 列大部分留空**——构建工具按行序自动排布，只有 `sec_cert`（0xd000）和 `nvs`（0x10000）显式钉死。合计约 15.1MiB，16MB Flash 只剩不到 1MiB 余量。

这张表编译后会变成二进制分区表烧到 Flash 0x8000 处，bootloader 靠它找 app——完整链路是第五章的主题。

---

## 4.3 组件模型：ESP-IDF 的唯一模块单位

### 1. 什么是组件

构建系统的定义很干脆：**`COMPONENT_DIRS` 搜索路径下任何包含 `CMakeLists.txt` 的目录都是组件**。默认搜索路径为 `$IDF_PATH/components`、`$PROJECT_DIR/components` 和 `EXTRA_COMPONENT_DIRS`（4.4 节）。

```text
my_component/
├── CMakeLists.txt        # 必须：idf_component_register 在这里
├── include/              # 惯例：公共头文件（对依赖者可见）
├── priv_include/         # 惯例：私有头文件（仅本组件源文件可见）
├── Kconfig               # 可选：本组件的 menuconfig 选项
├── Kconfig.projbuild     # 可选：出现在 menuconfig 顶层的选项（4.5 节）
├── project_include.cmake # 可选：向包含它的工程注入构建逻辑
└── src/*.c               # 源文件
```

### 2. idf_component_register 参数语义

| 参数                | 语义                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------- |
| `SRCS` / `SRC_DIRS` | 编入组件库的源文件；后者按目录收编（factory_demo 用法）                               |
| `INCLUDE_DIRS`      | **公共** include 目录：会加进"所有依赖本组件的组件"的搜索路径，随公共依赖**递归传播** |
| `PRIV_INCLUDE_DIRS` | 私有头文件目录，只对本组件源文件可见                                                  |
| `REQUIRES`          | **公共依赖**：本组件**公共头文件**里 `#include` 到的组件                              |
| `PRIV_REQUIRES`     | **私有依赖**：仅本组件**源文件**用到、或只需链接其符号的组件                          |

公共/私有的判据就一句话：**头文件里 include 了谁，谁就必须进 `REQUIRES`；只在 .c 文件里用的，进 `PRIV_REQUIRES`**。二者近似于 CMake 的 `target_link_libraries(... PUBLIC/PRIVATE ...)`。私有依赖不传染 include 路径——好处是下游编译器命令行更短、全量编译更快。

### 3. 两条免申报通道与一类典型报错

并不是所有依赖都要写。构建系统给每个组件预置了**通用依赖**：`cxx`、`esp_libc`、`freertos`、`esp_hw_support`、`heap`、`log`、`soc`、`hal`、`esp_rom`、`esp_common`、`esp_system`——所以 `#include "freertos/FreeRTOS.h"` 从不需要声明。另一条就是 4.1 节说的 main 特权（自动依赖全部组件）。

越过这两条通道还忘写 `REQUIRES`，报错分两种：

- **头文件路径没拿到**：编译期直接 `fatal error: xxx.h: No such file or directory`——include 搜索路径是按依赖关系展开的，没声明就没有路径（这是最常见的形态）；
- **路径靠别的组件传递拿到了，但链接符号缺**：拖到链接期才爆 `undefined reference to ...`，更隐蔽。

另有一条硬规则：`REQUIRES` / `PRIV_REQUIRES` 的值**不能依赖 `CONFIG_xxx` 配置项**——依赖在配置加载之前就展开完了，配置还没出生。需要按配置区分时，只能用两个组件 + Kconfig `depends on` 选择性收编的办法绕行。

### 4. 同名组件的优先级

四个来源出现同名组件时，优先级从高到低：**工程 `components/` > `EXTRA_COMPONENT_DIRS` > `managed_components/` > `$IDF_PATH/components`**。这意味着把 IDF 内置组件复制进工程同名目录即可实现"本地覆盖官方实现"而不动 IDF 源码；代价是从此吃不到官方更新。移动组件位置后需 `idf.py reconfigure` 才能被重新发现。

---

## 4.4 三种组件来源与落点

| 来源       | 落点                            | 谁放进去       | factory_demo 里的例子            |
| ---------- | ------------------------------- | -------------- | -------------------------------- |
| IDF 内置   | `$IDF_PATH/components/`         | IDF 发行版     | freertos、esp_driver、spiffs     |
| 工程本地   | `<project>/components/`         | 你手写         | （未用，esp-box 走了下一种）     |
| 额外目录   | `EXTRA_COMPONENT_DIRS` 指定     | 你指定         | `esp-box/components/bsp`         |
| 注册表托管 | `<project>/managed_components/` | 组件管理器下载 | esp-sr、esp_rainmaker、qrcode 等 |

托管组件的声明在 `main/idf_component.yml`（组件清单，manifest），factory_demo 的清单实地读取如下：

```yaml
## IDF Component Manager Manifest File
dependencies:
  idf: ">=5.1"

  chmorgan/esp-audio-player: 1.0.5
  chmorgan/esp-file-iterator: 1.0.0

  espressif/esp_rainmaker: ~1.1.0
  espressif/esp_schedule: ~1.1.0
  espressif/esp-sr: 1.4.*
  espressif/led_strip: ~2.0.0
  espressif/qrcode: ^0.1.0
  espressif/ir_learn: ^0.1.0
  espressif/aht20: ^0.1.0
  espressif/at581x: ^0.1.0
```

最后一列两行不是 espressif 命名空间的——第三方作者（chmorgan）也能向注册表发布组件。对照 [[ch2-ecosystem-map|第二章]] 的生态地图：`ir_learn`/`aht20`/`at581x` 恰好对应 SENSOR 板的红外学习、温湿度（AHT20）、微波雷达（AT581X）——板上一颗传感器一个托管组件。

### 1. 版本约束语法逐个读

语义依官方 versioning 规则（已对照文档核实）：

| 写法      | 名称   | 允许范围        | 一句话语义                                                                     |
| --------- | ------ | --------------- | ------------------------------------------------------------------------------ |
| `'>=5.1'` | 下限   | 5.1 及以上      | 特殊键 `idf` 约束的是 **IDF 本体版本**，不是注册表组件                         |
| `1.0.5`   | 裸版本 | ==1.0.5         | 无操作符默认**精确钉死**，补丁级更新也不收                                     |
| `1.4.*`   | 通配   | >=1.4.0, <1.5.0 | 钉住主版本.次版本，放开补丁位                                                  |
| `~1.1.0`  | tilde  | >=1.1.0, <1.2.0 | 允许补丁级变化                                                                 |
| `^0.1.0`  | caret  | >=0.1.0, <0.2.0 | 允许"不改变最左非零位"的更新；0.x 组件最左非零位是次版本，所以实际只放开补丁位 |

注意 `~1.1.0` 与 `1.4.*` 在数值区间上同型（都钉前两位、放补丁位），语义来源不同：前者是"兼容该版本的次版本内更新"，后者是通配符匹配。而 `^0.1.0` 对 0.x 组件（qrcode、ir_learn、aht20、at581x 全是）等效于只放开补丁位——这些年轻组件用 caret 表达"修复可以收，破坏性变更不要"，分寸恰当。

### 2. 清单如何变成 managed_components

CMake 配置阶段（`idf.py reconfigure` 或首次 build）组件管理器自动完成三件事：解析工程内**所有**组件的 `idf_component.yml`（包括托管组件自带的清单，递归解析）→ 把解析结果下载到 `managed_components/` → 在工程根生成 `dependencies.lock` 记录每个依赖的**精确版本**。相关命令：`idf.py add-dependency`（追加依赖）、`idf.py update-dependencies`（按清单约束重新求解并更新 lock）。

Git 策略随之明确：**`dependencies.lock` 要提交**（它把区间约束固化成精确版本，保证别人 checkout 后拿到一模一样的组件树），**`managed_components/` 不提交**（构建时按 lock 自动恢复，官方文档明言该目录通常不入版本控制、且不应手改）。

---

## 4.5 Kconfig / menuconfig / sdkconfig 三角

### 1. 三者的分工

```text
Kconfig / Kconfig.projbuild     （选项定义：名字、类型、默认值、依赖关系）
        │
        │  idf.py menuconfig（交互界面，改的是"值"）
        ▼
sdkconfig                       （当前工程的全部配置值，机器可读文本）
        │
        │  构建期生成
        ├──> build/config/sdkconfig.h   （给 C 代码的 #define CONFIG_xxx）
        └──> CMake 里的 CONFIG_xxx 变量  （给构建脚本的条件判断）
        ▲
        │  idf.py set-target 时作为种子写入
sdkconfig.defaults              （你手工维护的"期望配置"）
```

关键认知：**sdkconfig 是生成物，sdkconfig.defaults 才是你的**。`idf.py set-target esp32s3` 会以 defaults 为种子重新生成 sdkconfig——直接手改 sdkconfig 的任何内容，下次 set-target 就会被冲掉。团队协作的正确姿势是只维护 defaults（menuconfig 改完把 diff 摘进 defaults）。

### 2. Kconfig 与 Kconfig.projbuild 的区别：BSP 选板实例

普通 `Kconfig` 的选项收在 menuconfig 的 "Component settings" 子菜单深处；`Kconfig.projbuild` 的选项则出现在**顶层菜单**——需要用户主动做选择的配置（比如"这是哪块板"）要的就是这种曝光度。esp-box 的 `components/bsp/Kconfig.projbuild`（实地读取，节选）：

```text
menu "HMI Board Config"
    choice BSP_LCD_BOARD
        prompt "Select BSP board"
        default BSP_BOARD_ESP32_S3_BOX_3

        config BSP_BOARD_ESP32_S3_BOX
            bool "BSP board ESP32-S3-BOX"
        config BSP_BOARD_ESP32_S3_BOX_Lite
            bool "BSP board ESP32-S3-BOX-Lite"
        config BSP_BOARD_ESP32_S3_BOX_3
            bool "BSP board ESP32-S3-BOX-3"
    endchoice
endmenu
```

同一个 esp-box 仓库要伺候三代板子，靠这一个 choice + 下面的 sdkconfig.ci 文件实现多板构建。这份 Kconfig 里还藏着另一个信息：默认值就是 BOX_3——当前主推板型。

### 3. sdkconfig.defaults：一块板子的硬件约束全书

factory_demo 的 sdkconfig.defaults 共 80 余行，摘核心片段（实地读取）：

```text
CONFIG_IDF_TARGET="esp32s3"
CONFIG_ESPTOOLPY_FLASHMODE_QIO=y
CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_240=y
CONFIG_SPIRAM=y
CONFIG_SPIRAM_MODE_OCT=y
CONFIG_SPIRAM_SPEED_80M=y
CONFIG_PM_ENABLE=y
CONFIG_PM_DFS_INIT_AUTO=y
CONFIG_EXAMPLE_MAX_CPU_FREQ_240=y
CONFIG_EXAMPLE_MIN_CPU_FREQ_40M=y
CONFIG_SR_WN_WN9_HILEXIN_MULTI=y
CONFIG_SR_WN_WN9_HIESP_MULTI=y
CONFIG_SR_MN_CN_MULTINET6_QUANT=y
CONFIG_SR_MN_EN_MULTINET6_QUANT=y
CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y
CONFIG_FREERTOS_HZ=1000
CONFIG_FREERTOS_USE_TICKLESS_IDLE=y
```

逐项对应 BOX-3 的硬件事实（N16R8V 模组：双核 Xtensa LX7、16MB Flash、8MB **Octal** PSRAM）：

| 配置行                                                        | 对应的硬件/产品事实                                                            |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `CONFIG_IDF_TARGET="esp32s3"`                                 | 目标是 S3 而非经典 esp32                                                       |
| `FLASHSIZE_16MB` + `FLASHMODE_QIO`                            | 16MB 四线 Flash（N16 中的 16）                                                 |
| `SPIRAM=y` + `MODE_OCT` + `SPEED_80M`                         | 8MB 八线 PSRAM 80MHz（R8V 中的 R8=8MB、V=Octal）——LVGL、语音缓冲全靠它         |
| `CPU_FREQ_MHZ_240` + `MAX_240`/`MIN_40M` + `PM_DFS_INIT_AUTO` | 240MHz 满速跑 AI，空闲时 DFS 动态降到 40MHz 省电                               |
| `SR_WN_WN9_HILEXIN_MULTI` / `WN9_HIESP_MULTI`                 | WakeNet9 多唤醒词：中文"Hi 乐鑫"+ 英文"Hi ESP"同时在线（第一章体验到的唤醒词） |
| `SR_MN_CN/EN_MULTINET6_QUANT`                                 | MultiNet6 量化版中英文命令词模型——正是 4.2 节 model 分区 8600K 的住户          |
| `ESP_CONSOLE_USB_SERIAL_JTAG=y`                               | 控制台走板载 USB-Serial-JTAG（第一章 `/dev/ttyACM*` 的由来）                   |
| `FREERTOS_HZ=1000` + `USE_TICKLESS_IDLE`                      | 1ms tick + tickless 空闲，配合 DFS 组成低功耗三件套                            |

一句话结论：**换一块板子 = 换一份 sdkconfig.defaults**。Flash 型号、PSRAM 模式、频段策略、唤醒词选择、控制台通道，全部集中在这一个文件里，main/CMakeLists.txt 一行都不用动。sdkconfig 体系更深的机制（三副面孔、defaults 的合并次序）在 [[ch3-esp-idf-build-and-bootflow|FreeRTOS 系列第三章]] 3.2 节，此处不重复。

### 4. sdkconfig.ci.box-3：CI 怎么多板测试

factory_demo 目录下有三个文件：`sdkconfig.ci.box`、`sdkconfig.ci.box-lite`、`sdkconfig.ci.box-3`。box-3 的全文只有两行：

```text
# BSP
CONFIG_BSP_BOARD_ESP32_S3_BOX_3=y
```

机制已从 esp-box 的 `tools/build_apps.py` 实地核实：其默认配置规则 `sdkconfig.ci.*=` 把每个 `sdkconfig.ci.<名字>` 文件**追加**到 `sdkconfig.defaults` 之后，生成一个名为 `<名字>` 的构建任务——即"defaults 打底，ci 片件按板覆盖"。三个片段就是三个板的构建矩阵；`.gitlab/ci/build.yml` 里 factory_demo 还同时挂在 release-v5.1 到 v5.5 五个 IDF 镜像上并行编译。多板多版本的组合测试，就是靠这几行配置文件自动化完成的。

---

## 4.6 读者练习

**练习一：给 factory_demo 加一个本地组件**（步骤描述级，以下预期均**待验证**——我未在本机执行构建）：

1. 建 `components/my_led/` 目录，放 `CMakeLists.txt`、`include/my_led.h`、`my_led.c`；
2. CMakeLists 写 `idf_component_register(SRCS "my_led.c" INCLUDE_DIRS "include" PRIV_REQUIRES led_strip)`——led_strip 已在清单里（4.4 节），托管组件的依赖照常可用；
3. `main.c` 里 `#include "my_led.h"` 调用；
4. `idf.py build`。预期：`components/` 目录在默认搜索路径里，**不需要改顶层 CMakeLists.txt**，构建日志应出现 my_led 组件被编入的记录。

**练习二：menuconfig 改一个选项再构建**：

1. `idf.py menuconfig`，定位 Component settings → BSP → LCD draw buffer height（对应 `CONFIG_BSP_LCD_DRAW_BUF_HEIGHT`，defaults 里为 10）改为 50，保存退出；
2. `idf.py build`。预期（**待验证**）：sdkconfig 中该行更新为 50，`build/config/sdkconfig.h` 对应宏变化，引用该宏的 bsp/LVGL 相关源文件被增量重编，其余不动；刷屏帧率是否可感知变化需真机验证（第十章的实验正好覆盖）；
3. 若确认要保留，把 `CONFIG_BSP_LCD_DRAW_BUF_HEIGHT=50` 摘进 `sdkconfig.defaults`——否则下次 set-target 就丢了（4.5 节第 1 小节）。

---

## 4.7 翻车点表与小结

| 症状                                            | 根因                                                                          | 处理                                                                                      |
| ----------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 构建停在组件下载，超时/连接失败                 | 组件管理器需访问 components.espressif.com，网络不通                           | 解决网络后 `idf.py reconfigure` 触发重下；长期方案是自建代理或离线注入 managed_components |
| `fatal error: xxx.h: No such file or directory` | 组件 A 的源文件用了组件 B 的头文件但没写 `REQUIRES`/`PRIV_REQUIRES`（4.3 节） | 按判据补声明：头文件里用的进 REQUIRES，仅 .c 用的进 PRIV_REQUIRES                         |
| 手改的 sdkconfig 选项莫名消失                   | `idf.py set-target` 会以 defaults 为种子**重新生成** sdkconfig                | 配置只写进 sdkconfig.defaults；sdkconfig 视为纯生成物                                     |
| REQUIRES 里想按 CONFIG 分支，CMake 直接报错     | 依赖展开早于配置加载（4.3 节）                                                | 拆成两个组件，用 Kconfig `depends on` 选择性收编                                          |
| 想改官方组件，改完不生效或污染 IDF              | 直接改了 `$IDF_PATH/components` 或 `managed_components`                       | 复制到工程 `components/` 同名覆盖（优先级最高），改完 `idf.py reconfigure`                |
| `dependency.lock` 要不要提交？                  | ——                                                                            | **要**：把版本区间固化成精确版本，保证可复现构建（文档明言勿手编，它是生成物但应当入库）  |
| `managed_components/` 要不要提交？              | ——                                                                            | **不要**：加 `.gitignore`；构建按 lock 自动恢复，目录本身是纯缓存                         |

本章小结：

- **工程 = 顶层三行 CMakeLists + main 组件 + 配置文件**。顶层只负责"点火"（导入 project.cmake、声明工程名、可选地扩搜索路径）；main 是自动依赖一切的特殊组件，最小示例的 `MINIMAL_BUILD` 则收回了这个特权。
- **factory_demo 的增量每一件都有名有姓**：自定义分区表（16MB 被 app/资源/语音模型瓜分到只剩不到 1MiB）、SPIFFS 资源镜像、BSP 额外组件目录、十余个注册表依赖。
- **组件依赖只有两个关键词**：REQUIRES（公共，随头文件传播）与 PRIV_REQUIRES（私有，只管自己链接）；记不住时回到判据——"头文件里 include 了谁，谁就是公共依赖"。
- **三种来源四级优先**：工程 components > EXTRA_COMPONENT_DIRS > managed_components > IDF 内置；同名即覆盖。
- **sdkconfig.defaults 是板子的身份证**：BOX-3 的 Flash/PSRAM/DFS/唤醒词/控制台全部浓缩于此；`sdkconfig.ci.*` 片件让同一仓库三块板五个 IDF 版本地毯式过 CI。

下一章进入 build 目录：bootloader、分区表、app 三镜像如何生成与烧录，0x8000 这个 4.2 节埋下的地址将在那里兑现。
