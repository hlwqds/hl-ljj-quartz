---
title: "ESP32-S3-BOX-3 工程实战（十）：SPI 与屏幕"
date: 2026-08-26 12:00:00
description: "从『LVGL 调一次 flush 到屏上出画』的完整数据通路出发，四层下钻 esp_lcd：panel io + panel 驱动两级 API → SPI polling/queue 双模式与 DC 引脚的软件切换 → ILI9342C 初始化命令序列走读 → S3 GPSPI3 与 GDMA 通道对；板级事实（SPI3、GPIO6/7、40MHz、320×10 draw buf）全部从 factory_demo 真实组件源码反查，最后不依赖 LVGL 直刷纯色/色带并算清一帧 30.72ms 的总线账。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（十）：SPI 与屏幕

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch9-i2c-sensors|第九章：I2C 与传感器]]
> **第十章：SPI 与屏幕**（当前章）
> 下一章：[[ch11-i2s-audio|第十一章：I2S 与音频]]

屏幕是 BOX-3 上数据量最大的外设：I2C 一次写一个字节，SPI 刷一屏要搬 153,600 字节。它也是链路分层最清晰的外设——LVGL 画界面、esp_lcd 管协议、SPI 驱动管搬运、GDMA 管内存、屏内 GRAM 管显示，每层职责单一。本章按四层下钻走满 L1→L4；所有板级事实（SPI 总线号、引脚、时钟、缓冲）均从 factory_demo 构建下载的真实组件源码实地反查（`managed_components/espressif__esp-box-3/` v1.1.3、`espressif/esp_lcd_ili9341` v1.2.0、ESP-IDF v5.1 组件源码），驱动实现以本地 `~/esp/esp-idf-v5.1/components/` 为准。

---

## 10.1 全景：一次刷屏的数据通路

一句话版本：**CPU 只负责把像素数组交给 SPI，屏幕自己持帧**。与 RGB 屏（帧存在 ESP 侧、逐像素推流）不同，SPI 屏的帧存在屏控制器 ILI9342C 的 GRAM 里，扫描电路自刷新；ESP 侧只管"把某块区域的像素写进 GRAM"。这决定了整条通路是**搬运型**而非**流型**——正好与第十一章 I2S 的恒速流形成对照。

```text
 应用/LVGL 渲染任务（第十五章）
 │  把控件画进 draw buf（RGB565 像素数组，DMA 内存）
 ▼
 esp_lcd_panel_draw_bitmap（本章 L1）
 │  抽象 framebuffer：换算坐标，发 CASET/RASET/RAMWR 三条命令 + 像素数据
 ▼
 panel io：esp_lcd_panel_io_tx_color（本章 L2 上）
 │  传输策略：命令走 polling、像素走队列；DC 电平在 pre_cb 里切换
 ▼
 SPI master 驱动 + GDMA（本章 L3）
 │  lldesc 描述符链搬运，CPU 让出；传输完 EOF 中断 → post_cb
 ▼
 GPIO6(MOSI)/GPIO7(SCLK) 40MHz 波形（本章 L4）
 ▼
 ILI9342C（本章 L2 下：初始化命令序列）
 │  GRAM 收数，屏内扫描电路以自己的节刷显示
 ▼
 2.4" 320×240 液晶面板
```

逐层归属：draw buf 与 LVGL 的缓冲策略是第十五章的主题；`draw_bitmap` 以下到 GDMA 是本章；屏幕为什么"收下就自己亮"是 ILI9342C 命令序列（10.5 节）的事；而触摸（GT911/TT21100，I2C 总线）已在第九章扫过，本章只在面板型号判别处借用它一次。

---

## 10.2 板级事实反查：屏幕到底接在哪

先澄清一个容易踩的源码位置问题：factory_demo 的 `EXTRA_COMPONENT_DIRS` 里有本地 `esp-box/components/bsp`（第十四章的走读对象），但**显示初始化的真实代码不在那里**——本地 bsp 的 `idf_component.yml` 只声明依赖 `espressif/esp-box-3: 1.1.*`，`dependencies.lock` 解析为 **v1.1.3**，实现在 `examples/factory_demo/managed_components/espressif__esp-box-3/`。读屏幕代码要去 managed_components。

反查出的屏幕事实清单（来源：`espressif__esp-box-3/include/bsp/esp-box-3.h` 与 `esp-box-3.c`，两处实地读取；已与官方规格表交叉验证）：

