---
title: "F429 × Korvo-1（十一）：第二宿主——树莓派加入战局"
date: 2026-10-10 12:00:00
description: "续篇开章：多宿主不是重写而是兑现——ch03「传输无关」分层承诺的验收。宿主画像对比（F429 裸机 vs RPi4B Linux：中断/轮转 vs fd/poll，寄存器 vs 字符设备）；三条路径盘点（官方 ESP-Hosted / 手搓协议上 spidev 用户态 / 内核驱动延伸）；树莓派侧硬件合同（SPI0 引脚、dtparam 使能、DRDY 的 gpiod 事件）；与 F429 六根线的对照表。"
tags: [wifi, rpi, linux, spi, coprocessor, series]
---

> [!info] WiFi 协处理器实战（续篇） 0. [[wifi-coproc|系列索引]] 1. [[ch01-coproc-architecture|第一章]] … 10. [[ch10-beyond|第十章]] 11. **第十一章：第二宿主——树莓派**

# F429 × Korvo-1（十一）：第二宿主——树莓派加入战局

主线十章在 F429 上完结；这一章开启续篇——把**同一块 Korvo-1** 接到第二个宿主（[[rpi-lab|树莓派实验室]]的 RPi4B）上。多宿主的意义不是"再写一遍"，而是两件事：**兑现承诺**（ch03 把帧协议做成字节流无关，白纸黑字说"换传输层协议零改"——现在验收）与**交叉验证**（S3 从机固件对任何宿主一视同仁，两个宿主跑同一应用，协议行为互为对照）。

---

## 11.1 宿主画像：两台机器，两种世界观

协议分层在两侧宿主上的落点一图看清——**变的是事件源与传输层，不变的是中间三层**：

```text
            F429（裸机）                          RPi4B（Linux）
应用         NTP/HTTP（ch07）                      同一套逻辑（可直接搬）
调度         轮转任务 / 中断                        进程 + poll/epoll + 线程
API 门面      ws_* （ch06）                        ws_*（源码原样编译）
协议层        control/framing ←———— 零改动搬上 Linux ————→ 同一份 .c
传输层        SPI 寄存器 + DMA + EXTI               /dev/spidev 字符设备 + ioctl
事件源        DRDY → EXTI 中断                      DRDY → gpiod 事件 → poll()
```

世界观差异逐条对表（每一条都会在 ch12 的代码里现形）：

| 维度       | F429 裸机                 | RPi4B Linux                                  |
| ---------- | ------------------------- | -------------------------------------------- |
| 一次"交换" | 写寄存器 + DMA，µs 级可达 | `ioctl(SPI_IOC_MESSAGE)`，syscall + 拷贝开销 |
| DRDY 到达  | EXTI 向量直入             | 字符设备 fd 可 poll                          |
| 等待语义   | WFI/轮询标志位            | `poll()` 一处收齐全部事件源                  |
| 时钟霸权   | 自己出时钟，想换就换      | spidev 参数（mode/speed）ioctl 设置          |
| 出问题看哪 | 示波器 + LED              | strace/dmesg/逻辑分析仪                      |

## 11.2 三条路径：续篇怎么走

- **路径 A（官方）**：ESP-Hosted 从机固件 + 树莓派宿主模块，得到虚拟网卡——ch13 全程走一遍，与官方方案贴身对照；
- **路径 B（本续篇主线）**：**手搓协议栈直接上 Linux**——ch03/05/06 的源文件原样编译，传输层换成 spidev 用户态驱动，守护进程形态收尾。教学延续性最好：F429 上调好的每一层在这里都要"自己证明可移植"；
- **路径 C（延伸，不展开）**：把传输层做成内核模块（[[rpi-lab|树莓派实验室]]ch04 的 mygpio 思路 + ch05 的 request_irq）——性能上限更高，但调试代价陡增，列为进阶练习。

## 11.3 树莓派侧硬件合同

延续 ch01 的"先审计后签约"，RPi4B 侧六根线：

| 信号 | RPi4B 引脚（40-pin）         | 对接 Korvo-1（同 ch01 审计脚） |
| ---- | ---------------------------- | ------------------------------ |
| SCLK | GPIO11（pin 23，SPI0）       | SPI CLK                        |
| MOSI | GPIO10（pin 19，SPI0）       | SPI MOSI                       |
| MISO | GPIO9（pin 21，SPI0）        | SPI MISO                       |
| CS   | GPIO8（pin 24，SPI0 CE0）    | SPI CS                         |
| DRDY | GPIO17（pin 11，任选空闲脚） | DRDY                           |
| GND  | 任一 GND 脚                  | GND                            |

使能 SPI（[[rpi-lab|树莓派实验室]]ch06 的设备树 overlay 主场）：`/boot/firmware/config.txt` 加 `dtparam=spi=on`，重启后 `/dev/spidev0.0` 现身——**Linux 把 SPI 主机控制器包装成字符设备**，这是 ch12 全部代码的入口。DRDY 的用户态事件用 libgpiod（[[rpi-lab|树莓派实验室]]ch03 的用户态点灯课直接复用）。RPi4B 板载 WiFi 走专用通路、不占 SPI0 引脚（ch09 提过的型号差异在此落定）。

## 11.4 小结

- 多宿主 = 兑现"传输无关"承诺 + 两个宿主交叉验证同一从机；协议中间三层零改动，换的只是传输层与事件源。
- 两种世界观对照表是 ch12 代码的预告片：ioctl 交换、poll 事件、spidev 参数化时钟。
- 三条路径：官方 ESP-Hosted（ch13）、手搓上 Linux（ch12 主线）、内核模块（进阶练习）。
- 硬件合同五线 + 共地；`dtparam=spi=on` 拿到 `/dev/spidev0.0`，DRDY 用 libgpiod——全部踩在 rpi-lab 已铺好的地基上。

下一章动手：spidev 传输层的三个 ioctl（模式/速度/交换）、DRDY 事件进 poll 循环、守护进程骨架把 ch06 的 ws\_\* 世界在 Linux 上原样立起来——F429 版的每个设计决定在这里逐一对答案。[[ch12-rpi-spidev-host|第十二章：手搓协议上 Linux]]。
