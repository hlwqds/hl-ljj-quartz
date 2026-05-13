---
title: AF_XDP 深度探索 Ch6：生产环境实战与调优
date: 2026-04-30 09:00:00
tags:
  [
    AF_XDP,
    Production,
    Deployment,
    Tuning,
    Monitoring,
    Troubleshooting,
    Performance,
    Kernel,
    NIC,
    RSS,
    NUMA,
    Hugepage,
    BPF,
    iproute2,
    ethtool,
    Systemd,
    Docker,
    Kubernetes,
    Cilium,
    High Availability,
    Security,
    Hardening,
  ]
description: AF_XDP 生产环境实战指南：环境配置、部署方案、监控排错、调优参数、HA设计、安全加固，以及在 Kubernetes/DPDK 环境中的最佳实践。
---

# AF_XDP 深度探索 Ch6：生产环境实战与调优

## 1. 生产环境规划

### 1.1 硬件选型

```
AF_XDP 生产环境硬件选型：

┌──────────────────────────────────────────────────────────────────────┐
│                        硬件选型建议                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  网卡（必须支持 XDP native 模式）：                                  │
│                                                                      │
│  ★★★★★ Mellanox ConnectX-6/7 (mlx5)                              │
│     · 完整 AF_XDP ZEROCOPY 支持                                    │
│     · 100GbE / 200GbE / 400GbE                                    │
│     · ROCE v2 支持                                                 │
│     · 最佳性能，推荐用于生产环境                                    │
│                                                                      │
│  ★★★★ Intel E810 (ice)                                           │
│     · 完整 XDP 支持                                                │
│     · 100GbE                                                      │
│     · AVX-512 加速                                                │
│     · 性价比高                                                     │
│                                                                      │
│  ★★★ Intel XL710 / X710 (i40e/ixgbe)                             │
│     · 部分 XDP 支持（ZEROCOPY 有限）                               │
│     · 40GbE / 10GbE                                               │
│     · 可用于开发/测试                                              │
│                                                                      │
│  ★★  其他驱动                                                      │
│     · 通用模式（skb 回退）可工作，但性能下降                        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        CPU 选型                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  核心要求：                                                          │
│  · 支持 AVX-512（数据包处理加速）                                  │
│  · 高频率（3.5GHz+）                                               │
│  · 多核心（16+ 核心用于网络处理）                                  │
│                                                                      │
│  推荐：                                                              │
│  · Intel Xeon Scalable (Ice Lake / Sapphire Rapids)                │
│  · AMD EPYC (Milan / Genoa)                                       │
│                                                                      │
│  不推荐：                                                            │
│  · 低端 CPU（性能不足）                                            │
│  · 移动版/桌面版（不稳定）                                         │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        内存选型                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  容量：                                                              │
│  · 基础：32GB（适合 10GbE 中等负载）                               │
│  · 推荐：64GB-256GB（适合 100GbE 高吞吐）                         │
│                                                                      │
│  类型：                                                              │
│  · DDR4-3200 / DDR5                                                │
│  · 必须支持 hugepage（2MB 或 1GB）                                │
│                                                                      │
│  NUMA：                                                              │
│  · 必须正确配置 NUMA                                                │
│  · 网卡应连接到 CPU socket 0（如果可能）                             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.2 操作系统要求

```
OS 要求：

┌──────────────────────────────────────────────────────────────────────┐
│                        内核版本                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  最低：Linux 4.18（XDP 基础功能）                                   │
│                                                                      │
│  推荐：Linux 5.10+（稳定 + 优化）                                   │
│                                                                      │
│  最佳：Linux 6.1+（最新特性 + 修复）                               │
│                                                                      │
│  内核配置必需项：                                                    │
│  CONFIG_XDP_SOCKETS=y                                               │
│  CONFIG_BPF=y                                                       │
│  CONFIG_BPF_SYSCALL=y                                               │
│  CONFIG_BPF_JIT=y                                                   │
│  CONFIG_CGROUPS=y                                                   │
│  CONFIG_KPROBES=y                                                   │
│  CONFIG_NET_INGRESS=y                                               │
│  CONFIG_NET_EGRESS=y                                               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        发行版推荐                                    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ★★★★★ Ubuntu 22.04 LTS / 24.04 LTS                                │
│     · 5.15+ / 6.x 内核                                             │
│     · 官方支持 Mellanox/Intel 驱动                                  │
│     · 最佳生产选择                                                  │
│                                                                      │
│  ★★★★ Red Hat Enterprise Linux 9.x                                │
│     · 5.14+ 内核（RHEL 9.2+）                                      │
│     · 长期支持                                                      │
│     · 企业级支持                                                    │
│                                                                      │
│  ★★★ Debian 12+                                                     │
│     · 6.x 内核                                                      │
│     · 灵活配置                                                      │
│                                                                      │
│  ★★  其他发行版                                                     │
│     · 确保内核版本满足要求                                          │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.3 部署架构

