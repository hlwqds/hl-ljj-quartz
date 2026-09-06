---
title: "ESP32-S3-BOX-3 工程实战（二十）：综合项目——语音遥控器"
date: 2026-08-26 12:00:00
description: "系列收官：把 19 章积累的外设、组件与 FreeRTOS 调度知识组装成一台语音遥控器——唤醒 Hi ESP、命令词识别、LVGL 反馈、RMT 发射 NEC 红外码。本章是设计文档而非可编译工程：任务/优先级/绑核论证、内存预算、状态机与核心骨架，全部锚定 factory_demo 实地核实的事实，待真机验证后修订。"
tags: [esp32, esp32-s3, esp-idf, series, project]
---

# ESP32-S3-BOX-3 工程实战（二十）：综合项目——语音遥控器

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch19-esp-dl-deployment|第十九章：ESP-DL 模型部署]]
> **第二十章：综合项目——语音遥控器**（当前章）
> 系列完结：下一迭代为真机验证与修订

收官章做一个把全系列串起来的项目：**语音遥控器**——说「Hi ESP」唤醒，说「打开电视」「调大音量」等命令词，屏幕给出 LVGL 反馈，红外管发出 NEC 码。硬件仍在途，因此本章是一份**设计文档**：不编造可编译的完整工程，只给结构体、任务签名、状态机与主循环伪码；每一个任务优先级、栈深、内存 caps 的取值都锚定 factory_demo 实地核实的事实（[[ch4-project-anatomy|第四章]] + 本地 esp-box 仓库源码），到货后按此蓝图施工并回填修订。

---

## 20.1 需求与验收

产品形态一句话：**一台会听话的电视遥控器**。主链路四步——唤醒（WakeNet9「Hi ESP」）→ 命令识别（MultiNet6 中文量化模型）→ 屏幕反馈（LVGL 提示动画与识别文本）→ 红外发射（RMT + NEC 编码，38kHz 载波）。验收清单每条都对应本系列某章的知识点——这张表同时也是全系列的复习提纲：

| #   | 验收项                                              | 验证方法                                   | 考核的知识                                   |
| --- | --------------------------------------------------- | ------------------------------------------ | -------------------------------------------- |
| 1   | 上电 60s 内进入主界面，无黑屏/花屏，背光正常        | 串口日志 + 目视                            | 六（启动流程）、十（SPI 屏幕）、十五（LVGL） |
| 2   | 说「Hi ESP」，1s 内屏幕弹出聆听动画                 | 秒表 + 日志时间戳                          | 十八（WakeNet）、十一（ES7210 双 mic 采集）  |
| 3   | 说「打开电视」，屏幕显示识别文本，红外管发出 NEC 帧 | 逻辑分析仪抓 IR_TX：38kHz 载波、9ms 引导头 | 十二（RMT/NEC）、十八（MultiNet 命令词）     |
| 4   | 唤醒后不说话，5.76s 超时回到待命并提示「超时」      | 日志 `Time out`                            | 十八（multinet 检测窗口）、本章状态机        |
| 5   | 连续 20 次命令，识别 ≥18 次，日志无音频丢帧计数     | 脚本化重复测试                             | 十一（I2S DMA 环形缓冲）、本章丢帧监控       |
| 6   | 红外发射期间聆听动画不卡顿                          | 目视帧率                                   | 十五（UI 与音频任务的优先级权衡）            |
| 7   | 满负荷跑 30 分钟，无任务看门狗复位                  | 串口全程监控                               | 十三（TWDT/MWDT）                            |
| 8   | 断电重启后，已学习的红外码表从 NVS 恢复             | 学习→重启→重放                             | 七（NVS）、十二（ir_learn 学习数据）         |

> [!warning] 待真机验证
> 以上 8 条全部依赖真机（麦克风阵列、SENSOR 板红外收发、逻辑分析仪波形）。第 3 条的 NEC 波形参数（9ms 引导 + 4.5ms 间隔 + 32bit 地址/命令）以第十二章实验为准，本章只设计数据通路。

---

## 20.2 系统架构：五个任务与一条状态机

### 1. 任务图

