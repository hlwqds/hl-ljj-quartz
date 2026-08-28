---
title: "ESP32-S3-BOX-3 工程实战（十八）：ESP-SR 语音唤醒"
date: 2026-08-26 12:00:00
description: "离线语音识别的官方答案：ESP-SR 三层流水线（AFE 前处理 → WakeNet 唤醒 → MultiNet 命令词）逐层拆解，再实地走读 factory_demo 的模型加载（model 分区 mmap）、Feed/Detect/Handler 三任务与唤醒反馈链路；重点分析推理任务与 WiFi 的双核共存、模型内存布局与 32ms 帧周期的实时预算。"
tags: [esp32, esp32-s3, esp-idf, series, ai]
---

# ESP32-S3-BOX-3 工程实战（十八）：ESP-SR 语音唤醒

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[2026-08-26-esp32-s3-box-3-hands-on-series-index|系列索引]]
> 上一章：[[2026-08-26-esp32-s3-box-3-ch17-rainmaker-matter|第十七章：生态一瞥]]
> **第十八章：ESP-SR 语音唤醒**（当前章）
> 下一章：[[2026-08-26-esp32-s3-box-3-ch19-esp-dl-deployment|第十九章：ESP-DL 模型部署]]

BOX-3 之所以是一块「AI 开发板」，本体就是本章的对象：**不联网、不上云，说「Hi 乐鑫」就能唤醒，说「打开空调」就能识别命令**。这套离线语音栈的官方名字叫 ESP-SR。本章先把它当黑盒拆成三层流水线，讲清每层的输入输出与算法职责；然后走进 factory_demo 的真实代码——模型从哪个分区加载、三个任务怎么分工、唤醒之后发生了什么；最后回答工程上最要命的两个问题：推理任务怎么和 WiFi 在两个核上共存，模型和运行时内存放在哪。所有组件源码均从本地 `managed_components/espressif__esp-sr/`（依赖清单 `1.4.*`，`dependencies.lock` 实际解析为 **1.4.2**）与 factory_demo 的 `main/` 实地读取，性能数字取自官方 benchmark 文档并注明出处。

---

## 18.1 ESP-SR 全家福：一条三级流水线

先报户口。ESP-SR 是一个注册表组件（[[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章]] 讲过的 `managed_components` 来源），factory_demo 的清单写 `espressif/esp-sr: 1.4.*`，锁定 1.4.2；它自己还私有依赖 `espressif/esp-dsp ^1.2.1` 与 `idf >=4.4`（`dependencies.lock:212-230`）。算法本体是六个预编译静态库（`lib/esp32s3/` 下 `libwakenet.a`、`libmultinet.a`、`libesp_audio_front_end.a`、`libesp_audio_processor.a` 等），开源可见的只有胶水层：模型加载（`src/model_path.c`）、命令表管理（`esp_mn_speech_commands.c`）和 Kconfig。

三层流水线一张图（通道/采样率均从组件头文件核实）：

```text
 I2S 双 mic (16 kHz / 16 bit / 2ch 交错, 第十一章的 DMA 环)
        │  Feed 任务：展开为 3 声道（mic1 + mic2 + 置零的参考声道）
        ▼
 ┌────────────────────────────────────────────────────┐
 │ 第一层 AFE（Audio Front-End，libesp_audio_front_end）│
 │  AEC 回声消除 / NS 降噪 / VAD 语音活动检测          │
 │  / MASE 双 mic 阵列增强（BSS）                       │
 │  输入: 3ch s16@16k 交错 → 输出: 单声道增强音频        │
 ├────────────────────────────────────────────────────┤
 │ 第二层 WakeNet9（唤醒词, libwakenet）                │
 │  常开滑窗推理:「Hi 乐鑫」「Hi ESP」…                  │
 │  输出: wakenet_state_t（DETECTED / CHANNEL_VERIFIED）│
 ├────────────────────────────────────────────────────┤
 │ 第三层 MultiNet6（命令词, libmultinet, 仅唤醒后运行） │
 │  输出: command_id + 概率 top-5, 5.76 s 超时窗口      │
 └────────────────────────────────────────────────────┘
        │  result_que（深度 3 的 FreeRTOS 队列）
        ▼
 Handler 任务: 提示音播放 + LVGL 反馈 + 业务动作
```

每层的精确输入输出契约（出处：`include/esp32s3/esp_afe_sr_iface.h`、`esp_wn_iface.h`、`esp_mn_iface.h`）：

