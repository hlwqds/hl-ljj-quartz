---
title: "P4 深度探索 (二十一)：BMv2——Behavioral Model v2、软件交换机、p4app 与 P4 语言仿真"
date: 2026-04-14
tags:
  [p4, series, bmv2, behavioral-model, software-switch, p4app, bmv2-ss, mininet, p4runtime, 仿真]
description: "P4 BMv2 深度解析——Behavioral Model v2 软件交换机架构、BMv2 Simple Switch/Complex Switch、p4app Docker 环境、mininet 集成、P4Runtime 控制面、BMv2 调试工具 pdump/Wireshark"
---

> [!info] P4 深度探索系列 0. [[p4-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct/tuple]]
> 6. [[ch6-headers|第六章：Header 与 Packet——Header 定义、Header Stack]]
> 7. [[ch7-parser|第七章：Parser 编程——状态机、Header 提取、Error 处理]]
> 8. [[ch8-match-action|第八章：Match-Action 编程——Table、Action、Key]]
> 9. [[ch9-control|第九章：Control 编程——Control Block、条件判断、Action 调用链]]
> 10. [[ch10-deparser|第十章：Deparser——包重组、Header 顺序、Checksum 重新计算]]
> 11. [[ch11-psa|第十一章：PSA 架构——Portable Switch Architecture、Ingress/Egress 管道]]
> 12. [[ch12-tna|第十二章：TNA 架构——Tofino Native Architecture、高性能流水线]]
> 13. [[ch13-pipeline|第十三章：Pipeline 设计——Match-Action 流水线、逻辑阶段与物理阶段]]
> 14. [[ch14-registers|第十四章：Register 与状态——Register、Counter、Gauge、Direct/Indirect 资源]]
> 15. [[ch15-checksum|第十五章：Checksum——Checksum 验证与重新计算、IPv4/TCP/UDP]]
> 16. [[ch16-extern|第十六章：Extern 对象——Hash/Checksum/Register/Queue/Digest]]
> 17. [[ch17-parsevarset|第十七章：Parse Varset——变长 Header 与 IPv6 Extension Header 解析]]
> 18. [[ch18-meter|第十八章：Meter 与 Traffic Manager——流量计量、队列管理与 QoS]]
> 19. [[ch19-int|第十九章：INT——In-band Network Telemetry 随流检测]]
> 20. [[ch20-multicast|第二十章：Multicast 与 Clone——多播组、Packet Clone、会话复制与镜像]]
> 21. **第二十一章：BMv2——Behavioral Model v2、软件交换机、p4app 与 P4 语言仿真**

---

## 1. 概述：什么是 BMv2？

**BMv2 (Behavioral Model version 2)** 是 P4 语言的开源软件交换机实现，由 P4 语言 consortium 开发维护。它是 P4 语言的参考交换机，用于**学习、实验、原型验证**。

```
BMv2 在 P4 生态中的位置:
========================

P4 Source Code (my_program.p4)
         |
         v
    +-----------+
    |  p4c-bmvm  |  <-- P4 编译器 (BMv2 后端)
    +-----------+
         |
         v
    JSON Config File
         |
         +---> BMv2 (Software Switch) <---> Control Plane (P4Runtime/gRPC)
                     |
                     v
              [Packet Processing]
```

### 1.1 BMv2 的特点

| 特性            | 描述                              |
| --------------- | --------------------------------- |
| **开源**        | Apache 2.0 许可，可在 GitHub 获取 |
| **跨平台**      | Linux/macOS/Windows (via Docker)  |
| **可移植**      | 基于 C++ 实现，依赖 Boost/Thrift  |
| **P4Runtime**   | 支持 gRPC 控制面接口              |
| **PSA/V1Model** | 支持两种架构                      |
| **调试友好**    | 内置 pdump/pdjson 日志工具        |

### 1.2 BMv2 vs 硬件交换机

| 维度     | BMv2       | Tofino/硬件    |
| -------- | ---------- | -------------- |
| 吞吐量   | ~10Mpps    | ~1000Mpps+     |
| 延迟     | 10-50μs    | <1μs           |
| 表容量   | 受限于 RAM | 数十 M entries |
| TCAM     | 软件模拟   | 原生硬件       |
| 成本     | 免费       | $10K-$100K+    |
| 适用场景 | 开发/测试  | 生产部署       |

