---
title: request_irq：Linux 的中断官僚体系
date: 2026-08-30 03:50:00
description: 按键 GPIO 中断驱动（threaded IRQ + 等待队列阻塞读）对照 F429 的 EXTI→NVIC→ISR 直配——顶半/底半/threaded 三条路，Linux 把 handler 关进「不可睡眠监狱」并给了保释通道
tags: [RPi, Linux, Driver, IRQ, Lab]
---

# request_irq：Linux 的中断官僚体系

> **状态声明**：本章为「先成文、后实跑」的实验设计，**未在真机执行**；以
> [[2026-08-30-rpi-lab-ch01-bookworm-surgery-baseline|ch01]] 升级后的 Bookworm（内核 ≥ 6.6）与
> [[2026-08-30-rpi-lab-ch04-kernel-module-mygpio|ch04]] 的模块基建（Makefile、misc 设备模式）
> 为前提。所有「预期输出」均为待实测核销占位，绝不冒充真实运行日志。

## 本章装备清单

| 分类     | 装备                        | 价格/状态 | 用途                                             |
| -------- | --------------------------- | --------- | ------------------------------------------------ |
| 已有     | 树莓派 4B + MicroSD + 网线  | ✅        | 实验主体                                         |
| 已有     | 笔记本（SSH 客户端）        | ✅        | 远程操作                                         |
| 需购买   | 杜邦线 + 轻触按键（母对母） | ~¥10      | 按键接 GPIO4→GND（没有按键用杜邦线手按短接也行） |
| 建议购买 | 万用表                      | ~¥50      | 量 GPIO4 静态电平，确认上拉生效                  |
| 可选联动 | 挑战者 F429 板 + 杜邦线     | 视库存    | §4 跨板彩蛋用；**无 F429 板可直接跳过该节**      |

> 本章的按键可以用「杜邦线一头接 GPIO4、一头接 GND，手按」代替实体按键——本章要观察的
> 是中断行为，不是机械手感。

### 本章会遇到的词

| 词                  | 一句话预览                                                        |
| ------------------- | ----------------------------------------------------------------- |
| 中断 / IRQ          | 硬件向 CPU「插队求救」的电信号；IRQ=中断请求（Interrupt ReQuest） |
| IRQ 号              | Linux 给每条中断线编的号，运行期才分配，不是查手册背的            |
| 边沿触发 / 电平触发 | 「电平跳变那一下」算事件 / 「保持某电平期间」持续算事件           |
| 中断上下文          | handler 执行时的特殊状态：不能睡、不能慢——「不可睡眠监狱」        |
| 顶半 / 底半         | 快取证的前台（hardirq）+ 慢干活的后台（线程/工作队列）            |
| threaded IRQ        | 底半是一个真正的内核线程，可睡眠、可调度、有名字                  |
| 等待队列            | 让进程睡下等事件、事件来了被唤醒的内核机制                        |
| 原子量 atomic_t     | 读写保证「一口气完成」的整型，多核并发下的最小同步单位            |
| gpiod               | 内核的 GPIO 描述符接口：按「描述符」而不是裸编号操作引脚          |
| /proc/interrupts    | 内核导出的中断计数表：每条线在哪个 CPU 上发生了几次               |

## 目标（先结论）

写一个按键中断驱动 `btn_irq.ko`：`gpiod_to_irq()`（把 GPIO 线换算成内核中断号的函数）拿中断号
→ `request_threaded_irq()`（注册「顶半+底半线程」式中断的函数）注册边沿触发中断（只在电平
跳变的瞬间触发一次，对照电平触发=保持电平期间反复触发）→ 顶半只记时间戳（硬中断上下文，
即「中断上下文」——不能睡、要快）→ 底半在**内核线程**里消抖计数 →
`wake_up_interruptible()`（唤醒睡在等待队列上的进程）唤醒阻塞在 `cat /dev/btnirq0` 上的读者。
用户态一句 `cat` 挂起等按键、按下即醒——事件驱动从用户态一路通到硬件边沿。

