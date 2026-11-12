---
title: "Zig × ESP32-S31 全栈开发（十九）：UDP、DHCP 与 DNS"
date: 2026-11-30 18:00:00
description: "从「能 ping」到「能问路」：UDP 的 8 字节首部与三个陷阱、伪首部校验和的复核判据、端口分派的三种结局、DHCP 的 236+4+TLV 三段式与六个状态、租期/T1/T2/重传退避四个计时器、NAK 与迟到包的处置、DNS 报文的头部与压缩指针、把终止性变成不变量的解压器、TTL 缓存的淘汰策略，以及「从路由器拿到 IP」的完整验收路径。"
tags: [zig, esp32-s31, riscv, udp, dhcp, dns, series]
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
> 19. **第十九章：UDP、DHCP 与 DNS**
> 20. [[ch20-tcp-state-machine-reliable-delivery|第二十章：TCP 状态机与可靠传输]]
> 21. [[ch21-tcp-congestion-throughput|第二十一章：TCP 拥塞控制与吞吐]]
> 22. [[ch22-socket-api-event-loop|第二十二章：Socket API 与事件循环]]

# Zig × ESP32-S31 全栈开发（十九）：UDP、DHCP 与 DNS

第十八章结束时，板子已经能 `ping` 通一个地址——但那个地址是**手动配的**。
一台真的设备不会有人给它填 `ip / mask / gateway / dns` 这四件事；它得自己
在广播域里喊一句“有人能给我一个地址吗”，然后听答案。

这一章就是那一声喊。它由三个协议组成，难度递增：

| 协议 | 报文复杂度  | 真正的难点                                 |
| ---- | ----------- | ------------------------------------------ |
| UDP  | 8 字节首部  | 校验和的两个特殊值（0 与 0xFFFF 语义相反） |
| DHCP | 240 + TLV   | 状态机与计时器：丢包、续租、拒绝、租期到期 |
| DNS  | 头部 + 变长 | 压缩指针：一个能让你死循环的 14 位偏移     |

> [!warning] 本章的证据边界
> 静态部分全部验证过（2026-11-13，宿主 x86_64 / Zig 0.17.1）：
>
> - `zig build test` → `All 49 tests passed`（48 个具名用例 + 根文件容器 test）；
> - `zig build -Dtarget=riscv32-freestanding-eabihf …` 退出 0；
> - `esptool elf2image` 打印 `Merged 2 ELF sections.`，`image-info` 里落在
>   flash 的 `DROM, IROM` 行正好两条（`0x40000020` / `0x40020020`）；
> - `bash -n tools/flash.sh` 退出 0。
>
> **已上板（2026-11-13）**：板侧 14 条判据全部 PASS（`checks: passed=14 failed=0 total=14`），
> 原始输出见 `../logs/ch19-boot.log`。**「从路由器拿到 IP」仍需 ch17 + ch18 + 本章
> 三件套联调**（ch17 DMA 未通），联调结果不在本章交付范围内——把联调结论写成
> 本章的结论，是这类章节最常见的过度承诺。

---

## 19.1 本章在 Part IV 里的位置：从“能 ping”到“能问路”

路线图（`content/zig-esp32-s31/index.md` 的 Part IV 表格）把第 19 章定义为
“UDP、DHCP 与 DNS”，验收产物是“从路由器拿到 IP；域名解析成功”。把它拆开，
其实是这样一条依赖链：

```text
ch17  以太网帧进出          →  ch18  IPv4 首部能被解析、ARP 能问到网关 MAC
                                      ↓
                             ch19  UDP 数据报 → DHCP 客户端（67/68）
                                             → DNS 解析器（53）
                                      ↓
                             ch20  TCP（同一条 IP 路径上的下一种传输层）
```

本章**只依赖 ch18 的一个接口**：把 `(src_ip, dst_ip, protocol, payload)` 交下来，
把 `(dst_ip, protocol, payload)` 交上去。它不需要知道 IPv4 首部怎么排、ARP 缓存
多大、MTU 是 1500 还是 9000——这些全部属于 ch18。

反过来，本章给后面的章节提供了两样“名字”：

- **端口**：ch20 的 TCP、ch22 的 socket API 会复用同一张“端口 → 处理者”的表；
- **域名**：ch23 的 HTTPS 需要一个能把 `example.com` 变成地址的解析器。

所以本章的工程刻意做成**零 MMIO、零中断、零定时器**：所有时间都由状态机的
`now` 参数驱动。这样同一份代码既能被主机测试逐秒推演，也能在板上被真实的
1 Hz tick 驱动，切换成本是零。

---

## 19.2 UDP：一个 8 字节首部里的三个陷阱

UDP 首部长这样（RFC 768）：

```text
 0      7 8     15 16    23 24    31
+--------+--------+--------+--------+
|     Source Port |  Destination Port|
+--------+--------+--------+--------+
|    Length       |   Checksum       |
+--------+--------+--------+--------+
|          data octets ...           |
+------------------------------------+
```

四个字段，三个坑。

**坑一：`Length` 是“UDP 首部 + 载荷”，不是 IP 载荷长度，也不是缓冲区长度。**
这三个数在网络里经常同时对不上：以太网帧可能带 4 字节 FCS（ch17 的 `APCS=0`），
IPv4 可能因为填充比 UDP 长，接收缓冲区可能比报文大。任何一处对了、另一处错了，
解析出来的载荷就是错位的。工程里的 `Header.payload()` 只认 `length`：

```zig
pub fn payload(self: Header, dgram: []const u8) Error![]const u8 {
    if (self.length < len) return error.BadLength;
    if (dgram.len < self.length) return error.Truncated;
    return dgram[len..self.length];
}
```

**坑二：`Checksum = 0` 表示“发送方没算”，不是“算出来是 0”。**
接收方遇到 0 必须放行（`Verdict.absent`），而不是判错。工程里把它做成三态：

