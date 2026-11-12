---
title: "Zig × ESP32-S31 全栈开发（一）：目标、边界与硬件鉴定"
date: 2026-11-12 12:00:00
description: "系列开篇：为什么用 Zig 重写一颗 SoC 的软件栈，'全 Zig'到底完整到什么程度，S31 相对 S3 的 RISC-V 红利在哪里，哪些层注定是厂商 blob；随后落到板卡接口、最小实验台与一份可执行的硬件鉴定清单——读芯片、读 Flash ID/MAC、16 MB 全片备份、记录 ROM 启动日志，并把'读成 S3 怎么办'写成决策而不是事故。"
tags: [zig, esp32-s31, riscv, hardware, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. **第一章：目标、边界与硬件鉴定**
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]（下一篇）

# Zig × ESP32-S31 全栈开发（一）：目标、边界与硬件鉴定

## 1.1 为什么是 Zig，为什么值得"重写一遍"

大多数 ESP32 教程的终点是"调通 API"：`gpio_set_level` 亮灯、`esp_wifi_connect` 联网、`esp_http_client` 发请求。这条路能做出产品，但做不出**解释**——你不知道 tick 从哪来、pbuf 何时被释放、Wi-Fi 驱动为什么在中断里回调你。

本系列换一个目标：**把一颗 SoC 上所有可替换的软件层，用一门语言从零写出来**，并且每一步都有可测量的证据。选 Zig 不是趣味，是四个工程理由：

| 理由             | 具体表现                                                                                       | 对教学的意义                                    |
| ---------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| 上游 RISC-V 后端 | `riscv32-freestanding-eabihf`、`generic_rv32`、`+m/+a/+c/+f/+zicsr/+zifencei` 都在标准工具链里 | 不需要维护 Xtensa 分支，交叉编译开箱可用        |
| 显式内存管理     | 没有隐藏分配器、没有隐式拷贝；分配器是参数                                                     | 堆、栈、DMA 缓冲的生命周期必须自己说清楚        |
| 与 C ABI 直通    | `extern fn`、`export fn`、`callconv` 明确                                                      | 可以先链接 IDF 的 blob 与 ROM 函数，再逐层替换  |
| 编译期能力       | `comptime` 生成寄存器表、中断向量、协议常量                                                    | 169 个中断源、48 路 CLIC 这类表驱动代码不必手抄 |

读者画像：写过 C 裸机、用过 FreeRTOS 或 lwIP、愿意读汇编与手册、想真正掌握"一个系统是怎么被构造出来的"的工程师。系列不要求你读过 Zig 标准库源码，但要求你能接受"先测量、再抽象"。

**本系列承诺**：每章一个可验收产物、一组可复制命令、一份能互相印证的证据（串口日志 / `image-info` / map / 抓包 / 波形）。**非目标**：不做 Linux 级虚拟内存与进程模型，不重写芯片掩膜 ROM，不重写 Wi-Fi 射频固件，不追 Zig master，不做蓝牙认证与量产合规——这些要么物理上不可能，要么超出"教学可复现"的成本边界。

## 1.2 系列目标与"全 Zig"的可验收定义

先把口号拆成三条可检查的口径：

1. **纯 Zig 路径**：从应用一直到以太网 MAC，全部 Zig；网络走板载千兆口。这条路径**没有射频 blob**，是"全 Zig 能做到什么程度"的硬证据。
2. **无线路径**：Wi-Fi/BT 的 PHY/MAC 保留厂商二进制；blob 以上的适配层、supplicant、TCP/IP、应用全部 Zig。边界写进文档，不假装不存在。
3. **不碰清单**：掩膜 ROM、Wi-Fi PHY、蓝牙控制器、Linux 级内存模型。

一句话：**"全 Zig"不是"每一行机器码都来自 Zig"，而是"所有可替换的软件层都由 Zig 实现，且边界可解释、可测量、可复现"。**

为了不让"完成"变成主观判断，系列用两级标尺：**交付等级 D0–D6** 定义"做到什么"，**阶段门 G0–G6** 定义"什么条件下才允许进入下一段"。

