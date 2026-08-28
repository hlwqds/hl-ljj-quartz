---
title: "lwIP 深度解析（五）：内存管理：内存池、堆与耗尽实验"
date: 2026-08-26
description: "上游 lwIP 的 memp 定长池 + mem.c 定制堆双体系源码走读；MEM_LIBC_MALLOC/MEMP_MEM_MALLOC 开关组合的'内存来源决策表'；ESP-IDF 全堆化（两开关全开）换来了什么、付出了什么，以及那只补丁出来的 TCP_PCB 计数器；静态账+动态账的内存预算公式；QEMU 上真实触发的三种故障注入：PCB 耗尽的静默拒绝、堆耗尽的驱动层丢帧传播链、free 复原而 largest 缩水的碎片疤痕。"
tags: [lwip, network, esp32, esp-idf, qemu, memory-management]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 5. **第五章：内存管理：内存池、堆与耗尽实验**

# lwIP 深度解析（五）：内存管理：内存池、堆与耗尽实验

这一章回答三个问题：**lwIP 上游为什么同时设计了"静态内存池 + 定制堆"两套内存系统**、**ESP-IDF 为什么把这两套全部换成 libc 堆、代价是什么**、**嵌入式网络应用的内存预算该怎么做、耗尽时协议栈会以什么姿势倒下**。读完它，你应当能对着任意一份 `lwipopts.h`/Kconfig 心算出"这台设备的网络栈最多吃多少内存、先死在哪一环"。

本章的实验照例在 QEMU 上完成：给 echo server 并发灌 6 路连接看 PCB 耗尽，把 libc 堆吃到只剩 3836 字节看驱动丢帧，再用五步探针看清 free 与 largest 的分叉。所有运行输出均来自真实抓取的串口日志。

源码参照版本：ESP-IDF **v6.0.2** 捆绑的 lwIP **2.2.0-dev**（`~/esp/esp-idf/components/lwip/lwip/src`）。内核堆那边的前置知识在 FreeRTOS 系列 [[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison|第十九章]]——那章讲的是"RTOS 内核对象的堆"，这一章讲的是"协议栈的内存"，两篇合起来是嵌入式内存预算的完整拼图。

---

## 5.1 上游为什么要有两套内存系统

打开 `src/core/` 会看到两个并立的分配器：`mem.c` 和 `memp.c`。它们不是历史包袱，而是对两类需求的不同回答：

|              | memp（`memp.c`）                                          | mem（`mem.c`）                                            |
| ------------ | --------------------------------------------------------- | --------------------------------------------------------- |
| 分配对象     | **定长的内部结构体**：PCB、netconn、定时器节点、pbuf 头…… | **变长的数据缓冲**：PBUF_RAM 型 pbuf 的 payload 等        |
| 尺寸决定权   | 编译期（每类元素尺寸固定）                                | 运行期（请求多少就切多少）                                |
| 上游默认来源 | 静态数组拼接成的大池 `memp_memory[]`                      | 定制堆 `ram_heap[MEM_SIZE_ALIGNED + 2*SIZEOF_STRUCT_MEM]` |
| 设计动机     | O(1) 摘链、绝不碎片化、用量天然有上限 `MEMP_NUM_*`        | 在无 libc 的世界里提供 malloc/free 语义，邻接合并抗碎片   |

为什么不直接用 libc 的 `malloc()`？2001 年的 lwIP 面向的场景里，libc 可能根本不存在（不链接完整 newlib）、可能非线程安全、而且行为完全不可观测。自己写的分配器则是一个可以放进指定 RAM 段的确定大小数组——这个思路和 FreeRTOS 的 heap_4 是同一个灵魂（见 [[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison|FreeRTOS 第十九章]]），连"邻接空闲块合并"都是同一个问题域。

### 5.1.1 memp：一张 X-macro 编织的池类型表

memp 的全部秘密集中在 `src/include/lwip/priv/memp_std.h`。它是一个被反复 include 的表格文件，每种池一行：

```c
/* src/include/lwip/priv/memp_std.h（摘录） */
#if LWIP_TCP
LWIP_MEMPOOL(TCP_PCB,        MEMP_NUM_TCP_PCB,         sizeof(struct tcp_pcb),        "TCP_PCB")
LWIP_MEMPOOL(TCP_PCB_LISTEN, MEMP_NUM_TCP_PCB_LISTEN,  sizeof(struct tcp_pcb_listen), "TCP_PCB_LISTEN")
LWIP_MEMPOOL(TCP_SEG,        MEMP_NUM_TCP_SEG,         sizeof(struct tcp_seg),        "TCP_SEG")
#endif
...
LWIP_MEMPOOL(PBUF,           MEMP_NUM_PBUF,            sizeof(struct pbuf),           "PBUF_REF/ROM")
LWIP_PBUF_MEMPOOL(PBUF_POOL, PBUF_POOL_SIZE,           PBUF_POOL_BUFSIZE,             "PBUF_POOL")
```

