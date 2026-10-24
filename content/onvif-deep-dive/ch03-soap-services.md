---
title: "ONVIF 深度解析（三）：SOAP 服务全景——WSDL、命名空间与设备信息四连问"
date: 2026-10-10 12:00:00
description: "控制面解剖：一次 HTTP POST 的完整请求与应答信封（GetDeviceInformation）；命名空间即路由——Body 第一个子元素的展开名决定服务与操作，附 tds/trt/tr2/tptz/tev/trc/tse/trp/tt 词典表；WSDL 契约的五块骨架与代码生成工具链；免鉴权四连问的实战顺序（对时为何排第一——为摘要认证埋伏笔）与 GetServices/GetCapabilities 两问齐发；HTTP 层几乎总是 200、真相在 XML 里的 SOAP Fault 与 ter: 错误码字典；最后是改两行 Body 即任意操作的最小 C 客户端模板。"
tags: [onvif, soap, wsdl, http, xml, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] 1. [[ch01-onvif-overview|第一章]] 2. [[ch02-ws-discovery|第二章]] 3. **第三章：SOAP 服务全景**

# ONVIF 深度解析（三）：SOAP 服务全景——WSDL、命名空间与设备信息四连问

[[ch02-ws-discovery|第二章]]的产出是一张 XAddrs 清单——设备的 HTTP 服务端点。这一章冲着它发出第一批 HTTP 请求，回答四个问题：**控制面的对话长什么样**（一次「带 XML 的 POST」的完整解剖）、**XML 里那一堆 xmlns 前缀怎么读**（命名空间就是路由表）、**WSDL 契约是什么**（服务世界的头文件与代码生成）、以及**不用任何账号能问出什么**（免鉴权四连问，把设备的时钟、身份、服务目录一次摸清）。最后两节处理工程现实：错误真相藏在 HTTP 200 的 XML 里（SOAP Fault 与 ter: 错误码字典），以及一个不需要任何框架的最小客户端模板。

---

## 3.1 控制面解剖：一次 HTTP POST 里的一切

控制面没有第二种动作——**每次对话都是往端点 POST 一个 SOAP 信封**。以 GetDeviceInformation（问设备身份）为例，线上的完整请求（XML 实际是压成一行的，此处照实呈现）：

```text
POST /onvif/device_service HTTP/1.1
Host: 192.168.1.64:80
Content-Type: application/soap+xml; charset=utf-8
Content-Length: 208

<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><s:Body><tds:GetDeviceInformation/></s:Body></s:Envelope>
```

应答是同一个信封骨架，Body 里换成「操作名 + Response」——ONVIF 的命名纪律，读抓包先找这个模式（下例展开排版便于阅读）：

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <s:Body>
    <tds:GetDeviceInformationResponse>
      <tds:Manufacturer>ACME</tds:Manufacturer>
      <tds:Model>IPC-X2000</tds:Model>
      <tds:FirmwareVersion>2.4.1</tds:FirmwareVersion>
      <tds:SerialNumber>SN-0000001</tds:SerialNumber>
      <tds:HardwareId>HW-A1</tds:HardwareId>
    </tds:GetDeviceInformationResponse>
  </s:Body>
</s:Envelope>
```

几个值得停一下的细节：先补一笔——信封还有个本例省略的 s:Header 扩展区，ch04 的 UsernameToken 就住在那里。其一，`Content-Type: application/soap+xml` 是 SOAP 1.2 的标志，现代 ONVIF 设备的通行款；历史上亦有设备走 SOAP 1.1（`text/xml` 外加 `SOAPAction` 头），兼容库通常两种都备着。其二，**HTTP 状态码几乎帮不上忙**——业务出错时大概率仍是 200，真相在 XML 里（3.5 专门拆）。其三，每个操作都是「一个 POST 一个回合」的请求-应答，没有会话状态——设备靠报文里的 token/句柄类参数维持上下文（ch05 的 Profile token 就是例子）。

## 3.2 命名空间即路由：xmlns 决定打给谁

单端点设备（一个 `/onvif/device_service` 收所有服务的请求——低成本摄像机的常态）URL 不变、HTTP 头不变，**路由信息全在 Body 第一个子元素的展开名里**：命名空间 URI 选服务，本地名选操作：

```text
POST /onvif/device_service            ← HTTP 层不变（单端点设备的常态）
        │
        ▼ 路由在 Body 第一个子元素的展开名 ＝ 命名空间 URI ＋ 本地名
