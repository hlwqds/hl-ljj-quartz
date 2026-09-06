---
title: 树莓派实验室：仪器、对端与 Linux 反向解剖（系列索引）
date: 2026-08-30 02:35:00
description: RPi4B 三重身份实验系列——Linux 反向解剖课主线（点灯三态→字符设备→request_irq→设备树→全栈跟踪）+ 服务 F429/WiFi/BOX-3 的仪器手册
tags: [rpi-lab, RPi, Linux, Lab]
---

# 树莓派实验室：仪器、对端与 Linux 反向解剖（系列索引）

> **状态声明**：本系列与 F429 实验室同模式——「先成文、后实跑」。所有命令与预期状态
> 均可复现设计，但**尚未在真机执行**；「预期输出」均为待实测核销占位。树莓派当前仍为
> 2020 年的 Buster，主线第一章（Bookworm 手术）实跑后系统事实以新系统为准。

姊妹系列：[[f429-lab|F429 裸机实验室]]——本系列的对照面与主要客户。
教学方法：把天天用的 Linux 从 GPIO 往下拆到寄存器，每层「官僚体系」都回答一个问题：
**它在解决裸机的什么问题**（request_irq vs NVIC 直配、DT vs 代码硬编码、用户态点灯 vs 写寄存器）。

## R0–R5：Linux 反向解剖课主线

| #   | 章节                                                                                      | 主题                                                          | 状态 |
| --- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ---- |
| 1   | [[2026-08-30-rpi-lab-ch01-bookworm-surgery-baseline\|手术台：Bookworm 升级与实验室基线]]  | SD 卡 dd 备份→全新刷机→恢复 8082/公钥→NTP 校时→共地与电平红线 | ✍️   |
| 2   | [[2026-08-30-rpi-lab-ch02-devmem-direct-register\|devmem 直捅：找回 F429 的手感]]         | BCM2711 GPIO 基址 0xFE200000；sysfs 旧接口的废与立            | ✍️   |
| 3   | [[2026-08-30-rpi-lab-ch03-libgpiod-userspace-toll\|libgpiod 与用户态的过路费]]            | gpioset/gpiomon + C API；strace 记账；翻转速率对比            | ✍️   |
| 4   | [[2026-08-30-rpi-lab-ch04-kernel-module-mygpio\|内核模块入门：hello 与 my_gpio 字符设备]] | file_operations=裸机函数指针表的内核版；udev 放权             | ✍️   |
| 5   | [[2026-08-30-rpi-lab-ch05-request-irq-vs-nvic\|request_irq：Linux 的中断官僚体系]]        | 顶半/底半/threaded IRQ；对照 NVIC 直配与 FreeRTOS 的 ISR 语义 | ✍️   |
| 6   | [[2026-08-30-rpi-lab-ch06-device-tree-overlay-spi\|设备树：嵌入式的 BIOS]]                | /proc/device-tree 解读；overlay 开 SPI；参数流进驱动的路径    | ✍️   |
| 7   | [[2026-08-30-rpi-lab-ch07-read-syscall-fullstack-trace\|一次 read() 的全栈旅行]]          | strace+ftrace 从 syscall 到 SPI 驱动寄存器写的四层证据        | ✍️   |
| 8   | [[2026-08-30-rpi-lab-ch08-instrument-roles-guide\|仪器手册：低成本逻辑分析仪与网络之眼]]  | piscope/tcpdump/iperf/hostapd/usbmon 六种角色速查             | ✍️   |

## 三重身份定位

| 身份         | 服务对象                          | 章节/实验                            |
| ------------ | --------------------------------- | ------------------------------------ |
| 仪器         | F429 阶段 2 波形课、WiFi RF 系列  | ch08（piscope/hostapd/tcpdump 手册） |
| 陪练对端     | F429 I2C/以太网、BOX-3 USB、pcapx | ch08 + F429 系列 ch08/ch09/ch20–22   |
| 反向解剖对象 | 本系列主线 R1–R5                  | ch02–ch07                            |

## 环境与安全规约

| 项       | 约定                                                                             |
| -------- | -------------------------------------------------------------------------------- |
| 当前系统 | Raspbian 10 Buster（2020 刷机，内核 4.19）；主线开跑前按 ch01 升 Bookworm（6.x） |
| 访问     | 网线直连笔记本（NM shared 10.42.0.1）；SSH **端口 8082** + ed25519 公钥免密      |
| 无 RTC   | 每次上电先对笔记本 NTP 校时（历史坑已记录）                                      |
| 电平红线 | BCM2711 GPIO **非 5V 容忍**；三块板（RPi/F429/ESP32）均为 3.3V 逻辑可直连        |
| 共地规约 | 任何跨板信号线连接前，先共地；规约在 ch01 固化                                   |
| 新增装备 | 杜邦线+LED+电阻小包（~¥10）；万用表（~¥50）建议                                  |
| spec     | `docs/spec/rpi-linux-lab-series.md`（每实验的做通标准）                          |

## 排期咬合

- R0（ch01）随时可做，建议与 F429 阶段 1 并行；
- R1–R5（ch02–ch07）在 **F429 阶段 1 结束后**开——先有裸机「无官僚」的手感，
  再看 Linux 每层封装才有「原来它在防这个」的顿悟；
- ch08 仪器手册按 F429/WiFi RF/BOX-3 各系列节奏取用，不占主线排期。