| 层                    | 输入                                     | 输出                                                                        | 帧长/单位                                       |
| --------------------- | ---------------------------------------- | --------------------------------------------------------------------------- | ----------------------------------------------- |
| `afe_handle->feed()`  | 声道交错的 s16 @16 kHz，末声道为参考信号 | 进 AFE 内部环形缓冲                                                         | `get_feed_chunksize()` 查询，单位 16-bit 样本   |
| `afe_handle->fetch()` | （内部消费）                             | `afe_fetch_result_t`：**单声道**增强音频 + 唤醒状态 + VAD 状态 + 触发通道号 | `get_fetch_chunksize()` 查询                    |
| `wakenet->detect()`   | 增强后音频帧                             | `WAKENET_NO_DETECT / WAKENET_DETECTED / WAKENET_CHANNEL_VERIFIED`           | 同 fetch 帧                                     |
| `multinet->detect()`  | 同一帧增强音频                           | `ESP_MN_STATE_DETECTING / DETECTED / TIMEOUT`                               | 同 fetch 帧，超时窗口由 `create(name, ms)` 指定 |

官方 benchmark 页标注 WakeNet/MultiNet 的处理帧长为 **32 ms**（16 kHz 下即 512 样本/帧）——这就是整条流水线的「节拍」，18.5 节的实时性预算全围绕它展开。

BOX-3 的 AFE 默认配置不需要自己写，`AFE_CONFIG_DEFAULT()` 的 S3 分支（`esp_afe_config.h:108-133` 实地摘录）已经按「2 mic + 1 参考」配好：

```c
#define AFE_CONFIG_DEFAULT() { \
    .aec_init = true, .se_init = true, .vad_init = true, .wakenet_init = true, \
    .vad_mode = VAD_MODE_3, \
    .wakenet_mode = DET_MODE_2CH_90, \        /* 双通道判决，普通灵敏度 */
    .afe_mode = SR_MODE_LOW_COST, \           /* 低成本模式（省内存） */
    .afe_perferred_core = 0, .afe_perferred_priority = 5, \
    .afe_ringbuf_size = 50, \
    .memory_alloc_mode = AFE_MEMORY_ALLOC_MORE_PSRAM, \  /* 工作集尽量放 PSRAM */
    .pcm_config.total_ch_num = 3, .pcm_config.mic_num = 2, \
    .pcm_config.ref_num = 1, .pcm_config.sample_rate = 16000, \
    ...
}
```

四个值得注意的默认值：`DET_MODE_2CH_90` 表示唤醒判决跑在双 mic 通道上（`det_mode_t` 枚举里有 90/95 两档，95 更激进、误唤醒率也更高——头文件注释原话）；`SR_MODE_LOW_COST` 与 `HIGH_PERF` 是内存/算力的两档取舍；`AFE_MEMORY_ALLOC_MORE_PSRAM` 说明 AFE 工作集大头在 PSRAM；`total_ch_num = 3` 正好对应 18.4 节 Feed 任务里那个「2 声道拆插成 3 声道」的循环。

---

## 18.2 WakeNet：常开、离线、滑窗触发

### 1. 为什么它能常开还离线

三个条件叠加。**第一，模型在 Flash 不在内存**：唤醒词模型烧在 `model` 分区，运行时整区 mmap 进地址空间（18.4 节看代码），不拷贝、不占 app 体积。**第二，量化后足够小**：官方 benchmark（docs.espressif.com esp-sr Benchmark 页，esp32s3）给出一组对比——量化版 WakeNet9 双通道 RAM 16 KB / PSRAM 324 KB / 每帧 3.0 ms，三通道 20 KB / 347 KB / 4.3 ms；而上一代 WakeNet8 双通道要 50 KB RAM / 1640 KB PSRAM / 每帧 10.0 ms。WN9 一代把 PSRAM 占用砍到五分之一、耗时砍到三成，「常开」才真正划算。**第三，负载是间歇的**：每 32 ms 一帧只花 3~4.3 ms，空闲帧 CPU 可以降频（factory_demo 开了 DFS 240↔40 MHz，[[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章]] sdkconfig 表）。

### 2. 滑窗推理与触发平滑

WakeNet9 的结构（官方文档）：膨胀卷积（Dilated Convolution）+ MFCC 特征，输入 16 kHz 单声道 s16。关键工程细节在触发端——单帧概率噪声很大，官方文档描述为：对连续若干帧的识别结果取平均得到平滑值 M，**只有 M 超过设定阈值才触发唤醒**。阈值不合适时的调节口在接口层：`set_det_threshold(model, det_threshold, word_index)`，范围 0.5~0.9999（`esp_wn_iface.h:105-112`）；`DET_MODE_90/95` 则是官方预置的两档「灵敏度/误报」权衡。

