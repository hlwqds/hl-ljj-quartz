---
title: "ONVIF 深度解析（十七）：实战实录六——lab06，互通收口（框架）"
date: 2026-10-25 12:00:00
description: "实战篇收官框架章：lab06 总装 lab01–lab05 的完整固件，把 ch09 的客户端工作流掉头对准自己——witness 定为 Home Assistant 或 Frigate 以 ONVIF 集成零手工 URL 走完发现→凭据→取流三步（备选 ONVIF Device Manager），出发前按 ch09 六坑清单逐条自查，对账用 tcpdump 三断面（3702/80/8554）+ 客户端日志 + Fault 子码的三层定位法，PullPoint 事件与 G.711 前向音频列为不进主链的可选扩展；lab06 未实跑，实测记录整节（待实测回填）。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 16. [[ch16-lab05-rtsp-mjpeg-report|第十六章]] 17. **第十七章：实战实录六**

# ONVIF 深度解析（十七）：实战实录六——lab06，互通收口（框架）

前五回实录把三层栈逐层装上板：发现（[[ch12-lab01-discovery-report|第十二章]]）、控制面（[[ch13-lab02-device-service-report|第十三章]]）、认证（[[ch14-lab03-auth-digest-report|第十四章]]）、Profile 与快照（[[ch15-lab04-media-snapshot-report|第十五章]]）、RTSP 取流（[[ch16-lab05-rtsp-mjpeg-report|第十六章]]）。但每一站的验收者都是我们自己准备的第一方工具——它们天然站在实现者认知的同侧：知道我们实现了什么，就照着我们的方言发问。lab06 把裁判权交出去：总装五站固件，请一个**不知道我们存在**的集成系统来当裁判。这就是「互通收口」。

按系列「先成文后实跑」的纪律（[[ch11-esp32s31-lab-plan|第十一章]]11.4），本章是框架章：lab06 未实跑，凡依赖实测的数值与结果一律写「（待实测回填）」；对 lab02–lab05 能力的叙述一律按工程契约 [practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md)（[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)）§6 lab06 节的口径展开，各站实测以其各自实录章为准。

## 17.1 定位：把第九章的工作流掉头对准自己

[[ch09-interop-ecosystem|第九章]]是站在客户端侧写就的：它给了工具箱（wsdiscovery 探测、python-onvif-zeep 冒烟、ffplay 验流）、六类坑的靶子、三层定位排错法——全部用来审**别人造的**设备。lab06 的工作就是把这套工作流原样拿来，掉头 180° 审我们自己：三层各由前面某站交付，现在要让 ch09 的工具链在三层上一次性全程走通。这正是「一台普通 ONVIF 摄像机」这个定义的操作化执行——不靠任何一方的自证，只靠生态自己的姿势。

先看清前五站第一方验收的共同盲区：

| 站       | 第一方验收者（按 SPEC 契约）    | 盲区                 |
| -------- | ------------------------------- | -------------------- |
| lab01    | 自写探针 `tools/onvif_probe.py` | 照我们的方言发 Probe |
| lab02–03 | python-onvif-zeep 逐操作冒烟    | 只点名白名单内的操作 |
| lab04    | curl + `file`/`ffprobe`         | 只拉我们自己发的 URI |
| lab05    | ffplay/VLC + 板宿帧计数对账     | 只拉我们知道存在的流 |

第三方裁判不知道我们实现了什么、更不知道我们**没**实现什么：它会试探白名单外的操作（Fault 答得合规吗）、可能先探 Media2 再回落（回落得了吗）、按自己的节奏重发 Probe（组播路径吃得消吗）。这些恰恰是第一方工具永远问不出来的问题。

总装形态（按 SPEC §5 端口表，三个断面就是前五站的全部交付）：

| 断面     | 协议                         | 交付站                      | 内容                                                                                                   |
| -------- | ---------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------ |
| 3702/udp | 发现：SOAP 1.2 over UDP      | lab01（十二章）             | Probe→ProbeMatch，XAddrs 把 :80 端点递到客户端手里（[[ch02-ws-discovery\|第二章]]）                    |
| 80/tcp   | 控制：SOAP 1.1 over HTTP     | lab02–lab05（十三至十六章） | 免鉴权四连、摘要认证、合规 Fault、GetProfiles/GetStreamUri/快照；另保留 `/stream` HTTP MJPEG 对照面    |
| 8554/tcp | 媒体：RTSP + RTP interleaved | lab05（十六章）             | OPTIONS/DESCRIBE（SDP：m=video RTP/AVP 26）/SETUP（先 TCP interleaved）/PLAY，MJPEG 按 RFC 2435 封 RTP |

