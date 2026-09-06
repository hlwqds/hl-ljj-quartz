---
title: "FreeRTOS 深度解析（十）：队列：FreeRTOS 的万能 IPC"
date: 2026-08-26
description: "逐字段解剖 Queue_t 结构，源码级走读 xQueueGenericCreate / xQueueGenericSend / xQueueReceive 全路径；吃透拷贝语义、队满三种处理、ISR 延迟解锁机制，以及 IDF 双核下队列锁被自旋锁取代的真相。"
tags: [freertos, rtos, esp32, esp-idf, queue, ipc, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 10. **第十章：队列：FreeRTOS 的万能 IPC**

# FreeRTOS 深度解析（十）：队列：FreeRTOS 的万能 IPC

第九章结束时，我们手里已经有了完整的任务模型：任务会创建、会阻塞、会被唤醒。但两个任务之间**怎么传数据**，至今还是空白——全局变量加标志位？那是裸机时代的手法，第七章已经埋过它的坑。

这一章进入 `queue.c`。先给结论：**队列是 FreeRTOS 唯一的通用 IPC 原语**。信号量、互斥量在源码层面都是队列的特例（第十一章展开），队列集是装队列的队列，软件定时器的命令通道也是队列（第十五章）。把 `queue.c`（IDF 默认树三千四百余行）吃透，FreeRTOS 的整个"内核对象"体系就通了一大半。

本章路线：先解剖 `Queue_t` 结构体（10.2），再顺着创建（10.3）、发送（10.4）、接收（10.5）三条路径走源码，然后专门拆 ISR 变体与延迟解锁机制（10.6）——那里藏着全章最精彩的设计，也藏着 ESP32 双核默认配置下这个机制**被整个裁掉**的暗线。

> [!note] 源码参照
> 本章源码引用以 ESP-IDF v6.0.2 **默认编译的内核树**为准：`components/freertos/FreeRTOS-Kernel/`（文件头自述 "FreeRTOS Kernel V10.5.1 (ESP-IDF SMP modified)"，即 Vanilla v10.5.1 的 Espressif SMP 改造版）。上游对照用 Vanilla FreeRTOS v10.5.1。ESP-IDF v6 里另有一棵 `FreeRTOS-Kernel-SMP/`，那是实验性的上游新内核（`CONFIG_FREERTOS_SMP` 才启用，默认关闭），本章不涉及——两棵树的关系见[[ch4-kernel-source-map|第四章]]。

---

## 10.1 为什么队列是中心抽象

### 1. 一个文件装下整个 IPC 家族

回看第一章的内核文件表：`queue.c` 一个文件装下队列、信号量、互斥量三样东西。这不是代码组织的巧合，而是**本质同源**：

| 你以为在用的 API                        | 实际调用的 queue.c 函数                                  | 与"真队列"的差异                              |
| --------------------------------------- | -------------------------------------------------------- | --------------------------------------------- |
| `xQueueSend()` / `xQueueReceive()`      | `xQueueGenericSend()` / `xQueueReceive()`                | 本体                                          |
| `xSemaphoreTake()` / `xSemaphoreGive()` | `xQueueSemaphoreTake()` / `xQueueGenericSend()`          | `uxItemSize == 0`，不拷数据只数数             |
| `xSemaphoreCreateMutex()`               | `xQueueCreateMutex()` → `xQueueGenericCreate(1, 0, ...)` | 长度 1、尺寸 0，外加优先级继承字段            |
| `xSemaphoreCreateCounting()`            | `xQueueCreateCountingSemaphore()`                        | 长度 = maxCount，初值写进 `uxMessagesWaiting` |

信号量就是"元素尺寸为零的队列"：没有数据要搬运，只剩计数与等待链表，于是 `uxMessagesWaiting` 顺便当了信号量的计数值。这个观察值得先立在这里，10.2 解剖结构体时你会反复看到它的影响。

### 2. 拷贝语义：与"共享内存 + 锁"的分野

FreeRTOS 队列的第二 个关键词是**按值拷贝**（queued by copy）。`xQueueSend(q, &data, ...)` 把 `data` 的内容 `memcpy` 进队列自己的存储区；`xQueueReceive()` 再从队列存储区 `memcpy` 到你的缓冲区。发送完立刻改 `data`，不影响队列里那份。

这与 Linux 管道/消息队列"引用传递、发送方负责生命周期"的设计正相反，权衡是：

| 维度           | 拷贝语义（FreeRTOS 队列）     | 引用语义（共享缓冲）       |
| -------------- | ----------------------------- | -------------------------- |
| 发送后的原数据 | 可立即复用/释放               | 必须保持有效直到消费完     |
| 生命周期管理   | 不存在——这正是价值            | 谁释放、何时释放，经典难题 |
| 大数据开销     | 两 memcpy，与 item 尺寸成正比 | 一次指针传递               |
| 越界隔离       | 天然（数据进了队列的地盘）    | 消费者可写穿生产者的缓冲   |

嵌入式系统里消息通常是小结构体（一个读数、一条命令），拷贝开销几十纳秒级，换来的是**彻底没有 use-after-free 类问题**。大数据（图像帧、网络包）不适合整块拷，惯例是传指针：队列 item 设为 `sizeof(void *)`，拷的只是指针本身，缓冲区生命周期由协议约定（如池化分配）。10.4 末尾给对照代码。

### 3. 队列自带"事件 + 互斥 + 阻塞"三合一

一个队列对象同时解决了裸机时代的三件事：数据在哪（环形缓冲）、谁在等（两条等待链表）、怎么不打架（临界区）。这就是它能当万能 IPC 的资本。

---

## 10.2 Queue_t 逐字段解剖

### 1. 完整结构

`queue.c` 中 `Queue_t`（`typedef struct QueueDefinition ... } xQUEUE;`）的字段布局，按默认树源码如实画出（双核默认配置下 `queueUSE_LOCKS == 0`，两个锁字段不编入；见 10.6）：

```text
Queue_t                                  /* queue.c */
┌────────────────────────────────────────────────────────────────┐
│ int8_t            *pcHead        ──► 存储区起点                  │
│ int8_t            *pcWriteTo     ──► 下一个写入槽                │
│ ┌──────────────────────── union u ────────────────────────┐    │
│ │ QueuePointers_t xQueue:      /* 队列形态使用 */            │    │
│ │   int8_t  *pcTail            ──► 存储区末尾(回绕判据)       │    │
│ │   int8_t  *pcReadFrom        ──► 上一次读取的槽             │    │
│ │ SemaphoreData_t xSemaphore:  /* 信号量/互斥量形态使用 */     │    │
│ │   TaskHandle_t xMutexHolder       持锁任务(优先级继承用)     │    │
│ │   UBaseType_t uxRecursiveCallCount 递归互斥量计数            │    │
│ └──────────────────────────────────────────────────────────┘    │
│ List_t  xTasksWaitingToSend     等待"有空间可写"的任务,按优先级序  │
│ List_t  xTasksWaitingToReceive  等待"有数据可读"的任务,按优先级序  │
│                                                                  │
│ volatile UBaseType_t uxMessagesWaiting  当前元素个数 == 信号量计数 │
│ UBaseType_t        uxLength        容量(元素个数,不是字节!)       │
│ UBaseType_t        uxItemSize      单个元素字节数                 │
│                                                                  │
│ [int8_t cRxLock, cTxLock]   ← 单核编译才有(queueUSE_LOCKS==1)     │
│ [uint8_t ucStaticallyAllocated]                                   │
│ [trace/queue-set 可选字段]                                        │
│ portMUX_TYPE       xQueueLock     ← IDF 加的 per-队列自旋锁       │
└────────────────────────────────────────────────────────────────┘
        紧随其后(同一块堆内存):uxLength * uxItemSize 字节存储区
```

逐字段过一遍，每个都标了它服务于哪条路径：

**存储区四指针：`pcHead` / `pcTail` / `pcWriteTo` / `pcReadFrom`。** 这四个指针围出一个环形缓冲。注意一个反直觉的约定：`pcReadFrom` 指向的是**上一次**读走的位置，不是下一个要读的位置——读取时先 `pcReadFrom += uxItemSize` 再取数据（10.5 会看到为什么这个约定让 `xQueuePeek` 和队头插入异常简洁）。`pcTail` 只当回绕判据用：写指针碰到它就绕回 `pcHead`。

**union：一份内存，两种身份。** `pcTail`/`pcReadFrom` 只有队列形态需要；互斥量形态需要的是 `xMutexHolder`（谁持锁，优先级继承的依据）和递归计数。二者互斥，塞进 union。判别方式很省：`uxQueueType`（就是 `pcHead` 的别名宏）为 `NULL` 即互斥量——所以 10.3 会看到 `uxItemSize == 0` 时 `pcHead` 被赋成指向结构体自身的"良性值"，唯独不能是 NULL。

**两条等待链表。** 队列的两侧各有一条：满了在 `xTasksWaitingToSend` 上排队，空了在 `xTasksWaitingToReceive` 上排队。它们是第六章讲过的 `List_t`，`vTaskPlaceOnEventList()` 按优先级插入——**链表头永远是等待者中优先级最高的**，同优先级内按到达顺序（FIFO）。10.7 的多消费者语义全靠这个性质。

**三个计数。** `uxMessagesWaiting` 是唯一的"当前状态"读数，所有满/空判断都只看它；`uxLength` 是容量（**元素个数**，`xQueueCreate(10, 4)` 是 10 个 4 字节元素、共 40 字节存储区）；`uxItemSize` 是元素尺寸，为 0 时队列退化为信号量。

**`cRxLock` / `cTxLock`。** 延迟解锁机制的现场，整个 10.6 都属于它们。这里先记一个结论：**ESP32 双核默认编译里，这两个字段连同机制一起被 `#if` 裁掉了**。

**`portMUX_TYPE xQueueLock`。** Espressif 给每个队列配的私有自旋锁——IDF SMP 化的签名改动，10.6 与暗线小节详述。

### 2. 一个对象，三种伪装

把上面的字段按对象类型对齐：

| 字段                        | 队列          | 二值/计数信号量      | 互斥量       |
| --------------------------- | ------------- | -------------------- | ------------ |
| 存储区（`pcHead`~`pcTail`） | N × size 字节 | 无（size=0）         | 无           |
| union 取哪边                | `xQueue`      | `xSemaphore`（不用） | `xSemaphore` |
| `uxMessagesWaiting`         | 元素个数      | 当前计数值           | 0 或 1       |
| `xQueueLock` / 等待链表     | 用            | 用                   | 用           |

同一套读写路径，三副面孔。

---

## 10.3 创建路径：xQueueGenericCreate

### 1. API 的真身

`queue.h` 里所有创建入口都是宏，最终都落到一个函数：

```c
/* queue.h */
#define xQueueCreate( uxQueueLength, uxItemSize ) \
    xQueueGenericCreate( ( uxQueueLength ), ( uxItemSize ), ( queueQUEUE_TYPE_BASE ) )

/* queue.c */
QueueHandle_t xQueueGenericCreate( const UBaseType_t uxQueueLength,
                                   const UBaseType_t uxItemSize,
                                   const uint8_t ucQueueType );
```

`ucQueueType` 只影响 trace 标记与调试器显示（`configUSE_TRACE_FACILITY`），不影响行为——又一次印证"万物皆队列"。

### 2. 走读

`xQueueGenericCreate()` 的步骤（默认树 `queue.c`）：

```text
1. 参数防御:
     uxQueueLength > 0
     SIZE_MAX / uxQueueLength >= uxItemSize        ← 乘法溢出检查
     SIZE_MAX - sizeof(Queue_t) >= uxLength*size   ← 加法溢出检查
2. 单次分配: pvPortMalloc( sizeof(Queue_t) + uxQueueLength * uxItemSize )
     结构体与存储区是同一块堆内存,存储区紧跟结构体之后
     (省一次分配;代价是 vQueueDelete 时也只 free 一次)
3. pucQueueStorage = (uint8_t *)pxNewQueue + sizeof(Queue_t)
4. prvInitialiseNewQueue(...):
     uxItemSize == 0 → pcHead = (int8_t *)pxNewQueue   ← 良性自指,绝不能 NULL
     否则           → pcHead = 存储区起点
5. xQueueGenericReset(pxNewQueue, pdTRUE):
     pcTail   = pcHead + uxLength * uxItemSize
     pcWriteTo = pcHead                            ← 空,从头上写
     pcReadFrom = pcHead + (uxLength-1) * uxItemSize ← "上次读"初始化在末槽!
     两条等待链表 vListInitialise()
     portMUX_INITIALIZE( &pxQueue->xQueueLock )    ← 初始化自旋锁(IDF)
```

第 5 步里 `pcReadFrom` 的初值值得盯着看：它指向**最后一个槽**。这样第一个元素写入 `pcHead` 后，第一次读取时 `pcReadFrom += size` 正好落到 `pcHead`——"先移动再读"的约定从创建那一刻就自洽了。

### 3. 内存从哪来：heap_caps 伏笔

`pvPortMalloc()` 在 ESP-IDF 里不是 Vanilla 的 `heap_2/3/4`，而是 `components/freertos/heap_idf.c` 里的转发函数：

```c
/* heap_idf.c */
#define portFREERTOS_HEAP_CAPS    ( MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT )

void * pvPortMalloc( size_t xWantedSize )
{
    return heap_caps_malloc( xWantedSize, portFREERTOS_HEAP_CAPS );
}
```

内核对象被强制放进**内部、可按字节访问的 RAM**——注释写明原因：缓存关闭时（写 Flash 期间）队列这类内核对象必须仍然可用。多 caps 堆的完整机制是[[ch20-idf-heap-and-caps|第二十章]]的主题，此处记住结论即可。

---

## 10.4 发送路径：xQueueGenericSend 源码走读

`xQueueSend` / `xQueueSendToFront` / `xQueueOverwrite` 三个宏全部展开成同一个函数，只差一个 `xCopyPosition`：

```c
/* queue.h */
#define xQueueSend( q, item, wait )  xQueueGenericSend( (q), (item), (wait), queueSEND_TO_BACK )  /* =0 */
#define xQueueSendToFront( q, item, wait ) \
    xQueueGenericSend( (q), (item), (wait), queueSEND_TO_FRONT )                                 /* =1 */
#define xQueueOverwrite( q, item )    xQueueGenericSend( (q), (item), 0, queueOVERWRITE )        /* =2 */
```

### 1. 快路径：有空间

函数体是一个 `for( ;; )` 循环，每一轮开头先拿锁进入临界区（IDF 双核下是 per-queue 自旋锁，见 10.6）：

```c
taskENTER_CRITICAL( &( pxQueue->xQueueLock ) );
{
    if( ( pxQueue->uxMessagesWaiting < pxQueue->uxLength )
        || ( xCopyPosition == queueOVERWRITE ) )
    {
        xYieldRequired = prvCopyDataToQueue( pxQueue, pvItemToQueue, xCopyPosition );

        if( listLIST_IS_EMPTY( &( pxQueue->xTasksWaitingToReceive ) ) == pdFALSE )
        {
            if( xTaskRemoveFromEventList( &( pxQueue->xTasksWaitingToReceive ) ) != pdFALSE )
            {
                queueYIELD_IF_USING_PREEMPTION();   /* 唤醒者优先级更高,立刻让路 */
            }
        }
        /* ... */
        taskEXIT_CRITICAL( &( pxQueue->xQueueLock ) );
        return pdPASS;
    }
```

三个动作在临界区内一次完成：拷数据、唤醒一个等待的接收者、必要时让出 CPU。注意那句源码注释："Yes it is ok to do this from within the critical section — the kernel takes care of that."——临界区内直接 `yield`，切换代码会连同临界区状态一起保存/恢复（细节在[[ch7-context-switch-deep-dive|第七章]]，这里先收下这个事实）。

`xQueueOverwrite` 的容许条件写在同一行判断里：覆写模式无视 `uxMessagesWaiting < uxLength`——队列满不满都能写。代价是它只对 `uxLength == 1` 的队列合法，函数入口的 `configASSERT( !( ( xCopyPosition == queueOVERWRITE ) && ( pxQueue->uxLength != 1 ) ) )` 会拦下违规。长度 1 + 覆写 = **邮箱**（mailbox）：永远保存"最新值"，旧值无条件丢弃。传感器 latest-reading 场景的标准解。

### 2. 队满的三种处理

快路径不成立（队满且非覆写）时，展开成三岔口：

```text
                    队列满,且有 xTicksToWait 参数
                              │
        ┌─────────────────────┼──────────────────────┐
        ▼                     ▼                      ▼
  xTicksToWait==0      设定超时起点后             xTaskCheckForTimeOut()
  立即返回              (首次循环)                  到期?
  errQUEUE_FULL              │                ┌──────┴──────┐
                              ▼               ▼             ▼
                    [IDF 双核] 临界区内:    返回            回到 for(;;) 顶部
                    vTaskPlaceOnEventList( errQUEUE_FULL   重试快路径
                      &xTasksWaitingToSend )                (数据可能已到)
                    portYIELD_WITHIN_API()
                    → 本任务阻塞,等接收者腾空间
```

| 模式     | 调用形态            | 行为                                                     |
| -------- | ------------------- | -------------------------------------------------------- |
| 失败即返 | `xTicksToWait == 0` | 返回 `errQUEUE_FULL`，调用方自己决定重试策略             |
| 限时阻塞 | 有限 tick 数        | 挂到 `xTasksWaitingToSend`，被接收者唤醒或超时唤醒       |
| 永久阻塞 | `portMAX_DELAY`     | 同上，无超时分支（`INCLUDE_vTaskSuspend` 为 1 时真无限） |

阻塞分支里有个容易漏看的细节：挂上事件链表前有 `xTaskCheckForTimeOut()` 复查——若恰好在设超时起点与挂链表之间队列变空过又满回来，循环会回头重试快路径而不是傻等。所有"检查-行动"之间存在窗口的地方，FreeRTOS 都用这个模式缝合，队列代码里至少出现四处。

### 3. 拷贝的落点：prvCopyDataToQueue

真正动存储区的只有 `prvCopyDataToQueue()`，三个 `xPosition` 走三条路：

```text
 queueSEND_TO_BACK (xQueueSend)          queueSEND_TO_FRONT / queueOVERWRITE
 ────────────────────────────            ────────────────────────────────────
   memcpy(pcWriteTo, item, size)           memcpy(pcReadFrom, item, size)
        │                                       │
        ▼                                       ▼
   pcWriteTo += size                      pcReadFrom -= size
        │                                       │
   pcWriteTo >= pcTail ?                  pcReadFrom < pcHead ?
     ├─ 是 → pcWriteTo = pcHead             ├─ 是 → pcReadFrom = pcTail - size
     └─ 否 → 不动                           └─ 否 → 不动
        │                                       │
        └──────────► uxMessagesWaiting++ ◄──────┘
                   (OVERWRITE 且原有一个元素时: 先 -- 再 ++,计数不变)
```

```c
/* queue.c — prvCopyDataToQueue() 核心逻辑(节选) */
else if( xPosition == queueSEND_TO_BACK )
{
    ( void ) memcpy( ( void * ) pxQueue->pcWriteTo, pvItemToQueue,
                     ( size_t ) pxQueue->uxItemSize );
    pxQueue->pcWriteTo += pxQueue->uxItemSize;
    if( pxQueue->pcWriteTo >= pxQueue->u.xQueue.pcTail )
    {
        pxQueue->pcWriteTo = pxQueue->pcHead;      /* 回绕 */
    }
}
```

`SEND_TO_FRONT` 写在 `pcReadFrom` 处再回退一格——于是下一个读取者会先读到它，"插队"语义达成。`OVERWRITE` 与 `SEND_TO_FRONT` 共用写入逻辑，差别只在计数修正：队里已有元素时覆写不增计数。

还有一个 `uxItemSize == 0` 的分支没画：那是信号量/互斥量的领地——不 memcpy，只 `++uxMessagesWaiting`，互斥量还要做优先级返还（`xTaskPriorityDisinherit()`）。这就是第十一章的全部剧情，此处按下。

### 4. 值传递与引用传递的选型

落到应用层，两种风格对照：

```c
/* 值传递:小消息(推荐默认) */
typedef struct { uint16_t seq; int16_t temp_x10; } sensor_msg_t;
xQueueSend(q, &( sensor_msg_t ){ .seq = n, .temp_x10 = t }, 0);

/* 引用传递:大块数据(传指针) */
FrameBuf *fb = frame_pool_acquire();          /* 池化分配 */
xQueueSend(q, &fb, portMAX_DELAY);            /* 拷的只是 4 字节指针 */
/* fb 的所有权交给消费者;池的回收协议代替 free 纪律 */
```

> [!tip] 传指针不是免死金牌
> 拷贝语义换来的"无生命周期问题"，传指针时就全部回来了：消费者还握着缓冲时生产者复用/释放它，就是数据竞争。池化 + 所有权转移协议是最低成本的补丁；对单读单写的大流量场景，第十四章的流缓冲是更对口的工具。

---

## 10.5 接收路径：xQueueReceive 与 xQueuePeek

### 1. xQueueReceive：发送的镜像

`xQueueReceive()` 与发送路径严格对称，快路径同样三步（临界区内）：

```c
taskENTER_CRITICAL( &( pxQueue->xQueueLock ) );
{
    const UBaseType_t uxMessagesWaiting = pxQueue->uxMessagesWaiting;
    if( uxMessagesWaiting > ( UBaseType_t ) 0 )
    {
        prvCopyDataFromQueue( pxQueue, pvBuffer );
        pxQueue->uxMessagesWaiting = uxMessagesWaiting - 1;

        if( listLIST_IS_EMPTY( &( pxQueue->xTasksWaitingToSend ) ) == pdFALSE )
        {
            if( xTaskRemoveFromEventList( &( pxQueue->xTasksWaitingToSend ) ) != pdFALSE )
            {
                queueYIELD_IF_USING_PREEMPTION();  /* 让被唤醒的生产者优先 */
            }
        }
        taskEXIT_CRITICAL( &( pxQueue->xQueueLock ) );
        return pdPASS;
    }
    /* 空队列:0 tick 返回 errQUEUE_EMPTY / 有限阻塞 / portMAX_DELAY,镜像 10.4 */
}
```

注意接收成功后唤醒的是**等空间的生产者**——你腾出了一个槽，正好让一个阻塞的发送者进来。生产者与消费者互相接力，这条级联链在 10.7 展开。

`prvCopyDataFromQueue()` 就是"先移再取"约定的实现：

```c
static void prvCopyDataFromQueue( Queue_t * const pxQueue, void * const pvBuffer )
{
    if( pxQueue->uxItemSize != ( UBaseType_t ) 0 )
    {
        pxQueue->u.xQueue.pcReadFrom += pxQueue->uxItemSize;   /* 先移到下一个读位 */
        if( pxQueue->u.xQueue.pcReadFrom >= pxQueue->u.xQueue.pcTail )
        {
            pxQueue->u.xQueue.pcReadFrom = pxQueue->pcHead;    /* 回绕 */
        }
        ( void ) memcpy( pvBuffer, ( void * ) pxQueue->u.xQueue.pcReadFrom,
                         ( size_t ) pxQueue->uxItemSize );
    }
}
```

### 2. xQueuePeek：读而不取

`xQueuePeek()` 想看队头又不消费它。结构上与 `xQueueReceive` 几乎相同，只多两行：

```c
pcOriginalReadPosition = pxQueue->u.xQueue.pcReadFrom;  /* 拷贝前存档 */
prvCopyDataFromQueue( pxQueue, pvBuffer );              /* 复用同一函数 */
pxQueue->u.xQueue.pcReadFrom = pcOriginalReadPosition;  /* 读位还原 */
```

"先移再取"的约定在这里兑现了红利：peek = 正常读 + 还原指针，零特判。还要注意 peek 成功后**不递减计数、不唤醒生产者**（没腾空间），反而会唤醒别的 `xTasksWaitingToReceive` 等待者——数据还在，下一个 peek 者也有份。peek 的典型用途：状态查询（`uxQueueMessagesWaiting` 之外的"看一眼内容"）、测试驱动框架里的断言读取。

### 3. 接收侧的完整快照

| API                    | 取数据   | 计数 | 唤醒谁                         | 阻塞语义             |
| ---------------------- | -------- | ---- | ------------------------------ | -------------------- |
| `xQueueReceive`        | 是       | −1   | 一个等空间的生产者             | 0 tick / 有限 / 永久 |
| `xQueuePeek`           | 是(拷出) | 不变 | 一个等数据的 peek 者           | 同上                 |
| `xQueueReceiveFromISR` | 是       | −1   | 置 `pxHigherPriorityTaskWoken` | 永不阻塞             |

---

## 10.6 ISR 变体与延迟解锁机制

到这里，任务级 API 的故事是完整的。但 ISR 里不能调用上述任何函数——它们会阻塞，而 ISR 无栈可换。FreeRTOS 为每个可能阻塞的 API 提供了 `*FromISR` 变体，这些变体引入了 `queue.c` 中最精巧的设计：**队列锁与延迟解锁**。先讲 Vanilla 的经典模型，再看 IDF 在双核上对它做了什么。

### 1. ISR 版本的约束

`xQueueSendFromISR()`（宏展开为 `xQueueGenericSendFromISR(..., queueSEND_TO_BACK)`）与任务版的差异：

- 永不阻塞：队满直接返回 `errQUEUE_FULL`，没有 `xTicksToWait` 参数；
- 唤醒变成"报告"：不直接触发调度，而是置 `*pxHigherPriorityTaskWoken = pdTRUE`，让 ISR 在**退出时**通过 `portYIELD_FROM_ISR()` 统一决策——同一个 ISR 里发 N 个队列，只做一次切换判断；
- 进入方式：`prvENTER_CRITICAL_OR_MASK_ISR()`（IDF 私有宏，`esp_additions/include/esp_private/freertos_idf_additions_priv.h`），它在单核与 SMP 下展开成完全不同的东西——正是本节的主角。

### 2. Vanilla/单核模型：为什么不能直接动链表

任务版发送在阻塞前有个"退出临界区 → 挂调度器 → 挂事件链表"的窗口（10.4 第 2 岔图下面那段的单核版本：`vTaskSuspendAll()` + `prvLockQueue()`）。窗口期内，任务已经放下了关中断保护、还没挂上链表——此刻 ISR 进来发送，如果它直接去动 `xTasksWaitingToReceive`（把等待者摘链表、塞就绪链表），会和正在慢吞吞挂链表的任务**并发写同一条链表**，链表指针必然打架。

FreeRTOS 的解法是给队列加**锁**：任务在动事件链表前，把 `cRxLock`/`cTxLock` 从 `queueUNLOCKED(-1)` 置为 `queueLOCKED_UNMODIFIED(0)`（`prvLockQueue` 宏）。ISR 发现队列处于锁定态，就**不碰事件链表**，只把锁计数 `+1`（`prvIncrementQueueTxLock()`）作为"锁定期间有 N 次发送"的欠条，数据本身照常入队。等任务挂完链表、调用 `prvUnlockQueue()` 还账：数着欠条逐次补做唤醒，被唤醒任务先进 pending-ready 链表（因为此刻调度器仍挂起），恢复调度时统一搬进就绪链表。

```text
任务侧(单核模型)                          ISR 侧(xQueueSendFromISR)
─────────────────                        ─────────────────────────
vTaskSuspendAll()                          uxSaved = portSET_INTERRUPT_MASK_FROM_ISR()
prvLockQueue(q):                           if (有空间) {
  cRxLock/cTxLock: -1 → 0                    prvCopyDataToQueue(...)   ← 数据照常入队
  (队列进入"锁定")                            if (cTxLock == UNLOCKED)
vTaskPlaceOnEventList(                          直接唤醒等待者(安全:无并发窗口)
  &xTasksWaitingToSend)                      else
prvUnlockQueue(q):                            prvIncrementQueueTxLock() ← 只记欠条,不动链表
  while (cTxLock > 0) {                   } else 返回 errQUEUE_FULL
    补唤醒 cTxLock 个接收者               portCLEAR_INTERRUPT_MASK_FROM_ISR(uxSaved)
    (进 pending-ready)
    cTxLock--
  }
  cTxLock = UNLOCKED
xTaskResumeAll()
```

两个方向对称：`cTxLock` 记"锁定期间的发送"（还账时唤醒接收者），`cRxLock` 记"锁定期间的接收"（还账时唤醒生产者）。计数上限由 `prvIncrementQueueTxLock()` 封顶在系统任务数——唤醒次数不可能超过等待者总数。

`portSET_INTERRUPT_MASK_FROM_ISR()` 的存在是这套机制的前提：它只屏蔽**低于当前 ISR 优先级**的中断（并返回原状态供恢复），保证本 ISR 执行期间不会被同级/更低级的嵌套再次进入，但高优先级中断仍可抢占。这也是 Cortex-M 端口 "maximum system call priority" 概念的出处——高于该优先级的中断永不被内核屏蔽，因此**永远不许调用任何 FreeRTOS API**。Xtensa 端口的中断模型与之如何对应，[[ch17-xtensa-port-internals|第十七章]]展开。

### 3. IDF 双核：整套机制被裁掉

现在看 ESP32 上真实发生的事。默认树 `queue.c` 顶部：

```c
/* Single core FreeRTOS uses queue locks to ensure that vTaskPlaceOnEventList()
 * calls are deterministic ... However, the SMP implementation is
 * non-deterministic anyways, thus SMP can forego the use of queue locks
 * (replaced with a critical sections) in exchange for better queue performance. */
#if ( configNUMBER_OF_CORES > 1 )
    #define queueUSE_LOCKS            0      /* ← ESP32 双核默认:不用队列锁 */
    #define queueUNLOCKED             ( ( int8_t ) 0 )
#else
    #define queueUSE_LOCKS            1      /* 单核:经典模型 */
    #define queueUNLOCKED             ( ( int8_t ) -1 )
    ...
#endif
```

双核下 `queueUSE_LOCKS == 0`：`cRxLock`/`cTxLock` 字段**不编入结构体**，`prvLockQueue`/`prvUnlockQueue` 连函数体都不存在，发送/接收路径里 `vTaskSuspendAll + prvLockQueue + ... + prvUnlockQueue + xTaskResumeAll` 整段被 `#if` 挖掉。取而代之：**一切在 per-queue 自旋锁的临界区内完成**——包括阻塞本身：

```c
/* IDF 双核的阻塞分支(queueUSE_LOCKS == 0):临界区内直接睡 */
if( xTaskCheckForTimeOut( &xTimeOut, &xTicksToWait ) == pdFALSE )
{
    vTaskPlaceOnEventList( &( pxQueue->xTasksWaitingToSend ), xTicksToWait );
    portYIELD_WITHIN_API();     /* 持锁阻塞:切换代码保存/恢复临界区状态 */
}
```

为什么敢这么做？因为整套延迟解锁机制的存在理由是**确定性**：单核上"挂调度器"是可重入、不关中断的保护方式，代价是需要 ISR 侧配合记账。而 SMP 内核本身已经放弃确定性（自旋锁的等待时间取决于对端核），"用临界区换掉挂起调度器"不再损失什么，反而省掉记账、缩短了路径——官方注释说得直白：换更好的队列性能。`Queue_t` 尾部那把 `xQueueLock` 就是这笔交易的收据。

> [!tip] Vanilla vs ESP-IDF：队列的并发保护
>
> | 维度                               | Vanilla v10.5.1（单核模型）                         | IDF fork（ESP32 双核默认）                                                                     |
> | ---------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
> | 快路径保护                         | `taskENTER_CRITICAL()`（关中断）                    | `taskENTER_CRITICAL(&q->xQueueLock)`（关本核中断 + 抢 per-queue 自旋锁）                       |
> | 阻塞前保护                         | `vTaskSuspendAll()` + `prvLockQueue()` 挂起调度器   | 无窗口——直接在临界区内挂链表并 yield                                                           |
> | `cRxLock`/`cTxLock`                | 存在，ISR 侧记账、`prvUnlockQueue()` 补唤醒         | **编译期裁掉**（`queueUSE_LOCKS == 0`）                                                        |
> | FromISR 进入                       | `portSET_INTERRUPT_MASK_FROM_ISR()` 存/恢复中断状态 | `taskENTER_CRITICAL_ISR(&q->xQueueLock)` 抢自旋锁（经 `prvENTER_CRITICAL_OR_MASK_ISR` 宏适配） |
> | 语义（拷贝、FIFO、唤醒一个、邮箱） | 一致                                                | 一致                                                                                           |
>
> 注意 `CONFIG_FREERTOS_UNICORE` 并不切换源码树，只是把 `configNUM_CORES` 设为 1——同一棵默认树里，队列锁机制随之重新编入，回到经典模型。适配两层形态的正是 `freertos_idf_additions_priv.h` 里那组 `prvENTER_CRITICAL_OR_MASK_ISR` / `prvENTER_CRITICAL_OR_SUSPEND_ALL` 宏：单核展开为"挂调度器/屏蔽中断"，SMP 展开为"抢自旋锁"。

---

## 10.7 多生产者 / 多消费者语义

### 1. 唤醒一个，而不是惊群

发送成功后唤醒等待者的方式是 `xTaskRemoveFromEventList(&xTasksWaitingToReceive)`——从**按优先级排序**的链表摘走链表头：优先级最高的等待者；同优先级内按 `vTaskPlaceOnEventList()` 插入顺序，FIFO。每次事件只唤醒一个，其余继续睡。

这与"广播唤醒全部、被唤醒者再抢"的惊群（thundering herd）模型相比：没有输者白付的唤醒成本，天然负载分摊（每来一个元素，恰好一个消费者醒来处理）。代价是**同优先级的多个消费者之间没有公平性以外的保证**——一个快消费者可能长期独占队列，慢消费者饿着但系统吞吐反而更高。

### 2. 生产者与消费者互相级联

把 10.4/10.5 的两侧拼起来，稳态下的队列像一条传送带：

```text
生产者 P1 P2 P3                     消费者 C1 C2
    │ send                              ▲ receive
    ▼                                   │
  ┌────────── 队列(容量 N) ──────────────┐
  │  满了: P 挂 xTasksWaitingToSend      │
  │  空了: C 挂 xTasksWaitingToReceive   │
  └──────────────────────────────────────┘
  C 取走一个 → 唤醒一个 P(有空间了)
  P 放入一个 → 唤醒一个 C(有数据了)
  → 消费速率 == 生产速率时,队列充当速率平滑器
```

一个极限情形值得在脑中跑一遍：队列长度 0 会怎样？`xQueueCreate(0, size)` 直接失败（`uxQueueLength > 0` 是创建检查的第一条）——FreeRTOS 没有"会合点"（rendezvous）语义，发送总是先落队列再等人取。要"手递手"传递，用长度 1 的队列近似：满了的队列让发送者阻塞到接收者腾空，近似同步点效果。

### 3. 顺序保证的边界

- **同队列同优先级**：发送 FIFO、接收 FIFO，唤醒 FIFO——顺序可靠；
- **跨优先级**：高优先级等待者优先被唤醒，顺序被优先级改写（这是特性不是 bug）；
- **`xQueueSendToFront`**：插队机制，专供高紧迫消息（如紧急停机命令）越过积压；
- **多生产者**：`prvCopyDataToQueue` 全程在临界区内，多个 `xQueueSend` 并发调用不会撕裂单个元素——原子性以元素为单位；
- **跨核**：两个核上的任务同时操作同一队列，per-queue 自旋锁串行化之——这正是 10.6 那把 `xQueueLock` 存在的意义，[[ch23-cross-core-synchronization|第二十三章]]会看到它的完整成本模型。

---

## 10.8 实验：生产者-消费者与吞吐测量

理论到此，上 QEMU 量化。设计：一个队列、一个生产者、一个消费者，测每元素往返成本；再追加邮箱与 peek 的小实验验证语义。

### 1. 代码

```c
/* main/freertos-ch10.c —— 队列实验 */
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_timer.h"

#define QUEUE_LEN   8
#define BURST       20000
#define ITEM_BYTES  sizeof(uint32_t)

static QueueHandle_t s_q;

/* 生产者:发一整批,计时 */
static void producer_task(void *arg)
{
    uint32_t seq = 0;
    int64_t t0 = esp_timer_get_time();
    for (int i = 0; i < BURST; i++) {
        seq = ( uint32_t ) i;
        if( xQueueSend( s_q, &seq, portMAX_DELAY ) != pdPASS ) {
            printf( "[producer] unexpected failure at %d\n", i );
            vTaskDelete( NULL );
        }
    }
    int64_t us = esp_timer_get_time() - t0;
    printf( "[producer] %d items in %lld us  (%.2f us/send avg)\n",
            BURST, us, ( double ) us / BURST );
    vTaskDelete( NULL );
}

/* 消费者:收满一批,校验顺序并计时 */
static void consumer_task(void *arg)
{
    uint32_t v, expect = 0;
    bool in_order = true;
    int64_t t0 = esp_timer_get_time();
    for ( int i = 0; i < BURST; i++ ) {
        xQueueReceive( s_q, &v, portMAX_DELAY );
        if( v != expect++ ) {
            printf( "[consumer] ORDER BROKEN: got %u want %u\n", v, expect - 1 );
            in_order = false;
        }
    }
    int64_t us = esp_timer_get_time() - t0;
    printf( "[consumer] %d items in %lld us  (%.2f us/recv avg), in-order=%d\n",
            BURST, us, ( double ) us / BURST, in_order );
    vTaskDelete( NULL );
}

/* 邮箱 + peek 语义演示 */
static void mailbox_demo(void)
{
    QueueHandle_t mb = xQueueCreate( 1, sizeof( int ) );
    int v = 1, peeked = 0;
    xQueueOverwrite( mb, &v );
    v = 2;
    xQueueOverwrite( mb, &v );            /* 覆写:旧值 1 无声丢弃 */
    xQueuePeek( mb, &peeked, 0 );
    printf( "[mailbox] after 2 overwrites, peek = %d (expect 2)\n", peeked );
    xQueueReceive( mb, &peeked, 0 );
    printf( "[mailbox] after consume, peek rc=%d (expect err %d)\n",
            xQueuePeek( mb, &peeked, 0 ), errQUEUE_EMPTY );
    vQueueDelete( mb );
}

void app_main(void)
{
    s_q = xQueueCreate( QUEUE_LEN, ITEM_BYTES );
    configASSERT( s_q );
    printf( "[ch10] queue created: len=%d item=%d bytes, total=%d bytes\n",
            QUEUE_LEN, ( int ) ITEM_BYTES, QUEUE_LEN * ( int ) ITEM_BYTES );
    mailbox_demo();
    xTaskCreate( producer_task, "prod", 3072, NULL, 5, NULL );
    xTaskCreate( consumer_task, "cons", 3072, NULL, 5, NULL );
}
```

```bash
idf.py create-project freertos-ch10 && cd freertos-ch10   # 然后 main.c 换成上面
idf.py set-target esp32 && idf.py qemu monitor
```

### 2. 典型输出（QEMU，数量级示意）

```text
[ch10] queue created: len=8 item=4 bytes, total=32 bytes
[mailbox] after 2 overwrites, peek = 2 (expect 2)
[mailbox] after consume, peek rc=0 (expect err 0)
[producer] 20000 items in 312845 us  (15.64 us/send avg)
[consumer] 20000 items in 313010 us  (15.65 us/recv avg), in-order=1
```

（成功路径静默、失败才打印——顺序校验的输出为空本身就是结果；`errQUEUE_EMPTY` 数值为 0，观察要点 4 展开这个返回值约定。）

### 3. 观察要点

1. **顺序校验通过**。整个输出没有一行 `ORDER BROKEN`，`in-order=1` 收尾：FIFO 语义在两任务并发下成立，即使它们被调度器分到不同核（`xTaskCreate` 不绑核，可再加 `xPortGetCoreID()` 打印验证漂移）。
2. **send 与 recv 均摊成本几乎相等**。两侧路径对称，代价都摊在"拷贝 + 临界区 + 可能的切换"上。QEMU 的绝对值偏大且抖动明显（仿真外设与真实 LX6 时序不同），**只做相对比较**；真机上典型个位数微秒。把 `BURST` 调大，均摊值趋于稳定——首次编译/缓存冷启动被摊薄。
3. **吞吐随 `QUEUE_LEN` 变化不明显**。容量只影响"填满前生产者能跑多远"的突发平滑，稳态吞吐由消费侧决定。把消费者里插一句 `vTaskDelay(1)` 再跑：生产者均摊立刻涨到接近一个 tick 的量级——它现在大部分时间睡在 `xTasksWaitingToSend` 上，队列的背压（backpressure）肉眼可见。
4. **邮箱实验验证了 10.4 的覆写语义**：连续 overwrite 后队列里只有最新值；取空后再 peek 返回 `errQUEUE_EMPTY`。这里有个值得当场认清的返回值约定（`projdefs.h`）：`pdPASS == pdTRUE == 1`，而 `errQUEUE_EMPTY` 与 `errQUEUE_FULL` 都是 0——两个错误码同值，仅凭返回值分不清"空"还是"满"。判断成败就写 `!= pdPASS`；要区分空/满，只能另查 `uxQueueMessagesWaiting()`。
5. **改一发看暗线**：`idf.py menuconfig` 里开 `CONFIG_FREERTOS_UNICORE` 重编，`xQueueLock` 的争用消失（单核模型回归），吞吐通常小幅变化——10.6 那套 `#if` 的实际效果可以在同一个实验里摸到。

---

## 10.9 小结

- 队列是 FreeRTOS **唯一的通用 IPC 原语**：信号量 = 零尺寸队列，互斥量 = 带优先级继承的零尺寸队列；`queue.c` 一个文件承载整个内核对象体系。
- `Queue_t` 的骨架是**环形缓冲四指针 + 双等待链表 + 一个计数字**：`pcReadFrom` 指向上次读位（"先移再取"），`uxMessagesWaiting` 是唯一的状态读数，两条事件链表按优先级有序。
- 创建是**单次堆分配**（结构体 + 存储区同块），IDF 下经 `heap_idf.c` 转到 `heap_caps_malloc(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)`——内部 RAM 强制策略，第二十章展开。
- 发送/接收是**临界区内三步舞**：拷数据、唤醒一个对侧等待者、必要时 yield。队满三岔口：即败 / 限时阻塞 / 永久阻塞；`xQueueOverwrite` 只对长度 1 队列合法，构成邮箱。
- 数据是**拷贝语义**：换掉生命周期管理，代价随 item 尺寸线性；大块数据传指针 + 所有权协议，或改用流缓冲。
- Vanilla 的 ISR 变体靠 **cRxLock/cTxLock 延迟解锁**避免与"正在挂链表的任务"并发写链表；IDF 双核默认配置**整套裁掉**，换成 per-queue 自旋锁临界区内直接阻塞——确定性换性能，`Queue_t` 里的 `xQueueLock` 就是证据。
- 多消费者靠"事件只唤醒链表头一个"避免惊群；生产者消费者在队列两侧互相级联唤醒，容量决定背压的突发平滑范围。

下一章顺着 10.2 那个 union 往下挖：信号量与互斥量如何用"零尺寸队列"实现计数与持有语义，互斥量为何必须携带优先级继承，以及一次教科书级的优先级反转实验。[[ch11-semaphore-mutex-priority-inheritance|第十一章]]见。
