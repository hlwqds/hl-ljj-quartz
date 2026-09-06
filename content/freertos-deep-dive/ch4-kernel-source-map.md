---
title: "FreeRTOS 深度解析（四）：源码地图——内核结构、Kconfig 裁剪与编译产物"
date: 2026-08-26
description: "实读 ESP-IDF v6.0.2 的 components/freertos/CMakeLists.txt 与 Kconfig：两棵内核树到底谁是默认、include/ 公共头文件各管什么、menuconfig 背后的 FreeRTOSConfig.h 翻译层、build 目录里的内核足迹，最后用一个『改一行内核源码 + QEMU 验证』的实验把整张地图走活。"
tags: [freertos, rtos, esp32, esp-idf, kconfig, cmake]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 4. **第四章：源码地图——内核结构、Kconfig 裁剪与编译产物**

# FreeRTOS 深度解析（四）：源码地图——内核结构、Kconfig 裁剪与编译产物

这一章回答四个问题：**components/freertos/ 里每个文件是干什么的**、**两棵内核树到底哪棵被编进固件**（这个问题比多数资料说的更有意思）、**Kconfig 裁剪是怎么作用到内核源码上的**、**编译产物里去哪里亲眼看到内核**。读完它，你应该能完成一个完整闭环：改一行内核源码 → 重编 → QEMU 里看到效果——这是后面二十章做实验的标准动作。

所有结论基于实读 ESP-IDF **v6.0.2** 的 `components/freertos/CMakeLists.txt`、`Kconfig`、`config/include/freertos/FreeRTOSConfig.h`、两棵树各自的说明文档（`idf_changes.md` / `porting_notes.md`）与 `heap_idf.c`、linker 片段。文中的机制描述都可以用同样的方式复核。

---

## 4.1 组件解剖：components/freertos/ 全景

先给结论：**FreeRTOS 在 ESP-IDF 里没有特殊地位，它就是一个普通组件**。它的 `CMakeLists.txt` 在配置期做四件事：挑一棵内核树、拼出 include 搜索路径、把内核接到 IDF 的服务上（堆、tick、启动流程）、按 Kconfig 决定代码放哪个内存段。理解了这四件事，这个目录就没有秘密了。

以 v6.0.2 为准的顶层结构（`CMakeLists.txt` 头部注释自带一张架构图，下面是它与实际文件的对应）：

```text
$IDF_PATH/components/freertos/
├── CMakeLists.txt           # 本章主角之一：挑树、拼路径、注册组件
├── Kconfig                  # 本章主角之二：menuconfig 里全部 FREERTOS_* 选项
├── FreeRTOS-Kernel/         # 内核树 A：IDF FreeRTOS（默认编入！见 4.2）
│   ├── tasks.c queue.c timers.c event_groups.c
│   ├── stream_buffer.c list.c
│   ├── include/  portable/
│   └── idf_changes.md       # 相对 Vanilla v10.5.1 的全部改造清单
├── FreeRTOS-Kernel-SMP/     # 内核树 B：Amazon SMP FreeRTOS（实验，默认不编）
│   ├── （同上六个 .c + include/ + portable/）
│   └── porting_notes.md     # 迁移到上游 SMP 内核的官方笔记
├── esp_additions/           # IDF 扩展 API 宿主（idf_additions.h/c 等）
├── config/                  # FreeRTOSConfig.h 模板（Kconfig → config* 翻译层）
├── heap_idf.c               # pvPortMalloc → IDF heap 组件的转接头
├── port_systick.c/.h        # tick 中断的产生与接入（esp_timer / 硬件定时器）
├── port_common.c            # 各架构共享的端口胶水
├── app_startup.c            # start_app / start_app_other_cores，拉起 main 任务
├── linker_common.lf         # 链接脚本片段（三份，见 4.4 与 4.5）
├── linker.lf                #   用于树 A
└── linker_smp.lf            #   用于树 B
```

逐个说职责，并标注"从哪知道的"——本章坚持每个论断可复核：

| 文件 / 子目录          | 职责                                                                                                                                | 依据                                                      |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| `FreeRTOS-Kernel/`     | **IDF FreeRTOS**：Vanilla v10.5.1 加双核 SMP 改造（`tasks.c` 约 273KB）                                                             | 树内 `idf_changes.md` 自述；`CMakeLists.txt` 默认选择     |
| `FreeRTOS-Kernel-SMP/` | **Amazon SMP FreeRTOS**：上游 v11.1.0 SMP 内核的拷贝（`tasks.c` 约 353KB），实验性                                                  | 树内 `porting_notes.md` 自述；`Kconfig` 的 `FREERTOS_SMP` |
| `esp_additions/`       | IDF 扩展 API：`xTaskCreatePinnedToCore()` 的声明/包装、`...WithCaps()` 家族、TLSP 删除回调等                                        | `idf_additions.h` 头部注释与 `CMakeLists.txt` 源文件清单  |
| `config/`              | `FreeRTOSConfig.h` 模板：把 `CONFIG_FREERTOS_*` 翻译成内核的 `config*` 宏                                                           | 4.4.3 实读                                                |
| `heap_idf.c`           | `pvPortMalloc()` → `heap_caps_malloc()`、`vPortFree()` → `heap_caps_free()`，`xPortGetFreeHeapSize()` → `heap_caps_get_free_size()` | `heap_idf.c` 源码（全文件仅 109 行）                      |
| `port_systick.c`       | tick 源接到 Kconfig 选定的定时器（ESP32 默认 Xtensa Timer 0）                                                                       | `Kconfig` 的 `FREERTOS_CORETIMER`                         |
| `app_startup.c`        | 提供 `start_app`/`start_app_other_cores`，创建 main 任务并在其中调用 `app_main()`                                                   | `CMakeLists.txt` 注释与 `-u app_main` 链接选项            |
| `linker*.lf`           | 声明 `libfreertos.a` 里哪些函数进 IRAM（`noflash_text`）、哪些留 Flash                                                              | `linker_common.lf` 等三份片段                             |

