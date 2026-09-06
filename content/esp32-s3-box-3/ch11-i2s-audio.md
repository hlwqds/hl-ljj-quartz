---
title: "ESP32-S3-BOX-3 工程实战（十一）：I2S 与音频"
date: 2026-08-26 12:00:00
description: "从双 mic 到扬声器的音频全链路：先讲清 I2S 协议本体（BCLK/WS/SD/MCLK、为什么多 mic 要 TDM），再四层下钻 i2s_channel 新 API → 驱动的 DMA 描述符环 → S3 双 I2S 控制器与 GDMA 共享 → 引脚波形；用 esp-box-3 BSP 与 factory_demo 真实源码反查板级音频事实，最后设计一条可被 WakeNet 接管的音频流水线并做录放实验。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（十一）：I2S 与音频

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch10-spi-display|第十章：SPI 与屏幕]]
> **第十一章：I2S 与音频**（当前章）
> 下一章：[[ch12-rmt-infrared|第十二章：RMT 与红外]]

音频是 BOX-3 的本体：这块板子存在的理由就是"听得见、说得出"。但它在所有外设里也是链路最长的一个——从麦克风振膜到扬声器纸盆，中间隔着两颗 codec、一条 I2S 总线、一组 DMA 描述符环、若干个任务和缓冲区。本章先俯瞰全链路，再讲 I2S 协议本体，然后按系列惯例走 L1→L4 四层下钻；所有板级事实（引脚、I2C 地址、采样率、增益）均从本地 `esp-box` 仓库与 factory_demo 的 `managed_components` 源码实地反查，驱动事实以 ESP-IDF v6.0.2 的 `components/esp_driver_i2s` 头文件与源码为准。

---

## 11.1 全链路框图：从振膜到纸盆

一句话版本：**控制面走 I2C，数据面走 I2S**。两颗 codec 芯片都不做"配置"，配置寄存器（音量、增益、格式）通过 I2C 慢速写入；真正的音频采样数据以恒定速率在 I2S 线上流动，由 DMA 搬运，CPU 只在缓冲区满/空时被叫醒。

```text
 采集方向（录音）
 ─────────────────────────────────────────────────────────────
 双麦克风 ──模拟──> ES7210 (ADC, 四通道) ──I2S/TDM──> ESP32-S3 I2S1.RX
                                                      │ DMA 描述符环（6×960B）
                                                      ▼
                                              内部 RAM 缓冲 ──> 应用任务
 播放方向（放音）
 ─────────────────────────────────────────────────────────────
 应用任务 ──> 内部 RAM 缓冲 ──> I2S1.TX ──I2S──> ES8311 (DAC)
                                                      │
                                              PA 功放（GPIO46 使能）
                                                      ▼
                                                    扬声器
 控制面（两条腿共用）
 ─────────────────────────────────────────────────────────────
 I2C1 (SCL=GPIO18, SDA=GPIO8) ──> ES7210 @0x80 / ES8311 @0x30
```

反查出来的板级事实清单（来源：factory_demo 的 `managed_components/espressif__esp-box-3/include/bsp/esp-box-3.h` 与 `esp-box-3_idf5.c`，实地读取）：

| 事实            | 值                                            | 出处                                     |
| --------------- | --------------------------------------------- | ---------------------------------------- |
| I2S 控制器      | **I2S1**（`CONFIG_BSP_I2S_NUM` 默认 1）       | `esp-box-3/Kconfig`                      |
| MCLK            | GPIO2                                         | `BSP_I2S_MCLK`                           |
| BCLK            | GPIO17                                        | `BSP_I2S_SCLK`                           |
| WS（LRCLK）     | GPIO45                                        | `BSP_I2S_LCLK`                           |
| DOUT（→ES8311） | GPIO15                                        | `BSP_I2S_DOUT`                           |
| DIN（←ES7210）  | GPIO16                                        | `BSP_I2S_DSIN`                           |
| 功放使能        | GPIO46                                        | `BSP_POWER_AMP_IO`                       |
| ES8311 I2C 地址 | 0x30（8-bit 写地址，7-bit 即 0x18）           | `ES8311_CODEC_DEFAULT_ADDR`              |
| ES7210 I2C 地址 | 0x80（8-bit 写地址，7-bit 即 0x40）           | `ES7210_CODEC_DEFAULT_ADDR`              |
| 默认采样格式    | 16 kHz / 16 bit / 2 ch（factory_demo 覆盖值） | `esp32_bsp_board.c` 的 `CODEC_DEFAULT_*` |