```text
        Core 1（音频 + 推理）                      Core 0（WiFi + UI + 状态机）
 ┌──────────────────────────┐            ┌────────────────────────────────────┐
 │ audio_task  prio5        │            │ ui_task(LVGL) prio4                │
 │  bsp_i2s_read → AFE.feed │            │  渲染 + 触摸 indev + 聆听动画       │
 │        │ (AFE 内部环形)   │            │        ▲ bsp_display_lock          │
 │        ▼                 │            │ ir_task  prio4                     │
 │ sr_task     prio5        │            │  xTaskNotify(cmd_id) → rmt_transmit│
 │  AFE.fetch → WN/MN 推理  │            │        ▲                           │
 └──────┬───────────────────┘            │ sm_task(复用 main 任务) prio1/Core0 │
        │ result_que(深度3)              │  状态机：IDLE→LISTENING→COMMAND→…   │
        └───────────────────────────────►│  投递 UI 事件 / 任务通知            │
                                       └────────────────────────────────────┘
```

### 2. 任务表：优先级、绑核、栈深

任务参数不是拍脑袋——factory_demo 的 `app_sr_start()`（本地源码核实）给出了官方参考值，本设计继承或在其邻域内取值：

| 任务            | 优先级 | 绑核   | 栈(字节) | 取值依据                                                                          |
| --------------- | ------ | ------ | -------- | --------------------------------------------------------------------------------- |
| audio_task      | 5      | Core 1 | 4096     | factory_demo「Feed Task」同参数（4KB/prio5/Core0）；本设计移到 Core 1，见下方论证 |
| sr_task         | 5      | Core 1 | 8192     | factory_demo「Detect Task」同参数（8KB/prio5/Core1）；推理调用链深、含浮点        |
| ui_task(LVGL)   | 4      | Core 0 | 4096     | esp_lvgl_port 默认量级；factory_demo 仅显式改了 `task_affinity` 未改优先级        |
| ir_task         | 4      | Core 0 | 4096     | factory_demo 的 ir_learn 任务即 4096/prio5；发码只提交 RMT 事务，硬件定时         |
| sm_task(状态机) | 1      | Core 0 | 4096     | 复用 main 任务：阻塞在队列上，零 CPU 占用，无需新建任务                           |

**绑核论证（Core 1 = 音频+推理，Core 0 = WiFi+UI+状态机）**：

1. **屏蔽协议栈突发**。IDF 的 WiFi/NIMBLE/lwIP 任务按平台惯例钉在 Core 0（PRO_CPU 传统，见 [[ch1-from-bare-metal-to-rtos|FreeRTOS 系列（一）]]），且其优先级很高（WiFi 任务 23 级）。音频链路的截止期是硬的——I2S DMA 环必须在每个 chunk 周期内被取走，否则 overrun 丢帧。把 feed/detect 钉在 Core 1，等于用**物理隔离**替代优先级竞争：Core 0 上 23 级任务再怎么突发也抢不走另一个核。
2. **生产者消费者同核**。AFE 的 feed/fetch 共享内部环形工作集，同核调度避免跨核同步开销与缓存一致性流量（机制见 [[ch23-cross-core-synchronization|（二十三）跨核同步]]）。
3. **UI 是软实时**。LVGL 30fps 是人眼约束，且负载集中在 DMA 搬运与渲染，与 WiFi 同为「突发+可延迟」型，合住 Core 0。代价是 WiFi 高负载时可能掉帧——验收第 6 条专门盯这个；factory_demo 的备选方案（LVGL 也钉 Core 1）作为帧率不达标时的退路。

**栈深估算方法**：先按 factory_demo 参考值给足 → 真机跑满功能 → `uxTaskGetStackHighWaterMark()` 读历史最小余量 → 留 30~50% 余量收紧。栈单位是**字节**（IDF 口径，Vanilla 是字——老 MCU 照抄参数是经典翻车点），栈为何默认禁放 PSRAM 见 [[ch21-stack-and-memory-layout|（二十一）栈与内存布局]]。

### 3. IPC 通道选型

