---
title: "WiFi 空口调度实战（二）：先看见再动手——空口占用的测量"
date: 2026-10-30 12:00:00
description: "测量先行：iw survey dump 算信道占用率（busy/active，>70% 判饱和）并按 rx/tx 拆分定位谁在吃空口；iw station dump 读每站重传率、信号与速率，分诊「弱信号速率悬崖」与「碰撞」两类病因；monitor 模式抓 Data 帧 retry 位（tshark 过滤）与 ESP32 侧可用观测点；配套实验 ch02-airtime-probe 的真实解析结果与测量基线表。"
tags: [wifi, airtime, iw, survey, monitor-mode, tshark, series]
---

> [!info] WiFi 空口调度实战系列 0. [[wifi-airtime|系列索引]] 1. [[ch01-dcf-contention-basics|第一章]] 2. **第二章：先看见再动手**

# WiFi 空口调度实战（二）：先看见再动手——空口占用的测量

同一个局域网里两台机器互传图像，速度死活上不去——[[ch01-dcf-contention-basics|第一章]]已经从机制上回答了「为什么」：CSMA/CA 让所有人竞争同一条看不见的公路，车越多每辆车分到的时间越少。这一章回答「现在公路到底有多堵、堵在路上的是谁、有多少是白白烧掉的」：三类证据与各自的取证工具（2.1）、金标准 `iw survey dump`（2.2）、每站体检 `iw station dump`（2.3）、monitor 模式抓重传帧与 ESP32 侧观测点（2.4）、配套实验与测量基线表（2.5）。工具全部是 Linux 现货，树莓派即可开跑。

---

## 2.1 原则先行：不能优化看不见的东西

空口优化的第一步不是改参数，而是建立测量。没有基线数字，调优只能凭感觉——调完也无法证明有没有用；本系列后面每一章动手之前，都先回到这一章的仪表盘。

「互传图像卡」这个症状背后，空口侧要找的是三类证据：

| 证据       | 回答的问题                     | 量纲            | 主工具                                |
| ---------- | ------------------------------ | --------------- | ------------------------------------- |
| 信道占用率 | 信道时间被用掉了多少（供给）   | busy/active (%) | `iw survey dump`（2.2）               |
| 重传率     | 用掉的时间里多少是浪费（效率） | retries/packets | `iw station dump`、monitor（2.3/2.4） |
| 时延抖动   | 应用最终感受到的症状（结果）   | ms 级波动       | `ping`/`iperf3`（应用侧）             |

三者是一条因果链：占用率高 → 竞争窗口里碰撞概率上升 → 重传率升 → 同样多的数据占用更多空口 → 占用率更高（正反馈恶化）；到应用层才表现为延迟、抖动与吞吐塌陷。所以取证从占用率与重传率入手——它们是因，抖动是果。图像互传若走摄像机那套 RTSP/ONVIF 栈，码流本身对抖动与丢帧的敏感度可以再参考 [[onvif-deep-dive|ONVIF 协议深度解析]]取流相关章节；本章只管空口侧。

时延抖动的最小观测，两条命令先备着（应用侧症状取证，第七章做节奏调控时还会回来）：

```bash
ping -i 0.2 192.168.1.64          # 200ms 间隔的 RTT 序列，看波动形态（尖刺 vs 整体抬升）
iperf3 -c 192.168.1.64 -u -b 30M  # UDP 模式，报告 jitter 与丢包率
```

## 2.2 金标准：iw dev <iface> survey dump

占用率测量的金标准是直接问驱动「射频看到的世界」，不经抓包推断：

```bash
sudo iw dev wlan0 survey dump
```

输出按信道块组织（每块一个 `Survey results for` 头），字段布局如下（数值取自配套实验的 fixtures 样例，2.5 详）：

```text
Survey results for wlan0:
	frequency:			2412 MHz
	in use:				yes
	noise:				-92 dBm
	channel active time:		1000000 ms
	channel busy time:		764000 ms
	channel receive time:		321000 ms
	channel transmit time:		298000 ms
	extended channel busy time:	45000 ms
```