注意方向性：ES7210 只有 ADC（只发不收），挂在 DIN；ES8311 做 DAC（只收不发），挂在 DOUT。BCLK/WS/MCLK 由 S3 主发，两颗 codec 都做从机——所以三条时钟线只有一套，收发共用，这正是 11.5 节"一个控制器跑全双工"的硬件前提。

---

## 11.2 I2S 协议本体：三根线、两个声道、一个主时钟

### 1. 角色分工

| 信号           | 角色                                  | 频率关系                 |
| -------------- | ------------------------------------- | ------------------------ |
| BCLK           | 位时钟，每个沿对应数据线上 1 bit      | `fs × slot位宽 × slot数` |
| WS（LRCLK）    | 字选择，电平区分左/右声道             | 等于采样率 `fs`          |
| SD（DOUT/DIN） | 串行数据，MSB first                   | ——                       |
| MCLK           | 主时钟，喂给 codec 内部 ΔΣ 调制器/PLL | 通常 `256 × fs`          |

关键认知：WS 频率 = 采样率，**采样率不是"配置"出来的，是分频分出来的**——S3 的 I2S 从 PLL 时钟源分频出 MCLK，再从 MCLK 分出 BCLK，BCLK 里按帧结构切出 WS。

### 2. 左右声道与 WS 相位

标准 Philips I2S：WS 低电平 = 左声道，高电平 = 右声道；**数据 MSB 相对 WS 翻转沿延迟 1 个 BCLK**（这就是 `bit_shift = true` 字段的物理含义）。两个声道各占一个 slot（16/24/32 bit），一帧 = 2 slot。所以 16 bit 立体声时 BCLK = 32 × fs；若 slot 配成 32 bit，则 BCLK = 64 × fs——"BCLK 是 WS 的 64 倍"说的就是这种经典配置。BOX-3 默认 16 bit slot，BCLK = 32 × 16 kHz = 512 kHz。PCM-short 格式则不同：WS 只有 1 个 BCLK 宽的正脉冲（`ws_width = 1`），数据左对齐。

### 3. 为什么多 mic 要 TDM

立体声总线一帧只有 2 个 slot，**两个声道就是上限**。ES7210 是四通道 ADC，四个麦克风要同时采，只能把"一帧 = 2 slot"扩展成"一帧 = N slot"——TDM（时分复用）：WS 翻转一次划出一帧，帧内按 slot 顺序排 mic1、mic2、mic3、mic4。IDF 的 TDM 模式用 `slot_mask` 启用时隙（S3 最多 16 个），BCLK 相应变成 `fs × slot位宽 × slot数`。BOX-3 只焊了 2 个 mic，所以 factory_demo 走的是标准立体声；IDF 的 Korvo 例程（`i2s_es7210_tdm`）则是四 mic TDM 的现成参照。后文 11.4 会看到 esp_codec_dev 在标准总线上跑 4 声道的一个取巧做法。

### 4. MCLK 为什么要单独给

I2S 协议本身不需要 MCLK——BCLK 足以移位。但 codec 芯片内部的过采样 ADC/DAC、数字滤波器、去爆音时钟都需要一个远高于 BCLK 的稳定基准，这个基准就是 MCLK（典型 256 × fs = 4.096 MHz @16 kHz）。BSP 里 ES8311 的配置明写 `use_mclk = true`；如果 MCLK 引脚没配或没到 codec，I2S 波形再标准，喇叭也是无声的——这是音频翻车榜第一名（见 11.9）。

---

## 11.3 L1 应用层：i2s_channel API 与 BSP 封装

### 1. 新驱动的心智模型：先建通道，再定模式

v5/v6 的 I2S 驱动（`components/esp_driver_i2s/include/driver/i2s_common.h`）把旧版"一个 i2s_config_t 包打天下"拆成了三步：`i2s_new_channel()` 分配通道（此时还不知道协议细节）→ `i2s_channel_init_std_mode()/tdm/pdm()` 绑定通信模式 → `i2s_channel_enable()` 起流。

