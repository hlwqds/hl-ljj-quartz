---
title: NVIC × FreeRTOS：优先级契约
date: 2026-08-30 04:20:00
description: F429 裸机实验室（十二）——数值越小优先级越高、BASEPRI 阈值屏蔽与三类关中断手段，故意在优先级 4 的 ISR 里调 FromISR 看 configASSERT 当场炸
tags: [f429-lab, STM32, FreeRTOS, NVIC]
---

# NVIC × FreeRTOS：优先级契约

> **状态声明**：本章属「先成文、后实跑」——实验设计与契约推导已写定，但**尚未在真机上执行**。
> 两点特殊：①这是系列里第一篇**跑调度器**的章节（基座本就是 `~/stm32/f429-freertos`，前 11 章
> 裸机实验没启动它）；②预期输出里的 assert 行号**以实跑为准**（vAssertCalled 打印 port.c 的
> 文件:行号，与序章 3.4 的体验同款——不预填编造）。FreeRTOSConfig.h 的三个契约值写前已按
> 工程实值核对。方法论继承[[2026-08-30-stm32f429-clock-misconfig-postmortem|故障复盘]]。

## 本章装备清单

| 分类       | 装备                    | 价格/状态 | 用途               |
| ---------- | ----------------------- | --------- | ------------------ |
| 已有       | 挑战者 F429-V2 板       | ✅        | 实验主体           |
| 已有       | 野火 DAP 仿真器         | ✅        | 烧录/调试          |
| 已有       | Mini-USB 线             | ✅        | 供电 + 串口        |
| 已有       | 笔记本（Fedora 工具链） | ✅        | 构建与观测         |
| 沿用基础盘 | 无新增                  | —         | 中断优先级软件实验 |

## 本章会遇到的词

| 词                                 | 一句话版                                           | 详见                  |
| ---------------------------------- | -------------------------------------------------- | --------------------- |
| NVIC                               | 管所有中断的硬件「总机」：开关/优先级/排队全在它这 | 原理下钻·术语卡       |
| FromISR 族 API                     | 专供中断里调的 FreeRTOS 函数，名字带 FromISR 后缀  | 目标·术语卡           |
| 数值越小优先级越高                 | NVIC 反直觉坐标系：0 最紧迫、15 最低               | 原理下钻·术语卡       |
| 优先级分组（抢占位 vs 子优先级位） | 4 个优先级位可拆两组；跑 RTOS 应全设成抢占位       | 原理下钻·术语卡       |
| BASEPRI                            | 「屏蔽优先级数值 ≥X 的中断」的可编程阈值           | 三类关中断手段·术语卡 |
| PRIMASK / FAULTMASK                | 一刀切总闸：全关 / 连 HardFault 也关               | 三类关中断手段·术语卡 |
| configASSERT                       | 内核断言宏：违规当场打印文件:行号并死循环          | 契约的推导·术语卡     |
| 中断上下文                         | 正在跑 ISR 时的执行状态：不能阻塞，API 面被砍半    | 系统侧类比·术语卡     |
| PendSV                             | 「ISR 全退完才做任务切换」的最低优先级专用异常     | pend 而不切·术语卡    |
| portYIELD_FROM_ISR                 | ISR 收尾标准动作：挂起 PendSV，退出时才切          | pend 而不切·术语卡    |
| NVIC->IP / ISER                    | 优先级寄存器数组 / 中断使能寄存器                  | 实验·代码走读         |

## 目标（先说结论）

- 契约一句话：**优先级数值 ≥5 的中断才能调 `FromISR` 族 API；数值 0–4 是「内核盲区」**——
  可以存在、可以抢占一切，但绝不能碰任何内核对象。数值边界来自工程 FreeRTOSConfig.h：
  `configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY = 5`。
- 两个反直觉先讲透：①**NVIC 数值越小、优先级越高**（写 0x40 的是大爷、写 0xF0 的是孙子）；
  ②内核的「关中断」不是全关——CM4F 端口用 **BASEPRI 阈值屏蔽**（只罩 5–15），0–4 级永远
  畅通。契约正是这两条合起来的必然推论。
- 实验是**故意违法**：优先级 4 的定时器 ISR 里调 `xQueueSendFromISR` → `configASSERT` 当场
  炸（vAssertCalled 打印文件:行号后死循环）；对照组优先级 6 同一段代码长跑正常。再看正确
  姿势：`portYIELD_FROM_ISR` 的 pend 机制。
