---
title: "嵌入式硬件基础（十一）：调试体系——SWD、JTAG 与 openocd"
date: 2026-08-30 09:00:00
description: "从 printf 的观察者效应出发建立嵌入式调试层级（打印→在线调试→trace）；解剖 SWD 两线协议与 DP/AP 访问模型、JTAG TAP 与 SWJ-DP 复用；openocd 三层架构与 interface/board/target 配置链全部用本机 0.12.0 真实输出考证（含无硬件时'配置解析通过→适配器打开失败'的分层意义）；无板期用 QEMU gdbstub 跑通完整上帝视角循环：硬件/软件断点对照、watchpoint 捕获 .data 拷贝、寄存器组检查，附 gdb 速查表；ST-Link 接 F407 接线表与烧录工具地图（真机待验证）。"
tags: [embedded-basics, STM32, RISC-V]
---

> [!info] 嵌入式硬件基础系列 0. [[embedded-basics|系列索引]] · 10. [[ch10-i2c-spi-theory|上一章：I2C/SPI 协议理论]] · 11. **第十一章：调试体系** · 12. [[ch12-freertos-port-contrast|下一章：FreeRTOS 三架构 port 对照]]

# 嵌入式硬件基础（十一）：调试体系——SWD、JTAG 与 openocd

软件人调试有完整的工具金字塔：printf、gdb、strace、tcpdump、perf。嵌入式前十章我们只用过最原始的两样——UART 打印（第四章的 `hello baremetal`）和 QEMU gdbstub（[[ch03-arm-cortex-m-anatomy|第三章]]的三个实验、[[ch04-baremetal-boot|第四章]]的复位实证）。板子快到了，真机上的"上帝视角"靠什么？答案是三件事：**芯片里的调试硬件（SWD/JTAG 口）、电脑边的翻译官（openocd）、你手上已有的武器（gdb）**。

本章把这三件事拼成完整体系。openocd 0.12.0 已在本机安装（`openocd-0.12.0-3.fc42.5`，Fedora 包），所有 openocd 命令均真实执行——包括"无硬件时的预期失败形态"本身也是知识：它会精确告诉你失败发生在哪一层。gdb 演示复用第四章模板工程，全部真实会话。

---

## 11.1 调试层级总览：从 printf 到上帝视角

先建立一个层级地图，嵌入式的调试手段按"对目标系统的侵入度"排：

| 层级 | 手段                       | 侵入度        | 能干什么                                 | 不能干什么                                       |
| ---- | -------------------------- | ------------- | ---------------------------------------- | ------------------------------------------------ |
| L0   | printf/UART                | 高            | 看执行路径、变量值                       | 改变时序；一次只能看预埋的点；程序跑飞时无声无息 |
| L1   | 在线调试（SWD/JTAG + gdb） | 低（可 halt） | 断点/单步/任意内存读写/寄存器/flash 烧录 | halt 期间外设时钟仍在走（可配置冻结）            |
| L2   | trace（SWO/ETM）           | 近零          | 实时观测运行中的指令流/数据              | 需要更多引脚与更高带宽设备                       |

**为什么嵌入式最终必须会 L1？观察者效应。** 算一笔账：115200 波特率下一个字节约 87 µs，一行 50 字符的 printf 若走轮询发送就是约 4.3 ms 的纯阻塞——对 168 MHz 的 F407 是 72 万个时钟周期。时序敏感的代码（一段 10 µs 精度的 delay、一个和波特率打擦边球的 UART 收发）加上 printf，行为立刻改变：**bug 消失或不出现，这才是最恶心的 Heisenbug**。printf 还要求程序"活着"才能打印——跑飞、HardFault 死循环、启动早期（时钟没配好）阶段，printf 全部哑火，而调试口在这些阶段都工作。

诚实起见补一句：L1 也有自己的观察者效应——halt 时 CPU 停了，但外设没停（SysTick 还在数、UART FIFO 还会溢出），除非配置 DBGMCU 冻结位（11.3 会看到 openocd 的 cfg 里就自动写了这几位）。**没有零扰动观测，只有可控扰动观测**——这与网络世界的"抓包本身会影响时序"是同一课。

L2 一句话预告：SWO 是单线异步 UART 式 trace（ITM 打印 + DWT 计数器，速率 Mbit/s 级），ETM 是全指令流 trace（需 trace 端口 + 硬件，TPIU 引出）。本系列真机阶段优先 SWO，届时专文展开。

---

## 11.2 SWD vs JTAG：两条进核的路

调试器到 CPU 核之间必须有一条"物理通道"。历史上是 JTAG，ARM 为主流 MCU 定义了更省引脚的 SWD。F407 两者都支持（SWJ-DP，可动态切换）。

### 1. JTAG：边界扫描的第二次就业

JTAG 生于 1980 年代，本业是 IEEE 1149.1 **边界扫描**——测 PCB 焊点通断（把每个引脚的信号"边界寄存器"串起来移位读出）。后来人们发现这条四线通道通用性极强，可以顺路挂上 CPU 调试模块，于是它成了几十年的行业标配。

| 信号  | 方向        | 作用                                  |
| ----- | ----------- | ------------------------------------- |
| TCK   | 调试器→目标 | 时钟，一切同步于它                    |
| TMS   | 调试器→目标 | 状态机控制线（与 TCK 配合选状态）     |
| TDI   | 调试器→目标 | 数据入                                |
| TDO   | 目标→调试器 | 数据出                                |
| nTRST | 调试器→目标 | 测试逻辑复位（可选线，F407 上是 PB4） |

