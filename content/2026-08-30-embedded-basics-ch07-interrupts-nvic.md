---
title: "嵌入式硬件基础（七）：中断体系——NVIC、EXTI 与中断驱动的 UART"
date: 2026-08-30 09:00:00
description: "NVIC 寄存器解剖（ISER/ICER/IPR/优先级分组/VTOR，对照 Linux IRQ 子系统）、中断从触发到返回的完整生命周期、F407 EXTI 线映射与挂起寄存器的坑，再在 QEMU mps2-an385 上跑两个实证：SysTick 100Hz 心跳（IPSR/EXC_RETURN/COUNTFLAG 逐位验尸）与 UART RX 中断驱动 + 环形缓冲（含一个真实踩出来的 W1C 清挂起顺序 bug，只回显第一个字符的经典症状）。"
tags: [embedded, stm32, cortex-m, arm, qemu, interrupt]
---

> [!info] 嵌入式硬件基础系列 0. [[2026-08-30-embedded-basics-series-index|系列索引]] · 6. [[2026-08-30-embedded-basics-ch06-uart-protocol|上一章：UART 协议]] · 7. **第七章：中断体系** · 8. [[2026-08-30-embedded-basics-ch08-timer-systick|下一章：定时器]]（并行写作中）

# 嵌入式硬件基础（七）：中断体系——NVIC、EXTI 与中断驱动的 UART

到这里为止，本系列所有程序都是"主动式"的：CPU 想读 UART 了，就去查 STATE 寄存器；想延时了，就数循环。外设什么时候有数据、什么时候出事，CPU 一无所知——除非它一直盯着问。这就是**轮询**，它的问题不是"能不能用"，而是**账算不过来**：115200 波特率下一个字节每 86.8µs 到达一次，轮询循环必须比这更密才不丢字节，而绝大多数轮询都是白问。

操作系统的答案你已经背熟了：硬件中断 + 中断处理程序。本章把这套机制在 Cortex-M 上从顶拆到底：

- **NVIC**（Nested Vectored Interrupt Controller）：核内标准件，所有 Cortex-M 同款——使能、挂起、优先级，全部是它房间里的寄存器；
- **中断的完整生命周期**：从外设一根信号线拉高，到硬件压栈、取向量、进 ISR、返回、尾部链；
- **EXTI**：F407 在 NVIC 之外加的"GPIO 事件整形器"（QEMU 不仿真，寄存器级讲透 + 真机待验证标注）；
- **两个 QEMU 实证**：SysTick 心跳（核内中断源）与 UART RX 中断驱动 + 环形缓冲（外设中断源）——第二个实验还会真实踩中一个"只回显第一个字符"的经典 bug，把它当场验尸。

所有输出均来自本章工程 `practice/hwbasics/ch07-nvic-exti/` 的真实运行（工具链 `arm-none-eabi-gcc` 15.2.0、`qemu-system-arm` 10.1.5、`-M mps2-an385`）。

---

## 7.1 NVIC 解剖：核内标准件的六个抽屉

先给 NVIC 一个准确的定位：它不在芯片外设区（`0x40000000` 起，那里住着 UART/TIMER/EXTI 这些**芯片厂**的 IP），而在**处理器核自带的系统控制空间**（SCS，`0xE0000000` 起，[[2026-08-30-embedded-basics-ch03-arm-cortex-m-anatomy|第三章]] 讲 VTOR 时进去过）。这个位置决定了一个工程事实：**NVIC 是 ARM 的标准件，不随芯片厂变化**——你在 STM32F103、F407、GD32 的 Cortex-M 系列上写的是同一套寄存器；变的只是"接了多少条 IRQ 线"（每根线接什么外设，芯片厂说了算）。

用软件人的 IRQ 子系统做类比总表（延续 ch03 3.6 节那张表的扩展版）：

| Linux IRQ 子系统                 | Cortex-M/NVIC 对应物                                           |
| -------------------------------- | -------------------------------------------------------------- |
| APIC/IOAPIC 中断控制器           | NVIC（`0xE000E100` 起的寄存器组）                              |
| `request_irq(dev, handler)`      | 向量表槽位填函数指针（链接期注册）+ 写 ISER 使能（运行期开关） |
| `free_irq()`                     | 写 ICER 对应位（W1C 禁能，handler 还在表里但不被调度）         |
| `irq_set_affinity`/优先级        | 写 IPR 设优先级（数字越小越高，与 Linux nice 相反）            |
| `/proc/interrupts` 计数          | 读 ISER/ISPR 的回读值（gdb 直接看，见 7.5 节）                 |
| `disable_irq()`/`local_irq_save` | PRIMASK/BASEPRI（ch03 挂账的三个屏蔽寄存器，7.7 节兑现）       |
| 下半部 softirq/tasklet           | 尾部链 + "ISR 置标志、主循环消费"（本章环形缓冲就是标准姿势）  |

NVIC 的寄存器按功能分成六类（地址依据 ARMv7-M ARM，DDI 0403E.b，§B3.4；以下均以 mps2-an385 的 32 条 IRQ 为例，一个 32 位寄存器管 32 条线，更多 IRQ 时有 ISER1/ICER1…成组扩展）：

