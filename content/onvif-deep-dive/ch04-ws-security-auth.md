---
title: "ONVIF 深度解析（四）：WS-Security——Nonce+Created 摘要认证的手工推导"
date: 2026-10-10 12:00:00
description: "认证层解剖：UsernameToken 四件套（Username/Nonce/Created/Password Digest）的报文结构与设计动机；摘要公式的逐步手工推导——Digest = Base64(SHA1(nonce 原始字节 + Created 字符串 + 口令))，头里的 Nonce 是 base64、参与运算的是解码后字节这一经典坑（正解与错解各算一遍）；设备时间窗口（±5 分钟量级）与对时三板斧；GetUsers/CreateUser/SetUser 与三级用户体系；HTTP 与 RTSP 两套鉴权各算一遍、TLS 端点迁移；默认口令、URL 内嵌凭据、离线爆破等现实裂缝与加固清单。"
tags: [onvif, ws-security, authentication, sha1, soap, rtsp, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] 1. [[ch01-onvif-overview|第一章]] … 3. [[ch03-soap-services|第三章]] 4. **第四章：WS-Security 摘要认证**

# ONVIF 深度解析（四）：WS-Security——Nonce+Created 摘要认证的手工推导

第三章的四连问不需要口令，但从这一章起，一切敏感操作——改配置、建用户、领流地址、转云台——设备都要先问一句「你是谁」。本章拆四件事：**凭据怎么放进 SOAP 头**（4.1 UsernameToken 结构）、**摘要怎么亲手算一遍**（4.2 公式只有一行，坑全在字节）、**时间为什么是第一道坎**（4.3 时间窗口与对时）、以及**这套机制在现实里怎么用、怎么破**（4.4–4.6 用户管理、双轨鉴权、安全裂缝）。读完它，任何「401 / ter:Sender not authorized」都拦不住你。

---

## 4.1 为什么需要认证：控制面的门卫与 UsernameToken

发现层只负责把门牌号（XAddrs）递给你，门卫站在 SOAP 层。控制面的每个操作都是 HTTP POST——网络上任何人都能伪造这个 POST，所以设备必须能校验「发信人持有合法口令」而又**不能让口令明文上线**（控制面常态是明文 HTTP，第四章 4.6 会回到这一点）。ONVIF 的答案是 OASIS WS-Security 的 **UsernameToken Profile**：凭据不放在 HTTP 头，而是作为 SOAP Header 的 `Security` 元素随每个请求携带——这是「消息级安全」，校验对象是报文本身而不是传输连接。

以 GetUsers（4.4 登场）为例的完整请求：

```xml
POST /onvif/device_service HTTP/1.1
Host: 192.168.1.64
Content-Type: application/soap+xml; charset=utf-8

<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <wsse:Security s:mustUnderstand="1"
        xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
        xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
      <wsse:UsernameToken wsu:Id="UsernameToken-1">
        <wsse:Username>admin</wsse:Username>
        <wsse:Password
            Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">yN+RxcHPSx2u50AcC/obCm/0zIQ=</wsse:Password>
        <wsse:Nonce
            EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">TEtLMHdpOWNRM1ptdlFwMg==</wsse:Nonce>
        <wsu:Created>2026-10-10T12:00:00.000Z</wsu:Created>
      </wsse:UsernameToken>
    </wsse:Security>
  </s:Header>
  <s:Body>
    <tds:GetUsers xmlns:tds="http://www.onvif.org/ver10/device/wsdl"/>
  </s:Body>
</s:Envelope>
```

四件套字段各自的职责：

| 字段       | 内容                                 | 作用                                     |
| ---------- | ------------------------------------ | ---------------------------------------- |
| `Username` | 明文用户名                           | 告诉设备查哪条用户记录、用哪个口令重算   |
| `Nonce`    | base64 编码的随机字节（16 字节量级） | 每请求唯一——防重放的原料之一             |
| `Created`  | UTC 时间戳（ISO 8601 字符串）        | 参与摘要运算 + 供设备做时间窗口校验      |
| `Password` | 摘要值（Type 标明 #PasswordDigest）  | **口令本体永不上线**，设备重算一遍再比对 |

设计上它与 HTTP Digest 同族——都是「客户端用口令算一次性证明、服务端重算比对」——差别在于挑战的来源：HTTP Digest 由服务端发 nonce 挑战，UsernameToken 由客户端自己生成 nonce+时间、设备靠时间窗口（4.3）兜住重放。免鉴权的例外正是 [[ch03-soap-services|第三章]]的四连问：时间、设备信息、服务清单、能力——全是「只读且无隐私」的信息，恰好够你在掏口令之前摸清设备底细。

