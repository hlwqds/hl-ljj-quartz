---
title: "ESP32-S3-BOX-3 工程实战（十四）：esp-box-3 BSP 组件走读"
date: 2026-08-26 12:00:00
description: "实地走读 esp-box 仓库的 bsp 组件与注册表 espressif/esp-box-3（1.1.3）板级组件：选板 Kconfig 与 CMake 的正则把戏、bsp_display_start 的初始化编排、运行时双屏幕探测、引脚定义头文件全文对账——第八到十三章的外设在这里收拢成一层。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（十四）：esp-box-3 BSP 组件走读

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch13-timers-watchdogs|第十三章：定时器与看门狗]]
> **第十四章：esp-box-3 BSP 组件走读**（当前章）
> 下一章：[[ch15-lvgl|第十五章：LVGL]]

第八到十三章把 GPIO、I2C、SPI、I2S、RMT、定时器逐个拆完，但一直有个问题悬着：**这些外设是谁、按什么顺序、用哪些引脚组织成一整块板子的？** 答案就是 BSP（Board Support Package，板级支持包）。本章的素材全部来自本地实地走读：`~/esp/esp-box/components/bsp` 全目录，加上 factory_demo 构建现场留下的 `managed_components/espressif__esp-box-3`（版本由 `dependencies.lock` 实测钉死为 1.1.3），注册表页面另做了核实。各外设的驱动细节不再重复，逐一指回对应章节。

---

## 14.1 BSP 为什么值得单独成层

### 1. 没有 BSP 的世界

设想第八~十一章的实验代码不经封装直接堆进产品：点亮屏幕要先拼 SPI 六根线（CLK/MOSI/CS/DC/RST/背光）加触摸的 I2C 两根线加 INT；放声音要配 I2S 五根线，再分别对 ES8311、ES7210 写 I2C 寄存器。示意（宏名是真的，代码是假的）：

```c
/* 每个 demo 都要来一遍的"拼引脚"——没有 BSP 的世界（示意） */
spi_bus_config_t bus = { .sclk_io_num = 7, .mosi_io_num = 6, /* ... */ };
i2c_config_t   i2c  = { .sda_io_num = 8, .scl_io_num = 18, /* ... */ };
i2s_std_config_t i2s = { .mclk = 2, .bclk = 17, .ws = 45, .dout = 15, .din = 16 };
/* 之后还有：背光 LEDC、触摸 probe、ES8311/ES7210 寄存器、LVGL 对接…… */
```

痛点不在代码量，在于**这份知识无处安放**：它描述的是"这块板子长什么样"，却被复制进每个 example 的 `main.c`。换一块板（BOX → BOX-3）、换一批屏幕（后文会看到 BOX-3 有两代屏幕），全部 demo 逐个改。第四章 4.2 节已经见过官方解法的一半——`sdkconfig.defaults` 集中放硬件约束；另一半就是本章的 BSP：**把引脚表和初始化顺序从应用代码里抽出来，做成一个可复用的组件**。

### 2. BSP = 板子的"设备树 + 驱动组装车间"

- **静态描述**：这块板有哪些外设、每个外设接在哪些 GPIO 上（引脚定义头文件）——相当于"设备树"；
- **动态组装**：按正确顺序把底层驱动（esp*lcd、esp_codec_dev、button……）实例化并接好（`bsp*\*.c`）——相当于"组装车间"。

### 3. 与 Linux 设备树的类比

| 关注点       | Linux 设备树（DTS）                       | ESP-IDF BSP                                 |
| ------------ | ----------------------------------------- | ------------------------------------------- |
| 硬件描述载体 | `.dts` 文本，运行前由 of 层解析           | `esp-box-3.h` 里的 `#define` 引脚宏         |
| 驱动匹配     | compatible 字符串 → platform driver probe | Kconfig 选板 + CMake 条件编译选源文件       |
| 何时生效     | 编译期生成 dtb，启动期展开                | 纯编译期（外加本章 14.3 的运行时 I2C 探测） |
| 改一块板     | 改 dts + 重编内核/模块                    | 改头文件宏 + 重编组件                       |

类比建立直觉，差异也要看清：设备树用**通用语法描述任意硬件拓扑**，BSP 是**每块板一份 C 代码**——粒度粗，但零运行时开销、可读性直接。

---

## 14.2 两层 BSP：仓库组件与注册表组件

### 1. 全景：谁包含谁

实地走读的第一个发现：**"BSP"在 esp-box 工程里其实是两层**。

