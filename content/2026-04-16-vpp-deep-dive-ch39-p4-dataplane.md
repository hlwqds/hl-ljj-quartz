---
title: "VPP 深入探讨 ch39：P4 可编程数据面"
date: 2026-04-16 11:20:00
tags: [vpp, p4, programmable, strangler-fig, pipeline, p4runtime, tna,ida]
description: "深入解析 P4 可编程数据面与 VPP 集成：P4 架构、STRONGMAN/StrangerFig 模式、P4Runtime 控制、VPP P4 流水线、以及混合编程模型"
---

# VPP 深入探讨 ch39：P4 可编程数据面

> [!abstract] 核心要点
> P4 是数据平面编程语言，与 VPP 结合可实现更灵活的数据处理流水线。本章详解 P4 架构、P4Runtime 控制平面、以及 VPP+P4 的混合部署模式。

## 1. P4 架构概述

### 1.1 什么是 P4？

```
P4 (Programming Protocol-independent Packet Processors) 
= 数据平面编程语言

┌─────────────────────────────────────────────────────────────┐
│                    P4 核心特性                              │
│                                                              │
│  1. 协议无关                                                 │
│    - 不绑定特定协议                                          │
│    - 可自定义包解析                                          │
│                                                              │
│  2. 可编程匹配-动作                                          │
│    - 匹配字段可自定义                                        │
│    - 动作逻辑可编程                                          │
│                                                              │
│  3. 目标无关                                                 │
│    - 同一 P4 程序可编译到不同硬件                           │
│    - VPP, Barefoot Tofino, SmartNIC                         │
│                                                              │
│  4. 快速迭代                                                 │
│    - 修改协议只需重写 P4 代码                               │
│    - 无需等待硬件升级                                        │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 P4 vs VPP

|| 特性 | P4 | VPP |
|------|-----|-----|
| **编程模型** | 数据流图 | 图节点 |
| **目标** | 可编程交换机 | 通用数据平面 |
| **硬件支持** | Tofino, Tofino2, eBPF | x86, ARM, RISC-V |
| **协议栈** | 可自定义 | 内置完整 |
| **性能** | 硬件级 | 软件级 |
| **成熟度** | 较新 | 成熟 |

### 1.3 P4 + VPP 互补性

```
┌─────────────────────────────────────────────────────────────┐
│                    P4 + VPP 互补架构                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    P4 (可编程)                        │   │
│  │                                                       │   │
│  │  - 自定义协议解析                                     │   │
│  │  - 快速转发决策                                       │   │
│  │  - 报文修改                                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPP (丰富功能)                     │   │
│  │                                                       │   │
│  │  - NAT/Firewall/QoS                                 │   │
│  │  - Tunnel 封装                                       │   │
│  │  - HTTP 分析                                          │   │
│  │  - 连接跟踪                                           │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 2. P4 编程模型

### 2.1 P4 程序结构