一条总装期纪律要提前立：lab05 的 rtsp_server 是**单客户端语义**（SPEC §6：raw socket、逐连接串行）——witness 观测期间不要并行第二个 RTSP 取流者；第二个并发连接的行为（排队还是拒绝）按第十六章实录为准（待实测回填），这不是 bug 而是契约，README 需如实记录。

## 17.2 witness 设计：三步零手工 URL，谁来当裁判

SPEC §6 lab06 的 witness 定义：**Home Assistant 或 Frigate 以 ONVIF 集成完成发现→凭据→取流三步，零手工填 URL**。用户全程不碰任何地址——发现交给组播，流地址交给 GetStreamUri。

**主 witness：Home Assistant 的 ONVIF 集成。** 选它不是因为它流行，而是因为 ch09 9.4 里它「双腿并用」的姿势恰好覆盖三步全程：ONVIF 集成负责发现、枚举 Profile、取 StreamUri，流本体交给 RTSP/ffmpeg 流处理管线——一步不缺，而且它是不迁就我们的严格客户端（方案章风险表把 zeep 列为第一验收客户端，HA 是第二道更严格的门）。三步在 HA 里的形态：

```text
① 发现  HA 的 wsdiscovery 在 239.255.255.250:3702 组播 Probe
        板回单播 ProbeMatch：XAddrs=http://<板IP>:80/onvif/device_service
        → HA 集成页出现「ONVIF 摄像机」待配置项
② 凭据  用户只填用户名/口令，不碰任何 URL
        HA：免鉴权 GetSystemDateAndTime 对表（ch09 坑 1 的标准两步走）
        → 摘要认证的 GetDeviceInformation / GetServices / GetProfiles
③ 取流  HA：GetProfiles（token=profile_1）→ GetStreamUri
        → rtsp://<板IP>:8554/… 交给 ffmpeg → 摄像头实体出实时画面
```

**最大的单点风险在第一步。** lab01 的实测已经量出家庭 AP 的组播路径不对称：组播 Probe 板端 4/4 收到并回包，但其单播应答宿主侧 0/4 送达；单播直探 4/4 稳定（[[ch12-lab01-discovery-report|第十二章]]）。HA 的发现恰好依赖组播 Probe——这不是理论风险，是已知地雷。预案按代价排三档：

1. **原样先跑**。HA 的 wsdiscovery 与我们的探针实现不同（Probe 数量、重发节奏、扫描窗口），不对称是否在 HA 上复现，本身就是 lab06 要记录的实测项（待实测回填）。
2. **降级记账**。HA 的 ONVIF 配置流支持手填主机地址触发——填的是 IP 不是 URL，凭据之后的 Profile 与 StreamUri 仍由 ONVIF 全自动完成。若走到这档，witness 记「降级通过（手填 host）」，与纯发现通过分层记账、不合并。
3. **环境治本**。AP 侧组播/IGMP snooping 配置修正或换有线段（真实部署形态，[[ch02-ws-discovery|第二章]]的语义世界）——环境修正不进固件，列为边界条件记录。

**备选 witness：Frigate。** 它的 ONVIF 用法是「导入即止」：发现 + 凭据之后用 GetProfiles/GetStreamUri 自动把流地址填进 camera 配置，此后纯 RTSP——与 ch09 9.4 给它的「RTSP 优先」姿势一脉相承（ONVIF 只在入门出场）。对固件的三步覆盖与 HA 等价，控制面的追问更少；其 onvif 配置形态随版本演进，以所用版本手册为准。**兜底 witness：ONVIF Device Manager**（Windows 老牌 GUI 浏览器）：Probe→凭据→Profile→live view 三步全覆盖、零脚本，定位「是集成的问题还是我们的问题」时最快——代价是需另备 Windows 机器（本环境宿主是 NixOS）。

出发前，把 ch09 9.2 的六坑清单逐条对号做自查表——每一条都得有前五站的交付兜着：

