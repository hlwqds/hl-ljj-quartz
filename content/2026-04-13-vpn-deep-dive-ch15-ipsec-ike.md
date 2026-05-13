---
title: "VPN 技术深度探索 (十五)：IKE 密钥交换协议"
date: 2026-04-13
tags: [vpn, series, networking, security, ipsec, ike, ikev1, ikev2, dpd, xauth, eap, main-mode, aggressive-mode]
description: "IKE 协议深度解析——IKEv1 主模式/野蛮模式报文交换过程、IKEv2 简化流程与新特性、DPD 死亡对等体检测、XAUTH/EAP 扩展认证、NAT 穿透（NAT-T）详解"
---

> [!info] VPN 技术深度探索系列
> 14. [[2026-04-13-vpn-deep-dive-ch14-ipsec-overview|IPSec 体系概述]]
> **15. IKE 密钥交换（本章）**
> 16. [[2026-04-13-vpn-deep-dive-ch16-ipsec-esp|AH 与 ESP 协议]]
> 17. [[2026-04-13-vpn-deep-dive-ch17-ipsec-policy|IPSec 策略配置]]
> 18. [[2026-04-13-vpn-deep-dive-ch18-ipsec-troubleshooting|IPSec 排错]]

---

## 1. 为什么需要 IKE

IPSec 的 SA（安全关联）需要共享密钥才能工作。手工配置密钥在大规模部署时不现实：
- 密钥管理复杂，难以定期轮换
- 无法实现完美前向保密（PFS）
- 无法自动协商算法参数

**IKE（Internet Key Exchange）** 解决了这个问题：在 IPSec 对等体之间**自动、安全地协商密钥和参数**。

```
IKE 协议演进：
  IKEv1  ← RFC 2409（1998），由 ISAKMP + Oakley + SKEME 组合而来
  IKEv2  ← RFC 7296（2014），完全重写，简化+增强
```

IKE 运行在 **UDP 端口 500**（或 NAT-T 时 4500），由用户空间守护进程（strongSwan charon、Libreswan pluto）处理，协商结果通过 Netlink 接口注入内核 SADB。

---

## 2. IKEv1 协议

IKEv1 分为两个阶段：

```
Phase 1（阶段一）：建立 ISAKMP SA（IKE 通道本身的安全关联）
  目标：认证对等体身份，建立安全的 IKE 通信信道

Phase 2（阶段二）：建立 IPSec SA（用于保护实际数据）
  目标：在 Phase 1 保护下协商 IPSec SA 参数
```

### 2.1 Phase 1 — 主模式（Main Mode）

主模式使用 **6 条消息**完成 IKE SA 协商：

```
Initiator                           Responder
    │                                    │
    │─── HDR, SA ───────────────────────→│  消息1：提议加密/认证算法
    │←── HDR, SA ────────────────────────│  消息2：应答选定算法
    │                                    │
    │─── HDR, KE, Ni ──────────────────→│  消息3：DH 公钥 + 随机数
    │←── HDR, KE, Nr ───────────────────│  消息4：DH 公钥 + 随机数
    │   (双方独立计算 DH 共享秘密)          │
    │                                    │
    │─── HDR*, IDi, AUTH ──────────────→│  消息5：身份 + 认证（加密）
    │←── HDR*, IDr, AUTH ───────────────│  消息6：身份 + 认证（加密）
    │                                    │
    │   IKE SA 建立完成                   │
```

消息 1-4 为明文，消息 5-6 用协商的密钥加密（`HDR*` 表示加密）。

**密钥材料派生**（Phase 1）：

```
DH 交换 → DH 共享秘密 g^xy
              ↓
SKEYID = prf(pre-shared-key, Ni | Nr)
              ↓
SKEYID_d = prf(SKEYID, g^xy | CKY-I | CKY-R | 0)  ← 用于派生 IPSec 密钥
SKEYID_a = prf(SKEYID, SKEYID_d | g^xy | ...)       ← IKE 消息认证
SKEYID_e = prf(SKEYID, SKEYID_a | g^xy | ...)       ← IKE 消息加密
```

### 2.2 Phase 1 — 野蛮模式（Aggressive Mode）

