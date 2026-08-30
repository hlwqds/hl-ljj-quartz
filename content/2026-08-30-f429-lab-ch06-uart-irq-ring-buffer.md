---
title: UART 进阶：中断驱动与环形缓冲
date: 2026-08-30 03:25:00
description: F429 裸机实验室（六）——RXNE 中断接收 + 单生产者单消费者无锁环形缓冲，缓冲调小的溢出推挤实验，ORE/FE 错误位的处理责任
tags: [STM32, CortexM, UART, Lab]
---

# UART 进阶：中断驱动与环形缓冲

> **状态声明**：本章属「先成文、后实跑」——实验设计与寄存器推导已写定，但**尚未在真机上执行**；
> 所有「预期输出」均为待实测核销的推导值（丢帧数、高水位等均为算术推导，非实测）。
> 起点=序章工程已验证的 TX 轮询版 UART（BRR=0x30D 沿用不动），本章在其上开中断。
> 方法论与工具链继承[[2026-08-30-stm32f429-brick-rescue-debug-story|序章]]。

## 本章装备清单

| 分类       | 装备                    | 价格/状态 | 用途                   |
| ---------- | ----------------------- | --------- | ---------------------- |
| 已有       | 挑战者 F429-V2 板       | ✅        | 实验主体               |
| 已有       | 野火 DAP 仿真器         | ✅        | 烧录/调试              |
| 已有       | Mini-USB 线             | ✅        | 供电 + 串口            |
| 已有       | 笔记本（Fedora 工具链） | ✅        | 编译/烧录/串口终端     |
| 沿用基础盘 | 无新增                  | —         | 板载串口即本章实验对象 |

## 本章会遇到的词

| 词                    | 一句话版                                            | 详见              |
| --------------------- | --------------------------------------------------- | ----------------- |
| UART                  | 两根线的异步串口，逐 bit 收发字节，靠约定波特率对拍 | 「目标」节        |
| 波特率 / 8N1          | 每秒多少 bit；8 数据位+无校验+1 停止位的帧格式      | 「账单」节        |
| RXNE / TXE            | 「收到了」「可发了」两个状态标志位                  | 「原理下钻」节    |
| ORE / FE / NE / PE    | 溢出/帧/噪声/校验，四类错误标志位                   | 「原理下钻」节    |
| 中断 / ISR            | 硬件事件打断 CPU / 处理它的小函数                   | 「原理下钻」节    |
| NVIC                  | 内核里管中断开关、优先级、跳转地址的部件            | 「原理下钻」节    |
| 环形缓冲              | 首尾相接的数组队列，读写指针各自前进                | 「SPSC 无锁环」节 |
| SPSC 无锁             | 单生产者单消费者，不关中断不上锁也不丢数据          | 「SPSC 无锁环」节 |
| `volatile` / 内存屏障 | 挡住编译器优化 / 强制写入顺序对外可见               | 「SPSC 无锁环」节 |
| 高水位（maxw）        | 缓冲占用量的历史峰值，容量规划的依据                | 「实验」节        |

> 📖 **术语卡：UART（Universal Asynchronous Receiver/Transmitter，通用异步收发器）**
> **是什么**：两根信号线（TX 发、RX 收）逐 bit 传输字节的异步串口；没有时钟线，双方各按同一
> 波特率数拍子来对齐每一位。
> **为什么存在**：最便宜的两点通信——一个方向一根线外加共地即可，芯片间、板间、调试口全用它。
> **类比**：路由器/交换机背后那个 115200 8N1 的 console 口，跑的就是 UART；引到 USB 才轮到 CH340 芯片。
> ⚠️ 类比边界：telnet/SSH 登录设备时走的是 IP 网络栈；UART 是它脚底下那层物理串口。

## 目标（先说结论）

- 序章的 `uart_puts` 是忙等 TXE（Transmit Empty，发送寄存器已空——硬件举手「可以塞下一字节了」
  的标志位）的轮询版——**每发一个字节 CPU 全程陪跑**。本章把串口升级为
  标准形态：**RXNE（Receive Not Empty，接收寄存器非空——硬件举手「收到一字节了」的标志位）中断接收
  进环形缓冲 + 主循环消费**，TX 侧给「TXE 中断发」骨架，DMA（Direct Memory Access，外设与内存间
  不经 CPU 的直达搬运通道，ch10 的主角）版留给 ch10。
