---
title: "lwIP 深度解析（六）：零拷贝：tcp_write 的 copy 语义与数据通路"
date: 2026-08-26
description: "拆解 tcp_write 的三阶段分段事务：TCP_WRITE_FLAG_COPY 如何在 PBUF_RAM 快照与 PBUF_ROM 引用之间切换、snd_buf/snd_queuelen 两道反压闸、memerr 的全有或全无回滚，以及重传为什么要求应用缓冲存活到 ACK。给出 ESP-IDF 关键事实：LWIP_NETIF_TX_SINGLE_PBUF=1 把 no-copy 在编译期收走，全程两次 memcpy。附 QEMU 实测：COPY 与 no-copy 吞吐逐轮对照（121 vs 122 Mbit）、SND_BUF 5760→28800 窗口实验、2 Mbps 限速读取下 tcp_sndbuf 反压曲线与 ERR_MEM 计数。"
tags: [lwip, network, esp32, esp-idf, qemu, tcp]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 6. **第六章：零拷贝：tcp_write 的 copy 语义与数据通路**

# lwIP 深度解析（六）：零拷贝：tcp_write 的 copy 语义与数据通路

这一章回答三个问题：**一次 `tcp_write()` 到底会不会拷贝我的内存**（答案取决于一个运行时 flag 和一个编译期开关）、**"零拷贝"在 lwIP 里究竟指什么**（发送侧的 no-copy 引用语义 + 接收侧的 pbuf 所有权直通）、**它的代价与前提是什么**（缓冲必须活到 ACK，重传直接引用你的内存）。读完它，你应该能对着源码说清一个字节从应用到网线的每一站谁碰过它，以及什么时候值得为省掉一次 `memcpy` 支付生命周期管理的复杂度。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`~/esp/esp-idf/components/lwip/lwip/src`），核心文件 `core/tcp_out.c`；移植层配置在 `components/lwip/port/include/lwipopts.h`。本章所有性能数字来自 QEMU (openeth + SLIRP) 实测，方法与次数在各实验节标明。

---

## 6.1 核心问题三连

### 1. 一次 tcp_write 会拷贝内存吗？

看两处开关。**运行时**：`apiflags` 里有没有 `TCP_WRITE_FLAG_COPY`（`lwip/tcpbase.h`，值 `0x01`）——不给这个 flag 就是 no-copy 模式，协议栈只存指针不搬数据。**编译时**：`LWIP_NETIF_TX_SINGLE_PBUF` 为 1 时 `tcp_write()` 入口第一件事就是 `apiflags |= TCP_WRITE_FLAG_COPY;` 把你的选择覆盖掉（`tcp_out.c` 入口段）：

```c
#if LWIP_NETIF_TX_SINGLE_PBUF
  /* Always copy to try to create single pbufs for TX */
  apiflags |= TCP_WRITE_FLAG_COPY;
#endif
```

Vanilla lwIP 这个宏默认 0（`opt.h`：`LWIP_NETIF_TX_SINGLE_PBUF 0`），no-copy 是真实可用的模式；**ESP-IDF 移植层把它硬编码为 1**（`port/include/lwipopts.h`：`#define LWIP_NETIF_TX_SINGLE_PBUF 1`），于是在 IDF 上 no-copy 的代码分支还在编译产物里，但你永远走不到。这是 ESP-IDF lwIP 最容易被忽略的行为差异之一，6.6 节给完整对照。

### 2. "零拷贝"到底指什么

lwIP 的零拷贝是**栈内 zero-copy**，不是 DMA 意义上的，更不是 `sendfile()` 那种跨设备直达：

| 方向   | 零拷贝指                                                                         | 载体                               |
| ------ | -------------------------------------------------------------------------------- | ---------------------------------- |
| 发送侧 | 不把应用数据 memcpy 进协议栈自有缓冲，只把指针装进引用型 pbuf（`PBUF_ROM`）      | seg 队列里的 pbuf 直接指向应用内存 |
| 接收侧 | 收到的数据装载在 pbuf 链里一路向上交付，raw API 回调拿到的是**所有权**而不是副本 | 应用要么释放它，要么转发它         |

两端共用同一套资本：pbuf 的**类型系统**（第四章的基础设施）。`PBUF_RAM` 是栈自己的堆内快照，`PBUF_ROM` 只是一个"指向外部数据的头结构"。

### 3. 代价与前提

零拷贝不是免费的：

- **生命周期契约**：引用模式下，从 `tcp_write()` 返回到对端 ACK 到达之前，这块内存的内容与位置都不能变——因为 TCP 重传要原样再发一遍，而重传发的就是你那块内存；
- **反压显式化**：不再有阻塞语义兜底，发送缓冲满了就是 `ERR_MEM` 返回值，应用必须自己安排重试节奏（`sent` 回调 / `poll` 定时器）；
- **管理复杂度**：`copy` 模式下函数一返回缓冲就可以复用，`no-copy` 模式下你要自己记账哪些块已经 ACK 归还。

这三条的成本收益账，6.5 节用数字算清。

---

## 6.2 发送通路全图：一个字节去往网线的完整旅程

以 ESP-IDF 默认配置（`LWIP_NETIF_TX_SINGLE_PBUF=1`）为基准，途中每一个碰过数据的位置标注「**拷贝发生在这里 / 没有拷贝**」：

