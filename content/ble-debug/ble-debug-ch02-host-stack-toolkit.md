---
title: "蓝牙调试实战（二）：主机栈工具链"
date: 2026-10-27 12:00:00
pin: false
description: "把第一章的分层取证落到手上工具：先用 30 秒地图认清 Linux BlueZ 从应用到控制器的分层结构（内核侧 hci/驱动 + 用户态 bluetoothd），明确每层插管子的位置；然后逐个上手 bluetoothctl（scan/info/connect/gatt 系列）、btmon（HCI 命令与事件流逐段读法）、btmgmt 与 mgmt API、hcidump 与传统抓包对比；再速览 ESP-IDF 侧 NimBLE 与 Bluedroid 的日志等级与常见错误码速查（HCI error / ATT error 对照小表）、手机端 Android 蓝牙 HCI 日志导出与 iOS sysdiagnose 概念，收尾给一张「想看 X → 用 Y」速查总表。所有命令真实可复制，日志样例均标注格式示意，不虚构读数。"
tags: [ble-debug, BLE, Debugging, Bluetooth]
---

# 蓝牙调试实战（二）：主机栈工具链

> [!info] 蓝牙调试实战系列 0. [[ble-debug|系列索引]]
> 上一章：[[ble-debug-ch01-debug-methodology-toolbox|第一章：调试方法论与工具箱]]
> **第二章：主机栈工具链**（当前章）
> 下一章：[[ble-debug-ch03-protocol-map|第三章：协议栈全景与边界]]

## 本章装备清单

| 分类 | 装备                                       | 价格/状态 | 用途                                             |
| ---- | ------------------------------------------ | --------- | ------------------------------------------------ |
| 已有 | Linux 笔记本（BlueZ 已装，多数发行版默认） | ✅ 免费   | 主力取证机：bluetoothctl/btmon/btmgmt            |
| 已有 | 任一 BLE 设备（手环/传感器/开发板）        | ✅ 免费   | 扫描、连接、GATT 操作的观测对象                  |
| 可选 | ESP32/ESP32-C3/NRF52 真机 + USB 线         | ~几十元   | 嵌入式侧视角（NimBLE/Bluedroid 日志）            |
| 可选 | Android 手机（开发者选项可用）             | 手边找    | HCI 日志（btsnoop）导出                          |
| 提醒 | 空口抓包留给第四章                         | —         | 本章全部命令在正常主机模式即可运行，不需要嗅探器 |

## 2.1 Linux 蓝牙栈 30 秒地图

动手之前，先花 30 秒看清你到底在哪一层插管子。BlueZ 时代（内核 3.x 起协议栈主体下沉内核）的 Linux 蓝牙栈从上到下是：

```text
┌────────────────────────────────────────────────────────────┐
│ 应用层   你的程序(D-Bus/BlueZ API) / bluetoothctl / 测试脚本 │  ← 最常站的一层
├────────────────────────────────────────────────────────────┤
│ 守护进程 bluetoothd（用户态：设备发现/配对/GATT 服务注册）    │  ← 配对与 GATT 的管家
├────────────────────────────────────────────────────────────┤
│ 用户态↔内核接口  mgmt API(控制通道) / HCI socket(原始流)     │  ← btmgmt 走 mgmt，btmon 监听 HCI
├────────────────────────────────────────────────────────────┤
│ 内核     蓝牙子系统：L2CAP/RFCOMM/SMP/ATT 等协议实现          │
│          hci_core（HCI 层核心，连接/查询/链路管理）           │
├────────────────────────────────────────────────────────────┤
│ 驱动     btusb(USB dongle) / hci_uart / 厂商传输驱动 …        │  ← 厂商差异集中地
├────────────────────────────────────────────────────────────┤
│ 控制器   芯片内跑的 LE Controller（PHY/LL：广播/连接/跳频）   │  ← 对主机是黑盒
└────────────────────────────────────────────────────────────┘
```

记住四层职责边界，工具选择就不再靠猜：

