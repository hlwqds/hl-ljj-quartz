---
title: "WiFi 硬件调试实战（五）：案例——掉线与漫游"
date: 2026-10-27 12:00:00
pin: false
description: "掉线案例章：先把「隔墙就断」「漫游卡十几秒」「每晚定时掉」三类现象分开，再逐层取证——deauth 与 disassoc 的语义区别、IEEE 802.11 高频 reason code 分类表、空口抓包判断「谁先发 deauth」、站端 iw/ESP32 日志与空口 pcap 的对时方法（单调钟与墙钟陷阱）、省电漏 beacon/弱信号/AP 策略/固件崩溃四大根因家族，最后覆盖 802.11k/v/r 漫游分工、漫游乒乓与粘滞 AP 的取证，并以一条从首条 deauth 到根因闭环的教学时间线收束。软件命令全部可复制，时间线样例标注格式示意。"
tags: [wifi-hw-debug, WiFi, Debugging]
---

# WiFi 硬件调试实战（五）：案例——掉线与漫游

> [!info] WiFi 硬件调试实战系列 0. [[wifi-hw-debug|系列索引]]
> 上一章：[[wifi-hw-debug-ch04-cannot-associate|第四章：案例——连不上]]
> **第五章：案例——掉线与漫游**（当前章）
> 下一章：[[wifi-hw-debug-ch06-throughput-debugging|第六章：案例——吞吐量上不去]]

> [!note] 本章证据口径
> 802.11 reason code 引用 IEEE Std 802.11-2016 §9.4.1.7（Table 9-45），编号与名称已对照 hostapd `ieee802_11_defs.h` 同源定义；ESP32 厂商段（200+）对照 esp-idf `esp_wifi_types_generic.h` 的 `wifi_err_reason_t`；`ap_max_inactivity` 默认值对照 hostapd 官方手册。所有帧序列、时间线、日志样例均标「格式示意」，案例为**教学复盘案例，取材自常见故障模式综述**，非真实事故报告；RSSI 判据为工程经验口径并就地标注。

---

## 5.1 现场引入：三类「掉线」不是一种病

第四章解决「连不上」——连接状态机没走完；本章往后挪一步：**连接建立之后，链路意外终止**。用户口中的「掉线」至少是三种不同的病，混着查必然绕路：

| #   | 用户描述               | 现象特征                                     | 高频真因                                             | 首选取证                   |
| --- | ---------------------- | -------------------------------------------- | ---------------------------------------------------- | -------------------------- |
| 1   | 「隔一堵墙就断」       | 走到会议室/阳台必断，回原位自动恢复          | 弱信号 × 省电漏 beacon 叠加；漫游触发过迟            | RSSI + deauth 方向与原因码 |
| 2   | 「跨 AP 漫游断十几秒」 | 同名 SSID 两台 AP 之间走动，切换时转圈 10 s+ | 漫游决策慢（全信道扫描）+ 完整重认证；双 AP 配置漂移 | 漫游时间线分解（5.6）      |
| 3   | 「每晚固定时间掉」     | 凌晨 3 点整批设备掉线，几分钟内自己恢复      | AP 定时任务（信道优化/踢空闲）；上游定时事件         | 对时 + 空口（5.3/5.4）     |

排查前先答一个最便宜的问题——**是 WiFi 断了，还是网断了**：

```text
掉线了
 ├─ ping 网关通？ → 802.11 链路还活着，断在 DHCP/上游/运营商
 │                 （PPPoE 定时重拨是「每晚固定掉」的经典非 WiFi 答案）
 └─ 不通 / Network is unreachable → 802.11 层真断，本章主战场，从 5.2 下钻
```

总索引的分层取证顺序照用（观测 → 协议 → 驱动固件 → 射频电路），掉线问题的主战场在协议层与驱动固件层。工具盲区回 [[wifi-hw-debug-ch02-linux-wifi-toolkit|第二章：Linux 无线工具链]] 补课，抓包手法见 [[wifi-hw-debug-ch03-ota-sniffing|第三章：空口抓包实战]]。