| 寄存器      | 地址         | 写 1 的效果         | 读的语义         | 心智模型                     |
| ----------- | ------------ | ------------------- | ---------------- | ---------------------------- |
| ISER0       | `0xE000E100` | 使能对应 IRQ（W1S） | 读回当前使能状态 | `atomic_or(enable_mask)`     |
| ICER0       | `0xE000E180` | 禁能对应 IRQ（W1C） | 同样读回使能状态 | `atomic_andnot(enable_mask)` |
| ISPR0       | `0xE000E200` | 软件触发挂起（W1S） | 读回挂起状态     | `raise_softirq()`            |
| ICPR0       | `0xE000E280` | 清挂起（W1C）       | 读回挂起状态     | 撤销尚未派发的请求           |
| IPR[0..31]  | `0xE000E400` | 字节宽，设优先级    | 读回优先级       | 每 IRQ 一字节的优先级表      |
| （SCB）VTOR | `0xE000ED08` | 重定位向量表        | 读回向量表基址   | idt 的物理地址寄存器         |

四个细节，每个都值得停一秒：

1. **ISER/ICER 不是普通内存**。它们是"写 1 生效、写 0 无副作用"的特种寄存器：`ISER0 = 1` 只会置位 bit0，**不会**把其它 31 个使能位清零。所以裸机代码写 `NVIC_ISER0 = (1u << irq);` 是对的，写成 `|=` 反而多一次无意义的读改写。同理禁能是 `ICER0 = (1u << irq);`——想一次关多个就一次写多个位，硬件按位解释；
2. **ISPR 是"软件中断"**。写 1 就能让对应 IRQ 进入挂起，不需要任何外设配合——调试 ISR、测试中断路径时用它，不用拿杜邦线去戳引脚；
3. **挂起是"记事本"不是"开关"**。IRQ 线只是一根电平信号，NVIC 收到后**置挂起位**；如果此刻中断被屏蔽或优先级不够，请求不会丢，挂起位替你记着，等条件满足再派发。这也是"中断标志要在哪一层清"这类问题的根源（7.4/7.6 节两次撞上）；
4. **VTOR 在 SCB 不在 NVIC**（`0xE000ED08`，第三章读出过 0）。它管理的对象是整张向量表，所以归"系统控制块"管；对齐要求不低于表大小向下取 2 的幂（本工程 48 项表=192B → 对齐 256B），bootloader 跳应用时的第一件事就是改它。

---

## 7.2 优先级：4 位天花板、抢占与子优先级、以及"全部抢占"惯例

IPR 是每 IRQ 一个字节的优先级字段，但 **F407 只实现高 4 位**（RM0090 §4 与 ST 头文件 `__NVIC_PRIO_BITS = 4`），所以有效优先级只有 16 级，写入时习惯左移 4 位：

```c
NVIC_IPR[0] = 2u << 4;   /* 优先级 2；低 4 位 F407 读回恒 0，写了也白写 */
```

**数字越小优先级越高**（0 最高），这一点和 Linux nice 值方向一致、和直觉相反，第一次写反是成长必修课。

### 1. 优先级分组：一个字节掰成两半用

ARMv7-M 允许把这 4 位掰成"抢占优先级 + 子优先级"两段，切分点由 SCB->AIRCR（`0xE000ED0C`）的 PRIGROUP 字段（bit10:8）决定。写 AIRCR 前 16 位必须写入魔数 `0x5FA`（VDDKEY），防手滑。对 F407（4 位实现）的分组表（DDI 0403E.b §B3.4.7 通用表裁剪到 4 位）：

| PRIGROUP | 抢占位:子位 | 效果                               |
| -------- | ----------- | ---------------------------------- |
| 0 ~ 3    | 4 : 0       | 16 级全抢占（复位默认即此档）      |
| 4        | 3 : 1       | 8 级抢占 × 2 级子                  |
| 5        | 2 : 2       | 4 × 4                              |
| 6        | 1 : 3       | 2 × 8                              |
| 7        | 0 : 4       | 0 抢占 × 16 子（任何中断都不嵌套） |

两段的分工：

- **抢占优先级不同**：高优 ISR 可以打断低优 ISR——**嵌套**；
- **抢占相同、子优先级不同**：正在执行的不被打断，但两个同时挂起时**子优先级决定先派发谁**——只是排队顺序，不是嵌套能力。

### 2. 为什么实际项目几乎都用"全部抢占"

```c
SCB->AIRCR = (0x5FA << 16) | (0x5 << 8) | (SCB->AIRCR & 0xFFFF); /* 别这么干 */
```

三个理由，从软到硬：

1. **子优先级解决的问题太少**。它只在"多个同抢占级中断同时挂起"时改变派发顺序——这种场景多数项目一年遇不上一次，为此牺牲一半（或全部）嵌套能力不划算；
2. **RTOS 的要求**。FreeRTOS 的 `configMAX_SYSCALL_INTERRUPT_PRIORITY` 机制（可调 `FROM_ISR` API 的中断门槛）作用在**抢占优先级**字段上；分组不一致会让"哪些中断允许调用 API"的推理从一条规则变成一张表。详见 [[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|FreeRTOS 系列（十八）：临界区]] 里 BASEPRI 掩码的位宽分析；
3. **可移植性**。不同芯片实现的优先级位数不同（M3/M4 常 4 位，M0 根本没有分组——M0 的 PRIGROUP 字段不存在），"全部抢占"在所有核上语义一致。

