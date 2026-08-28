---
title: "FreeRTOS 深度解析（十九）：堆分配器全家桶"
date: 2026-08-26
description: "内核堆契约（pvPortMalloc/vPortFree 与 configSUPPORT_DYNAMIC_ALLOCATION）；heap_1~heap_5 五个参考分配器的源码走读与能力矩阵；heap_4 的 BlockLink_t 块结构、地址序 first-fit、分裂与相邻合并逐函数拆解；malloc 失败钩子与 IDF heap_idf.c 的转接差异；QEMU 上观察分配释放模式下的空闲堆。"
tags: [freertos, rtos, esp32, esp-idf, memory-management, heap, allocator, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]] 19. **第十九章：堆分配器全家桶**

# FreeRTOS 深度解析（十九）：堆分配器全家桶

这一章回答一个问题：**内核的内存从哪来**。`xTaskCreate()` 一执行，TCB 和任务栈就从堆里长出来——但 FreeRTOS 是个"没有进程、没有虚拟内存"的内核，它用的堆是谁的堆？答案是：内核自己带了一套可选的堆实现，`portable/MemMang/` 下的 `heap_1.c` 到 `heap_5.c` 五个文件，工程里五选一编入。本章把它们全部拆开：每个的实现策略、源码要点、适用场景，其中 heap_4 作为主力实现逐函数走读。最后照例对照 ESP-IDF——在 ESP32 上这五个文件你一个都不会编到，`heap_idf.c` 把整个问题替换成了另一套体系（第二十章的主角）。

---

## 19.1 内核为什么自带堆：契约先行

### 1. 谁在消费内核堆

动态创建 API 全部依赖堆，这不是"可选优化"而是默认路径。以 Vanilla v10.5.1 源码为准：

- `tasks.c`：`xTaskCreate()` 走动态分配分支时，先 `pvPortMalloc(sizeof(TCB_t))` 拿 TCB，再 `pvPortMallocStack(...)` 拿任务栈（栈字节数按 `usStackDepth` 折算——注意 Vanilla 以字计、IDF 以字节计，见第一章暗线）；
- `queue.c`：`xQueueCreate()` 一次性 `pvPortMalloc(sizeof(Queue_t) + 存储区字节数)`，队列头和存储区是**一整块**内存（这是第十章"队列很省"的证据之一）；
- `event_groups.c`、`timers.c`、`stream_buffer.c`：事件组、软件定时器、流缓冲同理。

也就是说，只要用 `xTaskCreate` 而不是 `xTaskCreateStatic`，你的系统从第一条创建语句开始就在跑堆分配器。

### 2. 契约：portable.h 规定的七个函数

FreeRTOS 不直接规定"怎么分配"，只规定**端口层必须提供哪些符号**。`portable.h` 里的声明就是内核与堆实现之间的全部契约：

```c
void * pvPortMalloc( size_t xSize );                /* 分配；失败返回 NULL */
void * pvPortCalloc( size_t xNum, size_t xSize );   /* 分配并清零 */
void   vPortFree( void * pv );                      /* 释放；接受 NULL */
void   vPortInitialiseBlocks( void );               /* 遗留：BSS 未清零平台的初始化钩子 */
size_t xPortGetFreeHeapSize( void );                /* 当前剩余空闲字节 */
size_t xPortGetMinimumEverFreeHeapSize( void );     /* 历史最低剩余字节（水位线） */
void   vPortGetHeapStats( HeapStats_t * pxHeapStats ); /* 详细统计（v10.5.0 引入） */
```

此外还有 heap_5 专用的 `vPortDefineHeapRegions()`（见 19.6）和 `configSTACK_ALLOCATION_FROM_SEPARATE_HEAP` 开关（让任务栈走独立的 `pvPortMallocStack`/`vPortFreeStack`，默认关闭时它们就是 `pvPortMalloc`/`vPortFree` 的别名）。

### 3. 两个总开关

`FreeRTOS.h` 里控制内存形态的两个编译期开关（均给了默认值）：

| 宏                                 | 默认                   | 语义                                                                       |
| ---------------------------------- | ---------------------- | -------------------------------------------------------------------------- |
| `configSUPPORT_DYNAMIC_ALLOCATION` | 1                      | 允许动态分配。置 0 时 `heap_1~5.c` 全部 `#error` 拒绝编译，动态版 API 消失 |
| `configSUPPORT_STATIC_ALLOCATION`  | 0（Vanilla）/ 1（IDF） | 允许 `xTaskCreateStatic` 等静态版 API，应用自备内存                        |

两者不能同时为 0。全静态系统（航天、医疗认证常见要求）会把动态关掉，堆整个消失；本章讨论的是开启动态的世界。

### 4. 为什么不用 libc 的 malloc

三个理由，一个比一个实际：

1. **可能根本没有**。裸奔小 MCU 的工程常常不链接完整 libc，malloc 未必存在。
2. **线程安全是玄学**。newlib 的 malloc 靠 `__malloc_lock`/`__malloc_unlock` 钩子做线程安全，默认是空操作——你得自己接上内核锁，忘接就是偶发链表损坏。
3. **不可控、不可观测**。libc 堆的大小由链接脚本决定、位置不可指定、内部行为不可见。而内核堆是一个你可以放进特定 RAM 段的 `ucHeap[]` 数组，`xPortGetFreeHeapSize()` 让你在运行时看清水位。

于是内核自带五个参考实现，分层关系如下：

```text
   应用 / 内核对象创建
   xTaskCreate   xQueueCreate   xTimerCreate ...
        │
        ▼
   pvPortMalloc(n) / vPortFree(p)      ← portable.h 规定的契约
        │
        ▼
   ┌──────────────────────────────────────┐
   │ heap_1  heap_2  heap_3  heap_4  heap_5│  ← Vanilla: portable/MemMang/ 五选一
   └──────────────────────────────────────┘
        │  ESP-IDF：这一整层被替换
        ▼
   heap_idf.c → heap_caps_malloc(size, MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)
                （IDF heap 组件 → 第二十章）
```

