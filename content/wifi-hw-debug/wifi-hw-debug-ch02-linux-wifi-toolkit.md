---
title: "WiFi 硬件调试实战（二）：Linux 无线工具链"
date: 2026-10-27 12:00:00
pin: false
description: "把第一章的分层取证落到手上工具：先用 30 秒地图认清 Linux 无线子系统从应用到 RF 的分层结构，明确每层插管子的位置；然后逐个上手 iw（dev/list/scan/link/station dump/event）、wpa_cli（status/log_level/认证阶段日志）、hostapd 与 OpenWrt 侧 logread/ubus、内核 dmesg 报错对照表与 debugfs 计数器，最后速览 ESP32 侧 esp_wifi 事件与日志接口，收尾给一张「想看 X → 用 Y」速查总表。所有命令真实可复制，日志样例均标注格式示意，不虚构读数。"
tags: [wifi-hw-debug, WiFi, Debugging]
---

# WiFi 硬件调试实战（二）：Linux 无线工具链

> [!info] WiFi 硬件调试实战系列 0. [[wifi-hw-debug|系列索引]]
> 上一章：[[wifi-hw-debug-ch01-debug-methodology-toolbox|第一章：调试方法论与工具箱]]
> **第二章：Linux 无线工具链**（当前章）
> 下一章：[[wifi-hw-debug-ch03-ota-sniffing|第三章：空口抓包实战]]

## 本章装备清单

| 分类 | 装备                            | 价格/状态 | 用途                                   |
| ---- | ------------------------------- | --------- | -------------------------------------- |
| 已有 | Linux 笔记本（WSL2 可做软件侧） | ✅ 免费   | 主力取证机：iw/wpa_cli/dmesg           |
| 已有 | 家里路由器                      | ✅ 免费   | 扫描对象、station dump 的对端          |
| 可选 | OpenWrt 设备或 Linux SBC        | 家里找    | AP 侧视角（hostapd/logread/ubus）      |
| 可选 | ESP32/ESP32-S3 真机 + USB 线    | ~几十元   | 嵌入式侧视角（esp_wifi 事件与日志）    |
| 提醒 | 监听模式实验留给第三章          | —         | 本章全部命令在正常 STA/AP 模式即可运行 |

## 2.1 内核无线子系统 30 秒地图

用 `iw` 之前，先花 30 秒看清你到底在哪一层插管子。Linux 无线栈从上到下是一条清晰的流水线：

```text
┌─────────────────────────────────────────────────────┐
│ 应用层   NetworkManager / wpa_cli / iperf3 / 你的程序 │  ← 你最常站的一层
├─────────────────────────────────────────────────────┤
│ 守护进程 wpa_supplicant(STA) / hostapd(AP)            │  ← 认证/关联/密钥由它驱动
├─────────────────────────────────────────────────────┤
│ 用户态↔内核接口  nl80211（netlink）/ wext(遗留)       │  ← iw 走这一层
├─────────────────────────────────────────────────────┤
│ 内核     cfg80211（配置/扫描/ regulatory）             │
│          mac80211（SoftMAC 通用 MAC 层，多数驱动用）   │
├─────────────────────────────────────────────────────┤
│ 驱动     iwlwifi / ath9k / mt7921u / brcmfmac ...     │  ← 厂商差异集中地
├─────────────────────────────────────────────────────┤
│ 固件     芯片内跑的 blob（崩溃、断言在这层）          │  ← 日志常只有一行
├─────────────────────────────────────────────────────┤
│ RF       PA/LNA/天线/晶振/电源 —— 电磁波出发          │  ← 本系列 Part III
└─────────────────────────────────────────────────────┘
```

记住三层职责边界，工具选择就不再靠猜：

| 层        | 负责什么                                  | 谁在管          | 出问题时的口供在哪里            |
| --------- | ----------------------------------------- | --------------- | ------------------------------- |
| 配置/扫描 | 信道、 regulatory、扫描请求、加密套件协商 | cfg80211        | `iw` 的返回值                   |
| 认证/密钥 | 与 AP 走 802.11 认证、关联、4-way 握手    | wpa_supplicant  | `wpa_cli` 日志与事件            |
| MAC/队列  | 重传、聚合、速率自适应、省电              | mac80211 + 驱动 | `iw station dump` 计数器、dmesg |
| 固件      | PHY 控制、部分 MAC 功能                   | 厂商 blob       | `dmesg` 里的 firmware crash 行  |

