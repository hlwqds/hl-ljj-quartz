---
title: "Zig × ESP32-S31 全栈开发（二十）：TCP 状态机与可靠传输"
date: 2026-12-15 18:00:00
description: "从「能问路」到「能负责」：TCP 首部逐字段与选项、2^32 模空间里的 seq/ack 算术与回绕、11 个状态与三次握手/四次挥手、TIME_WAIT 与 2MSL、RFC 6298 的 SRTT/RTTVAR/K=4 与 Karn 算法、单段重传与重复 ACK 快速重传、有界乱序重组、伪首部校验和，以及「如何用注入时钟在两毫秒里验完 60 秒的 TIME_WAIT」。"
tags: [zig, esp32-s31, riscv, tcp, state-machine, reliable-delivery, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. [[ch04-linker-memory-layout|第四章：链接脚本与内存布局]]
> 5. [[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]
> 6. [[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]]
> 7. [[ch07-interrupts-exceptions-clic|第七章：中断、异常与 CLIC]]
> 8. [[ch08-timers-dma-precision|第八章：定时器、DMA 与精确时序]]
> 9. [[ch09-spi-flash-partition-nvs|第九章：SPI Flash、分区与 NVS 存储]]
> 10. [[ch10-context-switch-cooperative-scheduler|第十章：上下文切换与协作调度]]
> 11. [[ch11-preemptive-scheduler-tcb-tick|第十一章：抢占调度、TCB 与 tick]]
> 12. [[ch12-sync-primitives-ipc|第十二章：同步原语与 IPC]]
> 13. [[ch13-heap-stack-caps|第十三章：堆、栈保护与内存 caps]]
> 14. [[ch14-dual-core-smp-ipi|第十四章：双核 SMP 与 IPI]]
> 15. [[ch15-observability-testing-stability|第十五章：可观测性、测试与稳定性]]
> 16. [[ch16-stack-architecture-zero-copy|第十六章：协议栈架构、缓冲与零拷贝]]
> 17. [[ch17-ethernet-mac-phy-driver|第十七章：以太网 MAC/PHY 驱动]]
> 18. [[ch18-ipv4-icmp-arp-routing|第十八章：IPv4、ICMP、ARP 与路由]]
> 19. [[ch19-udp-dhcp-dns|第十九章：UDP、DHCP 与 DNS]]
> 20. **第二十章：TCP 状态机与可靠传输**
> 21. [[ch21-tcp-congestion-throughput|第二十一章：TCP 拥塞控制与吞吐]]

# Zig × ESP32-S31 全栈开发（二十）：TCP 状态机与可靠传输

第十九章结束时，板子能自己问出一张“身份证”：IP、掩码、网关、DNS。
但那四个数字只够它**说一句话**——UDP 把数据报扔出去，丢了就算了。
真实世界的连接要的是另一件事：**说出去的话，对方一定收到，且只收一次**。

这一章就做这一件事。它和前面所有章都不同：

| 章节              | 主要难点                 | 状态      | 定时器       | 内存         |
| ----------------- | ------------------------ | --------- | ------------ | ------------ |
| ch18 IPv4/ICMP    | 逐字段解析、校验和       | 无        | 无           | 单帧         |
| ch19 UDP/DHCP/DNS | 报文格式 + 租约计时      | 6（DHCP） | 4（租期）    | 单报文       |
| **ch20 TCP**      | **状态 × 定时器 × 内存** | **11**    | **2 个尺度** | **3 块定容** |

所谓“难”，不是字段多，而是三者互相纠缠：

- 状态决定“收到这个段该回什么”，而回什么又改变状态；
- 定时器决定“没收到回音时该重发什么”，而重发又必须让状态机知道；
- 内存决定“乱序段能暂存多少”，暂存不下时的正确反应是**继续确认缺口**，
  而不是悄悄丢掉整个连接。

> [!warning] 本章的证据边界
> 静态部分全部验证过（2026-11-13，宿主 x86_64 / Zig 0.17.1）：
>
> - `zig build test` → `All 27 tests passed`（26 个具名用例 + 根文件容器 test）；
> - `zig build -Dtarget=riscv32-freestanding-eabihf …` 退出 0；
> - `esptool elf2image` 打印 `Merged 2 ELF sections.`；`image-info` 的段表里落在
>   flash 的 `DROM, IROM` 行正好两条（`0x40000020` / `0x40020020`）；
> - `bash -n tools/flash.sh` 退出 0。
>
> **已上板（2026-11-13）**：板侧 11 条判据全部 PASS，原始输出见
> `practice/zig-esp32-s31/logs/ch20-boot.log`。
>
> **上板证据只来自注入路径**：自检的每一个“段”都是 `.bss` 里的字节数组，
> 不经过 MAC、不经过 IPv4、不经过任何网卡，也没有中断与真实 tick。
> 因此本章**不声称**“板上能握手”“抓包能看到三次握手”。
> 真实链路上的验收必须等 ch17（以太网 DMA）闭环后与本章联调，
> 那一项的写法是「待 ch17 闭环」，不是本章的结论。

---

## 20.1 为什么 TCP 比前面所有章都难

先把“难”拆成可验证的判据，而不是一句感觉。

### 20.1.1 状态是协议的一部分

UDP 没有状态：收一个数据报，看端口，交付或丢弃。TCP 的同一个字节流，
在 `LISTEN` 里收到 SYN 要回 SYN-ACK，在 `SYN_SENT` 里收到 SYN 要回 ACK，
在 `ESTABLISHED` 里收到 FIN 要先回 ACK 再交给应用，在 `TIME_WAIT` 里
收到 FIN 却只重发 ACK 并重置 2MSL。**同样的输入，答案取决于状态**。

这意味着状态机不能写成“一串 if”，而要先定义一个封闭的状态集合。
本工程的 `tcp.State` 与 lwIP 的 `enum tcp_state`
（`components/lwip/lwip/src/include/lwip/tcpbase.h:56-67`）逐项一致：

```text
CLOSED(0)  LISTEN(1)  SYN_SENT(2)  SYN_RCVD(3)  ESTABLISHED(4)
FIN_WAIT_1(5)  FIN_WAIT_2(6)  CLOSE_WAIT(7)  CLOSING(8)  LAST_ACK(9)  TIME_WAIT(10)
```

按 lwIP 的编号顺序（`tcpbase.h:70` 的 `TCP_STATE_IS_CLOSING` 依赖它），
“正在关闭”就是从 `FIN_WAIT_1` 起的全部状态。本章不依赖编号，
但保留同样的顺序，方便与源码对照。

### 20.1.2 两个时间尺度

TCP 至少有两个互不相干的时间：

1. **RTO**（retransmission timeout）：毫秒到秒级，随 RTT 变化，超时要重发；
2. **2MSL**：固定 60 秒（MSL 取 30 秒），到点才能释放那个四元组。

如果用一个“全局 tick 计数器”硬编码两件事，测试会变成“跑 60 秒等结果”。
本章的做法是把**时间作为参数注入**：`tick(now_us)`、`onSegment(seg, now_us)`、
`appClose(now_us)`。自检传常数，于是 60 秒的 TIME_WAIT 在两次函数调用里
就走完了。这不是“作弊”，而是把时间从实现细节提升为接口——ch15 的
可测试性原则在这里第一次真正兑现。

### 20.1.3 内存是有界的

TCP 必须能接住乱序到达的段，否则一个重排就会触发不必要的重传。
但“接住”意味着缓冲，而裸机没有 `malloc` 的余地（ch13 已经把堆的代价算过）。
本章的答案是**固定槽**：`Reasm` 有 4 个槽，每个 512 字节，满了就丢最老
的一段，并计入 `dropped`。丢段的正确后果不是“连接坏了”，而是“对端按
累积 ACK 重传”——协议本身会把有界缓冲的代价吸收掉。

### 20.1.4 三个不变量

整章代码围着三条不变量转，后面每一节都在给其中一条加证据：

| 不变量                                     | 含义                     | 被谁守住                       |
| ------------------------------------------ | ------------------------ | ------------------------------ |
| `snd_una <= snd_nxt <= snd_max`（模空间）  | 已确认 ≤ 已发送 ≤ 曾发送 | `Conn.processAck` / `sendData` |
| 交付给应用的是 `[rcv_nxt, ...)` 的连续前缀 | 不乱序交付、不重复交付   | `Reasm.insert`                 |
| 任何状态下 RST 都直接回 `CLOSED`           | 复位是“立刻生效”，不排队 | `Conn.onSegment` 的第一分支    |

---

## 20.2 首部逐字段：20 字节定长 + 最多 40 字节选项

TCP 首部是“定长部分 + 变长选项”的经典结构。定长部分 20 字节
（`TCP_HLEN`，`components/lwip/lwip/src/include/lwip/prot/tcp.h:47`），
选项最多 40 字节（`TCP_MAX_OPTION_BYTES`，同文件 `:83`），因此
data offset 的合法范围是 5..15。

lwIP 的 `struct tcp_hdr`（`tcp.h:56-64`）只有 8 个字段；注意第 5 个字段
`_hdrlen_rsvd_flags` 是一个 16 位字，高 4 位是首部长度、低 8 位是标志：

```c
struct tcp_hdr {
  PACK_STRUCT_FIELD(u16_t src);
  PACK_STRUCT_FIELD(u16_t dest);
  PACK_STRUCT_FIELD(u32_t seqno);
  PACK_STRUCT_FIELD(u32_t ackno);
  PACK_STRUCT_FIELD(u16_t _hdrlen_rsvd_flags);
  PACK_STRUCT_FIELD(u16_t wnd);
  PACK_STRUCT_FIELD(u16_t chksum);
  PACK_STRUCT_FIELD(u16_t urgp);
} PACK_STRUCT_STRUCT;
```

本章的 `tcp.Header` 把它展开成 10 个逻辑字段（`src/tcp.zig` 的
`pub const Header`），因为状态机关心的是 `data_offset` 与 `flags`，
而不是那个打包字。逐字段：

| 偏移 | 长度  | 字段          | 语义               | 本章的实现要点              |
| ---- | ----- | ------------- | ------------------ | --------------------------- |
| 0    | 2     | `src_port`    | 源端口             | 大端读写；不参与状态判断    |
| 2    | 2     | `dst_port`    | 目的端口           | 四元组的一半，由调用方匹配  |
| 4    | 4     | `seq`         | 本段首字节的序列号 | SYN/FIN 各占 1 个序号       |
| 8    | 4     | `ack`         | 期望对方下一个字节 | 只有 ACK 置位时有效         |
| 12   | 4 bit | `data_offset` | 首部长度 / 4       | 必须 ≥5；>15 即 60 字节封顶 |
| 12   | 4 bit | reserved      | 保留               | 解析时忽略，编码写 0        |
| 13   | 8 bit | `flags`       | 8 个控制位         | LSB 在前，见下表            |
| 14   | 2     | `window`      | 接收窗口           | 只记录，不做窗口管理        |
| 16   | 2     | `checksum`    | 伪首部 + 段        | 必须计算并校验              |
| 18   | 2     | `urgent`      | 紧急指针           | 本章不实现 URG              |

标志位与 lwIP 的 `TCP_FIN..TCP_CWR`（`tcp.h:72-79`）逐位一致，
`TCP_FLAGS` 掩码是 `0x3f`（`tcp.h:81`）：

| bit | 名称 | 含义               | 本章用到   |
| --- | ---- | ------------------ | ---------- |
| 0   | FIN  | 发送方没有更多数据 | 是         |
| 1   | SYN  | 同步序列号         | 是         |
| 2   | RST  | 复位连接           | 是         |
| 3   | PSH  | 尽快交付应用       | 编码时置位 |
| 4   | ACK  | `ack` 字段有效     | 是         |
| 5   | URG  | 紧急指针有效       | 否         |
| 6   | ECE  | ECN-Echo           | 否（ch21） |
| 7   | CWR  | 拥塞窗口减小       | 否（ch21） |

`tcp.Flags` 是一个 `packed struct(u8)`，字段顺序从 `fin` 开始——
这正是“LSB 在前”的写法。`toByte` 用 `@bitCast`，`fromByte` 反向，
不需要手写移位。

### 20.2.1 选项：MSS、WS、SACK-permitted

选项区是 TLV（type-length-value），只有两个 kind 是单字节：0（EOL）与
1（NOP）。本章只处理三种：

| kind | 名称           | 长度           | 本章行为                            |
| ---- | -------------- | -------------- | ----------------------------------- |
| 2    | MSS            | 4              | 解析并采用（影响分段大小）          |
| 3    | Window Scale   | 3              | 解析并记录，**不应用**（ch21）      |
| 4    | SACK-permitted | 2              | 解析并记录，**不实现 SACK**（ch21） |
| 其他 | —              | 由长度字节给出 | 按长度跳过                          |

“按长度跳过”不是偷懒，而是 RFC 9293 对接收方的要求：不认识就跳过，
不能因为多一个选项就断连。本章的 `parseOptions` 还多做了一件事：
**校验长度**。MSS 必须是 4，WS 必须是 3 且 shift ≤ 14，SACK 必须是 2；
任何一个不合法就返回 `error.BadOption`，而不是继续按错位的长度游走。

编码侧（`tcp.encode`）的 `data_offset` **不是调用方给的**：它由选项集
唯一决定：

```zig
const opt_len = optionsByteLen(opts);
const hlen = MIN_HEADER + opt_len;
if (hlen > MAX_HEADER) return error.BadOption;
hdr.data_offset = @intCast(hlen / 4);
```

这条规则消灭了一整类 bug：手写 `data_offset` 与选项长度不一致时，
对端会把载荷的第一个字节当成选项。板侧判据 `options … hdr=32B roundtrip=1`
就是在钉这条规则：MSS(4) + WS(4) + SACK(2) = 10，向上取整到 12，
20 + 12 = 32 字节，`data_offset = 8`。

`optionsByteLen` 里 WS 也是 4 而不是 3，因为要补一个 NOP 让下一个选项
落在 4 字节边界上；最后的 `(n + 3) & ~3` 再做一次全局对齐。

---

## 20.3 seq/ack 算术：2^32 是一个圆，不是一条线

### 20.3.1 为什么不能用 `<`

假设连接的起始序列号是 `0xFFFFFF00`，发了 0x200 字节之后，
`seq` 回绕到 `0x00000100`。此时：

- 用无符号 `<` 比较：`0x100 < 0xFFFFFF00`，结论是“新段比老段早”；
- 正确的结论：新段在 0x200 字节之后。

序列号是模 2^32 的**循环空间**，比较必须看“沿哪个方向走得近”。
RFC 1982 给出了严格定义（本章 20.3.2），而“半程规则”是它的直观版：
以 `a` 为起点，若 `b` 落在前半个圆内（距离 < 2^31），则 `b` 在 `a` 之后。

### 20.3.2 严格形式与半程边界

本章的 `seqLt` 按 RFC 1982 写：

```zig
pub fn seqLt(a: u32, b: u32) bool {
    if (a == b) return false;
    if (a < b) return (b - a) < 0x8000_0000;
    return (a - b) > 0x8000_0000;
}
```

相差正好 2^31 时，两个方向都返回 false——这是 RFC 1982 §3.2 的
“未定义区”，实现必须选一个确定行为，本章选择“都不算之后”。

有趣的是，lwIP 的选择不同。它的宏
（`components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:109`）：

```c
#define TCP_SEQ_LT(a,b) (((u32_t)((u32_t)(a) - (u32_t)(b)) & 0x80000000u) != 0)
```

只取差值的最高位。差值恰为 `0x80000000` 时最高位是 1，于是
`TCP_SEQ_LT(0, 0x80000000)` 在 lwIP 里为真，在本章为假。
两者在真实连接里都不会走到这个点（窗口远小于 2^31），但写测试时
必须知道自己的实现选的是哪一边：板侧判据
`seq wrap 0xfffffff0<0x10=1 diff=0x20` 只覆盖回绕方向，
主机侧另外钉了 `!seqLt(0, 0x8000_0000)` 这条边界。

`seqDiff` 仍然保留，但只用于日志与“挑最老槽”这种排序键——
它的返回值在差值恰为 2^31 时是 `i32` 的 MIN，符号没有意义。
把“给人看的距离”和“给协议用的先后”分成两个函数，是本章刻意的取舍。

### 20.3.3 序号空间里谁占一个字节

| 东西   | 占几个序号         |
| ------ | ------------------ |
| 数据   | 每个字节 1 个      |
| SYN    | 1 个（在数据之前） |
| FIN    | 1 个（在数据之后） |
| 纯 ACK | 0 个               |

因此 `Segment.seqLen()` 是“载荷长度 + SYN + FIN”，而
`rcv_nxt` 的推进必须用同一个公式。数据路径上只有两处**相对推进**
`rcv_nxt`：

1. 收到数据：`rcv_nxt = h.seq + payload.len`（仅当段覆盖 `rcv_nxt`）；
2. 收到 FIN：`rcv_nxt +%= 1`。

握手（`rcv_nxt = h.seq + 1`）与 `TIME_WAIT` 里的赋值是**绝对定位**，
不依赖旧值——但它们同样遵守“SYN/FIN 各占一个序号”的规则。这几处加起来
的效果就是“同一段重传两次，`rcv_nxt` 只前进一次”。

### 20.3.4 回绕的测试

```text
起始:  seq = 0xFFFFFFF0, 发送 0x20 字节
结束:  seq = 0x00000010
判据:  seqLt(0xFFFFFFF0, 0x10) == true
       seqDiff(0x10, 0xFFFFFFF0) == 0x20
```

板侧与主机侧都跑了这一条。它不是“理论边界”：一个长期运行的连接
（每字节一个序号）在 4 GiB 流量之后必然回绕，而 4 GiB 对今天的网络
只是一个下午。

---

## 20.4 三次握手与同时打开

### 20.4.1 主动打开：CLOSED → SYN_SENT → ESTABLISHED

```text
客户端                                 服务端
  CLOSED
    |  activeOpen(iss)          --> 发 SYN(seq=iss)
    v
  SYN_SENT
    |                             <-- 收 SYN+ACK(seq=sis, ack=iss+1)
    |  验证 ack == snd_max(iss+1)
    |  rcv_nxt = sis+1, snd_una = iss+1
    v
  ESTABLISHED                 --> 发 ACK(seq=iss+1, ack=sis+1)
```

本章的 `Conn.activeOpen` 只做三件事：置 `iss`、把 `snd_nxt/snd_max`
推进到 `iss+1`（SYN 占一个序号）、启动重传计时器。它不“等”，
因为板上没有调度器——返回一个 `Action`，由调用方把描述变成真正的段。

`SYN_SENT` 收到 SYN-ACK 时有两个必须校验的条件：

1. `h.flags.syn and h.flags.ack`：否则可能是同时打开（见 20.4.3）；
2. `h.ack == self.snd_max`：确认的是我们刚发的那个 SYN。

少任何一个校验都会让一个伪造的段把连接推进到 `ESTABLISHED`。
这也是为什么 `Action` 里要带 `seq` 与 `ack`：调用方不需要再猜。

### 20.4.2 被动打开：LISTEN → SYN_RCVD → ESTABLISHED

```text
服务端                                 客户端
  LISTEN(iss)
    |                             <-- 收 SYN(seq=cis)
    |  rcv_nxt = cis+1
    |  mss = 对端 MSS 选项（缺省 536）
    v
  SYN_RCVD                    --> 发 SYN+ACK(seq=iss, ack=cis+1)
    |                             <-- 收 ACK(ack=iss+1)
    |  验证 ack == snd_max
    v
  ESTABLISHED
```

第三次握手**不带数据时不回包**——这是本章 `onSegment` 在
`SYN_RCVD` 分支里返回空 `Action` 的原因。很多实现会在这里多发一个
无意义的 ACK，结果是在抓包里出现“四次握手”的假象。

### 20.4.3 同时打开：RFC 的路径，本章没有实现

RFC 9293 §3.5 的 simultaneous open 与常规握手是**两条不同的边**：

```text
  A: SYN_SENT                        B: SYN_SENT
  A --> SYN(seq=a)                   B --> SYN(seq=b)
  A <-- SYN(seq=b)     裸 SYN，不带 ACK
  A: SYN_RCVD          回 SYN+ACK
  B: SYN_RCVD          回 SYN+ACK
  双方再收对方的 SYN+ACK → ESTABLISHED
```

关键在第二步：`SYN_SENT` 状态下收到的是一枚**裸 SYN**（`syn=1, ack=0`），
而不是 SYN+ACK。常规握手的 `SYN_SENT` 分支只认 `syn && ack &&
ack == snd_max`，因此裸 SYN 在这里必须走另一条边。

**本章没有实现这条路**：`syn_sent` 分支不匹配裸 SYN，直接返回空
`Action`（相当于忽略）。这是一个明确的边界，列在 20.12。lwIP 的
`SYN_SENT` 分支（`components/lwip/lwip/src/core/tcp_in.c:877-940`）
同样只处理 `SYN+ACK` 与“带 ACK 的半开连接”两种情况，也没有裸 SYN 分支——
所以“不实现同时打开”并不是本章独有的偷懒，而是这条路径在真实部署里
极少出现（两端必须几乎同时向对方发起连接）。

### 20.4.4 CLOSING：属于关闭阶段，不是握手

双方同时发 FIN 时会出现另一个竞争状态 `CLOSING`。它和同时打开无关，
放在 20.5 讲更合适；这里只留一句：`CLOSING` 的判据是“收到对方 FIN，
但我方 FIN 还没被 ACK”，本章的 `fin_wait_1` 分支用 `fin_acked` 区分。

### 20.4.5 握手期间的 RTO

SYN 也会丢，也要重传。本章在 `activeOpen` 与收到 SYN 时都启动
`TxTimer`；`tick` 在 `SYN_SENT` 状态下重发 SYN、在 `SYN_RCVD` 状态下
重发 SYN+ACK。注意重传的是**同一个 iss**，不能换序列号——否则对端会
把它当成两个连接。

---

## 20.5 关闭：四次挥手、TIME_WAIT 与 2MSL

### 20.5.1 为什么是四次

TCP 是全双工的：两个方向各自独立关闭。于是“关闭一个连接”需要
四件事，且可以交错：

```text
  A: ESTABLISHED
  A --> FIN                       (1) A 不再发数据
  B: CLOSE_WAIT   --> ACK         (2) B 确认，但 B 可能还有数据要发
  B --> FIN                       (3) B 也不发了
  A: LAST_ACK? 不 —— A 是主动方，走 FIN_WAIT_2 → TIME_WAIT
  A --> ACK                       (4) 确认 B 的 FIN
```

被动方（B）的顺序是 `ESTABLISHED → CLOSE_WAIT → LAST_ACK → CLOSED`；
主动方（A）是 `ESTABLISHED → FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT → CLOSED`。
两个方向都可能出现“半关闭”：A 发了 FIN，但 B 还在发数据，
此时 A 处于 `FIN_WAIT_2`，仍然**接收**数据。

本章的状态机没有实现半关闭的数据接收路径（`fin_wait_2` 分支只处理 FIN），
这是刻意的范围收缩，写在 20.12。

### 20.5.2 同时关闭与 CLOSING

双方几乎同时调用 `close()` 时，会出现“我发了 FIN、对方也发了 FIN，
但我的 FIN 还没被确认”的窗口：

```text
  FIN_WAIT_1
    |  收 FIN（且 h.ack 尚未覆盖我方 FIN）
    v
  CLOSING                   --> 回 ACK
    |  收 ACK(ack == snd_max)
    v
  TIME_WAIT
```

`CLOSING` 与 `FIN_WAIT_1` 的区别只有一个：**对方的 FIN 与对我方 FIN
的 ACK 谁先到**。本章的 `fin_wait_1` 分支用 `fin_acked` 把两者分开：

```zig
const fin_acked = h.flags.ack and h.ack == self.snd_max;
if (h.flags.fin) {
    self.rcv_nxt +%= 1;
    if (fin_acked) { self.state = .time_wait; ... } else { self.state = .closing; }
}
```

主机侧用例 `tcp: 同时关闭走 CLOSING（双方 FIN 竞争）` 覆盖了这条边：
先正常建立，再让 `appClose` 与对端 FIN 竞争。注意它与 20.4.3 的
“同时打开”是两回事——`CLOSING` 发生在关闭阶段，握手已经完成。

### 20.5.3 TIME_WAIT 到底在等什么

主动关闭方在发出最后一个 ACK 后进入 `TIME_WAIT`，等 2MSL 才释放
（RFC 9293 §3.6.1 的 MUST-13；状态处理见 §3.10.7.4）。两个理由：

1. **让最后的 ACK 有机会重发**：如果那个 ACK 丢了，被动方会重传 FIN；
   还在 `TIME_WAIT` 的一方可以再回一个 ACK，而不是回 RST。
2. **让旧连接的迟到段在网络里消亡**：2MSL 保证同一个四元组的新连接
   不会收到上一个连接的残留段。

lwIP 的实现可以对照：`tcp.c:1386` 用
`(tcp_ticks - pcb->tmr) > 2 * TCP_MSL / TCP_SLOW_INTERVAL`
判断 `TIME_WAIT` 是否到期，而 `TCP_MSL` 缺省是 60000 毫秒
（`components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:137-138`）。
也就是说，lwIP 把 `TCP_MSL` 配成 60 秒还要再乘 2，实际等待 **120 秒**；
ESP-IDF 把它暴露成 `CONFIG_LWIP_TCP_MSL`
（`components/lwip/port/include/lwipopts.h:670`），可以在 menuconfig 里改。
本章为演示取 MSL = 30 秒（RFC 9293 §3.4.2 的规范取值是 2 分钟，
并明确写着这是 engineering choice；lwIP 缺省配成 60 秒），
于是 `TIME_WAIT_US` 是 60 秒。三者的差异是**配置选择**，不是协议错误：
规范只要求“足够长”，具体秒数由实现决定。

### 20.5.4 用注入时钟验 60 秒

本章的 `TIME_WAIT_US = 2 * MSL_US = 60_000_000`。自检里没有任何
`sleep`：

```zig
self.time_wait_until_us = now_us + TIME_WAIT_US;
...
// 自检：差 1 µs 还在 TIME_WAIT；到点才回 CLOSED
_ = conn.tick(3_000 + tcp.TIME_WAIT_US - 1);
_ = conn.tick(3_000 + tcp.TIME_WAIT_US);
```

板侧判据 `close active FIN_WAIT_1->2->TIME_WAIT 2msl=60000000us closed=1`
就是这两次调用的结果。它证明的是**判定逻辑**，不是“板子真的等了 60 秒”。

### 20.5.5 TIME_WAIT 里收到重传 FIN

如果对方的 FIN 重传了，`TIME_WAIT` 必须重发 ACK 并**重置 2MSL**。
本章的 `time_wait` 分支：

```zig
if (h.flags.fin) {
    self.rcv_nxt = h.seq +% 1;
    self.time_wait_until_us = now_us + TIME_WAIT_US;
    self.last = .{ .send = true, .seq = self.snd_nxt, .ack = self.rcv_nxt, ... };
}
```

主机侧用例 `tcp: TIME_WAIT 里收到重传 FIN 会重发 ACK 并重置 2MSL`
断言了 `time_wait_until_us` 变大。这条规则的价值在于：它把
“ACK 丢失”从“连接卡死”降级为“多等一个 2MSL”。

### 20.5.6 RST：唯一不需要状态机的迁移

任何状态收到 RST 都立刻回 `CLOSED`，清空未确认数据，停表，不回包。
本章把它放在 `onSegment` 的第一个分支，先于所有状态判断：

```zig
if (h.flags.rst) {
    self.state = .closed;
    self.timer.stop();
    self.unacked_len = 0;
    self.last = .{ .to = .closed };
    return self.last;
}
```

板侧判据 `rst state=CLOSED replied=0 timer=off` 与主机侧
“从 ESTABLISHED 收到 RST 也立刻关闭（丢弃未确认数据）”各钉一遍。

---

## 20.6 RTO 估计：RFC 6298 的四个数字

### 20.6.1 公式与常数

RFC 6298 要维护三个量：`SRTT`（平滑 RTT）、`RTTVAR`（RTT 偏差）、
`RTO`（超时时间）。规则见 §2 的 (2.1)–(2.5)：

| 步骤       | 公式                                   | 规则号      | 本章常数 |
| ---------- | -------------------------------------- | ----------- | -------- |
| 初始值     | 尚无样本时 `RTO = 1 s`                 | (2.1)       | 1 s      |
| 第一次测量 | `SRTT = R`；`RTTVAR = R/2`             | (2.2)       | —        |
| 后续测量   | `RTTVAR = (1-β)·RTTVAR + β·\|SRTT-R\|` | (2.3)       | β = 1/4  |
| 后续测量   | `SRTT = (1-α)·SRTT + α·R`              | (2.3)       | α = 1/8  |
| 计算 RTO   | `RTO = SRTT + max(G, K·RTTVAR)`        | (2.2)/(2.3) | K = 4    |
| 下限       | `RTO < 1 s → 1 s`                      | (2.4)       | 1 s      |
| 上限       | `RTO > 60 s → 60 s`                    | (2.5)       | 60 s     |

用整数实现时，α=1/8 与 β=1/4 正好是“除以 8”和“除以 4”：

```zig
self.rttvar_us = (3 * self.rttvar_us + diff) / 4;
self.srtt_us = (7 * self.srtt_us + rtt_us) / 8;
self.rto_us = clampRto(self.srtt_us + RTO_K * self.rttvar_us);
```

### 20.6.2 K=4 是从哪来的

`RTO = SRTT + 4·RTTVAR` 不是随手取的。RTT 的分布通常右偏，
`RTTVAR` 作为平均绝对偏差（MAD）近似标准差；在正态假设下，
`SRTT + 4·σ` 覆盖约 99.99% 的样本。K 取 4 意味着“只在极端异常时才
误判超时”，代价是丢包恢复变慢。K=2 会更灵敏但更容易伪超时，
K=4 是 Jacobson/Karels 之后的工程折中。

lwIP 把这个 4 藏进了变量的缩放里：`pcb->sa` 存的是 `8·SRTT`、
`pcb->sv` 存的是 `4·RTTVAR`，于是
`pcb->rto = (pcb->sa >> 3) + pcb->sv`
正好等于 `SRTT + 4·RTTVAR`
（`components/lwip/lwip/src/core/tcp_in.c:1366-1387`）。
读那段代码时容易误以为“lwIP 只用 1 倍 RTTVAR”，其实是缩放。

两者的初始值不同：lwIP 的 `LWIP_TCP_RTO_TIME` 缺省 3000 ms
（`components/lwip/lwip/src/include/lwip/opt.h:1384`，
ESP-IDF 暴露为 `CONFIG_LWIP_TCP_RTO_TIME`，
`components/lwip/port/include/lwipopts.h:698`），而 RFC 6298 的规则 (2.1)
要求初始 1 秒。本章按 RFC 取 1 秒——这是一个**可观测的差异**：
同样的丢包场景，lwIP 第一次重传要等 3 秒，本章等 1 秒。
RFC 6298 的规则 (2.1) 也明确允许继续用 3 秒（“MAY still use this
value”），所以这不是 lwIP 的 bug，而是两种合规的保守程度。

### 20.6.3 Karn 算法：重传过的段不给样本

如果一段被重传过，你就不知道收到的 ACK 确认的是第一次发送还是第二次，
RTT 样本会把估计值拉向错误的方向。Karn 的规则是：**重传过的段不取样**
（RFC 6298 §3：“TCP MUST use Karn's algorithm”）。

lwIP 的写法是 `pcb->rttest = 0`：只在没有在途测量时记录
（`tcp_out.c:1542-1543`），一旦发生 RTO 重传就清掉
（`tcp_out.c:1676-1677` 的 `/* Don't take any RTT measurements after
retransmitting. */`）。本章用一个布尔量：

```zig
pub fn sampleRtt(self: *Conn, rtt_us: u64) bool {
    if (self.retransmit_happened) return false;
    self.rto.sample(rtt_us);
    return true;
}
```

`retransmit_happened` 在 `sendData` 时清零、在 `tick` 真正重传时置位。
板侧判据 `rto … retrans=1` 里同时断言了 `!conn.sampleRtt(500)`——
即重传之后递进来的样本必须被拒绝，且 RTO 不变。

### 20.6.4 数字代入：为什么板侧打印 6 s 与 12 s

自检先给一个 2 秒的 RTT 样本（第一次测量）：

```text
SRTT    = 2.000000 s
RTTVAR  = 1.000000 s
RTO     = 2 + 4×1 = 6.000000 s
```

随后发 100 字节但“丢了”，在 `now = 1_000 + 6_000_000 µs` 时
`tick` 触发重传，`backoff()` 把 RTO 翻倍到 12 秒。板侧实际输出：

```text
check: rto srtt=2000000us rttvar=1000000us first_rto=6000000us backoff=12000000us retrans=1 ok=1
```

这些数字全部来自 `Rto` 的整数运算，没有浮点，也没有平台相关的
`@sizeOf(usize)` 依赖。

---

## 20.7 重传与乱序重组：单段模型的上限与下限

### 20.7.1 为什么先做“单段”

真实的 TCP 发送方有一个**发送窗口**：多段同时在途，ACK 可以部分确认。
本章刻意只允许**一段在途**（`unacked_len` 只有一个数）：

- 好处：状态机只有一条计时器，`snd_una` 的推进只有“全确认/部分确认”
  两条路径，所有不变量都能在自检里断言；
- 代价：吞吐被锁死在 `MSS / RTT`，而且无法验证 SACK 的选择性重传；
- 这正是 ch21 的入口：拥塞控制与窗口管理必须一起做，单独做其中一个
  会得到“有窗口但没有 ACK 时钟”的半成品。

单段模型下，`tick` 的重传是 go-back-N 的退化形式：

```zig
.established, .close_wait => .{
    .send = true, .retransmit = true,
    .seq = self.snd_una, .ack = self.rcv_nxt,
    .flags = .{ .ack = true, .psh = true },
    .payload_len = self.unacked_len,
    .to = self.state,
},
```

从 `snd_una` 重发，而不是从 `snd_nxt`——这一点与“超时后从当前发送位置
继续”是两回事，写错会导致对端永远收不齐缺口。

### 20.7.2 重复 ACK 与快速重传

重复 ACK 的判据（lwIP 的注释列了五条，
`components/lwip/lwip/src/core/tcp_in.c:1205-1225`）：不确认新数据、
无载荷、窗口未变、有未确认数据、等于 `snd_una`。本章实现了其中最关键的
三条（无载荷、等于 `snd_una`、确有未确认数据）：

```zig
if (ack == self.snd_una and self.snd_una != self.snd_max) {
    self.dup_acks +|= 1;
}
```

第三个重复 ACK 触发一次快速重传，**不改变 RTO**（RFC 5681 的
fast retransmit 不进入退避）。lwIP 在 `tcp_in.c:1243-1246` 用
`pcb->dupacks >= 3` 判断，本章用 `self.dup_acks >= 3`，语义一致。

为什么是 3 而不是 1？一个重复 ACK 可能只是乱序；两个还可能是抖动；
三个重复 ACK 意味着至少有一个段确定缺失，而此时“等 RTO”会浪费
一个完整的超时周期。

### 20.7.3 有界重组：4 个槽怎么选

`Reasm` 的设计只有三条规则：

1. **只交付连续前缀**：`seq == expect` 才交付，交付后继续吸收
   `seq == 新 expect` 的槽；
2. **老段裁掉前缀**：`seq < expect` 时按 `expect - seq` 裁掉已交付部分，
   整段都旧就丢弃；
3. **未来段进槽，槽满丢最老**：4 个槽、每个 512 字节；满了就按
   `seqLt` 找最小 `seq` 的槽覆盖，`dropped += 1`。

第 3 条的选择值得说明：丢“最老”而不是“最新”，是因为最老的段离
`expect` 最近，最有可能在下一个段到达后立刻被用上；丢最新则会制造
更大的缺口。lwIP 的对应策略是“不无限期保存乱序数据”：当乱序队列存在
且连接已经 `TCP_OOSEQ_TIMEOUT × RTO` 没有活动时，整个乱序队列被释放，
注释写明“它最终会被重传”
（`components/lwip/lwip/src/core/tcp.c:1366-1373`，
`TCP_OOSEQ_TIMEOUT` 缺省 6，见
`components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:133-134`）。
本章没有超时释放，只有槽位覆盖——更简单，也更保守。

板侧判据 `reasm out_of_order late=0 delivered=200 identical=1`：
后段先到（`late=0` 表示这次插入没有交付任何字节），前段到达后一次
交付 200 字节，且与原始载荷逐字节相同。主机侧还钉了“槽满丢最老”的计数。

### 20.7.4 重组的交付缓冲不是重组器自己的

`insert(seq, data, out)` 的 `out` 是调用方给的。这看起来啰嗦，但它是
“零拷贝”与“有界内存”的折中：重组器只持有槽里的**副本**（因为段可能
被上层释放），而交付时写进应用缓冲。ch16 的 `pbuf` 链表可以把“段”本身
挂进队列而不复制，本章不用它——单段模型里复制的成本可以忽略，
而链表的复杂度会掩盖状态机本身的错误。

---

## 20.8 校验和与伪首部

### 20.8.1 伪首部不是可选项

UDP 的校验和字段为 0 表示“发送方没算”（RFC 768），接收方必须放行；
TCP **没有这个豁免**：字段必须有效，接收方必须校验
（RFC 9293 §3.1）。lwIP 在 `tcp_in.c:173-177` 直接调
`ip_chksum_pseudo(p, IP_PROTO_TCP, p->tot_len, ...)`，结果不为 0 就丢弃。

伪首部是 12 字节：源地址 4 + 目的地址 4 + `0x00` + 协议号 6 + TCP 长度 2。
它不随段传输，只参与计算。最容易错的两处：

1. **长度**：是 TCP 段总长（首部 + 载荷），不是 IP 总长；
2. **协议号**：TCP 是 6，UDP 是 17。

### 20.8.2 RFC 1071 的加法

16 位反码和的核心是“按大端两两成组、逐字相加、进位回卷、最后取反”。
本章的 `Sum` 支持**跨片连续**：一个 3 字节的片与下一个 5 字节的片，
中间那个字节必须与下一片的第一个字节配对。`odd` 字段记住落单的高字节：

```zig
if (self.odd) |hi| {
    self.absorb((@as(u16, hi) << 8) | bytes[0]);
    i = 1;
    self.odd = null;
}
```

`s.finish()` 返回的是“可以写进首部”的值；把首部连同校验和字段一起
再算一次，结果必须是 0——这就是 `verifyTcp` 的判据。

### 20.8.3 已知向量

本章用 ch16 测试里同一个 SYN 段作为交叉验证：

```text
sport=8080 dport=80 seq=1 ack=0 offset=5 flags=SYN window=8192
src=192.168.1.10 dst=192.168.1.1
期望校验和 = 0xeca5
```

两个**独立实现**（ch16 的 `checksum.zig` 与本章的 `checksum.zig`）
得到同一个值，才有资格说“这个向量是对的”。板侧实际输出：

```text
check: checksum syn_seg=0xeca5 verify=1 known=0xeca5 ok=1
```

`verify=1` 是“把校验和写回去再整体验证为 0”。`fillTcp` 在写入前
先清零校验和字段，因此重复调用是安全的（不会把上次的结果算进去）。

### 20.8.4 三个校验和的差别

| 协议      | 覆盖范围             | 0 的语义             | 计算为 0 时     |
| --------- | -------------------- | -------------------- | --------------- |
| IPv4 首部 | 首部（含选项）       | 合法值               | 就发 0          |
| UDP       | 伪首部 + 首部 + 载荷 | “未计算”，接收方放行 | 必须发 `0xFFFF` |
| TCP       | 伪首部 + 首部 + 载荷 | 合法值（没有豁免）   | 就发 0          |

这张表在 ch16/ch18/ch19 各出现过一次，本章仍然重复——因为它是
“同一个算法、三种语义”的最短总结，而混淆 UDP 与 TCP 的 0 规则
是协议栈里最常见的移植 bug。

---

## 20.9 工程走读

### 20.9.1 目录与数据流

```text
src/start.zig      _start: 关中断 → 设 sp/gp → 关 WDT → 清 bss → mtvec → main
      |
      v
src/main.zig       banner + selftest.run() + verdict + wfi
      |
      +--> src/selftest.zig   造段（.bss 字节数组）→ tcp.parse → Conn.onSegment
      |         |                                   → tcp.encode → checksum.fillTcp
      |         +--> src/tcp.zig       状态机 / RTO / 重组 / 分段
      |         +--> src/checksum.zig  伪首部 + RFC 1071
      |
      +--> src/trap.zig / src/hw.zig / src/log.zig   失败现场与串口
```

主机侧的数据流更短：`host_tests.zig` 只 import `tcp.zig` 与
`checksum.zig`，完全不碰 `start.zig`/`hw.zig`/`trap.zig`。这条边界
保证了 `zig build test` 在 x86_64 上能跑——如果测试文件 import 了
`start.zig`，`@compileError` 会因为架构不是 riscv32 而立即触发。

### 20.9.2 关键类型

| 类型      | 作用                   | 不变量                                 |
| --------- | ---------------------- | -------------------------------------- |
| `Header`  | 20 字节定长字段        | `data_offset >= 5`，`len() = offset*4` |
| `Options` | MSS/WS/SACK 的解析结果 | 长度已校验，`bytes` 是 4 的倍数        |
| `Segment` | 首部 + 选项 + 载荷切片 | `payload` 指向输入缓冲，不拥有内存     |
| `Flags`   | 8 个控制位             | LSB 在前，`@bitCast` 双向              |
| `Rto`     | SRTT/RTTVAR/RTO        | RTO ∈ [1 s, 60 s]                      |
| `TxTimer` | 单段重传计时器         | `expired(now)` 只在 active 时有意义    |
| `Reasm`   | 4 槽乱序重组           | 只交付连续前缀，缓冲有上限             |
| `Conn`    | 11 状态机              | 三条不变量见 20.1.4                    |
| `Action`  | “该发什么”的描述       | 不含端口/选项，由连接固定              |

### 20.9.3 一次完整的“收段 → 回段”要经过什么

以 `ESTABLISHED` 收到一个带数据的段为例：

1. `tcp.parse(buf)`：校验长度、`data_offset`、选项，切出载荷；
2. `conn.onSegment(seg, now)`：
   - `processAck` 处理 ACK（推进 `snd_una`、停表、清重复计数）；
   - 用 `seqLeq(h.seq, rcv_nxt)` 判断段是否覆盖当前缺口；
   - 推进 `rcv_nxt`，返回 `Action{send=true, ack=rcv_nxt}`；
3. 调用方按 `Action` 用 `tcp.encode` 造一个 20 字节的纯 ACK；
4. `checksum.fillTcp(src, dst, seg)` 填伪首部校验和。

这四步里，只有第 3、4 步与“真实网络”有关；前两步是纯函数式的，
所以能在主机侧用内存数组跑到饱。

### 20.9.4 浏览页深链

| 文件                 | 职责                                                                           |
| -------------------- | ------------------------------------------------------------------------------ |
| `build.zig`          | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/build.zig)          |
| `linker/s31.ld`      | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/linker/s31.ld)      |
| `src/tcp.zig`        | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/tcp.zig)        |
| `src/checksum.zig`   | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/checksum.zig)   |
| `src/selftest.zig`   | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/selftest.zig)   |
| `src/host_tests.zig` | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/host_tests.zig) |
| `src/main.zig`       | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/main.zig)       |
| `src/start.zig`      | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/start.zig)      |
| `src/hw.zig`         | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/hw.zig)         |
| `src/trap.zig`       | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/trap.zig)       |
| `src/log.zig`        | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/src/log.zig)        |
| `tools/flash.sh`     | [查看](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/tools/flash.sh)     |

