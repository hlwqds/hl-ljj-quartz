---
title: 栈高水位与溢出侦探
date: 2026-08-30 04:40:00
description: F429 裸机实验室（十六）——uxTaskGetStackHighWaterMark 的 0xA5 涂料原理（tasks.c 源码逐行）、configCHECK_FOR_STACK_OVERFLOW 三档对照、递归爆栈触发 hook 的现场，与 openocd mdw 直接看 A5 海岸线的双证据链
tags: [STM32, FreeRTOS, Lab]
---

# 栈高水位与溢出侦探

> **状态声明**：本章属「先成文、后实跑」——实验设计、寄存器推导、预期输出均已写定，但**尚未在真机上执行**；
> 文中所有「预期输出」均为待实测核销的推导值，实跑后回填真实数据。板上事实查不到的一律标「待核对」，
> 绝不编造运行日志与寄存器读数。实验载体是序章救回的 `~/stm32/f429-freertos`，栈单位与高水位读数法承接
> [[2026-08-30-f429-lab-ch14-stack-units-word-vs-byte|ch14：栈的单位]]。

## 本章装备清单

| 分类       | 装备                    | 价格/状态 | 用途               |
| ---------- | ----------------------- | --------- | ------------------ |
| 已有       | 挑战者 F429-V2 板       | ✅        | 实验主体           |
| 已有       | 野火 DAP 仿真器         | ✅        | 烧录/调试          |
| 已有       | Mini-USB 线             | ✅        | 供电 + 串口        |
| 已有       | 笔记本（Fedora 工具链） | ✅        | 构建与观测         |
| 沿用基础盘 | 无新增                  | —         | 栈侦探单步软件实验 |

## 本章会遇到的词

| 词                                | 一句话版                                     | 详见     |
| --------------------------------- | -------------------------------------------- | -------- |
| 栈高水位（Stack High Water Mark） | 任务栈「史上最少还剩多少」的读数             | 目标节   |
| 0xA5 涂料                         | 任务创建时把整块栈刷成 0xA5 的标记底色       | 涂料节   |
| 满递减栈 / portSTACK_GROWTH       | 栈向低地址生长：用得越深地址越小             | 数水位节 |
| SP / PSP                          | 栈指针寄存器；PSP 是任务专用的那个           | 三档节   |
| 魔数（0xa5a5a5a5）                | 连续 4 字节涂料＝「这格没被碰过」的暗号      | 三档节   |
| 栈溢出 hook                       | 爆栈时内核回调你预埋的处理函数               | 侦探节   |
| weak（弱符号）                    | 允许被同名函数覆盖的「默认实现」占位         | 侦探节   |
| configCHECK_FOR_STACK_OVERFLOW    | 溢出检测档位开关：0 关 / 1 查指针 / 2 双保险 | 三档节   |
| volatile                          | 「别优化我的读写」的编译器指令               | 实验节   |
| heap_4 / ucHeap                   | FreeRTOS 自带堆分配器与它管理的那块静态数组  | 实验节   |
| nm                                | 列 ELF 符号表（名字→地址）的工具             | 埋点节   |
| bp / mdw / halt                   | openocd 的断点、读内存、停机三板斧           | 埋点节   |

## 目标（先说结论）

- ch14 把 `uxTaskGetStackHighWaterMark()` 当仪表用；本章**拆开仪表**：任务创建时整块栈被涂成
  `0xA5`（`tskSTACK_FILL_BYTE`，tasks.c:121），水位函数就是「从栈底向上数连续 0xA5 还剩几格」——
  全部源码 11 行（tasks.c:6470-6481）。
- 它的本质是**事后法医**，不是事前预警：涂料是创建时刻一次性刷的，函数只是回头验伤痕。数字含义 =
  「历史上最深处之上、从未被碰过的字数」，单调不升。
- 溢出侦探三档（`configCHECK_FOR_STACK_OVERFLOW` 0/1/2）差异成表；本工程实配 **2** 档
  （FreeRTOSConfig.h:32）= PSP 边界（PSP＝Process Stack Pointer，任务栈指针——Cortex-M 上任务跑用
  PSP、中断处理用 MSP，双栈设计下一章拆）+ 涂改检测**双保险**（stack_macros.h:101-122），检查时机是
  `vTaskSwitchContext()`（内核每次切换时「选出下一个跑谁」的函数）里**切出的瞬间**（tasks.c:5259）——不切换就永远不检查。
