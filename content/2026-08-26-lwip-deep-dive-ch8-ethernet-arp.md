---
title: "lwIP 深度解析（八）：以太网与 ARP：从帧到 IP 的第一跳"
date: 2026-08-26
description: "以 openeth+SLIRP 为解剖台，走读 ethernet_input 帧类型分派与 ch4 剥头流水线的落地；拆解 etharp.c 五态缓存状态机、驱逐优先级、排队队列与 IDF 的 ESP_LWIP_ARP 补丁；实验实测 ARP 冷启动首包 22.6ms vs 热缓存 2.6ms、ARP_TABLE_SIZE=2 时表满驱逐把网关打回冷态（11.2ms）、队列上限恰好 3 个包的发送失败路径。"
tags: [lwip, network, esp32, esp-idf, arp, ethernet, qemu]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 8. **第八章：以太网与 ARP：从帧到 IP 的第一跳**

# lwIP 深度解析（八）：以太网与 ARP：从帧到 IP 的第一跳

这一章回答三个问题：**一个以太网帧从驱动到 IP 层要经过什么**（`ethernet_input()` 的帧类型分派与剥头）、**IP 地址怎么变成 MAC 地址**（ARP 缓存的五态状态机与老化账本）、**ARP 未命中时包去了哪里**（排队还是丢弃——IDF 在这里埋了一个上游没有的补丁）。读完它，你应该能对着日志指认每一个 ARP 表项的生老病死。源码参照：ESP-IDF v6.0.2 捆绑的 lwIP 2.2.0-dev（`components/lwip/lwip/src/`），对照 ESP-IDF 移植层（`components/lwip/port/`）与上游 opt.h 默认值。

---

## 8.1 第一跳的全景：帧从哪儿来，到哪儿去

### 1. 收包流水线：五次转手才进协议栈

以本章实验环境（QEMU `-nic user,model=open_eth` + SLIRP）为解剖台，一帧以太网数据从网卡寄存器走到 `ip4_input()`，全程五次转手：

```text
openeth 硬件 RX 描述环 (QEMU SLIRP 注入)
   │  emac_opencores_rx_task（esp_eth/src/openeth/esp_eth_mac_openeth.c）
   │    malloc(1516) → emac_opencores_receive() → stack_input()
   ▼
esp_eth mediator → glue 层 ethernetif_input()
   │  （esp_netif/lwip/netif/ethernetif.c：esp_pbuf_allocate 包成 pbuf）
   │  netif->input(p, netif)   ← netif_add(..., tcpip_input) 注册的就是它
   ▼
tcpip_input()：把 pbuf 打包成消息投进 tcpip 邮箱      ←─ 系列暗线 A
   │  （从此这帧只在 tcpip_thread 单线程世界里流动）
   ▼
ethernet_input()（src/netif/ethernet.c）：读 eth_hdr->type 分派
   ├─ ETHTYPE_IP  (0x0800) → pbuf_remove_header(p, 14) → ip4_input()
   ├─ ETHTYPE_ARP (0x0806) → pbuf_remove_header(p, 14) → etharp_input()
   └─ ETHTYPE_IPV6(0x86DD) → pbuf_remove_header(p, 14) → ip6_input()
```

两点先记下：

- `netif->input` 不是 `ethernet_input` 而是 `tcpip_input`。esp_netif 在 `netif_add()`（esp_netif_lwip.c）里统一传 `tcpip_input`——驱动侧只是生产者，真正的收包处理全部汇入 `tcpip_thread`。这是整个系列反复出现的单线程邮箱模型在链路层的入口。
- 广播/多播标记（`PBUF_FLAG_LLBCAST`/`PBUF_FLAG_LLMCAST`）在分派之前就写进 `p->flags`了，上层不必再看 MAC。

### 2. 剥头：ch4 的 layer 流水线在这里落地

[[2026-08-26-lwip-deep-dive-ch4-pbuf-anatomy|第四章]]量过 `pbuf layer` 各档的头偏移：LINK=14、IP=54、TRANSPORT=74（IPv6 开启时编译值）。那串数字的本体就是本章的两行代码——`ethernet_input()` 对每个可识别类型做同一次"层权交接"：

```c
/* src/netif/ethernet.c: ethernet_input() */
case PP_HTONS(ETHTYPE_IP):
  ...
  /* skip Ethernet header (min. size checked above) */
  if (pbuf_remove_header(p, next_hdr_offset)) {   /* next_hdr_offset = SIZEOF_ETH_HDR = 14 */
    ... /* 太短，丢 */
  } else {
    ip4_input(p, netif);                          /* payload 已指向 IP 头 */
  }
```

`pbuf_remove_header(p, SIZEOF_ETH_HDR)` 把 `p->payload` 前移 14 字节，等于 LINK 层把自己那一段头从视野里让渡出去。此后 `ip4_input()` 再剥 20 字节交给传输层——对应 ch4 实测表里 LINK(14)→IP(54)→TRANSPORT(74) 的阶梯。收到方向是"剥"，发出方向就是 `ethernet_output()`（同文件）用 `pbuf_add_header()` 把头加回来再调 `netif->linkoutput`。一收一发，对称成立。

