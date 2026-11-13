# S31 生产化架构：OS 与 TCP/IP 的组件拆分

> 状态：**设计文档**；对应的四个 Zig 切片宿主测试已由主线于 2026-11-13 跑通（15/15、8/8、18/18、9/9），均未上板。目标是把 ch01–ch28 的“章节实现”收敛成可复用组件，
> 而不是继续复制第 29、30 个工程。本文只定边界、接口、依赖与编码顺序。

## 1. 两条主线，一套底座

```text
应用 / 服务 (OTA, 配网, 恢复, 遥测)
        │
┌───────┴────────┐
│   TCP/IP 栈     │
│  socket / tls   │
└───────┬────────┘
        │ 只用公共内核 API
┌───────┴────────┐
│   OS 内核       │
│ sched/sync/time │
└───────┬────────┘
        │
┌───────┴────────┐
│ arch / hal / bsp│
└────────────────┘
```

规则：

- **单向依赖**：`arch → kernel → net → services → apps`，禁止反向调用。
- **协议不碰硬件**：`net/*` 只能通过 `netif` 驱动接口收发，不直接写 EMAC/WiFi 寄存器。
- **内核不碰协议**：`kernel/*` 不 import `net/*`，只提供线程、锁、时间、内存。
- **arch 不含策略**：`arch/riscv` 只做 trap、上下文、CSR、CLIC、原子操作。
- **服务可依赖内核与网络**；应用只依赖服务与公共 API。
- **禁止隐式分配**：所有缓冲/对象由调用方注入 allocator 或静态池。

## 2. 目录规划

```text
practice/s31-components/
  arch/riscv/          trap、context、clic、atomic、per-cpu
  kernel/
    sched/             TCB、就绪队列、tick、抢占、阻塞/唤醒
    sync/              spin、mutex(PI)、sem、queue、event
    time/              systimer、tick、超时轮、tickless
    mem/               TLSF、pool、stack、caps
  hal/                 uart/gpio/spi/flash/emac/wifi/entropy 接口
  bsp/s31-coreboard/   引脚、时钟、Flash、PHY、射频配置
  crypto/              hash/verify/random 的注入式接口（算法在外部或后续切片）
  net/
    pktbuf/            引用计数包、链、headroom、静态池
    netif/             驱动 vtable、RX/TX 环、链路状态、统计
    ethernet/          Ethernet II、VLAN
    arp/               ARP 缓存/老化
    ipv4/              头、校验和、分片、路由
    icmp/              echo/错误
    udp/               UDP 控制块
    tcp/               状态机、重传、窗口、拥塞
    dhcp/ dns/         客户端
    socket/            socket ops、poll、非阻塞
    tls/ http/ mqtt/   应用协议（后续）
    bench/ pcap/       统计与抓包钩子
  services/
    log/ panic/ trace/ watchdog/ power/ config/ ota/ provisioning/ recovery/
  apps/
    s31-node/          产品应用装配
```

`tools/s31-production/` 里已有的 `ota`、`netmgr`、`provisioning`、`recovery` 作为**服务层原型**，
后续迁入 `components/services/`；不要在新内核里再写第二份。

## 3. OS 组件契约

### 3.1 arch/riscv

```zig
pub const TrapFrame = extern struct { /* mepc, mstatus, regs... */ };
pub fn irqSave() u32;
pub fn irqRestore(state: u32) void;
pub fn contextSwitch(save: *usize, target: usize) void; // naked
pub fn clicEnable(source: u16, priority: u8) void;
```

- 只暴露机制，不做调度决策。
- `switchRaw` 的 naked/`asm volatile("call ...")` 约束继续有效。
- 每核状态（`mscratch`/per-cpu）由 arch 提供，sched 使用。

### 3.2 kernel/sched