> [!tip] 「调试时你在哪一层插管子」
> 第一章说取证成本从低到高，这张图就是那个顺序的物理对应：`iw` 问的是 cfg80211/mac80211 这层的**账本**（计数器、协商结果）；`wpa_cli` 问的是**流程**（认证走到哪一步了）；`dmesg` 问的是**驱动与固件**（报错与崩溃）；空口抓包（第三章）则绕过整个协议栈直接看电磁波上说了什么。顺序不对，就会拿着烙铁去查一个 `wpa_cli` 一眼能看出密码错误的问题。

本章按这张地图从上往下走。

## 2.2 iw 实战：cfg80211/mac80211 的账本

`iw` 是 nl80211 的命令行前端，替代老的 `iwconfig`。以下命令均在 STA 模式验证过语法，输出字段名为内核 `nl80211.h` 与 `iw` 文档口径。

### 2.2.1 iw dev：我的网卡是谁

```bash
iw dev
# 输出要点（字段为真实输出结构，数值略）：
# Interface wlan0
#   ifindex 3
#   wdev 0x1
#   addr xx:xx:xx:xx:xx:xx        ← 本机 MAC
#   type managed                   ← managed=STA, AP=AP, monitor=监听
#   channel 6 (2437 MHz), width: 20 MHz, txpower 20.0 dBm
```

三件事立刻可读：接口名、当前模式（`type`）、当前信道/带宽/发射功率。调试的第一步永远是确认你**以为**在操作的和**实际**在操作的是同一块网卡、同一个信道。

### 2.2.2 iw list：读 capabilities 段

`iw list` 打印网卡全部能力，输出很长，但调试只关心三段：

```bash
iw list
# 重点段一：Supported interface modes —— 有没有 * monitor
# 重点段二：Frequencies/Band 段 —— 每个信道一行，后面跟标志：
#   [no HT40-] [no HT40+] [disabled] ...
#   当前禁用/受 regulatory 限制的信道直接标 disabled
# 重点段三：Capabilities: 0xxxx —— HT capability 位图解码出的明细行
#   HT20/HT40, RX LDPC, max A-MPDU length, RX MCS 索引列表
```

逐项说怎么读：

| 看什么       | 在哪段                         | 调试含义                                                      |
| ------------ | ------------------------------ | ------------------------------------------------------------- |
| 监听模式支持 | Supported interface modes      | 没列 `* monitor` 的网卡做不了第三章的空口抓包，换卡前先看这里 |
| 信道可用性   | Band 1/Band 2 的 Frequencies   | 想用信道 12/13 却 `disabled`，多半是 regulatory domain 没设对 |
| 带宽上限     | Frequencies 行的 HT40/VHT 标志 | 「连上却只有 20 MHz」的硬件前提先在这里确认（第六章）         |
| MCS 支持范围 | RX MCS 列表                    | 两台设备 MCS 集差异可解释速率协商瓶颈                         |
| VHT/HE 段    | Band 2 之后的 VHT Capabilities | 5 GHz 上是否有 80/160 MHz、MU-MIMO 能力                       |

### 2.2.3 iw scan：读邻居与 RSSI

```bash
sudo iw dev wlan0 scan | less
# 每个 BSS 块的常见字段（真实字段名，数值以实测为准）：
# freq: 2437 / signal: -55.00 dBm / SSID: myhome
# capability: ESS Privacy ...        ← Privacy 置位 = 有加密
# RSN:  * version: 1
#        * group cipher: CCMP         ← 组加密
#        * pairwise ciphers: CCMP     ← 单播加密
#        * authentication suites: PSK ← PSK(密码) 或 802.1X(企业)
# RSNSecurityCapability: ... / BSS DTIM period: 2
```

扫描结果就是 AP 的自我介绍信，四个用途：**对比信号**（同一 SSID 多个 BSS 的 signal 差值就是漫游决策依据，第五章用）；**确认加密方式**（RSN 段与你的 supplicant 配置对不上是「连不上」经典根因，第四章）；**看邻居信道占用**（哪些信道有哪些 BSS，粗版频谱分析）；**读 DTIM/能力位**（省电行为相关，第十章）。

### 2.2.4 iw link 与 iw station dump：链路体检单

