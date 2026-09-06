---
title: "FreeRTOS 深度解析（五）：任务的生与死"
date: 2026-08-26
description: "逐行拆解 xTaskCreate 到就绪链表的完整调用链，逐字段解剖 TCB_t，看懂 Xtensa 端口如何伪造初始栈帧，再理清 vTaskDelete 的两条回收路径；配 QEMU 双任务创建/栈体检/删除实验。"
tags: [freertos, rtos, esp32, esp-idf, qemu, tasks, tcb, xtensa]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 5. **第五章：任务的生与死**

# FreeRTOS 深度解析（五）：任务的生与死

从本章起进入 `tasks.c`——内核真正的心脏。第一章里我们写下 `xTaskCreate(fast_task, "fast", 2048, NULL, 5, NULL)` 就转身去看输出了；这一章把这行代码拆开看个底朝天：一次调用在内核里走了哪几步、TCB（Task Control Block，任务控制块）里每个字段是干嘛的、一个"还没跑过"的任务凭什么能被调度器当作"正在跑的任务"来恢复、以及 `vTaskDelete` 之后内存什么时候才真正回来。

所有代码引用以 ESP-IDF v6.0.2 的默认内核树 `components/freertos/FreeRTOS-Kernel/`（即 IDF FreeRTOS 本体，Vanilla v10.5.1 的 SMP 改造 fork）为准；涉及 Vanilla 时对照 `FreeRTOS-Kernel` 上游 V10.5.1。

---

## 5.1 从 API 到就绪链表：一次创建的完整旅程

先给结论：**`xTaskCreate` 的一次调用 = 分配两块内存 + 填一个 TCB + 伪造一个栈帧 + 挂进就绪链表（可能顺手触发一次调度）**。下面按调用链逐步展开。

### 1. 入口：两个名字，一条路

在 IDF FreeRTOS 里，`xTaskCreate` 根本不住在 `tasks.c`——它是 `task.h` 里的一个 `static inline` 包装函数，转手就把活派给了带核亲和参数的版本：

```c
/* task.h（IDF fork）：xTaskCreate 只是 xTaskCreatePinnedToCore 的语法糖 */
static inline __attribute__( ( always_inline ) )
BaseType_t xTaskCreate( TaskFunction_t pxTaskCode,
                        const char * const pcName,
                        const configSTACK_DEPTH_TYPE usStackDepth,
                        void * const pvParameters,
                        UBaseType_t uxPriority,
                        TaskHandle_t * const pxCreatedTask )
{
    extern BaseType_t xTaskCreatePinnedToCore( ... /* 多一个 xCoreID 参数 */ );

    /* 用 tskNO_AFFINITY 创建"不绑核"任务 */
    return xTaskCreatePinnedToCore( pxTaskCode, pcName, usStackDepth,
                                    pvParameters, uxPriority,
                                    pxCreatedTask, tskNO_AFFINITY );
}
```

`tskNO_AFFINITY` 在 `task.h` 中定义为 `(( BaseType_t ) 0x7FFFFFFF)`，与合法核号（0、1）天然不冲突。`xTaskCreatePinnedToCore()` 和 `xTaskCreateStaticPinnedToCore()` 这对真正的实现函数住在 `esp_additions/freertos_tasks_c_additions.h`——这个文件会被 `#include` 进 `tasks.c` 一起编译，所以它们能直接访问 `TCB_t` 等内核私有类型。

> [!tip] Vanilla vs ESP-IDF：创建 API 的组织方式
>
> | 主题               | Vanilla FreeRTOS v10.5.1                        | IDF FreeRTOS（默认树）                                            |
> | ------------------ | ----------------------------------------------- | ----------------------------------------------------------------- |
> | `xTaskCreate` 位置 | `tasks.c` 内的正式函数                          | `task.h` 内 `static inline` 包装                                  |
> | 核亲和概念         | 无（单核假设）                                  | `xTaskCreatePinnedToCore()` 族，`xCoreID` 取 0/1/`tskNO_AFFINITY` |
> | 栈深参数类型       | `configSTACK_DEPTH_TYPE`（默认 16 位）          | `uint32_t`（`xTaskCreatePinnedToCore` 签名）                      |
> | 栈深单位           | **字**（word，多数端口 `StackType_t` 为 32 位） | **字节**（xtensa 端口 `portSTACK_TYPE` 为 `uint8_t`）             |
>
> 栈单位这条在第一章踩过一次，这里从源码上坐实：IDF 的 `portmacro.h` 把 `StackType_t` 定义成单字节，于是 `usStackDepth * sizeof( StackType_t )` 就是字节数——`task.h` 的注释也明说"specified as the NUMBER OF BYTES. Note that this differs from vanilla FreeRTOS"。

### 2. xTaskCreatePinnedToCore：两块内存的分配次序

`xTaskCreatePinnedToCore()`（默认、非 `CONFIG_FREERTOS_SMP` 分支）先分配栈、再分配 TCB：