http://www.onvif.org/ver10/device/wsdl ＋ GetDeviceInformation
＝ 设备管理服务（tds）的 GetDeviceInformation 操作
```

于是「读 ONVIF 报文」的第一课就是认前缀。常用词典（覆盖本系列主线章节）：

| 前缀   | 命名空间 URI                                | 圈的地盘                          | 世代  |
| ------ | ------------------------------------------- | --------------------------------- | ----- |
| `tds`  | `http://www.onvif.org/ver10/device/wsdl`    | 设备管理：信息/时间/用户/网络     | ver10 |
| `trt`  | `http://www.onvif.org/ver10/media/wsdl`     | Media1：Profile/取流 URI/截图     | ver10 |
| `tr2`  | `http://www.onvif.org/ver20/media/wsdl`     | Media2：新一代媒体，配置模型简化  | ver20 |
| `tptz` | `http://www.onvif.org/ver20/ptz/wsdl`       | 云台 PTZ（只有 ver20 一代）       | ver20 |
| `tev`  | `http://www.onvif.org/ver10/events/wsdl`    | 事件：订阅/通知                   | ver10 |
| `trc`  | `http://www.onvif.org/ver10/recording/wsdl` | 录像：Profile G 的主干（ch08）    | ver10 |
| `tse`  | `http://www.onvif.org/ver10/search/wsdl`    | 检索：Profile G 的 Find\*（ch08） | ver10 |
| `trp`  | `http://www.onvif.org/ver10/replay/wsdl`    | 回放：GetReplayUri（ch08）        | ver10 |
| `tt`   | `http://www.onvif.org/ver10/schema`         | 公共类型库（各服务共用的结构体）  | ver10 |

三个工程要点：**前缀本身无意义**——`tds:` 换成 `foo:` 只要 URI 不变语义就不变，所以设备应答用的前缀可能与你发的不同，比对报文前先按 URI 归一化（解析抓包最常见的坑）；**世代混杂是常态**——同一台设备 ver10 的 events 与 ver20 的 PTZ 并存，见到 ver20 命名空间不代表整机是 ver20；**tt 是类型库不承载操作**——Body 第一个子元素永远不会是 `tt:`，它只出现在参数与应答的内部结构里（3.4 的时间应答就是例子）。

## 3.3 WSDL 契约：服务的「头文件」

WSDL（Web Services Description Language）是 XML 写的接口定义，ONVIF 每个服务一份。用编程语言类比：portType ≈ interface，operation ≈ 方法签名，types ≈ 结构体定义，binding ≈ 序列化约定。文档骨架五块：

```text
WSDL 文档
├── types      参数与应答的类型定义（引 XSD；ONVIF 公共类型住在 tt 那个 schema）
├── message    每个操作的入参/出参消息（引用 types 里定义的元素）
├── portType   服务 ＝ 一组 operation（每个操作绑一对入/出 message）
├── binding    怎么上传输层（SOAP 1.1/1.2、document/literal 编码）
└── service    端点定义（发现层拿到的 XAddrs 对应到这里的 port）
```

WSDL 的真正威力是**代码生成**：把契约喂给工具链，直接得到强类型的客户端桩——序列化、命名空间、Fault 映射全部自动。ONVIF 圈最常见的路径是 gSOAP 的 `wsdl2h` + `soapcpp2`（设备固件与 PC 客户端常同源），.NET 的 svcutil、Python 的 zeep 也能直接消化 ONVIF 的 WSDL。这也解释了 [[ch01-onvif-overview|第一章]]说的「控制面复用整个 Web 服务生态」：工具链是现成的，厂商按同一份契约生成各自的实现，报文天然对得上。