- 实验：递归函数（自己调自己的函数，每层调用往栈上压一帧）每层吃 200 字节直到爆栈（把分配的栈用穿边界）→ 工程里现成的 `vApplicationStackOverflowHook()`
  （main.c:85-92）打印任务名并死循环冻结现场；同代码换 1024 字栈 → 无事生还。再加一层 openocd 埋点：
  `mdw`（openocd 的「按 32 位字读内存」命令）直接看栈区 0xA5 海岸线（涂料区与脏区的分界线）的移动——软件水位与内存实读两条证据链在此合流（序章方法论）。

> 📖 **术语卡：栈高水位（Stack High Water Mark）**
> **是什么**：一个任务从创建至今，栈最多用到过多么深——以「从未被用过的字数」报出来。
> **为什么存在**：栈会不会爆取决于历史最深用量而不是当下用量；水位读数是配栈大小（该给多少字）的依据。
> **类比**：泳池最高水线——游过一次之后墙上的印子告诉你水最深到过哪。
> ⚠️ 类比边界：水线印的是「最高曾到」，水位报的是「从未用到的余量」，两者互补、不是同一个数；而且伤痕不会愈合——读数单调不升。

## 水位机制揭秘：一桶 0xA5 涂料的两用

### 1. 涂料的来历

```c
/* tasks.c:121 */
#define tskSTACK_FILL_BYTE    ( 0xa5U )

/* tasks.c:131-134：三个开关任一打开，栈就要「刷成已知值」——
 * 溢出检测 >1 档、trace facility、高水位 API，都吃同一桶涂料 */
#if ( ( configCHECK_FOR_STACK_OVERFLOW > 1 ) || ( configUSE_TRACE_FACILITY == 1 ) \
   || ( INCLUDE_uxTaskGetStackHighWaterMark == 1 ) || ( INCLUDE_uxTaskGetStackHighWaterMark2 == 1 ) )
    #define tskSET_NEW_STACKS_TO_KNOWN_VALUE    1

/* tasks.c:1832-1837（prvInitialiseNewTask）：创建任务时整块涂满 */
#if ( tskSET_NEW_STACKS_TO_KNOWN_VALUE == 1 )
    ( void ) memset( pxNewTCB->pxStack, ( int ) tskSTACK_FILL_BYTE,
                     ( size_t ) uxStackDepth * sizeof( StackType_t ) );
#endif
```

**代码走读：** 涂料怎么刷、何时刷

| 片段                                                                     | 作用                                                                                                                      |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `tskSTACK_FILL_BYTE ( 0xa5U )`                                           | 涂料颜色：单字节 0xA5，四个连起来就是后面要用的魔数 `0xa5a5a5a5`                                                          |
| `#if ( ( ... ) \|\| ( ... ) )` 大开关                                    | 溢出检测 >1 档、trace、水位 API 三者任一打开才启用刷涂料——不用就省下这步启动开销                                          |
| `memset( pxNewTCB->pxStack, ..., uxStackDepth * sizeof( StackType_t ) )` | memset＝C 标准库「把一段内存每字节填成指定值」；这里把任务整块栈（从栈基 `pxStack` 起、`uxStackDepth` 个字）全部刷成 0xA5 |

> 📖 **术语卡：0xA5 涂料（栈填充法）**
> **是什么**：创建任务那一刻，把整块栈的每个字节都写成 0xA5；之后哪里被写过，哪里就不再是 A5。
> **为什么存在**：内存单元没有「用过/没用过」标签——先刷一层已知底色，回头再看哪里的底色还在，就知道哪里没碰过。
> **类比**：新黑板先整面蹭上粉笔灰，写过字的地方擦掉了也会留下痕迹——没留痕的区域就是没写过的。
> ⚠️ 类比边界：黑板上的痕可以擦干净；栈里被写过的字节即使「逻辑上已弹出」也还是脏值——这既是法医式读数的根据，也是它报不出「当下用量」的原因。

