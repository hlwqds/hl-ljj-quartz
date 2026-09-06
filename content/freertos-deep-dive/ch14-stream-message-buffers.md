---
title: "FreeRTOS 深度解析（十四）：流缓冲与消息缓冲"
date: 2026-08-26
description: "拆解 stream_buffer.c：StreamBuffer_t 环形结构、单读单写（SPSC）免锁原理与内存序、xStreamBufferSend/Receive 走读与字节阈值，消息缓冲的 4 字节长度前缀封包，Vanilla 与 IDF 的锁与屏障实现对照，以及一个 UART 风格的可变长日志管道实验。"
tags: [freertos, rtos, esp32, esp-idf, ipc, stream-buffer, message-buffer, spsc, lock-free, qemu]
---

> [!info] FreeRTOS 深度解析系列 0. [[freertos-deep-dive|系列索引]] 14. **第十四章：流缓冲与消息缓冲（单读单写约束）**

# FreeRTOS 深度解析（十四）：流缓冲与消息缓冲

队列解决的是"定长消息"的传递，但真实系统里大量数据天生**变长**：一行日志 20 到 120 字节不等，一帧 UART 数据长度不定，一段传感器的采样序列想"流式"地涌过去。用队列装它们，要么按最大长度分配每个槽位（内存浪费），要么套一层指针+内存池（复杂度回来了）。FreeRTOS v10 引入的流缓冲（stream buffer）与消息缓冲（message buffer）就是这对缺口的官方答案——而它们为此付出的代价，是一个全内核对象中独一无二的设计决策：**放弃多读多写，只支持单读者单写者，换来数据路径上的完全免锁**。

本章拆解 `stream_buffer.c`（IDF 默认内核树中约 1500 行）：先看数据结构，再回答核心问题——为什么"只有一个读者、一个写者"就能免锁（包括 SMP 双核下的内存序问题），然后走读收发 API 的阻塞语义与字节阈值，看消息缓冲如何用 4 字节长度前缀在流上重建"消息"边界，最后用实验搭一条 UART 风格的变长日志管道。

---

## 14.1 队列不够用的地方：变长数据的税

先明确队列（第十章）的传递模型：`xQueueSend()` 把 item **按值拷贝**进队列的存储区，槽位大小在 `xQueueCreate()` 时一次定死。对变长数据，这个模型立刻收税：

| 变通方案         | 做法                         | 代价                                                 |
| ---------------- | ---------------------------- | ---------------------------------------------------- |
| 按最大长度建队列 | item size = 最长消息         | 平均利用率暴跌：120 字节槽位装 20 字节日志，浪费 83% |
| 传指针 + 内存池  | 队列只传指针，真实数据在池里 | 池管理、生命周期、悬挂指针——复杂度全回来了           |
| 多次队列调用拼包 | 把一条消息切成多个定长 item  | 接收端要重组，中间被抢占时消息交错                   |

流缓冲换了一个模型：**底层是裸字节流**。`xStreamBufferSend()` 想写多少字节写多少，写不下的部分留在调用者手里（部分写语义）；`xStreamBufferReceive()` 想读多少读多少。没有任何"槽位"概念，一段环形内存 + 两个游标就是全部状态。消息缓冲再在其上加一层薄封装：每条消息前置 4 字节长度头，把字节流重新切出消息边界。

官方头文件对它的定位说得很直白（`stream_buffer.h` 顶部注释）：实现轻量，**特别适合"中断到任务"与"核到核"的通信场景**。这两个场景的共同点恰好是：一端一个生产者、另一端一个消费者——SPSC。这不是巧合，是设计契约。

---

## 14.2 StreamBuffer_t 解剖

IDF 默认内核树（`components/freertos/FreeRTOS-Kernel/`，文件头自称 "FreeRTOS Kernel V10.5.1 (ESP-IDF SMP modified)"）中 `stream_buffer.c` 的核心结构，剥掉条件编译后：

```c
typedef struct StreamBufferDef_t
{
    volatile size_t xTail;                       /* 读游标：下一个待读字节 */
    volatile size_t xHead;                       /* 写游标：下一个写入位置 */
    size_t xLength;                              /* 数据区长度（字节） */
    size_t xTriggerLevelBytes;                   /* 唤醒读者所需的最小字节数 */
    volatile TaskHandle_t xTaskWaitingToReceive; /* 等数据的读者（单席位！） */
    volatile TaskHandle_t xTaskWaitingToSend;    /* 等空间的写者（单席位！） */
    uint8_t * pucBuffer;                         /* 数据区指针 */
    uint8_t ucFlags;                             /* 消息缓冲/静态分配标志位 */
    /* 可选：uxStreamBufferNumber、收发完成回调 ... */
    portMUX_TYPE xStreamBufferLock;              /* IDF 增加：per-buffer 自旋锁 */
} StreamBuffer_t;
```

注意两点。一，结构里**没有链表、没有事件等待列表**——`queue.c` 里那套 `xTasksWaitingToSend/Receive` 双向链表（每个可阻塞方向一条）在这里坍缩成两个单席位句柄，这正是单读单写约束在数据结构上的投影。二，最后一行 `portMUX_TYPE xStreamBufferLock` 是 Vanilla 没有的 IDF 改造，14.6 节展开。

