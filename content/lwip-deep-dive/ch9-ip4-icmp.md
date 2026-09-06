---
title: "lwIP 深度解析（九）：IP 与 ICMP：路由决策与 ping 的完整往返"
date: 2026-08-26
description: "站到包视角：拆解 ip4_input 的版本/校验/地址四分类决策树、ip4_forward 的 TTL 与增量校验、无选项直发与 PBUF_RAM 链的 ip4_frag 切分术、reassdatagrams 链表上 ip_reass_helper 复用 IP 头存偏移的重组技巧（含 MAX_PBUFS 溢出逐出与 IDF 把 IP_REASS_MAXAGE 砍成 3 秒的差异），再以 icmp.c 讲透 echo 原地翻转与差错信使的三类报文；最后用四个真实实验还原 ping 一去一回的全部停靠点——4000B 大包分片往返、ttl=255 的 SLIRP 代答指纹、15000B 洪峰下的不完整数据报停摆与 ICMP Time Exceeded 自证、以及 ARP 解析失败后的静默超时。"
tags: [lwip, network, esp32, esp-idf, qemu]
---

> [!info] lwIP 深度解析系列 0. [[lwip-deep-dive|系列索引]] 9. **第九章：IP 与 ICMP：路由决策与 ping 的完整往返**

# lwIP 深度解析（九）：IP 与 ICMP：路由决策与 ping 的完整往返

这一章回答三个问题：**`ip4_input()` 拿到一个包之后要做几个决策**（版本/长度/校验三连检，然后本机、广播、多播、转发四岔路口）、**一个大于 MTU 的包怎么拆开又怎么拼回来**（`ip4_frag()` 的切分数学与 `ip4_reass()` 在 pbuf 里借地扎营的重组技巧）、**ping 的一去一回在协议栈里各停哪些站**（esp_ping 任务 → raw socket → IP → openeth → SLIRP 代答 → 回程 `icmp_input`，每一站的源码证据都在）。读完它，第三章那句「`ttl=255` 是网关亲自回话的指纹」会得到完整的机制解释，你还会亲手把重组缓冲区压到停摆、再看着 lwIP 自己给自己发一封 ICMP Time Exceeded。源码参照：ESP-IDF v6.0.2（`~/esp/esp-idf`）捆绑的 lwIP 2.2.0-dev；所有运行输出来自本章实验工程 `practice/lwip-ch09-ip4-icmp/` 的真实运行日志。

---

## 9.1 `ip4_input`：一个包在 IP 层的四道选择题

入口是 `src/core/ipv4/ip4.c` 的 `ip4_input(struct pbuf *p, struct netif *inp)`——第七章讲过，netif 的 `input()` 链（openeth 走 `ethernet_input` → `ip4_input`）最终都汇到这里。它对每个包做四道选择题：

### 决策零：三连检不过，计数器知道

```c
/* src/core/ipv4/ip4.c, ip4_input() 开头 */
iphdr = (struct ip_hdr *)p->payload;
if (IPH_V(iphdr) != 4) {                 /* 1) 版本号 */
    ... pbuf_free(p); IP_STATS_INC(ip.err); IP_STATS_INC(ip.drop);
}

iphdr_len = lwip_ntohs(IPH_LEN(iphdr));
if (iphdr_len < p->tot_len) {            /* 帧填充比 IP 包长？裁掉以太网 padding */
    pbuf_realloc(p, iphdr_len);
}
if ((iphdr_hlen > p->len) || (iphdr_len > p->tot_len) || (iphdr_hlen < IP_HLEN)) {
    ... pbuf_free(p); IP_STATS_INC(ip.lenerr);      /* 2) 长度自洽 */
}
if (inet_chksum(iphdr, iphdr_hlen) != 0) {
    ... IP_STATS_INC(ip.chkerr); IP_STATS_INC(ip.drop); /* 3) 头校验和 */
}
```

三个失败出口对应 `lwip_stats.ip` 的三枚不同计数器：`err`（坏版本）、`lenerr`（头长字段自相矛盾）、`chkerr`（校验和不符）。第二段里那个 `pbuf_realloc` 解释了一个 Ethernet 细节：最小帧 60 字节，而小 IP 包往往不足 60，多余 padding 必须在这里裁掉，否则上层会读进垃圾。

### 决策一：目标地址四分类

接下来拷贝 src/dest 到全局 `ip_data.current_iphdr_dest/src`（后面所有「当前包」语义都靠它），然后分类：

| 分类       | 判定                                        | 出路                                                      |
| ---------- | ------------------------------------------- | --------------------------------------------------------- |
| 本机单播   | `ip4_input_accept()`：dest == netif 地址    | 接受，往下走                                              |
| 广播       | `ip4_addr_isbroadcast(dest, netif)`         | 接受，往下走                                              |
| 多播       | `ip4_addr_ismulticast(dest)`                | 仅当本 netif 是 IGMP 成员（`igmp_lookfor_group()`）才接受 |
| 非以上任何 | 全部 netif 试过 `ip4_input_accept()` 都失败 | `netif == NULL` → 转发或丢弃                              |

两个值得停留的细节。其一，「接受」检查**先看接收 netif 本人**（`inp` 优先），不行才遍历整个 netif 链表——单网卡场景下绝大多数流量在第一格就定案。其二，DHCP 有个后门通道：`IP_ACCEPT_LINK_LAYER_ADDRESSING` 分支允许 dest 不是自己的 UDP 68 端口包通过——因为 DHCP 握手时客户端还没有 IP，按 IP 地址过滤会把 offer 全部扔掉。

### 决策二：要不要替别人转发？（`ip4_forward`）

`netif == NULL` 且目标非广播时进入转发分支。IDF 默认 `CONFIG_LWIP_IP_FORWARD=n`（vanilla 同样默认 0），所以默认行为是**静默丢弃并累加 `mib2.ipinaddrerrors`**——一台 ESP32 默认不做路由器。开了开关后，`ip4_forward()` 的流水线很值得一读：

