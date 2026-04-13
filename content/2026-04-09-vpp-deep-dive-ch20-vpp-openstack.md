---
title: "VPP 深入探讨 ch20：VPP + OpenStack"
date: 2026-04-10 04:00:00
tags: [vpp, openstack, neutron, ml2, sriov, networking, vm, ml2-driver]
description: "深入解析 VPP 与 OpenStack 集成：ML2 驱动、Neutron 集成、SRIOV VF 管理、router 与 security group"
---

# VPP 深入探讨 ch20：VPP + OpenStack

> [!abstract] 核心要点
> VPP 可以作为 OpenStack Neutron 的 ML2 驱动，提供高性能虚拟机网络。本章深入解析 ML2 架构、VPP ML2 驱动、Neutron 集成与 SRIOV。

## 1. OpenStack 网络概述

### 1.1 Neutron 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenStack Neutron                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Neutron Server                          │  │
│  │  (REST API)                                          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              ML2 Plugin (Mechanism Driver)            │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │  │
│  │  │  OVS    │  │  SRIOV   │  │  VPP     │           │  │
│  │  │  Driver │  │  Driver  │  │  Driver  │           │  │
│  │  └──────────┘  └──────────┘  └──────────┘           │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP (Data Plane)                         │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 ML2 插件

```
ML2 (Modular Layer 2) 插件：

- Type Driver: 处理网络类型 (VLAN, VXLAN, GRE)
- Mechanism Driver: 处理实际网络设备

┌─────────────────────────────────────────────────────────────┐
│                    ML2 架构                                 │
│                                                              │
│  Network Types (Type Drivers):                              │
│  - Flat                                                       │
│  - VLAN                                                     │
│  - VXLAN                                                    │
│  - GRE                                                      │
│                                                              │
│  Mechanism Drivers:                                          │
│  - OVS                                                      │
│  - SRIOV                                                    │
│  - Linuxbridge                                              │
│  - VPP                                                      │
└─────────────────────────────────────────────────────────────┘
```

## 2. VPP ML2 驱动

### 2.1 驱动架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP ML2 驱动架构                        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Neutron Server                           │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Mechanism Driver                      │  │
│  │                                                       │  │
│  │  - create_network_postcommit                          │  │
│  │  - update_network_postcommit                         │  │
│  │  - delete_network_postcommit                         │  │
│  │  - create_port_postcommit                            │  │
│  │  - update_port_postcommit                            │  │
│  │  - delete_port_postcommit                            │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Agent (RPC)                          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP (Data Plane)                          │  │
│  │                                                       │  │
│  │  - Bridge Domain                                     │  │
│  │  - TAP/vhost-user                                    │  │
│  │  - VxLAN                                             │  │
│  │  - Router                                            │  │
│  │  - ACL                                               │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 驱动实现

```python
# VPP ML2 Mechanism Driver (Python)
from neutron.plugins.ml2 import driver_api as api
from oslo_log import log as logging

LOG = logging.getLogger(__name__)

class VPPMechanismDriver(api.MechanismDriver):
    """VPP ML2 Mechanism Driver."""

    def initialize(self):
        """初始化驱动."""
        self.vpp_agent = VppAgentClient()
        LOG.info("VPP Mechanism Driver initialized")

    def create_network_postcommit(self, context):
        """创建网络后调用."""
        network = context.current
        segment = context.segments_to_commit

        LOG.info("Creating VPP network: %s", network['id'])

        # 调用 VPP Agent
        self.vpp_agent.create_network(
            network_id=network['id'],
            network_type=segment['network_type'],
            segmentation_id=segment['segmentation_id']
        )

    def delete_network_postcommit(self, context):
        """删除网络后调用."""
        network = context.current

        LOG.info("Deleting VPP network: %s", network['id'])

        self.vpp_agent.delete_network(network_id=network['id'])

    def create_port_postcommit(self, context):
        """创建端口后调用."""
        port = context.current
        network = context.network

        LOG.info("Creating VPP port: %s", port['id'])

        # 确定接口类型
        binding = port.get('binding', {})
        profile = binding.get('profile', {})

        if 'vtep' in profile:
            # SRIOV VF
            self.vpp_agent.create_sriov_port(
                port_id=port['id'],
                vf_id=profile['vf_id'],
                mac=port['mac_address']
            )
        else:
            # vhost-user
            self.vpp_agent.create_vhost_port(
                port_id=port['id'],
                mac=port['mac_address'],
                network_id=network['id']
            )
```