| 层              | 负责什么                                     | 谁在管          | 出问题时的口供在哪里                         |
| --------------- | -------------------------------------------- | --------------- | -------------------------------------------- |
| 应用/工具       | 发起扫描、连接、GATT 读写                    | 你的程序/CLI    | 命令返回值与 D-Bus 错误                      |
| bluetoothd      | 设备发现策略、配对代理、GATT 服务数据库      | bluetoothd 守护 | `bluetoothctl` 反馈、journalctl 单元日志     |
| 内核协议栈      | L2CAP 通道、SMP 配对、ATT 处理、HCI 命令组装 | 内核蓝牙子系统  | `btmon` 里的 HCI 命令/事件、内核日志         |
| 控制器（LE LL） | 广播、扫描、连接维护、跳频、加密的硬件部分   | 芯片固件        | HCI 事件里的错误码；内部对主机不可见（黑盒） |

> [!tip] 「调试时你在哪一层插管子」
> 第一章的取证顺序在这里有物理对应：`bluetoothctl` 问的是应用/守护进程层的**结果**（扫到了吗、连上吗）；`btmon` 问的是主机与控制器之间的**对话原文**（HCI 命令与事件逐条流）；第四章的空口抓包则绕过整个协议栈直接看电磁波上说了什么。顺序不对，就会拿着示波器去查一个 `bluetoothctl info` 一眼能看出「设备没配对」的问题。

本章按这张地图从上往下走。

## 2.2 bluetoothctl 实战：应用层的方向盘

`bluetoothctl` 是 BlueZ 的交互式控制台，走 D-Bus 与 bluetoothd 对话。它是 L1/L3 之间最顺手的一层：既能当「测试仪」快速复现现象，又能读出设备的关键属性。

```bash
bluetoothctl                      # 进入交互式控制台
[bluetooth]# power on             # 上电（控制器 powered）
[bluetooth]# scan le on           # 只扫 BLE（scan on 会连 BR/EDR 一起扫，噪声大）
[WAIT]# scan le off               # 扫描结果缓存后停掉，减噪
[bluetooth]# devices              # 已发现的设备列表（MAC + 名字）
[bluetooth]# info XX:XX:XX:XX:XX:XX
```

`info` 输出的关键字段（字段名为真实输出结构，数值示意）：

| 字段                          | 含义                      | 调试含义                                                     |
| ----------------------------- | ------------------------- | ------------------------------------------------------------ |
| `Device:` 后的 `Name`/`Alias` | 广播名/本地别名           | 名字空 = Scan Response 没拿到或固件没放名字（第四章的主菜）  |
| `Paired: yes/no`              | 是否已配对                | 连接失败第一嫌疑；`no` 却要求加密服务 → 配对流程问题         |
| `Bonded: yes/no`              | 是否已绑定（持久化密钥）  | 绑定态不对是「换手机后连不上」的经典根因                     |
| `Trusted: yes/no`             | 是否信任                  | 部分 Profile 需 `trust` 才自动接受连接                       |
| `Connected: yes/no`           | 当前连接状态              | 配合 `connect`/`disconnect` 观察状态机                       |
| `RSSI:`                       | 最近一次广播的接收强度    | 只在设备在广播时更新；数值趋势有用，绝对值跨机型不可比       |
| `TxPower:`/`UUIDs:`           | 广播里的发射功率/服务列表 | UUID 列表空 = 广播里没带服务 UUID（影响部分 App 的过滤显示） |

连接与 GATT 操作三连：

```bash
[bluetooth]# connect XX:XX:XX:XX:XX:XX     # 建立连接（自动进入 GATT 发现）
[NEW] Primary Service ...                  # 发现的服务逐条打印（格式示意）
[CHG] Device XX:.. Connected: yes
[bluetooth]# menu gatt                     # 进入 GATT 子菜单
[gatt]# list-attributes XX:XX:XX:XX:XX:XX  # 列出该设备全部服务/特征/句柄
[gatt]# select-attribute /service0001/char0000
[gatt]# read                               # 读当前特征
[gatt]# write "0x01"                       # 写当前特征
[gatt]# notify on                          # 订阅 notify，观察数据是否持续到达
[gatt]# acquire-notify                     # 更高吞吐的裸 socket 方式（大流量调试用）
```

