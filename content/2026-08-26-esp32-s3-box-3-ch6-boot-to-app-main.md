---
title: "ESP32-S3-BOX-3 工程实战（六）：从上电到 app_main"
date: 2026-08-26 12:00:00
description: "按下复位之后你的 app_main 是怎么跑起来的：ROM bootloader（GPIO0/46 strap 选启动模式）→ 二级 bootloader（读分区表、选镜像、建 MMU 映射）→ 应用侧 call_start_cpu0（PSRAM、堆、init.fn 数组、main 任务），配一份逐行标注来源模块的启动日志对账框架。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（六）：从上电到 app_main

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[2026-08-26-esp32-s3-box-3-hands-on-series-index|系列索引]]
> 上一章：[[2026-08-26-esp32-s3-box-3-ch5-image-and-flashing|第五章：编译产物与烧录链路]]
> **第六章：从上电到 app_main**（当前章）
> 下一章：[[2026-08-26-esp32-s3-box-3-ch7-system-services|第七章：系统服务层]]

第五章结束时，bootloader、分区表、app 三件套已经躺在 Flash 里。本章回答下一个问题：**按下复位键之后，这三件套是怎么一级一级接力，最终把 CPU 交给你的 `app_main` 的**。写法延续系列方法论——每一环都到 `$IDF_PATH` 源码里实地对账（v6.0.2），ROM 那一级没有源码，就用官方文档 + 启动日志反推。读完你应该能在任何一次启动日志里，把每一行钉到它的源码位置。

---

## 6.1 三级接力全景

先把整条链画出来。ESP32-S3 上电后的执行流是一场三级接力，每一级只干最小的一摊事，然后把硬件以更"可用"的状态交给下一级：

```text
上电 / 复位
   │
   ▼
① ROM bootloader（掩膜 ROM，不可修改）
   │  读 strap 引脚定启动模式；SPI Boot 时从 Flash 0x0 读镜像头，
   │  把二级 bootloader 的 RAM 段拷进 IRAM/DRAM，跳到其入口
   ▼
② 二级 bootloader（esp-idf 编译，可升级）
   │  初始化时钟/Flash 到"能干活"状态；读 0x8000 分区表选 app 分区；
   │  校验镜像、拷贝 RAM 段、建 MMU 映射（XIP 段不搬运），跳到 app 入口
   ▼
③ 应用（call_start_cpu0 系列 C 初始化）
   │  清 BSS、初始化 Flash 最终状态与 PSRAM、跑组件 init.fn 数组、
   │  拉起 CPU1、创建 main 任务、启动 FreeRTOS 调度器
   ▼
app_main()  ── 返回后 main 任务自删，系统继续运行
```

三级各自的职责与"证据来源"：

| 级                | 介质           | 可改吗           | 核心职责                                                   | 本章证据来源                                          |
| ----------------- | -------------- | ---------------- | ---------------------------------------------------------- | ----------------------------------------------------- |
| ① ROM bootloader  | 芯片掩膜 ROM   | 否               | 启动模式判定、最小化加载二级 bootloader、UART/USB 下载模式 | 官方文档 + 启动日志（无源码）                         |
| ② 二级 bootloader | Flash 0x0 起   | 是（随固件分发） | 分区表、镜像校验、可选加密/安全启动/回滚、Flash 预初始化   | `components/bootloader_support/` 实读                 |
| ③ 应用            | Flash app 分区 | 是               | C 运行时、堆、组件初始化、FreeRTOS、main 任务              | `components/esp_system/`、`components/freertos/` 实读 |

> [!note] 与老教程的一处 v6 差异：PSRAM 初始化搬家了
> ESP32-S3 的 PSRAM 历史上由二级 bootloader 顺手初始化（v4/v5 教程多这么讲）。v6 里职责被拆开：bootloader 只把 Flash/MSPI 带到"预备状态"（`bootloader_flash_config_esp32s3.c` 的 `bootloader_init_spi_flash()`），**PSRAM 的正式初始化移到了应用侧** `cpu_start.c` 的 `mspi_init()` 里（`CONFIG_SPIRAM_BOOT_HW_INIT`，默认开）。源码注释原话：_"In bootloader, we only init Flash (and MSPI) to a preliminary state"_。看老日志对照时注意这一点。

---