```
生产部署架构：

┌──────────────────────────────────────────────────────────────────────┐
│                        物理部署                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Layer 2 Switch (100GbE)                   │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│        ┌─────────────────────┼─────────────────────┐             │
│        │                     │                     │               │
│        ▼                     ▼                     ▼               │
│  ┌──────────┐         ┌──────────┐         ┌──────────┐           │
│  │ Server 1 │         │ Server 2 │         │ Server 3 │           │
│  │ (Active) │◄───────►│ (Standby)│◄──────►│ (Active) │           │
│  │          │         │          │         │          │           │
│  │ eth0     │         │ eth0     │         │ eth0     │           │
│  │ (data)   │         │ (data)   │         │ (data)   │           │
│  │          │         │          │         │          │           │
│  │ eth1     │         │ eth1     │         │ eth1     │           │
│  │ (mgmt)   │         │ (mgmt)   │         │ (mgmt)   │           │
│  └──────────┘         └──────────┘         └──────────┘           │
│                                                                      │
│  数据面：100GbE（数据网络）                                          │
│  管理面：1GbE（eth1，带外管理）                                      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        HA 部署                                       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Load Balancer                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│         ┌────────────────────┼────────────────────┐              │
│         ▼                    ▼                    ▼               │
│  ┌────────────┐      ┌────────────┐      ┌────────────┐          │
│  │   Node A   │      │   Node B   │      │   Node C   │          │
│  │  (AF_XDP)  │◄───►│  (AF_XDP)  │◄───►│  (AF_XDP)  │          │
│  │   Active   │      │   Active   │      │   Active   │          │
│  └────────────┘      └────────────┘      └────────────┘          │
│                                                                      │
│  HA 方案：                                                           │
│  · L2: MC-LAG / VPC                                                │
│  · L3: ECMP + BFD                                                  │
│  · 应用层: Keepalived / VRRP                                       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. 内核参数配置

### 2.1 系统级参数

```bash
#!/bin/bash
# sysctl_tuning.sh — 系统级参数调优

# ========================
# 内核模块加载
# ========================

cat >> /etc/modules-load.d/xdp.conf <<EOF
af_xdp
bpf
xdp_dummy
EOF

modprobe af_xdp
modprobe bpf

# ========================
# 网络参数
# ========================

cat >> /etc/sysctl.d/99-xdp-network.conf <<EOF
# 禁用 arp 过滤（XDP 环境可能需要）
net.ipv4.conf.all.arp_filter = 0
net.ipv4.conf.default.arp_filter = 0

# 增大 ring buffer
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216

# 增大 backlog
net.core.netdev_max_backlog = 100000
net.core.netdev_backlog = 100000

# BPF JIT
net.core.bpf_jit_enable = 1
net.core.bpf_jit_harden = 0

# TCP 参数（按需调整）
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_fin_timeout = 15

# 禁用 iptables（XDP 已处理）
net.netfilter.nf_conntrack_max = 8192
EOF

sysctl -p /etc/sysctl.d/99-xdp-network.conf

# ========================
# hugepage 配置
# ========================

cat >> /etc/sysctl.d/99-hugepage.conf <<EOF
# 2MB hugepages（推荐 256-1024）
vm.nr_hugepages = 512

# 1GB hugepages（可选，高性能场景）
# vm.nr_overcommit_hugepages = 4
EOF

sysctl -p /etc/sysctl.d/99-hugepage.conf

# ========================
# CPU 调度
# ========================

cat >> /etc/sysctl.d/99-cpu.conf <<EOF
# 禁用 kernel scheduler 的 numa balancing（应用自己处理）
kernel.numa_balancing = 0

# 禁用 ASLR（可能导致调试困难）
kernel.randomize_va_space = 0
EOF

sysctl -p /etc/sysctl.d/99-cpu.conf

echo "=== 内核参数配置完成 ==="
```

### 2.2 网卡配置

```bash
#!/bin/bash
# nic_tuning.sh — 网卡调优

IFACE="${1:-eth0}"

echo "=== 网卡配置: ${IFACE} ==="

# 1. 巨型帧
ip link set ${IFACE} mtu 9000

# 2. 启用 rx/tx offload（按需）
ethtool -K ${IFACE} rxvlan on txvlan on 2>/dev/null || true
ethtool -K ${IFACE} rx-checksumming on tx-checksumming on 2>/dev/null || true

# 3. 关闭不需要的 offload（高性能场景）
ethtool -K ${IFACE} gso off tso off ufo off gro off lro off 2>/dev/null || true

# 4. ring buffer 大小
ethtool -G ${IFACE} rx 4096 tx 4096

# 5. 中断合并
ethtool -C ${IFACE} rx-usecs 0 tx-usecs 0  # 禁用中断合并（busy-polling）

