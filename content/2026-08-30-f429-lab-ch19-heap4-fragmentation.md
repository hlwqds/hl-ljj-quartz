---
title: heap_4 碎片实验
date: 2026-08-30 04:55:00
description: F429 裸机实验室（十九）——heap_4 的块结构、地址序 first-fit 与相邻合并逐行（heap_4.c 实读）；交错分配/隔块释放制造「不可合并碎片」，用 vPortGetHeapStats 的最大空闲块对阵总空闲字节自证，同一笔 malloc 失败后再成功的对照；对照 ESP32 侧 heap_2/heap_4 理论与 IDF 多堆 TLSF
tags: [STM32, FreeRTOS, Lab]
---

# heap_4 碎片实验

> **状态声明**：本章属「先成文、后实跑」——实验设计、寄存器推导、预期输出均已写定，但**尚未在真机上执行**；
> 文中所有「预期输出」均为待实测核销的推导值（示例数字以 `sizeof(TCB_t)=112B` 占位估算，公式列给出
> 精确算法），实跑后回填真实数据。板上事实查不到的一律标「待核对」，绝不编造运行日志与寄存器读数。
> 实验载体是序章救回的 `~/stm32/f429-freertos`，堆的口径与
> [[2026-08-30-f429-lab-ch14-stack-units-word-vs-byte|ch14：栈的单位]]严格一致，观察工具承接
> [[2026-08-30-f429-lab-ch16-stack-high-water-mark|ch16]]与[[2026-08-30-f429-lab-ch17-pendsv-single-step|ch17]]。

## 本章装备清单

| 分类       | 装备                   | 价格/状态 | 用途                 |
| ---------- | ---------------------- | --------- | -------------------- |
| 已有       | 挑战者 F429-V2 板      | ✅        | 实验主体             |
| 已有       | 野火 DAP + Mini-USB 线 | ✅        | 烧录/调试/串口       |
| 沿用基础盘 | 无新增                 | —         | ch19 纯软件+调试实验 |

## 本章会遇到的词

| 词                     | 一句话版                                        | 详见   |
| ---------------------- | ----------------------------------------------- | ------ |
| heap_4                 | FreeRTOS 官方第四套堆实现：first-fit + 相邻合并 | 目标   |
| 碎片（fragmentation）  | 空闲总量够、但拼不出一块连续的大空间            | 目标   |
| 空闲链表               | 把所有空闲块按地址串起来的单链表                | 原理一 |
| 块头（BlockLink_t）    | 每块内存头顶 8 字节的管理信息                   | 原理一 |
| first-fit              | 从头扫链表，第一个装得下的块就用                | 原理二 |
| 相邻合并（coalesce）   | 释放时跟前后紧挨的空闲块拼回一块                | 原理二 |
| HeapStats_t            | vPortGetHeapStats 填出的七字段堆体检报告        | 原理二 |
| TCB                    | 任务控制块——描述一个任务全部身份的结构体        | 原理三 |
| pvPortMalloc/vPortFree | FreeRTOS 版的 malloc/free，走 ucHeap 池         | 原理二 |
| TLSF                   | 两级分离适配分配算法（ESP32 用），近似 O(1)     | 对照   |

## 目标（先说结论）

- 先钉死口径（ch14 的结论，本章的地基）：**heap_4（FreeRTOS 官方随源码附带的五套堆实现里的第四套，源文件就叫 heap_4.c——本章主角）的堆 = `heap_4.c:95` 的静态数组
  `ucHeap[configTOTAL_HEAP_SIZE]`，64KB，落主 SRAM 的 .bss**（.bss：C 程序里未初始化/初值为零的静态变量所在段，上电时被启动代码清零，本身不占 Flash 体积；本机当前构建 `nm` 实测 `ucHeap` 在
  0x2000010c）。链接脚本（.ld 文件——告诉链接器「每个段放哪个地址」的地图）里那个 `.heap (NOLOAD)` 0x400 段（STM32F429IG.ld:57-63）是给 libc malloc
  留的，本工程 `-nostdlib`（编译选项：不链接 C 标准库——自然也没有 libc 那套 malloc）未用——两张「堆」互不相干。
