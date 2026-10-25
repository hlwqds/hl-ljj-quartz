---
title: "ONVIF 深度解析（十五）：实战实录四——lab04，Media Profile 与快照（框架）"
date: 2026-10-25 12:00:00
description: "实战篇第四章（框架，实测待回填）：把第五章的 Media Profile 配置模型最小落地到 ESP32-S31-Korvo-1——GetProfiles 用一张静态模板应答单 profile（token=profile_1，JPEG/MJPEG 编码档 640×480，参数全部取自基座实测与推算），GetSnapshotUri 指向 80 端口 /onvif-http/snapshot；快照零额外编码：从 lab01 既有的最新帧双缓冲锁内拷贝最近一帧成品 JPEG；验收计划 curl+file/ffprobe 完整性与 python-onvif 拿 Profile/SnapshotUri，实测记录整节待回填。工程契约 SPEC §6 lab04。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 14. [[ch14-lab03-auth-digest-report|第十四章]] 15. **第十五章：实战实录四**

# ONVIF 深度解析（十五）：实战实录四——lab04，Media Profile 与快照（框架）

实战篇按「先成文后实跑」推进（[[ch11-esp32s31-lab-plan|第十一章]] §11.4）：lab01 已上板验收通过（[[ch12-lab01-discovery-report|第十二章]]），**lab02–lab06 未实跑**。本章给第四站 lab04 先立框架——设计决策、应答模板、验收清单成文；所有依赖实测的数字与结论一律「（待实测回填）」，不把计划写成既成事实（SPEC §7 一票否决第 2 条）。工程契约见 [practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md)（[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)）§6 lab04 节，关键三条逐字如下：

> GetProfiles 返回单一 profile（token 固定 `profile_1`，MJPEG 编码档）；GetSnapshotUri 指向 `/onvif-http/snapshot`。快照实现：从最新帧双缓冲拷贝最近一帧编码 JPEG。

## 15.1 定位：第五章配置模型的最小可信落地

六站序列里 lab04 是控制面的收官站：lab01 让板子能被 [[ch02-ws-discovery|第二章]]的 Probe 探到，lab02 让它能用 [[ch03-soap-services|第三章]]的 SOAP 答出设备信息四连，lab03 让它过得了 [[ch04-ws-security-auth|第四章]]的摘要认证门。lab04 在此之上挂出 Media 服务：[[ch05-media-profiles|第五章]]的配置模型——Profile 是引用的聚合体、token 是全链路索引键——从「拆别人家的响应」变成「自己交一份响应」，前面积攒的每条读表纪律，此刻全部变成对自己的要求。

落到固件，lab04 的增量是 80 端口同一 httpd 上的两个 URI（SPEC §5 端口表）：`/onvif/media_service`（SOAP：GetProfiles 与 GetSnapshotUri 两个操作）与 `/onvif-http/snapshot`（普通 HTTP GET，交出一张 JPEG）。不新开端口、不引 XML 库，仍走 lab02 定下的「模板字符串 + 定向解析」路线。

「最小可信」是本章的立意，两条：

- **只报一个 profile，因为它真的只有一路**。基座只有一条「采集 → PPA → 硬件 JPEG」管线、一个 640×480 编码档；安防语境的「主/子码流」双档需要第二路编码配置，而 [[ch05-media-profiles|第五章]] §5.5 讲过 Media1 只能挂已有配置实体、造不出新的。没有的东西不报——[[ch09-interop-ecosystem|第九章]]审判过的「能力伪装」，轮到自己造设备时的反面自律。
- **报出来的每个字段都必须是事实**。分辨率、帧率、质量档全部取自基座的实测与固件常量（出处逐项见 15.2），一处对不上就是把自己变成 ch09 坑 3 的被告。

快照排在 RTSP（lab05）之前是有意的台阶：它是 ONVIF 路径上的**第一张真实像素**——控制面在 XML 里承诺「JPEG、640×480」，媒体面用一张 JPEG 交卷，`ffprobe` 读出的编码参数与 profile 声明逐项对账。[[ch05-media-profiles|第五章]] §5.4 的 ffprobe 对账纪律，第一次用在自家设备上。

## 15.2 应答设计：单 profile 静态模板与快照 URI 约定