```c
/* v6 头文件原文的默认通道配置：I2S_CHANNEL_DEFAULT_CONFIG(i2s_num, role) */
.id = i2s_num, .role = role,
.dma_desc_num = 6,        /* DMA 描述符（缓冲）个数 */
.dma_frame_num = 240,     /* 每个缓冲的帧数 */
.auto_clear_after_cb = false, .auto_clear_before_cb = false,
.allow_pd = false, .intr_priority = 0,

i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_1, I2S_ROLE_MASTER);
i2s_new_channel(&chan_cfg, &tx_handle, &rx_handle);   /* 两个句柄都非 NULL = 全双工 */
i2s_std_config_t std_cfg = {
    .clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(16000),    /* mclk_multiple 默认 256 */
    .slot_cfg = I2S_STD_PHILIP_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,
                                                   I2S_SLOT_MODE_STEREO),
    .gpio_cfg = { .mclk = 2, .bclk = 17, .ws = 45,
                  .dout = 15, .din = 16, .invert_flags = {0} },
};
i2s_channel_init_std_mode(rx_handle, &std_cfg);
i2s_channel_enable(rx_handle);
/* 之后就是 i2s_channel_read()/i2s_channel_write()/i2s_channel_preload_data() */
```

读 API 全家：`i2s_channel_read/write(handle, buf, size, &bytes, timeout_ms)` 阻塞式搬运；`i2s_channel_preload_data()` 允许在 enable 之前预填 TX 缓冲，起流第一毫秒不会送出垃圾数据；事件回调 `i2s_event_callbacks_t` 有四个钩子——`on_recv`（RX 收满一缓冲）、`on_recv_q_ovf`（RX 队列溢出）、`on_sent`（TX 发完一缓冲）、`on_send_q_ovf`，全部运行在 ISR 环境。头文件还留了一句要背下来的话：全双工模式下"TX/RX 只共享时钟，不保证读写同步"。

### 2. BSP 把这条路封装成了三行

BOX-3 不需要自己写上面任何一段。`bsp_audio_init(NULL)` 用默认配置（标准 Philips、16 bit、mono、22050 Hz）建好 I2S1 全双工通道；`bsp_audio_codec_speaker_init()` / `bsp_audio_codec_microphone_init()` 分别把 ES8311/ES7210 经 I2C 配置成 codec 设备。esp-box 仓库的 `components/bsp` 再包一层产品级 API（`esp32_bsp_board.c` 实地读取）：

```c
#define CODEC_DEFAULT_SAMPLE_RATE   (16000)
#define CODEC_DEFAULT_BIT_WIDTH     (16)
#define CODEC_DEFAULT_CHANNEL       (2)
#define CODEC_DEFAULT_ADC_VOLUME    (24.0)   /* dB */

bsp_i2s_read(buf, len, &bytes_read, timeout_ms);   /* 内部 esp_codec_dev_read()  */
bsp_i2s_write(buf, len, &bytes_written, timeout);  /* 内部 esp_codec_dev_write() */
bsp_codec_set_fs(16000, 16, I2S_SLOT_MODE_STEREO); /* 换采样率：关→配→开两设备  */
bsp_codec_volume_set(70, NULL);  bsp_codec_mute_set(false);
```

三个值得抄走的细节：其一，`bsp_codec_set_fs()` 换格式时先 `esp_codec_dev_close()` 两个设备再重开——采样率是 I2S 分频器和 codec 内部分频器**两边都要改**的事；其二，录音增益在每次 set_fs 后重设为 24 dB（ES7210 的增益档位是 0~37.5 dB 的阶梯，30 dB 是 codec 驱动 open 时的默认值）；其三，`bsp_i2s_read` 的 `timeout_ms` 参数实际被忽略——它内部调用的 `esp_codec_dev_read` 是无限期阻塞的，别指望靠它做超时控制。

---

## 11.4 L2 组件源码：DMA 描述符环 + 控制面/数据面分离

### 1. `i2s_channel_read` 的真身：一次队列接收 + 一次 memcpy

驱动源码（`esp_driver_i2s/i2s_common.c`，v6.0.2 实地读取）把"读音频"实现为三件套：**环形描述符 + FreeRTOS 队列 + 二值信号量**。

`i2s_alloc_dma_desc()` 分配 `dma_desc_num` 条 `lldesc_t` 描述符（注释原文："Descriptors must be in the internal RAM"），每条挂一块 DMA 缓冲（S3 带缓存，单块上限 `DMA_DESCRIPTOR_BUFFER_MAX_SIZE_64B_ALIGNED` = 4032 字节），然后首尾相接连成环：