[完整工程](/static/code/#/zig-esp32-s31/ch20-tcp-state-machine/)

表里的深链由 `node scripts/gen-code-site.mjs` 生成；新增文件后要重跑一次，
`/static/code/` 下才会出现对应叶子。

### 20.9.5 与 ch16 的关系

ch16 的 `headers.zig:224-260` 已经有一个 `Tcp` 结构，含
`min_len = 20`、8 个字段、`write`/`parse`。本章的 `tcp.zig` 是它的
**超集**，不是替代：

| 能力               | ch16 `headers.Tcp`  | 本章 `tcp.Segment`  |
| ------------------ | ------------------- | ------------------- |
| 20 字节定长首部    | 有                  | 有                  |
| 选项解析           | 无                  | MSS/WS/SACK         |
| 载荷切片           | 无（只到首部）      | 有                  |
| 校验和             | ch16 `checksum.tcp` | 本章 `checksum.tcp` |
| 状态机/定时器/重组 | 无                  | 有                  |

为什么不 `@import` ch16 的 `headers.zig`？理由与 ch18 的 `inet.zig`
相同：**每一章必须能单独 `zig build`**。跨工程的 import 会把
“这一章到底依赖哪一版结构”变成一个隐式的、无法在单章构建里发现的契约。
代价是重复约 60 行结构定义，收益是任何一个工程目录单独拷走都能编译。

ch16 的 `pbuf` 本章没有用。单段模型里“缓冲”就是一个 `[MSS]u8`，
零拷贝链表的收益要等 ch21 有滑动窗口、多段同时在途时才体现；
现在引入它只会让状态机的错误被缓冲层的错误掩盖。

---

## 20.10 上板自检输出

### 20.10.1 判据一览

板侧 11 条判据，全部来自注入路径（自造段 + 注入时钟），
输入不经过任何网卡：

| #   | 判据              | 实际输出（`logs/ch20-boot.log`）                                                       |
| --- | ----------------- | -------------------------------------------------------------------------------------- |
| 1   | 已知 TCP 校验和   | `checksum syn_seg=0xeca5 verify=1 known=0xeca5`                                        |
| 2   | seq 回绕          | `seq wrap 0xfffffff0<0x10=1 diff=0x20`                                                 |
| 3   | 选项 + 编解码往返 | `options mss=1460 ws=7 sack=1 hdr=32B roundtrip=1`                                     |
| 4   | 三次握手          | `handshake state=ESTABLISHED snd_una=0x1001 rcv_nxt=0x9001 third=ACK`                  |
| 5   | MSS 分段          | `mss segs=3 lens=1460/1460/80 last_seq=0x2b68`                                         |
| 6   | RTO + 重传        | `rto srtt=2000000us rttvar=1000000us first_rto=6000000us backoff=12000000us retrans=1` |
| 7   | 乱序重组          | `reasm out_of_order late=0 delivered=200 identical=1`                                  |
| 8   | 重复 ACK          | `dupack n=3 fast_retransmit=1 seq=0x1001`                                              |
| 9   | 主动关闭          | `close active FIN_WAIT_1->2->TIME_WAIT 2msl=60000000us closed=1`                       |
| 10  | 被动关闭          | `close passive CLOSE_WAIT->LAST_ACK->CLOSED rcv_nxt=0x1002`                            |
| 11  | RST               | `rst state=CLOSED replied=0 timer=off`                                                 |

### 20.10.2 原始日志片段

以下逐行摘自 `practice/zig-esp32-s31/logs/ch20-boot.log`（2026-11-13，
`/dev/ttyUSB1`，115200 8N1），未做删改：

```text
ch20-tcp-state-machine | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: tcp segment codec + seq math + state machine + rto + reasm; no MAC/IPv4/IRQ
host: 27 unit tests via 'zig build test' (26 named + root container)
evidence: injected in-memory segments only; real-link handshake 待 ch17 闭环
check: checksum syn_seg=0xeca5 verify=1 known=0xeca5 ok=1
check: seq wrap 0xfffffff0<0x10=1 diff=0x20 ok=1
check: options mss=1460 ws=7 sack=1 hdr=32B roundtrip=1 ok=1
check: handshake state=ESTABLISHED snd_una=0x1001 rcv_nxt=0x9001 third=ACK ok=1
check: mss segs=3 lens=1460/1460/80 last_seq=0x2b68 ok=1
check: rto srtt=2000000us rttvar=1000000us first_rto=6000000us backoff=12000000us retrans=1 ok=1
check: reasm out_of_order late=0 delivered=200 identical=1 ok=1
check: dupack n=3 fast_retransmit=1 seq=0x1001 ok=1
check: close active FIN_WAIT_1->2->TIME_WAIT 2msl=60000000us closed=1 ok=1
check: close passive CLOSE_WAIT->LAST_ACK->CLOSED rcv_nxt=0x1002 ok=1
check: rst state=CLOSED replied=0 timer=off ok=1
checks: passed=11 failed=0 total=11
main: verdict=pass, skeleton idle (real link 待真机验证)
main: halting (wfi)
```

### 20.10.3 这些行分别在证什么

- `hdr=32B`：选项集决定 `data_offset`，不是手写常量；
- `snd_una=0x1001 / rcv_nxt=0x9001`：SYN 各占一个序号，第三次握手只回 ACK；
- `last_seq=0x2b68`：`0x2000 + 2920 = 0x2b68`，最后一段从第 2920 字节开始，
  长度 80；
- `first_rto=6000000us backoff=12000000us`：2 s 样本 → `2 + 4×1` 秒，
  超时后退避翻倍；
- `identical=1`：重组结果与原始载荷逐字节相同；
- `fast_retransmit=1 seq=0x1001`：三个重复 ACK 后从 `snd_una` 重发，
  而不是从 `snd_nxt`；
- `closed=1` 出现在 2MSL 到点之后，不是“立刻”；
- `rcv_nxt=0x1002`：被动关闭时 FIN 也占一个序号；
- `replied=0`：RST 不引发任何回包。

### 20.10.4 没有证什么

必须说清楚，否则这一节会变成过度承诺：

- 没有证“板上能真实握手”：段从未离开内存；
- 没有证“重传在真实丢包下工作”：丢包是脚本里的 `tick` 调用；
- 没有证“窗口/WS/SACK”：这些选项只解析；
- 没有证“吞吐”：单段模型的吞吐上限是 `MSS/RTT`，不在本章验收范围。

真实链路联调的前置条件是 ch17 的以太网 DMA 闭环；在此之前，
本章的结论止步于“状态机与算术正确”。

---

## 20.11 与 lwIP 的对照

本章不链接 lwIP，但在“同样的问题别人怎么解”这点上给出可查的坐标。
下表每一行都对应上面实际 grep 过的源码位置：

| 主题           | lwIP 的做法                                       | 本章的做法                     | 差异是否有行为后果           |
| -------------- | ------------------------------------------------- | ------------------------------ | ---------------------------- |
| 首部定长       | `TCP_HLEN 20`（`prot/tcp.h:47`）                  | `MIN_HEADER = 20`              | 无                           |
| 首部字段       | 打包的 `_hdrlen_rsvd_flags`（`tcp.h:56-64`）      | 拆成 `data_offset` + `Flags`   | 无（编码等价）               |
| 标志位         | `TCP_FIN..TCP_CWR`（`tcp.h:72-79`）               | `packed struct(u8)` 同序       | 无                           |
| 选项上限       | `TCP_MAX_OPTION_BYTES 40`（`tcp.h:83`）           | `MAX_HEADER - MIN_HEADER = 40` | 无                           |
| 状态集合       | 11 个（`tcpbase.h:56-67`）                        | 11 个，同名同序                | 无                           |
| seq 比较       | 只看差值最高位（`tcp_priv.h:109`）                | RFC 1982 严格形式              | 仅在差值恰为 2^31 时有差异   |
| 初始 RTO       | `LWIP_TCP_RTO_TIME` 缺省 3000 ms（`opt.h:1384`）  | RFC 6298 的 1 s                | 有：首次重传晚 2 s           |
| RTO 公式       | `sa/8 + sv`，`sv` 预乘 4（`tcp_in.c:1366-1387`）  | `SRTT + 4×RTTVAR` 显式         | 无（等价）                   |
| 退避           | 查表 `tcp_backoff[13]`（`tcp.c:163-164`）         | 每次 ×2，封顶 60 s             | 有：lwIP 第 6 次后不再增长   |
| 定时粒度       | 粗定时 500 ms（`tcp_priv.h:124-126`）             | 注入微秒时间戳                 | 有：本章无粒度损失           |
| 初始 MSS       | `INITIAL_MSS 536`（`tcp.c:139`）                  | `MSS_DEFAULT 536`              | 无                           |
| 乱序上限       | `TCP_OOSEQ_TIMEOUT` 等（`tcp.c:1369`）            | 4 槽 × 512 B + `dropped`       | 有：上限更小、行为更保守     |
| 重传判据       | `dupacks >= 3`（`tcp_in.c:1243-1246`）            | `dup_acks >= 3`                | 无                           |
| Karn           | 重传清 `rttest`（`tcp_out.c:1676-1677`）          | `retransmit_happened`          | 无                           |
| 校验和         | `ip_chksum_pseudo`（`tcp_in.c:173-177`）          | `pseudoSeed + Sum`             | 无                           |
| MSS 选项       | `tcp_parseopt`（`tcp_in.c:1971`）                 | `parseOptions`                 | 无（都校验长度）             |
| 窗口缩放       | 解析 + `>14` 拒绝（`tcp_in.c:2009,2021`）         | 解析 + `>14` 拒绝，但不应用    | 有：本章不用缩放             |
| TIME_WAIT 到期 | `2 * TCP_MSL / TCP_SLOW_INTERVAL`（`tcp.c:1386`） | `now_us + 2*MSL_US`            | 有：lwIP 的 MSL 配置语义不同 |

观察到的三个“值得写下来的差异”：

1. **初始 RTO 3 s vs 1 s**：lwIP 的选择更保守（减少伪重传），代价是
   真丢包时恢复更慢。这不是谁对谁错，而是 RFC 允许的两种工程取舍。
2. **seq 比较的半程边界**：lwIP 的宏在差值恰为 2^31 时给出“小于”，
   本章返回 false。真实连接不会触发，但写单元测试时必须知道自己的选择。
3. **退避表封顶**：lwIP 的 `tcp_backoff` 是
   `{1,2,3,4,5,6,7,7,...}`，作为**左移量**使用
   （`((sa>>3)+sv) << tcp_backoff[nrtx]`），所以第 6 次之后移位量
   停在 7，即最大 ×128；本章每次 ×2 直到 60 秒上限。在高丢包链路上，
   这两者的重试节奏不同。

---

## 20.12 边界：本章没做的与下一章要做的

### 20.12.1 本章明确没做

| 没有的东西                               | 影响                                     | 归谁                    |
| ---------------------------------------- | ---------------------------------------- | ----------------------- |
| 拥塞控制（cwnd/ssthresh/慢启动/AIMD）    | 单段模型的吞吐是 `MSS/RTT`，无法应对拥塞 | ch21                    |
| 发送窗口与接收窗口管理                   | `snd_wnd` 只记录；不能多段在途           | ch21                    |
| 窗口缩放（WS）的应用                     | 大带宽时延积下窗口不足                   | ch21                    |
| SACK 与选择性重传                        | 一个段丢失会导致重复发送后续段           | ch21                    |
| 半关闭（FIN_WAIT_2 里继续收数据）        | 主动关闭后不再接收数据                   | 后续扩展                |
| 同时打开（SYN_SENT 收裸 SYN → SYN_RCVD） | 裸 SYN 被忽略；两端必须按常规握手发起    | 本章范围外（见 20.4.3） |
| URG/ECE/CWR 的行为                       | 只编码/解析，不实现语义                  | ch21（ECN）/不实现      |
| 真实链路收发                             | 需要 MAC/DMA + IPv4/ARP                  | ch17 + ch18 联调        |

### 20.12.2 真实链路的验收路径（待 ch17 闭环）

以下步骤**尚未执行**，写成判据而不是结论：

1. **前置**：ch17 的 EMAC DMA 能收能发（当前症状见
   `practice/zig-esp32-s31/logs/ch17d-boot.log`：DMA 软复位超时、
   MDIO 扫不到 PHY）；ch18 的 ARP/ICMP 能 `ping` 通网关。
2. **主动打开**：板子向网关的某个端口发 SYN，用 `tcpdump` 在同一广播域
   抓包，判据是“SYN → SYN-ACK → ACK”三行，且 `seq/ack` 相差 1。
3. **重传**：在主机侧用 `iptables`/`tc netem` 丢弃 SYN-ACK 一次，
   判据是“约 1 秒后出现第二个 SYN，序列号与第一个相同”。
4. **关闭**：主动 `close()`，判据是“FIN → ACK → FIN → ACK”，
   且板侧在 60 秒内保持 `TIME_WAIT`（串口打印状态名）。
5. **反例**：对端发 RST，判据是“板侧立刻回 CLOSED，串口不再有该连接”。

在这些步骤完成之前，任何“板上 TCP 通了”的表述都是把
“纯逻辑自检通过”偷换成“链路可用”。

### 20.12.3 为什么把拥塞控制单独成章

本章的所有机制都假设“网络能送达，只是偶尔丢”。拥塞控制要回答的是
另一个问题：**当网络持续丢包时，发送方应该多快**。它需要的输入
（RTT、丢包、重复 ACK）本章已经有了，但它改的是“一次能发多少”，
而不是“发了之后怎么确认”。把两者塞进一章，结果是两个模型互相
掩盖错误：窗口算错了，看起来像重传错了；重传错了，看起来像窗口太小。
分章之后，每一章都能用一条明确的判据收尾：

- 本章：**同样的输入段，11 个状态的输出与 RFC 一致**；
- ch21：**同样的丢包序列，窗口曲线与 RFC 5681 一致**（主机侧仿真，
  不是真链路吞吐）。

---

## 事实来源

| #   | 事实                                                                       | 路径与位置（本地 `~/esp/esp-idf`，逐条 grep 核过）                                                               |
| --- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| 1   | TCP 定长首部 20 字节                                                       | `components/lwip/lwip/src/include/lwip/prot/tcp.h:47`（`TCP_HLEN 20`）                                           |
| 2   | 首部字段顺序：src/dest/seqno/ackno/\_hdrlen_rsvd_flags/wnd/chksum/urgp     | `components/lwip/lwip/src/include/lwip/prot/tcp.h:56-64`                                                         |
| 3   | 标志位 bit 定义 FIN..CWR，`TCP_FLAGS` 掩码 `0x3f`                          | `components/lwip/lwip/src/include/lwip/prot/tcp.h:72-81`                                                         |
| 4   | 选项区上限 40 字节                                                         | `components/lwip/lwip/src/include/lwip/prot/tcp.h:83`（`TCP_MAX_OPTION_BYTES 40`）                               |
| 5   | 11 个状态及编号                                                            | `components/lwip/lwip/src/include/lwip/tcpbase.h:56-67`                                                          |
| 6   | `TCP_SEQ_LT` 只看差值最高位                                                | `components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:109-111`                                                  |
| 7   | 粗定时器 500 ms、`tcp_tmr` 里 250/500 两档                                 | `components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:124-126`、`components/lwip/lwip/src/core/tcp.c:234-242`   |
| 8   | `TCP_MSL` 缺省 60000 ms                                                    | `components/lwip/lwip/src/include/lwip/priv/tcp_priv.h:137-138`                                                  |
| 9   | 初始 RTO 缺省 3000 ms                                                      | `components/lwip/lwip/src/include/lwip/opt.h:1384`；ESP 端口映射见 `components/lwip/port/include/lwipopts.h:698` |
| 10  | 退避表 `{1,2,3,4,5,6,7,7,...}`                                             | `components/lwip/lwip/src/core/tcp.c:163-164`                                                                    |
| 11  | 超时判定 `rtime >= rto`、重传与 RTO 重算                                   | `components/lwip/lwip/src/core/tcp.c:1285-1303`                                                                  |
| 12  | TIME_WAIT 到期条件 `2*TCP_MSL/TCP_SLOW_INTERVAL`                           | `components/lwip/lwip/src/core/tcp.c:1386`                                                                       |
| 13  | RTT 更新（sa/sv 缩放）与 `rto = (sa>>3)+sv`                                | `components/lwip/lwip/src/core/tcp_in.c:1366-1387`                                                               |
| 14  | Karn：仅在 `rttest == 0` 时取样                                            | `components/lwip/lwip/src/core/tcp_out.c:1542-1543`                                                              |
| 15  | RTO 重传后清 `rttest`（不再测 RTT）                                        | `components/lwip/lwip/src/core/tcp_out.c:1676-1677`                                                              |
| 16  | 接收侧校验和：`ip_chksum_pseudo`，非 0 即丢                                | `components/lwip/lwip/src/core/tcp_in.c:173-177`                                                                 |
| 17  | 最小长度与 `hdrlen` 边界、`tcphdr_optlen`                                  | `components/lwip/lwip/src/core/tcp_in.c:156,187,195`                                                             |
| 18  | 选项解析入口与 MSS/WS/SACK 分支、WS>14 拒绝                                | `components/lwip/lwip/src/core/tcp_in.c:1971,1995,2009,2021,2060`                                                |
| 19  | 重复 ACK 的五个条件、`dupacks >= 3` 快速重传                               | `components/lwip/lwip/src/core/tcp_in.c:1205-1225,1243-1246`                                                     |
| 20  | 初始 MSS 536                                                               | `components/lwip/lwip/src/core/tcp.c:139`（`INITIAL_MSS 536`）                                                   |
| 21  | 本章 `tcp.zig` 是 ch16 `headers.Tcp` 的超集                                | `practice/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/headers.zig:224-260`                               |
| 22  | 序列号比较的严格定义与半程边界                                             | RFC 1982 §3.2                                                                                                    |
| 23  | RTO 估计的规则 (2.1)–(2.5)；Karn 算法在 §3；指数退避在规则 (5.5)           | RFC 6298 §2、§3、§5                                                                                              |
| 24  | TIME-WAIT 需等 2xMSL（MUST-13）、TIME-WAIT 状态处理、MSL 规范取值 2 分钟   | RFC 9293 §3.6.1、§3.10.7.4、§3.4.2                                                                               |
| 25  | 快速重传与重复 ACK 门限 3                                                  | RFC 5681 §3.2                                                                                                    |
| 26  | lwIP 的 `SYN_SENT` 分支只处理 SYN+ACK 与带 ACK 的半开连接（无裸 SYN 分支） | `components/lwip/lwip/src/core/tcp_in.c:877-940`                                                                 |
| 27  | 同时打开的路径：`SYN_SENT` 收到裸 SYN → `SYN_RCVD`                         | RFC 9293 §3.5                                                                                                    |

> [!note] 口径
> 第 1–21 行是本地源码事实，行号均为本机 `~/esp/esp-idf` 的
> ESP-IDF v6.1 工作树，用 `grep -n` 与 `sed -n` 逐条核对；
> 第 22–25 行是规范原文。凡属本章自己的判断（单段模型、4 槽丢最老、
> 注入时钟、RST 优先），都在正文给了理由与用例，而不是引用权威。

---

## 自查清单

上板前（静态，均已在本机执行过）：

- [x] `zig build test` → `All 27 tests passed`（26 具名 + 容器）
- [x] `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 的段表里 `DROM, IROM` 行数**正好 2**（`0x40000020`、`0x40020020`）
- [x] `bash -n tools/flash.sh` 退出 0
- [x] `git status --short` 里属于本章的新增只有 `content/zig-esp32-s31/ch20-*.md` 与
      `practice/zig-esp32-s31/ch20-*/` 两个路径

上板后（逐条打勾才叫“跑通”）：

- [x] banner 五行完整（含 `host: 27 unit tests`）
- [x] `check: checksum syn_seg=0xeca5 verify=1 known=0xeca5 ok=1`
- [x] `check: seq wrap 0xfffffff0<0x10=1 diff=0x20 ok=1`
- [x] `check: options mss=1460 ws=7 sack=1 hdr=32B roundtrip=1 ok=1`
- [x] `check: handshake state=ESTABLISHED snd_una=0x1001 rcv_nxt=0x9001 third=ACK ok=1`
- [x] `check: mss segs=3 lens=1460/1460/80 last_seq=0x2b68 ok=1`
- [x] `check: rto srtt=2000000us rttvar=1000000us first_rto=6000000us backoff=12000000us retrans=1 ok=1`
- [x] `check: reasm out_of_order late=0 delivered=200 identical=1 ok=1`
- [x] `check: dupack n=3 fast_retransmit=1 seq=0x1001 ok=1`
- [x] `check: close active FIN_WAIT_1->2->TIME_WAIT 2msl=60000000us closed=1 ok=1`
- [x] `check: close passive CLOSE_WAIT->LAST_ACK->CLOSED rcv_nxt=0x1002 ok=1`
- [x] `check: rst state=CLOSED replied=0 timer=off ok=1`
- [x] `checks: passed=11 failed=0 total=11`
- [x] `main: verdict=pass` 之后停在 `wfi`，复位可重复
- [ ] 联调（待 ch17 闭环）：真实 SYN/SYN-ACK/ACK 抓包
- [ ] 联调：netem 丢一个 SYN-ACK，约 1 s 后同序列号重传
- [ ] 联调：主动关闭后板侧在 60 s 内保持 `TIME_WAIT`

失败时的第一反应（按顺序排查，不要跳步）：

1. `checksum … verify=0` → 先查伪首部的长度字段（是 TCP 段长，不是 IP 总长），
   再查 `0x0006` 字；
2. `handshake … state=SYN_SENT` → 查 SYN-ACK 的 `ack` 是否等于 `snd_max`，
   不要先怀疑 seq；
3. `rto … first_rto` 不对 → 查样本单位（本章是微秒）与 K 是否仍是 4；
4. `reasm … identical=0` → 打印 `insert` 的裁剪前缀与 `expect`，
   通常是 `seqLt` 用错方向；
5. `close … 2msl` 立刻 closed → 查 `now_us` 是否在 `appClose` 之前就超过了
   `time_wait_until_us`（注入时钟的单调性由调用方保证）。

---

本章交付的是“可负责”：每一行串口输出都对应一个字段、一条不变量或一次
状态迁移；每一个尚未验证的结论都标了「待 ch17 闭环」。TCP 真正的难点
不在 20 字节首部，而在于**在丢包、乱序与内存压力同时存在时仍然收敛**。
下一章站在这台状态机上，去调那个更“暴力”的旋钮：一秒能发多少。

系列导航：[[ch19-udp-dhcp-dns|上一章：UDP、DHCP 与 DNS]] ·
[[ch21-tcp-congestion-throughput|下一章：TCP 拥塞控制与吞吐]] ·
[[zig-esp32-s31|系列索引]]