| 事实            | 值                                                                                  | 出处                                                               |
| --------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| SPI 控制器      | **SPI3_HOST**（S3 的 GPSPI3，见 10.6）                                              | `BSP_LCD_SPI_NUM`（esp-box-3.h:344）                               |
| SCLK            | **GPIO7**（宏名 `BSP_LCD_PCLK`）                                                    | esp-box-3.h:61 + `buscfg.sclk_io_num`                              |
| MOSI            | **GPIO6**（宏名 `BSP_LCD_DATA0`）                                                   | esp-box-3.h:60 + `buscfg.mosi_io_num`                              |
| MISO            | **未连接**（`GPIO_NUM_NC`）——只写总线                                               | esp-box-3.c:372                                                    |
| CS              | **GPIO5**                                                                           | `BSP_LCD_CS`                                                       |
| DC（数据/命令） | **GPIO4**                                                                           | `BSP_LCD_DC`                                                       |
| RST             | **GPIO48，高电平复位**（`reset_active_high=1`，罕见）                               | `BSP_LCD_RST` + esp-box-3.c:399                                    |
| 背光            | **GPIO47**，LEDC 通道 1、5 kHz、10 bit PWM，占空 100%=最亮                          | `BSP_LCD_BACKLIGHT` + `bsp_display_brightness_init`                |
| 触摸 INT        | GPIO3                                                                               | `BSP_LCD_TOUCH_INT`                                                |
| 像素时钟        | **40 MHz**，SPI mode 0                                                              | `BSP_LCD_PIXEL_CLOCK_HZ`（esp-box-3.h:343）；官方规格表同为 40 MHz |
| 分辨率/格式     | 320×240，RGB565（16bpp），BGR 字节序                                                | `display.h`：`BSP_LCD_H_RES/V_RES/BITS_PER_PIXEL/COLOR_SPACE`      |
| 驱动 IC         | **ILI9342C**（官方规格表 specs_for_box.md:106），驱动用 esp_lcd_ili9341 组件 v1.2.0 | 规格表 + `dependencies.lock`                                       |
| draw buf        | **320×10 像素单缓冲，DMA 内存**（factory_demo 覆盖值）                              | `sdkconfig.defaults:72` `CONFIG_BSP_LCD_DRAW_BUF_HEIGHT=10`        |
| 事务队列深度    | `trans_queue_depth = 10`                                                            | esp-box-3.c:387                                                    |

三个值得展开的细节：

1. **MISO 没接，所以不能读屏**。SPI 屏标准命令里有 `RDDID`（0x04，读面板 ID），但 MISO 悬空让 `esp_lcd_panel_io_rx_param` 无从工作。BSP 于是用了一个取巧的判别法——**在 I2C 上探测触摸控制器来推断屏幕型号**（esp-box-3.c:404-409）：探测到 TT21100 触摸的板子走 ST7789 面板驱动；否则走 ILI9341 驱动 + 厂商初始化序列。BOX-3 标准版的触摸是 GT911/TT21100（BSP 双探测，以第九章 I2C 扫描定案），两种硬件批次对应两种屏。命令集同族兼容：ILI9342C 由 ILI9341 驱动 + 厂商序列点亮。
2. **头文件注释与代码打架**。esp-box-3.h:334 的注释写着 "ESP-BOX is shipped with 2.4inch ST7789 display controller"，而同文件代码创建的是 ILI9341 面板——事实以规格表和代码为准，注释是历史遗留。读 BSP 时"注释仅供参考、宏和函数才是证据"，这是第一课。
3. **背光不是普通 GPIO**。它接在 LEDC PWM 上（`bsp_display_brightness_set` 按 10bit 分辨率换算占空），所以裸用 esp_lcd 点屏时，拉高 GPIO47 只是"最粗的亮法"，标准做法是复用 BSP 的亮度接口。LEDC 本身的机制在第十三章展开。

---

## 10.3 L1 应用层：esp_lcd 的两级 API

esp_lcd 把"一块 SPI 屏"拆成两个对象，这是理解全部 API 的钥匙：

```text
 SPI 总线（spi_bus_initialize，SPI 驱动的地盘）
   └─ panel io（esp_lcd_new_panel_io_spi）    ← "怎么说"：传输层
        │  持有 SPI 设备句柄、CS/DC 引脚、事务队列、完成回调
        └─ panel（esp_lcd_new_panel_ili9341）  ← "说什么"：控制器层
             持有 RST 引脚、初始化命令表、GRAM 地址窗口逻辑
```

panel io 回答"命令和像素分别怎么送到总线上"，panel 回答"这块控制器听懂哪些命令"。换 ST7789 的屏，panel io 原封不动，只换 panel 驱动——BSP 的双分支正是只换后半截。BSP 的创建代码（esp-box-3.c:369-413，节选）：

