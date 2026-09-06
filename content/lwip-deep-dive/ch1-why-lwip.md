---
title: "lwIP 深度解析（一）：为什么是 lwIP"
date: 2026-08-26
description: "为什么 MCU 不直接塞 Linux 栈、裸写以太网帧能走多远、协议栈的最小职责边界在哪。对比 lwIP/picoTCP/CycloneTCP/商业栈，用源码证据拆 lwIP 四大设计哲学（单线程 tcpip_thread 邮箱、pbuf 统一内存抽象、回调式 raw API+分层 API、opt.h 数百开关的极致可裁剪），给出顶层目录地图与 Vanilla/ESP-IDF 对照，并用三组真实 idf.py size + QEMU 运行账本算清'lwIP 在 ESP32 上到底吃多少资源'。"
tags: [lwip, network, esp32, esp-idf, qemu, embedded, tcpip]
---

> [!info] lwIP 深度解析系列 0. [[lwip-deep-dive|系列索引]]
>
> 1. **第一章：为什么是 lwIP**

# lwIP 深度解析（一）：为什么是 lwIP

这一章回答三个问题：**为什么 MCU 上不能直接塞 Linux 那套网络栈**（资源与假设的差异）、**绕过协议栈裸写以太网帧能走多远**（哪里是分水岭）、**一个 TCP/IP 栈的最小职责边界是什么**（由此推出选型标准）。读完它，你会清楚 lwIP 凭什么成为 ESP-IDF、Arduino、RT-Thread 的事实标准，它的四个设计决定各自长什么样、在源码哪个文件里，以及在 ESP32 上开一个协议栈到底花多少 Flash 和 RAM——全部数字来自本章实测。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`components/lwip/lwip/src/include/lwip/init.h` 中 `LWIP_VERSION` 为 2.2.0 development，即上游 2.1.3 之后的开发版）。

---

## 1.1 核心问题三连

### 1. 为什么不把 Linux 的栈塞进 MCU

Linux 网络子系统不是"一个库"，而是一整套围绕这些前提建造的东西：

| Linux 栈的隐含前提                                 | 裸机/MCU 现实                                       |
| -------------------------------------------------- | --------------------------------------------------- |
| MMU + 进程地址空间，socket fd 关联到 `struct file` | 单一平坦地址空间，没有进程概念                      |
| 内核与应用隔离，系统调用边界                       | 应用和"内核代码"在同一特权级混跑                    |
| 内存以页为单位，动态分配失败可以回收重试           | RAM 以 KB 计（ESP32 片上 520KB SRAM），碎片就是死刑 |
| 网络报文处理可以慢，吞吐靠并发补偿                 | 一个报文处理超时可能意味着错过下一个采集周期        |

结果就是量级差距：Linux 网络路径连同其依赖（slab 分配器、RCU、软中断调度、netfilter 钩子……）即使裁剪也难低于 MB 级内存占用；而本章实测（1.6 节），ESP32 上一个"开了 socket 但还没插网线"的 lwIP 只花了 **4192 字节堆**和一个任务。嵌入式需要的不是功能最多的栈，而是**职责刚好够用的最小栈**。

### 2. 裸写以太网帧能走多远

不做任何"协议栈"，直接操作网卡收发帧，能实现什么？按代价从低到高：

```text
✅ 以太网帧收发            —— 填 DMA 描述符/读写缓冲即可
✅ ARP 请求/应答           —— 一张 N 条目的缓存表 + 广播
✅ IPv4 收发 + ICMP echo   —— 能 ping 通，几百行代码
⚠️ UDP                     —— 还要校验和、分片/重组，开始变厚
❌ TCP                     —— 主动这里断掉（原因见下）
```

ping 得通的人常常在这里产生幻觉："我自己也能写个栈"。分水岭在 TCP：

1. **状态机**：三次握手、11 种状态、TIME_WAIT 定时器、半开连接（RFC 793 及无数勘误）；
2. **可靠性**：序号/确认号记账、RTO 指数退避重传、快速重传/恢复；
3. **流控**：滑动窗口 + 接收方窗口通告；
4. **拥塞控制**：cwnd 增长、对丢包事件的响应策略；
5. **一切之上的健壮性**：乱序、重复、损坏、对端崩溃、自己这边的定时器竞态。

这不是写不出来，而是**写出来并且正确**需要常年的协议细节积累与回归测试——正是你该买现成栈的原因。但"裸帧层能做什么"依然值得知道：它划定了本书第 8~9 章（[[ch8-ethernet-arp|ARP]] 与 [[ch9-ip4-icmp|ICMP]]）要深入的那一层，也是很多 bootloader/tftp 小栈的真实实现层级。

### 3. 协议栈的最小职责边界

把上面两问交集一下，一个"够嵌入式用"的栈至少欠这些债：