两个立刻值得注意的细节：

**一，bootloader 不编内核。** `CMakeLists.txt` 开头检查 `NON_OS_BUILD`：bootloader 构建时该组件直接空注册返回——FreeRTOS 的配置头仍然可用，但调度器、队列这些代码完全不进 bootloader。二级 bootloader 是裸机程序（第 3 章的结论在这里落到了构建系统层面）。

**二，`app_main` 是被链接器强行留下的。** 组件通过 `target_link_libraries(... INTERFACE "-u app_main")` 告诉链接器"无论谁引用没引用，`app_main` 符号必须保留"。你的 `app_main()` 由此从"看起来没人调用"变成入口——细节属于第三章的启动流程，这里只需记住：这条 `-u` 选项写在 `components/freertos/CMakeLists.txt` 里，而不是什么神秘的 startup 文件。

---

## 4.2 两棵内核树：谁是默认

这是全章最重要的一节，因为它纠正一个流传极广的误解。

### 1. CMakeLists 的选择逻辑（实读）

`components/freertos/CMakeLists.txt` 里，树的选择逻辑就这几行：

```cmake
if(CONFIG_FREERTOS_SMP)
    set(kernel_impl "FreeRTOS-Kernel-SMP")
else()
    set(kernel_impl "FreeRTOS-Kernel")
endif()
```

之后所有内核源文件、include 目录、链接片段全部以 `${kernel_impl}` 为根拼接——**配置期二选一，另一棵树一个字节都不进固件**。而 `CONFIG_FREERTOS_SMP` 在 `Kconfig` 里的定义是：

```text
config FREERTOS_SMP
    bool "Run the Amazon SMP FreeRTOS kernel instead (FEATURE UNDER DEVELOPMENT)"
    depends on !IDF_TARGET_ESP32P4 && !IDF_TARGET_ESP32H4
    default "n"
```

默认 `n`，且帮助文本写明：不勾选时使用的是位于 `components/freertos/FreeRTOS-Kernel` 的 **IDF FreeRTOS 内核**，并且 "**Both kernel versions are SMP capable**"——两棵树都支持 SMP。

### 2. 谁是谁：一次说清

| 维度           | `FreeRTOS-Kernel/`                                                   | `FreeRTOS-Kernel-SMP/`            |
| -------------- | -------------------------------------------------------------------- | --------------------------------- |
| 官方名字       | IDF FreeRTOS                                                         | Amazon SMP FreeRTOS               |
| 上游基线       | Vanilla **v10.5.1**（文件头版本串 "V10.5.1 (ESP-IDF SMP modified)"） | 上游 SMP 分支 **v11.1.0** 的拷贝  |
| SMP 由谁实现   | Espressif 自己改：per-core 状态、细粒度自旋锁、每核 Idle             | 上游官方设计：亲和掩码、全局锁    |
| 编入条件       | 默认（`FREERTOS_SMP=n`）                                             | 勾选 `FREERTOS_SMP=y`（实验特性） |
| 随附文档       | `idf_changes.md`（改造清单）                                         | `porting_notes.md`（迁移笔记）    |
| `tasks.c` 体量 | ~273 KB                                                              | ~353 KB                           |

也就是说：**你的 ESP32 工程默认编入的是 `FreeRTOS-Kernel/`，它不是"单核版"，而是那个以 v10.5.1 为基线、被 Espressif 深度改造出双核能力的 IDF FreeRTOS**——第 1 章讲的 `xTaskCreatePinnedToCore()`、每核一个 Idle 任务、Best-Effort Round-Robin，全部住在这棵树里（其 `include/freertos/task.h` 直接声明了 `xTaskCreatePinnedToCore()`）。

`FreeRTOS-Kernel-SMP/` 是新玩家：上游 FreeRTOS 官方终于做出了自己的 SMP 内核（v11 系），Espressif 把它引进来作为**实验性替代**，帮助文本里那句大写的 "FEATURE UNDER DEVELOPMENT" 和 `porting_notes.md` 里成串的 Todo 都在提醒：它是未来，不是现在。

### 3. 为什么两棵树并存

时间线一摆就清楚：

```text
2016~      ESP32 双核上市，上游内核是纯单核设计
           → Espressif 自己 fork 出 SMP 改造（今天的 IDF FreeRTOS）
           ……
v11        上游官方发布 SMP 内核（亲和掩码、跨核调度一套全新模型）
           → 与 IDF fork 的模型差异巨大，无法平滑合并
v6.0       IDF 引入上游 SMP 内核为实验选项（FreeRTOS-Kernel-SMP/）
           → 新旧两套内核并存，配置期二选一，迁移期开始
```

两套模型的差异有多大？`porting_notes.md` 里记了一笔账（第二十二章的预告）：核亲和从"钉死或不钉"变成**掩码**（可同时亲和多个核的组合）；`vTaskSuspendAll()` 从每核独立变成**全局**生效；临界区从细粒度自旋锁（队列一把、定时器一把）变成**全局大锁**；Idle 任务从每核钉死一个变成**不钉核的池子**。这不是"打补丁"级别的差异，是两套设计——所以只能两棵树。