调试含义：`connect` 卡住不动 = 连接请求没被对端接受（第五章逐阶段拆）；`list-attributes` 列表为空或不完整 = 服务发现中断（GATT 问题入口，第六章）；`read` 返回错误码 = ATT 层错误（2.6 的错误码表直接查）；`notify on` 之后毫无数据 = 要么对端没发，要么 CCCD 没写成功——用 `btmon` 分辨（下一节）。

## 2.3 btmon：HCI 命令/事件流逐段读

`btmon` 是本章的主角：它监听主机与控制器之间的 HCI 通道，把每一条命令、事件、ACL 数据原样翻译出来。这正是第一章 L3 层的「主机栈自述」。

```bash
sudo btmon -t          # -t 打印时间戳；Ctrl+C 结束。输出也可重定向存档
```

以一次「扫描 → 连接 → 读 GATT」为例，btmon 输出的骨架如下（**格式示意**：结构、命令名与字段名按 HCI 规范真实措辞，数值与地址为示意）：

```text
# 段一：配置扫描——主机告诉控制器怎么扫
< HCI Command: LE Set Scan Parameters (0x08|0x000b) plen 7
  Scan type: Active (0x01)          ← Active = 会发 SCAN_REQ（能拿到 Scan Response）
  Scan interval: 60.000 msec / Scan window: 30.000 msec
> HCI Event: Command Complete (0x0e) plen 4
  LE Set Scan Parameters (0x08|0x000b) ncmd 1 status 0x00   ← status 0x00 = 成功
< HCI Command: LE Set Scan Enable (0x08|0x000c) plen 2
  Scanning enabled. Filter duplicates disabled
# 段二：控制器逐条上报广播——每一包广播一个报告
> HCI Event: LE Advertising Report (0x0d) plen 35
  Num reports: 1
  Event type: Connectable undirected advertising (0x00)
  Address: XX:XX:XX:XX:XX:XX (RANDOM)
  Data length: 17
  Company: Nordic Semiconductor ...   ← 广播数据逐字段解码
  Flags: Simultaneous LE and BR/EDR ...
  RSSI: -67 dBm (-67)
# 段三：停扫描、发起连接——参数全部可读
< HCI Command: LE Create Connection (0x08|0x000d) plen 25
  Scan interval: 60.000 msec / window: 60.000 msec
  Initiator filter: Address of the peer
  Peer address: XX:XX:XX:XX:XX:XX (RANDOM)
  Conn interval: 30.00 msec / latency: 0 / Supervision timeout: 5000 msec
> HCI Event: LE Connection Complete (0x0d) plen 18
  Status: Success / Handle: 0x0040
  Role: master / Conn interval: 30.00 msec
# 段四：GATT 读——ATT PDU 在 ACL 数据里逐条可见
> ACL Data RX: Handle 0x0040 plen 9        # ATT Exchange MTU Request/Response 常先出现
  ATT: Read Request (0x0a) len 2
    Handle: 0x0003
< ACL Data TX: Handle 0x0040 plen 7
  ATT: Read Response (0x0b) len 4
```

四段各自回答一个调试问题：

| 段        | 命令/事件                                                           | 回答的问题与常见异常                                                         |
| --------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| 扫描配置  | `LE Set Scan Parameters`/`LE Set Scan Enable`                       | 扫描窗口/间隔是多少？Active 还是 Passive？（决定能否拿到名字）               |
| 广播上报  | `LE Advertising Report`（扩展版：`LE Extended Advertising Report`） | 对端到底广播了什么内容、什么类型、RSSI 多少——**绕过手机 App 过滤的地面真相** |
| 连接发起  | `LE Create Connection` + `LE Connection Complete`                   | 事件里的 `Status` 非 0x00 就是连接失败的直接答案（2.6 错误码表）             |
| GATT 交互 | ACL Data 里的 ATT PDU（Read/Write/Notify/MTU）                      | 交互停在哪条 PDU、错误码是什么（第六章逐条拆）                               |

