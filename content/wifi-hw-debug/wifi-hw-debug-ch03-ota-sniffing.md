---
title: "WiFi 硬件调试实战（三）：空口抓包实战"
date: 2026-10-27 12:00:00
pin: false
description: "让网卡听见空气里的每一句话：先分清 promiscuous 与 monitor 两种「监听」的本质差异——为什么只有监听模式能看到 AP 与 STA 的完整对话；监听网卡怎么选怎么验（`iw list` 一步确认，不迷信商品页）；从托管模式切进 monitor 的完整命令序列与三大经典坑（NetworkManager 抢占、信道漂移、regdomain 限制）；Wireshark 里 radiotap 头怎么读、管理/控制/数据三大帧类型与断连排查最常用子类型的过滤表达式清单；WPA2 解密的配置方法与 4-way handshake 前提、WPA3/SAE 的限制；双网卡工作法与一段可复制的取证脚本——它是后面三章所有案例的标准开场。"
tags: [wifi-hw-debug, WiFi, Debugging, RF]
---

# WiFi 硬件调试实战（三）：空口抓包实战

> [!info] WiFi 硬件调试实战系列 0. [[wifi-hw-debug|系列索引]]
> 上一章：[[wifi-hw-debug-ch02-linux-wifi-toolkit|第二章：Linux 无线工具链]]
> **第三章：空口抓包实战**（当前章）
> 下一章：[[wifi-hw-debug-ch04-cannot-associate|第四章：案例——连不上]]

## 本章装备清单

| 分类   | 装备                                       | 价格/状态     | 用途                                |
| ------ | ------------------------------------------ | ------------- | ----------------------------------- |
| 已有   | Linux 笔记本（`iw`/`tcpdump`/Wireshark）   | ✅ 免费       | 主取证机，切监听模式或当 STA        |
| 已有   | 自家路由器 + 一台被测设备（如 ESP32 真机） | ✅ 免费       | 产生可观测的空口流量                |
| 需准备 | 一块支持监听模式的 USB WiFi 网卡           | 几十元级      | 本章主角；选购与验证见 3.2          |
| 可选   | 第二块同款网卡 + Wireshark/tshark          | 几十元级/免费 | 双网卡工作法（3.6）；逐帧解析与解密 |

> [!note] 本章的证据口径
> 本章全部命令为 Linux 标准用户态工具用法（`iw`/`ip`/`tcpdump`），参数以 iproute2、`iw` 与 tcpdump 官方手册为准；`iw list` 输出为**格式示意**，字段结构以内核 nl80211 文档为准，实际值因网卡芯片而异。Wireshark 过滤表达式为官方文档语法。本章不虚构任何实测读数；帧解析示例均为**教学复盘案例，取材自常见故障模式综述**，字段值用于讲解结构而非实测记录。信道划分、regdomain 概念不重复教，见 [[ch02-radio-and-spectrum|射频入门（二）：信道编号真相]]；命令速查沿用第二章，不重抄。

## 3.1 为什么抓空口不等于抓 eth0：promiscuous 与 monitor 的区别

做过后端的人都有肌肉记忆：查网络问题就 `tcpdump -i eth0`。到了 WiFi 现场自然想 `tcpdump -i wlan0`——然后发现抓到的全是「自己与 AP 之间」的帧，AP 和**别的** STA 的对话一个字节都没有。这不是过滤器写错了，是两种「监听」根本不是一回事：

| 模式            | 内核怎么说（nl80211 iftype） | 收到谁的帧            | 帧要不要被过滤                            | 能看到什么                                           |
| --------------- | ---------------------------- | --------------------- | ----------------------------------------- | ---------------------------------------------------- |
| 普通模式（STA） | `managed`                    | 只收目标 MAC 是自己的 | 硬件/驱动按目的地址过滤                   | 自己的收发；对方重发的管理帧细节看不到               |
| 混杂模式        | `managed` + IFF_PROMISC      | 理论上全收            | 关软件过滤，但**硬件仍按关联的 BSS 过滤** | WiFi 上基本退化为普通模式，别的 STA 流量通常仍收不到 |
| 监听模式        | `monitor`                    | 空口上同信道的全部帧  | 不过滤，逐帧上交                          | beacon/probe/认证/关联/deauth/别人的数据帧——全量真相 |