```text
factory_demo main.c            应用层：调 bsp_display_start() / bsp_board_init()
      │
      ▼
esp-box/components/bsp         本地"产品 BSP"：选板 Kconfig + 按键/音频/传感器封装
      │  PRIV_REQUIRES esp-box-3          （EXTRA_COMPONENT_DIRS 引入，第四章 4.2）
      ▼
managed_components/            注册表"板级 BSP"：引脚定义 + LCD/触摸/codec 初始化
espressif__esp-box-3 (1.1.3)   （上游：github.com/espressif/esp-bsp/bsp/esp-box-3）
      │
      ▼
esp_lcd / esp_lcd_ili9341 / esp_lcd_touch_gt911 / esp_codec_dev / button / esp_lvgl_port
      ▼                          （又是注册表组件，依赖树见 dependencies.lock）
ESP-IDF components（driver/i2c、i2s_std、sdmmc、spiffs……）
```

两层之间靠一个门面头文件缝合——注册表组件提供的 `include/bsp/esp-bsp.h` 全文只有两行：`#pragma once` 和 `#include "bsp/esp-box-3.h"`。本地 BSP 的 `bsp_board.h` 只写 `#include "bsp/esp-bsp.h"`，**链接哪个板组件，宏与函数就指向哪个板**——三板共存而不互相污染的机制正在于此。

### 2. 本地 bsp 组件目录

`~/esp/esp-box/components/bsp` 全目录（实地核对，共 10 个文件）：

```text
bsp/
├── CMakeLists.txt / Kconfig.projbuild / idf_component.yml
├── include/bsp_board.h, bsp_storage.h     # 公共 API：按键/音频/板信息 + SD 挂载
├── priv_include/bsp_board_priv.h
└── src/boards/esp32_bsp_board.c          # 板级编排：按键 + codec + sensor 底板
          esp32_bsp_sensor.c              # SENSOR 底板实装（AHT20 + 雷达 + 电源管理）
          esp32_bsp_no_sensor.c           # 无底板时的桩实现
   storage/bsp_sdcard.c                   # 走 PMOD 引脚的 SD 卡挂载
```

### 3. CMakeLists：在配置出生前读配置

```cmake
if(EXISTS ${PROJECT_DIR}/sdkconfig)
    file(READ ${PROJECT_DIR}/sdkconfig SDKCONFIG_RULE)
elseif(EXISTS ${PROJECT_DIR}/sdkconfig.defaults)
    file(READ ${PROJECT_DIR}/sdkconfig.defaults SDKCONFIG_RULE)
endif()
if(SDKCONFIG_RULE)
    string(REGEX MATCH "CONFIG_BSP_BOARD_ESP32_S3_BOX_3=y" COMPILER_TARGET_IS_ESP_BOX_3 "${SDKCONFIG_RULE}")
endif()
...
set(priv_requires "esp-box${box_alias}")   # box_alias 为 "-3"、"-lite" 或空
```

为什么要用正则去**读 sdkconfig 文本文件**？第四章 4.3 节的规则：`REQUIRES`/`PRIV_REQUIRES` 不能依赖 `CONFIG_xxx`——组件依赖在 Kconfig 值可用之前就要展开。而"按板型 PRIV_REQUIRES 不同板组件"绕不开配置，于是作者用"读文件 + 正则"在 CMake 配置期抢先拿到选板结果，再决定 `priv_requires` 与源文件清单（BOX-3 且 factory_demo 时追加 `esp32_bsp_sensor.c` 与 `aht20`/`at581x` 依赖，否则上桩实现）——那条硬规则的一个真实 workaround 标本。

### 4. Kconfig 选板（第四章已拆，此处对账）

`Kconfig.projbuild` 的 `choice BSP_LCD_BOARD` 定义了 `CONFIG_BSP_BOARD_ESP32_S3_BOX / _Lite / _3` 三项、默认 BOX_3——机制与截图级解读见 [[ch4-project-anatomy|第四章]] 4.5 节，不重复。补一个第四章没展开的细节：同一文件还有第二个 menu `Power Save Configuration`，`depends on BSP_BOARD_ESP32_S3_BOX_3`——BOX-3 专属，第四章 defaults 表里的 `CONFIG_EXAMPLE_MAX_CPU_FREQ_240`/`MIN_40M` 就定义在这里，最终被 14.3 节的 `bsp_pm_init()` 消费，闭环。

### 5. 与注册表组件的关系（版本核实）

本地 `idf_component.yml` 全文（9~21 行）：