所以 ST 的新版 HAL 模板默认 `HAL_NVIC_SetPriorityGrouping(NVIC_PRIORITYGROUP_4)`，而 v7-M 复位值 PRIGROUP=0 在 F407 上本来就等价于 4:0——**惯例即默认，代码里显式写一遍是为了可读不是为改行为**。

---

## 7.3 中断的完整生命周期：从一根线到 `bx lr`

把全流程串成一条时间线（编号对应图中箭头），硬件步骤依据 DDI 0403E.b §B1.5（异常模型）——压栈顺序与栈帧布局第三章已用 gdb 逐字实证过，这里只引用结论：

```text
外设事件 ──①──> IRQ 线拉高（电平信号）
                  │
                  ▼
        ②NVIC 置挂起位(ISPR 可见)，做优先级仲裁：
          挂起的最高优先级 > 当前执行优先级？
          ├── 否：记账，等（挂起位就是记事本）
          └── 是：③硬件自动压栈 8 寄存器到 MSP（ch03 的栈帧）
                  ④取向量：PC = 向量表[16+IRQn]，LR = EXC_RETURN
                  ⑤IPSR = 异常号，切 Handler 模式
                  ▼
              ISR 执行（读数据 / 清挂起源 / 塞缓冲）
                  │
                  ▼
        ⑥bx lr 触发异常返回：出栈 8 寄存器，恢复现场
                  │
        还有挂起？──是──> 尾部链：跳过出栈再入栈，直接派发下一个
                  否
                  ▼
              原来被打断的代码继续，完全无感
```

三个关键机制补注：

**抢占（preemption）**：③ 发生在 ISR 执行中同样成立——中断嵌套就是"ISR 里又来了一次 ②③④"。栈消耗按嵌套深度叠加（每层 8 字 + ISR 局部变量，全压在 MSP 上），这就是 ch03 说"任务栈不用预算中断深度、handler 永远用 MSP"的账本视角。

**迟来的高优中断（late-arriving）**：如果更高优先级的异常在 ③ 压栈进行中到达，硬件放弃当前入栈、先服务后来者，已压的帧直接复用——不做"压完再退栈"的傻事。

**尾部链（tail-chaining）**：⑥ 退出时若还有挂起，硬件把刚压的栈帧**原样移交**给下一个 ISR，省掉出栈+再入栈的来回。Cortex-M3 TRM 给的数字：普通中断进入约 12 周期，尾部链约 6 周期。中断风暴下 Cortex-M 依然从容，靠的就是它——对照软件派发（RISC-V 的 trap 入口要自己读 mcause、查表、跳转，见 [[2026-08-30-embedded-basics-ch09-riscv-gd32-contrast|第九章]]），这套硬件查表是"用晶体管换延迟"的典范。

还有一对容易混的状态词，钉死在这里：**active**（正在执行该 ISR，硬件在异常进入时自动置位、返回时清零）与 **pending**（请求已记录、尚未派发）。v7-M 没有给软件读 active 的通用寄存器，pending 则随时可读（ISPR）。一个 IRQ 可以同时 pending + active——典型场景：ISR 执行中同源又来了一次请求。

---

## 7.4 EXTI：F407 的"GPIO 事件整形器"（寄存器级，真机待验证）

NVIC 的 32/82 条 IRQ 线里没有一根属于 GPIO（F407 上 GPIO 是"静默外设"，没有中断输出）。想让"引脚上出现一个边沿"变成中断，中间要经过 **EXTI**（Extended Interrupt/Event controller，RM0090 早期修订 §10，17+ 修订改编号为 §13——查手册时认章名不认章号）这一层整形。

> [!warning] QEMU 边界
> mps2-an385 上没有 EXTI/GPIO 中断模型（`hw/arm/mps2.c` 里 0x40010000 的 GPIO 是 `create_unimplemented_device` 占位），本节为寄存器级讲解 + 真机待验证，依据 RM0090 §10（EXTI）与 §7（SYSCFG）。

### 1. 线映射：EXTI 线不是 GPIO 引脚的别名，是"同号聚合"

EXTI 提供 23 根线，其中 **线 0-15 与 GPIO 引脚号对应**——注意是"按引脚号聚合"：EXTI0 可以接到 **任意端口** 的 pin0（PA0 或 PB0 或 PC0……，一时刻只选一个），选择器是 **SYSCFG_EXTICR1~4**（每寄存器 4 个线槽，每槽 4 位选端口 A~H）。线 16-22 是内部事件（PVD、RTC 闹钟、USB 唤醒等），不走 GPIO。

```c
/* 例：PB0 下降沿中断（SYSCFG 时钟需先开，RM0090 §7）
 * SYSCFG->EXTICR[0] 槽 0 选端口 B：0000=A 0001=B ...        */
SYSCFG->EXTICR[0] = (SYSCFG->EXTICR[0] & ~0xFu) | (1u << 0);
EXTI->FTSR = 1u << 0;   /* 下降沿触发选择（RTSR=上升沿，双沿=两个都写） */
EXTI->IMR = 1u << 0;    /* 中断未屏蔽（EMR 是"事件"通路，DMA 唤醒用）    */
/* 此后 PB0 每个下降沿 → EXTI 挂起 PR0 → NVIC IRQ6（EXTI0 的向量表槽） */
```