操作白名单在 lab02 的 `onvif_svc` 派发器（SOAPAction 头 + Body 首子节点名定向提取）上加两个操作，均走 lab03 立好的 UsernameToken 摘要门（无凭据 → `ter:NotAuthorized`）；未实现的媒体操作（GetProfile 单数、GetVideoEncoderConfigurationOptions、SetVideoEncoderConfiguration 等）复用 lab02 的合规 Fault 路径回 `ter:ActionNotSupported`——白名单之外的诚实沉默。信封沿用 lab02 的手写模板路线（命名空间严格对 WSDL），本节只拆 Body 增量。

GetProfiles 的应答模板（定稿草案，值的出处见下表）：

```xml
<trt:GetProfilesResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
                         xmlns:tt="http://www.onvif.org/ver10/schema">
  <trt:Profiles token="profile_1">
    <tt:Name>mjpeg_640x480</tt:Name>
    <tt:VideoSourceConfiguration token="vsc_1">
      <tt:Name>sc101iot_source</tt:Name>
      <tt:UseCount>1</tt:UseCount>
      <tt:SourceToken>vs_1</tt:SourceToken>
      <tt:Bounds x="0" y="0" width="640" height="480"/>
    </tt:VideoSourceConfiguration>
    <tt:VideoEncoderConfiguration token="vec_1">
      <tt:Name>mjpeg_encoder</tt:Name>
      <tt:UseCount>1</tt:UseCount>
      <tt:Encoding>JPEG</tt:Encoding>
      <tt:Resolution>
        <tt:Width>640</tt:Width>
        <tt:Height>480</tt:Height>
      </tt:Resolution>
      <tt:Quality>80</tt:Quality>
      <tt:RateControl>
        <tt:FrameRateLimit>15</tt:FrameRateLimit>
        <tt:EncodingInterval>1</tt:EncodingInterval>
        <tt:BitrateLimit>3020</tt:BitrateLimit>
      </tt:RateControl>
    </tt:VideoEncoderConfiguration>
  </trt:Profiles>
</trt:GetProfilesResponse>
```

| 字段                | 模板值    | 出处                                                                                                               |
| ------------------- | --------- | ------------------------------------------------------------------------------------------------------------------ |
| token               | profile_1 | SPEC §6 定死；ch06 例文写 `Profile_1`——token 是设备分配的字符串句柄，客户端只透传不解释（ch05 §5.1），本设备取小写 |
| Encoding            | JPEG      | ONVIF 枚举名（JPEG/MPEG4/H264，ch05 §5.3）；业界俗称 MJPEG（连续 JPEG 帧），SPEC 行文的「MJPEG 编码档」即此        |
| Resolution / Bounds | 640×480   | SC101IOT（PID 0xda4a）实际输出，PPA 全幅直通（scale 1.0，基座代码实证）                                            |
| Quality             | 80        | 基座固件编码器质量参数（`FACTORY_STREAM_JPEG_QUALITY`），声明与实现同源                                            |
| FrameRateLimit      | 15        | 帧到达率上限 15 fps（lab01 基座工程标注）＜ 编码器上限 16.667 fps（上游实测），取 15                               |
| BitrateLimit        | 3020      | 25,165 B/帧 × 15 fps × 8 bit ≈ 3,020 kbps，推算值                                                                  |
| UseCount            | 1         | 单 profile 引用、无共享（ch05 §5.2 的看点字段，如实填 1）                                                          |

两个刻意不写的段：`Multicast`（组播档用不到，不声明）与 `SessionTimeout`（与 RTSP 会话保活联动，等 lab05 落地再定值）——[[ch11-esp32s31-lab-plan|第十一章]]的「一行不多」模板纪律，宁缺勿假。JPEG 档也没有 `H264`/`GovLength` 块（那是 H.264 的旋钮，ch05 §5.3）；JPEG 的主旋钮是 Quality，恰好与固件常量一一对应。

GetSnapshotUri 的约定（请求 + 应答模板）：

```xml
<!-- 请求：ProfileToken 必带（ch05 的 token 索引键在此消费） -->
<trt:GetSnapshotUri xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
  <trt:ProfileToken>profile_1</trt:ProfileToken>
</trt:GetSnapshotUri>

<!-- 应答：MediaUri 结构（与 GetStreamUri 同款，ch06 §6.6） -->
<trt:GetSnapshotUriResponse xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
                            xmlns:tt="http://www.onvif.org/ver10/schema">
  <trt:MediaUri>
    <tt:Uri>http://192.168.1.4:80/onvif-http/snapshot</tt:Uri>
    <tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>
    <tt:InvalidAfterReboot>false</tt:InvalidAfterReboot>
    <tt:Timeout>PT0S</tt:Timeout>
  </trt:MediaUri>
</trt:GetSnapshotUriResponse>
```

