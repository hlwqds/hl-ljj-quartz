---
title: "FreeRTOS 深度解析（十七）：Xtensa 端口深挖"
date: 2026-08-26
description: "逐段走读 IDF FreeRTOS 的 Xtensa 端口汇编：寄存器窗口的保存与 spill、两种任务栈帧、_frxt_dispatch 全流程、FPU 协处理器的惰性切换、中断嵌套退出路径与调度器启动，并用 QEMU+GDB 单步一次真实的上下文切换。"
tags: [freertos, rtos, esp32, esp-idf, xtensa, assembly, qemu, gdb]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 17. **第十七章：Xtensa 端口深挖**

# FreeRTOS 深度解析（十七）：Xtensa 端口深挖

第十六章把 `portmacro.h` 里每个宏背后的硬件事实数了一遍。这一章下到最底层：实读 ESP-IDF v6.0.2 的 Xtensa 端口源码，逐段走读一次完整的上下文切换——从 `portYIELD()` 或一个 tick 中断出发，到汇编保存寄存器、调用 `vTaskSwitchContext()`、再恢复（可能是另一个任务的）寄存器为止。读完它，Xtensa 端口对你不再是黑盒：哪些寄存器被保存、保存在哪个栈帧的哪个偏移、寄存器窗口怎么 spill、FPU 为什么是"惰性"切换、`portEXIT_CRITICAL()` 之后切换发生在哪一刻——每个问题都能落到具体的汇编指令上。

> [!note] 读哪个树
> 本章全部源码引用来自 **默认编译的 `components/freertos/FreeRTOS-Kernel/`**（IDF FreeRTOS 本体：Vanilla v10.5.1 + Espressif 双核改造，详见 [[2026-08-26-freertos-deep-dive-ch4-kernel-source-map|第四章]]）。同目录结构下还有一个由 `CONFIG_FREERTOS_SMP` 开启的实验性上游 Amazon SMP 内核树（`FreeRTOS-Kernel-SMP/`），其 Xtensa 端口与本章走读的几乎逐行同源，差异会在文中单独标注。

---

## 17.1 端口文件地图：谁住在哪里

第十六章说过，端口层 = `port.c` + `portmacro.h` + 汇编。在 ESP-IDF 里这三样东西分布在两个组件、七八个文件里：

| 文件                                                | 所属          | 职责                                                               |
| --------------------------------------------------- | ------------- | ------------------------------------------------------------------ |
| `FreeRTOS-Kernel/portable/xtensa/port.c`            | FreeRTOS 组件 | 调度器启停、栈初始化、临界区辅助、FPU 清理钩子                     |
| `FreeRTOS-Kernel/portable/xtensa/portasm.S`         | FreeRTOS 组件 | `vPortYield`、`_frxt_int_enter/_exit`、`_frxt_dispatch` 等切换核心 |
| `FreeRTOS-Kernel/portable/xtensa/xtensa_init.c`     | FreeRTOS 组件 | 中断相关表初始化                                                   |
| `portable/xtensa/include/freertos/portmacro.h`      | FreeRTOS 组件 | 第十六章的主角：端口契约宏                                         |
| `portable/xtensa/include/freertos/xtensa_rtos.h`    | FreeRTOS 组件 | 把 Cadence 的 RTOS 移植契约宏接到 FreeRTOS 函数                    |
| `portable/xtensa/include/freertos/portbenchmark.h`  | FreeRTOS 组件 | 中断延迟/切换基准钩子（默认全空）                                  |
| `components/xtensa/xtensa_context.S`                | xtensa 组件   | `_xt_context_save/restore`、协处理器保存恢复                       |
| `components/xtensa/xtensa_vectors.S`                | xtensa 组件   | 全部异常/中断向量、窗口溢出/下溢向量、`_xt_user_exit`              |
| `components/xtensa/include/xtensa/xtensa_context.h` | xtensa 组件   | 两种栈帧与协处理器保存区的**权威布局定义**                         |

> [!tip] Vanilla vs ESP-IDF：一个目录拆成两层
> Vanilla FreeRTOS 的 Xtensa 端口把上述所有文件塞在同一个目录（`portable/ThirdParty/XCC/Xtensa/`，含 `xtensa_context.S`、`xtensa_vectors.S` 全套）。ESP-IDF 把它拆成两层：FreeRTOS 粘合层（`portable/xtensa/`）与通用 Xtensa HAL 层（`components/xtensa/`）。后者与无 OS 的裸机环境共享同一套向量与上下文代码——这就是 IDF 能让 FreeRTOS 和二级 bootloader、无 OS 固件复用同一份异常入口的原因。

粘合的关键是 `xtensa_rtos.h` 里的四个钩子宏——Cadence 给所有 Xtensa RTOS 移植定的契约点，FreeRTOS 各自实现成一个 `_frxt_*` 函数：

| 契约宏                | FreeRTOS 实现             | 何时被调                                 |
| --------------------- | ------------------------- | ---------------------------------------- |
| `XT_RTOS_INT_ENTER`   | `_frxt_int_enter`         | 向量保存完最小现场后，进入 ISR 前        |
| `XT_RTOS_INT_EXIT`    | `_frxt_int_exit`          | ISR 结束，交还控制权前                   |
| `XT_RTOS_CP_STATE`    | `_frxt_task_coproc_state` | 协处理器异常处理中取当前任务的 CP 保存区 |
| `XT_RTOS_CP_EXC_HOOK` | `_frxt_coproc_exc_hook`   | 每次协处理器异常先走这个钩子             |

`portbenchmark.h` 则是一组空宏（`portbenchmarkINTERRUPT_DISABLE()` 等）：只有 `configBENCHMARK=1` 且打上官方 trace 补丁时才有实体，默认编译为零开销。

---

## 17.2 前置知识：窗口寄存器与两种 ABI