> [!note] 为什么是 14 而不是别数
> `SIZEOF_ETH_HDR = (14 + ETH_PAD_SIZE)`（src/include/lwip/prot/ethernet.h），IDF 与多数移植都取 `ETH_PAD_SIZE=0`。前 6 字节目的 MAC + 6 字节源 MAC + 2 字节类型。ARP 帧走同一个 14 字节前缀，所以 IP 和 ARP 共享同一套剥头逻辑。

| ethhdr->type（网络序） | 宏             | 处理函数                                    |
| ---------------------- | -------------- | ------------------------------------------- |
| 0x0800                 | `ETHTYPE_IP`   | `ip4_input()`                               |
| 0x0806                 | `ETHTYPE_ARP`  | `etharp_input()`                            |
| 0x86DD                 | `ETHTYPE_IPV6` | `ip6_input()`                               |
| 其他                   | —              | `LWIP_HOOK_UNKNOWN_ETH_PROTOCOL` 或计数丢弃 |

## 8.2 ARP 缓存本体：一张 static 全局表的五态人生

### 1. 数据结构：裸数组 + 单线程即安全

ARP 缓存没有任何哈希或链表花活，就是一块静态数组（src/core/ipv4/etharp.c）：

```c
struct etharp_entry {
#if ARP_QUEUEING
  struct etharp_q_entry *q;   /* 待发包队列（IDF 开启，见 8.5） */
#else
  struct pbuf *q;             /* 上游默认：单个待发包 */
#endif
  ip4_addr_t        ipaddr;
  struct netif     *netif;
  struct eth_addr   ethaddr;
  u16_t             ctime;    /* 年龄计数器，单位秒 */
  u8_t              state;
};
static struct etharp_entry arp_table[ARP_TABLE_SIZE];
```

`ARP_TABLE_SIZE` 上游默认 10（opt.h），ESP-IDF 没有给它配 Kconfig、也没有覆盖——**IDF 固件的 ARP 表就是 10 格**。这张表敢用无锁 `static` 全局，靠的是架构红利：所有读写都发生在 `tcpip_thread` 内部（收包如 8.1 所述汇入邮箱；应用侧 API 若想摸它必须像我们 8.8 实验那样用 `tcpip_callback()` 把回调投递进线程）。系列暗线 A 在这里的价值是负空间式的——正因为单线程，`arp_table` 一个锁都不需要。

> [!warning] 公共观测 API 天生只能看见一半
> 对外的查询接口只有 `etharp_find_addr()` / `etharp_get_entry()`，两者都要求 `state >= ETHARP_STATE_STABLE` 才返回。**PENDING 状态对公共 API 完全不可见**。8.8 实验 B 会展示这个盲区：刚发完解析请求的瞬间去 dump，什么都没有。

### 2. 五态状态机

枚举定义同样在 etharp.c（成员名照抄源码）：

```text
                 新目标发包/显式 query（建表项+发请求）
   ┌────────┐  ───────────────────────────────────────►  ┌─────────┐
   │ EMPTY  │                                            │ PENDING │◄── 每 1s 重发请求，
   └────────┘                                            └────┬────┘    直到 ctime≥5 释放
      ▲                     ARP reply 到达                    │ update_arp_entry()
      │                    （含被动嗅探更新）                  ▼
      │  etharp_timer 老            ┌────────────────────────────┐
      │  化（ctime≥300）释放        │ STABLE                     │
      │                             │  ctime≥270: 发单播刷新请求  │
      │  ┌──────────────────────┐   │  ctime≥285: 发广播刷新请求  │
      └──┤ STABLE_REREQUESTING_2│◄──┤                            │
         └──────────┬───────────┘   └────────────────────────────┘
                    │ 下一个 tick                   │ 发出刷新请求后
                    ▼                               ▼
         回到 STABLE（等下一个包触发重发）  STABLE_REREQUESTING_1（每 2s 至多一步）
```

状态语义一句话版：

| 状态                                 | 含义                 | 谁能进 / 谁会出                                                         |
| ------------------------------------ | -------------------- | ----------------------------------------------------------------------- |
| `ETHARP_STATE_EMPTY`(0)              | 空槽                 | 初始化 / `etharp_free_entry()` 回收                                     |
| `ETHARP_STATE_PENDING`               | 请求已发、尚未应答   | `etharp_query()` 建；应答转 STABLE 或 `ctime>=5` 回收                   |
| `ETHARP_STATE_STABLE`                | 有效映射             | 应答到达或嗅探更新；老化/驱逐出                                         |
| `ETHARP_STATE_STABLE_REREQUESTING_1` | 刷新请求已发，冷却中 | tmr 推进到 \_2 或应答后回 STABLE                                        |
| `ETHARP_STATE_STABLE_REREQUESTING_2` | 下个发包时重发请求   | tmr 一个 tick 后回 STABLE                                               |
| `ETHARP_STATE_STATIC`                | 静态条目（永不过期） | 仅 `ETHARP_SUPPORT_STATIC_ENTRIES=1` 编译；IDF 默认关（开启条件见 8.7） |

两个设计细节值得咀嚼：