```text
 应用 buffer
     │
     │ tcp_write(pcb, buf, len, apiflags)               ← 全部跑在 tcpip_thread（第十三章）
     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ ① tcp_write() 分段事务                                    core/tcp_out.c │
│    COPY:   MEMCPY(seg_pbuf_payload, arg, len)      【拷贝 #1】          │
│            → 数据进 PBUF_RAM（栈所有），随后 app buffer 可自由复用        │
│    NOCOPY: ((struct pbuf_rom*)p2)->payload = arg+pos【无拷贝】           │
│            → 头部小 pbuf(PBUF_RAM) + 数据 pbuf(PBUF_ROM) pbuf_cat 挂链   │
│    闸门:   len>snd_buf 或 snd_queuelen 超限 → ERR_MEM（不动 pcb 状态）    │
└──────────────┬──────────────────────────────────────────────────────────┘
               ▼  pcb->unsent / unacked seg 链（环形账本：snd_buf 计字节，
│                snd_queuelen 计 pbuf 个数）
│
│ ② tcp_output()                                             core/tcp_out.c
│    while (snd_nxt < snd_wnd && cwnd 允许) 出队成段：
│      - 填 TCP 头 seqno/ackno/wnd —— 写进头部 pbuf         【无拷贝】
│      ▼
│ ③ ip4_output_if → etharp_output                             netif 层
│      - 原地填 IP 头、前插以太网帧头（分配时已留 headroom）【无拷贝】
│      ▼ netif->linkoutput = ethernet_low_level_output
│                                                    esp_netif/lwip/netif/ethernetif.c
│      - 单节点 pbuf：esp_netif_transmit(payload) 直传       【无拷贝】
│      - 多节点链：pbuf_copy 线性化                          【拷贝】(IDF 下因①强制
│                                                                 COPY 而永远单节点)
│      ▼
│ ④ openeth MAC emac_opencores_transmit()
│                                      esp_eth/src/openeth/esp_eth_mac_openeth.c
│      MEMCPY(tx_desc_buf, buf, will_write)                 【拷贝 #2】
│      → 写进描述符指向的 DMA 缓冲（QEMU 里这步模拟真实网卡 DMA）
│      ▼
│ QEMU SLIRP ──► 宿主机 socket
```

两条路径的全景差异一眼可见：

|                                                     | 全程 memcpy 次数（每 MSS 数据）      | ESP-IDF 实际路径 |
| --------------------------------------------------- | ------------------------------------ | ---------------- |
| COPY 模式                                           | ① 一次 + ④ 一次 = **2 次**           | 就是这条路       |
| NOCOPY 模式（vanilla + 支持 scatter-gather 的驱动） | **0 次**（只有头部 pbuf 的小额写入） | 编译期不可达     |

ESP-IDF 上真实跑的是"COPY×N"，其中第 ④ 站是驱动边界上的必然拷贝（对应真机上是 DMA 描述符缓冲）；第 ① 站这一次才是 `TCP_WRITE_FLAG_COPY` 想省掉、但被 `LWIP_NETIF_TX_SINGLE_PBUF` 锁死的那次。

> [!note] 系列暗线 A
> 以上所有站点都活在同一个 `tcpip_thread` 里：`tcp_write` 由你的回调上下文调用（raw API 必须借道 `tcpip_callback` 投递进来，见 6.7 的工程写法），网络事件驱动各站接力。Part III 的邮箱模型会解释为什么 raw API "不允许跨线程直接调"。

---

## 6.3 tcp_write 语义深拆

### 1. 入口闸门：tcp_write_checks()

任何一次 `tcp_write()` 先过三关（`tcp_out.c` 的 `tcp_write_checks()`）：

```c
/* 1) 连接状态必须在可发数据的四个状态之一 */
if ((pcb->state != ESTABLISHED) && (pcb->state != CLOSE_WAIT) &&
    (pcb->state != SYN_SENT) && (pcb->state != SYN_RCVD))
        return ERR_CONN;

/* 2) 字节信用额度 */
if (len > pcb->snd_buf)
        return ERR_MEM;                      /* 并置 TF_NAGLEMEMERR */

/* 3) 队列物品数上限 */
if (pcb->snd_queuelen >= LWIP_MIN(TCP_SND_QUEUELEN, TCP_SNDQUEUELEN_OVERFLOW + 1))
        return ERR_MEM;
```

这里藏着两个维度完全不同的账本：

- `pcb->snd_buf`——**剩余可写字节数**（`tcpwnd_size_t`）。`tcp_write()` 成功后 `snd_buf -= len`，ACK 后归还。读它的公开接口是 `tcp_sndbuf()`（`lwip/tcp.h`：`#define tcp_sndbuf(pcb) (TCPWND16((pcb)->snd_buf))`）。编译期上限即 `TCP_SND_BUF`。
- `pcb->snd_queuelen`——**队列上挂着的 pbuf 个数**。每个 pbuf 一个名额。编译期上限 `TCP_SND_QUEUELEN` 按 opt.h 公式由另两者推导：`(4 * TCP_SND_BUF + TCP_MSS - 1) / TCP_MSS`。IDF 默认 5760/MSS1440 下等于 16（我们实验固件开机自报的实测值，见 6.7）。

两个上限的分工很有讲究：前者管**字节洪水**，后者防**碎片化攻击自己**——no-copy 模式下每个小块都会变成一个独立 pbuf 占一个名额，小消息高频写入会先撞碎在 queuelen 这堵墙上，哪怕字节数远没满。

第二关里的 `TF_NAGLEMEMERR` 值得点名：置位后 Nagle 会暂缓继续凑包，防止"缓冲半满却一直写不进去"的死循环消耗 CPU。这是个防呆位，不是错误状态本身。

### 2. 三阶段分段事务：全有或全无

通过闸门后进入正体。`tcp_out.c` 用一段注释明说了设计意图："我们可能在任何时候耗尽内存；此时必须返回 ERR_MEM 且**不改变 pcb 的任何状态**。" 所有改动先落在局部变量上，最后统一提交：