一句话类比先立住：**中断 handler 像信号 handler，但 Linux 把 handler 关进了「不可睡眠监狱」
（中断上下文，atomic 上下文），并给了保释通道（threaded IRQ：顶半申请保释，底半在内核线程
里睡够干完）**。

> 📖 **术语卡：中断与 IRQ 号**
> **是什么**：中断=硬件主动打断 CPU 当前执行、要求立即服务的机制（按键按下、网卡收包都靠
> 它）；IRQ 号=内核里这条中断线的编号，注册 handler、查计数都用它。
> **为什么存在**：轮询浪费 CPU；中断让 CPU「事件来了再理」，其余时间干别的或省电。
> **类比**：你的主场——信号是内核替进程收的「软件中断」；硬件中断是外设直接拉给中断控制
> 器的电线，比信号底层两级。
> ⚠️ 类比边界：信号 handler 跑在进程上下文（能用大多数 API）；硬件中断 handler 跑在监狱里
> （见下一张卡），这是两套世界。

> 📖 **术语卡：中断上下文（atomic 上下文，「不可睡眠监狱」）**
> **是什么**：硬中断 handler 执行时所处的特殊状态：不代表任何进程、不参与正常调度，因此
> **不能睡眠/阻塞**（拿 mutex、等 I/O 都算），也要尽量短。
> **为什么存在**：中断来时 CPU 可能正拿着自旋锁、关着抢占——你若睡下，等你的锁全部卡死，
> 典型死相是内核报 `BUG: scheduling while atomic`。
> **类比**：消防员冲进火场那一刻不能去排队买咖啡——不是纪律约束，是物理上没人替你排队。
> ⚠️ 类比边界：监狱只关顶半；底半线程（threaded IRQ）在正常调度世界，随便睡。

| #    | 做通标准                                                              | 对应     |
| ---- | --------------------------------------------------------------------- | -------- |
| R3.1 | `cat /dev/btnirq0` 阻塞 → 按键唤醒并打印计数；`/proc/interrupts` 递增 | 主实验   |
| R3.2 | STM32 KEY 经一根 GPIO 线触发 RPi 中断，两端日志同秒记录（可选彩蛋）   | 跨板联动 |

## 1. 原理：同一个按键，两套官僚体系

裸机里按一次按键要走八环使能链（
[[2026-08-30-f429-lab-ch02-button-polling-to-interrupt|F429 ch02]] 的主图）：RCC 时钟 → MODER →
SYSCFG EXTICR → EXTI IMR/FTSR → NVIC ISER → 向量表 handler，最后一环还是**链接期写死**的
函数指针——接错了就是弱符号桩死循环（
[[2026-08-30-stm32f429-brick-rescue-debug-story|序章]] 3.4 的血案）。Linux 把这八环收进一个
函数 `request_irq()`，但代价是 handler 进了监狱。全章主轴是下面这张逐行对照表——**同一件事，
两个世界的成本与防护**：

先给这串 F429 术语一人一张名牌（本章只需记住「它管哪一环」，细节在 F429 系列展开）：RCC
（Reset and Clock Control——STM32 的时钟总开关，外设不开钟就等于不存在）；MODER（引脚模式
寄存器，决定一根脚是输入/输出/复用）；SYSCFG EXTICR（选择「哪个端口的几号线」接到 EXTI）；
EXTI（外部中断控制器：IMR=中断屏蔽开关，FTSR/RTSR=下降沿/上升沿选择）；NVIC ISER（中断
控制器 NVIC 的使能开关）；向量表（中断号→handler 地址的跳转表，链接期写死）；弱符号桩
（你没提供实现时链接器垫上的空默认函数，一调用就死循环）。

> 📖 **术语卡：NVIC（Nested Vectored Interrupt Controller）**
> **是什么**：Cortex-M 内核**自带**的中断管家：收中断请求、按优先级嵌套、查向量表跳转
> handler——F429 那八环里的最后两环（使能+分发）就是它管的。
> **为什么存在**：外设几百条线，CPU 只有一根 NMI/IRQ 入口，必须有管家先仲裁再上报。
> **类比**：BCM2711 用的 GIC（Generic Interrupt Controller）是同职位——Linux 世界里这位
> 管家的寄存器由内核的 irqchip 驱动代管，你不再直接碰它。
> ⚠️ 类比边界：NVIC 查的是链接期写死的向量表；Linux 的分发查的是运行期 request_irq 挂的
> 链表——一个静态、一个动态。