```zig
pub const Verdict = enum { absent, ok, bad };
```

把“没算”和“算错”分成两个值，统计才有意义：`absent` 是配置问题，`bad` 是
线路/对端问题。混成一个 `false`，抓包时你永远不知道该怀疑谁。

**坑三：算出的结果恰好是 0 时，必须发 `0xFFFF`。**
因为 0 已经被“没算”占用了。这条规则藏在 RFC 768 的一句话里，却是“偶发丢包”
的经典原因——只有校验和正好落在 0 的那千分之一个报文会消失。工程把它单独
做成 `finalize()`，就是为了让这条规则**能被一条断言钉住**：

```zig
pub fn finalize(raw: u16) u16 {
    return if (raw == 0) 0xFFFF else raw;
}
```

> [!note] 与 ch16 的关系
> ch16 的 `checksum.zig` 已经有一份 RFC 1071 求和。本章工程要求**独立可编**，
> 所以这里只保留 UDP 需要的部分（跨片求和 + 伪首部 + 0/0xFFFF 规则）。两份
> 实现在“分片边界不等于 16 位字边界”这一点上口径必须一致——都由同一类用例
> 钉死：奇数字节载荷分三段求和，结果必须等于连续缓冲求和。

---

## 19.3 伪首部：为什么校验和要“假装”看到 IP 头

UDP 校验和覆盖的不是“UDP 数据报”，而是：

```text
+--------+--------+--------+--------+--------+
|           Source Address (4B)             |
+--------+--------+--------+--------+--------+
|         Destination Address (4B)          |
+--------+--------+--------+--------+--------+
|  zero  | proto  |       UDP length        |
+--------+--------+--------+--------+--------+
|            UDP header + payload           |
+-------------------------------------------+
```

这张“伪首部”**不会出现在线上**，它只是计算时借用的输入。RFC 768 引入它的
目的很直接：让传输层校验和也覆盖“这两个地址 + 这个协议”，从而能抓住一类
IP 层不会报错的错误——报文被投递到了错误的地址。

对实现来说，这带来一个接口后果：**UDP 校验和函数必须知道 IP 地址**。所以
本章的签名是：

```zig
pub fn seal(src: [4]u8, dst: [4]u8, dgram: []u8) Error!void;
pub fn check(src: [4]u8, dst: [4]u8, dgram: []const u8) Verdict;
```

这两个地址由 ch18 传入。UDP 模块自己不解析 IP 首部——那是上一章的事。这也
说明一件事：**“零拷贝”不代表“零知识”**。即使一个字节都不复制，校验和仍然
要求上层把两个地址递下来。

伪首部里的 `zero + proto` 在 16 位字里是 `0x0011`（17 = UDP）。这个字写错
（比如写成 `0x1100`），所有校验和都会“看起来算对了”但全错——因为发送方和
接收方用的是同一个错误公式。这也是 **19.4** 那条判据存在的原因。

---

## 19.4 复核判据：`verified=ok` 而不是“数字看起来对”

发送方算完校验和，把它写进第 6..8 字节。接收方有两种复核方式：

| 方式           | 做法                                                      | 代价         |
| -------------- | --------------------------------------------------------- | ------------ |
| 清零重算再比较 | 把字段改成 0，算一遍，和原值比                            | 需要可写缓冲 |
| **整包再求和** | 不清零，直接对“伪首部 + 整个数据报”求和，结果必须折叠为 0 | 只读，零拷贝 |

第二种是标准做法，也正好是本章板侧自检打印的判据：

```zig
var s = pseudo(src, dst, h.length);
s.add(dgram[0..h.length]);
return if (s.finish() == 0) .ok else .bad;
```

为什么它比“等于某个数字”可靠？因为它同时覆盖了三件事：

1. 伪首部里的两个地址、协议号、长度（任何一项错，和都不会是 0）；
2. UDP 首部的四个字段（包括校验和字段本身）；
3. 全部载荷。

而“等于 `0x5a60`”这种判据只覆盖“我这一次算出来的和上次一样”，对字段错位
完全不敏感。README 里那些 `cksum=0x????` 的占位符就是为了防止有人把主机
测试里的中间值抄成“实测值”。

---

## 19.5 端口复用：一张静态表与三种结局

真实协议栈的端口表是哈希表 + socket 队列（ch22）。本章只需要证明**分派这一步
是可判读的**，所以用一张 12 项的静态表：

```zig
pub const Demux = struct {
    pub const max_ports = 12;
    const Entry = struct { port: u16 = 0, handler: Handler = .echo, used: bool = false };
    entries: [max_ports]Entry = @splat(.{}),
    …
};
```

分派只有三种结局，而且**必须显式区分**：

| 结局                 | 含义                       | 上层应该做什么                   |
| -------------------- | -------------------------- | -------------------------------- |
| `delivered: Handler` | 有人监听这个目的端口       | 交给对应处理者                   |
| `unbound: u16`       | 没人监听（如 67 未开服务） | ICMP port unreachable 的来源     |
| `malformed`          | 首部/长度自相矛盾          | 计入“坏包”统计，不要误报“没服务” |

把后两者混成一个 `dropped` 计数器，是抓包时最常见的自欺：你看到“丢包 100”，
却不知道是对端发错了，还是自己根本没开那个端口。

`bind` 还有两条硬规矩：端口 0 非法（`error.InvalidPort`），重复绑定报
`error.PortInUse` 而不是静默覆盖。后者会在“DHCP 客户端与 DNS 客户端共用
同一个缓冲”这类场景里救你一命。

---

## 19.6 DHCP 报文：236 + 4 + TLV 的三段式

DHCP（RFC 2131）的报文格式继承自 BOOTP，长度变化全在最后一段：

```text
0 .. 236    固定区：op/htype/hlen/hops/xid/secs/flags/
            ciaddr/yiaddr/siaddr/giaddr/chaddr[16]/sname[64]/file[128]
236 .. 240  魔数 0x63825363
240 .. end  TLV 选项（PAD=0、END=255 例外）
```

