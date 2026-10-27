---
title: "WiFi 硬件调试实战（四）：案例——连不上"
date: 2026-10-27 12:00:00
pin: false
description: "本系列第一个完整案例章：把「连不上」这个最含糊的现象拆开——按连接状态机五阶段（扫描→认证→关联→4-way→DHCP）逐段取证。每阶段给用户可见表现、空口帧特征（认证/关联 status code 按 802.11 标准口径解读）、站端日志特征与常见根因清单：隐藏 SSID 的 probe 行为、PMF 强制拒绝老设备、能力位不匹配、密码错在空口的真实样子、EAPOL 丢失与频偏暗坑、DHCP 超时的三步甄别法。命令全部可复制，帧序列与日志样例均为格式示意，案例取材自常见故障模式的教学复盘综述。"
tags: [wifi-hw-debug, WiFi, Debugging]
---

# WiFi 硬件调试实战（四）：案例——连不上

> [!info] WiFi 硬件调试实战系列 0. [[wifi-hw-debug|系列索引]]
> 上一章：[[wifi-hw-debug-ch03-ota-sniffing|第三章：空口抓包实战]]
> **第四章：案例——连不上**（当前章）
> 下一章：[[wifi-hw-debug-ch05-disconnect-roaming|第五章：案例——掉线与漫游]]

## 本章证据口径

> [!note] 先立规矩
> 本章命令（`iw`/`wpa_cli`/`tcpdump`/Wireshark 过滤器）均为真实可执行命令，输出格式以工具官方文档为准；status code、reason code、认证算法编号等协议事实引 IEEE 802.11 标准口径（各代标准通用编号，正文标注）；**帧序列与日志样例均为「格式示意」**——字段结构真实、具体数值为教学排版需要而编排，不代表任何一次真实抓包的读数。案例均为**教学复盘案例，取材自常见故障模式综述**，非某公司事故报告。

## 4.1 现场引入：三类「连不上」

「连不上」是现场出镜率最高、信息量却最低的描述。同一句汇报，背后可能是三种完全不同的问题域：

| 类型                        | 典型描述                                 | 问题域直觉                                               | 常见重灾区                        |
| --------------------------- | ---------------------------------------- | -------------------------------------------------------- | --------------------------------- |
| A：新设备首次上电连网失败   | 「新板子第一次连公司 AP，转圈然后失败」  | 站端配置/regulatory/能力协商                             | 新固件、新地区码、新模组批次      |
| B：固件升级后原有网络连不上 | 「升级前好好的，OTA 完连不上家里路由器」 | 站端**变更**引入：默认值漂移、PMF/认证方式变化、校准数据 | OTA 后默认配置、证书/PSK 存储丢失 |
| C：只在某型号路由器上连不上 | 「A 牌 AP 秒连，B 牌 AP 连不上」         | **互操作性**：能力位组合、非标实现、老协议兼容           | 老 AP 新站、新 AP 老站、mesh 组合 |

分类价值在于：A 类先查「这台设备自身」；B 类先做**差分**——升级前后改了什么，回滚验证一次；C 类不要恋战单台 AP，先抓空口看协商断在哪一步，再查两边的官方兼容性说明。三类最终都会落到同一张地图上——连接状态机。先问「断在哪一阶段」，再问「为什么断」。

## 4.2 排障第一问：现象断在状态机哪一阶段

一次成功的连接，站端要依次走完五个阶段；任何一阶段断掉，用户看到的现象不同。这是本章的全章地图：

```text
 站端 STA                                AP
   │                                       │
 ┌─▼──────────────┐  ① 扫描    ┌──────────▼─┐
 │ scan: 找 SSID   │◄─beacon/── │ 周期广播     │
 │ (主动 probe /   │  probe resp│             │
 │  被动听 beacon) │            │             │
 └─┬──────────────┘            └─────────────┘
 ┌─▼──────────────┐  ② 认证    ┌─────────────┐
 │ auth: 开放/PSK/ │◄──────────►│ 验证身份      │
 │ SAE             │  auth 帧   │ (开放/802.11)│
 └─┬──────────────┘            └─────────────┘
 ┌─▼──────────────┐  ③ 关联    ┌─────────────┘
 │ assoc: 报能力   │──────────► │ 能力/速率集   │
 │ (assoc req)     │◄─assoc resp│ 审查,回状态码 │
 └─┬──────────────┘            └─────────────┘
 ┌─▼──────────────┐  ④ 4-way   ┌─────────────┘
 │ EAPOL: M1→M2→   │◄──────────►│ 验证 PMK      │
 │ M3→M4,装密钥     │  EAPOL-Key │ (PSK/SAE 派生)│
 └─┬──────────────┘            └─────────────┘
 ┌─▼──────────────┐  ⑤ DHCP    ┌─────────────┘
 │ discover→offer→ │──── LAN ──►│ DHCP 服务器    │
 │ request→ack,拿IP │            │ (常在路由器)   │
 └────────────────┘            └─────────────┘
```