| ch09 坑               | 我们的暴露面                        | 兜底（按 SPEC 契约）                                                                                                          |
| --------------------- | ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| 1 时钟漂移致鉴权失败  | 板无 RTC，冷启动时钟从零起          | lab03：SNTP 启动对时 + 免鉴权 GetSystemDateAndTime + 校验窗口；客户端也会先对表                                               |
| 2 能力查询双轨并存    | GetCapabilities 与 GetServices 都有 | lab02 一次交付、出自同一套手写模板——两边对不上本身就是互通红旗（ch09）                                                        |
| 3 Profile 伪装        | 只自报能兑现的能力                  | SPEC §5：Scopes 必含 `onvif://www.onvif.org/Profile/Streaming`，types 返回 `dn:NetworkVideoTransmitter`；缺的操作回合规 Fault |
| 4 Media1/Media2 双栈  | 只实现 Media1（ver10）              | lab02 的合规 ActionNotSupported：客户端探 Media2 吃到 Fault 后正确回落 Media1                                                 |
| 5 私有 extension 节点 | 模板 XML「一行不多」                | lab02 契约：应答不夹任何私有命名空间节点                                                                                      |
| 6 SOAP 1.1/1.2 混用   | 两代并存：3702 用 1.2、80 用 1.1    | 各按其绑定：发现面 SOAP 1.2 信封（ch02），控制面 SOAP 1.1 + `text/xml`（lab02）                                               |

坑 4 值得多说一句：witness 对 Media2 的探测，我们**不实现也必须答得合规**——ActionNotSupported 的 Fault 结构（lab02 交付）就是客户端「正确回落」的依据；答错形态（裸 HTTP 500、信封命名空间错）会让严格客户端直接放弃而不是回落。第一方工具踩不到这条，因为它知道我们只有 Media1；第三方一定会踩。

## 17.3 双端对账：三断面 × 两本账 × 一张 Fault 核对表

witness 的三种结局都要留痕：成了，「为什么能成」要有归档证据；败了，ch09 9.5 的三层定位法原样上场——先定层、再对账。SPEC lab06 的验收本来就要求 tcpdump 三断面各留一段。

三断面抓包（NIC 纪律沿用十二章：出口按 `ip route get 239.255.255.250` 定；板 IP 以板端日志为准，DHCP 会变、勿写死）：

```bash
# 本机唯一网卡 wlp0s20f3；-A 打 ASCII 才能读 XML 与 RTSP 文本
# 断面① 发现层：WS-Discovery 组播（Probe 进 / ProbeMatch 出，含 MX 错峰）
sudo tcpdump -i wlp0s20f3 -vvv -s0 'udp port 3702'
# 断面② 控制面：SOAP over HTTP（/onvif/* 与快照都在 80）
sudo tcpdump -i wlp0s20f3 -s0 -A 'tcp port 80 and host <板IP>'
# 断面③ 媒体面：RTSP 信令 + RTP/AVP/TCP interleaved（$ 帧混在 RTSP 文本流里）
sudo tcpdump -i wlp0s20f3 -s0 -A 'tcp port 8554 and host <板IP>'
```

各断面要抓到什么（成功形态为预期，待实测回填）：

| 断面   | 成功形态（预期）                                                  | 定位价值                           |
| ------ | ----------------------------------------------------------------- | ---------------------------------- |
| ① 3702 | HA 的 Probe → 板 ProbeMatch（XAddrs 落 :80）                      | 发现步第一现场；组播不对称复现与否 |
| ② 80   | 免鉴权 GetSystemDateAndTime → 带摘要头的 GetProfiles/GetStreamUri | 凭据步；Fault 在这层露脸           |
| ③ 8554 | OPTIONS/DESCRIBE/SETUP（interleaved）/PLAY → `$` 帧开始流动       | 取流步；帧流是否启动               |

第 2 层要的是「客户端以为自己在干什么」。HA 侧只放开 onvif 组件的 debug 日志：

```yaml
# HA configuration.yaml：只放开 onvif 组件的 debug（reload logger 即生效）
logger:
  logs:
    homeassistant.components.onvif: debug
```

需要可复现最小例时，换 python-onvif-zeep 上场（ch09 9.5 同款）——zeep 传输层日志逐字打印收发 XML，与断面② 的线上原文逐字 diff，「应用以为发的」vs「线上实际发的」当场对账：

```python
import logging

logging.basicConfig(level=logging.DEBUG)
logging.getLogger("zeep.transports").setLevel(logging.DEBUG)
```