三条阅读纪律。其一，**方向符号 `<`（主机→控制器，TX）与 `>`（控制器→主机，RX）是时间线的主轴**，「谁先说的、谁没回」全靠它。其二，`status`/`Status` 字段一旦非 0x00（成功），立即查错误码表——HCI 错误码是 L3 层最接近「决定性证据」的东西。其三，btmon 看到的是**主机-控制器通道**，不是空口：广播报告是控制器「转述」的，控制器没扫到的东西 btmon 里就没有；想看空口原文，第四章的嗅探器接棒。

> [!note] 证据口径
> 上述骨架的结构、命令名与字段名按 Bluetooth Core Spec 的 HCI 部分与 btmon 实际输出措辞整理；btmon 具体排版随 BlueZ 版本略有差异（如扩展广播事件、厂商事件段）。数值与地址均为示意，取证时以实际输出为准；命令用法以 BlueZ 官方文档为准。

## 2.4 btmgmt 与 mgmt API：控制通道快查

`bluetoothctl` 走的是 bluetoothd 的 D-Bus 接口；`btmgmt` 走的是内核 **mgmt API**——一条更靠下的控制通道。当 bluetoothd 行为可疑（版本 bug、配置异常、D-Bus 挂了）时，`btmgmt` 是绕过它的旁路：

```bash
sudo btmgmt info            # 控制器索引、地址、版本、支持设置（LE/BREDR/SECURE_CONN 等）
sudo btmgmt power off       # 关控制器
sudo btmgmt le on           # 打开 LE（低功耗）
sudo btmgmt bredr off       # 关经典蓝牙（双模 dongle 上隔离变量用）
sudo btmgmt power on
sudo btmgmt find            # 一次性发现（含 LE 扫描），结果直出终端，适合脚本取证
sudo btmgmt advertise on    # 本机对外广播（把 Linux 当外设时用）
sudo btmgmt clr-adv         # 清除广播实例
```

常用速查表：

| 命令                      | 看什么/干什么      | 典型调试用法                                     |
| ------------------------- | ------------------ | ------------------------------------------------ |
| `btmgmt info`             | 控制器身份与能力位 | 确认 dongle 支持 LE；确认 powered/le 的实际状态  |
| `btmgmt le on` / `le off` | LE 能力开关        | 「只有经典蓝牙能连、BLE 全哑」类问题的第一检查项 |
| `btmgmt bredr off`        | 关 BR/EDR          | 强制纯 LE 环境做对照实验（钉死双模干扰变量）     |
| `btmgmt find`             | 主动发现，结果直出 | 脚本化取证：不同时段/位置反复跑，diff 广播名列表 |
| `btmgmt power off/on`     | 控制器重启         | 控制器进入异常态（ HCI 无响应）时的最低成本复位  |
| `btmgmt advertise on`     | 本机作为外设广播   | 验证「手机扫不到」问题时，用已知正常的广播源对照 |

与 bluetoothctl 的分工一句话：**做实验、看结果用 bluetoothctl；定状态、绕守护进程、写脚本用 btmgmt**。两者对同一控制器的状态应当一致——不一致本身就是证据（bluetoothd 或 D-Bus 层出了问题）。

## 2.5 hcidump 与传统抓包：老工具的存留价值

`hcidump` 是 BlueZ 时代的元老：监听 HCI 通道并可直接落盘为 btsnoop 格式文件。

```bash
sudo hcidump -t -R            # -t 时间戳；-R 原始十六进制一并打印
sudo hcidump -w dump.snoop    # 落盘为 btsnoop 文件，可用 Wireshark 直接打开
```