- **REREQUESTING 两段式**不是摆设：`_1` 存在的唯一目的是让"刷新请求"之间至少隔一个 tick（注释原话"Don't send more than one request every 2 seconds"），防止高频流量把刷新请求打成风暴。
- **PENDING 寿命只有 5 秒**（`ARP_MAXPENDING`），且期间 `etharp_tmr()` 每 1 秒重发一次请求。5 秒无应答就整个表项连人带队列一起销毁——挂在上面的待发包随之丢弃，8.8 实验 C 里有真实残骸可看。

### 3. 定时器账本

| 宏                                 | 默认值        | 出处/含义                                   |
| ---------------------------------- | ------------- | ------------------------------------------- |
| `ARP_TMR_INTERVAL`                 | 1000 ms       | `etharp_tmr()` 的心跳，由内核定时器体系驱动 |
| `ARP_MAXPENDING`                   | 5 s           | PENTRY 无应答寿命                           |
| `ARP_MAXAGE`                       | 300 s         | STABLE 条目最长年龄（opt.h）                |
| `ARP_AGE_REREQUEST_USED_UNICAST`   | 270 (=300−30) | ctime≥270 后发包改用**单播**刷新请求        |
| `ARP_AGE_REREQUEST_USED_BROADCAST` | 285 (=300−15) | ctime≥285 后升级为**广播**刷新请求          |

"预刷新"的工程意义：一条持续使用的连接不应该在 ARP 条目到期瞬间突然断流。lwIP 选择在使用中提前 30 秒开始温和地续命（先单播——不打扰全网，再广播——容错对方 MAC 变化），300 秒硬超时只惩罚真正闲置的目标。**老连接永不因 ARP 断**，这是 8.4 节 `etharp_output_to_arp_index()` 里最容易被忽略的三行。

> [!warning] 上游注释也会说谎
> etharp.c 里 `ARP_MAXPENDING` 的文档注释写着"for ARP_TMR_INTERVAL = 1000, this is 10 seconds"，但宏值是 **5**，按 1 s 心跳折算就是 5 秒——注释是旧值残留。本章实验 C 的日志（expired 恰好落在 TICK+5s 与 +6s 之间）站在宏值这一边：遇到记忆、注释、代码三方打架，以代码为准，以实测结案。

## 8.3 收包路径走读：etharp_input 的 RFC 826 三段式

剥掉 14 字节以太网头之后，28 字节 ARP 报文（`struct etharp_hdr`，SIZEOF_ETHARP_HDR=28）交给 `etharp_input()`：

```text
┌────┬────┬─────────────┬──────────────┬──────────────────────────┐
│htype│ptype│hlen/plen/op│ sender MAC+IP │ target MAC(未答全0)+IP  │
│  1  │0x800│  6/4/1or2  │               │                          │
└────┴────┴─────────────┴──────────────┴──────────────────────────┘
```

处理逻辑严格跟着 RFC 826 走，三步：

1. **合法性闸门**：hwtype=1、proto=0x0800、hwlen=6、protolen=4 四不对则计 proterr/drop 直接丢。
2. **学习（无论报文是不是问我的都执行）**：`etharp_update_arp_entry(netif, &sipaddr, &hdr->shwaddr, for_us ? TRY_HARD : FIND_ONLY)`。问我的（含请求与应答）强制建稳定表项；不是问我的只做"已有表项才顺手更新"的嗅探。这就是为什么长期运行的设备即使从不主动说话，也会被网络里他人的 ARP 流量喂熟缓存。
3. **按 opcode 行动**：
   - `ARP_REQUEST` 且 for_us → 用 `etharp_raw()` 单播回 ARP reply（注意 dst MAC 直接抄请求方的 `shwaddr`——省一次自己的解析）；
   - `ARP_REPLY` → 无需动作，第 2 步已经入账；
   - 其他 opcode → 计数丢弃。

还有一个对称性细节：应答回程走的不是 `etharp_request_dst`，而是 `etharp_raw()` 组帧后 `ethernet_output(netif, p, hwaddr, &hdr->shwaddr, ETHTYPE_ARP)`——以太网头的目的 MAC = ARP 头里的 sender MAC。

> [!tip] SLIRP 的一个有趣指纹
> 本章 QEMU 日志里抓到的 ARP 应答，帧的 src MAC 是 `52:55:0a:00:02:02` / `52:55:0a:00:02:03`——低四字节正好是被解析的 IP（10.0.2.2→`0a 00 02 02`）。也就是说 SLIRP 给虚拟网段的每个 IP 都编织了"编码其 IP 的专属假 MAC"。而 guest 侧 openeth 的 MAC 是固定的 `52:54:00:12:34:56`（ch3 已验证，属预期）。真机抓不到这种规律性 MAC，看到它基本可以断定是用户态虚拟网络。

## 8.4 发包路径：etharp_output 的三种结局

IP 层发包走到 `netif->output`——ethernet 型 netif 在初始化时把它挂成 `etharp_output`（esp_netif 的 ethernetif.c：`netif->output = etharp_output;`）。三种结局按 dest 类型分流：