```c
/* freertos_tasks_c_additions.h（节选，向下生长栈分支） */
pxStack = pvPortMallocStack( ( ( size_t ) usStackDepth ) * sizeof( StackType_t ) );
if( pxStack != NULL ) {
    pxNewTCB = pvPortMalloc( sizeof( TCB_t ) );
    if( pxNewTCB != NULL ) {
        memset( pxNewTCB, 0x00, sizeof( TCB_t ) );
        pxNewTCB->pxStack = pxStack;
    } else {
        vPortFreeStack( pxStack );      /* TCB 没拿到，栈还回去 */
    }
}
```

三个细节值得停一下：

1. **先栈后 TCB 不是随手写的**。xtensa 栈向下生长（`portSTACK_GROWTH` 为 `-1`），源码注释明说：这样分配是"让向下生长的栈不会长进 TCB"（`portSTACK_GROWTH > 0` 的端口则反过来先分 TCB 后分栈）。两块内存若被堆安排得相邻，越界时最先压坏的也是同一次创建的"自己人"，而不是堆里无辜的第三者。
2. **失败路径成对回收**。栈成功、TCB 失败时栈被 `vPortFreeStack()` 归还，调用方拿到 `errCOULD_NOT_ALLOCATE_REQUIRED_MEMORY`。
3. **`pvPortMalloc` 不是 heap_1~heap_5 里那套**。IDF 用 `components/freertos/heap_idf.c` 把内核的 `pvPortMalloc`/`vPortFree` 直接转接到 IDF heap 组件（`heap_caps_malloc()`/`heap_caps_free()`）。也就是说在 ESP32 上，任务栈和 TCB 与普通 `malloc` 共用同一个多分配器堆，还能吃到 caps 机制——细节留到[[ch20-idf-heap-and-caps|第二十章]]。

分配成功后，`ucStaticallyAllocated` 字段被打上 `tskDYNAMICALLY_ALLOCATED_STACK_AND_TCB` 标记（删除时靠它决定要不要 free，见 5.4 节），然后进入 `prvInitialiseNewTask()`。

### 3. prvInitialiseNewTask：把 TCB 填成一个"活人"

`prvInitialiseNewTask()` 在 `tasks.c` 里，IDF fork 给它加了一个 Vanilla 没有的参数——`xCoreID`。按执行顺序，它做八件事：

1. **栈区灌水**：`memset( pxNewTCB->pxStack, tskSTACK_FILL_BYTE, ... )`，填充字节 `tskSTACK_FILL_BYTE` 是 `0xa5U`。这不是洁癖，是给 `uxTaskGetStackHighWaterMark()` 留的测量底子（见 5.6 节）。
2. **算栈顶**：向下生长，`pxTopOfStack = &pxStack[ulStackDepth - 1]`，再向下对齐到 16 字节边界（xtensa 窗口 ABI 强制 SP 16 字节对齐，`portBYTE_ALIGNMENT` 为 16），并把对齐后的高地址记进 `pxEndOfStack`。
3. **抄名字**：逐字符复制 `pcName` 到 `pcTaskName[configMAX_TASK_NAME_LEN]`（IDF 默认 16，即 `CONFIG_FREERTOS_MAX_TASK_NAME_LEN`），超长截断并保证结尾 `\0`。
4. **优先级夹紧**：`uxPriority >= configMAX_PRIORITIES` 时截到最大值，然后写入 `pxNewTCB->uxPriority`；开互斥量时同步记录 `uxBasePriority`（优先级继承的基准，[[ch11-semaphore-mutex-priority-inheritance|第十一章]]的主角）。
5. **写入核亲和**：`pxNewTCB->xCoreID = xCoreID`——IDF fork 给 TCB 加的 SMP 字段，单核编译时此参数被 `(void)` 掉。
6. **初始化双链表项**：`vListInitialiseItem()` 两个 item，`listSET_LIST_ITEM_OWNER()` 把 item 反指向自己的 TCB；`xEventListItem` 的值设为 `configMAX_PRIORITIES - uxPriority`（反过来编码的优先级，5.2 节解释）。
7. **初始化栈帧**：调用端口层 `pxPortInitialiseStack()`，把"任务从未运行过"伪装成"刚被中断打断"，返回新的栈顶写进 `pxNewTCB->pxTopOfStack`。这是 5.3 节的全部内容。
8. **回传句柄**：`*pxCreatedTask = ( TaskHandle_t ) pxNewTCB`——所谓任务句柄，就是 TCB 指针本身，没有中间层。

### 4. prvAddNewTaskToReadyList：挂进世界

最后一步 `prvAddNewTaskToReadyList()` 让任务正式进入调度视野。整段包在 `taskENTER_CRITICAL( &xKernelLock )` 里——注意 Vanilla 这里是普通的 `taskENTER_CRITICAL()`（关中断），IDF fork 则锁的是内核专用自旋锁 `xKernelLock`（第十八章的伏笔）。临界区里依次：

```text
uxCurrentNumberOfTasks++                        ← 全局任务计数
若是第一个任务 → prvInitialiseTaskLists()       ← 链表们只初始化这一次
按核播种 pxCurrentTCBs[]：                       ← SMP 特有
    core0 空且亲和兼容 → pxCurrentTCBs[0] = 新任务
    否则 core1 空且亲和兼容 → pxCurrentTCBs[1] = 新任务
    否则（调度器未跑时）按优先级顶掉较低的当前任务
uxTaskNumber++（trace 场景写入 uxTCBNumber）
prvAddTaskToReadyList( pxNewTCB )               ← 宏：挂到 pxReadyTasksLists[prio] 尾部
portSETUP_TCB( pxNewTCB )                       ← 调试器 hook
若调度器已跑且 taskIS_YIELD_REQUIRED() → 立刻 yield
```

