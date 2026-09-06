---
title: PendSV 单步：亲眼看上下文切换
date: 2026-08-30 04:45:00
description: F429 裸机实验室（十七）——DAP 断点 + 单步 xPortPendSVHandler：PendSV 的「最低优先级 + 挂起待办」设计、MSP/PSP 双栈、port.c 逐行走读配本机 ELF 反汇编实拍、R4–R11 一个字一个字落栈的逐步快照，与 Xtensa 端口的镜像对照
tags: [f429-lab, STM32, FreeRTOS, PendSV]
---

# PendSV 单步：亲眼看上下文切换

> **状态声明**：本章属「先成文、后实跑」——实验设计、寄存器推导、预期输出均已写定，但**尚未在真机上执行**；
> 文中所有「预期输出」均为待实测核销的推导值，实跑后回填真实数据，绝不编造运行日志与寄存器读数。文中
> 引用的 `nm` 符号表与 `objdump` 反汇编是**本机当前构建产物**（命令可复现）——静态事实；待实测的是运行期
> 行为（断点命中、`reg`/`mdw` 读数）。实验载体是序章救回的 `~/stm32/f429-freertos`，方法论承接
> [[2026-08-30-stm32f429-clock-misconfig-postmortem|故障复盘]]第 5 节，素材衔接
> [[ch16-stack-high-water-mark|ch16：栈高水位]]。

## 本章装备清单

| 分类       | 装备                    | 价格/状态 | 用途                           |
| ---------- | ----------------------- | --------- | ------------------------------ |
| 已有       | 挑战者 F429-V2 板       | ✅        | 实验主体                       |
| 已有       | 野火 DAP 仿真器         | ✅        | 烧录/调试                      |
| 已有       | Mini-USB 线             | ✅        | 供电 + 串口                    |
| 已有       | 笔记本（Fedora 工具链） | ✅        | 构建与观测                     |
| 沿用基础盘 | 无新增                  | —         | DAP 单步调试实验（DAP 即主角） |

## 本章会遇到的词

| 词                     | 一句话版                                   | 详见   |
| ---------------------- | ------------------------------------------ | ------ |
| PendSV                 | 专门留给 RTOS 切任务的最低优先级可挂起中断 | 原理一 |
| 挂起位 / ICSR          | 写一个寄存器位登记「有待办切换」           | 原理一 |
| 末尾链（tail-chain）   | 中断退场时硬件直接接棒进下一个异常         | 原理一 |
| MSP / PSP              | 中断用主栈 / 任务用进程栈，双栈指针        | 原理二 |
| EXC_RETURN             | 装在 LR 里的异常返回魔数                   | 原理二 |
| naked 函数             | 无编译器开场白/收尾、只有手写汇编的函数    | 原理三 |
| R4–R11（callee-saved） | 调用约定里「谁用谁负责复原」的寄存器       | 原理三 |
| BASEPRI                | 「挡住低优先级中断」的屏蔽闸门             | 原理三 |
| nm / objdump           | 查符号地址 / 把机器码翻回汇编              | 原理三 |
| 字面池（literal pool） | 代码尾部的常量表，用 PC 相对寻址来读       | 原理三 |
| 硬件断点（bp … hw）    | FPB 单元的地址哨兵，撞上即停机             | 实验节 |
| step / si              | 单步：执行一条指令就停                     | 实验节 |

## 目标（先说结论）

- 上下文切换在 CM4F 上是一段**全部软件可见**的指令序列（本机实拍共 21 条，见下文反汇编）。本章用
  野火 DAP（Debug Access Port，调试访问口——廉价 USB 调试器里负责说 SWD 协议的那颗芯片）+
  openocd（开源调试守护进程：一头经 SWD 连芯片，一头向 gdb/telnet 开调试服务）断点在 `xPortPendSVHandler` 入口逐条单步，把 `R4–R11` 一个字一个字落进任务栈的
  过程亲眼看一遍——唯一的硬件部分是异常进入/返回，其余每条指令都可停可看。
- PendSV 的存在理由一句话：**切换动作必须不可分割**。CM3+ 的答案是「只挂起、不立即做」：任何想切换的
  地方只写一个 ICSR 位挂起 PendSV，真正的保存/恢复放在**优先级最低**的 PendSV handler 里——它必然等
  所有其它 ISR 退完才 tail-chain 进场，序列天然原子。
- 双栈分工：MSP 归中断/handler 模式，PSP 归任务。异常进入硬件自动压 8 字到 PSP（任务栈），PendSV 再
  软件补 R4–R11 与 EXC_RETURN——**任务的完整上下文 = 8 字硬件帧 + 9 字软件帧 = 17 字**。
- 对照位：[[ch17-xtensa-port-internals|FreeRTOS（十七）]]在 ESP32 上用
  QEMU（开源全系统模拟器，不用真机也能跑固件）+GDB（GNU Debugger，老牌调试器）单步了
  `_frxt_dispatch`；本章是它的 CM4F（带 FPU 的 Cortex-M4）镜像——而且**更纯**：Xtensa（乐鑫 ESP32 的 CPU 架构）的窗口溢出是硬件
  陷阱、协处理器切换靠异常驱动；CM4 的每条压栈指令都能单步（文末对照表）。

