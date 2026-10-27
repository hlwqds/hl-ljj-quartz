---
title: "Thread 调试实战（三）：802.15.4 空口抓包"
date: 2026-10-27 12:00:00
pin: false
description: "让第三块板变成 sniffer：为什么 Thread 的真话在空口——ot-cli 只报告节点「认为」发生了什么，MLE 交互的每一帧才是因果；802.15.4 2.4 GHz 信道 11-26 与 WiFi 信道的重叠图；nRF52840 dongle 刷 sniffer 固件与 Wireshark 的 IEEE 802.15.4 TAP 配置；从 dataset 取 network key 在 Wireshark 配置 Thread 解密的完整步骤；帧解读三层结构——802.15.4 帧头→6LoWPAN IPHC 压缩→UDP/MLE/CoAP，MLE 消息家族表（Discovery/Parent Request/Child ID 三对消息）为第四章铺路；固定信道抓包与 ot-cli 联动的双窗口取证流程；收束为常见过滤器速查表。"
tags: [thread-debug, Thread, OpenThread, Debugging, RF]
---

# Thread 调试实战（三）：802.15.4 空口抓包

> [!info] Thread 调试实战系列 0. [[thread-debug|系列索引]]
> 上一章：[[thread-debug-ch02-openthread-toolchain|第二章：OpenThread 工具链]]
> **第三章：802.15.4 空口抓包**（当前章）
> 下一章：[[thread-debug-ch04-network-formation-commissioning|第四章：组网与入网]]

## 本章装备清单

| 分类   | 装备                                       | 价格/状态 | 用途                      |
| ------ | ------------------------------------------ | --------- | ------------------------- |
| 已有   | Linux 笔记本 + Wireshark                   | ✅ 免费   | 抓包主机与逐帧解析        |
| 已有   | 第二章刷好的 Thread 节点 ×2                | ✅ 已就位 | 被观测的空口流量来源      |
| 需准备 | 第三块 802.15.4 板（nRF52840 dongle 首选） | 百元级    | 刷 sniffer 固件，专职监听 |
| 可选   | 串口终端多开（tmux/screen）                | ✅ 免费   | 3.6 的双窗口联动取证      |

> [!note] 本章证据口径
> sniffer 固件烧录与 Wireshark 配置以 OpenThread 官方文档（openthread.io _Packets and Wireshark_ 类指南）与 Nordic 官方文档口径标注，步骤随工具版本演进以到手版本文档为准；Wireshark 界面项以当前官方文档为准；帧解析示例均为**格式示意/教学复盘案例，取材自常见故障模式综述**，字段值用于讲解结构而非实测记录。本章不虚构任何实测读数。

## 3.1 为什么 Thread 的真话在空口

第二章的 ot-cli 已经很好用了，为什么还要抓包？因为**设备自述与空口真相是两回事**：

| 问题              | ot-cli 会告诉你                 | 空口才能告诉你                                          |
| ----------------- | ------------------------------- | ------------------------------------------------------- |
| attach 为什么失败 | `state` 卡在 `detached`（现象） | Parent Request 发了没回？回了拒了？停在哪条 MLE（因果） |
| 邻居「忽隐忽现」  | `neighbor table` 里 Age 在跳    | 是链路断了重连，还是数据请求没被父节点 ACK              |
| 两节点 ping 不通  | `ping` 超时（现象）             | 路径上哪一跳转发失败、重传了几次、谁没回 ACK            |
| 配网消息没到达    | 无从知晓                        | MeshCoP/CoAP 每一条交互的到达与应答                     |

一句话：ot-cli 是**被告的自述**，抓包是**现场监控**。自述有用，但定罪靠监控。这与 [[wifi-hw-debug-ch03-ota-sniffing|WiFi 调试（三）]] 开篇的论证完全同构——STA 端日志只会说「连接超时」，只有空口能告诉你握手停在哪一帧。Thread 把这套方法原样搬来，只换帧格式：802.15.4 的 127 字节小帧 + 6LoWPAN 压缩头 + MLE/CoAP 消息面。

Thread 抓包还有一项 WiFi 没有的便利：**解密钥匙是静态的**。WiFi WPA2 的会话密钥按握手动态派生（必须抓到 4-way handshake）；Thread 的网络层加密用的是 dataset 里的 **network key**——你手里本来就有（第一章「先核对 dataset」顺手拿到的），任何时候都能解密任何抓包，不需要等待握手。这是 Thread 取证比 WiFi 友好的地方。

## 3.2 信道世界：11~26 与 WiFi 的重叠

