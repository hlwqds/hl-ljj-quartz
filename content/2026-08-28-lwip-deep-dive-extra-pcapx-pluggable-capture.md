---
title: "lwIP 深度解析番外：给 lwIP 造一个可插拔抓包模块"
date: 2026-08-28 12:00:00
description: "ch23 的抓包三路各留缺口：IP4 hook 只到 IP 层 RX、宿主 tcpdump 隔着 SLIRP、LWIP_DEBUG 不可回放。本篇把缺口铸成 pcapx 组件——netif 函数指针换装 + 旋锁串行化的 MPSC 环 + 专职 writer + 三 sink（半托管/RAM/UART），零修改 lwIP 与 IDF 源码。QEMU 验收：107 帧 pcap Wireshark 可开（ARP5/UDP52/ICMP50），DROP 恒等式 1003=0+918+85 精确成立，attach/detach churn 100/100 无泄漏；QEMU 半托管双通路、tap 写环 12B 偏移踩堆两个深坑全程留档。"
tags: [lwip, freertos, esp-idf, pcap, debugging, series]
---

> [!info] lwIP 深度解析系列·番外0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]]
> 前置：[[2026-08-26-lwip-deep-dive-ch23-debugging-toolbox|第二十三章：调试工具箱]]
> **番外：给 lwIP 造一个可插拔抓包模块**（当前文）
> 相关：[[2026-08-26-lwip-deep-dive-ch7-netif-abstraction|第七章 netif 抽象]] · [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|第十三章 tcpip 线程]] · [[2026-08-26-lwip-deep-dive-ch19-isr-and-priority-design|第十九章 ISR 与优先级设计]]

# lwIP 深度解析番外：给 lwIP 造一个可插拔抓包模块

本篇回答三个问题：**现有抓包手段的缺口到底是什么形状**（为什么 ch23 盘完三条路还是不够用）、**一个「双向、链路层、可回放、零侵入、运行时可插拔」的抓包模块该怎么造**（接入点选型、RTOS 纪律、pcap 格式、sink 设计）、**怎么证明它是对的**（数字、恒等式与观测点回归）。与 [[2026-08-26-lwip-deep-dive-ch23-debugging-toolbox|第二十三章]] 的分工一句话说清：ch23 回答「现有工具能看见什么」，本篇回答「看不见的部分怎么补」——方法论一脉相承（先规格、后实现、观测点验收），内容零重复，ch23 的 hook/壳/统计手段在本篇只作为被替代的基线出场。

源码与证据参照：ESP-IDF v6.0.2 捆绑 lwIP 2.2.0-dev，组件 `practice/pcapx/`（规格 `docs/spec/pcapx.md`，四条决策记录 KD-8~KD-11 见 `docs/decisions.md`），验收工程 `practice/lwip-pcapx-lab/`（run.log / run-drop.log / run-churn.log 三份真实日志）。全部实验 QEMU 实跑，真机相关项如实标注。

## X.1 为什么自己造：把 ch23 的工具箱盘点到底

结论先行：ch23 的三条抓包路——宿主 `tcpdump -i lo`、`LWIP_HOOK_IP4_INPUT` 注入、`linkoutput` 包装壳——没有一条同时满足「双向、链路层、可回放」。把需求对着现有手段逐一核对：

| 需求       | ch23 最接近的手段     | 缺口               |
| ---------- | --------------------- | ------------------ |
| 双向收发   | hook 只 RX；壳只 TX   | 收发从不走同一条路 |
| 链路层视角 | hook 在 IP4 入口生效  | ARP/DHCP 帧不可见  |
| 可回放产物 | LWIP_DEBUG 文本日志   | 无 pcap 无法重解析 |
| 零侵入     | hook 要 -include 注入 | 换目标要动构建     |
| 运行时插拔 | 手段全是编译期装配    | 故障后才想抓已迟   |

三个背景事实把缺口钉死：

- **LWIP_DEBUG 不可回放**：它是编译期门牌系统（ch23 23.2），2.2.0-dev 里运行时动态开关的 `debug_flags` 全局已不存在；日志没有字节保真度，是给人看的，不是给 Wireshark 看的。
- **QEMU 没有 tap 口**：全系列的 SLIRP 用户态网络（DHCP 10.0.2.15、网关 10.0.2.2）没有宿主侧桥接口，`tcpdump -i lo` 只能看到 hostfwd 落到宿主 loopback 的那一段，guest 内 loopback 完全不可见。
- **filter-dump 不算出路**：宿主侧 QEMU 抓包要把 `-nic user` 改写成 `-netdev` 加 `-object filter-dump`，等于为抓一次包改一遍启动脚本，且只覆盖 QEMU 场景。
- **lwIP 里没有 tcpdump**：协议栈不认识 libpcap，也没有抓包文件的落盘通道。要 pcap，只能自己写。

于是需求被逼成一句话：

> **双向、链路层、可回放成 pcap、零侵入、运行时可插拔**——这就是 pcapx 的验收定义。

五要素各有落点：双向加链路层是 X.3 的接入点问题，可回放是 X.5 的格式问题，零侵入与运行时插拔是 X.2/X.3 的机制问题，而「加了它系统不能变慢、不能崩」是 X.4 的 RTOS 纪律问题。