与 btmon 的取舍：

| 维度         | btmon                           | hcidump                                                  |
| ------------ | ------------------------------- | -------------------------------------------------------- |
| 可读性       | 逐字段解码，Human-readable 最好 | 摘要式，细节常要配合 `-R` 看原始字节                     |
| 输出格式     | 文本为主                        | 原生支持 btsnoop 落盘，Wireshark 无缝衔接                |
| 现代 Linux   | BlueZ 官方推荐，持续维护        | 部分发行版需另装，功能上被 btmon 覆盖                    |
| 什么时候用它 | 日常 L3 取证主力                | 对端/老系统只留了 hcidump；需要 btsnoop 文件喂 Wireshark |

而**手机侧的 btsnoop**（下一节）才是「HCI 流抓包」的最大产量来源——Android 每台手机都能导出完整 HCI 日志，Linux 这套工具的价值在于桌面/网关场景与脚本化复现。

## 2.6 嵌入式侧：ESP-IDF 的 NimBLE 与 Bluedroid

嵌入式设备没有 shell，但日志与事件比手机更可控。乐鑫提供两套主机栈：**NimBLE**（轻量，默认推荐）与 **Bluedroid**（功能全，含经典蓝牙）。本章只讲取证视角（怎么配日志、怎么读错误），API 细节以官方文档为准。

**日志等级**。两套栈的日志都走 ESP-IDF 日志系统，按组件过滤：

```bash
idf.py monitor                                   # 串口日志主力（退出: Ctrl+]）
idf.py monitor --print_filter="NimBLE:I,bt:W"    # 按组件与级别过滤（NimBLE 例）
idf.py monitor --print_filter="BT_APPL:W,btc:W"  # Bluedroid 例：组件名以项目实际为准
```

| 需求           | NimBLE                                     | Bluedroid                                        |
| -------------- | ------------------------------------------ | ------------------------------------------------ |
| 运行时日志开关 | `ble_hs_log_...`/modlog 接口（以版本为准） | `esp_log_level_set("*", ESP_LOG_*)` 全局/按标签  |
| 编译期裁剪     | menuconfig → Bluetooth → NimBLE Options    | menuconfig → Bluetooth → Bluedroid Options       |
| 断连原因码     | GAP 断连回调带 `reason`（HCI 错误码口径）  | `ESP_GATTS_DISCONNECT_EVT` 带 `reason`（同口径） |

**错误码速查**。两条体系都要认识：HCI 错误码（Bluetooth Core Spec 统一定义，两套栈通用）与 ATT 错误码（GATT 交互层）。高频项：

| 错误码（名称）                                               | 体系 | 典型含义与第一反应                                          |
| ------------------------------------------------------------ | ---- | ----------------------------------------------------------- |
| `0x08` HCI Conn Connection Timeout                           | HCI  | 对端失联/超距离——链路问题，查 supervision timeout 与射频    |
| `0x3E` HCI Conn Failed to be Established / Sync Timeout      | HCI  | 连接请求发了对方没接住——广播窗口/时序冲突，第五章主菜       |
| `0x0C` HCI Command Disallowed                                | HCI  | 命令与当前状态冲突（重复连接、状态机没就绪）                |
| `0x3B` HCI Unspecified Connection Failure（常见于 ESP 复连） | HCI  | 多见于参数协商失败或密钥问题，先删绑定重试                  |
| `0x02` ATT Read Not Permitted / `0x03` Write Not Permitted   | ATT  | 权限位没开——固件里特征权限配置问题（第六章）                |
| `0x05` ATT Insufficient Authentication                       | ATT  | 访问需要加密/认证而链路没有——配对加密流程问题（第五、六章） |
| `0x0d` ATT Insufficient Authorization / `0x08` Timeout       | ATT  | 应用层授权/响应超时——查固件 ATT 处理是否阻塞                |