| 等级 | 覆盖章节 | 交付物                                    | 判定证据（缺一不可）                                            |
| ---- | -------- | ----------------------------------------- | --------------------------------------------------------------- |
| D0   | ch01     | 板卡鉴定记录 + 16 MB 全片备份             | 芯片型号/Flash ID/MAC、备份文件 SHA-256、ROM 启动日志原文       |
| D1   | ch02–04  | 第一个可烧录 Zig 镜像 + 镜像/链接布局认知 | 串口打出 `hello s31`；`image-info` 通过；map 与段布局能逐项解释 |
| D2   | ch05–09  | 裸机运行时：时钟、UART、CLIC、Flash       | 1 kHz tick + 按键中断稳定；掉电重启后配置不丢；波形与寄存器回读 |
| D3   | ch10–15  | Zig RTOS：调度、IPC、内存、SMP            | 3 任务抢占 + 优先级反转实验 + 双核各跑任务 + 1 小时压测无重启   |
| D4   | ch16–19  | 网络底座：EMAC 驱动、ARP/IPv4/ICMP/UDP    | 千兆口 ping/DHCP/DNS 通；抓包能逐字段对上                       |
| D5   | ch20–24  | TCP、socket、TLS/HTTP、MQTT/OTA           | echo 与吞吐曲线；浏览器访问板端页面；TLS 握手成功；MQTT pub/sub |
| D6   | ch25–28  | Wi-Fi 边界与兼容层、连接管理、产品化      | 连上 AP 并 DHCP；OTA 可回滚；性能/功耗有实测数据                |

阶段门只保留"一句话判据"，完整的风险登记在系列索引里维护，本章不重复：

| 门  | 章节  | 通过条件（一句话）                                             |
| --- | ----- | -------------------------------------------------------------- |
| G0  | 1–4   | 干净环境复现 `hello s31`，`image-info` 与 map 互相解释得通     |
| G1  | 5–9   | 自己的 `_start` 跑通，CLIC tick 与 UART 中断稳定，配置掉电不丢 |
| G2  | 10–15 | 3 任务抢占 + 双核并行 + 1 小时压测无重启                       |
| G3  | 16–19 | 千兆口 ping/DHCP/DNS 通，抓包逐字段对得上                      |
| G4  | 20–24 | TCP echo/吞吐达标，HTTP 可访问，TLS 与 MQTT 通                 |
| G5  | 25–26 | Wi-Fi 连 AP、DHCP、MQTT 通，blob 依赖与 ABI 边界有文档         |
| G6  | 27–28 | 综合项目可演示，OTA 可回滚，性能/功耗有数据                    |

> [!note] 为什么先写"不能做什么"
> 嵌入式教学最常见的失败不是"讲得浅"，而是"承诺了物理上做不到的事"：比如"用 Zig 重写 Wi-Fi 驱动"。把边界先钉死，后面 28 章才不会变成许愿池，也才能在面试/评审里理直气壮地说"这一层是 blob，我知道它依赖什么"。

## 1.3 S31 的坐标：RISC-V 是这条路线成立的前提

ESP32 家族里最容易混淆的是两个"高性能"分支。它们外设相似、名字相似，但**指令集不同，工具链命运完全不同**：

| 维度       | ESP32-S3                         | ESP32-S31                              |
| ---------- | -------------------------------- | -------------------------------------- |
| CPU 内核   | Xtensa LX7 双核                  | RISC-V RV32IMAF C 双核                 |
| 上游 Zig   | 不支持，需要 Espressif LLVM 分支 | 直接支持 `riscv32-freestanding-eabihf` |
| 中断控制器 | Xtensa 中断 + 自定义矩阵         | 每核 CLIC（48 输入 / 8 优先级）+ CLINT |
| 迁移成本   | 需要维护交叉工具链补丁           | 只需要写启动代码、链接脚本、OS 与驱动  |

S31 与本系列直接相关的规格：

