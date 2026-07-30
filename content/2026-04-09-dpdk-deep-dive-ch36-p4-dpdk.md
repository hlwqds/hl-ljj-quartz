---
title: "DPDK 深度探索 ch36：P4 与 DPDK SWX——从协议描述到可运行流水线"
date: 2026-04-09 16:10:00
tags: [dpdk, p4, p4c, swx, pna, psa, bmv2, p4runtime, ipdk, programmable-data-plane]
description: "解析 P4 的语言、架构与控制面边界，并说明 p4c-dpdk 如何把 PSA/PNA 程序编译为 DPDK SWX spec，以及 BMv2、P4Runtime、IPDK/infrap4d、性能测试与工程限制"
---

# DPDK 深度探索 ch36：P4 与 DPDK SWX——从协议描述到可运行流水线

> [!info] 资料基线
> 本文按 **2026-06-09** 的 P4C DPDK backend 与 DPDK 26.03 文档核对。
> P4C、PNA、IPDK 和 P4-DPDK target 仍在演进，部署时必须固定仓库 SHA 与版本组合。

> [!abstract] 核心结论
> P4 的价值不是“用另一种语言重写 DPDK C 程序”，而是把数据面拆成三个可验证部分：
>
> 1. **P4 程序**描述 parser、match-action、状态对象和 deparser；
> 2. **架构模型**定义端口、metadata、extern、traffic manager 等目标契约；
> 3. **控制面**在运行时装载 pipeline、写表项、读计数并处理异常。
>
> `p4c-dpdk` 将 PSA/PNA P4 程序编译成 DPDK SWX 使用的 **spec 文件**。
> 它不是把 P4 编译成 `testpmd` 插件，也不是生成一个可以直接执行的 JSON 数据面。

> [!info] 关联章节
>
> - [[2026-04-09-dpdk-deep-dive-ch1-architecture-overview|DPDK 架构总览]]
> - [[2026-04-09-dpdk-deep-dive-ch10-flow-classification|流分类]]
> - [[2026-04-09-dpdk-deep-dive-ch35-virtualization-future|DPU、SmartNIC 与未来虚拟化]]
> - [[2026-04-09-dpdk-deep-dive-ch37-smartnic|SmartNIC]]
> - [[2026-04-09-dpdk-deep-dive-ch38-dpdk-ebpf|DPDK 与 eBPF]]

---

## 1. P4 解决的不是“怎么收包”，而是“包应该经历什么”

传统 DPDK 应用把协议解析、查表和动作直接写进 C：

```text
rte_eth_rx_burst
  → parse Ethernet/VLAN/IP
  → lookup ACL/FIB/flow
  → rewrite header
  → rte_eth_tx_burst
```

这种方式性能与自由度高，但协议行为、数据结构、执行调度和设备细节紧密耦合。
每增加一种 tunnel、metadata 或表动作，都可能修改主循环、布局和控制接口。

P4 把数据面表达为：

```text
Parser
  → Match-Action Pipeline
  → Deparser
```

它描述：

- 从 packet 中提取哪些 header；
- 用哪些字段作为 table key；
- table 命中后允许执行哪些 action；
- header 和 metadata 如何被修改；
- 最终按什么顺序重新发出 header。

它通常不描述：

- lcore 怎样绑定；
- mbuf pool 多大；
- RX/TX burst 是多少；
- cache 如何预取；
- NIC queue 如何配置；
- 控制器何时下发路由。

这些属于 target runtime、应用框架和控制面。

### 1.1 P4 是受约束的数据面语言

P4 不是通用语言，也不是“网络版 C”：

- 没有任意动态内存分配；
- 循环和递归受到严格限制；
- table、register、counter 等资源由 target 映射；
- 同一 P4 程序在不同 target 上的容量与支持能力不同；
- 语言能表达某个 extern，不代表目标实现了该 extern。

这种约束是刻意的。它让编译器能够把程序映射到 ASIC 流水线、FPGA、软件交换机
或 DPDK SWX，而不是依赖某一颗 CPU 的任意控制流。

---

## 2. 语言、架构与 target 必须分开理解

### 2.1 三层关系