| 同一件事       | F429 裸机                                         | Linux                                                   | Linux 在防什么                                                |
| -------------- | ------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------- |
| 找中断号       | 查手册向量表：EXTI 线号→IRQ 号（线 0→IRQ6）       | `gpiod_to_irq(desc)` 由 gpiochip 的 irqdomain 算        | 屏蔽每块板不同的中断拓扑（BCM2711 走 GIC，编号是运行期映射）  |
| 注册 handler   | 向量表放函数指针，链接期固定                      | `request_irq()` 运行期挂进 irqaction 链表               | 多驱动共存一条 IRQ 线、模块可装卸（对照 insmod/rmmod 热更新） |
| 使能链         | 八环手写，任何一环断链即哑火且无声无息            | 一次调用内部全做（irqchip 驱动代写寄存器）              | 防手滑；少一环的排查成本全系列都见过                          |
| 选边沿         | EXTI RTSR/FTSR，纯边沿、无电平模式                | `IRQF_TRIGGER_FALLING` 等 flag（irq set_type）          | 同一抽象，还能表达电平触发（裸机要自己合成）                  |
| 清挂起         | ISR 手写 `EXTI->PR = 1<<line;`（w1c 陷阱）        | 通用中断层/流控代劳，handler 无感                       | 防 `\|=` 读改写清挂起这类低级错（F429 ch02 专设的陷阱节）     |
| 重入与并发     | 单核裸机 ISR 与主循环天然串行，共享数据手动关中断 | `IRQF_ONESHOT` 屏蔽重入；共享数据上自旋锁               | 多核 + 抢占的世界里「天然串行」不存在了                       |
| handler 能睡吗 | 没有「睡眠」概念（也没有别的执行流等你）          | **严禁**：中断上下文睡眠=BUG（scheduling while atomic） | 防死锁：中断上下文不进调度器，睡着就永远回不来                |
| 慢活去哪       | ISR 里自己干（时间戳消抖在 ISR 内完成）           | 底半三条路（见第 2 节），本实验用 threaded IRQ          | 防长 ISR 饿死系统：顶半长跑会推迟调度器与所有软中断           |
| 唤醒等事件者   | 主循环轮询 flag / FreeRTOS 里 FromISR 给队列      | 等待队列 `wake_up_interruptible()`                      | 让阻塞的进程（而非忙等循环）拿到事件                          |

读法提示：左列每一行都是你在 F429 上亲手做过的事，右列是 Linux 给同一件事立的「柜台」。
柜台没消灭能力，只改变了**谁有权、以什么顺序**碰它——和 ch02 的 /dev/mem 特权墙、ch03 的
ioctl 公文包是同一个故事在中断层的重演。

> 📖 **术语卡：边沿触发 vs 电平触发**
> **是什么**：边沿触发=电平**跳变的瞬间**报告一次事件（下降沿=高→低，上升沿=低→高）；
> 电平触发=只要引脚**保持**在有效电平，就持续算事件（处理完清掉才停）。
> **为什么存在**：按键这种「动作」适合边沿；持续告警（总线数据待读）适合电平。
> **类比**：webhook（事件来了推你一下）vs 占线灯（条件不满足就一直亮着提醒你）。
> ⚠️ 类比边界：电平触发处理慢会不停重触发；边沿触发遇抖动会多记——所以按键必须消抖。