STA 模式看自己：

```bash
sudo iw dev wlan0 link
# SSID myhome / freq: 2437 / signal: -55.00 dBm
# tx bitrate: 72.2 MBit/s MCS 7 short GI
# rx bitrate: 1.0 MBit/s (iw 5.x 起部分驱动会报 rx bitrate)
```

AP 模式（或 IBSS/mesh）看每个客户端的完整账本——这是吞吐量问题取证的主力命令：

```bash
sudo iw dev wlan0 station dump
# Station xx:xx:xx:xx:xx:xx (on wlan0)
#   signal:   -60.00 dBm
#   tx bitrate:   65.0 MBit/s MCS 6
#   rx bitrate:   72.2 MBit/s MCS 7 short GI
#   tx packets:   12345   tx bytes: 12345678
#   tx retries:   678     tx failed:  12
#   tx duration:  1234567 us
#   rx packets:   23456   rx bytes: 23456789
#   beacon signal avg: -61.00 dBm  beacon int: 100 TU  beacon lost: 0
#   connected time: 1234 seconds / authenticated / associated / authorized
```

关键字段的调试含义：

| 字段             | 含义                    | 怎么用                                                         |
| ---------------- | ----------------------- | -------------------------------------------------------------- |
| `signal`         | 最近几帧的平均 RSSI     | 与 tx bitrate 对照：信号好速率却低 → 干扰/重传在拖累速率自适应 |
| `tx bitrate`     | 当前协商的发射 MCS/速率 | RSSI 正常但 bitrate 常年低位 → 查重传与信道占用                |
| `tx retries`     | 重传帧计数（累计值）    | **看斜率不看绝对值**：两次采样间隔 10 s，斜率高 = 链路在挣扎   |
| `tx failed`      | 重传耗尽被丢弃的帧      | 持续增长 = 对端基本收不到，优先怀疑距离/遮挡/固件              |
| `beacon lost`    | 丢失的 beacon 数        | 持续 >0 = 空口质量差或 AP 侧 beacon 出问题，掉线前兆           |
| `connected time` | 连接保持时长            | 掉线排查时确认是否刚重连过                                     |

> [!note] 计数器都是累计值
> `tx retries`/`tx failed` 从驱动加载起累计，单看数字毫无意义。正确姿势是间隔采样取差值，配合 `watch -n1` 直观观察斜率。不同驱动对部分字段（尤其 `rx bitrate`、`tx duration`）的支持程度不同，字段缺失不代表链路异常。

### 2.2.5 iw event：事件流监控

```bash
sudo iw event -t   # -t 打印时间戳，-f 打印帧内容(需内核支持)
# 事件样例（字段为真实事件类型，时间与 MAC 为示意）：
# 12:00:01.234 wlan0: new station events / connected (authorized)
# 12:00:35.567 wlan0: disconnected (local request) reason: 3: DEAUTH_LEAVING
# 12:00:40.890 wlan0: scan started / scan completed
```

`iw event` 把 cfg80211 层的连接/断开/扫描/监管域事件实时吐出来。它是第五章掉线分析的主力：掉线发生时这里会记下 `disconnected` 与 `reason` 码，与 wpa_cli 事件、AP 侧日志三方对时，就能判断 deauth 是谁先发起的。现在先把这条命令挂上，第三章抓包时它会是最便宜的旁证。

## 2.3 wpa_supplicant 侧：流程的口供

`iw` 看账本，`wpa_cli` 看流程。连接过程的每一步——扫描、认证、关联、4-way 握手、组钥安装——都由 wpa_supplicant 驱动，它的日志是「连不上」案例的第一现场。

### 2.3.1 status 与 log_level

```bash
wpa_cli status
# 关键字段（真实字段名）：
#   wpa_state=COMPLETED        ← SCANNING/AUTHENTICATING/ASSOCIATING/4WAY_HANDSHAKE/COMPLETED
#   ssid=myhome / bssid=xx:..  ← 正在用的网络
#   ip_addr=192.168.1.23       ← COMPLETED 但没有 ip = 卡在 DHCP，别再赖 WiFi
#   key_mgmt=WPA2-PSK

wpa_cli log_level DEBUG      # 运行时调日志级别(及 log_level INFO/WARNING 等)
wpa_cli log_level INFO       # 取证完调回去，DEBUG 很吵
```

