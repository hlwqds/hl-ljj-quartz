---
title: "Zig × ESP32-S31 全栈开发（二十四）：MQTT 3.1.1 与 OTA 应用协议"
date: 2026-12-09 18:00:00
description: "把设备接入云端的最后一公里拆成可判定的零件：MQTT 3.1.1 的固定头与剩余长度变长编码（4 字节上限、非最短编码拒绝）、CONNECT/CONNACK/PUBLISH/四个 ACK/SUBSCRIBE 的字节布局、QoS 0/1/2 的真实差异与 QoS2 去重、主题过滤器里 + 与 # 的父子层语义、会话心跳与 inflight 背压、OTA 清单的 SHA-256 + Ed25519 信任链、A/B 槽位与连续失败回滚，以及为什么这些都不需要连上一个 broker 就能逐字节钉死。"
tags: [zig, esp32-s31, riscv, mqtt, ota, qos, ed25519, sha256, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 上一章：[[ch23-tls-http|第二十三章：TLS 记录层、密钥派生与 HTTP/1.1]]
>
> **本章：第二十四章：MQTT 3.1.1 与 OTA 应用协议**
>
> 下一章：[[ch25-wifi-blob-boundary|第二十五章：Wi-Fi blob 边界与 ABI 垫片]]

# Zig × ESP32-S31 全栈开发（二十四）：MQTT 3.1.1 与 OTA 应用协议

上一章把「加密管道」修好了：记录层能分片，密钥能从共享秘密派生，X.509 能验，
HTTP/1.1 能解。但它有一个刻意的留白——**管道里流什么，没写**。

嵌入式设备接入云端，流的通常不是 HTTP。摄像头要推快照、传感器要报数值、
设备要收命令、固件要升级，这四件事的公共载体是 MQTT；而“固件要升级”这件事
本身，又需要另一套东西：镜像怎么切、签名怎么验、升级失败怎么退回去。

本章把这两层放在一起做，理由是它们**共用同一个运维面**：

| 运维动作     | 传输载体                     | 失败后果                    |
| ------------ | ---------------------------- | --------------------------- |
| 上报状态     | MQTT PUBLISH（QoS0/1）       | 丢一条读数，可容忍          |
| 接收命令     | MQTT PUBLISH（QoS1/2）+ 订阅 | 命令丢了/重复执行，不可容忍 |
| 推送新固件   | MQTT 分块 + 清单广播         | 半包被当成完整镜像 → 变砖   |
| 确认升级成功 | 应用自检 → A/B 确认          | 没确认就回滚，好固件被误杀  |

四个动作里三个的失败模式都指向同一件事：**状态机的边界**。所以本章不写
“一个能跑通 demo 的 MQTT 客户端”，而是写三层可判定的东西：

```text
        ┌──────────────────────────────────────────────────────────┐
        │  ota.zig    清单(SHA-256/Ed25519) + A/B 槽位 + 回滚决策   │
        └──────────────────────────┬───────────────────────────────┘
                                   │ 版本/摘要/签名三关
        ┌──────────────────────────▼───────────────────────────────┐
        │  session.zig  连接/心跳/重传窗口/inflight 背压/QoS2 去重   │
        └──────────────────────────┬───────────────────────────────┘
                                   │ 一条完整报文
        ┌──────────────────────────▼───────────────────────────────┐
        │  mqtt.zig  固定头/剩余长度/各类报文/主题匹配/流式重组      │
        └──────────────────────────────────────────────────────────┘
```

> [!warning] 本章的证据边界（重要）
>
> ch17 的以太网驱动**仍未闭环**（DMA 软复位超时、MDIO 扫不到 PHY、TX 超时，
> 见 `practice/zig-esp32-s31/logs/ch17d-boot.log`）；ch09 的 flash 写入与
> 自定义分区表不在本工程里，本章的分区表依旧是 `single-app-large`（只有
> factory，没有 `otadata`/`ota_0`/`ota_1`）。因此本章**不可能、也不允许**
> 给出下面任何一条结论：
>
> - ✗「板子连上了 MQTT broker」
> - ✗「SUBSCRIBE 成功，收到了服务器的消息」
> - ✗「完成了一次真实的 OTA 升级」
> - ✗「固件已经写进 ota_0 并切换了启动分区」
>
> 本章的全部证据只有两种来源：
>
> 1. **主机侧单测**（`zig build test`，27 个用例）：已知答案来自 RFC 8032 §7.1
>    TEST 1（Ed25519）、FIPS 180-4（SHA-256 的 `abc`）、MQTT 3.1.1 §2.2.3
>    （剩余长度宽度）；协议结构用“手工拼字节 vs 本模块输出”对拍；
> 2. **板侧自检**（`practice/zig-esp32-s31/logs/ch24-boot.log`）：
>    `checks: passed=13 failed=0 total=13` 与 `main: verdict=pass`。
>    板子跑的是**同一份模块**，会话发出去的字节全部进了 `.bss` 里的录制器。
>
> 真实 broker 连接与真实 OTA 的判据写在 24.11，要等 ch17 与 ch09 闭环之后才成立。
> 把“能编出合法的 CONNECT”写成“连上了服务器”，是这类章节最常见的过度承诺。

---

## 24.1 为什么把 MQTT 和 OTA 放在一章

先设想只做 MQTT 的情形。你会得到一个“能发能收”的客户端：CONNECT 编得出，
PUBLISH 解得出，订阅也能发。它全部正确，却**没有回答最关键的问题**：

一个跑了三个月、内存碎片化、flash 上还有一半旧固件的设备，收到一条
“新固件在这里”的消息之后，凭什么相信它、怎么写它、写完起不来怎么办？

这三个问题都不是 MQTT 能回答的。MQTT 只保证“这条消息送到了”（QoS1）
或者“只送到一次”（QoS2）。它不保证消息里的字节是可执行的固件，也不保证
这份固件能在你的板子上跑起来。

反过来，只做 OTA 也不行：镜像清单再严谨，没有一条可靠的控制通道，
你连“有新版本”都通知不到设备。

所以本章的边界是：**协议负责把字节送到，OTA 负责判断这些字节能不能信**。
两者的交界处正好是一个设计决策点——这也是工程实现里最容易埋坑的地方：

| 交界处的问题               | 本章的选择                                             |
| -------------------------- | ------------------------------------------------------ |
| 固件分块用 QoS 几？        | QoS1。块级重传比 QoS2 便宜，且重复写入同一偏移是幂等的 |
| 清单和分块走同一条主题吗？ | 不同主题。清单独立的一条，且必须验签                   |
| 验签失败要不要回滚？       | 不回滚（还没切槽），只丢弃并计数                       |
| 验签通过但跑不起来怎么办？ | 回滚。这是 24.7 的 A/B 状态机存在的原因                |

这张表就是本章的骨架。它同时解释了为什么两件事要放在一章：
**“消息送达”与“内容可信”是两件事，而 OTA 恰好同时需要两者。**

### 24.1.1 本章在系列里的位置

| 章节 | 交付              | 与本章的关系                                                   |
| ---- | ----------------- | -------------------------------------------------------------- |
| ch09 | flash 与分区表    | **待闭环**：真写 flash、真做 `otadata` 要它                    |
| ch17 | 以太网 MAC/PHY    | **待闭环**：本章的所有报文都没有出口                           |
| ch20 | TCP 状态机        | 本章的字节流应由它承载，本章不调用                             |
| ch22 | socket 与事件循环 | **签名级依赖**：`StreamReader.push(bytes)` 的 `bytes` 由它给出 |
| ch23 | TLS 记录层 / HTTP | **签名级依赖**：MQTT over TLS 时，报文就是 TLS 的 payload      |
| ch24 | MQTT 3.1.1 + OTA  | 本章                                                           |
| ch25 | Wi-Fi blob 边界   | 下一章：链路层换成 Wi-Fi 时，闭源 blob 的边界在哪              |

“独立重写、仅签名级依赖”是这套工程的一条纪律：本章**不 import** ch22/ch23
的任何模块，两者只在“字节进、字节出”的签名上对齐。这样任何一章的返工
都不会拖垮另一章。

### 24.1.2 三个必须自己实现的理由

有人会问：ESP-IDF 已经有 `esp-mqtt`，为什么还要自己写一遍？

这个问题值得正面回答，因为答案不是“重复造轮子”，而是三条具体的事实：

1. **形态 B 没有 IDF 组件系统**。本系列从 ch13 起就是“纯 Zig ELF + 二级
   bootloader”，没有 `idf_component_register`，也没有 FreeRTOS 任务。
   `esp-mqtt` 依赖 `esp_event`、lwIP socket、任务与队列；搬进来的成本比
   重写一套“够用子集”高得多。
2. **协议层的 bug 只有字节级对拍才能钉住**。`esp-mqtt` 的 `mqtt_msg.c`
   有 652 行，其中 200 行是长度计算与缓冲下标的算术。本章的 `mqtt.zig` 是 **693 行**（`wc -l`，含注释与测试辅助）、
   每一行都有对拍用例，比读 652 行别人的算术更容易建立信心。
3. **本章要的不是客户端，是“可判定的边界”**。`esp-mqtt` 的实现里有很多
   为了兼容历史行为而保留的妥协（例如重连时把 SUBSCRIBE 也放进重传队列，
   见 `mqtt_client.c:854` 的注释里那句 “It is kept because it is what the
   client has always done”）。这些妥协在真实产品里是合理的，但在教学工程里
   会让“哪条规则是规范、哪条是工程惯例”变得模糊。

顺带说：本章并没有把 `esp-mqtt` 当黑盒。24.10 与事实来源表里有它的行号，
用来对照“同一件事在成熟实现里是怎么做的”——这是最有价值的参考。

---

## 24.2 MQTT 报文骨架：固定头、剩余长度、可变头

MQTT 3.1.1 的报文结构只有三层，且**所有报文共用**同一套外壳：

```text
 固定头（2..5 字节）
 ┌──────────┬─────────────────────────────┐
 │ byte 0   │ 剩余长度（1..4 字节，变长） │
 └────┬─────┴─────────────────────────────┘
      │
      ├─ 高 4 位：报文类型（1=CONNECT … 14=DISCONNECT）
      └─ 低 4 位：类型相关标志
                  PUBLISH  → DUP(3) QoS(2..1) RETAIN(0)
                  PUBREL / SUBSCRIBE / UNSUBSCRIBE → 恒为 0b0010
                  其余 → 恒为 0

 可变头（按类型不同，可能为 0 字节）
 载荷（按类型不同，可能为 0 字节）
```

### 24.2.1 第 0 个字节：类型 + 标志

类型占高 4 位，所以 `0x10` 是 CONNECT、`0x30` 是 PUBLISH、
`0xC0` 是 PINGREQ、`0xE0` 是 DISCONNECT。类型 0 与 15 是保留值，
收到就必须当协议错误——这条检查在 `mqtt.zig` 的 `typeFromByte()` 里：

```zig
pub fn typeFromByte(b: u8) Error!PacketType {
    const nibble: u4 = @truncate(b >> 4);
    return switch (nibble) {
        0, 15 => error.UnsupportedPacketType,
        else => @enumFromInt(nibble),
    };
}
```

低 4 位不是“自由标志”。只有 PUBLISH 用满三位，另外三种报文的标志被规范
钉死为 `0b0010`（这也是最容易写错的一处：很多人把 PUBREL 的标志位抄成 0）：

```zig
/// PUBREL / SUBSCRIBE / UNSUBSCRIBE 的固定头 flags 必须是 0b0010
/// （MQTT-3.6.1-1 / MQTT-3.8.1-1 / MQTT-3.10.1-1），其余类型必须是 0。
pub const fixed_flags_required: u4 = 0b0010;

pub fn flagsValid(t: PacketType, flags: u4) bool {
    return switch (t) {
        .publish => true, // dup/qos/retain 三个字段占满低 3 位
        .pubrel, .subscribe, .unsubscribe => flags == fixed_flags_required,
        else => flags == 0,
    };
}
```

为什么值得单独一个函数：接收路径上，flags 非法要**拒绝整条报文**，而不是
“忽略非法位继续解析”。3.1.1 的立场是：非法固定头属于协议错误，接收方应当
关闭网络连接。板侧自检的第 ③ 条就是拿 `0x02` 当 CONNACK 的 ack flags 喂进去，
要求它被拒——而不是把 bit1 当成什么新语义。

### 24.2.2 剩余长度：7 位一组，最多 4 字节

剩余长度是 MQTT 里唯一一个变长整数（§2.2.3）。规则：

- 每字节低 7 位有效，最高位是“还有后续”的续位；
- 最多 4 字节，所以上限是 $7 \times 4 = 28$ 位，即 268435455；
- 必须用**最短**形式（0 编成单字节 `0x00`，不是 `0x80 0x00`）。

编码器就这么几行：

```zig
pub fn encodeRemainingLength(out: []u8, value: u32) Error!usize {
    if (value > max_remaining_length) return error.RemainingLengthTooLong;
    var v = value;
    var n: usize = 0;
    while (true) {
        var b: u8 = @intCast(v % 128);
        v /= 128;
        if (v > 0) b |= 0x80;
        if (n >= out.len) return error.BufferTooSmall;
        out[n] = b;
        n += 1;
        if (v == 0) break;
    }
    return n;
}
```

注意 `n >= out.len` 的位置：**先检查容量再写**。板侧只有 512 字节的 `g_wire`，
如果先把 `0x80` 写进第 5 个字节再发现越界，那就是一次静默的缓冲区溢出。

解码器要拒绝的东西比编码器多：

```zig
pub fn decodeRemainingLength(in: []const u8) Error!RemainingLength {
    var value: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (i >= in.len) return error.MalformedPacket;
        const b = in[i];
        value |= @as(u32, b & 0x7F) << @intCast(7 * i);
        if ((b & 0x80) == 0) {
            // 非最短编码：多字节却在高位补 0（末字节 == 0 且前面还有字节）。
            if (i > 0 and b == 0) return error.MalformedPacket;
            return .{ .value = value, .len = @intCast(i + 1) };
        }
    }
    return error.RemainingLengthTooLong;
}
```

四个分支，每一个都对应一类真实故障：

| 输入                   | 结果                     | 为什么必须这样                             |
| ---------------------- | ------------------------ | ------------------------------------------ |
| `80 80 80 80`          | `RemainingLengthTooLong` | 编码者想要第 5 个字节，规范不允许          |
| `80`（只收到一个字节） | `MalformedPacket`        | 不是“非法”，只是“还不完整”，由上层继续等   |
| `80 00`                | `MalformedPacket`        | 非最短编码：同一个值两种字节串会让对拍失效 |
| `FF FF FF 7F`          | 268435455，`len = 4`     | 上限本身必须能编能解                       |

这张表里第二行是一个**必须分成两个函数**的地方，也是本章唯一一处被自查捉住的
真实 bug：

```zig
/// 严格版：`in` 必须已经包含完整的剩余长度字段，否则报 `MalformedPacket`。
pub fn decodeRemainingLength(in: []const u8) Error!RemainingLength {
    return (try decodeRemainingLengthOrNull(in)) orelse error.MalformedPacket;
}

/// 字段还没收全时返回 `null`（继续等）——流式路径必须用这个。
pub fn decodeRemainingLengthOrNull(in: []const u8) Error!?RemainingLength {
    ...
        if (i >= in.len) return null; // 字段还没收全：等，不要判非法
    ...
}
```

一开始 `StreamReader.peek()` 直接调了严格版，于是这样一个切分就翻车了：

```text
TCP 第一段：30        （PUBLISH 的类型字节）
TCP 第二段：80        （剩余长度 = 128，首字节带续位，第二个字节还没来）
```

严格版看到 `0x80` 后面没字节，报 `MalformedPacket`，而**这恰恰是最常见的
切分点**——固定头常常单独成段到达。修法不是“把严格版的报错改成 null”
（那会让真正截断的报文永远等下去），而是拆成两个契约：抓不到完整字段时
`decodeRemainingLengthOrNull` 返回 `null`，只有“字段已完整但内容非法”
（第 5 字节、非最短编码）才报错。板侧第 ⑬ 条把这次修复钉成了判据：

```text
check: mqtt stream pushes=4 total=138 id=772 stalled=3 reassembled=1 ok=1
```

`stalled=3` 就是“三次 peek 都返回 null”的证据：只有类型字节、只有 `0x87`
（长度字段首字节）、长度字段齐但报文体不够。

上限是怎么选出来的，值得算一遍：4 字节 × 7 位 = 28 位，$2^{28} - 1 = 268435455$。
所以“超过上限”只可能来自 5 字节编码——这就是为什么拒绝 5 字节与拒绝超限
在实现上是同一件事，而在报错上是两件事（前者说“你的编码太长”，后者说
“你的数值太大”）。本章统一报 `RemainingLengthTooLong`，注释里写清楚两种来源。

### 24.2.3 字节级 KAT：一条完整的 CONNECT

板侧自检的第 ① 条不测“能不能编”，而测“编出来的 18 个字节对不对”。
参数：`client_id = "ch24"`、`clean_session = true`、`keepalive = 60`。

```text
10                CONNECT(1) << 4 | flags(0)
10                remaining length = 16（单字节）
00 04             "MQTT" 的长度前缀
4D 51 54 54       'M' 'Q' 'T' 'T'
04                协议级别：3.1.1 == 4
02                connect flags：只置 clean session
00 3C             keepalive = 60（大端 16 位）
00 04             "ch24" 的长度前缀
63 68 32 34       'c' 'h' '2' '4'
```

剩余长度 16 是这么来的：可变头 10 字节（2 + 4 + 1 + 1 + 2），载荷 6 字节
（2 + 4）。**这个加法写错是 MQTT 实现里最高频的 bug**——少算 2，broker 会把
client id 的前两个字节当成主题长度，然后断开；多算 2，broker 会等两个永远
不会来的字节，直到超时。

板侧看到的行是（`logs/ch24-boot.log` 原文）：

```text
check: mqtt connect kat len=18 ka=60 bytes=101000044d5154540402 ok=1
read: mqtt connect kat_full=101000044d5154540402003c000463683234
```

`check:` 那行只打前 10 个字节（日志行有 200 字节上限，打全长会挤掉后面的
判据），`read:` 那行把 18 个字节完整打出来，方便和上面那张表逐字对拍。

### 24.2.4 CONNECT 的 flags：三个容易踩的位

connect flags 的 8 个位里，有三个位不是“布尔开关”，而是“条件开关”：

| 位     | 名字          | 陷阱                                           |
| ------ | ------------- | ---------------------------------------------- |
| bit7   | username      | 无陷阱                                         |
| bit6   | password      | 没有 username 时**不得**置位（否则是协议错误） |
| bit5   | will retain   | 没有 will 时置位无意义，但仍需保持为 0         |
| bit4-3 | will QoS      | 没有 will 时必须是 0；有 will 时不得是 3       |
| bit2   | will flag     | 决定后面有没有 will topic/payload 两段字符串   |
| bit1   | clean session | 决定 broker 要不要保留订阅与会话               |
| bit0   | reserved      | **必须为 0**，收到 1 必须当协议错误断开        |

本章的编码器直接拒绝“有 password 没 username”：

```zig
if (opts.password != null and opts.username == null) return error.MalformedPacket;
```

这不是“吹毛求疵”。在真实对接里，这种报文会被 broker 以 `0x04`
（bad user name or password）或 `0x05`（not authorized）拒绝，而设备侧
只会看到“连接失败”，根因却在我们自己编的字节里。与其等对端报一个含糊的
错误，不如在编码阶段就失败。

解码侧同样严格。`decodeConnectHeader()` 只解可变头（不碰 client id/will/凭据），
但它会检查两件事：协议名必须是 `"MQTT"`、保留位必须是 0：

```zig
if ((flags & 0x01) != 0) return error.InvalidFlags; // 保留位必须为 0
```

---

## 24.3 QoS 0/1/2 的真实差异

“QoS 是消息质量等级”这句话没错，但它掩盖了真正的差异：**三种 QoS 是三条
不同的状态机**，代价与语义都不同。

### 24.3.1 一张表看清三条路径

| QoS | 语义     | 报文序列                            | packet id | 额外状态          | 失败模式               |
| --- | -------- | ----------------------------------- | --------- | ----------------- | ---------------------- |
| 0   | 至多一次 | PUBLISH                             | 无        | 无                | 丢就丢了               |
| 1   | 至少一次 | PUBLISH → PUBACK                    | 有        | 1 个在途槽位      | 重复投递（应用要去重） |
| 2   | 恰好一次 | PUBLISH → PUBREC → PUBREL → PUBCOMP | 有        | 2 个阶段 + 接收表 | 状态泄漏（id 不回收）  |

三个关键事实：

1. **QoS0 的 PUBLISH 没有 packet id 字段**。不是“填 0”，是“这个字段不存在”。
   所以 `remaining length` 里少 2 字节，解码时也不能去读那两个字节。
2. **QoS1 的重发是“重复投递”而不是“补发”**。规范只保证“至少一次”，
   所以接收方必须能接受同一条消息来两次。这就是为什么 QoS1 的 PUBLISH
   在重发时要置 DUP=1——它不是给接收方去重用的（接收方无法只靠 DUP 判断），
   而是给日志和排障用的。
3. **QoS2 的“恰好一次”是靠四步握手 + 两边各一张 packet id 表换来的**。
   发送方在 PUBREC 之前保留 PUBLISH，在 PUBCOMP 之前保留 PUBREL；接收方
   在 PUBREL 之前保留“这个 id 已经收过”的记录。

本章的实现把这三条路径都走了一遍，板侧第 ④ ⑤ 条判据分别覆盖 QoS1 与 QoS2。

### 24.3.2 PUBLISH 的固定头与可变头

PUBLISH 是唯一“固定头低 4 位全用满”的报文：

```text
 bit3  DUP      1 = 这是一次重发（仅 QoS>0 有意义）
 bit2-1 QoS     0/1/2，3 非法
 bit0  RETAIN   broker 是否把这条消息保留为“最后一条”
```

编码器对 QoS 的检查有两处，分别对应规范里两条不同的话：

```zig
if (qos > 2) return error.InvalidQos;
// MQTT-2.3.1-2：QoS > 0 的 PUBLISH 必须带非零 packet id；
// QoS 0 必须不带（packet id 字段长度为 0）。
if (qos > 0 and packet_id == 0) return error.InvalidPacketId;
```

解码器还要多拒一种：**QoS 3**。规范（MQTT-3.3.1-4）明确规定 QoS 3 是
协议错误，接收方必须关闭连接。有趣的是，QoS 3 在固定头里是“合法位模式”
（`0b11`），只能靠类型检查拦下来——这就是为什么 `decodePublish()` 里
第一件事是看 `qos == 3`：

```zig
const qos: u2 = @truncate((flags >> 1) & 0x03);
if (qos == 3) return error.InvalidQos; // MQTT-3.3.1-4：QoS 3 是协议错误
```

### 24.3.3 四个 ACK 都是 4 字节

PUBACK / PUBREC / PUBREL / PUBCOMP 的 body 只有一个 packet id，所以整包
恒为 4 字节：1 字节固定头 + 1 字节剩余长度（值 2）+ 2 字节 id。

板侧第 ④ 条打印的 `puback=40020102` 就是：`40`（PUBACK，flags 0）、
`02`（剩余长度 2）、`01 02`（packet id = 258）。第 ⑤ 条打印的
`pubrel=62020001` 是：`62`（PUBREL，flags 0b0010）、`02`、`00 01`。

把它们写成一个函数是刻意的：

```zig
pub fn encodeAck(out: []u8, t: PacketType, packet_id: u16) Error!usize {
    if (packet_id == 0) return error.InvalidPacketId;
    const flags: u4 = switch (t) {
        .puback, .pubrec, .pubcomp => 0,
        .pubrel => fixed_flags_required,
        else => return error.UnsupportedPacketType,
    };
    ...
}
```

`packet_id == 0` 的检查在这里比在 PUBLISH 里更重要：一个 `00 00` 的
PUBACK 会让发送方永远等不到自己发的 id 的确认，从而无限重传——而且
没有任何日志会提示“id 是 0 所以永远匹配不上”。

### 24.3.4 QoS2 的四步与去重

出站方向是“发送方状态机”：

```text
        publish(qos=2)                 onPacket(PUBREC)
   ┌───────────────┐               ┌──────────────────┐
   │ send PUBLISH  │ ────────────→ │ send PUBREL      │ ────────────→  free
   │ stage=wait_pubrec             │ stage=wait_pubcomp                 slot
   └───────────────┘               └──────────────────┘
         ↑ 超时 → 重发 PUBLISH(DUP=1)      ↑ 超时 → 重发 PUBREL（无 DUP 位）
```

注意两处不对称，这是规范里没有明说、但不这么做就会出错的地方：

1. **PUBLISH 的重发要置 DUP=1，PUBREL 的重发不能置**。PUBREL 的固定头
   flags 恒为 `0b0010`，没有 dup 字段；如果你“顺手”把 bit3 也置 1，
   对端会当非法固定头拒绝整包。
2. **两个阶段共用一个 inflight 槽位**。QoS2 的一条消息在 PUBCOMP 之前
   始终占用一个槽位，阶段只是槽位内部的一个字段。

入站方向是“接收方状态机”，核心是那张去重表：

```zig
2 => {
    const dup = self.rxQos2Contains(p.packet_id);
    if (!dup) {
        if (self.rx_qos2_count >= max_slots) return error.BufferTooSmall;
        self.insertRxQos2(p.packet_id);
    } else {
        self.stat_qos2_dups += 1;
    }
    const n = try mqtt.encodeAck(&buf, .pubrec, p.packet_id);
    self.sink.emit(buf[0..n]);
    self.last_tx_ms = now_ms;
    return .{ .packet = p, .duplicate = dup };
},
```

三个细节值得单独说：

- **重复的 PUBLISH 也必须回 PUBREC**。只回一次会让发送方永远等不到确认，
  从而一直重发；回两次不多余——PUBREC 本身是幂等的。
- **`duplicate = true` 的消息仍然要交给调用方，但要标出来**。本章的选择是
  “上抛 + 标记”，因为“丢弃”这个决定应该由应用做（有些消息重复执行是无害的，
  有些不是）。会话层的责任只是“如实报告”。
- **PUBREL 到达时清记录，但重复的 PUBREL 仍回 PUBCOMP**。否则发送方的
  PUBREL 重发会得到一个沉默，然后它继续重发。

板侧第 ⑤ 条把两个方向都走了一遍，输出：

```text
check: mqtt qos2 pubrel=62020001 delivered=1 dup=1 pubcomp=1 ok=1
```

`delivered=1` 是“第一次投递被上抛”，`dup=1` 是“第二次被标记为重复”，
`pubrel=62020001` 是出站方向发出的 PUBREL 字节，`pubcomp=1` 是入站方向
回的 PUBCOMP。

### 24.3.5 为什么 QoS0 也值得实现

有人会说：QoS0 就是“编个 PUBLISH 发出去”，值得单独写吗？

值得。因为 QoS0 是唯一**不占 inflight 槽位**的路径。在一个窗口只有 4 的
设备上，如果 QoS0 也排队，那么 4 条心跳式读数就能把固件下载的窗口占满。
本章的实现明确区分：

```zig
if (qos == 0) {
    const n = try mqtt.encodePublish(&buf, topic, payload, 0, 0, false, false);
    self.sink.emit(buf[0..n]);
    self.last_tx_ms = now_ms;
    return 0;
}
```

返回 0 而不是分配 id，是“这条消息没有身份”的直接表达。板侧第 ⑫ 条在窗口
满的情况下发一条 QoS0，要求它仍然成功（`qos0=1`）——这条判据保护的是一个
很容易在重构中被破坏的性质。

---

## 24.4 主题过滤器与匹配算法

主题是 MQTT 里唯一由**人类**决定语法的地方，也是最容易出安全问题的地方：
一个写错的过滤器，轻则收不到消息，重则把 `$SYS` 的整个 broker 内部状态
订阅下来。

### 24.4.1 三条语法规则

主题是 `/` 分隔的层级串。过滤器里有两个通配符：

| 通配符 | 语义                             | 位置约束                         |
| ------ | -------------------------------- | -------------------------------- |
| `+`    | 匹配**恰好一层**（可以是空层）   | 必须独占整层：`a/+b` 非法        |
| `#`    | 匹配**剩余所有层**（可以是零层） | 必须独占整层**且是最后一个字符** |

“独占整层”这四个字是全部误区的来源。看反例：

| 过滤器       | 合法？ | 原因                      |
| ------------ | ------ | ------------------------- |
| `a/+/c`      | ✓      | `+` 独占中间层            |
| `a/+b`       | ✗      | `+` 与 `b` 挤在一层       |
| `a/#`        | ✓      | `#` 独占最后一层          |
| `a/b#`       | ✗      | `#` 前面不是 `/`          |
| `a/#/b`      | ✗      | `#` 不是最后一个字符      |
| `a//b`       | ✓      | 空层是合法的一层          |
| `#` / `+`    | ✓      | 单独使用合法              |
| `""`（空串） | ✗      | 长度为 0 的过滤器没有意义 |
| `##`         | ✗      | `#` 与 `#` 挤在一层       |

实现的核心是“定位当前层的起点与终点”：

```zig
pub fn validateFilter(filter: []const u8) bool {
    if (filter.len == 0 or filter.len > 0xFFFF) return false;
    for (filter, 0..) |c, i| {
        if (c != '#' and c != '+') continue;

        // 当前层级的起点。
        const level_start = if (std.mem.findScalarLast(u8, filter[0..i], '/')) |p| p + 1 else 0;
        const level_end = std.mem.findScalarPos(u8, filter, i, '/') orelse filter.len;

        // 通配符必须独占本层。
        if (level_start != i or level_end != i + 1) return false;

        // '#' 还必须是整个过滤器的最后一个字符。
        if (c == '#' and level_end != filter.len) return false;
    }
    return true;
}
```

`level_start != i or level_end != i + 1` 这一行同时覆盖了三种错误：
`+b`（终点不对）、`sport+`（起点不对）、`##`（终点不对）。
`#` 的额外检查覆盖 `a/#/b`。

### 24.4.2 匹配：`#` 包含父层，`+` 不吃零层

匹配算法与合法性检查是两件事，很多实现把它们混在一起，然后在这两个用例上翻车：

```text
过滤器 a/#        主题 a        →  命中（# 匹配“零层 + 父层”）
过滤器 a/+        主题 a        →  不命中（+ 至少要吃掉一层）
过滤器 a/+        主题 a/       →  命中（吃掉的那个是空层）
```

第一条尤其反直觉：`#` 不只是“匹配剩下的层”，它还包括**父层本身**。
规范里举的例子就是 `sport/#` 匹配 `sport`。

本章的实现从两个指针同步走层，把“谁先耗尽”单独处理：

```zig
pub fn matches(filter: []const u8, topic: []const u8) bool {
    if (filter.len == 0) return false;
    if (topic.len > 0 and topic[0] == '$' and (filter[0] == '#' or filter[0] == '+')) return false;
    ...
        const f_done = f_end == filter.len;
        const t_done = t_end == topic.len;
        if (f_done and t_done) return true;
        if (f_done) return false;
        if (t_done) {
            // 主题先耗尽：只有剩下的过滤器恰好是 `#` 才算命中（父层规则）。
            return std.mem.eql(u8, filter[f_end + 1 ..], "#");
        }