## X.2 规格先行：三维度可插拔与十条行为契约

动工之前先写规格（`docs/spec/pcapx.md`，S1~S3 已验收通过）。「可插拔」不是口号，是三个互相独立的轴：

1. **接入点运行时可插拔**：attach/detach 换装并恢复 netif 函数指针，不改编译配置、不动 sdkconfig；
2. **sink 后端可插拔**：一个四函数 vtable（open/write/close/free_fn，见 `include/pcapx.h`），半托管文件、RAM 暂存、UART 帧流三种实现同槽替换；
3. **组件引用可插拔**：pcapx 是独立组件，任何 labs 工程顶层一行 `set(EXTRA_COMPONENT_DIRS ...)` 即可挂载。

三个轴正交：换 sink 不动接入点，detach 不丢配置，组件整体拔掉不影响其他实验。接口头文件因此声明为「冻结契约」，实现侧需要偏离时必须在交付报告中说明理由——本篇X.7 的验收数字就是这份契约的回执。

十条行为契约（spec §4，每条绑定一个可 grep 的观测点）：

1. attach 成功 → `I pcapx: ATTACH netif=xx mode=rx+tx snap=N sink=...`
2. attach 被拒（down/busy/sink_open/arg/no_mem）→ `E pcapx: ATTACH_FAIL ... reason=...`
3. QEMU 未开 `-semihosting` → `E pcapx: SINK_OPEN_FAIL ... hint='qemu 需追加 -semihosting'`
4. tap 不阻塞不分配；环满丢新帧 → `W pcapx: DROP cnt=N`（累计值，每 32 次聚合一条）
5. 超 snaplen 截断记录（caplen < origlen）→ stats 的 `truncated` 字段
6. detach 恢复指针并打印会话总计 → `I pcapx: DETACH netif=xx rx=N tx=N drop=N trunc=N`
7. 产物合法性：Wireshark / python 可解析 → `pcapx_validate.py` exit 0
8. 计数精确：打流 N 包，capture + drop + filtered == 协议栈收发总数 → `--expect` 断言失败 exit 非 0
9. 零侵入：lwIP 与 IDF 源码零 diff、sdkconfig 不新增 `LWIP_HOOK_*` 宏 → `git -C ~/esp/esp-idf diff --stat` 为空
10. 不 attach 时近零开销（wrap 已装但 flag 关闭即直通）→ iperf 前后吞吐差 <5%（定量待真机，见 X.9）

验证计划与契约一一对应（spec §5，证据来源绑定）：

- pcap 字节正确性：validate 脚本（纯 python struct 解析，无 scapy 依赖）对 golden 样本与实跑产物双重校验；
- 集成主实验：openeth bring-up → DHCP → attach → UDP/DNS 打流 → detach → 宿主文件落地 → 计数断言；
- 丢包账目实验：ring 缩到 2048B + snaplen=64 + 背靠背 500 帧，DROP 累计与恒等式核对；
- 观测点全量回归：契约每行的日志在 run.log 中逐条 grep（X.7 的回归表）；
- 竞态冒烟：attach/detach 交替 100 次于流量进行中，无 crash、heap 前后对账。

为什么日志行是验收单位？三个理由。其一，机器可回归：grep 与退出码把「看起来对」变成「可断言」。其二，观测点即契约：每条行为一旦被违反，日志里立刻出现异常行或缺行，不需要人来解读现象。其三，这是 ch23 方法论教训的反向应用——「现象记录必须落到包级证据」，验收同样必须落到行级证据，人眼确认是整个链路里最不可信的一环。

## X.3 接入点选型：从编译期钩子到运行时换装

结论：`LWIP_HOOK_IP4_INPUT` 当不了抓包接入点，netif 的 `input` 与 `linkoutput` 两个函数指针才是。前者是 spec §3 机制映射表实读源码后排除的，三个硬伤：

- **编译期宏**：钩子要在编译单元里 `#define LWIP_HOOK_IP4_INPUT my_hook` 并经 `-include` 注入（ch23 23.4-b 的手法，实读 ip4.c:521 的调用点），换目标就要动构建；
- **仅输入侧**：上游 hooks 全集（arch.h/opt.h 实读）根本没有 IP4_OUTPUT，TX 方向无钩子可用；
- **仅 IP 层**：名字就叫 IP4_INPUT，ARP/DHCP 这些非 IP 帧到不了这里——ch23 23.4-b 早明说过它的盲区。

换装方案是系列知识的直接兑现。[[2026-08-26-lwip-deep-dive-ch7-netif-abstraction|第七章]] 讲过 `struct netif` 的 `input/output/linkoutput` 是驱动 init_fn 一锤定音的函数指针契约，运行期「基本不变」——但「基本」留下了合法的改写空间：ch12 的确定性丢帧注入、ch17 的驱动观察点、ch23 的壳计数用的都是同一扇门（Batch 3 沉淀的标准手法）。pcapx 把「TX 侧单点计数」扩成「RX+TX 双向完整抓包」。RX 侧调用链有 [[2026-08-26-lwip-deep-dive-ch17-ethernetif-porting-guide|第十七章]] 的实据：emac_rx 任务 `receive()` → `stack_input` → `esp_netif_receive` → `ethernetif_input` → `netif->input`（`esp_netif/lwip/netif/ethernetif.c:139`），ch17 实验 a 的身份自证行 `hook contexts: TX-linkoutput in 'tcpip', RX-stack_input in 'emac_rx'` 早就预告了两个 wrap 将各跑在什么上下文里。