```c
/* src/core/ipv4/etharp.c: etharp_output() 概骨 */
if (ip4_addr_isbroadcast(ipaddr, netif)) {
  dest = &ethbroadcast;                       /* 结局①：广播直发 */
} else if (ip4_addr_ismulticast(ipaddr)) {
  /* 01:00:5e + IP 低 23 位拼 MAC，结局①'：多播直发 */
} else {                                      /* 单播：查表 */
  if (目标不在本网段 && 有默认网关)
      dst_addr = netif_ip4_gw(netif);         /* 替身：解析的是网关 */
  …查 STABLE…
  if (命中) return etharp_output_to_arp_index(netif, q, i);
  return etharp_query(netif, dst_addr, q);    /* 结局②③：query */
}
```

### 1. 命中：直发 + 预刷新

`etharp_output_to_arp_index()` 就干两件事：上文说的"临近过期先续命"（270/285 双阈值单播/广播），以及 `ethernet_output()` 组帧直发。另外 etharp.c 还留了一条**上次命中缓存**快路：`LWIP_NETIF_HWADDRHINT=0`（IDF 即此配置）时，每次命中的表项号会被记进全局 `etharp_cached_entry`，下一次发包先猜"还是它"，猜中则跳过线性扫描并给 `etharp.cachehit` 计数。连续 TCP 流量的绝大多数包都走这条路。

### 2. 未命中：query 的隐藏代价

`etharp_query()` 是本章戏剧密度最高的函数。步骤：

1. `etharp_find_entry(ipaddr, ETHARP_FLAG_TRY_HARD, netif)` 找/建表项；
2. 新建的 EMPTY 翻成 PENDING，并发 ARP request；
3. 把待发的 IP 包**挂在表项上**（不发送！）：链式 pbuf 需要拷贝（`PBUF_NEEDS_COPY`）否则 ref 计数即可；
4. 返回 `ERR_OK` —— 注意，**这一刻调用方以为包发出去了，其实它躺在队列里等别人回答一个 28 字节的问题**。

TCP 三次握手的 SYN 就是这么躺进去的。这就是"首包延迟"的全部来源：SYN 之后的所有进度都被 ARP 往返阻塞，实测差距见 8.8 实验 A。

### 3. 表满了怎么办：find_entry 的驱逐优先级

`etharp_find_entry(TRY_HARD)` 找不到空槽时按破坏性从小到大挑牺牲者（顺序即源码注释）：

1. EMPTY 槽（不算驱逐）；
2. 最老的 STABLE；
3. 最老的 PENDING（无排队包）；
4. 最老的 PENDING（有排队包，驱逐时 `etharp_free_entry()` 连队列一起释放）。

平手细节：候选比较用 `>=`，同年龄时**后扫描到的赢**。这份排序的第二条最具冲击力——**STABLE 也会被逐出**，哪怕它是你的默认网关。表容量一旦吃紧，正常通信随时被打回冷启动，8.8 实验 C 用 `ARP_TABLE_SIZE=2` 把这个场景做成了演示。

## 8.5 排队与丢弃：ARP_QUEUEING 与 ESP-LWIP 补丁

### 1. 上游默认 vs IDF 配置

| 配置                 | 上游 opt.h 默认                     | IDF 实际                                | 说明                                                   |
| -------------------- | ----------------------------------- | --------------------------------------- | ------------------------------------------------------ |
| `ARP_QUEUEING`       | **0**（单槽：只保留最新一个待发包） | **1**（port/include/lwipopts.h 硬编码） | 链式排队，主目的注释明说：降低 TCP 建连延迟            |
| `MEMP_NUM_ARP_QUEUE` | 30                                  | 未覆盖 → 30                             | 队列节点池总深度（IDF 全堆化，计数闸门仍在，见第五章） |
| `ARP_QUEUE_LEN`      | 3                                   | 未覆盖 → 3                              | **每表项**排队上限                                     |

IDF 关掉的是"未命中时丢了前面的包"这种朴素行为，换来突发小包（典型如 HTTP 请求头+体分片、ping 连发）在解析期间无损等待。

### 2. ESP_LWIP_ARP 补丁：队满丢新不丢旧

排队上限到达后的行为，IDF 改了上游：etharp.c 的 `etharp_query()` 里有一段 `#if ESP_LWIP_ARP` 分支（port lwipopts.h 定义 `ESP_LWIP_ARP=1`）——

- 上游行为：丢掉**队首旧包**，新包入队（时间换公平，越新的包越可能代表最新意图？）；
- IDF 行为：新包直接不入队并返回 `ERR_MEM`，保住已排队的全部旧包。

对 socket 应用可见的效果：`sendto()` 同步返回 -1，errno 文本 "Not enough space"。这里还藏着一个统计陷阱：该分支**不给 `etharp.memerr` 计数**直接 return，所以 8.8 实验 B 的 stats 输出里 memerr=0 但发送确实失败了两次——排查时别迷信单一计数器。

### 3. 队列的两条出口

`arp_table[i].q` 只有两种命运：

- **喜**:应答到达，`etharp_update_arp_entry()` 转 STABLE 后当场循环出队、逐个 `ethernet_output()` 补发（我们的 post-evict 日志能看到 queued 的 SYN 在 stable 一落地的下一行就飞出去了）；
- **悲**：PENDING 到 5 秒寿限，`etharp_free_entry()` 里 `free_etharp_q()` 把整条队列 pbuf 释放——**排队只是缓冲，不是可靠投递**。