字段读法一张表：

| 字段                    | 含义                                            | 在公式里的角色 |
| ----------------------- | ----------------------------------------------- | -------------- |
| `channel active time`   | 采样统计窗内射频在信道上的总时间                | **分母**       |
| `channel busy time`     | CCA 判定「信道忙」的时间（含本机 rx/tx 与他方） | **分子**       |
| `channel receive time`  | 本机接收占用的时间                              | busy 的子集    |
| `channel transmit time` | 本机发送占用的时间                              | busy 的子集    |
| `extended channel busy` | HT40 等扩展信道的忙时间（副信道）               | 参考项         |
| `noise`                 | 底噪，干扰会把它抬高                            | 参考           |

一条时间轴把公式画直：

```text
采样窗 ＝ channel active time（分母：射频开启且在信道上）
├────────────────────────────────────────────────────────────────┤
│ 本机 tx │空闲│ 本机 rx │ 他方流量/干扰 │空闲│ 本机 tx │ …        │
└────────────────────────────────────────────────────────────────┘
busy% ＝ busy / active × 100 ＝ (本机 tx ＋ 本机 rx ＋ 他方占用) / active
```

三个读数层层定位：

1. **busy/active 即占用率**。本系列的工程约定是 **>70% 视为饱和**（阈值即配套实验源码里的判定线，业界常见的饱和经验线也在这个量级；具体数值以现场基线为准）——此时再多的调度技巧也只是挤牙膏，该换信道或减负载了。分档表见 2.5。
2. **rx/tx 拆分定位谁在吃**。在发送机上 tx 份额高，说明本机就是大户；rx 份额高，说明对端（或同信道的别人）在说；**「其余 busy」＝ busy − rx − tx**，即他方 BSS 与非 WiFi 干扰占用的时间——这块大，问题不在你家设备，在邻居（换信道，见 [[ch05-rate-and-channel-width|第五章]]的信道选择）。
3. **多块输出里只有 `in use: yes` 是当前工作信道**，其余是扫描过的信道；非工作信道的 busy 可作邻道干扰的参考，但统计窗不同，数值不完全可比。

两个必须知道的坑：

- **计数器是累计值**。survey 的时间字段与 station 的计数都从接口启用（或关联）起累加，直接做比值得到的是「自启用以来的平均」；要测某个时间窗的占用，取前后两个时间点的**差值**再算比例——2.5 的采集脚本按轮次落 CSV，正是为了留出差分的原料。
- **在谁身上测**。两台互传机器之一上测，busy 会被本机流量主导；要中立的「这条信道整体多堵」，用第三台空闲机器（或网关上非转发口的网卡）测。另外各计数器口径以驱动实现为准，跨芯片比绝对值意义不大，**纵向对比**（同一设备前后两轮）才有意义。

## 2.3 每站体检：iw dev <iface> station dump

占用率说「信道整体多忙」，station dump 说「每个站点的链路质量与浪费程度」。角色决定视野：AP 侧（如跑 hostapd 的树莓派网关）列出每个关联客户端；STA 侧只列出对端 AP 一条。两机互传的场景，在 AP 上跑一次就能同时看到双方：

```bash
sudo iw dev wlan0 station dump
```

每个站点一段（节选自配套实验 fixtures 样例）：

```text
Station 3c:71:bf:9a:1c:44 (on wlan0)
	inactive time:	12 ms
	tx packets:	50000
	tx retries:	18500
	tx failed:	2100
	signal:		-52 dBm
	signal avg:	-54 dBm
	tx bitrate:	144.4 MBit/s
```

| 字段         | 读法                                                                      |
| ------------ | ------------------------------------------------------------------------- |
| `signal`     | 瞬时 RSSI；`signal avg:` 是均值，看趋势更稳                               |
| `tx retries` | 发出但未获 ACK 而重发的帧数——重传率分子                                   |
| `tx failed`  | 重传上限后放弃的帧数——应用层卡顿与上层重传的直接来源                      |
| `tx bitrate` | 速率自适应当前档位（MCS 协商的结果），与 signal 对照着读                  |
| `TID xx:` 行 | 按 WMM 业务流拆分的计数，是 [[ch04-wmm-edca-qos\|第四章]]的素材，本章跳过 |