| 项       | 事实                                                                               | 对路线的影响                                  |
| -------- | ---------------------------------------------------------------------------------- | --------------------------------------------- |
| CPU      | 双核 32 位 RISC-V，最高 320 MHz；RV32IMAF C；单精度 F，无 D                        | 上下文切换要保存 F 寄存器；ABI 对齐 `ilp32f`  |
| 存储     | 512 KB SRAM、320 KB ROM、32 KB LP SRAM；模组 16 MB Flash + 16 MB PSRAM             | 链接脚本、堆预算、PSRAM 初始化与 cache 约束   |
| 中断     | 每核 CLIC 48 路、8 个优先级；169 个中断矩阵源；4 个软件中断                        | tick、IPI、外设中断分发全部自己接             |
| 无线     | Wi-Fi 6 1T1R（802.11b/g/n/ax）、BT 5.4、802.15.4                                   | 射频/MAC 是厂商 blob，构成"全 Zig"的硬边界    |
| 有线     | 千兆 Ethernet MAC + RGMII PHY（板载 RJ45）                                         | 可以 100% 用 Zig 驱动，作为无 blob 的对照路径 |
| 调试     | USB Serial/JTAG、USB-to-UART 双口                                                  | 串口日志与 OpenOCD/GDB 两条通道               |
| 板载外设 | RGB LED（GPIO60）、ES8311 codec、麦克风/扬声器、UART0（GPIO58/59）、BOOT（GPIO61） | 前几章的点灯、串口、音频支线                  |

**为什么上游 Zig 够用**：Zig 的 RISC-V 后端是一线维护的，`riscv32-freestanding`、`riscv32-freestanding-eabihf`、`generic_rv32` 与 `+m/+a/+c/+f/+zicsr/+zifencei` 这些目标能力都在 `std.Target.riscv` 里。S31 不需要 LLVM 分支、不需要 `zig cc` 包一层 Xtensa GCC、不需要给编译器打补丁；需要自己写的是 **CLIC/CLINT、启动代码、链接脚本、RTOS 与协议栈**——这正是本系列要教的内容。

目标不是"能编过"，而是"编出来的 ISA/ABI 与预期一致"。以下命令在 Zig 0.17.1、主机 Windows x86_64 上于 **2026-11-12 实测通过**：

```bash
zig build-lib --show-builtin \
  -target riscv32-freestanding-eabihf \
  -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei
```

实测输出关键字段：`abi = .eabihf`、`arch = .riscv32`、`model = generic_rv32`，特性集包含 `m/a/c/f/i/zicsr/zifencei`（以及由它们推导的 `zaamo/zalrsc/zca/zmmul`）。同一组参数下 `zig build-obj` 也成功产出了 RISC-V 目标文件。

> [!warning] 口径
> 上述结果只证明**编译器按预期目标生成代码**，不证明固件在 S31 上运行过。真机上的启动、时钟、串口输出一律标注「待真机验证」，第一次真机验收发生在第二章。把 `builtin.zig` 存档进工程，作为"编译器到底按什么 ISA/ABI 生成代码"的长期证据。

## 1.4 硬边界：哪些层能重写，哪些层必须承认

这一节是整条路线的"地图边界"。表里每一个 ❌ 都不是态度问题，而是物理与法律问题：掩膜 ROM 出厂固化，射频固件包含校准数据与认证过的基带实现。

| 层                      | 能否用 Zig 重写 | 说明                                                                  |
| ----------------------- | --------------- | --------------------------------------------------------------------- |
| 芯片掩膜 ROM / 一级引导 | ❌ 不能         | 出厂固化；负责下载模式、二级引导加载、基础 ROM 函数                   |
| 二级 bootloader         | ✅ 能           | 先借 IDF 的；ch28 再用 Zig 写自己的，做 A/B、校验与回滚               |
| RTOS 内核 / 驱动 / HAL  | ✅ 能           | 调度、IPC、堆、CLIC、UART、SPI、Flash、EMAC 全部 Zig                  |
| TCP/IP 协议栈           | ✅ 能           | ARP/IPv4/ICMP/UDP/TCP/DHCP/DNS/HTTP/MQTT，全部自写                    |
| Wi-Fi PHY / MAC         | ❌ 不能         | `libnet80211`/`libpp`/`libphy` 等厂商二进制，必须保留                 |
| Wi-Fi 主机侧 supplicant | ✅ 能，但很难   | WPA2/WPA3、EAPOL、SAE 可以用 Zig 写；第一版先接 IDF 的开源 supplicant |
| BT controller           | ❌ 不能         | 控制器固件是 blob；主机栈（GATT 等）可以 Zig 写                       |
| TLS / HTTP / MQTT / OTA | ✅ 能           | 用 `std.crypto` 原语自建记录层，或先接 mbedTLS 做对照                 |