`taskIS_AFFINITY_COMPATIBLE( xCore, pxTCB )` 的判定就一行：任务的 `xCoreID` 等于该核、或为 `tskNO_AFFINITY`。高优先级任务创建出来时若当前核跑着更低优先级的任务，`taskIS_YIELD_REQUIRED()` 为真，新任务当场抢走 CPU——**创建即调度**。

串起来的完整调用链：

```text
xTaskCreate()                          [task.h, static inline]
  └─ xTaskCreatePinnedToCore(..., tskNO_AFFINITY)      [freertos_tasks_c_additions.h, 编进 tasks.c]
       ├─ pvPortMallocStack( 栈字节数 )                [heap_idf.c → heap_caps_malloc]
       ├─ pvPortMalloc( sizeof(TCB_t) )
       ├─ prvInitialiseNewTask(..., xCoreID)           [tasks.c]
       │    ├─ memset 0xa5 灌栈
       │    ├─ 算 pxTopOfStack / pxEndOfStack（16 字节对齐）
       │    ├─ 填 uxPriority / xCoreID / 名字 / 双链表项
       │    └─ pxPortInitialiseStack(...)              [portable/xtensa/port.c]
       │         ├─ uxInitialiseStackCPSA()            ← 协处理器保存区
       │         ├─ uxInitialiseStackTLS()             ← GCC TLS 区
       │         └─ uxInitialiseStackFrame()           ← 初始中断栈帧（含退出陷阱）
       └─ prvAddNewTaskToReadyList( pxNewTCB )         [tasks.c]
            ├─ 持 xKernelLock 临界区
            ├─ prvAddTaskToReadyList() 宏 → 挂就绪链表
            └─ 需要时立刻触发调度
```

> [!note] 静态创建走同一条后路
> `xTaskCreateStatic()` 同样是 `task.h` 里的 inline 包装，转调 `xTaskCreateStaticPinnedToCore()`；后者跳过堆分配，直接用调用者给的缓冲区，但从 `prvInitialiseNewTask()` 往后的路径一模一样。差异细节集中在 5.5 节。

---

## 5.2 TCB 解剖：一个结构体装下的整个任务

TCB 是 FreeRTOS 里"任务"这个概念的物理实体——没有 PCB 那样的豪华阵容，一个结构体加一块栈就是全部。先看全景（IDF fork、ESP32 默认配置下实际编译进来的形状）：

```text
typedef struct tskTaskControlBlock           /* tasks.c 中定义，别名 TCB_t */
{
    volatile StackType_t *pxTopOfStack;      /* ── ① 生存必需 ──────────────
                                                 MUST BE THE FIRST MEMBER!
                                                 上下文切换汇编直接按偏移 0 取它 */
    ListItem_t xStateListItem;               /* 状态链表项：挂在哪条链 = 什么状态
                                                 (就绪/延时/挂起/待回收...)      */
    ListItem_t xEventListItem;               /* 事件链表项：等队列/信号量/事件组时
                                                 挂到内核对象的事件链上            */
    UBaseType_t uxPriority;                  /* 当前优先级（调度用）             */
    StackType_t *pxStack;                    /* 栈起始地址（低地址端）           */
    char pcTaskName[ configMAX_TASK_NAME_LEN ]; /* 名字，纯调试用，默认 16 字节 */

    BaseType_t xCoreID;                      /* ── ② SMP 扩展（本 fork 的灵魂）─
                                                 0 / 1 / tskNO_AFFINITY          */
    StackType_t *pxEndOfStack;               /* ── ③ 栈体检与溢出检测 ─────
                                                 栈高地址端（向下生长时）         */
    UBaseType_t uxTCBNumber;                 /* ── ④ 记账与调试 ──────────
                                                 TCB 创建序号（trace 场景编译）   */
    UBaseType_t uxTaskNumber;                /* 第三方 trace 工具自由使用        */
    UBaseType_t uxBasePriority;              /* ── ⑤ 互斥量优先级继承的基准 ── */
    UBaseType_t uxMutexesHeld;               /* 手里握着几把互斥量               */
    TaskHookFunction_t pxTaskTag;            /* 任务私有 hook（含看门狗喂狗回调）*/
    void *pvThreadLocalStoragePointers[ configNUM_THREAD_LOCAL_STORAGE_POINTERS ];
                                             /* TLS 指针数组（IDF 拿它存线程局部
                                                变量与删除回调）                 */
    configRUN_TIME_COUNTER_TYPE ulRunTimeCounter; /* CPU 占用统计（按配置编译）  */
    volatile uint32_t ulNotifiedValue[ configTASK_NOTIFICATION_ARRAY_ENTRIES ];
    volatile uint8_t  ucNotifyState[ configTASK_NOTIFICATION_ARRAY_ENTRIES ];
                                             /* ── ⑥ 任务通知：IPC 直接内嵌进 TCB
                                                （第十三章：最轻量的 IPC）      */
    uint8_t ucStaticallyAllocated;           /* 三态标记：删除时谁该被 free      */
    int iTaskErrno;                          /* 任务级 errno（按配置编译）       */
} tskTCB;
```

