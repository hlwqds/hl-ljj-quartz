---
title: "VPN 技术深度探索 (十七)：IPSec 策略配置"
date: 2026-04-13
tags: [vpn, series, networking, security, ipsec, xfrm, spd, sad, route-based-vpn, policy-based-vpn, strongswan, vti, xfrmi]
description: "IPSec 策略配置全景——ip xfrm 命令详解、SPD/SAD 管理、策略路由与路由 VPN 对比、VTI/XFRMI 虚拟接口、strongSwan swanctl 配置范式、多隧道/高可用部署架构"
---

> [!info] VPN 技术深度探索系列
> 14. [[2026-04-13-vpn-deep-dive-ch14-ipsec-overview|IPSec 体系概述]]
> 15. [[2026-04-13-vpn-deep-dive-ch15-ipsec-ike|IKE 密钥交换]]
> 16. [[2026-04-13-vpn-deep-dive-ch16-ipsec-esp|AH 与 ESP 协议]]
> **17. IPSec 策略配置（本章）**
> 18. [[2026-04-13-vpn-deep-dive-ch18-ipsec-troubleshooting|IPSec 排错]]

---

## 1. IPSec 两种 VPN 架构

Linux IPSec 支持两种主要部署架构：

### 1.1 策略 VPN（Policy-Based VPN）

```
工作原理：
  在 SPD（安全策略数据库）中配置 src/dst 子网选择符
  匹配策略的流量 → 自动应用 IPSec 封装
  不需要额外的路由配置

优点：
  配置简单，适合固定子网对子网的站点 VPN

缺点：
  每对通信子网需要独立的 SA，扩展性差
  不适合动态路由（OSPF/BGP）
  与 NAT/iptables 交互复杂
```

### 1.2 路由 VPN（Route-Based VPN）

```
工作原理：
  创建虚拟 IPSec 接口（VTI 或 XFRMI）
  通过路由表决定流量走哪个接口
  进入虚拟接口的流量被自动 IPSec 封装

优点：
  可运行动态路由协议（OSPF/BGP over IPSec）
  与 iptables/nftables 集成更友好
  适合 Hub-Spoke、多云互联等复杂拓扑
  支持 ECMP 负载均衡

缺点：
  配置稍复杂（需要额外的接口和路由）
```

---

## 2. ip xfrm 命令详解

`ip xfrm` 是管理 Linux IPSec 的核心工具（iproute2 的一部分）。

### 2.1 SA 管理（ip xfrm state）

```bash
# 列出所有 SA
ip xfrm state

# 显示统计信息
ip xfrm state show

# 添加出站 SA（手工，用于测试）
ip xfrm state add \
    src 192.168.1.1 \
    dst 192.168.2.1 \
    proto esp \
    spi 0xdeadbeef \
    mode tunnel \
    auth-trunc 'hmac(sha256)' 0x$(openssl rand -hex 32) 128 \
    enc 'cbc(aes)' 0x$(openssl rand -hex 32)

# 添加 AES-GCM SA（推荐）
ip xfrm state add \
    src 192.168.1.1 \
    dst 192.168.2.1 \
    proto esp \
    spi 0xdeadbeef \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' 0x$(openssl rand -hex 36) 128
    # 注：GCM 密钥 = 32字节密钥 + 4字节 salt = 36 字节

# 删除 SA
ip xfrm state del \
    src 192.168.1.1 \
    dst 192.168.2.1 \
    proto esp \
    spi 0xdeadbeef

# 清空所有 SA
ip xfrm state flush

# 查看 SA 使用统计
ip xfrm state show
# 关注字段：
#   stats: replay-window N replay M failed K
#   lifetime current: bytes X packets Y
```

### 2.2 策略管理（ip xfrm policy）

```bash
# 列出所有策略
ip xfrm policy

# 出站策略：10.0.1.0/24 → 10.0.2.0/24 走 IPSec
ip xfrm policy add \
    src 10.0.1.0/24 \
    dst 10.0.2.0/24 \
    dir out \
    priority 100 \
    tmpl \
        src 192.168.1.1 \
        dst 192.168.2.1 \
        proto esp \
        mode tunnel

# 入站策略
ip xfrm policy add \
    src 10.0.2.0/24 \
    dst 10.0.1.0/24 \
    dir in \
    priority 100 \
    tmpl \
        src 192.168.2.1 \
        dst 192.168.1.1 \
        proto esp \
        mode tunnel

# Forward 策略（网关场景）
ip xfrm policy add \
    src 10.0.2.0/24 \
    dst 10.0.1.0/24 \
    dir fwd \
    priority 100 \
    tmpl \
        src 192.168.2.1 \
        dst 192.168.1.1 \
        proto esp \
        mode tunnel

# 删除策略
ip xfrm policy del \
    src 10.0.1.0/24 \
    dst 10.0.2.0/24 \
    dir out

# 清空所有策略
ip xfrm policy flush

# 查看带统计的策略
ip xfrm policy list
```