# 6. 队列数（根据 CPU 核数调整）
#    建议：队列数 = CPU 核数（如果 <= 16）
CPU_CORES=$(nproc)
if [ ${CPU_CORES} -gt 16 ]; then
    CPU_CORES=16
fi
ethtool -L ${IFACE} combined ${CPU_CORES}

# 7. RSS 配置
#    将所有队列配置为相同的 hash
ethtool -X ${IFACE} equal ${CPU_CORES}

# 8. 队列中断亲和（每个队列绑定独立 CPU）
for i in $(seq 0 $((CPU_CORES-1))); do
    IRQ=$(grep -m1 "${IFACE}-${i}" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ')
    if [ -n "$IRQ" ]; then
        MASK=$(printf '0x%x' $((1 << i)))
        echo ${MASK} > /proc/irq/${IRQ}/smp_affinity
    fi
done

# 9. 启用 flow control（按需）
ethtool -A ${IFACE} rx on tx on 2>/dev/null || true

# 10. 查看配置结果
echo ""
echo "=== 配置后状态 ==="
ethtool ${IFACE}
ethtool -l ${IFACE}
ethtool -g ${IFACE}
```

### 2.3 驱动参数

```bash
#!/bin/bash
# driver_params.sh — 驱动参数配置

# Mellanox (mlx5) 参数
cat >> /etc/modprobe.d/mlx5.conf <<EOF
options mlx5_core log_mtu=4
options mlx5_core prof_sel=0
EOF

# Intel E810 (ice) 参数
cat >> /etc/modprobe.d/ice.conf <<EOF
options ice PackBuff=0
options ice IntMode=2
options ice CrcStrip=1
EOF

# 应用这些更改
update-initramfs -u

echo "=== 驱动参数已配置 ==="
echo "请重启系统以生效"
```

---

## 3. 部署方案

### 3.1 独立部署

```bash
#!/bin/bash
# deploy_xdp_service.sh — 独立服务部署

SERVICE_NAME="xdp-proxy"
BINARY_PATH="/opt/xdp-proxy/bin/xdp-proxy"
CONFIG_PATH="/etc/xdp-proxy/config.yaml"
USER="xdp"
GROUP="xdp"

echo "=== 部署 ${SERVICE_NAME} ==="

# 1. 创建用户
id ${USER} &>/dev/null || useradd -r -s /sbin/nologin ${USER}

# 2. 创建目录
mkdir -p /opt/xdp-proxy/{bin,config,log,run}
mkdir -p /etc/xdp-proxy

# 3. 复制文件
cp ${BINARY_PATH} /opt/xdp-proxy/bin/
cp ${CONFIG_PATH} /etc/xdp-proxy/

# 4. 设置权限
chown -R ${USER}:${GROUP} /opt/xdp-proxy
chown -R ${USER}:${GROUP} /etc/xdp-proxy

# 5. 创建 systemd 服务
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=XDP Proxy Service
After=network.target local-fs.target
Wants=network.target

[Service]
Type=simple
User=${USER}
Group=${GROUP}
ExecStart=${BINARY_PATH} --config ${CONFIG_PATH}
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
TimeoutStopSec=30s

# 资源限制
LimitNOFILE=1048576
LimitCORE=infinity
LimitMEMLOCK=infinity

# 环境
Environment="LD_PRELOAD="
Environment="XDP_SKB_MODE=1"

# 日志
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# CPU 亲和（根据部署调整）
# CPUPolicy=exclusive
# CPUAffinity=0-7

[Install]
WantedBy=multi-user.target
EOF

# 6. 重新加载 systemd
systemctl daemon-reload

# 7. 启用 hugepages（如果需要）
mkdir -p /mnt/hugepages
mount -t hugetlbfs nodev /mnt/hugepages
echo 256 > /proc/sys/vm/nr_hugepages

# 8. 设置 hugepages 持久化
cat >> /etc/fstab <<EOF
nodev /mnt/hugepages hugetlbfs defaults 0 0
EOF

# 9. 启动服务
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}

echo "=== 部署完成 ==="
systemctl status ${SERVICE_NAME}
```

### 3.2 Docker 部署

```dockerfile
# Dockerfile — XDP 应用 Docker 镜像

FROM ubuntu:22.04 AS builder

# 安装编译依赖
RUN apt-get update && apt-get install -y \
    clang llvm lld \
    linux-headers-$(uname -r) \
    libbpf-dev \
    gcc make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 复制源代码
COPY . .

# 编译
RUN make -j$(nproc)

# ============

FROM ubuntu:22.04

# 安装运行时依赖
RUN apt-get update && apt-get install -y \
    libbpf0 \
    ethtool \
    iproute2 \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# 创建 hugepages 挂载点
RUN mkdir -p /mnt/hugepages

# 复制二进制
COPY --from=builder /build/xdp-proxy /usr/local/bin/

# 复制配置文件
COPY config.yaml /etc/xdp-proxy/

