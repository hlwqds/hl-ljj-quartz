---
title: "lwIP 深度解析（二十三）：调试工具箱：LWIP_DEBUG、统计与抓包"
date: 2026-08-26
description: "把散落在前二十二章的观察技巧整合成系统化的分诊流程：分层探针决策图（物理→驱动→netif→IP→TCP→socket）、LWIP_DEBUG 的 flag 语法与 IDF Kconfig 映射（含运行时动态开关为何在 2.2.0-dev 不可行）、stats_display 全表与 snap-diff 增量范式、抓包的三条路（tcpdump/hook/linkoutput）视角差异，以及 gdb 活体 PCB 巡检。终章前奏用完整破案示范解剖 ch22 悬案②——真相不是『全 RST』而是数据黑洞加 SYN 静默丢弃，一个 RST 都没有。"
tags: [lwip, network, esp32, esp-idf, qemu, debugging]
---

> [!info] lwIP 深度解析系列 0. [[lwip-deep-dive|系列索引]] 23. **第二十三章：调试工具箱：LWIP_DEBUG、统计与抓包**

# lwIP 深度解析（二十三）：调试工具箱：LWIP_DEBUG、统计与抓包

这一章回答三个问题：**网络"出问题"时从哪一层查起**、**LWIP_DEBUG 的日志体系怎么开才不被淹没**、**QEMU 环境里"抓包"到底能抓到什么**。读完它，你应该能把一份卡死的连接、一条缓慢的链路、一堆看不懂的错误码，翻译成一串可执行的观测动作——并且有一个完整的破案示范把方法串起来。

源码参照：ESP-IDF **v6.0.2**（`~/esp/esp-idf`），捆绑 lwIP **2.2.0-dev**（`components/lwip/lwip/src`）。所有 Kconfig 名、宏名、函数行为均以该仓库源码与本章实测为准。本章是 [[ch24-debugging-tracing-pitfalls|FreeRTOS 系列第二十四章]] 的网络篇姊妹章——那边教你怎么停住整个世界看任务，这边教你协议栈坏掉时怎么一层层剥开看字节。

---

## 23.1 分层分诊：一个"偶发慢"从哪查起

### 1. 探针决策图

网络问题诊断的纪律和医学一样：先定位病灶所在的层次，再选那一层的观察工具。自下而上的分层分诊图：

```text
 应用     │ connect errno / RTT 抖动 / 业务断流      │ errno 记录、应用计时打点
 socket   │ fd 泄漏？邮箱堵塞？select/poll 误报？    │ CONFIG_LWIP_SOCKETS_DEBUG、fd 计数
 ─────────┼─────────────────────────────────────────┼────────────────────────────
 TCP      │ 重传/RTO/延迟ACK/状态机异常             │ lwip_stats.tcp snap-diff(23.3)、gdb PCB 巡检(23.5)、CONFIG_LWIP_TCP_DEBUG
 IP/ICMP  │ 分片、TTL、路由黑洞                     │ ip4 route 打印、stats.ip.drop/rterr、hook(23.4-b)
 netif    │ 地址没有？MTU？loop 队列溢出？          │ ext-callback 记录仪(ch7)、dbg_lwip_tcp_pcb_show()
 驱动     │ RX 描述符环满、linkoutput 卡死          │ linkoutput/input_path 包装计数(ch17/ch12)(23.4-c)
 物理     │ SLIRP 用户态转发、hostfwd 端口冲突       │ tcpdump -i lo(ch8/ch21 手法)(23.4-a)、宿主 ss/netstat
```

一句话版本：**症状在哪一层报出来不重要，证据在几层一起取**。"偶发慢"最常见的三个来源——SYN 重传退避、延迟 ACK 台阶、SLIRP/QEMU 仿真的毛刺——分别要在 TCP 层（重传计数）、定时器层（`TCP_TMR_INTERVAL` 基准，见第十二章）和物理层（双端对拍）找答案。

### 2. 两本硬账先算清

- **ping 差异法**：guest 内 `esp_ping` 打网关 10.0.2.2 得到的 RTT 是"栈+SLIRP"的基线（本章实测 0~1 ms）；如果应用层 RTT 明显高于基线，慢不在 IP 层以下。这是最便宜的分界线测量。
- **错误码别望文生义**：lwIP 的 errno 映射有自己的方言——`accept/connect` 拿到 `113(EHOSTDOWN)` 多半是"你的 SYN 被吞了"，`close` 返回 `128` 是跨任务解阻塞哨兵（[[ch16-socket-netconn-vfs|第十六章]]）。对照表收在 23.7。

---

## 23.2 LWIP_DEBUG 体系解剖

### 1. 宏的真身：debug.h 的开关语法

所有 lwIP 调试日志都走同一个宏（`src/include/lwip/debug.h`）：

```c
#ifdef LWIP_DEBUG
#define LWIP_DEBUG_ENABLED(debug) (((debug) & LWIP_DBG_ON) && \
                                   ((debug) & LWIP_DBG_TYPES_ON) && \
                                   ((s16_t)((debug) & LWIP_DBG_MASK_LEVEL) >= LWIP_DBG_MIN_LEVEL))
#define LWIP_DEBUGF(debug, message) do { ... } while(0)
#else
#define LWIP_DEBUG_ENABLED(debug) 0
#define LWIP_DEBUGF(debug, message)          /* 整段编译为空 */
#endif /* LWIP_DEBUG */
```

