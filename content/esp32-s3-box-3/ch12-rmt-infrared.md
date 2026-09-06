---
title: "ESP32-S3-BOX-3 工程实战（十二）：RMT 与红外"
date: 2026-08-26 12:00:00
description: "从『RTOS 下软件位劈为什么撑不住微秒级红外时序』出发，走满 L1~L4：新版 rmt_tx/rmt_rx API、esp_driver_rmt 源码（符号内存共享、RX 滤波阈值、中断回调派发）、S3 RMT 外设规格、NEC 帧波形精读，最后在 SENSOR 板红外收发上完成发码与学习模式设计。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（十二）：RMT 与红外

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch11-i2s-audio|第十一章：I2S 与音频]]
> **第十二章：RMT 与红外**（当前章）
> 下一章：[[ch13-timers-watchdogs|第十三章：定时器与看门狗]]

前面几章的外设（I2C、SPI、I2S）都是"数据总线"：硬件负责搬字节，时序由协议状态机保证。本章换一类问题——**红外遥控是"波形协议"**：信息不在字节里，而在"电平持续了多久"里。引导码 9ms、一个 bit 1.125ms 或 2.25ms，接收方靠测量时长解码。这类协议对 CPU 实时性的要求与前几章完全不同，也正是 RMT 外设存在的理由。

BOX-3 的 SENSOR 板上带红外收发（系列索引的芯片清单里登记过的那一行），本章就把它点亮：先说清为什么必须用硬件，再按四层下钻走满 L1（新版驱动 API）→ L2（esp_driver_rmt 源码）→ L3（S3 RMT 外设规格）→ L4（NEC 波形与逻辑分析仪），最后做发码实验并设计"学习模式"。所有 IDF 源码、BSP 事实均为本地实地读取（esp-idf v6.0.2、esp-box 仓库）；NEC 时序数字经权威资料核实（来源在 12.5 节注明）。

---

## 12.1 动机：调度抖动 vs 微秒级时序

### 1. 软件"位劈"在裸机里可行

用 GPIO 模拟红外发射（俗称 bit-banging，位劈）在裸机上是个经典练习：拉高 560us、拉低 560us 就是一个 0，拉高 560us、拉低 1690us 就是一个 1，忙等或定时器中断驱动，逐 bit 翻转。单任务、无干扰时误差可以控制在几个微秒。

问题出在"无干扰"四个字上。

### 2. RTOS 环境下，谁来保证 560us？

BOX-3 跑的是 factory_demo 那样的完整系统：FreeRTOS 1ms tick、WiFi 协议栈任务、音频任务、LVGL 渲染任务共存，还开了 DFS 动态降频。在这个环境里发一帧 NEC，需要的不是"平均 560us"，而是**每一个 bit 的每一次翻转都不能晚**。而调度器给出的恰恰只是统计意义上的及时：

- **任务被抢占**：你的发码任务翻转 GPIO 的循环里，任何更高优先级任务（比如音频 DMA 半满回调唤起的任务）就绪，你就被换下 CPU。唤醒到恢复的延迟受中断延迟、临界区长度、同优先级时间片多重影响——[[freertos-deep-dive|FreeRTOS 深度解析系列]]调度部分拆的正是这些路径，量级在十微秒到毫秒之间波动。
- **软件定时器靠守护任务**：想用软件定时器逐 bit 中断发码也不行——定时器回调排在定时器服务任务的队列后面，回调时刻随系统负载抖动（细节见 [[ch15-software-timers-daemon|FreeRTOS（十五）软件定时器]]，12.7 节还会回来算这笔账）。
- **NEC 的容差没那么宽**：官方示例解码用的容差是 ±200us（`EXAMPLE_IR_NEC_DECODE_MARGIN`，见 12.5 节）。发射端累计抖动一大，接收端就在临界值附近赌博。

一句话：**位劈要求 CPU 在整个 68ms 的帧期间独占式精确，RTOS 的抽象恰好不承诺这件事**。关中断硬扛可以做到，但那是把整个系统按住 68ms——音频立刻爆音，这条路在产品里走不通。

### 3. RMT 的回答：把波形表交给硬件

RMT 全称 **Remote Control Transceiver**（红外遥控收发器）——名字直接说明了出身：它就是乐鑫为红外遥控专门做的外设。设计思想一句话：

> CPU 只准备一张"电平-时长"序列表（每个条目：高电平 N 滴答、低电平 M 滴答），RMT 硬件按自己的时钟逐条执行，执行完发中断通知 CPU。载波调制/解调也在硬件里完成。