> [!note] 口径说明
> 错误码数值与名称按 Bluetooth Core Spec（HCI Error Codes 与 ATT Error Codes 章节）口径整理；具体数字以所用规范版本表格为准，ESP-IDF 头文件（`hci_error.h`/`esp_gatt_defs.h` 等命名随版本）里有同名宏可直接对照。日志接口的组件名与函数名随 IDF 版本演进，以所用版本官方文档为准（「待核对」项按实际项目版本核对后再写进案例报告）。

## 2.7 手机端：Android btsnoop 与 iOS sysdiagnose

手机是 BLE 调试里最大的产量终端，它的 HCI 日志是 L3 取证的最后一块拼图。

**Android：开发者选项导出 HCI 日志**。路径：设置 → 开发者选项 → 打开「蓝牙 HCI 信息收集日志」（不同厂商措辞/入口略有差异）；之后正常复现问题（nRF Connect 操作/自家 App）；设置 → 开发者选项 → 「错误报告」或「生成日志」（部分机型在 bugreport 里），取回 `btsnoop_hci.log`。**注意**：开关打开后的日志才被记录，先开开关再复现；部分厂商机型对 HCI 日志有裁剪，导出为空时换原生类机型。

```text
Wireshark 打开 btsnoop_hci.log 的姿势（第四章起反复使用）：
  File → Open → 选 .log 文件 → 自动按 btsnoop 协议解析
  过滤式：btatt / btatt.opcode.method == 0x0a   （只看 ATT Read Request）
         bthci_evt.code == 0x3e                  （只看连接建立失败事件）
         btcommon.eir_ad.entry.device_name       （广播名相关字段）
```

这条日志的定位要说清：它是**手机主机栈与控制器之间的对话**（L3），不是空口（L2）——手机控制器没扫到的广播它自然也没有；但它回答了「手机这一端到底发了什么命令、收到了什么错误」，是分辨「App 的问题 / 手机栈的问题 / 对端的问题」的关键证人。取证时同样按第一章纪律标注：机型、系统版本、日志导出方式。

**iOS：sysdiagnose 概念**。iOS 无 HCI 级导出（Apple 不开放），能拿到的是 sysdiagnose 里的蓝牙子系统日志：同时按侧键+音量键（或长按电源组合，随机型）触发 sysdiagnose，包内含蓝牙相关日志片段。定位：**现象级证据 + 有限的自述**，深度取证仍以「L1 现象记录 + L2 空口嗅探」为主——这也解释了为什么 BLE 空口抓包（第四章）的排期通常比 WiFi 系列更靠前：手机端不可透明，空口就是唯一的中立证人。

## 2.8 收尾：想看 X → 用 Y 速查总表

| 想看什么                         | 用什么                                              | 备注                                     |
| -------------------------------- | --------------------------------------------------- | ---------------------------------------- |
| 附近有哪些 BLE 设备在广播        | `bluetoothctl` → `scan le on` → `devices`           | 第一步永远先做                           |
| 某设备的配对/绑定/RSSI 状态      | `bluetoothctl` → `info <MAC>`                       | Paired/Bonded 字段是连接问题第一嫌疑     |
| 读/写/订阅某个特征               | `bluetoothctl` → `menu gatt` 系列                   | 错误返回直接对照 ATT 错误码              |
| 主机发了什么命令、控制器回了什么 | `sudo btmon -t`                                     | L3 主力；`<`/`>` 分方向                  |
| 连接失败的直接原因               | btmon 里 `LE Connection Complete` 的 `Status`       | 对照 2.6 错误码表                        |
| 广播内容原始字节                 | btmon 的 `LE Advertising Report` / nRF Connect 详情 | 第四章逐字段拆                           |
| 绕过 bluetoothd 做控制/脚本取证  | `btmgmt`（info/le/find/advertise）                  | 与 bluetoothctl 状态不一致 = 守护层问题  |
| HCI 流落盘给 Wireshark           | `hcidump -w` 或 Android btsnoop 导出                | btsnoop 格式通用                         |
| 本机当外设广播（对照实验源）     | `btmgmt advertise on`                               | 排查「扫不到」时的已知正常源             |
| 控制器能力与开关状态             | `sudo btmgmt info`                                  | LE 位没开是经典乌龙                      |
| ESP32 栈内日志与断连原因         | `idf.py monitor --print_filter=...`                 | 组件名随栈（NimBLE/Bluedroid）与版本而异 |
| 手机端到底发了什么命令           | Android 开发者选项 HCI 日志 → Wireshark             | L3 手机侧；iOS 只到 sysdiagnose 概念级   |
| 空口上双方说了什么               | nRF Sniffer + Wireshark                             | **留给第四章**                           |