```c
/* 1. SPI 总线：SCLK=7, MOSI=6, 无 MISO，DMA 自动分配 */
const spi_bus_config_t buscfg = {
    .sclk_io_num = BSP_LCD_PCLK,
    .mosi_io_num = BSP_LCD_DATA0,
    .miso_io_num = GPIO_NUM_NC,          /* 屏只写不读 */
    .max_transfer_sz = config->max_transfer_sz,
};
spi_bus_initialize(BSP_LCD_SPI_NUM, &buscfg, SPI_DMA_CH_AUTO);

/* 2. panel io：CS=5, DC=4, 40MHz, mode0, 队列深 10 */
const esp_lcd_panel_io_spi_config_t io_config = {
    .dc_gpio_num = BSP_LCD_DC,
    .cs_gpio_num = BSP_LCD_CS,
    .pclk_hz = BSP_LCD_PIXEL_CLOCK_HZ,   /* 40 MHz */
    .lcd_cmd_bits = 8, .lcd_param_bits = 8,
    .spi_mode = 0,
    .trans_queue_depth = 10,
};
esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)BSP_LCD_SPI_NUM, &io_config, ret_io);
/* 3. panel 驱动：RST=48（高有效），RGB565，BGR，厂商初始化序列 */
esp_lcd_panel_dev_config_t panel_config = {
    .reset_gpio_num = BSP_LCD_RST,
    .flags.reset_active_high = 1,
    .color_space = BSP_LCD_COLOR_SPACE,        /* BGR */
    .bits_per_pixel = BSP_LCD_BITS_PER_PIXEL,  /* 16 */
};
/* 探测不到 TT21100 触摸 → ILI9341 分支（BOX-3 标准版走这里） */
panel_config.vendor_config = (void *)&vendor_config;
esp_lcd_new_panel_ili9341(*ret_io, &panel_config, ret_panel);
/* 4. 起屏四连：复位 → 初始化 → 镜像 → 开显示 */
esp_lcd_panel_reset(*ret_panel);
esp_lcd_panel_init(*ret_panel);
esp_lcd_panel_mirror(*ret_panel, true, true);   /* MADCTL 置 MX|MY */
```

拿到 panel 句柄后，应用面对的是一个"抽象 framebuffer"，API 全家：

| API                                                            | 干什么                               | 坐标系                   |
| -------------------------------------------------------------- | ------------------------------------ | ------------------------ |
| `esp_lcd_panel_draw_bitmap(panel, x0, y0, x1, y1, color_data)` | 把像素数组写进 GRAM 的指定矩形       | 左上原点，**含头不含尾** |
| `esp_lcd_panel_mirror / swap_xy`                               | 改 MADCTL 的 MX/MY/MV 位             | —                        |
| `esp_lcd_panel_invert_color`                                   | 发 INVON/INVOFF（像素极性反转）      | —                        |
| `esp_lcd_panel_disp_on_off`                                    | 发 DISPON/DISPOFF（输出使能）        | —                        |
| `esp_lcd_panel_reset / init / del`                             | 硬复位（拉 RST）、发初始化序列、销毁 | —                        |

两个高频坑先埋个记号：`draw_bitmap` 的矩形是半开区间（LVGL port 调用时传 `x2+1, y2+1`，见 esp_lvgl_port.c:741）；`disp_on_off` **不在 init 里自动调用**——display.h 的注释明言"你必须显式打开显示"，忘掉它就是黑屏（翻车点表第一行）。

---

## 10.4 L2（上）：panel io 的 SPI+DMA 实现

panel io 的实现全在 IDF 的 `components/esp_lcd/src/esp_lcd_panel_io_spi.c`（v5.1 实地读取），核心是**两套发送模式 + 一个软切换的 DC**。

### 1. 命令走 polling，像素走队列

`esp_lcd_new_panel_io_spi` 内部调 `spi_bus_add_device`，挂上两个 SPI 驱动回调（esp_lcd_panel_io_spi.c:84-85）：`pre_cb` 管事务开始前的 DC 电平，`post_cb` 管事务结束后的完成通知。此后两条路径泾渭分明：

- `esp_lcd_panel_io_tx_param`（发命令/参数）：**polling 模式**。先等队列里所有在途事务排空，再 `spi_device_polling_transmit` 发命令字节（8 bit，DC 低），参数跟在后面（DC 高），全程 CS 保持有效。命令短，等一等无所谓。
- `esp_lcd_panel_io_tx_color`（发像素）：命令字节（RAMWR）仍走 polling，**像素数据走队列**——`spi_device_queue_trans` 交给 DMA，函数立刻返回，CPU 去干别的。

像素数据的分块逻辑（esp_lcd_panel_io_spi.c:350-397，节选）：

```c
/* color buffer 太大时切成 chunk，逐块入队 */
do {
    size_t chunk_size = color_size;
    if (chunk_size > spi_panel_io->spi_trans_max_bytes) {
        chunk_size = spi_panel_io->spi_trans_max_bytes;
        lcd_trans->base.flags |= SPI_TRANS_CS_KEEP_ACTIVE;   /* 块间 CS 不抬 */
    } else {
        lcd_trans->flags.en_trans_done_cb = 1;  /* 只在最后一块回调完成 */
    }
    lcd_trans->flags.dc_gpio_level = spi_panel_io->flags.dc_data_level;
    lcd_trans->base.length = chunk_size * 8;    /* 单位是 bit */
    spi_device_queue_trans(spi_panel_io->spi_dev, &lcd_trans->base, portMAX_DELAY);
    color = (const uint8_t *)color + chunk_size;
    color_size -= chunk_size;
} while (color_size > 0);
```

三个要点：块间用 `SPI_TRANS_CS_KEEP_ACTIVE` 让 CS 一直压低，对屏来说整帧像素是**一次连续的写 GRAM**；`on_color_trans_done` 只在最后一块触发，避免过早报完成；`spi_trans_max_bytes` 来自 `spi_bus_get_max_transaction_len`——BSP 传 `max_transfer_sz = 320×10×2 = 6400` 字节，驱动按 `lldesc` 描述符数向上取整到 2×4092=8184 字节（spi_common.c:805-808），于是一个 6400 字节的 draw buf 恰好一笔发完，不分块。