### 3. 多唤醒词：MULTI 配置的真相

factory_demo 的 `sdkconfig.defaults:10-12` 打开了：

```text
CONFIG_SR_WN_LOAD_MULIT_WORD=y      # 注意：上游配置名就把 MULTI 拼成了 MULIT
CONFIG_SR_WN_WN9_HILEXIN_MULTI=y    # 中文「Hi 乐鑫」
CONFIG_SR_WN_WN9_HIESP_MULTI=y      # 英文「Hi ESP」
```

（`MULIT` 这个拼写错误直接抄自上游 `Kconfig.projbuild:92`，自己写配置时千万别「顺手纠正」，否则不生效。）它的作用是**把两个唤醒词模型都打进 model 分区**——组件 `model/wakenet_model/` 目录下实拍可见 wn9_hilexin、wn9_hiesp、wn9_alexa、wn9_xiaoaitongxue、wn9_nihaoxiaozhi、wn9_customword 等，构建脚本按 sdkconfig 勾选搬运（18.4 节）。运行时才决定用哪个：`afe_config.wakenet_model_name` 填第一个，`wakenet_model_name_2` 是第二个——CHANGELOG 1.4.0 起 AFE 支持两个 wn9 模型**同时在线**，fetch 结果的 `wakenet_model_index` 字段告诉你被哪个模型唤醒。factory_demo 没走双在线这条路：它按语言切换（`app_sr_set_language()` 里 EN→`hiesp`、CN→`hilexin`，`app_sr.c:291-294`），同一时刻只激活一个，省一半推理开销。多模型的代价参见上表：每个 wn9 模型另有约 300+ KB PSRAM 级别的运行时开销。

---

## 18.3 MultiNet：命令词的两种模式与量化

MultiNet 解决「唤醒之后说什么」。它不是把命令训练进模型，而是一个**通用声学模型 + 可更换的命令表**——改命令不用重训。命令表有两条接入路径，分水岭正好是模型代次：

| 路径           | 适用模型                     | 命令定义处                                                                                                              | 更新方式     |
| -------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------ |
| Kconfig 固定表 | mn2/mn4/mn5（S3 上 mn4/mn5） | `Kconfig.projbuild` 的 `Add Chinese/English speech commands` 菜单，`CONFIG_CN_SPEECH_COMMAND_ID0~199` 一行一条          | 重新编译     |
| 运行时 API     | mn6/mn7（`*_QUANT` 量化版）  | 代码里 `esp_mn_commands_add(id, str)` / `modify` / `remove` / `clear`，改完必须 `esp_mn_commands_update()` 重建语言模型 | 运行中热更新 |

factory_demo 用的是 mn6（`CONFIG_SR_MN_CN_MULTINET6_QUANT` + `EN_MULTINET6_QUANT`），所以走 API 路径。它的命令表定义在 `main/app/app_sr.c:73-115` 的 `g_default_cmd_info[]`，中文条目直接写拼音（grapheme 输入），英文条目写原句：

```c
{SR_CMD_LIGHT_ON,  SR_LANG_CN, 0, "打开电灯", "da kai dian deng", {NULL}},
{SR_CMD_LIGHT_ON,  SR_LANG_EN, 0, "Turn On the Light", "TkN nN jc LiT", {NULL}},
```

注册时按模型分流（`app_sr.c:478-482`）：`mn6_en` 直接吃英文原句（MultiNet6 起接口接受 grapheme 输入，官方文档口径），其他模型吃音素串——所以表里那串「TkN nN jc LiT」是 mn5 时代的英文音素，mn6_en 下真正生效的是 `str` 字段。容量上限组件头文件写 `ESP_MN_MAX_PHRASE_NUM 400`（`esp_mn_iface.h:6`），官方文档说「up to 200」——按本地 1.4.2 版头文件为准，文档口径疑为旧值，**待核对**。

量化的意义回到那张 benchmark 表：MultiNet6 量化版内部 RAM 32 KB / PSRAM 4100 KB / 每帧 12 ms——PSRAM 大头就是它，这也是 BOX-3 必须上 8 MB Octal PSRAM 的直接原因。内存还想再省，接口留了三档 `esp_mn_loader_mode_t`（`esp_mn_iface.h:23-27`）：权重全载 PSRAM（最快最费内存）/ PSRAM+Flash 混载（默认）/ 尽量从 Flash 读（最省最慢），可用 `switch_loader_mode()` 运行时切换。