---

## 5.2 deauth 与 disassoc：谁断谁，断完还能不能重连

802.11 把「拆链」拆成两个动作，语义不同，取证价值不同：

| 帧               | 全名     | 拆掉什么                 | 认证保留？ | 重连起点                         | 典型场景                          |
| ---------------- | -------- | ------------------------ | ---------- | -------------------------------- | --------------------------------- |
| Deauthentication | 解除认证 | 认证关系（关联连带清除） | 否         | 从 Authentication 重新走         | AP 踢人、安全失败、一刀切断       |
| Disassociation   | 解除关联 | 只拆关联关系             | 是         | 可直接发 (Re)Association Request | 漫游时 STA 向旧 AP 告别、负载管理 |

两个关键认知：**deauth 是单向通知，不需要对方同意**——收到方没有「拒绝」选项，这也是它沦为攻击面的原因，802.11w（PMF）为管理帧提供保护正是冲着伪造 deauth 来的，开启 PMF 后非保护拆除会被拒收（ESP32 的 SA-Query 超时见下表）。**帧里 TA（地址 2）就是发起方**：TA = AP 的 BSSID 是 AP 踢我，TA = 我的 MAC 是我先走——方向判定，抓包比任何一侧日志都可靠。

### 高频 reason code 分类表

reason code 就跟在 deauth/disassoc 帧体里。IEEE 802.11-2016 §9.4.1.7 Table 9-45 定义完整编号域（1~66 及保留段），下表按现场频率列高频子集——**完整表见标准原文**：

| 码  | 标准名（缩写）             | 大白话                       | 典型发起者 | 现场含义                                              |
| --- | -------------------------- | ---------------------------- | ---------- | ----------------------------------------------------- |
| 1   | UNSPECIFIED                | 没说原因                     | 双方       | 兜底码，单看无意义，看方向与前后帧                    |
| 2   | PREV_AUTH_NOT_VALID        | 之前的认证不再有效           | AP 为主    | AP 重启丢会话状态、漫游时序错乱、802.1X 会话过期      |
| 3   | DEAUTH_LEAVING             | 发送方要离开 ESS/IBSS        | STA 为主   | 主动断开/驱动重置，单独出现通常不是故障               |
| 4   | DISASSOC_DUE_TO_INACTIVITY | 空闲超时                     | AP         | AP 的 idle timer 到期踢人（帧特征见 5.3）             |
| 5   | DISASSOC_AP_BUSY           | AP 承载不了当前关联数        | AP         | 达到连接数上限，高峰期整批出现                        |
| 7   | CLASS3_FRAME_FROM_NONASSOC | 收到未关联 STA 的 Class 3 帧 | AP 为主    | 双方状态失步：STA 以为还连着，AP 已清了上下文         |
| 8   | DISASSOC_STA_HAS_LEFT      | 发送方要离开 BSS             | STA 为主   | 漫游时对旧 AP 的告别（后接对新 AP 的 auth 才是漫游）  |
| 12  | BSS_TRANSITION_DISASSOC    | BSS 过渡管理引发的拆除       | AP         | 802.11v 引导漫游的配套拆除（5.6）                     |
| 15  | 4WAY_HANDSHAKE_TIMEOUT     | 4-way 握手超时               | 双方       | 密码错、握手包丢失（弱信号）、PMF 协商失败；回第四章  |
| 16  | GROUP_KEY_UPDATE_TIMEOUT   | 组密钥更新超时               | 双方       | GTK 周期更新失败——**整点掉线**（如每 3600 s）先查它   |
| 23  | 802_1X_AUTH_FAILED         | 802.1X 认证被拒              | AP         | 企业网 RADIUS 拒绝/证书过期                           |
| 34  | MISSING_ACKS               | 大量帧收不到 ACK             | AP 为主    | hostapd `disassoc_low_ack` 的踢除码：STA 长时间不应答 |

