---
title: "FreeRTOS 深度解析（二十）：ESP-IDF 堆组件与内存 caps"
date: 2026-08-26
description: "跨过 heap_idf.c 桥进入 ESP-IDF heap 组件本体：ESP32 异构内存（DRAM/D/IRAM/RTC/SPIRAM）为什么必须按能力位路由；MALLOC_CAP_* 语义与区域×能力矩阵；heap_t 注册表与 heap_caps_malloc 的匹配算法；multi_heap 抽象与 TLSF 两级位图分配器；malloc 默认策略与 SPIRAM 迁移、cache 惩罚；堆调试工具链（水位/污染检测/追踪）；QEMU 实验打印各 cap 余量并故意触发错 cap 分配失败。"
tags: [freertos, rtos, esp32, esp-idf, heap, memory, tlsf, spiram, dma]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 20. **第二十章：ESP-IDF 堆组件与内存 caps**

# FreeRTOS 深度解析（二十）：ESP-IDF 堆组件与内存 caps

上一章结尾，`heap_idf.c` 把 `pvPortMalloc()` 转接给了 `heap_caps_malloc(size, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)`，然后话题戛然而止——那个函数背后的整个体系，就是本章。ESP-IDF 的 heap 组件回答的是一个 Vanilla FreeRTOS 从来不用面对的问题：**当你的 SoC 里有五种脾气不同的 RAM，"给我一块内存"这个请求该怎么接？** 答案是一套三层结构：能力位（caps）描述请求、注册表（`heap_t` 链表）描述供给、multi_heap/TLSF 在每个区域里做真正的分配。本章自顶向下把三层全部拆开，最后照例用 QEMU 亲眼看看各能力位的余量和"故意要错内存"时系统的反应。

---

## 20.1 桥的另一端：回顾 heap_idf.c

[[ch19-heap-allocators-comparison|第十九章]] 19.9 节已经给过 `heap_idf.c` 的源码，这里只强调三个后续要用到的事实：

### 1. 内核堆是 caps 的一个切片

```c
/* components/freertos/heap_idf.c（v6.0.2） */
#define portFREERTOS_HEAP_CAPS    ( MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT )

void * pvPortMalloc( size_t xWantedSize )
{
    return heap_caps_malloc( xWantedSize, portFREERTOS_HEAP_CAPS );
}
```

IDF 里**不存在独立的"FreeRTOS 堆"**。TCB、任务栈、队列、定时器……所有内核对象与 lwIP、你的应用缓冲区共享同一个按 caps 组织的分配面。文件头注释写明了为什么 caps 是这两位：内核对象必须在 **cache 关闭时仍可访问**（擦写 flash 期间 cache 会被禁用），所以只能落在内部、可按字节访问的 RAM。

### 2. 校验函数也在桥上

`heap_idf.c` 还实现了三个 Vanilla 没有的扩展：`xPortCheckValidListMem()` / `xPortCheckValidTCBMem()` / `xPortcheckValidStackMem()`——内核在关键路径上用它们校验链表节点、TCB、任务栈确实落在 `esp_ptr_internal() && esp_ptr_byte_accessible()` 的内存里（开了 `CONFIG_FREERTOS_TASK_CREATE_ALLOW_EXT_MEM` 后栈的校验放宽）。这是"内存有能力之分"这个事实向内核层的直接渗透。

### 3. malloc() 也在同一栋楼里

ESP-IDF 干的另一件事是把 libc 的 `malloc`/`free` 一并改写（`components/esp_libc/src/heap.c`）：

```c
void* malloc(size_t size)  { return heap_caps_malloc_default(size);  }
void  free(void *ptr)      { heap_caps_free(ptr);                    }
```

newlib 自带的堆分配器彻底不参与链接（同文件把 `malloc_trim`、`mallinfo` 等做成了无功能桩，防止 newlib 堆被链进来）。所以在 ESP32 上，**`malloc()`、`pvPortMalloc()`、`heap_caps_malloc()` 三条路最终汇入同一个多堆体系**——这与 Vanilla 世界"`malloc` 归 libc、`pvPortMalloc` 归 heap_N"的两张皮结构完全不同。

---

## 20.2 为什么需要 caps：ESP32 的内存不是一块

heap 组件源码的第一段注释就是动机：

> ESP32 has RAM that's slightly heterogeneous. Some RAM can be byte-accessed, some allows only 32-bit accesses, some can execute memory...——`heap_caps.c` 文件头

### 1. 五种脾气不同的 RAM

ESP32 名义上 520KB SRAM，但物理上被总线切成了几类性质不同的区域（地址细节见[[ch2-esp32-xtensa-architecture|第二章]]）：

| 内存                   | 地址（数据面）              | 容量   | 关键特性                                                                                                    |
| ---------------------- | --------------------------- | ------ | ----------------------------------------------------------------------------------------------------------- |
| DRAM（D-port 专用）    | `0x3FFAE000 ~ 0x3FFE0000`   | ~200KB | 可字节访问、可 DMA，**不可执行**                                                                            |
| D/IRAM（I/D 分时复用） | `0x3FFE0000 ~ 0x40000000`   | 128KB  | 同一块物理 SRAM 有两个地址别名：D-bus 侧可作数据、I-bus 侧（`0x400A0000 ~ 0x400C0000`，**地址倒序**）可执行 |
| IRAM（I-port 专用）    | `0x40070000 ~ 0x400A0000`   | 192KB  | 可执行，但**只能 32 位对齐访问**（当 8bit 数据用会崩）                                                      |
| RTC Fast RAM           | `0x3FF80000`                | 8KB    | 深睡保持、cache 关了也在；可执行                                                                            |
| RTC Slow RAM           | `0x50000000`                | 8KB    | 深睡保持，**不在主地址总线**，只归 ULP 协处理器/RTC——从不入堆                                               |
| 外部 SPIRAM            | `0x3F800000` 起（MMU 映射） | 0~16MB | 大而便宜，但走 cache、**DMA 不可直达**、cache 关闭即消失                                                    |