- 本章是系列「反哺主系列」的一章：与
  [[ch18-critical-sections-spinlocks|FreeRTOS（十八）：临界区契约]]
  正面对接——同一契约在 Xtensa/IDF 与 CM4F/Vanilla 上的两套实现。

> 📖 **术语卡：NVIC**
> **是什么**：Nested Vectored Interrupt Controller（嵌套向量中断控制器），Cortex-M 内核里管中断的硬件「总机」：每个中断源的使能位、优先级、挂起/活跃标志都存在它的一排寄存器里，由它仲裁谁先被 CPU 接通、谁能打断谁（嵌套）。
> **为什么存在**：芯片动辄上百个中断源，靠软件排队太慢；硬件按优先级仲裁+自动压栈现场，中断响应压到十几个时钟周期。
> **类比**：公司总机+插线员：来电排队、重要先接，重要的还能直接插断不重要的正在通话。
> ⚠️ 类比边界：总机混着「先来后到+人工判断」，NVIC 是纯数值硬仲裁；数值相同时才退化为比硬件中断号（小号胜）。

> 📖 **术语卡：FromISR 族 API**
> **是什么**：FreeRTOS 里专供中断服务程序（ISR，Interrupt Service Routine，响应中断而执行的函数）调用的函数版本，名字统一带 `FromISR` 后缀：`xQueueSendFromISR`、`xTaskGetTickCountFromISR` 等；同名无后缀版只能在任务里调。
> **为什么存在**：中断里不能阻塞/睡眠，普通 API 内部可能「等一等」，ISR 版保证绝不等待，并把「要不要立刻切任务」的决定交回调用者（见 portYIELD_FROM_ISR）。
> **类比**：你的主场：内核按上下文拆 API 面——可睡眠版 vs 原子上下文版接口，同一个味道。
> ⚠️ 类比边界：Linux 靠 `might_sleep()` 在运行时抓违规；FreeRTOS 靠优先级数值**事先静态约定**+configASSERT 兜底（见「契约的推导」）。

## 系统侧类比：中断上下文的 API 边界

| NVIC/FreeRTOS 侧                 | 系统侧对应                                        |
| -------------------------------- | ------------------------------------------------- |
| 数值 0–4 盲区不能调 FromISR      | 中断上下文不能 sleep/阻塞——上下文决定 API 面      |
| BASEPRI=0x50 选择性关中断        | local_irq_disable 的阈值版：只封「会碰内核的」层  |
| PRIMASK 全关                     | `cli`/硬中断全关：全有全无                        |
| FromISR 族 API                   | atomic context 版接口（spinlock 保护下的快路径）  |
| portYIELD_FROM_ISR → pend PendSV | 中断里 `raise_softirq`：只挂起，退出时再调度      |
| 违规自检 configASSERT            | DEBUG_ATOMIC_SLEEP/WARNING 检测「原子上下文睡眠」 |
| 数值越小越 urgent                | nice 值反向同款：数字方向与直觉相反               |

Linux 侧工程师的肌肉记忆「中断里不能睡眠」与本章契约完全同构：**进入某种上下文，就放弃了
某类 API**。区别只在判定手段——Linux 靠 `in_interrupt()` 动态查，FreeRTOS 靠优先级数值静态
约定 + assert 兜底。

> 📖 **术语卡：中断上下文（interrupt context）**
> **是什么**：CPU 正在执行 ISR（而非任何任务/线程）时的执行状态。此时「当前任务」语义不存在、不能阻塞不能睡眠——API 面直接被砍掉一半（上表第一行的出处）。
> **为什么存在**：ISR 打断的是别人的现场；它若睡眠，被它压住的每个人都被动陪停，实时性整体坍塌。
> **类比**：你的主场：`in_interrupt()` 为真的世界，「中断里不能睡眠」同一条铁律；BASEPRI≈`sigprocmask`（只挡后到的信号交付）、PRIMASK≈全屏蔽。
> ⚠️ 类比边界：Linux 运行时动态查上下文；FreeRTOS 单核不查状态，而是用优先级数值静态圈出「谁允许在这个上下文调内核 API」——这正是本章契约。

## 原理下钻

### 数值越小优先级越高：先把方向掰对

F429 的 NVIC 每个中断 4 位优先级（0–15），寄存器里**左对齐存高 4 位**：优先级 5 写进
`NVIC->IP[n]` 的值是 `5<<4 = 0x50`。硬件比较的是这 4 位本身——**值小者胜**。于是坐标系是：

