---
title: "DPDK 工具对比实战: 4 类工具在同一故障上的'看见/看不见'对比"
date: 2026-06-02 09:00:00
tags: [dpdk, practice, ethtool, ss, ip, dpdk-procinfo, debugging, observability]
description: "用 4 类故障 (mbuf 泄漏/TX 队列满/RSS 关掉/sctp 路径) 演示 ethtool/ss/ip/dpdk-procinfo 各能看到什么, 落地'网卡被谁拥有决定工具选择'"
---

> [!info] 实战配套文档
> 本篇是 [[ch34-ethtool-comparison|ch34 工具全景对比]] 的实战版.
> 能力矩阵和理论见 ch34, 这里聚焦**手把手复现 + 4 工具对比**:
>
> - 同一故障, 4 个工具分别能看到什么
> - 演示"DPDK 拥有网卡后, 内核工具失明"的真实表现
> - 给出真实环境下的命令模板

---

## 1. 实战概览

### 1.1 核心结论

**网卡被谁拥有, 决定你用哪个工具**。3 句话总结:

```
DPDK 拥有网卡前 (内核驱动):
  → ethtool / ip / ss / conntrack 全部能用

DPDK 拥有网卡中 (绑定后):
  → 上述工具全部失明
  → 唯一能看内部状态: dpdk-procinfo / 应用 CLI / Telemetry

排查顺序: 物理 → 协议栈 → DPDK 数据面 → 应用层
  → 一层一层来, 别上来就 dpdk-procinfo
```

### 1.2 文件清单

```
practice/dpdk_tool_compare/
├── fault_inject_app.c        # 故意触发 4 类故障的 DPDK 应用
├── compare_tools.sh          # 真实 DPDK 环境下的 4 工具对比
├── sim_dpdk_runaway.sh       # 无 DPDK 硬件也能跑的演示
└── meson.build               # 编译脚本
```

### 1.3 4 类故障

| 故障              | 表现                  | 应该用哪个工具               |
| ----------------- | --------------------- | ---------------------------- |
| **mbuf 泄漏**     | 持续增长, 最终 nombuf | dpdk-procinfo 看 mempool     |
| **TX 队列满**     | 应用发不出去          | dpdk-procinfo 看 queue depth |
| **RSS 关/不均衡** | 单核 100%             | perf + taskset + ethtool -x  |
| **应用层 TCP**    | DPDK NAT/网关         | 应用 CLI / metrics           |

---

## 2. 快速开始: 无 DPDK 硬件也能跑

如果手头没 DPDK 网卡, 先跑 `sim_dpdk_runaway.sh` 体验"工具能力边界":

```bash
cd practice/dpdk_tool_compare
chmod +x sim_dpdk_runaway.sh
./sim_dpdk_runaway.sh
```

它会:

1. 编译一个 busy-loop C 程序, 模拟 DPDK 进程
2. 启动后, 用 4 个工具 (ethtool / ss / ip / ps) 分别"探测"
3. 打印对比表格, 直观展示"哪些工具失明"

输出片段 (无 DPDK 网卡时):

```
──────────────────────────────────────────────────────────
工具 4: 'dpdk-procinfo' (这里用 ps/lsof 模拟)
──────────────────────────────────────────────────────────
目标: 看 DPDK 进程内部状态 (mempool, queue, lcore)
    PID   %CPU %MEM    VSZ   RSS   ELAPSED  COMM
  12345  99.5  0.1   2560   512   00:01    dpdk_sim

CPU 占用: 99.5% (模拟 lcore 100% 占用)

  等效真实 DPDK 下 dpdk-procinfo 的输出:
  Port 0: 0000:3d:00.0
    Driver: net_i40e
    RX: Packets: 12345678  Nombufs: 0      ← 真实包数, 内核工具看不到
    ...
```

---

## 3. 真实 DPDK 环境: 编译 fault_inject_app

### 3.1 编译

```bash
export RTE_SDK=/opt/dpdk

gcc -O2 -g -Wall \
    -I$RTE_SDK/lib/eal/include \
    -I$RTE_SDK/lib/eal/linux/include \
    -I$RTE_SDK/lib/mempool/include \
    -I$RTE_SDK/lib/mbuf/include \
    -I$RTE_SDK/lib/ethdev/include \
    -I$RTE_SDK/lib/net/include \
    -I$RTE_SDK/lib/ring/include \
    -I$RTE_SDK/lib/lcore/include \
    -include $RTE_SDK/config/rte_config.h \
    -DALLOW_EXPERIMENTAL_API \
    fault_inject_app.c \
    -lrte_eal -lrte_mempool -lrte_mbuf -lrte_ethdev -lrte_net \
    -lrte_ring -lrte_kvargs -lpthread -lm -ldl \
    -o fault_inject_app
```