三个量各管一件事：

| 参数   | 取值                                                                                             | 作用                                       |
| ------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------ |
| 总开关 | `LWIP_DEBUG` 是否定义                                                                            | 不定义则所有调试代码被预处理器删除，零开销 |
| 类型位 | `LWIP_DBG_TRACE(0x40)` / `LWIP_DBG_STATE(0x20)` / `LWIP_DBG_FRESH(0x10)` / `LWIP_DBG_HALT(0x08)` | 按性质过滤同一模块内的大量消息             |
| 级别位 | `LWIP_DBG_MASK_LEVEL=0x03`：ALL/WARNING/SERIOUS/SEVERE                                           | 只有 `>= LWIP_DBG_MIN_LEVEL` 的消息放行    |

每个模块有自己的宏（`TCP_DEBUG`、`ETHARP_DEBUG`、`PBUF_DEBUG`……），调用形如 `LWIP_DEBUGF(TCP_DEBUG, ("..." ))` 或再 OR 一个类型位。这些模块宏的默认值在 `opt.h` 里全是 `LWIP_DBG_OFF`。

### 2. 输出落到哪：IDF 的两个通道

IDF 适配层 `port/esp32xx/include/arch/cc.h` 决定了日志长什么样：

```c
#ifdef CONFIG_LWIP_DEBUG_ESP_LOG
// lwip debugs routed to ESP_LOGD
#define LWIP_PLATFORM_DIAG(x) LWIP_ESP_LOG_FUNC x   /* tag 固定 "lwip"，级别 Debug */
#else
// lwip debugs routed to printf
#define LWIP_PLATFORM_DIAG(x)   do {printf x;} while(0)
#endif
```

默认走裸 `printf`——所以开调试前要保证控制台信道扛得住流量（`idf.py monitor` 的虚拟 UART 比真机 UART 快得多）；`menuconfig` 里 `Component config → lwIP → Enable LWIP Debug` 下勾上 `Route LWIP debugs through ESP_LOG interface` 后，改走 `ESP_LOGD("lwip", ...)`，可以被 IDF 日志级别统一压掉。

### 3. Kconfig 入口（拼写以源码为准）

`components/lwip/Kconfig` 第 1449 行起就是完整菜单，全部逐字核实过：

```text
Component config -> lwIP
  [ ] Enable LWIP Debug                      (CONFIG_LWIP_DEBUG，总开关，默认 n)
      [*] Route LWIP debugs through ESP_LOG  (CONFIG_LWIP_DEBUG_ESP_LOG)
      --- 以下每项都 depends on LWIP_DEBUG ---
      [ ] Enable netif debug messages        (CONFIG_LWIP_NETIF_DEBUG)
      [ ] Enable pbuf debug messages         (CONFIG_LWIP_PBUF_DEBUG)
      [ ] Enable etharp debug messages       (CONFIG_LWIP_ETHARP_DEBUG)
      ...
      [ ] Enable TCP debug messages          (CONFIG_LWIP_TCP_DEBUG)
      [ ] Enable UDP debug messages          (CONFIG_LWIP_UDP_DEBUG)
```

映射关系在 `port/include/lwipopts.h`：

```c
#ifdef CONFIG_LWIP_DEBUG
#define LWIP_DEBUG                      LWIP_DBG_ON
#else
#undef LWIP_DEBUG
#endif

#ifdef CONFIG_LWIP_TCP_DEBUG
#define TCP_DEBUG                       LWIP_DBG_ON
#else
#define TCP_DEBUG                       LWIP_DBG_OFF
#endif
```

> [!tip] 注意类型位的缺失
> IDF 把 `TCP_DEBUG` 映射为纯 `LWIP_DBG_ON`（不带 TRACE/STATE 位修饰），且 Kconfig **没有暴露** `LWIP_DBG_MIN_LEVEL` 和模块宏的组合自由度。想要 finer-grained 控制（比如只看 STATE 类消息），要么仿照第十一章的 `-include` 注入手法自己定义模块宏，要么接受全量输出。

### 4. 运行时动态调节：在本版 lwIP 是死路

老教材会说"lwIP 有 `u8_t debug_flags` 全局变量可以运行时调"。我在 2.2.0-dev 源码里确认了：**这个变量已经不存在**。`debug.h` 全文没有 extern 符号；`LWIP_DEBUG_ENABLED()` 引用的是**编译进指令流的常量位测试**。因此：

| 动作                                                | 本版本可行性                                                             |
| --------------------------------------------------- | ------------------------------------------------------------------------ |
| 编译期按模块开/关                                   | 可行（Kconfig 或自定义头），推荐                                         |
| 编译期调 `LWIP_DBG_MIN_LEVEL`                       | 可行（自己 `-D` 覆盖，opt.h 用 `#if !defined` 让位）                     |
| 运行时切换某模块 trace                              | **不可行**——除非编译时预留了多个等级的变体                               |
| 运行时关 mbedTLS 的 `mbedtls_debug_set_threshold()` | 可行（那是 mbedTLS 自己的运行时阈值机制，ch22 在用过之后静音过握手日志） |

"不淹没"的现实策略就两条：**最小集合开模块**（比如只 `CONFIG_LWIP_TCP_DEBUG=y`，DHCP/ARP/ip6 一律不开），加上**分阶段窗口式观测**（先把现场录下来，再增量开模块重跑）。

