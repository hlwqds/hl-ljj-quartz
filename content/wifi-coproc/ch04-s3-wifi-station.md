---
title: "F429 × Korvo-1（四）：S3 侧 WiFi——station 状态机与板级资源审计"
date: 2026-10-10 12:00:00
description: "协处理器内部的第一块肌肉：Korvo-1 的板级资源审计（音频/LCD/TF 住户与四根 SPI 线的隔离）、IDF station 的 bring-up 八步、事件驱动的状态机设计（IDLE→SCAN→CONNECTING→CONNECTED→重连退避）、NVS 存凭证、看门狗视角的自愈；S3 侧任务拓扑（SPI 从机/WiFi 事件/命令服务三任务的分工）。"
tags: [wifi, esp32-s3, esp-idf, korvo, coprocessor, series]
---

> [!info] WiFi 协处理器实战 0. [[wifi-coproc|系列索引]] 1. [[ch01-coproc-architecture|第一章]] … 3. [[ch03-framing|第三章]] 4. **第四章：S3 侧 WiFi**

# F429 × Korvo-1（四）：S3 侧 WiFi——station 状态机与板级资源审计

帧协议通了，本章开始填内容的第一块：**让 Korvo-1 侧的 WiFi 真正连上网并保持在线**。三件事：先把板子的住户查清（4.1），再把 station 按事件驱动状态机点亮（4.2–4.3），最后定下协处理器的任务拓扑（4.4）——S3 侧从此是一个"WiFi 服务进程"，等 ch05 的命令通道来调用。

---

## 4.1 Korvo-1 资源审计：住户与租约

协处理器不需要音频、LCD、TF 工作，但它们的驱动**可能已经在默认例程里初始化**，占着 GPIO 与外设控制器。审计三步走（与 ch01 F429 侧同款方法论，这次对着 Korvo-1 原理图）：

| 住户               | 典型占用（以官方原理图为准核对） | 与我们的关系                                    |
| ------------------ | -------------------------------- | ----------------------------------------------- |
| ES8311/ES7210 音频 | I2C 总线 + 两组 I2S              | 不初始化即无冲突；确认未被 esp-idf 例程默认拉起 |
| LCD/触摸           | SPI 或并口一组                   | 同上；注意别把 SPI 从机错配到 LCD 的控制器      |
| TF 卡槽            | SDMMC 一组                       | 空闲不用                                        |
| 功放使能/LED/按键  | 零散 GPIO                        | 记账即可                                        |

**产出物是一张"租约表"**：SPI 从机四脚 + DRDY + 可选 RESET 落在哪些空闲 GPIO（S3 的 GPIO 矩阵允许灵活映射），外加一句核验方法——每个脚先跑"输出方波 + 对侧逻辑笔/万用表确认"再签合同。这张表进工程的 README，真机实验第一步就是它。

## 4.2 Station bring-up：八步序列

IDF 侧把 station 点亮的标准序列（与 [[lwip-deep-dive|lwIP 系列]]第二章梳理的组件栈对得上）：

```text
① nvs_flash_init()                 // 凭证要存非易失
② esp_netif_init() + 事件循环创建   // 第一句网络调用（老规矩）
③ esp_netif_create_default_wifi_sta()
④ wifi_init_config_t 默认 + esp_wifi_init()
⑤ esp_wifi_set_mode(WIFI_MODE_STA)
⑥ 注册事件：WIFI_EVENT / IP_EVENT 各关心的槽位
⑦ esp_wifi_start()                 // → STATION_START 事件
⑧ （收到 START 后）esp_wifi_connect() // 凭证可来自 NVS，也可等 ch05 的 JOIN 命令
```

**协处理器模式的一个关键决策**：不写死 `wifi_config` 的 SSID——凭证由宿主通过命令通道下发（ch05 的 JOIN），或存进 NVS 后续启动自动重连。这让同一块 Korvo-1 能被任何宿主配置，也让我们省掉"换网络要重新刷 S3 固件"的蠢事。

