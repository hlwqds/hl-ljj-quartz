---
title: 一次 read() 的全栈旅行
date: 2026-08-30 04:00:00
description: strace -T 与 ftrace function_graph 双镜跟踪一次 /dev/spidev0.0 传输——从 syscall 行到 bcm2835_spi_transfer_one 的寄存器写，四层证据链各留一行；全系列「四层下钻」方法论的 Linux 完整版收束
tags: [rpi-lab, RPi, Linux, Tracing]
---

# 一次 read() 的全栈旅行

> **状态声明**：本章为「先成文、后实跑」的实验设计，**未在真机执行**；以
> [[ch01-bookworm-surgery-baseline|ch01]] 升级后的 Bookworm（内核 ≥ 6.6）与
> [[ch06-device-tree-overlay-spi|ch06]] 的 spidev 回环环境为前提。ftrace 的
> 具体函数名与调用链形态以 6.6 内核**实测**为准（本文函数名已对照 rpi-6.6.y 的
> drivers/spi/spi-bcm2835.c 源码核实，仍以 available_filter_functions 为权威清单）；
> 「预期输出」均为待实测核销占位。

## 本章装备清单

| 分类   | 装备                       | 价格/状态 | 用途                                                             |
| ------ | -------------------------- | --------- | ---------------------------------------------------------------- |
| 已有   | 树莓派 4B + MicroSD + 网线 | ✅        | 实验主体（ch01 升级后的 Bookworm + ch06 回环环境，两章成果复用） |
| 已有   | 笔记本                     | ✅        | SSH 进树莓派敲命令、收集并保存四层证据存档                       |
| 需购买 | 杜邦线一根（母对母）       | ~¥10/排   | MOSI–MISO 回环短接（ch06 已接好的那根，直接沿用）                |
| 可选   | fx2lpo 24M 逻辑分析仪      | ~¥50      | L4 对照组：piscope 软件波形拿不准时，由硬件分析仪仲裁            |

> 装备说明：L1/L2/L3 三层证据全靠软件仪器（strace、ftrace、/proc），一根杜邦线撑起 L4。
> 逻辑分析仪是可选项——1 MHz 的 SCLK 对 24 MSa/s 的采样率，足够数清 32 个时钟周期的突发。

## 本章会遇到的词

先混个脸熟，正文首现处会再展开（术语卡 📖 或行内括号）：

| 词                            | 一句话解释                                                |
| ----------------------------- | --------------------------------------------------------- |
| syscall（系统调用）           | 用户程序请求内核服务的唯一合法入口，如 `read()`           |
| strace                        | 拦截并打印程序全部 syscall 的跟踪器（L1 仪器）            |
| ftrace                        | 内核自带的函数级跟踪框架（L2 仪器的底座）                 |
| tracefs                       | ftrace 的控制面板：用读/写文件的方式操控内核跟踪器        |
| function_graph                | ftrace 的一种 tracer，输出带耗时的函数调用缩进树          |
| VFS / file_operations         | 内核统一的文件操作接口层：一张按设备填好的函数指针表      |
| spidev                        | Linux 通用 SPI 字符设备驱动，对外暴露 `/dev/spidev0.0`    |
| ioctl                         | 「read/write 装不下」的控制类 syscall；SPI 全双工传输走它 |
| MMIO                          | 内存映射 IO：把外设寄存器当作内存地址直接读写             |
| /proc/iomem、/proc/interrupts | 内核导出的物理地址持有表、中断计数表（L3 痕迹来源）       |
| inline 函数                   | 编译期被展开进调用者体内的函数——ftrace 的天然盲区         |
| 回环（loopback）              | 输出线接回输入线，发出的字节原样返回（L4 物证来源）       |

## 目标（先结论）

对 `read(/dev/spidev0.0)` 一个字节做全栈解剖，用两台仪器（strace 管 syscall 层、ftrace
function_graph 管内核层）加上两件物证（中断/寄存器痕迹、回环字节），产出**一张四层证据链表**
——每一层各留一行可存档的证据。这是 ch03 那笔「过路费账单」从另一头的清算：ch03 在用户态数
syscall 次数，本章进内核看每个 syscall 里面发生了什么，直到 SPI 控制器的寄存器写。