## 原理一：PendSV 为什么存在——「挂起待办」的原子性设计

先想一个没有 PendSV 的世界：SysTick ISR 里直接做切换。保存 R4–R11 到一半，更高优先级的中断嵌套进来
——它踩在「半个上下文」上执行，任务状态机直接碎掉。系统侧类比：**在软中断回调里做进程切换、硬中断
随时插队**——Linux 用 `preempt_disable`+调度点把切换收敛进原子窗口，CM3+ 直接给了硬件答案。

> 📖 **术语卡：PendSV（Pendable Service Call，可挂起系统调用）**
> **是什么**：Cortex-M 里一个「只登记、不马上做」的可挂起异常；FreeRTOS 专门把上下文切换代码放进去，并把它配成最低优先级。
> **为什么存在**：切换序列一旦被更高优先级中断打断，中断就会踩着「半个现场」执行——挂起＋最低优先级保证它必然最后进场，序列天然原子。
> **类比**：办公室墙上的待办便签：谁想切换都只贴一张（挂起位是黏的，多张并成一张），等所有访客（其他中断）都走了，秘书才统一办这张便签。
> ⚠️ 类比边界：便签可以被怠工，PendSV 的进场时机由硬件优先级硬性保证——所有 ISR 一退完立刻 tail-chain 进场，一次也不拖。

答案分两半。**第一半：触发只挂起**。所有切换请求收敛成一次对 ICSR（Interrupt Control and State
Register，0xE000ED04，中断控制状态寄存器）的写：

```c
/* portable/GCC/ARM_CM4F/portmacro.h:88-100 —— portYIELD() 的全部
 * portNVIC_INT_CTRL_REG = ICSR(0xe000ed04)；portNVIC_PENDSVSET_BIT = 1UL<<28 */
#define portYIELD()                                     \
    {                                                   \
        portNVIC_INT_CTRL_REG = portNVIC_PENDSVSET_BIT; \
        __asm volatile ( "dsb" ::: "memory" );          \
        __asm volatile ( "isb" );                       \
    }
```

tick 路径同款：`xPortSysTickHandler` 里 `xTaskIncrementTick()` 判定要切换时，也只是写这一位
（port.c:570-577，`portNVIC_INT_CTRL_REG = portNVIC_PENDSVSET_BIT`）。

**第二半：执行放最低优先级**。调度器启动时把 PendSV 与 SysTick 都设为最低优先级：

```c
/* port.c:65-67 优先级常量：255 = 全 1 = NVIC 里数值最大 = 优先级最低 */
#define portMIN_INTERRUPT_PRIORITY   ( 255UL )
#define portNVIC_PENDSV_PRI          ( ( ( uint32_t ) portMIN_INTERRUPT_PRIORITY ) << 16UL )
#define portNVIC_SYSTICK_PRI         ( ( ( uint32_t ) portMIN_INTERRUPT_PRIORITY ) << 24UL )
/* port.c:431-435（xPortStartScheduler）——写 SHPR3 的 PendSV/SysTick 字段、SHPR2 的 SVC 清 0（最高） */
portNVIC_SHPR3_REG |= portNVIC_PENDSV_PRI;
portNVIC_SHPR3_REG |= portNVIC_SYSTICK_PRI;
portNVIC_SHPR2_REG = 0;
```

F429 只实现 4 个优先级位（`configPRIO_BITS=4`，FreeRTOSConfig.h:37；上面代码写的 SHPR3＝System Handler
Priority Register，给 PendSV/SysTick 这类系统异常设优先级的寄存器），写 0xFF 读回 0xF0=15——PendSV=
SysTick=最低档、SVC=0 最高。于是 PendSV 永远不可能抢占任何 ISR，只能等它们全部退场后由 NVIC
（Nested Vectored Interrupt Controller，嵌套向量中断控制器：Cortex-M 内核里管中断优先级与派发的硬件）
**末尾链（tail-chain：上一中断刚退场，硬件跳过无谓的出栈入栈、直接接进下一个待处理异常）**接棒进场——「保存现场」序列从体系结构上排除了被嵌套打断的可能。挂起位还是
**黏的**：多个请求写同一位、合并成一次执行（`pend`=挂起，`SV`=supervisor 服务入口的传统命名）。

## 原理二：双栈——MSP 归中断，PSP 归任务

CM4F 有两个栈指针，当前用哪个由 `CONTROL`（0xE000ED14，模式控制寄存器）的 SPSEL（bit1，栈选择位：
0 用 MSP、1 用 PSP）决定；异常进入时硬件**无条件**
切到 MSP（handler 模式＝正在跑中断服务程序的状态，区别于跑普通代码的 thread 模式），异常返回时按 EXC_RETURN 的 bit0 决定回 MSP 还是 PSP：

