---
title: "WiFi 射频硬件入门（七）：WiFi SoC 解剖"
date: 2026-08-29 12:00:00
description: "把 ESP32/ESP32-S3 摆上解剖台的射频侧：CPU、MAC、基带、RF/PA/LNA 在一颗芯片里怎么分工——用协议栈分层当类比地图；再算模组经济学的账：为什么软件工程师永远买模组不买裸片。芯片事实逐条对 datasheet 核实，软件事实出自 esp_phy/esp_wifi 组件源码实读。"
tags: [wifi-rf-hw, RF, Hardware]
---

> [!info] WiFi 射频硬件入门系列导航
> 上一章 [[ch06-antenna-basics|第六章：天线入门]] · 当前 **第七章：WiFi SoC 解剖** · 下一章 [[ch08-passives-in-rf|第八章：四个元件的 RF 角色]] · [[wifi-rf-hw|系列索引]]

# WiFi 射频硬件入门（七）：WiFi SoC 解剖

第六章为止，天线是"一段被设计过的金属"：它不供电、不跑代码，只负责把导线上的电流和空中的电磁波互相翻译。但天线插在模组上，模组焊在板子上——WiFi 世界真正的发动机，那颗把比特变成 2.4 GHz 电磁波、再把电磁波变回比特的 SoC，还没拆过。本章拆它。

这是 [[ch2-esp32-xtensa-architecture|FreeRTOS（二）]] 的续篇。那一章从 CPU、寄存器、中断、内存映射的角度解剖了 ESP32，WiFi 子系统在它的框图里只是 CPU 身边众多"外设"之一，一笔带过；本章把镜头掉转 180 度，从射频侧再看同一颗芯片，把那个被一笔带过的方块放大成 MAC、基带、RF 三层电路。两章拼在一起，才是这颗芯片的完整地图。

先立本章的核心类比，后面所有内容都挂在它上面：**SoC 内部分层 ≈ 协议栈分层**。
你在软件世界熟悉的每一层——应用代码、TCP/IP 栈、帧的封装与收发、序列化与线路编码——在这颗芯片里几乎都能找到一个电路级的对应物。区别只有一个：软件层是"写"出来的，电路层是"刻"在硅片上的。

本章事实来源：芯片规格出自 ESP32 datasheet v5.3 与 ESP32-S3 datasheet v2.2（docs.espressif.com 官方 PDF 逐条核实），模组构成出自 ESP32-S3-WROOM-1/1U 模组手册 v1.8；软件侧全部出自本机 esp-idf 源码实读（`components/esp_phy` 与 `components/esp_wifi`），行号与注释原文随文标注。

## 本章装备清单

| 分类 | 装备                       | 价格/状态                | 用途                                       |
| ---- | -------------------------- | ------------------------ | ------------------------------------------ |
| 已有 | 手机（装 WiFi 分析仪 App） | ✅ Android 免费/iOS 受限 | 频谱/信号强度观察                          |
| 已有 | 自家路由器（管理后台可看） | ✅                       | 对照射频链路实物                           |
| 已有 | 笔记本                     | ✅                       | 查 datasheet 与模组手册                    |
| 已有 | ESP32 开发板 / BOX-3       | ✅ 已在手 / 在途         | 看模组丝印与屏蔽罩实物；BOX-3 在途可先看图 |

---

## 7.1 从系统框图看 WiFi SoC：一颗芯片上住着协议栈的每一层

### 1. 三大块

打开 ESP32 datasheet 的系统框图（§3 图 3-1），去掉细节后就是三块东西：

| 子系统         | 里面有什么                                    | 软件工程师看到的样子                        |
| -------------- | --------------------------------------------- | ------------------------------------------- |
| CPU 子系统     | 双核 LX6/LX7、ROM、SRAM、cache                | FreeRTOS（二）的主场：任务、调度、内存映射  |
| WiFi 子系统    | WiFi MAC、基带、RF（PA/LNA）、Balun、收发开关 | 闭源驱动库之下的黑盒外设，WiFi 事件由它上报 |
| 共享外设与电源 | GPIO/SPI/UART、RTC、PMU、40 MHz 时钟树        | esp_pm/esp_sleep 操作的硬件对象             |

