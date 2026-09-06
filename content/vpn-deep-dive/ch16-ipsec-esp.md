---
title: "VPN 技术深度探索 (十六)：AH 与 ESP 协议深度解析"
date: 2026-04-13
tags:
  [vpn, series, networking, security, ipsec, ah, esp, aead, aes-gcm, hmac, anti-replay, padding, iv]
description: "AH 与 ESP 协议深度解析——ESP 加密与认证流程、AES-GCM AEAD 模式、HMAC 完整性保护、防重放滑动窗口机制、ESP Padding 详解、IV/Nonce 处理、组合加密认证算法对比"
---

> [!info] VPN 技术深度探索系列 14. [[ch14-ipsec-overview|IPSec 体系概述]] 15. [[ch15-ipsec-ike|IKE 密钥交换]]
> **16. AH 与 ESP 协议（本章）** 17. [[ch17-ipsec-policy|IPSec 策略配置]] 18. [[ch18-ipsec-troubleshooting|IPSec 排错]]

---

## 1. AH 协议深度解析

### 1.1 AH 头结构

**AH（Authentication Header，IP 协议号 51）** 提供数据完整性和源认证，但不加密。

```
AH 头结构（RFC 4302）：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Next Header  |  Payload Len  |          RESERVED             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Security Parameters Index (SPI)               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Sequence Number Field                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                Integrity Check Value-ICV (variable)           +
|                    (必须是 32 位的整数倍)                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Payload Len 字段含义：AH 载荷长度，单位为 **32 位（4字节）**，值为 AH 头总长度/4 - 2。
示例：AH 头 24 字节（ICV 96位=12字节），Payload Len = 24/4 - 2 = 4。

### 1.2 AH 认证范围

AH 的 ICV 覆盖：

- **外层 IP 头中的不变字段**（Immutable Fields）
- **AH 头本身**（ICV 字段置 0 计算）
- **上层载荷**（IP 头之后的全部内容）

IP 头中的**可变字段**在计算 ICV 时置 0（因为这些字段在传输过程中可能被修改）：

```
IPv4 可变字段（AH 计算时置 0）：
  - TOS（可能被 DSCP 重标记）
  - Flags（可能被分片）
  - Fragment Offset
  - TTL（每跳减 1）
  - Header Checksum

IPv4 不变字段（AH 保护）：
  - Version、IHL、Total Length
  - Identification（若分片则为可变）
  - Protocol
  - Source Address
  - Destination Address（若有路由选项则为可变）
```

### 1.3 AH 的局限性

```
AH 问题总结：

1. 不加密：内容对中间节点可见
2. 不兼容 NAT：
   AH 保护 IP 头中的源/目地址，而 NAT 会修改这些字段
   → ICV 验证必然失败
3. 无法单独穿越有状态防火墙：
   AH 是 IP 协议号 51，不是 TCP/UDP
   → 防火墙难以建立状态条目

实际场景：
  AH 几乎只在不经过 NAT 的受控网络中使用
  大多数现代部署直接使用 ESP（含认证）即可满足需求
```

---

## 2. ESP 协议深度解析

### 2.1 ESP 完整结构

**ESP（Encapsulating Security Payload，IP 协议号 50）** 是 IPSec 的主力协议，提供加密 + 认证。

```
ESP 完整封装结构（传输模式）：

+--------+--------+--------+--------+
|          ESP Header                |  ← 明文（用于接收方查找 SA）
|   SPI (32 bit)  | Seq Number (32b) |
+--------+--------+--------+--------+
|          IV / Nonce                |  ← 明文（加密算法参数）
|   8-16 字节（取决于算法）            |
+========+========+========+========+
|         Payload Data               |  ←  ┐
|    (原始载荷，可变长度)               |    │ 加密
+--------+--------+--------+--------+    │ 范围
|    Padding (0-255 字节)             |    │
+--------+--------+--------+--------+    │
|  Pad Length    |  Next Header      |  ← ┘
+========+========+========+========+
|    Integrity Check Value (ICV)     |  ← 认证范围：ESP Header + IV + 加密内容
|    (变长，HMAC-SHA256-128 = 16B)   |
+--------+--------+--------+--------+
```

### 2.2 字段详解

**SPI（Security Parameters Index）**：

- 32 位整数，与目的 IP + 协议联合标识接收方 SA
- 范围 1～0xFFFFFFFF（0 保留，1～255 保留给本地使用）

**Sequence Number（序列号）**：

- 从 1 开始，每个 ESP 包递增 1
- 用于**防重放攻击**
- 溢出（到 2^32）时必须重新协商 SA
- 扩展序列号（ESN，RFC 4304）：64 位序列号，避免高速链路频繁重协商

**IV/Nonce（初始化向量/随机数）**：

- AES-CBC 模式：8 字节 IV（随机，不重复）
- AES-CTR/GCM 模式：8 字节隐式 Nonce + 4 字节 salt
- 必须对每个包唯一，否则破坏加密安全性

**Padding（填充）**：

- 作用 1：块对齐（AES-CBC 需要 16 字节对齐）
- 作用 2：流量分析对抗（填充使报文长度统一）
- Pad Length：填充字节数（0-255）
- Next Header：被保护的上层协议（传输模式：TCP/UDP/ICMP；隧道模式：IP=4）

**ICV（Integrity Check Value）**：

- HMAC-SHA256：截断为 128 位（16 字节）
- AES-GCM：内置 128 位认证标签（ICV）
- AES-GMAC：仅认证，不加密

---

## 3. 加密算法详解

### 3.1 AES-CBC 模式（传统方式）

```
工作原理：
  CBC（Cipher Block Chaining）：每个明文块与前一个密文块 XOR 后再加密

  M1  M2  M3  M4
  │   │   │   │
  ↓   ↓   ↓   ↓