CPU 从"微秒级的执行者"变成"毫秒级的准备者和善后者"，时序精度与调度器解耦。同一个思想换个场景就是 LED 灯带（WS2812）、步进电机脉冲、蜂鸣器乐谱——IDF 的 RMT 示例目录里这四类都有，红外只是它的本行。

### 4. 本章的硬件对象：SENSOR 板红外三引脚

从 `esp-box/components/bsp/include/bsp_board.h`（实地读取）反查 BOX-3 的红外硬件事实：

| 宏                 | 值      | 含义                               |
| ------------------ | ------- | ---------------------------------- |
| `BSP_IR_TX_GPIO`   | GPIO 39 | 红外发射管驱动脚（RMT TX 输出）    |
| `BSP_IR_RX_GPIO`   | GPIO 38 | 红外接收头输出脚（RMT RX 输入）    |
| `BSP_IR_CTRL_GPIO` | GPIO 44 | 红外发射使能脚，**低电平允许发射** |

第三行来自 factory_demo 的用法（`examples/factory_demo/main/gui/ui_sensor_monitor.c`）：发射前把 GPIO44 配成输出并 `gpio_set_level(BSP_IR_CTRL_GPIO, 0)`，注释写着 `//enable IR TX`——发射管不是常供电的，这是一个省电/防误触发设计。忘了拉这根线，波形发得再标准也出不了管子（翻车点表见 12.8）。

---

## 12.2 L1：新版驱动 API——通道、符号、编码器、异步事务

ESP-IDF v5 起驱动按"面向对象 + 回调"重构，v6 延续：`driver/rmt_tx.h`、`driver/rmt_rx.h` 各管一半，公共部分在 `driver/rmt_common.h`（头文件均已实地读取）。

### 1. 通道创建：rmt_new_tx_channel / rmt_new_rx_channel

TX 通道配置 `rmt_tx_channel_config_t` 的关键字段：

| 字段                | 本项目取值                      | 说明                                             |
| ------------------- | ------------------------------- | ------------------------------------------------ |
| `gpio_num`          | 39                              | BSP_IR_TX_GPIO                                   |
| `clk_src`           | `RMT_CLK_SRC_DEFAULT`（即 APB） | 同组通道必须同源                                 |
| `resolution_hz`     | 1 MHz                           | **1 滴答 = 1us**，NEC 所有数字以 us 书写、零换算 |
| `mem_block_symbols` | 128                             | 通道可缓存的符号数（见下文与 L2/L3 的内存账）    |
| `trans_queue_depth` | 4                               | 后台可排队的事务数                               |

RX 通道 `rmt_rx_channel_config_t` 结构类似（GPIO38、同样 1MHz），但没有队列深度——RX 是"一次装填一次接收"。创建后须 `rmt_enable()` 才能用。

### 2. rmt_symbol_word_t：硬件的原子单位

RMT 内存里存的东西只有一种——**符号**（`rmt_symbol_word_t`，定义在 `components/esp_hal_rmt/include/hal/rmt_types.h`），一个 32bit 字装两段"电平+时长"：

```c
typedef union {
    struct {
        uint16_t duration0 : 15; /*!< Duration of level0 */
        uint16_t level0 : 1;     /*!< Level of the first part */
        uint16_t duration1 : 15; /*!< Duration of level1 */
        uint16_t level1 : 1;     /*!< Level of the second part */
    };
    uint32_t val;
} rmt_symbol_word_t;
```

1MHz 分辨率下，一个符号最多表达"高 32.767ms + 低 32.767ms"——NEC 最长的引导码 9ms+4.5ms 单符号装得下。NEC 帧的一个 bit 恰好一个符号（高 560 + 低 560/1690），硬件与协议在这里严丝合缝。发射结束符约定 `duration1 = 0x7FFF`。

### 3. 编码器：谁来把应用数据变成符号

`rmt_transmit()` 的入参不是符号，而是任意 payload——转换交给**编码器**（`driver/rmt_encoder.h` 的 `rmt_encoder_t` 接口，三个函数指针：`encode`/`reset`/`del`）。驱动内置两个最常用的：

- **copy_encoder**（`rmt_new_copy_encoder`）：payload 已是 `rmt_symbol_word_t` 数组，原样拷进 RMT 内存。"学习-回放"场景的正解——学到的就是符号，回放时不需要还原成协议再编一次。
- **bytes_encoder**（`rmt_new_bytes_encoder`）：配置 `bit0`/`bit1` 两个符号模板，把字节流按位展开。NEC 的 32bit 数据位用它，一个字节 8 个符号。

