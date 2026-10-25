---
title: "ONVIF 深度解析（十六）：实战实录五——lab05，RTSP/RTP 取流全链"
date: 2026-10-25 12:00:00
description: "实战篇第五站：8554 端口 raw socket 手写 RTSP 状态机（OPTIONS/DESCRIBE/SETUP/PLAY/TEARDOWN，TCP interleaved 优先、UDP 第二档伺候 ffmpeg 默认），MJPEG 按 RFC 2435 封 RTP——量化表带内 Q=255（132B 头）、type 0 以板上 SOF 逐字节证据定案（Y 2x1/U 1x1/V 1x1）、四张 DHT 与 ffmpeg 标准表逐字节相同（缩略格式合规、无 Huffman 墙）；GetStreamUri 过 lab03 摘要门（WSDL 要求 StreamSetup 结构）。实测三本账：单 boot 三会话板端 552 帧、账本客户端 188/12s（15.7fps）、ffmpeg TCP 180 / UDP 179 解码，seq 会话内连续无丢帧；free_dma ≥243KB。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 15. [[ch15-lab04-media-snapshot-report|第十五章]] 16. **第十六章：实战实录五**

# ONVIF 深度解析（十六）：实战实录五——lab05，RTSP/RTP 取流全链

> [!info] 实测状态
> lab01–lab04 已上板验收（[[ch12-lab01-discovery-report|第十二章]]至[[ch15-lab04-media-snapshot-report|第十五章]]），本章 lab05 于 2026-10-26 实跑收口（九项验收全过，实测记录见 16.5）；lab06 未实跑。设计决策与算术推算保留原貌，与实测的出入在 16.5「计划外发现」逐项记账。

前十五章拆完了轮子、也铺好了底盘：发现（lab01，已上板）与 SOAP 控制面（lab02–lab04，框架已立——[[ch13-lab02-device-service-report|第十三章]]至[[ch15-lab04-media-snapshot-report|第十五章]]）把三件套的前两层各就各位，快照（lab04 设计）给 Media Profile 留好了产出像素的出口。但那终究只是一张静止的图——媒体面还没动起来。本章在 ESP32-S31-Korvo-1 上把 [[ch06-rtsp-streaming|第六章]]从 NVR 侧拆解过的取流链在设备侧重新装一遍：8554 端口上用 raw socket 手写 RTSP 信令状态机，把 17.5–18.3KB 的成品帧（暗光场景实测）按 RFC 2435 切成约 13 个 RTP 包（上游亮场基线为 25,165 B/18 包，见 16.3 两套锚并列），最后用 esp32-video-tran 验证过的帧计数对账方法学证明「每一帧都完整到达」。

工程契约见 [practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md) §6 lab05 节（[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)）；方案叙事见 [[ch11-esp32s31-lab-plan|第十一章]]，本文不重复论证，只写 lab05 自己的设计账。

## 16.1 定位：第六章取流链的设备侧镜像

第六章站在客户端走完了 `GetStreamUri → DESCRIBE/SETUP/PLAY → RTP`；lab05 是同一条链的镜像实验——这次我们坐在应答的那一头。前四个 lab 把控制面铺平之后，lab05 只剩两块增量：

1. **控制面补最后一格**：Media 服务新增 `GetStreamUri` 应答，返回 `rtsp://<板端IP>:8554/mjpeg`——第六章 6.1 节里「先声明怎么传、再给你地址」的 StreamSetup 有了真实落点。板端 IP 必须取 DHCP 后的 netif 实际地址，禁写死（SPEC §5，与 lab01 的 XAddrs 同一条纪律）。
2. **媒体面立新模块 `rtsp_server`**：8554/tcp raw socket 上的串行状态机 + RFC 2435 封包器——系列第一段全新媒体代码，也是 ch11 把它单独成站的原因。

| 第六章拆过的环节             | lab05 要造的设备侧                         | 验收面                         |
| ---------------------------- | ------------------------------------------ | ------------------------------ |
| StreamSetup / GetStreamUri   | Media 服务补 GetStreamUri 应答模板         | python-onvif-zeep 拿到可用 URL |
| DESCRIBE + SDP（6.4）        | 手拼 SDP：`m=video 0 RTP/AVP 26`           | ffprobe 认出 MJPEG/640×480     |
| SETUP 的 Transport 头（6.3） | 传输协商：TCP interleaved 优先，UDP 第二档 | VLC/ffmpeg 两档都能出图        |
| PLAY 与 RTP-Info（6.3）      | 会话状态机 + RTP 发送循环                  | 12 秒窗口帧计数对账            |
| RTP 承载与 $ 交织帧（6.5）   | RFC 2435 封包器                            | 抓包逐字节校验头 8 字节        |

