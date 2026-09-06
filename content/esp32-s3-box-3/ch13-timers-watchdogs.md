---
title: "ESP32-S3-BOX-3 工程实战（十三）：定时器与看门狗"
date: 2026-08-26 12:00:00
description: "把 BOX-3 上的时间层谱系一次讲清：从 16MHz systimer 到 FreeRTOS tick、esp_timer、54 位硬件定时器组；走读 esp_timer.c 与 task_wdt.c 源码（分发任务、自旋锁、两级超时），拆解『高优先级忙等饿死 Idle 触发 TWDT』因果链，对比 MWDT/IWDT；LEDC 硬件 PWM 呼吸灯与故意触发任务看门狗的实验设计。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（十三）：定时器与看门狗

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch12-rmt-infrared|第十二章：RMT 与红外]]
> **第十三章：定时器与看门狗**（当前章）
> 下一章：[[ch14-bsp-walkthrough|第十四章：esp-box-3 BSP 组件走读]]

第七章把 esp_timer 当"系统服务"用过，第十二章又见 RMT 自带精确到 tick 的时序引擎——本章把这些散落的"计时者"收进一张谱系表，然后沿四层下钻回答两个工程问题：**esp_timer 的回调到底跑在哪、能做什么**；**一个不 delay 的高优先级任务，为什么会引爆任务看门狗，日志该怎么读**。源码均为本地 esp-idf v6.0.2 实地读取（`components/esp_timer/`、`components/esp_system/task_wdt/`、`components/esp_driver_gptimer/`、`components/esp_driver_ledc/`）。

---

## 13.1 时间源全家谱：BOX-3 上有六层"表"

ESP-IDF 里"时间"不是一口钟，而是一摞精度、成本、用途各不相同的表。自底向上：

| 层  | 时间源               | 规格（S3 实测源码/TRM 口径）                                                                      | 典型用途                                   |
| --- | -------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| 1   | CPU cycle            | Xtensa LX7 @ 240MHz                                                                               | 指令间相对时序（CCOUNT）                   |
| 2   | **SYSTIMER** 外设    | 40MHz XTAL ÷ 2.5 = **16MHz**，**52 位**计数器（32+20 位）                                         | 唯一的高精度单调时钟底座                   |
| 3   | FreeRTOS tick        | 由 SYSTIMER counter1 产生，`CONFIG_FREERTOS_HZ` 默认 **100**（BOX-3 的 factory_demo 配 1000）     | `vTaskDelay`、软件定时器记账               |
| 4   | **esp_timer**        | 基于 SYSTIMER counter0，**1µs 分辨率**                                                            | 软件回调定时器、`esp_timer_get_time()`     |
| 5   | 硬件定时器组 TG0/TG1 | 每组 2 个通用定时器，**54 位**计数器 + **16 位预分频**（2~65536），时钟源 APB 80MHz 或 XTAL 40MHz | gptimer 驱动：自定义分辨率、事件捕获       |
| 6   | 专用外设定时器       | RMT/MCPWM/LEDC 各自内置                                                                           | 精确波形（第十二章 RMT）、PWM（本章 13.6） |

三个源码事实撑起这张表：

1. **SYSTIMER 的资源是静态分配的**（`esp_hw_support/include/esp_private/systimer.h`）：S3 有 2 个计数器、3 个报警器——counter0 归 esp_timer（报警器 2），counter1 归 FreeRTOS OS tick（报警器 0/1 各绑一个核，`port_systick.c` 里配成周期模式，周期 = `1000000/CONFIG_FREERTOS_HZ` µs）。**你调 `CONFIG_FREERTOS_HZ`，动的是 counter1 的报警周期，与 esp_timer 无关。**
2. **定时器组一身三职**：`timg_ll.h` 开头注释原话——"Timer Group has 3 independent functions: General Purpose Timer, Watchdog Timer and Clock calibration"。TG0/TG1 里的"通用定时器"只是其中一个功能位；**每个组还内置一个 MWDT 看门狗**，这就是后文 TWDT/IWDT 的硬件来源。S3 的 54 位计数宽度来自 `TIMER_LL_COUNTER_BIT_WIDTH 54`（`esp_hal_timg/esp32s3/include/hal/timer_ll.h`）。
3. **L3 寄存器视角**：预分频落在 `hw_timer[n].config` 的 `tn_divider` 字段（`timer_ll_set_clock_prescale()` 断言 2~65536）；计数器为 54 位自动重载向上计数。L4 视角下这层"表"的抖动最小——不含任何调度因素。