- 碎片的可操作定义：**总空闲字节 > 最大连续空闲块**。本章用 `vPortGetHeapStats()` 的
  `xAvailableHeapSpaceInBytes` 对阵 `xSizeOfLargestFreeBlockInBytes`，交错分配 A/B/C（+一颗门牙 D）、
  隔块释放，让这两个数字**分叉 4112 字节**；再发一笔「总空闲够、最大块不够」的 malloc，亲眼看它
  返回 NULL——然后把中间的占用者放掉，同一笔 malloc 立刻成功。碎片从直觉变成两列数字。
- heap_4 对 heap_2 的全部升级就在一个函数：`prvInsertBlockIntoFreeList()`（heap_4.c:504-569）的
  **相邻合并**——按序释放后最大块回升、四阶段快照的最后一行两列重新会合，是合并发生的直接证据。
- 对照：[[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison|FreeRTOS（十九）]]在 ESP32 侧
  讲过四种分配器的理论（heap_2 无合并的 A/C 演示、heap_4 的 first-fit+合并），
  [[2026-08-26-freertos-deep-dive-ch20-idf-heap-and-caps|FreeRTOS（二十）]]是 IDF 的多堆 TLSF——本章在
  64KB 的单堆上把同一套数字跑成实拍。

> 📖 **术语卡：碎片（fragmentation）**
> **是什么**：内存空闲总量还有不少，但被仍在使用的块切割成零散小段，拼不出一块够大的连续空间——「总空闲 ≥ 请求，malloc 仍失败」的状态。
> **为什么存在**：已分配的块不能搬家（指针正被用户拿着），空隙的位置就此钉死；交错分配、隔块释放最擅长造这种格局。
> **类比**：停车场剩 20 个空位，但全被停着的车隔成一格一格——小车进得来，大巴（大请求）进不来。
> ⚠️ 类比边界：车位格局只能靠车开走自然变化；堆里相邻的空闲块在释放瞬间会被自动合并成大块——碎片是动态的，这正是本章后面「清场后同一笔 malloc 立刻成功」的原因。

## 原理一：块结构与堆的初始形态

每块内存（无论空闲/已分配）头顶 8 字节管理头（32 位端口 `sizeof(BlockLink_t)=8`、对齐 8——
`portBYTE_ALIGNMENT=8` 见 portmacro.h:83，`xHeapStructSize` 见 heap_4.c:158）：

```c
/* heap_4.c:100-104 —— 空闲链表按【地址升序】链接（合并的前提） */
typedef struct A_BLOCK_LINK
{
    struct A_BLOCK_LINK * pxNextFreeBlock;
    size_t xBlockSize;                 /* 块大小（含头）；最高位被征用为占用标志 */
} BlockLink_t;
/* heap_4.c:80-84 —— MSB=1 表示已分配；与 pxNextFreeBlock==NULL 组成 double-free 防线 */
```

> 📖 **术语卡：空闲链表（free list）**
> **是什么**：把堆里所有空闲块用各自块头的 `pxNextFreeBlock` 字段串成的一条单链表；heap_4 特意让链表按块地址**升序**排列。
> **为什么存在**：分配时找「哪块空闲够大」、释放时找「该插到哪个位置」都要遍历这张清单；而按地址排序后，相邻两行地址一减就知道是否紧挨——这是相邻合并的前提。
> **类比**：小区车位登记表按门牌号排序——想查「3 号和 5 号之间是否隔着 4 号」，看相邻两行就够了。
> ⚠️ 类比边界：登记表是额外的一本册子；空闲链表直接寄生在每个空闲块自己的头 8 字节里，不耗额外内存，但代价是块至少要 16 字节（heapMINIMUM_BLOCK_SIZE）才装得下这两个字段。

看代码注释里两个位级小名词：**MSB**（Most Significant Bit，32 位字的最高位 bit31）——heap_4 把
`xBlockSize` 的这一位「征用」当占用标志（1=已分配、0=空闲），大小信息用低 31 位装；**double free**
（同一块内存被 free 两次）的防线就是注释里那对组合条件：MSB 在=确实分配过（防野指针），next 仍
NULL=还没回到链表（防二次释放）。