### 2. 三条硬约束

这些差异不是软件偏好，是硬件红线：

1. **DMA 只认内部 DRAM**。ESP32 的 DMA 控制器挂在内部总线上，SPIRAM 的数据要经过 cache 映射才能被 CPU 看到，DMA 描述符和缓冲区放 SPIRAM 会直接总线错误。这是嵌入式新手把 `malloc()` 的指针喂给 SPI 外设时翻车的第一现场（在启用 SPIRAM 的板子上）。
2. **执行必须走 I-bus**。取指只发生在 IRAM 与 D/IRAM 的 IRAM 别名上。把函数放 DRAM 地址执行，等来的只有非法指令异常——中断处理函数必须在 IRAM（flash 操作期间 cache 不可用），也是同一条约束的推论。
3. **cache 关闭时只有内部 RAM 存活**。擦写 flash 时整个 flash cache（连同映射进来的 SPIRAM、rodata）暂时不可用；这期间还要运行的代码和数据（内核对象、ISR、flash 操作自身的缓冲）必须留在内部。

### 3. 结论：分配器必须按能力路由

一张静态地图解决不了问题：同一块 D/IRAM，既可能被"要执行的代码"要走，也可能被"要 DMA 的数据"要走，还可能是普通数据兜底的最后一块。所以 IDF 的选择是把**内存的属性做成请求参数**——`malloc` 不再是"给我 N 字节"，而是"给我 N 字节**能 DMA 的**/**能执行的**/**掉电也在的**"。这就是 caps。

---

## 20.3 caps 语义与区域×能力矩阵

### 1. 能力位：一个 32 位位域

`components/heap/include/esp_heap_caps.h` 里的定义（ESP32 常用项）：

| 能力位                 | 值      | 语义                                                                  |
| ---------------------- | ------- | --------------------------------------------------------------------- |
| `MALLOC_CAP_EXEC`      | `1<<0`  | 可执行（I-bus 可达）                                                  |
| `MALLOC_CAP_32BIT`     | `1<<1`  | 允许 32 位对齐访问（IRAM 只有这个，不能按字节读写）                   |
| `MALLOC_CAP_8BIT`      | `1<<2`  | 允许 8/16 位访问——`char*`/`memcpy` 的前提                             |
| `MALLOC_CAP_DMA`       | `1<<3`  | DMA 可达                                                              |
| `MALLOC_CAP_SPIRAM`    | `1<<10` | 必须在外部 SPI RAM                                                    |
| `MALLOC_CAP_INTERNAL`  | `1<<11` | 必须内部（cache 关闭仍存活）                                          |
| `MALLOC_CAP_DEFAULT`   | `1<<12` | "普通 malloc 可返回的内存"                                            |
| `MALLOC_CAP_IRAM_8BIT` | `1<<13` | IRAM 且可字节访问（需 `CONFIG_ESP32_IRAM_AS_8BIT_ACCESSIBLE_MEMORY`） |
| `MALLOC_CAP_RTCRAM`    | `1<<15` | RTC Fast RAM                                                          |

caps 是**按位与组合**的：`heap_caps_malloc(n, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL)` 意思是"要一块同时满足两位的内存"。

### 2. 供给侧：每种内存类型的优先级档

请求有了位域，供给侧怎么描述？`components/heap/port/esp32/memory_layout.c` 给每种内存类型一个**最多三档的优先级 caps 数组**——每一档是该类型"愿意以什么身份被分配"：

```c
/* port/esp32/memory_layout.c（节选，v6.0.2） */
const soc_memory_type_desc_t soc_memory_types[] = {
    // Type 0: 纯 D-port RAM
    [SOC_MEMORY_TYPE_DRAM]   = { "DRAM",   { MALLOC_CAP_8BIT|MALLOC_CAP_DEFAULT,
                                             MALLOC_CAP_INTERNAL|MALLOC_CAP_DMA|MALLOC_CAP_32BIT, 0 }},
    // Type 1: 有 I-port 别名的 D-port RAM
    [SOC_MEMORY_TYPE_DIRAM]  = { "D/IRAM", { 0,
                                             MALLOC_CAP_DMA|MALLOC_CAP_8BIT|MALLOC_CAP_INTERNAL|MALLOC_CAP_DEFAULT,
                                             MALLOC_CAP_32BIT|MALLOC_CAP_EXEC }},
    // Type 2: IRAM
    [SOC_MEMORY_TYPE_IRAM]   = { "IRAM",   { MALLOC_CAP_INTERNAL|MALLOC_CAP_EXEC|MALLOC_CAP_32BIT, 0, 0 }},
    // Type 3: 外部 SPI RAM
    [SOC_MEMORY_TYPE_SPIRAM] = { "SPIRAM", { MALLOC_CAP_SPIRAM|MALLOC_CAP_DEFAULT,
                                             0,
                                             MALLOC_CAP_8BIT|MALLOC_CAP_32BIT }},
    // Type 4: RTC Fast RAM（需 CONFIG_ESP_SYSTEM_ALLOW_RTC_FAST_MEM_AS_HEAP）
    [SOC_MEMORY_TYPE_RTCRAM] = { "RTCRAM", { MALLOC_CAP_RTCRAM,
                                             MALLOC_CAP_8BIT|MALLOC_CAP_DEFAULT,
                                             MALLOC_CAP_INTERNAL|MALLOC_CAP_32BIT|MALLOC_CAP_EXEC }},
};
```

展开成**区域×能力矩阵**（这就是本章第一张必收的表）：