关键差异在**过滤发生在哪一层**。有线世界混杂模式有效，是因为集线器时代所有帧本来就物理广播到每个端口；而 WiFi 的接收过滤是 **MAC 硬件干的**：目的地址不是自己、也不在组播过滤表里的帧，在芯片内部就被丢弃，根本不递给驱动——混杂模式改变软件栈的态度，改不了硬件的过滤规则。monitor 模式则让芯片不做任何过滤、不关联任何 BSS，把同信道上解调成功的每一个帧（连同物理层元数据）原样上交。一张图看清一个帧在 STA 侧的命运（目标不是自己时）：

```text
空口：AP ──帧（目的地址=STA-B）──> 空中
                     │
        STA-A 的射频前端解调成功
                     │
       ┌── managed 模式 ──┐             ┌── monitor 模式 ──┐
       │ MAC 硬件比对地址：不是我│      │ 不过滤：帧 + radiotap │
       │ → 芯片内静默丢弃       │      │ → 内核 → libpcap → 你 │
       │  （tcpdump 什么都看不到）│    │  （这才是空口抓包）    │
       └───────────────────┘             └───────────────────┘
```

为什么调试必须上 monitor，一句话：**以太网抓包看到的是「点对点电缆上的两次对话」，空口抓包看到的是「一个房间里所有人说了什么、谁没听见、谁重说了一遍」**。第四章「连不上」案例里，STA 端日志只会说「连接超时」；只有空口能告诉你：STA 发了 auth 但 AP 没回（AP 侧问题）、AP 回了 deauth 原因码 2（密码问题）、还是 4-way 做到第三步断掉（密钥/PMF 问题）——这些握手都发生在 802.11 管理层，在有线侧的 IP 抓包里**物理上不可见**。

> [!tip] 软件类比
> managed 模式像「只收自己信箱的信」：邮递员（射频前端）拆开所有信封，但在分拣台（MAC 硬件）就把别人的信烧了。monitor 模式像「站在邮局分拣大厅」：每封过手的信都能登记、复印、标注邮戳（radiotap）。收不到的只剩一种：信号太弱连分拣台都没拆开的信（解调失败，空口抓包的固有盲区，第五章会再遇到）。

## 3.2 监听模式网卡选购：先验货，再谈信仰

### 3.2.1 芯片组阵营与驱动口碑

监听能力不是网卡「功能列表」里的一项，而是**驱动 + 固件**是否把 nl80211 的 monitor 接口实现完整。长期形成的阵营口碑（社区普遍认知，逐型号以到手实测为准）：

| 阵营/驱动             | 代表芯片                   | monitor 口碑                                                           | 备注                                        |
| --------------------- | -------------------------- | ---------------------------------------------------------------------- | ------------------------------------------- |
| ath9k                 | Atheros 较老 PCIe/USB 芯片 | 经典监听王，帧注入/monitor 支持久经考验                                | 多为 2.4 GHz 或双频老芯片，新片难买         |
| ath10k/ath11k         | Qualcomm/QCA 较新 PCIe     | monitor 可用，但部分固件版本有 radiotap 字段不全、无法收管理帧的已知坑 | 固件版本敏感，翻内核邮件列表历史较多        |
| mt76（mt7921u 等）    | MediaTek USB/PCIe          | 近年口碑上升的开源驱动，monitor 支持完整度较好                         | 5 GHz 支持取决于具体芯片                    |
| rtw88/rtw89、r8188 系 | Realtek 各代               | 鱼龙混杂：部分芯片 monitor 可开但丢管理帧、收不全；driver 版本差异大   | 便宜的 USB 小网卡多为此系，**必须到手验证** |
| brcmfmac              | Broadcom SDIO/USB          | monitor 支持有限或需补丁，一般不作为首选                               | 树莓派板载 WiFi 常见，别指望它抓包          |

规则很简单：**买之前查「芯片型号 + 驱动名 + monitor mode」的社区讨论，到手第一件事跑 3.2.2 的验证命令**。商品页写「支持监听」没有约束力——它可能指的是 Windows 下的厂商私有抓包驱动，Linux 下完全不通用。

### 3.2.2 几十元 USB 网卡的现实

这个价位的实物预期要摆正：