## 4.2 手工推导一遍摘要：公式一行，坑在字节

公式先立在此处，全章只需要这一行：

```text
Digest = Base64( SHA1( nonce 原始字节 + Created 字符串的 UTF-8 字节 + 口令的 UTF-8 字节 ) )
```

三个入参逐一看清（这步偷懒，后面全错）：

- **nonce 原始字节**：客户端随机生成的字节序列本身（16 字节量级即可），**不是**头里那串 base64 文本；
- **Created 字符串**：就是 `wsu:Created` 里那个字符串**原样**（含 `T`、毫秒、`Z`），逐字符 UTF-8——不是解析成时间对象后再重新格式化；
- **口令**：明文口令的 UTF-8 字节。

用一组固定示例值走完全程（本组数值为真实计算结果，读者可按下方命令复现）：

| 输入                                  | 示例值                                            |
| ------------------------------------- | ------------------------------------------------- |
| nonce 原始字节（16 字节可打印 ASCII） | `LKK0wi9cQ3ZmvQp2`                                |
| 同一组字节的 hex                      | `4c 4b 4b 30 77 69 39 63 51 33 5a 6d 76 51 70 32` |
| 头里出现的 Nonce（base64 之后）       | `TEtLMHdpOWNRM1ptdlFwMg==`                        |
| Created                               | `2026-10-10T12:00:00.000Z`                        |
| 口令（演示用）                        | `onvif-demo-pass`                                 |

第一步，base64 编码 nonce 原始字节得到头字段值；第二步，把 **nonce 原始字节**（不是 base64 文本）与 Created、口令直接拼接后做 SHA1，再 base64：

```bash
# 摘要的 openssl 一行推导（python hashlib.sha1 等价，两者已交叉验证一致）
printf '%s' 'LKK0wi9cQ3ZmvQp22026-10-10T12:00:00.000Zonvif-demo-pass' \
  | openssl dgst -sha1 -binary | base64
# → yN+RxcHPSx2u50AcC/obCm/0zIQ=        （SHA1 hex: c8df91c5c1cf4b1daee7401c0bfa1b0a6ff4cc84）
```

这就是 4.1 报文里 `Password` 字段的值。**经典坑**在此：头里的 Nonce 是 base64 编码、参与运算的是解码后的原始字节。如果实现时偷懒，直接把 base64 字符串那 24 个 ASCII 字节拼进去：

```text
正确（拼接解码后的 16 字节）: yN+RxcHPSx2u50AcC/obCm/0zIQ=
错误（拼接 base64 文本 24 字节）: Din2Yfha1vh38z2Zj/R/kDiumnk=
```

同一组输入、仅仅字节观不同，摘要完全对不上——而设备侧的反馈不会提「你的 nonce 处理错了」，只回一个 ter:Sender not authorized（[[ch03-soap-services|第三章]]的 Fault 字典）。把 ONVIF 客户端移植到不同语言时，这是出错率最高的一处：字符串 `TEtLMHdpOWNRM1ptdlFwMg==` 与它所代表的 16 个字节，是两个不同的东西。

这种「公式一行、坑在字节」的手工推导，与 [[diy-vpn|手写 VPN 系列]]里手写哈希时坚持的纪律是同一套：**先拿一组已知输入-输出的向量把实现喂通**（上面 openssl 一行就是验收向量），**再用第二个独立实现交叉对账**（本例是 python 标准库与 openssl 两算两验）。协议工程里九成的「认证不通」不是算法选错，是字节观错。

## 4.3 时间窗口与对时：设备时钟说了算

Nonce 保证每个请求都新鲜，但防重放的另一半押在 Created 上：设备校验它与**自身时钟**的偏差，超出窗口即拒绝——典型窗口在 ±5 分钟量级（具体值由实现决定）。这带来一个工程现实：**客户端时钟准没有用，设备时钟准才算数**。NVR 换电池断电一年、RTC 失效、出厂时间停在固件烧录日——设备时间漂出几小时几年的现场比比皆是；此时客户端按本地时钟算出的「正确」摘要全被窗口拒收，而报错依然只是 not authorized，极易误诊成口令错或 4.2 的字节坑。

对策三板斧（顺序就是排错顺序）：

1. **GetSystemDateAndTime**（免鉴权，四连问第一位）先读设备当前时间；
2. 偏差尚在窗口内 → 客户端**用设备时间作 Created 的基准**来算摘要——摘要原料取自设备时钟，窗口校验自然通过，这是标准做法；
3. 偏差过大 → 先校准设备再谈业务：SetSystemDateAndTime 手动写入（需管理员），或配 NTP 让设备自己走准（SetNTP 指定服务器，再把 DateTimeType 切到 NTP）。