```

`t_done` 分支就是父层规则的全部实现：主题比过滤器先结束，只有当过滤器
剩下的部分**恰好是 `#`** 时才算命中。`a/#` vs `a` 走这条分支返回 `true`；
`a/+` vs `a` 走这条分支时 `filter[f_end+1..]` 是 `"+"`，`eql` 为假 → `false`。

### 24.4.3 `$SYS` 例外

第三行那个前置检查是 MQTT 4.7.2-1：**以 `$` 开头的主题不被以 `#` 或 `+`
开头的过滤器命中**。

为什么要有这条规则？因为 broker 把内部状态挂在 `$SYS/` 下（连接数、
消息速率、订阅数）。如果 `#` 能匹配它，那么任何客户端订阅 `#` 都会收到
整个 broker 的内部流量——既是隐私问题也是流量问题。

注意规则的精确边界：

| 过滤器     | 主题                 | 结果 | 原因                   |
| ---------- | -------------------- | ---- | ---------------------- |
| `#`        | `$SYS/broker/uptime` | ✗    | 过滤器以通配符开头     |
| `+/broker` | `$SYS/broker`        | ✗    | 同上                   |
| `$SYS/#`   | `$SYS/broker/uptime` | ✓    | 过滤器不是以通配符开头 |

所以这条检查只出现在“过滤器的第一个字符”上，而不是“主题以 `$` 开头就
一律拒绝”。本章的 `matches()` 把两个条件写在一行里，避免后续重构把它
误删：