## 6.2 第一级：掩膜 ROM bootloader

### 1. 为什么 ROM 只能做最小加载

复位后第一个取指的代码在芯片掩膜 ROM 里——它在出厂时就固化了，**不在你的 Flash 里，也不在 IDF 仓库里**。这决定了它的能力上限：

- **XIP（就地执行）还不可能**：CPU 想直接从 Flash 取指，需要 cache/MMU 先配好，而配 MMU 的代码自己总得先在 RAM/ROM 里跑——这个鸡生蛋问题由 ROM 解决：ROM 代码天然可执行；
- **Flash 还是"生"的**：SPI Flash 的时序、QIO 模式都没配置，ROM 只能按最保守的方式（低速、SPI 单线）访问它；
- **分区表、加密、签名——统统不知道**：ROM 只认 Flash 0x0 处的一个镜像头（魔数 `0xE9`，`esp_app_format.h` 的 `ESP_IMAGE_HEADER_MAGIC`），把头部声明的 RAM 段拷进来、跳到 `entry_addr`，仅此而已。

所以 ROM 的设计哲学是"最小加载器"：它自己不可升级（芯片流片后就定了），于是把一切可变的策略——分区布局、安全特性、回滚——推给放在 Flash 里、可以随固件更新的二级 bootloader。ESP32-S3 的 bootloader 镜像放在 Flash **0x0** 处（`components/bootloader/Kconfig.projbuild`：`BOOTLOADER_OFFSET_IN_FLASH` 对 S3 默认 `0x0`；经典 esp32 是 0x1000——这是两代芯片一个容易混淆的差异）。

### 2. 启动模式：GPIO0 与 GPIO46 的 strap 采样

复位释放瞬间，ROM 会采样 strapping 引脚（S3 共四个：GPIO0、GPIO3、GPIO45、GPIO46，见 IDF 文档 `docs/en/api-reference/peripherals/gpio/esp32s3.inc`），决定芯片进入哪种启动模式。与启动模式直接相关的是 GPIO0/GPIO46：

| GPIO0         | GPIO46   | 模式                                            | 日志特征（`boot:0xNN` 后的字符串）                 |
| ------------- | -------- | ----------------------------------------------- | -------------------------------------------------- |
| 1（默认上拉） | 任意     | SPI Boot，正常从 Flash 启动                     | `SPI_FAST_FLASH_BOOT`                              |
| 0             | 0 或悬空 | Joint Download Boot（下载模式，esptool 烧录用） | `DOWNLOAD_BOOT(UART0/...)` / `DOWNLOAD(USB/UART0)` |
| 0             | 1        | 非法/诊断组合，不会正常启动                     | 其他保留模式名                                     |

两个工程细节值得记：

1. **`boot:0xNN` 是可以解码的**。按 esptool 官方文档，这个值就是 `GPIO_STRAP` 寄存器的十六进制快照，其中 **0x08 位对应 GPIO0、0x04 位对应 GPIO46**。BOX-3 正常启动的 `boot:0x8` = GPIO0 为高、GPIO46 为低；进了下载模式常见 `boot:0x3` 一类 GPIO0 位被拉低的值。
2. **strap 引脚有约 45kΩ 内部弱上拉/下拉**，GPIO0 默认高。如果你的外设会在复位瞬间把 GPIO0 拖低（BOX-3 上 BOOT 按键就是接它的），芯片就进下载模式——6.7 翻车点表的第一条。

> [!note] BOX-3 的另一颗 strap 雷：GPIO33~37
> N16R8V 是 Octal PSRAM（R8V 的 V），S3 上 Octal PSRAM 占用 GPIO33~37（SPIIO4~7 + DQS，IDF 文档 esp32s3.inc 原话）。这些脚在扩展实验里当作普通 GPIO 拉去点灯，轻则 PSRAM 数据错乱，重则启动失败——第十四章走读 BSP 时会再遇到。

### 3. 下载模式：esptool 的自动进门术

GPIO0 为低时进入的下载模式里，ROM 变成一个被动的小型 loader：通过 UART0 或 USB-Serial-JTAG（BOX-3 走后者，第五章的 `/dev/ttyACM*`）接收 esptool 的写 Flash 命令。手动进门是"按住 BOOT 再点 EN"；esptool 自动进门靠串口的 DTR/RTS 两根线分别接 EN 与 GPIO0 的经典电路——这就是 `idf.py flash` 不需要你碰按键的原因。