表格里 Linux 列的新词按出现顺序展开：**irqdomain**（中断域——把芯片自己的硬件中断编号
翻译成内核统一 IRQ 号的翻译层，`gpiod_to_irq()` 查的就是它）；**irqaction**（挂在一条 IRQ
线上的 handler 登记项，多个可共享同一条线）；**IRQF_TRIGGER_FALLING**（边沿选择 flag：
下降沿触发）；**w1c**（write-1-to-clear，「写 1 清挂起」的寄存器语义——读改写 `|=` 会把
没处理的挂起一并误清，F429 ch02 陷阱节的主角）；**自旋锁**（拿不到锁就原地忙等的锁——
中断上下文唯一可用的锁，因为忙等不需要睡）；**scheduling while atomic**（内核发现你在
atomic 上下文里睡了时打印的 BUG 签名——监狱的警报器）。

## 2. 底半三条路：慢活的去处

中断处理被切成两半的原因只有一个：**中断上下文是监狱**。不能睡眠（拿不了 mutex）、不能
`copy_to_user`（没有可靠的进程上下文）、不该长跑（顶半期间同级以下中断全被压制）。慢活有三条
保释通道：

> 📖 **术语卡：顶半 / 底半（top half / bottom half）与 threaded IRQ**
> **是什么**：顶半=中断一发生**立刻**跑的函数（hardirq，监狱里，只做取证+安排后事）；
> 底半=稍后被安排去干慢活的另一半。threaded IRQ 是底半的现代形态：每条中断一个专属
> **内核线程**，能睡、能调度、能设优先级，`ps` 里看得见。
> **为什么存在**：监狱里干不了慢活（I2C、内存分配、打印大量日志），而回用户态再处理又太慢。
> **类比**：急诊分诊——顶半是分诊台（30 秒判断轻重），底半是专科病房（慢慢治）。
> ⚠️ 类比边界：分诊台只有一个护士；顶半跑在**所有 CPU 都可能随时被抢来**的上下文里，
> 并发风险比任何单线程场景都高。

| 路线         | 执行上下文                     | 能睡吗 | 典型用途               | 现状                                                                       |
| ------------ | ------------------------------ | ------ | ---------------------- | -------------------------------------------------------------------------- |
| threaded IRQ | 独立内核线程（可配 RT 优先级） | 能     | 按键消抖、I2C/SPI 收尾 | 现代首选（2.6.30 引入），本实验落地                                        |
| tasklet      | 软中断派生，原子上下文         | 不能   | 历史驱动的收尾         | **6.9 起上游正式标注弃用**（LWN《The end of tasklets》，2024），新代码勿用 |
| workqueue    | 内核工作线程                   | 能     | 耗时工作、可排队       | 与 threaded IRQ 的分工：不依附单次中断的重活                               |

教学纪律：tasklet 只当历史形态讲，代码落在 `request_threaded_irq()`——它是「中断也进调度器」
的最终形态：底半是一个**有名字、有优先级、能被 ps 看见**的内核线程（`irq/<n>-btnirq` 形态，
待实测）。

表里三个新词：**tasklet**（把函数推迟到「软中断时机」执行的老机制——软中断=内核预留的延期
执行窗口，仍是原子上下文）；**workqueue**（工作队列：把活儿排进一群内核工人线程，工人在
进程上下文干活、可睡）；**RT 优先级**（实时调度优先级——threaded IRQ 的底半线程可配置成
实时优先级，按键响应能跑在普通进程前面）。

> 📖 **术语卡：等待队列（wait queue）与 wake_up_interruptible()**
> **是什么**：内核「睡下等条件」的标准设施：进程在 `wait_event_interruptible(q, cond)` 处
> 睡去，别处调用 `wake_up_interruptible(&q)` 把它叫醒重查条件。
> **为什么存在**：阻塞读不能忙等烧 CPU；条件达成又得有人负责叫人。
> **类比**：你的主场——epoll 的等/醒就是同一思想的用户态版本：睡在 epoll_wait 上，事件
> 就绪被唤醒。驱动里这对函数就是内核侧的「就绪通知」。
> ⚠️ 类比边界：epoll 一个 fd 可挂多种事件；等待队列只有一个条件表达式，写在调用处。