### 2. DC 引脚是软件切的 GPIO

SPI 本身没有 DC 信号。实现方式朴得出奇（esp_lcd_panel_io_spi.c:404-411）：

```c
static void lcd_spi_pre_trans_cb(spi_transaction_t *trans)
{
    /* 事务开始前，按这笔事务的类型拉 DC 电平 */
    if (spi_panel_io->dc_gpio_num >= 0) {
        gpio_set_level(spi_panel_io->dc_gpio_num, lcd_trans->flags.dc_gpio_level);
    }
}
```

默认约定：DC **低=命令字节、高=数据/参数**（`flags.dc_high_on_cmd` 等三个位可反转，esp_lcd_panel_io.h:136-139）。DC 在 SPI 中断里、CS 压低之前切好，硬件随后送数——这就是 L4 里"DC 必须先于 CS 稳定"的来源。

### 3. 完成回调跑在 ISR 里

`post_cb` 由 SPI 驱动的中断调用，`on_color_trans_done` 因此**运行在中断上下文**，返回值约定与第八章、第十二章的 ISR 回调完全一致：返回 true 表示唤醒了高优先级任务，驱动据此在 ISR 出口做 `portYIELD_FROM_ISR`。esp_lvgl_port 的用法最直接——在 ISR 里调 `lv_disp_flush_ready`（esp_lvgl_port.c:721-727）；自己的工程里更常见的姿势是任务通知唤醒等待方，机制细节在 [[ch13-task-notifications|FreeRTOS 深度解析（十三）：任务通知]]，10.8 的实验就用这个姿势。

注意异步语义（esp_lcd_panel_io.h:86-89 注释原话）：`tx_color` 返回时数据可能还没发完，**color 缓冲在回调到来之前不许动**——这一点和第十二章 `rmt_transmit` 的 payload 纪律一模一样。

---

## 10.5 L2（下）：ILI9342C 初始化命令序列走读

`esp_lcd_new_panel_ili9341` 只分配一个结构体、记下 reset 引脚和 bpp，真正的"点屏魔法"在 `esp_lcd_panel_init` 里。组件 v1.2.0 的 `panel_ili9341_init`（esp_lcd_ili9341.c:228-280）分两段：

```c
/* 第一段：标准苏醒流程 */
esp_lcd_panel_io_tx_param(io, LCD_CMD_SLPOUT, NULL, 0);   /* 0x11 退出睡眠 */
vTaskDelay(pdMS_TO_TICKS(100));                            /* 等内部电源稳定 */
esp_lcd_panel_io_tx_param(io, LCD_CMD_MADCTL, &ili9341->madctl_val, 1); /* 0x36 */
esp_lcd_panel_io_tx_param(io, LCD_CMD_COLMOD, &ili9341->colmod_val, 1); /* 0x3A */

/* 第二段：厂商序列逐条下发，每条后按 delay_ms 等待 */
for (int i = 0; i < init_cmds_size; i++) {
    esp_lcd_panel_io_tx_param(io, init_cmds[i].cmd, init_cmds[i].data, init_cmds[i].data_bytes);
    vTaskDelay(pdMS_TO_TICKS(init_cmds[i].delay_ms));
}
```

MADCTL/COLMOD 的值由创建参数算出：BGR 色序给 MADCTL 置上 BGR 位，16bpp 对应 COLMOD=0x55（RGB565）。而第二段的"厂商序列"来自 BSP，全文（esp-box-3.c:36-54）：

```c
static const ili9341_lcd_init_cmd_t vendor_specific_init[] = {
    {0xC8, (uint8_t []){0xFF, 0x93, 0x42}, 3, 0},   /* 厂商私有（未核对 datasheet 命名） */
    {0xC0, (uint8_t []){0x0E, 0x0E}, 2, 0},         /* Power Control 1 */
    {0xC5, (uint8_t []){0xD0}, 1, 0},               /* VCOM Control */
    {0xC1, (uint8_t []){0x02}, 1, 0},               /* Power Control 2 */
    {0xB4, (uint8_t []){0x02}, 1, 0},               /* Display Inversion Control */
    {0xE0, (uint8_t []){0x00,0x03,0x08,0x06,0x13,0x09,0x39,0x39,0x48,
                        0x02,0x0a,0x08,0x17,0x17,0x0F}, 15, 0},  /* 正 Gamma */
    {0xE1, (uint8_t []){0x00,0x28,0x29,0x01,0x0d,0x03,0x3f,0x33,0x52,
                        0x04,0x0f,0x0e,0x37,0x38,0x0F}, 15, 0},  /* 负 Gamma */
    {0xB1, (uint8_t []){0x00, 0x1B}, 2, 0},         /* 帧率控制 */
    {0x36, (uint8_t []){0x08}, 1, 0},               /* MADCTL：仅 BGR 位 */
    {0x3A, (uint8_t []){0x55}, 1, 0},               /* COLMOD：16bpp RGB565 */
    {0xB7, (uint8_t []){0x06}, 1, 0},               /* Entry Mode */
    {0x11, (uint8_t []){0}, 0x80, 0},               /* Sleep Out（再次下发） */
    {0x29, (uint8_t []){0}, 0x80, 0},               /* Display On —— 真正点亮的命令 */
    {0,    (uint8_t []){0}, 0xff, 0},               /* 结束符条目（见下文） */
};
```