| 时刻                   | 用哪个 SP | 谁决定                       |
| ---------------------- | --------- | ---------------------------- |
| 任务代码运行（thread） | PSP       | 异常返回时 EXC_RETURN.bit0=1 |
| 任何 ISR/handler 模式  | MSP       | 硬件自动                     |
| PendSV 保存任务寄存器  | 读写 PSP  | 汇编显式 `mrs/msr psp`       |
| PendSV 自己的 `push`   | MSP       | handler 模式，硬件规则       |

> 📖 **术语卡：MSP 与 PSP（双栈指针）**
> **是什么**：Cortex-M 物理上有两个栈指针——MSP（Main SP，主栈）与 PSP（Process SP，进程栈）；SP（R13）只是「当前生效者」的别名。
> **为什么存在**：中断栈与任务栈分家，中断嵌套再深也踩不到任务现场；每个任务各有各的 PSP 世界。
> **类比**：酒店客房（PSP，一人一间）vs 工程部公共工具间（MSP）——维修（中断）谁都能来，用公共工具间，不动客人房间。
> ⚠️ 类比边界：切到 MSP 是异常进入时硬件自动完成的，不需要软件指令；实验里 `reg sp` 看到的就是当前生效的那个。

EXC_RETURN 是异常进入时硬件写进 LR 的魔数（不是普通返回地址）。本工程两种会在实验里出现：
`0xFFFFFFFD` = 返回 thread 模式 + PSP + **基本帧**（bit4=1，无 FPU 区）；`0xFFFFFFED` = 同上但
**扩展帧**（bit4=0，栈上预留 FPU（浮点运算单元：算 float 的硬件）区——ch18 的主角）。任务出生的那一枚由端口亲手放好
（port.c:93 `portINITIAL_EXC_RETURN`；port.c:223-226 注释 "requires each task to maintain its own
exec return value"——每个任务自带自己的 EXC_RETURN）。

> 📖 **术语卡：EXC_RETURN（异常返回魔数）**
> **是什么**：异常进入时硬件写进 LR 的特殊值（不是普通返回地址）；`bx lr` 时 CPU 一看是它就走「异常返回」流程——弹硬件帧、按 bit0 决定回 MSP 还是 PSP。
> **为什么存在**：异常返回比普通函数返回多一堆事（恢复现场、切模式/切栈指针），硬件需要一个暗号区分两种返回。
> **类比**：登机牌上的快速通关码——地闸（CPU）看到码就知道走另一套流程。
> ⚠️ 类比边界：暗号伪造不了——EXC_RETURN 是硬件生成与消费的魔数，软件乱给会直接 HardFault（硬错误异常）；每个任务的第一枚由端口初始化时亲手放好。

第一个任务怎么起来：`prvPortStartFirstTask`（port.c:278-299）清 CONTROL、校准 MSP 后 `svc 0`（Supervisor
Call：主动触发一次异常，借硬件的手切进 handler 模式）；
`vPortSVCHandler`（port.c:260-275）从 `pxCurrentTCB`（「当前在跑谁」的内核指针，ch15 已拆）取初始栈、`ldmia r0!,{r4-r11,r14}`、`msr psp,
r0`、`bx r14`——用一次异常返回把 CPU「伪装」成刚从中断返回的任务。初始栈由 `pxPortInitialiseStack`
（port.c:202-231）倒着摆出：xPSR、PC、LR、R0、EXC_RETURN、8 字 R4–R11——正是 PendSV 将来要存的
那 17 字的镜像。

## 原理三：xPortPendSVHandler 逐行——源码 + 本机实拍

先看端口源码（`~/stm32/FreeRTOS-Kernel`，V11.1.0+，`tskKERNEL_VERSION_NUMBER` 见 include/task.h:57）。
函数声明 naked（port.c:138）——没有 prologue/epilogue，C 壳里只有一段纯汇编：

```c
/* port.c:504-557 摘行（注释为原文） */
"   mrs r0, psp             \n"                    /* 510：任务栈指针进 r0 */
"   ldr r3, =pxCurrentTCB   \n"                    /* 513：TCB 指针的地址 */
"   ldr r2, [r3]            \n"                    /* 514：r2 = pxCurrentTCB */
"   tst r14, #0x10          \n"                    /* 516：EXC_RETURN bit4=0？→ 用过 FPU */
"   it eq                   \n"                    /* 517 */
"   vstmdbeq r0!, {s16-s31} \n"                    /* 518：是 → 先补 16 字 FPU 高半区（ch18） */
"   stmdb r0!, {r4-r11, r14}\n"                    /* 520：压 R4–R11 + EXC_RETURN，共 9 字 */
"   str r0, [r2]            \n"                    /* 521：新栈顶写回 TCB 第一个成员 pxTopOfStack */
"   stmdb sp!, {r0, r3}     \n"                    /* 523：这两个字压在 MSP（handler 栈）！ */
"   mov r0, %0              \n"                    /* 524：%0 = configMAX_SYSCALL_INTERRUPT_PRIORITY */
"   msr basepri, r0         \n"                    /* 525：BASEPRI=0x50，关 5..15 级中断 */
"   dsb / isb               \n"                    /* 526-527 */
"   bl vTaskSwitchContext   \n"                    /* 528：C 世界选下一个任务 */
"   mov r0, #0 / msr basepri, r0   \n"             /* 529-530：解锁 */
"   ldmia sp!, {r0, r3}     \n"                    /* 531：从 MSP 取回 */
"   ldr r1, [r3]            \n"                    /* 533：重读 pxCurrentTCB——已换人 */
"   ldr r0, [r1]            \n"                    /* 534：r0 = 新任务的 pxTopOfStack */
"   ldmia r0!, {r4-r11, r14}\n"                    /* 536：弹 9 字（镜像 520） */
"   tst r14, #0x10 / it eq  \n"                    /* 538-539 */
"   vldmiaeq r0!, {s16-s31} \n"                    /* 540：镜像 518 */
"   msr psp, r0 / isb       \n"                    /* 542-543：PSP 装载新任务栈顶 */
"   bx r14                  \n"                    /* 552：异常返回——硬件弹 8 字，跳新任务 PC */
```