```zig
if (topic.len > 0 and topic[0] == '$' and (filter[0] == '#' or filter[0] == '+')) return false;
```

板侧第 ⑦ 条把六种情形压缩成一行：

```text
check: mqtt topic a/+/c=1 a/b/d=0 a/#(a)=1 sport/#=1 $SYS=0 invalid=2 ok=1
```

### 24.4.4 订阅时就要拒绝非法过滤器

一个实现细节：非法过滤器应该在**编码 SUBSCRIBE 时**就拒绝，而不是等 broker
用 `0x80`（失败）回你一条 SUBACK。因为 broker 的拒绝信息粒度是“这条过滤器
失败”，而设备的日志往往只有“订阅失败”，定位成本高得多。

于是 `encodeSubscribe()` 在算长度之前先校验：

```zig
for (subs) |s| {
    if (!validateFilter(s.filter)) return error.InvalidTopicFilter;
    if (s.qos > 2) return error.InvalidQos;
    payload_len += 2 + s.filter.len + 1;
}
```

这是“早失败”原则的典型应用：错误离源头越近，修复成本越低。

### 24.4.5 SUBACK 的四种返回码

SUBACK 的载荷是“每条过滤器一个字节”，只有四个合法值：`0x00`/`0x01`/`0x02`
（授予的 QoS）与 `0x80`（失败）。其它值一律当协议错误：