## 4.3 状态机：把事件流变成一张图

IDF 的 WiFi 是事件驱动的（`esp_event`），裸写回调容易碎成一地 if-else。正经做法是把生命周期画成状态机，事件只做迁移：

```text
  IDLE ──JOIN 命令/启动凭证──▶ CONNECTING ──GOT_IP──▶ CONNECTED
   ▲                              │ │                    │
   │              CONNECT_FAIL/断线 │ │ SCAN_DONE         │ 断线事件
   │                              ▼ ▼                    ▼
   └────────────────────────── BACKOFF ←──────（指数退避 1s→2s→…→60s 封顶）
                                       └─重试次数耗尽→ IDLE + 上报宿主
```

三个实战要点：

- **退避重连**：路由器重启、信号抖动是常态；指数退避防止把 AP 打成 DOS，上限封顶后回到 IDLE 等宿主指令；
- **异步事件上桥**：每次状态迁移（尤其断线）都要以**事件帧**（ch03 的 type=EVENT）主动告知 F429——宿主的协议层（ch05 会定义 LINK_UP/LINK_DOWN 事件）依赖它驱动自己的重连与 UI；**协处理器的义务不只是"能连"，是"状态变化必报"**；
- **看门狗视角**：喂狗线程跑在哪、CONNECTING 卡死多久判失败——这些决定"协处理器挂了宿主怎么办"（F429 侧最终手段：拉 RESET 线硬重启 S3，ch01 那根可选的第七根线在此兑现价值）。

## 4.4 任务拓扑：协处理器的三进程观

S3 侧固件的任务划分（FreeRTOS 任务，优先级从高到低）：

```text
[spi 任务]      SPI 从机队列 + DMA 回调 + DRDY 维护   ——链路的搬运工（ch02）
[wifi 任务]     状态机 + 事件处理 + 退避定时器          ——网络的守夜人（本章）
[cmd 任务]      帧解析 → 命令分派 → 应答组装            ——服务的柜台（ch05/ch06）
```

三者之间用 FreeRTOS 队列解耦（与 [[freertos-deep-dive|FreeRTOS 系列]]讲的"队列即信箱"完全同构）：spi 任务收帧丢给 cmd 任务，cmd 任务要联网时通过事件接口驱动 wifi 任务，应答帧排队等 spi 任务交换带走。**协处理器内部就是一个微型消息系统**——这也是它作为"服务进程"的正确形态。

> [!note] 与直接跑应用的差异
> 平时跑 ESP-IDF 应用（如 [[esp32-s3-box-3|S3-BOX-3 系列]]），WiFi 是 App 的一部分；协处理器模式下**WiFi 是"给别人的服务"**：凭证来自外部、状态要上报、随时可能被 RESET——把这三条刻进状态机，是协处理器固件与应用固件的分水岭。

## 4.5 小结

- 先审计后签约：Korvo-1 的音频/LCD/TF 住户与 SPI 四线隔离，租约表进 README、真机首验。
- 八步 bring-up + 事件驱动状态机（IDLE/CONNECTING/CONNECTED/BACKOFF）；凭证不烧死固件——JOIN 命令或 NVS，换网不刷机。
- 协处理器三义务：能连、状态变化必报（事件帧）、挂了能被拉 RESET 复活——喂狗与超时判定为宿主兜底。
- 任务拓扑三件套（spi/wifi/cmd）用队列解耦，微型消息系统是协处理器的正确形态。
- 应用固件与协处理器固件的分水岭：WiFi 从"我的能力"变成"卖给宿主的服务"。

WiFi 侧的"肌肉"就位，下一章铺"神经"：控制通道。TLV 格式的命令怎么定义（PING/SCAN/JOIN/STATUS/DNS…）、请求-应答怎么对齐（请求 ID + 超时）、异步事件怎么编号——F429 从此有了远程驾驶舱。[[ch05-control-protocol|第五章：控制通道]]。
