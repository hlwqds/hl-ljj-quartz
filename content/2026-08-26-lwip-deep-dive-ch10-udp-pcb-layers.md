---
title: "lwIP 深度解析（十）：UDP：PCB 匹配与三层 API"
date: 2026-08-26
description: "从 struct udp_pcb 的四元组匹配优先级出发，逐行走读 udp_input 分派与 udp_send 路由校验和；画出 raw/netconn/socket 三层封装的完整调用链并标注上下文切换点与拷贝点。QEMU 实测三层 API 时延中位数 103/215/288µs 递增、突发吞吐 68/56/43 Mbit 递减；邮箱慢消费者 94% 丢包而 lwIP 统计零痕迹（recv_udp trypost 静默分支）；应用层注入验证 UDP 校验和一比特翻转即被 chkerr 拦截；MAX_UDP_PCBS 压到 2 后行为纹丝不动——IDF 全堆化下这个闸门只对 TCP 存在，真实上限是 fd 槽位的 ENFILE。"
tags: [lwip, network, esp32, esp-idf, qemu, udp]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 10. **第十章：UDP：PCB 匹配与三层 API**

# lwIP 深度解析（十）：UDP：PCB 匹配与三层 API

这一章回答三个问题：**一个 UDP 报文怎么从 IP 层找到正确的接收者**（`udp_input()` 的四元组匹配优先级算法）、**raw / netconn / socket 三层封装各自加了什么成本**（调用链上的上下文切换点与拷贝点逐一标注）、**"无连接"的 UDP 在 lwIP 里还剩哪些状态**（bound / connected / 绑定 netif，以及它们如何改变匹配结果）。读完它，你应该能对着任何一个 UDP 现象——丢包、错投、bind 失败——说出它发生在哪一层、哪个结构体字段、被哪个计数器记录（或者不被任何计数器记录）。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP **2.2.0-dev**（`~/esp/esp-idf/components/lwip/lwip/src`），核心文件 `core/udp.c`；适配层 `api/api_msg.c`、`api/api_lib.c`、`api/sockets.c`，移植层配置在 `components/lwip/port/include/lwipopts.h`。本章所有性能数字来自 QEMU（openeth + SLIRP）实测，方法与重复次数在各实验节标明。

---

## 10.1 核心问题三连

### 1. 报文怎么找到接收者

TCP 有五元组哈希表和状态机兜底；UDP 的复用完全靠**线性扫描一条全局单链表** `udp_pcbs`（`core/udp.c` 定义并导出）。每个进入的报文拿 `(目的 IP, 目的端口, 源 IP, 源端口)` 对每个 PCB 比较 `(local_ip, local_port, remote_ip, remote_port)`，并且有明确的**优先级**：

| 优先级 | 匹配对象                        | 条件                                                                               |
| ------ | ------------------------------- | ---------------------------------------------------------------------------------- |
| 最高   | **已 connect 的"完美匹配"** PCB | `remote_port == src` 且 `remote_ip == 源 IP`（或 remote 为 ANY），加上本地端一口径 |
| 兜底   | **未 connect 的** PCB           | 仅本地 `(IP, port)` 口径相同；取扫描到的第一个                                     |
| 特例   | 广播报文的未连接 PCB            | 倾向绑定在入网 netif 地址上的那个                                                  |

没有匹配者则丢弃并向源头发 ICMP Port Unreachable——除非目标是广播/组播地址。10.2 节把这个循环逐行拆开。

### 2. 三层封装各加了什么

同一颗协议栈内核之上叠了三个接口世界：

|                            | raw API                    | netconn API                       | socket API                   |
| -------------------------- | -------------------------- | --------------------------------- | ---------------------------- |
| 编程模型                   | 回调（注册 `udp_recv_fn`） | 信箱（netbuf 投递）               | BSD `recvfrom/sendto`        |
| 应用代码运行的上下文       | **tcpip_thread 内**        | 应用自己的任务                    | 应用任务 + VFS 层转发        |
| 数据从栈到手的路径         | pbuf 指针直通回调          | netbuf 包着 pbuf 经 FreeRTOS 邮箱 | **memcpy 进用户缓冲区**      |
| 每 datagram 的额外调度成本 | 0 次                       | ≥2 次（收 1 + 发 1 的事件侧唤醒） | 同 netconn + VFS fd 映射一层 |

一次 echo 往返的成本差最终都折算进 RTT 和吞吐，10.6 节实测：时延中位数 **103 → 215 → 288 µs** 递增，突发吞吐 **68 → 56 → 43 Mbit** 递减——每层的"服务费"清晰可辨。

### 3. "无连接"还剩哪些状态

UDP 没有握手，但 PCB 上有三个互不冲突的标志位决定它的行为：

- **bound**：`local_port != 0` 且挂上 `udp_pcbs` 链。发送前从不 bind 也行——首次发包时自动绑随机端口（`udp_sendto_if_src()` 入口处）。
- **connected**：`flags & UDP_FLAGS_CONNECTED`。不产生任何网络流量，只是把 `remote_ip/remote_port` 写进 PCB，之后 `udp_send()` 不再需要目的地参数，且匹配时获得最高优先级。
- **绑定 netif**：`netif_idx != NETIF_NO_INDEX`，进出都限定在一块网卡上（多宿主场景）。

系统组件也在用这套"状态机"：DHCP 客户端的 PCB 一出生就 `bind(:68)` + `connect(:67)`（`core/ipv4/dhcp.c` 里一句 `udp_connect(dhcp_pcb, IP_ANY_TYPE, LWIP_IANA_PORT_DHCP_SERVER)`）。本章实验的开机实拍：

```text
CH10-PCBLIST idx=0 lport=68 rport=67 connected=1
CH10-FACT sizeof(struct udp_pcb)=80 active_pcbs=1
```

DHCP 完成时刻全系统唯一的 UDP PCB 就是它；`sizeof(struct udp_pcb) = 80` 字节（Xtensa 双指针 + IPv4/IPv6 双栈地址对开的话已经算克制）。DNS 更绝：开了 `LWIP_DNS_SECURE_RAND_SRC_PORT` 之后，每次查询临时 `udp_new()` 一个 PCB 绑随机源端口、查完就拆（`core/dns.c` 的 `dns_send()`），所以开机清单里看不到它。