首次 `pvPortMalloc`（FreeRTOS 的 malloc——函数原型与 malloc 相同，但内存池换成本章的 ucHeap，FreeRTOS 工程里任务栈/TCB 全走它）时 `prvHeapInit()`（heap_4.c:456-501）惰性初始化：堆起点上对齐 → 尾部放一个
`pxEnd` 哨兵块（哨兵 sentinel：摆在堆尾的假块，size 记 0、只当链表巡逻的终点标记，永不参与分配；xBlockSize=0、next=NULL）→ 整堆作为一个大空闲块。用本机真实地址算初始账
（推导，实跑回填）：

```text
ucHeap 落址（本机当前构建）：0x2000010c —— 不是 8 对齐（0x10c & 7 = 4）
prvHeapInit 上对齐（heap_4.c:463-470）：堆起点 0x20000110，损失 4 字节
尾部 pxEnd 哨兵（heap_4.c:485-490）：再扣 8 字节
可用总额 = 65536 − 4 − 8 = 65524 字节     ← xFreeBytesRemaining/xMinimumEver 的初值（:499-500）
（ucHeap 地址随构建挪动，对齐损失可能为 0/4，此账以实跑为准）
```

**命令拆解：** `arm-none-eabi-nm build/f429-freertos.elf | grep ucHeap`

| 部分                      | 作用                                                                  |
| ------------------------- | --------------------------------------------------------------------- |
| `arm-none-eabi-nm`        | 列出 ELF 文件（带调试符号的构建产物）里全部符号的「名字→地址」对照表  |
| `build/f429-freertos.elf` | 构建输出的 ELF 文件路径                                               |
| `\| grep ucHeap`          | 从符号表里只留 ucHeap 那一行，抄下它的落址（上面账本里的 0x2000010c） |

**你会看到**：类似 `2000010c B ucHeap` 的一行——B 表示 .bss 段符号，地址就是堆数组的起点。
**失败了先查**：没输出（符号被优化/裁掉，确认构建没换 release 裁符号选项）；地址与上一构建不同（加过代码必挪，正常现象）。

## 原理二：分配、释放与合并的艺术

> 📖 **术语卡：first-fit（首次适配）**
> **是什么**：分配时从空闲链表头开始逐块扫，遇到的第一个「装得下本次请求」的空闲块就用——不挑最合适的，够用就走。
> **为什么存在**：实现最简单、平均扫描距离最短；代价是大块容易被反复从尾部切渣，越切越碎（与 best-fit「挑最贴身的一块」相对）。
> **类比**：进停车场从头往里开，遇到第一个停得下的空位就停，不继续往深处找「正好贴合大巴长度」的位。
> ⚠️ 类比边界：车停进去车位就整段没了；first-fit 碰到过大的块会**从尾部切出余段重新挂回链表**——相当于长车位只占一头、剩下一头留给后来者。

**分配 = 地址序 first-fit + 分裂**（pvPortMalloc，heap_4.c:173-351）：请求加头对齐
（186-199）→ 从 `xStart` 走到第一个够大的块（244-253）→ 摘链、返回 `块首+8`（261）→
块太大就**从尾部**切一块新的空闲块插回链表（272-289，条件：余量 > heapMINIMUM_BLOCK_SIZE=16，
heap_4.c:59）。分配拿走低地址段、余段留在高地址——堆从低地址端向上生长，老块优先复用。

**释放 = 双重验尸 + 合并插入**（vPortFree，heap_4.c:354-410）：

```c
/* heap_4.c:369-370 —— 先验尸再动手 */
configASSERT( heapBLOCK_IS_ALLOCATED( pxLink ) != 0 );  /* MSB 在=确实分配过（防野指针） */
configASSERT( pxLink->pxNextFreeBlock == NULL );        /* next 仍空=还在用户手里（防 double free） */
/* 390-396：挂起调度器（vTaskSuspendAll）包住 → xFreeBytesRemaining 加回 → 合并插入 */
```

（`configASSERT` 是 FreeRTOS 的断言宏——条件为假时调用配置好的失败钩子/停机，调试期拿它抓「不该发生的状态」；「验尸」=先检查这块内存的死亡证明再动刀。）

**合并四步**（`prvInsertBlockIntoFreeList`，heap_4.c:504-569——heap_4 存在的全部理由）：