### 3.2 运行 (4 个故障 flag 可独立开)

```bash
# 把网卡绑到 DPDK (略, 见 ch31)

# 1. 正常运行 (基线)
./fault_inject_app -l 0-3 --no-pci -- --run-seconds=300

# 2. 触发 mbuf 泄漏
./fault_inject_app -l 0-3 --no-pci -- \
    --fault-mbuf-leak --run-seconds=300

# 3. 触发 TX 队列满
./fault_inject_app -l 0-3 --no-pci -- \
    --fault-tx-backlog --run-seconds=300

# 4. 触发单 lcore 不均衡
./fault_inject_app -l 0-3 --no-pci -- \
    --fault-no-rss --run-seconds=300
```

应用启动后, 立刻打开另一个终端跑对比脚本。

---

## 4. 4 工具对比: 同一故障, 谁能看到

### 4.1 故障 1: mbuf 泄漏

**触发**: `./fault_inject_app --fault-mbuf-leak`

```bash
# 启动对比脚本
./compare_tools.sh $(pidof fault_inject_app) eth0
```

输出 (节选关键字段):

```
工具 1: ethtool -S eth0                    → 失明
  $ ethtool -S eth0
  Cannot get driver information: No such device
  ↑ 网卡被 DPDK 拥有, 内核驱动 sysfs 切走

工具 2: ss -s                              → 失明
  TCP:   1000 (estab 800, closed 100, orphaned 0, timewait 0)
  ↑ 协议栈无关

工具 3: ip -s link show eth0               → 失明
  RX:  bytes 12345   packets 100   errors 0   dropped 0
  ↑ 数字停在 bind 前的值, 不再增长

工具 4: dpdk-procinfo                      → ✓ 唯一能看到
  Port 1 RX: Packets: 50000   Nombufs: 50000   ← ← ← mbuf 耗尽
  Mbuf Pool: Used: 8190/8191 (99.9%)            ← ← ← 即将爆
```

**根因**:

- `Nombufs` 数字反映 mbuf 分配失败次数
- `Mbuf Pool.Used` 接近上限 → 池子快空了
- 数字持续单调增长 → 泄漏

**修复**:

- 检查应用是否每条路径都 `rte_pktmbuf_free()`
- 用 ASan 编译 (见 ch33 调试实战)

### 4.2 故障 2: TX 队列满

**触发**: `./fault_inject_app --fault-tx-backlog`

```
工具 1: ethtool -S eth0                    → 失明
工具 2: ss -s                              → 失明
工具 3: ip -s link show eth0               → 失明
工具 4: dpdk-procinfo                      → ✓ 看到
  Port 2 TX: Packets: 0  Errors: 12345     ← ← 发不出去
  Queue 2 TX: Used: 1024/1024              ← ← 满了
```

**根因**:

- `Queue TX Used = Size` → ring 已满
- `TX Errors` 增长 → NIC 拒绝发送
- 对端可能反压 (pause frame) 或网卡拥塞

**修复**:

- 检查 TX 路径是否调用了 `rte_eth_tx_burst`
- 对端是否有反压 (看 `rx_pause_frames`)
- 加大 TX ring size (`RTE_ETH_TX_RING_SIZE`)

### 4.3 故障 3: RSS 关/不均衡

**触发**: `./fault_inject_app --fault-no-rss`

```
工具 1: ethtool -S eth0                    → 部分可见
  $ ethtool -S eth0
  rx_queue_0_packets: 12345678
  rx_queue_1_packets: 12                  ← ← ← 几乎不增长
  rx_queue_2_packets: 8
  rx_queue_3_packets: 5
  ↑ 但 DPDK 拥有后这个也失明...

工具 4: dpdk-procinfo                      → ✓ 看到 lcore 不均衡
  LCore 0: State: WAIT  CPU: 0
  LCore 1: State: RUNNING  CPU: 3   RX: 12345678
  LCore 2: State: WAIT  CPU: 0
  LCore 3: State: WAIT  CPU: 0
  ↑ 一个 lcore 干活, 其他闲

工具 5: perf top                           → 看到 CPU 热点
  99%  busy_loop
  ↑ 单一热点的典型表现
```

**根因**:

- `LCore.State = WAIT` 持续 → 那个 lcore 没事干
- 一个 lcore CPU 100%, 其他 0% → 不均衡
- 等效 DPDK 失明后, 这种问题只有 perf / taskset 能间接看到

**修复**:

- 启用 RSS (port_conf.mq_mode = RTE_ETH_MQ_RX_RSS)
- 用 rte_flow 把不同流分到不同队列
- 检查 ethtool -x 看 RSS indirection (绑卡前)

### 4.4 故障 4: 应用层 TCP/连接

**场景**: DPDK 写的 L4 代理, 客户端能连, ss 看不到

```
工具 1: ethtool -S eth0                    → 失明
工具 2: ss -tan                            → ✗ 看不到 DPDK 的连接
  State  Recv-Q  Send-Q  ...
  ↑ 这里是内核 TCP, DPDK 走的不是这条
工具 3: ip -s link                         → 失明
工具 4: dpdk-procinfo                      → ✓ 但只看到 port 层
  Port: 12345678 packets    ← 不知道具体哪个连接

工具 5: 应用自带 CLI                        → ✓ 唯一能看到
  $ curl http://<app>:9090/metrics | grep tcp_connections
  tcp_connections{state="established"} 5678
  ↑ 必须应用自己 expose
```

**根因**:

- DPDK 应用自己实现 TCP/IP 协议栈, 不走内核
- 内核工具完全感知不到

**修复**:

- 让应用 expose Prometheus / Telemetry
- 或用 OVS-DPDK / VPP 自带 `show` 命令

---

## 5. 工具选择决策树 (实战版)

```text
问题: 网络出问题
│
├── 1. 物理层 (光模块/速率/FCS 错)?
│   └─ 绑 DPDK 前用 ethtool -S / -m 抓快照
│
├── 2. 内核 TCP/UDP 连接问题?
│   └─ ss -tanp / ss -tin / conntrack
│      (DPDK L4 代理绕过这里, 这步看不到)
│
├── 3. DPDK 数据面问题 (pps/mbuf/queue/lcore)?
│   └─ dpdk-procinfo / 应用 CLI / Telemetry
│
├── 4. 整节点吞吐低?
│   ├─ 物理: ethtool -S | grep err/drop
│   ├─ 协议: ss -s / netstat -s
│   └─ DPDK: dpdk-procinfo + perf + bpftrace
│
└── 5. 应用内部 (NAT 会话 / 流表 / 协议状态)?
   └─ 应用 CLI (VPP show nat44, OVS dump-flows, 自研)
```

---

## 6. 现场排查命令模板

### 6.1 一键抓全所有工具的输出

```bash
#!/bin/bash
# snapshot.sh — 一次抓完所有工具的输出, 适合发到群里求助

OUT=/tmp/dpdk-snapshot-$(date +%Y%m%d-%H%M%S).txt
exec > >(tee -a $OUT) 2>&1

echo "=== Time: $(date) ==="
echo "=== Host: $(hostname) ==="
echo "=== Uptime: $(uptime) ==="
echo ""

echo "=== ethtool -S ==="
ethtool -S eth0 2>&1 | head -20

echo "=== ip -s link ==="
ip -s link show eth0

echo "=== ip route ==="
ip route show

echo "=== ss -s ==="
ss -s

echo "=== ss -tan (top 20) ==="
ss -tan | head -20

echo "=== conntrack -S ==="
conntrack -S 2>/dev/null || echo "conntrack not installed"

echo "=== /proc/interrupts (eth only) ==="
grep -E "eth|i40e|mlx" /proc/interrupts

echo "=== /proc/softirqs (net) ==="
grep NET_RX /proc/softirqs

echo "=== ps (dpdk procs) ==="
ps -eLo pid,lwp,psr,comm,args | grep -E "dpdk|l2fwd|testpmd" | head

echo "=== numastat ==="
numastat -m 2>/dev/null | head -10 || numastat | head -10

echo "=== dpdk-procinfo ==="
which dpdk-procinfo && dpdk-procinfo -- --proc-type=auto 2>&1 | head -50

echo "=== Saved to: $OUT ==="
```

### 6.2 实时监控模式

```bash
# ethtool 实时 (--period 参数, 部分驱动支持)
watch -n 1 'ethtool -S eth0 | grep -E "err|drop|miss"'

# dpdk-procinfo 实时
watch -n 1 'dpdk-proc-info -- --stats-period 1'

# ss 实时
watch -n 1 'ss -s'

# 综合: 同时跑 3 个窗口
tmux new-session \; \
    send-keys 'watch -n 1 "ethtool -S eth0 | tail -20"' C-m \; \
    split-window -v \; \
    send-keys 'watch -n 1 "ss -s"' C-m \; \
    split-window -h \; \
    send-keys 'watch -n 1 "dpdk-proc-info -- --stats-period 1"' C-m \;
```

