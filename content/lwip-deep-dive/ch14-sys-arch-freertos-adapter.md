---
title: "lwIP 深度解析（十四）：sys_arch：lwIP 与 FreeRTOS 的缝合层"
date: 2026-08-26
description: "lwIP 只认 sys.h 里那几十个原语，ESP-IDF 在 components/lwip/port/freertos/sys_arch.c 用 FreeRTOS 队列/静态信号量/互斥量逐条兑现。逐函数对照映射表与语义坑（超时换算的不对称、protect 是全局互斥量而非关中断）、LWIP_NETCONN_SEM_PER_THREAD=1 省了什么、线程模型全景表、Vanilla contrib 移植与 IDF 自研 port 的分野；实验实测邮箱堵塞传导链：慢消费者把应用 post 拖到 453µs 中位，tcpip 线程背 16ms 慢回调时 socket() 被拖 15ms。"
tags: [lwip, network, esp32, esp-idf, freertos, sysarch, qemu]
---

> [!info] lwIP 深度解析系列 0. [[lwip-deep-dive|系列索引]] 14. **第十四章：sys_arch：lwIP 与 FreeRTOS 的缝合层**

# lwIP 深度解析（十四）：sys_arch：lwIP 与 FreeRTOS 的缝合层

这一章回答三个问题：**"给我邮箱、信号量、互斥量、线程"这句 lwIP 的台词是谁兑现的**（[[ch13-tcpip-thread-mailbox|第十三章]] 里 tcpip_thread 循环里的 `sys_mbox_fetch` 到底落到 FreeRTOS 的哪个函数）、**这套契约最小要实现哪些东西**（一张逐函数映射表全说清）、**缝合层的质量如何决定整个协议栈的性能**（用真实测量回答："税"藏在哪）。读完它，你应该能独立给自己手上的 RTOS 写一份能跑的 sys_arch，并且知道每一行实现的性能代价。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP 2.2.0-dev——契约在 `components/lwip/lwip/src/include/lwip/sys.h`，兑现方在 `components/lwip/port/freertos/sys_arch.c`。

> [!warning] 先纠正一个常见的想当然
> IDF 的 sys_arch 实现文件**不在** `port/esp32xx/` 下（那里只有 VFS socket 集成与 netif 适配），真正的实现是 `port/freertos/sys_arch.c` + `port/freertos/include/arch/sys_arch.h`。`esp32xx/` 目录名很有迷惑性——写文章引用路径前请先 grep。

---

## 14.1 契约解剖：sys.h 抽什么，IDF 拿什么兑现

### 1. 契约的三种形态

`sys.h` 按 `NO_SYS` 分成两个世界：单机无 OS 模式下全部宏直接置空（`typedef u8_t sys_sem_t;` 那一排），OS 模式下则要求移植层交付以下内容：

```c
/* src/include/lwip/sys.h —— 非 NO_SYS 时移植层必须交付的核心面 */
#define SYS_ARCH_TIMEOUT 0xffffffffUL       /* 超时返回值，u32_t 特殊值 */
#define SYS_MBOX_EMPTY   SYS_ARCH_TIMEOUT   /* tryfetch 空箱返回值 */

err_t  sys_mutex_new / ...lock / ...unlock / ...free;
err_t  sys_sem_new(sys_sem_t *sem, u8_t count);      /* count 只有 0/1 */
void   sys_sem_signal(sys_sem_t *sem);
u32_t  sys_arch_sem_wait(sys_sem_t *sem, u32_t timeout); /* ms,0=永久 */
void   sys_mbox_post(sys_mbox_t *mbox, void *msg);    /* 满了必须等，绝不能变相失败；仅任务上下文 */
err_t  sys_mbox_trypost(...); err_t sys_mbox_trypost_fromisr(...);
u32_t  sys_arch_mbox_fetch(sys_mbox_t *mbox, void **msg, u32_t timeout);
u32_t  sys_arch_mbox_tryfetch(sys_mbox_t *mbox, void **msg);
sys_thread_t sys_thread_new(name, fn, arg, stacksize, prio);
void   sys_init(void);  u32_t sys_now(void);  u32_t sys_jiffies(void);
sys_prot_t sys_arch_protect(void);  void sys_arch_unprotect(sys_prot_t);
```

注意类型抽象的松弛度：`sys_sem_t/sys_mutex_t/sys_mbox_t` 可以是任意东西——指针、结构体值、句柄都行，全看 `arch/sys_arch.h` 怎么 typedef。这份自由正是各 port 分化的起点。

### 2. IDF 的类型选择：一把双刃剑的 typedef

```c
/* port/freertos/include/arch/sys_arch.h */
typedef StaticSemaphore_t sys_sem_t;          /* 值内嵌！不是指针 */
typedef SemaphoreHandle_t sys_mutex_t;        /* 动态创建的互斥量句柄 */
typedef TaskHandle_t      sys_thread_t;

typedef struct sys_mbox_s {
  StaticQueue_t os_mbox;                      /* 内嵌静态队列控制块 */
  uint8_t buffer[];                           /* 柔性数组：队列存储区紧随其后 */
} * sys_mbox_t;                               /* mbox 本身是堆上块的地址 */
```

三个 typedef 三种形态：信号量要求调用者提供存储（结构体按值嵌入 pcb/netconn 等 lwIP 对象内部，零额外堆分配）；互斥量走最普通的动态 `SemaphoreHandle_t`；邮箱则是"heap_caps_malloc 一整块 + xQueueCreateStatic 就地成形"。最后一种设计的妙处在 `sys_mbox_new()` 里看得最清楚：

```c
/* port/freertos/sys_arch.c */
err_t sys_mbox_new(sys_mbox_t *mbox, int size)
{
  *mbox = (sys_mbox_t)heap_caps_malloc(
      sizeof(struct sys_mbox_s) + (size * sizeof(void *)),
      ( MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT ));     /* 控制块+槽位一次成型 */
  QueueHandle_t res = xQueueCreateStatic(size, sizeof(void *),
                                         (*mbox)->buffer, &(*mbox)->os_mbox);
  ...
}
```