**重传率 = tx_retries / tx_packets**（同样是累计值，开窗要差分）。信号档位是业界常用工程经验（非规范数字，厂商文档口径不一）：约 -60 dBm 以内良好，-67 dBm 是常被引用的「语音/视频可用」经验线，-70 dBm 以下进入覆盖问题区。

重传率高的两条主因，用三列联读就能分诊：

| 组合          | signal         | tx bitrate | 重传率 | 病因                   | 处置方向                                                     |
| ------------- | -------------- | ---------- | ------ | ---------------------- | ------------------------------------------------------------ |
| 弱信号悬崖    | 差（<-70 dBm） | 被压得很低 | 高     | 覆盖/距离/障碍物       | 射频层：改善覆盖、换位，见 [[wifi-rf-hw\|WiFi 射频硬件入门]] |
| 碰撞/隐藏节点 | 好（>-60 dBm） | 正常档位   | 高     | 多设备同时发、互听不见 | 调度层：本系列主题（QoS/公平/节奏）                          |

「速率悬崖」的恶性循环值得记住：信号弱 → 速率自适应降档 → 同样的字节数要发更久 → 占用更多空口 → 信道更挤——所以**信号差最终也表现为信道忙**，这就是 2.2 与 2.3 必须联读的原因。碰撞分支里的隐藏节点是地下室经典病例：A、B 都在 AP 覆盖边缘且互相听不见，各自的 CCA 判定「闲」，同时开火，两败俱伤——信号列看不出任何异常，只有 monitor 抓帧能实锤（2.4）。

配套实验样例里的两个站点正好是分叉两侧的教科书样本（构造样例，数值为设计值）：站 1 信号 -52 dBm、速率 144.4 MBit/s，重传率却高达 37%——信号好速率高还狂重传，指向碰撞；站 2 信号 -67 dBm、速率掉到 72.2 MBit/s，重传率仅 7.5%——链路慢但干净，是弱信号下坡路的开始。

## 2.4 亲眼看帧：monitor 模式与 retry 位

survey/station 是统计视角，要「看见」浪费本身，得抓帧。802.11 Data 帧的 Frame Control 里有一个 **retry 位**：首发帧置 0，重传帧置 1（接收端以此去重）。monitor 模式让第三台机器只听不说——不参与竞争、不影响空口，却能看见信道上所有人（含 AP）的帧：

```bash
# 第三台 Linux 机器（树莓派即可），别在你唯一的 SSH 链路上做
sudo nmcli device set wlan0 managed no       # 让 NetworkManager 放手（按发行版调整）
sudo iw dev wlan0 interface add mon0 type monitor
sudo ip link set mon0 up
sudo iw dev mon0 set channel 6               # 必须与被观测 AP 同信道
```

```text
（infrastructure 模式：A、B 互传 ＝ A→AP、AP→B 两跳空口）

  机器 A（发图）──①──▶ AP ──②──▶ 机器 B（收图）
                        │
                        │ 射频只收不发，不参与竞争
                     mon0（第三台机器，monitor 模式，同信道）
```

retry 位在抓包里的样子：

```text
A ── Data(seq=123, retry=0) ──▶ AP           未收到 ACK（碰撞 / 弱信号丢帧）
A ──（竞争退避后重发）────────▶
A ── Data(seq=123, retry=1) ──▶ AP ◀── ACK
      ↑ mon0 视角：同一 seq 出现两次，第二次 retry=1 —— 一次可观测的重传
```

tshark 过滤与统计（display filter 用 `-Y`，字段 `wlan.fc.retry`）：