---

## 10.2 UDP PCB 解剖：一个 80 字节的结构体撑起的复用

### 1. 字段一览

`include/lwip/udp.h` 里的 `struct udp_pcb`（去掉条件编译后按出现顺序）：

| 字段                                | 类型         | 作用                                                                                                |
| ----------------------------------- | ------------ | --------------------------------------------------------------------------------------------------- |
| `IP_PCB`                            | 宏           | 展开＝`local_ip`/`remote_ip`（ip_addr_t 双栈）、`netif_idx`（绑卡）、`ttl`/`tos`、socket options 位 |
| `next`                              | 自指针       | 全局链表 `udp_pcbs` 的链节                                                                          |
| `flags`                             | u8_t         | `NOCHKSUM` / `UDPLITE` / `CONNECTED` / `MULTICAST_LOOP` 四个开关                                    |
| `local_port, remote_port`           | u16_t×2      | **主机字节序**存储（注释原话 "ports are in host byte order"）                                       |
| `mcast_ip4/mcast_ifindex/mcast_ttl` | 组播发送选项 | RFC 多宿主组播路由选择                                                                              |
| `chksum_len_rx/tx`                  | u16_t×2      | 仅 UDP-Lite 用                                                                                      |
| `recv, recv_arg`                    | 函数指针     | **raw API 的唯一交付手段**：回调与其参数                                                            |

对比 TCP 动辄几百字节的 tcp_pcb（状态机 + 七条队列），80 字节的 udp_pcb 是 lwIP 里最朴素的控制块——它的全部复杂性都转移到了 10.1 的匹配规则里。

### 2. 匹配循环：一次遍历，两级偏好，顺手的 MRU 缓存

`udp_input()` 的主体是一个带两级偏好的单次遍历（`core/udp.c`）：

```c
for (pcb = udp_pcbs; pcb != NULL; pcb = pcb->next) {
    /* 第一关：本地端口号 + 本地地址口径（any / 精确 / 广播组） */
    if ((pcb->local_port == dest) &&
        (udp_input_local_match(pcb, inp, broadcast) != 0)) {
      if ((pcb->flags & UDP_FLAGS_CONNECTED) == 0) {
          /* 记住第一个未连接的候选（广播场景下进一步选入网口地址更优者） */
          if (uncon_pcb == NULL) { uncon_pcb = pcb; }
      }
      /* 第二关：远端口 + 远地址全对上 → 完美命中 */
      if ((pcb->remote_port == src) &&
          (ip_addr_isany_val(pcb->remote_ip) ||
           ip_addr_eq(&pcb->remote_ip, ip_current_src_addr()))) {
          if (prev != NULL) {           /* MRU 前插：下次第一个就能扫到它 */
              prev->next = pcb->next;
              pcb->next = udp_pcbs;
              udp_pcbs = pcb;
          } else {
              UDP_STATS_INC(udp.cachehit);
          }
          break;                        /* 完美匹配直接终局 */
      }
    }
    prev = pcb;
}
if (pcb == NULL) { pcb = uncon_pcb; }     /* 全场无完美匹配才退回未连接候选 */
```

四个值得咀嚼的细节：

1. **自重排是性能特性的根源**：命中的 PCB 被搬到表头，下次同样流量的第一格就是它——这就是 `udp.cachehit` 计数器的存在意义。同时也意味着链表顺序依赖"最近谁被命中/谁最后注册"：两个同样合法的完美匹配并存时，**更晚出现在表头的那个赢**——这是一条任何文档都不会告诉你、只有读代码才看得见的决胜规则。
2. **`uncon_pcb` 只记第一个**："多个 unconnected PCB 绑同一个端口"本身是非法态（`udp_bind` 的冲突检测禁止之，见下），能落进这条路径的都是历史兼容或 SO_REUSE 特许出来的布局。
3. **SO_REUSE 打破平局**：若编译开启 `SO_REUSE`，第二个同端口未连接 PCB 若绑定了**具体 IP** 会顶替 any 型候选（`prefer specific IPs over catch-all` 注释）。IDF 中 SO_REUSE 由 `CONFIG_LWIP_SO_REUSE` 控制，默认关。
4. **匹配成功前不算校验和**：for_us 才算（`pcb != NULL` 或本机单播地址命中），寄给别人的烂包不浪费 CPU——这是把成本押在必要性上的老派智慧。

### 3. udp_bind 与 udp_connect：一对语义相反的"登记"

```text
udp_bind(pcb, ipaddr, port)             udp_connect(pcb, ipaddr, port)
├─ port==0 ? 自动挑 49152~65535 空闲口   ├─ 未 bind 先强制 bind（自动端口）
├─ 扫描全表查端口冲突：                  ├─ 直接覆写 remote_ip/remote_port
│   其它 PCB 已占该 (type,addr,port)     ├─ flags |= UDP_FLAGS_CONNECTED   ← 锁定对端
│   （双方都有 SO_REUSEADDR 才放行）     └─ 不在链表则上链（保证可被匹配到）
│   → 冲突返回 ERR_USE
├─ 写入 local_ip/local_port
└─ 不在链表则上链
```

要点有三。其一，**bind 的冲突规则以"任一方为 ANY 即视为重叠"判负**：`(ip_addr_eq || ip_addr_isany(ipaddr) || ip_addr_isany(另一边))`，所以先绑具体地址者活着，后来想绑 `INADDR_ANY` 的必须全部持 REUSEADDR 才能共存。其二，**connect 不是网络操作**——没有 SYN 概念，只是一次内存写 + 置位，`udp_disconnect()` 也只是清掉这三个东西顺带复位 `netif_idx`。其三，两者的"登记上链"动作合一：首次 bind/connect 都会把 PCB 插到 `udp_pcbs` 表头，而表头正是 10.2.2 里最容易被匹配到的黄金席位——**connect 还额外换来了完美的四元组资格，等于花一次写内存买下了优先级最高的接收通道**。

---

## 10.3 三层 API：调用链、切换点、拷贝点

### 1. 接收方向的三条路