- 主角是**单生产者单消费者（SPSC，Single-Producer Single-Consumer）无锁环**：ISR（Interrupt
  Service Routine，中断服务函数——事件触发后 CPU 自动跳进来执行的小函数）是唯一写 head 的生产者、
  主循环是唯一写 tail 的消费者——为什么不用关中断（把中断一刀切屏蔽掉换取互斥，最粗暴的临界区手段）
  不用锁也不丢数据，一页论证清楚（与 socket 收包路径同构，你的主场）。
- 三个实验：①回显（收什么回什么）；②**故意把缓冲调小 + 拖慢消费者**，看溢出时「丢新 vs 丢旧」
  两种策略的实际行为；③每秒收发字节统计。外加 UART 错误位（ORE 溢出/NE 噪声/FE 帧错/PE 校验错，
  四个硬件错误标志位，见「原理下钻」）的处理责任。

## 系统侧类比：socket 收包路径的微缩版

（右列全是你的主场——本表只锚定左右两边的对应关系，不展开。）

| UART 环形缓冲侧           | 系统侧对应                                          |
| ------------------------- | --------------------------------------------------- |
| RXNE 中断：每字节一次 ISR | 网卡硬中断收包（古老的中断 per-packet 模式）        |
| 环形缓冲（buf+head+tail） | sk_buff 队列 / socket 接收缓冲（rcvbuf 的底层形态） |
| ISR 入队（推进 head）     | 硬中断/softirq 入队 backlog                         |
| 主循环出队（推进 tail）   | NAPI poll / 应用 read() 消费                        |
| 溢出丢新（drop new）      | pfifo_fast 默认 tail-drop：队满丢最新               |
| 溢出丢旧（drop old）      | 音频 jitter buffer 的取舍：保延迟，丢旧帧           |
| ORE 溢出标志              | RX ring overrun：驱动没及时搬走，硬件层丢包计数器   |

一句话：本章是 Linux 收包路径 `NIC → IRQ → backlog → NAPI poll → app` 的 60 行微缩版，
实验二把「处理速率」压低，等价于给 netdev 人为限速看 qdisc 丢包计数。

## 现状：轮询 TX 的账单

8N1（8 数据位、N 无校验、1 停止位，再加一个固定为 0 的起始位——每字节线上恰好 10 bit）每字节
10 bit，115200 baud（波特率：每秒线上跑多少 bit——异步口没有时钟线，收发双方必须约好同一个数）
→ **86.8µs/字节、11520 字节/秒**。ch01 每秒一行 `beat N g_ms=...`
（约 20 字节）= CPU 忙等 **约 1.74ms**——「发多少陪多少」的线性税，ch21 的 lwIP 打日志、ch22
灌吞吐时第一个撑不住。RX 侧更糟：**轮询接收根本收不全**——不看 RXNE 的间隙里来两个字节，
第二个就把 ORE 顶出来。中断 + 缓冲不是优化，是功能正确性的前提。

## 原理下钻

### USART1 的中断相关寄存器

基址 `0x40011000`（寄存器块在 4GB 内存地图里的起始地址——STM32 的外设是「内存映射寄存器」，
读写某个地址就是读写外设本体；挂在 APB2——Advanced Peripheral Bus 2，芯片内部一条中速外设总线，
其总线时钟 PCLK2=90MHz；ch05 总线图上 APB2 桥后面的坐标）：

| 偏移    | 寄存器 | 本章用到的位                                                       |
| ------- | ------ | ------------------------------------------------------------------ |
| `+0x0`  | SR     | RXNE(5)、TXE(7)、ORE(3)、FE(1)、NE(2)、PE(0)、IDLE(4，ch10 的主角) |
| `+0x4`  | DR     | 读写各一字节缓冲；读 DR = 清 RXNE                                  |
| `+0x8`  | BRR    | 0x30D（115200@90MHz，序章已验证，不动）                            |
| `+0xC`  | CR1    | RXNEIE(5)、TXEIE(7)、UE(13)/TE(3)/RE(2)（序章已配）                |
| `+0x14` | CR3    | EIE(0)：FE/ORE/NE 错误中断使能                                     |

