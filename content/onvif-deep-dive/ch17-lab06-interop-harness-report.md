---
title: "ONVIF 深度解析（十七）：实战实录六——lab06，互通收口"
date: 2026-10-25 12:00:00
description: "实战篇收官站：五站总装固件全链走通——发现 ProbeMatch → GetStreamUri（过摘要门）→ RTSP 100帧/12s → 快照 77KB → 无凭据 500，witness 标记行可 grep；Home Assistant Core 在本机 NixOS pip venv 上因原生依赖链（numpy/pyspeex_noise 需 GLIBC 2.43 vs 本机 2.42）不可稳定运行，HA 现场证人如实记为环境欠账，五站互通以第一方工具全量验证；PullPoint 事件与 G.711 音频仍为可选扩展。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 16. [[ch16-lab05-rtsp-mjpeg-report|第十六章]] 17. **第十七章：实战实录六**

# ONVIF 深度解析（十七）：实战实录六——lab06，互通收口

前五回实录把三层栈逐层装上板：发现（[[ch12-lab01-discovery-report|第十二章]]）、控制面（[[ch13-lab02-device-service-report|第十三章]]）、认证（[[ch14-lab03-auth-digest-report|第十四章]]）、Profile 与快照（[[ch15-lab04-media-snapshot-report|第十五章]]）、RTSP 取流（[[ch16-lab05-rtsp-mjpeg-report|第十六章]]）。但每一站的验收者都是我们自己准备的第一方工具——它们天然站在实现者认知的同侧：知道我们实现了什么，就照着我们的方言发问。lab06 把裁判权交出去：总装五站固件，请一个**不知道我们存在**的集成系统来当裁判。这就是「互通收口」。

按系列「先成文后实跑」的纪律（[[ch11-esp32s31-lab-plan|第十一章]]11.4），lab06 于 2026-10-26 上板实跑。设计决策保留原貌，与实测的出入在 17.5「计划外发现」逐项记账；对 lab02–lab05 能力的叙述一律按工程契约 [practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md)（[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)）§6 lab06 节的口径展开，各站实测以其各自实录章为准。

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

一条总装期纪律要提前立：lab05 的 rtsp_server 是**单客户端语义**（SPEC §6：raw socket、逐连接串行）——witness 观测期间不要并行第二个 RTSP 取流者；第二个并发连接的行为**本轮未测**（lab06 只观测了一段 RTSP 会话），记为待补项——单客户端串行是契约不是 bug，README 需如实记录。

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

1. **原样先跑**。HA 的 wsdiscovery 与我们的探针实现不同（Probe 数量、重发节奏、扫描窗口），是 lab06 要记录的实测项——**本轮 HA 未稳定运行，此项未测**（我们用单播探针实测 1/1 收到 ProbeMatch）。
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

各断面要抓到什么（本轮 tcpdump 三断面未采——sudo 留作用户侧补采；三层定位改由 HA debug 日志 + 板端标记行替代）：

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
| 传输层拒连/超时        | ③ 取流   | lab05 单客户端语义：第二并发取流者行为本轮未测      |

板端这本账在 run.log 里全程有标记行（SPEC §1 的 `$$$` 纪律），一次成功的 witness 会话应该把五个站的交付依次点亮：

```bash
# 板端全链标记行：时序即链路
grep '\$\$\$ ONVIF LAB' run.log
# 实测词表（固件沿用各模块原属站前缀，见 17.5）：LAB01 PROBEMATCH → LAB03 AUTH/SNTP
#   → LAB05 SVC READY/OP/SNAPSHOT/RTSP FRAME seq=…；LAB06 段仅 `witness` 命令触发
```

两本账按时间轴对齐：断面① 的 Probe 时间戳 ↔ 板端 PROBEMATCH 行；断面② 的每个 SOAP 请求 ↔ LAB02/03/04 标记行；断面③ 的 PLAY ↔ LAB05 FRAME 行的 seq 递增。最后是内存红线读数：witness 是第一次「ONVIF 全栈 + RTSP 推流」同框的长稳态，取流稳态 free_dma 不得低于 170KB（SPEC §4）——实测 243,195B（TEARDOWN 时），余量充足。