（`MPU 设置`、`uxCriticalNesting`、`xTLSBlock`、`ucDelayAborted` 等字段都存在，但由对应 `config*` 宏控制；ESP32 默认配置下多数不编译进来——例如 xtensa fork 的 `portCRITICAL_NESTING_IN_TCB` 为 0，临界区嵌套计数在端口层按核维护，不进 TCB。）

### 1. 为什么 pxTopOfStack 必须排第一

源码注释原话：**"THIS MUST BE THE FIRST MEMBER OF THE TCB STRUCT."** 原因在端口层汇编：上下文切换的保存/恢复例程（xtensa 的 `_frxt_context_save`/`_frxt_context_restore` 一族）只认 TCB 基址，`pxTopOfStack` 在偏移 0 意味着汇编里"取当前任务栈顶"就是一条对 TCB 指针的裸访存，不需要 C 编译器算偏移。同理，端口层还导出了 `offset_pxEndOfStack`、`offset_xCoreID` 这类**用 C 的 `offsetof()` 算好、供汇编读取的常量**——TCB 的内存布局是被汇编"钉死"的，动字段顺序等于改 ABI。

### 2. 双链表项：任务状态的全部真相

FreeRTOS 没有"状态机字段"。一个任务是就绪、阻塞还是挂起，**唯一由它的 `xStateListItem` 挂在哪条链表决定**：

```text
pxReadyTasksLists[p]   ← xStateListItem 在这 ⇒ 就绪，优先级 p
xDelayedTaskList(1/2)  ← 在这 ⇒ 阻塞等超时
xSuspendedList         ← 在这 ⇒ 被挂起
xTasksWaitingTermination ← 在这 ⇒ 已死，等 Idle 收尸（5.4 节）
（不挂任何链表）         ⇒ 正在某个核上运行
```

`xEventListItem` 则是任务在**等某个内核对象**时的挂号窗口：阻塞在 `xQueueReceive()` 上的任务，`xStateListItem` 挂到延时链（等超时兜底），`xEventListItem` 挂到队列的事件链（等数据唤醒）。两条链独立操作，超时与唤醒哪个先到都能干净摘除——这是 Part III 一切 IPC 的底座。

它的 `xItemValue` 被设成 `configMAX_PRIORITIES - uxPriority` 这个"反码"也有讲究：事件链表用按值升序插入，值越小越靠前；于是优先级越高的任务在事件链上排得越前，唤醒时从链头摘，天然按优先级出队。两个 item 都通过 `pvOwner` 反指回 TCB——内核从任何一条链摸到一个 item，都能立刻找回任务本体。

### 3. Vanilla TCB vs IDF TCB 字段对照

> [!tip] Vanilla vs ESP-IDF：TCB 与任务全局状态对照（本系列暗线的核心一表）
>
> | 字段/全局量                 | Vanilla v10.5.1                      | IDF FreeRTOS（默认树）                                         | 差异的由来                               |
> | --------------------------- | ------------------------------------ | -------------------------------------------------------------- | ---------------------------------------- |
> | `xCoreID`                   | 无                                   | **有**（`configNUMBER_OF_CORES > 1` 时编译）                   | 双核：任务要声明自己钉在哪个核           |
> | 当前任务                    | `pxCurrentTCB`（单个）               | `pxCurrentTCBs[ configNUMBER_OF_CORES ]`（每核一个）           | 每核各自在跑一个任务                     |
> | 就绪挂起缓冲                | `xPendingReadyList`（单个）          | `xPendingReadyList[ cores ]`（每核一个）                       | 每核可独立挂起调度器                     |
> | 挂起计数                    | `uxSchedulerSuspended`（单个）       | `uxSchedulerSuspended[ cores ]`                                | `vTaskSuspendAll()` 只挂起当前核         |
> | Idle 任务                   | 一个 `xIdleTaskHandle`               | `xIdleTaskHandle[ cores ]`，每核一个，钉死在自己的核上         | 核不能跑别的任务时必须有本地的"填充任务" |
> | 临界区保护                  | 关中断                               | 同样关中断，但内核对象各配自旋锁（`xKernelLock` 等）           | 双核下关中断只隔离本核                   |
> | 任务名长度                  | `configMAX_TASK_NAME_LEN`（默认 16） | 同名配置映射到 `CONFIG_FREERTOS_MAX_TASK_NAME_LEN`（默认 16）  | 行为一致                                 |
> | `prvGetTCBFromHandle(NULL)` | 返回 `pxCurrentTCB`                  | 返回 `xTaskGetCurrentTaskHandle()`（内部关中断防任务中途换核） | SMP 线程安全                             |
>
> 官方的完整改造清单就写在 `FreeRTOS-Kernel/idf_changes.md` 里（"Data Structure Changes" 一节），本表是它的任务部分摘录。