```text
① 定位（511）：从 xStart 走到地址恰好小于被释放块的迭代器 I
② 前合并（525-529）：I 的尾地址 == 本块首地址？→ I 吞掉本块
③ 后合并（539-551）：本块尾地址 == I->next 的首地址？→ 本块吞掉 I->next
   （541-550 特判：I->next 是 pxEnd 哨兵时只改链接、不吞它的 size=0）
④ 链接（561-564）：若 ② 已被吞并则什么都不做——否则 I->next = 本块
   （无条件链接会让「前后同时合并」的块指向自己成环，源码注释 "plugged a gab" 记着这个坑）
```

**两个仪表 + 一份详细体检**：`xFreeBytesRemaining`（现在剩多少）与 `xMinimumEverFreeBytesRemaining`
（历史最惨，heap_4.c:166-167；分配路径 295-300 只降不升——**栈高水位的堆版本**，ch16 的水位单调性
同款）。`vPortGetHeapStats()`（heap_4.c:572-621）现场遍历空闲链填出七个字段（定义在
portable.h:157-165）：

| 字段（HeapStats_t）                    | 含义                         | 本章用途       |
| -------------------------------------- | ---------------------------- | -------------- |
| xAvailableHeapSpaceInBytes             | 总空闲字节（所有空闲块之和） | 碎片的「分母」 |
| xSizeOfLargestFreeBlockInBytes         | 最大连续空闲块               | 碎片的「分子」 |
| xNumberOfFreeBlocks                    | 空闲块个数                   | 洞的个数       |
| xSizeOfSmallestFreeBlockInBytes        | 最小空闲块                   | 找碎渣         |
| xMinimumEverFreeBytesRemaining         | 历史最低总空闲               | 容量规划基准   |
| xNumberOfSuccessfulAllocations / Frees | 成功分配/释放次数            | 操作数对账     |

锁的分层也在这段源码里：遍历链表用 `vTaskSuspendAll()`（挂起调度器——只是不许任务切换，中断照常进来，所以适合包住「长但不怕打断」的操作；577 行），读四个计数器用
`taskENTER_CRITICAL()`（进临界区——关掉可屏蔽中断的短保护，一致性快照；613-620 行）——为什么这么分，
[[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison|FreeRTOS（十九）]]19.7 有整节论证，此处只记
铁律：**ISR 里禁止 malloc/free**（挂调度器挡不住中断——这是与 Linux 里可以 sleep 的信号处理函数本质不同的约束）。

## 原理三：任务创建的账本——栈和 TCB 全走这个堆

> 📖 **术语卡：TCB（Task Control Block，任务控制块）**
> **是什么**：FreeRTOS 用一个结构体装下一个任务的全部身份：栈顶指针、任务函数入口、优先级、状态链表节点、任务名……动态创建任务时它和任务栈一样从 ucHeap 堆里 pvPortMalloc 出来。
> **为什么存在**：调度器切换任务必须有地方记「这个任务此刻的一切」；ch17 单步时见过的 `pxCurrentTCB` 就是指向当前 TCB 的指针。
> **类比**：内核里的 task_struct（你的主场）——同一思想在 RTOS 里的袖珍版。
> ⚠️ 类比边界：task_struct 由内核自家的 slab/伙伴系统分配，TCB 却和任务栈共用同一个用户态堆——堆一碎，最先死的就是「创建新任务」这件事。

ch14 的预算表在此落地成账本（动态创建路径：先 TCB 再栈，tasks.c:1651 与 1663 两次独立
`pvPortMalloc`；Idle 任务同样动态——`configSUPPORT_STATIC_ALLOCATION=0`，FreeRTOSConfig.h:30）：

| 账目                 | 公式（字节）                         | 占位估算（TCB=112B，待实测） |
| -------------------- | ------------------------------------ | ---------------------------- |
| fast：TCB + 256 字栈 | align8(112+8) + (256×4+8) = 120+1032 | 1152                         |
| slow：TCB + 256 字栈 | 同上                                 | 1152                         |
| Idle：TCB + 128 字栈 | align8(120) + (128×4+8) = 120+520    | 640                          |
| 基线剩余 S0          | 65524 − 2944                         | **62580**                    |

公式里的两个记号先翻译：`align8(x)` = 把 x 向上取整到 8 的倍数（块与栈都要 8 字节对齐——portBYTE_ALIGNMENT=8）；每个 `+8` 都是本章块头那 8 字节（pvPortMalloc 的实占 = 用户请求 + 8 头 + 对齐兜底）。所以 `pvPortMalloc(2048)` 实际从链表摘走 2056 字节、`pvPortMalloc(512)` 摘走 520——实验代码注释里的数字就是这么来的。