| #    | 做通标准                                                                    | 对应   |
| ---- | --------------------------------------------------------------------------- | ------ |
| R5.1 | 四层各留一行证据存档（strace 行 / function_graph 段 / 硬件痕迹 / 回环字节） | 主实验 |

四层的分层与全系列方法论一致：

| 层  | 是什么     | 仪器（本章）                                                       | 裸机同位物（F429）                                     |
| --- | ---------- | ------------------------------------------------------------------ | ------------------------------------------------------ |
| L1  | syscall 层 | `strace -T`（次数+耗时）                                           | ——（没有这层，函数就是函数）                           |
| L2  | VFS/驱动层 | ftrace `function_graph`（调用链+时长）                             | 断点二分 / 调用栈                                      |
| L3  | 硬件层     | `/proc/iomem`、`/proc/interrupts`、dmesg（内核环形日志的查看命令） | openocd `mdw` 活体读寄存器                             |
| L4  | 物理层     | 回环字节 + piscope 波形                                            | 串口字节 + 示波器/LA（logic analyzer，逻辑分析仪）波形 |

## 1. 原理：为什么 spidev 是最好的靶子

> 📖 **术语卡：spidev**
> **是什么**：Linux 内核的通用 SPI 字符设备驱动，把某条 SPI 总线包装成 `/dev/spidev0.0` 这样的设备文件（编号含义：`0.0` = 总线 0、片选 0）。
> **为什么存在**：让用户态程序不必写内核模块就能收发 SPI 字节——`open()` + `ioctl()` 两个 syscall 就够。
> **类比**：像网卡的通用 socket 接口——应用只管对 `/dev/spidev*` 读写，不必关心底下接的控制器是 bcm2835 还是别的芯片。
> ⚠️ 类比边界：socket 背后有整条协议栈兜底，spidev 是裸字节通道——你给什么波形，线上就是什么波形。

`/dev/spidev0.0` 的妙处在于**四层全通**：它有标准 syscall（system call，系统调用：用户程序
请求内核服务的唯一合法入口）面（L1 可 strace）、经 VFS 的
`file_operations` 分派（L2 可 ftrace，[[ch04-kernel-module-mygpio|ch04]] 立的
锚点）、落到 spi-bcm2835 驱动的 MMIO（memory-mapped IO，内存映射 IO：外设寄存器被映射进
内存地址空间，CPU 读写某个地址就是读写那颗寄存器；L3 有痕迹）、而回环短接线（loopback：把
MOSI 主出从入发送线直接接到 MISO 主入从出接收线，发出的字节原样弹回）让每个出站字节原样返回
（L4 有物理证据）。

> 📖 **术语卡：VFS 与 file_operations**
> **是什么**：VFS（Virtual File System，虚拟文件系统）是内核给「一切皆文件」打底的抽象层；每个驱动填一张 `file_operations` 函数指针表（open/read/write/ioctl 各指向谁），VFS 按你 `open()` 到的对象把调用分派给对应驱动的函数。
> **为什么存在**：让 `cat` 磁盘文件和 `read()` SPI 设备用同一套 syscall——内核版的多态（函数指针实现，ch04 立的锚点正是这张表）。
> **类比（你的主场）**：像协议栈的 socket 层不区分底层是 eth0 还是 wlan0——接口统一、实现可插拔。
> ⚠️ 类比边界：网络分层靠逐层封包解包，VFS 分派只是一次函数指针跳转，没有「包头」开销。

两条用户态路径都要看——它们在内核里汇进同一条链：

- `read(/dev/spidev0.0)`：只收不发（TX 侧发 0x00。TX = transmit 发送侧；read 语义上「只收」，
  但 SPI 没有只收的拍子——时钟每拍都在交换位，内核只能往发送侧填 0x00 占位），回环时读到
  0x00——**验证路径通**；
