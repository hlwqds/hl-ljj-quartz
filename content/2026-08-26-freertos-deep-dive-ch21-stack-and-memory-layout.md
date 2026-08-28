---
title: "FreeRTOS 深度解析（二十一）：栈与内存布局"
date: 2026-08-26
description: "从链接器视角看清 ESP32 固件在 IRAM/DRAM/flash 里的真实摆放（XIP、启动搬运、linker.lf 片段）；任务栈从堆里来、向下长、与 Xtensa 寄存器窗口的关系；栈溢出两档检测的源码级原理与局限；IDF 独有的高水位与硬件 watchpoint；中断栈为什么独立于任务栈。最后在 QEMU 里亲手递归爆一次栈。"
tags: [freertos, rtos, esp32, esp-idf, memory, stack, linker, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[2026-08-26-freertos-deep-dive-series-index|系列索引]]
>
> 1. **第二十一章：栈与内存布局**

# FreeRTOS 深度解析（二十一）：栈与内存布局

第[[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison|十九]]、[[2026-08-26-freertos-deep-dive-ch20-idf-heap-and-caps|二十]]章讲的是"内存怎么分出去"；这一章讲它的两个对偶问题：**固件本身在内存里是怎么摆的**（链接布局、XIP、启动搬运），以及**每个任务最私有的那块内存——栈——从哪来、怎么长、爆了怎么知道**。

栈问题是嵌入式调试时间黑洞的前三名：症状永远是"随机死机、数据莫名被改、偶现 hard fault"。这一章的目标是让你面对这类问题时，脑子里有一张精确的地图：哪个地址属于哪个段、哪个字节属于哪个任务、检测机制在源码里是哪一行判断。

---

## 21.1 固件在内存里的样子：段、XIP 与启动搬运

先建立整张地图。编译产物是 ELF，链接器按链接脚本把它切成若干**段（segment）**，烧进 flash 的 bin 按"头 + 若干段"组织；上电后 bootloader 决定每一段是**搬进 RAM** 还是**映射进地址空间**。

### 1. ESP32 的地址空间骨架

ESP32（经典版）与内存相关的地址窗口示意（精确位分配见[[2026-08-26-freertos-deep-dive-ch2-esp32-xtensa-architecture|第二章]]）：

```text
0x4000_0000 ┌────────────────────────────┐
            │ ROM（ bootloader 一级代码） │  只读，厂里固化
0x4007_0000 └────────────────────────────┘
0x4008_0000 ┌────────────────────────────┐
            │ IRAM：.iram0.text/.bss     │  内部 RAM，CPU 直接取指
            │ 中断向量表、关键函数        │  flash 缓存关闭时也能执行
0x400A_0000 ├────────────────────────────┤
            │ IROM 窗口：flash 代码映射   │  经 ICache，XIP 就地执行
            │ （.flash.text）            │  掉缓存 = 掉代码
0x4040_0000 └────────────────────────────┘

0x3FF8_0000 ┌────────────────────────────┐
            │ D/IRAM：.dram0.data/.bss   │  内部 RAM，数据 + 可放代码
            │ 内核数据、任务栈、堆        │
0x4000_0000 ├────────────────────────────┤
            │ DROM 窗口：flash 只读数据  │  经 DCache 映射
            │ （.flash.rodata）          │  字符串、const 表都在这
0x3F80_0000 └────────────────────────────┘
        （DROM 窗口实际位于 0x3F40_0000–0x3F80_0000 一带）
```

两个关键认知：

1. **flash 上的代码和数据从来不是"直接访问"的**，全部经过 MMU + Cache 映射到 IROM/DROM 窗口，这就是 XIP（execute in place）。代价后面马上讲：**cache 被禁的窗口期，flash 里的代码不能执行**。
2. **IRAM/DRAM 是稀缺资源**（合计约 520KB SRAM，还要扣 ROM 用量和 cache），所以"什么进 IRAM、什么留 flash"是一个显式的工程决策，IDF 用链接脚本片段把它管起来。

### 2. 一条数据从 flash 到 DRAM：启动搬运

ELF 里典型段与最终去向：

| ELF 段          | 内容                | 去向               | 谁负责                 |
| --------------- | ------------------- | ------------------ | ---------------------- |
| `.flash.text`   | 绝大多数函数代码    | IROM 映射（XIP）   | bootloader 建 MMU 映射 |
| `.flash.rodata` | 字符串、`const` 表  | DROM 映射          | bootloader 建 MMU 映射 |
| `.iram0.text`   | IRAM 函数（见下节） | **memcpy 进 IRAM** | bootloader             |
| `.dram0.data`   | 已初始化全局变量    | **memcpy 进 DRAM** | bootloader             |
| `.dram0.bss`    | 未初始化全局变量    | **清零**           | 应用启动代码           |

后三行就是经典的"裸机 startup 做的事"，只是 IDF 里分了两层做，源码可以对上号：

