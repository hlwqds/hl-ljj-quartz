---
title: 按键三态：轮询、中断与消抖
date: 2026-08-30 03:05:00
description: F429 裸机实验室（二）——从忙等轮询到 EXTI/NVIC 八环使能链，机械抖动的时间戳消抖；poll() 到 epoll 的嵌入式重演
tags: [STM32, CortexM, EXTI, Lab]
---

# 按键三态：轮询、中断与消抖

> **状态声明**：本章属「先成文、后实跑」——实验设计与寄存器推导已写定，但**尚未在真机上执行**；
> 所有「预期输出」均为待实测核销的推导值。KEY1/KEY2 的具体引脚号在板卡事实库中缺失，
> **全文以宏占位并标注「待核对」**（候选值来自野火教程常见配置，未经本板核实）。
> 方法论与工具链继承[[2026-08-30-stm32f429-brick-rescue-debug-story|序章]]。

## 本章装备清单

| 分类       | 装备                    | 价格/状态 | 用途                          |
| ---------- | ----------------------- | --------- | ----------------------------- |
| 已有       | 挑战者 F429-V2 板       | ✅        | 实验主体                      |
| 已有       | 野火 DAP 仿真器         | ✅        | 烧录/调试                     |
| 已有       | Mini-USB 线             | ✅        | 供电 + 串口                   |
| 已有       | 笔记本（Fedora 工具链） | ✅        | 编译/烧录/mdw 实证            |
| 沿用基础盘 | 无新增                  | —         | 本章用板载按键 KEY1/KEY2 完成 |

## 本章会遇到的词

| 词                     | 一句话版                                             | 详见           |
| ---------------------- | ---------------------------------------------------- | -------------- |
| GPIO                   | 通用输入输出引脚：可编程的电平门户                   | 「原理下钻」   |
| 上拉 / 低有效          | 引脚默认拉高 / 按下=0、松开=1                        | 「机械抖动」   |
| 轮询（poll）           | 主循环反复读引脚——你的主场                           | 「系统侧类比」 |
| EXTI / SYSCFG / NVIC   | 外部中断控制器 / 引脚选线总机 / CPU 侧中断总管       | 「使能链」     |
| 边沿触发 vs 电平触发   | 变化瞬间报一次 vs 保持期间持续报（epoll ET/LT 同款） | 「系统侧类比」 |
| 抖动 / 消抖            | 触点弹跳 5–10ms / 用时间戳滤掉                       | 「机械抖动」   |
| 时钟门控 / ENR         | 每个外设一个时钟开关，不开则寄存器读恒 0             | 「使能链」     |
| w1c                    | write-1-to-clear：写 1 清挂起的硬件约定              | 「原理下钻」   |
| PR / IMR / RTSR / FTSR | 挂起 / 屏蔽 / 上升沿 / 下降沿寄存器                  | 「使能链」     |
| ISER / IRQ 号          | NVIC 的使能寄存器 / 中断编号                         | 「使能链」     |
| ISR / MSP              | 中断服务函数 / 主栈指针                              | 「对照」       |
| mdw                    | openocd 读内存命令（按 32 位字）                     | 「预期输出」   |

## 目标（先说结论）

- 同一个「按键计数」需求写三遍：**轮询版**（抖动肉眼可见地吃掉计数精度）→ **EXTI 中断版**
  （事件驱动，CPU 空闲下来）（EXTI：STM32 的外部中断控制器，见「原理下钻」术语卡）→ **时间戳消抖版**（把机械抖动从计数里滤干净）。
- 本章主图是 **EXTI 的八环使能链**：从引脚时钟到向量表，任何一环没接上，按键就是哑的——
  而且死得无声无息（不报错、不进 handler，和 wikilink 死链同款静默劣化）。
- 系统侧主线：**忙等 poll() → epoll 事件驱动** 的嵌入式重演；EXTI 的挂起寄存器 PR ≈ 信号
  的 sigpending 集合（PR：Pending Register，"事件已发生、等人认领"的登记位；sigpending 是你的主场，不展开）。

## 系统侧类比：poll、epoll 与信号