| 内存类型（ESP32 实际区域）     | prio 0：优先以这个身份给  | prio 1：退一步的身份            | prio 2：最后的身份      |
| ------------------------------ | ------------------------- | ------------------------------- | ----------------------- |
| DRAM（`0x3FFAE000+`，~200KB）  | 8BIT + DEFAULT            | INTERNAL + DMA + 32BIT          | —                       |
| D/IRAM（`0x3FFE0000+`，128KB） | **—**（普通数据不来碰它） | DMA + 8BIT + INTERNAL + DEFAULT | 32BIT + EXEC            |
| IRAM（`0x40070000+`，192KB）   | INTERNAL + EXEC + 32BIT   | —                               | —                       |
| SPIRAM（MMU 映射区）           | SPIRAM + DEFAULT          | —                               | 8BIT + 32BIT            |
| RTCRAM（8KB）                  | RTCRAM                    | 8BIT + DEFAULT                  | INTERNAL + 32BIT + EXEC |

读法：请求先扫所有区域的 **prio 0** 档，没人接再扫 **prio 1**、**prio 2**。于是产生了几条立刻能用的推论：

- **普通 `malloc()`（DEFAULT|INTERNAL）先吃纯 DRAM，吃光后才动 D/IRAM，永远不碰 IRAM**（IRAM 的任何一档都不含 DEFAULT）——这保护了稀缺的可执行内存；
- **`MALLOC_CAP_EXEC` 先吃纯 IRAM，再吃 D/IRAM 的 IRAM 别名**；
- **`MALLOC_CAP_DMA` 的供给面 = 全部 DRAM + D/IRAM**（两类的某一档都有 DMA），所以内部 RAM 几乎总能满足 DMA 请求，除非被 static 数据占满。

> [!note] DEFAULT 不是"随便"
> `MALLOC_CAP_DEFAULT` 的准确定义是"**允许被无能力要求的分配（malloc/calloc）返回**"。它是路由的过滤器之一，不是"忽略其他位"的意思——`heap_caps_malloc(n, MALLOC_CAP_DEFAULT)` 匹配的正是 DRAM→D/IRAM→SPIRAM→RTCRAM 这些在某一档挂着 DEFAULT 的类型。

---

## 20.4 注册表与路由：`heap_t` 与 `registered_heaps`

### 1. 启动时把物理地图翻译成堆链表

`heap_caps_init.c` 的 `heap_caps_init()`（由 `ESP_SYSTEM_INIT_FN(init_heap, ...)` 在系统初始化早期调用）做四件事：

1. `soc_get_available_memory_regions()` 拿到"扣除保留区后的可用区域表"——保留区包括 ROM 数据、cache、静态 data/bss（`_data_start~_heap_start`）、已占用的 IRAM（`_iram_start~_iram_end`）、tracemem 等；
2. **合并（coalesce）**相邻且同类型的区域——20.2 表里那一长串 8KB/32KB 的"pool"在物理上连续，合并后 `0x3FFAE6E0~0x3FFE0000` 成一整块 DRAM。这也是启动日志里每个类型只有寥寥几行的原因：
   ```text
   I (75) heap_init: Initializing. RAM available for dynamic allocation:
   I (82) heap_init: At 3FFAE6E0 len 00001920 (6 KiB): DRAM
   I (90) heap_init: At 3FFB2B6C len 0002D494 (181 KiB): DRAM
   I (97) heap_init: At 3FFE4350 len 0001BCB0 (111 KiB): D/IRAM
   I (104) heap_init: At 4007C210 len 00003DF0 (15 KiB): IRAM
   ```
   （数字随固件大小与配置浮动；`D/IRAM` 行被扣掉了 ROM 启动栈。）
3. 每个合并后的区域注册成一个**堆**：`multi_heap_register()` 在区域头部建立分配器（20.5 节），记录进 `heap_t`；
4. 所有 `heap_t` 按**区域大小升序**插入全局单链表 `registered_heaps`——注释写明用意：同能力的多个堆，小请求先消耗小堆，"把大块的连续内存留到最后"。

注册表条目的形状（`heap_private.h`）：

```c
typedef struct heap_t_ {
    uint32_t caps[SOC_MEMORY_TYPE_NO_PRIOS];  /* 三档能力，从类型表拷贝 */
    intptr_t start, end;                      /* 本堆的地址范围 */
    multi_heap_lock_t heap_mux;               /* 本堆自己的自旋锁 */
    multi_heap_handle_t heap;                 /* multi_heap/TLSF 实例 */
    SLIST_ENTRY(heap_t_) next;                /* registered_heaps 链 */
} heap_t;
```

两个细节值得停下来：

- **启动栈区域延后注册**。`startup_stack` 标记的区域（D/IRAM 里 ROM 放临时栈的那部分）此时 `heap=NULL` 先挂账，调度器启动后再由 `heap_caps_enable_nonos_stack_heaps()` 补注册——堆元数据可以安全落进去的前提是 ROM 栈已经没人用了。
- **SPIRAM 是后来者**。`esp_psram.c` 的初始化函数在 heap 初始化之后运行（init 优先级 103 对 100），把 PSRAM 经 MMU 映射出的区域用 `heap_caps_add_region_with_caps()` 插进链表。运行时也能这么加堆——`heap_caps_add_region()` 对外开放，下一节的实验会看到它被用于"DMA 保留池"。

### 2. 路由算法：heap_caps_malloc 的匹配循环

所有 `heap_caps_*alloc*` 家族最终汇入 `heap_caps_base.c` 的 `heap_caps_aligned_alloc_base()`。剥掉对齐与记账的外壳，核心是这段（注释为本文所加）：