---

## 2. BMv2 架构

### 2.1 BMv2 整体架构

```
BMv2 整体架构:
==============

+------------------------------------------------------------------+
|                         Host Machine                             |
+------------------------------------------------------------------+

   +-------------+         +-------------+         +-------------+
   |  Control    |         |   BMv2      |         |   Network   |
   |  Plane      |<------->|   Switch    |<------->|   (Pkt I/O) |
   |  (P4Runtime)|  gRPC   |             |  Ports   |             |
   +-------------+         +-------------+         +-------------+
                                  |
                                  | Thrift CLI
                                  v
                           +-------------+
                           |   CLI.sh    |
                           |  (Commands) |
                           +-------------+

+------------------------------------------------------------------+
|                      BMv2 Internal Components                    |
+------------------------------------------------------------------+

   +---------------------------------------------------------------+
   |                     Simple Switch (SS) / Complex Switch      |
   +---------------------------------------------------------------+

   [Packet In] --> [Parser] --> [Match-Action] --> [Deparser] --> [Packet Out]
                          |               |
                          v               v
                    [Deparser]       [Traffic Manager]
                          |               |
                          v               v
                    [Checksum]       [Queue/Clone]

   +---------------------------------------------------------------+
   |                        Extern Objects                          |
   +---------------------------------------------------------------+
   |  * Hash (CRC)        * Register       * Counter               |
   |  * Checksum          * Meter          * Digest                 |
   |  * Action Profile   * Random         * Parser Value Set       |
   +---------------------------------------------------------------+
```

### 2.2 BMv2 Simple Switch (SS)

BMv2 Simple Switch 是最常用的 BMv2 实现，对应 **V1Model 架构**：

```
BMv2 Simple Switch 流水线:
==========================

     Packet Input (from port)
            |
            v
     +--------------+
     |    Parser    |  <-- P4 Parser (状态机)
     +--------------+
            |
            v
     +--------------+     +--------------+
     |   Checksum   |     | Match-Action |
     |   Verify     |     |   Pipeline  |
     +--------------+     +--------------+
                                  |
            +---------------------+---------------------+
            |                     |                     |
            v                     v                     v
     +------------+        +------------+        +------------+
     |  Ingress   |        |   Egress   |        |  Replicator| (MC/Clone)
     |  Pipeline  |------->|  Pipeline  |        |            |
     +------------+        +------------+        +------------+
            |                     |                     |
            v                     v                     v
     +-------------------------------------------+
     |           Traffic Manager                 |
     |  +--------+  +--------+  +--------+        |
     |  | Queues |  |  MC    |  | Clone  |        |
     |  |        |  | Engine |  | Engine |        |
     |  +--------+  +--------+  +--------+        |
     +-------------------------------------------+
            |
            v
     +--------------+
     |   Deparser   |  <-- P4 Deparser
     +--------------+
            |
            v
     +--------------+
     |  Checksum    |  <-- Recalculate
     +--------------+
            |
            v
     Packet Output (to port(s))
```

### 2.3 BMv2 组件关系

```
BMv2 核心组件:
==============

bmv2/
├── bmv2.cpp              # 主程序入口
├── simple_switch/        # Simple Switch 实现
│   ├── simple_switch.cpp
│   ├── SimpleSwitch.h
│   └── SimpleSwitch.cpp
├── simple_switchgrpc/   # gRPC 接口 (P4Runtime)
│   ├── simple_switch.grpc_server.cc
│   └── simple_switch_table_dump.cc
├── lib/                  # 核心库
│   ├── BMv2Switch.h      # 交换机基类
│   ├── Packet.h          # 数据包类
│   ├── PHV.h            # Packet Header Vector
│   └── ...
└──thrift/               # Thrift IDL 定义
```

---

## 3. BMv2 编译与运行

### 3.1 p4c-bmvm 编译流程

