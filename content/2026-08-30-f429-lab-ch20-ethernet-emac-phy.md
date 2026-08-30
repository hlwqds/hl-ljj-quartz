---
title: 以太网上电：EMAC 与 PHY
date: 2026-08-30 05:00:00
description: F429 裸机实验室（二十）——MAC 与 PHY 的分工解剖、MDIO 两线读 PHY ID、RMII 引脚与 50MHz 时钟来源、DMA 描述符环，插网线看 Link Up
tags: [STM32, Ethernet, Lab]
---

# 以太网上电：EMAC 与 PHY

> **状态声明**：本章属「先成文、后实跑」——实验设计、寄存器推导、预期输出均已写定，但**尚未在真机上执行**；
> 所有「预期输出」均为待实测核销的推导值。板上事实（PHY 型号/地址/时钟/走线）查不到的一律标
> 「待核对」并给候选，绝不编造。EMAC 寄存器地址与位序已对本机 CMSIS 设备头文件逐项自查，与
> RM0090 一致。方法论与工具链继承[[2026-08-30-stm32f429-brick-rescue-debug-story|序章]]。

## 本章装备清单

| 分类   | 装备                   | 价格/状态 | 用途                    |
| ------ | ---------------------- | --------- | ----------------------- |
| 已有   | 挑战者 F429-V2 板      | ✅        | 实验主体（板载网口）    |
| 已有   | 野火 DAP + Mini-USB 线 | ✅        | 烧录/调试/串口          |
| 需购买 | 网线一根               | ~¥5       | 板子直连树莓派          |
| 联动   | 树莓派 4B              | 已有      | 网线对端（插拔看 Link） |

## 本章会遇到的词

| 词           | 一句话版                                        | 详见     |
| ------------ | ----------------------------------------------- | -------- |
| MAC          | 数据链路层的硬件：成帧/地址/收发控制，F429 内置 | 硬件解剖 |
| PHY          | 物理层收发器芯片：线路编码/自协商/Link 检测     | 硬件解剖 |
| MDIO / MDC   | 读写 PHY 寄存器的两线管理总线（数据线+时钟线）  | MDIO 节  |
| BCR / BSR    | PHY 的基本控制/基本状态寄存器（802.3 标准）     | MDIO 节  |
| 自协商       | 链路两端自动商定速率与双工                      | MDIO 节  |
| Link Up/Down | 物理链路通/断（BSR 的 bit2）                    | 实验     |
| RMII         | MAC↔PHY 的精简并行接口，9 根线跑 100M           | RMII 节  |
| REF_CLK      | RMII 双方共享的 50MHz 参考时钟                  | RMII 节  |
| strap 引脚   | 上电瞬间靠电平「绑」出芯片配置的引脚            | RMII 节  |
| DMA 描述符   | 告诉以太网 DMA「缓冲在哪/归谁」的内存小卡片     | DMA 节   |
| OWN 位       | 描述符所有权标志：1=DMA 持有，0=CPU 持有        | DMA 节   |

## 目标（先说结论）

- 以太网硬件是**两颗芯片的二人转**：MAC 在 F429 芯片内部（RM0090 称 ETH 外设；RM0090=ST 的 F4xx 参考手册编号），PHY 是 RJ45（网线水晶头的那种插座）旁
  那颗小芯片（野火挑战者 V2 为 **LAN8720/LAN8742 候选，型号待核对**）。分工一句话：**MAC=数据
  链路层的硬件版（成帧/CSMA/RMII 接口；CSMA/CD=载波侦听多路访问/冲突检测，半双工时代的抢线规则，现代交换式全双工下名存实亡但位还在），PHY=物理层收发器（线路编码/Link 检测）**。
- 本章做通标准：**MDIO 两线读出 PHY ID**（LAN8720 预期 0x0007C0F0；LAN8742 预期值不同，读出后对号
  入座），插网线到树莓派，**PHY BSR 的 Link 位（bit2）从 0 变 1**。
- 一个诚实的边界预告：本章做通标准**不依赖 50MHz REF_CLK 正确**——MDIO 是 MAC 独立驱动的管理
  总线，读 ID 与 Link 检测都是 PHY 侧自转；REF_CLK 若有问题，要到 ch21 第一个 ARP（地址解析协议——
  IP→MAC 的邻居查询，你的主场）收不到回答才
  暴露——那时再回来查时钟方案。

## 系统侧类比：你早就用过这对组合