工作机制是 16 态的 **TAP 状态机**：TCK 每拍一次，TMS 的电平决定状态迁移；走到 Shift-IR 态就把指令寄存器（Cortex-M 是 4 位）串行移入，再走到 Shift-DR 态移数据。第一条常用指令是 IDCODE——上电后 TAP 默认进入的指令，读出 32 位芯片身份码，JTAG 枚举链上的设备就靠它自报家门。多设备时 TDO→TDI 菊花链串联，一条链调试整板。

对照网络：JTAG 的 TAP 状态机像一条低速"管理以太网"，TCK 是时钟域，TDI/TDO 是双工数据线，IDCODE 是 LLDP 的 chassis ID。

### 2. SWD：两线协议

ARM 的 SWD（Serial Wire Debug，ADIv5 定义）用两根线达到 JTAG 的调试目的：**SWDIO**（双向数据）+ **SWCLK**（时钟），外加 GND，目标通常还需从调试器取 3.3V 电（同时充当电压参考）。省下的引脚对小封装 MCU 是生死线（8 脚封装不可能给 4 根调试线）。

协议帧格式（ADIv5，ARM IHI 0031）：

```text
  ┌─────────┬───────────────┬────────┬──────────────────────┐
  │ 8 bit   │ 3 bit         │ 32 bit │ 1 bit                │
  │ 请求    │ ACK           │ 数据   │ 奇偶                 │
  │ ApnDP   │ OK=001        │        │                      │
  │ RnW     │ WAIT=010      │        │                      │
  │ A[2:3]  │ FAULT=100     │        │                      │
  └─────────┴───────────────┴────────┴──────────────────────┘
   主机发     目标答            方向由 RnW 定    覆盖 ACK+数据
```

三个协议细节值得记住：

- **每个事务只访问 DP/AP 寄存器的 4 字节窗口**：请求里的 A[2:3] 选寄存器 bank 内偏移，`SELECT` 寄存器负责翻页（AP 编号 + 寄存器高半地址）。访问 32 位寄存器要两个事务（写 TAR 地址 + 读写 DRW 数据）；
- **ACK 三态**：OK 正常；WAIT 目标忙（调试器要重试——比 JTAG 的"无响应"优雅）；FAULT 上次访问出错（需写 ABORT 寄存器清错并查明原因，通常是总线 fault：访问了 powered-down 的外设或非法地址）；
- **进协议前的握手**：先发 50+ 拍 SWDIO 高电平（line reset），如果芯片当前在 JTAG 模式，还要先发 16 位魔数 `0xE79E`（JTAG↔SWD 切换序列，在 TMS 线上发送）——这就是 SWJ-DP：同一组引脚 PA13/PA14/PA15/PB3/PB4 复用两种协议，上电默认 JTAG，谁先发切换魔数听谁的。

### 3. DP/AP 访问模型：从两根线到整个内存映射

SWD/JTAG 只是物理层。ARM ADIv5 的层次结构（这是全节的骨架）：

```text
  调试器(openocd)
     │ SWDIO/SWCLK (SWD) 或 TCK/TMS/TDI/TDO (JTAG)
     ▼
  DP (Debug Port，协议引擎)
     │  AP 编号选路
     ▼
  AP (Access Port，通常用 MEM-AP；Cortex-M 内是 AHB-AP)
     │  直接挂上芯片的 AHB 总线矩阵
     ▼
  整个系统内存映射：Flash / SRAM / 外设寄存器 / 私有外设总线
```

关键认知：**AHB-AP 挂在总线矩阵上，所以调试器看到的就是 CPU 看到的同一张内存地图**——0x08000000 的 Flash、0x20000000 的 SRAM、0x40000000 起的外设寄存器，调试器都能直接读写，不需要 CPU 配合、不需要程序里埋任何代码。这就是"上帝视角"的硬件来源。

DP 的常用寄存器（SWD 视角，bank 0）：

| 地址 | 名字      | 用途                                                                    |
| ---- | --------- | ----------------------------------------------------------------------- |
| 0x00 | DPIDR     | 只读身份：版本（VERSION）、部件号（PARTNO）等字段（F407 为 0x2BA01477） |
| 0x00 | ABORT     | 只写：清除 AP/DP 的错误粘滞位                                           |
| 0x04 | CTRL/STAT | 通电状态、请求上电（SYSPWRUPREQ）、粘滞错误                             |
| 0x08 | SELECT    | AP 编号 + 寄存器地址翻页                                                |
| 0x0C | RDBUFF    | 读缓冲：拿到上一次 AP 读的最终值（流水线对齐用）                        |

DPIDR 是调试器连上目标后读的第一个寄存器——读到 0x2BA01477（Cortex-M4 r0p1 的身份，RM0090 §38.6.3）才算物理层通；11.3 的 `stm32f4x.cfg` 里 `set _CPUTAPID 0x2ba01477` 一行就是它，openocd 靠这个值校验"线那头是不是我要的芯片"。

MEM-AP 侧的常用寄存器：CSW（传输属性：传输大小/自动递增）、TAR（目标地址）、DRW（数据读写窗口）。写一次外设寄存器 = SELECT 选中 MEM-AP → 写 TAR=0x40020014 → 写 DRW=值，三个 SWD 事务。

**那 CPU 寄存器（R0-R15）怎么读？** 它们不在内存映射里。CoreSight 的答案分两步：