802.15.4 在 2.4 GHz 划了 16 个信道（编号 11~26，每 5 MHz 一个，IEEE 802.15.4 口径）。麻烦在于它们与 WiFi 信道在频率上犬牙交错——**每一个 Thread 信道都压在某条 WiFi 信道的裙边或主体之下**：

```text
频率 →  2401      2423      2443      2463    2483 (MHz)
        ├─────────┼─────────┼─────────┼─────────┤
WiFi    ├──Ch1──┤ ├──Ch6──┤ ├──Ch11─┤ (20 MHz 主瓣)
        │        │         │         │
Thread  11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26
        ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤ ├─┤
         ▲      ▲▲▲▲    ▲▲▲▲        ▲▲▲▲          ▲▲
        Ch11   Ch15     Ch19       Ch23         Ch26
        (压Ch1) (压Ch6裙) (压Ch6/11间) (压Ch11裙)  (顶到 2480)
```

工程上记住三个锚点（信道选择策略第九章展开）：**15/20/25/26** 依次错开 WiFi 1/6/11 的主瓣，是共存放置的常见候选；但「错开主瓣」不等于「干净」——WiFi 的物理层旁瓣与邻道泄漏照样盖到 Thread 信道上，链路预算与灵敏度问题见 [[ch05-rx-chain-sensitivity|射频入门（五）]]，干扰与共存的系统观见 [[ch14-interference-coexistence|射频入门（十四）]]。频段背景与信道编号原理 [[ch02-radio-and-spectrum|射频入门（二）]] 已讲透，本章不重复。

对调试的直接影响有两条：其一，**抓包前必须先知道目标网络在哪条信道**——`ot-cli` 的 `scan` 或 `dataset active` 的 Channel 字段，一锤定音；其二，**sniffer 是单信道设备**，跨信道事件（节点换信道走 pending dataset）一只耳朵听不全，这与 WiFi 抓包「单网卡单信道」的视野盲区一模一样。

## 3.3 sniffer 搭建：固件与 Wireshark 配置

### 3.3.1 刷 sniffer 固件（官方文档口径）

主流路线以 openthread.io 官方指南为口径：用 **nRF52840 dongle 刷 sniffer 固件**（Nordic 官方提供产物），插到 Linux 主机当射频头。步骤骨架（具体参数以到手版本文档为准）：

```bash
# 1. 获取 sniffer 固件产物（Nordic 官方 openthread 仓库 / nRF Connect SDK sniffer 示例）
# 2. 烧录到 dongle（用 nRF52840 DK 作 programmer，同第二章 2.2.2）
nrfutil device program --firmware sniffer_nrf52840.hex    # 命令形态以官方文档为准
# 3. 插上主机，确认串口出现（通常 /dev/ttyACM0）
dmesg | tail    # 观察枚举日志
```

ESP32-H2 也有 esp-openthread 的 sniffer/rcp 形态可作替代（Espressif 官方文档口径），但本系列主线以 nRF52840 dongle 为 sniffer——USB 直插最省事。

### 3.3.2 Wireshark 侧配置

sniffer 板对 Wireshark 暴露为一条串口数据流，需要一次性的接口配置（Wireshark **IEEE 802.15.4 TAP** 页面，官方文档口径）：

```text
Wireshark → 编辑 → 首选项 → Protocols → IEEE 802.15.4
  ├─ IEEE 802.15.4 TAP: 勾选启用（TAP 类型用于携带信道等元数据）
  ├─ 「TLVs」按固件文档勾选（Channel/CC24xx 等元数据项）
  └─ Radiesse/CC24xx 类选项按所用固件口径选择
```

然后建一条串口捕获接口（Wireshark 对串口的捕获走 extcap 或管道方案，openthread 官方 Wireshark 指南给出对应脚本/命令），并**把 sniffer 固件锁定信道**——信道设置经固件的串口控制协议下发（Nordic sniffer 固件随附控制脚本，参数以固件 README 为准）：

```bash
# 骨架示意：信道切换经 sniffer 控制脚本下发（以到手固件文档为准）
sniffer_ctrl.py --channel 15      # 目标网在 Ch15（dataset 里查到的）
```

验收动作与 WiFi 系列同款「行为级验证」：先抓 30 秒，若能看到目标网络的 beacon/MLE 帧（Wireshark 里协议列出现 `IEEE 802.15.4`），链路才算通；只看到噪声就是信道不对或天线太远，别急着怪固件。

> [!warning] 单信道纪律
> 每次开抓前默念：sniffer 锁的信道 = 目标网络的信道（`dataset active` 的 Channel 字段）。换网、重 commissioning、pending dataset 生效都会换信道——「突然抓不到了」十有八九不是网死了，是你的耳朵站错了频道。