# 创建非 root 用户
RUN useradd -r -s /sbin/nologin xdp && \
    chown -R xdp:xdp /etc/xdp-proxy

# 设置 capabilities（必须）
# 注意：容器需要 --privileged 或特定 capabilities
USER xdp

# 默认命令
CMD ["xdp-proxy", "--config", "/etc/xdp-proxy/config.yaml"]
```

```yaml
# docker-compose.yml — XDP 应用编排

version: "3.8"

services:
  xdp-proxy:
    image: xdp-proxy:latest
    container_name: xdp-proxy
    hostname: xdp-node1

    # 能力要求
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE
    security_opt:
      - seccomp=unconfined
      - apparmor=unconfined

    # 网络模式：host（XDP 需要直接访问网卡）
    network_mode: host

    # 挂载 hugepages
    volumes:
      - /mnt/hugepages:/mnt/hugepages
      - /dev:/dev
      - /lib/modules:/lib/modules:ro

    # 环境变量
    environment:
      - XDP_IFACE=eth0
      - XDP_MODE=native
      - XDP_QUEUES=4
      - RUST_LOG=info

    # 重启策略
    restart: unless-stopped

    # healthcheck
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

```bash
#!/bin/bash
# run_docker.sh — Docker 运行脚本

# 停止并删除旧容器
docker rm -f xdp-proxy 2>/dev/null

# 运行新容器
docker run -d \
    --name xdp-proxy \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --cap-add SYS_RESOURCE \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --network host \
    --mount type=bind,src=/mnt/hugepages,dst=/mnt/hugepages \
    --mount type=bind,src=/dev,dst=/dev \
    --mount type=bind,src=/lib/modules,dst=/lib/modules,readonly \
    -e XDP_IFACE=eth0 \
    -e XDP_MODE=native \
    -e XDP_QUEUES=4 \
    -e RUST_LOG=info \
    xdp-proxy:latest

echo "容器已启动"
docker logs -f xdp-proxy
```

### 3.3 Kubernetes 部署（Cilium）

```yaml
# Cilium DaemonSet — Kubernetes CNI + XDP

# 注意： Cilium 默认使用 XDP 进行高性能网络
# 这里展示 Cilium + AF_XDP 的生产配置

apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  # XDP 加速
  enable-xdp: "true"
  xdp-mode: "native" # native/driver/generic

  # BPF
  bpf-map-growth-size: "65536"
  bpf-policy-map-max: "16384"

  # 性能
  enable-ipv4-fragmentation: "false"
  enable-ipv6-fragmentation: "false"
  enable-l7-proxy: "false" # 禁用 L7 代理以提升性能

  # 连接跟踪
  bpf-ct-global-max-entries: "1000000"
  bpf-nat-global-max-entries: "1000000"

  # 负载均衡
  enable-nodePort: "true"
  enable-external-LoadBalancer: "true"
  loadbalancer-mode: "dsr" # 直接服务器返回
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cilium
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: cilium
  template:
    spec:
      containers:
        - name: cilium-agent
          image: cilium/cilium:v1.14.0
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          securityContext:
            privileged: true
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "4"
              memory: 4Gi
          volumeMounts:
            - name: bpffs
              mountPath: /sys/fs/bpf
              mountPropagation: Bidirectional
            - name: lib-modules
              mountPath: /lib/modules
              readOnly: true
      volumes:
        - name: bpffs
          hostPath:
            path: /sys/fs/bpf
            type: DirectoryOrCreate
        - name: lib-modules
          hostPath:
            path: /lib/modules
```

---

## 4. 监控与排错

### 4.1 监控指标

```bash
#!/bin/bash
# monitor_xdp.sh — XDP 监控脚本

IFACE="${1:-eth0}"

echo "=== XDP 监控 ==="

# 1. 网卡统计
echo ""
echo "[1] 网卡统计:"
ethtool -S ${IFACE} | grep -E "xdp|redirect|drop|error" | head -20

# 2. XDP 状态
echo ""
echo "[2] XDP 程序:"
ip link show ${IFACE} | grep -E "xdp|prog"

# 3. BPF 程序
echo ""
echo "[3] BPF 程序:"
bpftool prog show | grep -E "xdp|af" | head -20

# 4. BPF Maps
echo ""
echo "[4] BPF Maps:"
bpftool map show | head -20

# 5. AF_XDP sockets
echo ""
echo "[5] AF_XDP sockets:"
cat /proc/net/xdp/ 2>/dev/null || ls -la /sys/kernel/debug/xdp/ 2>/dev/null

# 6. CPU 利用率
echo ""
echo "[6] CPU 利用率:"
mpstat -P ALL 1 1 | tail -10

# 7. 中断统计
echo ""
echo "[7] 中断统计:"
cat /proc/interrupts | grep -E "${IFACE}|eth" | head -20

# 8. 网卡 link 状态
echo ""
echo "[8] 网卡 link 状态:"
ethtool ${IFACE} | grep -E "Link|Speed|Duplex"

# 9. 内存状态
echo ""
echo "[9] 内存/hugepages:"
cat /proc/meminfo | grep -E "Huge|Transient"
```

