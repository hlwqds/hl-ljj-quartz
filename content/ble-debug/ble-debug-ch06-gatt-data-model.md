---
title: "蓝牙调试实战（六）：GATT 数据模型"
date: 2026-10-27 12:00:00
pin: false
description: "「读不到写不进」的主战场：service/characteristic/descriptor 层级与句柄空间；ATT 读/写/notify/indicate 的 PDU 家族与常见 ATT 错误码表（Core Spec 口径）；MTU 协商（默认 23）与长包读写 Prepare/Execute Write 流程；GATT metadata 权限位与加密要求如何导致读不到；nRF Connect 与 Wireshark/btmon 里看服务发现全过程；自定义服务 App 读不到的教学复盘案例与根因速查表。"
tags: [ble-debug, BLE, Bluetooth, Debugging]
---

# 蓝牙调试实战（六）：GATT 数据模型

> [!info] 蓝牙调试实战系列 0. [[ble-debug|系列索引]]
> 上一章：[[ble-debug-ch05-connection-parameters|第五章：连接建立与参数]]
> **第六章：GATT 数据模型**（当前章）
> 下一章：[[ble-debug-ch07-disconnect-cases|第七章：案例——掉线与可靠性]]

## 本章证据口径

> [!note] 先立规矩
> 本章 GATT/ATT 机制、PDU 名称与错误码数值引 **Bluetooth Core Spec** 的 ATT/GATT 章节口径（ATT 层错误码为标准定义值，正文逐处标注）；MTU 默认值 23 字节为 Core Spec ATT 层定义。`nRF Connect`、`bluetoothctl`、`btmon`、Wireshark 过滤器均为真实可执行操作；**PDU 流与日志样例均为「格式示意」**；案例为**教学复盘案例，取材自常见故障模式综述**。不虚构实测读数。

## 6.1 现场引入：三类「读不到写不进」

连接建立之后（第五章的成果），新一层故障浮出水面。按用户可见表现分三类：

| 类型              | 典型描述                                   | 问题域直觉                                             | 首查位置                        |
| ----------------- | ------------------------------------------ | ------------------------------------------------------ | ------------------------------- |
| A：读特征报错     | 「读一下就弹 Insufficient Authentication」 | 权限/加密门槛                                          | 6.5 权限位 + 6.3 错误码         |
| B：写入无效       | 「写成功但设备没反应」/「写入直接报错」    | 长包被截断 / 写模式选错（Write With/Without Response） | 6.4 MTU + 写 PDU 家族           |
| C：服务列表不完整 | 「App 里看不到某个服务/特征」              | 发现流程被截断 / UUID 声明不一致                       | 6.2 句柄空间 + 6.6 发现过程取证 |

与第四章（扫不到）、第五章（连不上）合起来，构成了「BLE 三连问」：**在不在广播 → 建不建得起来 → 数据通不通**。本章是第三问的主战场，取证工具也升级：除了空口抓包，nRF Connect 的服务浏览器和 btmon 的 ATT 流水线都是本层的主力证据源。

## 6.2 GATT 数据模型：层级与句柄空间

GATT 把设备上的数据组织为「服务 → 特征 → 描述符」三层，底层落在 **ATT 的句柄空间**上（引 Core Spec GATT/ATT 口径）：

```text
句柄空间（16-bit handle，0x0001 – 0xFFFF），格式示意：
0x0001  [Service]  Generic Access (0x1800)          ← 服务声明
0x0002  [Char]     Device Name 声明（值=0x0003，权限）
0x0003  [Char]     Device Name 值
0x0004  [Service]  Battery Service (0x180F)
0x0005  [Char]     Battery Level 声明
0x0006  [Char]     Battery Level 值
0x0007  [Desc]     Client Characteristic Config (CCCD)
0x0008  [Service]  自定义服务 (128-bit UUID)
0x0009  [Char]     自定义特征声明
0x000A  [Char]     自定义特征值
...
```

三个结构性要点：