Xtensa 端口汇编的一切复杂度都源于一个 ARM 没有的机制：**寄存器窗口**。

### 1. 64 个物理寄存器，16 个可见

ESP32 的 LX6 有 64 个物理地址寄存器（`XCHAL_NUM_AREGS = 64`），但任意时刻只有 16 个"可见"，就是汇编里的 `a0`–`a15`。可见的这 16 个只是物理寄存器的一个**窗口**（window），窗口起点由特殊寄存器 `WINDOWBASE` 决定。

函数调用指令 `call4` / `call8` / `call12` 把窗口向下旋转 4/8/12 格，被调函数因此拿到一组"全新"的寄存器（`a4`–`a15` 区段），返回指令 `retw` 把窗口旋回去。也就是说，**windowed ABI 下的"传参压栈"大部分被硬件旋转替代了**：

```text
  call4 func 之后的视角（调用者叫 caller，被调者叫 callee）：

  物理AR:   ... [a12][a13][a14][a15][a0'][a1'][a2'][a3'] ...
                                    └──── callee 看到的 a0-a3 ────┘
  caller 窗口: a0-a15               （callee 的 a4-a15 与 caller 的 a0-a11 重叠）
```

callee 的 `a4`–`a15` 与 caller 的 `a0`–`a11` 物理上相同——caller 的数据没被破坏，callee 直接在自己的窗口里就能看到。**caller-saved / callee-saved 的划分由此硬件化**：caller 的 `a0`–`a3` 恰好落到 callee 窗口外面，所以这 4 个寄存器跨调用不保；其余的重叠寄存器天然被 callee"让开"。

### 2. 溢出与下溢：窗口机制的地板

窗口只有 64 格，函数调用链一深就会转圈撞到自己。这时硬件触发异常，由 `xtensa_vectors.S` 里六个向量处理——它们被链接到 `.WindowVectors.text` 段的固定偏移（`0x00`/`0x40`/`0x80`/`0xC0`/`0x100`/`0x140`）：

| 向量                                       | 偏移          | 触发时机              | 动作                                          |
| ------------------------------------------ | ------------- | --------------------- | --------------------------------------------- |
| `_WindowOverflow4`                         | 0x00          | call4 撞到未回收窗口  | 把要被覆盖的 4 个寄存器 `s32e` 到栈上，`rfwo` |
| `_WindowUnderflow4`                        | 0x40          | retw 回到已溢出的窗口 | `l32e` 从栈上取回 4 个寄存器，`rfwu`          |
| `_WindowOverflow8` / `_WindowUnderflow8`   | 0x80 / 0xC0   | call8 版本            | 同上，8 个寄存器                              |
| `_WindowOverflow12` / `_WindowUnderflow12` | 0x100 / 0x140 | call12 版本           | 同上，12 个寄存器                             |

`_WindowOverflow4` 全文只有 6 条指令（`s32e` 是"按窗口旋转前的地址"寻址的存数指令，专门服务于 spill）：

```text
_WindowOverflow4:
    s32e    a0, a5, -16     /* 保存 a0 到下一层调用的栈帧底 */
    s32e    a1, a5, -12
    s32e    a2, a5,  -8
    s32e    a3, a5,  -4
    rfwo                    /* 旋转回去，重执行被中断的指令 */
```

关键洞察：**溢出保存的位置在被溢出窗口自己的栈帧底部**（call4 的栈帧预留 16 字节 base save area 干这个）。所以"窗口 spill"本质上是把寄存器内容写进**当前任务栈**——这决定了任务切换时必须先把所有活跃窗口 spill 干净（见 17.4）。

### 3. call0 ABI vs windowed ABI

Xtensa 还有另一种 ABI：call0。它没有窗口旋转，`call0` 就是普通跳转，栈帧和 ARM 类似由软件维护：

| 维度               | windowed ABI（IDF 默认）               | call0 ABI                |
| ------------------ | -------------------------------------- | ------------------------ |
| 调用指令           | `call4/8/12` + `entry`（旋转窗口）     | `call0`（纯跳转）        |
| callee-saved       | 由窗口重叠硬件保证                     | `a12`–`a15`（软件约定）  |
| 栈帧底部           | 必须预留 base save area（16/32/48B）   | 无此要求                 |
| 中断帧里的差异     | 多 `tmp0-2`（spill 辅助区）            | 多保存 `a14/a15`，帧更小 |
| 与任务栈布局的关系 | **任务栈深度受调用链与溢出点双重影响** | 只受调用链影响           |

ESP-IDF 默认 windowed ABI，本章走读以此为主线；`portasm.S` 里所有 `#ifdef __XTENSA_CALL0_ABI__` 分支是给同一份源码兼容两种编译模式用的。对 FreeRTOS 的直接影响：**任务栈的最小需求里，windowed ABI 每层调用都要在栈上留 base save area 的余量**——这就是任务栈经常"莫名"多出几十字节的原因之一。

> [!note] portBYTE_ALIGNMENT = 16 的出处
> 第十六章留过一个问题：为什么 Xtensa 端口要求 16 字节栈对齐？答案在 `xtensa_context.h` 开头注释引用的 ISA 手册："Xtensa 架构要求栈指针 16 字节对齐"——windowed ABI 的 base save area 与窗口 spill 的写入模式都以 16 字节为前提。`port.c` 里的 `_Static_assert(portBYTE_ALIGNMENT == 16, ...)` 是端口对内核的硬性声明。

---

## 17.3 两种栈帧：XtExcFrame 与 XtSolFrame

端口定义了两种任务栈帧，布局的权威定义在 `xtensa_context.h`（用一套 `STRUCT_FIELD` 宏同时展开成 C 结构体和汇编偏移常量，保证两边永不失配）。

### 1. 中断/异常帧 XtExcFrame（被抢占时用）