野蛮模式只用 **3 条消息**，但安全性更低：

```
Initiator                           Responder
    │                                    │
    │─── HDR, SA, KE, Ni, IDi ─────────→│  消息1：算法提议+DH+随机数+身份（明文！）
    │←── HDR, SA, KE, Nr, IDr, AUTH ────│  消息2：应答+认证
    │─── HDR, AUTH ────────────────────→│  消息3：确认
    │                                    │
    │   IKE SA 建立完成                   │
```

> [!warning] 野蛮模式的安全风险
> 1. **身份 IDi 以明文传输**（主模式中加密），可被嗅探
> 2. **容易受到离线字典攻击**：攻击者可捕获消息 1-2，然后离线暴力破解 PSK
> 3. 不支持身份保护
>
> 实际上仅在需要 PSK + 动态 IP 客户端时使用（无法用主模式的原因：主模式要求根据身份提前查找 PSK，动态 IP 无法提前知道身份）。
> **生产环境应尽量避免使用野蛮模式**。

### 2.3 Phase 2 — 快速模式（Quick Mode）

Phase 2 使用 **3 条消息**，在 IKE SA 保护下协商 IPSec SA：

```
Initiator                           Responder
    │                                    │
    │─── HDR*, HASH(1), SA, Ni [, KE] [, ID] ─→│  消息1：IPSec SA 提议
    │←── HDR*, HASH(2), SA, Nr [, KE] [, ID] ──│  消息2：应答选定参数
    │─── HDR*, HASH(3) ───────────────────────→│  消息3：确认
    │                                    │
    │   IPSec SA 建立（双向各一个）          │
```

可选字段：
- **KE（Key Exchange）**：若启用 PFS，则每次 Phase 2 都进行新的 DH 交换
- **ID（Identity）**：指定受保护的流量选择符（Traffic Selector）

**Phase 2 密钥派生**：

```
KEYMAT = prf+(SKEYID_d, [ g^xy | ] protocol | SPI | Ni | Nr)
            ↓
    分割为加密密钥 + 认证密钥
```

---

## 3. IKEv2 协议

IKEv2（RFC 7296）完全重新设计，解决了 IKEv1 的诸多问题。

### 3.1 IKEv2 核心改进

| 特性 | IKEv1 | IKEv2 |
|------|-------|-------|
| 协议复杂度 | ISAKMP + Oakley + SKEME 三部分拼接 | 统一规范 |
| 初始交换消息数 | 主模式 6 条 + 快速模式 3 条 | 最少 4 条完成 SA 建立 |
| NAT 穿透 | 扩展（RFC 3947） | 内置 |
| 移动性支持 | 无 | MOBIKE（RFC 4555） |
| 扩展认证 | XAUTH（非标准扩展） | EAP（内置，RFC 4306） |
| 可靠传输 | 无内置重传 | 内置请求/响应重传 |
| 多宿主 | 无 | MOBIKE 支持 |
| 流量选择符 | 单一 | 多个 TS（Traffic Selectors） |

### 3.2 IKEv2 初始交换（Initial Exchange）

IKEv2 的完整建立流程最少 **4 条消息**（2个往返）：

```
Initiator                           Responder
    │                                    │
    │─── IKE_SA_INIT(req) ─────────────→│
    │    [SA, KE, Ni, ...]               │
    │←── IKE_SA_INIT(resp) ─────────────│
    │    [SA, KE, Nr, CERTREQ, ...]      │
    │                                    │
    │   双方完成 DH 交换，派生密钥，       │
    │   后续消息全部加密                   │
    │                                    │
    │─── IKE_AUTH(req) ────────────────→│  (加密)
    │    [IDi, CERT, AUTH, SA, TSi, TSr] │
    │←── IKE_AUTH(resp) ────────────────│  (加密)
    │    [IDr, CERT, AUTH, SA, TSi, TSr] │
    │                                    │
    │   IKE SA + 第一对 IPSec SA 建立完成 │
```