---

## 23.3 统计体系：一张表、一套增量、三件套

### 1. stats_display() 全表与 IDF 的"半张表"

`CONFIG_LWIP_STATS=y` 后（IDF 默认 n！需要显式打开），一句 `stats_display()` 就吐出全表。本章实测截取（run2，章节实验工程在破案阶段后自动打印；中段同构段落省略）：

```text
==== FULL STATS TABLE ====
LINK
	xmit: 136
	recv: 136
	fw: 0
	drop: 0
	memerr: 0
	cachehit: 0
        （chkerr/lenerr/rterr/proterr/opterr/err 均为 0，下同）

ETHARP
	xmit: 7
	recv: 1
	cachehit: 1

IP_FRAG                     ← 分片/重组节，全程未动
	xmit: 0

ICMP                        ← 注意：xmit=0 而 recv=3，见下方解读
	xmit: 0
	recv: 3

UDP
	xmit: 2
	recv: 2
	cachehit: 2

TCP
	xmit: 133
	recv: 133
	memerr: 0
	cachehit: 55

SYS
	sem.used:  0
	mbox.err:  0
	（sem/mutex/mbox 全家皆 0，无资源耗尽迹象）
```

各节顺序：LINK → ETHARP → IP_FRAG → IPv6 FRAG → IP → ND → IPv6 → IGMP → MLDv1 → ICMP → ICMPv6 → UDP → TCP → SYS——**没有 MEM、没有 MEMP**：IDF 全堆化把上游统计表的上半张整个掏空了，内存观察请去 heap（下文第三件套）。另两个必背点：

1. **ICMP xmit=0 但 recv=3**：esp_ping 用 SOCK_RAW socket 自建 echo 头直发（`apps/ping/ping_sock.c` 走 `sendto()`），绕过了 `icmp.c` 的发送记账；应答回来经 `icmp_input` 才进了 recv 计数。看懂一张表的前提是知道每格由谁写。
2. **TCP.cachehit=55**：55 次路由缓存命中，对应本章几十次 loopback 往返的路由查找——每个计数格子背后都有一个具体的函数路径在写它。

两个必背点：

1. **MEM/MEMP 段不存在**——IDF 全堆化（`MEM_LIBC_MALLOC=MEMP_MEM_MALLOC=1`）把这上半张表整个掏空了，内存观察请去 heap（下文第三件套）。上游文档/教程里的 `mem.avail`、memp 池列在这里永远找不到。
2. **ICMP xmit=0 但 recv=3**：esp_ping 用 SOCK_RAW socket 自建 echo 头直发（`apps/ping/ping_sock.c` 走 `sendto()`），绕过了 `icmp.c` 的发送记账；应答回来经 `icmp_input` 才进了 recv 计数。看懂一张表的前提是知道每格由谁写。

### 2. snap-diff：绝对值没用，增量才有信息

表的意义在于**前后差**。[[ch9-ip4-icmp|第九章]]给过 `snap_take/snap_diff` 范式，核心十行（本章实验工程直接内置）：

```c
typedef struct { uint32_t v[12]; } proto_snap_t;
static void snap_take(proto_snap_t *s) {
    const struct stats_proto *p = &lwip_stats.tcp;   /* struct stats_ lwip_stats 全局符号 */
    s->v[0]=p->xmit; s->v[1]=p->recv; s->v[3]=p->drop;
    s->v[6]=p->memerr; s->v[8]=p->proterr; /* …其余字段同理 */ }
static void snap_diff(const char *tag, const proto_snap_t *a, const proto_snap_t *b);
```

对本章破案（23.6）的每次 connect 前后各拍一张，真实输出：

```text
[tcpdiff] first-extra-conn:  xmit=8 recv=8 cachehit=2    ← 握手、探针、ACK 的完整一锅
[tcpdiff] next-extra-conns:  xmit=5 recv=5 cachehit=5    ← 一条连接、五个 SYN 的自问自答
```

这里有个 loopback 特有的读表技巧：**xmit 和 recv 永远同步增长**——因为发给 127.x 的包转一圈立刻变成自己的入站段（先记 xmit 再触发 recv），所以两者相等不能说明"没有丢包"，丢包发生在入站处理深处（本例是 listen backlog 检查）。cachehit 同步增长同理。**统计告诉你"哪类事件发生了几次"，hook/gdb 告诉你"具体哪一包怎么处理的"**——两层合起来才是完整证据链。

### 3. heap 三件套及其陷阱（沿用 ch22 修正口径）

```text
[mem] boot-baseline  free=279840 largest=147456 min-ever=279840
[mem] post-ping      free=247812 largest=122880 min-ever=244528
[mem] post-case      free=244924 largest=118784 min-ever=236204
```

- `heap_caps_get_free_size()`：当前自由总量；
- `heap_caps_get_largest_free_block()`：最大连续块——**判能否装下某个大对象的唯一可靠指标**；
- `heap_caps_get_minimum_free_size()`（min-ever）：历史最低水位。