---

## 6.3 第二级：bootloader 源码走读

### 1. 入口在 v6 搬了家

老教程说入口是 `components/bootloader_support/src/bootloader_start.c`——v6 里它移到了 **`components/bootloader/subproject/main/bootloader_start.c`**（bootloader 是独立子工程，[[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow|FreeRTOS（三）]]3.1 节讲过构建视角），且全芯片共用一份。目标相关初始化拆去了 `src/esp32s3/bootloader_esp32s3.c`。入口函数与注释值得整段读：

```c
/* components/bootloader/subproject/main/bootloader_start.c */
/*
 * We arrive here after the ROM bootloader finished loading this second stage
 * bootloader from flash. The hardware is mostly uninitialized, flash cache is
 * down and the app CPU is in reset. We do have a stack, so we can do the
 * initialization in C.
 */
void __attribute__((noreturn)) call_start_cpu0(void)
{
    if (bootloader_before_init) { bootloader_before_init(); }   // 用户钩子 0
    if (bootloader_init() != ESP_OK) { bootloader_reset(); }    // 1. 硬件初始化
    if (bootloader_after_init) { bootloader_after_init(); }     // 用户钩子 1.1
    ...
    int boot_index = select_partition_number(&bs);              // 2. 选分区
    if (boot_index == INVALID_INDEX) { bootloader_reset(); }
    bootloader_utility_load_boot_image(&bs, boot_index);        // 3. 加载并跳转
}
```

注释三句话就是交接状态：硬件基本未初始化、flash cache 关着、APP CPU（CPU1）还在复位里保持——**S3 双核在 bootloader 阶段是单核运行的**，CPU1 要等应用侧 `system_early_init()` 才被拉起。

### 2. bootloader_init()：S3 版初始化清单

`bootloader_esp32s3.c` 的 `bootloader_init()` 按序做（摘自源码，逐项核对）：

| 步骤 | 函数                                                                             | 干什么 / 对应日志                                                                                                       |
| ---- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| 1    | `bootloader_ana_reset_config()` 等                                               | 使能 WDT/BOD/毛刺复位，超级看门狗自动喂狗                                                                               |
| 2    | `bootloader_init_mem()` / `bootloader_clear_bss_section()`                       | 内存保护 + 清 bootloader 自己的 BSS                                                                                     |
| 3    | `bootloader_clock_configure()`                                                   | 时钟升到可用频率                                                                                                        |
| 4    | `bootloader_console_init()`                                                      | 点亮 console——**从这行起才能打日志**                                                                                    |
| 5    | `bootloader_print_banner()`                                                      | `ESP-IDF v6.0.2 2nd stage bootloader` + `compile time ...`                                                              |
| 6    | `bootloader_init_ext_mem()` + cache/MMU                                          | 为读 Flash 建最小映射                                                                                                   |
| 7    | `bootloader_flash_update_id()` / `bootloader_flash_xmc_startup()`                | 读 Flash ID、处理 XMC 颗粒特殊启动流程                                                                                  |
| 8    | `bootloader_read_bootloader_header()` / `bootloader_check_bootloader_validity()` | `chip revision: v0.x`、`efuse block revision: ...`（`bootloader_init.c:58,64`）                                         |
| 9    | `bootloader_init_spi_flash()`                                                    | Flash 预备状态；`Boot SPI Speed : 80MHz`、`SPI Mode : QIO`（BOX-3 配置下，`bootloader_flash_config_esp32s3.c:201,226`） |
| 10   | `bootloader_config_wdt()` / `bootloader_enable_random()`                         | 关 flashboot 看门狗保护；`Enabling RNG early entropy source...`                                                         |

日志横幅为什么在分区表之前就出现？因为第 4 步 console 先通了。这也是读启动日志的第一个锚点。

### 3. 分区表如何被读取

`select_partition_number()` → `bootloader_utility_load_partition_table()`（`src/bootloader_utility.c:143`）三步：