```yaml
dependencies:
  esp_codec_dev: { public: true, version: "1.1.0" }
  espressif/button: { version: "^3.5.0" }
  espressif/esp-box: { version: "3.0.*", require: "no" }
  espressif/esp-box-lite: { version: "2.0.*", require: "no" }
  espressif/esp-box-3: { version: "1.1.*", require: "no" }
```

三个板组件都标 `require: no`——构建时**三个都会被下载**（factory_demo 的 `dependencies.lock` 把三者全部列为 direct_dependencies，managed_components 里也三套俱全），但只有 CMakeLists 正则选中的那个进入编译。实测版本（lock 固化）：**esp-box-3 = 1.1.3**、esp-box = 3.0.5、esp-box-lite = 2.0.4，lock 里 `idf: 6.0.2`、`target: esp32s3`——这就是第一章构建现场的组件指纹。

注册表页面核实（2026-08-26 抓取 components.espressif.com）：`espressif/esp-box-3` 最新版 **3.2.0**（共 19 个版本，Apache-2.0），源码仓库指向 **github.com/espressif/esp-bsp/bsp/esp-box-3**。需要澄清一个容易想当然的关系：esp-box 仓库**不是** esp-box-3 组件的上游，而是它的**消费方与配套示例宿主**；组件本体维护在 esp-bsp 仓库，esp-box 清单把版本钉在 1.1.\* 是刻意的代际选择（3.x 系 BSP API 已换代）。这是 [[ch2-ecosystem-map|第二章]] 生态地图"一个组件、多个仓库"的活例。

### 6. 板组件目录与条件编译

`managed_components/espressif__esp-box-3/`（构建现场实地）：

```text
espressif__esp-box-3/
├── CMakeLists.txt / Kconfig / idf_component.yml / README.md
├── esp-box-3.c             # 板级主体：I2C/LCD/触摸/codec/按键/SD/SPIFFS
├── esp-box-3_idf4.c        # IDF4 版 I2S 初始化（legacy i2s_config_t）
├── esp-box-3_idf5.c        # IDF5+ 版 I2S 初始化（i2s_std_config_t）
├── include/bsp/            # esp-bsp.h 门面 + esp-box-3.h 引脚定义 + display/touch.h
└── priv_include/bsp_err_check.h
```

它的 `CMakeLists.txt` 展示了"按 IDF 版本切源文件"的条件编译：

```cmake
if("${IDF_VERSION_MAJOR}.${IDF_VERSION_MINOR}" VERSION_LESS "5.0")
    set(SRC_VER "esp-box-3_idf4.c")
else()
    set(SRC_VER "esp-box-3_idf5.c")
endif()

idf_component_register(
    SRCS "esp-box-3.c" ${SRC_VER}
    INCLUDE_DIRS "include" PRIV_INCLUDE_DIRS "priv_include"
    REQUIRES driver spiffs PRIV_REQUIRES fatfs esp_lcd
)
```

与本地 bsp 对照：**按板型切只能用读配置的把戏，按 IDF 版本切有官方 `IDF_VERSION_MAJOR` 变量**——后者是构建系统一等的版本信息，不需要绕。

---

## 14.3 板级初始化主流程：从 app_main 到第一帧屏幕

### 1. 应用层看到的顺序

factory_demo 的 `main.c`（91~127 行实地节选）：

```c
void app_main(void)
{
    ...
    bsp_spiffs_mount();
    bsp_i2c_init();
    bsp_display_cfg_t cfg = {
        .lvgl_port_cfg = ESP_LVGL_PORT_INIT_CONFIG(),
        .buffer_size = BSP_LCD_H_RES * CONFIG_BSP_LCD_DRAW_BUF_HEIGHT,  /* 320x10 */
        .double_buffer = 0,
        .flags = { .buff_dma = true, }
    };
    cfg.lvgl_port_cfg.task_affinity = 1;
    bsp_display_start_with_config(&cfg);
    bsp_board_init();
    ...
    vTaskDelay(pdMS_TO_TICKS(500));
    bsp_display_backlight_on();   /* 背光默认是关的！ */
```

三个层次一目了然：资源挂载 → 总线 → 屏幕（含 LVGL）→ 本地 BSP 的按键/音频/传感器编排。注意 `BSP_LCD_H_RES`、`CONFIG_BSP_LCD_DRAW_BUF_HEIGHT`（factory_demo defaults 覆写为 10 行缓冲）这类名字跨两层——宏来自板组件头文件，配置项来自板组件 Kconfig。

