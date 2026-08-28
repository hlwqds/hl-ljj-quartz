---
title: "ESP32-S3-BOX-3 工程实战（九）：I2C 与传感器"
date: 2026-08-26 12:00:00
description: "从两根开漏线讲到一串命令链：I2C 协议本体（线与、START/地址帧/ACK）、v6 新驱动 i2c_master 的总线-设备模型（L1）、esp_driver_i2c 源码里的传输队列/三层超时/SCL 卡死恢复（L2）、S3 双控制器与 8 条命令寄存器、GPIO Matrix 任意路由（L3）、逻辑分析仪上一次 AHT20 读温湿度的完整总线流程与 PulseView 解码（L4）；实验扫遍 BOX-3 两条 I2C 总线，顺带给第八章遗留的触摸型号疑案定案。"
tags: [esp32, esp32-s3, esp-idf, series]
---

# ESP32-S3-BOX-3 工程实战（九）：I2C 与传感器

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[2026-08-26-esp32-s3-box-3-hands-on-series-index|系列索引]]
> 上一章：[[2026-08-26-esp32-s3-box-3-ch8-gpio-interrupts|第八章：GPIO 与中断]]
> **第九章：I2C 与传感器**（当前章）
> 下一章：[[2026-08-26-esp32-s3-box-3-ch10-spi-display|第十章：SPI 与屏幕]]

第八章留了一个悬案：系列索引记载触摸是 FT6336，但 BSP 源码里探测的是 GT911/TT21100。I2C 总线扫描是这类问题的终极裁判——地址骗不了人。本章先讲清 I2C 协议本体，再按四层下钻走完驱动 API → esp_driver_i2c 源码 → S3 控制器 → 总线波形，最后用扫描实验把 BOX-3 上两条 I2C 总线的住户全部点名。esp-idf 源码引用均为本地实地读取（v6.0.2，`components/esp_driver_i2c`、`esp_hal_i2c`、`soc`，行号以当前工作副本为准）；esp-box-3 BSP 与 AHT20 组件源码不在本地（managed_components 未下载），经 GitHub 官方仓库核对，文中注明来源。

---

## 9.1 协议本体：两根线怎么扛住一串设备

I2C（Inter-Integrated Circuit）用两根线挂多个设备：SDA（数据）与 SCL（时钟）。它能这么省引脚，靠的是一个电气约定——**两根线都是开漏输出 + 上拉电阻**：

```text
        VCC
         │
        [R] 上拉（1k~10k，越大边沿越缓）
         │
   ──────┴────── SDA 总线
    │       │        │
  主机    从机A     从机B
 (开漏)  (开漏)   (开漏)

  谁都不拉 → 线为高（"1"，空闲态）
  任何一个拉低 → 线为低（"0"）        ← 这叫"线与"（wired-AND）
```

为什么必须是开漏而不是推挽？三个理由，每个都对应一个真实机制：

1. **防电气冲突**：推挽输出一个输出高、一个输出低就是电源到地短路；开漏只能"拉低或放手"，多设备共用安全。
2. **多主仲裁**：两个主机同时发起传输时，都边发边读回比较，发现"我发 1 却读到 0"的一方自动退出——线与天然支持。
3. **从机时钟拉伸（clock stretching）**：从机来不及处理时可以把 SCL 拉低扣住时钟，主机必须等。这也是后文超时参数要按"从机可能拉伸很久"来配的原因。

数据在时钟上的摆放规则一句话：**SCL 低电平期间 SDA 允许翻转，SCL 高电平期间必须稳定**。START/STOP 是这条规则的例外，也正是用例外来编码的：

```text
普通数据位:                 START 条件:              STOP 条件:
              ____                        ___          ___
SDA  ‾‾‾\____/‾‾‾        SDA ‾‾‾\        SDA      ____/‾‾‾
          ^  ^                      ^                 ^
SCL  ‾‾‾‾‾‾‾‾‾‾‾‾        SCL ‾‾‾‾‾‾‾‾‾‾    SCL ‾‾‾‾/‾‾‾‾‾‾‾‾
          稳定窗口                 SCL 高时降           SCL 高时升
```

一次完整传输的帧结构（7 位地址模式）：

```text
[START] [A6 A5 A4 A3 A2 A1 A0] [R/W] [ACK] [D7..D0] [ACK] ... [STOP]
   ↑         7bit 从机地址       ↑    ↑      ↑        ↑
 主机发      主机发             1=读   从机回   数据字节   收方回
                              0=写   (SDA拉低)  (方向看R/W)
```

三处细节值得抠：