### 4. `CONFIG_FREERTOS_UNICORE` 不是选树的开关

第二个常见误解：以为"双核编 SMP 树、开 UNICORE 编单核树"。**错。** `Kconfig` 里 `FREERTOS_UNICORE` 的含义是"FreeRTOS 只在第一个核上跑"：它会 `select ESP_SYSTEM_SINGLE_CORE_MODE`，并把隐藏选项 `FREERTOS_NUMBER_OF_CORES` 置 1。核数与选树是两个正交的开关：

```text
                       CONFIG_FREERTOS_SMP = n（默认）   CONFIG_FREERTOS_SMP = y
                    ┌────────────────────────────────┬────────────────────────────────┐
 CONFIG_FREERTOS_   │  FreeRTOS-Kernel/ 双核运行       │  FreeRTOS-Kernel-SMP/ 双核运行  │
 UNICORE = n（默认） │  ← ESP32 出厂形态：两核、两 Idle  │  ← 实验内核                    │
                    ├────────────────────────────────┼────────────────────────────────┤
 CONFIG_FREERTOS_   │  FreeRTOS-Kernel/ 单核运行       │  FreeRTOS-Kernel-SMP/ 单核运行  │
 UNICORE = y        │  （configNUMBER_OF_CORES = 1）   │                                │
                    └────────────────────────────────┴────────────────────────────────┘
```

`FREERTOS_UNICORE` 只在 ESP32-S2 这类天生单核的芯片（以及 Linux 目标）上默认开。它影响的是整块 SoC 的工作方式，不只是 FreeRTOS。

### 5. 一个流传极广的误解

> [!warning] "双核 ESP32 编的是 FreeRTOS-Kernel-SMP/"
> 按目录名望文生义，很多人（包括大量中文资料）会推断"双核 = 编 SMP 树"。按 v6.0.2 实读构建脚本，这是**反的**：默认编入的是 `FreeRTOS-Kernel/`（它本身就是 SMP 改造版，即 IDF FreeRTOS）；`FreeRTOS-Kernel-SMP/` 是实验性的上游 Amazon SMP 内核，需手动开启 `CONFIG_FREERTOS_SMP`。选树的开关是 `CONFIG_FREERTOS_SMP`，不是 `CONFIG_FREERTOS_UNICORE`。本节开头的三个源文件（`CMakeLists.txt`、`Kconfig`、`porting_notes.md`）可以一锤定音——遇到任何资料对树归属含糊其辞，用这三处复核即可。

> [!tip] Vanilla vs ESP-IDF：内核树的形态
> | 主题 | Vanilla FreeRTOS | IDF FreeRTOS（ESP-IDF 组件） |
> | --- | --- | --- |
> | 内核来源 | 官网/ GitHub 下载源码包，自己拷进工程 | 组件内置，两棵树配置期二选一 |
> | 换版本 | 手动替换源码文件 | 换 IDF 版本（内核与组件绑定演进） |
> | 单双核 | 单核一份源码，没有选择问题 | 选树（`FREERTOS_SMP`）与核数（`FREERTOS_UNICORE`）两个正交开关 |
> | SMP 能力 | v10.5.1 无（v11 上游 SMP 为另一条产品线） | 两棵树都有，实现模型不同 |
> | `tskNO_AFFINITY` 值 | ——（无亲和概念） | 树 A 为 `0x7FFFFFFF`，树 B 为 `0xFFFFFFFF`（`Kconfig` 隐藏选项 `FREERTOS_NO_AFFINITY` 分别定义） |

最后那行小细节值得多看一眼：连"无亲和"这个哨兵值，两棵树都不一样——它们真的不是同一套代码的两个副本。

---

## 4.3 include/：公共头文件的角色

两棵树的公共 API 面一致，靠的是完全同构的 `include/freertos/` 目录布局。你的代码永远写 `#include "freertos/FreeRTOS.h"`，从不需要关心底下是哪棵树。

### 1. 五个必须认识的头文件

| 头文件       | 角色                                                                                                                                                      | 你会在里面找到什么                                                                                                             |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `FreeRTOS.h` | **总入口与配置消费端**。所有 `config*` 宏的默认值、合法性检查（缺配/错配直接 `#error`）、基础类型（`TickType_t` 等），并拉入 `projdefs.h` 与 `portable.h` | 内核每个 `.c` 的第一个 include 都是它                                                                                          |
| `task.h`     | 任务 API 与任务模型                                                                                                                                       | `xTaskCreate()` 族、`TaskHandle_t`、`tskNO_AFFINITY`；IDF 树里还直接声明 `xTaskCreatePinnedToCore()`（第 5 章主角）            |
| `queue.h`    | 队列 API                                                                                                                                                  | `xQueueSend()` 族——注意它只管队列本身                                                                                          |
| `projdefs.h` | 基础工具宏                                                                                                                                                | `pdPASS`/`pdFAIL`、`pdTRUE`/`pdFALSE`、`pdMS_TO_TICKS()`、`portTICK_PERIOD_MS`                                                 |
| `portable.h` | **内核与端口的服务边界**                                                                                                                                  | `pvPortMalloc()`/`vPortFree()` 声明、`vApplicationMallocFailedHook()` 等应用钩子声明、MPU 包装入口（第 16 章展开"契约"这个词） |

### 2. 其余头文件一览