| 偏移      | 字段                                         | 保存者                                                 |
| --------- | -------------------------------------------- | ------------------------------------------------------ |
| 0x00      | `exit`（出口分发器地址，如 `_xt_user_exit`） | 向量代码                                               |
| 0x04      | `pc`（EPC1）                                 | 向量代码                                               |
| 0x08      | `ps`                                         | 向量代码                                               |
| 0x0C      | `a0`（EXCSAVE_1 转存）                       | 向量代码                                               |
| 0x10      | `a1`（被打断时的 SP）                        | 向量代码                                               |
| 0x14–0x48 | `a2`–`a15`                                   | `_xt_context_save`（a12/13 由 `_frxt_int_enter` 先存） |
| 0x4C      | `sar`（移位辅助寄存器）                      | `_xt_context_save`                                     |
| 0x50      | `exccause`                                   | 向量代码                                               |
| 0x54      | `excvaddr`                                   | 向量代码                                               |
| 0x58–0x60 | `lbeg` / `lend` / `lcount`（零开销循环）     | `_xt_context_save`（`XCHAL_HAVE_LOOPS=1`）             |
| 0x64–0x6C | `tmp0`–`tmp2`（窗口 spill 辅助暂存）         | `_xt_context_save`（仅 windowed）                      |
| 0x70–     | `XT_STK_EXTRA`：TIE/NCP 扩展保存区           | `xthal_save_extra_nw`                                  |

按 ESP32 LX6 的配置算总账：结构体主体 112 字节，加上 48 字节 NCP 扩展区（`threadptr`、MAC16 的 `acclo/acchi`、原子操作选项的 `scompare1/m0/m1` 等），再向上对齐 16 并加 0x20（中断者的 base save area + gcc 嵌套函数备用区），**`XT_STK_FRMSZ = 192` 字节**。每任务栈必须容得下至少一帧。

### 2. 主动让出帧 XtSolFrame（`portYIELD()` 时用）

| 偏移      | 字段           | 说明                                        |
| --------- | -------------- | ------------------------------------------- |
| 0x00      | `exit` = **0** | 与中断帧同偏移！0 = solicited 帧标志        |
| 0x04      | `pc`           | `vPortYield` 的返回地址                     |
| 0x08      | `ps`           | 调用者的 PS                                 |
| 0x0C      | `threadptr`    | TLS 基址（windowed 下当 callee-saved 处理） |
| 0x10–0x1C | `a0`–`a3`      | caller 的 base save area（windowed）        |

windowed ABI 下共 8 个字，**`XT_SOL_FRMSZ = 32` 字节**——只有中断帧的 1/6。为什么能这么小？因为主动让出发生在函数调用边界上：caller-saved 寄存器按 ABI 约定本就不跨调用存活，`a4`–`a15` 属于"窗口会管"的部分，只需先把活跃窗口 spill 掉（17.4.1 会看到在哪做）。

`exit` 字段与中断帧同在偏移 0 是整个设计的点睛之笔：`_frxt_dispatch` 恢复现场时只读一个字 `[sp]`，就能判断手里是哪种帧、该走哪条恢复路径。

### 3. 保存/恢复职责总表

把一次完整切换要动的处理器状态收拢成一张表（**这就是 Xtensa 端口的"上下文"全集**）：

| 状态                                    | 保存在哪                          | 谁保存                                                  | 谁恢复                                              |
| --------------------------------------- | --------------------------------- | ------------------------------------------------------- | --------------------------------------------------- |
| PC、PS、A0、A1                          | 中断帧 `pc/ps/a0/a1` 槽位         | 向量代码（`_xt_lowint1` 等）                            | 出口分发器 `_xt_user_exit`（写回 EPC1/PS 后 `rfe`） |
| A2–A11                                  | 中断帧                            | `_xt_context_save`                                      | `_xt_context_restore`                               |
| A12–A15                                 | 中断帧                            | `_frxt_int_enter`（12/13）、`_xt_context_save`（14/15） | `_xt_context_restore`                               |
| 活跃寄存器窗口（A0–A15 之外的旋转部分） | **各层栈帧的 base save area**     | 溢出向量（`s32e`）/ `SPILL_ALL_WINDOWS`                 | 下溢向量（`l32e`，按需惰性）                        |
| SAR、LBEG/LEND/LCOUNT                   | 中断帧                            | `_xt_context_save`                                      | `_xt_context_restore`                               |
| THREADPTR + NCP 扩展（acclo 等）        | `XT_STK_EXTRA` / solicited 帧专槽 | `xthal_save_extra_nw` / `vPortYield`                    | 对应恢复路径                                        |
| CPENABLE + FPU 寄存器                   | **任务栈顶的 CP 保存区（CPSA）**  | `_xt_coproc_savecs` / 协处理器异常                      | `_frxt_dispatch`（CPENABLE）+ 惰性恢复（17.5）      |

> [!note] 为什么 A0–A3 在窗口 ABI 下"便宜"
> 表里 A2–A15 都进帧，唯独 A0–A3 由"向量代码"经特殊寄存器中转（A0 进 `EXCSAVE_1`）——因为异常发生时窗口还没旋转，直接 `s32i` 会用错基址。这是 Xtensa 异常处理和 ARM 最大的操作差异之一：**ARM 的硬件自动压栈 8 个寄存器，Xtensa 一个都不压，全靠向量前几条指令手工搬**。代价是中断延迟多了十几条指令，收益是帧布局完全软件可控。

---

## 17.4 逐段走读：从触发到恢复的完整链路

### 1. 主动让出：vPortYield()

`portYIELD()` 展开成 `vPortYield()`（`portasm.S`）。windowed ABI 路径逐段读：

