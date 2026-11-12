---
title: "Zig × ESP32-S31 全栈开发（二十三）：TLS 记录层、密钥派生与 HTTP/1.1"
date: 2026-12-02 18:00:00
description: "把「加密」拆成可判定的零件：TLS 1.3 记录层的 5 字节外壳与 2^14+256 上界、握手消息的 4 字节分帧与跨记录重组、HKDF-Extract/Expand 与 tls13 前缀的 HkdfLabel、X25519 的 RFC 7748 已知答案、AES-128-GCM 的 nonce/AD 绑定与 NIST 向量、X.509 的 DER 子集与自洽验签、HTTP/1.1 的请求行/首部/Content-Length/chunked/keep-alive，以及为什么这些都不需要一块网卡就能钉死。"
tags: [zig, esp32-s31, riscv, tls13, hkdf, x25519, aes-gcm, x509, http, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 上一章：[[ch22-socket-api-event-loop|第二十二章：Socket API 与事件循环]]
>
> **本章：第二十三章：TLS 记录层、密钥派生与 HTTP/1.1**
>
> 下一章：MQTT 与 OTA（规划中，尚无链接）

# Zig × ESP32-S31 全栈开发（二十三）：TLS 记录层、密钥派生与 HTTP/1.1

前两章把「字节怎么从网卡搬到应用」讲完了：ch20 的 TCP 状态机保证字节有序，
ch21 的拥塞控制决定发多快，ch22 的 socket 与事件循环决定谁来等、等到之后
交给谁。

但它们都没有回答一个更朴素的问题：**交给上层的那些字节，到底是什么格式？**

如果只是自己定的协议，随便发明一个头就行。可一旦要跟浏览器、MQTT broker、
OTA 服务器说话，边界就不是我们定的：对面期望的是 TLS 1.3 的记录、X.509 的
证书、HTTP/1.1 的首部。这些东西的每一个字段都在 RFC 里写死了，写错一个
字节就是 `bad_record_mac` 或者 `400 Bad Request`。

本章只做一件事：把这些格式里**不依赖网络就能判定**的部分实现出来，并用
规范给出的已知答案逐条钉死。钉死之后，等 ch17 的链路和 ch22 的循环到位，
剩下的只是“把字节搬过去”。

| 本章实现                 | 对应规范                   | 已知答案来源                     |
| ------------------------ | -------------------------- | -------------------------------- |
| 记录层头/长度/分片       | RFC 8446 §5.1–§5.2         | 结构本身（边界值 16640/16641）   |
| 握手消息分帧与重组       | RFC 8446 §4                | 自造 3004 字节消息               |
| HKDF-Extract / Expand    | RFC 5869 §2.2/§2.3         | RFC 5869 附录 A.1                |
| HkdfLabel / Expand-Label | RFC 8446 §7.1              | 手工拼字节对拍 + `std` 实现      |
| X25519                   | RFC 7748 §6.1              | 两组标量乘向量                   |
| AES-128-GCM              | RFC 5116 / NIST SP 800-38D | Test Case 1/2                    |
| X.509 DER 子集           | RFC 5280 §4.1              | 自签 fixture（OpenSSL 交叉验证） |
| HTTP/1.1 请求/响应       | RFC 9112 §6.1/§7.1/§9.3    | 结构 + 走私防线                  |

> [!warning] 本章的证据边界（重要）
>
> ch17 的以太网驱动**仍未闭环**（DMA 软复位超时、MDIO 扫不到 PHY、TX 超时，
> 见 `practice/zig-esp32-s31/logs/ch17d-boot.log`）；ch22 的 socket 与事件循环
> 也还没有落地。因此本章**不可能、也不允许**给出下面任何一条结论：
>
> - ✗「板子完成了一次 TLS 1.3 握手」
> - ✗「HTTPS GET 成功」
> - ✗「浏览器访问了板端页面」
> - ✗「与某个服务器协商出了 AES-128-GCM」
>
> 本章的全部证据只有两种来源：
>
> 1. **主机侧单测**（`zig build test`，32 个用例）：已知答案来自 RFC 5869 A.1、
>    RFC 7748 §6.1、NIST SP 800-38D；HkdfLabel 的结构用手工拼的字节对拍；
> 2. **板侧自检**（`practice/zig-esp32-s31/logs/ch23-boot.log`）：
>    `checks: passed=13 failed=0 total=13` 与 `main: verdict=pass`。
>    板子跑的是**同一份模块**，所以它证明的是“这些代码在 rv32 + 真实 SRAM
>    布局下算出来的字节与 x86_64 一致”，不是“链路通了”。
>
> 真实握手与真实 GET 的判据写在 23.11，要等 ch17 + ch22 都闭环之后才成立。
> 把“能算出正确的 PRK”写成“握手成功”，是这类章节最常见的过度承诺。

---

## 23.1 为什么把 TLS 和 HTTP 放在一章

先设想只做 TLS、不做 HTTP 的情形。你会得到这样一个结论：「记录层能分片，
密钥派生有已知答案，AEAD 能加解密」。它全部正确，却**没有被使用**。

因为 TLS 本身不产生任何可观测量。它是管道：里面流的东西（HTTP、MQTT、
WebSocket）才有语义。管道做对了没有，只有把东西从管道里放进去再拿出来
才能验证——而这一步恰好不需要网络：

```text
         ┌─────────────┐   明文（HTTP 请求）    ┌──────────────┐
  上层 → │  HTTP 解析  │ ─────────────────────→ │  记录层封装  │
         └─────────────┘                        └──────┬───────┘
                                                      │ TLSInnerPlaintext
                                                      │ = content || type || 0…
                                                      ▼
                                               ┌──────────────┐
                                               │  AEAD 加封   │  ← key/iv/seq
                                               └──────┬───────┘
                                                      │ TLSCiphertext
                                                      ▼
                     记录头(5B) + 密文 + tag      （交给 ch20 的字节流）
```

图上每一个节点都可以单独判：

| 节点       | 判据（本章的 check 编号）                       |
| ---------- | ----------------------------------------------- |
| 记录层封装 | ① 分片/重组、② 长度上界                         |
| 密钥派生   | ③ HKDF-Extract、④ HKDF-Expand-Label             |
| ECDHE      | ⑤ X25519 向量                                   |
| AEAD       | ⑥ GCM 向量与篡改拒绝                            |
| 身份       | ⑦ DER 解析、⑧ 验签                              |
| 上层语义   | ⑨ 请求解析、⑩ chunked、⑪ keep-alive、⑫ 响应构造 |

这张表就是本章的目录。它同时解释了为什么两件事要放在一章：**HTTP 是 TLS
的可用性证明**。没有 HTTP，TLS 只能证明“我算得对”；有了 HTTP，才能说
“这条管道能承载一个真实协议的最小形状”。

顺带说一个反直觉的取舍：本章**不做完整握手**。原因不是懒，而是握手是唯一
必须联网、必须有时序、必须有对端的部分——它恰好是本章证据纪律最薄弱的地方。
把“能测的”做深，把“必须联网才能测的”明确留到下一章，比做一个跑不起来的
半成品握手强。

### 23.1.1 本章在系列里的位置

| 章节 | 交付                  | 与本章的关系                                            |
| ---- | --------------------- | ------------------------------------------------------- |
| ch16 | 零拷贝发送栈          | 无关（本章不碰 pbuf）                                   |
| ch20 | TCP 状态机            | 本章的字节流最终由它承载，但本章不调用                  |
| ch21 | 拥塞控制              | 无关（决定发多快，不决定发什么）                        |
| ch22 | socket 与事件循环     | **签名级依赖**：`parseRequest(data)` 的 `data` 由它给出 |
| ch23 | 本章                  | 记录层/密钥派生/AEAD/DER/HTTP 解析                      |
| ch24 | MQTT 与 OTA（规划中） | 会复用本章的记录分片与响应构造                          |

注意“签名级依赖”的含义：本章**不 import** ch22 的任何文件，也不假设它的事件
循环存在。ch22 与 ch20 的 TCP 各自独立重写了一份，本章也独立重写自己的
字节解析；两层之间只约定函数签名（谁读、读多少、返回什么），不约定实现。

---

## 23.2 TLS 1.3 记录层：外层壳子与内层握手

### 23.2.1 5 个字节的外壳

TLS 1.3 的记录（`TLSPlaintext` / `TLSCiphertext`）共用同一个 5 字节头：

```text
struct {
    ContentType opaque_type = application_data;  /* 23 */
    ProtocolVersion legacy_record_version = 0x0303;
    uint16 length;
    opaque fragment[length];
} TLSPlaintext;
```

三个字段各有陷阱：

1. `opaque_type`：加密之后**恒为 23**（`application_data`），真实的
   `content_type` 被搬进内层 `TLSInnerPlaintext`。这是 TLS 1.3 与 1.2 最大的
   外观差异——中间设备看到的全是 23。
2. `legacy_record_version`：TLS 1.3 把它钉成 `0x0303`（§5.1）。但第一条
   ClientHello 常带 `0x0301`，所以解析侧必须放宽到 `0x0301..0x0304`。
3. `length`：明文上限 $2^{14} = 16384$；密文允许 AEAD 膨胀 256 字节，
   所以记录长度的硬上限是

$$
L_{\max} = 2^{14} + 256 = 16640
$$

本章把这三条写成了常量与一个显式校验：

```zig
pub const max_plaintext = 1 << 14;
pub const max_expansion = 256;
pub const max_record_length = max_plaintext + max_expansion; // 16640
pub const legacy_record_version: u16 = 0x0303;

pub fn readHeader(in: []const u8) Error!RecordHeader {
    if (in.len < header_len) return Error.Truncated;
    const ct = try contentTypeFromByte(in[0]);
    const version = (@as(u16, in[1]) << 8) | in[2];
    if (version < 0x0301 or version > 0x0304) return Error.BadVersion;
    const length = (@as(u16, in[3]) << 8) | in[4];
    if (length > max_record_length) return Error.RecordTooLarge;
    if (length == 0) return Error.EmptyFragment;
    return .{ .content_type = ct, .legacy_version = version, .length = length };
}
```

为什么 `length == 0` 也算错？RFC 8446 §5.1 明确写了 `length` 不得为 0。
把它当错的价值在于：一条空记录会让“分片器”和“重组器”同时停在原地，
排查时最难定位，不如在入口直接拒。

### 23.2.2 分片：一条消息切成几条记录

分片策略在 RFC 里是自由的：实现可以按 1 字节切，也可以按 $2^{14}$ 切。
本章只关心一件事：**切出来的东西能原样拼回去**。于是接口做成一个迭代器：

```zig
pub const Splitter = struct {
    payload: []const u8,
    frag_max: usize,
    pos: usize = 0,

    pub fn next(self: *Splitter) ?[]const u8 {
        if (self.pos >= self.payload.len) return null;
        const end = @min(self.pos + self.frag_max, self.payload.len);
        const out = self.payload[self.pos..end];
        self.pos = end;
        return out;
    }
};
```

它不改数据、不分配，返回的都是输入切片的子区间。板侧把每条 fragment 前面
补一个 5 字节头写进 `g_wire`（`.bss` 里的 3300 字节静态缓冲），就得到一段
“看起来像真记录流”的字节。

自检 ① 为了让余数可见，特意选了非整除的尺寸：

```text
消息 = 4 字节握手头 + 3000 字节 body = 3004
分片 = 1024 + 1024 + 956
```

`956 = 3004 - 2048`，日志里出现的正是 `lens=1024,1024,956`。

### 23.2.3 内芯：握手消息的 4 字节分帧

记录层的 fragment 里装的是握手消息。握手消息自己的头是 4 字节：

```text
struct {
    HandshakeType msg_type;    /* 1 字节 */
    uint24 length;             /* 3 字节，大端 */
    select (Handshake.msg_type) { ... };
} Handshake;
```

两个细节必须自己处理：

- **长度是 3 字节**，不是 4 字节。`length` 的上限是 $2^{24}-1$；
- **跨记录**：一条 3000 字节的 ClientHello 会被切成 3 条记录；
  **一条记录里也可能塞多条完整消息**（服务端常把 ServerHello 和
  EncryptedExtensions 分开，但规范允许合并）。

于是读侧不能“一条记录 = 一条消息”，必须有重组缓冲：

```zig
pub const MessageReader = struct {
    buf: []u8,
    len: usize = 0,

    pub fn push(self: *MessageReader, ct: ContentType, fragment: []const u8) Error!?[]const u8 {
        if (ct != .handshake) return Error.NotHandshake;
        if (fragment.len > self.buf.len - self.len) return Error.NoSpace;
        @memcpy(self.buf[self.len..][0..fragment.len], fragment);
        self.len += fragment.len;
        return self.take();
    }

    pub fn take(self: *MessageReader) Error!?[]const u8 {
        if (self.len < handshake_header_len) return null;
        const msg_len = try handshakeLength(self.buf[0..handshake_header_len]);
        if (msg_len > self.buf.len - handshake_header_len) return Error.BadHandshakeLength;
        const total = handshake_header_len + msg_len;
        if (self.len < total) return null;
        const msg = self.buf[0..total];
        const rest = self.len - total;
        if (rest > 0) std.mem.copyForwards(u8, self.buf[0..rest], self.buf[total..self.len]);
        self.len = rest;
        return msg;
    }
};
```

`take()` 交出的 `msg` 指向**内部缓冲**。这是刻意的：板侧没有分配器，
调用方必须在下一次 `push()` 之前把它用掉（拷走或解析完）。这个约束在
主机测试里由 `expectEqualSlices` 显式验证——测试拿到的切片在后续 push 之后
确实会变，所以测试必须在同一个语句里比对。

### 23.2.4 自检 ① 与 ② 的判据

自检 ① 的完整链条是：造 3004 字节消息 → 切成 3 条记录写进 `g_wire` →
用 `countRecords()` 复核「记录条数与每条长度自洽」→ 再逐条 `splitOne()` +
`push()` 重组 → 与原始 `g_msg` 逐字节比较。

日志里这一行：

```text
check: record frag records=3 lens=1024,1024,956 reasm=1 ok=1
```

四个数分别是：记录条数、前两条分片长度、余数、重组是否与原文相同。
`ok=1` 意味着四个条件同时成立，少一个就是 0。

自检 ② 判长度上界，三分支一起判：

| 分支                      | 期望             | 说明                           |
| ------------------------- | ---------------- | ------------------------------ |
| `writeHeader(16640)`      | 成功             | 恰好等于上限                   |
| `writeHeader(16641)`      | `RecordTooLarge` | 超一字节就拒                   |
| 原始字节 `17 03 03 41 01` | `RecordTooLarge` | `0x4101 = 16641`，模拟对端伪造 |

```text
check: record limit max=16640 exact=1 over=0 raw=0 ok=1
```

`raw=0` 表示“原始头里声明 16641 的那条被拒了”（0 = 没有被接受）。

### 23.2.5 长度上限为什么值得专门一条判据

在真实链路上，超过上限的记录通常表现为“对端直接断连”，看不出原因。
更糟的是：如果你的解析器把它当作“合法长度”去读，就会读越界——在板子上
是 `Store access fault`（`rst:0x1a` 前的那类 trap），在主机上是段错误。
把它放在解析入口，是把“不可归因的崩溃”换成“可归因的错误值”。

---

## 23.3 密钥派生：HKDF 与 `tls13 ` 前缀

### 23.3.1 HKDF 的两个半步

TLS 1.3 的所有密钥都从 HKDF 来。HKDF 是两步，两步都值得单独记住：

**第一步，Extract**（§2.2）：把任意长的输入压成一个固定长的伪随机密钥

$$
\text{PRK} = \text{HMAC}(\text{salt},\ \text{IKM})
$$

**第二步，Expand**（§2.3）：从 PRK 拉出任意长的输出

$$
T_1 = \text{HMAC}(\text{PRK},\ \text{info} \,\|\, 0x01),\quad
T_n = \text{HMAC}(\text{PRK},\ T_{n-1} \,\|\, \text{info} \,\|\, n)
$$

$$
\text{OKM} = T_1 \,\|\, T_2 \,\|\, \cdots \ \text{截断到 } L
$$

本章直接调用 `std.crypto.kdf.hkdf.HkdfSha256`：

```zig
pub fn extract(salt: []const u8, ikm: []const u8) [hash_length]u8 {
    return Hkdf.extract(salt, ikm);
}

pub fn expand(out: []u8, prk: [hash_length]u8, info: []const u8) void {
    Hkdf.expand(out, info, prk);
}
```

注意 `std` 的 `expand` 参数顺序是 `(out, ctx, prk)`——`ctx` 就是 §2.3 的
`info`。写成上面这两个包装函数的唯一理由是让调用点读起来像 RFC，而不是
为了抽象。

### 23.3.2 RFC 5869 A.1 的已知答案

RFC 5869 附录 A.1 给了 SHA-256 的一组完整向量：

| 字段 | 值                                                                                           |
| ---- | -------------------------------------------------------------------------------------------- |
| IKM  | `0x0b` × 22                                                                                  |
| salt | `00 01 02 03 04 05 06 07 08 09 0a 0b 0c`（13 字节）                                          |
| info | `f0 f1 f2 f3 f4 f5 f6 f7 f8 f9`（10 字节）                                                   |
| L    | 42                                                                                           |
| PRK  | `077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5`                           |
| OKM  | `3cb25f25faacd57a90434f64d0362f2a` `2d2d0a90cf1a5a4c5db02d56ecc4c5bf` `34007208d5b887185865` |

这组向量在主机侧被拆成两个独立用例（`extract` 与 `expand`），在板侧被并成
一条判据 ③：

```text
check: hkdf-extract rfc5869 prk=07770936 ok=1
```

日志里只打前 4 个字节，是为了让格式行不超过 200 字节（`log.line` 的上限），
但比较的是完整的 32 字节：`std.mem.eql(u8, &prk, &ks.rfc5869_prk)`。

为什么拆成两个用例？因为 Extract 错和 Expand 错是两类错误：

- Extract 错 → 所有密钥全错，表现为“握手第一条加密记录就解不开”；
- Expand 错（例如把 `info` 拼错一个字节）→ PRK 对、traffic secret 错，
  表现为“ServerHello 之后全部失配”，更难查。

分开测，错误就能落到具体一半。

### 23.3.3 `HkdfLabel`：最容易被写错的结构

TLS 1.3 不用裸 HKDF，而是带标签的变体（§7.1）：

```text
struct {
    uint16 length = Length;                    /* 期望输出长度 */
    opaque label<7..255> = "tls13 " + Label;   /* 6 字节前缀 + 名字 */
    opaque context<0..255> = Context;          /* 通常是转录哈希 */
} HkdfLabel;

HKDF-Expand-Label(Secret, Label, Context, Length) =
    HKDF-Expand(Secret, HkdfLabel, Length)
```

三个陷阱，按被踩到的频率排序：

1. **`label` 字段的第 1 个字节是「整个 label 的长度」**，不是用户给的那段
   文字的长度。`key` 的实际长度字节是 `6 + 3 = 9`，因为前面还有 `"tls13 "`。
2. **前缀是 `"tls13 "`，带尾随空格**，共 6 字节。少一个空格就是另一套密钥；
   多一个 `\0` 也一样。
3. **`length` 字段是 2 字节大端**，而且它参与 `info`——如果你忘了把期望
   长度写进去，Expand 的输出长度虽然对，但字节全错。

本章把结构单独暴露成 `encodeInfo`，就是为了让它能被逐字节检查：

```zig
pub fn encodeInfo(
    buf: []u8,
    out_len: u16,
    label: []const u8,
    context: []const u8,
) Error![]u8 {
    ...
    buf[0] = @intCast(out_len >> 8);
    buf[1] = @intCast(out_len & 0xFF);
    buf[2] = @intCast(label_len);              // 6 + label.len
    @memcpy(buf[3..][0..label_prefix.len], label_prefix);   // "tls13 "
    ...
    buf[w] = @intCast(context.len);
    ...
}

pub fn expandLabel(
    out: []u8,
    secret: [hash_length]u8,
    label: []const u8,
    context: []const u8,
) Error!void {
    var info_buf: [max_info]u8 = undefined;
    const info = try encodeInfo(&info_buf, @intCast(out.len), label, context);
    expand(out, secret, info);
}
```

`std.crypto.tls.zig` 里有一份等价实现（`:558 hkdfExpandLabel`，`:567` 就是
`const tls13 = "tls13 ";`），结构完全一致：
`length(2) || label_len(1) || "tls13 " || label || ctx_len(1) || ctx`。
本章不复用它，因为本章要能在 rv32 freestanding 下手工控制每一个字节、
并且把结构单独暴露给自检。

### 23.3.4 自检 ④：两条独立判据合一

自检 ④ 做了三件事，全部成立才算过：

1. `encodeInfo(32, "key", {01,02})` 的输出与**手工拼的 15 字节**逐字节相同：

```text
00 20 09 't' 'l' 's' '1' '3' ' ' 'k' 'e' 'y' 02 01 02
└len┘ └l┘ └──────── label ────────┘ └c┘└ctx┘
```

2. `expandLabel(secret, "key", {01,02})` 的输出与「直接拿手工 info 调
   `Hkdf.expand`」的输出相同——这排除了“编码对了但用错了 info”的可能。
3. 换 label（`"iv"`）必须给出**不同**输出——排除“忘了把 label 放进 info”。

日志：

```text
check: hkdf-expand-label label_len=9 info_len=15 out=8a5be387 manual=1 ok=1
```

`out=8a5be387` 是 `HKDF-Expand-Label(PRK_RFC5869, "key", {01,02}, 32)` 的
前 4 字节。它不是 RFC 里的常数，而是“用 RFC 5869 A.1 的 PRK 当输入、
按 RFC 8446 §7.1 结构派生”的可复现值——换实现就会变，所以对拍有效。

### 23.3.5 完整链条：从共享秘密到 traffic secret

RFC 8446 §7.1 的图在这个规模上可以整段实现（不需要握手状态机）：

```text
             0
             │
             ▼
   early_secret = HKDF-Extract(0, 0)
             │
             ▼
   derived = Derive-Secret(early_secret, "derived", "")
             │
   ECDHE ────┤
             ▼
   handshake_secret = HKDF-Extract(derived, ECDHE)
             │
      ┌──────┴──────┐
      ▼             ▼
 "c hs traffic"  "s hs traffic"      ← Derive-Secret(…, transcript)
      │
      ▼  derived = Derive-Secret(handshake_secret, "derived", "")
   master_secret = HKDF-Extract(derived, 0)
             │
      ┌──────┴──────┐
      ▼             ▼
 "c ap traffic"  "s ap traffic"
```

本章的 `buildSchedule` 就是这张图的直译：

```zig
pub fn buildSchedule(
    shared_secret: []const u8,
    hs_transcript: []const u8,
    ap_transcript: []const u8,
) Error!Schedule {
    const zeros: [hash_length]u8 = @splat(0);
    const empty: []const u8 = "";

    const early = extract(empty, &zeros);
    const derived_early = try deriveSecret(early, "derived", empty);
    const handshake = extract(&derived_early, shared_secret);
    const c_hs = try deriveSecret(handshake, "c hs traffic", hs_transcript);
    const s_hs = try deriveSecret(handshake, "s hs traffic", hs_transcript);
    const derived_hs = try deriveSecret(handshake, "derived", empty);
    const master = extract(&derived_hs, &zeros);
    const c_ap = try deriveSecret(master, "c ap traffic", ap_transcript);
    const s_ap = try deriveSecret(master, "s ap traffic", ap_transcript);
    ...
}
```

板侧用固定输入跑一遍这条链，把前 4 字节打成 `read:` 行：

```text
read: traffic c_ap=ef97e3ec s_ap=b7c74e70 master=11c9962e
```

这行**不是判据**（它没有 `ok=`），作用是让日志能被人对拍：同一份代码在
x86_64 与 rv32 上必须给出同样的 4 个字节。主机测试用整段 32 字节来判：
同输入两次调用必须相等、换共享秘密必须不等、`c_ap ≠ s_ap`。

### 23.3.6 真正的 KAT：RFC 8448 §3 的 handshake 链

RFC 5869 的向量只钉住 HKDF 本身；要钉住「标签 + 长度字节 + 转录哈希」这三样
拼起来的**形状**，最合适的材料是 RFC 8448 §3（Simple 1-RTT Handshake）：
它把一次真实握手的每个中间值都列了出来。本章直接当向量用：

| 中间值                                          | RFC 8448 §3 的值（前 4 字节用于日志） |
| ----------------------------------------------- | ------------------------------------- |
| ECDHE 共享秘密（IKM）                           | `8bd4054f…f89492d`                    |
| `early_secret` = Extract(0, 0)                  | `33ad0a1c…f170f92a`                   |
| `derived` = Derive-Secret(early, "derived", "") | `6f2615a1…6c3611ba`                   |
| `handshake_secret` = Extract(derived, IKM)      | `1dc826e9…043fbeac`                   |
| 转录哈希（CH…SH）                               | `860c06ed…f0e1cad8`                   |
| `c hs traffic`                                  | `b3eddb12…27a55a21`                   |
| `s hs traffic`                                  | `b67b7d69…d391ad38`                   |

`rfc8448Chain()` 只做四步：两次 Extract、两次 Expand-Label（context 直接用
RFC 给的转录哈希，绕开“消息序列化是否正确”这个变量），然后五项逐字节比对：

```zig
pub fn rfc8448Chain() Error!Rfc8448Chain {
    const zeros: [hash_length]u8 = @splat(0);
    const early = extract("", &zeros);
    const derived = try deriveSecret(early, "derived", "");
    const handshake = extract(&derived, &rfc8448.shared);

    var c_hs: [hash_length]u8 = undefined;
    var s_hs: [hash_length]u8 = undefined;
    try expandLabel(&c_hs, handshake, "c hs traffic", &rfc8448.hs_transcript_hash);
    try expandLabel(&s_hs, handshake, "s hs traffic", &rfc8448.hs_transcript_hash);
    ...
}
```

板侧把这条链做成判据 ⑬：

```text
check: rfc8448 chain early=33ad0a1c hs=1dc826e9 c_hs=b3eddb12 ok_all=1 ok=1
```

`ok_all=1` 表示五项同时匹配。这组值如果对不上，最可能的原因是三选一：

1. `label` 长度字节写成了「用户文字长度」而不是「6 + 文字长度」；
2. 前缀不是 `"tls13 "`（少空格、多空格、用了 `tls13` 无空格）；
3. `derived` 那一步的 context 传了空字节串而不是 `hash("")`
   （后者是 `e3b0c442…b855`，两者长度不同，输出完全不同）。

三条都在本章的代码里有显式形状，所以这条判据失败时能直接指认。

### 23.3.7 为什么 `master_secret` 也要保留

可以不保留——只要 `c ap`/`s ap` 就够了。但保留它有一个排查上的价值：
`master_secret` 是 handshake 与 application 两段之间的“接缝”。当
`c hs traffic` 正确而 `c ap traffic` 错误时，问题只可能出在
`Derive-Secret(handshake, "derived", "")` 或 `Extract(derived, 0)` 上；
把 `master` 打出来就能把范围缩到两行代码。

---

## 23.4 ECDHE：X25519 的已知答案

### 23.4.1 为什么选 X25519

TLS 1.3 允许 P-256、X25519、X448 等。本章选 X25519 的理由不是“更安全”，
而是**它的规范给了可以直接抄进代码的向量**：RFC 7748 §6.1 的两组
「标量 × u 坐标 → u 坐标」是纯函数，没有消息、没有随机数、没有对端。

而在板子上，真正的价值是：X25519 的 64 位 limb 乘法在 rv32 上必须用
“32 位 × 32 位 → 64 位”的软乘法拼出来，一旦进位写错，结果会**整体正确但
某一位错**——这种 bug 用“握手失败”是查不出来的，用已知答案一眼就能看出。

### 23.4.2 两组向量

| #   | 标量                | u 坐标              | 输出                |
| --- | ------------------- | ------------------- | ------------------- |
| 1   | `a546e36b…ba449ac4` | `e6db6867…d0ab1c4c` | `c3da5537…77a28552` |
| 2   | `4b66e9d4…7918ba0d` | `e5210f12…c715a493` | `95cbde94…7aac7957` |

完整值在 `src/x25519.zig` 里是 32 字节数组常量，板侧直接内联比较：

```zig
pub fn scalarmult(secret: [scalar_length]u8, peer: [key_length]u8) Error![key_length]u8 {
    const shared = Dh.scalarmult(secret, peer) catch return Error.LowOrderPoint;
    if (std.mem.allEqual(u8, &shared, 0)) return Error.ZeroShared;
    return shared;
}
```

日志：

```text
check: x25519 rfc7748 v1=c3da5537 v2=95cbde94 loworder=rejected ok=1
```

`loworder=rejected` 对应一条很容易漏的规则：RFC 8446 §7.4.2 要求，
如果 ECDHE 的共享秘密全零，必须**中止握手**。`std` 的实现会在输出全零时
返回 `error.IdentityElement`，本章把它翻译成自己的 `Error.LowOrderPoint`，
并在 `scalarmult` 里再兜一次零检查——两次检查不是冗余：一次防“曲线层
判定”，一次防“上层换实现后判定丢失”。

### 23.4.3 共享秘密的形状：TLS 1.3 与 TLS 1.2 恰好相反

这是一处非常容易写反的规则，值得单独记。

X25519 的输出是 32 字节（按 RFC 7748 的约定是小端编码的整数）。把它交给
HKDF 之前要不要“去掉前导零”？

- **TLS 1.2 及更早**：要。那时的 `ECDHEServerKeyExchange` 里，共享秘密是
  “大端整数的最小表示”，前导零会被裁掉。
- **TLS 1.3**：不要。RFC 8446 §7.4.2 写的是 `FE2OSP` 的输出对给定字段是
  **定长**的，并且明确要求

  > leading zeros found in this octet string MUST NOT be truncated

  同一节还特意加了一句注：_this construction differs from previous versions
  of TLS which removed leading zeros_。

也就是说，**TLS 1.3 的 `shared_secret` 永远是 32 字节的原样输出**，
长度不随数值大小变化。本章照此实现：`scalarmult()` 返回的 32 字节直接进
`tls_keyschedule.buildSchedule()`，没有任何裁剪函数。

为什么这个细节致命？因为 HKDF 只吃字节：如果一边裁了前导零、另一边没裁，
双方算出的 `handshake_secret` 会不同，但**长度都是合法的**——症状是
“握手走到某一步突然 tag 校验失败”，而不是任何形式的解析错误。若把 TLS 1.2
的裁零规则误用到 1.3，只在“共享秘密恰好以 0 开头”的极少数会话里出错，
测试环境几乎必然不复现。

（同理，跨实现比对时不要自己裁字节：`openssl s_client -keylogfile` 里的
`CLIENT_HANDSHAKE_TRAFFIC_SECRET` 是定长 32 字节的 hex，直接逐字节比。）

### 23.4.4 自检里为什么还要测「对称性」

两组 RFC 向量验的是“标量乘本身”。但它不能证明“双方算出的共享秘密相同”
——那是 DH 的性质，不是标量乘的性质。所以主机测试额外加了一条：

```zig
test "DH symmetry: a*b == b*a" {
    const a_sk = selftest_seed;              // 0x23 × 32
    const b_sk: [32]u8 = @splat(0x42);
    const a_pk = publicKey(a_sk);
    const b_pk = publicKey(b_sk);
    const s1 = try scalarmult(a_sk, b_pk);
    const s2 = try scalarmult(b_sk, a_pk);
    try std.testing.expectEqualSlices(u8, &s1, &s2);
}
```

板侧还把本工程固定 seed 的公钥打出来（`read: x25519 pub(len=32)=9a4503a9`），
将来接真握手时可以直接和 `openssl` 侧的 `key_share` 对拍。

---

## 23.5 AEAD：AES-GCM 与 nonce/AD 的绑定

### 23.5.1 TLS 1.3 只留了 AEAD

TLS 1.2 的 `TLSCiphertext` 还有“先 MAC 后加密”和“先加密后 MAC”两种模式，
TLS 1.3 直接砍掉：只允许 AEAD（§5.2）。于是记录层的密文部分变成

```text
struct {
    ContentType opaque_type = application_data;  /* 23 */
    ProtocolVersion legacy_record_version = 0x0303;
    uint16 length;
    opaque encrypted_record[TLSCiphertext.length];
} TLSCiphertext;

TLSCiphertext.length = len(TLSInnerPlaintext) + tag_length
```

而 `TLSInnerPlaintext` 是

```text
struct {
    opaque content[TLSPlaintext.length];
    ContentType type;
    uint8 zeros[length_of_padding];
} TLSInnerPlaintext;
```

也就是说：真实类型被搬到内层（`type` 字段），明文后面可能跟任意多个零作为
padding。本章只实现外层加解密与 AD 构造，不做 padding 生成——padding 的
作用是对抗长度分析，与“能不能解出来”无关。

### 23.5.2 nonce：iv 异或序号

TLS 1.3 §5.3 规定 nonce = `iv XOR (0^32 || seq)`，其中 seq 是 64 位大端：

```zig
pub fn nonceFor(iv: [nonce_length]u8, sequence: u64) [nonce_length]u8 {
    var nonce = iv;
    var seq_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_bytes, sequence, .big);
    for (seq_bytes, 0..) |b, i| {
        nonce[nonce_length - 8 + i] ^= b;
    }
    return nonce;
}
```

主机测试用 `iv = 0xAA × 12`、`seq = 1` 验证“只改低 8 字节”：

```text
nonce = AA AA AA AA AA AA AA AA AA AA AA AB
        └──── 前 4 字节不变 ────┘└── 末字节 +1 ──┘
```

### 23.5.3 additional data：把记录头绑进 tag

这是 TLS 1.3 最优雅的一处设计。AD 就是记录头本身：

```zig
pub fn additionalData(ct: u8, ciphertext_len: usize) [5]u8 {
    return .{ ct, 0x03, 0x03,
              @intCast((ciphertext_len >> 8) & 0xFF),
              @intCast(ciphertext_len & 0xFF) };
}
```

于是任何对记录头的篡改（改类型、改长度）都会让 tag 校验失败。
这解决了 TLS 1.2 的一个真实问题：中间人可以改记录头而不破坏 MAC，
进而做裁剪攻击（truncation）。TLS 1.3 把“头”纳入认证范围，攻击面直接消失。

自检 ⑥ 里 `tamper=2/2` 的第二个 1 就是它：拿正确的密文和 tag，
只把 AD 换成一个字节（`{0x17}` → 长度错），必须返回 `AuthenticationFailed`。

### 23.5.4 NIST 向量

NIST SP 800-38D 的 AES-128-GCM 测试用例（也是 RFC 5116 附录 B 引用的那组）：

| 用例 | K        | IV       | P        | A   | 期望                                                                           |
| ---- | -------- | -------- | -------- | --- | ------------------------------------------------------------------------------ |
| 1    | 全零 16B | 全零 12B | 空       | 空  | `T = 58e2fccefa7e3061367f1d57a4e7455a`                                         |
| 2    | 全零 16B | 全零 12B | 全零 16B | 空  | `C = 0388dace60b6a392f328c2b971b2fe78`，`T = ab6e47d42cec13bdf53a67b21257bddf` |

板侧判据 ⑥ 把这两组、以及“解封能还原”“tag 篡改被拒”“AD 篡改被拒”
合成一条：

```text
check: aes-gcm nist tag=ab6e47d4 ct=0388dace tamper=2/2 ok=1
```

`tag=ab6e47d4` 是 Test Case 2 的 tag 前 4 字节，`ct=0388dace` 是它的密文
前 4 字节。两个前缀同时对上，几乎不可能靠巧合。

### 23.5.5 从 traffic secret 到 key/iv

`aead.deriveKeyIv` 用的是 §7.3 的约定：AES-128-GCM 的 key 16 字节、
iv 12 字节，都从 32 字节 traffic secret 用 `HKDF-Expand-Label` 派生：

```zig
pub fn deriveKeyIv(secret: [32]u8, out_key: *[key_length]u8, out_iv: *[nonce_length]u8) void {
    const ks = @import("tls_keyschedule.zig");
    ks.expandLabel(out_key, secret, "key", "") catch unreachable;
    ks.expandLabel(out_iv, secret, "iv", "") catch unreachable;
}
```

注意 label 不带 `"tls13 "` 前缀——`encodeInfo` 会补。这个“补”的行为如果是
隐式的，就会和“调用方自己补”形成双重前缀，所以本章把前缀只写在
`encodeInfo` 一处，`deriveKeyIv` 传的是裸 label。主机测试专门验证了
`expandLabel("key")` 与手工 info 对拍，正是为了钉住这一点。

### 23.5.6 记录级加封：把三样东西串起来

```zig
pub fn seal(
    ct: []u8,
    tag: *[tag_length]u8,
    plaintext: []const u8,
    record_type: u8,
    iv: [nonce_length]u8,
    sequence: u64,
    key: [key_length]u8,
) Error!void {
    const ad = additionalData(record_type, plaintext.len + tag_length);
    try sealWithNonce(ct, tag, plaintext, &ad, nonceFor(iv, sequence), key);
}
```

主机测试 `GCM record sealing binds the record header as AD` 走完整条路：
用固定的 key/iv/seq 加封一段“HTTP 请求 + 0x17”，解密还原；然后把 seq 换成 8、
把 type 换成 0x16，两次都必须失败。这条用例是整章里最接近“真实记录”的一条。

---

## 23.6 证书：DER 结构、SAN、验签调用面

### 23.6.1 只解析我们需要的 6 个字段

X.509 是 ASN.1 的重灾区。但一个 HTTPS 客户端真正需要的只有六样：

| 字段       | DER 里的位置                      | 本章用途                 |
| ---------- | --------------------------------- | ------------------------ |
| version    | `tbsCertificate` 第 1 个 `[0]`    | 校验是 v3（v1 没有扩展） |
| subject CN | `Name` 里的 OID `2.5.4.3`         | 日志/判据                |
| issuer CN  | 同上（在 issuer 里）              | 自签时与 subject 相同    |
| validity   | 两个 `UTCTime`                    | 解析成结构（不比较时间） |
| SAN        | `extensions` 里的 OID `2.5.29.17` | 真实客户端用它匹配主机名 |
| SPKI       | P-256 公钥（uncompressed SEC1）   | 验签输入                 |

其余的一律跳过：`serialNumber` 只读不判，`keyUsage`/`extendedKeyUsage`
不读，`subjectAltName` 之外的扩展直接忽略。这是**故意**的——解析器越窄，
攻击面越小；真实证书里 90% 的字节我们不需要看懂。

### 23.6.2 TLV 读取器

DER 只有“tag + 长度 + 内容”一种形状，长度有三种编码（1 字节、`0x81`、
`0x82`、最多 `0x83`）：

```zig
pub fn nextTlv(der: []const u8, pos: *usize) Error!Tlv {
    var p = pos.*;
    if (p + 2 > der.len) return Error.Truncated;
    const tag = der[p];
    p += 1;
    var len: usize = der[p];
    p += 1;
    if (len & 0x80 != 0) {
        const n = len & 0x7F;
        if (n == 0 or n > 3) return Error.BadLength;   // 不定长/超长一律拒
        if (p + n > der.len) return Error.Truncated;
        len = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) len = (len << 8) | der[p + i];
        p += n;
    }
    if (p + len > der.len) return Error.Truncated;
    const raw = der[pos.* .. p + len];
    pos.* = p + len;
    return .{ .tag = tag, .raw = raw, .body = der[p .. p + len] };
}
```

`Tlv` 同时带 `raw`（含 tag 与长度）和 `body`（只内容）。为什么两者都要？

- `body` 用来向下解析；
- `raw` 用来**验签**：ECDSA 签的是 `tbsCertificate` 的**原始编码字节**，
  不是“重新编码一遍”的字节。重新编码会因 DER 的多种合法写法（例如
  BOOLEAN 的 `TRUE` 可以是 `0xFF` 也可以是 `0x01`）导致签名对不上。

这是 X.509 解析里最容易犯的错，也是本章把 `Cert.tbs` 定义成 `[]const u8`
（原始切片）而不是结构体的原因。

### 23.6.3 证书的骨架

```text
Certificate  ::=  SEQUENCE  {
     tbsCertificate       TBSCertificate,
     signatureAlgorithm   AlgorithmIdentifier,
     signatureValue       BIT STRING  }

TBSCertificate  ::=  SEQUENCE  {
     version         [0] EXPLICIT Version DEFAULT v1,
     serialNumber         CertificateSerialNumber,
     signature            AlgorithmIdentifier,
     issuer               Name,
     validity             Validity,
     subject              Name,
     subjectPublicKeyInfo SubjectPublicKeyInfo,
     issuerUniqueID  [1]  IMPLICIT UniqueIdentifier OPTIONAL,
     subjectUniqueID [2]  IMPLICIT UniqueIdentifier OPTIONAL,
     extensions      [3]  EXPLICIT Extensions OPTIONAL }
```

本章的 `parse()` 按这个顺序走，遇到可选字段（`[0]`/`[3]`）用 tag 判定：

```zig
var i: usize = 0;
if (n > 0 and children[0].tag == 0xA0) i = 1;      // version
...
const serial = try expectTag(children[i], 0x02);
const tbs_alg = try expectTag(children[i + 1], 0x30);
out.tbs_sig_oid = try algorithmOid(tbs_alg);
out.issuer_cn = try nameCn(children[i + 2]);
try validity(children[i + 3], &out.not_before, &out.not_after);
out.subject_cn = try nameCn(children[i + 4]);
try spki(children[i + 5], &out.spki_curve_oid, &out.spki_point);
if (n > i + 6 and children[i + 6].tag == 0xA3) try extensions(children[i + 6], &out);
```

### 23.6.4 fixture：419 字节的自签证书

没有 CA、没有随机数、没有网络，怎么得到一份“真实”的 DER？答案是**自己造一份**，
但必须满足两个条件：

1. **字节确定**：同一份源码永远产出同一串字节；
2. **外部实现认可**：用独立的解析器验证字段。

本章的做法：

```zig
pub fn buildSelfSigned(buf: []u8) Error![]u8 {
    const seed: [32]u8 = @splat(0x23);
    const kp = Ecdsa.KeyPair.generateDeterministic(seed) catch return Error.BadDer;
    const sec1 = kp.public_key.toUncompressedSec1();

    var tbs_buf: [640]u8 = undefined;
    var tr = Rev.init(&tbs_buf);
    try putTbs(&tr, &sec1);
    const tbs = tr.slice();

    const noise: [32]u8 = @splat(0);
    const sig = kp.sign(tbs, noise) catch return Error.BadDer;
    var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    const sig_der = sig.toDer(&sig_buf);
    ...
}
```

`Rev` 是一个**反向写**的 DER 编码器：从缓冲尾部往前写，因此可以在写内容
时还不知道长度、写完一层再补 tag+长度头。这样不需要两遍扫描，也不需要分配。
代价是“容器的子元素必须倒序写”，这一点在注释里写死了。

结果：

```text
wrote src/testdata/sample-cert.der: 419 bytes
sha256: 00f3df2260e2aaec305cfcc58b88df77703b1cd3fee5920ecf869b81e045d2a2
```

419 字节，SHA-256 指纹 `00f3df22…45d2a2`。板侧 `fp=00f3df22` 就是它的前 4 字节。

### 23.6.5 交叉验证：用 OpenSSL 看同一份字节

自己造的字节，自己解析对，不能说明什么。所以本章用 OpenSSL 3.6.4
（Python 的 `ssl._ssl._test_decode_cert`，内部就是 OpenSSL）独立解了一遍：

```python
import ssl, base64
der = open('src/testdata/sample-cert.der','rb').read()
pem = b"-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(der) + b"-----END CERTIFICATE-----\n"
open('/tmp/sample.pem','wb').write(pem)
print(ssl._ssl._test_decode_cert('/tmp/sample.pem'))
```

输出（真实运行结果）：

```text
subject = ((('commonName', 'ch23-stub.local'),), (('organizationName', 'Zig x S31 Lab'),), (('countryName', 'CN'),))
issuer  = ((('commonName', 'ch23-stub.local'),), (('organizationName', 'Zig x S31 Lab'),), (('countryName', 'CN'),))
subjectAltName = (('DNS', 'ch23.local'), ('DNS', 'www.ch23.local'), ('IP Address', '127.0.0.1'))
notBefore = Jan  1 00:00:00 2026 GMT
notAfter  = Jan  1 00:00:00 2027 GMT
version = 3
serialNumber = 01234567
```

本工程的解析器给出的是同样的字段（板侧 ⑦）：

```text
check: x509 der cn=ch23-stub.local issuer=ch23-stub.local san=3 first=ch23.local nb=2026-01-01 ok=1
```

`san=3` 表示三条 SAN：两个 DNS + 一个 IP（IP 以 4 字节二进制存，
判据里逐字节比较 `7F 00 00 01`）。

### 23.6.6 验签：自洽校验，不是信任链

```zig
pub fn verifySignature(cert: *const Cert) VerifyError!void {
    if (!std.mem.eql(u8, cert.sig_oid, &oid_ecdsa_sha256)) return Error.UnsupportedAlgorithm;
    const sig = try Ecdsa.Signature.fromDer(cert.sig);
    const pk = try Ecdsa.PublicKey.fromSec1(cert.spki_point);
    try sig.verify(cert.tbs, pk);
}
```

这三行分别对应三个 std API（都在 `std/crypto/ecdsa.zig` 里）：
`Signature.fromDer`（`:178`）、`PublicKey.fromSec1`（`:67`）、
`Signature.verify`（`:104`）。

它证明的是“tbs / 公钥 / 签名三段互相匹配”，**不证明“这个公钥被谁信任”**。
信任锚需要 CA store、需要有效期判断（可信时钟）、需要 `nameConstraints` 等
扩展的完整语义——这些都不在本章范围内，23.11 会把它们写成待验证项。

板侧 ⑧ 除了验“对的那份”，还验“错的那份”：

```zig
@memcpy(g_cert[0..cert.fixture_der.len], cert.fixture_der);
const idx = std.mem.indexOf(u8, g_cert[0..cert.fixture_der.len], "ch23-stub.local").?;
g_cert[idx] = 'd';       // 'c' -> 'd'：结构不变，签名失效
```

```text
check: x509 verify ok=1 tampered=rejected fp=00f3df22 ok=1
```

这个“翻一个字节”的用例比“验签成功”更重要：一个永远返回成功的
`verifySignature` 也能通过前者。

### 23.6.7 关于 `@embedFile`

fixture 通过

```zig
pub const fixture_der = @embedFile("testdata/sample-cert.der");
```

进固件。它在镜像里落在 `.rodata`（DROM 段），板侧解析时读的是 flash 映射区，
不需要任何文件系统——这也顺带说明了为什么本章的 `.rodata` 对齐会到 64 字节
（见 23.10.4）。

---

## 23.7 HTTP/1.1 解析器的边界

### 23.7.1 一条请求长什么样

```text
GET /index.html?x=1 HTTP/1.1\r\n
Host: ch23.local\r\n
User-Agent: s31\r\n
Accept: */*\r\n
\r\n
```

规则全在 RFC 9112（它取代了 RFC 7230 的消息语法部分）。本章只实现其中
“能判错”的那部分，并且**故意**不接受几件合法但少见的东西：

| 输入形态                                    | RFC 允许         | 本章        | 理由                     |
| ------------------------------------------- | ---------------- | ----------- | ------------------------ |
| `CRLF` 行尾                                 | 必须             | 接受        | 唯一标准形态             |
| 裸 `LF` 行尾                                | 服务端可宽容接受 | **拒绝**    | 宽容是攻击面（请求走私） |
| obs-fold（行折叠）                          | 已废弃但仍见     | **拒绝**    | 同上                     |
| `Content-Length` + `Transfer-Encoding` 并存 | 拒绝             | **拒绝**    | RFC 9112 §6.1 的走私防线 |
| 首部 > 16 条                                | 无限制           | 拒绝        | `.bss` 静态表上限        |
| absolute-form (`http://h/p`)                | 允许             | 只按 `?` 切 | 够自检，不够当代理       |

解析器的返回结构直接借用输入切片：

```zig
pub const Request = struct {
    method: Method,
    method_text: []const u8,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    version: Version,
    headers: [max_headers]Header = undefined,
    header_len: usize = 0,
    content_length: ?usize = null,
    chunked: bool = false,
    keep_alive: bool = false,
    ...
};
```

`path`/`query` 是 `target` 的两个切片视图，`headers[i].name/value` 是输入的
切片。整个解析**零拷贝**：只要输入缓冲还活着，结构就有效。板侧输入是
`.rodata` 里的字符串常量，生命周期天然满足。

### 23.7.2 请求行的三段

```zig
var parts = std.mem.splitScalar(u8, request_line, ' ');
const method_text = parts.next() orelse return Error.BadRequestLine;
const target = parts.next() orelse return Error.BadRequestLine;
const version_text = parts.next() orelse return Error.BadRequestLine;
if (parts.next() != null) return Error.BadRequestLine;
```

第四段必须不存在：`GET /a /b HTTP/1.1` 这种多空格或多余字段在真实世界里
是走私测试的第一发。本章把它直接判错。

方法名用白名单映射，未知方法归到 `.other` 而不是报错——因为扩展方法
（`PATCH`、`PROPFIND`）是合法的，只是本章不需要。

### 23.7.3 首部：大小写不敏感 + 去空白

HTTP 首部名大小写不敏感（RFC 9110 §5.1），所以查找要 `eqlIgnoreCase`：

```zig
pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
    for (self.headers[0..self.header_len]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}
```

值两侧的空白要裁掉（`trim(u8, value, " \t")`）——不是“顺手”，因为
`Content-Length: 11 ` 里的尾随空格如果进了 `parseInt` 就会失败。

`Content-Length` 的解析有一个隐藏陷阱：**多个 `Content-Length` 首部**。
本章的策略是“取最后一个”吗？不是，是“取第一个并忽略后面的”，这在严格
意义上也不合规（RFC 要求值相同或拒绝）。这是一个明确的简化，写进了注释。

### 23.7.4 自检 ⑨

```text
check: http request GET /index.html q=x=1 hdrs=3 keep=1 ok=1
```

四个读数：方法、路径、query、首部条数、keep-alive 判定。全部来自同一次
`parseRequest`，任何一个字段错都会让 `ok=0`。

主机测试还覆盖了三种拒绝形态：

```zig
const smuggle = "POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n";
try std.testing.expectError(http.Error.AmbiguousFraming, http.parseRequest(smuggle));
```

### 23.7.5 chunked：分块编码的解码

`Transfer-Encoding: chunked` 的语法（RFC 9112 §7.1）：

```text
chunked-body = *chunk last-chunk trailer-section CRLF
chunk        = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
chunk-size   = 1*HEXDIG
last-chunk   = 1*("0") [ chunk-ext ] CRLF
```

解码器要处理三件事：十六进制长度、块后的 `CRLF`、长度 0 的终止块。本章的实现：

```zig
pub fn decodeChunked(in: []const u8, out: []u8) Error!usize {
    var pos: usize = 0;
    var written: usize = 0;
    while (true) {
        const line_rel = std.mem.indexOf(u8, in[pos..], "\r\n") orelse return Error.Incomplete;
        const line_end = pos + line_rel;
        const size_text = std.mem.trim(u8, in[pos..line_end], " \t");
        const size_part = if (std.mem.indexOfScalar(u8, size_text, ';')) |semi| size_text[0..semi] else size_text;
        if (size_part.len == 0) return Error.BadChunkSize;
        const size = std.fmt.parseInt(usize, size_part, 16) catch return Error.BadChunkSize;
        pos = line_end + 2;
        if (size == 0) { ... return written; }
        ...
    }
}
```

`;` 之后是 chunk-ext（扩展参数），真实世界里几乎没人用，但**不处理它就会
把 `1a;foo=bar` 当成非法长度**，进而把合法请求判错。本章只截断不解析。

自检 ⑩：

```text
check: http chunked decoded=9 body=Wikipedia bad=rejected ok=1
```

`Wikipedia` 正好是 RFC 9112 §7.1 例子里的经典字符串（`4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n`）。
`bad=rejected` 对应 `zz\r\n` 这种非法长度行。

### 23.7.6 为什么解码要写到调用方给的缓冲

因为板侧没有堆。`decodeChunked(in, out)` 的形状让调用方负责内存，
解码器只负责“别越界”：

```zig
if (written + size > out.len) return Error.NoSpace;
```

这是一个很小但很关键的设计：所有会增长的缓冲都由调用方给容量，
解析器在容量不足时返回错误而不是分配。整章六个模块都遵守这条。

---

## 23.8 响应构造与 keep-alive

### 23.8.1 keep-alive 的两条规则

HTTP/1.1 默认持久连接，HTTP/1.0 默认关闭（RFC 9112 §9.3）：

```zig
pub fn keepAlive(version: Version, connection: []const u8) bool {
    return switch (version) {
        .http_1_1 => !containsToken(connection, "close"),
        .http_1_0 => containsToken(connection, "keep-alive"),
    };
}
```

`containsToken` 按逗号分割并去空白，因为 `Connection: keep-alive, Upgrade`
是合法的多值首部。用 `std.mem.indexOf` 做子串匹配会把
`Connection: x-close` 误判成 close——这是本章刻意避免的。

自检 ⑪ 用四格矩阵：

```text
check: http keepalive 1.1=1 1.1+close=0 1.0=0 1.0+keep=1 ok=1
```

四格全对才算过。为什么值得单独一条？因为 keep-alive 判错**不会立刻出错**：
客户端会等一个永远不会来的响应，或者服务端提前关掉一个还在用的连接。
症状是“偶发断开”，最难查。

### 23.8.2 响应构造：长度必须一致

```zig
pub fn buildResponse(
    out: []u8,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
    keep: bool,
) Error![]const u8 {
    const head = std.fmt.bufPrint(out, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n\r\n", .{
        status, reason, content_type, body.len, if (keep) "keep-alive" else "close",
    }) catch return Error.NoSpace;
    if (head.len + body.len > out.len) return Error.NoSpace;
    @memcpy(out[head.len..][0..body.len], body);
    return out[0 .. head.len + body.len];
}
```

`Content-Length` 与 body 用的是同一个 `body.len`，不可能写歪——这是刻意的
形状设计：不提供“让我单独指定长度”的接口，就不存在“长度不一致”的 bug。

`Connection` 也必须与请求的判定一致：请求判定为 keep-alive 就回 `keep-alive`，
否则回 `close`。如果两者不一致，代理会按错误的边界拆包——这是 HTTP
里最经典的“帧边界错位”来源。

### 23.8.3 自检 ⑫

```text
check: http response status=200 cl=9 total=97 conn=keep-alive close=1 ok=1
```

四个读数：状态码、`Content-Length`、响应总长、Connection。`total=97`
可以手工验算：

```text
"HTTP/1.1 200 OK\r\n"                 17
"Content-Type: text/plain\r\n"        26
"Content-Length: 9\r\n"               19
"Connection: keep-alive\r\n"          24
"\r\n"                                 2
--- 头 88 + body 9 = 97
```

这个 97 是实算的（板侧打印的就是 `resp.len`），不是猜的。

---

## 23.9 工程走读

### 23.9.1 浏览页深链

| 文件                       | 作用                                              | 站内浏览                                                                                                                                   |
| -------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `build.zig`                | 目标串、链接脚本、`zig build test`、`gen-fixture` | [/static/code/#/zig-esp32-s31/ch23-tls-http/build.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/build.zig)                               |
| `linker/s31.ld`            | 两段 flash、`.trap_ram`、5 条 ASSERT              | [/static/code/#/zig-esp32-s31/ch23-tls-http/linker/s31.ld](/static/code/#/zig-esp32-s31/ch23-tls-http/linker/s31.ld)                       |
| `src/start.zig`            | `esp_app_desc_t` + naked `_start`                 | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/start.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/start.zig)                       |
| `src/main.zig`             | banner → 自检 → verdict → `wfi`                   | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/main.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/main.zig)                         |
| `src/selftest.zig`         | 12 条板侧判据                                     | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/selftest.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/selftest.zig)                 |
| `src/tls_record.zig`       | 记录层 + 握手分帧                                 | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/tls_record.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/tls_record.zig)             |
| `src/tls_keyschedule.zig`  | HKDF + HkdfLabel + 密钥链                         | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/tls_keyschedule.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/tls_keyschedule.zig)   |
| `src/x25519.zig`           | RFC 7748 向量与调用面                             | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/x25519.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/x25519.zig)                     |
| `src/aead.zig`             | AES-128-GCM + nonce/AD                            | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/aead.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/aead.zig)                         |
| `src/cert.zig`             | DER 构造/解析/验签                                | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/cert.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/cert.zig)                         |
| `src/http.zig`             | HTTP/1.1 解析与响应                               | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/http.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/http.zig)                         |
| `src/host_tests.zig`       | 主机侧 32 个用例的根                              | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/host_tests.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/host_tests.zig)             |
| `src/gen_cert_fixture.zig` | 生成 fixture 的工具                               | [/static/code/#/zig-esp32-s31/ch23-tls-http/src/gen_cert_fixture.zig](/static/code/#/zig-esp32-s31/ch23-tls-http/src/gen_cert_fixture.zig) |
| `tools/flash.sh`           | 烧录（替换应用行）                                | [/static/code/#/zig-esp32-s31/ch23-tls-http/tools/flash.sh](/static/code/#/zig-esp32-s31/ch23-tls-http/tools/flash.sh)                     |

[完整工程](/static/code/#/zig-esp32-s31/ch23-tls-http/README.md)

### 23.9.2 模块依赖图

```text
                     ┌──────────────┐
     主机侧测试 ────→ │ host_tests   │
                     └──┬───────────┘
                        │ import
   ┌────────────────┬───┴────┬──────────────┬─────────────┐
   ▼                ▼        ▼              ▼             ▼
tls_record   tls_keyschedule  x25519      aead          http
   ▲                ▲            ▲          │              │
   │                └────────────┴──────────┘              │
   │                     （aead 调 keyschedule 派生 key/iv）│
   │                                                      │
   └──────────────┬───────────────────────────────────────┘
                  ▼
             selftest.zig ──→ main.zig ──→ start.zig（板侧）
                  │
                  └──→ cert.zig（fixture 走 @embedFile）
```

注意 `cert.zig` 被 selftest 与 host_tests 共用，但它**不依赖**其它五个模块：
DER 解析与密钥派生互不相干，混在一起只会让测试难定位。

### 23.9.3 静态缓冲的账

板侧主栈 16 KiB（链接脚本 `_stack_size = 0x4000`），所有工作区都在 `.bss`：

| 缓冲      | 大小 | 用途                         |
| --------- | ---- | ---------------------------- |
| `g_msg`   | 3004 | 一条握手消息（4 + 3000）     |
| `g_wire`  | 3300 | 分片后的记录流               |
| `g_reasm` | 3200 | 跨记录重组                   |
| `g_cert`  | 768  | fixture 的可写副本（篡改用） |
| `g_http`  | 512  | 响应缓冲                     |
| `g_chunk` | 64   | chunked 解码输出             |
| `g_plain` | 128  | GCM 解密输出                 |

合计约 11 KiB，全在 `.bss`（NOBITS，不占镜像空间，由 `_start` 清零）。
实测镜像里 `.bss` 大小 `0x2a70 = 10864` 字节，与上表吻合。

为什么必须放 `.bss` 而不是局部变量？16 KiB 栈里再放 11 KiB 的临时缓冲，
任何一次深调用（例如 ECDSA 验签内部的 P-256 乘法）都可能踩穿栈顶，表现为
`Store access fault` + `rst:0x1a`，而且调用栈被覆盖之后无法归因。

### 23.9.4 `_start` 与 `.bss` 的关系

```asm
        # ---- 4) 清零 .bss ----
        la      t0, _bss_start
        la      t1, _bss_end
        bgeu    t0, t1, 2f
1:
        sw      zero, 0(t0)
        addi    t0, t0, 4
        bltu    t0, t1, 1b
2:
```

这段与 ch13–ch22 完全一致。本章多了一个理由：`MessageReader` 的 `len` 是
`.bss` 里的字段，如果不清零，上一次运行（复位前）残留的消息长度会让
第一次 `push` 就从错误偏移开始重组——在主机上表现为“第二个用例依赖第一个
用例”，在板上表现为“复位后偶尔失败”。

---

## 23.10 上板自检输出

### 23.10.1 banner 与范围声明

```text
ch23-tls-http | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: tls1.3 record/keyschedule + x25519 + aes-128-gcm + x509 der + http1.1
note: no network, no real handshake - ch17 link and ch22 event loop pending
host: 32 unit tests via 'zig build test'
```

第 1 行是工程名，抓串口时用它确认“抓到的是自己的镜像”（共用同一块板、
同一块串口，抓错人的日志是常见事故）。第 4 行明确写了本章没有网络、没有
真实握手——这句话是给未来的自己看的。

### 23.10.2 十三条判据（`logs/ch23-boot.log` 原文）

```text
check: record frag records=3 lens=1024,1024,956 reasm=1 ok=1
check: record limit max=16640 exact=1 over=0 raw=0 ok=1
check: hkdf-extract rfc5869 prk=07770936 ok=1
check: hkdf-expand-label label_len=9 info_len=15 out=8a5be387 manual=1 ok=1
check: x25519 rfc7748 v1=c3da5537 v2=95cbde94 loworder=rejected ok=1
check: aes-gcm nist tag=ab6e47d4 ct=0388dace tamper=2/2 ok=1
check: x509 der cn=ch23-stub.local issuer=ch23-stub.local san=3 first=ch23.local nb=2026-01-01 ok=1
check: x509 verify ok=1 tampered=rejected fp=00f3df22 ok=1
check: http request GET /index.html q=x=1 hdrs=3 keep=1 ok=1
check: http chunked decoded=9 body=Wikipedia bad=rejected ok=1
check: http keepalive 1.1=1 1.1+close=0 1.0=0 1.0+keep=1 ok=1
check: http response status=200 cl=9 total=97 conn=keep-alive close=1 ok=1
check: rfc8448 chain early=33ad0a1c hs=1dc826e9 c_hs=b3eddb12 ok_all=1 ok=1
read: traffic c_ap=ef97e3ec s_ap=b7c74e70 master=11c9962e
read: x25519 pub(len=32)=9a4503a9
checks: passed=13 failed=0 total=13
main: verdict=pass, tls/http primitives verified off-link (wfi)
main: halting (wfi)
```

### 23.10.3 怎么读这些行

| 行                  | 关键读数                                   | 换成错误实现会怎样                              |
| ------------------- | ------------------------------------------ | ----------------------------------------------- |
| `record frag`       | `3 / 1024,1024,956`                        | 分片边界算错 → 条数或余数变；重组错 → `reasm=0` |
| `record limit`      | `16640 / exact=1 / over=0 / raw=0`         | 上界写成 16384 → `exact=0`；不检查 → `over=1`   |
| `hkdf-extract`      | `prk=07770936`                             | salt/IKM 顺序颠倒 → 前 4 字节完全不同           |
| `hkdf-expand-label` | `label_len=9 / info_len=15 / manual=1`     | 忘了前缀 → `label_len=3`                        |
| `x25519`            | `v1=c3da5537 v2=95cbde94`                  | 进位错一位 → 前缀就变                           |
| `aes-gcm`           | `tag=ab6e47d4 ct=0388dace tamper=2/2`      | 忘了 AD → `tamper` 只剩 1/2                     |
| `x509 der`          | `cn/issuer/san=3/nb=2026-01-01`            | 长度解码错 → 解析直接失败                       |
| `x509 verify`       | `ok=1 tampered=rejected`                   | 永远返回成功 → `tampered=accepted`              |
| `http request`      | `GET /index.html q=x=1 hdrs=3`             | 不切 query → `q=` 空                            |
| `chunked`           | `decoded=9 body=Wikipedia`                 | 不处理 `\r\n` → 解码失败                        |
| `keepalive`         | `1.1=1 1.1+close=0 1.0=0 1.0+keep=1`       | 规则写反 → 四格至少一格错                       |
| `response`          | `cl=9 total=97 conn=keep-alive`            | 长度与 body 不一致 → `total≠97`                 |
| `rfc8448 chain`     | `early=33ad0a1c hs=1dc826e9 c_hs=b3eddb12` | label 少一个空格/长度字节写成 3 → 三项全错      |

### 23.10.4 一个真实踩到的坑：`@min` 的类型收窄

第一版固件启动后，所有十六进制前缀都是**空的**：

```text
# 修复前（十六进制前缀全部为空，但判据本身是过的）
修复前的 hkdf-extract 行 → prk= 之后什么都没有
修复前的 x25519 行     → v1= / v2= 之后什么都没有
```

判据全过（字节比较在 `std.mem.eql` 里，与打印无关），但日志没有可对拍的
读数。原因在一行看似无害的代码：

```zig
const n = @min(bytes.len, 4);          // n 的类型是 u3！
return buf[0 .. n * 2];                // 4 * 2 = 8 溢出 u3 → ReleaseSmall 下回绕成 0
```

Zig 0.17 的 `@min` 会把结果收窄到“能容纳上界的最小整数类型”：`@min(usize, 4)`
的类型是 **`u3`**（0..7）。Debug 模式下 `4 * 2` 触发整数溢出 panic（在主机上
一测就抓到），`ReleaseSmall` 模式下静默回绕成 0，于是切出空切片。

修复只需一个显式类型：

```zig
const n: usize = @min(bytes.len, 4);
```

这个坑值得写进章节，因为它是“板上现象无法归因”的典型案例：判据通过说明
逻辑对，日志为空说明格式化对，两者同时发生时才指向**类型**。

### 23.10.5 镜像事实：DROM 在 0x40020040

```text
I (81) esp_image: segment 0: paddr=00010020 vaddr=40000020 size=198b0h (104624) map
I (107) esp_image: segment 1: paddr=000298d8 vaddr=2f000000 size=0006ch (   108) load
I (109) esp_image: segment 2: paddr=0002994c vaddr=00000000 size=066ech ( 26348)
I (116) esp_image: segment 3: paddr=00030040 vaddr=40020040 size=04160h ( 16736) map
```

对比 ch21（`segment 3: paddr=00020020 vaddr=40020020`），本章的 DROM 段起点
高了 `0x20`。原因链条完整可追：

1. 本章用到 `Aes128Gcm`，rv32 上没有 AES 指令，走 `std/crypto/aes/soft.zig`；
2. 那里五张查表写了 `align(64)`（`:746-750`，注释说明是为让加解密落在不同
   L1 cache line）；
3. LLVM 把 `.rodata` 输出节的对齐抬到 64；
4. `drom` 的起点 0x40020020 只对齐到 32，lld 于是把整个输出节推到
   `0x40020040`。

bootloader 是否接受？真正的检查是页内偏移同余（`esp_image_format.c:904`）：

```text
segment_data_offs % mmu_page_size == load_addr % mmu_page_size
```

镜像里 `paddr=0x30040`、`vaddr=0x40020040`，两者 `% 0x10000` 都是 `0x40`，
同余成立；`bootloader_utility.c:840` 的另一条断言（`rom_index == 2`）说的是
“镜像里恰好两个可映射段”，本章也是两个（IROM + DROM）。

于是本章保留这个偏移，并在链接脚本里用两条 ASSERT 把不变量钉住：

```ld
ASSERT(_rodata_start >= ORIGIN(drom) && _rodata_end <= ORIGIN(drom) + LENGTH(drom),
    ".flash.rodata must live inside the drom window")
ASSERT(_rodata_start % 64 == 0,
    ".flash.rodata must stay 64-byte aligned (LLVM .rodata input alignment)")
```

为什么不用 `SUBALIGN(16)` 把地址“弄好看”？那等于削弱 LLVM 的对齐声明：
五张表被摆到 32 字节边界，代码里对它们的 `align(64)` 假设就不再成立。
为了一个地址好看而违反对齐约定，是本章拒绝的那类“症状修复”。

一个副作用值得记下：`.flash.rodata` 单独成一个段之后，`elf2image` 必须
**恰好**打印 `Merged 2 ELF sections.`（irom 一段 + drom 一段）。如果为了
凑地址再加一个填充节，它会变成 `Merged 3`——这本身就是“镜像形状变了”的
信号，验收项里值得单独列一条。

---

## 23.11 边界：没做完整握手与真实连接

### 23.11.1 本章明确没有做的三件事

| 没做                             | 为什么                                                                                                       | 缺什么才能做                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------ | ---------------------------------- |
| ClientHello/ServerHello 的编解码 | 需要完整的扩展解析（`supported_versions`、`key_share`、`signature_algorithms`、ALPN…），且没有对端就无法判对 | ch17 链路 + ch22 socket            |
| Finished 的 `verify_data`        | 需要对**整条握手转录**做 HMAC，而转录的边界只有真实握手才有                                                  | 同上                               |
| 证书链与主机名匹配               | 需要 CA store、可信时钟、`nameConstraints`/`basicConstraints` 语义                                           | 时钟（ch05）+ 存储（ch09）+ 信任锚 |

### 23.11.2 真实握手需要的判据（等 ch17 + ch22）

写清楚“跑什么、看什么、算过”，将来才不用重新设计验收：

1. **握手完成判据**：与 `openssl s_server -tls1_3 -msg` 完成 1-RTT；
   本地打印的 `client_ap_traffic` 前 4 字节与 `openssl` 侧
   （`-keylogfile` 的 `CLIENT_TRAFFIC_SECRET_0`）一致。
2. **记录可解判据**：服务端发来的第一条 `application_data`（23）记录，
   用派生出的 `key/iv` + seq=0 解封成功，且内层 `type` 为 23、内容为
   一段合法 HTTP 响应。
3. **证书判据**：服务端证书链的叶证书通过 `parse` + `verifySignature`，
   SAN 与连接目标主机名匹配；一张**故意过期**的证书必须被拒。
4. **HTTP 判据**：对解出的响应调用 `buildResponse`/解析函数，`Content-Length`
   与 body 长度一致；chunked 响应能被 `decodeChunked` 还原成原文。
5. **失败判据**：把记录里任意一个字节改掉，必须得到
   `AuthenticationFailed` 而不是“解析出垃圾”。

第 5 条尤其重要：一个“永远成功”的解密器能通过前四条中的一部分，
通不过这一条。

### 23.11.3 为什么现在不做“半个握手”

可以做——把 ClientHello 硬编码成字节数组，发出去，等 ServerHello。但：

- 没有链路，发不出去；
- 就算发出去，收到的字节需要 TCP 重组（ch20 有状态机但没有真实链路）；
- 收到之后的每一步都需要前一步的输出，无法独立判定；
- 失败时无法区分“扩展写错”“记录层错”“密钥派生错”“链路丢字节”。

这正是本章把“可判定的部分”做深、把“必须联网的部分”留白的理由。等
ch17 与 ch22 到位，本章的六个模块可以直接被复用——因为它们全都只依赖
`[]const u8`。

---

## 事实来源

下表的行号都是在本机实际 `grep -n` 得到的（Zig 0.17.1 的 `lib/zig/std` 与
本地 `~/esp/esp-idf` v6.1 源码树）。

| #   | 事实                                                         | 来源（文件:行）                                                                                            |
| --- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| 1   | HKDF-Extract 的签名与实现                                    | `std/crypto/hkdf.zig:20`（`pub fn extract`）                                                               |
| 2   | HKDF-Expand 的签名与实现                                     | `std/crypto/hkdf.zig:41`（`pub fn expand(out, ctx, prk)`）                                                 |
| 3   | HKDF 的 PRK 长度 = HMAC 输出长度                             | `std/crypto/hkdf.zig:17`（`prk_length = Hmac.mac_length`）                                                 |
| 4   | AES-GCM 的 tag/nonce 长度                                    | `std/crypto/aes_gcm.zig:18-19`（`tag_length = 16`、`nonce_length = 12`）                                   |
| 5   | AES-GCM 加封/解封签名（解封返回 `AuthenticationError!void`） | `std/crypto/aes_gcm.zig:28`、`:71`                                                                         |
| 6   | X25519 标量乘返回 `IdentityElementError!`（低阶点）          | `std/crypto/25519/x25519.zig:80`                                                                           |
| 7   | X25519 的共享秘密长度 32                                     | `std/crypto/25519/x25519.zig:21`                                                                           |
| 8   | ECDSA 签名的 DER 解析                                        | `std/crypto/ecdsa.zig:178`（`Signature.fromDer`）                                                          |
| 9   | ECDSA 公钥的 SEC1 解析（uncompressed 65B）                   | `std/crypto/ecdsa.zig:67`（`PublicKey.fromSec1`）                                                          |
| 10  | ECDSA 验签入口                                               | `std/crypto/ecdsa.zig:104`（`Signature.verify`）                                                           |
| 11  | 确定性密钥派生（fixture 用固定 seed）                        | `std/crypto/ecdsa.zig:327`（`KeyPair.generateDeterministic`）                                              |
| 12  | tag 校验失败的错误名                                         | `std/crypto/errors.zig:14`（`SignatureVerificationFailed`）                                                |
| 13  | `std` 自己的 TLS 1.3 HkdfLabel 实现                          | `std/crypto/tls.zig:558`（`hkdfExpandLabel`）、`:567`（`const tls13 = "tls13 ";`）                         |
| 14  | `.rodata` 64 字节对齐的来源（AES 软件查表）                  | `std/crypto/aes/soft.zig:746-750`（`sbox_encrypt align(64)` 等）                                           |
| 15  | bootloader 的段地址同余检查                                  | `components/bootloader_support/src/esp_image_format.c:904`                                                 |
| 16  | bootloader 要求镜像里恰好两个可映射段                        | `components/bootloader_support/src/bootloader_utility.c:840`（`assert(rom_index == 2)`）                   |
| 17  | ROM `ets_printf` 的绝对地址（链接脚本 PROVIDE）              | `components/esp_rom/esp32s31/ld/esp32s31.rom.ld:24`                                                        |
| 18  | SRAM 起点与可用末尾（链接脚本 MEMORY）                       | `components/esp_system/ld/esp32s31/memory.ld.in:19`、`ld/esp32s31/ld.hp_mem_defs:9`                        |
| 19  | 记录层常量与我们逐一对拍（5 / 2^14 / 2^14+256）              | `std/crypto/tls.zig:41-43`（`record_header_len`、`max_ciphertext_inner_record_len`、`max_ciphertext_len`） |

规范条文（不是本机文件，按章节号引用）：

| 规范                       | 用到的条款                                                                                                                                                                              |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| RFC 8446 (TLS 1.3)         | §4（握手消息分帧）、§5.1（`legacy_record_version`）、§5.2（长度上界与 AEAD）、§5.3（nonce 构造）、§7.1（密钥派生与 `HkdfLabel`）、§7.3（key/iv 派生）、§7.4.2（共享秘密形状与全零拒绝） |
| RFC 5869 (HKDF)            | §2.2（Extract）、§2.3（Expand）、附录 A.1（SHA-256 向量）                                                                                                                               |
| RFC 8448 (握手样例)        | §3（Simple 1-RTT Handshake）：ECDHE 共享秘密、early/derived/handshake secret、c/s hs traffic 与转录哈希——本章的判据 ⑬                                                                   |
| RFC 7748 (X25519)          | §6.1（两组标量乘向量）                                                                                                                                                                  |
| RFC 5116 / NIST SP 800-38D | AES-128-GCM 的 nonce/tag 长度约定与两组测试向量                                                                                                                                         |
| RFC 5280 (X.509)           | §4.1（证书结构）、§4.1.2.5.1（UTCTime 的 YY 解释规则）                                                                                                                                  |
| RFC 9110 / RFC 9112 (HTTP) | §5.1（首部名大小写不敏感）、§6.1（framing 冲突拒绝）、§7.1（chunked）、§9.3（持久连接）                                                                                                 |

---

## 自查清单

- [x] `zig build test` 退出 0，`32/32 tests passed`（主机 x86_64 / Zig 0.17.1）
- [x] 每个已知答案都标注了出处：RFC 5869 A.1、RFC 7748 §6.1、
      NIST SP 800-38D Test Case 1/2、RFC 8446 §7.1 结构、**RFC 8448 §3 的
      完整 handshake 密钥链**（early/derived/handshake/c hs/s hs 五项）
- [x] `zig build -Dtarget=riscv32-freestanding-eabihf
-Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 恰好两条 `DROM, IROM`：`0x40000020`、`0x40020040`
      （后者的原因见 23.10.5，并有两条 ASSERT 钉住）
- [x] `flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'` 成功
- [x] 串口 banner 首行是 `ch23-tls-http | form B …`（确认不是别人的镜像）
- [x] 13 条 `check:` 全 PASS，`checks: passed=13 failed=0 total=13`
- [x] `main: verdict=pass` 后停在 `wfi`
- [x] 本章引用的每一行 `check:` 都与 `logs/ch23-boot.log` 逐字一致
- [x] 没有任何“真实握手/HTTPS GET 成功/浏览器访问”的结论
- [x] 未修改任何索引、套件 README 或既有章节工程
- [ ] 真实握手与 HTTPS GET（待 ch17 + ch22，判据见 23.11.2）
- [ ] 证书链验证与主机名匹配（待 CA store 与可信时钟）

---

## 下一章预告

ch24 规划为 **MQTT 3.1.1 与 OTA**：把本章的记录分片、`buildResponse` 与
ch22 的 socket 形状拼起来，做两件真实世界里最常做的“应用层小事”——

- MQTT 的 `CONNECT`/`PUBLISH` 变长整数编码与 QoS 1 的 `PUBACK` 往返；
- OTA 的分片校验：把固件按块切分，每块用本章的 AEAD 加封、
  用 `tls_record.Splitter` 的同一套边界装进传输层。

这两件都需要链路才能验收，所以 ch24 的板侧证据会继续遵守本章的纪律：
**能离线判定的做深，必须联网的写判据、不写结论。**

> [!info] 系列导航
>
> 上一章：[[ch22-socket-api-event-loop|第二十二章：Socket API 与事件循环]]
>
> **本章：第二十三章：TLS 记录层、密钥派生与 HTTP/1.1**
>
> 下一章：MQTT 与 OTA（规划中）
>
> 系列索引：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]