于是有了那个著名推论：**PA0 和 PB0 的中断不能同时用**（同抢 EXTI0 线），但 PA0 和 PA1 可以（不同线）。这不是 GPIO 的限制，是 EXTI 映射法的代价——换取 16 根线服务上百个引脚的复用。

### 2. 挂起寄存器 PR：写 1 清零，以及它的三个坑

EXTI->PR（挂起寄存器）的行为一句话：**边沿出现就置位（不管 IMR 有没有开），软件写 1 清零，写 0 无效**。围绕它的三个经典坑：

1. **忘了清**。ISR 里不写 `EXTI->PR = 1u << n;`，异常返回时挂起仍在 → 立刻重入同一个 ISR，死循环刷中断。症状特征：系统"卡死"但 `[hb ]` 之类的心跳停更，jstack 式排查第一条就是查挂起位；
2. **读改写清**。`EXTI->PR |= 1u << n;` 是读出全表、改一位、整字写回——写回的那些"1"会**顺带清掉**在你读和写之间刚置位的**其它线**的挂起，对应中断凭空丢失。正确姿势是直接写常量 `EXTI->PR = 1u << n;`（哪怕顺手清了自己也无妨，本来就该清）。这是 W1C 寄存器与普通内存语义冲突的第一现场，7.6 节 QEMU 实测的 INTSTATUS 同款；
3. **双层挂起的顺序**。EXTI.PR 与 NVIC.ISPR 是两级锁存：边沿 → EXTI.PR 置位 → （IMR 开着）→ NVIC 挂起 → 派发。ISR 里清的是源头 EXTI.PR；NVIC 侧的挂起在异常进入时已自动清（active 状态接管），**不需要**也不应该去碰 ICPR。把两级都手动清一遍的人，通常是在掩盖"没清对源头"的 bug。

> [!note] 与 GD32 的对照预告
> EXTI 是**芯片层**的中断扩展件，与内核无关；GD32VF103 侧对应的是 EXINT（寄存器名 EXTICR/RTSR/FTSR/PR 都几乎一样），差异在它把请求送进的是 **ECLIC** 而不是 NVIC——ECLIC 的非向量设计（统一入口、软件读 mcause 分发）与 NVIC 的硬件查表是两套哲学，[[2026-08-30-embedded-basics-ch09-riscv-gd32-contrast|第九章]] 展开。

---

## 7.5 QEMU 实证一：SysTick 心跳——核内中断源的最小闭环

**SysTick 是本章最合适的第一发实验弹**：它是 Cortex-M 核内标准件（DDI 0403E.b §B3.3），任何 Cortex-M 都有、QEMU 必仿真、不依赖任何芯片层外设——一个中断源 + 三行配置就能验证"向量表挂 handler → 计数器翻转 → ISR 执行"全链路。它也是将来 RTOS 的心跳（ch08、ch12 的主角），现在先把它点亮。

### 1. SysTick 三件套：一个 24 位倒计数器

| 寄存器   | 地址         | 关键位                                                                         |
| -------- | ------------ | ------------------------------------------------------------------------------ |
| SYST_CSR | `0xE000E010` | bit0 ENABLE、bit1 TICKINT（到 0 触发异常 15）、bit2 CLKSOURCE、bit16 COUNTFLAG |
| SYST_RVR | `0xE000E014` | 24 位重装载值，计数到 0 后自动回填                                             |
| SYST_CVR | `0xE000E018` | 当前计数值；写任意值清零（同时清 COUNTFLAG）                                   |

它的工作模型是"减到 0 就闹一次"：ENABLE 后 CVR 每个时钟减 1，减到 0 → 下个周期回填 RVR、置 COUNTFLAG；若 TICKINT=1，同时向内核发 SysTick 异常（异常号 15，向量表槽 15，**不走 IRQ 线**——所以 mps2.c 的 IRQ 表里找不到它）。CLKSOURCE 选 0/1 分别接外部参考时钟/处理器时钟，mps2-an385 上对应 1MHz/25MHz（`REFCLK_FRQ`/`SYSCLK_FRQ`，见 ch04 的时钟考证表）。

### 2. 工程：把 ch04 模板的向量表换成具名槽

工程 `practice/hwbasics/ch07-nvic-exti/`，底座即 ch04 模板，核心差异是向量表的 32 个 IRQ 槽从 `.rept 32 Default_Handler` 展开成带注释的具名槽（完整映射考证见下节），SysTick 直接用强符号覆盖：