```c
IPH_TTL_SET(iphdr, IPH_TTL(iphdr) - 1);        /* TTL 减一 */
if (IPH_TTL(iphdr) == 0) {                      /* 归零 → 差错信使 */
    if (IPH_PROTO(iphdr) != IP_PROTO_ICMP) {
        icmp_time_exceeded(p, ICMP_TE_TTL);     /* type=11 code=0 */
    }
    return;
}
/* 增量修正校验和：只改了 TTL，重算太浪费 —— 整数加法搞定 */
if (IPH_CHKSUM(iphdr) >= PP_NTOHS(0xffffU - 0x100)) {
    IPH_CHKSUM_SET(iphdr, (u16_t)(IPH_CHKSUM(iphdr) + PP_NTOHS(0x100) + 1));
} else {
    IPH_CHKSUM_SET(iphdr, (u16_t)(IPH_CHKSUM(iphdr) + PP_NTOHS(0x100)));
}
```

TTL 减一只影响头的两个字节，重算整个校验和不如**加减补偿**：TTL 每 -1，反码和减 1，补回校验等价于校验字段 +1（16 位网络序即 +0x0100）。这就是 RFC 1141 的增量更新。

顺带清点转发路径里的 ESP-LWIP 补丁：`ip4.c` 全文共三段 `#if ESP_LWIP && IP_NAPT`——入向 `ip4_input` 查 NAPT 表还原目的地址（`ip_napt_recv()`）、转发前 `ip_napt_forward()` 改写源地址端口、以及 PBUF_REF 型转发包在发送前 `pbuf_clone` 一份整装副本的兜底。这是不改一行 IDF 代码也能在 core 文件里直接读到的 IDF 改造实证。超大包的处理也在转发路径里：带 DF 标志就回 `ICMP_DUR_FRAG`（type 3 code 4「需要分片但 DF 已置位」，PMTUD 的基石），否则调 `ip4_frag()` 拆了再发。

### 决策三：交给哪个上层？

接受且重组完成（若有分片）之后，才轮到分发。注意 lwIP **没有**「协议注册表」这种运行时机制——TCP/UDP/ICMP 的分发是编译期写死的 switch：

```c
raw_status = raw_input(p, inp);          /* raw PCB 链表最先摘桃子 */
if (raw_status != RAW_INPUT_EATEN) {
    pbuf_remove_header(p, iphdr_hlen);   /* payload 下移越过 IP 头 */
    switch (IPH_PROTO(iphdr)) {
    case IP_PROTO_UDP:  udp_input(p, inp);  break;
    case IP_PROTO_TCP:  tcp_input(p, inp);  break;
    case IP_PROTO_ICMP: icmp_input(p, inp); break;
    case IP_PROTO_IGMP: igmp_input(...);    break;
    default:
        if (raw_status == RAW_INPUT_DELIVERED) { /* raw 已经感兴趣但没有吃掉 */ }
        else {
            /* 未注册协议 → ICMP Destination Unreachable, code 2 "protocol" */
            if (!broadcast && !multicast) icmp_dest_unreach(p, ICMP_DUR_PROTO);
            IP_STATS_INC(ip.proterr);
        }
        pbuf_free(p);
    }
}
```

所谓「动态注册」只有 raw 层一处：`raw_pcb` 全局链表按 protocol 字段匹配。socket API 里 `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)` 创建的就是这样的 pcb（本章的主角 esp_ping 正是这条路）。对未知协议，发一张 type 3 code 2 的不可达票据然后丢弃——「ICMP 是 IP 层的差错信使」第一次现形。顺带一个精妙设计：`raw_input()` 返回 `RAW_INPUT_DELIVERED` 而没吃掉包时（netconn 层的 recv 回调只是克隆入邮箱、原包继续流动，见 9.4），后续 switch 还能照常执行——同一个包可以被 raw 和内核各处理一次。

## 9.2 分片与重组：`ip4_frag` 拆解术与 `ip4_reass` 扎营法

文件都在 `src/core/ipv4/ip4_frag.c`，一半管拆、一半管装。

### 出向：`ip4_frag()` 的切分数学

触发点有两个：`ip4_output_if()` 末尾发现 `p->tot_len > netif->mtu` 时（我们主动发包）；`ip4_forward()` 转发大包时。函数开头先把规矩立好：

```c
const u16_t nfb = (u16_t)((netif->mtu - IP_HLEN) / 8);  /* number of fragment blocks */
...
if (IPH_HL_BYTES(iphdr) != IP_HLEN) return ERR_VAL;     /* 不支持带选项的头 */
left = (u16_t)(p->tot_len - IP_HLEN);                   /* 待切的数据量 */
while (left) {
    fragsize = LWIP_MIN(left, (u16_t)(nfb * 8));        /* MTU1500 → 每片 1480B */
    ...
    last = (left <= netif->mtu - IP_HLEN);
    tmp = (IP_OFFMASK & ofo);
    if (!last || mf_set) tmp |= IP_MF;                  /* 中间片都要 MF */
    ...
    ofo += nfb;                                         /* 片偏移按 8 字节块推进 */
}
```

MTU 1500 减 20 字节 IP 头得 1480，且必须是 8 的倍数（RFC 791 要求除末片外每片数据长度是 8 字节的整数倍，这样片偏移才能以 8 字节为单位编码进 13 位）——`nfb = (1500-20)/8 = 185`，185×8 = 1480。以后每个请求的 ID 由 `ip4_output_if` 里那个静态递增变量 `ip_id` 提供，同一次发送的所有分片共享同一 ID，这正是重组端配对的钥匙。

装填方式因宏而异。vanilla 用零拷贝的花活：PBUF_RAM 小头 + 一串 PBUF_REF 指回原包内存。ESP-IDF 则落到朴素路线——Batch 2 结论重温：IDF 把 `LWIP_NETIF_TX_SINGLE_PBUF` 硬编码为 1（`port/include/lwipopts.h`），所以走这条分支：