1. 调试器通过 AHB-AP 写内存映射中的调试寄存器组（私有外设总线 0xE0000000 区，ARMv7-M 架构手册 DDI 0403E.b Part C「Debug」）：
   - **DHCSR**（0xE000EDF0）：写 C_DEBUGEN=1 使能调试，写 C_HALT=1 停核，读它得到 halt 状态；
   - **DCRSR**（0xE000EDF4）/ **DCRDR**（0xE000EDF8）：写 DCRSR 选择"要访问第几号核寄存器、读还是写"，数据走 DCRDR——一套建立在内存接口上的核寄存器邮局；
   - **DEMCR**（0xE000EDFC）：TRCENA（开 DWT/ITM）、VC_CORERESET（复位即断住，"connect under reset"用）。
2. 停核后，gdb 的一句 `info registers` 在 openocd 里展开成一串 DCRSR/DCRDR 事务。

断点/单步的硬件：**FPB**（Flash Patch and Breakpoint，0xE0002000）提供 6 个指令比较器 + 2 个文字池比较器（Cortex-M4 TRM DDI 0439E）——地址匹配即触发断点或打补丁；**DWT**（0xE0001000）4 个比较器做 watchpoint（数据/地址观察点）。**gdb 的 hbreak/watch 在真机上就落在 FPB/DWT 上**——11.4 的 QEMU 演示会用 gdb 命令真实走一遍，机理一一对应。

CoreSight 一句话体系：以上这些组件（DAP、FPB、DWT、ITM、ETM、TPIU……）都是 ARM CoreSight 标准部件，芯片出厂时在 0xE00FF000 挂一张 ROM Table 自描述"我体内有哪些调试组件、各在哪"——调试器第一次连接后按表索骥，这就是 openocd 能用一份 cfg 通吃一个芯片家族的原因之一。

### 4. 对比与选择

| 维度     | JTAG                                   | SWD                              |
| -------- | -------------------------------------- | -------------------------------- |
| 信号线   | 4~5（TCK/TMS/TDI/TDO/nTRST）           | 2（SWDIO/SWCLK）+GND             |
| 引脚成本 | 高                                     | 低（小封装唯一选择）             |
| 协议     | 状态机 + 移位，通用标准（IEEE 1149.1） | ARM 专有（ADIv5），帧式          |
| 多器件   | 菊花链天然支持                         | 需 DPv2 multidrop（F407 不支持） |
| 典型场景 | 边界扫描、FPGA、多芯片板               | MCU 日常调试（本系列主线）       |

本系列主线用 SWD（ST-Link 原生），JTAG 作为知识储备。RISC-V 侧预告一句：GD32VF103 的对应物是 JTAG DTM → DMI → Debug Module（RISC-V Debug Specification 0.13），分层思想与 ADIv5 同构，[[ch09-riscv-gd32-contrast|第九章]]的寄存器对照表会在调试维度再补一行。

---

## 11.3 openocd 解剖：三层架构与三层配置

openocd（Open On-Chip Debugger）是开源世界的调试中间件事实标准，把"USB 调试器→芯片调试口→gdb"整条链翻译通。它已经装好（Fedora 仓库）：

```text
$ openocd --version
Open On-Chip Debugger 0.12.0
Licensed under GNU GPL v2
For bug reports, read
	http://openocd.org/doc/doxygen/bugs.html
$ rpm -q openocd
openocd-0.12.0-3.fc42.5.x86_64
```

### 1. 三层架构

```text
┌──────────────────────────────────────────────┐
│ server 层：gdb server(:3333) / telnet(:4444) / tcl(:6666) │
│    ——对上只说 GDB Remote Serial Protocol 或 openocd 命令 │
├──────────────────────────────────────────────┤
│ adapter 层：stlink / cmsis-dap / ftdi / jlink ……（USB 调试器驱动）│
├──────────────────────────────────────────────┤
│ target 层：cortex_m 调试驱动 + stm32f2x flash 驱动 + DAP 序列 │
└──────────────────────────────────────────────┘
```

本机编译进了哪些 adapter 驱动，一条命令问出来（真实输出，共 30 个）：

```text
$ openocd -c "adapter list" -c "shutdown"
The following debug adapters are available:
1: parport
2: dummy
3: ftdi
4: usb_blaster
5: esp_usb_jtag
6: jtag_vpi
7: jtag_dpi
8: ft232r
9: amt_jtagaccel
10: gw16012
11: presto
12: usbprog
13: openjtag
14: jlink
15: vsllink
16: rlink
17: ulink
18: arm-jtag-ew
19: buspirate
20: remote_bitbang
21: hla
22: osbdm
23: opendous
24: sysfsgpio
25: xlnx_pcie_xvc
26: aice
27: cmsis-dap
28: kitprog
29: xds110
30: st-link
shutdown command invoked
```

值得注意的分层细节：ST-Link 走 `hla`（High Level Adapter）路径——ST 的固件自己管底层时序，openocd 只发高层命令（`interface/stlink.cfg` 全文就是证据）：

```tcl
# /usr/share/openocd/scripts/interface/stlink.cfg（全文 19 行，本机真实文件）
adapter driver hla
hla_layout stlink
hla_device_desc "ST-LINK"
hla_vid_pid 0x0483 0x3744 0x0483 0x3748 0x0483 0x374b 0x0483 0x374d \
              0x0483 0x374e 0x0483 0x374f 0x0483 0x3752 0x0483 0x3753 0x0483 0x3754
```

那一串 vid_pid 是 ST-Link 各代硬件的 USB 身份（0483=ST，3748=V2，374B=V2-1，3752/3753/3754=V3 系列）——`lsusb` 里看到其中之一，openocd 就认识它。而 CMSIS-DAP/FTDI 走原生路径（openocd 自己驱动每一根信号线），所以它们能玩 SWD 之外的裸协议把戏（如 11.5 的 connect under reset 更精细控制）。