```c
/* 源码节选（i2s_common.c:544-547）：连接成环 */
for (int i = 0; i < num; i++) {
    STAILQ_NEXT(handle->dma.desc[i], qe) =
        (i < (num - 1)) ? (handle->dma.desc[i + 1]) : handle->dma.desc[0];
}
```

运行时链路是：GDMA 沿描述符环搬运，每填满一块就触发 EOF 中断 → `i2s_dma_rx_callback` 把**这块缓冲的指针**压进 `msg_queue`（深度 = desc_num - 1，即 5）；队列满则丢最旧的一块并回调 `on_recv_q_ovf`——这就是"缓冲不足爆音"的代码级出处。任务侧的 `i2s_channel_read()` 先拿二值信号量（保证同一通道同时只有一个读者），再循环 `xQueueReceive(msg_queue)` 取缓冲指针、`memcpy` 到用户 buffer。换句话说，**i2s_channel_read 的本质是 FreeRTOS 队列消费 + 一次内存拷贝**，队列语义细节正好回看 [[ch10-queue-universal-ipc|FreeRTOS 深度解析（十）：队列]]。

按 BOX-3 默认参数算一笔账：6 描述符 × 240 帧 × 4 字节/帧（16 bit × 2 ch）= 5760 字节 ≈ 90 ms @ 64 kB/s。从 DMA 填满第一块到缓冲全满，应用任务只有约 90 ms 的迟到余量。

### 2. esp_codec_dev：控制面与数据面的接口分离

`esp_codec_dev` 组件（factory_demo 用 1.1.0，注册表最新已到 1.6.2）把 11.1 的"两条腿"直接建模成两个接口，官方文档原话："The control interface mainly offers `read_reg` and `write_reg` APIs to do codec setup"，数据接口则提供 `read/write` 交换音频数据。装配关系：

```text
audio_codec_ctrl_if_t  <--audio_codec_new_i2c_ctrl()   I2C 写寄存器（慢速、命令式）
audio_codec_data_if_t  <--audio_codec_new_i2s_data()   I2S 通道句柄（恒速、流式）
        │                      │
   es8311_codec_new() / es7210_codec_new()   ← 芯片驱动，吃 ctrl_if（+gpio_if 管 PA）
        │                      │
        └──> esp_codec_dev_cfg_t {codec_if, data_if, dev_type} ──> esp_codec_dev_new()
                            ──> esp_codec_dev_open/read/write/set_in_gain/set_out_vol
```

这个分层的妙处：换一颗 codec 只换中间那层，I2C 控制与 I2S 数据通路原封不动；反过来换数据通路（比如改成 USB）也碰不到 codec 逻辑。BOX-3 的两个实例都是极简配置——ES8311 侧传了 `pa_pin = GPIO46`（功放使能交给 codec 驱动管理，配合 `hw_gain = {pa_voltage: 5.0, codec_dac_voltage: 3.3}` 做响度保护）；ES7210 侧只传了 `ctrl_if`，于是驱动走默认值：`mic_selected = 0 → MIC1 | MIC2`（恰好是板上的双 mic）、开嗓默认增益 30 dB、从机模式。

一个源码级彩蛋：ES7210 驱动里有 `es7210_is_tdm_mode()`——选中的 mic 数 ≥ 3 就自动切 TDM 寄存器模式，并在 `set_fs` 里把 4 通道 16 bit 打包进 2 个 32 bit slot（"Use 2 channel to fetch TDM data"）。也就是说**标准立体声总线也能跑 4 mic**，靠的是加宽 slot 再软件拆包——TDM 不是唯一解，但 slot 不加宽就一定是 2 声道上限。

---

## 11.5 L3 寄存器层：S3 有几个 I2S，全双工归谁

对照 `soc_caps.h` 与官方文档（`docs/zh_CN/api-reference/peripherals/i2s.rst`，实地读取）：

| 能力          | ESP32-S3 事实                                                |
| ------------- | ------------------------------------------------------------ |
| 控制器数量    | 2 个（I2S0、I2S1），均为硬件版本 2（`SOC_I2S_HW_VERSION_2`） |
| 标准/TDM 模式 | I2S0 与 I2S1 都支持                                          |
| PDM           | 原始 PDM 两口都收发；PCM↔PDM 格式转换器**仅在 I2S0**         |
| 内置 ADC/DAC  | 无（经典 ESP32 才有，I2S0 直连）                             |
| 全双工        | **两个控制器都行**，且 RX/TX 时钟互相独立                    |