### 2. bsp_display_start_with_config：屏幕侧的编排

`esp-box-3.c` 里它是四步串行（569~581 行）：`lvgl_port_init`（起 LVGL 任务）→ `bsp_display_brightness_init`（LEDC PWM，[[ch13-timers-watchdogs|第十三章]] 的 LEDC）→ `bsp_display_lcd_init` → `bsp_display_indev_init`（触摸 indev）。其中 `bsp_display_new`（358~425 行）把依赖顺序写得最清楚：

```c
esp_err_t bsp_display_new(const bsp_display_config_t *config, ...)
{
    ESP_RETURN_ON_ERROR(bsp_display_brightness_init(), TAG, "Brightness init failed");
    BSP_ERROR_CHECK_RETURN_ERR(bsp_i2c_init());          /* 触摸在 I2C 上，先起总线 */
    const spi_bus_config_t buscfg = {
        .sclk_io_num = BSP_LCD_PCLK,
        .mosi_io_num = BSP_LCD_DATA0,                    /* ... */
    };
    ESP_RETURN_ON_ERROR(spi_bus_initialize(BSP_LCD_SPI_NUM, &buscfg, SPI_DMA_CH_AUTO), ...);
    ...   /* panel IO → 面板驱动选择 → reset/init/mirror */
}
```

顺序本身就是依赖关系的文档：**背光独立 → I2C 先于触摸 → SPI 总线先于面板 → probe 先于驱动选择**。SPI/DMA 到刷屏通路已在 [[ch10-spi-display|第十章]] 拆到底，此处不重复。

### 3. 运行时探测：一块 BSP 伺候两代屏幕

BOX-3 出过两代屏幕模组，BSP 用 I2C 地址探测在运行期自适应（404~409、511~525 行节选）：

```c
if (ESP_OK == bsp_i2c_device_probe(ESP_LCD_TOUCH_IO_I2C_TT21100_ADDRESS)) {
    esp_lcd_new_panel_st7789(...);                  /* 老一代屏：ST7789 面板 */
} else {
    panel_config.vendor_config = (void *)&vendor_config;
    esp_lcd_new_panel_ili9341(...);                 /* 新一代屏：ILI9342C（ili9341 驱动 + 厂商命令表） */
}
/* 触摸探测链（bsp_touch_new）：GT911 主地址 0x5D → GT911 备用地址 0x14
 * → TT21100 0x24 → 都不在则报 "Touch not found"（地址值出自两个触摸组件头文件） */
```

这个设计把"硬件版本差异"从用户面前藏掉：probe 一次 I2C 地址（[[ch9-i2c-sensors|第九章]] 拆过的总线事务），面板和触摸驱动各自选中——你手里那块板到底是哪一代，也用第九章的 I2C 总线扫描即可定案。`vendor_specific_init[]` 命令表（0xC8/0xC0/0xE0… 伽马与电源序列）正是第十章"ILI9342C 初始化命令序列"的原始出处。

### 4. 本地 BSP 层的编排：bsp_board_init

`esp32_bsp_board.c` 242~257 行（全文走读）：

```c
esp_err_t bsp_board_init(void)
{
    esp_err_t ret = ESP_OK;
    ESP_LOGD(TAG, "Board init");
    ESP_ERROR_CHECK(bsp_btn_init());
#if !CONFIG_BSP_BOARD_ESP32_S3_BOX_Lite
    ESP_ERROR_CHECK(bsp_btn_register_callback(BSP_BUTTON_MUTE, BUTTON_PRESS_DOWN, mute_btn_handler, ...));
    ESP_ERROR_CHECK(bsp_btn_register_callback(BSP_BUTTON_MUTE, BUTTON_PRESS_UP, mute_btn_handler, ...));
#endif
    ESP_ERROR_CHECK(bsp_codec_init());
    bsp_sensor_init(&g_bottom_handle);
    return ret;
}
```

