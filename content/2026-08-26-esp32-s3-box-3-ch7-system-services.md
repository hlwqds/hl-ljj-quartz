---
title: "ESP32-S3-BOX-3 工程实战（七）：系统服务层——日志、NVS、事件循环与 esp_timer"
date: 2026-08-26 12:00:00
description: "app_main 之后你能依赖的四件地基：ESP_LOG 的编译期/运行期双重闸门、NVS 的页与追加写、esp_event 的 sys_evt 任务三级派发、esp_timer 的 SYSTIMER 时基——全部对着 esp-idf v6 源码走读，最后一个三段式实验把四者串成一条链。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（七）：系统服务层——日志、NVS、事件循环与 esp_timer

第六章看完"从上电到 app_main"，这一章回答它的反面：**app_main 之后，你写下的第一行日志、存的第一个配置、注册的第一个事件、起的第一个定时器，各自站在谁的地基上**。四个组件——log、nvs_flash、esp_event、esp_timer——都是 ESP-IDF 的普通组件，却有一个共同点：它们在 app_main 之前就已就位，你的应用代码从第一毫秒起就在用它们。

按系列惯例走 L1（应用 API）→ L2（组件源码）两层。L3/L4 本章基本不适用：前三个是纯软件组件，没有寄存器和波形可言；唯一的硬件触碰是 esp_timer 的 SYSTIMER 外设，它的寄存器层与精度测量留给第十三章。

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[2026-08-26-esp32-s3-box-3-hands-on-series-index|系列索引]]
> 上一章：[[2026-08-26-esp32-s3-box-3-ch6-boot-to-app-main|第六章：从上电到 app_main]]
> **第七章：系统服务层——日志、NVS、事件循环与 esp_timer**（当前章）
> 下一章：[[2026-08-26-esp32-s3-box-3-ch8-gpio-interrupts|第八章：GPIO 与中断]]

---

## 7.1 ESP_LOG：一行日志要过几道闸门

### 1. L1：六个等级与一族宏

等级定义在 `components/log/include/esp_log_level.h` 的 `esp_log_level_t`：`NONE(0) / ERROR(1) / WARN(2) / INFO(3) / DEBUG(4) / VERBOSE(5)`，数值越大越啰嗦。使用面只有一族宏加一个 TAG 惯例：

```c
#include "esp_log.h"
static const char *TAG = "my_module";

ESP_LOGI(TAG, "boot count = %" PRIu32, count);   /* I 级 */
ESP_LOGE(TAG, "init failed: %s", esp_err_to_name(err));
```

启动日志里每行开头的 `I (290) cpu_start:`，I 是等级字母、290 是开机毫秒数、`cpu_start` 就是 TAG。除了 `ESP_LOGE/W/I/D/V`，还有两族特殊宏：

| 宏族             | 用途                                                        | 底层出口                                                         |
| ---------------- | ----------------------------------------------------------- | ---------------------------------------------------------------- |
| `ESP_LOGx`       | 常规日志                                                    | `esp_log()` → 默认 `vprintf`                                     |
| `ESP_EARLY_LOGx` | 堆/系统调用初始化之前（bootloader、极早期启动）             | ROM 里的 `esp_rom_printf`（`esp_log.h` 的 `ESP_LOG_EARLY_IMPL`） |
| `ESP_DRAM_LOGx`  | cache 被禁用时（flash 擦写期间、某些 ISR），字符串须在 DRAM | 同上，且禁用颜色与时间戳                                         |

### 2. 一行日志的两道闸门

`ESP_LOGI` 不是马上打印，它要连过两道闸（这是 L2 的核心结论，直接决定常见翻车）：

```text
ESP_LOGI(TAG, ...)
  │
  ├─ 闸门一（编译期）：LOG_LOCAL_LEVEL，即 CONFIG_LOG_MAXIMUM_LEVEL
  │    等级高于它的 ESP_LOGx 展开为空 —— 根本不进固件
  │
  └─ 闸门二（运行期）：esp_log_is_tag_loggable(level, TAG)
       ├─ 默认级别 CONFIG_LOG_DEFAULT_LEVEL（menuconfig，默认 INFO）
       └─ esp_log_level_set() 做的按 TAG 覆盖（"*" 通配全部）
```

