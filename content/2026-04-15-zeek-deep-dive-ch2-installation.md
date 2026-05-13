---
title: "Zeek 深度探索 (二)：安装部署"
date: 2026-04-15
tags:
  - zeek
  - series
  - installation
  - build
  - zeekctl
description: "Zeek 安装部署完全指南——从源码编译、依赖库安装、版本选择，到 zeekctl 部署和首次运行"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. **第二章：安装部署**
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]

---

## 1. 安装方式概述

Zeek 提供三种安装方式：

| 方式 | 适用场景 | 优点 | 缺点 |
| :--- | :--- | :--- | :--- |
| **包管理器** | 快速体验 | 一键安装，自动依赖 | 版本可能过时 |
| **ZeekMetaPkg** | 生产环境 | 保持更新，官方维护 | 依赖较多 |
| **源码编译** | 深度定制/开发 | 灵活配置，最新特性 | 编译时间长 |

---

## 2. 系统依赖

### 2.1 基础依赖（所有安装方式）

Zeek 依赖以下核心库：

```bash
# Ubuntu / Debian
sudo apt-get update
sudo apt-get install -y \
    cmake \
    make \
    gcc \
    g++ \
    flex \
    bison \
    libpcap-dev \
    libssl-dev \
    zlib1g-dev \
    libmaxminddb-dev \
    libgeoip-dev \
    libkrb5-dev \
    libzstd-dev \
    liblz4-dev \
    python3 \
    python3-dev \
    python3-pip \
    swig \
    libbind-dev \
    libgtest-dev \
    btest

# macOS (Homebrew)
brew install cmake flex bison openssl zlib libpcap maxminddb geoip
```

### 2.2 可选依赖（增强功能）

| 功能 | 依赖 | 配置选项 |
| :--- | :--- | :--- |
| **AF_XDP 支持** | libbpf + linux-headers | `--enable-af-xdp` |
| **PF_RING 支持** | PF_RING DNA | `--enable-pf-ring` |
| **Redis Writer** | hiredis | `--enable-redis` |
| **Broker 通信** | OpenSSL + CMake | 默认启用 |
| **GSSAPI (Kerberos)** | libkrb5 | 默认启用 |
| **GeoIP2** | libmaxminddb | 默认启用 |

### 2.3 依赖验证脚本

Zeek 提供依赖检查脚本：

```bash
# 检查依赖完整性
./scripts/check-dependencies.sh
```

---

## 3. 方式一：包管理器安装

### 3.1 Linux 包管理器

```bash
# Ubuntu 22.04+
sudo apt update
sudo apt install zeek

# CentOS / RHEL / Fedora
sudo dnf install zeek

# macOS Homebrew
brew install zeek
```

### 3.2 验证安装

```bash
$ zeek --version
zeek version 7.x.x

$ which zeek
/usr/bin/zeek

$ zeekctl
ZeekControlSystem...
```

### 3.3 环境变量

包管理器安装后需配置环境变量：

```bash
# Ubuntu/Debian 包安装路径
export ZEEKBASE=/usr/share/zeek
export ZEEK_PLUGIN_PATH=$ZEEKBASE/plugins
export PATH=$PATH:$ZEEKBASE/bin:$ZEEKBASE/scripts
```

---

## 4. 方式二：ZeekMetaPkg（推荐生产环境）

ZeekMetaPkg 是官方推荐的包管理方式，基于 **Zeek Package Manager (zkg)** 基础设施。

### 4.1 安装 ZeekMetaPkg

```bash
# 克隆 ZeekMetaPkg 仓库
git clone --recurse-submodules https://github.com/zeek/zeek-meta-pkg.git
cd zeek-meta-pkg

# 运行安装脚本
sudo ./install.sh
```

### 4.2 使用 zeek-pkg 命令

```bash
# 更新 Zeek
zeek-pkg update

# 查看已安装包
zeek-pkg list

# 安装社区包
zeek-pkg install zeek/zeek-corelight-luajit
```

---

## 5. 方式三：源码编译（完整指南）

源码编译是获得最新特性和深度定制的最佳方式。

