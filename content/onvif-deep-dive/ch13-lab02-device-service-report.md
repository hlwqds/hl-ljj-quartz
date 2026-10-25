---
title: "ONVIF 深度解析（十三）：实战实录二——lab02，SOAP 控制面最小集"
date: 2026-10-25 12:00:00
description: "实战篇第二站：lab01 广播的 XAddrs 指向 /onvif/device_service，本章把这张支票兑付成 ESP32-S31-Korvo-1 上的 SOAP 控制面——onvif_svc 模块（393 行）在基座同一 httpd 实例挂 /onvif/device_service，免鉴权四连以手写模板 XML 应答，白名单之外一律 env:Receiver + ter:ActionNotSupported 合规拒绝；Body 首子元素做权威路由、SOAPAction 仅作兜底（实测 zeep 4.3.3 全程不发该头）；成文期预研定下的双壳信封（回信跟随请求版本）经 python-onvif-zeep 0.2.12 逐操作冒烟与 stdlib 1.1 手搓探针双双验证：5/5 + 4/4 全绿，Fault 结构、XAddr Host 回拼、free_dma 253.7KB 红线、双端标记行对账全部落 runs/ 与 run.log 留样。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 12. [[ch12-lab01-discovery-report|第十二章]] 13. **第十三章：实战实录二**

# ONVIF 深度解析（十三）：实战实录二——lab02，SOAP 控制面最小集

[[ch12-lab01-discovery-report|第十二章]]收尾时，这块板子的处境很微妙：它**已经被探到了**——宿主
单播直探 4/4 拿到 ProbeMatch，`xaddrs=http://192.168.1.4:80/onvif/device_service` 这行字进了
runs/ 留样（192.168.1.4 为本轮 DHCP 地址）；但任何客户端真顺着这张地址条 POST 过去，只会收获
404。发现层开出的是一张**支票**，lab01 的「已知边界」里自己承认了：XAddrs 指向的
`/onvif/device_service` 尚不存在。lab02 的全部任务就是兑现这张支票——在同一块板、同一个 80 端口
上，把 [[ch03-soap-services|第三章]]里我们当客户端问过的那套 SOAP 控制面，坐到应答席上重新实现
一遍。

视角对调正是实战篇的价值：第三章的四连问是「问」的纪律（对表 → 身份 → 目录 → 能力），这一章是
「答」的纪律——每个操作变成一段模板 XML，每个错误变成一封合规 Fault，每行命名空间都要经得起
zeep 这样严格客户端的反序列化。工程契约以
[practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md)（[GitHub
源](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)）的 §6 lab02 节
与 §5 端口表为准。

## 13.1 定位：发现层开出的支票，控制面来兑现

[[ch03-soap-services|第三章]]的协议概念与 lab02 的固件落点，一张表对齐：

| [[ch03-soap-services\|第三章]]的概念  | lab02 的设备侧落点                                    |
| ------------------------------------- | ----------------------------------------------------- |
| 命名空间即路由（Body 首子元素展开名） | Body 首子元素权威路由 + SOAPAction 兜底（实测未触发） |
| WSDL 契约：服务世界的头文件           | 手写模板 XML 严格对 WSDL，一行不多，不引栈            |
| 免鉴权四连问（对表→身份→目录→能力）   | 四操作白名单，应答体逐个模板化                        |
| SOAP Fault 与 ter: 错误码字典         | 合规拒绝：env:Receiver + ter:ActionNotSupported       |

端口纪律照 SPEC §5 端口表：80/tcp 是全系列的 SOAP 端口——基座的 `/stream`（HTTP MJPEG 对照面）
已经住在那里，lab02 在**同一个 httpd 实例**上挂 `/onvif/*` 前缀；3702/udp 属于 lab01（已交付），
8554/tcp 属于 lab05。不另起新端口、不占 81——端口表与「XAddrs 填实际 IPv4、禁写死」都是 SPEC
级红线。

还有一个容易忽略的定位：lab02 交付的 `onvif_svc` 是**后续 lab 的宿主**——lab03 的鉴权头校验、
lab04 的 Media 三件套都会长在这同一个模块的路由表上。所以本章的模块边界要为它们留缝（路由表可
扩展、模板可追加），但不预实现：留缝不是预写，白名单之外依旧一律拒绝。