### 1. 环形布局与一字节空位

数据区是普通字节数组，`xHead`/`xTail` 是环上的两个游标，有效数据是从 `xTail` 前进到 `xHead` 的环上区间：

```text
 index:   0    1    2    3    4    5    6    7
       ┌────┬────┬────┬────┬────┬────┬────┬────┐
       │ D  │ D  │ D  │ F  │ F  │ F  │ F  │ D  │   D = 数据, F = 空闲
       └────┴────┴────┴────┴────┴────┴────┴────┘
         ▲                 ▲                 ▲
         │                 └─ xHead = 3      └─ xTail = 7
         └─ 有效数据 = [7 → 8) ∪ [0 → 3)，共 4 字节（回绕场景）
```

环形缓冲的经典难题是满/空歧义：朴素实现里"满"和"空"都表现为 `xHead == xTail`。FreeRTOS 的解法是**永不填满**：`xStreamBufferSend()` 里的 `xMaxReportedSpace = xLength - 1`，可用空间最多报告 `xLength-1` 字节，`xTail` 永远追不上 `xHead`。配套细节在 `xStreamBufferGenericCreate()` 里：申请尺寸先 `xBufferSizeBytes++` 再连头带尾一次 `pvPortMalloc(xBufferSizeBytes + sizeof(StreamBuffer_t))`（结构在前、数据区紧随其后），所以**用户感知的容量恰好等于创建参数**，那一字节空位被实现藏起来了。

两个游标的基础运算都在源码里能对上号：`prvBytesInBuffer()` 算 `xLength + xHead - xTail` 再回绕取模得有效字节数；`xStreamBufferSpacesAvailable()` 对称地算空闲量。

### 2. 一个值得驻足的细节：读取顺序与重读循环

`xStreamBufferSpacesAvailable()` 里有一段不带任何锁的采样代码，注释直译如下："下面的代码先读 `xTail` 再读 `xHead`。如果两次读之间缓冲区**被更新了一次**，这是安全的；被更新**多于一次**，就不安全——所以要用循环"：

```c
do {
    xOriginalTail = pxStreamBuffer->xTail;
    xSpace = pxStreamBuffer->xLength + pxStreamBuffer->xTail;
    xSpace -= pxStreamBuffer->xHead;
} while( xOriginalTail != pxStreamBuffer->xTail );
```

这是 SPSC 约束换来的典型红利：唯一读者只会推进 `xTail`、且只会让 `xSpace` 变大，因此采样期间**至多发生一次变化**；先读 `xTail` 再读 `xHead` 的顺序保证读到的 `xHead` 不旧于 `xTail`（否则可能算出负数回绕成天文数字）。若循环出口时 `xTail` 没变，说明本次采样一致。多读者场景下这个循环照样会静默算错——又一个"约束即正确性来源"的例子。

---

## 14.3 单读单写为什么免锁：SPSC 的所有权划分

`stream_buffer.h` 顶部有一段全 FreeRTOS 独一无二的警告，大意是：**在所有 FreeRTOS 对象中唯它一份，本实现假设只有一个写者（任务或中断）和一个读者（任务或中断）**。写者与读者可以是不同的任务/中断，但绝不允许出现多个不同写者或多个不同读者；实在要多写/多读，必须把每次写（读）API 调用包进临界区且阻塞时间设为 0。

为什么这么苛刻的约束反而能换来免锁？答案是一张干净的所有权表：

| 字段 / 区域                       | 写者                        | 读者                     |
| --------------------------------- | --------------------------- | ------------------------ |
| `xHead`                           | **写**（唯一修改者）        | 只读                     |
| `xTail`                           | 只读                        | **写**（唯一修改者）     |
| 数据区 `[xHead, xTail)`（空闲侧） | **写**（memcpy 写入新数据） | 不碰                     |
| 数据区 `[xTail, xHead)`（有效侧） | 不碰                        | **写**（memcpy 读走）    |
| `xTaskWaitingToSend`              | **写**（阻塞前登记自己）    | 写（唤醒时清空）         |
| `xTaskWaitingToReceive`           | 写（唤醒时清空）            | **写**（阻塞前登记自己） |

每个 volatile 字段要么只有一个修改者（`xHead`/`xTail`），要么修改只发生在临界区内（两个等待句柄）。没有共享可变状态需要互斥，自然不需要锁。

### 1. 发布顺序：数据先于指针

免锁的正确性不只靠"各改各的"，还靠**顺序**。看 `prvWriteBytesToBuffer()` 的调用方式（`prvWriteMessageToBuffer()` 内）：

```text
 写者路径                                     读者视角
 ─────────────────────────────              ─────────────────────────────
 1. memcpy( pucBuffer + xHead, 数据, n )     1. 读 xHead —— 得到一个"旧但有效"的位置
 2. 计算 newHead = xHead + n (回绕取模)        2. memcpy( 出, pucBuffer + xTail, m )
 3. pxStreamBuffer->xHead = newHead  ←发布    3. pxStreamBuffer->xTail = newTail ←发布
    （volatile 写，最后一步）                   （volatile 写，最后一步）
```

