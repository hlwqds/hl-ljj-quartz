---
title: "lwIP 深度解析（十二）：TCP 可靠性：滑动窗口、Nagle 与延迟 ACK"
date: 2026-08-26
description: "拆解 lwIP 的 TCP 可靠性机器：tcp_receive 的累计确认与 dupack 五条件、rwnd/cwnd/ssthresh 三重奏（RFC 3465 字节计数慢启动）、sa/sv 到 rto 的 VJ 公式与 tcp_backoff 退避表、ESP_LWIP 的 SYN_RCVD 退避排除补丁、零窗口 persist 探询、tcp_do_output_nagle 五个放行条件与 TF_ACK_DELAY 隔段确认的合谋。附 QEMU 实测：10%/40% 丢包下的重传与退避阶梯、Nagle 扣留时长分布、固定丢包率下 SND_BUF 扫描吞吐曲线。"
tags: [lwip, network, esp32, esp-idf, tcp, congestion, qemu]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 12. **第十二章：TCP 可靠性：滑动窗口、Nagle 与延迟 ACK**

# lwIP 深度解析（十二）：TCP 可靠性：滑动窗口、Nagle 与延迟 ACK

这一章回答三个问题：**包丢了 TCP 怎么知道、多久之后重发**（RTO 的计算、退避与放弃）、**接收方怎么控制发送方的节奏**（rwnd 滑动窗口与 cwnd 拥塞窗口在 lwIP 里各管哪一段）、以及 **Nagle 算法和延迟 ACK 这两个"省资源"机制什么时候变成延迟元凶**。读完它，你应当能对着一条 `tcp_sndbuf` 不回血或一批小消息突然卡 250ms 的现象，在源码里指出具体是哪个字段/标志位在起作用。源码参照：`~/esp/esp-idf/components/lwip/lwip/src`（IDF v6.0.2 捆绑的 lwIP 2.2.0-dev），实验工程 `practice/lwip-ch12-tcp-reliability/` 在 ESP32 + QEMU openeth 上全部实测跑通。

---

## 12.1 三台机器：确认、窗口、定时器

TCP 的可靠性拆开是三台互相咬合的机器：

```text
 ┌─ 确认机（接收方向驱动发送方）──────────────────────────┐
 │ seq/ack 序号空间上的滑动游标：ackno 之前的都收到了      │
 │ 累计确认 + 隔段 ACK（延迟 ACK）+ 第三次重复 ACK 触发    │
 │ 快速重传                                               │
 └──────────────┬───────────────────────────────────────┘
                │ ACK 到达 → snd_buf 回血 → 应用层发送泵重新获得额度
 ┌──────────────▼─ 窗口机（两端各一套）──────────────────┐
 │ 发送侧要同时满足三个闸门，取最小值才是"这一刻能发多少" │
 │   min( snd_buf,        ← 应用写入了多少还没被确认      │
 │       snd_wnd,         ← 对端通告的接收窗口 rwnd        │
 │       cwnd )           ← 自己对网络拥塞程度的估计      │
 └──────────────┬───────────────────────────────────────┘
                │ 都不满足时的兜底
 ┌──────────────▼─ 定时器机（500ms/250ms 两档节拍）──────┐
 │ RTO 超时重传 + 指数退避；persist 零窗口探询；          │
 │ 延迟 ACK 到点补发                                      │
 └────────────────────────────────────────────────────────┘
```

[[2026-08-26-lwip-deep-dive-ch11-tcp-state-machine|第十一章]]讲过 PCB 在状态机里怎么迁移；本章把状态机当作背景，聚焦上面三台机器的数据面。

先给一张字段速查表——它们全在 `struct tcp_pcb` 里（定义于 `src/include/lwip/tcp.h`，应用代码甚至能直接读到，12.7 的采样器就是这么干的）：

| 字段                                | 含义                                     | 单位    |
| ----------------------------------- | ---------------------------------------- | ------- |
| `snd_nxt` / `lastack`               | 下一个待发序号 / 已见最大 ACK            | 字节    |
| `snd_buf`                           | 应用可写的"信用额度"，ACK 回来即回血     | 字节    |
| `snd_wnd` (`snd_wl1/2`)             | 对端通告窗口及更新锚点                   | 字节    |
| `cwnd` / `ssthresh` / `bytes_acked` | 拥塞窗口、慢启动阈值、ABC 计数器         | 字节    |
| `unacked` / `unsent` / `ooseq`      | 已发未确认 / 待发 / 失序缓存三条链表     | 段      |
| `rttest` / `rtseq` / `sa` / `sv`    | RTT 采样中标志、采样段、VJ 均值/偏差估计 | tick    |
| `rto` / `rtime` / `nrtx`            | 当前超时值、计时器、已重传次数           | tick/次 |
| `dupacks`                           | 重复 ACK 计数（快速重传判据）            | 次      |
| `persist_cnt/backoff/probe`         | 零窗口探询计数                           | tick    |

---

## 12.2 确认机：seq/ack 空间上的累计确认

### 1. 序号空间与累计语义

TCP 的序号是 32 位模 $2^{32}$ 回绕的空间，比较必须用回绕安全的宏（`src/include/lwip/priv/tcp_priv.h`）：

```c
#define TCP_SEQ_LT(a,b)     (((u32_t)((u32_t)(a) - (u32_t)(b)) & 0x80000000u) != 0)
#define TCP_SEQ_BETWEEN(a,b,c) (TCP_SEQ_GEQ(a,b) && TCP_SEQ_LEQ(a,c))
```

ACK 是**累计**的：`ackno = N` 表示 N 之前的所有字节都收到。这带来免费的去重和重组语义——乱序段不能前进 `rcv_nxt`，只能进 ooseq 缓存并触发即时重复 ACK；而一旦洞被填上，`tcp_receive()` 会把 ooseq 上连续的段一口气摘下来递给应用。

### 2. tcp_receive() 的 ACK 处理主干

每个携带 ACK 的段都会进入 `tcp_receive()`（`src/core/tcp_in.c`）。处理新数据的分支按顺序做五件事：