- **2.4 GHz 是基本盘**：绝大多数几十元 USB 网卡主打 2.4 GHz；「双频 AC/AX」便宜款未必允许在 5 GHz 上开 monitor。5 GHz 抓包能力完全取决于芯片，**买前按芯片型号查证，到手实测**。
- **天线小、灵敏度有限**：弱信号房间会漏帧——你看到的「AP 没回」可能只是「你没听见」（3.1 的解调失败盲区）。挪位置、换高增益天线重抓，再下结论。
- **吞吐预期**：抓 802.11n 级别流量够用，别指望无损抓 ax 满速；调试以管理帧为主，够用。
- **虚拟机直通**：WSL2/虚拟机需 USB 直通（如 usbipd），宿主 OS 不得占用该网卡——即第一章装备约定的「监听实验需原生 Linux 或直通」。

### 3.2.3 验证方法优先：`iw list` 一锤定音

拿到手，插上，先别装任何厂商驱动，直接问内核：

```bash
# 找到新网卡的接口名（对比插拔前后）
ip link show

# 查该网卡支持的接口模式与频段（假设接口名 wlan1）
iw list | grep -A 12 "Supported interface modes"
iw list | grep -A 6 "Band 1"   # 2.4 GHz 段
iw list | grep -A 6 "Band 2"   # 5 GHz 段（没有这行就是单频）
```

`Supported interface modes` 一段的输出长这样（**格式示意**，实际条目因芯片/驱动而异）：

```text
	Supported interface modes:
		 * IBSS
		 * managed
		 * AP
		 * monitor          # ← 有这一行，monitor 才有入场券
	Band 1:
		Capabilities: 0x...
		HT20/HT40 ...
		Frequencies:
			* 2412.0 MHz [1] (20.0 dBm)     # [信道号] (该域允许的最大功率)
			* 2437.0 MHz [6] (20.0 dBm)
			* ...
	Band 2:                      # ← 缺这段 = 不支持 5 GHz
		...
```

逐行解读：

| 看什么                              | 结论                                                                     |
| ----------------------------------- | ------------------------------------------------------------------------ |
| 列表里有 `* monitor`                | 驱动声明支持监听接口类型——入门券到手                                     |
| `* monitor` 缺失                    | 这块卡在当前驱动下不能抓包，商品页吹得再响也退货/换芯片                  |
| `Band 2` 段存在且含你要抓的 5G 信道 | 5 GHz 抓包可行；注意 DFS 信道可能被 regdomain 禁用（3.3.3）              |
| 频率行后面的 `[N]`                  | 信道号；括号里的 dBm 是该信道本地 regdomain 允许的最大发射功率，非实测值 |

还有一招更狠的**行为级验证**——声明支持不等于收得全，切进 monitor（3.3 的命令）后对着自家路由器抓 30 秒：

```bash
timeout 30 tcpdump -i wlan1 -c 50 'type mgt subtype beacon' -l 2>/dev/null | head -5
```

能稳定抓到自家 AP 的 beacon，才算「监听真的在工作」。声明级过、行为级不过的卡（典型症状：只收数据帧丢管理帧）社区里很常见——这就是为什么本系列把验证放在选购前面。

### 3.2.4 选购要点清单

不指定具体商品型号（市场流转太快，以到手实测为准），按这张清单对芯片型号做功课：

- [ ] 芯片型号可查（商品页或到手 `lsusb` 看厂商:产品 ID），能对应到上表某一驱动阵营
- [ ] 社区有「该芯片 + monitor」的正面讨论记录（Aircrack-ng 官方兼容性页面是好起点）
- [ ] `iw list` 输出含 `* monitor`（到手第一件事）；频段覆盖你要抓的信道
- [ ] 天线可拆（SMA/IPEX 座）；预算允许就买**两块同款**——双网卡工作法（3.6）是后续案例章的默认配置

## 3.3 动手进 monitor：命令序列与三大坑

### 3.3.1 标准切换序列

假设监听网卡是 `wlan1`（用 `ip link` 确认），从 managed 切到 monitor 的完整序列：

