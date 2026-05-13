---
title: "VPP 深入探讨 ch35：部署与配置管理"
date: 2026-04-16 10:45:00
tags: [vpp, deployment, configuration, ansible, docker, kubernetes, systemd]
description: "深入解析 VPP 部署与配置管理：二进制安装、Docker 部署、Kubernetes CNI、systemd 配置、Ansible 自动化与配置版本管理"
---

# VPP 深入探讨 ch35：部署与配置管理

> [!abstract] 核心要点
> 生产部署需要规范的配置管理流程。本章详解 VPP 各种部署方式：二进制安装、Docker、Kubernetes，以及 Ansible 自动化部署、配置模板与版本管理。

## 1. 二进制部署

### 1.1 包安装

```bash
# Debian/Ubuntu
# 添加 VPP 仓库
curl -L https://packagecloud.io/fdio/release/gpgkey | apt-key add -
echo "deb https://packagecloud.io/fdio/release/ubuntu focal main" > \
    /etc/apt/sources.list.d/99fd.io.list
apt-get update

# 安装 VPP
apt-get install vpp vpp-dev vpp-lib

# 查看安装的文件
dpkg -L vpp | head -30

# 安装路径：
# /usr/bin/vpp
# /usr/bin/vppctl
# /etc/vpp/startup.conf
# /usr/lib/vpp/bin/
# /var/log/vpp/
```

### 1.2 startup.conf 配置

```bash
# /etc/vpp/startup.conf

# Unix 配置
unix {
    # 运行用户/组
    # user root
    # group root

    # CLI socket 路径
    cli-listen /run/vpp/cli.sock

    # 日志配置
    log /var/log/vpp/vpp.log
    log-level notice

    # coredump
    full-coredump

    # 启动超时
    startup-timeout 30

    # 退出超时
    exit-timeout 10
}

# DPDK 配置
dpdk {
    # hugepage 大小（建议 1024M 以上）
    hugeheap {
        default-hugepage-mem-nbytes 1024M
    }

    # 启用 tinger (telemetry)
    enable tinger

    # 默认队列配置
    dev default {
        num-rx-queues 4
        num-tx-queues 4
        rxq-size 1024
        txq-size 1024
    }

    # 特定接口配置
    dev 0000:1a:00.0 {
        name eth0
        num-rx-queues 8
        num-tx-queues 8
    }
}

# 中断/轮询模式
polling {
    # 使用轮询模式（默认）
    # mode adaptive
}

# CPU 配置
cpu {
    # worker 数量 (0 = 自动，使用所有可用核心)
    workers 0

    # 主线程 CPU
    main-core 0

    # worker 开始 CPU
    startup-worker-core 1

    # 线程优先级
    # scheduler-priority normal
}

# 插件配置
plugins {
    # 禁用不需要的插件
    plugin default {
        disable
    }

    # 启用需要的插件
    plugin linux-cp {
        enable
    }

    # 插件路径
    path /usr/lib/vpp/plugins
}
```

### 1.3 systemd 管理

```bash
# VPP systemd 服务文件
cat > /etc/systemd/system/vpp.service << 'EOF'
[Unit]
Description=Vector Packet Processing (VPP)
After=network.target local-fs.target
Wants=network.target

[Service]
Type=notify
Environment=LD_LIBRARY_PATH=/usr/lib/vpp:$LD_LIBRARY_PATH
ExecStartPre=/sbin/modprobe af_xdp
ExecStartPre=/sbin/modprobe vfio-pci
ExecStart=/usr/bin/vpp -c /etc/vpp/startup.conf
ExecReload=/bin/kill -SIGHUP $MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
TimeoutStopSec=30s

# 资源限制
LimitNOFILE=1048576
LimitCORE=infinity

# 日志
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vpp

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd
systemctl daemon-reload

# 启用开机启动
systemctl enable vpp

# 启动/停止/重启
systemctl start vpp
systemctl stop vpp
systemctl restart vpp

# 查看状态
systemctl status vpp

# 查看日志
journalctl -u vpp -f
```

### 1.4 多实例部署