三块的身份要摆正：**CPU 子系统是 FreeRTOS（二）已经拆完的那一半**——ESP32 经典版是双核 Xtensa LX6 @ 240 MHz、448 KB ROM、520 KB SRAM（datasheet §2/§3.1；与那章从 `core-isa.h`/`soc.h` 读出的数字一致），ESP32-S3 换成双核 LX7 @ 240 MHz、384 KB ROM、512 KB SRAM（S3 datasheet §1.1）。**WiFi 子系统是本章主角**，CPU 通过系统总线和中断看到它，就像通过 MMIO 看到一个极其复杂的外设。**共享外设与电源管理**是两边的公共设施——尤其 40 MHz 晶振：datasheet §5.1 明说外部晶振 2~60 MHz 可选，但"40 MHz 仅用于 Wi-Fi/Bluetooth 功能"，射频的整个时间基准都挂在它上面（第十一章的主角）。另外注意框图里蓝牙的位置：BT 链路控制器与 BT 基带，和 WiFi MAC/BB 并排放着，往下接的是**同一套**射频电路（RF receive/RF transmit/Balun）——WiFi 和蓝牙共享一颗射频心脏，这就是第十四章"共存"问题的硬件根源。

### 2. 一张图拼起两个视角

FreeRTOS（二）画过 CPU/内存视角的框图，这里把它和本章的射频视角拼成整图（数字以 ESP32 经典版为准；S3 把 LX6 换成 LX7，形状相同）：

```text
┌───────────────────── ESP32 SoC：两个视角拼成整图 ─────────────────────┐
│                                                                       │
│  ══ CPU/内存视角（FreeRTOS（二）已拆过的一半）═════════════════════    │
│    Core 0 / PRO_CPU                  Core 1 / APP_CPU                 │
│    Xtensa LX6 @ 240 MHz              Xtensa LX6 @ 240 MHz             │
│    跑 FreeRTOS、应用、WiFi 驱动库     跑应用任务                        │
│         └───────────────┬────────────────┘                            │
│       DPORT 互连 + 中断矩阵 + 共享 SRAM 520 KB + ROM 448 KB            │
│                             │                                         │
│  ══ 射频视角（本章补上的另一半）═══════════════════════════════════    │
│    WiFi MAC ──► WiFi 基带(BB) ──► RF 收发（TX: 调制+片内PA）          │
│    帧收发/ACK/                    （RX: LNA+AGC+ADC）                 │
│    加密引擎/TSF                    │                                  │
│    （BT 基带也接在这套 RF 上）     Balun + 收发开关 + 时钟产生         │
│                                   │                                   │
│              ── RF 管脚：芯片的边界到这里为止 ──                       │
└───────────────────────────────────┼───────────────────────────────────┘
                                    ▼
              板上匹配网络（模组内）──► 50 欧端口 ──► 天线（第六章）
```

两个视角各看半张图：FreeRTOS（二）关心上面那半——窗口寄存器、中断级别、内存映射；本章关心下面那半——帧进去、电磁波出来。中间的连接点有两个，都是那章提过的伏笔：一是 PRO_CPU 的名字本身就是 **Protocol CPU**（协议栈核），WiFi 时代的典型分工是把协议栈钉在 Core 0；二是中断系统里 WiFi/BT 占用的保留中断号 0/1/4（`soc.h`，见那章 2.3 节）——WiFi 子系统不是安静的邻居，它持续地以中断打断 CPU。

### 3. 核心类比：芯片分层对协议栈分层

| 你熟悉的软件世界           | SoC 里的对应电路             | 边界                   |
| -------------------------- | ---------------------------- | ---------------------- |
| 应用层：app_main 业务代码  | CPU 核 + FreeRTOS + 你的任务 | 纯软件，随时可改       |
| 网络层：lwIP 的 TCP/IP 栈  | 仍是 CPU 上的软件            | 纯软件                 |
| 驱动层：帧封装与收发队列   | WiFi MAC 硬件电路            | 软件递帧，时序电路保证 |
| 编码调制：序列化与线路编码 | 基带（BB）电路               | 比特与波形的翻译官     |
| PHY 芯片段：网卡芯片本身   | RF：PA、LNA、Balun           | 纯硬件，只经校准触达   |

这张表是本系列的方法论锚点，值得逐行多看一眼：lwIP 往上是纯软件（[[ch18-esp32-wifi-lwip-integration|lwIP（十八）]] 讲过它怎么接到 WiFi 驱动上）；从 MAC 往下，每一层都是"固化成电路的软件"——**你在应用层拥有的那种"改一行重编译"的自由，越往下越少，直到 RF 层只剩几个校准参数可调**。这个"自由度递减"的形状，正是硬件世界的第一性约束。