换装本体只有两个壳（`practice/pcapx/src/pcapx_core.c` 节选，注释为原文缩写）：

```c
/* capture 在调用原 input 之前（规格设计决定）：此刻 pbuf 仍归调用者所有，
 * 原始 input（tcpip_input）会把它投递进 tcpip 邮箱、所有权移交协议栈 */
static err_t pcapx_wrap_input(struct pbuf *p, struct netif *inp)
{
    tap_capture(PCAPX_DIR_RX, p);
    return s_orig_input(p, inp);
}

/* TX 同理：linkoutput 调用时帧已组装完整；返回值透传，不改发送语义 */
static err_t pcapx_wrap_linkoutput(struct netif *netif, struct pbuf *p)
{
    tap_capture(PCAPX_DIR_TX, p);
    return s_orig_linkoutput(netif, p);
}
```

安全模型四条，每条都对应 core 里的显式设计：

- **wrap 常驻 + 原子 flag**：attach 后 wrap 永久装在 netif 上，捕获由原子 `s_enabled` 门控；不抓时 wrap 只做一次 flag 读取即直通，近零开销；
- **publish 顺序**：attach 先初始化全部状态并创建 writer，最后才换装指针 + 开 flag——tap 一开门看到的就是完整状态（attach 代码注释原文）；
- **detach 五步收敛**：关 flag → 恢复原始指针 → 自旋等 `inflight==0`（在飞 tap 的尾部 ≤ snaplen 拷贝，µs 级）→ 停 writer（`run=false` + notify）→ 等排空信号量 → 回收；
- **竞态窗口如实入契约**：恢复指针的瞬间，另一核可能正拿着旧指针进入 wrap——inflight 栅栏保证它们安全走完（wrap 仍会检查 flag 并直通原函数）；lwIP 内部缓存函数指针之类的残余路径在现行代码中不存在，但契约仍建议链路静默期 detach（spec §3 设计决定原文）。另有一个工程取舍要知道：attach/detach 属控制路径，core 未对二者做相互互斥（单 console 会话使用，代码注释明示）。

attach 的前置检查同样值得一看：netif 未 up、`input`/`linkoutput` 指针为空都会被 `reason=down` 拒绝；netif 为 NULL 时日志打出 `netif=??`（netif_tag 对空指针的诚实处理——run.log:72 的 `ATTACH_FAIL netif=?? reason=arg` 就是它）。

暗线 B 在这里有个干净的落点：换装用的是 vanilla netif 契约本身，pcapx 核心不含任何 IDF 私有 API——换成 `esp_eth_update_input_path()`（ch17 的 RX 观察点手法）也能做，但那绑死 esp_eth 句柄、只覆盖以太网路径；`netif->input` 换装对任意 netif 通用。IDF 侧的差异只剩「怎么拿到 netif」：esp_netif 组合关系下要 `esp_netif_get_netif_impl()`（ch7 7.5 的翻译链），且 ch23 23.4-c 的纪律提醒依然有效——动 netif 指针的标准姿势是 `tcpip_callback()` 投递进 tcpip 线程；pcapx 的 lab 走 console 控制路径，靠 flag 门控与 inflight 栅栏同样收敛。

## X.4 tap 的 RTOS 纪律：多生产者、丢新策略与一次踩堆战记

先回答「谁会调到 tap」——这是 [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|第十三章]] 与 [[2026-08-26-lwip-deep-dive-ch19-isr-and-priority-design|第十九章]] 的知识在本篇兑付的地方。core 文件头的线程模型注释（原文节选）：

```text
生产者实际有两类上下文：input wrap 跑在 eth RX 任务（openeth 路径：
esp_eth rx task → esp_netif_receive → ethernetif_input → netif->input），
linkoutput wrap 跑在 tcpip_thread。「SPSC 环」因此按「单一消费者」理解；
多生产者由同一把 portENTER_CRITICAL 旋锁把整个入环操作（元数据+帧数据
memcpy）串行化，换取丢新计数与环指针的无竞态。
```

对照 ch19 19.1 的任务表：tcpip prio 18、emac_rx prio 15，双双 NO_AFFINITY 可跨核漂移。所以「SPSC」是按消费者口径起的名字——单消费者（writer），多生产者（MPSC）；而且 RX 与 TX 可能同时活动，两个生产者可以在不同核并发进入 tap，这正是契约第 4/8 行要求计数精确的原因。纪律五条：

