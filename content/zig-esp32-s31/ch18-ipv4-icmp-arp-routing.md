---
title: "Zig × ESP32-S31 全栈开发（十八）：IPv4、ICMP、ARP 与路由"
date: 2026-11-30 12:00:00
description: "把以太网载荷变成可 ping 的 IP 栈：IPv4 首部 20 字节的逐字段校验与三个必踩的坑、RFC 1071/1624 校验和与增量更新、8 字节对齐的分片算术、有界重组器的区间/重叠/超时/淘汰、ICMP 回显与 frag-needed、ARP 缓存的六个状态与 1s×3 重传、最长前缀匹配与“ARP 到底解析谁”、PMTU 黑洞与 68 字节下限。主机侧 70 个用例全绿，板侧 13 条判据已于 2026-11-13 真机全过（`checks: passed=13 failed=0`）。"
tags: [zig, esp32-s31, riscv, ipv4, icmp, arp, routing, pmtu, series]
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
> 18. **第十八章：IPv4、ICMP、ARP 与路由**
> 19. [[ch19-udp-dhcp-dns|第十九章：UDP、DHCP 与 DNS]]

# Zig × ESP32-S31 全栈开发（十八）：IPv4、ICMP、ARP 与路由

ch17 把比特从差分对搬进了 SRAM，并且在描述符里证明了 `OWN` 位真的被 DMA
翻转过。但从协议栈的角度看，那只是**一串字节**：以太网首部 14 字节，后面
跟着 EtherType 指明的载荷。这一章开始把载荷读成"包"。

有意思的是，本章的验收目标极其朴素——`ping` 通。但一个能回 `ping` 的栈，
必须同时具备：IPv4 首部解析与校验和、ICMP 回显、ARP 请求/应答、ARP 缓存、
路由表（哪怕只有一条默认路由）、MTU 处理。**`ping` 是这六件事的最小联合
验收**，缺一件都通不了。这也是 Part IV 把本章放在 ch17 与 ch19 之间的原因。

> [!warning] 本章的证据边界
> 静态部分全部验证过（2026-11-13，宿主 x86_64 / Zig 0.17.1）：
>
> - 交叉编译退出 0；`elf2image` 打印 `Merged 2 ELF sections.`；
> - `image-info` 的段表里 `DROM, IROM` 行数**正好 2**（`0x40000020` / `0x40020020`；
>   另有 2 个 DRAM/IRAM 段与 1 个 PADDING 段，与 ch16/ch17 真机跑过的结构一致）；
> - `zig build test` 的 70 个主机侧用例全绿（69 个具名 + 根文件容器 test）；
> - `bash -n tools/flash.sh` 退出 0；
> - 镜像静态占用：`.flash.text` 0x4b90、`.flash.rodata` 0xb30、`.data` 0x180、
>   `.bss` 0x3810。
>
> **已上板（2026-11-13）**：板侧 13 条判据全部 PASS（`checks: passed=13 failed=0 total=13`），
> 原始输出见 `../logs/ch18-boot.log`。**ping 通仍不在本章的已验收范围内**：它需要把
> ch17 的收发包路径接上（ch17 目前 DMA 软复位超时），属于 18.11 说的跨工程联调。

---

## 18.1 交接面：ch17 交上来的是什么

ch17 的收包路径最后停在"一帧在 SRAM 里、`OWN` 位已翻回 CPU"。本章约定的交接
只有四个值，没有第五个：

| 交接物   | 类型/范围                            | 谁负责                               |
| -------- | ------------------------------------ | ------------------------------------ |
| `frame`  | `[]const u8`，以太网首部 + 载荷      | ch17 提供，本章只读                  |
| 接口 MTU | 1500（板载千兆口，链路层不额外分片） | ch17 / 板级配置                      |
| `now_ms` | `u32` 毫秒，单调递增                 | 上层 tick（ch11 之后接 `esp_timer`） |
| 本机地址 | `inet.Addr` + 前缀长度               | 配置（ch19 由 DHCP 提供）            |

输出方向同样是三个动作：

1. `send(frame)` —— 交给 ch17 的 TX 环；
2. `arp request(target)` —— 由 `poll()` 产生，上层填 `sha = 本机 MAC`、
   `tha = 广播`、`tpa = target`，再交给 `send`；
3. `icmp reply / icmp error` —— 同样是"一个 IPv4 报文"，回到 1。

按 EtherType 分派的两条路：

```text
ETH 0x0800 ──► ipv4.Header.parse ──┬── proto 1  (ICMP) ──► icmp.*        ──► 可能是应答
                                   ├── proto 17 (UDP)  ──► ch19
                                   └── proto 6  (TCP)  ──► ch20
ETH 0x0806 ──► arp.Packet.parse ──┬── op 1 request     ──► learn + 可能回 reply
                                   └── op 2 reply       ──► learn
```

本章的板侧工程刻意**不**包含 EMAC：它只把上面这套纯逻辑跑一遍，证明同一份
代码在 rv32 上自洽。真正的 ping 需要 ch17 的环、本章的解析、以及一份本机
IP 配置三者同时在真机上跑——那是 18.11 的联调清单。

---

## 18.2 20 字节：逐字段与三个必踩的坑

IPv4 首部的固定部分 20 字节，字段顺序在 RFC 791 §3.1。写成 Zig 结构体时
**不要**用 `packed struct` 去"对齐"网络字节序——那是最常见的自找麻烦。
本章的做法是：结构体是普通值类型，编解码逐字段 `writeInt(..., .big)`。

| 偏移 | 长度 | 字段                | 本章的读法                                           |
| ---- | ---- | ------------------- | ---------------------------------------------------- |
| 0    | 1    | Version / IHL       | 高 4 位必须 4；低 4 位 ≥5（单位是 **4 字节**）       |
| 1    | 1    | DSCP / ECN          | 原样保存，不参与转发决策                             |
| 2    | 2    | Total Length        | **首部 + 载荷**，含本片自己的 20 字节                |
| 4    | 2    | Identification      | 分片重组键的一半                                     |
| 6    | 2    | Flags + Frag Offset | `bit15..13` flags，`bit12..0` 偏移，单位 **8 字节**  |
| 8    | 1    | TTL                 | 每跳减 1；减到 0 回 ICMP time exceeded（本章不转发） |
| 9    | 1    | Protocol            | 1=ICMP、6=TCP、17=UDP                                |
| 10   | 2    | Header Checksum     | 只覆盖首部，**不含载荷**                             |
| 12   | 4    | Source Address      | 网络序                                               |
| 16   | 4    | Destination Address | 网络序                                               |

