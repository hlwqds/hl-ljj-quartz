---
title: "lwIP 深度解析（四）：pbuf 深拆：lwIP 的内存面包屑"
date: 2026-08-26
description: "逐字段解剖 struct pbuf：len/tot_len 沿链递推不变量、type_internal 低字节的四类型编码、pbuf_alloc 分支路径与 layer 预留头空间。实测证明 IDF 全堆化下 PBUF_POOL 名义池上限根本不设防（memp 计数补丁只盖 TCP_PCB），真正的天花板是 libc 堆——并用 174 个 pbuf 打到 1.5KB 剩余的故障注入展示协议栈症状与 30KB 释放即自愈的全过程。"
tags: [lwip, network, esp32, esp-idf, qemu, memory-management]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 4. **第四章：pbuf 深拆：lwIP 的内存面包屑**

# lwIP 深度解析（四）：pbuf 深拆：lwIP 的内存面包屑

这一章回答三个问题：**为什么 lwIP 不直接用 malloc+memcpy 的传统缓冲**（一个 16 字节的结构体怎么省掉整包拷贝）、**一个包在 pbuf 链上长什么样**（协议头在哪层、payload 在哪层、`tot_len` 怎么递推）、**ref 计数如何让"零拷贝共享"成立**（释放时到底发生了什么）。读完它，你面对 `pbuf_alloc` 返回 NULL 时应该能立刻说清是哪一层的天花板被打穿了——这在第三章建好的 QEMU 网络环境里会被我们亲手打穿一次。源码参照：ESP-IDF v6.0.2 内捆绑的 lwIP **2.2.0-dev**（上游 2.1.3 之后的开发版），关键文件 `src/core/pbuf.c`、`src/include/lwip/pbuf.h`；实验工程 `practice/lwip-ch04-pbuf-anatomy/`，复用[[2026-08-26-lwip-deep-dive-ch3-qemu-network-lab|第三章]]的 openeth 联网模板。

---

## 4.1 为什么不是 malloc + memcpy

### 1. 传统方案的两笔账

把"收一个包/发一个包"写成最直白的 C 代码，通常长这样：

```c
/* 朴素方案：整包一块连续内存 */
uint8_t *pkt = malloc(ETH_HLEN + IP_HLEN + UDP_HLEN + payload_len);
memcpy(pkt + ETH_HLEN, &udp_hdr, UDP_HLEN);
memcpy(pkt + ETH_HLEN + IP_HLEN + UDP_HLEN, app_data, payload_len);
```

这笔账有两项隐性开销：

| 开销       | 来源                                                          | 后果                                              |
| ---------- | ------------------------------------------------------------- | ------------------------------------------------- |
| **拷贝税** | 数据从应用缓冲 → 包缓冲 → 各层处理再挪动，每次重组都要 memcpy | 数据在 RAM 里滚好几遍，CPU 和总线时间都花在搬运上 |
| **碎片税** | 每个"包缓冲"大小不一、生命周期参差                            | 通用堆反复 malloc/free 后碎片化，找不出连续大块   |

嵌入式协议栈两头都耗不起：RAM 以几十上百 KB 计，没有 MMU 兜底，TCP 收发窗口里同时活着几十个包缓冲。

### 2. lwIP 的答案：结构、数据、链三样分离

pbuf 的设计用三个正交机制同时砍这两笔账：

1. **结构与数据分离**：`struct pbuf` 只是 16 字节的"面包屑"，payload 可以跟结构体同块（TX 场景），也可以指向完全外部的内存甚至 flash 常量（ROM/REF 场景）；
2. **链（chain）**：一个包可以由多个 pbuf 用 `next` 指针串成单链表——头部留好了头空间的块装协议头，数据零拷贝挂尾巴；
3. **引用计数（ref）**：同一份数据被多少个指针指着就有多大的 ref，计数归零才真正释放——"共享而不拷贝"的簿记基础。

这三样合起来，意味着各层可以**通过移动 payload 指针来"剥头/加头"而完全不碰数据**（4.5 节），也意味着一份 flash 里的固件版本字符串可以直接挂进 TCP 发送队列而不做一次拷贝（第 6 章展开 zero-copy TCP write）。

### 3. 系列暗线提示

pbuf 几乎所有复杂操作（alloc/free/chain/cat）都发生在 `tcpip_thread` 单线程上下文里，这是 lwIP " mailbox 模型"（第 13 章主角）的数据面基础；而 ref 计数的增减用了 `SYS_ARCH_PROTECT` 而不是邮箱投递——因为驱动 RX 路径可能在 tcpip 线程之外触碰它。带着这个视角看源码，每处临界区都不是装饰。

---

## 4.2 struct pbuf 逐字段解剖

### 1. 八个字段撑起全部

先上真货。`src/include/lwip/pbuf.h` 的定义一字未改：

```c
struct pbuf {
  /** next pbuf in singly linked pbuf chain */
  struct pbuf *next;

  /** pointer to the actual data in the buffer */
  void *payload;

  /**
   * total length of this buffer and all next buffers in chain
   *
   * For non-queue packet chains this is the invariant:
   * p->tot_len == p->len + (p->next? p->next->tot_len: 0)
   */
  u16_t tot_len;

  /** length of this buffer */
  u16_t len;

  /** a bit field indicating pbuf type and allocation sources
      (see PBUF_TYPE_FLAG_*, PBUF_ALLOC_FLAG_* and PBUF_TYPE_ALLOC_SRC_MASK) */
  u8_t type_internal;

  /** misc flags */
  u8_t flags;

  /** the reference count always equals the number of pointers that refer
      to this pbuf (application, stack, or ->next pointers of a chain) */
  LWIP_PBUF_REF_T ref;      /* 默认 typedef 为 u8_t */

  /** For incoming packets, this contains the input netif's index */
  u8_t if_idx;
};
```

32 位 Xtensa 上 `sizeof(struct pbuf) == 16`（E1 实测输出印证）。逐字段的职责速查：