```c
/* heap_caps_base.c: heap_caps_aligned_alloc_base() 主循环（节选） */
for (int prio = 0; prio < SOC_MEMORY_TYPE_NO_PRIOS; prio++) {
    heap_t *heap;
    SLIST_FOREACH(heap, &registered_heaps, next) {      /* 链表按堆大小升序 */
        if (heap->heap == NULL) continue;
        if ((heap->caps[prio] & caps) != 0 &&           /* ① 本档沾边 */
            (get_all_caps(heap) & caps) == caps) {      /* ② 三档并集覆盖全部请求位 */
            ret = aligned_or_unaligned_alloc(heap->heap, size, ...);
            if (ret != NULL) { /* 记账、设置块 owner、返回 */ return ret; }
        }
    }
}
return NULL;   /* 全链扫完仍失败 → 上层 heap_caps_malloc() 调失败钩子 */
```

两个匹配条件缺一不可：①保证这个堆**在这一档**愿意提供某种被请求的能力；②保证请求的**每一个**能力位都被这个堆的三档并集覆盖（否则会分到一块缺某项能力的内存）。外层 `prio` 循环在内层整条链都失败后才推进——这正是 20.3 矩阵"先吃谁、再吃谁"的实现。

进入循环前的三道预处理同样重要：

1. **尺寸卫兵**：`size` 超过 `SOC_MAX_CONTIGUOUS_RAM_SIZE` 直接 NULL（防 `start+size` 回绕）；
2. **EXEC 特判**：请求含 `MALLOC_CAP_EXEC` 时，若同时要求 8BIT 或 DMA **立即返回 NULL**（能执行的区域按字节访问/可 DMA 在 ESP32 上是硬件矛盾——软件知道路由不出结果，不去白跑）；同时补上 `MALLOC_CAP_32BIT`；
3. **32BIT 取整**：请求 32BIT 时 `size` 向上对齐到 4 字节（IRAM 只能整字访问）。

### 3. D/IRAM 别名：一块 RAM 两个地址的魔法

请求 `MALLOC_CAP_EXEC` 而纯 IRAM 已满时，路由会落到 D/IRAM 区域——但 I-bus 看到的地址和 D-bus 不同且**顺序相反**（DRAM 最低地址对应 IRAM 最高地址）。`dram_alloc_to_iram_addr()` 负责翻译，并把原始 DRAM 地址**藏在返回指针的前一个字**里：

```text
  D/IRAM 物理块（以 DRAM 视角分配，地址 dstart）:
  ┌────────────┬─────────────────────────────┐
  │ dstart     │  ...分配出的 size+4 字节...  │
  └────────────┴─────────────────────────────┘
   ↑ *iptr = dstart（DRAM 地址存进 IRAM 侧首字）
   IRAM 视角返回值 = iram_alias(iptr) + 4

  heap_caps_free() 时: ptr[-1] 取回 DRAM 地址 → 用它回到 D-bus 侧正常释放
```

`heap_caps_free()` 里那段 `dramAddrPtr[-1]` 的还原逻辑就是这张图的另一半。一次 `MALLOC_CAP_EXEC` 分配的真实代价是 4 字节别名开销，换来的是同一块 SRAM 在"数据"与"代码"两种身份间按需腾挪。

### 4. 一图收拢全路由

```text
  malloc()/calloc()          pvPortMalloc()                heap_caps_malloc(n, caps)
        │                          │                                │
        ▼                          ▼                                │
  heap_caps_malloc_default    heap_caps_malloc(INTERNAL|8BIT) ◄──────┘
        │                          │
        │   (可选的三级策略, 见 20.6) │
        ▼                          ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │            heap_caps_aligned_alloc_base(align=4, size, caps)     │
  │  ① 尺寸卫兵  ② EXEC×(8BIT|DMA) 矛盾→NULL  ③ 32BIT 取整          │
  └───────────────────────────┬──────────────────────────────────────┘
                              ▼
        for prio = 0 → 2:  for heap in registered_heaps（按大小升序）:
            heap->caps[prio] 沾边  &&  三档并集 ⊇ 请求
                              │ 命中
                              ▼
                  multi_heap_malloc(heap->heap, size)     ← 每堆独立 portMUX 锁
                              │
        ┌─────────────────────┴────────────────────┐
        ▼                                          ▼
   普通/数据区域                            D/IRAM 的 EXEC 路径
   直接返回 DRAM 指针                       dram_alloc_to_iram_addr() 别名翻译
```

---

## 20.5 分配器本体：multi_heap 抽象 + TLSF

路由层只决定"去哪个堆要"，真正切分内存的是每个 `heap_t` 里挂着的 `multi_heap` 实例。

### 1. 三层分工

```text
heap_caps.c / heap_caps_base.c    路由层：caps 匹配、别名翻译、失败钩子、统计聚合
        │
multi_heap.c                      单堆抽象：锁、free_bytes/minimum_free_bytes 记账、
        │                         污染检测挂接、块遍历（walk/check/dump）
        │
tlsf.c（espressif/tlsf 子模块）   算法层：Two-Level Segregated Fit，O(1) malloc/free
```

一个可选的变体：`CONFIG_HEAP_TLSF_USE_ROM_IMPL`（默认 y，支持的目标上）把 TLSF 换成 ROM 里烧录的实现，省回 IRAM——代价是拿不到 IDF 侧的修复与调试符号。

### 2. multi_heap_register：一个区域的内存布局

`multi_heap_register()` 在区域起点依次放置控制结构：

```text
  区域 start                                                start+size
  ├──────────┬──────────────────────┬────────────────────────┤
  │ multi_   │ TLSF control         │ TLSF pool（实际分配区） │
  │ heap_info│ (fl/sl 位图+指针表)  │  首尾哨兵块夹住         │
  └──────────┴──────────────────────┴────────────────────────┘
   free_bytes / minimum_free_bytes      tlsf_size()           tlsf_add_pool()
```

`multi_heap.c` 的 `multi_heap_malloc_impl()` 在 TLSF 之上只做簿记：