识别输出是 top-5 候选（`esp_mn_results_t` 的 `command_id[]/phrase_id[]/prob[]`，`num<=5`）。`create(model_name, 5760)` 的第二个参数是超时窗口毫秒数——factory_demo 给 5760 ms，超时返回 `ESP_MN_STATE_TIMEOUT`，这就是第二十章状态机里「5.76 s 超时回待命」的出处。

---

## 18.4 factory_demo 实地走读

### 1. 模型从哪来、到哪去：构建期与运行期两条链

**构建期**（组件 `CMakeLists.txt:97-119` + `model/movemodel.py`，实地读取）：每次构建先跑 `movemodel.py`——解析工程 sdkconfig 里的 `CONFIG_SR_WN_*`/`CONFIG_SR_MN_*`，把选中模型的目录从组件 `model/` 拷到 `build/srmodels/`，再用 `pack_model.py` 打成单个 `srmodels.bin`（头部是模型数 + 每模型文件索引表，正文是数据），并打印 `Recommended model partition size: %dK` 提示分区该多大。然后 `esptool_py_flash_to_partition(flash "model" ...)` 把它挂进 `idf.py flash`——**用 `idf.py flash` 会自动烧 model 分区；用 esptool 手动只烧 app.bin 就会漏**（翻车点表第一条）。

**运行期**（`app_sr.c:359` + 组件 `src/model_path.c:486-511`）：

```c
models = esp_srmodel_init("model");
```

S3 上这一行的真实路径是：`esp_partition_find_first(DATA, ANY, "model")` 找分区 → `srmodel_mmap_init()` 调 `esp_partition_mmap` 把**整个分区**映射进 data mmap 区 → 解析头部索引表得到每个模型每个文件的指针。注意两个细节：其一，分区表里 model 的 subtype 虽写着 `spiffs`，S3 上实际**并不挂 SPIFFS 文件系统**，是裸 mmap 直读；其二，mmap 消耗的是地址空间页表而非 RAM，代码里有 `spi_flash_mmap_get_free_pages()` 检查并在不足时打 `ESP_LOGE`（CHANGELOG 已知问题：IDF v5.0 上可用页偏少，建议 v5.1+——factory_demo 恰好要求 idf>=5.1）。

### 2. AFE 装配与三任务创建（`app_sr_start()`，`app_sr.c:324-388`）

```c
models = esp_srmodel_init("model");
afe_handle = (esp_afe_sr_iface_t *)&ESP_AFE_SR_HANDLE;
afe_config_t afe_config = AFE_CONFIG_DEFAULT();
afe_config.wakenet_model_name = esp_srmodel_filter(models, ESP_WN_PREFIX, NULL);  /* 分区里第一个 WN 模型 */
afe_config.aec_init = false;                    /* 显式关 AEC */
esp_afe_sr_data_t *afe_data = afe_handle->create_from_config(&afe_config);
...
ret_val = xTaskCreatePinnedToCore(&audio_feed_task,    "Feed Task",        4 * 1024, afe_data, 5, &g_sr_data->feed_task, 0);
ret_val = xTaskCreatePinnedToCore(&audio_detect_task,  "Detect Task",      8 * 1024, afe_data, 5, &g_sr_data->detect_task, 1);
ret_val = xTaskCreatePinnedToCore(&sr_handler_task,    "SR Handler Task",  6 * 1024, NULL, configMAX_PRIORITIES - 1, &g_sr_data->handle_task, 0);
```

`aec_init = false` 是 BOX-3 的现实选择：参考声道没有接回采信号（Feed 任务把它置零），AEC 无米下锅。三任务的分工（参数已由 [[2026-08-26-esp32-s3-box-3-ch11-i2s-audio|第十一章]] 从同源代码核实，此处只引用不重讲）：**Feed**（4 KB / prio 5 / Core 0）跟 DMA 节拍喂 AFE；**Detect**（8 KB / prio 5 / Core 1）独占一个核跑全部推理；**Handler**（6 KB / **最高优先级** / Core 0）消费结果并驱动反馈。结果队列 `xQueueCreate(3, sizeof(sr_result_t))`——深度 3 的小事件队列。

### 3. Feed 任务：2 声道拆插成 3 声道（`app_sr.c:117-170`）