关键在第 3 步：`xHead` 的更新是**唯一**的"数据已就位"的发布点，而且发生在 `memcpy` 之后。读者若在发布前读到旧 `xHead`，只会低估可用数据量（下次再读就是了），绝不会读到"指针已更新、数据还没落好"的撕裂状态。读侧对称：`prvReadMessageFromBuffer()` 全程用局部变量 `xNextTail` 链式读取，**读完整条消息后才一次性提交** `pxStreamBuffer->xTail`——源码注释明说：不让写者过早看到"空间已释放"，因为读可能因接收缓冲不足而中止（14.5 节）。

### 2. SPSC 无锁原理图

把整套机制画在一张图上：

```text
                    ┌────────────── StreamBuffer_t ──────────────┐
                    │  xTail(读游标)   [环形数据区 xLength 字节]   xHead(写游标) │
                    └──────▲──────────────────▲───────────────▲───┘
                           │                  │               │
        ┌──────────────────┘                  │               └────────────────┐
        │                                     │                                │
 ┌──────┴───────┐                    ┌────────┴────────┐              ┌───────┴───────┐
 │   写者（唯一） │                    │  读者（唯一）    │              │   其他任务     │
 └──────┬───────┘                    └────────┬────────┘              └───────────────┘
        │                                     │
        │ 1. 查 xTail 算空间（只读）            │ 1. 查 xHead 算可用量（只读）
        │ 2. memcpy 数据到 [xHead...]         │ 2. memcpy 数据从 [xTail...] 出
        │ 3. volatile 发布新 xHead  ──┐       │ 3. volatile 发布新 xTail  ──┐
        │                             │       │                             │
        │    ┌────────────────────────┘       │      ┌──────────────────────┘
        │    ▼                                │      ▼
        │  指针更新 = 唯一发布点，              │  指针更新 = 唯一消费点，
        │  永远发生在数据落好之后               │  永远发生在数据取走之后
        │                                     │
        │        ┌──── 数据路径：全程无锁 ────┐│
        └───────►│  volatile 游标 + 单调推进  │◄┘
                 └───────────────────────────┘
        ┌── 控制路径（检查+登记等待）：临界区内三步原子完成 ──┐
        │  查数据量 → xTaskNotifyStateClear → 登记等待句柄   │
        └──────────────────────────────────────────────────┘
```

数据路径（大头的 memcpy）完全免锁；锁只出现在控制路径上"检查状态并登记等待"的一瞬间，而且这一瞬间保护的不是数据，是**等待句柄的单席位**和丢失唤醒竞争（见 14.4）。

### 3. 单核视角：为什么 volatile 就够

单核上，写者与读者只可能被两件事交错：任务切换（调度器）或中断。两者都不会把"memcpy 完成后、`xHead` 发布前"的窗口撕开——`memcpy` 是普通函数调用，中途不会切走执行流（除非中断，而 ISR 里跑的若是同一个写者身份——比如"中断写、任务读"模式——那它本身就是唯一写者，自洽）。所以单核下：`volatile` 阻止编译器把指针读写缓存进寄存器或重排出有效顺序，就足够了。**这也是 Vanilla v10.5.1 的全部做法**：它的 `xStreamBufferSend()` 里阻塞检查用的是无参数的全局 `taskENTER_CRITICAL()`，通知宏用 `vTaskSuspendAll()`/`xTaskResumeAll()`，数据路径同样裸奔。

### 4. 跨核视角：内存序、cache 与 portMEMORY_BARRIER

双核 SMP 上问题升级：写者在 Core 0 发布 `xHead`，读者在 Core 1 何时能看到？三层事实：

1. **可见性介质**。ESP32 两核共享同一块内部 SRAM，且内部 SRAM 访问**不经过数据 cache**（cache 只作用于 Flash/PSRAM 侧）。写入一旦离开 CPU 写缓冲，即对另一核可见；Xtensa LX6 对齐的 32 位 load/store 是原子的，`size_t` 游标的单次读写不存在撕裂。cache 一致性的完整图景留到第二十三章。
2. **顺序性**。免锁正确性要求"数据写在前、指针发布在后"这个顺序对另一核可见。C 编译器层面靠 `volatile` 抑制重排；硬件层面，ESP32 内部 SRAM 是强序的（写按序传播）。真正需要显式 `memw` 指令冲刷写缓冲的是外设寄存器与 PSRAM 场景——内核临界区实现（下节）已经覆盖了必要顺序。
3. **`portMEMORY_BARRIER` 是什么、不是什么**。它是 FreeRTOS 的通用端口宏，`FreeRTOS.h` 里默认定义为空，供有需要的端口重定义；内核里最典型的使用点是 `tasks.c` 的 `vTaskSuspendAll()`——`uxSchedulerSuspended` 自增之后跟一个 `portMEMORY_BARRIER()`，注释说明是防止编译器把这次自增挪到别处。ESP-IDF 的 Xtensa 端口**没有**定义它（展开为空）。要点：**stream_buffer.c 的正确性并不依赖 `portMEMORY_BARRIER`**——它依赖的是 `volatile` 游标 + "数据先于指针"的发布纪律 + 控制路径上的临界区。把屏障宏当成 SPSC 免锁的守护神是常见误读，它守护的是别的变量（如调度器挂起计数）的编译器顺序。