```zig
for (granted) |g| {
    if (g != 0x00 and g != 0x01 and g != 0x02 and g != 0x80) return error.MalformedPacket;
}
```

板侧第 ⑥ 条用 `00 0A 01 80` 喂进去，要求解出 `packet_id=10`、
第一条授予 QoS1、第二条失败：

```text
check: mqtt subscribe filters=2 id=10 granted=1,rej ok=1
```

---

## 24.5 会话：心跳、inflight、背压

报文层是“字节 ↔ 结构”，会话层是“什么时候发、发不出去怎么办”。
这一层完全没有字节算术，全是时间与计数——所以它最容易被“看起来能跑”
掩盖。

### 24.5.1 心跳：两个时间点，不是三个

Keep Alive 的语义只有一句话（§3.1.2.10）：**客户端必须保证两次控制报文之间
的间隔不超过 keepalive**。没别的事要发的时候，就发 PINGREQ。

工程实现通常会再收紧一点：不等满一个 keepalive，而在**一半**的时候就开始
探活。成熟实现（esp-mqtt）就是这么做的：

| 时刻               | 动作                                | 出处                |
| ------------------ | ----------------------------------- | ------------------- |
| 空闲 `keepalive/2` | 发 PINGREQ，置 `wait_for_ping_resp` | `mqtt_client.c:803` |
| 已等 `keepalive`   | 仍未收到 PINGRESP → 判死、断开      | `mqtt_client.c:793` |

于是总预算是 $1.5 \times$ keepalive：半程空闲 + 一个完整等待。
本章的实现与它同构：

```zig
if (self.awaiting_pingresp) {
    // 已经发过 PINGREQ：再等满一个 keepalive 就判死。
    // 总预算是 1.5×keepalive（半程空闲 + 一个完整等待）。
    if (elapsed(now_ms, self.ping_sent_ms) >= keepalive_ms) {
        self.state = .failed;
        self.awaiting_pingresp = false;
    }
    return;
}

if (elapsed(now_ms, self.last_tx_ms) >= keepalive_ms / 2) {
    ...
    self.sink.emit(buf[0..n]);
    self.ping_sent_ms = now_ms;
    self.last_tx_ms = now_ms;
    self.awaiting_pingresp = true;
}
```

两个设计细节：

1. **基准是“最后一次发出控制报文”，不是“最后一次收到”**。规范约束的是
   发送方向；把接收也计入会让“对端一直在发、我们从不发”的会话被误判为健康。
2. **时间比较用无符号回绕减法**。`now -% since` 在 `now` 回绕到 0 之后
   仍然给出正确差值，而 `now >= since + timeout` 会失效。板子跑几个月之后
   毫秒计数一定会回绕，这不是理论问题。

板侧第 ⑧ 条用三个时刻把这条时间轴切了三刀：

```text
check: session keepalive early=0 ping@30000=1 dead@90000=1 ok=1
```

- `tk=29 999`：一条报文都不该发（`early=0` 表示“没有提前发”）；
- `tk=30 000`：必须发出恰好一条 `C0 00`；
- `tk=90 000`：仍无 PINGRESP → 状态转 `failed`，且之后不再发包。

### 24.5.2 重传窗口与保序

3.1.1 §4.4 只说“未确认就重发”，不给具体秒数——这是留给实现的。
本章的默认是 5 秒（`retry_ms = 5_000`），并且有一条硬约束：
**重发必须保持原始顺序**。

```zig
fn retransmitExpired(self: *Session, now_ms: u32) Error!void {
    // 按槽位顺序遍历 == 按 packet id 升序：MQTT-4.6.0-2 要求重发的
    // PUBLISH 保持原始发送顺序，跳着发会让对端先看到 id 大的。
    for (&self.tx) |*slot| {
        ...
```

“按槽位顺序遍历”之所以等于“按 id 升序”，是因为槽位分配总是取第一个空闲位，
而 id 单调递增。这个不变式很脆弱（一次“找最久未发的槽”优化就会破坏它），
所以注释里写明了原因。

重发的两种形态在 24.3.4 讲过，这里补一句代码上的不对称：

```zig
const n = switch (slot.stage) {
    .wait_puback, .wait_pubrec => try mqtt.encodePublish(
        &buf, slot.topic, slot.payload, slot.qos, slot.packet_id,
        true, // DUP=1：MQTT-3.3.1-1
        false,
    ),
    .wait_pubcomp => try mqtt.encodeAck(&buf, .pubrel, slot.packet_id),
};
```

PUBREL 的重发走 `encodeAck`，自然不会带上 DUP 位。

顺带说一个成熟实现里的对照点：esp-mqtt 在重连时会把**所有** `TRANSMITTED`
状态的报文重新入队，包括 SUBSCRIBE；它自己在 `mqtt_client.c:854` 的注释里
承认“MQTT-4.4.0-1 只允许重发未确认的 QoS>0 PUBLISH 与 PUBREL，重排
SUBSCRIBE 不正确，但历史行为如此”。本章的实现严格按规范：只有 PUBLISH
与 PUBREL 会重发。

### 24.5.3 inflight 上限与背压

“背压”在裸机上不是抽象概念：如果窗口无界，那么对端变慢时我们要么丢报文，
要么把报文堆在 RAM 里直到 OOM。本章的选择是**第三个**：

```zig
fn allocSlot(self: *Session) ?*TxSlot {
    if (self.tx_count >= self.cfg.max_inflight) return null;
    ...
}

const slot = self.allocSlot() orelse return error.InflightFull;
```

窗口满时向调用方报错，由调用方决定“停住生产者”还是“丢掉可丢的”。
会话层不做决定，因为只有应用知道哪些消息可以丢。

`windowFull()` 是给调用方做流控用的查询；注意它只统计 QoS>0：

```zig
pub fn windowFull(self: *const Session) bool {
    return self.tx_count >= self.cfg.max_inflight;
}
```

板侧第 ⑫ 条把窗口设成 4，然后：

```text
check: session inflight accepted=4 full=1 fifth=rej qos0=1 freed=1 ok=1
```

五个字段对应五件事：4 条被接受、窗口标记为满、第 5 条被拒、窗口满时 QoS0
仍能发、收到 PUBACK 之后又能发。

### 24.5.4 为什么这一层“无锁”

本工程没有中断、没有第二核、没有抢占（`MIE = 0`，全轮询）。
所有状态只被一次 `onPacket()` 或 `tick()` 调用推进，天然串行。

如果为了“将来可能上 RTOS”先加一把锁，得到的不是安全性，而是两个新问题：
锁的粒度（报文级还是槽位级）和与 tick 的重入顺序。真正需要并发的实现
应该重新设计状态归属，而不是给串行状态机套壳。这一点在 ch14（双核 SMP/IPI）
与 ch12（同步原语）里已经演示过代价。

---

## 24.6 OTA 镜像信任链：清单、SHA-256、Ed25519

现在到了本章的另一半：怎么判断“服务器推来的这堆字节”能不能装。

答案不是“算个校验和”，而是**三层证明**：

| 层     | 问题                 | 手段                       | 失败后果                     |
| ------ | -------------------- | -------------------------- | ---------------------------- |
| 长度   | 收完了吗？           | `image_len` 与实际字节数   | 半包被当作完整镜像 → 变砖    |
| 完整性 | 内容在传输中变了吗？ | SHA-256                    | 传输损坏/位翻转              |
| 来源   | 谁给我下的这个固件？ | Ed25519 签名（覆盖元数据） | 任何能发消息的人都能替换固件 |

三层必须按这个顺序，理由在 24.6.3 讲。

### 24.6.1 清单的 108 字节布局

本章的清单是一个定长结构，故意小到能塞进一条 MQTT 消息：