| 层         | 最小职责                           | 源码落点（lwIP）                      |
| ---------- | ---------------------------------- | ------------------------------------- |
| 链路适配   | 把"网卡驱动交给我的一块数据"规范化 | `src/netif/ethernet.c`                |
| ARP / ND   | IP↔MAC 解析与缓存老化              | `src/core/ipv4/etharp.c`              |
| IP         | 寻址、转发判定、分片重组、校验     | `src/core/ip.c` + `ipv4/` `ipv6/`     |
| ICMP       | 差错报告 + echo                    | `src/core/ipv4/icmp.c`                |
| UDP / TCP  | 数据报 / 可靠字节流全语义          | `src/core/udp.c` `tcp*.c`             |
| 内存与缓冲 | 报文数据的统一表示与所有权规则     | `src/core/pbuf.c` `mem.c` `memp.c`    |
| OS 对接    | 与某种 RTOS 的信号量/队列/线程对接 | `src/api/tcpip.c` + 移植层 `sys_arch` |

最后两行不属于经典分层图，却是嵌入式栈最要命的部分：**报文怎么存、跟 RTOS 怎么相处**。下一章会看到 ESP-IDF 在这两处动的大手术（esp_netif 与 tcpip 任务）；本章 1.3 节先看 lwIP 自己的设计答案。

---

## 1.2 选型：开源三角与商业栈

### 1. 对比总表

截至本文写作时点（2026-08）主流候选：

| 维度                       | **lwIP**                                                                  | picoTCP                                     | CycloneTCP                        | 商业闭源栈                            |
| -------------------------- | ------------------------------------------------------------------------- | ------------------------------------------- | --------------------------------- | ------------------------------------- |
| 许可证                     | **BSD-3-Clause**（本地 `lwip/COPYING` 可查）                              | GPL-3.0 或商业双授权                        | GPL 与商业双授权（Oryx Embedded） | 纯商业授权（如 Treck、InterNiche 等） |
| 源码体量（src，含头/应用） | ~13.8 万行（实测 138,168）                                                | 十万行级                                    | 十万行级                          | 不公开或不完整公开                    |
| 协议完整度                 | IPv4/v6、TCP/UDP、DHCP/DNS/mDNS/SNTP/SNMP/MQTT/HTTP…                      | v4/v6 双栈、6LoWPAN、CAN 名义支持           | v4/v6、TLS 配套较全               | 通常很全（卖点所在）                  |
| 内存可裁剪性               | **数百个编译期开关**（见 1.3.4），RAM 目标可达几十 KB 量级                | 号称极小目标，但近年基本停滞                | 商业支持好，改动需授权谈判        | 厂商定制裁剪                          |
| 社区与生态                 | **事实标准**：ESP-IDF/Arduino(core)/RT-Thread/mbed(IPv4) 均内置或默认集成 | GitHub 多年低活跃（上游仓库已归档维护模式） | 商业用户为主，社区一般            | 无社区                                |
| 工具链友好                 | C99，任意交叉编译器                                                       | 同左                                        | 同左                              | 需厂商工具链或交付二进制              |

注：第三方项目的许可证与活跃度以各自主仓库当下状态为准（CycloneTCP 至今仍在 Oryx Embedded 自己的 GitHub 下以双授权发布）。本表的静态体量数字只做量级参考。

### 2. lwIP 胜出的三个理由

1. **BSD 授权的传染性为零**。商业产品可以直接链接发行，这是它进入 SDK 的法律前提；GPL 双授权项目（picoTCP/CycloneTCP 的开放面）要么污染授权，要么掏钱。
2. **生态飞轮已经转起来**。ESP-IDF 里它是唯一 TCP/IP 实现（WiFi 也走它），Arduino-ESP32 底下还是它，RT-Thread 默认网络框架 SAL 底层绑定它。**用的人越多，坑被踩得越平**——对一个靠社区修 bug 的开源栈，这比任何 benchmark 都重要。
3. **可裁剪做到了配置化而不是改源码**。数千个选项集中在 opt.h（上游）/Kconfig+lwipopts.h（IDF），裁剪=改配置重编，升级无合并负担。这就是下一节的主角。

> [!note] 不是"最强"，是"恰好"
> 论原始吞吐与新特性跟进，商业栈各有胜场；论"能否让一个 64KB RAM 的芯片联网并保持 BSD 干净"，lwIP 几乎是唯一解。选型选的是约束下的最优，不是绝对最优。

### 3. 30 秒选型决策树

把上面的对比压缩成可执行的判断流程：

```text
许可证必须宽松（要进商业固件）？
├── 是 → 现成 SDK 里有没有 lwIP？
│        ├── 有（ESP-IDF/Arduino/RT-Thread…）→ 直接用它，别再造轮子
│        └── 没有 → 自己移植 lwIP（工作量主要在 sys_arch + netif 两层，
│                    见 ch14 与 ch17），或评估 ThreadX NetX（MIT）
└── 否（接受 GPL 或付费）→ 需要 TLS/工业协议全家桶与厂商背书？
         ├── 是 → CycloneTCP / 商业闭源栈
         └── 否 → picoTCP 开源面（注意维护停滞风险）或仍然 lwIP
```

三条实战注解：

1. "现成 SDK 已带"的权重被普遍低估——自己换栈意味着接手裁剪、移植、安全补丁三件套的全部维护成本；
2. 资源极小（<20KB RAM）且只有 UDP 需求的场景，先确认是否真的需要 TCP/IP 栈，CoAP+裸帧有时比完整栈更省；
3. 本系列后续所有章节只处理 lwIP，其他栈只在此对照一次。

---

## 1.3 四大设计哲学（带源码证据）

