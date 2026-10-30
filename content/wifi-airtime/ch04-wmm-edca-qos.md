---
title: "WiFi 空口调度实战（四）：让路给视频——WMM/EDCA 优先级"
date: 2026-10-30 12:00:00
description: "QoS 层解剖：EDCA 用三条杠杆——AIFS 等更久、CW 更小胜面更大、TXOP 一次拿走更多——把四个接入类排出高低；WMM 默认参数表与 DCF 的对照；图传标 VI 的意义与边界（两路都标 VI 等于都没标）；DSCP→AC 的完整链路：应用层 DSCP、AP 映射表、Linux 侧 SO_PRIORITY 与 hostapd 配置位、ESP32 STA 侧可控性的诚实现状。"
tags: [wifi, wmm, edca, qos, dscp, series]
---

> [!info] WiFi 空口调度实战系列 0. [[wifi-airtime|系列索引]] 1. [[ch01-dcf-contention-basics|第一章]] 2. [[ch02-measuring-airtime|第二章]] 3. [[ch03-aggregation-ampdu|第三章]] 4. **第四章：让路给视频**

# WiFi 空口调度实战（四）：让路给视频——WMM/EDCA 优先级

[[ch01-dcf-contention-basics|第一章]]的 DCF 是「人人平等」：所有站点抽同一范围的退避、等同样长的 DIFS、赢一次发一帧。但现实网络里流量生而不等——一路视频通话丢两帧就卡顿，一个后台备份晚十秒无所谓。这一章拆 EDCA（Enhanced Distributed Channel Access）回答四个问题：**优先级是怎么「排」出来的**（4.1 的三条杠杆）、**四个接入类的典型参数长什么样**（4.2）、**图传标 VI 到底有没有用**（4.3——剧透：两路图传都标 VI 等于都没标）、以及**标记从哪里打进去**（4.4，从应用层 DSCP 一路到 ESP32 的诚实现状）。WMM（Wi-Fi Multimedia）是 Wi-Fi 联盟对 802.11e 这套机制的认证名，两者在本文里当同义词用。

---

## 4.1 三条杠杆：EDCA 的心智模型

EDCA 没有发明新竞争规则，它只是把 DCF 复制了四份，每份调不同的参数，然后把流量分进其中一份。这四份叫**接入类（Access Category，AC）**：AC_VO（语音）、AC_VI（视频）、AC_BE（尽力而为）、AC_BK（背景）。帧进哪个 AC，就按哪个 AC 的规则竞争信道。差别全在三条杠杆上：

1. **AIFS——等更久**：DCF 里发前等 DIFS；EDCA 里每个 AC 有自己的 AIFS = SIFS + AIFSN × slotTime。AIFSN 越大，越晚被允许开始递减退避计数器——**低优先级 AC 连入场券都来得晚**；
2. **CW——胜面更大**：退避计数器从 `[0, CW]` 抽，CWmin 越小，平均抽到的数越小，越先减到 0 抢到信道。高优先级 AC 的 CWmin/CWmax 整体小一截——**同场竞技时胜面更大**；
3. **TXOP——一次拿走更多**：DCF 赢一次竞争只发一帧（发完从零再抢）；EDCA 允许高优先级 AC 赢一次后**在一个 TXOP 时限内连发多帧**（每帧间隔 SIFS，无需重新竞争）。TXOP=0 表示维持「赢一次发一帧」。

把三条杠杆画在时间轴上（以 AIFSN 典型配比示意，slotTime 按 9µs 档物理层）：

```text
信道刚空闲（SIFS 结束处对齐）：
AC_VO │SIFS│slot│slot│← AIFS 到期，开始递减退避（CW 3~7，抽小数）
AC_VI │SIFS│slot│slot│← 同点起步，但 CW 7~15，胜面小一档
AC_BE │SIFS│slot│slot│slot│← 晚一个 slot 才允许递减（CW 15~1023）
AC_BK │SIFS│slot│slot│slot│slot│slot│slot│slot│← 晚五个 slot（CW 15~1023）
       AIFS = SIFS + AIFSN × slotTime；AIFSN 典型：VO/VI=2、BE=3、BK=7
```

两个容易被忽略的细节：其一，**进了 AC 之后规则还是 DCF 那套**——抽退避、空闲递减、碰撞后 CW 翻倍（BEB）、成功后回 CWmin，第一章的账本照常记，只是档位不同。其二，同一个站点自己的两个 AC 也可能同时退避到 0——这叫**内部碰撞（internal collision）**，高优先级 AC 胜出发送，低优先级 AC 按碰撞处理退避重抽。站点的「让路」先在自己体内发生。