- **搬运**：二级 bootloader 解析 app 镜像时，`esp_image_format.c` 的 `process_segment_data()` 对每个段做 `memcpy((void *)segment_data->load_addr, data, segment_data->data_len)`；而 `should_map()`（同一文件）判断段的加载地址落在 IROM/DROM 窗口则**不搬运**——`should_load()` 里明确写着映射段直接 `return false`。一个段要么搬、要么映射，由镜像段头里的 `load_addr`（构建时源自 ELF 的 `p_paddr`）决定。
- **清零**：应用自己的启动代码 `cpu_start.c` 里，CPU0/CPU1 各自 `memset(&_bss_start, 0, ...)`、`memset(&_iram_bss_start, 0, ...)`（还有 RTC bss）。`.data` 是"flash 里有副本、启动时抄进 RAM"；`.bss` 是"flash 里根本没有，启动时清零"。

> [!note] 为什么搬运发生在 bootloader 而不是应用里？
> 应用自己就躺在 flash 里，它的 `.text` 要靠 cache 映射才能执行；而搬运 `.data` 需要读 flash、写 DRAM，这期间一旦操作 cache 就可能把正在执行的代码抽走。放在 bootloader（一段专门放进 IRAM/ROM 执行的小程序）里做，就没有"自己搬自己脚下地板"的问题。[[2026-08-26-freertos-deep-dive-ch3-esp-idf-build-and-bootflow|第三章]]有完整启动时序。

### 3. linker.lf：FreeRTOS 关键函数怎么进 IRAM

"什么函数进 IRAM"在 ESP-IDF 里不写在巨型链接脚本里，而是各组件自带**链接片段文件**（`.lf`），构建系统汇总生成最终脚本。FreeRTOS 组件的 `components/freertos/linker.lf`（v6.0.2）开头就写明了策略：

```text
Placement Rules:
  - 默认：所有 FreeRTOS 函数放 flash，除了：
      - FromISR() 函数（默认进 IRAM）
      - 性能/正确性关键函数：临界区 API、上下文切换相关代码
  - CONFIG_FREERTOS_IN_IRAM=y：全部进 IRAM（吃内部 RAM，默认关）
```

片段语法长这样（节选自 `linker.lf`，`noflash_text` 即 IRAM 放置方案）：

```text
[mapping:freertos_idf]
archive: libfreertos.a
entries:
    ...
    tasks:xTaskIncrementTick (noflash_text)
    tasks:vTaskSwitchContext (noflash_text)
    tasks:xTaskGetSchedulerState (noflash_text)
    tasks:xTaskGetTickCount (noflash_text)
    ...
    port:xPortStartScheduler (noflash_text)
    port:vPortExitCritical (noflash_text)
    port:vPortSetStackWatchpoint (noflash_text)
    ...
    portasm (noflash_text)     ← 整个 portasm.S 对象文件进 IRAM
```

为什么是这几位？`linker.lf` 注释说得很直白：这些函数**在上下文切换路径上被高频调用，或会在 cache 被禁用的窗口里执行**。第[[2026-08-26-freertos-deep-dive-ch7-context-switch-deep-dive|七]]章会看到，`portasm.S` 里的切换代码若在 flash 里，关 cache 写 SPI flash 的瞬间就可能取不到下一条指令——这不是性能问题，是正确性问题。反向开关也存在：`CONFIG_FREERTOS_PLACE_ISR_FUNCTIONS_IN_TO_FLASH`（依赖 flash 自动挂起特性）把 `FromISR` 函数挪回 flash 省 IRAM。

> [!tip] Vanilla vs ESP-IDF：代码放置谁说了算
> | 主题 | Vanilla FreeRTOS | ESP-IDF |
> | --- | --- | --- |
> | 放置机制 | 端口自带一个整体链接脚本（或直接用芯片默认布局），无逐函数控制 | `.lf` 片段按**对象文件 + 函数名**粒度控制放置 |
> | ISR 函数 | 无特殊放置约定 | `FromISR` 族默认进 IRAM |
> | 一键切换 | 无 | `CONFIG_FREERTOS_IN_IRAM` 全量进 IRAM |
>
> 本质差异：IDF 把"flash 擦写期间代码必须仍在可执行内存"这个硬约束，做成了声明式的、可审计的构建配置。

到这里，"固件怎么摆"有了全图。下面进入本章主角：任务栈。

---

## 21.2 任务栈：从堆里来，向下长

### 1. 动态创建时，栈就是一块堆内存

`xTaskCreate()` 走到内核里（`tasks.c` 的任务创建路径），内存动作只有两步：从 `pvPortMalloc` 拿一大块（TCB + 栈连续），再初始化。在 ESP-IDF 里这个 `pvPortMalloc` 不是 `heap_4.c`，而是 `components/freertos/heap_idf.c` 的转发：

```c
/* heap_idf.c —— 内核堆被整体接到 IDF heap 组件 */
#define portFREERTOS_HEAP_CAPS    ( MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT )

void * pvPortMalloc(size_t xWantedSize)
{
    return heap_caps_malloc(xWantedSize, portFREERTOS_HEAP_CAPS);
}
```

也就是说：**任务栈 = 一块普通的内部 RAM 堆内存**（能力约束为内部、可按字节访问——栈必须是 8 位可写的，所以纯指令 RAM 不行）。同一个文件里的 `xPortcheckValidStackMem()` 还会把静态创建任务的栈地址校验一遍：默认必须落在内部 RAM，开了 `CONFIG_FREERTOS_TASK_CREATE_ALLOW_EXT_MEM` 才允许外部 PSRAM 栈。堆本身的结构（多分配器、caps 怎么路由）是[[2026-08-26-freertos-deep-dive-ch20-idf-heap-and-caps|第二十章]]的内容。