```p4
// basic_router.p4

#include <core.p4>
#include <tna.p4>

// ===================== 头部定义 =====================
header ethernet_t {
    bit<48>  dst_addr;
    bit<48>  src_addr;
    bit<16>  ether_type;
}

header ipv4_t {
    bit<4>   version;
    bit<4>   ihl;
    bit<8>   diffserv;
    bit<16>  total_len;
    bit<16>  identification;
    bit<3>   flags;
    bit<13>  frag_offset;
    bit<8>   ttl;
    bit<8>   protocol;
    bit<16>  hdr_checksum;
    bit<32>  src_addr;
    bit<32>  dst_addr;
}

// ===================== 元数据 =====================
struct metadata_t {
    bit<32>  nexthop;
    bit<8>   l4_src_port;
    bit<8>   l4_dst_port;
}

// ===================== 解析器 =====================
parser MyParser(packet_in packet,
                out headers_t hdr,
                inout metadata_t meta,
                inout standard_metadata_t smeta)
{
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            0x0800:  parse_ipv4;
            default: accept;
        }
    }
    
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

// ===================== 匹配-动作表 =====================
control MyIngress(inout headers_t hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t smeta)
{
    action drop() {
        mark_to_drop(smeta);
    }
    
    action route_to_vpp() {
        // 重定向到 VPP 处理
        smeta.egress_spec = 255;  // 特殊端口
    }
    
    action ipv4_forward(bit<48> dst_addr, bit<48> src_addr, bit<8> port) {
        hdr.ethernet.src_addr = src_addr;
        hdr.ethernet.dst_addr = dst_addr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        smeta.egress_port = port;
    }
    
    table ipv4_lpm {
        key = {
            hdr.ipv4.dst_addr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            route_to_vpp;
        }
        default_action = drop;
        size = 65536;
    }
    
    apply {
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
    }
}

// ===================== 输出控制 =====================
control MyEgress(inout headers_t hdr,
                 inout metadata_t meta,
                 inout standard_metadata_t smeta)
{
    apply {
        // 输出处理
    }
}

// ===================== 依赖检查 =====================
control MyDeparser(packet_out packet,
                   in headers_t hdr)
{
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

// ===================== 完整流水线 =====================
Pipeline(MyParser(),
         MyIngress(),
         MyEgress(),
         MyDeparser()) pipe;

Switch(pipe) main();
```

### 2.2 P4 流水线阶段

```
┌─────────────────────────────────────────────────────────────┐
│                    P4 流水线阶段                            │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Parser                            │   │
│  │   packet ──► headers (提取协议头)                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Verify Checksum                   │   │
│  │   校验和验证                                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Ingress MA                        │   │
│  │   ┌──────────┐  ┌──────────┐  ┌──────────┐       │   │
│  │   │ Table 1  │  │ Table 2  │  │ Table 3  │       │   │
│  │   └──────────┘  └──────────┘  └──────────┘       │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Traffic Manager                   │   │
│  │   队列、调度、重标记                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Egress MA                         │   │
│  │   输出匹配-动作                                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Deparser                          │   │
│  │   headers ──► packet (序列化)                        │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 P4 表类型

```p4
// 匹配类型
key = {
    hdr.ipv4.src_addr: exact;    // 精确匹配
    hdr.ipv4.dst_addr: lpm;      // 最长前缀匹配
    hdr.tcp.src_port:   range;   // 范围匹配
    hdr.ipv4.protocol:  ternary; // 通配符匹配
}

// 表动作
actions = {
    drop;
    NoAction;
    ipv4_forward(bit<48>, bit<48>, bit<8>);
    send_to_vpp();  // 自定义动作
}

// 大小和默认动作
size = 65536;  // 表项数量
default_action = drop;
```

## 3. P4Runtime 控制平面

### 3.1 P4Runtime 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    P4Runtime 架构                           │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Control Plane (SDN Controller)          │   │
│  │   ┌──────────────────────────────────────────────┐  │   │
│  │   │         P4 Runtime gRPC Service               │  │   │
│  │   └──────────────────────────────────────────────┘  │   │
│  │                         │                            │   │
│  │                         ▼                            │   │
│  │   ┌──────────────────────────────────────────────┐  │   │
│  │   │              P4Info (Compiled P4)             │  │   │
│  │   │   - 表定义                                     │  │   │
│  │   │   - 动作定义                                   │  │   │
│  │   │   - 解析器图                                   │  │   │
│  │   └──────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    P4Runtime Agent                   │   │
│  │                                                       │   │
│  │   ┌─────────┐  ┌─────────┐  ┌─────────┐            │   │
│  │   │ Table   │  │  Digest │  │  FIFO   │            │   │
│  │   │ Write   │  │ Listener│  │         │            │   │
│  │   └─────────┘  └─────────┘  └─────────┘            │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    P4 Switch (VPP)                   │   │
│  │                                                       │   │
│  │   ┌─────────────────────────────────────────────┐    │   │
│  │   │              P4 Pipeline                     │    │   │
│  │   └─────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 P4Info 生成

```bash
# 1. 编译 P4 程序生成 P4Info
p4c-build --p4runtime \
    --p4runtime-file=p4runtime.txt \
    basic_router.p4