```text
vPortYield:
    entry   sp,  XT_SOL_FRMSZ        ; ① 旋转窗口 + 开 32B solicited 帧
    rsr     a2,  PS
    s32i    a0,  sp, XT_SOL_PC       ; ② 存返回地址（entry 后的 a0）
    s32i    a2,  sp, XT_SOL_PS       ;    存 PS
    rur.threadptr a2
    s32i    a2,  sp, XT_SOL_THREADPTR;    存 TLS 基址
    ...
    movi    a6,  ~(PS_WOE_MASK|PS_INTLEVEL_MASK)
    and     a2,  a2, a6              ; ③ 清 WOE，防 spill 期间再溢出
    addi    a2,  a2, XCHAL_EXCM_LEVEL;    INTLEVEL 提到 3（关中断）
    wsr     a2,  PS
    rsync
    call0   xthal_window_spill_nw    ; ④ 把所有活跃窗口 spill 到本任务栈
    l32i    a2,  sp, XT_SOL_PS
    wsr     a2,  PS                  ;    恢复 PS
    ...
    rsil    a2,  XCHAL_EXCM_LEVEL    ; ⑤ 再次关中断（接下来动共享状态）
    call0   _xt_coproc_savecs        ; ⑥ FPU callee-saved 状态存入 CPSA（若启用）
    movi    a2,  pxCurrentTCBs
    getcoreid a3                     ;    rsr.prid + 取 bit13 → 核号
    addx4   a2,  a3, a2
    l32i    a2,  a2, 0               ;    a2 = pxCurrentTCBs[coreid]
    movi    a3,  0
    s32i    a3,  sp, XT_SOL_EXIT     ; ⑦ 帧类型标志 = 0（solicited）
    s32i    sp,  a2, TOPOFSTACK_OFFS ; ⑧ TCB->pxTopOfStack = SP
    ...
    call0   _frxt_dispatch           ; ⑨ 尾调用分发器，不再返回这里
```

第 ④ 步是 windowed ABI 的命门：**spill 必须发生在还站在本任务栈上时**。切换后 SP 指向别的任务，如果还有活跃窗口没 spill，将来窗口下溢会从错误的栈取数据。`_nw`（no-window）版本保证 spill 过程本身不再分配调用帧。

### 2. 被抢占：从中断向量到 \_frxt_int_exit

以默认配置（tick 走外部 SYSTIMER，电平 1 中断）为例。ESP32 的电平 1 中断统一从用户异常向量进入：

```text
_UserExceptionVector:  wsr a0, EXCSAVE_1 ; call0 _xt_user_exc
_xt_user_exc:          读 EXCCAUSE
                       == 4 (EXCCAUSE_LEVEL1INTERRUPT) → j _xt_lowint1
_xt_lowint1:           开 XT_STK_FRMSZ(192B) 帧
                       存 a1/PS/EPC1/a0，帧头 exit=_xt_user_exit
                       call0 XT_RTOS_INT_ENTER (= _frxt_int_enter)
                       /* —— 此起在 ISR 栈上 —— */
                       PS = INTLEVEL(1)|UM|WOE     ; 开放更高优先级中断
                       dispatch_c_isr 1 ...        ; 调 C 的 ISR（如 SysTickIsrHandler）
                       call0 XT_RTOS_INT_EXIT  (= _frxt_int_exit)
```

`_frxt_int_enter`（`portasm.S`）做三件事：存 `a12/a13`（给 `_xt_context_save` 当 scratch）；调 `_xt_context_save` 存 A2–A11、A14/15、SAR、LBEG/LEND/LCOUNT（其间临时清 EXCM、置 WOE 跑一遍 `SPILL_ALL_WINDOWS`，把中断时刻的活跃窗口全部 spill 到任务栈，然后恢复 PS）；**若这是本核第一层中断**（`port_interruptNesting[core]` 从 0 → 1），把任务 SP 存进 `pxCurrentTCBs[core]->pxTopOfStack`，并把 SP 切到本核独立的 ISR 栈 `port_IntStack[core]`（大小 `configISR_STACK_SIZE`，默认 1536 字节/核）。

中断退出走 `_frxt_int_exit`，这是**切换请求的兑现点**：

```text
_frxt_int_exit:
    rsil    a0,  XCHAL_EXCM_LEVEL            ; 关中断
    port_interruptNesting[core] -= 1
    bnez    → .Lnesting                      ; 还嵌套着 → 只恢复现场
    l32i    a1, pxCurrentTCBs[core]->pxTopOfStack
    检查 port_switch_flag[core]
    beqz    → .Lnoswitch                     ; 无切换请求 → 恢复原任务
    清零 port_switch_flag[core]
    call4   vPortYieldFromInt                ; 存 CPENABLE 进 CPSA 并清零
    call0   _frxt_dispatch                   ; 尾调用分发器，不返回
```

`port_switch_flag` 由 `_frxt_setup_switch()` 置位——它就是 `portYIELD_FROM_ISR()` 的全部实现（`portmacro.h`：`vPortYieldFromISR()` 内联调 `_frxt_setup_switch()`）。**所以 ISR 里的"请求切换"只是置个标志，真正的切换发生在最外层中断退出、栈已解回中断入口之时**。原因很 windowed：中断期间 C 调用链的帧都压在 ISR 栈上，必须等它们退完，才能让分发器安全换 SP。

### 3. 公共分发器：\_frxt_dispatch

solicited 与 unsolicited 两条路最后都汇进 `_frxt_dispatch`：