`memp.c` 把这张表 include 四次，分别展开成：各池描述符的定义、`memp_pools[MEMP_MAX]` 描述符指针数组的初始化……这就是 C 语言的 X-macro 技法。每个池的存储本体由 `LWIP_MEMPOOL_DECLARE(name,num,size,desc)` 宏声明（`memp.h`），关键是它有**两个分支**：

```c
/* src/include/lwip/memp.h */
#if MEMP_MEM_MALLOC          /* ← IDF 走这个分支 */
#define LWIP_MEMPOOL_DECLARE(name,num,num,...) \
  const struct memp_desc memp_##name = { ...size... };   /* 只剩一个描述符！ */

#else                         /* ← 上游默认走这个分支 */
#define LWIP_MEMPOOL_DECLARE(name,num,size,desc) \
  static u8_t memp_memory_##name##_base[]; /* 静态存储本体 */ \
  static struct memp *memp_tab_##name;     /* 空闲链表头 */    \
  const struct memp_desc memp_##name = {...};
#endif
```

记住这两个分支（上面为简化示意），5.2 节它会成为理解 IDF 全堆化的钥匙。上游默认分支里，每类元素编进一个静态数组并维护空闲链表头指针，`num` 就是硬上限：分配即从空闲链表摘一个节点，拿不到就返回 NULL——**这就是"MEMP_NUM_TCP_PCB=16 则第 17 条连接失败"的机制根源**，也是 `stats_display()` 里 MEMP 段 `avail/used/max/err` 四个数字的出处。

### 5.1.2 mem：藏在 ram_heap 里的定制堆

`mem.c` 默认实现是一个教科书级的 first-fit 分配器：

```c
/* src/core/mem.c（摘录） */
struct mem {
  mem_size_t next;      /* 后继块的偏移量（不是指针！） */
  mem_size_t prev;
  u8_t       used;
};
static u8_t *ram;                    /* 对齐后的堆起点 */
static struct mem *ram_end;
static struct mem *lfree;            /* 最近一次已知空闲位置，加速扫描起点 */
```

几个值得一看的设计：

- **偏移量代替指针**：`next/prev` 存的是相对 `ram` 的字节偏移而非地址，省一半元数据（32 位平台上 8 字节 → 9 字节内含 padding 对齐到 `SIZEOF_STRUCT_MEM=12`，最小块 `MIN_SIZE=12`）；
- **lfree 加速**：`mem_malloc()` 从最近一次成功的空闲点开始扫，而不是每次从头遍历；
- **plug_holes() 双向合并**：释放时若物理前驱或后继空闲则吸收合并——这与 heap_4 的 `prvInsertBlockIntoFreeList()` 异曲同工；
- **保护分层**：任务侧互斥用 `sys_mutex_lock(&mem_mutex)`；若允许中断上下文释放（`LWIP_ALLOW_MEM_FREE_FROM_OTHER_CONTEXT`），再叠一层 `SYS_ARCH_PROTECT` 关中断短临界区。

另外还有第三条路 `MEM_USE_POOLS`（把"堆请求"路由到一组按尺寸分类的 malloc-pool），配合 `MEM_USE_POOLS_TRY_BIGGER_POOL` 可逐级向上找更大的池。三条路的切换全靠两个编译期开关，下一节直接上决策表。

### 5.1.3 开关组合 → 内存来源决策表

从 `src/core/mem.c` 的条件编译结构可以直接读出四象限：

| MEM_LIBC_MALLOC | MEMP_MEM_MALLOC | mem_malloc() 实现                                                       | memp 元素来源                   | 出现的位置                     |
| :-------------: | :-------------: | ----------------------------------------------------------------------- | ------------------------------- | ------------------------------ |
|    0（默认）    |    0（默认）    | 自研：ram_heap 定制堆                                                   | 各自的静态池数组                | 教科书式上游配置，两套系统并存 |
|        0        |        0        | 同上，但 `MEM_USE_POOLS=1` 时改为按尺寸分池查表（需自备 `lwippools.h`） | 同上                            | 想彻底消灭堆碎片的极端场景     |
|        1        |        0        | libc malloc（`mem_clib_malloc` 宏可重定向）                             | 仍是各自静态池数组              | 折中：结构体保留确定性上限     |
|        1        |      **1**      | libc malloc                                                             | **也走 mem_malloc() → libc 堆** | **ESP-IDF 选择：全堆化**       |

还有一条隐藏的统计线埋在 `opt.h`：

```c
/* src/include/lwip/opt.h */
#define MEM_STATS   ((MEM_LIBC_MALLOC == 0) && (MEM_USE_POOLS == 0))
#define MEMP_STATS  (MEMP_MEM_MALLOC == 0)
```

也就是说 `stats_display()` 是否输出 MEM/MEMP 段，完全由这两个开关在编译期决定——IDF 选了右下角格子之后，这两段统计就从固件里**整个消失了**。这是 5.3 节"黑盒问题"的根。

---

## 5.2 ESP-IDF 的选择：全堆化解剖

### 5.2.1 三处铁证

IDF 的 port 层配置在 `components/lwip/port/include/lwipopts.h`，写死且不可通过 Kconfig 更改：