- `ioctl(SPI_IOC_MESSAGE)`（SPI_IOC_MESSAGE(n) 是 spidev 定义的 ioctl 命令码：一次提交 n 条
  传输消息，返回值 = 实际传输的总字节数；[[ch06-device-tree-overlay-spi|ch06]]
  的 spiloop）：全双工（full-duplex：收发同拍进行——SPI 的 MOSI/MISO 两条数据线天然支持，
  对比 I2C 单数据线的半双工）发 `A5 5A 00 FF`，回环读回同串——**验证字节内容**，物理层证据用它。

> 📖 **术语卡：ioctl**
> **是什么**：「input/output control」——专门承载 read/write 表达不了的设备控制操作的 syscall；每个驱动自定义命令码（如 spidev 的 `SPI_IOC_MESSAGE`）与参数结构。
> **为什么存在**：文件读写只有「往缓冲区读/写顺序字节」一种语义，而设备有各种非顺序语义的操作（设速率、发起一次全双工传输），统统从 ioctl 这扇杂项门进。
> **类比（你的主场）**：数据面走 read/write，控制面走 ioctl——如同转发的包走数据通道、改配置走管理通道，两条道各走各的门。
> ⚠️ 类比边界：管理通道好歹有标准协议（SNMP/NETCONF），ioctl 没有统一格式——命令码与参数结构完全由驱动自定义，strace 只能帮你看到门牌号。

## 2. L1：strace 记账（syscall 层）

> 📖 **术语卡：strace**
> **是什么**：系统调用级的跟踪器：把程序发起的每个 syscall 的名字、参数、返回值（开 `-T` 还有耗时）打印成文本行。底层机制是 ptrace——被跟踪程序每次进出内核都被拦停一次，跟踪器趁停顿抄走参数。
> **为什么存在**：syscall 是用户态/内核态的边界，程序「卡了、慢了、权限错了」的答案大多挂在这条边界上。
> **类比（你的主场）**：strace 之于 syscall，如同 tcpdump 之于报文——抓全量、可过滤、自带开销。
> ⚠️ 类比边界：tcpdump 的 BPF 过滤器在内核里丢包、代价小；strace 的 ptrace 每次进出内核都要停走一轮，性能放大效应重得多——所以本章纪律是「记账用 strace，测时绝不在 strace 下测」。

```bash
# 路径 A：read() 一个字节（回环状态下预期读到 0x00）
sudo strace -T -e trace=openat,read,ioctl -s 16 \
    dd if=/dev/spidev0.0 bs=1 count=1 of=/dev/null 2>&1 | grep -vE 'ld\.so|locale'

# 路径 B：spiloop 的一次全双工传输
sudo strace -T -e trace=openat,ioctl -s 32 ./spiloop 1000000 2>&1 | tail -8
```

预期能看到（形态待实测）：`openat("/dev/spidev0.0", O_RDWR) = 3` 之后，路径 A 一行
`read(3, "\0", 1) = 1`，路径 B 一行 `ioctl(3, SPI_IOC_MESSAGE(1), {...}) = 4`——返回值正是
传输字节数。`-T` 给每行挂耗时（µs 级），这就是 ch03 账单的延续：**ioctl 那几微秒里，内核
替你走完了 L2–L3**。纪律照旧：记账用 strace，测时绝不在 strace 下测。

**命令拆解：** `sudo strace -T -e trace=openat,read,ioctl -s 16 dd if=/dev/spidev0.0 bs=1 count=1 of=/dev/null 2>&1 | grep -vE 'ld\.so|locale'`（路径 A）