| 字段            | 类型 | 一句话职责                                                                                                    |
| --------------- | ---- | ------------------------------------------------------------------------------------------------------------- |
| `next`          | 指针 | 单链表串链；链尾为 NULL                                                                                       |
| `payload`       | 指针 | **本节点数据起点**——会随剥头/加头移动，这是全章的主角                                                         |
| `tot_len`       | u16  | 本节点及其后继的总长；沿链递推不变量见注释                                                                    |
| `len`           | u16  | 本节点承载的字节数；`len <= tot_len`                                                                          |
| `type_internal` | u8   | 四类型 + 分配源 + 连续性标志的低字节编码，4.3 节拆                                                            |
| `flags`         | u8   | 杂项位：`PBUF_FLAG_IS_CUSTOM`（自定义释放器）、`PBUF_FLAG_TCP_FIN`、`PBUF_FLAG_LLBCAST` 等                    |
| `ref`           | u8   | 引用计数 == 指向它的指针个数。`LWIP_PBUF_REF_T` 默认 `u8_t`（`opt.h`），理论上 255 个引用封顶且溢出会断言失败 |
| `if_idx`        | u8   | 收包 netif 的索引，多网卡场景下路由判断要用                                                                   |

> [!warning] type_internal 是"截断后的枚举"
> `pbuf_init_alloced_pbuf()` 里写的是 `p->type_internal = (u8_t)type;`。`pbuf_type` 枚举值里有高位 flag（如 `PBUF_ALLOC_FLAG_RX = 0x0100`），塞进 u8_t 时被截掉了。所以运行期可观察到的真实驻留值只有低八位——E1 实测四种类型的 `ti` 分别是 `80h / 82h / 01h / 41h`，恰好等于「2 个类型标志位 + 4 位分配源」：
>
> | 类型      | 结构体里实际存的值 | 组成                                          |
> | --------- | ------------------ | --------------------------------------------- |
> | PBUF_RAM  | `0x80`             | STRUCT_DATA_CONTIGUOUS(0x80) \| src=heap(0x0) |
> | PBUF_POOL | `0x82`             | 0x80 \| src=MEMP_PBUF_POOL(0x2)               |
> | PBUF_ROM  | `0x01`             | 无标志 \| src=MEMP_PBUF(0x1)                  |
> | PBUF_REF  | `0x41`             | DATA_VOLATILE(0x40) \| 0x1                    |

### 2. 不变量：tot_len 的递推与链/队列的分界

源码注释直接给出了两条铁律，全库代码都在维护它们：

```text
不变量 I   （沿链递推）  p[i].tot_len == p[i].len + p[i+1].tot_len；尾节点 p[n].tot_len == p[n].len
不变量 II  （和约束）    整条链承载的字节总数 == 头节点 tot_len == Σ len
```

还有一条容易忽略的边界规则：`pbuf.c` 文件头注释强调，链表这个字段也可以用来串**多个包的队列**（packet queue），区分依据是遍历时看 `tot_len == len` 还是 `next == NULL`——前者表示"当前包到此为止"。日常读包务必按包边界走，别把 `next != NULL` 当作"本包还有后续"。本章实验只涉及纯链，队列语义到 TCP 重传队列那里再见。

### 3. 链式结构的 ASCII 图：以 E2 实测的地址画一张

下面这张图的每一行数字都来自 4.7 节 E2 实验的真实打印（RAM 头节点装 20 字节伪 IP 头，后接 60 字节 flash 常量的 PBUF_ROM）：

```text
pbuf 链：HDR(PBUF_RAM) -> DAT(PBUF_ROM)        应用数据：flash 里的 s_rom_payload

 DRAM heap                                        DROM (flash 映射区)
┌───────────────────────────┐                 ┌─────────────────────────────┐
│ HDR @3ffba7c4             │                 │      ┊                      │
│  next     : 0x3ffafddc ───┼───────────────► │ DAT @3ffafddc               │
│  payload  : 0x3ffba80c ──┐│       next      │  next=0x0                   │
│  tot_len : 80 (=20+60)   ││                 │  tot_len: 60                │
│  len     : 20            ├┼────► ┌────────┐ │  len    : 60                │
│  ti/ref  : 80h / 1       ││      │20B 伪IP│ │  ti/ref : 01h / 2 ◄── 共享！│
└───────────────────────────┘      └────────┘ │  payload: 0x3f40caec ───────┼─► flash 常量区
                                              └─────────────────────────────┘
                                ┌─────────────────────────┐
                                │ 60B 用户数据（DRAM 中不存在拷贝）│
                                └─────────────────────────┘
```

注意 `HDR.payload` 与 HDR 自身地址只差 `off=72` 字节——这正是 `pbuf_alloc(layer=PBUF_IP)` 在数据前预留的头空间（4.3 节算给你看）；DAT 的 payload 则跨到了完全另一个存储域。所谓"面包屑"，就是这些散落在不同介质上的小块被 4 个指针字段串成一条完整的包。

---

## 4.3 四种类型与分配路径

### 1. pbuf_type：一编译进枚举的分配策略

`pbuf.h` 枚举四个类型（前面已给实测低字节值）。语义一句话版：

| 类型        | struct 来源                   | payload 位置                           | 排队安全？                                                              | 典型角色                                  |
| ----------- | ----------------------------- | -------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------------- |
| `PBUF_RAM`  | `mem_malloc` 大块             | 与 struct 同一块连续 RAM（后随）       | 安全                                                                    | **TX 主力**：发包前从这取，头空间同块预留 |
| `PBUF_POOL` | `memp_malloc(MEMP_PBUF_POOL)` | 与 struct 同块（池元素内固定尺寸缓冲） | 安全，RX 必备                                                           | **RX 主力**：驱动收包快取快放             |
| `PBUF_ROM`  | `memp_malloc(MEMP_PBUF)`      | 调用者指定，通常 flash/常量            | **必须不可变**                                                          | 只读零拷贝挂载                            |
| `PBUF_REF`  | 同 ROM（MEMP_PBUF）           | 调用者指定的易变 RAM                   | **不安全**：入队前要拷贝（`PBUF_NEEDS_COPY(p)` 就是查它的 VOLATILE 位） | 引用现成缓冲，马上就发                    |

