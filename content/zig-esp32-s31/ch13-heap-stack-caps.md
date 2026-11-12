---
title: "Zig × ESP32-S31 全栈开发（十三）：堆、栈保护与内存 caps"
date: 2026-11-27 18:00:00
description: "在 512 KB SRAM、16 MB PSRAM 的 S31 上自己写分配器：TLSF 的两级位图索引与双向物理合并、slab 的固定尺寸槽、8 字节对齐与 min_block 的取舍、IDF 式内存 caps（IRAM/DRAM/DMA/PSRAM）、栈哨兵与高水位、bus_monitor 的 SP 越界监视，以及『分配器自己写』意味着没有 sbrk 这条退路。"
tags: [zig, esp32-s31, riscv, rtos, allocator, memory, series]
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
> 12. [[ch12-sync-primitives-ipc|第十二章：同步原语与 IPC]]
> 13. **第十三章：堆、栈保护与内存 caps**
> 14. [[ch14-dual-core-smp-ipi|第十四章：双核 SMP 与 IPI]]

# Zig × ESP32-S31 全栈开发（十三）：堆、栈保护与内存 caps

前十二章里，所有对象都是"静态"的：任务栈是 `.bss` 里的数组，TCB 池是数组，
就绪队列是数组。这不是偷懒，而是把不确定性挡在门外——一旦有了动态分配，
"这块内存从哪来、会不会失败、失败了谁负责"就变成每个模块的问题。

本章正面处理这件事：**分配器自己写**。不是引用一个新库，而是把 TLSF 的两级
索引、块头与合并、对齐与碎片、栈哨兵与溢出检测、IDF 式的内存 caps、PSRAM 的
MMU 窗口，逐个在 S31 上讲清楚并落到代码里。

> [!warning] 本章的证据边界
> 形态 B 不变（Zig 产 ELF、自有链接脚本、IDF 只提供二级 bootloader 与分区表）。
> 寄存器与地址取自 ESP-IDF v6.1 的 `esp32s31` 头文件；S31 的 TRM 仍是
> Pre-release v0.7。本工程已于 2026-11-13 **真机运行**：TLSF 初始化/校验、7 档对齐分配、2000 次碎片压测（`peak_used=6536`、`frag=0`、`corrupt=0`、`ooms=0`）与 4 档 slab 统计全部正常，原始输出见 `../logs/ch13-boot.log`；PSRAM 探针与栈高水位仍按验收目标对待。构建、`esptool`
> 转换与主机侧单测在本仓执行过，但串口输出、PSRAM 探针结果、栈高水位数字
> 全部按"待真机验证"对待；不提供 `run.log`。

---

## 13.1 裸机里"分配器自己写"到底剥夺了什么

桌面上的 `malloc` 至少有四条退路，裸机一条都没有：

| 能力               | 桌面 glibc           | 本章（S31 形态 B）                                 |
| ------------------ | -------------------- | -------------------------------------------------- |
| 向 OS 要更多内存   | `sbrk` / `mmap`      | 无。arena 是链接期定死的 `[_heap_start,_heap_end)` |
| 缺页时换出         | swap                 | 无。物理内存就这么多                               |
| 分配失败时阻塞等待 | 可以等               | 不能等。返回 `null`，调用方必须处理                |
| 越界访问被抓       | MMU 保护页 → SIGSEGV | 只能靠哨兵/总线监视器，事后或半当场                |

第四条最容易被低估：**裸机的堆越界不会立刻报错**。它可能踩到相邻块头（下一次
`free` 才发现）、可能踩到另一个任务的栈（表现为"某个任务的局部变量自己变了"），
也可能踩到 `.data` 里的函数指针（表现为"随机跳飞"）。所以本章的分配器自带
`verify()` / `verifyLists()` / `verifyFlags()` 三个自检，并且在碎片压测里**每轮**
都跑。

第二条决定了一件事：**内存预算必须写下来**，不能"用到 OOM 再说"。所以本章的
第一个可观测产物不是分配成功，而是这张表：

```text
budget: sram_total=524288B app_usable=503744B static=…B heap=…permille stack=…permille
```

---

## 13.2 S31 的地址空间：五个不能互换的区间

`malloc` 的隐含假设是"内存都一样"。S31 上至少五个区间，能力完全不同：

| 区间           | 起址 + 长度              | 取指 | 8/16 位访问 | DMA  | 掉电保持 |
| -------------- | ------------------------ | ---- | ----------- | ---- | -------- |
| SRAM           | `0x2F000000` + `0x80000` | 是   | 是          | 是   | 否       |
| LP SRAM        | `0x2E000000` + `0x8000`  | 是   | 是          | 未核 | 是       |
| ROM            | `0x2F800000` + `0x50000` | 是   | 否（只读）  | 否   | —        |
| Flash 线性窗口 | `0x40000000` + 64 MiB    | 是   | 是          | 否   | —        |
| PSRAM 线性窗口 | `0x50000000` + 64 MiB    | 是   | 是          | 是   | 否       |