```text
_frxt_dispatch:
    call4   vTaskSwitchContext()     ; ① 内核选出下一个任务（见第六/七章）
    a3 = pxCurrentTCBs[coreid]      ; ② 取新 TCB
    sp = a3->pxTopOfStack           ; ③ 换栈
    port_uxCoreStartupDone[coreid] = 1   ; ④ 标记本核启动完成（17.7）
    l32i    a2, sp, XT_STK_EXIT     ; ⑤ 读帧类型
    beqz    a2, .L_frxt_dispatch_sol

  /* —— 中断帧路径（被抢占的任务）—— */
.L_frxt_dispatch_stk:
    CPSA = get_cpsa_from_tcb(新TCB) ; ⑥ CPENABLE = CPSA->cpenable
    wsr     a3, CPENABLE
    call0   _xt_context_restore     ; ⑦ 恢复 A2-A15/SAR/ZOL/TIE 扩展
    l32i    a0, sp, XT_STK_EXIT     ; ⑧ 跳到出口分发器（_xt_user_exit）
    ret

  /* —— solicited 帧路径（主动让出的任务）—— */
.L_frxt_dispatch_sol:
    恢复 threadptr、PS、（call0 还有 a12-a15）
    l32i    a0, sp, XT_SOL_PC
    wsr     a3, PS                  ; PS 一恢复，中断随时可能来
    retw                            ; ⑨ 伪装成"从 vPortYield() 返回"
```

第 ⑧ 步 `ret` 跳到的 `_xt_user_exit`（`xtensa_vectors.S`）是所有中断帧的统一出口：

```text
_xt_user_exit:
    l32i a0, sp, XT_STK_PS  ; wsr PS
    l32i a0, sp, XT_STK_PC  ; wsr EPC1
    l32i a0, sp, XT_STK_A0
    l32i sp, sp, XT_STK_A1  ; 拆掉中断帧
    rsync                   ; 等特殊寄存器写入生效
    rfe                     ; PS.EXCM 清零，跳回 EPC1 —— 任务复活
```

一图收拢全景（★ = 切换决策点）：

```text
  任务 A 运行中
     │ portYIELD()                        tick 中断（电平1）
     ▼                                        ▼
  vPortYield                              _UserExceptionVector
     │ entry 32B solicited 帧                │
     │ spill 全部活跃窗口 ★                   ▼
     │ _xt_coproc_savecs                  _xt_lowint1 开 192B 中断帧
     │ pxTopOfStack = SP                    │ _frxt_int_enter
     ▼                                      │   _xt_context_save + spill + 切 ISR 栈
  _frxt_dispatch ◄──────────────────────────┤ dispatch C ISR → xTaskIncrementTick
     │ call vTaskSwitchContext()  ★         │   → portYIELD_FROM_ISR 置 switch_flag
     │ pxCurrentTCBs[coreid] = 新TCB        ▼
     │ sp = 新TCB->pxTopOfStack          _frxt_int_exit ★（nesting==0 且 flag 置位）
     │                                      │  vPortYieldFromInt：存 CPENABLE
     │                                      └──── call0 _frxt_dispatch
     ├── 帧[sp]==0 → solicited：恢复最小现场，retw 伪装返回
     └── 帧[sp]!=0 → 中断帧：恢复 CPENABLE → _xt_context_restore
                      → ret 跳 _xt_user_exit → rfe →（新）任务继续
```

> [!tip] Vanilla vs ESP-IDF：汇编里的 SMP 痕迹
> 同一份 `portasm.S`，Vanilla XCC 端口里全局状态全是标量：`pxCurrentTCB`、`port_switch_flag`、`port_xSchedulerRunning` 各一个。IDF fork 全部改成**每核数组**：`pxCurrentTCBs[coreid]`、`port_switch_flag[core]`、`port_interruptNesting[core]`，每处访问前先 `getcoreid`（读 PRID 取 bit 13：PRID 硬编码值 0xCDCD=Core 0 / 0xABAB=Core 1）再 `addx4` 索引。另一个细节：默认树的 `_frxt_dispatch` 调 `vTaskSwitchContext()` **无参**（内核内部自查核号），而实验性 SMP 树改为传 `xCoreID` 参数——同一函数签名，能看出两棵树的分代。

---

## 17.5 协处理器上下文：FPU 的惰性切换

### 1. CPSA：藏在任务栈顶的 96 字节

ESP32 LX6 配置了 1 个协处理器（`XCHAL_CP_NUM = 1`，CP0 = FPU，保存区 72 字节、对齐 4）。每个任务的栈顶（高地址端）固定躺着一块**协处理器保存区 CPSA**，由 `port.c` 的 `pxPortInitialiseStack()` 在建任务时最先分配：

```text
   任务栈顶（pxEndOfStack）
   ┌────────────────────────────┐ ─┐
   │ CP0 保存区（FPU，72B）      │  │ XT_CP_SIZE = 96B
   ├────────────────────────────┤  │ （16B 对齐）
   │ XT_CP_ASA   (4B)           │  │
   │ XT_CP_CS_ST (2B)           │  │
   │ XT_CPSTORED (2B)           │  │
   │ XT_CPENABLE (2B)           │  │
   └────────────────────────────┘ ─┘ ← 16 字节对齐
   │ TLS 变量区                  │
   ├────────────────────────────┤
   │ 初始中断帧（192B）          │ ← pxTopOfStack（任务的起点 SP）
   │            ……              │
   └────────────────────────────┘ 栈底
```

头 12 字节是三张位图加一个指针（定义在 `xtensa_context.h`）：`XT_CPENABLE` 记录本任务拥有哪些 CP、`XT_CPSTORED` 标记完整状态已保存、`XT_CP_CS_ST` 标记 callee-saved 部分已保存、`XT_CP_ASA` 指向对齐后的实际保存区。

汇编侧通过 `get_cpsa_from_tcb` 宏定位它：读 C 常量 `offset_pxEndOfStack`（即 `offsetof(StaticTask_t, pxDummy8)`，对应 `TCB->pxEndOfStack`）拿到栈顶，减 `offset_cpsa`（= `XT_CP_SIZE`），向下 16 对齐。**CPSA 不在 TCB 里、也不在中断帧里，而是锚定在任务栈的最高处**——中断不用 FPU（用了直接 panic，除非开 `CONFIG_FREERTOS_FPU_IN_ISR`），所以它没必要进每帧。

