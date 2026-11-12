# ch12 同步原语与 IPC：让任务学会等待、互斥与交接

> 所属章节：[[ch12-sync-primitives-ipc|第十二章：同步原语与 IPC]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
> 本工程**部分实测（2026-11-13）**：spin（`locked=1000/atomic=1000`）与 no-pi 阶段
> （`phase no-pi: high_wait=90 ticks boosts=0 span=99 ticks`）通过，原始输出见 `../logs/ch12-boot.log`；
> **pi 阶段仍挂起**。其余日志、tick 数、`wait_ticks` 仍是验收目标。

## 目的

这是形态 B 的第七个工程，骨架沿用 `ch11-preemptive-scheduler`：Zig 自己产 ELF、
`linker/s31.ld` 决定段布局、`_start` 是入口、应用镜像由 `esptool elf2image` 生成，
IDF 只负责二级 bootloader 与分区表（`idf-bootstrap/`）。

在不变的骨架上，本章给调度器补上 **blocked 状态**，然后在这个状态上实现五种同步原语：

| 原语             | 文件             | 等待对象       | 唤醒策略               | 本章用它证明什么                          |
| ---------------- | ---------------- | -------------- | ---------------------- | ----------------------------------------- |
| 关中断临界区     | `src/sched.zig`  | ——             | ——                     | 单核上唯一无条件正确的互斥手段            |
| 自旋锁（A 扩展） | `src/spin.zig`   | 一个 32 位锁字 | 轮询 `lr.w`/`sc.w`     | 原子读改写；单核上必须与关中断配对        |
| 计数信号量       | `src/sem.zig`    | 名额           | 交给有效优先级最高者   | “已发生 N 次”可累积；用它做先后约束与汇合 |
| 互斥量 + 继承    | `src/mutex.zig`  | 所有权         | handoff 给最该跑者     | 优先级反转的复现与修复                    |
| 队列             | `src/queue.zig`  | 空位 / 元素    | 双向等待链，各唤醒一个 | 生产者/消费者；满与空两个方向的阻塞       |
| 事件组           | `src/events.zig` | 位掩码         | 唤醒全部、各自复核     | 位是状态而不是计数；惊群的代价            |

### 四个可判读的阶段

`src/tasks.zig` 由 prio 7 的 `supervisor` 串起四个阶段，每个阶段都打印可核对的数字：

| 阶段 | 任务                        | 打印                                                   |
| ---- | --------------------------- | ------------------------------------------------------ |
| 0    | `spinA`/`spinB`（prio 2×2） | `spin: locked=<n> atomic=<n> expected=<n> acq=<n> ...` |
| A    | `L1`(1)/`M1`(3)/`H1`(5)     | `phase no-pi: high_wait=<n> ticks boosts=0`            |
| B    | `L2`(1)/`M2`(3)/`H2`(5)     | `phase pi: high_wait=<n> ticks boosts=1`               |
| C    | `P1`/`P2`/`C1`/`C2`（2×4）  | `queue: puts=<n> gets=<n> high_water=<n>/4 ...`        |

验收的核心是一条不等式：**阶段 A 的 `high_wait` 必须显著大于阶段 B 的 `high_wait`**。
A 里中优先级任务把持有者压在 CPU 之外，B 里继承把持有者抬到与等待者同高、中优先级插不进来。

### 工程不做的事

- **不实现超时**：`blockOn` 没有 deadline，`sleepTicks` 是独立路径（睡眠链），
  没有“等锁最多等 N tick”的组合。真实内核用统一的时间轮。
- **不做嵌套优先级继承**：`unlock` 时把 `prio` 还原成 `base_prio`，
  若同一任务同时持有两把被等待的锁，还原会低估它。单层够本章用，正文写明了边界。
- **不做 SMP**：只用 core0；自旋锁在此没有真竞争（双核留给 ch14）。
  因此 `lr_sc_retries` 在真机上预期恒为 0——这本身是要打印出来的证据。
- **不分配内存**：TCB 池、栈、队列缓冲全是 `.bss` 静态对象。
- **不跑浮点**：`-Dcpu` 里的 `f` 只影响指令集与 ABI；FP 变体帧（208 字节）见 ch11。

## 本章修掉的两个 ch11 真机缺陷

这两条来自 ch11 的板级验证记录，本章的基线里已经带上修复：

1. **idle 必须有独立栈。** ch11 让 idle 复用 `main` 的 `_stack_top`；全部任务结束后
   切回 idle 时，`switchRaw` 从被覆盖的帧里恢复 `ra`，跳到 0x2f07af18（栈地址），
   报 `instruction access fault`。本章的 `sched.zig` 给 idle 一块
   `var idle_stack: [4096]u8 align(16)`，`start()` 先换到这块栈、再打开 `MIE`。
2. **`pickNext` 必须丢弃 `done` 任务。** ch11 里任务可能在时间片到期时被重新入队、
   之后才被标成 `done`，`pickNext` 直接返回队首就会“复活”已结束的任务。
   本章的 `pickNext` 出队后检查状态，`done` 的直接丢弃。

另有一条**未闭环**的现象必须留在明面上：ch11 真机上同为 prio 1 的 `loA` 被 tick
抢占后长时间不再产出（`loB` 能跑完）。本章沿用同一套 `switchRaw`/trap 帧，
因此“tick 抢占下的现场恢复”仍然**待真机复核**，不能写成已验证。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 只需串口。本章不新增外部接线，不需要示波器                      |

## 寄存器 / 指令速查

| 项                    | 值 / 位置                                  | 说明                                                      |
| --------------------- | ------------------------------------------ | --------------------------------------------------------- |
| `mstatus.MIE`         | bit 3                                      | `csrci mstatus, 8` 关、`csrsi mstatus, 8` 开              |
| `mie.MEIE`            | bit 11                                     | `_start` 清了 `mie`，CLIC 输入要重新打开这一位            |
| `lr.w rd, (rs1)`      | A 扩展                                     | 独占读，建立 reservation；不需要事先加锁                  |
| `sc.w rd, rs2, (rs1)` | A 扩展                                     | 只有 reservation 仍在时才写；`rd != 0` 表示失败，必须重读 |
| `amoswap.w.aq`        | A 扩展                                     | 原子交换，交换值不需要重试                                |
| `amoadd.w.aq`         | A 扩展                                     | 原子加并返回旧值，计数器首选                              |
| `fence rw, rw`        | 基座 I                                     | 阻止前后普通访存重排                                      |
| `mcause`（ecall）     | `0x3800000b`（本板实测）                   | 高位带 CLIC 字段，异常码只在低 5 位                       |
| `mcause`（tick）      | `0x80000010`                               | 最高位 = 中断，低 6 位 = CLIC 输入号 16                   |
| TIMG0 / 矩阵 / CLIC   | `0x20580000` / `0x20585000` / `0x10800000` | 与 ch11 完全一致，本章没有改 tick 的产生与投递路径        |
| trap 帧 / switch 帧   | 80 字节 / 64 字节                          | 与 ch10/ch11 一致；阻塞与唤醒不改变帧布局                 |

## 文件表

| 路径                               | 角色                                                                                         | 代码浏览                                                                                       |
| ---------------------------------- | -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `build.zig`                        | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                                         | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/build.zig)                        |
| `linker/s31.ld`                    | `ENTRY(_start)`、`.app_desc` 最前、`.text.trap` 4 字节对齐、`.trap_ram` 进 SRAM              | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/linker/s31.ld)                    |
| `src/start.zig`                    | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → sp/gp → 关 RWDT → 清 `.bss` → `mtvec` | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/start.zig)                    |
| `src/context.zig`                  | 帧布局、`trapEntry`、`switchRaw`、`taskStart`（开 MIE）、`initTaskStack`                     | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/context.zig)                  |
| `src/tick.zig`                     | TIMG0 T0、矩阵[25]、CLIC 输入 16；本章未修改 tick 链路                                       | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/tick.zig)                     |
| `src/sched.zig`                    | **本章核心**：TCB + blocked、等待链、`blockOn`/`wake`/`setPrio`、睡眠链、idle 独立栈         | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/sched.zig)                    |
| `src/spin.zig`                     | `lr.w`/`sc.w` 自旋锁（关中断 + CAS）、`amoswap`/`amoadd`、`fence`                            | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/spin.zig)                     |
| `src/mutex.zig`                    | 互斥量：所有者、等待链、`pi` 开关、handoff、继承与还原                                       | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/mutex.zig)                    |
| `src/sem.zig`                      | 计数信号量：直接交接、可累积                                                                 | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/sem.zig)                      |
| `src/queue.zig`                    | 定长环形队列：`len` 为权威、双向等待链、`while` 重检查                                       | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/queue.zig)                    |
| `src/events.zig`                   | 事件组：32 位、`all`/`any`、唤醒全部再复核                                                   | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/events.zig)                   |
| `src/tasks.zig`                    | 四个阶段的演示任务 + prio 7 supervisor                                                       | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/tasks.zig)                    |
| `src/main.zig`                     | banner/配置、建 supervisor、把 `main` 交给 idle                                              | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/src/main.zig)                     |
| `idf-bootstrap/CMakeLists.txt`     | 最小 IDF 工程根：只为产出 bootloader 与分区表                                                | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/idf-bootstrap/CMakeLists.txt)     |
| `idf-bootstrap/main/*`             | 空 `app_main`，让 IDF 构建走完                                                               | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/idf-bootstrap/main/app_main.c)    |
| `idf-bootstrap/sdkconfig.defaults` | 16 MB Flash + single-app-large（factory 在 `0x10000`），不启用 PSRAM                         | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/idf-bootstrap/sdkconfig.defaults) |
| `tools/flash.sh`                   | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                               | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/tools/flash.sh)                   |
| `README.md`                        | 本文件                                                                                       | [查看](/static/code/#/zig-esp32-s31/ch12-sync-primitives-ipc/README.md)                        |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置
single-app-large）、没有 `components/`、没有 `run.log`（真机未跑）。
生成物 `zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 都不入库。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh
zig version   # 必须 0.17.x
```

`-Dcpu` 里的 `+a` 不是可选的：本工程的内联汇编里有 `lr.w`/`sc.w`/`amoadd.w`，
没有 A 扩展时汇编器会直接拒绝。

## 构建

### 1. 应用 ELF（纯 Zig，无 idf.py）

```bash
cd practice/zig-esp32-s31/ch12-sync-primitives-ipc

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

### 2. 应用镜像（必须看到两个 flash 段）

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`image-info` 的 Segments 表里必须正好有两行 `DROM, IROM`：
`0x40000020`（.flash.text）与 `0x40020020`（.flash.rodata）。
S31 的二级 bootloader 在 `SOC_MMU_DI_VADDR_SHARED=1` 下断言 `rom_index == 2`，
少一个或三个段都会 `Assert failed`。

### 3. bootloader 与分区表（供应商步骤）

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

产物：`idf-bootstrap/build/bootloader/bootloader.bin`、
`idf-bootstrap/build/partition_table/partition-table.bin`、`idf-bootstrap/build/flash_args`。

### 4. 烧录

```bash
sh tools/flash.sh /dev/ttyUSB0     # Linux
```

脚本读 `flash_args`，保留 `--flash_mode`/`--flash_freq`/`--flash_size` 与
bootloader、partition-table 两行（偏移一律不手抄），把 `0x10000` 那一行替换成
`app.bin` 的绝对路径，再 `cd` 到该 build 目录执行 esptool。脚本不调用 `idf.py`。

## 运行

串口 115200 8N1 打开 UART0（GPIO58/59）。下面是**目标形态**（验收目标，不是实测日志）：

```text
ch12-sync-primitives-ipc | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
mtvec: base=0x4000xxxx mode=0 (0 = direct)
frames: trap=80 switch=64 bytes (integer only)
tick: 1000 us via TIMG0 T0 (source 25) -> clic input 16 prio 3
pool: max_tasks=16 prio_levels=8 idle_stack=4096B own stack
prims: mutex(pi=on) sem(count) queue(cap=4) events(32 bits) spin(A ext)
sched: 1 task created (+idle), preemptive, blocked-capable
ch12: sync primitives & IPC - blocked state, PI, queue, events
cfg: cs_sleep=30 tick, cs_burn=20000 nop, med_busy=60 tick, spin_iters=500
cfg: queue cap=4, items/task=6, prios L=1 M=3 H=5 supervisor=7
mon#0: tick=50 cur=<task> ready=[<8 个计数>] blocked=<n> sleep=<n>
spin: locked=1000 atomic=1000 expected=1000 acq=1000 lr_sc_retries=0
phase no-pi: begin, creating L1(prio 1)
phase no-pi: L1 holds m-no-pi
phase no-pi: M1(3) and H1(5) created
phase no-pi: high_wait=<A> ticks boosts=0 span=<n> ticks
phase pi: begin, creating L2(prio 1)
phase pi: L2 holds m-pi
phase pi: M2(3) and H2(5) created
phase pi: high_wait=<B> ticks boosts=1 span=<n> ticks
events: any -> bits=0x<n> (first finisher)
events: all -> bits=0xf reblocks=<k>
queue: puts=12 gets=12 high_water=<h>/4 put_blocks=<p> get_blocks=<g>
queue(partial): puts=<n> gets=<n> high=<h>/4 pb=<p> gb=<g>
queue: C1 items=6 sum=0x<x> bad=0 | C2 items=6 sum=0x<x> bad=0
sem: locked(blocks=<n>) done(posts=<n> blocks=<n> accumulated=<a>)
result: inversion wait no_pi=<A> tick vs pi=<B> tick (lower is better)
result: inheritance saved <A-B> tick (~<A-B> ms)
supervisor: 4 phases complete, handing over to idle
sched: all tasks done ticks=<t> switches=<s> blocks=<b>
idle: wfi
```

判读规则：

- `spin: locked == atomic == expected`：两条路径（锁保护 + `amoadd`）都没丢更新。
- `phase no-pi: boosts=0`、`phase pi: boosts=1`：证明继承只在阶段 B 发生。
- `no_pi > pi`：反转存在且被继承缩短。**具体数字必须来自真机**，
  判据是 **`A − B ≈ med_busy`（≈60 tick）**，不是绝对值。一句 ~90 字符的 `line()` 在 115200 下约 **8 ms**，
  TX FIFO 一满就阻塞，也就是最多 **8 个 tick**——所以带上 `monitor` 心跳后预期是 `A≈97`、`B≈37`
  （两边吸收同样的打印开销），差值不变。把 `97 ≠ 90` 当成新回归是误判。
- `queue: high_water` 说明队列真的被填满过；`put_blocks`/`get_blocks` 说明双向阻塞都发生过
  （同为 prio 2 的四任务按 slice 轮转，具体是否为 0 取决于调度顺序，**待真机确认**）。
- 最后停在 `wfi`：所有任务 `done` 后 idle 打印统计、`tick.disable()`、停住。

## 证据与边界

### 1. 为什么 idle 必须有自己的栈

任务被换下时，它的栈里存着“下次恢复要用的现场”（`switch` 帧里是 `ra`/`s0`–`s11`，
上面还有 trap 帧）。让 idle 复用 `main` 的 `_stack_top`，等于假设“`main` 的栈之后没人动”——
但 `main` 的栈正好是 SRAM 顶端那块，任何越界或任何一次换栈都会被它踩到。
ch11 的真机崩溃（`instruction access fault`，`ra` 指向栈地址）就是这个形状。
本章的修法：`idle_stack` 独占 4096 字节，`start()` **先换栈、后开 `MIE`**。
顺序反了会出现另一种 bug：`tick.enable()` 之后、`switchTo` 之前来一次 tick，
`schedule` 会把 `main` 的 sp 写进 `idle_task.sp`，把刚构造好的 idle 帧冲掉。

### 2. 为什么 `pickNext` 要丢弃 `done`

`markDone`（置 `done`）与“从就绪链上出队”不是同一个原子动作：任务可能先被 tick
按时间片重新入队，再被置成 `done`。若 `pickNext` 无条件返回队首，这个已结束的
TCB 会被重新调度，继续执行它 `done` 之后的代码——现象是“已经打印过 `done` 的任务
又打出几行”，或者更糟：`parkForever` 里不断 `ecall`，把 CPU 全吃在异常路径上。

### 2.5 等待由生产者驱动，静默必须可区分

两轮真机教训（2026-11-13）：

- 第一轮：supervisor 用**阻塞** `sem.wait` 推进阶段，`phase no-pi` 之后 50 s 静默。
- 第二轮：改成 `sleepTicks(1)` 轮询“有界等待”，回归更早——`spinA/spinB` 两行 `done` 之后
  连 `phase begin` 都没有，原因是 supervisor 在第一次 sleep 之后就没再被唤醒。

结论：**在裸机内核里，把同步寄托在睡眠链上比寄托在 post 上更脆**。现在：

| 机制                                  | 谁驱动                              | 用途                                               |
| ------------------------------------- | ----------------------------------- | -------------------------------------------------- |
| `sem.wait`（阻塞）                    | 生产者的 `post`（handoff 当场换栈） | 阶段推进、汇合                                     |
| `m.owner` 复核                        | 事实本身                            | 确认通知没撒谎，否则打 `WARN ... owner=none`       |
| `monitor`（prio 6，`sleepTicks(50)`） | tick                                | `mon#n: tick=… ready=[8 级计数] blocked=… sleep=…` |

心跳是最后一道可观测性，三种静默故障靠它区分：

| 现象                           | 结论                        |
| ------------------------------ | --------------------------- |
| 心跳完全不出现                 | tick ISR 死了，或睡眠链断了 |
| 心跳照走、`blocked=` 里有 sup  | 阻塞/唤醒 bug               |
| 心跳照走、`ready=[…]` 不符预期 | 就绪链被写坏                |

另外给两条链都加了不变量与上限：TCB 的 `sleeping` 标志拒绝重复入链（重复入链会让
睡眠链成环，而 `sleepTick` 在 ISR 里遍历它——成环等于冻住整个 tick，串口只会静默）；
`sleepTick`/`sleepRemove`/`waitPopBest` 都以 `max_tasks` 为上限，环最多走 16 步。

### 3. 丢失唤醒（lost wakeup）的形状

```
A：检查条件（不满足）            ← 关中断从这里开始
B：                             ← 若中间开过中断，别人在这里满足条件并唤醒
A：把自己挂进等待链并切换走      ← 醒来条件永远不成立，也再没人唤醒它
```

本章所有 `blockOn` 都在调用者已关中断的窗口里执行（`irqSave` 到 `schedule` 返回），
并且被唤醒后**重新检查谓词**（`while` 而不是 `if`）。

### 4. 单核上自旋锁必须先关中断

持有者被 tick 抢占后，同一个 hart 上的自旋者永远等不到释放。
所以 `spin.acquire` 先 `irqSave` 再 CAS，与 IDF 的 `spinlock_acquire`
（`components/esp_hw_support/include/spinlock.h:74`：先
`rv_utils_set_intlevel_regval(RVHAL_EXCM_LEVEL_CLIC)` 再 `esp_cpu_compare_and_set`）
完全同构。真竞争要等 ch14 的双核。

### 5. 继承能救什么、不能救什么

阶段 B 里 L 是**抱着锁睡觉**的：睡眠期间它不在就绪队列上，任何继承都帮不了它，
中优先级任务照样能跑。继承只能缩短“持有者已经就绪、但被中优先级挡住”的那一段。
这正好解释了那条铁律：**临界区里不要阻塞，不要睡眠，不要打印。**

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 退出码 0
- [ ] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [ ] `image-info` 的 Segments 表正好两行 `DROM, IROM`：`0x40000020`、`0x40020020`
- [ ] `bash -n tools/flash.sh` 退出码 0
- [ ] 串口出现 banner、`frames: trap=80 switch=64`、`pool: max_tasks=16`
- [ ] `spin:` 行里 `locked == atomic == expected`
- [ ] `phase no-pi` 的 `boosts=0`，`phase pi` 的 `boosts=1`
- [ ] `no_pi > pi`（记录两个数字与差值）
- [ ] `queue: puts=12 gets=12`、`bad=0`、`high_water ≥ 2`
- [ ] `events: all -> bits=0xf`
- [ ] `sched: all tasks done` 后停在 `wfi`，复位后不复现 `instruction access fault`
- [ ] 连续复位 10 次，`phase pi` 的 `high_wait` 稳定（±1 tick）
- [ ] （未闭环）ch11 遗留现象：同 prio 任务被 tick 抢占后长时间不再产出是否复现
