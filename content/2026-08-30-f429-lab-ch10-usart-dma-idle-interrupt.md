---
title: DMA：把 memcpy 交给硬件
date: 2026-08-30 04:10:00
description: F429 裸机实验室（十）——DMA2 路由表与 Stream 寄存器逐位解读，USART 定长块回显 + IDLE 空闲中断变长接收，空转计数器自证 CPU 自由
tags: [STM32, CortexM, DMA, Lab]
---

# DMA：把 memcpy 交给硬件

> **状态声明**：本章属「先成文、后实跑」——实验设计与寄存器推导已写定，但**尚未在真机上执行**；
> 所有「预期输出」均为待实测核销的推导值（空转计数率、中断次数为算术推导，非实测）。文中
> DMA 请求映射行（USART1/ADC1）已对 RM0090 Table 42/43 的公开资料自查一遍（RM0090=ST 官方
> 《STM32F4xx 参考手册》的文档编号；Table 42/43 就是「哪个外设请求走哪个 DMA 流」的硬事实表），
> 其余未用到的组合用时再查、不预填。基座=序章工程（BRR=0x30D、g_ms 时基；BRR 是 USART 的
> 波特率分频寄存器，0x30D 即 115200 baud 对应的分频值；g_ms 是 SysTick 毫秒计数地基），
> ch06 的环收（环形缓冲区接收路径）着本章接管收发路径。
> 方法论与工具链继承[[2026-08-30-stm32f429-brick-rescue-debug-story|序章]]。

## 本章装备清单

| 分类       | 装备                    | 价格/状态 | 用途           |
| ---------- | ----------------------- | --------- | -------------- |
| 已有       | 挑战者 F429-V2 板       | ✅        | 实验主体       |
| 已有       | 野火 DAP 仿真器         | ✅        | 烧录与调试     |
| 已有       | Mini-USB 线             | ✅        | 供电+串口      |
| 已有       | 笔记本（Fedora 工具链） | ✅        | 工具链主机     |
| 沿用基础盘 | 无新增                  | —         | 串口即实验对象 |

## 本章会遇到的词

| 词                   | 一句话版                                             | 详见      |
| -------------------- | ---------------------------------------------------- | --------- |
| DMA                  | 不经 CPU 的搬运工，外设和内存直通                    | 第 1 节   |
| DMA 控制器 / Stream  | 两台搬运公司 × 各 8 条搬运流                         | 原理下钻  |
| Channel（CHSEL）     | 每条流从 8 根外设请求线里选一根的选择器              | 原理下钻  |
| AHB / APB / 总线矩阵 | 芯片内的高速/低速总线与它们的交叉交换矩阵            | 原理下钻  |
| NDTR                 | 搬运单剩余项数，硬件递减；读它=问「搬到哪了」        | Stream 表 |
| PAR / M0AR           | 搬运单上的外设地址 / 内存地址两个格子                | Stream 表 |
| IDLE 空闲中断        | 线路静默一字符时间，硬件替你报「帧尾」               | 原理下钻  |
| RXNE / ORE           | 「收到字节待读」标志 / 溢出错误，ch06 每字节老路径   | 原理下钻  |
| NVIC                 | Cortex-M 的中断控制器：向量号、使能、优先级          | 实验代码  |
| 写 1 清零            | 挂起标志的清法：往那一位写 1 才清，写 0 无效         | 原理下钻  |
| SR / DR              | 外设的状态寄存器 / 数据寄存器                        | 原理下钻  |
| M2M / CIRC / DBM     | 内存到内存 / 循环自动重装 / 双缓冲乒乓，三种进阶模式 | 原理下钻  |

## 目标（先说结论）

- DMA 是片上**异步 memcpy 引擎**：CPU 只填一张「搬运单」（源、目的、长度），搬完由中断通知——
  传输期间 CPU 全程自由。本章把 ch06 的「每字节一次中断」升级为「每帧一次中断」。
- 三件事讲透：①F429 的 DMA 拓扑（**两控制器 × 8 stream × 8 channel 的路由表**，串口为什么只能
  上 DMA2）；②Stream 寄存器组逐位（PAR/M0AR/NDTR/CR）；③**IDLE 空闲中断**——变长接收的
  嵌入式经典手势，逐行拆。
- 三个实验：①定长块 DMA 回显（外设↔内存两方向各练一遍）；②IDLE 变长帧回显（帧长用 NDTR
  反算）；③**CPU 自由的铁证**——主循环空转计数器在 DMA 大块传输期间照涨不误，对照 ch06 的
  0.7% 中断税继续把账算到极限。