五阶段失败对应的用户可见表现，是现场唯一的免费信息，要会读：

| 阶段    | 失败时用户看到                                        | 站端典型日志关键词                        | 首选取证                                     |
| ------- | ----------------------------------------------------- | ----------------------------------------- | -------------------------------------------- |
| ① 扫描  | **SSID 列表里根本没有这个网**                         | `scan done` 但目标 absent                 | 手机 WiFi 分析仪看 beacon 有无；空口抓 probe |
| ② 认证  | 提示**密码错误**（真错或被 AP 拒）                    | `authentication failed` / SAE commit 失败 | 空口看 auth 帧 status code                   |
| ③ 关联  | 反复「正在连接…」后失败，无明显密码提示               | `assoc rejected/refused`                  | 空口看 assoc resp status code                |
| ④ 4-way | 显示「正在获取 IP 地址」后超时，或连接反复弹回        | `4-way handshake failed/timeout`          | 空口数 EAPOL：M1/M2 有无、M3 缺席否          |
| ⑤ DHCP  | **已显示已连接**（信号图标在），但拿不到 IP、上不了网 | DHCP discover 发出无 offer                | 抓有线侧/AP 后台看 DHCP，空口反而不重要      |

> [!tip] 排障第一问
> 拿到任何「连不上」，第一个问题不是「为什么」，而是「**断在哪一阶段**」。做法很简单：让站端把日志开起来（第二章的 `wpa_cli -i wlan0 log_level debug` 或 ESP32 侧事件回调），重连一次，看最后一个成功的事件是什么。卡在「认证失败」和卡在「获取 IP」是两个世界的问题——后者的 WiFi 链路其实已经建好了。

ESP32 侧每个阶段都有对应事件（`WIFI_EVENT_STA_START` → `SCAN_DONE` → `STA_CONNECTED` 之后才是 IP 事件），事件模型的完整梳理见 [[ch16-wifi-events|BOX-3（十六）]]；本章 4.8 用它做站端证据源。

## 4.3 阶段①扫描失败：SSID 看不见的四种根因

### 主动与被动扫描

- **被动扫描**：STA 逐信道驻留，听 AP 周期广播的 beacon 帧。慢但省电，也是发现隐藏网络之外一切网络的方式。
- **主动扫描**：STA 在每个信道广播 probe request（可带 directed SSID），AP 回 probe response。快，是手机/物联网设备的主用方式。

隐藏 SSID 的特殊行为：AP **不广播 SSID**（beacon 中该字段为空），STA 必须发**带目标 SSID 的 directed probe request**，AP 才回 probe response。这直接派生出一条经典故障：**路由器开了「隐藏 SSID」，而站端只做被动扫描或 probe 不带 SSID**——手机上手动输入过 SSID 的设备能连，但物联网模块死活扫不到。判别方法一行命令：

```bash
# 在 AP 同信道监听，过滤该 SSID 的 probe 往返（格式示意过滤器）
# tcpdump 监听抓包：见第三章双网卡法，此处为 Wireshark 显示过滤器
wlan.fc.type_subtype == 4   # probe request
wlan.fc.type_subtype == 5   # probe response
wlan.ssid == "TargetAP"     # directed probe 才带 SSID 字段
```

### 根因清单与取证对照

| #   | 根因                                       | 机理                                                                              | 空口帧特征                                                                  | 取证/验证                                                                    |
| --- | ------------------------------------------ | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| 1   | **目标信道不在扫描集**                     | 站端 regulatory domain 排除了该信道（如站端按 FCC 域只扫 1-11，AP 在 12/13 信道） | 空口正常有 beacon，但站端从不驻留该信道                                     | 站端 `iw reg get` 看域码；`iw phy` 看 allowed channels；改 `iw reg set` 验证 |
| 2   | **AP 隐藏 SSID + 站端不发 directed probe** | 见上                                                                              | beacon 的 SSID 字段为空；无 probe response                                  | 抓包对比「手机能扫到 vs 设备扫不到」时的 probe 行为差异                      |
| 3   | **MAC 过滤静默丢弃**                       | AP 配了 MAC 黑/白名单，对 probe/认证**不回应**而非拒绝                            | probe request 发出，**无 probe response**（白名单外）；或到 auth 阶段无响应 | 换一块已知在白名单内的网卡 MAC 试连；查 AP 后台                              |
| 4   | **AP 侧真的不在发**                        | AP 宕了/该 SSID 对应 VAP 关了/2.4G 被关只剩 5G                                    | 该信道无 beacon                                                             | 手机分析仪确认信号有无；换频段重试                                           |