陷阱两条（[[ch22-tls-esp-tls-mbedtls|第二十二章]]用血泪修正过的口径）：min-ever 是**多区域 sum-of-minima**，跨越阶段直接相减会失真，正确姿势是"阶段边界差 + 周期采样窗最小值"双指标并用；free 正常回涨不代表没事，要看 largest 有没有跟着涨（碎片化三联征：free 回涨 / largest 不动 / min-ever 单调下降，见 [[ch5-memory-management|第五章]]）。

---

## 23.4 抓包的三条路：各自的视野

在 QEMU + openeth 环境，"抓包"有三条可达路径。先用一句话概括差异，再看实测。

### 路径 a：宿主机 `tcpdump -i lo` ——看 SLIRP 之外的主机侧真相

guest 发往 10.0.2.2 的 TCP 连接最终会落在宿主机 loopback 同端口（SLIRP 特性，ch8/ch21 已验证）。hostfwd 方向同理：宿主机连 `127.0.0.1:8031`，SLIRP 转发进 guest :8888。实测一条探针流量的两端视角（左边是你抓到的，右边 guest 内 hook 同时打出的，端口号严格对应 44768）：

```bash
sudo timeout 14 tcpdump -i lo -nn tcp port 8031 -c 60 -w /tmp/ch23.pcap &
python3 tools/host_probe.py 6          # 宿主机侧定时探针
```

```text
06:15:33.813068 IP 127.0.0.1.44768 > 127.0.0.1.8031: Flags [S], length 0
06:15:33.813086 IP 127.0.0.1.8031 > 127.0.0.1.44768: Flags [S.], length 0
06:15:33.813100 IP 127.0.0.1.44768 > 127.0.0.1.8031: Flags [.], ack 1, length 0
06:15:33.813134 IP 127.0.0.1.44768 > 127.0.0.1.8031: Flags [P.], seq 1:15, length 14
...（为排版略去每行的 win/options 字段，其余逐字照抄）
```

配对的 guest 侧 `[ip4in]` 输出（同一次运行）：

```text
[ip4in] 10.0.2.2:44768 > 10.0.2.15:8888 S    len=0
[ip4in] 10.0.2.2:44768 > 10.0.2.15:8888 A    len=0
[ip4in] 10.0.2.2:44768 > 10.0.2.15:8888 AP   len=14
```

### 路径 b：`LWIP_HOOK_IP4_INPUT` 注入 —— guest 协议栈 IP 层的眼睛

第十一章的手法：注入头被强制包含进 lwIP 所有编译单元，`ip4.c` 入口的 `LWIP_HOOK_IP4_INPUT(p, inp)` 调我们的钩子。返回 0 即纯观测、不改包、不夺所有权：

```c
/* main/ch23_inject.h （根 CMakeLists: add_compile_options(-include ...)）*/
#define LWIP_HOOK_IP4_INPUT ch23_ip4_input_hook
struct pbuf; struct netif;
int ch23_ip4_input_hook(struct pbuf *p, struct netif *inp);   /* lab_main.c 实现 */
```

关键红利：**loopback 流量也经过这里**。发送 127.x 的包并不进网卡，而是 `netif_loop_output()` 把 pbuf 拷贝挂进 `loop_netif.loop_first` 队列，`netif_poll()` 再喂回 `tcpip_input() → ip_input()`（`src/core/netif.c`）。所以 VM 内自环的两端、"看不见的网络"，照样能逐包取证——这是 23.6 破案的主力证据源。

注意它的盲区：ARP 帧不是 IP 包（宏名就叫 IP4_INPUT，只在 ip4_input() 生效）；驱动层丢弃的帧到不了这里。

### 路径 c：`linkoutput` 包装计数 ——驱动层出口的秤

第十二章/十七章的手法：在拿到 lwip `netif*` 后换 `n->linkoutput` 指针套一层壳，计数并放行原函数（替换必须在 tcpip_thread 内执行，标准做法是 `tcpip_callback((tcpip_callback_fn)install_fn, NULL)`）。本章壳的实现只需 8 行，输出：

```text
[tx ] len=42 pkts=1 bytes=42      ← ARP 小帧们
[tx ] len=106 pkts=2 bytes=148    ← DHCP
[tx ] len=58 pkts=8 bytes=544
```

三条路视野对比表：

| 视野项                    | a) tcpdump -i lo      | b) IP4_INPUT hook               | c) linkoutput 壳       |
| ------------------------- | --------------------- | ------------------------------- | ---------------------- |
| 看得到 SLIRP/hostfwd 流量 | 仅宿主机视角一段      | 仅 guest 视角一段               | TX 方向仅出网卡时      |
| guest 内部 loopback       | **看不到**（不进 lo） | **看到**（走 ip_input）         | **看不到**（不经驱动） |
| ARP/DHCP 帧级细节         | 另加过滤器可见        | ARP 不可见（非 IP4）            | TX 可见、RX 不可见     |
| 时间戳口径                | 主机时钟              | `sys_now`/log 时间（10ms 网格） | 同左                   |
| 开销/侵入                 | 零侵入，但要 sudo     | tcpip 线程内一行 printf         | 同左                   |

> [!note] RX 方向还有第四条路吗？
> 有：`esp_eth_update_input_path()` 覆写 glue 层输入路径（ch17 配对手法），位置介于驱动与 lwIP 之间——对 openeth 场景它是 RX 进 lwIP 前的最后一站；本章为聚焦未启用，破案时 b 已经足够靠前。

---

## 23.5 gdb 活体检剖：不停世界，只看一眼