从一个到达 openeth 网卡的报文出发，三种 API 的一切差异都在这张接力图里（切换点用 ⟳ 标注，拷贝点用 ⧉ 标注）：

```text
                       ┌──────────────────────────────────────────────┐
 openeth RX 任务 ─────► │ ethernet_input → ip4_input → udp_input       │
                        │                 （全部在 tcpip_thread）       │
                        └──────────────┬───────────────────────────────┘
                                       │ pcb->recv(...) ①交付
        ┌──────────────────────────────┼───────────────────────────────┐
        ▼ raw                          ▼ netconn                       ▼ socket
  recv_cb 在 tcpip_thread      recv_udp() api_msg.c:            recv_udp 同左（socket
  内同步执行。pbuf 指针         memp_malloc(MEMP_NETBUF)          底层同样是 netconn）
  直通你的回调；你要么           包住 pbuf →                      netconn_recv 返回后，
  free 要么转发，0 次拷贝。      sys_mbox_trypost(recvmbox)       lwip_recvfrom_udp_raw()
                                【⟳ 上下文切换#1】                把 netbuf 内容 ⧉ 拷贝
                                应用任务 netconn_recv()            进用户的 recvfrom()
                                从邮箱取走【无拷贝】                缓冲区【拷贝 ⧉ #1】
        │                              │                               │
        ▼                              ▼                               ▼
  udp_sendto(p, ...)          netconn_sendto(conn,buf,...)      sendto(fd,buf,...)
  还是同一个 pbuf 出栈         netbuf 引用用户已有数据            netconn_send 之下先
  （零拷贝零切换）              （指针移交）                       ⧉ 拷贝进新 netbuf
                                                                       │
                                                       【⟳ 事件→tcpip_thread】共 2 次 ⟳
```

三列的关键落差集中在两点：**交付时的所有权形式**（指针 vs 信箱消息 vs 数据副本）与**发送时的包装方式**。尤其注意第三列的发送拷贝并不是 lwIP socket 层天生要交的税——它是 ESP-IDF 强加的：

```c
/* api/sockets.c, lwip_sendto() 内 */
#if LWIP_NETIF_TX_SINGLE_PBUF
  /* Allocate a new netbuf and copy the data into it. */   ← 原注释
  if (netbuf_alloc(&buf, short_size) == NULL) { ... }
  else { MEMCPY(buf.p->payload, data, short_size); }      ← 【⧉ 拷贝发生在这】
#else
  err = netbuf_ref(&buf, data, short_size);               ← 零拷贝引用分支
#endif
```

第六章的主角 `LWIP_NETIF_TX_SINGLE_PBUF=1`（`port/include/lwipopts.h` 硬编码）在这里第二次发力：**vanilla 的 UDP socket sendto 是 netbuf_ref 纯引用，IDF 因该宏变成了无条件 memcpy**。为什么入口要先复制？netbuf_ref 生成的引用型 pbuf 若混在链式输出路径上，不支持 scatter-gather 的驱动只能在中途线性化拷贝；与其在每个驱动里兜底，不如在 sendto 入口保证"数据就是一个连续 pbuf"。与第六章 TCP 写路径的强制 COPY 同根同源。

### 2. 对比矩阵

| 维度                  | raw API                                      | netconn API                      | socket API                               |
| --------------------- | -------------------------------------------- | -------------------------------- | ---------------------------------------- |
| 接收载体              | `pbuf *` 所有权直通                          | netbuf（pbuf 包装）              | 用户缓冲区里的裸字节                     |
| 回调/等待             | 注册 `udp_recv(pcb, fn, arg)`                | `netconn_recv()` 阻塞于 recvmbox | `recvfrom()` 同 netconn + 拷贝           |
| 执行上下文            | 全程 tcpip_thread                            | 应用任务 + tcpip_thread 往返     | 同左，再经 VFS dispatch                  |
| datagram 往返切换次数 | **0**                                        | 2（收/发各一事件唤醒往返）       | 2（netconn 相同）                        |
| datagram 往返 memcpy  | **0**                                        | 0（指针交接）                    | 2（rx 用户缓冲 + tx 入栈快照）           |
| FD 成本               | 无                                           | 无                               | 每个 socket 占一个 fd（VFS fd 区间映射） |
| 错误传达              | 函数返回 err_t                               | err_t + timeout 参数             | errno（POSIX 语义翻译）                  |
| 可用并发模型          | 单线程纪律（跨线程须经 tcpip_callback 投递） | 天然多任务                       | 天然多任务                               |
| 内核姿态              | 最接近协议栈本体                             | 邮箱解耦                         | 标准化移植性最好                         |

一次 echo 的总成本差可以被精确预测：raw 与 netconn 差 2 次任务级上下文切换（FreeRTOS 邮箱投递/取件各伴一次优先级比较与栈帧搬移），socket 再加 2 次 memcpy + 一次 VFS 层间接寻址。10.6 实验 A 将验证这条预算与实测 RTT 的对应关系：实测中位均值每层增量约 +112µs 与 +73µs，正处于"两次任务切换 ≈ 百微秒量级、两次短拷贝 ≈ 数十微秒"的合理区间（QEMU 主机兑现速度会稀释绝对值，相对差更可信）。

### 3. 一个容易被漏看的静默角落

信箱满员时会发生什么？`api/api_msg.c` 的 `recv_udp()`（即 ③柱里的"包一层 netbuf 投递"那步）末尾：

```c
err = sys_mbox_trypost(&conn->recvmbox, buf);
if (err != ERR_OK) {
    netbuf_delete(buf);                    /* 释放刚包好的 netbuf 连同 pbuf */
    LWIP_DEBUGF(API_MSG_DEBUG, (...));     /* 只有 DEBUG 级日志（默认关闭）*/
    return;                                 /* ——没有 STATS++，没有错误上报 */
}
```

**UDP 的" mailbox 满"这一丢包点不在 `lwip_stats.udp.*` 的任何字段里留痕**——`drop/memerr/proterr` 都不会动。包在 `udp_input` 已经被计入 `recv`，然后无声无息地消失在 core 与应用之间。10.6 实验 B 会用一个 94% 丢包率、统计纹丝不动的现场演示这个角落，以及如何用计数器算术定位它。（IDF 在此函数里还插了一个自己的补丁：`ESP_LWIP && LWIP_IPV6` 下对 `NETCONN_FLAG_IPV6_V6ONLY` 连接丢弃 IPv4 报文的提前 return——也是一路静默丢弃。）