```c
} else if (TCP_SEQ_BETWEEN(ackno, pcb->lastack + 1, pcb->snd_nxt)) {
    /* ACK 确认了新数据 */
    if (pcb->flags & TF_INFR) {            /* ① 正在快速恢复？ */
        tcp_clear_flags(pcb, TF_INFR);
        pcb->cwnd = pcb->ssthresh;         /*    NewReno 式收尾 */
        pcb->bytes_acked = 0;
    }
    pcb->nrtx = 0;                         /* ② 重传计数清零 */
    pcb->rto  = (s16_t)((pcb->sa >> 3) + pcb->sv);  /* ③ RTO 回到实测值 */
    acked = (tcpwnd_size_t)(ackno - pcb->lastack);
    pcb->dupacks = 0;                      /* ④ dupack 判定复位 */
    pcb->lastack  = ackno;
    /* ⑤ 拥塞窗口推进（见 12.3），然后摘链表： */
    pcb->unacked = tcp_free_acked_segments(pcb, pcb->unacked, ...);
    pcb->unsent  = tcp_free_acked_segments(pcb, pcb->unsent, ...);
    if (pcb->unacked == NULL) { pcb->rtime = -1; }  /* 无在途数据则停表 */
    else                     { pcb->rtime = 0;  }  /* 否则重新计时 */
    ...
    pcb->snd_buf += recv_acked;            /* ← 第六章发送泵的氧气就来自这里 */
```

最后那行是 [[2026-08-26-lwip-deep-dive-ch6-zero-copy-tcp-write|第六章]] 结论的协议层根据：**`tcp_sent()` 回调里能看到应用泵重新运转，本质是这一行把被确认字节还给了 `snd_buf`**。没有 ACK 流就没有额度，注册 `tcp_sent()` 不是 API 礼仪而是机制本身。

RTO 收尾也值得注意：`rtime = -1` 是"停表"哨兵（无在途数据时 RTO 定时器不跑），有在途数据才置 0 重新数拍子。

另外 ②③ 的位置揭示了 lwIP 的一个取舍：`nrtx=0` 和 `rto=(sa>>3)+sv` 在**任何一个新数据 ACK** 到达时无条件执行——一次成功确认就完全抹掉拥塞怀疑的历史，这与许多教科书的"karn 算法+温和衰减"描述相比更激进，也意味着丢包后每恢复一段就要完整地重新撞墙一次（12.7 实验 a 的锯齿形状由此而来）。

### 3. dupack 的五个判定条件与快速重传

同一函数里，没有确认新数据的 ACK 还要走一遍五条件闸门（源码注释直接引用 Stevens《TCP/IP Illustrated Vol II》p970）：

```c
if (TCP_SEQ_LEQ(ackno, pcb->lastack)) {      /* 条件1：没 ACK 新数据 */
    if (tcplen == 0) {                        /* 条件2：不带数据 */
        if (pcb->snd_wl2 + pcb->snd_wnd == right_wnd_edge) { /* 条件3：窗口没变 */
            if (pcb->rtime >= 0) {            /* 条件4：确有在途未确认数据 */
                if (pcb->lastack == ackno) {  /* 条件5：ACK 号 == 最大已见 */
                    ++pcb->dupacks;
                    if (pcb->dupacks > 3)
                        TCP_WND_INC(pcb->cwnd, pcb->mss);  /* 恢复期膨胀 cwnd */
                    if (pcb->dupacks >= 3)
                        tcp_rexmit_fast(pcb);              /* 第三次：快传！ */
```

五条件缺一不可。条件 4 尤其致命：如果丢了那段之后对端的 dupack 还没回来时本地 RTO 先到点了……不过真正坑的是反过来——**在途数据太少时 dupack 凑不满三个**。SND_BUF=5760、MSS=1440 时最多 4 段在途，丢 1 段最多剩 3 个后续段去触发 dupack，还要求它们都被对端看到；一旦更少就只能等 RTO。这不是理论推演——12.7 实验 a 在默认配置下观测到 `fastrexmit_events≈0`、全程靠 RTO 爬行，就是这个效应。

`tcp_rexmit_fast()`（`src/core/tcp_out.c`）的实现是标准的 NewReno 前半场：

```c
void tcp_rexmit_fast(struct tcp_pcb *pcb)
{
  if (pcb->unacked != NULL && !(pcb->flags & TF_INFR)) {
    if (tcp_rexmit(pcb) == ERR_OK) {
      pcb->ssthresh = LWIP_MIN(pcb->cwnd, pcb->snd_wnd) / 2;
      if (pcb->ssthresh < (2U * pcb->mss))
        pcb->ssthresh = 2 * pcb->mss;            /* 下限 2*MSS */
      pcb->cwnd = pcb->ssthresh + 3 * pcb->mss;  /* 虚拟补偿 3 段 */
      tcp_set_flags(pcb, TF_INFR);
      pcb->rtime = 0;                            /* 防止紧接着的 RTO 抢跑 */
    }
  }
}
```

而 `tcp_rexmit()` 只把 `unacked` 链表的**头一段**搬回 `unsent` 链排队，`MIB2_STATS_INC(mib2.tcpretranssegs)` 在这里记账（注意：只有 MIB2 统计开着才存在这个计数器；IDF 的 Kconfig 没暴露它，12.7 用应用层事件计数替代）；随后 `tcp_output()` 真正发出去。恢复结束在 12.2 第 2 节贴过的 ① 处：下一个确认新数据的 ACK 清 `TF_INFR` 并把 `cwnd` 直接砍到 `ssthresh`——半速滑行离场。

---

## 12.3 窗口机：rwnd、cwnd、ssthresh 三重奏

### 1. 有效发送窗口 = 三者取最小

`tcp_output()` 开头一句话定调（`src/core/tcp_out.c`）：

```c
wnd = LWIP_MIN(pcb->snd_wnd, pcb->cwnd);
```

外加隐性的第三者 `snd_buf`（`tcp_write()` 入口已经用它卡过额度）。所以第一章问题"谁控制节奏"的完整答案分三层：**接收端用 rwnd 控制流量（别撑死我），发送端用 cwnd 控制网络注入量（别堵死路），应用用 snd_buf 控制 API 层的背压（别写爆我）**。嵌入式里最常见的性能事故是把三层混为一谈——调大了 `TCP_WND` 却发现 guest 发送吞吐没变，因为瓶颈在另一层的某个值上。

### 2. rwnd：接收方的心跳

lwIP 对每个进来的字节立即扣减自己的 `rcv_wnd`（`tcp_receive()` 里 `pcb->rcv_wnd -= tcplen;`），但**通告**出去的是另一个影子变量 `rcv_ann_wnd`。真正决定"何时告诉对端我又能收了"的是 `tcp_recved()`（`src/core/tcp.c`，socket 层每次 recv 后调用）：