固定区的字段里，客户端真正关心四个：

| 字段     | 谁填           | 含义                                        |
| -------- | -------------- | ------------------------------------------- |
| `xid`    | 客户端随机生成 | 事务 ID：把“这包是不是回给我的”变成可判定   |
| `flags`  | 客户端         | bit15 = BROADCAST（还没地址时要求广播回包） |
| `yiaddr` | 服务器         | “你的地址”（your IP address）               |
| `chaddr` | 客户端         | 硬件地址，服务器用来区分同一广播域里的设备  |

工程里 `Flags` 是一个 `packed struct(u16)`。Zig 的位域从 bit0 起算，而 RFC 的
图画从 bit15 起，所以顺序要反过来写：

```zig
pub const Flags = packed struct(u16) {
    reserved: u15 = 0,
    broadcast: bool = false,   // 这才是 bit15
};
```

魔数是三段式的锚点。lwIP 把它定义在 `lwip/prot/dhcp.h:129`（`DHCP_MAGIC_COOKIE
0x63825363UL`），本工程用 `parseFixed()` 的第一件事校验它：

```zig
if (std.mem.readInt(u32, buf[fixed_len..options_off], .big) != magic_cookie)
    return error.BadCookie;
```

它不是“格式装饰”：没有它，同一段字节可能被解释成 BOOTP 老报文，选项区
就会被当成 `sname/file` 的一部分——解析结果不会报错，只会全错。

---

## 19.7 选项解析：TLV 的边界检查与“必须有 END”

选项区只有三种形态：

```text
PAD      : 0x00                    （一个字节，跳过）
END      : 0xFF                    （一个字节，结束）
普通选项 : code(1) + len(1) + value(len)
```

解析器要防三件事：

1. **len 越界**：`i + len > packet.len` 时必须报错，不能“读到哪算哪”；
2. **缺 END**：RFC 2131 要求最后一个选项是 255。缺了它多半说明报文被截断，
   本工程返回 `error.Truncated`，而不是默默接受；
3. **已知选项的长度不对**：`option 53` 必须 1 字节、`option 51` 必须 4 字节、
   IP 类选项必须 4 的倍数。长度不对时 lwIP 会跳过，本工程选择报错——因为
   这些字段一旦错，租期和网关就都是猜的。

`option 55`（Parameter Request List）是客户端唯一“主动表达偏好”的地方。
本工程请求六项，顺序就是优先级：

```zig
pub const default_param_list = [_]u8{
    Option.subnet_mask, Option.router, Option.dns,
    Option.lease_time, Option.t1, Option.t2,
};
```

服务器**没有义务**按你的顺序回答，甚至可以一项都不给（比如只给租期）。
所以客户端的每个字段都必须有兜底：

| 缺失的选项 | 兜底                                    | 出处                    |
| ---------- | --------------------------------------- | ----------------------- |
| 子网掩码   | 按 classful 猜（/8、/16、/24）          | lwIP `dhcp_bind()` 同款 |
| 路由器     | 用服务器地址                            | 同网段假设              |
| DNS        | 用服务器地址                            | 同网段假设              |
| T1         | `lease / 2`                             | RFC 2131 §4.4.5         |
| T2         | `lease - lease / 8`（即 0.875 × lease） | RFC 2131 §4.4.5         |

注意 `lease / 2` 与 `lease - lease / 8` 都是**整数秒**运算：`lease=3600` 时是
1800 / 3150，`lease=6` 时是 3 / 6。后者的 T1 与 T2 已经贴在一起了，这正是
19.9 要处理的边界。

---

## 19.8 状态机：四个报文、六个状态

正常路径只有四个报文：

```text
客户端                                    服务器
   |  DISCOVER (广播, xid=X)  ------------>  |
   |  <--------------  OFFER (yiaddr=A)      |
   |  REQUEST  (广播, 请求 A, server-id=S) -> |
   |  <-------------------  ACK (lease=L)    |
```

四个报文对应六个状态：

| 状态         | 在等什么         | 收到什么会迁移                                   |
| ------------ | ---------------- | ------------------------------------------------ |
| `init`       | 没有地址         | `poll()` 发 DISCOVER → `selecting`               |
| `selecting`  | OFFER            | OFFER → `requesting`；超时重发 DISCOVER          |
| `requesting` | ACK / NAK        | ACK → `bound`；NAK → `init`；超时重发 REQUEST    |
| `bound`      | T1               | T1 → `renewing`；T2 → `rebinding`                |
| `renewing`   | 续租的 ACK       | ACK → `bound`；T2 → `rebinding`；租期到 → `init` |
| `rebinding`  | 任意服务器的 ACK | ACK → `bound`；租期到 → `init`                   |

工程把“下一步做什么”做成一个**无载荷的枚举**：

```zig
pub const Action = enum {
    idle, send_discover, send_request, send_renew, send_rebind, lease_expired,
};
```

这样做的好处是状态机**不持有缓冲区**：它不组包、不发包，只回答“该发什么”。
组包与发送分别属于 `Builder` 和 ch18 的 IP 路径，三者可以独立测试。

`poll(now)` 的调用频率建议 1 Hz，但所有判断都基于 `now` 的绝对值，因此
调用快一点慢一点只影响精度、不影响正确性：

```zig
.renewing => {
    if (now >= self.t2_at) { … return .send_rebind; }
    if (now >= self.retry_at) { … return .send_renew; }
},
```

顺序很重要：**先查 T2 再查重试**。否则一个迟迟得不到回应的续租请求会一直
重发，永远不会升级成广播重绑定——而广播重绑定正是“服务器换了/挂了”时唯一
的出路。

---

## 19.9 四个计时器：租期、T1、T2 与重传退避

DHCP 客户端有四个时间量，它们的关系是：

