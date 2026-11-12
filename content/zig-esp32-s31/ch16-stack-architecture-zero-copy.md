---
title: "Zig × ESP32-S31 全栈开发（十六）：协议栈架构、缓冲与零拷贝"
date: 2026-11-29 12:00:00
description: "进入网络底座：netif 抽象、pbuf 链与引用计数、拷贝点的显式化、IPv4/UDP/TCP 校验和与伪首部、RFC 1624 增量更新、哈希时间轮，以及一套不需要开发板的主机侧测试骨架（55 个用例）与板侧最小 loopback 自检。"
tags: [zig, esp32-s31, networking, pbuf, zero-copy, checksum, timer-wheel, series]
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
> 16. **第十六章：协议栈架构、缓冲与零拷贝**
> 17. [[ch17-ethernet-mac-phy-driver|第十七章：以太网 MAC/PHY 驱动]]

# Zig × ESP32-S31 全栈开发（十六）：协议栈架构、缓冲与零拷贝

从这一章开始进入「网络底座」。目标很具体：先不碰 Wi-Fi、不碰厂商 blob，用一条**完全可解释**的路径把以太网帧收发、IPv4 首部、校验和、定时器讲透。而所有网络代码的第一性问题不是「协议长什么样」，而是——

> 这段字节现在归谁？谁会改它？谁负责把它还回去？

这一章不写驱动，只把协议栈内部的**内存宪法**立起来：netif 是唯一的层间接口，pbuf 是唯一的报文容器，校验和是唯一的全局扫描，时间轮是唯一的超时机制。为了让这些结论可验证，工程把主要交付放在主机侧：`zig build test` 跑 55 个用例，不需要开发板、不需要 root、不需要 TAP 设备。

> [!warning] 本章的证据边界
>
> - `zig build test` → **`All 55 tests passed`**（54 个具名用例 + 根文件容器 test，2026-11-13，x86_64 / Zig 0.17.1）——**已跑通**。
> - 板侧镜像：`zig build -Dtarget=riscv32-freestanding-eabihf ... -Doptimize=ReleaseSmall` 退出 0；`esptool elf2image` 打印 `Merged 2 ELF sections.`；`image-info` 的 Segments 表正好两个 flash 段 `0x40000020` / `0x40020020`——**已跑通**。
> - 板侧自检**已上板（2026-11-13）**：`checks: passed=6 failed=0 total=6`，原始输出 `../logs/ch16-boot.log`；
>   本文 `check:` 行即该日志原文。
> - 协议语义来自公开 RFC（1071/1624/768/791/9293/6298）；实现参照来自本地 IDF v6.1 内的 lwIP 源码，具体行号见 `## 事实来源`。

---

## 16.1 先分层，再谈零拷贝

把「零拷贝」挂在嘴边的人，通常说不清三件事：拷贝了几次、拷贝点在哪、谁能证明。这一章的做法是先把问题拆成四个**所有权问题**，每一个都对应一个数据结构或一次显式动作：

| 问题                               | 本章的答案                                              | 位置            |
| ---------------------------------- | ------------------------------------------------------- | --------------- |
| 一段报文由谁分配、由谁归还？       | 编译期定容的 pbuf 池，池空即 `error.NoSpace`            | `src/pbuf.zig`  |
| 同一段报文被两层同时持有时怎么办？ | `ref` 引用计数，`reference()` 是唯一合法共享方式        | `src/pbuf.zig`  |
| 剥首部要不要 memcpy？              | 不要。`eat()` 只移动 payload 视图                       | `src/pbuf.zig`  |
| 什么时候必须复制？                 | 只有当链路层要求「连续内存」时，`sendPbuf` 的 `scratch` | `src/netif.zig` |

这四条决定了后面所有设计。比如「校验和要不要先线性化」——如果 `Sum` 支持跨片字节流，就不需要；如果它只接受 `[]u8`，那么每一个 pbuf 链都要先拼成连续内存，零拷贝就成了一句空话。本章的 `Sum` 是流式的，所以链上求和真的不复制（16.5 有等式证明）。

分层的另一个好处是**测试边界清楚**。协议栈里可以分成三类代码：

```text
┌──────────────────────────────────────────────────────────────┐
│ 纯逻辑（主机可测）                                            │
│   pbuf 链 / 引用计数 / 校验和 / 首部编解码 / 时间轮            │
│   → zig build test：55 个用例，确定性、可重复、无需硬件        │
├──────────────────────────────────────────────────────────────┤
│ 接口逻辑（主机可测 + 板侧同一份代码）                          │
│   netif 输出路径 / MTU / EtherType 分派 / 丢弃计数             │
│   → 主机用 Loopback 替身；板侧用同一份实现跑一条闭环            │
├──────────────────────────────────────────────────────────────┤
│ 硬件逻辑（只能上板）                                          │
│   MAC 寄存器 / DMA 描述符 / PHY 自协商 / cache 维护            │
│   → ch17                                                      │
└──────────────────────────────────────────────────────────────┘
```

本章把下面两层都写完了，第三层留给下一章。这不是偷懒：把「能与硬件无关地验证的部分」先在主机上钉死，等到真机上出问题时，才不需要在「协议逻辑错 / 驱动错 / 编译错」之间猜。

---

## 16.2 主机侧 TAP 骨架：为什么“不需要板子”

先解释 TAP。Linux 的 `/dev/net/tun` 允许用户态程序创建一个**虚拟网卡**：

```text
    用户态进程                          内核
  ┌──────────────┐    read()      ┌──────────────┐
  │ tap0 (fd)    │◀───────────────│  tap0 网卡    │◀── 内核协议栈 / bridge
  │              │    write()     │              │
  │  你的协议栈  │───────────────▶│              │──▶ 对端可见的以太网帧
  └──────────────┘                └──────────────┘
```

写进 fd 的字节会变成一张「网卡收到/发出的以太网帧」，读 fd 拿到的是内核要发出去的帧。它把「协议栈实现」与「真实 MAC」解耦，是嵌入式网络开发里最有价值的测试基础设施之一。

但 TAP 有两个门槛：**需要 root（或 `CAP_NET_ADMIN`）**、**需要内核模块 `tun`**。本章的立场是：

- TAP 是**可选的加餐**，不是必跑步骤；
- 主路径是 `zig build test`，它用 `netif.Loopback` 做同形状的替身；
- 真的要用 TAP 时，把 open/read/write 三件事写成独立脚本，失败不影响主流程。

`Loopback` 不到 40 行，但形状和真实链路完全一致——因为它实现的就是同一个函数指针类型：

```zig
pub const LinkOutput = *const fn (ctx: *anyopaque, frame: []const u8) LinkError!void;
```