```c
int audio_chunksize = afe_handle->get_feed_chunksize(afe_data);
int feed_channel = 3;
int16_t *audio_buffer = heap_caps_malloc(audio_chunksize * sizeof(int16_t) * feed_channel,
                                         MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);   /* DMA 缓冲钉内部 RAM */
...
bsp_i2s_read((char *)audio_buffer, audio_chunksize * I2S_CHANNEL_NUM * sizeof(int16_t), &bytes_read, portMAX_DELAY);
/* Channel Adjust: 从尾部倒序展开，2ch → 3ch，参考声道置零 */
for (int i = audio_chunksize - 1; i >= 0; i--) {
    audio_buffer[i * 3 + 2] = 0;                       /* ref = 0 */
    audio_buffer[i * 3 + 1] = audio_buffer[i * 2 + 1]; /* mic2 */
    audio_buffer[i * 3 + 0] = audio_buffer[i * 2 + 0]; /* mic1 */
}
afe_handle->feed(afe_data, audio_buffer);
```

倒着循环是就地展开的经典写法——正向会覆盖还没读的数据。`MALLOC_CAP_INTERNAL` 是死规矩：I2S DMA 搬运的目的地必须内部 RAM，分配失败直接 `esp_system_abort`。任务里还有三处「跳过采集」的守卫（雷达睡眠模式 / 静音播放标志 / 红外学习进行中），都靠 `vTaskDelay` 降频轮询——采集暂停时唤醒自然也暂停。

### 4. Detect 任务：一个循环里的隐式状态机（`app_sr.c:172-271`）

```c
int mu_chunksize = g_sr_data->multinet->get_samp_chunksize(g_sr_data->model_data);
assert(mu_chunksize == afe_chunksize);            /* MN 与 AFE 帧长必须相等 */
while (true) {
    afe_fetch_result_t *res = afe_handle->fetch(afe_data);   /* 无新帧则阻塞 */
    if (res->wakeup_state == WAKENET_DETECTED) {
        xQueueSend(g_sr_data->result_que, &result, 0);        /* 唤醒事件 → Handler */
    } else if (res->wakeup_state == WAKENET_CHANNEL_VERIFIED) {
        detect_flag = true;
        g_sr_data->afe_handle->disable_wakenet(afe_data);     /* 停掉 WakeNet，省算力 */
    }
    if (true == detect_flag) {
        esp_mn_state_t mn_state = ESP_MN_STATE_DETECTING;
        if (false == sr_echo_is_playing()) {                  /* 提示音播放期间不识别 */
            mn_state = g_sr_data->multinet->detect(g_sr_data->model_data, res->data);
        } else { continue; }
        if (ESP_MN_STATE_TIMEOUT == mn_state) { ... g_sr_data->afe_handle->enable_wakenet(afe_data); detect_flag = false; }
        if (ESP_MN_STATE_DETECTED == mn_state) {
            esp_mn_results_t *mn_result = g_sr_data->multinet->get_results(...);
            xQueueSend(g_sr_data->result_que, &result, 0);    /* 命令事件 → Handler */
            g_sr_data->afe_handle->enable_wakenet(afe_data);  /* 回到待唤醒 */
        }
    }
}
```

三个设计点值得抄：**WakeNet 按需启停**——唤醒确认后 `disable_wakenet()`，命令结束或超时再 `enable_wakenet()`，同一时刻两层只跑一层，CPU 预算减半；**防自唤醒守卫**——`sr_echo_is_playing()` 为真就跳过 MultiNet，否则喇叭正在播的「好的」会被当成命令输入；**帧长断言**——MN 与 AFE 的 chunksize 不相等说明配置配错，属于集成期就该炸的错误。

### 5. Handler 任务：唤醒 → 提示音 → 命令的反馈链路（`app_sr_handler.c:150-286`）

Handler 阻塞在 `app_sr_get_result(&result, portMAX_DELAY)` 上等事件，收到后分三类处理：

- **唤醒事件**：`sr_anim_start()` 弹出 LVGL 聆听动画、暂停音乐播放、`sr_anim_set_text("请说")`，然后 `sr_echo_play(AUDIO_WAKE)` 播唤醒提示音；
- **命令事件**：查命令表 → 屏幕显示命令文本 → `sr_echo_play(AUDIO_OK)` 播确认音 → `switch (cmd->cmd)` 执行动作（RGB 灯、音乐播放/切歌、空调界面）；
- **超时事件**：显示「超时」、播结束音、动画收起、恢复之前暂停的音乐。