```text
绑定时刻                          T1                T2          租期到
   |------------------------------|-----------------|-------------|
   |        正常使用               |   单播续租       |  广播重绑定  | 回到 INIT
   |<----------- lease ----------->|
   |<----- t1 = lease/2 ---------->|
   |<---------- t2 = 7/8 lease ------------------>|
```

| 计时器   | 默认值                  | 到期动作                                |
| -------- | ----------------------- | --------------------------------------- |
| 租期     | ACK 的 option 51        | 释放地址、回 `init`（`lease_expired`）  |
| T1       | 租期 / 2                | 单播 REQUEST 给原服务器（`send_renew`） |
| T2       | 租期 × 7/8              | 广播 REQUEST（`send_rebind`）           |
| 重传退避 | 4 → 8 → 16 → 32 → 64 秒 | 重发上一次的报文                        |

退避的算法是 RFC 2131 §4.1 的“4 秒起步、随机化、指数翻倍”。工程把它做成
纯函数，好让用例逐项断言：

```zig
pub fn backoffDelay(attempt: u8, jitter: bool) u32 {
    const base: u32 = if (attempt >= 4) 64 else @as(u32, 4) << @intCast(attempt);
    return base + @intFromBool(jitter);
}
```

`jitter` 只加 0/1 秒，并且由 `xid` 的某一位决定——这样“同一台设备同一轮
协商”的行为完全可复现，而不同设备之间又不会同步重试（这是随机化的本意）。

lwIP 的实现值得对照：它把 T1/T2 换算成 **60 秒**的粗定时器 tick 数
（`lwip/dhcp.h:64-65` 的 `DHCP_COARSE_TIMER_SECS`），因此在 `dhcp.c:1196-1199`
里有一句很实在的补丁——“租期小于 1 分钟时 T1 与 T2 会同时触发，索性把 T1
置 0”。这个 0 的语义是**关掉 T1 定时器**，整条链是这样的：

```text
dhcp_bind():  t1_timeout = T1;  t1_renew_time = t1_timeout;   // dhcp.c:1184-1186
dhcp_bind():  t1_timeout >= t2_timeout 时  t1_timeout = 0;    // dhcp.c:1196-1199
粗定时器:     else if (dhcp->t1_renew_time && (dhcp->t1_renew_time-- == 1))
                                                            // dhcp.c:555
              → 倒计时字段为 0，`&&` 直接短路，T1 分支永不进入
```

所以 lwIP 在“租期太短”时剩下的唯一驱动是 T2（`dhcp.c:550` 的
`t2_rebind_time` 倒计时），与 T1 无关。本章同款，只是判据写成秒：

本章用秒，不需要粗 tick 的量化误差，但保留了同一条约束：

```zig
if (self.t2_secs > 0 and self.t1_secs >= self.t2_secs) self.t1_secs = 0;
```

并且 `poll()` 必须把 0 当成“定时器关闭”，而不是“到点了”：

```zig
if (self.t1_secs != 0 and now >= self.t1_at) { … return .send_renew; }
```

漏掉 `t1_secs != 0` 这个守卫，`t1_at` 恰好等于绑定时刻，`now >= t1_at` 立刻
成立——于是绑定成功后马上发出一次单播续租，语义与“关闭 T1”正相反。这是本
章唯一一处**协议语义写反就会静默出错**的地方，所以专门有一条用例钉住它：
服务器给 `T1=90、T2=80` 时，`poll(0)` 与 `poll(79)` 都必须返回 `idle`，
`poll(80)` 才 `send_rebind`。

---

## 19.10 NAK、迟到包与“为什么 xid 是唯一的防伪”

两条分支决定“会不会掉线”：

**NAK：必须清空 offer。**
NAK 的语义是“你请求的地址不能给你”（RFC 2131 §4.3.2）。如果此时还保留着
上一次 OFFER 的 `offered_ip`，下一次 REQUEST 会继续请求同一个被拒绝的地址，
表现就是**无限 NAK 循环**。工程的处置是一条直线：

```zig
.nak => {
    self.expire();          // 清空 offer / server_id / 租期 / 计时器
    return .idle;           // 下一次 poll() 会重新发 DISCOVER（并换 xid）
},
```

**迟到包：只认 xid。**
广播域里同时可能有十几台设备在协商；上一轮的超时 OFFER 也可能在 3 秒后才到。
这些包对当前事务全部无效。把 `xid` 比对放在**改状态之前**，一条断言就能钉住：

```zig
if (msg.xid != self.xid) return error.WrongXid;
```

用例里把 `xid +% 1` 的回包喂进去，断言状态仍然是 `selecting`、`offered_ip`
仍然是 0。这类测试的价值在于：它验证的是“拒绝”这条路径，而不是“接受”。

还有一个容易忽略的点：`xid` 必须**每轮更新**。工程用递增序号乘一个奇数常量
再异或固定前缀，保证可复现且不重复：

```zig
fn nextXid(self: *Client) u32 {
    self.xid_seq +%= 1;
    return 0x3D00_0000 ^ (self.xid_seq *% 0x9E37_79B9);
}
```

---

## 19.11 DNS 报文：header、question 与资源记录

DNS 报文（RFC 1035 §4）由 12 字节头和四个可变区组成：

```text
+---------------------+
| Header (12B)        |  id, flags, qdcount, ancount, nscount, arcount
+---------------------+
| Question   × qdcount|  name, qtype(2), qclass(2)
+---------------------+
| Answer     × ancount|  name, type, class, ttl(4), rdlength(2), rdata
+---------------------+
| Authority / Additional
```

标志字的位序是另一个“文档和图相反”的地方：

```text
bit:  15 14..11 10  9   8   7   6..4 3..0
      QR opcode AA  TC  RD  RA  Z    RCODE
```

Zig 的 `packed struct(u16)` 从 bit0 起算，所以字段声明要倒着写：