分配完成后 TCB 里记三个指针（`tasks.c` 的 `prvInitialiseNewTask()` 建立它们）：

```text
        堆上分配的一大块（ulStackDepth 字节）
        ┌───────────────────────────────┐ 高地址
        │ 初始上下文帧（入口 PC/PS 等）  │ ← pxEndOfStack（栈顶=起始 SP，16 对齐）
        │ …以后每层调用往下压…           │
        │                               │ ← pxTopOfStack（当前 SP，随调用下移）
        │                               │
        │ 0xa5 0xa5 0xa5 …（填充魔数）  │ ← pxStack（栈基=最低地址，溢出先砸这里）
        └───────────────────────────────┘ 低地址
```

- `pxStack`：栈缓冲区**最低**地址（下文称"栈基"）；
- `pxEndOfStack`：**最高**有效地址，任务首次运行时 SP 从这附近开始（`configRECORD_STACK_HIGH_ADDRESS=1`，IDF 强制打开，`FreeRTOSConfig.h` 注释写明"端口需要它"）；
- `pxTopOfStack`：当前 SP，每次切出任务时由端口汇编更新。

### 2. 向下生长：portSTACK_GROWTH = -1

Xtensa 端口的 `portmacro.h` 里三个定义决定了栈的一切几何性质：

```c
#define portSTACK_TYPE        uint8_t      /* StackType_t 是字节 → 栈深单位=字节 */
#define portSTACK_GROWTH      ( -1 )       /* 向低地址生长 */
#define portBYTE_ALIGNMENT    16           /* 窗口 ABI 强制 SP 16 字节对齐 */
```

第一行是暗线里那个著名差异的**实现现场**：Vanilla 大多数端口 `StackType_t` 是 `uint32_t`，`xTaskCreate` 的栈深参数以**字**计；IDF 把 `StackType_t` 改成了 `uint8_t`，于是同一个参数变成**字节**。`task.h` 里 IDF 版文档原话："The size of the task stack specified as the NUMBER OF BYTES. **Note that this differs from vanilla FreeRTOS.**" 从 STM32 教程抄 `xTaskCreate(..., 128, ...)` 过来，128 字节起步的栈几乎必爆。

第二行 `portSTACK_GROWTH = -1`：调用发生时 SP 往**低**地址走，局部变量、保存的寄存器都压在更低处。所以"栈溢出"= SP 越过 `pxStack` 继续向下，砸坏的是**堆里相邻的其它内存**（别的任务的栈、某个队列……），这就是栈溢出症状随机的根源。

### 3. 与 Xtensa 寄存器窗口的关系

Xtensa LX6 的"窗口式寄存器"（详见[[2026-08-26-freertos-deep-dive-ch17-xtensa-port-internals|第十七章]]）让它的栈行为和 ARM 有两个不同：

1. **函数调用不一定要显式压栈**。`call4`/`call8`/`call12` 指令直接旋转 64 个通用寄存器组成的窗口，被调用者拿到一组"新"寄存器。只有窗口转满一圈（寄存器耗尽）时，硬件触发 **window overflow 异常**，由异常处理程序把最老的窗口寄存器组**倒进当前任务的栈**。换句话说：C 代码看起来零压栈的调用链，栈上压力是**延迟、成批**到来的。这也是 `portBYTE_ALIGNMENT` 必须是 16 的原因——`portmacro.h` 引用了 Xtensa 窗口 ABI 对 SP 16 字节对齐的硬性要求。
2. **初始栈帧不是普通的函数帧**。`port.c` 的 `pxPortInitialiseStack()` 在栈顶手工搭一个"伪造的中断帧"（`XtensaFrame`：PC 指向任务函数、PS 带上 `WOE`/`CALLINC` 位、参数放进 a2……），任务第一次被调度时就当作"从中断返回"一样起跑。源码注释里的布局图值得一看：栈顶往下依次是**协处理器保存区（CPSA）→ TLS 区 → 起始帧**，三块都 16 字节对齐。协处理器区为什么必须在最顶、和 `_frxt_task_coproc_state()` 怎么配合，第十七章展开。

> [!note] 一次调用到底吃多少栈？
> 对 Xtensa 窗口 ABI：普通叶子函数可能 0 字节（窗口旋转不落栈）；触发 overflow 的调用按窗口大小成批落（16/32/48 字节一组）；再加上本帧局部变量（16 对齐向上取整）。经验上**平均每层 C 调用 32~64 字节**，但这只是量级——精确值永远用 21.4 节的高水位量，不要背表。

---

## 21.3 栈溢出检测：内核的两档机制

FreeRTOS 内核自带两档检测，全部实现在 `stack_macros.h` 的宏 `taskCHECK_FOR_STACK_OVERFLOW()` 里，**唯一的检查时机是任务被切换出 CPU 的瞬间**——`tasks.c` 的 `vTaskSwitchContext()` 里，在选新任务之前对刚下场的任务做一次检查。

### 1. 方法一（configCHECK_FOR_STACK_OVERFLOW=1）：查指针