```zig
pub const Loopback = struct {
    buf: []u8,
    len: usize = 0,
    deliveries: u32 = 0,
    netif: Netif = undefined,

    pub fn init(self: *Loopback, buf: []u8, name: []const u8, mtu: u16) void {
        self.* = .{ .buf = buf };
        const ctx: *anyopaque = @ptrCast(self);
        self.netif = .{ .name = name, .mtu = mtu, .output_fn = output, .ctx = ctx };
    }

    fn output(ctx: *anyopaque, frame: []const u8) LinkError!void {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        if (frame.len > self.buf.len) return error.NoSpace;
        @memcpy(self.buf[0..frame.len], frame);
        self.len = frame.len;
        self.deliveries += 1;
    }
};
```

换成 TAP 时，`output` 里只是一行 `write(tap_fd, frame, frame.len)`，`ctx` 换成一个打开 `/dev/net/tun` 的 fd 与 `ifreq` 结构。**上层代码一个字都不用改**——这就是 netif 抽象真正买到的东西。

如果确实想跑 TAP，流程如下（需要 root，且非必跑）：

```bash
# 1) 创建并启用 tap0（需要 root）
sudo ip tuntap add dev tap0 mode tap user "$USER"
sudo ip link set tap0 up
sudo ip addr add 192.168.1.10/24 dev tap0   # 与本工程帧的 src 同一网段

# 2) 用引导程序把帧写进 tap0（示例，不属于本章验收）
python3 - <<'PY'
import struct, subprocess, sys
frame = bytes.fromhex(
    "020000000001" "020000000002" "0800"                      # eth
    "45000023 1c46 4000 4011 0000 c0a8010a c0a80101"           # ipv4(校验和为占位)
    "9c40 0007 000f 0000" "7a69672f733331"                    # udp + "zig/s31"
)
# 注意：上面帧的校验和是占位，真实回放请用工程里 buildFrame 的结果
print(len(frame), file=sys.stderr)
PY
```

上面脚本刻意**只写到校验和占位为止**：手抄十六进制帧是最容易出错的一步，与其在文章里塞一个可能错的向量，不如让读者用工程代码生成。这也是本章反复强调的原则——**能由代码算出来的数字，绝不手写**。

主机侧测试的三层金字塔，本章把第一、二层填满了：

| 层     | 内容                                       | 本章状态                 |
| ------ | ------------------------------------------ | ------------------------ |
| 单元   | pbuf/校验和/首部/时间轮，纯值，无 IO       | 54 个具名用例，全绿      |
| 集成   | `netif` + `Loopback`，构造帧、发送、再接收 | 9 个用例（含零拷贝断言） |
| 端到端 | TAP / 真机 MAC，需要 root 或开发板         | 本章不做，ch17 开始      |

---

## 16.3 pbuf：链、`tot_len` 与引用计数

lwIP 的 pbuf 是「一个报文可能由多块内存拼成」的经典表达。它的三条不变式值得逐字抄下来（`components/lwip/lwip/src/include/lwip/pbuf.h:198,200,218`）：

```c
/* For non-queue packet chains this is the invariant:
 * p->tot_len == p->len + (p->next? p->next->tot_len: 0)
 */
u16_t tot_len;
...
LWIP_PBUF_REF_T ref;
```

本章的 `Pbuf` 保留这三条，但把「池」显式化：

```zig
pub const Pbuf = struct {
    next: ?*Pbuf = null,
    payload: []u8,      // 当前视图：长度恒等于 len
    cap: usize,         // 块的原始容量；eat 只把视图往后推
    len: usize,
    tot_len: usize,
    ref: u16 = 1,
    kind: Kind = .pool,
};
```

为什么用「视图 + cap」而不是「指针 + 长度」两个裸字段？因为视图可以在不丢失「原始容量」的前提下前进：`eat` 剥掉 14 字节以太网首部时，`payload` 从 `buf[0..64]` 变成 `buf[14..64]`，`cap` 仍是 64。这样 `check()` 可以断言 `len <= cap`、`tot_len == len + next.tot_len`，而不需要记住「原来的起点在哪」。

池是编译期定容的：

```zig
pub fn Pool(comptime node_cap: usize, comptime block_size: usize) type {
    ...
    nodes_storage: [node_cap]Node = undefined,
    in_use: [node_cap]bool = @splat(false),
    stats: Stats = .{},
}
```

分配就是线性找一个未使用的槽（`node_cap` 很小，线性扫描比维护空闲链表更不容易写错）：

```zig
pub fn alloc(self: *Self, len: usize) Error!*Pbuf {
    if (len > block_size) {
        self.stats.exhausted += 1;
        return error.NoSpace;
    }
    var i: usize = 0;
    while (i < node_cap) : (i += 1) {
        if (self.in_use[i]) continue;
        self.in_use[i] = true;
        const node = &self.nodes_storage[i];
        node.pbuf = .{
            .next = null,
            .payload = node.storage[0..len],
            .cap = block_size,
            .len = len,
            .tot_len = len,
            .ref = 1,
            .kind = .pool,
        };
        self.stats.allocs += 1;
        const used: u32 = @intCast(self.inUse());
        if (used > self.stats.high_water) self.stats.high_water = used;
        return &node.pbuf;
    }
    self.stats.exhausted += 1;
    return error.NoSpace;
}
```

三个统计字段决定了「池够不够大」这件事能不能被回答：`allocs`、`exhausted`、`high_water`。没有它们，池太小只会表现为「偶尔收不到包」，而不是一条明确的 `error.NoSpace`。

`allocChain` 有一个容易忽视的细节：`tot_len` 只能从**链尾往前**累加。若从头往后写，你需要在创建每个节点时知道后面还有多少字节；从尾往头的写法只需要一个 `rest` 变量：

```zig
var cur: ?*Pbuf = head;
var rest = total;
while (cur) |q| {
    q.tot_len = rest;
    rest -= q.len;
    cur = q.next;
}
```

`allocChain` 失败时会 `errdefer` 把已分配的节点全部归还。这条不是洁癖：串口驱动在池耗尽后还能不能再次收包，取决于失败路径有没有漏归还。

---

## 16.4 所有权与拷贝点：`alloc`/`reference`/`eat`/`toLinear`

pbuf 的四个动作，恰好对应零拷贝的四种可能：

| 动作        | 复制字节？ | 语义                                           |
| ----------- | ---------- | ---------------------------------------------- |
| `alloc`     | 否         | 从池里切一块视图，`ref = 1`                    |
| `reference` | 否         | 整链 `ref += 1`，把「我也有权读它」登记下来    |
| `eat`       | 否         | 把链首的若干字节从视图中去掉，必要时归还空节点 |
| `toLinear`  | **是**     | 把链拼成一段连续内存（唯一显式的 `memcpy`）    |

`reference` 的实现只有五行，但它是**唯一**合法的共享方式：

```zig
pub fn reference(p: *Pbuf) *Pbuf {
    var cur: ?*Pbuf = p;
    while (cur) |q| {
        if (q.ref < std.math.maxInt(u16)) q.ref += 1;
        cur = q.next;
    }
    return p;
}
```