两个特殊成员值得点名：`PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS`（0x80）决定 `pbuf_add_header` 能否向回挪 payload（有此标志才能边界检查，ROM/REF 没有所以默认加头失败，要 `force`）；`PBUF_REF` 的 VOLATILE 位（0x40）是"入队请拷贝我"的自首书。

### 2. pbuf_alloc 分支走读（src/core/pbuf.c）

函数签名：`struct pbuf *pbuf_alloc(pbuf_layer layer, u16_t length, pbuf_type type);`。主体就是一个 switch：

```c
switch (type) {
  case PBUF_REF: /* fall through */
  case PBUF_ROM:
    p = pbuf_alloc_reference(NULL, length, type);   /* 只要一个 MEMP_PBUF 结构体 */
    break;
  case PBUF_POOL: {
    rem_len = length; offset = (u16_t)layer;
    do {
      q = memp_malloc(MEMP_PBUF_POOL);              /* 取池元素 */
      if (q == NULL) { PBUF_POOL_IS_EMPTY(); if (p) pbuf_free(p); return NULL; }
      qlen = LWIP_MIN(rem_len, PBUF_POOL_BUFSIZE_ALIGNED - align(offset));
      pbuf_init_alloced_pbuf(q, (u8_t*)q + SIZEOF_STRUCT_PBUF + offset,
                             rem_len, qlen, type, 0);
      /* 头元素记 offset，后续元素 offset=0 —— 只有第一个节点带预留给 layer 的空间 */
      last->next = q; ...
      rem_len -= qlen; offset = 0;
    } while (rem_len > 0);                          /* 大包拉成一条链 */
    break;
  }
  case PBUF_RAM: {
    alloc_len = align(SIZEOF_STRUCT_PBUF) + align(offset) + align(length);
    p = mem_malloc(alloc_len);                      /* 一整块 */
    pbuf_init_alloced_pbuf(p, (u8_t*)p + SIZEOF_STRUCT_PBUF + offset,
                           length, length, type, 0);
    break;
  }
}
```

三个可咀嚼的点：

1. **POOL 是唯一可能产生多节点链的分支**：请求长度超过单个池缓冲就把剩下的甩给下一个元素，头元素独占 layer 偏移，后续元素 offset 归零——保证链上协议头始终从头元素的 payload 开始。
2. **POOL 分配失败是"事务性"的**：半途某元素拿不到，已分配的半截链立刻 `pbuf_free` 回滚再返回 NULL。
3. **RAM 是单块的**，因此 RAM 型天然 `next==NULL`，长度超过预算则整个失败。

`pbuf_alloc_reference()` 则最省事：`memp_malloc(MEMP_PBUF)` 拿 16 字节结构体，payload 直接指外部，len=tot_len=length，完事。

### 3. layer 参数：预留头空间怎么算

`pbuf_layer` 本身就是"枚举出来的字节数"。IDF v6 默认双栈构建下实测（E1 第一行输出）：

```text
[E1] layer enum values: RAW=0 LINK=14 IP=54 TRANSPORT=74
```

对照 `pbuf.h` 的定义就能解释为什么 `IP=54` 而不是教科书上的 34：

```c
PBUF_TRANSPORT_HLEN = 20
PBUF_IP_HLEN        = LWIP_IPV6 ? 40 : 20     /* IDF 默认开 IPv6 → 40 */
PBUF_LINK_HLEN      = 14 (+ETH_PAD_SIZE=0)
PBUF_TRANSPORT = LINK_ENCAPSULATION(0)+LINK(14)+IP(40)+TRANSPORT(20) = 74
PBUF_IP        = 14+40  = 54
PBUF_LINK      = 14
PBUF_RAW_TX/PBUF_RAW = 0
```

就算你的设备只讲 IPv4，预留也按最大协议族算——换来的是"任何时候都能原地加上任何头"。E1b 实测了这条预留律：同为 64 字节 payload 的 PBUF_RAM，layer 从 RAW→LINK→IP→TRANSPORT，`payload - (struct+16)` 分别落在 **0 / 16 / 56 / 76**（恰好是 `align4(layer)`），堆占用也从 ~80B 涨到 ~156B。头空间不是白给的，是买好的保险。

### 4. 重点对照：IDF 全堆化下的 PBUF_POOL

[[2026-08-26-lwip-deep-dive-ch5-memory-management|第五章]]会把 lwIP 内存子系统整体铺开，这里先把与本类型相关的部分钉死。上游 vanilla lwIP 里 PBUF_POOL 来自编译期静态数组池：`LWIP_MEMPOOL(PBUF_POOL, PBUF_POOL_SIZE, ...)` 声明 `PBUF_POOL_SIZE` 个固定大小元素，发完了就没了——上限由宏硬性给出。而 IDF 的 port 头文件 `port/include/lwipopts.h` 写死：

```c
#define MEM_LIBC_MALLOC                 1   /* lwip 的 mem 层直接走 libc malloc */
#define MEMP_MEM_MALLOC                 1   /* memp 每类"池"也改成 mem_malloc 透传 */
```

于是 `memp_malloc(MEMP_PBUF_POOL)` 变成了 `mem_malloc(align(sizeof(struct pbuf)) + align(PBUF_POOL_BUFSIZE))`，最终落到 ESP-IDF 的 heap 组件。E1/E3 的地址段证据已经说明一切：POOL 节点 `0x3ffba8f8` 与 RAM 节点 `0x3ffba7c4` 落在同一段 int-DRAM 堆区间，一个仅请求 200 字节 payload 的 POOL 也照样吃掉约 1.5KB（元素尺寸固定，C2 实测平均 1540 B/pbuf）。