一个 ONVIF 特有的习惯：**契约随规范发布而非设备在线提供**。WSDL/XSD 从 ONVIF 官网随规范一起下载，客户端开发时离线生成代码；不要指望对设备端点发 HTTP GET 就能拿到 WSDL——那是别的 SOAP 生态的习惯，ONVIF 把契约放在规范文档里，设备只负责按契约说话。

## 3.4 免鉴权四连问：从「几点了」到「你有什么」

规范把少数几个操作划为 pre-auth——**不需要任何安全头即可调用**。它们正好构成一条标准的开局序列，实战顺序与理由一张表：

| 顺序 | 操作                 | 问的是什么                  | 为什么排这里                 |
| ---- | -------------------- | --------------------------- | ---------------------------- |
| 1    | GetSystemDateAndTime | 现在几点（时区/NTP 状态）   | 摘要认证要按设备时钟算时间戳 |
| 2    | GetDeviceInformation | 你是谁（厂/型/固件/序列号） | 兼容性决策的第一手依据       |
| 3    | GetServices          | 有哪些服务、在哪、什么版本  | 新式服务目录                 |
| 4    | GetCapabilities      | （老式）分域能力清单        | 存量设备/老 NVR 仍大量依赖   |

四连问还兼作**探活器**，接住 [[ch02-ws-discovery|第二章]]的尾巴——「缓存不可全信，用前要验」：对 XAddrs 发一问 GetSystemDateAndTime，有应答（哪怕是 Fault）即端点活着，超时则从活设备表摘除。UDP 的 Bye 靠不住（设备断电发不出来），探活只能靠 HTTP 层最便宜的一问。

**时间排第一，是给 ch04 埋的伏笔。**看应答（注意 tt 前缀在这里登场）：

```xml
<tds:GetSystemDateAndTimeResponse>
  <tds:SystemDateAndTime>
    <tt:DateTimeType>NTP</tt:DateTimeType>          <!-- NTP 或 Manual -->
    <tt:DaylightSavings>false</tt:DaylightSavings>
    <tt:TimeZone><tt:TZ>CST-8</tt:TZ></tt:TimeZone>
    <tt:UTCDateTime>
      <tt:Time><tt:Hour>4</tt:Hour><tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time>
      <tt:Date><tt:Year>2026</tt:Year><tt:Month>10</tt:Month><tt:Day>23</tt:Day></tt:Date>
    </tt:UTCDateTime>
    <!-- LocalDateTime 与 UTCDateTime 同构，字段换成本地时间 -->
  </tds:SystemDateAndTime>
</tds:GetSystemDateAndTimeResponse>
```

为什么对表是第一步：下一章的摘要认证要在报文里填 Created 时间戳，**且要按设备时钟来填**——客户端与设备时差过大，设备直接拒绝（容忍窗口多窄因设备而异，秒级是常见量级）。现场一大类「Sender not authorized」故障，追到最后就是客户端没对表。四连问把它放在第一位，是实战换来的排序。

**GetDeviceInformation 问出身份证**：3.1 已贴全报文——Manufacturer/Model/FirmwareVersion/SerialNumber/HardwareId 五行。报障、查兼容矩阵、批量清点资产，都从这五行开始。

**服务目录是四连问的后两问，新 API 与老 API 的交接现场。**GetServices（新）向设备自己要服务清单，每服务一条：命名空间（对应 3.2 的路由键）、XAddr（可以各不相同，也可以全指同一个 URL——端点怎么摆是设备的自由）、版本号（判断哪些新操作可用）：

```xml
<!-- 请求：true ＝ 把各服务的能力细节也带上 -->
<tds:GetServices>
  <tds:IncludeCapability>true</tds:IncludeCapability>
</tds:GetServices>
```

```xml
<tds:GetServicesResponse>
  <tds:Service>
    <tds:Namespace>http://www.onvif.org/ver10/device/wsdl</tds:Namespace>
    <tds:XAddr>http://192.168.1.64/onvif/device_service</tds:XAddr>
    <tds:Version><tt:Major>2</tt:Major><tt:Minor>4</tt:Minor></tds:Version>
  </tds:Service>
  <!-- 其余服务各一条：Media / PTZ / Events / Recording …… -->
</tds:GetServicesResponse>
```