IV→XOR XOR XOR XOR
   │   │   │   │
  AES AES AES AES
   │   │   │   │
  C1  C2  C3  C4

ESP + AES-CBC + HMAC-SHA256 处理顺序：
  1. 填充对齐到 16 字节边界
  2. 生成随机 IV（8 字节）
  3. AES-CBC 加密（密钥 128/256 位）
  4. 计算 HMAC-SHA256（覆盖 ESP Header + IV + 密文）
  5. 截断 HMAC 到 128 位作为 ICV
```

缺点：

- "先加密后认证"（Encrypt-then-MAC）需要两次独立运算
- 存在 Padding Oracle 攻击风险（若实现不当）
- 并行化能力差（CBC 解密可并行，加密不能）

### 3.2 AES-GCM 模式（AEAD，推荐）

**AES-GCM（Galois/Counter Mode）** 是 AEAD（Authenticated Encryption with Associated Data）算法，同时完成加密和认证。

```
AES-GCM 工作原理：

  ┌─────────────────────────────────────────────────────┐
  │  GCM = CTR 模式加密 + GHASH 认证                      │
  │                                                     │
  │  CTR 部分（加密）：                                   │
  │    Counter Block = IV(96bit) | Counter(32bit)       │
  │    KeyStream = AES(Key, Counter)                    │
  │    CipherText = PlainText XOR KeyStream             │
  │                                                     │
  │  GHASH 部分（认证）：                                  │
  │    覆盖 AAD（Associated Authenticated Data）          │
  │    + 密文                                            │
  │    → 128 位认证标签                                   │
  └─────────────────────────────────────────────────────┘

ESP + AES-256-GCM 中：
  IV 结构：4 字节 salt（SA 协商时固定）+ 8 字节 Explicit IV（每包随机/递增）
  Nonce  = salt | explicit_iv  （共 12 字节 = 96 位）
  AAD    = ESP Header（SPI + Sequence Number）
  认证标签 = 128 位（作为 ICV 附在包尾）
```

AES-GCM 的优势：

```
优势：
  1. 同时加密 + 认证，一次遍历数据
  2. 认证覆盖 ESP Header（AAD），SPI/序列号不可篡改
  3. AES-NI 硬件加速支持，性能远超 AES-CBC + HMAC
  4. 无 Padding Oracle 漏洞
  5. 可并行处理多个 Counter Block

性能对比（典型 10G 网卡，单核）：
  AES-256-CBC + HMAC-SHA256：约 2-3 Gbps
  AES-256-GCM：            约 8-12 Gbps（AES-NI）
```

> [!warning] AES-GCM Nonce 复用风险
> AES-GCM 若 Nonce 重复，将彻底破坏加密安全性（可恢复密钥！）。
> 实现时必须保证每个 SA 的每个包使用唯一 IV。
> SA 重协商（Rekey）时分配新的 salt，从根本上避免跨 SA 的 Nonce 冲突。

### 3.3 ChaCha20-Poly1305（RFC 8439）

对于没有 AES-NI 的低功耗设备（ARM、MIPS 路由器），ChaCha20-Poly1305 提供更好的软件性能：

```
ChaCha20（流密码）+ Poly1305（MAC）= AEAD
IKEv2 + ESP 支持：RFC 8221
Linux 内核：4.10+ 支持 chacha20poly1305
```

### 3.4 算法选择建议

```
优先级排序（2024+）：

1. AES-256-GCM-128        ← 首选，硬件加速，AEAD
2. AES-128-GCM-128        ← 128 位密钥，仍安全，速度更快
3. ChaCha20-Poly1305      ← 嵌入式/无 AES-NI 场景
4. AES-256-CBC + SHA-256  ← 兼容性需要时
5. AES-128-CBC + SHA-256  ← 不推荐

