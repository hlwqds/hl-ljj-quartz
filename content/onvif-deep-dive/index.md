---
title: "ONVIF 协议深度解析系列索引"
date: 2026-10-10
pin: true
description: "ONVIF 由浅入深系列：10 章拆解网络视频设备的通用语言——WS-Discovery 组播发现、SOAP/WSDL 服务全景、WS-Security 摘要认证的手工推导、媒体 Profile 配置模型、GetStreamUri → RTSP/RTP 取流全链、PTZ 与事件、Profile G 录像回放、互通实测与生态、以及从 ONVIF 学协议设计。协议分析向，实战工程按「先成文后实跑」可续。"
tags: [onvif, series, ip-camera, rtsp, soap, streaming]
---

# ONVIF 协议深度解析系列

> [!tip] 系列说明
> 本系列回答一个问题：**一台网络摄像机和一台 NVR/平台，凭什么来自不同厂商却能即插即用**——答案是 ONVIF 这套"通用语言"：**WS-Discovery 发现（UDP 组播）+ SOAP/WSDL 控制面（HTTP/XML）+ RTSP/RTP 媒体面**。由浅入深十站：从发现一个设备开始，到手工推导一遍摘要认证、解剖 Media Profile、走完取流全链、玩转 PTZ/事件/录像，最后以互通实测与协议设计启示收束。
>
> 定位：协议分析向（与 [[vpn-deep-dive|VPN 与隧道技术系列]]、[[quic-deep-dive|QUIC 深度探索系列]]同族的"拆轮子"路线）。实战已立项：设备端方案见 [[ch11-esp32s31-lab-plan|第十一章]]，工程契约在 `practice/onvif-labs/SPEC.md`，六个里程碑 lab 按「先成文后实跑」逐个落地。

## Part I：接入——发现一台设备并跟它说上话

| #   | 章节                            | 主题                                        | 状态      |
| --- | ------------------------------- | ------------------------------------------- | --------- |
| 1   | [[ch01-onvif-overview\|第一章]] | ONVIF 是什么：三件套技术栈与 Profile 体系   | ✅ 已发布 |
| 2   | [[ch02-ws-discovery\|第二章]]   | WS-Discovery：UDP 组播里的设备自荐          | ✅ 已发布 |
| 3   | [[ch03-soap-services\|第三章]]  | SOAP 服务全景：WSDL、命名空间与设备信息四连 | ✅ 已发布 |

## Part II：认证与媒体——从口令到像素

| #   | 章节                              | 主题                                         | 状态      |
| --- | --------------------------------- | -------------------------------------------- | --------- |
| 4   | [[ch04-ws-security-auth\|第四章]] | WS-Security：Nonce+Created 摘要的手工推导    | ✅ 已发布 |
| 5   | [[ch05-media-profiles\|第五章]]   | Media Profile：配置三件套与 Media2 的简化    | ✅ 已发布 |
| 6   | [[ch06-rtsp-streaming\|第六章]]   | 取流全链：GetStreamUri → RTSP/RTP → 抓包对账 | ✅ 已发布 |

## Part III：能力与生态

| #   | 章节                                 | 主题                                   | 状态      |
| --- | ------------------------------------ | -------------------------------------- | --------- |
| 7   | [[ch07-ptz-events\|第七章]]          | PTZ 与事件：云台控制和三种通知模型     | ✅ 已发布 |
| 8   | [[ch08-recording-profile-g\|第八章]] | 录像与回放：Profile G 与 NVR 侧视角    | ✅ 已发布 |
| 9   | [[ch09-interop-ecosystem\|第九章]]   | 互通实战：测试工具、兼容性坑与开源生态 | ✅ 已发布 |
| 10  | [[ch10-design-lessons\|第十章]]      | 设计启示：从 ONVIF 学协议设计          | ✅ 已发布 |

## Part IV：实战——把设备端装进一块开发板

| #   | 章节                                            | 主题                                              | 状态                    |
| --- | ----------------------------------------------- | ------------------------------------------------- | ----------------------- |
| 11  | [[ch11-esp32s31-lab-plan\|第十一章]]            | 实战方案：ESP32-S31-Korvo-1 当一台 ONVIF 摄像机   | 📋 方案已立             |
| 12  | [[ch12-lab01-discovery-report\|第十二章]]       | 实战实录一：lab01，从烧录到被探到                 | ✅ 成文                 |
| 13  | [[ch13-lab02-device-service-report\|第十三章]]  | 实战实录二：lab02，SOAP 控制面最小集              | ✅ 实跑（双壳冒烟全绿） |
| 14  | [[ch14-lab03-auth-digest-report\|第十四章]]     | 实战实录三：lab03，WS-Security 摘要认证与时钟纪律 | ✅ 实跑（九行矩阵全绿） |
| 15  | [[ch15-lab04-media-snapshot-report\|第十五章]]  | 实战实录四：lab04，Media Profile 与快照           | 🚧 骨架（待实测回填）   |
| 16  | [[ch16-lab05-rtsp-mjpeg-report\|第十六章]]      | 实战实录五：lab05，RTSP/RTP 取流全链              | 🚧 骨架（待实测回填）   |
| 17  | [[ch17-lab06-interop-harness-report\|第十七章]] | 实战实录六：lab06，互通收口                       | 🚧 骨架（待实测回填）   |

---

## 相关系列

- [[p2p-deep-dive|P2P 网络深度解析系列]] —— ch02 的 UDP 广播发现与 WS-Discovery 同宗同源
- [[vpn-deep-dive|VPN 与隧道技术系列]] —— TLS/传输安全的地基（ONVIF 侧信道）
- [[diy-vpn|手写 VPN 系列]] —— ch04 摘要认证与手写哈希的纪律同款
- [[suricata-deep-dive|Suricata 深度探索系列]] / [[zeek-deep-dive|Zeek 深度探索系列]] —— 流量观测的另一片战场