`wpa_state` 是状态机读数：卡在 `SCANNING` 查信号与 SSID 拼写，卡在 `AUTHENTICATING` 查认证方式，卡在 `4WAY_HANDSHAKE` 第一嫌疑是密码错误。**状态停在哪，问题就在哪一步**——这是第四章逐阶段取证的总纲。

### 2.3.2 debug 日志常见行解读

开 DEBUG 后的日志按认证流程分四段（以下**行格式示意**，展示结构与关键词，非实测记录；不同版本措辞略有出入，认关键词即可）：

| 阶段       | 日志关键词（格式示意）                                | 正常表现                              | 异常线索                                    |
| ---------- | ----------------------------------------------------- | ------------------------------------- | ------------------------------------------- |
| 扫描       | `Starting AP scan` / `Scan finished`                  | 扫到目标 SSID 且 `freq`/`signal` 合理 | 扫不到 → 信号/regulatory/SSID 配置          |
| 认证/关联  | `Trying to associate` / `Authentication response`     | 关联后进入 4-way                      | `status_code=16` 类拒绝 → AP 侧拒绝你       |
| 4-way 握手 | `EAPOL: ... start` / `WPA: key negotiation completed` | M1-M4 走完，`PTK` 安装                | 反复 `EAPOL-Key timeout` → 密码错或空口丢帧 |
| 组钥       | `WPA: Group Key ... GTK` / `key_mgmt` 完成            | GTK 安装后 `COMPLETED`                | 卡 GTK → 多播/组播路径问题                  |

两个高频关键词提前认识：`EAPOL` 是 4-way 握手的承载协议，日志里 `EAPOL` 相关行密集出现说明卡在密钥协商；`CTRL-EVENT-DISCONNECTED` 与 `CTRL-EVENT-CONNECTED` 是 supplicant 对外发的状态广播，第五章会把它与 `iw event` 的时间线对齐。

> [!tip] 快捷取证姿势
> 前台跑一次 `wpa_supplicant -i wlan0 -c /etc/wpa_supplicant.conf -dd`（-dd = 最详尽日志），比后台守护进程的日志更容易读。故障复现时终端里从头滚到尾，第一处 `FAIL`/`timeout` 字样基本就是答案。企业网（802.1X/EAP）场景同理，`EAP` 段会多出身份认证细节。

## 2.4 AP 侧：hostapd 与 OpenWrt

站端说「我没错」，就得去 AP 侧对质。AP 侧工具随系统不同，这里给两种最常见环境。

**hostapd（裸 Linux/嵌入式通用）**。hostapd 日志同样按流程分段（关键词真实、行内容为格式示意）：`wlan0: STA xx:.. IEEE 802.11: associated`（关联请求到达）、`STA xx:.. WPA: ... EAPOL-Key timeout`（握手超时——站端密码错的 AP 侧典型表现）、`AP-STA-DISCONNECTED`（站离开）。密码错误的握手失败、DTIM/省电导致的异常，站端没口供时 hostapd 日志常常一句话定案。

**OpenWrt（路由器调试最常见环境）**：

```bash
logread | grep -i -e hostapd -e wireless   # 系统日志里筛无线相关行
ubus call network.wireless status          # 所有 radio 的信道/模式/关联站列表(JSON)
ubus call network.wireless up              # 整机无线重启(复现用)
```

| 命令                                | 看什么                                    | 典型用法                               |
| ----------------------------------- | ----------------------------------------- | -------------------------------------- |
| `logread`                           | hostapd/radio 状态变化、deauth 记录       | 配合 `logread -f` 流式跟踪掉线事件     |
| `ubus call network.wireless status` | 各 radio 的 `channel`/`htmode`/`stations` | 确认 AP 实际信道与站表（对比站端视角） |
| `ubus list network.wireless`        | 该对象是否存在                            | 排查 ubus 服务本身                     |

注意对时：AP 侧日志与站端 `iw event`/`wpa_cli` 的时间基准必须先对齐（第五章给对时方法），否则「谁先发起 deauth」的判断全是错的。

## 2.5 内核侧：dmesg 对照表与 debugfs

### 2.5.1 dmesg 常见无线报错

```bash
sudo dmesg -w | grep -i -e wlan -e wireless -e firmware   # 流式跟踪内核消息
sudo dmesg -T                                             # -T 带可读时间戳
```