```c
/* components/lwip/port/include/lwipopts.h */
#define MEM_LIBC_MALLOC                 1     /* mem_malloc → libc malloc */
#define MEMP_MEM_MALLOC                 1     /* memp → 也走 mem_malloc   */
#define MEM_ALIGNMENT                   4
```

而 IDF 的 newlib 其实在底层转发 heap 组件（malloc ≈ `heap_caps_malloc(size, MALLOC_CAP_DEFAULT)`，细节见 FreeRTOS 系列 第二十章），所以"libc 堆"实际就是 ESP32 的多 region 内存体系：内部 DRAM（部分区域还可当 DMA 用）、可选外部 PSRAM……都按能力位聚合成一个分配面。

第 5.5 节实验里我们会在设备上打印这两个宏做运行时复核，实测输出为：

```text
[cfg] MEM_LIBC_MALLOC=1 MEMP_MEM_MALLOC=1 MEM_ALIGNMENT=4 (MEM_USE_POOLS=0)
```

### 5.2.2 全堆化换来了什么

1. **与 heap 组件的多 region 策略天然协同**。WiFi 协议栈、蓝牙、应用代码共享同一片内部 RAM，lwIP 不需要也不应该圈一块"专属领地"。想要的话还有一个官方旋转门：

   ```c
   /* lwipopts.h：CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y 时 */
   #define mem_clib_malloc(size) heap_caps_malloc_prefer(size, 2,
           MALLOC_CAP_DEFAULT|MALLOC_CAP_SPIRAM,
           MALLOC_CAP_DEFAULT|MALLOC_CAP_INTERNAL)
   ```

   把 lwIP 的内存优先推去 PSRAM，内部 RAM 留给更挑地方的对象。如果 lwIP 还抱着自己的 `ram_heap[MEM_SIZE]`，这种"region 间调度"就无从谈起。

2. **没有 MEM_SIZE 圈地浪费**。上游 `ram_heap` 必须按最坏情况圈定，平时大部分是死的；全堆化后内存是流动的。
3. **一份调试设施服务全局**。heap 组件的越界检测、按 caps 统计、分配失败回调全都自动覆盖 lwIP 的分配。

### 5.2.3 付出的代价

- **碎片化风险回归**：静态池永不变碎，堆会。pbuf 这种高频变长分配混在同一片堆里，理论上（实验证明也会，5.5.d 节）产生碎片。
- **失去确定性上限**：每类元素的消耗上限从"`MEMP_NUM_* × sizeof(struct)`，链接期可见"变成"直到堆空"。诊断内存问题时少了静态账。
- **观测性被编译掉了**：上一节的两个 stats 宏双双归零——`stats_display()` 从此没有 MEM/MEMP 段（5.5.a 有实测截图级证据）；想看内存只能退回到 heap_caps 这一层，它是"全系统视角"，分不清哪些字节属于协议栈。
- **绝大多数 `MEMP_NUM_*` 变成了文档性数字**：空闲链表没了，计数上限自然失效——除非打补丁。这就要说到下面这只关键计数器。

### 5.2.4 那只补丁出来的 TCP_PCB 计数器

通读 `memp.c` 会发现一段被 `ESP_LWIP` 包裹的上游没有的代码：

```c
/* src/core/memp.c —— do_memp_malloc_pool() 内部（IDF 补丁） */
#if MEMP_MEM_MALLOC && ESP_LWIP
#if LWIP_TCP
  if (desc == memp_pools[MEMP_TCP_PCB]) {
    if (num_tcp_pcb >= MEMP_NUM_TCP_PCB) {
      return NULL;                     /* 明确拒绝，哪怕堆还有富余 */
    }
  }
#endif
#endif

  memp = (struct memp *)mem_malloc(MEMP_SIZE + MEMP_ALIGN_SIZE(desc->size));
```

配对的减计数在 `do_memp_free_pool()` 里。效果：**在全堆化世界里，只有 TCP PCB 这一类资源保留了 Kconfig 承诺的硬上限**（`MEMP_NUM_TCP_PCB = CONFIG_LWIP_MAX_ACTIVE_TCP`），其余 pool 类型都已放任到"堆空才失败"。为什么单单优待 TCP？因为半开连接是 DoS 攻击的经典靶子（SYN flood），UDP/RAW 的滥用一般不会拖垮整个栈。

配套的补救逻辑也升级了。`tcp_alloc()`（`tcp_in.c` 中实现）发现 `MEMP_TCP_PCB` 拿不到时会逐级杀死"最该死"的旧连接腾位子：

```text
TIME-WAIT → LAST_ACK → CLOSING → FIN_WAIT_2* → FIN_WAIT_1* → 更低优先级*
                                     （* 为 ESP_LWIP 扩展的两级）
```

这条链条在第 5.5.b 节的调试日志里会完整现身。

另一处有趣的对比：socket 数反而**不受**全堆化影响——`sockets.c` 里维护着编译期定长的静态数组：

```c
#define NUM_SOCKETS MEMP_NUM_NETCONN        /* = CONFIG_LWIP_MAX_SOCKETS，sockets_priv.h */
static struct lwip_sock sockets[NUM_SOCKETS];
```