### 坑一：IHL 的单位是 4 字节

`ihl = 5` 才是 20 字节。写成 `buf[0] & 0x0F` 之后忘了乘 4，解析出来的载荷会
从第 5 个字节开始——所有上层协议全线错位，而校验和（只覆盖首部）居然还是
对的，于是你会去怀疑 ICMP。

### 坑二：标志位与片偏移共用一个 16 位字

```text
 bit 15   14   13                12 ... 0
   +----+----+----+--------------------------------+
   | 0  | DF | MF |        Fragment Offset         |
   +----+----+----+--------------------------------+
                            单位：8 字节
```

所以"片偏移 185"表示载荷从第 1480 字节开始。这也是为什么分片大小要向下取整
到 8：除最后一片外，任何片载荷不是 8 的倍数都无法用 13 位偏移表达。

### 坑三：`total_length` 不是载荷长度

第一片的 `total_length` 是 1500，最后一片可能只有 60；两者都包含各自的 20 字节
首部。重组时如果拿 `total_length` 当"整包载荷长度"，最后一片会永远补不齐。

### 解析必须先拒绝，再解释

`ipv4.Header.parse` 的六道检查（顺序不能换，否则会在越界的读上崩）：

```zig
if (buf.len < 20) return error.Truncated;        // 1. 连首部都不够
if (buf[0] >> 4 != 4) return error.BadVersion;   // 2. 不是 IPv4
if (ihl < 5) return error.BadIhl;                // 3. IHL 小于最小值
if (buf.len < ihl * 4) return error.Truncated;   // 4. 选项被截断
if (total_len < ihl * 4) return error.BadTotalLength;
if (total_len > buf.len) return error.Truncated; // 5. 缓冲区没这么多字节
```

校验和单独放在 `parseChecked` 里：错误包也需要计数上报，不能让"校验和错"
和"结构错"混成一个错误路径。

**选项为什么只跳过不支持**：选项（record route、timestamp、source route）
在现代网络上几乎不出现，而"复制语义"（copy bit 决定分片时是否复制该选项）
让分片实现复杂度翻倍。本章解析时允许 `ihl > 5` 并用 `headerLen()` 跳过，
生成与分片时拒绝（`error.UnsupportedOptions`）。这是一个显式的边界，
不是遗漏。

---

## 18.3 校验和：RFC 1071、RFC 1624 与 ch16 的边界

### 反码和的三步

1. 把字节流按大端两两成组，当作 16 位整数累加；
2. 每加一次就把进位折回低 16 位（`acc = (acc & 0xFFFF) + (acc >> 16)`）；
3. 取反，写进校验和字段。

验证时把**含校验和字段**的整段再算一遍，结果必须是 `0x0000`——因为校验和字段
的值恰好是"其余字之和的反码"，加上自己就是 `0xFFFF`，折叠后是 `0xFFFF`，
取反是 0。`inet.verify` 用的就是这条性质，比"算出期望值再比较"少一次
人为约定的机会。

### 奇数字节：不是"每片自己补零"

若一段是 3 字节、下一段是 5 字节，第 3 个字节必须和下一段的第 1 个字节配对。
`inet.Sum` 用 `pending: ?u8` 记住"落单的高字节"：

```zig
pub fn add(self: *Sum, bytes: []const u8) void {
    var i: usize = 0;
    if (self.pending) |hi| {                       // 上一段落单的字节
        if (bytes.len == 0) return;
        self.acc += (@as(u32, hi) << 8) | bytes[0];
        i = 1;
        self.pending = null;
    }
    while (i + 1 < bytes.len) : (i += 2) { ... }   // 成对累加
    if (i < bytes.len) self.pending = bytes[i];    // 这一段又落单了
}
```

这条性质是零拷贝的地基：校验和可以**跨 pbuf/跨分片**求和，不需要先把链拼成
连续内存。本章的 `ofSlices` 与 ch16 的同名函数语义一致，但实现独立。

### 增量更新：为什么不能用 RFC 1141 的旧公式

路由器改 TTL、NAT 改地址时只动一个 16 位字。整包重算是 O(n)，而且需要把
整个报文读一遍——对转发路径是灾难。

设 `~HC` = "除校验和字段外所有字的部分和" `S`。改动 `m → m'` 后
`S' = S - m + m'`；反码算术里 `-m == ~m`，且 `0xFFFF` 就是 `-0`。于是

```text
HC' = ~( ~HC + ~m + m' )
```

RFC 1141 的旧公式 `HC' = HC - ~m - m'` 在 `HC == ~m` 时得到 `-0`（0xFFFF），
而 RFC 1624 明确要求得到 `+0`（0x0000）。本章实现的是 RFC 1624：

```zig
pub fn updateChecksum(checksum: u16, old_word: u16, new_word: u16) u16 {
    var acc: u32 = @as(u32, ~checksum & 0xFFFF) +
        (@as(u32, ~old_word & 0xFFFF)) + @as(u32, new_word);
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return @truncate(~acc);
}
```

测试里用"改 TTL 64→63"和"两个字段各改一次"两条用例钉死：增量结果必须等于
整包重算、且与调用顺序无关。

### 和 ch16 的边界：为什么独立重写

| 维度     | ch16 `checksum.zig`            | 本章 `inet.zig`                         |
| -------- | ------------------------------ | --------------------------------------- |
| 模块形态 | 协议栈工程的一层               | 本章工程的独立模块                      |
| 状态     | `Sum{acc, odd}`                | `Sum{acc, pending}`（同语义，不同结构） |
| 额外能力 | 伪首部、UDP 特例（0 → 0xFFFF） | 地址/掩码/前缀匹配、`verify`、增量更新  |
| 被谁引用 | ch16 的 `headers/netif`        | ch18 的 `ipv4/icmp`                     |