```bash
# 1. 安装依赖 (Ubuntu 20.04/22.04)
sudo apt-get update
sudo apt-get install -y \
    git cmake build-essential \
    libboost-dev libboost-graph-dev libboost-iostreams-dev \
    libboost-program-options-dev libboost-system-dev \
    libboost-thread-dev libevent-dev libgrpc++-dev \
    libprotobuf-dev libssl-dev libthrift-dev \
    python3 python3-pip python3-rrdtool

# 2. 克隆 p4lang/p4c
git clone --recursive https://github.com/p4lang/p4c.git
cd p4c

# 3. 配置并编译
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release \
         -DENABLE_BMV2=ON \
         -DENABLE_P4RUNTIME=ON \
         -DENABLE_GRPC=ON
make -j$(nproc)
sudo make install

# 4. 设置环境变量
export PATH=$PATH:/usr/local/bin
export PYTHONPATH=$PYTHONPATH:/usr/local/lib/python3*/dist-packages
```

### 3.2 编译 P4 程序到 BMv2

```bash
# 编译 basic_routing.p4 到 BMv2 (JSON + P4Info)
p4c-bmvm-ss -o basic_routing.json \
    --p4v 16 \
    --p4runtime-files basic_routing.p4info.txt \
    basic_routing.p4

# 输出文件:
#   basic_routing.json        <-- BMv2 配置
#   basic_routing.p4info.txt  <-- P4Runtime 描述
```

### 3.3 使用 p4app 运行 BMv2

**p4app** 是 Docker 封装的 P4 开发环境，一键启动：

```bash
# 1. 安装 p4app
docker pull p4lang/p4app

# 2. 创建拓扑文件 (topology.json)
cat > topology.json << 'EOF'
{
  "program": "basic_routing.p4",
  "p4info": "basic_routing.p4info.txt",
  "bmv2_json": "basic_routing.json",
  "switch": "simple_switch",
  "options": "--device-id 0",
  "ports": {
    "s1": [1, 2, 3, 4]
  },
  "links": [
    ["h1", "s1"], ["h2", "s1"],
    ["h3", "s1"], ["h4", "s1"]
  ],
  "hosts": {
    "h1": { "ip": "10.0.1.1/24", "mac": "00:00:00:00:01:01" },
    "h2": { "ip": "10.0.1.2/24", "mac": "00:00:00:00:01:02" },
    "h3": { "ip": "10.0.2.1/24", "mac": "00:00:00:00:02:01" },
    "h4": { "ip": "10.0.2.2/24", "mac": "00:00:00:00:02:02" }
  },
  "routes": {
    "h1": [{"dst": "10.0.2.0/24", "gw": "10.0.1.254"}],
    "h2": [{"dst": "10.0.2.0/24", "gw": "10.0.1.254"}],
    "h3": [{"dst": "10.0.1.0/24", "gw": "10.0.2.254"}],
    "h4": [{"dst": "10.0.1.0/24", "gw": "10.0.2.254"}]
  }
}
EOF

# 3. 运行 p4app (创建 Mininet 拓扑)
p4app run --topology topology.json

# 4. 在 Mininet CLI 中测试
mininet> h1 ping h2
mininet> h1 ping h3
```

### 3.4 直接运行 BMv2

```bash
# 1. 启动 BMv2 (无控制面，手动配置)
simple_switch -i 0@00:00:00:00:01:00 -i 1@00:00:00:00:01:01 \
    --log-console \
    --dump-packet-data 100 \
    basic_routing.json &

# 2. 连接 CLI (Thrift)
simple_switch_CLI --thrift-port 9090 < commands.txt

# 3. 查看表项
simple_switch_CLI --thrift-port 9090 << 'EOF'
table_dump ipv4_lpm
EOF

# 4. 停止
pkill simple_switch
```

---

## 4. BMv2 CLI 命令

### 4.1 Thrift CLI 基本命令

```bash
# 连接 BMv2 CLI
simple_switch_CLI --thrift-port 9090

# 显示帮助
help

# 读取表项
table_dump <table_name>
table_dump ipv4_lpm

# 添加表项 (P4 内部定义的动作)
table_add <table_name> <action_name> <key> => [action_params]
table_add ipv4_lpm set_nexthop 10.0.1.0/24 => 2
table_add ipv4_lpm set_nexthop 10.0.2.0/24 => 3

# 删除表项
table_delete <table_name> <entry_handle>
table_delete ipv4_lpm 1

# 设置默认动作
table_set_default <table_name> <action_name>
table_set_default acl_table drop

# 读取寄存器
register_read <register_name> <index>
register_read switch_id 0

# 写入寄存器
register_write <register_name> <index> <value>
register_write switch_id 0 42

# 读取计数器
counter_read <counter_name> <index>
counter_read ingress_counters.pkts 0

# 清除所有状态
clear
```