端口用 8554 而非 RTSP 知名端口 554：SPEC §5 的端口表统一分配——80（SOAP + 快照 + `/stream` HTTP MJPEG 对照面）、3702/udp（WS-Discovery）、8554（RTSP）是这块板子的三张面孔，81 保留给对照面 status 页。ffplay/VLC/ffmpeg 对显式端口的 rtsp URL 一视同仁，没有兼容代价。

## 16.2 rtsp_server：raw socket 上的串行状态机

**为什么 raw socket 而不是 esp_http_server**：RTSP 长得像 HTTP 但不是 HTTP——请求行是 `OPTIONS rtsp://… RTSP/1.0`，响应行是 `RTSP/1.0 200 OK`，每个请求带必须回显的 `CSeq`，会话状态由 `Session` 头携带。esp_http_server 的 URI 路由模型装不下这套语法，直接用 lwIP socket 自写。这与 lab02「模板 XML 不引栈」是同一克制哲学：信令方法是有限白名单，手写状态机足够，还完全可控。

**单客户端、逐连接串行**：accept 循环一次只服务一条连接；PLAYING 会话结束（TEARDOWN 或空闲超时）前，新到达的连接排在 listen backlog 里等待，不并发服务。SPEC §6 明文「逐连接串行，单客户端语义」，理由有三：内存红线（§4）下不值得为并发会话复制 RTP 发送缓冲；上游基座的最新帧双缓冲本来就是「慢消费者丢整帧」语义（见 16.4），一个编码器喂多个 RTP 会话没有增益；第三个理由是诚实——这是实验形态的取舍，把「单客户端」写进 README，而不是装成 N 路并发（[[ch09-interop-ecosystem|第九章]]审判过的能力伪装，轮到我们自己头上一条都不沾）。

一次取流的完整节奏，设备侧视角：

```text
ffplay / VLC / ffmpeg                    rtsp_server（8554/tcp raw socket）
  │ ── OPTIONS rtsp://<ip>:8554/mjpeg ─► │  200 + Public: OPTIONS,DESCRIBE,SETUP,PLAY,TEARDOWN
  │ ── DESCRIBE …/mjpeg ───────────────► │  Accept: application/sdp
  │ ◄─ 200 OK + SDP（m=video 0 RTP/AVP 26）│
  │ ── SETUP …/mjpeg/trackID=0 ────────► │  Transport: RTP/AVP/TCP;unicast;interleaved=0-1
  │ ◄─ 200 OK + Session: <id>;timeout=60 │  会话建立，帧消费者槽位就位
  │ ── PLAY（带 Session）──────────────► │
  │ ◄─ 200 OK + RTP-Info: url…;seq…;rtptime│
  │ ◄─ '$'+ch0+len+RTP(JPEG) ≈13 包/帧 ──│  15.6fps → ≈200 包/s（16.3 的算术）  │
  │ ── OPTIONS/SET_PARAMETER（保活）───► │  空闲 60s 单方面 TEARDOWN 并释放
  │ ── TEARDOWN ───────────────────────► │  会话回收，打印 teardown 后 heap 三件套
```

逐方法的设计账：

- **OPTIONS**：应答 `Public` 白名单，兼任保活（ch06 6.5 节保活三选一的最常见档）；`SET_PARAMETER` 同样回 200——第六章的结论是设备应同时认这两种保活，症状「固定 30/60 秒整点断流」我们不留给客户端复现的机会。
- **DESCRIBE**：手拼 SDP 模板。MJPEG 与第六章 6.4 节 H.264 的 SDP 差一条本质：payload type 26 是 RFC 3551 的**静态**类型（JPEG/90000），不需要 `a=rtpmap` 现场约定，更没有 `sprop-parameter-sets` 那样的带外钥匙——JPEG 每帧自描述，参数装在 RFC 2435 的 8 字节头里逐帧携带。模板纪律照旧：一行不多。