```zig
pub const Task = struct { id: u32, prio: u8, state: State, stack: []u8, /*...*/ };
pub fn spawn(cfg: SpawnConfig) !*Task;
pub fn yield() void;
pub fn sleepUs(us: u64) void;
pub fn block(reason: BlockReason) void;
pub fn wake(task: *Task) void;
pub fn current() *Task;
```

- `SpawnConfig` 包含栈、优先级、入口、参数、名字；不包含“章节工程”概念。
- 阻塞/唤醒只操作等待链；超时由 `kernel/time` 注入。
- 先单核正确，再扩展 SMP；SMP 的 per-CPU 队列作为独立模块。

### 3.3 kernel/sync

```zig
pub const Mutex = struct { owner: ?*Task, waiters: WaitQueue, /*...*/ };
pub fn lock(m: *Mutex) void;
pub fn unlock(m: *Mutex) void;
pub const Semaphore = struct { count: u32, waiters: WaitQueue };
pub const Queue = struct { /* ring + waiters */ };
```

- mutex 必须实现优先级继承；ch12 的 PI 缺陷先修再冻结 API。
- spinlock 只用于极短临界区；禁止在持锁时睡眠。
- 所有等待都带可选超时，避免永久挂死。

### 3.4 kernel/time

```zig
pub fn nowUs() u64;
pub fn nowTicks() u64;
pub const Timer = struct { deadline_us: u64, callback: *const fn(*Timer) void };
pub fn arm(t: *Timer) void;
pub fn disarm(t: *Timer) void;
```

- 单调时钟与墙钟分离；SNTP 只改墙钟偏移。
- tickless 作为 time 的可选策略，不改变 API。
- 提供 `bench` 计数：tick 抖动、超时延迟、唤醒延迟。

### 3.5 kernel/mem

```zig
pub const Allocator = struct { /* alloc/free/resize */ };
pub fn initHeap(region: []u8) void;
pub fn stackUsage(task: *Task) usize;
```

- 组件不直接调用全局堆；通过 `Allocator` 注入。
- 静态池优先；OOM 必须返回错误，不 panic（除启动期）。

## 4. TCP/IP 组件契约

### 4.1 pktbuf（最优先拆）

```zig
pub const Pkt = struct {
    data: []u8,          // 含 headroom
    len: usize,
    refs: u32,
    next: ?*Pkt,
};
pub fn alloc(pool: *Pool, headroom: usize, len: usize) !*Pkt;
pub fn clone(p: *Pkt) *Pkt;
pub fn put(p: *Pkt) void;
```

- **RX 链归属**：驱动从池 `alloc` → 交给 `netif` → 协议层只读/改自己那层的头 →
  最后一个消费者 `put`；协议层不得保存包指针到回调返回之后。
- **TX 链归属**：socket 从池借出 → 协议层填头 → `netif.tx` 提交 → 驱动发送完成 `put`；
  `tx` 失败时由 `netif` 负责 `put`，调用方不再持有。
- **禁止跨层释放**：只有“当前所有者”能 `put`；转移所有权必须在函数注释/README 写明。
- 支持链式包（分片/聚合），避免整包拷贝。
- 池按 MTU/连接数静态配置；统计 `alloc_fail`、`peak`。

### 4.2 netif

```zig
pub const Netif = struct {
    mtu: usize,
    driver: *const Driver,
    stats: Stats,
};
pub const Driver = struct {
    init: *const fn(*Netif) anyerror!void,
    deinit: *const fn(*Netif) void,
    tx: *const fn(*Netif, *Pkt) anyerror!void,
    poll: *const fn(*Netif) void,
    setRxCallback: *const fn(*Netif, *const fn(*Netif, *Pkt) void) void,
    setLinkCallback: *const fn(*Netif, *const fn(*Netif, bool) void) void,
    txReady: *const fn(*Netif) bool,
};
```