| 头文件                                                                 | 一句话                                                                                   |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `semphr.h`                                                             | 在 `queue.h` 之上用宏包装出信号量/互斥量 API——"信号量即队列"的第一手证据（第 10、11 章） |
| `timers.h` / `event_groups.h` / `stream_buffer.h` / `message_buffer.h` | 对应内核对象的 API，与同名 `.c` 一一映射                                                 |
| `list.h`                                                               | 内核链表原语，`tasks.c` 等内本地包含；第 6 章整章的地基                                  |
| `atomic.h`                                                             | 无锁原语（端口提供的原子操作包装）                                                       |
| `mpu_prototypes.h` / `mpu_wrappers.h` / `mpu_syscall_numbers.h`        | MPU 受保护模式（IDF 不使用，读到可跳过）                                                 |
| `stack_macros.h`                                                       | 栈溢出检查的内部实现宏（对应 `Kconfig` 的栈检查选项）                                    |
| `deprecated_definitions.h`                                             | 旧 API 名到新 API 的宏兼容层                                                             |
| `newlib-freertos.h` / `picolibc-freertos.h`                            | C 库可重入结构与任务的挂接                                                               |

### 3. include 路径是怎么拼出来的

`CMakeLists.txt` 把这些目录登记为公共 include 路径（顺序与角色如注释所述）：

```text
你的代码  #include "freertos/FreeRTOS.h"
   │
   ▼  按组件 include_dirs 依次解析（无论哪棵树被编入，布局完全一致）
config/include                      → freertos/FreeRTOSConfig.h（模板，4.4.3）
config/include/freertos             → FreeRTOSConfig.h（供内核 .c 直接 include）
config/xtensa/include               → freertos/FreeRTOSConfig_arch.h（架构相关补充）
${kernel_impl}/include              → freertos/task.h、queue.h ……全部公共头
${kernel_impl}/portable/xtensa/include → freertos/portmacro.h（第 16 章主角）
esp_additions/include               → freertos/idf_additions.h 等 IDF 扩展
```

三件事值得圈出来：

1. **`freertos/` 前缀是组件玩的路径戏法**：树内的头文件住在 `include/freertos/` 子目录里，所以应用侧统一用 `"freertos/xxx.h"` 引用。两棵树都遵守这个布局，切换对应用代码透明。
2. **IDF 扩展 API 与内核 API 分家**：树 A 的 `task.h` 自带 `xTaskCreatePinnedToCore()`；切到树 B 时它由 `esp_additions/include/freertos/idf_additions.h` 补上（包装上游的 `xTaskCreateAffinitySet()`）。应用侧无论哪棵树都 `#include "freertos/task.h"`（必要时加 `idf_additions.h`），不需要改代码。
3. 内核自己的 `.c` 编译时带着 `_ESP_FREERTOS_INTERNAL` 宏（`CMakeLists.txt` 对 `tasks.c`/`queue.c` 等五个文件专门设置），用来标记"这是内核内部编译单元"——读源码遇到它时知道这不是公共 API 的一部分即可。

---

## 4.4 Kconfig：内核的裁剪面

### 1. 菜单结构

`idf.py menuconfig` → `Component config` → `FreeRTOS`，下面分三个子菜单，正好对应三种裁剪性质：

| 子菜单     | 内容                                                                   | 性质                                   |
| ---------- | ---------------------------------------------------------------------- | -------------------------------------- |
| **Kernel** | 上游 FreeRTOS 的经典 `config*` 项（tick 频率、钩子、定时器、栈检查……） | 对应 Vanilla 世界的 `FreeRTOSConfig.h` |
| **Port**   | ESP-IDF 端口层的项（ISR 栈、watchpoint、tick 定时器选择、IRAM 放置……） | Vanilla 里这些散落在端口代码里手改     |
| **Extra**  | 少量 IDF 特有扩展（如允许任务栈进 PSRAM）                              | 纯 IDF 话题                            |

### 2. 关键选项导览（实读 Kconfig）