| 以太网侧                      | 系统侧对应（读者已熟）                                     |
| ----------------------------- | ---------------------------------------------------------- |
| MAC（F429 内核里的 ETH 外设） | 服务器网卡里的 MAC IP 核（igb/e1000 的那部分描述符逻辑）   |
| PHY（板上 LAN8720/8742 候选） | 独立电口 PHY 芯片（rtl8211 之流）：编码、自协商、Link 检测 |
| MDIO（MDC/MDIO 两线）         | PCIe 配置空间 / `ethtool` 底下的寄存器读写通道             |
| RMII（MAC↔PHY 数据接口）      | 网卡内部 MAC↔PHY 总线（SGMII/RGMII 的百兆简化版）          |
| REF_CLK 50MHz                 | 两芯片共享的参考时钟约定（PCIe 100MHz RefClk 同款问题）    |
| DMA 描述符环                  | 网卡 RX/TX ring——`ethtool -S` 里那串 rx_no_buffer 的本体   |

「原来我熟的东西在这层长这样」第一弹：Linux 上 `ethtool <iface>` 报的 link/speed/auto-neg，底层
就是驱动经 MDIO 读 PHY 寄存器；本章把这条链路的最底下两根线（MDC/MDIO）亲手拉直。

> ⚠️ 类比边界（都是你的主场，只标差异）：PCIe 配置空间每设备独享、枚举由软件扫描；MDIO 是真·两线共享总线，一条 MDIO 上可挂最多 32 颗 PHY、靠 5 位地址区分，不存在「枚举」只有「扫描试探」。RMII 是并行 GPIO 级总线、双方共享同一 50MHz 时钟沿采样——没有 PCIe 那种串行训练/均衡/Lane 协商，所以 REF_CLK 一坏没有降速重试，只有静默收死。

## 硬件解剖：MAC 与 PHY

> 📖 **术语卡：MAC（Media Access Control，介质访问控制层硬件）**
> **是什么**：以太网「数据链路层」的硬件实现——把字节流装进帧（加帧头/帧尾/CRC 校验）、比对 MAC 地址、控制收发；F429 里它是一块外设（RM0090 叫 ETH），含 MAC 寄存器、统计计数器、DMA。
> **为什么存在**：帧格式/地址过滤/描述符搬运这些规则固定又高频，用硬件跑比软件快几个量级——这正是服务器网卡（igb/e1000）里那颗 MAC IP 核的同一角色。
> **类比**：快递分拣中心——负责打包/验单/按地址分拨，但不关心货走的是公路还是铁路。
> ⚠️ 类比边界：分拣中心可以独立选址；MAC 离开 PHY 就没有线可发——「成帧的」和「上线的」必须成对出现。

> 📖 **术语卡：PHY（Physical Layer Transceiver，物理层收发器）**
> **是什么**：把 MAC 给的并行数字信号与网线上的差分模拟信号互相翻译的芯片：线路编码、时钟恢复、自协商、Link 检测、电气隔离配合。
> **为什么存在**：模拟收发单独做一颗芯片工艺更合适，也让「同一颗 MAC 配不同 PHY（百兆/千兆/光纤）」成为可能——服务器电口 PHY（rtl8211 之流）与板载 LAN8720 是同门。
> **类比**：调制解调器——数字世界与物理线路之间的翻译官。
> ⚠️ 类比边界：调制解调器翻译的是协议内容，PHY 不看帧内容——它对「帧里是什么」一无所知，只管把位送到线上。

### MAC：F429 芯片内部的 ETH 外设（AHB1 段）

ch05 总线图上的坐标（本机 CMSIS 头文件核实）：ETH 外设在 **AHB1 段**（AHB=Advanced High-performance Bus，芯片内部高速总线，挂的都是带宽大户），块基址 `0x40028000`——MAC
寄存器在最前，MMC（MAC Management Counters，以太网收发统计计数器，`ethtool -S` 数据的硬件原型）+0x100，PTP（Precision Time Protocol 精确时间协议——给帧盖硬件时间戳用的单元，本章不用）+0x700，**DMA 寄存器 +0x1000（`0x40029000` 起）**。
ETH DMA 本身是总线矩阵的主设备（ch05 图里「以太网 DMA」那一行），与 CPU、DMA1/2 抢 SRAM 从端口。

本章用到：MAC 侧的 MACCR、MACMIIAR/MACMIIDR（MDIO）、MACA0HR/LR（MAC 地址）；DMA 侧的 DMABMR
（复位）、DMARDLAR/DMATDLAR（描述符表）、DMAOMR（启停）。