```text
v=0
o=- 1234567 1 IN IP4 <板端IP>
s=ONVIF LAB05 MJPEG
c=IN IP4 0.0.0.0
t=0 0
a=control:rtsp://<板端IP>:8554/mjpeg
m=video 0 RTP/AVP 26
a=control:rtsp://<板端IP>:8554/mjpeg/trackID=0
```

- **SETUP**：解析 Transport 头，两档匹配。第一档 `RTP/AVP/TCP;unicast;interleaved=0-1`（应答回显选定 transport + `Session: <id>;timeout=60`）——优先 TCP 的理由：第六章 6.5 节的防火墙论证（一条出站连接全搞定，无端口对协商），外加本实验室自己的教训——这台家庭 AP 的路径对称性已经在 lab01 坑过组播应答（[[ch12-lab01-discovery-report|第十二章]]），对「设备反向打客户端高端口」的 UDP 形态天然警惕。第二档 `RTP/AVP;unicast;client_port=A-B`（偶/奇端口对，RFC 3550 硬规定）→ 应答 `server_port=8556-8557`（设计预留，按 SPEC §5 在 README 声明、避开端口表与黑名单）。UDP 仍要做的原因很硬：**ffmpeg 默认先走 UDP**（ch06 6.7 节），没有第二档等于默认命令行全挂。代价照第六章 6.1 节表格记账：TCP 换来可达性，付出队头阻塞，由 16.4 的丢帧语义兜住。
- **PLAY**：应答 `RTP-Info: url=…;seq=<起始序号>;rtptime=<起始时间戳>`，客户端靠它对齐第一帧（ch06 6.3 节）。
- **TEARDOWN 与超时**：释放 socket、注销帧消费者、停 RTP 发送循环；空闲 60s 同样单方面回收。SPEC §4 的观测纪律照抄：启动、LISTENING、会话建立、PLAYING 稳态、teardown 五个里程碑各打一行 `free DMA/internal/SPIRAM` 三件套。

**鉴权与 RTCP 的边界**（先立好，不装）：第一版 DESCRIBE 不套 RTSP Digest，第六章 6.3 节的「首轮 401 挑战」在 lab05 不出现——内网明文实验形态，与控制面 lab02–lab04 同口径；HA/Frigate 若强制凭据，归 lab06 互通收口处理。RTCP 的交织通道 1 预留但第一版不发 SR——第六章 6.5 节的「质量仪表盘」暂时缺位，个别客户端靠 SR 判超时的行为列入观察清单。

**内存纪律**：RTP 封包缓冲与 SDP 应答一律 PSRAM 分配（SPEC §4 红线：内部 RAM 只留栈与 socket 系统缓冲）。对账起点用 lab01 的实测账：启动序列 free_dma 356,227 → 274,983 B（无流客户端）；上游推流稳态 ≈190KB 是预期落点，红线 170KB——lab05 实测读数见 16.5（LISTENING 259,567B 起、PLAYING/TEARDOWN 243,119–243,419B，全程高于红线）。

## 16.3 MJPEG 封 RTP：RFC 2435 与帧长算术

**吞吐算术**——两套锚点并列：上游基线（亮场，25,165 B/帧）：25,165 ÷ 1400 = 17.97 →
**18 包/帧**（末包 1,365 B）、13–15 fps ≈ **234–270 包/s**、码率 ≈ **2.77 Mbps**；
本轮实测（暗光，17,484–18,309 B/帧）：≈13 包/帧、15.6 fps、码率 ≈ **2.24 Mbps**。
量级差来自场景亮度（暗光熵低、帧短），封包器与上限不受影响。1400 B 的选择是算过
MTU 的：IP 20 + TCP 20 + $ 帧头 4 + RTP 12 + JPEG 头 8 + 1400 = 1464 < 1500，避开
IP 分片（RFC 2435 §4.3 的 SHOULD）。编码侧上限 16.667 fps 是天花板，实际帧率由空
口与消费节拍决定。

**8 字节主 JPEG 头**（RFC 2435 §3.1，SPEC 点名「抓包逐字节校验」的对象）逐字段对齐到本板：