两道闸的分工：闸门一管**固件体积**（编译后 DEBUG/VERBOSE 语句直接消失），闸门二管**运行时噪声**。推论也立刻出来：menuconfig 里只把 Default 调成 Debug 没用——若 Maximum（默认"Same as default"）没跟着调，D/V 级语句在编译期就没了，运行期永远调不出来；反之 Maximum 开得很高而 Default 低，固件变大，但可以运行期按 TAG 精确放大某一路日志。

`esp_log_level_set("*", ESP_LOG_WARN)` 这类通配调用，在源码里走的是 `tag_log_level.c` 的 `log_level_set()`：重置默认级别、清空按 TAG 链表与缓存。按 TAG 的级别查询默认带缓存（Kconfig `CONFIG_LOG_TAG_LEVEL_IMPL` 默认 `CACHE_AND_LINKED_LIST`，缓存 31 项），所以逐条日志的运行期开销只是一次缓存查找。

### 3. 输出走到哪，和 printf 什么关系

追到 `components/log/src/os/log_write.c`：`vprintf_like_t esp_log_vprint_func = &vprintf;`——日志最终调 newlib 的 `vprintf` 写 stdout，再经 VFS 落到 `CONFIG_ESP_CONSOLE_*` 选定的控制台通道（BOX-3 是 USB-Serial-JTAG，见第四章 sdkconfig.defaults；UART 板则是 `esp_driver_uart/src/uart_vfs.c` 注册的 /dev/uart）。`esp_log_set_vprintf()` 可以把整个出口换掉（重定向到 JTAG、网络都是这么做的）。所以 **ESP_LOGx ≈ 带两道闸门和格式化的 vprintf**；裸 `printf` 也通（同一个 stdout），但没有等级、时间戳、TAG，更没有闸门——项目里混用 printf 是排查"为什么这条日志删不掉"的经典来源。

### 4. L2：components/log 源码一瞥

```text
components/log/
├── include/esp_log.h            # 宏族：ESP_LOGx / EARLY / DRAM 的展开
├── src/log.c                    # esp_log_va()：闸门检查→时间戳→格式化
├── src/os/log_write.c           # esp_log_vprint_func（默认 &vprintf）
├── src/log_level/tag_log_level/ # 按 TAG 级别：链表 + 缓存
└── Kconfig*                     # 等级/版本/格式全部可配
```

值得知道的一件事：IDF v6 的日志有 V1/V2 两代（`CONFIG_LOG_VERSION`，默认 V1）。V1 把颜色/时间戳揉进格式串（flash 里存的是 `"\x1b[0;32mI (%lu) %s: ..."`）；V2 把格式化集中进 `esp_log()` 函数，格式串原样存储，还支持二进制日志模式（只发格式串地址，host 端 monitor 借 ELF 还原，Kconfig 自述可省 10%~35% flash）。本章按默认 V1 讲解，行为差异不影响 API。

---

## 7.2 NVS：把配置写进 flash 的正确姿势

### 1. L1：namespace / key / value 三层模型

NVS（Non-Volatile Storage）是键值库，不是文件系统。寻址是三层：**分区 → namespace → key**。

```c
#include "nvs_flash.h"
#include "nvs.h"

esp_err_t err = nvs_flash_init();                 /* 找分区表里标签 "nvs" 的分区 */
if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());           /* 分区被截断/版本不认：擦掉重来 */
    err = nvs_flash_init();
}

nvs_handle_t h;
nvs_open("storage", NVS_READWRITE, &h);           /* namespace ≤ 15 字符 */
nvs_set_i32(h, "boot_count", 42);                 /* key ≤ 15 字符 */
nvs_commit(h);                                    /* 保证落盘 */
nvs_close(h);
```

这是官方 `examples/storage/nvs/nvs_rw_value` 的标准骨架（含错误恢复模式，原文如此）。类型面覆盖 `i8/u8/i16/u16/i32/u32/i64/u64/str/blob`；blob 读取用 WinAPI 式两段法——先 `nvs_get_blob(h, key, NULL, &len)` 问长度，malloc 后再读真身。