# 2. P4Info 内容示例
cat > p4runtime.txt << 'EOF'
# P4Info proto format
p4info {
  tables {
    id: 1
    name: "MyIngress.ipv4_lpm"
    match_fields {
      field_id: 1
      bitwidth: 32
      match_type: LPM
    }
    actions {
      id: 1
      name: "ipv4_forward"
      params {
        id: 1
        name: "dst_addr"
        bitwidth: 48
      }
    }
  }
}
EOF

# 3. 生成 Protobuf
protoc --python_out=. p4runtime.proto
```

### 3.3 P4Runtime gRPC 示例

```python
# p4runtime_client.py

import grpc
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc

class P4RuntimeClient:
    def __init__(self, addr='localhost:50051'):
        self.channel = grpc.insecure_channel(addr)
        self.stub = p4runtime_pb2_grpc.P4RuntimeStub(self.channel)
        
        # Master election (必须)
        self.election_id = (1, 0)
        
    def set_pipeline_config(self, p4info, bmv2_json):
        """设置流水线配置"""
        request = p4runtime_pb2.SetPipelineConfigRequest()
        request.config.p4info.CopyFrom(p4info)
        request.config.cookie = bmv2_json
        
        self.stub.SetPipelineConfig(request)
        
    def write_table_entry(self, table_name, match, action, priority=0):
        """写入表项"""
        update = p4runtime_pb2.Update()
        update.type = p4runtime_pb2.Update.INSERT
        
        # 设置匹配字段
        entry = update.entity.table_entry
        entry.table_id = self.get_table_id(table_name)
        entry.priority = priority
        
        for field, value, mask in match:
            match_field = entry.match.add()
            match_field.field_id = field
            match_field.lpm.value = value
            match_field.lpm.prefix_len = mask
            
        # 设置动作
        action_entry = entry.action.action
        action_entry.action_id = self.get_action_id(action['name'])
        for param in action['params']:
            p = action_entry.params.add()
            p.param_id = param['id']
            p.value = param['value']
            
        self.stub.Write(p4runtime_pb2.WriteRequest(
            updates=[update],
            election_id=self.election_id
        ))
        
    def read_table_entries(self, table_name):
        """读取表项"""
        request = p4runtime_pb2.ReadRequest()
        entity = request.entities.add().table_entry
        entity.table_id = self.get_table_id(table_name)
        
        for response in self.stub.Read(request):
            yield response.entities
```

## 4. VPP P4 集成模式

### 4.1 STRONGMAN 模式

```
┌─────────────────────────────────────────────────────────────┐
│                    STRONGMAN 模式                          │
│                                                              │
│  P4 作为 VPP 的"前端加速器":                                 │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    P4 (Tofino/NIC)                  │   │
│  │                                                       │   │
│  │  - 高速包解析                                        │   │
│  │  - 快速匹配                                         │   │
│  │  - 流分类                                           │   │
│  │  - 结果传递给 VPP                                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           │ P4 annotations                  │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPP                               │   │
│  │                                                       │   │
│  │  - 复杂 NAT/Firewall                                 │   │
│  │  - 连接跟踪                                          │   │
│  │  - DPI                                              │   │
│  │  - 隧道封装                                          │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 StrnglerFig 模式

```
┌─────────────────────────────────────────────────────────────┐
│                    StranglerFig 模式                        │
│                                                              │
│  逐步迁移:                                                   │
│                                                              │
│  Phase 1: P4 处理所有流量                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    P4                                 │   │
│  │   All Traffic                                        │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  Phase 2: 部分流量迁移到 VPP                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │     P4           │        VPP                        │   │
│  │   Fast Path      │     Complex Path                  │   │
│  │   (80%)          │     (20%)                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  Phase 3: VPP 处理所有流量 (P4 卸载)                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPP                               │   │
│  │   All Traffic (with P4 acceleration)                 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 VPP P4 Hybrid 配置

```bash
# VPP 启用 P4 插件
vpp# plugin load p4runtime