## 3.4 解密 Thread 流量：network key 进 Wireshark

不解密时你只看得到：帧头（谁发给谁、什么类型）+ 一坨加密载荷——管理面信息（MLE 的多数交互、MeshCoP 配网消息）够定位「交互停在哪」，但应用数据与部分加密管理消息是黑的。配上 network key，Thread 层立刻全部可读。

钥匙从 dataset 拿（第二章 2.3 第五组）：

```bash
> dataset active                 # 结构化列出（在任一网内节点上）
...
Network Key: 00112233445566778899aabbccddeeff      # ← 这就是钥匙（示意值）
Channel: 15
PAN ID: 0x1234
...
```

填进 Wireshark（路径以官方文档为准）：

```text
Wireshark → 编辑 → 首选项 → Protocols → IEEE 802.15.4
  → Decryption keys → 编辑 → 新增
      Key type: Thread
      Key: 00112233445566778899aabbccddeeff    （dataset 里的 network key）
```

生效判据：此前显示 `[Data]`/加密载荷的帧，展开后出现 `6LoWPAN → IPv6 → UDP → MLE/CoAP` 的完整协议栈；MLE 帧（目的端口 19788，Thread 规范口径）是最常见的第一道风景。三个注意点：

| 注意点             | 说明                                                                             |
| ------------------ | -------------------------------------------------------------------------------- |
| 密钥换了要跟着换   | commissioning 重跑、pending dataset 生效都会换 network key——解密突然失效先查这个 |
| 只解 Thread 网络层 | 802.15.4 MAC 层的安全帧（如部分 MAC 层加密场景）另行处理，日常 Thread 调试遇不到 |
| 钥匙别外传         | network key = 整个 Thread 网的通行证，取证记录脱敏后再归档                       |

## 3.5 帧解读：三层结构到 MLE 消息家族

### 3.5.1 802.15.4 帧头

每个帧最前面是 IEEE 802.15.4 MAC 头（IEEE 802.15.4-2006 口径），调试最常看的字段：

| 字段                    | 干什么                                | 调试用途                                      |
| ----------------------- | ------------------------------------- | --------------------------------------------- |
| Frame Control (FCF)     | 帧类型/安全位/ACK 请求/PAN 内压缩     | 判定 Data/Beacon/Command；有没有要求 ACK      |
| Sequence Number         | 帧序号                                | 数重传与丢帧（同一序号重复出现 = 重传）       |
| Dest PAN ID + Dest Addr | 目的 PAN 与地址（短地址或 64 位扩展） | 过滤目标流量；短地址 0xfffe/0xffff 的特殊语义 |
| Src Addr                | 源地址                                | 与 ot-cli 的 `rloc16`/`extaddr` 对号入座      |
| FCS                     | 帧校验                                | Wireshark 标红 = 空口损坏帧（干扰线索）       |

地址换算表（第五章详细展开 RLOC 体系）：ot-cli 里 `rloc16 0x4800` 的节点，在 MAC 头里常以短地址 `0x4800` 出现；64 位扩展地址对应 `extaddr`。抓包过滤设备的第一件事就是用这两个地址建显示过滤器。

### 3.5.2 6LoWPAN 头压缩（IPHC 概念）

802.15.4 帧净荷只有 ~80 字节量级，塞不下完整的 40 字节 IPv6 头 + 8 字节 UDP 头。6LoWPAN 的 IPHC（IP Header Compression）把两者压到几个字节：**可从上下文推导的字段（链路本地前缀、Mesh-Local 前缀、RLOC 接口标识）整段省略，只留变化位**。对调试者的实际影响：

```text
Wireshark 显示的层级（解密成功后）：
IEEE 802.15.4  →  6LoWPAN (IPHC 编码的头部)
               →  IPv6 (Wireshark 已替你解压还原，可读！)
               →  UDP (端口判消息面)
               →  MLE / CoAP / 应用数据
```

关键认知：**Wireshark 会把 IPHC 还原成完整 IPv6 显示**——你在包列表里看到的是解压后的标准 v6 地址，压缩细节只在 6LoWPAN 树节点里。所以「看不懂压缩」不妨碍调试，直接读还原后的 v6 层即可；要排查压缩本身（罕见）再展开 IPHC 位段。

### 3.5.3 UDP 上的三个消息面

解压后的 UDP 端口告诉你在跟哪个消息面打交道（端口值为 Thread 规范口径）：