```text
客户端                                       设备
  │ ① GetSystemDateAndTime（免鉴权） ─────→ │
  │ ←────────── 设备当前时间 T ────────────  │
  │                                           │
  │ ② Created = T（对齐设备时钟）             │
  │    Digest = SHA1(nonce + Created + 口令)  │
  │ ③ 带证请求 ────────────────────────────→ │ 用自己存的口令重算
  │ ←─────────────── 应答 ────────────────── │ 摘要比对 ✓ + 时间窗口 ✓
```

顺带一个互通细节：Created 的毫秒位常见写法是三位（`.000Z`），不同设备的解析严格度不一——摘要算的是字符串本身，格式化丢位、进位都会失配，属于 4.2「字节观」问题的变体。

## 4.4 设备侧用户管理：三级权限体系

门卫查的「花名册」由设备管理服务自己维护。经典操作四件（均在 ver10 设备命名空间 tds 下，均要求管理员权限）：

| 操作        | 作用                               |
| ----------- | ---------------------------------- |
| GetUsers    | 列出用户名与级别（**不返回口令**） |
| CreateUser  | 新建用户（用户名/口令/级别三件套） |
| SetUser     | 修改已有用户的口令或级别           |
| DeleteUsers | 删除用户                           |

CreateUser 的请求体（应答为空壳，成功与否看有无 Fault）：

```xml
<tds:CreateUser xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <tt:User xmlns:tt="http://www.onvif.org/ver10/schema">
    <tt:Username>op01</tt:Username>
    <tt:Password>...</tt:Password>
    <tt:UserLevel>Operator</tt:UserLevel>
  </tt:User>
</tds:CreateUser>
```

三级用户体系（UserLevel 枚举）——规范对每个操作逐条标注所需级别，下表是直觉版概括，边界操作以设备文档为准：

| 级别          | 典型权限范围                                            |
| ------------- | ------------------------------------------------------- |
| Administrator | 全部操作：用户管理、网络/时间/固件配置、一切读写        |
| Operator      | 业务配置与控制（媒体配置、PTZ、事件复位），不碰系统配置 |
| User          | 只读为主（查看配置、领流地址）+ PTZ 控制                |

一个值得留意的体系细节：因为设备要拿**口令原文**重算 4.2 的摘要，它原则上得以可还原的形式保存口令——这也解释了 GetUsers 为什么绝不回显口令。少数设备为避开明文存储改存口令的 SHA1 值、重算时以该值作原料，两种模式算出的摘要不同，是互通时偶见的「口令明明对、摘要总不配」的第三种来源（以设备文档为准，[[ch09-interop-ecosystem|第九章]]兼容清单再收）。

## 4.5 传输层：HTTP 与 RTSP 两套鉴权并存

[[ch01-onvif-overview|第一章]]埋的线到这里收：控制/媒体分离的代价是**同一个账号口令、两套鉴权体系各算一遍**。

| 维度       | 控制面（SOAP over HTTP）            | 媒体面（RTSP）                                |
| ---------- | ----------------------------------- | --------------------------------------------- |
| 凭据载体   | WS-Security UsernameToken（XML 内） | HTTP 认证框架（WWW-Authenticate 头）          |
| 摘要算法   | SHA1(nonce + Created + 口令)        | HTTP Digest（MD5 系：HA1/HA2 + 服务端 nonce） |
| 防重放机制 | 客户端 nonce + 时间窗口             | 服务端每次 401 现发 nonce 挑战                |
| 典型通道   | 明文 HTTP 80                        | 明文 RTSP 554                                 |

RTSP 侧的典型 Digest 握手：

```text
C→D  DESCRIBE rtsp://192.168.1.64:554/stream1 RTSP/1.0
D→C  RTSP/1.0 401 Unauthorized
     WWW-Authenticate: Digest realm="ipc", nonce="8a7f...", algorithm=MD5
C→D  DESCRIBE rtsp://192.168.1.64:554/stream1 RTSP/1.0
     Authorization: Digest username="admin", realm="ipc",
                    nonce="8a7f...", uri="rtsp://.../stream1",
                    response="..."     ← MD5 系的又一套手工推导
```

response 的 MD5 推导与本章 SHA1 公式平行（HA1 = MD5(用户:realm:口令) 起步），细节留给 [[ch06-rtsp-streaming|第六章]]取流全链再拆。现实生态里 RTSP 侧多数设备同时接受 Basic 与 Digest，规范方向是 Digest 优先——Basic 的 base64「口令」等于明文，只在 TLS 下勉强可接受。两条真实可跑的观察/核验命令：