- **地址后的 ACK 是从机发的**——这是"这个地址有人吗"的应答，NACK（不拉低）就是"查无此人"。9.6 的总线扫描就靠它。
- **读方向的最后一个字节主机回 NACK**——告诉从机"别再发了，我要收摊了"，然后发 STOP。驱动里这是两条硬件命令（9.3 节会在源码里再见到它）。
- **RESTART**：不发 STOP 直接再来一个 START，用于"先写寄存器地址再读数据"的组合事务——写读之间总线控制权不释放，防止多主环境下被插队。AHT20 的读法用的就是"写事务 + STOP + 延时 + 读事务"的松散版本（传感器测量需要时间，中间必须释放总线）。

速度档位两档就够用：**标准模式 100 kHz、快速模式 400 kHz**（IDF 文档明言主机 SCL 不应超过 400 kHz）。BOX-3 的 BSP 默认走 400 kHz（9.6 节核实）。频率上不去时的第一嫌疑人是上拉电阻与线电容——电阻越大 RC 越大、边沿越缓，文档建议 1 kΩ~10 kΩ（常用 2.2 kΩ~4.7 kΩ）。

---

## 9.2 L1 应用 API：i2c_master 的总线-设备模型

v6 的 I2C 主机驱动在 `driver/i2c_master.h`（本地实地读取），核心是**两级句柄**：先建总线（控制器+引脚），再往总线上挂设备（地址+速率）。每个设备可以有不同速率——换设备谈话时驱动会重配时序（9.3 节源码证据）。

```c
#include "driver/i2c_master.h"

/* BOX-3 SENSOR 板扩展总线（真实参数，来源见 9.6 拓扑表） */
i2c_master_bus_config_t bus_cfg = {
    .i2c_port = 0,                      /* -1 为自动分配空闲控制器 */
    .sda_io_num = 41,                   /* GPIO41 */
    .scl_io_num = 40,                   /* GPIO40 */
    .clk_source = I2C_CLK_SRC_DEFAULT,
    .glitch_ignore_cnt = 7,             /* 滤掉 <7 个模块时钟周期的毛刺 */
    .flags.enable_internal_pullup = false, /* SENSOR 板有外部上拉 */
};
i2c_master_bus_handle_t bus;
ESP_ERROR_CHECK(i2c_new_master_bus(&bus_cfg, &bus));

i2c_device_config_t dev_cfg = {
    .dev_addr_length = I2C_ADDR_BIT_LEN_7,
    .device_address = 0x38,             /* AHT20，7bit 裸地址，不带 R/W 位 */
    .scl_speed_hz = 400000,
    .scl_wait_us = 0,                   /* 0 = 用默认 SCL 超时 */
};
i2c_master_dev_handle_t aht20;
ESP_ERROR_CHECK(i2c_master_bus_add_device(bus, &dev_cfg, &aht20));
```

四个传输函数覆盖所有常见姿势：

| API                           | 总线上的动作                               | 典型设备行为               |
| ----------------------------- | ------------------------------------------ | -------------------------- |
| `i2c_master_transmit`         | START+地址W+数据+STOP                      | 写寄存器、发命令           |
| `i2c_master_receive`          | START+地址R+读N字节(末字节NACK)+STOP       | 直接读（地址自增的传感器） |
| `i2c_master_transmit_receive` | START+地址W+数据+**RESTART**+地址R+读+STOP | "写寄存器地址→读值"两连击  |
| `i2c_master_probe`            | START+地址W+STOP                           | 探测设备存在（9.6 扫描用） |

错误码语义（头文件注释原文核对）：`ESP_ERR_INVALID_RESPONSE` = 收到 NACK（地址没 人应答或从机拒收）；`ESP_ERR_TIMEOUT` = 总线忙/硬件异常超时；`ESP_ERR_NOT_FOUND` = probe 没找到该地址的设备。

> [!warning] 新旧驱动不要混用
> esp-box 仓库自己的 BSP（`components/bsp/src/boards/esp32_bsp_sensor.c:263-266`，本地实地读取）用的还是**旧版** `i2c_param_config()` + `i2c_driver_install()`——因为 esp-box 的 CI 要兼容 IDF 5.1 起的多个版本，而新驱动是 5.2 引入、v6 全面主推的（旧 API 在 v6 头文件注释里明确标注 deprecated）。同一端口上两套驱动不能同时安装。新代码一律用本节的 `i2c_new_master_bus` 族；读懂 BSP 里的旧写法只需知道 `i2c_master_cmd_begin()` 手搓命令链（start→write_byte→stop）正是新 API 一个函数的事。
>
> 本章素材是 v6 实际头文件（注意函数名是 `i2c_new_master_bus`，不是更早预览版文档里的 `i2c_master_create_bus`）。

---

## 9.3 L2 源码走读：一次传输在驱动里走多远

组件 `components/esp_driver_i2c/` 一共四个源文件：`i2c_master.c`（约 1540 行，主角）、`i2c_slave.c`、`i2c_common.c`（总线句柄、引脚）、`i2c_private.h`（数据结构）。