```zig
pub const Flags = packed struct(u16) {
    rcode: u4 = 0,
    z: u3 = 0,
    ra: bool = false,
    rd: bool = false,
    tc: bool = false,
    aa: bool = false,
    opcode: u4 = 0,
    qr: bool = false,
};
```

用例里直接用数值钉死：`QR=1 AA=1 RD=1 RA=1 RCODE=3` 必须编码成 `0x8583`。
如果位序写反，这条断言会立刻失败——比“抓包看一眼”快得多。

名字的线上格式是**长度前缀标签 + 终止符**：

```text
example.com  →  07 'e' 'x' 'a' 'm' 'p' 'l' 'e'  03 'c' 'o' 'm'  00
```

两条硬上限来自 §2.3.4：单个标签 ≤ 63 字节（高两位被指针占用）、整个名字
≤ 255 字节（含终止符）。工程把两条都做成错误：

| 输入                     | 结果                 |
| ------------------------ | -------------------- |
| 64 字节的标签            | `error.LabelTooLong` |
| 4 个 63 字节标签（257）  | `error.NameTooLong`  |
| `example..com`           | `error.EmptyLabel`   |
| `example.com.`（末尾点） | 合法（绝对域名）     |

---

## 19.12 压缩指针：把终止性变成不变量

压缩指针是两字节：高两位 `11`，剩下 14 位是偏移。

```text
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
| 1  1|             offset (14 bit)              |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
```

它带来两个必须解决的问题：

**问题一：语义。** 名字可能以指针结尾；此时“名字在本层的下一字节”是
**指针之后**，不是被指向的名字之后。搞错这一点，后面所有资源记录都会错位。

**问题二：终止性。** 指针可以指向任何地方，包括自己、包括另一个指回来的
指针。天真的“跟随指针直到 0”实现会死循环。

本工程的解法是**一条结构不变量**：

```zig
// 必须严格向前指：任何跳转都让偏移变小，环路不可能成立。
if (ptr >= pos) return error.BadPointer;
```

任何一次跳转都让 `pos` 严格减小，而 `pos` 是非负整数——所以最多跳 `pos` 次
必然到达 0，不可能成环。`jumps >= 32` 的计数只是二道防线，不是主要机制。

为什么值得这样设计？因为“跳 32 次就放弃”这类经验值，一旦遇到合法的长指针链
（比如某个服务器把 `a.b.c.d.e.f…` 压缩成一串）就会误伤；而“只能向前”既是
RFC 隐含的意图（指针指向“先前的出现”），也永远不会有误伤。

对照组：lwIP 在 `dns.c:758-805` 的 `dns_compare_name()` 里遇到压缩名字直接
返回不匹配（因为它自己从不用压缩），在 `dns.c:815-855` 的 `dns_skip_name()`
里遇到指针就停下。两个函数都**不跟随指针**，因为 lwIP 只需要跳过名字，不需要
还原它。本章要还原（缓存需要点分名字），所以必须真的走一遍指针——也就必须
自己解决终止性。

---

## 19.13 DNS 缓存：TTL、大小写与淘汰策略

缓存的目标不是“记住更多”，而是“记住还有效的”。三条规则：

**规则一：TTL 是权威，且要钳制。**
RFC 1035 把 TTL 定义成 32 位；RFC 2181 §8 规定最高位必须当 0 处理——也就是
“不要缓存”。所以 `put()` 的第一步是**归一化**，而不是直接钳制：

```zig
const eff = if (ttl & 0x8000_0000 != 0) 0 else ttl;   // §8：最高位置 1 → 0
```

归一化之后才用 `max_ttl` 钳制（默认 604800 = 7 天，与 lwIP 的 `DNS_MAX_TTL`、
`dns.c:133-135` 同口径；lwIP 在 `dns.c:1434-1436` 里也是这么钳的）。顺序不能
反：先 `@min(ttl, max_ttl)` 会把 `0x80000000` 变成 604800，缓存 7 天——与
RFC 2181 §8 恰好相反。用例 `TTL 最高位置 1` 把这条钉死。

**规则二：名字比较不区分大小写。**
RFC 1035 §2.3.3：DNS 名字比较是大小写无关的。服务器回显时保留你发的大小写，
但 `Example.COM` 和 `example.com` 是同一个键。工程在写入时统一转小写：

```zig
for (name, 0..) |c, i| e.name[i] = std.ascii.toLower(c);
```

**规则三：淘汰“最早到期”，不是“最久未用”。**
DNS 缓存的价值与**剩余 TTL** 成正比：一条还剩 1 秒的记录，命中一次也只能用
1 秒；淘汰它损失最小。LRU 反而会把“刚刚命中、但马上过期”的条目留下，把
“还有 6 天”的条目挤走。

| 策略         | 淘汰谁            | 在这里的问题                  |
| ------------ | ----------------- | ----------------------------- |
| LRU          | 最久未使用的      | 刚命中的短 TTL 记录会占着位置 |
| FIFO         | 最早写入的        | 与 TTL 无关，可能先扔长命记录 |
| **最早到期** | `expires_at` 最小 | 与“知识还剩多少价值”直接对齐  |

另外两条边界：**TTL=0 表示不要缓存**（RFC 1035 §3.2.1），工程直接删掉同名旧
条目而不是存一条立刻过期的；**同名覆盖只占一个槽**，否则反复查询同一个域名
会把 8 个槽全部占满。

---

## 19.14 从路由器拿到 IP 的验收路径

把三章拼起来，真机上应该按这个顺序看串口（每一步都是“上一步通过才做下一步”）：

