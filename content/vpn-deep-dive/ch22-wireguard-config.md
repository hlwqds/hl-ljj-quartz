---
title: "VPN 技术深度探索 (二十二)：WireGuard 配置部署"
date: 2026-04-13
tags: [vpn, series, wireguard, configuration, wg-quick, deployment]
description: "WireGuard 配置与部署实战——wg-quick 工具链、配置文件详解、wg show 状态查看、NAT 穿透与 Endpoint 配置、进阶路由（split-tunnel/full-tunnel）、多 Peer 管理"
---

> [!info] VPN 技术深度探索系列 0. [[vpn-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-vpn-fundamentals|VPN 基础概念]]
> 2. [[ch18-ipsec-troubleshooting|第十八章：IPSec 排错]]
> 3. [[ch19-wireguard-protocol|第十九章：WireGuard 协议详解]]
> 4. [[ch20-wireguard-crypto|第二十章：WireGuard 密码学]]
> 5. [[ch21-wireguard-kernel|第二十一章：WireGuard 内核实现]]
> 6. **第二十二章：WireGuard 配置部署**
> 7. [[ch23-wireguard-cloud|第二十三章：WireGuard 云端方案]]

---

## 1. 配置工具链

### 1.1 工具概述

WireGuard 提供两套工具：

```
┌─────────────────────────────────────────────────────────────────┐
│                  WireGuard 工具链                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  内核模块:                                                        │
│  ├─ wg.ko (wireguard-linux/compat/wireguard.ko)               │
│  └─ 内核态加密/解密                                             │
│                                                                 │
│  用户态工具:                                                      │
│  ├─ wg (wireguard-tools/src/wg)                                │
│  │   └─ 运行时配置接口                                          │
│  │                                                               │
│  ├─ wg-quick (wireguard-tools/src/wg-quick)                    │
│  │   └─ 便捷配置脚本，自动管理接口                             │
│  │                                                               │
│  └─ genkey, pubkey, genpsk                                      │
│      └─ 密钥生成工具                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 安装

```bash
# Ubuntu/Debian
apt install wireguard

# CentOS/RHEL (EPEL)
dnf install wireguard-tools

# macOS
brew install wireguard-tools

# 验证安装
wg --version
# wg-tools version 1.0.20210914
```

---

## 2. 密钥生成与管理

### 2.1 密钥生成

WireGuard 使用 **Curve25519** 密钥对：

```bash
# 生成私钥 (32 字节随机数，base64 编码)
wg genkey > server_private.key
# 输出: aBNz5OXa+V9VIL3HTN2P8TnMEO1jO+9F0E9h6rPkCXU=

# 从私钥导出公钥
wg pubkey < server_private.key > server_public.key
# 输出: bnECZ+V9VIL3HTN2P8TnMEO1jO+9F0E9h6rPkCXU=

# 一行完成
wg genkey | tee private.key | wg pubkey > public.key

# 生成预共享密钥 (可选，用于混合密钥)
wg genpsk > preshared.key
```

### 2.2 密钥格式

```
┌─────────────────────────────────────────────────────────────────┐
│                     WireGuard 密钥格式                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  私钥:                                                           │
│  ├─ 长度: 32 字节 (256 bits)                                    │
│  ├─ 编码: Base64                                                │
│  └─ 示例: aBNz5OXa+V9VIL3HTN2P8TnMEO1jO+9F0E9h6rPkCXU=          │
│                                                                 │
│  公钥:                                                           │
│  ├─ 长度: 32 字节                                               │
│  ├─ 编码: Base64                                                │
│  └─ 示例: bnECZ+V9VIL3HTN2P8TnMEO1jO+9F0E9h6rPkCXU=             │
│                                                                 │
│  预共享密钥:                                                      │
│  ├─ 长度: 32 字节                                               │
│  ├─ 用途: 混合密钥（抗量子）                                     │
│  └─ 示例: XNKl9O2CXF9VLZ3hN2P8TnMEO1jO+9F0E9h6rPkCXU=          │
│                                                                 │
│  安全建议:                                                        │
│  ├─ 私钥文件权限: chmod 600                                     │
│  ├─ 不要在生产环境使用弱随机数生成                              │
│  └─ 私钥应备份在安全位置                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 配置文件详解

### 3.1 完整配置示例