**它住在哪**：`nvs_flash_init()` 定位分区表中标签为 `nvs` 的 data 分区。第四章 factory_demo 的 `partitions.csv` 里就是 `nvs, data, nvs, 0x10000, 0x6000`——24KB，接下来算页的时候会用到这个数。

### 2. L2：4096 字节一页，追加写，位图回收

`private_include/nvs_constants.h` 和 `src/nvs_types.hpp` 给出全部底牌：

```text
一页 = 4096B（正好一个 flash 擦除扇区）
      = 32B 页头（页状态） + 32B 入口位图 + 126 个 32B 入口
一个入口(Item) = nsIndex + datatype + span + chunkIndex + crc32
               + key[16] + 8B 载荷          ← key 上限 15 字符的根源
```

写入是**追加式**：改一个 key 不是原地覆盖，而是追加一个新 entry、旧 entry 在位图里标成 ERASED——因为 flash 只能把 1 写成 0，物理上就不支持原地改。当一个页写满，NVS 把它标记为 FREEING，把仍有效的 entry 搬运到别的页，然后整页擦除回收。**"磨损均衡思想"就体现在这**：写压力被追加机制摊到页内不同 entry，擦除以整页为单位成批进行，任意一个 4KB 块都不会被反复单独擦。每个 entry 自带 CRC32（`nvs_types.cpp` 的 `calculateCrc32`），掉电写一半的 entry 会被校验淘汰——这是它比裸写 flash 可靠的底气。factory_demo 的 24KB 分区 = 6 页，容量对"WiFi 凭据 + 用户设置"绰绰有余，但边界也在那（翻车点表第一行）。

### 3. 什么时候不该用它

| 场景                             | 不该                     | 该用                                                        |
| -------------------------------- | ------------------------ | ----------------------------------------------------------- |
| 大资源文件（MP3、模型、图片）    | 单 blob 硬塞             | 独立分区：factory_demo 的 storage/model 走 SPIFFS（第四章） |
| 高频写入（每秒多次的传感器流水） | 追加写很快耗页，触发搬页 | 内存缓冲 + 低频批量落盘，或 FATFS/LittleFS 分区             |
| 结构化大量记录、需要遍历过滤     | namespace/key 不是数据库 | LittleFS/FATFS 文件                                         |
| 加密凭据                         | 明文 key                 | NVS encryption（`nvs_flash_secure_init`，本章不展开）       |

一句话：NVS 是**配置存储**，为"低频写、掉电保持、键值寻址"而生，不是通用存储。

---

## 7.3 esp_event：谁在派发你的事件

### 1. L1：base + id 的事件命名，default loop 起手

事件用 `(loop, base, id)` 三元组命名。base 是个字符串指针，惯例这样定义：

```c
/* 定义方 */
ESP_EVENT_DEFINE_BASE(TOUCH_EVENTS);          /* 展开为 const 字符串 "TOUCH_EVENTS" */
enum { TOUCH_EVENT_PRESSED = 1 };

/* 订阅方 */
esp_event_loop_create_default();              /* 创建默认循环（含 sys_evt 任务） */
esp_event_handler_register(TOUCH_EVENTS, TOUCH_EVENT_PRESSED,
                           my_handler, NULL); /* 或 ESP_EVENT_ANY_ID 通配 */
/* 发布方 */
esp_event_post(TOUCH_EVENTS, TOUCH_EVENT_PRESSED, &data, sizeof(data), portMAX_DELAY);
```

两种循环：**default loop**（`esp_event_loop_create_default`，全局一份，WiFi/网络事件全走它）与**用户循环**（`esp_event_loop_create` + `esp_event_loop_args_t`，可自定队列深度/任务参数，甚至 `task_name=NULL` 做成"无任务循环"——由谁调 `esp_event_loop_run()` 谁负责派发）。官方示例 `examples/system/esp_event/default_event_loop` 与 `user_event_loops` 分别演示两种。

### 2. L2：sys_evt 任务——派发发生在哪

`default_event_loop.c` 里 default loop 的出生参数（全部可溯源）：