```c
/* multi_heap.c（节选） */
multi_heap_internal_lock(heap);                 /* 每堆独立 portMUX */
void *result = tlsf_malloc(heap->heap_data, size);
if (result) {
    heap->free_bytes -= tlsf_block_size(result);   /* 含块头的完整块尺寸 */
    heap->free_bytes -= tlsf_alloc_overhead();
    if (heap->free_bytes < heap->minimum_free_bytes)
        heap->minimum_free_bytes = heap->free_bytes;  /* 低水位线 */
}
multi_heap_internal_unlock(heap);
```

每堆一把 `portMUX_TYPE` 自旋锁（`multi_heap_platform.h` 注释直说原因："malloc/free 可能发生在 ISR 里，所以必须用 portmux 自旋锁而不是 RTOS 互斥量"），锁粒度是**单堆**——两个核同时在 DRAM 堆和 IRAM 堆上分配互不阻塞。对照 Vanilla heap_4 的 `vTaskSuspendAll()`（挡任务不挡中断、单核语义，见[[ch19-heap-allocators-comparison|第十九章]] 19.7），这是 SMP 世界的正确答案。

### 3. TLSF：两级 segregated 位图

`tlsf.c` 的核心数据结构是两级位图加指针矩阵：

```c
/* tlsf.c（节选） */
typedef struct control_t {
    block_header_t block_null;              /* 哨兵 */
    unsigned int   fl_bitmap;               /* 一级：哪些 FL 行非空 */
    unsigned int   sl_bitmap[FL_INDEX_COUNT];/* 二级：行内哪些列非空 */
    block_header_t* blocks[FL_INDEX_COUNT][SL_INDEX_COUNT]; /* 空闲块链头 */
} control_t;
```

- 尺寸按 **first level = 2 的幂区间、second level = 再均分 32 档**编码（`SL_INDEX_COUNT_LOG2=5`，`FL_INDEX_SHIFT=7`）。例如 132~260 字节的请求都会落到同一格；
- `malloc`：由请求尺寸算出 (fl, sl) → `sl_bitmap[fl]` 里 `ffs` 找本行够大的列，没有则 `fl_bitmap` 里 `fls` 上跳一行（**good-fit**，不是严格 best-fit）→ 摘链、必要时分裂。两次位扫描 + 一次链表摘除，**O(1)**；
- `free`：写回块头、与物理相邻空闲块合并、挂回 (fl,sl) 格。同样 O(1)；
- 与 heap_4 的地址序 first-fit 相比：分配时间不随碎片数量增长（heap_4 最坏要扫整条空闲链），合并仍然完整保留。代价是控制结构常驻（位图 + 指针表）与"按对数桶分级"带来的轻微内部碎片——对 RTOS 场景是划算的交换。

块的元数据沿用"头部藏身"的老把戏，只是更紧凑：`block_header_t` 的 `prev_phys_block` 指针 + 带 2 个状态位的 `size` 字段共 8 字节（32 位平台），空闲块的 `next_free/prev_free` 与用户数据**重叠存放**，分配后即被覆盖。

---

## 20.6 malloc 的默认策略与 SPIRAM

### 1. heap_caps_malloc_default：一条带三档回退的决策链

`malloc()` 最终落到 `heap_caps.c` 的 `heap_caps_malloc_default()`。它的行为由一个静态变量 `malloc_alwaysinternal_limit` 分成两态：

```text
  malloc(size)
     │
     ├─ limit == -1（默认，未启用 SPIRAM malloc）
     │      → heap_caps_malloc(size, DEFAULT | INTERNAL)      ← 纯内部，永不碰 SPIRAM
     │
     └─ limit >= 0（heap_caps_malloc_extmem_enable(L) 已调用）
            ├─ size <= L  →  先试 DEFAULT | INTERNAL
            ├─ size >  L  →  先试 DEFAULT | SPIRAM
            └─ 失败再放宽 →  DEFAULT（内外不限，哪里有空去哪里）
```

### 2. SPIRAM 的接入点与 Kconfig

PSRAM 初始化后（`esp_psram.c`），两个动作决定它成为什么样的资源：

- `esp_psram_extram_add_to_heap_allocator()`：把映射出的 SPIRAM 区域 `heap_caps_add_region_with_caps()` 进注册表——从此 `MALLOC_CAP_SPIRAM` 有供给；
- 若选了 `SPIRAM_USE_MALLOC`，紧接着 `heap_caps_malloc_extmem_enable(CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL)` 把上文的 limit 设起来——从此普通 `malloc()` 也可能返回 SPIRAM 指针。

三种使用模式（`Kconfig.spiram.common` 的 `SPIRAM_USE` choice，默认 `SPIRAM_USE_MALLOC`）：

| 模式                    | malloc() 会不会返回 SPIRAM                | 典型用法                 |
| ----------------------- | ----------------------------------------- | ------------------------ |
| `SPIRAM_USE_MEMMAP`     | 永不                                      | 自己 mmap 管理一块裸内存 |
| `SPIRAM_USE_CAPS_ALLOC` | 不会（`heap_caps_malloc(SPIRAM)` 显式要） | 大缓冲显式放外部         |
| `SPIRAM_USE_MALLOC`     | 会（>limit 倾向外部，见上）               | 最省心的"内存变大"       |

`SPIRAM_USE_MALLOC` 模式还有两个关键参数：

- **`SPIRAM_MALLOC_ALWAYSINTERNAL`（默认 16384）**：小于它的 malloc 留内部，大于它的倾向 SPIRAM。激进调小（如 1024）能让内部 RAM 更省，但小对象也外流、整体变慢；
- **`SPIRAM_MALLOC_RESERVE_INTERNAL`（默认 32768）**：**内部 RAM 保留池**。实现很妙（`esp_psram_extram_reserve_dma_pool()`）：启动时从内部 RAM `heap_caps_malloc` 走最大可用块，然后把这些块**重新注册成新堆**，caps 数组三档是 `{0, DMA|INTERNAL, 8BIT|32BIT}`——**prio 0 是 0**，所以任何带 `MALLOC_CAP_DEFAULT` 的普通请求在这一档永不匹配，这池子只响应显式的 `DMA|INTERNAL` 类请求（任务栈、DMA 缓冲正属此类）。用"改写能力档案"而不是加标志位来保护内存，是 caps 体系表达力的一个漂亮示范。