真正的 NEC 帧还需要引导码、结束码——官方示例 `examples/peripherals/rmt/ir_nec_transceiver/main/ir_nec_encoder.c` 演示了组合术：自定义编码器内部持有一个 copy_encoder（发引导/结束码）+ 一个 bytes_encoder（发数据位），`encode` 里用一个四状态机依次驱动两个子编码器。这个"组合子"模式值得抄——步进电机、DShot 电调示例的编码器同构。

### 4. rmt_transmit 的异步语义：发起即返回

`rmt_transmit()` 只是把事务描述符压进内部队列（`trans_queue_depth` 深度，队列满时按 `queue_nonblocking` 决定阻塞还是返回），**不等发送完成**。两个直接推论：

1. **payload 在完成前不许动**——头文件注释原话："You CAN'T modify the payload during the transmission"。传栈上数组的后果是发出去的后半帧是栈垃圾。
2. 完成通知走 `on_trans_done` 回调——**它在 ISR 环境执行**（头文件注释明言），所以回调里只能做 ISR-safe 的事：`xQueueSendFromISR`、任务通知（`vTaskNotifyGiveFromISR`），把数据转交任务层。这正是第八章 GPIO 中断建立的"ISR 快进快出 + 唤醒任务"模式；任务通知机制本身在 [[ch13-task-notifications|FreeRTOS（十三）任务通知]]拆过。

不想要回调也可以阻塞等：`rmt_tx_wait_all_done(tx_chan, -1)` 等全部排空。factory_demo 的回放路径用的就是这招（12.6 节）。

### 5. 载波与接收配置

- **载波**：`rmt_apply_carrier()` 一行配好 38kHz、占空比 1/3，调制由硬件完成——CPU 和符号表里都不出现载波（L3 展开）。
- **接收**：`rmt_receive()` 也是异步发起，两个阈值是关键参数：`signal_range_min_ns`（比这短的脉冲当毛刺滤掉）和 `signal_range_max_ns`（比这长的电平视为帧结束，触发接收完成）。官方 NEC 示例取 `1250ns / 12000000ns`——下限远小于最短有效脉冲 560us，上限大于最长脉冲 9ms，留裕量的逻辑一目了然。

---

## 12.3 L2：esp_driver_rmt 源码走读

组件在 v6 里拆成两层：`components/esp_driver_rmt/`（驱动策略层）+ `components/esp_hal_rmt/`（寄存器抽象层，含各芯片 `rmt_ll.h`）。走读三条主线。

### 1. 符号内存：通道间可以"吞地"

S3 的 RMT 内存不是每通道私有等分，而是**公共块池**：8 个通道各配 1 个 48 字块，但一个通道可以申请连续多个块（`rmt_tx_register_to_group`，`src/rmt_tx.c`）：

```c
// one channel can occupy multiple memory blocks
mem_block_num = config->mem_block_symbols / SOC_RMT_MEM_WORDS_PER_CHANNEL;
if (mem_block_num * SOC_RMT_MEM_WORDS_PER_CHANNEL < config->mem_block_symbols) {
    mem_block_num++;
}
// search free channel and then register to the group
// memory blocks used by one channel must be continuous
uint32_t channel_mask = (1 << mem_block_num) - 1;
```

分配在组级 `occupy_mask` 位图上找**连续**空位，占了几块，相邻通道就整体不可用（源码注释："a channel can take up its neighbour's memory block, so the neighbour channel won't work"）。算一笔账：factory_demo 的 TX 通道 `mem_block_symbols = 128` → 128/48 = 2.67 → 向上取整 **3 块**——4 个 TX 通道的块池一下吃掉 3 个，再建第二个大 TX 通道大概率 `ESP_ERR_NOT_FOUND: no free tx channels`。符号内存是稀缺资源，不是"配大点保险"的免费参数。

ping-pong 是这套内存的运作方式：块池对半分成两翼，硬件发/收一翼的同时驱动搬运另一翼，`ping_pong_symbols` 就是单翼容量（`mem_block_num * 48 / 2`）。TX 的"交替中断连续编码"、RX 的长帧接收都建立在它上面。

### 2. RX 的滤波与阈值：两个参数对应两处硬件

`rmt_receive()` 把 ns 换算成滴答写进两类寄存器（`src/rmt_rx.c`）：