QEMU 的 `-s` 就是 gdbserver。两种姿势：

**姿势 1，暂停起步抓分配路径**（配合 [[ch24-debugging-tracing-pitfalls|FT 系列第廿四章]]的双终端直觉）：

```bash
qemu-system-xtensa ... -S -s -nographic &      # -S: 上电即暂停
xtensa-esp32-elf-gdb -batch -x tools/ch23_tcpalloc.gdb build/*.elf
```

`tools/ch23_tcpalloc.gdb` 内容：`target remote :1234` → `break tcp_alloc` → `continue` → `bt`。首次命中的真实 backtrace——一条直线证明协议栈是单线程邮箱模型（[[ch13-tcpip-thread-mailbox|第十三章]]的活化石）：

```text
Thread 1 hit Breakpoint 1, tcp_alloc (prio=0 '\000') at tcp.c:1851
#0  tcp_alloc (prio=0 '\000')          src/core/tcp.c:1851
#1  tcp_new_ip_type (type=0)           src/core/tcp.c:2010
#2  pcb_new (msg=0x3ffb5d60)           src/api/api_msg.c:673
#3  lwip_netconn_do_newconn (m=...)    src/api/api_msg.c:711
#4  tcpip_thread_handle_msg (...)      src/api/tcpip.c:162
#5  tcpip_thread (arg=0x0)             src/api/tcpip.c:148
#6  vPortTaskWrapper (...)             port.c:147
```

应用调 `socket()` 只是往邮箱投递消息；真正的 PCB 出生发生在 tcpip_thread 的执行帧里。想断点观察"杀链"同理：`break tcp_pcb_remove`、`break tcp_close_shutdown_fin` 能抓住每一次 PCB 死亡瞬间的调用者。

**姿势 2，活体 attach 巡检 PCB**（系统跑着不管它，gdb 连上瞬间 target 会被打断，检查完 detach 继续）：

```bash
timeout 150 qemu-system-xtensa ... -s -nic user,...,hostfwd=tcp::8031-:8888 &
# 等 firmware 进入 keepalive 窗口后：
xtensa-esp32-elf-gdb -batch -x tools/ch23_inspect.gdb build/*.elf
```

巡检脚本遍历四张全局 PCB 链表（全部是非 static 全局符号：`tcp_bound_pcbs` / `tcp_listen_pcbs.pcbs` / `tcp_active_pcbs` / `tcp_tw_pcbs`，定义于 `src/core/tcp.c`），实测输出摘录：

```text
===== LISTEN pcbs =====
LISTEN port=23210 backlog=2 accepts_pending=0 next=0x3ffbfb40
LISTEN port=8888   backlog=2 accepts_pending=0 next=0x3ffbfb90
LISTEN port=23211 backlog=2 accepts_pending=0 next=(nil)

===== ACTIVE pcbs =====
（空）
===== TIME_WAIT pcbs =====
TW lport=64195 rport=23210 next=0x3ffc0024
TW lport=64194 rport=23210 next=0x3ffbff50
TW lport=64186 rport=23211 next=0x3ffbfbe0
TW lport=64177 rport=23210 next=(nil)

===== core / current tasks =====
$1 = "IDLE0\000..."      $2 = "IDLE1\000..."
```

读法要点：三个 LISTEN 全活着、`accepts_pending=0` 说明积压已清空；ACTIVE 空 + TW 十五条 = 当时只有客户端主动关闭留下的躯壳。这四个链表加上 `loop_netif.loop_first`（loopback 待处理队列）与 `lwip_stats.tcp.*`，就是 lwIP 的全套"生命体征"。工具链 gdb 位于 `~/.espressif/tools/xtensa-esp-elf-gdb/12.1_*/bin/xtensa-esp32-elf-gdb`。

> [!tip] QEMU gdbserver 没有内核线程感知
> QEMU 把线程模型暴露为**两个核**而非任务列表（真机 JTAG/OpenOCD 才有 RTOS 感知），所以要像上面那样手动读 `pxCurrentTCBs[n]->pcTaskName`——这套技巧与 FT 系列第廿四章完全通用。全 IDLE 说明我们 attach 的时机赶上了所有任务都阻塞、cpu only 心跳，这也是真实嵌入式系统的常态。

---

## 23.6 破案实战：ch22 悬案② 的完整解剖

工程：`practice/lwip-ch23-debugging-toolbox/`（构建/运行命令见其 README，或 23.9 的最小复现集）。目标悬案来自 [[ch22-tls-esp-tls-mbedtls|第二十二章]] 的留档记录："**guest 内 loopback 明文服务仅第一条连接可用，后续 connect 全 RST**"。

### 1. 现象与复现设计

复刻 ch22 的触发拓扑做两阶段：PHASE-L2 先建立连接 A 并保持存活，然后在 127.0.0.1:23210 上连续再拨 4 条新连接（每条拨通后 echo 一条探针载荷）。同期挂载三路观测：hook 打包级流水、snap-diff 拍计数器、修复版服务器 :23211 作对照组。

实测现象（`runlogs/run2-case.log`，摘要）：