> [!note] 一句话版本
> SPSC 免锁的根：**每个共享字段要么单写者，要么只在临界区内被改**；每个发布点（游标更新）**发生在对应数据搬运完成之后**；采样端（如 `SpacesAvailable`）用**先读消费游标、再读生产游标**的顺序把并发读变成"至多一次变化"的问题。`volatile` 管编译器，强序共享 SRAM 管硬件，临界区只管等待句柄。

---

## 14.4 xStreamBufferSend / Receive 走读

### 1. Send：先谈拢空间，再免锁搬运

`xStreamBufferSend(handle, data, len, ticks)` 的流程（对照源码）：

1. **算需求**。`xRequiredSpace = len`。若是消息缓冲（`ucFlags` 带 `sbFLAGS_IS_MESSAGE_BUFFER`），加上 4 字节长度头（`sbBYTES_TO_STORE_MESSAGE_LENGTH = sizeof(configMESSAGE_BUFFER_LENGTH_TYPE)`）。**消息缓冲全有全无**：整条放不下就压根不等（`xTicksToWait` 直接清零）；**流缓冲允许部分写**：需求封顶到 `xLength - 1`。
2. **阻塞协商循环**（`xTicksToWait != 0` 时）。进临界区（IDF 版带 `&pxStreamBuffer->xStreamBufferLock` 参数，见 14.6），三步原子完成：查空间 → `xTaskNotifyStateClear(NULL)` 清掉残留通知 → 空间不足则把当前任务登记进 `xTaskWaitingToSend`。出临界区后 `xTaskNotifyWait()` 睡下等唤醒；醒来重查超时，循环。
3. **免锁写入**。临界区外调 `prvWriteMessageToBuffer()`：消息缓冲先写 4 字节长度头再写数据（两段 memcpy 处理回绕），流缓冲按 `min(len, xSpace)` 能写多少写多少；最后发布新 `xHead`。**返回值是实际写入字节数**——流缓冲可能小于 `len`，调用方要处理尾巴；消息缓冲要么全写要么返回 0。
4. **按阈值唤醒读者**。`if( prvBytesInBuffer() >= xTriggerLevelBytes ) prvSEND_COMPLETED()`——写入后缓冲内总字节数达到阈值才发通知。`prvSEND_COMPLETED` 展开为 `xTaskNotify( xTaskWaitingToReceive, 0, eNoAction )`，即用**任务通知**（第十三章）做唤醒原语，这也是流缓冲比队列轻的原因之一：不进链表，直接戳 TCB。

### 2. 触发阈值（trigger level）：批量唤醒的旋钮

`xTriggerLevelBytes` 是创建时第二个参数（`xStreamBufferCreate(size, trigger)`），含义：**读者被唤醒所需的最小积压字节数**。默认 1（传 0 会被创建函数改成 1，源码注释：阈值 0 会让读者在空缓冲上也醒）。运行期可用 `xStreamBufferSetTriggerLevel()` 调整（要求不大于缓冲长度）。

它解决的问题是唤醒风暴：UART 每来一字节中断就 `xStreamBufferSendFromISR()` 一次，若阈值是 1，读者任务每字节被唤醒一次，上下文切换开销淹没系统。把阈值设成比如 32，读者会攒够 32 字节才醒，一次搬走一批。代价是时延上界变粗——低流量时读者要等超时兜底。消息缓冲的阈值固定语义是"一条完整消息"（长度头 + 数据到齐才算），`xMessageBufferCreate()` 内部就是按"能装下一条消息"来等待的。

### 3. 防丢失唤醒：清通知与登记的原子性

第 2 步里"`xTaskNotifyStateClear` + 登记句柄"必须在临界区内原子完成，否则有经典竞争。想象没有临界区的裸写法：读者查完发现没数据 → （此刻被抢占）→ 写者写入并 `xTaskNotify` 读者（读者还没睡下，通知只能挂起成 pending）→ 读者回来调 `xTaskNotifyWait`。这个方向其实是安全的——pending 的通知会让 `xTaskNotifyWait` 立即返回，读者醒来一查数据正好在。真正的坑在反序窗口：读者**先清掉通知状态**、还没来得及把自己登记进 `xTaskWaitingToReceive` 时，写者写入并检查等待句柄——看到 NULL，于是不发通知——读者随后才完成登记并睡下，**那次写入的唤醒机会被永远错过**（直到下次写入或超时）。临界区把"查 + 清 + 登记"压成一个不可分割的瞬间，而写者侧的"查是否有人等 + 发通知"同样在临界区内（`sbSEND_COMPLETED` 宏的展开），两个瞬间互斥，竞争窗口消失。