- **一把旋锁包住整个入环**：12B 元数据写 + ≤snaplen 的 `pbuf_copy_partial` 双段直写环，临界区有界；spinlock 提供 SMP 内存序，这是 detach 栅栏能成立的前提（core 注释原文）。
- **禁阻塞、禁分配、禁 printf**：ch13 的账单在前（回调长处理饿死全栈、3 秒卡死实证、一切异步本质是排队），tap 是净增路径，它的每一微秒都直接加在 tcpip 线程或 emac_rx 的时间片上。唯一被豁免的打印是 DROP 聚合行：每 32 次丢帧一条，先快照计数、出锁后再打。
- **丢新不丢旧**：保序（被接受样本时间戳单调）、计数语义简单可审计；DROP 打的是累计值，可 grep 对账。
- **writer 是专职消费者**：优先级 17——刻意卡在 emac_rx(15) 与 tcpip(18) 之间（Kconfig 默认值）：写 sink 抢得过驱动搬运、抢不过协议栈；唤醒用计数型 `ulTaskNotifyTake`（排空期间 tap 的 give 会累积不丢唤醒）；出环的大拷贝放在临界区外——生产者只写 `[head, head+need)`，永不触碰未消费区 `[tail, head)`。
- **writer 的谢幕纪律**：sink 的 close 由 writer 统一执行（保证所有记录写完再关）；give 完成信号量 → 清句柄 → `vTaskDelete(NULL)` 自删的顺序，保证 detach 侧与后续 attach 都不会引用死任务——TCB 由 Idle 收尸（FreeRTOS 系列 ch5/ch9 的语义，core 尾部注释原文）。

> [!tip] 内存账本也在契约里
> attach 时一次性分配环（`ring_bytes`）与 writer 弹床（`snaplen` 字节），都取 `MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT`——确定性访问的 internal RAM；detach 五步走完后全额回收。X.7 的 churn 实验对账的正是这笔账：100 轮之后 heap free 净释放 4224B，说明没有一届会话赖在堆上。

### 战记：12 字节偏移引发的随机崩溃（KD-10）

S3 集成首跑必崩，症状是随机三联征：TLSF `block_locate_free` assert（崩在 RX 任务的 malloc）、Core1 InstrFetchProhibited（A0=0 跳 NULL）、Double exception（异常入口二次异常）。换 RAM sink 排除 semihost 因素、把 RX 任务栈加到 8192，全部无效——「随机崩溃」最常见的两个错误归因（怪分配器、怪栈溢出）都被证伪。

真正的定位手段是**分层二分**：给 tap/writer 双侧加指纹日志，按执行段逐层设闸——L1 只计数、L2 加时间戳、L3a 只写环不唤醒 writer、L4a 只出环不写 sink。闸门推进到 L4 才现形：writer 首帧读出的「元数据」是 `ffffffffffff 525400123456`——广播目的 MAC 加 QEMU 网卡 MAC（52:54:00:12:34:56，全系列日志的常客）。那是以太网帧头，不是元数据。

根因一行：tap 写环时帧数据起点 `off = pos % ring_size` 漏加了 12B prefix，帧头把时间戳/长度元数据盖掉，整条环错位。此后连环塌方：writer 解析出垃圾 caplen（上限 65535）→ `s_tail = pos + 12 + caplen` 越过 `s_head` → `used = head - tail` 无符号下溢成巨值 → 容量判断恒过 → 后续帧按最长 64KB 越界写环，把相邻堆块踩烂。修复同样一行：`off = (pos + PCAPX_RING_PREFIX) % s_ring_size`，五回合构建收敛。

两条沉淀（KD-10 原话）：其一，「环不变式」类代码必须有跨生产者/消费者的端到端集成测试，单侧单测测不出错位；其二，多任务随机崩溃先做「双侧指纹日志 + 执行段分层闸」二分，比盯着栈回溯猜快得多——三种崩溃签名没有一种指向真凶。这个案例也是 X.2 契约第 4/8 行的由来：没有精确计数与恒等式断言，这类缺陷会以「偶尔丢几帧」的面目长期潜伏。

## X.5 pcap 格式：一个字节序陷阱与一个截断语义

pcap 是个只有两种头的朴素格式：24B 全局头（magic / version 2.4 / thiszone / sigfigs / snaplen / network）加每帧 16B 记录头（ts_sec / ts_usec / incl_len / orig_len）。自写它不是为了炫技，而是参考实现踩过的坑必须绕开（KD-8）：

- **找参考实现就先翻车**：组件注册表指认 espressif/pcap 属 esp-protocols，但 esp-protocols 全历史 2149 个 commit 里根本没有 components/pcap——真身在 espressif/idf-extra-components monorepo，registry 元数据与仓库实况脱节。
- **字节序 bug**：参考实现提供 little_endian 标志，但那标志按「魔数字面值」而非「文件字节序」设计——LE 常量 0xD4C3B2A1 以 native fwrite 写到 LE 目标，落盘字节序变成 a1 b2 c3 d4，消费者读出的魔数反而宣告「这是 BE 文件」。官方 simple_sniffer 示例走默认路径才碰巧正确。

pcapx 的对策是**显式逐字节小端序列化**，不引入任何字节序标志（`pcapx_core.c` 节选）：

```c
static void put_le32(uint8_t *p, uint32_t v)
{
    put_le16(p, (uint16_t)(v & 0xffff));
    put_le16(p + 2, (uint16_t)(v >> 16));
}

/* attach 时全局头先于任何记录写出（节选） */
uint8_t ghdr[PCAPX_PCAP_GHDR_LEN] = {0};
put_le32(&ghdr[0], PCAPX_PCAP_MAGIC);          /* 0xa1b2c3d4：µs 分辨率 */
put_le16(&ghdr[4], 2);                         /* version_major */
put_le16(&ghdr[6], 4);                         /* version_minor */
put_le32(&ghdr[16], cfg->snaplen);
put_le32(&ghdr[20], PCAPX_PCAP_LINKTYPE_ETH);  /* LINKTYPE_ETHERNET = 1 */
```