| 顺序 | 判据                                             | 失败时先怀疑                       |
| ---- | ------------------------------------------------ | ---------------------------------- |
| 1    | ch17：`mdio:` 读到 PHY ID，`link=1`              | 网线、PHY 供电、MDC/MDIO 引脚      |
| 2    | ch17：`rx:` 至少收到一帧（ARP/LLDP/广播）        | RXC 时钟、`MACFF.DBF`、过滤位      |
| 3    | ch18：`arp:` 解析到网关 MAC（或 `arp.reply`）    | ARP 缓存、广播帧是否被丢           |
| 4    | ch18：`ping` 网关通                              | IPv4 校验和、ICMP 回显路径         |
| 5    | 本章：`udp demux dport=67 delivered=dhcp_server` | 端口表、UDP 校验和                 |
| 6    | 本章：`dhcp state=selecting` → `offer` → `bound` | xid、`chaddr`、广播标志（bit15）   |
| 7    | 本章：`ip/mask/gw/dns` 四项与路由器后台一致      | 选项解析、兜底顺序                 |
| 8    | 本章：`dhcp t1=… renew state=renewing`           | 计时器基准（`now` 的单位是不是秒） |
| 9    | 本章：`dns a=… ttl=…`                            | 53 端口、响应 ID、压缩指针         |
| 10   | 本章：第二次查询 `dns cache hit=1`               | 缓存键大小写、TTL 写入             |

这张表的价值在于**把“能上网”拆成十个可判读的中间态**。任何一步失败，你都
知道该看哪个模块，而不是“DHCP 不行，重烧一次”。

本章工程的板侧自检覆盖了第 5–10 步的**纯逻辑部分**（用自造报文），但第 1–4 步
需要 ch17/ch18 的驱动与真实链路。所以本章的验收口径必须写成两句话：

- **本章自己**：`zig build test` 49 项全绿 + 镜像两段合法 + 板侧自检 14 条判据
  打印 `passed=14 failed=0`（2026-11-13 已实测，见 `../logs/ch19-boot.log`）；
- **联调**：ch17+ch18+ch19 一起，路由器后台能看到这台设备的租约，且板子能
  `ping` 网关、能解析一个域名。这条结论只能由联调给出，本章不代填。

---

## 19.15 与 ch16/ch17/ch18 的接口边界

三章都想“独立可编”，所以边界必须只有函数签名级：

| 边界              | 提供方 | 形状                                                                  | 本章怎么用                           |
| ----------------- | ------ | --------------------------------------------------------------------- | ------------------------------------ |
| 缓冲区与零拷贝    | ch16   | `pbuf` 链、`netif.send`                                               | 只作口径参考；本章用连续切片         |
| 链路层收发        | ch17   | `(buffer, len)` 的帧，`APCS=0`（含 4 字节 FCS）                       | 本章不碰帧头；IP 载荷由 ch18 剥出    |
| IPv4 / ARP / ICMP | ch18   | `inet.Addr = [4]u8`、`ipv4.proto.udp = 17`、`src/dst`、`payload` 切片 | `udp.seal(src,dst,dgram)` 的两个地址 |
| UDP / DHCP / DNS  | ch19   | `Verdict`、`Action`、`Answer`、`Cache`                                | 给 ch20/ch22 提供端口与名字          |

三个“不要”：

1. **不要让 UDP 模块解析 IP 首部**。它只需要两个地址；一旦它开始读 `ihl`，
   ch18 与 ch19 就纠缠在一起，主机测试也必须造 IP 头。
2. **不要让 DHCP 状态机持有报文缓冲**。`poll()` 只回答“发什么”，组包是
   `Builder` 的事。这样状态机可以在没有缓冲的主机测试里逐秒推演。
3. **不要让 DNS 缓存依赖分配器**。定容 8 条，满了就淘汰；板侧没有堆，
   也不该为一个地址缓存引入 `OutOfMemory` 路径。

再补一条“要”：**`now` 的单位必须在整个栈里统一**。本章用秒；ch15 的 tick
以毫秒计，ch20 的 RTO 也按毫秒（RFC 6298 的初始值 1 秒 = 1000 ms）。把两者
混在一起，表现为“租期一天，实际一分钟就过期”。
工程里所有计时字段都以 `_at` 结尾（`t1_at`、`t2_at`、`lease_at`），单位写在
注释第一行，就是为了让这种错误在 review 时一眼可见。

---

## 19.16 工程结构与判读顺序

工程是形态 B（Zig 产 ELF + IDF 只提供二级 bootloader/分区表），文件职责表在
`practice/zig-esp32-s31/ch19-udp-dhcp-dns/README.md`。这里只强调三件事。

站内代码浏览（不离开站点看高亮源码）：

| 文件                 | 代码浏览                                                                  |
| -------------------- | ------------------------------------------------------------------------- |
| `build.zig`          | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/build.zig)          |
| `linker/s31.ld`      | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/linker/s31.ld)      |
| `src/udp.zig`        | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/udp.zig)        |
| `src/dhcp.zig`       | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/dhcp.zig)       |
| `src/dns.zig`        | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/dns.zig)        |
| `src/selftest.zig`   | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/selftest.zig)   |
| `src/host_tests.zig` | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/host_tests.zig) |
| `src/main.zig`       | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/main.zig)       |
| `src/start.zig`      | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/start.zig)      |
| `src/hw.zig`         | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/hw.zig)         |
| `src/trap.zig`       | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/trap.zig)       |
| `src/log.zig`        | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/log.zig)        |
| `tools/flash.sh`     | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/tools/flash.sh)     |

深链由 `npm run code-site` 生成（`scripts/gen-code-site.mjs` 的
`PROJECT_GLOBS` 已覆盖 `practice/zig-esp32-s31/*`），浏览页收录本章工程的全部源文件。

**第一，主机测试是权威。** 48 个具名用例的分布是 13（UDP）+ 17（DHCP）+ 18（DNS），
再加根文件容器 test 共 49：

| 模块       | 用例数 | 钉住的东西                                                     |
| ---------- | -----: | -------------------------------------------------------------- |
| `udp.zig`  |     13 | 首部字节序、长度三态、0/0xFFFF、跨片求和、端口表与三种结局     |
| `dhcp.zig` |     17 | 固定区布局、魔数、TLV、状态迁移、T1/T2、NAK、退避、迟到包      |
| `dns.zig`  |     18 | 标志位序、标签/名字上限、指针向前、CNAME 跳过、rcode、缓存淘汰 |