| Kconfig 选项                                                                                   | 对应内核宏                                | 默认                   | 要点                                                                                                                                               |
| ---------------------------------------------------------------------------------------------- | ----------------------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FREERTOS_SMP`                                                                                 | ——                                        | `n`                    | 切换到 Amazon SMP 内核树（4.2；实验特性）                                                                                                          |
| `FREERTOS_UNICORE`                                                                             | ——                                        | `n`（S2/linux 为 `y`） | 只用第一个核；正交于选树（4.2.4）                                                                                                                  |
| `FREERTOS_HZ`                                                                                  | `configTICK_RATE_HZ`                      | **100**                | 范围 1~1000。默认 1 tick = 10ms——`vTaskDelay(1)` 的最粗粒度由此决定                                                                                |
| `FREERTOS_CHECK_STACKOVERFLOW`                                                                 | `configCHECK_FOR_STACK_OVERFLOW`          | Method 2（金丝雀）     | 三档：不查 / 查栈指针 / 查栈底魔数；用户不提供钩子时 IDF 给默认的 `vApplicationStackOverflowHook()`。第 21 章深挖                                  |
| `FREERTOS_IDLE_TASK_STACKSIZE`                                                                 | `configMINIMAL_STACK_SIZE`                | 1536 字节              | 装了重负载 idle/TLSP 钩子才需要加大                                                                                                                |
| `FREERTOS_ISR_STACKSIZE`                                                                       | ——                                        | 1536 字节              | **中断有自己的独立栈**（每核一份，总占用 ×2）。与 Cortex-M"中断借任务栈"截然不同，第 17 章展开                                                     |
| `FREERTOS_USE_TIMERS`                                                                          | `configUSE_TIMERS`                        | `y`                    | 关掉可整体裁掉定时器任务（见下文"链接器裁剪"）                                                                                                     |
| `FREERTOS_TIMER_TASK_PRIORITY` / `_STACK_DEPTH` / `_QUEUE_LENGTH`                              | `configTIMER_*`                           | 1 / 2048 / 10          | 定时器守护任务的三个旋钮（第 15 章）                                                                                                               |
| `FREERTOS_USE_TICKLESS_IDLE`                                                                   | `configUSE_TICKLESS_IDLE`                 | `n`                    | **依赖 `PM_ENABLE`**——IDF 把 tickless 与电源管理绑死（见下方暗线）                                                                                 |
| `FREERTOS_TASK_NOTIFICATION_ARRAY_ENTRIES`                                                     | `configTASK_NOTIFICATION_ARRAY_ENTRIES`   | 1                      | 每任务通知数组长度，加大则每个 TCB 都变胖（第 13 章）                                                                                              |
| `FREERTOS_THREAD_LOCAL_STORAGE_POINTERS`                                                       | `configNUM_THREAD_LOCAL_STORAGE_POINTERS` | 1（下限）              | 索引 0 被 pthread API 占用；开 TLSP 删除回调时数组翻倍                                                                                             |
| `FREERTOS_USE_TRACE_FACILITY` → `_USE_STATS_FORMATTING_FUNCTIONS` → `_GENERATE_RUN_TIME_STATS` | 同名 `config*`                            | 全 `n`                 | 打开 `vTaskList()`/运行时间统计；时钟源可选 esp_timer（1MHz，约 4290 秒回绕）或 CPU 时钟（240MHz 时约 17 秒回绕）。第 24 章调试主力                |
| `FREERTOS_CORETIMER`（choice）                                                                 | ——                                        | ESP32: Timer 0         | tick 源选 Xtensa Timer 0（中断 6，level 1）或 Timer 1（中断 15，level 3）；C3/S3 等走 SYSTIMER                                                     |
| `FREERTOS_IN_IRAM`                                                                             | ——                                        | `n`                    | 内核函数整体进 IRAM 换性能（见 4.4.4）                                                                                                             |
| `FREERTOS_WATCHPOINT_END_OF_STACK`                                                             | ——                                        | `n`                    | 用最后一个硬件 watchpoint 盯栈底 32 字节，溢出当场断下——比上下文切换时才检查的方法 1/2 及时得多，代价是少一个调试 watchpoint、可用栈最多缩 60 字节 |
| `FREERTOS_TASK_FUNCTION_WRAPPER`                                                               | ——                                        | 调试构建下 `y`         | 任务函数包一层 wrapper：任务函数误 return 时打错误并 abort，GDB 回溯/C++ 异常也靠它                                                                |
| `FREERTOS_NUMBER_OF_CORES`（隐藏）                                                             | `configNUMBER_OF_CORES`                   | 由 UNICORE 推导        | 1 或 2；将来会取代 UNICORE（Kconfig 注释里的 Todo）                                                                                                |

不必记住这张表——记住**裁剪面在哪**即可：改内核行为的第一反应应当是打开 menuconfig 搜 `FREERTOS`，而不是去找头文件改宏。

### 3. CONFIG*FREERTOS*_ → config_ 的翻译层

Vanilla 教程会教你"拷一份 `FreeRTOSConfig.h` 到工程里手动填宏"。**ESP-IDF 工程里没有（也不该有）你的 `FreeRTOSConfig.h`**——它由组件提供，位于 `config/include/freertos/FreeRTOSConfig.h`，全部工作是把 `sdkconfig` 生成的 `CONFIG_FREERTOS_*` 翻译给内核。节选实读内容：

```c
/* components/freertos/config/include/freertos/FreeRTOSConfig.h（节选） */
#include "sdkconfig.h"                                  /* 吃进 menuconfig 的结果 */

#define configUSE_PREEMPTION                         1
#define configTICK_RATE_HZ                           CONFIG_FREERTOS_HZ
#define configCPU_CLOCK_HZ                           ( CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ * 1000000 )
#define configMAX_PRIORITIES                         ( 25 )
#define configNUMBER_OF_CORES                        CONFIG_FREERTOS_NUMBER_OF_CORES
#define configSTACK_DEPTH_TYPE                       uint32_t

#if CONFIG_FREERTOS_CHECK_STACKOVERFLOW_NONE
    #define configCHECK_FOR_STACK_OVERFLOW    0
#elif CONFIG_FREERTOS_CHECK_STACKOVERFLOW_PTRVAL
    #define configCHECK_FOR_STACK_OVERFLOW    1
#elif CONFIG_FREERTOS_CHECK_STACKOVERFLOW_CANARY
    #define configCHECK_FOR_STACK_OVERFLOW    2