### 2. 惰性切换：异常驱动的所有权转移

FPU 上下文切换不发生在调度器里，而是发生在**下一次有人用 FPU 时**：

```text
任务 B（刚被调度）执行 float 指令
   │ CPENABLE 里 FPU 位是 0（切走时被清了）
   ▼
协处理器异常（EXCCAUSE = 32+，CP0_DISABLED）
   ▼
_xt_coproc_exc（xtensa_vectors.S）
   │ 开中断帧、call _frxt_coproc_exc_hook  ← 钩子里把未钉核任务钉到当前核
   │ call _frxt_task_coproc_state          ← 返回新主人的 CPSA
   │ CPENABLE |= FPU 位
   │ _xt_coproc_owner_sa[CP][core] 换主（spinlock 保护，跨核共享数组）
   │ 旧主人 CPENABLE 位还置着？→ 完整状态 xchal_cp0_store 存入其 CPSA
   │ 新主人 XT_CPSTORED 置位？  → xchal_cp0_load 恢复；只存过 callee-saved
   │                              就只恢复那部分（_xt_coproc_restorecs）
   ▼
_xt_user_exit → 回到触发异常的那条 float 指令重执行
```

收益：两个整数任务来回切换，FPU 状态一动不动，**切换成本里根本没有 FPU**；只有真用了 FPU 的任务才付 72 字节搬运的账。代价：协处理器异常路径要绝对正确，而且**每核一份 FPU 意味着用 FPU 的任务必须钉核**——这就是 `_frxt_coproc_exc_hook` 存在的理由：未钉核任务第一次碰 FPU，钩子直接写 `TCB->xCoreID = 当前核`，从此钉死。

任务删除时 `port.c` 的 `vPortTCBPreDeleteHook()` 会算出 CPSA 位置，调 `_xt_coproc_release()`（`xtensa_context.S`）把所有权数组里指向它的表目清零——必须在释放栈内存之前做，否则协处理器异常会往已释放的内存里存数据。

> [!tip] Vanilla vs ESP-IDF：cp_state 挂在哪
> Vanilla 端口把协处理器保存区指针直接存在 TCB 的一个字段里（汇编用 `CP_TOPOFSTACK_OFFS` 常量从 TCB 偏移 4 取 `cp_state`）。IDF fork 改成**从 `TCB->pxEndOfStack` 反推**（`pxEndOfStack - XT_CP_SIZE` 对齐 16），并用 C 编译出的 `offsetof` 常量喂给汇编——TCB 布局改了也不用重写汇编。SMP 化后每核还有独立的 `_xt_coproc_owner_sa` 属主数组和跨核 spinlock 保护，这是 Vanilla 完全没有的维度。

---

## 17.6 中断嵌套与 portEXIT_CRITICAL 的退出路径

**嵌套记账**：`port_interruptNesting[core]` 在 `_frxt_int_enter` 加一、`_frxt_int_exit` 减一。只有从 0→1 的那层做"任务 SP 存 TCB + 切 ISR 栈"，1→0 的那层才有资格触发切换——嵌套期间 `port_switch_flag` 会被反复置位，最后由最外层统一兑现。电平 2/3 的中优先级中断（`_Level2Vector` → `_xt_medint2` 等）走同一套 `XT_RTOS_INT_ENTER/EXIT` 契约，天然参与嵌套计数。

**临界区退出链**（细节留给[[2026-08-26-freertos-deep-dive-ch18-critical-sections-spinlocks|第十八章]]，这里只看时序）：`portEXIT_CRITICAL()` 最终把 `PS.INTLEVEL` 写回保存值（`XTOS_RESTORE_JUST_INTLEVEL`）。ESP32 LX6 的 `XCHAL_EXCM_LEVEL = 3`，所以 IDF 的"关中断"实际是 INTLEVEL=3——电平 1~3 全被挡住。**INTLEVEL 一落回 0，被压住的 tick 中断立刻进场**；若它判定需要切换，流程就接回 17.4.2 的 `_frxt_int_exit` 路径。换句话说：临界区结束 ≠ 切换，切换发生在"临界区结束后到来的那个中断的退出点"。

```text
portEXIT_CRITICAL()
   │ INTLEVEL 3 → 0（ps 写回）
   ▼ ……
tick 中断（可能就在下一条指令）
   │ _frxt_int_enter：nesting 0→1，切 ISR 栈
   │ xPortSysTickHandler → xTaskIncrementTick → 需要切换
   │ portYIELD_FROM_ISR → port_switch_flag[core] = 1
   ▼
_frxt_int_exit：nesting 1→0，flag 置位
   → vPortYieldFromInt → _frxt_dispatch → 新任务
```

---

## 17.7 xPortStartScheduler：从 main 到第一个任务

`port.c` 的 `xPortStartScheduler()` 在默认树里出奇地短：

```c
BaseType_t xPortStartScheduler( void )
{
    portDISABLE_INTERRUPTS();
#if XCHAL_CP_NUM > 0
    _xt_coproc_init();          /* CP 属主数组清零：全部"无主" */
#endif
    vPortSetupTimer();          /* tick 源（见下） */
    BaseType_t coreID = xPortGetCoreID();
    port_xSchedulerRunning[coreID] = 1;
    port_uxCoreStartupDone[coreID] = 0;
    xthal_window_spill();       /* 把启动期的窗口全部 spill 掉 */
    __asm__ volatile ("call0    _frxt_dispatch\n");  /* 不再返回 */
    return pdTRUE;
}
```