```text
数值:   0    1    2    3    4  |  5    6    ...    15
        ↑ 最高urgent（复位/NMI级语义）|      ↑ 最低（SysTick/PendSV 住这）
        ├── 内核盲区（禁 FromISR）──┤├── 合法区（可 FromISR）──┤
                                      ▲ BASEPRI=0x50 的阈值线：≥0x50 的才被内核临界区屏蔽
```

ch06 给 USART1 写的 `NVIC->IP[37]=0x40`、ch10/ch11 写的 `0x60`，在本章坐标系里分别是盲区与
合法区——ch10/ch11 注释里「0x60 的伏笔」在此兑现：裸机章节不调内核 API 所以 0x40 也无害，
但一旦想在串口中断里投队列，0x40 就踩雷。

名词补注：图里「最低档」住的两位房客——SysTick（系统心跳定时器，给调度器供 1ms 一次的 tick 节拍）与 PendSV（任务切换工位，见下文术语卡）——是内核刻意安排在最低优先级的，原因在「pend 而不切」一节揭晓。上文的 `NVIC->IP[n]` 即 NVIC 的中断优先级寄存器数组（IP=Interrupt Priority），每个中断占 1 个字节、按中断号 `n` 索引，下标就是向量表里的 IRQ 号。

> 📖 **术语卡：数值越小，优先级越高**
> **是什么**：NVIC 的反直觉坐标系——优先级数值 0 最高（最紧迫）、15 最低；且 F429 每中断只有 4 位优先级，存在 8 位寄存器的**高 4 位**（左对齐），故优先级 5 写进去是 `5<<4=0x50`。
> **为什么存在**：硬件比较的是这 4 位本身，谁小谁赢；左对齐则让优先级位数不同的 Cortex-M 芯片（F429 是 4 位，别的型号可能只有 3 位）比较结果一致，代码可移植。
> **类比**：nice 值反向同款（你的主场）：数字方向与直觉相反。
> ⚠️ 类比边界：nice 只是调度权重的建议，进程终归能跑；NVIC 优先级是硬件抢占资格，数值小的直接打断数值大的，没有商量。

> 📖 **术语卡：优先级分组（抢占优先级 vs 子优先级）**
> **是什么**：NVIC 还允许把 4 个优先级位拆成两半用：**抢占位**（决定能否互相打断）+**子优先级位**（只在两者抢占级相同时决定谁先响应，**不构成打断**）；拆分比例由 SCB->AIRCR 寄存器的 PRIGROUP 字段设定。
> **为什么存在**：裸机时代用来在同层级里做精细排队；但「子优先级不能抢占」对 RTOS 是坑。
> **类比**：插队许可分两级：一级拿到就能插断通话，二级只是同队里站得更靠前。
> ⚠️ 类比边界：跑 FreeRTOS 的惯例是把 4 位**全部**设成抢占位；CM4F 官方端口的 `vPortValidateInterruptPriority` 里专门有一条对 PRIGROUP 的断言，分组设错会当场炸——分组也是契约的一部分。

### 三类关中断手段：一张表分家

| 手段      | CMSIS 指令                    | 屏蔽谁                                      | 粒度 | 谁在用                   |
| --------- | ----------------------------- | ------------------------------------------- | ---- | ------------------------ |
| PRIMASK   | `__disable_irq()`(cpsid i)    | 全部可配置中断+PendSV（NMI/HardFault 除外） | 全关 | 裸机临界区、启动代码     |
| FAULTMASK | `__set_FAULTMASK(1)`(cpsid f) | 连 HardFault 也罩（仅 NMI 例外）            | 全关 | 故障处理内部，几乎不手用 |
| BASEPRI   | `__set_BASEPRI(0x50)`         | 仅「优先级数值 ≥0x50」的中断                | 阈值 | **FreeRTOS CM4F 端口**   |

PRIMASK/BASEPRI 都不走普通内存窗口（`mdw` 读不到，halt 后用 `reg` 通道才能看，待核对）——
它们是内核私有寄存器，正呼应 ch05「核心私有外设不经矩阵」那一段（矩阵=总线矩阵：把 CPU/DMA/外设交叉连到内存的开关阵列；这类核心寄存器挂在专门的私有外设总线 PPB 上，不经矩阵，所以普通内存访问工具读它另有一套通道）。