```c
rcv_wnd = pcb->rcv_wnd + len;              /* 应用吃掉了 len 字节 */
...
pcb->rcv_wnd = rcv_wnd;
wnd_inflation = tcp_update_rcv_ann_wnd(pcb);
/* 右边缘膨胀超过水位线才立刻发显式窗口更新，否则蹭下一次发包 */
if (wnd_inflation >= TCP_WND_UPDATE_THRESHOLD) {
    tcp_ack_now(pcb);
    tcp_output(pcb);
}
```

`TCP_WND_UPDATE_THRESHOLD` 默认 `LWIP_MIN(TCP_WND/4, TCP_MSS*4)`（`opt.h`）。这个"攒够一个量级再播报"的滞后设计跟延迟 ACK 的动机一致：省去专程送一张窗户纸的往返。num-recv-mailbox 有限时（IDF 默认 `CONFIG_LWIP_TCP_RECVMBOX_SIZE=6`），接收邮箱满会造成 rcv_wnd 长期为零，触发的是 12.4 的 persist 探询而非窗劫持死锁——两者机制不同，别混淆。

### 3. cwnd 与 ssthresh：出生、成长、受挫

lwIP 版本的"AIAD/SA 系"实现要点（全部可直接在源码指认）：

| 事件                                                     | 动作                                                                                                                                             | 位置                |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------- |
| `tcp_alloc()` 出生                                       | `cwnd = 1`，`ssthresh = TCP_SND_BUF`（把最大的有效在途当阈值，RFC 5681 建议），`rto/rv = LWIP_TCP_RTO_TIME/TCP_SLOW_INTERVAL`，`rtime=-1`        | `tcp.c`             |
| 握手完成（SYN_SENT→ESTABLISHED 或 SYN_RCVD→ESTABLISHED） | `cwnd = LWIP_TCP_CALC_INITIAL_CWND(mss)` = `MIN(4*mss, MAX(2*mss, 4380))`（RFC 3390 公式；MSS=1440 时得 **4380**）                               | `tcp_in.c`          |
| 新数据 ACK 且 `cwnd < ssthresh`（慢启动）                | RFC 3465 字节计数：`increase = MIN(acked, num_seg*mss)`，其中 `num_seg = (flags & TF_RTO) ? 1 : 2`——非 RTO 恢复期每 ACK 至多涨 2×MSS（L=2\*MSS） | `tcp_receive()`     |
| 新数据 ACK 且 `cwnd >= ssthresh`（拥塞避免）             | `bytes_acked += acked;` 攒到 `>= cwnd` 才 `cwnd += mss` 一格——ABC 的省油模式                                                                     | 同上                |
| 3 次 dupack（快速重传）                                  | `ssthresh = MAX(MIN(cwnd,snd_wnd)/2, 2*mss)`，`cwnd = ssthresh + 3*mss`，置 `TF_INFR`                                                            | `tcp_rexmit_fast()` |
| 快速恢复结束                                             | `cwnd = ssthresh`（乘法减半落地）                                                                                                                | `tcp_receive()`     |
| RTO 到点                                                 | `ssthresh = MAX(MIN(cwnd,snd_wnd)>>1, 2*mss)`，**`cwnd = mss`**（砍到底，不是砍一半！）                                                          | `tcp_slowtmr()`     |

几个容易踩的理解坑：

- **初始 cwnd 不是 1 段**。`tcp_alloc()` 里那个 `cwnd = 1` 只活到握手完成，真实起点由 `LWIP_TCP_CALC_INITIAL_CWND()` 决定（IDF 默认 MSS=1440 → 4380 ≈ 3 段）。
- **慢启动增速上限不是"翻倍"**。教科书说慢启动每 RTT 翻倍，那是"每个 ACK 涨 1 MSS"的近似；lwIP 按 RFC 3465 把每 ACK 的涨幅压到 L=2×MSS，翻倍只在"整窗确认"的理想情况下成立。
- **RTO 后 `cwnd = mss` 而不是 `ssthresh`**。这是最狠的一步：一次超时直接打回起点重新慢启动，配合 `ssthresh` 减半，构成 lwIP 对"网络疑似雪崩"的全部敬畏。

### 4. 把三重奏画在时间轴上（对应 12.7 实验 a 的前奏）

```text
连接建立  cwnd=4380 ssthresh=5760(TCP_SND_BUF)  → 慢启动
若干 ACK  cwnd: 4380 → 5760 → ...               → 撞 ssthresh 转 CA
丢 1 段   后续段到达 → dupack ×(不足3)          → 干瞪眼
RTO 到点  ssthresh=max(min(cwnd,swnd)/2,2880), cwnd=1440
          unacked 整链搬回 unsent 重发           → 重新慢启动
```

默认配置下最多 4 段在途意味着"dupack 凑不满"是常态而非例外——这是 12.7 表格里 10% 丢包吞吐掉到 0.10 Mbit 的第一推动力。

---

## 12.4 定时器机：RTT、RTO、指数退避与零窗口探询

### 1. 从 sa/sv 到 rto：四行 VJ 公式

lwIP 没有 BSD 栈的 SRTT/RTTVAR 名字，用的还是 Van Jacobson 1988 年论文里的整数版记号：`sa` 存 8 倍均值估计、`sv` 存 4 倍平均偏差估计，单位都是 slow timer 的 tick（500ms，`TCP_SLOW_INTERVAL`，可在 Kconfig 里整体改档，见 12.6）。采样在 `tcp_rexmit()` 之后失效（`rttest=0`，Karn's algorithm：重传过的段不测 RTT），正常路径上每测一段就在 `tcp_receive()` 里走这四行：

```c
m = (s16_t)(tcp_ticks - pcb->rttest);     /* 本次 RTT，tick 数 */
m = (s16_t)(m - (pcb->sa >> 3));
pcb->sa = (s16_t)(pcb->sa + m);
if (m < 0) m = (s16_t)-m;
m = (s16_t)(m - (pcb->sv >> 2));
pcb->sv = (s16_t)(pcb->sv + m);
pcb->rto = (s16_t)((pcb->sa >> 3) + pcb->sv);
```

即经典公式 $RTO \leftarrow SRTT + 4\times RTTVAR$ 的定点数化身。所有正值封顶由 `s16_t` 自然承担，负数靠取绝对值吸收。初值方面 `tcp_alloc()` 给 `sv = LWIP_TCP_RTO_TIME/TCP_SLOW_INTERVAL`，所以第一次超时等待就是完整的 `LWIP_TCP_RTO_TIME`。