还有一层值得知道：ESP-IDF 里另有一棵实验性的 `FreeRTOS-Kernel-SMP/` 树（由 `CONFIG_FREERTOS_SMP` 开启，默认关闭），那是上游 Amazon FreeRTOS SMP 新内核（v11.x 基线）。它的 TCB 又是另一种形状——用位掩码 `uxCoreAffinityMask` 表达亲和（可同时亲和多核），还多出 `xTaskRunState`（记录任务正在哪个核上跑/是否让出中），创建 API 相应变成 `xTaskCreateAffinitySet()`。两条 SMP 路线的对比留给[[ch22-smp-refactor-overview|第二十二章]]，本章以下全部聚焦默认树。

---

## 5.3 栈初始化：给新任务伪造一个"被中断过"的栈帧

### 1. 核心思想：第一次调度 = 一次"从中断返回"

调度器恢复一个任务，走的和"中断返回"是**同一条路**：从任务的 `pxTopOfStack` 恢复寄存器，`ret` 回 PC。那么一个从没跑过的任务怎么被"恢复"？答案漂亮得很——**创建时就在栈顶伪造一个标准的中断栈帧，把 PC 填成任务函数入口**。于是"启动新任务"和"唤醒旧任务"在内核眼里是同一件事，调度路径不需要任何特殊分支。

真正的实现不在 `tasks.c`，而在端口层 `portable/xtensa/port.c` 的 `pxPortInitialiseStack()`，它依次调用三个 helper，从栈顶（高地址）向下依次铺三层：

```text
高地址
│  pxTopOfStack（16 字节对齐）
├────────────────────────────┐
│  ① 协处理器保存区 CPSA      │ XT_CP_SIZE，含 CPENABLE/CPSTORED 等管理字
│     （FPU 状态的落脚点）     │ 必须铺在最上面：汇编 _frxt_task_coproc_state()
├────────────────────────────┤    按固定偏移找它
│  ② GCC TLS 变量区           │ .tdata 初值拷贝 + .tbss 清零，
│     （thread 变量的家）      │ 并算出 THREADPTR 寄存器初值
├────────────────────────────┤
│  ③ 初始中断栈帧 XtExcFrame  │ XT_STK_FRMSZ，16 字节对齐
│     pc     = 任务入口        │ ← 返回地址即任务函数（或包装函数）
│     a0     = 0               │ ← GDB 回溯终止符
│     a1     = 帧顶            │ ← 恢复后的 SP
│     exit  = _xt_user_exit    │ ← 退出陷阱！
│     a6     = pvParameters    │ ← 参数放在 call4 的第一参位置
│     ps     = UM|EXCM|WOE|CALLINC(1)
├────────────────────────────┤
│  （以下全是 0xa5 灌水区）     │ pxTopOfStack 指向 ③ 的帧底并写回 TCB
│         ⋮                   │
低地址  pxStack
```

### 2. 三个值得把玩的细节

**退出陷阱**。初始帧的 `exit` 字段填的是 `_xt_user_exit`——用户异常返回分发器。任务函数是 `void f(void *)`，没有合法的"返回去处"；万一它真的 `return` 了，执行流会滑进这个陷阱路径。配合 `CONFIG_FREERTOS_TASK_FUNCTION_WRAPPER`（依赖 coredump/GDB stub 等选项时默认开启），入口 `pc` 实际填的是包装函数 `vPortTaskWrapper()`：它调用真正的任务函数，返回后打出 `FreeRTOS Task "xxx" should not return, Aborting now!` 并 `abort()`——把"任务返回"这个未定义行为变成带任务名的明确崩溃，coredump 里一眼可辨。`a0 = 0` 同理，是给 GDB 回溯准备的终止符。

**参数伪装成 call4 调用**。窗口 ABI 下函数参数由寄存器窗口位置决定；初始帧把 `ps` 设成 `PS_UM | PS_EXCM | PS_WOE | PS_CALLINC(1)`，`pvParameters` 放在 `a6`——正好是"这个任务函数曾被 `call4` 调用过"的寄存器布局。中断返回后硬件按这个 PS 恢复窗口，任务函数一开场就"天然地"从 `a6` 读到参数。这套寄存器窗口戏法属于第十七章的正题。

**栈没跑就被吃掉一块**。CPSA + TLS + 初始帧都铺在栈的高地址端，所以一个新建任务的 `uxTaskGetStackHighWaterMark()` **本来就小于栈容量**——那部分不是"用掉的"，是结构性的底座。给任务定栈大小时要把这几十字节算进预算，别指望 3072 字节能全用。

灌水与体检的闭环也在这里：创建时 `0xa5` 灌满全栈，之后栈向下生长的每一步都会踩掉水渍；`uxTaskGetStackHighWaterMark()` 从 `pxStack`（低地址端）向上数还连着多少个 `0xa5`，除以 `sizeof( StackType_t )`——IDF 里 `StackType_t` 是单字节，**所以 IDF 的返回值单位是字节**；Vanilla 端口 `StackType_t` 多为 32 位，返回的是字数。又是一个照抄教程会翻车的单位差异。

---

## 5.4 任务的死：vTaskDelete 的两条回收路径

