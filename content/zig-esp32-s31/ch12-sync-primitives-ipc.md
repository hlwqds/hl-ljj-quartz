---
title: "Zig × ESP32-S31 全栈开发（十二）：同步原语与 IPC"
date: 2026-11-27 12:00:00
description: "给 ch11 的抢占调度器补上 blocked 状态，然后在它之上实现五种同步原语：A 扩展的 lr.w/sc.w 自旋锁（单核必须先关中断）、关中断临界区、计数信号量、带优先级继承的互斥量、定长环形队列与事件组；并用两个对照阶段把『优先级反转』从一句话变成可判读的 tick 数。"
tags: [zig, esp32-s31, riscv, rtos, ipc, sync, series]
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
> 11. [[ch11-preemptive-scheduler-tcb-tick|第十一章：抢占调度、TCB 与 tick]]
> 12. **第十二章：同步原语与 IPC**
> 13. [[ch13-heap-stack-caps|第十三章：堆、栈保护与内存 caps]]

# Zig × ESP32-S31 全栈开发（十二）：同步原语与 IPC

第十一章的调度器只有 ready / running / done 三个状态。它能回答“现在谁最该跑”，不能回答“它在等什么、什么时候醒”。这条缺口看起来只是一个枚举成员，实际上是内核里最难的一块：有了“等”，就有了**丢失唤醒**、**惊群**、**优先级反转**，以及“谁有权把一个任务叫醒”这个所有权问题。

本章补上 blocked，然后在它之上实现五种原语：A 扩展的 `lr.w`/`sc.w` 自旋锁、关中断临界区、计数信号量、带优先级继承的互斥量、定长环形队列与事件组。核心不是把五种原语都写一遍，而是把**它们的适用边界**钉死——单核上为什么自旋锁必须先关中断、为什么继承只能救“已就绪但被挡住”的那一段、为什么阻塞必须用 `while` 重检查。

> [!warning] 本章的证据边界
> 形态 B 不变（Zig 产 ELF、自有链接脚本、IDF 只提供二级 bootloader 与分区表）。寄存器与指令语义取自 ESP-IDF v6.1 的 `esp32s31` 头文件、RISC-V 规范与 IDF 的 FreeRTOS 端口。本工程**已于 2026-11-13 部分实测**：spin 与 no-pi 阶段跑通（`spin: locked=1000 atomic=1000 …`、`phase no-pi: high_wait=90 ticks boosts=0 span=99 ticks`，`../logs/ch12-boot.log`）；**PI 阶段仍挂起**（心跳消失），其余数字按验收目标对待，详见 `BRINGUP-2026-11-12.md`。
>
> 另外，第十一章在真机上留下了三条记录（idle 栈被覆盖导致 `instruction access fault`、`pickNext` 复活已结束任务、同优先级任务被抢占后长时间不产出）。前两条本章已经修在设计里，第三条**仍未闭环**——见 12.13，它不会被写成“已验证”。

---

## 12.1 为什么“能抢占”还不够

ch11 的三个状态是**调度器视角**的分类：能跑、在跑、跑完了。任务是主动的——它自己决定什么时候结束。而 “等” 是被动的：任务等的那件事由别人完成，所以内核必须额外记住两样东西：

1. **它在等哪个对象**（互斥量、信号量、队列、事件组、还是一次睡眠）；
2. **谁有资格叫醒它**（那个对象的持有者/生产者）。

只有第一样而没有第二样，“唤醒”就退化成广播：所有等待者醒一遍、各自检查条件、大多又睡回去。这不是并行，这是抖动。

| 维度       | ch11（无 blocked）         | 本章（有 blocked）                      |
| ---------- | -------------------------- | --------------------------------------- |
| 任务状态   | ready / running / done     | 追加 blocked                            |
| TCB 缺什么 | ——                         | 等待链指针、等待对象名、基础/有效优先级 |
| 等锁的写法 | 自旋（烧 CPU，且必然反转） | 阻塞（不烧 CPU，可被继承修复）          |
| 换栈触发点 | tick 到期、主动 `ecall`    | 追加：阻塞、唤醒、放锁时的立即抢占      |
| 新的失败型 | 饥饿                       | 丢失唤醒、惊群、反转、死锁              |

最后一行才是重点。ch11 的最坏情况是“低优先级饿着”，本章的最坏情况是“整机静默卡死”：两个任务互相持有一把锁、或者一个任务在等待链上却再也不会被唤醒，现象都是串口突然不动——而且因为死锁常发生在关中断的窗口里，连“卡在哪”都打不出来。所以本章除了实现，还要给调度器加一个**停滞诊断**（12.11 末尾）。

### 三种“互斥”手段，三种场合

| 手段                 | 挡住谁                       | 代价                     | 唯一正确的场合                             |
| -------------------- | ---------------------------- | ------------------------ | ------------------------------------------ |
| 关中断临界区         | 同核上的中断与抢占           | 关多久就丢多久的实时性   | 改内核链表、改几字节共享状态（几十条指令） |
| `lr.w`/`sc.w` 自旋锁 | **另一个 hart** 的并发读改写 | 自旋烧电、依赖缓存一致性 | SMP 下跨核保护；单核上必须与关中断配对     |
| 互斥量（阻塞式）     | 上层任务，且有所有权         | 一次上下文切换（µs 级）  | 临界区里有慢操作、可能等待的共享资源       |

这三行不是“三选一”，而是“三个不同层次”。本章的代码里它们同时存在：`spin.acquire` 的第一件事是关中断，`mutex.lock` 的第一件事是关中断，队列的环形下标更新也在关中断的窗口里。**关中断是底座**，自旋锁和互斥量只是在这个底座上解决不同层面的问题。

---

## 12.2 原子指令：LR/SC 与 AMO 各自解决什么

RISC-V 的 A 扩展给了两组原语，它们解决的问题不一样：

| 指令族          | 形态                       | 表达力                                  | 失败方式                        |
| --------------- | -------------------------- | --------------------------------------- | ------------------------------- |
| `lr.w` + `sc.w` | 独占读 → 任意计算 → 条件写 | 可以表达**任意**读改写（包括 CAS 循环） | `sc.w` 返回非 0，必须**重新读** |
| `amoswap.w`     | 原子交换                   | 只能“换成某个值”                        | 不会失败                        |
| `amoadd.w`      | 原子加                     | 只能“加一个数并返回旧值”                | 不会失败                        |

`lr.w` 在目标地址上建立一次 reservation；`sc.w` 只有在 reservation 仍然有效时才写入。**失败不是错误**，它表示“你手上的读已经过期了，别人在这中间改过”。唯一正确的反应是回到 `lr.w` 重来：

```text
cas:  lr.w   t0, (a)          # 独占读
      bne    t0, expect, fail # 旧值不是期望值 → 直接放弃（不是重试）
      sc.w   t1, new, (a)     # 只有 reservation 还在时才写
      bnez   t1, cas          # 写失败 → 状态变了，必须重读
fail:
```

IDF 自己的 `rv_utils_compare_and_set`（`components/riscv/include/riscv/rv_utils.h:513`）就是这个形状，一行不差；`#if __riscv_atomic` 决定它是走 `lr/sc` 还是退化成“关中断 + 普通读写”。这条退化分支很值得看：**没有 A 扩展的核上，所谓 CAS 就是关中断**——说明这两件事在单核上是同一件事的两种写法。

本章的 `spin.zig` 用内联汇编复刻这个循环，两个寄存器约束必须写成 `=&r`（early clobber）：

```zig
fn tryCas(p: *volatile u32, expect: u32, replace: u32) bool {
    var old: u32 = 0;
    var err: u32 = 0;
    asm volatile (
        \\  lr.w   %[o], (%[a])
        \\  bne    %[o], %[e], 2f
        \\  sc.w   %[r], %[n], (%[a])
        \\  bnez   %[r], 2f
        \\2:
        : [o] "=&r" (old),
          [r] "=&r" (err),
        : [a] "r" (@intFromPtr(p)),
          [e] "r" (expect),
          [n] "r" (replace),
    );
    return old == expect and err == 0;
}
```