本工程 `INCLUDE_uxTaskGetStackHighWaterMark=1`（FreeRTOSConfig.h:59）——这就是 ch14 说「不用改配置
就能量水位」的根据：**水位 API 本身就是刷涂料的触发条件之一**。

### 2. 数水位：11 行源码

```c
/* tasks.c:6470-6481（prvTaskCheckFreeStackSpace），完整摘录 */
STATIC configSTACK_DEPTH_TYPE prvTaskCheckFreeStackSpace( const uint8_t * pucStackByte )
{
    configSTACK_DEPTH_TYPE uxCount = 0U;
    while( *pucStackByte == ( uint8_t ) tskSTACK_FILL_BYTE )
    {
        pucStackByte -= portSTACK_GROWTH;   /* growth=-1 → 指针向上走 */
        uxCount++;
    }
    uxCount /= ( configSTACK_DEPTH_TYPE ) sizeof( StackType_t );  /* 字节 → 字 */
    return uxCount;
}
```

**代码走读：** `prvTaskCheckFreeStackSpace` 这 11 行在数什么

| 行                                 | 作用                                                                                             |
| ---------------------------------- | ------------------------------------------------------------------------------------------------ |
| `while( *pucStackByte == 0xA5 )`   | 从起点逐字节看：还是涂料就继续——连续 0xA5 段＝从未被写过的区                                     |
| `pucStackByte -= portSTACK_GROWTH` | growth＝−1，减去负一＝加一：指针向高地址走（满递减栈从低地址的栈基往深处用，未用区在高地址方向） |
| `uxCount /= sizeof( StackType_t )` | 数出来的是字节数，除以 4 换回「字」——ch14 单位之争的根源就在这一行                               |

> 📖 **术语卡：满递减栈（Full Descending Stack）与 SP**
> **是什么**：栈的生长方向约定。满递减＝数据越压地址越小：SP（Stack Pointer，栈指针，Cortex-M 的 R13 寄存器）始终指向最后压入的有效数据，每压一个字 SP 减 4。Cortex-M 的任务栈都是满递减，所以「用得越深」＝「地址越小」。
> **为什么存在**：入栈/出栈要硬件自动增减 SP，方向必须先约定死；方向定了，才能从栈基（最低地址）一路向高地址扫「没动过的涂料」。
> **类比**：从笔记本最后一页往前写——写得越多，用到的页码越小；高水位就是「还没写过的最靠前的空白页」位置。
> ⚠️ 类比边界：`portSTACK_GROWTH=-1` 只是 FreeRTOS 的宏约定——世上也有栈向高地址生长的处理器，那时扫描方向整个反过来。

调用方（uxTaskGetStackHighWaterMark2，tasks.c:~6500）在 `portSTACK_GROWTH<0` 时从 `pxStack`
（栈基=最低地址）起扫。于是读数的精确语义：

| 问题       | 答案                                                                                                     |
| ---------- | -------------------------------------------------------------------------------------------------------- |
| 数字是什么 | 从栈底向上**连续**未被写过的 0xA5 字数=历史最深处之上的余量                                              |
| 单位       | 字（`/sizeof(StackType_t)`，CM4F 除以 4；IDF 除以 1 是字节）                                             |
| 初始值     | ≈ 栈深（减去任务入口上下文那一小截；入口上下文＝任务栈上预先压好的第一帧寄存器现场，首次切换时取出来用） |
| 会回升吗   | 不会——伤痕不会愈合，它是**历史最小值**                                                                   |
| 谁来调用   | 你。内核从不主动巡检（`O(栈深)`——耗时与栈深成正比——的扫描，挂调度器里太贵）                              |

「事后法医」的完整逻辑链：涂料刷在创建那一刻 → 任务跑动**抹掉**路过处的 0xA5 → 函数回头数没抹掉的。
它测量的是**痕迹**，不是**事件**——所以它给不出「马上要爆」的告警（那需要边界保护，Vanilla 没有；
IDF 的硬件 watchpoint 方案见[[2026-08-26-freertos-deep-dive-ch21-stack-and-memory-layout|FreeRTOS（廿一）]]21.4），
而且只认「连续」：局部数组跳过某段没写时，中间残留的 0xA5 会让读数虚高（ch14 写满 pad 的原因之一）。