```c
uint32_t filter_reg_value = ((uint64_t)rx_chan->filter_clock_resolution_hz
                             * config->signal_range_min_ns) / 1000000000UL;
ESP_RETURN_ON_FALSE_ISR(filter_reg_value <= RMT_LL_MAX_FILTER_VALUE, ...);
rmt_ll_rx_set_filter_thres(hal->regs, channel_id, filter_reg_value);
rmt_ll_rx_enable_filter(hal->regs, channel_id, config->signal_range_min_ns != 0);
```

- `signal_range_min_ns` → **滤波器阈值寄存器**：小于它的输入脉冲直接丢弃。S3 上限 `RMT_LL_MAX_FILTER_VALUE = 255` 滴答（滤波计数时钟走组分辨率，1MHz 下即 255us）——把 min 设得超过它，驱动直接报 `signal_range_min_ns too big`。
- `signal_range_max_ns` → **接收超时（idle threshold）**：电平持续超过它，硬件判定帧结束，产生 RX_DONE 事件。设小了真实帧被腰斩，设大了帧结束迟迟判定不了。

### 3. 中断与回调派发：数据的搬运工

RX 完成的完整路径（`rmt_isr_handle_rx_done`，`src/rmt_rx.c`）值得逐行看，因为它是"硬件缓冲到用户缓冲"的全部距离：

1. 清中断，**关掉 RX 引擎**（下次 `rmt_receive()` 再开）；
2. 切内存所有权 `MEM_OWNER HW → SW`，`memcpy` 把符号从 RMT 块搬到用户 buffer，再切回 `HW`——全程 `portENTER_CRITICAL_ISR` 保护；
3. 用户 buffer 不够则截断（`user buffer too small, received symbols truncated`，partial 模式下会提前分批回调，`is_last` 标志区分）；
4. 调用 `on_recv_done` 回调；**回调返回 true 表示唤醒了高优先级任务**，驱动据此让 ISR 出口做 `portYIELD_FROM_ISR`——与 FreeRTOS 系列第十三/十七章讨论的"从 ISR 安全交还调度"完全同一个约定。

TX 侧对称：TX threshold 中断里驱动继续调 encoder 的 `encode()` 往另一翼写符号（所以编码器函数必须非阻塞、建议 IRAM），最后一个事务的 tx_done 中断里回调 `on_trans_done`。另外 `rmt_enable()` 会**获取 PM 锁**、`rmt_disable()` 释放——这是 DFS 环境下时序不塌方的制度保证（L3 展开）。

---

## 12.4 L3：S3 的 RMT 外设规格

以 IDF 的芯片能力头文件为准（`soc_caps.h`、`esp32s3/include/hal/rmt_ll.h`、`soc/clk_tree_defs.h`，实地读取；与 TRM 的 RMT 章一致）：

| 项目         | ESP32-S3 的值                                                                | 出处                                   |
| ------------ | ---------------------------------------------------------------------------- | -------------------------------------- |
| 通道总数     | 1 组 8 通道：**4 TX + 4 RX**（通道方向固定，不可换向）                       | `RMT_LL_TX/RX_CANDIDATES_PER_INST = 4` |
| 符号内存     | 每通道 48 字（`SOC_RMT_MEM_WORDS_PER_CHANNEL = 48`），块池共享可吞并（12.3） | `soc_caps.h:249`                       |
| 时钟源       | APB（默认）/ RC_FAST / XTAL                                                  | `SOC_RMT_CLKS`                         |
| 分频         | 组级 × 通道级两级预分频，各 ≤256                                             | `rmt_ll.h:55-57`                       |
| RX ping-pong | 支持（`SOC_RMT_SUPPORT_RX_PINGPONG`）                                        | `soc_caps.h:250`                       |
| TX 循环      | 支持指定次数循环 + 自动停止                                                  | `soc_caps.h:251-252`                   |
| DMA          | 支持（`SOC_RMT_SUPPORT_DMA`），内存瓶颈可绕开                                | `soc_caps.h:253`                       |
| RX 解调      | 支持（`RMT_LL_SUPPORT_RX_DEMODULATION = 1`）                                 | `esp32s3/rmt_ll.h:35`                  |

三个对红外项目直接相关的推论：