```text
[L2] A: connect OK fd=58 (kept open) → echo OK
[L2] #0 FAILED            ← recv 返回 errno=11（EAGAIN，等不到回声）
[L2] #1 FAILED            ← 同上
[L2] #2 FAILED            ← connect errno=113，耗时 6.4 秒
[L2] #3 FAILED            ← 同上
[L2] A still alive: echo -> OK     ← 原 connection 安然无恙

[L2b-FIXED] #0..#3 connect+echo OK（584~1014us，四次全成功）
```

### 2. 取证：包到底走到哪一步死了？

hook 流水线（第一个新连接 #0）：

```text
[ip4in] 50764 > 23210 S    len=0      ← SYN 到达
[ip4in] 23210 > 50764 SA   len=0      ← SYN|ACK 回复了！（backlog 没满）
[ip4in] 50764 > 23210 A    len=0      ← 三次握手完成
[ip4in] 50764 > 23210 AP   len=14     ← 客户端发出 14 字节探针
[ip4in] 23210 > 50764 A    len=0      ← TCP 层收到了，还回了 ACK……
                                  ……然后呢？没有任何 P 位出站包
[cli ] recv r=-1 errno=11 (want 14)   ← 2 秒后客户端超时
```

而第二个失败模式（#2）完全不同：SYN 发了五遍（初始 + `CONFIG_LWIP_TCP_SYNMAXRTX=4` 次重传，指数退避），**每发一发 hook 都看见它进来（loopback 的自问自答），但 SA 一个都没等到**，6.4 秒后 connect 判死返回 errno=113：

```text
[ip4in] 50766 > 23210 S    len=0      ← ×5：初发 + 4 次重传
[tcpdiff] next-extra-conns: xmit=5 recv=5 cachehit=5   ← 五进五出全在 IP 层记账了
[cli ] connect 127.0.0.1:23210 FAILED errno=113 (6390014 us)
```

两种死亡姿势并存：

1. 握手正常、TCP 收了数据并 ACK、应用却永远不给回——**数据黑洞**；
2. SYN 被彻底无视、按退避节奏空转致死——**静默丢弃**。
   以及最重要的负证据：**全程 0 个 RST 包**（我 grep 了整份日志的 flags=R 行，数量为零）。

### 3. 定位：listen PCB 到底还在不在？（诚实的猜测被证伪）

按照惯例大胆假设：会不会 listen PCB 被某种老化机制拆了，后续 SYN 因"无 PCB 匹配"被判死刑（`tcp_in.c` 里的注释确实写着 no matching PCB found → send RST）？顺着这条线索用 23.5 的活体巡检验证——结果 PCB 全家福显示三个 LISTEN 作业全部健在、ACTIVE 空、一切平静如初。**老化假说当场证伪**。

那静默的 SYN 丢弃发生在哪？翻 `tcp_in.c` 的 `tcp_listen_input()`：

```c
#if TCP_LISTEN_BACKLOG
    if (pcb->accepts_pending >= pcb->backlog) {
      LWIP_DEBUGF(TCP_DEBUG, ("tcp_listen_input: listen backlog "
                              "exceeded for port %"U16_F"\n", tcphdr->dest));
      return;                                   /* 静默 return，连 RST 都不发 */
    }
#endif
    npcb = tcp_alloc(pcb->prio);
    if (npcb == NULL) { ...同样静默 return，只记 memerr... }
```

这正是批量事实（Batch 2）早就警告过的形状："listen PCB 分配失败时 `tcp_listen_input` **静默丢弃 SYN（不发 RST）**"。backlog 为何满？——因为**连接 A 的服务任务还堵在 `recv(A)` 里**：单任务串行 `accept→recv 循环` 的模型，遇到不会自动让位的并发场景（A 永远不断开），`accept()` 再也不会被执行；挂在 backlog 里的两个 pending 吃满 `listen(ls, 2)` 之后，第三个及以后的 SYN 只能等死。

### 4. 让 lwIP 自己开口：debug 变体的临门一脚

切到 `sdkconfig.debug.defaults`（`CONFIG_LWIP_DEBUG=y` + `CONFIG_LWIP_TCP_DEBUG=y`）重新构建重跑，LWIP_DEBUG 直接点名元凶（`runlogs/run5-debug.log`）：

```text
TCP connection request 62484 -> 23210.
tcp_listen_input: listen backlog exceeded for port 23210     ← 判决书
```

顺带出现了两个值得截图裱起来的中间信号：

```text
tcp_recved: received 14 bytes, wnd 5760 (0).   ← TCP 层"收到"了黑洞里的 14 字节
tcp_fasttmr: delayed ACK                        ← 解释了那些孤零零的 A 包
```

同时，两处真正会发 RST 的 debug 点位（本变体中我通过注入头额外点亮 `TCP_RST_DEBUG`）**一次都没响**：

```c
LWIP_DEBUGF(TCP_RST_DEBUG, ("tcp_input: no PCB match found, resetting.\n"));
LWIP_DEBUGF(TCP_RST_DEBUG, ("tcp_listen_input: ACK in LISTEN, sending reset\n"));
```

### 5. 结论：真相修正 + 完整因果链

| 维度     | 记录中的说法             | 本章复现实测                                                                              |
| -------- | ------------------------ | ----------------------------------------------------------------------------------------- |
| 故障表现 | "第一条可用，后续全 RST" | 第一条可用；后续分两类死（黑洞 / 无响应直至超时）；RST 数量 = 0                           |
| 根因     | 未定                     | 单任务串行 accept × `listen(backlog=2)` × TCP_LISTEN_BACKLOG 静默丢弃；A 存活期间永不恢复 |
| 缺陷归属 | 怀疑 lwIP                | **应用编程模型的锅**：lwIP 行为完全符合设计（该路径对内存/拥塞保护本来就不承诺通知）      |
| 修复成本 | —                        | 加一对比照：每连接独立 worker，四次再拨全过（584~1014 µs）                                |