### 6.3 性能计数器对比

| 工具                      | 计数器   | 精度  | 适合        |
| ------------------------- | -------- | ----- | ----------- |
| `ethtool -S`              | NIC 硬件 | 100ns | 物理层错误  |
| `ip -s link`              | 内核驱动 | 100ns | 内核态收包  |
| `ss -tin`                 | TCP 拥塞 | ms    | 协议层      |
| `dpdk-proc-info --xstats` | PMD 内部 | 100ns | DPDK 数据面 |
| `perf stat`               | CPU 硬件 | ns    | CPU 瓶颈    |
| `bpftrace`                | 任意函数 | ns    | 自定义追踪  |

---

## 7. 真实生产环境的 3 个组合

### 7.1 组合 1: 物理层 + DPDK 数据面

```bash
# 物理层 (绑卡前抓, 之后抓不到)
ethtool -S eth0 > /var/log/ethtool-before-bind.log

# 绑卡
dpdk-devbind --bind=vfio-pci 0000:3d:00.0

# DPDK 启动
./myapp -l 0-7

# 数据面
dpdk-proc-info -- --stats-period 5 | tee /var/log/dpdk-stats.log
```

### 7.2 组合 2: 内核协议栈 + DPDK 网关

```bash
# 假设是 "DPDK 网关 + 内核应用" 混合架构
# 1. DPDK 网关的连接 (只能看应用 CLI)
curl http://gateway:9090/metrics | grep nat_sessions

# 2. 内核应用的连接 (用 ss)
ss -tanp | grep my-kernel-app

# 3. 同时监控
watch 'echo "=== DPDK gateway ===" && curl -s gateway:9090/metrics | grep -E "connections|sessions" && echo "=== Kernel app ===" && ss -s'
```

### 7.3 组合 3: OVS-DPDK

```bash
# OVS 端
ovs-ofctl show br-dpdk
ovs-ofctl dump-ports br-dpdk
ovs-appctl dpif-netdev/pmd-stats-show

# VM 端
# 装好 testpmd 或自己的 DPDK 应用, 用 dpdk-proc-info 看

# 主机物理层
ethtool -S <PF 名字>  # PF 不归 DPDK, 仍可看
```

---

## 8. 工具能力速查卡 (实战版)

```
工具                    DPDK 拥有时     实时性     输出格式     远程
─────────────────────────────────────────────────────────────────
ethtool -S              ✗               ✓         text        脚本
ip -s link              ✗               ✓         text        脚本
ss -tanp                ✗ (协议栈无关)  ✓         text        脚本
conntrack -L            ✗               ✓         text        脚本
dpdk-proc-info          ✓               ✓         text        socket
dpdk-telemetry          ✓               ✓         JSON        HTTP
VPP show                ✓               ✓         text+json   socket
ovs-ofctl dump-ports    ✓               ✓         text        socket
ovs-appctl              ✓               ✓         text        socket
应用 CLI / metrics      ✓ (最详细)      ✓         json/prom   http
```

**最常用的 3 个组合**:

1. **生产监控**: 应用 Prometheus + Grafana (长期趋势)
2. **实时排障**: dpdk-proc-info + perf + bpftrace
3. **物理层**: 绑卡前 ethtool -S 抓快照 (之后抓不到)

---

## 9. 一句话总结

**网卡被 DPDK 拥有后, 99% 的"看不到"问题, 都可以用"绑卡前抓 ethtool 快照 + 跑起来后用 dpdk-proc-info + 应用 Telemetry"这个组合解决**。

`sim_dpdk_runaway.sh` 让你**没 DPDK 网卡也能直观看到工具能力边界**——这是 ch34 没法演示的部分, 用这个脚本**手把手走一遍, 概念立刻清晰**。

---

> 参考:
>
> - [[ch34-ethtool-comparison|ch34 工具全景对比]]
> - [[ch31-debugging-tools|ch31 调试工具]]
> - [[ch33-debug-techniques|ch33 调试技术]]
> - [ethtool 官方文档](https://www.kernel.org/pub/software/network/ethtool/)
> - [iproute2 文档](https://wiki.linuxfoundation.org/networking/iproute2)
> - [DPDK procinfo 用户指南](https://doc.dpdk.org/guides/tools/proc_info.html)
