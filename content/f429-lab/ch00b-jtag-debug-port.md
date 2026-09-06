---
title: JTAG 调试口深潜：五根线、一个状态机和它的本职工作（含实测）
date: 2026-08-30 06:05:00
description: 野火挑战者 F429 平台的 JTAG 全解——TAP 状态机原理、双 TAP 与 IDCODE 解码、五线接线法、Fedora 上 openocd 命令；含本系列一个月来的全部 JTAG 实测输出
tags: [f429-lab, STM32, JTAG, Debug]
---

# JTAG 调试口深潜：五根线、一个状态机和它的本职工作（含实测）

> **状态声明**：本章证据最厚的一篇——本系列**从序章故障恢复到 ch22 的全部烧录与调试，
> 一直在走 JTAG**（工程默认 `transport select jtag`），文中标注「实测」的输出全部
> 来自这些真实会话。SWD 篇见姊妹章
> [[2026-08-30-f429-lab-ch00a-swd-debug-port\|ch00a]]——两篇共用「三层架构」的底图，
> 各讲各的门。

## 本章装备清单

| 分类 | 装备                         | 价格/状态 | 用务                                 |
| ---- | ---------------------------- | --------- | ------------------------------------ |
| 已有 | 挑战者 F429-V2 板            | ✅        | 被调试方（板上调试座 JTAG/SWD 双开） |
| 已有 | 野火 DAP 仿真器（CMSIS-DAP） | ✅        | 支持 JTAG+SWD 双协议                 |
| 已有 | DAP 防呆排线                 | ✅ 随 DAP | JTAG 用满全部信号，防呆座插不反      |
| 可选 | 杜邦线（母对母）6 根         | ~¥10/排   | 无防呆线时手动接五信号（见第 3 节）  |
| 已有 | Mini-USB 线 + 笔记本         | ✅        | 供电/串口 + 运行 openocd             |

## 本章会遇到的词

| 词              | 一句话版                                     | 详见      |
| --------------- | -------------------------------------------- | --------- |
| JTAG            | 1985 年诞生的五线测试/调试总线（SWD 的前辈） | 第 2.1 节 |
| TAP             | 芯片里的测试访问口——JTAG 的"前台"            | 第 2.2 节 |
| TCK/TMS/TDI/TDO | 时钟/状态机控制/数据入/数据出，四根信号线    | 第 2.1 节 |
| 状态机（16 态） | TMS 引导 TAP 在 16 个状态间走位              | 第 2.3 节 |
| IDCODE          | 每个 TAP 的身份证号，读它=验货               | 第 2.4 节 |
| 边界扫描        | JTAG 的本职工作：测 PCB 焊接连通性           | 第 2.5 节 |
| 双 TAP          | 挑战者上有两个 TAP：CPU 门 + 边界扫描门      | 第 2.4 节 |
| 移位寄存器      | JTAG 一切数据操作的载体                      | 第 2.3 节 |

## 1. 先看我们一直在用的东西

每次 `make probe` 的输出，前两行就是 JTAG 的名片（实测）：

```text
Info : CMSIS-DAP: Interface Initialised (JTAG)
Info : JTAG tap: stm32f4x.cpu tap/device found: 0x4ba00477 (mfg: 0x23b (ARM Ltd), part: 0xba00, ver: 0x4)
Info : JTAG tap: stm32f4x.bs  tap/device found: 0x06419041 (mfg: 0x020 (STMicroelectronics), part: 0x6419, ver: 0x0)
```

两个 `JTAG tap` 行 = 链上有**两个 TAP**被逐个识别。第二行那个 `0x06419041` 在调试链路失效
之夜立过大功：当时 SWD 侧 CPUID 读不出、无法确认芯片身份，是边界扫描 TAP 的这个
ID（part=0x6419，ST 的 F429 家族代号）**从芯片外部证明了"人在、芯好"**——证据链
不依赖 CPU 活着，这正是 JTAG 设计初衷的力量。

## 2. 原理：JTAG 到底是什么