三个容易踩的点：

1. **ROM 与 SRAM 是两个区间**。`0x2F000000 + 0x80000 = 0x2F080000` 是 SRAM 的
   物理末尾；ROM 从 `0x2F800000` 起——中间那 7.5 MiB 是空洞。第十一章
   `PROVIDE(esp_rom_printf = 0x2f800024)` 之所以是"绝对地址"而不是符号引用，
   就是因为 ROM 不在链接脚本的任何 `MEMORY` 段里。
2. **应用可用的 SRAM 比物理少 0x5040**。二级 bootloader 把
   `iram_loader_seg` 放在 `0x2F07AFC0` 之上，所以链接脚本的
   `sram (rwx) : ORIGIN = 0x2F000000, LENGTH = 0x7AFC0`。写 `0x80000` 会在
   启动后不久被 bootloader 的残留数据覆盖。
3. **flash/PSRAM 窗口是 MMU 线性地址，不是物理地址**。1024 项 × 64 KiB 页
   = 64 MiB 窗口；模组只有 16 MiB PSRAM，所以"窗口比芯片大"是正常的，
   窗口里没映射的页访问即 fault。

本章的 `src/caps.zig` 把这张表变成代码：`Region { id, name, base, len, caps, note }`
数组 + `regionOf(addr)` + `find(want)`。`comptime` 块还会检查**区间互不重叠**——
否则归类结果依赖扫表顺序，那是隐患不是特性。

```zig
pub const Caps = packed struct {
    exec: bool = false,      // 可以取指
    bit8: bool = false,      // 支持 8/16 位访问
    bit32: bool = false,     // 支持非对齐 32 位访问
    dma: bool = false,       // 可被 GDMA 直接寻址
    internal: bool = false,  // 关 cache 后仍在
    psram: bool = false,
    retention: bool = false, // 深睡保持
};
```

为什么用 `packed struct` 而不是 IDF 那种整型掩膜：调用点写
`.{ .dma = true, .internal = true }`，拼错字段名是编译错误；掩膜拼错是运行期
偶发。代价是与 C 侧对接要在边界上加一个 `toMask()`。

---

## 13.3 TLSF：为什么是两级位图而不是空闲链

"第一次适应 + 单向空闲链"的教科书实现有两个致命属性：分配是 O(n)（链越长
越慢）、最坏情况不可分析。实时系统两条都不能接受。TLSF（Masmano 等，
ECRTS 2004）用两级位图把它压到**常数上界**：

```text
fl_bitmap        bit i    = 第 i 个一级类里有空闲块
sl_bitmap[23]    bit j    = 该一级类的第 j 个二级类里有空闲块
heads[23*16]     每个 (fl,sl) 一条双向空闲链
```

一级索引是 `floor(log2(size))`，二级索引是该幂次内的线性细分：

$$
\text{fl} = \lfloor \log_2 s \rfloor,\qquad
\text{sl} = \left\lfloor \frac{s - 2^{\text{fl}}}{2^{\text{fl}-\text{SL\_LOG2}}} \right\rfloor
$$

本章取 `SL_LOG2 = 4`（每个 fl 细分 16 段），于是"找一块 ≥ n"就是：

1. `fl_map = fl_bitmap & (~0 << fl)` → `@ctz` → 第一个可能装得下的幂次；
2. 同级则 `sl_map = sl_bitmap[fl] & (~0 << sl)`，否则取该 fl 的全部；
3. `@ctz` 得到链头，取块。

两次 `ctz` + 一次链表头读取，与 arena 大小无关。

**本实现与论文的一处必要偏离**：论文可以断言"同一个 (fl,sl) 里的块都 ≥ 请求"，
因为它把最小块与细分粒度设计成"一个类只有一个尺寸"。本章 `ALIGN = 8`、
`min_block = 32`，一个类里可能同时躺着 512 和 520，所以 `findFit` 会沿链找第一块
真正放得下的：

```zig
var cur = self.heads[@as(usize, fl) * sl_count + sl];
while (cur != 0) {
    if (sizeOf(cur) >= size) return cur;
    cur = at(cur).next_free;
}
```

代价是链长，不是 O(1) 的破坏：每个类里的尺寸种类上界是 `2^fl/16/8`。

---

## 13.4 块头、界限标记与物理合并

每个块 16 字节头（rv32）：

```text
       块地址 a ┌──────────────────────────┐
                │ size_and_flags  u32      │  低 3 位：FREE / PREV_FREE / LAST
                │ prev_phys       u32      │  前一个**物理**相邻块的地址
                │ next_free       u32      │  同一 (fl,sl) 链的下一个空闲块
                │ prev_free       u32      │  链上的前一个空闲块
      a + 16    ├──────────────────────────┤  ← alloc() 返回的指针
                │ payload …                │
                └──────────────────────────┘
```

四个字段各司其职，少一个都不行：