找空位找不到就直接 `ERR_NOFD`，跟堆余量无关。所以"IDF 一切上限都虚化了"并不成立——三个例外：TCP PCB（补丁计数器）、socket 数（静态数组）、以及 VFS 文件描述符表本身。

### 5.2.5 Kconfig ↔ lwIP 宏 映射表（预算要用到的）

| CONFIG*LWIP*\*        | lwIP 宏                        | 默认值            | 全堆化后的真实含义                                                     |
| --------------------- | ------------------------------ | ----------------- | ---------------------------------------------------------------------- |
| `MAX_ACTIVE_TCP`      | MEMP_NUM_TCP_PCB               | 16（范围 1~1024） | 仍是硬上限（ESP_LWIP 补丁），**唯一**保留分配语义的计数上限            |
| `MAX_LISTENING_TCP`   | MEMP_NUM_TCP_PCB_LISTEN        | 16                | 堆内存下的软建议值                                                     |
| `MAX_UDP_PCBS`        | MEMP_NUM_UDP_PCB               | 16                | 同上                                                                   |
| `MAX_SOCKETS`         | NUM_SOCKETS / MEMP_NUM_NETCONN | 10                | 硬上限（静态数组）                                                     |
| `TCPIP_RECVMBOX_SIZE` | TCPIP_MBOX_SIZE                | 32                | tcpip 主邮箱深度，真 mailbox（FreeRTOS queue），消息只占指针大小的槽位 |
| `TCP_RECVMBOX_SIZE`   | DEFAULT_TCP_RECVMBOX_SIZE      | 6                 | 每连接接收邮箱深度                                                     |
| `TCP_ACCEPTMBOX_SIZE` | DEFAULT_ACCEPTMBOX_SIZE        | 6                 | 每个 listen socket 一个                                                |
| `TCP_SND_BUF_DEFAULT` | TCP_SND_BUF                    | 5760（=4×MSS）    | 发送缓冲**字节预算**，这是最有用的动态账参数                           |
| `TCP_WND_DEFAULT`     | TCP_WND                        | 5760              | 通告窗口与接收缓存的锚点                                               |
| `IP_REASS_MAX_PBUFS`  | IP_REASS_MAX_PBUFS             | 10                | 分片重组占用的 pbuf 数软上限                                           |

顺带澄清一个反直觉的点：Kconfig 对 `MAX_ACTIVE_TCP` 的 help 文本自己写着 _"Changing this value by itself does not substantially change the memory usage of LWIP"_——上游年代这句话是对的（池子反正要建满），但在 IDF 全堆化后反过来讲才是重点：**调小它几乎不省内存（内存本来就没预占），但它仍然精确控制着连接数上限**。

---

## 5.3 内存预算方法论：静态账 + 动态账

### 5.3.1 静态账（链接期锁定）

| 项目             | 出处                                             | 本实验环境取值                                       |
| ---------------- | ------------------------------------------------ | ---------------------------------------------------- |
| tcpip 任务栈     | `CONFIG_LWIP_TCPIP_TASK_STACK_SIZE`              | 3072 B                                               |
| eth 接收任务栈   | openeth MAC 默认 rx task（ch3 已述 4096/prio15） | 4096 B                                               |
| 应用线程栈       | 用户自定                                         | 例：echo_srv 4096 B                                  |
| tcpip 主邮箱深度 | `TCPIP_MBOX_SIZE`=32 条消息                      | 每条消息只是 `sizeof(struct tcpip_msg)` 级别的小对象 |
| sockets 表       | `MAX_SOCKETS`×`sizeof(lwip_sock)`                | 10 组编译期定长                                      |
| TCB 固定件       | 活跃 TCP PCB 数 × `sizeof(struct tcp_pcb)`       | 运行时按需逐条出现                                   |

静态账的特点是**逐项可在构建产物里核对**，缺陷是不包括任何随流量伸缩的东西。

### 5.3.2 动态账（每连接的呼吸量）

一条活跃 TCP 连接的瞬时内存占用近似：

```text
RX 侧：min(TCP_WND, recvmbox 深度 × pbuf_pool 单元)
       = min(5760 B, 6 × ~1516 B)              ≈ 5.7 ~ 9 KB（收得慢才顶格）
TX 侧：TCP_SND_BUF 数据拷贝 + SND_QUEUELEN 个 tcp_seg 结构
       = 5760 B + (4*SND_BUF+(MSS-1))/MSS × ~48 B
       = 5760 + 16 × 48                        ≈ 6.5 KB
固定件：tcp_pcb + netconn + 2~3 个 mbox/sem            ≈ 数百字节级
```

代入默认值，**一条满负荷连接大约压住 12~16 KB**，10 条 ≈ 150 KB——把它和实验测得的"INT|8BIT 总共 314704 B、开机空闲 268888 B"（见 5.5.a）摆在一起，结论不言自明：**默认配置下 10 条满负荷 TCP 连接就能吃掉本机一半以上的可用内部 RAM**。预算表的最后一行必须永远留着 heap_caps 水位来背书，纸面公式只是它的先验估计。