| 边       | 载荷形态                                              | 选择                                                      | 论证                                                                                                                             |
| -------- | ----------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| audio→sr | PCM 字节流（每 chunk 数 KB）                          | AFE 内部环形（本质是流式缓冲）；自建则用 StreamBuffer     | 字节流、单产单销、不可分帧——正是流缓冲的甜点区，见 [[2026-08-26-freertos-deep-dive-ch14-stream-message-buffers\|（十四）流缓冲]] |
| sr→sm    | 定长事件 `sr_result_t{wakenet_mode,state,command_id}` | 队列，深度 3                                              | 定长小事件、天然背压；深度 3 为 factory_demo 实测值，见 [[2026-08-26-freertos-deep-dive-ch10-queue-universal-ipc\|（十）队列]]   |
| sm→ir    | 单个 `cmd_id`（表索引）                               | 任务通知                                                  | 32 位值即全部信息，最轻量 IPC，见 [[2026-08-26-freertos-deep-dive-ch13-task-notifications\|（十三）通知]]                        |
| sm→ui    | 文本/状态变更                                         | `bsp_display_lock(0)` 临界区 + `lv_label_set_text_static` | LVGL 非线程安全，纪律见 20.5 节与 [[2026-08-26-freertos-deep-dive-ch11-semaphore-mutex-priority-inheritance\|（十一）互斥量]]    |
| 生命周期 | 删除握手（NEED_DELETE/DELETED 位）                    | 事件组                                                    | 多任务多位状态汇聚，见 [[2026-08-26-freertos-deep-dive-ch12-event-groups\|（十二）事件组]]                                       |

---

## 20.3 内存预算：内部 SRAM 与 PSRAM 的分界线

BOX-3 是 512KB 内部 SRAM + 8MB Octal PSRAM 的双世界格局。预算原则一句话：**DMA 要到的、锁不能等的、栈——内部；大块的、冷数据的——PSRAM**。caps 机制与分配优先级见 [[ch20-idf-heap-and-caps|（二十）IDF 堆与 caps]]。

| 区域                  | 预算(设计值)                                         | caps                          | 理由（factory_demo 实证处标注 ✦）                                  |
| --------------------- | ---------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------ |
| esp-sr 模型工作区     | 由 `multinet->create(name, 5760)` 决定，MB 级        | PSRAM 为主                    | 命令表节点 `MALLOC_CAP_SPIRAM` ✦、提示音 wav 缓冲 `SPIRAM\|8BIT` ✦ |
| 音频 feed 缓冲        | `chunksize×3ch×2B`（数 KB）                          | `MALLOC_CAP_INTERNAL\|8BIT` ✦ | I2S DMA 搬运目的地，内部 RAM 是确定路径；分配失败直接 abort ✦      |
| LVGL draw buffer      | 320×10×2B≈6.4KB（`DRAW_BUF_HEIGHT=10`，单缓冲+DMA）✦ | 内部 DMA-capable              | 分片刷新，BSP 以 `buff_dma=true` 申请 ✦                            |
| LVGL 对象树/字体/图片 | 数百 KB                                              | PSRAM                         | `CONFIG_LV_MEM_CUSTOM=y` 把 LVGL 堆接到系统堆 ✦                    |
| 5 条任务栈            | 4/8/4/4/4 KB                                         | 内部                          | `SPIRAM_ALLOW_STACK_EXTERNAL_MEMORY` 未开启 ✦                      |
| WiFi/lwIP 缓冲        | 尽量外置                                             | PSRAM                         | `CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y` ✦                         |

两道保险丝（factory_demo sdkconfig.defaults 实证）：`SPIRAM_MALLOC_ALWAYSINTERNAL=1024`——小于 1KB 的分配强制内部，避免高频小对象走 PSRAM 拖慢总线；`SPIRAM_MALLOC_RESERVE_INTERNAL=8192`——内部快耗尽时给 ISR/临界路径保留 8KB。预算表合计内部占用逼近 300KB 时就该警觉：S3 的内部 SRAM 还要容纳 WiFi 驱动、DMA 描述符与中断栈。

> [!warning] 待真机验证
> 本表是**设计预算**而非实测占用。真机首跑用 factory_demo 同款 monitor 循环（`heap_caps_get_free_size` / `get_largest_free_block` / `get_minimum_free_size` 三个口径）采集基线，再回填修正。

---

## 20.4 工程组装 checklist

从零到可烧录，八步。版本约束全部沿用 [[ch4-project-anatomy|第四章]] 核实的 factory_demo 清单——依赖树已被官方 CI 在五个 IDF 版本上地毯式验证过，不要自创组合。