> [!note] 类比的边界：分层是"职责"像，不是"结构"像
> 协议栈的层是逻辑概念，可以随意增删重组；芯片的层是物理电路，共享同一份时钟、电源和硅面积。所以别把类比推得太远：MAC 电路坏了不能像替换软件模块那样"重装"，RF 层的时序约束（16 微秒 SIFS）会反向绑架 MAC 层的设计。类比帮你回答"谁负责什么"，不承诺"它们互相独立"。

---

## 7.2 MAC 层是什么硬件：裸机时代的定时器中断，芯片里的现成电路

MAC（Media Access Control）在 802.11 语境里常被说成"软件栈的一层"，但在 SoC 里它是**一块真实的数字电路**。ESP32 与 S3 的 datasheet 都在 Wi-Fi 一节列了它的硬件功能清单（ESP32 §4.6.5、S3 §4.6.5），逐条翻译过来就是它干的活：帧收发、RTS/CTS 保护、立即 Block ACK、帧分片与重组、A-MPDU/A-MSDU 聚合、加密、beacon 自动监测。

对软件工程师，最好的类比是：**MAC 之于 WiFi 帧 = UART 外设之于串口字节**。你从来不会用 GPIO 翻转去软件模拟 115200 波特率——不是不能，是没必要也不可靠；同理，CPU 也不该用定时器中断去软件模拟帧时序。裸机时代你用"定时器中断 + 状态机"堆出来的每一样东西，这块电路里都是现成的：

- **帧收发与缓冲**：MAC 从总线上拿走你排队的帧、把收到的帧 DMA 进内存。软件侧的对应物就是 `esp_wifi_init()` 里那个 `wifi_init_config_t` 的 `static_rx_buf_num`/`dynamic_rx_buf_num`/`static_tx_buf_num`（`esp_wifi.h`）——你在配置的"收发缓冲池"，正是 MAC DMA 的落地地点。
- **ACK 与重传时序**：802.11 规定收到帧后要在 SIFS（2.4 GHz 频段 OFDM 为 16 微秒、802.11b 为 10 微秒，IEEE 802.11 标准值）内回 ACK。16 微秒内要完成 CRC 校验、组织 ACK 帧、压上射频——靠 CPU 中断服务程序根本来不及，这块时序是 MAC 电路里的硬逻辑。重传计数与退避（backoff）同理。
- **加密引擎**：datasheet 原文列着 "CCMP (CBC-MAC, counter mode), TKIP (MIC, RC4), WAPI (SMS4), WEP (RC4) and CRC"——WPA 时代每帧都要做的 AES-CCM 运算由硬件加速器完成，S3 还加了 GCMP/BIP（对应 WPA3）。你的 `esp_wifi_set_password()` 递进去的密钥，最终喂给的就是这块电路。
- **beacon 时序（硬件 TSF）**：datasheet 明写 "automatic beacon monitoring (hardware TSF)"。TSF（Timing Synchronization Function）是芯片里一台独立跑的微秒级定时器，STA 用它和 AP 的 beacon 间隔对表——modem-sleep 睡着后能在正确的时刻醒来听 beacon，靠的就是它而不是 CPU（呼应 [[ch16-wifi-events|BOX-3（十六）]] 的省电模式，第十二章展开）。

把 ACK 这一条展开成时间线，"为什么必须是电路"就一目了然：

```text
软件模拟（裸机思路）                      MAC 电路（实际发生）
───────────────────────────              ───────────────────────────
帧到达 → 触发中断                          帧到达，硬件流水线并行干：
       → ISR 抢占 CPU                          CRC 校验 + 组织 ACK 帧
       → CPU 从任务里切出来                     + 16 微秒内压上射频
       → 组织 ACK 帧、压上射频                  （全程 CPU 可以在跑别的任务）
       → 回 ACK
总延迟随 CPU 负载浮动，超过 16 微秒          总延迟恒定，与 CPU 忙闲无关
即被 AP 判定丢帧、触发重传
```

还有一个容易忽略的硬件事实：datasheet 说 MAC 提供**四个虚拟 WiFi 接口**（four virtual WiFi interfaces）。同一套 MAC 硬件分时复用出 STA、SoftAP、混杂模式等逻辑接口——你在 `esp_wifi` API 里看到的 `WiFi_STA`/`WiFi_AP` 是虚拟接口的选择器，不是两块电路。

