---
title: "ONVIF 深度解析（十二）：实战实录一——lab01，从烧录到被探到"
date: 2026-10-25 12:00:00
description: "实战篇第一站落地实录：在裁剪版 factory_demo 基座（采集→PPA→硬件 JPEG→双缓冲 + WiFi STA + 串口控制台）上叠加 243 行的 onvif_disc 应答器，让 ESP32-S31-Korvo-1 加入 239.255.255.250:3702 组播、对 Probe 回 ProbeMatch——从按 VID:PID 定位烧录口、esptool 式 RTS 复位串口取证，到单播直探 4/4、组播路径不对称的双端对账，板端 run.log 与宿主 runs/*.log 两账互证，发现面就此闭环。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 11. [[ch11-esp32s31-lab-plan|第十一章]] 12. **第十二章：实战实录一**

# ONVIF 深度解析（十二）：实战实录一——lab01，从烧录到被探到

## 12.1 引言：方案的第一块里程碑

[[ch11-esp32s31-lab-plan|第十一章]]把实战方案写成了纸面契约：三层协议栈映射成三个固件模块、六个里程碑、风险清单与验收方法，「先成文后实跑」。本章是第一块落地的里程碑——**lab01-discovery，2026-10-25 上板验收通过**，第十一章 11.4 文末那条「已落地」预告的完整实录就在这里。

lab01 只回答一个问题：**这块板能不能被一个标准 WS-Discovery 客户端探到**。发现是 ONVIF 三件套的第一层（[[ch02-ws-discovery|第二章]]拆过的 Probe→ProbeMatch 问答）——这一步不成立，后面的 SOAP 控制面与 RTSP 取流都是空中楼阁。答案是成立，而且实测顺手挖出一个纯纸面规划发现不了的工程事实：**家庭 AP 的组播路径不对称**——组播 Probe 板端 4/4 收到并回包，但其单播应答宿主 0/4 送达。这个发现本身恰好论证了 SPEC 把验收定为「双端原文对账」的正确性：任何一端的单边日志都会把它漏掉。

证据纪律沿用本仓 lwIP 实验室的 `$$$` 标记行传统（SPEC §1）：板端关键事件落一行 `$$$ ONVIF LAB01 <event> <k=v>` 机器可读标记，宿主探针也打 `$$$ HOST PROBEMATCH` 对称标记——两端 grep 即对账。