regulatory 这条在现场（尤其 A 类「新设备」）出现频率极高：模组出厂默认域、固件里 NVS 存的域、AP 实际信道三者对不齐，扫描集就少了信道。信道划分的来龙去脉见 [[ch02-radio-and-spectrum|射频入门（二）]]。取证顺序建议：先手机确认 AP 在发（排除根因 4）→ 空口确认站端有没有 probe 到该信道（排除 1）→ 再看 probe response 有无（区分 2/3）。

## 4.4 阶段②认证失败：密码错的空口真相

### 三种认证方式在空口的差别

| 方式                   | 空口认证帧行为                         | 说明                                                   |
| ---------------------- | -------------------------------------- | ------------------------------------------------------ |
| Open System            | auth alg = 0，一来一回（req/status=0） | 声明性的，**不验密码**；真正的鉴权推迟到 4-way         |
| Shared Key（WEP 遗留） | auth alg = 1，四步挑战-响应            | 仅考古场景，新设计不应出现                             |
| SAE（WPA3）            | auth alg = 3，commit/confirm 多轮交换  | 密码错表现为 commit/confirm 失败或循环；引 802.11 口径 |

关键认知：**WPA2-PSK 网络里，空口认证阶段用 Open System，「密码错」并不在这一阶段体现**——AP 先放你过认证和关联，到 4-way 才发现 PMK 对不上，然后发 deauth 把你踢掉。所以「用户看到密码错误提示」可能是：

- 站端 wpa_supplicant 在 4-way 连续失败后，**自己总结**上报「密码可能错了」——提示语是站端推理，不是 AP 的话；
- 或 PMF/策略原因在 auth/assoc 阶段被拒，UI 一律显示「密码错误」。

### 认证/关联阶段的状态码（引 IEEE 802.11 标准口径）

Status Code 是 auth response / assoc response 里的 16 位字段，常见值（标准编号，各代通用）：

| Status Code | 含义                                                                        | 现场对应                       |
| ----------- | --------------------------------------------------------------------------- | ------------------------------ |
| 0           | Success                                                                     | —                              |
| 1           | Unspecified failure（泛化失败）                                             | AP 内部拒绝，查 AP 日志        |
| 12          | Association denied because AP is unable to handle additional associated STA | AP 关联数满了/负载限制         |
| 13          | Association denied temporarily; try again later                             | AP 策略性拒绝                  |
| 17          | Association denied because AP is unable to support additional association   | 同 12 的老表述（cap 满）       |
| 18          | **Cannot support all requested capabilities**（能力不匹配）                 | 关联阶段能力审查失败，见 4.5   |
| 37          | Invalid information element                                                 | 请求里的 IE AP 读不懂/认为非法 |
| 45          | **Stronger security required**（需更强安全）                                | **PMF 强制被拒的经典码**       |
| 53          | Missing Robust Management Frame (PMF) capability                            | 同上族，802.11w 引入           |

### PMF 强制拒绝老设备：新 AP 时代的头号坑

WPA3 认证**强制要求 PMF**（802.11w，受保护管理帧）。大量新路由器默认「WPA2/WPA3 混合」且对不支持 PMF 的老站**直接拒绝**，于是：老设备（老模组、老固件）连混合模式 AP，ap 回 auth/assoc 拒绝（常见 status 45 一族），站端 UI 报「密码错误」，用户改十遍密码无用。处置：

- 站端：升级固件使模组支持 PMF，或临时把 AP 改为「WPA2-only + PMF 可选」验证归因；
- 判别证据：空口抓 auth/assoc response 看 status code；站端 `wpa_cli -i wlan0 status` 看 pmf 字段。

> [!warning] 归因纪律
> 「密码错误」提示在本阶段不可信。必须在空口或日志里拿到 status code / deauth reason，再下结论。教学复盘案例：现场曾按「密码错」排查两小时，最后空口一条 status 45 定案为 PMF——提示语误导的典型案例（教学复盘案例，取材自常见故障模式综述）。