| 参数     | 值                                                                                                        | 出处                                           |
| -------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| 任务名   | `"sys_evt"`                                                                                               | `default_event_loop.c`                         |
| 优先级   | `configMAX_PRIORITIES - 5` = 20                                                                           | `esp_task.h` `ESP_TASKD_EVENT_PRIO`（25-5）    |
| 栈       | 2304（`CONFIG_ESP_SYSTEM_EVENT_TASK_STACK_SIZE`）+ 512 = 2816B（开 lwIP core locking 再 +2048，默认不开） | `esp_system/Kconfig` + `TASK_EXTRA_STACK_SIZE` |
| 队列深度 | 32（`CONFIG_ESP_SYSTEM_EVENT_QUEUE_SIZE`）                                                                | 同上                                           |
| 亲和     | core 0                                                                                                    | `default_event_loop.c`                         |

派发主循环在 `esp_event.c` 的 `esp_event_loop_run()`（由 `esp_event_loop_run_task` 里的 `while(1)` 驱动）：`xQueueReceive` 取出事件 → 按三级匹配执行 handler——**loop 级（ANY/ANY）→ base 级（base + ANY_ID）→ base:id 级**，同一事件命中多个 handler 时按注册顺序串行执行。发布端 `esp_event_post_to()` 做的关键动作是 **calloc 一份 event_data 拷进堆**再入队——事件数据的生命周期与发布者解耦，handler 拿到的指针在派发前一直有效、派发后由循环 free。ISR 里发布用 `esp_event_isr_post()`：数据必须 ≤ 4 字节（塞进 `esp_event_post_data_t` 这个 `uint32_t/void*` 联合体，超了直接 `ESP_ERR_INVALID_ARG`），内部走 `xQueueSendToBackFromISR`。

### 3. 为什么优于裸回调

裸回调（驱动持函数指针、直接调你）的四个痛点，事件循环逐个回应：

| 裸回调                                        | esp_event                                              |
| --------------------------------------------- | ------------------------------------------------------ |
| 发布者必须知道每个消费者                      | post 方只报 `(base, id)`，谁订阅谁自己知道             |
| 回调在发布者的上下文里跑（常是 ISR/驱动任务） | handler 统一跑在 sys_evt 任务里，上下文可预期          |
| 一次注册一组回调，增删要改发布者              | register/unregister 随时增删，还能 ANY_ID 通配整族事件 |
| 数据指针生命周期靠人肉约定                    | post 拷贝数据，handler 执行完由循环释放                |

顺序可控是隐藏收益：单任务串行派发 = 同一循环内 handler 天然互不并发，很多锁都省了。代价同样明确：**派发是串行的，一个 handler 慢，后面全部事件排队**（7.6 翻车点）。

> [!note] 伏笔：WiFi 状态机的地基
> 第十六章的 WiFi 连接管理（`WIFI_EVENT` / `IP_EVENT`，断线重连状态机）全部构建在 default loop 上——`esp_wifi_init()` 注册的事件、`esp_netif` 的 IP 事件，走的都是本章这条 sys_evt 任务。到那里你会回来感谢现在理解的派发模型。

---

## 7.4 esp_timer：微秒级定时与它的任务

### 1. L1：64 位微秒时基

```c
#include "esp_timer.h"

int64_t now = esp_timer_get_time();            /* 开机以来的微秒数，64 位 */

const esp_timer_create_args_t args = {
    .callback = &blink_cb,
    .name = "blink",                           /* 仅用于调试 dump */
};
esp_timer_handle_t t;
esp_timer_create(&args, &t);
esp_timer_start_periodic(t, 500000);           /* 周期 500ms，单位微秒 */
esp_timer_start_once(t, 5000000);              /* 或 5s 后单次触发 */
```

官方示例 `examples/system/esp_timer` 就是这个形状：一个 0.5s 周期定时器 + 一个 5s 单次定时器，后者到期后把前者改成 1s 周期，还顺带演示了 `esp_timer_dump(stdout)` 与浅睡时计时不停。

### 2. L2：哪个任务在等、等什么、时钟是谁

对 `src/esp_timer.c` 的走读给出三张底牌：

**底牌一：派发任务叫 `"esp_timer"`，比你的代码先出生。** `esp_timer_init()`（`ESP_SYSTEM_INIT_FN(esp_timer_init_os, SECONDARY, ...)` 在启动期调用，见 `system_init_fn.txt`）创建任务：`xTaskCreatePinnedToCore(timer_task, "esp_timer", 3584+512, NULL, configMAX_PRIORITIES-3=22, ...)`——优先级 22、钉 core 0，都高于 sys_evt(20)，更远高于跑 app_main 的 main 任务(1)。**系统服务层住在你应用之上**，这组数字是最直接的证据。