> [!tip] 容量规划的两个水位
> `heap_caps_get_free_size()` 回答"现在剩多少"，`heap_caps_get_minimum_free_size()` 回答"史上最低剩过多少"。**规划余量只认后者**——它等于全系统的最低水位记录，一旦跌破永不回升（除非重启），和 FreeRTOS 的 `xPortGetMinimumEverFreeHeapSize()` 是同一个用法（[[2026-08-26-freertos-deep-dive-ch19-heap-allocators-comparison|ch19]] 的 tip 在这里同样成立，只是覆盖范围从内核堆扩大到了整台机器）。
>
> 另外一个小坑：LWIP 协议计数器的容器 `STAT_COUNTER` 默认是 **u16_t**（`stats.h` 里 `LWIP_STATS_LARGE=0`，IDF 未暴露该 Kconfig），长时间运行会把 recv/xmit 累计回绕归零。读数请使用短时间窗内的差值。

---

## 5.4 Vanilla lwIP 与 ESP-IDF lwIP 对照

| 维度         | Vanilla 上游                                                         | ESP-IDF                                                                                                                         |
| ------------ | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| 结构体内存   | 静态池数组，`MEMP_NUM_*` 即容量                                      | 全部走 libc/heap*caps，多数 `MEMP_NUM*\*` 仅存名字                                                                              |
| 变长缓冲     | `ram_heap[MEM_SIZE...]` 圈地（默认 1600B，太小实际必改）             | 与全系统共用堆，无圈地                                                                                                          |
| TCP PCB 上限 | 池容量天然限定                                                       | **保留**（ESP_LWIP 补丁计数器 + 五级杀链）                                                                                      |
| 可观测性     | `stats_display()` 输出 MEM/MEMP 段：每池 avail/used/max/err 一目了然 | 两段被编译期掏空，仅剩 LINK/IP/ICMP/UDP/TCP/SYS 协议段                                                                          |
| 内存观察工具 | lwIP 自带统计即是专用仪表盘                                          | `heap_caps_get_free_size/largest/min-ever`（全局视角）+ 协议段 err 计数推断                                                     |
| 补偿手段 ①   | —                                                                    | `CONFIG_LWIP_STATS=y` 打开后，TCP 段的 `memerr`、IP 段的 `drop` 是内存故障的第一线索                                            |
| 补偿手段 ②   | —                                                                    | 上限族 Kconfig 充当阀门：`MAX_ACTIVE_TCP`、`MAX_SOCKETS`、`TCPIP_RECVMBOX_SIZE`、`IP_REASS_MAX_PBUFS`……单项虽不圈地，但精准限流 |
| 补偿手段 ③   | —                                                                    | heap 组件生态：caps 过滤、`heap_caps_print_heap_info()` 区域画像、分配失败注册回调                                              |

一句话总结暗线 B：IDF 不是简单替换了 lwIP 的内存层，而是**把它溶解进了平台级的 heap 组件**，然后打了两针补丁（TCP PCB 计数、TCP_RTO 背退等）找回在"自由经济"下最重要的几样公共品。

---

## 5.5 实验：基线、三种故障注入与恢复

工程：`practice/lwip-ch05-memory-management/`，从 ch3 模板起建（openeth bring-up + DHCP + TCP echo），追加四阶段固件逻辑与观测原语。构建运行命令遵循公约第 3 节，详细步骤已写入工程的 README.md。主机访问约定端口 **8005**（hostfwd=tcp::8005-:8888）。

以下三份日志均为真实截取：`run-a-definitive.log`（A/C/D 一次连续运行）、`run-b-pcb-exhaust.log`（SLIM 构建）。

### 5.5.a 建立基线：分区记账 + stats 真容 + 单次对话 diff

**目的**：量化"空闲状态的协议栈机器"长什么样，拿到后续故障注入的对照系。

开头即是 per-caps 台账与编译期开关的运行时复核：

```text
[caps] INTERNAL  total= 400148 free= 353436 largest= 147456 min-ever= 351404
[caps] INT|8BIT  total= 314704 free= 268888 largest= 147456 min-ever= 266856
[caps] DMA       total= 314704 free= 268888 largest= 147456 min-ever= 266856
[caps] DEFAULT   total= 314704 free= 268888 largest= 147456 min-ever= 266856
[cfg] MEM_LIBC_MALLOC=1 MEMP_MEM_MALLOC=1 MEM_ALIGNMENT=4 (MEM_USE_POOLS=0)
[cfg] CONFIG_LWIP_MAX_ACTIVE_TCP=16 CONFIG_LWIP_MAX_SOCKETS=10 TCP_MSS=1440 TCP_SND_BUF=5760 TCP_WND=5760 TCPIP_MBOX_SIZE=32 PBUF_POOL_SIZE=16
```

解读：

- INT|8BIT（lwIP 与应用真正抢的那口锅）总共 **314704 B**，DHCP 完成后还剩 **268888 B**，最大连续块 147456 B——这正是 heap 组件聚合成五个物理 region 后的产物：
  ```text
  Heap summary for capabilities 0x00000800:
    At 0x3ffae6e0 len 6432    free 24     ... largest_free_block 16
    At 0x3ffe0440 len 15072   free 6316   ...
    At 0x4008b23c len 85444   free 84548  ...
    At 0x3ffe4350 len 113840  free 112968 ...
    At 0x3ffb4360 len 179360  free 149580 ... min_free 147568
    Totals:
      free 353436 allocated 42788 min_free 351404 largest_free_block 147456
  ```