> 📖 **术语卡：naked 函数**
> **是什么**：编译器完全不加「包装」的函数——没有 prologue（开场白：压栈、布置栈帧）/epilogue（收尾：弹栈返回），函数体里只有你亲手写的汇编。
> **为什么存在**：上下文切换要精确控制每一条指令（哪条压栈、压到哪个栈），编译器自作主张插的任何一条 prologue 都会破坏这份账目。
> **类比**：进无菌手术室必须裸手——多带一样东西（编译器生成的指令）都可能污染现场。
> ⚠️ 类比边界：naked 函数里写普通 C 语句是未定义行为——里面只放汇编。

**指令速查：** 读走读表之前，先认五组汇编助记符（v 前缀＝FPU 指令，eq 后缀＝条件执行）

| 助记符           | 全称与作用                                                                 |
| ---------------- | -------------------------------------------------------------------------- |
| `mrs rd, psp`    | 把特殊寄存器（PSP）的值读进通用寄存器                                      |
| `msr psp, rd`    | 反向：通用寄存器的值写进特殊寄存器                                         |
| `stmdb r0!, {…}` | STore Multiple Decrement Before：地址先减 4 再存——「压栈」                 |
| `ldmia r0!, {…}` | LoaD Multiple Increment After：先取后加——「出栈」，stmdb 的镜像            |
| `tst` / `it eq`  | tst＝按位与、只设标志不存结果；it eq＝若相等（Z=1）则执行下一条 Thumb 指令 |

> 📖 **术语卡：R4–R11 与 callee-saved（被调者保存）**
> **是什么**：ARM 调用约定（AAPCS）把寄存器分两组：R0–R3、R12 是 caller-saved（调用者保存——调别人前自己存好，被调方随便踩）；R4–R11 是 callee-saved（被调者保存——谁用谁负责复原）。
> **为什么存在**：异常打断任务等价于「硬件突然调了一个函数」——硬件自动压 caller-saved 那组（R0-R3/R12/LR/PC/xPSR 共 8 字），callee-saved 的 R4–R11 留给 PendSV 软件补压，分工正好拼出完整现场。
> **类比**：办公室换班——贵重私人物品（R4-R11）各自锁柜，公共文具（R0-R3）桌面统一收走。
> ⚠️ 类比边界：「硬件自动压 8 字」只对异常进入成立；普通函数调用一个字都不自动压，全靠编译器按约定插指令。

再看本机真实产物（**当前构建实拍**，复现命令见实验步骤 0）——注意三行映射
（FreeRTOSConfig.h:64-66）让符号表里的名字是 `PendSV_Handler`：

```text
$ arm-none-eabi-nm build/f429-freertos.elf | grep -E "PendSV_Handler|vTaskSwitchContext|pxCurrentTCB"
080016ac T PendSV_Handler        ← 就是 xPortPendSVHandler（#define 改名，序章第三层 Bug 的修复物）
08000a8c T vTaskSwitchContext
20000008 B pxCurrentTCB

$ arm-none-eabi-objdump -d build/f429-freertos.elf --start-address=0x080016ac --stop-address=0x0800170c
080016ac <PendSV_Handler>:
 80016ac:  mrs   r0, PSP
 80016b0:  isb   sy
 80016b4:  ldr   r3, [pc, #76]        ← 字面池在 8001704：0x20000008（&pxCurrentTCB）
 80016b6:  ldr   r2, [r3, #0]         ← r2 = pxCurrentTCB（旧任务 TCB）
 80016b8:  tst.w lr, #16              ← EXC_RETURN.bit4？
 80016bc:  it    eq
 80016be:  vstmdbeq r0!, {s16-s31}    ← 本工程 fast/slow 不碰 FPU：这行会跳过（ch18 让它执行）
 80016c2:  stmdb r0!, {r4-r11, lr}    ← 9 字落栈：PSP −= 0x24
 80016c6:  str   r0, [r2, #0]         ← TCB->pxTopOfStack = 新栈顶
 80016c8:  push  {r0, r3}             ← 注意：压在 MSP！
 80016ca:  mov.w r0, #80              ← 0x50 = configMAX_SYSCALL_INTERRUPT_PRIORITY（5<<4）
 80016ce:  msr   BASEPRI, r0
 80016d2:  dsb   sy
 80016d6:  isb   sy
 80016da:  bl    8000a8c <vTaskSwitchContext>
 80016de:  mov.w r0, #0
 80016e2:  msr   BASEPRI, r0
 80016e6:  pop   {r0, r3}
 80016e8:  ldr   r1, [r3, #0]         ← pxCurrentTCB 已换手
 80016ea:  ldr   r0, [r1, #0]
 80016ec:  ldmia.w r0!, {r4-r11, lr}
 80016f0:  tst.w lr, #16
 80016f4:  it    eq
 80016f6:  vldmiaeq r0!, {s16-s31}
 80016fa:  msr   PSP, r0
 80016fe:  isb   sy
 8001702:  bx    lr                   ← 异常返回，新任务复活
```