一次分配同时拿到 `StaticQueue_t` 和消息槽位区，内网可寻址（INTERNAL）保证中断路径也能安全投递。对比上游 contrib 版本两次分配（队列对象 + 数据区），IDF 这版少一次堆操作也少一处碎片来源。

### 3. 全函数映射总表

把 `sys_arch.c` 逐函数对照 FreeRTOS 原语过一遍。右列标注是"直译"（同语义映射）还是"意译"（有取舍/坑）：

| lwIP 契约                      | FreeRTOS 原语                                                            | 形态备注                                         |
| ------------------------------ | ------------------------------------------------------------------------ | ------------------------------------------------ |
| `sys_mbox_new(m, size)`        | `heap_caps_malloc(INTERNAL)` + `xQueueCreateStatic(size, sizeof(void*))` | 直译 + 静态化改造                                |
| `sys_mbox_post(m, msg)`        | `xQueueSendToBack(…, portMAX_DELAY)`                                     | 直译；契约要求"可能阻塞但绝不变相失败"，断言兜底 |
| `sys_mbox_trypost(m, msg)`     | `xQueueSend(…, 0)`                                                       | 直译；满即返 `ERR_MEM`                           |
| `sys_mbox_trypost_fromisr()`   | `xQueueSendFromISR(…,&woken)`                                            | 意译：woken 时返回自定 `ERR_NEED_SCHED`(=123)    |
| `sys_arch_mbox_fetch(m,msg,t)` | `xQueueReceive(…, t/portTICK_PERIOD_MS)`                                 | **意译坑①：超时截断换算**（14.1.4）              |
| `sys_arch_mbox_tryfetch()`     | `xQueueReceive(…, 0)` + `SYS_MBOX_EMPTY` 判定                            | 直译                                             |
| `sys_mbox_free(m)`             | 空箱断言 → `vQueueDelete` → `heap_caps_free`                             | 增加"非空即断言"防御                             |
| `sys_sem_new(s,count)`         | `xSemaphoreCreateBinaryStatic(s)` + count==1 时 give                     | 直译 + 静态化（调用者供内存）                    |
| `sys_sem_signal(s)`            | `xSemaphoreGive(s)`（满也算成功）                                        | 直译；纯信号语义不报队满错                       |
| `sys_arch_sem_wait(s,t)`       | `xSemaphoreTake(…, ticks)`                                               | **意译坑②：向上取整再 +1 tick**                  |
| `sys_mutex_*`                  | `xSemaphoreCreateMutex/Take(portMAX_DELAY)/Give/Delete`                  | 直译；非递归型互斥量                             |
| `sys_thread_new(…)`            | `xTaskCreatePinnedToCore(…, CONFIG_LWIP_TCPIP_TASK_AFFINITY)`            | 意译：多了亲和性注入点                           |
| `sys_now()`                    | `xTaskGetTickCount() * portTICK_PERIOD_MS`                               | **tick 派生，不是 esp_timer**（14.6 实验证明）   |
| `sys_jiffies()`                | `xTaskGetTickCount()`                                                    | 直译；`sys_now` 的原始形态                       |
| `sys_arch_protect()`           | `sys_mutex_lock(&g_lwip_protect_mutex)`                                  | **意译坑③：全局互斥量，不是关中断**（14.3.3）    |
| `sys_msleep(ms)`               | `vTaskDelay(ms / portTICK_PERIOD_MS)`                                    | 直译                                             |

上游 contrib 参考版（`lwip/contrib/ports/freertos/sys_arch.c`，Simon Goldschmidt 维护）做同样的事，但每一行的选择都不同——14.5 节并排对比。

表中唯一需要展开的一针是 `sys_thread_new`——它是 lwIP 语义被 FreeRTOS 参数化最重的一处：

```c
/* port/freertos/sys_arch.c */
sys_thread_t sys_thread_new(const char *name, lwip_thread_fn thread,
                            void *arg, int stacksize, int prio)
{
  /* LwIP's lwip_thread_fn matches FreeRTOS' TaskFunction_t ... */
  ret = xTaskCreatePinnedToCore(thread, name, stacksize, arg, prio,
                                &rtos_task, CONFIG_LWIP_TCPIP_TASK_AFFINITY);
  ...
}
```

两个参数翻译要点：lwIP 的 `stacksize` 契约写明"字节数，可被忽略"，IDF 内核因 `portSTACK_TYPE=uint8_t` 天然按字节收单（见 [[ch16-portmacro-port-contract|FreeRTOS 十六章]] 的类型契约一节）；而 `prio` 在两边都是不透明的 int——它的实际含义由 14.4 的优先级阶梯决定。

### 4. 超时换算的两个不对称

等待函数是整个缝合层语义最密集的地方，把 `sys_arch_mbox_fetch` 全身摊开看：

```c
/* port/freertos/sys_arch.c */
u32_t sys_arch_mbox_fetch(sys_mbox_t *mbox, void **msg, u32_t timeout)
{
  void *msg_dummy;
  if (msg == NULL) { msg = &msg_dummy; }        /* 契约允许丢消息式取用 */

  if (timeout == 0) {                           /* lwIP 约定：0 = 永久等待 */
    ret = xQueueReceive((QueueHandle_t)&(*mbox)->os_mbox, &(*msg), portMAX_DELAY);
    LWIP_ASSERT("mbox fetch failed", ret == pdTRUE);
  } else {
    TickType_t timeout_ticks = timeout / portTICK_PERIOD_MS;
    ret = xQueueReceive((QueueHandle_t)&(*mbox)->os_mbox, &(*msg), timeout_ticks);
    if (ret == errQUEUE_EMPTY) {
      *msg = NULL;
      return SYS_ARCH_TIMEOUT;                  /* 魔法值：超时 */
    }
  }
  return 0;                                     /* 成功：非超时即合法 */
}
```