选择原则一句话：**精度要求越高，越往表的底层走；对"到点跑一段代码"的需求，优先 esp_timer（µs 级、无硬件数量限制）；对"到点翻转引脚"，让第 5/6 层的硬件自己干（gptimer/RMT/LEDC），CPU 连中断都可以不进。**

---

## 13.2 esp_timer 源码走读（L2）：一个任务、两条链表、一次通知

### 1. 组件地图与核心数据结构

```text
components/esp_timer/
├── src/esp_timer.c               # 核心：任务、链表、分发
├── src/esp_timer_impl_systimer.c # 时间源实现（S3 用 systimer）
├── src/esp_timer_impl_common.c   # 共享锁、最小周期
└── include/esp_timer.h           # 公共 API
```

每个定时器就是一个堆分配的 `struct esp_timer`：56 位到期时间 `alarm` + 56 位 `period` + 8 位标志（是否 ISR 分发、是否跳过错过的周期）+ 回调与参数。所有活跃定时器按 **alarm 升序**挂在 `s_timers[]` 单链表上——链表头永远是最近到期的那个，这就是"下一次闹钟"。

### 2. 分发任务：它不是队列模型

esp_timer 初始化时创建一个任务（`esp_timer_init()` → `init_timer_task()`）：

```c
xTaskCreatePinnedToCore(&timer_task, "esp_timer",
                        ESP_TASK_TIMER_STACK, NULL, ESP_TASK_TIMER_PRIO,
                        &s_timer_task, CONFIG_ESP_TIMER_TASK_AFFINITY);
```

三个参数的实际值：优先级 `ESP_TASK_TIMER_PRIO = configMAX_PRIORITIES - 3`，IDF 默认 `configMAX_PRIORITIES=25`，即 **22**——比 main 任务（优先级 1）、Tmr Svc（优先级 1）高得多，仅次于 BT controller（23）；栈 = `CONFIG_ESP_TIMER_TASK_STACK_SIZE`（默认 3584）+ 512 = **4096 字节**；默认钉在 **CPU0**。

任务主循环极简：

```c
static void timer_task(void* arg)
{
    while (true) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);   // 睡到被通知
        timer_process_alarm(ESP_TIMER_TASK);       // 一次排干所有到期定时器
    }
}
```

**以源码为准纠正一个常见说法**：很多资料（包括旧版 IDF）把 esp_timer 描述成"命令队列模式"。v6.0.2 的实现里**没有命令队列**——`esp_timer_start_once/periodic/stop` 不发消息，而是拿着每类分发一把的自旋锁（`portENTER_CRITICAL_SAFE(&s_timer_lock[])`）**直接改链表**、必要时重编报警值；硬件中断 `timer_alarm_handler()` 里 `vTaskNotifyGiveFromISR()` 通知任务起床（任务通知的机制细节见 [[ch13-task-notifications|FreeRTOS 深度解析（十三）]]）。

与 FreeRTOS 软件定时器的守护任务（[[ch15-software-timers-daemon|FreeRTOS 深度解析（十五）]]）对比，**架构同构、握手机制不同**：

| 维度         | Tmr Svc（timers.c）                          | esp_timer（v6.0.2）                        |
| ------------ | -------------------------------------------- | ------------------------------------------ |
| 分发执行流   | 单个守护任务                                 | 单个 esp_timer 任务                        |
| 到期记账     | 两条按 tick 排序的链表                       | 两条按 µs 排序的链表（TASK/ISR 各一）      |
| 状态修改路径 | **命令队列**（API 塞消息，守护任务串行处理） | **自旋锁**（API 直接改链表，ISR/任务共用） |
| 计时基准     | FreeRTOS tick（默认 10ms / BOX-3 1ms）       | SYSTIMER µs                                |
| 回调铁律     | 不许阻塞                                     | 同样不许阻塞                               |

### 3. 回调运行在哪个上下文、能不能阻塞