`lr.w` 会**先写** `old`，而 `expect`/`replace`/地址都是输入。若不给 `=&`，编译器有权把某个输入分配到与 `old` 相同的物理寄存器里，生成的代码就是错的——而且错得很安静：单核上几乎必成功，只有在真正并发时才偶发。这类错误没有日志可查，只能靠约束写对。

### 内存序：`.aq`/`.rl` 与 `fence`

原子性 ≠ 可见性。`amoadd.w` 只保证“这个地址的读改写在硬件上不可分割”，它不保证前面写的其它变量已经对别人可见。本章用两种手段：

- **指令后缀**：`amoswap.w.aq` / `amoadd.w.aq` 带 acquire 语义（后续访存不能上浮到它前面）；
- **显式屏障**：`fence rw, rw`，用于“放锁”这一侧（此前的共享写必须先生效，再让锁看起来是空的）。

还有一条容易被忽略的边界：**`asm volatile` 不是编译器屏障**。它保证这段汇编不被删除、不被复制、不会跨它做纯计算的重排，但它没有声明“我读写内存”，所以编译器理论上仍可以把普通的全局写挪过它。本章是单 hart + 关中断，没有第二个 hart 能观察到这种顺序，因此不受影响；但要写对，得显式告诉编译器这条汇编会碰内存——Zig 0.17 各架构的 `Clobbers` 结构都有 `memory` 字段：

```zig
// 读写任意内存都不能跨过这条 asm
asm volatile ("fence rw, rw" ::: .{ .memory = true });
```

`spin.zig` 的 `release` 与 `tryCas` 都带了 `.memory = true`；这也是为什么 `busyTicks` 里的计数器要经 `*volatile` 读（见 12.9）——两条是同一类错误的两种形态：**编译器并不知道你的汇编做了什么，你必须告诉它。**

另一个同等有效的写法是 Zig 的内建原子：

```zig
@atomicStore(u32, &l.locked, 0, .release);   // 会生成带 .rl 语义的存储
```

---

## 12.3 单核上的自旋锁：为什么必须先关中断

自旋锁在教科书里的前提是“有别的核会释放它”。单核上这个前提不成立，于是出现一个非常具体的死锁：

```text
t=0.0ms  L（prio 1）: spin.lock(lk)     ← 拿到锁，locked = 1
t=0.3ms                                 ← tick 中断，L 被换下
t=0.3ms  H（prio 5）: spin.lock(lk)     ← 自旋等待
         ...                            ← H 优先级最高，L 永远得不到 CPU
         锁永远不释放                    ← 同一颗 hart 上的自旋 = 永久空转
```

H 在自旋里烧掉全部 CPU，而唯一能放锁的 L 正躺在就绪队列里等 CPU。这不是“性能问题”，是**逻辑死锁**，而且因为它在中断里也可能发生，常见现象是串口一行字都不吐。

所以本章的 `spin.acquire` 第一件事不是 CAS，是关中断：

```zig
pub fn acquire(l: *SpinLock) usize {
    const old = sched.irqSave();          // 先关中断：把“被抢占”这个前提消掉
    var guard: u32 = 0;
    while (!tryCas(&l.locked, 0, 1)) {    // 关中断后，单核上第一次必然成功
        retries += 1;
        guard += 1;
        if (guard >= max_spins) { giveups += 1; break; }
    }
    acquisitions += 1;
    return old;                            // 返回旧 mstatus，放锁时原样交回
}
```

这不是本系列的发明，IDF 的 `spinlock_acquire`（`components/esp_hw_support/include/spinlock.h:74`）就是同一个顺序：先 `rv_utils_set_intlevel_regval(RVHAL_EXCM_LEVEL_CLIC)` 抬高中断级别，再 `esp_cpu_compare_and_set(&lock->owner, SPINLOCK_FREE, core_owner_id)`。`esp_cpu_compare_and_set`（`components/esp_hw_support/cpu.c:196`）在 RISC-V 上最终落到刚才那个 `lr/sc` 循环。

那自旋锁在 S31 上还有意义吗？有，但不在本章。`SOC_CPU_CORES_NUM` 是 **2**（`components/soc/esp32s31/include/soc/soc_caps.h:175`），第二个 hart 要到 ch14 才启动；一旦两个核同时改同一份内核链表，“关中断”就完全挡不住对方了——**关中断是本核的性质，不是全局的性质**。那时才轮到自旋锁上场，而且必须与关中断组合（先关本核中断，再抢跨核锁），否则会出现“本核中断没关 → 被本核的 ISR 重入同一把锁”。

`max_spins` 那个上限不是修复，是**诊断**：单核 + 关中断下它永远不会触发；真触发了说明有人关着中断等一把不会释放的锁，继续自旋只会让板子静默卡死，所以记一笔 `giveups` 再放行，把问题暴露在后面的日志里。

---

## 12.4 关中断临界区：`irqSave` / `irqRestore` 的正确形状

内核里最常用、也最容易被写错的临界区只有两条指令：

```zig
pub inline fn irqSave() usize {
    const v = asm volatile ("csrr %[d], mstatus" : [d] "=r" (-> usize));
    asm volatile ("csrci mstatus, 0x8");   // 只清 MIE，其它位保持
    return v;
}

pub inline fn irqRestore(old: usize) void {
    asm volatile ("csrw mstatus, %[v]" :: [v] "r" (old));
}
```

三条不可交换的理由：

1. **返回旧值而不是“开中断”**。临界区可以嵌套：`mutex.lock` 关一次，里面的 `blockOn` 又关一次。内层退出时必须恢复“进入内层之前”的状态，也就是**仍然关着**；无条件 `csrsi mstatus, 8` 会把外层还没做完的窗口直接捅开。
2. **整字写回，而不是只置 MIE**。`mstatus` 里还有 `MPIE`、`MPP`、`FS`、`SUM` 等位，逐位置位容易漏；整字恢复才是“回到进入前”。
3. **`mstatus` 是每任务一份**，因为它在每个任务自己的 trap 帧里（ch11 的 80 字节帧偏移 68）。所以 A 任务关中断、被换下、B 任务开中断，互不影响；每个任务恢复时读的是自己的那一份。

### 临界区必须包住什么

```text
irqSave
  ├─ 改就绪链 / 等待链 / 队列下标 / 互斥量 owner
  ├─ 选下一个任务（pickNext）
  ├─ current = next
  └─ switchRaw 把旧 sp 写进 TCB
irqRestore        ← 注意：只有“切回来”之后才执行到这里
```

最后一项必须原子：若 `current = next` 之后、`sp` 落盘之前放中断进来，tick 会看到 `current = next` 却仍在 prev 的栈上，把 prev 的 sp 存进 next.sp——两个任务从此共用一张栈。这个窗口的长度是“一次链表操作 + 8 级扫描 + 13 次寄存器存取”，几十条指令，**不是毫秒**，但它每天都在被命中。

而 `switchRaw` 之后控制流已经跑到**另一个任务**上，所以 `irqRestore` 实际是在“这个任务再次被调度上 CPU”之后才执行的——临界区跨过了换栈。这不是 bug：对每个任务来说，它自己的关/开是配对的。

### 不在临界区里打印

`esp_rom_printf` 是 ROM 里的格式化函数，不可重入，一次输出可能上千周期。本章的规则：

- **临界区里不打印**（`markDone` 的打印在置 `done` 之前，且不在任何关中断窗口内）；
- **ISR 里不打印**，除了停机诊断；
- 任务打印时被抢占会让两行字符混排，但每个任务的格式化缓冲在自己的栈上（`line()` 用 192 字节局部数组），不会损坏内存——这是观测代价，不是正确性问题。

---

## 12.5 TCB 扩展：等待对象、基础/有效优先级

ch11 的 TCB 有 `sp/state/prio/slice/slice_init/next/steps/ticks/idle`。本章加六个字段：