**纯 Zig 的以太网路径**是本系列的"诚实对照基线"：EMAC 是标准寄存器 + DMA 描述符环，PHY 走 MDIO/RGMII，中间没有一行厂商二进制。ch16–ch19 先把这条路打通，它同时承担两个作用——证明"Zig 能驱动真实硬件"，以及在 Wi-Fi 章出问题时提供"协议栈本身是对的"的排除依据。

**Wi-Fi 的边界不在 API，在依赖**：`libnet80211`/`libpp`/`libphy` 这一组二进制不是"一个函数"，它们内部调用 FreeRTOS 的任务、队列、信号量、`esp_timer`、NVS 与事件循环；IDF 用 `esp_adapter.c` 把这一整面 API 桥接给 blob。这意味着"在裸 Zig OS 上直接链接 Wi-Fi blob"不是缺几个符号的问题，而是缺一整个运行时语义。ch25 只做三件事：列清依赖面、做最小可链接实验、在"混合双 OS"与"兼容层"之间做一次有数据的决策——不承诺把它写成纯 Zig。

> [!important] 判断标准
> 遇到"这层能不能自己写"的争论，用三个问题过滤：**寄存器手册公开吗？初始化序列可观测吗？失败可复现吗？** 三个都是"是"，就归入可重写；任何一个为"否"，先划边界，再谈替代方案。

## 1.5 板卡与实验台：先认识你要驱动的物理对象

本系列固定使用 **ESP32-S31-Function-CoreBoard-1**（模组 ESP32-S31-WROOM-3，N16R16V）。选它不只为性能，而是接口齐全到能覆盖后面所有实验：

| 部件 / 接口     | 事实                                                            | 在本系列里的用途                                             |
| --------------- | --------------------------------------------------------------- | ------------------------------------------------------------ |
| SoC / 模组      | ESP32-S31-WROOM-3；16 MB Flash + 16 MB PSRAM                    | 镜像、分区、OTA 槽、网络缓冲                                 |
| 以太网          | 千兆 EMAC + RGMII PHY，板载 RJ45                                | ch16–ch19 的无 blob 数据面                                   |
| USB HS OTG      | 高速 USB 设备/主机口                                            | 后续 USB 设备实验；本章只需认识它和调试口的区别              |
| USB Serial/JTAG | 独立调试口，可烧录、可 OpenOCD/GDB                              | 烧录与断点；不是 UART0                                       |
| UART0           | GPIO58 / GPIO59（TX/RX 方向以板卡原理图为准），板载 USB-UART 桥 | 控制台日志；ch02 的唯一观测手段                              |
| BOOT 按键       | GPIO61，strap 引脚                                              | 手动进下载模式；esptool 通常用 DTR/RTS 自动完成              |
| RGB LED         | GPIO60，**可寻址**（WS2812 类，单线归零码）                     | WS2812 需 RMT/精确时序；ch06 只讲边界，驱动留到后续 RMT 章节 |
| 音频            | ES8311 codec + 麦克风/扬声器                                    | 选修支线；不影响主线验收                                     |
| 供电与电流测量  | USB-C 供电，板载电流测量点                                      | 功耗章与供电完整性排查                                       |

**为什么第二章不点这颗灯**：它不是普通 GPIO——单线归零码靠高低电平的**宽度**编码 0/1，对时序抖动敏感，通常要 RMT 外设或精心校准的忙等。第一个可烧录实验如果同时引入"Zig 构建 + IDF 集成 + 精确时序 + 烧录链路"四个变量，失败时根本无法定位。所以 ch02 的验收口径是**串口输出 `hello s31`**：一个变量、一个观测点、一条可复现的因果链。LED 放到后续 RMT/时序章节，等 GPIO/中断/时序工具都就位再点（ch06 只做 WS2812/RMT 边界论证）。