| 目的端口     | 消息面     | 管什么                                   | 对应章节 |
| ------------ | ---------- | ---------------------------------------- | -------- |
| 19788        | MLE        | 链路建立与维护：加网、链路探测、路由通告 | 四、五章 |
| 61631 (CoAP) | MeshCoP 等 | 网络管理面：配网、dataset 分发、地址查询 | 四、六章 |
| 61631 (CoAP) | 网内应用面 | 供应商用 CoAP 承载的业务/管理消息        | 按产品   |
| 其他         | 应用       | 你自己的 UDP 业务（ot-cli `udp` 试验台） | 第二章   |

### 3.5.4 MLE 消息家族表（为第四章铺路）

MLE（Mesh Link Establishment，UDP 19788）是 Thread 组网的主旋律。四个最高频消息对，一次 attach 的完整编曲就是它们的轮唱（逐帧解读与失败案例在第四章）：

| 消息对                         | 谁发→谁收     | 干什么                                        | 抓包里的特征                               |
| ------------------------------ | ------------- | --------------------------------------------- | ------------------------------------------ |
| **Discovery Request/Response** | 新节点→全网   | 找周边有哪些 Thread 网（按扩展 PAN ID 过滤）  | 广播；Response 带 Beacon 载荷、扩展 PAN ID |
| **Parent Request/Response**    | 新节点→候选父 | 问「谁愿意收我当孩子」；多个 Router/REED 竞答 | 广播 Request；多播 Response（一父一答）    |
| **Child ID Request/Response**  | 新节点→选定父 | 正式入籍：要孩子身份（child ID/地址资源）     | 单播对；此后 `state` 变 `child`            |
| **Link Accept（单发）**        | Router↔Router | Router 间建链， mesh 的横向骨架               | 单播，含链路参数协商                       |

配套的还有 Link Probe/Link Reject、Advertisement（链路维护心跳）与 Data Response（网络数据同步，第五章）等。读 MLE 帧的速成法：Wireshark 里过滤 `mle` 后看 `MLE Command` 字段——Command 名字即语义，对照上表就能读出一场 attach 的全剧情。

> [!tip] 教学速记
> 一场典型 attach 的帧序（格式示意）：Discovery Request → 多个 Discovery Response → Parent Request → 多个 Parent Response → Child ID Request → Child ID Response → （state=child）→ Data Response 同步网络数据。**数得出第几步缺席，就定位得了问题**——这正是第一章「MLE 交互停在哪条消息」取证动作的帧级落地。

## 3.6 取证小抄：双窗口联动流程

sniffer 一只眼看空口、ot-cli 一只眼看设备自述，两边**必须共用一套时钟**才能互证（第一章的三世界纪律）。树莓派/笔记本场景下，主机时钟只有一个，串口日志与 pcap 时间戳天然同源——这正是把 ot-cli 跑在主机侧（仿真或 ot-ctl）的额外红利。标准流程：

```bash
# 窗口 1（空口）：锁定信道开抓，pcap 文件带 UTC 时间戳命名
mkdir -p trace && cd trace
sudo wireshark ... -w $(date -u +%Y%m%dT%H%M%SZ)_ch15.pcapng    # 骨架示意
# 窗口 2（设备）：ot-cli/ot-ctl 侧开着，准备触发动作
screen /dev/ttyACM1 115200        # 被测节点串口（设备世界）
```

联动纪律四条：

| #   | 纪律           | 落地动作                                                                        |
| --- | -------------- | ------------------------------------------------------------------------------- |
| 1   | 先开抓、再触发 | 抓包窗口必须覆盖事件的**前因**（如 attach 从 Discovery 就开始）                 |
| 2   | 动作打标记     | 触发前在 ot-cli 里敲一条无害命令（如 `ping` 一次网内地址）做事件路标            |
| 3   | 时间统一 UTC   | 主机 `timedatectl` 确认 NTP 同步；文件名、日志、pcap 全用同一时区               |
| 4   | 证据三件套归档 | pcap + ot-cli 全程转储（`script` 命令录制串口会话）+ 当时的 `dataset active -x` |

第 4 条的 dataset 归档值得强调：三个月后复盘时，「当时网络密钥是什么」决定了旧 pcap 还解不解得开——把 dataset 快照（脱敏）与 pcap 放在一起，证据链才算完整。

## 3.7 常见过滤器速查表

Wireshark 显示过滤器（802.15.4 与 Thread 相关的高频项，语法以 Wireshark 官方文档为准）：

