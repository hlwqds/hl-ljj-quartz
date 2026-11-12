---
title: "Zig × ESP32-S31 全栈开发（二十六）：Wi-Fi 连接管理与 WPA2/WPA3"
date: 2026-12-06 18:00:00
description: "把「Wi-Fi 连接管理」拆成今天就能断言的三层：passphrase→PMK→PTK 的密钥链与 EAPOL MIC（WPA2-PSK）、4-way handshake 的顺序与重放计数、WPA3-SAE 的字节层（pwd-seed/pwd-value/F_p 归约/KCK/PMK/PMKID/confirm），再加连接状态机、事件环形队列与指数退避。全部离线可测：主机 20 例、板侧 13 条判据，不含任何射频结论。"
tags: [zig, esp32-s31, riscv, wifi, wpa2, wpa3, sae, eapol, handshake, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 上一章：[[ch25-wifi-blob-boundary|第二十五章：Wi-Fi blob 边界与 ABI 垫片]]
>
> **本章：第二十六章：Wi-Fi 连接管理与 WPA2/WPA3**
>
> 下一章：[[ch27-ble-802154-boundary|第二十七章：BLE 与 802.15.4 的边界]]

# Zig × ESP32-S31 全栈开发（二十六）：Wi-Fi 连接管理与 WPA2/WPA3

上一章把「全 Zig 卡在 Wi-Fi」这件事拆成了可测的形状：三份预编译归档导出什么、
要求什么、通过哪条通道提要求，然后把「边界」写成了 ABI 契约，用一个模拟 blob
把垫片的每条分支跑通。那一章的结论很克制：**边界是可信的，射频还没有。**

这一章往前走一步，但仍然不碰射频。问题换成另一个：

> **从「扫描到一串 BSSID」到「连接建立」之间，有哪些部分是纯协议、纯字节、
> 纯状态，因此今天就能写成可断言的代码？**

答案不是一句「很多」就能交差的。本章把这段路切成三层，逐层给出可复现的证据：

1. **密钥层**：passphrase + SSID → PMK（PBKDF2-HMAC-SHA1，4096 轮）
   → PTK（PRF-384 / PRF-512）→ KCK / KEK / TK；
2. **帧层**：EAPOL-Key 描述符的编解码、MIC（HMAC-SHA1 截断 16 字节）、
   重放计数、4-way 顺序机（msg1 → msg2 → msg3 → msg4）；
3. **连接层**：扫描候选选择、连接状态机、事件环形队列、重连退避。

三层的共同点是：**它们都能用「输入字节 → 期望字节」或者「事件序列 → 期望状态」
描述**。这正是本章敢下判据的原因——判据不是「看起来对」，是十六进制逐字节相等。

> [!warning] 本章的证据边界（重要）
>
> ch17 的以太网驱动**仍未闭环**（DMA 软复位超时、MDIO 扫不到 PHY、TX 超时，
> 见 `practice/zig-esp32-s31/logs/ch17d-boot.log`），ch25 的真实 blob 链接也还没做。
> 板上的固件**没有任何射频路径**：没有 `esp_wifi_init`、没有 MAC、没有信标、
> 没有 AP。因此本章**不可能、也不允许**给出下面任何一条结论：
>
> - ✗「板子连上了 Wi-Fi」
> - ✗「扫描到了 N 个 AP」
> - ✗「4-way handshake 在真实网络上成功」
> - ✗「SAE 能和真实 WPA3 路由器协商」
> - ✗「拿到了 IP 地址」
> - ✗「重连退避在真实断线中生效」
>
> 允许的只有：**自造帧 / 注入路径 / 纯逻辑 / known-answer**。
> 具体是：13 条 `check:` 行（本章 26.10 逐行引用）、`checks: passed=13 failed=0 total=13`、
> `main: verdict=pass`。真链路要等 ch17 闭环 + ch25 的真实 blob 链接，
> 判据写在 26.11，每条都写清「跑什么 / 看什么 / 算过」。

---

## 26.1 为什么 Wi-Fi 连接管理比 TCP 更像外设驱动

写 TCP 的时候，我们面对的是一个**完全自己实现**的协议：三次握手、序列号、
重传、拥塞窗口，全部在 ch20/ch21 里从零写出来，输入是字节流，输出是字节流。
Wi-Fi 不是这样。Wi-Fi 的连接管理有一半是「和一块你看不见的芯片谈判」：

| 层           | 谁实现                  | 本章能不能断言           |
| ------------ | ----------------------- | ------------------------ |
| PHY / 射频   | 闭源 blob（`libphy.a`） | 不能（见 ch25 26.12）    |
| MAC / 802.11 | 闭源 blob               | 不能（同 ch25）          |
| **密钥管理** | 标准（802.11i / SAE）   | **能**：字节层可离线对拍 |
| **帧层**     | 标准（EAPOL-Key）       | **能**：编码/校验可断言  |
| **连接状态** | 各厂商实现              | **能**：事件→状态可断言  |
| IP / TCP     | 我们自己写（ch18–ch22） | 已能（但没链路）         |

这张表解释了本章的切法。**密钥、帧、状态**三段是标准或我们自己定义的行为，
它们的「正确」可以用字节和状态迁移来判定；射频与 MAC 在 blob 里，今天改不动。

### 26.1.1 五个相似点：把连接当外设驱动写

这不是比喻。把「连接管理」和 ch06–ch16 写过的外设驱动并排看，结构是一样的：

| 外设驱动（ch06–ch16）   | Wi-Fi 连接管理（本章）                           |
| ----------------------- | ------------------------------------------------ |
| 上电 → 复位 → 配寄存器  | idle → scan → auth → assoc → fourway → connected |
| 中断（或轮询状态位）    | 事件（`scan_done`/`auth_ok`/`link_lost`…）       |
| ISR 不能阻塞 → 环形队列 | 事件环形队列，满了丢最旧并计数（26.6）           |
| 出错重试 + 退避         | 1/2/4/8 秒退避 + 抖动 + 上限（26.7）             |
| 超时是状态机的一部分    | 4-way 计数不前进 = 坏帧（26.4）                  |

最后一行尤其像：**外设驱动里「寄存器读回值不对」和 4-way 里「replay counter
没有严格递增」是同一种信号**——不是「再读一次也许会好」，而是「对面不按协议来」。

### 26.1.2 一个刻意的选择：把时间交给调用方

本章的状态机不读任何时钟。所有时间都由调用方给：

```zig
pub fn tick(self: *Machine, now_ms: u64) bool      // 到点就从 reconnect 回 scan
pub fn onLinkLost(self: *Machine, now_ms: u64) u64 // 返回下一次尝试的时间戳
```

好处是测试可以「快进」：判据 ⑪ 里连续 6 次断线 + 5 次退避全部在微秒内跑完，
不需要真的等 1+2+4+8+8 = 23 秒。ch15 的可观测性章节讲过同一条经验：
**把时间变成参数，状态机才可测**。

> [!tip] 工程入口
>
> 本章的完整工程在
> [`practice/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/`](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/README.md)。
> 源码走读见 26.9，上板输出见 26.10。

---

## 26.2 扫描与候选选择：先把「一堆 BSSID」变成「一个可用的候选」

扫描本身在 blob 里（`esp_wifi_scan_start`，`esp_wifi.h:557`），
结果通过 `esp_wifi_scan_get_ap_records`（`esp_wifi.h:642`）拿回来。
每条记录（`wifi_ap_record_t`，`esp_wifi_types_generic.h:352` 结束）里本章关心四个字段：

- `bssid[6]`：AP 的身份，**去重的键**；
- `rssi`：dBm，负数，越接近 0 越强；
- `primary`：信道；
- `authmode`：安全类型（`WIFI_AUTH_WPA2_PSK` 是 `esp_wifi_types_generic.h:96`，
  `WIFI_AUTH_WPA3_PSK` 是 `:100`）。

### 26.2.1 为什么「扫描结果」不能直接用

一次主动扫描会收到**多个**探针响应，同一个 BSSID 可能出现两三次，RSSI 各不相同——
这很正常：AP 在不同天线上、不同速率下回你。直接拿来用有两个坑：

1. **同 BSSID 多条**：后面的状态机按 BSSID 认 AP，重复条目会让它「认错人」；
2. **开放网络混在里面**：本章只做 WPA2/WPA3，开放网络不该进入候选。

IDF 自己也承认这一点，所以给了 `wifi_scan_threshold_t`
（`esp_wifi_types_generic.h:379`，作为 `wifi_sta_config_t.threshold` 用，`:572`）：
「只考虑安全类型不低于 X 且 RSSI 不弱于 Y 的 AP」。本章的
`selectCandidates` 是同一个思路的**纯逻辑版本**，不依赖 IDF 结构体：

```zig
// src/conn.zig:183
pub fn selectCandidates(aps: []const Ap, out: []Ap) ScanError!usize {
    // 1) 丢掉 open；
    // 2) 同一 BSSID 只留 rssi 最大的那条；
    // 3) 按 rssi 降序排；同 rssi 用 channel 升序、再按 bssid 字节序，保证确定性。
}
```

第 3 步的「确定性」不是洁癖：判据要逐条比对输出顺序。如果排序不稳定，
同样的输入两次运行顺序不同，判据就成了掷骰子。

### 26.2.2 判据 ⑦ 的输入与输出

判据用的 5 条输入（`src/selftest.zig:312` 起）：

```text
bssid=01:01:01:01:01:01  rssi=-70  ch=6   wpa2
bssid=01:01:01:01:01:01  rssi=-52  ch=6   wpa2     ← 同一个 BSSID，更强
bssid=02:02:02:02:02:02  rssi=-40  ch=36  wpa3
bssid=03:03:03:03:03:03  rssi=-30  ch=1   open     ← 被过滤
bssid=04:04:04:04:04:04  rssi=-88  ch=11  wpa2
```

期望：3 条，顺序 `-40, -52, -88`，其中 `-52` 是合并后的最强值。板侧原文：

```text
check: scan in=5 out=3 merged_rssi=-52 order=-40,-52,-88 open_dropped=1 ok=1
```

这一行是「真判据」而不是「打印」的证据：`merged_rssi=-52` 只有在
「同 BSSID 取更强」这条分支真的执行时才成立；`out=3` 只有在 open 被过滤、
重复被合并同时发生时才是 3（否则是 4 或 5）。

---

## 26.3 WPA2-PSK：从一句口令到一把会话密钥

WPA2-PSK 的密钥链有三段，每一段都有标准编号，也都能用已知向量钉住。

### 26.3.1 第一段：PMK = PBKDF2-HMAC-SHA1(passphrase, SSID, 4096, 256 bit)

802.11i 的定义（本地 IDF 里的 hostap 实现照抄了这段注释）：

```c
/* components/wpa_supplicant/src/crypto/sha1-pbkdf2.c:69
 * iterations is set to 4096 and buflen to 32. This function is described in
 * IEEE Std 802.11-2004, Clause H.4. The main construction is from PKCS#5 v2.0.
 */
int pbkdf2_sha1(const char *passphrase, const u8 *ssid, size_t ssid_len,
                int iterations, u8 *buf, size_t buflen)
```

三个容易记错的点：

1. **salt 就是 SSID**，没有别的字段参与。同一个口令换个 SSID 就是另一把 PMK；
2. **4096 轮**是标准写死的（不是安全建议值），一轮 = 一次 HMAC-SHA1；
3. 输出 **32 字节**，而 HMAC-SHA1 一次只给 20 字节，所以 32 字节需要**两块**
   （`F(P,S,c,1) || F(P,S,c,2)` 的前 12 字节）。

本章的实现只有一行「真活」，剩下的是长度校验：

```zig
// src/wpa2.zig:73
pub fn derivePmk(passphrase: []const u8, ssid: []const u8) Wpa2Error![pmk_len]u8 {
    if (!passphraseValid(passphrase)) return error.PassphraseLength; // 8..63
    if (ssid.len == 0 or ssid.len > ssid_max) return error.SsidLength; // 1..32
    var pmk: [pmk_len]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&pmk, passphrase, ssid, pbkdf2_rounds, HmacSha1) catch
        return error.Kdf;
    return pmk;
}
```

`std.crypto.pwhash.pbkdf2` 的签名在
`lib/zig/std/crypto/pbkdf2.zig:53`，PRF 是**类型参数**——所以「PBKDF2 用哪个哈希」
是编译期决定的，本章传 `std.crypto.auth.hmac.HmacSha1`
（`lib/zig/std/crypto/hmac.zig:6`；`create/init/update/final` 分别是 `:27/:33/:62/:66`）。

### 26.3.2 向量：RFC 6070 与 password/IEEE

两条独立的证据链：

**(a) RFC 6070 §2**（PBKDF2-HMAC-SHA1 的标准测试向量，P="password"、S="salt"）：

```text
c=1,    dkLen=20 → 0c60c80f961f0e71f3a9b524af6012062fe037a6
c=2,    dkLen=20 → ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957
c=4096, dkLen=20 → 4b007901b765489abead49d926f721d065a429c1
c=4096, dkLen=25 → 3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038
```

板侧只跑前两条（省时间），主机侧跑完四条（含跨块的 25 字节）。

**(b) WPA2 的公开示例**：passphrase `password`、SSID `IEEE`：

```text
PMK = f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e
```

板侧原文（判据 ①，`c1`/`c2` 打的是前 4 字节）：

```text
check: pbkdf2 rfc6070 c1=0c60c80f c2=ea6c014d c1_ok=1 c2_ok=1 bad_len=1/1 ok=1
```

注意 `bad_len=1/1`：7 字节与 64 字节的 passphrase 都被拒绝（`PassphraseLength`）。
这两个反例不是凑数——真实配置错误里最常见的正是「口令写短了 3 个字符」和
「把 64 位十六进制 PSK 填进了 passphrase 字段」。

### 26.3.3 第二段：PTK = PRF-X(PMK, "Pairwise key expansion", ...)

PTK 不是「再哈希一次」，而是一个**带计数器的 PRF**（802.11i 8.5.1.1 / 802.11-2020 12.7.1.2）：

```text
PRF(K, A, B, len) = HMAC-SHA1(K, A || 0x00 || B || i)   i = 0,1,2,...
                    逐块拼接后截断到 len
```

`A` 是标签（PTK 用 `"Pairwise key expansion"`，19 个字节，不含结尾 0；分隔字节
`0x00` 是 PRF 自己加的），`B` 是绑定数据：

```text
B = Min(AA, SPA) || Max(AA, SPA) || Min(ANonce, SNonce) || Max(ANonce, SNonce)
```

本地 IDF 的对照实现是 `components/wpa_supplicant/src/crypto/sha1-prf.c:30`，
:`33` 的 `u8 counter = 0` 就是「i 从 0 开始」的证据——和 SAE 用的
`sha256_prf_bits`（从 1 开始）**不一样**，这两个计数器起点经常被抄错。

四个 `Min/Max` 的作用是**消除角色差异**：AP 侧与 STA 侧的入参天然相反
（AP 认为自己是 AA，STA 认为自己是 SPA），重排之后两端算出同一个 PTK。
判据 ② 直接测这一点：

```text
check: ptk prf512=0cb59d207218375a prf384_prefix=1 swap_invariant=1 kck=0cb59d207218375a ok=1
```

`swap_invariant=1` 的背后是「把 AP/STA 与 ANonce/SNonce 全部对调，输出不变」。
输出长度有讲究：

| AKM / 密码套件        | PTK 长度 | 组成                       |
| --------------------- | -------- | -------------------------- |
| WPA2-PSK + CCMP       | 384 bit  | KCK 16 + KEK 16 + TK 16    |
| 802.11r / GCMP-256 等 | 512 bit  | 更长，多出的部分继续往后取 |

本章两个都算：`ptk48` 与 `ptk64`，并断言 `ptk64[0..48] == ptk48`
（PRF 是前缀稳定的，取更多块不影响前面的字节）。

固定输入的完整结果（`tools/vectors.py` 复现）：

```text
PMK   = f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e
AP    = 02:11:22:33:44:55      STA = 02:aa:bb:cc:dd:ee
ANonce= 00 01 02 ... 1f         SNonce = 20 21 22 ... 3f
PTK48 = 0cb59d207218375a0cc1c4db3cc0736060aad631553eee9dad2e06711528a2e8
        933ef3ea575a37b1ccce47a080b20de1
KCK   = 0cb59d207218375a0cc1c4db3cc07360     ← PTK 前 16 字节
```

（`KCK` 就是 PTK 的前 16 字节，所以它的十六进制前缀与 PTK 相同——判据 ② 里
`prf512=` 与 `kck=` 打出来都是 `0cb59d207218375a`，这不是复制粘贴错误。）

### 26.3.4 第三段：EAPOL-Key 帧与 MIC

4-way handshake 的每条消息都是一个 **EAPOL-Key 帧**。它的字段布局在
`components/wpa_supplicant/src/common/wpa_common.h:207` 起的
`struct wpa_eapol_key`（注意 `STRUCT_PACKED`，字段是**非对齐**的）：

| 偏移 | 长度 | 字段                        | hostap 行    |
| ---: | ---: | --------------------------- | ------------ |
|    0 |    4 | EAPOL 头（v,type,body_len） | 802.1X §11.9 |
|    4 |    1 | descriptor type             | `:208`       |
|    5 |    2 | key info（大端）            | `:210`       |
|    7 |    2 | key length（大端）          | `:211`       |
|    9 |    8 | replay counter              | `:212`       |
|   17 |   32 | key nonce                   | `:213`       |
|   49 |   16 | key IV                      | `:214`       |
|   65 |    8 | key RSC                     | `:215`       |
|   73 |    8 | key ID                      | `:216`       |
|   81 |   16 | **MIC**                     | `:217`       |
|   97 |    2 | key data length             | `:218`       |
|   99 |    N | key data（RSN IE）          | 紧随其后     |

`key_info` 的位定义（`wpa_common.h:192/196/198/199/200`）：

```text
BIT(3) KEY_TYPE  = 1 → pairwise       BIT(8) MIC
BIT(6) INSTALL                        BIT(9) SECURE
BIT(7) ACK                            BIT(10) ERROR / BIT(11) REQUEST
```

本章的 `encode` 就是按这张表写字节（`src/wpa2.zig:231`），`decode` 反向解析
（`:260`）。判据 ③ 用一帧完整的 msg2 验往返：

```text
key_info = 0x010a   (ver=2 | pairwise | MIC)
replay   = 1
nonce    = SNonce
key data = 22 字节标准 RSN IE
帧长     = 4 + 95 + 22 = 121
```

这一帧的十六进制（`tools/vectors.py` 产出，`src/vectors.zig` 编译期解码）：

```text
02030075                                  EAPOL v2 type=3 body=117
02                                        descriptor type = RSN
010a                                      key info
0000                                      key length
0000000000000001                          replay = 1
202122232425262728292a2b2c2d2e2f3031...   SNonce (32 B)
0000000000000000 0000000000000000          IV(16) / RSC(8)
0000000000000000                          key ID (8)
73e895d1efbcfc3c240b8752b08f41ea          MIC
0016                                      key data length = 22
30140100000fac040100000fac040100000fac020000   RSN IE
```

**MIC 怎么算**（802.1X-2010 §11.9.1）：

```text
MIC = HMAC-SHA1(KCK, 整个 EAPOL 帧，MIC 字段先清 0)[0..16]
```

三个细节都能把实现打偏：

1. **MIC 字段清零后再算**，不是「用旧 MIC 覆盖」；
2. 参与计算的是**整个帧**（含 4 字节 EAPOL 头），不是只有 body；
3. 密钥是 **KCK（PTK 的前 16 字节）**，不是 PMK。

本章实现（`src/wpa2.zig:288`）刻意**不修改入参**：主机测试拿同一块缓冲连续算两次，
必须得到同样的结果——如果实现里「顺手把 MIC 清零写回入参」，第二次就会算错。
校验用常量时间比较（`lib/zig/std/crypto/timing_safe.zig:12` 的
`eql`），避免把「MIC 前几字节对」泄漏成时间差（`src/wpa2.zig:301`）。

判据 ③ 一次给五个结果：重算出的 MIC、命中向量、校验通过、改 key data 被拒、
换一把 KCK 被拒，外加解码往返正确：

```text
check: eapol mic len=121 mic=73e895d1efbcfc3c vec=1 verify=1 tamper=1 wrong_kck=1 decode=1 ok=1
```

`mic=73e895d1efbcfc3c` 是**重算出来的** MIC（前 8 字节），`vec=1` 表示它与
向量表里的 `73e895d1efbcfc3c240b8752b08f41ea` 逐字节相同。这条判据如果只打印
`ok=1` 而没有具体值，就无法区分「算对了」和「两边都错得一样」——所以它同时
打印了计算值，`verify=1` 才是「拿帧里的 MIC 去校验」这条路径。

---

## 26.4 4-way handshake：时序、计数器、以及为什么重放计数不能省

### 26.4.1 四条消息到底在交换什么

| 消息 | 方向   | key_info（典型）          | replay | 带 nonce   | 作用                        |
| ---- | ------ | ------------------------- | -----: | ---------- | --------------------------- |
| msg1 | AP→STA | ACK                       |      1 | ANonce     | 给出 ANonce，开始派生       |
| msg2 | STA→AP | MIC \| pairwise           |      1 | SNonce     | 交出 SNonce + 自己的 RSN IE |
| msg3 | AP→STA | ACK\|MIC\|INSTALL\|SECURE |      2 | ANonce     | 下发加密的 GTK，要求装密钥  |
| msg4 | STA→AP | MIC \| pairwise           |      2 | （通常空） | 确认装好                    |

两条「不明显但必须」的规则：

1. **msg2 的计数与 msg1 相同**，msg3 才 +1，msg4 与 msg3 相同。计数属于
   「AP 的这一轮 EAPOL-Key 对话」，不是「每帧 +1」。
2. **msg1 没有 MIC**（此时还没有 PTK，算不出 KCK）。所以 msg1 的防伪只能靠
   replay counter 与「我是否正在等 msg1」——这也是为什么 msg1 的重放最危险：
   它能把双方拖回握手开头（拒绝服务），或者让 STA 用旧 ANonce 派生一把没用的 PTK。

本地 IDF 的对照实现：`wpa_supplicant_process_1_of_4` 在
`components/wpa_supplicant/src/rsn_supp/wpa.c:704`，
`wpa_supplicant_process_3_of_4` 在 `:1506`，
MIC 校验在 `wpa_supplicant_verify_eapol_key_mic`（`:1937`）。

### 26.4.2 重放计数：为什么必须「严格递增」

802.11i 的规则是：每条**新的** EAPOL-Key 帧带来一个**更大**的 replay counter；
重传帧带同一个计数，但必须与上次**逐字节相同**（含 MIC）。本章采用最保守的
实现（`src/wpa2.zig:316`）：

```zig
pub fn replayAccept(last: u64, incoming: u64) bool {
    return incoming > last;   // 相等也拒：库里没有「重传判定」这一层
}
```

保守是有代价的：真实网络偶尔会重传 msg3（AP 没收到 msg4），严格递增会把它判成
`BadReplay`，导致重来一轮。这个代价是可接受的——重来一轮只是慢几百毫秒，
而接受一个旧计数会让**旧的 GTK 被重新装回去**，那是安全问题。

hostap 的对应实现能看到同样的意图（`wpa.c:2237`）：

```c
if (sm->rx_replay_counter_set &&
    os_memcmp(key->replay_counter, sm->rx_replay_counter,
              WPA_REPLAY_COUNTER_LEN) <= 0) { ... 拒绝 ... }
```

注意 `<= 0`——它也是「不大于就拒」。`WPA_REPLAY_COUNTER_LEN` 是 8
（`wpa_common.h:21`），与本章的 `u64` 大端编码一致。

### 26.4.3 顺序机：四种错误分开报

本章把 STA 侧的行为写成四个方法（`src/wpa2.zig:337` 起），每种错误一个类型：

| 方法       | 前提状态       | 检查                                      | 错误                                |
| ---------- | -------------- | ----------------------------------------- | ----------------------------------- |
| `recvMsg1` | idle/msg1_seen | ACK=1、MIC=0、计数前进                    | `BadKeyInfo`/`BadReplay`/`BadOrder` |
| `sendMsg2` | msg1_seen      | 带 MIC、计数 == last                      | `BadKeyInfo`/`BadReplay`/`BadOrder` |
| `recvMsg3` | msg2_sent      | ACK\|MIC\|INSTALL\|SECURE、计数 == last+1 | `BadKeyInfo`/`BadReplay`/`BadOrder` |
| `sendMsg4` | msg3_seen      | 带 MIC、计数 == last                      | `BadKeyInfo`/`BadReplay`/`BadOrder` |

「把错误分开」不是为了好看，而是因为**响应不同**：

- `BadOrder`：对面乱序，通常意味着两侧状态不同步 → 重来一轮；
- `BadReplay`：可能有人在重放 → 丢弃并计数，必要时断开重连；
- `BadKeyInfo`：对面实现有问题（或缺 INSTALL） → 记录、断开；
- `BadMic`：**密码错了**或帧被篡改 → 直接失败，不要重试（重试只会继续错）。

判据 ④ 与 ⑤ 分别钉住「旧计数」与「顺序错」：

```text
check: replay accept(1,2)=1 same(2,2)=0 back(2,1)=0 msg1_twice=BadReplay:1 rejects=1 ok=1
check: 4way order msg2_early=1 msg4_early=1 msg3_skip=1 msg3_nokeyinfo=1 ok=1
```

判据 ④ 的细节值得看：同一条 msg1 第二次到达时，状态已经是 `msg1_seen`
（顺序允许），但计数相等 → 必须是 `BadReplay` 而不是 `BadOrder`。这条判据
能让「把重放检查删掉、只留顺序检查」的实现失败。

判据 ⑤ 的四种错都在同一行里：

- `msg2_early`：msg2 在 msg1 之前 → `BadOrder`
- `msg4_early`：msg4 在 msg3 之前 → `BadOrder`
- `msg3_skip`：msg3 计数 = 3 而期望 2 → `BadReplay`
- `msg3_nokeyinfo`：msg3 缺 INSTALL 位 → `BadKeyInfo`

四个都命中才 `ok=1`。任何一条被写成「凡是失败就返回同一个错误」的实现，
这一行都会出 `0`。

### 26.4.4 时序图（离线版）

```text
STA                                    AP
 |  ───────────── idle ──────────────  |
 |  start → scan                          |
 |  scan_done → auth                      |
 |  auth_ok → assoc                       |
 |  assoc_ok → fourway                    |
 |                                        |
 |  <── msg1  replay=1 ANonce  (ACK) ───  |   recvMsg1: 计数 0→1
 |  ──── msg2  replay=1 SNonce  (MIC) ──> |   sendMsg2
 |  <── msg3  replay=2 ANonce  (+GTK) ──  |   recvMsg3: 计数 1→2
 |  ──── msg4  replay=2         (MIC) ──> |   sendMsg4 → done
 |                                        |
 |  fourway_ok → connected                |
```

本章状态机的 `fourway` 阶段只回答「4-way 有没有按顺序完成」，不处理 GTK 解密
（那是 CCMP 的事，本章不做）。判据 ⑨ 验证 `fourway_ok` 之后进入 `connected`。

---

## 26.5 WPA3-SAE：dragonfly 的一句话原理，和本章做到哪

### 26.5.1 一句话原理

WPA2-PSK 的口令派生是**离线可暴力**的：抓到一次 4-way 就能拿 PMK 去猜口令，
猜对了 MIC 就对上，全程不需要 AP 参与。WPA3-SAE 换掉了这一步：

> 口令不再派生成一把静态密钥，而是通过 **dragonfly** 变成曲线上的一个点（PWE），
> 两端各发一个 commit（标量 + 元素），只有**真的在跟对端交互**才能算出共享密钥。
> 攻击者每猜一次口令，都必须先当一次「在线客户端」——于是离线字典攻击不成立。

代价是：每次连接都要做椭圆曲线运算，而且必须**抗侧信道**（标量乘的时间不能
泄漏口令的信息）。这两件事是 SAE 实现的主体。

### 26.5.2 本章实现的是「除 EC 点运算以外的全部字节层」

`src/sae.zig` 的顶部有两条表，自检会把条数打出来（`read: sae subset
implemented=6 unimplemented=6`）。实现的部分：

| 步骤      | 公式（H = SHA-256，group 19）                                    | 本工程位置        |
| --------- | ---------------------------------------------------------------- | ----------------- |
| pwd-seed  | `HMAC-SHA256(MAX(addr)‖MIN(addr), password‖LE16(counter))`       | `sae.zig:275`     |
| pwd-value | `sha256_prf_bits(pwd-seed, "SAE Hunting and Pecking", p, 256)`   | `sae.zig:297`     |
| F_p 归约  | `x_candidate = pwd-value mod p`（256 位逐位长除法）              | `sae.zig:184/199` |
| F_q 加法  | `(sc + pc) mod n`                                                | `sae.zig:215`     |
| keyseed   | `HKDF-Extract(salt = 0³², ikm = k) = HMAC-SHA256(0³², k)`        | `sae.zig:259`     |
| KCK‖PMK   | `KDF-Hash-Length(keyseed, "SAE KCK and PMK", (sc+pc) mod n)`     | `sae.zig:235/331` |
| PMKID     | `L((sc+pc) mod n, 0, 128)` = 前 16 字节                          | `sae.zig:331`     |
| confirm   | `HMAC-SHA256(KCK, LE16(send-confirm) ‖ sc ‖ elem ‖ psc ‖ pelem)` | `sae.zig:350`     |

字段布局照抄本机 IDF 的 hostap 实现，所以每个公式都能对照到源码行：

- `sae_pwd_seed_key()`（`components/wpa_supplicant/src/common/sae.c:122`）把两个 MAC
  按 `os_memcmp > 0` 排成 `MAX||MIN` 当 **HMAC 的 key**；
- `sae.c:353` 的 `hmac_sha256_vector(addrs, sizeof(addrs), 2, addr, len, pwd_seed)`
  里，消息是 `password || counter`；
- `sae.c:149` 的 `sha256_prf_bits(pwd_seed, SHA256_MAC_LEN, "SAE Hunting and Pecking", prime, ...)`
  就是 pwd-value；
- `sae_derive_k_ecc()`（`sae.c:1377`）里 `k` 是共享点的 **x 坐标**
  （`crypto_ec_point_to_bin(sae->tmp->ec, K, k, NULL)`）——不是「哈希一下 commit 字段」，
  这是常见误解；
- `sae_derive_keys()`（`sae.c:1462`）做 keyseed → KCK‖PMK；
- `sae_cn_confirm()`（`sae.c:2208`）注释里直接写了
  `CN(key, X, Y, Z, ...) = HMAC-SHA256(key, D2OS(X) ‖ D2OS(Y) ‖ …)`；
- `send-confirm` 是 LE16 且从 0 递增（`sae.c:2313-2316`）。

`sha256_prf_bits` 的构造是

```text
HMAC-SHA256(K, LE16(i) ‖ label ‖ data ‖ LE16(bits))     i 从 1 开始
```

（`components/wpa_supplicant/src/crypto/sha256-prf.c:39/54/58/79`）。
注意它与 WPA2 的 PRF **三处不同**：hash 是 SHA-256、计数器从 1 开始、
计数器与长度都是 LE16 且**在两端**。

### 26.5.3 本章没有实现的部分（逐条，不假装）

| 未实现                                        | 为什么本章不做                                                      |
| --------------------------------------------- | ------------------------------------------------------------------- |
| EC 点运算（PWE 的 y、`scalar-op`、`elem-op`） | 需要 P-256 完整实现 + 求平方根 + 选点；工作量远大于字节层，且易错   |
| Lagrange/sqrt 选点                            | 同上：`y² = x³ + ax + b` 的平方根与「取哪一支」都是独立算法         |
| 恒定时间（const-time）实现                    | hostap 用 `const_time_*` 抹平循环次数与分支；本章的循环次数是公开的 |
| H2E（WPA3 R3 的 hash-to-element）             | 另一套 PWE 派生（RFC 9380 风格），与 hunting-and-pecking 并存       |
| 组协商 / rejected-groups                      | 需要组列表与降级规则，属于「策略」而非「字节层」                    |
| FFC 群（5/14/15/16）                          | 素数更大、编码不同；本章只做 group 19                               |

`k` 与两个 commit 元素在判据里都是**固定字节串**（`src/vectors.zig` 里
`sae_k` / `sae_scalar_own` / `sae_element_own` …）：真实实现里它们来自点乘，
本章把「从哪来」换成「给了什么」，就能单独验证「之后怎么用」。

### 26.5.4 一个诚实的观察：P-256 的 hunting 循环几乎只跑一轮

hunting-and-pecking 的循环本来是为了「pwd-value 恰好 ≥ p 时换一个 counter」。
但 P-256 的 `p` 与 `2²⁵⁶` 只差 2²²⁴ 量级：

```text
p = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
```

随机 256 位值落到 `p` 之上的概率约 **2⁻³²**。所以实测 `counter` 恒为 1——
判据 ⑥ 打印的 `pwd-value` 是 counter=1 的结果，而 `ctr=1` 断言的是
「counter=2 也能算出向量里的另一个值」（说明 counter 真的进了哈希）。

这不是设计缺陷，是 P-256 的性质。循环真正起作用的是 group 5 那种
3072 位的 FFC 群（素数离 2³⁰⁷² 远得多），本章不实现它们。

### 26.5.5 向量与判据

固定输入（`src/vectors.zig`，`tools/vectors.py` 可复现）：

```text
password   = "correct horse battery staple"
STA/AP     = 02:aa:bb:cc:dd:ee / 02:11:22:33:44:55
pwd-seed(counter=1) = 63ab6f8392ff2824d8a75c9c403bfab5236ee87311808791fd1de89a151fc2e7
pwd-seed(counter=2) = 28b74f836a38f8873180135ad68e8e6ffaf76f7df679d100b989b6769a0de406
pwd-value(counter=1)= 559ea05d3c0ff84d26d110202680503ee2d736cdf11ea82e92ddb961b4328ef9
k          = 8f2c1d4b7a9e63550c4b3a291807f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d
scalar_own = 7b1f4c2a9d3e50618273a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9
scalar_peer= 1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f801
scalar_sum = 954a8877fbadc0e31517597b9dbfe1022446688aacced0f31537597b9dbfe0fa
keyseed    = a9e90d74962c362eb32de5a283b6769d2abd397837fdf5b66b2b00c0d0741cc9
KCK        = 047c1f688fc5fe70b32d1d4b063b8acef284df930c16c6d213bb5f866c79046a
PMK        = d22b52d05c699fa37d0d7c8de70fa30a2f63e4d924b194ef59f7ca650d2d6702
PMKID      = 954a8877fbadc0e31517597b9dbfe102          ← scalar_sum 前 16 字节
confirm(A) = 6a643b15ba978398a4ce707bc8fa324ad3a749a69084eb51d4ef7911371043e3
confirm(S) = 6cdc0a4e16a4007fa0c5758acb555113c3be9583942c7d31ff6d1b481450fdbc
```

板侧两条判据（⑥ 确定性与基域归约，⑬ 派生与篡改）：

```text
check: sae pwd-seed=63ab6f8392ff2824 pwd-value=559ea05d3c0ff84d det=1 ctr=1 modp=1 modq=1 ovf=1 ok=1
check: sae derive kck=047c1f688fc5fe70 pmkid=954a8877fbadc0e3 kdf=1/1/1/1 confirm=1/1 tamper_rej=1 ok=1
```

`det=1` 是同输入同输出、`ctr=1` 是 counter 进哈希、`modp=1` 是五个基域边界、
`modq=1` 是标量加法向量、`ovf=1` 是「0xff..ff + 1 = 2²⁵⁶」的溢出用例（见 26.5.6）。
`kdf=1/1/1/1` 是 keyseed / KCK / PMK / PMKID 四个向量各自命中；
`confirm=1/1` 是两端 confirm 各自命中；`tamper_rej=1` 是把 confirm 改一位后
校验必须失败。

### 26.5.6 基域归约：为什么值得单独测

`pwd-value` 是一个 256 位值，要变成 x 坐标必须对 `p` 取模。本章没有用「大数库」，
而是写了一个 33 字节宽的逐位长除法（`src/sae.zig:184`）：

```text
r = 0
for 每个 bit（从最高位到最低位）:
    r = (r << 1) | bit
    if r >= m: r -= m
```

256 步 × 33 字节，正确性依赖三个细节：**33 字节**（移位后可能到 2·m−1，需要 257 位）、
**从最高位开始**、以及**借位的去向**。前两个容易写反，第三个最阴：

> 当被减数带着第 257 位（`r[0] == 1`，即 `r = 2²⁵⁶ + low`）时，低 32 字节
> 减 `m` 会**借位**——借的正是 `r[0]` 那一位。把这笔借位清掉，结果才是
> `r − m`；忽略它，结果就差 2²⁵⁶。

这条路径只在输入是**33 字节宽数**（`scalarAddModQ` 的和溢出 256 位）时可达：
32 字节输入处理到第 i 位（i ≤ 255）时，被除数本身就是前 i 位的值、小于 2²⁵⁵，
所以前缀余数恒 < 2²⁵⁵，移位后仍 < 2²⁵⁶，永远碰不到 `r[0]`。所以判据 ⑥ 专门喂了
`0xff..ff + 0x00..01 = 2²⁵⁶` 这一组（`ovf=1`，期望 `2²⁵⁶ mod n =
00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaaf`）。
这正是本章开发过程中真实踩到的坑：先加这条用例，测试**在 Debug 下断言失败**，
修完 `subWide` 才通过——不是「写完就绿」。

两个容易漏掉的边界输入：

```text
in = 0xffff…ffff (2²⁵⁶−1)  → 0x00000000fffffffeffffffffffffffffffffffff000000000000000000000000
in = p                     → 0
in = p + 1                 → 1
in = p + 0x0123456789abcdef→ 0x0123456789abcdef
in = 2²⁵⁵                  → 原样（< p）
```

如果只测 `pwd-value < p` 那种输入（概率 1−2⁻³²），归约函数**永远不会执行减法**，
写错的实现也能通过——这是「随机测试覆盖不到边界」的典型例子。

---

## 26.6 连接状态机与事件环形队列

### 26.6.1 八个状态，七个事件

`src/conn.zig` 的状态（`read: fsm states=8`）：

```text
idle → scan → auth → assoc → fourway → connected
                    ↑                        │
                    └──── reconnect ←── link_lost
                             │
                             └──(超过上限)──→ failed
```

事件种类（`read: fsm events=7`）：`scan_done`、`auth_ok`、`assoc_ok`、
`fourway_ok`、`link_lost`、`backoff_expired`、`gave_up`。

设计与真实 IDF 事件的对应关系（不是依赖，是形状对照）：

| 本章事件     | IDF 对应（`esp_wifi_types_generic.h`）                        |
| ------------ | ------------------------------------------------------------- |
| `scan_done`  | `WIFI_EVENT_SCAN_DONE`（`:1251`）                             |
| `fourway_ok` | `WIFI_EVENT_STA_CONNECTED`（`:1254`）之后（4-way 完成）       |
| `link_lost`  | `WIFI_EVENT_STA_DISCONNECTED`（`:1255`）+ `reason`（`:1353`） |
| `gave_up`    | 上层策略（IDF 不提供，需要应用自己定）                        |

`reason` 的数值尤其值得记住（`esp_wifi_types_generic.h`）：

```text
WIFI_REASON_MIC_FAILURE            = 14   (:134)   → 口令错 / 帧被改
WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT = 15   (:135)   → 4-way 卡住
WIFI_REASON_NO_AP_FOUND            = 201  (:170)   → 扫描不到
WIFI_REASON_ASSOC_FAIL             = 203  (:172)   → 关联被拒
```

这三个数字是「真实连接」时把本章状态机接上去的钥匙：`reason=14` 应该落到
`BadMic`（不要重试），`reason=15` 应该落到 `BadReplay`/超时（可以重来一轮），
`reason=201` 应该直接进入退避（不重试同一信道）。

### 26.6.2 为什么「丢最旧」而不是「丢最新」

环形队列容量 8（`conn.queue_capacity`），写满时的语义是**覆盖最旧的一条**并
`dropped += 1`（`src/conn.zig:102`）：

```zig
pub fn push(self: *EventQueue, ev: Event) PushResult {
    self.pushed += 1;
    if (self.len < queue_capacity) { /* 追加 */ return .queued; }
    self.buf[self.head] = ev;                    // 覆盖最旧
    self.head = (self.head + 1) % queue_capacity;
    self.dropped += 1;
    return .dropped_oldest;
}
```

两种语义各有道理，选择「丢最旧」是因为**消费者要的是最新状态**：
如果队列里积了 8 条旧事件（`scan_done` ×8），第 9 条 `link_lost` 被丢掉，
消费者就会以为「还在扫描」，从而永远等不到断线处理。丢最旧保证
「最新的状态一定在队列里」，而「丢了 3 条」这个计数提醒你队列不够快。

判据 ⑫ 同时断言四个数字（`src/selftest.zig:456`）：

```text
check: queue cap=8 pushed=11 dropped=3 head_arg=3 tail_arg=10 push_full=dropped_oldest ok=1
```

`head_arg=3` 是关键：投了 arg=0..10 共 11 条，最后留下的是 3..10 共 8 条。
如果实现是「满了就拒」(`rejected`)，`dropped` 会是 3 但 `tail_arg` 会是 7；
如果是「丢最新」，`head_arg` 会是 0。三个数字一起才唯一确定语义。

### 26.6.3 判据 ⑧⑨：状态迁移必须能被「走错」验证

```text
check: fsm auth->assoc start=1 scan=1 auth=1 state=assoc reauth=0 idle_auth=0 ok=1
check: fsm fourway->connected assoc=1 fourway=1 done=1 state=connected reset=1 extra=1 ok=1
```

`reauth=0` 与 `idle_auth=0` 是**反向**断言：已经在 `assoc` 时再收一个 `auth_ok`
不迁移；在 `idle` 时直接 `auth_ok` 也不迁移。只测正向路径的实现（「事件来了就
往下走」）会在这两个位置返回 1，判据失败。

第二条判据的顺序也是刻意的：先把 `retries` 人为设成 3，**再**调用
`onFourWayOk()`。`reset=1` 断言这次真正的迁移把失败计数清零了；
`extra=1` 断言随后再收一个 `fourway_ok`（此时已经 `connected`）**不迁移**、
计数也仍然是 0。如果反过来写（先完成再设 3），`reset=1` 就永远不会被执行到——
判据会变成「打印了一个没人检查的 3」。

---

## 26.7 重连：退避、抖动、上限、风暴抑制

### 26.7.1 三个参数与一条曲线

```zig
// src/conn.zig:141
pub fn backoffMs(retry: u8) u32 {
    if (retry == 0) return 0;
    const shift: u5 = @intCast(@min(retry - 1, 3));
    return @min(backoff_base_ms << shift, backoff_cap_ms);   // 1000 → 2000 → 4000 → 8000
}
```

序列：`1000 / 2000 / 4000 / 8000 / 8000`（第 5 次起撞上限，`backoffMs(200)` 也是 8000）。
板侧原文：

```text
check: backoff base=1000/2000/4000/8000/8000 jitter=1096/2068/4024/8086/8100 span<=125 cap=8000 ok=1
```

### 26.7.2 抖动：为什么必须加，加了之后为什么还要「可复现」

同一批设备断电重启后会在同一秒一起重连（重连风暴 / thundering herd）。
如果所有设备的退避曲线完全一样，它们会**永远同步**：一起等 1 秒、一起撞 AP、
一起失败、一起等 2 秒……抖动把它们的相位打散。

本章用 32 位 LCG 生成 0..125 ms 的加性抖动（`src/conn.zig:157`）：

```zig
pub fn backoffWithJitter(retry: u8, seed: *u32) u32 {
    const base = backoffMs(retry);
    if (base == 0) return 0;
    return base + (lcgNext(seed) >> 16) % (jitter_span_ms + 1);  // jitter_span_ms = 125
}
```

LCG 而不是 TRNG，是为了**日志可对拍**：同样的 seed 得到同样的抖动序列
（`jitter=1096/2068/4024/8086/8100`）。真实产品应该用 TRNG，判据不变
（只断言 `base ≤ v ≤ base+125`）。

注意抖动是**加性**的（只往上加），不是对称的 ±12.5%：这样「最短等待」
仍然是标称退避时间，不会出现「比设计更快的重连」。

### 26.7.3 上限与放弃

`max_retries = 5`：第 6 次断线直接 `failed`，不再等。判据 ⑪：

```text
check: retries max=5 at_cap_state=reconnect retries=6 6th=failed capped=1 ok=1
```

`at_cap_state=reconnect` 证明第 5 次仍然是 `reconnect`（还在等），
`retries=6 / 6th=failed` 证明第 6 次落到了 `failed`。
`capped=1` 断言「最后一次的等待时间等于上限 8000」——如果实现忘了封顶，
第 5 次会是 16000。

放弃之后怎么办？本章不做「永久放弃」：`failed` 是给上层看的信号，
上层可以重置 `retries` 再试（比如收到用户手动连接）。状态机只负责
「现在不能自动重连了」这件事。

### 26.7.4 风暴抑制的第三条腿：不要在 scan 阶段重试

退避只解决「重连太快」。另一条风暴来源是**扫描 → 失败 → 立刻扫描**：
如果 `scan_done` 之后发现没有合适候选就马上重新扫描，射频会一直忙。
真实实现里 `WIFI_REASON_NO_AP_FOUND`（201）应该进入退避，而不是重扫——
本章的状态机把「扫描失败」也走 `onLinkLost`（因为它最终表现为没有可用 AP），
所以同一个退避曲线同时管住这两种循环。

---

## 26.8 与 ch25 ABI 垫片的关系：独立重写，仅签名级

ch25 交付的是「blob 要调用方提供什么」：`HostApi`（4 项函数指针 + 版本 + 长度）、
`Event`（20 字节：kind/flags/len/seq/payload[12]）、`Errno`（13 个值）。
本章交付的是「连上之后状态怎么走」。两章**不互相 import**，也不共享结构体：

| 维度       | ch25（blob 边界）                     | 本章（连接管理）                         |
| ---------- | ------------------------------------- | ---------------------------------------- |
| 事件类型   | `blob_abi.Event`（20 B，带 payload）  | `conn.Event`（8 B：kind + arg）          |
| 队列       | `adapter` 里的 8 × Event = 160 B      | `EventQueue` 8 × 8 B = 80 B              |
| 错误       | `Errno`（13 个，映射 `esp_err_t`）    | `Wpa2Error` / `HsError` / `ScanError`    |
| 正确性判据 | ABI 布局、注册表、队列背压、泄漏      | 密码学向量、顺序机、退避、状态迁移       |
| 共同点     | 无 blob / 无链路：`not_linked` 是行为 | 无射频 / 无 AP：状态机停在 injected 事件 |

真正接起来时，「接线」只有三处，都不需要改两章的结构体：

1. **事件翻译**：blob 的 `WIFI_EVENT` → `conn.EventKind`（一个 switch）；
2. **载荷**：`blob_abi.Event.payload` 里的 BSSID/SSID/状态码 → `conn` 的入参；
3. **错误映射**：`esp_err_t`/`reason` → `BadMic`/`BadReplay`/超时（26.6.1 的表）。

为什么要**独立重写**而不是「复用 ch25 的 Event」？因为两章的消费者不同：
ch25 的消费者是 ABI 边界（要固定布局、要 20 字节、要给 blob 填 payload），
本章的消费者是状态机（只要 kind + 一个小整数）。硬把两者塞进一个结构体，
结果是两边都为对方付代价——ch25 会多出一个「状态机专用」字段，
本章会被迫携带 12 字节用不到的 payload。

---

## 26.9 工程走读

### 26.9.1 浏览页深链表

| 文件                 | 在章节里的作用                                              | 浏览器                                                                                 |
| -------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `README.md`          | 工程根：验证状态、快速开始、向量来源、待闭环项              | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/README.md)          |
| `build.zig`          | 目标串、链接脚本、`zig build test`（20 例）                 | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界、6 条 ASSERT          | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t`（project_name = ch26…）+ naked `_start`    | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/start.zig)      |
| `src/main.zig`       | banner → 自检 → verdict → `wfi`                             | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/main.zig)       |
| `src/wpa2.zig`       | PMK/PTK、EAPOL 编解码、MIC、重放、4-way 顺序机（26.3/26.4） | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/wpa2.zig)       |
| `src/sae.zig`        | SAE 字节层 + 256 位取模（26.5）                             | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/sae.zig)        |
| `src/conn.zig`       | 状态机、事件队列、退避、扫描候选（26.2/26.6/26.7）          | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/conn.zig)       |
| `src/vectors.zig`    | 判据常数表（编译期十六进制解码）                            | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/vectors.zig)    |
| `src/selftest.zig`   | 板侧 13 条判据（26.10 的每一行都来自这里）                  | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/selftest.zig)   |
| `src/host_tests.zig` | 主机侧 20 个用例                                            | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/host_tests.zig) |
| `tools/vectors.py`   | 交叉实现向量生成器（26.3–26.5 的每个数字）                  | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/tools/vectors.py)   |
| `tools/flash.sh`     | 按 `flash_args` 烧录，替换 factory 应用行                   | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/tools/flash.sh)     |

### 26.9.2 代码规模

| 文件                 | 行数 | 角色                                             |
| -------------------- | ---: | ------------------------------------------------ |
| `src/wpa2.zig`       |  409 | PMK/PTK/EAPOL/MIC/重放/4-way                     |
| `src/sae.zig`        |  374 | pwd-seed/pwd-value/F_p/F_q/KCK/PMK/PMKID/confirm |
| `src/conn.zig`       |  322 | 状态机、队列、退避、扫描候选                     |
| `src/vectors.zig`    |  151 | 常数表                                           |
| `src/selftest.zig`   |  573 | 板侧 13 条判据                                   |
| `src/host_tests.zig` |  521 | 主机 20 例                                       |

（行数以 `wc -l` 实测，2026-11-13；`src/selftest.zig` 含 13 条判据与三行 `read:` 读数。）

### 26.9.3 结构长度与 `.bss`

本章的所有状态都是**栈上的局部变量**（每个判据一份，互不污染），
所以 `.bss` 只有 16 字节：

| 对象              |  大小 | 说明                                           |
| ----------------- | ----: | ---------------------------------------------- |
| `conn.Machine`    | 104 B | 状态 + 重试计数 + seed + 内嵌 80 B 队列        |
| `conn.EventQueue` |  80 B | 8 × `Event`（8 B/条）                          |
| `conn.Event`      |   8 B | `kind: u8` + `arg: u32`（含对齐）              |
| `wpa2.KeyFrame`   |  64 B | key_info/replay/nonce/mic（不含 key data）     |
| `wpa2.FourWay`    |  80 B | 状态 + last_replay + ANonce + SNonce + rejects |
| `sae.Keys`        | 144 B | scalar_sum/keyseed/KCK/PMK/PMKID               |

`.text` 40516 B、`.data` 0、`.bss` 16 B（`riscv32-esp-elf-size` 实测）。
PBKDF2 的 4096 轮 HMAC-SHA1 是本工程最大的执行路径，但它是**循环**，不是体积。

### 26.9.4 `idf-bootstrap/` 的位置

`idf-bootstrap/` 只产 bootloader、分区表与 `flash_args`，不链接 Zig 代码
（`main/app_main.c` 是空实现）。它的 `sdkconfig.defaults` 里刻意**不启用**
Wi-Fi 组件——这个工程本来就不该有射频。`build/` 被 `.gitignore` 忽略，
新克隆里需要自己 `idf.py --preview set-target esp32s31 && idf.py build` 一次。

---

## 26.10 上板自检输出

### 26.10.1 镜像

```text
$ env -u LD_LIBRARY_PATH $ZIG build -Dtarget=riscv32-freestanding-eabihf \
    -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