四件事：**按键**（`iot_button` 封装三个按键，其中"主页键"竟是触摸控制器报告的虚拟按键，见 `bsp_get_main_button`）→ **静音回调**（`mute_btn_handler` 是 `__attribute__((weak))`，应用可覆盖）→ **音频 codec 组装**（`bsp_audio_codec_speaker_init`/`_microphone_init` 把 ES8311、ES7210 挂到 `bsp_audio_init` 建好的 I2S 通道上，返回 `esp_codec_dev` 句柄——ES8311/ES7210/I2S/DMA 已在 [[ch11-i2s-audio|第十一章]] 拆透）→ **SENSOR 底板**。`esp32_bsp_sensor.c` 的 `bsp_sensor_init` 又是一次运行时探测：probe AT581x 的 I2C 地址决定底板在否，在则初始化雷达 + AHT20 温湿度（[[ch9-i2c-sensors|第九章]] 的实验对象），并创建钉在核 1、优先级 5 的 `low_power_monitor_task`（雷达触发唤醒整机、2 分钟无活动则让屏幕/音频/LVGL 依次休眠并释放三把 `esp_pm` 锁——任务亲和与优先级语义见 [[ch5-task-lifecycle-and-tcb|FreeRTOS 系列第五章]]）。

### 5. 幂等、单例与错误处理策略

走读时注意三处"防重入"标志：板组件的 `i2c_initialized`（`bsp_i2c_init`）、`bsp_sdcard` 指针判空（`bsp_sdcard_mount`）、`i2s_tx_chan && i2s_rx_chan`（`bsp_audio_init`）。BSP 内部各初始化函数**不要求特定调用顺序**——`bsp_audio_codec_speaker_init` 发现数据接口没建，会顺手先 `bsp_i2c_init` + `bsp_audio_init`。这解释了 factory_demo 为什么敢在 `app_main` 里随手调 `bsp_i2c_init`：即使不调，后面也会被补上。错误处理则是宏的双重人格，`priv_include/bsp_err_check.h`（17~22 行）：

```c
#if CONFIG_BSP_ERROR_CHECK
#define BSP_ERROR_CHECK_RETURN_ERR(x)    ESP_ERROR_CHECK(x)
#define BSP_NULL_CHECK(x, ret)           assert(x)
#else
/* 展开为 if (err != ESP_OK) return err; 风格的优雅返回 */
#endif
```

Kconfig 里 `BSP_ERROR_CHECK` **默认 y**：出错直接 `abort()`（串口打出 panic 回溯），而不是返回错误码。产品代码想要优雅降级，得显式关掉它——这个默认值是"demo 友好、产品危险"的典型取舍。本地 BSP 层则不设开关，直接 `ESP_ERROR_CHECK` + `assert`（如 `assert((play_dev_handle) && "play_dev_handle not initialized")`）。

---

## 14.4 外设封装清单

两层 BSP 的 API 分工：**板组件管"芯片级"封装（屏幕/触摸/codec/I2C），本地 BSP 管"产品级"封装（按键语义、音频流、传感器底板、SD）**。逐外设对账（底层组件版本以 lock 为准）：

| 外设             | BSP API                                                                   | 底层组件/驱动                                                  | 已拆章节           |
| ---------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------ |
| 背光（PWM 调光） | `bsp_display_brightness_set/on/off`                                       | LEDC（`driver/ledc`）                                          | 第十三章（LEDC）   |
| LCD 面板         | `bsp_display_new` / `bsp_display_start*`                                  | esp_lcd + esp_lcd_ili9341 1.2.0（+st7789 内置）                | 第十章             |
| 触摸             | `bsp_touch_new`                                                           | esp_lcd_touch 1.2.1 + gt911/tt21100 1.2.1                      | 第八、九章         |
| I2C 总线         | `bsp_i2c_init/deinit`                                                     | legacy `driver/i2c`（`i2c_param_config`/`i2c_driver_install`） | 第九章             |
| 音频输出/输入    | `bsp_audio_codec_speaker_init` / `_microphone_init` → esp_codec_dev 1.1.0 | es8311/es7210（codec 库内建）+ `driver/i2s_std`                | 第十一章           |
| 音频流控         | 本地层 `bsp_i2s_read/write`、`bsp_codec_set_fs`                           | esp_codec_dev `read/write/open`                                | 第十一章           |
| 按键             | 板级 `bsp_iot_button_create` / 本地层 `bsp_btn_*`                         | espressif/button 3.5.0                                         | 第八章             |
| SD 卡            | 板级 `bsp_sdcard_mount` / 本地层 `bsp_sdcard_init`                        | `esp_vfs_fat` + `sdmmc_host`                                   | —                  |
| SPIFFS           | `bsp_spiffs_mount/unmount`                                                | `esp_spiffs`                                                   | —                  |
| 温湿度/雷达      | 本地层 `bsp_board_get_sensor_handle`                                      | aht20 0.1.0 / at581x 0.1.0（GPIO21 雷达中断）                  | 第九、十二章       |
| 红外收发         | 本地层引脚宏 `BSP_IR_TX/RX/CTRL_GPIO`                                     | RMT                                                            | 第十二章           |
| 电源管理         | 本地层 `bsp_pm_init`（三把 pm 锁）                                        | `esp_pm`                                                       | 第四章（DFS 配置） |