第 3 层的语义锚点是 Fault 子码。我们的固件按契约只会说三种「方言内的拒绝」Fault，外加一条传输层信号——每一种都对应前面某站的交付，ch09 的速查表在这里变成自指的核对表：

| 信号                   | 出现的步 | 我们的来源（契约）                                  |
| ---------------------- | -------- | --------------------------------------------------- |
| ter:NotAuthorized      | ② 凭据   | lab03：无凭据、nonce 重放、时钟超窗                 |
| ter:ActionNotSupported | ② → ③ 间 | lab02：白名单外操作；亦是 Media2 探测的合规回落信号 |
| ter:InvalidArgs        | ③ 取流   | lab04：Profile token 方言（只认 profile_1）         |
| 传输层拒连/超时        | ③ 取流   | lab05 单客户端语义：第二并发取流者的行为待实测回填  |

板端这本账在 run.log 里全程有标记行（SPEC §1 的 `$$$` 纪律），一次成功的 witness 会话应该把五个站的交付依次点亮：

```bash
# 板端全链标记行：时序即链路
grep '\$\$\$ ONVIF LAB' run.log
# 预期依次出现：LAB01 PROBEMATCH … → LAB02 OP … → LAB03 AUTH …
#   → LAB04 SNAPSHOT …（witness 不拉快照则无此行）→ LAB05 FRAME seq=… → LAB06 WITNESS …
```

两本账按时间轴对齐：断面① 的 Probe 时间戳 ↔ 板端 PROBEMATCH 行；断面② 的每个 SOAP 请求 ↔ LAB02/03/04 标记行；断面③ 的 PLAY ↔ LAB05 FRAME 行的 seq 递增。最后是内存红线读数：witness 是第一次「ONVIF 全栈 + RTSP 推流」同框的长稳态，取流稳态 free_dma 不得低于 170KB（SPEC §4；基线 ≈190KB，lab01 无流客户端连接态实测 274,983 B）——串口控制台 `status` 随时可查，读数（待实测回填）。

## 17.4 可选扩展展望：让设备学会说话（不进主链验收）

SPEC §6 lab06 把两个扩展明示为可选、不进主链验收——它们是 witness 收口之后的下一步，这里只做工程展望。

**扩展 A：PullPoint 事件 + 帧差运动检测。** witness 通过后，设备可以从「被动应答者」升级成「会说话的传感器」（[[ch07-ptz-events|第七章]]模型②，事实上的默认选择——纯客户端身份、NAT 全友好）。设备侧增量三件：

- tev 服务端点：CreatePullPointSubscription / PullMessages（长轮询：无消息按住应答直到超时）/ Renew / Unsubscribe，话题过滤 `tns1:VideoSource/MotionAlarm`；
- 检测算法零新硬件：双缓冲里的最新帧做降采样帧差（PSRAM），MotionAlarm true/false 的边沿去抖照抄 ch07 7.6 的纪律——抖动不除，跟着抽搐的就是 HA 里的自动化；
- 内存面：事件缓冲与挂起应答一律 PSRAM（SPEC §4 红线），一个挂起的 HTTP 连接对 esp_http_server 并发预算的影响要单独观测。

HA 侧是否把 MotionAlarm 落成 binary_sensor 实体，以实测为准（待实测回填）。

**扩展 B：G.711 前向音频。** 板载 ES8389 codec 的音频通路在出厂 demo 验证过（[[ch11-esp32s31-lab-plan|第十一章]]11.1 的底牌表），SPEC §1 裁剪基座时被裁掉——所以这是「接回来」而不是从零写。ONVIF 面：Profile 挂 AudioEncoderConfiguration（G.711 μ-law，RTP 静态 payload type 0）、GetStreamUri 多一路、RTSP SDP 双 `m=` 行、RTP PCMU 按 20 ms 一包。64 kbps 的数据率对 2.77 Mbps 的空口实测吞吐是零头，真正的成本是新增采集→编码链路的任务栈与缓冲对 free_dma 的挤压——照例先量再上。语义边界：**前向音频**＝设备→客户端单向；双向对讲（backchannel）不做，不做的不假装会。

两个扩展共用一条纪律：主链互通与红线守住之前，不谈能力面扩张——「标称当广告、探测当合同」（[[ch09-interop-ecosystem|第九章]]9.1）同样约束我们自己。