| 过滤表达式                              | 语义                        | 什么时候用                                |
| --------------------------------------- | --------------------------- | ----------------------------------------- |
| `wpan.dst16 == 0x4800`                  | 按短地址过滤（目的）        | 聚焦某节点的流量（先 `rloc16` 对号）      |
| `wpan.src16 == 0x4800`                  | 按短地址过滤（源）          | 看某节点发了什么                          |
| `wpan.src64 == f6:d3:4a:2b:0c:1d:5e:8f` | 按 64 位扩展地址过滤        | 短地址未分配的入网期节点（用 `extaddr`）  |
| `wpan.frame_type == 1`                  | 只看数据帧                  | 排除 beacon/控制帧的底噪                  |
| `wpan.frame_type == 0`                  | 只看 beacon 帧              | 看周边 Thread 网的存在与参数              |
| `wpan.fcs_ok == 0`                      | 只看校验坏帧                | 空口损坏多 → 干扰/链路质量线索（第九章）  |
| `mle`                                   | 只看 MLE（UDP 19788）       | 组网/拓扑问题的主过滤器                   |
| `mle.cmd == <编号>`                     | 按命令过滤                  | 例：Parent Request 类消息逐帧审（第四章） |
| `coap`                                  | CoAP（MeshCoP/管理/应用面） | 配网与网络数据分析                        |
| `coap.code == 0.02` 之类按需组合        | POST/响应细分               | MeshCoP 交互失败定位（第四章展开）        |
| `udp.port == 19788`                     | MLE 端口（等价 `mle`）      | 备用写法                                  |
| `wpan.dsn == 0x2a`                      | 按帧序号过滤                | 数某个帧重传了几次                        |

组合示例——被测节点入网期的全部关键交互（第四章案例的标准开场）：

```text
wpan.src64 == <extaddr> || wpan.dst16 == <rloc16> || mle
```

---

## 本章小结

- **自述 ≠ 真相**：ot-cli 告诉你节点认为发生了什么，抓包告诉你空口实际发生了什么——attach 失败、忽隐忽现、ping 不通三类问题的因果都在帧里（3.1）。
- **信道是第一步**：802.15.4 信道 11~26 与 WiFi 1/6/11 犬牙交错，15/20/25/26 是共存锚点；sniffer 单信道，开抓前用 `dataset active` 核对 Channel（3.2）。
- **sniffer 三步走**：刷固件（官方文档口径）→ Wireshark 802.15.4 TAP 配置 → 锁信道做行为级验收（3.3）。
- **解密是静态的**：dataset 的 network key 填进 Wireshark 即解全部 Thread 流量，不需要等握手；密钥换了解密就失效（3.4）。
- **帧三层读法**：MAC 头（地址/序号/FCS）→ IPHC（Wireshark 自动还原成 v6，不用怕）→ UDP 端口定消息面（MLE 19788 / CoAP 61631）；MLE 四个消息对是一场 attach 的编曲，数帧定位卡点（3.5）。
- **双窗口联动 + 过滤器弹药**：先开抓再触发、动作打标记、时间统一 UTC、证据三件套归档；速查表回指全系列（3.6、3.7）。

**本章自查清单**（全部打勾再进第四章）：

- [ ] sniffer 板锁定目标信道后，Wireshark 里能看到目标网的 MLE/beacon
- [ ] 填入 network key 后，任选一帧能看到 802.15.4→6LoWPAN→IPv6→UDP 完整展开
- [ ] 能用 `wpan.src16` 过滤出单个节点的流量
- [ ] 能对着 MLE 消息家族表，读出一次完整 attach 的帧序
- [ ] 双窗口流程跑通过一次：pcap 与 ot-cli 转储按同一 UTC 时间戳归档

环境三件套（ot-cli、OTBR、sniffer）至此全部就位，你也已经能「看见」Thread。下一章让它们联动实战：从 dataset 家族到 commissioning 流程，把「入不了网」类症状沿 MLE 状态机逐帧定罪，见 [[thread-debug-ch04-network-formation-commissioning|第四章：组网与入网]]。

### 本章事实出处清单

| 事实                                     | 出处口径                                                                      |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| sniffer 固件、Wireshark TAP/解密配置步骤 | openthread.io 官方 Wireshark 指南与 Nordic 官方文档；参数随版本以到手文档为准 |
| 802.15.4 信道 11~26 划分、帧结构字段     | IEEE 802.15.4-2006 及后继版本                                                 |
| MLE 消息族与 UDP 19788、CoAP 61631 端口  | Thread Specification（1.x 口径）                                              |
| Wireshark 过滤器字段名                   | Wireshark 官方文档（版本间字段可能演进，以实际版本为准）                      |
| 帧序示例与解析值                         | 教学复盘案例，取材自常见故障模式综述；全部数值为格式示意                      |