一个观察：BSP 1.1.x 的 I2C 走的还是**旧版驱动 API**（第九章从协议层拆过这条总线；新工程建议 `i2c_master` 新 API，但 BSP 为了兼容 IDF ≥4.4.5 停在旧 API——它的 `idf_component.yml` 明写 `idf: '>=4.4.5'`）。

---

## 14.5 esp-box-3 变体专属：引脚定义头文件

`include/bsp/esp-box-3.h` 的 pinout 段是**全书硬件事实的源头**——第八章的背光/触摸 INT、第九章的 I2C 引脚、第十章的 LCD 六线、第十一章的 I2S 五线，全部出自这 70 余行。全文引用（46~122 行）：

```c
/* I2C */
#define BSP_I2C_SCL           (GPIO_NUM_18)
#define BSP_I2C_SDA           (GPIO_NUM_8)

/* Audio */
#define BSP_I2S_SCLK          (GPIO_NUM_17)
#define BSP_I2S_MCLK          (GPIO_NUM_2)
#define BSP_I2S_LCLK          (GPIO_NUM_45)
#define BSP_I2S_DOUT          (GPIO_NUM_15) // To Codec ES8311
#define BSP_I2S_DSIN          (GPIO_NUM_16) // From ADC ES7210
#define BSP_POWER_AMP_IO      (GPIO_NUM_46)
#define BSP_MUTE_STATUS       (GPIO_NUM_1)

/* Display */
#define BSP_LCD_DATA0         (GPIO_NUM_6)
#define BSP_LCD_PCLK          (GPIO_NUM_7)
#define BSP_LCD_CS            (GPIO_NUM_5)
#define BSP_LCD_DC            (GPIO_NUM_4)
#define BSP_LCD_RST           (GPIO_NUM_48)

#define BSP_LCD_BACKLIGHT     (GPIO_NUM_47)
#define BSP_LCD_TOUCH_INT     (GPIO_NUM_3)

/* USB */
#define BSP_USB_POS           USBPHY_DP_NUM
#define BSP_USB_NEG           USBPHY_DM_NUM

/* Buttons */
#define BSP_BUTTON_CONFIG_IO  (GPIO_NUM_0)
#define BSP_BUTTON_MUTE_IO    (GPIO_NUM_1)

/* SD card */
#define BSP_SD_D0             (GPIO_NUM_9)
#define BSP_SD_D1             (GPIO_NUM_13)
#define BSP_SD_D2             (GPIO_NUM_42)
#define BSP_SD_D3             (GPIO_NUM_12)
#define BSP_SD_CMD            (GPIO_NUM_14)
#define BSP_SD_CLK            (GPIO_NUM_11)
#define BSP_SD_DET            (GPIO_NUM_NC)
#define BSP_SD_POWER          (GPIO_NUM_43)

/* PMOD —— Digilent 开放标准；DOCK 上两个双 PMOD 座，3.3V 供电，ESD 保护 */
#define BSP_PMOD1_IO1        GPIO_NUM_42
#define BSP_PMOD1_IO2        BSP_USB_POS
#define BSP_PMOD1_IO3        GPIO_NUM_39
#define BSP_PMOD1_IO4        GPIO_NUM_40 // Intended for I2C SCL (pull-up NOT populated)
#define BSP_PMOD1_IO5        GPIO_NUM_21
#define BSP_PMOD1_IO6        BSP_USB_NEG
#define BSP_PMOD1_IO7        GPIO_NUM_38
#define BSP_PMOD1_IO8        GPIO_NUM_41 // Intended for I2C SDA (pull-up NOT populated)

#define BSP_PMOD2_IO1        GPIO_NUM_13 // Intended for SPI2 Q (MISO)
#define BSP_PMOD2_IO2        GPIO_NUM_9  // Intended for SPI2 HD (Hold)
#define BSP_PMOD2_IO3        GPIO_NUM_12 // Intended for SPI2 CLK
#define BSP_PMOD2_IO4        GPIO_NUM_44 // UART0 RX by default
#define BSP_PMOD2_IO5        GPIO_NUM_10 // Intended for SPI2 CS
#define BSP_PMOD2_IO6        GPIO_NUM_14 // Intended for SPI2 WP (Write-protect)
#define BSP_PMOD2_IO7        GPIO_NUM_11 // Intended for SPI2 D (MOSI)
#define BSP_PMOD2_IO8        GPIO_NUM_43 // UART0 TX by default
```