魔数 0xa1b2c3d4 按小端落盘即 `d4 c3 b2 a1`，与参考实现的正确路径（native fwrite 0xA1B2C3D4 于 LE 目标）字节等价，但语义不再依赖目标机字节序——同一份代码放到 BE 目标上产物不变。

第二个坑是参考实现根本没有的**截断语义**：它恒 caplen == origlen。pcapx 把 orig_len 记为 `p->tot_len`（含以太网填充），incl_len 记为 `min(tot_len, snaplen)`，caplen < origlen 即截断并计 truncated。这是 pcap 的正式机制——Wireshark 会显示「frame truncated」；validate 脚本逐记录断言 `incl_len <= snaplen` 且 `orig_len >= incl_len`（X.7 的工具链就查这个）。

writer 出环时把环里的 µs 时间戳组装成 pcap 记录头（`writer_drain` 节选）：

```c
uint8_t rec[PCAPX_PCAP_RHDR_LEN];
put_le32(&rec[0], (uint32_t)(ts_us / 1000000)); /* ts_sec */
put_le32(&rec[4], (uint32_t)(ts_us % 1000000)); /* ts_usec（magic 为 µs 分辨率） */
put_le32(&rec[8], caplen);                      /* incl_len < orig_len 即截断 */
put_le32(&rec[12], orig_len);                   /* orig_len */
sink_write_checked(rec, sizeof(rec));
sink_write_checked(s_bounce, caplen);
```

全局魔数宣告 µs 分辨率，所以 `ts_usec` 写微秒余数而不是毫秒——单位错误是 pcap 工具链最常见的静默劣化（时间戳仍能读，只是差三个数量级）。时间戳取自 `esp_timer_get_time()`，绕开了 `sys_now()` 的 10ms tick 网格（Batch 4 的老坑）。

## X.6 QEMU 半托管深坑：两条互不通约的通路（KD-9）

半托管（semihosting）是「目标机借用宿主机文件系统」的机制，听起来是抓包落盘的完美通道。首跑即翻车，真实日志链（run.log:74-77）：

```text
E (2601) esp_semihost: OpenOCD is not connected!
E (2601) pcapx: SINK_OPEN_FAIL path=/tmp/. hint='qemu 需追加 -semihosting'
E (2601) pcapx: SINK_OPEN_FAIL path=/tmp/. reason=simcall_open errno=21
E (2601) pcapx: ATTACH_FAIL netif=en reason=sink_open
```

明明 QEMU 已经加了 `-semihosting`。根因：IDF 的 VFS 半托管驱动（esp_vfs_semihost）硬依赖 `esp_cpu_dbgr_is_attached()`——Xtensa 上读 DSRSET bit0，只有 OpenOCD attach 才置位；Espressif QEMU 的 `-semihosting` 不模拟 OCD attach，这一位恒 0，于是 `esp_vfs_semihost_register()` 直接返回 ESP_ERR_NOT_SUPPORTED，整条 VFS/newlib/fopen 路径在 QEMU 下是死路（即使 register 侥幸通过，open 也会被 FAIL_IF_NO_DEBUGGER 以 EIO 拒绝）。先手试 IDF 自带的 ARM 约定入口（`xtensa/semihosting.h` 的 `semihosting_call_noerrno`，`break 1,14` 指令）也直接 Guru Meditation「BREAK instr」——两条路都不通，只剩读模拟器源码定案。

答案写在 espressif/qemu 的 `target/xtensa/xtensa-semi.c` 里：QEMU 拦截的是 **SIMCALL 指令 + Xtensa ISS 调用号**（V7 Unix 风格：exit=1 / read=3 / write=4 / open=5 / close=6 / lseek=19，a3..a6 传参、a2 返回、a3 回 errno），与 OpenOCD 的 break+ARM 号约定是两条互不相认的通路——IDF 自己的 `openocd_semihosting.h` 注释早就写明「not compatible with QEMU for Xtensa」。fallback 设计由此而来：register 返回 NOT_SUPPORTED 时，sink 退化为 raw SIMCALL 直连（`pcapx_sink_semihost.c` 节选）：

```c
/* SIMCALL 原语：a2=调用号，a3..a6=参数；返回值 a2、errno a3（QEMU 写回） */
static long semihost_simcall(long nr, long a3, long a4, long a5, long a6,
                             long *errno_out)
{
    register long v2 asm("a2") = nr;
    register long v3 asm("a3") = a3;
    register long v4 asm("a4") = a4;
    register long v5 asm("a5") = a5;
    register long v6 asm("a6") = a6;
    __asm__ __volatile__("simcall" : "+r"(v2), "+r"(v3)
                                 : "r"(v4), "r"(v5), "r"(v6)
                                 : "memory");
    if (errno_out != NULL) {
        *errno_out = v3;
    }
    return v2;
}

/* Xtensa ISS 调用号（xtensa-semi.c 实读）与显式宿主 flags 常数 */
#define ISS_SYS_WRITE 4L
#define ISS_SYS_OPEN  5L
#define ISS_SYS_CLOSE 6L
/* 宿主 Linux x86_64 的 O_WRONLY|O_CREAT|O_TRUNC = 1|0100|01000 = 0x241 */
#define ISS_OPEN_WRONLY_CREAT_TRUNC 0x241L
```