## 17.4 可选扩展展望：让设备学会说话（不进主链验收）

SPEC §6 lab06 把两个扩展明示为可选、不进主链验收——它们是 witness 收口之后的下一步，这里只做工程展望。

**扩展 A：PullPoint 事件 + 帧差运动检测。** witness 通过后，设备可以从「被动应答者」升级成「会说话的传感器」（[[ch07-ptz-events|第七章]]模型②，事实上的默认选择——纯客户端身份、NAT 全友好）。设备侧增量三件：

- tev 服务端点：CreatePullPointSubscription / PullMessages（长轮询：无消息按住应答直到超时）/ Renew / Unsubscribe，话题过滤 `tns1:VideoSource/MotionAlarm`；
- 检测算法零新硬件：双缓冲里的最新帧做降采样帧差（PSRAM），MotionAlarm true/false 的边沿去抖照抄 ch07 7.6 的纪律——抖动不除，跟着抽搐的就是 HA 里的自动化；
- 内存面：事件缓冲与挂起应答一律 PSRAM（SPEC §4 红线），一个挂起的 HTTP 连接对 esp_http_server 并发预算的影响要单独观测。

HA 侧是否把 MotionAlarm 落成 binary_sensor 实体——本轮 HA 未稳定运行、未验证。

**扩展 B：G.711 前向音频。** 板载 ES8389 codec 的音频通路在出厂 demo 验证过（[[ch11-esp32s31-lab-plan|第十一章]]11.1 的底牌表），SPEC §1 裁剪基座时被裁掉——所以这是「接回来」而不是从零写。ONVIF 面：Profile 挂 AudioEncoderConfiguration（G.711 μ-law，RTP 静态 payload type 0）、GetStreamUri 多一路、RTSP SDP 双 `m=` 行、RTP PCMU 按 20 ms 一包。64 kbps 的数据率对 2.77 Mbps 的空口实测吞吐是零头，真正的成本是新增采集→编码链路的任务栈与缓冲对 free_dma 的挤压——照例先量再上。语义边界：**前向音频**＝设备→客户端单向；双向对讲（backchannel）不做，不做的不假装会。

两个扩展共用一条纪律：主链互通与红线守住之前，不谈能力面扩张——「标称当广告、探测当合同」（[[ch09-interop-ecosystem|第九章]]9.1）同样约束我们自己。

## 17.5 实测记录

2026-10-26 实跑。`run.log` 入库，宿主侧留样入 `runs/`。板端标记行实际词表为
LAB01（发现）→ LAB03（鉴权/SNTP）→ LAB05（控制面 OP + RTSP）——onvif_svc.c 从
lab05 复制时 OP/SVC READY/SNAPSHOT 前缀仍为 LAB05、onvif_auth.c 仍为 LAB03，
LAB06 仅 console witness 命令（本轮未触发）。「总装站标记前缀归位到功能来源站」
记为待补项。

**HA 现场证人的环境边界（本轮最值钱的发现，两笔）**：

1. **H264 profile 墙**：HA 2026.2.3 的 onvif 集成只接受 `Encoding == "H264"` 的
   profile（`config_flow.py` 直接 `AbortFlow("no_h264")`）——本板只有 JPEG 编码档
   （ESP32-S31 无硬编 H264），配置流在建 entry 前必然中止。这不是互通 bug，是
   **集成侧的能力过滤**：JPEG-only 设备过不了 HA 的 onvif 摄像头集成。绕行路：HA
   的通用 RTSP camera 集成（不走 ONVIF，直接拉 `rtsp://<ip>:8554/mjpeg`）可出图
   （lab05 已证 ffmpeg 解码 180 帧/12s），但「零手工 URL 的 ONVIF 全自动」在
   JPEG-only 设备上不可达。