```bash
# 1. 停掉网络管理器对该网卡的管理（否则它随时会把接口改回去，见坑 1）
sudo systemctl stop NetworkManager
# 2. 接口必须先 down 才能改类型
sudo ip link set wlan1 down
# 3. 切换接口类型为 monitor
sudo iw dev wlan1 set type monitor
# 4. up 起来
sudo ip link set wlan1 up
# 5. 固定信道（不固定的话驱动可能在频段里漂，见坑 2）
sudo iw dev wlan1 set channel 6
# 6. 验收：确认接口类型与信道
iw dev wlan1 info
# 7. 开始抓包（-s 0 不截断帧；写文件供 Wireshark 离线分析）
sudo tcpdump -i wlan1 -s 0 -w capture.pcapng
```

第 6 步的正常输出应包含 `type monitor` 和 `channel 6 (2437 MHz), width: 20 MHz, center1: 2437 MHz`——两个都对了再开抓，否则后面全是无效工。

### 3.3.2 坑 1：NetworkManager 抢占

症状：切好 monitor、抓了半分钟，接口突然变回 managed 并关联上了邻居 AP，pcap 里混进正常业务流量。根因：NetworkManager（或 wpa_supplicant 等管理面）周期性检查接口状态，发现一个「没被管理的无线接口」就接管配置。

对策按优先级：

```bash
# 临时（调试会话期间）：直接停服务
sudo systemctl stop NetworkManager
# 或只让 NM 放手这一个接口（其余网卡继续被管理，笔记本还能上网）：
# 编辑 /etc/NetworkManager/conf.d/99-monitor.conf 写入：
#   [keyfile]
#   unmanaged-devices=mac=xx:xx:xx:xx:xx:xx    # 监听网卡的 MAC
sudo systemctl reload NetworkManager
```

推荐后者：主取证机的有线/自身 WiFi 不受影响，监听网卡永久免抢。用 `nmcli device status` 确认目标网卡显示 `unmanaged` 才算到位。

### 3.3.3 坑 2：信道不固定 + 坑 3：regulatory 限制

**信道漂移**：monitor 接口若不显式 `set channel`，驱动可能停在任意残留信道。后果是灾难性的：你按「AP 在信道 6」的假设抓了十分钟，实际网卡在信道 11——pcap 里除了噪声什么都没有，而你会误判为「AP 不发 beacon」。纪律：**每次切换接口类型后、每次开抓前，`iw dev <if> info` 确认信道**；抓 5 GHz 还要确认带宽（`set channel 36 HT20` 或按需 HT80，带宽不匹配收不到 40/80 MHz 帧的完整内容）。

**regdomain 限制**：内核按监管域决定「哪些信道允许、允许多大功率」。`iw reg get` 查当前域，`iw reg set CN` 切换；DFS 信道在监听下也可能因雷达检测状态被限制。若 `set channel` 报 `EBUSY` 或被拒，用 `iw phy` 看该频段哪些频率带 `disabled`/`no IR` 标记。regdomain 与各国信道差异的概念 [[ch02-radio-and-spectrum|射频入门（二）]] 已教，这里只记排障动作：**抓不到某信道 → 先 `iw reg get`，再 `iw phy | grep -A 30 Band`**。

> [!warning] 合规提醒
> 监听空口在你自己管理的网络里做调试没有问题；但对他人网络流量的捕获与解密在多数司法辖区有法律边界。本章及后续案例的全部操作对象是**自己的路由器 + 自己的被测设备**。

## 3.4 Wireshark 读 802.11：radiotap、帧类型与过滤器清单

### 3.4.1 radiotap：每帧开头的「物理层发票」

monitor 模式递上来的每个帧，802.11 头前面都挂一段 **radiotap 头**——网卡把「这帧是在什么物理条件下收到的」记录在案：时间戳、信道、数据率、RSSI、天线编号等。调试中最常用三个字段：

| radiotap 字段           | 在 Wireshark 哪里看                            | 调试用途                                                   |
| ----------------------- | ---------------------------------------------- | ---------------------------------------------------------- |
| RSSI（Signal Strength） | radiotap → Signal Strength，或列视图加 RSSI 列 | 对端离得远不远；配合第五章区分「信号差断连」vs「协议断连」 |
| Channel / Frequency     | radiotap → Channel                             | 核对抓包信道是否漂了（3.3.3 的自检手段之一）               |
| Data Rate               | radiotap → Data rate                           | 管理帧固定基础速率；数据帧速率异常低 → 第六章的重传话题    |