- **`size` 含头**：这样"下一块 = a + size"是一条加法，不需要单独的 tail 指针。
- **`prev_phys`**：向后合并的入口。`free(p)` 要 O(1) 找到前邻，不能扫链。
- **`PREV_FREE` 冗余位**：合并前先看前一个邻居是不是空闲，避免无谓读 `prev_phys`；
  更重要的是它是**一致性检查的抓手**——`verifyFlags()` 断言
  `PREV_FREE(块) == FREE(前邻)`，二者不一致就是"泄漏的碎片"。
- **`LAST`**：arena 最后一块的标记。没有它，`next_phys` 会走到 arena 外面读
  不属于自己的内存——这正是本章开发过程中真实踩到的一类 bug。

释放时的动作固定三步：与后邻合并（若 `FREE`）→ 与前邻合并（若 `PREV_FREE`）→
写新块头并让**物理后继**回指新块：

```zig
if (!last) {
    const succ = a + total;
    at(succ).prev_phys = a;
    setFlag(succ, PREV_FREE, true);
}
```

这三行看着平淡，但本章的随机压测（400 步、每步自检）就是被它救回来的：
最初的实现把 `PREV_FREE` 在"切出 tail"的路径上写死成 `false`，导致三个本该
合并的空闲块一直挨着——**结构完全自洽**（`verify` 全过），只是永远不合并。
这不是崩溃，是慢性泄漏。`verifyFlags()` 一加，第 5 步就报出来了。

---

## 13.5 对齐：请求的是 payload，不是块

`allocAligned(size, 64)` 的正确含义是"**返回的指针** % 64 == 0"，而不是"块地址
% 64 == 0"。块头 16 字节，所以两者差一个常数偏移，这个偏移必须显式补偿。

做法是"多要一点、把前面切掉"：

```text
[  前段（空闲）  ][ 本次分配 ][      tail（空闲）      ]
      ↑ shift         ↑ blk_addr
```

三个细节决定成败：

1. **shift 必须按对齐粒度抬**。若 `shift0 = align - payload0 % align` 小于
   `min_block`，前段做不成独立块，得"吞掉"它；但补偿量必须是 `align` 的整数倍
   （`shift += k * align`），加一个 `min_block` 会破坏对齐——这正是本章代码里
   注释写着"`+min_block` 会破坏对齐"的那一行。
2. **搜索尺寸要预留最坏间隙**。最坏 `shift = 2*align - 8`，所以
   `want = need + 2*align + min_block`。它只影响"找多大的空闲块"，切完 tail
   之后多余部分会还回去，不是真浪费。
3. **`need` 是整块字节数**。写成 `payload` 就等着出事：

```zig
// 错：need 是 payload，want 再加一次 header
const need = alignUp(size, 8);              // 17 -> 24
const want = block_header + need;           // 40
// 对：need 是整块
const payload = alignUp(@max(size, min_block - block_header), 8); // 17 -> 24
const need = block_header + payload;        // 40
```

这两个写法在小请求上看起来一样，但前者会让 `blk_size = 24 < block_header = 32`
（主机侧 64 位），写 `next_free` 时直接踩到下一块的 `size` 字段。本章就是
这么发现的：主机上 `verify()` 立刻报块链断裂，而 rv32 上恰好"勉强"能跑。

---

## 13.6 碎片压测：怎么让"压测"有判据

"跑 1000 次分配释放没崩"不是判据。本章的压测有四个判据：

| 判据       | 手段                                                        | 失败含义                       |
| ---------- | ----------------------------------------------------------- | ------------------------------ |
| 结构自洽   | 每轮 `verify()`：从 arena 头逐块走，尺寸合法、恰好走到 end  | 块头被踩坏                     |
| 空闲链自洽 | 每轮 `verifyLists()`：链上每块真 FREE、尺寸真属于该 (fl,sl) | 索引与链表脱节                 |
| 标记自洽   | 每轮 `verifyFlags()`：`PREV_FREE` 与物理相邻状态一致        | 泄漏的碎片（不崩溃但永不合并） |
| 不重叠     | 每块首字写本槽哨兵，释放时比对                              | 同一块被发出去两次             |

负载用一条 LCG（`seed = seed*1664525 + 1013904223`），与主机侧单测**同一条
公式**。这不是巧合：主机上跑 400 步能在一秒内复现，板上跑 2000 步再确认一次，
两份证据指向同一个数据结构的同一段代码。

```text
frag: ops=… peak_used=… free=… largest=… blocks=…
frag: overlap_hits=0 corrupt=0 ooms=… frag=…permille
```

`frag`（‰）的定义是 `1 - largest/free`：空闲内存里最大的一块占多少。它是
"还能不能分配出大块"的直接指标——永远比 `free` 更能说明问题。`blocks` 是
排空之后剩下的空闲块数：健康的分配器在全部释放后应当收敛到 1~2 块。

---

## 13.7 slab：把块头成本摊薄，并给出第二个"检测面"

TLSF 的 16 字节块头对 16 字节对象是 100% 开销。实时系统里大量对象是同一尺寸的
（队列节点、事件、`skb`），它们的分配不该走通用路径。