1. `idf.py create-project --target esp32s3 voice-remote`，骨架见第四章 4.1 节（三行 CMakeLists）。
2. 克隆 esp-box 仓库，顶层 CMakeLists 加 `set(EXTRA_COMPONENT_DIRS <esp-box>/components)`——`bsp_board.h`（SENSOR 板抽象、IR GPIO 定义）只住在那里。
3. `main/idf_component.yml` 最小清单（对照 ch4 全量清单裁剪：去掉 rainmaker/audio-player/led_strip/qrcode/aht20/at581x/esp_schedule）：

```yaml
## IDF Component Manager Manifest File
dependencies:
  idf: ">=5.1"
  espressif/esp-sr: 1.4.*
  espressif/ir_learn: ^0.1.0
  # BSP 经 <esp-box>/components/bsp 的清单传递：
  #   espressif/esp-box-3: 1.1.*（factory_demo 实际解析 1.1.3）
  #   esp_codec_dev 1.1.0、espressif/button ^3.5.0
  #   lvgl / esp_lvgl_port 随 BSP 传递（factory_demo 实际解析 8.4.0 / 1.4.0）
```

4. `partitions.csv`——以 ch4 核实的 factory_demo 分区表为底本裁剪，去掉 `sec_cert`/`fctry`（无 RainMaker）、`storage`（暂无提示音资源则留 512K 备用）：

```csv
# Name,   Type, SubType, Offset,  Size, Flags
nvs,      data, nvs,     0x10000, 0x6000,
otadata,  data, ota,     ,        0x2000,
phy_init, data, phy,     ,        0x1000,
ota_0,    app,  ota_0,   ,        3M,
model,    data, spiffs,  ,        8600K,
```

`model` 分区名是 esp-sr 的加载约定（`esp_srmodel_init("model")`）✦。只勾中文 MN 模型时 8600K 可显著缩小，具体值以构建后 model 镜像体积为准——**待真机验证**。5. `sdkconfig.defaults`——从 ch4 核实片段取核心行：目标/16MB QIO Flash/自定义分区表/CPU 240MHz + DFS 240↔40/`SPIRAM=y MODE_OCT SPEED_80M`/`SR_WN_WN9_HIESP_MULTI`（只要英文唤醒词「Hi ESP」，比 factory_demo 少勾 HILEXIN）/`SR_MN_CN_MULTINET6_QUANT`（只要中文命令模型）/`ESP_CONSOLE_USB_SERIAL_JTAG`/`FREERTOS_HZ=1000`。另加两行 factory_demo 教训值：`CONFIG_ESP_TASK_WDT_TIMEOUT_S=7`（推理长任务友好）与 20.3 节两道内存保险丝。6. `main/` 目录组织：`main.c`（状态机 sm_task）、`app_audio.c`、`app_sr.c`、`app_ir.c`、`gui/ui_remote.c`；组件依赖申报规则照 ch4 4.3 节判据。7. `idf.py build` 冒烟——编译不需要硬件，先让链接器把内存预算表变成 map 文件里的硬数字。8. `idf.py -p /dev/ttyACM* flash monitor`，按 20.1 验收清单逐条打勾。

> [!warning] 待真机验证
> 第 4 步的分区尺寸、第 5 步精简后的 sdkconfig 组合，均需真机构建+烧录确认（尤其单语言 model 分区缩容与 3M app 是否够用），本 checklist 未在本机执行。

---

## 20.5 核心设计骨架

### 1. 状态机：六次转移

| 当前态    | 事件                             | 下一态    | 动作                                             |
| --------- | -------------------------------- | --------- | ------------------------------------------------ |
| IDLE      | `WAKENET_DETECTED` 入队          | LISTENING | 唤醒提示音、UI 聆听动画启动                      |
| LISTENING | AFE 声道校验通过（MN 就绪）      | COMMAND   | 关 WakeNet，进 MultiNet 检测循环                 |
| COMMAND   | `ESP_MN_STATE_DETECTED`          | FEEDBACK  | UI 显示识别文本 + OK 提示音                      |
| COMMAND   | `ESP_MN_STATE_TIMEOUT`（5.76s）✦ | IDLE      | UI 显示「超时」，重新使能 WakeNet                |
| FEEDBACK  | 提示音播完                       | IR_FIRE   | 查命令表，`xTaskNotifyGive` 携 cmd_id 给 ir_task |
| IR_FIRE   | `rmt_tx_wait_all_done` 返回      | IDLE      | 重新使能 WakeNet，回到待命                       |

