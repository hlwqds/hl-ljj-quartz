---
title: STM32F429 挑战者首烧即砖：救板全程与四层 Bug 剥洋葱实录
date: 2026-08-30 01:30:00
description: 野火挑战者 F429-V2 第一次烧录就把调试口写死了——BOOT0 跳线救砖全程 + VOS/晶振/向量表/构建依赖四层根因复盘
tags: [STM32, FreeRTOS, Debug, Hardware]
---

# STM32F429 挑战者首烧即砖：救板全程与四层 Bug 剥洋葱实录

## 本章装备清单

| 分类 | 装备                    | 价格/状态 | 用途                     |
| ---- | ----------------------- | --------- | ------------------------ |
| 已有 | 挑战者 F429-V2 板       | ✅        | 实验主体（本章救板对象） |
| 已有 | 野火 DAP 仿真器         | ✅        | 烧录/调试                |
| 已有 | Mini-USB 线             | ✅        | 供电 + 串口              |
| 已有 | 笔记本（Fedora 工具链） | ✅        | 运行 openocd/烧录工具    |

## 本章会遇到的词

| 词                    | 一句话版                                              | 详见       |
| --------------------- | ----------------------------------------------------- | ---------- |
| SWD / JTAG            | 电脑指挥芯片的调试接线协议：SWD 两线，JTAG 四线       | 第 1 节    |
| DAP / DP / AP         | 芯片内调试访问链：DP 管协议握手，AP 翻译成总线读写    | 第 1 节    |
| DPIDR / CPUID         | 两层"身份证"寄存器：前者在调试口，后者在 CPU 内部     | 第 1 节    |
| BOOT0 / ISP           | 启动选择引脚 / 串口在线下载模式（ROM 里的出厂烧录器） | 第 2 节    |
| 跳线帽 / 丝印         | 连通两根排针的小黑帽 / 板面白色印刷标注               | 第 2 节    |
| HSE / PLL / VCO       | 外部晶振 / 锁相环倍频器 / 芯片内高频振荡器            | 第 3.2 节  |
| VOS                   | 内核电压档位（Scale1/2/3），高频必须配高压档          | 第 3.1 节  |
| 8E1 / 8N1             | 串口帧格式：数据位+校验位+停止位的两种组合            | 第 3.3 节  |
| NRST                  | 芯片复位引脚，低电平 = 按住复位不放                   | 第 3.3 节  |
| 向量表 / 弱符号       | 「中断号→处理函数地址」查找表 / 可被覆盖的默认函数桩  | 第 3.4 节  |
| SysTick / BRR         | 内核节拍定时器 / 串口波特率寄存器                     | 第 4 节    |
| openocd / stm32loader | SWD 调试器软件 / 串口 ISP 烧录工具                    | 第 2、3 节 |

## TL;DR

给野火挑战者 STM32F429-V2 烧了一个手写时钟初始化的 Vanilla FreeRTOS 固件，`Verified OK` 之后芯片当场"死机"——SWD 无法访问 CPU。最后确认这不是一个 bug，而是**四层 bug 叠罗汉**，外加两个环境陷阱：

| #        | 根因                                         | 一句话原理                                     |
| -------- | -------------------------------------------- | ---------------------------------------------- |
| 1        | VOS 写成 `3<<14`（Scale3=复位值）            | 180MHz 跑在最低电压档，欠压失控，调试口陪葬    |
| 2        | 晶振按 8MHz 配 `PLL_M=8`，板载实为 **25MHz** | VCO 输入超规格，PLLRDY 永不置位，死循环        |
| 3        | FreeRTOS 三个中断入口没接进向量表            | 调度器第一条 `svc` 掉进 Default_Handler 死循环 |
| 4        | Makefile 无头文件依赖                        | 修好的代码根本没编译进去，烧的是旧固件         |
| 环境坑 a | stm32loader 以 8E1 偶校验退出                | 校验位残留 tty，正常固件听起来像乱码           |
| 环境坑 b | openocd 会话被 timeout 杀死                  | NRST 留在按住态，寄存器读出全 0                |

救板通道：**J64 跳线帽拉高 BOOT0 → 断电重上电 → stm32loader 串口擦除 → 帽回 GND**。全程约 3 分钟，已沉淀为可复用技能。

---

## 0. 背景