| 部分                         | 作用                                                                                  |
| ---------------------------- | ------------------------------------------------------------------------------------- |
| `sudo strace`                | 以 root 运行跟踪器（`/dev/spidev0.0` 默认属 root:spi，普通用户常读不了）              |
| `-T`                         | 每个 syscall 行尾追加耗时，如 `<0.000123>`（单位是秒的定点小数）                      |
| `-e trace=openat,read,ioctl` | 只显示这三类 syscall，把动态链接器/locale 的噪音调用滤掉                              |
| `-s 16`                      | 每个指针参数指向的缓冲区最多回显 16 字节，防刷屏                                      |
| `dd if=... bs=1 count=1`     | dd（按块复制的经典工具）：输入源是设备、每次 1 字节、只读 1 块——正好触发一次 `read()` |
| `of=/dev/null`               | 读到的字节丢进「黑洞」设备，本次只为借道触发 syscall                                  |
| `2>&1`                       | strace 的输出走 stderr，用重定向并进 stdout 才能进管道                                |
| `grep -vE 'ld\.so\|locale'`  | `-v` 反选命中行 + `-E` 扩展正则：滤掉动态链接器装载阶段的杂音                         |

**命令拆解：** `sudo strace -T -e trace=openat,ioctl -s 32 ./spiloop 1000000 2>&1 | tail -8`（路径 B）

| 部分                    | 作用                                                       |
| ----------------------- | ---------------------------------------------------------- |
| `-e trace=openat,ioctl` | 路径 B 不走 read，全双工传输从 ioctl 门进                  |
| `-s 32`                 | 缓冲区回显放宽到 32 字节，够看清 4 字节传输的结构          |
| `./spiloop 1000000`     | ch06 的全双工回环程序，参数是时钟速率 1000000 Hz（1 MHz）  |
| `tail -8`               | 只看最后 8 行——首轮之后的 ioctl 形态都一样，看尾部即看代表 |

**你会看到**：`openat` 之后 read/ioctl 各一行，行尾挂 `<0.000xxx>` 级耗时（完整形态见下方「预期输出（待实测核销）」）。
**失败了先查**：权限（把用户加进 `spi` 组，或干脆 sudo）、`strace` 是否已装（`sudo apt install strace`）、`./spiloop` 是否就在当前目录。

## 3. L2：ftrace function_graph（内核层，配置步骤全录）

> 📖 **术语卡：ftrace**
> **是什么**：Linux 内核自带的跟踪框架：编译内核时给每个函数入口埋了跳转桩（历史叫 mcount，现代内核用 fentry/patchable-function-entry 一类实现），运行时可按需记录指定函数的调用。它不是单一工具，而是一整套内核仪器的总机。
> **为什么存在**：内核态发生的事，用户态仪器天生看不见——内核必须自带内窥镜。
> **类比（你的主场）**：像交换机自带的端口计数器与镜像口——不依赖外部探针，设备自己交代自己。
> ⚠️ 类比边界：镜像口是无感旁路复制；ftrace 的桩要在函数入口真执行几条指令，被跟踪路径会变慢。

> 📖 **术语卡：tracefs**
> **是什么**：一个伪文件系统（通常挂在 `/sys/kernel/tracing`），把 ftrace 的全部开关与输出暴露成普通文件：`cat` 读状态、`echo` 改配置——「一切皆文件」落在仪器上的样子。
> **为什么存在**：配置内核跟踪器不需要新命令、新 API，`echo`/`cat`/`grep` 就是完整操作界面，脚本天然可组合。
> **类比（你的主场）**：像网络设备把管理面暴露成 SNMP/REST 对象树——每个对象可读可写、语义固定。
> ⚠️ 类比边界：写这些「文件」不是存数据，而是立即触发内核动作；`cat trace` 拿到的只是当下缓冲区的一份快照。

> 📖 **术语卡：ftrace 的 function_graph**
> **是什么**：ftrace 的一种 tracer（跟踪模式）：把函数调用渲染成带耗时的缩进树——函数进入打 `{`，退出打 `} /* 3.5 us */`。
> **为什么存在**：想知道「一次操作在内核里经过了谁、谁最慢」，日志做不到，必须内核自埋点。
> **类比**：perf 的调用链火焰图——但这是内核视角、函数级、每箭头带微秒。
> ⚠️ 类比边界：火焰图是采样统计（抓典型），function_graph 是全量实录（每次都记，所以更慢也更准）。