GetCapabilities（老）的应答则是嵌套的能力树——Media/PTZ/Events 各一小节，塞着能力位与功能 URI（比如 Media 小节里的流能力细节，ch06 取流时会回来翻）：

```xml
<tds:GetCapabilities>
  <tds:Category>All</tds:Category>
  <!-- 枚举：All | Analytics | Device | Events | Imaging | Input | Media | PTZ | Receiver -->
</tds:GetCapabilities>
```

较新的规范文本已把 GetCapabilities 标为弃用、推荐 GetServices，但存量设备与老 NVR 巨大——互操作代码的姿势是**两问齐发**：GetServices 拿目录，GetCapabilities 拿能力细节，哪问成功用哪问的结果，两份互为备份。两问的差异一句话：前者平铺「有哪些服务、在哪、什么版本」，后者嵌套「每个能力域里具体支持什么」。

## 3.5 SOAP Fault：HTTP 层几乎总是 200，真相在 XML 里

控制面报错时，HTTP 状态大概率仍是 200，错误信息在应答 Body 的 Fault 元素里。只看状态码的监控脚本会把失败全部误判为成功——这是控制面观测的经典盲区：通用 HTTP 工具看得到 POST 与 200，看不到 XML 里的失败（[[suricata-deep-dive|Suricata 深度探索系列]]与 [[zeek-deep-dive|Zeek 深度探索系列]]的 HTTP 日志就是这个视角，审计 ONVIF 流量时要往载荷里再挖一层）。鉴权失败另有姿势：部分设备直接回 HTTP 4xx 而不带 Fault，也有设备坚持 200 + Fault——两种姿势都在野外存在，客户端两种都得接，ch04 还会再遇到。

SOAP 1.2 的 Fault 结构与一个完整形态的例子：

```xml
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:ter="http://www.onvif.org/ver10/error">
  <s:Body>
    <s:Fault>
      <s:Code>
        <s:Value>s:Sender</s:Value>
        <s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode>
      </s:Code>
      <s:Reason>
        <s:Text xml:lang="en">Sender not Authorized</s:Text>
      </s:Reason>
    </s:Fault>
  </s:Body>
</s:Envelope>
```

两层结构分工明确：**Code/Value 是 SOAP 标准层**（`s:Sender` 你发错了 / `s:Receiver` 设备侧的问题 / `s:VersionMismatch` 信封版本不对），**Subcode 才是 ONVIF 的 ter: 语义层**；Reason/Text 是给人读的，可带多语言。常见 ter: 子码一表（此处是高频子集，完整表在 Core 规范的错误码小节）：

| Code/Value                 | ter: 子码                | 语义                       | 常见诱因                                                  |
| -------------------------- | ------------------------ | -------------------------- | --------------------------------------------------------- |
| `s:Sender`                 | `ter:NotAuthorized`      | 发送方无权执行该操作       | 没带安全头 / 口令错 / 时间戳超窗（ch04）                  |
| `s:Sender`                 | `ter:InvalidArgVal`      | 参数值非法                 | 传了不存在的 token；可再嵌子子码（PTZ 的 `ter:NoConfig`） |
| `s:Sender`                 | `ter:MissingArg`         | 缺必选参数                 | Body 里少了参数元素                                       |
| `s:Sender`                 | `ter:TooManyRequests`    | 请求太频被限流             | 轮询间隔过猛                                              |
| `s:Sender` 或 `s:Receiver` | `ter:ActionNotSupported` | 操作未实现（多为可选操作） | 对老设备调 Media2 等新操作                                |

一个兼容性提醒：鉴权失败这一族在历史规范版本与老设备上存在拼写不同的变体（如旧设备上见过的 `ter:SenderNotAuthorized` 形态——见到「not authorized」字样即是这一族），客户端按子码做字符串匹配时要宽容；拿不准就以目标设备所属时代的 Core 规范错误码小节为准。