向下生长版本的宏逻辑（IDF 版，`pxCurrentTCBs[xCurCoreID]` 是 SMP 化的数组写法）：

```c
/* 栈指针还在界内吗？ */
if ( pxCurrentTCBs[xCurCoreID]->pxTopOfStack
     <= pxCurrentTCBs[xCurCoreID]->pxStack + portSTACK_LIMIT_PADDING )
{
    vApplicationStackOverflowHook( (TaskHandle_t) pxCurrentTCBs[xCurCoreID],
                                   pxCurrentTCBs[xCurCoreID]->pcTaskName );
}
```

`pxTopOfStack` 是切出时保存的 SP。只要 SP 曾越过栈基，这个比较立刻为真。**快**（一次比较），但**只能看见"切换那一刻"的深度**：一个任务在两次切换之间深潜又浮回来，方法一完全看不见。

### 2. 方法二（configCHECK_FOR_STACK_OVERFLOW=2）：查魔数（canary）

创建任务时，`prvInitialiseNewTask()` 把整块栈 memset 成 `0xa5`（`tskSTACK_FILL_BYTE`，tasks.c 顶部定义）。方法二在每次切换时检查**栈基开头 16 字节**还是不是 `0xa5a5a5a5`：

```c
const uint32_t * const pulStack = (uint32_t *) pxCurrentTCBs[xCurCoreID]->pxStack;
const uint32_t ulCheckValue = (uint32_t) 0xa5a5a5a5;

if ( ( pulStack[0] != ulCheckValue ) || ( pulStack[1] != ulCheckValue ) ||
     ( pulStack[2] != ulCheckValue ) || ( pulStack[3] != ulCheckValue ) )
{
    vApplicationStackOverflowHook( ... );   /* 同上 */
}
```

任何写脏这 16 字节的越界都会被记住——**历史痕迹**检测，比方法一可靠。这个填充同时也是 21.4 节高水位机制的原料（`tskSET_NEW_STACKS_TO_KNOWN_VALUE` 的开关条件里，`configCHECK_FOR_STACK_OVERFLOW > 1` 和高水位 INCLUDE 任一为真就启用填充）。

### 3. ESP-IDF 的默认档位与默认 hook

IDF 里这两档有 Kconfig 名字，**默认是方法二**：

| Kconfig 选项                          | config 值     | 语义              |
| ------------------------------------- | ------------- | ----------------- |
| `FREERTOS_CHECK_STACKOVERFLOW_NONE`   | 0             | 不查（默认关）    |
| `FREERTOS_CHECK_STACKOVERFLOW_PTRVAL` | 1             | 方法一：查指针    |
| `FREERTOS_CHECK_STACKOVERFLOW_CANARY` | **2（默认）** | 方法二：查 canary |

hook 也有区别：Vanilla 要求应用**必须**提供 `vApplicationStackOverflowHook()`（不提供直接链接失败）；IDF 在 Xtensa 端口 `port.c` 里给了一个 `__attribute__((weak))` 默认实现——拼出 `***ERROR*** A stack overflow in task <名字> has been detected.` 后调 `esp_system_abort()`，进入 panic 处理器（`panic.c`：打印原因与回溯，默认 `CONFIG_ESP_SYSTEM_PANIC_PRINT_REBOOT` 打完即重启）。所以 ESP32 上爆栈的典型下场是：串口吐一行 ERROR + backtrace，然后设备复位。

### 4. 两档机制共同的局限

必须清楚这两个机制**不是安全网**，是"事后验尸"：

| 局限               | 说明                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------ |
| 只在切换时检查     | 溢出发生到被发现之间，破坏已经造成；若溢出当场毁掉 TCB/返回地址，可能根本活不到下一次切换        |
| 方法一只看瞬时 SP  | 深潜后恢复的溢出完全漏报                                                                         |
| 方法二只守 16 字节 | 越界**跳过** canary 直捣更低地址（典型：函数里一个很大的局部数组，帧直接跨过栈基 16 字节）→ 漏报 |
| 魔数可能"自然出现" | 应用数据恰好等于 `0xa5a5a5a5` 会误报；反过来被踩后又巧合写回（罕见）则漏报                       |
| hook 在残骸上执行  | 溢出可能已破坏打印/abort 依赖的数据结构，hook 只能 best-effort                                   |

> [!tip] Vanilla vs ESP-IDF：溢出检测对照
> | 主题 | Vanilla FreeRTOS | ESP-IDF |
> | --- | --- | --- |
> | 两档机制本身 | `stack_macros.h` 同款两档 | 相同（宏改成 `pxCurrentTCBs[xCoreID]` 数组形式） |
> | 默认档位 | 用户在 FreeRTOSConfig.h 自定 | Kconfig 默认方法二（CANARY） |
> | 默认 hook | 无，必须自己实现 | `port.c` 提供 weak 默认：打印任务名 + abort + 重启 |
> | 填充启用条件 | 同 | 同逻辑；另有多档 `configSTACK_OVERHEAD_TOTAL` 自动加余量（见 21.4） |
> | 溢出即时捕获 | 无 | 可选硬件 watchpoint（见 21.4） |

---

## 21.4 IDF 增强：高水位测量与硬件 watchpoint