**命令拆解：** `arm-none-eabi-objdump -d build/f429-freertos.elf --start-address=0x080016ac --stop-address=0x0800170c`

| 部分                                 | 作用                                                        |
| ------------------------------------ | ----------------------------------------------------------- |
| `-d`                                 | disassemble：把机器码按字节翻回汇编指令                     |
| `--start-address` / `--stop-address` | 只反汇编这个闭区间——PendSV_Handler 的 21 条，不倾倒整个固件 |
| 行首地址（如 `80016ac:`）            | 该指令在 Flash 里的地址，后面下断点用的就是它               |

**你会看到**：上文那段反汇编（本机当前构建实拍）。
**失败了先查**：地址与 `nm` 输出对不上（拿了旧构建的 elf）、start/stop 写反。

（地址随加代码会挪，动手前以自己的 `nm` 输出为准。）两个源码细节值得点名：`stmdb sp!, {r0,r3}` 的
`sp` 此刻是 **MSP**——handler 自己的暂存压 MSP、不污染任务栈；`str r0,[r2]` 敢直接写偏移 0，是因为
TCB 第一个成员就是 `pxTopOfStack`（tasks.c 结构体处注释原文 "THIS MUST BE THE FIRST MEMBER OF THE
TCB STRUCT"）。

两个小词补注：反汇编里 `ldr r3, [pc, #76]` 读的「字面池」（literal pool）＝编译器把塞不进指令的常量
（这里是 0x20000008）集中放在代码尾部的小表格，用「当前 PC＋偏移」来取；`BASEPRI`＝Cortex-M 的中断
屏蔽闸门——写入 0x50 表示「优先级数值 ≥0x50（即逻辑上更低优先级）的中断一律别进来」，FreeRTOS 临界区
用它代替关全部中断，把 1–4 级留给硬实时中断。

## 实验：五步单步，序章方法论的满配用法

实验不改任何代码——fast/slow 每 200ms/1000ms 各切换一次，PendSV 自然会来。

**步骤 0（拿地址，每次构建后必做）**：`make flash` 后跑
`arm-none-eabi-nm build/f429-freertos.elf | grep -E "PendSV_Handler|pxCurrentTCB"`（输出即上文反汇编
块头部那三条——地址以这一步为准）。

**命令拆解：** `arm-none-eabi-nm build/f429-freertos.elf | grep -E "PendSV_Handler|pxCurrentTCB"`

| 部分                                     | 作用                                                                          |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| `nm`                                     | 列 ELF（链接产物）符号表：每个函数/变量一行「地址 段类型 名字」               |
| `grep -E "PendSV_Handler\|pxCurrentTCB"` | 只留这两个符号（`-E`＝正则模式，`\|`＝「或」）                                |
| 行首字母 `T` / `B`                       | `T`＝.text 代码段（函数）；`B`＝.bss 未初始化数据段（变量）——先认类型再抄地址 |

**你会看到**：`080016ac T PendSV_Handler`、`20000008 B pxCurrentTCB`（数值以当前构建为准）。
**失败了先查**：忘了先 `make`（elf 还没生成）、grep 拼错符号名。

**步骤 1（断点进场）**：起 openocd（`openocd -f openocd.cfg`，gdbserver :3333 / telnet :4444）：

```bash
> reset run          # 或 reset halt + resume，让任务跑起来
> sleep 1500         # 等 1~2 个 200ms 节拍，PendSV 必然发生过
> bp 0x080016ac 2 hw # PendSV 入口，硬件断点，2 字节（Thumb）
> resume             # 下一次 tick/delay 触发 → 断点命中自动 halt
> reg pc             # 预期：pc 0x080016ac
> reg psp            # 预期：任务栈内 0x2000xxxx（ucHeap 里，见 ch14/16 的账本）
> reg lr             # 预期：0xfffffffd（整数任务，基本帧）——bit4=1
> reg sp             # 预期：0x2002xxxx 附近——handler 模式用的是 MSP（_estack=0x20030000 向下）
```

**命令拆解：** 步骤 1 的 8 条 openocd 指令

