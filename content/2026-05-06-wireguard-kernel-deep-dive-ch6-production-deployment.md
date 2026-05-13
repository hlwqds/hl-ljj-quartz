---
title: WireGuard 内核深度探索 Ch6：生产部署与调优
date: 2026-05-06 09:00:00
tags: [WireGuard, Production, Deployment, Kubernetes, Docker, Systemd, Monitoring, Prometheus, Grafana, Troubleshooting, Security, Hardening, High Availability, Load Balancing, Firewall, Iptables, Failover]
description: WireGuard 生产环境实战指南：Docker/Kubernetes 部署、Systemd 管理、监控告警、故障排除、安全加固、高可用设计与性能调优。
---

# WireGuard 内核深度探索 Ch6：生产部署与调优

## 1. 概述

```
Ch6 生产部署与调优：

本章内容：
  1. 部署方案
  2. Docker 部署
  3. Kubernetes 部署
  4. Systemd 管理
  5. 监控告警
  6. 故障排除
  7. 安全加固
  8. 高可用设计
```

---

## 2. 部署方案

### 2.1 部署架构

```
WireGuard 部署架构：

┌──────────────────────────────────────────────────────────────────────┐
│                        单机部署                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌────────────────┐                                                │
│   │   Client A    │                                                │
│   │   10.0.0.2    │                                                │
│   └───────┬────────┘                                                │
│           │ WireGuard (UDP 51820)                                  │
│           │                                                          │
│           ▼                                                          │
│   ┌────────────────────────────────────────────────────────────┐   │
│   │                    Server (VPS/Dedicated)                  │   │
│   │                                                          │   │
│   │   eth0: 1.2.3.4 (公网)                                   │   │
│   │   wg0: 10.0.0.1/24                                      │   │
│   │                                                          │   │
│   │   ┌──────────────────────────────────────────────────┐   │   │
│   │   │              WireGuard Kernel Module              │   │   │
│   │   │              (drivers/net/wireguard/)             │   │   │
│   │   └──────────────────────────────────────────────────┘   │   │
│   │                                                          │   │
│   └────────────────────────────────────────────────────────────┘   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        网状部署 (Mesh)                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐                       │
│   │ Client A│◄──►│ Client B│◄──►│ Client C│                       │
│   │ 10.0.0.2│    │ 10.0.0.3│    │ 10.0.0.4│                       │
│   └────┬────┘    └────┬────┘    └────┬────┘                       │
│        │               │               │                            │
│        └───────────────┴───────────────┘                            │
│        WireGuard 全互联 (Full Mesh)                                  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        星型部署 (Hub-Spoke)                          │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│                         ┌─────────┐                                  │
│                         │  Hub    │                                  │
│                         │ 10.0.0.1│                                  │
│                         └───┬─────┘                                  │
│                    ┌───────┼───────┐                                │
│                    │       │       │                                │
│                    ▼       ▼       ▼                                │
│               ┌─────────┐ ┌─────────┐ ┌─────────┐                  │
│               │Spoke A  │ │Spoke B  │ │Spoke C  │                  │
│               │10.0.0.2 │ │10.0.0.3 │ │10.0.0.4 │                  │
│               └─────────┘ └─────────┘ └─────────┘                  │
│                                                                      │
│   所有流量经过 Hub 转发                                               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 密钥生成

```bash
#!/bin/bash
# generate_keys.sh — 生成 WireGuard 密钥

echo "=== WireGuard 密钥生成 ==="

# 1. 生成服务器密钥
wg genkey | tee server_private.key | wg pubkey > server_public.key

# 2. 生成客户端密钥
wg genkey | tee client_private.key | wg pubkey > client_public.key

# 3. 生成预共享密钥（抗量子）
wg genpsk > preshared.key

# 4. 设置权限
chmod 600 *.key

echo ""
echo "=== 密钥文件 ==="
echo "服务器私钥: $(cat server_private.key)"
echo "服务器公钥: $(cat server_public.key)"
echo "客户端公钥: $(cat client_public.key)"
echo "预共享密钥: $(cat preshared.key)"