表头「CMSIS 指令」补注：CMSIS 是 ARM 官方提供的芯片支持层（头文件+内联函数集），`__disable_irq()`、`__set_BASEPRI()` 这些函数名都来自它；括号里的 `cpsid i` 才是背后真正的 CPU 机器指令。

> 📖 **术语卡：BASEPRI**
> **是什么**：Cortex-M 的一个特殊寄存器：写进一个优先级数值后，比它更高数值（更低紧迫度）的中断全被挡住，写 0 恢复全通。CM4F 版 FreeRTOS 进临界区就写 `0x50`——只罩数值 5–15，0–4 照常放行。
> **为什么存在**：有些临界区只想挡「不重要」的中断，得给最要命的中断（如电机保护、高速比较器）留零延迟通道。
> **类比**：会议勿扰模式——过滤普通来电，白名单（高优先级）照样接通。
> ⚠️ 类比边界：阈值只在**新中断申请进入**那一刻判定；已经在中断里的不受影响，嵌套各自的屏蔽判定发生在各自进入时。

> 📖 **术语卡：PRIMASK / FAULTMASK（三兄弟的两位总闸）**
> **是什么**：PRIMASK 是 1 位总开关：置 1 后全部可配置中断（含 PendSV）都进不来，只剩 NMI（不可屏蔽中断，优先级仅次于复位的异常）与 HardFault（硬故障异常，类比内核 panic）能进；FAULTMASK 更狠，连 HardFault 也挡，只剩 NMI。与 BASEPRI 合称 Cortex-M 三类中断屏蔽手段。
> **为什么存在**：给「一微秒都不许打断」的场合（切换时钟树、Flash 擦写窗口）留总闸；FAULTMASK 主要供故障处理内部自救用，应用代码几乎不碰。
> **类比**：拔电话线（PRIMASK）/连火警专线都拔（FAULTMASK）/勿扰白名单（BASEPRI）。
> ⚠️ 类比边界：三者都只是「进入资格」闸门——不拦 DMA 这类不经 CPU 的内存搬运（ch13 的主角），更不是停机。

### 契约的推导：为什么盲区不能碰内核

FreeRTOS 单核内核的互斥全部押在「关中断」上（对照 FreeRTOS 十八 18.3 的单核世界观）：任务进
临界区 → `BASEPRI=0x50` → 数值 5–15 的中断全停 → 内核链表随便改。但**0–4 级中断在这套屏蔽
之外**——它们能在链表改到一半时插进来。若这种 ISR 再去调 `xQueueSendFromISR`（它也改链表），
撕裂就发生了；而内核对此**毫无感知**，因为它开不出更大的屏蔽（开 PRIMASK 违背「给高紧急
中断留零延迟」的设计初衷，那个设计初衷就是给 0–4 区的：电机保护、高速比较器）。

所以契约分两半：**0–4 区换来了确定性（永不被内核延迟），代价是裸奔（不能碰内核对象）**。
不是缺陷，是明码标价。内核配套 `vPortValidateInterruptPriority` 自检（configASSERT 开启时
编入）：FromISR 入口检查「当前活跃中断的优先级是否都 ≥0x50」（遍历 NVIC 活跃寄存器 IABR
核对优先级），违规当场断言——把静默撕裂提前成响亮爆炸。（IABR=Interrupt Active-Bit Register，NVIC 的一排只读寄存器，每位为 1 表示对应中断当前活跃或还在嵌套中；文中「链表」指内核对象底层的数据结构——队列/信号量/事件组都用双向链表挂等待任务，`xQueueSendFromISR` 同样要改它。）

> 📖 **术语卡：configASSERT**
> **是什么**：FreeRTOS 的断言宏（角色同 C 标准库的 `assert`，但由内核配置统一收口）：条件不成立时调用 `vAssertCalled`——本工程实现为打印 port.c 的文件:行号后死循环，把板子停在现场等调试器上钩。
> **为什么存在**：链表撕裂类 bug 的症状是「随机 HardFault 在千里之外」，断言把它提前成第一现场当场爆炸，省掉数小时归因。
> **类比**：你的主场：`WARN_ON`/`BUG_ON`——把不变量写进代码，违约即报告。
> ⚠️ 类比边界：`WARN_ON` 打印完继续跑；`vAssertCalled` 是死循环停下等调试器；生产固件常关掉 configASSERT 或改成复位——关掉后就是待核对清单第 6 项的「静默违规」高危场景。