### 2.3 实时监控

```bash
# 监控 SA/策略变化（IKE 守护进程操作时实时显示）
ip xfrm monitor

# 典型输出：
# Async event (0x20) timer expired
# src 192.168.1.1 dst 192.168.2.1
#   proto esp spi 0xdeadbeef ...
```

---

## 3. 策略 VPN 完整配置示例

### 3.1 场景描述

```
Site A                              Site B
10.0.1.0/24 ── [GW-A] ─── Internet ─── [GW-B] ── 10.0.2.0/24
              192.168.1.1             192.168.2.1
```

### 3.2 strongSwan 配置（策略模式）

**GW-A（/etc/swanctl/swanctl.conf）**：

```
connections {
  site-b {
    version = 2
    remote_addrs = 192.168.2.1

    local {
      auth = psk
      id = "gw-a@example.com"
    }
    remote {
      auth = psk
      id = "gw-b@example.com"
    }

    proposals = aes256gcm128-prfsha256-ecp256

    children {
      net-b {
        local_ts  = 10.0.1.0/24
        remote_ts = 10.0.2.0/24
        esp_proposals = aes256gcm128-ecp256
        dpd_action = restart
        start_action = start
        close_action = restart
      }
    }

    dpd_delay = 30s
    dpd_action = restart
  }
}

secrets {
  ike-site-b {
    id-a = "gw-a@example.com"
    id-b = "gw-b@example.com"
    secret = "ChangeMe_SuperSecretKey_2024"
  }
}
```

GW-B 配置对称（remote_addrs 改为 GW-A 的 IP，local/remote 子网互换）。

### 3.3 启动与验证

```bash
# 启动 strongSwan
systemctl start strongswan

# 加载配置
swanctl --load-all

# 查看连接状态
swanctl --list-conns

# 手工触发连接（若 start_action = none）
swanctl --initiate --child net-b

# 查看已建立的 SA
swanctl --list-sas

# 验证 xfrm 状态
ip xfrm state
ip xfrm policy

# 测试连通性
ping -I 10.0.1.1 10.0.2.1
```

---

## 4. 路由 VPN — VTI 接口

**VTI（Virtual Tunnel Interface）** 是 Linux 内核的 IPSec 隧道虚拟接口（内核 3.6+）。

### 4.1 VTI 工作原理

```
VTI 接口作为路由的"出口"，
进入 VTI 接口的报文 → 内核 xfrm 通过 MARK 匹配 SPD 策略 → ESP 封装

SPD 策略使用 mark 而不是 src/dst 子网：
  src 0.0.0.0/0 dst 0.0.0.0/0 mark 0x100 → 走 IPSec
```

### 4.2 VTI 配置示例

```bash
# 创建 VTI 接口（GW-A）
ip tunnel add vti0 \
    mode vti \
    local 192.168.1.1 \
    remote 192.168.2.1 \
    key 0x100        # MARK，用于关联 SPD 策略

ip link set vti0 up
ip addr add 169.254.0.1/30 dev vti0   # 隧道内地址（可选）
ip route add 10.0.2.0/24 dev vti0     # 通过 VTI 路由

# 禁用 VTI 接口的 rp_filter（否则入站报文被丢弃）
sysctl -w net.ipv4.conf.vti0.rp_filter=0

# 配置 xfrm 策略（使用 mark）
ip xfrm policy add \
    src 0.0.0.0/0 dst 0.0.0.0/0 \
    dir out \
    mark 0x100 \
    tmpl src 192.168.1.1 dst 192.168.2.1 \
        proto esp mode tunnel

ip xfrm policy add \
    src 0.0.0.0/0 dst 0.0.0.0/0 \
    dir in \
    mark 0x100 \
    tmpl src 192.168.2.1 dst 192.168.1.1 \
        proto esp mode tunnel

ip xfrm policy add \
    src 0.0.0.0/0 dst 0.0.0.0/0 \
    dir fwd \
    mark 0x100 \
    tmpl src 192.168.2.1 dst 192.168.1.1 \
        proto esp mode tunnel
```

strongSwan VTI 配置：

```
connections {
  site-b-vti {
    ...
    if_id_out = 100   # 对应 VTI mark
    if_id_in  = 100
    children {
      net-b {
        local_ts  = 0.0.0.0/0    # 路由模式，匹配所有流量
        remote_ts = 0.0.0.0/0
        if_id_out = 100
        if_id_in  = 100
      }
    }
  }
}
```

---