function_graph tracer 会在目标函数入口/出口画框并计时，是「看穿 syscall 边界」的正牌仪器。
tracefs 在 Bookworm（Raspberry Pi OS 当前大版本代号，Debian 12 基）通常已挂载，不在就手动挂：

```bash
TRC=/sys/kernel/tracing
ls $TRC >/dev/null 2>&1 || sudo mount -t tracefs none $TRC

# ① 确认仪器与靶子都存在（available_filter_functions 是权威清单）
cat $TRC/available_tracers                       # 应含 function_graph
grep -E 'bcm2835_spi|spidev_sync' $TRC/available_filter_functions

# ② 配置：graph tracer + 只追 bcm2835 的传输函数（一行一个函数，glob 也支持，待实测）
sudo sh -c "echo function_graph > $TRC/current_tracer"
sudo sh -c "echo bcm2835_spi_transfer_one >> $TRC/set_graph_function"
sudo sh -c "echo bcm2835_spi_transfer_one_poll >> $TRC/set_graph_function"

# ③ 清场 → 开闸 → 一发 → 关闸（窗口越小，trace 越干净）
sudo sh -c "echo 0 > $TRC/tracing_on; echo > $TRC/trace"
sudo sh -c "echo 1 > $TRC/tracing_on"
sudo ./spiloop 1000000
sudo sh -c "echo 0 > $TRC/tracing_on"

sudo cat $TRC/trace | head -50
```

**命令拆解：** 挂载与清点（开头 3 行）