那**名义池上限还管不管用？**上一批笔记（本仓库 CONVENTIONS.md §6 Batch 1）写下的是"仍受计数上限约束"。这一章我们把源码翻到了底——该结论需要收窄：

```c
/* src/core/memp.c — MEMP_MEM_MALLOC 下 do_memp_malloc_pool() 的完整防护逻辑 */
#if MEMP_MEM_MALLOC && ESP_LWIP && LWIP_TCP
static u32_t num_tcp_pcb = 0;
#endif
...
#if MEMP_MEM_MALLOC && ESP_LWIP && LWIP_TCP
  if (desc == memp_pools[MEMP_TCP_PCB]) {
    if (num_tcp_pcb >= MEMP_NUM_TCP_PCB) {
      return NULL;                    /* ← IDF 给 TCP_PCB 手工补了计数闸门 */
    }
  }
#endif
```

`do_memp_malloc_pool()` 里的显式计数闸门**只对 `MEMP_TCP_PCB` 这一关生效**——因为 PCB 是常驻对象，上限必须有；其余类型（包括 PBUF_POOL）在 MEMP_MEM_MALLOC 模式下只剩堆本身这道墙。4.7 节 E3.C1 的 48 连发实测（越过第 16、32、48 关口全部存活）验证了这一点。同时确认：`PBUF_POOL_SIZE` 在本仓库中**没有对应的 Kconfig 旋钮**（`components/lwip/Kconfig` grep 无命中），想改只能仿照 port 头写 build 头覆盖，menuconfig 改不了。

> [!tip] 版本命名噪音
> 更晚上游把池数量宏重命名为 `MEMP_NUM_PBUF_POOL`（与你熟悉的 `MEMP_NUM_*` 家族对齐），但 IDF v6.0.2 捆绑的 2.2.0-dev 快照里仍是旧名 **`PBUF_POOL_SIZE`**（默认 16，`opt.h`）。网上教程让你"把 MEMP_NUM_PBUF_POOL 调小做故障注入"，在本仓库连编译开关都对不上号——这也是本章 E3 不用改配置、改用应用层压力注入的直接原因。

vanilla vs IDF 的差异汇总（本章范围内）：

| 维度            | Vanilla lwIP（静态池模式）                  | ESP-IDF v6（MEM_LIBC_MALLOC + MEMP_MEM_MALLOC）              |
| --------------- | ------------------------------------------- | ------------------------------------------------------------ |
| PBUF_POOL 存储  | 编译期静态数组，`pbuf_init()` 一次性划出    | 每次 `heap_caps/malloc` 动态申请，物理上无池                 |
| 数量上限        | `PBUF_POOL_SIZE`（16）由空闲链表天然强制    | **无上限**（唯一例外 TCP_PCB 有补丁计数）                    |
| 元素尺寸        | 固定 `PBUF_POOL_BUFSIZE`，请求 10B 也占满格 | malloc 尺寸同样是固定的整格（~1536B），只是换了个堆          |
| ROAM/REF 结构体 | MEMP_PBUF 静态池（默认 16 个）              | libc 堆动态分配                                              |
| 分配失败语义    | 池空即 NULL（即使堆有大片闲内存）           | 堆尽才 NULL；现场可用 `heap_caps_get_free_size()` 定量诊断   |
| 观测手段        | `stats_display()` 有 MEM/POOL 计数段        | stats 的 MEM/MEMP 段被编译裁空（ch1 已验证），用 heap API 看 |

---

## 4.4 引用与释放：ref 如何让零拷贝共享成立

### 1. pbuf_free 的精确语义

`u8_t pbuf_free(struct pbuf *p)` 返回"本次真正释放掉的 pbuf 个数"。算法是一条 while 循环：

```text
while (p != NULL):
    SYS_ARCH_PROTECT(old)          /* ref-- 必须原子：驱动/RX 上下文也在摸它 */
    ref = --p->ref
    SYS_ARCH_UNPROTECT(old)
    if ref == 0:
        按 type_internal 的 alloc_src 分发释放：
          POOL → memp_free(MEMP_PBUF_POOL)   （IDF 下就是 free()）
          ROM/REF → memp_free(MEMP_PBUF)     （free()）
          RAM → mem_free(p)                  （free()）
          custom（flags 含 IS_CUSTOM）→ custom_free_function(p)  ← 见 4.6 节，IDF RX 路径靠它
        count++; p = 原 next   /* 继续沿链检查下一个 */
    else:
        p = NULL               /* ref 还有主，立即停车，绝不多放 */
```

源码注释里那张真值表值得背诵（把 head 当作调用者手里最后一个引用）：

```text
现有链 a->b->c，ref 分布         调 pbuf_free(a) 之后
1 -> 2 -> 3            →        1(alive) -> 3      （a 释放，链断头，bc 少一个指向者）
3 -> 3 -> 3            →        2 -> 3 -> 3        （整体少一个总引用）
1 -> 1 -> 2            →                  1        （ab 释放，c 存活）
1 -> 1 -> 1            →        全部释放
```

**"减到非零即停"** 就是共享的全部秘密：哪怕两条业务路径拿着同一条链的不同入口，各自 `pbuf_free` 自己那份引用即可，谁也不会提前埋葬别人还在用的数据。

### 2. cat vs chain：一字之差，引用语义两重天

| 函数                    | 行为                                 | 对 tail 的 ref                        | 调用者此后                     |
| ----------------------- | ------------------------------------ | ------------------------------------- | ------------------------------ |
| `void pbuf_cat(h, t)`   | 把 t 链到 h 尾巴 + 沿 h 修补 tot_len | **不变**——t 原有的那格引用被 h "接管" | 不得再单独使用 t（所有权转移） |
| `void pbuf_chain(h, t)` | `pbuf_cat(h,t)` + `pbuf_ref(t)`      | **+1**                                | 照常用 t，最后自己负责 free    |