《FreeRTOS 深度解析》系列是在 ESP32（乐鑫 IDF 生态）上写的。为了做**端口层对照实验**（Xtensa ↔ Cortex-M、IDF 集成版 ↔ Vanilla 原版），我在野火挑战者 F429-V2 上搭了一个零拷贝工程 `~/stm32/f429-freertos`：寄存器级手写 `clock_init()`（HSE→PLL→180MHz）+ 寄存器级 UART + 上游 FreeRTOS-Kernel 的 CM4F 端口。（词注：Xtensa 与 Cortex-M 是两种 CPU 架构——乐鑫自研 vs ARM 内核；Vanilla 指"原版未修改的上游 FreeRTOS"；"寄存器级"指不用库函数、直接向芯片内一个个有地址的 32 位小格子（寄存器）写值下命令、读值看状态；HSE→PLL→180MHz 意为"外部晶振 HSE 经锁相环 PLL 倍频到 180MHz 主频"；UART 是芯片上最基础的串口外设；CM4F = Cortex-M4F（带单精度浮点单元的 ARM 内核），"端口"指 FreeRTOS 为该内核写的汇编移植层。）

固件本身极简：两个任务，fast 每 200ms 打印 tick，slow 每 1000ms 打印 hello。

## 1. 案发现场：Verified OK，但芯片"死了"

```text
** Programming Started **
** Programming Finished **
** Verified OK **
** Resetting Target **
```

烧录校验全绿。但随后的表现：

- 串口（板载 CH340 → /dev/ttyUSB0）无任何输出（CH340：板载的 USB 转 UART 桥接芯片，把芯片串口变成电脑里的 /dev/ttyUSBx——tty 设备这层是你的主场）
- `openocd halt` 超时；读 CPUID 报 `Cortex-M PARTNO 0x0 is unrecognized`（openocd：开源片上调试器软件，电脑这端的指挥官；halt = 命令 CPU 停下；CPUID：CPU 内核的身份证寄存器，读到 0x0 表示"隔着调试链根本够不到 CPU 本体"）
- 而 SWD 的 DPIDR、JTAG 两个 TAP（`0x4ba00477` CPU + `0x06419041` 边界扫描）**仍然活着**，能正确认出这是 ST 的 F429（SWD：两线串行调试口；DPIDR：调试端口的身份寄存器；JTAG：四线老牌调试口；TAP：JTAG 链上的测试访问口，一个可测单元占一个；边界扫描是 JTAG 的逐引脚观测功能）

### 这个症状组合说明了什么

这是本次学到的第一个架构知识点，**STM32 的调试链路是分层的**：

```text
上位机 → DAP仿真器 → DP（调试端口，管协议握手） → AP（访问端口） → 芯片总线 → CPU/外设寄存器
                                ↑ DPIDR 在这层活着        ↑ CPUID 在这层死了
```

> 📖 **术语卡：调试链（SWD/JTAG → DAP 的 DP/AP）**
> **是什么**：SWD（Serial Wire Debug，两线串行调试口）与 JTAG（四线老牌调试口）是电脑指挥芯片的接线协议；信号进芯片后交给 DAP（Debug Access Port，调试访问端口）——它分两级：DP（Debug Port，调试端口，管协议握手与身份登记）和 AP（Access Port，访问端口，把调试请求翻译成对芯片总线的读写）。
> **为什么存在**：调试通路必须独立于 CPU——CPU 崩了也得够得着芯片，所以 ARM 把它做成旁路硬件。
> **类比**：DP 是大楼门卫（验明身份、开门），AP 是楼内电梯（载你直达任意楼层的内存地址）。
> ⚠️ 类比边界：门卫+电梯靠人跑腿，DP/AP 是纯硬件转发；另注意上图"DAP 仿真器"指电脑侧的调试小盒（CMSIS-DAP 探针），与芯片内的 DAP 同名不同物，别混。

DPIDR 能读、CPUID 读 0 = **传输层没坏，是芯片内部状态坏了**。而烧录（Programming/Verify）走的是完全独立的 flash 控制器路径，所以"烧录成功"和"固件能跑"根本是两件事——**Verified OK 只证明 flash 里的字节对了，不证明这些字节执行起来不死**。

结论：固件在上电后的头几毫秒内把芯片带进了某种致命状态。要恢复，必须让芯片**不执行 flash 里的代码**。

## 2. 救板：从「找不到 BOOT0」到 ISP 擦除

### 2.1 为什么只能走 UART ISP

STM32 的启动模式由复位瞬间 BOOT0/BOOT1 引脚电平决定（BOOT0/BOOT1：启动选择引脚，只在复位那一瞬间被采样一次，之后电平随便变）：

| BOOT0 | BOOT1 | 启动区                            | 用途          |
| ----- | ----- | --------------------------------- | ------------- |
| 0     | X     | 片内 Flash                        | 正常运行      |
| 1     | 0     | 系统存储器（ROM 里的 bootloader） | 串口 ISP 下载 |
| 1     | 1     | 内置 SRAM                         | 调试用        |

bootloader 是 ST 出厂烧死在 ROM 里的（ROM：Read-Only Memory，只读存储器，出厂固化、用户改不动），**不依赖 flash 里任何字节**。只要 BOOT0=1 复位，芯片就进 ISP 模式，通过 USART1 收命令——包括全片擦除。这是固件把 SWD 写死时唯一不需要调试口的恢复通道。