| 字段         | 类型         | 作用                              | 为什么不能省                                    |
| ------------ | ------------ | --------------------------------- | ----------------------------------------------- |
| `state`      | 枚举         | 追加 `blocked`                    | 没有它就无法区分“该跑”和“在等”                  |
| `wait_next`  | `?*Task`     | 等待链（或睡眠链）上的下一个      | 与 `next`（就绪链）分开：一个任务只能在一个链上 |
| `wait_on`    | `[]const u8` | 对象名或 `"sleep"`，**只为打印**  | 死锁时这是唯一能说清“谁在等谁”的信息            |
| `base_prio`  | `u3`         | 创建时的优先级                    | 继承结束后要还原，还原目标不能是“当前值”        |
| `sleep_left` | `u32`        | 剩余睡眠 tick，0 表示不在睡眠链上 | 睡眠是第三种唤醒源（tick），需要一个计数器      |
| `boosts`     | `u32`        | 被继承抬高的次数，**只为证据**    | 让“继承到底有没有发生”变成可核对的数字          |

`next` 与 `wait_next` 是两个不同的链指针，一个任务同刻只能出现在其中一条链上（或者哪条都不在，即 running/done）。这条不变量值得单独说：如果 `blockOn` 之后又把它入就绪链，它会同时出现在两条链上——被唤醒一次、被 tick 选一次，两个调度器都以为自己拥有它，栈就乱了。

### 为什么改优先级要重新挂链

就绪队列是**按优先级分桶**的环形链（ch11 的 8 条链）。`prio` 字段和“它在哪条链上”必须始终一致，否则 `pickNext` 按链找、任务却宣布自己是另一级：

```text
ready_head[1] ──► [L] ──┐      L.prio = 1
                  ▲      │      继承要求 L 变成 5
                  └──────┘      若只改字段：链还在 1，pickNext 永远找不到 5 级的就绪者
```

所以 `setPrio` 是先摘后挂：

```zig
pub fn setPrio(t: *Task, p: u3) void {
    if (t.prio == p) return;
    const in_ready = t.state == .ready and !t.idle;
    if (in_ready) unlinkReady(t);   // 用**旧** prio 定位它
    t.prio = p;
    if (in_ready) enqueue(t);       // 按新 prio 入链
}
```

环形链没有双向指针，`unlinkReady` 只能线性找前驱（最多 16 个节点）。这不是为了省内存，而是因为 TCB 只有一份、侵入式链表不需要额外分配——代价就是删除是 O(n)。真实内核用按优先级分桶的双向链，或者干脆让任务在改优先级时先出队再说。

---

## 12.6 阻塞与唤醒：`blockOn` / `wake` / handoff

阻塞的全部代码只有十几行，但每一行都在挡一种 bug：

```zig
pub fn blockOn(list: *WaitList, what: []const u8) void {
    const t = current orelse return;
    const old = irqSave();
    t.state = .blocked;
    t.wait_on = what;
    t.sleep_left = 0;
    waitPush(list, t);
    block_events += 1;

    schedule(false);        // requeue = false：绝不能回到就绪链

    irqRestore(old);
}
```

四个决定：

1. **`irqSave` 在改状态之前**。否则会出现经典的丢失唤醒：

   ```text
   A: 检查条件（不满足）
   B:                        ← 中断在这里进来，别人满足条件并调用 wake
   A: 把自己挂进等待链        ← wake 早就过去了，A 永远睡着
   ```

   `wake` 看到 `state != .blocked` 会直接忽略，所以这个窗口必须整段关中断。

2. **`requeue = false`**。`schedule` 只在 `requeue && state == .running` 时把当前任务入队；blocked 的任务已经在等待链上，再入就绪链就违反了 12.5 的不变量。

3. **`wait_on` 是诊断字段**。它不参与任何判断，但死锁时 idle 的停滞报告能直接打出“L1 在等 `m-no-pi`，H1 在等 `m-no-pi`，M1 在跑”。

4. **返回时一定已经被唤醒并重新调度**。`schedule` 会把 CPU 交给下一个任务；本函数只有在某个 `wake` 把它变回 ready、再被选中时才继续。

### 唤醒：谁该醒，按什么顺序

```zig
pub fn wake(t: *Task) void {
    if (t.state != .blocked) return;   // 双重唤醒是幂等的
    t.state = .ready;
    t.wait_on = "";
    t.wait_next = null;
    enqueue(t);
}
```

`waitPopBest` 挑的是**有效优先级最高**的等待者（同级取最早入队），不是严格 FIFO。理由是语义：资源应该交给最该跑的那个任务。若严格 FIFO，高优先级等待者会被“先来的低优先级”挡住——那只是把反转从中优先级插队换成了等待队列插队。

### handoff 而不是“醒来再抢”

本章所有原语都用 **handoff**：放锁/放名额时直接把资源交给被选中的等待者。

- **不用 handoff**（醒来再抢）：被唤醒的任务要重新竞争，可能又被第三个任务抢走，于是再睡回去。现象是“明明有人放锁了，等待者却多等一个 tick”，而且重复发生。
- **用 handoff**：`unlock` 里先把 `owner` 写成等待者，再 `wake` 它。等待者醒来直接认为“我持有”，不再检查。

代价是 handoff 必须保证“被选中者一定能跑”（否则资源被一个暂时跑不起来的任务拿着）。本章的做法是唤醒后立刻判断是否需要抢占：

```zig
pub fn rescheduleIfNeeded() void {
    const cur = current orelse return;
    if (cur.idle) { if (hasReady()) schedule(false); return; }
    if (hasHigherReady(cur.prio)) schedule(true);
}
```

这一步是本章的“可测量性”关键。ch11 的抢占只发生在 tick 边界（1 ms）；如果继承也只管改字段、等下一个 tick 才切换，那么“继承省了多少”会被 1 ms 的量化噪声淹没，实验就白做了。放锁时立刻切换，才能让等待时长精确落在“临界区剩下多少”上。

---

## 12.7 信号量：计数、顺序与直接交接

信号量只有一个计数器和一个等待链，没有所有者。它同时承担两种用途，而这两种用途完全不同：

| 用途      | 初值 | 语义                     | 本章用在哪                                       |
| --------- | ---- | ------------------------ | ------------------------------------------------ |
| 互斥      | 1    | “拿走唯一名额，用完还回” | **不用**（没有所有权就没有继承，反转只能靠运气） |
| 计数/顺序 | 0    | “某件事已经发生了 N 次”  | `s_locked`（先后约束）、`s_done`（汇合）         |

计数语义的关键性质：**没人等待时 `post` 会累加**。这让“先发生的事”不会丢——生产者可以先跑完再去消费者那边报到，消费者后到也能看到计数。

```zig
pub fn wait(s: *Semaphore) void {
    const old = sched.irqSave();
    if (s.count > 0) { s.count -= 1; sched.irqRestore(old); return; }
    s.blocks += 1;
    sched.blockOn(&s.waiters, s.name);   // post 那边会把名额直接交给我们
    sched.irqRestore(old);
}

pub fn post(s: *Semaphore) void {
    const old = sched.irqSave();
    s.posts += 1;
    if (sched.waitPopBest(&s.waiters)) |w| {
        sched.wake(w);                    // 直接交接：count 不加也不减
        sched.rescheduleIfNeeded();
    } else {
        s.count += 1;                     // 没人等才累加
        s.accumulated += 1;
    }
    sched.irqRestore(old);
}
```

注意 `post` 那条分支：有等待者时**不动计数器**。如果写成“`count += 1` 然后唤醒一个”，被唤醒者还要重新 `wait` 去抢那个名额，中间可能被第三个任务截胡——又是“醒来再抢”的老问题。

### 本章用它做两件不显眼但关键的事