## 8.6 免费 ARP（GARP）：vanilla 的两次机会 vs IDF 的定时广播

`etharp_gratuitous()` 是个宏（src/include/lwip/etharp.h）：`etharp_request((netif), netif_ip4_addr(netif))`——拿自己的 IP 问"谁是 XX.XX.XX.XX"，sender/target 字段都是自己。按标准语义，听到的人会把这对映射学进缓存，用于地址变更后主动纠正他人（文件头注释注明遵循 RFC 3220 §4.6）。

上游 vanilla 触发点很克制：仅在 `netif_set_up()` / `netif_set_link_up()`（src/core/netif.c 的 `netif_issue_reports()`，`LWIP_ACD` 未开时）各广播一次。ESP-IDF 则把它做成周期服务：

- Kconfig：`CONFIG_LWIP_ESP_GRATUITOUS_ARP`（默认 **y**）+ `CONFIG_LWIP_GARP_TMR_INTERVAL`（默认 60 s）；help 文本直言动机——STA 换 AP 场景下旧 AP 不主动刷新 ARP 表会导致下行丢失，让设备自己定期广播兜底。
- 实现：esp_netif 组件内（esp_netif_lwip.c）`netif_set_garp_flag()` 注册 `sys_timeout(60s)` 循环，每轮回调合法 IPv4 就 `etharp_gratuitous()` 再续 60 s。
- 实验足迹：应用完全静默期，guest 侧唯一周期性外出的帧就是这段定时器的孤立 `etharp_request:`（8.8 实验 D 段末贴出）。

## 8.7 Vanilla lwIP 与 ESP-IDF lwIP 对照

| 维度             | Vanilla lwIP 2.2.0-dev                            | ESP-IDF v6.0.2 移植                                                                                             |
| ---------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `ARP_TABLE_SIZE` | opt.h 默认 10                                     | 同样 10（无 Kconfig、未覆盖；要改须编译期注入 `-D`，本文用此法做故障注入）                                      |
| `ARP_QUEUEING`   | 默认 0：每表项单包，后来者顶掉前者                | 硬编码 1：链式队列（`MEMP_ARP_QUEUE`=30 深度池）                                                                |
| 队满行为         | 丢队首旧包腾位                                    | `ESP_LWIP_ARP` 补丁：丢新包返 ERR_MEM，且不计 memerr                                                            |
| GARP             | 地址变更/link up 时一次（netif_issue_reports）    | `CONFIG_LWIP_ESP_GRATUITOUS_ARP` 默认开，60 s 周期广播（esp_netif sys_timeout 循环）                            |
| 静态 ARP         | 编译开关自由定                                    | `ETHARP_SUPPORT_STATIC_ENTRIES` 仅在 `CONFIG_LWIP_DHCPS_STATIC_ENTRIES` 时开                                    |
| 调试开关         | 手编 lwipopts.h                                   | menuconfig 化：`CONFIG_LWIP_DEBUG` + `CONFIG_LWIP_ETHARP_DEBUG` 等（Kconfig 名以 components/lwip/Kconfig 为准） |
| 收包入口一致性   | 移植自选（常见 ethernet_input 直挂 netif->input） | 统一 tcpip_input 进邮箱，ethernet_input 只跑在 tcpip_thread                                                     |

## 8.8 实验：给第一跳装仪表

### 8.8.0 工程与构建

工程位于 `practice/lwip-ch08-ethernet-arp/`（基于 ch3 模板裁剪：去掉 ping/DNS/echo，新增 connect 计时、ARP 表观察、故障注入序列）。两个构建变体共用一份代码：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch08-ethernet-arp
idf.py set-target esp32           # 仅首次
idf.py build                      # normal 变体：ARP_TABLE_SIZE=10 + LWIP_STATS
# 故障注入 + 日志变体（单独 build 目录）：
idf.py -B build-dbg -D SDKCONFIG=sdkconfig.dbg \
      -D SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.debug" \
      -D CH08_ARP_TABLE_SIZE=2 build