> 📖 **术语卡：BOOT0 与 ISP（In-System Programming，串口在线下载）**
> **是什么**：BOOT0 为 1 时从"系统存储器"启动——ST 出厂固化在 ROM 里的 bootloader（引导程序），它监听 USART1（芯片的 1 号串口外设，本板经 CH340 接到 USB）并接受读/写/擦除 flash 的命令，这就是 ISP：不取下芯片、不经调试口直接烧录。
> **为什么存在**：给芯片留一条不依赖用户代码、也不依赖调试口的保底烧录通道。
> **类比**：服务器主板的 BIOS/UEFI——系统盘里的引导代码再烂，BIOS 在独立 ROM 里照常工作，还能从别的口救系统。
> ⚠️ 类比边界：进 BIOS 靠开机按键，BOOT0 靠复位瞬间的引脚电平；改跳帽后必须断电重新上电才算数。

（另一条理论通道：openocd 连接时按住复位 `connect_assert_srst` 抢在固件跑之前接管——但本板固件在时钟初始化早期就出事，这条路反复尝试无效。）

### 2.2 J64 寻踪记：官方文档里查无此号

讽刺的部分来了：这块板**没有自动 ISP 电路**，KEY1/KEY2 都不是 BOOT 键，必须靠跳线帽手工把 BOOT0 拉到 3.3V（跳线帽 / jumper：套在两根排针上把它们连通的小黑帽）。而 BOOT 跳线在哪？

- 官方《底板介绍》文档列了 V2 全部跳线帽：J40（CAN/485 电源）、J66（WiFi 电源）、J69/J70、J73、J74-76、J77、J80/J81……**没有 BOOT 的位置记载**（CAN/RS-485：两种工业界常用的串行总线）
- FAQ 只说操作："把 BOOT0 用跳帽跳到 3.3V 后，板子断电重新上电"——默认你能找到它

最后是把官方整板标注图下载下来裁剪放大，读出了跳线组旁边的丝印：**`J64`，旁边印着 `3V3 / BOOT0 / BOOT1`**（丝印：电路板表面的白色印刷标注）。位置在板左侧中部跳线簇（Mini-USB 和 CH340 上方、J41/J40 下方）。

> 教训：**丝印是最后的事实来源**。文档没写的，板上一定印了；照片放大 + 视觉模型读丝印是可行的定位手段。

### 2.3 擦除与复活

```bash
# 权限（每次重新上电后 ACL 会丢）
sudo setfacl -m u:huanglin:rw /dev/ttyUSB0

# 帽移到 3V3—BOOT0，断电重上电后：
$ python3 -m stm32loader -p /dev/ttyUSB0 -b 115200 -e
Bootloader version: 0x31
Chip id: 0x419 (STM32F42xxx and STM32F43xxx)   ← 正是 F429
Extended erase (0x44), this can take ten seconds or more

# 回读验证全 FF（空白）：
$ python3 -m stm32loader -p /dev/ttyUSB0 -b 115200 -f F4 \
    -r -a 0x08000000 -l 64 /tmp/readback.bin
$ xxd /tmp/readback.bin
00000000: ffff ffff ffff ffff ...   ← 全 FF，擦干净了
```

**命令拆解：** `python3 -m stm32loader -p /dev/ttyUSB0 -b 115200 -e`（及回读变体）

| 部分                              | 作用                                                                      |
| --------------------------------- | ------------------------------------------------------------------------- |
| `python3 -m stm32loader`          | 以模块方式运行 stm32loader：开源串口烧录工具，说 ST ROM bootloader 的协议 |
| `-p /dev/ttyUSB0`                 | 走哪个串口（经板载 CH340 桥出的 USB 串口）                                |
| `-b 115200`                       | 波特率：串口双方约定的传输速率（码元/秒）                                 |
| `-e`                              | 全片擦除——救砖核心一步，把 flash 全写成 0xFF                              |
| `-f F4`                           | 声明目标芯片系列，工具据此选对命令与地址布局                              |
| `-r -a 0x08000000 -l 64`          | 从 0x08000000（Flash 基址）回读 64 字节存成文件，验证"确实空了"           |
| `xxd <file>`                      | 十六进制转储（你的主场）；全 FF = 擦干净                                  |
| `sudo setfacl -m u:huanglin:rw …` | 你的主场：Linux ACL 授权读写 tty；板子重新上电后权限会丢，要重做          |

**你会看到**：`Bootloader version: 0x31`、`Chip id: 0x419`（0x419 = ST 内部编号，正对 F42x/F43x 系列）。
**失败了先查**：跳帽是否真在 3V3–BOOT0 且**断电重新上过电**（ISP 只在复位瞬间生效）；`ls -l /dev/ttyUSB0` 看权限；本板 USART1↔CH340 需要 J80/J81 跳帽在位。