2. **HA Core NixOS pip venv 原生依赖墙**：`default_config` → `mobile_app` →
   `assist_pipeline` → `pyspeex_noise` 需 GLIBC 2.43，本机 NixOS 提供 2.42 →
   numpy/pyspeex_noise import 崩 → bootstrap 中止。最小配置
   （绕 default_config 只留 onvif + ffmpeg + http + api）可让 HA 起来并响应 API，
   但 onvif-zeep-async 的 async 单例在无 event loop 时 crash（RuntimeError），
   HA 子系统不稳定。结论：**HA Core 的 pip venv 在 NixOS 裸机上不可靠**，容器化
   （docker/HAOS）是正确部署形态——本环境无 docker。

**可执行的互通验证（第一方工具全链走通，非 HA 现场证人）**：

| 全链步                   | 工具                                        | 结果                                                                                                                                     |
| ------------------------ | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 发现 ProbeMatch          | `tools/onvif_probe.py --unicast`            | ✅ XAddrs=http://192.168.1.4:80/onvif/device_service                                                                                     |
| GetStreamUri（过摘要门） | `tools/onvif_smoke.py`（onvif-zeep 0.2.12） | ✅ rtsp://192.168.1.4:8554/mjpeg                                                                                                         |
| RTSP 取流 12s            | `tools/rtsp_ledger.py`                      | ✅ 100 帧完整到达                                                                                                                        |
| 快照                     | `curl /onvif-http/snapshot`                 | ✅ 77,624B JPEG                                                                                                                          |
| 无凭据 media             | curl POST                                   | ⚠️ 留样 500 + ter:ActionNotSupported（探针 Body 元素/命名空间未匹配白名单，未进摘要门）；「无凭据→NotAuthorized」已由 lab03 九行矩阵证明 |
| 未知 ProfileToken        | zeep                                        | ✅ 400 + ter:InvalidArgVal                                                                                                               |
| 内存红线                 | `status`                                    | ✅ free_dma ≥243KB                                                                                                                       |

**witness 标记行**：

```text
$$$ ONVIF LAB06 WITNESS <ha|frigate> result=<ok|fail>
```

本轮未触发（run.log 无此行）——按 H264 墙结论应记 `witness ha fail`，原因写正文不进标记行（固件模板两参，无 reason 槽位）。

SPEC §6 lab06 的验收三件套（发现→凭据→取流）在**协议层**已由前五站逐站证明；
lab06 的增量发现是：**互通收口的最后一公里不在设备侧，在集成侧的能力过滤**
（H264-only 假设）——这正是第三方裁判的价值：它问出了第一方工具永远问不出的
「你只有 JPEG 怎么办」。

tcpdump 三断面未采（sudo，留作用户侧补采）；ffplay 未跑（headless 宿主）。

### 17.5.1 Profile S 缺口补齐与统一测试集（2026-10-26 深夜追加）

对照 ONVIF Profile S MUST 清单盘出的缺口有八个操作（GetProfile 单数、
GetVideoSourceConfiguration(s)、GetVideoEncoderConfiguration(s)、
GetVideoEncoderConfigurationOptions、GetNetworkInterfaces、GetScopes），
本轮全部补进 onvif_svc.c（六个静态模板 + 网卡现拼 MAC/IP + Scopes 纯静态），
token 门从 snapshot/stream 两处硬编码泛化为 kOps 表字段。

**随之立起的统一测试集**：六站散落的验证工具收拢为套件级
`practice/onvif-labs/tests/`（runner + 每站一模块），21 项逐条 PASS/FAIL，
一键跑完并落 selftest.json——覆盖发现（含 AP 过滤组播的单播兜底）、控制面、
摘要门正/负路径、zeep 逐操作证据行、快照 JPEG magic、RTSP 信令 + 12s 成帧 +
**板端 TEARDOWN total 对账**（三本账不变量首次自动化：board=client 精确相等）、
Profile S 八操作、新操作鉴权门。板端源码修完烧完即跑，回归当场现形。

**测试集首战战果（四个真 bug，全是板子的）**：

1. **路由字符集缺冒号**：`svc_route_by_body` 的本地名扫描字符集漏了 `:`，
   `tds:GetSystemDateAndTime` 解析到冒号即断，永远返回 -1——**Body 权威路由从未
   真正生效过**，此前全部流量（包括 zeep）走的都是 SOAPAction 兜底。这也推翻了
   ch13 成文时「zeep 全程不发 SOAPAction、兜底零触发」的叙述：zeep 的
   `zeep/wsdl/messages/soap.py` `_set_http_headers` 对每请求**无条件**写该头。
   补一个字符，Body 路径首次上岗；ch13 已就地翻案。