`zig build` 的根模块只包含本工程的 `src/`。跨工程 `@import("../ch16-…")`
要么把别人的目录布局变成隐式契约，要么在 `build.zig` 里挂模块——两种做法都会
让"这一章能不能单独拷走"变成问题。本系列的约定是**每章独立可编**：
共享接口与做法，不共享文件。代价是每个工程自带一份约 200 行的地址/校验和
实现；收益是任何一章都能单独 `zig build test`。

---

## 18.4 分片：8 字节的算术

### 每片载荷的上限

```text
chunk = ((mtu - header_len) / 8) * 8
```

MTU 1500、首部 20 → `chunk = 1480`。3000 字节载荷 → 1480 + 1480 + 40，三片。
偏移分别是 0、185、370（**以 8 字节为单位**），字节偏移是 0、1480、2960。

`mtu` 不是 8 的倍数时也一样：MTU 1499 → `(1479/8)*8 = 1472`，仍然 3 片。
这就是"向下取整"的实际含义——宁可少 7 个字节，也不能让偏移字段表达不了。

### 每片改什么、不改什么

| 字段           | 第一片       | 中间片     | 最后一片  |
| -------------- | ------------ | ---------- | --------- |
| Identification | 不变（原值） | 不变       | 不变      |
| Total Length   | 20 + chunk   | 20 + chunk | 20 + 剩余 |
| DF             | **清 0**     | 0          | 0         |
| MF             | 1            | 1          | **0**     |
| Frag Offset    | 0            | off/8      | off/8     |
| Header Cksum   | 重算         | 重算       | 重算      |
| TTL / Protocol | 不变         | 不变       | 不变      |

`id` 必须原样保留，否则接收端会把三片当成三个独立数据报；`TTL` 在分片时
**不**递减（递减发生在转发时）。校验和每片都要重算，因为 `total_len`、
`offset`、`mf` 都变了。

### DF=1：不分片，交给 ICMP

`ipv4.fragment` 遇到 `df = true` 直接返回 `error.DfSet`。这是刻意的：
DF 的语义是"宁可不发，也不要分片"，正确动作是给发送方回 `ICMP type 3 code 4`
并附上本链路 MTU（18.9）。如果驱动"顺手"把 DF 清掉再分片，路径 MTU 发现
就永远不会收敛，而发送方会一直以为自己在发 1500 字节的包。

### 分片时的两个常见 bug

1. **给每片重新分配 id**：接收端的重组键是 `(src, dst, id, proto)`，id 变了
   就是三个单包，最后一片 `mf=0` 会被当成"完整数据报"，前两片永远等不到。
2. **最后一片也按 8 字节对齐**：最后一片载荷可以是任意长度（本章例子里是 40）。
   强行补齐到 8 的倍数会在包里塞进 4 个不属于原数据的字节。

---

## 18.5 重组：有界、区间、重叠

重组器是攻击面最集中的地方。本章的 `ipv4.Reasm` 只有五个决定，每个决定都
对应一类攻击或一类内存放大：

| 决定       | 本章取值                     | 防的是什么                                   |
| ---------- | ---------------------------- | -------------------------------------------- |
| 槽数       | 2                            | 分片洪水把 `.bss` 吃穿                       |
| 单包上限   | 3000 字节载荷                | 无界重组（65535 B 可被拆成 8191 个 8 B 片）  |
| 区间表上限 | 8 段/槽                      | 每 8 字节一片的"碎片化"攻击（187 段/1500 B） |
| 超时       | 30 s                         | 永远等不到最后一片的槽                       |
| 重叠处理   | 内容一致则接受，不一致丢整包 | teardrop / 重叠注入                          |

### 键与状态

```text
key = { src, dst, id, protocol }
slot = {
    used, key, header(20B), ranges[8]{start,end},
    range_count, total = null, updated_ms
}
```

`total` 只在收到 `mf = 0` 的片时确定——这是整包载荷的**唯一可信来源**。
在此之前只知道"已覆盖多少"，不知道"还差多少"。

### 插入一片的五步

1. 拒绝 `ihl != 5`（选项不支持）、超过 3000 字节的偏移，以及 **MF=1 但载荷
   不是 8 的倍数**的片（RFC 791 的硬规则，否则偏移无法对齐）；
2. 校验 `payload.len == total_len - 20`（片自身自洽）；
3. 记账 `total`：若已有 `total` 且与本片 `end` 矛盾，丢整包；
4. 比对重叠区间的字节：内容不同 → `error.OverlapConflict`，整包丢弃并计入
   `stats.failed`；
5. 若区间已完全覆盖（重复片）→ 返回 `.duplicate`，不写缓冲；否则拷贝 +
   合并区间（相邻区间也合并，避免区间表被"连续片"撑爆）。

完成条件是"存在一个区间从 0 覆盖到 total"。组装时用**第一片的首部**作为模板，
把 `total_len` 改成 `20 + total`、清 `mf`、清 `frag_offset`、重算校验和，
于是上层拿到的是一个完整的 IPv4 报文（首部 + 载荷），而不是一堆片。

### 有界策略与计数

槽满时踢掉 `updated_ms` 最旧的槽，`stats.evicted += 1`。这个计数是判断
"是否正在被分片洪水打"的第一个指标——比看串口日志快得多。

本章没有做"按源地址限流"（真实网关会做），也没有做"重组队列给上层反压"。
两者都写进 18.11 的边界。

### 与 lwIP 的对照

本地 IDF v6.1 的 lwIP 在同一位置做了同样的事，可以直接读代码对照：

- `components/lwip/lwip/src/core/ipv4/ip4_frag.c:65-80`：注释明确写
  "fragments must not overlap … overlapping or duplicate fragments are thrown away"，
  并给出 `IP_REASS_MAX_PBUFS` 的裁剪开关；
- 同文件 `:259` `ip_reass_remove_oldest_datagram()`：槽/缓冲不足时踢最旧的数据报；
- 同文件 `:421/434/447`：重叠检测的三处分支；
- `components/lwip/lwip/src/include/lwip/opt.h:797/809`：默认
  `IP_REASS_MAXAGE = 15`、`IP_REASS_MAX_PBUFS = 10`；