> [!tip] 类比收拢：MAC 是芯片里的"帧协处理器"
> 就像 GPU 替 CPU 扛走矩阵运算，MAC 替 CPU 扛走**全部微秒级时序义务**：ACK、退避、加密流水、beacon 对表。CPU 上跑的 WiFi 驱动（闭源库，见 7.6）只做"慢决策"——扫描、关联、速率选择。这个"快硬件 + 慢软件"的分界，是理解一切 WiFi SoC 的钥匙。

---

## 7.3 基带（BB）：第四章的调制解调，住在这里

第四章发射链路漫游的终点、第五章接收链路的起点，就是基带（Baseband）这块电路。它是数字世界与模拟世界之间的翻译官：

- **发射方向**：MAC 交来的比特流，经编码、交织、QAM 星座映射、OFDM 调制（IFFT），变成两路数字 I/Q 信号交给 DAC——这是数字侧的最后一站；
- **接收方向**：ADC 采样进来的 I/Q 数据（datasheet §4.6.2 说接收机集成两颗高速 ADC），经 FFT、星座解映射、解码，还原成比特流交还 MAC——模拟侧进来后的第一站。

datasheet 给它的规格清单（§4.6.5 "Wi-Fi Radio"）：MCS0~MCS7、20/40 MHz 带宽、短保护间隔、接收 2x1 STBC、空口速率最高 150 Mbps。对照第四章的速率表你会发现：**MCS 表的每一行，在 BB 里都是一套现成电路配置**——硬件支持全部档位，随时可切。也顺手给"150 Mbps"祛魅：这是 PHY 层的理论顶格（单空间流、40 MHz、短 GI），你在 iperf 里看到的 TCP 吞吐要远低于它——帧间隔、beacon、管理帧、重传，再叠加 lwIP 的协议开销，每一层都在抽成（[[ch24-performance-tuning-pitfalls|lwIP（二十四）]] 讲的就是后一半的账）。

**速率自适应的硬件侧**就在这里分界：档位本身是硬件能力，但"此刻用哪一档"是软件决策——算法在闭源驱动库（libnet80211.a/libpp.a，见 7.6）里，依据 BB/PHY 报告的 RSSI 与重传统计动态调整；你能摸到的旋钮是 `esp_wifi_set_max_tx_power()`、`esp_wifi_set_bandwidth()` 这类 API，以及 menuconfig 里的 `CONFIG_ESP_PHY_MAX_TX_POWER`。为什么信号满格却跑不快、为什么路由器后台看到的连接速率一直变——硬件真相在第十六章展开。

> [!tip] 类比收拢：换 MCS = 换编码方案
> 软件世界里你换过序列化格式（JSON 换 protobuf，解析快了但调试难了）；WiFi 换 MCS 是同构决策：QAM 阶数越高（一次装更多比特），对信噪比要求越苛刻。速率自适应就是芯片里一位不知疲倦的架构师，每帧都在"吞吐"和"鲁棒"之间重新选型。

---

## 7.4 RF/PA/LNA 片段：ESP32 片内集成到什么程度

datasheet §4.6（Radio）的回答是：**一颗芯片装下了整条射频链**。接收方向，射频信号经 Balun 进接收机，片内集成 LNA、射频滤波、自动增益控制（AGC）、直流偏移消除、基带滤波和那两颗 ADC；发射方向，数字 I/Q 经正交调制进片内 CMOS 功率放大器（PA），datasheet 说它在 802.11b 模式可输出最高 +20.5 dBm，并"配合校准方案抵消温度与负载变化的影响"；再加上收发开关和时钟产生电路。也就是说，从基带接口到 RF 管脚，中间不需要任何外部有源器件。S3 datasheet（§4.6.2）把这套东西总结成一句话："RF 模块由天线开关、RF 巴伦、功率放大器和低噪接收放大器组成。"

把三份官方 PDF 的关键数字对齐（全部为典型值，出处见表）：