上电三件套，顺序有坑（RM0090 明文）：①`RCC->APB2ENR` 先开 SYSCFGEN（SYSCFG=系统配置控制器，管引脚复用杂项选择的小外设；RCC=Reset & Clock Control，全芯片时钟/复位开关的总机房；APB2ENR=APB2 总线外设时钟使能寄存器），**先**把 `SYSCFG->PMC`
（0x40013804）的 `MII_RMII_SEL`（bit23）置 1 选 RMII——RM0090 要求模式选择**在 MAC 时钟使能前**
完成；②`RCC->AHB1ENR` 置 `ETHMACEN`(bit25)+`ETHMACTXEN`(bit26)+`ETHMACRXEN`(bit27)；③`DMABMR`
写 `SR`(bit0) 软件复位，轮询读回 0。

### PHY：RJ45 旁那颗芯片（板上事实待核对）

| 项         | 候选 A                                 | 候选 B                        | 核对方法               |
| ---------- | -------------------------------------- | ----------------------------- | ---------------------- |
| 型号       | LAN8720（预期 ID 0x0007C0F0）          | LAN8742（预期 ID 值待查手册） | 丝印/野火原理图        |
| PHY 地址   | 0                                      | 1                             | MDIO 扫描 0–31（下文） |
| 25MHz 时钟 | PHY 独立晶振，内部 PLL 出 50MHz 给 MAC | 板级时钟出 50MHz 喂 PHY       | 原理图/波形            |

ID 的读法依据：PHY 寄存器 2/3 是 802.3 标准位段，ID1=0x0007 是 SMSC（现 Microchip）的 OUI（Organizationally Unique Identifier，IEEE 分配给厂商的唯一编号——网卡 MAC 地址的前缀也是这套）高位，
ID2 低 4 位是版本号——LAN8720 读出 `0xC0Fx` 即核销。LAN8742 的 ID2 候选写文时未最终确认（不同
子型号有 0xC13x 口径），**以 Microchip 数据手册为准**——这也是把 PHY 地址扫描做进实验的理由。

### RJ45 磁性件：网线自带的隔离

I2C/SPI 双板实验（ch08/09）都强调先共地；以太网不用——RJ45 座内嵌或板侧布有**磁性件（变压器）**，
双绞线上的差分信号经变压器耦合，两端板子的地在直流上互相隔离——网线可以直接怼任何对端而不用
担心地环路，ch21 直连 RPi 不必再飞一根地线。顺带一个数字：100M 只用 2 对差分线（千兆才用满 4 对）。

## MDIO 管理总线：两根线读完 PHY

> 📖 **术语卡：MDIO 管理总线（Management Data Input/Output）**
> **是什么**：IEEE 802.3 定义的两线管理接口——MDC（时钟线，MAC 驱动）+ MDIO（双向数据线），用来读写 PHY 芯片内部的寄存器（配置速率、查 Link、读 ID）。
> **为什么存在**：PHY 是独立芯片，CPU 够不着它的内部寄存器，必须留一条「网线之外的旁路」去配置和体检它——协议、时序全是标准（Clause 22），换 PHY 不换驱动框架。
> **类比**：PCIe 配置空间 / SMBus（你的主场）——数据通路之外那条慢速的「管理通道」。
> ⚠️ 类比边界：PCIe 配置空间每设备独享且软件可枚举；MDIO 一条总线挂最多 32 颗 PHY（5 位地址），没有枚举协议——只能像本章实验那样逐地址试探读 ID。

IEEE 802.3 Clause 22 管理接口：MDC 时钟 + MDIO 双向数据，**MDC 由 MAC 驱动**，分频自 HCLK。
180MHz 下取 Div102（MACMIIAR.CR=100b）→ MDC≈1.76MHz，满足 ≤2.5MHz 上限（分频档已对 CMSIS 头
注释自查：150–168MHz 档即 Div102，180MHz 沿用同档，余量充足；实测可抓 PC1 复核，见
[[2026-08-30-rpi-lab-ch08-instrument-roles-guide|RPi 仪器手册]]）。

读写协议只涉两个寄存器（MACMIIAR 0x40028010 / MACMIIDR 0x40028014）：PA（PHY 地址，bit15:11）、
MR（PHY 寄存器号，bit10:6）、MW（bit1，1=写 0=读）、MB（bit0，写 1 启动、轮询清零收工）。

PHY 前四个寄存器是 802.3 标准，各家通用（这正是「换 PHY 只换 ID 预期值」的原因）：

| 寄存器 | 名字    | 本章用到的位                                                   |
| ------ | ------- | -------------------------------------------------------------- |
| 0      | BCR     | bit15 软复位（写 1 自清零）、bit12 自协商使能、bit9 重启自协商 |
| 1      | BSR     | **bit2 Link Status**、bit5 自协商完成                          |
| 2      | PHY_ID1 | OUI 高位（LAN8720/LAN8742 均为 0x0007）                        |
| 3      | PHY_ID2 | 型号+版本（LAN8720 = 0xC0Fx）                                  |