```text
偏移   长度  字段        说明
0      4     magic       "S31O"（ASCII，便于在 hexdump 里认出来）
4      4     version     u32 LE，单调递增
8      4     image_len   u32 LE，镜像字节数
12     32    sha256      镜像摘要
44     64    signature   Ed25519 签名，覆盖 [0, 44)
--------------------------------------------------------
合计   108 字节
```

三个设计决策值得说：

1. **签名覆盖 [0,44)，不覆盖镜像本身**。签名的是“元数据声明”，
   而镜像内容由 `sha256` 字段间接绑定。这样做的好处是签名运算只处理 44 字节，
   在 rv32 上代价可忽略；代价是校验时必须**先验摘要再验签名**，两步缺一不可。
2. **`magic` 用 ASCII**。十六进制转储里 `5333314f` 一眼就能看出这是清单，
   而随机的 32 位魔数需要查表。
3. **`version` 在签名范围内**。这是防降级的关键：摘要只覆盖镜像内容，
   签名覆盖版本号，所以“把旧但合法的镜像配上一个新版本号”这件事，
   必须同时伪造摘要与签名才能成立。

编码侧只有五行：

```zig
pub fn encodeManifest(out: []u8, m: Manifest) Error!usize {
    if (out.len < manifest_len) return error.BufferTooSmall;
    @memcpy(out[0..4], &manifest_magic);
    writeU32Le(out[4..8], m.version);
    writeU32Le(out[8..12], m.image_len);
    @memcpy(out[12..44], &m.sha256);
    @memcpy(out[44..108], &m.signature);
    return manifest_len;
}
```

小端是刻意选的：rv32 是小端，`readU32Le` 因此可以退化成一次 `@memcpy`
（编译器会这么优化），而不需要字节交换。

### 24.6.2 校验顺序：长度 → 摘要 → 签名

```zig
pub fn verify(bytes: []const u8, image: []const u8) Error!Manifest {
    const m = try decodeManifest(bytes);

    // 1) 长度：清单声明的长度必须与实际收到的字节数一致。
    if (m.image_len != image.len) return error.LengthMismatch;

    // 2) 摘要：防传输损坏 / 半包。
    var digest: [32]u8 = undefined;
    Sha256.hash(image, &digest, .{});
    if (!std.mem.eql(u8, &digest, &m.sha256)) return error.Sha256Mismatch;

    // 3) 签名：证明“这份清单是持私钥的人签的”。
    const pk = Ed25519.PublicKey.fromBytes(trusted_key) catch return error.UntrustedKey;
    const sig = Ed25519.Signature.fromBytes(m.signature);
    sig.verify(bytes[0..signed_len], pk) catch return error.BadSignature;

    return m;
}
```

这个顺序不是随手排的。三条理由：

- **长度最先**：一次整数比较，最便宜；而且半包是最常见的失败（TCP 断流、
  MQTT 丢块），先把它筛掉可以避免对半包算一次 SHA-256。
- **摘要第二**：SHA-256 是 $O(n)$，Ed25519 是 $O(1)$ 但常数极大
  （曲线标量乘）。先做便宜的。
- **签名最后**：它是唯一能证明“来源”的一步，也是最慢的一步。放在最后
  意味着“只有前两关都过了的镜像才值得花这个代价”。

代价到底差多少？在 rv32 @ 40 MHz 上，512 字节的 SHA-256 是微秒级；
一次 Ed25519 验签是**几百毫秒**级。这个比例决定了 OTA 的验签策略：
一次升级只验一次，不能在每个分块上验签。

### 24.6.3 为什么“改版本号”必须被签名拦住

这是本章最值得记住的一个攻击面。假设签名只覆盖镜像摘要：

```text
合法清单：version=7, image_len=512, sha256=X,   sig=S(sha256=X)
攻击者：  version=999, image_len=512, sha256=X,  sig=S   ← 完全合法！
```

设备会认为“第 999 版”，然后装上一个第 7 版的镜像。如果第 7 版有一个
已知漏洞，攻击者就完成了一次“合法降级”。

本章的布局把 `version` 与 `image_len` 都放进签名范围，所以这种改写会让
签名失效。主机测试里有一条专门打这个点：

```zig
// 版本号被改 → 摘要仍然对（摘要只覆盖 image），但签名覆盖了版本号。
var bumped = manifest_buf;
bumped[4] +%= 1;
try testing.expectError(error.BadSignature, ota.verify(&bumped, &image));
```

板侧第 ⑨ 条把三条拒绝路径压成一行：

```text
check: ota manifest v=7 len=512 sha256=110009dc tamper=rej downgrade=rej ok=1
```

`tamper=rej` 是“镜像翻一位 → `Sha256Mismatch`”，`downgrade=rej` 是
“当前 v8，候选 v7 → `Downgrade`”。注意降级检查是**独立**于验签的一步：

```zig
pub fn checkVersion(current: u32, candidate: u32) Error!void {
    if (candidate <= current) return error.Downgrade;
}
```

验签通过只说明“这个 v7 是合法的 v7”，不说明“设备愿意回到 v7”。
两件事分开实现，是因为它们的失败语义完全不同：前者是“有人在攻击你”，
后者是“运维操作被拒绝”。

### 24.6.4 Ed25519：为什么用它，以及它有多贵

选 Ed25519 而不是 RSA 或 ECDSA-P256 的理由：

| 维度     | Ed25519                        | RSA-2048       | ECDSA-P256           |
| -------- | ------------------------------ | -------------- | -------------------- |
| 公钥大小 | 32 B                           | 256 B          | 33/65 B              |
| 签名大小 | 64 B                           | 256 B          | 64 B（DER 72）       |
| 验签速度 | 快（rv32 软件实现 ~百毫秒）    | 慢（大数模幂） | 中                   |
| 实现陷阱 | 少（确定性 nonce，无需随机数） | 多（padding）  | 多（nonce 复用致命） |

最后一行对裸机特别重要：Ed25519 的签名不需要随机数，验签更不需要。
板上没有可信熵源时，任何“签名时需要随机数”的方案都要先解决熵的问题。

本章用 `std.crypto.sign.Ed25519`（`std/crypto.zig:198-199` 的别名）。
验签入口是 `Signature.verify(sig, msg, pk)`（`std/crypto/25519/ed25519.zig:275`），
公钥从 32 字节解出（同文件 `:114`），签名从 64 字节解出（`:254`）。

已知答案用的是 RFC 8032 §7.1 TEST 1 的三件套：种子
`9d61b19d…cae7f60`、公钥 `d75a9801…f707511a`、空消息的签名
`e5564300…8e7a100b`。主机测试要求“种子 → 公钥 → 签名”三个量全部逐字节一致：

```zig
test "Ed25519 fixture key pair reproduces RFC 8032 7.1 TEST 1" {
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(ota.trust_seed);
    const pub_bytes = kp.public_key.toBytes();
    try testing.expectEqualSlices(u8, &ota.trusted_key, &pub_bytes);

    const sig = try kp.sign("", null);
    ...
}
```

板侧第 ⑩ 条验的是**清单签名**（消息不是空的，所以签名前缀与 RFC 的
空消息签名不同，这是正常的）：

```text
check: ota ed25519 key=d75a9801 sig=c95179b0 badsig=rej ok=1
```

`key=d75a9801` 与 RFC 的公钥前缀一致，这是“板上跑的确实是我以为的那把钥匙”
的最便宜证据。`sig=c95179b0` 是本次清单签名的前缀，`badsig=rej` 是
“签名翻一位 → `BadSignature`”。

一个必须说明的边界：**本章不实现安全启动**。安全启动是把公钥烧进 eFuse，
由 bootloader 在**加载镜像时**验签（`esp_image_format.c` 的
`verify_secure_boot_signature`）。本章做的是“应用自己验一份清单”，
两者的信任根不同：

| 方案        | 验证者     | 时机       | 本章覆盖？ |
| ----------- | ---------- | ---------- | ---------- |
| 安全启动 V2 | bootloader | 每次启动   | ✗          |
| 清单验签    | 应用       | 收到镜像时 | ✓          |

真正的设备应该两者都有：安全启动保证“跑起来的代码是授权的”，
清单验签保证“收到的更新是授权的”。只做后者，攻击者仍然可以用
“降级 + 已知漏洞”绕过去（所以还需要 24.6.3 的版本单调性）。

### 24.6.5 与 IDF 的对照：`esp_ota_end` 做了什么

真实 IDF 的 OTA 流程里，校验发生在 `esp_ota_end()`。它内部调用
`ota_verify_partition()`（`esp_ota_ops.c:587`），后者对 app 分区调
`esp_image_verify()`（`esp_ota_ops.c:120` 的 `image_validate()`
也做同一件事），失败就打印 `New image failed verification`（`:647`）
并返回 `ESP_ERR_OTA_VALIDATE_FAILED`。

`esp_image_verify()` 检查的东西本章没有全做（也不需要）：

| IDF 检查项                             | 出处                           | 本章对应            |
| -------------------------------------- | ------------------------------ | ------------------- |
| 镜像头魔数 / 段数 / 校验和             | `esp_image_format.c:360` 起    | `magic` + 长度      |
| 每个 mmap 段的页内偏移同余             | `esp_image_format.c:904`       | ✗（镜像不是我写的） |
| 应用描述结构（256 B，魔数 0xABCD5432） | `esp_app_desc.h:21`            | 注释 + 常量         |
| SHA-256（若启用安全启动）              | `verify_simple_hash` / SBV2    | ✓ SHA-256           |
| 签名（安全启动 V2）                    | `verify_secure_boot_signature` | ✓ Ed25519（应用级） |

也就是说：**本章做的是 IDF 那条链里“应用层可判定”的部分**，而 bootloader
那条链（页内偏移、段布局、安全启动）属于 ch03/ch04/ch09 的地盘。

---

## 24.7 A/B 与回滚状态机

验签通过只回答“这份固件是授权的”，不回答“它能不能在这块板子上跑起来”。
最后这个问题只能靠**跑一次试试**——而“试”失败时必须能退回去。

### 24.7.1 五个状态，与 IDF 一一对应

本章的槽位状态机直接照抄 `esp_ota_img_states_t`
（`esp_flash_partitions.h:67-74`）：

| 状态             | 值   | 含义                               | 谁写的     |
| ---------------- | ---- | ---------------------------------- | ---------- |
| `new`            | 0x00 | 刚写进非活动槽，还没启动过         | OTA 写入方 |
| `pending_verify` | 0x01 | 第一次启动，等待应用自检确认       | bootloader |
| `valid`          | 0x02 | 确认可用，正常启动                 | 应用       |
| `invalid`        | 0x03 | 确认不可用，永不再选               | 应用       |
| `aborted`        | 0x04 | 启动次数超预算，仍未确认，永不再选 | bootloader |
| `undefined_`     | 0xFF | 槽位从未写过                       | —          |