```c
#define SYST_CSR (*(volatile uint32_t *)0xE000E010UL)
#define SYST_RVR (*(volatile uint32_t *)0xE000E014UL)
#define SYST_CVR (*(volatile uint32_t *)0xE000E018UL)

#define TICK_HZ 100UL

static volatile uint32_t g_tick;

static void systick_init(void)
{
    SYST_RVR = 25000000UL / TICK_HZ - 1;  /* 25MHz/100 - 1 = 249_999 */
    SYST_CVR = 0;                         /* 清当前值，首周期从满装值起算 */
    SYST_CSR = (1UL << 0) | (1UL << 1) | (1UL << 2); /* ENABLE|TICKINT|CLKSOURCE=CPU */
}

void SysTick_Handler(void)  /* 链接期"注册"：覆盖 startup.S 的弱符号 */
{
    g_tick++;              /* ISR 里只做这一次访存，打印全部留给主循环 */
}
```

两个数字先算好：LOAD=249_999 在 24 位上限（0xFFFFFF=16_777_215）之内；而"想要 1Hz 直接装 25M-1"会**静默截断**成 16_777_214（≈0.67Hz）——24 位倒计数器的天花板，168MHz 的 F407 真机上更紧，**高频计数 + 软件分频**是唯一通用解。这里选 100Hz 分频，正好是 ESP-IDF 里 FreeRTOS 的默认 `configTICK_RATE_HZ`，为 ch08 预演。

### 3. 真实运行（`make run-heart`，6 秒无输入）

```text
$ make run-heart        # = timeout 6 qemu-system-arm -M mps2-an385 -kernel \
                        #   build/ch07-nvic-exti.elf -display none -serial stdio </dev/null

ch07: systick + uart rx irq
SYST_RVR=249999 (tick=100Hz)  UART0 RX=IRQ0 enabled
ISER0=0x00000001 IPR[0]=0x00000020 (prio<<4)  VTOR=0x00000000

[hb ] tick=0 sec=0
[hb ] tick=100 sec=1
[hb ] tick=200 sec=2
[hb ] tick=300 sec=3
[hb ] tick=400 sec=4
[hb ] tick=500 sec=5
```

验尸三条：

- `tick` 每秒恰好 +100——**墙钟 6 秒跑出 5 个整周期**，证明 CLKSOURCE=1 真接的是 25MHz 处理器时钟（若接的是 1MHz refclk，100 拍要 25 秒，输出会慢 25 倍——这个"时钟源接错"的定量鉴别法本身就是排坑工具）；
- `tick=0 sec=0` 立即出现是刻意设计（`last_sec` 初值取不等值），顺带证明 ISR 在第一条心跳打印前已被调度过；
- banner 里 `ISER0=0x00000001`、`IPR[0]=0x20` 是程序自己读回打印的（下一实验的 NVIC 配置已生效），`VTOR=0x00000000` 与第三章 gdb 读数一致。

### 4. gdb 亲眼看 NVIC：IPSR、EXC_RETURN 与 COUNTFLAG

gdbstub 断在 `SysTick_Handler` 入口，把 7.1/7.2 的寄存器一次读齐（`-S -gdb tcp::1237` 挂起启动，Fedora 原生 gdb `set architecture arm` 直连，ch03 同款工位）：

```text
(gdb) x/2wx 0x40          # 向量表槽 16/17（IRQ0/IRQ1，实验二用）
0x40 <_vectors+64>:  0x00000201  0x000000eb
(gdb) break SysTick_Handler ; continue
Breakpoint 1, SysTick_Handler () at main.c:119
(gdb) info registers pc lr xpsr
pc      0x1f0   0x1f0 <SysTick_Handler>
lr      0xfffffff9  -7
xpsr    0x6100000f
(gdb) x/wx 0xE000E100     # ISER0
0xe000e100:  0x00000001
(gdb) x/2bx 0xE000E400    # IPR[0..1]
0xe000e400:  0x20  0x00
(gdb) x/wx 0xE000E010     # SYST_CSR
0xe000e010:  0x00010007
```

逐位拆解，每一项都对着前文某一条：

- **xpsr = 0x6100000f**：低 9 位 IPSR = 0x0F = **15**——SysTick 的异常号（ch03 讲过 xPSR 三合一，这次是在真 ISR 里读到它）；T 位=1；
- **lr = 0xfffffff9**：EXC_RETURN，"返回 Thread 模式 + MSP"——我们在 Thread+MSP 的主循环里被中断，硬件编码分毫不差（ch03 3.5 的表）；
- **ISER0 = 0x1**：IRQ0 已使能（实验二的 UART0 RX，见下）；**IPR[0] = 0x20**：优先级 2<<4 已生效；
- **SYST_CSR = 0x00010007**：低 3 位 ENABLE|TICKINT|CLKSOURCE，而 **bit16 = COUNTFLAG 置位**——gdb 这次读之前计数器到过 0；按架构定义**读 CSR 的动作本身会清掉它**，下次读就只剩 0x7。一个位，把"读清型状态位"的语义演完了。

---

## 7.6 QEMU 实证二：UART RX 中断驱动——外设 IRQ 号考证 + 环形缓冲 + 一个真实的 W1C 坑

第二个实验换外设中断源，任务具体：把 [[2026-08-30-embedded-basics-ch06-uart-protocol|第六章]] 的轮询 RX 改成**中断驱动 + 环形缓冲**。开工前必须先回答一个 SPEC 级问题：**mps2-an385 的 UART0 RX 到底是几号 IRQ？**