> [!note] 口径修正
> 系列索引的章节表里，第二章曾写作"UART + RGB LED"。本批起统一为：**ch02 只做 UART 可观测；可寻址 RGB LED 推迟到 RMT/时序章节（ch06 只做边界论证）**。索引页的验收文字已同步为本口径，本章以此为准。

最小实验台（本章只需要前两项，其余为后续章节准备）：

| 设备                        | 用途                                                           | 必需? |
| --------------------------- | -------------------------------------------------------------- | ----- |
| CoreBoard-1 + 两根 USB-C 线 | 供电、UART 控制台、USB Serial/JTAG 调试                        | 必需  |
| 千兆交换机/路由器 + 网线    | 以太网协议栈验证；能开 DHCP 与抓包                             | 必需  |
| 支持 WPA2/WPA3 的 AP        | ch26 的连接、重连与漫游实验                                    | 必需  |
| 逻辑分析仪（≥8 通道）       | 中断延迟、GPIO 翻转、SPI/UART 时序；没有就用 GPIO + 示波器替代 | 推荐  |
| 万用表 + 板载电流测量点     | 功耗章、供电完整性排查                                         | 推荐  |
| Linux 主机或 Wireshark      | 抓包、对比 TCP 状态机、镜像与串口脚本                          | 推荐  |

## 1.6 硬件鉴定实验：把"这是哪颗芯片"变成记录

本章唯一的动手环节。目标不是"能烧程序"，而是产出一份**可复查的板卡身份档案**：芯片型号、Flash ID、MAC、16 MB 原始镜像、ROM 启动日志。有了它，后面任何"烧坏了/不启动"的事故都有回滚基线。

完整可执行清单在 `practice/zig-esp32-s31/ch01-board-id/README.md`，这里给出命令与判据。**以下所有涉及真机的步骤均标注「待真机验证」**，本章不提供任何伪造的输出。

### 1.6.1 装 esptool 并确认版本

```bash
python -m pip install -U "esptool>=5.2"
esptool version
```

判据：版本号 ≥ 5.2（S31 支持从 5.2 起）。esptool v5 的子命令使用连字符写法（如 `read-flash`、`write-flash`），本书统一用连字符形式；**具体子命令与参数以 esptool 5.2+ `--help` 为准**。

### 1.6.2 识别芯片

```bash
esptool -p <PORT> --chip esp32s31 chip-id
```

「待真机验证」。判据：输出中出现 `ESP32-S31` 与芯片修订号；连接握手本身就会打印检测到的芯片类型。若命令名在你的版本里不同，直接 `esptool --help` 查当前注册的子命令。

### 1.6.3 读 Flash ID 与 MAC

```bash
esptool -p <PORT> --chip esp32s31 flash-id
esptool -p <PORT> --chip esp32s31 read-mac
```

「待真机验证」。`flash-id` 给出厂商 ID、设备 ID 与检测到的容量（应为 16 MB）；`read-mac` 给出出厂 MAC。把两者与模组丝印（N16R16V）交叉核对——丝印说 16 MB、工具说 4 MB，就是拿错板子或板子被换过。

### 1.6.4 16 MB 全片备份

```bash
esptool -p <PORT> --chip esp32s31 -b 460800 read-flash 0 0x1000000 s31-factory-16mb.bin
```

「待真机验证」。`0x1000000` 就是 16 MB。备份完成后立刻算摘要并存档：

```bash
sha256sum s31-factory-16mb.bin
```

这份镜像的意义：刷砖后可以整片写回（`write-flash 0x0 s31-factory-16mb.bin`），也可以离线分析出厂分区表与 bootloader。**在做任何擦除/烧录之前完成它**，这是本系列唯一一条"不可跳过"的操作纪律。

### 1.6.5 记录 ROM 启动日志

