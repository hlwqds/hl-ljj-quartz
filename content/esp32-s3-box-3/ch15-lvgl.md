---
title: "ESP32-S3-BOX-3 工程实战（十五）：LVGL"
date: 2026-08-26 12:00:00
description: "在第十、十四章铺好的屏幕通路上盖一层应用框架：LVGL 8.4 的对象模型与心跳刷新机制、BOX-3 移植三件事（flush 对接 esp_lcd、GT911/TT21100 触摸 indev、缓冲三模式取舍）、esp_lvgl_port 的 GUI 任务模型与递归互斥锁纪律，最后论证音频任务为何必须压过渲染任务。"
tags: [esp32, esp32-s3, esp-idf, series, lvgl]
---

# ESP32-S3-BOX-3 工程实战（十五）：LVGL

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch14-bsp-walkthrough|第十四章：esp-box-3 BSP 组件走读]]
> **第十五章：LVGL**（当前章）
> 下一章：[[ch16-wifi-events|第十六章：WiFi 与 esp_netif]]

[[ch10-spi-display|第十章]]把「一段像素数据怎么从内存走到 ILI9342C」讲完了，[[ch14-bsp-walkthrough|第十四章]]看清了 BSP 这层板级胶水。但真实产品的屏幕上跑的不是 `esp_lcd_panel_draw_bitmap()`，而是按钮、列表、动画和触摸交互——这中间缺一层**应用框架**。本章讲 LVGL：它是什么（对象模型与心跳机制）、在 BOX-3 上怎么接（移植三件事，全部实地取证）、以及在 FreeRTOS 下怎么活（GUI 任务模型与锁纪律）。

版本事实先钉死（全部本地实读，`managed_components/` 下）：factory_demo 依赖链为 **esp-box-3 BSP 1.1.3 → espressif/esp_lvgl_port 1.4.0 → lvgl/lvgl 8.4.0**（各组件 `idf_component.yml` 的 version 字段，BSP 对 port 是 `^1` 公共依赖、port 对 lvgl 是 `^8`）。概念性论述依据 LVGL 官方文档 v8.4 版（docs.lvgl.io，2026-08-26 抓取，链接见小结前），与本地源码版本一致。

---

## 15.1 LVGL 是什么：没有窗口系统的 GUI 库

### 1. 定位：一个库，不是操作系统

官方文档的自我介绍：free and open-source graphics library，MIT 许可，目标是从 64KB Flash / 16KB RAM 起步的 MCU；「OS, external memory and GPU are supported but not required」——三个 not required 说清了它的位置。它与桌面 GUI 栈的根本差异用一张对照表看最直观：

| 维度        | 桌面 GUI 栈（X11/Wayland + GTK）         | LVGL                                           |
| ----------- | ---------------------------------------- | ---------------------------------------------- |
| 进程模型    | 多进程，窗口系统做合成与隔离             | 单进程内一棵对象树，直连一块屏                 |
| 窗口/合成器 | 有（每个应用一个窗口，合成器合成）       | 无——「屏幕」就是最顶层容器，无重叠窗口概念     |
| framebuffer | 显示服务器持有，应用不直接摸             | 移植层自己管理 draw buffer，flush 回调直接写屏 |
| 输入        | 输入系统（evdev/libinput）经窗口系统路由 | 移植层注册 indev 回调，库里轮询读取            |

所以理解 LVGL 的心智模型是「**单 framebuffer 思维**」：一块屏、一棵树、一个循环。它不调度进程、不管理权限，只做三件事——维护对象树、把树的变化渲染进缓冲、把缓冲搬到屏幕。这个极简定位正是它能在 64KB Flash 上活下来的原因。

### 2. 对象模型：一切都是 lv_obj

LVGL 的世界里只有一种基本构件——`lv_obj_t`（base object）。按钮、标签、图表这些 widget 都是它的派生；组织形式是一棵**父子树**，树的根是 screen（`lv_scr_act()` 指向当前活动屏）：

```c
lv_obj_t *scr = lv_scr_act();            /* 屏幕：树的根 */
lv_obj_t *btn = lv_btn_create(scr);      /* 按钮挂在屏幕上 */
lv_obj_t *lab = lv_label_create(btn);    /* 标签挂在按钮上——树，不是图层 */
lv_label_set_text(lab, "Press me");
lv_obj_center(btn);                      /* 布局是相对父对象的 */
```

三个关键机制配合这棵树工作：