高频报错对照表（报错文案按主流驱动常见措辞归纳，措辞因驱动而异，认模式不认原文）：

| 报错模式（常见措辞示意）                                 | 所在层 | 含义与第一反应                                       |
| -------------------------------------------------------- | ------ | ---------------------------------------------------- |
| `deauthenticating ... reason=N`                          | cfg    | 站或 AP 主动解除认证；**reason 码是第五章的主菜**    |
| `Failed to send ... firmware asserts` / `firmware crash` | 固件   | 固件崩溃，驱动通常自动重载固件；先升级驱动/固件版本  |
| `Microcode SW error detected` / `HW issue` 类            | 固件   | 同上，iwlwifi 系固件异常的常见措辞                   |
| `hardware reset` / `restart needed` / `interface reset`  | 驱动   | 驱动级复位；与固件崩溃常成对出现                     |
| `Failed to initialize ... -110` 类超时错误码             | 驱动   | 初始化超时（-110 = ETIMEDOUT），查供电/总线/驱动版本 |
| `capabilities/regulatory changed` / `regulatory domain`  | cfg    | 监管域变化导致信道被禁，`iw reg set` 相关（见下）    |

```bash
iw reg get      # 当前监管域；country 00 = 未设置，部分信道会被禁用
sudo iw reg set CN   # 按所在地区设置(需内核 CONFIG_CFG80211_DEFAULT_KERNEL_BUF...)
```

> [!warning] 内核时间戳与真实时间
> `dmesg` 默认时间戳是开机秒数，`-T` 转成挂钟时间但依赖系统时钟已同步。做三方对时（站端/AP/空口）前先统一时间基准，这是第五章的硬前提。

### 2.5.2 /sys/kernel/debug/ieee80211 能看什么

挂载 debugfs 后（多数发行版默认已挂）：

```bash
mount | grep debugfs                      # 确认已挂载
ls /sys/kernel/debug/ieee80211/phy0/      # 每个 phy 一个目录
```

典型可见内容：`netdev:wlan0` 下的 station 子目录（RSSI 统计、RC 速率自适应统计）、驱动私有目录（如 iwlwifi 的 fw/replay 计数、ath 系的 airtime 统计）。用途与边界：

| 能看什么           | 典型路径形态                       | 价值                               |
| ------------------ | ---------------------------------- | ---------------------------------- |
| 每站的 PHY 统计    | `.../netdev:wlan0/stations/<MAC>/` | RSSI 均值、最后Seen 时间、速率统计 |
| 速率自适应内部状态 | 驱动私有文件（minstrel 系较全）    | 解释「为什么速率卡在某档」         |
| 队列与 airtime     | 驱动私有文件                       | 第六章信道占用分析的低层视角       |

**必须注明**：这里的目录树**驱动相关，不同芯片可见内容不同**——mac80211 通用部分较稳定，厂商私有文件五花八门，且读这些计数器本身可能有性能开销，取证时用完即走，别在生产设备上挂着不管。它定位为「账本比 `iw` 更细的一层」，日常排障 `iw station dump` 已覆盖八成需求。

## 2.6 ESP32 侧速览：esp_wifi 事件与日志

嵌入式侧的「工具链」长得完全不同——没有 shell，但事件模型更清晰。

**事件流**：esp-idf 的 WiFi 事件通过 `esp_event` 总线分发（注册 `WIFI_EVENT_*` 与 `IP_EVENT_*` 处理器），`WIFI_EVENT_STA_DISCONNECTED` 事件自带 `reason` 字段，其取值集合就是乐鑫口径的断连原因码——与第五章的 802.11 标准原因码对照阅读，能看出固件在标准码之外扩展了多少「自家诊断」（如 beacon 超时、握手超时的细分码）。断连重连的完整事件模型已在 [[ch16-wifi-events|BOX-3（十六）]] 走读过，那边是「代码里怎么接事件」，本章补的是「排障时怎么读事件」。

**日志级别**：`esp_wifi_set_log_level()`（配合 menuconfig 中 Wi-Fi 日志开关）可调 WiFi 组件日志详略，特殊调试版本还支持按子模块（PHY/init 等）选择性打开。日常排障 IDF monitor 是主力：

```bash
idf.py monitor          # 串口日志 + 重启复位 + 交互(退出: Ctrl+] )
idf.py monitor --print_filter="wifi:W,wpa:I"   # 按组件过滤日志级别
```