### portYIELD_FROM_ISR：pend 而不切

ISR 唤醒了更高优先级任务也不能就地切换（可能还有中断嵌套在身上）。正确姿势是
`portYIELD_FROM_ISR(x)`：往 `SCB->ICSR`（0xE000ED04）写 **PENDSVSET（bit28）** 把 PendSV
挂起。PendSV 被端口放在**最低优先级 0xF0**——它只在所有挂起中断清空、ISR 全退完之后执行，
那才是安全切换点。「中断里只挂起、退出时调度」与 Linux 硬中断里 `raise_softirq`、退出时
`do_softirq` 完全同构。切换现场的单步观察是
[[ch17-pendsv-single-step|ch17：PendSV 单步]]的戏份。

> 📖 **术语卡：PendSV**
> **是什么**：Cortex-M 内置的可挂起系统异常（Pendable Service Call，可挂起服务调用），FreeRTOS 拿它当**任务切换工位**：任何想切任务的代码只往它身上挂「待办」（pend），真正的上下文切换统一在 PendSV 的服务程序里做。
> **为什么存在**：中断可能层层嵌套，中途就地切任务会把现场切在半空；PendSV 被端口设在最低优先级 0xF0，天然要等「所有 ISR 全退完」才轮到执行——那才是唯一安全的切换点。
> **类比**：你的主场：硬中断里 `raise_softirq` 只挂起、退出嵌套后 `do_softirq` 才真干（bottom half 的延迟执行）。
> ⚠️ 类比边界：Linux 的 softirq 干不完还能扔给 ksoftirqd 内核线程兜底；PendSV 没有替补，只在「退出最后一个中断」这一个时机触发。

> 📖 **术语卡：portYIELD_FROM_ISR(x)**
> **是什么**：ISR 收尾的标准动作：`x` 为真（本次 ISR 唤醒了比当前任务更紧急的任务）时，往 `SCB->ICSR`（中断控制/状态寄存器，地址 0xE000ED04）的 bit28（PENDSVSET 位）写 1，把 PendSV 挂起，然后正常退出。
> **为什么存在**：ISR 里不能就地切任务（可能还压着嵌套中断）；挂起只花一条写寄存器指令，切换时机交给 PendSV。
> **类比**：`raise_softirq`+irq_exit 组合拳：先做标记，退出时统一处理（你的主场）。
> ⚠️ 类比边界：它**不立即切换**、只登记意愿；从 ISR 退出到真正切任务还有「退出嵌套+PendSV 入口」的固定开销——这就是下文唤醒延迟 µs 级部分的来源（tick 只量得出 <1ms 的上界）。

## 实验：故意违反契约

同一段代码，一个宏切两组，分两次烧录（违规组 assert 后死循环，跑不长）：

```c
/* FreeRTOSConfig.h 的契约三件套（本工程实值） */
#define configPRIO_BITS                               4
#define configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY  5    /* 契约边界：≥5 才能进 FromISR */
#define configMAX_SYSCALL_INTERRUPT_PRIORITY         (5 << 4)  /* =0x50：BASEPRI 的阈值 */

#define TEST_PRI 0x40u      /* 违规组：优先级 4（盲区）。对照组改 0x60 */

static QueueHandle_t g_q;
static volatile uint32_t g_isr_cnt, g_task_cnt, g_wake_drift_max;

static void tim3_start(void)              /* TIM3：APB1 定时器时钟 90MHz（ch03 的 ×2 规则） */
{
    RCC->APB1ENR |= RCC_APB1ENR_TIM3EN;
    TIM3->PSC = 90 - 1;                   /* 90MHz → 1MHz */
    TIM3->ARR = 1000 - 1;                 /* → 1kHz 中断 */
    TIM3->DIER = TIM_DIER_UIE;
    NVIC->IP[29] = TEST_PRI;              /* TIM3=IRQ29；寄存器存「优先级<<4」 */
    NVIC->ISER[0] = (1u << 29);
    TIM3->CR1 = TIM_CR1_CEN;
}

void TIM3_IRQHandler(void)
{
    TIM3->SR = ~TIM_SR_UIF;               /* 写 0 清挂起——TIM 系与 EXTI 的写 1 恰相反 */
    BaseType_t hpw = pdFALSE;
    uint32_t now = xTaskGetTickCountFromISR();
    xQueueSendFromISR(g_q, &now, &hpw);   /* 违规组：TEST_PRI=0x40 → 这一行触发
                                             vPortValidateInterruptPriority → configASSERT */
    portYIELD_FROM_ISR(hpw);              /* 正确姿势：pend PendSV，ISR 退出即切换 */
    g_isr_cnt++;
}

static void consumer_task(void *arg)      /* 消费者：阻塞在队列上，被 ISR 唤醒 */
{
    uint32_t t;
    for (;;) {
        if (xQueueReceive(g_q, &t, portMAX_DELAY) == pdPASS) {
            uint32_t d = xTaskGetTickCount() - t;    /* 唤醒延迟：tick=1ms 分辨率，只能给上界 */
            if (d > g_wake_drift_max) g_wake_drift_max = d;
            g_task_cnt++;
        }
    }
}

int main(void)
{
    clock_init(); uart_init();
    g_q = xQueueCreate(32, sizeof(uint32_t));
    xTaskCreate(consumer_task, "cons", 256, NULL, 2, NULL);  /* 栈单位是字！见 ch14 */
    vTaskStartScheduler();                /* 调度器起跑（序章修好的三行向量映射在此生效） */
    tim3_start();                         /* vTaskStartScheduler 不返回；初始化放任务里亦可 */
    for (;;) { }
}
```