默认分发方式 `ESP_TIMER_TASK` 下，回调在 **esp_timer 任务上下文**执行。`timer_process_alarm()` 的写法值得抄下来：它把到期定时器摘下链表、**解锁、调回调、再上锁**——所以回调里可以调用 esp_timer API（不会自旋死锁），但也意味着：

- **回调里阻塞，全体 TASK 分发定时器一起停摆**——这就是"回调必须短小、必须非阻塞"的铁律（和 Tmr Svc 一模一样，交叉引用十五）。回调里拿一个别人持有的互斥锁，等于把系统里所有 esp_timer 定时器押在那把锁上。
- 多个回调**串行**执行：一个回调拖 100ms，后面到期的全部迟到。
- 另一条路 `ESP_TIMER_ISR`（需开 `CONFIG_ESP_TIMER_SUPPORTS_ISR_DISPATCH_METHOD`）：回调直接在 systimer 报警中断里跑，延迟最低但只适合几微秒级的极简回调，且只能用 `ESP_DRAM_LOGx` 这类中断安全日志，让出 CPU 要用 `esp_timer_isr_dispatch_need_yield()` 而非 `portYIELD_FROM_ISR()`。

两个精度事实：`esp_timer_impl_get_min_period_us()` 硬编码返回 **50µs**（更小的周期请求会被钳到 50，官方文档口径：一次性定时器实际最小超时约 20µs、周期性约 50µs）；`esp_timer_get_time()` 是**无锁**的，读 counter0 换算 µs，任务和 ISR 里都能用，BOX-3 上它是最顺手的高精度秒表。还有个源码彩蛋：删除定时器不是立刻 free，而是塞回 TASK 链表并打上事件号 `0xF0DE1E1E`（"food elele"），等分发任务跑到时在**任务上下文**里释放——ISR 分发的定时器因此避免在中断里调 `free()`。

---

## 13.3 TWDT 任务看门狗：监控"任务还活着吗"

### 1. 监控谁、谁喂狗、怎么喂

`components/esp_system/task_wdt/task_wdt.c` 的模型：一个**订阅名单**（`entries_slist`，每项记任务句柄/用户名 + `has_reset` 标志）+ 一个底层硬件超时。关键设计是**合取喂狗**：任何订阅者调用 `esp_task_wdt_reset()` 只把自己的 `has_reset` 置位，`esp_task_wdt_reset()` 内部检查"**名单上所有人**是否都已 reset"，全部 reset 才真正喂硬件定时器（`task_wdt_timer_feed()` 并清零所有标志）。换句话说：**只要有一个订阅者没喂，全系统一起背锅**——这是"看门狗是群体合同"的语义。

默认订阅名单就是两个 Idle 任务：`CONFIG_ESP_TASK_WDT_EN/INIT`（默认 y）在启动时把 CPU0/CPU1 Idle 订阅进去（`CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0/1` 默认 y）。喂狗通道是 **Idle 钩子**：Idle 任务每轮空转调 `idle_hook_cb()` → `esp_task_wdt_reset()`。

订阅自己只需两行：

```c
esp_task_wdt_add(NULL);            // NULL = 当前任务
for (;;) {
    do_work();
    esp_task_wdt_reset();          // 每轮主动喂
}
```

### 2. 高优先级忙等 → Idle 饿死 → TWDT：因果链

这是本章的核心因果链，每一步都有源码坐标：

```text
高优先级任务 while(1) 忙等（无 delay/无阻塞）
  → 调度器永不选到同核更低优先级的任务（含 Idle）
  → idle_hook_cb() 得不到执行 → Idle 的 has_reset 恒为 false
  → 硬件 MWDT0 到期，TWDT ISR 触发
```

为什么监控 Idle 而不是监控你的任务？因为 **Idle 是"这个核还有富余时间"的传感器**——Idle 还能跑，说明没有任务在独占 CPU（Idle 的更多职责见 [[ch9-blocking-delay-idle|FreeRTOS 深度解析（九）]]）。忙等任务本身往往"活得好好的"，看门狗若只盯它反而测不出来；盯着被它饿死的 Idle，才能捕获"有人独占 CPU"这种系统级病变。这也解释了因果链的精妙之处：**TWDT 报的是受害者，真凶要去日志里找**（见下）。

### 3. 超时时打印什么（读日志的正确姿势）