```text
Phase 1  尾部填充   : 上一次 tcp_write 因 TCP_OVERSIZE 预留在 unsent 尾段的空隙，
                      这次的数据直接补进去（唯一一处"写旧缓冲"而非新建 pbuf 的路径）
Phase 2  续接尾段   : unsent 最后一段还有富余空间时，为本次数据造一个新 pbuf
                      cat 到该段尾部（COPY→RAM pbuf；NOCOPY→ROM pbuf 或扩长相邻 ROM）
Phase 3  新建段落   : 剩余数据按 mss_local 切片造全新 seg，串成本次 queue
提交(commit)       : pcb->unsent 接上 queue；snd_lbb += len;
                     snd_buf -= len;  snd_queuelen = queuelen;
失败(memerr)       : pbuf_free(concat_p); tcp_segs_free(queue);
                     （pcb 未动分毫）return ERR_MEM;
```

对应用层的含义是漂亮的原子性：**`tcp_write()` 要么整批入队，要么一个字节都没入队**。不存在"写了一半成功一半"需要你自己清理的中间态。这也意味着你不必为部分失败做簿记——收到 `ERR_MEM` 就整块等下次机会。

`mss_local` 也有细节：`min(pcb->mss, snd_wnd_max/2)`——本次连接实际观察过的最大窗口的一半，比静态 MSS 更保守，避免在对端窗口很小时切出永远发不出去的超长段。

### 3. NOCOPY 的全部机制：一行指针赋值

Phase 3 中 no-copy 分支的核心就这几行（剥掉校验和杂音）：

```c
if ((p2 = pbuf_alloc(PBUF_TRANSPORT, seglen, PBUF_ROM)) == NULL)
        goto memerr;
/* reference the non-volatile payload data */
((struct pbuf_rom *)p2)->payload = (const u8_t *)arg + pos;

/* Second, allocate a pbuf for the headers. */
if ((p = pbuf_alloc(PBUF_TRANSPORT, optlen, PBUF_RAM)) == NULL) { ... }
pbuf_cat(p/*header*/, p2/*data*/);
```

所谓零拷贝：**给栈一个描述符，描述符里的 payload 指针指向你的内存**。注意两点：

1. 即使 no-copy，也仍要从堆里拿两个东西——数据描述符（`PBUF_ROM`，几乎零成本）和一个放 TCP/IP 头的小 `PBUF_RAM`。零拷贝省的是数据搬运，不是全部内存操作。
2. 为什么敢用 `PBUF_ROM` 而不是看起来更语义化的 `PBUF_REF`？源码注释给了理由：被引用的数据至少在发出乃至 ACK 之前都必须有效（重传要用），这本身就是 `ROM` 语义——不可变、已固化。`PBUF_REF` 是留给"瞬时有效、可能易变"缓冲的弱引用类型，这条路径不需要也不应该用。（顺带验证第四章伏笔：`pbuf_ref` 增加的是引用计数，而这里连计数都不必加——因为队列对这段数据的独占性由契约保证。）

Phase 2 还有一个精巧的相邻优化：如果新数据地址恰好紧跟着尾段最后一个 ROM pbuf——

```c
if (((p->type_internal & (PBUF_TYPE_FLAG_STRUCT_DATA_CONTIGUOUS |
                          PBUF_TYPE_FLAG_DATA_VOLATILE)) == 0) &&
    (const u8_t *)p->payload + p->len == (const u8_t *)arg)
        extendlen = seglen;      /* 不新建 pbuf，直接把旧引用区间延长 */
```

——连 ROM 描述符都省了，直接把上一个引用的长度字段改大。这精确匹配"应用按顺序向一个大缓冲追加、每写一块就 `tcp_write` 一块"的生产模式。

### 4. 两个 apiflags 的完整语义

- `TCP_WRITE_FLAG_COPY`（0x01）：见 6.3.1~6.3.3。IDF 下永远被置上。
- `TCP_WRITE_FLAG_MORE`（0x02）：抑制在本次最后一段上打 PSH 标志，且影响 Phase 2/3 是否预留 oversize 余量——设了 MORE 说明"我马上还要写"，预分配就可以慷慨些（`tcp_pbuf_prealloc()` 的启发式：MORE 为真或 Nagle 正在攒包时多留余量）。典型用法是把一条大消息切成多次 write 又不想让中间块触发推送。

### 5. copy 模式的拷贝时机与失败分支

COPY 分支每次都走 `tcp_pbuf_prealloc()` 新开 `seglen + optlen` 的 RAM pbuf，随即 `TCP_DATA_COPY2(...)`——宏展开后就是一个 `MEMCPY(dst, src, len)`（`lwip/opt.h`：`#define MEMCPY(dst,src,len) memcpy(dst,src,len)`；若开启 checksum-on-copy 则换成"边拷边算校验和"版本，IDF 默认未开启：`LWIP_CHECKSUM_ON_COPY=0` → `TCP_CHECKSUM_ON_COPY=0`，见 `priv/tcp_priv.h:251`）。**拷贝时机就是 enqueue 当时**，此后即使应用立刻覆写原缓冲也无碍——栈里已经是快照。

三个失败分支最终殊途同归到同一个 `memerr` 标签：prealloc/pbuf_alloc 失败（堆耗尽，IDF 全堆化所以就是 libc 堆紧张）、queuelen 超限回滚检查失败、segment 创建失败。这也是 `tcp_sndbuf()` 读数的正确用法所在：先看额度再决定写多少，能显著降低白扣 ERR_MEM 的概率——但注意 6.7 实验 C 我们刻意反其道而行来观测反压波形。

### 6. 低水位 TCP_SNDLOWAT：另一套世界的“可写”判定

与 `snd_buf` 相关的还有一个容易和队列上限混淆的旋钮：`TCP_SNDLOWAT`（opt.h 默认公式 `min(max(SND_BUF/2, 2*MSS+1), SND_BUF-1)`）。它不参与 raw API 的任何判定——`tcp_write()` 只看额度是否装得下本次 len；它的作用域是 **socket/netconn 层的“可写”语义**：发送缓冲中的未确认字节低于该水位时，select/poll 才报告可写、非阻塞 send 才恢复放行。换句话说：raw 世界里反压的唯一词汇就是 `ERR_MEM` + 回调驱动；netconn/socket 世界把同一份账本翻译成了阻塞/唤醒——两边读的是同一个 `pcb->snd_buf`，语法的分野在 13 章的邮箱模型里能找到结构根源。