配套的还有 `pbuf_dechain(p)`（拆头尾并归还引用）与 `pbuf_ref(p)`（裸加引用——TCP 重传队列把同一个 seg 再排队一次时会用到，见 `tcp.c` 的 `pbuf_ref(cseg->p)`）。以及 `struct pbuf *pbuf_free_header(q, size)`：从头上 free 掉整整 size 字节的节点们（整节点直接 free、末节点 remove_header 截断），UDP/IP 层吃掉整个报文但还剩自定义 payload 挂着时的标准动作。

### 3. 常见泄漏模式清单

按事故现场反推，80% 的 pbuf 泄漏来自三种姿势：

1. **回调里忘 free**：raw/recv 回调拿到 `p` 之后既没消费完转交（如交给 `tcp_recved` 之外的自有队列时要自己 ref/接管），也没有 finally 分支兜底 `pbuf_free(p)`。特征：一次风暴后 heap 缓慢下台阶不复原。排查口诀：每个拿到 `struct pbuf*` 的函数，退出路径数一遍——return 几处，free 就得几处（或全部移交所有权）。
2. **REF/ROM 的 payload 生命周期错配**：`PBUF_REF` 指着你栈上的缓冲就 send 出去了，发送尚未完成缓冲已被回收——这不是泄漏而是 use-after-free；反过来 ROM 引用的模块卸载了才知道 flash 数据不会消失（好事），但 REF 进 TCP 重传队列时若没人 `pbuf_take` 拷贝一份，重传的就是赃数据。规则：**REF 只许 fire-and-forget，凡是要排队的引用一律先拷贝或升级为自管缓冲。**
3. **cat 之后又单独 free 了 tail**：`pbuf_cat` 已经把你的 tail 所有权并给了 head，再 `pbuf_free(tail)` 就是一次超额 deref（好消息是 ref 断言会当机立断抓到你）。

E1 结尾那行 `after free-all heap free=273024 delta_vs_start=0` 是这类问题的金标准自查法：一组配对操作跑完，heap 免费水位应精确回到起点（QEMU 上 64KB 栈内存级别抖动 <1KB 属正常流量噪音）。

---

## 4.5 头空间的让渡：pbuf_header 三兄弟

### 1. API 关系与限制

```c
u8_t pbuf_add_header(struct pbuf *p, size_t header_size_increment);    /* 加头：payload 前移 */
u8_t pbuf_add_header_force(struct pbuf *p, size_t header_size_increment); /* 允许对 ROM/REF 强行加头 */
u8_t pbuf_remove_header(struct pbuf *p, size_t header_size_decrement); /* 剥头：payload 后移 */
u8_t pbuf_header(struct pbuf *p, s16_t header_size_increment);         /* 带符号老接口：负数剥正数加 */
```

`add_header` 的边界检查非常诚实：类型带 CONTIGUOUS 标志才允许挪，且要求新 payload 不得小于 `(u8_t*)p + SIZEOF_STRUCT_PBUF`（不能踩进自己的 16 字节结构体），挪不动返回 1。`remove_header` 只要求 `decrement <= p->len`。每次成功的操作同步维护三个字段：`payload ± n`、`len ± n`、`tot_len ± n`——且只动**本节点**。对链头操作时递推不变量依然成立：链头的 tot_len 恰是全包总量，减去剥掉的 n 之后恰好等于"新 len + 后继 tot_len"。这也解释了为什么这套调用总是发生在收包链的头上。force 版本的存在理由：ROM/REF 没有 CONTIGUOUS 位没法做安全检查，但内核自己在受控场景下可以明确承担风险。

### 2. 收包路径的剥头流水线（呼应第 8/9 章）

协议分层在 pbuf 世界里表现为一串 `pbuf_remove_header`。IDF 以太网收包从驱动到 socket data 的完整链路：

```text
openeth RX 缓冲(driver L2 buffer, heap)
  └─ ethernetif_input():          p = esp_pbuf_allocate(...)   ← pbuf_custom 包装 L2 缓冲，零拷贝
       └─ tcpip_thread:
            ethernet_input():     pbuf_remove_header(p, 14 /*SIZEOF_ETH_HDR, 或 18 带 VLAN*/)
                                   ↓ ethertype 分流
            ip4_input():          pbuf_remove_header(p, ihl*4 /*通常 20*/)
                                   ↓ 协议号分流            ↑ TTL/校验和在这里检查
            udp_input():          pbuf_remove_header(p, 8 /*UDP_HLEN*/) → 找 PCB → 交付 app
            tcp_input():          pbuf_remove_header(p, tcphdrlen + option 折腾)  /* tcp_in.c */
```

E2 实验把这层"让渡"拍成了慢镜头（伪造 eth+ip+udp+32B 数据的一张 PBUF_RAW 帧）：

```text
[E2.rx-frame] ==> p#0 @0x3ffba824 next=0 | RAM ti=80h len=74 tot_len=74 ref=1 | payload=0x3ffba834 off=16
[E2] strip ETH(14): rc=0 payload@0x3ffba842 len=60 tot_len=60
[E2] strip IP(20): rc=0 payload@0x3ffba856 len=40 tot_len=40
[E2] strip UDP(8): rc=0 payload@0x3ffba85e len=32 tot_len=32 <- app data starts here
```

三次剥头，`payload` 指针分别 +14/+20/+8 前进，`len` 与 `tot_len` 同步缩水，**数据本体一个字节都没动**。这就是"头空间的让渡"：alloc 时预留在前面的那些字节，此刻被以太网/IP/UDP 依次认领。发送方向则相反——`ethernet_output()` 用 `pbuf_add_header(p, SIZEOF_ETH_HDR)` 把以太网头"印"在预先留好的位置上。ARP/IP 层的具体分诊逻辑留给[[2026-08-26-lwip-deep-dive-ch8-ethernet-arp|第八章]]与[[2026-08-26-lwip-deep-dive-ch9-ip4-icmp|第九章]]。

---

## 4.6 Vanilla lwIP 与 ESP-IDF lwIP 对照