**命令拆解：** `gdb -q build/f429-freertos.elf -ex 'p sizeof(TCB_t)'`

| 部分                             | 作用                                                                                 |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| `gdb -q build/f429-freertos.elf` | 不连板、只加载带调试信息的 ELF（-q=安静模式不印版权）；types TaskControlBlock_t 也行 |
| `-ex 'p sizeof(TCB_t)'`          | 执行一条「打印 sizeof(TCB_t)」后退出——把账本表的 112B 占位换成实测值                 |

**你会看到**：`$1 = 112`（或别的数——取决于当前内核配置，换值重算账本表即可）。
**失败了先查**：报 No symbol（工程没带 -g3 调试信息，查 Makefile 的 CFLAGS）；类型名不认（换 `struct tskTaskControlBlock` 全名）。

## 实验：四阶段快照 + 一笔跨洞 malloc

实验任务（加进 `main.c`，创建于 `vTaskStartScheduler()` 之前；`HeapStats_t` 随 `FreeRTOS.h` 即得）：

```c
static void stats_dump(const char *tag)
{
    HeapStats_t s;
    vPortGetHeapStats(&s);
    uart_puts("[heap] "); uart_puts(tag); uart_puts(": avail=");
    uart_putdec(s.xAvailableHeapSpaceInBytes);
    uart_puts(" largest="); uart_putdec(s.xSizeOfLargestFreeBlockInBytes);
    uart_puts(" blocks="); uart_putdec(s.xNumberOfFreeBlocks);
    uart_puts(" min-ever="); uart_putdec(s.xMinimumEverFreeBytesRemaining);
    uart_puts(" a/f="); uart_putdec(s.xNumberOfSuccessfulAllocations);
    uart_puts("/"); uart_putdec(s.xNumberOfSuccessfulFrees); uart_puts("\r\n");
}

static void frag_task(void *arg)
{
    (void)arg;
    void *A, *B, *C, *D;
    HeapStats_t s;

    vTaskDelay(pdMS_TO_TICKS(500));        /* 等 Idle 建完，基线干净 */
    stats_dump("S0 baseline");

    A = pvPortMalloc(2048);                /* 交错分配：吃块头后实占 2056 */
    B = pvPortMalloc(512);                 /* 520 */
    C = pvPortMalloc(2048);                /* 2056 */
    D = pvPortMalloc(512);                 /* 520：门牙——顶住尾块，不让 C 的洞跟大尾巴合并 */
    stats_dump("S1 ABCD allocated");

    vPortFree(A);                          /* 隔块释放：B、D 还在中间占着 */
    vPortFree(C);
    stats_dump("S2 freed A,C (B,D hold gaps)");

    vPortGetHeapStats(&s);                 /* 跨洞证明：总空闲够、最大块不够 */
    size_t want = s.xSizeOfLargestFreeBlockInBytes + 2000;   /* 2000 < 两洞之和 4112−8 */
    void *cross = pvPortMalloc(want);
    uart_puts("[heap] cross-gap malloc("); uart_putdec(want);
    uart_puts(") -> "); uart_puts(cross ? "OK?!" : "NULL"); uart_puts("\r\n");
    if (cross) { vPortFree(cross); }       /* 不应发生；发生即推导翻车，进 KD 日志 */

    vPortFree(B);                          /* 按序清场：A+B+C 连片，D 再并入，最后接上大尾巴 */
    vPortFree(D);
    stats_dump("S3 B,D freed, coalesced");

    void *again = pvPortMalloc(want);      /* 同一笔请求重发：这次应该成功 */
    uart_puts("[heap] retry same malloc -> "); uart_puts(again ? "OK" : "NULL?!");
    uart_puts("\r\n");
    if (again) { vPortFree(again); }

    for (;;) { vTaskDelay(pdMS_TO_TICKS(2000)); }
}
```

代码走读（数字对着看）：注释里 2056/520 就是「请求 + 8 字节块头」（2048+8、512+8，本例恰无对齐尾差）；`stats_dump` 把 HeapStats_t 七字段里最关键的五列打成一串，每阶段一行、肉眼可比；`want = largest + 2000` 的算计是——比最大块多要 2000 字节（2000 < 两个孤洞合计 4112−8，请求塞得进「总空闲」却塞不进任何单块），制造确定性的跨洞失败；`cross ? "OK?!" : "NULL"` 里的问号是给推导留的翻车报警；每阶段之间靠 `vTaskDelay` 拉开时间，让串口日志阶段分明。