1. **两级分频决定 resolution_hz 的自由度**。APB 80MHz 组级先分、通道级再分；1MHz 这种整数倍轻松命中。factory_demo 与官方示例统一用 1MHz（"1 tick = 1us"），本章沿用。
2. **APB + DFS 的坑被 PM 锁兜住**。BOX-3 开着 DFS（第四章 sdkconfig.defaults 里的 `CONFIG_PM_DFS_INIT_AUTO`），CPU 降频时 APB 跟着变，RMT 的"滴答"就会漂移。驱动在 `rmt_enable()` 拿 APB 频率锁，事务期间频率焊死——文档"电源管理"节的原话是"在这两个函数之间的任何 RMT 事务都可以保证正常工作"。所以**通道常开的代价是锁常持**，factory_demo 的做法是用完即 `rmt_disable()`（见 12.6 源码）。
3. **载波调制/解调是硬件功能，不走 CPU**。TX 侧 `rmt_apply_carrier(38kHz, 0.33)` 配置的是 `chncarrier_duty` 等寄存器，输出级把基带信号与载波相与；符号表里只写 9ms/560us 这些**基带时长**。RX 侧同样可在硬件里先解调再测量。文档有个反直觉提醒：RX 解调频率别配理论值——空中反射折射会让载波失真，官方例子配 25kHz 去收 38kHz 的信号，靠解调带宽容差兜底。

---

## 12.5 L4：NEC 帧波形精读

> [!note] 时序数字来源
> 本节 NEC 数值以 SB-Projects IR Knowledge Base（sbprojects.net/knowledge/ir/nec.php，2026-08-26 抓取核实）为准，并与本地 IDF 官方示例常量（`examples/peripherals/rmt/ir_nec_transceiver/main/ir_nec_transceiver_main.c`）交叉对照，两处一致才写入。示意图按协议规范绘制，**非实测波形**——实测见本节末尾。

### 1. 数字总表

| 段     | 时长                                                    | 说明                                   |
| ------ | ------------------------------------------------------- | -------------------------------------- |
| 载波   | 38 kHz，占空比 1/4~1/3                                  | 560us 突发 ≈ 21 个载波周期             |
| 引导码 | **9ms 载波突发 + 4.5ms 停歇**                           | AGC burst + header                     |
| 逻辑 0 | 560us 突发 + ~560us 停歇（共 1.125ms）                  | 距离调制：时长编码                     |
| 逻辑 1 | 560us 突发 + ~1690us 停歇（共 2.25ms）                  |                                        |
| 帧结构 | 地址 8b + 地址反 8b + 命令 8b + 命令反 8b，**LSB 先发** | 反码用于校验                           |
| 帧尾   | 560us 突发                                              | 停止位                                 |
| 重复码 | 9ms + 2.25ms + 560us                                    | 按键按住时每 ~110ms 发一次，不重发整帧 |

标准帧 = 1 引导 + 32 数据 + 1 停止 = **34 个 RMT 符号**；重复码 = **2 个符号**。官方示例解码就按 `symbol_num == 34 / == 2` 分诊，判定容差 ±200us。

### 2. 波形图：载波放大 + 基带包络

载波视角（发射管上实际的东西，38kHz、1/3 占空）：

```text
            ┌─┐   ┌─┐   ┌─┐   ┌─┐   ┌─┐   ┌─┐        ┌─┐
            │ │   │ │   │ │   │ │   │ │   │ │   ...  │ │   ... (约21个周期)
        ────┘ └───┘ └───┘ └───┘ └───┘ └───┘ └────────┘ └─────── ...
            |<-------------- 560us 载波突发 ------------>|
```

基带包络视角（RMT 符号描述的层，也是接收头解调后输出的层）：

```text
        ┌──────────────┐                    ┌─────┐      ┌─────┐   ┌────┐
        │   9.000ms    │      4.500ms       │560us│      │560us│   │560us│   ← 停止位
    ────┘  (载波突发)  └────────────────────┘     └──────┘     └─...─┘    └────→
        |<---- 引导码 --------->|                 bit=0        bit=?
                                                    |1.125ms|  |2.25ms → bit=1
                                                   (560+560)   (560+1690)

        帧尾: ...最后一个bit ─┬─ 560us 突发 ─┬─ 长停歇(下一帧或空闲)
                              └─ 停止位 ──────┘

        重复码（按住按键）:
        ┌──────────────┐            ┌─────┐
        │   9.000ms    │  2.250ms   │560us│        每 ~110ms 一发
    ────┘              └────────────┘     └──────
```

还有一个所有实做都会撞上的细节：**接收头输出是反相的**。IRM-3638T 这类一体化接收头内部带解调器，检测到载波时输出**低**电平。所以逻辑分析仪在 GPIO38 上看到的是上图的镜像（引导码是 9ms 的**低**），RMT 收到的符号 `level0/level1` 也随之翻转——这就是官方示例的 NEC 解析函数**只比对 duration0/duration1、完全不看 level** 的原因：时长才是信息，极性随接收头硬件走。