```c
#if LWIP_NETIF_TX_SINGLE_PBUF
    rambuf = pbuf_alloc(PBUF_IP, fragsize, PBUF_RAM);   /* 整片新分配 */
    poff += pbuf_copy_partial(p, rambuf->payload, fragsize, poff); /* 拷过来 */
    pbuf_add_header(rambuf, IP_HLEN);                   /* 再盖 IP 头 */
    SMEMCPY(rambuf->payload, original_iphdr, IP_HLEN);  /* 抄原始头 */
#endif
```

每个分片一份全新 RAM 内存，从原 pbuf 拷数据、抄头、改 offset/MF/total_len、重算头校验和，立刻 `netif->output()` 打出去再释放。多花内存换确定性——分散在各链节里的原始包无需保活，也避免了 PBUF_REF 被 DMA 异步发送时的生命周期难题。

### 入向：`ip4_reass()` 在 pbuf 里借地扎营

重组的核心数据结构是一道单链表加一个计数器：

```c
static struct ip_reassdata *reassdatagrams;   /* 进行中的 datagram 链表 */
static u16_t ip_reass_pbufcount;              /* 当前占用的 pbuf 总数 */

struct ip_reassdata {
  struct ip_reassdata *next;
  struct pbuf *p;         /* 分片串成的 pbuf 链头 */
  struct ip_hdr iphdr;    /* 配对用的首片副本 */
  u16_t datagram_len;
  u8_t flags;
  u8_t timer;
};
```

最漂亮的技巧藏在 `struct ip_reass_helper` 里（也是本章标题「借地扎营」的出处）：

```c
PACK_STRUCT_BEGIN
struct ip_reass_helper {
  PACK_STRUCT_FIELD(struct pbuf *next_pbuf);
  PACK_STRUCT_FIELD(u16_t start);
  PACK_STRUCT_FIELD(u16_t end);
} PACK_STRUCT_STRUCT;
```

它只有 8 个字节，比 20 字节的 IP 头小，于是每个分片 pbuf 直接**把自己的 IP 头覆盖成这个 helper 结构**：start/end 记录该片数据的字节区间，next_pbuf 把各片串成有序链表。一片内存三种用途（帧缓冲 → 重组节点 → 完整报文的一员），零额外开销。第一片的原始头另有备份存在 `ipr->iphdr`（重组成功要靠它还原正确 total_len 并重算校验和）。

配对键是三元组 `src + dst + IP_ID`（宏 `IP_ADDRESSES_AND_ID_MATCH`）。命中已有条目计一枚 `ip_frag.cachehit`；没命中就从 `MEMP_REASSDATA` 池里开新帐。`ip_reass_chain_frag_into_datagram_and_validate()` 把新片按 start 有序插入链中，插入时检查重叠与重复：`CHECK_OVERLAP=1` 下任何交叠或完全重复的分片直接扔（注释明说：不支持重叠，重复投递也不去重留新）。「完整性」判定只需两条线索齐备：见过 MF=0 的末片（置 `IP_REASS_FLAG_LASTFRAG`）＋ 首片 start==0 在场 ＋ 链上无缝隙。三者同时成立，就地拼包：还原头、`pbuf_cat` 串链、返回完整 pbuf 给 `ip4_input` 继续走分发。

### 溢出与超时：缓冲区的两条底线

```c
clen = pbuf_clen(p);
if ((ip_reass_pbufcount + clen) > IP_REASS_MAX_PBUFS) {
#if IP_REASS_FREE_OLDEST
    if (!ip_reass_remove_oldest_datagram(fraghdr, clen) ||
        ((ip_reass_pbufcount + clen) > IP_REASS_MAX_PBUFS))
#endif
    {
        IPFRAG_STATS_INC(ip_frag.memerr);       /* Overflow condition 日志在此 */
        goto nullreturn;                        /* 丢新人，不发任何 ICMP (@todo) */
    }
}
```

第一条底线是容量：`IP_REASS_MAX_PBUFS`（IDF Kconfig 名 `CONFIG_LWIP_IP_REASS_MAX_PBUFS`，范围 10~100，默认 10）。超限时先逐出**别的**数据报（`ip_reass_remove_oldest_datagram` 按 timer 最老优先挑别人下手，绝不踢正在配对的 fraghdr 本人）；救不回来就丢新来的分片——注意此时**不给任何人回 ICMP**，源码里的 `@todo: send ICMP time exceeded here?` 还挂着账。

第二条底线是时间。每条 reassdata 带一个 `timer` 字段，`ip_reass_tmr()` 每秒把全场减一，减到 0 就回收整个半成品。这里撞上了本章第一个重要版本差异：

> [!warning] IDF 把重组寿命砍成 3 秒
> vanilla lwIP `opt.h` 定 `IP_REASS_MAXAGE = 15`（单位是 `IP_TMR_INTERVAL`=1000ms 的倍数）；ESP-IDF 在 `components/lwip/port/include/lwipopts.h` 里直接覆写成 **`#define IP_REASS_MAXAGE 3`**。嵌入式视角很好理解：10 个 pbuf 上限的池子，卡一条半成品 15 秒是不可接受的资源绑架。3 秒到期回收时还有一个微妙分支——`ip_reass_free_complete_datagram()` 只有在**首片已经收到**时才会反向给发送方捎信（`icmp_time_exceeded(p, ICMP_TE_FRAG)`，type 11 code 1），因为它手里必须有一份合法的原始 IP 头才能构造回执。9.6 实验 C 会让你亲眼看到这封信。

定时器的调度本身也被 IDF 动过：vanilla 在 `timeouts.c` 的静态表里登记 `{IP_TMR_INTERVAL, HANDLER(ip_reass_tmr)}`，只要 IP_REASSEMBLY 编译进来这个计时器就永久运转；IDF 加了 `ESP_LWIP_IP4_REASSEMBLY_TIMERS_ONDEMAND`——只有真正出现待重组分片才 `sys_timeout()` 挂表，收完/超时就摘除。又一次「按需定时器」改造（第一章提过 DHCP/DNS 同款待遇）。