## 溢出侦探：三档检测与工程档位

`include/stack_macros.h` 按配置展开成三个版本的 `taskCHECK_FOR_STACK_OVERFLOW()` 宏：

| 档  | 名称与出处                          | 检查什么                                                                             | 抓得住                             | 抓不住                           |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------- | -------------------------------- |
| 0   | 关闭（stack_macros.h:149-150 空宏） | 什么都不查                                                                           | —                                  | 一切                             |
| 1   | 查指针（stack_macros.h:68-80）      | 切出时保存的 SP（栈指针：指向当前栈顶的寄存器）是否 ≤ 栈基+`portSTACK_LIMIT_PADDING` | 切换瞬间已在界外的 SP              | 深潜后浮回的溢出（SP 已回去）    |
| 2   | 查魔数（stack_macros.h:101-122）    | SP 边界 **OR** 栈基 4 字 ≠ `0xa5a5a5a5` 双保险                                       | 任何写脏栈基 16 字节的**历史越界** | 整段跳过栈基的越界（大数组跨栏） |

`portSTACK_LIMIT_PADDING` 默认 0（stack_macros.h:52-53），即本板方法一就是裸比较。方法二的原文
（本档的「双保险」长这样）：

```c
/* include/stack_macros.h:101-122（portSTACK_GROWTH < 0 摘录） */
const uint32_t * const pulStack = ( uint32_t * ) pxCurrentTCB->pxStack;
const uint32_t ulCheckValue = ( uint32_t ) 0xa5a5a5a5U;
if( ( pxCurrentTCB->pxTopOfStack <= pxCurrentTCB->pxStack + portSTACK_LIMIT_PADDING ) ||
    ( pulStack[ 0 ] != ulCheckValue ) || ( pulStack[ 1 ] != ulCheckValue ) ||
    ( pulStack[ 2 ] != ulCheckValue ) || ( pulStack[ 3 ] != ulCheckValue ) )
{
    vApplicationStackOverflowHook( ( TaskHandle_t ) pxCurrentTCB, pcOverflowTaskName );
}
```

**代码走读：** 2 档的四个条件 OR 相连，任一命中即调 hook

| 条件                                     | 含义                                                                                       |
| ---------------------------------------- | ------------------------------------------------------------------------------------------ |
| `pxTopOfStack <= pxStack + padding`      | 方法一残留：`pxTopOfStack`（TCB 里记的「最后保存的栈顶」）已不高于栈基——切出瞬间人已在界外 |
| `pulStack[0..3] != 0xa5a5a5a5`（四选一） | 栈基最底 4 个字（16 字节魔数区）任何一字被写脏——**历史上**曾越界，哪怕此刻 SP 已经浮回来   |

三个关键事实钉死：

1. **检查时机=切出的瞬间**：调用点在 `vTaskSwitchContext()`（tasks.c:5259），此刻 `pxCurrentTCB`
   （「当前在跑谁」的内核指针，ch15 已拆）还是**刚下场**的任务——检测只对「正在被切出的那位」做，别的任务此刻爆没爆要等它下次下场。
2. **不切换就不检查**：两个互相忙等的任务永远不阻塞，检查永不发生（ch21 的漏报面，本章实验用
   fast 任务的周期抢占当「天然触发器」规避了它）。
3. **hook 必须应用自己写**（Vanilla 无 weak 默认，不提供则链接失败）。本工程已写好且方案是
   「保现场」型（main.c:85-92）：打印任务名 + 提示「单位是字」+ **死循环**——把案发现场冻在
   hook 里等 openocd 上来验尸，比 IDF 默认 weak hook 的「打印后 abort 重启」更适合教学
   （两种取舍的对照见文末表格）。

> 📖 **术语卡：hook（钩子函数）与 weak（弱符号）**
> **是什么**：hook＝内核在特定事件发生时回调的应用函数，`vApplicationStackOverflowHook` 就是 FreeRTOS 预留的「爆栈了叫你一声」接口；weak（弱符号）＝链接器允许被同名「强符号」覆盖的默认实现。
> **为什么存在**：爆栈后要不要停机、要不要保现场，只有应用自己知道——内核只负责喊人，不替你做主。
> **类比**：物业（内核）发现漏水只负责敲门（调 hook），怎么修由住户（应用）决定。
> ⚠️ 类比边界：Vanilla 版连默认 weak 实现都不给——不写 hook 直接链接失败；IDF 给了 weak 默认（打印＋abort 重启），覆盖与否自己选。