## 4.5 阶段③关联失败：能力不匹配家族

认证过了，站端发 association request 报告自己「是谁、会什么」，AP 审查后回 association response + status code。AP 侧审查项与常见失败：

| 审查项                             | AP 拒绝的典型情形                                                                                            | 空口特征                                                                         | 对策方向                                   |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- | ------------------------------------------ |
| **低速率集（BSS Basic Rate Set）** | 老 AP 强制 802.11b 基本速率集里含 1/2 Mbps，某些新站固件不支持而被拒；或反过来 AP 关掉了低速，老站无共同速率 | assoc resp status ≠ 0；或 AP 直接不响应                                          | AP 侧开启兼容速率；站端固件补速率支持      |
| **HT/VHT/HE 能力位**               | 站端声明的能力位组合 AP 不认（如 HT40 但不声明 40-MHz intolerant 的反面）；802.11n 老 AP 对新站某些 IE 敏感  | assoc resp status 18（cannot support all requested capabilities，标准口径）或 37 | 抓 assoc request 的 IE 逐项对 AP 支持表    |
| **频宽（20/40/80 MHz）**           | 站端只支持 20 MHz 而 AP 以 40/80 邀约，多数实现能降级兼容；**反向**（AP 锁 20 MHz、站端强上 40）少数实现拒绝 | 能连但异常，或 assoc 失败                                                        | 先用 20 MHz 固定值验证能否连通，再放开频宽 |
| 关联容量                           | AP 关联终端数满（status 12/17，标准口径）                                                                    | assoc resp status 12/17                                                          | AP 后台看已连数；重启 AP 验证              |
| SSID 长度/编码异常                 | 罕见：UTF-8 SSID 编码不一致                                                                                  | assoc request 的 SSID IE 与 beacon 不匹配                                        | 十六进制比对 SSID 字节                     |

C 类现场（只在某型号 AP 连不上）十有八九落在这一族。实操上最省力的二分法：**把 AP 的安全模式临时改成 Open（无密码）**——若 Open 能连，问题在 4.4/4.6（认证/密钥侧）；若 Open 也连不上，问题在本节（能力/速率/IE 侧）。这一步能在五分钟内把嫌疑名单砍一半。

老设备连新 AP 的经典坑还包括：新 AP 默认只开 5 GHz 高信道（站端 regulatory 扫不到，其实是 4.3 的问题）、以及 802.11ax AP 的某些 IE 触发老站固件解析崩溃（表现是 assoc request 发出后毫无响应，连拒绝都省了）。

## 4.6 阶段④4-way 握手：密码错与「密码明明对」

### 四步握手的空口样子

4-way 在关联成功后由 AP 发起，目的是双方基于 PMK 派生并安装 PTK：

```text
  AP                                    STA
   │  ── EAPOL-Key M1 (ANonce) ───────►  │  STA 算 PTK
   │  ◄── EAPOL-Key M2 (SNonce+MIC) ───  │  AP 校验 MIC
   │  ── EAPOL-Key M3 (MIC+GTK) ──────►  │  STA 校验并装密钥
   │  ◄── EAPOL-Key M4 (MIC) ──────────  │  双方进入加密态
```

（格式示意：真实帧里还带 RSN IE、Key RSC、重放计数字段等，教学图省略。）

**计数规律是本章最有用的单条判据**：

| EAPOL 观测              | 结论                                                                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| M1→M2→M3→M4 完整四帧    | 握手成功，密码对                                                                                                                |
| **有 M1/M2，无 M3**     | **密码错**——AP 收到 M2 校验 MIC 失败，不再发 M3，转而发 deauth（WPA2 口径；SAE 网络密码错在 auth 的 commit/confirm 阶段就失败） |
| M1 发出无 M2            | 上行弱/STA 没收到或没回，见下面的「暗坑」                                                                                       |
| M2 发出无 M3            | 下行回程丢或 AP 未确认 MIC，看 AP 侧                                                                                            |
| EAPOL 循环多轮后 deauth | 典型的密码错或半包丢失混合，需看每轮 M3 有无                                                                                    |

Wireshark 过滤器：`eapol`（全部 EAPOL 帧）；`eapol.type == 3`（EAPOL-Key）。

### 「密码明明对却握手失败」的暗坑