### 1. 同步路径：从 API 到硬件命令链

以 `i2c_master_transmit_receive()` 为例（`i2c_master.c:1310-1332`），它先在栈上把这次传输翻译成一个 **ops 数组**——软件版的命令链：

```c
i2c_operation_t i2c_ops[] = {
    {.hw_cmd = I2C_TRANS_START_COMMAND},                                      /* START   */
    {.hw_cmd = I2C_TRANS_WRITE_COMMAND(true), .data = write_buffer, ...},     /* 写      */
    {.hw_cmd = I2C_TRANS_START_COMMAND},                                      /* RESTART */
    {.hw_cmd = I2C_TRANS_READ_COMMAND(I2C_ACK_VAL), .data = read_buffer,
        .total_bytes = read_size - 1},                                        /* 读N-1,每字节回ACK */
    {.hw_cmd = I2C_TRANS_READ_COMMAND(I2C_NACK_VAL), .data = read_buffer+read_size-1,
        .total_bytes = 1},                                                    /* 末字节NACK! */
    {.hw_cmd = I2C_TRANS_STOP_COMMAND},                                       /* STOP    */
};
```

9.1 节的协议规则逐条映射到了代码：读方向的最后一字节单列一条命令、ACK 值为 NACK。随后 `s_i2c_synchronous_transaction()`（:1004）拿 `bus_lock_mux` 互斥锁（这是"I2C 主机操作函数线程安全"的实现），进入 `s_i2c_transaction_start()`（:672）：

1. 按设备配置**重配时序**：`i2c_hal_set_bus_timing(hal, i2c_dev->scl_speed_hz, ...)`（:698）——换设备说话先换语速；
2. 写入该设备的 SCL 超时 `scl_wait_us`（:702-703，超上限自动收敛并打 warning）；
3. 复位收发 FIFO、使能事件中断，然后 `s_i2c_send_commands()`（:526）**逐条把 ops 翻译进硬件命令寄存器**（写命令同时把数据灌进 TX FIFO），最后 `i2c_hal_master_trans_start()` 点火；
4. 任务在 `event_queue`（深度 1 的 FreeRTOS 队列）上睡觉等中断（:582），ISR 发来 DONE/NACK/TIMEOUT 事件后醒来返回。

数据量超过硬件 FIFO（S3 为 32 字节，见 9.4）怎么办？`s_i2c_write_command()` 的注释（:161-166）写得很直白：一次灌不满就拆成多段，段间挂 END 命令，靠 `END_DETECT` 中断回来续灌——所以长传输对 CPU 不是一次阻塞到底的忙等，而是"睡觉—中断—续灌"若干轮。

### 2. 中断与事件

`i2c_master_isr_handler_default()`（:780-873）是唯一的 ISR。它读中断掩码归类为三种事件（NACK / TIMEOUT+仲裁丢失 / 主机完成），投进 `event_queue`；读方向的 FIFO 数据也在 ISR 里顺手搬走（`i2c_isr_receive_handler()`，:740）。同步模式下 ISR 通过 `cmd_semphr` 信号量放行任务侧的命令循环；若注册了回调（异步模式），则在 ISR 里直接推进下一段命令并调用用户回调——回调跑在 ISR 上下文，只能用 `FromISR` 后缀 API（与第八章 ISR 纪律一致）。

### 3. 传输队列（异步模式）

建总线时 `trans_queue_depth != 0` 即进入异步模式：`i2c_new_master_bus()` 会建 **READY / PROGRESS / COMPLETE 三个 FreeRTOS 队列**（`i2c_private.h:87-92`）组成事务流水线，API 立即返回、完成后回调通知。但驱动自己先打预防针（:1120 原文大意：异步模式目前只用于特定场景，出错时用户拿不到总线错误、且与 `i2c_master_probe` 不兼容）。结论：**传感器轮询这种慢速场景用同步 API 足够**，异步留给高频小事务且确认总线无错的场合。

### 4. 三层超时

| 层            | 参数                          | 位置                          | 语义                                                                                                                                                   |
| ------------- | ----------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 硬件 SCL 超时 | `scl_wait_us`（设备级）       | `:702-703` 写入超时寄存器     | SCL 被从机拉伸（低电平）超过该时长 → TIME_OUT 中断。默认 2000 µs（`i2c_ll.h:86`），上限约 2^31 个源时钟周期（`s_i2c_timeout_range_check()`，:662-670） |
| 软件传输超时  | `xfer_timeout_ms`（每次调用） | `s_i2c_send_commands()`，:536 | 命令链推进/等事件超过该毫秒数 → 放弃并复位索引                                                                                                         |
| probe 专用    | 固定值                        | `i2c_master_probe()`，:1392   | probe 无设备配置，SCL 超时固定按 20 ms 配（"足够覆盖拉伸"），时钟固定 100 kHz（:1385）                                                                 |