> [!warning] 口径提醒：reason 域 ≠ status 域
> 不少资料把 34/35 写成「associated not supported」，那混淆了两个编号域：**status code**（关联/认证响应帧里的结果码）与 **reason code**（拆除原因码）是两张表。status 34/35 确实是「能力不支持/无法确认关联」类拒绝；reason 34 是 low-ack 踢除，reason 35 是 EXCEEDED_TXOP（QoS 场景）。抓包先看帧类型再对号入座。

### ESP32 侧：标准段 + 厂商段

ESP32 的 `WIFI_EVENT_STA_DISCONNECTED` 附带 `reason` 与 `rssi`，编号与 802.11 对齐（1~66），另有一段 **200+ 厂商扩展码**——恰恰是掉线排障的高频值：

| 码  | esp-idf 枚举名                  | 含义           | 对应的「人间真相」                             |
| --- | ------------------------------- | -------------- | ---------------------------------------------- |
| 200 | `WIFI_REASON_BEACON_TIMEOUT`    | beacon 超时    | 站侧收不到 beacon：弱信号/省电睡过头           |
| 201 | `WIFI_REASON_NO_AP_FOUND`       | 扫不到 AP      | 重连阶段找不到目标（IDF 5.2 起细分出 210~212） |
| 202 | `WIFI_REASON_AUTH_FAIL`         | 认证失败       | 密码错/认证阶段超时                            |
| 204 | `WIFI_REASON_HANDSHAKE_TIMEOUT` | 握手超时       | 4-way 没走完                                   |
| 206 | `WIFI_REASON_AP_TSF_RESET`      | AP 的 TSF 复位 | AP 重启过——配合「整批同时掉」判 AP 侧          |
| 207 | `WIFI_REASON_ROAMING`           | 正在漫游       | 漫游过渡态，非故障                             |

出处：esp-idf `esp_wifi_types_generic.h` 的 `wifi_err_reason_t`（master 口径；201 的拆分见 IDF 5.2 迁移指南）。事件模型与重连策略的代码走读见 [[ch16-wifi-events|BOX-3（十六）]]。

---

## 5.3 空口取证核心一问：谁先发 deauth

原因码告诉你「哪一类原因」，**帧方向告诉你原因在谁那一侧**，合起来一棵决策树走完大半排障：

```text
看到 deauth/disassoc
 ├─ TA = AP 的 BSSID？── AP 主动断我 → 原因在「我这条链路」或 AP 策略
 │    ├─ reason 4/34，断点前有单播探活、无 ACK → 链路其实早半死（弱信号/省电没醒）
 │    ├─ reason 4，断点与 idle timer 对齐      → 上行静默太久被按策略踢
 │    ├─ reason 5/34，只高峰整批出现           → 负载/容量管理
 │    └─ reason 12，前面有 BTM Request 帧      → 11v 引导拆除（查目标 AP 是否健康）
 └─ TA = STA 的 MAC？── 我先断的 → 原因在站侧
      ├─ reason 3/8，后接对新 BSSID 的 auth → 漫游，正常动作
      ├─ ESP32 reason 200 → 站侧收不到 beacon（弱信号/省电/AP 皆可能，继续分层）
      └─ reason 15/204 → 安装类，回第四章
```

### inactivity/low-ack 踢除的帧特征

hostapd 系 AP（家用路由固件绝大多数基于它）的空闲踢除有清晰的帧指纹：对长时间无上行流量的 STA，AP 先发**若干次单播探活**（缓存下行帧/NULL 帧，等 ACK 或 PS-Poll），连续无应答才动刀。两条可抓包验证的判据：

- **时刻对齐**：idle timer 固定时长计时，拆除断点与其对齐（hostapd 默认 `ap_max_inactivity=300`，见官方手册），多次断连间隔呈固定值或整数倍；AP 内部计时踩在 TBTT（beacon 节拍）上，断点常落在 beacon 周期边界附近。
- **前置探活**：拆除前几百毫秒内 AP→STA 单播帧没有对应 ACK/PS-Poll——「链路早已半死」的铁证，死因多半在站侧（睡太深、信号弱），deauth 只是 AP 迟到的收尸。