| 暗坑               | 机理                                                                                            | 判别                                                     |
| ------------------ | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ------------------ |
| **弱信号丢 EAPOL** | 4-way 有超时与重试窗口，边缘信号下 M2/M3 单帧丢失即整轮失败；表现是「靠近 AP 能连，远处连不上」 | 空口看 EAPOL 重传（Retry 位）；对齐 RSSI 读数            |
| **频偏超限**       | 晶振频偏过大导致高速率下调制解调连续失败，管理帧（低速、鲁棒）能过而 EAPOL 数据帧丢             | 换更低 MCS 验证改善；根治查晶振——见 [[ch11-crystal-clock | 射频入门（十一）]] |
| PSK 空格/编码      | 复制粘贴密码带尾随空格，或 SSID/密码含非 ASCII 字符编码不一致                                   | 十六进制打印 PSK 长度（应为 8-63 字符口径）              |
| AP 侧同类站互踢    | AP 对同 MAC/同 IP 的旧会话未清理，新站握手被旧会话干扰                                          | 改 STA MAC 后四位重试验证                                |
| 时间敏感的缓存失效 | AP 重启后 STA 拿着旧 PMKID 尝试快速重连失败（PMKID 缓存不一致）                                 | 关闭 PMKID 缓存或忽略首次失败看第二轮                    |

弱信号与频偏这两条把本章和物理层接上了：软件栈排查到「EAPOL 丢失」仍未归因时，就该切换到物理层视角（第七章的 EVM/频偏实测）。

## 4.7 阶段⑤DHCP 超时：不是 WiFi 问题

4-way 完成、加密链路已建立，之后拿不到 IP——**WiFi 链路本身是好的**。三步甄别法：

```text
步骤1 空口: 4-way M4 之后,STA 是否发出 DHCP Discover?
        有 Discover → 链路通,问题在 DHCP 服务侧/AP 桥接
        无 Discover → 其实不是 DHCP 问题,回查 4-way 是否真完成
步骤2 端内: 手动静态 IP + ARP 验证
        sta 配静态IP → ping 网关 → arp 看网关 MAC 学到没
        ARP 通 → 纯 DHCP 服务器问题(地址池满/option 不匹配)
        ARP 不通 → L2 桥接问题(AP 把该 STA 隔离/ACL)
步骤3 有线侧: 在 AP 的 LAN 口再抓一份包
        空口有 Discover 而 LAN 口没有 → AP 桥接丢包
        LAN 口有 Discover 无 Offer → DHCP 服务器问题
```

对应的真实命令（在 STA 上）：

```bash
sudo ip addr add 192.168.1.99/24 dev wlan0     # 临时静态 IP（按现场网段改）
ping -c 3 192.168.1.1                          # 网关连通性
ip neigh show dev wlan0                        # 网关 MAC 学到了吗
sudo tcpdump -i wlan0 -n port 67 or port 68    # DHCP 往返
```

现场占比经验：标着「连不上/没网」的工单里，这一类（含地址池满、AP 客户端隔离、VLAN 未放行）相当常见——因为它**同样表现为「上不了网」**。这也是 4.2 强调「先定位阶段」的价值：多问一句「信号图标亮了吗」，就能把这批人分流出去。

## 4.8 站端日志与空口对齐

单独看空口或单独看日志都只有半张地图，**对齐时间轴才是完整证据**。方法沿用第三章的双网卡法：一块网卡做 STA 复现问题，另一块进监听模式在同一信道抓包，两边各自打时间戳：

```bash
# 取证机 A（STA 角色）：日志留痕
sudo wpa_cli -i wlan0 log_level debug
sudo wpa_cli -i wlan0 reassociate | ts '%Y-%m-%d %H:%M:%.S' 2>&1 | tee sta.log
# 取证机 B（sniffer 角色，第三章方法）
sudo tcpdump -i wlan1 -i flag -w ota.pcap type mgt subtype probe-req or subtype auth or subtype assoc-req or eapol
# 之后用首条公共帧（如 probe request 的空中时间戳 vs 日志行时间）对齐两侧
```

（`ts` 来自 moreutils；pcap 内帧时间是抓包机的本地时钟，与 STA 日志时钟需先对一次表，或用同一条可观测事件——如 deauth 帧与日志中的 deauth 行——做锚点。）

ESP32 侧的证据源是 `esp_wifi` 事件序列：`WIFI_EVENT_STA_START` → `WIFI_EVENT_STA_DISCONNECTED`（带 reason code）→ 重连循环；连接成功后 `IP_EVENT_STA_GOT_IP`。把事件回调打印加上时间戳，就得到与空口可对齐的站端时间线；事件模型与断连原因码在站端的对应物见 [[ch16-wifi-events|BOX-3（十六）]]，驱动边界见 [[ch18-esp32-wifi-lwip-integration|lwIP（十八）]]。一个有效的复盘模板（格式示意）：