```text
P4_16 language
  header / parser / control / table / action / extern
                    │
                    ▼
Architecture model
  v1model / PSA / PNA / vendor architecture
  定义标准 metadata、pipeline block 和 extern 契约
                    │
                    ▼
Target
  BMv2 / DPDK SWX / ASIC / SmartNIC / FPGA
  决定真实资源、能力、性能与限制
```

仅说“这个程序是 P4_16”还不够。编译命令和运行目标必须知道它采用哪个 architecture。

### 2.2 v1model、PSA 与 PNA

| 架构    | 主要定位                        | 本文中的用途                      |
| ------- | ------------------------------- | --------------------------------- |
| v1model | BMv2 `simple_switch` 的经典架构 | 教学、原型和调试                  |
| PSA     | 可移植交换机架构                | `p4c-dpdk` 支持的输入架构之一     |
| PNA     | 可移植 NIC 架构                 | `p4c-dpdk` 与 IPDK 的重要输入架构 |

原文使用 v1model 程序介绍 P4，然后直接声称可以编译到 DPDK，这是错误的迁移假设。
当前 P4C DPDK backend 官方支持的是 **PSA/PNA**，不是把任意 v1model 程序原样
交给 `p4c-dpdk`。

### 2.3 “可移植”不是“一次编写，到处无差异运行”

P4 的可移植性主要指语言与架构级接口。目标之间仍可能存在：

- match kind 与 key 宽度限制；
- table 容量和内存类型差异；
- parser 深度与 header stack 限制；
- extern 缺失；
- egress、clone、recirculate 和 traffic manager 差异；
- register 并发语义差异；
- checksum、hash 和 timestamp 实现差异。

因此工程上的可移植流程是：

```text
portable source
  + target capability profile
  + target-specific validation/tests
  + optional extern adapter
```

---

## 3. P4 程序的核心结构

下面用 BMv2 的 v1model 展示语言概念。它适合教学，但不应直接当作 DPDK target 输入。

### 3.1 Headers 与 metadata

```p4
#include <core.p4>
#include <v1model.p4>

header ethernet_t {
    bit<48> dst_addr;
    bit<48> src_addr;
    bit<16> ether_type;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> total_len;
    bit<16> identification;
    bit<3>  flags;
    bit<13> frag_offset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> checksum;
    bit<32> src_addr;
    bit<32> dst_addr;
}

struct headers_t {
    ethernet_t ethernet;
    ipv4_t ipv4;
}

struct metadata_t {
    bit<32> next_hop;
}
```

Header 有 valid/invalid 状态，metadata 只在 pipeline 内部存在，默认不会被发送到线上。

### 3.2 Parser 是有限状态机

```p4
parser MyParser(
    packet_in packet,
    out headers_t hdr,
    inout metadata_t meta,
    inout standard_metadata_t standard_metadata)
{
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}
```

Parser 负责识别包格式，而不是完成路由或 ACL。未知协议可以进入 `accept`，
由后续 control 决定 bypass、punt 或 drop。

### 3.3 Table 将 key、action 与 control plane 连接起来

```p4
control MyIngress(
    inout headers_t hdr,
    inout metadata_t meta,
    inout standard_metadata_t standard_metadata)
{
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action set_nhop(bit<48> dst_mac, bit<9> port) {
        hdr.ethernet.dst_addr = dst_mac;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        standard_metadata.egress_spec = port;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dst_addr: lpm;
        }
        actions = {
            set_nhop;
            drop;
            NoAction;
        }
        size = 16384;
        default_action = drop();
    }

    apply {
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
    }
}
```

P4 source 声明“这张表允许什么”，但具体前缀、MAC 和端口通常由控制面运行时写入。

### 3.4 Deparser 决定发包布局

```p4
control MyDeparser(packet_out packet, in headers_t hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}
```

`emit` 无效 header 不会输出。封装/解封装通常通过 `setValid()`、`setInvalid()`
和 emit 顺序完成。

### 3.5 Stateful extern 需要谨慎

Counter、meter、register 让数据面持有状态，但会引入：

- 多包并发更新；
- 原子性与可见性；
- 热点 cache line；
- target 资源限制；
- warm restart 和状态恢复；
- 控制面读取与数据面写入竞争。

P4 程序能够声明 register，不意味着软件 target 上可以无限扩展，也不意味着硬件
target 会提供与 CPU 顺序执行相同的语义。

---

## 4. BMv2：行为验证工具，不是 DPDK 性能基线