1. **做先后约束**（`s_locked`，初值 0）：低优先级任务 L 拿到锁之后 `post` 一次，supervisor 才能继续创建中/高优先级任务。没有这一步，“高优先级先跑”会让高优先级任务直接拿到空锁，反转根本不发生——而日志看起来一切正常。**用信号量表达“我已经做完前一件事”，比用 `sleep` 猜时间可靠一个数量级。**

   但真机之后还要往前走一步：**等待必须由“生产者”驱动，不能由“时间”驱动。** 中间试过一版用 `sleepTicks(1)` 轮询的“有界等待”，结果 supervisor 在第一次 sleep 之后就再也没被唤醒——串口停在 spin 任务的两行 `done` 上，既没有 `phase begin`，也没有任何超时日志。结论是明确的：**在裸机内核里，把同步寄托在睡眠链上比把同步寄托在 post 上更脆**，因为睡眠链的正确性依赖 tick ISR 每一步都活着，而 post 是同步的、当场的、不依赖任何时基。

   所以现在的分工是：

   | 机制                                       | 谁驱动              | 用途                                    | 失败时的可见性                           |
   | ------------------------------------------ | ------------------- | --------------------------------------- | ---------------------------------------- |
   | `sem.wait`（阻塞）                         | **生产者**的 `post` | supervisor 推进阶段、加入口/退出汇合    | 立即（handoff 换栈，不依赖 tick）        |
   | `m.owner` 复核                             | 事实本身            | 确认“信号量说的事是真的”                | 打印 `WARN locked signal but owner=none` |
   | `monitor` 心跳（prio 6，`sleepTicks(50)`） | tick                | 打印 `tick/ready[8]/blocked/sleep` 快照 | 心跳停 ⇒ tick 或睡眠链断了               |

   `monitor` 是最后一道可观测性。它对应三种完全不同的故障形态，而这三种在串口上都表现为“不再输出”：

   | 现象                                 | 结论                                         |
   | ------------------------------------ | -------------------------------------------- |
   | 心跳**完全不出现**                   | tick ISR 死了，或睡眠链断了（谁都没被叫醒）  |
   | 心跳照走、`blocked=` 里有 supervisor | 阻塞/唤醒 bug（等一个不会再来的 post）       |
   | 心跳照走、`ready=[…]` 与预期不符     | 就绪链被写坏（任务 `.ready` 但不在任何链上） |

   为什么 idle 里的 STALL 不够：它只在“一个就绪任务都没有”时才可能打印；而就绪链被写坏、或某个 `waitPopBest`/`sleepTick` 在环上打转时，CPU 是 **100% 忙**的——idle 根本轮不到，STALL 永远不会出现，串口只剩静默。

   一句话：**通知可以丢，事实不会；而“静默”必须被专门设计成可区分。**

2. **做汇合**（`s_done`，初值 0）：三个任务各 `post` 一次，supervisor `wait` 三次。因为计数可以累积，post 早于 wait 也不会丢。

---

## 12.8 优先级反转与继承：完整时间线

先看没有继承时的形状。三个任务、一把锁：

| 任务 | 优先级 | 行为                                          |
| ---- | ------ | --------------------------------------------- |
| L    | 1      | 拿锁 → 抱着锁睡 30 tick → 补一段忙等 → 放锁   |
| M    | 3      | 纯 CPU 忙等 60 tick，**不碰锁**               |
| H    | 5      | 记录时刻 → 拿锁（被 L 挡住）→ 记录时刻 → 放锁 |

M 是反转的“插队者”。它不需要做任何坏事：**只要它在跑，prio 1 的 L 就拿不到 CPU**，于是 L 无法放锁，H 只能等。

```text
       L(1)      M(3)      H(5)                    内核状态
t≈0    拿锁 ──────────────────────────────────────  owner=L
       post(locked)
t≈0                       ┌─ t0 = ticks
                          └─ lock → blocked         H 挂进 m.waiters
t≈0               跑 ─────────────────────────────  pickNext → M（M > L）
t≈30              跑（L 想跑也跑不了）               严格优先级：M 一直赢
t≈60              done ────────────────────────────  M 退出就绪链
t≈60    sleep(30) ────────────────────────────────  L 这才开始睡
t≈90    burn → unlock ────────────────────────────  H 被唤醒
t≈90                      t1 = ticks
                          wait = t1 - t0 ≈ 90 tick  ← 反转的代价
```

### 继承怎么改这条时间线

H 在 `lock` 里发现持有者是 L，于是：

```zig
if (m.pi) {
    const o = m.owner.?;
    if (t.base_prio > o.prio) {          // 5 > 1
        sched.setPrio(o, t.base_prio);   // L: 1 → 5（摘链 + 重挂）
        m.boosts += 1;
        o.boosts += 1;
    }
}
```

抬到**请求者的 `base_prio`**，不是请求者的有效优先级。抬到有效值会把“别人已经给你抬过的高度”继续传播出去，两层嵌套时优先级会虚高。

```text
       L(1→5)             M(3)      H(5)              内核状态
t≈0    拿锁 ─────────────────────────────────────────  owner=L
t≈0                       ┌─ t0
                          └─ lock → 阻塞，L 变 5      H 挂进 waiters
t≈0    L 立刻被选中（5 > 3）─────────────────────────  pickNext → L
t≈0    sleep(30) ────────────────────────────────────  L 抱着锁睡（继承帮不上）
t≈0             跑 ──────────────────────────────────  睡眠期间 M 趁机跑
t≈30   tick 唤醒 L(5) → 抢占 M ─────────────────────  5 > 3，M 被换下
t≈30   burn → unlock ────────────────────────────────  handoff 给 H
t≈30                      t1 = ticks
                          wait ≈ 30 tick              ← 省掉的是 M 的剩余部分
```

### 三条必须写下来的边界

1. **继承只能救“持有者已就绪、但被中优先级挡住”的那一段。** L 在睡的时候不在就绪队列上，任何优先级都救不了它——所以阶段 B 的等待时间是 30 tick 而不是 0。这正好是那条铁律的量化版：**临界区里不要阻塞、不要睡眠、不要打印**。
2. **还原顺序不能反。** `unlock` 先把 `t.prio` 还原成 `base_prio`，再挑下一个等待者。反过来的话，`pickNext` 会看到一个还带着继承高度的旧持有者，算出错误的抢占关系。
3. **本工程只做单层继承。** 同一任务同时持有两把被等待的锁时，还原会低估它。要正确必须记录“我还被谁抬着”（每个 mutex 一条边，取最大值），那是 ch14 之后的事。

FreeRTOS 的两个函数就是这两步的名字：`xTaskPriorityInherit`（`components/freertos/FreeRTOS-Kernel/tasks.c:5041`）与 `xTaskPriorityDisinherit`（同文件 `:5141`）；IDF 默认打开 `configUSE_MUTEXES = 1`（`components/freertos/config/include/freertos/FreeRTOSConfig.h:104`）。也就是说，你在 `xSemaphoreTake(mutex)` 里感受到的“它怎么没被中优先级拖住”，背后就是这几十行。

---

## 12.9 实验设计：两阶段对照与 tick 量化

要证明“继承有效”，最弱的做法是打印一句“已启用继承”。本章的做法是**同构两遍、只改一个开关**：

| 项               | 阶段 A（`no-pi`）                 | 阶段 B（`pi`）         |
| ---------------- | --------------------------------- | ---------------------- |
| 互斥量           | `m_no_pi`（`pi = false`）         | `m_pi`（`pi = true`）  |
| 任务与优先级     | L(1) / M(3) / H(5)                | L(1) / M(3) / H(5)     |
| 任务体           | 完全相同                          | 完全相同               |
| 预期 `high_wait` | ≈ `med_busy + cs_sleep` = 90 tick | ≈ `cs_sleep` = 30 tick |

两个互斥量同时存在（而不是跑完 A 改个全局开关再跑 B），这样对照表里除了 `pi` 一位以外没有任何差异，也没法在“改开关”这个动作上引入时序噪声。

### 为什么用 tick 计数，而不是指令数或 GPIO

1. **主频不是本章的已知量。** S31 标称 320 MHz，但从“上电到 PLL 锁定到实际跑在多少”这条链在裸机形态 B 下还没闭环。用指令数换算成时间，等于把一个未验证的常数塞进实验结论。
2. **tick 计数器是硬件产生的。** `sched.tickCount()` 是 tick ISR 的命中次数，1 tick = 1 ms，不依赖任何软件时基。H 记录 `t0`/`t1` 两个时刻，差值就是“等了多少个 tick”。本章的计数器是 **u32 + volatile 读**，两条都不是随手写的：
   - 用 `u32` 而不是 `u64`：RV32 上 64 位读是两条 `lw`，ISR 若在两个半字之间更新，读到的是一个**从未存在过**的值；用 `now -% t0 < n` 比较时这种撕裂会让差值偏 2^32，把“等 60 个 tick”变成等 4294967 个 tick。u32 单条 `lw` 天然原子。
   - 经 `*volatile u32` 读：`busyTicks` 的形状是 `while (now - t0 < n) { asm volatile ("nop"); }`，而 `asm volatile` 声明不了“我读内存”，编译器完全有理由把 `tick_count` 的 load 当成循环不变式提到循环外——条件一旦不变，这个循环就是死循环，中优先级任务永远不 `post`，整章的主证据在真机上根本产不出来。

   顺带一条：本系列没有用 SYSTIMER 做第二时基，但如果要用，`HP_SYS_CLKRST + 0x120` 的 bit0（APB）与 bit4（计数器时钟）都必须置 1，否则读数恒 0（ch08 的结论）。