上面日志链里的 errno=21（EISDIR）正是 fallback 已经生效的证明：demo 故意 attach 到 `/tmp/.`，SIMCALL open 把 basename「.」交给宿主，宿主说这是目录——失败发生在宿主一侧，通路本身通了。真正的成功路径在同一份 run.log 里：第 82-84 行 `OpenOCD is not connected!` 之后紧跟 `SINK_OPEN sink=semihost-qemu-simcall path=/tmp/cap.pcap fd=9 host_cwd_rel=1` 与 `ATTACH ... sink=semihost:/tmp/cap.pcap`。

两个二级坑也都踩过。其一，**flags 位错位**：QEMU 把 open 的 flags 原样透传给宿主 `open()`，而 guest newlib 的 O_CREAT=0x200 / O_TRUNC=0x400 与宿主 Linux x86_64（0x40 / 0x200）位定义不同源，必须写显式宿主常数 0x241，禁止用 `<fcntl.h>` 宏组装——期间还因十六进制手算 `1|0x100|0x200=0x301` 漏了 O_CREAT，白绕了一轮 ENOENT。其二，**路径语义**：VFS 通路会把挂载点前缀剥掉、以「QEMU 进程 cwd + basename」落盘，SIMCALL 模式复刻同一行为——`/tmp/cap.pcap` 实际落在启动 QEMU 的目录下，文件名是 cap.pcap，日志里的 `host_cwd_rel=1` 就是这个意思。

顺带一个日志契约的分工细节：`SINK_OPEN_FAIL` 的 hint 行（修复提示属 sink 领域知识）由 sink 实现自己打，core 只负责上一层 `ATTACH_FAIL reason=sink_open`——两层各打各的，run.log:75-77 三行连读就是完整的失败链。落盘及时性同理是 sink 的领域责任：VFS 模式每次 write 后立即 fflush（lab 用 timeout 击杀 QEMU，应用收不到 detach 机会，不 flush 的 stdio 缓冲会整段丢失）；SIMCALL 模式每次 write 即宿主 write(2)，天然落盘。

真机风险边界同样写进了 Kconfig help 与源码注释：SIMCALL 是 ISS 专用指令，无 OpenOCD 的真机（ESP32 LX6）上执行即 illegal instruction。RISC-V 构建自动编译掉 fallback（`__XTENSA__` 条件）。真机要直写文件请 attach OpenOCD 走 VFS 路径，或换 UART / RAM sink（X.8）。这一节的方法论一句话：**模拟器的行为不靠试，读模拟器源码定案**。

## X.7 验收：数字、恒等式与观测点回归

验收产物三件套：run.log（契约行）、cap.pcap（字节产物）、validate 退出码。先看默认会话的关键行（run.log 原文）：

```text
I (2601) pcapx: SINK_OPEN sink=semihost-qemu-simcall path=/tmp/cap.pcap fd=9 host_cwd_rel=1
I (2601) pcapx: ATTACH netif=en mode=rx+tx snap=128 sink=semihost:/tmp/cap.pcap
E (2601) pcapx: ATTACH_FAIL netif=en reason=busy
pcapx_stats rx=53 tx=54 filtered=0 dropped=0 truncated=0 written=107 ring_high_wm=236
I (4101) pcapx: SINK_CLOSE sink=semihost-qemu-simcall path=/tmp/cap.pcap bytes=12756 writes=215
I (4101) pcapx: DETACH netif=en rx=53 tx=54 drop=0 trunc=0
```

硬数字总表（全部来自三份日志与 validate 退出码）：

| 验收项        | 实测数字                        |
| ------------- | ------------------------------- |
| validate 断言 | total=107 arp=5 udp=52 icmp=50  |
| 方向账        | rx=53 tx=54（53+54=107）        |
| DROP 恒等式   | 1003 = 0 + 918 + 85，恒等式成立 |
| 环水位        | ring_high_wm=1976/2048          |
| churn 冒烟    | rounds_ok=100/100，无 crash     |
| heap 对账     | 344204 -> 348428，净释放 4224B  |
| 零侵入        | esp-idf git diff 为空           |

逐项对账：