### 1. uxTaskGetStackHighWaterMark 的原理

```c
UBaseType_t uxTaskGetStackHighWaterMark( TaskHandle_t xTask );   /* NULL=当前任务 */
```

返回值 = 该任务**有史以来**剩余的最小栈空间。原理简单到可以口述（`tasks.c` 的 `prvTaskCheckFreeStackSpace()`）：从 `pxStack`（栈基）开始逐字节向上数，数到第一个**不是** `0xa5` 的字节为止——那就是栈使用到达过的最深处。计完数后有一行关键除法：

```c
ulCount /= ( uint32_t ) sizeof( StackType_t );
```

于是暗线再次出现：IDF 的 `StackType_t` 是 `uint8_t`，返回值单位是**字节**；Vanilla 端口除以 4，返回的是**字**。IDF 版 `task.h` 文档特意加粗说明"以字节计（区别于标准 FreeRTOS 文档中的字）"。从别的教程抄来的"高水位 < 50 就危险"的阈值，在 ESP32 上请按字节重新校准。

两个配套 API：`uxTaskGetStackHighWaterMark2()`（返回 `configSTACK_DEPTH_TYPE`，IDF 中是 `uint32_t`，纯接口差异）；以及 `vTaskGetInfo()`——它把 TCB 快照填进 `TaskStatus_t`，其中 `usStackHighWaterMark` 字段同样是高水位（`uxTaskGetSystemState()` 批量版走的就是它，`CONFIG_FREERTOS_USE_TRACE_FACILITY` 打开后配合 `vTaskList()` 出全任务报表）。

注意：高水位**不要求**开溢出检测——`INCLUDE_uxTaskGetStackHighWaterMark=1`（IDF 默认）本身就会触发栈填充，`CHECK_FOR_STACK_OVERFLOW=0` 也能用。

### 2. 高水位的局限

1. **只认"连续未写"**：它从栈基向上数连续的 `0xa5`。如果某层调用的局部变量恰好**跳过**了未触碰区（大数组跨过整段），中间残留的 `0xa5` 会让读数**虚高**——真实最深点比报告的更深。
2. **`0xa5` 是合法数据**：缓冲区里出现该字节则读数偏低（保守方向，无害）；被释放栈页复用等场景则读数失真。
3. **是历史最小值不是当前值**：调小栈要靠"清零重来"，任务跑得越久数字越悲观。
4. **开销 O(栈深)**：逐字节扫描，大栈频繁轮询有成本，监控任务别开太快。
5. **窗口 ABI 的盲区**：寄存器窗口成批落栈发生在异常路径，极端时序下最深帧可能没在"稳定状态"被采到。

结论：高水位是**工程估算工具**（量级、趋势、对比不同代码路径），不是精确仪表。

### 3. 栈里到底什么在吃空间（量级参考）

| 消耗源                       | 量级                          | 说明                                                             |
| ---------------------------- | ----------------------------- | ---------------------------------------------------------------- |
| 普通一层 C 调用              | 32–64 B                       | 窗口 ABI + 对齐后的典型值                                        |
| `printf("...%d\n")` 一族     | 数百 B～1 KB+                 | newlib 格式化 + `__builtin_va_arg`；newlibnano 明显更省          |
| 浮点格式化 `%f`              | 再 + 数百 B                   | 软浮点格式化路径                                                 |
| 局部大数组 / `char buf[N]`   | **N 字节全额**（16 对齐取整） | 最常见的爆栈元凶；改 `static`/堆/流缓冲                          |
| 深递归 / 深调用链            | 每层 × 链深                   | 21.7 实验主题                                                    |
| 栈保护 (`-fstack-protector`) | 每帧 +canary 与判定           | IDF 的 `configSTACK_OVERHEAD_TOTAL` 为此自动给最小栈加 256B 余量 |

数值会随编译选项浮动，别背表——用下一节的实验量。另外注意 `configSTACK_OVERHEAD_TOTAL`（`FreeRTOSConfig.h`）这个 IDF 汇总项：栈保护 +256、`-O0` 编译 +320、apptrace +1280、watchpoint +60，全部自动叠进 `configMINIMAL_STACK_SIZE`。**编译选项变了，同样代码的栈需求就变了**，这是"开发板好好的、量产版爆栈"的经典来源之一。

### 4. 硬件 watchpoint：把"事后验尸"变成"当场抓获"

两档内核检测都只能在切换时验尸。IDF 加了一层**实时**手段：`CONFIG_FREERTOS_WATCHPOINT_END_OF_STACK`（默认关）。打开后：

- `vTaskSwitchContext()`（`tasks.c`）在**切入**新任务时调用 `vPortSetStackWatchpoint(pxCurrentTCBs[xCurCoreID]->pxStack)`；
- `port.c` 里的实现把**最后一个**硬件 watchpoint（`SOC_CPU_WATCHPOINTS_NUM - 1`，ESP32 共 2 个，即占用 1 号）设到栈基向上对齐的 32 字节、**只监控写操作**（`esp_cpu_set_watchpoint(..., 32, ESP_CPU_WATCHPOINT_STORE)`，API 在 `esp_cpu.h`）；
- 于是任何任务一旦写进栈尾 32 字节，CPU **当条指令**触发 debug 异常——接了调试器（OCD/JTAG）就是 SIGTRAP 当场停下，现场完好；没接调试器则按 Kconfig 帮助文本的说明，作为未处理的 debug 异常进 panic。