- `components/lwip/port/include/lwipopts.h:241`：ESP-IDF 把 `IP_REASS_MAXAGE`
  改成 **3**（单位是 IP 定时器 tick，通常 1 s）。

差异只在"量"：lwIP 用 pbuf 计数而非字节上限，本章用固定槽 + 字节上限。
两者的不变量是同一个：**任何时刻占用的内存有上界**。

---

## 18.6 ICMP：echo 与 frag-needed

### 8 字节首部，两种"剩余"语义

```text
 0        1        2        3
+--------+--------+-----------------+
|  Type  |  Code  |   Checksum      |
+--------+--------+-----------------+
|      Rest of Header (4 bytes)     |
+-----------------------------------+
|            Data ...               |
```

同样 4 个字节，在不同类型里含义完全不同：

| Type | Code | rest-of-header           | 本章是否实现    |
| ---- | ---- | ------------------------ | --------------- |
| 0    | 0    | Identifier + Sequence    | ✅ 回显应答     |
| 8    | 0    | Identifier + Sequence    | ✅ 回显请求     |
| 3    | 0/1  | Unused                   | ❌（只回 4）    |
| 3    | 4    | Unused(2) + Next-hop MTU | ✅ frag needed  |
| 11   | 0/1  | Unused                   | ❌ 不转发，无需 |
| 4/5  | —    | 已废弃/重定向            | ❌              |

### 校验和没有伪首部

ICMP 的校验和覆盖**整个 ICMP 报文**（首部 + 数据），不包含 IP 伪首部。
把 UDP/TCP 的伪首部习惯带过来，症状是 `ping` 一直 "checksum bad"，而对端
明明收到了包。本章的 `checksumOk(bytes)` 要求 `bytes` 恰好是这段 ICMP 报文，
不能带以太网填充。

### 应答：只改两个字节

```zig
pub fn echoReplyFrom(request: []const u8, out: []u8) Error![]const u8 {
    if (request[0] != typ.echo_request) return error.NotEcho;
    @memcpy(out[0..request.len], request);
    out[0] = typ.echo_reply;                 // 8 → 0
    std.mem.writeInt(u16, out[2..4], 0, .big);
    std.mem.writeInt(u16, out[2..4], inet.of(out[0..request.len]), .big);
    return out[0..request.len];
}
```

`id`、`seq`、载荷一律原样带回。这是 `ping` 的丢包统计能工作的前提：发送方
用 `(id, seq)` 配对请求与应答，任何"自作聪明"的改写都会让统计错位。

### 谁能回、谁不能回

RFC 1122 §3.2.2.6 写的是 **MAY**：目的地址是**广播或多播**的回显请求
**可以静默丢弃**。规范留了余地（有人把它当诊断工具），但代价是
`ping 192.168.1.255` 一次，整个网段的主机都回一个包——ICMP 变成反射放大器。
本工程选择丢弃，并把它做成一个显式谓词：

```zig
pub fn mayReply(dst_is_broadcast: bool, dst_is_multicast: bool) bool {
    return !(dst_is_broadcast or dst_is_multicast);
}
```

调用方（未来的 `netif` 输入路径）在拿到 IP 目的地址后用 `inet.isLimitedBroadcast`
/ `inet.isMulticast` 算这两个布尔值。**策略与实现分离**，测试里可以直接
断言四个组合。

### frag-needed：PMTU 的唯一来源

`type 3 code 4` 的报文里，4 字节的 rest-of-header 是 `unused(16) + MTU(16)`，
后面跟"触发它的原始 IP 报文的前 28 字节"（20 字节首部 + 8 字节载荷）。
少抄了这 28 字节，发送方就无法把错误关联到某条连接（或某个 socket），

`writeFragNeeded` 的两个边界：

- `original.len < 28` 时按实际长度抄（例如一个 20 字节的空数据报）；
- `mtu` 原样写入，不做夹紧——夹紧是**接收方**的事（18.9 的 68 字节下限）。
- `mtu == 0` 是老式报文：不支持 PMTU 发现的路由器只会填 0。接收方按
  RFC 1191 §4 把它折算成 576（`Pmtu.learn` 的第一行就是这个判断）。

---

## 18.7 ARP：28 字节与六个状态

### 报文

| 偏移 | 长度 | 字段                 | 以太网/IPv4 的取值 |
| ---- | ---- | -------------------- | ------------------ |
| 0    | 2    | Hardware Type        | 1（Ethernet）      |
| 2    | 2    | Protocol Type        | 0x0800（IPv4）     |
| 4    | 1    | Hardware Length      | 6                  |
| 5    | 1    | Protocol Length      | 4                  |
| 6    | 2    | Operation            | 1=request、2=reply |
| 8    | 6    | Sender Hardware Addr | 发送方 MAC         |
| 14   | 4    | Sender Protocol Addr | 发送方 IP          |
| 18   | 6    | Target Hardware Addr | 请求时全 0         |
| 24   | 4    | Target Protocol Addr | 被问的 IP          |

请求以**广播**发出（目的 MAC `ff:ff:ff:ff:ff:ff`，EtherType `0x0806`），
应答以**单播**回到请求方。解析只接受 `htype=1/ptype=0x0800/hlen=6/plen=4`，
其它组合返回 `error.Unsupported`——不要试图用一个 `[6]u8` 去装 8 字节的
硬件地址。

### 六个状态

| 状态         | 含义                         | 进入条件                      | 定时器/动作                            |
| ------------ | ---------------------------- | ----------------------------- | -------------------------------------- |
| `free`       | 槽空闲                       | 回收/初始化                   | —                                      |
| `incomplete` | 已发请求，等应答             | `resolve()` 未命中            | 1 s 重发，3 次后 `free` + `failures`   |
| `reachable`  | 最近确认过，可直接用         | `learn()`（reply / 捎带学习） | 30 s 后 → `stale`                      |
| `stale`      | MAC 仍可用，但该复核         | `reachable` 到期              | 下次 `lookup` → `delay`                |
| `delay`      | 复核倒计时（给上层刷新机会） | `stale` 被使用                | 5 s 后 → `probe` 并立刻发探测          |
| `probe`      | 正在发单播探测               | `delay` 到期                  | 1 s ×3；3 次无果 → `free` + `failures` |