> [!note] "参考实现"的含义
> FreeRTOS 官方把这五个文件定位为 **sample implementation**——它们同时是可用代码和教学材料。内核只认 `portable.h` 契约，你完全可以换成自研分配器（TLSF、pool allocator……），只要那几个函数符号对得上。ESP-IDF 干的正是这件事。

---

## 19.2 heap_1：只分配不释放的 bump allocator

### 1. 全部状态是一个下标

heap_1 是"水涨船高"分配器：整个堆是一个静态数组，一个游标记录分配到哪了。

```c
static uint8_t ucHeap[ configTOTAL_HEAP_SIZE ];   /* 堆本体 */
static size_t xNextFreeByte = 0;                  /* 全部状态就这一个变量 */
```

`pvPortMalloc()` 的核心逻辑三行：把请求大小向上对齐、检查剩余空间够不够、返回当前游标位置并把游标前推。首次调用时顺手把堆起点对齐到 `portBYTE_ALIGNMENT`（用一个 `static` 的 `pucAlignedHeap` 缓存对齐结果）。`vPortFree()` 则是一个 `configASSERT(pv == NULL)`——**释放非空指针直接断言炸掉**，因为这个分配器根本没有"还回去"的概念。

`configADJUSTED_HEAP_SIZE`（等于 `configTOTAL_HEAP_SIZE - portBYTE_ALIGNMENT`）给起点对齐可能损失的几个字节留了余量。

### 2. 性格：零碎片、O(1)、绝对确定

| 维度       | 表现                                     |
| ---------- | ---------------------------------------- |
| 时间复杂度 | O(1)，无遍历无合并                       |
| 碎片       | **不存在**——内存只会单调向前推进         |
| 确定性     | 分配耗时与历史完全无关，最适合硬实时路径 |
| 每块开销   | 无块头！只对齐请求大小，不藏任何元数据   |

### 3. 什么时候它就够了

答案出奇地常见：**初始化阶段创建全部对象、之后一个都不删**的系统。任务、队列、事件组在 `main()` 里一口气建好，固件跑一辈子直到断电——很多真实产品就是这么写的（官方也明确推荐"能不用释放就不用释放"）。这时：

- 不释放 ⇒ 没有碎片问题 ⇒ heap_2/4 的复杂度全是白给；
- 总内存消耗在启动后固定 ⇒ `configTOTAL_HEAP_SIZE` 直接就是预算上限，可静态核算。

反过来，只要代码里有一处 `vTaskDelete()` 或 `vQueueDelete()`（它们内部会 `vPortFree`），heap_1 就出局。另外注意 heap_1 连 `pvPortCalloc` 和 `xPortGetMinimumEverFreeHeapSize` 都没有提供——契约的最小子集。

---

## 19.3 heap_2：首次适应 + 分裂，无合并

heap_2 引入"空闲块链表"这个贯穿后面所有实现的核心结构，但选了一条简单路线：**释放时只挂回链表，不和邻居合并**。

### 1. 数据结构与链表组织

```c
typedef struct A_BLOCK_LINK
{
    struct A_BLOCK_LINK * pxNextFreeBlock;  /* 下一个空闲块 */
    size_t xBlockSize;                      /* 本块大小（含块头） */
} BlockLink_t;
```

heap_2 的空闲链表**按块大小升序**排（文件头注释写明 "in order of their size"；`pvPortMalloc` 里那句 "Blocks are stored in byte order" 是陈年过时注释，行为以插入逻辑为准）。链表头尾是两个静态变量 `xStart`、`xEnd`，其中 `xEnd.xBlockSize` 被填成 `configADJUSTED_HEAP_SIZE` 这样一个巨大值当**哨兵**——遍历寻找"第一个 ≥ 请求大小的块"时必然停在它身上。

在**尺寸升序**链表上找"第一个够大的"，效果等价于 **best-fit**（最合适匹配）：找到的必然是能容纳请求的最小块。

### 2. 分配：找块、摘链、分裂

`pvPortMalloc()` 的流程：

1. 请求大小加上块头 `heapSTRUCT_SIZE` 并向上对齐；
2. 从 `xStart` 遍历，找到第一个 `xBlockSize >= xWantedSize` 的空闲块（best-fit）；
3. 把该块从链表摘除，返回 `块首 + heapSTRUCT_SIZE`（块头藏在用户指针前面）；
4. **分裂**：若块比请求大出 `heapMINIMUM_BLOCK_SIZE`（两倍块头）以上，把尾部切出来作为一个新的小空闲块插回链表——避免"要 8 字节却切走 1KB"。

有个实现细节值得一看：heap_2 把 `prvInsertBlockIntoFreeList` 写成了**宏**而不是函数（源码注释明说 "STATIC FUNCTIONS ARE DEFINED AS MACROS TO MINIMIZE THE FUNCTION CALL DEPTH"）——上世纪 MCU 调用开销敏感时代的化石。

### 3. 无合并的代价：碎片化演示

释放的块原样挂回链表，不检查物理上相邻的块。后果用一组数字看清：

```text
heap_2 无合并的碎片化（数字为块大小，含块头）：

t0  [ A:100 已分配 ][ B:50 已分配 ][ C:100 已分配 ][ D:60 空闲 ]

t1  free(A)、free(C)：
    [ A:100 空闲 ][ B:50 已分配 ][ C:100 空闲 ][ D:60 空闲 ]
     空闲总量 = 260 字节

t2  malloc(150)：
    链表里最大的连续空闲块只有 100 → 返回 NULL
    明明剩 260 字节，却给不出 150 —— 这就是碎片（fragmentation）
```