（严谨起见：`tim3_start` 应放在调度器启动后的任务里——上电即 1kHz 中断会赶在队列建好前
到达；实验代码以任务内初始化为准，此处为叙述顺序展开。）

### 代码走读（逐行拆）

| 代码行                                   | 干什么                                                     | 值得注意                                            |
| ---------------------------------------- | ---------------------------------------------------------- | --------------------------------------------------- |
| `configPRIO_BITS 4`                      | 告诉内核：本芯片 NVIC 每中断 4 个优先级位                  | F429 实测就是 4 位；别的芯片可能 3 位，两处必须一致 |
| `configLIBRARY_MAX_SYSCALL_…_PRIORITY 5` | 契约值人类可读版：优先级数值 ≥5 才能调 FromISR             | 未移位的裸数字，给人看                              |
| `configMAX_SYSCALL_…_PRIORITY (5 << 4)`  | 上一行左对齐后的寄存器版=0x50，内核写进 BASEPRI 的就是它   | 与上一行必须配套改，只改一处是经典事故              |
| `TEST_PRI 0x40u`                         | TIM3 的优先级：违规组 0x40=优先级 4（盲区）；对照组 0x60=6 | `u` 后缀=unsigned；值已是「优先级<<4」形态          |
| `RCC->APB1ENR \|= RCC_APB1ENR_TIM3EN`    | 给 TIM3 所在的 APB1 总线开时钟                             | 外设时钟没开时，写它的寄存器会被静默忽略            |
| `TIM3->PSC = 90 - 1`                     | 预分频器：90MHz 先除以 90 → 1MHz 计数时钟                  | 计数从 0 起跳，所以写「倍数-1」                     |
| `TIM3->ARR = 1000 - 1`                   | 自动重装值：再数 1000 拍溢出一次 → 1kHz 中断               | PSC×ARR=90000：90MHz/90000=1ms 一发                 |
| `TIM3->DIER = TIM_DIER_UIE`              | 使能「更新事件」（计数溢出）的中断请求                     | DIER=DMA/中断使能寄存器                             |
| `NVIC->IP[29] = TEST_PRI`                | 优先级写进 NVIC 优先级寄存器数组第 29 项（TIM3=IRQ29）     | 寄存器存「优先级<<4」，TEST_PRI 恰好已是 0x40/0x60  |
| `NVIC->ISER[0] = (1u << 29)`             | 中断使能寄存器第 0 组第 29 位置 1，NVIC 才放行 TIM3        | ISER 按每 32 个中断一组排布，F429 用到前几组        |
| `TIM3->CR1 = TIM_CR1_CEN`                | CEN=计数器使能：之前全是配置，这行定时器才起跑             |                                                     |
| `TIM3->SR = ~TIM_SR_UIF`                 | 清中断挂起标志：TIM 系**写 0 清**                          | EXTI 是写 1 清，方向相反；不清会立刻重进中断        |
| `xTaskGetTickCountFromISR()`             | 取系统节拍数（tick，本工程 1ms 一跳）的 ISR 安全版         | 用来给「入队时刻」盖时间戳                          |
| `xQueueSendFromISR(g_q, &now, &hpw)`     | 把 now 入队；hpw 由函数回写「是否唤醒了更紧急的任务」      | 违规组就死在这一行（校验在 API 入口拦下）           |
| `portYIELD_FROM_ISR(hpw)`                | hpw 为真→挂起 PendSV，ISR 退出时切换                       | 见上文术语卡                                        |
| `xQueueReceive(g_q, &t, portMAX_DELAY)`  | 出队；队列空就睡到有货（portMAX_DELAY=永不超时）           | 任务上下文才许睡——ISR 版另有 `xQueueReceiveFromISR` |
| `xTaskCreate(..., 256, ...)`             | 建消费者任务；256 是**栈深，单位是字（4 字节）不是字节**   | 实际 1KiB；单位大坑详见 ch14                        |
| `vTaskStartScheduler()`                  | 启动调度器：从此任务世界接管 CPU，本函数不返回             | 它后面的 `tim3_start()` 其实执行不到（见上段括号）  |