## 实验：递归潜水，两层对照

```c
static void dive(int depth, int maxd)
{
    volatile char pad[200];                     /* 每层吃 ~200B + 帧杂项 */
    for (unsigned i = 0; i < sizeof(pad); i++) {
        pad[i] = (char)(depth + i);             /* 写满：让伤痕连续（法医才认） */
    }
    uart_puts("[dive] level "); uart_putdec((uint32_t)depth); uart_puts("\r\n");
    if (depth < maxd) {
        dive(depth + 1, maxd);                  /* 递归下潜，maxd 封顶 */
    }
}

static void dive_task(void *arg)
{
    (void)arg;
    uart_puts("[dive] start\r\n");
    dive(0, 8);                                 /* 最多 8 层：小栈必爆，大栈生还 */
    uart_puts("[dive] survived\r\n");
    for (;;) { vTaskDelay(pdMS_TO_TICKS(1000)); }
}

/* 案发组：256 字 = 1024B；对照组：把 256 改成 1024（=4096B），其余一字不动 */
xTaskCreate(dive_task, "dive", 256, NULL, 1, NULL);
```

**代码走读：** dive 的三处刻意设计

| 片段                     | 作用                                                                                                                                 |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `volatile char pad[200]` | volatile＝告诉编译器「这个变量随时可能被外部观察，别优化对它的读写」；不加的话，这个从没被读过的数组可能被编译器整个删掉，栈就白吃了 |
| `for … pad[i] = …`       | 写满 pad：让栈的「伤痕」连续——法医（水位扫描）只认**连续**的 0xA5 缺口，跳着写会读数虚高                                             |
| `dive(depth + 1, maxd)`  | 递归（函数调用自己）：每层调用压一个栈帧（该层的局部变量＋返回地址），`maxd` 封顶防止无限递归                                        |

预算算术（推导，`-O0`（编译器「不优化」档：栈帧最大最肥、行为最好预测，教学实验专用）帧肥按 16–32B/层估）：

```text
案发组：1024B − 入口 64B = 960B 可花；每层 ≈ 200+16~32B ≈ 216–232B
        → 第 4 层打印时 64+5×~224+打印帧 ≈ 1180B > 1024B，SP 已越界 ~150B
对照组：4096B − 64B = 4032B；8 层全下潜 ≈ 1.8–1.9KB，余量过半 → 生还
```

爆栈后发生什么的时序推演（决定串口上先看到什么）：递归越界写**不会立刻停**——CM4 没有 MMU
（Memory Management Unit，内存管理单元：服务器 CPU 用它拦截越界访问，越界当条指令就段错误——你的主场；
嵌入式裸机没有这层保护），SP 越过栈基照样写，砸的是 heap_4（FreeRTOS 自带的堆分配方案第 4 号：一块名叫
ucHeap 的静态数组＋首次适配分配＋相邻空闲块合并）里低地址方向的邻居（空闲块/别的块）。案发组的「死亡证明书」
由两个时机之一签发：① fast 任务（ch14 创建的优先级 2 周期打印任务）每 200ms 唤醒抢占（高优先级就绪立刻
打断低优先级——ch15 的术语卡）dive（优先级 1）→ 切出瞬间检查 →
魔数已脏 → hook 立刻打印；② 侥幸潜完 8 层、打印 survived、`vTaskDelay` 阻塞切换 → 同样触发。
哪个先到取决于涂料被写脏的时机与 fast 的节拍相位——**标待实测**。

## 埋点：软件水位 × 内存实读，证据链合流

序章方法论的升级用法：软件读数（水位）和 openocd 裸读（内存）互相印证。

```bash
# 1) 拿地址：ucHeap（64KB 堆、所有任务栈都在里面）与 hook 的落位
arm-none-eabi-nm build/f429-freertos.elf | grep -E "ucHeap|vApplicationStackOverflowHook"

# 2) 在 hook 下硬件断点，爆栈即冻结（现场比 hook 自己打印的更完整）
openocd -c "init; reset run; sleep 3000" \
        -c "bp <hook地址> 2 hw; resume; sleep 5000; halt"

# 3) 裸读栈区，找 0xA5 海岸线（地址待实测回填，ucHeap 在 .bss，0x2000xxxx）
> mdw 0x2000xxxx 16
```