```bash
# 创建实例目录
mkdir -p /etc/vpp/instances
mkdir -p /run/vpp/instances
mkdir -p /var/log/vpp/instances

# 实例1 配置
cat > /etc/vpp/instances/vpp1.conf << 'EOF'
unix {
    cli-listen /run/vpp/instances/vpp1.sock
    log /var/log/vpp/instances/vpp1.log
    full-coredump
}
dpdk {
    dev 0000:1a:00.0 {
        name eth0
    }
}
EOF

# 实例2 配置
cat > /etc/vpp/instances/vpp2.conf << 'EOF'
unix {
    cli-listen /run/vpp/instances/vpp2.sock
    log /var/log/vpp/instances/vpp2.log
    full-coredump
}
dpdk {
    dev 0000:1a:00.1 {
        name eth1
    }
}
EOF

# 创建多实例 systemd 服务
cat > /etc/systemd/system/vpp@.service << 'EOF'
[Unit]
Description=VPP Instance %I
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/vpp -c /etc/vpp/instances/%i.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 启用和启动实例
systemctl enable vpp@vpp1
systemctl enable vpp@vpp2
systemctl start vpp@vpp1
systemctl start vpp@vpp2

# 连接实例 CLI
vppctl -s /run/vpp/instances/vpp1.sock
```

## 2. Docker 部署

### 2.1 Dockerfile

```dockerfile
# Dockerfile for VPP
FROM ubuntu:22.04

LABEL maintainer="admin@example.com"
LABEL description="VPP (Vector Packet Processing)"

# 安装依赖
RUN apt-get update && apt-get install -y \
    curl \
    gnupg2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 添加 VPP 仓库
RUN curl -L https://packagecloud.io/fdio/release/gpgkey | apt-key add - && \
    echo "deb https://packagecloud.io/fdio/release/ubuntu focal main" > \
    /etc/apt/sources.list.d/99fd.io.list && \
    apt-get update && \
    apt-get install -y vpp

# 复制配置文件
COPY startup.conf /etc/vpp/startup.conf

# 创建必要目录
RUN mkdir -p /var/log/vpp /run/vpp /var/lib/vpp

# 设置 hugepage
RUN echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 暴露端口
EXPOSE 5001 9932 8080

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD vppctl show version || exit 1

# 启动命令
CMD ["vpp", "-c", "/etc/vpp/startup.conf"]
```

### 2.2 Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  vpp:
    image: vpp:latest
    container_name: vpp
    privileged: true
    environment:
      - VPP_HUGEHEAP_SIZE=1024M
    volumes:
      - ./startup.conf:/etc/vpp/startup.conf:ro
      - ./data:/var/lib/vpp
      - /mnt/huge:/mnt/huge
    ports:
      - "5001:5001"  # gRPC
      - "9932:9932"  # Telemetry
      - "8080:8080"  # REST API
    networks:
      - vpp-net
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "vppctl", "show", "version"]
      interval: 30s
      timeout: 10s
      retries: 3

  # VPP 作为 CNI 插件
  vpp-cni:
    image: vpp:latest
    container_name: vpp-cni
    privileged: true
    volumes:
      - /etc/cni/net.d:/etc/cni/net.d
      - /opt/cni/bin:/opt/cni/bin
      - /mnt/huge:/mnt/huge
    network_mode: "host"
    command: ["vpp", "-c", "/etc/vpp/startup.conf"]

networks:
  vpp-net:
    driver: bridge
```

### 2.3 主机网络模式

```bash
# 使用主机网络（高性能模式）
docker run --rm -it \
    --network=host \
    --privileged \
    --cpuset-cpus=0-3 \
    --memory=4g \
    -v /mnt/huge:/mnt/huge \
    -v /sys/bus/pci/drivers:/sys/bus/pci/drivers \
    -v /lib/modules:/lib/modules \
    vpp:latest

# 绑定特定 NIC
docker run --rm -it \
    --network=host \
    --privileged \
    --device=/dev/vfio:/dev/vfio \
    --device=/sys/bus/pci/devices/0000:1a:00.0:/sys/bus/pci/devices/0000:1a:00.0 \
    -v /mnt/huge:/mnt/huge \
    vpp:latest