| 时刻   | 站端事件/日志                                       | 空口帧                 | 判读                           |
| ------ | --------------------------------------------------- | ---------------------- | ------------------------------ |
| T+0.0s | `STA_START`, scan start                             | probe req（广播）      | 扫描开始                       |
| T+1.2s | scan done, found "TargetAP" (-63 dBm)               | beacon/ap              | 扫描 OK → 断点不在①            |
| T+1.3s | auth open                                           | auth req/resp status 0 | 认证 OK → 不在②                |
| T+1.4s | assoc ok                                            | assoc resp status 0    | 关联 OK → 不在③                |
| T+1.5s | 4-way timeout                                       | M1, M2×2(重传), 无 M3  | **断在④**，且 M2 重传→疑上行弱 |
| T+4.5s | `STA_DISCONNECTED` reason=2(4-way 失败口径见第五章) | deauth                 | 复盘结论                       |

（格式示意。这张表就是本章的交付物形态：任何「连不上」都应最终收敛成这样五行。）

## 4.9 根因速查总表

| 断在哪      | 用户可见              | 空口帧特征                       | 站端日志特征            | 根因                          | 对策                           |
| ----------- | --------------------- | -------------------------------- | ----------------------- | ----------------------------- | ------------------------------ |
| ①扫描       | SSID 不在列表         | 无 probe response                | scan done 无目标        | MAC 过滤静默丢弃              | 查 AP 白名单                   |
| ①扫描       | SSID 不在列表         | beacon 的 SSID 字段空            | scan done 无目标        | 隐藏 SSID 未发 directed probe | 配置站端带 SSID 主动扫         |
| ①扫描       | SSID 不在列表         | 空口有 beacon 但站端不驻留该信道 | allowed channels 少信道 | regulatory 域不匹配           | `iw reg set`/固件域配置        |
| ②认证       | 「密码错误」          | auth resp status 45/53 族        | auth failed             | PMF 强制、老站不支持          | 升固件或 AP 改 WPA2+PMF 可选   |
| ②认证       | 连接失败              | auth req 无响应                  | auth timeout            | AP 负载/策略拒绝              | 查 AP 后台与关联数             |
| ③关联       | 反复「正在连接」      | assoc resp status 18             | assoc rejected          | 能力位/速率集不匹配           | 抓 assoc req IE 对 AP 支持表   |
| ③关联       | 连接被拒              | assoc resp status 12/17          | assoc refused           | AP 关联数满                   | 清理 AP 或扩容                 |
| ④4-way      | 卡「获取 IP」后弹回   | M1/M2 有、无 M3                  | 4-way failed            | **密码错**（WPA2 口径）       | 核对 PSK 字节                  |
| ④4-way      | 近处能连远处不能      | EAPOL 重传/丢                    | handshake timeout       | 弱信号丢 EAPOL                | 改善链路；查天线               |
| ④4-way      | 换板子/晶振批次后出现 | 高速率帧连续丢失                 | handshake timeout       | 晶振频偏超限                  | 实测频偏，查晶振（见射频十一） |
| ④4-way(SAE) | WPA3 网络连不上       | auth commit/confirm 失败         | SAE failed              | 老站不支持 SAE                | AP 关 WPA3-only 或站端升级     |
| ⑤DHCP       | 已连接但无 IP         | 4-way 完整                       | got ip 事件缺席         | 地址池满/DHCP 服务异常        | 三步甄别法第 2/3 步            |
| ⑤DHCP       | 已连接但无 IP         | 空口有 DHCP discover             | discover 无 offer       | AP 客户端隔离/桥接丢包        | 静态 IP+ARP 定位               |
| 全程        | 时连时不连            | 各阶段帧间歇正常                 | 多次重连循环            | 弱信号/干扰的综合表现         | 转第五章/第六章方法            |

> [!summary] 本章收束
> 「连不上」的解法不是背表，而是**流程**：先定位断在哪一阶段（4.2）→ 每阶段有固定的帧特征判据（4.3-4.7）→ 站端日志与空口对齐拿双份证据（4.8）→ 汇总成一张阶段断点表。下一章处理连接**建立之后**的断连与漫游问题——deauth 原因码会成为新的主角。