与 FreeRTOS 的 ISR-defer 语义对照（你早已用过同一思想）：ISR 里 `xQueueSendFromISR()`（FreeRTOS
「中断里安全入队」的专用函数）+ `portYIELD_FROM_ISR()`（中断退出时立即触发一次调度），业务
逻辑留在任务里——**顶半只留个信号，业务回任务上下文**。Linux 的
threaded IRQ 是它的完全体：底半不只是任务，还是**可调度、可设优先级**的线程，能被高优先级
实时任务抢占。契约细节见
[[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|FreeRTOS 深度解析（十八）：临界区]]
与 [[2026-08-26-lwip-deep-dive-ch19-isr-and-priority-design|lwIP 深度解析（十九）：ISR 与优先级]]；
F429 侧「故意违约看 configASSERT 炸」的实验在
[[2026-08-30-f429-lab-ch12-nvic-freertos-priority-contract|F429 ch12]]。

## 3. 实验：btn_irq.ko 全代码

### 3.1 接线与按键输入的「免费上拉」

选 **GPIO4**（BCM 编号 4 = 40-pin 头物理引脚 7），按键（或杜邦线直接短接）接 GPIO4 → GND。
理由是 BCM2711 的上电默认上拉分布（手册事实）：**GPIO0–8 默认上拉、GPIO9–27 默认下拉**——
选 4 号免去外接上拉电阻，低有效按下即下降沿。避开 GPIO2/3（板载 1.8kΩ 固定上拉的 I2C1，
[[2026-08-30-rpi-lab-ch08-instrument-roles-guide|ch08]] 要用）与 GPIO8–11（SPI0，
[[2026-08-30-rpi-lab-ch06-device-tree-overlay-spi|ch06]] 要用）。默认上拉用
`pinctrl get 4` 交叉核对（输出形态待实测）。`pinctrl`（树莓派官方的引脚状态查看工具）。

几个词先对齐：**BCM 编号**（博通芯片手册里的 GPIO 序号，软件世界通用）与**物理引脚号**
（40-pin 排针上的位置 1~40）是两套编号——GPIO4 在物理引脚 7，接线时别数错；**上拉/下拉**
（引脚内部轻拉向 3.3V/GND 的电阻，防悬空脚电平乱飘）；**低有效**（按下=接地=低电平算事件，
配合默认上拉正好「不按为高、按下为低」→ 下降沿）。

### 3.2 代码