### 教学抓包时间线（格式示意）

监听网卡驻留目标信道抓到的片段（**格式示意**，时间戳为示意值）：

```text
No.   时间(s)      方向             类型                  说明
1201  1023.410200  AP -> STA(单播)  Data (more-data=1)    探活：缓存下行帧投递
1202  1023.412800  （无 ACK）       —                     STA 没醒/收不到
1204  1023.438900  AP -> STA(单播)  Data (retry=1)        重试探活，仍无 ACK
...
1350  1323.402300  AP -> STA(单播)  Data (more-data=1)    又一轮探活（+300 s，对齐 idle timer）
1522  1623.401800  AP -> STA        Disassoc (reason=4)   空闲超时，动手
1523  1623.403500  AP -> STA        Deauth  (reason=4)    部分实现再补一刀 deauth
1525  1625.110200  STA -> 广播      Probe Request         STA 重新找网
```

读懂三件事：探活无 ACK 在前、拆除在后（死因不是这次拆除）；探活间隔 300 s 与 `ap_max_inactivity` 对齐；拆除时刻 ≈ beacon 周期边界（示意按 100 ms interval），印证计时踩在 TBTT 上。常用过滤器：`wlan.fc.type_subtype == 0x0c`（deauth）/`0x0a`（disassoc）、`wlan.reason_code == 4`、按 `wlan.ta` 等于 STA MAC 还是 BSSID 区分方向。

---

## 5.4 站端日志对时：让空口和串口说同一门时间

空口 pcap 和站端日志分属两个时钟域，**不对时，一切「同时发生」都是巧合**。

### 三个时钟域的陷阱

| 时钟域               | 代表                               | 陷阱                                               |
| -------------------- | ---------------------------------- | -------------------------------------------------- |
| 墙钟（UTC/本地时间） | `date`、`dmesg -T`、Wireshark 显示 | NTP 校时会**跳变**；时区不同则差 8 小时            |
| 纪元秒（UTC）        | `tcpdump -tt`、`date +%s`          | 无时区歧义，适合做对齐锚点（推荐锚点钟）           |
| 单调钟（开机起算）   | `dmesg` 默认秒数、ESP32 日志时间戳 | 与墙钟差一个「开机时刻」偏移；重启归零；无时区概念 |

`dmesg` 不加 `-T` 打内核单调秒，加 `-T` 才换算墙钟；ESP32 日志时间戳是 `esp_timer` 单调毫秒（自启动起）。**同一份证据里混用两种钟，是掉线排障最常见的翻车点**——日志说 03:00:00、pcap 里 19:00:00，先查钟再查网。

### 对时流程（命令可直接复制）

```bash
# 终端 A：空口侧，纪元秒时间戳（-tt = 秒，UTC 语义），与 date +%s 同钟
sudo tcpdump -tt -i mon0 -w drop.pcap 'type mgt and (subtype deauth or subtype disassoc)'

# 终端 B：站端事件流（-t 打时间戳，-f 打帧内容；工具时间戳口径随版本实现，
# 不猜——用锚点法对齐）
iw event -t -f

# 抓包开始前后各敲一次锚点（长抓包期间 NTP 可能挪动墙钟；pcap 内部时间戳不受影响）
date +%s.%N

# 事后分析：把 pcap 时间戳换算回墙钟核对断点时刻
tcpdump -tttt -r drop.pcap 2>/dev/null | head
```

### ESP32 侧的对照

ESP32 站端的事件流就是 `WIFI_EVENT_STA_DISCONNECTED`（附 `reason`），对时做法：NTP 同步后在事件回调里同时打印墙钟 `time(NULL)` 与默认单调时间戳，一次事件两枚锚点（**格式示意**）：