**命令拆解：** `arm-none-eabi-nm build/f429-freertos.elf | grep -E "ucHeap|vApplicationStackOverflowHook"`

| 部分                                | 作用                                                                                                               |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `arm-none-eabi-nm`                  | nm＝列出 ELF（编译链接的最终产物，带「名字→地址」符号表）里的所有符号；`arm-none-eabi-` 前缀＝ARM 裸机交叉工具链版 |
| `build/f429-freertos.elf`           | 要查的固件镜像文件                                                                                                 |
| `grep -E "ucHeap\|vApplication..."` | 只留名字含 ucHeap 或 vApplicationStackOverflowHook 的行（`-E`＝启用正则，`\|`＝「或」）                            |

**你会看到**（推导格式，地址待实测回填）：`2000xxxx B ucHeap`、`0800xxxx T vApplicationStackOverflowHook`——B＝.bss 段（未初始化大数组）、T＝.text 段（函数）。
**失败了先查**：路径不对（不在仓库根执行、build/ 没生成）、裁剪开了 LTO 导致符号被改名合并。

**命令拆解：** `openocd -c "init; reset run; sleep 3000" -c "bp <hook地址> 2 hw; resume; sleep 5000; halt"`

| 部分                 | 作用                                                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `init`               | 连接芯片并完成识别                                                                                                        |
| `reset run`          | 复位芯片并立刻放跑（程序从头开始运行）                                                                                    |
| `sleep 3000`         | 等 3000 毫秒，让任务调度进入稳态                                                                                          |
| `bp <hook地址> 2 hw` | 下断点：地址＝hook 函数入口；`2`＝断点长度 2 字节（Thumb 指令按 2 字节对齐）；`hw`＝用芯片 FPB 硬件断点单元，不改动 Flash |
| `resume`             | 放行 CPU 继续跑，直到撞上断点                                                                                             |
| `sleep 5000`         | 最多等 5 秒，给爆栈事件时间发生                                                                                           |
| `halt`               | 兜底停机——撞没撞上断点都停下来看现场                                                                                      |

**你会看到**（推导）：断点命中时 openocd 报 `halted due to breakpoint`，pc 落在 hook 入口附近。
**失败了先查**：nm 给的函数地址最低位是 1（Thumb 标记位），下硬件断点或许要先用减 1 后的偶数地址——本条待实测核对；hook 迟迟不命中则回查爆栈是否真发生（水位是否归零）。

**命令拆解：** `mdw 0x2000xxxx 16`

| 部分         | 作用                                                             |
| ------------ | ---------------------------------------------------------------- |
| `mdw`        | memory dump word：按 32 位字为单位读内存，可连读一串             |
| `0x2000xxxx` | 起始地址——栈区位置（ucHeap 在 .bss，任务在堆内的偏移待实测回填） |
| `16`         | 连读 16 个字（＝64 字节），足够跨过海岸线看清两侧                |

`mdw` 里的海岸线长这样（**示意推导，非实拍**）：每行 4 字，`a5a5a5a5` 是没动过的深海，非 A5 的
第一个字就是历史最深水位线——对照组的栈区应是整片深海 + 浅浅一层使用痕迹：

```text
案发组（爆栈冻结后）：
0x2000xxxx: 34306576 6c20656c ... ...        ← 栈基附近已被 "[dive] level" 的帧数据写穿
0x2000xxxx: a5a5a5a5 a5a5a5a5 ...            ← 再往下才是没碰过的涂料

对照组（survived 后）：
0x2000xxxx: a5a5a5a5 a5a5a5a5 a5a5a5a5 ...   ← 栈基 16 字节魔数完好=方法二不触发
```

两条证据链的合流点：`uxTaskGetStackHighWaterMark()` 报的数字 ×4 + 栈基地址，应该**正好等于**
mdw 里海岸线的位置——软件说「还剩 N 字」，内存里第 N+1 字就不是 A5。两边对上了，机制的讲解
才算被真机签字。