### 2.1 五根线的分工

> 📖 **术语卡：JTAG（Joint Test Action Group，联合测试行动组）**
> **是什么**：1985 年一批芯片厂联合制定的标准（IEEE 1149.1），用五根线构成一条
> **串行测试总线**：能读取链上每颗芯片的身份、驱动/采样它们的每个引脚（边界扫描）、
> 以及——后来被挪用的——指挥芯片内部的调试单元。
> **为什么存在**：80 年代芯片引脚越来越密、电路板层数越来越多，万用表探针已经点到
> 不引脚焊点之下，**出厂测试需要不接触引脚就能验证"焊没焊好"** 的电学手段。
> **类比**：一个 40 年前的 SNMP/带外管理标准——不依赖被测系统任何配合，从独立通道
> 查询与控制每个"端口"（引脚）。
> ⚠️ 类比边界：SNMP 管理的是软件栈，JTAG 的边界扫描直接停在引脚电平层。

| 线   | 方向          | 作用                                                      | STM32 引脚     |
| ---- | ------------- | --------------------------------------------------------- | -------------- |
| TCK  | 仿真器 → 芯片 | 时钟：所有动作按它的节拍走（同 SWCLK 的角色）             | PA14           |
| TMS  | 仿真器 → 芯片 | 状态机引导：每个 TCK 沿上它的电平决定 TAP 走向哪个状态    | PA13           |
| TDI  | 仿真器 → 芯片 | 数据入：往移位寄存器里塞位                                | PA15           |
| TDO  | 芯片 → 仿真器 | 数据出：移位寄存器吐位                                    | PB3            |
| TRST | 仿真器 → 芯片 | 可选的 TAP 硬复位（低有效；很多现代设计省略，走软件复位） | PB4（F429 有） |

对照 SWD（ch00a）：TCK≈SWCLK、TMS+TDI+TDO 的活被 SWDIO 一根线全包（半双工分时）。

### 2.2 TAP：芯片里的前台

> 📖 **术语卡：TAP（Test Access Port，测试访问口）**
> **是什么**：每颗支持 JTAG 的芯片内部的一个小状态机+寄存器组，负责应答总线上的
> 询问。挑战者上有**两个**：`stm32f4x.cpu`（通往调试单元的门）与 `stm32f4x.bs`
> （bs=boundary scan，边界扫描门）。
> **类比**：大楼里两个前台——一个（cpu TAP）转接调试请求进办公楼（总线），另一个
> （bs TAP）管的是大楼每个门口的灯开关（引脚电平）。
> ⚠️ 类比边界：真实前台会下班，TAP 只要芯片上电就在。

### 2.3 状态机与移位：JTAG 的"说语法"

JTAG 的一切操作都是同一套舞蹈：TAP 上电处于 Test-Logic-Reset，之后 TMS 按
16 态状态图引导，走到关键工位：

```text
（简化图，只画常用路径）
 Test-Logic-Reset ──► Run-Test/Idle
        │                  │
        │           TMS=1 进 Capture-DR ──► Shift-DR ──► Exit1-DR ──► Update-DR
        │           （锁存数据寄存器）  （逐位进出）   （生效）
        └─ 另一条对 IR 的同构路径：Capture-IR → Shift-IR → …
```

- **Shift-IR**（指令寄存器）：先告诉 TAP"接下来干什么"（如 IDCODE、BYPASS、EXTEST）
- **Shift-DR**（数据寄存器）：再按刚才的指令移入/移出数据位流

> 📖 **术语卡：移位寄存器（Shift Register）**
> **是什么**：一串首尾相接的存储位，每个 TCK 从 TDI 进一位、TDO 出一位，像传送带。
> **为什么存在**：JTAG 用"串行移位"这一招通吃一切——读 ID、扫引脚、写调试命令，
> 全是"移进去/移出来"。
> **类比**：旋转寿司传送带：放上去一盘（TDI 进位），转一圈，另一端取下一盘（TDO
> 出位）；多颗芯片串联时传送带穿过每家店（见 2.4 的链）。
> ⚠️ 类比边界：传送带是循环的，JTAG 移位是定长（每次移 IR/DR 的固定位数）。