## 9.3 `icmp.c`：echo 引擎与差错信使

ICMP 报文挂在 IP 协议号 1 下面，头部四字段一目了然（`src/include/lwip/prot/iana.h` 与 `icmp.h` 定义常量）：

| 类型 | 常量                        | 方向 | 本章相关触发点                                                            |
| ---- | --------------------------- | ---- | ------------------------------------------------------------------------- |
| 0    | `ICMP_ER` Echo Reply        | 应答 | `icmp_input()` 原地翻转生成                                               |
| 3    | `ICMP_DUR` Dest Unreachable | 差错 | 未知协议(code 2)、UDP 无端口(code 3，第十章)、DF 太大(code 4)、转发无路由 |
| 8    | `ICMP_ECHO` Echo Request    | 请求 | ping                                                                      |
| 11   | `ICMP_TE` Time Exceeded     | 差错 | 转发 TTL 归零(code 0)、重组超时(code 1)                                   |

### echo：最高效的一张应答

`icmp_input()` 收到 type=8 时几乎不重新造包——**原地翻转复用**：

```c
iecho = (struct icmp_echo_hdr *)p->payload;
pbuf_add_header(p, hlen);                    /* 回退到 IP 头 */
iphdr = (struct ip_hdr *)p->payload;
ip4_addr_copy(iphdr->src, *src);             /* src ↔ dest 对调 */
ip4_addr_copy(iphdr->dest, *ip4_current_src_addr());
ICMPH_TYPE_SET(iecho, ICMP_ER);              /* 8 → 0 */
/* 类型变了只差一字节，校验和照样增量修补，而不是全量重算 */
iecho->chksum += PP_NTOHS(ICMP_ECHO << 8)...
IPH_TTL_SET(iphdr, ICMP_TTL);                /* 应答用独立 TTL */
ret = ip4_output_if(p, src, LWIP_IP_HDRINCL, ICMP_TTL, 0, IP_PROTO_ICMP, inp);
```

一句历史注脚：ICMP_TTL 最终取值 `IP_DEFAULT_TTL`，vanilla 默认 **255**，IDF 经 `CONFIG_LWIP_IP_DEFAULT_TTL` 改为 **64**——所以一台真 ESP32（或 lwIP 设备）亲自回答 ping 时 TTL 通常露馅 64 或 255 的出身，排障时极有用。还有个防御性检查顺手记下：目标是多播/广播地址的 echo request 默认**不应答**（`LWIP_MULTICAST_PING/BROADCAST_PING` 控制），避免广播风暴放大。

### 差错信使：全协议栈共四处发信人

`icmp_dest_unreach()` / `icmp_time_exceeded()` 都汇入 `icmp_send_response()`：从闯祸的原包**抄下 IP 头 + 前 8 字节数据**（`ICMP_DEST_UNREACH_DATASIZE = 8`，正是 RFC 规定的引用量——8 字节足以让 TCP/UDP 对上端口号）塞进新报文，路由回源地址。全栈的发信点收敛到四处，值得背下来：

| 发信点                              | 报文                   | 场景                       |
| ----------------------------------- | ---------------------- | -------------------------- |
| `ip4_input()` default 分支          | DUR code 2             | 协议号没人认领             |
| `udp_input()`                       | DUR code 3             | 端口无人监听（第十章实验） |
| `ip4_forward()`                     | TE code 0 / DUR code 4 | TTL 归零 / DF 撞墙         |
| `ip_reass_free_complete_datagram()` | TE code 1              | 重组超时（实验 C 见）      |

而当 lwIP **收到**别人的差错报文时，现状相当冷淡：`icmp_input()` 的 default 分支只更新 MIB2 计数（`icmpindestunreachs` 等），然后丢弃——文件头那句注释就是官方承认：_"Some ICMP messages should be passed to the transport protocols. This is not implemented."_ 因此 esp_ping 判断目标是否可达，从不指望收到差错票据，只能按 SO_RCVTIMEO 超时落袋。实验 D 会正面展示这一点。

## 9.4 ping 的一去一回：十五个停靠点

### 时序总览

```text
 esp_ping task (FreeRTOS)          tcpip_thread                     主机/QEMU
 ───────────────────────          ─────────────                    ─────────
 │ sendto(SOCK_RAW,ICMP)
 │  └─(VFS→netconn→mbox)──┐
 │                        ▼
 │                   raw_send: 组 ICMP echo(type8,id,seq,data)
 │                        │
 │             ip4_output_if: 盖 IP 头(id=ip_id++, ttl=64*)
 │                        │ tot_len>MTU? ──yes──► ip4_frag(): 1480B ×N片
 │                        ▼                       （PBUF_RAM 逐片复制）
 │                 ethernet_output → openeth DMA → QEMU ethmac
 │                                                 │
 │                                     ┌───────────▼────────────┐
 │                                     │ SLIRP 用户态网络栈       │
 │                                     │  ①dst=10.0.2.2 网关本人  │
 │                                     │    → vhost 代答(TTL=255)│
 │                                     │  ②公网 IP → 打开 host 的 │
 │                                     │    unprivileged ping    │
 │                                     │    socket 转发,回程重写   │
 │                                     │    TTL=255 ③超大回复照样  │
 │                                     │    按 guest MTU=1500     │
 │                                     │    ip_fragment() 逐片回送│
 │                                     └───────────┬────────────┘
 │                                                 ▼
 │             ethernet_input ◄─ openeth RX（burst 超限则驱动丢帧!）
 │                        │
 │               ip4_input: 三连检/地址匹配 ✓ → MF|offset≠0?
 │                        │ yes ──► ip4_reass(): 三元组配对/有序插链/
 │                        │        LASTFRAG+无缝隙 → 拼回完整包
 │                        ▼
 │           raw_input(): 匹配 ping 的 raw_pcb
 │            → recv_raw 克隆 pbuf 入 recvmbox（DELIVERED，未 EATEN）
 │            → 继续 icmp_input(): type=0 只累加计数
 │                        │
 │  ◄──(recvmbox)──────────┘
 │ recvfrom() 匹配 id+seqno → 取 IPH_TTL/IPH_LEN → on_ping_success()
 └ RTT = gettimeofday 差值（任务级时钟，非内核级）
   超时 = SO_RCVTIMEO 到点 → on_ping_timeout()
```