### 4. Receive：对称的镜像

`xStreamBufferReceive(handle, buf, bufsize, ticks)` 与 Send 逐点对称：临界区内查 `prvBytesInBuffer()` + 清通知 + 登记 `xTaskWaitingToReceive`；醒来后重查；`prvReadMessageFromBuffer()` 里流模式取 `min(用户缓冲, 可用量)` 字节（部分读语义），消息模式先读长度头判断装不装得下；成功取出后 `prvRECEIVE_COMPLETED()` 唤醒等空间的写者。`FromISR` 两兄弟去掉阻塞协商（ISR 里不能睡），收发完成通知换成 `portSET_INTERRUPT_MASK_FROM_ISR()` 保护 + `xTaskNotifyFromISR()`，并经 `pxHigherPriorityTaskWoken` 请求尽早切换。

---

## 14.5 消息缓冲：流 + 4 字节长度前缀

`message_buffer.h` 没有自己的 `.c`——所有 API 都是转发宏：`xMessageBufferSend(a,b,c,d)` 直接展开为 `xStreamBufferSend(a,b,c,d)`，`xMessageBufferCreate(size)` 展开为 `xStreamBufferGenericCreate(size, 0, pdTRUE, NULL, NULL)`。`pdTRUE` 最终变成 `ucFlags` 里的 `sbFLAGS_IS_MESSAGE_BUFFER` 位，从此收发路径走进 14.4 里所有"若是消息缓冲"的分支。**消息缓冲就是带封包纪律的流缓冲**。

### 1. 封包与拆包

线上格式（缓冲区内的字节布局）：

```text
 xMessageBufferSend("HELLO", 5) 连发两条变长消息后的环形数据区：

 ┌─────────┬────────────┬─────────┬────────────┬───────────────┐
 │ 05 00 00 00 │ H E L L O │ 02 00 00 00 │ H I     │  ←（后续空间） │
 └─────────┴────────────┴─────────┴────────────┴───────────────┘
  └─ 4字节长度头 ──┘         └─ 4字节长度头 ──┘
     = sizeof(configMESSAGE_BUFFER_LENGTH_TYPE)
     默认 = sizeof(size_t) = 4（32 位平台）

 xMessageBufferReceive() 拆包：读 4 字节头得 N → 检查用户缓冲 ≥ N
        → 读 N 字节载荷 →（都成功才）提交 xTail
```

写入方向，`prvWriteMessageToBuffer()` 先把长度头写进缓冲，再写载荷，两次调用 `prvWriteBytesToBuffer()` 链式推进局部 `xNextHead`，最后一次性发布。读取方向，`prvReadMessageFromBuffer()` 先取长度头，若用户缓冲装不下整条消息则把本次读取长度置 0——由于 `xTail` 只在真正消费后提交，**这条消息原封不动留在缓冲区里**，下次拿大一点的缓冲再来。配套的窥视 API `xStreamBufferNextMessageLengthBytes()` 可以不消费地读出下一条消息的长度，用来动态分配接收缓冲。

### 2. 与队列、流缓冲的选型表

| 维度            | 队列（queue.c）      | 流缓冲                 | 消息缓冲         |
| --------------- | -------------------- | ---------------------- | ---------------- |
| 传递模型        | 定长 item，按值拷贝  | 变长字节流             | 变长离散消息     |
| 边界            | 天然有（item）       | 无边界                 | 长度头重建边界   |
| 多生产者/消费者 | 支持                 | **禁止**               | **禁止**         |
| 部分传递        | 不适用（整 item）    | 允许部分写/读          | 全有全无         |
| 阻塞唤醒粒度    | 每进一 item          | trigger level 字节阈值 | 一条完整消息     |
| 典型场景        | 命令、事件、定长采样 | UART 字节流、日志汇聚  | 协议帧、变长事件 |

经验法则：**两端各是一个执行流**（一个 ISR + 一个任务、或一核一个任务）且数据变长 → 消息缓冲；纯字节流不在乎边界 → 流缓冲；需要多对多 → 老老实实用队列，或给流缓冲外加汇聚层（见 14.7）。

---

## 14.6 Vanilla vs IDF：锁与屏障的改造

IDF 默认树的 `stream_buffer.c` 基于 Vanilla v10.5.1 改造，核心差异集中在一件事：**Vanilla 的临界区假设单核，IDF 必须让它在双核下正确**。

### 1. 结构差异：per-buffer 自旋锁

Vanilla 的 `StreamBuffer_t` 没有任何锁字段；IDF 在结构尾部加了 `portMUX_TYPE xStreamBufferLock`（创建时 `portMUX_INITIALIZE()` 初始化）。这是一个**每缓冲区一把**的自旋锁——不是内核全局锁，两个不相干的流缓冲互不干扰。`portMUX_TYPE` 在 Xtensa 端口（`portable/xtensa/include/freertos/portmacro.h`）里就是 `spinlock_t`，`taskENTER_CRITICAL(&lock)` 的语义是"关本核中断 + 自旋等锁"（第十八章拆到指令级；`spinlock_acquire()` 用 `esp_cpu_compare_and_set()` 做原子 CAS 抢占，Xtensa 上落到 S32C1I 指令）。