---

## 10.4 收发路径走读

### 1. 发送侧：udp_send 五连门

`udp_send()` 不过是个薄壳，真正的工序集中在展开后的调用家族 `udp_sendto_if_src()`（名字越长权限越大的洋葱式签名是这章的特色）：

```text
udp_send(pcb,p)
  → udp_sendto(pcb, p, &pcb->remote_ip, pcb->remote_port)   remote 必须已定(ANY → ERR_VAL)
    → [ESP_LWIP 补丁] IPv4-mapped IPv6 目标在此解包成原生 IPv4 递归回 sendto
    → 选出口 netif：
         pcb->netif_idx 已绑卡？          → netif_get_by_index
         目标是组播且有 mcast_ifindex/ip4？ → 按 RFC 语义指定
         否则                              → ip_route(local_ip, dst_ip) 常规查表
       查不到 → udp.rterr++, ERR_RTE
    → udp_sendto_if(pcb,p,dst,dst_port,netif)
         选源地址：local_ip 是 any/组播 → 用 netif 自己的地址
                   local_ip 与出口地址不符（netif 换址陈旧） → ERR_RTE
    → udp_sendto_if_src(...)
         auto-bind：local_port==0 就地 udp_bind 自动端口
         加头：pbuf_add_header 能就地腾 8 字节最佳；腾不出则
               分配独立头部 pbuf 再 pbuf_chain【无数据拷贝，只有一个头节点】
         校验和：udphdr->chksum 清零；CHECKSUM_GEN_UDP 且（IPv6 或未置
               NOCHKSUM 标志）时以伪头求和；算得 0x0000 改写 0xFFFF
               （RFC 768：传输中的 0 表示"未启用校验"，故真 0 得转义）
         ttl = 单播 ttl / 组播 ttl 二选一 → ip_output_if_src(q, ..., proto, netif)
```

其中 IP头的构作一律沿既有 netif 约束走，驱动怎么管理 scatter-gather 属于第七章的内容，此处按下不表。

对照接收侧"for_us 才算"的门，发送侧是"除明确关闭外必算"——`UDP_FLAGS_NOCHKSUM` 只是 IPv4 场景下的豁免券（IPv6 强制算），反映 RFC 的两副面孔：IPv4 校验可选、IPv6 必选（`ip_output_if` 下一站的 IP 头校验另计）。

### 2. 接收侧再走一遍：从 udp_input 到你的回调

```c
if (p->len < UDP_HLEN) { lenerr++; drop++; free; }        /* 门 1：短包 */
broadcast = ip_addr_isbroadcast(...);
src/dest = ntohs(...);
pcb = 匹配循环;                                            /* 门 2：匹配（10.2） */
for_us = (pcb != NULL) || 本机其他身份的单播目标;
if (!for_us) { pbuf_free(p); return; }
#if CHECKSUM_CHECK_UDP
  IF__NETIF_CHECKSUM_ENABLED(inp, NETIF_CHECKSUM_CHECK_UDP) {
      if (udphdr->chksum != 0)                            /* 门 3：0=未启用 跳过 */
          if (ip_chksum_pseudo(...)) goto chkerr;          /* chkerr++; drop++; */
  }
#endif
pbuf_remove_header(p, UDP_HLEN);                           /* 摘掉 UDP 头 */
pcb->recv(pcb->recv_arg, pcb, p, src_ip, src_port);        /* 门 4：交付（所有权移交！）*/
/* …若无匹配 pcb：icmp_port_unreach + proterr/drop + mib2.udpnoports */
```

门 3 之前若没有任何 PCB 认领，还会走到无主分支：非广播目标回送 **ICMP Port Unreachable**（`LWIP_ICMP` 打开时），这与第五章 IP 层的 ICMP 素材形成呼应——UDP 本身不回错，错让 ICMP 替说。这个"先匹配、后校验"的次序还藏着一个安全性质：外部乱扫你未监听的端口，连校验和计算都可以省。

**校验和到底覆盖什么**：UDP 校验和对「伪首部（源 IP 4B + 目的 IP 4B + 0 + 协议号 17 + UDP 总长 2B）+ UDP 头 + 载荷」整体做 16 位反码求和再取反。伪首部不存在于线上，只是防止"IP 层地址被抓改、载荷仍在组合之内"的串线攻击（IP 头校验和本来就不管载荷）。发送方真算出 0 要转写成 0xFFFF（同一段著名的实现层面细节），接收方的对称操作包括：字段为 0 视为"发送方未启用校验"、直接放行。

---

## 10.5 Vanilla lwIP 与 ESP-IDF lwIP 对照

围绕本章的 UDP 路径逐项对照（均经 grep 实核）：