### 2.4 IDCODE 解码：身份证怎么读

上电后 TAP 默认选中 IDCODE 指令，进 Shift-DR 移出 32 位身份证。拿实测值逐字段拆：

```text
0x4ba00477（cpu TAP）:
  ver=0x4  part=0xba00  mfg=0x23b(ARM)     → ARM 的调试端口 DAP
0x06419041（bs TAP）:
  ver=0x0  part=0x6419  mfg=0x020(ST)      → ST 的 F429 家族边界扫描单元
```

> 📖 **术语卡：IDCODE**
> **是什么**：IEEE 1149.1 规定每个 TAP 必须有的 32 位只读身份寄存器（版本:部件号:
> 厂商号:固定尾码 1）。
> **为什么存在**：生产线上先读 ID 确认"板上的芯片是贴对了的"——这是 JTAG 的看家
> 功能，我们时钟配置故障复盘拿它认人属"挪用为民用"。
> **类比**：网卡 MAC 的 OUID 段——前缀告诉你这是谁家的货。
> ⚠️ 类比边界：MAC 全球唯一，part 号只到"家族"粒度（0x6419=F429 系列，不分 IG/II）。

**链（chain）**：多颗芯片的 TDO→TDI 首尾串成一条移位带，一次移位穿过所有 TAP——
这就是复杂板卡（路由器、交换机主板上 CPU+FPGA+PHY 各一带 TAP）的接法。挑战者是
"一颗芯片两个 TAP"的迷你链：openocd 逐个敲门识别，于是有两行 tap 输出。

### 2.5 边界扫描：JTAG 的本职工作

> 📖 **术语卡：边界扫描（Boundary Scan）**
> **是什么**：芯片每个物理引脚内侧都放一个"边界寄存器单元"，串成一条环绕芯片的
> 移位链。通过它，JTAG 能**不惊动芯片内核**地：读每个引脚当前电平 / 强制驱动引脚
> 电平。配合 PCB 设计文件（BSDL），可自动验证"芯片 A 的 37 脚是否真的焊通到芯片 B
> 的 12 脚"。
> **为什么存在**：多层板 + 细间距焊点，探针碰不到，只有从引脚内部"里应外合"。
> **类比**：交换机的端口环回测试（loopback test）——不需要终端设备配合，从端口
> 层自证连通性。
> ⚠️ 类比边界：环回测的是链路收发对，边界扫描测的是"焊点通不通"，粒度更细。

这是 JTAG 与 SWD 的分水岭：**SWD 没有边界扫描**，它只为调试而生。哪天你想验证
挑战者上某两焊点是否连通（比如自己焊坏了排针），JTAG 的 EXTEST 指令是电学手段。
（openocd 对边界扫描的支持有限，完整玩法要专门工具如 urjtag，标系列外选修。）

### 2.6 那"调试"是怎么搭上 JTAG 的

ARM 在 DAP（Debug Access Port）前面放了一个 JTAG 门（TAP），后面三层架构与 SWD
完全共用——DP→AP→MEM-AP→芯片总线（详解与"电话/总机/办公楼"类比见
[[ch00a-swd-debug-port|ch00a 第 2.2 节]]）。所以对调试用户而言
JTAG/SWD 只是"前门不同、屋内同款"——这也是两篇实测输出能逐项对上的原因：

| 读数（实测一致） | JTAG 门             | SWD 门             |
| ---------------- | ------------------- | ------------------ |
| 门牌号           | IDCODE `0x4ba00477` | DPIDR `0x2ba01477` |
| CPUID            | `410fc241` ✓        | `410fc241` ✓       |
| 活体 RCC         | `03035883` ✓        | `03035883` ✓       |

## 3. 接线

### 3.1 主方式：防呆排线（不变）