| 指标                        | ESP32               | ESP32-S3          | 出处                    |
| --------------------------- | ------------------- | ----------------- | ----------------------- |
| 802.11 标准                 | 802.11 b/g/n        | 802.11 b/g/n      | datasheet Wi-Fi 节      |
| 最高空口速率                | 150 Mbps            | 150 Mbps          | datasheet Wi-Fi 节      |
| 11b 1Mbps 发射功率（典型）  | +19.5 dBm           | +21.0 dBm         | ESP32 表 5-6，S3 表 6-2 |
| 11n MCS7 发射功率（典型）   | +13.0 dBm           | +18.5 dBm         | ESP32 表 5-6，S3 表 6-2 |
| 11b 1Mbps 接收灵敏度        | -98 dBm             | -98.4 dBm         | ESP32 表 5-6，S3 表 6-2 |
| 11n MCS7 接收灵敏度（HT20） | -73 dBm             | -74.2 dBm         | ESP32 表 5-6，S3 表 6-2 |
| 发射峰值电流                | 240 mA（+19.5 dBm） | 340 mA（+21 dBm） | ESP32 表 5-6，S3 表 6-2 |

表里藏着一条硬件规律：**速率越高，PA 输出功率越低**——ESP32 上 11b 能打 19.5 dBm，11n MCS7 只剩 13 dBm。原因：高阶 QAM 的星座点挤得很密，PA 推到饱和附近会引入非线性失真把星座揉成一团，必须回退（back-off）功率保线性。这条规律是第十六章"降速连接"的硬件根源之一，也是下一节模组增益账本的输入。顺带记住发射电流这一列：PA 打满的瞬间几百毫安，就是第十二章"WiFi 电源性格"要处理的那头吞金兽。

**与外置 FEM 的分界线**画在哪？datasheet 自己交代得很诚实：ESP32 的典型射频输出阻抗是 30+j10 欧（QFN 6x6 封装）或 35+j10 欧（QFN 5x5，datasheet §3.1 注）——**不是 50 欧**。芯片止步于 RF 管脚，把阻抗变换到 50 欧、再到天线，是芯片外匹配网络（第九章）的活；而当需要超过 20 dBm 的发射功率或更干净的接收时，就要在芯片外加 FEM（外置 PA/LNA/收发开关/滤波器，第十章）——路由器的"信号猛"多半猛在这块板外电路上，ESP32 这类单芯片方案是"够用就好"的取舍。

最后一个 datasheet 值得引全文的细节（§4.6.2）：芯片内置成套校准例程——载波泄漏、I/Q 相位匹配、基带非线性、射频非线性、**天线匹配**——"这些内置校准例程减少了产测时间，使产品测试设备不再必要"。注意"天线匹配"四个字：芯片连天线匹配都能校。但这些校准由谁、在什么时候执行？答案在软件里，7.6 节揭晓。

还有一件事别漏了：射频是会被**整个关掉**的。datasheet 电源管理一节定义 modem-sleep 为"CPU 正常运行，Wi-Fi/蓝牙基带与射频关闭"，配合 7.2 的硬件 TSF 在 beacon 时刻定时唤醒。软件侧能找到对应证据——`esp_wifi.h` 的错误码 `ESP_ERR_WIFI_WAKE_FAIL` 注释原话："WiFi is in sleep state(RF closed) and wakeup fail"。"RF closed"三个字泄露了天机：WiFi 驱动内部维护的"睡眠状态"，就是这块射频电路的电源状态；7.6 的 `esp_phy_enable()`/`esp_phy_disable()` 就是它的开关。所谓 WiFi 功耗管理，本质是对这块电路开合时机的管理——第十二章的主题。

---

## 7.5 模组经济学：买模组 = 买一台预装调好的整机

拆完芯片，问题从"里面有什么"变成"我该买什么"。ESP32 系列出货形态有两种：**裸片**（SoC 芯片本身，BGA/QFN 封装）和**模组**（如 ESP32-S3-WROOM-1）。软件工程师清一色用模组，原因不是焊接难度，是经济学。

核心类比：**裸片 = 散件 CPU，模组 = 品牌整机**。买散件 CPU，你还得自己装主板（画 PCB、摆匹配网络）、配电源（阻抗变换）、过质检（法规认证）、装天线（设计与净空）；买品牌整机，开箱即用、出厂已检验、带保修（认证证书）。WROOM-1 模组手册（v1.8）的解剖表：