用串口工具连 UART0（GPIO58/59，板载 USB-UART 桥），先按 **115200 8N1** 打开（ROM 默认值；若输出乱码，再依次尝试常见波特率），按一下复位（EN），抓取 ROM 打印的启动日志。「待真机验证」。关注三类信息：

- strap 采样（形如 `boot:0xNN`）与启动模式；
- Flash 模式/大小/频率的 ROM 侧判断；
- 是否直接进入下载模式（若一直停在 `waiting for download`，说明 BOOT 被按住或 strap 电平不对）。

### 1.6.6 鉴定记录模板

把结果写进实验目录的 `board-id.md`（模板如下），后续章节遇到异常先回查这份档案：

| 字段               | 记录值                                                        |
| ------------------ | ------------------------------------------------------------- |
| 板卡 / 模组丝印    | ESP32-S31-Function-CoreBoard-1 / ESP32-S31-WROOM-3（N16R16V） |
| 芯片型号与修订     | 待填（`chip-id` 输出）                                        |
| Flash 厂商/设备    | 待填（`flash-id` 输出）                                       |
| Flash 容量         | 待填（应为 16 MB）                                            |
| 出厂 MAC           | 待填（`read-mac` 输出）                                       |
| ROM 日志首行       | 待填（原文，不改写）                                          |
| 备份文件           | `s31-factory-16mb.bin`                                        |
| 备份 SHA-256       | 待填                                                          |
| 主机 / 端口 / 日期 | 待填（例如 Windows COM7，2026-11-12）                         |

### 1.6.7 如果读出来不是 S31

这是**必须写成决策而不是事故**的分支：

| 现象                              | 含义                               | 动作                                                                  |
| --------------------------------- | ---------------------------------- | --------------------------------------------------------------------- |
| 报 `--chip` 与实际不符 / 检测超时 | 端口错、线材只供电、或没进下载模式 | 换口（USB Serial/JTAG 与 UART 是两个口）、换线、用 BOOT+EN 手动进下载 |
| 读到 `ESP32-S3`                   | 板子不是 S31，模块被换或拿错板     | **停止**。S3 是 Xtensa，工具链、启动链、ABI 全不同，本系列命令不适用  |
| 读到经典 `ESP32`                  | 同上，且是更老的架构               | 停止并记录，联系供板方；不要试图"先凑合烧进去"                        |
| 读到 S31 但 Flash 容量不是 16 MB  | 模组型号不符（可能是 N8R8 等）     | 记录实际容量，后续分区表与备份长度按实际值调整，并在档案里标注偏差    |

> [!warning] 纪律
> 硬件鉴定阶段不做任何写操作。只读命令（`chip-id`、`flash-id`、`read-mac`、`read-flash`）之外一律不执行；备份没落盘并核对 SHA-256 之前，不进入第二章的烧录环节。

## 1.7 验收矩阵与决策门

本章的验收不看"灯亮没亮"，只看证据是否闭合：

| 验收项       | 通过判据                                             | 证据形式                    |
| ------------ | ---------------------------------------------------- | --------------------------- |
| 工具链坐标   | `--show-builtin` 输出 `abi=.eabihf`、`arch=.riscv32` | 存档的 `builtin.zig` 文本   |
| 芯片身份     | 工具读到 ESP32-S31，修订号与丝印不矛盾               | `chip-id` 原始输出          |
| Flash 与 MAC | Flash ID + 容量 16 MB；MAC 可读且唯一                | `flash-id`、`read-mac` 输出 |
| 可回滚       | 16 MB 镜像落盘，SHA-256 与文件大小记录在案           | 备份文件 + 摘要 + 档案表    |
| 启动可解释   | ROM 日志能指出 strap 值与启动模式                    | 日志原文（不改写、不截断）  |
| 边界认知     | 能说出至少三层"不能重写"及其理由                     | 本章 1.4 表的复述           |

决策门（本章只列与"地基"相关的四条，完整风险登记见索引）：