- `stats_display()` 的真实输出依次滚过 LINK/ETHARP/IP/ICMP/UDP/TCP，然后**直接跳到 SYS 收尾**——MEM 段和 MEMP 循环段整个缺席，与 5.1.3 的编译期推理严格一致：

  ```text
  TCP
    xmit: 0  recv: 0  fw: 0  drop: 0  chkerr: 0  lenerr: 0
    memerr: 0  rterr: 0  proterr: 0  opterr: 0  err: 0  cachehit: 0

  SYS
    sem.used: 0   mutex.used: 0   mbox.used: 0
  [MARKER] ----------------------------------------------
  ```

接着主机对 guest 做一次单发单回的最小对话（23 字节），echo 服务在每个连接 accept/close 时快照堆：

```text
[echo] #39 ACCEPT from 10.0.2.2:51906
[heap] on-accept        free=266536 largest=131072 min-ever=252256
[echo] #39 CLOSE served_rounds=1 bytes=23
[heap] on-close         free=268488 largest=139264 min-ever=252256
[netstat] post-close   link.recv=2 link.drop=0 ip.recv=9271 ip.drop=1
                       tcp.recv=9268 tcp.xmit=11601 tcp.memerr=0 udp.recv=2 ...
```

单次小对话的**净占用在 KB 级以下**（连接关闭后 heap 净值回升），印证 5.3 的动态账公式：固定件是小头，pbuf 数据量才决定呼吸幅度。`min-ever` 从 266856 掉到 252256——前面的 flood 流量已经把它砸低过一截，水位线的记忆功能在工作。

### 5.5.b 故障注入·PCB 耗尽："谁也没听见"的拒绝

**目的**：验证 `CONFIG_LWIP_MAX_ACTIVE_TCP=2` 时第 3+ 条连接到底在哪一行代码被拒绝、以什么面目呈现在应用和客户端两侧。

**构建变体**：把 README 里注明的三行 Kconfig 打开重建（含 `CONFIG_LWIP_DEBUG` + `CONFIG_LWIP_TCP_DEBUG` 以便捕获内核日志）。启动后从主机并发开 6 路：

```python
# 六线程并发：connect → sendall(b"conn-%02d") → 读回显；超时 10s
# 客户端实测结果（run-b-pcb-exhaust.log 对应的这次注入）：
client-1: echoed b'conn-01' in 0.2s
client-2: echoed b'conn-02' in 0.2s
client-3: FAILED after 10.0s: timed out
client-4: FAILED after 10.0s: timed out
client-5: echoed b'conn-05' in 6.2s      ← SYN 重传恰逢槽位释放
client-6: echoed b'conn-06' in 6.2s
```

guest 侧同刻日志（`run-b-pcb-exhaust.log`）：

```text
TCP connection request 32772 -> 8888.        ← SYN #1：分配 PCB 成功
TCP connection request 32776 -> 8888.        ← SYN #2：成功（两个名额满）
TCP connection request 32792 -> 8888.
tcp_alloc: killing off oldest TIME-WAIT connection   ┐
tcp_alloc: killing off oldest LAST-ACK connection    │
tcp_alloc: killing off oldest CLOSING connection     │ 五级杀链：
tcp_alloc: killing off oldest FIN_WAIT_2 connection  │ 都没有可杀对象
tcp_alloc: killing off oldest FIN_WAIT_1 connection  │ （全是活跃 ESTABLISHED）
tcp_alloc: killing oldest connection with prio lower than 64  ┘
tcp_listen_input: could not allocate PCB     ← 静默丢弃，不发 RST
E (9488) ch5lab: accept failed errno=113
TCP connection established 32772 -> 8888.    ← 前两条正常握手完毕
E (9588) ch5lab: accept failed errno=113
[echo] #1 ACCEPT from 10.0.2.2:32772
...
[netstat] post-close   ... tcp.memerr=2 ...   ← 恰好两次 PCB 分配失败的旁证
```

**拒绝位置的拆解**。一个 SYN 在 listen pcb 内部要走两道闸，都在 `tcp_listen_input()` 里，顺序如下（源码摘要）：

```c
#if TCP_LISTEN_BACKLOG                      /* 第一道：backlog 计数 */
  if (pcb->accepts_pending >= pcb->backlog) return;   /* 也是静默丢弃 */
#endif
  npcb = tcp_alloc(pcb->prio);              /* 第二道：PCB 分配 */
  if (npcb == NULL) { TCP_STATS_INC(tcp.memerr); ... return; }  /* 还是静默 */
```

本实验 backlog=6 > 并发路数，第一道没有触发；卡住的是第二道。要点有三个：