两个设计意图说破：**D 为什么存在**——没有 D，`free(C)` 会立刻跟大尾块合并（后合并第 ③ 步），
「最大块 < 总空闲」的差距只剩 A 一个洞，跨洞 malloc 的尺寸没法预算；D 把 C 的洞也隔成孤岛，
两个洞合计 4112 字节，2000 字节的跨洞请求就有了确定性的失败预算。**为什么要重发同一笔**——
S2 时总空闲 61540 本已大于请求 59436，malloc 却因「不连续」失败；清场后总空闲只多了 B+D 的
1040 字节，同一笔请求就成功了——**让请求通过的不是多了 1040 字节，是内存重新连续**。
碎片问题的全部戏剧性，就在这一对输出里。

## 预期输出（待实测核销）

四阶段快照表（示例数字按 TCB=112B 占位推导，实跑回填；公式已给，换 TCB 实测值重算即可）：

| 阶段 | 总空闲 avail | 最大块 largest | 空闲块数 | min-ever | 解读                                         |
| ---- | ------------ | -------------- | -------- | -------- | -------------------------------------------- |
| S0   | 62580        | 62580          | 1        | 62580    | 一整块，无碎片                               |
| S1   | 57428        | 57428          | 1        | 57428    | ABCD 从低地址端切走 5152，尾巴仍连片         |
| S2   | 61540        | 57428          | 3        | 57428    | **两列分叉 4112=两个孤洞**：碎片成立         |
| S3   | 62580        | 62580          | 1        | 57428    | 两列重新会合=合并发生的铁证；min-ever 不回升 |

串口形态（数值待实测核销）：

```text
[heap] S0 baseline: avail=62580 largest=62580 blocks=1 min-ever=62580 a/f=8/0
[heap] S1 ABCD allocated: avail=57428 largest=57428 blocks=1 min-ever=57428 a/f=12/0
[heap] S2 freed A,C (B,D hold gaps): avail=61540 largest=57428 blocks=3 min-ever=57428 a/f=12/2
[heap] cross-gap malloc(59428) -> NULL          ← 总空闲 61540 够、最大块 57428 不够
[heap] S3 B,D freed, coalesced: avail=62580 largest=62580 blocks=1 min-ever=57428 a/f=12/4
[heap] retry same malloc -> OK                  ← 同一笔请求，只因内存重新连续
```

三个推导自检点：① S2 的 blocks=3 是 A 洞、C 洞、大尾块——如果实跑读到 2，说明 C 意外并进了尾巴
（D 没顶住或释放顺序有出入），先查这个再看别的；② min-ever 全程钉在 S1 的 57428 不动——水位线
只降不升（295-300 的实现决定了它不可能回升），S3 的「回升」只发生在 avail 与 largest 上；
③ a/f 计数按代码顺序对账：S0 时 fast/slow/frag/Idle 各吃两次分配（8/0），S1 加 ABCD 四次（12/0），
S2 两次释放（12/2），S3 再释放两次（12/4）；跨洞那次失败**不进计数**——字段名里 Successful 的含义，
也是用这对计数抓「静默 malloc 失败」的原理。

## 与主系列对照

| 维度         | 本板（heap_4/64KB 单堆）                                  | ESP32（IDF heap 组件）                                           |
| ------------ | --------------------------------------------------------- | ---------------------------------------------------------------- |
| 堆的形状     | `ucHeap[64KB]` 静态数组（heap_4.c:95）                    | 全部内部 RAM 按 caps 聚合，无独立内核堆（heap_idf.c 转接）       |
| 分配算法     | 地址序 first-fit + 分裂（最坏扫全链）                     | 每区域一个 TLSF：两级位图 good-fit，O(1)（FreeRTOS（二十）20.5） |
| 合并         | prvInsertBlockIntoFreeList 四步（本章主角）               | TLSF 完整保留合并                                                |
| 碎片哨兵     | largest vs avail 两列分叉（HeapStats）                    | `heap_caps_get_largest_free_block` 同款思路（20.7 经验法则）     |
| 水位线       | xMinimumEverFreeBytesRemaining，单一堆精确                | 各区域独立记录再求和=「最坏情形指示」而非全局最低点（19.9）      |
| 抗碎片的本钱 | 小池：64KB 里 4KB 的洞就是 6%                             | 大池+分流：520KB 内部 RAM、caps 把不同负载路由到不同区域池       |
| malloc 失败  | vApplicationMallocFailedHook（零参数，main.c:79-83 已备） | heap_caps_register_failed_alloc_callback（带 size/caps/函数名）  |