```ini
# /etc/wireguard/wg0.conf

# ============ 接口配置 ============
[Interface]

# 本地私钥 (必需)
PrivateKey = aBNz5OXa+V9VIL3HTN2P8TnMEO1jO+9F0E9h6rPkCXU=

# VPN 内部 IP 地址 (必需)
Address = 10.0.0.1/24

# UDP 监听端口 (可选，默认 51820)
ListenPort = 51820

# DNS 服务器 (可选，客户端使用)
DNS = 1.1.1.1, 8.8.8.8

# 出站标记 (可选，用于 policy routing)
FwMark = 0xca6c

# MTU 设置 (可选，默认自动计算)
MTU = 1420

# 预 Up 命令 (可选)
# PreUp = iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -j MASQUERADE

# ============ 对端配置 ============
[Peer]

# 对端公钥 (必需)
PublicKey = bnECZ+V9VIL3HTN2P8TnMEO1jO+9F0E9h6rPkCXU=

# 预共享密钥 (可选，启用抗量子混合密钥)
PresharedKey = XNKl9O2CXF9VLZ3hN2P8TnMEO1jO+9F0E9h6rPkCXU=

# 对方公网地址和端口 (必需，用于主动连接)
Endpoint = 203.0.113.10:51820

# 允许通过的 IP 范围 (必需，决定哪些流量走 VPN)
AllowedIPs = 10.0.0.2/32, 192.168.1.0/24

# 持久 keepalive (可选，用于 NAT 穿透)
PersistentKeepalive = 25

# ============ 更多对端 ============
[Peer]
PublicKey = another/public/key/here=
AllowedIPs = 10.0.0.3/32
Endpoint = 198.51.100.20:51820
PersistentKeepalive = 25
```

### 3.2 配置字段详解

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      WireGuard 配置字段详解                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  [Interface] 部分:                                                     │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 字段                 │ 必需 │ 说明                               │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │ PrivateKey          │ 是   │ 本机 Curve25519 私钥               │   │
│  │ Address             │ 是   │ VPN 内部 IP/掩码                   │   │
│  │ ListenPort          │ 否   │ UDP 监听端口 (默认 51820)         │   │
│  │ DNS                 │ 否   │ 客户端 DNS 服务器                  │   │
│  │ FwMark              │ 否   │ 出站 fwmark 标记                   │   │
│  │ MTU                 │ 否   │ MTU 值 (默认自动)                  │   │
│  │ PreUp/PostUp        │ 否   │ 启动/关闭时执行的命令              │   │
│  │ PreDown/PostDown    │ 否   │ 关闭前/后执行的命令                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  [Peer] 部分:                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 字段                 │ 必需 │ 说明                               │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │ PublicKey           │ 是   │ 对端 Curve25519 公钥               │   │
│  │ PresharedKey        │ 否   │ 预共享密钥 (抗量子)                │   │
│  │ Endpoint            │ 否*  │ 对端地址 (*服务器端可不填)        │   │
│  │ AllowedIPs          │ 是   │ 允许的 IP 范围                     │   │
│  │ PersistentKeepalive │ 否   │ Keepalive 间隔 (秒)               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.3 AllowedIPs 的作用

AllowedIPs 是 WireGuard 最核心的概念之一：

```bash
# 客户端配置
[Peer]
PublicKey = <Server PublicKey>
AllowedIPs = 0.0.0.0/0, ::/0  # 全部流量走 VPN (full-tunnel)

# 服务器配置
[Peer]
PublicKey = <Client PublicKey>
AllowedIPs = 10.0.0.2/32  # 只允许该客户端 IP

# 路由行为：
# 当内核收到目的地址在 AllowedIPs 范围内的包时
# 会将该包路由到 WireGuard 接口
# 由 WireGuard 加密后发送

# 特殊值：
# 0.0.0.0/0, ::/0  → 全流量 (full-tunnel)
# 10.0.0.0/24      → 特定网段 (split-tunnel)
# 192.168.1.0/24   → 访问内网
```

---

## 4. wg-quick 工具

### 4.1 基础命令

```bash
# 启动接口
wg-quick up wg0

# 关闭接口
wg-quick down wg0

# 查看接口状态
wg show wg0

# 列出所有接口
wg show

# 添加配置 (临时)
wg set wg0 peer <pubkey> allowedips <ip>

# 保存配置
wg showconf wg0 > /etc/wireguard/wg0.conf.backup
```

### 4.2 wg-quick 脚本功能

wg-quick 自动处理：