2×10 防呆盒座一次接通全部 20 触点（JTAG 五信号 + VREF + 9 根 GND + VCC + 两个
保留位——保留位在 fireDAP 上是野火的 TXD/RXD 串口扩展，见 §6.4）。挑战者调试座
与 DAP 的缺口对缺口，物理唯一。

### 3.2 备用方式：杜邦线手动接（6 根）

| DAP 侧信号   | 挑战者调试座丝印 | 意义                            |
| ------------ | ---------------- | ------------------------------- |
| TCK          | TCK/SWCLK        | 时钟（PA14）                    |
| TMS          | TMS/SWDIO        | 状态机引导（PA13）              |
| TDI          | TDI              | 数据入（PA15）                  |
| TDO          | TDO              | 数据出（PB3）                   |
| GND          | GND              | **共地，必须**                  |
| VTref        | 3V3              | 电平参考                        |
| （可选）TRST | nTRST            | TAP 硬复位（PB4，多数场景可省） |

```text
野火 DAP                          挑战者调试座（顶边靠右）
┌────────┐   TCK  ──────────────▶ TCK/SWCLK (PA14)
│  USB   │   TMS  ──────────────▶ TMS/SWDIO (PA13)
│  ▲     │   TDI  ──────────────▶ TDI      (PA15)
└─笔记本─┘   TDO ◀────────────── TDO      (PB3)
             GND  ──────────────▶ GND        ← 共地！
             VTref ─────────────▶ 3V3
```

注意 PA15/PB3/PB4 平时也可被固件复用为 GPIO——固件抢走它们 = JTAG 门被关（SWD 的
两脚同理，见 ch00a 的 PA13/14 卡）。手动接 JTAG 比 SWD 多接两三根，但换来边界扫描
能力。

## 4. Linux 命令实战（Fedora）

### 4.1 配置文件：我们一直在用的那份

`~/stm32/f429-freertos/openocd.cfg`（实测逐行）：

```text
source [find interface/cmsis-dap.cfg]   ← CMSIS-DAP 家族仿真器（野火 DAP）
transport select jtag                   ← 敲 JTAG 门（本系列全程默认）
source [find target/stm32f4x.cfg]       ← ST F4 目标（含两个 TAP 的声明与烧录脚本）
adapter speed 2000                      ← TCK 2MHz
reset_config srst_only srst_nogate connect_assert_srst
                                        ↑ 只用 NRST；连接时按住复位再松（故障恢复姿势）
```

第 4.2–4.6 节的命令与 ch00a **逐字相同**（把 `-f openocd-swd.cfg` 换成
`-f openocd.cfg` 即可）——openocd 把协议差异吃掉了，这是分层的好处。

### 4.2 体检（probe）：亲眼看两个 TAP 被识别

**命令拆解：** `cd ~/stm32/f429-freertos && make probe`

| 部分         | 作用                                            |
| ------------ | ----------------------------------------------- |
| `make probe` | 展开为 openocd … `-c "init; targets; shutdown"` |
| `init`       | 连接：复位 TAP → 读链上 IDCODE → 逐个识别       |

```text
【实测】完整输出（节选）：
Info : CMSIS-DAP: Interface Initialised (JTAG)
Info : JTAG tap: stm32f4x.cpu tap/device found: 0x4ba00477 (mfg: 0x23b (ARM Ltd)…)
Info : JTAG tap: stm32f4x.bs  tap/device found: 0x06419041 (mfg: 0x020 (STMicroelectronics)…)
Info : [stm32f4x.cpu] Cortex-M4 r0p1 processor detected
Info : [stm32f4x.cpu] target has 6 breakpoints, 4 watchpoints
```

**失败了先查**：`lsusb | grep -i dap` → 排线 → 降速 `adapter speed 1000`。

### 4.3 双协议切换实验（ch00a 第 1 节的另一半）

```bash
cd ~/stm32/f429-freertos
openocd -f openocd.cfg     -c "init; targets; shutdown"   # JTAG 门
openocd -f openocd-swd.cfg -c "init; targets; shutdown"   # SWD 门
```