SENSOR 底板的引脚不在板组件里，而在本地 `bsp_board.h`（I2C 扩展口 SCL=40/SDA=41、雷达输出 21、红外发射 39/接收 38/使能 44）——因为 SENSOR 是 BOX-3 特有配件，归"产品 BSP"层管。

**三板共存机制**：同一段上层代码，三个板组件各自提供同名宏与同名函数——esp-box 组件 `esp-box.h` 的触摸只探测 TT21100（初代 BOX 的配置）；esp-box-lite 组件里 `BSP_CAPS_TOUCH` 为 **0**（Lite 根本没触摸）；esp-box-3 组件才有 14.3 节的双探测链。选板 Kconfig 决定链接谁，`bsp/esp-bsp.h` 门面让本地 BSP 与应用对差异无感。

> [!warning] 顺带勘误：触摸控制器是 GT911/TT21100，不是 FT6336
> 系列索引与第二章芯片表写的"FT6336"未获源码支持：esp-box-3 1.1.3 的探测链（上节）、依赖树（gt911/tt21100，全树无 ft6336 组件）、组件 README 依赖表、Zephyr 官方板级文档（`goodix,gt911`）四源一致——BOX 系三块板的 BSP 里根本没有 FT6336。另有一处：esp-box 仓库官方硬件文档原话是"additional 16 MB Quad flash and **16 MB Octal PSRAM**"（`docs/hardware_overview/esp32_s3_box_3/`），索引表的"N16R8V（8MB）"同待修。两处均**待真机验证**：第九章的 I2C 总线扫描（看 0x5D/0x14/0x24 谁应答）与上电日志的 PSRAM 探测行一锤定音。

---

## 14.6 思路：给 BOX-3 换自制扩展板

### 1. 官方示范与轻路径：把 PMOD 当外设用

factory_demo `main.c` 138~143 行给了扩展板消费范式的官方样板：

```c
const board_res_desc_t *brd = bsp_board_get_description();
#ifdef CONFIG_BSP_BOARD_ESP32_S3_BOX_3
    app_pwm_led_init(brd->PMOD2->row2[2], brd->PMOD2->row2[3], brd->PMOD2->row1[3]);
#else
    app_pwm_led_init(brd->PMOD2->row1[1], brd->PMOD2->row1[2], brd->PMOD2->row1[3]);
#endif
```

即：应用不写死 GPIO，而是从 BSP 的板资源描述符取 PMOD 引脚。走读发现一个值得记录的源码事实：`g_board_box_res` 里 `.PMOD1 = &g_pmod[0]`，而 `g_pmod[0]` 用的是 **PMOD2_IO\* 宏**（62~63 行对照 22~31 行）——描述符名与宏名互换，factory_demo 因此为 BOX-3 单写了 `#ifdef` 分支（展开后即 GPIO39/40/41 接 RGB LED）。是 bug 还是"DOCK 丝印编号与主板编号相反"的有意为之，需对照 DOCK 原理图确认（待真机验证）。

自制扩展板若只接普通外设（传感器、LED、舵机），轻路径即可：DOCK/BREAD 把 16 个 GPIO 以两个 PMOD 座引出（上节宏表即引脚表），应用直接 `#include "bsp/esp-box-3.h"` 用 `BSP_PMOD*_IO*` 宏。注意两条注释级警告：PMOD1 的 IO4/IO8 外接 I2C 时**板载未焊上拉**；PMOD2 的 IO1/IO2/IO3/IO6/IO7 与 SD 卡线复用（对照 `BSP_SD_D1/D0/D3/CMD/CLK`），SD 在用就别碰。

### 2. 重路径：复制一个板型目录（步骤级，待真机验证）

想让"选板菜单"里出现自制板型，照 esp-box-3 的样子复制改：

1. 把 `managed_components/espressif__esp-box-3/` 整目录拷到工程 `components/my-board/`（工程 components 优先级最高，第四章 4.3 节，天然覆盖注册表同名组件）；
2. 改 `include/bsp/esp-box-3.h` 里的引脚宏（板名、GPIO 分配）与 `idf_component.yml`（`targets`、版本号改 0.0.1）；
3. 本地 bsp 的 `Kconfig.projbuild` choice 里加 `config BSP_BOARD_MY_BOARD` 一项；
4. 本地 bsp 的 `CMakeLists.txt` 加对应正则分支与 `set(box_alias ...)`/`priv_requires`（照 14.2 节第 3 小节的样式）；
5. 工程加 `sdkconfig.ci.my-board` 片件（两行，第四章 4.5 节机制）进 CI 矩阵，最后 `idf.py reconfigure`——正则读的是配置文件文本，不 reconfigure 则 CMake 仍按旧选板结果组源文件。