### 1. IRQ 号考证：读 QEMU 源码，不猜

QEMU 文档只列机型不列 IRQ 表，数字在 `hw/arm/mps2.c`（v10.1.5）里。FPGA_AN385 分支的关键行：

```c
static const int uartirq[] = {0, 2, 4, 18, 20};   /* RX irq number; TX irq is always one greater */
...
sysbus_connect_irq(s, 0, qdev_get_gpio_in(armv7m, uartirq[i] + 1));  /* TX */
sysbus_connect_irq(s, 1, qdev_get_gpio_in(armv7m, uartirq[i]));      /* RX */
...
int irqno = 8 + i;    /* timer0/1 = IRQ8/9，dualtimer 显式接 IRQ10 */
```

整理成表（这也是工程 startup.S 注释与向量表槽位的依据）：

| NVIC IRQ     | 设备                        | 备注                                 |
| ------------ | --------------------------- | ------------------------------------ |
| 0 / 1        | UART0 RX / TX               | `uartirq[0]=0`，TX=RX+1              |
| 2 / 3，4/5   | UART1、UART2 RX/TX          | 同规则                               |
| 8 / 9 / 10   | Timer0 / Timer1 / DualTimer | ch08 的入场券                        |
| 12           | UART0-2 收发溢出（6 线 OR） | 共享一根线，ISR 里查各 UART 溢出位   |
| 13           | LAN9118 以太网              |                                      |
| 18/19，20/21 | UART3、UART4 RX/TX          | `uartirq[3]=18`、`uartirq[4]=20`     |
| ——           | SysTick                     | 核内异常 15，不占 IRQ 号（上一实验） |

**UART0 RX = IRQ0**，即向量表槽 16+0、异常号 16。对照 STM32：F407 的 USART2 中断是 IRQ38（RM0090 §10.1.3 向量表）——号完全不同、机制完全相同，这就是 7.1 说的"NVIC 标准件 + 芯片厂布线"。

### 2. 三步接一根中断线

外设中断的"注册"只有三步，缺一不可（对照 `request_irq()` 的两步：注册 handler + 使能 irq；Cortex-M 把"注册 handler"拆成了链接期的向量表覆盖）：

```c
/* ① 链接期注册：向量表槽 16 填强符号（startup.S 弱符号被覆盖） */
void UART0_RX_Handler(void) { ... }

/* ② 运行期使能：NVIC 侧（优先级 + ISER） */
NVIC_IPR[0]  = 2u << 4;            /* 优先级 2，低于 SysTick（复位默认 0） */
NVIC_ISER0   = 1UL << 0;           /* 使能 IRQ0（W1S，不是 |=） */

/* ③ 运行期使能：外设侧——RX 中断使能位（CMSDK UART CTRL bit3） */
UART0_CTRL = UART_CTRL_TX_EN | UART_CTRL_RX_EN | UART_CTRL_RX_INTEN;
```

优先级故意给 2：SysTick（复位默认 0）可以抢占串口 ISR——心跳不许被字节流插队，这是 7.2 分组哲学的落地。

### 3. ISR 与环形缓冲：生产者-消费者的最小实现

```c
#define RING_SIZE 32u                     /* 必须 2 的幂：掩码代替取模 */
#define RING_MASK (RING_SIZE - 1u)
static volatile uint32_t g_head;          /* 写指针：只有 ISR 动 */
static volatile uint32_t g_tail;          /* 读指针：只有主循环动 */
static volatile uint8_t  g_ring[RING_SIZE];

void UART0_RX_Handler(void)
{
    UART0_INTST = UART_INTST_RX;          /* 先清挂起（W1C），再读数据！坑见下 */
    if (UART0_STATE & UART_STATE_RXFULL) {
        uint8_t c = (uint8_t)UART0_DATA;  /* 读 DATA 顺带清 RXFULL */
        uint32_t h = g_head;
        if (h - g_tail >= RING_SIZE)
            g_rx_drop++;                  /* 满：丢字节保 ISR 短命 */
        else {
            g_ring[h & RING_MASK] = c;
            g_head = h + 1;
        }
    }
}
```

单生产者（ISR）单消费者（主循环）、head/tail 各只归一侧写、32 位对齐访问在 M3 上单条指令完成——这三条凑齐，环形缓冲**不需要任何锁**。这是并发世界少有的免费午餐，代价是纪律：谁破例谁背锅。

主循环消费端 + 睡眠（完整代码见工程 main.c）：

```c
for (;;) {
    uint32_t sec = g_tick / TICK_HZ;
    if (sec != last_sec) { /* 心跳打印 */ }
    while (g_tail != g_head) { /* 取字节；行尾打印统计行 */ }
    __asm volatile ("wfi");   /* 没活睡，任意中断唤醒 */
}
```

### 4. 轮询 → 中断 → 环形缓冲：为什么值得升两级架构

| 方案            | CPU 占用（无数据时） | 丢字节风险         | 复杂度                 |
| --------------- | -------------------- | ------------------ | ---------------------- |
| 轮询 RX         | 100%（空转查 STATE） | 主循环稍忙即溢出   | 最低                   |
| 中断 + 立即处理 | 近 0（wfi 睡眠）     | ISR 处理慢于到达率 | 中（ISR 里干重活违禁） |
| 中断 + 环形缓冲 | 近 0（wfi 睡眠）     | 缓冲深度兜底突发   | 中（本节）             |