`free` 与它配对：整链每个节点 `ref -= 1`，归零的节点回池。

```zig
pub fn free(self: *Self, p: *Pbuf) u32 {
    var freed: u32 = 0;
    var cur: ?*Pbuf = p;
    while (cur) |q| {
        const nxt = q.next;             // 先存 next：q 可能马上被归还
        if (q.ref <= 1) {
            self.releaseNode(q);
            freed += 1;
        } else {
            q.ref -= 1;
        }
        cur = nxt;
    }
    return freed;
}
```

`eat` 是收包路径的核心。IPv4 首部 20 字节、UDP 首部 8 字节，全部靠移动视图剥掉：

```zig
pub fn eat(self: *Self, p: *Pbuf, n: usize) Error!?*Pbuf {
    const total = p.tot_len;
    if (n >= total) {
        var probe: ?*Pbuf = p;
        while (probe) |q| {
            if (q.ref != 1) return error.Shared;   // 有人在看，不能归还
            probe = q.next;
        }
        _ = self.free(p);
        return null;
    }

    var skip = n;
    var head: *Pbuf = p;
    while (skip >= head.len) {
        if (head.ref != 1) return error.Shared;
        const nxt = head.next orelse return null;
        skip -= head.len;
        self.releaseNode(head);
        head = nxt;
    }
    if (skip > 0) {
        head.payload = head.payload[skip..];
        head.len -= skip;
    }
    head.tot_len = total - n;
    return head;
}
```

`error.Shared` 这个分支值得单独讲。设想 A 层把链交给了 TCP 重传队列（`reference` 后 `ref = 2`），B 层又想 `eat` 掉首部并归还节点——如果实现「悄悄归还」，重传队列手里的指针就会指向池里的空闲块，下一个 `alloc` 覆写它，于是你会看到「重传的数据莫名其妙变成了别人的 HTTP 响应」。这是网络栈里最经典的 use-after-free，症状离现场很远。本章选择让调用方看见错误：

```zig
test "eat: 被共享的节点不能归还（error.Shared）" {
    var pool: Pool(4, 32) = .{};
    const chain = try pool.allocChain(&.{ 4, 6 });
    _ = reference(chain);
    try testing.expectError(error.Shared, pool.eat(chain, 10));
    // 一次 free 只降引用，链依然完整。
    try testing.expectEqual(@as(u32, 0), pool.free(chain));
    try testing.expectEqual(@as(usize, 2), pool.inUse());
    _ = pool.free(chain);
}
```

跨块 `eat` 也有一个必须写死的用例：首部被拆在两个 pbuf 里（比如 14 字节以太网首部 + 20 字节 IP 首部，但块边界在 10 字节处）。测试用 `allocChain(&.{ 10, 10, 8 })` 构造这种链，剥 14 字节后断言：

```zig
const rest = (try pool.eat(chain, 14)).?;
try testing.expectEqual(@as(usize, 14), rest.tot_len);
try testing.expectEqual(@as(usize, 6), rest.len);      // 第一块剩 6 字节
try testing.expectEqual(@as(u8, 14), rest.payload[0]); // 原第 14 字节
try testing.expectEqual(@as(u8, 20), rest.next.?.payload[0]);
```

`toLinear` 是唯一显式的复制点，它同时维护 `stats.linearize_copies`：

```zig
pub fn toLinear(self: *Self, p: *const Pbuf, out: []u8) Error![]const u8 {
    const need = p.tot_len;
    if (out.len < need) return error.NoSpace;
    var offset: usize = 0;
    var cur: ?*const Pbuf = p;
    while (cur) |q| {
        @memcpy(out[offset .. offset + q.len], q.payload);
        offset += q.len;
        cur = q.next;
    }
    if (need != 0) self.stats.linearize_copies += 1;
    return out[0..offset];
}
```

这个计数器不是装饰：主机侧的 `netif: 单块 pbuf 的发送是零拷贝` 断言 `copies=0`，
`netif: 多块 pbuf 必须线性化` 断言 `copies=1`。**实现一旦退化成先复制再算校验和，
这两个用例立刻变红。**

---

## 16.5 校验和：反码和、伪首部与奇偶字节

Internet 校验和（RFC 1071）的算法只有一句话：把字节流按大端两两成组做 16 位反码和，最后取反。真正的坑全在边界：

1. **奇数字节**要补一个零字节参与求和；
2. **跨片**时不能每片各自补零——第 3 个字节必须和下一片的第 1 个字节配对；
3. **伪首部**要参与 UDP/TCP 校验和，但不参与 IPv4 首部校验和；
4. **UDP 的 0 要变成 0xFFFF**（RFC 768：0 表示「未计算校验和」）。

先看第 2 条。若把「一个 pbuf」当作一次 `add` 调用，那么 `odd` 字段必须记住落单的高字节：

```zig
pub const Sum = struct {
    acc: u32 = 0,
    odd: ?u8 = null,

    pub fn add(self: *Sum, bytes: []const u8) void {
        var i: usize = 0;
        if (self.odd) |hi| {
            if (bytes.len == 0) return;
            self.absorb((@as(u16, hi) << 8) | bytes[0]);
            i = 1;
            self.odd = null;
        }
        while (i + 1 < bytes.len) : (i += 2) {
            self.absorb((@as(u16, bytes[i]) << 8) | bytes[i + 1]);
        }
        if (i < bytes.len) self.odd = bytes[i];
    }

    pub fn finish(self: Sum) u16 {
        var acc = self.acc;
        if (self.odd) |lo| acc += @as(u16, lo) << 8;
        while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
        return @truncate(~acc);
    }
};
```

`finish` 按值接收 `self`，所以可以重复调用而不破坏状态（有测试钉死）。这条看起来微不足道，但校验和经常需要「先算一遍看看、再算一遍写进去」，消耗式 API 会逼调用方复制整个累加器。

第 1、2 条由同一个测试守住：

```zig
test "checksum: 分片流式求和等于连续缓冲求和（含奇数长度片）" {
    const flat = "0123456789abcdefg"; // 17 字节：故意是奇数
    var whole = Sum{};
    whole.add(flat);

    var split = Sum{};
    split.add("0");
    split.add("1234567");
    split.add("89abcdefg");

    try testing.expectEqual(whole.finish(), split.finish());
    try testing.expectEqual(of(flat), ofSlices(&.{ "0", "1234567", "89abcdefg" }));
}
```

一个标准向量来自 RFC 1071 的示例，本章直接把它写成断言：

```zig
test "checksum: RFC 1071 的示例（00 01 f2 03 f4 f5 f6 f7 → 0x220d）" {
    const bytes = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try testing.expectEqual(@as(u16, 0x220d), of(&bytes));
}
```

第 3 条是伪首部。它的形状（RFC 791）：