slab 的分层：

```text
class 0..4 ── 槽尺寸 16/32/64/128/256
     │
     ├── page 0  [1 KiB，切成 N 个槽，u64 位图记占用]
     ├── page 1  …
     └── page 3（每类最多 4 页）
```

- **页从 TLSF 借**（`heap.allocAligned(1024, 16)`），所以两层是真实的：slab 用光
  页就向 TLSF 要，TLSF 用光返回 `null`，谁都不越界。
- **1 KiB 页**让 16 字节类正好 64 槽（`u64` 位图整好填满），256 字节类 4 槽。
- **分配 = `@ctz(~bitmap)`**，一条指令。
- **不还页**：还页会让页数随负载抖动，位图与页描述都要重写，还可能立刻又借回来。
  代价是预算必须按峰值报（`slab: borrowed=…B`）。

内部碎片是刻意可观测的：

```text
slab: class= 16B pages=2 slots=128 used=70 waste=928B
slab: borrowed=…B waste=…B allocs=… frees=… ooms=…
```

`waste = pages × 1024 - used × slot_size`，包含"未用槽 + 位图 + 页尾对齐浪费"。
一个 70 个 16 字节对象的需求，slab 用 2048 字节（浪费 928），TLSF 直连则要
70 × 32 = 2240 字节（浪费 1120）。差距不大，但对象数到几千时是数量级差异。

---

## 13.8 栈：哨兵只能事后，高水位能事前

栈溢出在裸机上的表现是"随机"：踩到的是堆顶、另一个任务的栈，还是 `.data` 的
函数指针，取决于布局。三个层次的检测：

| 手段                      | 何时发现   | 成本                  | 本章状态       |
| ------------------------- | ---------- | --------------------- | -------------- |
| 边界哨兵字                | 每次检查时 | 4 字节 + 一次比较     | 已实现         |
| 高水位（魔数）            | 任意时刻   | 填一次 + 扫一次       | 已实现         |
| `bus_monitor` SP 越界中断 | **当场**   | 要开中断 + 接中断矩阵 | 只读探针，未配 |

**哨兵**：在栈的可增长端（最低地址）放 `0xDEADBEEF`，检查时比对。只能事后，
但零依赖——一个 `wfi` 之前的检查就能把"随机跳飞"变成一行日志。

**高水位**：把整段未用栈填 `0xA5`，跑完之后从边界往上找第一个被改动的字节。
本实现有个必须注意的细节：**不能填到自己正在用的帧上**。

```zig
const sp = readSp();
const limit = if (sp > r.low + frame_margin) sp - frame_margin else r.low;
// 只填 [_stack_bottom + 4, limit)
```

`frame_margin = 256` 覆盖本文件最深的调用（`log.line` 的 200 字节格式化缓冲 +
两级调用帧）。填到 `sp` 以下会把返回地址写掉——那是"检测工具自己制造溢出"。

**怎么证明检测器真的会响**：本章的 `sim_stack` 是一块 `.bss` 里的 512 字节数组，
扮演"某个任务的栈"。流程是"报 ok → 故意踩哨兵 → 必须报 overrun → 恢复 → 再报 ok"：

```text
stack: sim sentinel=ok at=0x… expect=0xdeadbeef got=0xdeadbeef
stack: sim simulate overrun -> write 0x78563412 at 0x…
stack: sim sentinel=overrun at=0x… expect=0xdeadbeef got=0x78563412
stack: sim overrun DETECTED (checker works)
stack: sim sentinel=ok at=0x… expect=0xdeadbeef got=0xdeadbeef
```

写的是**我们自己的缓冲区**，不是真栈，所以不是 UB；但它走的是与真栈溢出
完全相同的检测路径。一个永远返回 `ok` 的检测器没有任何价值，这一组输出是它的
唯一证明。

**硬件监视器（未配，寄存器先记下来）**：S31 的 `bus_monitor`
（`ASSIST_DEBUG`，基址 `0x2D002000`）把 SP 与两个边界比较：

| 寄存器                        | 偏移                        | 含义                                        |
| ----------------------------- | --------------------------- | ------------------------------------------- |
| `CORE_0_MONTR_ENA`            | `0x000`                     | `SP_SPILL_MIN_ENA` = bit8、`MAX_ENA` = bit9 |
| `CORE_0_INTR_RAW / ENA / CLR` | `0x004` / `0x008` / `0x00C` | `SP_SPILL_MIN/MAX` 对应 bit8/bit9           |
| `CORE_0_SP_MIN / SP_MAX`      | `0x038` / `0x03C`           | 下界 / 上界地址（复位 0 / 0xFFFFFFFF）      |
| `CORE_0_SP_PC`                | `0x040`                     | 触发那一刻的 PC                             |
| 中断源                        | 119                         | `ETS_ASSIST_DEBUG_INTR_SOURCE`              |