```c
case WIFI_EVENT_STA_DISCONNECTED: {
    wifi_event_sta_disconnected_t* d = data;
    ESP_LOGI(TAG, "disc reason=%d rssi=%d wall=%lld",
             d->reason, d->rssi, (long long)time(NULL)); /* NTP 同步后的墙钟锚点 */
    break;
}
```

两边对齐后的拼图（**格式示意**）：

```text
pcap (UTC 纪元秒)      iw/esp 日志（换算后）           事件
1769999999.876         02:59:59.876  mono=192840.8s    AP->STA Disassoc reason=4    ← 空口先动刀
1769999999.881         02:59:59.881  mono=192840.9s    esp: disc reason=4 rssi=-58  ← 站端晚 5 ms
1770000000.401         03:00:00.401  mono=192841.3s    STA 发 Probe Request（重新找网）
```

先空口后站端、差值几毫秒量级 → 两边看到的是同一次拆除；这条对应关系立住了，后面所有时间线才敢画进一张图。

---

## 5.5 根因家族逐个过

掉线的根因基本不出四族，逐族过：机制 → 帧特征/日志指纹 → 对策。

### 1）省电模式漏 beacon（睡过头）

机制：STA 关联后进 modem sleep，RF 周期性醒来看 beacon 维持心跳；AP 的组播/广播必须攒到 **DTIM beacon** 才发，DTIM 间隔拉大意味着睡得更深、醒得更稀。睡过头的连锁反应两截：**连续收不到 beacon → 驱动判超时主动断**（ESP32 报 `WIFI_REASON_BEACON_TIMEOUT`，码 200），或 **AP 下行探活等不到唤醒 → low-ack 踢除（码 34）**。连带伤害是组播类业务先坏（mDNS 发现、ARP 延迟）——它们走组播缓存队列，DTIM 越大积压越久。取证：站端 200/34 交替 → 空口核对「探活无 ACK」→ 先调省电再疑射频（`esp_wifi_set_ps(WIFI_PS_NONE)` 做验证性关闭）。省电与功耗预算的完整权衡是 [[wifi-hw-debug-ch10-power-consumption|第十章：功耗调试]] 的主场。

### 2）弱信号 / beacon 丢失（够不着）

灵敏度——多少 dBm 以下开始解调失败——在 [[ch05-rx-chain-sensitivity|射频入门（五）]] 讲过：RSSI 掉到灵敏度附近时，管理帧（低速、重传耐受差）先于数据帧受害。工程经验判据（**经验口径，随网卡/驱动差异大，非标准规格**）：

| 2.4 GHz RSSI 量级 | 链路状态 | 掉线风险                      |
| ----------------- | -------- | ----------------------------- |
| ≥ -65 dBm         | 良好     | 低                            |
| -70 dBm 上下      | 边缘     | 中，漫游应在此前发生          |
| -75 ~ -80 dBm     | 差       | 高：重传激增、beacon 间歇丢失 |
| ≤ -85 dBm         | 接近失效 | 极高，随时断连                |

取证：`iw dev wlan0 link` 看 signal 与 tx bitrate（速率被压到基础速率档是伴生症状）、断连前后 RSSI 曲线、空口重传与 ACK 缺失。对策指向射频层（天线、位置、增补 AP），归第七、八章。

### 3）AP 侧：idle 策略 / 连接数上限 / 双 AP 配置漂移

| AP 侧机制    | 掉线指纹                                | 排查点                                                            |
| ------------ | --------------------------------------- | ----------------------------------------------------------------- |
| idle 踢除    | reason 4，断点与 idle timer 对齐（5.3） | hostapd `ap_max_inactivity`（默认 300 s）、`skip_inactivity_poll` |
| low-ack 踢除 | reason 34，前置探活无 ACK               | hostapd `disassoc_low_ack` 是否开启                               |
| 连接数上限   | reason 5，高峰整批出现、低峰自愈        | hostapd `max_num_sta`、企业 AC 负载均衡策略                       |
| 双 AP 漂移   | 漫游到某台必出问题；跨 AP 参数突变      | 逐台对比 beacon 的 IE（下表）                                     |