```python
# prometheus_exporter.py — Prometheus 指标导出

from prometheus_client import start_http_server, Gauge, Counter, Histogram
import subprocess
import time

# 定义指标
xdp_packets_rx = Counter('xdp_packets_rx', 'XDP packets received')
xdp_packets_tx = Counter('xdp_packets_tx', 'XDP packets transmitted')
xdp_packets_drop = Counter('xdp_packets_drop', 'XDP packets dropped')
xdp_latency_us = Histogram('xdp_latency_us', 'XDP processing latency',
                            buckets=[1, 2, 5, 10, 20, 50, 100])

def collect_stats():
    """收集 XDP 统计"""
    try:
        # ethtool 统计
        result = subprocess.run(
            ['ethtool', '-S', 'eth0'],
            capture_output=True, text=True
        )
        for line in result.stdout.split('\n'):
            if 'rx_xdp' in line or 'tx_xdp' in line:
                # 解析并更新指标
                pass

        # bpftool 统计
        result = subprocess.run(
            ['bpftool', 'map', 'show'],
            capture_output=True, text=True
        )

    except Exception as e:
        print(f"Error collecting stats: {e}")

def main():
    start_http_server(9090)
    print("Prometheus exporter listening on :9090")

    while True:
        collect_stats()
        time.sleep(15)

if __name__ == '__main__':
    main()
```

### 4.2 日志配置

```yaml
# /etc/xdp-proxy/logging.yaml — 日志配置

version: 1
disable_existing_loggers: false

formatters:
  default:
    format: "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    datefmt: "%Y-%m-%d %H:%M:%S"

  json:
    class: pythonjsonlogger.jsonlogger.JsonFormatter
    format: "%(asctime)s %(name)s %(levelname)s %(message)s"

handlers:
  console:
    class: logging.StreamHandler
    level: INFO
    formatter: default
    stream: ext://sys.stdout

  file:
    class: logging.handlers.RotatingFileHandler
    level: DEBUG
    formatter: json
    filename: /var/log/xdp-proxy/app.log
    maxBytes: 104857600 # 100MB
    backupCount: 10

  syslog:
    class: logging.handlers.SysLogHandler
    level: WARNING
    formatter: default
    address: /dev/log

root:
  level: INFO
  handlers: [console, file]

loggers:
  xdp:
    level: DEBUG
    handlers: [console, file]
    propagate: false

  xdp.stats:
    level: INFO
    handlers: [file]
    propagate: false
```

### 4.3 常见故障排除

```
故障排除指南：

┌──────────────────────────────────────────────────────────────────────┐
│  故障 1: XDP 程序加载失败                                           │
├──────────────────────────────────────────────────────────────────────┤
│  症状：ip link set dev eth0 xdp obj prog.o 失败                     │
│                                                                      │
│  可能原因：                                                          │
│    1. 驱动不支持 native XDP                                        │
│    2. 内核版本太低                                                 │
│    3. 权限不足                                                     │
│    4. 程序有 BPF 验证错误                                          │
│                                                                      │
│  排查步骤：                                                         │
│    $ dmesg | tail -50                                              │
│    $ ip link show eth0                                             │
│    $ cat /sys/class/net/eth0/device/sriov_totalvfs                 │
│                                                                      │
│  解决方案：                                                          │
│    1. 使用 generic 模式：ip link set eth0 xdp obj prog.o generic  │
│    2. 升级内核到 5.x                                               │
│    3. 使用 root 权限                                               │
│    4. 检查 bpftool prog load prog.o type xdp                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  故障 2: AF_XDP socket 创建失败                                     │
├──────────────────────────────────────────────────────────────────────┤
│  症状：socket(AF_XDP, SOCK_RAW, 0) 返回 -1                         │
│                                                                      │
│  可能原因：                                                          │
│    1. UMEM 配置错误                                                │
│    2. Ring 大小不匹配                                               │
│    3. 权限不足                                                     │
│    4. 文件描述符 耗尽                                              │
│                                                                      │
│  排查步骤：                                                         │
│    $ dmesg | grep -i xdp                                           │
│    $ cat /proc/sys/fs/file-nr                                      │
│    $ ulimit -n                                                    │
│                                                                      │
│  解决方案：                                                          │
│    1. 检查 UMEM 大小（必须 2MB 对齐）                              │
│    2. 确认 ring 大小是 2 的幂                                      │
│    3. 设置 CAP_NET_ADMIN                                           │
│    4. ulimit -n 1048576                                           │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  故障 3: 性能下降                                                  │
├──────────────────────────────────────────────────────────────────────┤
│  症状：延迟抖动、吞吐下降                                           │
│                                                                      │
│  可能原因：                                                          │
│    1. FILL ring 耗尽                                               │
│    2. NUMA 跨域                                                    │
│    3. 中断风暴                                                     │
│    4. 内存碎片                                                     │
│                                                                      │
│  排查步骤：                                                         │
│    $ watch -n1 'cat /proc/interrupts | grep eth'                  │
│    $ numactl --hardware                                            │
│    $ mpstat -P ALL 1                                               │
│                                                                      │
│  解决方案：                                                          │
│    1. 增加 UMEM chunks 数量                                        │
│    2. numactl --membind=0 --cpunodebind=0                          │
│    3. 调整中断亲和                                                  │
│    4. 重启应用以重置内存                                            │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  故障 4: 连接中断                                                  │
├──────────────────────────────────────────────────────────────────────┤
│  症状：连接突然中断、复位                                           │
│                                                                      │
│  可能原因：                                                          │
│    1. XDP 程序崩溃                                                 │
│    2. 网卡驱动问题                                                 │
│    3. 内存错误                                                     │
│                                                                      │
│  排查步骤：                                                         │
│    $ dmesg | tail -100                                            │
│    $ ethtool -i eth0                                              │
│    $ cat /sys/class/net/eth0/operstate                            │
│                                                                      │
│  解决方案：                                                          │
│    1. 检查 bpf_trace_printk 输出                                  │
│    2. 更新网卡驱动                                                  │
│    3. 运行 memtester                                               │
│    4. 使用 hardware ECC 内存                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 5. 性能调优实战

### 5.1 极限延迟调优

```bash
#!/bin/bash
# tuning_low_latency.sh — 低延迟调优