致"全 RST"原始记录的一个诚实勘误：当初的现象描述可能有偏差或混入了 SLIRP 外环行为（ch22 第一悬案所在的那条路，那里的 SLIRP 确实会在一些情况下代发 RST）。因为当时没有留下包级流水，无法回溯验证到底看见了什么。**这正是本章的方法论教训：现象记录必须落到包级证据，眼睛在并发世界里是最不可信的工具。** 若你在自己的环境里真的看到循环 RST，优先查三件事：`tcp_abort()` 路径（reader 数据被拒绝/ linger=0 close）、外部代理/防火墙代发的 RST、以及 tcpdump 与现场时序的对齐。

> [!warning] 这案子教会我的三件事
> ① "全 X" 类概括词汇永远是嫌疑犯——先把 X 逐个数出来再谈分布；② 立案的假说要用最快的方式证伪（活体 PCB 巡检花了不到一分钟），而不是顺着假说继续加戏；③ 一个 bug 的最终解释常常又土又简单：一个单线程模型撞上一个无保护的资源池。复杂系统的 bug 也遵守奥卡姆剃刀。

---

## 23.7 常见坑速查表（错误码 ↔ 根因 ↔ 验证）

浓缩自全系列实测（CONVENTIONS Batch 1~6沉淀），遇错先对号：

| 症状/错误码                        | 最可能根因                                                      | 最快验证手段                                                                  |
| ---------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| connect `errno=113`(EHOSTDOWN)     | SYN 被静默丢弃：backlog 满 / `tcp_alloc` 失败                   | hook 数 SA 有无；debug 变体看 backlog exceeded；gdb 看 LISTEN.accepts_pending |
| 第 N 个 `socket()` 失败 `errno=23` | fd 槽耗尽（FD_SETSIZE−MAX_SOCKETS）                             | 数 busy slots；核对 `CONFIG_LWIP_MAX_SOCKETS`                                 |
| accept 看到 `errno=113`            | listen PCB 创建失败（Batch 2 的语义错位）                       | 同 113 行                                                                     |
| 吞吐涓流/停滞                      | 忘注册 `tcp_sent()` 回调（泵停了）                              | ch6 的 ACK 驱动补发套路                                                       |
| 延迟固定台阶 ~200ms                | Nagle/延迟 ACK 对撞                                             | `TF_NODELAY` flag（`tcp_nagle_delay` 字段不存在！）                           |
| 堆刷屏 malloc 失败、计数器冻结     | 全堆化下驱动层丢帧（openeth RX 第一步 malloc 失败）             | mem_stamp 三件套 + openeth INT_BUSY 日志                                      |
| free 回涨但 largest 不动           | 碎片化三联征之一                                                | 周期采样窗 min + min-ever 双指标                                              |
| TLS 死于 alloc(16717)              | mbedtls 4.x 内存不足 `-0x008D`（PSA_ERROR_INSUFFICIENT_MEMORY） | ch22 的 `alloc failed` 日志指纹                                               |
| ICMP ping 10.0.2.15 不通           | SLIRP 不支持主机→guest 方向 ICMP                                | 换 UDP/discard 探针造确定性流量                                               |
| ping 同刻第二次恒超时              | SLIRP 会话边界毛刺                                              | 同上，避免并行会话                                                            |
| 亚毫秒计时失真                     | `sys_now()` 是 10ms tick 网格                                   | 用 `esp_timer_get_time()`                                                     |
| 改了 sdkconfig.defaults 没生效     | 老 sdkconfig 覆盖                                               | `rm sdkconfig` 后重建                                                         |
| QEMU 镜像更新无效                  | `idf.py qemu monitor` 静默失败                                  | 手动 merge-bin 兜底（见 README 命令）                                         |

---

## 23.8 Vanilla lwIP 与 ESP-IDF lwIP 对照

| 维度            | Vanilla 2.2.x                                          | ESP-IDF v6                                                                                                                                                                                                                                      |
| --------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| debug 总开关    | 应用在 `lwipopts.h` 写 `#define LWIP_DEBUG` + 每模块宏 | Kconfig 菜单逐模块映射进 `port/include/lwipopts.h`（`CONFIG_LWIP_*_DEBUG`）                                                                                                                                                                     |
| 日志落点        | 由用户 `arch/cc.h` 决定                                | 默认 printf；`CONFIG_LWIP_DEBUG_ESP_LOG` 转 `ESP_LOGD("lwip")`                                                                                                                                                                                  |
| 运行时开关      | 同样静态（本版已无 debug_flags 全局）                  | 同样静态；Kconfig 只解决"编译期拼装"的人机界面                                                                                                                                                                                                  |
| `MEMP/MEM` 统计 | 存在                                                   | **不存在**（全堆化），只剩 `heap_caps_*` 视角                                                                                                                                                                                                   |
| PCB 巡检助手    | 没有                                                   | 现成五件套 `debug/lwip_debug.h`：`dbg_lwip_tcp_pcb_show()`、`dbg_lwip_udp_pcb_show()`、`dbg_lwip_tcp_rxtx_show()`、`dbg_lwip_udp_rxtx_show()`、`dbg_lwip_mem_cnt_show()`（`port/debug/lwip_debug.c` 已编入组件）                                |
| 网络事件旁路    | hooks 手工装                                           | esp_netif 事件流（IP_EVENT/ETHERNET_EVENT）+ ext-callback，覆盖 most 情况；esp_netif 自身没有统一的 stats 出口，还是要回到 lwIP 统计/Hook 层                                                                                                    |
| heap tracing    | N/A                                                    | 接口存在：`components/heap/include/esp_heap_trace.h`（`heap_trace_init_standalone/start/stop`，HEAP_TRACE_LEAKS/ALL 模式）；其中 ToHost 模式依赖 JTAG 通道，standalone 缓冲模式理论上不依赖特殊硬件但本章 QEMU 环境未展开实测，只声明接口存在性 |