**底牌二：v6 里它等的是任务通知，不是队列。** `timer_task()` 全文五行：`ulTaskNotifyTake(pdTRUE, portMAX_DELAY)` 阻塞，被唤醒后 `timer_process_alarm(ESP_TIMER_TASK)`。唤醒方是 SYSTIMER 报警中断 `timer_alarm_isr` → `timer_alarm_handler` → `vTaskNotifyGiveFromISR(s_timer_task, ...)`。（早期 IDF 版本用队列唤醒，网上旧文的"等队列"说法在 v6 源码里已不成立——以源码为准。）`timer_process_alarm` 遍历按到期时间排序的定时器链表，**在任务上下文里逐个调用回调**。

**底牌三：S3 的时钟源是 SYSTIMER，不是定时器组。** `esp_timer_impl_systimer.c` 注释明言用 systimer counter0 + alarm2 实现 esp_timer；S3 的 `SOC_SYSTIMER_FIXED_DIVIDER=1`（soc_caps.h：固定 2.5 分频，即 40MHz XTAL → 16MHz 计数、52 位计数器）。定时器组 LAC 实现（`CONFIG_ESP_TIMER_IMPL_TG0_LAC`）在 Kconfig 里 `depends on IDF_TARGET_ESP32`——只有经典 esp32 才有。所以"S3 上 esp_timer 占用某 timer 组"的传言可以就此打住；SYSTIMER 的寄存器细节在第十三章展开。

回调上下文的规矩（`esp_timer.h` 头注释原文精神）：回调从 esp_timer 任务派发，**上一个回调返回前下一个不会开始**；回调应尽量短，把活转交其他任务。若开 `CONFIG_ESP_TIMER_SUPPORTS_ISR_DISPATCH_METHOD`（默认 n），create 时可选 `ESP_TIMER_ISR` 派发——回调直接在中断里跑，延迟更低，但那几微秒跑不完的活就别进去了。

### 3. 与 FreeRTOS 软件定时器：分工与选型

[[2026-08-26-freertos-deep-dive-ch15-software-timers-daemon|FreeRTOS（十五）软件定时器]]拆过 Tmr Svc 守护任务模型，这里只给选型表（数字均已对源码核实）：

| 维度     | FreeRTOS 软件定时器                                       | esp_timer                                                  |
| -------- | --------------------------------------------------------- | ---------------------------------------------------------- |
| 时基     | FreeRTOS tick（`CONFIG_FREERTOS_HZ=1000` → 1ms）          | SYSTIMER 硬件计数（µs 级）                                 |
| 派发任务 | Tmr Svc（优先级 `configTIMER_TASK_PRIORITY`，IDF 默认 1） | esp_timer（优先级 22，core 0）                             |
| 周期单位 | tick                                                      | 微秒，64 位                                                |
| 睡眠时   | tick 停，浅睡不计时                                       | 浅睡继续计时（官方示例有断言验证）                         |
| 命令通道 | 命令队列（深 10）                                         | 直接改链表 + 任务通知唤醒                                  |
| 适合     | 秒级慢周期、与内核对象联动                                | 亚毫秒/毫秒级、需要高优先级派发、`esp_timer_get_time` 打点 |

经验法则：**ms 级以上、精度无所谓 → 软件定时器；要微秒、要打点、要浅睡保持 → esp_timer**。两者回调同守一条铁律：别在回调里阻塞或做重活。

---

## 7.5 综合实验：重启计数 + 触摸事件链

三段式把本章四个组件串成一条链：**NVS 记重启次数 → 触摸中断进事件循环 → 处理任务干活，日志全程打点**。GPIO 中断的驱动细节是第八章主题，此处只取最小组装。