### 1. 谁在跑，决定谁收尸

删除的难点只有一个：**正在 CPU 上跑的任务没法自己拆自己脚下的栈**。`vTaskDelete()` 用两条路径绕开它：

```text
vTaskDelete( xTaskToDelete )
  │  持 xKernelLock 临界区
  │  pxTCB = prvGetTCBFromHandle( 句柄或 NULL=自己 )
  │  从状态链表摘除 xStateListItem；若在等事件，也摘 xEventListItem
  │
  ├─ 目标不在任何核上运行（阻塞/挂起/就绪未跑）
  │     └─ 路径 A：出临界区后当场 prvDeleteTCB( pxTCB )
  │                ——内存同步归还，函数返回即彻底消失
  │
  └─ 目标正在运行（=自己，或正在另一个核上跑）
        └─ 路径 B：挂入 xTasksWaitingTermination 链
                   uxDeletedTasksWaitingCleanUp++
                   若在别的核上跑 → taskYIELD_CORE( 那个核 )  ← 跨核 IPI 踢它下台
                   ……真正的内存回收等 Idle 任务来做

（自删的收尾在临界区外：vTaskDelete 末尾检测到删的是自己，
  立刻 portYIELD_WITHIN_API() 切走——这一去就不会再回来了）
```

路径 B 的收尸人是 Idle 任务：它每轮循环调用 `prvCheckTasksWaitingTermination()`，看到 `uxDeletedTasksWaitingCleanUp > 0` 就遍历 `xTasksWaitingTermination`——注意 SMP 版本会**跳过仍在某个核上运行的任务**（被 IPI 踢下台需要时间），只对确认停跑的 TCB 调 `prvDeleteTCB()`。两个核的 Idle 可能同时在场收尸，所以遍历全程持锁、每摘一个都要重新核对。

### 2. prvDeleteTCB：回收前的两件身后事

`prvDeleteTCB()` 先执行 `portCLEAN_UP_TCB()`——在 xtensa 端口里它映射到 `vPortTCBPreDeleteHook()`，做两件 Vanilla 没有的清理：调用 TLS 指针数组后半段登记的**删除回调**（`CONFIG_FREERTOS_TLSP_DELETION_CALLBACKS`，让 pthread 风格的 TLS 析构有机会跑），以及**释放协处理器保存区**（若任务的 FPU 上下文还挂在某个核上，通知 `_xt_coproc_release()`）。然后按 `ucStaticallyAllocated` 的三态决定 free 什么：

| `ucStaticallyAllocated`                       | 含义              | 删除时                             |
| --------------------------------------------- | ----------------- | ---------------------------------- |
| `tskDYNAMICALLY_ALLOCATED_STACK_AND_TCB`（0） | 栈和 TCB 都来自堆 | `vPortFreeStack()` + `vPortFree()` |
| `tskSTATICALLY_ALLOCATED_STACK_ONLY`（1）     | 仅栈静态          | 只 `vPortFree( pxTCB )`            |
| `tskSTATICALLY_ALLOCATED_STACK_AND_TCB`（2）  | 全静态            | 什么都不 free                      |

### 3. 两条路径的时序推论

- **删别人是同步的**（只要对方没在跑）：`vTaskDelete()` 返回时内存已归还，`uxTaskGetNumberOfTasks()` 立刻减一。
- **自删（及删正在跑的任务）是最终一致的**：内存要等 Idle 任务跑到才有机会回收。若全系统高优先级任务满负荷运转、Idle 长期上不了 CPU，被删任务的栈和 TCB 会一直占着内存——这也是"别让高优先级任务忙等"的又一条理由。
- **删除是延迟生效的**，句柄在目标真正停跑前仍指向活着的 TCB；但内核已把它摘出所有调度链表，它绝不会再被选中。安全做法照旧：删了就当句柄已失效。

> [!tip] Vanilla vs ESP-IDF：vTaskDelete 的差异
>
> | 主题             | Vanilla v10.5.1                           | IDF FreeRTOS（默认树）                                                                         |
> | ---------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------- |
> | 自删延迟回收     | 有（同样的 termination list + Idle 收尸） | 有，机制相同                                                                                   |
> | 删"正在跑"的目标 | 只有"自己"这一种情况                      | 多了"正在**另一个核**上跑"：挂 termination list 后发跨核 IPI（`taskYIELD_CORE()`）强制对方换出 |
> | Idle 收尸判据    | 直接取链头                                | **遍历链表、跳过仍在任一核上运行的任务**（可能被另一核的 Idle 先收走）                         |
> | 临界区           | 关中断                                    | 关中断 + `xKernelLock` 自旋锁                                                                  |
> | 删除前清理       | 无端口级 hook 链                          | `vPortTCBPreDeleteHook()`：TLS 删除回调 + 协处理器上下文释放                                   |
>
> 跨核 IPI 的硬件机制（`from_cpu` 中断一类）在[[ch23-cross-core-synchronization|第二十三章]]展开。

---

## 5.5 静态创建：xTaskCreateStatic 与 StaticTask_t

### 1. 用法与路径

动态创建的一切失败模式（堆耗尽、碎片）都可以用静态创建根除：