文档提醒过从机拉伸可达 12 ms 量级——`scl_wait_us` 设得太小，慢从机会被误判超时（翻车点表第 6 条）。

### 5. SCL 卡死恢复：总线急救术

最经典的 I2C 事故：主设备在从机正好驱动 SDA 输出 0 时复位/断电，从机状态机停在"等我发完这个字节"，**SDA 被从机一直按在地上**，总线永久死亡——重新初始化控制器也没用。标准急救术是：主机手动补发最多 9 个 SCL 脉冲，把从机状态机推过当前字节，等它放开 SDA 后补一个 STOP。

驱动把这套术式做成了 `s_i2c_master_clear_bus()`（:53-99），并按芯片能力分两条路（`s_i2c_hw_fsm_reset()`，:108）：

- **S3 这类有硬件清总线的芯片**（`I2C_LL_SUPPORT_HW_CLR_BUS=1`，`i2c_ll.h:34`）：调 `i2c_ll_master_clr_bus()`，硬件按 `scl_rst_slv_num`（驱动传 9）自动发脉冲。有趣的是 S3 的 `i2c_ll_master_is_bus_clear_done()` **恒返回 false**（`i2c_ll.h:833-836` 注释：not supported on esp32s3）——所以 S3 上这段代码是"发射后不管"，直接继续走；
- **无硬件能力的芯片**（如 ESP32）：GPIO 层面手搓——把 SCL/SDA 切成开漏 GPIO，`while (!gpio_get_level(SDA) && i++ < 9)` 逐个敲脉冲，最后制造 SDA 低→高（SCL 为高）的 STOP（:57-78 的注释详细解释了为什么至多 9 个、为什么要对齐 ACK 位）。

触发时机（都藏在源码里）：每次事务开始发现 bus busy 或上次状态是 TIMEOUT（:679-681）；NACK 后总线迟迟不空（:586-598）；以及用户显式调 `i2c_master_bus_reset()`（:1246）。**下次 I2C 全体超时先怀疑 SDA 被按死，救法驱动已内置。**

---

## 9.4 L3 寄存器层：S3 的 I2C 控制器长什么样

S3 有 **2 个 I2C 控制器**（`SOC_I2C_NUM = 2`，`soc_caps.h:203`），BOX-3 恰好两条总线各占一个（9.6 表）。时钟源支持 XTAL 与 RC_FAST（`soc_caps.h:206-207`）——选 APB 才会在 DFS 降频时拿 PM 锁。

### 1. 命令链表：8 个命令寄存器

S3 的 I2C 控制器不是"写一个字节敲一次"，而是**命令链表（command link）**机制：`I2C_LL_CMD_REG_NUM = 8`（`i2c_ll.h:31`）——8 个命令槽，每槽一条 `{操作码(RSTART/WRITE/READ/STOP/END), 字节数, ACK 控制}`。CPU 把整段事务的剧本一次写进 8 个槽，硬件按序自动执行，只在"FIFO 需要续灌/剧本演完/出错"时中断。9.3 节驱动的 ops 数组就是这张链表的软件镜像，`s_i2c_send_commands()` 做的就是镜像到寄存器的搬运。8 条槽也解释了 `i2c_master_execute_defined_operations()` 的参数检查上限为什么是 `CMD_REG_NUM`——剧本再长就得靠 END 中断分段续写。

### 2. FIFO 与超时寄存器

- 收发各 **32 字节 FIFO**（`I2C_LL_FIFO_LEN`，`i2c_ll.h:30`）——9.3 节"超 FIFO 拆段"的边界值；
- 超时寄存器 `I2C_TIME_OUT_REG` 的值字段 5 位（`i2c_reg.h:239`，`I2C_TIME_OUT_VALUE_V=0x1F`），以源时钟周期计，所以上限是 2^31 周期（:1015-1017）；
- 毛刺过滤器（`filter_cfg`）按模块时钟周期滤尖刺，驱动把 `glitch_ignore_cnt` 原样传给它（`i2c_master.c:1156`），文档惯例值 7。

### 3. 引脚：没有专用 I2C 脚，全靠 GPIO Matrix

呼应第八章：S3 的 I2C **没有 IO MUX 直连脚**，SDA/SCL 走 GPIO Matrix 任意路由。证据在 `i2c_common.c` 的 `s_hp_i2c_pins_config()`（:304-348）：

```c
gpio_od_enable(handle->sda_num);            /* 开漏输出 —— 协议的电气要求 */
gpio_func_sel(handle->sda_num, PIN_FUNC_GPIO);   /* 功能选 GPIO，再挂矩阵 */
esp_rom_gpio_connect_out_signal(handle->sda_num, i2c_periph_signal[port_id].sda_out_sig, 0, 0);
esp_rom_gpio_connect_in_signal(handle->sda_num, i2c_periph_signal[port_id].sda_in_sig);
```