| 部分                                                                 | 作用                                                                                                                                                            |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TRC=/sys/kernel/tracing`                                            | 把长路径存进 shell 变量，后续一律用 `$TRC` 代称                                                                                                                 |
| `ls $TRC \|\| sudo mount -t tracefs none $TRC`                       | `\|\|` = 前一条失败才做后一条：目录没挂就手动挂；`-t tracefs` 指定文件系统类型，`none` 是伪文件系统惯用的占位「设备名」                                         |
| `cat $TRC/available_tracers`                                         | 列出本内核支持的 tracer 清单，应含 `function_graph`                                                                                                             |
| `grep -E 'bcm2835_spi\|spidev_sync' $TRC/available_filter_functions` | `available_filter_functions` 是本内核 ftrace 能「看见」的函数全集（权威清单：没被内联、没被裁剪、带入口桩）；`\|` 在扩展正则里表示「或」，此处筛出 SPI 相关函数 |

**你会看到**：第一行是空格分隔的 tracer 名单；第二行起是 `bcm2835_spi_transfer_one` 这类函数名，一行一个。
**失败了先查**：`available_tracers` 里没有 `function_graph`（内核裁掉了跟踪支持）；grep 无输出（函数没编进内核，或已被 inline 吞掉）。

**命令拆解：** 配置 tracer 与靶函数（② 段三行 echo）

| 部分                                                     | 作用                                                                                               |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `sudo sh -c "echo function_graph > $TRC/current_tracer"` | `current_tracer` 是「当前用哪种 tracer」的选择开关，写入即切换仪器                                 |
| `echo ... >> $TRC/set_graph_function`                    | `set_graph_function` 是降噪闸门：只对列出的函数（及其调用的子函数）画图；`>>` 追加写，一行一个函数 |
| 两个 `bcm2835_spi_transfer_one*`                         | 分发者与 poll 实现各占一行；想看整条链再补 `spidev_*`、`__spi_*`，先窄后宽                         |

**你会看到**：echo 无任何输出——Unix 惯例「沉默即成功」，配置是否生效要看下一步的 trace。
**失败了先查**：为什么必须 `sudo sh -c "..."`——单纯 `sudo echo x > file` 时，重定向仍由普通用户身份的 shell 执行，会报 Permission denied；`sh -c` 把整条重定向都圈进 root 的 shell 里。

**命令拆解：** 清场 → 开闸 → 一发 → 关闸 → 读出（③ 段）

| 部分                                          | 作用                                                                            |
| --------------------------------------------- | ------------------------------------------------------------------------------- |
| `echo 0 > $TRC/tracing_on; echo > $TRC/trace` | `tracing_on` 是记录总闸（0 关 / 1 开）；`echo > trace` 清空输出缓冲区——两步清场 |
| `echo 1 > $TRC/tracing_on`                    | 开闸：内核从此持续记录函数事件                                                  |
| `sudo ./spiloop 1000000`                      | 被跟踪的「一发」——窗口越小，trace 缓冲区越干净                                  |
| `echo 0 > $TRC/tracing_on`                    | 关闸止血，缓冲区内容定格待读                                                    |
| `sudo cat $TRC/trace \| head -50`             | 读出全局缓冲区，只看前 50 行                                                    |

**你会看到**：缩进的函数树，形如 `bcm2835_spi_transfer_one() {` … `} /* x.xxx us */`（完整形态见下方「预期输出（待实测核销）」）。
**失败了先查**：`trace` 文件只有表头没有函数体——靶函数没写进 `set_graph_function`，或 `tracing_on` 忘了置 1。

rpi-6.6.y 的 spi-bcm2835.c 里实际存在（已核对）的候选函数：`bcm2835_spi_transfer_one`（分发
者）与 `bcm2835_spi_transfer_one_poll` / `_irq` / `_dma`（poll：CPU 忙等盯着硬件；irq：靠中断
通知完成；dma：Direct Memory Access，由 DMA 控制器替 CPU 搬数据）三种实现，另有
`bcm2835_spi_prepare_message`（每条消息开始前的硬件准备函数）、`bcm2835_spi_interrupt`（SPI 的
中断服务例程：硬件搬完一块数据后回调它）。4 字节短传输出于**哪种实现**是本章的
预埋学习点（见第 4 节 L3 的中断悖论），实测时把三种都挂上 graph。

两个 ftrace 的诚实预告：

1. **inline 函数不上镜**。寄存器读写封装在 `static inline` 的 `bcm2835_wr/bcm2835_rd` 里，
   编译期内联进 `transfer_one` 帧——graph 里**看不到**独立的「写寄存器」节点。这不是仪器的
   盲区，是它的工作方式：L2 到函数粒度为止，寄存器层的证据去 L3/L4 拿。
2. 想看整条链（从 `spidev_ioctl`（spidev 驱动的 ioctl 入口函数）一路到驱动），把 `spidev_*`、
   `__spi_*` 也加进 set_graph_function——函数越少 trace 越干净，建议先窄后宽。

> 📖 **术语卡：inline 函数（内联函数）**
> **是什么**：标了 `static inline` 的小函数，编译器把它的代码「原地展开」复制进调用者体内——最终机器码里根本不存在这次调用，只剩一串揉进去的指令。
> **为什么存在**：省掉函数调用的固定开销（压栈、跳转、返回），热路径上的寄存器读写包装函数（`bcm2835_wr/rd`）都这么写。
> **类比**：像把被调函数当宏一样原地展开——源码里是调用，二进制里是一体。
> ⚠️ 类比边界：这不是修得好的仪器盲区——函数入口在二进制里不存在了，任何靠「函数入口打桩」的跟踪器（ftrace、kprobe 同理）天然看不见它，证据只能去 L3/L4 层拿。

## 4. L3 与 L4：硬件痕迹与物理字节

> 📖 **术语卡：/proc/iomem 与 /proc/interrupts**
> **是什么**：`/proc` 是内核导出状态的伪文件系统，这两个文件是其中的「房契表」与「计数器墙」：`iomem` 列出每段物理地址区间被哪个驱动持有；`interrupts` 列出每个中断源在各 CPU 上触发过的次数。
> **为什么存在**：零侵入地回答「这块地址是谁的」「中断到底来没来」——不停机、不打断执行流，是 openocd `mdw` 活体读的内核版。
> **类比（你的主场）**：`interrupts` 就是内核版的 `ip -s link` 收发计数器——只增不减，必须拍前后两张快照看差值才有意义。
> ⚠️ 类比边界：链路计数器有细分的错误/丢包语义，中断计数只说「来了几次」；谁触发的，要靠行首名字对号入座。

L3 的三件痕迹（都来自 /proc，零侵入——「活体读」的内核版）：

```bash
grep -i '204000' /proc/iomem                              # fe204000 段的持有者（spi-bcm2835 的房契）
grep -iE 'spi|bcm' /proc/interrupts > /tmp/i0             # 传输前
sudo ./spiloop 1000000
grep -iE 'spi|bcm' /proc/interrupts > /tmp/i1
diff /tmp/i0 /tmp/i1                                      # 中断计数变化（若有）
```

**命令拆解：** L3 取证三步

| 部分                                             | 作用                                                                                                                                 |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `grep -i '204000' /proc/iomem`                   | `-i` 忽略大小写；在房契表里找 `fe204000` 段——BCM2711 的 SPI0 寄存器区（外设基址 0xfe000000 + 偏移 0x204000），持有人应写 spi-bcm2835 |
| `grep -iE 'spi\|bcm' /proc/interrupts > /tmp/i0` | 传输前拍快照：筛出 SPI 相关中断行，存临时文件                                                                                        |
| `sudo ./spiloop 1000000`                         | 制造一次传输                                                                                                                         |
| `grep ... > /tmp/i1` + `diff /tmp/i0 /tmp/i1`    | 传输后再拍一张，逐行比对——哪行计数涨了，哪条中断路径就在干活                                                                         |

**你会看到**：iomem 一行形如 `fe204000-fe2040ff : ...spi`（形态待实测）；diff 或为空（见下方中断悖论，空也是证据）。
**失败了先查**：`/proc/iomem` 里的地址全显示成 `00000000`——非 root 读取会被内核清零，加 `sudo` 再读。

**预埋的中断悖论**：4 字节短传输出于 `transfer_one_poll` 的概率很大（阈值与条件以 6.6 实测
为准）——poll 实现是**同步忙等 FIFO**（忙等 busy-wait：CPU 原地循环查状态位直到完成；FIFO：
first-in-first-out 硬件字节队列，待发字节排队出去、已收字节排队进来），一次传输可能**一次中断都不产生**。若 diff 为空，别以为
失败：这正是裸机轮询的内核版现身（对照
[[ch02-button-polling-to-interrupt|F429 ch02]] 轮询→中断的同一取舍，发生在
Linux 驱动内部）。挂大传输（如 4096 字节）再 diff，若计数跳变，就是驱动换到了 `_irq`/`_dma`
路径的证据。

L4 的物证两件：spiloop 打出的 `rx: a5 5a 00 ff`（回环字节本身）；以及
[[ch08-instrument-roles-guide|ch08]] 的 piscope（树莓派上的软件逻辑分析仪：
pigpiod 守护进程高速采样 GPIO 电平，piscope 把采样渲染成波形图）抓 SCLK（SPI 时钟线：每来
一拍，数据线上移入/移出一个位）——1MHz 下应看到
4 字节 = 32 个时钟周期、每个 1µs 的突发波形。

## 5. 产出：四层证据链表（存档件）

| 层  | 证据（形态，待实测核销）                                                                     | 抓取命令          |
| --- | -------------------------------------------------------------------------------------------- | ----------------- |
| L1  | `ioctl(3, SPI_IOC_MESSAGE(1), {...}) = 4 <0.0001xx>`（或路径 A 的 `read(...) = 1`）          | strace -T         |
| L2  | function_graph 段：`spidev_sync → … → bcm2835_spi_transfer_one { … }`（时长列）              | tracefs cat trace |
| L3  | `/proc/iomem` 的 `fe204000…` 持有行；`/proc/interrupts` 计数增量（或「零中断」这一事实本身） | grep /proc        |
| L4  | `rx: a5 5a 00 ff` 回环一致；piscope 上 32 个 SCK 周期的突发                                  | spiloop / piscope |

## 预期输出（待实测核销）

```text
$ sudo strace -T -e trace=read,ioctl -s 32 ./spiloop 1000000 2>&1 | grep -E 'SPI_IOC|read\('
ioctl(3, SPI_IOC_MESSAGE(1), 0x...) = 4 <0.000xxx>       # 时长与缓冲区形态以实测为准