## 3. Neutron 集成

### 3.1 VPP Agent

```python
# VPP Agent RPC 客户端
import os_vif
from os_vif import objects as osv_objects

class VppAgentClient:
    """VPP Agent 通信客户端."""

    def __init__(self):
        self.vpp = os_vif.connect()

    def create_network(self, network_id, network_type, segmentation_id):
        """创建 VPP 网络."""
        if network_type == 'vxlan':
            # 创建 VXLAN 隧道
            self.vpp.create_vxlan(
                network_id=network_id,
                vni=segmentation_id
            )
        elif network_type == 'vlan':
            # 创建 VLAN
            self.vpp.create_vlan(
                network_id=network_id,
                vlan_id=segmentation_id
            )

    def create_port(self, port_id, network_id, mac_address):
        """创建 VPP 端口."""
        # 创建 TAP 或 vhost-user
        self.vpp.create_interface(
            port_id=port_id,
            network_id=network_id,
            interface_type='vhost-user',
            mac_address=mac_address
        )
```

### 3.2 安装配置

```bash
# 安装 VPP ML2 驱动
pip install networking-vpp

# Neutron 配置 /etc/neutron/neutron.conf
[ml2]
tenant_network_types = vxlan,vlan
mechanism_drivers = vpp,openvswitch

# /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2_vpp]
# VPP API socket
vpp_socket = /var/run/vpp/vpp-api.sock

# VPP 节点
vpp_hosts = compute1,compute2

# 默认网络类型
default_network_type = vxlan
```

### 3.3 VPP Agent 安装

```bash
# 在每个计算节点安装 VPP Agent
apt-get install networking-vpp-agent

# 配置 /etc/vpp/vpp-agent.conf
[DEFAULT]
# VPP socket
vpp_socket = /var/run/vpp/vpp-api.sock

# Neutron 端点
neutron_url = http://controller:9696

# 启动服务
systemctl enable networking-vpp-agent
systemctl start networking-vpp-agent
```

## 4. Router 集成

### 4.1 VPP Router

```
VPP 可以替代 Linux Namespace Router：

┌─────────────────────────────────────────────────────────────┐
│                    VPP Router                               │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    VPP                                 │  │
│  │                                                       │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐    │  │
│  │  │  Router A  │  │  Router B  │  │  Router C  │    │  │
│  │  │            │  │            │  │            │    │  │
│  │  │ net1 ↔ net2│  │ net3 ↔ net4│  │ net5 ↔ net6│    │  │
│  │  └────────────┘  └────────────┘  └────────────┘    │  │
│  │                                                       │  │
│  │  - HA (VRRP)                                        │  │
│  │  - SNAT                                            │  │
│  │  - DNAT                                            │  │
│  │  - ACL                                             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Router 配置

```python
# VPP Router 操作
def create_router(self, router_id, external_gateway=None):
    """创建 VPP Router."""
    self.vpp.create_l3_vrf(router_id)

    if external_gateway:
        self.vpp.set_l3_vrf_gateway(
            vrf_id=router_id,
            gateway=external_gateway
        )

def add_interface(self, router_id, network_id, subnet_id):
    """添加接口到 Router."""
    # 获取子网信息
    subnet = self.neutron.get_subnet(subnet_id)

    # 添加到 VPP
    self.vpp.add_l3_vrf_interface(
        vrf_id=router_id,
        interface=network_id,
        subnet=subnet['cidr']
    )

def enable_snat(self, router_id, external_net, floating_ip):
    """启用 SNAT."""
    self.vpp.enable_snat(
        vrf_id=router_id,
        external_interface=external_net,
        inside_cidr=floating_ip
    )
```

## 5. Security Group

### 5.1 VPP ACL 作为 Security Group

```
Neutron Security Group → VPP ACL：