### (a) 单线程协议栈核心：tcpip_thread + 邮箱

lwIP 核心不立多线程假设：**全部协议状态只属于一个线程**——`tcpip_thread()`（`src/api/tcpip.c`）。别人的线程想碰协议栈，只有一条正门：往邮箱里投消息。

```c
/* src/api/tcpip.c —— 消息类型节选（缩略） */
enum tcpip_msg_type {
    TCPIP_MSG_API,          /* netconn API：msg->msg.api_msg.function(...) */
    TCPIP_MSG_INPKT,        /* 收包：msg->msg.inp.input_fn(p, netif) */
    TCPIP_MSG_CALLBACK,     /* 用户回调在核心线程里执行 */
    ...
};
```

三种入队货色对应三类调用者：netconn API 调用（来自应用任务）、网卡收包（`netif->input = tcpip_input` 把 pbuf 从 ISR/驱动上下文转投进来）、以及用户自己的 `tcpip_callback()`。同一个邮箱也是 TCP 重传等内部定时器的结算窗口——`tcpip_thread` 主循环取一条消息执行一条，顺带检查到期定时器。主循环的完整骨架比想象中还朴素：

```c
/* src/api/tcpip.c —— tcpip_thread() 主循环（骨架） */
while( 1 ) {                                   /* MAIN Loop */
    /* 取消息；等待期间顺路处理到期的内部定时器 */
    TCPIP_MBOX_FETCH( &tcpip_mbox, (void **)&msg );
    if( msg == NULL ) { ... continue; }
    tcpip_thread_handle_msg( msg );            /* 按 msg->type 分发执行 */
}
```

整个协议栈的心跳就是这几行：**没有消息就睡在邮箱上，有消息就同步执行，睡眠期间定时器到期照常结算**。你在 lwIP 里看到的任何"并发"都是被这个循环串行化之后的假象。

这个设计的收益与代价都极端：

- ✅ 核心**零锁**：协议内部数据结构没有并发访问，不需要锁，中断延迟和 worst-case 时间好分析；
- ❌ 所有 API 调用都是一次跨线程投递：延迟多一跳，邮箱满就堵（或者丢）；
- ⚠️ 但 lwIP 又提供了另一个模式 `LWIP_TCPIP_CORE_LOCKING`（默认开，opt.h 第 190 行）：别人持有全局锁直接进核心跑，省掉投递。**两条路线互斥，必须全局选一边。**

> [!tip] IDF 的选择埋着第 13 章的伏笔
> ESP-IDF 的 Kconfig 把 `LWIP_TCPIP_CORE_LOCKING` **默认关掉**（`components/lwip/Kconfig` 第 29 行 `default n`），回到纯邮箱模型；上游 opt.h 默认值反而是 1。为什么带宽敏感的 IDF 反而选了"慢"的模式？mailbox 深度多少才够？第十三章专门拆 [[ch13-tcpip-thread-mailbox|tcpip 线程与邮箱]]。本章实验先给一个直观证据：什么都不配，`tcpip_init()` 之后任务清单里就会出现名为 `tcpip` 的 FreeRTOS 任务（优先级 18，实测见 1.6）。

### (b) pbuf：一份结构统一所有报文内存

lwIP 里任何报文——网卡收到的帧、待发送的分段、应用要发的数据——都是同一种东西：`struct pbuf`（`src/include/lwip/pbuf.h`）：

```c
struct pbuf {
    struct pbuf *next;      /* 分片链表 */
    void *payload;          /* 本段数据指针 */
    u16_t tot_len;          /* 本段+后续所有段的总长（链式不变式） */
    u16_t len;              /* 本段长度 */
    u8_t  type_internal;    /* 类型：PBUF_RAM/POOL/ROM/REF... */
    u8_t  flags;
    LWIP_PBUF_REF_T ref;    /* 引用计数，谁来释放由计数裁决 */
    u8_t  if_idx;
};
```

两件事值得现在就记住：

1. **payload 是指针不是数组**。它可以指向池子里拷出来的数据（PBUF_RAM/PBUF_POOL），也可以指向 ROM 字符串或零拷贝交上来的应用缓冲（PBUF_ROM/PBUF_REF）——"数据搬不搬、谁拥有"是显式决策，不是隐含约定。
2. **链表 + 引用计数**意味着头部信息与负载可以串在同一包上、跨层传递全程零拷贝共享一个物理副本。

`payload` 的四种归属由 `pbuf_alloc()` 的 type 参数决定，这是读写 lwIP 代码时判断"这块数据在哪、归谁管"的速查表：

| 类型        | payload 指向     | 分配自（vanilla 默认） | 典型场景                        |
| ----------- | ---------------- | ---------------------- | ------------------------------- |
| `PBUF_RAM`  | 栈内可写内存     | `mem_malloc()` 堆      | 发送路径：协议头+数据拼成一段   |
| `PBUF_POOL` | 静态 pbuf 池元素 | `memp` 池（定长分块）  | 接收路径：驱动把数据装进固定块  |
| `PBUF_ROM`  | 只读存储区       | 不分配，仅加头         | 回应包直接引用 ROM 里的常量内容 |
| `PBUF_REF`  | 调用方自己的缓冲 | 不分配，仅加头         | 零拷贝：应用缓冲原地入栈        |

