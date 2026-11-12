---
title: "Zig × ESP32-S31 全栈开发（二十一）：TCP 拥塞控制与吞吐"
date: 2026-12-01 18:00:00
description: "从「能连上」到「跑得快」：慢启动与 AIMD 的锯齿、三个重复 ACK 触发的快重传与快恢复、超时重传为什么贵一个数量级、接收窗口与 RFC 7323 窗口缩放、BDP 把「窗口开多大」变成算术题、Nagle 与延迟 ACK 的经典互等、Mathis 吞吐模型与确定性仿真逐点对照，以及本章与 lwIP tcp.c/tcp_out.c 实现的逐行差异。"
tags: [zig, esp32-s31, riscv, tcp, congestion-control, aimd, bdp, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 上一章：[[ch20-tcp-state-machine-reliable-delivery|第二十章：TCP 状态机与可靠传输]]
>
> **本章：第二十一章：TCP 拥塞控制与吞吐**
>
> 下一章：[[ch22-socket-api-event-loop|第二十二章：Socket API 与事件循环]]

# Zig × ESP32-S31 全栈开发（二十一）：TCP 拥塞控制与吞吐

上一章把 TCP 的“可靠性”做完了：序号、确认、重传、乱序重组、FIN/RST。
一个能把字节可靠送达的实现，已经可以叫做 TCP 了——但它跑起来会很难看。
因为**可靠**只回答“别丢”，不回答“发多快”。

这一章只讨论后者：发送端在完全看不到网络内部的情况下，如何推断
“现在能塞多少字节进去”。这个推断机制就是拥塞控制，它由四个部件组成：

| 部件                  | 回答的问题                       | 本章实现                         |
| --------------------- | -------------------------------- | -------------------------------- |
| 拥塞窗口 `cwnd`       | 我能在途多少字节                 | `cong.Cwnd` 的慢启动 / 拥塞避免  |
| 慢启动门限 `ssthresh` | 从“指数试探”切到“线性试探”的分界 | 快重传与超时各减半一次           |
| 重传定时器 `RTO`      | 多久没确认就认为丢了             | `cong.RttEstimator`（RFC 6298）  |
| 接收窗口 `rwnd`       | 对端还能收多少                   | `cong.Cwnd.inFlightLimit()` 取小 |

> [!warning] 本章的证据边界（重要）
>
> 本章**没有真实链路**。ch17 的以太网驱动尚未闭环（DMA 软复位超时、
> MDIO 扫不到 PHY、TX 超时，见 `practice/zig-esp32-s31/logs/ch17d-boot.log`），
> 因此本章不可能、也不允许给出任何“板子吞吐 X KB/s”“ping 通之后跑出
> 多少 Mbit/s”的结论。
>
> 本章的全部数字只有两种来源：
>
> 1. **主机侧确定性仿真**（`src/sim.zig`）：固定链路参数、固定种子、
>    无交叉流量。文中所有 `字节/tick`、`段/RTT`、曲线采样都标注为
>    **仿真数值（非真链路）**；
> 2. **板侧自检的判据读数**（`practice/zig-esp32-s31/logs/ch21-boot.log`）：
>    `checks: passed=10 failed=0 total=10` 与 `main: verdict=pass`。
>    板子跑的是**同一份控制律 + 同一份仿真器**，所以它证明的是
>    “代码在 rv32 上跑得完、结论一致”，不是“链路跑得快”。
>
> 真链路吞吐曲线要等 ch17 闭环后另做一章的实测；把仿真数字写成实测，
> 是这类章节最常见的过度承诺。

---

## 21.1 为什么「能连上」和「跑得快」是两件事

先看一个不需要网络的思维实验。

假设 ch20 的发送端已经完整实现了“可靠传输”，并且它尊重接收窗口：
对端通告 `rwnd = 64 KiB`，它就把 64 KiB 全部塞进网卡。链路是 10 Mbit/s，
中间有一台只带 32 KiB 缓冲的路由器。会发生什么？

```text
t=0ms     发送端：64 KiB 一次性交给网卡（受 rwnd 允许）
t=1..52ms 链路把 64 KiB 以 10 Mbit/s 逐个比特送出去
t=26ms    路由器的 32 KiB 缓冲先满
t=27ms    第 33 KiB 起被路由器**丢弃**
t=52ms    接收端只收到前 32 KiB，回 TCP 的确认只到 32 KiB
t=53ms    发送端：重传后半段 → 再次拥塞 → 丢得更多
```

结论：**可靠传输保证了“最终送达”，但保证不了“网络不被自己压垮”**。
接收窗口 `rwnd` 是接收端的缓冲承诺，它跟路径上任何一台路由器的缓冲
都没有关系。把 `rwnd` 当成发送速率的上限，等于把拥塞的责任推给网络，
而网络只会用丢包来回答。

拥塞控制就是这个回答的解码器：

```text
丢包（或时延上升）  →  网络在告诉我“你发太快了”
                      ↓
                减半窗口（乘法减小）
                      ↓
                慢慢加回去（加法增大）
```

这套“加法增大、乘法减小”（AIMD）之所以能收敛，是因为它在数学上是一个
**公平且稳定**的反馈回路：所有流在拥塞点附近共享带宽时，谁也不会长期
占优，总吞吐也不会振荡到把链路打空。RFC 5681 把它写成了四条规则，
本章的实现就是这四条规则的逐字翻译：

| 规则     | 触发条件          | 动作                             |
| -------- | ----------------- | -------------------------------- |
| 慢启动   | `cwnd < ssthresh` | 每个 ACK 加至多 2 SMSS           |
| 拥塞避免 | `cwnd ≥ ssthresh` | 每个 RTT 加 1 SMSS               |
| 快重传   | 三个重复 ACK      | 立即重传队首，`ssthresh` 减半    |
| 超时     | RTO 到期          | `cwnd = 1 SMSS`，`ssthresh` 减半 |

本章的工程把这些规则做成一个**纯状态机**：输入是“一个 ACK”“一个重复
ACK”“一次超时”，输出是“要不要现在重传”。它没有 socket、没有定时器、
没有网卡寄存器——这正是它能在主机上跑完 20 个用例、又能在 rv32 上原样
跑一遍的原因。

---

## 21.2 慢启动与 AIMD：从 1 段到 29 段的那 14 个 RTT

### 21.2.1 慢启动不是“慢”，是“指数”

慢启动的名字是历史包袱。它的行为是**每收到一个确认就把窗口加一段**：
一个 RTT 内确认多少段，窗口就涨多少段，于是窗口每个 RTT 翻倍。

链路上什么都没有的时候，这是唯一能快速找到“可用带宽”的办法：
从 1 段涨到 1024 段只需要 10 个 RTT。RFC 5681 §3.1 的原文是
“每收到一个确认新数据的 ACK，`cwnd` 增加至多 2 SMSS”，这个 2 的上界
是为了防止**延迟 ACK 批量确认**时一次跳太多——如果对端一个 ACK 确认了
5 段，你不该把窗口加 5 段。

工程的实现（`src/cong.zig`，`onAck()`）：

```zig
if (self.cwnd < self.ssthresh) {
    // 慢启动：每个 ACK 至多补 2 SMSS。段大小为 MSS 时，就是每 ACK +1 MSS，
    // 等价于“每个 RTT 翻倍”。
    self.cwnd += @min(acked, slowStartCap(self.mss));
    self.state = .slow_start;
} else {
    // 拥塞避免：攒够 cwnd 字节的确认才 +1 MSS，即每 RTT +1 MSS。
    self.ca_acked += acked;
    while (self.ca_acked >= self.cwnd) {
        self.ca_acked -= self.cwnd;
        self.cwnd += self.mss;
    }
    self.state = .congestion_avoidance;
}
```

> 源自 `practice/zig-esp32-s31/ch21-tcp-congestion/src/cong.zig` 的 `Cwnd.onAck`。

两个细节值得单独说一句：

1. **窗口内部用字节，不用段数。** 教材里的 `cwnd` 常写成“10 个 MSS”，
   但接收窗口 `rwnd` 天生是字节，取小 `min(cwnd, rwnd)` 必须同单位。
   本章所有窗口字段都是字节，只在打印时用 `mssCount()` 折算。
2. **拥塞避免用字节累加器，不用“每个 ACK 加一点点”。** 后者在整数运算里
   会因为 MSS 不整除而丢误差；累加器攒够一个 `cwnd` 再加 1 MSS，
   在任何一个 MSS 上都是精确的。

### 21.2.2 实测曲线（仿真）

仿真参数（`sim.Params` 的默认值）：MSS 1460、链路 10 Mbit/s
（1250 字节/tick，1 tick = 1 ms）、单程时延 12 tick（RTT = 24 ms）、
接收窗口 64 KiB、初始 `ssthresh` 32 KiB、总传输量 256 KiB、不丢包。

每个 RTT 采一次 `cwnd`，单位是 MSS：

| RTT          | 0   | 1   | 2   | 3   | 4   | 5   | 6   | 7   | 8   | 9   | 10  | 11  | 12  | 13  |
| ------------ | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `cwnd`（段） | 1   | 1   | 2   | 4   | 8   | 16  | 23  | 24  | 25  | 26  | 26  | 27  | 28  | 29  |

原始采样行（板侧日志原文，见 21.9）：

```text
sim: cwnd none@1rtt n=14 [1,1,2,4,8,16,23,24,25,26,26,27,28,29]
```

判读这条曲线的四段：

1. **RTT 0 与 1 都是 1**：第一个段刚发出去，它的 ACK 还没回来。
   采样点打在 RTT 边界上，所以“窗口没动”不代表“慢启动没工作”。
2. **RTT 2 → 5 是 2、4、8、16**：标准翻倍。这就是慢启动。
3. **RTT 6 的 23 不是 32**：`ssthresh = 32 KiB = 22.44 MSS`。窗口在
   这一 RTT 内从 16 往上涨，涨到 23 段时越过了 `ssthresh`，剩下的 ACK
   走拥塞避免。**切换发生在 RTT 内部，采样只能看到结果**。
4. **RTT 6 之后每 RTT +1**：24、25、26…… 最后停在 29 段
   （42.3 KiB），逼近但没到 BDP（10 Mbit/s × 24 ms = 30 KB ≈ 21 段）。

等一下：29 段已经 **超过** BDP 的 21 段了，为什么还能跑？
因为 29 段 ≈ 42 KiB，其中只有约 21 段“在链路上”，其余在队列里。
不丢包是因为这条仿真链路**没有队列上限**——这是模型的一个明确简化
（见 21.7 的“模型边界”）。真实链路的队列会溢出，溢出的那一刻就是丢包，
也就是 21.3 的入口。

> [!note] 为什么从 1 段起步，而不是 RFC 6928 的 10 段
> 现代实现（Linux、lwIP 的 `TCP_INITIAL_WND` 可配）初始窗口是 10 MSS，
> 直接把 10 段塞进第一个 RTT。本章从 1 段起步是**为了把翻倍曲线画出来**：
> 1→2→4→8 是判据 ① 的字面要求，也是读者最容易手工验证的一段。
> 生产实现用 IW10 的理由很实在：省掉 3 个 RTT 的爬坡，
> 而 10 段（≈14.6 KB）在今天的链路上很难造成拥塞。

### 21.2.3 慢启动什么时候结束：`ssthresh` 是唯一的刹车

`ssthresh` 的初值有两种常见取法：

| 取法                          | 出处               | 后果                     |
| ----------------------------- | ------------------ | ------------------------ |
| “任意大”（如 64 KiB）         | RFC 5681 §3.1 建议 | 慢启动一直涨到丢包才停   |
| 等于发送缓冲（`TCP_SND_BUF`） | lwIP `tcp.c:1955`  | 涨到“能发满缓冲”就转线性 |

lwIP 选后者，并在注释里给了理由：**开启窗口缩放/自动调优的对端，
初始通告窗口可能很小，随后迅速变大**；如果 `ssthresh` 取“最大通告窗口”，
慢启动会在窗口变大之前就结束，白白丢掉一段指数增长。把 `ssthresh`
钉在“发送端最多能在途多少”（`TCP_SND_BUF`）上，行为与缓冲大小对齐，
不会受对端通告窗口的临时变化影响。

本章的仿真选的是中间路线：`ssthresh = 32 KiB`，比 BDP（30 KB）
略大一点。这样曲线里能同时看到“指数段”和“线性段”，判据 ① 与 ②
可以在同一条链路上分别验证。

---

## 21.3 快重传与快恢复：三个重复 ACK 值多少钱

### 21.3.1 重复 ACK 是“洞”的指纹

接收端的确认是**累积**的：收到 1000 就回 `ack=1001`。如果 1001 那一段
丢了，后面 1001+1460、1001+2920… 陆续到达，接收端只能一遍遍回
`ack=1001`。这些“不确认新数据、不带载荷、窗口没变”的 ACK 就是重复 ACK。

一个重复 ACK 说明“我收到了乱序数据”；**三个**重复 ACK 说明“乱序数据已经
连续来了三段，这个洞大概率不是重排序，是真丢了”。RFC 5681 §3.2 就把它
当成重传信号，不必等 RTO：

```text
接收端视角：  [1001..2460]  [2461..3920]  [3921..5380]  [5381..6840]
              丢           三份重复 ACK  第四份        第五份
              ack=1001      ack=1001      ack=1001      ack=1001
                            ↑ 第 3 个到这里 → 发送端立即重传 1001
```

工程里的判据就在 `onDupAck()`：

```zig
pub fn onDupAck(self: *Cwnd, rwnd_bytes: u32) Action {
    self.dupacks_total += 1;
    if (self.dupacks < 255) self.dupacks += 1;

    if (self.dupacks == 3) {
        const flight = self.inFlightLimit(rwnd_bytes);
        self.ssthresh = halfWindow(flight, self.mss);
        self.cwnd = self.ssthresh + 3 * self.mss;
        self.state = .fast_recovery;
        self.fast_retx += 1;
        return .retransmit_now;
    }
    if (self.dupacks > 3 and self.state == .fast_recovery) {
        self.cwnd += self.mss;
    }
    return .none;
}
```

> 源自 `src/cong.zig` 的 `Cwnd.onDupAck`。

三件事同时发生，缺一不可：

1. `ssthresh` 减半（乘法减小）；
2. `cwnd` 被设成 `ssthresh + 3 MSS`——这是**临时膨胀**，
   代表“已经离开网络的那三段”（它们确实到了接收端，只是不能确认）；
3. 立刻重传队首，不等定时器。

板侧判据 ③ 的读数（`cwnd` 从 10 段开始）：

```text
check: fast retx ssthresh=7300 cwnd=11680 state=fast_recovery ok=1
```

`7300 = 5 × 1460`，`11680 = 5 × 1460 + 3 × 1460 = 8 × 1460`。
与 RFC 5681 §3.2 的公式逐字对齐。

### 21.3.2 快恢复：为什么不是直接退到 `ssthresh`

如果收到三个重复 ACK 就把 `cwnd` 打回 `ssthresh`，会发生什么？
那个洞被重传、对端回一个“确认到洞末尾”的 ACK，发送端立刻发现
“我在途的数据还很多”，于是又要重新爬坡。结果是每丢一个包就掉进一次
慢启动——吞吐被打成锯齿，而且锯齿的下沿是 1 MSS。

快恢复的思路：**洞被填上时，网络里其实还有 `ssthresh` 那么多未确认数据**
（因为重复 ACK 证明它们都到了），所以窗口不该回到 1，而该回到
“减半后的窗口”。那段临时膨胀的 3 MSS 只是让发送端在等待重传 ACK 的
一个 RTT 里不至于空转；一旦新 ACK 到达（证明洞填上了），就做 **deflate**：

```zig
if (self.state == .fast_recovery) {
    // Reno 的 deflate：确认了重传的那个洞，窗口退回到减半后的 ssthresh。
    self.cwnd = self.ssthresh;
    self.state = .congestion_avoidance;
    self.ca_acked = 0;
    return;
}
```

> 源自 `src/cong.zig` 的 `Cwnd.onAck` 开头。

### 21.3.3 Reno 与 NewReno：一句话的差别

- **Reno**：一个窗口里丢一个包，快重传 + 快恢复处理得很好。
  一个窗口里丢**多个**包时，只重传第一个洞；第二个洞要等第一个洞的 ACK
  回来以后才能被发现——而那个 ACK 是“部分确认”，Reno 会把它当成
  “恢复结束”，窗口立刻退到 `ssthresh`，剩下的洞只能等 RTO。
- **NewReno**（RFC 6582）：把“部分确认”单独处理——只要 ACK 没有覆盖
  到进入恢复时的最高序号，就认为“还有洞”，立刻重传下一个洞并**留在
  快恢复里**。差别只有一条：**Reno 用一个 ACK 结束恢复，NewReno 用全部
  洞填完才结束**。

本章实现的是 Reno（判据 ③④ 的语义都按 Reno 写），lwIP 也是 Reno
（`tcp_in.c` 用 `TF_INFR` 标志表示“在快恢复里”，见 21.10 的对照表）。
这一点在仿真的 k=10（10% 丢包）那一组里能看到代价：18 次重传里有
2 次是超时——窗口里同时丢了多个洞，Reno 只能靠 RTO 兜底。

### 21.3.4 丢包后的曲线（仿真）

同一组链路参数，周期丢包“每 100 个发出的段丢 1 个”（p = 1%）：

| RTT          | 0   | 1   | 2   | 3   | 4   | 5   | 6   | 7   | 8   | 9   | 10  | 11  | 12  | 13  | 14  |
| ------------ | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `cwnd`（段） | 1   | 1   | 2   | 4   | 8   | 16  | 23  | 24  | 25  | 26  | 29  | 13  | 14  | 15  | 16  |

```text
sim: cwnd loss1/100 n=15 [1,1,2,4,8,16,23,24,25,26,29,13,14,15,16]
sim: k100 ramp sent=180 retx=1 to=0 fr=1 dup=23 ticks=346
```

读法：

- 前 10 个 RTT 与本 21.2 的无丢包曲线**完全一致**——1% 的丢包在
  180 个段里只命中一次，爬坡阶段还没轮到它；
- RTT 10 是 29 段的高点，RTT 11 掉到 13 段：快重传发生，`ssthresh` 减半、
  `cwnd` 膨胀 3 段、随后 deflate。**注意 13 不是 29/2 = 14.5 的取整**——
  快重传用的是“第 3 个重复 ACK 到达那一刻的 `cwnd`”，它与采样点相差
  一个 RTT，中间可能已经发生过增长。想验证减半公式，必须像判据 ③ 那样
  **逐事件**驱动状态机，而不是看曲线猜；
- RTT 11 之后恢复成每 RTT +1：13、14、15、16。这就是拥塞避免的斜率，
  也是“锯齿”的上升沿。

这条曲线解释了“为什么 1% 丢包不等于 1% 吞吐损失”：一次丢包只让窗口
减半，而窗口是“在途字节”的上限，吞吐 ≈ 窗口 / RTT。这次运行的账是：

| 运行                | tick 数 | 有效吞吐（字节/tick） | 丢包事件 |
| ------------------- | ------: | --------------------: | -------: |
| 无丢包              |     315 |                 832.2 |        0 |
| 1%（每 100 段丢 1） |     346 |                 757.6 |        1 |

**代价是 +31 tick（+9.8%）**，不是“每丢一个包就慢一倍”。因为这一次丢包
发生在传输的后段（第 10 个 RTT，总共 13 个 RTT），窗口掉到 13 段之后
只剩三个 RTT 需要爬。换句话说：**同样一次丢包，发生在长传输的开头，
代价远大于发生在结尾**——这解释了为什么短连接对丢包更敏感，
而长连接能“摊平”偶发丢包。

但也要看清另一面：180 段的传输里只有 1 次丢包事件，**根本没有形成
“锯齿”**，只是一段爬坡加一次减半。要用仿真验证稳态模型，
传输量必须足够大——21.7 会先给你看“看起来吻合”的短运行，再拆穿它。

---

## 21.4 超时重传的代价与 RTO 的关系

### 21.4.1 一次超时 ≈ 一次慢启动重来

超时是拥塞控制里最贵的信号，因为它的语义是“**连重复 ACK 都没来**”：
要么整窗全丢，要么 ACK 全丢，要么路径断了。RFC 5681 §3.1 的处理是：

```zig
pub fn onTimeout(self: *Cwnd, rwnd_bytes: u32) void {
    const flight = self.inFlightLimit(rwnd_bytes);
    self.ssthresh = halfWindow(flight, self.mss);
    self.cwnd = self.mss;      // 不是减半，是直接 1 MSS
    self.state = .slow_start;
    self.dupacks = 0;
    self.ca_acked = 0;
    self.timeouts += 1;
}
```

> 源自 `src/cong.zig` 的 `Cwnd.onTimeout`。

与快重传的区别只有两处，但后果差一个数量级：

|            | 快重传               | 超时                           |
| ---------- | -------------------- | ------------------------------ |
| `ssthresh` | 减半                 | 减半                           |
| `cwnd`     | `ssthresh + 3 MSS`   | **1 MSS**                      |
| 重传范围   | 只重传队首           | 整窗（实现上通常是 go-back-N） |
| 恢复时间   | 约 1 个 RTT 回到半窗 | 从 1 段重新指数爬              |

仿真里 k=10（10% 丢包）那一组同时出现了两种恢复：16 次快重传、
2 次超时。2 次超时看起来不多，但每次超时按默认 RTO 200 tick 算，
就是 400 tick——占这次传输 2010 tick 的 **20%**。这就是“超时很贵”的
定量含义。

### 21.4.2 RTO 从哪来：RFC 6298 的四个寄存器

RTO 不能拍脑袋。太短会导致**伪重传**（包没丢，你自己重发，把网络搞得更
拥塞）；太长则丢包后干等。RFC 6298 §2 给了四步：

```text
第一次测量：  SRTT = R                 RTTVAR = R/2
之后的测量：  RTTVAR = 3/4·RTTVAR + 1/4·|SRTT - R|      （先用旧 SRTT）
              SRTT   = 7/8·SRTT   + 1/8·R
              RTO    = SRTT + max(G, 4·RTTVAR)
超时一次：    RTO    = min(2·RTO, 60s)                  （指数退避）
确认新数据：  RTO    = SRTT + max(G, 4·RTTVAR)           （清退避）
```

工程实现（整数微秒，无浮点）：

```zig
pub fn sample(self: *RttEstimator, rtt_us: u32) void {
    if (self.samples == 0) {
        self.srtt_us = rtt_us;
        self.rttvar_us = rtt_us / 2;
    } else {
        const delta = if (rtt_us > self.srtt_us) rtt_us - self.srtt_us else self.srtt_us - rtt_us;
        self.rttvar_us = (3 * self.rttvar_us + delta) / 4;
        self.srtt_us = (7 * self.srtt_us + rtt_us) / 8;
    }
    self.samples += 1;
    const var_term = @max(self.clock_granularity_us, 4 * self.rttvar_us);
    const rto = self.srtt_us + var_term;
    self.rto_us = std.math.clamp(rto, min_rto_us, max_rto_us);
}
```

> 源自 `src/cong.zig` 的 `RttEstimator.sample`。

三个容易写错的地方：

1. **必须先算 `RTTVAR` 再更新 `SRTT`**。公式里的 `|SRTT - R|` 是
   “当前样本与**旧**平滑值”的偏差；先更新 `SRTT` 会让偏差被你自己抹平，
   RTO 变得对抖动不敏感（局域网里看不出问题，一旦跨公网就频繁伪重传）。
2. **`max(G, 4·RTTVAR)` 里的 G 不能省**。G 是时钟粒度（取 1 ms 或
   “测量的最小分辨率”）。链路的 RTTVAR 可能只有几十微秒，
   `4·RTTVAR` 远小于 tick 精度，RTO 会缩到 0——那等于每次 ACK 还没回来
   就重传。
3. **下界是策略，不是公式**。RFC 6298 要求下限 1 s；Linux 用 200 ms
   （`TCP_RTO_MIN`），因为现代局域网 RTT 只有几百微秒，1 s 的下界会让
   快速重传之外的丢包恢复慢得离谱。本章的 `min_rto_us = 200_000`
   跟随 Linux，并在测试里钉住了这个值：

```text
check: timeout cwnd=1460 ssthresh=11680 ok=1
```

（`ssthresh = 16 MSS / 2 = 8 MSS = 11680 B`，`cwnd` 回 1 MSS = 1460 B。）

### 21.4.3 退避表：为什么是 3 s、6 s、12 s

lwIP 的慢定时器是 500 ms 一跳（`tcp_priv.h:125`：
`TCP_SLOW_INTERVAL = 2 * TCP_TMR_INTERVAL = 500 ms`），RTO 的初值是
**3000 ms = 6 跳**（`opt.h:1384` 的 `LWIP_TCP_RTO_TIME` 与
`tcp.c:1942` 的 `pcb->rto = LWIP_TCP_RTO_TIME / TCP_SLOW_INTERVAL`）。
每次超时按 `tcp_backoff[13] = {1,2,3,4,5,6,7,7,7,...}` 的倍数放大再取小
（`tcp.c:163`）。合起来就是 3 s、6 s、9 s、12 s…… 封顶 21 s。

不是 3、6、12、24 的原因很实在：lwIP 的退避是**加性到乘性的混合**，
前几次用线性倍数，避免“第二次超时就等到 12 s”把连接卡死；
7 次以后固定 7 倍（21 s），再等下去 LAN 场景已经没有意义。
对比 RFC 6298 的 `2·RTO`（3、6、12、24…），lwIP 更早封顶。

本章的估算器用 RFC 6298 的 `2·RTO` 与 60 s 上限，因为它要跨公网；
板侧自检只验证公式，不验证 lwIP 的常量。

---

## 21.5 接收窗口、窗口缩放与 BDP

### 21.5.1 两个窗口，取小

发送端能在途的字节数是 `min(cwnd, rwnd)`，没有第二种解释：

```zig
pub fn inFlightLimit(self: Cwnd, rwnd_bytes: u32) u32 {
    return @min(self.cwnd, rwnd_bytes);
}
```

> 源自 `src/cong.zig` 的 `Cwnd.inFlightLimit`。

板侧判据 ⑤：

```text
check: window min(cwnd=14600,rwnd=5840)=5840 ok=1
```

这一行同时钉住两件事：`min` 是真的取小（不是取大、不是相加）；
单位是字节（14600 = 10 MSS，5840 = 4 MSS）。

### 21.5.2 `cwnd` 可以超过 `rwnd`，但在途字节不能

仿真里有一个容易误读的现象：把接收窗口压到 8 MSS 之后，`cwnd` 的采样
峰值仍然能到 29 段。这不是 bug：

- `cwnd` 是**拥塞窗口**，它反映“网络看起来能承受多少”，与接收端无关；
- 真正限制发送的是 `min(cwnd, rwnd)`，所以在途字节永远不会超过 8 MSS；
- 因为不丢包，`cwnd` 的慢启动会一直涨（没有丢包信号就不减速），
  而它涨到多大都不影响事实上的发送速率。

所以判据不能写“`cwnd` 峰值 ≤ 8”，只能写“吞吐 ≤ rwnd/RTT”。
这是本章主机侧用例里刻意保留的一条注释：

```text
// 上界：8 段 / 24 tick = 486.7 字节/tick。cwnd 会自己涨过 rwnd，
// 所以在途字节才是判据，不是 cwnd 的采样值。
```

仿真实测（256 KiB 传输）：

| 接收窗口          | 吞吐（字节/tick） | 理论上界 = rwnd / RTT      |
| ----------------- | ----------------- | -------------------------- |
| 64 KiB            | 832.2             | 2730.7（受链路 1250 限制） |
| 8 MSS（11.7 KiB） | 434.0             | 486.7                      |

第二条正是“窗口成了瓶颈”：实际吞吐 434 略低于上界 487，
差的 10% 是慢启动爬坡与 ACK 往返的启动代价。

### 21.5.3 16 位窗口字段与 RFC 7323

TCP 首部里的窗口字段只有 16 位，最大 65535 字节。在 10 Mbit/s、
24 ms RTT 的链路上，这个值刚好够用（BDP = 30 KB）。一旦链路升级：

| 链路       | RTT    | BDP     | 65535 字节够吗               |
| ---------- | ------ | ------- | ---------------------------- |
| 10 Mbit/s  | 24 ms  | 30 KB   | 够                           |
| 100 Mbit/s | 24 ms  | 300 KB  | **不够，只能跑 21.8 Mbit/s** |
| 1 Gbit/s   | 24 ms  | 3 MB    | 差 46 倍                     |
| 1 Gbit/s   | 100 ms | 12.5 MB | 差 190 倍                    |

窗口缩放（RFC 7323）在三次握手时协商一个 shift，之后所有窗口字段都表示
“真实窗口 >> shift”。上限是 **14**：

```text
65535 << 14 = 1,073,725,440 字节 ≈ 1 GiB
```

板侧判据 ⑥ 就把这三个数钉在一行里：

```text
check: wscale shift=14 encode(1MiB)=64 decode=1048576 max=1073725440 ok=1
```

逐项读：

- 对方 SYN 里给的 shift 是 15，`clampWscale` 必须当 14 处理
  （RFC 7323 §2.2 的原文要求；lwIP 在 `tcp_in.c:2020-2022` 里也是这么干的）；
- `encodeWnd(1 MiB, 14)` = 64：真实窗口放回报文要**右移并向下取整**，
  1 MiB >> 14 = 64；
- `decode(64, 14)` = 1048576：64 << 14 正好回到 1 MiB；
- `wndFieldMax(14)` = 0x3FFFC000 = 1073725440：这是 16 位字段在该 shift 下的极限。

两条边界必须写死在代码里，否则线上会出现“窗口看起来很大、实际发不出去”
的诡异现象：

1. **shift > 14 一律按 14**（不是按对方给的值截断到 16 位——那会溢出）；
2. **编码向下取整**，不能向上取整：向上取整等于通告一个自己不打算兑现的
   窗口，对端按它发送，你只能丢包。

### 21.5.4 BDP 是“窗口至少要多大”的答案

```zig
pub fn bdpBytes(bits_per_sec: u64, rtt_us: u32) u32 {
    const bytes_per_sec = bits_per_sec / 8;
    const bdp = bytes_per_sec * @as(u64, rtt_us) / 1_000_000;
    return @intCast(@min(bdp, std.math.maxInt(u32)));
}
```

> 源自 `src/cong.zig` 的 `bdpBytes`。

板侧判据 ⑨：

```text
check: bdp 10mbit/24ms = 30000B 21seg rwnd_needed=30660 ok=1
```

`10 Mbit/s ÷ 8 × 0.024 s = 30 000 字节`；按 1460 向上取整是 21 段；
`windowForBdp()` 返回 21 × 1460 = 30660，比 BDP 略大，
因为窗口只能是段的整数倍。

BDP 的用处是把“要不要调窗口”从感觉变成算术：**如果
`min(rwnd, cwnd) < BDP`，链路一定跑不满**，而且这不是算法问题，
是配置问题。这一条在 ESP-IDF 上的现实意义极大：

ESP-IDF 的 lwIP 默认接收窗口与发送缓冲都是 **5760 字节**
（`components/lwip/Kconfig:682` 与 `:699`，默认 `4 * 1440`）。
在 24 ms RTT 的链路上，窗口上限决定了吞吐上限：

```text
5760 B / 0.024 s = 240 000 B/s ≈ 1.92 Mbit/s
```

也就是说：**默认配置下，即使网卡跑千兆、链路空着，TCP 单流也只有
不到 2 Mbit/s**。这不是 bug，是 BDP 的算术后果。想跑满，必须同时改
`LWIP_TCP_WND_DEFAULT` / `LWIP_TCP_SND_BUF_DEFAULT`，并确认
`LWIP_WND_SCALE` 打开（默认关闭时窗口字段只有 16 位）。

> [!tip] 一条可操作的检查顺序
>
> 1. 算 BDP：`带宽(字节/秒) × RTT(秒)`；
> 2. 看 `LWIP_TCP_WND_DEFAULT` 与 `LWIP_TCP_SND_BUF_DEFAULT` 是否 ≥ BDP；
> 3. 若 BDP > 65535，确认 `LWIP_WND_SCALE=1` 且对端也支持；
> 4. 最后才怀疑拥塞控制算法本身。

---

## 21.6 Nagle 与延迟 ACK 的经典互等

### 21.6.1 两个“为了省”的优化

- **Nagle（RFC 896）**：不要发小段。规则是“**没有未确认数据时才允许发
  小段**”，效果是“在途最多一个小段”。目的是减少 41 字节首部只为
  1 字节载荷的浪费。
- **延迟 ACK（RFC 1122 §4.2.3.2）**：不要每收一个段就回一个 ACK。
  等第二个段到了再一起确认，或者最多等 200 ms（推荐值 500 ms 上限）。
  目的是减少反向路径的小包。

单独看都很合理。叠在一起就是死锁：

```text
发送端（Nagle）：  有一个小段在途未确认 → 等 ACK 才发下一段
接收端（延迟 ACK）：只有一个段到了        → 等第二个段才发 ACK
                    ↓
        发送端等 ACK 最多 200 ms；接收端等数据最多 200 ms
                    ↓
        每一个 request/response 的往返都多出 40 ms ~ 200 ms
```

这就是为什么“telnet 打字卡”“HTTP/1.0 短连接慢”“Redis 小命令延迟高”
这些老问题都指向同一个开关：`TCP_NODELAY`。

### 21.6.2 判据怎么写

Nagle 的规则可以压成三个条件（`src/cong.zig`）：

```zig
pub fn nagleAllows(unacked_bytes: u32, pending_bytes: u32, mss: u32, nodelay: bool) bool {
    if (nodelay) return true;
    if (unacked_bytes == 0) return true;
    // 够一整段就可以发：Nagle 只压“小段”，不压满段。
    return pending_bytes >= mss;
}
```

板侧判据 ⑦：

```text
check: nagle unacked=1 small=blocked full=allowed idle=allowed ok=1
```

三行合一行，分别对应：

1. `unacked=1460, pending=100` → **blocked**：在途有数据、待发是小段 →
   压住（这就是那个会互等的场景）；
2. `pending=1460` → **allowed**：满段不受 Nagle 限制（Nagle 只压小段）；
3. `unacked=0` → **allowed**：没有在途数据，小段立刻发。

lwIP 的判据是同一个逻辑，但多了一个“例外”和一个“更多”：

```c
#define tcp_do_output_nagle(tpcb) ((((tpcb)->unacked == NULL) || \
                            ((tpcb)->flags & (TF_NODELAY | TF_INFR)) || \
                            (((tpcb)->unsent != NULL) && (((tpcb)->unsent->next != NULL) || \
                              ((tpcb)->unsent->len >= (tpcb)->mss))) || \
                            ((tcp_sndbuf(tpcb) == 0) || (tcp_sndqueuelen(tpcb) >= TCP_SND_QUEUELEN)) \
                            ) ? 1 : 0)
```

> 源自 `~/esp/esp-idf/components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:100-105`。

多出来的两项很实用：

- **`TF_INFR`（在快恢复里）**：快重传期间不能再压小段，否则重传窗口
  里的小段会被 Nagle 卡住，恢复更慢；
- **发送缓冲满 / 队列满**：此时“压住”没有意义（反正也发不出去），
  让上层尽快拿到 `ERR_MEM` 反而更好。

### 21.6.3 什么时候该关

| 场景                                      | 建议                     | 理由                                             |
| ----------------------------------------- | ------------------------ | ------------------------------------------------ |
| 请求/响应型协议（Redis 命令、Modbus/TCP） | `TCP_NODELAY` 打开       | 应用本身就是“一问一答”，Nagle 只会拖延迟         |
| 大块传输（文件、OTA）                     | 保持 Nagle               | 数据天然是满段，Nagle 不会触发；关掉只会增加小包 |
| 实时控制（本系列后续的 socket 章节）      | 打开，并自己控制写入节奏 | 延迟可预测比省首部重要                           |

一句话记法：**Nagle 优化的是“首部开销”，延迟 ACK 优化的是“ACK 数量”，
两者都在优化“小包”，而小包本身就是这两类应用的正常形态。**
对它们来说，优化小包等于制造延迟。

---

## 21.7 吞吐模型：Mathis 公式与本仿真的对照

### 21.7.1 公式

Mathis、Semeniuk、Mahdavi 等人在 1997 年给出了 AIMD 在稳态下的吞吐近似：

```text
BW ≈ (MSS / RTT) · sqrt(3 / (2p))
```

其中 `p` 是稳态丢包率。它的推导假设“每个窗口丢一个包、窗口减半、
再线性爬回”，所以：

- 窗口 ≈ `sqrt(3/(2p))` 段；
- 吞吐 = 窗口 / RTT。

代入 p = 1%：`sqrt(3/0.02) = sqrt(150) = 12.247 段/RTT`。
10 Mbit/s 链路上，12.247 段 / 24 ms = 745 字节/ms。

工程里把开方做成了整数版本，避免在 rv32 上拖进 f64：

```zig
pub fn mathisSegPerRttMilli(p_permille: u32) u64 {
    if (p_permille == 0) return std.math.maxInt(u32);
    const num: u64 = 1500 * 1_000_000 / p_permille;
    return isqrt(num);
}
```

> 源自 `src/cong.zig` 的 `mathisSegPerRttMilli`。`p_permille = 10` 表示 1%，
> 返回 12247，即 12.247 段/RTT（千分之一段为单位）。

板侧判据 ⑩ 用的是 **4 MiB 稳态运行**（不是 21.2 那条 256 KiB 的爬坡曲线）：

```text
check: mathis p=1% theory=745025 sim=596290 ratio_x1000=800 ok=1
```

`theory = 745025` 的单位是“毫字节/tick”，即 745.0 字节/tick；仿真 596.3；
比值 0.80。**稳态下仿真比理论低 20%**，原因见 21.7.3。

### 21.7.2 稳态对照（4 MiB ≈ 2873 个段）

这一组运行才是“Mathis 描述的东西”：1% 丢包下约 29 次丢包事件、
28 次快重传，而不是 1 次。

| 周期丢包 | p   | Mathis 理论(字节/tick) | 仿真(字节/tick) | 比值 | 重传 | 其中超时 | 快重传 |
| -------- | --- | ---------------------- | --------------- | ---- | ---- | -------- | ------ |
| 不丢     | 0   | —                      | 1211.9          | —    | 0    | 0        | 0      |
| k=100    | 1%  | 745.0                  | 596.3           | 0.80 | 29   | 1        | 28     |
| k=50     | 2%  | 526.8                  | 429.4           | 0.82 | 58   | 0        | 58     |
| k=25     | 4%  | 372.5                  | 245.4           | 0.66 | 119  | 0        | 119    |
| k=10     | 10% | 235.5                  | 136.5           | 0.58 | 317  | 2        | 315    |

三条结论：

1. **单调性成立，而且是真的稳态。** 无丢包 1211.9 → 1% 596.3 → 2% 429.4
   → 4% 245.4 → 10% 136.5。无丢包那一行的 1211.9/1250 = 97%，
   说明链路确实被跑满了（剩下 3% 是启动爬坡与尾部）。
2. **仿真稳定低于 Mathis，且丢包越高差得越多**（0.80 → 0.58）。
   先把“实际丢包”对上再谈偏差：k=100 的稳态运行发出 2874 段、重传 29 次，
   实际丢包 ≈ 29/2874 = 10.1‰，与名义 p = 1/100 = 10‰ 一致——这组运行
   确实跑在公式假设的丢包率上（256 KiB 那一组只有 5.6‰，见下一条）。
   三个方向的原因，见 21.7.3 的模型边界；其中最主要的一条是
   **周期丢包是“固定位置”的**：每第 k 个段必丢，丢包与窗口相位高度相关，
   而 Mathis 假设的是随机丢包。随机丢包会成簇，一个窗口里多个洞
   → 只能靠 RTO，代价更高；两种模型各有偏差，但都落在同一量级。
3. **不要把 256 KiB 运行拿来验证公式。** 同样是 k=100，短运行给出：

   | 运行长度 | 段数 | 丢包事件 | 仿真(字节/tick) | 比值 |
   | -------- | ---: | -------: | --------------- | ---- |
   | 256 KiB  |  180 |        1 | 757.6           | 1.02 |
   | 4 MiB    | 2874 |       29 | 596.3           | 0.80 |

   短运行的 1.02 是**爬坡均值的巧合**：慢启动从 1 段爬到 BDP，
   整段传输的平均吞吐恰好落到理论值附近，但运行里根本没有“锯齿”。
   一个只在 1 次丢包上“验证公式”的实验，验证的是巧合，不是公式。
   这是本章最想强调的方法论：**判据要跑够长，让被检验的现象真的出现。**

### 21.7.3 模型边界（必须写清楚）

本仿真是**教科书模型**，有五条明确简化，任何引用都要带上：

| 简化                     | 真实情况              | 影响                                                                 |
| ------------------------ | --------------------- | -------------------------------------------------------------------- |
| 单发送端、无交叉流量     | 多个流共享瓶颈        | AIMD 的公平性无法在单流模型里体现                                    |
| 固定 RTT（24 ms）        | 排队会让 RTT 上升     | 真实链路会看到 RTT 随窗口上升（bufferbloat）                         |
| 队列无上限               | 队列溢出即丢包        | 仿真里 `cwnd` 可以超过 BDP 而不丢包                                  |
| 超时用 go-back-N         | 真实栈只重传队首      | 丢包率高时仿真更悲观                                                 |
| **周期丢包（固定位置）** | 真实丢包是随机/成簇的 | 周期丢包每窗必丢一个洞，快重传几乎总能救回；随机成簇丢包会退化成 RTO |

最后一条最容易被忽略，也是“为什么仿真值不是理论值”的主要来源。
如果想更贴近随机丢包，用 `.random(permille)` 模式——但那时就不能再
要求和理论值吻合到个位数：随机数在有限样本里本来就有方差
（这也是为什么判据 ⑧ 用周期模式做单调性、用随机模式做可复现性）。

另外还有一条**周期丢包的边界**：k=200 与 k=400 两组在 256 KiB 的运行里
**没有任何丢包**，因为那次传输只有 180 个段，第 200 个段根本没发出去。
把这两组当成“低丢包率”来读会得到错误的结论；章节表格因此只用
k ≤ 100 的四组。

---

## 21.8 工程走读

站内代码浏览（不离开站点看高亮源码）：

| 文件                 | 角色                                                                    | 代码浏览                                                                    |
| -------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`                                    | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆栈边界、四条 ASSERT                       | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                               | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/main.zig)       |
| `src/selftest.zig`   | 板侧 10 条判据（①–⑩）与曲线读数                                         | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/selftest.zig)   |
| `src/cong.zig`       | 控制律：慢启动/拥塞避免/快重传/超时/RTO/BDP/pacing/Nagle/Mathis         | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/cong.zig)       |
| `src/sim.zig`        | 确定性丢包仿真：段队列、接收位图、周期/随机丢包                         | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/sim.zig)        |
| `src/host_tests.zig` | `zig build test` 的根：只 import 纯逻辑模块                             | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/host_tests.zig) |
| `src/hw.zig`         | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                              | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/hw.zig)         |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump（80 字节帧）                              | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/trap.zig)       |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                               | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/log.zig)        |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用          | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/tools/flash.sh)     |

完整工程（入口为工程 README，可再进目录树）：[ch21-tcp-congestion](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/README.md)

深链由 `npm run code-site` 生成（`scripts/gen-code-site.mjs` 的
`PROJECT_GLOBS` 已覆盖 `practice/zig-esp32-s31/*`），浏览页收录本章工程的全部源文件。

### 21.8.1 三个模块的职责边界

```text
cong.zig  纯状态机：事件 → 窗口变化。无时间、无缓冲、无 I/O。
              ↑ 被两方复用
sim.zig   驱动者：tick 循环 + 段队列 + 接收位图，喂事件给 cong.zig
              ↑ 被两方复用
selftest  板侧使用者：先逐事件验证公式（判据 ①–⑦），再跑仿真（⑧–⑩）
host_tests 主机侧使用者：zig build test 只 import cong.zig / sim.zig
```

**为什么 `cong.zig` 里一行 `std.time` 都没有？** 因为板侧是纯轮询、
无中断、无 tick 源（`mstatus.MIE = 0`）。如果状态机自己读时钟，
主机测试就必须 mock 时钟，板侧又必须提供 tick —— 两边都会长出适配层。
把它做成“纯函数 + 显式输入”，两边共用同一份实现，测试才是真的测了
同一份代码。

### 21.8.2 静态缓冲与 16 KiB 栈

`sim.zig` 的段队列与接收位图是**文件作用域的静态缓冲**，不是
`run()` 的局部变量：

```zig
const queue_cap = 128;      // 64 KiB 接收窗口 = 45 段，128 段留出重传余量
const delivered_cap = 4096; // 4096 × 1460 = 5.7 MiB，覆盖 4 MiB 的稳态运行

var g_queue: [queue_cap]Seg = undefined;
var g_delivered: [delivered_cap]bool = @splat(false);
```

原因写在注释里：链接脚本给主栈 16 KiB（`linker/s31.ld` 的
`_stack_size = 0x4000`）。128 段队列 = 3 KiB、接收位图 4096 项 = 4 KiB，
两块加起来 7 KiB（都在 `.bss`，不在栈上）；如果它们进栈，`main → selftest →
run` 的帧加上 `Result`（采样数组 256 B）就会越过 16 KiB 栈顶——
**表现是 trap，不是“结果不对”**。
这类问题在主机上看不出来（x86_64 栈有 8 MB），只有上板才炸。

`run()` 开头还有一行必须存在的清理：

```zig
@memset(&g_delivered, false); // 上一次运行的状态不能漏进这一次
```

静态缓冲的代价就是“跨调用保留状态”。主机侧有一个用例专门跑同一组参数
两次并比对指纹，就是为了钉住这条：

```text
sim: seed=0x21c0ffee hash=0xfd1ab529b33a5ef rerun=0xfd1ab529b33a5ef equal=1
```

### 21.8.3 与 ch16 的 `headers.zig` / `pbuf` 是什么关系

|                  | ch16                                                                                     | 本章                                                          |
| ---------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `headers.zig`    | 以太网/IPv4/UDP 首部的读写与校验和（`pub const Udp` 在 `headers.zig:181`，**没有 TCP**） | 完全不用：拥塞控制只看“ACK 确认了多少字节”，不看首部          |
| `pbuf.zig`       | 零拷贝缓冲链（head/tail、引用计数）                                                      | 完全不用：仿真里每个段就是一个 `Seg{seq,len,at,dropped}` 结构 |
| 为什么能完全解耦 | —                                                                                        | 窗口控制律的输入是整数（字节数），输出是枚举（要不要重传）    |

本章**没有**为了“复用”而 import ch16 的任何模块。ch16 的 `headers.zig`
只到 UDP，TCP 首部由 ch20 补齐；即便 ch20 补齐了，本章也不需要它——
把首部布局引入本章的依赖图，只会让主机测试多一份“构造合法首部”的负担，
却对判据 ①–⑩ 一点帮助都没有。

---

## 21.9 上板自检输出（真实日志）

烧录与抓取：`flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'`，
串口 115200 8N1（UART0，GPIO58/59）。原始输出在
`practice/zig-esp32-s31/logs/ch21-boot.log`，下面是与判据相关的部分原文：

```text
ch21-tcp-congestion | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: cwnd/ssthresh/rto/bdp/pacing/nagle + deterministic loss sim
note: throughput numbers are host-side simulation, NOT a real link
host: 21 unit tests via 'zig build test' (20 named + root container)
check: cwnd slowstart rtt 1,2,4,8 ok=1
check: cwnd ca per-rtt 8,9,10,11 ok=1
check: fast retx ssthresh=7300 cwnd=11680 state=fast_recovery ok=1
check: timeout cwnd=1460 ssthresh=11680 ok=1
check: window min(cwnd=14600,rwnd=5840)=5840 ok=1
check: wscale shift=14 encode(1MiB)=64 decode=1048576 max=1073725440 ok=1
check: nagle unacked=1 small=blocked full=allowed idle=allowed ok=1
sim: cwnd none@1rtt n=14 [1,1,2,4,8,16,23,24,25,26,26,27,28,29]
sim: cwnd loss1/100 n=15 [1,1,2,4,8,16,23,24,25,26,29,13,14,15,16]
sim: k100 ramp sent=180 retx=1 to=0 fr=1 dup=23 ticks=346
check: sim tp none=1211876 k100=596290 k25=245395 k10=136453 ok=1
sim: k100 steady sent=2874 retx=29 to=1 fr=28 dup=386 ticks=7034
sim: seed=0x21c0ffee hash=0xfd1ab529b33a5ef rerun=0xfd1ab529b33a5ef equal=1
check: bdp 10mbit/24ms = 30000B 21seg rwnd_needed=30660 ok=1
check: mathis p=1% theory=745025 sim=596290 ratio_x1000=800 ok=1
checks: passed=10 failed=0 total=10
main: verdict=pass, congestion control law verified off-link (wfi)
main: halting (wfi)
```

### 21.9.1 判读顺序

| 顺序 | 前缀              | 判据                                             | 失败时先怀疑                                            |
| ---- | ----------------- | ------------------------------------------------ | ------------------------------------------------------- |
| 1    | `cwnd slowstart`  | 1,2,4,8                                          | `onAck` 的 2 SMSS 上界、`mssCount` 的单位               |
| 2    | `cwnd ca per-rtt` | 8,9,10,11                                        | `ca_acked` 累加器是否在切换时清零                       |
| 3    | `fast retx`       | ssthresh=7300 cwnd=11680                         | `halfWindow` 的下限、3 MSS 膨胀                         |
| 4    | `timeout`         | cwnd=1460 ssthresh=11680                         | 超时路径是否误用快重传的公式                            |
| 5    | `window`          | 5840                                             | 是否把 rwnd 与 cwnd 相加了                              |
| 6    | `wscale`          | 64 / 1048576 / 1073725440                        | 编码是否向上取整、shift 是否钳 14                       |
| 7    | `nagle`           | blocked/allowed/allowed                          | 判据是否漏了“满段放行”                                  |
| 8    | `sim tp`          | 1211876 > 596290 > 245395 > 136453（4 MiB 稳态） | 丢包模式是否真的生效（看 retx）、`total_bytes` 是否够长 |
| 9    | `bdp`             | 30000 / 21 / 30660                               | 位的字节换算、向上取整                                  |
| 10   | `mathis`          | ratio ≈ 800（稳态低 20%）                        | p 的千分比换算、整数开方、运行长度是否足够              |

### 21.9.2 五条 `sim:` 行是读数，不是判据

`checks:` 行只汇总 10 条判据。三行 `sim:` 是**判据的原始读数**：

1. `cwnd none@1rtt` 与 `cwnd loss1/100`：两条曲线，21.2/21.3 的表格直接从
   这两行抄下来；
2. `k100 ramp` 与 `k100 steady`：两行描述**同一组丢包参数下的两种运行长度**。
   256 KiB 那一组只有 1 次重传（曲线来自它），4 MiB 那一组有 29 次
   （判据 ⑧⑩ 来自它）。两行必须同时出现，否则无法判断“吞吐下降”
   是真丢包造成的，还是运行被截断了；
3. `seed/hash/rerun/equal`：确定性证据。**同一台板子、同一次上电、
   两次调用仿真得到同一个 64 位指纹**，而主机侧用另一个种子得到的是
   `0xa02c6b11b5f4514c`（见 `zig build test` 的用例）。

> [!warning] 不要这样读日志
> `none=1211876` 读作 1211.9 字节/tick，不是“板子跑 1211 KB/s”。
> tick 是仿真器的**虚拟毫秒**，链路参数是写死的 10 Mbit/s
> （1250 字节/tick），所以 1211.9 的含义是“这条虚拟链路被用到了 97%”。
> 把它当成实测吞吐，就把仿真当成了硬件。

---

## 21.10 与 lwIP 的对照

lwIP 的拥塞控制在 `tcp.c` / `tcp_in.c` / `tcp_out.c` 三个文件里，
散落在“收到 ACK”“收到重复 ACK”“慢定时器”三个入口。下表是本工程的
每条规则与它的实现坐标（行号来自本机 `~/esp/esp-idf`，逐条 grep 过）：

| 规则                                          | lwIP 实现                                                          | 与本章的差异                                  |
| --------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------- |
| 初始 `ssthresh = TCP_SND_BUF`                 | `tcp.c:1955`                                                       | 本章给显式常量，便于画出切换点                |
| 初始 RTO = 3000 ms                            | `opt.h:1384`（`LWIP_TCP_RTO_TIME`）、`tcp.c:1942`                  | 本章按 RFC 6298 从 1 s 起、下限 200 ms        |
| 慢启动：每 ACK ≤ 2 SMSS                       | `tcp_in.c:1283`（RFC 3465 §2.2）、`tcp_in.c:1292` 的 `TCP_WND_INC` | 相同；额外用 `TF_RTO` 把首次恢复限制到 1 SMSS |
| 拥塞避免：每 RTT +1 MSS                       | `tcp_in.c:1288`（RFC 3465 §2.1）                                   | 相同（字节累加器）                            |
| 重复 ACK 计数与膨胀                           | `tcp_in.c:1238-1240`（`dupacks > 3` 时 `cwnd += mss`）             | 相同                                          |
| 三重复 ACK → 快重传                           | `tcp_in.c:1242-1244` 调 `tcp_rexmit_fast()`                        | 相同                                          |
| `ssthresh = min(cwnd, snd_wnd)/2`             | `tcp_out.c:1801`，下限 2 MSS 在 `1804-1809`                        | 相同（本章 `halfWindow`）                     |
| `cwnd = ssthresh + 3 MSS`                     | `tcp_out.c:1812`                                                   | 相同                                          |
| 快恢复 deflate                                | `tcp_in.c:1259`（`TF_INFR` 清除时 `cwnd = ssthresh`）              | 相同（Reno）                                  |
| 超时：`ssthresh = eff_wnd>>1`、`cwnd = 1 MSS` | `tcp.c:1311`、`tcp.c:1315`                                         | 相同                                          |
| 退避表                                        | `tcp.c:163`（`{1,2,3,4,5,6,7,7,…}` 倍慢定时器）                    | 本章用 RFC 6298 的 `2·RTO`                    |
| 在途上限 = `min(snd_wnd, cwnd)`               | `tcp_out.c:1266`                                                   | 相同                                          |
| 收到窗口更新时缩放                            | `tcp_in.c:1184-1185`（`SND_WND_SCALE`）                            | 相同                                          |
| `wscale > 14` 钳到 14                         | `tcp_in.c:2020-2022`                                               | 相同                                          |
| Nagle 判据                                    | `tcp_priv.h:100-105`（`tcp_do_output_nagle`）                      | 相同，本章少两个例外（`TF_INFR`、缓冲满）     |
| 粗定时器 500 ms                               | `tcp_priv.h:117`（250 ms）与 `:125`（`TCP_SLOW_INTERVAL`）         | 本章不实现定时器，只按 RTO 值驱动仿真         |

> 这条表只做**源码级对照**：本章不链接 lwIP，也没有在真链路上跑过
> lwIP 的拥塞控制。任何“lwIP 在本机跑出多少吞吐”的说法都需要 ch17 闭环，
> 本章不提供。

三处值得展开的差异：

**1. lwIP 的 `TF_RTO` 保护。** 超时把 `cwnd` 打回 1 MSS 之后，
lwIP 在 `tcp_in.c` 里用 `num_seg = (pcb->flags & TF_RTO) ? 1 : 2` 限制
“RTO 后的第一个 RTT 每个 ACK 只加 1 SMSS”。这是 RFC 3465 §2.2 的补丁，
目的是避免“刚超时就把窗口翻倍”再次压垮网络。本章的 `Cwnd` 没有这个
标志位，因此超时后的第一个 RTT 就可能翻倍——**这是本章为了保持状态机
简单而做的取舍**，在仿真里影响很小（k=10 只有 2 次超时）。

**2. 快重传的前置条件。** lwIP 的 `tcp_rexmit_fast()`（`tcp_out.c:1787`）
只在 `pcb->unacked != NULL && !(pcb->flags & TF_INFR)` 时才动手，
并用 `TF_INFR` 而不是 `dupacks >= 3` 判断“是否已在恢复里”。
这两种写法的区别是**幂等性**：如果第 4、5 个重复 ACK 也触发重传，
同一段会被重发多次，网络里凭空多出流量。本章靠 `onDupAck` 里
`dupacks == 3` 的精确相等来保证只触发一次。

**3. 接收窗口的更新策略。** lwIP 在 `tcp.c:1006` 用
`TCP_WND_UPDATE_THRESHOLD` 控制“窗口增长多少才值得发一个更新 ACK”，
本章完全不涉及——那是接收端的事，本章只是把对方通告的值当成输入。

---

## 21.11 边界：真实链路需要 ch17，本章只给控制律与仿真

把本章交付的东西列清楚，同时把没做的也列清楚：

- ✅ 拥塞窗口状态机：慢启动 / 拥塞避免 / 快重传 / 快恢复 / 超时
- ✅ `ssthresh` 的减半与 2 MSS 下限
- ✅ 在途上限 = `min(cwnd, rwnd)`
- ✅ RFC 7323 窗口缩放（钳 14、编码向下取整）
- ✅ BDP 计算与“窗口至少要多大”的换算
- ✅ RFC 6298 的 RTT 估计与 RTO（含下界/上限/指数退避）
- ✅ pacing 令牌桶（`cwnd/RTT` 的速率换算）
- ✅ Nagle 判据与延迟 ACK 的互等分析
- ✅ 确定性丢包仿真（周期/随机、同种子可复现）
- ❌ **不发送任何真实报文**：没有 MAC、没有 IP、没有 socket
- ❌ **不测真链路吞吐/时延**：ch17 未闭环，任何“实测吞吐”都不存在
- ❌ 不做 SACK（RFC 2018）与 NewReno 的多洞恢复
- ❌ 不做 CUBIC / BBR 等现代算法（本章只实现 Reno 这一支）
- ❌ 不做 ECN（RFC 3168）——它的丢包替代信号不在本章范围

ch20 的 20.12.1 表格把“拥塞控制 / 收发窗口管理 / 窗口缩放 / SACK / ECN+CWR”
五项交给本章，逐项结账：`cwnd`/`ssthresh`/慢启动/AIMD ✓、
`min(cwnd, rwnd)` 的收发窗口管理 ✓、RFC 7323 窗口缩放 ✓（21.5.3）、
**SACK 与选择性重传 ✗**（本章仍是 Reno 快重传 + go-back-N 式超时恢复）、
**ECN/CWR ✗**。20.12.3 承诺的“同样的丢包序列，窗口曲线与 RFC 5681 一致”
对应判据 ③④ 与 21.3 的两条曲线，且**只以主机侧仿真形式交付**，
不是真链路吞吐。

- ❌ 不做 TSO/GSO、分段卸载与网卡特性相关的窗口调整

### 21.11.1 接上真链路要补什么

真实链路的联调顺序（ch17 闭环之后）：

| 顺序 | 判据                                 | 说明                                   |
| ---- | ------------------------------------ | -------------------------------------- |
| 1    | ch17：`mdio:` 读到 PHY ID、`link=1`  | 没有链路就没有 RTT                     |
| 2    | ch17：`rx:` 至少收到一帧             | RXC 时钟、过滤位                       |
| 3    | ch18/ch20：ARP 解析 + 三次握手       | 握手完成才能测窗口                     |
| 4    | 本章：`cwnd` 从 1（或 10）开始增长   | 用串口打印每 RTT 的 `cwnd`             |
| 5    | 本章：RTT 与 `ping` 的 RTT 同量级    | 说明 `RttEstimator` 的样本真的来自 ACK |
| 6    | 本章：吞吐 ≈ `min(cwnd, rwnd) / RTT` | 这是唯一能把仿真与实测对上的等式       |
| 7    | 主动丢包（`tc netem` 或中间交换机）  | 观察锯齿是否按 Mathis 预测下降         |

第 6 步是本章唯一“可以拿来验证仿真”的等式：它不含任何算法假设，
只是“窗口 / RTT = 速率”。如果实测吞吐远低于这个值，先怀疑应用层没
把数据喂满（发送缓冲空），再怀疑窗口配置，最后才怀疑算法。

---

## 事实来源

本章的协议规则来自公开 RFC，对照实现来自本地 ESP-IDF v6.1 自带的
lwIP（路径相对 `~/esp/esp-idf/`），行号逐条 grep 过。

| #   | 事实                                                                                            | 路径与位置                                                                                                                       |
| --- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| 1   | 慢启动：`cwnd < ssthresh` 时每 ACK 至多 +2 SMSS；否则每 RTT +1 SMSS                             | RFC 5681 §3.1                                                                                                                    |
| 2   | 三重复 ACK → 快重传；`ssthresh = max(FlightSize/2, 2·SMSS)`；`cwnd = ssthresh + 3·SMSS`         | RFC 5681 §3.2                                                                                                                    |
| 3   | 超时：`ssthresh` 减半，`cwnd` 回到 1 SMSS                                                       | RFC 5681 §3.1 末段                                                                                                               |
| 4   | RTT 估计：`SRTT`/`RTTVAR` 的 1/8、1/4 平滑，`RTO = SRTT + max(G, 4·RTTVAR)`，退避上限 60 s      | RFC 6298 §2、§5.5                                                                                                                |
| 5   | 窗口缩放 shift 上限 14，超出必须当 14 处理                                                      | RFC 7323 §2.2                                                                                                                    |
| 6   | Nagle：没有未确认数据时才允许发小段                                                             | RFC 896                                                                                                                          |
| 7   | 延迟 ACK 与 Nagle 的互等，以及 `TCP_NODELAY` 的建议                                             | RFC 1122 §4.2.3.2                                                                                                                |
| 8   | 吞吐模型 `BW ≈ (MSS/RTT)·sqrt(3/(2p))`                                                          | Mathis et al., _The Macroscopic Behavior of the TCP Congestion Avoidance Algorithm_, 1997                                        |
| 9   | lwIP 初始 `ssthresh = TCP_SND_BUF` 及其理由（窗口缩放/自动调优）                                | `components/lwip/lwip/src/core/tcp.c:1949-1955`                                                                                  |
| 10  | lwIP 初始 RTO = 3000 ms，按 500 ms 慢定时器折算成 6 跳                                          | `components/lwip/lwip/src/include/lwip/opt.h:1384`、`src/core/tcp.c:1942`                                                        |
| 11  | lwIP 退避表 `tcp_backoff[13] = {1,2,3,4,5,6,7,7,7,7,7,7,7}`                                     | `components/lwip/lwip/src/core/tcp.c:163`                                                                                        |
| 12  | lwIP 超时路径：`ssthresh = eff_wnd >> 1`（下限 2 MSS）、`cwnd = mss`                            | `components/lwip/lwip/src/core/tcp.c:1311`、`:1315`（下限判断在 `:1312-1313`）                                                   |
| 13  | lwIP 重复 ACK 的三种处理（<3 忽略 / =3 快重传 / >3 膨胀）与 `cwnd += mss`                       | `components/lwip/lwip/src/core/tcp_in.c:1214-1216`（注释）、`:1238-1240`                                                         |
| 14  | lwIP 快重传函数与公式：`ssthresh = min(cwnd, snd_wnd)/2`、下限 2 MSS、`cwnd = ssthresh + 3·mss` | `components/lwip/lwip/src/core/tcp_out.c:1787`、`:1801`、`:1804-1809`、`:1812`                                                   |
| 15  | lwIP 快恢复 deflate：清 `TF_INFR` 时 `cwnd = ssthresh`                                          | `components/lwip/lwip/src/core/tcp_in.c:1256-1259`                                                                               |
| 16  | lwIP 慢启动/拥塞避免的字节计数实现（RFC 3465）                                                  | `components/lwip/lwip/src/core/tcp_in.c:1283`、`:1288-1292`                                                                      |
| 17  | lwIP 在途上限 = `min(snd_wnd, cwnd)`                                                            | `components/lwip/lwip/src/core/tcp_out.c:1266`                                                                                   |
| 18  | lwIP 收到窗口更新时应用 `SND_WND_SCALE`                                                         | `components/lwip/lwip/src/core/tcp_in.c:1184-1185`                                                                               |
| 19  | lwIP 把 `snd_scale > 14` 钳到 14                                                                | `components/lwip/lwip/src/core/tcp_in.c:2020-2022`                                                                               |
| 20  | lwIP 的 Nagle 判据（含 `TF_INFR` 与缓冲满的例外）                                               | `components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:100-105`                                                                  |
| 21  | lwIP 定时器粒度：`TCP_TMR_INTERVAL 250`、`TCP_SLOW_INTERVAL 500`                                | `components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:117`、`:125`                                                              |
| 22  | MSS 三方取值：lwIP 自身默认 536、ESP-IDF Kconfig 默认 1440、本章仿真用 1460（1500 − 20 − 20）   | `components/lwip/lwip/src/include/lwip/opt.h:1362`、`components/lwip/port/include/lwipopts.h:621`、`components/lwip/Kconfig:650` |
| 23  | ESP-IDF 默认发送缓冲与接收窗口都是 5760 字节（4 × 1440）                                        | `components/lwip/Kconfig:682`、`:699`                                                                                            |
| 24  | ch16 的 `headers.zig` 只到 UDP，没有 TCP 首部                                                   | `practice/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/headers.zig:181`                                                   |

> [!note] 口径
> 第 9–23 行是**对照实现**，不是本章的依赖：本章不链接 lwIP，也没有在
> 真链路上跑过它。凡属本章自己的判断（`ssthresh` 取 32 KiB、
> 从 1 MSS 起步、仿真用周期丢包、超时用 go-back-N），都在正文里给了
> 理由与用例，而不是引用权威。
>
> 本章的 MSS 选 1460（以太网 MTU 1500 − IPv4 20 − TCP 20），
> 而 ESP-IDF 的 Kconfig 默认是 1440。差 1.4%，不影响任何控制律；
> 但如果在真机上对账，会看到窗口字节数差这么多。

---

## 自查清单

静态部分（本机 2026-11-13 实测，宿主 x86_64 / Zig 0.17.1）：

- [x] `zig build test` 全绿：`21/21 tests passed`（20 个具名用例 + 根文件容器 test）
- [x] 覆盖边界已核对：`host_tests.zig` 只 import `cong.zig`/`sim.zig`，
      **不编译 `selftest.zig`**；十个板侧判据只由 rv32 交叉编译 + 上板运行验证
      （不要把 21 个用例读成“十个板侧判据已被主机测试覆盖”）
- [x] 仿真确定性：同种子两次运行指纹相同（`hash=0xfd1ab529b33a5ef` 两次），换种子必变
- [x] `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 的段表里 `DROM, IROM` 行数**正好 2**（`0x40000020`、`0x40020020`）
- [x] `bash -n tools/flash.sh` 退出 0
- [x] `cong.zig` 与 `sim.zig` 均无 `std.time`、无分配器、无浮点（板上不拖 soft-float）

上板部分（2026-11-13，`practice/zig-esp32-s31/logs/ch21-boot.log`）：

- [x] banner 五行完整（含 `note: throughput numbers are host-side simulation, NOT a real link` 与 `host: 21 unit tests via 'zig build test' (20 named + root container)`）
- [x] `check: cwnd slowstart rtt 1,2,4,8 ok=1`
- [x] `check: cwnd ca per-rtt 8,9,10,11 ok=1`
- [x] `check: fast retx ssthresh=7300 cwnd=11680 state=fast_recovery ok=1`
- [x] `check: timeout cwnd=1460 ssthresh=11680 ok=1`
- [x] `check: window min(cwnd=14600,rwnd=5840)=5840 ok=1`
- [x] `check: wscale shift=14 encode(1MiB)=64 decode=1048576 max=1073725440 ok=1`
- [x] `check: nagle unacked=1 small=blocked full=allowed idle=allowed ok=1`
- [x] `check: sim tp none=1211876 k100=596290 k25=245395 k10=136453 ok=1`
- [x] `check: bdp 10mbit/24ms = 30000B 21seg rwnd_needed=30660 ok=1`
- [x] `check: mathis p=1% theory=745025 sim=596290 ratio_x1000=800 ok=1`
- [x] `checks: passed=10 failed=0 total=10`
- [x] `main: verdict=pass` 之后停在 `wfi`，复位可重复

未闭环（不代填）：

- [ ] 真链路吞吐/时延曲线：需 ch17 以太网驱动闭环（DMA 软复位、MDIO、TX）
- [ ] ch20 状态机 + 本章控制律合体后的丢包恢复实测
- [ ] 接收窗口缩放（`LWIP_WND_SCALE`）在真链路上的协商与效果
- [ ] SACK / NewReno 的多洞恢复（本章只实现 Reno）

失败时的第一反应（按顺序排查，不要跳步）：

1. 曲线不是 1,2,4,8 → 先看 `onAck` 的 `@min(acked, 2*mss)`，再看 `mssCount()` 的整除；
2. 拥塞避免不是 +1/RTT → 看 `ca_acked` 在状态切换时是否清零（快恢复 deflate 与超时都要清）；
3. 快重传没触发 → 看重复 ACK 计数是否被“窗口变化”重置（仿真里窗口恒定，所以不会）；
4. 快恢复不收敛 → 看 `onAck` 里是否**先**处理 `fast_recovery` 再增长窗口；
5. 吞吐不随丢包下降 → 先看 `retx` 是否为 0（丢包模式没生效），再看 `max_ticks` 是否截断；
6. `same seed` 指纹不同 → 看 `run()` 开头是否清了 `g_delivered`，`loss_counter` 是否跨调用残留。

---

## 下一章预告

下一章进入 socket API：把 ch18–ch21 的四层东西（IP 路径、TCP 状态机、
拥塞控制、端口与名字）包成应用能用的接口——阻塞/非阻塞、`poll`/`select`
式事件循环、回调与超时，以及在“没有调度器、没有中断”的形态 B 里
如何用一个轮询循环同时驱动多个连接。

本章留下的两个接口会被直接复用：

- `cong.Cwnd` 的四个事件入口（新 ACK / 重复 ACK / 超时 / 发送机会）；
- `sim.zig` 的确定性驱动循环——它是“没有网络也能回归测试协议逻辑”的模板，
  socket 层的事件循环测试同样可以照这个形状写。

> 下一章：[[ch22-socket-api-event-loop|第二十二章：Socket API 与事件循环]]

系列导航：[[ch20-tcp-state-machine-reliable-delivery|上一章：TCP 状态机与可靠传输]] · [[zig-esp32-s31|系列索引]]