「第二弹」顿悟：你在服务器上看到的 `ethtool: Link: yes / Auto-negotiation: on`，物理本体就是
BCR/BSR 这几枚位——本章裸机轮询 BSR.bit2 与 Linux 驱动的 PHY 中断/轮询是同一个动作。

> 📖 **术语卡：自协商（Auto-Negotiation，BCR bit12 / BSR bit5）**
> **是什么**：链路两端上电后通过线路上特殊的脉冲互相播报各自支持的速率/双工组合，自动选双方都支持的最优档——`ethtool` 里的 Auto-neg 就是它。
> **为什么存在**：免跳线。没有它的年代速率靠 DIP 开关手配，两边不一致就是各种疑难杂症；协商不成还会回退到默认档。
> **类比**：打电话双方先互报「我说中文/英文？」再挑共同语言开聊。
> ⚠️ 类比边界：人是谈判出「双方都能接受」的方案；自协商选的是**双方能力表的交集里最优**一档，若一侧被强设固定速率（不协商），另一侧的回退规则可能给出双工不匹配——经典半/全双工错配坑。

> 📖 **术语卡：Link（链路状态，BSR bit2）**
> **是什么**：PHY 持续监测线路信号质量得出的「物理链路通/断」结论——通（bit2=1，插好线、对端也上电、信号达标）= Link Up，否则 Link Down。
> **为什么存在**：给上层一个最基础的「线通不通」信号，协议栈据此决定接口 up/down——但注意它**只代表物理层**，Link Up 不等于能 ping 通。
> **类比**：电话拨通了有嘟嘟声（链路建立），但对面接不接、说什么（协议栈/应用）是另一回事。
> ⚠️ 类比边界：BSR 的 Link 位是「锁存低」设计——只要掉过一次链路，读数会保持一次 0、再读才回真值；所以驱动惯例是连读两次取后值，本章半秒轮询也恰好能捕捉瞬时掉线。

## RMII：9 根线上的 100M

> 📖 **术语卡：RMII（Reduced Media Independent Interface，精简介质独立接口）**
> **是什么**：MAC 与 PHY 之间传送以太网帧数据的并行总线：收/发各 2 位数据 + 2 根控制线，外加双方共享的 50MHz REF_CLK 与两根 MDIO 管理线，合计约 9 脚；一次传 2 位、50MHz 恰好凑出 100Mbps。
> **为什么存在**：老标准 MII 用 4 位数据 + 收发各一路 25MHz 时钟，16+ 根线；RMII 把数据位砍半、时钟翻倍、收发共用一个 REF_CLK，引脚省近半——F429 两方案都支持，靠 SYSCFG 一位选择。
> **类比**：把 16 车道并成 9 车道、限速翻倍——总流量不变，占地更小。
> ⚠️ 类比边界：车道宽度说改就改；RMII/MII 一旦焊死就只能靠上电时的 MII_RMII_SEL 软件位选对，选错即「MDIO 能读、数据全死」的静默故障。

引脚映射（F429 datasheet AF 表标准值，全部 AF11——AF=Alternate Function，引脚复用功能编号：一个物理脚可切给不同外设用，AF11 在 F429 上就是「以太网」；**板上实际走线待核对**——TX 侧 F429 还有
PB11/PB12/PB13 备选位，datasheet 一脚多位，板上选了哪组以原理图为准）：

| 引脚 | RMII 功能 | 方向（对 MAC） | AF  |
| ---- | --------- | -------------- | --- |
| PA1  | REF_CLK   | 入（50MHz）    | 11  |
| PA2  | MDIO      | 双向           | 11  |
| PC1  | MDC       | 出             | 11  |
| PA7  | CRS_DV    | 入             | 11  |
| PC4  | RXD0      | 入             | 11  |
| PC5  | RXD1      | 入             | 11  |
| PG11 | TX_EN     | 出             | 11  |
| PG13 | TXD0      | 出             | 11  |
| PG14 | TXD1      | 出             | 11  |

**REF_CLK 50MHz 从哪来**：候选 A——PHY 旁挂 25MHz 晶振，PHY 内部 PLL（锁相环——用输入时钟倍频/分频出目标频率的电路）倍频出 50MHz，经 REF_CLK Out
引脚回送 MAC（PA1），这是国产开发板最常见接法，LAN8720 明确支持（strap 引脚上电时选 In/Out 模式——
strap=绑定脚：芯片在复位结束的瞬间采样这些脚上的电平、锁存成配置（PHY 地址、时钟输入/输出方向等），
采样完脚就恢复普通功能；想改配置得改电路上的上下拉电阻，模式错了是经典「MDIO 通、收发死」故障）。候选 B——板级时钟源出 50MHz 喂 PHY 的 XI 脚。**野火板
走哪个方案待核对原理图**；两方案软件差别只有一处：候选 A 下 PHY 必须先完成上电并输出时钟，MAC
才有 REF_CLK（ch21 抓不到包先查这里，可用 piscope/LA 看 PA1 有无 50MHz——LA=逻辑分析仪，采数字电平看时序；piscope=拿树莓派 GPIO 高速采样当简易逻辑分析仪的玩法，见 RPi 仪器手册）。