### 1. pbuf 层本体：core 几乎未动

`src/core/pbuf.c` 在 IDF 树里**没有任何 `ESP_LWIP` 条件补丁**（grep 全文为零命中）——分配策略的差异全部由 `port/include/lwipopts.h` 的两个宏（`MEM_LIBC_MALLOC/MEMP_MEM_MALLOC`）驱动，属于"配置级改造"。IDF 特有的 pbuf 相关代码出现在 core 之外的适配层。

### 2. IDF 的三处 pbuf 相关改造点

1. **memp.c 的 TCP_PCB 计数闸门**（4.3 节引过的那段）：全堆化之后手工补回的唯一一道池上限，附带同款对称的 `num_tcp_pcb++/--` 簿记——这是 core 目录内唯一的例外，特征宏正是 `MEMP_MEM_MALLOC && ESP_LWIP`。
2. **esp_netif 的 custom pbuf 零拷贝收包**：`components/esp_netif/lwip/netif/esp_pbuf_ref.c` 全文 66 行，干的事是把驱动的 L2 缓冲"打包"成 pbuf 直送协议栈：

   ```c
   typedef struct esp_custom_pbuf {
       struct pbuf_custom p;        /* 标准 pbuf + custom_free_function 槽位 */
       esp_netif_t *esp_netif;
       void *l2_buf;                /* 驱动的原始接收缓冲 */
   } esp_custom_pbuf_t;

   static void esp_pbuf_free(struct pbuf *pbuf) {
       esp_netif_free_rx_buffer(((esp_custom_pbuf_t*)pbuf)->esp_netif,
                                ((esp_custom_pbuf_t*)pbuf)->l2_buf);   /* 还缓冲给驱动 */
       mem_free(pbuf);                                                 /* 还包装壳给堆 */
   }

   struct pbuf *esp_pbuf_allocate(esp_netif_t *esp_netif, void *buffer,
                                  size_t len, void *l2_buff) {
       esp_custom_pbuf_t *esp_pbuf = mem_malloc(sizeof(esp_custom_pbuf_t));
       esp_pbuf->p.custom_free_function = esp_pbuf_free;
       esp_pbuf->l2_buf = l2_buff;
       return pbuf_alloced_custom(PBUF_RAW, len, PBUF_REF,
                                  &esp_pbuf->p, buffer, len);
   }
   ```

   这是 `LWIP_SUPPORT_CUSTOM_PBUF`（IDF 设 1）+ `pbuf_alloced_custom()` + `PBUF_FLAG_IS_CUSTOM` 的教科书用法：**pbuf_free 走到这个节点时不调 memp/mem，改调 `custom_free_function` 把缓冲还给驱动的缓冲池**。整条以太网 RX 路径上，帧数据从网卡寄存器到 socket 一次拷贝都没有——代价仅仅是每次收包一个小壳的 alloc/free。

3. **WiFi 走的是另一条路**：`esp_netif/lwip/netif/wlanif.c` 里 WiFi 输入若拿到独立 L2 缓冲同样走 `esp_pbuf_allocate()` 零拷贝，否则退化为 `pbuf_alloc(PBUF_RAW, len, PBUF_RAM)` 整帧拷贝——两条路的选择与 esp-wifi 的 MAC 缓冲管理有关，QEMU 无法仿真 WiFi 真实路径（CONVENTIONS §2），源码层面的完整对比在第 18 章展开。

### 3. 对照小结表

| 维度              | Vanilla lwIP                              | ESP-IDF v6                                               |
| ----------------- | ----------------------------------------- | -------------------------------------------------------- |
| pbuf core 代码    | `src/core/pbuf.c` 原味                    | 同左（零条件补丁），配置差全在 lwipopts                  |
| RX pbuf 来源      | 驱动 `pbuf_alloc(PBUF_POOL,...)` 拷贝填充 | ethernetif/wlanif custom-pbuf 包驱动缓冲（可选拷贝退化） |
| POOL 上限         | 静态池强制 PBUF_POOL_SIZE                 | 仅 TCP_PCB 有补丁计数，POOL 无限（堆界）                 |
| 可观测性          | `stats_display()` MEM/POOL 段齐全         | 该两段被裁空，须用 heap_caps API                         |
| menuconfig 调优点 | 手编 opt.h/lwipopts.h                     | Kconfig 暴露 sockets/MSS 等，但 PBUF_POOL_SIZE 无旋钮    |

---

## 4.7 实验：四类型分配、链可视化与故障注入

工程位于 `/home/huanglin/code/quartz/practice/lwip-ch04-pbuf-anatomy/`（基于 ch3 模板改，bring-up 序列一致；DHCP 到手后依次跑 E1→E2→E3）。所有输出摘录自 `run.log` 真实打印，坐标可复现（QEMU 内存布局确定，指针值两次运行略有偏移属正常）。