提示音机制本身就是一章素材：三段 wav（wake/ok/end，中英各一套）在语言切换时从 `/spiffs/` 整个读进 `MALLOC_CAP_SPIRAM` 缓冲；播放时解析 WAV 头 → `bsp_codec_set_fs()` 按头里的采样率重配链路 → mute 抖动去爆音 → `bsp_i2s_write(..., portMAX_DELAY)` 阻塞写完——期间 `b_audio_playing` 置真，回过头喂给 Detect 任务的守卫。UI 侧的并发纪律见 `ui_sr.c:210-215`：`sr_anim_set_text` 内部是 `ui_acquire(); lv_label_set_text_static(...); ui_release();`，非 UI 任务碰 LVGL 必须走显示锁（[[2026-08-26-esp32-s3-box-3-ch20-capstone-voice-remote|第二十章]] 4 节展开过正反例）。

---

## 18.5 实时性与内存：三任务、双核与 32ms 预算

### 1. 任务布局：为什么这么绑核

| 任务                    | 优先级                                                                             | 核     | 栈   | 依据           |
| ----------------------- | ---------------------------------------------------------------------------------- | ------ | ---- | -------------- |
| Feed Task               | 5                                                                                  | Core 0 | 4 KB | `app_sr.c:375` |
| Detect Task             | 5                                                                                  | Core 1 | 8 KB | `app_sr.c:378` |
| SR Handler Task         | `configMAX_PRIORITIES-1`（=24，IDF 默认 25 级，v6.0.2 `FreeRTOSConfig.h:93` 核实） | Core 0 | 6 KB | `app_sr.c:381` |
| （参照）WiFi 协议栈任务 | 高优先级（第二十章按平台口径记为 23 级）                                           | Core 0 | —    | 平台惯例       |

推理是**双核物理隔离**的教科书案例：Feed 与 Detect 同为 5 级却分踞两核，Detect 在 Core 1 上永远不怕被 WiFi 突发抢占——Core 0 上优先级再高的协议栈任务也抢不走另一个核的 CPU（调度机制见 [[2026-08-26-freertos-deep-dive-ch5-task-lifecycle-and-tcb|FreeRTOS（五）：任务生命周期]] 与 [[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|（二十二）SMP 重构]]）。Feed 与 WiFi 同在 Core 0 共存的底气是：WiFi 任务绝大部分时间在等事件，Feed 每帧只有一次拷贝加拆插（微秒级），而 DMA 环给了约 90 ms 迟到余量（[[2026-08-26-esp32-s3-box-3-ch11-i2s-audio|第十一章]] 4 节算过账）。Handler 用最高优先级则是为了「反馈不被打断」：它跑在 Core 0 却压过协议栈任务，播提示音、刷 UI 的短临界区几乎零延迟——代价是它绝不能干重活，否则全核遭殃（优先级是把双刃剑，[[2026-08-26-freertos-deep-dive-ch5-task-lifecycle-and-tcb|（五）]] 的调度规则）。

### 2. 模型放哪：Flash 常驻 + 按需进 PSRAM

一句结论：**模型本体永远在 Flash 的 model 分区（8600K，[[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章]] 分区表），运行时 mmap 直读；只有推理工作集进 PSRAM**。各层运行时内存（官方 benchmark 页数字，esp32s3）：

| 组件                                             | 内部 RAM | PSRAM     | 每帧耗时（帧长 32 ms）               |
| ------------------------------------------------ | -------- | --------- | ------------------------------------ |
| WakeNet9 量化 @2 通道                            | 16 KB    | 324 KB    | 3.0 ms                               |
| WakeNet9 量化 @3 通道                            | 20 KB    | 347 KB    | 4.3 ms                               |
| MultiNet6                                        | 32 KB    | 4100 KB   | 12 ms                                |
| AFE 整链（最接近的 MMNR/SR/LOW_COST 行，4 声道） | 79.1 KB  | 1153.7 KB | feed 23.7% + fetch 22.9%（单核占比） |

BOX-3 是 3 声道（MMR）配置，表中没有对应行——MMNR 行仅作量级参考，**待真机验证**。粗算总量级：AFE 工作集约 1.1 MB PSRAM + MN6 约 4.1 MB PSRAM + 两个 WN 模型（若同时在线）约 0.7 MB——8 MB Octal PSRAM 恰好装下还有余量，这就是 N16R8V 里「R8」的意义。MultiNet 权重的三级加载模式（18.3 节）是最后的调节阀：PSRAM 紧张时把部分权重留在 Flash 直读，换约 12 ms/帧变成更慢（具体各档耗时**待核对**）。

### 3. 与 32 ms 帧周期赛跑