关于「多堆为什么天然抗碎片」要说得精确：**多区域本身不抗碎片**——heap_5/多堆的区域边界是永久的
不可合并源（FreeRTOS（十九）19.6.2 讲过）；IDF 的抗碎片本钱在三处：池大（同样的洞占比下更容易找到
大块）、caps（capabilities，能力标签——IDF 给每片内存标上「可 DMA/可 8 位访问/可执行」等能力，分配请求按所需能力路由到对应池）路由让同脾气负载同池（交错模式天然减少）、TLSF（Two-Level Segregated Fit，两级分离适配——把空闲块按大小分桶挂两级位图索引，分配近似 O(1)）的 good-fit（好适配——从「最贴合该尺寸的桶」里取块）不像 first-fit 那样偏爱在
低地址切出细渣。本实验的 64KB 单堆把这些优势全部剥掉，露出碎片问题的最裸形态——先看懂病，再看病
在哪里被稀释。容量规划的教训同款收尾：**永远看 min-ever 而不是当前 avail**，而 `configTOTAL_HEAP_SIZE`
撑不下时的死亡证明书是 ch14 讲过的 `[HOOK] malloc failed!`（configUSE_MALLOC_FAILED_HOOK=1，
FreeRTOSConfig.h:33）。

## 本章待核对清单

| #   | 项                                                                     | 核对方法                                                  |
| --- | ---------------------------------------------------------------------- | --------------------------------------------------------- |
| 1   | `sizeof(TCB_t)` 实测值（账本表用 112B 占位）                           | gdb `p sizeof(TCB_t)`（ELF 有 -g3 调试信息）              |
| 2   | ucHeap 落址与对齐损失（当前构建 0x2000010c、损失 4B；加代码后会挪）    | `arm-none-eabi-nm build/f429-freertos.elf \| grep ucHeap` |
| 3   | S0 基线 avail（占位 62580）与 a/f 计数（frag_task 自己也吃堆）         | stats_dump 首行回填                                       |
| 4   | S2 两列分叉 4112、blocks=3（若为 2 即 D 门牙失效，查释放顺序）         | S2 行回填 + openocd `mdw` 看 B/D 块头的 MSB               |
| 5   | 跨洞 malloc 返回 NULL、清场后同一尺寸返回 OK                           | 两行输出对照                                              |
| 6   | min-ever 全程钉在 S1 值不回升                                          | 四阶段表核对                                              |
| 7   | `vPortGetHeapStats` 的 S2.xSizeOfSmallestFreeBlockInBytes（应为 2056） | stats_dump 加打一列                                       |
| 8   | free 后块头 MSB 清零、pxNextFreeBlock 指向链表（双重验尸的字段级验证） | `mdw` 块头两字对照 heap_4.c:80-84 的位定义                |

清单 #8 的操作展开：先在 gdb/openocd 里拿到 B、D 指针值（即块首），对每块执行 openocd 的
`mdw <块首−8> 2`（从块头前 8 字节起连读 2 个字：第一个字是 pxNextFreeBlock、第二个是 xBlockSize）——
空闲态应看到 size 的低 31 位仍在、bit31 清零，next 已指向链表里的邻居；这正是「双重验尸」两个字段的
硬件级目击。

下一章：[[2026-08-30-f429-lab-ch20-ethernet-emac-phy|以太网上电：EMAC 与 PHY]]——
FreeRTOS 对照实验（阶段 4）到此收官：栈的单位、轮转的纯度、水位侦探、PendSV 单步、FPU 欠账、
堆的碎片，六块积木齐了；阶段 5 用它们搭以太网大戏——MDIO 读 PHY ID、裸机 lwIP、ping 通树莓派。
系列总目录见[[2026-08-30-f429-lab-series-index|F429 裸机实验室索引]]。