读出四个工程事实：

1. **Gamma 表是"调色"数据**。0xE0/0xE1 各 15 字节，决定灰阶过渡的观感——不同批次屏的液晶/背光有差异，厂商逐屏调好后把这张表写进 BSP。这解释了为什么换第三方屏"能亮但颜色不对"：序列可以兼容，gamma 未必匹配。
2. **真正点亮屏幕的是序列末尾的 0x29（DISPON）**。组件的 init 段并不发 DISPON，靠厂商序列或应用后续的 `disp_on_off(true)` 补上——BSP 两条路都走了（序列里的 0x29 + `bsp_display_lcd_init` 里的显式调用，esp-box-3.c:436）。
3. **MADCTL 的 0x08 只含 BGR 位**，而 BSP 在 init 之后又调 `esp_lcd_panel_mirror(true, true)` 把 MX|MY 补上——最终 MADCTL=0xC8，得到 BOX-3 的默认横屏方向。坐标方向不对时先查这两处的叠加结果。
4. **尾部三条是历史遗留写法**：`{0x11,…,0x80,0}`、`{0x29,…,0x80,0}` 的第三个字段是 `data_bytes`，0x80=128 字节参数——组件按条数遍历、不检查结束符（esp_lcd_ili9341.c:254 的 for 循环），于是连 `{0,…,0xff,0}` 结束符也会被当作命令 0x00（NOP）下发。实际无害（NOP 的多余参数被屏忽略、SLPOUT 已在第一段发过），但**在逻辑分析仪上数初始化波形时会比命令表多出几笔传输**，知道出处就不慌。

`draw_bitmap` 则是三笔命令 + 一笔数据（esp_lcd_ili9341.c:294-308）：CASET（0x2A，列窗口）→ RASET（0x2B，行窗口）→ RAMWR（0x2C，开始写）→ 像素流。窗口坐标含头不含尾（发的是 `x_end-1`），与 API 的半开区间约定对齐。

---

## 10.6 L3 寄存器层：S3 的 GPSPI3 与 GDMA

对照 `soc_caps.h`、SPI 驱动源码与文档（v5.1 实地读取）：

| 项目         | ESP32-S3 的事实                                                                                                                                                   | 出处                            |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| 控制器       | 3 个 SPI：SPI0/1 专属 Flash，**SPI2/GPSPI2 与 SPI3/GPSPI3 为通用控制器**                                                                                          | `SOC_SPI_PERIPH_NUM = 3`        |
| 谁被屏占用   | **SPI3_HOST（GPSPI3）**；SPI2 预留给扩展（DOCK 的 PMOD2 引脚注释 "Intended for SPI2"）                                                                            | BSP 宏 + esp-box-3.h PMOD 注释  |
| DMA          | 无私有 DMA，`SPI_DMA_CH_AUTO` 从 **GDMA 通道池**领一对 TX+RX 通道（`reserve_sibling` 成对保留）并 `GDMA_MAKE_TRIGGER(GDMA_TRIG_PERIPH_SPI, 3)` 挂到 GPSPI3 请求线 | spi_common.c:229-256            |
| 单笔上限     | FIFO 64 字节（`SOC_SPI_MAXIMUM_BUFFER_SIZE`）；DMA 单链最长 `SPI_LL_DMA_MAX_BIT_LEN = 2^18 bit = 32 KB`；实际取 `min(max_transfer_sz, 32KB)`                      | spi_ll.h:43 + spi_master.c:1132 |
| 时钟         | 最高 80 MHz；**S3 上经 GPIO matrix 走线与 IOMUX 行为相同**（≤80MHz 时），BOX-3 的 GPIO6/7 并非 IOMUX 专用脚但不吃亏                                               | spi_master.rst:432-434          |
| 控制器不对称 | Octal 八线模式仅 SPI2 支持（"SPI3 does not support octal mode"）                                                                                                  | spi_master.c:781                |

两个对工程有直接影响的推论：

1. **40 MHz 不是 GPIO matrix 的锅**。老教程常说"GPIO matrix 只能跑 40 MHz、IOMUX 才 80 MHz"——那是**经典 ESP32** 的限制（spi_master.rst:390-397 明确只对 esp32 生效）；S3 文档原话是 80MHz 及以下"GPIO matrix 与 IOMUX 表现相同"。BSP 选 40 MHz 更可能是 ILI9342C 接口规格的上限（官方规格表同写 40 MHz）；具体的 datasheet 时序参数手头无原件，**待核对**——真机到手后用 10.7 的方法实测当前时钟，再试 80MHz 看是否花屏即可定案。
2. **GDMA 通道是整机共享池**，与第十一章的 I2S 收发两通道同池。BOX-3 一块板上：SPI3 屏占一对、I2S1 音频占一对——外设越堆越多时，`spi_bus_initialize` 或 `gdma_new_channel` 报 `ESP_ERR_NOT_FOUND` 会落在"最后注册的那个外设"头上，真凶往往是池子枯竭。