echo "=== 低延迟调优 ==="

# 1. 禁用电源管理
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > $cpu
done

# 2. 禁用 Turbo Boost（低延迟场景可能需要）
# echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo

# 3. 禁用 CPU 调度增强
echo 0 > /proc/sys/kernel/sched_autogroup_enabled
echo 0 > /proc/sys/kernel/numa_balancing

# 4. 增大内核日志缓冲区
echo 65536 > /proc/sys/kernel/printk

# 5. 最小化 watchdog
echo 0 > /proc/sys/kernel/watchdog_thresh

# 6. 禁用 transparent hugepage
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# 7. 设置 hugepage
echo 1024 > /proc/sys/vm/nr_hugepages

# 8. 调整内存
echo 100 > /proc/sys/vm/swappiness
echo 0 > /proc/sys/vm/dirty_ratio
echo 5 > /proc/sys/vm/dirty_background_ratio

# 9. 网络参数
sysctl -w net.core.bpf_jit_enable=1
sysctl -w net.core.bpf_jit_harden=1
sysctl -w net.ipv4.tcp_fastopen=3
sysctl -w net.ipv4.tcp_tw_reuse=0

# 10. 禁用 IRQs 合并（busy-polling）
for f in /sys/class/net/eth*/queues/rx-*/rps_cpus; do
    echo 0 > $f 2>/dev/null
done

echo "=== 低延迟调优完成 ==="
```

### 5.2 高吞吐调优

```bash
#!/bin/bash
# tuning_high_throughput.sh — 高吞吐调优

echo "=== 高吞吐调优 ==="

# 1. CPU 频率
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > $cpu
done

# 2. 中断亲和（每个队列绑定独立 CPU）
for i in $(seq 0 7); do
    IRQ=$(cat /proc/interrupts | grep "eth0-$i" | awk -F: '{print $1}')
    if [ -n "$IRQ" ]; then
        echo $((1 << i)) > /proc/irq/$IRQ/smp_affinity_list
    fi
done

# 3. RPS (Receive Packet Steering)
for f in /sys/class/net/eth*/queues/rx-*/rps_cpus; do
    echo ff > $f
done

# 4. 网卡 offload
ethtool -K eth0 gso on tso on 2>/dev/null || true
ethtool -K eth0 gro on 2>/dev/null || true

# 5. 增大 ring buffer
ethtool -G eth0 rx 8192 tx 8192

# 6. 巨型帧
ip link set eth0 mtu 9000

# 7. 关闭 irqbalance
systemctl stop irqbalance 2>/dev/null || true

# 8. 内存
echo 2048 > /proc/sys/vm/nr_hugepages

# 9. 文件描述符
echo 1048576 > /proc/sys/fs/file-max
ulimit -n 1048576

# 10. 连接跟踪（如果需要）
echo 2000000 > /proc/sys/net/netfilter/nf_conntrack_max

echo "=== 高吞吐调优完成 ==="
```

### 5.3 NUMA 优化

```bash
#!/bin/bash
# tuning_numa.sh — NUMA 优化

echo "=== NUMA 优化 ==="

# 1. 查看 NUMA 拓扑
lstopo

# 2. 查看网卡 NUMA 位置
echo "网卡 eth0 NUMA:"
cat /sys/class/net/eth0/device/numa_node