> 📖 **术语卡：NVIC（Nested Vectored Interrupt Controller，嵌套向量中断控制器）**
> **是什么**：Cortex-M 内核里统管中断的部件：谁能触发（使能位 ISER）、谁先谁后（优先级寄存器 IP）、
> 触发后跳到哪（向量表）全归它管。
> **为什么存在**：外设只能举手；真正打断 CPU、自动压栈现场、按 IRQ 号查表跳转的是内核这套机构。
> **类比**：你的主场——相当于内核 IRQ 子系统的硬件前身：写向量表≈request_irq 注册 handler，
> 置 ISER 位≈enable_irq。
> ⚠️ 类比边界：NVIC 没有软件分层也没有线程概念，ISR 里不能睡眠阻塞；优先级是硬件数值当场裁决。

使能链三层（ch02 八环的精简版）：`CR1.RXNEIE`（外设侧放行：外设自己「有事件要不要上报」的开关）
→ `NVIC ISER1 bit5`（IRQ37=USART1，CPU 侧放行：ISER=Interrupt Set-Enable Register，中断使能
寄存器，每 IRQ 占一位、32 个 IRQ 一组字，37-32=5 落在 1 号字的 bit5）→ 向量表（中断向量表：一张
按 IRQ 号排好序的函数地址数组，CPU 拿号查表即得跳转目标）`USART1_IRQHandler`。TX 侧同理但方向反过来。

### 错误位：谁负责清理

> 📖 **术语卡：ORE（Overrun Error，接收溢出错）**
> **是什么**：USART 的接收寄存器只有 1 字节深；上一个还没被软件读走、下一个又到了，硬件丢弃
> 新字节并置 ORE=1。
> **为什么存在**：它是「软件跟不上」最诚实的指示灯——测的是 CPU 读走数据的速度，不是线上信号质量。
> **类比**：网卡 RX ring overrun——ring 满，ethtool 统计里的 rx_missed/rx_no_buffer 计数器。
> ⚠️ 类比边界：网卡 ring 是一整圈 descriptor、动辄上千字节余量；这里只有 1 字节，从满到丢零余量。

四个错误位就是四类事故：**FE**（帧错误：起始位采样点不是 0——波特率偏差/地弹）、**NE**
（噪声：采样点三次表决不一致）、**ORE**(溢出：DR 没及时读、新字节被硬件丢弃)、**PE**
（校验错，8N1 下不会出现）。责任归属：

1. 它们**不会自己消失**——ORE/NE/FE 靠「读 SR 再读 DR」序列清除；PE 靠读 SR+DR 加 EIE/PEIE。
2. **ORE 不清会中断风暴**：ORE=1 且 RXNEIE=1 时中断反复重入。我们 ISR 的第一行就是读 SR
   快照、随后必然读 DR——清除序列天然嵌进正常路径，这是本章 ISR 写成「先读 SR 后读 DR」的原因。
3. 错误字节**不入环只记账**：FE 的字节大概率是残缺帧，把它当数据回显只会污染流。

### SPSC 无锁环：头尾指针与内存屏障（一页）

> 📖 **术语卡：环形缓冲（Ring Buffer）**
> **是什么**：一段固定内存+两个指针（写头/读尾），写到头绕回尾，像钟表一样循环。
> **为什么存在**：生产者和消费者速度不同步时，中间垫一块有界缓冲，谁也不等谁。
> **类比**：socket 的收包缓冲——网卡（生产者）和应用程序（消费者）各走各的。
> ⚠️ 类比边界：socket 缓冲满了内核会丢包/背压，我们这个自己定策略（丢新或丢旧）。

```text
   生产者 USART1_IRQHandler（唯一写 head）：先写 buf[head&MASK]，后 head++（发布协议）
   ┌──────────────── 环形缓冲（2 的幂）────────────────┐
   │ ……已读区…… │ ……待读区…… │ ……空位…… │
   │       ▲tail（消费者推进）      ▲head（生产者推进） │
   └────────────────────────────────────────────────────┘
   消费者 main（唯一写 tail）：先读 buf[tail&MASK]，后 tail++

   空：head == tail        满：head - tail == RB_SIZE
   索引用 free-running uint32_t 永不取模回绕 → 减法即长度，无「满/空同形」歧义
```

免锁论证三条（对应系统侧「为什么 NIC ISR 和 softirq 抢队列不用锁」）：