1. **mmap**：把 Flash 上 `ESP_PARTITION_TABLE_OFFSET`（= `CONFIG_PARTITION_TABLE_OFFSET`，默认 **0x8000**，`partition_table/Kconfig.projbuild:155`）开始的 `0xC00` 字节映射进地址空间；
2. **校验**：`flash_partitions.c` 的 `esp_partition_table_verify()` 逐条检查——每项 magic 必须是 `0x50AA`、**offset+size 不得越出 Flash 容量**（用 ROM 读到的 `g_rom_flashchip.chip_size` 对账，16MB 板上分区表写了 32MB 会在这里报 `partition N invalid ... exceeds flash chip size`）、表尾 MD5 逐字节比对、必须有 `0xFFFF` 终止项；
3. **打印**：`Partition Table:` 表头 + 每分区一行（`## Label Usage Type ST Offset Length` 格式串在 `bootloader_utility.c:163-164`）+ `End of partition table`。

一个流传已久的日志彩蛋：nvs 分区那一行的 Usage 列印的是 **`WiFi data`**——不是 bug，是 bootloader 的 usage 字符串表里子类型 `0x02` 标着 `PART_SUBTYPE_DATA_WIFI`（`esp_flash_partitions.h:30`），而 nvs 的子类型恰好也是 0x02，switch 落进了同一个 case（`bootloader_utility.c:213`）。看老日志对表时别被这列骗了。

第四章 factory_demo 分区表里 `otadata`、`ota_0` 那几行，就是在这一步被逐行念出来的。

### 4. 选镜像与跳转：load_boot_image 函数链

选中分区后，`bootloader_utility_load_boot_image()`（`bootloader_utility.c:578`）的尝试顺序是个**降级链**：从 otadata 指定的序号**向前**逐个试到 factory 分区 → 再**向后**试其余 OTA 槽 → 再试 test 分区 → 全军覆没则 `No bootable app partitions in the partition table` + `bootloader_reset()` 复位循环。每个分区的尝试由 `try_load_partition()` 完成：读镜像头（魔数 `0xE9`）、校验段与 checksum/hash，成功则打 `Loaded app from partition at offset 0x...`（`:480`）。

真正的一跳在 `set_cache_and_start_app()`（`:1035`）：把 app 的 DROM/IROM 段经 `mmu_hal_map_region()` 建好 Flash→虚拟地址映射、使能两核 cache 总线，然后：

```c
typedef void (*entry_t)(void) __attribute__((noreturn));
entry_t entry = ((entry_t) entry_addr);   // entry_addr 来自镜像头
(*entry)();                               // bootloader_utility.c:1150-1155
```

这个 `entry_addr` 就是应用镜像的入口函数——`call_start_cpu0`（下一节）。XIP 段（代码/只读数据）**不搬运**，靠刚建好的映射就地执行；只有 data/bss 落 RAM 的段被实际拷贝。MMU 映射的构建细节归 [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow|FreeRTOS（三）]]3.3 节管，此处不重复。

### 5. OTA 回滚（ota_data）一段话版

ota_data 分区存两个 4KB 扇区的 `esp_ota_select_entry_t`（序号 ota_seq + CRC + 状态），bootloader 取 CRC 有效、seq 更大的那个，`boot_index = (ota_seq - 1) % app_count` 定槽位。开启 `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE` 后还有一层保险：新镜像首次启动被标为 `ESP_OTA_IMG_PENDING_VERIFY`，应用必须主动调 `esp_ota_mark_app_valid_cancel_rollback()` 转正，否则下次启动 bootloader 把 PENDING_VERIFY 改判 ABORTED（`bootloader_utility.c:395-404`）、回退旧槽——"启动成功"与"运行健康"被区分开，这是 OTA 设备防变砖的关键一招（第十七章 RainMaker OTA 时会用上）。factory_demo 单 ota_0 分区无回滚余地，第四章 4.2 节已经从空间取舍角度解释过。

---

## 6.4 应用侧：从 call_start_cpu0 到 app_main

### 1. port 层：call_start_cpu0（cpu_start.c）

二级 bootloader 跳来的入口在 `components/esp_system/port/cpu_start.c:965`。v6 里它被精简成一条清晰的流水线（源码逐行核对）：