```text
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-------+-------+-------+-------+-------+-------+-------+-------+
 |                       Source Address                          |
 +-------+-------+-------+-------+-------+-------+-------+-------+
 |                    Destination Address                        |
 +-------+-------+-------+-------+-------+-------+-------+-------+
 |  zero | Proto |            Length                             |
 +-------+-------+-------+-------+-------+-------+-------+-------+
```

注意第 9、10 字节是 `zero` 与 `proto`，按大端读成一个 16 位字就是 `0x00PP`——**不是** `proto << 8`。本章的 `pseudoSeed`：

```zig
pub fn pseudoSeed(src: [4]u8, dst: [4]u8, protocol: u8, length: u16) Sum {
    var s = Sum{};
    s.add(&src);
    s.add(&dst);
    // 伪首部的第 9、10 字节是 zero + protocol，按大端是一个 0x00PP 字。
    s.addWord(@as(u16, protocol));
    s.addWord(length);
    return s;
}
```

这个「写反了也能跑、只是校验和永远对不上」的错误非常常见，所以测试必须比对**完整重算**，而不是只断言「不为 0」：

```zig
var s = pseudoSeed(src, dst, 17, @intCast(datagram.len));
s.add(&datagram);
try testing.expectEqual(@as(u16, 0), s.finish());   // 写回校验和后整段求和为 0
```

第 4 条是 UDP 的 `0 → 0xFFFF`。lwIP 的注释几乎可以作为规范引用（`components/lwip/lwip/src/core/udp.c:883-885`）：

```c
/* chksum zero must become 0xffff, as zero means 'no checksum' */
if (udpchksum == 0x0000) {
  udpchksum = 0xffff;
}
```

本章的实现与测试：

```zig
pub fn udp(src: [4]u8, dst: [4]u8, udp_datagram: []const u8) u16 {
    var s = pseudoSeed(src, dst, 17, @intCast(udp_datagram.len));
    s.add(udp_datagram);
    const computed = s.finish();
    return if (computed == 0) 0xFFFF else computed;
}
```

```zig
// 构造一个“计算结果是 0”的数据报：src/dst 全 0、proto=17、长度 10，
// 伪首部与首部已贡献 17+10=0x1b，载荷补 0xffe4 正好凑成 0xffff → 取反得 0。
var edge: [10]u8 = @splat(0);
edge[8] = 0xff;
edge[9] = 0xe4;
const zero_addr = [4]u8{ 0, 0, 0, 0 };
try testing.expectEqual(@as(u16, 0xFFFF), udp(zero_addr, zero_addr, &edge));
```

TCP 校验和不做这个替换（`src/checksum.zig:108-112`），因为 TCP 没有「0 = 未计算」的约定。本章的 TCP 向量测试也验证了「写回校验和后整段求和为 0」。

---

## 16.6 增量更新：RFC 1624 与 `-0`

TTL 每跳减一，NAT 会改写地址。每次都重算整包显然浪费，于是有了增量公式。lwIP 在 `ip4.c:343-348` 里就做了这件事：

```c
/* Incrementally update the IP checksum. */
if (IPH_CHKSUM(iphdr) >= PP_HTONS(0xffffU - 0x100)) {
  IPH_CHKSUM_SET(iphdr, (u16_t)(IPH_CHKSUM(iphdr) + PP_HTONS(0x100) + 1));
} else {
  IPH_CHKSUM_SET(iphdr, (u16_t)(IPH_CHKSUM(iphdr) + PP_HTONS(0x100)));
}
```

它处理的是「和里少了一个 0x0100」。通用形式是 RFC 1624 的公式 (3)：

```text
HC' = ~(~HC + ~m + m')
```

本章实现：

```zig
pub fn update(old_checksum: u16, old_word: u16, new_word: u16) u16 {
    var acc: u32 = @as(u16, ~old_checksum);
    acc += @as(u16, ~old_word);
    acc += new_word;
    while (acc >> 16 != 0) acc = (acc & 0xFFFF) + (acc >> 16);
    return @truncate(~acc);
}
```

为什么不用更直观的 `HC' = HC - m + m'`？因为反码运算里 `-0`（`0xFFFF`）与 `+0`（`0x0000`）是两个不同的编码。当结果正好是 0 时，朴素公式会给出 `0x0000`，而接收方按反码校验会得到 `0xFFFF`——校验失败，包被丢。RFC 1624 的整篇文档就是在讲这件事。

测试的方式是「两条路径必须逐字节一致」：

```zig
const c = ipv4Header(&header);
const incremental = update(c, 0x4011, 0x3f11);   // TTL 64 → 63

var changed = header;
changed[8] = 63;
changed[10] = @truncate(incremental >> 8);
changed[11] = @truncate(incremental & 0xff);
try testing.expectEqual(@as(u16, 0), of(&changed));

// 增量结果必须与“校验和字段清零后整包重算”逐字节一致（这里是 0x9c2a）。
try testing.expectEqual(@as(u16, 0x9c2a), incremental);
```

第二组测试改的是源地址高 16 位（`10.0 → 172.16`），做同样的比对。两个数字并非从别处抄来，而是先用独立脚本算出、再写进测试——这也解释了为什么测试里能出现具体向量而文章里不写「大概是多少」。

---

## 16.7 首部编解码：严格解析的七条检查

IPv4 首部只有 20 字节，但它是全网最容易被畸形包攻击的地方。本章的 `Ipv4.parse` 依次做这些检查：

1. `buf.len >= 20`——最小首部都放不下，`error.Truncated`；
2. `version == 4`——`error.BadVersion`；
3. `ihl >= 5`——`error.BadIhl`（IHL=4 意味着首部 16 字节，非法）；
4. `ihl * 4 <= buf.len`——选项把首部撑出缓冲区，`error.Truncated`；
5. `total_len >= ihl * 4`——首部比整包还长，`error.BadLength`；
6. `total_len <= buf.len`——声称的长度超过实际收到的字节，`error.Truncated`；
7. 载荷视图 `buf[ihl*4 .. total_len]` 必须是合法切片。

对应实现：

```zig
pub fn parse(buf: []const u8) Error!Ipv4 {
    if (buf.len < min_len) return error.Truncated;
    const version: u4 = @truncate(buf[0] >> 4);
    const ihl: u4 = @truncate(buf[0] & 0x0F);
    if (version != 4) return error.BadVersion;
    if (ihl < 5) return error.BadIhl;

    const total_len = std.mem.readInt(u16, buf[2..4], .big);
    const header_len = @as(usize, ihl) * 4;
    if (total_len < header_len) return error.BadLength;
    if (total_len > buf.len) return error.Truncated;
    if (header_len > buf.len) return error.Truncated;
    ...
}
```

「拒绝」而不是「猜一个默认值」是这里的关键设计。真实网络里的畸形包远比想象的多，而一旦解析函数开始「容错」（比如版本不对就当 4 处理），后面所有计数、所有长度计算都会跟着错，问题会出现在离现场很远的地方。