1. **每个索引只有一个写者**。竞争只剩「读对方的索引」，而读永远不会破坏对方。
2. **读到旧值的后果是保守，不是越权**。生产者读到过时的 tail → 误判更满 → 提前丢/等
   （安全方向）；消费者读到过时的 head → 误判更空 → 这轮少拿一个，下轮补上（安全方向）。
   把竞态的后果约束在「只会更保守」，是不加锁的核心纪律。
3. **发布顺序：先写数据槽，再推进索引**。`volatile` 挡住编译器重排；CM4 单核下程序序
   实践上成立。严谨写法在两步之间加 `__DMB()`——ARM 文档里真正会咬人的是 M7 的写缓冲；
   一旦写索引的换成 DMA 或另一个核（ch10 的 DMA 环、FreeRTOS 多核），DMB 从礼貌变必需，
   详见[[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|FreeRTOS（十八）：临界区契约]]。

尾注：11520 字节/秒下 uint32_t 索引约 4.3 天回绕一次，回绕瞬间减法依然正确（模 2^32 算术）。

补一笔下标算术：代码里 `head & RB_MASK` 用「按位与」代替除法取模——前提是容量为 2 的幂
（`RB_SIZE-1` 恰好是低 n 位全 1 的掩码，与运算直接砍掉高位）。这就是环容量取 256/16 这类数的
工程原因；free-running（自由递增、永不归零回绕）索引+掩码取下标，两件事是配套使用的。

## 实验：回显、溢出推挤、吞吐统计

### 接收环与发送环（同构、方向镜像）

```c
/* ---------- 两个 SPSC 环：RX 环 ISR 生产/主循环消费；TX 环主循环生产/ISR 消费 ---------- */

#define RB_SIZE 256u                 /* 2 的幂；溢出实验改 16u */
#define RB_MASK (RB_SIZE - 1u)
#define RB_POLICY_DROP_NEW 0         /* 满：拒收新字节（qdisc tail-drop 同款） */
#define RB_POLICY_DROP_OLD 1         /* 满：覆盖最老字节（实时流保新鲜） */
#define RB_POLICY RB_POLICY_DROP_NEW

static volatile uint8_t  g_rx_buf[RB_SIZE];
static volatile uint32_t g_rx_head, g_rx_tail;   /* head 只由 ISR 写；tail 只由 main 写 */
static volatile uint32_t g_rx_drop, g_maxw;      /* 丢字节计数；缓冲高水位（呼应 ch16 高水位） */

static void rb_put(uint8_t b)                    /* 生产者：只在 ISR 里调用 */
{
#if RB_POLICY == RB_POLICY_DROP_OLD
    /* 丢旧版：满了照写、覆盖最老字节；tail 依然不归生产者碰（不变量不破）——被覆盖的
       旧字节由消费者追赶时认亏（rb_get 滞后检查，perf 环形缓冲同款语义） */
    g_rb_buf[g_rb_head & RB_MASK] = b;
    g_rb_head = g_rb_head + 1u;
#else
    uint32_t head = g_rb_head;
    if (head - g_rb_tail == RB_SIZE) {           /* 丢新版：满则拒收，字节蒸发，计数器留名 */
        g_rx_drop++;
        return;
    }
    g_rb_buf[head & RB_MASK] = b;                /* 先写数据…… */
    g_rb_head = head + 1;                        /* ……后推进索引（发布协议） */
#endif
}

static int rb_get(uint8_t *out)                  /* 消费者：只在 main 里调用 */
{
    uint32_t tail = g_rb_tail;
#if RB_POLICY == RB_POLICY_DROP_OLD
    if (g_rb_head - tail > RB_SIZE) {            /* 滞后超过一圈：被覆盖的旧字节认亏丢弃 */
        g_rx_drop += (g_rb_head - tail) - RB_SIZE;
        tail = g_rb_head - RB_SIZE;              /* 跳到最老幸存字节 */
    }
#endif
    if (g_rb_head == tail) return 0;
    if (g_rb_head - tail > g_maxw) g_maxw = g_rb_head - tail;  /* 高水位消费侧顺便量 */
    *out = g_rb_buf[tail & RB_MASK];
    g_rb_tail = tail + 1u;                       /* 取走数据后再推进 tail */
    return 1;
}

#define TX_SIZE 256u
static volatile uint8_t  g_tx_buf[TX_SIZE];
static volatile uint32_t g_tx_head, g_tx_tail;   /* 镜像：head 只由 main 写，tail 只由 ISR 写 */

static void tx_push(uint8_t b)
{
    while (g_tx_head - g_tx_tail == TX_SIZE) { } /* 满则等——本章 TX 量小，忙等可接受；
                                                    RTOS 版这里是任务阻塞点（对照节） */
    g_tx_buf[g_tx_head & (TX_SIZE - 1u)] = b;
    g_tx_head++;
    USART1->CR1 |= USART_CR1_TXEIE;              /* 投完必重开 TXEIE——见正文竞态 */
}
```