## 4.2 参数表：WMM 默认档位与 DCF 对照

四类参数的典型默认值（WMM 规范对 slotTime=9µs 物理层——11a/11g 短时隙/5GHz——给出的默认表；**具体数值以规范版本与 AP 信标实际播报为准**，11b 长时隙档的 TXOP 数值另有不同）：

| AC    | 业务定位 | AIFSN | CWmin | CWmax | TXOP 典型值       |
| ----- | -------- | ----- | ----- | ----- | ----------------- |
| AC_VO | 语音     | 2     | 3     | 7     | 1.504 ms          |
| AC_VI | 视频     | 2     | 7     | 15    | 3.008 ms          |
| AC_BE | 尽力而为 | 3     | 15    | 1023  | 0（赢一次发一帧） |
| AC_BK | 背景     | 7     | 15    | 1023  | 0（赢一次发一帧） |

对照 DCF：DIFS = SIFS + 2 × slotTime，**相当于全线只有一档：AIFSN=2、CW 15–1023、无 TXOP 概念**——比 AC_BE 还少等一个 slot 的「一刀切」。所以 EDCA 不是推翻 DCF，是把 DCF 的参数按队列分了档：VO/VI 拿到更早起跑点加更小的抽签池，VI 再加约 3ms 的连发窗口，BE 维持原状，BK 则被压后五个 slot。

验证 AP 实际播报的参数不需要任何仪器——AP 会在信标里广播自己的 WMM 参数集：

```bash
iw dev wlan0 scan | grep -A6 'WMM:'
# 典型输出形态（iw 的打印格式；数值因 AP 而异）：
#   WMM:  * Parameter version 1
#        * BE: CW 15-1023, AIFSN 3
#        * BK: CW 15-1023, AIFSN 7
#        * VI: CW 7-15, AIFSN 2, TXOP 3008 usec
#        * VO: CW 3-7, AIFSN 2, TXOP 1504 usec
```

注意 TXOP 与 [[ch03-aggregation-ampdu|第三章]]的聚合是乘法关系：TXOP 内连发的不必是零散单帧，而是一整条 A-MPDU——赢一次竞争，抱走一串帧。这也是 VI 档对视频流真正的吸引力所在。

## 4.3 给图传标 VI：意义与边界

回到本系列的痛点场景：局域网内两台机器互传图像，空口争抢严重。直觉的答案是「把图传标成 VI」。先说结论：**对「只有这两台机器在传」的孤立场景，标了也白标**。

原因在 EDCA 的天性：它是**相对**优先级机制，只在「不同 AC 混跑」时起作用。两路图传都标 VI，就是在同一个 AC 里用同一套 AIFS/CW/TXOP 互相竞争——竞争强度与都标 BE 时完全相同，只是换了个名字的抽签池。两人的空口分配最终仍由 DCF 的对称公平性决定（[[ch01-dcf-contention-basics|第一章]]E4 实验里 Jain 指数趋近 1 讲的就是这件事），想改变「两人怎么分」要去 [[ch06-airtime-fairness|第六章]]找答案。

标 VI 真正有用的场景是**混合流量**：

| 场景                                 | 标 VI 的效果                                                           |
| ------------------------------------ | ---------------------------------------------------------------------- |
| 图传 + 同小区有人开视频会议/语音通话 | 双方都在意时延，但 VI 的 TXOP 让图传成串拿走空口，语音（VO）仍更快入场 |
| 图传 + 有人在跑备份/下载/同步        | 图传标 VI、背景流量落 BE/BK，让路关系成立，收益明显                    |
| 两台机器互传图传，别无他人           | 无差别，等于都没标                                                     |
| 图传被误标进 BK                      | 反向让路——被所有 BE/VI/VO 压着打，最需要排查的故障态                   |

所以本章标题「让路给视频」的准确含义是：**让背景流量给图传让路**，而不是让两路图传互分高下。实践中更有用的动作往往是反向的——把可让路的东西（备份、镜像同步、大文件下载）显式压进 BK，让图传留在默认的 BE 也能享受到相对优势。另外注意 TXOP 的副作用：VI 的 3ms 连发窗口在饱和时会挤压 BE 的入场机会，小区里 VI 流量一多，BE 的时延会肉眼可见地变差——优先级是把双刃剑。

## 4.4 标记链路：从 DSCP 到空口

一帧数据从应用到空口，「打标记」的路径是一条链：应用在 IP 头写 DSCP →（若经过有线路由）中间设备可能保留或改写它 → AP 按映射表决定空口 AC（下行方向），或 STA 驱动自己决定（上行方向）。每一环都可能掉链子，逐段看。