$ sudo cat /sys/kernel/tracing/trace | grep -A4 bcm2835_spi
 ...   |   bcm2835_spi_transfer_one() {
 ...   |     bcm2835_spi_transfer_one_poll() {
 ...   |       /* 帧内：CS 拉低、写 FIFO、忙等、CS 拉高（inline 访问不可见） */
 ...   |     }   /* x.xxx us */
 ...   |   }   /* x.xxx us */
                                                # 层级缩进、CPU 列、时长值均为形态示意

$ sudo ./spiloop 1000000
tx: a5 5a 00 ff @ 1000000 Hz
rx: a5 5a 00 ff
LOOPBACK OK
```

## 与 F429/裸机对照：四层方法论的合流

[[2026-08-30-stm32f429-clock-misconfig-postmortem|F429 故障复盘]] 定下的方法论——分层判尸、证据比
灵感先到——在两个世界是同一张骨架，只是每层的仪器不同：

| 环节      | F429 裸机                      | Linux（本章）                              |
| --------- | ------------------------------ | ------------------------------------------ |
| L1 入口   | 没有边界；main 直接调驱动函数  | syscall 边界，strace 全量记账              |
| L2 内部   | openocd 断点二分定位卡死帧     | ftrace function_graph 无断点看穿调用链     |
| L3 寄存器 | `mdw` 活体读（零侵入，不停机） | `/proc/iomem`、`/proc/interrupts` 活体读   |
| L4 物理   | 串口字节 + LA/ piscope 波形    | 同款：回环字节 + piscope 波形（ch08）      |
| 判尸纪律  | 「读出的值对复位值验」         | 「证据链每层各留一行，缺层结论降级为推测」 |

最值得带走的对称性：**openocd `mdw`（memory display word：openocd 里经 SWD 调试总线直接读
目标内存/寄存器的命令）之于裸机，就是 /proc 与 ftrace 之于 Linux**——都是
「不打断执行流、直接读出系统内部状态」的仪器。裸机靠调试私有总线，Linux 靠内核自带的
observability（可观测性）接口；后者不需要额外硬件，代价是这些接口本身就是「官僚体系」的一部分（
tracefs 要 root、available_filter_functions 限定了可见函数集）。

至此 R1–R5 主线收束：ch02 特权墙、ch03 过路费、ch04 函数指针表、ch05 中断监狱、ch06 描述与
驱动分离——每层官僚体系都回答了「它在解决裸机的什么问题」，而本章把五层串成了一次 4 字节
传输的完整旅程。剩下的 [[ch08-instrument-roles-guide|ch08]] 换身份：从解剖
标本变回仪器，去服务 F429/WiFi/BOX-3 系列。

## 待核对清单

- `available_filter_functions` 里 bcm2835*spi*\* / spidev\_\* 的确切集合（决定 graph 挂哪些函数）
- 4 字节 @1MHz 传输实际走 poll/irq/dma 哪条路径（决定「中断悖论」的验证结果）
- `set_graph_function` 是否接受通配符（`echo 'bcm2835_spi*'`）与多函数逐行写法的行为
- tracefs 在 Bookworm 的默认挂载点与权限（/sys/kernel/tracing vs /sys/kernel/debug/tracing）
- spidev `read()` 在回环态读到的字节（预期 0x00；TX 侧填充行为以源码/实测为准）
- strace 下 SPI_IOC_MESSAGE 的缓冲区回显形态（-s 32 是否够显示 transfer 结构）
- 4096 字节大传输时 `/proc/interrupts` 计数与 dmesg 的 DMA 相关行为（spi_dma4 dtparam 默认值）