`xthal_window_spill()` 值得停一下：此刻 CPU 还站在**启动栈**（startup stack）上，窗口里残留着 bootloader→app_startup 一路的引用。不 spill 干净，等启动栈被回收再复用后，任务里一次窗口下溢就可能从"已经是堆内存"的旧栈里捞数据。spill 之后启动期的调用史就安全作废了。

**双核怎么都跑起来**（`app_startup.c`）：

```text
Core 0 (PRO)                          Core 1 (APP)
────────────────────────────          ────────────────────────────
esp_startup_start_app()
  建 main_task、初始化中断/交叉核中断
  vTaskStartScheduler()
    xPortStartScheduler():
      tick 起振、flag 置位、spill、
      call0 _frxt_dispatch ──┐        esp_startup_start_app_other_cores()
                             │          自旋等 port_xSchedulerRunning[0]
        首次 dispatch 里              │
        port_uxCoreStartupDone[0]=1   │ xPortStartScheduler()  ← 在 Core 1 上！
                             │          同一套初始化 + dispatch
                             │          port_uxCoreStartupDone[1]=1
                             ▼        ▼
        main_task 运行后等两个核的 startupDone 都置位，
        才敢回收双核启动栈入堆（heap_caps_enable_nonos_stack_heaps）
```

注意 Core 1 不是被 Core 0"叫醒"的——两个核各自跑完 `startup.c` 后独立进入 FreeRTOS，Core 1 只用自旋等待确认 Core 0 的调度器已就绪（避免竞态），然后**在自己身上**调用 `xPortStartScheduler()`。

**tick 源**：默认配置用外部 SYSTIMER 外设（`port_systick.c` 的 `vSystimerSetup()`），每核一个周期性 alarm，Core 0/1 的中断刻意错开半个周期；ISR 是普通 C 函数 `SysTickIsrHandler`，经 `esp_intr_alloc` 挂到电平 1/3。老路径 `CONFIG_FREERTOS_SYSTICK_USES_CCOUNT`（用 CPU 内部 CCOUNT 比较器）仍保留在 `portasm.S` 的 `_frxt_timer_int` 里——里面有个漂亮的"追赶循环"：中断被耽误超过一个 tick 时，按旧比较值累加补发多个 tick，防止计数器回绕。tick 进入内核后的双核分工（Core 0 全责 / Core 1 部分）在[[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|第二十二章]]展开。

---

## 17.8 实验：QEMU+GDB 单步一次真实切换

没硬件也能把 17.4 的每一步踩实。建一个最小工程，两个任务互相让出：

```c
/* main.c —— ch17-ctxswitch */
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static void worker(const char *name)
{
    for (;;) {
        printf("%s\n", name);
        vTaskDelay(1);      /* 阻塞 → 让出，制造每 tick 一次的切换 */
    }
}

void app_main(void)
{
    xTaskCreatePinnedToCore(worker, "w1", 2048, "A", 1, NULL, 0);
    xTaskCreatePinnedToCore(worker, "w2", 2048, "B", 1, NULL, 0);
}
```

两个任务同优先级、同钉 Core 0，`vTaskDelay` 到期唤醒谁就切谁——每次切换都完整经过 `_frxt_dispatch`。启动调试：

```bash
idf.py qemu gdb     # 编译 → QEMU(带 GDB server) → xtensa-esp32-elf-gdb 自动 attach
```

**第一站：在分发器门口看换栈。**

```text
(gdb) b _frxt_dispatch
(gdb) c
Breakpoint 1, _frxt_dispatch () at portasm.S:446
(gdb) p pxCurrentTCBs
$1 = (TCB_t *volatile *) 0x3ffd0000      ; 数组基址，因构建而异
(gdb) p/x pxCurrentTCBs[0]->pcTaskName[0]
$2 = 0x41                                ; 'A'：切换前跑的是 A
(gdb) si            ; …单步越过 call4 vTaskSwitchContext、取新 TCB、换栈…
(gdb) info reg a1
a1     0x3ffb1e20     ; SP 已经是任务 B 的 pxTopOfStack
(gdb) x/wx $a1
0x3ffb1e20: 0x400d1234     ; 帧类型字（XT_STK_EXIT 槽）
```

**第二站：判定帧类型。** `x/wx $sp` 读到的就是 `_frxt_dispatch` 那句 `l32i a2, sp, XT_STK_EXIT` 的依据。B 是被 tick 抢占的，这里应是 `_xt_user_exit` 的地址；继续验证：

```text
(gdb) p &_xt_user_exit
$3 = (void (*)()) 0x400d1234
```

对上号了——这是中断帧，走 `stk` 分支。若是 `vTaskDelay()` 主动让出触发的切换，同一个字会是 0（solicited 帧），恢复路径变成 `retw`。你可以用条件断点分别抓两种帧：

```text
(gdb) b vPortYield          ; 主动让出：观察 entry sp,32 开帧 + spill
(gdb) watch port_switch_flag[0]   ; 谁在请求切换？栈回溯会指向 tick/IPC 中断
```

**第三站：按 17.3 的偏移表解剖栈帧。** 中断帧里 PC/PS/A0–A15/SAR/ZOL 一目了然：

```text
(gdb) x/29wx $sp            ; 0x00 exit, 0x04 pc, 0x08 ps, 0x0c a0, 0x10 a1, …
(gdb) p $ps                 ; 特殊寄存器直接按名取
(gdb) p $sar
(gdb) p $windowbase         ; 窗口起点——单步 spill 前后观察它不动，
                             ; 但 base save area 里多了被 spill 的寄存器
```