---

## 6.4 接收通路：pbuf 所有权规则

发送侧讨论所有权交接少、讨论生存期多；接收侧正好反过来——**pbuf 一旦交到你手上，栈就完全放手**。raw API 的规则一句话：**回调收到的 pbuf 你必须处理掉——要么 `pbuf_free()`，要么转手挂到自己继续处理的结构里**，绝不能既不释放也不保存地把返回值当"临时借用"。`tcp_recv` 回调签名的第四参数把整个链交给你：

```c
err_t my_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err);
/* p == NULL 表示对端关闭连接 */
```

几层 API 对同一份数据的处理差异（15/16 章展开，此处浅讲）：

| API 层           | 数据载体             | 拷贝次数（相对 pbuf 内的原数据）     | 释放责任       |
| ---------------- | -------------------- | ------------------------------------ | -------------- |
| raw (`tcp_recv`) | pbuf 链本体直通      | 0                                    | 应用           |
| netconn          | 经邮箱投递到应用任务 | 0（指针移交），消费后才 `tcp_recved` | api_msg 层代管 |
| socket (`recv`)  | `recv(buf)` 用户缓冲 | **1 次 memcpy**（pbuf → 用户区）     | 协议栈自动     |

两个容易被忽略的规则：

1. **跨多个 pbuf 取数**：一帧 TCP 载荷可能横跨 pbuf 链上若干节点（长度不够、OOSEQ 展开、纯 ROM 引用混合都有可能），遍历 `q->next` 逐节点取 `q->payload/q->len` 才是通用姿势，别假设首节点的 `tot_len == payload 可读长度`。
2. **限流靠你不取**：回调里"不消费但也不 free"会让栈把包挂在 `pcb->refused_data` 上并收缩接收窗口（`tcp_in.c` 明确写着 "keep incoming packet, because pcb is \"full\""），这就是接收侧的反压信号—— analogous to 发送侧的 `ERR_MEM`。socket 层把它翻译成了邮箱深度（`CONFIG_LWIP_TCP_RECVMBOX_SIZE`，默认 6）满则丢包重传的重量级机制，效率差得多——这也是 raw API 吞吐占优的另一个来源。

---

## 6.5 什么时候值得零拷贝

### 1. 收益模型

每 1460 字节（MSS）最多省一次 ≤1460B 的 memcpy。粗算量级：ESP32 单核 memcpy 约 100~200 MB/s（240MHz，缓存命中场景），跑满 100 Mbps 持续吞吐时，纯数据拷贝约占一颗核的 **5%~12%**；再加上 copy 模式额外的分配/释放路径与 cache pollution，实测差距通常在十几个百分点的量级（高度依赖平台与负载特征；注意本章未能在 IDF 上给出该对照的实测值——如实验 A 所示，IDF 把两条路径编译期合并了，此估计只对 vanilla/no-copy 可达的平台有意义）。结论方向：**带宽越高、主频越低、CPU 越闲不下来，零拷贝越划算**；写热文件这种本来就要生成数据的应用，往往瓶颈根本不在这一层。

### 2. 陷阱清单（每条都能静默炸）

1. **生命周期悬空**：no-copy 引用的缓冲如果在 ACK 前被释放/挪动，栈手里握着的是野指针。正确姿势是用静态池/对象池，并在 `sent` 回调累计的 ACK 字节数到达时才归还。
2. **内容变更**：释放之前就修改内容 = 重传时发出改过的数据 = 字节流损坏，而且大概率能通过 TCP 校验和（因为发出的那一刻内容还是对的），属于最难查的一类事故。
3. **free 时机绑定错了事件**：`tcp_write()` 返回 ≠ 可以回收（数据只是进了队列）；`tcp_output()` 完成 ≠ 可以回收（没 ACK 可能重传）。**唯一正确的时钟是 `sent()` 回调累计的 acked 字节数**。
4. **小块高发**：小消息写 no-copy，每个片段一个 ROM pbuf 吃掉一个 `snd_queuelen` 名额，还会绕过 oversize 合并优化——队列额度先于字节数耗尽。zero-copy 请配大块。
5. **memcpy 白省**：应用在 `tcp_write` 前一刻才把数据组装到临时缓冲、随后又要复用该缓冲——这等于被迫自己实现一份"等待安全"逻辑，零拷贝没有净赚。

### 3. 重传为什么逼出了这些约束：seg 引用 vs 拷贝快照

这是 no-copy 语义的地基，值得从源码角度钉死。重传（RTO 或 dup-ACK 触发的 fast retransmit）的实现思路都是：**从 `unacked`/`unsent` 队列里找到那个 seg，重新交给 `tcp_output()` 输出**。协议栈不会也不会有机会"恢复"当年那段数据——

- **COPY 模式**：seg 里的 pbuf 指向栈自有的 RAM 快照，那份拷贝是 enqueue 时刻定格的，无论应用之后怎么折腾原缓冲，重传内容永远正确。代价是这份冗余存储本身就挂在 snd_buf 额度里。
- **NOCOPY 模式**：seg 里的 ROM pbuf **就是应用内存本身**。第一次发送与第 N 次重传读的是同一块地址。协议栈没有任何防御措施，契约完全在你这边：这段数据在 ACK 前必须恒定不变。6.3.3 里那句"we can safely use PBUF_ROM instead of PBUF_REF"的安全性声明，成立条件全部由使用者的生命周期纪律支付。

> [!warning] 一句话记忆
> COPY 是"寄快照"，NOCOPY 是"押房产证"。寄快照弄丢了顶多重拍；押了房产证之后装修房子，重传的每一包都在广播你的新墙颜色。