3. **量化误差是 1 tick（1 ms），而我们要区分的差是 60 tick。** 60 倍的余量，噪声压不倒结论。

代码里还留了一条自我否定的判据：

```zig
if (wait_ticks_no_pi > wait_ticks_pi) {
    sched.line("result: inheritance saved {d} tick (~{d} ms)", .{ ... });
} else {
    sched.line("result: UNEXPECTED - no inversion observed; check med_busy >= cs_sleep", .{});
}
```

如果真机上打出 `UNEXPECTED`，说明参数没把反转“撑”出来（最常见的原因：`med_busy` 太小，M 在 H 阻塞之前就跑完了），而不是继承没实现。**让代码自己否认自己的结论**，比在正文里写“预期有效”更值钱。

### 三个会让实验失效的坑

| 坑                               | 现象                                   | 处置                                                       |
| -------------------------------- | -------------------------------------- | ---------------------------------------------------------- |
| H 比 L 先拿到空锁                | 反转不发生，日志“看起来正常”           | 用 `s_locked` 信号量约束“L 已持锁”，不要用 sleep 猜        |
| `med_busy < cs_sleep + 启动开销` | 阶段 A 与 B 的等待时长接近，看不出差别 | 让 M 的忙等远大于 L 的睡眠（本章 60 vs 30）                |
| 任务体里自己调用 `yield`         | 中优先级会“礼貌地”让出，反转被人为抹平 | 演示任务里**不能有** `yield`；换栈只由 tick 与同步原语驱动 |

---

## 12.10 队列：环形缓冲与双向等待链

队列比信号量多一件事：它带数据。所以除了“有没有空位/有没有元素”，还要保证“取走的刚好是别人放进去的那个”，并且放/取两个方向各有一条等待链——本章唯一同时使用两条等待链的原语。

```text
    head          tail
     ↓             ↓
   [ 7 ][ - ][ 5 ][ 9 ]     容量 4，len = 3，high_water = 3
```

三条设计决定：

1. **`len` 是唯一权威**。不用 `head`/`tail` 推导“满还是空”——环绕之后，“head == tail”既可以表示空也可以表示满，靠 `len` 才能一眼分清。
2. **容量固定，满了阻塞生产者**。不丢数据、不覆盖旧数据。静默丢弃会让消费者永远等不到它以为存在的元素，比死锁更难查。
3. **`while` 而不是 `if`**：

```zig
while (q.len == capacity) {
    q.put_blocks += 1;
    sched.blockOn(&q.put_waiters, q.name);
}
```

被唤醒 ≠ 条件成立。名额可能在被选中后、真正运行前被另一个任务抢走（本章的唤醒是按优先级挑的，但抢占仍需时间）。用 `if` 的版本会在这种时序下写出数组越界或重复计数，而且只在特定交错下复现。

两个方向的唤醒是**各唤醒一个**：`put` 成功后唤醒一个等 `get` 的；`get` 成功后唤醒一个等 `put` 的。这里不需要“全部唤醒”——队列的进展是单调的（一个元素进来只让一个消费者有可能前进），广播只会制造惊群。

`high_water` 与 `put_blocks`/`get_blocks` 是这节的证据：

- `high_water == 4` 说明队列真的被填满过，生产者确实被阻塞过；
- `put_blocks > 0` 说明“满”这条路径被执行过；
- `get_blocks > 0` 说明“空”这条路径被执行过。

三个都是 0 也能说明问题：四个同优先级任务按 slice 轮转时，生产者与消费者可能恰好同步推进，队列永远不空也不满——那就得改参数（容量、item 数、slice）再测，而不是宣布“阻塞没实现”。

---

## 12.11 事件组：位是状态，唤醒全部再复核

事件组和信号量长得像，语义完全不同：

| 原语   | 语义                 | 唤醒策略               | 会丢失吗             |
| ------ | -------------------- | ---------------------- | -------------------- |
| 信号量 | 计数（发生了 N 次）  | 交给一个等待者         | 不丢：没人等就累加   |
| 事件组 | 状态（某些位已置位） | **全部唤醒**，各自复核 | 不丢：位一直留着     |
| 队列   | 数据（有 N 个元素）  | 交给一个等待者         | 不丢：元素留在队列里 |

`set` 把位或上去，然后唤醒所有等待者；等待者醒来重新求值谓词：

```zig
while (true) {
    const v = eg.bits;
    const ok = switch (mode) {
        .all => (v & mask) == mask,
        .any => (v & mask) != 0,
    };
    if (ok) { sched.irqRestore(old); return v; }
    eg.reblocks += 1;
    sched.blockOn(&eg.waiters, eg.name);
}
```

为什么内核不能“只唤醒可能满足的那个”：满不满足取决于**每个等待者自己的 mask 与 all/any 模式**。内核若替它算，就得把每个等待者的谓词存下来——那已经是在实现条件变量了。唤醒全部把这段逻辑留在等待者一侧，正确性最好论证。

代价是**惊群**：一次 `set` 可能让 10 个任务全醒一遍、检查一遍、9 个再睡回去。本章的 `reblocks` 计数器就是它的度量：

```text
events: all -> bits=0xf reblocks=<k>
```

本章用它做“四个任务都完成”的汇合点，而且两种模式都跑一遍：先 `any`（谁先完成都算），再 `all`（四个都到位才继续）。两种模式的差异在日志里就是两行 `bits=`。

`clear` 只清位、不唤醒任何人——清位只会让已经在等的任务多睡一会儿，这是“位是状态”的另一面：**置位是事件，清位不是**。

### 停滞诊断：让死锁自己说出来

死锁时最难的不是修，是**看见**。本章在 idle 循环里加了一条只打印一次的检查：

```zig
if (!stall_reported and !hasReady() and hasBlocked()) {
    reportStall();     // 打出每个 blocked 任务的 name / prio / wait_on / sleep_left
    stall_reported = true;
}
```

判据是“**没有任何就绪任务，却有任务在等**”——这时没人能让时间前进了。输出形如：

```text
sched: STALL - no ready task, blocked tasks follow (deadlock or lost wakeup)
  blocked: L1 prio=1 on="m-no-pi" sleep_left=0
```

`wait_on` 字段在这里兑现价值：它直接告出“在等谁”。如果没有它，日志只会停在最后一个打出来的任务上，而那个任务往往是无辜的。

---

## 12.12 工程走读

| 文件              | 职责                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------ |
| `src/context.zig` | 80B trap 帧、64B switch 帧、`trapEntry`、`switchRaw`、`taskStart`（沿用 ch10/ch11）  |
| `src/tick.zig`    | TIMG0 T0、矩阵[25]、CLIC 输入 16；本章**没有改** tick 的产生与投递路径               |
| `src/sched.zig`   | **本章核心**：TCB + blocked、等待链、`blockOn`/`wake`/`setPrio`、睡眠链、idle 独立栈 |
| `src/spin.zig`    | `lr.w`/`sc.w` 自旋锁（关中断 + CAS）、`amoswap`/`amoadd`、`fence`                    |
| `src/mutex.zig`   | 所有者、等待链、`pi` 开关、handoff、继承与还原                                       |
| `src/sem.zig`     | 计数信号量、直接交接、可累积                                                         |
| `src/queue.zig`   | 定长环形队列、双向等待链、`while` 重检查                                             |
| `src/events.zig`  | 32 位事件组、`all`/`any`、唤醒全部再复核                                             |
| `src/tasks.zig`   | 四个阶段的演示任务 + prio 7 的 supervisor                                            |
| `src/main.zig`    | banner/配置、建 supervisor、把 `main` 交给 idle                                      |
| `linker/s31.ld`   | `.app_desc` 最前、`.text.trap` 4 字节对齐、`.trap_ram` 进 SRAM、两段 flash 布局      |
| `tools/flash.sh`  | 读 `flash_args`、替换 0x10000 应用行、一次烧三样                                     |