| 要点                           | 内容                                                                  | 调试意义                                                                         |
| ------------------------------ | --------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| 句柄是唯一地址                 | 每个属性一个 16-bit 句柄；特征值、CCCD 各占一个句柄                   | App 里「读特征」底层是「读某句柄」；句柄错位（表改版后句柄漂移）是缓存类故障之源 |
| 服务声明即边界                 | Primary/Secondary Service 声明划出服务的句柄范围                      | 服务发现（6.6）按声明句柄递归展开；声明缺失/顺序错 = 服务列表不完整              |
| CCCD 决定 notify/indicate 开关 | Client Characteristic Config Descriptor 由客户端写 0x0001/0x0002 启用 | 「收不到 notify」先查 CCCD 写了没有（1=notify，2=indicate 口径）                 |

SIG 已定义的标准服务用 16-bit 短 UUID（Battery 0x180F、Heart Rate 0x180D 等，引 SIG Assigned Numbers 口径）；自定义服务用 128-bit UUID。第四章 4.3.3 讲过广播层的 16/128-bit 坑——**同一类坑在 GATT 层再现**（6.7 案例主角）。

## 6.3 ATT 协议：PDU 家族与错误码

ATT 是无状态的请求-响应/指示-确认协议，四类操作各成家族（PDU 名称引 Core Spec ATT 口径）：

| 操作类别 | PDU                                                                                              | 语义                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| 读       | Read Request / Read Response；Read By Type Request/Response；Read By Group Type Request/Response | Read By Group Type 用于服务发现（按服务声明类型枚举）；Read By Type 用于特征发现；Read 按句柄读值 |
| 写       | Write Request / Write Response；Write Command（无响应）                                          | Request 有应答（可靠），Command 无应答（尽力而为）——「写入无效」的第一嫌疑组合                    |
| 通知     | Handle Value Notification                                                                        | 服务器→客户端无确认；须先写 CCCD                                                                  |
| 指示     | Handle Value Indication / Confirmation                                                           | 服务器→客户端有确认（更可靠但更慢）                                                               |

每个请求都可能被错误响应拒绝。**ATT 错误码表是本章的核心弹药**（错误码为 Core Spec ATT 层标准定义值）：

| 错误码 | 名称                        | 现场对应                                                    |
| ------ | --------------------------- | ----------------------------------------------------------- |
| 0x01   | Invalid Handle              | 句柄越界/服务表改版后缓存漂移                               |
| 0x02   | Read Not Permitted          | 特征权限声明禁读，App 硬读                                  |
| 0x03   | Write Not Permitted         | 同上，禁写                                                  |
| 0x05   | Insufficient Authentication | 安全等级不够（未配对/配对等级低）——**配对坑的 ATT 表现**    |
| 0x06   | Request Not Supported       | 请求的操作该属性不支持（如对不支持 indicate 的特征写 CCCD） |
| 0x07   | Invalid Offset              | 长包读取的 offset 越界（6.4）                               |
| 0x08   | Insufficient Authorization  | 授权不足（认证之外的授权层门槛）                            |
| 0x09   | Prepare Queue Full          | Prepare Write 队列满（长包写入流控）                        |
| 0x0A   | Attribute Not Found         | 服务发现到头了（**正常的发现结束标志**，不是错误现场）      |
| 0x0C   | Attribute Not Long          | 该属性不支持长读                                            |
| 0x0F   | Insufficient Encryption     | 链路未加密而该属性要求加密                                  |

> [!tip] 读错误码的纪律
> 错误码是**设备端的正式声明**，不是玄学。「读不到」先问「ATT Error Code 是几」：0x05/0x0F 归 6.5 的安全门槛；0x02/0x03 归权限位设计；0x01/0x07 归句柄与长包逻辑；App 连错误码都不展示时，换 nRF Connect 直接读同一句柄拿一手错误码。

## 6.4 MTU 协商与长包读写

### MTU 与 Exchange MTU

ATT 的默认 MTU 是 **23 字节**（Core Spec 口径）：3 字节 ATT 头 + 20 字节净负载。协商更大 MTU 的流程是客户端发起 Exchange MTU：

```text
客户端                              服务器
  │ ── Exchange MTU Request (协商值) ──► │
  │ ◄── Exchange MTU Response (取两者较小) │
  │   此后净负载上限 = min(两端 MTU) - 3   │
```