每 32 ms，AFE 产出一帧，Detect 任务必须消费掉：fetch 取帧（含 AFE 前处理）+ 唤醒态 WN 推理 3~4.3 ms（或命令态 MN 推理 12 ms）。单帧预算占用约 10%~50%，Core 1 同时还要跑 LVGL（factory_demo 把 LVGL 也钉在 Core 1，靠同/低优先级时间片共存）——正常情况绰绰有余。**翻车模式是链式的**：一旦 Detect 被同核重活拖住（比如某个高优先级任务直跑长循环），AFE 内部环形缓冲（`afe_ringbuf_size`）涨满 → Feed 的 `feed()` 阻塞 → DMA 环 90 ms 后溢出 → `on_recv_q_ovf` 丢最旧缓冲 → 扬声器侧表现为爆音、识别侧表现为漏唤醒。这条背压链的每一环都在 [[2026-08-26-esp32-s3-box-3-ch11-i2s-audio|第十一章]] 7 节拆过，本章只补一句：**推理过载的第一症状永远先出现在音频，而不是日志**。任务看门狗维度（Core 1 满载饿死 Idle 触发 TWDT）见 [[2026-08-26-esp32-s3-box-3-ch13-timers-watchdogs|第十三章]]。

---

## 18.6 实验：跑通「唤醒 → 命令 → 反馈」

> [!warning] 待真机验证
> 本节步骤尚未在真机执行（板子在途）。日志格式字符串摘自源码 `ESP_LOGx` 语句，真实输出以真机为准，到货后逐条对账并补截图。

**步骤一：构建与烧录**（环境与版本约束见 [[2026-08-26-esp32-s3-box-3-ch4-project-anatomy|第四章]]）：

```bash
cd ~/esp/esp-box/examples/factory_demo
idf.py set-target esp32s3 && idf.py build
idf.py -p /dev/ttyACM0 flash monitor    # flash 自动包含 model 分区（esp-sr CMake 挂接）
```

**步骤二：观察启动与模型加载**。`main.c:145-147` 在开机 4 秒后才调 `app_sr_start(false)`（给 GUI 和 WiFi 让路）。启动日志应出现模型加载相关行——格式来自源码：`app_sr.c` 的 `load wakeword:%s` / `load multinet:%s` / `audio_chunksize=%d, feed_channel=%d`，以及 `model_path.c` 的 `The partition size is %ld KB` / `Successfully map %s partition`。

**步骤三：唤醒**。对 mic 说「Hi 乐鑫」或「Hi ESP」（出厂默认中文，双唤醒词模型都在分区里）。预期链路：日志 `wakeword detected` → `AFE_FETCH_CHANNEL_VERIFIED, channel index: %d` → 屏幕「请说」动画 → 唤醒提示音。

**步骤四：命令**。接着说「打开空调」（或英文 "Turn on the Air"）。预期：日志打印 top-5 候选（`TOP %d, command_id: %d, phrase_id: %d, prob: %f`，`app_sr.c:242`）→ `Detected command : %d` → Handler 日志 `command:%s, act:%d` → 屏幕显示命令文本 + 确认音 + 空调界面响应。

**步骤五：超时**。唤醒后沉默 5.76 s。预期：日志 `Time out`，屏幕「超时」，结束音，回到待唤醒态（可再次唤醒验证 `enable_wakenet` 生效）。

| 现象                       | 源码锚点                                        |
| -------------------------- | ----------------------------------------------- |
| 唤醒动画与「请说」         | `sr_handler_task` WAKENET 分支 + `ui_sr.c`      |
| top-5 概率打印             | `audio_detect_task` DETECTED 分支               |
| 提示音期间说命令无效       | `sr_echo_is_playing()` 守卫（可趁机做正反实验） |
| 唤醒后 5.76 s 无命令回待命 | `multinet->create(mn_name, 5760)`               |

**自定义命令词**（概念级，待真机验证）。路径 A（推荐，mn6 的 API 模式）：在 `g_default_cmd_info[]` 加一条 `{SR_CMD_XXX, SR_LANG_CN, 0, "打开风扇", "da kai feng shan", {NULL}}`，并在 Handler 的 `switch` 加对应分支——`app_sr_update_cmds()` 会自动把新命令注册进 MultiNet 语言模型，拼音规则见组件 `tool/multinet_pinyin.py`。路径 B（换模型）：`idf.py menuconfig` 里 ESP Speech Recognition 菜单换勾唤醒词/MultiNet 模型，重新构建即自动重打包 `srmodels.bin` 并烧 model 分区，日志会打印推荐分区大小，超出 8600K 就得改 `partitions.csv`。

---

## 18.7 翻车点表与小结