### 3. 逻辑分析仪实测步骤

> [!warning] 待真机验证
> 以下为按系列装备约定（24MHz 8 通道分析仪 + PulseView）设计的操作步骤，尚未在真机执行，波形截图待补：
>
> 1. 杜邦线接 SENSOR 板红外接收头输出到分析仪通道 0（若 SENSOR 板未引出测试点，从 GPIO 38 的 DOCK 引出点就近取）；
> 2. PulseView 采样率 1MSa/s 足够看基带包络（9ms/4.5ms 量级）；想看 38kHz 载波细节需 ≥5MSa/s，24MHz 上限内随意；
> 3. 任意家电遥控器对准接收头按键，采集一段；
> 4. 预期（依协议）：看到 9ms 低 + 4.5ms 高开头的包络序列，测量第一个数据 bit 的高/低时长应落在 560±容差 / 560 或 1690±容差 附近；
> 5. 用 12.6 的 TX 代码从 GPIO39 发码，对比"自制波形"与"遥控器波形"的逐段时长差异。

---

## 12.6 实验：发一枚电源码 + 学习模式

### 1. 实验 A：NEC 发码（代码骨架）

综合本章事实（GPIO39/44、38kHz 载波、1MHz 分辨率、NEC 编码器组合）的发送骨架。协议部分直接沿用官方示例（编码器同 `ir_nec_encoder.c`，时序常量同 12.5 节）：

```c
#include "driver/rmt_tx.h"
#include "driver/gpio.h"

#define IR_RESOLUTION_HZ 1000000   // 1MHz, 1 tick = 1us（factory_demo 同款）

void ir_send_nec_power_key(void)
{
    /* 1. 使能发射管（SENSOR 板的省电开关，忘这步必翻车） */
    gpio_config_t io = {
        .pin_bit_mask = BIT64(44),     /* BSP_IR_CTRL_GPIO */
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = true,
    };
    gpio_config(&io);
    gpio_set_level(44, 0);             /* 低电平 = enable IR TX */

    /* 2. TX 通道 + 硬件载波 */
    rmt_tx_channel_config_t tx_cfg = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .gpio_num = 39,                /* BSP_IR_TX_GPIO */
        .resolution_hz = IR_RESOLUTION_HZ,
        .mem_block_symbols = 128,      /* 占 3 个 48 字块（12.3 的账） */
        .trans_queue_depth = 4,
    };
    rmt_channel_handle_t tx_chan = NULL;
    ESP_ERROR_CHECK(rmt_new_tx_channel(&tx_cfg, &tx_chan));

    rmt_carrier_config_t carrier = {
        .frequency_hz = 38000,         /* NEC 载波 */
        .duty_cycle = 0.33,
    };
    ESP_ERROR_CHECK(rmt_apply_carrier(tx_chan, &carrier));

    /* 3. NEC 编码器：copy(引导/结束) + bytes(数据位) 的组合（官方示例结构） */
    rmt_encoder_handle_t nec_encoder = NULL;
    ir_nec_encoder_config_t enc_cfg = { .resolution = IR_RESOLUTION_HZ };
    ESP_ERROR_CHECK(rmt_new_ir_nec_encoder(&enc_cfg, &nec_encoder));

    ESP_ERROR_CHECK(rmt_enable(tx_chan));

    /* 4. 发射：payload 是 {address, command}，异步入队后阻塞等完成 */
    const ir_nec_scan_code_t code = {
        .address = 0x00FF,             /* TODO: 换成目标设备地址码 */
        .command = 0x00FD,             /* TODO: 换成目标设备电源键码 */
    };
    rmt_transmit_config_t tx = { .loop_count = 0 };
    ESP_ERROR_CHECK(rmt_transmit(tx_chan, nec_encoder, &code, sizeof(code), &tx));
    ESP_ERROR_CHECK(rmt_tx_wait_all_done(tx_chan, -1));

    /* 5. 用完即关：释放 PM 锁、还回内存块 */
    rmt_disable(tx_chan);
    rmt_del_channel(tx_chan);
}
```

> [!warning] 待真机验证
> 地址/命令码因设备而异（从设备手册查，或用实验 B 的接收端学出来）；本骨架尚未在真机编译烧录验证，`TODO` 处的码值、以及目标设备是否响应，需真机确认。RX 侧骨架（GPIO38 + `signal_range_min_ns=1250` / `max_ns=12000000` + `on_recv_done` 回调入队解码）与官方 `ir_nec_transceiver_main.c` 一致，不再重复贴。