### 2. 指数退避：一张 13 格的表

每次 RTO 真的触发了，`tcp_slowtmr()`（`src/core/tcp.c`）会按重传次数查 `tcp_backoff[]` 左移放大下次超时：

```c
static const u8_t tcp_backoff[13] = { 1, 2, 3, 4, 5, 6, 7, 7, 7, 7, 7, 7, 7 };
...
if (pcb->rtime >= pcb->rto) {
    u8_t backoff_idx = LWIP_MIN(pcb->nrtx, sizeof(tcp_backoff) - 1);
    int calc_rto = ((pcb->sa >> 3) + pcb->sv) << tcp_backoff[backoff_idx];
    pcb->rto = (s16_t)LWIP_MIN(calc_rto, 0x7FFF);
    pcb->rtime = 0;
    /* 同时砍拥塞窗口（见 12.3 表格最后一行）并 requeue 全部 unacked */
}
```

注意乘数是**左移指数**而不是简单 ×2：查表用的是**本次触发时还没自增的 `nrtx`**。仍以 IDF 默认基值 1500ms（`sv` 初值 3 ticks）计，序列如下——首次超时等 1.5s 发出第 1 次重传，之后每轮按上轮的 `nrtx` 查表放大：

| 触发时 nrtx    | 左移量 `tcp_backoff[nrtx]` | 重传后生效的下一次 RTO |
| -------------- | -------------------------- | ---------------------- |
| 初值（未退避） | —                          | **1500 ms**            |
| 0              | ×2¹                        | 3000 ms                |
| 1              | ×2²                        | 6000 ms                |
| 2              | ×2³                        | 12000 ms               |
| 4              | ×2⁵                        | **48000 ms**           |
| 5              | ×2⁶                        | 96000 ms               |
| ≥6（封顶 7）   | ×2⁷                        | 不再放大               |

放弃条件同样在 `tcp_slowtmr()`：`SYN_SENT` 态重传超过 `TCP_SYNMAXRTX` 次、或数据段重传超过 `TCP_MAXRTX` 次（IDF 默认都是 12），PCB 被拆除并向应用报错。实验 40% 丢包子阶段实测出这条链的真身：`nrtx 4→5 后 rto_ticks=96（~48s），5→6 后 192（~96s）`，两跳之间隔着漫长的静默——§12.7 有原始日志。

**这里埋着 IDF 对 vanilla lwIP 最核心的一处 TCP 补丁**：vanilla 的判断只有 `if (pcb->state != SYN_SENT)`——只要不在主动握手就照常翻倍。ESP-IDF 加了一个态：

```c
#if ESP_LWIP
    if (pcb->state != SYN_SENT && pcb->state != SYN_RCVD) {
#else
    if (pcb->state != SYN_SENT) {
#endif
        u8_t backoff_idx = LWIP_MIN(pcb->nrtx, sizeof(tcp_backoff) - 1);
        int calc_rto = ((pcb->sa >> 3) + pcb->sv) << tcp_backoff[backoff_idx];
        pcb->rto = (s16_t)LWIP_MIN(calc_rto, 0x7FFF);
    }
```

**SYN_RCVD 态也被豁免**：服务端半开连接的 SYN-ACK 重传永远使用固定间隔，不再指数放大。动机很直白——嵌入式设备的 listen 队列是稀缺资源，若客户端发的最后一个 ACK 丢失（常见于弱网尾部丢包），服务端按 vanilla 会以 1.5s/3s/6s… 的间隔吊着半开连接等满 `TCP_SYNMAXRTX` 轮，队列在十几秒内被拖垮；固定短间隔则让这批僵尸更快收敛。同属 `ESP_LWIP` 条件块的还有 ooseq 相关的两处加固（`tcp_in.c` 中失序段裁剪时把 FIN 也计入长度扣减、oo_seq 出队时对超出 `rcv_wnd` 的部分截断），以及 `tcp_alloc()` 在 PCB 枯竭时的追加猎杀名单（FIN_WAIT_2/FIN_WAIT_1 也加入回收候选），后者我们已在第五章内存章节观察过它的效果。

### 3. 零窗口探询（persist）

rwnd 归零且应用迟迟不收时，发送方不能干等对方的窗口更新——那张更新可能永远在路上丢着。lwIP 的解法是 persist 探针表：

```c
static const u8_t tcp_persist_backoff[7] = { 3, 6, 12, 24, 48, 96, 120 };
```

单位同样是 slow timer tick：第 1 次探询等 1.5s，逐级放大到 60s 封顶。探针本体是 `tcp_zero_window_probe()`（`src/core/tcp_out.c`）：借下一个期待字节的 1 字节内容发探询；`snd_wnd==0` 时只发 1 字节探测，非零但装不下整个未发段时用 `tcp_split_unsent_seg()` 把头段切开塞进残余窗口。探询总次数达到 `TCP_MAXRTX` 后 PCB 拆除。整套逻辑入口挂在 `tcp_output()`："下一段放不进窗口 && 无在途数据"即激活 `persist_backoff=1`。

> [!note] 三张定时器表速记
> `tcp_backoff[13]={1..7...}` 管 RTO 退避；`tcp_persist_backoff[7]={3,6,12,24,48,96,120}` 管零窗口探询间隔；`LWIP_TCP_RTO_TIME`（IDF 可配，默认 1500ms）管 RTO 初值。三者的单位都是 tick，一 tick = `TCP_SLOW_INTERVAL` = 500ms（IDF 默认）。

---

## 12.5 Nagle 与延迟 ACK：一对相爱相杀的优化

### 1. Nagle：满一段才发

lwIP 的 Nagle 是 `tcp_priv.h` 里一个纯宏，没有任何隐藏状态：

```c
#define tcp_do_output_nagle(tpcb) ((((tpcb)->unacked == NULL) || \
        ((tpcb)->flags & (TF_NODELAY | TF_INFR)) || \
        (((tpcb)->unsent != NULL) && (((tpcb)->unsent->next != NULL) || \
          ((tpcb)->unsent->len >= (tpcb)->mss))) || \
        ((tcp_sndbuf(tpcb) == 0) || (tcp_sndqueuelen(tpcb) >= TCP_SND_QUEUELEN)) \
        ) ? 1 : 0)
```