状态名与 Linux 邻居子系统的 `NUD_*` 常量一一对应
（`linux/neighbour.h:63-72`：`NUD_INCOMPLETE/REACHABLE/STALE/DELAY/PROBE/FAILED`），
所以上板后可以拿 `ip neigh show` 的输出直接对照本章的串口行。

### 为什么 `incomplete` 不能"先发广播试试"

以太网帧必须有目的 MAC。没有解析结果时，唯一合法的动作是发广播 **ARP 请求**；
把数据帧改成广播发出去，结果是所有主机都收下再丢掉，还会污染对端的连接状态
（它可能把广播当成链路层错误）。所以 `lookup()` 在 `incomplete` 态返回 `null`，
上层必须显式处理"暂时不可达"。

真实栈会做**待发队列**（lwIP 的 `ARP_QUEUEING`，IDF 在
`components/lwip/port/include/lwipopts.h:163` 打开了它；上游默认在 `opt.h:648`
是关的）。本章没做，写进 18.11。

### 学习：不只从 reply

RFC 826 允许从任何 ARP 报文的 `sender` 字段学习，因为发送方填的一定是它
自己的 `(IP, MAC)`。本章的 `receive` 无条件学习 `spa/sha`，**除了**
`spa == 0.0.0.0`：那是地址冲突检测（RFC 5227）的探测报文，发送方还没有地址，
学习它会在缓存里留下一条"0.0.0.0 → 某 MAC"的垃圾。

### 容量与淘汰

8 个槽。满了之后先踢 `stale`，再踢 `delay/probe`，最后才踢 `reachable`；
同级别里踢最久没确认的。`incomplete` 排最后——它正在解析中，踢掉等于让
上层重来一次。这个 `rank()` 顺序就是"缓存策略"，值得在代码里显式写出来，
而不是埋在 `if` 里。

---

## 18.8 路由与最长前缀匹配

### 三步决策

```text
lookup(dst)
  ├─ 没有匹配 → null（回 ICMP net unreachable，不要猜默认网关）
  ├─ gateway != null → via = gateway, on_link = false  → ARP 解析网关
  └─ gateway == null → via = dst,     on_link = true   → ARP 解析目的地址
```

第三行是"跨网段 ping 的真相"：`ping 8.8.8.8` 时，板子发出的以太网帧目的
MAC 是**网关**的，不是 8.8.8.8 的（也不可能是——8.8.8.8 的 MAC 不在这个
广播域里）。如果 ARP 表里出现 8.8.8.8 的条目，说明路由查错了。

### 表结构与 LPM

```zig
pub const Route = struct {
    dst: inet.Addr,          // 网络地址，主机位必须为 0
    prefix: u8,              // 0..32
    gateway: ?inet.Addr,     // null = connected
    iface: Iface,
    metric: u16,
};
```

`lookupRoute` 对 16 条表项做线性扫描，选"前缀最长"的；同前缀取 `metric`
更小的；都相同则取先插入的（数组顺序稳定，结果可复现）。**插入顺序不影响
结果**——这条有测试钉死，因为"路由表是顺序敏感的"是最常见的误解之一。

### 三个必须在 `add` 里挡掉的错误

1. **主机位不为 0**：`192.168.1.10/24` 不是一条合法路由项。本章直接返回
   `error.HostBits`，而不是"用掩码比较也能匹配"地放行——后者会让打印、
   去重、与 `ip route` 的输出全对不上。
2. **前缀 > 32**：`error.BadPrefix`。
3. **表满**：`error.TableFull`。静默丢弃一条路由，故障现象会是"某个网段
   偶发不通"，比直接报错难查得多。

### 为什么不用 trie

主机路由表只有 connected + 默认 + 少量静态，十几条。16 次掩码比较在 320 MHz
的核上是亚微秒级；而 multibit trie 需要额外的内存、插入/删除时的重建逻辑，
以及针对前缀长度的分支。**没有测量支撑的优化就是负债**。等到真有 10 万条
前缀（路由器场景），再换成 trie——那是另一个数量级的问题，不是本章的范围。

### connected 判定

`hasConnected(addr)` 回答"这个地址是否直连"。DHCP 拿到地址后（ch19），
第一个要检查的就是"网关是否 on-link"：如果网关不在任何 connected 网段里，
那么默认路由本身就是坏的——你会一直发 ARP 请求问一个不可达的地址。

---

## 18.9 MTU 与 PMTU

### 三个不同的 MTU

| 名字     | 值                                 | 谁决定                         |
| -------- | ---------------------------------- | ------------------------------ |
| 接口 MTU | 1500（板载千兆口）                 | 链路层 / 硬件                  |
| 路径 MTU | 路径上最小的那一跳                 | 中途链路（PPPoE 1492 等）      |
| 最小合法 | 68 字节（IPv4 要求每个链路都能过） | RFC 791                        |
| 最小重组 | 576 字节（EMTU_R 下限）            | RFC 791 §3.2 / RFC 1122 §3.3.2 |

接口 MTU 是本地已知的；路径 MTU 只能**学**——这就是 RFC 1191 的 PMTU 发现：

```text
板子 ──1500 DF──► 路由器 ──► 链路 MTU 1400 的下一跳
                                │
                                └── ICMP type 3 code 4, mtu=1400（引用原报文 28B）
板子收到 → pmtu.learn(dst, 1400)
        → 后续发往该 dst 的报文按 1400 分片（或让上层按 1400 分片）
```

### 黑洞 PMTU

如果中途设备把"需要分片"的包**静默丢弃**（不产生 ICMP），发送方会一直重传
1500 字节的包，连接挂死但 `ping` 小包正常。这叫 PMTU 黑洞。缓解手段：
按 RFC 1191 §7 的 plateaus 逐级尝试（65535/32000/17914/8166/4352/2002/1492/
1006/508/296/68），或用 PLPMTUD（RFC 8899，靠探测而不是靠 ICMP）。