再补一个藏在 SPI 驱动里的性能真相：`setup_priv_desc`（spi_master.c:867-874）发现发送缓冲**不在 DMA-capable 内存**时，会悄悄 `heap_caps_malloc(MALLOC_CAP_DMA)` 一块临时内存、memcpy 进去再发——不报错、只掉速。esp_lvgl_port 专门提供 `buff_dma` 标志用 `MALLOC_CAP_DMA` 分配 draw buf（esp_lvgl_port.c:274-282），就是为了绕开这次隐藏拷贝；PSRAM 缓冲同理必被拷贝（`buff_dma && buff_spiram` 互斥，直接报不支持）。内存能力位的语义在 [[ch20-idf-heap-and-caps|FreeRTOS 深度解析（二十）：IDF 堆与 caps]] 拆过。

---

## 10.7 L4 物理层：SPI 波形怎么看

按 mode 0（CPOL=0/CPHA=0）与 10.4 的实现，一次 `draw_bitmap` 在四根线上应当呈现的**结构性关系**（描述性预期，非实测）：

```text
 CS   ──┐  CASET  ┌─ RASET ┌─ RAMWR ┌──────────── 像素数据 ───────────┐──
        └─────────┘────────┘────────┘  （块间 CS 保持低，一笔连续）      ┘
 DC   ──低──┬─高──┬─低──┬─高──┬─低──┬────────────── 高 ──────────────
           │     │     │     │     └── RAMWR 命令字节期间的窗口
 CLK      8 拍   4×8拍  8 拍  ...            40MHz 连续时钟
 MOSI     0x2A  x0x1.. 0x2B  ...            RGB565 像素流（MSB first）
```

- **CS 是"事务边界"的物理呈现**：一次 draw_bitmap 里 CASET/RASET/RAMWR/像素属于若干笔 SPI 事务，但块间 `CS_KEEP_ACTIVE` 让 CS 全程压低，屏看到的是一整段连续写入；
- **DC 先于 CS 稳定**：DC 在中断里先行切换，CS 压低时电平已就位；命令字节期间 DC 低、参数与像素期间 DC 高，翻转点就是"命令/数据"分界；
- **时钟实测方法**：分析仪测 CLK 周期取倒数即实际 `pclk_hz`（驱动可能按分频精度向下取整）；再量 CS 低电平总宽度，除以本笔字节数×8，可反推有效带宽利用率。

> [!warning] 待真机验证
> 两个设备侧的硬约束要先说破：其一，系列装备的 24 MHz 8 通道逻辑分析仪**采不清 40 MHz 时钟**（奈奎斯特欠采样），抓到的 CLK 会是伪波形——正确姿势是临时把 `pclk_hz` 降到 2 MHz 以下重编译，抓"结构"（CS 包络、DC 翻转、命令顺序、初始化全序列），量完再改回 40 MHz；其二，上电初始化波形按 10.5 的序列表逐笔对账（注意尾部那三条历史遗留条目也会出现在总线上）。以上均为设计预期的量法，实测截图待真机补。

---

## 10.8 实验：不依赖 LVGL 直刷纯色与色带

目标：绕过 LVGL，只用 esp_lcd 两级 API 把屏点亮，验证 10.3 的调用次序与 10.4 的异步语义。引脚用 10.2 反查的实值（不引 BSP 头文件，保持工程自包含；厂商序列直接搬 10.5 的数组）：