```bash
# 谁在重传：按发送方 MAC 汇总重传帧数，降序一目了然
sudo tshark -i mon0 -Y 'wlan.fc.retry == 1' \
  -T fields -e wlan.sa | sort | uniq -c | sort -rn

# 全量 Data 帧（type==2）的 retry 位分布：0=首发 1=重传，两者之比即重传占比
sudo tshark -i mon0 -Y 'wlan.fc.type == 2' \
  -T fields -e wlan.fc.retry | sort | uniq -c

# 存盘离线分析（配合 Wireshark 看 TID/速率/信号细节）
sudo tshark -i mon0 -w /tmp/airtime.pcapng
```

注意事项：monitor 支持度因驱动而异——树莓派板载博通芯片（brcmfmac）的 monitor 能力随内核版本起伏（帧注入历来受限，纯抓包一般可用），稳妥路线是选 mac80211 全量支持的 USB 网卡，以实际驱动为准；环境准备（系统烧写、权限、排错）见 [[rpi-lab|树莓派实验室]]。

**ESP32 侧的观测点**。esp_wifi 固件是闭源黑盒，拿不到逐帧 retry 计数，但「让计数器说话」的思路不变：RSSI 有公开 API——STA 角色 `esp_wifi_sta_get_ap_info()` 的 `rssi` 字段、AP 角色 `esp_wifi_ap_get_sta_list()` 拿每个客户端的 rssi，把 2.3 的信号维度搬到 ESP32 侧；吞吐用 esp-idf 自带的 iperf 示例（`examples/wifi/iperf`）在同一空口下实测；应用层走 lwIP 时，打开 lwipopts.h 的统计开关（`LWIP_STATS`/`MIB2_STATS`）看 UDP/TCP 层的收发与丢包计数。固件侧计数 + 网关侧 survey，两边夹逼定位——这与 [[lwip-deep-dive|lwIP 深度解析系列]]调试章的方法论一脉相承。设备若是 [[esp32-s3-box-3|ESP32-S3-BOX-3]] 这类成品模组，观测面完全相同。

## 2.5 配套实验：ch02-airtime-probe