| 零件        | 具体内容                        | 它替你解决了什么             |
| ----------- | ------------------------------- | ---------------------------- |
| SoC         | ESP32-S3，双核 LX7 最高 240 MHz | CPU 与 WiFi 全家桶一芯搞定   |
| Flash 芯片  | 独立 QSPI Flash 芯片，4/8/16 MB | 走线与布局已做好，原理图 U2  |
| PSRAM       | 集成在芯片封装内，2/8/16 MB     | 选后缀即得，板上无需另挂     |
| 晶振        | 40 MHz 晶体，误差正负 10 ppm    | WiFi 时钟的心跳源            |
| RF 匹配网络 | 匹配网络，50 欧阻抗控制         | 三座大山之一：阻抗匹配       |
| 天线        | 板载 PCB 天线（1U 为外置口）    | 三座大山之二：天线与净空     |
| 屏蔽罩      | 模组顶面的金属罩                | EMC 屏蔽（实物可见，待核对） |
| 认证        | RF 认证证书齐备（见手册）       | 三座大山之三：法规准入       |

（出处：模组手册 v1.8 表 1-1 零件清单、图 1-1 系统框图"RF Matching"、原理图图 8-1 的 40 MHz ±10 ppm 晶体与 50 欧阻抗控制标注；屏蔽罩为实物观察，手册正文未单列此项——待核对。）

散件 CPU 要自己面对的**三座大山**，模组逐一铲平：

1. **匹配**：上一节说过芯片输出阻抗不是 50 欧。模组手册框图里那个 "RF Matching" 方块，就是把它变换成 50 欧标准端口的匹配网络——一个你不用会算、但裸片设计者必须用矢网调半天的东西（第九章）。
2. **天线**：板载 PCB 天线连同它的净空区（keepout）一起设计好了。1U 版本留外置天线口，但手册 §1.4 限定认证时的天线增益不超过 2.33 dBi——**天线与认证是绑定的**，换更高增益天线理论上要重新认证（第十七章）。
3. **认证**：模组出厂已带 RF 认证证书（手册 Certification 节："RF certification: See certificates"）。这不是抽象荣誉，它在你固件里留下了代码：`esp_phy_init.h` 里有一整组按认证区域命名的 PHY 初始化数据类型——SRRC、FCC、CE、NCC、KCC、MIC……`phy_init.c` 里维护着国家码到它们的映射表（`CN → SRRC`、`US → FCC` 等）。同一颗芯片，卖到不同国家要加载不同国家的发射参数模板——法规如何钻进你的 `sdkconfig`，第十七章细说。

所以"为什么软件工程师永远用模组"的完整答案：你需要操心的是 `nvs_flash_init()` 和 `esp_wifi_start()`，而不是矢网、暗室和 EMC 整改。模组把三座大山打包进了 ¥20 的差价里。那谁还在买裸片？量产到百万级的大厂——它们有自己的射频团队、自己的 layout 工程师、自己的认证预算，省下的物料成本和板面积在那个量级下值得重新爬三座大山。规模改变经济学，这和软件世界"要不要自建基建"的决策是同一个形状。

---

## 7.6 软件触点：你烧录时见过的东西，终于有了名字

本章最后落到你的代码和日志里。以下全部出自 esp-idf 源码实读（`components/esp_phy`、`components/esp_wifi`）。

**第一个名字：`phy_init` 分区**。第一次跑 `idf.py flash` 时，默认分区表 `partitions_singleapp.csv` 里就有一行 `phy_init, data, phy, , 0x1000`——现在你知道它是什么了：存放 PHY 初始化数据（`phy_init_data.bin`）的分区。默认配置（`CONFIG_ESP_PHY_INIT_DATA_IN_PARTITION=n`）下这份数据编译进固件的只读段（`esp_phy_get_init_data()` 的注释：返回指向 DROM 中数据的指针）；打开该选项后才改从分区加载（Kconfig help：默认分区表已自动包含 phy 分区）。这份数据是 Espressif 生成的 128 字节不透明参数表（`esp_phy_init_data_t.params[128]`），其中你唯一可能碰到的字段是发射功率上限——`esp32/phy_init_data.c` 里能看到 `LIMIT(CONFIG_ESP_PHY_MAX_TX_POWER * 4, 40, 78)`。

**第二个名字：NVS 里叫 `phy` 的命名空间**。`phy_init.c` 第 731~734 行定义了它的三个键：`cal_version`、`cal_mac`、`cal_data`。这就是 PHY 校准数据的家——datasheet 吹的"内置校准例程"，执行结果存在这里，结构体定义在头文件里，原文摘录。顺带解开一个新手之谜：为什么所有 WiFi 例程第一行都要 `nvs_flash_init()`？因为 WiFi 启动链要来 NVS 读校准数据——`phy_init.c` L747 的报错原话："NVS has not been initialized. Call nvs_flash_init before starting WiFi/BT."。