```c
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_ili9341.h"     /* 组件 espressif/esp_lcd_ili9341 */
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define LCD_SPI_NUM   SPI3_HOST
#define LCD_SCLK      7      /* BSP_LCD_PCLK   */
#define LCD_MOSI      6      /* BSP_LCD_DATA0  */
#define LCD_CS        5      /* BSP_LCD_CS     */
#define LCD_DC        4      /* BSP_LCD_DC     */
#define LCD_RST       48     /* BSP_LCD_RST，高电平复位 */
#define LCD_BL        47     /* BSP_LCD_BACKLIGHT */
#define H_RES  320
#define V_RES  240

static TaskHandle_t s_flush_waiter;   /* 10.4：完成回调唤醒等待方 */

static bool flush_done_cb(esp_lcd_panel_io_handle_t io, esp_lcd_panel_io_event_data_t *e, void *u)
{
    BaseType_t hp_woken = pdFALSE;
    vTaskNotifyGiveFromISR(s_flush_waiter, &hp_woken);   /* ISR 里只做这一件事 */
    return hp_woken;                                     /* 让驱动决定是否 yield */
}

/* 厂商初始化序列：整段复制 esp-box-3.c:36-54 的 vendor_specific_init[] */
void app_main(void)
{
    /* 1. 总线（40MHz、DMA）与 panel io */
    spi_bus_config_t buscfg = {
        .sclk_io_num = LCD_SCLK, .mosi_io_num = LCD_MOSI,
        .miso_io_num = GPIO_NUM_NC, .max_transfer_sz = H_RES * 20 * sizeof(uint16_t),
    };
    ESP_ERROR_CHECK(spi_bus_initialize(LCD_SPI_NUM, &buscfg, SPI_DMA_CH_AUTO));

    esp_lcd_panel_io_spi_config_t io_cfg = {
        .cs_gpio_num = LCD_CS, .dc_gpio_num = LCD_DC,
        .pclk_hz = 40 * 1000 * 1000, .spi_mode = 0,
        .lcd_cmd_bits = 8, .lcd_param_bits = 8,
        .trans_queue_depth = 10,
        .on_color_trans_done = flush_done_cb,   /* 创建时即可挂回调 */
    };
    esp_lcd_panel_io_handle_t io = NULL;
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)LCD_SPI_NUM, &io_cfg, &io));

    /* 2. panel + 起屏四连（次序照抄 BSP） */
    ili9341_vendor_config_t vendor = { .init_cmds = vendor_specific_init,
                                       .init_cmds_size = sizeof(vendor_specific_init)/sizeof(ili9341_lcd_init_cmd_t) };
    esp_lcd_panel_dev_config_t dev_cfg = {
        .reset_gpio_num = LCD_RST, .flags.reset_active_high = 1, /* BOX-3 特有极性 */
        .rgb_endian = LCD_RGB_ENDIAN_BGR, .bits_per_pixel = 16,
        .vendor_config = &vendor,
    };
    esp_lcd_panel_handle_t panel = NULL;
    ESP_ERROR_CHECK(esp_lcd_new_panel_ili9341(io, &dev_cfg, &panel));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    ESP_ERROR_CHECK(esp_lcd_panel_mirror(panel, true, true));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel, true));      /* 不调 = 黑屏 */

    /* 3. 背光：粗点亮的懒办法是 GPIO 拉高（标准做法复用 BSP 的 LEDC 亮度接口） */
    gpio_config_t bl = { .pin_bit_mask = 1ULL << LCD_BL, .mode = GPIO_MODE_OUTPUT };
    gpio_config(&bl);
    gpio_set_level(LCD_BL, 1);
    /* 4. 刷色带：一次整帧。draw buf 必须 DMA-capable（10.6 的隐藏拷贝教训） */
    static uint16_t buf[H_RES * V_RES];            /* static → 内部 RAM，DMA 可用 */
    for (int y = 0; y < V_RES; y++) {
        uint16_t c = y < V_RES/3 ? 0xF800 : (y < 2*V_RES/3 ? 0x07E0 : 0x001F);
        for (int x = 0; x < H_RES; x++) buf[y * H_RES + x] = c;
    }
    s_flush_waiter = xTaskGetCurrentTaskHandle();
    ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(panel, 0, 0, H_RES, V_RES, buf));
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);       /* 等 ISR 通知：buf 此后才可复用 */
}
```

> [!warning] 待真机验证
> 本骨架尚未上板编译烧录。预期现象：红绿蓝三横条；两个待核对点：其一，整帧 153,600 字节远超单笔上限——`max_transfer_sz=12,800` 经 lldesc 取整（4×4092）后单块上限 16,368 字节，panel io 会把整帧切成约 10 块连续发送（10.4 的 chunk 循环），CS 全程压低、屏上应无接缝；其二，若改用栈上大数组或 PSRAM 缓冲，依靠驱动的隐藏 memcpy 仍能点亮，但吞吐下降——是否可感知需实测帧率对比（帧率量法：计时 N 次 `ulTaskNotifyTake` 往返）。

最后把总线账算清（代入本章反查的真实值）：

```text
一整帧数据量   = 320 × 240 × 2 字节 = 153,600 B（1,228,800 bit）
传输时间       = 1,228,800 ÷ 40,000,000 = 30.72 ms
理论帧率上限   = 1000 ÷ 30.72 ≈ 32.6 fps          ← 纯总线时间，不含渲染与命令开销
一个 draw buf  = 320 × 10 × 2 = 6,400 B → 1.28 ms/块
整帧 = 24 个 320×10 条带 × 1.28 ms = 30.72 ms     ← 与整帧公式自洽
BSP Kconfig 默认（100 行条带）= 64,000 B → 12.8 ms/块
```

一个有意思的对比：esp_lvgl_port 注释建议 draw buf "至少 1/10 屏"（7,680 像素），而 factory_demo 只给 3,200 像素（1/24 屏）——用更小的缓冲换内存，代价是整帧要切 24 次 flush；LVGL 只刷脏区的特性让日常界面远小于整帧，这笔取舍在 factory_demo 的内存预算下是划算的。实际帧率受 LVGL 渲染、任务调度、脏区大小多重影响，**待真机验证**后再补数。

---

## 10.9 翻车点表与小结