## 3.6 最小客户端：改两行 Body，就是任意操作

把前几节拼起来会发现控制面没有魔法：**一个 TCP 连接、几行 HTTP 头、一个信封**。C 视角的最小模板（零依赖，嵌入式友好）：

```c
static const char *kSoapPostFmt =
    "POST %s HTTP/1.1\r\n"
    "Host: %s\r\n"
    "Content-Type: application/soap+xml; charset=utf-8\r\n"
    "Content-Length: %d\r\n"
    "Connection: close\r\n"
    "\r\n"
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">"
    "<s:Body>%s</s:Body></s:Envelope>";

/* 任意操作 ＝ 换下面这「两行」：元素名 + xmlns；带参数就再塞子元素 */
static const char *kBodyGetDevInfo =
    "<tds:GetDeviceInformation"
    " xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\"/>";
static const char *kBodyGetTime =
    "<tds:GetSystemDateAndTime"
    " xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\"/>";
```

流程：sprintf 拼装 → 连 80 端口 → send → recv → 在应答 XML 里搜 `Response>` 或 `Fault` 二选一。免鉴权四连问全部适用；一旦要鉴权，Header 里得塞 UsernameToken——摘要要算 SHA-1 与 Base64（ch04 手推一遍），那时才需要真正的加密库，「改两行」的自由到此为止。这也是本系列先讲免鉴权四连问的原因：**在引入密码学之前，把协议形态看清楚**。

不写 C 也能玩，curl 一发（`getdevinfo.xml` 即 3.1 的信封，去掉 HTTP 头只留 XML）：

```bash
curl -s --data-binary @getdevinfo.xml \
  -H 'Content-Type: application/soap+xml; charset=utf-8' \
  http://192.168.1.64/onvif/device_service

# 旁边开个抓包，肉眼看控制面的请求-应答节奏：
tcpdump -i eth0 -s0 -A 'tcp port 80 and host 192.168.1.64'
```

看点清单：每个操作一个 POST/200 回合、应答 XML 压成一行、把元素名故意拼错观察 200 + Fault（3.5 的现场版）。工程化建议：学习期手搓报文最有价值——每个字节都见过，故障时不会慌；产品期换 WSDL 生成的栈（3.3），除非内存预算或交叉编译环境逼你手写——嵌入式世界里两条路都有人长跑。

## 3.7 小结

- 控制面 = HTTP POST + SOAP 信封：应答操作名是「操作名 + Response」；路由不在 URL 与 HTTP 头，而在 **Body 第一个子元素的展开名**（命名空间 URI 选服务 + 本地名选操作）。
- 命名空间词典：tds/trt/tr2/tptz/tev/trc/tse/trp 各管一个服务，tt 是公共类型库；前缀本身无意义、比对前先按 URI 归一化；ver10 与 ver20 并存是常态。
- WSDL 是服务的头文件：types/message/portType/binding/service 五块，gSOAP、zeep 等工具链可离线生成客户端；契约随规范发布，设备不负责在线吐 WSDL。
- 免鉴权四连问（对表 → 身份 → 目录 → 能力）：GetSystemDateAndTime 排第一，是给摘要认证对设备时钟；四问兼作发现缓存的探活器；GetServices 新、GetCapabilities 旧而弃用但存量巨大——兼容代码两问齐发。
- 错误真相在 XML：HTTP 几乎总是 200，`s:Sender`/`s:Receiver` 定大方向、ter: 子码定细节；鉴权失败既有 200 + Fault 也有 HTTP 4xx 两种姿势。

四连问问完，设备的底细已经摸清——但 GetUsers、改配置这些「真操作」还差一把钥匙：不带安全头发过去，回来的就是 `ter:NotAuthorized`。下一章把这把钥匙造出来：WS-UsernameToken 摘要认证的手工推导——Nonce 怎么来、Created 为何必须跟着设备时钟走、Base64(SHA1(...)) 一步一步算给设备看。[[ch04-ws-security-auth|第四章：WS-Security 摘要认证]]。