同一个文件里，信号量一侧对"毫秒 → tick"的态度却更严：

```c
/* sys_arch_mbox_fetch：向零取整（截断） */
TickType_t timeout_ticks = timeout / portTICK_PERIOD_MS;

/* sys_arch_sem_wait：向上取整之后再 +1，注释原文：
 * "we also need to add 1. Indeed, this function shall wait for AT LEAST
 *  timeout, but on FreeRTOS, if we specify a timeout of 1 tick ... it will
 *  take AT MOST 1 tick." */
TickType_t timeout_ticks = ((timeout + portTICK_PERIOD_MS - 1)
                            / portTICK_PERIOD_MS) + 1;
```

后果值得咀嚼一下：请求等 15ms、tick=10ms 时，邮箱版本等 1 tick（实际最多 ~10ms，**可能提前醒来**）；信号量版本等 3 tick（30ms，只多不少）。两个换算都不算错——API 语义都写着 "at least"——但同一份代码里两种策略并存，移植别人代码或精确计时时要心里有数。上游 contrib 两处都用截断式，IDF 把信号量一侧加严了。

> [!tip] `SYS_ARCH_TIMEOUT` 是魔法值的集合
> 返回 `0` 表示"没等到就拿到了，等了 0ms"也是合法成功返回；只有 `0xffffffffUL` 特指超时。这就是为什么所有正常路径统统 `return 0` 或 `return 1` 都能编过跑通——老版本 lwIP 曾要求返回等待时长，现在只区分"超时/非超时"。看到第三方 port 里 return 值五花八门不必惊讶。

---

## 14.2 缝合层的另一半：LWIP_MARK_TCPIP_THREAD 与 sys_init 干的事

契约不止那批带 `sys_` 前缀的函数。tcpip 线程启动瞬间要执行的 `LWIP_MARK_TCPIP_THREAD()`，在 IDF 的 lwipopts.h 里被接到自家扩展接口：

```c
/* port/include/lwipopts.h:65 */
#define LWIP_MARK_TCPIP_THREAD()  sys_thread_tcpip(LWIP_CORE_MARK_TCPIP_TASK)

/* sys_arch.c 尾部：一个五态小状态机，服务 core-locking 断言与初始化探测 */
bool sys_thread_tcpip(sys_thread_core_lock_t type) {
  case LWIP_CORE_IS_TCPIP_INITIALIZED:  return lwip_task != NULL;
  case LWIP_CORE_MARK_TCPIP_TASK:       lwip_task = xTaskGetCurrentTaskHandle(); ...
}
```

这是纯 IDF 扩展：`LWIP_MARK_TCPIP_THREAD()` 与 `LWIP_ASSERT_CORE_LOCKED()`（lwipopts.h 54/61/65 行）双双接到这个查询接口——core-locking 开启时报"没拿锁就动核心"，关闭时（IDF 默认）报"不在 tcpip 上下文"。ch3 提到过的"socket 创建早于 esp_netif_init 会 assert 崩复位"，断言的真身就是这里记录的 `lwip_task` 是否为空；上游 contrib 对应物是 `sys_mark_tcpip_thread()/sys_check_core_locking()`，签名与检查强度都不同。

`sys_init()` 的三件事也全是 IDF 特色：建 protect 全局互斥量、`pthread_key_create` 注册线程局部信号量的析构钩子、注册 `esp_vfs_lwip_sockets_register()` 把 socket 层挂进 VFS——第三件事已经属于 ch16 的领地了。

### FromISR 一条线：ERR_NEED_SCHED=123 的旅行路线

lwIP 契约里中断上下文只能走 trypost/tryfetch 的 `_fromisr` 变体，而 FreeRTOS 的 ISR 又不能直接调度——于是 IDF port 设计了一个返回码协议：`sys_mbox_trypost_fromisr()` 在 `xHigherPriorityTaskWoken==pdTRUE` 时向调用者交回自定义值 `ERR_NEED_SCHED`（arch 头文件里 `#define ERR_NEED_SCHED 123`），意思是"更高优先级的任务已被我弄醒，请求调度是你调用者的责任"。同族还有 `sys_sem_signal_isr()`。上游 contrib 定义了完全相同的宏值——这是两侧 port 少数逐字一致的地方。

仓库里能找到的真实消费方是 `port/esp32xx/vfs_lwip.c`：VFS 层的 select/epoll 唤醒在 ISR 允许路径上借 `sys_sem_signal_isr()` 叫醒等待线程，并根据它的布尔返回决定要不要置 woken 标志回传上层。换句话说，**123 这个数字是写给"写驱动和移植层的人"的接口，而不是给应用开发者的**——你在协议栈外的 ISR 里若借 lwIP 邮箱发消息，收到它就该补一个 `portYIELD_FROM_ISR()`。

---

## 14.3 性能关键细节：三条通道的开销模型

### 1. 一次 `sys_mbox_post` 到底花了什么

对照 [[ch10-queue-universal-ipc|FreeRTOS 第十章]] 的队列开销模型，IDF 邮箱的一次 post =

1. 解两级指针：`(*mbox)->os_mbox`（mbox 是堆块地址，先解引用堆块再定位内嵌队列）；
2. `xQueueSendToBack` 临界区内拷贝 4 字节指针入队；
3. 若 tcpip 任务在等：事件链表摘除 + 就绪链表插入 + yield 判定（一次调度点）。

常态是零唤醒成本的：空闲时 tcpip 线程就睡在邮箱的事件链表上，post 即叫醒；第 3 步的调度成本只在"接收方确实在睡"时发生，包峰期才高频兑现。14.6 的 C 组实验会给这组模型填上真实数字。

### 2. LWIP_NETCONN_SEM_PER_THREAD=1：每个任务自带回执信号量