```c
// btn_irq.c — 按键 GPIO 中断：threaded IRQ + 等待队列阻塞读（教学版）
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/init.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/interrupt.h>
#include <linux/gpio/consumer.h>
#include <linux/ktime.h>
#include <linux/atomic.h>
#include <linux/wait.h>

static unsigned int gpio_line = 4;            /* GPIO4，物理引脚 7，默认上拉 */
module_param(gpio_line, uint, 0444);

static unsigned int debounce_ms = 20;         /* 与 F429 ch02 同款窗口 */
module_param(debounce_ms, uint, 0644);

static struct gpio_desc *btn;
static unsigned int btn_irq;

static atomic_t press_cnt  = ATOMIC_INIT(0);  /* 合法按压计数 */
static atomic_t events     = ATOMIC_INIT(0);  /* 未被读者取走的事件数 */
static u64 last_ns;                           /* 顶半时间戳（仅底半写，无需锁） */
static wait_queue_head_t btn_wq;

/* ---------- 顶半：硬中断上下文——不能睡、要快，只记时间戳 ---------- */
static irqreturn_t btn_top_half(int irq, void *dev_id)
{
    last_ns = ktime_get_boottime_ns();        /* 监狱里唯一该干的事：取证 */
    pr_info("btnirq: top half at %llu ns\n", last_ns);
    return IRQ_WAKE_THREAD;                   /* 申请保释：慢活去线程 */
}

/* ---------- 底半：内核线程上下文——能睡，这里做消抖与记账 ---------- */
static irqreturn_t btn_thread_fn(int irq, void *dev_id)
{
    u64 now = ktime_get_boottime_ns();

    if (now - last_ns < (u64)debounce_ms * 1000000u)
        return IRQ_HANDLED;                   /* 抖动窗口内：整段丢弃 */

    atomic_inc(&press_cnt);
    atomic_inc(&events);
    wake_up_interruptible(&btn_wq);           /* 唤醒阻塞在 read 的读者 */
    return IRQ_HANDLED;
}

/* ---------- 阻塞读：cat /dev/btnirq0 挂起等按键 ---------- */
static ssize_t btnirq_read(struct file *f, char __user *buf, size_t count, loff_t *ppos)
{
    char line[32];
    int len, ev;

    if ((f->f_flags & O_NONBLOCK) && atomic_read(&events) == 0)
        return -EAGAIN;                       /* 生产驱动要处理的非阻塞路径 */
    if (wait_event_interruptible(btn_wq, atomic_read(&events) > 0))
        return -ERESTARTSYS;                  /* 被 Ctrl-C 打断，让 VFS 收尾 */

    ev = atomic_xchg(&events, 0);             /* 一次读清掉全部积压事件 */
    len = scnprintf(line, sizeof(line), "press=%u\n", atomic_read(&press_cnt));
    if (count < len)
        return -EINVAL;
    if (copy_to_user(buf, line, len))
        return -EFAULT;
    return len;
}

static const struct file_operations btnirq_fops = {
    .owner = THIS_MODULE,
    .read  = btnirq_read,
};

static struct miscdevice btnirq_misc = {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = "btnirq0",                       /* → /dev/btnirq0 */
    .fops  = &btnirq_fops,
};

static int __init btnirq_init(void)
{
    int ret;

    btn = gpio_to_desc(gpio_line);            /* 全局号换描述符（正道是 DT，ch06 治） */
    if (!btn)
        return -ENODEV;
    gpiod_direction_input(btn);

    btn_irq = gpiod_to_irq(btn);              /* irqdomain 把 GPIO 线映射成内核 IRQ 号 */
    if (btn_irq < 0)
        return btn_irq;

    init_waitqueue_head(&btn_wq);

    ret = request_threaded_irq(btn_irq, btn_top_half, btn_thread_fn,
                               IRQF_TRIGGER_FALLING | IRQF_ONESHOT,
                               "btnirq", NULL);
    /* ONESHOT：底半线程跑完前中断线保持屏蔽——防同一线重入 */
    if (ret)
        return ret;

    ret = misc_register(&btnirq_misc);
    if (ret) {
        free_irq(btn_irq, NULL);
        return ret;
    }
    pr_info("btnirq: /dev/btnirq0 ready, irq=%u, line=%u\n", btn_irq, gpio_line);
    return 0;
}

static void __exit btnirq_exit(void)
{
    misc_deregister(&btnirq_misc);
    free_irq(btn_irq, NULL);                  /* 注销即从向量/链表摘除并释放 IRQ 号 */
    pr_info("btnirq: unloaded, total press=%u\n", atomic_read(&press_cnt));
}

module_init(btnirq_init);
module_exit(btnirq_exit);
MODULE_LICENSE("GPL");
```

对位读法（与 F429 ch02 实验二逐行对得上的地方）：

- `IRQF_TRIGGER_FALLING` ≈ `EXTI->FTSR |= 1<<line`（下降沿=按下）；但清挂起那行（`EXTI->PR = …`）
  在 Linux 里**消失了**——irqchip 层代劳。
- 顶半只做 `ktime_get_boottime_ns()` 取证，恰是 F429 ch02「ISR 里只做记时间戳、放行、退出」
  纪律的**制度化版本**：那里靠自觉，这里靠监狱。
- 消抖的 20ms 窗口逻辑原样搬进底半线程——裸机 ISR 里也能这么写，Linux 只是把它移到能睡的
  上下文里（消抖若要查 I2C 键盘控制器、要 alloc 内存，裸机 ISR 就写不了了）。
- `wait_event_interruptible` 是主循环轮询 flag 的替身：**F429 的忙等主循环，在 Linux 里是
  一个睡着的进程**。

**代码拆解：** `request_threaded_irq(btn_irq, btn_top_half, btn_thread_fn, IRQF_TRIGGER_FALLING | IRQF_ONESHOT, "btnirq", NULL)`——本章的主角，参数逐个看：