同一场景换成 heap_4：`free(C)` 时发现 C 的尾部地址恰好是 D 的起始地址 → 合并成 160；`malloc(150)` 从合并块分裂成功。**这就是 heap_4 存在的全部理由**。官方文档现在的态度也是：heap_2 视为遗留方案，新设计用 heap_4（或 heap_5）。顺带一提，heap_2 起才有 `pvPortCalloc`，但水位线与详细统计（`xPortGetMinimumEverFreeHeapSize`、`vPortGetHeapStats`）仍是 heap_4 时代才补齐的能力。

---

## 19.4 heap_3：包一层系统 malloc

heap_3 最短，也最"省事"：自己不管理任何内存，把契约转发给编译器配套的 libc。

```c
void * pvPortMalloc( size_t xWantedSize )
{
    void * pvReturn;

    vTaskSuspendAll();
    {
        pvReturn = malloc( xWantedSize );
        traceMALLOC( pvReturn, xWantedSize );
    }
    ( void ) xTaskResumeAll();
    /* ... malloc failed hook ... */
    return pvReturn;
}
```

`vPortFree()` 同样是挂起调度器包住 `free()`。四个要点：

1. **线程安全从哪来**：来自 `vTaskSuspendAll()`/`xTaskResumeAll()` 这对括号——调度器挂起期间其他任务不可能挤进来调 malloc，于是即便 libc 的 malloc 本身非线程安全也没事（单核前提下）。这层包装是"用内核原语给非线程安全库上锁"的经典手法。
2. **堆本体在链接器手里**：heap_3 没有 `ucHeap[]`，`configTOTAL_HEAP_SIZE` 对它无意义，堆区域由链接脚本/启动文件提供（GCC 下典型是 `_sbrk` 扩展的那个 heap 段）。
3. **失去可观测性**：heap_3 **没有实现** `xPortGetFreeHeapSize`——libc 堆的内部它不知道。移植到 heap_3 的工程常常发现监控 API 突然链接不过，就是这个原因。
4. **适用场景**：平台 libc 又好又线程安全（或已被上述包装驯服）、且你想要 libc 堆的成熟优化时。比如宿主机模拟器上跑 FreeRTOS 测试，heap_3 是自然选择。

heap_3 的"包系统分配器"思路，正是 ESP-IDF 那个 `heap_idf.c` 的原型——只不过 IDF 包的不是 libc malloc，而是自己的 heap 组件（19.9 展开）。

---

## 19.5 heap_4 逐函数走读：主力实现

heap_4 = heap_2 的进化完全体：**地址序 first-fit + 分裂 + 相邻空闲块合并**。它是 Vanilla 文档钦定的默认推荐，也是理解所有"空闲链表分配器"的最佳教材。文件里五个函数：`prvHeapInit`、`pvPortMalloc`、`vPortFree`、`prvInsertBlockIntoFreeList`、`vPortGetHeapStats`，逐个过。

### 1. 块结构与内存布局

管理结构与 heap_2 相同的 `BlockLink_t`，但空闲链表改为**按地址升序**（合并必须知道物理邻居，地址序是前提）。关键常量：

```c
static const size_t xHeapStructSize =
    ( sizeof( BlockLink_t ) + ( portBYTE_ALIGNMENT - 1 ) ) & ~portBYTE_ALIGNMENT_MASK;

#define heapMINIMUM_BLOCK_SIZE    ( ( size_t ) ( xHeapStructSize << 1 ) )
```

- 32 位端口、`portBYTE_ALIGNMENT=8` 时：`sizeof(BlockLink_t)=8` → `xHeapStructSize=8`；
- **Xtensa 端口（ESP32）**：`portmacro.h` 里 `portBYTE_ALIGNMENT=16`（窗口 ABI 要求栈指针 16 字节对齐）→ `xHeapStructSize=16`，`heapMINIMUM_BLOCK_SIZE=32`。

一次分配的完整变形（以 8 字节对齐的 32 位端口为例）：

```text
分配前（空闲链表按地址序）：  xStart ──► [ A: 0xC0 字节 ] ──► pxEnd

pvPortMalloc(0x30)：
  ① 尺寸调整    0x30 + 8(块头) + 8(对齐余量) = 0x40
  ② first-fit   从最低地址遍历，找第一个 ≥ 0x40 的块 → 命中 A
  ③ 摘链 + 分裂 0xC0 - 0x40 = 0x80 ≥ heapMINIMUM_BLOCK_SIZE(0x10)
                → A 拆成 [已分配 0x40] + [新空闲块 0x80]
  ④ 标记        A.xBlockSize |= MSB；A.pxNextFreeBlock = NULL

分配后：                        xStart ──► [ 0x80 ] ──► pxEnd

        A 的内存布局（低地址 ───────────────► 高地址）：
        ┌────────────┬───────────────────┬───────────────┐
        │ BlockLink_t│  用户区 0x30 字节   │ 对齐垫 8 字节  │
        │ next=NULL  │                   │               │
        │ size=0x40  │ ← pvReturn 指这里  │               │
        │ (MSB=1)    │                   │               │
        └────────────┴───────────────────┴───────────────┘
        ← xHeapStructSize →←──── xBlockSize = 0x40 ──────→
```

三个技巧藏在这张图里：

- **块头藏身**：`BlockLink_t` 挤在用户内存正前方，`vPortFree(p)` 只需 `p -= xHeapStructSize` 就能找回元数据——不占额外全局结构，每个已分配块自描述；
- **对齐传递**：块首天然对齐、`xHeapStructSize` 本身是对齐值的倍数，所以 `pvReturn` 必然对齐（函数末尾的 `configASSERT` 就在验这一点，19.1 节 `tasks.c`/`queue.c` 里"pvPortMalloc 保证对齐"的注释依赖的正是这条性质）；
- **MSB 占用标志**：`xBlockSize` 的最高位（32 位 `size_t` 即 bit31）被征用为"已分配"标志。`heapBLOCK_ALLOCATED_BITMASK` 一族宏负责置位/清零/检查。代价是块大小实际只有 31 位有效——嵌入式堆摸不到 2GB，无所谓。