netconn/socket API 的同步模式是：应用任务把 api_msg 投进 tcpip 邮箱，然后睡在"操作完成信号量"上等回执。没有优化时这个信号量每次调用都要新建+删除（见 `tcpip_api_call()` 无此选项的分支：`sys_sem_new` … `sys_sem_free` 成对出现在热路径）。开关打开后换成复用线程局部存储：

```
opt.h:1985  LWIP_NETCONN_SEM_PER_THREAD==1: Use one (thread-local) semaphore per
            thread instead of allocating one semaphore per netconn
lwipopts.h:1719 (IDF=1):
  #define LWIP_NETCONN_THREAD_SEM_GET()   sys_thread_sem_get()
  #define LWIP_NETCONN_THREAD_SEM_ALLOC() sys_thread_sem_init()
  #define LWIP_NETCONN_THREAD_SEM_FREE()  sys_thread_sem_deinit()
```

IDF 的托底实现在 `sys_arch.c` 底部：`pthread_key_create(&sys_thread_sem_key, sys_thread_sem_free)` 注册 TLS 槽位，首次 `sys_thread_sem_get()` 时 `heap_caps_malloc(sizeof(StaticSemaphore_t))` 并挂进 pthread specific，线程退出由析构钩子回收。省下的账很直观：**每次 api_msg 往返少一对 create/delete**，代价是每个真实用过 socket 的任务多一块约 sizeof(StaticSemaphore_t) 的内网堆 + 一个 TLS 槽位。这也顺带解释了 Batch 2 事实中"netconn 接收邮箱深度 CONFIG_LWIP_TCP_RECVMBOX_SIZE=6"的另一面——接收靠 recvmbox，回执靠 TLS 信号量，两条通道分工明确。

> [!note] 与上游的关系
> 这个优化本身是上游特性（opt.h 注释与 api_lib.c 里的分支都是 vanilla 代码）。区别在于挂钩方式：上游 contrib 用 FreeRTOS 原生 TLS（`pvTaskGetThreadLocalStoragePointer(task,0)`，要求 `configNUM_THREAD_LOCAL_STORAGE_POINTERS>0`），IDF 改走 newlib/pthreads 的 `pthread_setspecific`——因为 IDF 经典内核树默认 TLS 槽位数为 0，pthreads 是 IDF 用户更常用的 TLS 出入口。

### 3. SYS_ARCH_PROTECT 的真身：全局互斥量，不是关中断

`mem.c/memp.c` 的池操作被 `SYS_ARCH_PROTECT(old_level)` 包着保护。IDF 的实现全身不过十行：

```c
/* port/freertos/sys_arch.c */
static sys_mutex_t g_lwip_protect_mutex = NULL;

sys_prot_t sys_arch_protect(void)
{
  if (unlikely(!g_lwip_protect_mutex)) {
    sys_mutex_new(&g_lwip_protect_mutex);     /* 惰性初始化兜底 */
  }
  sys_mutex_lock(&g_lwip_protect_mutex);      /* ← 全系统唯一的池串行点 */
  return (sys_prot_t) 1;                      /* 恒 1：没有嵌套计数 */
}
void sys_arch_unprotect(sys_prot_t pval)
{
  LWIP_UNUSED_ARG(pval);
  sys_mutex_unlock(&g_lwip_protect_mutex);
}
```

三方机制对照：

| 维度     | 上游 contrib 默认                          | 上游可选（USES_MUTEX=1）             | **IDF 实现**                                                 |
| -------- | ------------------------------------------ | ------------------------------------ | ------------------------------------------------------------ |
| 实现机制 | `taskENTER_CRITICAL()`（关调度器级临界区） | `xSemaphoreTakeRecursive` 递归互斥量 | `sys_mutex_lock(&g_lwip_protect_mutex)` **非递归**普通互斥量 |
| 返回值   | 恒 1（无嵌套计数）                         | 可选 sanity check 计数               | 恒 1                                                         |
| 双核含义 | 单核假设，SMP 直接失效                     | 两核互斥，允许同任务重入             | 两核互斥，**禁止同任务重入**                                 |

这份表格解释了前面章节反复出现的现象：为什么相关路径永远不会并发跑飞——全系统任何时刻只有一个任务能在 memp 保护区内。但有两笔账要并排读：

> [!warning] 契约要求可嵌套，IDF 实现字面上做不到
> sys.h 对 SYS_ARCH_PROTECT 的原文注释写着 "The implementation should allow calling SYS_ARCH_PROTECT when already protected"（已受保护时再 PROTECT 也必须安全）。IDF 用的是**非递归**普通互斥量 + 恒返 1：同一任务若真的嵌套进入保护区，第二次 take 会当场死锁自己。它能岁月静好，依赖的是"core 路径从不嵌套进保护区"这条事实约定（memp/mem 各自独立保护，保护区内部不再调用其他带保护区的函数）。读第三方 port 时同样值得先确认这条隐性假设在不在。
>
> 另一笔账是核间串行点：谁持着这把互斥量，另一颗核上的所有 pbuf 分配就得在门外等。它锁的是分配器元数据一致性而非数据通路，通常不是瓶颈；但如果哪天有人在 tcpip 回调里做长时间内存操作，另一个核上的 malloc 正在门外转圈就是对症的解释。

顺带的观测性差异也记录在案：上游 contrib 版在每个失败点都埋着 `SYS_STATS_INC(sem.err)`/`SYS_STATS_INC(mbox.err)` 计数钩子，IDF port 把这些全部剥掉了——本章排障靠 `stats_display()` 输出（见 Batch 1 事实：无 MEM/MEMP 段）之外的实测手段，就是这个原因的直接后果。

---

## 14.4 线程模型汇总表：谁的优先级压着谁

把实验 D 快照（14.6 真实输出）与 Kconfig/驱动默认值拼成全景：