"谁支持全双工"在两代硬件上答案不同，这是老教程的高发污染源：硬件版本 1（经典 ESP32/S2）RX 与 TX **共用一套时钟**，全双工必须两侧同配置、同启停；硬件版本 2（S3）每个控制器有独立的 RX、TX 通道，"能够在不同的时钟和声道配置下工作"——文档同时补了一句限制：**一个控制器的 MCLK 输出只能绑到其中一个通道**，要两路独立 MCLK 必须分到两个控制器。BOX-3 全双工跑在 I2S1 上，收发共享 BCLK/WS/MCLK 三线，正是"独立但共用引脚配置"的实例。

DMA 这层的共享更隐蔽：S3 的 I2S 没有私有 DMA，驱动在 `i2s_common.c` 里为每个通道调 `gdma_new_ahb_channel()` 从芯片级 AHB-GDMA 通道池里领一条，再用 `GDMA_MAKE_TRIGGER(GDMA_TRIG_PERIPH_I2S, 1)` 把它挂到 I2S1 的外设请求线上。所以 BOX-3 的音频一发一收**占用两条 GDMA 通道**，与 SPI、ADC、AES 等外设共吃同一个池子——DMA 通道是整机共享资源，外设堆多了会在 `gdma_new_channel` 处失败，报错却常常落在最后注册的那个外设头上。

---

## 11.6 L4 物理层：引脚上应该看到什么

把 11.2 的公式代入 BOX-3 默认配置（16 kHz / 16 bit / 2 slot / MCLK 256×），四根线上的预期波形：

| 信号          | 频率      | 周期关系                                        |
| ------------- | --------- | ----------------------------------------------- |
| MCLK (GPIO2)  | 4.096 MHz | 256 × fs                                        |
| BCLK (GPIO17) | 512 kHz   | 32 × fs，每 32 个沿一个声道字                   |
| WS (GPIO45)   | 16 kHz    | 高低电平各 16 个 BCLK：低=左(mic1)，高=右(mic2) |
| DIN (GPIO16)  | ——        | Philips 格式：MSB 落后 WS 翻转沿 1 个 BCLK      |

示波器/逻辑分析仪上的自查清单：WS 与 BCLK 严格同源（用分析仪的频率测量，WS 应精确 16 kHz）；DIN 的 MSB 出现在 WS 翻转沿之后 1 个 BCLK 处（Philips 延迟）；静止环境下 DIN 接近全零、对着 mic 说话时出现成串非零数据；MCLK 必须一直在跳（哪怕不录音——功放使能与否不影响它）。

> [!warning] 待真机验证
> 以上波形参数由配置推算得出，尚未用逻辑分析仪实测核对。到货后计划：8 通道分析仪抓 GPIO2/17/45/16 四线，PulseView 解码 I2S，对照本表逐项打勾，并补一张实测截图。

---

## 11.7 音频流水线：本系列的"核心图"

I2S 章真正的工程产出不是"能收音频"，而是**一条有节奏的生产线**。factory_demo 给出了官方答案（`app_sr.c` 实地读取），任务布局如下：

```text
                      ┌────────────────────────────────────────────┐
 I2S1.RX (DMA 环 90ms)│  Feed Task      prio 5  core 0  stack 4K   │
 ───> msg_queue ───> │  bsp_i2s_read() 双声道 → 拆插成 3 声道       │
                      │  （mic1 + mic2 + 置零的参考声道）→ AFE.feed  │
                      └──────────────┬─────────────────────────────┘
                                     │ AFE 内部环形缓冲
                      ┌──────────────▼─────────────────────────────┐
                      │  Detect Task    prio 5  core 1  stack 8K   │
                      │  AFE.fetch() → WakeNet 唤醒 → MultiNet 命令 │
                      └──────────────┬─────────────────────────────┘
                                     │ result_que（深度 3 的队列）
                      ┌──────────────▼─────────────────────────────┐
                      │  SR Handler    最高优先级  core 0  stack 6K │
                      │  命令 → 事件/LVGL 反馈 → 触发提示音播放       │
                      └──────────────┬─────────────────────────────┘
                                     │ bsp_i2s_write()
 I2S1.TX <── Audio Player (prio 5) <─┘   ← MP3/WAV 解码后的 PCM
```