超时 ISR `task_wdt_isr()` 按顺序做四件事：喂一次硬件防止第二级复位（`esp_task_wdt_impl_timeout_triggered`）→ 打印**未喂狗名单** → 打印**各核正在运行的任务** → panic 或回溯。两段打印的字符串模板直接来自源码：

```text
E (t) task_wdt: Task watchdog got triggered. The following tasks/users did not reset the watchdog in time:
E (t) task_wdt:  - IDLE0 (CPU 0)
E (t) task_wdt: Tasks currently running:
E (t) task_wdt: CPU 0: <打断时恰好在这个核上的任务名>
```

（Idle 任务在 IDF 多核内核里按核命名为 `IDLE0`/`IDLE1`——`tasks.c` 在 `configIDLE_TASK_NAME "IDLE"` 后追加固编号。）

**读法**：第一段是"受害者名单"（订阅了且没喂的，通常是 IDLE）；**真凶在第二段**——TWDT 中断打断的那个正在运行的任务，就是独占 CPU 的忙等者。新手最常见的误读是把 `IDLE0` 当成"出问题的任务"去查 Idle；第二个误读方向相反：第二段里若出现 `esp_timer`、`CONSOLE` 这类系统任务，就怪罪日志系统——它们只是"被打断时恰好在场"，真正该看的仍然是谁让 Idle 五秒没跑。默认 `CONFIG_ESP_TASK_WDT_PANIC=n` 只打印回溯；置 panic 则走 `task_wdt_timeout_abort()`，跨核联手 abort（双核都挂时先打本核回溯、再发跨核中断让对核跟着崩）。用户可定义弱符号 `esp_task_wdt_isr_user_handler()` 在超时时刻追加自定义动作。

硬件层（S3）：TWDT 用 **TG0 的 MWDT0**，`CONFIG_ESP_TASK_WDT_USE_ESP_TIMER` 仅在只有一个定时器组的 C2 上默认 y（用 esp_timer 模拟）；MWDT 计数时钟 80MHz 经预分频得 **500µs/tick**，**两级超时**：stage0 = `timeout_ms`（`CONFIG_ESP_TASK_WDT_TIMEOUT_S` 默认 **5s**）触发中断走上述流程，stage1 = 2 倍超时**直接复位系统**——如果 ISR 打印都救不回来（比如打印本身卡死），硬件兜底重启。

---

## 13.4 MWDT 中断看门狗：监控"中断还能进来吗"

第二个看门狗在 `components/esp_system/int_wdt.c`，监控对象完全不同：**FreeRTOS tick 中断是否按时发生**。喂狗者是每核注册的 **tick 钩子**（`tick_hook()`，`xPortSysTickHandler()` 每个节拍都会调它）；tick 中断来不了，说明该核**中断被关太久或 ISR 失控**——长临界区（`taskENTER_CRITICAL` 家族的成本见 [[ch18-critical-sections-spinlocks|FreeRTOS 深度解析（十八）]]）、`portDISABLE_INTERRUPTS` 后忘开、中断风暴霸占同级/更高级向量，都会让它爆发。

硬件：S3 有两个定时器组，IWDT 用 **TG1 的 MWDT1**（与 TWDT 的 TG0 井水不犯河水，`int_wdt.c` 顶部 `#if TIMG_LL_GET(INST_NUM) > 1`）；`CONFIG_ESP_INT_WDT_TIMEOUT_MS` 默认 **300ms**，且代码里有硬断言"超时必须 ≥ 2 倍 tick 周期"——把 `CONFIG_FREERTOS_HZ` 调大时记得同步检查它。两级动作与 TWDT 同款：stage0 触发中断进入 panic 处理程序（错误信息为 `Interrupt wdt timeout on CPU0/1`，地址寄存器级路由到专用 panic 入口），stage1 硬复位。

| 维度     | TWDT 任务看门狗                                  | MWDT/IWDT 中断看门狗                    |
| -------- | ------------------------------------------------ | --------------------------------------- |
| 监控什么 | 订阅任务（默认 Idle）按时"报到"                  | tick 中断按时发生                       |
| 病变信号 | 任务独占 CPU、Idle 饿死                          | 关中断过长、临界区过长、ISR 风暴        |
| 谁喂狗   | 订阅任务调 `esp_task_wdt_reset()`（Idle 走钩子） | 每核 tick 钩子                          |
| 硬件     | TG0 的 MWDT0（500µs/tick）                       | TG1 的 MWDT1（500µs/tick）              |
| 默认超时 | 5s（`ESP_TASK_WDT_TIMEOUT_S`）                   | 300ms（`ESP_INT_WDT_TIMEOUT_MS`）       |
| 超时动作 | 默认打印+回溯，可配 panic                        | 直接 panic（`Interrupt wdt timeout`）   |
| 典型肇因 | `while(1)` 不 delay、忙等外设                    | 巨大临界区、`while` 等 ISR 标志忘开中断 |