### 2. 为什么是地址序 first-fit

从**最低地址**开始找第一个能放下的块，而不是像 heap_2 那样找最小合适块。实践中地址序 first-fit 的碎片表现相当好：低地址的老块优先被复用，高地址的大块尽量保持完整。更重要的是**它和合并是绝配**——合并需要判断"物理上隔壁的块是不是空闲的"，这要求能按地址定位邻居，地址序链表让"邻居"天然就是链表里的前后项。

### 3. prvHeapInit()：xStart 与 pxEnd

首次 `pvPortMalloc()` 时惰性初始化（heap_4 用 `pxEnd == NULL` 判断首次，比 heap_2 的 `xHeapHasBeenInitialised` 布尔更省一个变量）：

1. 把 `ucHeap` 起点向上对齐；
2. `xStart.pxNextFreeBlock` 指向对齐后的堆首；
3. 在**堆尾部**放一个 `BlockLink_t` 当尾哨兵，全局指针 `pxEnd` 指向它：`xBlockSize=0`、`pxNextFreeBlock=NULL`；
4. 整个堆（扣除尾哨兵）作为一个大空闲块挂进链表；`xFreeBytesRemaining` 与 `xMinimumEverFreeBytesRemaining` 都初始化为这个尺寸。

对比 heap_2 的哨兵设计能看出演化：heap_2 的 `xEnd` 是个**变量**（藏在 .data 里，靠"size 巨大"拦住遍历）；heap_4 的 `pxEnd` 是**放在堆尾的标记块**（`size=0` 且 `next=NULL`，靠"next 为 NULL"终止遍历）。后者让"堆的边界"物理地存在于堆内，heap_5 的多区域扩展全靠这一点。

### 4. pvPortMalloc()：防御性编程范本

主流程（19.3 节第 2 小节的 ①~④）之外，值得学的是它层层设防的检查：

- `heapADD_WILL_OVERFLOW`：请求大小加块头是否会溢出 `size_t`——溢出则把请求归零，分配必然失败；
- `heapBLOCK_SIZE_IS_VALID`：确认调整后的尺寸没有碰到 MSB（否则占用标志没地方放）；
- 分裂前 `configASSERT` 新块地址对齐；
- 每条"不该走到"的分支都放一个 `mtCOVERAGE_TEST_MARKER()`，供官方覆盖率测试插桩。

统计更新也在成功路径上：`xFreeBytesRemaining` 扣减，若跌破历史最低则刷新 `xMinimumEverFreeBytesRemaining`，`xNumberOfSuccessfulAllocations` 自增。

### 5. vPortFree() 与 prvInsertBlockIntoFreeList()：合并的艺术

`vPortFree()` 先做双重验尸：

```c
configASSERT( heapBLOCK_IS_ALLOCATED( pxLink ) != 0 );   /* MSB 是"已分配"？ */
configASSERT( pxLink->pxNextFreeBlock == NULL );         /* next 仍是分配时置的 NULL？ */
```

两个标志联手排除了最常见的误用：**double free**（第一次 free 已清 MSB，第二次直接断言）和**释放野指针**（栈上/静态区的内存几乎不可能恰好两个标志都对）。之后可选地按 `configHEAP_CLEAR_MEMORY_ON_FREE` 清零用户区（安全敏感固件会用，默认 0），再挂起调度器调用合并插入。

`prvInsertBlockIntoFreeList(pxBlockToInsert)` 是全文件精华，四步：

```text
目标：把空闲块 B 插回地址序链表，并尽可能与邻居合并

 ① 定位：从 xStart 走到"地址恰好小于 B"的迭代器 I
 ② 前合并：若 I 的尾部地址 == B 的首地址（物理紧邻）
      I.size += B.size；B "消失"（B := I）
 ③ 后合并：若 B 的尾部地址 == I->next 的首地址
      B.size += I->next->size；B->next = I->next->next
      （特判 I->next == pxEnd：只改链接不吞哨兵的 size）
 ④ 链接：若 ② 已把 B 并进 I（I == B），什么都不做；
      否则 I->next = B
```

第 ④ 步的判空是这份代码最细腻的一处：当 B 同时与前驱、后继合并时，它的 `pxNextFreeBlock` 已在第 ③ 步设好，若无条件执行 `I->next = B` 会让链表成环（B 指向的块反过来指回 B）。源码注释里那个 "plugged a gab"（gap 的笔误）恰好标记着这个坑。

### 6. 统计与 vPortGetHeapStats()

heap_4 维护四个全局计数：`xFreeBytesRemaining`、`xMinimumEverFreeBytesRemaining`、`xNumberOfSuccessfulAllocations`、`xNumberOfSuccessfulFrees`。`vPortGetHeapStats()` 在此之上现场遍历空闲链表，填出 `portable.h` 定义的 `HeapStats_t`：最大/最小空闲块、空闲块个数、历史水位、成功分配/释放次数。注意源码里的锁用法分层——**遍历链表用 `vTaskSuspendAll()`，读四个计数器用 `taskENTER_CRITICAL()`**，为什么这么分，下一节正是答案。

> [!tip] 水位线的正确用法
> `xPortGetFreeHeapSize()` 是"现在"，`xPortGetMinimumEverFreeHeapSize()` 是"历史上最惨"。**容量规划永远看后者**：启动后跑完所有典型业务场景，水位线最低点就是你的安全余量基准，它不回升、只减不增，是免费的高水位标记（watermark）。

---

## 19.6 heap_5：多内存区域