### 中断服务与主循环

```c
static volatile uint32_t g_rx_cnt, g_tx_cnt, g_uart_err;

static void ring_uart_irq_init(void)
{
    USART1->CR3 |= USART_CR3_EIE;                /* FE/ORE/NE 错误中断（8N1 无 PE 的事） */
    NVIC->IP[37] = 0x40;                         /* 次于 SysTick 的 0：串口风暴别拖慢毫秒时基 */
    NVIC->ISER[1] = (1u << (37u - 32u));         /* IRQ37 → ISER1 bit5 = NVIC_EnableIRQ(USART1_IRQn) */
    USART1->CR1 |= USART_CR1_RXNEIE;             /* 最后开门：先装锁后开锁的顺序纪律 */
}

void USART1_IRQHandler(void)
{
    uint32_t sr = USART1->SR;                    /* 先读 SR：快照错误位；顺带构成清 ORE 序列前半 */
    if (sr & USART_SR_RXNE) {
        uint8_t b = USART1->DR;                  /* 读 DR 清 RXNE；ORE 场景下顺带清掉 ORE */
        g_rx_cnt++;
        if (sr & (USART_SR_ORE | USART_SR_FE | USART_SR_NE)) g_uart_err++; /* 脏字节 */
        else rb_put(b);                          /* 干净字节才入环 */
    }
    if ((sr & USART_SR_TXE) && (USART1->CR1 & USART_CR1_TXEIE)) {
        if (g_tx_head != g_tx_tail) {
            USART1->DR = g_tx_buf[g_tx_tail & (TX_SIZE - 1u)]; /* 消费 TX 环 */
            g_tx_tail++;
            g_tx_cnt++;
        } else {
            USART1->CR1 &= ~USART_CR1_TXEIE;     /* 空环必须自关：TXE 恒 1，开着就是中断风暴 */
        }
    }
}

int main(void)
{
    clock_init();
    uart_init();                                 /* 序章版：UE/TE/RE + BRR=0x30D 原样 */
    ring_uart_irq_init();                        /* SysTick 已在跑（ch01 的 g_ms 地基） */

    uint32_t last_stat = 0;
    uint32_t rx_last = 0, tx_last = 0;
    for (;;) {
        uint8_t b;
        uint32_t n = 0;
        while (n < 8u && rb_get(&b)) { tx_push(b); n++; }   /* 回显：每轮最多搬 8 字节 */
        delay_ms(5);                             /* 溢出实验开关：注释掉=全速消费者 */
        if (g_ms - last_stat >= 1000u) {         /* 每秒统计一行 */
            last_stat += 1000u;
            uart_puts("[STAT] rx=");  uart_putdec(g_rx_cnt - rx_last);
            uart_puts(" tx=");        uart_putdec(g_tx_cnt - tx_last);
            uart_puts(" drop=");      uart_putdec(g_rx_drop);
            uart_puts(" err=");       uart_putdec(g_uart_err);
            uart_puts(" maxw=");      uart_putdec(g_maxw);
            uart_puts("\r\n");
            rx_last = g_rx_cnt; tx_last = g_tx_cnt;
        }
    }
}
```

**初始化三行的账**（`ring_uart_irq_init`）：`NVIC->IP[37] = 0x40`——IP 是优先级寄存器数组
（Interrupt Priority，每 IRQ 一字节，STM32 只用高 4 位，0x40 即优先级 4；数值越小越优先，故排在
SysTick 的 0 之后，串口风暴拖不垮毫秒时基）；`NVIC->ISER[1] = 1u << 5`——ISER 每 32 个 IRQ 分
一组字，IRQ37 落在第 2 组的 bit5，等价于库函数 `NVIC_EnableIRQ(USART1_IRQn)`；最后一行才开
`RXNEIE`——先装好处理函数与中断控制器再放行事件，顺序反了就是「门开了没人接」。