- **事件（event）**：状态变化沿逻辑分发——`lv_obj_add_event_cb(btn, cb, LV_EVENT_CLICKED, NULL)` 注册回调，触摸按下/抬起、值改变、绘制各阶段都是事件。回调运行在 GUI 任务的上下文里（15.4 节的伏笔）。
- **样式（style）**：外观属性（颜色、边框、圆角）独立成 `lv_style_t` 对象，可复用、可级联地加到任意对象上，思路接近 CSS——factory_demo 的 `ui_button_style_init()`（`main/gui/ui_main.c:61`）就是先初始化 normal/pressed/focus 三套样式再全局复用。
- **失效（invalidate）**：改了对象只调 `lv_obj_invalidate()` 标脏，**不立即画**——画什么、什么时候画是刷新机制的事，下一节展开。

### 3. 移植面只有两个回调 + 一个心跳

文档把「LVGL 与硬件之间」压缩到了极小：`lv_disp_drv_t` 的 `flush_cb`（把一块渲染好的像素搬到屏幕）、`lv_indev_drv_t` 的 `read_cb`（读输入设备状态）、外加一个时基 `lv_tick` 和一个被周期调用的 `lv_timer_handler()`。15.3 节会看到 esp_lvgl_port 把这四件事在 BOX-3 上各自怎么落。

---

## 15.2 心跳与刷新：lv_timer_handler 在忙什么

### 1. 一切内建行为都是 lv_timer

LVGL 没有自己的线程，它的「事件循环」就是被外部周期调用的 `lv_timer_handler()`。库内一切周期性工作都注册成 `lv_timer_t`：indev 读取（`LV_INDEV_DEF_READ_PERIOD`，默认 30ms）、显示刷新（`LV_DISP_DEF_REFR_PERIOD`，默认 30ms）、动画步进、用户定时器（`lv_timer_create()`）。handler 每次被调，就遍历 timer 链表、执行到期者。文档强调两点：timers are **non-preemptive**（timer 不会互相打断，回调跑完才轮到下一个）；调用时机「not critical but it should be about 5 milliseconds」。

`lv_timer_handler()` 有返回值，本地源码头文件注释（`lvgl__lvgl/src/misc/lv_timer.h:66`）：**「time till it needs to be run next (in ms)」**——调用方可以拿它决定睡多久。这个设计在 15.4 节的 GUI 任务循环里直接兑现。

### 2. lv_tick 从哪来：esp_timer 5ms 周期回调

时基由移植层负责。官方要求 `lv_tick_inc()` 被周期调用、且「should be called in a higher priority routine than lv_task_handler() (e.g. in an interrupt)」。esp_lvgl_port 1.4.0 的实现（`esp_lvgl_port.c:1266`）：

```c
static void lvgl_port_tick_increment(void *arg)
{
    /* Tell LVGL how many milliseconds have elapsed */
    lv_tick_inc(lvgl_port_timer_period_ms);        /* 默认 5ms */
}
static esp_err_t lvgl_port_tick_init(void)
{
    const esp_timer_create_args_t lvgl_tick_timer_args = {
        .callback = &lvgl_port_tick_increment,
        .name = "LVGL tick",
    };
    ESP_RETURN_ON_ERROR(esp_timer_create(&lvgl_tick_timer_args, &lvgl_port_ctx.tick_timer), TAG, ...);
    return esp_timer_start_periodic(lvgl_port_ctx.tick_timer, lvgl_port_timer_period_ms * 1000);
}
```

即 **esp_timer 周期 5ms 打点**。esp_timer 回调跑在 esp_timer 任务/高优先级定时器上下文，高于 GUI 任务，满足文档的优先级要求。factory_demo 的 sdkconfig 里 `CONFIG_LV_TICK_CUSTOM` 未启用（实测 `# CONFIG_LV_TICK_CUSTOM is not set`），走的就是这条显式打点路径——esp_timer 的实现位置见[[ch7-system-services|第七章系统服务层]]。

### 3. 一次刷新的完整账：脏区域 → 分块渲染 → flush

把「改一行文字」到「屏幕像素变化」串起来：

```text
lv_label_set_text()                     改对象属性
   └─ lv_obj_invalidate(obj)            把对象的矩形加入 disp->inv_areas[]（可合并）
        ↓ 30ms 刷新 timer 到期，refr_timer 回调执行
   合并脏区域 → 对每个脏区：
      [渲染] 把脏区切成 draw buffer 大小的块，逐块画进 buffer（CPU 活）
      [flush] flush_cb(area, color_map) → esp_lcd_panel_draw_bitmap(...)
              → SPI DMA 搬运（第十章的数据通路从这里开始）
      [ready] DMA 完成（on_color_trans_done 中断）→ lv_disp_flush_ready()
              → LVGL 才允许复用这块 buffer 画下一块
```