heap_5 = heap_4 的分配器 + **堆可以由多个不连续的内存区域拼成**。MCU 地址空间碎片化的现实产物：内部 SRAM 的尾段、外挂 RAM 的映射窗口、留给堆的专用 DMA 区……它们地址不连续，heap_4 的单一 `ucHeap[]` 装不下。

### 1. 区域表：vPortDefineHeapRegions()

`portable.h` 定义了区域描述：

```c
typedef struct HeapRegion
{
    uint8_t * pucStartAddress;   /* 区域起始地址 */
    size_t xSizeInBytes;         /* 区域大小 */
} HeapRegion_t;
```

用法（官方示例的风格）：

```c
static const HeapRegion_t xHeapRegions[] =
{
    { ( uint8_t * ) 0x80000000UL, 0x10000 },   /* 区域 1：64KB */
    { ( uint8_t * ) 0x90000000UL, 0xa0000 },   /* 区域 2：640KB */
    { NULL, 0 }                                 /* 终止符，必须有 */
};

int main( void )
{
    vPortDefineHeapRegions( xHeapRegions );     /* 必须先于一切 pvPortMalloc */
    /* 从这里开始才能创建任务/队列/... */
}
```

三条铁律，源码里全有 `configASSERT` 把守：

1. **必须先调用**：`pvPortMalloc()` 开头就 `configASSERT(pxEnd)`，未初始化直接断言；
2. **只能调用一次**：`vPortDefineHeapRegions()` 开头 `configASSERT(pxEnd == NULL)`；
3. **区域必须按地址升序排列**：每个新区域处理时有 `configASSERT(xAddress > (size_t) pxEnd)` 检查。合并逻辑靠指针比较判断相邻性，乱序会静默破坏链表不变量。

### 2. 区域如何串成一条链

初始化对每个区域做一遍"迷你 prvHeapInit"：起点对齐 → 区域尾部放一个**区域尾标记**（`xBlockSize=0` 的 `BlockLink_t`）→ 整个区域作为一个大空闲块。关键一步是：**上一个区域的尾标记的 `pxNextFreeBlock` 指向下一个区域的首块**。最终形态：

```text
HeapRegion_t 表（地址升序）          初始化后的空闲链表：

 {R1 起址, R1 大小}    ┐            xStart ──► [R1 大空闲块] ──► [R1 尾标记]
 {R2 起址, R2 大小}    ┘                          │ (size=0，充当跨区链接)
 {NULL, 0}  ← 终止符                                ▼
                                             [R2 大空闲块] ──► [R2 尾标记] ──► NULL
                                                                    ▲
                                              全局 pxEnd 指向最后一个区域的尾标记
```

由此得到 heap_5 的两个行为特征：

- **first-fit 天然先用低地址区域**：分配顺序是 R1 优先耗尽、再用 R2——想控制"哪块内存先被用"，排区域表顺序即可；
- **跨区域永不合并**：合并的前提是物理地址连续，而区域之间地址断开（每个区域的"尾部"都隔着标记与空洞），地址序检查保证了不会误判相邻。一个微妙后果：区域交界处的碎片无法通过合并消除，区域边界本身是永久的碎片源。

顺带一提，`vPortGetHeapStats()` 在 heap_5 里对"最小空闲块"的统计专门跳过了 `xBlockSize == 0` 的块——就是那些区域尾标记，它们不是真块，只是链接件。

### 3. 五选一：heap_1~5 能力矩阵总表

五个实现全部走完，总表收拢（块头大小按 32 位端口计：8 字节对齐时 8 字节，Xtensa 16 字节对齐时 16 字节）：

| 能力                                | heap_1                | heap_2                 | heap_3      | heap_4                  | heap_5                                    |
| ----------------------------------- | --------------------- | ---------------------- | ----------- | ----------------------- | ----------------------------------------- |
| 支持释放                            | ✗（`vPortFree` 断言） | ✓                      | ✓           | ✓                       | ✓                                         |
| 相邻合并（抗碎片）                  | —（无碎片可言）       | ✗                      | 取决于 libc | ✓                       | ✓（区域内）                               |
| 分配策略                            | bump 递增             | best-fit（尺寸序链表） | libc malloc | first-fit（地址序链表） | 同 heap_4                                 |
| 堆内存来源                          | `ucHeap[]` 数组       | `ucHeap[]` 数组        | 链接器堆段  | `ucHeap[]` 数组         | 多个 `HeapRegion_t` 区域                  |
| 需显式初始化                        | 否                    | 否                     | 否          | 否                      | **是**（先调 `vPortDefineHeapRegions()`） |
| `xPortGetFreeHeapSize()`            | ✓                     | ✓                      | ✗           | ✓                       | ✓                                         |
| `xPortGetMinimumEverFreeHeapSize()` | ✗                     | ✗                      | ✗           | ✓                       | ✓                                         |
| `vPortGetHeapStats()`               | ✗                     | ✗                      | ✗           | ✓                       | ✓                                         |
| 定位                                | 全静态创建系统        | 遗留/教学              | 有好 libc   | **默认主力**            | 非连续内存                                |

选型一句话：能不释放就用 **heap_1**（最简单即最可靠）；要释放用 **heap_4**；内存不连续用 **heap_5**；heap_2/heap_3 基本只出现在维护老工程或宿主机模拟的场景里。

---

## 19.7 线程安全策略对比：挂调度器 vs 关中断

五个实现里凡是要动链表的，全部用 `vTaskSuspendAll()`/`xTaskResumeAll()` 包住，没有一处用 `taskENTER_CRITICAL()`。这是个值得停下来想清楚的设计决策。

### 1. 两种互斥手段的本质区别

| 手段                             | 挡住谁                   | 放过谁           | 代价                     |
| -------------------------------- | ------------------------ | ---------------- | ------------------------ |
| `taskENTER_CRITICAL()`（关中断） | 所有任务**和所有中断**   | 无人             | 中断延迟上升，实时性受损 |
| `vTaskSuspendAll()`（挂调度器）  | 所有**任务**（不再切换） | **中断照常响应** | 仅挡任务级并发           |