> 📖 **术语卡：DMA（Direct Memory Access，直接内存访问）**
> **是什么**：芯片里独立于 CPU 的小搬运引擎（即文中的「DMA 控制器」），按 CPU 预先填好的一张「搬运单」——源地址（PAR）、目的地址（M0AR）、项数（NDTR）——在内存和外设寄存器之间倒数据，搬完/出错用中断通知 CPU。
> **为什么存在**：CPU 一个字节一个字节搬（load/store 循环）极度浪费——就像让 CEO 亲自收发每一封邮件；DMA 把「搬运」这件事整个卸载给硬件，传输期间 CPU 全程自由。
> **类比**：网卡 DMA 收包：网卡直接写内存环，CPU 只处理「到了一批」的完成通知（你的主场：异步 memcpy 卸载 + descriptor ring + 完成事件，一套全齐）。
> ⚠️ 类比边界：网卡有专用描述符协议与环回语义；STM32 的 DMA 流是通用搬运工，描述符要靠 NDTR/地址寄存器手动重构，环（CIRC）也只是简单回卷。

## 系统侧类比：网卡 DMA 与 io_uring

| DMA 侧                | 系统侧对应                                             |
| --------------------- | ------------------------------------------------------ |
| DMA 控制器            | 网卡 DMA 引擎 / 异步 memcpy 卸载单元                   |
| Stream（传输流）      | DMA channel / 网卡队列：一单业务一条流                 |
| 搬运单 PAR/M0AR/NDTR  | descriptor：源地址、目的地址、长度                     |
| TCIE 传输完成中断     | io_uring 的 CQE 完成事件：提交后去做别的，完成时被通知 |
| IDLE 空闲中断         | 帧定界：线路静默一字符时间=隐式分隔符（应用层读分帧）  |
| NDTR 剩余计数         | ring buffer 的 tail 残量：`总长−NDTR`=已到字节数       |
| Channel 路由（CHSEL） | 中断路由表/IRQ affinity：把请求线接到哪条流上          |
| TEIE 传输错误         | NIC 的 DMA error / 总线错误计数器                      |

一句话：ch06 是「中断 per-packet」的古老收包模式，本章是「DMA ring + 完成通知」的现代模式——
lwIP 收包路径里 pbuf 之前的那一层硬件骨架，正是本章这套手势。

（表右列的 descriptor、io_uring SQE/CQE、IRQ affinity、ring buffer tail 全是你的主场，不再展开；
左列才是本章要新学的词。）

## 原理下钻

### 两台引擎：串口为什么必须上 DMA2

F429 有两个 DMA 控制器，寄存器窗口都在 AHB1 段（ch05 总线图上 0x40020000+ 的坐标）：
**DMA1@0x40026000、DMA2@0x40026400**。区别在外设请求口接的域：

- **DMA1 的外设口只接 APB1**——TIM2–7、USART2/3、I2C、SPI2/3（45MHz 慢域）的请求线只连它；
- **DMA2 外设口接 APB2，同时还有独立的内存主端口**——USART1、ADC、SPI1（90MHz 快域）只能
  由它伺候；也因此**内存到内存（M2M）只有 DMA2 能做**（DMA1 没有第二根总线矩阵主端口，源
  目的都只能有一端在 APB1 外设上）。M2M 模式下 CIRC 与 FIFO burst 不可用，CHSEL 无效
  （burst=突发传输：DMA 一次拿到总线就连发多拍数据，摊薄每次总线仲裁的开销；FIFO=stream
  内部的小缓冲队列，用来攒数据凑一次 burst）。

> 📖 **术语卡：AHB / APB 总线与总线矩阵（Bus Matrix）**
> **是什么**：STM32 内部的三条高速公路——AHB（Advanced High-performance Bus，高速总线，挂 CPU、DMA 控制器、内存）、APB1/APB2（Advanced Peripheral Bus，外设总线，挂 UART/SPI/定时器等慢速外设；F429 上 APB1=45MHz 慢域、APB2=90MHz 快域）。总线矩阵是把多条主设备（CPU、DMA1、DMA2）和多条从设备（Flash、SRAM、各 APB 桥）交叉连通的交换矩阵，谁当主（master，发起读写）谁当从（slave，被读写）由矩阵仲裁。
> **为什么存在**：多个主设备要并发访存，点对点连线不现实；矩阵让「DMA2 访问 SRAM」与「CPU 取指」并行不冲突——DMA 能让 CPU「全程自由」的物理前提就在这。
> **类比**：机箱里的 PCIe 交换/NUMA 互连——多个 initiator 各自并发打到多个 target（你的主场）。
> ⚠️ 类比边界：总线矩阵是单个 SoC 内部的仲裁，延迟纳秒级；没有协议栈、没有重传，抢输就是等。