三点约定：

- **Uri 动态拼**：应答时以 netif 实际 IPv4 现拼（lab01 XAddrs 同款纪律，SPEC §5 禁写死 IP）；上例 192.168.1.4 是 lab01 那轮 DHCP 的实值，仅作示意。路径 `/onvif-http/snapshot` 无扩展名——HTTP 世界里 Content-Type 才是身份，扩展名是装饰。
- **语义字段**：InvalidAfterConnect/InvalidAfterReboot = false、Timeout = PT0S——URI 不失效、帧常新（快照无会话语义，ch06 §6.6）。
- **未知 token**：回合规 SOAP Fault（子码按 media WSDL 的 fault 定义实现时定稿），样本归档 `runs/`。

## 15.3 快照实现：零额外编码的最新帧语义

[[ch06-rtsp-streaming|第六章]] §6.6 留过一句厂商自由度：「实现上重编码还是 ISP 直出 JPEG 是厂商自由，规范只约束到 URL 这层」。lab04 的答案是成本最低的一种：**不编码**。lab01 基座的管线本来就在常跑——UYVY 帧 →PPA→ RGB565 →硬件 JPEG→ 最新帧双缓冲（`jpeg_buf[2]` 两片 DMA 级 PSRAM + 数据锁；每帧编码完成即更新 `read_slot/read_size` 指向最新成品），`/stream` HTTP MJPEG 对照面是它的第一消费者。任何时刻去读，拿到的都是一张已经编好的 JPEG。快照只是第二个消费者：拿锁、拷贝、放锁、发送——顺带把 lab05 的 RTP 封包预留成第三个消费者，[[ch11-esp32s31-lab-plan|第十一章]] §11.3 的「两路消费者」架构在这里落成接口：基座暴露一个「拷贝最新帧」的小函数，消费者自带缓冲。

```c
/* lab04 快照处理函数（设计草图；接口名与缓冲分配实跑时定稿） */
static esp_err_t onvif_snapshot_handler(httpd_req_t *req)
{
    /* 只借数据不抢通知：锁内拷贝 read_slot 最新成品帧，不碰 frame_sem */
    const ssize_t n = factory_stream_copy_latest(s_snapshot_buf,
                                                 s_snapshot_buf_size);
    if (n <= 0) {   /* 启动初期编码环还没交出第一帧 */
        return httpd_resp_send_err(req, HTTPD_503_SERVICE_UNAVAILABLE,
                                   "no frame yet");
    }

    ESP_LOGI(TAG, "$$$ ONVIF LAB04 SNAPSHOT bytes=%zd", n);
    httpd_resp_set_type(req, "image/jpeg");
    return httpd_resp_send(req, (const char *)s_snapshot_buf, n);
}
```

四条纪律：

- **锁内只拷贝**。持锁窗口 = 一次约 25KB 的 PSRAM→PSRAM 拷贝（持锁时长实测待回填），不做任何编码或格式换算，编码环不被快照拖慢。
- **不碰 `frame_sem`**。那是 `/stream` 消费者的闹钟（每编码一帧给一次）；快照只借数据、不抢通知，避免偷走流订阅者的一次唤醒。
- **缓冲进 PSRAM**（SPEC §4 红线逐字点名「快照拷贝」）。快照缓冲按整帧余量取 300 KiB 级、以 `MALLOC_CAP_SPIRAM` 分配，与 `/stream` 的 send_buf 同款；XML 应答模板同理进 PSRAM，free_dma 纹丝不动。启动与里程碑照例打 free DMA/internal/SPIRAM 三件套对账红线（推流稳态 ≥170KB，基线 ≈190KB；lab01 启动实测 356,227→274,983 B、无流客户端，作对照锚点）。
- **GET 即快门**。无「上一张/下一张」语义（ch06）；返回 GET 时刻最近一次编码完成的帧，年龄上界 ≈ 一个帧周期 + 一次编码耗时（15 fps 档约 67ms + 编码时长，实测待回填）。首帧未就绪（`read_size==0`）回 503，不阻塞等帧。

一个诚实声明的鉴权边界：SOAP 侧的 GetProfiles/GetSnapshotUri 走 lab03 的摘要门，但快照本体是一次普通 HTTP GET，WS-Security 头无处安放。第一档按 [[ch11-esp32s31-lab-plan|第十一章]] §11.2 的边界表走内网明文实验形态（快照端点免鉴权直出），HTTP Digest 401 挑战与 TLS 一样列为后续增强、不进里程碑——商用形态必补，此处明示为已知边界，不做能力伪装。