## 17.5 实测记录（待实测回填）

按 SPEC §7 的一票否决纪律，本节整节占位：lab06 未上板，以下每格都是实测时回填的位置，禁止预填。回填后本章从「框架」摘帽，与第十二至十六章的实录结构对齐。

| #   | 证据项                                                   | 采集方法                            | 结果           |
| --- | -------------------------------------------------------- | ----------------------------------- | -------------- |
| 1   | witness 发现步：HA 集成页出现本板                        | HA UI + 断面① 抓包                  | （待实测回填） |
| 2   | 组播不对称在 HA 上是否复现                               | 断面① 与板端 PROBEMATCH 行计数对账  | （待实测回填） |
| 3   | witness 凭据步：摘要认证全通                             | HA onvif debug 日志 + 断面②         | （待实测回填） |
| 4   | witness 取流步：实时画面 + 实测帧率                      | HA 摄像头实体 + 断面③ 的 `$` 帧计数 | （待实测回填） |
| 5   | 板端全链标记行（LAB01→LAB06 依次点亮）                   | `grep '\$\$\$ ONVIF LAB' run.log`   | （待实测回填） |
| 6   | 取流稳态 free_dma（红线 ≥170KB）                         | 串口控制台 `status`                 | （待实测回填） |
| 7   | 坏 case：错凭据 / 时钟漂移 / 断网重连 / 第二 RTSP 客户端 | 各断面 + Fault 子码                 | （待实测回填） |
| 8   | 备选 witness（Frigate / ODM）三步                        | 同 1–4                              | （待实测回填） |

标记行模板（SPEC §6 lab06）：

```text
$$$ ONVIF LAB06 WITNESS <ha|frigate> result=<ok|fail>
```

若走到 17.2 的降级档，result 记 ok 但 README 分层记录发现的实际路径——纯发现通过与手填 host 通过是两档结论，不合并。

## 17.6 小结

- lab06 = 总装 + 换裁判：五站固件合成一台完整设备，验收者从第一方工具换成不知道我们存在的集成系统；witness 三步（发现→凭据→取流）零手工 URL，就是「一台普通 ONVIF 摄像机」的操作化定义。
- witness 选型：主 HA（双腿并用，三步全覆盖、追问最严）；备 Frigate（导入即止，RTSP 优先姿势的入门用法）；兜底 ONVIF Device Manager（需另备 Windows 机器）。
- 最大单点风险是 lab01 实测的家庭 AP 组播不对称（板端 4/4 回包、宿主 0/4 收到）——预案三档：原样跑（复现与否本身是实测项）、手填 host 降级记账、AP 侧治本。
- 对账照抄 ch09 三层定位法：tcpdump 三断面（3702/80/8554）+ 客户端认知（HA debug 日志 / zeep 传输层日志）+ Fault 子码自指核对表；板端 `$$$` 标记行全链点亮、两本账按时间轴对齐；取流稳态 free_dma ≥ 170KB 红线照查。
- ch09 六坑逐条自查：时钟、双轨、伪装、双栈、extension、SOAP 版本——每条都有前五站的契约交付兜着；坑 4（Media2 探测）尤其依赖合规 Fault 让客户端正确回落。
- 可选扩展不进主链：PullPoint 事件 + 帧差运动检测（ch07 模型②）、G.711 前向音频（板载 ES8389 接回来）；能力面扩张永远排在主链互通与内存红线之后。
- lab06 未实跑：本章为框架，17.5 整节（待实测回填），回填即实战篇收官。

实战篇至此收口，本章也是系列的末章。回望两个半场：前十章拆轮子——从 3702 端口的一声组播喊话（[[ch02-ws-discovery|第二章]]），到 SOAP 信封、摘要认证、Profile 配置、RTSP 取流，再到生态互审与协议设计的反思；后六章装轮子——把同一套三层栈亲手装进一块 ESP32-S31-Korvo-1，从被探到（[[ch12-lab01-discovery-report|第十二章]]）到被取流（[[ch16-lab05-rtsp-mjpeg-report|第十六章]]），最后交给不知道我们存在的集成系统审判。一问（凭什么互通）一答（亲手造一台被互通的设备）之间，ONVIF 不再是规范文本里的名词，而是板上跑着的、可抓包对账的字节。lab06 实测回填之日，就是系列真正完稿之时——回到 [[onvif-deep-dive|系列索引]]。