同一个 DAP、同一条排线、同一颗芯片：两扇门轮流敲，输出里只有"门牌号行"不同
（IDCODE↔DPIDR）——SWJ-DP 自动协议识别的现场演示。

### 4.4 烧录/调试/串口：四目标工作流（JTAG 下全部实测过）

**命令拆解：** `make flash / make gdb / make serial / make probe`

| 目标          | 干什么                 | JTAG 下的实测履历                 |
| ------------- | ---------------------- | --------------------------------- |
| `make flash`  | 烧录+校验+复位         | 序章两次 Verified OK + 全系列烧录 |
| `make gdb`    | 交互式调试（:3333）    | ch17 PendSV 单步                  |
| `make serial` | 串口监听（115200 8N1） | 故障恢复夜看到的第一坨乱码与修复  |
| `make probe`  | 体检                   | 时钟配置故障复盘的身份鉴定        |

### 4.5 JTAG 专属进阶（选修，标待实测）

- 边界扫描验线：openocd 支持 EXTEST 原语但工具链不友好，完整玩法走 urjtag/
  OpenOCD 的 jtag subsystem（标系列外）
- 链上多 TAP 的手工遍历：`openocd -c "jtag newtap …"` 自定义链（无需求不要碰）

### 4.6 常见故障速查（JTAG 视角）

| 症状                          | 根因                           | 解法                        |
| ----------------------------- | ------------------------------ | --------------------------- |
| `Could not find JTAG tap`之类 | TDO/TDI 接反、未共地、降速不够 | 查接线、`adapter speed 500` |
| 识别到 TAP 但后续超时         | 内核挂死（非链路问题）         | `reset halt`；序章分层判尸  |
| 一会能连一会不能              | 拓展坞供电/线材干扰            | DAP 直插笔记本 USB          |
| halt 偶发超时                 | 本板已知怪癖                   | 重试或 `reset halt`         |
| 被杀会话后读全 0              | NRST 留在按住态                | 新会话 `reset halt`         |

## 5. 怎么选：JTAG vs SWD 决策表

| 场景                       | 选谁 | 理由                     |
| -------------------------- | ---- | ------------------------ |
| 日常开发调试（本系列 99%） | SWD  | 少 3 根线、快、够用      |
| 验 PCB 焊接/引脚连通       | JTAG | 边界扫描独占能力         |
| 多芯片链（CPU+FPGA）       | JTAG | 链式串联独占             |
| 引脚极度金贵的小封装       | SWD  | 2 根 vs 5 根             |
| 想跟着本系列旧文章原样复现 | JTAG | 全系列实测都在 JTAG 下做 |

## 6. 增补（2026-08-30 问答实录）：码本五层、IDCODE 走读与 NC 化石

### 6.1 码本的五层约定

JTAG 把"约定变化"做到了极致——整本码本分五层叠出：

1. **每根线只说半句话**：TCK 定节拍；TMS 每个上升沿被采样一次（决定状态机走向）；
   TDI 每个上升沿被读走一位；TDO 在**下降沿**更新输出——读写错开半拍，谁也不撞谁；
2. **状态机地图**：16 态，TMS 导航；保命通道=**TMS 连续 5 个 1，无论迷路到哪必回
   Test-Logic-Reset**（协议自带的"总回家按钮"，也是 TRST 可省的原因）；
3. **IR→DR 两段式**：指令寄存器先装"接下来干什么"（IDCODE/BYPASS/EXTEST…），
   数据寄存器再按指令干活；上电默认 IDCODE——所以"开机先读身份证"永远可行；
4. **位序**：移位 LSB 先行；
5. 各指令码的数值：每颗芯片手册给（方言注脚）。

三种码本风格对照记忆：UART=时间片（按时刻表发车）；JTAG=状态机+沿（按舞谱跳舞的
电报员）；SWD=定长帧（现代网络帧）。

### 6.2 读一次 IDCODE 的完整走读（openocd 探链时干的事）

