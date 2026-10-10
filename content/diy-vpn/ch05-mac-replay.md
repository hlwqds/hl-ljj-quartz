---
title: "手写 VPN（五）：完整性与防重放——MAC、AEAD 与滑动窗口"
date: 2026-10-10 12:00:00
description: "给隧道装第二个零件：MAC 的构造（HMAC 的 ipad/opad 双轮结构）、为什么必须 Encrypt-then-MAC、帧格式升级为 [计数器|密文|标签]；防重放滑动窗口（IPsec AH 同款算法）逐位讲解；实测三种攻击注入——比特翻转被 MAC 拦截、旧帧重放被窗口拒绝、窗口内乱序放行。"
tags: [vpn, crypto, hmac, mac, replay, series]
---

> [!info] 手写 VPN 系列 0. [[diy-vpn|系列索引]] 1. [[ch01-vpn-anatomy|第一章]] 2. [[ch02-udp-tunnel|第二章]] 3. [[ch03-tun-device|第三章]] 4. [[ch04-stream-cipher|第四章]] 5. **第五章：完整性与防重放**

# 手写 VPN（五）：完整性与防重放——MAC、AEAD 与滑动窗口

加密之后，攻击者读不到内容了，但 ch01 威胁模型的第 2 条还没对付：**他能改**。UDP 时代的攻击菜单至少三样——比特翻转（改密文一个字节，赌解密后落到关键字段）、重放（把截获的旧帧原样再发）、乱序调包。这一章装上两个零件堵死它们：**MAC**（消息认证码，防改）与**滑动窗口**（防重放），顺路认识工程上更优雅的合体形态 AEAD。收尾时我们的隧道帧就升级成了 `[计数器][密文][标签]` 的安全信封。

---

## 5.1 MAC：给密文贴防伪封条

MAC（Message Authentication Code）是带密钥的哈希：只有持钥者能算出/验证的摘要。标准构造是 **HMAC**（RFC 2104），它教会我们"密钥怎么拌进哈希"的正确姿势——两轮哈希、内外两个填充：

```text
HMAC-SHA256(key, msg):
  k'  = key 补零到 64 字节（SHA-256 的块大小）
  inner = SHA256( (k' ⊕ ipad 0x36×64) ∥ msg )     ← 内轮：钥匙拌进来再吞消息
  outer = SHA256( (k' ⊕ opad 0x5c×64) ∥ inner )   ← 外轮：再拌一次防长度扩展攻击
  输出 32 字节标签
```

为什么绕两轮而不直接 `SHA256(key ∥ msg)`？因为 SHA-2 家族是可扩展的：知道 `H(key∥msg)` 和 msg，无需密钥就能算出 `H(key∥msg∥append)` 的正确值——直接拼接等于把伪造门焊在哈希的可扩展性上。HMAC 的双轮结构把这个性质拆掉了（原理与实现细节见 [[vpn-deep-dive|姊妹篇]]第三章的密码学基础）。

**为什么 MAC 要盖在密文上**（Encrypt-then-MAC）而不是明文上（MAC-then-Encrypt）？两种顺序历史上都有人用，但 EtM 是唯一被证明安全的组合：MtE 让接收方**先验 MAC 前必须先解密**，把解密器暴露在未认证数据面前——SSL/TLS 二十年间的 padding oracle 攻击（POODBE 一族）全是这个顺序的利息。规矩一句话：**先加密，再对密文盖章，验章通过才允许解密**。

## 5.2 帧格式升级：安全信封

把 ch02 的帧格式穿上 ch04+本章的两件衣服：

```text
明文时代（ch02）：  [type][session][seq][payload……]
安全信封（现在）：  [ctr(8B)][ciphertext(=type+session+payload 加密后)][tag(32B)]
                    └ nonce 的一半  ┘└ 只有持钥者能解                   └ HMAC 盖在
                       另一半是会话密钥                                     密文+ctr 上
```