所以「USART/SPI 等高速通信用 DMA2」不是性能建议，是**拓扑硬约束**——ch05 那张总线图上，
DMA1 根本没有通往 USART1 的请求线。

### 路由表：外设请求 → Stream/Channel

每个控制器 8 个 stream（搬运流），每个 stream 从 8 个 channel 里选一路请求线（CR.CHSEL）。
「哪个外设走哪个 Stream/Channel」是 RM0090 的硬事实表，不能猜。本系列会用到的行：

| 外设请求  | 控制器 | Stream/Channel          | 用途        |
| --------- | ------ | ----------------------- | ----------- |
| USART1_RX | DMA2   | Stream2 Ch4（或 S5）    | 本章 RX     |
| USART1_TX | DMA2   | Stream7 Ch4（或 S6 C5） | 本章 TX     |
| ADC1      | DMA2   | Stream0 Ch0（或 S4）    | ch11 采样流 |

> 📖 **术语卡：Stream 与 Channel（DMA 的搬运流与请求线）**
> **是什么**：每个 DMA 控制器有 8 条 stream（传输流，一条独立的一次搬运业务：一组自己的 CR/NDTR/PAR/M0AR 寄存器）；每条 stream 靠 CR 里的 3 位 CHSEL 从 8 根 channel（请求线）里选一根——channel 不是新硬件，是「外设到 DMA 的请求信号线」的编号。哪个外设的请求线接在哪根 channel 上，由芯片设计焊死，只能查 RM0090 的映射表。
> **为什么存在**：外设多于 stream（几十个外设 vs 8 条流），用「一根线多个外设分时复用」的交换结构省硬件；代价是同 channel 的外设不能同时用同一 stream。
> **类比**：网卡多队列 + 中断路由表：把「请求线」接到哪条「流」上，如同把 IRQ 亲和到哪个核（你的主场）。
> ⚠️ 类比边界：网卡的 RSS 队列是按流哈希分流、软件可调；DMA 的 Channel↔外设映射是芯片布线决定的硬表，选错 stream 就永远收不到请求。

（RX 与 TX 各有两个候选 stream 是路由表给的备选路径，类比网卡多队列；本章选 S2+S7，
S5 留空。本表已对照 RM0090 Table 43 的公开资料自查；SPI1/USART2 等行用时再查。）

### Stream 寄存器组：一张搬运单的六个字段

每条 stream 一组寄存器，基址 `0x40026400 + 0x10 + 0x18×n`（n=stream 号；0x10=控制器公共
寄存器区的结束偏移，0x18=每 stream 六个 32 位寄存器共 24 字节的块距，S2=0x10+0x18×2=0x40）。
以本章
S2/S7 为例：

| 偏移（S2/S7）     | 寄存器 | 作用                                                         |
| ----------------- | ------ | ------------------------------------------------------------ |
| +0x40 / +0x88     | CR     | 控制字：方向/递增/宽度/优先级/通道/中断使能/EN（逐位见下）   |
| +0x44 / +0x8C     | NDTR   | 剩余传输项数：硬件递减，**读它=问「搬到哪了」**              |
| +0x48 / +0x90     | PAR    | 外设地址（本章=&USART1->DR，固定不递增）                     |
| +0x4C / +0x94     | M0AR   | 内存地址 0（MINC=1 时逐项递增）                              |
| （+0x50 / +0x98） | M1AR   | 内存地址 1：双缓冲 DBM 模式的另一块（本章不用，ch11 讲思想） |
| （+0x54 / +0x9C） | FCR    | FIFO 控制：默认 direct mode 关 FIFO——字节流不需要 burst      |

CR 的关键位（RM0090 位序，全章代码就靠这张小表写）：

| 位    | 名        | 一句话                                                 |
| ----- | --------- | ------------------------------------------------------ |
| 0     | EN        | 挂机/摘机。清零后必须**轮询读回 0**才能改配置          |
| 2     | TEIE      | 传输错误中断（总线拒绝时置位，ch13 的主角）            |
| 3     | HTIE      | 半传输中断：NDTR 数到一半来一次（ch11 双缓冲的左半边） |
| 4     | TCIE      | 传输完成中断：NDTR 数到 0 来一次                       |
| 7:6   | DIR       | 00 外设→内存、01 内存→外设、10 内存→内存               |
| 8     | CIRC      | 循环模式：NDTR 到 0 自动重装，地址回卷（ch11 用）      |
| 9/10  | PINC/MINC | 外设/内存地址递增。串口：PINC=0（DR 不动）、MINC=1     |
| 12:11 | PSIZE     | 外设侧宽度：00 字节、01 半字、10 字                    |
| 14:13 | MSIZE     | 内存侧宽度（可与 PSIZE 不同，FIFO 做打包）             |
| 17:16 | PL        | 流间仲裁优先级（两流抢同一从端口时用）                 |
| 18    | DBM       | 双缓冲：M0AR/M1AR 乒乓（HT/TC 各切一次）               |
| 27:25 | CHSEL     | 请求线选择：路由表查得的 Channel 号                    |