```c
void IRAM_ATTR call_start_cpu0(void)
{
    init_cpu();               // CPU 异常向量、eFuse 相关检查
    get_reset_reason(rst_reas);
    init_bss(rst_reas);       // 清 app 的 BSS（注释：此前别做复杂事/early log）
    ...
    ext_mem_init();           // cache/MMU 收尾
    sys_rtc_init(rst_reas);   // 电源相关；此后才能做 MSPI timing 调整
    mspi_init();              // ★ Flash 最终状态 + PSRAM 初始化（见下）
    /* ---- 分隔线注释原文：CPU0 此后才能访问外部内存(cache) ---- */
    system_early_init(rst_reas);   // 打出 "Multicore app"，拉起 CPU1
    SYS_STARTUP_FN();         // 按核号跳 g_startup_fn[core]()，CPU0 落到 start_cpu0_default
}
```

`mspi_init()`（`:609`）值得展开，因为 BOX-3 的 8MB Octal PSRAM 在这里上线：`spi_flash_init_chip_state()` 把 Flash 从 bootloader 的预备状态升到用户配置（QIO、80MHz）；`mspi_timing_flash_tuning()` 调时序；然后 `esp_psram_chip_init()`（`CONFIG_SPIRAM_BOOT_HW_INIT`）初始化 PSRAM 硬件——失败时按配置二选一：`Failed to init external RAM; continuing without it.`（`SPIRAM_IGNORE_NOTFOUND=y`，带病继续）或 `Failed to init external RAM!` + `abort()`（`:637-640`）。这是 PSRAM 类翻车点的源码出处。

`system_early_init()` 里的 `ESP_EARLY_LOGI(TAG, "Multicore app")`（`:684`）是日志里区分单双核固件的锚点，紧随其后 `start_other_core()` 把 CPU1 从复位里放出来（CPU1 走 `call_start_cpu1`，细节归 FreeRTOS（三）3.4 节）。

### 2. start_cpu0_default：组件构造（init.fn 数组）

`SYS_STARTUP_FN()` 展开为 `(*g_startup_fn[core_id])()`（`startup_internal.h:36`），CPU0 落到 `components/esp_system/startup.c:172` 的 `start_cpu0_default()`：

```c
static void start_cpu0_default(void)
{
    do_core_init();              // ESP_SYSTEM_INIT_FN 的 CORE 阶段
    __libc_init_array();         // C 运行时：全局构造器
    do_secondary_init();         // SECONDARY 阶段；内部先 resume 其它核
    esp_startup_start_app();     // 交给 FreeRTOS（下小节）
    ESP_INFINITE_LOOP();
}
```

**init.fn 数组是 ESP-IDF 组件向启动流程注册代码的机制**：任何组件用 `ESP_SYSTEM_INIT_FN(名字, 阶段, 核掩码, 优先级)` 声明一个函数，链接器把它收进 `_esp_system_init_fn_array_start..end` 区间，`do_system_init_fn()` 遍历执行（`startup.c:92-115`）。执行次序由 `components/esp_system/system_init_fn.txt` 文档化并有 CI 盯着——这份文件本身就是绝佳的启动地图，摘 BOX-3 相关条目：

| 阶段:优先级   | 函数                     | 作用 / 对应日志                                                     |
| ------------- | ------------------------ | ------------------------------------------------------------------- |
| CORE:10       | `init_show_cpu_freq`     | `Pro cpu start user code`、`cpu freq: 240000000 Hz`                 |
| CORE:20       | `init_show_app_info`     | `Application information:` 块（工程名、版本、IDF 版、ELF SHA256）   |
| CORE:100      | `init_heap`（heap 组件） | **堆初始化**；注释强调必须在 CPU1 上线后，否则链表被 ROM 初始化踩坏 |
| CORE:103      | `add_psram_to_heap`      | PSRAM 并入堆——BOX-3 的大内存时代从此行开始                          |
| CORE:110~120  | `init_vfs_usj` 等        | console 接到 USB-Serial-JTAG、stdio 就绪——**日志 tag 从此规范化**   |
| SECONDARY:201 | `init_pm`                | 电源管理（BOX-3 的 DFS 动态调频在此就位）                           |
| SECONDARY:999 | `init_disable_rtc_wdt`   | **关启动看门狗**，注释明言"必须是最后一步"                          |

`do_secondary_init()` 里还有个易忽略的动作：`startup_resume_other_cores()` 先放 CPU1 去跑它自己的 SECONDARY 阶段，CPU0 同时跑自己的，然后 CPU0 自旋等所有核汇报完成——组件初始化在 S3 上是**双核并行**的。