分配路径要遍历空闲链表——长度与碎片程度相关、**无上界**。若用关中断保护，一次碎片严重的分配能让中断延迟抖动到不可接受；挂调度器则只在"任务视角"上互斥，硬实时中断路径完全不受影响。

### 2. 这个选择的两个前提（也是两个限制）

**前提一：中断里绝不允许 malloc。** 挂起调度器挡不住 ISR——ISR 若也来 `pvPortMalloc()`，链表照样被并发踩坏。所以规则是铁的：`pvPortMalloc`/`vPortFree` 只能在任务上下文调用（FreeRTOS 文档对所有 heap_N 一视同仁地写明）。ISR 里要内存？预分配好，或者用队列把请求递给任务。

**前提二：单核。** `vTaskSuspendAll()` 挂起的是**当前核**的调度器，另一个核上的任务照样跑、照样调 malloc——单核世界里滴水不漏的互斥，到了 SMP 就成了筛子。

`vPortGetHeapStats()` 的混合用法现在能读懂了：遍历链表是长操作，用挂调度器避免长时间关中断；读四个计数器只是几条访存，用关中断拿一个一致快照即可（单核下两种手段都成立，如此分层更多是防御性写法的示范）。而 `xTaskResumeAll()` 恢复调度时若发现挂起期间有更高优先级任务就绪，会立刻触发切换——分配完顺手让贤，不浪费一个 tick。

> [!tip] Vanilla vs ESP-IDF：SMP 下谁保 heap 安全
> Vanilla heap_1~5 的线程安全**全部**建立在 `vTaskSuspendAll()` 的单核互斥上。IDF FreeRTOS 跑在双核 ESP32 上，`vTaskSuspendAll()` 只挂起当前核（第二十二章）——于是 `heap_idf.c` 转接到的 heap 组件**自带**基于 `portMUX` 自旋锁的按堆加锁，malloc 天然多核线程安全，这是 IDF 堆与 Vanilla heap_N 在并发模型上的根本分野（锁细节在第十八、二十章）。

---

## 19.8 malloc 失败钩子：vApplicationMallocFailedHook()

分配失败的两种命运：返回 NULL 让调用者处理，或者——如果你配置了钩子——进入应用提供的回调。

Vanilla 侧的机制：`FreeRTOSConfig.h` 里 `configUSE_MALLOC_FAILED_HOOK = 1`（`FreeRTOS.h` 默认为 0），然后实现这个函数（声明在 `portable.h`）：

```c
void vApplicationMallocFailedHook( void )
{
    /* 任务创建失败往往在这里被第一次发现 */
    taskDISABLE_INTERRUPTS();
    for( ;; );        /* 经典做法：记录现场后停机等待调试器/看门狗复位 */
}
```

三个实现细节：

1. **调用时机在 `xTaskResumeAll()` 之后**——钩子在调度器恢复之后、临界区之外执行，所以钩子里可以安全地打日志（printf 本身可能还要分配内存，注意别递归触发失败）；
2. heap_1~5 每个实现的 `pvPortMalloc()` 末尾都保留了这处调用，行为一致；
3. 最典型的触发场景：`xTaskCreate()` 返回 `errCOULD_NOT_ALLOCATE_REQUIRED_MEMORY`——栈给小了、任务建多了、或者堆已经碎了。

> [!tip] Vanilla vs ESP-IDF：IDF 上这个钩子是哑的
> 实读 `components/freertos/heap_idf.c`：它**不包含任何 `vApplicationMallocFailedHook()` 调用**；IDF 的 `FreeRTOSConfig.h` 也**没有定义** `configUSE_MALLOC_FAILED_HOOK`（默认 0）。在 ESP-IDF 里实现这个函数不会报错，但永远不会被内核堆调用——新手常见困惑点。替代物是 heap 组件的注册式回调，信息也更丰富（能拿到失败的大小和 caps）：
>
> ```c
> /* esp_heap_caps.h */
> typedef void (* esp_alloc_failed_hook_t)( size_t size, uint32_t caps,
>                                           const char *function_name );
> esp_err_t heap_caps_register_failed_alloc_callback( esp_alloc_failed_hook_t callback );
> ```
>
> 本章实验环节会实际触发它一次。

---

## 19.9 Vanilla vs IDF：heap_idf.c 桥接

照例收拢暗线。ESP-IDF 编译 FreeRTOS 组件时**不编任何 heap_N.c**，取而代之的是组件根目录的 `heap_idf.c`——一个不到一百行的转接层，把 `portable.h` 契约逐个映射到 heap 组件：

```c
/* heap_idf.c 的全部核心（节选自 v6.0.2） */
#define portFREERTOS_HEAP_CAPS    ( MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT )

void * pvPortMalloc( size_t xWantedSize )
{
    return heap_caps_malloc( xWantedSize, portFREERTOS_HEAP_CAPS );
}
void vPortFree( void * pv )                    { heap_caps_free( pv ); }
size_t xPortGetFreeHeapSize( void )
{
    return heap_caps_get_free_size( portFREERTOS_HEAP_CAPS );
}
size_t xPortGetMinimumEverFreeHeapSize( void )
{
    return heap_caps_get_minimum_free_size( portFREERTOS_HEAP_CAPS );
}
```

为什么是 `MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT`？文件头注释给了官方理由：任务栈、TCB、队列这些内核对象必须在 **cache 关闭时仍可访问**（flash 操作期间 cache 会被映射走），所以内核堆只能落在内部、可按字节访问的 RAM 里。用户想把大缓冲放外部 PSRAM？官方答案是"用静态创建 API 自己管理"，而不是放宽内核堆的 caps。

对照表：