接法与前几章一致：源 119 → 中断矩阵 `0x20585000 + 4×119` 写 CLIC 输入号 →
CLIC 输入的 `IE` → `mstatus.MIE`。它才是"当场发现"，代价是把内存错误变成中断
路径的一部分（ISR 里要能安全地打印）。本章把寄存器与源号写在这里，把接线留给
ch14（IPI 已经有现成的跨核中断骨架）与 ch15（watchdog/panic dump）。

> [!warning] 待真机验证
> `bus_monitor` 在 S31 上的 `SP_MIN/SP_MAX` 语义（`<` 还是 `<=`、是否与
> 双核共享）未在本板实测。上面是头文件的字段定义，不是实测结论。

---

## 13.9 caps：把"这块内存能干什么"写进类型

`heap_caps_malloc(size, MALLOC_CAP_DMA)` 的价值不在 API，而在**拒绝**：它让
"我要 DMA 能直接寻址的内存"成为一条编译期/分配期可检查的约束，而不是运行期
"搬不动了"的调试噩梦。

本章的 `heap.allocCaps(want, size)` 只有 SRAM 一个 arena，所以它的主要作用是
明确失败：

```text
caps: alloc(internal+8bit, 128)=0x… region=sram
caps: alloc(size=1024) region=psram_cache has no arena in this chapter
caps: alloc(size=64) region=lp_sram has no arena in this chapter
caps: alloc(exec+dma+internal, 64)=0x…
```

三条不同的结局，对应三种真实场景：

1. **满足且有 arena** → 分配，返回地址；
2. **区间存在但没有 arena**（PSRAM/LP SRAM/ROM）→ `NoArenaForCaps` + 说明；
3. **区间不存在**（例如要 `psram && internal`，物理上无人满足）→
   `CapsUnsupported`，打印 `REJECTED`。

第 3 种才是 caps 的真正用处：它挡住的是"以为可以"的请求。注意比较用的是
`region.id == .sram` 而不是 `region.name`——字符串字面量的地址去重不可靠，
本章第一版就是靠 `name.ptr == "sram".ptr` 判断，随时可能被优化器或链接器改了。

---

## 13.10 PSRAM：窗口存在 ≠ 能访问

PSRAM 在 CPU 眼里是 MMU 线性窗口后面的一段地址：

```text
0x50000000 .. 0x54000000   64 MiB 线性窗口（1024 项 × 64 KiB 页）
   │ 每项把一页映射到 PSRAM 的某个物理页
   └→ 物理 PSRAM：模组 16 MiB
```

两件事必须分开看：

- **控制器初始化**：PSRAM 芯片本身要上电、配置模式寄存器、校准。IDF 里是
  `esp_psram_init()`（`CONFIG_SPIRAM_BOOT_INIT` 时由二级 bootloader 完成）。
- **MMU 映射**：把线性窗口的页映射到 PSRAM 物理页，写的是 PSRAM 侧的 MMU 表。

**本章的 bootloader 没有开 `CONFIG_SPIRAM`**（`idf-bootstrap/sdkconfig.defaults`
里没有这一项），所以两件事都没做。此时读 `0x50000000` 不是"读到随机值"，
而是 load access fault（本章会打印 `trap: exception code=5`）。

所以 `src/psram.zig` 的顺序是：

1. 读 `SPI_MEM_S_MMU_POWER_CTRL_REG`（`0x20502384`）的 `SPI_MMU_PAGE_SIZE[4:3]`
   得到页大小（PSRAM 侧 0 = 64K / 1 = 32K / 2 = 16K / 3 = 8K）；
2. 逐项读 `SPI_MEM_S_MMU_ITEM_CONTENT_REG`（`0x2050237C`，先写索引
   `0x20502380`），统计 `BIT(11)`（`SOC_MMU_PSRAM_VALID`）为 1 的项数；
3. **只有** `valid > 0` 才做读写校验；否则直接打印结论并跳过。

```text
psram: window=0x50000000..0x54000000 entry=1024 page=65536B chip=16777216B
psram: mmu_valid_entries=0/1024 mapped=no
psram: no mapping programmed by bootloader -> skip rw (initialise PSRAM first)
```

这是本章最重要的"诚实性"设计：探针的结论是"没有映射"，而不是"读写失败"。
假设我们不做这个检查、直接写 `0x50000000`，串口上看到的会是
`trap: exception code=7 (store access fault)`——信息量小得多（不知道是 PSRAM
没初始化、还是窗口没映射、还是页表写错）。

> [!warning] 待真机验证
> `valid_entries` 的实测值预期为 0（bootloader 没开 SPIRAM），但这只是推断；
> 上板后以串口实际数字为准。若不为 0，说明 bootloader 建了映射，`rw_probe`
> 那条分支才有意义。

---

## 13.11 工程走读