## 15.4 验收计划

验收四步，全部走完才算过站（SPEC §6 lab04 + §7 通用清单）：

**① 板端证据**。沿用 lab01 的 run.log 纪律：每次快照 GET 落一行标记行 `$$$ ONVIF LAB04 SNAPSHOT bytes=<n>`，与宿主侧落地文件字节数两账互对；内存三件套在启动与 lab04 模块初始化后各打一轮，对 SPEC §4 红线。

**② curl 落地与完整性**：

```bash
# 落地一张快照（板 IP 以板端日志为准，DHCP 会变）
curl -fsS -o snap.jpg http://192.168.1.4/onvif-http/snapshot

# 格式与像素参数：与 profile 声明逐项对账（JPEG、640×480）
file snap.jpg
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height -of default=nw=1 snap.jpg

# 板宿两账互对：宿主字节数 ↔ run.log 标记行
ls -l snap.jpg
grep 'ONVIF LAB04 SNAPSHOT' run.log | tail -3
```

`file` 认格式（JPEG image data）、`ffprobe` 认像素参数（codec_name/width/height），读出的三项必须与 profile 声明逐项一致；字节数与标记行 `bytes=<n>` 相等。

**③ python-onvif 客户端冒烟**（[[ch09-interop-ecosystem|第九章]]的工具链，zeep 的严格反序列化是第一道验收）：

```python
from onvif import ONVIFCamera   # python-onvif-zeep，第九章工作流同款

cam = ONVIFCamera('192.168.1.4', 80, 'user', 'pass', '/etc/onvif/wsdl/')
media = cam.create_media_service()

profiles = media.GetProfiles()   # 期望：恰好 1 个，token=profile_1
uri = media.GetSnapshotUri({'ProfileToken': 'profile_1'})
print([p.token for p in profiles], uri['Uri'])
```

期望：`profiles` 恰好一个、token 为 `profile_1`；拿到的 Uri 直接 GET 能落地同一张 JPEG。

**④ 样本归档与坏 case**。GetProfiles/GetSnapshotUri 的应答 XML 按操作名存 `runs/`（SPEC §7 加分项）；未知 ProfileToken、无凭据访问 SOAP 操作两个坏 case 各留一份 Fault 样本。

## 15.5 实测记录（待实测回填）

本节整节为占位。lab04 上板后按 15.4 清单回填；回填前，本章一切「将/计划」表述均不代表既成事实：

- run.log 摘录（LAB04 标记行、内存三件套、与 lab01 锚点对账）：（待实测回填）
- curl/file/ffprobe 实际输出（含多次 GET 的字节数分布）：（待实测回填）
- python-onvif 返回对象与快照二次验证输出：（待实测回填）
- 与 SPEC §6 lab04 验收项逐条对账的结论：（待实测回填）

## 15.6 小结

- lab04 是 [[ch05-media-profiles|第五章]]配置模型的最小可信落地：单 profile 静态模板（token=profile_1、JPEG 编码档 640×480），每个字段有出处、没有的能力不声明、未实现的操作回合规 Fault。
- GetSnapshotUri 指向 80 端口 `/onvif-http/snapshot`，Uri 以 netif 实时 IP 现拼、禁写死；快照本体免鉴权直出是明示的内网实验形态边界（HTTP Digest 与 TLS 列为后续增强）。
- 快照零额外编码：复用 lab01 最新帧双缓冲，锁内拷贝最近一帧成品 JPEG；新增缓冲一律 PSRAM——SPEC §4 红线对「快照拷贝」有逐字点名。
- 验收三板斧：curl 落地 + `file`/`ffprobe` 完整性与声明对账、python-onvif 拿 Profile 与 SnapshotUri、`$$$ ONVIF LAB04 SNAPSHOT bytes=<n>` 标记行板宿互对；实测记录整节待回填。

一张静态的 JPEG 交了卷，下一章要交的是连续的画面：lab05 把 profile token 换成流——8554 端口自写 RTSP 信令（OPTIONS/DESCRIBE/SETUP/PLAY）、MJPEG 按 RFC 2435 封 RTP、ffplay/VLC 出图，板端 `frames_sent` 与宿主 JPEG EOI 计数逐帧对账，那是六个里程碑里全新代码最多的一站。[[ch16-lab05-rtsp-mjpeg-report|第十六章：实战实录五]]。