```c
static StaticTask_t xTaskBuffer;               /* TCB 的家 */
static StackType_t xStack[ 3072 ];             /* 栈的家（单位：字节！） */

TaskHandle_t h = xTaskCreateStaticPinnedToCore( vTaskCode, "stat", 3072, NULL,
                                                5, xStack, &xTaskBuffer, 1 );
```

`xTaskCreateStatic()` 照例是 `task.h` 里的 inline 包装，转调 `xTaskCreateStaticPinnedToCore()`。它跳过两个 `pvPortMalloc`，直接 `pxNewTCB = ( TCB_t * ) pxTaskBuffer; pxNewTCB->pxStack = puxStackBuffer;`，打上 `tskSTATICALLY_ALLOCATED_STACK_AND_TCB` 标记，之后与动态创建共用 `prvInitialiseNewTask()` / `prvAddNewTaskToReadyList()`。还有一个贴心的编译期断言：`configASSERT( sizeof( StaticTask_t ) == sizeof( TCB_t ) )`——镜像结构体和真身一旦漂移，构建直接失败。

### 2. StaticTask_t 是什么

`StaticTask_t` 是 `task.h` 里一串 `pxDummy*` 字段拼成的**不透明镜像**：布局与 `TCB_t` 逐字段对齐，但应用代码只能拿到一块正确大小的内存，看不见内部（TCB 是内核私有类型）。这个"影子结构"的传统用途是内核感知调试器；IDF 端口层更进一步，前面提到的汇编偏移常量（`offset_pxEndOfStack`、`offset_xCoreID`）就是拿 `offsetof( StaticTask_t, ... )` 算出来的。

### 3. 什么时候选它

- **确定性**：创建不依赖堆状态，启动序列可静态证明——功能安全场景的标配；
- **无堆策略**：项目禁用动态分配（`configSUPPORT_DYNAMIC_ALLOCATION = 0`）时是唯一选择；
- **内核自己也这么干**：IDF 的两个 Idle 任务就是 `vTaskStartScheduler()` 里用 `xTaskCreateStaticPinnedToCore()` 建的（缓冲区由 `vApplicationGetIdleTaskMemory()` 提供），每核一个、钉在自己核上、名字分别是 `IDLE0` / `IDLE1`（`configIDLE_TASK_NAME` 加核号后缀）。

代价也直白：栈和 TCB 的生命周期从此钉死为"永久"，删了任务内存也不还（`ucStaticallyAllocated` 三态表里那一行"什么都不 free"）。

---

## 5.6 实验：创建 → 栈体检 → 删除（QEMU）

三个任务上演一场完整的生老病死：`victim` 周期性自报栈余量，`killer` 定时先"删别人"再"删自己"，`monitor` 旁观数任务数——两条删除路径的时序差异会在它的输出里现形。

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static TaskHandle_t s_victim;

static void victim_task( void *arg )          /* 被删的倒霉蛋 */
{
    for( ;; ) {
        printf( "[victim] core=%d hwm=%u bytes\n",
                xPortGetCoreID(),
                ( unsigned ) uxTaskGetStackHighWaterMark( NULL ) );
        vTaskDelay( pdMS_TO_TICKS( 300 ) );
    }
}

static void killer_task( void *arg )          /* 先删别人，再删自己 */
{
    vTaskDelay( pdMS_TO_TICKS( 1700 ) );      /* t=1700ms 动手：victim 在 1500ms 醒来
                                                   打印后又睡到 1800ms，此刻必然阻塞中 */

    printf( "[killer] tasks=%u, deleting victim (blocked -> sync free)\n",
            ( unsigned ) uxTaskGetNumberOfTasks() );
    vTaskDelete( s_victim );                  /* victim 正在 vTaskDelay：路径 A */

    printf( "[killer] tasks=%u, victim gone already\n",
            ( unsigned ) uxTaskGetNumberOfTasks() );

    printf( "[killer] self-deleting (deferred free by IDLE)\n" );
    vTaskDelete( NULL );                      /* 自删：路径 B，本行之后不会再执行 */
}

static void monitor_task( void *arg )         /* 旁观者：每 500ms 数一次人头 */
{
    for( int i = 0; i < 10; i++ ) {
        printf( "[monitor] t=%4dms tasks=%u\n",
                i * 500, ( unsigned ) uxTaskGetNumberOfTasks() );
        vTaskDelay( pdMS_TO_TICKS( 500 ) );
    }
}