现场账：

| 场景                                      | 判据                                           | 结论方向                                           |
| ----------------------------------------- | ---------------------------------------------- | -------------------------------------------------- |
| 单包写超过 min(MTU)-3                     | 上位机库自动拆 Prepare Write（见下）或直接失败 | 先确认协商后的实际 MTU，再核业务包长               |
| 未发起 Exchange MTU                       | 抓包里没有该 PDU                               | 永远工作在 20 字节净负载——「大包写不进」的隐形首因 |
| Android 支持请求 MTU / iOS 由系统策略协商 | 平台 API 差异（官方文档口径）                  | 同一 App 在两平台有效 MTU 不同是常态               |

### 长包：Prepare Write / Execute Write

超过 MTU 的写，走「队列-提交」两段式（引 Core Spec ATT 口径）：

```text
客户端                                    服务器
  │ ── Prepare Write Request (offset=0) ──► │ 入队
  │ ── Prepare Write Request (offset=..) ──►│ 入队
  │ ── Execute Write Request (commit) ────► │ 一次性提交生效
```

两个衍生坑：

- **Prepare Queue Full（0x09）**：队列深度有限（实现相关，Core Spec 不定死），分片发太快被拒——「偶发写入失败 + 包越大越容易失败」的组合拳；
- **忘记 Execute**：只有 Prepare 没有 Execute，值从未生效——「写成功但设备没反应」的典型根因（B 类），上位机库 API 是否自动 Execute 要查文档；
- **offset 对不上**：分片 offset 不连续或越界触发 Invalid Offset（0x07）。

### 6.4.1 notify 链路：CCCD 的完整闭环

「收不到 notify」的排查按这条链逐环核对（每一步都有抓包特征）：

```text
客户端                                    服务器
  │ ── Write Request (CCCD句柄, 0x0001) ──► │ ① 订阅：写 CCCD
  │ ◄── Write Response ──────────────────── │
  │        …… 业务事件发生 ……              │
  │ ◄── Handle Value Notification ───────── │ ② 推送：无确认
  │ ◄── Handle Value Indication ─────────── │ ②' 指示版
  │ ── Handle Value Confirmation ─────────► │     （客户端必须确认）
```

| 断点     | 抓包特征                               | 根因方向                                                |
| -------- | -------------------------------------- | ------------------------------------------------------- |
| ① 未发生 | 抓包里没有写 CCCD 的 Write             | App 漏订阅（非设备问题）                                |
| ① 被拒   | Write 得到错误响应（0x02/0x06）        | 特征没声明 notify/indicate 属性                         |
| ② 无包   | CCCD 已写 1，事件发生却无 Notification | 设备端业务没触发 / 服务表句柄认知错位（6.2）            |
| ②' 卡住  | Indication 发出无 Confirmation         | 客户端没确认；indicate 会重试占满事件预算（第九章的账） |

另有一条易混项：**DLE（Data Length Extension）与 MTU 是两回事**——DLE 协商的是链路层单包净载荷（LL_LENGTH_REQ/RSP），MTU 管的是 ATT 层净负载；吞吐问题的账两者都要算（第九章展开），排「写不进」时只看 MTU 即可。

## 6.5 权限位与安全：为什么「读不到写不进」

GATT 属性带三层「门」（引 Core Spec GATT 口径）：**权限（permissions）**、加密要求、认证/授权要求。它们不占空口字节，只在被访问时生效——这也是为什么抓包里「看不到」权限，只能从 ATT 错误码反推：

| 门槛层        | 配置位置（设备端 metadata）                                                | 被拦时的 ATT 错误码 | 典型现场                                            |
| ------------- | -------------------------------------------------------------------------- | ------------------- | --------------------------------------------------- |
| 读/写权限     | 特征声明里的属性位与 ATT 元数据（Read/Write/Notify/Indicate 各自允许与否） | 0x02 / 0x03 / 0x06  | 固件模板复制后权限没改对，App 功能静默失败          |
| 加密要求      | 特征 metadata 要求加密链路                                                 | 0x0F                | 未配对直读保密特征                                  |
| 认证/授权要求 | metadata 要求带 MITM 的配对等级 / 授权层                                   | 0x05 / 0x08         | 配对了但等级不够（Just Works 无 MITM 达不到认证级） |