#endif
```

三个层次的信息：

1. **有些项 IDF 不开放**：`configUSE_PREEMPTION` 恒为 1（IDF 不支持协作式调度）、`configMAX_PRIORITIES` 固定 25、`configUSE_TIME_SLICING` 恒开——`menuconfig` 里找不到它们，因为组件替你做了决定。
2. **有些项会自动联动**：打开 `FREERTOS_TLSP_DELETION_CALLBACKS`，模板自动把 `configNUM_THREAD_LOCAL_STORAGE_POINTERS` 翻倍（回调指针和 TLSP 存同一数组）。
3. **模板还会替你算账**：文件开头有一组 `STACK_OVERHEAD_*` 辅助宏——编译器栈检查（`-fstack-check`）加 256 字节、`-O0` 加 320 字节、apptrace 加 1280 字节、栈 watchpoint 也要余量，最后合成 `configSTACK_OVERHEAD_TOTAL` 参与最小栈计算。Vanilla 世界里"Idle 栈不够跑挂了"这类坑，IDF 用模板里的这套启发式先兜一层。

改内核配置的合法路径因此只有一条：**`idf.py menuconfig`（或直接编辑 `sdkconfig`）→ 重新生成 `sdkconfig.h` → 模板翻译 → 内核重编**。直接改模板文件会在下次升级 IDF 时静默丢失。

### 4. 裁剪的另一只手：链接器

Kconfig 编译期裁剪之外，IDF 还叠了两层 Vanilla 没有的机制：

- **弱符号**：`FREERTOS_USE_TIMERS` 的帮助文本明说——只要你不调用任何软件定时器函数，IDF 定义的**空的弱符号 `xTimerCreateTimerTask()`** 就会让链接器把整个 `timers.c` 丢弃，定时器任务根本不会创建。裁剪不需要你手动从工程里删文件。
- **链接片段（`.lf`）**：三份片段都声明作用对象是 `libfreertos.a`，核心规则一句话——`FREERTOS_IN_IRAM=y` 时内核全部函数进 IRAM（`noflash_text` 段）；默认则整体留 Flash，仅把会被 ISR 上下文调用的少数函数（如 `event_groups.c` 的 `...FromISR` 系列、双核配置下的 `tasks.c` 的 `xTaskIncrementTickOtherCores()`）单独放进 IRAM。Flash 代码在 cache miss 时延不可控，而中断路径不能赌——这条规则背后就是第 17、18 章的主题。

### 5. 工程形态对照

> [!tip] Vanilla vs ESP-IDF：两种工程形态（本章暗线正片）
> | 维度 | Vanilla 工程（STM32 教程世界） | IDF 工程（ESP32 世界） |
> | --- | --- | --- |
> | 获取内核 | 官网下源码包 / 包管理器，手动拷 6 个 `.c` + `include/` + 对应 `portable/` | 组件内置，`idf.py` 自动编入，选树由 `CONFIG_FREERTOS_SMP` 决定 |
> | 内核配置 | **手写 `FreeRTOSConfig.h`**，每个工程一份，几十个 `config*` 宏逐个填 | **menuconfig 勾选**，`sdkconfig` → 翻译模板，改完即生效 |
> | 堆 | 从 `heap_1`~`heap_4`（`portable/MemMang/`）里挑一个编 | `heap_idf.c` 转接到 IDF heap 组件（caps 分配，第 19、20 章） |
> | tick 源 | 端口 `port.c` 里配硬件定时器，手算重载值 | `port_systick.c` + Kconfig 选定时器，接 esp*timer 体系 |
> | tickless | 纯内核特性：`configUSE_TICKLESS_IDLE` + 端口提供 `portSUPPRESS_TICKS_AND_SLEEP()` | 绑定电源管理（依赖 `PM_ENABLE`），语义是"自动浅睡"，esp_timer 事件会阻止入睡 |
> | 任务栈单位 | 字（word） | 字节（byte，第 1 章暗线） |
> | 裁剪手段 | `configUSE*\*`编译开关 + 手动删源文件 | Kconfig + 弱符号链接丢弃 +`.lf` 分段，三层叠加 |
> | 升级内核 | 换源码包，重新对配置 | 换 IDF 版本，内核与组件一起走 |
>
> 左列是"内核是库，工程是主人"；右列是"内核是组件，构建系统是主人"。读 Vanilla 教材时把配置翻译回 `config*` 宏，你就能在两个世界之间自由换算。

---

## 4.5 编译产物观察

源码地图的最后一环：**在 build 目录里亲眼看到内核**。以下结构全部可从 `CMakeLists.txt` 的源文件清单推导——build 目录不过是它的镜像。

### 1. build 目录里的内核

```text
build/
├── sdkconfig                      # 当前配置（CONFIG_FREERTOS_* 就住这）
├── compile_commands.json          # 每个编译单元的完整命令行（见下）
├── project_description.json       # 组件清单与路径
└── esp-idf/freertos/
    ├── libfreertos.a              # 组件静态库：bootloader 不含它，app 链接它
    └── CMakeFiles/__idf_freertos.dir/
        ├── heap_idf.c.o  app_startup.c.o  port_common.c.o  port_systick.c.o
        ├── FreeRTOS-Kernel/                        # ← 树 A 的镜像（默认）
        │   ├── tasks.c.o  queue.c.o  timers.c.o
        │   ├── event_groups.c.o  stream_buffer.c.o  list.c.o
        │   └── portable/xtensa/
        │       ├── port.c.o  portasm.S.o
        │       └── xtensa_init.c.o  xtensa_overlay_os_hook.c.o
        └── esp_additions/
            ├── idf_additions.c.o  idf_additions_event_groups.c.o
