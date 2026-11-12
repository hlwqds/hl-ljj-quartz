---
title: "Zig × ESP32-S31 全栈开发（十一）：抢占调度、TCB 与 tick"
date: 2026-11-26 12:00:00
description: "把 ch10 的自愿让出升级为抢占：TIMG0 T0 的 1 ms tick 经中断矩阵第 25 号源进入 CLIC 输入 16，在 ISR 里递减时间片、按 8 级优先级选任务，并复用 80 字节 trap 帧与 64 字节 switch 帧完成『从中断里换栈』；同时给出软件中断 yield、tickless 的三个前提、临界区，以及 tick 漂移/抖动的测量口径。"
tags: [zig, esp32-s31, riscv, rtos, scheduler, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. [[ch04-linker-memory-layout|第四章：链接脚本与内存布局]]
> 5. [[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]
> 6. [[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]]
> 7. [[ch07-interrupts-exceptions-clic|第七章：中断、异常与 CLIC]]
> 8. [[ch08-timers-dma-precision|第八章：定时器、DMA 与精确时序]]
> 9. [[ch09-spi-flash-partition-nvs|第九章：SPI Flash、分区与 NVS 存储]]
> 10. [[ch10-context-switch-cooperative-scheduler|第十章：上下文切换与协作调度]]
> 11. **第十一章：抢占调度、TCB 与 tick**
> 12. 第十二章：同步原语与 IPC（待发布）

# Zig × ESP32-S31 全栈开发（十一）：抢占调度、TCB 与 tick

第十章做出了“能换栈”的调度器，但它要求任务**自愿**调用 `yield()`。一个忘记让出的长循环就能让其余任务停摆。操作系统不能建立在任务自觉上。

这一章补三块：周期性的时间源（tick）、不等任务配合的切换点（中断）、决定次序的规则（优先级 + 时间片）。三块都复用已有结论——tick 走 ch07 的 CLIC 与中断矩阵，定时器走 ch08 的 TIMG0，帧布局与 `switchRaw` 直接沿用 ch10。真正新增的只有 TCB 的调度字段，以及“在 ISR 里调用 `switchTo`”这条边界。

> [!warning] 本章的证据边界
> 形态 B 不变（Zig 产 ELF、自有链接脚本、IDF 只提供二级 bootloader 与分区表）。寄存器地址取自 ESP-IDF v6.1 的 `esp32s31` 头文件，S31 的 TRM 仍是 Pre-release v0.7。**本工程没有在任何真机上运行过**，构建与烧录也未在本仓执行：文中输出全是验收目标，不是实测；不提供 `run.log`。ISR 换栈、tick 周期、漂移/抖动都按待真机验证对待。

---

## 11.1 抢占到底多了什么

| 维度       | 协作式（ch10）   | 抢占式（本章）                    |
| ---------- | ---------------- | --------------------------------- |
| 切换触发   | 任务执行 `ecall` | tick 中断（`ecall` 仍可主动让出） |
| 触发时机   | 任务决定         | 硬件按 1 ms 周期决定              |
| 需要 `MIE` | 不需要，全程 0   | 必须为 1，否则 tick 进不来        |
| 需要优先级 | 不需要           | 需要，否则只是在瞎轮转            |
| 失败现象   | 一个任务独占 CPU | tick 不跳，按创建顺序轮转         |

第三行是关键：ch10 可以保证“切换过程中不会来中断”，本章不能。`MIE = 1` 之后**任何时刻**都可能被 tick 打断，包括正在改就绪队列的那一刻。所以本章要同时回答：中断里怎么合法换栈；哪些代码必须挡住 tick、挡多久。

---

## 11.2 TCB：任务需要被记住的全部东西

ch10 的 TCB 只有 `sp`、`state`、`steps`，够协作式，不够抢占式。本章多三个调度字段：

```zig
pub const Task = struct {
    name: []const u8,   // 只用于打印
    stack: []const u8,  // 栈区间，诊断用
    sp: usize,          // 挂起时指向 switch 帧；运行中无意义
    state: State,       // ready / running / done
    prio: u3,           // 0..7，越大越优先
    slice: u16,         // 剩余时间片，单位 = tick
    slice_init: u16,    // 时间片初值，到期后重装
    next: ?*Task,       // 同优先级就绪链的下一个
    steps: u32,         // 任务自维护的进度
    ticks: u32,         // 被 tick 命中的次数
    idle: bool,
};
```

- **`sp` 仍是唯一的硬件上下文锚点**：换任务 = 换 `sp`。抢占没有改变它，tick ISR 最终也是 `switchTo(&prev.sp, next.sp)`。
- **`prio` 用 `u3`**：CLIC 的 `NLBITS = 3`（8 级），与 ch07 对齐。用 `u8` 会把“优先级 8 存不存在”变成运行期问题。
- **`slice` 单位是 tick，不是毫秒**。1 tick = 1 ms 只是本章配置；字段名写毫秒，换 tick 频率时就会说谎。
- **`next` 是侵入式链表指针**，不额外分配节点；TCB 池是 `.bss` 里的 `[8]Task`。
- **idle 是普通 TCB**，但复用 `_start` 的主栈（`_stack_top`）且永不进就绪队列。

没有 `blocked`。阻塞需要唤醒源，那是第十二章（同步原语/IPC）的题；本章只有 ready/running/done。一个没有唤醒路径的 `blocked` 会让调度器静默死锁，排错时连输出都没有。

---

## 11.3 就绪队列：8 条链，同级轮转

每个优先级一条单向环形链，用 TCB 的 `next` 串起来；`head` 出队、`tail` 入队：

```text
ready_head[8] ──► [T2] → [T5] → [T9] ──┐
                  ▲                     │
                  └─────────────────────┘   （尾节点 next 指回 head）
ready_tail[8] ──► [T9]                       // 入队在尾，出队在头
```

- **入队**：追加到 `tail` 之后；空链时 `head = tail = t`。
- **出队**：取 `head`，`head = head.next`；取空后 `head = tail = null`。
- **同级轮转**不需要游标：时间片到期时当前任务被**追加到自己那条链的尾部**，下次出队自然轮到兄弟。

规则只有一条：**最高优先级的队首**（`pickNext` 从 7 到 0 扫第一条非空链）。同级顺序由“到期追加到队尾”保证。严格性意味着只要高优先级队列非空，低优先级**永远**不被选中——这是优先级抢占的定义，也是饥饿的来源。本章不解决饥饿（没有老化、没有优先级继承），只把它写出来。

idle 不放进 `ready_head[0]`：否则“新建的 prio 0 任务排在 idle 前还是后”没有正确答案。它只作为“队列全空”的返回值：`const next = pickNext() orelse &idle_task;`。

---

## 11.4 tick 从哪来：TIMG0 T0 与中断链路的六道门

| 候选                    | 源编号 | 优点                         | 代价                                   |
| ----------------------- | ------ | ---------------------------- | -------------------------------------- |
| TIMG0 T0 闹钟（本章）   | 25     | 分频自由，1 tick = 1 µs 可读 | 要配时钟源、分频、闹钟、INT_ENA 与重装 |
| SYSTIMER TARGET0 比较器 | 33     | 16 MHz 全局时基，天然单调    | 52 位比较值要维护高低位，周期模式待核  |

选 TIMG0 T0 不是因为它更好，而是每个参数都能读回核对：分频 40 就是 1 MHz，闹钟装 1000 就是 1 ms。$$f_{\text{tick}} = \frac{40\,\text{MHz}}{40} = 1\,\text{MHz},\qquad T_{\text{tick}} = \frac{1000}{1\,\text{MHz}} = 1\,\text{ms}.$$

一条 tick 要穿过六道门：

```text
TIMG0 T0 命中（INT_RAW_TIMERS.bit0）
   ↓ INT_ENA_TIMERS.bit0 = 1（TIMG 侧门闩，复位值 0）
   ↓ 源 25 = ETS_TIMERGRP0_T0_INTR_SOURCE
中断矩阵 INTERRUPT_CORE0[25]：MAP[5:0] = 0 + 16 = 16
   ↓
CLIC 输入 16：CTL 优先级 = 3，IE = 1
   ↓ 优先级 3 > 阈值 0
mstatus.MIE = 1 → trapEntry → trapDispatch（mcause = 0x80000010）
```

三个数字必须一起记：

- **矩阵寄存器地址 = `0x20585000 + 4 × 25`**：每源一个 32 位寄存器，偏移是源编号乘 4。
- **写进去的是 CLIC 输入号 16..47，不是外部通道 0..31**，即 `MAP[5:0] = channel + 16`。写 0 不会报错，而是投递到内部输入（0..15），表现为“中断完全没发生”。
- **`mcause` 最高位为 1 表示中断，低 6 位是输入号**：tick 的 `mcause = 0x8000_0010`，不是规范里的“机器定时器 7”。

**TIMG 自己的门闩容易被漏掉：`INT_ENA_TIMERS(+0x70)` 的 bit0 复位为 0。** 它是 TIMG 内部“原始状态位 → 中断输出线”的开关，ch08 用轮询时不需要它所以没开。只配矩阵与 CLIC、却漏掉这一位，现象是 `INT_RAW` 在寄存器里照常置位、芯片外部（矩阵与 CLIC）却完全看不到——查矩阵和 CLIC 是白费时间。本章的 `tick.init` 在写矩阵之前先清一次 `INT_CLR`、再置 `INT_ENA` 的 bit0，`tick.disable` 关掉 tick 时把这一位一起清掉。三层开关（TIMG `INT_ENA`、CLIC `IE`、`mstatus.MIE`）任何一层为 0，最终现象都一样：没有 tick。

**闹钟必须绝对重装。** `ALARM_EN` 命中后自动清零（ch08 已记录），每次 ISR 都要重新使能；重装用 `last_target += period`，而不是 `now + period`——后者把 ISR 的迟到量积分成漂移。代价是迟到超过一个周期时目标落在过去，硬件立刻再进一次，形成短时补 tick 风暴；本章 ISR 很短，不预期出现，出现了就是要记录的证据。

配套的一条位：`T0CONFIG.AUTORELOAD`（bit29）**复位默认是 1**，本章的 `tick.init` 显式写 0。开着它，命中闹钟后计数器会从 `T0LOAD`（本工程装的是 0）自动回卷，绝对时间轴（`next_target` 在累加）立刻失去意义；关掉它，计数器只朝一个方向跑，“第 n 次闹钟”才恒等于“`n × period` 微秒”。这一位与 `INT_ENA` 一样属于“复位值不是你想要的默认”的坑。

---

## 11.5 在中断里换栈：为什么不用加 4

tick 到来时，CPU 正在某个任务的任意指令上。`trapEntry` 在**当前任务的栈**上压出 80 字节 trap 帧：

```text
当前任务栈（高地址）
  ┌──────────────────────────────┐
  │ TrapFrame 80B                │  ra, t0–t6, a0–a7, mepc, mstatus
  ├──────────────────────────────┤  ← trapEntry 的 sp
  │ switchTo 的 64B 帧           │  ra, s0–s11（由 switchRaw 压）
  ├──────────────────────────────┤  ← 挂起后写进 TCB.sp 的值
  │ …… 任务自己的栈 ……           │
  └──────────────────────────────┘
```

**每个任务的 `mepc`/`mstatus` 就在它自己的 trap 帧里**，而 trap 帧在它自己的栈上。所以 TCB 不需要额外的 CSR 字段：`sp` 指向 switch 帧，上面就是 trap 帧，偏移固定（`64(sp)`/`68(sp)`）。

恢复时 `switchRaw` 换回 `sp`、恢复 callee-saved、`ret` 到该任务上次 `switchTo` 之后的指令，逐层返回到它自己的 `trapEntry`；后者从本任务帧取回自己的 `mepc`/`mstatus`，`mret` 继续。整条链没有跨任务跳转，全是栈回溯。

| 陷入类型  | `mcause`     | `mepc` 指向  | 返回前      |
| --------- | ------------ | ------------ | ----------- |
| `ecall`   | `11`         | `ecall` 本身 | `mepc += 4` |
| tick 中断 | `0x80000010` | 被打断的指令 | **不动**    |

`ecall` 是同步异常，“跳过陷入指令”才符合语义；中断是异步事件，“回到被打断处继续”才符合语义。两者共用一个 `schedule()` 时，**加 4 必须留在 `ecall` 分支**，不能写进 `schedule()` 开头。ch10 把它放在 `schedule` 第一行——那里 `schedule` 只会被 `ecall` 分支调用，位置无所谓；本章 `schedule` 同时被 tick 与软件中断复用，必须挪进 `ecall` 分支。这是升级到抢占最容易漏的改动，后果是 tick 之后所有任务都“随机跳过一条指令”。

```text
tick 命中 → trapEntry 压 80B 帧 → trapDispatch 判中断
  → tick.handle：清 INT_CLR.bit0、清输入 16 的 IP、重装闹钟 → sched.onTick：ticks++、slice--
       ├─ slice > 0 且无更高优先级就绪 → 直接返回，不换栈
       └─ 否则：当前任务入队尾 → schedule → switchTo → switchRaw
  → 逐层返回 trapEntry，取回本任务 mepc/mstatus → mret
```

清标志顺序是**先清源，再调度**。反过来的话，新任务运行期间 `INT_RAW` 一直为 1，`mret` 后立刻再进一次，表现为“每次切换都多一次 tick”。

---

## 11.6 时间片、优先级与饥饿

`onTick` 只做三个判断，顺序固定：`ticks += 1`；`slice -= 1`（若 > 0）；若 `slice` 归零，**或**存在比 `prev.prio` 更高的就绪任务，就调度一次。

后半句是“优先级抢占”的全部实现：低优先级在跑，高优先级变成 ready（本章只有创建与让出两个入口），下一个 tick 就换它。本章没有“事件当场切换”，因为所有状态变化都发生在 tick 边界；第十二章的唤醒会需要显式 `schedule()`，接口已经在那里。

同为 prio 1 的 A、B，各 `slice = 2`：tick 1 后 A 剩 1；tick 2 后 A 归零、入队尾，选中 B；tick 3/4 轮到 A。**时间片不是定时器，只是一个递减到 0 的计数器**，所以它的精度上限是 tick 周期（1 ms），不是 CPU 周期。

严格优先级的代价是饥饿：只要 prio 5 一直 ready，prio 1 永远不跑。本章的高优先级任务会自己 `done`，低优先级最终能跑——这是**演示需要**，不是调度器保证。真实 RTOS 要么靠阻塞让出，要么靠老化；本章两者都没有。所有任务 `done` 后 `pickNext` 返回 null，idle 检测 `allDone()`、打印统计、停 tick、停在 `wfi`。

---

## 11.7 临界区：改队列的人必须挡住 tick

共享结构只有就绪队列（`ready_head/ready_tail/next`）与 `current`。改动路径三条：`create()` 在 `MIE = 0` 下调用，安全；`yield()` 在任务上下文，会被 tick 打断；`onTick()` 在 ISR 里，不会被同优先级打断，但会被更高优先级 ISR 打断。后两条必须成对关/开中断：

```zig
pub inline fn irqSave() usize {
    const v = asm volatile ("csrr %[d], mstatus" : [d] "=r" (-> usize));
    asm volatile ("csrci mstatus, 0x8"); // 只清 MIE，其它位保持
    return v;
}
pub inline fn irqRestore(old: usize) void {
    asm volatile ("csrw mstatus, %[v]" :: [v] "r" (old));
}
```

`irqSave` 读回整字、再清 `MIE`；恢复时整字写回。**不要退出时无条件开中断**：`yield` 可能本来就在 `MIE = 0` 的上下文里，无条件 `csrsi` 会提前放 tick 进来。保存/恢复旧值才能嵌套。

- `yield` 与 `onTick` 的临界区包住“入队 + `pickNext` + 改 `current` + **`switchRaw` 保存 sp**”。最后一项必须原子：若 `current = next` 之后、sp 落盘之前放中断进来，tick 会看到 `current = next` 却仍在 prev 的栈上，把 prev 的 sp 存进 next.sp——两个任务共用一张栈。最长窗口是“一次队列操作 + 8 级扫描 + 13 次寄存器存取”，几十条指令，不是毫秒。

新任务的 `MIE` 不能由 `schedule` 代开：ISR 里 `irqSave` 读到的 `MIE = 0`，恢复它等于把 0 写给新任务。`taskStart` 的第一条指令 `csrsi mstatus, 8` 负责新任务；被抢占的任务走自己的 `mret`，由 `MPIE` 恢复。两条路都只依赖“任务自己的现场”。

真正长的窗口在 `line()` 里的 `esp_rom_printf`：ROM 格式化不可重入，一次输出可能上千周期。**本章不在临界区里打印**，也不在 tick ISR 里打印（停机路径除外）。任务在打印时被抢占会让两行字符混排，但每个任务的格式化缓冲在自己的栈上，不会损坏内存——这是观测代价，不是正确性问题。

---

## 11.8 软件中断 yield：`ecall` 之外的第二条让出路

ch07 已经配好了 CLIC 输入 19 这条软件中断线：`IP` 就是挂起状态，写 1 等价于“有人敲门”。它给出一条不依赖 `ecall` 的让出路径：

```text
任务上下文：clic.raise(19)            // 写 CLIC_INT_CTRL(19).IP = 1
  → 中断入口（mcause = 0x80000013）
  → ISR：clic.clearPending(19)         // 必须清，否则 mret 后立刻再进
  → sched.schedule（入队 + pickNext，与 tick 到期同一条路径）
```

| 维度        | `ecall`（ch10/本章保留） | 软件中断（输入 19）              |
| ----------- | ------------------------ | -------------------------------- |
| 异常类型    | 同步异常，`mcause = 11`  | 中断，`mcause = 0x80000013`      |
| 依赖 `MIE`  | 不依赖                   | 必须为 1                         |
| `mepc` 处理 | 返回前 `+4`              | 不动                             |
| 触发成本    | 一条 `ecall`             | 读改写一次 MMIO（`IP` 位）       |
| 跨核投递    | 不能                     | 能（矩阵 + 目标核，ch14 的 IPI） |

本章的 `yield()` 仍走 `ecall`：它不需要 `MIE`，在 tick 尚未启动的启动阶段也能用，排错时“异常路径”比“中断路径”更容易定位。软件中断的接口留在 `sched.requestYield()` 里，**没有接线到任务**——它真正的主场是 ch14 的双核 IPI：core0 要叫醒 core1，`ecall` 做不到，只有“往目标核的 CLIC 输入写 `IP`”能做到。这里先把语义与清挂起的责任固定下来，避免到 SMP 章节才第一次遇到它。

> [!warning] 待真机验证
> 输入 19 的 `IP` 写 1/清 0 在 S31 上的具体行为（是否需要边沿应答、是否与 `SHV` 有关）未在本板实测；本章不启用这条路径。

---

## 11.9 tickless：什么时候该把 tick 关掉

1 ms 的周期中断在“有任务要跑”时是必要的，在“所有任务都在等”时纯属浪费：每毫秒唤醒一次 CPU、进一次 ISR、跑一遍调度，然后发现还是 idle。**tickless 的目标是让空闲期完全不进 tick ISR**。

真正的 tickless 需要三件事，缺一不可：

1. **一个可读的单调时基**——决定“现在几点”。ch08 的 SYSTIMER 52 位计数器就是它；TIMG 计数器也能读，但要先 `UPDATE` 快照。
2. **把“最近的 deadline”写进一次性闹钟**——不是周期闹钟，而是“下一个任务该醒的时刻”。醒来后重算，再装下一个。
3. **一条唤醒路径**——新任务就绪、中断到来时，要能把一次性闹钟改成“立刻”或更早的时刻，否则睡过头。

本章只落地第 1 步的读法与第 3 步的边界：**所有任务 `done` 之后，idle 关闭 tick（清 `T0_EN`/`ALARM_EN`、清 `INT_ENA` 的 bit0、关 CLIC 输入的 `IE`，三层一起断开），然后 `wfi`**。这不是 tickless 调度器，只是“空闲时停表”。真正的 tickless 需要一个“最近 deadline”结构，而本章没有 `blocked` 状态、没有睡眠接口，硬做只会得到一个假装省电、实际靠周期中断兜底的四不像。

> [!warning] 待真机验证
> 停 tick 后 `wfi` 的唤醒源只剩外部中断；本章没有再唤醒路径，所以这是终止状态，不是低功耗模式。tickless 的完整实现与功耗数据留给后续章节。

---

## 11.10 FPU 边界：208 字节帧与不能懒保存

本章仍然只跑整数任务。S31 的三个限制决定了浮点任务必须单独设计：

1. **`SOC_CPU_HAS_FPU_EXT_ILL_BUG=1`**：EXT_ILL 的 CSR 访问不支持 `FLW`/`FSW`，标准 RISC-V 的懒保存（`FS = 0` → 非法指令 → 异常里保存）不可行。
2. **`SOC_PM_FPU_RETENTION_BY_SW=1`**：低功耗不保留 FPU 状态，软件必须自己存。
3. **`mstatus.FS` 在 bit[14:13]，复位 0**：任何浮点指令前必须置非零。

结论：浮点帧 **208 字节**，必须**无条件保存全部 32 个 f 寄存器**（不能只存 ABI 的 callee-saved 那一半）：

```text
64（整数 switch 帧）+ 128（f0–f31）+ 4（fcsr）+ 12（填充）= 208
```

`mstatus.FS` 随任务的 trap 帧保存，所以“每个任务有自己的 FP 状态”自动成立——前提是切换路径确实保存了 `mstatus`；ch10 的 `trapEntry` 做了，本章沿用。

> [!warning] 待真机验证
> 本工程不含浮点指令、不配置 `FS`、不实现 208 字节帧。上面三条来自 IDF v6.1 `soc_caps.h` 与 RISC-V 特权规范，未在本板实测。

---

## 11.11 工程走读

| 文件              | 职责                                                                      |
| ----------------- | ------------------------------------------------------------------------- |
| `src/context.zig` | 80B trap 帧、64B switch 帧、`trapEntry`、`switchRaw`、初始帧（沿用 ch10） |
| `src/sched.zig`   | TCB、8 条优先级队列、`onTick`、`schedule`、`yield`、临界区、`start`       |
| `src/tick.zig`    | T0 时钟/分频/闹钟/INT_ENA、矩阵[25]=16、CLIC 输入 16、ISR 清源与绝对重装  |
| `src/tasks.zig`   | 三个**不主动让出**的任务：不同优先级/时间片，靠 tick 被换下               |
| `src/main.zig`    | 打印配置、建任务、初始化 tick、把 `main` 变成 idle                        |
| `src/start.zig`   | `esp_app_desc_t` + `_start`（关中断 → sp/gp → 清 .bss → 装 mtvec）        |
| `linker/s31.ld`   | `.app_desc` 最前、`.text.trap` 4 字节对齐、`gp` 锚点、SRAM-only           |
| `tools/flash.sh`  | 读 `flash_args`、替换 0x10000 应用行、`FLASH_DIR` 锚定                    |

完整源码可站内浏览（不离开本站看高亮版本）：

| 文件                               | 代码浏览                                                                                        |
| ---------------------------------- | ----------------------------------------------------------------------------------------------- |
| `build.zig`                        | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/build.zig)                        |
| `linker/s31.ld`                    | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/linker/s31.ld)                    |
| `src/start.zig`                    | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/start.zig)                    |
| `src/context.zig`                  | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/context.zig)                  |
| `src/sched.zig`                    | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/sched.zig)                    |
| `src/tick.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/tick.zig)                     |
| `src/tasks.zig`                    | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/tasks.zig)                    |
| `src/main.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/src/main.zig)                     |
| `idf-bootstrap/CMakeLists.txt`     | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/idf-bootstrap/CMakeLists.txt)     |
| `idf-bootstrap/main/app_main.c`    | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/idf-bootstrap/main/app_main.c)    |
| `idf-bootstrap/sdkconfig.defaults` | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/idf-bootstrap/sdkconfig.defaults) |
| `tools/flash.sh`                   | [查看](/static/code/#/zig-esp32-s31/ch11-preemptive-scheduler/tools/flash.sh)                   |

任务体里**没有 `yield()`**：它们只是循环、打印、再循环，被换下完全由 tick 决定。这就是“抢占”的可观测定义。

```text
_start：MIE=0、mie=0 → sp/gp → 清 .bss → mtvec=trapEntry → call main
  main：banner/帧长 → create(hi,prio 5,slice 3) / loA、loB(prio 1,slice 2)
       → tick.init(1000)：clkrst→T0CONFIG→闹钟→INT_ENA bit0→矩阵[25]=16→输入16 prio3/IE→阈值0 → sched.start()：MIE=1 → yield → 选中 prio 5
```

两个顺序不可交换：**`tick.init` 必须在 `MIE = 1` 之前**（否则第一个 tick 落在“矩阵未写、输入未使能”的窗口里，`INT_RAW` 置位没人清）；**`mtvec` 也必须在 `MIE = 1` 之前**（ch10 已有约束，抢占让它更要命）。

两条来自 ch04 的链接约束不变：`.app_desc` 必须是第一个装载段最前 256 字节（否则 bootloader 报 `Failed to fetch app description header!`）；`__global_pointer$` 必须落在 `.data` 与 `.sdata` 之间（本工程 `.data` 之后 `+0x800`），`gp` 错了会让全局变量静默偏移。tick 的静态变量与 TCB 池都是普通 `.bss`/`.data` 对象，不需要新段。

`tools/flash.sh` 与 ch08–ch10 逐字同构：不调用 `idf.py`，只读 `idf-bootstrap/build/flash_args`，把 `0x10000` 那行换成 `zig-out/bin/app.bin` 的绝对路径，`cd` 到 `FLASH_DIR` 再执行 esptool（文件里的 bootloader/分区表路径相对 build 目录）。偏移的唯一权威是 `flash_args`。

---

## 11.12 验收与证据

1. 串口出现 banner、`frames: trap=80 switch=64`、`tick: 1000 us via TIMG0 T0 (source 25) -> clic input 16 prio 3`；
2. 高优先级 `hi` 先运行；它运行期间 `loA`/`loB` **完全没有输出**（优先级生效）；
3. `hi` 结束后，`loA` 与 `loB` 的输出按时间片交替，且交替**不依赖任务自己让出**；
4. 每个任务打印自己的 `beat` 计数，`done` 之后不再出现该任务输出；
5. 全部完成后 idle 打印 `sched: all tasks done ticks=<n> switches=<m>`，随后停在 `wfi`；
6. 连续复位 10 次，交错顺序与 `switches` 稳定；
7. 用 SYSTIMER 统计的 tick `min/avg/max` 与 GPIO 翻转测得的 ISR 宽度可复现（实测值记录在案，本仓不预填）。

```text
ch11-preemptive-scheduler | form B (Zig ELF + IDF 2nd-stage bootloader)
tick: 1000 us via TIMG0 T0 (source 25) -> clic input 16 prio 3
hi: beat 1 (prio=5 slice=3)
hi: done (steps=<n>)
loA: beat 1 (prio=1 slice=2)
loB: beat 1 (prio=1 slice=2)
sched: all tasks done ticks=<n> switches=<m>
idle: wfi
```

行数取决于忙等长度与编译器的常量折叠，本仓不预填。**能验收的是顺序关系，不是行数。**

ch08 的口径在这里复用：**漂移是长期平均周期的偏差，抖动是单次间隔的分布宽度**。测法有两条，互相对照：

1. **第二时基**：tick ISR 入口读一次 SYSTIMER（52 位、16 MHz），把与上一次的差值累加成 `interval_ticks`；每 1000 个 tick 打印 `min/avg/max`。16 MHz 下 1 µs = 16 counts，分辨率足够看 1 ms 周期的抖动。
2. **GPIO 翻转 + 示波器**：ISR 入口翻转一个空闲 GPIO（例如排针上的测试点），出口再翻回来。高电平宽度就是 ISR 执行时间，相邻上升沿间隔就是 tick 周期；不占用串口，也不受打印延迟干扰。

```text
tick stats: n=1000 period=1000 us | min=<a> avg=<b> max=<c> us | isr_max=<d> us
```

预期（验收目标）：`avg` 贴近 1000 µs，`max - min` 的量级由 ISR 体与临界区决定，`isr_max` 应远小于 1000 µs。**本仓没有这些数字**，因为它们必须在真机上测；任何“约 ±X µs”的写法都是编造。测量本身要关掉 `line()` 打印（串口输出会污染时间轴），统计只在最后打印一次。

```bash
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
riscv32-esp-elf-nm -n zig-out/bin/app.elf | grep -E 'trapEntry|switchRaw|taskStart'
grep -n "mepc" src/sched.zig src/context.zig    # 确认 +4 只在 ecall 分支
grep -n "INT_ENA" src/tick.zig                  # 确认 tick.init 置了 INT_ENA_TIMERS.bit0
```

---

## 11.13 排错

| 现象                           | 根因                                                             | 处置                                                                            |
| ------------------------------ | ---------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 只有 banner，任务不跑          | `MIE` 没开；或 `irqRestore` 把 0 写回                            | 打印 `mstatus`；确认恢复的是进入临界区前的值                                    |
| 顺序等于创建顺序               | tick 没进：`INT_ENA` 没开、矩阵写成 0..31、`IE` 没置、或阈值 ≥ 3 | 读回 `INT_ENA_TIMERS` bit0 为 1；矩阵[25] 应为 16；读 `CTRL(16)` bit8；阈值设 0 |
| 每个任务都跳过一条指令         | `mepc += 4` 也应用到了中断路径                                   | 加 4 只放在 `ecall` 分支                                                        |
| tick 后立刻又进 ISR            | `INT_CLR` 或 CLIC `IP` 没清                                      | 先写 `INT_CLR_TIMERS.bit0`，再清输入 16 的 `IP`，最后重装闹钟                   |
| 第一次抢占后再也没有 tick      | `taskStart` 没开 MIE：新任务没有 trap 帧，不会走 `mret`          | `taskStart` 第一条加 `csrsi mstatus, 0x8`                                       |
| 高优先级结束后低优先级仍不跑   | `done` 的任务仍被入队                                            | `finish()` 先置 `done` 再 `yield`；`schedule` 只在 `running` 时入队             |
| `trap: unexpected cause=0x...` | 进了非 tick 中断（矩阵配错源）或同步异常                         | 最高位为 1 时低 6 位是 CLIC 输入号，据此反查                                    |
| `all tasks done` 后立刻复位    | idle 退出后回到 `_start` 的返回路径                              | idle 循环 `noreturn`；统计后停在 `wfi`                                          |

---

## 11.14 下一章预告

本章的任务只会“跑”和“结束”，不会“等”。调度器只需要回答“现在谁最该跑”，不需要回答“它在等什么、何时醒”。

下一章补上同步原语与 IPC：自旋锁（A 扩展）、关中断、信号量/互斥量、队列与事件组，以及“有阻塞之后才真正出现”的优先级反转与继承。本章留下的两个接口（`schedule()` 的显式调用点、`irqSave/irqRestore`）就是为它准备的。

---

## 事实来源

| 事实                                                      | 来源                                            | 备注                                        |
| --------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------- |
| callee-saved = `sp`、`s0`–`s11`；栈 16 字节对齐           | RISC-V psABI（ILP32）                           | 与 ch10 一致；帧长 64                       |
| trap 帧 = 16 GPR + `mepc` + `mstatus` + 2 填充 = 80 字节  | 本章 + ch10                                     | 中断路径不加 4                              |
| `mstatus.FS` 位于 bit[14:13]，复位 0                      | RISC-V 特权规范                                 | 用 FP 前必须置非零                          |
| TIMG0 `0x20580000`；`T0CONFIG`/`T0ALARMLO`/`INT_CLR` 偏移 | IDF v6.1 `reg_base.h` + `timer_group_reg.h`     | `INT_CLR_TIMERS = 0x7c`，T0 = bit0          |
| `INT_ENA_TIMERS = 0x70`，T0 使能 = bit0，复位 0           | IDF v6.1 `timer_group_reg.h`                    | 不开则 `INT_RAW` 出不了 TIMG；ch08 同一结论 |
| `T0CONFIG.AUTORELOAD` = bit29，复位 1                     | IDF v6.1 `timer_group_reg.h`                    | 本章显式清 0，否则命中即回卷毁掉绝对时间轴  |
| TIMG0 T0 时钟源/门控在 `HP_SYS_CLKRST + 0x114`            | IDF v6.1 `hp_sys_clkrst_reg.h`                  | `T0_SRC_SEL`[4:3]、`T0_CLK_EN`[5]           |
| 源 25 = `ETS_TIMERGRP0_T0_INTR_SOURCE`；源 33 = SYSTIMER  | IDF v6.1 `soc/interrupts.h`                     | 与 ch07 源表一致                            |
| 矩阵基址 `0x20585000`，每源 4 字节，`MAP`[5:0]            | IDF v6.1 `reg_base.h` + `interrupt_core0_reg.h` | 写 CLIC 输入号 = 通道 + 16                  |
| CLIC `0x10800000`；输入块 `0x10801000 + 4i`               | IDF v6.1 `clic_reg.h`                           | `IE` bit8、`IP` bit0、`CTL`[31:24]          |
| CLIC 8 级、阈值“≤ 被屏蔽”；输入 19 为软件中断             | IDF v6.1 `clic_reg.h`（`NLBITS=3`）+ ch07       | 阈值 0 不挡                                 |
| `mcause` 最高位 = 中断，低 6 位 = 输入号                  | ch07 结论 + CLIC 规范                           | tick = `0x80000010`，软中断 = `0x80000013`  |

## 自查清单

- [ ] 协作式与抢占式在“谁决定下一次切换”上的差别？为什么后者 `MIE` 必须为 1？
- [ ] TCB 的 `sp` 为什么仍是唯一锚点？抢占没有改变它的原因是什么？
- [ ] `prio` 为什么用 `u3`？`slice` 为什么按 tick 而不是毫秒？
- [ ] 就绪队列为什么是“8 条链 + 尾插头取”？idle 为什么不进 `ready_head[0]`？
- [ ] tick 为什么选 TIMG0 T0？SYSTIMER 的代价是什么？
- [ ] 矩阵第 25 号源地址多少？写进去的值为什么是 16？
- [ ] 一条 tick 要穿过哪三层开关？只配矩阵与 CLIC、不置 TIMG 的 `INT_ENA` 会看到什么现象？
- [ ] `mcause = 0x80000010` 的最高位与低 6 位各是什么？
- [ ] 为什么 tick 不能 `mepc += 4`，而 `ecall` 必须？
- [ ] 每个任务的 `mepc`/`mstatus` 存在哪里？TCB 为什么不需要额外字段？
- [ ] 闹钟为什么用 `last_target + period` 而不是 `now + period`？
- [ ] `irqSave/irqRestore` 为什么保存旧值，而不是退出时无条件开？
- [ ] 软件中断 yield 与 `ecall` 在 `mcause`、`MIE`、`mepc` 上各差什么？为什么 IPI 必须用它？
- [ ] 真正的 tickless 需要哪三件事？本章停 tick 为什么只是终止状态？
- [ ] FPU 帧为什么 208 字节？为什么不能只保存 callee-saved 的 f 寄存器？

---

本章的产出是**一个不再依赖任务自觉的调度器**：tick 由 TIMG0 产生，经矩阵第 25 号源进入 CLIC 输入 16，在 ISR 里递减时间片、按 8 级优先级选任务，并用 ch10 的 64/80 字节两层帧完成换栈。下一章让任务学会等待与互斥。

系列导航：[[ch10-context-switch-cooperative-scheduler|上一章]] · [[zig-esp32-s31|系列索引]]