配置纪律（RM0090 明文顺序，违反会有幽灵流）：`EN=0 → 等 EN 读回 0 → 写 PAR/M0AR/NDTR →
写 CR 其余位 → 清 LIFCR/HIFCR 挂起标志 → 最后 EN=1 摘机`。中断标志在
LISR/HISR（stream 0–3 低半区、4–7 高半区），**写 1 清零**（经 LIFCR/HIFCR），每 stream 五个
标志：FEIF/DMEIF/TEIF/HTIF/TCIF。

几个词扫盲：**幽灵流**=stream 带着半套/旧配置就被使能，DMA 按残缺搬运单乱跑——所以改配置前
必须先挂机（EN=0）并**轮询读回 0**（写 EN=0 只是发请求，硬件把手头事务收尾后才真正停）；**写 1
清零**（write-1-to-clear）=这类标志寄存器往对应位写 1 才清除、写 0 无效果，防止「读-改-写」把
旁边的标志顺手误清；五个标志速记——FEIF（FIFO 错误）、DMEIF（直接模式错误）、TEIF（传输错误，
总线拒绝了搬运）、HTIF（半传输完成，NDTR 数到一半）、TCIF（传输完成，NDTR 数到 0）。

### IDLE 空闲中断：变长帧的句号

> 📖 **术语卡：IDLE 空闲中断（USART 的帧尾探测器）**
> **是什么**：USART 的状态机发现数据线连续静默一个字符时间（=一帧 10 bit 的时长，115200 下约 86.8µs）就把状态寄存器的 IDLE 位（SR bit4）置 1；若 CR1.IDLEIE=1 则触发中断。SR（Status Register，状态寄存器）记录「发生了什么」，DR（Data Register，数据寄存器）是字节进出的门口。
> **为什么存在**：UART 是纯字节流，协议里没有帧头帧尾字段；「线路静默」是物理层白送的隐式分隔符——硬件替你盯梢，CPU 不必逐字判断「停了没有」。
> **类比**：流式协议里的 idle timeout 分帧：连接静默 N 毫秒就认为一段消息结束（应用层读分帧，你的主场）。
> ⚠️ 类比边界：网络 idle timeout 是软件定时器、时间可配；IDLE 的判定窗口固定为一个字符时间，中间任何字节都会重置计时——所以「帧内间隔 > 一字符时间」的流会被错误切帧，这是本章实验②要控制的变量。

UART 是字节流，没有帧头帧尾。「变长帧怎么收」的经典答案：**线路静默一个字符时间，硬件置
SR.IDLE（bit4）**——空闲本身就是分隔符。用 DMA 收 + IDLE 报帧尾，一帧只进一次中断：

```text
CR1.IDLEIE=1（开 IDLE 中断）→ 帧到：DMA 静默逐字节搬进缓冲，CPU 不知情
→ 帧尾：线路静默一字符时间 → SR.IDLE 置位 → 进 USART1_IRQHandler
→ 清序（RM0090 规定）：先读 SR、再读 DR（各一次，顺序不可反）
→ 帧长 = RX_BUF_SIZE − NDTR（搬运单还剩几项，就是没来的字节）
→ 重挂 stream（EN=0→NDTR 重装→EN=1），等下一帧
```

两个易翻车点：①IDLE 的清除序列是「读 SR+读 DR」**两步**，与 ORE 同款（ORE=Overrun Error
溢出错误，DR 没被及时读走、新字节覆盖时置位；ch06 的教训直接复用）；②ch06 的 RXNE 中断
（RXNE=Receive data register Not Empty，「DR 里有字节待读」标志）在 DMA 版必须**关掉**——
RXNE 由 DMA 读 DR 消化，人再开 RXNEIE 就是不让 DMA 干活还要挨每字节一鞭的中断风暴
（interrupt storm——你的主场：软中断风暴的硬件版）。

## 实验：定长块、变长帧、空转计数器