---

## 6.6 Vanilla lwIP 与 ESP-IDF lwIP 对照

围绕 tcp_write 发送路径逐项对照（均经 grep 实核，非凭记忆）：

| 维度                        | Vanilla lwIP 2.2.0-dev                         | ESP-IDF v6.0.2 移植                                                                                                                    |
| --------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `MEMCPY`                    | `memcpy` 直定义（opt.h）                       | 同（IDF 未替换）                                                                                                                       |
| `TCP_MSS` 默认              | 536（保守值）                                  | Kconfig `CONFIG_LWIP_TCP_MSS` 默认 **1440**（范围 536~1460）                                                                           |
| `TCP_SND_BUF` 默认          | `2 * TCP_MSS` = **1072 B**                     | Kconfig `CONFIG_LWIP_TCP_SND_BUF_DEFAULT` 默认 **5760**（= 4×MSS，范围 2440 起）                                                       |
| `TCP_WND` 默认              | `4 * TCP_MSS` = 2144                           | `CONFIG_LWIP_TCP_WND_DEFAULT` 默认 **5760**                                                                                            |
| `TCP_SND_QUEUELEN`          | 公式 `(4*SND_BUF+MSS-1)/MSS` → 1072/536 下 ≈ 8 | 同公式，5760/1440 下 = **16**（28800 配置下 = 80，实验实测）                                                                           |
| `LWIP_NETIF_TX_SINGLE_PBUF` | 默认 0，no-copy 可达                           | **硬编码 1** → `tcp_write` 强制 COPY（本文主角）                                                                                       |
| `TCP_OVERSIZE`              | 默认 `TCP_MSS`                                 | menuconfig 三选一：`CONFIG_LWIP_TCP_OVERSIZE_MSS / QUARTER_MSS / DISABLE`                                                              |
| checksum-on-copy            | `LWIP_CHECKSUM_ON_COPY` 开关（默认 0）         | 未接 Kconfig，同样默认 0 → 拷贝即纯 memcpy                                                                                             |
| 窗口缩放                    | `LWIP_WND_SCALE` + `TCP_RCV_SCALE`             | menuconfig `CONFIG_LWIP_WND_SCALE`（不开则 SND/WND 上限 65535）                                                                        |
| linkoutput 契约             | pbuf 链交给驱动，鼓励 scatter-gather           | esp_netif `ethernet_low_level_output()` 为单节点提供快路、链则线性化；openeth 驱动最终 memcpy 进描述符缓冲                             |
| core 补丁                   | —                                              | 存在但不在此路径：`ESP_LWIP` 条件改造集中在 RTO 背退（`LWIP_TCP_RTO_TIME`）、NAPT 挂点、按需定时器；`tcp_out.c` 本体的分段事务未被改编 |

一个容易误读的点要先澄清：`TX_SINGLE_PBUF=1` 不是 Espressif 随手拧大的旋钮——ESP32 系大部分板载以太网/SPI-Ethernet 驱动的 DMA 不支持 scatter-gather，与其在每个驱动里线性化，不如在源头保证单节点 pbuf。代价就是把 `TCP_WRITE_FLAG_COPY` 变成了摆设。若你在 IDF 上确实需要 no-copy（例如已换用支持 SG-DMA 的 MAC 并自行实现 linkoutput），改造点就在 `port/include/lwipopts.h` 这一行的编译期决策，而不是运行时 flag。

---

## 6.7 实验：吞吐定量、窗口调优与反压故障注入

工程：`practice/lwip-ch06-zero-copy-tcp-write/`（基于 ch3 联网模板：openeth bring-up + esp_netif + DHCP；raw API TCP 发送端）。主机端脚本 `host/recv_counter.py` 同时负责高速收数与限速收数。

实验方法学三件套，全文数字均由此产生：

1. **双计时口径**：guest 内 `esp_timer_get_time()` 从建连到"全部字节 ACKed"；主机端 Python `time.monotonic()` 从收到首字节到 EOF。两侧互相印证。
2. **数据完整性**：guest 与主机各自对字节流累加 Fletcher-16 校验，逐轮比对 digest（防"测了个寂寞"——吞吐对但数据错）。
3. **重复次数**：每组设置 3 轮，COPY/NOCOPY 相邻交错调度以摊平台温漂；结果报告均值与全样本。

环境：Fedora 16 核主机 + qemu-system-xtensa (Espressif fork)，`-nic user,model=open_eth`（SLIRP 用户态网络，无需 hostfwd——本实验是 guest 出方向直连 `10.0.2.2` 即宿主机回环）。目标芯片 esp32，`CONFIG_LWIP_TCP_MSS=1440`。

构建与运行（完整复现命令）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch06-zero-copy-tcp-write
idf.py set-target esp32 && idf.py build
idf.py qemu monitor < /dev/null || true        # 生成 qemu_flash.bin/qemu_efuse.bin

python3 host/recv_counter.py --port 8006 --conns 6 > host_rx_fast.log &
python3 host/recv_counter.py --port 8007 --conns 1 --rate-mbps 2 --read-size 8192 \
        > host_rx_slow.log &

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 120 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot > run_all.log 2>&1
```

固件行为：DHCP 拿到 IP 后经 `tcpip_callback()` 进入 tcpip 线程，先跑 6 轮 ×10 MB 的吞吐基准（端口 8006），结束后自动进入反压阶段（端口 8007，总量 16 MB、15 s 硬超时、周期采样打印）。所有调度以 `sys_timeout` 自续，遵守 raw API 线程纪律。

驱动整个发送端的核心只有两个函数（节选自 `main/lab_main.c`，注释即文档）：

```c
/* 发送泵：额度内按 CHUNK 喂栈；ACK 之后由 sent 回调再次触发 */
static err_t pump(void)
{
    int calls = 0;
    while (b->written < b->total && calls < PUMP_MAX_CALLS) {
        u16_t len = /* min(剩余量, CHUNK, 模式缓冲边界) */;
        err_t err = tcp_write(b->pcb, s_pat + b->pat_off, len, apiflags);
        if (err != ERR_OK) { b->err_mem++; break; }   /* 额度耗尽：撤退 */
        b->written += len;
        calls++;
    }
    if (calls > 0) tcp_output(b->pcb);   /* 立即尝试外送（Nagle 会再把关） */
    return ...;
}