## 5. 路由 VPN — XFRMI 接口（推荐）

**XFRMI（IPSec Transformation Interface）** 是 VTI 的改进版（内核 4.19+），推荐使用。

### 5.1 VTI vs XFRMI 对比

| 特性 | VTI | XFRMI |
|------|-----|-------|
| 内核版本 | 3.6+ | 4.19+ |
| 隔离粒度 | 按 src/dst IP 对 | 按 if_id（接口 ID） |
| 支持协议 | IPv4 only | IPv4 + IPv6 |
| SA 绑定方式 | MARK | if_id |
| 支持多隧道同 IP 对 | 否 | 是（不同 if_id） |
| 硬件卸载 | 有限 | 更好支持 |

### 5.2 XFRMI 配置

```bash
# 创建 XFRMI 接口
ip link add xfrm0 type xfrm if_id 1

ip link set xfrm0 up
ip addr add 10.255.0.1/30 dev xfrm0
ip route add 10.0.2.0/24 dev xfrm0

# xfrm 策略使用 if_id
ip xfrm policy add \
    src 0.0.0.0/0 dst 0.0.0.0/0 \
    dir out if_id 1 \
    tmpl src 192.168.1.1 dst 192.168.2.1 \
        proto esp mode tunnel

ip xfrm policy add \
    src 0.0.0.0/0 dst 0.0.0.0/0 \
    dir in if_id 1 \
    tmpl src 192.168.2.1 dst 192.168.1.1 \
        proto esp mode tunnel
```

strongSwan 使用 if_id：

```
connections {
  site-b {
    if_id_in  = 1
    if_id_out = 1
    ...
  }
}
```

---

## 6. 多隧道与高可用场景

### 6.1 Hub-Spoke 拓扑

```
         ┌────────────────────────────────┐
         │          HUB（总部）              │
         │      192.168.0.1               │
         └──────┬──────────────┬──────────┘
                │              │
        Tunnel 1 (if_id=1)  Tunnel 2 (if_id=2)
                │              │
         ┌──────┘     ┌────────┘
         ▼            ▼
    Spoke-A        Spoke-B
  192.168.1.1    192.168.2.1
  10.0.1.0/24   10.0.2.0/24
```

HUB strongSwan 配置：

```
connections {
  spoke-a {
    remote_addrs = 192.168.1.1
    if_id_in = 1
    if_id_out = 1
    children { net-a { local_ts=0.0.0.0/0 remote_ts=0.0.0.0/0 if_id_in=1 if_id_out=1 } }
  }
  spoke-b {
    remote_addrs = 192.168.2.1
    if_id_in = 2
    if_id_out = 2
    children { net-b { local_ts=0.0.0.0/0 remote_ts=0.0.0.0/0 if_id_in=2 if_id_out=2 } }
  }
}
```

### 6.2 主备高可用（Active-Standby）

```
方案 1：使用 Keepalived + VIP
  主网关：VIP = 192.168.1.100（对外 IPSec 地址）
  备网关：standby，VIP 切换时接管
  优点：切换时对对端透明（IP 不变）
  缺点：SA 不迁移，切换后需重协商

方案 2：使用 VRRP + 独立 BGP
  主备都建立 IPSec 隧道（双活）
  BGP 控制路由选择，故障时自动切换
  IKEv2 DPD + restart 自动重连

方案 3：基于 Linux HA（Pacemaker/Corosync）
  同步 SA 状态（strongSwan HA 插件）
  实现无缝切换（in-flight 包不丢失）

strongSwan HA 配置（/etc/strongswan.d/ha.conf）：
  ha {
    local  = 192.168.1.1   # 本节点通信地址
    remote = 192.168.1.2   # 对端 HA 节点地址
    secret = <HA_sync_key>
    resync = yes
    pools {
      # 同步地址池分配
    }
  }
```

---

## 7. 路由策略与 IPSec 交互

### 7.1 策略路由（Policy Routing）

在复杂网络中，可能需要基于源 IP、DSCP 等选择 IPSec 隧道：

```bash
# 创建路由表 100
echo "100 vpn" >> /etc/iproute2/rt_tables

# 匹配源地址 10.0.1.0/24 的流量走路由表 100
ip rule add from 10.0.1.0/24 table 100 priority 100

# 路由表 100 中，目的 10.0.2.0/24 走 xfrm0 接口
ip route add 10.0.2.0/24 dev xfrm0 table 100
```

### 7.2 避免 ESP 流量递归封装

IPSec 报文本身（ESP）不能再被 IPSec 封装，需要 bypass 策略：