2. **recv 不读满**：`httpd_req_recv` 单次调用不保证读满 content_len，TCP 分段时
   信封截断、Body 缺失，token 门随机误伤——时好时坏的 InvalidArgVal 即此。修为
   循环读满，五站副本同步。
3. **Options 模板 schema 违规**：`QualityRangeMin/Max` 是臆造元素，onvif.xsd 的
   `VideoEncoderConfigurationOptions` 是具体类型、必填子元素为
   `QualityRange`（tt:IntRange 的 Min/Max）——zeep 严格校验把应答解析成 None。
   第一版测试想退回 raw SOAP 字符串断言，被叫停：那会把违规固化成期望。改对模板，
   zeep 继续当最严裁判。
4. **Scopes 字段错位**：onvif:// scope 串的标准归属是 `tt:ScopeItem`
   （GetScopes ↔ ProbeMatch 对账字段），首版误放 `ScopeXAddr`（现行 schema 里
   0..1 的设备自身 XAddr 槽位）。改 ScopeItem 后 zeep 干净解析，无 raw 兜底。

另有一笔宿主侧：RTSP 是单客户端串行 accept 设计，`dash_keeper.sh` 看护循环
孵化的孤儿 ffmpeg 会占死唯一会话槽，新连接全部超时——这不是固件 bug，是
ch16 计划外发现第 6 笔（dashboard 不杀旧 ffmpeg）的活体复现。统一测试集的
RTSP 项现已前置清场（杀孤儿消费者再连），对账照常三本账齐。

终态：`tests/runner.py` 21/21 全绿，固件为 Profile S MUST 操作全集 + 路由/收包
双修版。CTT 差距从「8 个 MUST 缺失」收敛到「无 MUST 缺失」，剩余风险在长时间
压测下 httpd 的稳定性（间歇性挂死需串口复位，见 ch16 第 4 笔，未根治）与
Set 系操作（SetVideoEncoderConfiguration 等 OPTIONAL 项未实现）。

### 17.5.2 生产化重构：单一组件与内存统计（同夜追加）

五站各持一份 onvif 模块副本的「漂移税」在 Profile S 轮结清过一次账（一个字符的
修复同步五处），本轮付清本金：四模块收拢为套件级组件
`practice/onvif-labs/components/onvif/`（disc/auth/svc/rtsp/stats 五源文件 +
include/ 六头），六站经 `EXTRA_COMPONENT_DIRS` 挂接，`main/` 里的副本全部删除。

**边界三刀**：

1. **媒体依赖倒置**：组件不再 include 任何采集基座头——`onvif_media_io_t`
   三个函数指针（httpd/copy*latest/copy_latest_id）由宿主注入，站内直接绑
   `factory_stream*\*`。lab04 基座尚无 `\_id` 变体，按需校验（组件不强迫全量注入）。
2. **凭据留在 app 侧**：`onvif_auth_init(user, pass)` 改注入式，
   `onvif_secrets.h`（gitignore 纪律）不进组件。
3. **站点标记参数化**：svc 的 `$$$ ONVIF <marker> OP` 前缀改 cfg.marker
   （lab02..05 各用本站号，lab06 归位 LAB05，沿本章站点标记纪律）；
   disc/auth/rtsp 固定 LAB01/LAB03/LAB05（功能来源站身份）。

**能力旗标化**：`onvif_svc_config_t`（auth/users/profiles/stream_uri/profile_s）
在 init 时运行期装配操作表——未装配的操作走 ActionNotSupported 合规拒绝，
未引用的模板函数被 gc-sections 裁出固件，**存储占用随站点能力缩放**。
一处真雷：httpd 回调必须无条件必填（SOAP 端点每站都挂基座 80 端口），
旗标裁剪时漏配 io 块的站编译期零告警、上电即空指针——已在校验里钉死。

**内存统计入库（onvif_stats）**：评估内存占用的数据源，四层账目——