```c
/* components/esp_phy/include/esp_phy_init.h */
typedef struct {
    uint8_t version[4];      /*!< PHY version */
    uint8_t mac[6];          /*!< The MAC address of the station */
    uint8_t opaque[1894];    /*!< calibration data */
} esp_phy_calibration_data_t;

typedef enum {
    PHY_RF_CAL_PARTIAL = 0x00000000, /*!< Do part of RF calibration.
             This should be used after power-on reset. */
    PHY_RF_CAL_NONE    = 0x00000001, /*!< Don't do any RF calibration.
             This mode is only suggested to be used after deep sleep reset. */
    PHY_RF_CAL_FULL    = 0x00000002  /*!< Do full RF calibration. Produces
             best results, but also consumes a lot of time and current.
             Suggested to be used once. */
} esp_phy_calibration_mode_t;
```

`esp_phy_load_cal_and_init()`（`phy_init.c` L895）把三档校准串成一条决策链，源码读起来就是策略文档：

1. 上电复位 → 默认 `PHY_RF_CAL_PARTIAL`（部分校准，快）；
2. 深度睡眠唤醒 → 强制 `PHY_RF_CAL_NONE`（校准数据还留着，不用重做）；
3. NVS 读取失败或版本/MAC 对不上 → 打出你可能在日志里见过的那行 `"failed to load RF calibration data (0x%x), falling back to full calibration"`，退回 `PHY_RF_CAL_FULL`（全量校准，慢且费电，注释原话 "Suggested to be used once"）；
4. 真正干活的函数 `register_chipv7_phy(init_data, cal_data, mode)` 由 **libphy.a** 提供——闭源二进制库（组件 `lib/esp32/` 目录，`CMakeLists.txt` L153 链接），校准完的结果写回 NVS。

串口启动日志里那行 `phy_init: phy_version ...` 就是这条链的入口日志（L898）。所以：**擦掉 NVS 不会让 WiFi 坏掉，但会让每次冷启动多付一次全量校准的时间和电流**——`esp_phy_erase_cal_data_in_nvs()` 的注释把它定位成"最后手段的补救"。

**第三个名字：`esp_wifi_init()` 到底初始化了什么**。读 `wifi_init.c` L348~515：它先调 `esp_wifi_init_internal()`（装配驱动内部状态与你配置的缓冲池），再 `esp_phy_modem_init()`（准备 PHY 上下电的备份内存）、创建名为 "wifi" 的电源管理锁、最后 `esp_supplicant_init()`（WPA 握手层）。**注意它没有直接开射频**。谁开的？`esp_phy_enable()` 的头文件注释写得明白："PHY and RF enabling job is done automatically when start WiFi or BT. Users should not call this API"——由闭源 WiFi 库在 `esp_wifi_start()` 时自动调用。你 grep 不到调用点，因为它藏在二进制里。

这引出本章最后一张表：WiFi 功能的软件一半，哪些是源码、哪些是二进制：

| 组件           | 库文件                     | 它管什么                                      |
| -------------- | -------------------------- | --------------------------------------------- |
| esp_phy        | libphy.a、librtc.a         | RF 初始化与校准，register_chipv7_phy 在这里   |
| esp_wifi       | libnet80211.a、libpp.a 等  | 802.11 驱动：MAC 的软件管家，速率自适应也在这 |
| esp_supplicant | 开源的 wpa_supplicant 移植 | WPA 握手与密钥派生，跑在 CPU 上               |

（出处：`esp_phy/CMakeLists.txt` 与 `esp_wifi/CMakeLists.txt` 的 `add_prebuilt_library` 列表。）`esp_wifi.h` 开篇的编程模型注释自带一张图（原文照抄）：

```text
                            default handler              user handler
  -------------             ---------------             ---------------
  |           |   event     |             | callback or |             |
  |   tcpip   | --------->  |    event    | ----------> | application |
  |   stack   |             |     task    |    event    |    task     |
  |-----------|             |-------------|             |-------------|
                                  /|\                          |
                                   |                           |
                            event  |                           |
                                   |                           |
                             ---------------                   |
                             |             |                   |
                             | WiFi Driver |/__________________|
                             |             |\     API call
                             |             |
                             |-------------|
```