> [!tip] 🧪 配套实验：ch02-airtime-probe
> 本章 2.2/2.3 的字段读法与阈值判定，固化成一个 C11 零依赖解析器：喂 `iw` 的两类 dump 文本，输出占用率、rx/tx 拆分与每站重传率，超阈值即告警。源码直达：[airtime_probe.c（代码浏览）](/static/code/#/wifi-airtime-labs/ch02-airtime-probe/airtime_probe.c)、[完整工程](/static/code/#/wifi-airtime-labs/ch02-airtime-probe/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/wifi-airtime-labs/ch02-airtime-probe)。

解析器对样例数据的真实解析结果（摘自工程 run.log，为解析器自检输出——fixtures 是按 iw 输出布局构造的样例，数值为设计值，非真机实测；真机数据由采集脚本现场取）：

```text
== iw survey dump 解析（fixtures/survey_sample.txt，接口 wlan0）==
[survey 1] freq=2412 MHz  in-use=YES  noise=-92 dBm
    active=1000000000 us  busy=764000000 us  rx=321000000 us  tx=298000000 us  extbusy=45000000 us
    信道占用 busy=76.40%  rx 份额=32.10%  tx 份额=29.80%  其余 busy=14.50%
    >>> 饱和预警: busy 76.40% > 70%，信道时间已被占满（排查邻道/干扰或换信道）
[survey 2] freq=2437 MHz  in-use=n/a  noise=-95 dBm
    信道占用 busy=35.00%  rx 份额=30.00%  tx 份额=5.00%  其余 busy=0.00%

== iw station dump 解析（fixtures/station_sample.txt，接口 wlan0）==
[station 1] 3c:71:bf:9a:1c:44  signal=-52 dBm  tx_bitrate=144.4 MBit/s
    tx: packets=50000 bytes=9412877 retries=18500 failed=2100
    重传率 = 18500/50000 = 37.00%
    >>> 重传偏高: 37.00% > 30%（链路质量差/信号弱，降速率或改善覆盖）
```

自检将解析结果与源码内编码的期望值逐项比对，34 项全部 PASS（run.log 末行 `自检汇总: 34/34 PASS`）。样例的两个细节顺带验证了解析健壮性：单位归一（iw 打印 ms、内核语义为 µs，比例值不受影响、绝对值必须归一）与干扰行免疫（`signal avg:`、`TID 00:` 行不会误匹配）。

真机采集用 `collect.sh`（bash + awk，循环执行两类 dump，加 ISO 8601 时间戳追加 CSV；每轮落的是累计计数器原值，开窗分析时对相邻行差分——呼应 2.2 的坑）：

```bash
sudo ./collect.sh -i wlan0 -o /home/pi/airtime.csv -t 30   # 每 30s 一轮，Ctrl-C 停止
sudo ./collect.sh -n 1 -o /home/pi/airtime.csv             # crontab 用：跑一轮即退
# 现场快照直接喂解析器看报告：
sudo iw dev wlan0 survey dump > /tmp/s.txt
sudo iw dev wlan0 station dump > /tmp/t.txt
./airtime_probe /tmp/s.txt /tmp/t.txt
```

> [!NOTE]
> 脚本状态**待真机**（README 显式标注）：尚未上真树莓派验证，宿主上已用 iw 桩脚本回放 fixtures 干跑 2 轮通过，CSV 行列与解析器输出一致。真机注意 iw 需要 root。

最后是**测量基线表**——把 2.2/2.3 的读数收拢成一张可以贴在墙上的分档表：

| 指标           | 健康     | 警戒          | 饱和/异常                     |
| -------------- | -------- | ------------- | ----------------------------- |
| 信道占用 busy% | <40%     | 40%–70%       | **>70%（饱和预警）**          |
| 重传率         | <10%     | 10%–30%       | **>30%（重传偏高）**          |
| signal         | >-60 dBm | -60 ~ -70 dBm | <-70 dBm（覆盖问题）          |
| tx failed      | 0 或零星 | 持续增长      | 与 retries 同量级（链路濒危） |

阈值口径要诚实：70% 与 30% 两条判定线定义在实验源码顶部（`BUSY_SATURATION_PCT`/`RETRY_HIGH_PCT`），中间分档与信号档位是本系列的工程经验约定——802.11 规范不规定这些数字，现场应以「空载时先测一轮」的自基线为准。

## 2.6 小结

本章 2.2/2.3/2.4 的三件取证工具——`survey dump`（占用率）、`station dump`（链路质量）、monitor 模式抓包（帧级证据）——后续章节合称**三件套**。

- 空口争抢的三类证据按因果排序：**占用率是因头（供给）、重传率是浪费（效率）、时延抖动是症状（结果）**——先测前两个，第三个留给应用侧 `ping`/`iperf3`。
- `iw survey dump` 是占用率金标准：**busy/active 即占用率**，>70% 判饱和；rx/tx 拆分与其余 busy（busy−rx−tx）定位谁在吃空口；计数器是累计值，开窗要差分。
- `iw station dump` 是每站体检：重传率 = tx_retries/tx_packets；signal、tx bitrate、重传率三列联读分诊——**弱信号速率悬崖**（射频层，去 [[wifi-rf-hw|WiFi 射频硬件入门]]）还是**碰撞/隐藏节点**（调度层，本系列主场）。
- monitor 模式 + `wlan.fc.retry` 过滤器实锤重传；ESP32 侧固件黑盒，用公开 API 的 RSSI、iperf 吞吐与 lwIP 统计计数夹逼。
- 配套实验 ch02-airtime-probe：自检 34/34 PASS；`collect.sh` 待真机，采集-差分-分档的流程即本章方法的可复现落地。

测量告诉我们「忙到什么程度、浪费了多少」，但还没有动手机会。下一章拆掉占用高的第一个结构性原因：每个 Data 帧都要独立竞争一次信道——**聚合（A-MPDU）**让一次竞争摊到一串帧上，是所有现代 WiFi 提效的第一站，也是后续讨论公平与节奏的地基。[[ch03-aggregation-ampdu|下一章]]。