BMv2 是 P4 的软件参考交换机。它解释执行 P4C 生成的 JSON，适合：

- 验证 parser、table 和 action 行为；
- 使用 CLI 或 P4Runtime 调试控制面；
- 配合 Mininet/PTF 做功能测试；
- 观察 table hit/miss 和 parser transition。

它不追求生产级吞吐，不能用其性能推断 DPDK SWX 或 ASIC 性能。

### 4.1 正确的 BMv2 编译与运行

对于 v1model 程序：

```bash
p4c --target bmv2 --arch v1model --std p4-16 \
  --p4runtime-files router.p4info.txt \
  --p4runtime-format text \
  -o router.json \
  router.p4

sudo simple_switch \
  -i 0@veth0 \
  -i 1@veth1 \
  --log-console \
  router.json
```

原文中的 `--no-p4 topo.json` 不会装载指定 P4 pipeline；`--no-p4` 表示启动时
不加载 P4 配置，通常用于稍后通过 P4Runtime 设置 forwarding pipeline。

### 4.2 Thrift CLI 与 P4Runtime 不应混为一谈

经典 `simple_switch` 可以使用 Thrift CLI：

```bash
simple_switch_CLI --thrift-port 9090
```

```text
table_add MyIngress.ipv4_lpm MyIngress.set_nhop \
  10.0.0.0/24 => 00:11:22:33:44:55 1
```

删除条目通常使用 entry handle，而不是再次传 match key：

```text
table_delete MyIngress.ipv4_lpm <entry_handle>
```

如果目标是验证标准 P4Runtime 控制器，应使用 `simple_switch_grpc`、P4Info 与
P4Runtime client，而不是把 Thrift CLI 当成 P4Runtime。

---

## 5. P4-DPDK 的真实编译链

### 5.1 从 P4 到 SWX spec

DPDK 20.11 引入 Software Switch（SWX）pipeline。P4C 的 DPDK backend 将 PSA/PNA
程序降低为 SWX 指令和对象定义：

```text
P4_16 source (PSA/PNA)
          │
          ▼
      p4c-dpdk
          │
          ├─ pipeline spec
          ├─ P4Info / runtime metadata（按选项与集成方式）
          └─ target context artifacts（完整 target 栈可能需要）
          │
          ▼
DPDK SWX pipeline / p4-dpdk-target
```

最小编译示例：

```bash
p4c-dpdk --arch psa vxlan.p4 -o vxlan.spec
```

输出是文本形式的 SWX **spec**，不是 `myprogram.dpdk.json`。

### 5.2 SWX 在运行时做什么

SWX pipeline 动态定义：

- input/output port；
- header 与 metadata structure；
- parser/deparser instruction；
- action；
- exact/LPM/ternary table；
- extern object/function；
- pipeline control flow。

初始化时，spec 被验证并转换为运行时指令。数据面执行时，SWX 通过多 packet
in-flight 和内存访问前的调度/预取来隐藏部分 lookup 延迟。

### 5.3 它不是 `testpmd`

`testpmd` 是 ethdev 测试工具，不能直接加载 P4C DPDK spec。
上游 DPDK 中应通过 SWX/Packet Framework 相关应用或自行集成 `rte_swx_pipeline`
运行 pipeline；完整 P4-DPDK 软件栈则通常使用 `p4-dpdk-target`。

把 P4 程序放进 DPDK 数据面至少还需要：

```text
port configuration
mbuf pools
RX/TX queues
pipeline instance
spec loading
table population
lcore assignment
telemetry and lifecycle management
```

编译成功只证明程序能被 target backend 接受，不代表数据面已经连上 NIC。

---

## 6. 上游 SWX 与 IPDK 完整栈的区别

### 6.1 轻量路径：应用直接管理 SWX

适合实验、嵌入式数据面或已有自研控制面的场景：

```text
custom controller / CLI
          │
          ▼
DPDK application
  ├─ ethdev/EAL
  ├─ SWX pipeline
  ├─ table transaction
  └─ lcore/port management
```

优点是依赖少、边界清晰；缺点是端口、表管理、持久化和远程 API 都要自己实现。

### 6.2 完整路径：p4-dpdk-target + infrap4d

IPDK 体系增加 target driver 与控制平面：