**命令拆解：** `grep -n 'configLIBRARY_MAX_SYSCALL' inc/FreeRTOSConfig.h`

| 部分                        | 作用                                                    |
| --------------------------- | ------------------------------------------------------- |
| `grep -n …`                 | 在文件里找这行配置并显示行号（`-n`=带行号）             |
| 查的宏                      | 契约值「≥5 才能进 FromISR」的人类可读版（见代码走读表） |
| 路径 `inc/FreeRTOSConfig.h` | 你的工程里的内核配置文件（相对工程根的路径，按实际改）  |

**你会看到**：一行如 `#define configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY 5`。
**失败了先查**：在工程根目录跑；宏名拼写（LIBRARY 别丢）；路径不对先 `find . -name FreeRTOSConfig.h` 定位。

## 预期输出（待实测核销）

```text
── 对照组（TEST_PRI=0x60：优先级 6，合法区）──
[BOOT ] scheduler running, tick=1000Hz
[STAT ] isr=60000 task=60000 drift_max<=1 queue_len=0     ← 60s 长跑：两计数相等=零丢失
（drift 以 tick 为分辨率：真实唤醒延迟是 ISR 退出+PendSV 的 µs 级，tick 只能给 <1ms 上界；
 µs 级测量留给 ch15 的时间戳序列）

── 违规组（TEST_PRI=0x40：优先级 4，盲区）──
[BOOT ] scheduler running, tick=1000Hz
[ASSERT] .../portable/GCC/ARM_CM4F/port.c:NNN              ← vPortValidateInterruptPriority
                                                            的断言；行号以实跑为准
（vAssertCalled 打印文件:行号后死循环——序章 3.4 同款体验重演；openocd `reg pc` 应停在
 vAssertCalled 内，对照序章断点二分法可定位到断言调用者）

── 寄存器侧（两组各照一张）──
0xE000E474（NVIC_IPR[29]）：0x40（违规组）/ 0x60（对照组）
0xE000ED20（SCB_SHPR3）   ：0xF0F00000 —— PendSV(14)=0xF0、SysTick(15)=0xF0，全系统最低
0xE000ED04（SCB_ICSR）    ：ISR 活跃瞬间可捕获 PENDSVSET 位=1（pend 机制在跑）
```

**命令拆解：** `mdw 0xE000E474`（openocd 交互命令，预期输出里另外两个地址同理）

| 部分         | 作用                                                                      |
| ------------ | ------------------------------------------------------------------------- |
| `mdw`        | memory display word：按 32 位字读内存（兄弟命令 `mdb`/`mdh` 按字节/半字） |
| `0xE000E474` | 要读的地址：预期输出里标为 NVIC_IPR[29] 的那个字                          |
| 读回比对     | 违规组见 0x40、对照组见 0x60，才证明契约值真落了地                        |

**你会看到**：一个 32 位字。⚠️ 打包细节：NVIC 优先级寄存器基址 0xE000E400，**每个中断只占 1 个字节**，一个 32 位字打包 4 个连续中断——TIM3=IRQ29 的字节地址是 0xE000E400+29=0xE000E41D，落在 0xE000E41C 那个字的中间字节；而 0xE000E474 是「字编号 29」的字（打包 IRQ116–119）。两种推法差着地址，本条正属待核对清单第 3 项，实跑时两个地址都读一下即可核销。
**失败了先查**：openocd 已连上且目标板处于 halt（跑着的核会拒绝读）；地址的十六进制拼写。