| 任务              | 优先级                                  | 栈 (B)                            | 亲和性                                                | 来源与角色                                                                                                                     |
| ----------------- | --------------------------------------- | --------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| ipc0 / ipc1       | 24                                      | —                                 | 各钉一核                                              | SMP 内部核间信使（几乎不可见）                                                                                                 |
| esp_timer         | 22                                      | CONFIG_ESP_TIMER_TASK_STACK_SIZE  | any                                                   | 高精度定时分发（lwIP 不直接依赖，见 14.6 实验 B）                                                                              |
| sys_evt           | 20                                      | Kconfig 默认 2304+512             | any                                                   | 默认事件循环，GOT_IP 从这里广播                                                                                                |
| **tcpip**         | **CONFIG_LWIP_TCPIP_TASK_PRIO 默认 18** | 3072+512=3584（Kconfig 891 行起） | `CONFIG_LWIP_TCPIP_TASK_AFFINITY` 默认 no-affinity    | **协议栈本体**，由 `sys_thread_new(TCPIP_THREAD_NAME…)` 创建，邮箱深 TCPIP_MBOX_SIZE=`CONFIG_LWIP_TCPIP_RECVMBOX_SIZE` 默认 32 |
| emac_rx           | ETH_MAC_DEFAULT_CONFIG 固定 15          | 4096                              | no-affinity（设 `ETH_MAC_FLAG_PIN_TO_CORE` 才钉当核） | openeth/WiFi 无关；以太网 RX 泵，ISR→任务经驱动自有机制                                                                        |
| bench14 / probe14 | 10 / 21                                 | 自定义                            | 钉核 0 / 核 1                                         | 本章实验任务                                                                                                                   |
| echo_srv          | 5                                       | 4096                              | 钉核 1                                                | 应用任务代表                                                                                                                   |
| IDLE0/1           | 0                                       | —                                 | 各一核                                                | 挨饿监测归 Task WDT 管                                                                                                         |

三条优先级铁律从表中浮出：

1. **tcpip(18) > 应用常规任务(≤17)**：协议栈永远能抢过业务逻辑，保证 RTO/ACK 及时性——这就是 [[ch13-tcpip-thread-mailbox|第十三章]] "单线程心脏"不被饿死的制度保障。
2. **驱动 RX(15) < tcpip(18)**：openeth 收到帧后并不直接进栈，而是排队交给 tcpip 处理；若 RX 反而更高，洪峰会淹死协议处理。
3. **WiFi 矩阵需真机**：本环境 QEMU 没有 esp-wifi-mac，只能给方向——WiFi 任务的核亲和由 `ESP_WIFI_TASK_CORE_ID`（默认核 0）配置，优先级绑死在闭源 blob 里（常见资料口径 23，Kconfig 不暴露），本章不给实测值。

> [!tip] 亲和性旋钮与"缝合层"的关系
> `CONFIG_LWIP_TCPIP_TASK_AFFINITY` 之所以放在 lwIP 组件的 Kconfig 而不是 FreeRTOS 的，是因为 sys_thread_new 里的那次 `xTaskCreatePinnedToCore` 就是缝纫机的针脚——lwIP 的"线程优先级/亲和性"语义完全由 port 层的这一针决定。改它不需要碰 lwIP 源码。

---

## 14.5 Vanilla contrib port vs ESP-IDF port：一份契约的两份答卷

上游 lwIP 仓库带了 FreeRTOS 参考移植（本仓库路径 `lwip/contrib/ports/freertos/`）。把它和 IDF port 并排放，差异一目了然：

| 维度                  | 上游 contrib（freertos port）                                                | IDF port                                                                                                                                         |
| --------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 类型包裹              | wrapper struct 包 void*（`struct \_sys_sem { void *sem; }`，一点点类型安全） | 直接用 FreeRTOS 原生类型别名（`StaticSemaphore_t` 值内嵌等）                                                                                     |
| 对象分配              | 全动态 `xQueueCreate/xSemaphoreCreateBinary`                                 | 邮箱/信号量静态化（`heap_caps_malloc`+`CreateStatic`）                                                                                           |
| 内存上舱              | 接口未管内存能力                                                             | `MALLOC_CAP_INTERNAL` 强制内网                                                                                                                   |
| SYS_ARCH_PROTECT      | 默认 `taskENTER_CRITICAL`（关调度），可选 mutex 版（可递归）                 | 固定 mutex 版（不可递归），返回恒 1                                                                                                              |
| sys_now 开关          | `LWIP_FREERTOS_SYS_NOW_FROM_FREERTOS` 可换硬件时基                           | 写死 tick 公式                                                                                                                                   |
| 信号量等待返回        | 成功返回 1                                                                   | 成功返回 0（旧语义宽容）                                                                                                                         |
| 互斥量类型            | 递归互斥量 `xSemaphoreCreateRecursiveMutex`                                  | 非递归 `xSemaphoreCreateMutex`                                                                                                                   |
| sys_thread_new 栈单位 | `stacksize / sizeof(StackType_t)`（lwIP 字节数→FreeRTOS 字，或有字数开关）   | 字节数直传（IDF 内核 `portSTACK_TYPE=uint8_t`，参见 [[2026-08-26-freertos-deep-dive-ch16-portmacro-port-contract\|FreeRTOS 十六章]] 的类型契约） |
| 任务创建              | `xTaskCreate`（不控核）                                                      | `xTaskCreatePinnedToCore`+Kconfig 亲和性                                                                                                         |
| 核锁定检查            | `LWIP_FREERTOS_CHECK_CORE_LOCKING` 可选块                                    | `sys_thread_tcpip()` 五态查询 + VFS 注册塞进 `sys_init`                                                                                          |
| 附加件                | 无                                                                           | per-thread netdb/信号量（TLS）、`ERR_NEED_SCHED` 双侧贯通                                                                                        |