CPU 效率账（25MHz、115200-8N1）：一个字节 10 bit ≈ 86.8µs，轮询 10 条指令的循环约 0.4µs/圈——想不丢就得每 87µs 至少查一次，占 CPU 的下限是 0.4/86.8 ≈ 0.5%，看着不多？**这是"只有 UART"时的账**。真实系统 5 个外设都这么轮询，加上"查完什么都没有"的总线往返，空转就吃掉两位数百分比；更糟的是轮询把**延迟耦合**进主循环——任何一段长任务都会让 RX 溢出。中断翻转责任关系：**外设有事才花 CPU**，`wfi` 让无活时功耗和占用同时归零。环形缓冲再解耦两级速率：字符到达率（µs 级、成串突发）与处理率（行级、ms 级）之间放一段弹性内存。这套"ISR 顶半部收集、主循环底半部处理"，就是内核 softirq 的裸机前身。

### 5. 真实踩坑：清挂起的顺序，一个 bug 的完整验尸

第一版 ISR 顺手写成了"读数据 → 清挂起"（直觉顺序），真实运行（`make run-rx`，注入 `nvic alive\r` + `irq driven uart\n`）：

```text
[hb ] tick=0 sec=0
[hb ] tick=100 sec=1
n[hb ] tick=200 sec=2        ← 只有孤零零一个 'n'，其余 9 个字节人间蒸发
[hb ] tick=300 sec=3
...                          ← 没有任何 [rx ] 行，心跳照常
```

症状：**只回显第一个字符**，且之后 5 秒再无 RX 动静。结合 QEMU 模型源码（`hw/char/cmsdk-apb-uart.c`）逐事件还原：

1. 字节 `'n'` 到达 → `intstatus.RX` 置位 → IRQ0 派发，ISR 进入；
2. ISR 读 `DATA`——模型在这一步**同步**调用 `qemu_chr_fe_accept_input()`，后端立刻把下一个字节 `'v'` 推进来：RXFULL 置位、`intstatus.RX` **再次置位**（通知"还有一个"）；
3. ISR 接着执行 `UART0_INTST = RX`（W1C）——把第 2 步刚置的通知**一并清掉**；
4. 结果：`'v'` 躺在接收缓冲里，`intstatus.RX=0`，中断线是低的——**这个字节的通知永久丢失**，而且 RXFULL 不清，`uart_can_receive()` 恒返 0，后续 8 个字节全部堵在 chardev 里。

修法即上面代码的样子：**先 W1C 清挂起，再读数据**。清完之后再到达的任何字节会重新置位挂起 → 新的 IRQ → ISR 再进——一个不丢。修复后真实输出：

```text
$ make run-rx      # 启动 2s 后注入 "nvic alive\r"，再 1s 后注入 "irq driven uart\n"

[hb ] tick=0 sec=0
[hb ] tick=100 sec=1
nvic alive[rx ] line done: 10 bytes, irq=11 rxirq_total, drop=0
[hb ] tick=200 sec=2
irq driven uart[rx ] line done: 15 bytes, irq=27 rxirq_total, drop=0
[hb ] tick=300 sec=3
[hb ] tick=400 sec=4
[hb ] tick=500 sec=5
[hb ] tick=600 sec=6
[hb ] tick=700 sec=7
```

对账：第一行 10 字节 + CR，中断 11 次（11=1+10）；第二行 15 字节 + LF，累计 27 次（27=11+16）。`drop=0` 说明 32 字节缓冲在主循环毫秒级消费下绰绰有余。**这不是 QEMU 的仿真 bug**——它是"W1C 挂起源 + 数据寄存器读触发流控"这类真实硬件的标准陷阱（STM32 的 USART SR/DR 清标志顺序、7.4 节 EXTI->PR 的读改写坑，同族），仿真器只是免费送了我一次真机排错体验。

---

## 7.7 ISR 编写军规（裸机通用版）

本章两个实验够提炼一份清单了。按"违反代价"从高到低排：