**第一环：UP→AC 映射（标准确定的部分）**。802.11 层的优先级叫用户优先级（UP，0–7，即 802.1D/802.1p 的 8 个等级），到 AC 的映射是标准写死的：

| UP   | AC    | 典型业务 |
| ---- | ----- | -------- |
| 0、3 | AC_BE | 默认数据 |
| 1、2 | AC_BK | 背景     |
| 4、5 | AC_VI | 视频     |
| 6、7 | AC_VO | 语音     |

**第二环：DSCP→UP（实现各异的部分）**。IP 层的 DSCP 有 64 个码点，WMM 规范并不强制 DSCP 映射表，业界常见两条路线：显式映射表（代表是 RFC 8325 对实时流的建议：EF/46→UP 6→AC_VO，AF41/34→UP 4→AC_VI，CS1/8→UP 1→AC_BK）；以及「取 DSCP 高三位当 UP」的粗映射。后者有个反直觉的结果：EF(46) 的二进制高三位是 101（=5），按粗映射落进 **AC_VI 而非 AC_VO**——两条路线对同一个码点给出不同答案，遇到具体设备时以它的映射表/实测为准，别背口诀。

**第三环：谁在哪里执行映射**。发送方是无线 STA 本体时，AC 由 STA 自己的驱动决定（看它认 skb 优先级还是认 DSCP，因驱动而异）；发送方在有线侧、数据经 AP 转发下无线时，AC 由 AP 决定——AP 能看到的是 IP 头里的 DSCP，所以这条路上 DSCP 标记才有意义。

### Linux 发送侧：两条可复现的标记路径

发送端是 Linux（含树莓派）时，最可靠的是直接设 socket 优先级——mac80211 把 `skb->priority` 的 0–7 按 802.1D 表映射到 AC：

```c
// 应用层：SO_PRIORITY 直接决定上行帧的 AC（5 = 802.1D 视频）
int up = 5;
setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &up, sizeof(up));
```

若发送端不归你改、但流量经你的 Linux 盒子中转，可在 mangle 表给 IP 头打 DSCP，指望下游 AP 的映射表接管（AP 认不认，用下一小节的方法验证）：

```bash
# 把发往 5001 端口的流量标成 AF41（视频交互档）
iptables -t mangle -A POSTROUTING -p tcp --dport 5001 -j DSCP --set-dscp-class AF41
```

验证空口侧到底落进了哪个 AC，要在 **Monitor 模式**下抓——managed 模式下内核递给抓包工具的是剥掉 802.11 头的以太帧，QoS 控制字段根本不可见：

```bash
iw dev wlan0 set type monitor && ip link set wlan0 up   # 会断开连接，测完 set type managed 还原
tshark -i wlan0 -T fields -e wlan.qos.priority 2>/dev/null | sort | uniq -c
# 输出每行「帧数 UP值」；图传流量应聚集在 4/5（VI），默认未标则是 0（BE）
```

### AP 侧：hostapd 的 WMM 配置位

自建 AP（树莓派/OpenWrt 上跑 hostapd）时，整张参数表可以显式落地。hostapd 官方示例配置里的默认块（恰与 4.2 的 WMM 默认表一致；**注意 cwmin/cwmax 是指数**——真实 CW = 2^n − 1；txop_limit 单位是 32µs）：

```ini
wmm_enabled=1
# cwmin/cwmax 为指数：cwmin=4 → CW=15；txop_limit 单位 32µs：94 → 3008µs
wmm_ac_bk_aifs=7
wmm_ac_bk_cwmin=4
wmm_ac_bk_cwmax=10
wmm_ac_bk_txop_limit=0
wmm_ac_be_aifs=3
wmm_ac_be_cwmin=4
wmm_ac_be_cwmax=10
wmm_ac_be_txop_limit=0
wmm_ac_vi_aifs=2
wmm_ac_vi_cwmin=3
wmm_ac_vi_cwmax=4
wmm_ac_vi_txop_limit=94
wmm_ac_vo_aifs=2
wmm_ac_vo_cwmin=2
wmm_ac_vo_cwmax=3
wmm_ac_vo_txop_limit=47
```

改完重启 hostapd，用 4.2 的 `iw scan` 复核信标播报。另有 `wmm_ac_xx_acm=1` 可对该 AC 开启准入控制（要求流先做 TSPEC 协商才准用），家用场景基本用不上，知道有这个位即可。

### ESP32 侧：可控性有限的诚实现状