同名 SSID 的两台 AP 配置漂移是家庭/小微办公的隐形炸弹——同一台 STA 在两边漫游时，两台的「世界观」必须一致：WPA 模式/PMF（一台 WPA2、一台 WPA2/WPA3 混合 → 漫游后握手慢或失败）、密码（漂移 → 4-way 失败，reason 15）、信道/带宽（一台 40 MHz 一台 20 MHz → 吞吐跳变）、DTIM/beacon 间隔（省电行为突变，另一侧开始漏 beacon）、VLAN/ACL/min-RSSI（只配了一台 → 「只有半层楼会掉线」）。取证：分别抓两台 AP 的 beacon，Wireshark 里并排对比信息元素，tag 级差异一目了然。

### 4）驱动/固件崩溃（栈自己塌了）

指纹最明显的一族，先查它成本最低。Linux STA：`dmesg -T | grep -iE "deauth|disconnect|firmware|crash"`，固件崩溃的典型样子是驱动打印固件错误并自动重启接口（iwlwifi 系的「Microcode SW error detected. Restarting」类日志），随后 wpa_supplicant 报 `CTRL-EVENT-DISCONNECTED ... reason=3 locally_generated=1`——`locally_generated=1` 直接说明拆除是本地发起。ESP32：事件流之外看 task watchdog、panic backtrace、wifi 任务栈溢出；注意崩溃导致的掉线里，掉线是结果不是原因。判别口诀：**掉线前有固件报错 = 塌栈**（升级驱动/固件、查供电→第九章）；**掉线前无本地异常 = 链路问题**，回到前三族。把 WiFi 挂在协处理器上的整机（如 [[wifi-coproc|F429 × WiFi 协处理器]]）还要区分「WiFi 断」与「主控-协处理器链路断」。

---

## 5.6 漫游机制与乒乓：11k/v/r 分工

漫游慢是掉线投诉的第二大类。先把机制摆正：**802.11 从不规定 STA 何时漫游**——「什么时候换 AP」历来是 STA 的私事（自主漫游，各驱动阈值不一），标准只定义换的过程（scan → auth → assoc）。k/v/r 三个 amendment 往这件事里各塞了一块拼图：

| 协议    | 绰号           | 它做什么                                                                  | 抓包特征                                                | 排查点                             |
| ------- | -------------- | ------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------- |
| 传统    | 自主漫游       | STA 按自家 RSSI 阈值决定，被动全信道扫描找新 AP                           | 漫游前一大串 Probe Request 扫全信道                     | 驱动漫游阈值、bgscan 参数          |
| 802.11k | RRM 资源测量   | AP 下发**邻居报告**（附近值得考虑的 BSS）与 beacon 测量，定向扫描少走弯路 | Action 帧 category 5，内含 Neighbor Report IE           | `iw phy` 能力位、是否下发报告      |
| 802.11v | BSS Transition | AP **建议/强制** STA 去某 BSS（BTM），可带 Disassociation Imminent 倒计时 | Action 帧 category 10，Req=8/Resp=9；配套拆除 reason 12 | BTM Response 的 status（0=接受）   |
| 802.11r | FT 快速切换    | 密钥分布式预置（R0KH/R1KH），切换时免完整重认证，只走 FT 子握手           | auth 算法号为 FT（2）的 Authentication 帧               | `mobility_domain`、over-the-air/DS |

分工一句话：**k 告诉 STA 候选在哪（省扫描），v 由 AP 拍板何时去（省犹豫），r 把到岗手续办快（省认证）**。齐了，漫游中断才能压到语音无感的量级；全没有的传统漫游，中断到秒级很常见（**量级经验值，随驱动与部署差异大**）。

### 漫游时间线分解（格式示意）