---

## 13.5 RTC 看门狗与 boot 看门狗：启动阶段的保险丝

一句话级带过（细节属第六章启动流程）：上电时 ROM 会自动打开 RWDT（RTC 看门狗）与 MWDT0 的 **flashboot 保护**，防止 flash 启动期死锁；二级 bootloader 先关掉 flashboot 保护，再按 `CONFIG_BOOTLOADER_WDT_ENABLE`（默认开）重新武装 RWDT 看护"bootloader→app_main"全程（`bootloader_init.c`，默认 **9s**，`CONFIG_BOOTLOADER_WDT_TIME_MS` 可调）；app 接管前 RTC 看门狗即被禁用。两个冷知识：JTAG 调试断点时 OpenOCD 会停掉 IWDT/TWDT 的硬件定时器，所以断点期间看门狗不叫；panic 处理程序入口处会**反过来再武装 RWDT**（`panic.c` 的 `esp_panic_handler_enable_rtc_wdt`），保证 panic 处理自己卡死时芯片仍能复位。

---

## 13.6 LEDC：把"翻转 GPIO"下放给硬件

第八章用软件方式翻转 GPIO（任务 + delay 或中断回调），这条路的精度天花板是调度延迟，且**每个输出都占一个任务/中断**。LEDC（LED Ctrl）是 S3 内置的 PWM 发生器：波形的周期与占空比全由硬件维持，CPU 配完就去睡觉。

| 维度     | 软件 GPIO 翻转（第八章）    | LEDC 硬件 PWM                                                             |
| -------- | --------------------------- | ------------------------------------------------------------------------- |
| 精度     | tick/调度抖动级（ms~百 µs） | 硬件周期级，零 CPU 参与                                                   |
| CPU 成本 | 每次翻转都消耗 CPU          | 只在改占空比时碰一次                                                      |
| 数量上限 | 无硬限制（任务堆出来）      | S3：**8 通道**、**4 个时基**、14 位最大分辨率（`soc_caps.h`），仅低速模式 |
| 适合     | 低频、逻辑型开关            | 呼吸灯、背光调光、舵机                                                    |

BOX-3 上 LEDC 不是练习题而是现役部件：BSP 源码 `esp-box-3.c` 的 `bsp_display_brightness_init()` 就用 LEDC 驱动屏幕背光——GPIO47（`BSP_LCD_BACKLIGHT`）、LEDC timer1、**5kHz、10 位分辨率、LOW_SPEED 模式**。所以"呼吸灯"实验不用外接 LED，让屏幕呼吸即可（骨架代码，`ledc_fade_func_install()` 之后的渐变全由硬件完成）：

```c
#include "driver/ledc.h"

#define BL_CH   LEDC_CHANNEL_0            // 注意别与 BSP 背光用的通道冲突（14 章走读 BSP 时对账）
#define BL_GPIO 47                        // BSP_LCD_BACKLIGHT

void breathing_led_init(void)
{
    ledc_timer_config_t t = {
        .speed_mode = LEDC_LOW_SPEED_MODE,       // S3 只有低速通道
        .timer_num = LEDC_TIMER_0,
        .duty_resolution = LEDC_TIMER_10_BIT,    // 1024 级
        .freq_hz = 5000,                         // 与 BSP 背光同规格
        .clk_cfg = LEDC_AUTO_CLK,                // 自动在 APB/XTAL 里挑
    };
    ledc_timer_config(&t);
    ledc_channel_config_t ch = {
        .gpio_num = BL_GPIO,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = BL_CH,
        .timer_sel = LEDC_TIMER_0,
        .duty = 0,                               // 从灭起步
        .hpoint = 0,
    };
    ledc_channel_config(&ch);
    ledc_fade_func_install(0);                   // 硬件渐变要占一个 LEDC 中断
}

void breathing_once(void)                        // 3 秒亮→3 秒暗，硬件自走
{
    ledc_set_fade_with_time(LEDC_LOW_SPEED_MODE, BL_CH, 1023, 3000);
    ledc_fade_start(LEDC_LOW_SPEED_MODE, BL_CH, LEDC_FADE_WAIT_DONE);
    ledc_set_fade_with_time(LEDC_LOW_SPEED_MODE, BL_CH, 0, 3000);
    ledc_fade_start(LEDC_LOW_SPEED_MODE, BL_CH, LEDC_FADE_WAIT_DONE);
}
```