**第二，板侧只保留一条闭环。** `selftest.zig` 在 rv32 上把两条流程各走一遍：
DHCP（DISCOVER→UDP→分派→OFFER→ACK→T1 续租）与 DNS（查询→压缩响应→缓存→过期），
共 14 条判据。它不打中断、不发包，所以输出可以静态推理复现。

**第三，串口前缀就是判读顺序。**

| 顺序 | 前缀            | 判据                                          |
| ---- | --------------- | --------------------------------------------- |
| 1    | `dhcp discover` | 长度 > 241，最后字节 `END(255)`               |
| 2    | `dhcp cookie`   | `0x63825363`                                  |
| 3    | `udp sport=68`  | `verified=ok`（伪首部 + 整包折叠为 0）        |
| 4    | `udp demux`     | `delivered=dhcp_server ports=2`               |
| 5    | `dhcp bound`    | `lease=3600 t1=1800 t2=3150`（与 ACK 对得上） |
| 6    | `dhcp t1=`      | `renew state=renewing`                        |
| 7    | `dns query`     | `len=29 qd=1 rd=1`                            |
| 8    | `dns a=`        | 地址、TTL、`cname_hops=0`                     |
| 9    | `dns cache`     | `hit=1`，随后 `expired=1 entries=0`           |

---

## 19.17 还不做的事与下一章

本章交付的是“能问到地址、能解析名字”的最小闭环：

- ✅ UDP 首部编解码、伪首部校验和与三态复核
- ✅ 端口复用表（`bind/unbind/lookup/dispatch`）
- ✅ DHCP 报文编解码（含 PAD/END 与长度校验）
- ✅ DHCP 客户端状态机（六个状态、四个计时器、NAK、迟到包）
- ✅ DNS 查询编码、压缩指针解压（带结构性防环）、A 记录解析
- ✅ DNS 缓存（TTL 钳制、大小写无关、最早到期淘汰）
- ❌ **不发真实报文**：没有 MAC/IPv4 路径，板侧自检只解析本机构造的报文
- ❌ **`secs` 恒为 0**：RFC 2131 §4.1 要求客户端在重传时把 `secs` 填成“距离开始
  获取地址已过的秒数”，本章的 `writeFixed()` 一直写 0。这是与 RFC 的唯一一处
  故意偏差（真实抓包里它应当递增），补上只需在 REQUEST/DISCOVER 组包时把
  `msg.secs` 设成 `min(now - start, 0xFFFF)`
- ❌ 不做 DHCP 服务器、不处理 `option 52`（overload）、不做 DHCPv6
- ❌ 不做 DNS 递归解析、不做 EDNS0、不做 AAAA 的地址语义
- ❌ 不做 `ICMP port unreachable` 的生成（那是 ch18 的输出路径）

下一章（ch20）在**同一条 IP 路径**上做 TCP：三次握手、seq/ack、RTO 重传、
乱序重组、FIN/RST。本章的两样东西会被直接复用：

- **端口表**：TCP 需要同一张“目的端口 → 处理者”的表，只是多了一个四元组键；
- **计时器**：ch16 的时间轮 + 本章的“`now` 统一用秒”的口径，会在 RTO 那里
  变成“毫秒”的一次显式换算——这是 ch20 的第一个坑。

---

## 事实来源

本章所有协议字段、常量与对照实现都来自公开 RFC 与本地 ESP-IDF v6.1 的 lwIP
源码，下表逐条给出出处（IDF 路径相对 `~/esp/esp-idf/`）。