帽移回 GND、重新上电，`make probe` 立刻满血：

```text
Info : [stm32f4x.cpu] Cortex-M4 r0p1 processor detected   ← 之前这里报 PARTNO 0x0
Info : [stm32f4x.cpu] target has 6 breakpoints, 4 watchpoints
```

**SWD 复活。** 从确认砖机到救回，扣掉找跳线的时间，实际操作 3 分钟。

## 3. 剥洋葱：四层 Bug

flash 擦空后，开始修代码。过程不是一次到位，而是每修一层、烧一次、暴露下一层——像剥洋葱。

### 3.1 第一层：VOS 电压档编码记反

原代码：

```c
PWR->CR |= (3u << 14);                 /* VOS[15:14] = 11 = Scale 1 */  ← 注释自信，内容错误
```

F42x 的 VOS 编码：`01`=Scale1（≤180MHz）、`10`=Scale2（≤144MHz）、`11`=Scale3（**复位默认值**）。所以 `|= (3u<<14)` 是把寄存器写回它本来的值——**一行 no-op**。芯片留在 Scale3 的电压档，却被切到 180MHz 主频。（no-op：空操作——这行赋值等于什么都没改）

> 📖 **术语卡：VOS（Voltage Scale，内核电压档）**
> **是什么**：电源外设 PWR 的控制寄存器 PWR->CR 里 bit[15:14] 两位，选内核供电档位：`01`=Scale1（配 ≤180MHz）、`10`=Scale2（≤144MHz）、`11`=Scale3（最低，复位默认）。
> **为什么存在**：电压低省电但电路翻转慢——主频和电压档是一对必须匹配的参数，规格书里成对给边界。
> **类比**：CPU 超频要加电压（原文正是这个类比）；也像手机的省电/性能模式切换。
> ⚠️ 类比边界：PC 超压失败会蓝屏重启，这边欠压是时序随机违约——静默、不可复现、还可能把调试口一起带死。

用系统侧的话说：**给 CPU 超频却没加电压**。后果不是"变慢"，而是欠压下数字逻辑时序违约，行为完全不可预测——包括把调试端口带进死状态。（时序违约：数字电路每一级门都有传播延迟，电压不够延迟变大，规定一个时钟周期内该完成的翻转完不成）

修复（用 CMSIS 宏，不手搓魔数）（CMSIS：ARM 官方芯片支持包，把每个寄存器位域定义成有名字的宏，如 PWR_CR_VOS_0；"手搓魔数"指直接写 `3u<<14` 这类来历不明的常数）：

```c
PWR->CR = (PWR->CR & ~PWR_CR_VOS) | PWR_CR_VOS_0;   /* VOS = 01 = Scale 1 */
```

### 3.2 第二层：晶振不是 8MHz

修完 VOS 烧录，串口出乱码——有戏，但没到终点。用断点定位卡点：

```bash
# 复位停在入口 → 在 uart_init（clock_init 之后）下硬件断点 → 放行
openocd -c "init; reset halt; bp 0x08001780 2 hw; resume; sleep 1500; halt; reg pc"
# 结果 PC 停在 0x08001a6e，反汇编对照：
8001a6a:  ldr  r3, ...      ← 读 RCC->CR
8001a72:  cmp  r3, #0
8001a74:  beq  8001a6a      ← 死循环：等 PLLRDY（bit25）
```

**命令拆解：** `openocd -c "init; reset halt; bp 0x08001780 2 hw; resume; sleep 1500; halt; reg pc"`

| 部分                 | 作用                                                                                          |
| -------------------- | --------------------------------------------------------------------------------------------- |
| `openocd`            | 开源片上调试器：电脑这端、经 DAP 仿真器指挥芯片的软件                                         |
| `-c "…"`             | 把引号内的命令序列喂给 openocd 执行后退出                                                     |
| `init`               | 建立与仿真器、芯片的连接                                                                      |
| `reset halt`         | 复位并停在复位后第一条指令——从已知状态出发                                                    |
| `bp 0x08001780 2 hw` | 在 uart_init 入口下 2 字节**硬件断点**（芯片 FPB 断点单元执行，本芯 6 个，不改动 flash 内容） |
| `resume` / `halt`    | 放行全速跑 / 按停                                                                             |
| `sleep 1500`         | 等 1.5 秒，让固件跑到卡死点                                                                   |
| `reg pc`             | 读程序计数器 PC = CPU 下一条要执行的指令地址                                                  |