| 按键方案            | 系统侧对应                                    | 代价/收益                   |
| ------------------- | --------------------------------------------- | --------------------------- |
| 轮询 GPIO IDR       | 用户态 `poll()` 热循环（不带 timeout 的忙等） | CPU 100% 花在「看」上       |
| EXTI 中断 + handler | epoll 注册回调 / 内核里 request_irq           | 事件来了才花 CPU            |
| EXTI PR 挂起位      | `sigpending()`：事件已发生、等你认领          | 认领动作=写 1 清除（w1c）   |
| NVIC ISER 使能      | 内核 `enable_irq()` / 信号 unblock            | 总开关在 CPU 侧，不在设备侧 |

（右列 poll / epoll / sigpending / request_irq 全是你的主场，不展开；本章的新知识全在左列。）

两个值得先记的差异：

1. **EXTI 是纯边沿触发**（RTSR/FTSR 选上升/下降沿），没有电平触发模式——相当于 epoll 只有 ET 模式。
   想要「电平语义」得在 ISR 里再读一次 IDR 自己合成。（边沿 vs 电平：边沿只在"变化的一瞬"报一次，电平在"保持期间"持续报——你的主场的 epoll ET/LT 正是同一对概念，EXTI 这边只有 ET）
2. EXTI 的**同号互斥**：EXTI 线 0 只能映射 PA0/PB0/PC0/... 其中之一（SYSCFG_EXTICR 每 4 位选一个端口）。
   想同时用 PA0 和 PB0 的中断？没门——和 XT-PIC 时代一条 IRQ 线只能挂一个设备的味道一模一样（XT-PIC：x86 上古中断控制器 8259A 的时代——你的主场）。

## 原理下钻

### 机械抖动：为什么「按一下」不是「一个事件」

机械触点闭合/断开的瞬间，金属片要弹跳几毫秒才稳定。低有效按键（按下接地；低有效 = 按下读 0、松开读 1）在示波器（示波器：把电平随时间画成波形的仪器）上是这样的
（示意，非实测波形；板上抖动时长**待实测**，典型 5–10ms）：

```text
松开(1) ──┐┌──┐┌────────────── 按下(0)
           └┘  └┘    ↑
           |← 5–10ms →|  这段时间电平在 0/1 之间弹跳
```

对轮询版，抖动意味着「等 10ms 再采一次」的朴素防抖会被更长的抖动骗过；
对中断版更致命——**每一跳都是一次合法的下降沿**，一次按压能进 handler 十几次。

### EXTI/NVIC 使能链（本章主图）

STM32F4 的外部中断要穿过两层「接线总机」：SYSCFG 决定**哪根引脚**接上 EXTI 线，
NVIC 决定 CPU **放不放行**。八环全通才有中断：

> 📖 **术语卡：EXTI、SYSCFG 与 NVIC——外部中断的三级接力**
> **是什么**：EXTI（Extended Interrupt/Event Controller，外部中断/事件控制器）是 STM32 的外设，盯着引脚的电平边沿；SYSCFG（SYStem ConFiG controller，系统配置控制器）是选线总机——决定 EXTI 线 n 接哪个端口的 P n 引脚；NVIC（内核内置中断管理器，ch01 已注）是 CPU 门口的最后一道闸，管放行与优先级。
> **为什么存在**：引脚上百根、EXTI 线只有 23 根、CPU 异常入口有限——三级结构把"谁在看、怎么接、放不放行"解耦。
> **类比**：小区门禁三级：摄像头（EXTI 盯边沿）→ 监控室选路（SYSCFG 决定哪路信号上墙）→ 保安队长放行（NVIC 决定是否打断 CPU）。
> ⚠️ 类比边界：门禁走的是人，这里是电信号的三级硬件链路，任何一级断开都静默无声——本章"八环"里它们占了三环。