三个要点：**只有脏的矩形被重画**（部分刷新，partial refresh），静止的 UI 不花 CPU；draw buffer 装不下的大脏区会被**分块**，`flush_cb` 被多次调用（文档提示用 `lv_disp_flush_is_last()` 判断最后一块）；flush 与渲染的**握手**是同步的核心——buffer 什么时候能复用，取决于 `lv_disp_flush_ready()` 什么时候被调。这三点决定了 15.3 的缓冲策略取舍。

---

## 15.3 移植三件事：BOX-3 实地取证

### 1. 显示：flush 回调对接 esp_lcd

BSP 把 esp_lcd 的 panel/io 句柄递给 esp_lvgl_port，后者注册 flush 回调。核心只有一行真码（`esp_lvgl_port.c:730`）：

```c
static void lvgl_port_flush_callback(lv_disp_drv_t *drv, const lv_area_t *area, lv_color_t *color_map)
{
    lvgl_port_display_ctx_t *disp_ctx = (lvgl_port_display_ctx_t *)drv->user_data;
    const int offsetx1 = area->x1;
    const int offsetx2 = area->x2;
    const int offsety1 = area->y1;
    const int offsety2 = area->y2;
    // copy a buffer's content to a specific area of the display
    esp_lcd_panel_draw_bitmap(disp_ctx->panel_handle, offsetx1, offsety1, offsetx2 + 1, offsety2 + 1, color_map);
}
```

注意 `x2 + 1`：LVGL 的 area 是闭区间，esp_lcd 的参数是开区间，移植层替你换算。「ready」这条握手走的是异步路（IDF ≥ 4.4.4 时编译开关 `LVGL_PORT_HANDLE_FLUSH_READY = 1`）：

```c
static bool lvgl_port_flush_ready_callback(esp_lcd_panel_io_handle_t panel_io,
                                           esp_lcd_panel_io_event_data_t *edata, void *user_ctx)
{
    lv_disp_drv_t *disp_drv = (lv_disp_drv_t *)user_ctx;
    lv_disp_flush_ready(disp_drv);       /* 在 SPI 传输完成中断里通知 LVGL */
    return false;                        /* 不需要 yield */
}
```

即 SPI DMA 传输完成中断 → `on_color_trans_done` → `lv_disp_flush_ready()`。CPU 发起 draw_bitmap 后不必傻等，渲染与搬运有了并行的前提。颜色格式一侧：`LV_COLOR_DEPTH=16`（RGB565，与 BSP 的 `BSP_LCD_BITS_PER_PIXEL=16` 一致），factory_demo 特意开了 `CONFIG_LV_COLOR_16_SWAP=y`（sdkconfig.defaults:73）——SPI 外设按字节流搬像素，而 ILI9342C 期望大端字序，字节交换在 LVGL 侧完成比在驱动侧逐像素换便宜。

### 2. 触摸：indev 读点（GT911/TT21100 双探测）

输入侧的移植同样是一个回调。esp_lvgl_port 1.4.0（`esp_lvgl_port.c:803`）：

```c
static void lvgl_port_touchpad_read(lv_indev_drv_t *indev_drv, lv_indev_data_t *data)
{
    uint16_t touchpad_x[1] = {0}, touchpad_y[1] = {0};
    uint8_t touchpad_cnt = 0;
    esp_lcd_touch_read_data(touch_ctx->handle);                      /* I2C 读触摸控制器 */
    bool pressed = esp_lcd_touch_get_coordinates(touch_ctx->handle,
                    touchpad_x, touchpad_y, NULL, &touchpad_cnt, 1); /* 取坐标 */
    if (pressed && touchpad_cnt > 0) {
        data->point.x = touchpad_x[0];
        data->point.y = touchpad_y[0];
        data->state = LV_INDEV_STATE_PRESSED;                        /* 只报状态+坐标 */
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}
```

它被 LVGL 以 30ms 周期轮询（`LV_INDEV_DEF_READ_PERIOD`，indev 也是个 lv_timer）——**LVGL 是拉模型**，不依赖触摸中断（中断引脚只帮触摸控制器自己暂存数据）。契约就两个成员：`state` 与 `point`。