本章只实现"学 + 缓存 + 老化"，不做探测——这是 18.11 的边界。

### 缓存的三条规则

1. **只降不升**（除老化）：ICMP 报的 MTU 比链路 MTU 大 → 忽略（对方在撒谎
   或报的是自己的上行 MTU）；为 0 → 按 576（老式路由器）；比 68 小 → 夹到 68。
2. **按目的地精确匹配**：真实栈按"下一跳/路由"为键（一条路由下共享 PMTU），
   本章按目的地址，表容量 8，超了踢最旧。
3. **10 分钟老化**：路径会变（换了链路、路由收敛），过期就回到链路 MTU 重试。
   RFC 1191 §6.3 的原话是 "on the order of 10 minutes"，且要求恢复为**第一跳
   的 MTU**——本章的 `age()` 就是把这个条目置为无效，`mtuFor` 自然回落到
   `link_mtu`。一直用旧值会把"路径变宽了"永久锁在小 MTU 上。

调用方视角只有两个函数：

```zig
const mtu = pmtu.mtuFor(dst);                 // 没记录就是链路 MTU
if (ipv4.needsFragment(total_len, mtu)) { … } // 分片，或给上层回 error
```

`needsFragment` 而不是"直接分片"是刻意的：DF 包不能分片，只能回 ICMP
frag-needed（18.4/18.6）。

---

## 18.10 工程结构与判读顺序

工程是形态 B（Zig 产 ELF + IDF 只提供二级 bootloader/分区表）。文件职责表在
`practice/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/README.md`，这里只强调三件事。

### 站内代码浏览

| 文件                 | 代码浏览                                                                           |
| -------------------- | ---------------------------------------------------------------------------------- |
| `build.zig`          | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/build.zig)          |
| `linker/s31.ld`      | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/linker/s31.ld)      |
| `src/inet.zig`       | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/inet.zig)       |
| `src/ipv4.zig`       | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/ipv4.zig)       |
| `src/icmp.zig`       | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/icmp.zig)       |
| `src/arp.zig`        | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/arp.zig)        |
| `src/route.zig`      | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/route.zig)      |
| `src/host_tests.zig` | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/host_tests.zig) |
| `src/selftest.zig`   | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/selftest.zig)   |
| `src/main.zig`       | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/main.zig)       |
| `src/start.zig`      | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/start.zig)      |
| `src/hw.zig`         | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/hw.zig)         |
| `src/trap.zig`       | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/trap.zig)       |
| `src/log.zig`        | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/log.zig)        |
| `tools/flash.sh`     | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/tools/flash.sh)     |

**第一，五个模块没有一个字节的 MMIO。** `inet/ipv4/icmp/arp/route` 全部接受
`now_ms: u32` 参数，不读时钟、不分配内存、不 sleep。所以 70 个用例能在
主机上 10 ms 内跑完，而且结果是确定的（假时钟推进老化）。

**第二，重组缓冲由调用方挂上。** 这是一个踩过的坑：把 `[2][3020]u8` 放进
`Reasm{}` 的默认值，`var g_reasm: Reasm = .{}` 会让编译器把 6 KB 写进 `.data`
（镜像变大、启动变慢，`.bss` 边界检查失效）。改成 `storage: []u8` +
`attach(&buf)` 之后，`.data` 只剩 0x180 字节。这条经验对任何"大缓冲 + 默认
初始化"的嵌入式结构都成立。

**第三，串口输出的 13 行就是判读顺序。** 上板后按这个顺序看：

| 顺序 | 判据（`check:` 行）                              | 不对时先怀疑                      |
| ---- | ------------------------------------------------ | --------------------------------- |
| 1    | `addr … net=192.168.1.0 same-subnet…`            | `mask()` 的位数循环、前缀比较     |
| 2    | `icmp echo-request len=15 … cksum-ok=1`          | 校验和把伪首部也算进去了          |
| 3    | `icmp echo-reply len=15 type=0 payload-copied=1` | 忘了改 type、或没重算校验和       |
| 4    | `ipv4 … total=3020 payload=3000`                 | IHL 乘 4、total_len 含首部        |
| 5    | `ipv4 frag … off=0/1480/2960 mf=1/1/0`           | 分片大小没向下取整到 8            |
| 6    | `ipv4 reasm … identical=1 completed=1`           | 区间合并、total 只认 MF=0 那一片  |
| 7    | `route 192.168.1.50 on-link=1 via-self=1`        | 先查了默认路由，或前缀比较写反    |
| 8    | `route 8.8.8.8 on-link=0 via=192.168.1.1`        | 网关字段没进 NextHop              |
| 9    | `arp resolve miss=1 request target=…`            | `resolve` 后 `next_action` 不是 0 |
| 10   | `arp learn state=reachable …`                    | `learn` 没把状态置回 reachable    |
| 11   | `arp expire +31s state=stale`                    | 老化用的是 `>` 而不是 `>=`        |
| 12   | `arp serve reply op=2 sha=… tpa=… len=28`        | 应答里填了请求方的 IP/MAC         |
| 13   | `pmtu … mtu=1400 needs-frag(1500)=1`             | learn 的"只降不升"判断反了        |

最后一行 `checks: passed=13 failed=0 total=13` 之后才打印 verdict；任何一条
失败都会走 `panic:` 路径并停在 `wfi`。

### 已经跑过的静态验证

```bash
cd practice/zig-esp32-s31/ch18-ipv4-icmp-arp-routing
zig build test --summary all
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
esptool --chip esp32s31 image-info zig-out/bin/app.bin
bash -n tools/flash.sh
```

主机侧分布（69 个具名用例 + 根文件容器 test = 70）：

| 模块        | 用例数 | 覆盖的东西                                       |
| ----------- | -----: | ------------------------------------------------ |
| `inet.zig`  |     11 | 地址/掩码/前缀、RFC 1071、RFC 1624 增量更新      |
| `ipv4.zig`  |     22 | 首部、分片算术、重组（乱序/重复/重叠/超时/淘汰） |
| `icmp.zig`  |     10 | 回显、应答、frag-needed、应答策略                |
| `arp.zig`   |     15 | 报文、六状态机、老化、应答、容量淘汰             |
| `route.zig` |     11 | LPM、metric、connected/gateway、表容量           |