---

## 14.7 翻车点表与小结

| 症状                                                      | 根因                                                                                    | 处理                                                                       |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| menuconfig 换板后构建仍按旧板编译                         | 本地 bsp 的正则在 CMake 配置期读 sdkconfig 文本，menuconfig 只更新 sdkconfig 不触发重配 | 改选板后 `idf.py reconfigure`；CI 里靠 `sdkconfig.ci.*` 整文件切换         |
| 选板宏与实际链接组件不一致                                | 三件套必须同步：Kconfig choice、CMakeLists 正则分支、`priv_requires` 的板名             | 14.6 节步骤 3/4 成对改；漏一处即"编了 A 板源码 + 链了 B 板组件"            |
| 自己先 `i2c_param_config` 同一端口后 BSP 初始化失败       | BSP 幂等标志只认自己调过 `bsp_i2c_init`；`BSP_I2C_NUM`（默认 1）被外部驱动占用          | 外设统一走 BSP 拿总线，或全走自建（别混）；端口号可在板组件 Kconfig 改     |
| 手写 I2S 与 BSP 音频冲突                                  | `bsp_audio_init` 一次性占用 `CONFIG_BSP_I2S_NUM` 的 tx+rx 双通道（`auto_clear` DMA）    | 音频路径交给 `esp_codec_dev` 句柄（第十一章的管道）；裸 I2S 用另一个控制器 |
| 背光不亮/触摸报 `Touch not found`                         | 背光默认关，必须显式 `bsp_display_backlight_on()`；触摸探测依赖 I2C 已初始化            | 照 factory_demo 顺序：display_start → 延时 → backlight_on；失败先查 I2C    |
| 一初始化就"死机"（panic 回溯）                            | 板组件 `BSP_ERROR_CHECK` 默认 y，出错 `abort()` 而非返回错误码                          | 排障时可关该选项拿到错误码；产品要优雅降级则必须关                         |
| 改 managed_components 下的板组件，改动丢失/告警 hash 不符 | 托管目录是纯缓存（第四章 4.4 节），`.component_hash` 校验                               | 拷到工程 `components/` 覆盖（14.6 节重路径第 1 步）                        |
| 想升 LVGL 9 报冲突                                        | esp-box-3 1.1.x 依赖树钉死 `lvgl ^8`（lock 实测 8.4.0）+ esp_lvgl_port 1.4.0            | 留在 LVGL 8；要 LVGL 9 需换 esp-bsp 3.x 代板组件（API 换代）               |

本章小结：

- **BSP 是两层**：esp-box 仓库的本地 `bsp`（选板、按键/音频/传感器产品级封装）+ 注册表 `espressif/esp-box-3` 1.1.3（引脚定义、芯片级初始化），靠 `bsp/esp-bsp.h` 门面缝合；后者上游在 **esp-bsp 仓库**，esp-box 仓库是消费方与示例宿主。
- **选板三件套**：Kconfig choice、CMakeLists 读配置文本的正则分支、`priv_requires` 板名——这是"REQUIRES 不能依赖 CONFIG"硬规则下的一组真实 workaround，改板必须三处同步并 reconfigure。
- **初始化编排的教训可迁移**：依赖顺序即文档（背光→I2C→SPI→面板→probe→驱动）、幂等标志消除调用顺序要求、运行时 I2C 探测吃掉硬件版本差异（两代屏幕/触摸、SENSOR 底板在否）。
- **引脚定义头文件是全书硬件事实的源头**：第八~十一章用到的每个 GPIO 都能在 14.5 节的引用里对上号；并据此勘误索引表两处（GT911、16MB PSRAM，待真机验证）。
- **错误处理默认 abort**：BSP 是 demo 友好取向，产品化第一件事是关 `BSP_ERROR_CHECK` 拿回错误码。

下一章进入 `bsp_display_start()` 留下的那扇门：LVGL 任务模型、双缓冲策略与触摸 indev——BSP 把 LVGL 藏在门后，[[ch15-lvgl|第十五章]]把这扇门彻底打开。