| 命令                 | 作用                                                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `reset run`          | 复位芯片并放跑——任务开始轮转                                                                                          |
| `sleep 1500`         | 等 1500 毫秒：fast 每 200ms 切一次，PendSV 必已发生过                                                                 |
| `bp 0x080016ac 2 hw` | 在 PendSV 入口下硬件断点：`2`＝断点长 2 字节（Thumb 指令对齐）；`hw`＝用 FPB 硬件断点单元（F429 有 6 个，不动 Flash） |
| `resume`             | 放行 CPU；下一次 tick/delay 触发 PendSV → pc 撞上断点 → 自动 halt                                                     |
| `reg pc`             | 读程序计数器：现在停在哪个地址                                                                                        |
| `reg psp`            | 读任务栈指针：此刻是**被打断任务**的栈顶、硬件 8 字帧的上沿                                                           |
| `reg lr`             | 读 LR——异常进入后它装的是 EXC_RETURN 魔数，`0xfffffffd`＝整数任务基本帧                                               |
| `reg sp`             | 读当前生效栈指针：handler 模式下显示的是 MSP，应在 RAM 顶端 `_estack`（链接脚本定义的栈顶 0x20030000）下方            |

**你会看到**：pc=0x080016ac、psp=0x2000xxxx、lr=0xfffffffd、sp=0x2002xxxx（全部推导值，待实测）。
**失败了先查**：DAP 被另一个 openocd 会话占用（报 cannot open）、`bp` 地址没先 `nm` 核对抄错了位。

**步骤 2（看硬件先压好的 8 字）**：断点命中时异常进入已完成，PSP 下方躺着硬件自动压的 8 字。
记 `P = reg psp`，布局是 ARMv7-M 固定格式（低地址→高地址）：

```text
P+0x00 R0 | +0x04 R1 | +0x08 R2 | +0x0C R3 | +0x10 R12 | +0x14 LR | +0x18 PC | +0x1C xPSR
两个看点：P+0x18 的 PC 应落在 vTaskDelay 调用链（对照 nm 的 vTaskDelay=0x080004bc 附近）；
          P+0x1C 的 xPSR（程序状态寄存器）bit24=1（Thumb 指令态——CM4 只会跑 Thumb）。
> mdw <P> 8     ← 逐字对上面的表
```

**命令拆解：** `mdw <P> 8`（P＝上一步记下的 `reg psp` 值）

| 部分  | 作用                                           |
| ----- | ---------------------------------------------- |
| `<P>` | 从 PSP 起读——硬件自动压的 8 字就躺在 P..P+0x1F |
| `8`   | 连读 8 个 32 位字，逐字对上面的布局表          |

硬件为什么只压这 8 个：R0–R3/R12/LR/PC/xPSR 属 caller-saved（见上文术语卡），中断随时会踩，硬件替你
存；R4–R11 属 callee-saved，硬件不管——这正是接下来单步要亲眼看软件补压的部分。

**步骤 3（单步压栈序列，本章主菜）**：`step`（openocd 的单步：执行一条指令就停）或 gdb `si`（step
instruction，同义；`make gdb`＝Makefile 预设目标，自动起 gdb 并连 openocd 的 3333 端口）。本工程
fast/slow 不用 FPU，走整数路径。**关键技巧**：`0x80016da` 的 `bl vTaskSwitchContext` 不能 `step`
进去——`-O0` 下它是几百条指令；在 `0x080016de`（bl 的下一条）放第二个硬件断点、`continue` 跳过
函数体（F429 有 6 个硬件断点，序章实拍 `target has 6 breakpoints`）。每步记 `reg psp` 并 `mdw`：

| 单步到     | 指令                      | PSP 变化     | 落栈的新内容（推导）                           |
| ---------- | ------------------------- | ------------ | ---------------------------------------------- |
| 80016b4    | mrs/isb/ldr/tst（无栈动） | P（不变）    | —                                              |
| 80016c2 前 | vstmdbeq 被跳过           | P（不变）    | lr.bit4=1 → EQ 不成立（ch18 改造后这里 −0x40） |
| 80016c6    | stmdb {r4-r11,lr}         | P − 0x24     | P−0x24..P−0x04 = R4,R5,…,R11,EXC_RETURN        |
| 80016c8    | str r0,[r2]               | 不变         | TCB 偏移 0 被改写为 P−0x24（mdw r2 可见）      |
| 80016ca    | push {r0,r3}              | PSP 不变     | **MSP** −= 8（reg sp 可验证——双栈现场）        |
| 80016da    | bl vTaskSwitchContext     | 不变         | BASEPRI 已=0x50（`reg basepri` 可验）          |
| 80016e6    | （越过函数体后）          | 不变         | pxCurrentTCB 已换手（见步骤 4）                |
| 80016ec    | ldmia {r4-r11,lr}         | r0 += 0x24   | R4–R11、LR 换成**新任务**的值（reg r4 对比）   |
| 80016fa    | msr psp,r0                | PSP=新栈帧基 | 此刻 PSP 已是新任务的帧                        |
| 8001702    | bx lr                     | —            | 异常返回：硬件弹 8 字、PC 跳新任务             |