- 协议栈只调用 `netif.tx`；驱动只把 RX 包交给 `netif`。
- `setLinkCallback` 提供 `link_up/link_down`，这是 `netmgr` 事件的来源；缺它 netmgr 接不进来。
- `txReady` 用于 TCP 窗口/队列背压；返回 false 时上层必须停止提交，不能忙等。
- `deinit` 负责停 DMA/释放环，供 OTA/复位/测试拆卸。
- 中断上下文只入队，不在 ISR 里跑协议。
- 统计：rx/tx/drop/err/queue_depth。

### 4.3 协议层

- `ethernet`：EtherType 分发；VLAN 可选。
- `arp`：缓存、老化、请求抑制、冲突。
- `ipv4`：校验和、TTL、分片/重组、路由表；先单播。
- `icmp`：echo、目的不可达、超时。
- `udp`：控制块、端口复用、校验和。
- `tcp`：状态机、序号/ACK、RTO、重传、窗口、拥塞；先单连接正确，再多连接。
- `socket`：`open/bind/connect/listen/accept/send/recv/close/poll`；阻塞/非阻塞。
- `dhcp/dns`：租约、续约、缓存、超时。
- `tls/http/mqtt`：单独目录，依赖 socket，不反向依赖 IP 内部结构。

### 4.4 并发模型

第一阶段：**单网络线程 + 驱动 RX 队列**。

- ISR 只把包放进 lock-free ring；
- 网络线程轮询/被唤醒，跑 ARP/IP/TCP/应用回调；
- socket API 通过消息队列与网络线程交互；
- 这样先避免“每个协议层各一把锁”。

第二阶段：SMP 时按连接/网卡分片，再引入 per-connection 锁；不改变上层 API。

## 5. 服务层

| 服务           | 依赖                      | 说明                      |
| -------------- | ------------------------- | ------------------------- |
| `log`          | kernel/time, hal/uart     | 分级、环形缓冲、异步 sink |
| `panic`        | arch, kernel              | trap 现场、coredump 标记  |
| `watchdog`     | kernel/time               | 任务心跳、超时策略        |
| `power`        | hal, kernel/time          | light/deep sleep、唤醒源  |
| `config`       | flash, kernel/sync        | 双副本、CRC、版本迁移     |
| `ota`          | net/socket, flash, crypto | 清单、A/B、回滚           |
| `provisioning` | net, config               | SoftAP/BLE PoP、凭据      |
| `recovery`     | watchdog, ota             | boot loop 熔断、安全模式  |

## 6. 编码顺序（不做验证）

1. **接口骨架**：`arch`、`kernel/sched`、`kernel/time`、`net/pktbuf`、`net/netif` 的公共类型与空实现。
2. **pktbuf + loopback netif**：主机侧用假驱动跑 ARP/IPv4/ICMP/UDP。
3. **sched + sync + time**：从 ch10–ch14 抽公共 API，先单核。
4. **TCP**：在 loopback 上跑状态机/重传/窗口；再接真实 netif。
5. **socket + 事件循环**：单网络线程模型。
6. **服务层**：把 `tools/s31-production` 的 ota/provisioning/recovery 迁入。
7. **BSP 集成**：EMAC/WiFi 驱动只实现 `netif.Driver`。

每一步只写代码与测试，不运行；主机测试作为下一阶段门禁。

## 7. 对标预留

从第一天就把可测量性写进接口：

- OS：`kernel/bench` 记录上下文切换、ISR 延迟、锁等待、tick 抖动。
- Net：`net/bench` 记录吞吐、RTT、重传、每连接 RAM、每 MB 周期；`net/pcap` 提供抓包钩子。
- 所有统计用 p50/p95/max，不只均值；与 FreeRTOS/lwIP 同板对照时才谈“对标”。

## 8. 明确不做（本阶段）

- 不做 POSIX 兼容层。
- 不做 MPU/MMU 进程隔离。
- 不先做 IPv6/SACK/QUIC；等 IPv4/TCP 主机测试稳定后再评估。
- 不把 28 个章节工程改造成组件；章节保留为参考实现，组件另立。
- 不在本阶段跑构建、测试、烧录或 code-site。