这五态正是 factory_demo `audio_detect_task`/`sr_handler_task` 里 `detect_flag` 隐式状态机的显式化——官方代码用布尔标志+分支实现同样的转移，教学项目把它画成表便于审计。

```c
/* 设计骨架——非可编译工程代码 */
typedef enum {
    SM_IDLE = 0, SM_LISTENING, SM_COMMAND, SM_FEEDBACK, SM_IR_FIRE,
} sm_state_t;

static void sm_task(void *arg)          /* 复用 main 任务亦可 */
{
    sm_state_t st = SM_IDLE;
    sr_result_t res;
    for (;;) {
        xQueueReceive(g_result_que, &res, portMAX_DELAY);   /* 阻塞让出 CPU */
        switch (st) {
        case SM_IDLE:
            if (res.wakenet_mode == WAKENET_DETECTED) {
                ui_remote_show_listen(true);                /* 经显示锁 */
                st = SM_LISTENING;
            }
            break;
        case SM_COMMAND:
            if (res.state == ESP_MN_STATE_DETECTED) {
                ui_remote_show_text(cmd_table[res.command_id].ui_text);
                st = SM_FEEDBACK;                           /* 音播完→IR_FIRE */
            } else if (res.state == ESP_MN_STATE_TIMEOUT) {
                ui_remote_show_text("超时");  st = SM_IDLE;
            }
            break;
        /* LISTENING/FEEDBACK/IR_FIRE 的转移由 AFE 回调与 ir_task 完成位驱动，略 */
        }
    }
}
```

### 2. audio→sr 衔接：环形缓冲伪码

factory_demo 直接用 esp-sr AFE 的内部环形（feed/fetch 一对阻塞接口），这是首选；下面给出等价语义的自建版本，说明水位与丢帧策略（若自建，MN 与 AFE 的 chunksize 必须相等——官方代码里有一句 `assert(mu_chunksize == afe_chunksize)` ✦）：

```text
audio_task (Core1, 每个DMA周期唤醒一次):
    n = bsp_i2s_read(buf, CHUNK * 2CH * 2B, portMAX_DELAY)   # 阻塞在I2S事件
    展开双 mic 为 3 通道（参考通道置零，AEC 关闭时官方同款处理 ✦）
    if xStreamBufferSend(g_pcm_sb, buf, n, 0) != n:
        g_drop_frames++                                      # 满则丢，绝不阻塞音频
    # g_pcm_sb 建立时设 trigger 水位 = 一个 fetch chunksize：
    #   xStreamBufferCreate(FEED_CHUNK * 4, FEED_CHUNK * 2)

sr_task (Core1):
    xStreamBufferReceive(g_pcm_sb, buf, FETCH_CHUNK, portMAX_DELAY)  # 水位未到不出CPU
    ... WakeNet/MultiNet 推理，结果 xQueueSend(g_result_que, &res, 0)
```

两个纪律：**audio_task 里禁止 malloc/日志/锁**（热路径只做搬运）；**发送端零超时、接收端无限等**——丢帧计数器比阻塞更健康。另注意 factory_demo 的守卫：提示音播放期间暂停 MN detect（`sr_echo_is_playing()` ✦），否则自己的提示音会被当成命令输入。

### 3. 命令词表：语音到红外码的映射

结构体是 MultiNet 注册表与 NEC 码表的连接点。拼音串进 `esp_mn_commands_add`，命中后返回的 `command_id` 直接索引本表：