```text
[1] RCC->AHB1ENR    |= GPIOxEN      引脚供电（不开时钟，读 IDR 恒 0——常见第一环断链）
[2] GPIOx->MODER    = 输入(00)       引脚交给输入驱动器；低有效按键配内部上拉
[3] RCC->APB2ENR    |= SYSCFGEN      SYSCFG 时钟（接线总机也要上电）
[4] SYSCFG->EXTICR[n]=端口序号        把 EXTI 线焊到指定端口（0=PA … 8=PI），每线 4 位
[5] EXTI->IMR       |= (1<<line)     解屏蔽：事件允许走到 NVIC
[6] EXTI->FTSR      |= (1<<line)     选边沿：下降沿=按下（低有效）
[7] NVIC->ISER[irq/32]=1<<(irq%32)   CPU 侧放行（NVIC_EnableIRQ() 的真身就是写这个寄存器）
[8] 向量表 handler                   到站：ISR 读 PR 确认来源，写 1 清挂起，做业务
```

> 词典行：ENR = ENable Register（使能寄存器）；MODER = 模式寄存器（每脚 2 位，00=输入）；PUPDR = 上/下拉选择寄存器；IDR = Input Data Register（读引脚电平）；IMR = Interrupt Mask Register（屏蔽寄存器，1=放行）；RTSR/FTSR = Rising/Falling Trigger Selection（上升/下降沿选择）；ISER = Interrupt Set-Enable Register（NVIC 的中断使能寄存器，写 1 开）；PR = Pending Register（挂起登记）。

> 📖 **术语卡：GPIO（General Purpose Input/Output，通用输入输出）**
> **是什么**：芯片引脚背后的可编程门户：每个引脚由 MODER（模式：输入/输出/复用/模拟，每脚 2 位）、PUPDR（上拉/下拉选择）、IDR（Input Data Register，读引脚当前电平）等寄存器控制。
> **为什么存在**：MCU 引脚是万能件——今天接按键输入、明天驱动 LED 输出，全靠寄存器现场定义角色。
> **类比**：多功能插座上每个插口带拨钮，拨到"听"是输入、拨到"说"是输出。
> ⚠️ 类比边界：插口不接也有默认状态，引脚悬空却会读到随机电平——输入脚必须配 PUPDR 上拉/下拉给出默认值（本章按键配内部上拉，空闲为 1）。

> 📖 **术语卡：外设时钟门控与 ENR**
> **是什么**：STM32 每个外设都有独立时钟开关，集中在 RCC 的 ENR（ENable Register）系列：挂 AHB1 总线的 GPIO 在 AHB1ENR，挂 APB2 的 SYSCFG 在 APB2ENR（AHB/APB：两条不同速度的外设总线）。不开开关，外设寄存器读恒 0、写无效。
> **为什么存在**：外设全开太耗电，逐个门控让未用的外设彻底静默。
> **类比**：你的主场：BIOS/安全组逐设备、逐端口放行——不开就不通，且**不报错**。
> ⚠️ 类比边界：软件 disable 的设备通常还能被探测到；时钟门控关掉的外设寄存器读出恒 0，极易误诊成"硬件坏了"。

寄存器地址速查（本章全部 `mdw` 证据的坐标）：

| 模块   | 基址       | 用到的寄存器（偏移）                                     |
| ------ | ---------- | -------------------------------------------------------- |
| RCC    | 0x40023800 | AHB1ENR(+0x30)、APB2ENR(+0x44)                           |
| SYSCFG | 0x40013800 | EXTICR1–4（+0x08/+0x0C/+0x10/+0x14，每 4 位管 4 条线）   |
| EXTI   | 0x40013C00 | IMR(+0x00)、RTSR(+0x08)、FTSR(+0x0C)、**PR(+0x14，w1c)** |
| NVIC   | 0xE000E100 | ISER0(+0x00)、ISER1(+0x04)；优先级 IPR 在 0xE000E400+n   |

EXTI 线号 → NVIC 中断号的映射（F42x 向量表，RM0090）：线 0–4 一线一个中断（IRQ 6–10），
线 5–9 合用 `EXTI9_5`（IRQ 23），线 10–15 合用 `EXTI15_10`（IRQ 40）。合并意味着 ISR 里
必须靠 PR 判断**到底是哪条线**——这就是 PR「确认来源」的用途。

**PR 的 w1c 与读改写陷阱**（w1c：write-1-to-clear——中断控制器的通用约定，写 1 清对应位、写 0 无效）：挂起位写 1 清除。若写成 `EXTI->PR |= (1<<line)`，
读改写过程中会把**同一瞬间挂起的其他线也一起清掉**（读出来是 1，写回去还是 1，全部清空）。
正确姿势是直接写：`EXTI->PR = (1 << line);`