## DMA 描述符环：生产者/消费者邮箱的终极形态

> 📖 **术语卡：DMA 描述符（descriptor）与描述符环**
> **是什么**：摆在内存里的小卡片（本章每张 16 字节、4 个 32 位字），写给以太网 DMA 看：「缓冲区在哪、多长、现在归谁」；若干张用「下一张」指针首尾相接成环，DMA 与 CPU 各自从两边推进——DMA 拿走一张填数据，CPU 收走一张读数据。
> **为什么存在**：让硬件搬运零 CPU 参与：CPU 只要预先摆好卡片，收发包时改改 OWN 位即可；网卡 RX/TX ring（你的主场，`ethtool -S` 里 rx_no_buffer 的本体）就是这套东西在服务器上的版本。
> **类比**：小区快递柜的格子+取件码——快递员（DMA）放件拍照，业主（CPU）凭码取件，柜子本身循环使用。
> ⚠️ 类比边界：快递柜格子是硬件固定的；描述符只是普通内存，环长几格、放哪、几条环全由软件摆布——代价是描述符地址必须落在 DMA 访问得到的内存里（本章铁律：禁 CCM）。

ch06 的软件环形缓冲（ISR 生产/主循环消费）、ch10 的 DMA NDTR（硬件推进 head），到本章合流成
**硬件 DMA 与 CPU 共享的描述符邮箱**——openeth 上读过的那套语义（lwIP 主系列
[[2026-08-26-lwip-deep-dive-ch17-ethernetif-porting-guide|（十七）：ethernetif 移植指南]]）换真身对号：

| 对照     | openeth（lwIP ch17）   | F429 ETH DMA（本章）                         |
| -------- | ---------------------- | -------------------------------------------- |
| 描述符   | 8 字节/槽，固定 128 槽 | enhanced 模式 4 字/槽（16B），软件任意深度   |
| 所有权位 | TX 的 rd / RX 的 e     | 收发统一 OWN（bit31）                        |
| 环尾标记 | wr 位                  | RCH/TCH=1 时 DES3 填「下一描述符」指针成链表 |
| 环满     | INT_BUSY 硬丢帧        | DMASR 的 RBU/TPS 状态位（同款「发票」）      |

RX 描述符（每项 4 字）本章用到的位：

| 字    | 位                                       | 含义                                                             |
| ----- | ---------------------------------------- | ---------------------------------------------------------------- |
| RDES0 | OWN(31)、ES(15)、FS(9)、LS(8)、FL(29:16) | OWN=1 归 DMA；FS+LS 同置=完整一帧；FL=帧长（含 4B CRC）          |
| RDES1 | RBS1(13:0)、RCH(14)                      | buffer1 长度；RCH=1 时 DES3 当「下一描述符」用                   |
| RDES2 | Buffer1 指针                             | 帧数据落点——必须 SRAM，**禁 CCM**（ch13 铁律：DMA 走不进那房间） |
| RDES3 | 下一描述符指针（RCH=1 时）               | 链成环：最后一项指回首项                                         |

TX 描述符对称：TDES0 的 OWN(31)/FS(29)/LS(28)/TCH(20)，TDES1 的 TBS1(12:0) 是 buffer 长度，
TDES2 缓冲指针、TDES3 下一描述符。（完整位图以 RM0090「Enhanced descriptor」表为准，只列所用位。）

补一行 CCM：CCM（Core Coupled Memory，F429 特有的 64KB 紧耦合 RAM）只有 CPU 能访问、总线矩阵没
铺路到那——描述符或缓冲落进去，ETH DMA 直接搬不动（ch13 实测铁律）。代码里 `rx_d/tx_d/rx_b/tx_b`
全放普通 SRAM 的 .bss，就是这个原因。

初始化=在 SRAM 里摆两个环，把首地址写进 DMA 列表寄存器（DMARDLAR/DMATDLAR，0x4002900C/0x40029010），
DMAOMR 置 SR/ST 开收发。本章只「上架」不「营业」——真正收发帧在 ch21。

## 实验：读 ID、配 MAC、看 Link