（退出 0，无输出）

$ python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
    --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
Creating ESP32-S31 image...
Merged 2 ELF sections.
Successfully created ESP32-S31 image.

$ python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin | grep 'DROM, IROM'
      0  0x08370  0x40000020  0x00000018  DROM, IROM
      3  0x01a68  0x40020020  0x00010018  DROM, IROM
```

正好两条 `DROM, IROM`：`0x40000020`（IROM，段 0）与 `0x40020020`（DROM，段 3）。
整个镜像 72368 字节（`image-info` 的 `Image size` 行），入口 `0x40008282`。

完整的分段表（`image-info` 原文节选）解释了中间那个「大段」是什么：

```text
Segment   Length   Load addr   File offs  Memory types
      0  0x08370  0x40000020  0x00000018  DROM, IROM
      1  0x00006c  0x2f000000  0x00008390  DRAM, BYTE_ACCESSIBLE, IRAM
      2  0x07c0c  0x00000000  0x00008404  PADDING
      3  0x01a68  0x40020020  0x00010018  DROM, IROM
```

段 2 是 `PADDING`，长度 0x7c0c（31756 字节）。它存在的原因写在链接脚本里：
bootloader 检查的是**页内偏移同余**而不是「段必须在 ORIGIN 上」

```c
/* components/bootloader_support/src/esp_image_format.c:904 */
if (map_segment
        && ((segment_data_offs % mmu_page_size) != (load_addr % mmu_page_size))) {
```

`0x40020020` 的页内偏移是 `0x20`（页大小 64 KiB），所以 DROM 段的**文件偏移**
也必须是 `0x20 mod 0x10000`——于是 elf2image 从 `0x8404` 一直填到 `0x10018`，
中间 31756 字节全部记为 PADDING。这也解释了为什么 `.flash.rodata` 只有 0xf70
（3952 字节）而 DROM 段是 0x1a68（6760 字节）：后者还包含 `.eh_frame_hdr`
（0x214）与 `.eh_frame`（0x8e4）——Zig 生成的展开表，被同一段带走。

`.section` 实测（`riscv32-esp-elf-readelf -SW zig-out/bin/app.elf`）：

```text
[ 1] .flash.text    PROGBITS  40000020  001020  008370  AX  16
[ 2] .flash.rodata  PROGBITS  40020020  00a020  000f70  AMS 16
[ 5] .trap_ram      PROGBITS  2f000000  00c000  00006c  AX  4
[ 6] .data          PROGBITS  2f000070  00c070  000000  WA  16
[ 7] .bss           NOBITS    2f000070  00c070  000010  WA  16
```

本章没有 AES 查表，`.rodata` 不需要 64 字节对齐，段起点就是 `ORIGIN(drom)`
（对照 ch23 的 `0x40020040`）。

### 26.10.2 banner（日志前五行）

```text
ch26-wifi-connection-wpa2-wpa3 | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: wpa2-psk pmk/ptk/mic + 4way order + sae subset + conn fsm (13 checks)
note: no radio, no AP, no link - ch17 ethernet and ch25 blob still pending
host: 20 unit tests via 'zig build test'
```

第一行就是工程身份（`esp_app_desc_t.project_name` 也是这串）。抓到别人的 banner
必须重烧重抓，不得改名。

### 26.10.3 十三条判据（`logs/ch26-boot.log` 原文）

```text
check: pbkdf2 rfc6070 c1=0c60c80f c2=ea6c014d c1_ok=1 c2_ok=1 bad_len=1/1 ok=1
check: ptk prf512=0cb59d207218375a prf384_prefix=1 swap_invariant=1 kck=0cb59d207218375a ok=1
check: eapol mic len=121 mic=73e895d1efbcfc3c vec=1 verify=1 tamper=1 wrong_kck=1 decode=1 ok=1
check: replay accept(1,2)=1 same(2,2)=0 back(2,1)=0 msg1_twice=BadReplay:1 rejects=1 ok=1
check: 4way order msg2_early=1 msg4_early=1 msg3_skip=1 msg3_nokeyinfo=1 ok=1
check: sae pwd-seed=63ab6f8392ff2824 pwd-value=559ea05d3c0ff84d det=1 ctr=1 modp=1 modq=1 ovf=1 ok=1
check: scan in=5 out=3 merged_rssi=-52 order=-40,-52,-88 open_dropped=1 ok=1
check: fsm auth->assoc start=1 scan=1 auth=1 state=assoc reauth=0 idle_auth=0 ok=1
check: fsm fourway->connected assoc=1 fourway=1 done=1 state=connected reset=1 extra=1 ok=1
check: backoff base=1000/2000/4000/8000/8000 jitter=1096/2068/4024/8086/8100 span<=125 cap=8000 ok=1
check: retries max=5 at_cap_state=reconnect retries=6 6th=failed capped=1 ok=1
check: queue cap=8 pushed=11 dropped=3 head_arg=3 tail_arg=10 push_full=dropped_oldest ok=1
check: sae derive kck=047c1f688fc5fe70 pmkid=954a8877fbadc0e3 kdf=1/1/1/1 confirm=1/1 tamper_rej=1 ok=1
```

判据与要求的对应：

| #   | 要求                       | 行内证据                                                      |
| --- | -------------------------- | ------------------------------------------------------------- |
| ①   | PBKDF2 测试向量            | `c1=0c60c80f c2=ea6c014d`、`bad_len=1/1`                      |
| ②   | PTK 派生向量               | `prf512=0cb59d20…`、`prf384_prefix=1`、`swap_invariant=1`     |
| ③   | EAPOL MIC 正/反例          | `mic=73e895d1efbcfc3c`、`vec=1 verify=1 tamper=1 wrong_kck=1` |
| ④   | 重放计数拒绝旧帧           | `same(2,2)=0 back(2,1)=0`、`msg1_twice=BadReplay:1`           |
| ⑤   | 消息 2/4 顺序错误被拒      | `msg2_early=1 msg4_early=1 msg3_skip=1 msg3_nokeyinfo=1`      |
| ⑥   | SAE commit 确定性          | `pwd-seed=63ab6f83…`、`det=1 ctr=1`、`modp=1 modq=1 ovf=1`    |
| ⑦   | 扫描去重/排序              | `in=5 out=3 merged_rssi=-52 order=-40,-52,-88`                |
| ⑧   | AUTH→ASSOC 迁移            | `state=assoc`、`reauth=0 idle_auth=0`                         |
| ⑨   | 4WAY 完成→CONNECTED        | `state=connected`、`reset=1 extra=1`                          |
| ⑩   | 重连退避序列 1/2/4/8 上限  | `base=1000/2000/4000/8000/8000`、`jitter=1096…8100`           |
| ⑪   | 超过重试上限→FAILED        | `retries=6 6th=failed`、`capped=1`                            |
| ⑫   | 事件队列满丢最旧且计数     | `pushed=11 dropped=3 head_arg=3 tail_arg=10`                  |
| ⑬   | SAE 派生与篡改拒绝（附加） | `kck=047c1f68… pmkid=954a8877…`、`tamper_rej=1`               |

### 26.10.4 读数与总结

```text
read: sizes pmk=32 ptk=48 mic=16 eapol=95 sae_scalar=32 sae_elem=64
read: sae subset implemented=6 unimplemented=6 (EC ops, h2e, groups: see ch26 26.5)
read: fsm states=8 events=7 backoff cap=8000ms max_retries=5
checks: passed=13 failed=0 total=13
main: verdict=pass, wifi connection layer verified off-link (wfi)
main: halting (wfi)
```

三行 `read:` 不是判据（它们没有 `ok=`），作用是让日志能被人肉眼对拍：

- 第一行把结构长度摊开（rv32：PMK 32、PTK-CCMP 48、MIC 16、EAPOL 固定部分 95、
  SAE 标量 32、元素 64）；
- 第二行是 26.5 的「做了什么/没做什么」条数（6/6）——这条读数的价值是
  **把「没实现」写在日志里**，而不是藏在注释里；
- 第三行是状态机形状（8 状态 / 7 事件 / 上限 8000ms / 最多 5 次重试）。

### 26.10.5 主机侧 20 例

```text
$ env -u LD_LIBRARY_PATH $ZIG build test --summary all
Build Summary: 3/3 steps succeeded; 20/20 tests passed
test success
+- run test 20 pass (20 total)
```

覆盖：RFC 6070 四条、PMK 与长度边界、PRF 块序列与前缀稳定、PTK-384/512 与
端点顺序无关、EAPOL 编码对齐向量、四条坏帧拒绝、MIC 正/反例（篡改 key data、
错 KCK、改 MIC 本身）、重放计数（含 u64 回绕）、4-way 全绿路径与六种拒绝路径、
SAE pwd-seed/pwd-value 与 counter、F_p 归约五个边界 + 16 个随机输入、
F_q 加法交换律与单位元、KCK/PMK/PMKID、confirm 与 send-confirm/篡改、
扫描去重/过滤/排序/缓冲不足、同 rssi 按信道排序、状态机正反向迁移、
退避序列与抖动范围与 tick 快进、放弃逻辑与 `gave_up` 事件、队列回绕与 pop 顺序。

板侧只跑其中 13 条，是因为 rv32 上 PBKDF2 的 4096 轮是「最贵的一条」，
而且串口日志要能一眼对完。**两边的向量与断言是同一份**（都 import
`src/vectors.zig`），差别只在测试框架。

---

## 26.11 边界：真实扫描 / 连接 / 拿 IP 需要什么

本章的十三条判据全部离线。要变成真实链路，需要四件事，每件都有判据：

### 26.11.1 扫描到真实 AP

**做什么**：ch25 的真实 blob 链接 + `esp_wifi_init` / `esp_wifi_start`，
然后 `esp_wifi_scan_start`（`esp_wifi.h:557`）与 `esp_wifi_scan_get_ap_records`
（`:642`）。

**判据**：

1. `esp_wifi_scan_get_ap_num`（`:624`）返回的数目与 `selectCandidates` 的输入条数一致；
2. 判据 ⑦ 的输入换成真实 `wifi_ap_record_t`（BSSID/RSSI/authmode 三个字段），
   输出仍然满足「去重 + 过滤 open + rssi 降序」；
3. 板侧日志出现真实 BSSID（`check:` 行里出现 `xx:xx:xx:...`，而不是构造值）。

### 26.11.2 真实 4-way handshake

**做什么**：`esp_wifi_set_config`（`:1052`）配 SSID/密码，`esp_wifi_connect`
（`:495`）发起连接，打开 hostap 的调试打印。

**判据**：

1. 串口出现 msg1/msg2/msg3/msg4 四条，且 `wpa.c:1937` 的 MIC 校验全部通过；
2. `WIFI_EVENT_STA_CONNECTED`（`esp_wifi_types_generic.h:1254`）到达；
3. 本章 `conn.Machine` 的 `fourway_ok` **来自真实回调**（把 blob 事件翻译成
   `EventKind`），而不是自检注入；
4. 故意填错密码：串口出现 `WIFI_REASON_MIC_FAILURE = 14`（`:134`），
   并且状态机落到 `BadMic`（**不重试**）——这条最能证明「错误分类」的价值。

### 26.11.3 拿到 IP

**做什么**：依赖 ch17（以太网/链路）与 ch19（DHCP）。在 Wi-Fi 上，DHCP 走的是
同一个 IP 栈，只是链路层换成 802.11。

**判据**：DHCP ACK 之后 `conn.State.connected` 且 ch19 的地址分配成功；
在这之前，任何「拿到 IP」的说法都不成立。

### 26.11.4 SAE 的真实实现

**做什么**：把 `src/sae.zig` 的 `unimplemented` 六条逐条消掉：

1. EC 点运算（PWE 的 y、`scalar-op`、`elem-op`）；
2. 平方根 / Lagrange 选点；
3. 恒定时间实现（`const_time_select_*` 等价物）；
4. H2E（若走 WPA3 R3）；
5. 组协商与 rejected-groups；
6. FFC 群。

**判据**：与 hostap 的 `sae.c` 在**同一组输入**上逐字节一致（pwd-seed、pwd-value、
commit-scalar、commit-element、KCK、confirm），并且用一组真实 WPA3 路由器
完成一次 SAE 握手。

---

## 事实来源

| #   | 事实                                                                      | 来源（文件:行 / 命令）                                                                                                                                                                                                                                                               |
| --- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | PSK = PBKDF2-HMAC-SHA1(passphrase, SSID, 4096, 32)，出自 802.11-2004 H.4  | `components/wpa_supplicant/src/crypto/sha1-pbkdf2.c:69-70`（注释）、`:72`（`pbkdf2_sha1` 定义）                                                                                                                                                                                      |
| 2   | WPA2 PRF 是 802.11i 8.5.1.1 的 HMAC-SHA1 计数器构造，计数器从 0 起        | `components/wpa_supplicant/src/crypto/sha1-prf.c:17`（注释）、`:30`（`sha1_prf`）、`:33`（`u8 counter = 0`）                                                                                                                                                                         |
| 3   | `sha256_prf_bits` = HMAC-SHA256(K, LE16(i)‖label‖data‖LE16(bits))，i 从 1 | `components/wpa_supplicant/src/crypto/sha256-prf.c:39`（注释）、`:54`（定义）、`:58`（`u16 counter = 1`）、`:79`（`WPA_PUT_LE16(counter_le, counter)`）                                                                                                                              |
| 4   | EAPOL-Key 描述符的字段顺序与非对齐标志                                    | `components/wpa_supplicant/src/common/wpa_common.h:207`（`struct wpa_eapol_key`）、`:208`（descriptor type）、`:210`（key_info）、`:212`（replay_counter）、`:217`（key_mic）、`:218`（key_data_length）                                                                             |
| 5   | key_info 的位含义：ACCEPT/ACK/MIC/SECURE/INSTALL                          | 同文件 `:196`（INSTALL）、`:198`（ACK）、`:199`（MIC）、`:200`（SECURE）、`:192`（KEY_TYPE）                                                                                                                                                                                         |
| 6   | 重放计数长度 8 字节                                                       | 同文件 `:21`（`WPA_REPLAY_COUNTER_LEN 8`）                                                                                                                                                                                                                                           |
| 7   | msg1/msg3 的处理函数                                                      | `components/wpa_supplicant/src/rsn_supp/wpa.c:704`（`wpa_supplicant_process_1_of_4`）、`:1506`（`..._3_of_4`）                                                                                                                                                                       |
| 8   | MIC 校验函数                                                              | 同文件 `:1937`（`wpa_supplicant_verify_eapol_key_mic`）                                                                                                                                                                                                                              |
| 9   | 重放计数「不大于就拒」                                                    | 同文件 `:2237-2239`（`os_memcmp(key->replay_counter, sm->rx_replay_counter, WPA_REPLAY_COUNTER_LEN) <= 0`）                                                                                                                                                                          |
| 10  | SAE 的 pwd-seed 用 MAX‖MIN 地址当 HMAC key                                | `components/wpa_supplicant/src/common/sae.c:122`（`sae_pwd_seed_key`）                                                                                                                                                                                                               |
| 11  | SAE pwd-value 用 `sha256_prf_bits("SAE Hunting and Pecking")`             | 同文件 `:149`（`sha256_prf_bits(pwd_seed, SHA256_MAC_LEN, "SAE Hunting and Pecking", prime, ...)`）                                                                                                                                                                                  |
| 12  | SAE pwd-seed 的消息是 `password‖counter`                                  | 同文件 `:353`（`hmac_sha256_vector(addrs, sizeof(addrs), 2, addr, len, pwd_seed)`）                                                                                                                                                                                                  |
| 13  | SAE 的 `k` 是共享点的 x 坐标，不是 commit 字段的哈希                      | 同文件 `:1377`（`sae_derive_k_ecc`）、`:1399`（`crypto_ec_point_to_bin(sae->tmp->ec, K, k, NULL)`）                                                                                                                                                                                  |
| 14  | SAE keyseed = HKDF-Extract(0³², k)，KCK‖PMK 用 `"SAE KCK and PMK"`        | 同文件 `:1462`（`sae_derive_keys`）、`:1562`（`sae_kdf_hash(..., "SAE KCK and PMK", ...)`）                                                                                                                                                                                          |
| 15  | SAE confirm = CN(KCK, send-confirm, ...) = HMAC-SHA256                    | 同文件 `:2208`（`sae_cn_confirm` 及其注释）、`:2242`（`hkdf_extract` 调用）                                                                                                                                                                                                          |
| 16  | send-confirm 是 LE16 且递增                                               | 同文件 `:2312-2315`（`if (sae->send_confirm < 0xffff) sae->send_confirm++; wpabuf_put_le16(buf, sae->send_confirm);`）                                                                                                                                                               |
| 17  | SAE 的 KCK/PMK/PMKID 长度                                                 | `components/wpa_supplicant/src/common/sae.h:18`（KCK 32）、`:19`（PMK 32）、`:21`（PMKID 16）                                                                                                                                                                                        |
| 18  | IDF 的 Wi-Fi 事件枚举                                                     | `components/esp_wifi/include/esp_wifi_types_generic.h:1251`（`WIFI_EVENT_SCAN_DONE`）、`:1254`（`STA_CONNECTED`）、`:1255`（`STA_DISCONNECTED`）                                                                                                                                     |
| 19  | 断线原因码：MIC 失败 14、4-way 超时 15、找不到 AP 201、关联失败 203       | 同文件 `:134`、`:135`、`:170`、`:172`；断线结构里的 `reason` 字段在 `:1353`                                                                                                                                                                                                          |
| 20  | 扫描阈值结构（authmode + rssi）                                           | 同文件 `:379`（`wifi_scan_threshold_t`）、`:572`（`wifi_sta_config_t.threshold`）、`:599`（`wifi_sta_config_t` 结束）                                                                                                                                                                |
| 21  | 扫描/连接 API 原型                                                        | `components/esp_wifi/include/esp_wifi.h:557`（`esp_wifi_scan_start`）、`:624`（`..._get_ap_num`）、`:642`（`..._get_ap_records`）、`:495`（`esp_wifi_connect`）、`:1052`（`esp_wifi_set_config`）                                                                                    |
| 22  | `esp_app_desc_t` 的字段偏移（本章 `start.zig` 的 comptime 断言）          | `components/esp_app_format/include/esp_app_desc.h:27`（magic）、`:31`（project_name）、`:34`（idf_ver）、`:35`（sha256）、`:38`（mmu_page_size）、`:39`（spi_flash_mode）                                                                                                            |
| 23  | SRAM 起点与可用末端                                                       | `components/esp_system/ld/esp32s31/memory.ld.in:19`（`SRAM_START 0x2F000000`）、`:23`（`SRAM_SIZE = SRAM_SEG_END - SRAM_START`）；`ld.hp_mem_defs:9`（`SRAM_SEG_END 0x2F07AFC0`）                                                                                                    |
| 24  | bootloader 的段地址同余检查                                               | `components/bootloader_support/src/esp_image_format.c:904`（`segment_data_offs % mmu_page_size != load_addr % mmu_page_size`）                                                                                                                                                       |
| 25  | ROM 里 `ets_printf` / `ets_delay_us` 的地址                               | `components/esp_rom/esp32s31/ld/esp32s31.rom.ld:24`、`:30`                                                                                                                                                                                                                           |
| 26  | Zig 0.17.1 的 PBKDF2 入口（PRF 是类型参数）                               | `lib/zig/std/crypto/pbkdf2.zig:53`；导出在 `lib/zig/std/crypto.zig:192`（`pwhash.pbkdf2` 在 `:343`）                                                                                                                                                                                 |
| 27  | Zig 的 HMAC-SHA1 与 SHA-1 长度                                            | `lib/zig/std/crypto/hmac.zig:7`（`HmacSha1`）、`:27/:33/:62/:66`（create/init/update/final）；`lib/zig/std/crypto/Sha1.zig:10`（block 64）、`:11`（digest 20）                                                                                                                       |
| 28  | 常量时间比较                                                              | `lib/zig/std/crypto/timing_safe.zig:12`（`pub fn eql`）                                                                                                                                                                                                                              |
| 29  | 本工程 PMK/PRF/PTK 的实现位置                                             | `src/wpa2.zig:73`（`derivePmk`）、`:89`（`prf`）、`:120`（`derivePtk`）、`:141`（`splitPtk`）                                                                                                                                                                                        |
| 30  | 本工程 EAPOL 编解码与 MIC                                                 | `src/wpa2.zig:231`（`encode`）、`:260`（`decode`）、`:288`（`computeMic`）、`:301`（`verifyMic`）                                                                                                                                                                                    |
| 31  | 本工程重放与 4-way 顺序机                                                 | `src/wpa2.zig:316`（`replayAccept`）、`:337`（`FourWay`）、`:358/:370/:379/:390`（recvMsg1/sendMsg2/recvMsg3/sendMsg4）                                                                                                                                                              |
| 32  | 本工程 256 位取模与 SAE 派生                                              | `src/sae.zig:108`（`sub`）、`:158`（`subWide`，含第 257 位借位吸收）、`:184`（`reduceWide`）、`:199`（`mod`）、`:215`（`scalarAddModQ`）、`:235`（`kdfHash`）、`:259`（`hkdfExtract`）、`:275`（`pwdSeed`）、`:297`（`pwdValue`）、`:331`（`deriveKeys`）、`:350`（`deriveConfirm`） |
| 33  | 本工程状态机与队列                                                        | `src/conn.zig:102`（`EventQueue.push`）、`:141`（`backoffMs`）、`:157`（`backoffWithJitter`）、`:183`（`selectCandidates`）、`:224`（`Machine`）、`:245/:252/:283/:301`（start/onScanDone/onLinkLost/tick）                                                                          |
| 34  | 判据实现在哪                                                              | `src/selftest.zig:38`（`check`）、`:70/:104/:133/:176/:203/:248/:312/:345/:372/:402/:429/:456/:483`（①–⑬）、`:551`（`run`）                                                                                                                                                          |
| 35  | 镜像分段与 `.section` 实测                                                | `python -m esptool ... image-info`（72368 B，4 段，含 `0x07c0c PADDING`）、`riscv32-esp-elf-readelf -SW zig-out/bin/app.elf`、`riscv32-esp-elf-size`（text 40516 / data 0 / bss 16）                                                                                                 |

规范/文档条文（不是本机文件）：

| 资料                   | 用到的部分                                                          |
| ---------------------- | ------------------------------------------------------------------- |
| IEEE 802.11i-2004      | Annex H.4（PSK 派生）、8.5.1.1（PTK 用 PRF）、8.5.2（4-way 与 MIC） |
| IEEE 802.11-2020       | 12.4（SAE）、12.7.1.2（KDF / PRF 构造）                             |
| IEEE 802.1X-2010       | 11.9（EAPOL-Key 描述符与 MIC 计算规则）                             |
| RFC 2898 / RFC 6070    | PBKDF2 构造与 PBKDF2-HMAC-SHA1 测试向量                             |
| RFC 5869               | HKDF-Extract 的定义（本章只用到 Extract）                           |
| ESP-IDF Wi-Fi 编程指南 | `wifi_scan_threshold_t`、`WIFI_EVENT_*`、断线 `reason` 的语义       |

---

## 自查清单

- [x] `zig build test --summary all` 退出 0，`20/20 tests passed`（主机 x86_64 / Zig 0.17.1）
- [x] 每条密码学判据都有「出处」两选一：RFC 6070 / 802.11i 公开向量，或
      `tools/vectors.py` 的双实现交叉值
- [x] `python3 tools/vectors.py` 可重跑，输出与 `src/vectors.zig` 逐字节一致
- [x] 交叉编译退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 恰好两条 `DROM, IROM`：`0x40000020`、`0x40020020`
- [x] `flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'` 成功
- [x] 串口 banner 首行是 `ch26-wifi-connection-wpa2-wpa3 | form B …`（确认不是同伴的镜像）
- [x] 13 条 `check:` 全 PASS，`checks: passed=13 failed=0 total=13`
- [x] `main: verdict=pass` 后停在 `wfi`
- [x] 章节与 README 引用的每一行 `check:`/`checks:`/`main:` 都与 `logs/ch26-boot.log` 逐字一致
- [x] 判据条数（13）在 `build.zig`、`src/main.zig`、`src/selftest.zig`、`linker/s31.ld`、
      README、本章六处一致
- [x] 没有任何「连上 AP / 扫描到 N 个 AP / 拿到 IP」的结论
- [x] SAE 的「没实现」清单在 `src/sae.zig` 的 `unimplemented` 表里，并被打进日志
      （`read: sae subset implemented=6 unimplemented=6`）
- [x] 未修改索引、套件 README、BRINGUP 或任何既有章节/工程
- [ ] 浏览页深链需主 agent 跑 `npm run code-site` 重新生成后才可点（本章不跑
      code-site / quartz build / git 写操作）
- [ ] 索引 `content/zig-esp32-s31/index.md` 的 ch26 行与「第 1–25 章已完成」需主 agent
      同步成 wikilink / 第 1–26 章（索引不在本章的可写范围内）
- [ ] 真实 blob 链接（判据见 26.11.1，承接 ch25 26.12.1）
- [ ] 真实扫描与 4-way（判据见 26.11.2）
- [ ] 拿到 IP（判据见 26.11.3）
- [ ] SAE 的 EC/恒定时间实现（判据见 26.11.4）

---

## 下一章预告

下一章是 [[ch27-ble-802154-boundary|第二十七章：BLE 与 802.15.4 的边界]]：
把本章的纪律搬到另外两种射频上——BLE（GATT/ATT 的字节层、广播与连接的边界）
与 802.15.4（Thread 的 MAC 层、帧格式与入网边界）。

它们与 Wi-Fi 的处境一样：MAC/PHY 在 blob 里，协议的可测部分在外面。
ch27 会回答同一个问题：**在没有射频的前提下，哪些字节层与状态机今天就能断言？**

对于本章，「连接」这个词到此为止只是状态机里的一个枚举值。要把 `connected`
变成「真的能收发」，还差 ch17 闭环、ch25 的真实 blob 链接，以及 26.11 的
四条判据。这也是整个系列的节奏：**先把能证明的证明完，再诚实地标记剩下的。**

> [!info] 系列导航
>
> 上一章：[[ch25-wifi-blob-boundary|第二十五章：Wi-Fi blob 边界与 ABI 垫片]]
>
> **本章：第二十六章：Wi-Fi 连接管理与 WPA2/WPA3**
>
> 下一章：[[ch27-ble-802154-boundary|第二十七章：BLE 与 802.15.4 的边界]]
>
> 系列索引：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]