### 3. esp_startup_start_app：main 任务诞生与调度器点火

`esp_startup_start_app()` 在 `components/freertos/app_startup.c:61`——注意这是 **freertos 组件**的文件，系统启动的最后一步实际由内核组件接管：

```c
void esp_startup_start_app(void)
{
    esp_int_wdt_init(); esp_int_wdt_cpu_init();   // 中断看门狗
    esp_crosscore_int_init();                     // 跨核中断
    BaseType_t res = xTaskCreatePinnedToCore(main_task, "main",
                          ESP_TASK_MAIN_STACK, NULL,
                          ESP_TASK_MAIN_PRIO, NULL, ESP_TASK_MAIN_CORE);
    ...
    vTaskStartScheduler();                        // 点火，永不返回
}
```

main 任务的三围全部来自 `esp_task.h`：优先级 `ESP_TASK_MAIN_PRIO = ESP_TASK_PRIO_MIN + 1 = 1`（很 低！），栈深 `ESP_TASK_MAIN_STACK = CONFIG_ESP_MAIN_TASK_STACK_SIZE + 512`，核亲和 `CONFIG_ESP_MAIN_TASK_AFFINITY`（默认 CPU0）。

### 4. main_task：app_main 的宿主与自删

```c
static void main_task(void* args)
{
    ESP_LOGI(MAIN_TAG, "Started on CPU%d", (int)xPortGetCoreID());
    reclaim_startup_stack_memory_for_heap();      // 回收启动栈内存入堆（等所有核就绪）
    ... esp_task_wdt_init(&twdt_config);          // 任务看门狗
    ESP_LOGI(MAIN_TAG, "Calling app_main()");     // 源码注释：pytest 拿它当应用起点标记
    extern void app_main(void);
    app_main();
    ESP_LOGI(MAIN_TAG, "Returned from app_main()");
    vTaskDelete(NULL);                            // main 任务自删
}
```

两个工程要点：

1. **`app_main` 返回是合法的**——FreeRTOS 系列第一章实验时你可能已注意到 main 任务消失、其余任务照跑；本节就是那句伏笔的兑现处：`vTaskDelete(NULL)` 把 main 任务从就绪链表摘除，栈与 TCB 交给 Idle 任务回收（回收机制细节见 FreeRTOS 系列）。
2. **main 任务优先级只有 1**：在 `app_main` 里直接死循环做重活，会饿死所有同优先级任务、且被任何更高优先级任务抢占——长活务必像第一章那样拆成独立任务。

---

## 6.5 启动日志逐行对账（框架版）

> [!warning] 标注：日志为框架示意
> 下面这段日志的**每行格式与出处均已对源码核实**，但具体数值（时间戳、段地址、芯片版本号、Flash 频率等外设参数）是占位符或按 IDF 默认配置预填——**真实输出待真机验证 / QEMU 日志待主会话补录**。到货后用 `idf.py -p /dev/ttyACM0 monitor` 抓 BOX-3 实机日志替换占位符，逐行核销。