| 偏移 | 字段            | lab05 取值                     | 依据                                                                            |
| ---- | --------------- | ------------------------------ | ------------------------------------------------------------------------------- |
| 0    | type-specific   | 0（逐行扫描）                  | RFC §3.1.1：无解释则置 0                                                        |
| 1–3  | fragment offset | 本包载荷在帧内的字节偏移，大端 | 同帧约 13 包各不相同，乱序重组的锚点                                            |
| 4    | type            | 0 = 4:2:2 采样                 | 板上 SOF0 实测 Y 2x1 / Cb 1x1 / Cr 1x1，与 RFC type 0 表逐字段吻合（16.3 对账） |
| 5    | Q               | 量化表指针（对齐决策见下）     | 1–99 走 IJG 公式，≥128 走带内表                                                 |
| 6    | width           | 80（= 640/8）                  | 8 像素倍数编码，上限 2040                                                       |
| 7    | height          | 60（= 480/8）                  | 同上                                                                            |

一个必须写进注释的直觉陷阱：**type 1 不是 4:2:2 而是 4:2:0**——RFC 2435 §4.1 的表写得明白（type 0 色度只水平 2:1 下采样即 4:2:2；type 1 水平垂直都下采样即 4:2:0），凭直觉填 type 就等着色度错位的花屏。板上摄像头 SC101IOT（PID 0xda4a）出 640×480 UYVY，经 PPA 转 RGB565 后由 esp_new_jpeg 硬件编码，上游配置 `sub_sample = JPEG_DOWN_SAMPLING_YUV422`——所以填 0，上板时再以编码器 SOF 采样因子复核一遍。

**载荷形态**：RFC 2435 用 JPEG 的**缩略格式**（abbreviated format）——载荷是单一熵编码扫描，SOI/DQT/SOF/DHT/SOS 头段全部剥掉，由解码端拿 8 字节头按 RFC 附录 B 重建。封包器要做的定位只有一处：SOS 段之后第一个字节起、EOI 之前止。两条硬约束随之而来：Huffman 表必须是 Annex K.3 标准表（type 0 的固定映射，没有带外通道）；类型 0 禁止携带重启标记（要带得换 64–127 段外加重启头，第一版不碰），上板需核对编码器输出无 DRI。

**量化表对齐**（ch11 风险表第一条的具体形状：参数与编码器输出不匹配即花屏）。上游编码参数固定 `image_quality = 80`，两条候选路：

1. **公式路**：若 esp_new_jpeg 的 DQT 恰按 IJG 公式从 quality 生成（Q=80 → S = 200 − 2×80 = 40，即 Annex K 基准表 0.4 量级缩放），则头里填 Q=80、剥掉 DQT 即可——零带内开销，但押注「编码器公式与 RFC 公式逐字节等价」这个待验证假设。
2. **带内路**（保守首选）：头里填 Q=255，把编码器 DQT 原样抄进量化表头（type 0 两张表、各 64 字节 zig-zag 序，加 4 字节头共 132 B）放每帧首包——不依赖任何公式等价，代价是每帧 132 字节与解码端逐帧重载。

两路都以「抓包逐字节校验头 8 字节 + ffmpeg 环回解码」收口；若实测发现编码器用非标 Huffman 或带 DRI，两条路一起死，只剩固定 Q 档重配编码器再封包这一条退路。

**实测对账（2026-10-26，全部通过）**：板上成品 JPEG 逐字节解析——SOF0 采样因子
**Y 2x1 / Cb 1x1 / Cr 1x1**（= RFC type 0 表，直觉陷阱未触发）、**无 DRI**（type 0
合规）、双 DQT 各 64B 系数；四张 DHT 与 `ffmpeg -huffman default`（标准 Annex K）产出的
表**逐字节相同**——「两条路一起死」的退路未触发，带内 Q=255 路全量合规。宿主侧
验证用「ffmpeg 标准表 JPEG 为 oracle 逐字节比 DHT」完成（注意：直接 `-i x.jpg -frames:v 1`
生成的 oracle 默认 `-huffman optimal`，会得出假 mismatch——比对必须用 `-huffman default`）。

封包器设计草案（未实测）：