1. **用户与应用两侧都没有错误码**。没有 RST 回击（对比主动关闭端口的 ECONNREFUSED），发起方只能等自家内核 SYN 重传超时（Linux 默认约 2 分钟）；阻塞在 `accept()` 的服务器同样一无所知——唯一的涟漪是本例中看到的 `accept failed errno=113`（EHOSTUNREACH），其字面语义与真实病因相距甚远，恰好是"全堆化后错误传播路径变得晦涩"的活标本。
2. **`tcp.memerr` 是唯一的数字指纹**：风暴结束时的净值为 2，正好等于两次静默丢弃；约 15 秒后对端的 SYN 重传形成第二波到达，又有两次拒绝（日志再现两遍五级杀链），净值随之升到 4——计数与日志严格对应。
3. **自愈是必然的，时间取决于对方的重传计划**：名额释放后的下一个 SYN 重传立即握手成功（client-5/6 的 6.2 秒正是 1+2+4 的指数退避节奏）；风暴平息后单独发起的新连接 0.01 秒即获服务（recovery probe），协议栈完全不需要干预。

> [!note] 为什么说这个现象健康
> "忙不过来就沉默 + 依赖对端重传"正是 RFC 视角下 TCP 应有的韧性——SYN 重传本来就是内建的探测机制。工程上的对策不是改 lwIP，而是让服务的 accept 循环不被慢连接占死（或者前置 accept 之后立刻转交工作线程），名额周转快了，第 3+ 条连接的等待期自然缩到秒级以下。

### 5.5.c 故障注入·堆耗尽：失败在三层递归传播

**目的**：应用先吃光 libc 堆再灌持续流量，观察 lwIP 分配失败的完整传播路径，以及压力解除后的自愈。**这次构建不需要动 Kconfig**——全堆化的意义就是应用和其他模块共享同一片堆。

注压方式：应用侧 starver 任务每轮 `malloc(4096)` 啃一块，啃不动为止；主机侧用 Python 循环开连接、发 256KB、排空回显，循环终止条件绑定到 guest 日志里的 release 标记，保证覆盖整个饥饿窗口。

获取阶段的台阶清晰可见：

```text
[starve] grabbed=40 held=163840B  free=101708  largest= 81920
[starve] grabbed=56 held=229376B  free= 36108  largest= 22528
[starve] grabbed=64 held=247808B  free=  9020  largest=  2176
[starve] saturated: grabbed=71 held=251392B (allocation returned NULL)
[heap] starved-floor    free=  3836  largest=   496  min-ever=  2224
E (37627) opencores.emac: no mem for receive buffer
E (37627) opencores.emac: no mem for receive buffer
...(此后同类日志共 177119 行)
```

保持期的记账揭示了真正有意思的部分——**失败根本不是从 lwIP 开始的**：

```text
[starve-hold] +5s   [netstat] hold  ip.recv=17781 ip.drop=1 tcp.recv=17778
                                          tcp.memerr=6   ...
[starve-hold] +10s  [netstat] hold  ip.recv=17781 ip.drop=1 tcp.recv=17778
                                          tcp.memerr=11  ...
[starve-hold] +15s  ...大量 emac 错误行之间偶尔漏网一帧 → memerr 又跳一格
```

- 大部分帧死在**驱动层**：openeth RX 任务第一步就是 `malloc(ETH_MAX_PACKET_SIZE)=1516B`（`components/esp_eth/src/openeth/esp_eth_mac_openeth.c` 的 `emac_opencores_rx_task()`），失败即丢帧打日志——此时 lwIP 对发生的一切**不知情**（link/ip 计数器纹丝不动，毕竟报文从未抵达）；
- 少数帧趁某个瞬时释放钻进来，随后死在 lwIP 内部的某一环（PCB/netconn/seg 消息……），留下 `tcp.memerr` 六、十一、十六的爬升和一枚 `ip.drop`；
- 从主机的视角，这一切合成为一种症状：吞吐先腰斩、再抖动、最后归零，TCP 的可靠传输负责把这口黑锅慢慢咽下去（无限重传窗口内的数据）。这比"某函数返回 NULL"立体得多——同一颗子弹，穿过了 driver、l2→pbuf 转换、tcpip 邮箱、tcp 输出四道工序，每道留下的痕迹都不一样。

解除压力后的自愈干脆利落：

```text
[MARKER] ===== PHASE-C release: free everything -----
[heap] released+t300ms  free=265708 largest=131072   ← 300ms 内总量基本复原
[MARKER] WINDOW2 ... host echo round-2 == recovery proof
round2 echoed: b'hello-ch5-round2-after-recovery'    ← 主机复测：立刻恢复
```

值得注意的是 largest 只回升到 131072（此前的峰值块 147456 还没回来）：刚放完大堆，抓泄洪期间零散落地的小分配还嵌在大块的骨架里，需要一个安静窗口才能重新聚合。这把我们自然引到最后一种故障。

### 5.5.d 故障注入·碎片化：free 复原了，largest 没有

**目的**：制造经典碎片形态（隔块空洞），检验 free 与 largest 的分叉、精确回填与合并回收。全程无需网络流量参与，纯 heap_caps 记账。

```text
[heap] frag-baseline    free=259076  largest=139264
[heap] frag-all-alloc   free=211336  largest=110592   /* 整体申请 24×2048B */
[heap] frag-even-freed  free=237596  largest=110592   /* 隔块释放 12 洞 */
[heap] frag-refilled    free=211392  largest=110592   /* 新块精确填洞 */
[heap] frag-all-free    free=262192  largest=131072   /* 全释放+合并 */
[heap] frag-after-churn free=268488  largest=122880   /* 400 轮混合尺寸 churn */
```