```text
rst:0x1 (POWERON_RESET),boot:0x8 (SPI_FAST_FLASH_BOOT)
configsip:0, SPIWP:0xe0, ...                                     ← ROM：Flash 采样参数
load:0x3ffc<xxxx>,len:<nnnn> entry 0x403c<xxxx>                   ← ROM：装载二级 bootloader 并跳转
I (28) boot: ESP-IDF v6.0.2 2nd stage bootloader                  ← bootloader_print_banner()
I (28) boot: compile time <...>                                   ← 同上（可配置关闭）
I (30) boot: chip revision: v<0.n>                                ← bootloader_check_bootloader_validity()
I (31) boot: efuse block revision: v<0.n>                         ← 同上
I (32) boot: Boot SPI Speed : 80MHz                               ← print_flash_info()（esp32s3 版）
I (32) boot: SPI Mode       : QIO                                 ← 同上（BOX-3 sdkconfig 默认 QIO）
I (40) boot: Partition Table:                                     ← bootloader_utility_load_partition_table()
I (40) boot: ## Label            Usage          Type ST Offset   Length
I (..) boot:  1 nvs              WiFi data        01 02 00010000 00006000   ← factory_demo 分区表逐行（格式串见正文彩蛋）
I (..) boot:  5 ota_0            OTA app          00 10 000<....> 00420000
I (..) boot: End of partition table
I (..) boot: Enabling RNG early entropy source...                 ← bootloader_enable_random()
I (..) boot: Trying partition index <n> offs 0x<....> size 0x<....>  ← 尝试各 app 分区（DEBUG 级，默认不显）
I (56) boot: Loaded app from partition at offset 0x00<....>       ← try_load_partition() 校验成功
I (60) cpu_start: Pro cpu start user code                         ← init_show_cpu_freq()
I (60) cpu_start: cpu freq: 240000000 Hz                          ← 同上
I (62) cpu_start: Application information:                        ← init_show_app_info()
I (62) cpu_start: Project name:     factory_demo                  ← 同上
I (..) cpu_start: Multicore app                                   ← system_early_init()，CPU1 将上线
I (..) cpu_start: Starting scheduler on CPU0                      ← esp_startup_start_app()（DEBUG 级）
I (..) main_task: Started on CPU0                                 ← main_task() 第一行
I (..) main_task: Calling app_main()                              ← ★ 你的代码即将执行
... 应用日志 ...
I (..) main_task: Returned from app_main()                        ← app_main 返回（若返回）
```

逐行来源表（与上面 log 对应，均为实地核对）：

| 日志段                                   | 打印者                   | 源码位置                                                |
| ---------------------------------------- | ------------------------ | ------------------------------------------------------- |
| `rst:` / `boot:` / `load:` / `entry`     | ROM bootloader（无源码） | rst 值查 `esp32s3/rom/rtc.h` 枚举；boot 值解码见 6.2 节 |
| `ESP-IDF ... 2nd stage bootloader`       | boot                     | `bootloader_init.c:111` `bootloader_print_banner()`     |
| `chip revision` / `efuse block revision` | boot                     | `bootloader_init.c:58,64`                               |
| `Boot SPI Speed` / `SPI Mode`            | boot                     | `bootloader_flash_config_esp32s3.c:201,226`             |
| `Partition Table:` 各行                  | boot                     | `bootloader_utility.c:163-270`                          |
| `Loaded app from partition at offset`    | boot                     | `bootloader_utility.c:480` `try_load_partition()`       |
| `Pro cpu start user code` / `cpu freq`   | cpu_start                | `startup_funcs.c:54-56`                                 |
| `Application information:`               | cpu_start                | `esp_app_format/esp_app_desc.c:122-132`                 |
| `Multicore app`                          | cpu_start                | `port/cpu_start.c:684`                                  |
| `Started on CPU0` / `Calling app_main()` | main_task                | `freertos/app_startup.c:178,204`                        |

`rst:0x1` 的解码示例：`POWERON_RESET = 1`（上电复位）；其他常见值同在 `esp32s3/rom/rtc.h` 枚举里（如 deep sleep 为 5）。`boot:0x8` 按 6.2 节的位定义读作"GPIO0=1、GPIO46=0，SPI 启动"。

---

## 6.6 与 FreeRTOS 系列第三章的分工

同一主题两条线写，边界这样切：

| 维度       | 本篇（工程视角）                        | [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow | FreeRTOS（三）]]（构建/内核视角） |
| ---------- | --------------------------------------- | -------------------------------------------------------------- | --------------------------------- |
| 主角       | BOX-3 真机 esp32s3、v6.0.2 源码逐行对账 | 经典 esp32 + QEMU、构建系统怎么产出这些镜像                    |
| bootloader | 启动模式 strap、分区表校验细节、回滚    | 为什么 bootloader 是独立 CMake 子工程                          |
| init.fn    | 次序表 `system_init_fn.txt` 的工程读法  | 链接器收集机制本身                                             |
| 调度器     | 到 `vTaskStartScheduler()` 为止         | `xPortStartScheduler` 往下的汇编级派发                         |
| 证据       | 源码行号 + 真机日志（待补录）           | QEMU 日志 + GDB 断点回溯                                       |

两篇互不重复，卡在某一环时按表跳线。

---

## 6.7 翻车点表与小结