> [!tip] 配套工程：practice/onvif-labs/lab01-discovery（2026-10-25 上板验收通过）
> [README](/static/code/#/onvif-labs/lab01-discovery/README.md)（拓扑/复现命令/实测摘录）
> · 应答器实现：[onvif_disc.c](/static/code/#/onvif-labs/lab01-discovery/main/onvif_disc.c)
> · 工程契约：[SPEC](/static/code/#/onvif-labs/SPEC.md)。板端证据 `run.log` 与宿主侧
> `runs/probe-*.log` 随工程入库——本章引用的每一行，仓里都有原文可对。

## 12.2 基座与固件形态：裁剪决策与内部 DMA 纪律

固件一句话：**stream-first 的裁剪版 factory_demo，加一个 onvif_disc 增量模块**（板卡 ESP32-S31-Korvo-1，RISC-V，IDF target `esp32s31`）。裁剪的每一条都写在 SPEC §3/§4，这里讲「为什么」：

| 决策 | 内容                                                           | 依据                                                                           |
| ---- | -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 留   | 采集→PPA→硬件 JPEG→双缓冲管线、WiFi STA、串口控制台            | 媒体面已被 30 分钟烤机验证（第十一章 11.1）；串口控制台是取证通道              |
| 留   | BSP 与 esp_video / esp_cam_sensor / esp_new_jpeg 组件树        | dependencies.lock 固化、离线可重复（SPEC §3）；传感器时序不敢重写              |
| 留   | 两个本地补丁副本（esp_cam_sensor、esp_lvgl_adapter）整目录迁移 | esp_lvgl_adapter 的 6.1 补丁副本是基座能编过的关键（SPEC §3 明令禁止重新解析） |
| 去   | LVGL/UI 画布、mmap 资产分区                                    | UI 与 WiFi 驱动抢同一池内部 DMA RAM——`esp_wifi_init` 曾因此 `ESP_ERR_NO_MEM`   |
| 去   | 触摸、USB HID、音频                                            | 无 UI 即无输入面；板载 ES8389 留给 lab06 之后的可选扩展                        |

注意第三行：UI 裁掉了，但让基座「能编过、能跑稳」的补丁组件一个不动——裁剪的原则是**删功能，不删地基**。

启动序列（`main.c` 全文 48 行）延续 factory_demo 的 stream-only 形态：控制台先建（REPL 任务要在堆还富时创建）→ 相机先于 WiFi（共享 I2C 归相机管，显示句柄传 NULL）→ stream init 前后各打一次 free DMA → 最后 `onvif_disc_init()`。内部 DMA 的账本直接进了 run.log：

```text
I (1333) factory_stream: heap before stream init: free DMA=356227, SPIRAM=15650136
I (1355) factory_stream: encode buffers: rgb=0x50125a80(ext_ram=1) jpeg0=0x501bbac0(ext_ram=1) jpeg1=0x50206b00(ext_ram=1)
I (1356) factory_stream: heap after encoder+PPA init: free DMA=355115, SPIRAM=14108216
I (1701) factory_stream: heap after wifi start: free DMA=274815, SPIRAM=14039396
```

这笔账是 SPEC §4 红线的运作实录：编码器 + PPA 初始化只吃掉 **1,112 B** 内部 DMA（356,227→355,115）——RGB 与双 JPEG 缓冲全在 PSRAM（`ext_ram=1`，0x50xxxxxx 地址段）；WiFi 驱动才是内部 RAM 的大头（355,115→274,815，**80,300 B**）。相机 DVP 帧缓冲 2×614,400 B 同样落在 PSRAM（`0x5029db40` / `0x50333b80`）。启动收尾的两行打点（`lab01: Free internal DMA before/after stream init`）在取证轮为 356,227→274,791 B，验收轮（README 实测摘录）为 356,227→274,983 B——两次引导差 192 B，同一量级；这是**启动态（无流客户端）**水位，距 SPEC §4 的推流稳态红线（free_dma ≥ 170KB，上游基线 ≈190KB）还有 100KB 以上余量。

对照面也活着：`MJPEG stream at http://192.168.1.4/stream`（:80）与 `status page at http://192.168.1.4:81/status`——SPEC §5 端口表里 80 给 SOAP+快照+`/stream` 对照面、81 保留给对照面 status 页。上游实测这条管线的推流能力是 13.75 fps / 2.77 Mbps（30 分钟烤机均值 13.51 fps、0 重启 0 断连；编码侧上限 16.667 fps、25,165 B/帧）——lab01 本轮没有流客户端连接，不出流媒体数据，只留水位。

## 12.3 onvif_disc 应答器：模板 + 定向提取的 243 行闭环

发现面的全部增量是 `main/onvif_disc.c` 一个文件，243 行，零 XML 库——第十一章三决策之二（不引 XML 栈）在发现面的同款实践：**模板字符串出站、定向提取入站**。

生命周期分两拍：`onvif_disc_init()` 在 app_main 末尾被调，只做三件事——派生 UUID、注册 `IP_EVENT_STA_GOT_IP` 监听、打出 `DISC READY` 标记行；真正干活的 `disc_task` 等 GOT_IP 才创建，任务参数就是拿到的 IPv4（网络序）。为什么等：XAddrs 必须填板端实际 IPv4（SPEC §5 禁写死），组播成员也要按 STA 接口加入；而 GOT_IP 事件可能带旧地址重放多次，`s_task_started` 保证任务只起一次。所以启动日志里 READY 在 WiFi 关联之前、JOIN 在拿到地址之后——12.4 的判据链会看到这两行隔着一次完整的关联+DHCP。

UUID 是 efuse MAC 派生的确定性值。实测对照：`wifi:mode : sta (1c:29:04:d0:72:e8)` → `DISC READY uuid=urn:uuid:1c29047d-26d0-72e8-8a3e-4ba59cd1e2f3`——MAC 前三字节 1c:29:04 落在第一段，后三字节 d0:72:e8 跨在第二、三段（中间是固定填充 7d-26），第 9 字节 0x8a 把高两位置成 10xx，形似 RFC 4122 变体位。为什么不用每次随机的 UUID：发现层的语义是「同一台设备」，EndpointReference 漂移会把客户端的去重与缓存全部打乱——[[ch02-ws-discovery|第二章]]的「记表-探活」骨架依赖稳定身份。

入组与缓冲（源自 practice/onvif-labs/lab01-discovery/main/onvif_disc.c）：

```c
    struct sockaddr_in local = {
        .sin_family = AF_INET,
        .sin_port = htons(DISC_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(sock, (struct sockaddr *)&local, sizeof(local)) < 0) {
        ESP_LOGE(TAG, "bind :%u failed errno=%d", DISC_PORT, errno);
        close(sock);
        vTaskDelete(NULL);
        return;
    }

    struct ip_mreq mreq = {
        .imr_multiaddr.s_addr = inet_addr(DISC_GROUP),
        .imr_interface.s_addr = (in_addr_t)sta_ip_netorder,
    };
    if (setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) {
        ESP_LOGE(TAG, "join %s failed errno=%d", DISC_GROUP, errno);
        close(sock);
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "$$$ ONVIF LAB01 DISC JOIN grp=%s:%u ip=%s", DISC_GROUP, DISC_PORT, s_ip);

    char *rx = heap_caps_malloc(DISC_RECV_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    char *tx = heap_caps_malloc(DISC_REPLY_BUF, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
```

三个要点（`DISC_GROUP` 为 239.255.255.250、`DISC_PORT` 为 3702、缓冲 2048/1400 字节）：`SO_REUSEADDR` 是 3702 端口多 socket 共存的常规姿势；`IP_ADD_MEMBERSHIP` 的 `imr_interface` 填的是 STA 实际地址而非 `INADDR_ANY`，组播成员落在正确接口上；收发缓冲用 `heap_caps_malloc` 显式要 PSRAM——SPEC §4「ONVIF 新增缓冲一律 PSRAM，内部 RAM 只留栈与 socket 系统缓冲」在 243 行里最直接的落点（任务栈 4096 B 走 `xTaskCreate` 的常规内部分配）。tx 上限 1400 字节给 IP/UDP 头留足余量，实测 1,074 字节的 ProbeMatch 一个 UDP 数据报装下、不分片。

定向提取——「任意前缀」的诀窍（源自 practice/onvif-labs/lab01-discovery/main/onvif_disc.c）：

```c
/* 定向提取：找 "<任意前缀:tag>" 的文本值（跳过开标签，读到下一个 '<'）。
 * 用 "tag>" 定位以同时兼容 <w:MessageID> 与 <MessageID> 两种前缀形态。
 * 找不到返回 false；找到时 out 以 NUL 结尾、按 out_max 截断。 */
static bool disc_extract(const char *xml, const char *tag, char *out, size_t out_max)
{
    char pat[32];
    snprintf(pat, sizeof(pat), "%s>", tag);
    const char *p = strstr(xml, pat);
    if (p == NULL) {
        return false;
    }
    p += strlen(pat);
    const char *end = strchr(p, '<');
    if (end == NULL) {
        return false;
    }
    size_t n = (size_t)(end - p);
    if (n >= out_max) {
        n = out_max - 1;
    }
    memcpy(out, p, n);
    out[n] = '\0';
    return true;
}
```

needle 用 `"tag>"` 而不是 `"<w:tag>"`，于是 `<w:MessageID>` 与 `<MessageID>` 两种前缀形态通吃——**入站宽松**。与之配对的是**出站严格**：应答模板的命名空间与 SOAP 1.2 信封逐字手写、对齐 WSDL——[[ch09-interop-ecosystem|第九章]]坑 5 的教训反过来约束自己：严格客户端挑报文，我们发的报文一行不多。一进一出，两条纪律。Probe 判定同样宽松：Action 头含 `discovery/Probe<`、或正文出现 `:Probe>` / `<Probe>` 开标签即认；Resolve/Hello/Bye 一律沉默——lab01 只承诺 Probe（SPEC §6 明示的边界）。

应答主循环（源自 practice/onvif-labs/lab01-discovery/main/onvif_disc.c）：

```c
        /* 定向提取 MessageID（回 RelatesTo）与 Types（宽松过滤）。 */
        char relates[64] = {0};
        char types[128] = {0};
        disc_extract(rx, "MessageID", relates, sizeof(relates));
        bool types_ok = !disc_extract(rx, "Types", types, sizeof(types)) ||
                        strstr(types, "NetworkVideoTransmitter") != NULL ||
                        strstr(types, "Device") != NULL;
        if (!types_ok) {
            ESP_LOGD(TAG, "Probe Types not ours: %.60s", types);
            continue;
        }

        int n = snprintf(tx, DISC_REPLY_BUF, REPL_TMPL, s_uuid,
                         relates[0] != '\0' ? relates : s_uuid, s_uuid, s_ip, DISC_XADDR_PORT);
        if (n <= 0 || n >= DISC_REPLY_BUF) {
            ESP_LOGE(TAG, "reply render failed (%d)", n);
            continue;
        }

        if (sendto(sock, tx, n, 0, (struct sockaddr *)&src, sizeof(src)) < 0) {
            ESP_LOGE(TAG, "sendto errno=%d", errno);
            continue;
        }
        /* 机器可读标记行（SPEC §1）：验收 grep 锚点。 */
        ESP_LOGI(TAG, "$$$ ONVIF LAB01 PROBEMATCH xaddrs=http://%s:%u/onvif/device_service client=%s:%d",
                 s_ip, DISC_XADDR_PORT, inet_ntoa(src.sin_addr), ntohs(src.sin_port));
```

循环体三步：提取 `MessageID` 去填 `RelatesTo`（提不到就拿自己的 UUID 兜底，ProbeMatch 永远结构完整）；Types 宽松过滤——Probe 没写 Types、或写了含 `NetworkVideoTransmitter` / `Device` 都应答，其它类型沉默；`snprintf` 五参填模板、`sendto` 回到 Probe 的**源地址**。注意应答是单播：目标就是 `recvfrom` 拿到的 `src`——第二章家族对照里「组播喊话-单播应答-记表」的骨架，设备端这半边就这么几行。最后打 `$$$ ONVIF LAB01 PROBEMATCH` 标记行，且打在 `sendto` 成功之后——所以它证明的是「UDP 已交给协议栈发出」，帧是否真的离开射频要靠抓包才能断言（12.5 会用到这个细节）。

Scopes 是刻意的不解析：Probe 里的 Scopes 连看都不看，一律应答——第二章讲的 MatchBy 前缀匹配语义留到 lab02+ 收紧（README 已声明）。宽松的代价是拿 scope 过滤的客户端会多收应答，收益是实现为零、绝不误杀，实验形态选后者。应答侧自报的 Scopes 三个值：`onvif://www.onvif.org/Profile/Streaming`（SPEC §5 必含）+ `onvif://www.onvif.org/hardware/ESP32-S31-Korvo-1` + `onvif://www.onvif.org/name/onvif-lab01`。信封版本也别混：发现面是 SOAP 1.2（`http://www.w3.org/2003/05/soap-envelope`，WS-Discovery 的规定），到 lab02 的 HTTP 控制面才换 SOAP 1.1——两个 lab 两种信封，模板各写各的。

## 12.4 上板与取证：VID:PID、RTS 复位与启动判据

上板第一课是找对串口。宿主机上常驻两块 USB 串口：本板的 CP2102N（**10c4:ea60**）和一块 STM32 板的 CH340（1a86:7523）——口名 `/dev/ttyUSB0` / `/dev/ttyUSB1` 随枚举顺序漂移，两个名字都出现过，所以**按 VID:PID 定位，不按口名**：

```bash
udevadm info -q property -n /dev/ttyUSB0 | grep -E '10c4|ea60'   # 烧前核身份
# 重插后需 sudo chmod 666 /dev/ttyUSB0；CH340（1a86:7523）那块切勿灌错
idf.py -p /dev/ttyUSB0 flash   # esp32s31 是 IDF v6.1 preview target，set-target 必带 --preview（构建壳见 SPEC §2）
```

第二课是取证：run.log 要的是**从头完整**的启动日志，而 esptool 烧完会把串口电平留在非复位态——仅打开端口板子不会复位。`tools/serial_capture.py` 补的就是 esptool 同款的手动复位（源自 practice/onvif-labs/lab01-discovery/tools/serial_capture.py）：

```python
        if not args.no_reset:
            # esptool 式硬复位：RTS→EN 脉冲（0.1s），保证从头收完整启动日志。
            # 仅打开端口不拉线时板子不会复位（esptool 烧完已把电平留在非复位态）。
            s.dtr = False
            s.rts = True
            time.sleep(0.1)
            s.rts = False
```

RTS→EN 脉冲 0.1 秒，保证 40 秒窗口从 ROM 引导日志（`ESP-ROM:esp32s31-20251218`）一路收到 `app_main`。用法一行：`python3 tools/serial_capture.py --port /dev/ttyUSB0 --seconds 40 > run.log`。

启动判据链（README 定义，run.log 原文摘录）：

```text
I (1438) sc101iot: Detected Camera sensor PID=0xda4a
I (1837) onvif_disc: $$$ ONVIF LAB01 DISC READY uuid=urn:uuid:1c29047d-26d0-72e8-8a3e-4ba59cd1e2f3
I (1846) lab01: lab01-discovery base ready (camera+stream+disc)
I (2158) wifi:connected with CMCC-eafe, aid = 10, channel 11, BW20, bssid = b8:12:da:7f:c3:01
I (3384) esp_netif_handlers: sta ip: 192.168.1.4, mask: 255.255.255.0, gw: 192.168.1.1
I (3395) onvif_disc: $$$ ONVIF LAB01 DISC JOIN grp=239.255.255.250:3702 ip=192.168.1.4
```

判据链的读法：`DISC READY` 在 I (1837)，WiFi 还没关联（`connected` 在 I (2158)）——因为 init 只做 UUID 派生与事件注册；`DISC JOIN` 在 I (3395)，拿到 DHCP 地址后任务才起、组播成员才加。两行标记行之间是一次完整的关联+DHCP，约 1.6 秒。顺手的体检也全过：传感器自报 `PID=0xda4a`（SC101IOT，不是官方资料写的 OV3660）、`Found 16MB PSRAM device`（15211K 进堆）、相机 640×480 UYVY 首帧 614,400 B（恰为 640×480×2，两字节一像素）——第十一章 11.1 的底牌清单逐项对上。app_init 自报 `Project name: onvif_lab01_discovery`、`ESP-IDF: v6.1`；分区表沿用基座布局（factory 应用分区 8MB + coffee_pjpg 6MB，16MB flash）。串口控制台与日志口同口，`korvo>` 提示符下 `status` / `ip` / `heap` 随时可查。

## 12.5 探测验收：单播 4/4、组播 0/4 与双端对账

SPEC §6 定的验收工具是仓内 `tools/onvif_probe.py`——纯 stdlib，与第十一章 11.6 设想的 wsdiscovery 包语义等价，但对账价值更高：同屏打出发出的 Probe 原文与收到的 ProbeMatch 原文+hex，并打自己的 `$$$ HOST PROBEMATCH` 标记行。`--repeat N` 间隔 1 秒重发（抗组播丢包假阴性），`--unicast <板IP>` 是组播被环境过滤时的兜底：

```bash
# 组播探测（发往 239.255.255.250:3702）
python3 tools/onvif_probe.py --timeout 8 --repeat 3 | tee runs/probe-mcast.log
# 单播直探（板 IP 以板端日志为准，DHCP 会变、勿写死）
python3 tools/onvif_probe.py --unicast 192.168.1.4 --timeout 5 | tee runs/probe-unicast.log
python3 tools/onvif_probe.py --unicast 192.168.1.4 --timeout 8 --repeat 3 | tee runs/probe-unicast-x3.log
```

四份宿主留档对一份板端取证，账目如下：

| 宿主留档（runs/）    | 发往                 | 发  | 宿主收到 | 板端（run.log 同轮取证）                  |
| -------------------- | -------------------- | --- | -------- | ----------------------------------------- |
| probe-1.log          | 239.255.255.250:3702 | 1   | 0        | PROBEMATCH ×1（client 192.168.1.2:40682） |
| probe-mcast.log      | 239.255.255.250:3702 | 3   | 0        | PROBEMATCH ×3（:47448，间隔整 1 秒）      |
| probe-unicast.log    | 192.168.1.4:3702     | 1   | 1        | 不在此取证窗口，宿主收到即反证            |
| probe-unicast-x3.log | 192.168.1.4:3702     | 3   | 3        | 同上                                      |

**单播账——验收主路径**。宿主直发 4 发，收到 4 条 ProbeMatch（各 1,074 字节），字段逐一对：

- `w:RelatesTo` = `urn:uuid:81cb9972-b94d-4640-85e1-953735976532`——与发出 Probe 的 `w:MessageID` 一字不差；x3 轮三发共用同一 MessageID（`2869dd71-b86f-43ab-aafc-b90625471256`），三条应答的 RelatesTo 也一致。第二章的问答配对语义，字节层面成立。
- `w:EndpointReference` = `urn:uuid:1c29047d-26d0-72e8-8a3e-4ba59cd1e2f3`——与板端 `DISC READY` 行相同（MAC 派生）。
- `d:Types` = `dn:NetworkVideoTransmitter`，`d:MetadataVersion` = `1`——SPEC §5 规定的返回值。
- `d:Scopes` = `onvif://www.onvif.org/Profile/Streaming onvif://www.onvif.org/hardware/ESP32-S31-Korvo-1 onvif://www.onvif.org/name/onvif-lab01`。
- `d:XAddrs` = `http://192.168.1.4:80/onvif/device_service`——DHCP 实际 IP + 端口表 80，无一处写死。

宿主侧原文（runs/probe-unicast.log）：

```text
--- ProbeMatch #1 from 192.168.1.4:3702 (1074 bytes) ---
$$$ HOST PROBEMATCH from=192.168.1.4 ep=urn:uuid:1c29047d-26d0-72e8-8a3e-4ba59cd1e2f3 types=dn:NetworkVideoTransmitter xaddrs=http://192.168.1.4:80/onvif/device_service
total ProbeMatch: 1
```

**组播账——意外发现**。宿主两轮组播共 4 发（probe-1.log 单发、probe-mcast.log 三连发），宿主收到 **0** 条（两份日志的末行都是 `total ProbeMatch: 0`）。而板端取证轮恰好留下 4 条标记行：

```text
I (6842) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:40682
I (11928) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:47448
I (12930) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:47448
I (13932) onvif_disc: $$$ ONVIF LAB01 PROBEMATCH xaddrs=http://192.168.1.4:80/onvif/device_service client=192.168.1.2:47448
```

对账读法：第一条来自宿主源端口 40682，后三条来自 47448、间隔整 1 秒——正是 `--repeat 3` 的发送节奏。两边合起来：**组播 Probe 4 发，板端 4/4 收到、4/4 回包（sendto 成功），宿主 0/4 送达**。单播直探的板端应答不在这份取证窗口里——宿主 4/4 收到本身就是板端已应答的反证。

**不对称怎么读**。方向性结论：下行（宿主→组播组）通，回程（板端单播→宿主）不通，且高度可复现（4/4 对 0/4）。两个对照把嫌疑收窄：同一探针、同量级收集窗口下，单播路径 4/4 全收——探针的收包逻辑没问题；板端关联质量很好（`rssi:-29`、`snr:67`，11ax 关联）——不是无线弱信号。再往下的机理归因（家庭 AP 对组播流量的路径处理），双端日志给不出答案——板端标记行只证明「已交给协议栈」，宿主 0 收只证明「没到达」，中间发生了什么要靠 tcpdump 3702 断面（需 sudo，SPEC 与 README 都列为可选补充证据，本轮未留档）。工程决策因此很朴素：**本环境验收与日常探测用 `--unicast`；真实部署（有线 NVR、IGMP snooping 正确配置）按第二章语义走组播**。

这 4 发 0 收同时解释了 SPEC 为什么把「双端原文」定成一票否决项（§7.2：run.log 无真实上板输出、或输出与声称不符 = 否决）：板端单边看「一切正常」，宿主单边看「设备失踪」，只有两本账摆在一起，不对称才现形——而单播 4/4 又把「应答器本身有 bug」排除掉。孤证不立，双账互证。

## 12.6 边界与下一步

lab01 刻意不做的事（README「已知边界」+ 代码可见的简化）：

- **Scopes 宽松匹配**：Probe 的 Scopes 不校验、一律应答；MatchBy 前缀匹配语义留到 lab02+ 收紧。
- **只应答 Probe**：Resolve/Hello/Bye 不实现，无重发与惩罚机制；应答是立即回包，未做第二章讲的 MX 随机错峰——单设备实验形态无影响，多台同网设备被同一 Probe 打时会齐射。
- **XAddrs 指向的 `/onvif/device_service` 尚不存在**：SOAP 控制面是 lab02 的交付，本站只证明「发现面可被标准客户端探到」。
- **仅 IPv4**；HTTP 对照面 `/stream`（:80）沿袭基座，端口表见 SPEC §5。
- **家庭 AP 组播路径不对称**（本环境实测）：验收与日常探测用 `--unicast` 兜底；机理定位留给 tcpdump（可选）。
- **内存红线观测**：启动态 356,227→274,983 B（无流客户端）；推流稳态 free_dma ≥ 170KB 的红线要等起流后回归观测（上游基线 ≈190KB）。

交付侧的 SPEC §7 清单也过了一遍：README（中文、拓扑、复现命令、真实输出摘录）、run.log 真实上板留存、dependencies.lock 提交（构建离线可重复）、`$$$` 标记行覆盖 READY/JOIN/PROBEMATCH 全部关键事件。

下一步是把发现面递出去的 XAddrs 变成真的：lab02 在 80 端口挂 `/onvif/*`，免鉴权四连（GetSystemDateAndTime / GetDeviceInformation / GetServices / GetCapabilities）加合规 SOAP Fault，以 python-onvif-zeep 逐操作冒烟验收（SPEC §6，标记行 `$$$ ONVIF LAB02 OP <name> ok`）。Scopes 收紧也排在那里。

## 12.7 小结

- lab01 已上板验收通过（2026-10-25）：裁剪版 factory_demo 基座 + 243 行 onvif_disc 应答器，板端 run.log 与宿主 runs/\*.log 双端原文入库，与第十一章的规划逐项对账。
- 应答器走「模板出站 + 定向提取入站」的极简路线：IGMP 按 STA 接口入组、`tag>` 定位吃任意前缀、efuse MAC 派生稳定 UUID、收发缓冲全 PSRAM——不引任何 XML 栈。
- 单播直探 4/4：RelatesTo / EndpointReference / Types / Scopes / XAddrs 逐字段对上，XAddrs 用 DHCP 实际 IP——第二章的问答语义在字节层面成立。
- 组播 Probe 板端 4/4 收到并回包、宿主 0/4 送达——家庭 AP 组播路径不对称，记为工程边界；本环境验收用 `--unicast`，机理定位留给 tcpdump（可选）。
- 内存纪律生效：启动态 free_dma 356,227→274,983 B（无流客户端），距 170KB 红线余量 100KB+；编码三缓冲与 DVP 帧缓冲全在 PSRAM，WiFi 驱动是内部 RAM 唯一大头（80,300 B）。

被探到只是第一句话。ProbeMatch 递出去的 XAddrs（`http://<板IP>:80/onvif/device_service`）现在指向一个还不存在的端点——下一章把它补上：lab02 的 SOAP 控制面最小集，单 httpd 挂 `/onvif/*`、免鉴权四连、合规 SOAP Fault、python-onvif-zeep 逐操作冒烟。从「探得到」到「问得动」：[[ch13-lab02-device-service-report|第十三章]]。