void app_main( void )
{
    xTaskCreatePinnedToCore( victim_task,   "victim",   3072, NULL, 4, &s_victim, tskNO_AFFINITY );
    xTaskCreatePinnedToCore( killer_task,   "killer",   3072, NULL, 5, NULL,      tskNO_AFFINITY );
    xTaskCreatePinnedToCore( monitor_task,  "monitor",  3072, NULL, 3, NULL,      tskNO_AFFINITY );
    /* app_main 返回 → main 任务自删：也是路径 B（第三、九章讲过它的来历） */
}
```

跑起来（环境搭建见[[ch1-from-bare-metal-to-rtos|第一章]]）：

```bash
idf.py qemu monitor
```

典型输出（启动横幅略；任务总数随组件配置浮动，关注相对变化）：

```text
[victim] core=1 hwm=2616 bytes
[monitor] t=   0ms tasks=13
[victim] core=0 hwm=2412 bytes
[monitor] t= 500ms tasks=13
[victim] core=1 hwm=2408 bytes
[monitor] t=1000ms tasks=13
[monitor] t=1500ms tasks=13
[killer] tasks=13, deleting victim (blocked -> sync free)
[killer] tasks=12, victim gone already
[killer] self-deleting (deferred free by IDLE)
[monitor] t=2000ms tasks=11
[monitor] t=2500ms tasks=11
...
```

### 1. 从输出里读出四件事

1. **hwm 一出生就小于 3072**：`2616` 而不是 `3072`——高地址端被 CPSA/TLS/初始帧占了底座（5.3 节），还扣掉了 printf 调用链压过的栈。两轮之间 `2616 → 2412` 的差值，就是输出路径深浅波动的水位线。**单位是字节**（IDF 特产），Vanilla 教材里这个数是"字"。
2. **`core=` 在 0 和 1 之间漂**：`tskNO_AFFINITY` 任务允许调度器自由搬核——`xCoreID = 0x7FFFFFFF` 的含义不是"没有值"，而是"两个核都要兼容"。
3. **删别人是同步的**：`vTaskDelete( s_victim )` 返回后，killer 紧接着的 `tasks=` 已经从 13 掉到 12——victim 彼时阻塞在 `vTaskDelay` 里（killer 特意挑在 1700ms 动手，就是为了保证这一点），路径 A 在函数返回前就归还了内存。
4. **自删的回收时机"由 Idle 说了算"**：killer 自删后，它的 TCB 要等某个核的 Idle 任务跑 `prvCheckTasksWaitingTermination()` 才真正释放。本实验系统很闲，Idle 几乎立刻上场，所以 t=2000ms 那行已经少了两个人头。想亲眼看到"延迟"：再加两个钉在各自核上的高优先级忙等任务，把两个 Idle 都饿死——`tasks=` 会一直停在 12，直到你放掉一个核。这条"删除依赖 Idle 活着"的性质，是 FreeRTOS 里"高优先级任务不该无限忙等"的又一条硬理由。

### 2. 加餐：用 GDB 亲手摸一次 TCB

```bash
idf.py qemu gdb
```

```text
(gdb) break prvInitialiseNewTask
(gdb) continue
(gdb) print *pxNewTCB
(gdb) print pxNewTCB->xCoreID
(gdb) print/x pxNewTCB->xStateListItem.pxContainer    ← 此刻还没挂任何链表
```

在断点处能看到一个"半成品"任务：`pcTaskName` 已填、`pxTopOfStack` 已指向伪栈帧、而 `xStateListItem` 还没有 `pxContainer`——再单步越过 `prvAddNewTaskToReadyList()`，它就挂进了 `pxReadyTasksLists[4]`。静态创建的话，把断点换成 `xTaskCreateStaticPinnedToCore` 能看到同一个 TCB 从你的静态缓冲区里"长"出来。更多调试姿势见[[ch24-debugging-tracing-pitfalls|第二十四章]]。

---

## 5.7 小结

- `xTaskCreate` 在 IDF 里是 `task.h` 的 inline 包装，真身是 `xTaskCreatePinnedToCore()`：**先栈后 TCB** 两块堆内存（经 `heap_idf.c` 转到 IDF heap 组件）→ `prvInitialiseNewTask()` 填 TCB → `prvAddNewTaskToReadyList()` 挂链表，高优先级新任务当场触发调度。
- TCB 是"任务"的全部物理实体：`pxTopOfStack` 钉死在偏移 0 供汇编直达；**双链表项就是状态机**（挂在哪条链 = 什么状态）；`xEventListItem` 按反码优先级排序保证事件唤醒次序；`xCoreID` 是 IDF fork 加出的 SMP 灵魂字段。
- 栈初始化的本质是**伪造一个"被中断过"的栈帧**：CPSA + TLS + `XtExcFrame` 三层，PC 填任务入口、参数伪装成 call4、`exit` 填 `_xt_user_exit` 陷阱——于是"启动"与"恢复"共用一条调度路径；`0xa5` 灌水让 `uxTaskGetStackHighWaterMark()`（IDF 返回**字节**）有了刻度。
- `vTaskDelete` 两条路：目标没在跑 → 当场回收；目标在跑（自己或别的核）→ 挂 termination list、发跨核 IPI 踢下台，由 Idle 任务收尸——删别人同步、自删最终一致。
- 静态创建 `xTaskCreateStaticPinnedToCore` 跳过堆、靠 `ucStaticallyAllocated` 三态指导回收；内核自己的两个 Idle 任务就是静态创建、按核钉死的。

任务已经"活"了，也挂进了 `pxReadyTasksLists[]`——但这条链表凭什么叫"就绪"？调度器每一步怎么从一堆链表里挑出下一个上 CPU 的任务、双核又怎么各自为政还互不踩脚？下一章钻进调度器的选路算法：[[ch6-scheduler-ready-lists|第六章：调度器核心——就绪链表与最高优先级任务选择]]。