| 文件                  | 职责                                                                      |
| --------------------- | ------------------------------------------------------------------------- |
| `linker/s31.ld`       | 两个 flash 装载段、`.trap_ram`、`_heap_start/_heap_end`、16 KiB 主栈      |
| `src/start.zig`       | `esp_app_desc_t` + `_start`（关中断 → sp/gp → 关 RWDT → 清 .bss → mtvec） |
| `src/trap.zig`        | `.trap_ram` 里的 trap 入口 + 现场打印                                     |
| `src/log.zig`         | `esp_rom_printf("%s")` 包装，格式化在 Zig 侧                              |
| `src/alloc/tlsf.zig`  | TLSF：两级索引、块头、合并、对齐、三条自检                                |
| `src/alloc/slab.zig`  | slab：尺寸类、页借用、位图槽                                              |
| `src/caps.zig`        | 六个地址空间 + 能力集合 + 归类                                            |
| `src/heap.zig`        | arena 接线、caps 检查、预算表、结构自检                                   |
| `src/stack_guard.zig` | 哨兵 / 高水位 / 模拟溢出                                                  |
| `src/psram.zig`       | PSRAM 窗口常量 + 只读 MMU 探针                                            |
| `src/main.zig`        | 五组观测的编排                                                            |

启动顺序与 ch11 完全一致，本章只多了一个约束：

```text
_start：MIE=0、mie=0 → sp=_stack_top、gp → 关 RWDT → 清 .bss → mtvec → call main
  main：banner → budget()（链接符号）→ reportSpaces()（caps 归类）
       → heap.init()（arena = [_heap_start,_heap_end)）
       → 对齐/碎片压测/slab/caps/栈/PSRAM → 最终 verify → wfi
```

**`heap.init()` 必须在任何分配之前**，而且它不需要 `.bss` 被清零之后再做别的
准备——arena 里的内容在 `init` 里由块头覆盖。反过来，`_heap_start == _bss_end`
意味着"堆区不在 `.bss` 清零范围内"，这是有意的：清一块 480 KiB 的堆会让启动
多花几十万次写，而 `init` 只写头 16 字节。

三条来自前几章的硬约束照旧：

1. **两个 flash 装载段**。`image-info` 必须看到 `0x40000020` 与 `0x40020020`
   两个 `DROM, IROM` 段，否则 bootloader 的 `rom_index == 2` 断言会挂。
2. **trap 向量在 SRAM**（`.trap_ram`）。放 flash 时异常投递直接
   `rst:0x1a CPU_LOCKUP_RESET`——那样本章所有"打印现场"的能力都是空话。
3. **`_start` 关 RWDT**。bootloader 留着它，约 9 s 后 `CHIP_LP_WDT_RESET`。
   本章的压测有 2000 次分配/释放 + 一次 MMU 表扫描，时间不长，但没理由赌。

---

## 13.12 预算表：写下来，而不是算着看

本章的 `budget` 行有两层意义：第一层是数字（各段多大、还剩多少），第二层是
**它们全部来自链接符号**，不是手抄：

| 符号                           | 含义                                           |
| ------------------------------ | ---------------------------------------------- |
| `_image_start` / `_text_start` | 镜像头（`esp_app_desc_t`）/ `.flash.text` 起点 |
| `_rodata_start`                | `.flash.rodata` 起点（DROM 段）                |
| `_trap_start` / `_data_start`  | `.trap_ram` / `.data`（都在 SRAM）             |
| `_bss_start` / `_bss_end`      | `.bss`；`_bss_end == _heap_start`              |
| `_heap_start` / `_heap_end`    | arena；`_heap_end == _stack_bottom`            |
| `_stack_bottom` / `_stack_top` | 主栈 16 KiB；`sp` 初值 = `_stack_top`          |

链接脚本里那条 `ASSERT(_bss_end <= _stack_bottom)` 是整章的"最后一道构建期
防线"：静态对象一旦吃进栈区，**构建失败**，而不是运行期把栈踩掉。裸机没有
保护页，构建期检查是唯一便宜的兜底。

一份典型的分布（数字随代码变化，`<…>` 处必须由真机/本地构建填）：

```text
budget: image=0x40000020 irom.text=<n>B drom.rodata=<n>B
budget: sram trap=<n>B data=<n>B bss=<n>B heap=<n>B stack=16384B
budget: sram_total=524288B app_usable=503744B static=<n>B heap=<n>permille stack=<n>permille
```

`heap=<n>permille` 是堆占"应用可用 SRAM"的千分比。本章的分配器、slab 页表、
缓冲区表全在 `.bss` 里（约几 KB），所以堆能拿到 96% 以上。这个比例会随着
后续章节（协议栈缓冲、任务栈）下降——**每次下降都应该是设计决定**，而不是
"某个模块悄悄多要了几 KB"。

---

## 13.13 排错