```c
#define RX_BUF_SIZE 64u
static uint8_t g_dma_rx[RX_BUF_SIZE] __attribute__((aligned(4))); /* ch13 会把它搬进 CCM 翻车 */
static volatile uint32_t g_free;      /* 空转计数器：主循环唯一工作就是自增 */
static volatile uint32_t g_rx_cnt, g_tx_cnt, g_idle_cnt, g_tc_cnt, g_te_cnt;

static void dma_tx_start(const uint8_t *buf, uint32_t len)   /* M2S：内存→外设 */
{
    DMA2_Stream7->CR &= ~DMA_SxCR_EN;
    while (DMA2_Stream7->CR & DMA_SxCR_EN) { }               /* 等硬件确认摘机 */
    DMA2->HIFCR = DMA_HIFCR_CTCIF7 | DMA_HIFCR_CHTIF7 | DMA_HIFCR_CTEIF7
                | DMA_HIFCR_CDMEIF7 | DMA_HIFCR_CFEIF7;      /* 清挂起，防幽灵中断 */
    DMA2_Stream7->M0AR = (uint32_t)buf;
    DMA2_Stream7->NDTR = len;
    DMA2_Stream7->CR  |= DMA_SxCR_EN;                        /* 提交搬运单（提交即异步） */
}

static void dma_rx_rearm(void)                               /* 重挂 RX：S2 Ch4 */
{
    DMA2_Stream2->CR &= ~DMA_SxCR_EN;
    while (DMA2_Stream2->CR & DMA_SxCR_EN) { }
    DMA2->LIFCR = DMA_LIFCR_CTCIF2 | DMA_LIFCR_CHTIF2 | DMA_LIFCR_CTEIF2
                | DMA_LIFCR_CDMEIF2 | DMA_LIFCR_CFEIF2;
    DMA2_Stream2->NDTR = RX_BUF_SIZE;
    DMA2_Stream2->CR  |= DMA_SxCR_EN;
}

void DMA2_Stream2_IRQHandler(void)      /* RX 完成：定长块满了（实验①） */
{
    if (DMA2->LISR & DMA_LISR_TCIF2) {
        DMA2->LIFCR = DMA_LIFCR_CTCIF2;
        g_tc_cnt++; g_rx_cnt += RX_BUF_SIZE;
        dma_tx_start(g_dma_rx, RX_BUF_SIZE); /* 回显整块；host 是请求-应答节奏，无覆盖竞态 */
        dma_rx_rearm();
    }
    if (DMA2->LISR & DMA_LISR_TEIF2) { DMA2->LIFCR = DMA_LIFCR_CTEIF2; g_te_cnt++; }
}

void USART1_IRQHandler(void)            /* IDLE：变长帧的句号（实验②） */
{
    if (USART1->SR & USART_SR_IDLE) {
        (void)USART1->SR;               /* 清序前半：读 SR */
        (void)USART1->DR;               /* 清序后半：读 DR（读到的是 DMA 搬走的旧字节，弃） */
        DMA2_Stream2->CR &= ~DMA_SxCR_EN;
        while (DMA2_Stream2->CR & DMA_SxCR_EN) { }
        uint32_t len = RX_BUF_SIZE - DMA2_Stream2->NDTR;     /* 帧长反算：64−剩余 */
        DMA2->LIFCR = DMA_LIFCR_CTCIF2 | DMA_LIFCR_CHTIF2 | DMA_LIFCR_CTEIF2
                    | DMA_LIFCR_CDMEIF2 | DMA_LIFCR_CFEIF2;
        if (len) {
            g_idle_cnt++; g_rx_cnt += len;
            dma_tx_start(g_dma_rx, len);
        }
        DMA2_Stream2->NDTR = RX_BUF_SIZE;
        DMA2_Stream2->CR |= DMA_SxCR_EN;
    }
}

static void dma_usart_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_DMA2EN;

    DMA2_Stream2->CR = 0;                /* RX：S2 Ch4，P2M，字节，MINC，TC/TE 中断 */
    while (DMA2_Stream2->CR & DMA_SxCR_EN) { }
    DMA2_Stream2->PAR  = (uint32_t)&USART1->DR;
    DMA2_Stream2->M0AR = (uint32_t)g_dma_rx;
    DMA2_Stream2->NDTR = RX_BUF_SIZE;    /* DIR=00、PSIZE/MSIZE=00、CIRC=0：复位默认即所需 */
    DMA2_Stream2->CR = (4u << 25) | (1u << 16)      /* CHSEL=4、PL=中 */
                     | DMA_SxCR_MINC | DMA_SxCR_TCIE | DMA_SxCR_TEIE;

    DMA2_Stream7->CR = 0;                /* TX：S7 Ch4，M2P——只有 DIR 差一位 */
    while (DMA2_Stream7->CR & DMA_SxCR_EN) { }
    DMA2_Stream7->PAR  = (uint32_t)&USART1->DR;
    DMA2_Stream7->CR = (4u << 25) | (1u << 16) | (1u << 6)   /* DIR=01：内存→外设 */
                     | DMA_SxCR_MINC | DMA_SxCR_TCIE | DMA_SxCR_TEIE;

    NVIC->IP[58] = 0x60;  NVIC->ISER[1] = (1u << 26);  /* DMA2_Stream2=IRQ58 */
    NVIC->IP[70] = 0x60;  NVIC->ISER[2] = (1u << 6);   /* DMA2_Stream7=IRQ70；0x60 的伏笔见 ch12 */

    USART1->CR1 &= ~USART_CR1_RXNEIE;    /* 关 ch06 的每字节中断：DMA 接管读 DR */
    USART1->CR1 |= USART_CR1_IDLEIE;     /* 只留 IDLE 一根线 */
    USART1->CR3 |= USART_CR3_DMAR | USART_CR3_DMAT;  /* USART 侧放行收/发 DMA 请求 */

    DMA2_Stream2->CR |= DMA_SxCR_EN;     /* 最后开门：先装锁后开锁 */
}

int main(void)
{
    clock_init(); uart_init(); dma_usart_init();
    uint32_t last = 0, free_last = 0;
    for (;;) {
        g_free++;                        /* 空转计数器：DMA 干活时它照样涨 */
        if (g_ms - last >= 1000u) {      /* 每秒统计一行（g_ms=ch01 地基） */
            last += 1000u;
            uart_puts("[DMA] loops=");  uart_putdec(g_free - free_last);
            uart_puts(" rx=");           uart_putdec(g_rx_cnt);
            uart_puts(" tx=");           uart_putdec(g_tx_cnt);
            uart_puts(" tc=");           uart_putdec(g_tc_cnt);
            uart_puts(" idle=");         uart_putdec(g_idle_cnt);
            uart_puts(" te=");           uart_putdec(g_te_cnt);
            uart_puts("\r\n");
            free_last = g_free;
        }
    }
}
```