```c
/* lab05 封包器设计草案（未实测）：RTP 头 12B + RFC 2435 主 JPEG 头 8B + 单一分片 */
static void rtp_send_frame(const uint8_t *scan, size_t len, uint32_t ts)
{
    static uint16_t seq;
    size_t off = 0;
    do {
        size_t n = MIN(1400, len - off);   /* 1400B 载荷避开 IP 分片 */
        bool last = (off + n == len);
        uint8_t hdr[20];                   /* [0,12) RTP；[12,20) 主 JPEG 头 */
        rtp_fill(hdr, seq++, ts, last);    /* PT=26；末包置 M 位 */
        hdr[12] = 0;                       /* type-specific：逐行扫描 */
        put_be24(hdr + 13, off);           /* 帧内字节偏移（大端） */
        hdr[16] = 0;                       /* type 0 = 4:2:2 */
        hdr[17] = g_rtp_q;                 /* 量化表指针（16.3 对齐决策） */
        hdr[18] = 80;                      /* 640/8 */
        hdr[19] = 60;                      /* 480/8 */
        rtsp_interleave_send(0, hdr, sizeof hdr, scan + off, n); /* 通道 0 */
        off += n;
    } while (off < len);
    s_session.frames_sent++;               /* 末包完整写出才计数（16.4） */
}
```

**时间戳与 M 位**：RTP 时钟 90kHz，同一帧全部分片共享同一时间戳，末包置 M 位——客户端以「fragment offset 0 起包、M 位止包」识别完整帧（RFC §4.3），这也是 16.4 抓包侧对账的计数锚点。

## 16.4 帧计数对账：方法学从 HTTP 平移到 RTP

ch11 给 lab05 定的验收硬指标不是「能出图」而是「每一帧都完整到达」，方法学直接继承 esp32-video-tran：**板端发送侧计数 ↔ 宿主接收侧计数，两边对得上才算数**。

方法学的出处是上游第 3 轮实测（HTTP MJPEG 对照面）：宿主 `curl` 抓 12 秒 `/stream` 落盘，python 数 SOI/EOI 边界；板端 `frames_sent` 只在整帧写完后 +1。结果 165 = 165 精确一致——第 166 个 SOI 是抓流窗口自身截断的宿主行为，不是板子丢帧。`frames_encoded − frames_sent` ≈ 被慢消费者跳过的整帧，同一套口径平移过来。

RTSP 断面上的对账变成**三本账**：

| 账本       | 计数点                                                            | 工具                     |
| ---------- | ----------------------------------------------------------------- | ------------------------ |
| 板端发送侧 | `frames_sent`：一帧的末包（M 位）完整写入 socket 才 +1            | 控制台 + run.log         |
| 抓包侧     | 8554 断面上「offset 0 包 … M 位包」的成帧数（即时间戳去重数）     | tcpdump + 解析脚本       |
| 宿主解码侧 | ffmpeg 解码输出帧数——每张完整 RTP 帧解一张 JPEG，EOI 计数的等价物 | `ffmpeg -t 12 -f null -` |

判据：三账相等 = 每一帧完整到达且可解码。SPEC 写死「12 秒采样窗口无丢帧」。80 端口的 `/stream` HTTP MJPEG 对照面在这里多了一个用途——**二分定位**：同一时段 HTTP 对照面帧数对、RTSP 不对，锅在 RFC 2435 对齐（16.3）；两边都不对，锅在编码器/空口。

**丢帧语义与背压**：interleaved TCP 遇丢包重传、队头阻塞（ch06 6.1 节），发送循环按最新帧双缓冲的语义**只丢整帧、绝不半帧**——保住三本账的可解释性，丢帧率可直接从 `frames_encoded − frames_sent` 读出。这是把上游「慢消费者丢帧」纪律原样搬进 RTP 会话。

lab05 专属风险表（系列级风险见 ch11 11.5 节，不重复）：

| 风险                     | 症状                 | 缓解                                          |
| ------------------------ | -------------------- | --------------------------------------------- |
| RFC 2435 量化表约束      | 花屏 / 绿屏 / 解不动 | 16.3 两条对齐路 + 逐字节校验；Q 档固定不漂    |
| type 字段直觉陷阱        | 色度错位的花屏       | type 0 = 4:2:2 以 RFC 表为准；上板核对 SOF    |
| ffmpeg 默认先 UDP        | 默认命令行拿不到流   | 双档都验收；README 写明 `-rtsp_transport tcp` |
| 2.4G 空口 + TCP 队头阻塞 | fps 下探、整帧跳过   | 丢整帧语义；fps 与丢帧入对账表                |
| RTCP 缺位                | 个别客户端判超时断流 | 通道 1 预留；ffplay/VLC 行为列入观察清单      |
| RTSP 无鉴权              | 严格客户端拒绝取流   | 明示边界；凭据接入归 lab06 互通收口           |