### 2. 配置三层：interface / board / target

openocd 的 cfg 是 Tcl 脚本，按"谁的职责"分三层目录（本机 `/usr/share/openocd/scripts/` 实际考证：`interface/` 49 个、`board/` 379 个、`target/` 309 个 cfg）：

| 层        | 目录         | 回答的问题               | 关键词举例                                    |
| --------- | ------------ | ------------------------ | --------------------------------------------- |
| interface | `interface/` | 电脑边是谁（调试器）     | stlink、cmsis-dap、jlink、ftdi                |
| target    | `target/`    | 线那头是什么芯片         | stm32f4x、gd32vf103、cortex_m 内核/flash 定义 |
| board     | `board/`     | 整块开发板（前两者拼装） | st_nucleo_f4、stm32f4discovery                |

三层的关系是**组合**：board = interface + target + 板级参数。本机考证两份关键文件都存在（这是本章真机方案的基石）：

- `target/stm32f4x.cfg` —— 存在；
- `board/st_nucleo_f4.cfg` —— 存在，且全文只有 16 行，因为它只做拼装（本机真实文件）：

```tcl
# /usr/share/openocd/scripts/board/st_nucleo_f4.cfg（全文）
source [find interface/stlink.cfg]      # ← 找到并加载 interface 层
transport select hla_swd                # ← 选 SWD 传输
source [find target/stm32f4x.cfg]       # ← 加载 target 层
reset_config srst_only                  # ← 板级复位策略：只用 SRST
```

`[find ...]` 会沿搜索路径（当前目录 → `/usr/share/openocd/scripts/`）解析文件名。本机真实验证它确实解析到系统路径：

```text
$ openocd -f board/st_nucleo_f4.cfg \
      -c 'set p [find target/stm32f4x.cfg]; echo "resolved: $p"' -c "shutdown"
resolved: /usr/bin/../share/openocd/scripts/target/stm32f4x.cfg
```

`target/stm32f4x.cfg`（本机真实文件，67 行）是芯片层的全部秘密，关键几行逐条对应 11.2 的知识：

```tcl
# ……省略：CHIPNAME/WORKAREASIZE 可被外部变量覆盖（board 层覆写口）
if { [using_jtag] } {
   # See STM Document RM0090
   # Section 38.6.3 - corresponds to Cortex-M4 r0p1
   set _CPUTAPID 0x4ba00477        # ← JTAG 模式的 IDCODE
} {
   set _CPUTAPID 0x2ba01477        # ← SWD 模式的 DPIDR（11.2 表里那个值！）
}
swj_newdap $_CHIPNAME cpu -irlen 4 -expected-id $_CPUTAPID   # 声明 DAP 并校验身份
target create $_CHIPNAME.cpu cortex_m -dap $_CHIPNAME.dap    # Cortex-M 调试驱动
$_TARGETNAME configure -work-area-phys 0x20000000 -work-area-size 0x8000
flash bank $_CHIPNAME.flash stm32f2x 0 0 0 0 $_TARGETNAME    # F4 的 flash 用 f2x 驱动（同代控制器）

$_TARGETNAME configure -event examine-end {
	# Enable debug during low power modes (uses more power)
	mmw 0xE0042004 0x00000007 0        # DBGMCU_CR |= DBG_STANDBY|DBG_STOP|DBG_SLEEP
	# Stop watchdog counters during halt
	mmw 0xE0042008 0x00001800 0        # DBGMCU_APB1_FZ |= DBG_IWDG_STOP|DBG_WWDG_STOP
}
```

- `mmw 0xE0042004 0x7`：连接成功即写 DBGMCU_CR（RM0090 §38），允许 Sleep/Stop/Standby 低功耗模式下保持调试连接——**没有这两位，你的代码一进 WFI 调试器就"失联"**；
- `mmw 0xE0042008`：halt 时冻结 IWDG/WWDG 看门狗——否则"断点停 3 秒、继续跑就复位"的灵异现象就来自这里，这是 11.1 说的"可配置冻结"的活例子；
- work-area 0x20000000/32KB：openocd 在目标 RAM 里借一块工作区加速 flash 编程（下载 stub）。

### 3. 无硬件自检：预期失败形态也是知识

板子没到，但 openocd 的启动分**配置解析**和 **adapter 初始化**两个阶段，前者不碰硬件。三种命令形态（全部本机真实执行）：

**形态一：纯解析自检（`-c shutdown` 在 init 前退出，不碰 USB）**

```text
$ openocd -f board/st_nucleo_f4.cfg -c "echo CONFIG_PARSE_OK" -c "shutdown"
Info : The selected transport took over low-level target control. The results might differ compared to plain JTAG/SWD
srst_only separate srst_nogate srst_open_drain connect_deassert_srst

CONFIG_PARSE_OK
shutdown command invoked
```

退出码 0。这条是**改完 cfg 后的标准自检**：语法错误、`find` 找不到文件、变量拼错都会在这暴露。

**形态二：完整启动（自动 init → 打开 USB 适配器 → 无硬件，失败）**

```text
$ openocd -f interface/stlink.cfg -f target/stm32f4x.cfg
Open On-Chip Debugger 0.12.0
Licensed under GNU GPL v2
For bug reports, read
	http://openocd.org/doc/doxygen/bugs.html
Info : auto-selecting first available session transport "hla_swd". To override use 'transport select <transport>'.
Info : The selected transport took over low-level target control. The results might differ compared to plain JTAG/SWD
Info : Listening on port 6666 for tcl connections
Info : Listening on port 4444 for telnet connections
Info : clock speed 2000 kHz
Error: open failed
```