另一个容易写错的细节是**分片标志的位序**。首部第 7、8 字节按大端组成 16 位字，最高 3 位是 `reserved/DF/MF`。Zig 的 `packed struct` 字段从 LSB 开始排布，所以定义顺序必须是 `mf → df → reserved`：

```zig
pub const FragFlags = packed struct(u3) {
    mf: bool = false,
    df: bool = false,
    reserved: bool = false,
};

const frag: u16 = (@as(u16, @as(u3, @bitCast(self.flags))) << 13) |
    @as(u16, self.frag_offset);
```

TCP 的 `data offset` 与 8 个标志位挤在第 13、14 字节里，同理：

```zig
pub const TcpFlags = packed struct(u8) {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,
    urg: bool = false,
    ece: bool = false,
    cwr: bool = false,
};
```

测试直接断言字节值，而不是断言「解析回来相等」——后者在编码与解码同时错的时候会假通过：

```zig
try testing.expectEqual(@as(u8, 0x50), buf[12]);  // data offset 5
try testing.expectEqual(@as(u8, 0x12), buf[13]);  // SYN(0x02) | ACK(0x10)
```

---

## 16.8 netif 抽象：MTU、输出函数与线性化边界

netif 是协议栈与链路层的唯一接口。lwIP 里对应两个函数指针（`components/lwip/lwip/src/include/lwip/netif.h:303,308`）：

```c
netif_output_fn output;        /* 协议栈 → netif：参数是 pbuf 链 */
netif_linkoutput_fn linkoutput; /* netif → 驱动：参数通常也是 pbuf 链 */
```

本章把它简化成「只接受连续字节」的一个出口：

```zig
pub const LinkOutput = *const fn (ctx: *anyopaque, frame: []const u8) LinkError!void;

pub const Netif = struct {
    name: []const u8,
    mtu: u16 = 1500,
    up: bool = true,
    output_fn: ?LinkOutput = null,
    ctx: ?*anyopaque = null,
    stats: Stats = .{},
};
```

这个简化是有意的：它把「链什么时候必须变成连续内存」压缩到一个函数里，而不是散布在驱动中。`sendPbuf` 就是这条边界的全部：

```zig
pub fn sendPbuf(self: *Netif, p: *const pbuf.Pbuf, scratch: []u8) LinkError![]const u8 {
    if (p.next == null) {
        try self.send(p.payload);
        return p.payload;      // 单块：零拷贝，返回的切片指向 pbuf 存储
    }
    if (scratch.len < p.tot_len) return error.NoSpace;
    var it = pbuf.SliceIter.init(p);
    var offset: usize = 0;
    while (it.next()) |part| {
        @memcpy(scratch[offset .. offset + part.len], part);
        offset += part.len;
    }
    self.stats.linearize_copies += 1;
    const flat = scratch[0..offset];
    try self.send(flat);
    return flat;
}
```

两个测试分别钉住两个分支：

```zig
test "netif: 单块 pbuf 的发送是零拷贝（返回的切片指向 pbuf 存储）" {
    ...
    const sent = try lo.netif.sendPbuf(p, &scratch);
    try testing.expect(@intFromPtr(sent.ptr) == @intFromPtr(p.payload.ptr));
    try testing.expectEqual(@as(u32, 0), lo.netif.stats.linearize_copies);
}
```

```zig
test "netif: 多块 pbuf 必须线性化，计数一次、字节顺序正确" {
    ...
    try testing.expectEqual(@as(usize, 45), sent.len);
    try testing.expectEqual(@as(u32, 1), lo.netif.stats.linearize_copies);
    try testing.expect(@intFromPtr(sent.ptr) == @intFromPtr(&scratch));
    try testing.expectEqual(@as(u8, 0), sent[0]);
    try testing.expectEqual(@as(u8, 100), sent[14]);
    try testing.expectEqual(@as(u8, 200), sent[34]);
    try testing.expectEqual(@as(u8, 250), sent[42]);
}
```

注意第二个测试用**互不相同**的字节填充每一块（0/100/200/250 起），这样才能证明拼接顺序正确；如果四块都填 0，任何顺序都会通过。

MTU 检查放在 `send` 里而不是调用方，理由很实际：每个发送点都记得检查 MTU 是不可能的；漏一次就会让超大帧进入 DMA，症状是「大包丢、小包通」。

```zig
pub fn send(self: *Netif, frame: []const u8) LinkError!void {
    if (!self.up) return error.LinkDown;
    if (frame.len > self.mtu) {
        self.stats.drops_mtu += 1;
        return error.MtuExceeded;
    }
    const out = self.output_fn orelse return error.LinkDown;
    const ctx = self.ctx orelse return error.LinkDown;
    try out(ctx, frame);
    self.stats.tx_frames += 1;
    self.stats.tx_bytes += @intCast(frame.len);
}
```

接收侧只做最小分派：长度、EtherType、IPv4 首部校验和。其余交给后续章节。

```zig
switch (eth.ethertype) {
    .ipv4 => {
        const ip = headers.Ipv4.parse(body) catch |err| switch (err) { ... };
        if (!ip.verifyChecksum(body[0..ip.headerLen()])) {
            self.stats.drops_bad_checksum += 1;
            return .{ .kind = .dropped, .reason = .bad_ip_checksum };
        }
        return .{ .kind = .ipv4, .ip = ip };
    },
    .arp => return .{ .kind = .arp },
    else => {
        self.stats.drops_ethertype += 1;
        return .{ .kind = .dropped, .reason = .unknown_ethertype };
    },
}
```

`rx_frames` 与 `rx_bytes` 在**最前面**就累加（甚至包括 runt），因为它们描述的是「链路交付了多少字节」；而 `drops_*` 描述的是「为什么没往上送」。两类计数不能混在一起，否则排障时会得出「收到 0 帧」这种明显错误的结论。

---

## 16.9 timer wheel：为什么排序链表不够

lwIP 的超时管理是一条按到期时间排序的链表（`components/lwip/lwip/src/core/timeouts.c:208-219`）：

```c
if (next_timeout == NULL) {
  next_timeout = timeout;
  return;
}
if (TIME_LESS_THAN(timeout->time, next_timeout->time)) {
  timeout->next = next_timeout;
  next_timeout = timeout;
} else {
  for (t = next_timeout; t != NULL; t = t->next) {
    if ((t->next == NULL) || TIME_LESS_THAN(timeout->time, t->next->time)) {
      timeout->next = t->next;
      t->next = timeout;
      ...
```

插入要顺序找到位置，最坏 O(n)。连接数少时完全够用；但 TCP 的每个连接都有重传计时器（RFC 6298 的 RTO），几百个连接加上 ARP 老化、DHCP 租期，链表就会变成热点。

哈希时间轮把「到期时间」变成桶号：

```text
bucket = expire_at % slots
```