控制器型号则由 BSP 在总线上现探（`esp-box-3.c` 的 `bsp_touch_new()`，实地读取）：先探 GT911 主地址、再探 GT911 备用地址、再探 TT21100，谁应答用谁；无一应答报 `Touch not found`。所以 BOX-3 的触摸控制器是 **GT911/TT21100（BSP 双探测）**，具体是哪颗待[[ch9-i2c-sensors|第九章]]的 I2C 总线扫描定案。一个有意思的分支细节：探测到 TT21100 时 BSP 会改配 ST7789 面板并做 X 镜像——**触摸型号还反推出屏幕模组的批次差异**，这是「BSP 抽象了什么」最生动的注脚。另外屏下 Home 键也是同一颗触摸控制器读出的（`esp_lcd_touch_get_button_state()`，`esp-box-3.c:624`）。

### 3. 缓冲策略：三模式对比与 factory_demo 的实选

draw buffer 的配置是移植中最大的取舍。官方文档给出基准：「it's recommended to choose the size of the draw buffer(s) to be at least 1/10 screen sized」，超过 1/10 后收益不再显著。三种模式对账（320×240×2B 全帧 = 150KB）：

| 模式                              | 显存占用              | 撕裂                                   | CPU 时序                                                                              | 适用                                                                               |
| --------------------------------- | --------------------- | -------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 全帧单缓冲（full_refresh）        | 150KB                 | 换帧期间屏在扫，必撕裂                 | 一次渲染整帧，渲染期间 SPI 空转                                                       | 几乎不用；官方明言适合带 LCD 控制器外设的 MCU，对 ILI9341 这类串口外屏「too slow」 |
| 分片单缓冲（partial，BOX-3 实选） | 320×10×2B = **6.4KB** | 脏区分块逐个上屏，块间可能被扫过——轻微 | 渲染一块→等 DMA 完成→再渲染下一块，**渲染与搬运串行**                                 | 内部 RAM 紧张、UI 动效轻量                                                         |
| 分片双缓冲 + DMA                  | 6.4KB×2               | 同上，但更低概率                       | 渲染 buf1 的同时 DMA 送 buf2，「rendering and refreshing become parallel operations」 | 想榨帧率又不想吃全帧显存                                                           |
| 全帧双缓冲 + full_refresh         | 300KB                 | 页翻转，无撕裂                         | flush 只换地址                                                                        | 有 RGB 并口屏/大 PSRAM 的板子（BOX-3 的 SPI 带宽不适合）                           |

factory_demo 的实选（`main.c:110` + `sdkconfig.defaults:72`，均为实地读取）：

```c
bsp_display_cfg_t cfg = {
    .lvgl_port_cfg = ESP_LVGL_PORT_INIT_CONFIG(),
    .buffer_size = BSP_LCD_H_RES * CONFIG_BSP_LCD_DRAW_BUF_HEIGHT,  /* 320 × 10 */
    .double_buffer = 0,                                             /* 单缓冲 */
    .flags = { .buff_dma = true, },                                 /* DMA 内部 RAM */
};
cfg.lvgl_port_cfg.task_affinity = 1;   /* GUI 任务钉在 core 1 */
```

即 **320×10 像素（6.4KB）单缓冲、DMA 内部内存**——只有 1/24 屏，比官方建议的 1/10 还小（BSP Kconfig 默认 100 行，demo 主动压到 10 行）。为什么敢这么省：factor_demo 要同屏跑语音模型、RainMaker、音频，内部 RAM 寸土寸金；而它的 UI 是菜单/状态栏类界面，脏区小、无全屏动画，10 行的分片足够在 30ms 预算内刷完。这是「按 UI 形态定制缓冲」的活例子，也是改配置的抓手——`CONFIG_BSP_LCD_DRAW_BUF_HEIGHT`（range 10~240）与 `CONFIG_BSP_LCD_DRAW_BUF_DOUBLE`（默认 n）两个 Kconfig 项就是旋钮。esp_lvgl_port 还允许把缓冲放 PSRAM（`buff_spiram`），但明确禁止 DMA+SPIRAM 同时设（「Alloc DMA capable buffer in SPIRAM is not supported」，`esp_lvgl_port.c:273`）——SPI DMA 搬不动 PSRAM 的直通限制，第十章讲过缘由。

---

## 15.4 GUI 任务模型：一个任务、一把锁