| 触发信号                            | 决策                                                            |
| ----------------------------------- | --------------------------------------------------------------- |
| Zig 目标编译失败或 ABI 不符         | 退回形态 A（IDF 托管 Zig 静态库）先完成教学，工具链问题单独立项 |
| 板子读成 S3/经典 ESP32              | 停止本系列硬件步骤，换板；不改工具链硬凑                        |
| 16 MB 备份无法完成（读失败/校验错） | 不烧录；先解决供电、线材、端口与驱动，再谈后续                  |
| Flash 实际容量与模组丝印不符        | 以实测为准重写分区与备份长度，档案里标注偏差，不假装是 16 MB    |

## 1.8 第一个里程碑：干净机器可复现

"在我机器上能跑"不算交付。第一章结束时，本系列的第一个里程碑定义为：

1. **工具版本锁定**：Zig 0.17.1、ESP-IDF v6.1、esptool ≥ 5.2，三者版本写进 README，不依赖"最新版"。
2. **只读鉴定可复现**：换一台干净主机（只装 Python + esptool），按 `ch01-board-id/README.md` 能重新读出同一颗芯片、同一个 MAC、同一个 Flash ID。
3. **备份可验证**：备份文件的 SHA-256 与档案记录一致；文件大小恰为 16 MB。
4. **证据可互证**：`flash-id` 的容量、模组丝印、备份文件长度三者一致；ROM 日志的 strap 值与实际按键操作对得上。
5. **无隐式依赖**：不依赖某台机器上残留的 venv、PATH 或串口别名；所有路径与端口都是命令里的显式参数。

达到这五点，D0 才算完成；第二章的烧录与 `hello s31` 才有意义。反过来，如果备份缺失就烧录，后面任何一次"板子不启动"都会变成无法回滚的事故。

## 1.9 与现有系列的关系

| 系列                                        | 在本系列里的角色                                                                                                                                         |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [[freertos-deep-dive\|FreeRTOS 深度解析]]   | OS 章的直接对照：调度器、IPC、端口层、SMP；本系列用 Zig 重写一遍                                                                                         |
| [[lwip-deep-dive\|lwIP 深度解析]]           | 协议栈章的直接对照：pbuf、TCP 状态机、邮箱模型；本系列自写一遍                                                                                           |
| [[embedded-basics\|嵌入式硬件基础]]         | 裸机/RISC-V/CLIC 的入门地基；S31 是这套方法在真实 SoC 上的应用                                                                                           |
| [[esp32-s3-box-3\|ESP32-S3-BOX-3 工程实战]] | IDF 真机经验与排坑；注意 S3 是 Xtensa，工具链与本系列不同                                                                                                |
| [[wifi-rf-hw\|WiFi 射频硬件入门]]           | 解释为什么 Wi-Fi PHY/MAC 是 blob、哪些指标只能靠仪器测                                                                                                   |
| [[wifi-hw-debug\|WiFi 硬件调试实战]]        | Wi-Fi 连接/吞吐/功耗问题的取证方法，直接复用到 ch26                                                                                                      |
| [[onvif-deep-dive\|ONVIF 协议深度解析]]     | 本仓已有的 S31 真机基线：Korvo-1 + IDF v6.1 preview target，lab01–lab06 已上板；工具链/烧录/PSRAM 经验可直接复用（[[ch11-esp32s31-lab-plan\|第十一章]]） |

读法建议：OS 章（ch10–ch15）遇到"为什么这么设计"，去 FreeRTOS 系列看 C 实现与端口层；协议栈章（ch16–ch24）遇到 pbuf/TCP 状态机争议，去 lwIP 系列看成熟实现；硬件章（ch05–ch09）遇到 CLIC/裸机概念，回嵌入式硬件基础补课。对照不是抄，而是"同一个问题，两种语言，各自付了什么代价"。

## 1.10 本章事实出处