转移图：

```text
     stage()               setBootSlot()            markValid()
 ─────────────→  new  ─────────────────→  pending_verify  ────────────→  valid
                        (bootloader 选它)        │
                                                 │ onBoot() 超预算
                                                 ├──────────────→ aborted ─┐
                                                 │                          ├─→ rollback()
                                                 │ noteFailure() 超预算     │
                                                 └──────────────→ invalid ─┘
```

注意 `invalid` 与 `aborted` 的区别只在**谁判定**：`invalid` 是应用说
“我跑不起来”，`aborted` 是 bootloader 说“它从来没说自己能跑”。
两者的后果相同：永不再选，回滚到另一个槽。

### 24.7.2 连续失败才有资格回滚

这是整个状态机里最容易做错的一处。如果“任何一次失败就回滚”，那么：

```text
一次 WiFi 握手超时 → 回滚
一次传感器读失败   → 回滚
一次 OTA 服务器 503 → 回滚
```

结果是设备永远在 A/B 之间来回跳，而且每次都把“其实能用”的新固件标成
`invalid`。所以本章的计数是**连续**的，并且有一个清零入口：

```zig
pub fn noteFailure(self: *Rollback) void {
    const s = &self.slots[@intFromEnum(self.active)];
    s.failures +|= 1;
    if (s.failures >= self.cfg.max_runtime_failures and s.state == .pending_verify) {
        s.state = .invalid;
        self.rollback();
    }
}

pub fn noteHealthy(self: *Rollback) void {
    self.slots[@intFromEnum(self.active)].failures = 0;
}
```

两个条件都必须有：

- `failures >= max_runtime_failures`：默认 3 次，可配；
- `s.state == .pending_verify`：**只有还没确认的新固件才有资格被回滚**。
  一个已经 `valid` 的固件偶发失败，不应该被标成 `invalid`——那会把
  “运行期故障”和“固件故障”混为一谈。

板侧第 ⑪ 条把这条边界完整走了一遍：

```text
check: ota ab start=a fail3=rollback b=invalid rollbacks=1 ok=1
```

`start=a`：初始 A 槽 valid；`fail3=rollback`：B 槽连续三次失败后回滚；
`b=invalid`：B 被标为 invalid；`rollbacks=1`：回滚计数器为 1。

### 24.7.3 启动预算：另一种回滚

有些固件不是“跑起来之后失败”，而是“根本跑不起来”——启动中途 triple fault
复位，循环往复。这种情况下 `noteFailure()` 永远不会被调用，因为应用没活到
那一步。

所以还需要第三种机制：**启动计数**。bootloader 每次启动处于
`pending_verify` 的槽就 +1，超过预算仍未确认就判 `aborted`：

```zig
.pending_verify => {
    s.boot_attempts +|= 1;
    if (s.boot_attempts > self.cfg.max_boot_attempts) {
        s.state = .aborted;
        self.rollback();
    }
},
```

默认预算是 2：第一次启动（`setBootSlot` 里已计 1）之后允许再启动一次，
再启动还是没确认就回滚。这个数字背后是一个权衡：

- 太小（1）：任何一次“第一次启动需要初始化 flash/校准”的新固件都会被误杀；
- 太大（5+）：真正跑不起来的固件会在复位循环里烧几分钟。

主机测试里有一条专门验证“永不确认”的路径：

```zig
test "A/B: a slot that never confirms is aborted after the boot budget" {
    var ab = ota.Rollback.init(.{ .max_boot_attempts = 2 });
    try ab.stage(.b);
    try ab.setBootSlot(.b);
    ab.onBoot(); // 第二次启动，仍是 pending
    ...
    ab.onBoot(); // 第三次启动 > 预算 → aborted + 回滚
    try testing.expectEqual(ota.Slot.a, ab.active);
```

### 24.7.4 内存模型与真机的差距

本章的 `Rollback` 是内存里的两个结构体。真实的 A/B 需要：

| 真实组件                       | 作用                                        | 本章的替代                |
| ------------------------------ | ------------------------------------------- | ------------------------- |
| `otadata` 分区（2 扇区）       | 存两份 `esp_ota_select_entry_t`（CRC 保护） | 内存里的 `slots[2]`       |
| `ota_seq` 单调序号             | bootloader 用它选“最新有效槽”               | `active` 字段             |
| bootloader 的回滚逻辑          | 读 otadata，决定启动哪个槽                  | `onBoot()` / `rollback()` |
| `esp_ota_set_boot_partition()` | 写 otadata 并校验                           | `setBootSlot()`           |

`esp_ota_select_entry_t` 的字段在 `esp_flash_partitions.h:78-83`：
`ota_seq`、`seq_label[20]`、`ota_state`、`crc`（只保护 `ota_seq`，因为
`ota_state` 会被应用改写而 `ota_seq` 不会）。这种“CRC 只覆盖不变字段”的
设计在掉电场景下很重要，但它属于 ch09 的题目，本章不代实现。

一个诚实的说明：内存模型**无法**验证“掉电时序”。真实 OTA 最脆弱的时刻是
`esp_ota_write` 写到一半掉电——那时分区里是半个镜像，而 otadata 还没更新。
本章的 `stage()` 是原子的，所以这个风险在本章不存在，也就没有被验证。
判据见 24.11。

---

## 24.8 失败计数与看门狗：为什么这两件事必须分开

24.7 的失败计数有个前提：应用得活着，才能计数。

如果固件在某个死循环里，`noteFailure()` 永远不会执行。这时唯一的救援是
看门狗：它把“死循环”变成“一次复位”，然后由 bootloader 的启动预算
（24.7.3）接手。

两者的分工非常清晰，混在一起就会互相破坏：

| 机制         | 观测对象         | 动作              | 计数归属              |
| ------------ | ---------------- | ----------------- | --------------------- |
| 看门狗       | 是否按时喂狗     | 复位              | 不计数（它不记得）    |
| 启动预算     | 启动了几次没确认 | 标 aborted + 回滚 | bootloader（otadata） |
| 连续失败计数 | 业务自检是否通过 | 标 invalid + 回滚 | 应用                  |

为什么不能让看门狗自己决定回滚？因为看门狗只看到“超时”，看不到“为什么”。
一次 OTA 期间的大块 SHA-256 计算可能让主循环 800 ms 没喂狗——如果看门狗
据此回滚，那么每次升级都会回滚。所以本章的纪律是：**看门狗只负责把死循环
变成复位，决策全部交给“有没有连续失败”**。

本章的 `_start` 里那段关 RTC/LP 看门狗的序列（ch15 的成果）在这里有一个
副作用值得说明：裸机工程关掉了 bootloader 留下的 RTC WDT，所以本章**没有**
看门狗兜底。这不是疏忽，而是形态 B 的选择：没有 RTOS、没有任务，一次
自检跑完不到一秒，WDT 只会制造噪音。真要上产品，需要按 ch05 的序列重新
武装 TIMG0 的 WDT，并保证喂狗点在主循环里。

板侧日志里没有 `rst:0x10 CHIP_LP_WDT_RESET`，就是因为 `_start` 第 3 步做了
这件事；如果哪天看到它，说明启动序列被改坏了。

---

## 24.9 工程走读

### 24.9.1 浏览页深链

| 文件                 | 作用                                               | 站内浏览                                                                                                                                                                   |
| -------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build.zig`          | 目标串、链接脚本、`zig build test`                 | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/build.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/build.zig)                   |
| `linker/s31.ld`      | 两段 flash、`.trap_ram`、6 条 ASSERT               | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/linker/s31.ld](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/linker/s31.ld)           |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`                  | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/start.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/start.zig)           |
| `src/main.zig`       | banner → 自检 → verdict → `wfi`                    | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/main.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/main.zig)             |
| `src/selftest.zig`   | 13 条板侧判据                                      | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/selftest.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/selftest.zig)     |
| `src/mqtt.zig`       | 固定头 / 剩余长度 / 各类报文 / 主题匹配 / 流式重组 | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/mqtt.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/mqtt.zig)             |
| `src/session.zig`    | 心跳 / 重传 / 背压 / QoS2 去重 / `FrameRecorder`   | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/session.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/session.zig)       |
| `src/ota.zig`        | 清单 / SHA-256 / Ed25519 / A/B 槽位                | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/ota.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/ota.zig)               |
| `src/host_tests.zig` | 主机侧 27 个用例的根                               | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/host_tests.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/host_tests.zig) |
| `src/hw.zig`         | ROM 忙等 / CSR 读 / `halt()`                       | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/hw.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/hw.zig)                 |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump                      | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/trap.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/trap.zig)             |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`                  | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/log.zig](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/log.zig)               |
| `tools/flash.sh`     | 烧录（替换 `flash_args` 里的应用行）               | [/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/tools/flash.sh](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/tools/flash.sh)         |

[完整工程](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/README.md)

### 24.9.2 模块依赖图

```text
                     ┌──────────────┐
     主机侧测试 ────→ │  host_tests  │
                     └──┬───────────┘
                        │ import
        ┌───────────────┼────────────────┐
        ▼               ▼                ▼
     mqtt.zig       session.zig        ota.zig
        ▲               │                ▲
        └───────────────┘                │
          （session 只依赖 mqtt 的编码）   │
                                         │
   selftest.zig ──→ 三个模块 ────────────┘
        │
        └──→ main.zig ──→ start.zig（板侧）

   log.zig / hw.zig / trap.zig 只被板侧路径引用，
   所以主机测试不会把 CSR 汇编带进 x86_64 编译单元。