```c
/* main/main.c —— 实验骨架（ IDF v6，esp32s3 ） */
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_log.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "driver/gpio.h"

static const char *TAG = "ch7_lab";

/* ---- 事件定义：触摸事件族 ---- */
ESP_EVENT_DEFINE_BASE(TOUCH_EVENTS);
enum { TOUCH_EVENT_PRESSED = 1 };

/* 触摸 INT 引脚号以第八章/第十四章 BSP 走读为准，先占位 */
#define TOUCH_INT_GPIO   -1   /* TODO(ch8): 核对 BOX-3 触摸 INT 引脚后填入 */

/* ---- 第一段：重启计数存 NVS ---- */
static int32_t bump_boot_count(void)
{
    nvs_handle_t h;
    int32_t cnt = 0;
    if (nvs_open("lab", NVS_READWRITE, &h) != ESP_OK) { return -1; }
    nvs_get_i32(h, "boot_count", &cnt);        /* 首次是 NOT_FOUND，cnt 保持 0 */
    cnt++;
    nvs_set_i32(h, "boot_count", cnt);
    nvs_commit(h);                             /* 不 commit 掉电即丢 */
    nvs_close(h);
    return cnt;
}

/* ---- 第二段：触摸 ISR → 事件循环（ISR 里只发事件，不干活）---- */
static void IRAM_ATTR touch_isr(void *arg)
{
    BaseType_t woken = pdFALSE;
    esp_event_isr_post(TOUCH_EVENTS, TOUCH_EVENT_PRESSED, NULL, 0, &woken);
    portYIELD_FROM_ISR(woken);                 /* 唤醒可能在别的核上的 sys_evt */
}

/* ---- 第三段：handler 只搬运，重活全部进 worker 任务 ---- */
static QueueHandle_t s_work_q;

static void touch_handler(void *arg, esp_event_base_t base,
                          int32_t id, void *data)
{
    int evt = (int)id;                         /* handler 跑在 sys_evt，快进快出 */
    xQueueSend(s_work_q, &evt, 0);             /* 满了就丢，不在派发任务里等 */
}

static void worker_task(void *arg)
{
    int evt;
    for (;;) {
        xQueueReceive(s_work_q, &evt, portMAX_DELAY);
        ESP_LOGI(TAG, "worker handles touch event %d at %lld us",
                 evt, esp_timer_get_time());   /* 重活（刷屏/发声）在这里做 */
    }
}

void app_main(void)
{
    /* 1. NVS */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    ESP_LOGI(TAG, "boot count = %" PRId32, bump_boot_count());

    /* 2. 事件循环 + 注册 */
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(esp_event_handler_register(TOUCH_EVENTS, TOUCH_EVENT_PRESSED,
                                               touch_handler, NULL));
    /* 3. worker 任务 + 队列 */
    s_work_q = xQueueCreate(8, sizeof(int));
    xTaskCreate(worker_task, "worker", 4096, NULL, 4, NULL);
    /* 4. 触摸 INT（GPIO 中断细节第八章展开） */
    gpio_install_isr_service(0);
    gpio_set_direction(TOUCH_INT_GPIO, GPIO_MODE_INPUT);
    gpio_set_intr_type(TOUCH_INT_GPIO, GPIO_INTR_NEGEDGE);
    gpio_isr_handler_add(TOUCH_INT_GPIO, touch_isr, NULL);
}
```

main 组件依赖（`main/CMakeLists.txt`）需补 `PRIV_REQUIRES nvs_flash esp_event esp_driver_gpio`——第四章 4.3 节的判据：都在 .c 里用，走 PRIV。

> [!warning] 待真机验证
> 硬件在途，本实验未执行。真机到货后的验证点：① 每次 `idf.py -p /dev/ttyACM* flash monitor` 复位后，`boot count` 从 NVS 读出且 +1 递增（证明跨掉电保持）；② `nvs_flash_erase()` 后首启应打印 1；③ 触摸屏幕后 worker 任务打印带 `esp_timer_get_time()` 微秒时戳的处理日志，且触摸连点不丢事件（队列 8 深）；④ 触摸 INT 引脚号与触发边沿按第八章 BSP 核对结果修正。全程无预期之外的 WDT/abort 日志。

代码骨架中的 API 用法已对照官方示例核实（nvs_rw_value 的错误恢复模式、esp_event 示例的 DEFINE_BASE/register 模式、esp_timer 示例的 create/start 模式），但编译与运行行为以真机为准。

---