```text
P4Runtime / gNMI clients
            │ gRPC
            ▼
        infrap4d
  Stratum / TDI / SAI / target driver
            │
            ▼
      p4-dpdk-target
            │
            ▼
       DPDK SWX pipeline
```

其中：

- P4Runtime 管理 P4 定义的 table、action、counter 等对象；
- TDI 为不同 target 提供统一的表驱动接口；
- target driver 加载 spec、context 和 runtime metadata；
- gNMI/OpenConfig 可管理非 P4 或固定功能对象；
- `infrap4d` 负责远程服务、仲裁、配置与 target 协调。

这是一套独立的软件栈，不等同于“安装 DPDK 后自动拥有 P4Runtime”。

### 6.3 版本必须成套固定

`p4c`、P4 architecture include、DPDK、p4-dpdk-target、TDI 和 infrap4d
之间存在 artifact schema 与 API 依赖。可靠做法是：

- 使用目标发行版推荐的 tag/SHA；
- 记录 P4C、DPDK 与 target driver commit；
- 不把系统中的最新 `p4c` 随意替换进旧 IPDK release；
- 在 CI 中重新编译 P4 并运行 PTF；
- 保存编译 artifacts 的版本和 hash。

---

## 7. 当前 p4c-dpdk 的重要限制

截至本文核对时，官方 DPDK backend 文档列出的限制包括：

- 不支持 subparser 和 parser value set；
- egress parser/control/deparser 尚未作为正常完整路径实现，重点应放在 ingress；
- 没有完整 packet replication engine / traffic manager；
- Packet Digest、Random、Hash、Timestamp 等 PSA extern 尚不支持；
- Direct Meter、Direct Counter、Basic Checksum 尚不支持；
- clone、recirculate、resubmit 尚不支持；
- structure field 需要按 target 约束对齐，文档仍列有 8-bit 倍数与最大 64-bit 限制；
- meter/counter 的 DPDK target 方法可能需要显式 packet length 参数。

原文的“Direct Counter、Direct Meter、Stateful Register 全部支持”表格过于乐观。
真实支持矩阵必须以当前 backend 文档、编译结果和 target 测试为准。

### 7.1 Extern 是扩展能力，也是可移植性边界

SWX 支持调用 extern object/function，用于：

- 复杂 hash 或 checksum；
- crypto；
- 自定义 statistics；
- 无法高效表示为普通 match-action 的算法。

但 extern 会把程序绑定到目标实现。设计时应区分：

```text
portable core:
  parser + tables + common actions

target extension:
  extern + host service + hardware-specific metadata
```

这样可以在 BMv2 中为 extern 提供 mock，在 DPDK 中使用真实插件，并对差异做显式测试。

---

## 8. 控制面不是“往表里塞几条命令”

### 8.1 P4Info 描述控制面可见对象

P4Runtime controller 不应硬编码编译器内部名称和 ID。P4Info 描述：

- table；
- match field；
- action 与参数；
- counter/meter/register；
- controller packet metadata；
- P4 entity ID。

controller 需要同时知道：

```text
P4Info
  定义“有哪些对象、字段和 ID”

device config / target artifact
  定义“目标怎样执行 pipeline”
```

### 8.2 Pipeline 装载与表更新是不同生命周期

```text
pipeline deployment:
  compile → validate → load device config → reconcile state

runtime programming:
  add/modify/delete table entries → read counters → handle errors
```

替换 pipeline 可能改变 P4Info ID、key layout、action 参数与状态对象，不能当作普通表项更新。

### 8.3 一致性与原子更新

路由、ACL、NAT 等功能常需同时更新多张表。逐条更新可能暴露中间状态：

```text
new nexthop installed
route not installed yet
        或
route points to nexthop
new nexthop not installed yet
```

DPDK SWX 提供 transaction-oriented table update 思路，使一批变更在 commit 前后可见，
而不是让数据包观察到半完成状态。控制面还要处理：

- write error 与部分失败；
- duplicate/modify/delete 语义；
- mastership；
- warm restart reconciliation；
- counter read consistency；
- pipeline reload 时状态迁移。

---

## 9. P4 与 eBPF、rte_flow、手写 DPDK 的关系