- **107 帧的构成**（lab README 验收产物行 + validate 摘要）：5 ARP + 52 UDP（50 个探针 + 1 对 DNS 查询/应答，SLIRP 的 DNS 代理把 baidu.com 答成 198.18.1.95）+ 50 ICMP（发往闭合端口 9999 的每个 UDP 都招致一个确定性 port-unreachable 回弹）。方向账 rx=53 / tx=54 由 stats 与 DETACH 行双重记录（run.log:92、96），validate 侧 `--expect rx=53,tx=54` 断言 rx+tx == total。
- **DROP 恒等式**（run-drop.log:115 原文 `IDENTITY rx+tx=1003 filtered=0 dropped=918 written=85 -> OK`）：1003 = 501+502，分流为 0 过滤 + 918 丢弃 + 85 落盘，一个帧都不许下落不明。构造方法是 KD-11 的教训：QEMU 下用 vTaskDelay 压不出 writer 背压（2003 次「2ms delay」在约 1.1s 内跑完、500 帧零 drop），改 busy-wait 自旋 2ms/帧把出环速率确定性钉死在约 500 帧/s，环才稳定打满。
- **DROP 实验的流量构成**：ring=2048、snaplen=64、500 个背靠背 UDP 加各自招致的 ICMP 回弹（run-drop.log:113 的 rx=501/tx=502）；DROP 行从 cnt=32 到 cnt=896 共 28 条（每 32 次聚合一条，最终计数 918），ring_high_wm=1976/2048。
- **字节级对账**：SINK_CLOSE 行 `bytes=12756 writes=215` = 24B 全局头 + 107×16B 记录头 + 11020B 帧数据；writes = 1 次全局头 + 每帧 2 次（记录头 + 载荷）。仪器自己也要被计量——ch17 实验 c 的老纪律。
- **churn**（run-churn.log:615 原文 `CHURN RESULT rounds_ok=100/100 heap_before=344204 heap_after=348428 delta=-4224`）：UDP 流量（8ms/包）进行中 attach/detach 100 轮全部成功，中间进度点 heap 在 339492~343696 波动，终点 free 不降反升——净释放 4224 字节，无泄漏。
- **零侵入**：`git -C ~/esp/esp-idf diff --stat` 为空；sdkconfig 相比基线不新增任何 `CONFIG_LWIP_HOOK_*`（组件 README 记录核查步骤）。
- **镜像时效性**：run.log:57 的 built 指纹（Aug 28 2026 00:37:28）与 boot/app 组件的 compile time 同批（秒级差异）——Batch 7 的纪律：先核对指纹再读数，杜绝烧旧镜像量新数据。

观测点回归表（spec §4 契约逐条 grep 的结果摘要）：

| 契约行    | 位置（行号）  |
| --------- | ------------- |
| ATTACH    | run.log:84    |
| 失败三类  | run.log:72 等 |
| SINK_OPEN | run.log:75-76 |
| stats 行  | run.log:92-98 |
| DETACH    | run.log:96    |
| DROP 行   | 见 drop 日志  |

复现就两条 shim（lab README 原文）：

```bash
# 构建 + 生成 QEMU 镜像
source /home/huanglin/esp/shims/build-pcapx-lab.sh

# 运行 60s（cap.pcap 落在本目录，串口输出 tee 到 run.log）
RUN_SECONDS=60 source /home/huanglin/esp/shims/run-pcapx-lab.sh

# 宿主校验（结构合法性 + 计数断言，全过 exit 0）
python3 ../pcapx/tools/pcapx_validate.py cap.pcap \
  --expect total=107,arp=5,rx=53,tx=54
```

实验切换：编辑 `sdkconfig.defaults` 打开对应开关（`CONFIG_LAB_PCAPX_EXP_DROP` / `CONFIG_LAB_PCAPX_EXP_CHURN`）再依次 source 两个 shim——run-drop.log 与 run-churn.log 就是这么产出的（build shim 每次从 defaults 重新生成 sdkconfig）。

## X.8 使用指南：三个 sink 与参数建议

| sink 后端 | 适用场景（何时选）     | 落盘与还原方式（要点）       |
| --------- | ---------------------- | ---------------------------- |
| semihost  | QEMU（或真机 OpenOCD） | 目标直写宿主文件，验收主路径 |
| ram       | 无宿主信道时事后导出   | RAM 环形暂存 + console 导出  |
| uart      | 真机、无调试器         | 帧协议 + 宿主收集脚本还原    |

RAM sink 用 `pcapx_sink_ram_new(cap_bytes)` 构造，console 的 `pcapx_ram_dump` 导出、宿主 `tools/pcapx_ram_extract.py` 还原；UART sink 用 `pcapx_sink_uart_new(uart, baud)`，宿主侧 `tools/pcapx_uart_collect.py` 收流重组 pcap。组件的 Kconfig 默认值（menuconfig → pcapx）：writer 优先级 17、writer 栈 4096B、环容量 8192B、SIMCALL fallback 默认 y——四个旋钮的取舍理由散见 X.4/X.6。

> [!warning] 待真机验证
> UART 帧 sink 的端到端链路（真机发送 + 宿主收集脚本还原 pcap）尚未在真机实测——QEMU 环境实证的是 semihost 与 RAM 两条路；UART 帧协议本身（4B 魔数 + len + CRC，抗串口日志穿插）随组件交付，BOX-3 到货后首先补这项。

参数建议四条：