> [!warning] IDF 还动了协议栈的心脏旁边
> 别忘了系列暗线 B：IDF 不只在 port 层替换实现，还往 lwIP core 里打了自己的补丁。对本章最相关的是"按需定时器"——`timeouts.c` 里一圈 `ESP_LWIP_XXX_TIMERS_ONDEMAND` 条件编译：

```c
/* src/core/timeouts.c */
#if IP_REASSEMBLY && !ESP_LWIP_IP4_REASSEMBLY_TIMERS_ONDEMAND
  /* 上游行为：sys_check_timeouts 轮询多个常驻定时器 */
#endif /* IP_REASSEMBLY && !ESP_LWIP_IP4_REASSEMBLY_TIMERS_ONDEMAND */
... DHCP / IGMP / DNS / MLD6 同款条目
```

```c
/* port/include/lwipopts.h:1630 起，IDF 全部置 1 */
#define ESP_LWIP_IGMP_TIMERS_ONDEMAND        1
#define ESP_LWIP_MLD6_TIMERS_ONDEMAND        1
#define ESP_LWIP_DHCP_FINE_TIMERS_ONDEMAND   1
#define ESP_LWIP_DNS_TIMERS_ONDEMAND         1
#define ESP_LWIP_IP4_REASSEMBLY_TIMERS_ONDEMAND 1
#define ESP_LWIP_IP6_REASSEMBLY_TIMERS_ONDEMAND 1
```

效果：没用到的子系统不再向 tcpip 线程的定时器链挂周期回调，空闲协议栈的邮箱流量更低。这属于"对心跳模型的瘦身"，与 [[ch15-software-timers-daemon|FreeRTOS 第十五章]] 的软件定时器哲学异曲同工：没人订报纸就不印报。

---

## 14.6 实验：给缝合层标定