```bash
# wg-quick up wg0 实际上执行：

# 1. 创建 WireGuard 接口
ip link add wg0 type wireguard

# 2. 设置私钥
ip link set wg0 mtu 1420
wg set wg0 private-key /path/to/private.key

# 3. 设置 IP 地址
ip addr add 10.0.0.1/24 dev wg0

# 4. 启动接口
ip link set wg0 up

# 5. 执行 PostUp (如果有)
# PostUp = iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -j MASQUERADE

# 6. 启动监听
wg set wg0 listen-port 51820
```

### 4.3 NAT 场景下的 PostUp

```ini
# /etc/wireguard/wg0.conf

[Interface]
Address = 10.0.0.1/24
PrivateKey = <server-private-key>

# NAT 场景：VPN 服务器作为网关
PostUp = iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT

# 关闭时清理
PostDown = iptables -t nat -D POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey = <client-public-key>
AllowedIPs = 10.0.0.2/32
```

---

## 5. wg show 状态查看

### 5.1 基本状态

```bash
# 查看所有接口状态
wg show

# 查看 wg0 接口详细信息
wg show wg0

# 输出示例:
# interface: wg0
#   public key: bnECZ+V9VIL3HTN2P8TnMEO1jO+9F0E9h6rPkCXU=
#   private key: (hidden)
#   listening port: 51820
#
# peer: abc123...  # 对端公钥
#   endpoint: 203.0.113.10:51820  # 对端地址
#   allowed ips: 10.0.0.2/32     # 允许的 IP
#   latest handshake: 45 seconds ago  # 上次握手时间
#   transfer: 12.34 MiB received, 56.78 MiB sent  # 流量统计
```

### 5.2 握手状态解析

```
latest handshake 状态解读：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  45 seconds ago                                                  │
│      └── 正常：最近有成功的握手                                  │
│                                                                 │
│  2 minutes, 32 seconds ago                                      │
│      └── 正常：可能有 NAT 映射超时风险                          │
│                                                                 │
│  4 minutes, 23 seconds ago                                      │
│      └── 警告：建议检查网络或增加 PersistentKeepalive           │
│                                                                 │
│  23 hours, 4 minutes, 56 seconds ago                             │
│      └── 异常：握手可能失败，需要排查                            │
│                                                                 │
│  (rotating)                                                     │
│      └── 正在进行握手重试                                        │
│                                                                 │
│  No handshake                                                   │
│      └── 从未成功握手过                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.3 统计信息

```bash
# 查看详细统计
wg show wg0 transfer

# 流量监控 (持续)
watch -n 1 wg show wg0

# 通过 /sys 接口查看
cat /sys/class/net/wg0/statistics/rx_bytes
cat /sys/class/net/wg0/statistics/tx_bytes
```

---

## 6. NAT 穿透配置

### 6.1 NAT 穿透原理

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      WireGuard NAT 穿透                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  WireGuard 使用 UDP，天生支持 NAT 穿透：                                 │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                                                                 │   │
│  │   Client A (NAT 内)              Server (公网)                  │   │
│  │   10.0.0.2:51820                                                │   │
│  │        │                                                         │   │
│  │        │──── SYN ────────────────────▶│ NAT-A 映射创建          │   │
│  │        │        UDP:51820→51820      │                         │   │
│  │        │                              │                         │   │
│  │        │◀──── SYN-ACK ───────────────│                         │   │
│  │        │                              │                         │   │
│  │        │──── ACK ────────────────────▶│ NAT 映射确认            │   │
│  │        │                              │                         │   │
│  │        │                              │                         │   │
│  │        │══════════════════════════════▶│                        │   │
│  │        │        UDP 数据传输            │                        │   │
│  │        │                              │                         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  问题：                                                                │
│  ├─ NAT 映射有超时时间 (通常 60-300 秒)                                │
│  ├─ 超时后外部无法主动发送数据到 NAT 后的客户端                        │
│  └─ 解决方案：PersistentKeepalive                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.2 PersistentKeepalive 配置

```ini
# 客户端配置 - 建议开启
[Peer]
PublicKey = <Server PublicKey>
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25  # 每 25 秒发送 keepalive