读成中文——**以下任一情况允许此刻发送**：

1. 没有任何在途未确认数据（空管发言权）；
2. 用户关了 Nagle（`TF_NODELAY`）或正处于快速恢复（`TF_INFR`，恢复优先）；
3. unsent 链上攒的东西"足够一段"——不止一条段，或头部已 ≥ MSS；
4. 发送缓冲已经满/排满了（内部压力优先于算法洁癖）。

`tcp_output()` 主循环里它握着刹车：`(tcp_do_output_nagle(pcb)==0) && !(TF_NAGLEMEMERR|TF_FIN)` 就 break。注意 `TF_NODELAY` 就是 `TCP_NODELAY` setsockopt 的落点（`sockets.c` 里映射为 `tcp_nagle_disable()/enable()`，raw API 则是同名内联函数，展开皆 `tcp_set_flags(pcb, TF_NODELAY)`）；传说中的 `tcp_nagle_delay` 字段在本版本中不存在，行为完全由 flag + 宏表达。

### 2. 延迟 ACK：隔段才开火

接收方向的省包策略藏在 `tcp_ack()` 这个宏里（`tcp_priv.h`）：

```c
#define tcp_ack(pcb)                               \
  do {                                             \
    if((pcb)->flags & TF_ACK_DELAY) {              \
      tcp_clear_flags(pcb, TF_ACK_DELAY);          \
      tcp_ack_now(pcb);                            /* 第二段来了：立即确认 */\
    }                                              \
    else {                                         \
      tcp_set_flags(pcb, TF_ACK_DELAY);            /* 第一段：先把账挂着 */\
    }                                              \
  } while (0)
```

挂着的账由快速定时器统一清账——`tcp_fasttmr()` 每 `TCP_FAST_INTERVAL`（= `TCP_TMR_INTERVAL`，IDF Kconfig `CONFIG_LWIP_TCP_TMR_INTERVAL` 默认 250ms）扫一遍活动 PCB：

```c
/* send delayed ACKs */
if (pcb->flags & TF_ACK_DELAY) {
    tcp_ack_now(pcb);
    tcp_output(pcb);
    tcp_clear_flags(pcb, TF_ACK_DELAY | TF_ACK_NOW);
}
```

所以 lwIP 的延迟 ACK 没有自适应超时，就是一个硬邦邦的"最坏 250ms，两个周期之间的任意相位"。数据自带捎带（piggyback）豁免权：回程正好有数据要发，ACK 蹭车即走，这也是 echo 类服务几乎从不独立发 ACK 的原因。

### 3. 合谋：为什么会卡出整整齐齐的延迟

把两个机制放在"双写小消息"场景里跑一遍：

```text
应用:   write(A[16B]) ──▶ 输出：A 单独成段飞出（unacked 空，条件1放行）
        write(B[16B]) ──▶ 输出检查：unacked=A，B<MSS，无 NODELAY
                          → B 被 Nagle 扣住，躺在 unsent
接收方:  收到 A，回一个 ACK（假设它心情好立刻回）
发送方:  ACK 落地 → sent 回调/release → B 终于出门
```

如果对方**立刻** ACK，代价只是一次 RTT（微秒~毫秒级，看不出毛病）。但如果对方也在节约资源——Linux 宿主机的 delayed ACK 通常掐 40ms、lwIP 自己掐 250ms——B 就要在 unsent 队列里蹲到对方悠闲地在下一个小消息上捎带 ACK 或定时器到点为止。两条"省资源"曲线叠加，得到教科书级的坏模式：**请求 A、请求 B 连发，服务器应答也小而不及时，客户端表现为每两条卡一发，卡出的时长精确等于对端的 delayed-ACK 周期**（交叉抓包常现 40ms 台阶；对本章环境则是 ≤250ms）。解法向来只有一个维度选边：交互式小消息场景关 Nagle（`setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, ...)`），批量流式场景留着它换更低的包头税。

[[2026-08-26-lwip-deep-dive-ch16-socket-netconn-vfs|第十六章]]会回到 socket 层把这几个开关的位置画全。

---

## 12.6 Vanilla lwIP vs ESP-IDF lwIP 对照

### 1. TCP 可靠性相关 Kconfig 清单（`components/lwip/Kconfig`，拼写均已核对）

| Kconfig                                               | 默认            | 落到 core 宏                | 说明                   |
| ----------------------------------------------------- | --------------- | --------------------------- | ---------------------- |
| `CONFIG_LWIP_TCP_HIGH_SPEED_RETRANSMISSION`           | y               | （组合开关）                | 打开后下面两项换"快挡" |
| `CONFIG_LWIP_TCP_RTO_TIME`                            | y→1500 / n→3000 | `LWIP_TCP_RTO_TIME`         | RTO 初值 ms            |
| `CONFIG_LWIP_TCP_SYNMAXRTX`                           | y→12 / n→6      | `TCP_SYNMAXRTX`             | SYN 放弃次数           |
| `CONFIG_LWIP_TCP_MAXRTX`                              | 12              | `TCP_MAXRTX`                | 数据段放弃次数         |
| `CONFIG_LWIP_TCP_MSS`                                 | 1440            | `TCP_MSS`                   | 上游 opt.h 默认 536    |
| `CONFIG_LWIP_TCP_SND_BUF_DEFAULT`                     | 5760            | `TCP_SND_BUF`               | 上游默认 2×MSS         |
| `CONFIG_LWIP_TCP_WND_DEFAULT`                         | 5760            | `TCP_WND`                   | 上游默认 4×MSS         |
| `CONFIG_LWIP_TCP_RECVMBOX_SIZE`                       | 6               | `DEFAULT_TCP_RECVMBOX_SIZE` | socket 收信箱深度      |
| `CONFIG_LWIP_TCP_QUEUE_OOSEQ`                         | y               | `TCP_QUEUE_OOSEQ`           | 失序缓存               |
| `CONFIG_LWIP_TCP_OOSEQ_TIMEOUT`                       | 6               | `TCP_OOSEQ_TIMEOUT`         | ooseq 养老金 = 6×RTO   |
| `CONFIG_LWIP_TCP_OOSEQ_MAX_PBUFS`                     | 4               | `TCP_OOSEQ_MAX_PBUFS`       | 防 ooseq 吃光 RX       |
| `CONFIG_LWIP_TCP_SACK_OUT`                            | n               | `LWIP_TCP_SACK_OUT`         | 只支持发 SACK          |
| `CONFIG_LWIP_TCP_TMR_INTERVAL`                        | 250             | `TCP_TMR_INTERVAL`          | **快/慢定时器基准拍**  |
| `CONFIG_LWIP_TCP_RCV_SCALE` / `CONFIG_LWIP_WND_SCALE` | 0/n             | `TCP_RCV_SCALE` 等          | 窗口缩放需 SPIRAM 条件 |