五个状态对应五个论断：

1. **整体切块**（−49KB，largest −29KB）：big block 被拆，其余 region 共摊了一小块缺口——具体数值是多 region 布局的指纹，不必强求"整除关系"。
2. **隔块释放**是碎片的标准像：free 如数涨回一半（+24576B），**largest 纹丝不动**。一半空间复活了，却装不下任何一个大于 2048B 的新对象。
3. **精确回填**成功：新申请刚好落回原洞（free −24576 回到 all-alloc 水位）。顺带回答"什么时候应担心碎片"——只要你的新分配尺寸分布能命中旧洞，就没有急症。
4. **全部释放只复原了大半**：largest 到 131072 而未回到 139264。原因不玄：静默期间系统自身仍有零散存活分配嵌在区间里。理想情况下（这块区域足够干净）应当全额恢复，multi_heap 的相邻合并与 FreeRTOS heap_4 的 plug-hole 语义一致。
5. **终局画面最接近生产真相**：跑完 churn 与整个 echo 负载后，final 帧 `free=268488`（高于开机基线，无泄漏）而 `largest=122880`（较峰值 147456 蒸发了 24KB），外加一根再也降不下去的水位针 `min-ever=2224`。**总量正常 + 最大块缩水 + 最低水位疤痕**——这三联征就是嵌入式设备"明明没泄漏却越来越容易分配失败"的确诊单据。

> [!warning] 对全堆化架构的含义
> 5.5.d 的每一个字节都发生在 lwIP 眼皮外面：堆世界剩余多少、碎到什么程度，协议栈无从选择也无从规避——它下一次 `mem_malloc(PBUF_POOL)` 只是碰运气。上游设计中那些被放弃的确定性保证，现在要求应用程序用避免长期驻留的中间尺寸分配、尽量单调生命周期、给 largest 留安全垫这些纪律来偿还。这也是为什么 PSRAM 优先派会把 WiFi+lwIP 整体迁走，而不是让它们跟实时性敏感的小对象混居。

---

## 5.6 小结

- 上游 lwIP 用**两套系统回答两类需求**：memp 定长池管结构体（X-macro 表 + 静态数组 + 空闲链表，天然有 `MEMP_NUM_*` 上限），mem.c 定制堆（ram_heap + first-fit + lfree + plug_holes 双向合并）管变长缓冲；两者都被 `MEM_LIBC_MALLOC`/`MEMP_MEM_MALLOC` 四象限组合调度。
- **ESP-IDF 选了右下角：全堆化**。换来 heap 组件的多 region/caps 协同与零圈地浪费；付出碎片风险、静态账消失、`stats_display()` 的 MEM/MEMP 段被编译期掏空。memory 观察全面退守 `heap_caps_get_free_size/largest/min-ever`。
- 只有 **TCP PCB** 仍保留 Kconfig 硬上限（ESP_LWIP 补丁计数器，`do_memp_malloc_pool` 内先于分配判断），配五级杀链（TIME-WAIT→LAST_ACK→CLOSING→FIN_WAIT_2/FIN_WAIT_1（ESP 扩展）→低优先级）；socket 数另受静态数组 `sockets[NUM_SOCKETS]` 保护。
- 预算公式：**静态账**（任务栈+邮箱+固定件）链接期可核，**动态账**每条满负荷 TCP 连接 ≈12~16KB（recv 侧 min(WND, mbox×1516)，send 侧 SND_BUF+SND_QUEUELEN×seg 头），乘并发数后必须用 heap_caps 水位兜底复核。计划看 `minimum_free_size`，协议计数器 u16_t 会回绕，读差值不读绝对值。
- **PCB 耗尽是无声的**：双道闸（backlog 计数→`tcp_alloc`）都走静默丢弃，不发 RST、不给 errno，唯一的数字指纹是 `tcp.memerr`；自愈依赖对端 SYN 重传，本质健康。
- **堆耗尽的失败是多层递归的**：openeth 驱动 `malloc(1516)` 第一个倒下（177119 行丢帧日志），帧未达 lwIP 即湮灭；漏网之鱼才升级为 `tcp.memerr`/`ip.drop`。压力解除后百毫秒级自愈，echo 无恙。
- **碎片的确诊单据是三联征**：free 复原而 largest 缩水（122880 vs 147456）、min-ever 留下永久疤。在多 region 堆的世界里，协议栈对此无能为力，纪律（分配生命周期单调化、预留 largest 安全垫）是唯一的保险。

下一章我们顺着 TX 方向钻到底：`tcp_write()` 到底拷贝了几次数据？pbuf 引用计数如何让 zero-copy 成为可能，"少一次 memcpy"的性能红利和哪些坑绑定在一起——《lwIP 深度解析（六）：zero-copy 的 TCP 写路径》，见 [[2026-08-26-lwip-deep-dive-ch6-zero-copy-tcp-write|第六章]]。