- **snaplen 默认 128，上限别超过 512**：snaplen 决定的不只是 pcap 里每帧多长，还有 tap 临界区的长度——持锁内容 = 12B 元数据 + `min(tot_len, snaplen)` 的双段 memcpy。160MHz CPU（run.log:37 自报）下 512B 拷贝是微秒级，对照 ch19 的每包账单（tcpip 站 298µs/包），tap 税是小头；但 1514B 全帧 snaplen 会把这笔税放大一个数量级，且直接加在 tcpip 线程与 emac_rx 的时间片上。128 已覆盖 ARP / ICMP / DNS / UDP 的头部与载荷前缀。
- **过滤是结构体不是表达式**：ethertype 主机序（0x0800/0x0806/0x86dd）、ip_proto（1=ICMP/6=TCP/17=UDP）、port 网络序（与线上字节直接比较，命中 src 或 dst 任一）。IPv6 不跟随扩展头、VLAN 帧在设置 L4 过滤时判不匹配——两者都是 non-goal，Wireshark 侧 display filter 可补救。
- **ring 容量按「writer 最长停顿 × 到达速率」反推**（ch17 环深公式的同款思路）：默认 8192B；丢包实验刻意缩到 2048B + snaplen=64，就是为了在受控条件下把环打满、验出恒等式。
- **先 attach 后打流，给 writer 留排空时间**：lab 的默认会话 detach 前主动 drain 500ms、DROP 实验 drain 1000ms（等 ICMP 回弹尾巴）；detach 本身自带排空（等 `s_writer_done` 信号量），但主动 drain 让「会话总计」数字在 DETACH 行里就定格。

## X.9 翻车点表与扩展路线

| 翻车症状    | 根因速记     | 处置（一条）  |
| ----------- | ------------ | ------------- |
| sink 打不开 | 缺 DSRSET 位 | SIMCALL 直连  |
| SIMCALL 错  | O\_\* 位错位 | 常数 0x241    |
| 随机崩溃    | 漏 12B 偏移  | 补 12B 偏移   |
| 背压造不出  | tick 不稳    | busy-wait     |
| pcap 乱码   | 魔数按字面   | 小端序列化    |
| detach 竞态 | 恢复有窗口   | 静默期 detach |
| 重复 attach | 不管 sink2   | 单 attach     |

其中「重复 attach 泄漏」值得一句解释：已 attach 再 attach 会报 `reason=busy`，但 core 不接管第二个 sink 对象——lab 故意遗留这约 4.3KB 换取契约行证据（run.log:85-86），生产使用守住「一次只 attach 一个」即可。

扩展路线（spec non-goal 清单，按需迭代）：BPF / pcap-filter 表达式过滤；多 netif 并发 attach（API 形态已预留，实现只保证单 netif）；网络回传 sink（自指回路风险：捕获自身发送会递增流量、SLIRP 下污染样本）；WiFi sniffer / Radiotap（本环境 QEMU 无 esp-wifi-mac，公约已证）。这几项的共同点是「先有真实需求再动工」——本篇的教训之一就是规格的 non-goal 清单和 Goals 一样值钱。

> [!warning] 待真机验证
> 两笔定量账在 QEMU 补不了：其一，spec 契约第 10 行「不 attach 时 iperf 吞吐差 <5%」——宿主负载噪声 ±50% 的仿真环境测不出 5% 量级的差异，需真机配对测量；其二，上述 UART sink 端到端与 BOX-3 真机抓包（含 WiFi 侧）一并留待真机迭代。

## X.10 小结

- 需求从缺口来：ch23 的 tcpdump / IP4 hook / linkoutput 壳没有一条同时做到双向、链路层、可回放——番外把「工具不够用」变成「自己造一个」。
- 可插拔是三个独立的轴：接入点换装（运行时 attach/detach）、sink vtable（半托管/RAM/UART 同槽替换）、组件引用（EXTRA_COMPONENT_DIRS 一行挂载）；十条行为契约每条绑定一行可 grep 的观测点，验收单位是日志行与退出码，不是人眼。
- 接入点选 netif 函数指针而非编译期钩子：input/linkoutput 换装是唯一同时覆盖 RX+TX、链路层、运行时可插拔的位置（ch7 契约 + ch17 调用链的兑现）；wrap 常驻 + 原子 flag + publish 顺序 + inflight 栅栏是它的安全模型，detach 竞态窗口如实写进契约。
- tap 的纪律全部继承系列前作：多生产者一把旋锁串行化、禁阻塞禁分配禁 printf、丢新不丢旧且计数精确、writer prio 17 卡在 emac_rx(15) 与 tcpip(18) 之间（ch13/ch19 的线程与优先级知识落到了 Kconfig 默认值上）。
- 四个坑全部「读源码定案」：参考组件的字节序标志 bug 与截断缺失（KD-8）、QEMU 半托管 OpenOCD 与 SIMCALL 双通路互斥加 O\_\* 位错位（KD-9）、tap 写环 12B 偏移连环踩堆（KD-10，分层二分五轮收敛）、QEMU 下 vTaskDelay 做不出背压（KD-11）。
- 验收数字自洽：107 帧（ARP 5 / UDP 52 / ICMP 50）Wireshark 可开；DROP 恒等式 1003 = 0 + 918 + 85 精确成立；churn 100/100、heap 净释放 4224B；esp-idf 零 diff。
- 复现两条命令即可全链路重放（build/run 两个 shim + validate 断言），会话全自动——这也是公约对实验工程的收敛方向。
- 下一站待真机：UART sink 端到端与吞吐 <5% 定量。工具箱自此补上最后一块：ch23 教你怎么看，本篇教你怎么留档——抓到的 pcap 可以交给任何人重放。回到主线见 [[2026-08-26-lwip-deep-dive-ch24-performance-tuning-pitfalls|第二十四章]] 与 [[2026-08-26-lwip-deep-dive-series-index|系列索引]]。