（exit code 1，几秒后进程退出。）这五行 Info 的分层读法，是本节最值钱的知识：

1. 前两行：**配置层全部通过**——transport 选了 hla_swd（stlink.cfg + stm32f4x.cfg 解析成功，source 链走通）；
2. 中三行：**server 层已经立起来**——telnet 4444、tcl 6666 端口在听（gdb 的 3333 在 init 完成后才开）；
3. 最后一行 `Error: open failed`：**失败精确发生在 adapter 层**——libusb 找不到任何一个 stlink.cfg 里列的 vid:pid。配置没有问题，缺的只是那块硬件。

真机到手后同一命令的差别只会是：`Error: open failed` 变成 `STM32F4XX.cpu: hardware has 6 breakpoints, 4 watchpoints`（openocd 读 FPB/DWT 的能力上报——正是 11.2 说的那两组比较器）。

**形态三：两种配置错误（对照，帮助分层定位）**

```text
$ openocd -f interface/stlink.cfg -f target/stm32f99x.cfg
embedded:startup.tcl:28: Error: Can't find target/stm32f99x.cfg
Traceback (most recent call last):
  File "embedded:startup.tcl", line 28, in script
    find target/stm32f99x.cfg

$ openocd -f target/stm32f4x.cfg
Error: Debug adapter does not support any transports? Check config file order.
Error: unable to select a session transport. Can't continue.
shutdown command invoked
```

第一个：文件名拼错，`find` 阶段就死；第二个：只给 target 不给 interface——**加载顺序是 interface 在前**（transport 由 adapter 声明支持列表，target 只做选择）。两条报错都比"open failed"更早发生，看报错就能判断自己死在哪一层。

---

## 11.4 无板期的上帝视角：QEMU gdbstub 直连

openocd 能不能接 QEMU？如实回答：**不能**。QEMU 的系统仿真不建模 ADIv5/SWD 端口（没有 DP/AP 可言）；openocd 的 `jtag_dpi`/`jtag_vpi` 驱动（11.3 驱动清单里的 6/7 号）是给 RTL 仿真器（Verilator 之类）的套接字接口，对 QEMU 无效。但**这并不损失什么**——openocd 对上的出口本来就是 GDB Remote Serial Protocol，而 QEMU 自带 gdbstub 直接说这门语言：

```text
真机：  gdb ──GDB RSP── openocd(:3333) ──SWD── 芯片调试硬件 ──AHB── 内存/核
无板：  gdb ──GDB RSP── qemu gdbstub(:1234) ──────(直接)-── 仿真的内存/核
```

gdb 不关心背后是谁——`target remote localhost:1234` 连哪个都一样。第三章/第四章已经用这条通道验证过复位序列和栈帧，本章把它升级成**系统化的无板调试循环**，并用它讲清硬件/软件断点的区别。全部会话复用第四章模板工程（`practice/hwbasics/ch04-baremetal-template/`，`make` 后 `qemu-system-arm -M mps2-an385 -kernel build/ch04-baremetal.elf -nographic -S -gdb tcp::1234`）。

### 1. 硬件断点 vs 软件断点：一次真实对照

```text
$ gdb --batch -ex 'set architecture arm' -ex 'file build/ch04-baremetal.elf' \
      -ex 'target remote localhost:1234' \
      -ex 'hbreak Reset_Handler' -ex 'break main' -ex 'info breakpoints' \
      -ex 'continue' -ex 'info registers pc sp lr'
The target architecture is set to "arm".
Reset_Handler () at startup.S:55
55	    ldr  r0, =_sidata
Hardware assisted breakpoint 1 at 0xc0: file startup.S, line 55.
Breakpoint 2 at 0x168: file main.c, line 66.
Num     Type           Disp Enb Address    What
1       hw breakpoint  keep y   0x000000c0 in Reset_Handler at startup.S:55
2       breakpoint     keep y   0x00000168 in main at main.c:66

Breakpoint 2, main () at main.c:66
66	{
pc             0x168               0x168 <main>
sp             0x20020000          0x20020000
lr             0xe9               233
[Inferior 1 (process 1) detached]
```

（细节说明：QEMU 带 `-S` 启动、gdb 接上时 PC 已停在 0xc0，所以 1 号硬件断点不再触发，`continue` 一口气跑进 main 的 2 号软件断点。）

两种断点的机理差异：

|          | 软件断点（`break`）                                | 硬件断点（`hbreak`）                                       |
| -------- | -------------------------------------------------- | ---------------------------------------------------------- |
| 实现位置 | 目标内存里：把指令替换为 BKPT（Thumb 的 `0xBE00`） | 芯片调试硬件：FPB 指令比较器（QEMU 里是内部断点表）        |
| 数量     | 无限                                               | 有限（F407：6 个指令 + 2 个 literal；DWT 4 个 watchpoint） |
| 只读区域 | **不能**——写 flash 需整块擦写编程                  | 能（比较器只"看地址"，不写内存）                           |
| 隐患     | 改变了程序映像（若代码校验和/CRC 自检会炸）        | 无痕迹                                                     |

**真机铁律：flash 里的代码用 hbreak**。软件断点要求把 BKPT 写进指令位置——RAM 里的代码随便写，flash 里是页擦写，openocd 会尝试经 flash 驱动写入（慢且有磨损），多数工具链直接失败。QEMU 里两者都行（mps2 的代码区本就是可写 SSRAM，第四章考证过），但习惯从现在养成：**永久断点用 hbreak，临时打在 RAM 函数上的用 break**。gdb 协议层面，两者分别是 Z0/Z1 包，QEMU/openocd 都实现了。