# 3. 查看 CPU 拓扑
echo "CPU 分布:"
numactl --hardware

# 4. 在正确 NUMA 节点运行应用
# numactl --membind=0 --cpunodebind=0 ./xdp-app

# 5. 为 AF_XDP 预留内存
# 在正确节点预分配 hugepages
echo "预留 hugepages 在节点 0:"
echo 1024 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages

# 6. 确认正确分配
cat /proc/meminfo | grep Huge

# 7. 运行验证
# numactl --cpunodebind=0 --membind=0 ./xdp-app --verify-numa

echo "=== NUMA 优化完成 ==="
```

---

## 6. 安全加固

### 6.1 内核安全参数

```bash
#!/bin/bash
# security_hardening.sh — 安全加固

echo "=== 安全加固 ==="

# 1. 网络过滤
cat >> /etc/sysctl.d/99-security.conf <<EOF
# 禁用 ICMP redirect
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
net.ipv4.icmp_echo_ignore_all = 0  # 保持开启（可检测存活）

# syn flood 保护
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192

# 禁用 magic sysrq
kernel.sysrq = 0
EOF

sysctl -p /etc/sysctl.d/99-security.conf

# 2. BPF 限制
cat >> /etc/sysctl.d/99-bpf-security.conf <<EOF
# 限制 BPF JIT
kernel.bpf_jit_harden = 2  # 完全禁用（生产环境）
EOF

# 3. 文件权限
chmod 600 /sys/kernel/debug/tracing/trace 2>/dev/null || true
chmod 640 /proc/sys/kernel/bpf_stats_enabled 2>/dev/null || true

# 4. Capabilities 限制
# 为 XDP 应用分配最小权限
# 需要：CAP_NET_ADMIN（创建 XDP socket）
#      CAP_SYS_ADMIN（加载 BPF program）
#      CAP_SYS_RESOURCE（hugepage）

echo "=== 安全加固完成 ==="
```

### 6.2 Seccomp 配置

```json
// seccomp_xdp.json — seccomp 过滤规则