```c
/* ---------- ch20: MDIO 读 PHY ID + MAC/PHY 初始化 + Link 轮询 ---------- */
/* MAC（偏移）：MACCR +0x00  MACMIIAR +0x10  MACMIIDR +0x14  MACA0HR +0x40  MACA0LR +0x44 */
/* DMA（偏移）：DMABMR +0x00  DMARDLAR +0x0C  DMATDLAR +0x10  DMAOMR +0x18            */
#define RM32(off) (*(volatile uint32_t *)(0x40028000u + (off)))
#define RD32(off) (*(volatile uint32_t *)(0x40029000u + (off)))

#define RX_DESC_N 4u
#define TX_DESC_N 4u
#define ETH_MAX 1536u /* MTU 1500 + 头余量 */

typedef struct { volatile uint32_t d0, d1, d2, d3; } desc_t;
static desc_t rx_d[RX_DESC_N] __attribute__((aligned(4))); /* 全在 SRAM(.bss)，绝不能进 CCM */
static desc_t tx_d[TX_DESC_N] __attribute__((aligned(4)));
static uint8_t rx_b[RX_DESC_N][ETH_MAX], tx_b[TX_DESC_N][ETH_MAX];

static uint16_t mdio_read(uint8_t phy, uint8_t reg)
{
    RM32(0x10) = ((uint32_t)phy << 11) | ((uint32_t)reg << 6) | (4u << 2); /* CR=100b, MW=0 读 */
    RM32(0x10) |= 1u;                        /* MB=1 启动；轮询自清零 */
    while (RM32(0x10) & 1u) { }
    return (uint16_t)RM32(0x14);
}

static void mdio_write(uint8_t phy, uint8_t reg, uint16_t val)
{
    RM32(0x14) = val;
    RM32(0x10) = ((uint32_t)phy << 11) | ((uint32_t)reg << 6) | (4u << 2) | (1u << 1) | 1u;
    while (RM32(0x10) & 1u) { }              /* MW=1，MB=1 */
}

static uint8_t phy_addr = 0xFFu; /* 待核对：strap 决定；扫描兜底 */

static void eth_hw_init(void)
{
    /* 1) SYSCFG 先选 RMII，再开 ETH 时钟（RM0090 顺序） */
    RCC->APB2ENR |= (1u << 14);              /* SYSCFGEN */
    *(volatile uint32_t *)0x40013804 |= (1u << 23); /* SYSCFG_PMC.MII_RMII_SEL=1 */
    RCC->AHB1ENR |= (7u << 25) | (1u << 0) | (1u << 2) | (1u << 6); /* ETH 三位+GPIOA/C/G */
    rmii_gpio_af11_init();                   /* 2) 九脚 AF11：MODER=10b、OSPEEDR=11b、AFR=0xB（略） */
    RD32(0x00) |= 1u;                        /* 3) DMA 软复位，轮询自清零 */
    while (RD32(0x00) & 1u) { }
    /* 4) 描述符环上架：RCH/TCH=1 链表成环，RX 全部 OWN=1 交给 DMA */
    for (uint32_t i = 0; i < RX_DESC_N; i++) {
        rx_d[i].d1 = (1u << 14) | ETH_MAX;   /* RCH | RBS1 */
        rx_d[i].d2 = (uint32_t)rx_b[i];
        rx_d[i].d3 = (uint32_t)&rx_d[(i + 1) % RX_DESC_N];
        rx_d[i].d0 = 0x80000000u;            /* OWN=1 */
    }
    for (uint32_t i = 0; i < TX_DESC_N; i++) {
        tx_d[i].d0 = (1u << 20);             /* TCH */
        tx_d[i].d2 = (uint32_t)tx_b[i];
        tx_d[i].d3 = (uint32_t)&tx_d[(i + 1) % TX_DESC_N];
    }
    RD32(0x0C) = (uint32_t)rx_d;             /* DMARDLAR / DMATDLAR */
    RD32(0x10) = (uint32_t)tx_d;
    /* 5) MAC：自造本地管理地址（F429 无出厂 MAC：首字节 bit1=1，可从 96bit UID 派生或写死） */
    RM32(0x40) = 0x00001234u;                /* MACA0HR：高 16 位 */
    RM32(0x44) = 0x56789ABCu;                /* MACA0LR：低 32 位 */
    RM32(0x00) = (1u << 14) | (1u << 11) | (1u << 3) | (1u << 2); /* FES/DM/TE/RE */
    RD32(0x18) = (1u << 13) | (1u << 1);     /* DMAOMR：ST/SR——开张 */
}

static void phy_scan_and_reset(void)
{
    uart_puts("-- MDIO scan (reg2/3, addr 0..7) --\r\n");
    for (uint8_t a = 0; a <= 7; a++) {       /* 全扫是 0..31，示例截到 7 */
        uint16_t id1 = mdio_read(a, 2), id2 = mdio_read(a, 3);
        if (id1 == 0xFFFFu || id1 == 0x0000u) continue; /* 悬空/无应答 */
        uart_puts("phy "); uart_putdec(a);   /* 打印：phy N ID1=0x… ID2=0x… */
        uart_puts(" ID1=0x"); uart_puthex16(id1);
        uart_puts(" ID2=0x"); uart_puthex16(id2); uart_puts("\r\n");
        phy_addr = a;
    }
    mdio_write(phy_addr, 0, 0x8000u);        /* BCR 软复位，自清零 */
    while (mdio_read(phy_addr, 0) & 0x8000u) { }
    mdio_write(phy_addr, 0, 0x1200u);        /* 自协商使能 + 重启自协商 */
}

int main(void)
{
    clock_init(); uart_init();
    eth_hw_init(); phy_scan_and_reset();

    uint32_t last = 0; uint8_t was_up = 0;
    for (;;) {
        if (g_ms - last >= 500u) {           /* 半秒一轮询（ch01 的 g_ms 地基） */
            last += 500u;
            uint16_t bsr = mdio_read(phy_addr, 1);
            uint8_t up = (bsr >> 2) & 1u;    /* BSR.bit2 = Link Status */
            if (up != was_up) {              /* 打印：link: UP/DOWN BSR=0x… autoneg=n */
                uart_puts(up ? "link: UP   " : "link: DOWN ");
                uart_puts("BSR=0x"); uart_puthex16(bsr);
                uart_puts(" autoneg="); uart_putdec((bsr >> 5) & 1u); uart_puts("\r\n");
                was_up = up;
            }
        }
    }
}
```