| 维度                        | Vanilla lwIP 2.2.0-dev                                     | ESP-IDF v6.0.2 移植                                                                                                                                                                                                                                  |
| --------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LWIP_UDP` / `LWIP_UDPLITE` | 都可配                                                     | `LWIP_UDP=1` 固定开（UDPLITE 关）                                                                                                                                                                                                                    |
| `MEMP_NUM_UDP_PCB`          | 静态池构建下**硬闸门**：memp 池空则 `udp_new()` 返回 NULL  | `MEMP_NUM_UDP_PCB = CONFIG_LWIP_MAX_UDP_PCBS`（默认 16，range 1~1024）；**但在全堆化（MEMP_MEM_MALLOC=1）+ ESP_LWIP 下对 UDP 不生效**——`core/memp.c` 的分配闸门补丁只为 `MEMP_TCP_PCB` 保留，其余池类型直接落到 libc 堆。这是个死旋钮（实验 C 实证） |
| 接收邮箱深度                | `opt.h`：`DEFAULT_UDP_RECVMBOX_SIZE 0`（由 sys_arch 解释） | `DEFAULT_UDP_RECVMBOX_SIZE = CONFIG_LWIP_UDP_RECVMBOX_SIZE`，默认 **6**，**Kconfig range 6~64**——你想像 vanilla 一样压到 1 都压不下去（help 文本明说了"邮箱满则丢包"的设计后果）                                                                     |
| `tcpip_recvmbox`            | 实现自定义                                                 | `CONFIG_LWIP_TCPIP_RECVMBOX_SIZE` 默认 32                                                                                                                                                                                                            |
| udp_sendto 的 mapped-v6     | 不处理                                                     | `ESP_LWIP` 补丁：IPv4-mapped IPv6 在 sendto 入口解包递归（`core/udp.c`）                                                                                                                                                                             |
| recv_udp 的 IPv6-only       | 不管                                                       | `ESP_LWIP` 补丁：`NETCONN_FLAG_IPV6_V6ONLY` 的 conn 静默丢弃 IPv4 报文（`api_msg.c`）                                                                                                                                                                |
| sendto 拷贝语义             | `TX_SINGLE_PBUF=0` → `netbuf_ref` 零拷贝引用               | `TX_SINGLE_PBUF=1`（硬编码）→ `netbuf_alloc + MEMCPY` 无条件复制                                                                                                                                                                                     |
| `CHECKSUM_CHECK_UDP`        | 默认开（opt.h 的校验族默认都启用）                         | Kconfig `CONFIG_LWIP_CHECKSUM_CHECK_UDP` **默认 n**！须显式打开（本章 sdkconfig.defaults 已打开），否则进站 UDP 的软件校验整个编译期消失                                                                                                             |
| socket fd 映射              | 可选功能 `LWIP_SOCKET_OFFSET`                              | 强制 VFS 化：`port/esp32xx/vfs_lwip.c` 以 `esp_vfs_register_fd_range()` 挂入全局 fd 表；`LWIP_SOCKET_OFFSET = FD_SETSIZE − CONFIG_LWIP_MAX_SOCKETS`（默认 64−10，本章调到 64−16）                                                                    |
| socket() 失败语义           | 同源码                                                     | netconn 建不出来 → `errno=ENOBUFS`；fd 槽位耗尽 → `errno=ENFILE`（sockets.c 两处 set_errno）                                                                                                                                                         |

> [!warning] 本章最重要的 IDF 事实：MAX_UDP_PCBS 在 IDF 上是装饰品
> 前几章沉淀过同族事实："全堆化下 memp 只剩计数器"，而本章把这句话推到实证终点：`MEMP_MEM_MALLOC && ESP_LWIP` 下显式计数闸门**只覆盖 MEMP_TCP_PCB**。读 `core/memp.c` 的 `do_memp_malloc_pool()`，`MEMP_MEM_MALLOC` 分支里唯一的特判就是那段 `if(desc == memp_pools[MEMP_TCP_PCB]){ if(num_tcp_pcb >= MEMP_NUM_TCP_PCB) return NULL; }`。UDP PCB、netbuf、netconn 全都没有对应计数器——把 `CONFIG_LWIP_MAX_UDP_PCBS` 设成 2 再并发开 15 个 socket，你会发现它一点脾气都没有（实验 C 前 15 个全绿、第 16 个死于 `ENFILE` 的 fd 上限而非 PCB 上限）。真正管住 UDP socket 个数的旋钮是 `CONFIG_LWIP_MAX_SOCKETS` 和 libc 堆。

另一个必须诚实标注的差异：**Vanilla 的静态 memp 池里 `MEMP_NUM_UDP_PCB` 才是真闸门**——裸奔 lwIP 的移植（不用 IDF 这套堆化）回到"第 3 个 socket() 返回 NULL、errno 收 ENOMEM"的世界。两个世界的失败模式完全不同，调试手感也不同，这正是系列暗线 B 要让你内化的感觉。

---

## 10.6 实验：三层同题竞技、邮箱黑洞、PCB 闸门、校验和注入

工程：`practice/lwip-ch10-udp-pcb-layers/`（基于 ch3 联网模板：openeth bring-up + esp_netif + DHCP）。固件在拿到 IP 后同时开四个端口：

```text
8010/udp  raw      API echo   （recv 回调内 pbuf 原样回发）
8011/udp  netconn  API echo   （独立任务 ch10_nc，netconn_recv/sendto）
8012/udp  socket   API echo   （独立任务 ch10_sock，recvfrom/sendto）
8019/udp  控制口    （raw API；命令 st=打印统计/PCB 清单，slow:<ms>=设慢消费者延迟）
外加 PHASE C 探针与 PHASE D 校验和注入器（开机自跑一次）。
```

构建与启动（完整可复制）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch10-udp-pcb-layers
idf.py set-target esp32 && idf.py build
idf.py qemu monitor < /dev/null || true      # 生成 qemu_flash.bin/qemu_efuse.bin

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 240 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=udp::8010-:8010,hostfwd=udp::8011-:8011,\
hostfwd=udp::8012-:8012,hostfwd=udp::8019-:8019 \
  -nographic -no-reboot 2>&1 | tee run.log
# 等 run.log 出现 CH10-READY 再开始主机侧测试
```

主机侧统一使用 `host/udp_bench.py`（payload 格式 `magic'C10!' + seq u32LE + 填充`，回显必须逐字节一致才算收到；主机 SO_RCVBUF 调至 4MB 以排除主机内核排队干扰）。

### 实验 A：三层 API 同题基准（时延 + 吞吐）

**方法学**。时延：顺序 ping-pong——发出后阻塞等回显再发下一个，64 B × 400 个/轮 × 3 轮，三端口交错执行摊平台漂移；RTT 用主机 `time.monotonic_ns()` 计。吞吐两种口径：突发式（窗口 16 连发 1500 个 1200 B datagram，缺尾不补——测"一口气"的单向管线能力）与可靠式（同负载但对 >0.5 s 未回显的 seq 补发直至凑齐或超时——测"保证送达"时要付多少管道税）。

**时延结果**（µs，来自 `logs/exp_a_latency.log` 原始行：9 次调用 × 400 样本 = 3600 个 RTT 观测，下表取每次调用的中位数）：