### 2. 实验 B 思路：学习模式——不解码，存波形

对着未知协议的遥控器（很多空调是私有协议），逐协议手写解码不现实。**学习模式的正解是绕过协议层**：把接收到的原始 RMT 符号连同帧间间隔存下来，回放时用 copy_encoder 原样吐回去。协议识别留给被控设备，我们只当"波形复读机"。

factory_demo 用的就是乐鑫注册表组件 `espressif/ir_learn`（`main/idf_component.yml` 里 `espressif/ir_learn: ^0.1.0`；本地 managed_components 无源码）。其能力经组件注册表页（components.espressif.com/components/espressif/ir_learn，2026-08-26 抓取）核实：

- 基于 RMT 的红外**学习**组件，接收分析 **38kHz 载波**信号；
- 保存/转发**原始时序数据**——官方 README 明言"暂不支持具体红外协议解析"（不做 NEC/RC5 解码），与上面的"复读机"思路互为印证；
- 文档建议接收头 IRM-3638T、发射管 IR333C；支持 ESP32/S2/S3/C3/C6/H2；Apache-2.0；注册表最新版 1.0.1（factory_demo 钉的是 ^0.1.0）；
- 完整 API 文档在 esp-iot-solution（docs.espressif.com/projects/esp-iot-solution，`ir/ir_learn.html`）。

factory_demo 对它的用法（`ui_sensor_monitor.c` 实地读取）恰好是一份"学习-存储-回放"参考设计：

1. **学习**：`ir_learn_new` 配置 `learn_count = 4`（要求用户按 4 次键、两两采开/关码）、`learn_gpio = BSP_IR_RX_GPIO`、内部任务栈 4096/优先级 5/绑核 1；结果经状态机回调逐段上交（`IR_LEARN_STATE_READY/STEP/END/FAIL`）；
2. **存储**：学到的是 `rmt_rx_done_event_data_t` 原始符号，逐帧写进 SPIFFS 文件——文件格式就是朴素的 `num_symbols + 符号字数组`（`ir_learn_read_cfg` 的读码逻辑可反推）；
3. **回放**：读回符号 → 组件附带的 `ir_encoder_new` 编码器（内部是 copy 型）→ `rmt_transmit` + `rmt_tx_wait_all_done`，帧间用 `vTaskDelay` 复现学习时的 `timediff`——**连帧间隔都在复读**，兼容性因此出奇地好。

源码走读还捎出一个反面教材：该文件里 `POWER_ON_PATH` 与 `POWER_OFF_PATH` 两个宏**指向同一个文件名** `my_learn_off.cfg`（第 24-25 行，疑似复制粘贴笔误）——开关两组学习码会互相覆盖。写自己的存储层时，给每个键位独立文件/键名，别重蹈。

---

## 12.7 取舍：软件方案 vs RMT 方案

| 维度     | 软件（定时器/位劈）                              | RMT 硬件                                         |
| -------- | ------------------------------------------------ | ------------------------------------------------ |
| 时序精度 | 受调度抖动支配；关中断可精确但绑架系统           | 滴答级精确（1MHz 下 1us），与调度解耦            |
| CPU 占用 | 整帧期间逐 bit 服务                              | 每翼一次中断；DMA 模式更低                       |
| 载波     | 38kHz 载波也得软件劈（每 26us 翻转）——基本不可行 | 硬件调制，符号表里只有基带时长                   |
| 并发友好 | 差：抢占即畸变                                   | 好：可与音频/网络任务共存                        |
| 资源代价 | 零外设                                           | 占通道 + 符号内存块（48 字/块，稀缺）；PM 锁常持 |
| 灵活性   | 任意改动，易于实验                               | 帧长受内存限制；超长帧需 DMA 或 partial RX       |
| 适用     | 裸机、单功能、演示                               | RTOS、多任务、产品                               |

软件定时器这条路单独说一句：它的回调由**定时器守护任务**执行，排队长短随系统负载变化，抖动量级远超 NEC 的 ±200us 容差——机制细节见 [[ch15-software-timers-daemon|FreeRTOS（十五）软件定时器]]，本章 12.1 的分析在那里有源码级答案。结论：**在 BOX-3 这类多任务系统里，红外收发没有悬念地属于 RMT**；软件方案的价值是帮你理解协议本身。

---

## 12.8 翻车点表与小结