插拔网线的观察顺序：插 RPi 直连网线 → 1–3 秒内 `link: UP`（自协商耗时，PHY 侧自动）；拔线 →
`link: DOWN`。Link 翻转是纯 PHY 侧行为，CPU 只是旁观者——这一刻你亲眼分清了「链路」与「协议栈」。

代码走读（四段各有心机）：`mdio_read` 的三行是 MACMIIAR 的位打包——PHY 地址左移 11 位、寄存器号
左移 6 位、CR=100b 选 Div102 分频，末位 MB 写 1 是「发车」、轮询到自清零是「到站」，结果从
MACMIIDR（+0x14）取；`phy_scan_and_reset` 拿 ID1==0xFFFF/0x0000 当「此地址无 PHY」的判据（MDIO
悬空读到全 1、无应答回 0），扫到非空即锁定地址，再写 BCR=0x8000 软复位并轮询自清零、0x1200 开
自协商+重启协商；`eth_hw_init` 的顺序就是「上电三件套」+描述符上架——RX 环四项全部 OWN=1 意思是
「这四个空缓冲全交给 DMA 随便填」，TX 环不置 OWN（CPU 还没东西要发）；主循环每 500ms 读一次 BSR、
只打印**翻转**不打印稳态——串口安静就是链路稳定。缓冲取 1536=MTU 1500+余量（MTU 你的主场：以太网
payload 传统上限，多出的留给 VLAN 头/对齐）。

## 预期输出（待实测核销）

串口侧（LAN8720 候选值的推导：ID1=0x0007、ID2=0xC0F0；BSR 数值整体读数待实测，只推位段）：

```text
-- MDIO scan (reg2/3, addr 0..7) --
phy 0 ID1=0x0007 ID2=0xC0F0        ← 候选 A：LAN8720（若是 0x0007 C13x → 候选 B：LAN8742，查手册对号）
link: UP   BSR=0x79xx autoneg=1    ← xx=版本相关位；bit5=1 自协商完成、bit2=1 Link
link: DOWN BSR=0x79xx autoneg=0    ← 拔线后
```

寄存器侧（openocd 活体 `mdw`，推导依据上文配置）：

| 地址       | 预期值（关键位）           | 推导                                      |
| ---------- | -------------------------- | ----------------------------------------- |
| 0x40023830 | 0x0Exxxxxx（bit25:27=111） | RCC_AHB1ENR：ETH MAC/TX/RX 三时钟         |
| 0x40013804 | 0x008xxxxx（bit23=1）      | SYSCFG_PMC：RMII 已选                     |
| 0x40028000 | 0x0000408C                 | MACCR：FES+DM+TE+RE                       |
| 0x4002900C | rx_d 数组地址              | DMARDLAR=描述符环首（`nm` 查符号对账）    |
| 0x40029014 | bit16（NIS）随收发变化     | DMASR：上架后由 DMA 回写（ch21 才有动静） |

