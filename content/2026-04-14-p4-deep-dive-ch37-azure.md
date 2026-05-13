---
title: "P4 深度探索 (三十七)：Azure 网络可编程实践——Azure SONiC、P4 交换机、Dashboard 集成"
date: 2026-04-14
tags: [p4, series, azure, cloud, sonic, network, programmable, smartswitch, azure-networking]
description: "Azure P4 可编程网络深度解析——Azure SONiC 架构、P4 交换机设计、Dashboard 集成、Azure 虚拟网络、ENSP、Packet个工作流、P4 on Azure HCI"
---

> [!info] P4 深度探索系列 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述]]
>    ...
> 2. [[2026-04-14-p4-deep-dive-ch35-telemetry|第三十五章：P4 网络测量编程]]
> 3. [[2026-04-14-p4-deep-dive-ch36-aws|第三十六章：AWS 网络可编程实践]]
> 4. **第三十七章：Azure 网络可编程实践——Azure SONiC、P4 交换机、Dashboard 集成**

---

## 1. Azure 网络架构概述

Azure 的网络基础设施基于 **SONiC (Software for Open Networking in the Cloud)** 构建，这是一个开源的网络操作系统，广泛应用于云服务商的数据中心：

```
Azure 网络架构:
==============

  +-----------+     +------------+     +-----------+
  |  Azure   |     |  Azure     |     |  Azure    |
  |  VMs     |---->|  Virtual   |---->|  Physical |
  |          |     |  Network   |     |  Switch   |
  +-----------+     |  (vNet)    |     |  (SONiC)  |
                    +------------+     +-----------+
                         ^                   |
                         |                   |
                         v                   v
                   +------------+     +-----------+
                   |  Azure    |     |  Azure    |
                   |  Control  |     |  TOR      |
                   |  Plane    |     |  (P4)     |
                   +------------+     +-----------+
```

---

## 2. Azure SONiC

### 2.1 SONiC 架构

**SONiC** 是微软 Azure 主导的开源网络操作系统，采用微服务架构：

```
SONiC 系统架构:
===============

  +----------------------------------------------------------+
  |                    SONiC (Linux Container)                |
  |                                                          |
  |  +----------+  +----------+  +----------+  +----------+   |
  |  |  BGP     |  |  LACP    |  |  LLDP    |  |  ACL    |   |
  |  |  (Quagga)|  |  (swss)  |  |  (swss)  |  |  (swss) |   |
  |  +----------+  +----------+  +----------+  +----------+   |
  |                                                          |
  |  +----------+  +----------+  +----------+  +----------+   |
  |  |  VLAN    |  |  VXLAN   |  |  ECMP    |  |  STP     |   |
  |  |  (swss)  |  |  (swss)  |  |  (swss)  |  |  (swss)  |   |
  |  +----------+  +----------+  +----------+  +----------+   |
  |                                                          |
  |  +----------------------------------------------------+  |
  |  |              SWSS (Switch State Service)           |  |
  |  |  +----------+  +----------+  +----------+           |  |
  |  |  |  Ports  |  |  FDB    |  |  Routes  |           |  |
  |  |  |  DB     |  |  DB     |  |  DB      |           |  |
  |  |  +----------+  +----------+  +----------+           |  |
  |  +----------------------------------------------------+  |
  |                                                          |
  +----------------------------------------------------------+
                          |
                          v
  +----------------------------------------------------------+
  |              SAI (Switch Abstraction Interface)           |
  +----------------------------------------------------------+
                          |
                          v
  +----------------------------------------------------------+
  |         Broadcom/Tofino/Cavium (ASIC Driver)             |
  +----------------------------------------------------------+
```

### 2.2 SONiC 核心组件

| 组件             | 描述                                 | 技术栈     |
| ---------------- | ------------------------------------ | ---------- |
| **swss**         | Switch State Service，核心数据库服务 | C++, Redis |
| **syncd**        | ASIC 同步服务                        | C++        |
| **SAI**          | Switch Abstraction Interface         | C          |
| **BGP**          | 路由协议 (Quagga/FRR)                | C          |
| **LLDP**         | 链路发现                             | C          |
| **PortExpander** | 端口扩展                             | C          |