完整源码可站内浏览（不离开本站看高亮版本）。下面的链接指向 code-site 的产物路径，**需要先重跑一次 `npm run code-site` 才会收录本章的文件**；在那之前它们只会落到 index 页：

| 文件             | 代码浏览                                                                     |
| ---------------- | ---------------------------------------------------------------------------- |
| `src/sched.zig`  | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/sched.zig)  |
| `src/spin.zig`   | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/spin.zig)   |
| `src/mutex.zig`  | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/mutex.zig)  |
| `src/sem.zig`    | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/sem.zig)    |
| `src/queue.zig`  | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/queue.zig)  |
| `src/events.zig` | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/events.zig) |
| `src/tasks.zig`  | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/tasks.zig)  |
| `src/main.zig`   | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/main.zig)   |

### 启动顺序

```text
_start：MIE=0、mie=0 → sp/gp → 关 RTC WDT → 清 .bss → mtvec=trapEntry → call main
  main：banner/帧长/tick 配置 → create(sup, prio 7) → tick.init(1000) → sched.start()
    start：在 idle_stack 上构造首帧 → switchTo → taskStart（开 MIE）→ idleLoop
      idleLoop：tick.enable() → yield 循环（等 sup 跑完）
        sup：阶段 0 → 阶段 A → 阶段 B → 阶段 C → 打印结论 → done
          （全部 done）→ idle 打印统计 → tick.disable() → wfi
```

三个顺序不可交换：

1. **`tick.init` 在 `MIE = 1` 之前**（ch11 已有约束）；
2. **`mtvec` 在 `MIE = 1` 之前**（ch11 已有约束）；
3. **本章新增：切到 idle 的栈在 `MIE = 1` 之前**。反过来的话，`tick.enable()` 之后、`switchTo` 之前来一次 tick，`schedule` 会把 `main` 的 sp 写进 `idle_task.sp`，把刚构造好的 idle 帧冲掉——这正是 ch11 真机崩溃的形状（见 12.13）。

### 开中断不是一条指令的事：四道开关

真要收到一个 tick，必须四道全开，任何一道为 0 的现象都一样（**一片安静，`ticks` 不涨**）：

| 层次           | 位置                                                   | 谁打开                        |
| -------------- | ------------------------------------------------------ | ----------------------------- |
| TIMG 侧门闩    | `INT_ENA_TIMERS(+0x70).bit0`（复位 0）                 | `tick.init`                   |
| 中断矩阵       | `0x20585000 + 4×25` 的 `MAP[5:0] = 16`                 | `tick.init`                   |
| CLIC 输入      | `0x10801000 + 4×16` 的 `IE`(bit8)、`CTL[31:24]` 优先级 | `tick.init`                   |
| **`mie.MEIE`** | `mie` bit 11                                           | `tick.enable()`               |
| `mstatus.MIE`  | bit 3                                                  | `taskStart` / `tick.enable()` |

第四行最容易漏：`_start` 做了 `csrw mie, zero`（图省事把整张 `mie` 表清空），而 CLIC 的输入 16..47 属于“外部中断”类，**不重新置上 `MEIE` 就永远不会投递**。本工程在 `tick.enable()` 里显式补回：

```zig
asm volatile ("li t0, 0x800\n\tcsrs mie, t0");   // mie.MEIE = bit 11
asm volatile ("csrsi mstatus, 0x8");             // mstatus.MIE
```

真机上这条的症状极具欺骗性：`tick.init` 的所有配置读回都对，`INT_RAW` 也在寄存器里照常置位，但串口就是安静——因为中断在“矩阵 → CLIC → CPU”的最后一段被 `mie` 挡住了。

### 任务图

```text
prio 7  sup ──┬─ 阶段0: spinA(2) spinB(2) ──────────── sem.post(done)×2
              ├─ 阶段A: L1(1) M1(3) H1(5) ── m_no_pi ── sem.post(done)×3
              ├─ 阶段B: L2(1) M2(3) H2(5) ── m_pi    ── sem.post(done)×3
              └─ 阶段C: P1(2) P2(2) C1(2) C2(2) ── q + eg ── eg.set(位)×4
prio 0  idle（独立 4096B 栈）：yield 循环 + 停滞诊断 + 终态 wfi
```

13 个任务（含 supervisor）全部在 `.bss` 里静态分配：`max_tasks = 16`，每个任务一块
3072 字节的独占栈，idle 单独 4096 字节，supervisor 4096 字节。**没有任何一次堆分配。**

---

## 12.13 验收与证据口径

### ch11 真机留下的三条记录，本章的处理

| 现象                                                                                        | 根因                                                            | 本章处置                                                                                                  |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 全部任务结束后切回 idle，`instruction access fault`（`ra` 指向 0x2f07af18 栈地址）          | ch11 的 idle 复用了 `main` 的 `_stack_top`，帧被覆盖            | idle 独占 `idle_stack[4096]`；`start()` 先换栈再开 MIE                                                    |
| 已 `done` 的任务又打出几行 / 继续跑                                                         | 时间片到期重新入队发生在置 `done` 之前，`pickNext` 直接返回队首 | `pickNext` 出队后检查状态，`done` 的直接丢弃                                                              |
| 同为 prio 1 的 `loA` 被 tick 抢占后长时间不再产出（`loB` 能跑完），第三次切回时出现二次故障 | **未闭环**                                                      | 本章沿用同一套 `switchRaw`/trap 帧，因此“tick 抢占下被换出任务的现场恢复”**仍需真机复核**，不得标成已验证 |

第三条必须原样留在文里。它不影响本章的同步原语逻辑（本章的阶段任务不在同优先级上轮转竞争），但它意味着“tick 抢占 + 换栈”这条路径本身还没有被完整验证——任何把它写成“已验证”的表述都是假的。

### 真机记录（2026-11-13，主 agent 上板）

阶段 A 的实测与 12.8 的推演逐项吻合（这里只摘关键行）：

```text
spin: locked=1000 atomic=1000 expected=1000 acq=1000 lr_sc_retries=0
M1: done steps=1 prio=3/3 boosts=0 ticks=60
sched: STALL - no ready task, blocked tasks follow (deadlock or lost wakeup)
  blocked: sup prio=7 on="done" sleep_left=0
  blocked: L1 prio=1 on="sleep" sleep_left=27
  blocked: H1 prio=5 on="m-no-pi" sleep_left=0
H1: done steps=1 prio=5/5 boosts=0 ticks=0
L1: done steps=2 prio=1/1 boosts=0 ticks=0
phase no-pi: high_wait=90 ticks boosts=0 span=90 ticks
```

三个结论，两个是好消息、一个是 bug：

1. **`high_wait=90` 与 12.8 的预测（`med_busy + cs_sleep` = 60 + 30）完全一致。** 反转、tick 量化、`sleepTicks` 的睡眠链、handoff 唤醒，四条链路在真机上同时成立。
2. 但是这条 `STALL` 是**误报**：当时 L1 正在 `sleep`（`sleep_left=27`），睡眠本身就是合法的唤醒源。原判据只看了“没有就绪任务 + 有任务在等”，漏了“还有人在睡”。已修：判据加上 `sleep_head == null`，并且允许复报（最多 3 次、出现就绪任务即解锁），避免第二次死锁被“已经报过”永久静音。
3. **`phase no-pi` 之后 50 s 无输出**：`pi` 阶段没有开始。原因是 supervisor 用**阻塞式** `sem.wait(&s_locked)` / `sem.wait(&s_done)` 推进阶段，一旦某次 post 与 wait 的配对出错，它就永远停在 `blocked`——没有 trap、没有再报 STALL、只有不再变化的那一行。修法见 12.7 末尾：改成 `waitOwner` + `waitBounded` 两个有上界轮询，并把阶段内的每一步都打印出来（`phase pi: begin` → `holds` → `M/H created` → `done=n/3`）。