发送方：`ctr++ → chacha20(key, nonce=会话级, ctr) 加密 → hmac(封条密钥, ctr ∥ 密文)`。接收方三步走：先验标签（**常量时间比较**，防时序侧信道），再查重放窗口（5.3），最后才解密。注意标签覆盖了 ctr——**计数器被改，MAC 立刻爆**，攻击者连"换个旧计数器配旧密文"的路都被焊死。

## 5.3 滑动窗口：防重放的位图机关

UDP 不保序，所以不能"计数器必须严格 +1 才收"——正常网络里乱序包大量存在，太严会把隧道掐死。工程解法是 IPsec AH 同款**滑动窗口**（WireGuard 也是它）：

```text
收方状态：最高已收计数器 h = 1000，窗口宽 W = 64（一个 uint64 位图）

收到 ctr：
  ctr > h        → 窗口右移 (ctr - h) 格（高位补 0），标记该位，收下
  h-W < ctr ≤ h  → 查位图：该位是 0？标记并收下（窗口内乱序，正常放行）
                    该位是 1？重放，拒收 ❌
  ctr ≤ h-W      → 落在窗口左侧之外的旧包，重放，拒收 ❌
```

三行规则同时满足"不误伤乱序"与"拒绝重放"：窗口内的包按位记账，窗口外的历史一律作废。配套工程的注入实验把三个分支全踩了一遍：乱序（986、995、1001 依次到，全收）、重放（重发已标记的 995，拒）、窗口外旧包（ctr=900，拒）。

## 5.4 AEAD：一步到位的合体形态

我们的"ChaCha20 + HMAC-SHA256（EtM）"是教科书式的**组合式**安全通道。现代协议普遍改用 **AEAD**（Authenticated Encryption with Associated Data）：一个原语同时完成加密 + 认证，密文与"关联数据"（帧头等明文字段）一起纳入认证，边界情况（nonce 误用、填充歧义）由密码学家统一兜底。WireGuard 用 ChaCha20-Poly1305，TLS 1.3 用 AES-GCM 或 ChaCha20-Poly1305——**语义上就是我们这两章的合体压缩包**。手写一次组合式再去看 AEAD，才知道它替你免掉了哪些自己想不周全的坑（这也是本系列"先造轮子再看真轮子"路线的价值）。

> [!tip] 🧪 配套实验：vpn-labs/ch05-secure-channel
> HMAC-SHA256 手写（官方向量验证）+ 安全信封的完整收发端，内置三种攻击注入模式：`--tamper`（翻转密文一个比特 → MAC 拒收）、`--replay`（重发旧帧 → 滑动窗口拒绝）、`--reorder`（窗口内乱序 → 放行），全部真实运行留档。源码直达：[secure.c（代码浏览）](/static/code/#/vpn-labs/ch05-secure-channel/secure.c)、[hmac.c](/static/code/#/vpn-labs/ch05-secure-channel/hmac.c)、[完整工程](/static/code/#/vpn-labs/ch05-secure-channel/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/vpn-labs/ch05-secure-channel)。

## 5.5 小结

- MAC 是带钥哈希；HMAC 双轮 ipad/opad 结构防的是 SHA-2 的长度扩展性；标签必须常量时间比较。
- 顺序铁律 Encrypt-then-MAC：先加密、对密文盖章、验章通过才解密；MAC-then-Encrypt 把解密器暴露给未认证数据，是 padding oracle 家族的温床。
- 标签要覆盖计数器：连"旧计数器配旧密文"的拼接路也焊死。
- 防重放用滑动窗口（IPsec AH/WireGuard 同款）：窗口内位图放乱序、拒重放，窗口外历史一律作废。
- AEAD 是加密+认证的合体原语（WireGuard 的 ChaCha20-Poly1305）——手写一遍组合式再学它，才知道它帮你兜了什么。

保密和防改都齐了，还剩最后一个难堪：**两边怎么拿到同一把密钥？** 总不能微信传文件吧。下一章手写 Diffie-Hellman 密钥交换，再当场演示不认证的 DH 如何被中间人一锅端——那是 VPN 安全里最经典的一课。[[ch06-key-exchange|第六章：密钥交换]]。