> 📖 **术语卡：NVIC（Nested Vectored Interrupt Controller，嵌套向量中断控制器）**
> **是什么**：Cortex-M 内核自带的中断控制器——每个中断源有固定 IRQ 编号，NVIC 负责使能（ISER 寄存器组）、优先级（IP 寄存器组）、挂起与向量化跳转（直接进对号的处理函数，无需软件判源）。
> **为什么存在**：让「开/关某个中断」和「谁先谁后」有统一的硬件入口；M4 用 4 位优先级（0–15，数值越小越优先），不同优先级可互相打断（嵌套）。
> **类比**：硬件版的 IRQ 路由 + 优先级队列；向量表≈中断的服务注册表（你的主场）。
> ⚠️ 类比边界：没有软件负载均衡可言——哪个 IRQ 进哪个 handler 是芯片定死的向量号，改不了亲和性。

**命令拆解：** `DMA2_Stream2->CR = (4u << 25) | (1u << 16) | DMA_SxCR_MINC | DMA_SxCR_TCIE | DMA_SxCR_TEIE;`（RX 流的控制字拼装）

| 部分            | 作用                                                                 |
| --------------- | -------------------------------------------------------------------- |
| `4u << 25`      | 把 100b 写进 bit27:25 → CHSEL=4：选 USART1_RX 的请求线（路由表查得） |
| `1u << 16`      | 把 01b 写进 bit17:16 → PL=中：流间仲裁优先级                         |
| `DMA_SxCR_MINC` | bit9：内存地址每搬一项递增（缓冲区逐格填）                           |
| `DMA_SxCR_TCIE` | bit4：传输完成（NDTR 数到 0）中断使能                                |
| `DMA_SxCR_TEIE` | bit3：传输错误中断使能                                               |
| 未写的位        | 保持复位默认：DIR=00 外设→内存、PSIZE/MSIZE=00 字节宽、CIRC=0        |

**对照**：TX 流那行多一个 `(1u << 6)`（bit7:6=01，DIR=内存→外设），少 MINC 之外的差异全同——
「只有 DIR 差一位」的具象化。寄存器快照里的 0x0801_0415/0x0801_0455 就是这两行的位叠加结果
（差异位正是 bit6）。

**命令拆解：** `NVIC->IP[58] = 0x60; NVIC->ISER[1] = (1u << 26);`（开 DMA2_Stream2 的中断）

| 部分            | 作用                                                                        |
| --------------- | --------------------------------------------------------------------------- |
| `NVIC->IP[58]`  | Interrupt Priority 数组按 IRQ 号下标；58=DMA2_Stream2 在向量表里的编号      |
| `0x60`          | 优先级字节；M4 只实现高 4 位，0x60>>4=优先级 6（0x60 的伏笔见 ch12）        |
| `NVIC->ISER[1]` | Interrupt Set-Enable Register 第 1 组（每组管 32 个 IRQ：0–31/32–63/64–95） |
| `(1u << 26)`    | 组内位号：32×1+26=IRQ58——写 1 即使能（同组写 0 无效，关闭要用 ICER）        |