实现细节里有几处源码注释值得一读：Xtensa watchpoint 的区域必须按大小对齐，所以实际监控的是 `(pxStack+31) & ~31` 起的 32 字节，**最多提前 28 字节**触发——源码原话解释了为什么选 32：它大于方法二 canary 的宽度（16 字节，源码注释称 canary 20 字节），保证"在 canary 被写坏的同时或之前"报警，而不是之后。

代价也明确（Kconfig 帮助文本）：gdb 少一个可用硬件 watchpoint；由于对齐要求，任务**可用栈减少至多 60 字节**（就是 `STACK_OVERHEAD_WATCHPOINT=60` 的来源）。

> [!tip] Vanilla vs ESP-IDF：检测能力对照
> | 能力 | Vanilla | ESP-IDF |
> | --- | --- | --- |
> | 切换时查 SP | ✅ 方法一 | ✅ 同（Kconfig `PTRVAL`） |
> | 切换时查 canary | ✅ 方法二 | ✅ 同（Kconfig `CANARY`，默认） |
> | 默认 hook | 需自备 | weak 默认：报任务名并重启 |
> | 溢出**当条指令**捕获 | ❌ | ✅ debug watchpoint（可选） |
> | 高水位 API | ✅（单位：字） | ✅（单位：字节） |
> | 编译选项感知的栈余量 | ❌ | ✅ `configSTACK_OVERHEAD_TOTAL` |

---

## 21.5 中断栈：独立于任务栈的每核一根

### 1. 事实：每核一个静态中断栈

IDF 的 Xtensa 端口 `port.c` 里躺着一行全局数组：

```c
volatile StackType_t DRAM_ATTR __attribute__((aligned(16)))
    port_IntStack[ portNUM_PROCESSORS ][ configISR_STACK_SIZE ];
```

- **每核一根**：`portNUM_PROCESSORS` 维（ESP32 = 2）；
- **大小**：`configISR_STACK_SIZE`，由 `FreeRTOSConfig_arch.h` 从 Kconfig `CONFIG_FREERTOS_ISR_STACKSIZE` 换算（向上对齐到 16）；**默认 1536 字节/核**，Kconfig 帮助文本提醒"总占用是两倍"；开了 coredump 则最低 2096；
- **静态分配**：链接期定死，不在堆上，也不归任何任务所有。

### 2. 切换过程：`_frxt_int_enter` 的三步

`portasm.S` 的 `_frxt_int_enter()`（中断入口的 RTOS 挂钩）干了三件事，节选注释版：

```text
第一步：在【被打断任务的栈】上保存上下文
        s32i a12, a1, XT_STK_A12     ← 此时 a1 还是任务 SP
        call0 _xt_context_save

第二步：任务 SP 存入 TCB
        s32i a1, a2, TOPOFSTACK_OFFS  ← pxCurrentTCBs[core]->pxTopOfStack = SP

第三步：a1 切到本核中断栈顶，之后 C ISR 都跑在这上面
        movi a1, port_IntStack+configISR_STACK_SIZE
        add  a1, a1, configISR_STACK_SIZE*core_id
```

两点精度要抓住：

1. **中断入口帧仍然落在任务栈上**（硬件压栈 + `_xt_context_save` 那几步）。切到 `port_IntStack` 是之后的事。所以严格说：每次中断也向被打断任务"借"一小块栈（几十到一二百字节），算任务栈需求时别忽略。
2. **嵌套计数不为 1 时不再切换**（`port_interruptNesting` 判断）：嵌套的高优先级中断继续在同一个中断栈上摞。中断退出走 `_frxt_int_exit()`，按需做任务切换并恢复任务 SP。

### 3. 坑：中断里的大局部数组

任务栈有 canary、有高水位、有 watchpoint，**中断栈什么都没有**——它是静态数组，溢出直接改写链接上紧挨着它的其它静态数据（某个驱动变量、另一个核的中断栈……），而且**没有任何检测机制会告诉你**。症状通常是最恶性的那种：偶发、与中断负载相关、崩溃点与病因相距十万八千里。

纪律随之而来：

| 做法                                 | 说明                                                                                           |
| ------------------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------ |
| ISR 里**禁止**大缓冲区局部变量       | `char buf[512]` 在 ISR 里 = 从 1536B 的公共池里直接舀走 1/3；多级嵌套再来一次就见底            |
| 数据搬运用 `static` / 环形缓冲 / DMA | ISR 只做"搬运启动 + 通知"（[[2026-08-26-freertos-deep-dive-ch13-task-notifications             | 第十三章]]的通知就是为此设计） |
| 确实需要就调大栈                     | `idf.py menuconfig` → `FREERTOS_ISR_STACKSIZE`（注意是每核）                                   |
| 留意 flash 操作                      | 从 ISR 路径调 `FromISR` API 默认在 IRAM（21.1 的 linker.lf），别让 ISR 链路意外穿过 flash 访问 |

### 4. Vanilla 对照