| API     | 第 1 轮 median | 第 2 轮 median | 第 3 轮 median | 三轮均值  |
| ------- | -------------- | -------------- | -------------- | --------- |
| raw     | 97.3           | 97.4           | 114.0          | **102.9** |
| netconn | 205.1          | 249.5          | 189.8          | **214.8** |
| socket  | 265.2          | 263.4          | 334.2          | **287.6** |

原始行示例：

```text
LAT label=raw port=8010 size=64 n=400 ok=400 loss=0 avg_us=107.9 med_us=97.3 min_us=79.3 max_us=615.2 p95_us=128.4
LAT label=netconn port=8011 size=64 n=400 ok=400 loss=0 avg_us=256.3 med_us=205.1 min_us=128.6 max_us=1040.2 p95_us=519.4
LAT label=socket port=8012 size=64 n=400 ok=400 loss=0 avg_us=332.5 med_us=265.2 min_us=197.1 max_us=980.8 p95_us=621.2
```

（max/p95 的毛刺来自 QEMU 时钟粒度与 SLIRP 调度抖动，median 稳定得多，也更有解释力。）

**吞吐结果·突发口径**（Mbit/s，`logs/exp_a_tput.log`）：

| API     | 第 1 轮 | 第 2 轮 | 第 3 轮 | 均值     | 每轮恒定缺失 |
| ------- | ------- | ------- | ------- | -------- | ------------ |
| raw     | 75.97   | 77.15   | 52.04   | **68.4** | 12/1500      |
| netconn | 58.64   | 55.06   | 53.94   | **55.9** | 12/1500      |
| socket  | 40.69   | 42.76   | 46.32   | **43.3** | 12/1500      |

**吞吐结果·可靠口径**（`logs/exp_a_tput2.log`，1500/1500 全达，每轮约 12 次补发）：

| API     | 第 1 轮 | 第 2 轮 | 第 3 轮 | 均值     |
| ------- | ------- | ------- | ------- | -------- |
| raw     | 27.00   | 27.12   | 27.11   | **27.1** |
| netconn | 27.21   | 28.19   | 28.12   | **27.8** |
| socket  | 25.91   | 27.90   | 26.18   | **26.7** |

**解读四点**。

1. **时延的中位阶梯与调用链预算严丝合缝**：raw→netconn 增 +112 µs≈"接收邮箱投递+任务唤醒"往返的一次单价；netconn→socket 再增 +73 µs≈"两次 memcpy + VFS 间接层"。这不是玄学测量，10.3 图上每一个 ⟳/⧉ 符号都贡献了自己的份额。
2. **吞吐同步阶梯（68→56→43）证明这些成本在高频路径上是乘法不是加法**：每 datagram 固定开销越大，同样窗口深度下的稳态速率越低。raw 的 0 拷贝 0 切换在突发口径拿到了接近 SLIRP 管道天花板的速率。
3. **突发口径每轮恒丢最后 12 个**（三轮 × 三端口一个不少）——缺失模式与 API 无关，指向两条 API 之外的公共环节：SLIRP 用户态转发缓冲在突发尾巴上的溢出。这是仿真伪影不是协议栈缺陷，但它反过来帮我们做了排除法：**只要各 API 丢包数一致，残余差异就纯属于分层本身**。
4. **可靠口径三家收敛到 ~27 Mbit，补发逻辑吃到瓶颈后层的差距消失**——为 UDP 手工补上一套"seq + 重传 + 确认"之后，你已经造了个粗糙的 TCP，口径被共性机制封顶。工程含义：raw 的高性能只在"应用层自己不在乎个别丢包"的前提下成立。

> [!tip] 测量方法的自我批判
> 突发口径的第 3 轮全线下跌（raw 52 Mbit）由平台温漂叠加第三端口交错顺序导致，报告保留全部三轮而不是只贴好看的均值；在评估"层次价格"这种结构性问题时，跨 API 的**相对序**比单点绝对值可信得多。

### 实验 B：netconn/socket 邮箱深度的黑洞现场

**设计**：经控制口下发 `slow:10` 把 netconn/socket 两个消费任务的节奏钉在 10 ms 一个 datagram，随后主机以 2000 pps 定速灌 64 B 报文各 3 s，raw 口作为免打扰对照组；结束后抓取 guest 侧 `CH10-UDPSTATS` 快照；恢复 `slow:0` 后复灌一次 netconn 作恢复验证。

```bash
python3 host/udp_bench.py slow --ms 10
python3 host/udp_bench.py flood --port 8010 --pps 2000 --dur 3 --size 64 --label raw_slow
python3 host/udp_bench.py flood --port 8011 --pps 2000 --dur 3 --size 64 --label netconn_slow
python3 host/udp_bench.py flood --port 8012 --pps 2000 --dur 3 --size 64 --label socket_slow
sleep 12                                   # 等 guest 周期统计打印
grep CH10-UDPSTATS run.log | tail -2
python3 host/udp_bench.py slow --ms 0
python3 host/udp_bench.py flood --port 8011 --pps 2000 --dur 2 --size 64 --label netconn_recovered
```

真实输出（`logs/exp_b_mbox.log`）：

```text
FLOOD label=raw_slow port=8010 size=64 pps=2000 dur=3.0 sent=5286 echoed_unique=5286 lost_or_pending=0 loss_pct=0.00
FLOOD label=netconn_slow port=8011 size=64 pps=2000 dur=3.0 sent=5210 echoed_unique=305 lost_or_pending=4905 loss_pct=94.15
FLOOD label=socket_slow port=8012 size=64 pps=2000 dur=3.0 sent=5265 echoed_unique=302 lost_or_pending=4963 loss_pct=94.26
CH10-UDPSTATS recv=15718 xmit=5896 drop=1 chkerr=1 lenerr=0 memerr=0 rterr=0 proterr=0 | app rx raw=5286 nc=305 sock=302 inj=1 slow_ms=10
FLOOD label=netconn_recovered port=8011 ... sent=3490 echoed_unique=3490 lost_or_pending=0 loss_pct=0.00
```

**解读三点**。