# 配置 P4 流水线
vpp# p4 set pipeline default

# 配置 P4 表到 VPP 节点映射
vpp# p4 map-table ipv4_lpm graph-node acl-next

# 配置重定向
vpp# p4 set-redirect VPP_HANDLER tap0

# 显示 P4 状态
vpp# show p4

# 示例输出:
# P4 Runtime:
#   Status: Active
#   Pipeline: default
#   Tables:
#     ipv4_lpm: 65536 entries
#     ipv4_fib: 16384 entries
#   Counters:
#     packets: 1000000000
#     bytes: 500000000000
```

## 5. P4 程序示例

### 5.1 VXLAN 卸载

```p4
// vxlan_offload.p4

#include <core.p4>
#include <tna.p4>

header vxlan_t {
    bit<8>  flags;
    bit<24> reserved;
    bit<8>  vni[3];        // 24-bit VNI
    bit<8>  reserved2;
}

header outer_ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  tos;
    bit<16> total_len;
    bit<16> identification;
    bit<3>  flags;
    bit<13> offset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> checksum;
    bit<32> src;
    bit<32> dst;
}

header outer_udp_t {
    bit<16> src_port;
    bit<16> dst_port;
    bit<16> length;
    bit<16> checksum;
}

struct metadata_t {
    bit<24> vni;
    bit<32> inner_src;
    bit<32> inner_dst;
}

// VXLAN 解封装动作
action vxlan_decap() {
    // 删除外层头部
    remove_header(hdr.vxlan);
    remove_header(hdr.outer_udp);
    remove_header(hdr.outer_ipv4);
    remove_header(hdr.outer_ethernet);
}

// VXLAN 封装动作
action vxlan_encap(bit<32> dst_ip, bit<24> vni) {
    // 添加 VXLAN 头
    hdr.vxlan.setValid();
    hdr.vxlan.flags = 0x08;
    hdr.vxlan.vni = vni;
    
    // 添加外层 UDP
    hdr.outer_udp.setValid();
    hdr.outer_udp.dst_port = 4789;  // Vxlan 端口
    
    // 添加外层 IP
    hdr.outer_ipv4.setValid();
    hdr.outer_ipv4.dst = dst_ip;
}

table vxlan_term {
    key = {
        hdr.outer_ipv4.dst: exact;
        hdr.outer_udp.dst_port: exact;
        hdr.vxlan.vni: exact;
    }
    actions = {
        vxlan_decap;
        send_to_vpp;  // 无法处理的交给 VPP
    }
    size = 16384;
}

apply {
    if (hdr.vxlan.isValid()) {
        vxlan_term.apply();
    }
}
```

### 5.2 负载均衡

```p4
// load_balancer.p4

// 负载均衡哈希
hash<bit<32>>(HashAlgorithm_t.CRC32) 
    ecmp_hash;

action select_ecmp(bit<16> ecmp_base, bit<16> ecmp_count) {
    // 计算 ECMP 桶
    bit<32> hash = ecmp_hash.get({
        hdr.ipv4.src_addr,
        hdr.ipv4.dst_addr,
        hdr.tcp.src_port,
        hdr.tcp.dst_port
    });
    
    bit<16> ecmp_index = (bit<16>)(hash % ecmp_count);
    bit<16> nexthop_index = ecmp_base + ecmp_index;
    
    // 设置下一跳
    meta.nexthop = nexthop_index;
}