### 4.2 常用命令示例

```bash
# L3 路由配置
table_add forward l2_forward 00:00:00:00:01:02 => 2
table_add forward l2_forward 00:00:00:00:02:02 => 3

# ACL 配置
table_add acl allow_srcip 10.0.1.0/24 =>
table_add acl drop 0.0.0.0/0 =>

# 修改 MTU
switch_config set_mtu 1500

# 启用/禁用 Ingress
switch_config set_pipeline_config 0
```

---

## 5. P4Runtime 控制面

### 5.1 P4Runtime gRPC 接口

BMv2 支持 P4Runtime，可通过 gRPC 编程控制面：

```protobuf
// P4Runtime 服务定义
service P4Runtime {
    // 表项操作
    rpc Write(WriteRequest) returns (WriteResponse);
    rpc Read(ReadRequest) returns (stream ReadResponse);

    // Packet 操作
    rpc PacketIn(stream PacketOut) returns (stream PacketIn);

    // 流消息
    rpc StreamMessageBstream(stream StreamMessageRequest)
        returns (stream StreamMessageResponse);
}
```

### 5.2 P4Runtime Python 客户端

```python
#!/usr/bin/env python3
# p4runtime_client.py - 使用 P4Runtime 控制 BMv2

import grpc
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2

class P4RuntimeClient:
    def __init__(self, address='127.0.0.1:50051'):
        self.channel = grpc.insecure_channel(address)
        self.stub = p4runtime_pb2_grpc.P4RuntimeStub(self.channel)

    def get_forwarding_config(self):
        # 获取交换机配置
        req = p4runtime_pb2.GetForwardingStatisticsRequest()
        return self.stub.GetForwardingStatistics(req)

    def write_table_entry(self, table_name, action_name,
                          match_fields, action_params):
        """写入表项"""
        update = p4runtime_pb2.Update()
        update.type = p4runtime_pb2.Update.INSERT

        entry = update.entity.table_entry
        entry.table_id = self.get_table_id(table_name)

        # 设置 Match Key
        for field, value in match_fields.items():
            mf = entry.match.add()
            mf.field_id = self.get_field_id(table_name, field)
            mf.exact.value = value

        # 设置 Action
        action = entry.action.action
        action.action_id = self.get_action_id(action_name)
        for name, val in action_params.items():
            p = action.params.add()
            p.param_id = self.get_param_id(action_name, name)
            p.value = val

        req = p4runtime_pb2.WriteRequest()
        req.device_id = 0
        req.election_id.low = 1
        req.updates.append(update)

        return self.stub.Write(req)

    def read_table(self, table_name):
        """读取表项"""
        req = p4runtime_pb2.ReadRequest()
        entity = req.entities.add().table_entry
        entity.table_id = self.get_table_id(table_name)

        for resp in self.stub.Read(req):
            yield resp

    def set_pipeline_config(self, p4info_path, bmv2_json_path):
        """设置流水线配置"""
        with open(p4info_path, 'rb') as f:
            p4info = p4info_pb2.P4Info()
            p4info.ParseFromString(f.read())

        with open(bmv2_json_path, 'rb') as f:
            bmv2_json = f.read()

        req = p4runtime_pb2.SetPipelineProgramRequest()
        req.device_id = 0
        req.election_id.low = 1
        req.config.p4info.CopyFrom(p4info)
        req.config.bmv2_json_file = bmv2_json

        return self.stub.SetPipelineProgram(req)

# 使用示例
if __name__ == '__main__':
    client = P4RuntimeClient('127.0.0.1:50051')

    # 设置流水线配置
    client.set_pipeline_config('basic_routing.p4info.txt',
                               'basic_routing.json')

    # 写入路由表项
    client.write_table_entry(
        table_name='ipv4_lpm',
        action_name='set_nexthop',
        match_fields={'ipv4.dstAddr': '10.0.2.0'},
        action_params={'nexthop_id': 2}
    )
```