### 1. 专职 LVGL 任务（esp_lvgl_port 1.4.0 实读）

port 层不要求应用自己当循环，它创建专职任务。默认参数宏（`include/esp_lvgl_port.h:137`）与实际任务循环（`esp_lvgl_port.c:683`）：

```c
#define ESP_LVGL_PORT_INIT_CONFIG() \
    {                               \
        .task_priority = 4,         /* LVGL 任务优先级 */        \
        .task_stack = 4096,         /* 栈：字节 */               \
        .task_affinity = -1,        /* 不绑核；factory_demo 改 1 */ \
        .task_max_sleep_ms = 500,   /* 单次睡眠上限 */           \
        .timer_period_ms = 5,       /* lv_tick 打点周期 */       \
    }

static void lvgl_port_task(void *arg)
{
    uint32_t task_delay_ms = lvgl_port_ctx.task_max_sleep_ms;
    while (lvgl_port_ctx.running) {
        if (lvgl_port_lock(0)) {                    /* 拿到全局锁 */
            task_delay_ms = lv_timer_handler();     /* 干活：返回下次需运行的毫秒数 */
            lvgl_port_unlock();
        }
        /* 钳位到 [1, max_sleep] 再睡——用返回值动态决定睡眠 */
        if ((task_delay_ms > lvgl_port_ctx.task_max_sleep_ms) || (1 == task_delay_ms))
            task_delay_ms = lvgl_port_ctx.task_max_sleep_ms;
        else if (task_delay_ms < 1)
            task_delay_ms = 1;
        vTaskDelay(pdMS_TO_TICKS(task_delay_ms));
    }
    vTaskDelete(NULL);
}
```

比裸 `while(1){delay(5);handler();}` 精细的地方就在睡眠值来自 `lv_timer_handler()` 的返回值：有动画在跑时它返回 1ms（马上再干），全静止时只有 30ms 的 indev/refr timer 常驻，最长也就睡 500ms——空载不空转。

### 2. 非线程安全纪律与 ui_acquire/ui_release

官方文档的原话是制度级的：「**LVGL is not thread-safe by default**」；多任务环境「you need a mutex which should be invoked before the call of lv*timer_handler and released after it」，并且\*\*其他任务调任何 `lv*`函数都必须拿同一把锁**；ISR 里只允许`lv_tick_inc()`和`lv_disp_flush_ready()`，其余一律「set a flag … check it in an LVGL timer」。

BOX-3 三个层级把这把锁原样接力（真码）：

```c
/* esp_lvgl_port.c:187  创建：递归互斥量 */
lvgl_port_ctx.lvgl_mux = xSemaphoreCreateRecursiveMutex();

/* esp_lvgl_port.c:656  timeout_ms==0 即 portMAX_DELAY */
bool lvgl_port_lock(uint32_t timeout_ms) {
    return xSemaphoreTakeRecursive(lvgl_port_ctx.lvgl_mux, ...timeout...) == pdTRUE;
}

/* esp-box-3.c:593  BSP 薄封装 */
bool bsp_display_lock(uint32_t timeout_ms)  { return lvgl_port_lock(timeout_ms); }
void bsp_display_unlock(void)               { lvgl_port_unlock(); }

/* factory_demo main/gui/ui_main.c:51  应用层别名，注释原话：
 * "If you wish to call *any* lvgl function from other threads/tasks
 *  you should lock on the very same semaphore!" */
void ui_acquire(void) { bsp_display_lock(0); }
void ui_release(void) { bsp_display_unlock(); }
```

三个细节值得咀嚼：**递归**互斥（port 层刻意选 `xSemaphoreCreateRecursiveMutex`，允许同一任务在持锁路径里再调一个自己也会拿锁的辅助函数而不自锁）；**无限等待**（`0 → portMAX_DELAY`，UI 更新不许丢）；锁保护的不只是「画」，而是**整个 lv\_ 命名空间**——包括 `lv_label_set_text` 这类看似无害的调用，因为它同样在改 LVGL 内部链表，撞上正在跑的 `lv_timer_handler` 就是随机崩溃（翻车点表第 2 行）。

### 3. 其他任务更新 UI 的两种姿势

姿势一（直接拿锁）适合低频、短临界区的更新。factory_demo 的真例——WiFi 事件 handler 里刷状态栏图标（`main/app/app_wifi.c:131`）：