### 3. cache 惩罚：外部内存的隐性账单

SPIRAM 的字节要经过 flash cache 的 MMU 映射才能被 CPU 访问，账单有三笔：

1. **访问延迟**：cache 命中时尚可，未命中要走 PSRAM 的 SPI 时序（40/80MHz 四线），比内部 SRAM 慢一个数量级；
2. **挤占 cache 行**：大量数据在 SPIRAM 上流动会把映射 flash 代码/rodata 的 cache 行也挤出去，**内部代码的执行速度被连累**——"没用 SPIRAM 的代码怎么也变慢了"的经典原因；
3. **关键路径禁入**：cache 关闭（flash 擦写、深睡转换）期间 SPIRAM 整体消失。这就是 `heap_idf.c` 把内核对象钉死在 `MALLOC_CAP_INTERNAL|8BIT`、ISR 必须 IRAM、DMA 缓冲必须内部的共同根源。

> [!tip] 实践准则
> SPIRAM 适合**大、冷、非实时**的数据（大 JSON、图像帧、TLS 会话缓冲）；凡是出现在中断路径、DMA 描述符、任务栈、或实时循环里的东西，显式 `MALLOC_CAP_INTERNAL`（或 DMA）并检查返回值。

---

## 20.7 堆调试工具链

内存问题在多堆体系下更隐蔽（"总共还有内存，为什么这个分配失败了"通常是能力位不匹配），IDF 为此配了四层工具。

### 1. 水位与体检：按 caps 聚合的统计

| API                                      | 回答的问题                                    |
| ---------------------------------------- | --------------------------------------------- |
| `heap_caps_get_free_size(caps)`          | 满足该 caps 的堆还剩多少（多堆求和）          |
| `heap_caps_get_largest_free_block(caps)` | **最大连续空闲块**——比 free size 更早暴露碎片 |
| `heap_caps_get_minimum_free_size(caps)`  | 历史低水位（各堆独立低点之和）                |
| `heap_caps_print_heap_info(caps)`        | 逐堆 + 汇总打印（实验 20.9 看输出）           |
| `heap_caps_check_integrity_all(true)`    | 遍历所有堆校验元数据/污染模式，坏则打印       |

经验法则：怀疑碎片看 `largest_free_block` 与 `free_size` 的差距；怀疑泄漏看 `minimum_free_size` 是否单调下探；上线前留个按键调 `heap_caps_check_integrity_all()`，能把"偶发崩溃"提前变成"明确报告"。

### 2. 污染检测（poisoning）：三档开销换三种发现能力

`CONFIG_HEAP_CORRUPTION_DETECTION` 三档，实现全在 `multi_heap_poisoning.c`：

| 档位          | 机制              | 每块开销           | 能发现                             |
| ------------- | ----------------- | ------------------ | ---------------------------------- |
| Basic（默认） | 无                | 0                  | —                                  |
| Light         | 头尾金丝雀        | 12 字节            | 越界写（滞后发现，check/free 时）  |
| Comprehensive | 金丝雀 + 填充模式 | 12 字节 + 检查耗时 | 越界写 + use-after-free + 块内踩踏 |

Light 档在每个分配块前后埋：

```text
  ┌─────────────────┬───────────────────────┬──────────────┐
  │ head_canary     │ alloc_size │ 用户数据 │ tail_canary  │
  │ 0xABBA1234      │            │          │ 0xBAAD5678   │
  └─────────────────┴───────────────────────┴──────────────┘
        poison_head_t (8B)                        poison_tail_t (4B)
```

校验函数 `verify_allocated_region()` 在 `free`/`check` 时核对两端魔数，不符即打印 `CORRUPT HEAP: Bad head at 0x...` 并带期望/实际值。Comprehensive（对应源码里的 `MULTI_HEAP_POISONING_SLOW`）再加全块填充：分配后填 `0xce`（`MALLOC_FILL_PATTERN`）、释放后填 `0xfe`（`FREE_FILL_PATTERN`）——于是 use-after-free 读到的是满屏 `0xfe`，写坏的字节在校验时立刻暴露。

### 3. 堆追踪（heap tracing）：谁分配的、漏了谁

`CONFIG_HEAP_TRACING_*` 开启后，`--wrap` 链接选项把 `heap_caps_malloc_base` 等四个函数整体包一层记录器：

- `HEAP_TRACE_LEAKS`：free 时删除对应记录，缓冲里剩下的就是**当前仍存活的分配**——抓泄漏的主力模式；
- `HEAP_TRACE_ALL`：分配/释放全记录，用于分析分配频率与模式；
- 记录含调用栈（`CONFIG_HEAP_TRACING_STACK_DEPTH`，默认 2 层）与尺寸/caps，`heap_trace_dump()` 输出；
- Standalone 模式记录在内部缓冲（可配 hash map 加速 free 查找），Tohost 模式经串口发给主机分析——QEMU 上两者都可用。

### 4. 按任务记账（heap task tracking）

`CONFIG_HEAP_TASK_TRACKING` 打开后，`multi_heap_platform.h` 里的 `MULTI_HEAP_SET_BLOCK_OWNER()` 会在每个块头部多塞一个 `TaskHandle_t`（4 字节，即前文路由图里的"块 owner"），`heap_caps_print_all_task_stat()` 即可打印"每个任务占了哪些堆多少内存"；配合 `CONFIG_HEAP_TRACK_DELETED_TASKS` 还能审计已删除任务是否留下了未释放的分配——对"任务自杀后内存消失"这类问题几乎是唯一抓手。