# 服务器配置 - 通常不需要
[Peer]
PublicKey = <Client PublicKey>
AllowedIPs = 10.0.0.2/32
# PersistentKeepalive 通常不需要（服务器有公网 IP）
```

### 6.3 Endpoint 动态更新

WireGuard 支持 **roaming**——对端 IP 变化时自动更新：

```
┌─────────────────────────────────────────────────────────────────┐
│                      Endpoint Roaming                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  场景：移动客户端 IP 变化                                          │
│                                                                 │
│  Client 初始:                                                    │
│  ├─ Endpoint: 203.0.113.10:51820                                │
│  └─ NAT 映射: 203.0.113.10:51820 → 10.0.0.2:51820             │
│                                                                 │
│  Client 切换网络 (新 IP):                                         │
│  ├─ 发送数据包到原 Endpoint                                       │
│  ├─ NAT 设备看到新源 IP，更新映射                                 │
│  ├─ Server 收到数据包，从源 IP 学习新地址                        │
│  └─ 自动更新 Endpoint 为新 IP                                    │
│                                                                 │
│  优势：                                                           │
│  ├─ 移动时不断线                                                 │
│  ├─ 无需重新配置                                                 │
│  └─ WireGuard 自动处理                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 进阶配置

### 7.1 Split-Tunnel vs Full-Tunnel

```bash
# Full-Tunnel (全流量) - 客户端配置
[Peer]
PublicKey = <Server PublicKey>
AllowedIPs = 0.0.0.0/0, ::/0  # 所有流量走 VPN

# Split-Tunnel (分流量) - 客户端配置
[Peer]
PublicKey = <Server PublicKey>
AllowedIPs = 10.0.0.0/24, 192.168.1.0/24  # 只有这些网段走 VPN

# 服务器端配合 - 访问内网
[Peer]
PublicKey = <Client PublicKey>
AllowedIPs = 10.0.0.2/32, 192.168.10.0/24  # 允许客户端访问这些网段
```

### 7.2 多站点互联

```ini
# 站点 A (10.0.1.0/24) 配置
[Interface]
Address = 10.0.0.1/24

[Peer]
# 站点 B
PublicKey = <SiteB-PublicKey>
Endpoint = 198.51.100.20:51820
AllowedIPs = 10.0.0.2/32, 10.0.2.0/24  # 本地网段 + 对方网段

[Peer]
# 站点 C
PublicKey = <SiteC-PublicKey>
Endpoint = 203.0.113.30:51820
AllowedIPs = 10.0.0.3/32, 10.0.3.0/24

# 路由会自动添加
# 10.0.2.0/24 via 10.0.0.2 dev wg0
# 10.0.3.0/24 via 10.0.0.3 dev wg0
```

### 7.3 防火墙规则

```bash
# WireGuard 默认端口 51820/UDP
# 防火墙需要开放

# ufw
ufw allow 51820/udp

# iptables
iptables -A INPUT -p udp --dport 51820 -j ACCEPT

# firewalld
firewall-cmd --add-port=51820/udp --permanent

# 同时需要允许 IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
# 持久化
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
```

---

## 8. 常见问题排查

### 8.1 排查流程

```bash
# 1. 检查接口是否启动
ip link show wg0

# 2. 检查 WireGuard 状态
wg show wg0

# 3. 检查握手时间
wg show wg0 | grep handshake

# 4. 检查路由表
ip route show dev wg0

# 5. 检查 UDP 端口
ss -ulnp | grep 51820

# 6. 测试连通性
ping 10.0.0.2  # 对方 VPN IP

# 7. 抓包分析
tcpdump -i wg0 -n
tcpdump -i eth0 -n port 51820 -vv
```

### 8.2 常见问题与解决

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      常见问题与解决方案                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  问题 1: "No handshake"                                                 │
│  ├─ 原因: 网络不通或配置错误                                            │
│  └─ 解决:                                                                │
│     ├─ 检查防火墙是否开放 51820/UDP                                    │
│     ├─ 检查 Endpoint 地址是否正确                                      │
│     ├─ 检查公钥/私钥 是否匹配                                          │
│     └─ 抓包确认 UDP 包是否到达                                          │
│                                                                         │
│  问题 2: "latest handshake: X hours ago"                               │
│  ├─ 原因: 握手超时                                                      │
│  └─ 解决:                                                                │
│     ├─ 检查 NAT 映射是否超时                                           │
│     ├─ 添加/增加 PersistentKeepalive                                   │
│     ├─ 检查网络稳定性                                                  │
│     └─ 服务器端可能需要重启 wg-quick                                   │
│                                                                         │
│  问题 3: 可以握手但无法传输数据                                         │
│  ├─ 原因: AllowedIPs 配置问题                                          │
│  └─ 解决:                                                                │
│     ├─ 检查客户端 AllowedIPs 是否包含 0.0.0.0/0                        │
│     ├─ 检查服务器端 AllowedIPs 是否包含对方 IP                        │
│     ├─ 检查 IP forwarding 是否开启                                      │
│     └─ 检查 NAT/Masquerade 是否配置                                    │
│                                                                         │
│  问题 4: MTU 问题                                                       │
│  ├─ 原因: 分片丢失                                                      │
│  └─ 解决:                                                                │
│     ├─ 减小 MTU: ip link set wg0 mtu 1420                             │
│     ├─ 启用 MSS clamping                                               │
│     └─ 检查路径 MTU discovery                                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.3 日志查看