### 1. 构建与运行

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch04-pbuf-anatomy
idf.py set-target esp32        # 首次
idf.py build
idf.py qemu monitor < /dev/null || true    # 生成 qemu_flash.bin/efuse
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 90 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run.log
```

启动段的 openeth MAC filter 三连报错与 [[2026-08-26-lwip-deep-dive-ch3-qemu-network-lab|第三章]]相同，属预期噪音。全程约 10 秒。

### 2. 实验 E1：四种类型分配实测

目的：验证四类型的分配域、`type_internal` 驻留值、layer 预留律、以及 IDF 全堆化下 POOL 与 RAM 是否同段。代码对四类型各 `pbuf_alloc` 一个真实负载（ROM 指向 flash 常量数组、REF 指向局部易变缓冲），打印地址并用 `heap_caps_get_free_size()` 记账。关键输出：

```text
[BOOT] network ready: heap_free=273024
[E1] sizeof(struct pbuf)=16  SIZEOF_STRUCT_PBUF(align)=16  PBUF_POOL_BUFSIZE(align)=1516
[E1] layer enum values: RAW=0 LINK=14 IP=54 TRANSPORT=74
[E1] RAM  pbuf@0x3ffba7c4 ti=80h ref=1 len=200 tot_len=200 payload@0x3ffba820(int-DRAM) payload-pbuf=92 struct_region=int-DRAM
[E1] POOL pbuf@0x3ffba8f8 ti=82h ref=1 len=200 tot_len=200 payload@0x3ffba954(int-DRAM) payload-pbuf=92 struct_region=int-DRAM
[E1] ROM  pbuf@0x3ffafddc ti=01h ref=1 len=65 tot_len=65 payload@0x3f40caec(flash(DROM)) payload-pbuf=-12202736 struct_region=int-DRAM
[E1] REF  pbuf@0x3ffba79c ti=41h ref=1 len=200 tot_len=200 payload@0x3ffb6670(int-DRAM) payload-pbuf=-16684 struct_region=int-DRAM
[E1] heap free delta after 4 allocs=1888 B (before=273024)
[E1b] layer_enum=0 payload_offset_from_data_start=0 len=64 tot_len=64 heap_alloc=~80 B
[E1b] layer_enum=14 payload_offset_from_data_start=16 len=64 tot_len=64 heap_alloc=~96 B
[E1b] layer_enum=54 payload_offset_from_data_start=56 len=64 tot_len=64 heap_alloc=~136 B
[E1b] layer_enum=74 payload_offset_from_data_start=76 len=64 tot_len=64 heap_alloc=~156 B
[E1] after free-all heap free=273024 delta_vs_start=0
```

解读：

- **RAM 与 POOL 同落 int-DRAM 堆段、payload 相对 struct 同为 off=92**（=16 结构体 +76 预留）——IDF 全堆化下两者构造方式趋同的实证；ROM payload 则在 `0x3f40caec` 的 DROM 区，零拷贝挂载得到物理层证据；ti 四值为 `80h/82h/01h/41h`，与 4.2 节的推导表逐一对上。
- **这 1888B 的账单里 POOL 一家占大头**：其元素格固定为 `align(sizeof(struct pbuf))+align(PBUF_POOL_BUFSIZE)`≈1536B（含 allocator 头即 C2 实测的 1540B），200 字节的请求照样付整格的钱；剩下的是 RAM 一整块（E1b 已给公式值 ~156B+管理头）加 ROM/REF 各一个 MEMP_PBUF 小壳。这就是"POOL 元素按最长包预付"在堆化后的形态。
- 四次 `pbuf_free` 后水位 **delta_vs_start=0**：4.4 节泄漏自查法的第一次现场示范。
- E1b 印证 `payload_offset == align4(layer)` 以及 HEADROOM 即便 RAW 层也吃满 74 字节保险的 TRANSPORT 完全体。

### 3. 实验 E2：链式结构可视化

目的：亲手组装一条多类型链，让 4.2/4.4 的文字结论变成机器可验证的打印。关键输出已在 4.2 节以图的形式呈现，此处补齐 cat/chain/free 三阶段的原文摘录：

```text
[E2.after-cat] ==> p#0 @0x3ffba7c4 next=0x3ffafddc | RAM ti=80h len=20 tot_len=80 ref=1 | payload=0x3ffba80c off=72
[E2.after-cat]    -> p#1 @0x3ffafddc next=0x0     | ROM ti=01h len=60 tot_len=60 ref=1 | payload=0x3f40caec off=-12202736
[E2.chain2]    ==> p#0 @0x3ffba824 next=0x3ffafddc | RAM ti=80h len=8 tot_len=68 ref=1 | payload=0x3ffba86c off=72
[E2.chain2]       -> p#1 @0x3ffafddc next=0x0     | ROM ti=01h len=60 tot_len=60 ref=2 | payload=0x3f40caec off=-12202736
[E2.chain1]    ==> p#0 @0x3ffba7c4 next=0x3ffafddc | RAM ti=80h len=20 tot_len=80 ref=1 | payload=0x3ffba80c off=72
[E2.chain1]       -> p#1 @0x3ffafddc next=0x0     | ROM ti=01h len=60 tot_len=60 ref=2 | payload=0x3f40caec off=-12202736
[E2] pbuf_free(chain2 head) freed 1 pbuf(s); dat survives:
[E2.after-free2] ==> p#0 @0x3ffba7c4 next=0x3ffafddc | RAM ti=80h len=20 tot_len=80 ref=1 | payload=0x3ffba80c off=72
[E2.after-free2]    -> p#1 @0x3ffafddc next=0x0     | ROM ti=01h len=60 tot_len=60 ref=1 | payload=0x3f40caec off=-12202736
```

解读：`pbuf_cat` 后头节点 `tot_len` 从 20 涨到 80 且 `len` 保持 20——不变量 I 的实时整形；第二个头经 `pbuf_chain` 挂上同一个 ROM 尾，尾节点 `ref` 1→2；释放第二条链只消掉头节点那 8 字节小壳，ROM 因 ref 归 1 而**稳如泰山**——"减到非零即停"再次兑现。

### 4. 实验 E3：故障注入——打穿天花板并看协议栈自愈

目的与设计说明：按 vanilla 教科书的配方"把池子调小触发 PBUF_POOL 分配失败"在 IDF v6 上无法实施（上限宏已不在 Kconfig 且计数闸门未覆盖 POOL，见 4.3 节），故遵循公约改用**应用层注入**：测试任务持续持有 PBUF_POOL pbuf 不放，等价于"一个赖着不交还 RX 缓冲的恶意消费者"，压力直达真实的唯一天花板——libc 堆。三段推进：

**C1 池上限探针**（预期：cap 不存在，穿越证据）：

```text
[C1] held[15]=0x3ffc0fdc alive past nominal cap #16
[C1] held[31]=0x3ffc701c alive past nominal cap #32
[C1] held[47]=0x3ffcd05c alive past nominal cap #48
[C1] result: 48 consecutive non-NULL PBUF_POOL allocs (nominal PBUF_POOL_SIZE=16)
```

第 17、33、49 个名额安然存活——`PBUF_POOL_SIZE=16` 在这个系统里只是一个不再被读取的化石参数。

**C2 堆耗尽探针**（持续追加直到第一个 NULL）：

```text
[C2] added 126 more pool pbufs consuming 194040 B (1540 B each avg)
[C2] FIRST NULL at total_held=175; now heap_free=1528 largest_blk=704
[C2] confirm starvation, re-alloc -> NULL
```

C1 阶段先持了 48 个，C2 段续持的 126 个新元素又吞掉 194040B，平均每格 **1540B**（从 `heap_caps_get_free_size()` 差分记账得出；全程堆差分折算出的每格均价与之一致）。第 175 次 `pbuf_alloc` 干净利落地返回 NULL、且**无任何崩溃/assert**——pbuf 层的错误传播契约在此生效：NULL 向上冒泡，栈本体安然无恙。此时 `largest_blk=704` 说明堆彻底碎片化到连一格都凑不出。

**C3 高水位网络症状 + 阶梯自愈**：

```text
I (6388) ping_sock: esp_ping_new_session(228): create ping task failed      ← 协议栈组件开始喊疼
[C3] attempt#0: held=174 heap_free=1528 ok=0 fail=10 create_fail=1          ← ping 会话都创建不出来
[C3] attempt#1: freed=20 held=154 heap_free=32332 ok=10 fail=0 create_fail=0 ← 释放 ~31KB 立刻痊愈
[C3] ALL RELEASED: heap_free back to 269492
[C3] recovery ping: ok=10 fail=0 heap_free=269472                            ← 10/10 完全自愈
```

解读三件事：

1. **症状的第一现场不在 ICMP**：堆被榨干的瞬间最先失败的是 esp_ping 的会话创建（它要给 ping 任务分配栈内存），`ok=0 fail=10 create_fail=1` 把"网络故障"与"内存饥饿"的因果链完整摆在台面上——遇到诡异网络瘫痪，先看 heap 水位再抓包，是嵌入式排障的基本素养。
2. **恢复阈值呈阶跃而非渐变**：释放 20 个 pbuf（约 30.8KB）后，下一轮探测立即满分。固定尺寸池元素的世界里，恢复同样是"整格"跳变。
3. **自愈是免费的**：无需重启任何组件，tcpip_thread、netif、ARP 都保持着健康状态，堆一松绑网络立刻满血——pbuf 泄漏之痛从来不在"当下崩掉"，而在"几分钟到几天后慢性窒息"。

> [!note] 真机换算
> 真机 ESP32 上可分配 DRAM 更大且分布更碎（WiFi 启用后 .bss 先吃掉一大块），"第几次分配 NULL"与自愈阈值都会平移，但机制链条——全堆化、无池上限、NULL 冒泡、阶跃恢复——一模一样。

---

## 4.8 小结

- pbuf 用"16 字节结构体 + 外置 payload + next 链 + ref 计数"四件套替代整包大缓冲：`type_internal` 以低字节驻留四类型实测值 `RAM=80h/POOL=82h/ROM=01h/REF=41h`；`tot_len` 沿链递推（`p.tot_len == p.len + p.next->tot_len`，尾节点相等），"队列还是链"看 `tot_len == len` 而非 `next`。
- `pbuf_alloc` 三条分支：ROM/REF 只要一个 MEMP_PBUF 壳；POOL 循环取池元素、超长自动成链、失败事务回滚；RAM 一整块 mem_malloc。`layer` 参数就是预留头空间字节数（IDF 双栈下 IP=54/TRANSPORT=74），实测 `payload_offset == align4(layer)`。
- IDF 全堆化真相（修正 Batch 1 结论）：`MEM_LIBC_MALLOC + MEMP_MEM_MALLOC` 让 PBUF_POOL 物理上落入 libc 堆；memp 的计数闸门补丁只罩住 `MEMP_TCP_PCB`，**PBUF_POOL 的 `PBUF_POOL_SIZE=16` 上限形同虚设**，且该宏无 Kconfig 旋钮、在新上游才改名 `MEMP_NUM_PBUF_POOL`。每个 POOL 元素恒占 ~1536B 整格。
- 释放语义："ref-- 归零才真释放，非零立刻停"；`pbuf_cat` 转移所有权不加计数，`pbuf_chain` 保留双方所有权加计数；泄漏三大惯犯——回调忘 free、REF 入队未拷贝、cat 后二次 free。自查金标准：一组操作前后 heap 水位 delta==0。
- 剥头流水线是一串 `pbuf_remove_header`：ethernet_input(14) → ip4_input(ihl) → udp/tcp_input，payload/len/tot_len 三件套同步迁移，数据零拷贝；对偶的发送方向由 `pbuf_add_header` 认领预留区。
- IDF 的 pbuf 特色在 core 之外：ethernetif 用 66 行 `esp_pbuf_ref.c` 把驱动 L2 缓冲包成 custom PBUF_REF 实现 RX 全程零拷贝（`custom_free_function` 还缓冲给驱动）；WiFi 有零拷贝/拷贝双模态（第 18 章展开）。
- 故障注入实测：应用层持有 174 个 POOL 元素（194KB）把堆打到剩 1.5KB，`pbuf_alloc` 干净返回 NULL、无崩溃；ping 死于会话创建而非 ICMP 处理；释放 20 格（~31KB）即刻满血，自愈免费。

下一章把这些池与堆的故事讲全：vanilla lwIP 的三层内存体系（mem/memp 自定义堆与静态池）、`MEM_SIZE`/`MEM_ALIGNMENT` 的取舍、heap 碎片化的长期行为，以及为什么 IDF 选择了"全部寄人篱下"的堆化路线——带上本章积累的类型与引用知识，去读 `mem.c` 和 `memp_std.h` 的原始形态。见 [[2026-08-26-lwip-deep-dive-ch5-memory-management|第五章]]。