### 每一站的源码证据

esp_ping 不是独立组件——实现在 `components/lwip/apps/ping/ping_sock.c`（CMake 只需 `PRIV_REQUIRES lwip`，Batch 1 已验证的结论）。几个关键实现选择决定了上面图上的形状：

- **raw socket 而非 raw API**：`ep->sock = socket(AF_INET, SOCK_RAW, IP_PROTO_ICMP)`。应用侧是普通 fd，内核侧就是一个挂进 raw 链表的 pcb；
- **单飞节奏**：`esp_ping_thread` 循环体是严格的 send → receive → delay，一个会话永远只有一个未决请求。想制造并发洪峰必须开会话堆叠（9.6 实验 C 正是这么干的）；
- **id 即任务句柄**：`ep->packet_hdr->id = ((intptr_t)ep->ping_task_hdl) & 0xFFFF`——简单粗暴地保证同设备多个会话不打架；
- **接收缓冲固定 64 字节**（`IP_ICMP_HDR_SIZE`）：哪怕回了 4000B 大包，recvfrom 也只搬走前 64 字节，纯当元数据信封用；数据长度另有算法 `recv_len = ntohs(IPH_LEN) - 头长`，从 IP 头字段读出来；
- **双停靠是特性而非意外**：响应先被 raw 层克隆进 socket 邮箱，原包继续流进 `icmp_input()`——那里对 type=0 除了把 `icmpinechoreps` 计数加一什么也不做，然后把 pbuf 释放。一篇报文两个子系统各看一眼，互不相扰。

### ttl=255 的机制解释（ch3 之约）

第三章我们凭现象断言「SLIRP 作为协议栈终点应答而非转发者」。现在补全机制面：QEMU 的 `-nic user` 用 libslirp 实现了一整套用户态 IP 栈，`10.0.2.2` 是它的「虚拟主机本人」（vhost）。guest ping 10.0.2.2 时，SLIRP 根本不出 NAT——它在进程内就把 echo request 转成交给宿主机体系的 ping 操作、拿到响应后**自己组装**面向 guest 的应答，出向帧 TTL 由它自带的全局缺省给出满值 255。更妙的是对照：即便目标是不折不扣的外网地址（经 NAT 真正出门绕若干跳），guest 看到的应答 TTL **依然是 255**——因为响应回来经过 SLIRP 重写在先，guest 无法透过它观测真实的逐跳衰减。9.6 实验 B 用一组三方对照把这个指纹钉死。

## 9.5 Vanilla lwIP 与 ESP-IDF lwIP 对照

| 维度           | vanilla lwIP 2.2.0-dev                                        | ESP-IDF lwIP（本仓库实测）                                                                                                                                      |
| -------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 出向分片       | `IP_FRAG` 默认 1                                              | Kconfig `CONFIG_LWIP_IP4_FRAG` 默认 y（保持开）                                                                                                                 |
| 入向重组       | `IP_REASSEMBLY` 默认 1                                        | **`CONFIG_LWIP_IP4_REASSEMBLY` 默认 n！** 关着的话收到的分片整包丢弃（`ip.opterr++`）                                                                           |
| 重组 pbuf 上限 | `IP_REASS_MAX_PBUFS` 默认 10，自定义随意                      | Kconfig `CONFIG_LWIP_IP_REASS_MAX_PBUFS` 范围锁死 **10~100**，默认 10                                                                                           |
| 重组寿命       | `IP_REASS_MAXAGE = 15` 秒                                     | port 覆写为 **3 秒**（`port/include/lwipopts.h`）                                                                                                               |
| 重组定时器     | `timeouts.c` 静态表常驻运转                                   | `ESP_LWIP_IP4_REASSEMBLY_TIMERS_ONDEMAND=1`：有分片才挂 sys_timeout                                                                                             |
| 重组统计口径   | mib2 计数需 `MIB2_STATS` 手工开启                             | **Kconfig 完全没暴露 MIB2_STATS**；本章实验用根 CMakeLists `add_compile_definitions(MIB2_STATS=1)` 全局注入                                                     |
| IP 转发/NAT    | `IP_FORWARD` 默认 0                                           | `CONFIG_LWIP_IP_FORWARD`(n) + `CONFIG_LWIP_IPV4_NAPT`(依赖前者)，core 内三处 `#if ESP_LWIP && IP_NAPT` 挂点（input 还原 dest、forward 改写、PBUF_REF 克隆兜底） |
| ICMP/TTL 缺省  | `ICMP_TTL = IP_DEFAULT_TTL = 255`                             | `CONFIG_LWIP_IP_DEFAULT_TTL` 默认 **64**                                                                                                                        |
| ping 应用      | 上游 contrib 的 `ping/ping.c`（socket 版示例，不随 src 发行） | **移植进 lwIP 组件内**：`components/lwip/apps/ping/ping_sock.c`（FreeRTOS 事件回调风格），不是 esp_ping 独立组件                                                |

grep 取证的 ESP_LWIP 补丁位置（勿再说「IDF 未改编 IP 层」）：`src/core/ipv4/ip4.c` 中三段 `#if ESP_LWIP`——`ip_napt_recv()` 入向还原、`ip_napt_forward()` 转发改写、转发 PBUF_REF 时 `pbuf_clone` 兜底；外加前述 `ip4_frag.c` 的 on-demand 定时器补丁。