```bash
# 探认证方式：401 应答的 WWW-Authenticate 直接暴露设备支持哪些方案
curl -v 'rtsp://192.168.1.64:554/stream1'
# 走 Digest 实连（注意：口令进了命令行与 shell 历史——这正是 4.6 要谈的问题）
curl -v --digest -u 'admin:口令' 'rtsp://192.168.1.64:554/stream1'
```

TLS 侧两条通道各有去处。控制面：设备开启 HTTPS 后服务端点从 `http://` 变为 `https://`（同一路径 `/onvif/device_service`，端口以 GetServices 返回的 XAddrs 为准），证书管理走设备服务的典型操作——CreateCertificate 设备自生成密钥对、GetPkcs10Request 出 CSR 交 CA 签发、LoadCertificates 导入证书、SetClientCertificateMode 控制是否强制双向认证。媒体面：RTSPS（RTSP over TLS，`rtsps://`，默认端口 322，RFC 7826 分配）与 SRTP 已纳入 ONVIF 流规范，但现实部署开启率不高，媒体面明文仍是主流——[[ch06-rtsp-streaming|第六章]]抓包对账时看得一清二楚。WS-Security 与 TLS 不互斥：前者保护「凭据」这一个字段，后者保护整条信道（配置内容、流地址的机密性）；TLS 地基不熟可回 [[vpn-deep-dive|VPN 与隧道技术系列]]补课。

## 4.6 现实安全：这套机制的裂缝

机制本身不复杂，裂缝却比机制显眼：

1. **出厂默认口令**。设备开箱即 admin/空口令或固定组合、上线后永不变更——ONVIF 设备被批量攻陷的第一渠道从来不是协议层，而是这一条。本章的推导再精巧，口令是弱口令就全是摆设。
2. **GetStreamUri 返回的 rtsp URL 内嵌凭据**。多数实现把用户名口令拼进 `rtsp://admin:口令@192.168.1.64:554/stream1` 方便直连——便利与泄漏一体两面：这串 URL 会进日志、进配置文件、进 shell 历史、进工单系统，口令跟着流地址满地复制。认证本可走 4.5 的握手完成，客户端拿到 URL 后应剥离内嵌凭据、改走握手。
3. **摘要可离线爆破**。SHA1(nonce + Created + 口令) 对口令无盐——抓到一个带 Token 的请求，就能对候选口令字典离线逐一重算比对；±5 分钟量级的时间窗口只限定 Created 的取值范围，并不增加爆破成本。明文 HTTP 的局域网里，弱口令等于裸奔。

加固清单（按性价比排序）：

- 上线第一件事改默认口令；三级账号各设独立用户（4.4），别全员 admin；
- 控制面开 HTTPS（4.5），明文 HTTP 能关就关——这同时废掉了抓包离线爆破的原料；
- 口令长度优先于复杂度花哨——离线爆破面前，长度是主要防御；
- 流地址里的 `user:pass` 剥离后再入日志，凭据一律走握手传递；
- 网段隔离：摄像头放独立 VLAN，别让 Token 报文与办公网同广播域。

## 4.7 小结

- UsernameToken 四件套：Username 明文、Nonce（base64 的随机字节）、Created（UTC 字符串）、Password（摘要）——口令本体永不上线，设备用自己存的口令重算比对。
- 摘要公式 Digest = Base64(SHA1(nonce 原始字节 + Created 字符串 + 口令))；头里的 Nonce 是 base64、运算用解码后字节——正错两算（`yN+R...` vs `Din2...`）一眼看穿经典坑；实现纪律与 [[diy-vpn|手写 VPN 系列]]的向量验收同款。
- 时间窗口 ±5 分钟量级、以**设备**时钟为准；设备时间漂移是接入失败第一大原因——先 GetSystemDateAndTime 对齐（或校准）再算摘要。
- 用户管理四件套 GetUsers/CreateUser/SetUser/DeleteUsers 均需管理员；三级体系 Administrator/Operator/User 按操作逐条映射权限。
- HTTP（WS-Security）与 RTSP（HTTP Digest/Basic）两套鉴权各算一遍；TLS 迁移后端点看 GetServices 的 XAddrs，RTSPS 走 322；默认口令、URL 内嵌凭据、无盐摘要离线爆破是三大现实裂缝。

口令的问题解决，控制面的门就开了。下一章进入媒体配置的世界：Media Profile 把视频源、编码器、PTZ 配置打包成一个个命名的「频道」，GetProfiles 怎么枚举、VideoEncoderConfiguration 的分辨率/帧率/GOP 怎么读写、Media2 又把这套模型简化成了什么样子——而本章反复出镜的 GetStreamUri，正是从 Profile 领取 RTSP 流地址的入口。[[ch05-media-profiles|第五章：Media Profile 配置三件套]]。