L4 验证点（逻辑分析仪挂 GPIO47）：应看到 5kHz 载波、占空比连续滑动；fade 期间 CPU 空闲（`uxTaskGetSystemState` 里 Idle 占比回升）——这是"硬件替 CPU 打工"的物理证据。

---

## 13.7 实验：亲手引爆一次 TWDT

> [!warning] 待真机验证
> 以下两个实验的代码已按 v6.0.2 源码与 API 写定，但**尚未在 BOX-3 真机上运行**，日志为"源码推导的预期形态"，不是实机捕获。TWDT 触发实验不依赖外设，QEMU 即可复现（QEMU 复现路径待主会话补录）；gptimer/esp_timer 抖动对比实验建议真机（QEMU 的时序仿真不保证抖动真实性）。

### 实验一：高优先级忙等触发 TWDT

```c
static void busy_task(void *arg)
{
    volatile int i = 0;
    for (;;) { i++; }                // 优先级 10、钉在 CPU0、永不 delay —— 全速忙等
}

void app_main(void)
{
    xTaskCreatePinnedToCore(busy_task, "busy", 2048, NULL, 10, NULL, 0);
}
```

预期行为（按 13.3 的源码推导）：CPU0 上的 `busy` 以优先级 10 独占该核；约 5 秒后 TWDT stage0 中断爆发，串口先打"Task watchdog got triggered..."与 ` - IDLE0 (CPU 0)`（受害者），随后"Tasks currently running:"里 `CPU 0: busy`（真凶现形）；`CONFIG_ESP_TASK_WDT_PANIC=n` 时打印回溯后系统继续苟着、每轮超时重复打印，置 panic 则直接重启。**验证点**：①触发时间 ≈ 5s；②名单里只有 IDLE0 而无 IDLE1（忙等钉在 CPU0，CPU1 的 Idle 活得好好的）——若观察到 CPU1 的 Idle 也上榜，说明忙等任务没钉核、在两核间漂移饿死了两边。

正确姿势二选一：计算任务改为分片 + `vTaskDelay()` 让出（首选）；确需长时独占，就 `esp_task_wdt_add(NULL)` 把自己挂进名单、按里程碑 `esp_task_wdt_reset()`，并把 `CONFIG_ESP_TASK_WDT_TIMEOUT_S` 调到大于最长不可分片段（flash 大区域擦除正是文档点名的典型场景）。

### 实验二：gptimer 周期回调 vs esp_timer 周期回调

同一块板、同一周期（1ms），两个定时器各翻转一个 GPIO，用逻辑分析仪量抖动：

```c
/* gptimer：54 位硬件计数，报警回调跑在 ISR 上下文（回调返回值语义：是否唤醒了高优先级任务） */
gptimer_config_t cfg = { .clk_src = GPTIMER_CLK_SRC_APB,
                         .direction = GPTIMER_COUNT_UP,
                         .resolution_hz = 1000000 };          // 1MHz，1 count = 1µs
gptimer_new_timer(&cfg, &gt);
gptimer_event_callbacks_t cbs = { .on_alarm = my_alarm_cb };
gptimer_register_event_callbacks(gt, &cbs, NULL);
gptimer_alarm_config_t al = { .alarm_count = 1000, .reload_count = 0,
                              .flags.auto_reload_on_alarm = true };
gptimer_set_alarm_action(gt, &al);
gptimer_enable(gt);
gptimer_start(gt);

/* esp_timer：软链表 + 分发任务 */
const esp_timer_create_args_t ea = { .callback = my_esp_cb, .name = "cmp" };
esp_timer_create(&ea, &et);
esp_timer_start_periodic(et, 1000);
```