把一次切换拆段算耗时，健康与否当场现形（**格式示意**，数值为教学示意）：

```text
健康漫游（有 k/v/r）                        问题漫游（传统自主）
t0     STA 决定漫游                          t0     STA 决定漫游
t0→t1  定向 auth + FT 子握手   ~10 ms 量级   t0→t1  全信道主动扫描      300~1000 ms
t1     (Re)Assoc Request/Response            t1     向新 AP auth + assoc
t2     链路可用，IP 不变                     t1→t2  完整 4-way/802.1X   100~500 ms
合计   几十 ms 量级                          t2     链路可用（IP 保留）
                                             合计   秒级，应用层已感知「断」
```

取证要点：漫游期间 **IP 保留**，漫游慢卡的是 TCP 重传而非 DHCP；照 5.4 对时，把 `iw event -t` 里 disconnect → scan → auth → assoc 的时间戳差值填进这张分解图，慢在哪段当场现形。

### 漫游乒乓与粘滞 AP

| 病症     | 特征                                                 | 取证                                                                                             |
| -------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| 漫游乒乓 | 两 AP 信号胶着区，STA 在两个 BSSID 间高频往复        | `iw event -t` 里关联目标 BSSID 交替翻转；空口 (Re)Assoc Request 目标交替；伴随每次切换的吞吐塌陷 |
| 粘滞 AP  | 该走不走：新 AP 明显更好，STA 仍死守旧 AP 到链路快死 | `wpa_cli signal_poll` 显示 RSSI 已低于漫游阈值却无动作；对照驱动/bgscan 阈值                     |

对策：乒乓加迟滞（拉大触发阈值差）+ AP 侧 11v 主动引导；粘滞调 STA 侧扫描策略（wpa_supplicant `bgscan`，如 `bgscan="simple:30:-70:30"`：周期/信号阈值/短扫描间隔）或 AP 的 min-RSSI 挤一下。

### 企业 AP / hostapd 排查点

| 配置键（hostapd 口径）                    | 作用               | 关掉/配错的后果    |
| ----------------------------------------- | ------------------ | ------------------ |
| `rrm_neighbor_report`                     | 开 11k 邻居报告    | STA 盲扫，漫游慢   |
| `rrm_beacon_report`                       | 开 11k beacon 测量 | 无信道负载依据     |
| `bss_transition`                          | 开 11v BTM         | AP 无法引导漫游    |
| `wpa_key_mgmt=FT-...` + `mobility_domain` | 开 11r 快速切换    | 每次漫游完整重认证 |

OpenWrt 上有 usteer/dawn 这类跨 AP 协调器，企业 AC 把决策收进控制器——排查顺序永远是：先确认**能力位开没开**（beacon/Action 帧里看得见），再调**阈值合不合理**。

---

## 5.7 教学案例完整复盘：一条时间线从首条 deauth 到根因闭环

**教学复盘案例，取材自常见故障模式综述**（非真实事故报告）：数十台 ESP32 设备部署在一栋办公楼，每晚 03:00 前后**整批**掉线，几分钟内自行重连，云平台上报断档。完整取证链走一遍：

**第一步：判层。** 设备事件流显示 `WIFI_EVENT_STA_DISCONNECTED`——802.11 层真断，不是上游网断，排除 PPPoE 重拨这类假嫌疑人。

**第二步：对时。** 按 5.4 立锚点（pcap `-tt` 纪元秒 + 设备日志墙钟锚点），把两周断连时刻画直方图：全部落在 03:00:00~03:03 之间，整批、固定、周期性——「每晚固定时间」坐实，矛头指向定时任务。

**第三步：空口抓包。** 驻留目标信道过夜，断点前片段（**格式示意**）：