# 生成 QEMU 镜像（monitor 因无 TTY 报错属预期，镜像已生成）：
idf.py qemu monitor < /dev/null || true
```

宿主机侧配套（guest 将经 SLIRP 连到宿主机 loopback 别名 10.0.2.2:8108，方向是 guest→host，**本章不需要 hostfwd**）：

```bash
python3 practice/lwip-ch08-ethernet-arp/tools/host_listener.py &
# listening on 127.0.0.1:8108
```

故障注入的原理值得一提：`ARP_TABLE_SIZE` 没有 Kconfig，root CMakeLists.txt 里 `add_compile_definitions(ARP_TABLE_SIZE=${CH08_ARP_TABLE_SIZE})` 以全局 `-D` 注入。lwIP 所有选项宏都是 `#ifndef` 保护，预定义值覆盖 opt.h 默认——已在 build/compile_commands.json 中核实 `-DARP_TABLE_SIZE=2` 同时出现在 etharp.c 与 lab_main.c 的编译命令里。运行：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 45 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run-normal.log
```

> [!note] 测量口径
> 所有延迟为 guest 内 `esp_timer_get_time()` 微秒差（QEMU 虚拟时钟口径），单轮 12 次取逐次值呈现；连接采用非阻塞 connect + select 收割，超时上限 1.5 s 保证宿主机监听缺席时不拖垮实验。绝对数值随宿主机负载浮动很大，**cold/warm 的相对差距才是有效信号**；方法学与 ch6 的双计时口径一致。

### 8.8.1 实验 A：首包延迟（ARP 缓存效应）

实验目的：证明「第一次连新目标的耗时包含完整 ARP 解析往返，第二次起全部走缓存」。实机输出（run-normal.log 逐字摘录）：

```text
I (1713) ch8lab: [CFG] build: ARP_TABLE_SIZE=10, ARP_QUEUEING=1, LWIP_STATS=1
[BENCH] === cold-warm: 12x connect 10.0.2.2:8108 ===
[BENCH] cold-warm  conn#00 took 22614 us : ESTABLISHED
[BENCH] cold-warm  conn#01 took  4850 us : ESTABLISHED
[BENCH] cold-warm  conn#02 took  4227 us : ESTABLISHED
[BENCH] cold-warm  conn#03 took  3553 us : ESTABLISHED
[BENCH] cold-warm  conn#04 took  3587 us : ESTABLISHED
[BENCH] cold-warm  conn#05 took  3630 us : ESTABLISHED
[BENCH] cold-warm  conn#06 took  2482 us : ESTABLISHED
[BENCH] cold-warm  conn#07 took  4098 us : ESTABLISHED
[BENCH] cold-warm  conn#08 took  2541 us : ESTABLISHED
[BENCH] cold-warm  conn#09 took  2620 us : ESTABLISHED
[BENCH] cold-warm  conn#10 took  2678 us : ESTABLISHED
[BENCH] cold-warm  conn#11 took  2695 us : ESTABLISHED
```

解读：

1. 第 #00 次 22.6 ms ≈ 稳态（~2.6–3.6 ms）的 **8 倍**。溢出的 ~20 ms 由两部分构成：ARP 请求→应答的一个 RTT，和 SYN 在此期间的排队时长（8.5 的队列正是为此存在——注意 SYN 并没有被丢弃，而是延迟送达，所以连接依然成功）。
2. boot 阶段的地面真相可以保证这次"冷"是真冷：DHCP 完成后立刻 dump 显示 **(no stable entry)**——DHCP 的交互以广播为主，不会替我们把网关喂进缓存。
3. debug 小表变体的独立一轮复现了同样的形状：conn#00=13326 µs、其余 ~3–5 ms。数字不同（该变体还开着 ETHARP_DEBUG 日志拖慢 everything），形状一致。

### 8.8.2 实验 B：ARP 表观测（stable 可见、pending 盲区、stats）

实验目的：用公共 API 观察 stable 表项随通信生长；确认 PENDING 对外不可见；读取 etharp 统计。输出摘录（run-normal.log）：

```text
[ARPTAB] --- dump @W boot ground truth ---
[ARPTAB] stable entries (ARP_TABLE_SIZE=10):
[ARPTAB]   (no stable entry)
...12 次 connect 之后...
[UDP] probe gw-dns -> 10.0.2.3 : rc=4
[ARPTAB] --- dump @B after resolved 10.0.2.3 ---
[ARPTAB]   slot  1: 10.0.2.2 @ 52:55:0a:00:02:02 netif=en2
[ARPTAB]   slot  2: 10.0.2.3 @ 52:55:0a:00:02:03 netif=en2
[PEND] sent probe to unresolved 10.0.2.77, watch pending lifecycle ...
[UDP] probe dead-ip -> 10.0.2.77 : rc=4
[ARPTAB] --- dump @B right after pending created (public API sees nothing) ---
[ARPTAB]   slot  1: 10.0.2.2 @ 52:55:0a:00:02:02 netif=en2
[ARPTAB]   slot  2: 10.0.2.3 @ 52:55:0a:00:02:03 netif=en2
...
[STATS] final lwIP stats:
ETHARP
	xmit: 17
	recv: 2
	...
	memerr: 0
	cachehit: 58