## 16.5 实测记录

2026-10-26 实跑，板 IP=192.168.1.4（本轮 DHCP，与 lab01–04 同址）；`run.log` 53.8KB
（`wc -c` 实测 53,787B）入库（`practice/onvif-labs/lab05-rtsp-mjpeg/run.log`，末尾含两段
补采标注），宿主侧留样入 `runs/`。固件版本串 `v4.5.2-78-g1cae212d-dirty`（hash 为构建
时点提交，其后因凭据页清理被 amend 重写）。

| 验收项                      | 证据形态                                                                                                                                                 | 实测结果                                                                                                                                                                                                                                                                                                                             |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ffplay/VLC 出图             | ffmpeg TCP/UDP 双档解码（headless 宿主，以 `-f null` 帧计数代替截帧）                                                                                    | ✅ TCP 180 帧 / UDP 179 帧（12s）                                                                                                                                                                                                                                                                                                    |
| DESCRIBE 应答 SDP 原文      | 账本客户端留样（`runs/rtsp-ledger.log` 前四行）                                                                                                          | ✅ `v=0/o=-/s=ONVIF LAB05 MJPEG/m=video 0 RTP/AVP 26`                                                                                                                                                                                                                                                                                |
| SETUP 双档协商（TCP/UDP）   | run.log `SETUP transport=TCP/UDP` + 双档解码各跑一轮                                                                                                     | ✅ 两档都会话建立并出流                                                                                                                                                                                                                                                                                                              |
| 主 JPEG 头 8 字节逐字节校验 | 宿主侧对板上成品 JPEG 的标记级解析（SOI→SOS→EOI 全路径，含 DQT/DHT/SOF 字段）                                                                            | ✅ type 0（Y 2x1/U 1x1/V 1x1）、W=80、H=60、双 DQT 各 64B、无 DRI                                                                                                                                                                                                                                                                    |
| 帧计数三本账（12s 窗口）    | 板端 FRAME 标记 / 账本客户端成帧 / ffmpeg 解码                                                                                                           | ✅ 会话1：板 188 ↔ 账本 188（精确相等）；会话2：板 182 ↔ ffmpeg TCP 解码 180；会话3：板 182 ↔ ffmpeg UDP 解码 179。解码差值 = PLAY→解码器首帧就绪的启动段，会话内 seq 连续无丢帧。口径注记：会话2 板端从 I(18213) 拖到 I(40103) 共 21.89s——ffmpeg 到 12s 停读后，板端 send 阻塞在 TCP 窗口上直至客户端断开，属长连接停止语义而非丢帧 |
| PLAYING 稳态 free_dma       | 里程碑三件套打点                                                                                                                                         | ✅ 243,419B（≥170KB 红线）                                                                                                                                                                                                                                                                                                           |
| 实测 fps / 吞吐             | 会话1：188 帧 / 12.035s = **15.62fps**；帧长 17,484–18,309 B → ≈2.24 Mbps。板端编码 29fps 而 RTSP 发 15.6fps：差值来自发送耗时（消费者节拍），非丢帧策略 | ✅                                                                                                                                                                                                                                                                                                                                   |
| 机器可读标记行              | `$$$ ONVIF LAB05 FRAME seq=<n> bytes=<n>` ×552（三会话：188/182/182）                                                                                    | ✅                                                                                                                                                                                                                                                                                                                                   |

**里程碑与 heap 三件套**（`run.log`；LISTENING/SETUP/PLAYING/TEARDOWN 四档全打）：

```text
rtsp: $$$ ONVIF LAB05 RTSP LISTENING port=8554
rtsp: heap@LISTENING free_dma=259567 free_internal=291575 free_spiram=13374432
rtsp: SETUP transport=TCP
rtsp: heap@PLAYING  free_dma=243419 free_internal=275427 free_spiram=11404728
rtsp: TEARDOWN by client
rtsp: heap@TEARDOWN free_dma=243231 free_internal=275239 free_spiram=11398100
```

**Bad case**：无凭据 GetStreamUri → HTTP 500 + `s:Receiver`/`ter:NotAuthorized`
（`runs/fault-nocreds-GetStreamUri.res.xml`，板端 `AUTH deny reason=no_token user=-`）；
未知 ProfileToken → 400 + `ter:InvalidArgVal`（`runs/fault-GetStreamUri-unknown-token.res.xml`）。