| 参数                   | 作用                                                           |
| ---------------------- | -------------------------------------------------------------- |
| `btn_irq`              | IRQ 号——`gpiod_to_irq()` 换来的内核中断号（运行期分配）        |
| `btn_top_half`         | 顶半：中断发生**立刻**执行，监狱里，只取证                     |
| `btn_thread_fn`        | 底半：内核线程里执行，能睡，干慢活（消抖/记账/唤醒读者）       |
| `IRQF_TRIGGER_FALLING` | flag：下降沿触发（按下的瞬间）                                 |
| `IRQF_ONESHOT`         | flag：底半线程跑完前中断线保持屏蔽——防同一条线重入轰炸         |
| `"btnirq"`             | 名字：显示在 /proc/interrupts 与内核线程名 `irq/<n>-btnirq` 里 |
| `NULL`                 | dev_id：共享中断线时区分「这次是谁」的身份证；独占线可为 NULL  |

代码里其他新面孔：`ktime_get_boottime_ns()`（读开机以来的纳秒时钟）；顶半返回值
`IRQ_WAKE_THREAD`（「唤醒底半线程接着干」）与底半返回值 `IRQ_HANDLED`（「处理完了」）；
`atomic_t`/`atomic_inc`/`atomic_xchg`（原子量：读改写一口气完成的整数，多核不加锁也安全；
xchg=取出旧值的同时换成新值，一行完成「取走全部积压」）；`-EAGAIN`（非阻塞模式「现在没数据
待会再来」的标准码——你的主场，非阻塞 socket 同款语义）；`-ERESTARTSYS`（进程被 Ctrl-C 打断
时返回给 VFS 的内部约定，VFS 会代为重启系统调用或向用户态返回 EINTR）；`gpio_to_desc()`
（把全局 GPIO 编号换成 gpiod 描述符；正道是从设备树拿描述符，ch06 治）。

### 3.3 编译与运行

```bash
# Makefile 在 ch04 基础上加一行 obj-m += btn_irq.o
make && sudo insmod btn_irq.ko
dmesg | tail -1                          # 模块 ready、IRQ 号
cat /proc/interrupts | grep -iE 'btn|gpio'   # 找到自己的中断行
cat /dev/btnirq0                         # 挂起（阻塞）——按一下按键才返回
```

insmod 拆解见 ch04 §2（装模块进运行中内核，要 root）。本章两个新命令：

**命令拆解：** `cat /proc/interrupts | grep -iE 'btn|gpio'`

| 部分                   | 作用                                                                |
| ---------------------- | ------------------------------------------------------------------- |
| `/proc/interrupts`     | 内核导出的中断计数表：每行一条中断线，列出各 CPU 上的触发次数与名字 |
| `grep -iE 'btn\|gpio'` | `-E` 扩展正则（`\|` 表或）、`-i` 忽略大小写，过滤出我们的行         |

**你会看到**：一行 `xx:  计数 ... btnirq`；按一次按键再查，计数上涨（抖动会一次涨好几）。
**失败了先查**：没有 btnirq 行=模块没加载成（先 `dmesg | tail` 看 ready 日志）。

`cat /dev/btnirq0` 的体验值得预告：终端**像卡死一样挂住**——那是 `cat` 的 read 落在
`wait_event_interruptible` 上睡着了，不是死机；按一下按键立即打印 `press=1` 返回，Ctrl-C
随时可打断（走的就是 `-ERESTARTSYS` 那条路）。

## 预期输出（待实测核销）

```text
$ dmesg | tail -1
btnirq: /dev/btnirq0 ready, irq=xx, line=4        # xx 为运行期分配的 IRQ 号

$ cat /proc/interrupts | grep btnirq
xx:          1  ...   btnirq  ...                 # 列头形态（CPU 计数/层级）以实测为准

$ cat /dev/btnirq0        # 终端挂起；按下按键后：
press=1                   # 再次 cat 阻塞，等待下一次按键

$ dmesg | grep 'top half' | tail -3
btnirq: top half at ...ns                          # 一次按压若抖动会看到多条（被底半丢弃）
```

## 4. 跨板彩蛋（R3.2，可选）：STM32 的按键按进 Linux