### 2. 三处具体改造

| 位置                         | Vanilla v10.5.1                          | IDF FreeRTOS（默认树）                                                   |
| ---------------------------- | ---------------------------------------- | ------------------------------------------------------------------------ |
| 阻塞协商临界区               | `taskENTER_CRITICAL()`（无参，全局）     | `taskENTER_CRITICAL( &pxStreamBuffer->xStreamBufferLock )`（per-buffer） |
| 通知宏 `sbSEND_COMPLETED` 等 | `vTaskSuspendAll()` + `xTaskResumeAll()` | `prvENTER_CRITICAL_OR_SUSPEND_ALL( &lock )` + 对应退出宏                 |
| 阻塞醒来清等待句柄           | 临界区外直接 `xTaskWaitingToSend = NULL` | `configNUMBER_OF_CORES > 1` 时包进临界区                                 |

第三处最见功力。Vanilla 里 `xTaskNotifyWait()` 醒来后随手把句柄清 NULL 就行（单核，醒来即自己）；IDF 的源码注释原话大意是：**SMP 模式下任务可能被唤醒后调度到另一个核上跑，因此必须回临界区里清句柄**——否则写者核可能同时正在读写这个句柄，产生撕裂竞争。

`prvENTER_CRITICAL_OR_SUSPEND_ALL` 定义在 `esp_private/freertos_idf_additions_priv.h`，双形态编译：

```c
/* 多核构建：真正进临界区（自旋锁） */
#define prvENTER_CRITICAL_OR_SUSPEND_ALL( pxLock )    taskENTER_CRITICAL( ( pxLock ) )
#define prvEXIT_CRITICAL_OR_RESUME_ALL( pxLock )      ( { taskEXIT_CRITICAL( ( pxLock ) ); pdFALSE; } )

/* 单核构建：退化为 Vanilla 语义 */
#define prvENTER_CRITICAL_OR_SUSPEND_ALL( pxLock )    ( { vTaskSuspendAll(); ( void ) ( pxLock ); } )
#define prvEXIT_CRITICAL_OR_RESUME_ALL( pxLock )      xTaskResumeAll()
```

也就是说单核固件里 IDF 流缓冲的运行时行为与 Vanilla 逐指令等价；双核才引入自旋锁。这套"锁参数化、单核退化为挂起调度器"的模式是 IDF SMP 改造的惯用手法（`idf_changes.md` 里的通用招式，第二十二章总览）。

### 3. 屏障实现的对照

| 屏障问题     | Vanilla                                           | IDF（Xtensa 双核）                                          |
| ------------ | ------------------------------------------------- | ----------------------------------------------------------- |
| 编译器重排   | `volatile` 游标；`portMEMORY_BARRIER()`（默认空） | 同左；端口同样未定义该宏（空展开）                          |
| 控制路径互斥 | 无参全局临界区 / 挂起调度器                       | per-buffer 自旋锁 + 关中断                                  |
| 跨核可见性   | 无此场景（单核假设）                              | 内部 SRAM 强序共享；CAS（S32C1I）与临界区自带必要的顺序保证 |
| 数据路径     | 免锁（volatile + 发布顺序）                       | **同样免锁**——SMP 改造没有给 memcpy 路径加任何东西          |

最后一行是本章的题眼：连 Espressif 把内核改成双核时，也没敢（也不需要）给流缓冲的数据路径上锁。SPSC 所有权划分的免锁性在 SMP 下依然成立，改造只动了控制路径。

---

## 14.7 违反单读单写的后果与检测

约束是用来换性能的，违反它的代价是**静默数据损坏**。把两个典型违规场景的竞争窗口拆开看：

### 1. 双写者：空间检查的 TOCTOU

写者 A 与写者 B（两个任务、或一个任务一个 ISR）同时调 `xStreamBufferSend`：

```text
 写者 A                              写者 B
 ──────                              ──────
 查空间：剩 100 字节
      写 80 字节计划                  查空间：剩 100 字节
      （尚未发布 xHead）               写 80 字节计划
 memcpy 到 [head, head+80)           memcpy 到 [head, head+80)   ← 同一区间!
 发布 xHead += 80                    发布 xHead += 80            ← 第二次覆盖第一次
```

两个写者各自基于**同一份过期的 `xTail` 快照**算空间，数据写进同一区间互相覆盖，`xHead` 被推进两次——缓冲区里出现 160 字节"有效数据"，其中 80 字节是损坏的。消息缓冲下更惨：两个长度头交错，后续所有 `Receive` 拆包全部错位。另一个死亡路径是等待席位：A 登记进 `xTaskWaitingToSend` 后 B 也阻塞进来把句柄**覆盖**成自己，A 的唤醒通知发给了 B 的旧状态——丢失唤醒，A 永远睡死（直到超时）。

### 2. 双读者：快照过期与重复消费