**对照**：S7 的两行 `NVIC->IP[70]=0x60; NVIC->ISER[2]=(1u<<6);` 同一套算法：70=32×2+6。
**你会看到**：ISER 位一旦写过 1，对应中断到即跳 `DMA2_Stream2_IRQHandler`（向量号定死，不需判断来源）。
**失败了先查**：中断「不响」先 `mdw` 读回 ISER 对应位（OpenOCD 读内存命令，一次 4 字节）——忘了写使能是最常见事故；其次查 TCIE/TEIE 是否真写进 CR。

**命令拆解：** IDLE 中断里的清序与帧长反算四行

| 部分                        | 作用                                                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `(void)USART1->SR;`         | 清 IDLE 的第一步：读一次 SR（状态寄存器）                                                                                |
| `(void)USART1->DR;`         | 第二步：读一次 DR——顺序不可反；读到的是 DMA 搬走的旧字节，弃                                                             |
| `(void)` 强转               | 告诉编译器「读了不用」；SR/DR 是 volatile 指针，读动作不会被优化掉（你的主场：与信号处理器共享变量同一个 volatile 语义） |
| `len = RX_BUF_SIZE - NDTR;` | 帧长反算：搬运单发 64 项、NDTR 是剩余项数，64−剩余=已到字节数                                                            |

**你会看到**：一帧只进一次 USART1 中断，`idle` 计数 +1、`rx` 增帧长——没有每字节中断。
**失败了先查**：少读 DR 一版（待核对清单第 4 项）——IDLE 清不掉就是中断风暴；其次 ISER/IDLEIE 漏开。

代码里另外三个小注：`__attribute__((aligned(4)))`（GNU 扩展：强制 `g_dma_rx` 数组 4 字节对齐，
配合后续字/半字访问不栽对齐坑）；注释里预告的 CCM（Core Coupled Memory，内核紧耦合 RAM——
只有 CPU 能访问、DMA 总线矩阵根本连不到它，ch13 会故意把缓冲搬进去翻车）；`g_free` 等加
`volatile`（ISR 与主循环共享的计数器，禁止编译器缓存/合并读写）。

（TX 侧完成中断省略统计逻辑；`g_tx_cnt` 在 TX TC 里累加。主机侧脚本：实验①发 64B 块、收 64B
回显、立刻下一轮——请求-应答节奏下 RX/TX 分时复用同一缓冲，无需乒乓（乒乓 ping-pong：两块
缓冲轮流当「正在写」与「可安全读」，写读永不碰同一块）；若做连续双向流，缓冲
会读写相撞，工业解法是 M1AR 双缓冲（DBM）或 HT/TC 半区乒乓——思想在 ch11 展开。）

实验②的主机侧：每 100ms 发一帧随机 8–60 字节、间隔大于一字符时间；帧长超 64B 时 TC 先到，
固件按整块回显后把尾巴当新帧——降级行为如实记账，主机脚本控制帧长 ≤64。

## 预期输出（待实测核销）

```text
── 实验①：定长块回显（host 发 64B/收 64B，持续 10s）──
host 侧：64 次往返（每轮 ≈5.6ms 发+5.6ms 收+翻转），回显逐字节 diff 一致
[DMA] loops=35,98xx,xxx rx=4096 tx=4096 tc=64 idle=0 te=0      ← 计数率见下表推导

── 实验②：IDLE 变长帧（每 100ms 一帧 8–60B，60 帧）──
host 侧：每帧回显长度与内容一致；无粘连（IDLE 分帧生效）
[DMA] ... rx=1893 tx=1893 tc=0 idle=60 te=0                    ← 1893=60 帧均值 31.5B 的推导值

── 实验③：空转计数率（10s 均值）──
空载基线        loops≈36,000,000/s   ← 主循环 ≈5 周期/迭代（LDR/STR/ADD/B，Flash 预取下）
DMA 版@同流量   loops≈35,99x,xxx/s   ← 与空载差 <0.1%（推导：83 块/s×2 中断×≈百周期）
ch06 中断版@满线速双工（11520B/s×2） 中断税 ≈2.3M 周期/s ≈1.3%  ← ch06 0.7% 账的 RX+TX 双侧版
外推 921600 baud 满线速：中断版 ≈10% CPU vs DMA 版 ≈0.02%      ← 「按字节计税→按块计税」
```