```

注意 `.o` 的目录结构就是源码相对组件根的路径——所以**确认编了哪棵树，看这个目录名就够了**：开 `CONFIG_FREERTOS_SMP` 重编后，`FreeRTOS-Kernel/` 目录会整体换成 `FreeRTOS-Kernel-SMP/`。

### 2. 不碰源码的两个验证入口

- `build/compile_commands.json`：记录 `tasks.c` 的完整编译命令，包括全部 `-I` 路径和 `-D` 宏。搜 `tasks.c`，看它的源路径落在哪棵树、带了哪些定义——这是"构建系统到底在干什么"的权威答案，也是配置 clangd/vim 让 IDE 正确跳转内核源码的钥匙。
- `build/project_description.json`：列出全部组件的路径与依赖关系，freertos 组件的 `path` 字段就是 4.1 那张目录树的根。

### 3. idf.py size-components：内核的体积 footprint

```bash
idf.py size                # 总量：Flash/RAM 分项
idf.py size-components     # 按组件归档分摊（libfreertos.a 会单列一行）
idf.py size-files          # 进一步按源文件分摊
```

`size-components` 的输出里，`libfreertos.a` 一行就是整个内核的 Flash/DRAM 足迹。绝对数字随版本与配置浮动，别背——**做差才是正确用法**：

| 实验                                         | 预期方向                                                                                  |
| -------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 关 `FREERTOS_USE_TIMERS`（且未用定时器 API） | 内核 footprint 缩小一截（弱符号裁剪生效，`timers.c` 整个消失，`size-files` 里直接没有它） |
| `FREERTOS_HZ` 100 → 1000                     | 体积几乎不变，变的是 CPU：每秒 1000 次 tick 中断的开销                                    |
| `FREERTOS_IN_IRAM=y`                         | 总量不变，但 IRAM 占用大涨、Flash 占用下降（`.lf` 分段规则换挡）                          |
| 开运行时间统计三连                           | `tasks.c` 变胖（统计字段与格式化函数编入）                                                |

把"改配置 → 重编 → size-components 对比"养成习惯，Kconfig 就从一张选项表变成可测量的旋钮盘。

### 4. 关于 bootloader 的再次确认

`size-components` 看到的是 **app** 的组件分摊。bootloader 镜像是单独一份独立构建（4.1 的 `NON_OS_BUILD` 早退），里面没有 FreeRTOS——如果你在 bootloader 相关的 map 里找内核符号，注定一无所获。

---

## 4.6 两份官方改造文档导读

两棵树各带一份"自我说明书"，是这个组件最被低估的财富。

### 1. `FreeRTOS-Kernel/idf_changes.md`：IDF FreeRTOS 改造清单

这份文档开门见山："追踪对 FreeRTOS V10.5.1 源码添加双核 SMP 支持时的全部改动"。四个板块值得先扫一遍标题：

- **调度行为**：双核并发执行、每核一个钉死的 Idle 任务、每核独立 tick（仅 Core 0 调 `xTaskIncrementTick()` 计时，Core 1 调 `xTaskIncrementTickOtherCores()` 做时间片检查——第 1 章的结论在这里找到原始出处）、每核独立 `vTaskSuspendAll()`；
- **数据结构 per-core 化**：`pxCurrentTCBs`、`xPendingReadyList`、`xYieldPending`、`xIdleTaskHandle`、`uxSchedulerSuspended` 等全部变成按核索引的数组；TCB 新增 `xCoreID` 成员；
- **API 增改**：`xTaskCreatePinnedToCore()` 族、`taskYIELD_CORE()` 等内部宏、`vTaskDelete()`/`vTaskPrioritySet()` 等函数为跨核语义做的改造；
- **细粒度自旋锁**：内核对象各配各的锁——`xKernelLock`、每队列一把 `xQueueLock`、`xEventGroupLock`、`xTimerLock`……

第二十二章拆 SMP 改造时，这份清单就是施工图纸。今天你只需要知道：**第 1 章讲的所有"IDF 与 Vanilla 的行为差异"，追根溯源都能在这份文件里找到一行对应的改动记录**。

### 2. `FreeRTOS-Kernel-SMP/porting_notes.md`：迁移到上游 SMP 的笔记

它回答"上游官方 SMP 内核与 IDF fork 有何不同"——这是暗线之外的**第三条线**（旧 fork vs 新上游）：

| 差异点     | IDF FreeRTOS（树 A）         | Amazon SMP FreeRTOS（树 B）                                                     |
| ---------- | ---------------------------- | ------------------------------------------------------------------------------- |
| 核亲和     | 钉死单核或不钉（`xCoreID`）  | 亲和**掩码**，可任意核组合（`xTaskCreateAffinitySet()`，PinnedToCore 变成包装） |
| 调度器挂起 | 每核独立 `vTaskSuspendAll()` | 全局挂起；IDF 内部改用 `vTaskPreemptionDisable()` 适配                          |
| 临界区     | 细粒度自旋锁（对象各配各的） | 全局大锁（task/ISR 锁），进入时还会检查状态变化、必要时让出重试                 |
| Idle 任务  | 每核一个，钉死               | `prvIdleTask()` ×1 + `prvPassiveIdleTask()` ×(N-1)，全部不钉核，先到先得        |
| tick       | 每核 tick 中断，Core 0 计时  | 只允许 Core 0 调 `xTaskIncrementTick()`，时间片也由它代管                       |

树 B 里对上游源码的改动全部包在 `#ifdef ESP_PLATFORM` 里——刻意保持与上游的最小 diff，方便跟进上游演进。这个"迁移期工程纪律"本身就值得学习。

---

## 4.7 动手实验：改一行内核源码，用 QEMU 验证

现在把整张地图走活。实验目标有两个：**实证 4.2 的结论（默认编入的到底是哪棵树）**，以及建立全系列的标配工作流：改内核 → 重编 → QEMU 观察。

### 1. 打补丁

编辑 `$IDF_PATH/components/freertos/FreeRTOS-Kernel/tasks.c`（`$IDF_PATH` 通常为 `~/esp/esp-idf`）。两处修改：

```c
/* ① 文件头部 include 区，加一行： */
#include "esp_rom_sys.h"

/* ② vTaskStartScheduler() 开头（prvCreateIdleTasks() 调用之前），加一行： */
void vTaskStartScheduler( void )
{
    BaseType_t xReturn;

    esp_rom_printf( "[hack] scheduler from FreeRTOS-Kernel/ (IDF FreeRTOS)\n" );

    xReturn = prvCreateIdleTasks();
    ...
```