**你会看到**：`pc: 0x08001a6e`；对照反汇编（把机器码译回汇编指令）三连：`ldr`（把 RCC->CR 载入寄存器 r3）→ `cmp r3,#0`（与 0 比较）→ `beq`（相等就跳回循环头）——典型的"死等硬件标志位"循环。
**失败了先查**：断点地址必须来自**当前这次构建**的符号表（`nm` 查 uart_init，代码一改地址就变）；DAP 线与供电；有无残留 openocd 进程占着仿真器。

PLLRDY 永不置位 = PLL 拒绝锁定。（RCC：Reset and Clock Control，STM32 的时钟控制寄存器组，RCC->CR 是它的控制寄存器；PLLRDY 是其中 bit25，硬件置 1 表示"PLL 已稳定锁定"）查野火官方 HAL 教程第 15 章，白纸黑字：

> "HSE 我们使用 **25M** 的无源晶振" …… `HSE_SetSysClock(25, 360, 2, 7)` → 180M

我按 Nucleo 板的惯性写了 `PLL_M=8`：VCO 输入 = 25M/8 = 3.125MHz（合法域 1–2MHz），VCO 输出 1125MHz（合法域 192–432MHz）——**双重超规格，PLL 硬件拒绝锁定**。（Nucleo：ST 官方入门开发板系列，默认 HSE 按 8MHz 设计——"惯性"正是从这来的）

> 📖 **术语卡：HSE、PLL、VCO 与 PLLRDY**
> **是什么**：HSE（High-Speed External，外部高速晶振，本板 25MHz）是基准节拍；PLL（Phase-Locked Loop，锁相环）是倍频合成器：先 ÷M 得 VCO 输入频率，VCO（Voltage-Controlled Oscillator，压控振荡器，芯片内高频振荡电路）×N 得高频，再 ÷P 供给系统。PLLRDY 是 RCC->CR 的 bit25，硬件置 1 = PLL 已稳定锁定。
> **为什么存在**：晶振只能给一个稳定但固定的频率，任意主频要靠 PLL 现场合成。
> **类比**：HSE 是钟摆，PLL 是带变速箱的机芯——输入一个稳节拍，输出你要的任意转速。
> ⚠️ 类比边界：齿轮箱怎么配都能转，PLL 的 M/N/P 有硬性合法区间（VCO 输入 1–2MHz、输出 192–432MHz），越界直接拒绝锁定。

这层的教学价值：**"能编译"的时钟配置和"能锁定"的时钟配置之间隔着一本 reference manual**（reference manual：芯片参考手册，逐寄存器逐位给规格）。移植代码第一件事是查目标板的晶振频率，第二件事是把 PLL 参数对着合法域逐项验算：

```text
VCO输入 = HSE / M      必须落在 1–2 MHz        （25M/25 = 1M ✓）
VCO输出 = VCO输入 × N  必须落在 192–432 MHz    （1M×360 = 360M ✓）
SYSCLK  = VCO输出 / P  ≤ 180 MHz               （360/2 = 180M ✓）
```

### 3.3 插曲：两个环境陷阱（差点把方向带偏）

修完晶振，症状变成"烧完有一坨结构化乱码，之后完全静默"。这两条红鲱鱼值得单独记（红鲱鱼 / red herring：把调查引向歧途的假线索）：

**乱码 = stm32loader 的 8E1 校验残留。** ST 的 ROM bootloader 串口协议默认 8 数据位+偶校验（8E1），stm32loader 照此配置了 ttyUSB0。它退出后**校验位设置残留在设备上**。我之后所有 `stty 115200 raw -echo` 都没清校验位——用 8E1 的耳朵听 8N1 的数据，每个字节错位一格，正是那种"有重复模式的结构化乱码"。**固件可能一直是好的，是听的人聋了。**

```bash
# 正确的完整参数（已做成 make serial）：
stty -F /dev/ttyUSB0 115200 raw -echo -parenb -parodd -cmspar \
     cs8 -cstopb -crtscts -ixon -ixoff clocal cread
```

**命令拆解：** `stty -F /dev/ttyUSB0 115200 raw -echo -parenb -parodd -cmspar cs8 -cstopb -crtscts -ixon -ixoff clocal cread`（串口参数本质是 tty 配置——你的主场，这里补全旗标注释）

| 部分              | 作用                                                            |
| ----------------- | --------------------------------------------------------------- |
| `-F <设备>`       | 指定作用的 tty 设备（不指定则作用到标准输入）                   |
| `115200`          | 波特率                                                          |
| `raw`             | 原始模式：不做行缓冲、不解释特殊字符                            |
| `-echo`           | 关回显                                                          |
| `-parenb`         | **关掉校验位**——本次乱码元凶：stm32loader 留下的 8E1 偶校验没清 |
| `-parodd -cmspar` | 顺带关干净奇校验与 mark/space 校验模式                          |
| `cs8 -cstopb`     | 8 数据位 + 1 停止位（合计即标准 8N1 帧）                        |
| `-crtscts`        | 关硬件流控（RTS/CTS 信号线）                                    |
| `-ixon -ixoff`    | 关软件流控（防流控字符被当成数据吞掉）                          |
| `clocal cread`    | 忽略 modem 控制线；允许接收                                     |