共地与 3.3V 直连规约沿用 [[2026-08-30-rpi-lab-ch01-bookworm-surgery-baseline|ch01]] 第 6 节，此处
不重复——本节是那纸规约的实战检验。**没有 F429 板的读者直接跳过本节，不影响主线。**本节
两个词：**共地**（两块板的 GND 相连，电平才有共同参考系——不共地，高低电平无从谈起）；
**推挽输出**（push-pull：引脚既能主动驱动到高、也能主动驱动到低，对照开漏输出只能拉低）。

- **STM32 侧**：KEY1 按下（引脚候选 PA0，待核对，见 F429 ch02）时翻转一根**确认空闲**的
  推挽输出 GPIO（从底边黑色长排针取，避开调试口 PB3/PB4/PA13–15 与已占用引脚；具体选脚对照
  板卡事实库丝印，待核对），同时经串口打印 `g_ms` 时间戳。
- **RPi 侧**：同一根线接 GPIO4（物理 7），沿用本章驱动（STM32 输出为推挽，默认上拉不碍事；
  翻转沿会触发下降沿中断）。
- **对账**：RPi 侧 `dmesg --time-format reltime`（或 `ktime` 时间戳）与 STM32 串口时间戳都
  折算到笔记本时钟（ch01 的 NTP 链）比对，同一次按键两侧差值应在毫秒量级——**一根杜邦线把
  两个实验室的时钟绑在了同一个事件上**。

## 与 F429/裸机对照

| 维度         | F429 裸机                | Linux threaded IRQ                             |
| ------------ | ------------------------ | ---------------------------------------------- |
| 注册时机     | 链接期（向量表写死）     | 运行期（request_irq/free_irq 随 insmod/rmmod） |
| handler 权限 | 无限（想睡也没得睡）     | 顶半零权限（atomic），底半全权限（线程）       |
| 重入防护     | 手动（关中断/PR 语义）   | IRQF_ONESHOT 一 flag                           |
| 共享数据     | `volatile` flag + 关中断 | 原子量/自旋锁（多核抢占下 volatile 不够）      |
| 崩溃半径     | ISR 死循环=整机无声砖    | 顶半睡=BUG 立爆（might_sleep 抓现行）          |

最后一行的对照值得玩味：裸机的失败模式是**静默**（八环断链无声无息，F429 ch02 开篇语），
Linux 的失败模式是**响亮**（原子上下文一睡，内核立刻 BUG/警告，`cat /proc/sys/kernel/tainted`
见红）。`might_sleep`（内核在每个可能睡眠的函数入口埋的自检点：发现调用方处在 atomic 上下文
就当场打印 BUG——监狱的电子镣铐）。官僚体系讨厌，但它把「哑火」换成了「报警」——这正是
[[2026-08-30-rpi-lab-ch02-devmem-direct-register|ch02]] 以来反复出现的那笔交易。

下一章 [[2026-08-30-rpi-lab-ch06-device-tree-overlay-spi|ch06]] 清算本章埋的最后一处裸机习俗：
`gpio_to_desc(gpio_line)` 里的硬编码 4 号——设备树的世界里，引脚不该是代码里的魔数。

## 待核对清单

- `gpiod_to_irq()` 在 BCM2711 上返回的 IRQ 号区间与 `/proc/interrupts` 里 pinctrl 相关行的形态
- BCM2711 上电默认上拉覆盖 GPIO0–8（手册事实）：`pinctrl get 4` 实测交叉验证
- 顶半 `pr_info` 打印的频率（一次按压可能触发多次抖动中断，每跳一条日志——若太吵可删）
- 底半内核线程名（`irq/xx-btnirq` 形态）与默认调度策略/优先级（`chrt -p` 查）
- `request_threaded_irq` 传 `IRQF_TRIGGER_FALLING` 时 gpio irqdomain 是否真正下到硬件边沿
  配置（对照 pinctrl 寄存器或 behavior 实测）
- R3.2 的 STM32 空闲输出引脚选脚（排针丝印核对）与两端时间戳对账精度