### 5.1 获取源码

```bash
# 从 GitHub 克隆
git clone --recurse-submodules https://github.com/zeek/zeek.git
cd zeek

# 或下载稳定版tarball
wget https://download.zeek.org/zeek-7.0.1.tar.gz
tar -xzf zeek-7.0.1.tar.gz
cd zeek-7.0.1
```

### 5.2 版本选择

```
稳定版（推荐生产）：
- Zeek 7.0.x — 长期支持版本
- Zeek 6.2.x — 上一 LTS

开发版（测试/研究）：
- Zeek main — Git master 分支
```

**LTS 版本对比**：

| 版本 | 发布日期 | 支持截止 | 关键特性 |
| :--- | :--- | :--- | :--- |
| 7.0.x | 2024-Q4 | 2026-Q4 | AF_XDP、Modern C++ |
| 6.2.x | 2023-Q2 | 2025-Q2 | Broker 稳定、JSON 流 |
| 5.2.x | 2022-Q1 | 2024-Q1 | 初步现代化 |

### 5.3 配置（cmake）

```bash
# 创建构建目录（Zeek 要求 out-of-source build）
mkdir build && cd build

# 配置（cmake）
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/zeek-7.0.1 \
    -DENABLE_AF_XDP=ON \
    -DENABLE_REDIS=ON \
    -DENABLE_PERFTOOLS=ON \
    -DUSE_PERFTOOLS=ON \
    -DBUILD_TESTING=ON

# 查看所有配置选项
cmake .. -LH
```

**关键 CMake 选项**：

| 选项 | 默认 | 说明 |
| :--- | :--- | :--- |
| `CMAKE_INSTALL_PREFIX` | `/usr/local/zeek` | 安装根目录 |
| `CMAKE_BUILD_TYPE` | `Release` | Release/Debug |
| `ENABLE_AF_XDP` | `OFF` | 启用 AF_XDP 支持 |
| `ENABLE_REDIS` | `OFF` | 启用 Redis Writer |
| `ENABLE_PERFTOOLS` | `OFF` | gperftools 内存 profiling |
| `BUILD_TESTING` | `ON` | 构建测试套件 |

### 5.4 编译

```bash
# 编译（使用 -j 加速）
make -j$(nproc)

# 测试（可选，推荐）
make test
# 或使用 btest
cd testing
btest
```

编译时间（参考）：
- 首次编译：15-30 分钟（8核机器）
- 增量编译：2-5 分钟

### 5.5 安装

```bash
sudo make install
```

### 5.6 安装后配置

```bash
# 添加到 PATH（bash）
echo 'export PATH=/opt/zeek-7.0.1/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# 或 zsh
echo 'export PATH=/opt/zeek-7.0.1/bin:$PATH' >> ~/.zshrc
source ~/.zshrc

# 验证
zeek --version
```

---

## 6. ZeekCTL 部署

`zeekctl` 是 Zeek 的集群管理和控制工具，基于 SSH 协调远程节点。

### 6.1 ZeekCTL 目录结构

```
$ZEEKBASE/          # 默认 /usr/local/zeek
├── etc/            # 配置文件
│   ├── zeekctl.cfg # zeekctl 全局配置
│   └── node.cfg   # 节点配置
├── bin/            # 可执行文件
│   ├── zeek       # 主程序
│   ├── zeekctl   # 控制工具
│   └── zeek-cut  # 日志切割工具
├── scripts/        # 启动脚本
└── lib/            # 库文件
```

### 6.2 首次配置 zeekctl

```bash
# 生成 zeekctl 配置（如果使用 tarball 安装）
zeekctl setup

# 编辑 zeekctl 配置
vim $ZEEKBASE/etc/zeekctl.cfg
```

**关键 zeekctl 配置项**：

```ini
# etc/zeekctl.cfg

[zeek]
# Zeek 二进制路径
bindir = ${scriptdir}/../bin

# 日志输出目录
logdir = /var/log/zeek

# Spool 目录（进程状态）
spooldir = /var/spool/zeek

# Zeek 脚本路径
scriptdir = ${scriptdir}

# MailRecipient 和 MailFrom（告警邮件）
mailfrom = zeek@yourdomain.com
mailhost = localhost
mailto = security@yourdomain.com

[logging]
# 日志写入策略
 stdout = zeekctl
 rotation_format = json

[production]
# 部署模式（production 启用严格检查）
deployment = production
```