### 2.3 SONiC 架构 (Container 视图)

```
SONiC 容器架构:
===============

  +-----------+  +-----------+  +-----------+  +-----------+
  |  bgp      |  |  swss     |  |  snmp     |  |  telemetry|
  | (BGP/FRR) |  |(orchagent)|  |           |  | (gnmi)   |
  +-----------+  +-----------+  +-----------+  +-----------+
       |              |              |              |
       +--------------+--------------+--------------+
                           |
                    +------+------+
                    |  Redis DB   |
                    |  (Config/   |
                    |   State)    |
                    +------+------+
                           |
                    +------+------+
                    |   syncd     |
                    +------+------+
                           |
                    +------+------+
                    |    SAI      |
                    +------+------+
                           |
                    +------+------+
                    |   ASIC      |
                    +-------------+

  容器间通信:
  - 每个容器通过 Unix Socket 与 Redis 交互
  - syncd 通过 SAI 与 ASIC 通信
```

---

## 3. Azure P4 交换机

### 3.1 Azure P4 交换机架构

Azure 的数据中心使用 P4 可编程交换机，主要基于 Intel Tofino：

```
Azure P4 交换机架构:
====================

  +--------+     +-------------+     +-------------+
  |  ToR  |     |  Spine/     |     |  Gateway    |
  | (P4)  |---->|  Switch    |---->|  (P4)       |
  | Tofino|     |  (P4 Tofino)|     |            |
  +--------+     +-------------+     +-------------+
       |                                      |
       |                                      |
       v                                      v
  +--------+                              +--------+
  |  Pod   |                              |  WAN   |
  | Network|                              | Edge   |
  +--------+                              +--------+
```

### 3.2 P4 流水线设计

```c
// Azure P4 交换机流水线
// 基于 TNA (Tofino Native Architecture)

#include <core.p4>
#include <tna.p4>

// Azure 自定义 Header
header azure_metadata_t {
    bit<1>   is_mirror;
    bit<1>   is_tunnel;
    bit<6>   reserved;
    bit<32>  tunnel_id;
    bit<24>  vnet_id;
    bit<8>   sg_id;
}

// ACL 元数据
struct acl_metadata_t {
    bit<16>  acl_id;
    bit<8>   action;
    bit<1>   matched;
}

// Parser
parser AzureParser(
    packet_in pkt,
    out headers hdr,
    inout metadata_t meta,
    inout standard_metadata_t sm) {

    state start {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800:      parse_ipv4;
            0x86DD:      parse_ipv6;
            0x8100:     parse_vlan;
            0x8847:     parse_mpls;    // MPLS for WAN
            default:    accept;
        }
    }

    state parse_vlan {
        pkt.extract(hdr.vlan);
        transition select(hdr.vlan.ethertype) {
            0x0800:    parse_ipv4;
            0x86DD:    parse_ipv6;
            default:   accept;
        }
    }
}

// VNet ACL Table
table vnet_acl_table {
    key = {
        hdr.ipv4.srcAddr:    lpm;    // 支持 /32 到 /0
        hdr.ipv4.dstAddr:    lpm;
        hdr.tcp.srcPort:     range;  // 端口范围
        hdr.tcp.dstPort:     range;
        meta.sg_id:          exact;
    }
    actions = {
        permit;
        deny;
        log_and_permit;
    }
    default_action = deny;
}

// VXLAN 封装表
table vxlan_encap_table {
    key = {
        meta.tunnel_id: exact;
    }
    actions = {
        encap_vxlan;
        encap_geneve;
        no_encap;
    }
}

// ECMP 负载均衡表
table ecmp_table {
    key = {
        hdr.ipv4.srcAddr:   exact;
        hdr.ipv4.dstAddr:   exact;
        hdr.ipv4.protocol:  exact;
        hdr.tcp.srcPort:    exact;
        hdr.tcp.dstPort:    exact;
    }
    actions = {
        ecmp_fwd_to_group_1;
        ecmp_fwd_to_group_2;
        ecmp_fwd_to_group_3;
    }
}

// Egress Pipeline
control AzureEgress(
    inout headers hdr,
    inout metadata_t meta,
    inout standard_metadata_t sm) {

    // QoS 标记
    table qos_table {
        key = {
            meta.traffic_class: exact;
        }
        actions = {
            set_dscp_af11;
            set_dscp_af12;
            set_dscp_ef;
            set_dscp_cs6;
        }
    }

    // TTL 处理
    action decrement_ttl() {
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        if (hdr.ipv4.ttl == 0) {
            // 发送 ICMP Time Exceeded
            // 或丢弃包
        }
    }

    apply {
        qos_table.apply();
        decrement_ttl();
    }
}
```