实验工程：`practice/lwip-ch14-sys-arch-freertos-adapter/`（基于 ch3 openeth bring-up 模板，hostfwd 端口 8016）。构建运行照抄公约第 3 节，仅 `-nic` 加 hostfwd：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch14-sys-arch-freertos-adapter
idf.py build
idf.py qemu monitor < /dev/null || true        # 仅为了生成 qemu_flash.bin/qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 90 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8016-:8888 -nographic -no-reboot 2>&1 | tee run.log
```

环境说明：ESP32（160MHz 虚拟主频）/ QEMU SLIRP 网络 / DHCP 到手 10.0.2.15 后开始测量。以下摘录全部来自实际 `run.log`。

### 1. 实验 A：四种 IPC 原语的自往返成本

方法：同一任务内 post→tryfetch（邮箱，lwIP 语义）、give→take(0)（信号量）、`xTaskNotify(eIncrement)`→`ulTaskNotifyTake`（通知）各自循环 10000 次，裸 FreeRTOS 队列用相同参数（深度 32、项宽 4B）对照组；每轮以 `esp_timer_get_time()` 包边，500 次一批、批间 `vTaskDelay(1)` 喂调度器，报告 min/median/P95/max。

```text
--- experiment A: primitive round-trip cost (10000 iters) ---
[bench] lwip_sys_mbox_RTT    n=10000 min=3 us median=4 us P95=4 us max=97 us
[bench] raw_xQueue_RTT       n=10000 min=2 us median=3 us P95=4 us max=76 us
[bench] lwip_sys_sem_RTT     n=10000 min=5 us median=8 us P95=9 us max=262 us
[bench] task_notify_RTT      n=10000 min=2 us median=3 us P95=8 us max=589 us
```

解读，也是本章关于"缝合层税"的第一个结论：

- **直译壳本身测不出显著税**。四条路径的往返全部落在个位数微秒；而且跨多次完整复跑（本文先后跑了 4 次），mbox 与 raw queue 的中位数在 2~7µs 间互相翻转（例：另一次复跑 mbox=3µs / queue=6µs）。IDF 的邮箱就是 `StaticQueue_t` 的转发壳，信号量就是 binary semaphore 本尊——薄到与 QEMU 的计时噪声同数量级。
- 数量级感仍有价值：缝合层裸壳自往返 ≈ 2~8µs（本次测量），C2 又给出穿过完整调用链的稳态单价 ≈ 37µs。按本系列实测的 SLIRP 吞吐天花板 ~120 Mbit 折算 MTU 流约 1 万 pps：若每包都摊一次完整 api 往返，光这一层就要吞掉三成 CPU 预算。绝对值在 QEMU 上偏悲观、真机会好不少（[[ch16-socket-netconn-vfs|第十六章]] 的三层 API 对比里还会再算一遍这笔账），但"高频路径要绕开收票员"的方向由此定了调——这正是下一章 Raw API 的立足点。
- 对照 [[ch13-task-notifications|FreeRTOS 第十三章]] ping-pong 实验（当时通知比信号量快 30~45%）：这里两者几乎重合——因为本次测的是**不产生上下文切换的自往返**，ch13 测的是**强制切换的手递手**。两种测量分别照亮原语的两半成本：簿记成本与切换成本。

### 2. 实验 B：sys_now 的时基到底是谁

大纲原以为要验证"IDF 的 sys_now 映射 esp_timer"，grep 源码当场证伪：

```c
/* port/freertos/sys_arch.c */
u32_t sys_now(void)    { return xTaskGetTickCount() * portTICK_PERIOD_MS; }
u32_t sys_jiffies(void){ return xTaskGetTickCount(); }
```

它只是 FreeRTOS tick 计数的毫秒换算。实验于是改成验证这一事实。方法：每 7ms 采样一对 `(sys_now(), esp_timer_get_time())` 共 200 对画偏移分布；再用刻意跨 tick 网格的睡眠看步进序列。核心代码不过十几行：

```c
/* 实验 B 核心（完整版见工程 exp_b_sysnow()） */
for (int i = 0; i < 200; i++) {
    u32_t s0 = sys_now();
    int64_t e0 = esp_timer_get_time();
    offset_ms[i] = e0 / 1000 - (int64_t)s0;   /* µs 转 ms 后作差 */
    vTaskDelay(pdMS_TO_TICKS(7));             /* 7ms → 0 tick：睡一轮只 yield */
}
/* 步进序列：故意请求非整数倍 tick 的 27ms（内核截成 2 tick） */
vTaskDelay(pdMS_TO_TICKS(27));
printf(" %lu", (unsigned long)(sys_now() - prev));
```

输出：

```text
[clock] portTICK_PERIOD_MS=10  configTICK_RATE_HZ=100
[clock] offset(esp_timer_ms - sys_now), first 20: 53 53 53 53 53 53 53 53 53 53 53 53 53 53 53 53 53 53 53 53
[clock] offset stats over 200 samples: mean=53.53 ms min=53 ms max=54 ms span=1 ms
[clock] consecutive sys_now deltas (sleep 27ms->2 ticks x12): 20 20 20 20 20 20 20 20 20 20 20 20 (ms)  <- 只能落在 10ms tick 网格上
```

三行输出三份证据：偏移恒定于 ±1ms 内（两只钟走速一致，常数差只是采样起点差）；步进严格落在 10ms 网格（27ms 请求变 20ms 读数，既暴露 `vTaskDelay` 的 tick 截断又暴露 sys_now 的 tick 派生）；结合源码公式闭环。推论各有用处——TCP 时间戳、RTO 退避这些 sys_now 用户的精度上限就是 **CONFIG_FREERTOS_HZ（此处 100Hz→10ms）**；而 sub-ms 时序观察必须绕开 sys_now 直接用 esp_timer（配合 ICOUNT 校准，或干脆上 [[ch23-debugging-toolbox|第二十三章]] 的工具箱）。

### 3. 实验 C1：故障注入——邮箱堵塞如何传导回生产者

设计一个最小传导模型：自建深度 32 的 `sys_mbox`；消费者任务固定 400µs"处理一条"（模拟 tcpip 线程的单条耗时）；生产者连发 64 条并逐条计 `sys_mbox_post` 耗时。两侧核心代码（完整见工程 `exp_c1_own_mailbox()`）：

```c
/* 消费者：每取一条消息，花固定的 400µs “处理” */
while (s_cong_run || 队列未清空) {
    if (sys_arch_mbox_tryfetch(&s_cong_mbox, &msg) != SYS_MBOX_EMPTY)
        esp_rom_delay_us(CONG_DRAIN_US);          /* 模拟 tcpip 忙一段 */
    else
        vTaskDelay(1);
}
/* 生产者（bench 任务内）：第 i 条 post 的全程计时 */
int64_t t0 = esp_timer_get_time();
sys_mbox_post(&s_cong_mbox, (void *)&s_cong_mbox);
cong_dt[i] = esp_timer_get_time() - t0;
```

结果（节选关键相位）：

```text
--- experiment C1: own-mailbox congestion (depth=32, drain=400 us) ---
[bench] post_free_slots      n=   32 min=2 us median=3 us P95=9 us max=19 us
[cong ]   32:144 33:594 34:450 35:448 36:474 37:473 38:453 39:445 40:443 41:444 42:476 43:452 44:446 45:442 46:443 47:446
[cong ]   48:526 49:460 50:455 51:519 52:508 53:498 54:477 55:444 56:445 57:449 58:486 59:478 60:453 61:473 62:467 63:444
[bench] post_congested       n=   32 min=144 us median=453 us P95=526 us max=594 us
[cong ] posts#32..63 blocked(>50us): 32/32 avg-blocked=457 us
```

教科书级的传导曲线：前 32 条（还有免费槽位）全部 2~19µs；**恰好第 33 条起撞墙**（144µs 是第一次撞上半开窗口的部分等待），之后每一条 post 的阻塞时长都收敛到消费节奏附近——中位 453µs ≈ 消费者的 400µs 处理耗时 + 调度与唤醒抖动，32/32 全部发生阻塞。消费者慢多少，生产者就被拖多少，一一对应。

> [!important] 这条曲线就是"API 卡顿追凶"的形状模板
> 当你在线上发现某 socket 调用偶发卡数百微秒且分布严重收敛（不是一个长尾而是整齐的一簇），排查方向就应该顺着"邮箱深度→消费者单条耗时"这条链去找：who is draining too slow? 对号入座：tcpip 线程里是否有慢回调（下一阶段演示）、recvmbox 是否被慢 readers 拖住。

### 4. 实验 C2：真实 tcpip 邮箱的三段压力测试

对系统邮箱下手分三段（细节看工程 `exp_c2_tcpip_mbox`）：先 `vTaskSuspend` 把 tcpip 线程冻住，然后用 `tcpip_try_callback()`（trypost 语义）连续投递直到失败，量出实际容量与失败成本；恢复后再投 24 个阻塞回调看"插队等待"；最后钉高优先级探针任务（21 > tcpip 18，钉核 1，避免被 NO_AFFINITY 的慢回调自旋饿住——首批实验的真实教训，详见工程注释）压入 8×2000µs 慢回调再计时创建 socket：

```text
[tcpip] config: TCPIP_MBOX_SIZE=32 slots, MEMP_NUM_TCPIP_MSG_API=8 tickets
[tcpip] tcpip thread left NO_AFFINITY(prio 18); probe will outrun it
[tcpip] freezing tcpip thread (vTaskSuspend 0x3ffaff44)
[tcpip] froze->filled 32 msgs until ERR_MEM; the failing try took 43 us (immediate)
[tcpip] 24 blocking callbacks right after resume: 70 15 635 42 40 39 37 36 37 37 38 38 37 37 38 38 37 36 38 36 38 39 39 39 (us)
[sock ] calm baseline: 0.86 0.53 0.49 1.01 ms  <- socket() create cost, idle stack
[gate ] 8 x 2000 us queued in 1047 us (posting itself stays cheap)
[sock ] slow phase (8 x 2000 us queued): 15.04 0.75 0.60 0.62 ms  window=18.09 ms <- drained through the congested stack
[gate ] slow-callback executions observed=8
```

三段各有一条硬结论：

1. **容量实测 32 = 邮箱槽位数压倒一切**。消息票池 `MEMP_NUM_TCPIP_MSG_API` 名义上只有 8 张票，冻结期间却填进了整整 32 条才 ERR_MEM——说明在 IDF 全堆化模式（`MEMP_MEM_MALLOC=1`）下，这类的显式计数闸门并未随堆化迁移保留（系列 Batch 2 已实测计数闸只剩 `MEMP_TCP_PCB` 一类独享），**真正的封顶就是 `TCPIP_MBOX_SIZE` 那 32 个槽位**。失败的 trypost 仅花 43µs 即刻返回，绝不阻塞——trypost 族是"溢出快速失败"，post 族才是"溢出长等"。
2. **恢复后的稳态回调税 ≈ 37µs**：积压排干后每个阻塞回调（含 memp 取票+入队+回执）稳定在 37±3µs，个别抖动到 635µs——比实验 A 的裸往返贵一个数量级，这部分才是穿过完整调用链的真实单价。
3. **端到端传导闭合**：平静期 `socket()` 创建 0.1~1ms；tcpip 线程背上 8×2ms 慢回调后，**第一个 socket() 被拖 15.04ms**（≈ 积压工作量 16ms 减去投递期已消化部分），第二条之后的骤降则显示积压正被逐条收割——生产者结结实实付掉了消费者的时间账单。写作侧注记：首版实现把探针留在低优先级，NO_AFFINITY 的 tcpip 抢占探针 CPU 导致"看起来没人被阻塞"，这个教训本身就是关于线程模型表格重要性的最好教材。

### 5. 实验 D：bring-up 后的任务清单（快照）

```text
[tasks] snapshot(after-bringup): 10 tasks
[tasks] NAME         PRIO STATE        HWM
[tasks] bench14        10 Running     7708
[tasks] IDLE1           0 Ready       1088
[tasks] IDLE0           0 Ready       1092
[tasks] tcpip          18 Blocked     2332
[tasks] esp_timer      22 Suspended   3644
[tasks] ipc1           24 Suspended    572
[tasks] echo_srv        5 Blocked     2848
[tasks] emac_rx        15 Suspended   3332
[tasks] sys_evt        20 Blocked     1668
[tasks] ipc0           24 Suspended    564
```

两处状态值得玩味：**tcpip=Blocked** 正是它睡在自己邮箱事件链表上的形态（第十三章的主循环）；**emac_rx=Suspended** 而非 Blocked——同为"等一帧"，openeth 驱动选择的停车姿势不同：驱动作者可以选 vTaskSuspend 自挂起等事件，也可以选队列阻塞，sys_arch 管不着驱动的偏好。HWM 一列顺手给出栈的保险余量：tcpip 最险时刻仍剩 2.3KB（总栈 3584B），echo_srv 剩 2.8KB，都离爆线很远但印证了 14.4 表格的来源参数。

主机侧可用 nc 打 hostfwd 验证 echo（约定端口 8000+14=8016 → guest 8888）：

```bash
printf 'hello ch14' | timeout 5 nc 127.0.0.1 8016
```

---

## 14.7 小结

- sys_arch 契约的本质是一张函数清单 + 四个类型别名，全部写在 `src/include/lwip/sys.h`；IDF 的答卷在 `port/freertos/sys_arch.c`（注意不在 esp32xx/）。邮箱=静态化 FreeRTOS 队列、信号量=值内嵌 BinarySemaphore、互斥量=原生 Mutex、线程=xTaskCreatePinnedToCore 带 Kconfig 亲和性、protect=全局非递归互斥量、sys_now=tick 毫秒换算。
- 语义坑集中在超时换算的不对称（fetch 截断 vs sem 向上取整+1）、`SYS_ARCH_TIMEOUT=0xffffffffUL` 魔法值、try 系返回码（含 ISR 的 `ERR_NEED_SCHED=123`）。写移植层之前先把这三个坑划重点。
- 性能拆解三层：直译壳本身近乎免费（实验 A 的个位微秒自往返、跨次翻转说明低于噪声底）；每个 socket 调用的稳态系统路径单价约 37µs（C2 稳态段）；真正的大额开销是**排队等待**——消费者单条耗时直接转嫁为生产者 post 阻塞时长（C1：400µs 消费节奏 ⇒ 453µs 中位阻塞；32/32 撞墙从第 33 条开始），以及 tcpip 线程被慢回调占用时的端到端拉伸（C2：socket() 0.5ms→15ms）。
- LWIP_NETCONN_SEM_PER_THREAD=1 让每个任务通过 pthread TLS 复用一个回执信号量，砍掉热路径上成对的 sem new/free；protect 的全局互斥量则是全栈内存管理的唯一串行点——双核不可能并行进入 memp 保护区。
- Vanilla contrib port 与 IDF port 是同一张考卷的两份答案：前者包装 struct 保类型安全、全动态分配、protect 默认关临界区、互斥量可递归；后者贴合 ESP32 工程习惯——静态化、内网上舱、Kconfig 化线程参数、VFS/per-thread 扩展塞进 sys_init，并向 core 打入了 ONDEMAND 定时器瘦身补丁。
- 时基结论可外推：凡 sys_now 用户（TCP 时间戳、RTO 补偿计时）精度天花板 = CONFIG_FREERTOS_HZ；测更细的要用 esp_timer 而非 sys_now。

下一步把镜头拉回应用视角：既然 app 任务每一次 socket 操作都要付一次"投递+回执"的过路费，有没有一条**完全绕开缝合层**的路？有——Raw API 把你的回调直接搬进 tcpip 线程上下文执行，你写的代码从此睡在协议栈心脏里。见 [[ch15-raw-api-callbacks|第十五章：Raw API 与回调世界]]。