| 拍数  | TMS 序列              | 走到哪                     | 干什么                |
| ----- | --------------------- | -------------------------- | --------------------- |
| 1–5   | 1,1,1,1,1             | 强制回 TLR                 | 从已知状态出发        |
| 6     | 0                     | Run-Test/Idle              | 出门                  |
| 7,8   | 1,1                   | Select-DR→Select-IR        | 宣布"去装指令"        |
| 9,10  | 0,0                   | Capture-IR→Shift-IR        | 进入指令移位态        |
| 11~   | 0（边打拍边放指令位） | Shift-IR                   | IDCODE 指令码逐位塞入 |
| +1,+2 | 1,1                   | Exit1-IR→Update-IR         | 指令生效              |
| 后续  | 1,0,0…                | Select-DR→Capture→Shift-DR | 换数据通道            |
| 32 拍 | 收 TDO 一位/拍        | Shift-DR                   | 收齐 IDCODE，LSB 先拼 |

`make probe` 的两行 TAP 输出=这套流程对链上每个 TAP 各走一遍的成功回执。

### 6.3 IDCODE 考古：值从哪来、名字从哪来

- **值**：制造时物理固化（掩膜/熔丝），固件改不了；厂商号向 JEDEC 申请，part 号
  厂商自定义；
- **名字**：芯片只交数字，"ARM Ltd/STMicroelectronics"是 openocd 源码里的
  JEDEC 对照表（源头 JEP106 出版物）查出来的——**硬件交数字，软件配字典**，
  同 MAC OUI 模式；
- **bit0 哨兵**：恒为 1。链上空位走 BYPASS 移出恒 0——扫链看到全 0="这里没人"，
  看到 bit0=1 才认"真 TAP 在此"。一个比特完成存在性检测。

### 6.4 NC 化石：20 脚座上"没有名字"的两个座位

标准 20 脚的 17/19 位当年分给 DBGRQ/DBGACK（老式仿真器的握手信号），Cortex 时代
废弃——**信号死了座位不能拆**（标准定义冻结，改一位新旧全不兼容）。它们是接口
世界的 reserved 字段（TCP 头保留位同款操作）。警示：别拿 NC 当闲脚用——部分
厂家会挪用接私有信号（野火 fireDAP 就在 20 脚座上引出了 V-UART 的 TXD/RXD，
与两个 NC 并存——具体脚位见 fire-f429-flash 技能的待核对记录）。

### 6.5 最少引脚的三口径

| 口径     | 数量 | 成员                                |
| -------- | ---- | ----------------------------------- |
| 协议本体 | 4    | TCK/TMS/TDI/TDO（缺一即残废）       |
| 常说     | 5    | +TRST（可省：TMS=1×5 拍软复位顶替） |
| 实际接线 | 6    | +GND+VREF（协议外但链路必须）       |

对照 SWD：协议 2 / 实际 4（+可选 nRST=5）——省下的 TDI/TDO 正是 SWD 用半双工
一根线分时收发换回来的。

## 待核对清单

- [ ] TRST（PB4）不接时的行为对照（openocd 未用 nTRST，理论可省）
- [ ] `adapter speed` 500kHz 慢速档救急实测（故障表第 1 行的定量版）
- [ ] PA15/PB3 被固件复用后 JTAG 失联实验（对照 ch00a 的 PA13/14 卡，故意锁门看症状）
- [ ] 边界扫描 EXTEST 在 urjtag 下的最小可行实验（系列外选修）
- [ ] IDCODE 与芯片丝印互证（0x6419 家族号 vs F429IGT6 具体型号的粒度差）

## 相关阅读

- [[ch00a-swd-debug-port|ch00a：SWD 调试口深潜]]——姊妹篇：两根线与三层架构详解
- [[2026-08-30-stm32f429-clock-misconfig-postmortem|故障复盘]]——JTAG TAP 身份鉴定的实战现场
- [[f429-lab|F429 裸机实验室索引]]