外加一个通用保险：`heap_caps_register_failed_alloc_callback()` 注册失败回调（带 size/caps/函数名上下文），`CONFIG_HEAP_ABORT_WHEN_ALLOCATION_FAILS` 则让失败直接 `abort`，回调节省定位时间（20.9 实验就用它）。

---

## 20.8 Vanilla vs IDF：单堆对多堆

本章暗线收拢。Vanilla 的世界假设"RAM 是一块同质的连续数组"（heap_1~4）或"几块同质区域"（heap_5）；IDF 的世界从硬件事实出发，把"能力"做成一等公民：

| 维度        | Vanilla（heap_1~5）                             | ESP-IDF（heap 组件）                                                         |
| ----------- | ----------------------------------------------- | ---------------------------------------------------------------------------- |
| 内存观      | 一块静态数组 / 一张区域表，能力同质             | 异构多区域：DRAM / D/IRAM / IRAM / RTC / SPIRAM 各带能力档案                 |
| 分配接口    | `pvPortMalloc(n)`，尺寸是唯一参数               | `heap_caps_malloc(n, caps)`，能力位与尺寸共同路由                            |
| libc malloc | 与内核堆两张皮（heap_3 包一层除外）             | `malloc()` 被改写到 `heap_caps_malloc_default()`，与 `pvPortMalloc` 同一体系 |
| 算法        | bump / first-fit+合并 / libc（按所选 heap_N）   | 每区域一个 TLSF 实例，O(1) 分配释放                                          |
| 并发保护    | `vTaskSuspendAll()`（挡任务不挡中断，单核语义） | 每堆独立 `portMUX` 自旋锁（`portENTER_CRITICAL_SAFE`，ISR 安全）             |
| 失败处理    | `vApplicationMallocFailedHook()`，无上下文      | 回调带 size/caps/函数名；可配 abort                                          |
| 越界防护    | 无（最多 `configHEAP_CLEAR_MEMORY_ON_FREE`）    | 三档 poisoning + 完整性检查 + 堆追踪 + 按任务记账                            |
| 可观测水位  | 单一 `xMinimumEverFreeBytesRemaining`           | 按 caps 聚合：free / largest_block / 各堆独立低水位                          |
| 运行时扩展  | heap_5 区域表必须先于首次分配                   | `heap_caps_add_region()` 随时加堆（SPIRAM、DMA 保留池都靠它）                |

一句话：**Vanilla 的堆是"一块内存的管理者"，IDF 的堆是"一组内存的策略层"**。前者教你分配算法，后者教你异构资源抽象——两个都读过，才看得懂从 MCU 到 SoC 的内存管理光谱。

---

## 20.9 实验：QEMU 上盘点各 cap 余量 + 故意要错内存

照例 QEMU 主线（`idf.py qemu monitor`）。实验做三件事：注册失败回调、盘点各能力位的余量与最大块、故意发起三种"注定失败/可疑"的分配。

```c
/* main/freertos-ch20.c —— 第二十章实验 */
#include <stdio.h>
#include <inttypes.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "esp_memory_utils.h"

static void alloc_fail_hook(size_t size, uint32_t caps, const char *fn)
{
    /* 注意：可能在锁内被调，只能用 printf 这类已缓冲输出，别再做花活 */
    printf("[alloc-fail] %s: size=%u caps=0x%08" PRIX32 "\n",
           fn, (unsigned)size, caps);
}

void app_main(void)
{
    heap_caps_register_failed_alloc_callback(alloc_fail_hook);

    /* 1. 盘点：每种能力位的余量与最大连续块 */
    const struct { uint32_t caps; const char *name; } probe[] = {
        { MALLOC_CAP_INTERNAL, "INTERNAL" },
        { MALLOC_CAP_8BIT,     "8BIT"     },
        { MALLOC_CAP_DMA,      "DMA"      },
        { MALLOC_CAP_EXEC,     "EXEC"     },
        { MALLOC_CAP_SPIRAM,   "SPIRAM"   },
        { MALLOC_CAP_RTCRAM,   "RTCRAM"   },
    };
    for (size_t i = 0; i < sizeof(probe) / sizeof(probe[0]); i++) {
        printf("== %-8s free=%8u largest=%8u\n", probe[i].name,
               (unsigned)heap_caps_get_free_size(probe[i].caps),
               (unsigned)heap_caps_get_largest_free_block(probe[i].caps));
    }

    /* 2. 三种"错误姿势" */
    void *p1 = heap_caps_malloc(64, MALLOC_CAP_SPIRAM);            /* QEMU 无 PSRAM */
    printf("SPIRAM(64)            -> %p\n", p1);

    void *p2 = heap_caps_malloc(1024, MALLOC_CAP_DMA | MALLOC_CAP_EXEC); /* 硬件矛盾 */
    printf("DMA|EXEC(1024)        -> %p\n", p2);

    /* 3. 正确姿势对照 + 能力自检 */
    uint8_t *dma = heap_caps_malloc(1024, MALLOC_CAP_DMA);
    uint8_t *any = malloc(1024);
    printf("DMA(1024)             -> %p dma_ok=%d internal=%d\n",
           dma, esp_ptr_dma_capable(dma), esp_ptr_internal(dma));
    printf("malloc(1024)          -> %p dma_ok=%d\n",
           any, esp_ptr_dma_capable(any));

    heap_caps_free(dma);
    free(any);
    heap_caps_print_heap_info(MALLOC_CAP_DMA);   /* 逐堆明细 */
}
```

典型输出（QEMU/esp32、默认配置；数值随固件大小浮动）：