三个设计决策值得抄作业：

1. **采集任务绑核钉优先级，跟随 DMA 的节拍**。Feed 任务用 `portMAX_DELAY` 阻塞在 `bsp_i2s_read` 上，醒来即拷贝、即喂算法。它的死线不是软的——DMA 环 90 ms 后溢出，`on_recv_q_ovf` 丢最旧缓冲，音频出现跳变。所以它必须比任何"可延迟"任务优先级高，且不能与重负载任务同核抢CPU。
2. **算法任务独占一个核**。Detect（WakeNet+MultiNet 推理）是 CPU 密集型，钉在 core 1；LVGL 渲染也钉在 core 1 但靠时间片轮转共存，WiFi 协议栈在 core 0。双核分工是 BOX-3 这类"显示+语音"设备的生存技能（对照 [[ch1-from-bare-metal-to-rtos|FreeRTOS（一）]]的 SMP 伏笔）。
3. **结果用小队列、音频用大缓冲**。识别结果是低频离散事件，深度 3 的队列足够；音频流是恒速字节流，靠驱动内部的 DMA 环 + AFE 缓冲两级吸收抖动。若自己搭流水线，字节流通常更适合 [[ch14-stream-message-buffers|FreeRTOS 深度解析（十四）：流缓冲]]——单读单写免锁，正是"采集→算法"这种两点专线的美学。

背压（backpressure）策略在这条流水线上表现为"谁迟到谁挨打"：算法任务消费慢 → AFE 缓冲涨 → feed 阻塞 → DMA 环溢出丢数据（可听见的爆音，且 WakeNet 漏检）；播放任务消费慢 → `bsp_i2s_write` 阻塞 → 解码任务被反压。factory_demo 还有个防自唤醒细节：`sr_echo_is_playing()` 为真时暂停命令词识别——喇叭正在播"好的"，别让它自己唤醒自己。第十八章 WakeNet 上板时，接的就是 Feed/Detect 之间这个位置。

---

## 11.8 实验：录 2 秒存 WAV，再回放

目标：验证 11.1 全链路的两个方向。2 s 的 16 kHz/16 bit/双声道 PCM = 128,000 字节，存 SD 卡（BOX-3 的 DOCK 板 SDMMC 卡槽，`bsp_sdcard_mount()` 挂到 `/sdcard`）。代码骨架——直接复用 BSP，不碰寄存器层：

```c
#include "bsp/esp-bsp.h"
#include "bsp_board.h"
#include "driver/i2s_std.h"

#define FS      (16000)
#define SECS    (2)
#define CHUNK   (4096)   /* 每次 64ms 的读取粒度 */

/* 44 字节标准 WAV 头（与 factory_demo app_sr_handler.c 同构） */
typedef struct { /* RIFF/fmt/data 三个 chunk，字段省略，见 sr_echo_play() */ } wav_hdr_t;

void app_main(void)
{
    bsp_sdcard_mount();
    bsp_board_init();   /* 内部完成: speaker_init + microphone_init + set_fs(16000,16,2) */

    /* 1. 录音：先写占位头，收满后回填长度 */
    FILE *f = fopen("/sdcard/rec.wav", "w");
    wav_hdr_t hdr = make_wav_hdr(FS, 16, 2, FS * 2 * 2 * SECS);
    fwrite(&hdr, sizeof(hdr), 1, f);
    static int16_t buf[CHUNK / 2];
    for (int left = FS * 2 * 2 * SECS; left > 0; ) {
        size_t n = MIN(CHUNK, left);
        bsp_i2s_read(buf, n, &n, portMAX_DELAY);   /* L=mic1, R=mic2 交错 */
        fwrite(buf, 1, n, f);
        left -= n;
    }
    fclose(f);

    /* 2. 回放：按文件头设采样率，从 data 偏移处直写 */
    f = fopen("/sdcard/rec.wav", "r");
    fread(&hdr, sizeof(hdr), 1, f);
    bsp_codec_set_fs(hdr.SampleRate, hdr.BitsPerSample, I2S_SLOT_MODE_STEREO);
    bsp_codec_mute_set(true); bsp_codec_mute_set(false);   /* 去爆音的静音-解除套路 */
    while (fread(buf, 1, CHUNK, f) > 0) {
        bsp_i2s_write(buf, CHUNK, &n, portMAX_DELAY);
    }
    fclose(f);
}
```