**你会看到**：`stty -F /dev/ttyUSB0 -a` 回显里 `parenb` 前带 `-`；此后正常固件输出恢复为可读文本。
**失败了先查**：是否别的进程（screen/minicom/openocd）还占着 tty；旗标要一次设全，别分两次。

**静默 = openocd 会话被杀后的 NRST 残留。** openocd 的 halt 内部等待很长；我用 `timeout 25` 起会话，halt 还没完成进程就被杀——DAP 的 nRESET 可能留在**按住**状态。（NRST：芯片复位引脚 nRESET，低电平有效——被按住 = 芯片一直停在复位态）表现极具迷惑性：CPUID 能读（调试私有总线独立供电），但 RCC 等系统寄存器读出全 `0`，且这些 0 与文档复位值矛盾（CR 复位值应为 0x83）。识别特征就这一条：**读出的值连复位值都不是 → 总线死了 → 先 `reset halt` 救一把再谈别的**。

### 3.4 第三层：向量表没接（Vanilla FreeRTOS 的头号坑）

时钟全对之后，串口终于出字——banner 打出来了，然后：

```text
=== Vanilla FreeRTOS on STM32F429 (Fire Challenger V2) ===
kernel: upstream FreeRTOS-Kernel, port: GCC/ARM_CM4F

[ASSERT] .../ARM_CM4F/port.c:342
```

断言在 port.c:342——正是内核自带的 `configCHECK_HANDLER_INSTALLATION` 自检：**读 VTOR 向量表，检查 SVC 和 PendSV 入口是否指向 FreeRTOS 的处理函数**。（VTOR：内核里记录"向量表放在哪个地址"的寄存器；SVC：Supervisor Call，程序主动陷入内核的指令，调度器启动靠它；PendSV：可挂起的系统服务中断，RTOS 专拿它做任务切换）见字如面，它直接报出了病根。

> 📖 **术语卡：中断向量表（Vector Table）**
> **是什么**：芯片里一张「中断号 → 处理函数入口地址」的查找表，复位后默认放在 Flash 开头（0x08000000 处映射到 0x00000000）。
> **为什么存在**：硬件收到中断时不知道该跳去哪，必须有人提前画好地图。
> **类比**：医院分诊台——症状进来，告诉你去哪个诊室。
> ⚠️ 类比边界：分诊台靠人判断，向量表是硬件查表，快得多。

看符号表（`arm-none-eabi-nm`）一目了然：

```text
08001b7c W PendSV_Handler     ← 弱符号，粘到 Default_Handler（死循环）
08001b7c W SysTick_Handler    ← 同上
08001430 T vPortSVCHandler    ← 端口的真处理函数，孤零零没人引用
080016ac T xPortPendSVHandler ← 同上
```

**命令拆解：** `arm-none-eabi-nm <固件.elf>`

| 部分                  | 作用                                                           |
| --------------------- | -------------------------------------------------------------- |
| `arm-none-eabi-nm`    | 交叉工具链版 nm：列出二进制里的符号（函数/变量）及其地址       |
| 输出 `地址 类型 名字` | 类型 `T`=强定义函数、`W`=弱符号、`D`/`B`=已初始化/未初始化数据 |

**你会看到**：端口函数是 `T`（强）、中断入口是 `W`（弱）——同名强弱相遇谁赢，见下方术语卡。
**失败了先查**：看的是不是刚烧进去的那个 elf；`objdump -d`（反汇编工具）可继续看函数体首条指令。

原因：ST 官方启动文件（启动文件：厂商提供的 startup 汇编文件，芯片复位后最先执行，负责摆好向量表、初始化堆栈再跳进你的 main）给所有中断留了**弱符号桩**（全部粘到 Default_Handler 死循环）；而 Vanilla FreeRTOS 的 CM4F 端口把三个关键入口命名为 `vPortSVCHandler / xPortPendSVHandler / xPortSysTickHandler`。两边名字对不上，链接器（链接器：把各 .o 文件拼成最终镜像的工具）老老实实用了弱桩。调度器启动的第一条 `svc 0`（svc 0：触发一次 0 号系统调用，调度器靠它进入第一个任务）直接掉进死循环——`xTickCount`（FreeRTOS 全局节拍计数变量，每 tick +1）永远是 0。