注释原话把黑盒边界说得很清楚："WiFi 驱动可被视为黑盒，它对上层代码一无所知——TCP/IP 栈、事件任务等统统不认识；它能做的只有接收上层 API 调用，或向 `esp_wifi_init()` 初始化的队列投递事件。"你在 BOX-3（十六）处理过的每一个 WiFi 事件，都是这个黑盒从 MAC 电路的原始中断一路加工上来的。而 MAC/BB/RF 电路本身（本章上半场）+ 闭源驱动库（下半场）加起来，才是"WiFi 硬件"的完整边界。

> [!tip] 观察实验：亲眼看一次校准回退（待真机验证）
> 在 ESP32 真机上：`idf.py erase-flash` 擦掉 NVS → 重新烧录任意 WiFi 例程 → 打开串口看启动日志。预期出现 `phy_init: failed to load RF calibration data (0x...), falling back to full calibration`（错误码数值以实测为准），且这次冷启动比平时明显更慢——那是一次全量校准的价钱。再复位一次，该日志不再出现（校准数据已写回 NVS）。对应源码分支：`phy_init.c` L946~969。

---

## 7.7 常见误区与小结

| 常见误区                       | 真相                                                                         |
| ------------------------------ | ---------------------------------------------------------------------------- |
| 「WiFi 是 CPU 软件实现的」     | MAC、基带、RF 都是独立电路，CPU 只跑驱动与上层；SIFS 内回 ACK 靠电路不靠中断 |
| 「模组只是方便焊接」           | 匹配、天线、认证三件事都做完了，每件的隐性成本都是一台仪器                   |
| 「校准数据没用可随手擦」       | 擦掉后每次冷启动都会全量校准，慢且费电；官方注释称擦除是最后手段             |
| 「发射功率 20 dBm 恒定」       | 11b 典型 19.5 dBm，11n MCS7 典型只剩 13 dBm：速率越高，PA 越要回退           |
| 「WiFi 和蓝牙是两颗芯片」      | 两者共享同一套射频前端；esp_phy 的 modem 标志位就是共存机制的家              |
| 「esp_wifi_init 在初始化射频」 | 它初始化软件侧：缓冲池、OSI 适配、supplicant；RF 使能由 WiFi 库自动完成      |

小结：

- WiFi SoC = CPU 子系统（FreeRTOS（二）的主场）+ WiFi 子系统（MAC → 基带 → RF → Balun/开关）+ 共享外设与电源管理；用协议栈分层当地图，MAC 对驱动层、基带对编码/调制层、RF 对 PHY 芯片段，**越往下"改一行重编译"的自由越少**。
- MAC 是芯片里的"帧协处理器"：帧收发 DMA、16 微秒 SIFS 内回 ACK、WPA 加速引擎（CCMP/TKIP/GCMP）、硬件 TSF 对表 beacon——裸机时代定时器中断堆出来的东西，这里全是现成电路。
- 基带把第四章的调制解调固化成电路：MCS0~7 全档位在硬件里，选档算法在闭源驱动库；速率越高 PA 功率越低（19.5 → 13 dBm），是"满格却跑不快"的硬件根源。
- RF 片内集成度极高（LNA/AGC/ADC/调制/片内 PA/Balun 一芯全包），但输出阻抗不是 50 欧——芯片止于 RF 管脚，匹配是板上的活，更强射频要靠外置 FEM（第十章）。
- 模组经济学：买模组 = 买预装调好的整机，三座大山（匹配、天线、认证）全部铲平，认证甚至渗进了固件（多国 PHY init data：SRRC/FCC/CE……）。
- 软件触点三个名字：`phy_init` 分区（PHY 参数模板）、NVS 的 `phy` 命名空间（校准数据，三档校准策略）、闭源库 libphy.a/libnet80211.a（你读不到 MAC 驱动源码的原因）。
- 观察点：erase-flash 擦掉 NVS 后冷启动，日志里能看到一次校准回退与全量校准的时间代价（待真机验证）。

到这一章，芯片内部的分工已经清楚：每块电路负责协议栈的一层。但无论是芯片的 RF 管脚还是模组的 50 欧端口，信号下一步都要经过板子上那些最基础的元件——电阻、电容、电感、二极管。它们在直流世界里是中学物理的老朋友，在射频世界里却会"性情大变"。下一章 [[ch08-passives-in-rf|第八章：四个元件的 RF 角色]]。