映射都在 `components/lwip/port/include/lwipopts.h`。值得单独圈出来的关系是 `TCP_TMR_INTERVAL`：它同时决定 fast timer（延迟 ACK）和 slow timer（=2×拍，RTO/persist）的节拍，改它会整体平移本章所有时间常数。

### 2. 行为差异点（源码可指认）

| 维度                        | Vanilla 2.2.0-dev                   | IDF（`ESP_LWIP` 构建）                                              |
| --------------------------- | ----------------------------------- | ------------------------------------------------------------------- |
| RTO 退避豁免态              | 仅 `SYN_SENT`                       | `SYN_SENT && SYN_RCVD` 都豁免（半开连接固定间隔重试）               |
| 定时器挂载                  | 静态 every500ms 常驻                | `ESP_LWIP_*_TIMERS_ONDEMAND` 家族：无人使用时可卸载（`timeouts.c`） |
| PCB 枯竭时猎杀对象          | CLOSING/LAST_ACK/TIME_WAIT/低优先级 | 追加 FIN_WAIT_2、FIN_WAIT_1                                         |
| ooseq 加固                  | 标准                                | `tcp_in.c` 两处截断补丁（FIN 计入 tcplen；出队超窗截断）            |
| `LWIP_NETIF_TX_SINGLE_PBUF` | 可配                                | 硬编码 1（→ `tcp_write` 强制 COPY，见第六章）                       |
| MIB2 重传计数               | 可开                                | Kconfig 未暴露（tcpretranssegs 编译期不可用）                       |

### 3. 本章相关的坑位清单

- 想观察真实重传计数：开 `CONFIG_LWIP_STATS=y` 只能得到 tcp.xmit/rec/drop 这类总量；retranssegs 拿不到，要么像本章那样事件计数，要么自己给 core 加统计。
- `HIGH_SPEED_RETRANSMISSION` 一键把 RTO 初值减半 + SYN 放弃次数翻倍，弱网真机上它能显著缩短"看起来断线了"的感知，代价是无谓重传变多。
- 关 ooSEQ 省 RAM 的代价在本章语境下很贵：失序段全部丢弃、全部转化为重复 ACK 与重传洪峰，上游注释原话 "at the expense of increased retransmissions"。

---

## 12.7 实验：把机器放进故障台

工程 `practice/lwip-ch12-tcp-reliability/`，基于 ch3 联网模板（openeth bring-up + DHCP），全部实验在同一固件内分四个阶段自动完成：REXMIT-10pct → REXMIT-40pct → NAGLE 两组。raw API 全程经 `tcpip_callback` 进 tcpip_thread（老纪律）。主机端脚本 `host/recv_ch12.py` 提供 bulk（纯计量）与 msg（16B 帧解析）两种模式。

故障注入做法：`install_dropper()` 经 `esp_netif_get_netif_impl()` 拿到 lwip netif，把 `netif->linkoutput` 换成确定性丢帧 wrapper——xorshift32 固定种子（`0x1234abcd`），保证"每次运行丢同一批帧"。三次独立运行 10% 阶段的日志逐字节相同，可作为复现性的证据：

```text
CH12-RTOEV t_ms=10248 / 10246 / 10249   nrtx 0->1 rto_ticks=6 (~3000 ms)   ← 三次运行同位
```

本章全部原始日志已归档在工程 `logs/` 下（`run_ab.log`、`run_40pct_suite.log`、`sweep_guest_*.log` / `sweep_host_*.log`）。

观测手段有两层：

1. 50ms 周期的 `sys_timeout` 采样器直接打印公共结构体里的 PCB 内部字段（`cwnd/ssthresh/rto/nrtx/dupacks/snd_wnd/sndbuf/qlen`）；
2. `nrtx/dupacks` 跨越阈值时打事件行（`CH12-RTOEV`/`CH12-FREV`），应用层累计 RTO 与快传次数。