```text
时间(UTC)       帧方向      内容                      判读
02:59:59.876    AP -> STA   单播 Data (more-data=1)   空闲探活
02:59:59.879    （无 ACK）                            设备深睡没应答
02:59:59.901    AP -> STA   单播 Data (retry=1)       重试探活
03:00:00.402    AP -> STA   Disassoc  reason=4        空闲超时拆除
03:00:00.404    ESP32 日志  disc reason=4 rssi=-52    站端 2 ms 后收到（对时已立）
03:00:03.118    STA -> 广播 Probe Request             重新找网
03:00:05.660    STA <-> AP  auth/assoc/4-way/DHCP 复连  自愈，但上报已断档
```

**第四步：根因闭环。** reason 4 + 探活无 ACK + RSSI 良好（-52 dBm，排除弱信号）→ 设备夜里深睡（长 DTIM 省电）错过探活，被 AP 的 idle 策略收割；而「每晚 03:00 整批」的触发器在 AP 管理平台——凌晨「定时优化」顺带对空闲 STA 执行踢除，两个无害机制叠加成了整批掉线。修复：管理平台关闭该时段踢除（或拉长 `ap_max_inactivity`），设备侧按第十章重校 DTIM/心跳节奏；复测一周断连归零——闭环。

复盘模板值得背下来：**判层 → 对时 → 空口定方向 → 原因码定家族 → 找触发器 → 双侧修复 → 复测归零**。案例 1（隔墙断）与案例 2（漫游慢）套同一模板，只是「定家族」分别落在 5.5.1/5.5.2 与 5.6。

---

## 5.8 根因速查总表

| 证据（方向 + 原因码/特征）             | 根因域           | 下一步取证                           | 对策                                    |
| -------------------------------------- | ---------------- | ------------------------------------ | --------------------------------------- |
| AP→STA，4，断点与 idle timer 对齐      | 空闲策略         | 核对 `ap_max_inactivity`；查上行静默 | 调 idle 时长 / STA 加 keepalive         |
| AP→STA，34，前置探活无 ACK             | 站侧链路半死     | RSSI 曲线 + 省电开关对照实验         | 省电调参（→第十章）或修射频（→七/八章） |
| STA 侧 ESP32 reason 200                | beacon 超时      | 空口看 beacon 是否到达 + DTIM 设置   | 同上，双端各自排查                      |
| STA→AP，3/8，后接对新 BSSID 的 auth    | 正常漫游         | 分解漫游耗时（5.6 时间线）           | 慢则上 k/v/r                            |
| AP→STA，2                              | AP 状态丢失/过期 | AP 是否重启（206 伴生）；802.1X 日志 | 固化 AP 稳定性/会话时长策略             |
| AP→STA，5，高峰整批                    | 连接数/负载上限  | AP 关联数曲线                        | 扩容/负载均衡                           |
| 15/16（4-way/GTK 超时）                | 安装类/密钥周期  | 回第四章；GTK 周期对齐检查           | 密码/PMF/驱动修复                       |
| AP→STA，12 + 前置 BTM Request          | 11v 引导拆除     | BTM 目标 BSSID 是否健康              | 修引导目标/暂关 `bss_transition`        |
| dmesg 固件报错 + `locally_generated=1` | 驱动/固件崩溃    | 崩溃日志全文、版本变更记录           | 升级驱动/固件，查供电（→第九章）        |
| 关联目标 BSSID 高频交替                | 漫游乒乓         | 胶着区信号差值测量                   | 加迟滞/11v 引导/增补 AP                 |
| RSSI 已差但无漫游动作                  | 粘滞 AP          | 对照驱动阈值与 `signal_poll`         | 调 bgscan/min-RSSI/11v                  |
| 整批、固定时刻、秒级自愈               | 定时任务/策略    | 断连时刻直方图 + AP 平台任务表       | 错峰或关闭踢除策略                      |

> [!summary] 收束
> 掉线排障的肌肉记忆三句话：**方向（谁先发 deauth）定侧别，原因码定家族，对时定真凶**。空口说真话，日志给细节，两者必须共用一块表（纪元秒锚点）。下一章把同样的取证功力搬到「连得上但慢」的吞吐量问题上。