每个 tick 只处理 `now % slots` 一个桶，复杂度 O(桶内元素数)。跨度大于一圈（`slots` 个 tick）的计时器被扫到时还没到期，就**原地放回**——`expire_at` 不变，桶号也不变，于是它会在下一圈的同一个槽被再次看到：

```zig
pub fn tick(self: *Self) void {
    self.now +%= 1;
    const bucket: usize = @intCast(self.now % slot_count);
    var cur = self.buckets[bucket];
    self.buckets[bucket] = null;

    while (cur) |idx| {
        const e = &self.entries[idx];
        const nxt = e.next;
        e.next = null;

        // 到期的判定必须考虑 u32 回绕：差值的符号位表示“还没到”。
        const delta = e.expire_at -% self.now;
        const due = @as(i32, @bitCast(delta)) <= 0;
        if (due) {
            e.active = false;
            e.queued = true;
            self.pushDue(idx, e.id, e.expire_at);
            self.stats.expired += 1;
        } else {
            // 大跨度计时器：expire_at 不变 → 桶号不变 → 下一圈再见。
            self.insert(idx, e.expire_at);
            self.stats.reinserted += 1;
        }
        cur = nxt;
    }
}
```

同一槽内 deadline 相同的计时器按“头插 → 后进先出”出队：这是实现细节，不是语义承诺，
需要严格顺序的调用方应当把序号编码进 `id` 自己排序。跨 tick 的到期事件则严格按
到期先后进入 `due` 队列（有 `跨 tick 的到期事件按到期先后 FIFO 出队` 的用例）。

有三个设计点值得说明。

**一、到期不回调，只入队。** `tick` 里不执行任何用户代码，调用方随后 `popDue()`。这避免了“回调里再 schedule 导致重入”的经典死锁——TCP 重传处理里几乎必然要重新 schedule。lwIP 用 `sys_timeout` 回调 + 递归保护来处理同一个问题，本章选择更笨但更可测的形状。

**二、句柄带 generation。** `cancel` 传入的句柄可能已经过期（计时器早就触发、槽位被复用）。只比较下标会误杀新计时器：

```zig
pub const Handle = struct {
    index: u16,
    generation: u16,
};
```

```zig
test "wheel: 到期后旧句柄的 cancel 不会误杀复用槽位的新计时器" {
    var w = Wheel(4, 4).init();
    const old = try w.schedule(1, 1);
    w.advance(1);
    _ = w.popDue().?;

    const fresh = try w.schedule(2, 2);
    try testing.expectEqual(old.index, fresh.index); // 槽位确实被复用了
    try testing.expect(!w.cancel(old));              // generation 不同 → 拒绝
    try testing.expectEqual(@as(usize, 1), w.activeCount());
    ...
}
```

**三、回绕必须用有符号差值。** `u32` 的 tick 计数在 49.7 天（1 ms/tick）后回绕。直接比较 `expire_at <= now` 会在回绕那一刻把**所有**计时器一次性触发。本章用：

```zig
const delta = e.expire_at -% self.now;
const due = @as(i32, @bitCast(delta)) <= 0;
```

只要「到期时间与当前时间的距离小于 2^31 个 tick」（约 24.9 天），有符号比较就是正确的。测试把 `now` 手动设成 `0xFFFF_FFFE`，调度一个 4 tick 后的计时器（到期于 `0x0000_0002`），验证它仍然准时：

```zig
test "wheel: u32 回绕附近仍然准时（now 接近 0xffffffff）" {
    var w = Wheel(4, 8).init();
    w.now = 0xFFFF_FFFE;
    _ = try w.schedule(9, 4); // 到期于 0x00000002
    w.advance(3);
    try testing.expect(w.popDue() == null);
    w.advance(1);
    const d = w.popDue().?;
    try testing.expectEqual(@as(u32, 9), d.id);
    try testing.expectEqual(@as(u32, 2), d.at); // at 是绝对 tick，已回绕到 2
}
```

`at` 保留的是**绝对 tick**，所以回绕在 `Due` 里是可见的：id 9 的到期时刻
读出来是 2，而不是 `0x1_0000_0002`。需要「距离现在多久」的调用方用
`at -% now` 自行换算。

时间轮还有一个副作用是好东西：`nextDeadline()` 告诉你「最早什么时候要醒」。tickless 调度（ch11 讨论过）就是靠它决定睡眠时长——**不需要每毫秒醒一次**。

| 结构             | 插入     | tick     | 取消     | 内存         |
| ---------------- | -------- | -------- | -------- | ------------ |
| 排序链表（lwIP） | O(n)     | O(1)~    | O(n)     | 每计时器一项 |
| 哈希时间轮       | O(1)     | O(1) 桶  | O(桶内)  | 固定数组     |
| 最小堆           | O(log n) | O(log n) | O(log n) | 每计时器一项 |

本章选时间轮，最重要的一条是**内存可预算**：`Wheel(8, 8)` 就是 8 个条目 + 8 个桶，编译期就知道占多少 `.bss`。

---

## 16.10 板侧骨架与自检判读

板侧只保留一条闭环，`src/selftest.zig` 里 6 条判据：

1. **构造帧**：以太网 14 + IPv4 20 + UDP 8 + 载荷 7（`"zig/s31"`）= 49 字节；
   校验和真算、真写入；
2. **loopback 发送**：`netif.send` → 后备缓冲；断言字节完全一致、`tx_frames=1`；
3. **以太网解析**：EtherType `0x0800`、目的 MAC `02:00:00:00:00:01`；
4. **IPv4**：`ver=4 ihl=5 ttl=64 proto=17 total=35`，首部校验和验证通过；
5. **UDP**：`sport=40000 dport=7 len=15`，伪首部求和验证为 0；
6. **载荷与接收分派**：`dgram[8..]` 等于 `"zig/s31"`（原帧切片，未复制），
   `netif.receive` 把它分类为 `.ipv4`。

站内代码浏览（不离开站点看高亮源码）：

| 文件                  | 代码浏览                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------ |
| `build.zig`           | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/build.zig)           |
| `linker/s31.ld`       | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/linker/s31.ld)       |
| `src/pbuf.zig`        | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/pbuf.zig)        |
| `src/checksum.zig`    | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/checksum.zig)    |
| `src/headers.zig`     | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/headers.zig)     |
| `src/netif.zig`       | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/netif.zig)       |
| `src/timer_wheel.zig` | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/timer_wheel.zig) |
| `src/selftest.zig`    | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/selftest.zig)    |
| `src/host_tests.zig`  | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/host_tests.zig)  |
| `src/main.zig`        | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/main.zig)        |
| `src/start.zig`       | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/start.zig)       |
| `tools/flash.sh`      | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/tools/flash.sh)      |