static err_t bench_sent_cb(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
    b->acked += len;                     /* ACK 时钟：no-copy 缓冲的释放依据 */
    if (b->acked >= b->total) { report(); tcp_close(pcb); return ERR_OK; }
    pump();                              /* 归还的额度立即回填 */
    return ERR_OK;
}
```

两个工程细节值得点名：`s_pat[]` 是 64 KB 的确定性模式环形缓冲——它必须**远大于任意时刻的在途字节**（本实验最大配置 28800 B），这样才能保证 no-copy 引用区间被覆写前一定早已 ACK 归还；而 `bench_sent_cb` 里累计的 `acked` 正是 6.5 节陷阱 3 所说“缓冲可回收的唯一合法时钟”。

### 实验 A：COPY vs no-copy 定量对比（默认 5760 配置）

固件对同一连接分别携带/不携带 `TCP_WRITE_FLAG_COPY` 发送 10485760 字节。run.log 摘录：

```text
CH06-FACT LWIP_NETIF_TX_SINGLE_PBUF=1
CH06-FACT CONFIG_LWIP_TCP_SND_BUF_DEFAULT=5760
CH06-FACT CONFIG_LWIP_TCP_MSS=1440
CH06-FACT TCP_SND_QUEUELEN=16 CHUNK=2880 PATLEN=65536 TOTAL=10485760
CH06-BENCH mode=COPY   run=1 sent=10485760 us=693983 mbit=120.88 err_mem=7355 digest=3c32
CH06-BENCH mode=NOCOPY run=1 sent=10485760 us=691782 mbit=121.26 err_mem=7355 digest=3c32
CH06-BENCH mode=COPY   run=2 sent=10485760 us=713010 mbit=117.65 err_mem=7355 digest=3c32
CH06-BENCH mode=NOCOPY run=2 sent=10485760 us=680794 mbit=123.22 err_mem=7355 digest=3c32
CH06-BENCH mode=COPY   run=3 sent=10485760 us=672280 mbit=124.78 err_mem=7355 digest=3c32
CH06-BENCH mode=NOCOPY run=3 sent=10485760 us=686741 mbit=122.15 err_mem=7355 digest=3c32
```

主机端逐连接核对（顺序与 guest 侧一一对应）：

```text
HOST-DONE conn#1 ... bytes=10485760 dur=0.695s mbit=120.77 digest=3c32
HOST-DONE conn#2 ... bytes=10485760 dur=0.694s mbit=120.82 digest=3c32
HOST-DONE conn#3 ... bytes=10485760 dur=0.713s mbit=117.61 digest=3c32
HOST-DONE conn#4 ... bytes=10485760 dur=0.681s mbit=123.18 digest=3c32
HOST-DONE conn#5 ... bytes=10485760 dur=0.672s mbit=124.75 digest=3c32
HOST-DONE conn#6 ... bytes=10485760 dur=0.687s mbit=122.12 digest=3c32
```

| 轮次     | 模式   | guest 口径 Mbit | 主机口径 Mbit |
| -------- | ------ | --------------- | ------------- |
| 1        | COPY   | 120.88          | 120.77        |
| 2        | NOCOPY | 121.26          | 120.82        |
| 3        | COPY   | 117.65          | 117.61        |
| 4        | NOCOPY | 123.22          | 123.18        |
| 5        | COPY   | 124.78          | 124.75        |
| 6        | NOCOPY | 122.15          | 122.12        |
| **均值** | COPY   | **121.10**      | 121.04        |
| **均值** | NOCOPY | **122.21**      | 122.04        |

**解读**：两组均值差约 1%，落在本组轮间波动以内——**在 ESP-IDF 上 COPY 与 no-copy 没有区别**。这不是测量失效，而是 6.1 节那个编译期开关的直接后果：`LWIP_NETIF_TX_SINGLE_PBUF=1` 已经把两条路径合并成了一条（证据：run.log 第一行自报的宏值）。本轮实验的价值恰恰在于把它量化坐实：想在 IDF 上重启零拷贝之争，先得改 `lwipopts.h`；vanilla 用户请在自己的平台上重跑本节方法（每轮总量的挑选原则：单轮耗时 ≥1 s，让计时误差退场）。另外三个旁证：双口径偏差稳定 <0.5%；六个 digest 全部一致；`err_mem` 在两种模式下同为 7355 次（泵对满缓冲的无差别试探，见实验 C 的语义）。

> [!warning] 开发过程中踩到的真实坑：忘注册 tcp_sent() 的后果
> 本工程第一版漏调了 `tcp_sent(pcb, bench_sent_cb)`。现象极具迷惑性：连接正常建立，但主机端接收速率暴跌至涓流——单连接 26 s 仅收到约 76 KB（折合 ~23 kbit/s，与本节正常值差着三个数量级以上）。原因与 6.3.1 的机制严丝合缝：ACK 正常到达、`snd_buf` 正常归还，但没有任何回调去触发补充写入，传输只能靠 2 s 一次的 `tcp_poll` 兜底泵推。教训：**raw API 的推进事件一个都不能少**，协议栈不会替你补发生产者。排这类问题时，周期打印 `tcp_sndbuf()/tcp_sndqueuelen()`（本工程内置 1 s 采样）是最短诊断路径。

### 实验 B：调大 TCP_SND_BUF/TCP_WND 的吞吐影响

`sdkconfig.defaults` 增加 `CONFIG_LWIP_TCP_SND_BUF_DEFAULT=28800` 与 `CONFIG_LWIP_TCP_WND_DEFAULT=28800`（即 20×MSS），删除 sdkconfig 重新生成后同法复测。固件开机自报的变化：

```text
CH06-FACT CONFIG_LWIP_TCP_SND_BUF_DEFAULT=28800
CH06-FACT CONFIG_LWIP_TCP_WND_DEFAULT=28800
CH06-FACT TCP_SND_QUEUELEN=80 CHUNK=2880 PATLEN=65536 TOTAL=10485760
```

| 轮次 | 模式   | guest Mbit | 备注                                             |
| ---- | ------ | ---------- | ------------------------------------------------ |
| 1    | COPY   | 113.30     |                                                  |
| 2    | NOCOPY | 122.28     |                                                  |
| 3    | COPY   | 127.33     |                                                  |
| 4    | NOCOPY | 47.97      | 异常点：主机同轮 47.96，确认是环境抖动非测量错位 |
| 5    | COPY   | 120.93     |                                                  |
| 6    | NOCOPY | 131.26     |                                                  |

剔除异常点后 COPY 均值 120.52、NOCOPY 均值 126.77——**与默认配置（≈121）基本持平，×5 倍缓冲没有买到吞吐**。为什么？带宽-时延积的视角给出解释：SLIRP/OpenCores 路径的往返时延在亚毫秒量级，5760 B 在途足以喂饱观测到的 ~120 Mbit 吞吐（5760×8 / RTT≈亚毫秒 ≈ 90~180 Mbit 区间）；把发送窗放大五倍，第一步撞上的不再是窗口限制，而是 SLIRP 用户态转发与 guest 指令仿真构成的下一个瓶颈——TCP 生涯的常规剧本：**解除一个限制只会暴露下一个**。

调优建议表（把上面的原理翻成动作）：

| 场景                             | 建议                                                          | Kconfig 名                                                                                       |
| -------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| 吞吐不足且观测到对端窗口频繁回零 | 先调大 `TCP_WND` 至 ≥ 带宽×RTT（BDP），SNDBUF 同步 ≥ 2×BDP    | `CONFIG_LWIP_TCP_WND_DEFAULT` / `CONFIG_LWIP_TCP_SND_BUF_DEFAULT`（不开 WND_SCALE 时上限 65535） |
| 只调大 SNDBUF 不动窗口           | 几乎无效：发送受 cwnd 与对端 rwnd 双门控                      | 同上，成对调整                                                                                   |
| 大窗口后内存吃紧                 | 换窗口缩放而非暴力加窗；注意 `TCP_WND` 语义变为缩放后的总空间 | `CONFIG_LWIP_WND_SCALE` + `CONFIG_LWIP_TCP_RCV_SCALE`                                            |
| 接收邮箱排队丢包                 | RECVMBOX ≥ WND/MSS + 2                                        | `CONFIG_LWIP_TCP_RECVMBOX_SIZE`（默认 6）                                                        |

局限说明（照实）：SLIRP 平台的 ~120 Mbit 天花板是仿真的伪影，真机以太网/Wi-Fi 的瓶颈分布不同；上述建议的**方向**（BDP 决定窗口、成对调整、先量后调）在任何平台成立，**数值**必须在目标硬件上用 iperf 类负载重新标定（第 24 章的方法论）。

### 实验 C：反压故障注入——tcp_sndbuf 曲线与 ERR_MEM 行为

**注入方式**：同一固件的反压阶段（发送预算 16 MB，15 s 硬超时，100 ms 节拍的持续重试泵），主机端改为**速率桶限速读取**：

```bash
python3 host/recv_counter.py --port 8007 --conns 1 --rate-mbps 2 --read-size 8192
```

接收器按"已收字节 / 目标速率"计算时间预算、超支即 sleep 补差，从而让宿主机一侧的消费能力（≈2 Mbps）远低于管道容量（实验 B 实测 ~120 Mbit）。上游缓冲（SLIRP 内部缓冲 + 主机内核 rcvbuf）会先吸收一波，然后压力沿"内核←slirp←对端通告窗口←guest 协议栈"一路反弹回来。

发送侧水泵满负荷灌入，guest 每 250 ms 自采样打点（sndbuf = `tcp_sndbuf()` 即当前剩余发送额度，qlen = `tcp_sndqueuelen()`，err_mem = `tcp_write()` 非 OK 返回的累计次数）。run.log 曲线摘录（完整曲线见 `logs/run_bigwin_build.log`）：

```text
CH06-BP t=247ms   sndbuf=2144 qlen=19 written=4194304 acked=4167648 err_mem=2269
CH06-BP t=497ms   sndbuf=0    qlen=20 written=4439872 acked=4411072 err_mem=2442
CH06-BP t=3497ms  sndbuf=616  qlen=20 written=4439872 acked=4411688 err_mem=2474
CH06-BP t=7498ms  sndbuf=2856 qlen=19 written=5838464 acked=5812520 err_mem=3412
CH06-BP t=11497ms sndbuf=1440 qlen=19 written=6602560 acked=6575200 err_mem=3884
CH06-BP t=14497ms sndbuf=1512 qlen=19 written=7240640 acked=7213352 err_mem=4256
CH06-BPSTOP elapsed_ms=14997 written=7240640 acked=7213352 err_mem=4262 sndbuf_min=0 mbit=3.86
```

主机端终局核对：

```text
HOST-DONE conn#1 addr=127.0.0.1:43680 bytes=7213352 dur=28.852s mbit=2.00 digest=21b0
```

**现象解读（五个可精确对表的看点）**：

1. **倾泻期**：第一个采样点（t=247 ms）written 已冲到 4.19 MB——上游缓冲吞下了大量数据，此时尚有残喘（sndbuf=2144 接近耗尽）。
2. **钳制期**：t=497 ms 起 `sndbuf` 长期钉死在 0~few-KB、`written` 卡在 4439872 动弹不得——发送额度归零，`tcp_write()` 全部返回 `ERR_MEM`，err_mem 以 ~10 次/秒累积（等于重试泵 100 ms 节拍 × 每拍 1 次失败尝试）。
3. **步进跟随**：中段 written 随对端窗口逐渐抬升缓慢爬升（4439872 → 5838464 → …），这是对端限速排空上游缓冲、通告窗口逐步打开的镜像——sndbuf 出现 616、2856、1440 这样的"呼吸"。sender 的意志完全被接收方牵着走，这正是流控教科书画面。
4. **账目互恰**：结束时 written−acked = 27288 B ≈ qlen=19 个 pbuf（每段 ≤1440 B）的在途量；主机实际收到 7213352 字节与 guest acked 精确相等；排除傀儡限速等待期后主机口径恰为 2.00 Mbps。三方数字闭环。
5. **正确姿势对照**：本实验为了采集 ERR_MEM 波形**故意**不查询额度就盲写。生产代码的正确写法是二选一或组合：
   a) 写前闸门：`if (total <= tcp_sndbuf(pcb)) tcp_write(...); else return;` 等 `sent()`/`poll()` 再试——把 ERR_MEM 概率压到近零；
   b) 写入节流：固定块 ≤ MSS、由 `sent()` 回调驱动的"一次 ACK 喂一口"，天然贴着 ACK 时钟走。
   若用 socket/netconn API，同一堵墙表现为 `send()` 返回 ENOSPC/EWOULDBLOCK——两层的差别在第 16 章展开。

> [!tip] 反压不是故障，是设计在工作
> 注意曲线里没有任何数据丢失：失败四千二百六十余次的 `tcp_write()` 一字节都没丢，最终送达字节数与协商分毫不差。`ERR_MEM` 是协议栈在替你执行背压协议，返回值即是文档。把这个信号当成异常日志刷屏而忽略之，才会酿成真正的故障（比如有人在此基础上"看到失败就 memset 复用缓冲"，瞬间触犯 6.5 节陷阱 2）。

---

## 6.8 小结

- `tcp_write()` 有两面：COPY 模式立即 `MEMCPY` 进栈有快照，写完即可复用缓冲；no-copy 模式只做一行 `pbuf_rom->payload = arg` 式引用，代价是从 enqueue 到 ACK 全程的生命周期契约——因为重传引用的就是你那块内存（seg 引用，而非快照）。
- 入口两道反压闸：字节额度 `snd_buf`（对外暴露为 `tcp_sndbuf()`）与物件额度 `snd_queuelen`（`TCP_SND_QUEUELEN`，随 SND_BUF/MSS 联动推导）；超额一律 `ERR_MEM` 且置 TF_NAGLEMEMERR。发送失败路径是事务化的：全有或全无，pcb 不留中间态。
- 零拷贝的精髓在类型系统而不在管线：`PBUF_ROM` 指着别人的内存照样走完 ip_output/linkoutput；相邻连续追加还能触发"延长旧引用"优化连描述符都省掉。接收侧对称故事是 pbuf 所有权直通：raw 回调拿到的必须 free 或转发，socket 层则在站内多做一次拷贝换取易用性。
- **ESP-IDF 关键事实**：`LWIP_NETIF_TX_SINGLE_PBUF=1`（port/include/lwipopts.h 硬编码）使 `tcp_write` 无条件走 COPY 分支，`TCP_WRITE_FLAG_COPY` 在 IDF 上是语义摆设；实测 COPY vs NOCOPY 六轮均值 121.10 vs 122.21 Mbit，统计无差，与该机制完全自洽。真·零拷贝需改 lwipopts.h 编译期决策并自备 scatter-gather linkoutput。
- 通路全景（IDF）：app buffer —[memcpy#1 @tcp_write]→ PBUF_RAM seg 队列 —[原地填头]→ etharp/ip 输出 —[单节点快路]→ esp_netif —[memcpy#2 @openeth 描述符]→ QEMU。全程恰两次数据拷贝，天花板是驱动边界与 DMA 缓冲本性，而非协议栈设计失误。
- TCP_SND_BUF 默认 vanilla 1072（2×MSS536）、IDF 5760（Kconfig，4×MSS1440）；实验 B 显示在 SLIRP 亚毫秒 RTT 下 5760 已喂饱 ~120 Mbit 管道，×5 加窗不增吐——窗口调优的金科玉律：先测 BDP 再动手，成对调（SND_BUF+WND+RECVMBOX），别在一个已被移走的瓶颈上加内存。
- 反压实验闭环了背压协议全貌：限速读取→上游缓冲吸涨→通告窗口收缩→`tcp_sndbuf()` 归零→`tcp_write()` 高频 ERR_MEM 但零丢包→宿主按 2.00 Mbps 精确消费，written/acked/主机字节数三方互恰。正确响应姿势是闸门（tcp_sndbuf 预检）或节流（sent 回调 ACK 时钟驱动），绝不在 ERR_MEM 后复用缓冲。
- 工程备忘：raw API 推进事件（connect/sent/poll/err）缺一不可——本工程开发期忘注册 `tcp_sent()` 曾把吞吐打到原来的数千分之一，教训是 raw API 没有"隐形泵"，一切前进都以显式回调为燃料。

下一章顺着数据通路的地图走向下一站基础设施：那条把它们全部串起来的抽象层 `netif`——注册、路由选择、linkoutput 约定、以及 6.2 图里被我们一笔带过的 ESP-IDF 组合牌（esp_netif 与 lwIP netif 的组合关系）。见 [[2026-08-26-lwip-deep-dive-ch7-netif-abstraction|第七章《netif 抽象层》]]。