```c
} else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
    s_connected = 1;
    ui_acquire();                          /* 在事件循环任务里拿 GUI 锁 */
    ui_main_status_bar_set_wifi(s_connected);   /* 内部就是 lv_label_set_text_static */
    ui_release();
```

姿势二（发消息给 GUI 侧）适合高频数据流：生产任务把数据丢队列/任务通知，GUI 侧的消费者（GUI 任务里的 `lv_timer` 回调，或一个专职 UI worker）在锁内消费。factory_demo 的真实用例正是前者——状态栏时钟用一个 1000ms 周期的 `lv_timer`（`ui_main.c:555`，`lv_timer_create(clock_run_cb, 1000, lab_time)`）在 GUI 任务里更新 `23:59` 文本，回调天然与 `lv_timer_handler` 同上下文，**根本不需要拿锁**。区别在于代价结构：姿势一里生产者要承担**等锁 + 被渲染拖延**的时长（渲染一整帧脏区可能毫秒级），高频场景等于每个数据点都撞一次锁；姿势二把锁竞争收敛到单点，生产者永不阻塞。队列与任务通知的语义分别在[[ch10-queue-universal-ipc|FreeRTOS（十）队列]]与[[ch13-task-notifications|FreeRTOS（十三）任务通知]]，本章只取用。

### 4. 优先级权衡：为什么音频必须压过 GUI

先摆 factory_demo 的实测任务布局（各文件实地读取）：

| 任务                              | 优先级 | 绑核  | 出处                                             |
| --------------------------------- | ------ | ----- | ------------------------------------------------ |
| ir_learn_test_tx_task             | 10     | 1     | `ui_sensor_monitor.c:820`                        |
| audio_feed_task（mic 采集喂 AFE） | 5      | 0     | `app_sr.c:375`                                   |
| audio_detect_task（WakeNet 推理） | 5      | 1     | `app_sr.c:378`                                   |
| audio_player 任务                 | 5      | —     | `main.c:134`（`.priority = 5`）                  |
| **LVGL task**                     | **4**  | **1** | `ESP_LVGL_PORT_INIT_CONFIG()` 默认 + demo 改绑核 |
| rmaker_task                       | 1      | 0     | `app_rmaker.c:223`                               |

推理链条如下。第一步，硬实时与软实时的判据：音频链路的死线是 I2S DMA——半满/全满中断到了没人喂新数据， codec 就播/采出欠载（爆音、丢采样），这是**错过即毁**的硬约束；GUI 的死线是 30ms 刷新周期，错过一帧只是动画顿一下，人眼对 60→30ms 的迟滞并不敏感，是**统计满足即可**的软约束。第二步，资源冲突的形状：一次大脏区渲染（如整屏列表滚动）是几十毫秒的 CPU 连发，若 LVGL 优先级更高，audio_feed 在这几十毫秒里饿死，爆音必然发生；反过来，WakeNet 推理是 core 1 上的 CPU burst，它压过同核的 LVGL 时，UI 卡半拍但声音与唤醒不受影响。第三步，结论落在数值上：音频族全部 5、LVGL 4、后台同步 1——**用「掉帧」换「不掉采样」**。RMT 红外发射那种「错过即毁且时长极短」的瞬时任务（第十二章）则再抬到 10，短暂压过一切。这套数值不是标准答案，是「按死线的硬度排序」这一原则在 factory_demo 里的投影——第二十章综合项目会再复盘一遍。

---

## 15.5 实验：Hello LVGL + 跨任务刷 UI

### 1. 实验 A：label + button 事件切换文本

在 BSP 骨架上搭最小交互界面（基于本章实读的 API 面；依赖 factory_demo 同款组件）：

```c
#include "bsp/esp-bsp.h"
#include "lvgl.h"

static void btn_event_cb(lv_event_t *e)
{
    lv_obj_t *lab = lv_event_get_user_data(e);
    lv_label_set_text(lab, "Clicked!");      /* 回调跑在 GUI 任务里，免锁 */
}

void app_main(void)
{
    bsp_display_start();                     /* 15.3 的三件事 + 15.4 的任务/锁，全部内含 */

    lv_obj_t *scr = lv_scr_act();
    lv_obj_t *btn = lv_btn_create(scr);
    lv_obj_set_size(btn, 120, 50);
    lv_obj_center(btn);
    lv_obj_t *lab = lv_label_create(btn);
    lv_label_set_text(lab, "Press me");
    lv_obj_add_event_cb(btn, btn_event_cb, LV_EVENT_CLICKED, lab);

    bsp_display_backlight_on();
}
```