任意 GPIO（合法范围内）都能当 SDA/SCL——BOX-3 用 GPIO8/18 与 GPIO40/41 正是这个能力的应用。配置前还有 `esp_gpio_reserve()` 检查引脚冲突（:309-317），被别人占了会告警。

---

## 9.5 L4 物理层：一次 AHT20 读温湿度的总线全景

### 1. AHT20 协议事实（组件源码核对，来源：espressif/esp-iot-solution `components/sensors/humiture/aht20/`，即组件注册表 `espressif/aht20` 的源仓库；factory_demo 的 `dependencies.lock` 锁定其 0.1.0~1 版）

| 项        | 值                                                                    | 出处                                          |
| --------- | --------------------------------------------------------------------- | --------------------------------------------- |
| 7bit 地址 | `AHT20_ADDRRES_0 = 0x38`（ADDR 脚低）/ `AHT20_ADDRESS_1 = 0x39`（高） | `include/aht20.h`                             |
| 触发测量  | 写 `0xAC 0x33 0x00` 三字节                                            | `aht20_reg.h`（0xAC）+ `aht20.c`（0x33,0x00） |
| 测量耗时  | 驱动写死后 `vTaskDelay(100ms)` 再读（手册标称约 80ms）                | `aht20.c`                                     |
| 读回      | 一口气读 7 字节：状态 + 湿度20bit + 温度20bit + CRC                   | `aht20.c`                                     |
| 换算      | 湿度 = raw×100/2^20；温度 = raw×200/2^20 − 50                         | `aht20.c`                                     |
| 状态位    | bit7=忙，bit3=校准使能                                                | `priv_include/aht20_reg.h`                    |
| CRC       | CRC-8，多项式 0x31、初值 0xFF，覆盖前 6 字节                          | `aht20.c`                                     |

### 2. 总线上的两幕剧（文字时序图）

用 9.2 的 API 实现"AHT20 读一次温湿度"，落在总线上是**两个独立事务夹一段延时**（传感器测量期间必须释放总线）：

```text
── 事务一：触发测量（i2c_master_transmit，写） ──────────────
SDA: ‾\__[START]‾‾[0x70=0x38<<1|W]__[0xAC]__[0x33]__[0x00]__[STOP]/‾‾
                         ↑__ACK__↑  ↑_ACK_↑  ↑_ACK_↑  ↑_ACK_↑
                        从机应地址   └────── 命令三字节 ─────┘
SCL: 400kHz 方波（START+地址帧+3 命令字节+STOP ≈ 38 bit ≈ 0.1ms 量级）

──── 延时 ≈100ms：主机睡觉（vTaskDelay），总线释放为高 ────

── 事务二：读结果（i2c_master_receive，读 7 字节） ──────────
SDA: ‾\__[START]‾‾[0x71=0x38<<1|R]__[st]__[H19..12][H11..4][H3..0|T19..16][T15..8][T7..0]__[CRC]__[STOP]/‾‾
                         ↑__ACK__↑     └────────────── 每字节主机回 ACK ──────────────┘  ↑NACK↑
                                                                                   末字节 NACK = 收摊信号
```

逐段含义：地址帧 0x70/0x71 是 0x38 左移一位拼 R/W 位（驱动内 `I2C_ADDRESS_TRANS_WRITE/READ` 宏，`i2c_master.c:33-34`——**你填 0x38，移位驱动代劳**）；每字节第 9 个时钟是应答位；读 7 字节的末字节回 NACK 后紧跟 STOP，与 9.3 节 ops 数组里那条 `READ_COMMAND(I2C_NACK_VAL)` 一一对应。四层下钻在此闭环：**协议规则 → API 语义 → 驱动命令链 → 线上的电平**，说的是同一件事。

> [!warning] 待真机验证
> 上图为按协议与驱动源码推演的文字时序，非实测数据。真实波形截图（两幕事务的 START/STOP 细节、ACK 位位置、100ms 间隔）待逻辑分析仪采回后补充，并与 AHT20 手册时序参数对照。

### 3. 逻辑分析仪 + PulseView 解码步骤

装备即系列索引推荐的 8 通道 24MHz 廉价逻辑分析仪（约 ¥30，fx2lafw 固件，sigrok/PulseView 支持）：