> [!tip] 本章之后的标准动作
> 任何 BLE 问题，本章工具给出的「标准三件套」是：`bluetoothctl` 钉现象（L1）、`btmon` 拿对话原文（L3）、必要时 Android btsnoop 交叉对时——拿不出解释时，才升级到空口嗅探（第四章）。这三样都免费。

---

## 本章小结

- **分层地图**：应用 → bluetoothd → mgmt/HCI 接口 → 内核协议栈 → 驱动 → 控制器黑盒；工具选层不靠猜（2.1）。
- **bluetoothctl**：`scan le`/`info`/`connect`/`menu gatt` 是应用层方向盘，`Paired/Bonded/RSSI` 是连接问题第一嫌疑字段（2.2）。
- **btmon**：HCI 命令/事件流逐段读——扫描配置、广播报告、连接完成状态码、ATT PDU 四段各有分工；`Status` 非 0 立即查错误码（2.3）。
- **btmgmt**：mgmt 控制通道是绕过 bluetoothd 的旁路，`info`/`le`/`bredr off`/`find` 适合定状态与脚本取证（2.4）。
- **嵌入式与手机端**：ESP-IDF 两套栈的日志过滤 + HCI/ATT 错误码速查；Android btsnoop 是手机侧 L3 主力，iOS 只到 sysdiagnose 现象级（2.6、2.7）。

**本章自查清单**（全部打勾再进第三章）：

- [ ] 在 Linux 上完成一次「扫描 → 连接 → 读一个特征」，同时 `btmon` 全程记录
- [ ] 能在 btmon 输出里指出方向符号、`LE Connection Complete` 的 Status 字段位置
- [ ] 用 `btmgmt info` 确认过自己 dongle 的 LE 能力
- [ ] 在一台 Android 上导出过一次 btsnoop 并用 Wireshark 打开
- [ ] 能说出 btmon 与空口抓包的视野差异（各能看到/看不到什么）

下一章把名词表建立起来：BLE 协议栈从控制器（PHY/LL）到主机（GAP/GATT/ATT/L2CAP/SM）的全景分工、HCI 在其中站在哪里、单芯 SoC 与双芯方案对取证位置的差异，以及 BR/EDR 边界的一页划清——见 [[ble-debug-ch03-protocol-map|第三章：协议栈全景与边界]]。

### 本章事实出处清单

| 事实                                             | 出处                                                                                         |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| BlueZ 架构（内核协议栈 + bluetoothd + mgmt API） | BlueZ 官方文档（www.bluez.org）与内核文档 Documentation/networking/bluetooth.rst             |
| 2.2/2.3/2.4/2.5 的命令与输出字段                 | `bluetoothctl`/`btmon`/`btmgmt`/`hcidump` 手册页与 BlueZ 官方文档；输出格式以工具版本为准    |
| HCI 错误码 / ATT 错误码名称                      | Bluetooth Core Spec（HCI Error Codes、ATT Error Codes 章节）；ESP-IDF 头文件宏名随版本待核对 |
| Android HCI 日志导出路径                         | Android 官方开发者文档（btsnoop HCI log）；厂商入口措辞有差异                                |
| 2.3 btmon 骨架                                   | 结构与命令名按 Core Spec HCI 部分整理；数值与地址为格式示意                                  |