---

## 4. Azure 虚拟网络 (vNet)

### 4.1 虚拟网络架构

Azure Virtual Network (vNet) 是 Azure 的软件定义网络：

```
Azure vNet 架构:
===============

  +-----------+     +-------------+     +-------------+
  |  Azure   |     |   vNet      |     |  Gateway    |
  |  VM      |---->|   Gateway   |---->|  Subnet     |
  |          |     |  (Software) |     |             |
  +-----------+     +-------------+     +-------------+
       |                  |                    |
       |                  v                    v
  +-----------+     +-------------+     +-------------+
  |  NIC     |     |  Routing    |     |  P4 Switch  |
  |  (vNIC)  |     |  (SDN)      |     |  (TOR)      |
  +-----------+     +-------------+     +-------------+

  vNet 组件:
  - Address Space: 10.0.0.0/8 (可自定义)
  - Subnets: 10.0.0.0/24, 10.0.1.0/24, ...
  - NSG: Network Security Group
  - UDR: User Defined Route
  - Peering: vNet 对等连接
```

### 4.2 NSG (Network Security Group)

NSG 使用 P4 ACL 实现：

```c
// NSG P4 实现
// 在 vNet Gateway 或 TOR 上实现

struct nsg_metadata_t {
    bit<32>  nsg_id;
    bit<32>  rule_priority;
    bit<8>   action;         // 0: Allow, 1: Deny
    bool     logged;
}

// NSG 规则匹配
table nsg_rules_table {
    key = {
        hdr.ipv4.srcAddr:    lpm;     // 支持 CIDR
        hdr.ipv4.dstAddr:    lpm;
        hdr.tcp.srcPort:     range;
        hdr.tcp.dstPort:     range;
        hdr.ipv4.protocol:   exact;
        meta.nsg_id:         exact;
    }
    actions = {
        nsg_permit;
        nsg_deny;
        nsg_log;
    }
}

// 默认规则: 拒绝所有
table nsg_default_table {
    key = {}
    actions = {
        nsg_deny_all;
    }
    default_action = nsg_deny_all();
}
```

---

## 5. Azure 交换机管理

### 5.1 REST API 管理

Azure 使用 REST API 管理 SONiC 交换机：

```python
# Azure SONiC REST API
# 管理交换机配置

import requests

# 获取交换机端口状态
def get_port_status(switch_ip, port_id):
    url = f"https://{switch_ip}/restconf/operational/sonic-port:sonic-port/PORT/PORT_LIST/{port_id}"
    headers = {
        "Accept": "application/yang-data+json"
    }
    response = requests.get(url, headers=headers, verify=False)
    return response.json()

# 配置 VLAN
def configure_vlan(switch_ip, vlan_id, ports):
    url = f"https://{switch_ip}/restconf/config/sonic-vlan:sonic-vlan/VLAN_MEMBER"
    payload = {
        "sonic-vlan:VLAN_MEMBER": {
            "VLAN_MEMBER_LIST": [
                {
                    "vlan_id": vlan_id,
                    "port": port,
                    "tagging_mode": "tagged"
                }
                for port in ports
            ]
        }
    }
    response = requests.put(url, json=payload)
    return response.status_code

# 获取接口统计
def get_interface_stats(switch_ip, interface_name):
    url = f"https://{switch_ip}/restconf/operational/sonic-interface:sonic-interface/INTERFACE/interface/{interface_name}"
    response = requests.get(url)
    return response.json()
```