> [!note] RSSI 的口径提醒
> radiotap 里的 RSSI 是**抓包网卡**收到的信号强度，不是被测 STA 报告的 RSSI。两台设备位置不同，同一帧的 RSSI 天差地别。要拿「STA 眼中的 RSSI」，用第二章的 `iw dev wlan0 link`（STA 侧实测），别混用两个口径。dBm 单位制见 [[ch03-decibel-family|射频入门（三）]]。

### 3.4.2 三大帧类型与本章最常用的子类型

802.11 帧控制字段的 type/subtype 把空口流量切成三大类，断连调试的高频子类型全部集中在管理帧里：

| 类型   | type 值 | 干什么                         | 本章最关心的子类型（subtype）                                                                         |
| ------ | ------- | ------------------------------ | ----------------------------------------------------------------------------------------------------- |
| 管理帧 | 0       | 建链、维护、拆链的全部「对话」 | beacon(8)、probe req(4)/resp(5)、auth(11)、assoc req(0)/resp(1)、deauth(12)、disassoc(10)、action(13) |
| 控制帧 | 1       | 介质调度：RTS/CTS/ACK          | 一般不逐帧分析；大量丢 ACK 是第六章的重传线索                                                         |
| 数据帧 | 2       | 承载业务流量                   | EAPOL（含在数据帧中，LLC 头标识）——4-way 握手的载体                                                   |

这些子类型在一次连接生命周期里按「probe → beacon/auth → assoc → EAPOL×4 → 数据 → deauth」的顺序出场——这个顺序正是第四章的状态机取证框架，届时逐阶段展开。

### 3.4.3 过滤表达式清单

Wireshark 显示过滤器（不是捕获过滤器语法），日常断连排查的完整弹药：

| 过滤表达式                                                                                            | 语义                     | 什么时候用                         |
| ----------------------------------------------------------------------------------------------------- | ------------------------ | ---------------------------------- |
| `wlan.fc.type == 0`                                                                                   | 只看管理帧               | 断连排查的第一层筛                 |
| `wlan.fc.type_subtype == 8`                                                                           | 只看 beacon              | 确认 AP 活着、看能力信息元素       |
| `wlan.fc.type_subtype == 4`                                                                           | 只看 probe request       | 排查扫不到网（第四章）             |
| `wlan.fc.type_subtype == 11`                                                                          | 只看 auth                | 认证阶段卡住（第四章）             |
| `wlan.fc.type_subtype == 12`                                                                          | 只看 deauth              | 掉线根因（第五章，看原因码）       |
| `wlan.fc.type_subtype == 0x88`                                                                        | 只看 QoS 数据帧          | 业务流量分析                       |
| `wlan.addr == aa:bb:cc:dd:ee:ff`                                                                      | 任一地址字段含此 MAC     | 聚焦被测设备的全部流量（首选用法） |
| `wlan.sa == ...` / `wlan.da == ...`                                                                   | 源地址/目的地址精确匹配  | 区分谁先动手（谁发的 deauth）      |
| `wlan.fc.retry == 1`                                                                                  | 只看重传帧               | 重传占比异常 → 第六章              |
| `wlan_mgt.ssid == "MySSID"`                                                                           | 按 SSID 匹配管理帧       | 多 AP 环境先筛自家网络             |
| `eapol`                                                                                               | 只看 EAPOL               | 抓 4-way 握手（3.5 的前提验证）    |
| `wlan.fc.type == 0 && wlan.fc.retry == 1`                                                             | 管理帧里的重传           | 信号差导致管理帧损坏的线索         |
| 组合：`wlan.addr == <MAC> && (wlan.fc.type_subtype == 12 \|\| wlan.fc.type_subtype == 10 \|\| eapol)` | 被测设备的全部断连相关帧 | 现场第一步：先圈定设备的拆链与握手 |

## 3.5 WPA2 解密：配置方法与两个前提

抓到加密数据帧时，Wireshark 只能显示「这是一帧 QoS Data」，载荷全黑。配上密钥后，业务流量立刻变回可读的 IP/TCP。Wireshark 的配置路径：