### 2. watchpoint：DWT 的能力，QEMU 里真实可用

gdb 的 `watch`（写观察点）落到真机是 DWT 比较器。用第四章的证人性变量 `data_var`（0x20000000，初值 0x20260830）演示——**观察 Reset_Handler 的 .data 拷贝循环写入它的那一瞬间**：

```text
$ gdb --batch -ex 'set architecture arm' -ex 'file build/ch04-baremetal.elf' \
      -ex 'target remote localhost:1234' \
      -ex 'watch *(unsigned int *)0x20000000' -ex 'continue' \
      -ex 'info registers pc r0 r1 r2' -ex 'x/wx 0x20000000'
Hardware watchpoint 1: *(unsigned int *)0x20000000

Old value = 0
New value = 539363376
Reset_Handler () at startup.S:63
63	    b    1b
pc             0xd2                0xd2 <Reset_Handler+18>
r0             0x36c               876
r1             0x20000004          536870916
r2             0x20000004          536870916
0x20000000 <data_var>:	0x20260830
```

逐行验尸：新值 539363376 = 0x20260830（.data 初值魔数）；命中点 PC=0xd2 是拷贝循环的回跳指令 `b 1b`（第四章反汇编里 0xce 是 `str.w r3,[r1],#4`、0xd2 是 `b.n`）——**watchpoint 在那次 store 执行后立刻捕获**；此刻 r1 已递增到 0x20000004、r2（终点 \_edata）也是 0x20000004——下一个循环判断就会退出，因为 data_var 是唯一的 .data 字。第五章你在真机上调试"全局变量初值不对"时，这一招直接告诉你**是谁、在哪条指令改写了它**（野指针、DMA 误写、栈溢出砸内存，全都现形）。

### 3. 断点 + 单步 + 寄存器组：一次完整的上帝视角会话

```text
$ gdb --batch -ex 'set architecture arm' -ex 'file build/ch04-baremetal.elf' \
      -ex 'target remote localhost:1234' \
      -ex 'break main' -ex 'continue' -ex 'x/6i $pc' -ex 'stepi 4' \
      -ex 'info registers r0 r1 r2 r3 r12 sp lr pc xpsr' -ex 'x/wx 0x20000000'
The target architecture is set to "arm".
Breakpoint 1 at 0x168: file main.c, line 66.

Breakpoint 1, main () at main.c:66
66	{
=> 0x168 <main>:	push	{r3, lr}
   0x16a <main+2>:	bl	0x100 <uart_init>
   0x16e <main+6>:	ldr	r0, [pc, #172]	@ (0x21c <main+180>)
   0x170 <main+8>:	bl	0x122 <uart_puts>
   0x174 <main+12>:	ldr	r0, [pc, #168]	@ (0x220 <main+184>)
   0x176 <main+14>:	bl	0x122 <uart_puts>
0x00000106	31	    UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN;
r0             0x36c               876
r1             0x20000008          536870920
r2             0x3                 3
r3             0x40004000          1073758208
r12            0x0                 0
sp             0x2001fff8          0x2001fff8
lr             0x16f               367
pc             0x106               0x106 <uart_init+6>
xpsr           0x21000000          553648128
0x20000000 <data_var>:	0x20260830
```

看点：`stepi 4` 从 main 走进 `uart_init` 并停在 0x106，此刻 **r3=0x40004000——UART0 基址作为立即数已被装进寄存器**（第四章反汇编一节的 `mov.w r3, #1073758208` 正是它）；lr=0x16f 是 `bl` 压入的返回地址（main+5 处的下一条指令）；sp=0x2001fff8 说明 main 的 `push {r3,lr}` 已经压了两个字。源码行号、汇编、寄存器、内存四视图同屏——这就是 god view。

### 4. gdb 远程调试速查表（以上命令全部实证过）

| 场景         | 命令                                                                           | 备注                              |
| ------------ | ------------------------------------------------------------------------------ | --------------------------------- |
| 连接         | `set architecture arm` → `file build/app.elf` → `target remote localhost:1234` | 先 file 后 connect（第三章踩过）  |
| 软件断点     | `break main` / `break *0x168` / `delete 2`                                     | 改写指令为 BKPT；flash 慎用       |
| 硬件断点     | `hbreak Reset_Handler`                                                         | FPB 比较器；flash 代码必用它      |
| 观察点       | `watch *(unsigned int *)0x20000000`（写）/ `rwatch`（读）/ `awatch`（读写）    | DWT；野指针排查神器               |
| 执行控制     | `continue` / `stepi N` / `nexti` / `step`                                      | stepi 是指令级                    |
| 内存检查     | `x/4wx 0x0`（字）/ `x/6i $pc`（反汇编）/ `x/s 0x200`                           | `x/` 后 <个数><格式><宽度>        |
| 内存写入     | `set {int}0x20000000 = 0x20260830`                                             | 直接改 SRAM/外设寄存器            |
| 寄存器组     | `info registers`（全）/ `info registers r0 pc xpsr` / `p/x $xpsr`              | 第三章已用过                      |
| 断开会话     | `disconnect`（保持暂停）/ `detach`（放行继续跑）                               | 第三章的坑：detach 会放跑目标     |
| openocd 透传 | `monitor reset halt` / `monitor targets`                                       | monitor 后接 openocd 命令，真机用 |