| 症状                                                                                | 根因                                                                                                      | 处理                                                                                                |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ---------- |
| 启动日志 `Can not find model in partition table` 或唤醒永不触发                     | model 分区没烧：用 esptool 手动只烧了 app；或分区名不是 `model`                                           | `idf.py flash` 全量烧录；分区表必须有一行 `Name=model`（esp-sr CMake 按名查找）                     |
| 日志 `The storage free size ... less than model partition required size`，mmap 失败 | data mmap 可用页不足：IDF v5.0 已知问题，或 app 太大挤占映射区                                            | 升级 IDF ≥5.1（factory_demo 要求 `idf>=5.1` 的原因之一）；缩 app 或缩 model 分区                    |
| 识别率极低、远场完全失灵                                                            | mic 声道映射反了：Feed 任务的 Channel Adjust 假设 `[0]=mic1、[1]=mic2`，硬件声道颠倒则双 mic 增强互相打架 | 在拆插循环里交换两个 mic 源；用 18.6 实验分别捂住一个 mic 定位                                      |
| 采集正常但 AFE 输出全静音                                                           | 音频链路与 AFE 配置失配：采样率不是 16 k / 声道数不是 2（AFE 按 `pcm_config` 解释字节流）                 | 一律经 `bsp_codec_set_fs(16000, 16, 2ch)` 成对配置，对照 [[2026-08-26-esp32-s3-box-3-ch11-i2s-audio | 第十一章]] |
| 说话断续爆音、偶发漏唤醒                                                            | Detect 被同核任务饿死 → AFE 环形缓冲涨满 → Feed 阻塞 → DMA 环溢出丢帧                                     | 别往 Core 1 塞重活；确认 Detect 只在 `fetch()` 阻塞；加大 `afe_ringbuf_size` 只能缓解不能根治       |
| 唤醒后说命令没反应，日志一直 `Time out`                                             | 提示音回灌被当成环境音（守卫期间不识别），或音量过大自触发                                                | 依赖官方守卫别删；降低提示音量；必要时后续接 AEC（参考声道需真实回采）                              |
| 启动即 `assert(mu_chunksize == afe_chunksize)` 崩溃                                 | 换了 MultiNet 模型但 AFE/模型帧长不对齐                                                                   | 集成期配置错误，回到 menuconfig 让两者同源配置                                                      |
| `set-target` 后 SR 配置消失、模型列表变空                                           | 配置写进了 sdkconfig 而非 defaults（ch4 铁律），重新生成被冲掉                                            | 只维护 `sdkconfig.defaults`；注意 `MULIT` 拼写照抄上游                                              |
| 灵敏度不合适（误唤醒多/叫不醒）                                                     | 默认 `DET_MODE_2CH_90` 不匹配使用场景                                                                     | `set_det_threshold()` 调 0.5~0.9999，或换 `_95` 档（误报同升）                                      |

本章小结：

- **ESP-SR 是三级流水线**：AFE（AEC/NS/VAD/MASE，3ch 交错 s16@16k 进、单声道增强帧出）→ WakeNet9（常开滑窗唤醒，平滑均值过阈值触发）→ MultiNet6（仅唤醒后运行，5760 ms 命令窗口，top-5 候选）。整条线的节拍是 **32 ms 一帧**。
- **模型的生命周期分两段**：构建期按 sdkconfig 勾选打包成 `srmodels.bin` 烧进 8600K 的 model 分区；运行期 `esp_srmodel_init("model")` 整区 mmap 直读，不挂文件系统、不拷进 RAM——推理工作集才进 PSRAM（WN9 约 324 KB/模型，MN6 约 4.1 MB，官方 benchmark 口径）。
- **factory_demo 的三个抄作业点**：Feed 就地 2ch→3ch 展开（参考声道置零 + 关 AEC）；Detect 用 `detect_flag` + `enable/disable_wakenet` 把两层推理改造成分时复用，加 `sr_echo_is_playing()` 防自唤醒；Handler 以最高优先级保证反馈零延迟，但临界区内只做短操作。
- **实时性 = 双核隔离 + 预算意识**：Detect 独占 Core 1 与 WiFi 物理隔离；单帧推理最重 12 ms 对 32 ms 帧长余量充足；过载的第一症状在音频（爆音）不在日志，背压链每一环都能在第十一/十三章找到机制。

下一章把视角从「现成模型」换到「自己的模型」：ESP-DL 的量化工具链、ESP-NN 的向量指令加速，以及怎么把 PC 上训练的网络部署到这块板子——本章 mmap + PSRAM 的内存观会直接复用。