## 实验一：轮询版（忙等的代价可视化）

```c
/* ---------- KEY 宏占位：候选 KEY1=PA0 / KEY2=PC13（野火教程常见值，本板待核对） ---------- */

#define KEY1_PORT      GPIOA /* 候选，待核对 */
#define KEY1_PIN       0     /* 候选 PA0，待核对；实测方法：万用表量按键两端电平变化 */
#define KEY2_PORT      GPIOC /* 候选，待核对 */
#define KEY2_PIN       13    /* 候选 PC13，待核对 */

static void key_init_input(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOAEN | RCC_AHB1ENR_GPIOCEN;
    /* MODER 复位值本就是 00（输入），显式写一遍是教学习惯：把「依赖复位值」变成「声明意图」 */
    KEY1_PORT->MODER &= ~(3u << (KEY1_PIN * 2));
    KEY2_PORT->MODER &= ~(3u << (KEY2_PIN * 2));
    KEY1_PORT->PUPDR = (KEY1_PORT->PUPDR & ~(3u << (KEY1_PIN * 2))) | (1u << (KEY1_PIN * 2)); /* 上拉 */
    KEY2_PORT->PUPDR = (KEY2_PORT->PUPDR & ~(3u << (KEY2_PIN * 2))) | (1u << (KEY2_PIN * 2));
}

int main(void)
{
    clock_init();
    uart_init();
    key_init_input();

    uint32_t count = 0;
    uint8_t prev = 1; /* 低有效：1=松开（上拉保证空闲为 1） */
    for (;;) {
        uint8_t now = (KEY1_PORT->IDR >> KEY1_PIN) & 1u;
        if (now != prev) {
            /* 朴素防抖：等 10ms 再采，一致才认账——依然会被 >10ms 的长抖动骗过 */
            delay_ms(10); /* 用 ch01 的 g_ms 实现的毫秒等待 */
            if (((KEY1_PORT->IDR >> KEY1_PIN) & 1u) == now) {
                prev = now;
                if (!now) { /* 1→0：按下沿 */
                    count++;
                    uart_puts("[KEY1-poll] count=");
                    uart_putdec(count);
                    uart_puts("\r\n");
                }
            }
        }
        /* 主循环里除了看按键什么都没干——这就是忙等的全部代价 */
    }
}
```

> **代码走读（轮询版）**：① `~(3u << (KEY1_PIN*2))`：MODER/PUPDR 每个引脚占 2 位，`3u`=0b11 是"这两位"的掩码，先清后写是位域操作定式；② `(IDR >> KEY1_PIN) & 1u`：把目标位右移到最低位再取出——读单个引脚电平的标准姿势；③ `prev` 初值 1：低有效按键空闲为 1（上拉保证），首循环不误报。

## 实验二：EXTI 中断版 + 时间戳消抖

```c
static volatile uint32_t g_key1_count;
static volatile uint32_t g_key1_last_ms;

static void key1_exti_init(void)
{
    /* 候选 PA0 → EXTI 线 0 → IRQ 6。若实测引脚不同，三处一起改 */
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOAEN;  /* [1] 引脚时钟 */
    GPIOA->MODER &= ~(3u << (0 * 2));     /* [2] 输入 */
    GPIOA->PUPDR = (GPIOA->PUPDR & ~(3u << (0 * 2))) | (1u << (0 * 2)); /* 上拉（低有效） */

    RCC->APB2ENR |= RCC_APB2ENR_SYSCFGEN;         /* [3] SYSCFG 时钟 */
    SYSCFG->EXTICR[0] = (SYSCFG->EXTICR[0] & ~0xFu) | 0x0u; /* [4] 线0=PA（端口序号 0） */

    EXTI->IMR |= (1u << 0);  /* [5] 解屏蔽线 0 */
    EXTI->FTSR |= (1u << 0); /* [6] 下降沿=按下 */

    NVIC->ISER[0] = (1u << 6); /* [7] IRQ6 → ISER0 bit6；= NVIC_EnableIRQ(EXTI0_IRQn) */
}

void EXTI0_IRQHandler(void) /* [8] 向量表到站：IRQ6 的名字是固定的 */
{
    if (EXTI->PR & (1u << 0)) {
        EXTI->PR = (1u << 0); /* w1c 清挂起——直接写，禁用 |= 读改写（见正文陷阱） */
        uint32_t now = g_ms;  /* ch01 的毫秒地基在这里兑现 */
        if (now - g_key1_last_ms >= 20u) { /* 20ms 内的再次边沿 = 抖动，整段丢弃 */
            g_key1_last_ms = now;
            g_key1_count++;
            uart_puts("[KEY1-irq ] count=");
            uart_putdec(g_key1_count);
            uart_puts("\r\n");
        }
    }
}
```