**与既有系列的咬合**：和 [[ch18-esp32-wifi-lwip-integration|lwIP（十八）]] 的咬合点在**驱动边界**——那边讲清了 WiFi 驱动把报文交到 netif、再由 lwIP 接管的整条链路；本章补充边界**下侧**的取证手段：当 lwIP 层看到「网卡 up 但丢包」时，`esp_wifi` 的事件与统计（`esp_wifi_get_statistics` 类接口，字段口径待核对具体 IDF 版本）就是把嫌疑从协议栈下推到驱动/RF 的第一站。这种「lwIP 看 L2 以上、esp_wifi 看 L2 以下」的分赃方式，和本章 2.1 的分层地图在嵌入式上是一一对应的。

## 2.7 收尾：想看 X → 用 Y 速查总表

| 想看什么                     | 用什么                                             | 备注                       |
| ---------------------------- | -------------------------------------------------- | -------------------------- |
| 网卡/模式/当前信道           | `iw dev`                                           | 第一步永远先做             |
| 网卡能力(监听/频段/带宽/MCS) | `iw list`                                          | 第三章选卡依据             |
| 邻居 BSS 与 RSSI             | `sudo iw dev wlan0 scan`                           | RSN 段看加密方式           |
| 链路质量单次体检             | `sudo iw dev wlan0 link`                           | signal + tx bitrate        |
| 客户端重传/失败账本          | `sudo iw dev wlan0 station dump`（间隔采样看斜率） | 吞吐问题主力               |
| 连接/断开事件流              | `sudo iw event -t`                                 | 掉线分析旁证               |
| 连接状态机停在哪一步         | `wpa_cli status` 看 `wpa_state`                    | 卡哪一步查哪一步           |
| 认证/4-way 流程细节          | `wpa_supplicant -dd` 前台日志                      | 现场复现最直接             |
| AP 侧口供                    | hostapd 日志 / `logread -f`                        | 与站端先对时               |
| AP 实际信道与站表            | `ubus call network.wireless status`（OpenWrt）     | 站端视角的对照组           |
| 固件崩溃/驱动复位            | `sudo dmesg -w`                                    | 报错模式对照 2.5.1 表      |
| 监管域与被禁信道             | `iw reg get` / `sudo iw reg set CN`                | 「信道 12 扫不到」先查这里 |
| 更细的每站统计/RC 状态       | `/sys/kernel/debug/ieee80211/phy...`               | 驱动相关，用完即走         |
| ESP32 断连原因码             | `WIFI_EVENT_STA_DISCONNECTED` 事件的 `reason` 字段 | 乐鑫扩展码 vs 标准码       |
| ESP32 串口日志               | `idf.py monitor --print_filter=...`                | Ctrl+] 退出                |

**小结**：Linux 无线调试的三张口供单——`iw` 是 cfg80211/mac80211 的**账本**（结果与计数器），`wpa_cli` 是 supplicant 的**流程**（走到哪一步），`dmesg` 是驱动固件的**病历**（报错与崩溃）；AP 侧 hostapd/logread 提供对照组，ESP32 侧事件流是同一套思想的嵌入式形态。计数器一律看斜率不看绝对值，日志对时先于对质。

下一章把取证推进到协议栈之外：用监听模式网卡直接看空口上说了什么——beacon、认证、关联逐帧读，见[[wifi-hw-debug-ch03-ota-sniffing|第三章：空口抓包实战]]。

### 本章事实出处清单

| 事实                                     | 出处                                                |
| ---------------------------------------- | --------------------------------------------------- |
| iw/wpa_cli/hostapd/logread/ubus 命令语法 | 各工具官方 man page 与 --help 口径                  |
| station dump/link/scan 字段名            | 内核 nl80211 头文件与 iw 源码字段口径               |
| 输出数值（RSSI/bitrate/retries 等）      | 均为「真实输出结构 + 数值略」或字段说明，未虚构读数 |
| wpa_supplicant/hostapd 日志行            | 标注「格式示意」，认关键词                          |
| dmesg 报错措辞                           | 按主流驱动常见措辞归纳，标注措辞因驱动而异          |
| ESP32 事件模型与 log 接口                | esp-idf 官方 API 参考口径；统计接口字段「待核对」   |