两个设计点：`bsp_display_start()` 一行完成 SPI/panel/触摸/LVGL/port 全套初始化（默认 320×10 单缓冲 DMA，与 factory_demo 等价，见 15.3）；app_main 里直接建 UI **没拿锁**——此刻 GUI 任务刚起步、尚无并发写者，且 app_main 所在 main 任务很快退出，这是 demo 语境的侥幸。严谨版应把建 UI 包进 `ui_acquire()/ui_release()`，或交给 GUI 任务执行。

> [!warning] 待真机验证
> 以上骨架尚未在真机编译烧录。预期现象：屏幕中央出现按钮，触摸点击后文本变为「Clicked!」，按钮有按压缩放反馈。若黑屏，按 15.6 第 1 行排查；若触摸无响应，注意 GT911/TT21100 双探测在启动日志中打印的是哪颗（`esp-box-3` TAG 的探测分支）。

### 2. 实验 B：任务通知唤醒 GUI 刷新

先澄清一个机制事实：esp_lvgl_port 1.4.0 的 LVGL 任务是**周期睡眠轮询**（15.4 的 `vTaskDelay` 循环），没有对外暴露「通知唤醒」入口，外部任务无法直接催它。但常态下 indev/refr timer 常驻（30ms 周期），`lv_timer_handler()` 的返回值被压在 30ms 内，锁外改完 UI 后一拍内自然刷新。所以「唤醒」的正确姿势是给**自己的 UI worker** 发任务通知：

```c
static TaskHandle_t s_ui_worker;
static lv_obj_t *s_temp_lab;      /* 实验 A 界面上的一个 label */

/* 生产者：传感器任务读到新温度，只发通知+载荷，绝不碰 lv_ */
static void sensor_task(void *arg)
{
    for (;;) {
        float t = sensor_read_blocking();          /* 伪代码：AHT20 读数 */
        xTaskNotify(s_ui_worker, *(uint32_t *)&t, eSetValueWithOverwrite);
    }
}

/* 消费者：专职 UI worker，被通知唤醒后拿锁更新 */
static void ui_worker_task(void *arg)
{
    uint32_t val;
    for (;;) {
        if (xTaskNotifyWait(0, 0, &val, portMAX_DELAY) == pdTRUE) {
            float t = *(float *)&val;
            char buf[16];
            snprintf(buf, sizeof(buf), "%.1f C", t);
            ui_acquire();                          /* 同一把递归互斥 */
            lv_label_set_text(s_temp_lab, buf);
            ui_release();
        }
    }
}

/* app_main 中（ui_acquire 内建好界面后）：
 *   xTaskCreate(ui_worker_task, "ui_work", 3072, NULL, 3, &s_ui_worker);
 *   xTaskCreate(sensor_task,    "sensor",  3072, NULL, 2, NULL);   */
```

这是 15.4 姿势二的落地：sensor 任务永远不等 GUI 锁，高频读数也不会和渲染互卡；worker 优先级（3）刻意低于 LVGL 任务（4）——更新请求排队可以，干扰渲染不值得。

> [!warning] 待真机验证
> 本实验未在真机运行。预期现象：温度数值约每秒更新一次，期间触摸滑动列表仍跟手（锁竞争不可感知）。可对照观察：把 `lv_label_set_text` 直接挪进 sensor 任务而不拿锁，压测数分钟应能复现崩溃——这是理解 15.4 第 2 小节最贵的一课（慎做，死机需要重烧）。

---

## 15.6 翻车点表与小结