```text
Edit → Preferences → Protocols → IEEE 802.11
  → Enable decryption 打勾 → Decryption keys → Edit
      Key type: wpa-pwd
      Key: <明文密码>:<SSID>     （如 MyPassphrase:MyHomeWiFi）
```

（十六进制形式则选 `wpa-psk`，值为 32 字节 PMK 的 hex；`wpa-pwd` 直接填 passphrase+SSID 最省事。）

两个**缺一不可**的前提：

1. **能抓到完整的 4-way handshake**。解密密钥材料从握手动态派生，Wireshark 必须看到该会话的 EAPOL M1~M4。手上只有「握手之后」的 pcap？解不开——重连一次被测设备，确保握手落在抓包窗口里。验证：过滤器敲 `eapol`，4 个消息齐全才算数。这也是 3.7 取证脚本把「抓包窗口覆盖重连」作为标准动作的原因。
2. **是 PSK 个人版（WPA2-PSK）**。企业版（802.1X/EAP）会话密钥按会话随机派生，知道密码也没用。

> [!warning] WPA3/SAE 的限制
> WPA3-SAE 的密钥派生含前向保密设计，第三方即使持有 PSK 也**不能**像 WPA2 那样从抓包+密码还原业务流量（Wireshark 的 SAE 解密支持有限且依赖额外密钥材料，勿按 WPA2 流程期待）。调试被测设备时实用做法：**在 AP 上为调试单开一个 WPA2-PSK SSID**（仅调试期使用），既保解密能力，又不降生产网络的安全等级。被测设备是 ESP32 时它两侧都支持，切 SSID 零成本。

管理帧（beacon/auth/assoc/deauth）本身**从不加密**（受保护的管理帧 PMF 除外），所以即使不解密，断连排查最需要的那些帧也是明文可读的——「连不上/掉线」类问题大半不依赖解密就能破案，别把解密当成空口抓包的入门门槛。

## 3.6 双网卡工作法：一块 STA，一块 sniffer

只带一块网卡的窘境：切了 monitor 就不能同时当 STA 联网；更关键的是——第五章要用 STA 侧内核日志与空口抓包**对时**，同一台机器上两个角色一起干才方便。默认工作形态：

```text
┌──────────────────── 取证笔记本 ────────────────────┐
│  wlan0 (managed)              wlan1 (monitor)      │
│  关联被测 AP，当「标准 STA」    固定信道，只管听     │
│  iw dev wlan0 link             tcpdump -i wlan1 -w  │
│  dmesg -w / iw event 落盘     （信道随被测 AP 切）  │
│  └─ 内核时钟只有一个：两路证据自带同一 UTC 时间戳 ─┘│
└─────────────────────────────────────────────────────┘
```

分工与纪律：

| 角色          | 网卡  | 干什么                                                     | 别干什么                             |
| ------------- | ----- | ---------------------------------------------------------- | ------------------------------------ |
| STA（参考站） | wlan0 | 关联同一 AP，测得「STA 视角」RSSI/速率/断连事件            | 不切 monitor，保持被管理状态         |
| sniffer       | wlan1 | 只听不连；信道锁在被测 AP 的信道                           | 不用它的数据上网                     |
| 时间基准      | 主机  | 两路证据（pcap 帧时间戳、内核日志行时间）共用同一 UTC 时钟 | 开抓前 `timedatectl` 确认 NTP 已同步 |

对时为什么重要：第五章的根因判定经常是「空口先出现 deauth，还是站端日志先报 beacon loss」——顺序差几百毫秒，结论完全不同。同一主机双网卡时，pcap 时间戳与 `dmesg`/`iw event` 日志时间天然同源（同一内核时钟），误差接近零；sniffer 若被迫放在另一台机器，必须 NTP 同步后核对 `date -u` 秒级一致，并注明两台主机的时钟口径。

## 3.7 取证脚本小抄：三章案例的标准开场

把 3.3~3.6 的纪律压成一段可复制的流程。**约定**：`wlan1` 是监听网卡，`$CHAN` 是被测 AP 所在信道（先在 STA 侧用 `iw dev wlan0 link` 查到），`$TAG` 是本次取证标签。后续第四、五、六章的案例都从这个开场进入：