table ecmp_select {
    key = {
        hdr.ipv4.dst_addr: lpm;
    }
    actions = {
        select_ecmp;
        drop;
    }
    size = 4096;
}
```

## 6. VPP P4 流水线映射

### 6.1 图节点映射

```
┌─────────────────────────────────────────────────────────────┐
│                    P4 → VPP 图映射                         │
│                                                              │
│  P4 Stage              VPP Node                            │
│  ──────────────────────────────────────────────────────────  │
│  Parser                device-input                         │
│  Ingress Match-Action  ip4-lookup, acl-plugin-l2, etc.    │
│  Egress Match-Action   output-feature                      │
│  Deparser              device-output                       │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    VPP Graph                          │   │
│  │                                                       │   │
│  │  device-input                                        │   │
│  │      │                                               │   │
│  │      ▼                                               │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │       P4_IN_acl (P4 处理结果)                  │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  │      │                                               │   │
│  │      ▼                                               │   │
│  │  ip4-lookup ──► ip4-rewrite ──► ip4-frag           │   │
│  │      │                                               │   │
│  │      ▼                                               │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │       P4_OUT_acl (输出处理)                    │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  │      │                                               │   │
│  │      ▼                                               │   │
│  │  device-output                                       │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 VPP 配置 P4

```bash
# 1. 加载 P4 插件
vpp# plugin load p4runtime.so

# 2. 连接 P4Runtime 控制器
vpp# p4runtime set election-id high:1 low:0
vpp# p4runtime connect localhost:50051

# 3. 配置 P4 表映射
vpp# p4runtime map-table ipv4_lpm node ip4-lookup
vpp# p4runtime map-action set_nhop node ip4-rewrite

# 4. 启用 P4 处理
vpp# set interface feature arc input TenGigabitEthernet0/0/0 p4-pipeline
vpp# set interface feature arc output TenGigabitEthernet0/0/0 p4-pipeline
```

## 7. 混合编程最佳实践

### 7.1 分割策略

```
P4 适合的场景：
- 高速路径处理
- 协议解析
- 流分类/哈希
- 首包处理

VPP 适合的场景：
- 复杂 NAT/Session
- DPI/分析
- 隧道封装/解封装
- 连接跟踪
- HTTP 处理
```

### 7.2 性能优化

```bash
# P4 + VPP 性能调优

# 1. HugePages (P4 需要)
echo 2048 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 2. CPU 亲和性
# P4 线程绑定特定核
taskset -c 0-3 ./p4_switch

# VPP workers
vpp# set cpu main-core 0
vpp# set cpu corelist-workers 4-7

# 3. 接口队列
ethtool -G eth0 rx 4096 tx 4096
ethtool -C eth0 rx-usecs 50
```

### 7.3 调试工具

```bash
# P4 调试
p4c-debug --p4file basic_router.p4

# VPP P4 调试
vpp# debug p4runtime on
vpp# show packet-trace

# Wireshark 分析
# 导入 P4 dissector
# https://github.com/p4lang/wireshark
```

## 8. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                    P4 + VPP 总结                            │
│                                                              │
│  P4 价值:                                                   │
│  - 协议无关编程                                             │
│  - 硬件级性能 (Tofino)                                      │
│  - 快速迭代                                                 │
│  - 可移植性                                                 │
│                                                              │
│  VPP 价值:                                                  │
│  - 成熟协议栈                                               │
│  - 丰富功能 (NAT, ACL, QoS)                                 │
│  - 硬件无关                                                 │
│  - 社区支持                                                 │
│                                                              │
│  集成模式:                                                  │
│  1. STRONGMAN: P4 前端 + VPP 后端                          │
│  2. StranglerFig: 渐进迁移                                 │
│  3. Hybrid: P4/VPP 混合流水线                              │
│                                                              │
│  控制平面:                                                  │
│  - P4Runtime gRPC                                          │
│  - 统一控制平面                                             │
│                                                              │
│  适用场景:                                                  │
│  - 定制协议 (非标准隧道)                                    │
│  - 卸载场景 (VXLAN, IPsec)                                 │
│  - 负载均衡 (ECMP)                                         │
│  - 安全策略 (细粒度 ACL)                                    │
└─────────────────────────────────────────────────────────────┘
```

---

## 参考资源

- [P4 Language Specification](https://p4.org/p4-spec/)
- [P4Runtime Specification](https://p4.org/p4runtime/)
- [Barefoot Networks Documentation](https:// barefoot.tech/)
- [VPP P4 Plugin](https://wiki.fd.io/view/VPP/P4_)
- [P4 Tutorial](https://github.com/p4lang/tutorials)