### 6.3 node.cfg 配置

```ini
# etc/node.cfg — 单节点 standalone 部署

[zeek]
type = standalone
host = localhost
interface = eth0
```

**多节点集群配置**：

```ini
# etc/node.cfg — 多节点集群部署

[manager]
type = manager
host = 192.168.1.10

[proxy-1]
type = proxy
host = 192.168.1.11

[worker-1]
type = worker
host = 192.168.1.12
interface = eth0
lb_method = pf_ring  # 负载均衡方法
lb_procs = 4         # worker 进程数

[worker-2]
type = worker
host = 192.168.1.13
interface = eth0
lb_method = pf_ring
lb_procs = 4
```

### 6.4 部署命令

```bash
# 启动 zeekctl
zeekctl

# 首次部署
[ZeekControl]> deploy

# 检查状态
[ZeekControl]> status

# 查看日志
[ZeekControl]> log

# 停止
[ZeekControl]> stop

# 查看 zeek 进程
[ZeekControl]> diag zeek
```

### 6.5 检查 zeek 进程

```bash
# 检查 zeek 是否运行
ps aux | grep zeek

# 查看 zeek 日志
tail -f /var/log/zeek/current/zeek.log

# 查看连接日志
tail -f /var/log/zeek/current/conn.log

# 使用 zeek-cut 查看日志
zeek-cut ts id.orig_h id.resp_h < /var/log/zeek/current/conn.log
```

---

## 7. Docker 部署

### 7.1 官方 Docker 镜像

```bash
# 拉取官方镜像
docker pull zeek/zeek:latest

# 运行 standalone 模式
docker run --rm \
    --net=host \
    zeek/zeek:latest \
    zeek -i eth0
```

### 7.2 docker-compose 部署

```yaml
# docker-compose.yml
version: '3.8'
services:
  zeek:
    image: zeek/zeek:latest
    network_mode: host
    volumes:
      - ./zeek-logs:/var/log/zeek
      - ./zeek-scripts:/usr/local/zeek/share/zeek/site
    command: zeek -i eth0
```

---

## 8. 常见问题排查

### 8.1 libpcap 权限问题

```bash
# 错误：can't open device
# 解决：使用 sudo 运行或设置 pcap 权限
sudo setcap cap_net_raw,cap_net_admin=eip /usr/local/zeek/bin/zeek

# 或使用 -b 以 root 启动后降权
sudo zeek -i eth0
```

### 8.2 依赖缺失

```bash
# 检查缺失的库
ldd /usr/local/zeek/bin/zeek

# 如果 libtinfo.so.5 缺失（Ubuntu 22.04）
sudo apt install libtinfo5
```

### 8.3 zeekctl SSH 连接失败

```bash
# 确保 SSH key 免密登录
ssh-copy-id user@worker-host

# 测试 SSH 连接
ssh user@worker-host "echo OK"
```

### 8.4 日志目录权限

```bash
# zeekctl 需要写入日志目录
sudo mkdir -p /var/log/zeek /var/spool/zeek
sudo chown -R $USER /var/log/zeek /var/spool/zeek
```

---

## 9. 本章小结

本章覆盖了 Zeek 的完整安装部署流程：

1. **系统依赖**：libpcap、OpenSSL、flex/bison、GeoIP 等核心库
2. **三种安装方式**：包管理器、ZeekMetaPkg、源码编译
3. **源码编译详解**：cmake 配置选项、编译、测试、安装
4. **zeekctl 部署**：配置文件结构、standalone 和集群部署
5. **Docker 部署**：官方镜像和 docker-compose
6. **常见问题**：权限、依赖、SSH 连接等

**下一章**将深入讲解 Zeek 的配置系统，包括 zeekctl 配置、node.cfg 节点配置和 ZeekScript 加载机制。