```

解读与要点：

1. 观测函数通过 `tcpip_callback()` 投递进 tcpip_thread 执行后再遍历 `etharp_get_entry()`——绕开数据竞争的同时，顺手演示了"想碰栈内部状态就必须进入它的线程"这条系列公理。
2. 表项 MAC 正是 8.3 提到的 SLIRP 假 MAC；slot 编号随驱逐史漂移（debug 变体里能看到 slot0/1 的兴衰），属正常现象而非泄漏。
3. `probe dead-ip` 后立刻 dump **看不到 .77**——PENDING 盲区实证。它的完整生命周期要看日志：下方 debug 变体输出显示 `.77` 的表项在 5 秒后被 `etharp_timer: expired pending entry 1.` 连同排队的数据包一起回收。
4. stats 三处值得圈点：`xmit:17`（17 个 ARP 请求帧：DHCP 若干 + bench 前若干 + pending 重发若干）、`recv:2`（只有 .2/.3 两个目标肯应答）、`cachehit:58`（8.4 的 last-hit 快路把 15 次 connect 的后续数据包几乎全部拦在线性扫描之前）。
5. **memerr:0 但实验 C 里确实有 sendto 失败**——这正是 8.5 说的 ESP_LWIP_ARP 补丁静默路径，别拿单一计数器断案。

### 8.8.3 实验 C：故障注入·表满（ARP_TABLE_SIZE=2）

实验目的：把表压到 2 格，制造"新解析逐出稳定网关 → 死目标占坑 → 网关打回冷态"的连锁，并验证排队的长度上限与 expired 行为。debug 变体（自带 ETHARP_DEBUG 日志）单次运行即可同时作证实验 C 与 D；先看应用层输出（run-dbg.log 逐字摘录）：

```text
I (1602) ch8lab: [CFG] build: ARP_TABLE_SIZE=2, ARP_QUEUEING=1, LWIP_STATS=1
[ARPTAB] --- dump @B after resolved 10.0.2.3 ---
[ARPTAB]   slot  1: 10.0.2.3 @ 52:55:0a:00:02:03 netif=en2     ← 10.0.2.2 被挤掉了！
[ARPTAB] --- dump @B right after pending created ---
[ARPTAB]   (no stable entry)                                    ← 两格全被占满
[TICK] +5s
etharp_timer
etharp_timer: expired pending entry 1.
etharp_free_entry: freeing entry 1, packet queue 0x3ffba284.   ← .77 出局，连带弃包
...
[BURST] queue-fill: 5 rapid datagrams -> 10.0.2.101 (resolve pending)
etharp_query: queued packet 0x3ffbade8 on ARP entry 0          ← #0 入队
etharp_query: queued packet 0x3ffbae4c on ARP entry 0          ← #1 入队
etharp_query: queued packet 0x3ffbaeb0 on ARP entry 0          ← #2 入队
etharp_query: could not queue the packet 0x3ffbaf14 (queue is full)  ← #3
etharp_query: could not queue the packet 0x3ffbaf14 (queue is full)  ← #4
[BURST]   #0 rc=4
[BURST]   #1 rc=4
[BURST]   #2 rc=4
[BURST]   #3 rc=-1Not enough space                             ← socket 同步感知
[BURST]   #4 rc=-1Not enough space
...
[BENCH] === post-evict: 3x connect 10.0.2.2:8108 ===
etharp_find_entry: selecting oldest pending entry 1, freeing packet queue 0x3ffbadcc
etharp_update_arp_entry: updating stable entry 1
ethernet_output: sending packet 0x3ffba3fc                     ← 排队的 SYN 随应答起飞
[BENCH] post-evict conn#00 took 11225 us : ESTABLISHED         ← 打回冷态！
[BENCH] post-evict conn#01 took  3235 us : ESTABLISHED
[BENCH] post-evict conn#02 took  3438 us : ESTABLISHED
```

同轮中两条决定性的驱逐证据（etharp 日志，紧邻阶段标记便于对时序）：

```text
etharp_find_entry: selecting oldest stable entry 1        ← 解析 .3 时牺牲了 stable 的网关
etharp_find_entry: selecting oldest stable entry 1        ← 解析 .77 时又牺牲 stable 的 .3
etharp_find_entry: selecting oldest pending entry 1, freeing packet queue ...
                                                          ← .201 挤掉更老的 pending（并列龄取后扫者）