**代码走读：`USART1_IRQHandler` 逐行**

| 行                                 | 在干什么                                                   |
| ---------------------------------- | ---------------------------------------------------------- |
| `sr = USART1->SR`                  | 进门先拍快照：RXNE/TXE 与四个错误位一次性读走              |
| `if (sr & USART_SR_RXNE)`          | 有新字节：读 DR（读动作顺带清 RXNE，ORE 场景连着清 ORE）   |
| `rb_put(b)`                        | 干净字节才入环；脏字节只 `g_uart_err++` 记账、不污染数据流 |
| `if ((sr & TXE) && (CR1 & TXEIE))` | 发送侧两条件与：TXE 空闲时恒 1，必须连「中断开着吗」一起判 |
| `USART1->DR = g_tx_buf[...]`       | 从 TX 环搬一字节进发送寄存器，`g_tx_tail++` 推进           |
| `USART1->CR1 &= ~USART_CR1_TXEIE`  | TX 环空立刻自关中断——开着就是 TXE 无限重入的风暴           |

**TXE 自关与重开的竞态**：ISR 见空环关中断、主循环随后又投了字节——若不在 `tx_push` 末尾
无条件重开 TXEIE，新字节会睡在环里直到下一笔 TX 唤醒它。「投完必开」让所有交错都收敛，
是 lock-free「唤醒不丢」的最小案例。

### 溢出推挤：主机侧怎么灌

```bash
# 笔记本侧（需 pyserial）：1024 字节突发，线上时间约 89ms
python3 - <<'EOF'
import serial
s = serial.Serial('/dev/ttyUSB0', 115200)
s.write(b'Z' * 1024)
EOF
```

**命令拆解：** `python3 - <<'EOF' … EOF`

| 部分                                    | 作用                                                                |
| --------------------------------------- | ------------------------------------------------------------------- |
| `python3 -`                             | 从 stdin 读脚本执行（`-` 在这里代表标准输入而非文件名）             |
| `<<'EOF' … EOF`                         | heredoc：两个 EOF 之间的文本整体喂给 stdin；带引号防 shell 展开内容 |
| `serial.Serial('/dev/ttyUSB0', 115200)` | 打开 USB 串口适配器的设备节点并配置波特率（需 pyserial 库）         |
| `s.write(b'Z' * 1024)`                  | 1024 个 'Z' 一口气塞进内核发送缓冲，USB 侧按线速甩给板子            |

**你会看到**：板上统计行 rx 增加 1024；`/dev/ttyUSB0` 是 Linux 给 USB 转串口芯片（本板为
CH340）的设备文件名，插拔后编号可能变成 ttyUSB1…。
**失败了先查**：`ls /dev/ttyUSB*` 在不在；报 `ModuleNotFoundError: No module named 'serial'` =
`pip3 install --user pyserial` 没装；Permission denied = 把用户加进 `dialout` 组再重新登录。

推导：线上 11520 字节/秒；慢消费者（每轮 8 字节 + 5ms 延时）≈ 1600 字节/秒。89ms 突发窗口内
到达约 1024 字节、搬走约 142 字节，窗口后再清空环里剩下的 16 字节——**总回显 ≈158，丢弃 ≈866**。
两种策略丢的**数量**相同，丢的**是谁**不同：丢新=最老的 158 字节幸存（host 侧看到前缀+静默），
丢旧=最新的 158 字节幸存（中间断层跳变）；丢单位也不同——丢新在生产者处记账，丢旧由消费者
追赶时认亏（代码里 `#if` 的两个分支）。

## 预期输出（待实测核销）