明确禁止：
  - DES（56 bit，已破解）
  - 3DES（112 effective bit，Sweet32 攻击）
  - RC4
  - MD5 认证
  - SHA-1 认证
  - NULL 加密（仅调试）
```

---

## 4. HMAC 完整性保护

当使用非 AEAD 算法（如 AES-CBC）时，需要独立的 HMAC 提供完整性保护。

### 4.1 HMAC 计算

```
HMAC-SHA256 计算：
  HMAC(K, m) = SHA256((K' XOR opad) || SHA256((K' XOR ipad) || m))

  K' = 若 K 长度 > 块大小（64字节），则 K' = SHA256(K)，否则 K' = K（补零到块大小）
  ipad = 0x36 重复 64 次
  opad = 0x5C 重复 64 次

ESP 中 HMAC 的覆盖范围：
  HMAC(auth_key, SPI | Seq | IV | 密文 | Padding | PadLen | NextHdr)
```

### 4.2 截断 HMAC（Truncated HMAC）

RFC 4868 规定 HMAC 输出需截断：

- HMAC-SHA-256-128：输出 256 bit，截断为 **128 bit**（16 字节）ICV
- HMAC-SHA-384-192：输出 384 bit，截断为 **192 bit**（24 字节）ICV
- HMAC-SHA-512-256：输出 512 bit，截断为 **256 bit**（32 字节）ICV

---

## 5. 防重放机制

### 5.1 重放攻击原理

```
攻击场景：
  攻击者嗅探 Alice → Bob 的 IPSec 包（转账请求）
  稍后重发该加密包
  若 Bob 无防重放保护，会再次执行转账
```

### 5.2 滑动窗口防重放

IPSec 使用**滑动窗口**算法防止重放：

```
发送方：
  每个 ESP 包的 Sequence Number 从 1 递增

接收方维护：
  R_Next = 期望的下一个序列号（窗口右边界 + 1）
  W      = 窗口大小（默认 64 位，推荐 128 位）

  窗口范围：[R_Next - W, R_Next - 1]

  新包到达（序列号 N）：
    ├── N < R_Next - W         → 丢弃（太旧）
    ├── R_Next - W ≤ N < R_Next → 检查位图，已见过则丢弃
    ├── N == R_Next - 1        → 最新期望包，正常处理
    └── N >= R_Next            → 接受，右移窗口

  位图（Bitmap）：
    窗口内每一位对应一个序列号
    1 = 已收到，0 = 未收到
```

示例（窗口大小 = 8）：

```
当前窗口：[5, 12]，R_Next = 13
位图：1110 1101（序列号 5-12，1=已收到）

收到 N=10：位图第6位=1 → 重放，丢弃
收到 N=14：N > R_Next → 接受，窗口右移变为 [6, 13]，R_Next=15
收到 N=3 ：N < 5（窗口左边界）→ 太旧，丢弃
```

### 5.3 序列号溢出处理

当序列号达到 2^32 - 1 时，**必须重新协商 SA**（Rekey）：

```
正常情况：软生命期（soft lifetime）在序列号耗尽前触发 Rekey
紧急情况：若未及时 Rekey，到达最大序列号后不得再发送包（丢弃）

扩展序列号（ESN）：RFC 4304
  使用 64 位序列号，只在 ESP 头传输低 32 位
  接收方根据当前窗口推断高 32 位
  适合高速链路（10G+）避免频繁 Rekey
```

---

## 6. ESP Padding 详解

### 6.1 为什么需要 Padding

```
原因 1：块密码对齐
  AES-CBC 块大小 16 字节，Payload + PadLen + NextHeader
  必须是 16 字节的整数倍

原因 2：对齐 ICV
  整个 ESP 载荷（含 Padding）要对齐到 32 位边界

原因 3：流量分析对抗（可选）
  将报文填充到固定长度，防止通过报文大小推断内容类型
```

### 6.2 Padding 规则

```
Padding 内容：从 1 开始递增的字节序列（可选随机）
              RFC 推荐：1, 2, 3, 4, ..., N（便于检测截断攻击）

例子（AES-CBC，16字节块）：
  有效载荷 = 10 字节
  PadLen = 1 字节 + NextHdr = 1 字节 → 已有 2 字节
  需填充：10 + 2 = 12，距下一个 16 的倍数差 4 字节
  → 填充 4 字节：0x01 0x02 0x03 0x04
  → PadLen = 4
  总计：10 + 4（padding）+ 1（PadLen）+ 1（NextHdr）= 16 字节 ✓
```

---

## 7. AH + ESP 组合使用

在极少数场景下，AH 和 ESP 可以组合使用，提供更强的保护：

```
AH + ESP 传输模式（外到内顺序）：
  IP | AH | ESP Header | IV | 加密(TCP/UDP) | ESP尾 | ESP-ICV | AH-ICV