### 5.2 gNMI 管理

SONiC 支持 gNMI (gRPC Network Management Interface)：

```protobuf
// gNMI 服务定义
service gNMI {
    // 获取数据
    rpc Get(GetRequest) returns (GetResponse);

    // 设置数据
    rpc Set(SetRequest) returns (SetResponse);

    // 订阅数据流
    rpc Subscribe(SubscribeRequest) returns (stream SubscribeResponse);
}

// 获取交换机端口状态 (gNMI)
GetRequest:
  prefix:
    origin: "openconfig"
    target: "interfaces"
  path:
    - name: "interface"
      key:
        name: "Ethernet0"
    - name: "state"
    - name: "counters"
```

```python
# 使用 gNMI 获取接口统计
from gnmi.proto import gnmi_pb2
import grpc

def get_interface_counters(target, interface):
    # 建立 gRPC 连接
    channel = grpc.secure_channel(target, credentials)
    stub = gnmi_pb2_grpc.gNMIStub(channel)

    # 构建 GetRequest
    path = gnmi_pb2.Path(
        origin="openconfig",
        target="interfaces",
        elem=[
            gnmi_pb2.PathElem(name="interface", key={"name": interface}),
            gnmi_pb2.PathElem(name="state"),
            gnmi_pb2.PathElem(name="counters"),
        ]
    )

    request = gnmi_pb2.GetRequest(prefix=path.prefix, path=[path])
    response = stub.Get(request)

    return response.notification[0].update[0].val
```

---

## 6. Azure Dashboard 集成

### 6.1 Azure Network Watcher

Azure Network Watcher 提供网络监控和诊断：

```
Network Watcher 架构:
====================

  +-----------+     +------------+     +-----------+
  |  Azure   |     |  Network   |     |  Azure    |
  |  VMs     |---->|  Watcher   |---->|  Storage  |
  |          |     |  Service   |     |  (Logs)   |
  +-----------+     +------------+     +-----------+
                           |
                           v
                    +------------+
                    |  Dashboard |
                    |  (Portal)  |
                    +------------+
```

### 6.2 Packet 工作流

Azure 支持 Packet 抓包，用于网络诊断：

```python
# Azure Network Watcher Packet 抓包
from azure.mgmt.network import NetworkManagementClient
from azure.identity import DefaultAzureCredential

def capture_packets(subscription_id, resource_group, vm_name):
    # 创建 Network Watcher 客户端
    credential = DefaultAzureCredential()
    client = NetworkManagementClient(credential, subscription_id)

    # 配置抓包参数
    packet_capture = {
        "name": f"pc-{vm_name}",
        "target": f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.Compute/virtualMachines/{vm_name}",
        "timeLimit": 300,  # 5 分钟
        "bytesToCapture": 1024,
        "filters": [
            {
                "protocol": "TCP",
                "localIPAddress": "10.0.0.1",
                "remoteIPAddress": "10.0.0.100",
            }
        ]
    }

    # 创建抓包会话
    result = client.network_watcher_packet_captures.begin_create(
        resource_group_name="network-watcher-rg",
        network_watcher_name="network-watcher",
        packet_capture_name=packet_capture["name"],
        parameters=packet_capture
    )

    return result.result()
```

### 6.3 流量日志

Azure NSG 流量日志使用 P4 进行流统计：

```c
// NSG 流量日志 P4 实现
// 使用 Direct Counter 统计每个规则匹配的流量

direct_counter nsg_flow_counter) with {
    table nsg_rules_table;
}

// NSG 规则表 (带统计)
table nsg_rules_table {
    key = {
        hdr.ipv4.srcAddr:    lpm;
        hdr.ipv4.dstAddr:    lpm;
        hdr.tcp.srcPort:     range;
        hdr.tcp.dstPort:     range;
        meta.nsg_id:         exact;
    }
    actions = {
        nsg_permit;
        nsg_deny;
    }
    counters = {
        nsg_flow_counter: direct_counter;
    }
}

// 导出流量日志
action export_flow_log(bit<32> collector_ip) {
    // 构建 NetFlow/IPFIX 导出包
    // 发送到日志收集器
}
```