> **代码走读（中断版）**：① 注释 [1]–[8] 与上面八环图逐环对应，改一个引脚要动 [1][4][7] 三处；② `EXTICR[0] & ~0xFu`：EXTICR 每条 EXTI 线占 4 位，清低 4 位即"线 0 的选择位"；③ handler 三步纪律：查 PR 认领来源 → 直接写 PR 清挂起（w1c，禁用 `|=`）→ 记时间戳退出，绝不在 ISR 里等。

**时间戳消抖**的取舍：只认「距上一合法边沿 ≥20ms」的边沿，实现只有两行，但**首边沿即真相**——
抖动段的第一跳被采信，后续整段静默。代价是按下沿的系统响应延迟为 0（好），而若硬件抖动超过
20ms 仍可能漏计（典型机械按键 10ms 内稳定，20ms 余量充足；本板实测值**待核销**）。
对比朴素方案（延时后复读）：延迟固定 10ms、且在 ISR 里 delay 是灾难。ISR 里永远不做「等」，
只做「记时间戳、放行、退出」——和信号 handler 里只做 async-signal-safe 操作是同一条纪律（async-signal-safe：信号安全函数集——你的主场）。

## 预期输出（待实测核销）

串口侧（行为预期，非实测）：

```text
[KEY1-poll] count=1      ← 轮询版：偶发一次按压冒出 count=2/3（长抖动骗过 10ms 窗，待实测）
[KEY1-irq ] count=1      ← 中断版：一次按压恒 +1；主循环完全空闲
[KEY1-irq ] count=2
```

寄存器侧——按候选引脚 PA0 推导的整条使能链快照（**引脚核对后如有出入，这张表整体重算**）：

| 地址       | 寄存器         | 预期值     | 推导                                              |
| ---------- | -------------- | ---------- | ------------------------------------------------- |
| 0x40023830 | RCC_AHB1ENR    | 0x00000005 | GPIOAEN(bit0)+GPIOCEN(bit2)；uart_init 已开 GPIOA |
| 0x40023844 | RCC_APB2ENR    | 0x00004010 | USART1EN(bit4)+SYSCFGEN(bit14)                    |
| 0x40013808 | SYSCFG_EXTICR1 | 0x00000000 | 线 0=PA：端口序号 0（复位值恰为 0，写入是显式化） |
| 0x40013C00 | EXTI_IMR       | 0x00000001 | 线 0 解屏蔽                                       |
| 0xE000E100 | NVIC_ISER0     | 0x00000040 | IRQ6 → bit6                                       |

实测动作：`mdw` 逐行对照，任何一行不符 → 按「使能链从上往下」顺序排查断在哪一环；
全符但按键仍哑 → 查跳线/引脚号本身（回到「丝印是最后的事实来源」，序章教训）。

**命令拆解：** `openocd -c "init; mdw 0x40023830; mdw 0x40023844; mdw 0x40013808; mdw 0x40013C00; mdw 0xE000E100"`

| 部分                      | 作用                                                                        |
| ------------------------- | --------------------------------------------------------------------------- |
| `openocd -c "…"`          | 连上 DAP 仿真器后按序执行引号里的命令（`init` = 建立连接，序章 3.2 有拆解） |
| `mdw <地址>`              | 按地址读 32 位字；五个地址 = 使能链的五个证据点（对照上面快照表）           |
| `0x400238xx`              | RCC 的 AHB1ENR/APB2ENR：GPIO 与 SYSCFG 的时钟开关                           |
| `0x40013808`              | SYSCFG_EXTICR1：EXTI 线 0–3 各自接哪个端口                                  |
| `0x40013C00`/`0xE000E100` | EXTI_IMR（屏蔽放行）/ NVIC_ISER0（CPU 侧放行）                              |