**命令拆解：** `mdw 0x40023830 1`（活体读寄存器，任务跑着时执行，序章方法 3）

| 部分         | 作用                                          |
| ------------ | --------------------------------------------- |
| `mdw`        | openocd 的读内存命令：从地址读 32 位字打印    |
| `0x40023830` | RCC_AHB1ENR 的地址——查 ETH 三位时钟有没有全开 |
| `1`          | 读 1 个字                                     |

**你会看到**：`0x40023830: 0x0exxxxxx`——bit25/26/27 全 1 即 MAC/TX/RX 三时钟齐活。
**失败了先查**：读到全 0（eth_hw_init 没跑到）；bit 缺一（只开部分时钟，收或发必死一边）。

**命令拆解：** `arm-none-eabi-nm build/f429-freertos.elf | grep 'rx_d\|tx_d'`

| 部分                   | 作用                                                        |
| ---------------------- | ----------------------------------------------------------- |
| `arm-none-eabi-nm`     | 列 ELF 符号表（名字→地址）                                  |
| `\| grep 'rx_d\|tx_d'` | 过滤出两个描述符数组的地基址，与 DMARDLAR/DMATDLAR 读数对账 |

**你会看到**：`2000xxxx B rx_d` 一行——这个地址应等于 `mdw 0x4002900C` 读回的值。
**失败了先查**：两边对不上（描述符还没上架或读错寄存器）；地址落在 0x10000000 段（进了 CCM，DMA 访问不到——编译摆位出问题）。

## 系列对照

- **与 lwIP 主系列的接缝**：本章产出（描述符环+MDIO+MAC 地址）正是
  [[2026-08-26-lwip-deep-dive-ch17-ethernetif-porting-guide|lwIP（十七）]] 里 `low_level_init`
  该干的活——openeth 缩小版讲架构，本章在真芯片放大回来；17.4 清单逐条兑现（D-cache 免课）。
- **ESP32 侧的镜像**：esp_eth 组件底下同样是 MAC+PHY+MDIO，乐鑫替你写好了一排驱动；WiFi 侧（
  [[2026-08-26-lwip-deep-dive-ch18-esp32-wifi-lwip-integration|lwIP（十八）]]）连 MAC 都在闭源
  `libnet80211.a` 里——F429 是把「网卡」拆到元件级的唯一机会。
- **回扣本系列**：描述符环是 ch06/ch10 缓冲思想的终极形态（硬件是生产者，OWN 位是锁）；「缓冲
  禁进 CCM」是 ch13 实测结论的直接应用。

## 本章待核对清单

| #   | 项                                                           | 核对方法                         |
| --- | ------------------------------------------------------------ | -------------------------------- |
| 1   | PHY 型号与 ID（LAN8720 0x0007C0F0 / LAN8742 待查手册）       | 丝印/原理图 + 本章 MDIO 读数对号 |
| 2   | PHY 地址（候选 0/1，strap 决定）                             | 本章扫描 0–31 兜底               |
| 3   | REF_CLK 方案（候选 A：PHY PLL 出 50MHz / 候选 B：外部时钟）  | 原理图；piscope/LA 看 PA1 波形   |
| 4   | RMII 九脚板上实际走线（TX 侧 PG11/13/14 vs PB 备选）         | 原理图/万用表通断                |
| 5   | MACMIIAR.CR=Div102 在 180MHz 的实测 MDC 频率（预期≈1.76MHz） | LA 抓 PC1                        |
| 6   | TX 描述符位图与缓冲对齐要求（RM0090）终核                    | 发送路径上电前（ch21 实验①前置） |
| 7   | PHY nRST 引脚（若板上有独立复位脚，比软复位更彻底）          | 原理图                           |

名词补注（清单 #7 用到的）：nRST=PHY 芯片的硬件复位脚，拉低即把整颗芯片（含 strap 采样、内部
状态机）推倒重来；本章代码用的 BCR 软复位（写 0x8000）只复位寄存器与功能逻辑，档次略低但不用动
GPIO——板上若有独立 nRST 走线，救场时它比软复位彻底。

上一章：[[2026-08-30-f429-lab-ch19-heap4-fragmentation|heap_4 碎片实验]]——静态数组堆的结论马上
要在 lwIP 的 pbuf 池上复用；下一章：[[2026-08-30-f429-lab-ch21-baremetal-lwip|裸机 lwIP]]——把本章
的硬件邮箱接上协议栈，发出第一声 ARP。系列总目录见
[[2026-08-30-f429-lab-series-index|F429 裸机实验室索引]]。