### 5.3 P4Runtime Shell 工具

```bash
# 使用 p4rt-cli 工具
p4rt-cli set-forwarding-pipeline-config \
    --device=0 \
    --config=basic_routing.p4info.txt,basic_routing.json

p4rt-cli table-entry-insert \
    --device=0 \
    --table=ipv4_lpm \
    --key="10.0.2.0/24" \
    --action=set_nexthop \
    --param="nexthop_id=2"

p4rt-cli table-entry-dump \
    --device=0 \
    --table=ipv4_lpm
```

---

## 6. BMv2 调试工具

### 6.1 pdump 抓包

BMv2 内置 pdump，可在运行时抓取数据包：

```bash
# 1. 启用 pdump (在 BMv2 启动时)
simple_switch --pdump 0,1,2,3 \
    --pcap /tmp/pdump.pcap \
    basic_routing.json

# 2. pdump 生成文件
#    my_program-0-0.pcap  (Port 0 Ingress)
#    my_program-0-1.pcap  (Port 0 Egress)
#    my_program-1-0.pcap  (Port 1 Ingress)
#    ...

# 3. 使用 tcpdump 分析
tcpdump -r /tmp/my_program-0-0.pcap -vv

# 4. 使用 Wireshark 可视化
wireshark /tmp/my_program-0-0.pcap &
```

### 6.2 日志分析

```bash
# 1. 启用详细日志
simple_switch --log-console \
    --log-level 4 \
    basic_routing.json

# 2. 日志输出示例
[12:34:56.789] [bmv2] [D] [thread 0] Processing packet from port 1
[12:34:56.790] [bmv2] [D] [thread 0] Parser state: start
[12:34:56.791] [bmv2] [D] [thread 0] Extracted ethernet: dst=00:00:00:00:01:01 src=00:00:00:00:01:02
[12:34:56.792] [bmv2] [D] [thread 0] Table 'ipv4_lpm' matched: key=10.0.2.1
[12:34:56.793] [bmv2] [D] [thread 0] Action 'set_nexthop' executed with param nexthop_id=2

# 3. 日志级别
#    0 = trace
#    1 = debug
#    2 = info
#    3 = warn
#    4 = error
```

### 6.3 JSON 配置调试

BMv2 的 JSON 配置文件可以手动编辑后重载：

```bash
# 1. 导出当前配置
simple_switch_CLI --thrift-port 9090 << 'EOF'
dump-ports
dump-registers
dump-meters
EOF

# 2. 生成 JSON (用于调试编译器输出)
python3 tools/dumpjson.py > debug.json

# 3. 检查 Parser 状态机
jq '.parser_states' basic_routing.json
```

---

## 7. BMv2 与 Mininet 集成

### 7.1 Mininet 拓扑脚本