消息说明：
- **IKE_SA_INIT**：协商 IKE SA 加密/认证算法，完成 DH 密钥交换，交换随机数（Nonce）
- **IKE_AUTH**：在加密信道内完成身份认证（PSK、证书、EAP），同时建立第一对 Child SA（即 IPSec SA）

### 3.3 IKEv2 Child SA 创建（CREATE_CHILD_SA）

追加 IPSec SA（或重协商已有 SA）使用独立的交换：

```
Initiator                           Responder
    │                                    │
    │─── CREATE_CHILD_SA(req) ─────────→│  [SA, Ni, TSi, TSr, KE（PFS）]
    │←── CREATE_CHILD_SA(resp) ─────────│  [SA, Nr, TSi, TSr, KE（PFS）]
    │                                    │
    │   新的 Child SA 建立完成             │
```

### 3.4 IKEv2 密钥派生

```
IKE_SA_INIT 阶段：
  SKEYSEED = prf(Ni | Nr, g^xy)

SK 密钥集：
  {SK_d | SK_ai | SK_ar | SK_ei | SK_er | SK_pi | SK_pr}
  = prf+(SKEYSEED, Ni | Nr | SPIi | SPIr)

  SK_d  = 派生 Child SA 密钥的材料
  SK_ai = 入站消息认证密钥
  SK_ar = 出站消息认证密钥
  SK_ei = 入站消息加密密钥
  SK_er = 出站消息加密密钥
  SK_pi = 入站 AUTH 载荷计算密钥
  SK_pr = 出站 AUTH 载荷计算密钥

Child SA 密钥：
  KEYMAT = prf+(SK_d, Ni | Nr)  （无 PFS）
  KEYMAT = prf+(SK_d, g^xy | Ni | Nr)  （有 PFS）
```

---

## 4. IKE 认证方式

### 4.1 预共享密钥（PSK）

最简单的认证方式，双方配置相同密钥：

```
IKEv1 PSK（主模式）：
  AUTH = prf(SKEYID, g^xi | g^xr | CKY-I | CKY-R | SAi | IDi)

IKEv2 PSK：
  AUTH = prf(prf(PSK, "Key Pad for IKEv2"), <InitiatorSignedOctets>)
```

strongSwan 配置：
```
connections {
  site-a-to-b {
    remote_addrs = 203.0.113.2
    local {
      auth = psk
      id = "gateway-a@example.com"
    }
    remote {
      auth = psk
      id = "gateway-b@example.com"
    }
    ...
  }
}
secrets {
  ike-site-a-b {
    id-a = "gateway-a@example.com"
    id-b = "gateway-b@example.com"
    secret = "SuperSecretPSK2024!"
  }
}
```

### 4.2 RSA/ECDSA 数字证书

企业环境推荐方式，依赖 PKI 基础设施：

```
IKEv2 证书认证：
  Initiator 发送 CERT（X.509 证书）+ AUTH（用私钥签名的数据）
  Responder 用 CERT 中的公钥验证 AUTH 签名
  （双方互相验证 → mTLS 类似）
```

strongSwan 配置：
```
connections {
  corp-vpn {
    remote_addrs = %any
    local {
      auth = pubkey
      certs = server-cert.pem
      id = "CN=vpn.example.com"
    }
    remote {
      auth = pubkey
      cacerts = ca-cert.pem
    }
    ...
  }
}
```

### 4.3 EAP（Extensible Authentication Protocol）—— IKEv2 专属

IKEv2 支持 EAP 扩展认证，常用于客户端使用用户名/密码认证：

```
Initiator                           Responder
    │─── IKE_AUTH(req) [IDi, AUTH] ───→│  客户端用证书认证自己（或空 AUTH）
    │←── IKE_AUTH(resp) [EAP(Request)] │  服务端发起 EAP
    │─── IKE_AUTH(req) [EAP(Response)] →│
    │←── IKE_AUTH(resp) [EAP(Success)] │
    │─── IKE_AUTH(req) [AUTH] ────────→│  最终 AUTH
    │←── IKE_AUTH(resp) [AUTH, SA] ────│
```

常见 EAP 类型：
- EAP-MSCHAPv2：微软挑战握手认证协议，Windows 原生 IKEv2 客户端使用
- EAP-TLS：基于客户端证书的 EAP
- EAP-RADIUS：转发给 RADIUS 服务器认证