1. **短**。ISR 只做"搬数据、置标志、清挂起"，业务逻辑全部下沉主循环/线程。衡量标准：进 ISR 到出 ISR 的最坏周期数。本章 SysTick ISR 是 1 次访存，心跳打印在主循环——打印一次几 ms，放 ISR 里等于给全系统中断延迟加了 ms 级底噪；
2. **无阻塞、无重入地雷**。不在 ISR 里等 TXFULL 清零（等谁？）、不 delay、不 printf（它俩经常二合一）、不碰任何可能被主循环以非原子方式使用的结构；
3. **共享变量一律 `volatile`**。`g_tick` 若不加，编译器完全有权把 `while (g_tick == last)` 优化成读一次死循环——中断改了内存它也不看。volatile 只解决"可见性/不做激进优化"，**不解决原子性**，见第 4 条；
4. **原子性看位宽与访问序列**。M3 上对齐的 32 位读/写是单条指令、天然原子；`g_tick / TICK_HZ` 是"读-算-用"三步，中途被改得到的可能是撕裂数据吗？32 位单读不会撕裂，但**多变量复合不变量**（如 head+缓冲内容、`sec` 与 `rx` 统计的成对一致）必须临界区保护：裸机用 `PRIMASK`（一键关中断）或 `BASEPRI`（只关"不高于 N"的，FreeRTOS 同款、允许高优穿透），RTOS 下还有互斥量——完整光谱见 [[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|FreeRTOS 系列（十八）：临界区与自旋锁]]，ch03 挂账的三个屏蔽寄存器到此兑清；
5. **清挂起源，注意顺序与方式**。外设挂起寄存器（EXTI->PR、UART INTSTATUS）写常量直清，不读改写；"先清后读数据"（本章实证）；NVIC 侧挂起异常进入时硬件自动清，别画蛇添足写 ICPR；
6. **嵌套预算栈**。抢占开启时每层嵌套至少 8 字硬件栈帧 + ISR 自身局部变量，全在 MSP。深嵌套场景按"最深链 × 单层开销"预算 MSP 余量；
7. **能被 gdb 断住的不算黑盒**。IPSR 告诉你"在几号异常里"，ISER/ISPR 告诉你"谁开着、谁挂着"——中断问题的一半排查发生在这些寄存器上，另一半发生在清挂起的顺序上。

---

## 7.8 小结与下一章

本章把"中断"从名词拆成了机制清单，全部结论有 QEMU 实证背书：

- **NVIC**：核内标准件（SCS `0xE000E100` 起），ISER/ICER（W1S/W1C 特种语义，实测读回 `0x1`）、ISPR（软件触发）、IPR（F407 高 4 位 16 级，实测 `0x20`）、VTOR（实测 0）；
- **优先级**：抢占 vs 子优先级由 AIRCR.PRIGROUP 分组（4 位实现的分组表），工程惯例"全部抢占"——RTOS 门槛机制与可移植性双重理由；
- **生命周期**：IRQ 线 → 挂起记账 → 优先级仲裁 → 硬件压 8 寄存器（ch03 实证的栈帧）→ 取向量进 ISR → `bx lr` 出栈；尾部链（12→6 周期）与迟到高优是延迟优化的两板斧；
- **EXTI**：F407 的 GPIO 事件整形层，EXTI0-15 按引脚号聚合并经 SYSCFG_EXTICR 选端口；PR 写 1 清零，忘清=重入死循环、读改写=丢别人通知（真机待验证节）；
- **实证一**：SysTick 三件套配出 100Hz 节拍（24 位上限与分频的取舍），gdb 里 IPSR=15、EXC_RETURN=0xfffffff9、COUNTFLAG 逐位验明；
- **实证二**：UART0 RX=IRQ0（mps2.c uartirq 考证），三步接线（向量表强符号 + ISER + CTRL 位）+ 单生产者单消费者环形缓冲；真实踩中并修复"先读后清"的 W1C 顺序坑——只回显第一个字符的经典症状从此有案底。

NVIC 到此是熟人了。下一章 [[2026-08-30-embedded-basics-ch08-timer-systick|第八章：定时器]] 把已经在手的 SysTick 体系化：SysTick 源码级深读（我们刚用过它的三件套）、通用定时器的预分频/ARR 计算链（Timer0/1/DualTimer 的 IRQ8/9/10 槽位已在本章向量表里留好）、PWM 思想，以及"心跳"如何长成 RTOS 的调度节拍。再往后 [[2026-08-30-embedded-basics-ch09-riscv-gd32-contrast|第九章]] 转进 RISC-V：GD32VF103 的 ECLIC 没有硬件查表的向量分发，统一入口 + 软件读 mcause 是另一条路线，届时本章每一节都会有一张 ECLIC 对照表。

---

## 参考

- ARMv7-M Architecture Reference Manual（DDI 0403E.b）：§B1.5（异常模型：进入/返回/尾部链/迟到）、§B3.2（SCS：VTOR/AIRCR 及 PRIGROUP）、§B3.3（SysTick 三件套）、§B3.4（NVIC 寄存器：ISER/ICER/ISPR/ICPR/IPR）
- ARM Cortex-M3 Technical Reference Manual：中断延迟 12 周期 / 尾部链 6 周期数据
- ST RM0090（STM32F407 参考手册）：§4（NVIC 与优先级实现位数）、§7（SYSCFG，EXTICR1~4）、§10（EXTI；§10.1.3 完整向量表，§10.3 EXTI 寄存器组。修订 17+ 起章节重编号为 §11/§13，认章名）
- ST PM0214（STM32 Cortex-M4 编程手册）：NVIC/SysTick 编程模型的 ST 官方转述
- QEMU v10.1.5 源码：`hw/arm/mps2.c`（uartirq[]/timerirq 映射、SYSCLK_FRQ/REFCLK_FRQ、num-irq=32）、`hw/char/cmsdk-apb-uart.c`（CTRL/INTSTATUS 的 W1C 与 accept_input 流控）
- 本系列 SPEC：`practice/hwbasics/SPEC.md` §3 验证纪律、§6 验收清单
- 本章实验工程：`practice/hwbasics/ch07-nvic-exti/`（含 README、完整复现命令与 IRQ 号考证表）