这些判据的形状有个共同点：**每条都打印参与比较的数值**，而不是只打印 `ok`。前几章已经踩过「判据被编译器折叠成恒真/恒假」的坑（ch15 的 `sram stack ok=0`），所以这里的原则是——失败时必须能从串口那一行直接看出「哪个值不对」。

`check()` 的实现只有十几行：

```zig
fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        g_passed += 1;
    } else {
        g_failed += 1;
    }
    var text_buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch "print-fail";
    log.line("check: {s} ok={d}", .{ text, @intFromBool(ok) });
}
```

注意它先格式化正文、再拼 `ok=`，所以任何一行都同时带着「参数值」和「结论」。这比「PASS/FAIL + 编号」好用得多：编号需要查表，而参数值本身就是现场。

板侧代码只用静态内存，两个 96 字节缓冲就够：

```zig
var g_frame: [96]u8 = undefined;       // 构造出的以太网帧
var g_lo_backing: [96]u8 = undefined;  // loopback 的“网线”
var g_lo: netif.Loopback = undefined;
```

**pbuf 链与时间轮的演示不放进板侧**：它们已经由 26 个主机侧用例覆盖，板侧再跑一遍
只会增加“出错但无法归因”的表面。板侧的职责是一件事——证明首部/校验和/netif
这部分代码在 rv32 上、在真实 SRAM 布局下仍然自洽。链接脚本的 SRAM 区间是
`0x2F000000..0x2F07AFC0`，192 字节的静态缓冲在这里可以忽略，但它同样说明了
「这条路径不依赖堆」——对没有 PSRAM 的板子、以及「堆碎片已把系统拖垮」的现场，
这一点比多跑两个 demo 重要。

---

## 16.11 构建、镜像与烧录

### 16.11.1 主机侧（本章的主要验收）

```bash
cd practice/zig-esp32-s31/ch16-stack-architecture-zero-copy
zig build test --summary all
zig test src/host_tests.zig      # 想直接看到 "All 55 tests passed"
```

`zig build test` 只编译 `src/host_tests.zig`，它只 import 五个纯逻辑模块。测试数与分布：

| 模块              | 具名用例 | 覆盖                                                        |
| ----------------- | -------: | ----------------------------------------------------------- |
| `pbuf.zig`        |       14 | 池分配/链/tot_len/引用计数/`eat`（含跨块与共享）/`toLinear` |
| `checksum.zig`    |       10 | RFC 1071 向量、奇偶字节、伪首部、UDP 0→FFFF、RFC 1624       |
| `headers.zig`     |        9 | Eth/IPv4/UDP/TCP 往返、位序、六类畸形包拒绝                 |
| `netif.zig`       |        9 | MTU、丢弃计数、零拷贝与线性化两条路径、`LinkDown`           |
| `timer_wheel.zig` |       12 | 到期精度、FIFO、跨度大于槽数、取消、句柄复用、回绕          |

合计 54 个具名用例 + 根文件容器 test = 55。

### 16.11.2 应用 ELF

```bash
zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

### 16.11.3 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

本次实测输出（2026-11-13，esptool 5.6.0）：

```text
Merged 2 ELF sections.
Image size: 69024 bytes
Segments: 4
Segments Information
Segment   Length   Load addr   File offs  Memory types
      0  0x01f00  0x40000020  0x00000018  DROM, IROM
      1  0x0006c  0x2f000000  0x00001f20  DRAM, BYTE_ACCESSIBLE, IRAM
      2  0x0e07c  0x00000000  0x00001f94  PADDING
      3  0x00d5c  0x40020020  0x00010018  DROM, IROM
Checksum: 0x97 (valid)
```

注意 `Segments: 4` 与「正好两个 flash 段」并不矛盾：只有 0 号（`0x40000020`，
`.flash.text`）与 3 号（`0x40020020`，`.flash.rodata`）的 `Memory types` 是
`DROM, IROM`；1 号是 SRAM 的 DRAM 装载段，2 号是镜像加载器的 PADDING 段。
S31 的二级 bootloader 断言 `rom_index == 2`，所以「正好两个」不是风格问题，
是硬性要求（详见 ch03/ch04 与 `../BRINGUP-2026-11-12.md`）。

### 16.11.4 bootloader、分区表与烧录

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..

sh tools/flash.sh /dev/ttyUSB0
```

`flash.sh` 读 `flash_args`，保留 bootloader 与 partition-table 两行、把 `0x10000` 的应用行替换成 `zig-out/bin/app.bin`。偏移一律不手抄——手抄偏移是「烧了但跑不起来」的最常见原因。

---

## 16.12 零拷贝路径图与拷贝点清单

把本章的结论画成一张图。箭头上的数字是「复制次数」：

```text
应用数据（常量/栈/DMA 环）
   │
   │ 0: pbuf.alloc + 填入（这里通常是驱动直接在 DMA 缓冲上造视图）
   ▼
pbuf 链 ──reference──▶ 另一层（重传队列/应用缓存）   0 次复制
   │
   │ 0: eat(14) / eat(20) 剥首部（只移动视图）
   ▼
传输层 pbuf 视图
   │
   │ 0: Sum.add(iter) 链上算校验和（不线性化）
   ▼
netif.sendPbuf
   ├── 单块 → linkoutput(payload)                     0 次复制
   └── 多块 → linkoutput(scratch)                     1 次复制（唯一）
```

对应的拷贝点清单：

| 编号 | 位置                          | 何时发生                    | 可避免？                        |
| ---- | ----------------------------- | --------------------------- | ------------------------------- |
| C1   | `pbuf.toLinear`               | 调用方要求连续内存          | 若链路支持 scatter-gather，可免 |
| C2   | `netif.sendPbuf` 的 `scratch` | pbuf 链长度 > 1             | 同上；或让驱动吃链              |
| C3   | `Ipv4.write` / `Udp.write`    | 构造首部（20/8 字节，很小） | 不可免，属协议开销              |
| C4   | `Loopback.output`             | 仅测试替身                  | 真实链路无此项                  |

C1 与 C2 在本章是**同一个动作的两种入口**：`toLinear` 给应用用，`sendPbuf` 给协议栈用。C3 是不可避免的——你总要把首部字段写进某个缓冲；它的规模是 20/8 字节，与载荷无关。

C4 提醒一件事：`Loopback` 会复制整帧，所以**不能**用它测吞吐。想知道真实拷贝成本，必须上板读 MAC 的 DMA 计数（ch17）。

这也是「零拷贝」这个词最容易被误用的地方：它从来不是「一次都不复制」，而是**每一次复制都有名字、有位置、有计数器**。本章的 `stats.linearize_copies` 就是那个计数器；主机侧两个 netif 用例分别断言它在单块发送后仍为 0、在多块线性化时恰好加 1。

---

## 16.13 下一章预告

本章把协议栈「不碰硬件的那一半」写完了：内存所有权、校验和、首部编解码、层间接口、超时机制。所有这些在 `zig build test` 里都有确定性证据。