IDF 全堆化之后 RAM/POOL 两行的物理落点变成了 ESP-IDF heap，但类型语义与所有权规则原样保留——这也是为什么第 4 章解剖 pbuf 时必须两条线索并行。

量级证据：在 32 位 Xtensa 上 `sizeof(struct pbuf)` 只有 **16 字节**（1.6 节实测输出第一行）。头足够便宜，才能"一片数据一环扣一环"。解剖细节归 [[ch4-pbuf-anatomy|第四章]]。

### (c) 回调式 raw API 为核，socket 为壳

协议核心暴露的编程界面是**事件回调**（raw API）：你注册函数，栈在自己的线程里帮你调：

```c
/* src/include/lwip/tcp.h */
typedef err_t (*tcp_recv_fn)(void *arg, struct tcp_pcb *tpcb,
                             struct pbuf *p, err_t err);
```

注册流程长这样（raw API 的"搭积木"，每一步都是在给 PCB 挂回调）：

```c
struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
tcp_bind(pcb, IP_ADDR_ANY, 8080);
pcb = tcp_listen(pcb);                    /* 进入 LISTEN 态 */
tcp_accept(pcb, my_accept_cb);            /* 有连接进来时被调 */
/* my_accept_cb 里对每个新 pcb 继续： */
tcp_recv(pcb, my_recv_cb);                /* 收到数据：pbuf 交到你手上 */
tcp_sent(pcb, my_sent_cb);                /* 数据被对端 ACK 时被调 */
tcp_err(pcb, my_err_cb);                  /* 连接异常中止时被调 */
```

这种风格天生贴单线程模型：回调在核心线程内同步执行，天然免锁；代价是编程模型反直觉（状态分散在回调之间）。于是 lwIP 又往上盖了两层便捷壳：

```text
raw API      （回调，tcp_pcb 直接操作，最高效）
   ↑  api_msg.c 把阻塞调用翻译成投递给核心线程的消息
netconn      （半抽象层，api_lib/api_msg + netbuf）
   ↑  sockets.c 再映射成 BSD socket 名字 + VFS 集成
socket API   （POSIX 兼容，最顺手，代价一次消息往返）
```

三层都能同时存在，同一份 PCB。这也解释了选型常见疑问"lwIP 性能调优该调哪层"——开销差异主要就在离核心的距离。第十五章起逐层展开 [[ch15-raw-api-callbacks|raw API]] 与 [[ch16-socket-netconn-vfs|socket/netconn/VFS]]。

### (d) 极致可裁剪：opt.h 里数百个开关

裁剪的中央配电盘是 `src/include/lwip/opt.h`——单文件 **3730 行**，其中 `#define LWIP_*` 开关 **170 个**，加上 `TCP_/UDP_/MEMP_/MEM_` 等前缀的参数宏约 **280 个**。每个开关都带"默认值 + 注释说明依赖关系"，这意味着 lwIP 支持的是**官方声明过的裁剪面**，而不是靠运气删代码。挑一组有代表性的（默认值为 vanilla opt.h 所写，右列注明 IDF 是否接入了 menuconfig）：

| 开关（opt.h 默认）                                        | 控制什么                              | IDF Kconfig 映射                                                           |
| --------------------------------------------------------- | ------------------------------------- | -------------------------------------------------------------------------- |
| `LWIP_TCP` (1) / `LWIP_UDP` (1)                           | TCP/UDP 编译进出                      | 未接入（IDF 无法整体关掉 TCP）                                             |
| `LWIP_ICMP` (1)、`LWIP_ARP` (1)                           | ICMP、ARP                             | 有对应菜单（ICMP 菜单在 Kconfig）                                          |
| `LWIP_RAW` (0)                                            | raw pcb（ping 等自定义协议用）        | 仅上限 `LWIP_MAX_RAW_PCBS` 接入                                            |
| `LWIP_IPV6` (0)                                           | 整个 IPv6 子系统                      | ✓ `CONFIG_LWIP_IPV6`（IDF 默认 y！）                                       |
| `LWIP_DHCP` (0)/`LWIP_DNS`(0) 等                          | DHCP 客户端、DNS                      | 上限数值接入，总开关由 esp_netif 场景决定                                  |
| `MEMP_NUM_TCP_PCB` (5)                                    | 同时活跃 TCP 连接数（**静态池深度**） | ✓ `CONFIG_LWIP_MAX_ACTIVE_TCP`（默认 16）                                  |
| `MEMP_NUM_UDP_PCB` (4)、`MEMP_NUM_RAW_PCB` (4)            | UDP/raw pcb 池深                      | ✓ `CONFIG_LWIP_MAX_UDP_PCBS` 等                                            |
| `PBUF_POOL_SIZE` (16)                                     | pbuf 池大小（仅 PBUF_POOL 类型）      | 未直接接入（IDF 内存模型不同，见 1.5）                                     |
| `TCP_MSS` (536) → `TCP_WND`(4×MSS) / `TCP_SND_BUF`(2×MSS) | 单连接缓冲水位                        | ✓ `CONFIG_LWIP_TCP_MSS/WND_DEFAULT/SND_BUF_DEFAULT`（默认 1440/5760/5760） |
| `TCPIP_MBOX_SIZE` / `TCPIP_THREAD_STACKSIZE`              | 核心邮箱深度、核心线程栈              | ✓ `CONFIG_LWIP_TCPIP_RECVMBOX_SIZE`(32)/`TASK_STACK_SIZE`(3072)            |
| `MEM_LIBC_MALLOC` (0) / `MEMP_MEM_MALLOC` (0)             | 动态内存是否转交给 libc malloc        | ✓ 都设为 1——大改造，见 1.5                                                 |
| `LWIP_STATS` (1)                                          | 统计计数器结构本身                    | ✓ `CONFIG_LWIP_STATS`（IDF 默认 n）                                        |