中断栈的处理在 FreeRTOS 里是**端口职责**，各家不同：Cortex-M 端口里 handler 运行在 MSP（main stack）上——概念上同样是"独立于任务栈的一根公共栈"，但大小藏在启动文件/链接脚本里，没有统一配置项；而 Xtensa 这边，IDF fork 把它做成了**显式的每核数组 + Kconfig 可调 + 汇编里明确的三步切换**。又一次看到同一条暗线：Vanilla 给机制，IDF 把机制工程化到可观测、可配置。

---

## 21.6 main 任务与启动栈的归宿

### 1. main 任务：app_main 的宿主

`app_main()` 不是凭空运行的。`components/freertos/app_startup.c` 的 `esp_startup_start_app()`（CPU0 在调度器启动前调用）创建它：

```c
BaseType_t res = xTaskCreatePinnedToCore(main_task, "main",
                                         ESP_TASK_MAIN_STACK, NULL,
                                         ESP_TASK_MAIN_PRIO, NULL, ESP_TASK_MAIN_CORE);
```

参数在 `esp_system/include/esp_task.h` 与 Kconfig 里对上号：

| 宏                    | 来源                                                      | 默认值                                         |
| --------------------- | --------------------------------------------------------- | ---------------------------------------------- |
| `ESP_TASK_MAIN_STACK` | `CONFIG_ESP_MAIN_TASK_STACK_SIZE + TASK_EXTRA_STACK_SIZE` | 3584 + 512 = **4096 字节**（newlibnano 时 +0） |
| `ESP_TASK_MAIN_PRIO`  | `ESP_TASK_PRIO_MIN + 1`                                   | 1                                              |
| `ESP_TASK_MAIN_CORE`  | `CONFIG_ESP_MAIN_AFFINITY_*`                              | 钉在 **CPU0**                                  |

`main_task` 的生命周期（同文件）：打日志 `main_task: Started on CPU0` → **回收启动栈**（见下）→ 初始化任务看门狗 → `main_task: Calling app_main()` → 调你的 `app_main()` → 返回后打 `Returned from app_main` → `vTaskDelete(NULL)` 自删。自删之后栈和 TCB 由 Idle 任务回收（[[2026-08-26-freertos-deep-dive-ch9-blocking-delay-idle|第九章]]讲过这套延迟回收）。

两个直接推论：

1. **`app_main` 里深度递归/大局部数组，烧的是 4096 字节的 main 栈**，不是"系统栈"。很多人在 `app_main` 里写初始化大循环 + 大缓冲，爆的是这里。改法：`idf.py menuconfig` → ESP System Settings → Main task stack size，或者干脆把重活搬进自建任务。
2. `app_main` 返回后 main 任务消失，它的栈**归还堆**——那 4KB 不是永久占用。

### 2. 启动栈的回收

调度器起来之前，CPU 跑在每核一根的**启动栈**（裸机时代的系统栈）上。`main_task` 的第一件事 `reclaim_startup_stack_memory_for_heap()` 确认所有核都完成 FreeRTOS 初始化、启动栈不再被用，然后 `heap_caps_enable_nonos_stack_heaps()` 把这块 RAM **并入堆**。这就是"启动早期可用内存少、跑起来后 `xPortGetFreeHeapSize()` 反而变大"的原因——内存的地基本身也是循环利用的。

---

## 21.7 实验：在 QEMU 里亲手爆一次栈

理论全部到位，现在复现、观察、测量。全程 `idf.py qemu monitor`，无需硬件。

### 1. 建项目

```bash
cd ~ && idf.py create-project freertos-ch21 && cd freertos-ch21
idf.py set-target esp32
```

`main/main.c` 整体替换为：

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static TaskHandle_t s_buster;

/* 递归爆栈任务：volatile 大数组阻止优化器复用栈帧 */
static void deep_recursion(int depth)
{
    volatile char pad[256];
    pad[0] = (char)depth;              /* 防止整帧被优化掉 */
    (void)pad;
    deep_recursion(depth + 1);         /* 无终止条件：等栈爆 */
}

static void buster(void *arg)
{
    printf("[buster] start, free stack %u bytes\n",
           (unsigned)uxTaskGetStackHighWaterMark(NULL));
    deep_recursion(0);
}

/* 监控任务：每 200ms 报一次 buster 的历史最小剩余 */
static void monitor(void *arg)
{
    for (;;) {
        printf("[monitor] buster free stack: %u bytes\n",
               (unsigned)uxTaskGetStackHighWaterMark(s_buster));
        vTaskDelay(pdMS_TO_TICKS(200));
    }
}