strongSwan EAP 配置：
```
connections {
  roadwarrior {
    remote_addrs = %any
    pools = rw-pool
    local {
      auth = pubkey
      certs = server-cert.pem
    }
    remote {
      auth = eap-mschapv2
      eap_id = %any
    }
    children {
      rw {
        local_ts = 0.0.0.0/0
      }
    }
  }
}
```

---

## 5. DPD — 死亡对等体检测

**DPD（Dead Peer Detection，RFC 3706）** 用于检测对等体是否仍然存活。

### 5.1 为什么需要 DPD

网络中对等体可能因以下原因消失，而没有正常关闭 IKE SA：
- 网络故障
- 对等体崩溃重启
- 中间防火墙超时删除 NAT 条目

没有 DPD，IPSec 会话会一直残留，占用资源，直到生命期到期。

### 5.2 DPD 工作机制

```
IKEv1 DPD（RFC 3706）：
  使用私有 Notify 消息：
    R-U-THERE（Type 36136）：询问对等体是否存活
    R-U-THERE-ACK（Type 36137）：应答

  触发条件：空闲超时（dpd_delay）后未收到任何 IKE/IPSec 流量

IKEv2 DPD：
  直接使用空的 INFORMATIONAL 交换：
    → INFORMATIONAL(req)
    ← INFORMATIONAL(resp)
  IKEv2 内置，不需要额外扩展
```

### 5.3 DPD 响应动作

当检测到对等体死亡后：

| 动作 | 描述 |
|------|------|
| clear | 清除相关 SA，不重连 |
| hold | 清除 SA，但保留 SPD 策略，等待触发重连 |
| restart | 清除 SA 并立即重新发起 IKE 协商 |

strongSwan 配置：
```
connections {
  site-vpn {
    dpd_delay = 30s      # 空闲 30 秒后发送 DPD 探测
    dpd_timeout = 120s   # 120 秒内无响应视为死亡
    dpd_action = restart # 死亡后自动重连
    ...
  }
}
```

---

## 6. NAT 穿透（NAT-T）

### 6.1 问题背景

IPSec ESP（IP 协议号 50）不是 TCP/UDP，普通 NAT 设备无法处理端口映射，会导致：
- ESP 报文在 NAT 设备被丢弃
- AH 报文因 IP 头修改导致认证失败

### 6.2 NAT-T 检测

IKE 协商时自动检测 NAT 是否存在：

```
IKE_SA_INIT 交换中携带：
  NAT_DETECTION_SOURCE_IP Notify：
    hash = SHA1(SPIi | SPIr | 源IP | 源端口)
  NAT_DETECTION_DESTINATION_IP Notify：
    hash = SHA1(SPIi | SPIr | 目的IP | 目的端口)

收到后验证：
  若哈希值不匹配 → 说明 IP 或端口被修改 → NAT 存在
```

### 6.3 NAT-T 的处理方式

检测到 NAT 后，IKE 协商切换到 **UDP 4500** 端口，ESP 报文也被封装在 UDP 4500 中：

```
普通 ESP 报文：
  IP | ESP | 加密载荷

NAT-T ESP 报文：
  IP | UDP(4500→4500) | Non-ESP Marker(4字节0) | ESP | 加密载荷
                         ↑
                   用于区分 IKE 消息和 ESP 消息（IKE 消息首字节非0）
```

> [!tip] NAT-T Keepalive
> 为防止 NAT 设备超时删除 UDP 4500 的 NAT 条目，IKE 守护进程定期发送
> NAT-T Keepalive（1字节 0xFF 的 UDP 包，默认每 20 秒一次）。
> strongSwan：`charon.keep_alive = 20`

---

## 7. IKEv2 重要扩展

### 7.1 MOBIKE（RFC 4555）

支持 IKE/IPSec 在网络切换时不重建 SA：

```
场景：手机从 4G 切换到 WiFi，IP 地址变化
MOBIKE：客户端发送 UPDATE_SA_ADDRESSES Notify，
        通知对端自己的新地址，SA 继续使用
```