> [!warning] 表格翻译成人话
> 裁剪有三种深度：**编译期整体移除**（`LWIP_IPV6=n`，Flash 直降，1.6 节实测 −24.8KB）；**运行期容量封顶**（PCB/MSS/邮箱尺寸，省的是堆峰值而非 Flash）；**机制替换**（`MEM_LIBC_MALLOC` 这种改变整个内存所有权模型的）。三种混用才是真实工程里的样子。

opt.h 还有一个容易被忽略的读法技巧：同一开关在文件里**出现多次是常态而非笔误**——先用 `#if defined(...)` 保留用户 lwipopts.h 的定义，再按"其他开关的组合"给条件默认值。例如 `LWIP_DHCP` 在第 933/938 行出现两次，分别是 IPv4 关闭时与开启时的默认分支；`MEMP_STATS` 的默认值直接写成 `(MEMP_MEM_MALLOC == 0)`。也就是说 opt.h 是一张**依赖图而非常量表**：改一个上游默认值之前先 grep 它的引用者，否则你砍掉的分支可能悄悄拴着三个别的功能。

---

## 1.4 顶层目录地图

`src/` 下实际住着什么（照实 `ls`，非凭记忆）：

| 目录           | 内容                                  | 代表文件（行数为实测）                                                                                                                                                                                                                                                                                                                                         |
| -------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/core/`    | 协议核心：TCP/IP 本体 + 内存 + 定时器 | `tcp.c` 2737、`tcp_in.c` 2230、`tcp_out.c` 2257、`pbuf.c` 1545、`mem.c` 1017、`memp.c` 473、`timeouts.c` 464、`udp.c` 1333、`netif.c` 1863、`dns.c` 1844；子目录 `ipv4/`（`ip4.c`、`icmp.c`、`etharp.c`、`dhcp.c`、`igmp.c`、`ip4_frag.c`、`autoip.c`、`acd.c` 等）、`ipv6/`（`ip6.c`、`icmp6.c`、`nd6.c`、`mld6.c`、`ethip6.c`、`ip6_frag.c` 等）、altcp 相关 |
| `src/api/`     | 面向应用的接口层                      | `sockets.c`、`api_lib.c`、`api_msg.c`、`netdb.c`、`netbuf.c`、`tcpip.c`、`err.c`                                                                                                                                                                                                                                                                               |
| `src/netif/`   | 链路层适配器（每种物理网络一个）      | `ethernet.c`、`bridgeif.c`、`slipif.c`、`lowpan6*.c`、`zepif.c`、子目录 `ppp/`                                                                                                                                                                                                                                                                                 |
| `src/include/` | 全部公共头                            | `lwip/`（API 头）、`netif/`（驱动接口头）、`compat/`（POSIX 兼容垫片）                                                                                                                                                                                                                                                                                         |
| `src/apps/`    | 官方应用示例                          | `http/`、`mqtt/`、`sntp/`、`snmp/`、`mdns/`、`tftp/`、`altcp_tls/`、`lwiperf/` …                                                                                                                                                                                                                                                                               |

core 目录全部 C 文件合计 **36,278 行**（其中顶层 `*.c` 约 23,303 行，其余在 `ipv4/`、`ipv6/` 子目录）——这就是"一个能对讲的 TCP/IP 栈"本体量级，其余十几万行分布在上表另外四格与 `ppp/` 里。读源码建议顺序：`init.c`（装配现场）→ `tcpip.c`（引擎点火）→ `pbuf.c`（物流系统）→ `tcp_in/out.c`（业务主体），正好是本系列前四章的路线。

---

## 1.5 Vanilla lwIP vs ESP-IDF lwIP

IDF 拿到 lwIP 后做的不是简单打包，而是一整套组件化改造。目录布局（`components/lwip/` 实测）：

```text
components/lwip/
├── lwip/                 ← 上游源码原样副本（src/ 含 contrib、doc、test），版本 2.2.0-dev
├── port/                 ← Espressif 适配层
│   ├── esp32xx/          ← vfs_lwip.c（socket↔VFS 桥）、no_vfs_syscalls.c、include/
│   ├── freertos/         ← sys_arch.c（RTOS 信号量/队列/线程原语落地）
│   ├── hooks/            ← lwip_default_hooks.c、tcp_isn_default.c
│   ├── include/lwipopts.h ← ★ CONFIG_LWIP_* → LWIP_* 的翻译站（168 处引用）
│   └── linux/            ← 主机上跑 lwIP 的移植（CI 用），说明移植层完全可替换
├── apps/                 ← IDF 自有应用：dhcpserver/、ping/、sntp/、netdb/
├── Kconfig               ← 1559 行菜单：裁剪、Hook 选择、调试
└── sdkconfig.rename      ← 旧配置名兼容别名表
```

五个关键动作：

1. **配置翻译站**。你的每一个 `CONFIG_LWIP_*` 由 `port/include/lwipopts.h` 翻译成 lwIP 的原生宏，例如：
   ```c
   /* port/include/lwipopts.h —— 已验证的节选 */
   #define MEMP_NUM_TCP_PCB        CONFIG_LWIP_MAX_ACTIVE_TCP
   #define TCP_MSS                 CONFIG_LWIP_TCP_MSS
   #define TCPIP_MBOX_SIZE         CONFIG_LWIP_TCPIP_RECVMBOX_SIZE
   ```
   所以「menuconfig 改一项」和「vanilla 手改 lwipopts.h」是同一件事的两个门牌。
2. **内存所有权大革命：全堆化**。vanilla 默认每类对象预分配静态池（memp）、大缓冲区专用 heap；IDF 设 `MEM_LIBC_MALLOC=1` 且 `MEMP_MEM_MALLOC=1`——**所有协议栈动态需求统统转给 ESP-IDF 的 heap 管理器**。直接后果有二：(a) 栈的 RAM 与全系统共池，峰值弹性更好；(b) `stats_display()` 里**不再存在 MEM/MEMP 池账目**（opt.h 第 2268/2275 行的定义式 `MEM_STATS=(MEM_LIBC_MALLOC==0)...`、`MEMP_STATS=(MEMP_MEM_MALLOC==0)` 自动归零），观察内存只能去看 heap 管理器的账——1.6 节实验如实呈现了这一点。
3. **IDF 自有补件**。upstream 的 ping 示例基于 raw API；IDF 把 ping 重写成**基于 socket 的 `apps/ping/ping_sock.c`**（公开头在 `components/lwip/include/apps/ping/ping_sock.h`）；另有 `dhcpserver/`（上游没有的服务端实现）与 `apps/netdb/esp_netdb.c`（IPv4/v6 合流的 getaddrinfo 封装）；`LWIP_NETCONN_SEM_PER_THREAD=1`（port lwipopts.h）使每个线程自带等待信号量，vanilla 默认为 0。
4. **Hook 选择点 Kconfig 化**。lwIP 预留的 `LWIP_HOOK_*` 缝隙（TCP ISN 计算、IPv6 路由查询、外部 DNS 解析等）在 `Kconfig` 的 Hooks 菜单里可选 default/custom 两档，custom 档连接到你实现的 `lwip_hook_xxx`。
5. **兼容与不动 parts**。`sdkconfig.rename` 维护旧名（`CONFIG_TCP_MSS`→`CONFIG_LWIP_TCP_MSS` 等）避免老项目崩盘；`lwip/` 目录内容保持上游模样以便 diff 版本差异。注意一个例外——**IDF 没有暴露 `LWIP_TCP/LWIP_UDP` 总开关**，协议族本体关不掉；硬关只有改源码一条路。

> [!tip] 系列暗线 B 正式开工
> 「Vanilla vs IDF」对照是每章固定节目。本章看到的是总纲（配置翻译、内存模型、自有补件），后续章节会在各自主题下继续累积这张对照表。

---

## 1.6 实验：lwIP 在 ESP32 上到底吃多少资源

### 1. 实验设计

问题：「一个嵌入式 TCP/IP 栈的开销」必须拆成三笔账才有意义——**静态体积**（idf.py size：Flash code/data、DRAM data/bss）、**启动期动态开销**（`tcpip_init()` 前后的堆差）、**每连接边际成本**（建一个 socket 增加多少堆）外加**容量上限语义**（把上限压到 1 会发生什么）。测量方法：

- 工程：`practice/lwip-ch01-why-lwip/`（从 hello_world 模板起步，main 换成探针程序，`PRIV_REQUIRES lwip heap`）。探针行为：打印关键结构 `sizeof` → `tcpip_init()` 前后读 `heap_caps_get_free_size(MALLOC_CAP_INTERNAL|MALLOC_CAP_8BIT)` → 枚举任务清单 → 并发建 UDP+TCP socket 各一个并保留 → 做一次域名解析 → （开启 STATS 时）`stats_display()`。
- 三组配置只动 `sdkconfig.defaults`：A=全默认；B=最小化（下表）；C=B 再加 `CONFIG_LWIP_STATS=y` + `CONFIG_FREERTOS_USE_TRACE_FACILITY=y`（为了任务清单与统计账本，这两项是为测量服务的仪器开销）。
- 每个 socket 操作都真实穿过 netconn→tcpip 邮箱路径，保证 socket/TCP/UDP/DNS 代码确实链接进最终镜像（避免 linker GC 制造虚假的低估值——第一次搭实验时真的踩了这个坑：只调 `tcpip_init()` 的话 .text 比 A 组少 10KB，那是因为大部分协议根本没被链入）。

B 组的全部差异项（项名均已对过 `components/lwip/Kconfig` 的名字与 range 下限）：

```text
CONFIG_LWIP_MAX_SOCKETS=1          # 默认 10
CONFIG_LWIP_MAX_ACTIVE_TCP=1       # 默认 16
CONFIG_LWIP_MAX_LISTENING_TCP=1    # 默认 16
CONFIG_LWIP_MAX_UDP_PCBS=1         # 默认 16
CONFIG_LWIP_MAX_RAW_PCBS=1         # 默认 16
CONFIG_LWIP_TCP_MSS=536            # 默认 1440
CONFIG_LWIP_TCP_WND_DEFAULT=2440   # 默认 5760，range 下限 2440
CONFIG_LWIP_TCP_SND_BUF_DEFAULT=2440
CONFIG_LWIP_TCPIP_RECVMBOX_SIZE=6  # 默认 32，range 下限 6
CONFIG_LWIP_TCPIP_TASK_STACK_SIZE=2048  # 默认 3072
# CONFIG_LWIP_IPV6 is not set      # IDF 默认 y
# CONFIG_LWIP_CHECKSUM_CHECK_ICMP is not set  # 默认 y
```

### 2. 运行

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch01-why-lwip
idf.py set-target esp32 && idf.py build && idf.py size   # A 组；之后换 sdkconfig.defaults 重复 rm sdkconfig + build
idf.py qemu monitor < /dev/null || true                  # 生成 QEMU 镜像
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 30 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run.log
```