下一章开始碰硬件：以太网 MAC/PHY 驱动。要处理的具体问题是——RGMII 时序与引脚复用、MDIO 读 PHY ID、DMA 描述符环的所有权（谁来回收已发送的描述符）、cache 维护（S31 的 D-cache 与 DMA 一致性）、以及中断与轮询两种收包模式的取舍。

那时本章的 `LinkOutput` 会有真正的实现：不再抄进 `buf`，而是把描述符交给 MAC；`pbuf.Pool` 会与描述符一一对应；`timer_wheel` 会开始承担 PHY 自协商超时与链路状态轮询。**这一章的 55 个测试会继续跑**——驱动的加入不应该让任何一条纯逻辑断言改变。

---

## 事实来源

| 事实                                                                                             | 来源（本地 / 公开）                                                                                                                      |
| ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| pbuf 的 `tot_len` 不变式与 `ref` 语义                                                            | `~/esp/esp-idf/components/lwip/lwip/src/include/lwip/pbuf.h:196-200,218`                                                                 |
| pbuf 的 `PBUF_RAM/ROM/REF/POOL` 分类                                                             | 同上 `:140-165`                                                                                                                          |
| `netif.output` / `netif.linkoutput` 的函数指针形状                                               | `~/esp/esp-idf/components/lwip/lwip/src/include/lwip/netif.h:192,215,303,308`                                                            |
| 伪首部校验和对 pbuf 链计算（不线性化）                                                           | `~/esp/esp-idf/components/lwip/lwip/src/core/inet_chksum.c:309-311`                                                                      |
| UDP 校验和 0 必须写成 0xFFFF                                                                     | `~/esp/esp-idf/components/lwip/lwip/src/core/udp.c:883-885`（RFC 768 同义）                                                              |
| IPv4 首部校验和的增量更新（TTL 递减）                                                            | `~/esp/esp-idf/components/lwip/lwip/src/core/ipv4/ip4.c:343-348`                                                                         |
| IPv4 首部校验和验证（不通过即丢包）                                                              | `~/esp/esp-idf/components/lwip/lwip/src/core/ipv4/ip4.c:565-568`                                                                         |
| 超时管理是有序链表（插入 O(n)）                                                                  | `~/esp/esp-idf/components/lwip/lwip/src/core/timeouts.c:126,208-219`                                                                     |
| Internet 校验和算法与示例向量                                                                    | RFC 1071 §3（`00 01 f2 03 f4 f5 f6 f7` → `0x220d`）                                                                                      |
| 增量更新公式 (3) 与 -0/+0 的区别                                                                 | RFC 1624 §3、§4                                                                                                                          |
| UDP 校验和「0 表示未计算」                                                                       | RFC 768                                                                                                                                  |
| IPv4 首部格式、伪首部格式                                                                        | RFC 791 §3.1                                                                                                                             |
| TCP 首部与伪首部（校验和覆盖范围）                                                               | RFC 793 / RFC 9293 §3.1                                                                                                                  |
| RTO 与重传计时器                                                                                 | RFC 6298                                                                                                                                 |
| 哈希时间轮（hashed timing wheel）                                                                | Varghese & Lauck, _Hashed and Hierarchical Timing Wheels_（1987；ACM TOCS 1997 的多级扩展）                                              |
| SRAM 区间 `0x2F000000..0x2F07AFC0`、两个 flash 段断言                                            | `~/esp/esp-idf/components/esp_system/ld/esp32s31/memory.ld.in:19,23`、`ld.hp_mem_defs:9`；`../BRINGUP-2026-11-12.md`                     |
| `esp_app_desc_t` 256 字节与字段偏移                                                              | `~/esp/esp-idf/components/esp_app_format/include/esp_app_desc.h`                                                                         |
| RTC/LP WDT 关闭序列与 EN 的 WARL 行为                                                            | `../BRINGUP-2026-11-12.md:31`；ch05/ch15 的板级记录与 `_start`                                                                           |
| ROM 的 `ets_printf` / `ets_delay_us` 地址（`esp_rom_*` 是链接脚本的别名）                        | `~/esp/esp-idf/components/esp_rom/esp32s31/ld/esp32s31.rom.ld:24,30`（`0x2f800024` / `0x2f80003c`）；别名见 `linker/s31.ld` 的 `PROVIDE` |
| 主机测试结果 `All 55 tests passed`                                                               | 本工程 `zig test src/host_tests.zig`（2026-11-13，x86_64 / Zig 0.17.1）                                                                  |
| 镜像 `Merged 2 ELF sections`、两段 `0x40000020`/`0x40020020`、`Image size: 69024`、`Segments: 4` | 本工程 `esptool 5.6.0 elf2image` / `image-info`（2026-11-13）                                                                            |

---

## 自查清单

- [x] 章节日期 `2026-11-29 12:00:00`，位于 ch15（`2026-11-28 18:00:00`）之后
- [x] 章首导航 1–15 已发布章为 wikilink，第 16 章加粗，第 17 章在 2026-11-29 发布后改为 wikilink
- [x] 章尾 `系列导航：[[ch15-observability-testing-stability|上一章]] · [[zig-esp32-s31|系列索引]]`
- [x] `## 16.x` 编号小节 13 个（16.1–16.13），含 `## 事实来源` 与 `## 自查清单`
- [x] 主机侧 `zig build test` 全绿（55 个测试，54 个具名用例）
- [x] 板侧 `zig build -Dtarget=riscv32-freestanding-eabihf ... -Doptimize=ReleaseSmall` 退出 0
- [x] `elf2image` 打印 `Merged 2 ELF sections.`，`image-info` 正好两个 `DROM, IROM` 段
- [x] `bash -n tools/flash.sh` 退出 0
- [x] 每个结论都写明证据层级：主机测试 / 镜像检查 / 待真机验证
- [x] 板侧自检 6 条已实测（`../logs/ch16-boot.log`），未上板的项仍标「待真机验证」
- [x] pbuf/校验和/首部/时间轮的每条不变式都有对应测试用例
- [x] 校验和向量（`0x220d`、`0x9b2a`、`0x9c5e`、`0xeca5`、增量 `0x9c2a`）与测试一致
- [x] 零拷贝路径图与拷贝点清单（C1–C4）与代码一一对应
- [x] 未引入外部依赖，工程无 `build.zig.zon`
- [x] README 有反向 wikilink、实测状态说明、`zig build test` 命令

一句话总结：协议栈的第一性问题不是「报文格式」，而是「这段字节归谁」——把 pbuf 的所有权、`eat` 的零拷贝、`linearize_copies` 的计数、时间轮的到期判定都变成可断言的不变式之后，网络代码才第一次变得可测；本章的 55 个主机侧用例与两条拷贝点断言，就是后面 MAC、IPv4、TCP 各章的地基。

系列导航：[[ch15-observability-testing-stability|上一章]] · [[zig-esp32-s31|系列索引]]