**第二轮上板（同日）：把等待改成 `sleepTicks(1)` 轮询后出现回归**

```text
spinB: done steps=500 prio=2/2 boosts=0 ticks=0
spinA: done steps=500 prio=2/2 boosts=0 ticks=1
（之后无输出，也没有 STALL）
```

supervisor 连 `phase ... begin` 都没打出来：它在第一次 `sleepTicks(1)` 之后就没有再被唤醒，而 `sleep_head != null` 又让 STALL 判据保持沉默。修法三条，全部落在“让失败可区分、让等待由生产者驱动”上：

1. **等待回到 handoff**：supervisor 的阶段推进改回阻塞 `sem.wait`——由 `post` 当场换栈唤醒，不依赖 tick。`m.owner` 只做一次复核。
2. **给两条链都加不变量与上限**：TCB 增加 `sleeping` 标志，`sleepTicks` 拒绝重复入链（重复入链会让睡眠链**成环**，而 `sleepTick` 在 ISR 里遍历它——成环等于冻住整个 tick）；`sleepTick`/`sleepRemove`/`waitPopBest` 全部加 `max_tasks` 上限，环也只会走 16 步就退出。
3. **加 prio 6 的 `monitor` 心跳**：每 50 tick 打印 `tick/cur/ready[0..7]/blocked/sleep` 快照，用来区分“tick 死了”“有人永久阻塞”“就绪链被写坏”这三种同样表现为静默的故障。
4. **心跳与 banner 里补了中断侧寄存器**：`mtvec` 那行现在连 `mtvt`（CSR `0x307`）与 `mie` 一起打印，心跳行尾带 `mie=0x… mst=0x…`。原因是上板日志里出现过一条必须解释的读数：

   ```text
   mtvec: base=0x2f000000 mode=3
   ```

   本章 `_start` 写的是 `csrw mtvec, trapEntry`，而 `trapEntry` 4 字节对齐，软件**只可能**写进 `mode=0`。读到 `mode=3` 只有两种解释：S31 的 CLIC 把 MODE 位固定成 3（硬件行为，`BASE` 仍是单一入口），或者 `mtvec` 被别处改写、中断改走 `mtvt` 向量表。这两者的现象天差地别——后者会让 tick 彻底不投递。一句 `mode=3` 分不清，所以把 `mtvt` 一起打出来：`mtvt=0` 说明没有向量表、单一入口仍有效；`mtvt≠0` 就必须回去查是谁写的。

> [!warning] 这一节是待验证状态
> 上面第 1 条是实测；第 2、3 条是**修法**，尚未重新上板。下一次串口应当出现 `phase pi: begin` / `holds m-pi` / `high_wait≈30` 三行，以及 `result: inheritance saved 60 tick`。若出现 `WARN done timeout`，说明仍有信号丢失，日志会指出是哪个阶段、第几个 post。

### 验收目标

1. 串口出现 banner、`frames: trap=80 switch=64`、`pool: max_tasks=16 ... idle_stack=4096B own stack`；
2. `spin: locked=1000 atomic=1000 expected=1000 acq=1000 lr_sc_retries=0`——**三个 1000 必须相等**；
3. `phase no-pi: high_wait=<A> ticks boosts=0`、`phase pi: high_wait=<B> ticks boosts=1`——`boosts` 是继承发生的直接证据；
4. **判据是 `A − B ≈ med_busy`（≈ 60 tick），不是绝对值。** 绝对量与有没有额外打印强相关：一句 ~90 字符的 `line()` 走 UART0，在 115200 下是 **~8 ms**，只要 TX FIFO 满就会阻塞——也就是**最多 8 个 tick**，远超 tick 量化的 ±1。所以加了 `monitor` 心跳之后，预期读数会变成 `A ≈ 97`、`B ≈ 37`（各自吸收同样的打印开销），差值仍是 60。把 `97 ≠ 90` 读成新回归是误判；
5. `result: inheritance saved <A-B> tick` 出现（而不是 `UNEXPECTED`）；
6. `queue: puts=12 gets=12`、`bad=0`、`high_water ≥ 2`；
7. `events: all -> bits=0xf`；
8. `sched: all tasks done ticks=<n> switches=<m> blocks=<b>` 之后停在 `wfi`，不复现 `instruction access fault`；
9. 连续复位 10 次，阶段 B 的 `high_wait` 稳定在 ±1 tick。

**能验收的是关系（`A > B`、三个 1000 相等、`bad=0`），不是具体数字。** 具体数字必须来自真机，本仓不预填。

`blocks=` 这个总数也值得看：它是所有 `blockOn` 的累计次数，正常应在几十到几百之间。如果它异常大（几千），说明某个原语在反复唤醒又睡回去——那是惊群或“醒来再抢”的味道。

### 构建与镜像自检

```bash
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
esptool --chip esp32s31 image-info zig-out/bin/app.bin

# 段布局：必须正好两行 DROM, IROM（0x40000020 / 0x40020020）
riscv32-esp-elf-objdump -d zig-out/bin/app.elf | grep -cE 'lr\.w|sc\.w|amoadd|amoswap'
grep -n "requeue" src/sched.zig          # 确认 blockOn 传的是 false
grep -n "state == .done" src/sched.zig   # 确认 pickNext 丢弃 done
bash -n tools/flash.sh
```

`objdump | grep -c` 应 ≥ 3（`lr.w`、`sc.w`、`amoadd.w.aq` 各至少一处，`fence` 另算）。**如果没有原子指令**，说明 `-Dcpu` 少了 `+a`，或者汇编根本没被发射——后者会让“原子性”变成一句空话。

---

## 12.14 排错

| 现象                                           | 根因                                                        | 处置                                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 串口停在 banner，什么都不动                    | supervisor 第一次 `sem.wait` 就阻塞，而 L 没被创建/没被调度 | 检查 `create` 的 `entry` 是否 `pub fn` 且已 `@intFromPtr`                            |
| `sched: STALL - no ready task`                 | 死锁或丢失唤醒                                              | 看紧跟其后的 `blocked:` 行：`on="<对象>"` 直接指出在等谁                             |
| `phase no-pi: high_wait=0`                     | H 先于 L 拿到空锁                                           | 确认 `runPhase` 里 `waitOwner` 返回 true（L 真的持锁），且 L 在 `lock` 之后才 `post` |
| 两阶段 `high_wait` 几乎相等                    | `med_busy` 不够大，或 M 任务里自己 `yield` 了               | `med_busy` 拉到 `2 × (cs_sleep + ε)`；演示任务里禁止 `yield`                         |
| `boosts=0`（阶段 B 也是 0）                    | `m_pi.pi` 为 false；或 `t.base_prio > o.prio` 判断反了      | `mutex.init(name, true)`；优先级数值越大越优先                                       |
| `high_wait` 比 `med_busy + cs_sleep` 大很多    | 唤醒后没有立刻抢占，白等了一个 tick 或多个                  | 确认 `unlock` 末尾调用了 `rescheduleIfNeeded()`                                      |
| 继承后 `used` 优先级没降回去，任务一直霸占 CPU | `unlock` 忘了还原，或还原顺序在 `pickNext` 之后             | 先 `setPrio(t, t.base_prio)`，再挑等待者                                             |
| `queue: bad>0`                                 | 环形下标与 `len` 不同步（多半是 `if` 而不是 `while`）       | 检查 `put`/`get` 的条件等待都是 `while`                                              |
| `spin: giveups>0`                              | 关着中断等一把不会释放的锁                                  | 检查是否有任务在临界区里阻塞/睡眠                                                    |
| `sched: all tasks done` 后立刻复位             | idle 退出后回到 `_start` 的返回路径，或 idle 栈被复用       | idle 独立栈 + `noreturn` 循环 + 统计后停在 `wfi`                                     |
| `instruction access fault`（`ra` 指向栈地址）  | 任务栈被复用/覆盖                                           | 每任务独占栈；`idle_stack` 不能是 `main` 的 `_stack_top`                             |
| 已 `done` 的任务又打出几行                     | `pickNext` 返回了 `done` 的队首                             | `pickNext` 出队后 `if (t.state == .done) continue;`                                  |
| `trap: unexpected cause=0x...`                 | 进了非预期中断或同步异常                                    | 最高位为 1 时低 6 位是 CLIC 输入号；否则看 `cause & 0x1F` 的异常码                   |
| `mtvec` 读回 `mode=3`                          | CLIC 把 MODE 固定为 3，或 `mtvec` 被别处改写                | 看同一行的 `mtvt`：为 0 则单一入口仍有效；非 0 说明中断改走向量表，tick 会完全不投递 |