```c
/* 设计骨架——非可编译工程代码 */
typedef enum {
    RCMD_TV_ON = 0, RCMD_TV_OFF, RCMD_VOL_UP, RCMD_VOL_DOWN, RCMD_MAX,
} remote_cmd_id_t;

typedef struct {
    const char   *phoneme;    /* MultiNet6 拼音串，注册给 esp_mn_commands_add */
    const char   *ui_text;    /* LVGL 反馈文案 */
    uint16_t      nec_addr;   /* NEC 地址码（电视机厂商码，待学习/查码表） */
    uint16_t      nec_data;   /* NEC 命令码 */
    bool          need_repeat;/* 音量类需连发 2~3 帧 */
} remote_cmd_entry_t;

static const remote_cmd_entry_t g_cmd_table[RCMD_MAX] = {
    [RCMD_TV_ON]    = { "da kai dian shi", "打开电视", 0x00BF, 0x12, false },
    [RCMD_TV_OFF]   = { "guan bi dian shi", "关闭电视", 0x00BF, 0x1A, false },
    [RCMD_VOL_UP]   = { "tiao da yin liang", "调大音量", 0x00BF, 0x44, true  },
    [RCMD_VOL_DOWN] = { "tiao xiao yin liang", "调小音量", 0x00BF, 0x45, true },
};
```

> [!warning] 待真机验证
> 表中的 NEC 地址/命令码是占位示例。真实值要么查电视机码表，要么用第十二章 + ir_learn 组件学习获得（`ir_learn_cfg_t{learn_gpio=BSP_IR_RX_GPIO=38, task_stack=4096, task_priority=5}` ✦），学习结果按 factory_demo 格式落 SPIFFS/NVS，满足验收第 8 条。

ir_task 收到 cmd_id 后的发码路径，全部 API 在 factory_demo `ui_sensor_monitor.c` 中核实：先 `gpio_set_level(BSP_IR_CTRL_GPIO=44, 0)` 使能红外收发电路 ✦，`rmt_new_tx_channel{gpio_num=BSP_IR_TX_GPIO=39, mem_block_symbols=128, trans_queue_depth=4, resolution_hz=1MHz}` → `rmt_apply_carrier{38000Hz, duty 0.33}` → `ir_encoder_new`（ir_learn 组件的 NEC 编码器）→ `rmt_transmit` + `rmt_tx_wait_all_done` → 逆序拆除。

### 4. UI 事件投递：第十五章的并发纪律

LVGL 不是线程安全的，所有非 UI 任务触碰控件必须走显示锁——factory_demo 的正例是 `sr_anim_set_text()`：`ui_acquire(); lv_label_set_text_static(...); ui_release();`（内部即 `bsp_display_lock(0)/unlock` ✦）。同一文件里也有**反例**：`sr_anim_start()` 直接 `lv_event_send` 未加锁——它赌的是事件回调只改标志位，这种侥幸不要学。本章纪律：

- 跨任务投递一律封装成 `ui_remote_show_*()` 函数，锁在函数内成对出现；
- 锁内只做 O(1) 属性修改，绘制留给 ui_task 的 lv_timer；文本用 `lv_label_set_text_static` 引用静态表常量，避免锁内拷贝；
- 显示锁是带优先级继承的互斥量语义，高优先级 sm_task 短临界区不会长时间压住 ui_task——机制见 [[ch11-semaphore-mutex-priority-inheritance|（十一）优先级继承]]。

---

## 20.6 复盘：设计风险清单

| 风险                  | 机理                                                                                                            | 缓解                                                                                                                                                                                                                                                                                           |
| --------------------- | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 优先级反转            | sm_task(高) 等显示锁，而持锁的 ui_task(4) 又被同核更高任务挤占；或 echo 播放在临界区内 `portMAX_DELAY` 等待 I2S | 锁内只做 O(1) 调用；播放等长操作移出临界区；显示锁选互斥量（PI）而非二值信号量，见 [[2026-08-26-freertos-deep-dive-ch11-semaphore-mutex-priority-inheritance\|（十一）]]                                                                                                                       |
| 任务看门狗复位        | Core 1 上 audio+sr 双 5 级任务近似满载，Idle 饿死触发 TWDT；推理段又是长直跑代码                                | `ESP_TASK_WDT_TIMEOUT_S=7`（factory_demo 同值 ✦）；确认 sr_task 在 fetch 处自然阻塞；必要时用 esp_task_wdt API 显式管理订阅，排坑方法见 [[2026-08-26-freertos-deep-dive-ch24-debugging-tracing-pitfalls\|（二十四）排坑]]与本系列[[2026-08-26-esp32-s3-box-3-ch13-timers-watchdogs\|第十三章]] |
| 音频丢帧              | feed 缓冲被 PSRAM 分配失败拖累（模型加载吃掉大块 PSRAM 后内部碎片化）；或 feed 任务被同核长任务抢占             | feed 缓冲钉 `MALLOC_CAP_INTERNAL` 并在 LVGL 初始化**之前**申请（启动顺序即内存顺序）；丢帧计数器进 UI，超阈值告警                                                                                                                                                                              |
| IR 与语音互扰         | 发码期间提示音回灌麦克风造成误识别                                                                              | 状态机互斥：仅 IR_FIRE 态发码，提示音播放期暂停 MN detect（factory_demo 守卫 ✦）；后续可开 AEC                                                                                                                                                                                                 |
| MN/AFE chunksize 失配 | 两个模型分量不对齐时数据流错位                                                                                  | 集成期断言校验（官方同款 assert ✦），失败即配置错误而非运行错误                                                                                                                                                                                                                                |