把速查表贴在工位上——真机到位后，这份表从 QEMU 到 ST-Link 一字不改地复用（只有端口号从 1234 换成 3333）。

---

## 11.5 真机占位：ST-Link + F407 从接线到 attach

> [!warning] 真机待验证
> 板卡未到位，本节接线表与预期输出为**基于 openocd 0.12.0 配置库、RM0090 与 ST-Link 文档的预置方案**，板到后逐条回填实测。

### 1. 接线表（ST-Link V2 20-pin 排针 ↔ STM32F407VET6）

F407 的 SWD 引脚复位后默认即调试功能（AF0，RM0090 §8 复用表）：PA13=SWDIO、PA14=SWCLK、PB3=SWO、PA15=JTDI、PB4=NJTRST。

| ST-Link 信号 | 20-pin 脚位 | F407 引脚 | 必接 | 说明                           |
| ------------ | ----------- | --------- | ---- | ------------------------------ |
| SWDIO        | 7           | PA13      | 是   | 数据线                         |
| SWCLK        | 9           | PA14      | 是   | 时钟线                         |
| GND          | 4（或 20）  | GND       | 是   | 共地                           |
| VTref        | 1           | 3V3       | 是   | ST-Link 检测目标电压作电平参考 |
| RESET        | 15          | NRST      | 建议 | connect under reset 需要它     |
| SWO          | 19          | PB3       | 可选 | SWO trace（L2 层级预告）       |

接线三铁律（同 [[ch06-uart-protocol|第六章]] UART 的教训）：共地先行、电平匹配（3.3V，勿接 5V 到 VTref 之外的信号脚）、杜邦线越短越好（SWCLK 建议从 2 MHz 起步——cfg 默认值 `adapter speed 2000` 就是 2000 kHz）。

### 2. 从 openocd 启动到 gdb attach 的完整流程（预期）

```bash
# 终端 1：起 openocd（预期输出见下方注释）
openocd -f interface/stlink.cfg -f target/stm32f4x.cfg

# 终端 2：gdb attach
arm-none-eabi-gdb build/app.elf        # 本机用原生 gdb 也行（第三章考证过多目标构建）
(gdb) target extended-remote localhost:3333
(gdb) monitor reset halt               # 复位并停住：停在 Reset_Handler 入口
(gdb) break main
(gdb) continue
```

预期 openocd 输出（形态，真机回填）：

```text
Info : Listening on port 6666 for tcl connections
Info : Listening on port 4444 for telnet connections
Info : clock speed 2000 kHz
Info : STLINK V2 JTAG v37 ...          ← 适配器打开（对应本机实验里的 "Error: open failed"）
Info : STM32F4xx: Enabling HSI ...      ← 芯片时钟假设与 DAP 上电
STM32F4XX.cpu: hardware has 6 breakpoints, 4 watchpoints   ← FPB/DWT 能力上报（11.2 的数字）
Info : accepting 'gdb' connection on tcp/3333
```

### 3. 常见失败形态速查（真机回填实测）

| 报错/现象                                                   | 最可能原因                                                       | 处置                                                                   |
| ----------------------------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `Error: open failed`                                        | 本机无 ST-Link / USB 未识别                                      | `lsusb` 找 0483:3748 等（11.3 的 vid 表）                              |
| `Error: init mode failed (unable to connect to the target)` | 目标未上电 / SWD 线松或接反 / 目标代码把 PA13/PA14 复用成了 GPIO | 查 3V3；重插线；降速 `adapter speed 500`；用 connect under reset       |
| 读到稳定但错误的 DPIDR（如 0x00000000）                     | SWDIO/SWCLK 有一根接触不良                                       | 重接杜邦线，缩短长度                                                   |
| 能连但 flash 读写报错 / 只能读出全 0xFF                     | RDP 读保护（option bytes，RM0090 §3.9）                          | level 1 可经全片擦除回 level 0；level 2 不可逆（量产保护），调试板勿开 |
| 断点停住几秒后目标自己复位                                  | 看门狗没冻结 / NRST 被外拉                                       | 确认 cfg 的 examine-end 事件生效（11.3）；查复位脚电平                 |
| 时好时坏、长连接掉线                                        | 速率过高 / 线太长 / 供电不足                                     | `adapter speed 1000` 起步                                              |

**connect under reset** 值得单独记：若应用程序把 SWD 引脚复用成 GPIO 或关闭了调试时钟，openocd 只有在"芯片还捏在复位里"的窗口才能接管。做法是接上 NRST 并配置 `reset_config connect_assert_srst`——复位期间完成 DAP 握手，然后 `monitor reset halt` 拿到 0x08000000 的控制权。

---

## 11.6 烧录工具地图：flash write_image 命令族与三个对手

烧录和调试是同一条物理通道的两份差事（openocd 的 target 层同时注册了 `cortex_m` 调试驱动和 `stm32f2x` flash 驱动——11.3 的 cfg 第 53 行）。真机烧录命令族（语法为 openocd 0.12 命令，执行结果真机回填）：

```bash
# 形态 A：telnet 会话式（openocd 起服务后，telnet localhost 4444）
> reset halt                              # 复位并停住（不写 flash 前先停）
> flash write_image erase build/app.bin 0x08000000
> flash verify_image build/app.bin 0x08000000
> reset run                               # 复位并放行

# 形态 B：单命令流水线（不进交互，CI 友好）
openocd -f interface/stlink.cfg -f target/stm32f4x.cfg \
        -c "program build/app.elf verify reset exit"

# 形态 C：gdb 里经 openocd 烧录
(gdb) monitor reset halt
(gdb) load                                # 走 openocd flash 驱动写 flash
(gdb) monitor reset run
```