> [!note] 我们的工程怎么打开这些开关
> `practice/lwip-ch09-ip4-icmp/sdkconfig.defaults`：`CONFIG_LWIP_IP4_REASSEMBLY=y`（默认竟是 n，必须显式打开才有重组实验可做）、`CONFIG_LWIP_IP_REASS_MAX_PBUFS=10`（取下限方便压测）、`CONFIG_LWIP_STATS=y`（观察 ip_frag/mib2 计数器）、`CONFIG_LWIP_DEBUG=y` + `CONFIG_LWIP_IP_DEBUG/ETHARP_DEBUG/ICMP_DEBUG=y`（抓取内核内部轨迹）。改完记得删 `sdkconfig` 重新生成。

## 9.6 实验：四个视角打包验证

工程 `practice/lwip-ch09-ip4-icmp/` 基于 ch3 模板（[[ch3-qemu-network-lab|第三章]]），四组实验按六个阶段推进：基线小包 → 大包分片（A）→ TTL 对照（B）→ 重组缓冲压力与并发洪峰、自愈回归（C）→ 不可达（D）。构建与运行沿用系列标准流程（hostfwd 按章号约定 8009，本章主机方向仅作可选验证，日志以 guest 视角为准）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch09-ip4-icmp
idf.py set-target esp32        # 仅首次
idf.py build
idf.py qemu monitor < /dev/null || true   # 生成 qemu_flash.bin / qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 80 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run.log
```

bring-up 后首个基线（供后面对比统计口径）：

```text
I (2738) ch9lab: GOT_IP: 10.0.2.15/255.255.255.0 gw 10.0.2.2
I (2738) ch9lab: == ping 10.0.2.2 data=64 count=2 timeout=1000ms ==
I (2738) ch9lab: 64 bytes from 10.0.2.2 icmp_seq=1 ttl=255 time=3 ms
I (2938) ch9lab: 64 bytes from 10.0.2.2 icmp_seq=2 ttl=255 time=1 ms
I (6538) ch9lab: [B-small-gw] dSTAT ip(recv=2 xmit=2 drop=0 chkerr=0 lenerr=0)
I (6538) ch9lab: [B-small-gw] dSTAT ip_frag(frag_out=0 reass_in=0 cachehit=0 DROP=0 MEMERR=0)
I (6538) ch9lab: [B-small-gw] dSTAT etharp(req=4 drop=0) mib2(reasmreqds=0 reasmOK=0 reasmFAIL=0)
```

64 字节的小包整包走人，`ip_frag` 一动不动——重组路径根本没被惊动。`dSTAT` 行是我们封装的统计快照差分（相邻两次打印之间的计数增量），全部数字出自 lwIP 自己的计数器。

### 实验 A：4000B 大包的分片往返

**目的**：单次 ping 同时点亮出向 `ip4_frag` 与入向 `ip4_reass`，验证 9.2 的切分数学。esp_ping 通过 `cfg.data_size` 支持自定义载荷（`ping_sock.c` 里 `icmp_pkt_size = sizeof(icmp_echo_hdr) + data_size`），设 4000 后 ICMP 数据区 + 8 字节头 + 20 字节 IP 头 = 4028B，远超 MTU。

```text
I (6538) ch9lab: == ping 10.0.2.2 data=4000 count=3 timeout=1500ms ==
...（SLIRP 回程分片陆续抵达）
IP packet is a fragment (id=0x0004 tot_len=1500 len=1500 MF=1 offset=0), calling ip4_reass()
IP packet is a fragment (id=0x0004 tot_len=1500 len=1500 MF=1 offset=1480), calling ip4_reass()
IP packet is a fragment (id=0x0004 tot_len=1068 len=1068 MF=0 offset=2960), calling ip4_reass()
I (6548) ch9lab: 4000 bytes from 10.0.2.2 icmp_seq=1 ttl=255 time=5 ms
I (7438) ch9lab: --- A-big4000 ping statistics: 3 transmitted, 3 received ---
I (13348) ch9lab: [A-big4000] dSTAT ip(recv=9 xmit=3 drop=0 chkerr=0 lenerr=0)
I (13348) ch9lab: [A-big4000] dSTAT ip_frag(frag_out=9 reass_in=9 cachehit=6 DROP=0 MEMERR=0)
I (13348) ch9lab: [A-big4000] dSTAT icmp(rx=3 tx=0 lenerr=0 err=0)
I (13348) ch9lab: [A-big4000] dSTAT etharp(req=0 drop=0) mib2(reasmreqds=9 reasmOK=3 reasmFAIL=0)
```

**解读**——每一个数字都能和 9.2 的公式对上：

- **frag_out=9**：3 个请求 × 每个 ceil((4028−20)/1480)=3 片（1480+1480+1068），出向 `ip4_frag` 干活；
- **reass_in=9 / cachehit=6**：回程 SLIRP 分三组连续 ID（0x0004/05/06）各自镜像成 3 片，每组首片建帐、后两片命中旧帐，cachehit 恰为 2×3；
- **mf_set 证据**：调试行里前两片 `MF=1`、末片 `MF=0` 且 offset 以字节表示实际是 8 字节块粒度（2960=370×8），与 `nfb=185` 的推进步长一致；
- **ip.recv=9 vs icmp.rx=3**：IP 层把 9 个分片各自计了一次 `recv`，只有拼完的 3 张完整报文有资格到达 ICMP——「分片对传输层透明」被计数器演示了一遍。

### 实验 B：TTL 三方对照与代答指纹

**目的**：区分「网关代答」「本地服务代理」「出口转发」三种对面身份。真实 Internet 参照物由宿主机提供：`ping 223.5.5.5` 在主机上显示 `ttl=55 time=18ms`（出门绕 ~9 跳的真实衰减）。

```text
I (13348) ch9lab: == ping 10.0.2.3 data=64 count=2 timeout=1000ms ==
I (13348) ch9lab: 64 bytes from 10.0.2.3 icmp_seq=1 ttl=255 time=3 ms   ← DNS 代理(dhcp 下发的 DNS=10.0.2.3)
I (17148) ch9lab: == ping 223.5.5.5 data=64 count=2 timeout=2000ms ==
I (17158) ch9lab: 64 bytes from 223.5.5.5 icmp_seq=1 ttl=255 time=8 ms  ← 公网地址!
I (17458) ch9lab: 64 bytes from 223.5.5.5 icmp_seq=2 ttl=255 time=9 ms
```

**解读**：三个目标在 guest 视角清一色 ttl=255——包括那台物理上隔着真实互联网的公共 DNS。结合主机侧同目标的 ttl=55，可以钉死结论：**SLIRP 在 NAT 边界用自己的名义重生了所有应答，guest 能测到的 TTL 只反映 SLIRP 的缺省值，不反映真实路径长度**。推论也有实用价值：在这个环境里做 traceroute 类实验（ICMP/UDP TTL 渐增探测）只能观察 guest↔SLIRP 一段的伪象，真实逐跳衰减需要在真机或多跳仿真拓扑里做。（这也是为什么本章没有安排 guest 侧 traceroute：拓扑决定它测不到东西，如实标注。）

### 实验 C：故障注入·重组缓冲压力与「永不完工的数据报」

**目的**：把回程分片打到超过 `IP_REASS_MAX_PBUFS=10`，观察溢出、超时、隔离性与自愈。手段：单发 `data_size=15000` 的 ping（整报文 15028B → 回程同样 11 片），配合三路并发加强版。

```text
I (23948) ch9lab: == ping 10.0.2.2 data=15000 count=1 timeout=3000ms ==
W (23948) opencores.emac: emac_opencores_isr_handler: RX frame dropped (0x14)  ← 驱动层丢帧!
IP packet is a fragment (id=0x000b tot_len=1500 len=1500 MF=1 offset=0), calling ip4_reass()
IP packet is a fragment (id=0x000b tot_len=1500 len=1500 MF=1 offset=1480), calling ip4_reass()
IP packet is a fragment (id=0x000b tot_len=1500 len=1500 MF=1 offset=2960), calling ip4_reass()
IP packet is a fragment (id=0x000b tot_len=1500 len=1500 MF=1 offset=4440), calling ip4_reass()
   ……之后没有任何后续分片抵达（尾部连 MF=0 一起丢了）