void app_main(void)
{
    xTaskCreate(monitor, "monitor", 2048, NULL, 3, NULL);
    xTaskCreate(buster,  "buster",  2048, NULL, 2, &s_buster);
}
```

设计意图：`buster` 优先级**低于** `monitor`——`vTaskDelay` 的周期性切换保证 canary 检查有触发机会（检测只在切换时做，两个都忙等的任务是照不到镜子的）。

### 2. 跑起来：高水位一路下探

```bash
idf.py qemu monitor
```

典型输出（数值随编译选项浮动，看趋势）：

```text
I (3xx) main_task: Started on CPU0
I (3xx) main_task: Calling app_main()
[buster] start, free stack 1952 bytes
[monitor] buster free stack: 1952 bytes
[monitor] buster free stack: 864 bytes
[monitor] buster free stack: 320 bytes
***ERROR*** A stack overflow in task buster has been detected.
```

读数解读：创建即填充 0xa5，初始"剩余"≈2048 减去起始帧（CPSA/TLS/入口帧对齐开销）；每层递归吃约 272 字节（256 数组 + 帧与对齐）；三~四层后 `0xa5` 区被写穿。最后一次深潜写坏了栈基 canary，`monitor` 的 `vTaskDelay` 触发切换，`vTaskSwitchContext()` 的检查当场翻脸。随后 panic 处理器打印回溯并按默认配置重启（外层格式随 `CONFIG_ESP_SYSTEM_PANIC_*` 与版本而异，识别锚点就是 `***ERROR***` 那一行）；QEMU 里表现为复位后重新跑，`Ctrl-]` 退出。

### 3. 变体实验

1. **换检测档位**：`idf.py menuconfig` → Component config → FreeRTOS → configCHECK_FOR_STACK_OVERFLOW，切到 `PTRVAL`（方法一）。多数递归场景下它**报不出来**——每次切出时 SP 早已回到浅层（递归深处从未发生切换）。亲眼见过这个漏报，21.3 节的表格就不再是表格而是经验。
2. **量真实消耗**：把 `deep_recursion` 换成你的业务函数（带 `printf` 的、带 `%f` 的、带 1KB 数组的），`monitor` 的读数差就是每一项的**真实栈价**——比任何参考表都准。
3. **爆中断栈（反面教材）**：在 GPIO ISR 里放 `volatile char buf[1200]`，把 `FREERTOS_ISR_STACKSIZE` 调到 1536 默认值，观察"没有 ERROR、只是随机硬死"的样子；再调大它看症状消失。这个实验对建立"中断栈无检测"的肌肉记忆非常值。
4. **调试器视角**：`idf.py qemu gdb`，`break vApplicationStackOverflowHook`，命中后 `p pcTaskName`、`p/x pxCurrentTCBs[0]->pxStack` 直接看案发现场。更系统的调试工作流留给[[2026-08-26-freertos-deep-dive-ch24-debugging-tracing-pitfalls|第二十四章]]。
5. **watchpoint（真机线）**：`CONFIG_FREERTOS_WATCHPOINT_END_OF_STACK=y` 配合 JTAG/OCD 是它的主场（gdb 以 SIGTRAP 停在写坏 canary 的那条指令上）；QEMU 对 debug watchpoint 的支持不作为本系列基线，此实验建议真机。

---

## 21.8 小结

- **布局**：ESP32 固件 = 少量 IRAM/DRAM 段 + 大量经 MMU 映射的 flash 段（XIP）。bootloader 按段加载地址决定"搬或不搬"（`esp_image_format.c` 的 `should_load()`/`should_map()`），应用启动清 `.bss`；FreeRTOS 的切换路径与 `FromISR` 函数由 `linker.lf` 片段钉进 IRAM——flash 擦写期间代码必须仍在可执行内存，是正确性约束。
- **任务栈**：动态创建时就是 `heap_caps_malloc(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)` 的一块堆；`StackType_t=uint8_t` 使栈深单位为字节（Vanilla 为字）；`portSTACK_GROWTH=-1` 向低地址生长，溢出砸的是堆里邻居。Xtensa 窗口寄存器使栈压力延迟、成批到来，SP 强制 16 字节对齐。
- **检测**：两档都在 `vTaskSwitchContext()` 切出时做——方法一查瞬时 SP，方法二查栈基 16 字节 canary（IDF 默认）；都是事后验尸，各有明确漏报面。IDF 另给 weak 默认 hook（报任务名 + abort + 重启）。
- **测量**：`uxTaskGetStackHighWaterMark` 数连续 `0xa5`（IDF 单位字节），是量级工具不是仪表；`CONFIG_FREERTOS_WATCHPOINT_END_OF_STACK` 用最后一个硬件 watchpoint 把捕获提前到**写坏的那条指令**，代价是 gdb 少一个 watchpoint、可用栈减至多 60B。
- **中断栈**：每核一根静态 `port_IntStack`（默认 1536B，`_frxt_int_enter` 三步切换），无任何溢出检测——ISR 里的大局部数组是禁忌；入口帧仍会占用被打断任务的一小块栈。
- **main 任务**：`app_main()` 跑在 4096 字节（默认）的 main 栈上，返回即自删、栈归还堆；启动栈在调度器就绪后并入堆。

至此，Part V 的地基（堆、栈、布局）全部闭合。你已经知道每一个字节的来路与去处——而这恰好是下一章的最佳起跑点：IDF FreeRTOS 的 SMP 改造全景。当一根栈变成**两根核各自的执行流**，"当前任务"从单数变成 `pxCurrentTCBs[]` 数组、临界区从关中断变成自旋锁、每个核都要有自己的 Idle 任务和中断栈——本章你已经在 `vTaskSwitchContext()`、`_frxt_int_enter()`、`port_IntStack[][N]` 里反复见过这些 SMP 化的痕迹。下一章，[[2026-08-26-freertos-deep-dive-ch22-smp-refactor-overview|第二十二章]]把这些线索收拢成完整的改造地图。