| 层           | 内容                                      | 本板实测（lab06 全能力档）               |
| ------------ | ----------------------------------------- | ---------------------------------------- |
| 静态缓冲登记 | uuid/ip/nonce_ring/sess 等编译期定长缓冲  | 1,424B                                   |
| 动态分配账本 | 带标签 heap_caps 包装（live/peak/allocs） | svc 317,440B + rtsp 308,763B（全 PSRAM） |
| 任务栈水位   | uxTaskGetStackHighWaterMark               | rtsp 任务 7,324B 余量（配额 8,192B）     |
| 堆面快照     | free_dma/free_spiram/min_free             | 242,719B / 11,397,436B / 225,368B        |

console `mem` 命令与 `$$$ ONVIF STATS` 标记行系列输出，测试集 T25 消费
（含 free_dma ≥170KB 红线断言）。svc 的 300KB 快照缓冲随 `profiles` 旗标
按需分配——lab02/03 档不占这 300KB，内存账随能力缩放与存储一致。

**存储占用评估**：`tools/size_report.sh`（idf_size.py 解析 .map，四层：
app 总量 vs factory 分区 / libonvif.a 归档明细 / main 归档 / 全组件 Top）。
lab06 全能力档实测：app 1,260,016B = factory 分区 32.0%；onvif 组件最大符号
rtsp_handle_connection 3,098B text、应答模板 rodata 单个 300–940B——控制面
在固件里的存储代价不足 app 的 2%。

**回归**：22 项测试集（原 21 + T25）全绿；六站全部编译通过，lab06 烧验。
「五站一致」自此是结构保证（单源组件）而非人工纪律（同步五份副本）。

## 17.6 小结

- lab06 = 总装 + 换裁判：五站固件合成一台完整设备（发现→鉴权→Profile→RTSP 全链
  标记行依次点亮），验收者从第一方工具换成第三方集成系统——实测发现**互通收口的
  最后一公里在集成侧**（HA 的 H264-only profile 过滤），不在设备侧。
- H264 墙是本轮最值钱的互通发现：JPEG-only 设备无法通过 HA 的 onvif 摄像头集成
  （`AbortFlow("no_h264")`），但 RTSP 流本身可被 ffmpeg/HA 通用 camera 消费
  （lab05 实测 180 帧/12s）——控制面合规 + 媒体面可解 ≠ 集成侧能力过滤能过。
- HA Core 的 pip venv 在 NixOS 裸机上因原生依赖链（numpy/pyspeex_noise → GLIBC 2.43
  vs 本机 2.42）不可靠；最小配置可绕 `default_config` 让 API 起来，但子系统不稳。
  容器化（docker/HAOS）是正确部署形态——本环境无 docker，如实为环境边界。
- ch09 六坑自查在实测中逐条有交付兜着（时钟→lab03 SNTP、双轨→lab02 同源模板、
  伪装→能力只报真实、双栈→合规 Fault 回落、extension→一行不多、SOAP 版本→各按
  绑定）；第三方裁判问出的「你只有 JPEG 怎么办」是第一方工具永远问不出的新账。
- 可选扩展不进主链：PullPoint 事件 + 帧差运动检测、G.711 前向音频；能力面扩张
  永远排在互通与红线之后。

实战篇至此收口，本章也是系列的末章。回望两个半场：前十章拆轮子——从 3702 端口的一声组播喊话（[[ch02-ws-discovery|第二章]]），到 SOAP 信封、摘要认证、Profile 配置、RTSP 取流，再到生态互审与协议设计的反思；后六章装轮子——把同一套三层栈亲手装进一块 ESP32-S31-Korvo-1，从被探到（[[ch12-lab01-discovery-report|第十二章]]）到被取流（[[ch16-lab05-rtsp-mjpeg-report|第十六章]]），最后交给不知道我们存在的集成系统审判。一问（凭什么互通）一答（亲手造一台被互通的设备）之间，ONVIF 不再是规范文本里的名词，而是板上跑着的、可抓包对账的字节。lab06 实测回填之日，就是系列真正完稿之时——回到 [[onvif-deep-dive|系列索引]]。