### 3. 结果：size 三组对照

本实验在工程目录里留下的完整产物（可复核）：

| 文件                                                               | 内容                                                        |
| ------------------------------------------------------------------ | ----------------------------------------------------------- |
| `size-default.log` / `size-minimal.log` / `size-minimal-stats.log` | 三组配置的 `idf.py size` 输出                               |
| `run-default.log` / `run-minimal.log` / `run-minimal-stats.log`    | 三组配置的 QEMU 串口输出                                    |
| `sdkconfig.defaults`                                               | 当前为 C 组内容（B 组选项 + STATS + TRACE，文件内注释注明） |

A（默认）与 B（最小化）的 `idf.py size` 输出关键行：

```text
# A：默认配置（size-default.log）
│ Flash Code   │ 133894 │        │ Flash Data │ 47012 │
│ IRAM         │ 44183  │ 33.71% │ DRAM       │ 17308 │（.data 10764 + .bss 6544）

# B：最小化配置（size-minimal.log）
│ Flash Code   │ 109138 │        │ Flash Data │ 45916 │
│ IRAM         │ 44183  │ 33.71% │ DRAM       │ 15396 │（.data 10748 + .bss 4648）

# C：B + LWIP_STATS + TRACE_FACILITY（size-minimal-stats.log）
│ Flash Code   │ 111770 │        │ Flash Data │ 46828 │
│ IRAM         │ 44183  │        │ DRAM       │ 15668 │
```