> 📖 **术语卡：弱符号（Weak Symbol）**
> **是什么**：链接器的规则：同一个函数名若同时存在"强定义"和"弱定义"，强者胜，弱者静默让位。ST 启动文件给每个中断入口都备了弱桩（全部指向 Default_Handler 死循环）。
> **为什么存在**：让默认实现可被用户按名字覆盖，不必修改厂商文件。
> **类比**：配置文件里自带的默认值——你在自己的配置里写一行同名项就覆盖它。
> ⚠️ 类比边界：配置覆盖常有日志提示，弱符号覆盖失败是静默的——正是本案第三层 bug 的隐蔽来源。

官方解法是 FreeRTOSConfig.h 尾部三行重命名映射（强符号覆盖弱桩）：

```c
#define vPortSVCHandler     SVC_Handler
#define xPortPendSVHandler  PendSV_Handler
#define xPortSysTickHandler SysTick_Handler
```

**为什么 ESP32 上从没遇到？** 因为乐鑫在 IDF 移植层早就替你接好了（ESP32 也没有这种弱桩启动文件的惯例）。Vanilla 内核 + 芯片厂商启动文件的组合，这三行就是你的"过路费"——FreeRTOS 官方 FAQ 专门有一页讲它。

### 3.5 第四层：`make` 说"无需做任何事"

最阴的一层。改完 FreeRTOSConfig.h，`make` 输出：

```text
make: 对"all"无需做任何事。
```

然后照烧不误——烧的还是旧固件。而旧固件的行为（assert 342）和我的诊断完全自洽，差点让我以为修复无效。**Makefile 没有头文件依赖**：改 `.h` 不会触发任何 `.o` 重编，`make` 觉得一切最新。是符号表救了我——烧完检查 `nm`，三个 Handler 还在 Default_Handler 地址，才发现根本没编进去。

修复：编译参数加 `-MMD -MP`，Makefile 加 `-include $(OBJS:.o=.d)`。（`-MMD -MP`：让编译器为每个 .c 顺手生成 .d 依赖文件，记录"这个 .o 依赖哪些头文件"；`-include $(OBJS:.o=.d)`：让 make 把所有 .d 读进来，头文件一变对应 .o 自动重编——C 构建细节，算你主场边缘）

> 排障铁律升级版：**改完必须验证"改动真的进了产物"**。最小动作 = 烧完看一眼符号表/反汇编，或干脆 `make -B` 强制重编（`-B`：无视新旧全量重编）。

## 4. 终态验证

第四层修完，一锤定音：

```text
=== Vanilla FreeRTOS on STM32F429 (Fire Challenger V2) ===
kernel: upstream FreeRTOS-Kernel, port: GCC/ARM_CM4F

[fast] tick 0
[slow] hello from the low priority task
[fast] tick 1
...
[slow] hello [fast] tick 5        ← slow 被 fast 抢占，交错可见
from the low priority task
```

三项硬指标：

| 验证项        | 方法                                                           | 结果                                    |
| ------------- | -------------------------------------------------------------- | --------------------------------------- |
| 主频真 180MHz | 数打印节奏：fast ≈5.7 条/s、slow ≈0.86 条/s                    | ✓（若主频错，SysTick 周期会同比例漂移） |
| 寄存器实况    | openocd `mdw` 裸读：PLLRDY=1、SWS=PLL、VOS=01+ODRDY、BRR=0x30D | ✓                                       |
| 调度器活着    | `xTickCount` 非 0 且递增；`nm` 三个 T 强符号                   | ✓                                       |

> 行话补注（终态验证表）：
>
> - **SysTick**：内核自带的 24 位倒计时器，按主频一拍拍递减，到 0 触发中断；主频配错则节拍周期同比例漂移——这就是"数打印节奏能反推主频"的原理。
> - **抢占**：高优先级任务可直接打断低优先级任务运行，不必等它让出 CPU——RTOS 相对裸机的核心特权；上面日志里 slow/fast 交错即其外显。
> - **SWS**：RCC->CFGR 里的状态位，报告"系统时钟现在真来自谁"，=PLL 即倍频链确实生效。
> - **ODRDY**：OverDrive（内核升压模块）就绪位；180MHz 档要求 OverDrive 开启。
> - **BRR=0x30D**：串口波特率寄存器。理论分频 90MHz/(16×115200)≈48.84；BRR 高位放整数 48（0x30）、低 4 位放 16 分之几的小数 13/16（0xD），拼成 0x30D——实读与理论相符即波特率配方正确。
> - **xTickCount**：FreeRTOS 全局节拍计数变量，每个 SysTick 中断 +1；非 0 且递增 = 调度器真在跑。

## 5. 排障方法论提炼

这次最有价值的不是四个答案，是**逼近答案的手段**——多数时候证据比灵感先到：