| 症状                                       | 根因                                                                         | 处理                                                                                                         |
| ------------------------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| 波形"看起来"正常，设备毫无反应             | 载波频率配错（非 38kHz），接收头解调带外直接无视                             | 核对 `rmt_apply_carrier` 的 `frequency_hz`；逻辑分析仪测发射管实际周期                                       |
| 同上，但载波正确                           | GPIO44（IR_CTRL）没拉低，发射管根本没上电                                    | 发射前 `gpio_set_level(BSP_IR_CTRL_GPIO, 0)`（12.1/12.6）                                                    |
| 波形正常、距离稍远就失灵                   | 发射管驱动电流不足：GPIO 直驱能力有限，没有三极管放大时辐射距离很短          | SENSOR 板已有驱动电路的前提下确认 CTRL 电平；自制电路需加驱动管（描述性结论，具体电流参数待真机/原理图核对） |
| RX 收不到任何东西                          | `signal_range_min_ns` 设太大，真实信号被滤波器当毛扔掉；S3 上限 255 滴答     | min 从小往大调（官方取 1250ns）；对照 `signal_range_min_ns too big` 报错                                     |
| RX 只收到半帧                              | `signal_range_max_ns` 小于帧内最长电平（9ms），提前判帧结束                  | max 取大于最长电平的值（官方取 12ms）                                                                        |
| 长帧尾部是垃圾/截断告警                    | 通道符号内存或用户 buffer 不够：非 ping-pong 芯片硬截断，S3 上是 buffer 太小 | 加大 `mem_block_symbols`（吃连续内存块）或用户 buffer；超长帧用 `with_dma` 或 `en_partial_rx`                |
| 第二个 TX 通道创建失败 `ESP_ERR_NOT_FOUND` | 第一个通道吞了 3 个 48 字块，块池枯竭（12.3）                                | 缩小 `mem_block_symbols`；或砍通道数量；或 DMA                                                               |
| 发射期间系统莫名不许降频/耗电高            | `rmt_enable()` 拿的 PM 锁在事务期间钉死 APB 频率                             | 用完 `rmt_disable()`（factory_demo 同款纪律）                                                                |
| 回放学到的码，设备不认                     | payload 数组在事务完成前被改/释放（异步语义）                                | `rmt_tx_wait_all_done` 后再动 buffer；或改堆分配并延迟回收                                                   |
| 学习的"开/关"码互相覆盖                    | 存储 key 撞名（factory_demo 的同名文件笔误，12.6）                           | 每个键位独立文件/NVS key                                                                                     |

本章小结：

- **红外的信息在时长里**，NEC 用 560us 基准 + 距离调制编码 bit；这类微秒级时序在 RTOS 下不能交给任务/软件定时器——调度抖动与 DFS 都会咬掉容差。RMT（Remote Control Transceiver）把"电平-时长表"下沉到硬件执行，CPU 退居准备者。
- **L1**：新版 API 三件事——通道（`rmt_new_tx/rx_channel`，1MHz 分辨率让所有数字以 us 直书）、符号（`rmt_symbol_word_t` 两段 15+1bit）、编码器（copy 回放波形 / bytes 展开 bit / 组合成 NEC 编码器）；`rmt_transmit`/`rmt_receive` 都是异步发起，完成走 ISR 回调 → 队列/任务通知，与第八章的 ISR 模式同构。
- **L2**：符号内存是块池不是私产——128 符号吃 3 个连续 48 字块；RX 的 min/max 两个 ns 参数分别落到滤波器和超时寄存器（255 滴答上限）；RX_DONE 中断里完成"所有权切换 + memcpy + 回调"，回调返回值就是 `portYIELD_FROM_ISR` 的开关。
- **L3**：S3 给了 4 TX + 4 RX、每通道 48 字、APB/RC_FAST/XTAL 三源两级分频；载波调制解调在硬件里；DFS 环境靠 `rmt_enable` 的 PM 锁保时序，代价是常开常耗电。
- **L4**：NEC 帧 = 9ms+4.5ms 引导 + 34/2 符号 + 110ms 重复码；接收头输出反相，解码只看时长不看电平。逻辑分析仪实测待真机验证后补图。
- **实验**：发码骨架齐备（GPIO39/44 + 38kHz + 1MHz）；学习模式"存波形不解码"由 `espressif/ir_learn` 组件承担，factory_demo 提供了学习-存储-回放全套参考实现。

下一章从"RMT 的滴答"上升到时间体系本身：esp_timer 的实现位置、任务看门狗为什么会咬高优先级忙等、LEDC 与 RMT 的分工——第十三章把 BOX-3 的时间地基讲完。