| 口径          | A 默认  | B 最小化 | Δ(B−A)                  | 解读                                                                             |
| ------------- | ------- | -------- | ----------------------- | -------------------------------------------------------------------------------- |
| Flash .text   | 133,894 | 109,138  | **−24,756（−18.5%）**   | 大头是 IPv6 子系统整体退出（ND6/ICMP6/IPv6 分片等），外加若干校验分支            |
| Flash .rodata | 46,740  | 45,644   | −1,096                  | 字符串与常量表小幅缩减                                                           |
| IRAM          | 44,183  | 44,183   | 0                       | 默认未开 IRAM optimization，lwIP 代码全在 Flash                                  |
| 静态 DRAM     | 17,308  | 15,396   | **−1,912**              | 分布在随配置消失的全局数据里——IDF 全堆化后（1.5 节）静态侧只剩少量全局，波动不大 |
| C 组仪器成本  | —       | —        | text +2,632 / DRAM +272 | stats 计数器结构与任务枚举的开销，仅测量时付                                     |

### 4. 结果：运行时账本（QEMU，run.log 真实摘录）

三组共同的头部输出：

```text
== ch01 probe: bare protocol-stack core, no netif ==
sizeof: pbuf=16 tcp_pcb=208 udp_pcb=80 netconn=52     ← A 组
DRAM free before tcpip_init: 299772
DRAM free after  tcpip_init: 295580                   ← 差值 4192 字节
concurrency: udp_fd=54 tcp_fd=55                      ← 两个 socket 同时打开成功
heap: udp hold=372B, +tcp hold=380B
dns localhost -> 0x3ffb32ec
probe done, restarting
```

B 组（run-minimal.log）：

```text
sizeof: pbuf=16 tcp_pcb=168 udp_pcb=40 netconn=52
DRAM free after  tcpip_init: 298644                   ← 差值 3040 字节
concurrency: udp_fd=63 tcp_fd=-1
             tcp errno=23 (Too many open files in system)
heap: udp hold=332B, +tcp hold=0B
```

C 组追加的任务清单与统计账本（run-minimal-stats.log）：

```text
-- task inventory (6 tasks) --
task main           prio  1 stack-hwm   3016
task IDLE1          prio  0 stack-hwm   1088
task IDLE0          prio  0 stack-hwm   1092
task tcpip          prio 18 stack-hwm   1980      ← 核心线程：优先级 18，2048 栈峰值只用了 68
task ipc1           prio 24 stack-hwm    572
task ipc0           prio 24 stack-hwm    564
tcpip thread 'tcpip' stack high-water mark: 1980 bytes
LINK / ETHARP / IP / ICMP / TCP ... （xmit/recv/drop 全 0：还没有流量）
SYS sem/mutex/mbox 全 0
```