| 方案          | 主要优势                                             | 主要边界                         |
| ------------- | ---------------------------------------------------- | -------------------------------- |
| P4            | 协议无关 parser 与 match-action 描述，多 target 架构 | 受 target 模型和资源约束         |
| eBPF/XDP      | Linux 生命周期、观测和策略集成好                     | 受 hook、verifier 与内核环境约束 |
| `rte_flow`    | 直接表达 NIC flow steering/offload                   | 不是完整 parser/control language |
| 手写 DPDK C   | 最大自由度，可精细控制 CPU 和内存                    | 可移植性与维护成本较高           |
| DPDK SWX spec | 动态软件流水线，不必一定从 P4 生成                   | 仍需 runtime 与控制面            |

这些技术可以组合：

```text
P4/SWX:
  通用软件 match-action pipeline

rte_flow:
  把已知热点流或入口分类卸载到 NIC

eBPF:
  Linux 控制、可观测性与慢路径

custom DPDK C/extern:
  复杂算法和目标专用加速
```

关键不是选择“唯一正确技术”，而是明确每一层的状态所有权和 fallback。

---

## 10. 一个更可靠的 L3 Pipeline 设计

### 10.1 不要把所有逻辑塞进一张表

推荐拆分：

```text
parser
  → validate Ethernet/IPv4
  → ingress ACL
  → IPv4 LPM
  → nexthop resolution
  → rewrite
  → output selection
  → deparser
```

对应控制面对象：

| 表      | key                | value/action              |
| ------- | ------------------ | ------------------------- |
| ACL     | src/dst/proto/port | permit/drop/punt          |
| FIB     | destination prefix | nexthop ID                |
| nexthop | nexthop ID         | dst MAC、source MAC、port |

这样路由前缀变化不必复制 MAC/port 参数到每条 FIB entry，也更容易做原子更新。

### 10.2 TTL 与异常路径

一个可工作的路由 pipeline 还应处理：

- 非 IPv4 包；
- IPv4 header 长度与 checksum；
- TTL 为 0/1；
- fragmentation；
- unresolved neighbor；
- MTU exceed；
- multicast/broadcast；
- control-plane punt；
- default drop 与 drop reason。

“LPM 命中后减 TTL 并发端口”只能算最小演示，不能称为完整路由器。

### 10.3 ECMP 需要稳定 hash 与成员更新策略

ECMP 不只是：

```text
hash(5-tuple) % member_count
```

直接取模在成员变化时会重映射大量 flow。生产实现还要考虑：

- symmetric hash；
- fragment 缺少 L4 port；
- tunnel inner/outer tuple；
- resilient hashing；
- member health；
- table update 原子性；
- target 是否支持所需 hash extern。

而当前 p4c-dpdk 文档把 PSA Hash extern 列为不支持，因此不能直接照搬一个调用
`hash()` 的 v1model ECMP 示例并宣称它能编译到 DPDK。

---

## 11. 测试方法：语义、控制面、性能分三层

### 11.1 编译器与静态检查

```bash
# BMv2/v1model
p4c --target bmv2 --arch v1model --std p4-16 router.p4

# DPDK/PSA
p4c-dpdk --arch psa router_psa.p4 -o router.spec
```

CI 应将 warning 视为需要审查的结果，并保存 spec/P4Info/context artifact。

### 11.2 Packet-level 功能测试

使用 PTF 或等价框架覆盖：

- table hit/miss；
- default action；
- TTL、checksum 与 header rewrite；
- VLAN/tunnel parser 分支；
- malformed/truncated packet；
- boundary prefix；
- priority 与 ternary overlap；
- control-plane update 前后行为；
- unsupported protocol 的 drop/punt。

测试应验证完整输出包，而不只是 egress port。

### 11.3 差分测试

同一逻辑如果有 BMv2 与 DPDK 两个实现，可以使用相同 packet vectors：

```text
input packet + table state
          │
     ┌────┴────┐
     ▼         ▼
   BMv2      DPDK SWX
     │         │
     └────┬────┘
          ▼
compare output packet / port / counter / drop reason
```

差异可能来自 architecture metadata、extern 和 target 限制，应作为明确兼容性问题记录。

### 11.4 性能测试必须包含控制面规模

至少记录：

- 包长与流量模型；
- table 类型与条目数量；
- hit/miss 比例；
- pipeline stage 数与每包 lookup 数；
- burst、lcore、NUMA 和端口；
- 规则更新速率与 commit 延迟；
- 吞吐、尾延迟、CPU cycles 和 cache miss；
- counter/register 读取对数据面的影响。