IDF 的值得表扬之处是把"哪些旋钮存在"变成了 menuconfig 里能搜到的实体（虽然 MIN_LEVEL 这类细粒度仍需手工 `-D`）；Vanilla 的诚实之处是从不做"帮你兜底"的事——静默丢弃 SYN 这种决定属于协议栈自主裁量，谁用谁知道。

---

## 23.9 实验：全链路取证接力（附最小复现集）

主实验就是 23.6 的破案全过程（工程 `practice/lwip-ch23-debugging-toolbox/`，_phases 一目了然地写在 `lab_main.c` 顶部注释_）。再把综合案例"一次慢回声的全链路取证"的接力顺序定格成checklist，每一棒都有真实输出可回查：

```bash
# ① 起 QEMU（带 hostfwd + gdbserver；端口 8031 已避开全系列占用表）
timeout 150 qemu-system-xtensa -M esp32 -m 4M <flash/drive 参数见 README> \
  -nic user,model=open_eth,hostfwd=tcp::8031-:8888 -s -nographic -no-reboot &

# ② 等待 KEEPALIVE 窗口标记出现（约 t+20s，视宿主负载）
grep -m1 "KEEPALIVE WINDOW" runlogs/run3-host.log

# ③ 物理/外环层：tcpdump 起捕 + python 定时探针
sudo timeout 14 tcpdump -i lo -nn tcp port 8031 -c 60 -w /tmp/ch23.pcap &
python3 tools/host_probe.py 6
```

探针实测数字（同一窗口内）：

```text
probe 0: connect=3.4ms echo_rtt=5.04ms payload=14B match=True   ← 首连吃满 ARP/建链税
probe 1: connect=0.1ms echo_rtt=1.74ms
probe 4: connect=0.1ms echo_rtt=8.08ms                          ← 尾部抖动属 QEMU/SLIRP 毛刺
```

接力逻辑：**ping 基线（0~1ms，物理+IP 健康）→ python 探针发现"慢"集中在首连（connect 3.4ms = ARP 建立 + SLIRP 映射初始化）→ tcpdump 的 [S] 段时间戳把 3.4ms 拆成 SLIRP 前后两段 → 若仍不够，gdb attach 看此刻 PCB/统计（23.5）→ 需要包级铁证则开 debug 变体重跑**。五棒递进，开销与信息量成正比，前面的结论总是给后面的棒缩小搜索范围。

---

## 23.10 小结

- **分诊纪律**：症状不必和根因同层。自上而下定嫌疑范围，自下而上收集证据；两本硬账（ping 基线、错误码方言）永远先算。
- **LWIP_DEBUG 是编译期的门牌系统**：总开关 × 模块宏 × 类型位/级别位四维组合，IDF 经 Kconfig 逐个映射（`CONFIG_LWIP_DEBUG` / `CONFIG_LWIP_TCP_DEBUG`…），输出默认落 printf、可选转 ESP_LOGD；运行时动态调节在 2.2.0-dev 中已无处安放。
- **统计看增量不看绝对值**：`stats_display()` 的 MEM/MEMP 在 IDF 全堆化下缺席；snap-diff 告诉你事件次数，三件套（free/largest/min-ever）告诉你会不会碎。
- **抓包三路的视野互补**：tcpdump(-i lo) 看宿主机侧、IP4_INPUT hook 看 guest IP 层（含 loopback！）、linkoutput 壳看驱动出口——三选二经常必要，哪个都别神化。
- **gdb 是 lwIP 的听诊器**：`-S -s` 从出生开始盯着，attach 巡检四张 PCB 链表不动病人；`tcp_alloc` backtrace 是单线程邮箱模型的最短证明。
- **悬案②终审**：不是"全 RST"，而是单任务串行 accept 导致 backlog 满 + `tcp_listen_input` 静默丢弃 SYN 的复合症；"只有黑盒才神秘，打开盒子每个人都是侦探"。现象描述若不留包级证据，事后只能靠猜。

下一章进入本系列收官：《性能与调优陷阱》。调试章备好了"哪里不对劲"，性能章回答"哪里可以更快"——吞吐预算怎么拆、每层抽成多少、哪些优化是真优化哪些是安慰剂，以及把整套方法论交给下一个接手你设备的人之前，如何写成不会被忽略的文档。见 [[ch24-performance-tuning-pitfalls|第二十四章]]。