---

## 20.7 扩展路线

- **WiFi 遥测**（[[ch16-wifi-events|第十六章]]）：把丢帧率、识别率、状态机轨迹经 esp_event 上报局域网——esp_event 从第七章贯穿到此，遥测也是验收第 5 条的自动化手段。
- **ESP-DL 人脸解锁**（[[ch19-esp-dl-deployment|第十九章]]）：红外发射前加人脸确认，防止误触发电视。BOX-3 无摄像头，需经 PMOD 扩展——正好复用第十四章 BSP 里 PMOD 引脚描述的机制。
- **Matter 接入**（[[ch17-rainmaker-matter|第十七章]]）：语音遥控器升级为 Matter 控制器节点，「打开电视」同时下发 IR 与 Matter on/off 命令——红外设备的桥接正是 Matter 桥的标准用例。

---

## 20.8 翻车点表

| 症状                                   | 根因                                                 | 处理                                                               |
| -------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------ |
| 识别率奇低、唤醒无反应                 | 音频通路断层：chunksize 失配或参考通道未置零         | 核对 assert；按官方 feed 任务做 2ch→3ch 展开 ✦                     |
| 启动即 `No mem for audio buffer` abort | PSRAM 初始化晚于音频子系统，或内部 RAM 被先行吃光    | 确认 `SPIRAM_MODE_OCT/SPEED_80M` 生效；feed 缓冲申请提到 LVGL 之前 |
| 说命令没反应，日志一直 `Time out`      | 提示音回灌被识别为环境音，或 MN 在 echo 播放期间空转 | 加 `sr_echo_is_playing` 守卫；缩短/降低提示音                      |
| IR 学习成功但重放无效                  | 忘记拉低 IR_CTRL(GPIO44) 使能发射极                  | 发码前后统一管理 GPIO44 ✦                                          |
| UI 偶发花屏/崩溃                       | 某任务裸调 LVGL API 绕过显示锁                       | 全部收口到 `ui_remote_show_*()`，代码评审盯 `lv_` 前缀             |
| 跑几分钟后 TWDT 复位                   | Core1 满载饿死 Idle，或长直跑推理段                  | 见 20.6 风险表第二行；`uxTaskGetSystemState` 找元凶                |
| `set-target` 后 SR 相关配置消失        | 配置写进了 sdkconfig 而非 defaults                   | 只维护 sdkconfig.defaults（ch4 4.5 节铁律）                        |
| 优先级照抄本表却更卡                   | 本表数值绑定本设计的绑核方案，搬走即失效             | 优先级与绑核是一体的，改核必改优先级论证                           |

---

## 20.9 全系列知识地图与收官

二十章走完，用一张对照图把两条系列线钉在一起——左列是本系列（工程视角：产品怎么搭），右列是 FreeRTOS 深度解析（源码视角：内核怎么写）：