与第五章 5.5 的咬合点：**0x05/0x08 类错误的一半根子在配对**——设备要求「认证级」而手机走的是 Just Works（无 MITM），配对成功了等级还是不够。处置是让设备侧把门槛降到实际安全需求，或引导配对走带 MITM 的方式（Passkey/数字比较）。

设备端自查例（以使用 GATT 权限配置的平台通用思路为例，具体字段名随 SDK 而异，此处为示意）：把「用户可见错误」和「权限表」并排打出来，逐特征核对「业务预期 vs 声明权限」，十分钟就能排掉一半 B/A 类故障。

## 6.6 取证：看 GATT 发现过程

### 6.6.1 nRF Connect 服务浏览器

连接成功后（第五章的成果），nRF Connect 的设备详情页直接渲染完整服务树：服务 UUID → 特征（UUID/句柄/属性位 R/W/N/I）→ 描述符。三个取证用法：

| 用法              | 操作                                          | 判据                                                             |
| ----------------- | --------------------------------------------- | ---------------------------------------------------------------- |
| 服务齐不齐        | 对照设计文档数服务/特征                       | 缺服务 = 发现被截断或声明缺失（看下一条）                        |
| 权限位对不对      | 看每个特征的属性图标（读/写/notify/indicate） | 与设计不符 = 6.5 权限位问题                                      |
| 手动复现 App 操作 | 用 App 直接读/写同一特征、订阅同一 CCCD       | App 失败而 nRF Connect 成功 → 问题在 App 侧；两者都失败 → 设备侧 |

第三条是**分流神器**：先把「设备的问题」和「App 的问题」切开，再各自深挖。

### 6.6.2 Wireshark/btmon 里的服务发现 PDU 流

连接建立后，主机层的第一轮对话就是 GATT 发现（PDU 流格式示意；btmon 侧同构，HCI Event 里 ATT 层数据相同）：

```text
T+0.00  Exchange MTU Request (517)              ← 客户端先谈 MTU
T+0.01  Exchange MTU Response (517)
T+0.01  Read By Group Type Request (Primary Service)
T+0.02  Read By Group Type Response (0x1800, 0x180F, ...)
T+0.02  Read By Group Type Request (start=续起点)
T+0.03  Read By Group Type Response (自定义服务 128-bit)
T+0.03  Read By Group Type Request → Error: Attribute Not Found (0x0A)
        ↑ 发现结束的正常标志，不是故障
T+0.04  Read By Type Request (Characteristic)
T+0.04  Read By Type Response ×N （逐服务展开）
T+0.05  Read By Type Request → 0x0A 结束
```

对应命令与过滤器：

```bash
# HCI 层全程留痕（Linux 主机/带串口 HCI 的板子）
sudo btmon -w hci.pcap
# Wireshark 过滤器
btatt.opcode == 0x10        # Read By Group Type Request（服务发现）
btatt.opcode == 0x11        # Read By Group Type Response
btatt.opcode == 0x01        # Error Response（看 error code 字段）
btatt.opcode == 0x1b        # Handle Value Notification
btatt.opcode == 0x52        # Write Request（含写 CCCD）
```

发现被截断的抓包特征：Read By Group Type/Read By Type 序列**没有以 0x0A 收尾**就停了——中间某一请求得到错误码或超时，服务列表自然不完整（C 类的抓包判据）。

## 6.7 案例：自定义服务 App 读不到

**教学复盘案例，取材自常见故障模式综述。**现象：设备端新增一个自定义服务（128-bit UUID）+ 两个特征；nRF Connect 里能看到该服务；自研 App 的「读特征」操作报错，写入也不生效。连接参数与加密均未改动。

### 取证链