（输出块里几个词：loops=主循环空转自增次数，是「CPU 空闲度」的代理指标；「Flash 预取」=Flash
读取跟不上 180MHz 内核，靠预取缓冲提前取指令藏延迟——空转循环体小、几乎全程在预取缓冲里跑，
所以能压到 ≈5 周期/迭代；tc/idle/te 分别是传输完成/空闲/错误三类中断的计数。）

寄存器侧快照（空载活体 `mdw`；`mdw`=OpenOCD 读内存命令、一次 4 字节，「活体」=程序继续跑着
读，不是停下来 dump）：

| 地址       | 寄存器      | 预期值      | 推导                                     |
| ---------- | ----------- | ----------- | ---------------------------------------- |
| 0x40026440 | DMA2_S2CR   | 0x0801_0415 | CHSEL4+PL01+MINC+TCIE+TEIE+EN（DIR=00）  |
| 0x40026488 | DMA2_S7CR   | 0x0801_0455 | 同上+DIR=01                              |
| 0x40026444 | DMA2_S2NDTR | 0x0000_0040 | 重挂后的满装 64（空闲时刻）              |
| 0x4001100C | USART1_CR1  | 0x0000_2020 | UE+IDLEIE；RXNEIE 已清（对照 ch06 快照） |
| 0x40011014 | USART1_CR3  | 0x0000_00C0 | DMAR+DMAT                                |
| 0xE000E104 | NVIC_ISER1  | 0x0000_0400 | IRQ58 → bit26                            |

## 与 FreeRTOS / lwIP 对照

- 收发路径从此分层：**数据面走 DMA，控制面走中断**——正是
  [[2026-08-26-lwip-deep-dive-ch17-ethernetif-porting-guide|lwIP（十七）：ethernetif 移植]]
  里网卡驱动的骨架：EMAC（以太网 MAC 控制器）DMA 收包入 pbuf（lwIP 的包缓冲结构——你的
  主场）、中断只报事件。阶段 5 的以太网大戏（ch20/21）
  会把这章的手势原样放大。
- DMA 生产者 + 任务消费者 = ch06 SPSC 环（single-producer single-consumer 单生产者单消费者
  环形缓冲——你的主场）的 DMA 版：head 不再由 ISR 推进，而由硬件按搬运单
  推进。任务侧「环空则睡、环非空则唤」的封装即
  [[2026-08-26-freertos-deep-dive-ch14-stream-message-buffers|FreeRTOS（十四）：Stream 与 Message Buffer]]；
  DMA 中断里唤醒任务的契约（优先级 ≥5）在 ch12 专题拆解。
- M2M 只有 DMA2 能做、且 CIRC/FIFO burst 禁用——异步 memcpy 的能力边界，AN4031（ST 应用笔记
  《Using the STM32F2 and STM32F4 DMA controller》，DMA 用法的官方权威文档）有全表；
  「提交搬运单、完成通知」的编程模型对照 io_uring 的 SQE/CQE：同步轮询 NDTR 是 busy-wait，
  TCIE 才是完成事件。

## 本章待核对清单

| #   | 项                                                      | 核对方法                                   |
| --- | ------------------------------------------------------- | ------------------------------------------ |
| 1   | USART1_RX=DMA2 S2 C4 / TX=S7 C4（本文已自查，实跑终验） | `mdw` 读 S2CR/S7CR 的 CHSEL 位段           |
| 2   | 空转计数率推导（≈36M/s）与实测偏差                      | 空载 10s 均值标定，反推每迭代周期数        |
| 3   | DMA 版与空载计数率「无差别」假说                        | 同流量 10s 对照，差异 >0.5% 即学习点       |
| 4   | IDLE 清序（读 SR+读 DR）实测有效性                      | 少读 DR 一版对照：预期 IDLE 不清、中断风暴 |
| 5   | 超 64B 帧的降级行为（TC 整块回显+尾巴成新帧）           | host 发 100B 帧观察回显切分                |
| 6   | RXNEIE 残留会否中断风暴（关漏一行的人为 bug 版）        | 对照组实验，`reg pc` 抓在 ISR 里打转       |
| 7   | 寄存器快照六项                                          | `mdw` 逐行对照                             |

上一章：[[2026-08-30-f429-lab-ch09-rpi-piscope-logic-analyzer|波形之眼：树莓派穷人逻辑分析仪]]；
下一章：[[2026-08-30-f429-lab-ch11-adc-dma-double-buffer|ADC+DMA 双缓冲：无 CPU 的采样流]]——
把本章的 HT/TC 两个位变成主角。系列总目录见[[2026-08-30-f429-lab-series-index|F429 裸机实验室索引]]。