1. 接线：CH0→SDA(GPIO41)、CH1→SCL(GPIO40)、GND→板子 GND。**共地必接**，否则采到的全是噪声；
2. PulseView → Connect to Device → 选 fx2lafw，采样率 ≥1 MHz（I2C 解码经验值：≥10 倍总线速率，400kHz 总线取 5~24MHz），采样深度给几秒；
3. Run 采集，同时让固件发起一次读温湿度（串口打印对时间轴）；
4. 顶部 "Add protocol decoder" → 选 **I2C**，把 Decoder 的 SDA/SCL 通道分别指到 CH0/CH1；
5. 解码标注直接在波形上读出 `Start / Address 0x38 Write / ACK / 0xAC / ... / Address 0x38 Read / NACK / Stop`，与 9.5.2 的两幕剧逐段对账；地址标注可切换 7bit/8bit 显示（PulseView 默认 7bit，若看到 0x70/0x71 即 8bit 视图）。

> [!warning] 待真机验证
> 以上步骤为按 PulseView/sigrok 通用流程整理的操作路径，未在本机连硬件执行过；到货后按步骤实操并补截图。

---

## 9.6 实验：扫两条总线，给触摸型号定案

### 1. BOX-3 的 I2C 拓扑（引脚来源：esp-box 仓库 `components/bsp/include/bsp_board.h:22-23` 本地实读；总线号/主总线引脚来源：esp-bsp 官方仓库 esp-box-3 组件 `Kconfig`——`BSP_I2C_NUM` 默认 1、范围 0~1——及 `bsp/esp-box-3.h` 的 `BSP_I2C_SDA=GPIO8`、`BSP_I2C_SCL=GPIO18`）

| 总线                  | 控制器                                                        | SCL    | SDA    | 挂载设备（7bit 地址）                                                                                                                                      |
| --------------------- | ------------------------------------------------------------- | ------ | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 主总线                | I2C**1**（`BSP_I2C_NUM` 默认 1）                              | GPIO18 | GPIO8  | ES8311 codec（0x18）、ES7210 ADC（0x40）、触摸 **GT911（0x5D，备用 0x14）或 TT21100（0x24）**——BSP v1.1.3 双探测、ICM-42607-P IMU、ATECC608A（多数板未贴） |
| 扩展总线（SENSOR 板） | I2C**0**（`esp32_bsp_sensor.c:15`：`BSP_I2C_NUM==1 ? 0 : 1`） | GPIO40 | GPIO41 | **AHT20 温湿度（0x38）**、AT581X 雷达（0x28，来源 esp-iot-solution `at581x.h`）                                                                            |

两个说明：其一，第八章悬案的答案已按源码修正——BSP v1.1.3 的 `bsp_touch_new()` 只探测 GT911（0x5D/0x14）与 TT21100（0x24），**没有 FT6336（0x38）**；外部资料中的 FT6336 说法未获任何源码支持（顺带注意 FT6336 的典型地址恰也是 0x38，与 AHT20 同址——若真在同一总线必然冲突，BOX-3 用两条总线 + 双探测彻底回避了这个问题）。最终谁在线，9.6.3 的扫描定案。其二，两条总线的速率默认 400kHz（`BSP_I2C_FAST_MODE` 默认 y → `CONFIG_BSP_I2C_CLK_SPEED_HZ=400000`）。

### 2. 实验代码（完整骨架）

> [!warning] 待真机验证
> 以下代码未在真机编译运行过，为待验证骨架。前置条件：SENSOR 板插在主机上（AHT20/AT581X 在扩展板上）；烧本实验时**不能同时跑 factory_demo**（BSP 会抢先安装 I2C 驱动，同一端口新旧驱动叠加即冲突）。