## 7.6 翻车点表与小结

| 症状                                                                   | 根因                                                                             | 处理                                                                          |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `nvs_open` 返回 `ESP_ERR_NVS_INVALID_NAME`，或 set 返回 `KEY_TOO_LONG` | namespace/key 超过 15 字符（`Item.key[16]` 物理上限）                            | 缩短命名；这限制是 entry 格式决定的，绕不开                                   |
| 写 NVS 报 `ESP_ERR_NVS_NOT_ENOUGH_SPACE`，init 报 `NO_FREE_PAGES`      | 分区 6 页写满，或被大量 blob 撑爆                                                | 只存配置量级数据；大文件去 SPIFFS/FATFS 分区；开发期 `nvs_flash_erase()` 重来 |
| set 完直接掉电，重启数据丢了                                           | 没调 `nvs_commit`，写入不保证落 flash                                            | 每次修改序列以 commit 收尾（官方示例原话："must be called"）                  |
| 事件时灵时不灵，队列统计有 dropped                                     | sys_evt 被慢 handler 堵住，32 深队列溢出，post 返回 `ESP_ERR_TIMEOUT`            | handler 只搬运（入队/发通知），重活进 worker 任务；高频源检查 post 返回值     |
| handler 里栈溢出重启                                                   | sys_evt 栈只有 2816B（2304+512），塞不下大数组/深调用                            | 同上：handler 瘦身，或调大 `CONFIG_ESP_SYSTEM_EVENT_TASK_STACK_SIZE`          |
| `esp_event_isr_post` 返回 `ESP_ERR_INVALID_ARG`                        | ISR 版数据必须 ≤ 4 字节（塞 `uint32_t/void*` 联合体）                            | ISR 只传标志/指针；带数据的事件在任务上下文 post                              |
| esp_timer 回调里 `vTaskDelay` 后别的定时器全迟了                       | 回调在 esp_timer 任务串行执行，阻塞一个 = 阻塞全部                               | 回调置标志/通知，活交给普通任务；与 FreeRTOS 软件定时器同一条铁律             |
| 运行期 `esp_log_level_set` 调不出 DEBUG 日志                           | 编译期闸门 `CONFIG_LOG_MAXIMUM_LEVEL` 默认 = Default(INFO)，高于它的语句没进固件 | menuconfig 里把 Maximum log verbosity 调上去，再运行期按 TAG 放大             |
| 在 flash 擦写回调/关 cache 路径里用 `ESP_LOGI` 崩溃                    | 普通 log 代码与字符串在 flash，cache 禁用时不可执行                              | 该场景用 `ESP_DRAM_LOGx`（DRAM 字符串）                                       |

本章小结：

- **四个服务，一个共同身份**：都是 app_main 之前就位的系统层组件，且住得比你的应用高——esp_timer 任务优先级 22、sys_evt 20，都俯视 main 任务的 1。
- **ESP_LOG 是带两道闸门的 vprintf**：编译期 `CONFIG_LOG_MAXIMUM_LEVEL` 决定哪些语句存在，运行期默认级别 + 按 TAG 覆盖决定谁发声；输出口可整体替换（`esp_log_set_vprintf`）。
- **NVS 是配置库不是文件系统**：4096B 页 / 126×32B 追加式入口 / 位图标记删除 / 满页搬运回收，CRC 兜底掉电；key 与 namespace 的 15 字符上限刻在 entry 格式里。
- **esp_event 的派发者是 sys_evt 任务**：post 拷贝数据入 32 深队列，handler 按 loop/base/id 三级匹配串行执行——解耦、顺序可控、上下文安全，代价是一个慢 handler 拖垮全线。WiFi 状态机（第十六章）将整个压在这套模型上。
- **esp_timer 是 SYSTIMER + 高优先级任务**：v6 里任务靠任务通知唤醒（不是队列），S3 的时基是 SYSTIMER counter0+alarm2（XTAL 2.5 分频），与 FreeRTOS 软件定时器按精度和派发优先级分工。

下一章终于碰到硬件：GPIO 与中断。背光控制、触摸 INT 的 IO MUX 与 GPIO Matrix、ISR 的铁律——本章实验里那句"细节第八章展开"的欠账，在那里连本带利还清。