echo ""
echo "=== 复制到安全位置 ==="
mv *.key /etc/wireguard/
chmod 600 /etc/wireguard/*.key
```

---

## 3. Docker 部署

### 3.1 Dockerfile

```dockerfile
# Dockerfile — WireGuard 服务器

FROM ubuntu:22.04

LABEL maintainer="admin@example.com"
LABEL description="WireGuard VPN Server"

# 安装依赖
RUN apt-get update && apt-get install -y \
    wireguard \
    iptables \
    iproute2 \
    iputils-ping \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 创建目录
RUN mkdir -p /etc/wireguard /opt/wireguard/logs

# 复制配置
COPY wg0.conf /etc/wireguard/wg0.conf
COPY keys/ /etc/wireguard/keys/

# 设置权限
RUN chmod 600 /etc/wireguard/*.key \
    && chmod 644 /etc/wireguard/wg0.conf

# 暴露端口
EXPOSE 51820/udp

# 启动脚本
COPY start.sh /opt/wireguard/start.sh
RUN chmod +x /opt/wireguard/start.sh

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ping -c 1 10.0.0.1 || exit 1

ENTRYPOINT ["/opt/wireguard/start.sh"]
CMD ["wg-quick", "up", "wg0"]
```

### 3.2 启动脚本

```bash
#!/bin/bash
# start.sh — WireGuard 启动脚本

set -e

# 配置
CONF="/etc/wireguard/wg0.conf"
LOG="/opt/wireguard/logs/wireguard.log"

echo "[$(date)] WireGuard starting..." >> $LOG

# 启用 IP 转发
echo 1 > /proc/sys/net/ipv4/ip_forward

# 启用 NAT
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# 启动 WireGuard
exec "$@"
```

### 3.3 docker-compose

```yaml
# docker-compose.yml — WireGuard 服务编排

version: '3.8'

services:
  wireguard:
    image: wireguard:latest
    container_name: wireguard
    hostname: wireguard-server

    # 网络模式
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun

    # 挂载配置
    volumes:
      - ./config:/etc/wireguard
      - ./logs:/opt/wireguard/logs
      - /lib/modules:/lib/modules:ro

    # 环境
    environment:
      - TZ=Asia/Shanghai

    # 重启
    restart: unless-stopped

    # 健康检查
    healthcheck:
      test: ["CMD", "wg", "show", "wg0"]
      interval: 30s
      timeout: 10s
      retries: 3

  # 可选：监控导出器
  prometheus-exporter:
    image: prometheus-exporter:latest
    container_name: wireguard-exporter
    network_mode: host
    depends_on:
      - wireguard
    restart: unless-stopped
```

### 3.4 运行

```bash
#!/bin/bash
# run_wireguard.sh — 运行 WireGuard

# 1. 构建镜像
docker build -t wireguard:latest .

# 2. 准备配置
mkdir -p config keys logs
chmod 700 config keys

# 3. 生成密钥
cd keys
wg genkey | tee private | wg pubkey > public
cd ..

# 4. 创建配置
cat > config/wg0.conf <<EOF
[Interface]
PrivateKey = $(cat keys/private)
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = <CLIENT_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY>
AllowedIPs = 10.0.0.2/32
EOF

# 5. 启动
docker-compose up -d

# 6. 查看状态
docker exec wireguard wg show

# 7. 查看日志
docker logs -f wireguard
```

---

## 4. Kubernetes 部署

### 4.1 DaemonSet

```yaml
# wireguard-daemonset.yaml — Kubernetes DaemonSet

apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wireguard
  namespace: kube-system
  labels:
    app: wireguard
spec:
  selector:
    matchLabels:
      app: wireguard
  template:
    metadata:
      labels:
        app: wireguard
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: wireguard
        image: linuxserver/wireguard:latest
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
          capabilities:
            add:
              - NET_ADMIN
              - SYS_MODULE
        env:
        - name: TZ
          value: "Asia/Shanghai"
        - name: SERVERPORT
          value: "51820"
        - name: PEERS
          value: "10"
        - name: INTERNAL_SUBNET
          value: "10.0.0.0/24"
        - name: ALLOWEDIPS
          value: "0.0.0.0/0"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
        volumeMounts:
        - name: config
          mountPath: /config
        - name: modules
          mountPath: /lib/modules
          readOnly: true
      volumes:
      - name: config
        emptyDir: {}
      - name: modules
        hostPath:
          path: /lib/modules
      tolerations:
      - operator: Exists
```

### 4.2 Helm 部署

```bash
#!/bin/bash
# helm_install_wireguard.sh — Helm 安装 WireGuard

# 1. 添加 repo
helm repo add wireguard https://charts.delvtech.io
helm repo update

# 2. 创建 namespace
kubectl create namespace wireguard

# 3. 配置 values
cat > values.yaml <<EOF
image:
  repository: linuxserver/wireguard
  tag: latest

podSecurityPolicy:
  enabled: true

service:
  enabled: true
  type: LoadBalancer
  port: 51820
  annotations:
    prometheus.io/scrape: "true"

env:
  TZ: Asia/Shanghai
  PEERS: "10"
  INTERNAL_SUBNET: "10.0.0.0/24"

persistence:
  enabled: true
  size: 1Gi
  storageClass: "standard"

resources:
  limits:
    cpu: 500m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi
EOF

# 4. 安装
helm install wireguard wireguard/wireguard \
  -n wireguard \
  -f values.yaml

# 5. 查看状态
kubectl get pods -n wireguard
kubectl get svc -n wireguard

# 6. 获取客户端配置
kubectl get secret wireguard-config -n wireguard \
  -o jsonpath='{.data.config}' | base64 -d > wg0.conf
```

### 4.3 Cilium 集成

```yaml
# cilium_wireguard.yaml — Cilium + WireGuard 集成

apiVersion: cilium.io/v2alpha1
kind: CiliumClusterwideEnvoyConfig
metadata:
  name: wireguard-envoy
spec:
  # 通过 Envoy 代理 WireGuard 流量
  services:
  - name: wireguard
    namespace: wireguard
    ports:
    - port: 51820
      protocol: UDP
```

---

## 5. Systemd 管理

### 5.1 服务文件

```ini
# /etc/systemd/system/wireguard@.service
# WireGuard Systemd 服务

[Unit]
Description=WireGuard VPN Server (%i)
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
PartOf=wireguard.target
ReloadPropagatedFrom=wireguard.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up %i
ExecStop=/usr/bin/wg-quick down %i
ExecReload=/usr/bin/wg-quick reload %i

# 权限
ExecStartPost=/sbin/iptables -A FORWARD -i %i -j ACCEPT
ExecStartPost=/sbin/iptables -A FORWARD -o %i -j ACCEPT
ExecStartPost=/sbin/iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ExecStopPost=/sbin/iptables -D FORWARD -i %i -j ACCEPT
ExecStopPost=/sbin/iptables -D FORWARD -o %i -j ACCEPT
ExecStopPost=/sbin/iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# 日志
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wireguard-%i

# 安全
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/wireguard /run

[Install]
WantedBy=multi-user.target
```

### 5.2 单元文件

```ini
# /etc/systemd/system/wireguard.target
# WireGuard Target

[Unit]
Description=WireGuard VPN Targets
After=network-online.target
Wants=network-online.target

[Install]
WantedBy=multi-user.target
```

### 5.3 管理命令

```bash
#!/bin/bash
# wireguard_manager.sh — WireGuard 管理脚本

WG_INTERFACE="wg0"
LOG="/var/log/wireguard.log"

case "$1" in
    start)
        echo "[$(date)] Starting WireGuard..." >> $LOG
        systemctl start wireguard@${WG_INTERFACE}
        systemctl status wireguard@${WG_INTERFACE} --no-pager
        ;;

    stop)
        echo "[$(date)] Stopping WireGuard..." >> $LOG
        systemctl stop wireguard@${WG_INTERFACE}
        ;;

    restart)
        echo "[$(date)] Restarting WireGuard..." >> $LOG
        systemctl restart wireguard@${WG_INTERFACE}
        ;;

    status)
        wg show ${WG_INTERFACE}
        systemctl status wireguard@${WG_INTERFACE} --no-pager
        ;;

    add-peer)
        if [ -z "$2" ]; then
            echo "Usage: $0 add-peer <public_key>"
            exit 1
        fi
        PEER_KEY="$2"
        PEER_IP="${3:-10.0.0.$((RANDOM % 254 + 2))}"

        echo "[$(date)] Adding peer: $PEER_KEY" >> $LOG
        wg set ${WG_INTERFACE} peer ${PEER_KEY} allowed-ips ${PEER_IP}/32
        echo "Added peer with IP: ${PEER_IP}"
        ;;

    remove-peer)
        if [ -z "$2" ]; then
            echo "Usage: $0 remove-peer <public_key>"
            exit 1
        fi
        PEER_KEY="$2"

        echo "[$(date)] Removing peer: $PEER_KEY" >> $LOG
        wg set ${WG_INTERFACE} peer ${PEER_KEY} remove
        ;;

    list-peers)
        wg show ${WG_INTERFACE} peers
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status|add-peer|remove-peer|list-peers}"
        exit 1
        ;;
esac
```

---

## 6. 监控告警

### 6.1 Prometheus 导出器

```python
# wireguard_exporter.py — WireGuard Prometheus 导出器

from prometheus_client import start_http_server, Gauge, Counter
import subprocess
import time
import re

# 指标定义
wg_peers = Gauge('wireguard_peers_total', 'Total number of WireGuard peers')
wg_rx_bytes = Counter('wireguard_rx_bytes_total', 'Total received bytes')
wg_tx_bytes = Counter('wireguard_tx_bytes_total', 'Total transmitted bytes')
wg_rx_packets = Counter('wireguard_rx_packets_total', 'Total received packets')
wg_tx_packets = Counter('wireguard_tx_packets_total', 'Total transmitted packets')
wg_last_handshake = Gauge('wireguard_peer_last_handshake_seconds',
                           'Last handshake time in seconds', ['peer'])

def collect_wg_stats():
    """收集 WireGuard 统计"""
    try:
        result = subprocess.run(['wg', 'show', 'wg0'],
                              capture_output=True, text=True)
        output = result.stdout

        # 解析 peers
        peers = re.findall(r'peer: ([^\s]+)', output)
        wg_peers.set(len(peers))

        # 解析 transfer
        rx_match = re.search(r'received:\s+(\d+)', output)
        tx_match = re.search(r'sent:\s+(\d+)', output)
        if rx_match:
            wg_rx_bytes.inc(int(rx_match.group(1)))
        if tx_match:
            wg_tx_bytes.inc(int(tx_match.group(1)))

        # 解析 handshake
        for match in re.finditer(r'peer: ([^\s]+)\n\s+last handshake:\s+(.+)', output):
            peer = match.group(1)
            handshake = match.group(2)
            # 解析时间并转换
            wg_last_handshake.labels(peer=peer).set(parse_handshake(handshake))

    except Exception as e:
        print(f"Error collecting stats: {e}")

def main():
    start_http_server(9586)
    print("WireGuard exporter listening on :9586")

    while True:
        collect_wg_stats()
        time.sleep(15)

if __name__ == '__main__':
    main()
```

### 6.2 Grafana Dashboard

```json
{
  "dashboard": {
    "title": "WireGuard VPN",
    "uid": "wireguard-vpn",
    "panels": [
      {
        "title": "Active Peers",
        "type": "stat",
        "targets": [
          {
            "expr": "wireguard_peers_total",
            "legendFormat": "Peers"
          }
        ]
      },
      {
        "title": "Traffic (bytes)",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(wireguard_rx_bytes_total[5m])",
            "legendFormat": "RX"
          },
          {
            "expr": "rate(wireguard_tx_bytes_total[5m])",
            "legendFormat": "TX"
          }
        ]
      },
      {
        "title": "Packets",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(wireguard_rx_packets_total[5m])",
            "legendFormat": "RX pps"
          },
          {
            "expr": "rate(wireguard_tx_packets_total[5m])",
            "legendFormat": "TX pps"
          }
        ]
      }
    ]
  }
}
```

### 6.3 告警规则

```yaml
# alert_rules.yaml — Prometheus 告警规则

groups:
  - name: wireguard
    rules:
    - alert: WireGuardDown
      expr: up{job="wireguard"} == 0
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "WireGuard is down"
        description: "WireGuard exporter is not responding"

    - alert: NoActivePeers
      expr: wireguard_peers_total == 0
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "No active WireGuard peers"
        description: "There are no active WireGuard peers connected"

    - alert: HighPacketLoss
      expr: rate(wireguard_rx_packets_total[5m]) == 0 and rate(wireguard_tx_packets_total[5m]) > 1000
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High packet loss detected"
        description: "Possible packet loss on WireGuard tunnel"

    - alert: PeerHandshakeTimeout
      expr: time() - wireguard_peer_last_handshake_seconds > 300
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Peer handshake timeout"
        description: "Peer {{ $labels.peer }} has not handshake in 5 minutes"
```

---

## 7. 故障排除

### 7.1 常见问题

```
WireGuard 常见问题：

┌──────────────────────────────────────────────────────────────────────┐
│  问题 1: 无法建立连接                                               │
├──────────────────────────────────────────────────────────────────────┤
│  可能原因：                                                         │
│    · 防火墙阻止 UDP 51820                                          │
│    · 公网 IP 无法访问                                              │
│    · 密钥不匹配                                                    │
│    · 配置错误                                                      │
│                                                                      │
│  排查步骤：                                                         │
│    $ wg show                                                      │
│    $ netstat -ulnp | grep 51820                                  │
│    $ iptables -L -n | grep 51820                                   │
│    $ tail -f /var/log/wireguard.log                               │
│                                                                      │
│  解决方案：                                                         │
│    · 开放防火墙：ufw allow 51820/udp                              │
│    · 检查 NAT 映射                                                  │
│    · 核对公私钥                                                    │
│    · 重启 WireGuard                                               │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  问题 2: 隧道建立但无流量                                           │
├──────────────────────────────────────────────────────────────────────┤
│  可能原因：                                                         │
│    · AllowedIPs 配置错误                                           │
│    · 路由问题                                                      │
│    · NAT 问题                                                      │
│                                                                      │
│  排查步骤：                                                         │
│    $ wg show                                                      │
│    $ ip route show table all                                      │
│    $ ping 10.0.0.1                                                │
│    $ tcpdump -i wg0                                              │
│                                                                      │
│  解决方案：                                                         │
│    · 设置 AllowedIPs = 0.0.0.0/0（流量路由到 VPN）                  │
│    · 添加路由：ip route add default dev wg0                       │
│    · 检查 MASQUERADE                                              │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  问题 3: 性能下降                                                  │
├──────────────────────────────────────────────────────────────────────┤
│  可能原因：                                                         │
│    · CPU 负载高                                                    │
│    · 网络延迟                                                      │
│    · MTU 问题                                                     │
│    · 丢包                                                          │
│                                                                      │
│  排查步骤：                                                         │
│    $ top                                                           │
│    $ wg show                                                      │
│    $ ping -s 1500 <peer_ip>                                      │
│    $ ip -s link show wg0                                         │
│                                                                      │
│  解决方案：                                                         │
│    · 降低 MTU：mtu 1420                                           │
│    · 启用压缩：Compression = yes                                   │
│    · 优化内核参数                                                  │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  问题 4: 隧道频繁断开                                              │
├──────────────────────────────────────────────────────────────────────┤
│  可能原因：                                                         │
│    · keepalive 配置不当                                           │
│    · NAT 超时                                                      │
│    · 网络不稳定                                                    │
│                                                                      │
│  排查步骤：                                                         │
│    $ wg show                                                      │
│    $ journalctl -u wireguard@wg0 -f                              │
│                                                                      │
│  解决方案：                                                         │
│    · 设置 keepalive：PersistentKeepalive = 25                     │
│    · 调整 NAT 超时                                                  │
│    · 检查网络稳定性                                                │
└──────────────────────────────────────────────────────────────────────┘
```

### 7.2 调试命令

```bash
#!/bin/bash
# debug_wireguard.sh — WireGuard 调试脚本

echo "=== WireGuard 调试 ==="

# 1. 基本信息
echo "[1] WireGuard 状态:"
wg show || echo "WireGuard 未运行"

# 2. 网卡信息
echo ""
echo "[2] WireGuard 网卡:"
ip link show wg0 2>/dev/null || echo "wg0 不存在"

# 3. IP 配置
echo ""
echo "[3] IP 配置:"
ip addr show wg0 2>/dev/null || echo "wg0 无 IP"

# 4. 路由表
echo ""
echo "[4] 路由表:"
ip route show dev wg0 2>/dev/null || echo "wg0 无路由"

# 5. 端口监听
echo ""
echo "[5] UDP 端口:"
netstat -ulnp 2>/dev/null | grep 51820 || echo "51820 未监听"

# 6. 防火墙规则
echo ""
echo "[6] 防火墙规则:"
iptables -L -n -v 2>/dev/null | grep -E "wg|51820" || echo "无 WireGuard 规则"

# 7. 系统日志
echo ""
echo "[7] 最近日志:"
journalctl -u wireguard@wg0 -n 20 --no-pager 2>/dev/null || echo "无日志"

# 8. 性能统计
echo ""
echo "[8] 接口统计:"
ip -s link show wg0 2>/dev/null || echo "无统计"

# 9. NAT 表
echo ""
echo "[9] NAT 表:"
iptables -t nat -L -n -v 2>/dev/null | grep -E "MASQ|POST" || echo "无 NAT"

# 10. 连接跟踪
echo ""
echo "[10] 连接跟踪:"
cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A"

echo ""
echo "=== 调试完成 ==="
```

---

## 8. 安全加固

### 8.1 内核参数

```bash
#!/bin/bash
# security_hardening.sh — 安全加固

echo "=== WireGuard 安全加固 ==="

# 1. 禁用 ICMP redirect
cat >> /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# 禁用 source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# 启用 rp_filter
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# 禁用 ICMP ping
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF

sysctl -p /etc/sysctl.d/99-wireguard.conf

# 2. 防火墙规则
cat > /etc/iptables/rules.v4 <<EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# 允许本地
-A INPUT -i lo -j ACCEPT

# 允许 WireGuard
-A INPUT -p udp --dport 51820 -j ACCEPT

# 允许已建立连接
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 允许 ICMP
-A INPUT -p icmp -j ACCEPT

# 允许 SSH
-A INPUT -p tcp --dport 22 -j ACCEPT

# 日志drop
-A INPUT -j LOG --log-prefix "IPTABLES DROP: "
-A INPUT -j DROP

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# NAT for WireGuard
-A POSTROUTNG -s 10.0.0.0/24 -o eth0 -j MASQUERADE

COMMIT
EOF

# 3. 应用防火墙
iptables-restore < /etc/iptables/rules.v4

echo "=== 安全加固完成 ==="
```

### 8.2 WireGuard 配置加固

```ini
# /etc/wireguard/wg0.conf — 加固配置

[Interface]
# 私钥（必须保护）
PrivateKey = <PRIVATE_KEY>

# 本地地址
Address = 10.0.0.1/24

# 监听端口
ListenPort = 51820

# DNS（防止 DNS 泄露）
DNS = 1.1.1.1, 1.0.0.1

# 防泄露
Table = off
PreUp = sysctl -w net.ipv4.conf.%i.conf.all.rp_filter=1
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# 关闭不需要的功能
# Table = off (禁用自动路由)
# SaveConfig = false (禁止运行时保存)

[Peer]
# 客户端公钥
PublicKey = <CLIENT_PUBLIC_KEY>

# 预共享密钥（抗量子）
PresharedKey = <PRESHARED_KEY>

# 允许的 IP（限制访问范围）
AllowedIPs = 10.0.0.2/32

# 持久 keepalive（保持 NAT 映射）
PersistentKeepalive = 25
```

---

## 9. 高可用设计

### 9.1 主备模式

```
WireGuard 高可用架构：

┌──────────────────────────────────────────────────────────────────────┐
│                        主备模式                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│                    ┌─────────────┐                                   │
│                    │  LB / VIP  │                                   │
│                    │  1.2.3.4   │                                   │
│                    └──────┬──────┘                                   │
│                           │                                          │
│               ┌───────────┴───────────┐                              │
│               │                       │                              │
│               ▼                       ▼                              │
│        ┌─────────────┐        ┌─────────────┐                      │
│        │  Master     │        │  Backup     │                      │
│        │  wg0        │◄──────►│  wg0        │                      │
│        │  1.2.3.5   │  VRRP  │  1.2.3.6   │                      │
│        └──────┬──────┘        └─────────────┘                      │
│               │                                                  │
│               │ WireGuard                                         │
│               │                                                   │
│               ▼                                                   │
│        ┌─────────────┐                                          │
│        │   Client    │                                          │
│        └─────────────┘                                          │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 9.2 负载均衡

```nginx
# nginx stream 配置 — WireGuard UDP 负载均衡

stream {
    upstream wireguard {
        server 10.0.0.2:51820;
        server 10.0.0.3:51820;
        server 10.0.0.4:51820;
    }

    server {
        listen 51820 udp;
        proxy_pass wireguard;
        proxy_timeout 3s;
        proxy_responses 0;  # UDP 无响应
    }
}
```

---

## 10. 小结

```
WireGuard 生产部署总结：

部署方式：
  · 独立部署：Systemd 管理，简单直接
  · Docker：隔离性好，易于管理
  · Kubernetes：DaemonSet 或 Helm
  · 云平台：VPS/专用服务器

监控告警：
  · Prometheus 导出器
  · Grafana Dashboard
  · 告警规则
  · 日志收集

故障排除：
  · 连接问题：防火墙/端口/密钥
  · 流量问题：路由/NAT/MTU
  · 性能问题：CPU/延迟/丢包
  · 稳定性：keepalive/NAT超时

安全加固：
  · 内核参数优化
  · 防火墙规则
  · 最小权限
  · 密钥保护

高可用：
  · 主备 VRRP
  · 负载均衡
  · 健康检查
  · 自动切换

WireGuard 内核深度探索系列总结（6 章完成）：

  Ch1: 内核架构与初始化
  - 模块结构
  - 核心数据结构
  - 设备初始化
  - Socket 管理
  - Peer 管理
  - 加密队列

  Ch2: 加密引擎与 Key 管理
  - Noise 握手协议
  - ChaCha20-Poly1305 AEAD
  - 密钥派生
  - 密钥轮换
  - Cookie 验证

  Ch3: 数据包发送路径
  - wg_xmit 入口
  - AllowedIPs 路由
  - 加密队列
  - UDP 封装

  Ch4: 数据包接收路径
  - Socket 接收
  - 握手处理
  - 解密与防重放
  - 协议栈注入

  Ch5: WireGuard vs 内核网络栈
  - 性能对比
  - 开销分析
  - 适用场景
  - 调优建议

  Ch6: 生产部署与调优
  - Docker/Kubernetes 部署
  - Systemd 管理
  - 监控告警
  - 故障排除
  - 安全加固
```

---

## 延伸阅读

- WireGuard 官网: https://www.wireguard.com/
- WireGuard 快速入门: https://www.wireguard.com/quickstart/
- WireGuard 容器: https://docs.linuxserver.io/images/docker-wireguard
- Kubernetes WireGuard: https://github.com/boerman/compute-engine-wireguard
- Prometheus: https://prometheus.io/
- Grafana: https://grafana.com/
- Cloudflare: "WireGuard in production": https://blog.cloudflare.com/tag/wireguard/
- Linode: "WireGuard VPN": https://www.linode.com/docs/