# 查看容器网络
docker exec vpp ip addr show
docker exec vpp vppctl show interface
```

## 3. Kubernetes 部署

### 3.1 VPP CNI 插件

```yaml
# vpp-cni.yaml - VPP CNI 安装
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vpp-cni
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: vpp-cni
  template:
    metadata:
      labels:
        name: vpp-cni
    spec:
      hostNetwork: true
      serviceAccountName: vpp-cni
      containers:
      - name: vpp
        image: vpp:latest
        securityContext:
          privileged: true
        env:
        - name: VPP_HUGEPAGE_MB
          value: "1024"
        - name: PLUGIN_PATH
          value: /usr/lib/vpp/plugins
        volumeMounts:
        - name: huges
          mountPath: /mnt/huge
        - name: cni-bin
          mountPath: /opt/cni/bin
        - name: cni-conf
          mountPath: /etc/cni/net.d
        - name: vpp-config
          mountPath: /etc/vpp
        resources:
          requests:
            memory: "2Gi"
            hugepages-2Mi: "1Gi"
          limits:
            memory: "4Gi"
            hugepages-2Mi: "2Gi"
      volumes:
      - name: huges
        emptyDir:
          medium: Memory
      - name: cni-bin
        hostPath:
          path: /opt/cni/bin
      - name: cni-conf
        hostPath:
          path: /etc/cni/net.d
      - name: vpp-config
        configMap:
          name: vpp-config
      tolerations:
      - effect: NoSchedule
        operator: Exists
```

### 3.2 CNI 配置

```json
{
  "cniVersion": "0.3.1",
  "name": "vpp-network",
  "type": "vpp",
  "etiVersion": "1.0.0",
  "ipam": {
    "type": "host-local",
    "subnet": "10.244.0.0/16",
    "rangeStart": "10.244.1.100",
    "rangeEnd": "10.244.1.200",
    "routes": [
      {"dst": "0.0.0.0/0"}
    ]
  },
  "mtu": 9000,
  "pluginLogging": {
    "level": "debug"
  }
}
```

### 3.3 VPP 作为 Service Proxy

```yaml
# vpp-Lb.yaml - VPP 作为负载均衡器
apiVersion: v1
kind: ConfigMap
metadata:
  name: vpp-lb-config
  namespace: kube-system