W (26948) ch9lab: From 10.0.2.2 icmp_seq=1 TIMEOUT              ← 应用层只能干等
   ……3 秒后（IDF IP_REASS_MAXAGE=3），协议栈自行了断：
icmp_send_response: Sending ICMP type 0B for packet from 10.0.2.2 to 10.0.2.15   ← type 0x0B = Time Exceeded!
I (30748) ch9lab: [C-flood15000-1] dSTAT ip(recv=4 xmit=2 drop=0 chkerr=0 lenerr=0)
I (30748) ch9lab: [C-flood15000-1] dSTAT ip_frag(frag_out=11 reass_in=4 cachehit=3 DROP=0 MEMERR=0)
I (30748) ch9lab: [C-flood15000-1] dSTAT icmp(rx=0 tx=1 lenerr=0 err=0)
I (30748) ch9lab: [C-flood15000-1] dSTAT etharp(req=0 drop=0) mib2(reasmreqds=4 reasmOK=0 reasmFAIL=1)
```

**停摆期间的隔离性**——小包不进重组路径，毫发无损：

```text
I (30748) ch9lab: == ping 10.0.2.2 data=64 count=1 timeout=1000ms ==
I (30748) ch9lab: 64 bytes from 10.0.2.2 icmp_seq=1 ttl=255 time=1 ms    ← 照常通!
```

**三路并发加强版**（12KB ×3，27 片出向、回程 12 片交错扎营）。这波还逮到一个「迟到分片撞上 3 秒大限」的现行：日志里 `icmp_send_response: Sending ICMP type 0B` 混在仍在上报的 `ip4_reass` 分片轨迹中间——某条 datagram 的 MAXAGE 先到，协议栈把它连同已收的几片回收并发出 Time Exceeded；迟到的后续分片落地后另开新帐，新帐到期又补发第二、第三张 TE：

```text
I (39548) ch9lab: == 3 parallel big pings (12000 bytes each) ==
W (39568) opencores.emac: emac_opencores_isr_handler: RX frame dropped (0x14)
IP packet is a fragment (id=0x000e tot_len=1500 len=1500 MF=1 offset=0), calling ip4_reass()
……（0x000e 的 1480/2960 两片略）
IP packet is a fragment (id=0x000f tot_len=1500 len=1500 MF=1 offset=2960), calling ip4_reass()
icmp_send_response: Sending ICMP type 0B for packet from 10.0.2.2 to 10.0.2.15
……（0x000f 的 offset=4440 迟到分片此时仍在扎营）
icmp_send_response: Sending ICMP type 0B for packet from 10.0.2.3 to 10.0.2.15   ← 第二张 Time Exceeded
W (43558) ch9lab: From 10.0.2.2 icmp_seq=1 TIMEOUT
W (43578) ch9lab: From 10.0.2.3 icmp_seq=1 TIMEOUT
I (44368) ch9lab: [C-tri-flood12000] dSTAT ip_frag(frag_out=27 reass_in=12 cachehit=9 DROP=0 MEMERR=0)
I (44368) ch9lab: [C-tri-flood12000] dSTAT icmp(rx=0 tx=3 lenerr=0 err=0)
I (44368) ch9lab: [C-tri-flood12000] dSTAT mib2(reasmreqds=12 reasmOK=0 reasmFAIL=3)
```

**恢复后的回归**：等过 `MAXAGE` 窗口再来一发同规格大包——彻底回收、从零开始、症状完全复刻（再次 11 片出向/4 片进帐/TIMEOUT/TE 一枚），说明重组状态机没有泄漏，缓冲区是被正常回收的不是黑洞：

```text
I (47368) ch9lab: --- C-flood15000-2-recovered ping statistics: 1 transmitted, 0 received ---
I (51168) ch9lab: [C-flood15000-2-recovered] dSTAT ip_frag(frag_out=11 reass_in=4 cachehit=3 DROP=0 MEMERR=0)
I (51168) ch9lab: [C-flood15000-2-recovered] dSTAT mib2(reasmreqds=4 reasmOK=0 reasmFAIL=1)
```

> [!warning] 我们没能触发的路径也要说清楚
> 实验设计初衷是逼出 `(ip_reass_pbufcount + clen) > IP_REASS_MAX_PBUFS` 的溢出逐出分支（`ip_frag.DROP/MEMERR` 抬升）。三次运行该分支计数始终为 0：瓶颈提前到了**驱动层**——回程分片洪峰打爆 openeth 的 RX 描述符环（`RX frame dropped (0x14)`），每波只有前 4 片能走到 `ip4_reass`，`pbufcount` 峰值 4<10，溢出根本轮不到发生。这是教科书级的启示：**重组缓冲耗尽这种极端态，现实里常被更早的瓶颈（DMA 环/队列深度）屏蔽**。要在真机上真正压出 MEMERR，需要更高带宽、更大 RX 环、且让中间路由器只丢部分分片——真机路径留给读者。

### 实验 D：故障注入·网内不可达（ARP 解析失败的静默超时）

**目的**：验证 9.3 说的「lwIP 收差错票冷淡 + 自家 ARP 失败根本无人发差错票」。ping 一个网内不存在的主机 `10.0.2.250`，路由决策命中 en1 直连网段（`ip4_route` 子网匹配成功），下一步就卡在第八章的 ARP 解析上：

```text
I (51168) ch9lab: == ping 10.0.2.250 data=64 count=2 timeout=1000ms ==
etharp_find_entry: found empty entry 2
etharp_request: sending ARP request.
etharp_raw: sending raw ARP packet.
etharp_query: queued packet 0x3ffbaf14 on ARP entry 2     ←  echo request 先排队等着
W (52168) ch9lab: From 10.0.2.250 icmp_seq=1 TIMEOUT
W (53168) ch9lab: From 10.0.2.250 icmp_seq=2 TIMEOUT      ← 两发全超时
I (54968) ch9lab: [D-unreachable] dSTAT ip(recv=0 xmit=2 ...)      ← 一个字节都没回来
I (54968) ch9lab: [D-unreachable] dSTAT icmp(rx=0 tx=0 ...)        ← 没有任何 ICMP 差错票
I (54968) ch9lab: [D-unreachable] dSTAT etharp(req=5 drop=0)       ← 但 ARP 苦苦喊了 5 轮 request
```

**解读**：三层各自的证据完美咬合——IP 层路由一切正常（对同网段目标不需要网关，`xmit=2` 说明 IP 头都盖好了）；ARP 层对不存在的邻居在两个 ping 周期里重发了 5 次 request；链路上无人认领，ICMP 层零进出。按规范剧本，「host unreachable」（`ICMP_DUR_HOST`，type 3 **code 1**）应当由**目标所在网段的路由器**在解析失败时代发——而 10.0.2.0/24 这个网段的「路由器」就是 SLIRP 网关，它选择沉默。于是应用层的体感只能是 `TIMEOUT`——**不可达信息在网络的最底层丢失后，上层无从分辨「不存在」和「慢」**。这也是生产代码坚持超时 + 重试而不是依赖 ICMP 错误反馈的原因。

## 9.7 小结

- `ip4_input()` 四道题：版本/长度/校验三连检（`err/lenerr/chkerr` 各有计数器）→ 目标地址四分类（本机/广播接受、多播查 IGMP 名册、都不是就转发或丢）→ 转发与否（IDF 默认不开，`ip4_forward` 里 TTL 减一 + 增量校验修正是必考题）→ 按 IP_PROTO 编译期 switch 分发，raw PCB 链表享有先摘权。
- 出向分片是 8 字节块的艺术：`nfb=(MTU-20)/8`，MTU 1500 → 每片恰好 1480B；ESP-IDF 因 `LWIP_NETIF_TX_SINGLE_PBUF=1` 走 PBUF_RAM 逐片拷贝路线，放弃零拷贝花活。
- 入向重组靠 `ip_reass_helper` 借 IP 头的 8 字节地皮记账（start/end/next_pbuf）；三元组 src+dst+ID 配对；「见过末片 + 首片在场 + 无缝洞」即完工。
- 缓冲两条底线：`IP_REASS_MAX_PBUFS`（IDF Kconfig 10~100）溢出逐出别家、丢新片不发电报；超时回收 IDF 仅给 **3 秒**（vanilla 15），且只有首片在手才回 `ICMP Time Exceeded (code 1)`。
- ICMP 是 IP 层唯一公开的差错信使，但 lwIP 收到别人的差错票时几乎冷处理——ping 这类应用的可达性判断本质上只能靠超时。echo 应答的代价接近于零：原地翻转 src/dst + 类型 8→0 + 增量补丁校验和。
- ttl=255 的完整解释：SLIRP 的 vhost/DNS 代理代答与 NAT 出口回程都会以自己的名义重生应答，guest 的 TTL 探测止步于 QEMU 进程边界。
- 对照暗线 B：IDF 关掉了 IP_REASSEMBLY 默认值、砍短 MAXAGE、加了 NAPT 挂点和按需定时器——都是「嵌入式资源纪律」对通用堆栈的再裁剪。

Ping 通世界只算入门，真正的日常流量是端口的生意。下一章我们把镜头对准**UDP 与三层 PCB 分层**（raw/netconn/socket 是怎么一层层包出来的）：拆 `udp_input()` 的端口哈希查找与 `udp_bind/udp_connect` 的语义、重现经典的「对关闭端口发 UDP → 收到 ICMP Port Unreachable」并解释为何 connected UDP socket 第二次 sendto 才会吃到 errno，顺便用 Linux nc + hostfwd 打一个真实的 guest↔host 双向 UDP 往返。请听 [[ch10-udp-pcb-layers|第十章：UDP 与 PCB 分层]]。