单条 exact-match 表的 Mpps 不能代表多级 ACL + LPM + stateful extern pipeline。

---

## 12. 调试与可观测性

### 12.1 BMv2

- `--log-console` 查看运行日志；
- nanolog 观察 parser transition 与 table hit/miss；
- Thrift CLI 查看表项；
- `simple_switch_grpc` + P4Runtime client 验证标准控制面；
- packet capture 验证 deparser 输出。

### 12.2 DPDK SWX

需要同时观察：

```text
port RX/TX/drop
pipeline input/output/drop
table hit/miss
action counters
control-plane transaction result
rule population latency
lcore utilization
mempool/ring pressure
```

给 drop action 增加 reason/counter 比只有总 drop 数更有价值。否则 parser reject、
ACL deny、route miss 和 output congestion 会混成一个数字。

### 12.3 编译器接受不代表运行目标支持

排查顺序：

1. 确认 P4 architecture 与编译参数一致；
2. 查看 `p4c-dpdk` warning/error；
3. 检查生成 spec 是否包含预期 table/action；
4. 检查 runtime 是否成功加载全部 artifact；
5. 检查 port 与 pipeline 是否连接；
6. 检查 table entry 是否写入目标 device；
7. 用最小 packet vector 验证 parser 和 default action；
8. 最后再做性能测试。

---

## 13. 什么时候适合选择 P4-DPDK

适合：

- 协议和 match-action 逻辑经常变化；
- 需要相同控制模型覆盖软件与可编程硬件；
- 团队愿意维护 P4C/target/control-plane 工具链；
- pipeline 主要由可预测的 parser、table 与 action 构成；
- 需要运行时表更新而不重新编译整个 DPDK 应用。

不一定适合：

- 逻辑以复杂循环、动态内存或大型状态机为主；
- 主要需求只是固定 L2/L3 forwarding；
- 依赖大量当前 DPDK backend 不支持的 extern；
- 团队没有 P4Runtime/TDI 运维能力；
- 极致性能要求允许用手写 C 换取较低可移植性。

一个务实的采用路径：

```text
1. BMv2 验证协议语义
2. PTF 固化 packet contract
3. 将程序改写为 PSA/PNA
4. p4c-dpdk 编译并清理 unsupported feature
5. SWX 功能与差分测试
6. 接入最小控制面
7. 扩展到真实 NIC、规模表项和故障测试
```

---

## 14. 总结

理解 P4-DPDK，需要牢记四个边界：

```text
P4 language != architecture
architecture != target capability
compiler output != running dataplane
running dataplane != complete network product
```

P4 提供的是数据面行为的结构化表达；DPDK SWX 提供的是 CPU 上的可编程流水线执行引擎；
P4C DPDK backend 在两者之间生成 spec；P4Runtime/TDI/infrap4d 等组件负责把运行时控制
连接起来。

因此，更准确的说法不是“P4 自动生成高性能 DPDK 程序”，而是：

> **P4 把协议与 match-action 意图编译成 SWX 可执行流水线，性能、端口、状态和控制面
> 仍由具体 DPDK target 系统负责。**

---

## 参考资料

### P4

- [P4 specifications](https://p4.org/specs/)
- [P4_16 language specification](https://p4.org/p4-spec/docs/P4-16-v1.2.5.html)
- [Portable NIC Architecture](https://p4.org/p4-spec/docs/PNA-v0.7.pdf)
- [P4Runtime specification](https://p4.org/p4-spec/p4runtime/main/P4Runtime-Spec.html)
- [P4C compiler](https://github.com/p4lang/p4c)
- [P4C DPDK backend](https://p4lang.github.io/p4c/dpdk_backend.html)
- [BMv2 behavioral model](https://github.com/p4lang/behavioral-model)

### DPDK 与 IPDK

- [DPDK Packet Framework and SWX](https://doc.dpdk.org/guides-26.03/prog_guide/packet_framework.html)
- [P4 DPDK target](https://github.com/p4lang/p4-dpdk-target)
- [IPDK P4 Control Plane overview](https://ipdk.io/p4cp-userguide/overview/overview.html)
- [IPDK DPDK setup guide](https://ipdk.io/p4cp-userguide/guides/setup/dpdk-setup-guide.html)