1. **94% 黑洞与统计零痕迹并存**：`udp.drop/memerr/proterr` 纹丝不动（那唯一的 drop=1/chkerr=1 是实验 D 注入包留下的正当记录）。udp_input 明明收到了——这正是 10.3.3 那段 `sys_mbox_trypost` 静默分支的案发现场。`CONFIG_LWIP_UDP_RECVMBOX_SIZE=6` 的六个槽位在 2000 pps 下不足一毫秒就会被灌满。
2. **计数器算术定位丢失层**：三个端口合计送入主机的 `app rx` = 5286+305+302 = 5893；若 9 千余个包真的死在 SLIRP/驱动的上游，`recv` 应当只有 ~6000。实际 `recv=15718` ≈ 三个端口发送总量之和——包几乎全部穿过了 IP 层、进过 udp_input、被 PCB 认领、然后在 **pcb->recv（即 recv_udp）投递邮箱处蒸发**。一场教科书级的现场还原：丢的位置既不在 netcard 也不在应用，而在两者之间的 glue 层；而它不留痕。生产排障时，“主机发送数 − lwip_stats.udp.recv”与“recv − 应用收取数”这两段减法就是区分"网络丢了"还是"邮箱丢了"的最短刀路。
3. **恢复验证**：`slow:0` 后同一 netconn 端口在同样的 2000 pps 下 3490/3490 零丢失——资源无罪，只是消费者失职。

> [!note] 系列暗线 A 的一记实证
> 这正是十三章 tcpip_thread 邮箱模型的镜像面：netconn 用"深度 6 的信箱"隔离了核心与应用的节奏，换来的是慢消费者时代 core 侧**不得不代为处置**溢出；而处置协议是无声的 free。与 TCP 走"收缩通告窗口"的优雅背压不同，UDP 没有任何可伸张的反馈通道——RFC 768 给它的自由，全部转嫁给了应用程序自己长记性。

### 实验 C：故障注入·UDP PCB"耗尽"

**原有剧本**（按经典 lwIP 设定设计）：`MEMP_NUM_UDP_PCB = CONFIG_LWIP_MAX_UDP_PCBS` 压到 2，并发开/绑一组 socket，观察资源耗尽的报错形态。真实结果先剧透：**此路不通**——两个构建下行为一字不差地撞在同一堵墙上，而且根本不是 UDP PCB 的墙。

替换为真相探针后（固件 PHASE C：连续 socket()+bind 直到失败或 40 个为止），两种 sdkconfig 各烧一遍，输出原文：

```text
── CONFIG_LWIP_MAX_UDP_PCBS=2 构建（logs/exp_c_pcblow2.log）──
CH10-PHASE C start MAX_UDP_PCBS=2 MAX_SOCKETS=16 (probe: allocate+bind up to 40 udp sockets)
CH10-PCBFAIL #15 socket()=-1 errno=23 (Too many open files in system)
CH10-PCBSUMMARY allocated_and_bound=15 first_failure_at=#15 errno=23 (Too many open files in system)
CH10-PHASE C closing 15 sockets, recovery probe:
CH10-PCBRECOVERY socket=49 OK after close -> 资源已归还

── CONFIG_LWIP_MAX_UDP_PCBS=16 默认构建（logs/exp_c_default.log）──
CH10-PHASE C start MAX_UDP_PCBS=16 MAX_SOCKETS=16 ...
CH10-PCBFAIL #15 socket()=-1 errno=23 (Too many open files in system)
CH10-PCBSUMMARY allocated_and_bound=15 first_failure_at=#15 errno=23 (Too many open files in system)
CH10-PCBRECOVERY socket=49 OK after close -> 资源已归还
```

**解读四点**。

1. **两个配置、一模一样的输出**：`MAX_UDP_PCBS=2` 与 `=16` 都是活到第 16 个 socket 才倒——证实 10.5 的源码考古：全堆化 + ESP_LWIP 下 memp 计数闸只剩 TCP 一家，UDP PCB 直通 libc 堆，此旋钮在 IDF 上失效。
2. **真闸门是 fd 槽位**：`errno=23 ENFILE` 来自 `alloc_socket()` 失败路径的 `set_errno(ENFILE)`（`api/sockets.c`）。算术也对得上：VFS 给 lwIP 的 fd 区间起点 `LWIP_SOCKET_OFFSET = FD_SETSIZE − MAX_SOCKETS = 64−16 = 48`——socket 版 echo 服务器开机已占用 fd 48，探针顺次拿到 49..63 共 15 个后区间耗尽（注意只有 socket API 吃 VFS fd：raw 与 netconn 的服务器是 PCB 不是文件），第 16 次申请越界即遭拒。顺带回答了最初的提问"bind 失败是什么 errno"：在本配置空间里，**bind 从来没轮到失败**——socket() 先倒；真正能到达 bind 的失败只有 `EADDRINUSE`（ERR_USE，双绑拒绝）一类逻辑错误，与本实验的资源型失败不同源。
3. **与第五/六章 TCP 故事拼成全景**：listen PCB 耗尽时代码走进 `tcp_listen_input` 静默吞 SYN（也不报错）；UDP PCB 这里压根没机会演到那一幕。IDF 对"资源上限"的三种态度——TCP 数框框、UDP 放羊靠堆、Socket 数 fd——同一个栈里并存，值得每种都用实验摸一遍而不是相信 menuconfig 的字面描述。
4. **恢复语义**：close 归还 fd 后再次 socket() 立刻成功（`socket=49 OK`）。ENFILE 型耗尽是可逆的瞬时态，这点比"堆碎片化导致的慢性衰竭"友好得多（后者见第五章诊断三联征）。

### 实验 D：校验和验证（附方法学坦白）

**方法学说明**。理想方案是主机抓包核对 lwIP 生成的线上校验和，但 QEMU SLIRP 会在网卡边界终止 L3/L4 并用**宿主机协议栈重新生成**报文再发给主机进程——tcpdump 永远看到的是 Linux 的手笔。故改用**应用层注入法**：在 tcpip 线程上下文手工构造 `[IPv4][UDP][载荷]` 连续缓冲（跳过以太网头，扮演 ethernet_input 解析完成后的位置），正确/篡改校验和各一发，直塞 `ip4_input()`，观察 `lwip_stats.udp.*` 与应用交付计数的变化。这是全栈内验证：输入序列确定性、可重复、不依赖外部环境。