---

## 18.11 还不做的事与下一章

本章交付的是"**纯逻辑上的完整 IPv4 主机**"：

- ✅ IPv4 首部解析（含选项跳过）、校验和验证、RFC 1624 增量更新
- ✅ 分片（8 字节对齐）、有界重组（乱序/重复/重叠/超时/淘汰）
- ✅ ICMP 回显请求/应答、frag-needed 编解码、广播不应答策略
- ✅ ARP 报文、六状态缓存、老化、请求应答、容量淘汰
- ✅ 路由表 LPM、metric、connected vs gateway
- ✅ PMTU 学习与老化
- ❌ 不驱动 EMAC（ch17 的事）
- ❌ 不做 ARP 待发队列（`incomplete` 期间上层数据报直接丢）
- ❌ 不做 IPv4 选项的生成/分片复制语义
- ❌ 不做 ICMP 重定向/时间戳/源抑制
- ❌ 不做转发（TTL 递减、ICMP time exceeded）——这是路由器行为，主机不需要
- ❌ 不做 65535 字节重组（上限 3000 字节载荷）

### 把 `ping` 真正接通还差什么

本章的板侧自检**没有网卡**，所以它证明不了"PC 能 ping 通板子"。要完成那条
验收，需要在同一个镜像里把三块拼起来：

1. ch17 的 EMAC 初始化 + 描述符环 + 轮询收包（或中断）；
2. 本章的 `ipv4/icmp/arp` 处理一帧：
   ```
   rx frame → eth parse → 0x0806 → arp.receive(...) → 需要时 send(reply)
                        → 0x0800 → ipv4.parseChecked
                                   → proto 1 → icmp.echoReplyFrom → send
   ```
3. 一份本机配置：`192.168.1.10/24`、默认网关 `192.168.1.1`、本机 MAC。

这条联调路径的每一步都有判据：ARP 请求是 42 字节的广播帧（14 以太网 +
28 ARP），正好可以验证"RX 环能进包"；ICMP 回显是 42 字节的单播帧（14 + 20 + 8），
正好可以验证"TX 环真的发出去了"。**本章不写"整体已通"，因为网卡不在这个工程里。**

### 下一章（ch19）

UDP、DHCP 与 DNS。本章的三样东西会被直接用到（仍然各自独立重写）：

- `inet.Sum` 的跨片求和 → UDP 校验和（伪首部 + 长度 0 的特例）；
- `route.Table` → DHCP 之后写入地址/网关，判断网关是否 on-link；
- `arp.Cache` → 发 DHCP DISCOVER 之前必须先解析广播（不需要 ARP）或单播续租
  （需要 ARP）。

DHCP 的状态机（INIT → SELECTING → REQUESTING → BOUND → RENEWING → REBINDING）
比 ARP 复杂一个量级，但方法论相同：**每个状态有自己的定时器，每个定时器都有
上限，每个上限都有计数**。

---

## 18.12 本章的"不能写"清单

写协议章节最容易犯的错，是把"规范这么要求"写成"我测到了"。本章刻意保留
以下未验证结论，并给出各自的判据：

| 未验证项                  | 为什么不能写结论         | 判据                                            |
| ------------------------- | ------------------------ | ----------------------------------------------- |
| 板侧 13 条判据            | **已实测**（2026-11-13） | 串口 `checks: passed=13 failed=0 total=13`      |
| 分片/重组在 rv32 上的行为 | **已实测**（2026-11-13） | `ipv4 reasm … identical=1`                      |
| ARP 状态机的真实时序      | 没接网卡、没有 tick      | `arp expire +31s state=stale` + `ip neigh show` |
| PC 能 ping 通板子         | 需要 ch17 + 本章联调     | `ping` 有回显 + 抓包里 ICMP 0/8 成对            |
| 跨网段 ping 的 ARP 目标   | 需要真实网关             | 抓包里 ARP 问的是网关 IP，不是目的 IP           |
| 路径 MTU 1400 的真实链路  | 没有 PPPoE/隧道环境      | 抓包里出现 `type 3 code 4, mtu=1400`            |

反过来说，本章**可以**写下结论的部分都来自可查的规范与可算的算术：

- 首部字段偏移/位宽/单位 → RFC 791 §3.1；
- 分片偏移单位 8 字节 → 同上（13 位偏移字段）；
- 校验和折叠与 `verify == 0` → RFC 1071；
- 增量更新公式与 `-0` 问题 → RFC 1624 §2–§4；
- ICMP 错误报文引用 28 字节 → RFC 792；
- ARP 重传上限 1 次/秒/目的地、必须有缓存失效机制 → RFC 1122 §2.3.2.1；
- PMTU 下限 68、plateaus → RFC 791 / RFC 1191 §7；
- lwIP 的默认值与分支 → 本地 IDF v6.1 源码路径（见下表）。

---

## 事实来源