```bash
#!/bin/bash
# ota-sniff-start.sh —— 用法: sudo ./ota-sniff-start.sh <信道号> <标签>
set -euo pipefail
CHAN="${1:?用法: $0 <信道> <标签>}"; TAG="${2:?缺少标签}"
IF=mon1                                   # 监听接口命名，避免与 STA 混淆
STAMP=$(date -u +%Y%m%dT%H%M%SZ)          # 全部证据文件用 UTC 时间戳命名
# 0. 时间基准检查：NTP 未同步先报警（对时纪律，3.6）
timedatectl show -p NTPSynchronized --value | grep -q yes \
  || echo "[!] 警告：NTP 未同步，跨机对时将不可靠"
# 1. 放手监听网卡（只停 NM；更优雅做法见 3.3.2 的 unmanaged 配置）
sudo systemctl stop NetworkManager
# 2. 建独立 monitor 接口（保留 wlan1 原接口，比改类型更干净、可复用）
sudo iw dev wlan1 interface add $IF type monitor
sudo ip link set $IF up
sudo iw dev $IF set channel "$CHAN"
iw dev $IF info                            # 验收：type monitor + 信道正确
# 3. 双路落盘：空口帧 + 内核无线事件，同一 UTC 时钟源
mkdir -p cap_$TAG-$STAMP
sudo tcpdump -i $IF -s 0 -w cap_$TAG-$STAMP/ota.pcapng &
TCPDUMP_PID=$!
sudo iw event -t -f | tee cap_$TAG-$STAMP/iw-event.log &
IW_PID=$!
# 4. 此刻去触发被测设备的动作（重连/漫游/压测）……结束后 Ctrl+C 停止脚本
trap 'sudo kill $TCPDUMP_PID $IW_PID 2>/dev/null; \
      sudo iw dev $IF del; \
      sudo systemctl start NetworkManager; \
      echo "证据目录: cap_$TAG-$STAMP/"' EXIT
wait
```

脚本落点与三章案例的对应关系：

| 产出文件           | 是什么                                                 | 哪一章怎么用                                |
| ------------------ | ------------------------------------------------------ | ------------------------------------------- |
| `ota.pcapng`       | 空口逐帧（含 radiotap）                                | 第四章按状态机找卡住的阶段；第五章找 deauth |
| `iw-event.log`     | 内核无线事件流（`-t` 帧相对时间，`-f` 打印帧内容摘要） | 与 pcap 对时，站端视角的断连时刻            |
| 目录名（UTC 标签） | 证据链的时间锚点                                       | 案例复盘时两路证据按同一标签归档            |

使用纪律：每次取证前先跑、结束后 `iw dev $IF info` 确认没漂信道；触发动作（重连等）必须落在抓包窗口**内**才算有效证据。第四章开始，每个案例的「现象复现」都默认引用这个开场。

## 本章小结

- **monitor ≠ promiscuous**：WiFi 的接收过滤在 MAC 硬件，混杂模式绕不过去；监听模式是唯一能看到「AP 与 STA 完整对话」的姿势，也是断连类问题破案的唯一空口入口。
- **验货先于信仰**：芯片阵营口碑只是先验概率，`iw list` 查 `* monitor`、行为级抓到自家 beacon 才算数；几十元 USB 卡以 2.4 GHz 为主，5 GHz 到手实测。
- **三大坑的纪律**：unmanaged 目标网卡防抢占、每次开抓前 `iw dev info` 核信道、`iw reg get` 排 regdomain 限制。
- **Wireshark 三件套**：radiotap 读 RSSI/信道/速率（口径是抓包卡的，不是 STA 的）；管理帧 subtype 是断连排查主战场；过滤器清单按表速查。
- **解密有前提**：WPA2-PSK + 完整 4-way 才能解；WPA3/SAE 不按此路走，调试期单开 WPA2 SSID 是实用解；管理帧明文，多数断连案不解密也能破。
- **双网卡 + 同一时钟 + 标准开场**：STA 管事件、sniffer 管帧、UTC 时间戳管归档——`ota-sniff-start.sh` 把本章纪律压成一个可复制入口，第四、五、六章都从这里开始。

下一章开始真刀真枪：被测设备连不上 AP，用本章的抓包武器沿连接状态机逐阶段取证，见[[wifi-hw-debug-ch04-cannot-associate|第四章：案例——连不上]]。