| 维度                    | Vanilla（heap_1~5）                                      | ESP-IDF（heap_idf.c + heap 组件）                                                                                                                                                                                                                      |
| ----------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 实现文件                | `portable/MemMang/heap_N.c` 五选一                       | `components/freertos/heap_idf.c` 固定编入                                                                                                                                                                                                              |
| 堆的形状                | 静态数组 `ucHeap[configTOTAL_HEAP_SIZE]` 或区域表        | 系统全部内部 RAM 按能力位聚合，无独立"内核堆"                                                                                                                                                                                                          |
| `configTOTAL_HEAP_SIZE` | 定义堆大小                                               | **无意义**（配置不存在于 IDF FreeRTOSConfig.h）                                                                                                                                                                                                        |
| 算法                    | bump / best-fit / libc / first-fit+合并（按所选 heap_N） | heap 组件多分配器体系（第二十章）                                                                                                                                                                                                                      |
| 线程安全                | `vTaskSuspendAll()`（单核语义）                          | heap 组件内建 portMUX 自旋锁，多核安全                                                                                                                                                                                                                 |
| malloc 失败钩子         | `vApplicationMallocFailedHook()`                         | `heap_caps_register_failed_alloc_callback()`（带 size/caps 上下文）                                                                                                                                                                                    |
| 水位线语义              | `xMinimumEverFreeBytesRemaining`，单一堆                 | 各区域独立记录低水位再求和，是"最坏情形指示"而非全局精确最低点                                                                                                                                                                                         |
| 扩展校验                | 无                                                       | `xPortCheckValidListMem` / `xPortCheckValidTCBMem` / `xPortcheckValidStackMem`：内核校验 TCB/栈/链表节点必须落在内部可字节访问 RAM（`esp_ptr_internal()` && `esp_ptr_byte_accessible()`；开 `CONFIG_FREERTOS_TASK_CREATE_ALLOW_EXT_MEM` 后栈校验放宽） |

两个容易踩的语义差异：

1. **`xPortGetFreeHeapSize()` 的数字含义变了**。heap_4 里它是"专属内核堆剩多少"；IDF 里它是"全系统内部 8 位可用 RAM 总量"——包含了 lwIP、WiFi 之外所有还没被任何模块占用的内存。拿着 Vanilla 时代"`configTOTAL_HEAP_SIZE` 里还剩多少"的直觉来解读，会严重误判。
2. **IDF 的 `FreeRTOSConfig.h` 把 `configAPPLICATION_ALLOCATED_HEAP` 定为 1**——内核期待"应用（这里就是 heap 组件）自己提供堆内存"的正式声明，与 heap_idf.c 的转接互为表里。

至于 `FreeRTOS-Kernel/`（IDF 默认编入的 fork 树）与 `FreeRTOS-Kernel-SMP/`（实验性上游 Amazon SMP 内核）两棵树的选择——对堆这一层毫无影响：`heap_idf.c` 在组件根目录，两条路都过它。

---

## 19.10 实验：分配释放模式下的堆水位观察

在 QEMU 上把本章概念跑成数字。创建项目：

```bash
cd ~ && idf.py create-project freertos-ch19 && cd freertos-ch19
idf.py set-target esp32
```

`main/freertos-ch19.c` 整体替换为（直接用 heap 组件 API 观测，同时验证 heap_idf.c 的转接等价性）：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"

/* 与 heap_idf.c 的 portFREERTOS_HEAP_CAPS 相同的能力组合 */
#define WATCH_CAPS   ( MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT )

static void report( const char *tag )
{
    printf( "%-14s free=%7u  largest=%7u  min-ever=%7u\n",
            tag,
            ( unsigned ) heap_caps_get_free_size( WATCH_CAPS ),
            ( unsigned ) heap_caps_get_largest_free_block( WATCH_CAPS ),
            ( unsigned ) heap_caps_get_minimum_free_size( WATCH_CAPS ) );
}

/* heap 组件的分配失败回调（替代 Vanilla 的 vApplicationMallocFailedHook） */
static void alloc_failed_cb( size_t size, uint32_t caps, const char *function )
{
    printf( "[alloc-failed] %u bytes (caps=0x%x) refused in %s\n",
            ( unsigned ) size, ( unsigned ) caps, function );
}

static void dummy_task( void *arg )
{
    vTaskDelay( portMAX_DELAY );    /* 建完即删，实际跑不到这里 */
}

/* 实验一：创建/删除任务的标准分配释放模式 */
static void churn_task( void *arg )
{
    for ( int round = 1; round <= 3; round++ ) {
        TaskHandle_t h[ 10 ];
        for ( int i = 0; i < 10; i++ ) {
            xTaskCreate( dummy_task, "dummy", 2048, NULL, 1, &h[ i ] );
        }
        report( "created x10" );
        for ( int i = 0; i < 10; i++ ) {
            vTaskDelete( h[ i ] );          /* 摘链，内存等 Idle 回收（第 9 章） */
        }
        vTaskDelay( pdMS_TO_TICKS( 100 ) ); /* 让 Idle 任务有机会跑 */
        report( "deleted x10" );
    }
    vTaskDelete( NULL );
}

/* 实验二：隔块释放制造碎片，观察 free 与 largest 的分叉 */
static void frag_probe( void )
{
    enum { N = 48, SZ = 4096 };
    void *blk[ N ];

    for ( int i = 0; i < N; i++ ) {
        blk[ i ] = heap_caps_malloc( SZ, WATCH_CAPS );
    }
    report( "all alloc'd" );

    for ( int i = 0; i < N; i += 2 ) {      /* 释放偶数位：空闲块彼此被隔开 */
        heap_caps_free( blk[ i ] );
        blk[ i ] = NULL;
    }
    report( "half freed" );

    for ( int i = 1; i < N; i += 2 ) {      /* 全部释放：相邻合并应恢复大块 */
        heap_caps_free( blk[ i ] );
    }
    report( "all freed" );
}