两个读者各自在临界区里查到"有 50 字节"，出临界区后各自从**同一个 `xTail`** 开始 memcpy 各拿 50 字节——同一段数据被消费两次；两次提交 `xTail`，后写的赢，另一次读取等于从未发生。消息模式下表现为：同一条消息被处理两次、或下一条消息的长度头被上一个读者当数据读走一半导致拆包永久错位。

### 3. 检测手段

| 手段                                            | 能抓到什么                                                                                                                     | 局限                                                     |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------- |
| `configASSERT( xTaskWaitingToSend == NULL )`    | 写者**阻塞路径**上的双写登记                                                                                                   | 仅 debug 构建生效；不阻塞的双写（timeout=0）完全绕过断言 |
| `configASSERT( xTaskWaitingToReceive == NULL )` | 同上（读者侧）                                                                                                                 | 同上                                                     |
| 0x55 填充观察                                   | `prvInitialiseNewStreamBuffer()` 会把数据区 memset 成 0x55（特意不用 0xA5，那与栈填充混淆）——GDB 里看未被写过区域是否还是 0x55 | 事后取证，非主动检测                                     |
| 消息拆包校验                                    | 长度头出现非法值（巨大或 0）几乎必是双写/双读损坏                                                                              | 损坏已经发生                                             |
| trace 工具                                      | `traceBLOCKING_ON_STREAM_BUFFER_SEND` 等钩子可抓异常阻塞模式                                                                   | 需要配 tracealyzer 类前端（第二十四章）                  |

### 4. 正确的多写多读姿势

官方文档给的标准答案是：**每次写 API 调用包进临界区，且阻塞时间设为 0**（读侧对称）。临界区把"查空间 + 写 + 发布"重新压成原子的，0 阻塞消除了等待席位竞争。但临界区里自旋锁 + 关中断的代价在双核上并不便宜，更常见的工程替代方案：

1. **汇聚网关**：多个生产者先把消息丢进队列（队列天然多写安全），单一消费者任务从队列取出、作为唯一写者写进流/消息缓冲——队列当"多路复用器"，流缓冲当"高吞吐管道"。
2. **按核/按外设拆缓冲**：每个 UART、每个传感器的 ISR 天然是单写者，各配一个流缓冲，消费侧一个任务轮询多个缓冲（或用事件组聚合通知，第十二章）。
3. 中等流量下干脆退回队列——SPSC 的性能红利只在"高吞吐 + 单端单流"时值得这份纪律。

> [!tip] 纪律检查清单
> 代码评审遇到流/消息缓冲时问三句：谁写它（列全：任务 + ISR + 两核）？谁读它？两边是否各自恰好一个执行流？任何一侧出现"看情况，有时 A 任务有时 B 任务"，就是埋雷。

---

## 14.8 实验：UART 风格的可变长日志管道

搭一个经典结构：多个"模块"产生变长日志 → 汇聚网关（唯一写者）→ 消息缓冲 → 唯一消费者任务模拟慢速串口输出。写者钉在 Core 1、消费者钉在 Core 0，亲测"核到核"场景；同时用流缓冲观察 trigger level 的批量唤醒效果。

### 1. 代码

```c
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/message_buffer.h"
#include "freertos/stream_buffer.h"
#include "esp_random.h"
#include "esp_rom_sys.h"

#define LOG_MB_SIZE           1024
#define CONSUMER_US_PER_BYTE  60   /* 模拟慢速物理输出的每字节耗时 */

static MessageBufferHandle_t s_log_mb;

/* 生产者：模拟某个模块源源不断产生变长日志。
 * 它是 s_log_mb 的唯一写者 —— SPSC 契约的 S 端。 */
static void producer_task(void *arg)
{
    const char *tag = (const char *)arg;
    char line[96];
    uint32_t n = 0;
    for (;;) {
        int len = snprintf(line, sizeof(line),
                           "[%s] event=%lu rssi=-7%lu dBm\n",
                           tag, (unsigned long)n++,
                           (unsigned long)(esp_random() % 10));
        size_t sent = xMessageBufferSend(s_log_mb, line, len,
                                         pdMS_TO_TICKS(100));
        if (sent < (size_t)len) {
            printf("[gateway] dropped %d bytes (buffer full)\n",
                   len - (int)sent);
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

/* 消费者：模拟逐字节吐出的慢速 UART —— SPSC 契约的 C 端。 */
static void consumer_task(void *arg)
{
    char msg[128];
    for (;;) {
        size_t len = xMessageBufferReceive(s_log_mb, msg, sizeof(msg),
                                           portMAX_DELAY);
        if (len == 0) {
            continue;
        }
        for (size_t i = 0; i < len; i++) {     /* 模拟慢速物理输出 */
            esp_rom_delay_us(CONSUMER_US_PER_BYTE);
        }
        printf("%.*s", (int)len, msg);
    }
}

void app_main(void)
{
    s_log_mb = xMessageBufferCreate(LOG_MB_SIZE);
    configASSERT(s_log_mb);

    /* 写者钉 Core 1，读者钉 Core 0：核到核单读单写 */
    xTaskCreatePinnedToCore(producer_task, "gateway", 3072, "net", 5, NULL, 1);
    xTaskCreatePinnedToCore(consumer_task, "uart_tx", 3072, NULL, 4, NULL, 0);

    /* 违规实验（14.7）：放开下面的第二个生产者，观察静默损坏/断言。
     * 它与前一个生产者同写 s_log_mb，破坏"唯一写者"契约。 */
    /* xTaskCreatePinnedToCore(producer_task, "gateway2", 3072, "cfg", 5, NULL, 0); */
}
```