---

## 7. Azure HCI 与 P4

### 7.1 Azure Stack HCI

Azure Stack HCI 是混合云解决方案，使用 P4 实现网络虚拟化：

```
Azure Stack HCI 网络:
====================

  +-----------+     +------------+     +-----------+
  |  HCI     |     |  Hyper-V   |     |  Physical |
  |  Node    |---->|  Switch    |---->|  Switch   |
  |          |     | (OVS-DPDK) |     |  (P4)     |
  +-----------+     +------------+     +-----------+
       |                  |                   |
       |                  v                   v
  +-----------+     +------------+     +-----------+
  |  vNIC    |     |  OVS       |     |  Azure    |
  |          |     |  (OVS-DPDK)|     |  Arc      |
  +-----------+     +------------+     +-----------+
```

### 7.2 OVS-DPDK 与 P4 协同

Azure Stack HCI 使用 OVS-DPDK 进行虚拟交换，结合 P4 硬件卸载：

```c
// OVS-DPDK P4 卸载架构
// P4 程序处理数据包分类和封装
// DPDK 处理高速数据路径

// P4 分 类 + OVS 转发
pipeline P4Classification {
    // 1. P4 解析和分类 (硬件)
    parse -> classify -> encap

    // 2. OVS 处理 (软件，DPDK)
    classify -> flow_table -> action
}
```

---

## 8. Azure 网络最佳实践

### 8.1 网络设计模式

```bash
# Azure vNet 设计最佳实践
# 使用 Hub-Spoke 模型

# Hub vNet (中心)
10.0.0.0/16  # Hub vNet
  - 10.0.1.0/24  # Gateway Subnet
  - 10.0.2.0/24  # Shared Services
  - 10.0.3.0/24  # Management

# Spoke vNet 1 ( spoke)
10.1.0.0/16  # Spoke 1 vNet
  - 10.1.1.0/24  # Workloads

# Spoke vNet 2
10.2.0.0/16  # Spoke 2 vNet
  - 10.2.1.0/24  # Workloads
```

### 8.2 NSG 规则设计

| 优先级 | 规则        | 源         | 目的        | 端口 | 动作  |
| ------ | ----------- | ---------- | ----------- | ---- | ----- |
| 100    | Allow-HTTPS | Any        | Web Subnet  | 443  | Allow |
| 200    | Allow-HTTP  | Any        | Web Subnet  | 80   | Allow |
| 300    | Allow-SQL   | Web Subnet | Data Subnet | 1433 | Allow |
| 4000   | Deny-All    | Any        | Any         | Any  | Deny  |

### 8.3 性能优化

```bash
# Azure VM 网络性能优化

# 启用加速网络 (Accelerated Networking)
# 只支持特定 VM 大小
az vm create \
    --resource-group myResourceGroup \
    --name myVM \
    --image UbuntuLTS \
    --size Standard_DS3_v2 \
    --enable-accelerated-networking

# 查看网络接口信息
az network nic show \
    --resource-group myResourceGroup \
    --name myNic

# 验证 RSS (Receive Side Scaling)
ethtool -l eth0
```

---

## 9. 总结

Azure 的 P4 可编程网络实践：

| 组件                | 技术栈              | P4 用途     |
| ------------------- | ------------------- | ----------- |
| **SONiC**           | Linux + Redis + SAI | 开源网络 OS |
| **TOR Switch**      | Intel Tofino P4     | 流水线处理  |
| **vNet Gateway**    | Software SDN        | 虚拟网络    |
| **NSG**             | P4 ACL              | 安全规则    |
| **Network Watcher** | gNMI/REST           | 监控诊断    |

Azure 通过 SONiC 和 P4 的结合，实现了开放、灵活、高性能的网络基础设施。