**命令拆解：** `reg basepri`（openocd，待核对清单第 5 项用）

| 部分      | 作用                                                        |
| --------- | ----------------------------------------------------------- |
| `reg`     | openocd 的寄存器读写通道：不带参数单独敲=列出全部可用寄存器 |
| `basepri` | 内核私有寄存器 BASEPRI 的调试器名                           |

**你会看到**：halt 在 FreeRTOS 临界区内时是 0x50，平时 0x00（`mdw` 读不到它是预期——私有外设总线不走普通内存窗口）。
**失败了先查**：寄存器名拼写（全小写）；目标是否处于 halt 态。

## 与 FreeRTOS（十八）对照：同契约两套实现

| 维度           | CM4F / Vanilla（本章）              | Xtensa / IDF（FreeRTOS 十八）               |
| -------------- | ----------------------------------- | ------------------------------------------- |
| 关中断手段     | BASEPRI=0x50 阈值屏蔽               | PS.INTLEVEL 抬到 EXCM=3                     |
| 屏蔽范围       | 数值 5–15；0–4 照跑                 | level 1–3；更高 level 照跑                  |
| FromISR 合法区 | 优先级数值 5–15                     | 中断级别 ≤3                                 |
| 内核盲区       | 数值 0–4（零抖动、禁内核 API）      | level >3（看门狗等，同款禁令）              |
| 多核互斥       | 无此问题：单核关中断即独占          | spinlock + S32C1I 总线原子（十八 18.5）     |
| 违规自检       | vPortValidateInterruptPriority 断言 | portASSERT_IF_IN_ISR 族断言（任务版临界区） |

**名词补注（对照表里的对面世界）**：Xtensa 是 ESP32 系列 CPU 的架构名；IDF=ESP-IDF（乐鑫官方物联网开发框架，内核是其魔改版 FreeRTOS）；Vanilla 指 FreeRTOS 官方原版内核（本章 CM4F 端口即属此类）。`PS.INTLEVEL`/`EXCM` 是 Xtensa 的中断级别寄存器与「级别线抬高即屏蔽」机制——功能对标 BASEPRI，但方向相反（抬高下限 vs 压低上限）；`S32C1I` 是 Xtensa 的原子条件写指令（对标 ARM 的 LDREX/STREX、你主场的 `lock cmpxchg`）；spinlock 是你的主场，不展开。

两个坐标系左右对齐读：**「合法区」就是「能被内核临界区罩住的那层中断」**——IDF 把 1–3 罩住、
FreeRTOS-CM4F 把 5–15 罩住，方向相反（一个从小数端、一个从大数端圈地），语义完全一致。这也是
ESP32 代码平移到 F429 时的隐形坑：两边「数值方向」还各自相反（Xtensa level 数值越大越高、
NVIC 数值越小越高）——同一行 `中断优先级 = K` 的配置代码，两边的含义南辕北辙。

## 本章待核对清单

| #   | 项                                                        | 核对方法                             |
| --- | --------------------------------------------------------- | ------------------------------------ |
| 1   | FreeRTOSConfig.h 三件套实值（configPRIO_BITS=4 等）       | 工程内 grep + `mdw` SHPR3 交叉验证   |
| 2   | assert 的具体行号与打印格式（vAssertCalled 实现）         | 违规组实跑；与序章 port.c:342 对照   |
| 3   | TIM3=IRQ29、SHPR3=0xF0F00000 推导                         | `mdw 0xE000E474`、`mdw 0xE000ED20`   |
| 4   | 唤醒延迟 tick 上界（drift_max）与队列零丢失               | 60s 长跑统计                         |
| 5   | BASEPRI 经调试器可读性（`reg basepri`，halt 态）          | openocd 会话实验；mdw 读不到是预期   |
| 6   | 关闭 configASSERT 的静默违规（链表撕裂的实际形态）        | 对照组实验：预期随机 HardFault——高危 |
| 7   | 0x40 组在「ISR 不调内核 API」时确实无害（盲区可正当使用） | 对照组：只 toggling GPIO+计数，长跑  |

上一章：[[ch11-adc-dma-double-buffer|ADC+DMA 双缓冲：无 CPU 的采样流]]；
下一章：[[ch13-ccm-dma-isolation|CCM 实测：DMA 走不进的房间]]。系列总目录见
[[f429-lab|F429 裸机实验室索引]]。