三个对手一张表：

| 工具                  | 出品方   | 通道                             | 一句话定位                                                                  |
| --------------------- | -------- | -------------------------------- | --------------------------------------------------------------------------- |
| openocd               | 开源社区 | 任意适配器（ST-Link/DAP/J-Link） | 调试为主、烧录为辅；gdb 深度集成                                            |
| STM32CubeProgrammer   | ST 官方  | ST-Link / UART / DFU             | 官方全功能（含 option bytes/RDP 管理），CLI+GUI                             |
| st-flash（stlink 包） | 开源社区 | 仅 ST-Link                       | 轻量一行流：`st-flash write app.bin 0x08000000`                             |
| dfu-util              | 开源社区 | USB DFU（无需调试器！）          | 走芯片系统 bootloader（AN2606：F407 的 OTG FS 支持 DFU），量产/无调试器场景 |

DFU 一句话展开：F407 出厂 ROM 里驻留 bootloader，BOOT0=1 从系统存储器启动后，无需任何调试器、只靠 USB 就能烧录（`dfu-util -l` 枚举 0483:df11）——代价是只能烧不能调试，且要先 `dfu-suffix` 包装镜像。GD32VF103 侧：烧录调试同样走 openocd（`target/gd32vf103.cfg` 已在本机 0.12.0 配置库考证存在），适配器用 J-Link 或 Sipeed RV-Debugger，细节留给 RISC-V 真机章。

---

## 11.7 小结与下一章

本章把"调试"从手段拼成了体系，每个环节都有实证或考证锚点：

- **层级**：printf（87 µs/字节的观察者效应）→ 在线调试（SWD/JTAG + gdb，可配置冻结的扰动）→ trace（SWO/ETM 预告）；
- **通道**：SWD 两线协议（请求 8 bit + ACK 3 bit + 数据 32 bit，DPIDR=0x2BA01477）与 JTAG（TAP 状态机/IDCODE），ADIv5 的 DP→AP(AHB-AP)→总线模型让调试器直达全部内存映射；核寄存器经 DHCSR/DCRSR/DCRDR 邮局（0xE000EDF0-EFC），断点/watchpoint 落在 FPB（6+2）与 DWT（4）；
- **openocd**：server/adapter/target 三层，interface/board/target 三层配置（本机清单：interface 49 / board 379 / target 309，`st_nucleo_f4.cfg`、`stm32f4x.cfg` 均存在）；无硬件自检三形态真实跑通——`-c shutdown` 纯解析（exit 0）、完整启动的 `Error: open failed`（配置层全过、败在 USB 层）、拼错文件名/缺 interface 的两种更早报错；
- **无板调试循环**：QEMU gdbstub 与 openocd 对 gdb 说同一门语言（GDB RSP），硬件/软件断点（Z1/Z0）真实对照、watchpoint 真实捕获 `.data` 拷贝（0→0x20260830）、寄存器组会话展示 r3=0x40004000 的外设基址——速查表直接平移真机（只改端口号）；
- **真机占位**：ST-Link↔F407 接线表、启动到 attach 流程、失败形态速查（含 RDP 锁死与 connect under reset）、烧录四工具地图——全部标注真机待验证，板到回填。

下一章是整个系列的收官：[[ch12-freertos-port-contrast|第十二章：FreeRTOS 三架构 port 对照]]——把 Cortex-M 的 PendSV/双栈/SVC（第三章的解剖 + 本章的调试视角）与你在 FreeRTOS 系列读过的 Xtensa port、以及 RISC-V 的 machine timer 对照收官，三套架构在"上下文切换"这道同一道题上的三种解法。

---

## 参考

- ARM IHI 0031（ARM Debug Interface v5，ADIv5）：SWD 协议帧格式、DP/AP 寄存器、SWJ-DP 切换序列
- ARMv7-M Architecture Reference Manual（DDI 0403E.b）Part C「Debug」：DHCSR/DCRSR/DCRDR/DEMCR（0xE000EDF0-FC）、FPB（0xE0002000）、DWT（0xE0001000）、ROM Table
- ARM DDI 0439E（Cortex-M4 Technical Reference Manual）：FPB 六指令 + 两文字池比较器、DWT 四比较器
- ST RM0090（STM32F407 参考手册）：§38 Debug support（DBGMCU_CR 0xE0042004 / APB1_FZ 0xE0042008、§38.6.3 调试身份码）、§8 引脚复用（PA13/PA14/PB3）、§3.9 option bytes（RDP 层级）
- ST AN2606（STM32 system memory boot mode）：F407 系统 bootloader 的 UART/DFU（OTG FS）通道
- OpenOCD 文档（openocd.org/doc/doxygen，0.12.0）：adapter driver 与 flash 命令族、`program` 流水线命令
- 本机配置库：`/usr/share/openocd/scripts/`（interface 49 / board 379 / target 309 个 cfg，`st_nucleo_f4.cfg`、`target/stm32f4x.cfg`、`target/gd32vf103.cfg` 均存在）
- 本系列 [[ch03-arm-cortex-m-anatomy|第三章]]（gdbstub 会话经验与 detach 坑）、[[ch04-baremetal-boot|第四章]]（模板工程与 .data 拷贝证据）、[[ch07-interrupts-nvic|第七章]]（AIRCR/SYSRESETREQ）、[[ch09-riscv-gd32-contrast|第九章]]（RISC-V 调试体系对照预告）