启动命令（guest 主动连出，无需 hostfwd；ch6 同款方法学）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch12-tcp-reliability
idf.py set-target esp32 && idf.py build
idf.py qemu monitor </dev/null >/dev/null 2>&1   # 生成 build/qemu_flash.bin / qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
python3 host/recv_ch12.py bulk --port 8012 --conns 2 > logs/host_bulk.log &
python3 host/recv_ch12.py msg  --port 8013 --conns 2 > logs/host_msg.log &
timeout 250 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee logs/run_ab.log
```

固件自报家底（CH12-FACT 行，等价于核对了全部关键编译常数）：

```text
CH12-FACT TCP_MSS=1440 TCP_SND_BUF=5760 TCP_WND=5760 TCP_SND_QUEUELEN=16
CH12-FACT LWIP_TCP_RTO_TIME=1500 TCP_FAST_INTERVAL=250 TCP_SLOW_INTERVAL=500 TCP_MAXRTX=12 TCP_SYNMAXRTX=12 TCP_OOSEQ_TIMEOUT=6
```

### 1. 实验 a：10% 随机丢帧下的重传画像

目标 2MB 传输、稳定 10% 帧丢失、100s 截止。代表性日志（起始 200ms 内的状态冻结 + 若干次独立 RTO 事件）：

```text
CH12-PHASE REXMIT-10pct start total=2097152
CH12-DROP t_ms=1382 total=1 len=1494
CH12-DROP t_ms=1384 total=2 len=1494
CH12-T t_ms=48 sb=1440 qlen=3 cwnd=6510 ssthresh=5070 rto=3 nrtx=0 dup=2 swnd=65535
CH12-T t_ms=98 sb=1440 qlen=3 cwnd=6510 ssthresh=5070 rto=3 nrtx=0 dup=2 swnd=65535
...（僵持约 10 秒，唯一变化是 dup 计数）
CH12-RTOEV t_ms=10248 nrtx 0->1 rto_ticks=6 (~3000 ms)
CH12-RTOEV t_ms=34248 nrtx 0->1 rto_ticks=6 (~3000 ms)
CH12-RTOEV t_ms=85249 nrtx 0->1 rto_ticks=6 (~3000 ms)
CH12-RTOEV t_ms=89748 nrtx 0->1 rto_ticks=6 (~3000 ms)
CH12-RTOEV t_ms=97248 nrtx 0->1 rto_ticks=6 (~3000 ms)
CH12-DEADLINE hit at acked=1286944/2097152
CH12-ABORTED acked=1286944/2097152 elapsed_ms=99989 mbit=0.10 rto_events=5 fastrexmit_events=0 dropped_frames=96 err_mem=758
```

解读四连：

1. **dupack 天花板显形**。首采样就有 `dup=2` 停滞——4 段在途丢 1 段，凑不齐第三发 dupack，`fastrexmit_events=0` 全程零快传。恢复只能仰仗 RTO。
2. **RTO 即退避**。每次事件行的 `rto_ticks=6`=3000ms 都是 `((sa>>3)+sv)<<tcp_backoff[0]` 的产物（3 ticks×2¹）：1500ms 初值在首次重传后被翻倍，因为链路上仍有失败历史（nrtx 随后又归零让 12.2 说的"健忘症"生效，下次又从 1500ms 重新爬起）。
3. **锯齿状停滞节奏**。五次 RTO 各自孤悬（10s/34s/85s/89s/97s），期间 `sb=1440 qlen=3` 纹丝不动：发送缓冲被一棵动不了的树占满，应用 `tcp_write` 连续 ERR_MEM（err_mem=758）。
4. **稳态吞吐 0.10 Mbit**：对比第六章实测的 SLIRP 无损天花板 ~115 Mbit，30 秒跌三个数量级——默认参数下的 lwIP 并不打算在丢包网络上优雅生存，它的策略保守且正确（保护网络为先）。

### 2. 实验 a'：40% 重丢包——退避阶梯的极端形态

为了看到 nrtx 连续攀升的阶梯（重传自己也持续被丢），第二阶段把丢帧率提到 40%、体积降到 768KB：

```text
CH12-PHASE REXMIT-40pct start total=786432
CH12-RTOEV t_ms=47   nrtx 0->4 rto_ticks=3 (~1500 ms)
CH12-FREV  t_ms=47   dupacks=5 cwnd=10080 ssthresh=2880
CH12-T    t_ms=97 sb=0 qlen=11 cwnd=10080 ssthresh=2880 rto=3   nrtx=4 dup=5  swnd=65535
CH12-RTOEV t_ms=1498 nrtx 4->5 rto_ticks=96  (~48000 ms)
CH12-RTOEV t_ms=49498 nrtx 5->6 rto_ticks=192 (~96000 ms)
CH12-T    t_ms=49897 sb=0 qlen=11 cwnd=11520 ssthresh=2880 rto=192 nrtx=6 dup=12 swnd=65535
CH12-DEADLINE hit at acked=0/786432
CH12-ABORTED acked=0/786432 ... rto_events=6 fastrexmit_events=1 dropped_frames=15 err_mem=56
```

信息密度极高的一条流水账：开局一串段铺满窗口（cwnd 冲到 10080，慢启动的 ABC 增长），dupack 风暴（dup=5）促成一次真正的快速重传（`FREV`，ssthresh 落到下限 `2*MSS=2880`）；头 50ms 内事件行显示 nrtx 已连跳 4 次——多段接连丢失各自触发独立的重传循环。但被重传的内容自己也进了黑洞，链条转入纯 RTO 世界：`rto_ticks: 3 → 96 → 192`，即理论表里的 1.5s → 48s → 96s。连接实质死亡，110s 截止时 `acked=0`。两点工程结论顺手记下：其一，`dup=12` 还在缓慢增长说明接收端的重复 ACK 引擎本身没坏，死的是重传通道；其二，这种"指数深渊"正是真实协议栈要用 SACK+F-RTO 等手段填的坑，也是嵌入式上"弱网必配 keepalive/应用层心跳"的直接论据。

### 3. 实验 b：Nagle 扣留时长的真身

每组 50 对消息：pair = `write(16B)→write(16B)→单次 output()`，pair 间隔 30ms（确保下一对的 unacked 必然已清空，隔离测量对象）。两组仅差一行代码：实验组构造 PCB 后 `tcp_nagle_disable(pcb)`。指标 `hold_us` 定义为第二条 `tcp_write` 时刻到其首次进入 `sent` 回调（= 被释放出门）的 esp_timer 差值，全 guest 内部时钟、不受主机时钟漂移影响。分布（每组 n=50）：

| 组           | median     | P95    | max    | min    |
| ------------ | ---------- | ------ | ------ | ------ |
| Nagle 默认开 | **238 µs** | 314 µs | 324 µs | 197 µs |
| TF_NODELAY   | 302 µs     | 343 µs | 349 µs | 214 µs |

结论分三层，诚实交代：

1. **在本环境中两组都在亚毫秒级，且几乎没有差别**。原因不是"Nagle 没生效"（扣留发生的证据在源码与流程上无可辩驳：第二条写入时 `unacked!=NULL`、长度 <MSS、`unsent->next==NULL`，四条放行条件全不满足），而是**对端 SLIRP 是即时 ACK 型选手**：held 消息只需等一次 RTT 就被放出，量出来自然≈RTT 而不是 delayed-ACK 周期。
2. 因此这份表的真实教学价值是方法学：**当需要验证 Nagle+delayed-ACK 合谋造成的百毫秒级延迟时，必须控制对端的 ACK 行为**；SLIRP/loopback 环境测不出 40ms/250ms 模式不代表真机上不存在——那类台阶来自 Linux 内核 delayed ACK（典型 40ms）或本栈 `tcp_fasttmr` 的 250ms 清账周期，这两个数值一个在宿主内核里、一个是 `CONFIG_LWIP_TCP_TMR_INTERVAL` 的编译常数。
3. 顺带的反直觉观察：NODELAY 组反而略慢 ~60µs——单 RTT 级别的噪声完全盖过机制差异，顺带演示了"微基准低于噪声底"该怎么解读（看分布，不要看单点）。

> [!tip] 想亲手看到 250ms 台阶？
> 把本工程的接收方向反转即可：让 guest 作为 echo server 接收宿主机 python 的成对小消息，并在收到第一条后 sleep 再应答——guest 端 `TF_ACK_DELAY` 就会在 `CH12` 日志里以 250ms 节拍现身（`tcp_fasttmr` 清账）。`CONFIG_LWIP_TCP_TMR_INTERVAL` 改成 100 可以验证该台阶随编译常数移动。

### 4. 实验 c：固定丢包率下扫描 SND_BUF/WND

SWEEP_ONLY 构建，固定 5% 丢帧、单连接 2MB，SND_BUF 与 WND 同步取 {5760, 11520, 23040, 46080} 四档（示例改法：`sdkconfig.defaults` 中 `CONFIG_LWIP_TCP_SND_BUF_DEFAULT/WND_DEFAULT`，删除 sdkconfig 后重建，一键脚本 `run_sweep.sh`）。每档 95s 截止、只跑一次；guest（esp_timer）与主机（python monotonic）双时钟独立计时，两点间误差 <3ms，方法学互证成立：

| SND_BUF/WND  | TCP_SND_QUEUELEN | 传输结果                       | 耗时(guest/主机 ms) | 稳态吞吐   | RTO 事件             | 快传事件 |
| ------------ | ---------------- | ------------------------------ | ------------------- | ---------- | -------------------- | -------- |
| 5760（默认） | 16               | **95s 截止仅 1272544B（61%）** | >93034 / >93034     | ~0.11 Mbit | （中止，未见汇总行） | —        |
| 11520        | 32               | 完成                           | 91239 / 91241       | 0.18 Mbit  | 9                    | 4        |
| 23040        | 64               | 完成                           | 88243 / 88244       | 0.19 Mbit  | 7                    | 3        |
| 46080        | 128              | 完成                           | 88239 / 88241       | 0.19 Mbit  | 6                    | 2        |

对照第六章的无损参照：同样窗口下纯吞吐早已顶着 SLIRP 天花板 ~115 Mbit，窗口从 5760 加到 28800 都拉不开差距。**有损环境的瓶颈也依旧不在窗口宽度**——RTO 恢复周期的占空比才是第一主角：窗口翻 8 倍只是把 RTO 事件数从 9 压到 6（在途多一点，更容易凑齐 dupack 走快传），稳态吞吐纹丝不动地钉在 0.19 Mbit。这道题的"带宽×时延积账目"结论是：SLIRP 的毫秒级 RTT 下 BDP 只有几百字节量级，默认 5760 早就是超配；决定有损链路成败的是**恢复机制能否避开 RTO 长周期**（靠快传可用的 dupack 数量），而不是能塞进多少字节。真机弱网（RTT 大、BDP 上 MB）结论会倒过来，这是把 QEMU 实验外推时的边界条件。

### 5. 实验遗留事项

- MIB2 的 `tcpretranssegs` 在 IDF 构建里不可用（Kconfig 未暴露 `MIB2_STATS`），本文重传数全部来自应用层事件计数，属采样下界（相邻事件 <50ms 会被合并）。
- 黑窗/白噪声两类注入只作用于 TX 方向；RX 侧失序而非丢失的场景（考验 ooseq 队列）留给读者用同样手法改造 RX 路径复刻。

---

## 12.8 小结

- 可靠性 = 确认机 + 窗口机 + 定时器机。确认机做累计确认与五种条件的 dupack 判定（Stevens 五条件全在 `tcp_receive()`），第三次 dupack 触发 `tcp_rexmit_fast()`；新数据 ACK 一律 `nrtx=0、rto=(sa>>3)+sv、TF_INFR 则 cwnd=ssthresh`，并把确认字节还给 `snd_buf`——第六章发送泵的生存根基。
- 窗口机三层取最小：`snd_buf`（应用背压）、`snd_wnd`（对端 rwnd，`tcp_recved()` 过 `TCP_WND_UPDATE_THRESHOLD` 水位才广播）、`cwnd`（自估拥塞）。lwIP 的 cwnd 实现：初值 RFC 3390（MSS=1440 时 4380），慢启动按 RFC 3465 字节计数每 ACK 最多 +2×MSS，拥塞避免每攒满一个 cwnd 才 +1 MSS，快速重传 ssthresh 减半下限 2×MSS、RTO 则直接 `cwnd=mss` 重新慢启动。
- 定时器机以 500ms tick 为尺：RTT 估计是 VJ 整数四行公式（`sa`=8×均值、`sv`=4×偏差）；RTO 退避查 `tcp_backoff[]={1,2,...7}` 左移放大；放弃门槛 `TCP_MAXRTX/SYNMAXRTX=12`；零窗口走 `tcp_persist_backoff[]={3,6,12,24,48,96,120}` 探询表。**IDF 补丁点：`ESP_LWIP` 让 SYN_RCVD 态同样豁免退避**（vanilla 仅 SYN_SENT），外加 ooseq 两处截断加固与 PCB 猎杀名单扩容。
- Nagle 是一个零状态宏 `tcp_do_output_nagle()`：四个放行条件之外一律憋整段；关闭手段 `TF_NODELAY`（socket 层即 TCP_NODELAY）。延迟 ACK 是隔段确认宏 + `tcp_fasttmr` 的 250ms 硬清账（`CONFIG_LWIP_TCP_TMR_INTERVAL` 可改档）。两者相遇且对端 ACK 慢悠悠时，小消息呈周期性成对卡顿——40ms（Linux）/250ms（lwIP）台阶。
- 实测数字锚点：默认配置 + 10% 丢帧 → 0.10 Mbit，全程零快传、五个孤立 RTO（每次退避到 3s）；40% → 快传一次随即坠入 48s/96s 退避深渊，连接事实死亡；Nagle vs NODELAY 在即时-ACK 对端上均为亚毫秒（median 238µs/302µs），证明该模式的病根在对端 ACK 策略而非本地算法。
- 一句话带走：**嵌入式 TCP 调优不是调大窗口，而是知道你的流量落在"哪些字段组成的最小值"的哪一层；丢了包之后，这套栈的回答永远是保守、指数、且偏袒网络的。**

至此 Part III（TCP 数据面：ch11 状态机 + ch12 可靠性）收官。下一章镜头从协议面拉回架构面：所有这些回调、定时器、采样，究竟跑在哪个线程上？`tcpip_thread` 的邮箱模型如何在一根线程里串起整个协议栈的世界的？我们将解剖 `tcpip_thread()` 主循环、`tcpip_callback`/`sys_mbox_post` 的消息流、以及 API 线程怎么安全地把指令寄进邮箱——也是本系列 Part IV「并发模型」的开幕（详见 [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|第十三章]]）。