```c
/* main/main.c —— I2C 总线扫描 + AHT20 裸读（不用 aht20 组件，练协议） */
#include <stdio.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "driver/i2c_master.h"
#include "soc/soc_caps.h"

static const char *TAG = "ch9";

/* 9.6.1 表中已核实的引脚/地址 */
#define MAIN_SCL   18
#define MAIN_SDA   8
#define EXPAND_SCL 40
#define EXPAND_SDA 41
#define AHT20_ADDR 0x38

static i2c_master_bus_handle_t g_bus[SOC_I2C_NUM]; /* 按控制器号索引，S3 为 2 */
static i2c_master_dev_handle_t g_aht20;

static void bus_scan(i2c_master_bus_handle_t bus, const char *name)
{
    ESP_LOGI(TAG, "scan %s:", name);
    for (uint16_t addr = 0x00; addr <= 0x7F; addr++) {
        /* probe 原理：发 START+地址+STOP，ACK 即在线（i2c_master.c:1355） */
        esp_err_t ret = i2c_master_probe(bus, addr, 50);
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "  0x%02X ACK", addr);
        } else if (ret != ESP_ERR_NOT_FOUND) {
            ESP_LOGE(TAG, "  0x%02X %s (检查上拉!)", addr, esp_err_to_name(ret));
        }
    }
}

static float aht20_read_once(void)
{
    uint8_t cmd[3] = {0xAC, 0x33, 0x00};              /* 触发测量，9.5 表 */
    ESP_ERROR_CHECK(i2c_master_transmit(g_aht20, cmd, sizeof(cmd), 100));
    vTaskDelay(pdMS_TO_TICKS(100));                    /* 驱动同款等待 */
    uint8_t d[7] = {0};
    ESP_ERROR_CHECK(i2c_master_receive(g_aht20, d, sizeof(d), 100));
    if (d[0] & 0x80) {                                 /* 状态 bit7 = 忙 */
        ESP_LOGW(TAG, "AHT20 busy (status=0x%02X)", d[0]);
        return -273.0f;
    }
    uint32_t rh  = ((uint32_t)d[1] << 12) | ((uint32_t)d[2] << 4) | (d[3] >> 4);
    uint32_t tmp = (((uint32_t)d[3] & 0x0F) << 16) | ((uint32_t)d[4] << 8) | d[5];
    ESP_LOGI(TAG, "raw st=%02X rh=%"PRIu32" tmp=%"PRIu32, d[0], rh, tmp);
    /* 换算公式与组件驱动一致（CRC-8 校验 poly 0x31/init 0xFF 此处从简略去） */
    ESP_LOGI(TAG, "T=%.1fC RH=%.0f%%", tmp * 200.0f / 1048576.0f - 50.0f,
             rh * 100.0f / 1048576.0f);
    return tmp * 200.0f / 1048576.0f - 50.0f;
}

static void sensor_task(void *arg)
{
    while (1) {
        aht20_read_once();
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

void app_main(void)
{
    i2c_master_bus_config_t bc = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = false,  /* 两块板都有外部上拉 */
    };
    bc.i2c_port = 1; bc.scl_io_num = MAIN_SCL;   bc.sda_io_num = MAIN_SDA;
    ESP_ERROR_CHECK(i2c_new_master_bus(&bc, &g_bus[1]));
    bc.i2c_port = 0; bc.scl_io_num = EXPAND_SCL; bc.sda_io_num = EXPAND_SDA;
    ESP_ERROR_CHECK(i2c_new_master_bus(&bc, &g_bus[0]));

    bus_scan(g_bus[1], "main  (I2C1, SCL18/SDA8)");
    bus_scan(g_bus[0], "expand(I2C0, SCL40/SDA41)");

    i2c_device_config_t dc = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = AHT20_ADDR,
        .scl_speed_hz = 400000,
    };
    ESP_ERROR_CHECK(i2c_master_bus_add_device(g_bus[0], &dc, &g_aht20));
    xTaskCreate(sensor_task, "aht20", 4096, NULL, 5, NULL);
}
```

（工程 `main/CMakeLists.txt` 的 `PRIV_REQUIRES` 加 `esp_driver_i2c`；`soc_caps.h` 随 `soc` 组件通用依赖自动可见。）

### 3. 预期扫描结果（待真机验证的假设）

| 总线        | 预期 ACK 的地址           | 对应设备                                        | 说明                                                  |
| ----------- | ------------------------- | ----------------------------------------------- | ----------------------------------------------------- |
| I2C1 主总线 | 0x18 / 0x40               | ES8311 / ES7210                                 | 与社区实测一致（来源见文末）                          |
| I2C1 主总线 | **0x5D 或 0x14，或 0x24** | 触摸：GT911（INT 脚电平定 0x5D/0x14）或 TT21100 | **给第八章定案的关键观测**                            |
| I2C1 主总线 | 0x68 或 0x69（待扫）      | ICM-42607-P（AP_AD0 脚定址）                    | 未核实具体值，以扫描为准                              |
| I2C1 主总线 | （无 0x38）               | ——                                              | 若扫到 0x38 才支持 FT6336 说法                        |
| I2C0 扩展   | **0x38 / 0x28**           | AHT20 / AT581X                                  | SENSOR 板插上才有；拔掉后此总线应全空（可作对照实验） |

> [!warning] 待真机验证
> 本表为基于源码与外部资料的预期假设，非实测输出。真机扫完把实际日志回填此表，触摸型号同时回写系列索引与第八章 8.5 的"待核对"注记。AHT20 读值是否落在室温合理区间（如 20~35°C / 30%~70%RH）一并记录。

---

## 9.7 翻车点表与小结