| 症状                                            | 根因                                                                                                         | 处理                                                                                                                          |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| 屏幕全黑/画面永不更新                           | `lv_timer_handler()` 没被周期调用（自建任务漏了循环，或 port 任务没起来）；或 `lv_tick` 停了，timer 永不到期 | 自建循环：while(1){lock; handler; unlock; delay}；用 port 则确认 `bsp_display_start` 返回非 NULL                              |
| 运行中随机 HardFault/重启，栈回溯落在 lv\_ 函数 | 双任务并发碰 LVGL：某任务裸调 `lv_` 函数，撞上 GUI 任务正在渲染（非线程安全，15.4）                          | 全部 `lv_` 调用包进 `ui_acquire/ui_release`；ISR 里只留 `lv_tick_inc`/`lv_disp_flush_ready`，其余改通知                       |
| 画面滚动时明显撕裂/分片痕迹可见                 | 单缓冲 + 脏区跨多条扫描线，上一块还没扫完下一块已上屏                                                        | 开 `CONFIG_BSP_LCD_DRAW_BUF_DOUBLE` 双缓冲；或加大 `DRAW_BUF_HEIGHT` 减少块数；根治要全帧双缓冲页翻转（BOX-3 SPI 带宽不适合） |
| 动画卡顿、帧率上不去                            | 缓冲 320×10 太小，分块数多且渲染与 DMA 串行（15.3 表第 2 行）                                                | 增大 `CONFIG_BSP_LCD_DRAW_BUF_HEIGHT`（BSP 默认 100 行即官方 1/10 建议位）；或双缓冲并行                                      |
| 语音播报/识别时 UI 冻住，松口又恢复             | 渲染任务优先级高于音频任务，长脏区渲染饿死音频 feed（15.4 第 4 小节）                                        | 音频族优先级抬到 LVGL 之上（factory_demo：5 > 4）                                                                             |
| 别的任务改了 label 但屏幕迟迟不变               | 改动不在锁内恰逢 GUI 任务长睡（极端时上限 500ms）；或改的是非活动 screen 上的对象                            | 确认拿锁；确认对象挂在 `lv_scr_act()`；对延迟敏感就用实验 B 的 worker 模式                                                    |
| 触摸完全无反应，日志见 `Touch not found`        | I2C 上 GT911/TT21100 都不应答：地址探测失败或 I2C 总线未初始化                                               | 先跑第九章的 I2C 扫描定案；确认 `bsp_i2c_init()` 在显示启动前执行                                                             |
| 移植到别的屏颜色错乱（红蓝互换/花屏）           | 色深/字节序不匹配：`LV_COLOR_16_SWAP` 与面板期望字序不符（15.3）                                             | 对照面板手册调 `CONFIG_LV_COLOR_16_SWAP`；BGR/RGB 由 `BSP_LCD_COLOR_SPACE` 决定                                               |

本章小结：

- **LVGL 是库不是系统**：单进程、一棵 `lv_obj` 树、无窗口合成器，移植面收敛为 flush 回调、indev 回调、`lv_tick`、`lv_timer_handler` 四件事。
- **心跳与刷新**：一切内建行为是 30ms 级的 lv_timer，`lv_timer_handler()` 被周期调用时批量执行；BOX-3 上时基是 esp_timer 5ms 打 `lv_tick_inc`；刷新走「失效合并 → 分块渲染 → flush → DMA 完成中断回 ready」的部分刷新管线，与第十章的 `draw_bitmap` 通路无缝衔接。
- **移植三件事（实地取证）**：显示侧 flush 一行 `esp_lcd_panel_draw_bitmap(x1,y1,x2+1,y2+1,…)` + 中断里 `lv_disp_flush_ready`；触摸侧 30ms 轮询读点，控制器为 GT911/TT21100 双探测（探测结果还反推屏幕模组批次）；缓冲实选 **320×10 单缓冲 DMA 内部 RAM**（Kconfig 默认 100 行被 demo 压到 10）——比官方 1/10 建议更省，按 UI 形态定制的活例。
- **任务模型**：esp_lvgl_port 1.4.0 建专职任务（默认优先级 4/栈 4096，factory_demo 绑 core 1），睡眠时长由 handler 返回值动态决定；LVGL 非线程安全，全系统共用一把**递归互斥**——factory_demo 把它包装成 `ui_acquire/ui_release`，跨任务更新 UI 的正解是「拿锁短改」或「发消息给 GUI 侧消费者」。
- **优先级定式**：按死线硬度排序——音频 DMA 喂给是硬实时（factory_demo 音频族全 5），GUI 掉帧是软实时（LVGL 4），结论是用掉帧换不掉采样。

LVGL 一章把「应用」终于立起来了，下一章回到芯片的另一半天线：WiFi 连接管理、esp_netif 那层「拿到 IP 才算连上」的边界、断线重连状态机——本章 `app_wifi.c` 里那个状态栏小图标，正是两章共用的交接点。

参考（LVGL 官方文档 v8.4，2026-08-26 抓取）：intro（定位与线程安全）、porting/tick、porting/timer-handler、porting/os（锁纪律）、porting/display（缓冲建议）、porting/indev（读点契约），入口 https://docs.lvgl.io ；本地源码为 esp-box 仓库 factory_demo 的 `managed_components/{lvgl__lvgl, espressif__esp_lvgl_port, espressif__esp-box-3}`。