| 本系列章节            | FreeRTOS 系列对应章                                                                    | 咬合点                                                                             |
| --------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------ | -------------------------------------- |
| 一 三十分钟跑通       | [[2026-08-26-freertos-deep-dive-ch1-from-bare-metal-to-rtos\\                          | （一）从裸机到 RTOS]]                                                              | 同一套 IDF 环境，QEMU↔真机互补 |
| 二 生态地图           | [[2026-08-26-freertos-deep-dive-series-index\\                                         | 系列索引]]                                                                         | 仓库地图互见                   |
| 三 idf.py 工具链      | [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow\\                       | （三）构建与启动]]                                                                 | 工具链使用↔构建系统源码        |
| 四 工程解剖           | [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow\\                       | （三）构建与启动]]                                                                 | 组件模型↔project.cmake 走读    |
| 五 镜像与烧录         | [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow\\                       | （三）构建与启动]]                                                                 | 三镜像结构↔boot 链路           |
| 六 上电到 app_main    | [[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow\\                       | （三）构建与启动]]                                                                 | 启动日志↔app_start 源码        |
| 七 系统服务           | [[2026-08-26-freertos-deep-dive-ch12-event-groups\\                                    | （十二）事件组]]、[[2026-08-26-freertos-deep-dive-ch15-software-timers-daemon\\    | （十五）软件定时器]]           | esp_event↔事件组；esp_timer↔定时器守护 |
| 八 GPIO 与中断        | [[2026-08-26-freertos-deep-dive-ch13-task-notifications\\                              | （十三）通知]]、[[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks\\ | （十八）临界区]]               | ISR 侧的唤醒路径                       |
| 九 I2C 传感器         | [[2026-08-26-freertos-deep-dive-ch11-semaphore-mutex-priority-inheritance\\            | （十一）互斥量]]                                                                   | 总线共享的锁保护               |
| 十 SPI 屏幕           | [[2026-08-26-freertos-deep-dive-ch20-idf-heap-and-caps\\                               | （二十）堆与 caps]]                                                                | DMA 缓冲的 caps 选择           |
| 十一 I2S 音频         | [[2026-08-26-freertos-deep-dive-ch10-queue-universal-ipc\\                             | （十）队列]]、[[2026-08-26-freertos-deep-dive-ch14-stream-message-buffers\\        | （十四）流缓冲]]               | 本章 audio→sr 的原型                   |
| 十二 RMT 红外         | [[2026-08-26-freertos-deep-dive-ch15-software-timers-daemon\\                          | （十五）软件定时器]]                                                               | 硬件波形 vs 软件定时           |
| 十三 定时器看门狗     | [[2026-08-26-freertos-deep-dive-ch24-debugging-tracing-pitfalls\\                      | （二十四）排坑]]                                                                   | TWDT 触发条件                  |
| 十四 BSP 走读         | [[2026-08-26-freertos-deep-dive-ch5-task-lifecycle-and-tcb\\                           | （五）任务生命周期]]                                                               | BSP 内创建的任务们             |
| 十五 LVGL             | [[2026-08-26-freertos-deep-dive-ch8-priority-timeslice-rr\\                            | （八）时间片]]、（十一）互斥量                                                     | 显示锁与同优先级轮转           |
| 十六 WiFi             | [[2026-08-26-freertos-deep-dive-ch12-event-groups\\                                    | （十二）事件组]]                                                                   | 断线重连状态机                 |
| 十七 RainMaker/Matter | ——                                                                                     | 生态章，无内核对应                                                                 |
| 十八 ESP-SR           | （五~九）任务与调度、[[2026-08-26-freertos-deep-dive-ch23-cross-core-synchronization\\ | （二十三）跨核]]                                                                   | 推理任务的实时性设计           |
| 十九 ESP-DL           | [[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison\\                      | （十九）分配器对比]]、（二十）堆                                                   | 模型内存布局                   |
| 二十 综合（本章）     | 全系列                                                                                 | 本篇                                                                               |

收官回望：系列开场承诺的「四层下钻」在本章兑现为一条完整的数据通路——一句「打开电视」从麦克风（L4 声波）进入 ES7210（L3 I2S/TDM 寄存器），经 AFE 与 MultiNet（L2 组件源码），最终由 `bsp_i2s_read` 这类 API（L1）汇入状态机，再反向走到 RMT 引脚上的 38kHz 载波（L4）。自顶向下走一遍，自底向上又走一遍，这块板子的每一层都不再是黑盒。设计已备，蓝图上每一个「待真机验证」都是下一迭代的施工清单——板子到货之日，就是本章从设计文档变成可复现实验之时。