## 预期输出（待实测核销）

案发组串口（层号与触发时机为推导区间，待实测回填）：

```text
[dive] start
[dive] level 0
[dive] level 1
[dive] level 2
[dive] level 3
[dive] level 4        ← 可能完整打印、可能半行乱码、可能根本没到这行
[HOOK] stack overflow: dive
把栈参数改大（记住：单位是字！x4 才是字节）
```

对照组：

```text
[dive] start
[dive] level 0
...
[dive] level 7
[dive] survived
[fast] tick ...        ← 系统一切如常
```

水位数字表（监控任务每 2s 报，单位：字；推导区间）：

| 任务      | 栈深（字） | 预期高水位（字）    | 备注                               |
| --------- | ---------- | ------------------- | ---------------------------------- |
| dive 案发 | 256        | 0（或永远没机会报） | 栈基被写脏，扫描起点即非 A5 → 归零 |
| dive 对照 | 1024       | ≈ 550–600           | 4032B−8 层×~224B−打印帧 ≈ 2200B/4  |
| fast      | 256        | ≈ 214–224           | ch14 的读数，本章复测              |
| slow      | 256        | ≈ 224–232           | 同上                               |

## 与主系列对照

| 维度         | 本板（Vanilla/CM4F）                     | ESP32（IDF）                                                                                               |
| ------------ | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 水位单位     | 字（`sizeof(StackType_t)`=4）            | 字节（=1）                                                                                                 |
| 默认检测档   | 自己配（本工程=2，FreeRTOSConfig.h:32）  | Kconfig（乐鑫的菜单式配置系统）默认 CANARY=2（CANARY＝金丝雀：涂料法的别称，典故是矿工带金丝雀下矿探毒气） |
| hook         | 必须自写；本工程=打印+死循环保现场       | weak 默认：打印任务名+abort+重启                                                                           |
| 事前预警     | 无                                       | 可选硬件 watchpoint（观察点：调试单元盯住一个地址，谁写它谁触发停机——写脏当条指令即触发）                  |
| 爆栈典型下场 | hook 打印任务名（+被砸邻居的随机后遗症） | `***ERROR*** A stack overflow ...` + panic                                                                 |

机制本体（涂料、扫描、双保险）两边同源——差异全在「谁替你把机制工程化」。这是
[[2026-08-26-freertos-deep-dive-ch24-debugging-tracing-pitfalls|FreeRTOS（廿四）]]排坑方法论的第 1 案
（栈溢出的千奇百怪症状）在另一块芯片上的落地：症状随机，但验尸工具是同一套。

## 本章待核对清单

| #   | 项                                                                              | 核对方法                                                                                           |
| --- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| 1   | 案发组爆点层号（推导 4±1 层）与触发时机（fast 抢占切出 vs survived 后阻塞切换） | 串口日志 + bp hook 的命中时刻                                                                      |
| 2   | 对照组 survived + 高水位 ≈550–600 字                                            | monitor 读数回填                                                                                   |
| 3   | mdw 海岸线位置 = 栈基 + 水位×4（两证据链合流点）                                | nm 定位 + mdw 对照                                                                                 |
| 4   | `ucHeap`/hook 实际地址（本文 0x2000xxxx 占位）                                  | `nm build/f429-freertos.elf`                                                                       |
| 5   | 案发组是否出现「hook 之外的死法」（砸坏 fast 的 TCB/栈、串口静默）              | openocd 冻结后 `mdw` 邻居块 + reg pc                                                               |
| 6   | 每层实际帧耗（推导 216–232B，`-O0` 依赖）                                       | 爆点层号反推，或 objdump（反汇编工具：把机器码翻回汇编，直接看每层帧压多少字节）反汇编 dive 帧大小 |

下一章：[[2026-08-30-f429-lab-ch17-pendsv-single-step|PendSV 单步：亲眼看上下文切换]]——
本章冻结在 hook 里的现场，正是下一章 DAP 单步 `xPortPendSVHandler` 的入口素材：R4–R11 怎么压栈、
PSP 怎么换手，一条指令一条指令看。系列总目录见[[2026-08-30-f429-lab-series-index|F429 裸机实验室索引]]。