**第四站：看惰性 FPU。** 给 worker 加一行 `volatile float f = 1.0f * 2;`，断在 `_xt_coproc_exc`：观察 `CPENABLE` 从 0 变为 1、`_xt_coproc_owner_sa` 换主；再 `p $pc` 确认 `_xt_user_exit` 返回后**重新执行的是触发异常的那条 float 指令**。真机（`idf.py -p /dev/ttyUSB0 flash gdb`）上流程一致，只是地址与串口路径不同；QEMU 里窗口溢出/下溢的时序与真实 LX6 有细微差异，但 spill 的**位置**（各层栈帧 base save area）是架构保证的，观察结论通用。

排坑提示（[[2026-08-26-freertos-deep-dive-ch24-debugging-tracing-pitfalls|第二十四章]]会系统展开）：断点打在 `vPortYield` 内部 spill 前后时，GDB 的单步本身可能改变窗口状态；用 `x/wx` 验证帧类型比肉眼看反汇编可靠。

---

## 17.9 与 ARM Cortex-M 端口对照

读过 STM32 教程的读者，把 Xtensa 端口和最熟悉的 Cortex-M 端口（PendSV + MSP/PSP）并排放，所有差异一目了然：

| 维度               | Xtensa（ESP32 LX6）                                              | ARM Cortex-M（如 CM4/CM7）                            |
| ------------------ | ---------------------------------------------------------------- | ----------------------------------------------------- |
| 主动切换触发       | `portYIELD()` → `vPortYield()` 汇编直切                          | 写 `SCB->ICSR` 的 `PENDSVSET` 位，挂起 PendSV         |
| 被动切换触发       | 中断退出点 `_frxt_int_exit` 兑现 `port_switch_flag`              | ISR 退出时 NVIC 末尾链（tail-chain）进 PendSV         |
| 硬件自动压栈       | **零个**寄存器，向量前几条指令手工存                             | **8 个**（R0-R3、R12、LR、PC、xPSR）自动压入当前栈    |
| 双栈机制           | 软件切：任务栈 ↔ 每核 `port_IntStack`（`_frxt_int_enter` 换 SP） | 硬件双栈：PSP（任务）/ MSP（handler 模式自动切换）    |
| 软件保存清单       | A2–A15 + SAR + LBEG/LEND/LCOUNT + THREADPTR + TIE 扩展           | R4–R11（+ FPU 的 S16–S31）                            |
| 恢复执行流         | `rfe`（清 EXCM、跳 EPC1）或 `retw`（solicited）                  | 异常返回（`BX LR` + `EXC_RETURN` 魔数）               |
| 寄存器窗口         | 有：64 物理寄存器旋转，spill 落在各层栈帧                        | 无：固定 16 个，callee-saved 全靠软件                 |
| FPU 上下文         | 惰性：协处理器异常驱动，按任务 CPSA + 属主数组                   | `CONTROL.FPCA` + lazy stacking：异常时延迟压 S 寄存器 |
| 帧大小（整数任务） | 中断帧 192B / solicited 帧 32B                                   | 硬件帧 32B + 软件帧 32B（R4-R11）= 64B                |

两个端口的哲学差异比表格更深：Cortex-M 把"上下文切换的地基"焊进硬件（自动压栈、双栈、PendSV 最低优先级保切换原子性），端口汇编因此极短；Xtensa 把灵活性留给软件，窗口机制让**普通函数调用**都带上下文管理色彩，端口要处理 spill 时机、帧类型分派、协处理器属主这些 ARM 上不存在的问题——这就是 Xtensa 端口汇编量比 Cortex-M 多一个数量级的原因。理解了这一点，也就理解了为什么第十六章的契约宏里，Xtensa 端口需要 `portDISABLE_INTERRUPTS` 之外还有一整套 `_frxt_*` 接口。

---

## 17.10 小结

- 端口分两层：`FreeRTOS-Kernel/portable/xtensa/`（FreeRTOS 粘合层）与 `components/xtensa/`（通用向量与上下文层）；Cadence 的 `XT_RTOS_*` 契约宏把两者缝在一起。
- Windowed ABI 用窗口旋转替代压栈传参，溢出/下溢向量把寄存器 spill 到**各层栈帧的 base save area**；任务切换前必须 spill 干净所有活跃窗口（`vPortYield` 里的 `xthal_window_spill_nw`、中断路径里的 `SPILL_ALL_WINDOWS`）。
- 两种栈帧：被抢占用 192 字节的 `XtExcFrame`（PC/PS/A0-A15/SAR/ZOL/扩展区），主动让出用 32 字节的 `XtSolFrame`；`exit` 字段同在偏移 0，`_frxt_dispatch` 靠它一个字分流恢复路径。
- 完整链路：触发（`vPortYield` 或中断）→ 保存（向量 + `_frxt_int_enter` + `_xt_context_save` + spill）→ `vTaskSwitchContext()` 选新 TCB → 换 `pxCurrentTCBs[coreid]->pxTopOfStack` → 按帧类型恢复（`retw` 或 `_xt_context_restore` + `_xt_user_exit` + `rfe`）。
- FPU 是惰性切换：CPSA 锚在任务栈顶（96 字节，含三张位图），协处理器异常驱动属主转移，用 FPU 的未钉核任务会被钩子自动钉核；ISR 里用 FPU 默认直接 panic。
- `portYIELD_FROM_ISR()` 只置 `port_switch_flag[core]`，真正切换发生在最外层 `_frxt_int_exit`——嵌套计数归零、ISR 栈解完之后。
- 调度器启动：每核独立跑 `xPortStartScheduler()`（Core 1 自旋等 Core 0），`xthal_window_spill()` 作废启动栈引用，`call0 _frxt_dispatch` 一去不回。

下一章沿着 17.6 留下的线头往下拉：临界区的完整实现——`XTOS_SET_INTLEVEL` 与 spinlock 怎么组合成 `portENTER_CRITICAL()`、双核下"关中断 + 自旋"的代价模型、以及跨核总线锁的原理。那是 Xtensa 端口里最后一块硬骨头。