本章各节的方案描述均以 SPEC 为基线；模块拆分、行数与上板行为如与计划有出入，逐节回填。

**落地对账（2026-10-26 实跑）**：`onvif_svc` 模块单文件 393 行
（[main/onvif_svc.c](/static/code/#/onvif-labs/lab02-device-service/main/onvif_svc.c)），挂在
lab01 基座的同一个 httpd 实例上；路由表、双壳模板、PSRAM 缓冲（收/拼/发三块，4KB/2KB/4KB）均按
计划落位。与计划的第一处出入是**编译关**：成文期的代码从未上过编译器，首编即修出三处——注释里
写 `/onvif/*` 触发 `-Werror=comment`、`httpd_req_get_hdr_value_str` 第四参两处误传指针（应为
缓冲尺寸值）、两个从未被调用的死函数（详见 13.3 回填）。计划内的定位判断全部被实测支持：
XAddrs 支票兑现、`/stream` 对照面同实例共存、free_dma 红线无压力（13.5）。

## 13.2 操作集实测：白名单四个，拒绝其余一切

SPEC §6 lab02 对操作面的定义一句话：免鉴权四连 + 合规 Fault（原文：「新建 `onvif_svc` 模块：
单 httpd 挂 `/onvif/*`；实现免鉴权 GetSystemDateAndTime 与 GetDeviceInformation/GetServices/
GetCapabilities；未实现操作回合规 SOAP Fault」）。四连沿用 [[ch03-soap-services|第三章]]3.4 节
的实战顺序——顺序本身是协议语义（对表第一，为摘要认证埋伏笔），应答侧只是镜像：

| #   | 操作                 | 应答要点（实测核对）                                                                                                                                                                                        |
| --- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | GetSystemDateAndTime | tt 结构照 ch03：DateTimeType/DaylightSavings/TimeZone/UTCDateTime；lab02 无 SNTP，DateTimeType 诚实填 Manual，值取系统时钟——实测即开机秒数（UTCDateTime 回 1970-01-01 00:00:04，NTP+补偿窗口是 lab03 的活） |
| 2   | GetDeviceInformation | 身份五行 Manufacturer/Model/FirmwareVersion/SerialNumber/HardwareId；序列号取 efuse STA MAC（实测 `1c2904d072e8`），固件版本取 IDF 默认的 git describe（实测 `v4.5.2-77-gf46e24ab-dirty`）                  |
| 3   | GetServices          | 目录条目 Namespace/XAddr/Version；只报真实存在的 Device 服务（实测 n=1，Version 10.12）；XAddr 按请求 Host 头拼，禁写死（SPEC §5，实测 Host 回拼逐一命中）                                                  |
| 4   | GetCapabilities      | 能力树只塞 Device 小节（tt:Capabilities 各小节皆 minOccurs=0，合法；实测小节集合={Device}）；Media/Events 等 lab04+ 再长                                                                                    |

两个填值细节：版本号（tt:OnvifVersion 的 Major/Minor）如实填所依规范修订，宁旧勿新——实测落为
**10.12**（Device Management 依 ver10 修订 12 的 WSDL）；GetServices 的 IncludeCapability=true
时，tds:Service 的 Capabilities 元素按 schema 本就可空，lab02 暂不嵌能力细节（实测 zeep
反序列化无怨言）——这是刻意边界，等 GetServiceCapabilities 真正实现时再议。

**拒绝语义——白名单之外无特例。**GetUsers、GetProfiles、GetStreamUri，乃至拼错的元素名，一律回
Core 规范对未实现命令的指定回执：**env:Receiver + ter:ActionNotSupported**（与
[[ch03-soap-services|第三章]]3.5 节的 Fault 字典、[[ch09-interop-ecosystem|第九章]]速查表同源），
HTTP 层回 500——两代 SOAP 的 Fault HTTP 映射恰好都落在 500（1.1 一律 500，1.2 的 Receiver 语义
映射 5xx，坑 6 表）。

两个刻意的选择说透：

1. **诚实拒绝而非伪装。**ch09 坑 3 审判的「Profile 伪装」指纹是「标了 S、必选操作回
   ActionNotSupported」；我们把它反过来用：没实现就明说 ActionNotSupported，且 Scopes 与能力
   应答里不虚报任何未交付的能力——lab01 的 Scopes 只自报 Streaming，本章的能力树只报 Device。
   「标称当广告、探测当合同」同样约束我们自己。
2. **Receiver 而非 Sender。**ActionNotSupported 在 ch03 的表里写作「s:Sender 或 s:Receiver」
   两可；Core 规范文本对「该服务不要求实现、设备也未实现」的命令指定的是 env:Receiver。设备侧
   照规范文本走，客户端侧按 ter: 子码匹配、不挑 Code/Value——两头都宽容。

边界预告：lab03 立起 WS-Security 后，鉴权语义（ter:NotAuthorized）与重放拒绝会在同一张路由表上
长出来；lab04 再把 Media 操作转正。lab02 阶段它们统统走 ActionNotSupported。

**实测确认**：GetUsers 在两代壳上都收到合规拒绝——zeep（1.2）侧 `str(e)` 拿到
`Requested action not supported (ter:ActionNotSupported)`，HTTP 500；1.1 手搓探针侧
faultcode=`s:Receiver`、faultstring 文本承载 ter: 语义，同为 HTTP 500。板端两笔都落了
`$$$ ONVIF LAB02 OP (unlisted) fault action-not-supported` 标记行（run.log I(4788) / I(4982)），
客户端按 ter: 子码匹配的断言全数通过，无特例兑现。

## 13.3 实现方案：模板 XML，不引栈

架构一句话：新建 `onvif_svc` 模块，在基座已有的 httpd（80 端口，`/stream` 对照面同实例）上注册
`/onvif/device_service`——SPEC 说的「挂 /onvif/\*」在本站落为该前缀下先只注册这一个 URI，未注册
路径自然 404，不装作有服务。对设备端点发 HTTP GET 也不吐 WSDL（ONVIF 契约随规范发布，ch03 3.3
节的纪律），回 405 即可。

```text
httpd :80（基座复用，/stream 对照面同实例）
 └─ POST /onvif/device_service
     ├─ ① Body 首子元素展开名 → 权威路由（tds URI + 本地名，白名单四选一）
     ├─ ② SOAPAction 尾段 → 兜底提示（仅 Body 解析失败时才轮到；实测未触发）
     └─ ③ 命中 → 模板拼装（rodata 模板 + 运行期字段）→ 200
        未命中 → Fault 模板 → 500 + env:Receiver/ter:ActionNotSupported
```

**路由纪律：Body 权威，SOAPAction 只是兜底。**[[ch03-soap-services|第三章]]的纪律：路由信息在
Body 第一个子元素的展开名里（命名空间 URI 选服务、本地名选操作），URL 与 HTTP 头不承载路由。
设备端照此实现：handler 先做 Body 定向解析，解析失败才回落 SOAPAction 头。成文期曾据「源码
预研」断言 zeep 发 1.2 报文时也照发 `SOAPAction` 头、可当快路径——**本轮实跑把这条推翻了**：
zeep 4.3.3 两个绑定类的 `_set_http_headers` 都只设 `Content-Type`（1.1 绑定
`text/xml; charset=utf-8`，1.2 绑定 `application/soap+xml; charset=utf-8; action="…"`——action
进了 Content-Type 参数而不是独立的 SOAPAction 头），全程不发 SOAPAction。于是本轮九笔成功的
路由**全部由 Body 决定**，兜底分支一次都没轮到。教训与 ch09 坑 6 同款：预研的结论也要上板对
账，「源码注释说照发」不等于「报文里真有」；留样的 `zeep-*.req.xml`（envelope 全文）与 zeep
发行包源码（`zeep/wsdl/bindings/soap.py`）双方可复核。

C 视角的路由表（源码原文，模板拼装与 httpd 注册略）：

```c
/* ---- 路由表（白名单四操作；扩展点：lab03 鉴权、lab04 Media 在此追加） ---- */

typedef esp_err_t (*serve_fn)(httpd_req_t *req, char *body, size_t body_max);

static const struct {
    const char *local;       /* Body 首子元素本地名（tds 命名空间，白名单内） */
    const char *action_tail; /* SOAPAction 尾段：仅 Body 解析失败时兜底 */
    serve_fn serve;          /* 模板拼装进 body 缓冲 */
} kOps[] = {
    { "GetSystemDateAndTime", "GetSystemDateAndTime", serve_date_time },
    { "GetDeviceInformation", "GetDeviceInformation", serve_dev_info },
    { "GetServices",          "GetServices",          serve_services },
    { "GetCapabilities",      "GetCapabilities",      serve_capabilities },
};
```

路由逻辑在 `onvif_svc_handler`：先 `svc_route_by_body`（`s_rx` 里定位 `":Body>"` 后的首元素，
本地名查表，且 xmlns 前缀必须绑定 tds URI——定向提取，不做 DOM）；解析失败才读 SOAPAction 尾段
兜底；两者皆未命中 → Fault 模板 + HTTP 500。

**模板分层。**信封壳与内容分离：壳两套（SOAP 1.1 / SOAP 1.2，见下文），Body 模板四个，Fault
模板按壳各一。模板全部 `const`（rodata，flash），运行期只 sprintf 换动态字段（时间、序列号、
Host 拼出的 IP）；请求与应答缓冲一律 **PSRAM** 分配——SPEC §4 红线：推流稳态 free_dma ≥ 170KB
（基线 ≈190KB；lab01 启动实测 356,227→274,983 B 为无流客户端态），内部 RAM 只留栈与 socket
系统缓冲。应答都在千字节量级，PSRAM 毫无压力。

以对表应答为例（1.2 壳；结构与 [[ch03-soap-services|第三章]]3.4 节同构，值取系统时钟）：

```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
            xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Body>
    <tds:GetSystemDateAndTimeResponse>
      <tds:SystemDateAndTime>
        <tt:DateTimeType>Manual</tt:DateTimeType>
        <tt:DaylightSavings>false</tt:DaylightSavings>
        <tt:TimeZone><tt:TZ>CST-8</tt:TZ></tt:TimeZone>
        <tt:UTCDateTime><!-- 时/分/秒 + 年/月/日：系统时钟换算 --></tt:UTCDateTime>
      </tds:SystemDateAndTime>
    </tds:GetSystemDateAndTimeResponse>
  </s:Body>
</s:Envelope>
```

**信封版本纪律：坑 6 第一次约束我们自己。**SPEC §6 lab02 的基线是「命名空间与 SOAP 1.1 信封
严格对 WSDL」——1.1 是存量兼容面（`text/xml` + SOAPAction，[[ch09-interop-ecosystem|第九章]]
坑 6 表的「历史惯性」半边）。但成文期对第一验收客户端做了源码级预研，三件事实：

1. python-onvif-zeep 0.2.12 随包的全部 WSDL（devicemgmt/media/events/ptz……）声明的都是
   **soap12 绑定**——onvif.org 在线的 ver10 devicemgmt.wsdl 亦然；
2. zeep 4.3.3 按绑定发 SOAP 1.2 请求：信封 `http://www.w3.org/2003/05/soap-envelope`、
   `Content-Type: application/soap+xml; charset=utf-8; action="…"`；
3. zeep 对**回信**同样按绑定强校验：`SoapOperation.process_reply` 要求应答根元素就是绑定版本的
   Envelope，1.1 信封回给 1.2 绑定直接抛「does not contain a valid {…}Envelope root element」。

结论：**只备 1.1 壳会在自己的验收客户端上翻车**。落地纪律（成文期决策，以 zeep 冒烟为准）：
双壳模板共用 Body，**回信信封版本跟随请求**——解析请求 Envelope 的命名空间 URI 二选一，
Content-Type 跟壳走（1.1 → `text/xml; charset=utf-8`；1.2 →
`application/soap+xml; charset=utf-8`）。这正是坑 6 对策「按每个服务 WSDL 声明的 soap 版本设置
信封命名空间与 Content-Type，不要全局假设」的反向应用：野外的坑教育客户端，现在轮到它教育
设备端。SPEC 的 1.1 基线保留为存量兼容底座（老 NVR/老工具的直连路径）。

Fault 的双形态同理由此而来：1.2 壳按 [[ch03-soap-services|第三章]]3.5 节的结构（Code/Value=
env:Receiver + Subcode ter:ActionNotSupported + Reason/Text），Reason/Text 是给人读的文案（含
not supported 字样，供宽松断言），机器可判的语义在 Subcode；1.1 壳是 faultcode/faultstring
两件套，ter: 语义只能落进 faultstring 文本——SOAP 1.1 没有标准 Subcode 位，这是 1.1 路线的先天
取舍，以冒烟留样为准。

**坑 5 的反向纪律：一行不多。**应答绝不夹带私有命名空间节点——哪怕觉得「顺便报点自家的东西挺
方便」——zeep 对 GetCapabilities 扩展节点解析不了是有历史 issue 的
（[[ch09-interop-ecosystem|第九章]]坑 5；onvif-zeep 侧虽设了 `strict=False` 的宽容，纪律不建立在
别人的宽容上）。宽松解析是客户端的修养，报文干净是设备端的义务；要用私有能力就走私有路径
（`/stream` 对照面），不做半标准半私有的缝合。

标记行沿用 SPEC §1 的 $$$ 纪律：启动
`$$$ ONVIF LAB02 SVC READY http=<板IP>:80/onvif/device_service`；每操作
`$$$ ONVIF LAB02 OP <name> ok`——run.log 与宿主侧留样两账互对。

以上为成文期方案。上板对账（2026-10-26 实跑）——**先过编译关，再谈行为**：

1. **首编三修。**成文期代码从未上过编译器，`idf.py build` 首轮即暴露三处：①
   `factory_demo_stream.h` 注释里写 `/onvif/*`——注释内嵌 `/*` 被 `-Werror=comment` 拦下，改写
   为「/onvif/ 前缀」；② `httpd_req_get_hdr_value_str` 第四参是缓冲尺寸（size_t 值），实现误传
   指针（`&n`），Host 头与 SOAPAction 头两处同病；③ 两个从未被调用的死函数连坐
   `-Wunused-function`——`shell_ns`（信封命名空间本就在壳模板里）直接删除，
   `svc_route_by_action`（把 NULL 当 req 传、且永远 return NULL 的半成品）删除后由 handler 里的
   内联 SOAPAction 兜底承担其语义。另补 `esp_app_format` 组件依赖（`esp_app_desc.h` 取固件版本
   之需）。教训进账：**文档里写就的代码骨架也要先过编译器再成文**，死代码连 `-Wunused-function` 这关
   都过不了。
2. **缓冲与应答尺寸。**三块 PSRAM 缓冲按计划落位（s_rx 4096 / s_body 2048 / s_tx 4096 B）；
   实测应答字节数：身份 552 B（1.1）、目录 510 B、Fault 372 B（1.1）、能力树 968 B（1.2，留样
   经 lxml 重排）——全在千字节内，s_tx 余量充足。
3. **行为与方案逐条相符。**detect_shell 按 Envelope 命名空间二选一（zeep 1.2 走 2003/05、手搓
   1.1 走 schemas.xmlsoap.org，双壳都通）；XAddr 由 Host 头拼出，两条客户端路径逐一命中预期
   `http://192.168.1.4/onvif/device_service`；GET 端点 405、未注册路径（`/onvif/events_service`）
   404——「不装作有服务」留了原始字节证据。

## 13.4 验收实录：zeep 逐操作冒烟，Fault 留样归档

验收客户端锁定 python-onvif-zeep（SPEC §6 lab02 指定，[[ch11-esp32s31-lab-plan|第十一章]]
11.6 的工具链首选）。冒烟的「零号用例」常被忽略：**构造 `ONVIFCamera` 对象本身就是一发冒烟**
——onvif-zeep 的 `update_xaddrs()` 在 `__init__` 里就会调 `GetCapabilities({'Category': 'All'})`
（发行包源码可见），GetCapabilities 答不好，客户端对象都构造不出来。四连里最「老」的一问，反而
站在第一道门上。

宿主侧冒烟脚本落为工程常驻工具（沿用 lab01 的双端原文留样纪律）：
[tools/onvif_smoke.py](/static/code/#/onvif-labs/lab02-device-service/tools/onvif_smoke.py)（zeep
1.2 壳，HistoryPlugin 抓双端原文）与
[tools/soap11_probe.py](/static/code/#/onvif-labs/lab02-device-service/tools/soap11_probe.py)
（stdlib 手搓 1.1 壳）。核心流程与断言：

```python
from onvif import ONVIFCamera          # wsdl 目录默认随包（site-packages/wsdl）
from onvif.exceptions import ONVIFError

cam = ONVIFCamera('192.168.1.4', 80, 'admin', 'admin')
dev = cam.devicemgmt                   # 零号用例：构造内部已发过 GetCapabilities(Category=All)

dev.GetSystemDateAndTime()             # ① 对表：断言 DateTimeType == 'Manual'
dev.GetDeviceInformation()             # ② 身份五行：非空 + SerialNumber 十二位 efuse MAC
dev.GetServices(False)                 # ③ 目录：断言单条 tds 服务 + XAddr == Host 回拼
dev.GetCapabilities({'Category': 'All'})  # ④ 能力树：断言小节集合 == {'Device'}

try:                                   # ⑤ 拒绝语义：白名单之外
    dev.GetUsers()
    raise SystemExit('未拒绝 = 失败')
except ONVIFError as e:
    assert 'ActionNotSupported' in str(e)  # str(e)='Unknown error: Requested
    # action not supported (ter:ActionNotSupported)'；严格结构查 XML 留样
```

（lab02 设备端对 s:Header 一概不校验——四操作本就免鉴权，客户端带不带安全头、凭据对不对都
放行；校验是 lab03 的交付。）

验收矩阵（对 SPEC §7 通用清单的 lab02 特化）：

| 项         | 判据                                                                      | 证据落点                                  |
| ---------- | ------------------------------------------------------------------------- | ----------------------------------------- |
| 四连冒烟   | ①–④ 逐操作 zeep 反序列化成功、字段自洽                                    | runs/ 应答原文按操作名存样                |
| 拒绝语义   | 白名单外操作收到 Fault：Code=env:Receiver、Subcode=ter:ActionNotSupported | runs/fault-\*.xml + 板端标记行            |
| 双壳       | zeep（1.2）与 curl 手搓（1.1：text/xml + SOAPAction）两条路径都通         | 留样分版本存                              |
| 双端对账   | 板端 `$$$ ONVIF LAB02 OP <name> ok` ↔ 宿主应答原文一一对应                | run.log + runs/                           |
| 内存红线   | 冒烟前后串口 `status` 的 free_dma ≥ 170KB                                 | run.log heap 打点                         |
| XAddr 纪律 | GetServices/GetCapabilities 的 XAddr 由请求 Host 头拼出，非写死 IP        | 留样 grep                                 |
| 工程交付   | README 中文齐备（目的/拓扑/命令/真实输出摘录/边界）、prettier 过          | practice/onvif-labs/lab02-device-service/ |

tcpdump 80 断面为补充证据（sudo，可选，同 lab01 纪律）；run.log 超 1MB 按仓政策截断（SPEC §7
第 4 条）。冒烟全绿后证据链闭环：板端标记行、宿主留样、抓包断面三账互对。

**逐项判定（2026-10-26 实跑，全绿）**：四连冒烟 5/5（含零号用例，`runs/smoke-zeep.log`，逐操作
`zeep-*.req/res.xml` 存样）；拒绝语义两壳各一笔（`runs/fault-GetUsers.res.xml` 1.2 结构留样、
`soap11-fault-GetUsers.res.xml` 1.1 两件套留样 + 板端 unlisted 标记行×2）；双壳双通（zeep
1.2：`application/soap+xml` 往返，Content-Type 跟壳回 `text/xml`；1.1 探针 4/4 含 GET 405）；双
端对账 10 条标记行（板端 run.log ↔ 宿主两份 smoke 日志，顺序一一对应）；内存红线三轮打点
253,751→253,719→253,687 B ≥ 170KB；XAddr 纪律：两壳的 GetServices/GetCapabilities 应答均按
Host 头回拼 `http://192.168.1.4/onvif/device_service`（grep 留样即证）；工程交付 README 已按
SPEC §7 第 1 条重写为实跑版。tcpdump 断面本轮未采（单播 POST 路径，宿主/板端两账已互为印证，
留待 lab06 互通收口时三断面齐采）。

## 13.5 实测记录

按 SPEC §7 一票否决第 2 条，本节只收**真实上板输出**。2026-10-26 实跑，板 IP=192.168.1.4（本轮
DHCP，与 lab01 同址）；`run.log` 全文 15.9KB 入库（`practice/onvif-labs/lab02-device-service/run.log`），
宿主侧留样 18 件入 `runs/`（zeep 逐操作 req/res、1.1 探针原始字节、双份冒烟日志）。

**启动判据**（串口取证窗口，`serial_capture.py` 硬复位从头收全）：

```text
I (1438) sc101iot: Detected Camera sensor PID=0xda4a
I (1847) lab02: lab02 base ready (camera+stream+disc+svc)
I (3417) onvif_disc: $$$ ONVIF LAB01 DISC JOIN grp=239.255.255.250:3702 ip=192.168.1.4
I (3447) onvif_svc: $$$ ONVIF LAB02 SVC READY http=192.168.1.4:80/onvif/device_service
```

**双壳冒烟输出**（zeep 1.2 五发全过 + 1.1 探针四发全过，完整文本见
`runs/smoke-zeep.log` / `runs/smoke-soap11.log`）：

```text
$$$ HOST LAB02 OP GetCapabilities(implicit-on-init) ok  # 零号用例：构造成功
$$$ HOST LAB02 OP GetSystemDateAndTime ok  type=Manual utc=1970-01-01 00:00:04
$$$ HOST LAB02 OP GetDeviceInformation ok  Manufacturer=Espressif \
  Model=ESP32-S31-Korvo-1 ONVIF Lab FirmwareVersion=v4.5.2-77-gf46e24ab-dirty \
  SerialNumber=1c2904d072e8 HardwareId=ESP32-S31
$$$ HOST LAB02 OP GetServices ok  n=1 ns=tds \
  xaddr=http://192.168.1.4/onvif/device_service version=10.12
$$$ HOST LAB02 OP GetCapabilities ok  sections=Device xaddr=http://192.168.1.4/onvif/device_service
$$$ HOST LAB02 FAULT GetUsers ok  \
  reason='Unknown error: Requested action not supported (ter:ActionNotSupported)'
$$$ HOST LAB02 SMOKE PASS 5/5 (四连 + Fault)，原文留样见 runs/
```

**双端对账**：run.log 十条标记行与两份宿主日志一一对应——zeep 侧零号→对表→身份→目录→能力→
Fault（I(4571)→I(4788)），1.1 探针侧身份→目录→Fault（I(4929)→I(4982)）；两客户端合计九笔
SOAP 交换加一轮 events 探测，全程 1.5 秒内完成，控制面轻得符合「模板拼装」的预期。

**内存红线**（`--send-at` 定时往 `korvo>` 控制台写打点命令，无流客户端连接态）：

```text
t=9s  status: free_dma=253751 free_spiram=12055112   # 冒烟前
t=32s status: free_dma=253719 free_spiram=12055112   # 双客户端冒烟后
t=60s heap : free_dma=253687 free_spiram=12055112
```

启动打点 stream init 前 356,211 B / 后 274,975 B，与 lab01 同基线；冒烟前后 free_dma 漂移仅
32 B（至 t=60s 末次打点累计 64 B）——SOAP 缓冲全在 PSRAM 的纪律兑现，红线 ≥170KB 无压力。

**计划外发现**（每一站的保留节目，本轮六件）：

1. **框架代码首次过编译器，三处现形**：注释内嵌 `/*` 触发 `-Werror=comment`、
   `httpd_req_get_hdr_value_str` 第四参两处误传指针、死函数连坐 `-Wunused-function`
   （详见 13.3 回填）。文档里描述过的代码 ≠ 编译过的代码。
2. **无 SNTP 的 UTCDateTime 就是开机秒数**：`time()` 从 0 起算，冒烟时板已跑 4 秒，应答诚实回
   `1970-01-01 00:00:04`——「值取系统时钟」在 lab02 的真实含义，比任何解释都直白；SNTP 对时与
   免鉴权补偿窗口（ch09 坑 1 的翻车实验）正是 lab03 的开场。
3. **zeep 每发都带 WS-UsernameToken 摘要头**：`runs/zeep-GetDeviceInformation.req.xml` 留样里
   Username/PasswordDigest/Nonce/Created 四件俱全——lab02 设备端一概不校验照单全收，这枚「钥匙
   孔」的实物照片已经归档，lab03 的校验逻辑有现成的请求样本可对。
4. **onvif-zeep 的三件解析习惯**（冒烟脚本适配时逐一撞上）：HistoryPlugin 存的是
   `{"envelope": …, "http_headers": …}` 字典而非元组；GetServices 单数组应答被 zeep 直接解为
   list（没有 GetServicesResponse 包装层）；异常统一包成 ONVIFError 且文案带 `Unknown error: `
   前缀。客户端生态的「性格」与协议文本同样值得留样。
5. **端点语义的原始字节证据**：GET `/onvif/device_service` → 405；未注册路径
   `/onvif/events_service` → `404 Nothing matches the given URI`（curl 实测）——「不装作有服务」
   不是口号，是可复现的 HTTP 状态码。
6. **成文期「zeep 也照发 SOAPAction」的预研被实跑推翻**：zeep 4.3.3 两个绑定都只设
   `Content-Type`（1.2 把 action 放进 Content-Type 参数），全程不发 SOAPAction 头
   （`zeep/wsdl/bindings/soap.py` 两个 `_set_http_headers` 实现可复核）——本轮路由全程由 Body
   决定，设备端的 SOAPAction 兜底分支一次都没触发。「快路径」是写给野外的老客户端的，不是写给
   自己的验收客户端的。

## 13.6 小结

- lab02 = 兑现 lab01 的 XAddrs 支票：同一个 80 端口挂上 `/onvif/device_service`，
  [[ch03-soap-services|第三章]]的四连问镜像成设备侧四连答；实测 zeep 5/5、1.1 探针 4/4 双壳
  全绿，九笔交换 1.5 秒完成。
- 操作集是白名单：免鉴权四连之外一律 env:Receiver + ter:ActionNotSupported——诚实拒绝是
  ch09 坑 3（Profile 伪装）的反向纪律，能力应答只报真实存在的服务（实测小节集合={Device}、
  服务条目 n=1）。
- 实现不引栈：模板 XML + Body 首子元素权威路由 + SOAPAction 兜底（实测 zeep 全程不发该头，
  兜底分支零触发）；缓冲全进 PSRAM，实测冒烟稳态 free_dma ≈253.7KB，红线 ≥170KB 不动。
- 成文期源码预研定下的信封纪律（onvif-zeep 随包 WSDL 全 soap12 绑定、zeep 强校验回信信封 →
  双壳模板、回信跟随请求版本）被实跑验证：zeep 1.2 与手搓 1.1 两条路径的 Content-Type 均按壳
  跟随，坑 6 对策的反向应用成立。
- 上板新账两笔：框架代码必须先过编译器（首编三修）；无 SNTP 时 UTCDateTime 即开机秒数——
  诚实边界的实物留样，为 lab03 的时钟纪律递了刀。
- 验收三件套落地：ONVIFCamera 构造即冒烟（GetCapabilities 站在第一道门，实测通过）、逐操作
  XML 留样（runs/ 18 件）、run.log 与 runs/ 双端对账（十条标记行一一对应）。

四连答通、控制面立住之后，这块板子还欠一把钥匙：所有「真操作」仍会被 ActionNotSupported 挡回。
下一章把这把钥匙造出来——WS-UsernameToken 摘要认证的设备侧对称实现：PasswordDigest 校验、nonce
环形缓存防重放、SNTP 对时与免鉴权 GetSystemDateAndTime 的补偿窗口，外加一场故意关掉 SNTP 复现
ch09 坑 1 的「翻车实验」。
[[ch14-lab03-auth-digest-report|第十四章：实战实录三——lab03，WS-Security 摘要认证与时钟纪律]]。