| 症状                             | 根因                                                                                              | 处理                                                                                                                     |
| -------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| 背光亮但屏全黑                   | 没调 `esp_lcd_panel_disp_on_off(panel, true)`，DISPON 从未发出（init 不代发，display.h 注释明言） | init 后显式调用；裸序列方案则确认厂商序列含 0x29                                                                         |
| 背光也不亮                       | GPIO47 背光没使能（LEDC duty=0 或 GPIO 没拉）                                                     | `bsp_display_backlight_on()`，或实验里的 GPIO 拉高                                                                       |
| 全白/花屏，命令全发了            | RST 极性接反：BOX-3 是**高电平复位**（`reset_active_high=1`，罕见）                               | 对照 esp-box-3.c:399 改极性                                                                                              |
| 红蓝互换                         | rgb_endian（BGR）与面板/像素序不匹配                                                              | 换 `LCD_RGB_ENDIAN_BGR/RGB` 或改 MADCTL 的 BGR 位                                                                        |
| 画面镜像/颠倒                    | MADCTL 的 MX/MY 与预期不符                                                                        | 对照 BSP 的 `mirror(true, true)`（0x08 → 0xC8）                                                                          |
| 帧率远低于 32.6fps 理论值        | draw buf 落在 PSRAM/普通堆，SPI 驱动在 `setup_priv_desc` 里悄悄 malloc+memcpy（spi_master.c:867） | 用 `MALLOC_CAP_DMA` 分配（esp_lvgl_port 的 `buff_dma` 同理），详见 [[ch20-idf-heap-and-caps\|FreeRTOS（二十）内存 caps]] |
| 刷屏数据偶发损坏                 | `draw_bitmap` 返回即改写 color 缓冲——异步语义，DMA 还在读                                         | 在 `on_color_trans_done` 后（任务通知唤醒）再复用缓冲                                                                    |
| 抓 SPI 波形全是噪声              | 24MHz 分析仪对 40MHz 时钟欠采样                                                                   | 临时降 `pclk_hz` 抓结构，量完改回（10.7）                                                                                |
| 想再加一块 SPI 设备失败/总线冲突 | 忘了屏独占 SPI3；或共享总线时忽略 MISO 未接（读不了从设备）                                       | 新设备挂 SPI2（DOCK 的 PMOD2 预留）或评估真共享                                                                          |
| 初始化后首帧前短暂白屏           | SLPOUT 后面板内部电源需要稳定时间（驱动里 `vTaskDelay(100)`）                                     | 属正常时序，别删延时                                                                                                     |

本章小结：

- **SPI 屏是"搬运型"外设**：帧存在 ILI9342C 的 GRAM 里，ESP 侧只负责把像素矩形写进去；通路五层（LVGL → draw_bitmap → panel io → SPI+GDMA → GRAM），每层一个职责。
- **板级事实全部反查自 BSP v1.1.3**：SPI3（GPSPI3）、SCLK=GPIO7、MOSI=GPIO6、CS=5、DC=4、RST=48（**高有效**）、背光=47（LEDC PWM）、40 MHz mode 0、320×240 RGB565 BGR、draw buf 320×10 单缓冲 DMA 内存。MISO 未接 → 读不了面板 ID → BSP 用 I2C 探测触摸（GT911/TT21100 双探测）来挑面板驱动，这个设计本身就是"工程约束倒逼方案"的样本。
- **L1 两级 API**：panel io 管"怎么说"（`esp_lcd_new_panel_io_spi`：DC/CS/时钟/队列/回调），panel 管"说什么"（`esp_lcd_new_panel_ili9341`：复位、命令序列、坐标窗口）；`draw_bitmap` 半开区间、`disp_on_off` 必须显式调。
- **L2 两条腿**：命令 polling、像素 queue+DMA，块间 CS 压低成一笔连续写；DC 是 pre_cb 里软件切的 GPIO（低=命令、高=数据）；`on_color_trans_done` 跑在 ISR，唤醒任务用任务通知。ILI9342C 初始化序列 = 标准苏醒段（SLPOUT+100ms、MADCTL、COLMOD）+ 厂商段（电源/VCOM/Gamma/MADCTL/COLMOD/DISPON），尾部三条历史遗留条目会额外出现在总线上。
- **L3**：S3 给了 GPSPI2/GPSPI3 两个通用控制器（Octal 仅 SPI2），DMA 走 GDMA 共享池成对领通道；"GPIO matrix 限 40MHz"是经典 ESP32 的旧知识，S3 上 80MHz 内与 IOMUX 等效；非 DMA 缓冲会被驱动静默拷贝，性能坑不报错。
- **L4**：看波形先看结构（CS 包络、DC 翻转点、命令序），40MHz 时钟要降频采样；一帧 153,600 字节在 40MHz 下 30.72ms，理论 32.6fps 封顶，实测待真机。

下一章进入 BOX-3 的本体——I2S 与音频：同样走"控制器 + DMA + 回调"的路子，但数据从"一坨矩形像素"变成"一条永不停止的恒速流"，设计思路从搬运转向节奏。