```

`ota.zig` **不** import `session.zig`，`session.zig` **不** import `ota.zig`。
这条边界不是洁癖：OTA 的信任链与会话时序没有共享状态，混在一起只会让
“哪个 bug 属于哪一层”变模糊。

### 24.9.3 静态缓冲的账

主栈 16 KiB（`_stack_size = 0x4000`），工作区全在 `.bss`：

| 缓冲         | 大小 | 用途                                                  |
| ------------ | ---- | ----------------------------------------------------- |
| `g_wire`     | 512  | 一条出站报文的编码缓冲                                |
| `g_rx`       | 512  | 入站报文（自造）                                      |
| `g_stream`   | 512  | `StreamReader` 的重组缓冲                             |
| `g_image`    | 512  | OTA 镜像副本（篡改用）                                |
| `g_manifest` | 108  | OTA 清单                                              |
| `g_rec`      | 5164 | `FrameRecorder`：10 帧 × 512 B + 长度表(40) + 计数(4) |

实测镜像（`readelf -SW zig-out/bin/app.elf`）：

```text
[ 1] .flash.text       PROGBITS  40000020  size 017980
[ 2] .flash.rodata     PROGBITS  40020020  size 001c20
[ 5] .trap_ram         PROGBITS  2f000000  size 00006c
[ 7] .bss              NOBITS    2f000070  size 001ca0
```

`.bss = 0x1ca0 = 7328` 字节，与上表逐项相加正好相等（2048 + 108 + 5164 + 8 = 7328）。
为什么必须放 `.bss` 而不是局部变量：Ed25519 验签的 Edwards25519 标量乘
会吃掉几 KiB 栈，再叠 512 字节镜像副本就会踩穿 16 KiB 主栈，表现为
`Store access fault` + 复位，而调用栈被覆盖之后无法归因。

### 24.9.4 与 ch23 的链接脚本差异

两者结构完全相同（irom / drom / sram 三段 + `.trap_ram`），只有一处地址差异：

| 章节 | `.flash.rodata` 起点 | 原因                                                      |
| ---- | -------------------- | --------------------------------------------------------- |
| ch23 | `0x40020040`         | 用了 AES-128-GCM，`std` 的软件查表声明 `align(64)`        |
| ch24 | `0x40020020`         | SHA-256 与 Ed25519 没有 `align(64)` 的查表，节对齐仍是 32 |

这不是“我们控制”的结果，而是 LLVM 输入节对齐的自然结果。
`image-info` 打印的两行是唯一权威：

```text
      0  0x17980  0x40000020  0x00000018  DROM, IROM
      3  0x02df8  0x40020020  0x00020018  DROM, IROM
```

如果哪天把 AES 加回来，DROM 起点会自动变成 `0x…40`，链接脚本里的
`ASSERT(_rodata_start % 32 == 0)` 仍然成立，而 `elf2image` 会插入填充段
保持页内偏移同余（`esp_image_format.c:904`）。

---

## 24.10 上板自检输出

### 24.10.1 banner 与范围声明

```text
ch24-mqtt-ota-application-protocols | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: mqtt 3.1.1 codec + session tick + ota manifest (sha256/ed25519) + a/b rollback
note: no broker, no link, no flash write - ch17 ethernet and ch09 flash pending
host: 27 unit tests via 'zig build test'
```

banner 的第一行是**工程名**，这是共用开发板时唯一可靠的“这段日志是我的”的
证据（另一个工程刚烧过时，串口里会出现它的 banner）。

### 24.10.2 13 条判据（`logs/ch24-boot.log` 原文）

```text
check: mqtt connect kat len=18 ka=60 bytes=101000044d5154540402 ok=1
read: mqtt connect kat_full=101000044d5154540402003c000463683234
check: mqtt rem-len widths=112234 max=1 over=rej five=rej ok=1
check: mqtt connack sp=1 rc=0 refuse=not_authorized reserved=rej ok=1
check: mqtt publish qos1 id=258 payload=on puback=40020102 ok=1
check: mqtt qos2 pubrel=62020001 delivered=1 dup=1 pubcomp=1 ok=1
check: mqtt subscribe filters=2 id=10 granted=1,rej ok=1
check: mqtt topic a/+/c=1 a/b/d=0 a/#(a)=1 sport/#=1 $SYS=0 invalid=2 ok=1
check: session keepalive early=0 ping@30000=1 dead@90000=1 ok=1
check: ota manifest v=7 len=512 sha256=110009dc tamper=rej downgrade=rej ok=1
check: ota ed25519 key=d75a9801 sig=c95179b0 badsig=rej ok=1
check: ota ab start=a fail3=rollback b=invalid rollbacks=1 ok=1
check: session inflight accepted=4 full=1 fifth=rej qos0=1 freed=1 ok=1
check: mqtt stream pushes=4 total=138 id=772 stalled=3 reassembled=1 ok=1
read: ota manifest sha256_prefix=110009dc sig_prefix=c95179b0
checks: passed=13 failed=0 total=13
main: verdict=pass, mqtt/ota primitives verified off-link (wfi)
main: halting (wfi)
```

### 24.10.3 怎么读这些行

| 行                                              | 读法                                                                                       |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `connect kat len=18 …`                          | 18 字节的 CONNECT 与 24.2.3 的表逐字对得上                                                 |
| `rem-len widths=112234`                         | 六个边界值的编码宽度依次是 1/1/2/2/3/4                                                     |
| `connack sp=1 rc=0 refuse=not_authorized`       | 一条接受、一条拒绝（返回码 5），保留位被拒                                                 |
| `publish qos1 id=258 puback=40020102`           | packet id 258 = `0x0102` 往返，PUBACK 四字节                                               |
| `qos2 pubrel=62020001 delivered=1 dup=1`        | 四步走完；重复的 PUBLISH 被标记而没有二次投递                                              |
| `subscribe filters=2 granted=1,rej`             | 两条过滤器，一条授予 QoS1、一条 `0x80` 失败                                                |
| `topic a/+/c=1 a/b/d=0 a/#(a)=1`                | 通配符命中/不命中，`#` 的父层规则                                                          |
| `keepalive early=0 ping@30000=1 dead@90000=1`   | 29 999 不发、30 000 发一条、90 000 判死                                                    |
| `manifest v=7 len=512 tamper=rej downgrade=rej` | 512 字节镜像通过；篡改与降级都被拒                                                         |
| `ed25519 key=d75a9801 badsig=rej`               | 公钥前缀与 RFC 8032 向量一致；错签被拒                                                     |
| `ab start=a fail3=rollback b=invalid`           | 三次连续失败触发回滚，B 槽标 invalid                                                       |
| `inflight accepted=4 full=1 fifth=rej qos0=1`   | 窗口 4；第 5 条被拒；QoS0 不受影响                                                         |
| `stream pushes=4 total=138 stalled=3`           | 一条 138 字节的 PUBLISH 分四次推入；前三次（含“长度字段只到 `0x87`”）都返回 null，最后拼回 |

### 24.10.4 镜像事实

bootloader 的加载行（`logs/ch24-boot.log` 原文）：

```text
I (81) esp_image: segment 0: paddr=00010020 vaddr=40000020 size=17980h ( 96640) map
I (105) esp_image: segment 1: paddr=000279a8 vaddr=2f000000 size=0006ch (   108) load
I (107) esp_image: segment 2: paddr=00027a1c vaddr=00000000 size=085fch ( 34300)
I (116) esp_image: segment 3: paddr=00030020 vaddr=40020020 size=02df8h ( 11768) map
```

- segment 0：`0x40000020`，`map`——IROM，代码与 `esp_app_desc_t`；
- segment 1：`0x2f000000`，`load`——SRAM 里的 `.trap_ram`（108 字节）；
- segment 3：`0x40020020`，`map`——DROM，`.rodata`；
- segment 2：`vaddr=0`，既不是 IROM 也不是 DROM，是 `elf2image` 为了
  页内偏移同余插入的数据段。

`image-info` 里只有两行带 `DROM, IROM`，这正是 bootloader 那条
“恰好两个可映射段”断言需要的形状：

```text
      0  0x17980  0x40000020  0x00000018  DROM, IROM
      3  0x02df8  0x40020020  0x00020018  DROM, IROM
```

---

## 24.11 边界：真实 broker 连接与真实 OTA

### 24.11.1 本章明确没有做的四件事

1. **没有一次真实的 MQTT 连接**。没有 MAC/DMA（ch17 未闭环），没有 TCP
   连接（ch20 是纯状态机），没有 socket（ch22 只有注入路径）。
   会话层发出去的字节全部进了 `FrameRecorder`。
2. **没有真实订阅**。SUBSCRIBE 编得出来、SUBACK 解得出来，但没有 broker
   回你一条 SUBACK。
3. **没有写 flash**。分区表是 `single-app-large`，没有 `otadata`/`ota_0`/`ota_1`。
   A/B 槽位是两个内存结构体。
4. **没有 TLS**。MQTT over TLS 需要把本章的报文塞进 ch23 的记录层，
   这一步没有做。

### 24.11.2 真链路的判据（等 ch17 闭环）

| 判据                           | 怎么跑                                   | 通过标准                                   |
| ------------------------------ | ---------------------------------------- | ------------------------------------------ |
| TCP 能连上 broker 的 1883 端口 | `connect()` 到 `test.mosquitto.org:1883` | 三次握手完成，无 RST                       |
| CONNECT 被接受                 | 发本章编的 18 字节 CONNECT               | 收到 `20 02 00 00`                         |
| SUBSCRIBE 被授予               | 发 `dev/24/#`，QoS1                      | SUBACK 返回 `0x01`                         |
| QoS1 往返                      | 向 `dev/24/echo` 发一条，broker 回显     | 收到同 payload，回 PUBACK                  |
| QoS2 往返                      | 同上，QoS2                               | 四步全部完成，重复 PUBLISH 不二次上抛      |
| 心跳维持                       | 静置 5 分钟不主动发                      | 每 30 s 一条 PINGREQ，每条约 30 s 一条应答 |
| 断线检测                       | 拔掉网线                                 | 90 s 内状态转 `failed`（1.5×keepalive）    |

### 24.11.3 真 OTA 的判据（等 ch09 与 ch17 都闭环）

| 判据                 | 怎么跑                                      | 通过标准                                                        |
| -------------------- | ------------------------------------------- | --------------------------------------------------------------- |
| 分区表就位           | 自定义分区表：`otadata` + `ota_0` + `ota_1` | `esp_partition_find_first` 能找到三者                           |
| 镜像写入非活动槽     | `esp_ota_begin/write/end`                   | `esp_ota_end` 返回 `ESP_OK`                                     |
| 清单验签在写入前完成 | 先 `ota.verify()`，再写                     | 验签失败时一次 flash 写都没发生                                 |
| 切槽启动             | `esp_ota_set_boot_partition()` + 复位       | 启动日志里的 `Loaded app from partition at offset 0x…` 变成新槽 |
| 自检通过 → 确认      | 新固件跑完自检后 `markValid()`              | 下次启动仍是新槽，不计数                                        |
| 坏固件回滚           | 新固件启动后立即 `noteFailure()` 三次       | 再复位回旧槽，日志里出现 invalid 标记                           |
| 掉电安全             | 在 `esp_ota_write` 中途硬复位               | 重新上电后仍启动旧槽（otadata 未更新）                          |

最后一条是本模型**无法**覆盖的，因为它需要真实的擦写时序。