1. **分层判尸**：DPIDR 活/CPUID 死 → 传输层好、芯片内部坏；烧录 Verified OK ≠ 运行正常。先确定"坏在哪一层"，再动手。
2. **断点二分**：卡死类问题，在可疑区间下硬件断点 + `resume` + `halt` + `reg pc`，两次就能锁定死循环指令地址，再 `objdump -d`（objdump -d：把二进制机器码反汇编回指令文本）对质。比盯着代码猜快一个数量级。
3. **活体读寄存器**：`openocd mdw`（mdw：memory display words，openocd 里按 32 位字读任意地址的命令）**不需要 halt**。芯片 running 时直接读 RCC/RAM，零侵入。"你认为的配置"和"寄存器里的配置"是两回事，永远以后者为准。
4. **一个观察变量**：`xTickCount == 0` 一票否决"调度器在跑"的所有幻想。找一个能反映进度的内存变量，读两遍。
5. **读出的值要对着文档复位值验**：全 0 但复位值不该是 0 → 不是寄存器值，是总线死了 → 别分析假数据。
6. **每次修复后验证改动进产物**：`nm`/`objdump` 看符号落位，或强制重编。
7. **环境也要对账**：串口参数（校验位！）、残留进程、被杀会话留下的硬件状态（NRST），都可能是"红鲱鱼"。

> 换成你的主场来读这七条：分层判尸 = 网络排障的分层定位（物理层通 ≠ 应用层活）；断点二分 = 二分法/bisect；活体读寄存器 = `cat /proc/<pid>/*` 式零侵入观测；观察变量 = 监控系统里的计数器指标；对复位值验数 = 对照 `dmesg` 已知默认行为。

## 6. 速查附录

### 命令

```bash
cd ~/stm32/f429-freertos
make probe    # openocd 识别芯片
make flash    # 烧录 + 校验 + 复位
make serial   # 串口监听（含 -parenb，防 stm32loader 校验残留）
# 救砖：
python3 -m stm32loader -p /dev/ttyUSB0 -b 115200 -e
```

### 关键地址

| 目的                | 地址 / 方法                                                    |
| ------------------- | -------------------------------------------------------------- |
| CPUID（调试口体检） | `mdw 0xE000ED00`，M4 应读 `410fc241`                           |
| RCC CR/PLLCFGR/CFGR | `mdw 0x40023800` 起 3 字                                       |
| PWR CR/CSR          | `mdw 0x40007000` 起 2 字                                       |
| 卡死定位            | `reset halt; bp <addr> 2 hw; resume; sleep 1000; halt; reg pc` |

**命令拆解：** `mdw`（openocd 会话内命令，`make probe` 连上后即可用）

| 部分                        | 作用                                                                                                                           |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `mdw <地址>`                | memory display words：按 32 位字读任意地址，芯片运行中也能读、零侵入                                                           |
| `0xE000ED00`                | CPUID 所在地（内核私有外设区）；读回 `410fc241` 解码 = 厂商 0x41（ARM）+ 架构 0xF（v7E-M）+ 型号 0xC24（Cortex-M4）+ 版本 r0p1 |
| `0x40023800` / `0x40007000` | RCC（时钟控制）/ PWR（电源管理）两组寄存器的基址，往后连续读几个字                                                             |

**你会看到**：每个地址一个 32 位 hex 值，对着芯片 reference manual（参考手册）逐位核。
**失败了先查**：读出全 0 且与文档复位值矛盾 → 多半总线死/复位被按住，先 `reset halt`（见第 5 节第 5 条）。

### 本板专属事实

- BOOT 跳线 = **J64**（板左侧中部跳线簇，丝印 3V3/BOOT0/BOOT1，官方文档无记载）
- HSE = **25MHz**（PLL_M 必须 25）；180MHz 需 VOS=01 Scale1 + OverDrive + Flash≥5WS
- 串口走 USART1(PA9/PA10)↔CH340，需 J80/J81 跳帽在位；115200@PCLK2=90MHz → BRR=0x30D（PCLK2：挂 USART1 的那根外设总线时钟，180MHz 主频下为 90MHz）
- OverDrive（内核升压模块）与 Flash WS（Wait State，等待周期——主频越高、电压档越低，读一次 Flash 要插入的等待拍数越多）是 180MHz 配方的最后两味配料
- 以上已沉淀为技能：`fire-f429-flash`（操作）、`fire-f429-specs`（规格）

## 相关阅读

- [[2026-08-26-freertos-deep-dive-ch1-from-bare-metal-to-rtos|FreeRTOS 深度解析（一）：从裸机到 RTOS]] —— 本工程的 fast/slow 双任务即其对照实验
- [[2026-08-26-freertos-deep-dive-ch2-esp32-xtensa-architecture|FreeRTOS 深度解析（二）：ESP32 Xtensa 架构]] —— IDF 替你接好向量表的"另一边"