data:
  startup.conf: |
    unix {
      cli-listen /run/vpp/cli.sock
      log-level notice
    }
    dpdk {
      dev default {
        num-rx-queues 4
        num-tx-queues 4
      }
    }
    vxlan {
      # VTEP 配置
      gid 1
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vpp-lb
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: vpp-lb
  template:
    metadata:
      labels:
        app: vpp-lb
    spec:
      hostNetwork: true
      containers:
      - name: vpp-lb
        image: vpp:latest
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - SYS_ADMIN
        env:
        - name: VPP_LB_MODE
          value: "l3dsr"
        volumeMounts:
        - name: config
          mountPath: /etc/vpp
      volumes:
      - name: config
        configMap:
          name: vpp-lb-config
```

### 3.4 ServiceMesh 集成

```yaml
# vpp-service-mesh.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vpp-service-mesh
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: vpp-sidecar
  template:
    metadata:
      labels:
        app: vpp-sidecar
    spec:
      containers:
      - name: vpp-sidecar
        image: vpp:latest
        ports:
        - containerPort: 15001  # Envoy redirect
        - containerPort: 15006
        env:
        - name: VPP_SIDECAR_MODE
          value: "istio"
        - name: VPP_CONTROL_PLANE_PORT
          value: "15005"
```

## 4. Ansible 自动化

### 4.1 Inventory

```yaml
# inventory.yml
all:
  children:
    vpp_nodes:
      hosts:
        vpp-01:
          ansible_host: 192.168.1.100
          ansible_user: admin
          vpp_interfaces:
            - name: eth0
              pci: "0000:1a:00.0"
            - name: eth1
              pci: "0000:1a:00.1"
          vpp_workers: 4
        vpp-02:
          ansible_host: 192.168.1.101
          ansible_user: admin
          vpp_interfaces:
            - name: eth0
              pci: "0000:1a:00.0"
            - name: eth1
              pci: "0000:1a:00.1"
          vpp_workers: 4
```

### 4.2 Playbook

```yaml
# vpp_deploy.yml
---
- name: Deploy VPP
  hosts: vpp_nodes
  become: yes
  vars:
    vpp_version: "24.02"
    vpp_repo: "https://packagecloud.io/fdio/release/ubuntu"
    vpp_packages:
      - vpp
      - vpp-dev
      - vpp-lib
      - vpp-plugins

  tasks:
    - name: Add VPP GPG key
      apt_key:
        url: "{{ vpp_repo }}/gpgkey"
        state: present

    - name: Add VPP repository
      apt_repository:
        repo: "deb {{ vpp_repo }} focal main"
        state: present
        filename: 99fd.io

    - name: Install VPP packages
      apt:
        name: "{{ vpp_packages }}"
        state: present
        update_cache: yes

    - name: Configure hugepages
      sysctl:
        name: vm.nr_hugepages
        value: "1024"
        state: present
        permanent: yes

    - name: Create VPP directories
      file:
        path: "{{ item }}"
        state: directory
        mode: '0755'
      loop:
        - /etc/vpp
        - /run/vpp
        - /var/log/vpp

    - name: Deploy startup.conf
      template:
        src: templates/startup.conf.j2
        dest: /etc/vpp/startup.conf
        mode: '0644'
      notify: restart vpp

    - name: Enable and start VPP
      systemd:
        name: vpp
        enabled: yes
        state: started

    - name: Wait for VPP to be ready
      wait_for:
        path: /run/vpp/cli.sock
        timeout: 30

    - name: Verify VPP installation
      vpp_command:
        command: show version
      register: vpp_version_output
```

### 4.3 Startup.conf 模板

```jinja2
{# templates/startup.conf.j2 #}
unix {
    nodaemon
    cli-listen {{ vpp_cli_listen | default('/run/vpp/cli.sock') }}
    log {{ vpp_log_path | default('/var/log/vpp/vpp.log') }}
    log-level {{ vpp_log_level | default('notice') }}
    {% if vpp_full_coredump | default(true) %}
    full-coredump
    {% endif %}
    startup-timeout {{ vpp_startup_timeout | default(30) }}
    exit-timeout {{ vpp_exit_timeout | default(10) }}
}

api-trace {
    {% if vpp_api_trace | default(false) %}
    on
    {% else %}
    off
    {% endif %}
}

api-segment {
    uid {{ vpp_uid | default(0) }}
    gid {{ vpp_gid | default(0) }}
}

dpdk {
    hugeheap {
        default-hugepage-mem-nbytes {{ vpp_hugepage_mb | default('1024M') }}
    }

    {% for iface in vpp_interfaces %}
    dev {{ iface.pci }} {
        name {{ iface.name }}
        {% if iface.rx_queues is defined %}
        num-rx-queues {{ iface.rx_queues }}
        {% endif %}
        {% if iface.tx_queues is defined %}
        num-tx-queues {{ iface.tx_queues }}
        {% endif %}
    }
    {% endfor %}
}

cpu {
    {% if vpp_workers is defined %}
    workers {{ vpp_workers }}
    {% endif %}
    main-core {{ vpp_main_core | default(0) }}
}

plugins {
    {% if vpp_disabled_plugins is defined %}
    plugin default {
        disable
    }
    {% endif %}

    {% for plugin in vpp_enabled_plugins | default(['*']) %}
    plugin {{ plugin }} {
        enable
    }
    {% endfor %}
}
```

### 4.4 VPP Module

```python
#!/usr/bin/env python3
# library/vpp_command.py
# Ansible module for VPP commands

from ansible.module_utils.basic import AnsibleModule
import socket
import os

def vpp_exec_command(cmd, socket_path='/run/vpp/cli.sock'):
    """Execute VPP CLI command via UNIX socket"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)

    # Send command
    sock.sendall((cmd + '\n').encode())

    # Read response
    response = b''
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        response += chunk
        if b'\n' in chunk:
            break

    sock.close()
    return response.decode().strip()

def main():
    module = AnsibleModule(
        argument_spec={
            'command': {'required': True, 'type': 'str'},
            'socket': {'default': '/run/vpp/cli.sock', 'type': 'str'},
        },
        supports_check_mode=True
    )

    command = module.params['command']
    socket_path = module.params['socket']

    if not os.path.exists(socket_path):
        module.fail_json(msg=f"VPP socket not found: {socket_path}")

    try:
        result = vpp_exec_command(command, socket_path)
        module.exit_json(changed=False, stdout=result)
    except Exception as e:
        module.fail_json(msg=str(e))

if __name__ == '__main__':
    main()
```

## 5. 配置版本管理

### 5.1 配置结构

```
/etc/vpp/
├── startup.conf              # 主配置文件
├── startup.conf.d/           # 配置片段目录
│   ├── 01-interfaces.conf
│   ├── 02-routes.conf
│   ├── 03-acl.conf
│   └── 04-nat.conf
├── instances/               # 多实例配置
│   ├── vpp1.conf
│   └── vpp2.conf
└── conf.d/                  # 版本管理的配置目录
```

### 5.2 配置模板 (conf.d)

```bash
# /etc/vpp/conf.d/01-interfaces.conf
# 接口配置
set interface state TenGigabitEthernet0/0/0 up
set interface state TenGigabitEthernet0/0/1 up
set interface mtu 9000 TenGigabitEthernet0/0/0
set interface mtu 9000 TenGigabitEthernet0/0/1

# /etc/vpp/conf.d/02-ip-addresses.conf
# IP 地址配置
set interface ip address TenGigabitEthernet0/0/0 10.0.0.1/24
set interface ip address TenGigabitEthernet0/0/1 172.16.0.1/16

# /etc/vpp/conf.d/03-routes.conf
# 静态路由
ip route add 0.0.0.0/0 via 10.0.0.254 TenGigabitEthernet0/0/0
ip route add 192.168.0.0/16 via 172.16.0.254 TenGigabitEthernet0/0/1

# /etc/vpp/conf.d/04-acl.conf
# ACL 配置
acl-plugin enable
set acl-plugin ip4 table miss deny
```

### 5.3 配置加载顺序

```bash
#!/bin/bash
# /etc/vpp/load_configs.sh
# 启动时加载所有配置片段

CONFD_DIR="/etc/vpp/conf.d"
SOCKET="/run/vpp/cli.sock"

# 按顺序加载配置
for conf in $(ls -1 $CONFD_DIR/*.conf 2>/dev/null | sort); do
    echo "Loading: $conf"
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        # 发送到 VPP
        echo "$line" | nc -U -w 5 "$SOCKET"
    done < "$conf"
done
```

### 5.4 GitOps 工作流

```bash
#!/bin/bash
# gitops/vpp_config_sync.sh
# GitOps 配置同步脚本

GIT_REPO="git@github.com:org/vpp-configs.git"
GIT_DIR="/var/lib/vpp/git-config"
TARGET_DIR="/etc/vpp/conf.d"
BRANCH="production"

# Clone 或 Pull
if [ -d "$GIT_DIR/.git" ]; then
    cd "$GIT_DIR"
    git pull
else
    git clone -b "$BRANCH" "$GIT_REPO" "$GIT_DIR"
fi

# 计算 checksum 变化
new_checksum=$(find $GIT_DIR/conf.d -type f -exec cat {} \; | md5sum | cut -d' ' -f1)
old_checksum=$(cat /var/lib/vpp/.config_checksum 2>/dev/null || echo "")

if [ "$new_checksum" != "$old_checksum" ]; then
    echo "Config changed, applying..."

    # 备份当前配置
    backup_dir="/var/lib/vpp/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p $backup_dir
    cp -r $TARGET_DIR/* $backup_dir/

    # 应用新配置
    rm -rf $TARGET_DIR
    cp -r $GIT_DIR/conf.d $TARGET_DIR/

    # 通知 VPP 重载
    vppctl exec "config reload"

    # 更新 checksum
    echo "$new_checksum" > /var/lib/vpp/.config_checksum

    echo "Config applied successfully"
else
    echo "No config changes"
fi
```

### 5.5 配置回滚

```bash
#!/bin/bash
# rollback_config.sh - 配置回滚脚本

BACKUP_DIR="/var/lib/vpp/backups"
CURRENT_DIR="/etc/vpp/conf.d"

list_backups() {
    echo "Available backups:"
    ls -1 $BACKUP_DIR | sort -r
}

rollback() {
    local timestamp=$1

    if [ ! -d "$BACKUP_DIR/$timestamp" ]; then
        echo "Backup not found: $timestamp"
        exit 1
    fi

    echo "Rolling back to: $timestamp"

    # 备份当前配置
    current_backup="$BACKUP_DIR/$(date +%Y%m%d_%H%M%S)_pre_rollback"
    cp -r $CURRENT_DIR $current_backup

    # 应用回滚
    rm -rf $CURRENT_DIR
    cp -r $BACKUP_DIR/$timestamp $CURRENT_DIR

    # 通知 VPP 重载
    vppctl exec "config reload"

    echo "Rollback completed"
}

case "$1" in
    list)
        list_backups
        ;;
    rollback)
        rollback "$2"
        ;;
    *)
        echo "Usage: $0 {list|rollback <timestamp>}"
        ;;
esac
```