| 症状                                                        | 根因                                                                                                                                                      | 处理                                                                                                                                                       |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| probe 全地址 `ESP_ERR_TIMEOUT`，万用表量 SDA/SCL 有一根贴地 | 上拉缺失（线拉不起来），或从机把线按死（9.3.5 卡死场景）                                                                                                  | 外接 2.2k~4.7k 上拉或 `enable_internal_pullup`（驱动自述内部上拉偏弱，高速档不够用）；从机按死则靠驱动的 9 脉冲清总线自动恢复，或 `i2c_master_bus_reset()` |
| 扫描发现 0x70 一档设备"找不到"，或从机始终 NACK 地址        | **7bit/8bit 地址混淆**：datasheet 写 0x70 是 0x38 左移拼 R/W 的 8bit 写法；`device_address` 必须填 7bit 裸地址 0x38，移位驱动代劳（`i2c_master.c:33-34`） | 统一心智：**API 收 7bit，线上跑 8bit**                                                                                                                     |
| `ESP_ERR_INVALID_RESPONSE`（NACK）偶发                      | 设备忙（如 AHT20 测量中回 NACK）、地址错、或与 factory_demo 同烧抢总线                                                                                    | 查忙位/延时重试；保证同端口只有一套驱动在位                                                                                                                |
| 读到的数值明显错（如恒 -50°C 或 0）                         | 测量延时不足就开读，状态位忙、数据未就绪                                                                                                                  | 按驱动同款等 100ms 再读，并检查 `d[0]` bit7                                                                                                                |
| 400kHz 下频繁超时、通信不稳                                 | 长线缆/面包线电容大，RC 边沿过缓；或上拉电阻过大                                                                                                          | 降到 100kHz；减小上拉电阻（不小于 1k）；缩短线路                                                                                                           |
| 慢从机被误判 TIME_OUT                                       | `scl_wait_us` 配得太小，从机 clock stretching 被掐断（文档：拉伸可至 12ms）                                                                               | 该设备 `scl_wait_us` 放大（probe 内部就按 20ms 配）                                                                                                        |
| `i2c_del_master_bus` 返回 `ESP_ERR_INVALID_STATE`           | 总线上还有设备没删                                                                                                                                        | 先逐个 `i2c_master_bus_rm_device` 再删总线                                                                                                                 |
| 新旧 API 混装，总线行为诡异                                 | esp-box BSP v1.1.3 用旧 `i2c_param_config`，与新驱动同端口叠加                                                                                            | 同一端口只用一套驱动；读 BSP 代码时留意 API 代际                                                                                                           |

本章小结：

- **协议层**：两根开漏线 + 上拉构成"线与"介质，START/STOP 用"SCL 高时 SDA 翻转"这一例外编码，地址帧 7bit+R/W、每字节第 9 拍 ACK/NACK；标准 100kHz / 快速 400kHz。
- **L1**：v6 新驱动是总线-设备两级模型，`i2c_new_master_bus` → `i2c_master_bus_add_device` → transmit/transmit_receive/receive/probe；`device_address` 填 7bit 裸地址。esp-box BSP 因兼容旧 IDF 仍在用 legacy API。
- **L2**：`i2c_master.c` 把每次调用翻译成 ops 命令链，硬件执行、事件队列收尾；超时三层（scl_wait_us / xfer_timeout_ms / probe 内建 20ms）；SCL 卡死有 9 脉冲清总线急救（S3 走硬件且"发射后不管"）。
- **L3**：S3 双控制器、8 槽命令链表、32 字节 FIFO；SDA/SCL 无专用脚，全靠 GPIO Matrix 开漏路由——第八章的矩阵在这里落地。
- **L4**：一次 AHT20 读数 = "写 0xAC 0x33 0x00 → 放线 100ms → 读 7 字节（末字节 NACK）"两幕剧；PulseView 的 I2C 解码能把每一拍标注回协议。
- **实验**：扫 I2C1（SCL18/SDA8）与 I2C0（SCL40/SDA41），预期点名 ES8311/ES7210/触摸/AHT20/AT581X，并给"GT911 vs TT21100 vs FT6336"悬案定案——全部待真机验证。

下一章换到另一条战线：SPI 与屏幕。ILI9342C 的初始化命令序列、esp_lcd 组件的分层、DMA 刷屏数据通路，四层下钻的套路不变，只是时钟从 400kHz 跳到几十 MHz。

---

**外部资料来源**（本地无 managed_components，以下经 GitHub 官方仓库与社区实测核对）：esp-bsp 仓库 `bsp/esp-box-3/`（esp-box-3.h 引脚宏、Kconfig 总线号/速率默认值、esp-box-3.c 触摸双探测逻辑）；espressif/esp-iot-solution 仓库 `components/sensors/humiture/aht20/`（地址/命令/换算/CRC）与 `components/sensors/radar/at581x/`（0x28）；触摸型号定案旁证：[espressif/esp-box issue #120](https://github.com/espressif/esp-box/issues/120)、[esphome GT911 文档](https://esphome.io/components/touchscreen/gt911/)、[Home Assistant 社区 BOX 系列扫描实测（ES8311@0x18、ES7210@0x40）](https://community.home-assistant.io/t/esp-home-and-esp32-s3-box/549708/28)。