```bash
# Bypass：GW 之间的 IKE 和 ESP 流量不走 IPSec
ip xfrm policy add \
    src 192.168.1.1/32 dst 192.168.2.1/32 \
    proto 50 \       # ESP
    dir out \
    action bypass

ip xfrm policy add \
    src 192.168.2.1/32 dst 192.168.1.1/32 \
    proto 50 \
    dir in \
    action bypass

# strongSwan 会自动添加这些 bypass 策略（install_routes = yes）
```

---

## 8. 远程接入 VPN（Roadwarrior）

### 8.1 IKEv2 + EAP 客户端接入

```
Roadwarrior（动态 IP）─── Internet ──→ VPN 网关
  Windows/macOS/iOS                  192.168.1.1
  原生 IKEv2 客户端                   10.0.1.0/24（内网）
```

strongSwan 网关配置：

```
connections {
  rw-eap {
    version = 2
    remote_addrs = %any    # 接受任意来源 IP

    local {
      auth = pubkey
      certs = vpn-server.pem
      id = "vpn.example.com"
    }

    remote {
      auth = eap-mschapv2
      eap_id = %any
    }

    proposals = aes256gcm128-prfsha256-ecp256

    pools = rw-pool       # 分配虚拟 IP

    children {
      rw {
        local_ts  = 0.0.0.0/0   # 推送给客户端的路由
        remote_ts = dynamic      # 客户端虚拟 IP
        esp_proposals = aes256gcm128-ecp256
        dpd_action = clear
      }
    }
  }
}

pools {
  rw-pool {
    addrs = 10.10.0.0/24    # 虚拟 IP 池
    dns = 8.8.8.8           # 推送 DNS
    split_include = 10.0.1.0/24  # 分割隧道（只有内网走 VPN）
  }
}

secrets {
  eap-user1 {
    id = "user1"
    secret = "UserPassword1!"
  }
  eap-user2 {
    id = "user2"
    secret = "UserPassword2!"
  }
}
```

### 8.2 Full Tunnel vs Split Tunnel

```
Full Tunnel（全流量走 VPN）：
  客户端推送路由：0.0.0.0/0 → VPN 接口
  所有流量（含 Internet）经过 VPN 服务器出去
  优点：安全性高，便于监控审计
  缺点：增加服务器负担，延迟高

Split Tunnel（分割隧道）：
  只有内网流量走 VPN（10.0.1.0/24 → VPN 接口）
  Internet 流量直接走本地网络
  优点：性能好，服务器负担小
  缺点：安全策略难以全面控制

strongSwan 分割隧道：
  local_ts = 10.0.1.0/24  # 只推内网路由
  （iOS/Windows 支持 DHCP 推送的 split_include 属性）
```

---

## 9. 内核参数调优

```bash
# 允许 IP 转发（网关场景必须）
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# 关闭反向路径过滤（VTI/XFRMI 接口必须）
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.vti0.rp_filter=0

# 扩大接收/发送缓冲区（高吞吐场景）
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# IPSec 策略缓存（高并发场景）
sysctl -w net.core.xfrm_larval_drop=1   # 快速丢弃待建立的 SA
sysctl -w net.core.xfrm_acq_expires=30  # SA 协商超时（秒）

# 持久化配置到 /etc/sysctl.d/99-ipsec.conf
cat >> /etc/sysctl.d/99-ipsec.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.core.xfrm_larval_drop=1
EOF
```

---

## 10. 本章小结

```
IPSec 策略配置速查：

架构选择：
  策略 VPN  = SPD 基于子网匹配，简单场景
  路由 VPN  = 虚拟接口（VTI/XFRMI）+ 路由，推荐

接口选择：
  VTI  (kernel 3.6+)  = 基于 MARK，IPv4 only
  XFRMI(kernel 4.19+) = 基于 if_id，支持 IPv4/v6，推荐

关键 ip xfrm 命令：
  ip xfrm state   = 管理 SADB（SA 加密状态）
  ip xfrm policy  = 管理 SPD（匹配策略）
  ip xfrm monitor = 实时监控变化

strongSwan 配置要点：
  version = 2        → 使用 IKEv2
  start_action = start    → 自动建立
  close_action = restart  → 断开后重连
  dpd_action = restart    → 检测到对端死亡后重连
  if_id_in/out           → 关联 XFRMI 接口

高可用选项：
  主备切换 = VRRP/Keepalived
  HA 同步  = strongSwan HA 插件
  多活     = BGP 路由 + ECMP
```

---

## 参考资料

- iproute2 ip-xfrm(8) man page
- strongSwan swanctl.conf: https://docs.strongswan.org/docs/5.9/config/swanctl.html
- Linux XFRM: Documentation/networking/xfrm_sync.rst
- RFC 4301: Security Architecture for the Internet Protocol
- Linux VTI: https://lwn.net/Articles/540164/
- Linux XFRMI: https://lwn.net/Articles/757081/