预期差异（待验证）：gptimer 的报警由硬件自动重载，回调进 ISR，边到边触发，抖动小而稳；esp_timer 要经"systimer 报警中断 → 通知任务 → 任务被调度 → 回调"，路径上有任务调度延迟，且 busy 实验若同时在跑，其抖动会被显著放大——两条抖动曲线就是 13.1 表第 4 层与第 5 层的身价差。另记录：连开 5 个 `gptimer_new_timer`，第 5 个应返回 `ESP_ERR_NOT_FOUND`（S3 只有 TG0/TG1×2 = 4 个通用定时器，"no free timer" 日志来自 `gptimer_register_to_group()`）。

---

## 13.8 翻车点表与小结

| 症状                                                      | 根因                                                              | 处理                                                                               |
| --------------------------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| esp_timer 回调里拿互斥锁/`vTaskDelay`，其余定时器集体迟到 | 所有 TASK 分发回调串行跑在 esp_timer 任务里，一个阻塞全停（13.2） | 回调只做"发通知"（队列传消息），重活推给普通任务                                   |
| TWDT 每 5s 打一次 IDLE，任务"查无实锤"                    | 第一段是受害者名单，真凶在"Tasks currently running"里（13.3）     | 按第二段定位独占 CPU 的任务；别去查 Idle，也别冤枉恰好在场的 esp_timer/CONSOLE     |
| 烧录/擦除大分区时 TWDT 误触发                             | flash 擦除长时间关中断或独占 CPU，Idle 喂不上狗                   | 调大 `CONFIG_ESP_TASK_WDT_TIMEOUT_S`，或擦除前 `esp_task_wdt_reconfigure` 临时放宽 |
| TWDT 超时怎么设都别扭                                     | 合取喂狗：名单里任何一个不喂全体背锅（13.3）                      | 长任务订阅自己并按里程碑 reset；不相关任务别乱订阅                                 |
| `CONFIG_FREERTOS_HZ=1000` 后启动 assert                   | IWDT 断言超时 ≥ 2 倍 tick 周期（13.4）                            | 同步检查 `CONFIG_ESP_INT_WDT_TIMEOUT_MS`（默认 300ms）                             |
| 周期设 10µs 的 esp_timer "不准"                           | 最小周期被钳到 50µs（13.2），且文档警告 <50µs 会吃满 CPU          | µs 级波形需求改走 gptimer/RMT/LEDC（第十二章）                                     |
| LEDC 开第 9 路报错 / 背光通道打架                         | S3 只有 8 通道 4 时基，BSP 背光已占一个通道（13.6）               | 统一在 BSP 层规划通道；多通道复用同一 timer 可省时基                               |
| gptimer 创建报 `ESP_ERR_NOT_FOUND`                        | S3 通用定时器共 4 个，用完即止（13.7）                            | 回收不用的，或改用 esp_timer（数量不限）                                           |

本章小结：

- **时间是一座六层楼**：16MHz/52 位 systimer 是地基（counter1 供 tick、counter0 供 esp_timer），TG0/TG1 的 54 位定时器是可自由编程的通用层，RMT/MCPWM/LEDC 自带时基。选型原则：到点跑代码用 esp_timer，到点动引脚用硬件外设。
- **esp_timer（v6.0.2）= 高优先级任务（22 级/4KB 栈/默认 CPU0）+ 升序链表 + 自旋锁 + 任务通知**，没有命令队列——与 Tmr Svc 架构同构但握手更直接；回调跑在任务上下文、可调 esp_timer API、绝不可阻塞。
- **TWDT 监控"Idle 还活着吗"，MWDT 监控"tick 还进得来吗"**；前者抓 CPU 独占（受害者 IDLE 在名单上，真凶在"currently running"里），后者抓关中断过长（TG1，300ms，直接 panic）。两者都是 MWDT 硬件 + 两级超时：先中断报告，再硬复位兜底。
- **LEDC 是"CPU 下岗"的样板**：BOX-3 的背光本就是 LEDC 驱动（GPIO47/5kHz/10 位），呼吸灯用硬件 fade 全程零 CPU。

下一章走进 `esp-box-3` BSP 组件源码：本章埋的两条线——BSP 如何用 LEDC 点亮背光、如何替你收编板上十来颗外设——将在那里逐一对账。