**命令拆解：** 单步三件套与「跳过函数体」

| 命令                         | 作用                                                                                                                      |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| openocd `step`               | 执行一条指令就停（过 `bx lr` 这类异常返回步的行为见翻车点③）                                                              |
| gdb `si`                     | step instruction：单步一条机器指令，遇函数调用会**进去**                                                                  |
| gdb `ni`                     | next instruction：单步但**不进**函数——与下面断点跳过法同类                                                                |
| `bp 0x080016de … ; continue` | 在 `bl` 的下一条下第二个硬件断点，continue 全速跑到断点＝整体跳过 `vTaskSwitchContext`（`-O0` 下几百条，step 进去走不完） |

**你会看到**：每步 `reg psp` 按 80016c6 那行 −0x24、其余步不变（推导，待实测回填）。
**失败了先查**：硬件断点超 6 个上限（本实验只用 2 个）、continue 后迟迟不命中（第二断点地址抄错）。

**步骤 4（看 pxCurrentTCB 换手）**：gdb（GNU Debugger，经 openocd 的 3333 端口连到芯片）最省事——ELF 带
`-g3`（编译选项：生成含类型与宏定义的最全调试信息）调试信息，结构体直接按名访问：

```text
(gdb) b *0x080016da
(gdb) c
(gdb) p pxCurrentTCB->pcTaskName        ← 切换前：刚下场的任务，预期 "fast" 或 "slow" 或 "IDLE"
(gdb) b *0x080016de
(gdb) c
(gdb) p pxCurrentTCB->pcTaskName        ← 切换后：换手完成，任务名变了
(gdb) p/x pxCurrentTCB                  ← TCB 指针本身也变（0x2000xxxx）
```

**命令拆解：** gdb 四条命令看 pxCurrentTCB 换手

| 命令                         | 作用                                                                          |
| ---------------------------- | ----------------------------------------------------------------------------- |
| `b *0x080016da`              | break：`*`＋地址＝按**原始地址**下断点（不加 `*` 会被当成函数名/行号解析）    |
| `c`                          | continue：全速跑到下一个断点                                                  |
| `p pxCurrentTCB->pcTaskName` | print：按名字访问结构体成员——靠 `-g3` 调试信息里的类型定义才认得 `pcTaskName` |
| `p/x pxCurrentTCB`           | 以十六进制打印指针本身：换手前后应指向不同 TCB                                |

**你会看到**：第一次 `p` 打出 `"fast"`/`"slow"`/`"IDLE"` 之一，断点前后任务名变化（推导，待实测）。
**失败了先查**：elf 没带 `-g3`（报 No symbol / No type）、断点下在了旧构建的地址上。

openocd 裸读版：`mdw 0x20000008 1`（0x20000008＝步骤 0 查到的 pxCurrentTCB 地址；读 1 个字＝读出指针的
值）在 `bl` 前后各读一次，值不同即换手。C 侧发生的事
（`vTaskSwitchContext`，tasks.c:5215-5298）：5259 行先做栈溢出检查——**ch16 那个 hook 的调用点**；
5273 行 `taskSELECT_HIGHEST_PRIORITY_TASK()` 选人。本工程 `configUSE_PORT_OPTIMISED_TASK_SELECTION=0`
（FreeRTOSConfig.h:12）走通用 C 路径（tasks.c:197-212），机制全文见
[[ch15-perfect-round-robin|ch15：完美 Round-Robin]]。

**步骤 5（恢复路径）**：从 0x080016ec 继续单步，看 R4–R11 从**新任务**的栈里弹回、PSP 装载；`bx lr`
的异常返回由硬件完成（单步会「一步跨过」），之后 `reg pc` 应落在新任务上次被打断处——对 delay 驱动的
fast/slow，大概率在 `vTaskDelay` 调用点附近（对照 nm 的 0x080004bc）。

## 预期输出（待实测核销）

断点命中瞬间的寄存器组（推导值，地址取自当前构建，实跑回填）：

```text
> reg pc      → 0x080016ac
> reg psp     → 0x2000xxxx        # fast/slow 栈都在 ucHeap（nm: 0x2000010c 起 64KB）内
> reg lr      → 0xfffffffd        # 整数任务的 EXC_RETURN；若抓到的是用过 FPU 的上下文则为 0xffffffed（ch18）
> reg sp      → 0x2002xxxx        # MSP：_estack(0x20030000) 减去启动/中断用栈
```

mdw 逐步快照（步骤 3 的落栈实录形态；数值为推导占位，实跑逐字回填）：

```text
单步至 80016b4:  mdw P 8        → [R0][R1][R2][R3][R12][LR][PC≈0x080004xx][xPSR=0x61000000]
单步至 80016c6:  reg psp → P-0x24
                 mdw P-0x24 9    → [R4][R5][R6][R7][R8][R9][R10][R11][0xFFFFFFFD]   ← 9 字依次落栈
单步至 80016c8:  mdw 0x20000008 1 → 旧 TCB 地址；mdw <旧TCB> 1 → P-0x24（pxTopOfStack 已更新）
bl 前后换手:     p pxCurrentTCB->pcTaskName → "fast" → "slow"（或 → "IDLE"，取决于抓到哪次切换）
恢复后:          reg pc → 0x080004xx 附近（新任务被打断处），reg psp → 新任务帧基+0x20
```