注意 stats 输出**没有 MEM 与 MEMP 两段**——这正是 1.5 节说的全堆化的第一手印证，不是输出被截断。

### 5. 解读：这笔账怎么算

1. **启动一笔账：4192 → 3040 字节**。`tcpip_init()` 之后系统多了一个优先级 18 的 `tcpip` 任务、它的 3072 字节栈（栈 TCB + 队列句柄）、深 32 的核心邮箱（FreeRTOS 队列，每槽一个指针）和内部信号量。A/B 两组差值 1152 ≈ 栈砍掉的 1024 + 邮箱缩短贡献的百余字节——账能对上。
2. **每连接边际账：约 350~400 字节/连接**。实测单个 UDP socket 持有 372B、追加 TCP socket 380B（含 netconn 52B + PCB + VFS 登记与内部消息缓存）。乘以你的应用并发数就是 lwIP RAM 预算的下界公式——再叠加发送中的 pbuf 缓冲。
3. **裁剪的第一刀省 Flash**：关 IPv6 直接拿回 24.8KB（占 lwIP 关联 .text 的近两成）。第二刀封顶省堆：MSS 1440→536、窗口 5760→2440 决定的是**每个连接的传输中数据量上限**，连接越多这刀越痛快。
4. **EMFILE 是最好的教学案例**：`MAX_SOCKETS=1` 时第二个 socket 立刻 `errno=23`。可见这些"数量上限"是**硬拒绝不是软退化**——估算时给并发留余量，否则故障形态就是"高负载时莫名连不上"。顺带提醒：关了 socket 立刻重开也可能瞬时撞同一上限，因为 netconn 回收发生在 tcpip 线程里、异步于你的 `close()` 返回。
5. **结构体积本身就是设计宣言**：pbuf 头 16 字节、UDP PCB 80 字节——每个字段都在为"几十 KB RAM 上跑得动"服务；而 IPv6 裁掉后 `tcp_pcb` 208→168、`udp_pcb` 80→40，协议族的代价精确到 sizeof。

> [!warning] 数字的外推边界
> 以上是 QEMU 仿真的 Xtensa@ESP32 结果，镜像不含 esp_netif/WiFi/以太网驱动（那些另算）；主机性能不影响 size 数字，但运行时堆差在真机上可能有 ±百字节级别的差异（分配器行为）。结论层面——启动 ~4KB、每连接 ~400B、IPv6 占 Flash 近两成——可以直接当作预算起点使用。

---

## 1.7 小结

- **MCU 选栈的逻辑起点**是资源与假设差异：没有 MMU、内存按 KB 计、实时性敏感，Linux 栈的前提全不成立。裸写帧能撑到 ICMP，TCP 状态机+可靠性+拥塞控制是必须买现成的分水岭。
- **lwIP 胜出的组合拳**：BSD-3-Clause（无传染）+ 事实标准生态（ESP-IDF/Arduino/RT-Thread）+ 配置化裁剪（opt.h 3730 行、170 个 `LWIP_*` 开关，不用改源码）。
- **四大设计哲学**及落点：(a) 单线程核心 `tcpip_thread` + 邮箱（`src/api/tcpip.c`），核心零锁、通信全靠投递，IDF 默认关闭 core locking 回归纯邮箱；(b) `struct pbuf`（头仅 16 字节实测）统一报文内存，链表+引用计数支撑零拷贝；(c) raw API 回调为核、netconn/socket 为壳的三层编程面；(d) 可裁剪三档——编译期移除、运行期封顶、机制替换。
- **目录地图**：core 全部 C 文件 36.3K 行（顶层 23.3K）是协议本体，api/socket 层、netif 驱动适配、include 公共头、apps 官方应用各居其所。
- **Vanilla vs IDF 五件事**：Kconfig→lwipopts.h 翻译站（168 处映射）、`MEM_LIBC_MALLOC+MEMP_MEM_MALLOC` 全堆化（连带 MEM/MEMP 统计段消失）、自有补件（socket 版 ping、dhcpserver、esp_netdb）、Hook 选择菜单化、TCP/UDP 总开关未暴露。
- **实测账本**（ESP32/QEMU/IDF v6.0.2）：默认配置 `tcpip_init` 后 +4192B 堆、最小化 +3040B；每连接约 350~400B；关 IPv6 省 Flash .text 24.8KB（−18.5%）；上限类配置是硬顶，撞线即 EMFILE。

下一章进入真正的地基：ESP-IDF 如何把"一块 SoC + 一个 WiFi/以太网外设"组装成 lwIP 世界里的 netif——esp_netif 与 esp_eth 的双层架构、事件流与初始化次序，以及为什么你在代码里几乎从不直接碰 lwIP 却处处受它管辖。见 [[ch2-esp-idf-network-architecture|第二章]]。

---

Sources（第三方项目现状核对用）:

- [Oryx-Embedded/CycloneTCP (GitHub)](https://github.com/Oryx-Embedded/CycloneTCP)
- [Oryx Embedded commercial licensing](https://www.oryx-embedded.com/licensing/commercial/)