| 症状（日志特征）                                                         | 根因                                                                                                                              | 处理                                                                              |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 日志停在 `DOWNLOAD_BOOT(...)`、esptool 连不上应用，重启也不进 Flash 启动 | GPIO0 在复位采样时为低（BOOT 键按下/外设拉低），进了下载模式；对照 `boot:0xNN` 的 0x08 位                                         | 松开 BOOT；排查 GPIO0 上的外设驱动；下载模式本身按 `Ctrl-]` 退出监视器重启即可    |
| 反复打印 `rst:0x10 (RTCWDT_RTC_RESET)...` + `invalid header: 0xffffffff` | 空片/擦过的 Flash 上 ROM 找不到 0xE9 镜像头（全 0xFF 即擦除态），复位循环——官方 ESP-FAQ 对此场景的原话是"flash is not programmed" | 正常烧录固件；烧录中断导致半写时先 `esptool.py erase_flash` 再重烧                |
| `boot: Failed to verify bootloader / invalid chip revision` 后复位循环   | bootloader 镜像头与芯片版本不匹配，或 bootloader 区被误写                                                                         | 重烧 bootloader（`idf.py flash` 三件套齐烧）；排查镜像是否烧错芯片目标            |
| `flash_parts: partition N invalid ... exceeds flash chip size`           | 分区表 offset/size 越出实际 Flash 容量（如按 32MB 排表烧进 16MB 板）                                                              | 修 partitions.csv 后重新 flash 分区表                                             |
| `cpu_start: Failed to init external RAM!` 后 abort（待真机验证具体形态） | PSRAM 初始化失败：Octal 焊接不良/时序配错（`SPIRAM_MODE_OCT` 与板不符）                                                           | 核对 sdkconfig 的 PSRAM 模式/频率；调试期可临时 `SPIRAM_IGNORE_NOTFOUND` 带病启动 |
| `boot: ota data partition invalid, falling back to factory`              | otadata 两扇区 CRC 全坏，但好歹有 factory 分区兜底                                                                                | 重新做 OTA；无 factory 的分区表要警惕变砖风险                                     |
| `main_task: Returned from app_main()` 之后任务消失、代码"不跑了"         | 误以为 app_main 是超级循环——它返回即 main 任务自删（6.4 节）                                                                      | 长期逻辑放独立任务，或 app_main 里 for(;;) + vTaskDelay                           |
| 偶发进下载模式/启动乱套                                                  | 外设占用 GPIO0/46/3/45 strap 脚，或 Octal PSRAM 板把 GPIO33~37 拉去他用（6.2 节）                                                 | 复位窗口避开 strap 脚；GPIO33~37 在 R8V 板上禁用                                  |

本章小结：

- 启动是**三级接力**：ROM（掩膜、不可改、只认 0x0 的 0xE9 镜像头）→ 二级 bootloader（分区表/校验/回滚/跳转）→ 应用（C 运行时 → 组件 → 内核 → main 任务）。每一级只做"让下一级能跑起来"的最小集。
- ROM 的启动模式由 **GPIO0/GPIO46 strap 采样**决定，`boot:0x8` 可按 GPIO_STRAP 寄存器位（0x08=GPIO0、0x04=GPIO46）解码；下载模式就是 ROM 内建的 UART/USB 烧录通道。
- 二级 bootloader 主链五步：`call_start_cpu0` → `bootloader_init`（console→banner→Flash 预备）→ 读 0x8000 分区表并逐项校验 → otadata/降级链选槽 → `set_cache_and_start_app` 建 MMU 映射一跳了之；回滚靠 otadata 的 PENDING_VERIFY 状态机。
- 应用侧骨架：`call_start_cpu0`（BSS→MSPI/PSRAM→拉 CPU1）→ `start_cpu0_default`（**init.fn 数组**两阶段并行 + `__libc_init_array`）→ `esp_startup_start_app`（创建优先级 1 的 main 任务、启动调度器）→ `app_main`，返回即自删。
- v6 关键差异一处：**PSRAM 初始化移到了应用侧** `mspi_init()`，bootloader 只管 Flash 预备状态——对着老教程读日志时先校准版本。

下一章走进 app_main 之后的世界：ESP_LOG 的分级与 EARLY 版、NVS 键值存储、esp_event 事件循环、esp_timer——系统服务层是它们撑起来的，本章 init.fn 表里那几个 CORE 阶段条目正好是入口。