---

## 12.15 下一章预告

本章所有原语都建立在一个隐藏假设上：**内存足够，且栈不会溢出**。队列是定长数组，TCB 池是定长数组，任务栈是 3072 字节的固定数组——一旦溢出，踩到的是隔壁任务的栈帧，现象可能是“某个无关任务突然跑飞”，也可能是本章刚修好的 `instruction access fault` 重现。

下一章处理堆、栈保护与内存能力：TLSF/slab 分配器、对齐与 `IRAM/DRAM caps`、栈哨兵与溢出检测、PSRAM 分配器，以及一张能在 µs 级别说清“谁在什么时候拿了多少”的内存预算表。届时本章的“零分配”会变成一种**可选的严格模式**，而不是唯一做法。

---

## 事实来源

| 事实                                                                                                | 来源                                                                                                                               | 备注                                                        |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `lr.w` 建立 reservation、`sc.w` 仅在其有效时写入，失败必须重读                                      | RISC-V 非特权规范 v2.2 第 8 章 “A” 扩展                                                                                            | 本章 `tryCas` 的循环形状                                    |
| IDF 的 CAS 就是 `lr.w`/`sc.w` 循环；无 A 扩展时退化为关中断 + 普通读写                              | IDF v6.1 `components/riscv/include/riscv/rv_utils.h:513`（`#if __riscv_atomic` 在 :515）                                           | 说明单核上两者是同一件事的两种写法                          |
| `spinlock_acquire` 先抬高中断级别、再 CAS                                                           | IDF v6.1 `components/esp_hw_support/include/spinlock.h:74`                                                                         | `rv_utils_set_intlevel_regval(RVHAL_EXCM_LEVEL_CLIC)`       |
| `esp_cpu_compare_and_set` 在 RISC-V 上落到 `rv_utils_compare_and_set`                               | IDF v6.1 `components/esp_hw_support/cpu.c:196`                                                                                     |                                                             |
| `SOC_CPU_CORES_NUM = 2`                                                                             | IDF v6.1 `components/soc/esp32s31/include/soc/soc_caps.h:175`                                                                      | 自旋锁的真战场是双核（ch14）                                |
| `.aq`/`.rl` 后缀提供 acquire/release 语义；`fence rw, rw` 为全序屏障                                | RISC-V 非特权规范 v2.2 “A” 扩展                                                                                                    | 本章原子指令均带 `.aq`                                      |
| `mstatus.MIE` 在 bit 3；`mie.MEIE` 在 bit 11                                                        | RISC-V 特权规范                                                                                                                    | `_start` 清了 `mie`，CLIC 输入要重新打开 MEIE               |
| 优先级继承 = 持有者抬到请求者的基础优先级，放锁时还原                                               | FreeRTOS `xTaskPriorityInherit` / `xTaskPriorityDisinherit`，IDF v6.1 `components/freertos/FreeRTOS-Kernel/tasks.c:5041` / `:5141` | 本章用 `base_prio` / `prio` 两个字段复刻                    |
| IDF 默认启用互斥量与递归互斥量                                                                      | IDF v6.1 `components/freertos/config/include/freertos/FreeRTOSConfig.h:104`                                                        | `configUSE_MUTEXES = 1`                                     |
| TIMG0 `0x20580000`、矩阵 `0x20585000 + 4×源`、CLIC `0x10800000`                                     | IDF v6.1 `reg_base.h` / `interrupt_core0_reg.h` / `clic_reg.h`                                                                     | 与 ch07/ch11 同一张表，本章未改动                           |
| tick = 源 25 → 矩阵[25]=16 → CLIC 输入 16；`mcause = 0x80000010`                                    | ch11 结论 + 本板实测（2026-11-12）                                                                                                 | 本章沿用，未复验                                            |
| `mcause` 高位带 0x38/0x7f 一类脏位，异常码只在低位（ecall = `0x3800000b`、非法指令 = `0x30000002`） | 本板实测（2026-11-12）                                                                                                             | `trapDispatch` 先取 `cause & 0x3F` 再比 11，并兼容 5 位读法 |
| callee-saved = `sp`+`s0`–`s11`；switch 帧 64B、trap 帧 80B                                          | RISC-V psABI（ILP32）+ ch10 结论                                                                                                   | 阻塞/唤醒不改变帧布局                                       |
| idle 复用 `main` 栈导致 `instruction access fault`（`ra`→栈地址）                                   | ch11 板级验证记录（2026-11-11）                                                                                                    | 本章改为 idle 独占 4096B 栈                                 |
| `pickNext` 返回 `done` 任务导致“死任务复活”                                                         | ch11 板级验证记录（2026-11-11）                                                                                                    | 本章出队后丢弃 `done`                                       |
| 同 prio 任务被 tick 抢占后长时间不产出                                                              | ch11 板级验证记录（2026-11-11），**未闭环**                                                                                        | 本章沿用同一帧布局，仍需真机复核                            |

## 自查清单

- [ ] ch11 的三个状态为什么不够？“等”多出来的两个信息是什么？
- [ ] `lr.w`/`sc.w` 里 `sc.w` 失败意味着什么？为什么必须回到 `lr.w` 而不是重写？
- [ ] 为什么 `tryCas` 的输出约束必须带 `=&`（early clobber）？
- [ ] `amoadd.w` 与 `lr/sc` 的表达力差在哪？为什么不都用 CAS 循环？
- [ ] 单核上只用自旋锁（不关中断）会怎样？画出死锁的时间线。
- [ ] `irqSave` 为什么返回旧 `mstatus`、`irqRestore` 为什么整字写回？
- [ ] 临界区为什么要包住 `switchRaw` 保存 sp 这一步？窗口有多长？
- [ ] `blockOn` 为什么必须传 `requeue = false`？违反“一个任务只在一条链上”会怎样？
- [ ] 丢失唤醒的窗口在哪三行之间？为什么 `wake` 要检查 `state != .blocked`？
- [ ] 等待链为什么按有效优先级挑，而不是严格 FIFO？
- [ ] handoff 相比“醒来再抢”解决了什么？代价是什么？
- [ ] 优先级继承为什么抬到请求者的 `base_prio` 而不是 `prio`？
- [ ] `unlock` 里“还原自己优先级”和“挑下一个等待者”的顺序为什么不能反？
- [ ] 继承为什么救不了“抱着锁睡觉”的那一段？这条对临界区设计意味着什么？
- [ ] 为什么实验用 tick 计数而不是指令数或 GPIO？量化误差与要区分的差各是多少？
- [ ] 队列的 `put`/`get` 为什么必须用 `while` 重检查？用 `if` 会在什么交错下出错？
- [ ] 事件组为什么“唤醒全部再复核”，而不是唤醒某个“应该满足”的任务？代价是什么？
- [ ] 停滞诊断的判据是什么？它为什么必须在 idle 里做？
- [ ] ch11 的 idle 栈被覆盖为什么会导致 `instruction access fault`？本章的两条修复是什么？
- [ ] 为什么 `asm volatile` 不是编译器屏障？严格写法用什么？

---

本章的产出是**一个会等的调度器**：blocked 状态、等待链、睡眠链，以及在它之上长出来的五种原语；同时把“优先级反转”从一个术语变成了两行可对照的 tick 数（`no_pi` 与 `pi`，由代码自己判断差值方向）。下一章处理所有这一切的地基：堆、栈保护与内存能力。

系列导航：[[ch11-preemptive-scheduler-tcb-tick|上一章]] · [[zig-esp32-s31|系列索引]]