### 24.11.4 为什么现在不做“半个真连接”

有人会提议：先用 USB 串口桥做一个“假 broker”，让板子真的收发一次。
这个方案在技术上可行，但它验证的是**串口桥**，不是**MQTT over TCP**——
TCP 的粘包、重传、窗口为零这些真正会让 MQTT 实现出问题的行为，
串口桥一个都不会产生。

本章的选择是：把“不依赖传输”的部分做到逐字节可对拍，把“依赖传输”的部分
写成上表那样的判据。等 ch17 闭环，这些判据可以直接变成测试用例，
而本章的三个模块一行都不用改——因为它们只依赖 `[]const u8`。

---

## 事实来源

下表的行号都是在本机实际 `grep -n` 得到的（Zig 0.17.1 的 `lib/zig/std`、
本地 `~/esp/esp-idf` v6.1 源码树、以及仓库内 vendored 的 esp-mqtt
`practice/lwip-examples/ex08-mqtt-pubsub/components/mqtt/`）。

| #   | 事实                                                           | 来源（文件:行）                                                                                                                                                 |
| --- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `std.crypto.sign` 里 Ed25519 的别名入口                        | `std/crypto.zig:198-199`（`pub const sign` / `pub const Ed25519`）                                                                                              |
| 2   | Ed25519 验签入口                                               | `std/crypto/25519/ed25519.zig:275`（`Signature.verify`）、`:292`（`verifyStrict`）                                                                              |
| 3   | Ed25519 签名长度 64、公钥长度 32                               | `std/crypto/25519/ed25519.zig:237`（`encoded_length = 64`）、`:109`（公钥 32）                                                                                  |
| 4   | Ed25519 公钥/签名的字节解析                                    | `std/crypto/25519/ed25519.zig:114`（`PublicKey.fromBytes`）、`:254`（`Signature.fromBytes`）                                                                    |
| 5   | 确定性密钥派生（RFC 8032 的种子语义）                          | `std/crypto/25519/ed25519.zig:319`（`KeyPair.generateDeterministic`）、`:375`（`sign`）                                                                         |
| 6   | SHA-256 的类型与常量                                           | `std/crypto/sha2.zig:23`（`pub const Sha256`）、`:93`（`block_length = 64`）、`:94`（`digest_length`）                                                          |
| 7   | SHA-256 的一次性接口                                           | `std/crypto/sha2.zig:108`（`pub fn hash(b, out, options)`）                                                                                                     |
| 8   | 字节查找用 `findScalarPos`（`indexOfScalarPos` 已成别名）      | `std/mem.zig:1305`（`pub const indexOfScalarPos`）、`:1309`（`pub fn findScalarPos`）                                                                           |
| 9   | 固定头最大 5 字节（1 + 4 字节剩余长度）                        | esp-mqtt `lib/mqtt_msg.c:13`（`#define MQTT_MAX_FIXED_HEADER_SIZE 5`）                                                                                          |
| 10  | 剩余长度的编码循环（7 位一组、续位 0x80）                      | esp-mqtt `lib/mqtt_msg.c:72`（`fini_message`）、`:100`（`len_bytes + 1 > 5` 的健全性检查）                                                                      |
| 11  | 剩余长度的解码（最多 4 字节）                                  | esp-mqtt `lib/mqtt_msg.c:120`（`mqtt_get_total_length`）、`:148`（`i < MQTT_MAX_FIXED_HEADER_SIZE`）                                                            |
| 12  | 报文类型编号（CONNECT=1 … PINGRESP=13）                        | esp-mqtt `lib/include/mqtt_msg.h:23`（CONNECT）、`:25`（PUBLISH）、`:31`（SUBACK）、`:35`（PINGRESP）                                                           |
| 13  | 心跳：`keepalive_ms`、半程发 PINGREQ、一个周期无应答即断开     | esp-mqtt `mqtt_client.c:787`（`process_keepalive`）、`:790`、`:793`、`:803`                                                                                     |
| 14  | 重连时重排队报文的规范依据（只允许 QoS>0 PUBLISH 与 PUBREL）   | esp-mqtt `mqtt_client.c:854`（`[MQTT-4.4.0-1]` 注释）                                                                                                           |
| 15  | 重传时置 DUP 的标志                                            | esp-mqtt `mqtt_client.c:1855-1858`（“set duplicate flag for QoS-1 and QoS-2 messages”）                                                                         |
| 16  | PUBREL 的重传路径                                              | esp-mqtt `mqtt_client.c:1892`（`mqtt_resend_pubrel`）、`:2132`（调用点）                                                                                        |
| 17  | Receive Maximum 只对 QoS>0 生效                                | esp-mqtt `mqtt_client.c:2092`（“Receive Maximum applies only to QoS 1 and QoS 2.”）                                                                             |
| 18  | 会话配置项：clean session / keepalive / 重传超时               | esp-mqtt `include/mqtt_client.h:348`、`:349`、`:357`                                                                                                            |
| 19  | OTA 写入三段式接口                                             | IDF `components/app_update/include/esp_ota_ops.h:85`（`esp_ota_begin`）、`:158`（`write`）、`:200`（`end`）                                                     |
| 20  | 切槽与回滚接口                                                 | 同上 `:230`（`esp_ota_set_boot_partition`）、`:358`（`mark_app_valid_cancel_rollback`）、`:382`（`mark_app_invalid_rollback_and_reboot`）                       |
| 21  | 镜像校验调用与失败码                                           | `components/app_update/esp_ota_ops.c:120`（`image_validate` → `esp_image_verify`）、`:587`（`ota_verify_partition`）、`:647`（`New image failed verification`） |
| 22  | 镜像逐段校验入口（页内偏移同余）                               | `components/bootloader_support/src/esp_image_format.c:360`（`esp_image_verify`）、`:904`（`segment_data_offs % mmu_page_size`）                                 |
| 23  | otadata 的状态枚举（NEW/PENDING_VERIFY/VALID/INVALID/ABORTED） | `components/bootloader_support/include/esp_flash_partitions.h:67-74`                                                                                            |
| 24  | otadata 选择结构（`ota_seq` + CRC）                            | `components/bootloader_support/include/esp_flash_partitions.h:78-83`（`esp_ota_select_entry_t`）                                                                |
| 25  | 应用描述结构魔数 0xABCD5432                                    | `components/esp_app_format/include/esp_app_desc.h:21`                                                                                                           |

规范条文（不是本机文件，按条款引用）：

| 规范               | 用到的条款                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| MQTT 3.1.1 (OASIS) | §2.2.3（剩余长度：7 位一组、最多 4 字节、上限 268435455）、§2.3.1（packet id：QoS>0 必须非零、同向唯一）、§3.1.2（connect flags 与保留位）、§3.1.2.10（Keep Alive）、§3.2.2（CONNACK 与返回码）、§3.3.1（PUBLISH 与 QoS 3 非法）、§3.6-3.7（PUBREL/PUBCOMP）、§3.8.1（SUBSCRIBE flags）、§3.8.3（非法过滤器 → 关闭连接）、§3.9.3（SUBACK 返回码）、§4.4（重传范围）、§4.6（保序）、§4.7.1（通配符位置规则）、§4.7.2（匹配与 `$` 主题例外） |
| RFC 8032 (EdDSA)   | §7.1 TEST 1（种子 `9d61b19d…`、公钥 `d75a9801…`、空消息签名 `e5564300…`）、§5.1.7（Verify）                                                                                                                                                                                                                                                                                                                                                |
| FIPS 180-4 (SHA-2) | §6.2.2（SHA-256）、§B.1（`abc` 的 `ba7816bf…0015ad`）                                                                                                                                                                                                                                                                                                                                                                                      |

---

## 自查清单

- [x] `zig build test` 退出 0，`27/27 tests passed`（主机 x86_64 / Zig 0.17.1）
- [x] 每个已知答案都标注了出处：MQTT 3.1.1 §2.2.3 的宽度、FIPS 180-4 的
      `abc` 向量、RFC 8032 §7.1 TEST 1 的种子/公钥/签名三件套
- [x] `zig build -Dtarget=riscv32-freestanding-eabihf
-Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 恰好两条 `DROM, IROM`：`0x40000020`（`len=0x17980`）、
      `0x40020020`（`len=0x02df8`）
- [x] `flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'` 成功
- [x] 串口 banner 首行是 `ch24-mqtt-ota-application-protocols | form B …`
      （确认不是同伴的镜像）
- [x] 13 条 `check:` 全 PASS，`checks: passed=13 failed=0 total=13`
- [x] `main: verdict=pass` 后停在 `wfi`
- [x] 本章引用的每一行 `check:` 都与 `logs/ch24-boot.log` 逐字一致
- [x] 没有任何“连上 broker / 订阅成功 / OTA 升级完成 / 固件已写 flash”的结论
- [x] 未修改任何索引、套件 README 或既有章节工程
- [ ] 真实 broker 连接（待 ch17，判据见 24.11.2）
- [ ] 真实 OTA 写入与切槽启动（待 ch09 + ch17，判据见 24.11.3）
- [ ] OTA 期间掉电安全（需要真实擦写时序，内存模型无法覆盖）

---

## 下一章预告

[[ch25-wifi-blob-boundary|第二十五章：Wi-Fi blob 边界与 ABI 垫片]]：把链路层从“以太网 MAC/PHY”（ch17，仍未闭环）
换成 Wi-Fi 时，我们会撞上一个和前二十四章都不同的问题——

- 以太网驱动是**我们自己写的寄存器序列**（ch17 的 DMA 环、MDIO 读 PHY）；
- Wi-Fi 在 ESP32-S31 上是一坨**闭源 blob**：我们只能通过 IDF 的 `esp_wifi`
  API 与它交互，看不到协议栈内部的帧调度、重传与省电状态机。

于是“边界在哪”就变成了一个必须回答问题：哪些是我们能判定的（API 契约、
事件序列、ABI 对齐、内存归属），哪些是我们只能观测的（RSSI、重传计数、
信道占用）。ch25 会把这些边界画成一张表，并用 stub 适配层 + ABI 断言把
“能判定的部分”钉死——纪律与本章相同：**能离线判定的做深，必须上天的写判据、
不写结论。**

> [!info] 系列导航
>
> 上一章：[[ch23-tls-http|第二十三章：TLS 记录层、密钥派生与 HTTP/1.1]]
>
> **本章：第二十四章：MQTT 3.1.1 与 OTA 应用协议**
>
> 下一章：[[ch25-wifi-blob-boundary|第二十五章：Wi-Fi blob 边界与 ABI 垫片]]
>
> 系列索引：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]