三个「翻车即学习点」预埋：① 若 `reg lr` 抓到 0xffffffed——序章工程本不该有 FPU 债，出现即是线索
（ch18 展开）；② 单步是 DAP 往返、每步毫秒级，而 SysTick 每 1ms 挂起一次——单步期间 PendSV 可能被
重复挂起，`continue` 后再次命中属正常；③ `step` 过 `bx lr` 的行为取决于调试器实现（异常返回不是
普通跳转），具体表现标待实测。

## 与主系列对照：同一实验，两种架构的「可见度」

| 维度         | CM4F（本板）                                   | Xtensa（ESP32，[[2026-08-26-freertos-deep-dive-ch17-xtensa-port-internals\|FreeRTOS（十七）]]）    |
| ------------ | ---------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| 切换执行体   | PendSV handler，21 条指令**全软件可单步**      | `_frxt_dispatch` + 向量代码，核心路径可单步，但依赖硬件陷阱                                        |
| 触发方式     | 写 ICSR.PENDSVSET 挂起（黏位，最低优先级进场） | `port_switch_flag[core]` 置位，最外层 `_frxt_int_exit` 兑现                                        |
| 寄存器保存   | 硬件自动压 8 字 + 软件 9 字（+FPU 条件 16 字） | 硬件零自动，向量手工搬 A2–A15/SAR/ZOL，**窗口溢出保存是硬件隐式陷阱**（s32e 序列想看要等撞机时机） |
| 双栈         | 硬件 MSP/PSP，异常自动切换                     | 软件切：任务栈 ↔ 每核 `port_IntStack`                                                              |
| FPU 上下文   | FPCCR/LSPEN 硬件惰性（ch18）                   | 协处理器异常 + CPSA 属主数组，异常驱动惰性                                                         |
| 单步实验纯度 | **满配**：每条压栈指令可停可看                 | 打折：窗口 spill、CPENABLE 属主转移等关键步藏在硬件异常里，QEMU 单步也要绕                         |

对照表里 Xtensa 侧的小词快速版（看不懂不影响本章，记住结论即可）：**窗口寄存器**＝Xtensa 不用传统
压栈，改用一组循环轮换的物理寄存器＋硬件「窗口」，轮到头了触发**窗口溢出陷阱**由向量代码搬运；**协处理
器属主**（CPENABLE）＝FPU 这类扩展单元记录「现在归哪个任务用」，切换时要改属主。这些动作埋在硬件
异常里，单步看不见——这正是本板 CM4「纯」的反面。

为什么这章是本系列的「高光」：Xtensa 把上下文管理的地基焊进硬件（窗口、协处理器属主），换来**机制
不可见**；CM4 把地基留给软件（一段 naked 汇编），换来**机制全透明**。先在这里把 17 字的账目看清，
再看[[ch7-context-switch-deep-dive|FreeRTOS（七）：上下文切换深挖]]的
调度侧与（十七）的汇编侧——同一件事在另一个宇宙的投影。

## 本章待核对清单

| #   | 项                                                                       | 核对方法                                                                     |
| --- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| 1   | 断点命中时 `reg lr` 是否 0xfffffffd（抓到的均为整数任务）                | 多次 resume-hit 采样 ≥10 次                                                  |
| 2   | P+0x18（硬件帧 PC）是否落在 vTaskDelay 调用链（nm 对照 0x080004bc 附近） | mdw P 8 + objdump vTaskDelay 反汇编对照                                      |
| 3   | stmdb 后 PSP 恰好 −0x24、mdw 新 9 字与 reg r4-r11 一致                   | 逐步快照表回填                                                               |
| 4   | `push {r0,r3}` 期间 `reg sp` 确实走 MSP（0x2002xxxx 段）                 | 步骤 3 中插读 reg sp                                                         |
| 5   | pxCurrentTCB 换手前后 `pcTaskName` 序列（fast/slow/IDLE 的切换拓扑）     | gdb `p pxCurrentTCB->pcTaskName`，bl 前后各一次                              |
| 6   | `bx lr` 单步行为（跨异常返回的表现）与恢复后 PC 落点                     | 实跑记录；若调试器表现怪异，对比 `continue` 全速过                           |
| 7   | BASEPRI 在 bl 前的值（推导 0x50 = configMAX_SYSCALL_INTERRUPT_PRIORITY） | openocd `reg basepri`（BASEPRI 是特殊寄存器，只能 msr/mrs 访问、无内存地址） |

下一章：[[ch18-fpu-lazy-stacking|FPU 欠账：lazy stacking]]——
本章跳过的那条 `vstmdbeq r0!, {s16-s31}`，正是下一章的主角：给任务加一行 float 运算，让这 16 字
真的压下去，再逼硬件演示「预留不搬运」的欠账艺术。
系列总目录见[[f429-lab|F429 裸机实验室索引]]。