| 现象                                  | 根因                                                              | 处置                                                        |
| ------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------- |
| `heap: corrupted` 出现在 init 之后    | arena 起点/终点取错（符号名拼错、把 `_heap_end` 写成 `_bss_end`） | 打印 `heapStart/heapEnd`；确认 `_heap_end == _stack_bottom` |
| 块链自检在第一次小分配后断            | `need` 当成 payload 用，块长 < 块头                               | `need = block_header + alignUp(size, 8)`，见 13.5           |
| 空闲块永远相邻却不合并                | `PREV_FREE` 或 `LAST` 某条路径写死                                | 打开 `verifyFlags()`，看哪一步起不一致                      |
| 对齐分配偶发不对                      | shift 用 `+min_block` 补偿（破坏对齐）                            | 补偿量必须是 `align` 的整数倍                               |
| `frag: blocks` 排空后仍是几十         | 合并逻辑只看了后邻，`prev_phys` 没维护好                          | 断言 `succ.prev_phys == 本段最后一块`                       |
| 读 `0x50000000` 直接 `code=5/7`       | PSRAM 未初始化 / MMU 未建映射                                     | 先读 `MMU_ITEM_CONTENT` 的 `BIT(11)`，见 13.10              |
| 串口打印在压测中途卡住                | `log.line` 的缓冲溢出/`bufPrint` 失败被静默吞掉                   | 保持单行 ≤ 200 字节；失败路径要么打印要么显式丢弃           |
| `stack: main used` 接近 `span`        | 真的快溢出了（不是检测器问题）                                    | 加大 `_stack_size`，或把深层调用里的缓冲改成静态            |
| 上板后 9 s 复位成 `CHIP_LP_WDT_RESET` | `_start` 没关 RTC/LP 看门狗                                       | 抄 ch11 的 `_start`（本章已含）                             |

---

## 13.14 与前后章的关系

- **ch04/ch11**：链接脚本与 `_start` 的骨架。本章只加了三个边界符号
  （`_heap_start`、`_heap_end`、`_stack_bottom`）与一条 `ASSERT`。
- **ch07**：`mcause` 的口径。本章的 trap 打印沿用 `cause & 0x1F`（异常码）与
  `cause & 0x3F`（中断输入号）——PSRAM 未映射时的 fault 就靠它定位。
- **ch12**：同步原语。一旦分配器要被多个任务调用，`alloc/free` 就必须进临界区；
  本章是单线程（`MIE = 0`），所以**故意不加锁**，也不需要"中断安全"的变体。
  这不是遗漏，是范围：加了锁而没有并发测试，只会得到一个"看起来安全"的实现。
- **ch14**：双核。`heap` 会变成真正的共享状态，需要每核缓存 + 跨核回收（或者
  干脆每核一个 arena）。本章的结构（`Allocator` 不含任何全局变量，只有一个
  `arena` 实例）就是为"以后有两份实例"准备的。
- **ch15**：可观测性。`verify()` 三件套、`frag` 千分比、`bus_monitor` 的 SP
  越界中断，都会成为稳定性压测的固定观测点。

---

## 13.15 验收目标

1. `zig build … -Doptimize=ReleaseSmall` 退出 0；
2. `esptool image-info` 出现 **两个** `DROM, IROM` 段（`0x40000020`、`0x40020020`）；
3. 主机侧 `zig test src/alloc/tlsf.zig` / `slab.zig` / `caps.zig` 全绿；
4. 串口出现 `budget:` × 3、`space:` × 11、`heap: total=… used=… free=…` 若干行；
5. `heap: verify=ok` 在 init / after-align / stress / after-drain / final **全部**为 ok；
6. `frag: overlap_hits=0 corrupt=0`；
7. `stack: main … sentinel=ok`，`used` 在几千字节量级；
8. `stack: sim sentinel=overrun` 出现且 `got=0x78563412`（检测器会响）；
9. `psram: mmu_valid_entries=<n>/1024 mapped=no|yes` 与 `<n>` 记录在案；
10. 连续复位 10 次，`heap: total` 与 `alloc: first/last` 稳定。

本仓能给的是 1、2、3 的证据（构建与单测在本机执行过）；4–10 全部**待真机验证**。

---

## 事实来源