```text
== INTERNAL free=   253904 largest=   118784
== 8BIT     free=   249120 largest=   118784
== DMA      free=   249120 largest=   118784
== EXEC     free=    49348 largest=    32768
== SPIRAM   free=        0 largest=        0
== RTCRAM   free=        0 largest=        0
[alloc-fail] heap_caps_malloc: size=64 caps=0x00000400
SPIRAM(64)            -> (nil)
[alloc-fail] heap_caps_malloc: size=1024 caps=0x00000009
DMA|EXEC(1024)        -> (nil)
DMA(1024)             -> 0x3ffb2c10 dma_ok=1 internal=1
malloc(1024)          -> 0x3ffb3018 dma_ok=1
Heap summary for capabilities 0x00000008:
  At 3ffb2b6c len 185748 free 183588 allocated 160 min_free 183588
    largest_free_block 114688 alloc_blocks 1 free_blocks 8 total_blocks 9
  At 3ffe4350 len 113840 free 112624 allocated 1216 min_free 112624
    largest_free_block 106496 alloc_blocks 5 free_blocks 5 total_blocks 10
  Totals:
    free 296212 allocated 1376 min_free 296212 largest_free_block 114688
```

逐条解读：

1. **`DMA` 的 free 与 `8BIT` 几乎相同**：20.3 矩阵里 DRAM 和 D/IRAM 的某一档都挂着 DMA——内部 RAM 的 DMA 供给面就是这么宽；
2. **`EXEC` 明显更小**：能执行的只有 IRAM（约 192KB，扣掉代码后剩 ~48KB）加 D/IRAM 的别名身份；`largest=32768` 提醒你大块可执行内存比总量看起来更紧张；
3. **SPIRAM/RTCRAM 都是 0**：QEMU 的 esp32 机型默认不带 PSRAM；默认配置也没开 `CONFIG_ESP_SYSTEM_ALLOW_RTC_FAST_MEM_AS_HEAP`。两次失败的分配都触发了我们注册的回调——注意 `DMA|EXEC` 的 caps 打印 `0x00000009`（EXEC|DMA），它死在 20.4 节的"矛盾组合"预处理上，连路由循环都没进；
4. **`malloc` 出来的指针恰好 DMA 可用**——在 ESP32 上内部 DRAM 普遍如此，但**这是路由的副产品而非契约**：SPIRAM 启用后大 malloc 会外流，喂给 DMA 前必须 `esp_ptr_dma_capable()` 自检（真机上这一行检查能救命）；
5. `heap_caps_print_heap_info(MALLOC_CAP_DMA)` 的明细显示**两个堆**（合并后的 DRAM 堆 + D/IRAM 堆）都在响应 DMA——矩阵的"多堆求和"语义落到实处。

真机对照：带 4MB PSRAM 的 WROVER 模组、`SPIRAM_USE_MALLOC` 默认配置下重跑，`SPIRAM` 行会变成约 4MB（减去 rodata 外置等占用），且第 2 步的 `SPIRAM(64)` 分配成功——64 小于默认 limit 16384，反而**落回内部**；把 size 改成 65536 再看它落到 `0x3F...` 的外部地址段。同一段代码在两种硬件上的行为差异，本身就是 20.6 迁移策略的活教材。

---

## 20.10 小结

- ESP-IDF 没有独立的"FreeRTOS 堆"：`heap_idf.c` 把 `pvPortMalloc` 桥接到 `heap_caps_malloc(INTERNAL|8BIT)`，libc 的 `malloc` 也被改写到 `heap_caps_malloc_default()`——三条路共用一套按能力路由的多堆体系。
- **caps 的根因是硬件**：DMA 只认内部 DRAM、执行必须走 I-bus、cache 关闭时外部内存消失；RTC 慢速 RAM 根本不入堆。每类内存用三档优先级 caps 描述"愿意以什么身份被分配"，`malloc` 先吃纯 DRAM、`EXEC` 先吃纯 IRAM 的次序都由这张矩阵推出。
- 路由核心是 `registered_heaps` 链表上的双层循环：外层扫优先级档、内层扫堆（按大小升序）；匹配条件是"本档沾边且三档并集覆盖全部请求位"。D/IRAM 的双地址别名靠"返回指针前一个字藏 DRAM 地址"实现身份转换与正确释放。
- 每个堆是一个 `multi_heap` 实例：独立 `portMUX` 自旋锁（ISR 安全、核间只在同堆时互斥）+ TLSF 两级位图（O(1) 分配释放、good-fit、保留合并）。
- SPIRAM 接入后 `malloc()` 变成三档回退策略（`SPIRAM_MALLOC_ALWAYSINTERNAL` 分界、失败放宽）；DMA 保留池通过"把内部 RAM 重新注册成 prio 0 为空的能力档案"实现软隔离；外部内存的代价是 cache 延迟、挤占内部代码的 cache 行、关键路径禁入。
- 调试四件套：caps 聚合水位（`largest_free_block` 是碎片前哨）、三档 poisoning（`0xABBA1234`/`0xBAAD5678` 金丝雀 + `0xce`/`0xfe` 填充）、堆追踪（LEAKS 模式抓泄漏）、按任务记账（块头 `TaskHandle_t`）。
- QEMU 实验验证了矩阵的全部推论：DMA 供给面 ≈ 全部内部数据 RAM、EXEC 明显稀缺、矛盾 caps 在预处理即被拒、失败回调带 size/caps 上下文。

下一章留在内存主题内换一个视角：[[ch21-stack-and-memory-layout|第二十一章]]——**栈与内存布局**。任务栈从堆里长出来之后如何防溢出（`uxTaskGetStackHighWaterMark` 背后在量什么）、链接脚本如何决定 data/bss/IRAM/text 各归其位（`_heap_start` 这个符号正是本章保留区表的输入）、以及 IRAM/DRAM 地址映射的完整图景——把 Part V 的最后一块拼图放进去。