```text
── 实验 1：全速回显（delay_ms 注释掉，RB_SIZE=256，主机 1024B 突发）──
[STAT] rx=1024 tx=1024 drop=0 err=0 maxw=??      ← maxw 待实测：消费快于线速，预期个位数
host 侧回读字节流与发送内容逐字节一致（diff 对账）

── 实验 2：慢消费者 + 16 深缓冲（RB_SIZE=16，delay_ms(5) 在位）──
丢新：[STAT] rx=1024 tx=158 drop=866 err=0 maxw=16   ← 幸存=最老 158 字节：回显有前缀、无后缀
丢旧：[STAT] rx=1024 tx=158 drop=866 err=0 maxw=16   ← 计数全同；幸存=最新 158 字节：中间断层

── 实验 3：10 秒连续流（全速消费者，主机持续发）──
[STAT] rx=11520 tx=11520 drop=0 err=0 maxw=??    ← 11520=115200bit/s ÷ 10bit/字节，线速打满
```

寄存器侧快照（空载时刻活体 `mdw`——OpenOCD 的 memory-dump-word 命令：`mdw 0x4001100C` 按
32 位字读出该地址当前值，不暂停程序也能偷看外设状态的观察窗）：

| 地址       | 寄存器     | 预期值     | 推导                                            |
| ---------- | ---------- | ---------- | ----------------------------------------------- |
| 0x4001100C | USART1_CR1 | 0x0000202C | UE(13)+RXNEIE(5)+TE(3)+RE(2)；TXEIE(7) 时开时关 |
| 0x40011014 | USART1_CR3 | 0x00000001 | EIE                                             |
| 0x40011008 | USART1_BRR | 0x0000030D | 115200@90MHz（序章验证值，沿用）                |
| 0xE000E104 | NVIC_ISER1 | 0x00000020 | IRQ37 → bit5                                    |

`err` 计数是线上质量的体温计：持续为 0 = 波特率与地都稳；突发 FE → 先怀疑波特率偏差，
再怀疑共地（若引了外板）。ORE 只会在消费者慢到环满之后出现——它测的是**软件**，不是线。

## 与 FreeRTOS / lwIP 对照

- 这个环在 RTOS 里的官方身份是
  [[2026-08-26-freertos-deep-dive-ch14-stream-message-buffers|FreeRTOS（十四）：Stream 与 Message Buffer]]：
  同一颗 SPSC 环加「环空则睡、环非空则唤」的任务通知——本章忙等的两个点正是阻塞替代的位置。
- [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|lwIP（十三）：tcpip 线程信箱]]是同一
  模式在协议栈里的放大版：ISR 收包入 mbox、tcpip_thread 单消费者拆包——「中断顶半/线程底半」
  的中间站就是这个环。
- 中断负载的账：11520 字节/秒 × 每 ISR 约百十个周期 ≈ 1.2M 周期/秒 ≈ **180MHz 的 0.7%**——
  裸机完全付得起；但 ch10 会把这笔账放大到「每个字节都中断」的极限场景，DMA+IDLE 的动机
  就从这行算术长出来。届时「读 SR+读 DR」的清除序列会被「IDLE 标志+DMA 计数」替代。

## 本章待核对清单

| #   | 项                                                      | 核对方法                                                              |
| --- | ------------------------------------------------------- | --------------------------------------------------------------------- |
| 1   | maxw 实测值（全速/慢速两档）与推导直觉的一致性          | 统计行直读；差异即学习点                                              |
| 2   | 两策略 158/866 的实测数 vs 推导（丢多少相同、丢谁不同） | host 侧 diff + drop 计数                                              |
| 3   | ORE 中断风暴复现（注释掉 ISR 里读 DR 一行）             | 预期卡死在 ISR；openocd `reg pc`（读程序计数器，看 CPU 停在哪）抓现行 |
| 4   | TXE 自关/重开竞态的长期稳定性                           | 1 小时随机突发回显，tx 与 host 发送数对账                             |
| 5   | NVIC 优先级 0x40 生效后 g_ms 的节拍不受串口风暴影响     | 对照 ch01 的 beat 行漂移                                              |
| 6   | CH340/USB 链路的实际突发吞吐上限                        | host 侧灌 64KB，看 rx 曲线是否到 11520/s                              |

上一章：[[2026-08-30-f429-lab-ch05-bus-matrix-ccm|总线矩阵：CCM 为什么是「近端内存」]]；
下一章：[[2026-08-30-f429-lab-ch07-spi-flash-w25q64|SPI：点亮板载 8MB Flash]]——
本章的环先收着，ch21 的 lwIP 还要用它收包。系列总目录见
[[2026-08-30-f429-lab-series-index|F429 裸机实验室索引]]。