**解码完整性与色度对照**（补采段；ffmpeg 双档全量 stderr 落 `runs/ffmpeg-tcp.log` /
`runs/ffmpeg-udp.log`——TCP 120 帧/8s、UDP 119 帧/8s，≈15fps）：从 RTSP 流解出的首帧
与同时刻 `/onvif-http/snapshot` 各转 RGB24 比通道均值——RTSP 解码帧
R=91.2/G=91.7/B=87.0，快照 R=91.1/G=91.7/B=87.0，**通道均值最大差 0.1**（Huffman
表错配的失真通常 >60）——缩略格式 + 标准表假设的端到端色度验证闭环。

**计划外发现**（本轮四件）：

1. **Huffman「墙」证伪**：成文期风险表把「编码器非标 Huffman 表」列为两条封包路
   一起死的顶级风险——实测四张 DHT 与 ffmpeg `-huffman default`（标准 Annex K）逐字节
   相同，缩略格式全量合规。比对时有个必须写下的坑：用 ffmpeg 直接产出的 JPEG 做
   oracle 时，其 mjpeg 编码器**默认 `-huffman optimal`**（按内容优化表），会得出假
   mismatch——oracle 必须显式 `-huffman default`。
2. **lwip 套接字池 EMFILE**：多轮 HTTP 请求的 TIME_WAIT 叠加 RTSP 会话套接字，把
   默认 10 槽的 lwip 池打爆——症状是 httpd `accept (23)`、新 HTTP 连接全部空回复，
   离真因隔一层。`CONFIG_LWIP_MAX_SOCKETS=16` 修掉；凡长连接服务与 HTTP 控制面
   共存的形态都要预设此值。
3. **GetStreamUri 的 WSDL 入参**：zeep 严格校验要求 StreamSetup 结构（ProfileToken +
   Stream=RTP-Unicast + Transport.Protocol=RTSP），裸 ProfileToken 会在客户端序列化
   阶段被拒——嵌套 dict 传参（客户端侧问题，非设备端）。
4. **量化表头按 ffmpeg 对齐为 132B**：MBZ(1)+Precision(1)+Length(2)=128+128B 系数
   （Pq|Tq 字节不进表数据）——成文期「加 4 字节头共 132 B」的总量正确，内部布局以
   `rtpenc_jpeg.c` 为准逐字节落定。

宿主侧环境事实：curl 打内网 IP 需 `--noproxy '*'`（本机 shell 挂 127.0.0.1:7897 代理，
502 皆代理截走）；`file` 命令走 `nix shell nixpkgs#file`。

## 16.6 小结

- lab05 = 第六章取流链的设备侧镜像，实测三本账闭环：单 boot 三会话板端 552 帧、
  账本客户端会话1 精确 188/188、ffmpeg TCP 180 / UDP 179 解码（差值为启动段，
  会话内 seq 连续无丢帧）。
- RFC 2435 对齐账逐字节落定：type 0（板上 SOF Y 2x1/U 1x1/V 1x1 证据）、量化头
  132B（MBZ/Precision/Length + 纯系数）、四张 DHT 与 ffmpeg 标准表逐字节相同——
  成文期「两条路一起死」的退路未触发；oracle 必须显式 `-huffman default` 是本轮
  最值钱的防坑注脚。
- 信令五方法 + 双档传输全通：TCP interleaved 与 UDP 默认档 ffmpeg 都能解；
  60s 空闲回收、TEARDOWN、RTP-Info 起点对齐实测可用。
- 诚实边界不变：单客户端、无 RTSP Digest、无 RTCP SR、UDP 档依赖 AP 路径对称性
  ——全部 README 明示。
- 上板新账四笔：Huffman 墙证伪（oracle 的 `-huffman optimal` 陷阱）、lwip 套接字池
  EMFILE、GetStreamUri 的 StreamSetup 入参、132B 量化头内部布局——设计与实现的
  最后一批缝隙在实测中合拢。

媒体面立起来之后，三件套在这块板上就齐了——最后一站不再是新协议，而是把前五个 lab 总装成一台「普通 ONVIF 摄像机」，让 Home Assistant 或 Frigate 零手工填 URL 地完成发现、凭据、取流三步。[[ch17-lab06-interop-harness-report|第十七章：实战实录六——lab06 互通收口]]。回到 [[onvif-deep-dive|系列索引]]。