若图传发送端是 ESP32（[[esp32-s3-box-3|ESP32-S3-BOX-3 工程实战]]那类 STA），现状要讲清楚：**esp_wifi 公开 API 不提供逐帧指定 AC/TID 的接口**，数据帧落哪个队列由驱动内部策略决定（通常按业务类型默认进 BE）；常被问到的 `esp_wifi_80211_tx` 原始注入接口，文档也明确只支持**非 QoS 数据帧**——那条路连 QoS 头都带不上。所以 ESP32 图传的 QoS 优化，收益排序实际是：

1. **流量自身形状**：发送块大小、节奏控制与突发抑制（[[ch07-pacing-and-structure|第七章]]的主场）——这比任何标记都更可控；
2. **AP 侧的相对关系**：把同小区可让路的流量压进 BK、或自建 AP 用 hostapd 调档——AP 是四个 AC 参数真正的持有者；
3. **PHY 层底子**：信号好、速率高、聚合正常（[[ch05-rate-and-channel-width|第五章]]），每帧占的信道时间短，比优先级之争收益大。

顺带一句公道话：即使某个固件真给了上行打 VI 的口子，它也改变不了 4.3 的结论——对端那路图传同样标 VI 时，两个还是同池竞争。

## 4.5 诚实边界：家用 AP 的默认与真正该调的事

家用 AP 的现实：**WMM 开箱即开，且多数固件根本不提供关闭开关**。这不是偷懒——802.11n 起，HT/VHT/HE 高速率与聚合绑定在 QoS 数据帧上，关掉 WMM 意味着自废武功退回 11a/g 速率，没有厂商愿意留这个开关。参数也几乎不可调：家用固件极少暴露 AIFS/CW/TXOP，能调的往往只有「WMM 开关」（若有）和个别游戏的 QoS 白名单。想动真格的参数，路径是自己跑 hostapd（OpenWrt/树莓派）。

对图传场景，真正值得动手的清单按性价比排序：

- **排查图传有没有掉进 BK**（默认不会，但若路径上有设备按端口/协议改写 DSCP，就可能被动降档）——用 4.4 的 monitor 抓包看 UP 分布，这是唯一必查项；
- **混合流量小区**：把备份/同步/下载类流量显式压进 BK（发送端 `SO_PRIORITY` 1/2，或中间盒打 CS1），图传留 BE 即可吃到相对优势——比两边都抢 VI 更稳；
- **确有必要再标 VI**：图传与视频会议共存的场景，图传标 VI 的收益主要来自 TXOP 连发窗口与聚合的乘法效应，且要接受它挤压 BE 的副作用；
- **别指望调参拯救饱和小区**：EDCA 排的是「谁先入场、谁多拿」，不创造一微秒的空口容量——账本还是 [[ch02-measuring-airtime|第二章]]那本。小区已饱和时，优先做的是减负载、提速率、修信号，而不是改四个 AC 的档位。

## 4.6 小结

- EDCA = 把 DCF 复制四份、各调参数：AC_VO/VI/BE/BK。三条杠杆——AIFS 管入场早晚、CW 管抽签胜面、TXOP 管赢一次拿多少；进了 AC 内部规则仍是 DCF/BEB，同站两 AC 撞车先内部裁决。
- WMM 默认表（9µs slot 档典型值，以规范版本与信标播报为准）：VO/VI 的 AIFSN=2、BE=3、BK=7；CWmin 从 VO 的 3 到 BE/BK 的 15；TXOP 仅 VO/VI 非零（典型 1.504/3.008ms）。DCF 相当于全线共用「AIFSN=2、CW 15–1023、单帧」的一刀切档。
- 标记链路：UP→AC 是标准写死的（0/3→BE、1/2→BK、4/5→VI、6/7→VO）；DSCP→UP 因实现而异，RFC 8325 显式表与「取高三位」粗映射对 EF(46) 给出 VO/VI 两种答案——以设备实测为准。
- 图传标 VI 的边界：相对优先级只在混合 AC 场景起效，两路图传都标 VI 等于都没标；更实用的动作是把可让路流量压进 BK。ESP32 STA 侧无逐帧 AC 接口（esp_wifi_80211_tx 仅支持非 QoS 数据帧），收益大头在流量形状与 AP 侧。
- 家用 AP 的 WMM 默认全开且基本不可调（高速率绑定 QoS 数据帧）；真正要管的是「图传别落 BK」与混合流量的相对关系；饱和小区的解药在减负载与 PHY 层，不在优先级。

优先级解决的是「谁先入场」；而每一帧占多久的空口，由速率与信道宽度决定——下一章进入 PHY 侧的账：MCS 与码率怎么读、信道宽度翻倍为什么吞吐不翻倍、图传该挑哪个频宽档。[[ch05-rate-and-channel-width|下一章]]。