```

解读：

1. **容量悬崖是乘法效应**：10 格 → 2 格后，任何第三个活跃目标都会把"最老的稳定项"逐出。于是「解析 DNS 把网关挤掉」「探活死地址把 DNS 挤掉」级联发生，最终两格全是死目标的 PENDING，谁也别想工作——实验 A 尚可通过队列优雅延迟，表满则是雪崩式降级。
2. 队列上限精确等于 `ARP_QUEUE_LEN=3`：第 4、5 个 datagram 撞线，错误一路穿透到 socket 层。与 8.5 对照：若这是上游原版行为，看到的将是"队首旧包被释放、#3/#4 入队成功"；IDF 的保旧弃新在此一目了然。
3. post-evict 的 11.2 ms 与实验 A 的 22.6 ms 同数量级、与 warm 的 3.2 ms 相去甚远——**驱逐的代价就是重新支付一遍 ARP RTT**。生产固件大量短连接轮询多目标时（SNMP 探测、多传感器轮询），这张只有 10 格的表值得怀疑一次。
4. PENDING 生命周期严格 5 s：`.77` 从创建（TICK 前）到 `expired pending entry 1`（TICK +5s 与 +6s 之间）逐 tick 重发请求后阵亡，排队的那枚 UDP 帧同归于尽——印证 8.5 的"排队非投递"。

### 8.8.4 实验 D：帧内容抓取的方法学（guest 侧 ETHARP_DEBUG）

大纲期待的 sudo tcpdump 方案在本环境不可行：SLIRP 是 QEMU 进程内的用户态网络栈，guest↔slirp 的"线路"没有内核 NIC 可供 `tcpdump -i lo` 捕获（lo 上抓到的只能是宿主机自身 127.0.0.1:8108 的 host 侧流量，不含 guest 帧）。替代方法学：debug 变体打开 `CONFIG_LWIP_DEBUG` + `CONFIG_LWIP_ETHARP_DEBUG`，让 `ethernet_input()` 自己把每个进站的帧播报出来：

```text
ethernet_input: dest:52:54:00:12:34:56, src:52:55:0a:00:02:02, type:806   ← ARP 应答进站
etharp_update_arp_entry: 10.0.2.2 - 52:55:0a:00:02:02                     ← 学习成功
etharp_input: incoming ARP reply
ethernet_input: dest:ff:ff:ff:ff:ff:ff, src:52:55:0a:00:02:02, type:800   ← DHCP 广播(IP)
ethernet_input: dest:52:54:00:12:34:56, src:52:55:0a:00:02:02, type:800   ← 网关转来的 TCP
```

方法学差异说明：这不是线上的原始字节而是栈解码后的摘要（无 ARP 头字段逐字节 dump，看不到 htype/opcode 十六进制原文）；但 type/MAC/后续 etharp 决策行足以逐帧对账，且**视角天然在 guest 栈内部**，反而比外部抓包更贴近本章主题。宿主机 tcpdump 留给有 tap/bridge 拓扑的环境复现。

GARP 定时器的足迹也在静默期的日志里现形：应用 idle 后除了每秒的 `etharp_timer` 心跳，唯一孤立的：

```text
etharp_timer
etharp_timer
etharp_request: sending ARP request.       ← 应用没说一个字，这是 60s GARP 在广播
etharp_raw: sending raw ARP packet.
etharp_timer
```

结合 8.6 的源码考证（esp_netif_lwip.c 的 sys_timeout 60 s 循环调用 `etharp_gratuitous()`），可安心归因；vanilla 原版不会有这条周期广播。

> [!tip] 复现提示
> 想必看每个字段？可在 sdkconfig.defaults.debug 里追加 `CONFIG_LWIP_NETIF_DEBUG=y` 甚至自定义 hook；想要宿主机侧真抓包，把 QEMU 换成 `-netdev tap` 桥接拓扑即可，guest 代码零改动。

## 8.9 小结

- 一个以太网帧入栈共五次转手：openeth RX 任务 → esp_eth/glue（组 pbuf）→ `tcpip_input` 邮箱 → `tcpip_thread` 内 `ethernet_input()` 按 ethertype 分派（IP/ARP/IPv6），每个分支先用 `pbuf_remove_header(p,14)` 完成 LINK 层让渡——ch4 实测的 LINK=14/IP=54/TRANSPORT=74 阶梯由这两次剥头构成。
- ARP 缓存是 `arp_table[ARP_TABLE_SIZE]` 静态数组（上游与 IDF 默认同为 10 格，无 Kconfig），安全建立在 tcpip_thread 单线程模型之上；对外只见 STABLE（`etharp_find_addr/get_entry`），PENDING 是公共盲区。
- 五态状态机 EMPTY/PENDING/STABLE/REREQUESTING_1/2(+STATIC)：PENDING 寿命 5 s 且每秒重发请求；STABLE 寿命 300 s，但使用者会在 270 s（单播）/285 s（广播）抢先续命——长连接不断流的机制保障。
- `etharp_output()` 三分法：广播/多播直发（多播 MAC=01:00:5e+IP 低 23 位）、网外目标替换成网关代解析、单播查表——命中走 last-hit 快路（cachehit 计数可达 58），未命中 `etharp_query()` 建表发请求并把包挂队列返回 OK，首包延迟由此诞生（实测冷 22.6 ms vs 热 ~2.6 ms，约 8 倍）。
- 驱逐优先级 empty > 最老 STABLE > 最老 PENDING(无队) > 最老 PENDING(有队)，同龄后扫者胜；STABLE 网关随时可能陪葬（实验 C 实证两次）。
- 排队：IDF 强制 `ARP_QUEUEING=1` + 每项上限 `ARP_QUEUE_LEN=3` + 30 深节点池；队满时 `ESP_LWIP_ARP` 补丁改为丢新返 ERR_MEM（socket 见 ENOMEM）且不计 memerr——统计不可尽信；队列出口只有"应答补发"或"过期弃包"两种。
- GARP：vanilla 只在 `netif_set_up()`/`netif_set_link_up()` 时广播一次；IDF 默认（`CONFIG_LWIP_ESP_GRATUITOUS_ARP=y`）60 s 周期广播（`CONFIG_LWIP_GARP_TMR_INTERVAL`），实现在 esp_netif 的 sys_timeout 循环，静默期日志中的孤立 etharp_request 就是它。
- 故障注入方法论：无 Kconfig 的 lwIP 宏用 `add_compile_definitions(-D)` 全局覆盖（经 compile_commands.json 验证落到 etharp.c 编译单元）；"逻辑注入 + debug 日志取证"的组合在 SLIRP 无法抓包的环境中可复现一切引用过的现象。

帧的世界到此收束：本章结束时，payload 指针已经稳稳落在 IP 头上。下一章顺着这个指针继续剥——[[2026-08-26-lwip-deep-dive-ch9-ip4-icmp|第九章]]深入 `ip4_input()` 的校验、分片重组与转发判定，外加 ICMP：ping 到底经历了什么、回显报文在哪一行拐弯，让我们把"网关能 ping 通"这句话拆成字节级别的真相。