┌─────────────────────────────────────────────────────────────┐
│                    Security Group → ACL                     │
│                                                              │
│  Neutron Security Group Rule:                              │
│    allow tcp port 22 from 0.0.0.0/0                       │
│                                                              │
│  ↓ 转换                                                      │
│                                                              │
│  VPP ACL:                                                   │
│    permit tcp from 0.0.0.0/0 to any port 22                │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Security Group 实现

```python
# Security Group 到 ACL 转换
def update_security_group(self, sg_id, rules):
    """更新 Security Group ACL."""
    # 构建 VPP ACL
    acl_entries = []

    for rule in rules:
        entry = {
            'action': 'permit' if rule['direction'] == 'ingress' else 'deny',
            'source_ip': rule.get('remote_ip_prefix'),
            'dest_ip': rule.get('ip_prefix'),
            'protocol': rule['protocol'],
            'source_port': rule.get('port_range_min'),
            'dest_port': rule.get('port_range_max'),
        }
        acl_entries.append(entry)

    # 应用到 VPP
    self.vpp.set_acl(acl_id=sg_id, entries=acl_entries)
```

## 6. SRIOV 支持

### 6.1 SRIOV 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    SRIOV 与 VPP                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Physical Function (PF)                   │  │
│  │               (VPP 控制)                              │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                    ↓                    ↓           │
│  ┌─────────┐          ┌─────────┐          ┌─────────┐   │
│  │ VF 0   │          │ VF 1   │          │ VF 2   │   │
│  │ (VM)   │          │ (VM)   │          │ (VPP)  │   │
│  └─────────┘          └─────────┘          └─────────┘   │
│                                                              │
│  VPP 使用 VF 直接连接到 VM                                  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 SRIOV 配置

```bash
# 启用 SRIOV
ip link set eth0 vf 0 spoofchk off
ip link set eth0 vf 0 trust on
ip link set eth0 vf 0 max_tx_rate 1000

# 配置 VPP 使用 VF
vpp# create host-interface name eth0
vpp# set interface state host-eth0 up
vpp# set interface ip addr host-eth0 0.0.0.0
```

## 7. 性能对比

### 7.1 OVS vs VPP

| 指标 | OVS-Kernel | OVS-DPDK | VPP |
|------|-------------|-----------|-----|
| **延迟** | ~100μs | ~20μs | ~10μs |
| **吞吐量** | ~2 Gbps | ~8 Gbps | ~15 Gbps |
| **PPS** | ~500K | ~3M | ~10M |
| **CPU 开销** | 中 | 高 | 低 |
| **内存** | 低 | 高 | 中 |

### 7.2 配置示例

```ini
# /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2_vpp]
# VPP 连接
vpp_socket = /var/run/vpp/vpp-api.sock

# 网络类型
tenant_network_types = vxlan,vlan,flat

# 默认 MTU
default_mtu = 9000

# VLAN 范围
vlan_ranges = physnet1:100:200

# QoS
enable_qos = True
```

## 8. 总结

VPP + OpenStack 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP + OpenStack                         │
│                                                              │
│  Neutron Server                                             │
│       ↓ ML2                                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Mechanism Driver                     │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓ RPC                                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Agent (Compute Node)                  │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP (Data Plane)                         │  │
│  │                                                       │  │
│  │  - Networks (VxLAN/VLAN)                             │  │
│  │  - Ports (vhost-user/SRIOV)                          │  │
│  │  - Routers                                          │  │
│  │  - ACL (Security Groups)                             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

集成组件：

| 组件 | 功能 |
|------|------|
| **ML2 Driver** | Neutron 插件接口 |
| **VPP Agent** | 与 VPP 通信 |
| **Neutron Router** | L3 路由 |
| **Security Group** | ACL |
| **SRIOV** | 硬件直通 |

---

## 参考资源

- [Networking-VPP](https://github.com/openstack/networking-vpp)
- [Neutron ML2](https://docs.openstack.org/neutron/latest/admin/config-ml2.html)
- [VPP OpenStack](https://wiki.fd.io/view/VPP/OpenStack)