{
  "defaultAction": "SCMP_ACT_KILL",
  "syscalls": [
    {
      "names": ["read", "write", "close", "recvfrom", "sendto", "poll", "epoll_wait", "epoll_ctl"],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["socket", "bind", "listen", "accept", "accept4", "connect", "shutdown"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {
          "index": 0,
          "value": 43, // AF_XDP
          "op": "SCMP_CMP_EQ"
        }
      ]
    },
    {
      "names": ["mmap", "mprotect", "munmap", "brk"],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["clock_gettime", "gettimeofday"],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["exit", "exit_group"],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["getuid", "getgid"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

### 6.3 AppArmor 配置

```bash
# /etc/apparmor.d/usr.local.bin.xdp-proxy — AppArmor 配置

#include <tunables/global>

/usr/local/bin/xdp-proxy {
    #include <abstractions/base>

    # 能力
    capability net_admin,
    capability sys_admin,
    capability sys_resource,
    capability sys_ptrace,

    # 网络
    network af_xdp,
    network raw,
    network packet,

    # 文件系统
    /etc/xdp-proxy/ r,
    /etc/xdp-proxy/** r,
    /opt/xdp-proxy/** rw,
    /var/log/xdp-proxy/ w,
    /run/xdp-proxy/ w,

    # hugepages
    /mnt/hugepages/ w,
    /dev/hugepages/ w,

    # BPF
    /sys/fs/bpf/ r,
    /sys/fs/bpf/** rwk,

    # proc
    /proc/sys/kernel/bpf_stats_enabled r,

    # 网卡
    /sys/class/net/eth0/** rw,
    /sys/class/net/eth1/** rw,
}
```

---

## 7. 故障恢复

### 7.1 健康检查

```bash
#!/bin/bash
# healthcheck.sh — 健康检查脚本

IFACE="${1:-eth0}"
BINARY="/opt/xdp-proxy/bin/xdp-proxy"

# 检查进程
if ! pgrep -f "$BINARY" > /dev/null; then
    echo "CRITICAL: Process not running"
    exit 2
fi

# 检查 XDP 程序
if ! ip link show ${IFACE} | grep -q "xdp"; then
    echo "CRITICAL: XDP not loaded on ${IFACE}"
    exit 2
fi

# 检查错误统计
DROP_COUNT=$(ethtool -S ${IFACE} 2>/dev/null | grep "rx_xdp_drop" | awk '{print $2}')
if [ -n "$DROP_COUNT" ] && [ "$DROP_COUNT" -gt 1000 ]; then
    echo "WARNING: High drop count: ${DROP_COUNT}"
    exit 1
fi

# 检查内存
MEM_AVAILABLE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
if [ "$MEM_AVAILABLE" -lt 1048576 ]; then  # < 1GB
    echo "WARNING: Low memory: ${MEM_AVAILABLE} kB"
    exit 1
fi

# 检查 hugepages
HP_FREE=$(cat /proc/meminfo | grep "HugePages_Free" | awk '{print $2}')
if [ -z "$HP_FREE" ] || [ "$HP_FREE" -eq 0 ]; then
    echo "WARNING: No hugepages available"
    exit 1
fi

echo "OK: All checks passed"
exit 0
```

### 7.2 自动恢复

```bash
#!/bin/bash
# auto_recovery.sh — 自动恢复脚本

IFACE="${1:-eth0}"
SERVICE="xdp-proxy"

log() {
    echo "[$(date)] $1"
}

# 监控循环
while true; do
    # 检查 XDP 程序
    if ! ip link show ${IFACE} 2>/dev/null | grep -q "xdp"; then
        log "XDP not loaded, reloading..."

        # 重新加载 XDP 程序
        ip link set dev ${IFACE} xdp off 2>/dev/null
        ip link set dev ${IFACE} xdp obj /opt/xdp-proxy/xdp_prog.o sec xdp 2>/dev/null

        if ip link show ${IFACE} | grep -q "xdp"; then
            log "XDP reloaded successfully"
        else
            log "ERROR: XDP reload failed"
        fi
    fi

    # 检查服务进程
    if ! pgrep -f "$SERVICE" > /dev/null; then
        log "Service not running, restarting..."
        systemctl restart $SERVICE

        if pgrep -f "$SERVICE" > /dev/null; then
            log "Service restarted successfully"
        else
            log "ERROR: Service restart failed"
        fi
    fi

    # 检查错误率
    DROP_RATE=$(ethtool -S ${IFACE} 2>/dev/null | grep "rx_xdp_drop" | awk '{print $2}')
    if [ -n "$DROP_RATE" ] && [ "$DROP_RATE" -gt 10000 ]; then
        log "WARNING: High drop rate detected: ${DROP_RATE}"
    fi

    sleep 10
done
```

---

## 8. 小结

```
AF_XDP 生产环境实战总结：

硬件选型：
  · 网卡：Mellanox ConnectX-6/7（最佳）、Intel E810（推荐）
  · CPU：Xeon Scalable / EPYC，16+ 核心
  · 内存：64GB+，DDR4-3200+
  · NUMA：网卡与 CPU 正确对应

OS 配置：
  · 内核：5.10+（推荐 6.x）
  · hugepage：256-1024 页
  · BPF JIT：启用
  · 调度：禁用 numa_balancing

网卡调优：
  · 巨型帧：MTU 9000
  · 队列：CPU 核数
  · RSS：equal
  · offload：按需关闭（高性能场景）
  · ring buffer：4096+

部署方式：
  · 独立部署：systemd 管理
  · Docker：--network host + capabilities
  · Kubernetes：Cilium（原生 XDP 支持）

监控指标：
  · ethtool -S | grep xdp
  · bpftool prog/map show
  · /proc/net/xdp
  · 自定义 Prometheus exporter

安全加固：
  · 网络过滤（rp_filter/accept_redirects）
  · BPF JIT 禁用（kernel.bpf_jit_harden=2）
  · Capabilities 最小化
  · Seccomp/AppArmor

故障恢复：
  · 健康检查：XDP 状态、drop 率、内存
  · 自动恢复：监控循环 + 告警
  · 日志审计：dmesg、journalctl、应用日志

性能调优：
  · 低延迟：performance governor、禁用 turbo、busy-poll
  · 高吞吐：巨型帧、RPS、GRO、ring buffer
  · NUMA：绑定正确节点、预分配 hugepages

AF_XDP 系列总结（6 章完成）：

  Ch1: 架构与原理 — XDP + UMEM + 四大 Ring
  Ch2: XDP 脚本与 BPF 程序 — 开发、调试、Map、Tail Call
  Ch3: 数据路径分析 — RX/TX 全流程、延迟分解
  Ch4: 方案对比 — AF_XDP vs DPDK vs io_uring
  Ch5: 融合架构 — io_uring + AF_XDP 协同
  Ch6: 生产实战 — 部署、监控、调优、安全
```

---

## 延伸阅读

- XDP 官方文档: `Documentation/networking/xdp.rst`
- AF_XDP 官方: `Documentation/networking/af_xdp.rst`
- Cilium BPF: `https://docs.cilium.io/en/stable/bpf/`
- Mellanox XDP: `https://docs.nvidia.com/networking/category/xdp`
- Intel XDP: `https://www.intel.com/content/www/us/en/developer/articles/technical/
- Facebook XDP: `https://facebookmicrosites.github.io/bpf/blog/`
- Cloudflare XDP: `https://blog.cloudflare.com/tag/xdp/`
- LWN: "XDP performance": `https://lwn.net/Articles/808948/`
- 内核 BPF 文档: `Documentation/bpf/`
- BPF Performance Tools (Brendan Gregg): `https://www.brendangregg.com/bpf-performance-tools-book.html`