### 7.2 IKEv2 Fragment（RFC 7383）

解决 IKE 消息因携带证书等大载荷导致的分片问题：

```
大 IKEv2 消息在 IKE 层分片（非 IP 层），
避免因中间设备限制分片而导致协商失败
```

### 7.3 Redirect（RFC 5685）

允许 VPN 网关将客户端重定向到负载更低的节点：

```
Responder 在 IKE_SA_INIT 或 IKE_AUTH 阶段发送
REDIRECT Notify，客户端重新连接到指定地址
```

---

## 8. IKEv1 vs IKEv2 总结

| 对比项 | IKEv1 | IKEv2 |
|--------|-------|-------|
| 规范 | RFC 2409 + ISAKMP/Oakley | RFC 7296 |
| 初始协商消息数 | 主模式 9 条，野蛮模式 6 条 | 最少 4 条 |
| NAT-T | RFC 3947 扩展 | 内置 |
| 可靠性 | 无内置重传保证 | 请求/响应模型，内置重传 |
| 扩展认证 | XAUTH（非标准） | EAP（内置） |
| 移动性 | 无 | MOBIKE |
| 流量选择符 | 单一 proxy ID | 多个 TS |
| 密码套件协商 | 分散在 ISAKMP/Transform | 统一 SA payload |
| DoS 防护 | 无 | Cookie 机制（COOKIE Notify） |

> [!important] 部署建议
> - **新部署一律使用 IKEv2**
> - 旧系统兼容性需求才使用 IKEv1
> - 禁用 IKEv1 野蛮模式（除非确有需要 + 充分了解风险）

---

## 9. strongSwan IKEv2 完整配置示例

站点到站点 VPN，证书认证：

```
# /etc/swanctl/swanctl.conf

connections {
  site-b {
    version = 2
    remote_addrs = 203.0.113.2

    local {
      auth = pubkey
      certs = site-a.pem
      id = "CN=site-a.example.com"
    }

    remote {
      auth = pubkey
      id = "CN=site-b.example.com"
      cacerts = ca.pem
    }

    proposals = aes256gcm128-prfsha256-ecp256
    #           ^加密算法  ^PRF       ^DH Group

    dpd_delay = 30s
    dpd_action = restart

    children {
      net-b {
        local_ts  = 10.0.1.0/24
        remote_ts = 10.0.2.0/24
        esp_proposals = aes256gcm128-ecp256  # PFS: ecp256
        start_action = start
        dpd_action = restart
      }
    }
  }
}

secrets {
  private {
    file = site-a-key.pem
  }
}
```

---

## 10. 本章小结

```
IKE 速查：

IKEv1 阶段：
  Phase 1（ISAKMP SA）：
    主模式 = 6 条消息，身份加密传输（更安全）
    野蛮模式 = 3 条消息，身份明文（避免使用）
  Phase 2（IPSec SA）：
    快速模式 = 3 条消息

IKEv2（推荐）：
  IKE_SA_INIT = 2 条消息（DH + 算法协商）
  IKE_AUTH    = 2 条消息（身份认证 + 首个 Child SA）
  CREATE_CHILD_SA = 追加/重协商 IPSec SA

认证方式：PSK / 证书 / EAP（IKEv2）

关键机制：
  DPD    = 检测对端死亡，自动重连
  NAT-T  = ESP 封装进 UDP 4500，穿越 NAT
  PFS    = Phase 2 独立 DH，前向保密
  MOBIKE = IP 切换不断连（IKEv2）
```

---

## 参考资料

- RFC 7296: Internet Key Exchange Protocol Version 2 (IKEv2)
- RFC 2409: The Internet Key Exchange (IKEv1)
- RFC 3706: A Traffic-Based Method of Detecting Dead IKE Peers (DPD)
- RFC 3947/3948: Negotiation of NAT-Traversal in the IKE / UDP Encapsulation of IPSec ESP Packets
- RFC 4555: IKEv2 Mobility and Multihoming Protocol (MOBIKE)
- strongSwan IKEv2 Configuration: https://docs.strongswan.org/docs/5.9/config/strongswanConf.html