```bash
# 内核日志
dmesg | grep wireguard
journalctl -u wg-quick@wg0

# 调试模式 (临时)
echo "module wireguard +p" > /sys/kernel/debug/dynamic_debug/control
# 然后查看 dmesg
```

---

## 9. 性能调优

### 9.1 MTU 优化

```
WireGuard MTU 计算：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  以太网 MTU: 1500 bytes                                         │
│                                                                 │
│  WireGuard 开销:                                                │
│  ├─ Outer IP Header: 20 bytes (IPv4)                          │
│  ├─ UDP Header: 8 bytes                                        │
│  ├─ WireGuard Header: 16 bytes (Type + Counter)                │
│  ├─ Poly1305 Tag: 16 bytes                                     │
│  └─ Total: ~60 bytes                                          │
│                                                                 │
│  推荐 MTU:                                                       │
│  ├─ 保守: 1420 bytes (1500 - 80)                               │
│  ├─ 一般: 1440 bytes (1500 - 60)                              │
│  └─ 自动: WireGuard 默认 (通过 Path MTU Discovery)            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 9.2 内核参数优化

```bash
# /etc/sysctl.conf

# IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# WireGuard 相关
# 增加 UDP 缓冲区 (如果性能不足)
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000

# 关闭 rp_filter (如果有多路径)
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.wg0.rp_filter = 0
```

---

## 10. 总结

### 10.1 配置要点

```
┌─────────────────────────────────────────────────────────────────┐
│                   WireGuard 配置要点                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 密钥生成:                                                    │
│     ├─ wg genkey → 私钥                                         │
│     ├─ wg pubkey < 私钥 → 公钥                                  │
│     └─ chmod 600 私钥文件                                        │
│                                                                 │
│  2. 核心配置:                                                    │
│     ├─ Interface: 本机设置 (私钥、IP、端口)                     │
│     └─ Peer: 对端设置 (公钥、Endpoint、AllowedIPs)              │
│                                                                 │
│  3. AllowedIPs 是关键:                                           │
│     ├─ 决定哪些流量走 VPN                                        │
│     ├─ 0.0.0.0/0 = 全流量 (full-tunnel)                        │
│     └─ 10.0.0.0/24 = 特定网段 (split-tunnel)                    │
│                                                                 │
│  4. NAT 穿透:                                                    │
│     ├─ WireGuard 使用 UDP，天生支持                             │
│     ├─ PersistentKeepalive = 25 维持映射                        │
│     └─ Endpoint roaming 自动处理 IP 变化                        │
│                                                                 │
│  5. 排查:                                                        │
│     ├─ wg show 查看状态                                          │
│     ├─ 检查防火墙、端口、密钥匹配                                │
│     └─ 抓包分析 UDP 流量                                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 10.2 快速参考

```bash
# 完整安装和配置流程

# 1. 安装
apt install wireguard

# 2. 生成密钥
wg genkey | tee s_private.key | wg pubkey > s_public.key
wg genkey | tee c_private.key | wg pubkey > c_public.key

# 3. 服务器配置
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $(cat s_private.key)

[Peer]
PublicKey = $(cat c_public.key)
AllowedIPs = 10.0.0.2/32
EOF

# 4. 客户端配置
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.2/24
PrivateKey = $(cat c_private.key)

[Peer]
PublicKey = $(cat s_public.key)
Endpoint = <server-ip>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# 5. 启动
wg-quick up wg0
wg-quick down wg0

# 6. 验证
wg show
ping 10.0.0.1
```

---

## 外部参考

- [WireGuard 官方快速入门](https://www.wireguard.com/quickstart/)
- [WireGuard 配置示例](https://github.com/practicalwireguard/guides)
- [wg-quick 源码](https://git.zx2c4.com/wireguard-tools)
- [Ubuntu WireGuard 教程](https://ubuntu.com/tutorials/install-and-configure-wireguard)