```python
#!/usr/bin/env python3
# mininet_p4.py - Mininet + BMv2 集成

from mininet.net import Mininet
from mininet.node import Host, Switch
from mininet.link import Link, TCLink
from mininet.cli import CLI
from mininet.log import setLogLevel, info
import os

class P4Switch(Switch):
    """P4 BMv2 交换机"""

    def __init__(self, name, json_path, p4info_path, **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.json_path = json_path
        self.p4info_path = p4info_path
        self.command_args = [
            '--json', json_path,
            '--p4info', p4info_path,
        ]

    def start(self, controllers):
        """启动 BMv2 交换机"""
        info(f'Starting P4 Switch {self.name}\n')

        cmd = [
            'simple_switch',
            '--thrift-port', str(self.thrift_port),
            '-i', '0@{}'.format(self.intfs[0].name),
            '-i', '1@{}'.format(self.intfs[1].name),
            '--log-console',
            '--pcap',
            self.json_path,
            '--',
            '--device-id', str(self.dpid)
        ]

        self.cmd(' '.join(cmd) + ' &')
        self.waitStartup()

def create_topology():
    """创建 2x2 主机拓扑"""
    net = Mininet(link=TCLink)

    # 添加主机
    h1 = net.addHost('h1', mac='00:00:00:00:01:01', ip='10.0.1.1/24')
    h2 = net.addHost('h2', mac='00:00:00:00:01:02', ip='10.0.1.2/24')
    h3 = net.addHost('h3', mac='00:00:00:00:02:01', ip='10.0.2.1/24')
    h4 = net.addHost('h4', mac='00:00:00:00:02:02', ip='10.0.2.2/24')

    # 添加 P4 交换机
    s1 = net.addSwitch('s1', cls=P4Switch,
                       json_path='basic_routing.json',
                       p4info_path='basic_routing.p4info.txt')

    # 创建链路
    net.addLink(h1, s1)
    net.addLink(h2, s1)
    net.addLink(h3, s1)
    net.addLink(h4, s1)

    # 配置路由
    h1.setDefaultRoute('via 10.0.1.254')
    h2.setDefaultRoute('via 10.0.1.254')
    h3.setDefaultRoute('via 10.0.2.254')
    h4.setDefaultRoute('via 10.0.2.254')

    net.start()

    # 配置交换机的 L3 转发表
    s1.cmd('simple_switch_CLI --thrift-port 9090 < s1_commands.txt')

    CLI(net)
    net.stop()

if __name__ == '__main__':
    setLogLevel('info')
    create_topology()
```

### 7.2 交换机命令文件

```bash
# s1_commands.txt - 交换机 S1 的初始化命令

# 设置路由表
table_add ipv4_lpm set_nexthop 10.0.2.0/24 => 2
table_add ipv4_lpm set_nexthop 10.0.1.0/24 => 1

# 设置 L2 转发表
table_add forward l2_forward 00:00:00:00:02:01 => 2
table_add forward l2_forward 00:00:00:00:02:02 => 3
table_add forward l2_forward 00:00:00:00:01:01 => 0
table_add forward l2_forward 00:00:00:00:01:02 => 1

# 设置 ACL
table_set_default acl_table allow

# 读取表项验证
table_dump ipv4_lpm
table_dump forward
```

---

## 8. BMv2 限制与注意事项

### 8.1 与 TNA/PSA 的差异

| 特性          | BMv2         | Tofino/PSA |
| ------------- | ------------ | ---------- |
| 表容量        | 受限 (~100K) | 数十 M     |
| 精确度        | 软件模拟     | 硬件原生   |
| Parser        | 有限并行     | 高度并行   |
| 性能          | ~10Mpps      | 线速       |
| 支持的 extern | 基础子集     | 全部       |

### 8.2 已知的限制

```c
// BMv2 不支持的 P4-16 特性:
// =================================

// 1. 动态表大小 (某些情况下)
table my_table {
    key = { h.ipv4.dstAddr: lpm; }
    actions = { forward; drop; }
    // size 参数在 BMv2 中可能被忽略
    size = 65536;  // 仅作为提示
}

// 2. 常量表项中的复杂表达式
const entries = {
    // BMv2 可能不支持某些操作
    exact &&& { h.tcp.flags & 0xFF == 0x02 }: syn_ack();  // 可能失败
}

// 3. P4-16 extern 的完整实现
// BMv2 不支持某些 TNA/PSA 特定的 extern
```

### 8.3 性能优化建议

```bash
# BMv2 性能调优

# 1. 启用多线程 (充分利用多核)
simple_switch --threads 8 basic_routing.json

# 2. 调整队列深度
simple_switch --queues 1024 basic_routing.json

# 3. 禁用不必要的日志
simple_switch --no_debug_info basic_routing.json

# 4. 使用 DPDK 接口 (需要 DPDK 支持)
simple_switch --dpdk-arg="--vdev=eth_pcap0" basic_routing.json
```

---

## 9. 总结

BMv2 是 P4 生态中最重要的软件交换机实现：

1. **学习工具**：免费开源，快速上手 P4 编程
2. **验证平台**：在部署到硬件前验证 P4 程序逻辑
3. **测试框架**：支持单元测试、集成测试
4. **控制面开发**：P4Runtime gRPC 接口用于控制面开发

**下一章**我们将深入 **Intel Tofino** 架构，了解商用 P4 交换芯片的内部实现。