> [!warning] 待真机验证
> 本实验尚未上板执行。预期现象：录音期间对 mic 说话；回放听到自己的声音，左右声道分别对应两个 mic（捂住一个 mic 再录一次可对比）。SD 卡未插时 `bsp_sdcard_mount()` 会失败，应加重试或降级为 SPIFFS。两处待核对的坑：`bsp_i2s_write` 的回放粒度若小于一个 DMA 缓冲（960 B）是否引发咔哒声；回放结束后的尾音处理（factory_demo 播完会 `vTaskDelay(20ms)` 再关流）。

---

## 11.9 翻车点表与小结

| 症状                        | 根因                                                                                                            | 处理                                                                                                          |
| --------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 波形全对但喇叭无声          | MCLK 没到 codec（引脚配错/未配）或 PA 未使能（GPIO46）                                                          | MCLK 是 codec 内部时钟基准，`use_mclk=true` 时必查 GPIO2；PA 由 es8311 驱动经 `pa_pin` 管理，自建初始化时别漏 |
| 录音周期性"咔哒"/跳变       | 应用消费太慢，DMA 环溢出，`on_recv_q_ovf` 丢最旧缓冲                                                            | 加大 `dma_desc_num/dma_frame_num`、提高采集任务优先级、或把消费端拆到另一核                                   |
| 放音变速/变调/噪声          | 只改了 I2S 采样率没改 codec（或反之），两侧分频失配                                                             | 一律走 `bsp_codec_set_fs()` 一类的成对接口，别单独调 `i2s_channel_set_*`                                      |
| 多 mic 声道错乱             | TDM `slot_mask`/`total_slot` 与 codec 侧时隙序不一致                                                            | 先静态对齐两侧时隙表，再用固定内容逐 slot 打脉冲定位（真机验证手段）                                          |
| I2C 探测不到 codec          | esp_codec_dev 的地址宏是 8-bit 写地址（ES8311 0x30、ES7210 0x80），v6 新 `i2c_master` API 用 7-bit（0x18/0x40） | 统一口径：新 API 场景把宏右移一位，或沿用旧驱动语义                                                           |
| 录音削顶失真                | ES7210 增益档过高（默认 open 即 30 dB）                                                                         | `esp_codec_dev_set_in_gain()` 降到 12~24 dB 再试                                                              |
| `gdma_new_ahb_channel` 失败 | GDMA 通道池被 SPI/ADC 等占满                                                                                    | 排查整机 DMA 占用，砍掉不用的 DMA 外设或复用通道                                                              |
| 全双工收不到数              | 照抄经典 ESP32 教程把 RX/TX 配成不同参数（一代芯片共享时钟的约束）                                              | S3 上两通道时钟独立，但确认是**同一次** `i2s_new_channel()` 建出的全双工对，且 MCLK 只绑一侧                  |

本章小结：

- **音频链路 = I2C 控制面 + I2S 数据面**。ES7210（双 mic，@0x80）从 GPIO16 进，ES8311（DAC，@0x30）从 GPIO15 出，时钟 MCLK2/BCLK17/WS45 全由 S3 的 **I2S1** 主发，功放使能在 GPIO46——这些全部从 BSP 源码反查，不用背。
- **I2S 协议的本体是"WS 分帧、BCLK 定节拍"**：WS=采样率，BCLK=fs×slot宽×slot数，Philips 格式 MSB 迟到 1 拍；多 mic 要么 TDM 扩 slot，要么像 esp_codec_dev 那样加宽 slot 软件拆包；MCLK 是 codec 的命根子。
- **L2 的两个真相**：`i2s_channel_read` = 队列收指针 + memcpy（驱动内部就是 FreeRTOS 队列的教科书用例）；esp_codec_dev 用 ctrl_if/data_if 两个接口把"配置"与"流"彻底解耦。
- **S3 两个 I2S 都是硬件 v2**，全双工无需同配置（一代芯片才要），但一个控制器只有一路 MCLK 输出；DMA 通道来自芯片级共享池。
- **流水线设计三句话**：采集任务跟 DMA 节拍走、算法独占一核、事件走小队列音频走大缓冲——第十八章的 WakeNet 就插在这条线的中间。

下一章换个短促信号的外设：RMT 与红外——用硬件收发精确到微秒的波形，正好和本章"DMA 搬恒速流"形成两种外设哲学的对照。