AH + ESP 隧道模式：
  外IP | AH | ESP Header | IV | 加密(内IP + TCP/UDP) | ESP尾 | ESP-ICV | AH-ICV

AH 保护：外层 IP 头（不变字段）+ 整个 ESP 载荷
ESP 保护：内层载荷加密 + 认证
```

> [!note] 实际很少使用 AH + ESP 组合
> 现代 ESP 已经提供完整的加密和认证（AES-GCM 同时加密+认证），
> 单独 ESP 足以满足绝大多数安全需求。
> AH + ESP 只在特殊合规要求（需要保护外层 IP 头完整性）下才需要。

---

## 8. 协议开销对比

各种 IPSec 配置的额外字节开销（隧道模式）：

```
原始 IPv4 报文：
  外层 IP 头  = 20 字节
  ESP 头     = 8 字节（SPI 4B + Seq 4B）
  IV         = 8 或 16 字节（AES-GCM 8B，AES-CBC 16B）
  ESP 尾     = Padding + 2 字节（PadLen + NextHdr）
  ICV        = 16 字节（GCM-128）或 16 字节（HMAC-SHA256-128）
  NAT-T UDP  = 8 字节（若经过 NAT）

最小隧道开销（AES-GCM，无 Padding，无 NAT-T）：
  20（外IP）+ 8（ESP头）+ 8（IV）+ ~2（ESP尾）+ 16（ICV）= 54 字节

典型配置（AES-GCM + NAT-T）：
  20 + 8 + 8 + 8 + 4 + 16 = 64 字节额外开销

注：内层 IP 头（隧道模式）另 20 字节
→ 总额外开销约 84 字节，需确保 MTU 足够（建议设置 ESP MTU = 1400-1420）
```

---

## 9. 内核中的 ESP 处理路径

```
出站（xfrm_output）：

net/ipv4/xfrm4_output.c：
  xfrm_output()
    → xfrm_output_one()
      → x->type->output()     ← esp4_output()
        → esp_output_head()   ← 分配空间，写 ESP 头 + IV
        → esp_output_tail()   ← 调用 crypto subsystem 加密
          → crypto_aead_encrypt()  ← AES-GCM
            → aesni_gcm_enc()      ← AES-NI 汇编实现

入站（xfrm_input）：

net/xfrm/xfrm_input.c：
  xfrm_input()
    → x->type->input()         ← esp4_input()
      → crypto_aead_decrypt()  ← 解密 + 验证 ICV
      → esp_input_done2()      ← 防重放窗口检查
      → xfrm_parse_spi()       ← SPI 查找 SA
```

查看内核 ESP 统计：

```bash
# 查看 xfrm 错误统计
cat /proc/net/xfrm_stat

# 主要字段：
# XfrmInError         - 入站总错误数
# XfrmInAuthFailed    - ICV 验证失败（完整性错误）
# XfrmInStateSeqError - 序列号/防重放错误
# XfrmOutError        - 出站总错误数
# XfrmOutNoStates     - 无匹配 SA（触发 IKE 协商）
# XfrmInNoPols        - 无匹配 SPD 策略
```

---

## 10. 本章小结

```
AH vs ESP 速查：

AH (51)：
  认证范围：IP 头（不变字段）+ 载荷
  加密：无
  NAT：不兼容
  用途：极少使用（受控网络，无 NAT）

ESP (50)：
  认证范围：ESP 头 + 载荷（不含外层 IP 头）
  加密：是（AES-GCM 推荐）
  NAT：支持（UDP 4500 封装）
  用途：几乎所有 IPSec 部署

加密算法优先级：
  AES-256-GCM-128 > AES-128-GCM-128 > ChaCha20-Poly1305
  > AES-CBC + HMAC-SHA256（兼容性）
  禁止：DES、3DES、MD5、NULL

防重放：
  滑动窗口（默认 64 位）
  ESN（64 位序列号）适合高速链路

关键开销：
  隧道模式 ESP 典型额外开销 ~64 字节
  设置 MTU = 1400~1420 避免分片
```

---

## 参考资料

- RFC 4302: IP Authentication Header
- RFC 4303: IP Encapsulating Security Payload (ESP)
- RFC 4304: Extended Sequence Number (ESN) Addendum to IPSec DOI
- RFC 4106: The Use of Galois/Counter Mode (GCM) in IPSec ESP
- RFC 4868: Using HMAC-SHA-256, HMAC-SHA-384, and HMAC-SHA-512 with IPSec
- NIST SP 800-175B: Guide for Using Cryptographic Standards in the Federal Government
- Linux Kernel: net/ipv4/esp4.c, net/xfrm/xfrm_input.c