| 事实                                    | 来源                                                                                                                                                                                                                                   | 备注                                                      |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| S31 双核 RISC-V、320 MHz、512 KB SRAM   | [Espressif ESP32-S31 产品页](https://www.espressif.com/en/products/socs/esp32-s31)                                                                                                                                                     | 2026-08 更新                                              |
| S31 模组 16 MB Flash + 16 MB PSRAM      | [ESP32-S31-WROOM-3 Datasheet](https://documentation.espressif.com/esp32-s31-wroom-3_wroom-3u_datasheet_en.pdf)                                                                                                                         | Pre-release v0.7；CoreBoard-1 为 N16R16V                  |
| 板卡接口、千兆以太网、USB、ES8311       | [ESP32-S31-Function-CoreBoard-1 User Guide](https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s31/esp32-s31-function-coreboard-1/user_guide.html)                                                                        | RJ45 千兆、USB HS OTG、USB Serial/JTAG                    |
| IDF v6.1 支持 `esp32s31`                | [ESP-IDF v6.1 Get Started (ESP32-S31)](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s31/get-started/index.html)                                                                                                          | `esp32s31` 为 preview target；esptool/OpenOCD 随 IDF 安装 |
| esptool ≥ 5.2 支持 S31                  | [esptool v5.2.0 Release](https://github.com/espressif/esptool/releases/tag/v5.2.0)                                                                                                                                                     | `--chip esp32s31`；`elf2image`/`image-info`               |
| 镜像格式：8 字节头 + 扩展头 + 段 + 校验 | [esptool Firmware Image Format (ESP32-S31)](https://docs.espressif.com/projects/esptool/en/latest/esp32s31/advanced-topics/firmware-image-format.html)                                                                                 | 纯 Zig 产镜像的关键依据                                   |
| CLIC 48 路/8 级、169 源、4 个软件中断   | [esp-hal esp32s31 SoC metadata](https://github.com/esp-rs/esp-hal/blob/667f8f02/esp-metadata/devices/esp32s31/soc.toml)                                                                                                                | 与 TRM 交叉核对                                           |
| Wi-Fi blob 依赖 FreeRTOS/IDF API        | [IDF v6.1 esp_wifi CMakeLists](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_wifi/CMakeLists.txt)、[esp32s31/esp_adapter.c](https://github.com/espressif/esp-idf/blob/v6.1/components/esp_wifi/esp32s31/esp_adapter.c) | 1.4 节边界表的直接证据                                    |
| Zig 0.17.1 stable；目标/特性实测        | [Zig Download](https://ziglang.org/download/)                                                                                                                                                                                          | 2026-11-02 发布；2026-11-12 本机实测                      |

> [!note] 写作口径
> S31 目前仍是 pre-release 文档阶段，寄存器名、内存区间、CLIC 细节可能随 TRM/IDF 更新；每章开头会标注依据的 IDF/TRM/Zig 版本，**实测优先于文档**。Zig 的 target 特性串以 `--show-builtin` 输出为准，不在文章里硬编码未验证的能力名。

---

**本章自查清单**（全部打勾再进第二章）：

- [ ] 能用一句话说清"全 Zig"的三条口径，并说出哪一层注定是 blob
- [ ] 能解释为什么选 S31 而不是 S3：内核、中断控制器、上游 Zig 支持三处差异
- [ ] 能复述 `riscv32-freestanding-eabihf` 冒烟命令，并说出 `abi`/`arch`/`model` 的期望值
- [ ] 知道 UART0（GPIO58/59）、BOOT（GPIO61）、可寻址 RGB LED（GPIO60）各自是什么，为什么不先点灯
- [ ] 能区分 USB Serial/JTAG 与 UART 两个口，并说明各自用途
- [ ] 已完成芯片识别、Flash ID、MAC 读取（或明确记录"待真机验证"）
- [ ] 16 MB 全片备份已落盘，SHA-256 与文件大小记录在案
- [ ] 能回答"读成 S3 怎么办"，并说出为什么不能硬凑工具链

下一章把工具链真正装上：Zig 0.17.1 的安装与 `build.zig`、target/CPU 特性如何落到编译命令、IDF 托管形态 A 的 CMake 集成，以及第一个可烧录镜像——串口打出 `hello s31`、`image-info` 校验通过、`builtin.zig` 存档。第二章：工具链与第一个可烧录镜像。

系列导航：[[zig-esp32-s31|系列索引]] · 下一章：[[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