| #   | 事实                                                                                                                            | 路径与位置                                                                                                                                                       |
| --- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | UDP 首部 8 字节、`Length` 含首部、校验和 0 表示未计算、算出 0 发 `0xFFFF`                                                       | RFC 768（User Datagram Protocol）                                                                                                                                |
| 2   | UDP 校验和覆盖“伪首部 + 首部 + 载荷”，伪首部为 src/dst/zero/proto/length                                                        | RFC 768；IPv4 伪首部定义见 RFC 791 §3.1                                                                                                                          |
| 3   | DHCP 客户端/服务器端口 68/67                                                                                                    | RFC 2131 §4.1                                                                                                                                                    |
| 4   | DHCP 报文 = 236 字节固定区 + 4 字节魔数 + TLV 选项                                                                              | RFC 2131 §2；魔数 `0x63825363` 见 `components/lwip/lwip/src/include/lwip/prot/dhcp.h:129`                                                                        |
| 5   | 选项号：PAD 0、子网掩码 1、路由器 3、DNS 6、请求地址 50、租期 51、消息类型 53、服务器 ID 54、参数请求 55、T1 58、T2 59、END 255 | `components/lwip/lwip/src/include/lwip/prot/dhcp.h:134-161`（同上文件）                                                                                          |
| 6   | 标志字段 bit15 = BROADCAST                                                                                                      | RFC 2131 §2                                                                                                                                                      |
| 7   | 重传从 4 秒起步、随机化、指数翻倍                                                                                               | RFC 2131 §4.1                                                                                                                                                    |
| 8   | 缺省 T1 = 0.5 × 租期、T2 = 0.875 × 租期                                                                                         | RFC 2131 §4.4.5                                                                                                                                                  |
| 9   | NAK 后回到 INIT、重新 DISCOVER                                                                                                  | RFC 2131 §4.3.2 / §4.4.1                                                                                                                                         |
| 10  | lwIP 的 DHCP 粗定时器为 60 秒，T1/T2 按 tick 数换算                                                                             | `components/lwip/lwip/src/include/lwip/dhcp.h:64-65`、`src/core/ipv4/dhcp.c:131-147`                                                                             |
| 11  | lwIP 在租期 < 1 分钟时把 `t1_timeout` 置 0（= 关闭 T1 定时器）                                                                  | `components/lwip/lwip/src/core/ipv4/dhcp.c:1184-1186`（`t1_renew_time = t1_timeout`）、`1196-1199`（置 0）、`555`（`t1_renew_time && …` 守卫）、`550`（T2 分支） |
| 12  | lwIP 的掩码兜底按 classful 取 /8、/16、/24                                                                                      | `components/lwip/lwip/src/core/ipv4/dhcp.c:1204-1214`（`dhcp_bind()` 的 `offered_sn_mask`）                                                                      |
| 13  | lwIP 退避序列 `tries<6 ? 1<<tries : 60` 秒                                                                                      | `components/lwip/lwip/src/core/ipv4/dhcp.c:146`                                                                                                                  |
| 14  | DNS 报文头 12 字节、问题区/RR 结构、名字 ≤255 字节、标签 ≤63 字节                                                               | RFC 1035 §4 与 §2.3.4                                                                                                                                            |
| 15  | 压缩指针 `11xxxxxx xxxxxxxx`，指向“先前的出现”                                                                                  | RFC 1035 §4.1.4                                                                                                                                                  |
| 16  | DNS 标志位：QR/opcode/AA/TC/RD/RA/Z/RCODE 的顺序                                                                                | RFC 1035 §4.1.1                                                                                                                                                  |
| 17  | DNS 名字比较不区分大小写                                                                                                        | RFC 1035 §2.3.3                                                                                                                                                  |
| 18  | RR 类型号：A 1、CNAME 5、AAAA 28、OPT 41                                                                                        | `components/lwip/lwip/src/include/lwip/prot/dns.h:55-76`                                                                                                         |
| 19  | TTL 最高位必须当 0 处理                                                                                                         | RFC 2181 §8                                                                                                                                                      |
| 20  | lwIP 的 `DNS_MAX_TTL = 604800` 且对响应 TTL 做钳制                                                                              | `components/lwip/lwip/src/core/dns.c:133-135`、`dns.c:1434-1436`                                                                                                 |
| 21  | lwIP 在名字比较/跳过时**不跟随**压缩指针                                                                                        | `components/lwip/lwip/src/core/dns.c:758-805`（`dns_compare_name`）、`815-855`（`dns_skip_name`）                                                                |
| 22  | ch16/17/18 的接口与口径（checksum、帧含 FCS、IPv4 切片）                                                                        | `content/zig-esp32-s31/ch16-stack-architecture-zero-copy.md`、`ch17-ethernet-mac-phy-driver.md`                                                                  |

> [!note] 口径
> 第 10–13、20–21 行是**对照实现**，不是本章的依赖：本章不链接 lwIP，只是在
> “同样的问题别人怎么解”这一点上给出可查的坐标。凡属本章自己的判断（DNS
> 指针只许向前、NAK 清空 offer、缓存淘汰最早到期），都在正文里给了理由与
> 用例，而不是引用权威。

---

## 自查清单

上板前（静态，均已在本机执行过）：

- [x] `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 的段表里 `DROM, IROM` 行数 **正好 2**（`0x40000020`、`0x40020020`）
- [x] `zig build test` 全绿（49 项 = 48 具名 + 容器 test）
- [x] `bash -n tools/flash.sh` 退出 0
- [x] `git status --short` 里属于本章的新增只有上述两个路径（`practice/.../ch18-ipv4-icmp-arp-routing/` 是同伴并行产物，其余为仓库原有未跟踪文件，均不在本章范围内）

上板后（逐条打勾才叫“跑通”）：

- [ ] banner 四行完整（含 `host: 49 unit tests`）
- [x] `check: dhcp discover … last=END(255) ok=1`
- [x] `check: dhcp cookie=0x63825363 ok=1`
- [ ] `check: udp … verified=ok ok=1`
- [x] `check: udp demux dport=67 delivered=dhcp_server ports=2 ok=1`
- [x] `check: dhcp offer yiaddr=192.168.1.42 -> send_request ok=1`
- [x] `check: dhcp bound … lease=3600 t1=1800 t2=3150 ok=1`
- [x] `check: dhcp t1=1802 renew state=renewing ok=1`
- [x] `check: dns query len=29 qd=1 rd=1 labels=2 ok=1`
- [x] `check: dns a=93.184.216.34 ttl=300 cname_hops=0 ok=1`
- [x] `check: dns cache hit=1 … entries=1 ok=1`
- [x] `check: dns cache expired=1 entries=0 ok=1`
- [x] `checks: passed=14 failed=0 total=14`
- [ ] `main: verdict=pass` 之后停在 `wfi`，复位可重复
- [ ] 联调：路由器后台出现租约，板子 `ping` 网关成功
- [ ] 联调：第二次解析同一域名命中缓存（不再发 53 端口的包）

失败时的第一反应（按顺序排查，不要跳步）：

1. `cookie` 不对 → 查 `writeFixed` 的偏移 236 与大端序，**不要**继续解析选项；
2. `verified=bad` → 查伪首部的 `0x0011` 字与两个地址的字节序；
3. `offer` 收不到 → 查 `xid` 是否每轮更新、`chaddr` 是否写了、广播位是否置 1；
4. `bound` 后立刻 `lease_expired` → 查 `now` 的单位（秒）与 `*_at` 的基准；
5. `dns` 解析错位 → 先打印 `decodeName` 的 `next`，再怀疑压缩指针。

---

本章的交付物是“可问路”：每一行串口输出都对应一个字段或一条不变量，
每一个尚未验证的结论都标了「待真机验证」。DHCP 真正的难点不在报文格式，
而在于**在丢包与误解的网络里仍然收敛**；DNS 真正的难点不在名字编码，
而在于**让一个 14 位偏移永远不会把你带进死循环**。下一章站在这两样东西上，
去做那个更难的状态机——TCP。

系列导航：[[ch18-ipv4-icmp-arp-routing|上一章]] · [[zig-esp32-s31|系列索引]]