### 2. 跑起来

```bash
idf.py qemu monitor
```

典型输出（节选）：

```text
[net] event=317 rssi=-73 dBm
[net] event=580 rssi=-71 dBm
[gateway] dropped 18 bytes (buffer full)
[net] event=744 rssi=-76 dBm
...
```

### 3. 观察点

1. **背压可见**。消费者每字节拖 60µs，一条 30 字节日志约 1.8ms 才吐完；生产者 50ms 一条本不该堆——但把 `CONSUMER_US_PER_BYTE` 调大十倍，`dropped N bytes` 立刻频发：消息缓冲满 + 写超时 100ms 到，`xMessageBufferSend` 返回 0，网关丢日志并记账。**全有全无语义**让丢弃以整条为单位，日志永不截半——这正是流缓冲给不了、消息缓冲给的保证。
2. **违规实验**。把注释掉的第二个 `gateway2` 生产者放开（同钉 Core 0 也行）：它绕过"唯一写者"契约直接写同一缓冲。轻则偶发 `configASSERT( xTaskWaitingToSend == NULL )`（两个都阻塞时触发），重则输出行互相截断交错——静默损坏。对照 14.7 的分析逐条对号。
3. **trigger level 实验**。把消息缓冲换成 `xStreamBufferCreate(1024, 64)` + `xStreamBufferSend/Receive`，消费者改为"醒来一次尽量搬空"（`while (xStreamBufferReceive(..., 0) > 0)` 收集后统一输出）。把阈值从 64 改成 1 再改成 512，用 `xTaskGetTickCount()` 差值统计唤醒频率：阈值越大唤醒越稀疏、单次搬运量越大——吞吐与时延的旋钮亲手拧一遍。
4. **GDB 验证结构**。`idf.py qemu gdb` 起调试器，`p *(StreamBuffer_t*)s_log_mb`（句柄即结构指针）观察 `xHead`/`xTail` 随收发推进、数据区未写区域保持 0x55 填充——14.2/14.7 的源码陈述在内存里亲眼对上。

---

## 14.9 小结

- 流缓冲 = 环形字节流 + 两个 volatile 游标，`StreamBuffer_t` 里没有链表、没有事件列表，只有两个单席位的等待句柄；一字节永不填满的空位解决满/空歧义，创建时的 `+1` 分配把它对用户隐藏。
- 免锁的根是 **SPSC 所有权划分**：`xHead` 唯一写者改、`xTail` 唯一读者改，数据先搬运、游标后发布；采样端"先读消费游标再读生产游标"把并发读变成至多一次变化。`volatile` 管编译器，强序共享 SRAM 管跨核可见性，`portMEMORY_BARRIER`（默认空、Xtensa 未定义）守护的是别处的调度器变量，不是这里。
- 数据路径全程免锁，锁只出现在"查状态 + 清通知 + 登记等待"的控制路径瞬间——防的是丢失唤醒，不是数据竞争。
- `xStreamBufferSend` 流模式允许部分写（返回实际字节数），消息模式全有全无；`xTriggerLevelBytes` 阈值控制读者唤醒粒度，是吞吐/时延的旋钮；唤醒原语是任务通知（第十三章），这是它比队列轻的原因之一。
- 消息缓冲没有独立实现：`xMessageBufferSend` 是转发宏，封包 = 4 字节 `configMESSAGE_BUFFER_LENGTH_TYPE` 长度头 + 载荷，拆包用链式局部 `xTail`、失败不消费；`xStreamBufferNextMessageLengthBytes()` 可窥视下一条长度。
- Vanilla vs IDF：IDF 给结构加了 per-buffer `portMUX_TYPE xStreamBufferLock`，临界区带锁参数，SMP 下醒来清句柄也要回临界区（任务可能已在另一核上跑）；单核构建时 `prvENTER_CRITICAL_OR_SUSPEND_ALL` 退化为 Vanilla 的 `vTaskSuspendAll()`。数据路径两边都免锁。
- 违反单读单写的后果是静默损坏（空间检查 TOCTOU、句柄覆盖丢唤醒、重复消费）；断言只能抓阻塞路径的违规，工程上用"队列汇聚网关"或"按外设拆缓冲"保住 SPSC 契约。

下一章进入 `timers.c`：软件定时器如何用一个守护任务 + 一条命令队列，把成百上千个定时回调的成本压缩到两个内核对象里——你会看到队列（第十章）与任务通知在这里再次同台，而"定时器命令队列"本身就是一个现成的多写单读队列案例，与本章的汇聚网关模式互为印证：[[ch15-software-timers-daemon|第十五章]]。