选 `esp_rom_printf()` 而不是 `printf()` 是有讲究的：它走 ROM 里的 UART 例程，不依赖任何初始化，调度器还没跑起来也能安全输出——Xtensa 端口自己的 `port.c` 用的就是它。选 `vTaskStartScheduler()` 做注入点，是因为它必然被执行且只执行一次。

### 2. 第一次验证：默认配置

随便哪个工程（第一章的 `freertos-ch1` 即可）：

```bash
idf.py qemu monitor
```

`idf.py` 会自动重编（它检测到内核源码变了），QEMU 启动后在启动日志里看到：

```text
I (290) cpu_start: Starting scheduler on APP CPU.
[hack] scheduler from FreeRTOS-Kernel/ (IDF FreeRTOS)
[fast] tick 0 (core 0)
...
```

`[hack]` 行的确切位置随版本浮动，看到它即证明：**默认编入的是 `FreeRTOS-Kernel/`**——4.2 的源码结论拿到了运行时证据。顺手看一眼 build 目录（4.5.1），`.o` 也都落在 `FreeRTOS-Kernel/` 下。

### 3. 第二次验证：切换内核树

```bash
idf.py menuconfig
# Component config → FreeRTOS → Kernel →
#   勾选 "Run the Amazon SMP FreeRTOS kernel instead (FEATURE UNDER DEVELOPMENT)"
idf.py qemu monitor
```

重新配置后 `CMakeLists.txt` 的 `kernel_impl` 换挡：树 A 的补丁不再参与编译，`[hack]` 行消失；build 目录里的 `FreeRTOS-Kernel/` 整体换成 `FreeRTOS-Kernel-SMP/`。想让树 B 也说话，就给 `FreeRTOS-Kernel-SMP/tasks.c` 的同一个函数 `vTaskStartScheduler()` 加一行类似的 `esp_rom_printf()`（换个文案，比如 `from FreeRTOS-Kernel-SMP/`），重编后再看——两个 banner 的交替出现，就是那几行 CMake `if/else` 的全部含义。

### 4. 收尾与注意事项

```bash
cd $IDF_PATH && git diff --stat          # 看清自己动了什么
git checkout -- components/freertos/     # 实验完恢复原状
```

三条纪律：

1. **改动落在 IDF 安装树里，对这台机器上所有工程全局生效**——做完实验记得恢复，别把 `[hack]` 带进下一个正式项目。
2. v6.0.2 里两棵内核树直接位于 esp-idf 仓库中（不是 submodule），所以 `git diff`/`git stash` 全部可用；但升级或重装 IDF 会冲掉手工修改，值得保留的改动应当走补丁文件。
3. 真机对照：同一份补丁用 `idf.py -p /dev/ttyUSB0 flash monitor` 验证，行为一致；想深入单步，`idf.py qemu gdb` 直接断在 `vTaskStartScheduler`（第 24 章的主场）。

### 5. 这个工作流为什么重要

后面每一章的实验都是它的变奏：在第 6 章往就绪链表里加打印、在第 9 章数一数 Idle 任务的呼吸、在第 15 章偷看定时器命令队列……**内核不是黑盒，是你的实验台**——而 QEMU 让这台实验台免清洗、免烧录、随时重来。

---

## 4.8 小结

- `components/freertos/` 是一个普通组件：`CMakeLists.txt` 在配置期挑树、拼 include、接 IDF 服务（堆/tick/启动）、定内存段；bootloader 构建时它整体缺席。
- **两棵树的正解**：默认编入 `FreeRTOS-Kernel/`——它就是基于 Vanilla v10.5.1 深度 SMP 改造的 **IDF FreeRTOS**；`FreeRTOS-Kernel-SMP/` 是实验性的上游 **Amazon SMP** 内核（v11.1.0），由 `CONFIG_FREERTOS_SMP`（默认 `n`）开启。`CONFIG_FREERTOS_UNICORE` 管核数，不管选树（4.2.5 的误解警示值得再读一遍）。
- `include/freertos/` 布局两树同构：`FreeRTOS.h` 是配置消费端、`task.h`/`queue.h` 是对象 API、`projdefs.h` 是基础宏、`portable.h` 是端口服务边界；IDF 扩展 API 住在 `esp_additions/`。
- 配置的唯一合法入口是 Kconfig：`sdkconfig` → 翻译模板 `config/include/freertos/FreeRTOSConfig.h` → `config*` 宏；裁剪另有弱符号与链接片段两只有力的手。Vanilla 的"手写 FreeRTOSConfig.h"世界与此形成整套对照。
- 编译产物里，`build/esp-idf/freertos/` 的 `.o` 目录镜像了所选的树，`libfreertos.a` 是内核的静态库形态，`idf.py size-components` 量化 footprint，`compile_commands.json` 是构建系统的供词。
- `idf_changes.md` 与 `porting_notes.md` 分别是"IDF 怎么改内核"与"上游 SMP 与 IDF fork 有何不同"的官方清单——第二十二章的两块基石。
- 改一行内核源码 + `idf.py qemu monitor` 的工作流已经跑通：从本章起，内核是我们的实验台，不是黑盒。

下一章正式推开工事：`xTaskCreate()` 从参数校验、TCB 分配、栈填充到挂入就绪链表的全流程，以及 TCB 结构体里每个字段存在的原因——任务的生与死，[[ch5-task-lifecycle-and-tcb|第五章]]见。