**你会看到**：五组 32 位 hex，逐行对照快照表预期值。
**失败了先查**：读全 0 → 先 `reset halt`（序章方法论 5）；地址是否被引脚宏改动牵连（引脚核对后此表重算）。

PR 的活体读数另有一层乐趣：handler 会第一时间清挂起，所以空闲时 `mdw 0x40013C14` 预期恒 0；
**按住按键不放的瞬间**抢读，才有机会抓到挂起位=1（EXTI 是边沿触发，电平稳定后不再挂起——
这本身就是「ET 模式」语义的实证，待实测）。

## 与 FreeRTOS / ESP32 对照

- **ISR = 受限上下文**，两边同构：EXTI handler 不能阻塞、要用 MSP 主栈（MSP：Main Stack Pointer 主栈指针——Cortex-M 的中断 handler 固定用主栈，所以 ISR 里开大数组会砸主栈）；
  Linux 信号 handler 只能做 async-signal-safe 操作（你的主场）。FreeRTOS 下 ISR 里只能调 `*_FromISR` API，
  惯用姿势是 ISR 只投递队列、业务逻辑留给任务——「中断顶半部/线程底半部」的分工（你的主场：Linux 同款纪律）。
- **优先级契约**：本工程 `configMAX_SYSCALL_INTERRUPT_PRIORITY = 5<<4`，意味着优先级数值
  低于 5 的中断里调 FromISR 是违约（注意方向：数值低于 5 = 优先级更**高**——再记一遍"数值越小越急"；FromISR：FreeRTOS 的中断安全 API 后缀）、`configASSERT` 会当场炸——本系列 ch12 专做这个爆炸实验，
  与[[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|FreeRTOS（十八）：临界区契约]]
  理论篇互为表里。
- **ESP32 侧**：`gpio_install_isr_service()` + `gpio_isr_handler_add()` 一套调用把 EXTI/SYSCFG/
  NVIC 八环全包掉——设备树+内核 request_irq 的既视感（request_irq：内核注册中断 handler 的接口——你的主场）。IDF 生态没有「弱符号桩没接」这类坑，
  因为根本没有厂商启动文件与内核端口的名字冲突问题（序章 3.4 的对照面）。
- **消抖的位置**：ESP32 有 GPIO 的 glitch filter（硬件消抖）、Linux 有 gpio-keys 的
  debounce-interval（gpio-keys：Linux 内核的通用按键驱动框架——你的主场）——系统侧早已把「时间戳法」工业化。裸机自己写一遍，才知道 dt-bindings
  里那行 `debounce-interval = <20>;` 在替你做什么。

## 本章待核对清单

| #   | 项                                              | 核对方法                                    |
| --- | ----------------------------------------------- | ------------------------------------------- |
| 1   | KEY1/KEY2 引脚号（候选 PA0/PC13，未核实）       | 丝印/原理图/万用表；代码三处宏同步改        |
| 2   | 按键有效电平与上下拉方向（假设低有效+内部上拉） | 万用表量按键引脚空闲/按下电平               |
| 3   | 本板机械抖动实际时长（假设 5–10ms）             | 抓计数乱跳的窗口或后续用 RPi 采样（阶段 2） |
| 4   | 20ms 消抖窗是否漏计（快速连击测试）             | 1s 内连按 10 次，计数应=10                  |
| 5   | 使能链快照表五项实测值                          | `mdw` 逐行对照                              |
| 6   | 按住不放时 PR 挂起位的可观测性（ET 语义实证）   | `mdw 0x40013C14` 抢读                       |

上一章：[[2026-08-30-f429-lab-ch01-systick-heartbeat|SysTick：内核的心跳]]（g_ms 的来历）；
下一章：[[2026-08-30-f429-lab-ch03-timer-pwm-buzzer|定时器与 PWM：让蜂鸣器唱歌]]。