```text
步骤1  nRF Connect 手动读同一特征 → 成功读到值
       → 分流结论：设备侧特征本身健康，问题在 App 侧（6.6.1 分流神器）
步骤2  抓包对照 App 与 nRF Connect 的读操作
       → App 发的 Read Request 句柄 = 0x0023
       → nRF Connect 发的 Read Request 句柄 = 0x0027
       → 同一个特征在两边句柄不同！
步骤3  复盘 App 代码：App 缓存了上一版固件的服务表（句柄写死）
       → 新固件在表里插入了新服务，后续句柄整体后移 4
步骤4  修复方向：App 改为按 UUID 动态查找句柄，禁止硬编码句柄
步骤5  顺带发现：App 的写操作走的 Write Command（无响应），
       上位机以为发出即成功，偶发丢失表现为「写了没反应」
       → 关键写操作改用 Write Request（有响应，可靠）
```

### 三条复盘教训

| #   | 教训                                                                                                                                      | 对应机制     |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| 1   | **永远按 UUID 找特征，绝不缓存句柄**：服务表任何改版（插服务、调顺序、改权限）都会让句柄漂移，缓存句柄的 App 表现为「升级固件后全面失灵」 | 6.2 句柄空间 |
| 2   | 「写没反应」先分清 Write Request（有应答，失败可见）与 Write Command（无应答，失败静默）：调试期一律用 Request，量产后再权衡省开销        | 6.3 PDU 家族 |
| 3   | 分流纪律：nRF Connect 成功 + App 失败 = App 侧问题，先修 App 再怀疑固件——方向错了，取证做得再细也是白费                                   | 6.6.1        |

## 6.8 根因速查表

| 症状           | ATT 错误码                       | nRF Connect 表现       | 根因                                       | 对策                              |
| -------------- | -------------------------------- | ---------------------- | ------------------------------------------ | --------------------------------- |
| 读报错         | 0x02 Read Not Permitted          | 属性图标显示不可读     | 权限位声明禁读                             | 改特征权限或改用 notify           |
| 读报错         | 0x05 Insufficient Authentication | 读触发配对流程后仍失败 | 配对等级不够（Just Works vs 认证级）       | 降门槛或改配对方式（5.5 咬合）    |
| 读报错         | 0x0F Insufficient Encryption     | 未配对状态读保密特征   | 加密门槛                                   | 先配对加密再访问                  |
| 读报错         | 0x01 Invalid Handle              | 正常                   | 句柄缓存漂移（6.7 案例）                   | App 按 UUID 动态查找              |
| 写报错         | 0x03 Write Not Permitted         | 属性图标显示不可写     | 权限位禁写                                 | 改权限；确认是否该用 CCCD         |
| 写报错         | 0x07 Invalid Offset              | 长包偶发失败           | Prepare Write offset 越界                  | 核对分片逻辑                      |
| 写报错         | 0x09 Prepare Queue Full          | 大包高频写失败         | 长包队列溢出                               | 限速/减小 MTU 需求                |
| 写「成功」无效 | 无错误码                         | Write Command 静默     | Command 无应答，丢失不可见；或忘 Execute   | 改用 Write Request；确认 Execute  |
| 收不到 notify  | 无错误码                         | CCCD 值为 0            | 忘写 CCCD / CCCD 写失败                    | 先写 CCCD（1=notify，2=indicate） |
| 服务列表不全   | 发现序列未以 0x0A 收尾           | 服务树残缺             | 发现被错误/超时截断                        | 抓包定位第一个失败 PDU（6.6.2）   |
| 服务列表不全   | 无错误                           | 服务树缺某服务         | 广播/发现 UUID 声明不一致（16 vs 128-bit） | 对齐 UUID 声明（4.3.3 咬合）      |
| 大包写不进     | 无错误                           | MTU 显示 23            | 未协商 MTU                                 | 发起 Exchange MTU；核两端支持值   |

> [!summary] 本章收束
> 「读不到写不进」的解法还是流程：先分流（nRF Connect 手动复现，切开设备侧与 App 侧）→ 拿 ATT 错误码定层（6.3 表）→ 句柄/权限/MTU/配对四个嫌疑各归各位 → 抓包核对发现过程与 PDU 家族。至此「扫不到、连不上、读不到」三连问全部有了各自的取证地图；下一章转入时间轴上的问题——连接**建立之后**的掉线与可靠性，断连原因码与空口时间线将成为主角。