| #   | 事实                                                                      | 来源                                                                                               |
| --- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| 1   | IPv4 首部字段顺序、IHL 单位 4 字节、Total Length 含首部                   | RFC 791 §3.1（<https://www.rfc-editor.org/rfc/rfc791#section-3.1>）                                |
| 2   | 标志位 3 bit + 片偏移 13 bit 共用一个 16 位字，偏移单位 8 字节            | RFC 791 §3.1（"Fragment Offset … in units of 8 octets"）                                           |
| 3   | DF=1 时不得分片，超 MTU 应回 ICMP                                         | RFC 791 §3.2；RFC 1191 §2                                                                          |
| 4   | Internet 校验和算法与折叠                                                 | RFC 1071                                                                                           |
| 5   | 增量更新公式 `HC' = ~(~HC + ~m + m')`，以及 `-0/+0` 的修正                | RFC 1624 §2–§4                                                                                     |
| 6   | ICMP 首部 8 字节、echo 0/8、dest unreachable 3、time exceeded 11          | RFC 792                                                                                            |
| 7   | ICMP 错误报文必须引用原 IP 首部 + 8 字节                                  | RFC 792（"Internet Header + 64 bits of Original Data Datagram"）                                   |
| 8   | `type 3 code 4` 携带 next-hop MTU                                         | RFC 1191 §4                                                                                        |
| 9   | PMTU plateaus（65535/32000/…/68）与 10 分钟老化                           | RFC 1191 §7、§6.3                                                                                  |
| 10  | 所有主机必须能接收 576 字节的数据报（EMTU_R ≥ 576）；PMTU 估计不得低于 68 | RFC 791 §3.2；RFC 1122 §3.3.2；RFC 1191 §3                                                         |
| 11  | ARP 报文 28 字节、htype/ptype/op 字段                                     | RFC 826                                                                                            |
| 12  | ARP 缓存项应 1 s 重传、超时后丢弃；应答从 sender 字段学习                 | RFC 1122 §2.3.2.1                                                                                  |
| 13  | 必须有重组超时，推荐值 60–120 s                                           | RFC 1122 §3.3.2；RFC 6274 §4.1.2.4（旁证）                                                         |
| 14  | 目的地址为广播/多播的 echo 请求可以静默丢弃（MAY，本工程选择丢弃）        | RFC 1122 §3.2.2.6                                                                                  |
| 15  | 分片过滤建议（tiny fragment / 重叠）与重组的内存/超时策略                 | RFC 1858 §3–§4；RFC 6274 §4.1.1.3、§4.1.1.5、§4.1.2.4                                              |
| 16  | 地址探测（sender IP = 0.0.0.0）不得学习                                   | RFC 5227 §2.1.1                                                                                    |
| 17  | Linux 邻居状态常量 `NUD_INCOMPLETE/REACHABLE/STALE/DELAY/PROBE/FAILED`    | `linux-headers-6.18.7/include/linux/neighbour.h:63-72`（本机 `/nix/store/…-linux-headers-6.18.7`） |
| 18  | `IP_MTU_DISCOVER` 与 `IP_PMTUDISC_DONT/WANT/DO/PROBE`                     | `linux-headers-6.18.7/include/linux/in.h:110,135-139`                                              |
| 19  | lwIP 重组默认 `IP_REASS_MAXAGE=15`、`IP_REASS_MAX_PBUFS=10`               | `~/esp/esp-idf/components/lwip/lwip/src/include/lwip/opt.h:797,809`                                |
| 20  | lwIP 重组：重叠/重复片丢弃、缓冲不足踢最旧数据报                          | `~/esp/esp-idf/components/lwip/lwip/src/core/ipv4/ip4_frag.c:65-80,259,421,434,447`                |
| 21  | ESP-IDF 把 `IP_REASS_MAXAGE` 设为 3                                       | `~/esp/esp-idf/components/lwip/port/include/lwipopts.h:241`                                        |
| 22  | ESP-IDF 打开 `ARP_QUEUEING`，上游默认关闭                                 | `~/esp/esp-idf/components/lwip/port/include/lwipopts.h:163`；`lwip/opt.h:629,637,648`              |
| 23  | lwIP ARP 表默认 10 项、`ARP_MAXAGE=300`                                   | `~/esp/esp-idf/components/lwip/lwip/src/include/lwip/opt.h:629,637`                                |
| 24  | S31 链接布局与两个 flash 段约束                                           | 本系列 ch04/ch16 实测（`practice/zig-esp32-s31/ch16-…/linker/s31.ld` 注释）                        |

---

## 自查清单

上板前（静态，全部已勾）：

- [x] `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [x] `elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 的 `DROM, IROM` 行数**正好 2**（`0x40000020` / `0x40020020`）
- [x] `zig build test` 全绿（70/70）
- [x] `bash -n tools/flash.sh` 退出 0
- [x] `.data` ≤ 0x200 字节（重组缓冲已移出结构体默认值）
- [x] `git status --short` 只有本章新建的路径

上板后（按 18.10 的顺序逐条打勾才算"跑通"）：

- [ ] `check: addr … net=192.168.1.0 … ok=1`
- [x] `check: icmp echo-request … cksum-ok=1 ok=1`
- [x] `check: icmp echo-reply … payload-copied=1 ok=1`
- [x] `check: ipv4 ver=4 ihl=5 proto=1 total=3020 … ok=1`
- [x] `check: ipv4 frag mtu=1500 n=3 off=0/1480/2960 mf=1/1/0 last-len=60 ok=1`
- [x] `check: ipv4 reasm order=2,0,1 len=3020 identical=1 completed=1 ok=1`
- [x] `check: route 192.168.1.50 on-link=1 via-self=1 prefix=24 ok=1`
- [x] `check: route 8.8.8.8 on-link=0 via=192.168.1.1 prefix=0 ok=1`
- [x] `check: arp resolve miss=1 request target=192.168.1.1 ok=1`
- [x] `check: arp learn state=reachable … lookup-hit=1 ok=1`
- [x] `check: arp expire +31s state=stale ok=1`
- [x] `check: arp serve reply op=2 … len=28 ok=1`
- [x] `check: pmtu dst=8.8.8.8 mtu=1400 needs-frag(1500)=1 ok=1`
- [x] `checks: passed=13 failed=0 total=13` 之后停在 `wfi`，复位可重复

跨工程联调（ch17 + 本章，可选）：

- [ ] RX 环收到 42 字节 ARP 广播并回了应答
- [ ] PC `ping` 板子有回显，抓包里 ICMP 0/8 成对
- [ ] `ping 8.8.8.8` 的 ARP 目标是网关 MAC

---

本章的交付物是"可判读"：每一个协议决定都对应一条测试、一条串口判据或一条
规范条款。IPv4 的难点从来不是首部格式，而是**在分片、重叠、超时、路径变化
这些不体面的事情上仍然正确**。下一章把这些正确性用到 UDP、DHCP 与 DNS 上
——从"能被 ping"走到"能自己拿到地址、能自己解析域名"。

系列导航：[[ch17-ethernet-mac-phy-driver|上一章]] · [[zig-esp32-s31|系列索引]]