| 事实                                                                 | 来源                                                                                                    | 备注                                              |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| SRAM `0x2F000000`+`0x80000`；ROM `0x2F800000`+`0x50000`              | IDF v6.1 `soc/esp32s31/include/soc/soc.h`                                                               | `SOC_IRAM_LOW/HIGH`、`SOC_IROM_MASK_LOW/HIGH`     |
| LP SRAM `0x2E000000`+`0x8000`                                        | 同上                                                                                                    | `SOC_RTC_IRAM_LOW/HIGH`                           |
| 应用可用 SRAM 上界 `0x2F07AFC0`                                      | IDF v6.1 `esp_system/ld/esp32s31/ld.hp_mem_defs`                                                        | `SRAM_SEG_END`（bootloader 的 `iram_loader_seg`） |
| flash/PSRAM 线性窗口 1024 项 × 64 KiB，PSRAM 基址 `0x50000000`       | IDF v6.1 `soc/esp32s31/include/soc/ext_mem_defs.h`                                                      | `SOC_MMU_ENTRY_NUM`、`SOC_MMU_PSRAM_VADDR_BASE`   |
| PSRAM 侧 MMU 寄存器 `0x20502000`+`0x37C/0x380/0x384`                 | IDF v6.1 `register/soc/spi_mem_s_reg.h` + `reg_base.h`                                                  | `SPI_MEM_S_MMU_ITEM_CONTENT/INDEX/POWER_CTRL`     |
| `SPI_MMU_PAGE_SIZE[4:3]`：PSRAM 侧 0/1/2/3 = 64K/32K/16K/8K          | 同上                                                                                                    | flash 侧编码不同（256K/128K/64K/32K）             |
| `SOC_MMU_PSRAM_VALID = BIT(11)`                                      | `ext_mem_defs.h`                                                                                        | 表项有效位                                        |
| `bus_monitor` 基址 `0x2D002000`；`SP_MIN/SP_MAX` = `+0x38/+0x3C`     | IDF v6.1 `register/soc/bus_monitor_reg.h` + `reg_base.h`                                                | `SP_SPILL_MIN/MAX_ENA` = bit8/bit9                |
| 中断源 119 = `ETS_ASSIST_DEBUG_INTR_SOURCE`                          | IDF v6.1 `soc/esp32s31/include/soc/interrupts.h`                                                        | 枚举第 120 项（0 起）                             |
| `MALLOC_CAP_*` 语义（EXEC/32BIT/8BIT/DMA/INTERNAL/SPIRAM/RETENTION） | `components/heap/include/esp_heap_caps.h`                                                               | 本章 `Caps` 与之同名同义                          |
| TLSF 两级索引与 O(1) 上界                                            | Masmano, Ripoll, Crespo, Real, _TLSF: a New Dynamic Memory Allocator for Real-Time Systems_, ECRTS 2004 | 本章加了"同类内沿链找"的必要偏离                  |
| callee-saved / 栈 16 字节对齐                                        | RISC-V psABI（ILP32）                                                                                   | 影响 `_stack_top` 的对齐                          |
| `esp_app_desc_t` 256 字节、魔数 `0xABCD5432`                         | IDF v6.1 `esp_app_format/include/esp_app_desc.h`                                                        | 第一个装载段必须以此开头                          |
| `esp_rom_printf = 0x2f800024`                                        | IDF v6.1 `esp_rom/esp32s31/ld/esp32s31.rom.ld`                                                          | 链接脚本 `PROVIDE`                                |
| 镜像必须恰好两个 flash 段（IROM+DROM），0x20 偏移                    | 本仓 `practice/zig-esp32-s31/BRINGUP-2026-11-12.md`                                                     | 真机发现：`rom_index == 2` 断言                   |
| trap 向量放 flash 会 `CPU_LOCKUP_RESET`                              | 同上 + ch06/ch11                                                                                        | `.trap_ram` 必须在 SRAM                           |

## 自查清单

- [ ] 裸机分配器比桌面 `malloc` 少哪四条退路？哪一条最容易被低估？
- [ ] S31 的 SRAM 物理大小与应用可用的差多少？差的那部分归谁？
- [ ] 为什么 ROM 的 `esp_rom_printf` 必须用绝对地址 `PROVIDE`？
- [ ] TLSF 的 `fl_bitmap` / `sl_bitmap` / `heads` 三者各解决什么问题？
- [ ] 为什么本章的 `findFit` 要沿链找，而论文里可以直接取表头？
- [ ] `size` 为什么含块头？`prev_phys`、`PREV_FREE`、`LAST` 各防哪类错误？
- [ ] `verifyFlags()` 能抓到什么 `verify()` 抓不到的问题？
- [ ] 对齐分配里 `shift` 为什么必须按 `align` 的整数倍补偿？
- [ ] `need` 是"payload"还是"整块"，写错会在什么尺寸上暴露？
- [ ] 碎片压测的四个判据是什么？`frag`（‰）的定义与意义？
- [ ] slab 的页从哪来？为什么本章不把空页还给 TLSF？
- [ ] 栈哨兵、高水位、`bus_monitor` 三者分别在"何时"发现溢出？各要什么代价？
- [ ] 给栈填魔数时为什么要留 `frame_margin`？填过头会发生什么？
- [ ] `stack: sim sentinel=overrun` 为什么不算 UB？
- [ ] caps 的三种结局分别对应什么场景？为什么用 `region.id` 而不是比较 `name`？
- [ ] PSRAM 窗口存在但读会 fault 的原因是什么？探针为什么必须先读 `BIT(11)`？
- [ ] `ASSERT(_bss_end <= _stack_bottom)` 为什么比运行期检查更值钱？

---

本章交付的是**一块可以被信任的堆和一套能证明它没坏的自检**：TLSF 的两级索引把
分配压到常数上界，双向物理合并不留慢性碎片，slab 把小对象成本摊薄，caps 让
"这块内存能干什么"变成分配期的判断，哨兵与高水位把栈的错误从"随机跳飞"变成
一行日志——而"分配器自己写"的代价，是没有 `sbrk` 这条退路，所以预算必须先写下
来。下一章把同一套结构搬到两个核上。

系列导航：[[ch12-sync-primitives-ipc|上一章]] · [[zig-esp32-s31|系列索引]]