void app_main( void )
{
    heap_caps_register_failed_alloc_callback( alloc_failed_cb );

    /* heap_idf.c 的转接等价性：两个数字应该完全一致 */
    printf( "xPortGetFreeHeapSize()    = %u\n", ( unsigned ) xPortGetFreeHeapSize() );
    printf( "heap_caps_get_free_size() = %u\n",
            ( unsigned ) heap_caps_get_free_size( WATCH_CAPS ) );

    frag_probe();

    /* 实验三：注定失败的大分配，触发失败回调 */
    void *big = heap_caps_malloc( 1 << 20, MALLOC_CAP_INTERNAL );    /* 1MB */
    printf( "1MB internal alloc -> %s\n", big ? "non-NULL" : "NULL" );

    xTaskCreate( churn_task, "churn", 3072, NULL, 5, NULL );
    /* app_main 返回后 main 任务自删（第 3 章） */
}
```

运行：

```bash
idf.py qemu monitor
```

典型输出形态（数值依固件配置而异，重点看**相对关系**）：

```text
xPortGetFreeHeapSize()    = 243128
heap_caps_get_free_size() = 243128        ← 同一个数：heap_idf.c 原样转接的证据
all alloc'd    free=  46232  largest=  39864  min-ever=  46232
half freed     free= 144824  largest=  44072  min-ever=  46232
all freed      free= 243016  largest= 241752  min-ever=  46232
[alloc-failed] 1048576 bytes (caps=0x800) refused in heap_caps_malloc
1MB internal alloc -> NULL
created x10    free= 182472  largest=  91736  min-ever= 182472
deleted x10    free= 243128  largest= 241752  min-ever= 182472
...
```

逐行解读，四个观察点全部对应本章内容：

1. **转接等价**：前两行数字相同——`xPortGetFreeHeapSize()` 在 IDF 上就是一次 `heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)`。
2. **碎片的可观测定义**：`half freed` 一行，`free` 回升到 144824，但 `largest` 只有 44072——**空闲总量与最大连续块的分叉就是碎片率的直接度量**（24 个 4KB 空闲洞被活块隔开，合并算法也无能为力，因为隔着的是已分配块不是空闲块）。`all freed` 后两者重新会合，说明相邻合并在释放全完成后把洞补平了——正是 19.5 节 `prvInsertBlockIntoFreeList()` 的现场效果。
3. **水位线只降不升**：整份输出里 `min-ever` 的最低值（182472，出现在 churn 轮次）永远不回升。容量规划用它：留多少余量，看业务最重时刻的水位（19.5 节的 tip）。
4. **失败回调带上下文**：`[alloc-failed]` 行给出了失败的大小、caps 和**拒绝点函数名**——比 Vanilla 的 `vApplicationMallocFailedHook()`（零参数）可诊断性强一档。另外注意：若 churn 里哪次 `xTaskCreate` 因为内存不足失败，这条回调也会响——一个钩子看住全系统。

真机对照：命令换成 `idf.py -p /dev/ttyUSB0 flash monitor`，代码零修改；带 PSRAM 的模组上可以把 `frag_probe` 的 caps 换成 `MALLOC_CAP_SPIRAM` 再跑一遍，观察外部 RAM 区域的独立水位线（多区域聚合语义，19.9 表格第三行）。想看更完整的堆画像，`heap_caps_print_heap_info(MALLOC_CAP_INTERNAL)` 会打印各区域摘要，`heap_caps_dump_all()` 则倾倒全部空闲块——后者输出量大，留给排查内存问题时用。

---

## 19.11 小结

- 内核堆的契约只有七个函数（`portable.h`），`configSUPPORT_DYNAMIC_ALLOCATION` 是总闸；所有动态创建 API（`xTaskCreate`/`xQueueCreate`/...）都压在 `pvPortMalloc` 上。
- **heap_1**：bump 分配器，O(1)、零碎片、无块头；"初始化建齐、永不删除"的系统它就是最优解。**heap_2**：尺寸序链表 best-fit + 分裂、无合并，碎片无解，已属遗留。**heap_3**：挂起调度器包住 libc malloc，堆归链接器、失去可观测性。**heap_4**：地址序 first-fit + 分裂 + 相邻合并，主力实现。**heap_5**：heap_4 + 多区域表（`HeapRegion_t` 地址升序、`{NULL,0}` 收尾、先于一切分配调用）。
- heap_4 的三件宝：**块头藏身**（`BlockLink_t` 挤在用户内存前）、**MSB 占用标志**（与 `pxNextFreeBlock==NULL` 组成 double-free 防线）、**地址序链表**（让合并就是看链表前后项）。水位线统计 `xMinimumEverFreeBytesRemaining` 是容量规划的基准。
- 线程安全全部靠 `vTaskSuspendAll()`：挡任务不挡中断（ISR 禁止 malloc），且只在单核下成立——IDF 的 heap 组件用自旋锁自己解决了多核问题。
- Vanilla 的 `vApplicationMallocFailedHook()` 在 IDF 上是哑的；替代物 `heap_caps_register_failed_alloc_callback()` 带失败大小/caps/函数名上下文。
- ESP-IDF 不编任何 heap_N：`heap_idf.c` 把契约转接到 heap 组件的 `MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT` 池，`xPortGetFreeHeapSize()` 的语义随之从"专属内核堆余量"变为"全系统内部 RAM 余量"。

下一章跨过 `heap_idf.c` 这座桥，进入 ESP-IDF heap 组件本体：多内存区域（DRAM/IRAM/RTC/PSRAM）如何按 caps 聚合成一个分配面、`multi_heap` 的内部结构、`heap_caps_malloc` 的能力位匹配算法，以及"同一块 RAM 既能当执行区又能当数据区"的魔法是怎么实现的。第二十一章再回到任务栈与链接布局，把 Part V 收拢。