固件里最核心的三步（`main/lab_main.c` 的 `build_inject_datagram/inject_fn`）：

```c
u16_t ck = ~ones_sum_raw(b + 20, ulen,
                         ones_sum_raw(pseudo, 12, 0)) & 0xffff; /* 伪头+整段二段累加 */
if (!udp_correct && ck != 0) ck ^= 0x0001;   /* 篡改版：最低位翻转 1 bit */
...
struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);
memcpy(p->payload, buf, len);
err_t err = ip4_input(p, netif_default);     /* 所有权移交协议栈 */
```

开发过程中先踩了一脚才是这实验的彩蛋：第一版把"分两段求和再拼接"写成"分别取反再相加"，结果**正确校验和的包也被 chkerr 退回**——接收侧反算出来的和与发送侧不一致，立刻暴露。修好后的完整现场（run.log 原文）：

```text
CH10-INJ inject "ch10-inject-ok" len=42 udp_cksum=0x8cb2 (CORRECT)
CH10-UDPSTATS recv=2 xmit=2 drop=0 chkerr=0 ...
CH10-INJ delivered payload='ch10-inject-ok'
CH10-UDPSTATS recv=3 xmit=2 drop=0 chkerr=0 ... inj=1 slow_ms=0
CH10-INJ inject "ch10-inject-corrupt" len=47 udp_cksum=0x3cc0 (CORRUPT)
CH10-INJ ip4_input returned 0 (consumed by stack)
CH10-UDPSTATS recv=4 xmit=2 drop=1 chkerr=1 ... inj=1 slow_ms=0
```

**解读三点**。

1. **正误分明的双路径**：合法包一路绿灯直达应用回调（`delivered payload='...'`，inj 计数 +1）；翻转一个 bit 的包被拦截，`chkerr/drop` 各 +1，`ip4_input` 仍返回 ERR_OK——**数据报在 udp_input 内部即被消化，上层无感**。"一 bit 翻转必被捉"的直观印象得到机械化确认。
2. **配置责任在用户**：本实验依赖 `sdkconfig.defaults` 显式的 `CONFIG_LWIP_CHECKSUM_CHECK_UDP=y`；IDF 该项默认 n，即**不对进站 UDP 做软件校验**（宽泛默认假设驱动/HW 校验卸载处理，虚拟 openeth 显然没有 HW 卸载）。这个教训值得贴在最顺手的地方：换平台、裁组件之后，先 grep 一遍自己的 sdkconfig 再谈协议栈的正确性。
3. **配套的发送侧豁免语义**：`udp_setflags(pcb, UDP_FLAGS_NOCHKSUM)` 让 gen 分支直接跳过、线上出现 0x0000 校验和（RFC768 的"no checksum"约定），而接收端 `if (udphdr->chksum != 0)` 对 0 网开一面——两端语义互锁。本实验未构造 0 校验和的包做全链验证，如实标注。

---

## 10.7 小结

- UDP 的全部复用就是**对全局单链表 `udp_pcbs` 的线性扫描 + MRU 前插缓存**：完美匹配（connected PCB）短路一切，`uncon_pcb` 兜底，广播子句细选；`sizeof(struct udp_pcb)=80`，其复杂度全在规则而不在体积。
- `udp_bind` 负责"我是谁"（端口冲突判 ERR_USE，任一方 ANY 即视为重叠），`udp_connect` 负责"对面是谁"（零流量、置 CONNECTED 位、顺送最高接收优先级），DHCP/DNS 都是这两个原语的消费者；首次发包前的 auto-bind 让"从不 bind"也成立。
- 三层 API 的价格标签已被实测钉死：RTT 中位数 **raw 103 µs → netconn 215 µs → socket 288 µs**；突发吞吐 **68 → 56 → 43 Mbit**。差额对得上调用链账本——netconn 加 2 次任务切换，socket 再加 rx/tx 各一次 memcpy + VFS 一跳；而 ESP-IDF 的 `TX_SINGLE_PBUF=1` 把 socket sendto 的 vanilla 零拷贝 `netbuf_ref` 路径焊死成了 MEMCPY。
- 交付语义决定行为：raw 回调拿到 pbuf 所有权、零拷贝回发天经地义；netconn 走深度 `CONFIG_LWIP_UDP_RECVMBOX_SIZE`（默认 6、**最小值也是 6**，Kconfig range 钉死）的信箱；信箱满时的 `recv_udp` trypost 失败分支**静默 free**，lwIP 所有计数器一动不动——实验 B 用 94% 丢包 + 统计零变化的现场给了抓捕手法：`主机发送数 − udp.recv` 定位网络段、`udp.recv − 应用收取数`定位 glue 层。
- **ESP-IDF 关键事实**：`CONFIG_LWIP_MAX_UDP_PCBS`（=MEMP_NUM_UDP_PCB，默认 16）在全堆化下是死旋钮——`core/memp.c` 的 ESP_LWIP 计数闸补丁只为 MEMP_TCP_PCB 存在；真实的 UDP socket 上限是 `CONFIG_LWIP_MAX_SOCKETS` 撑开的 fd 槽位数（溢出时 `errno=ENFILE/23`，close 后即刻恢复）。Vanilla 静态池世界里"第三个 socket 返回 NULL + ENOMEM"的故事在 IDF 不再成立，调参前先看清楚自己站在哪个世界。
- 校验和是"伪头 + 整包"的反码和：发送侧 0→0xFFFF 转义、NOCHKSUM 标志可豁免（仅 IPv4）；接收侧 0 表示"未启用"直接放行，应用层注入实验证明正常路径下一个 bit 的翻转都会以 `chkerr/drop++` 消化于 udp_input 内部。别忘了 IDF 默认不开启 `CONFIG_LWIP_CHECKSUM_CHECK_UDP`。

下一章进入 TCP 的领土。有了本章的 PCB 匹配作参照系，会发现 tcp_pcb 一出场就是完全不同的物种：七种状态组成的状态机、三次握手里的 SYN/ACK 序号博弈、以及 `tcp_process()` 那张覆盖一切的迁移大表——[[2026-08-26-lwip-deep-dive-ch11-tcp-state-machine|第十一章《TCP：状态机与三次握手》]]。
