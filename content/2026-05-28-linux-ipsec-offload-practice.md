---
title: "Linux IPsec 三种加密卸载模式实战——软件、Lookaside、Inline"
date: 2026-05-28 10:00:00
tags: [Linux, IPsec, xfrm, inline-offload, QAT, strongSwan, crypto, 网络安全]
description: "在 Linux 上实战配置 IPsec 三种加密卸载模式：纯软件 (xfrm+AES-NI)、Lookaside (QAT)、Inline (NIC 硬件卸载)，包含完整命令、配置和性能对比"
---

# Linux IPsec 三种加密卸载模式实战

> [!info] 前置知识
> 本文是 [[ch30-lookaside-crypto|DPDK Lookaside 加速]] 的 Linux 内核实战篇，理论背景请先阅读该文。

---

## 1. 概述

### 1.1 三种模式回顾

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    IPsec 加密卸载三种模式                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  模式一: 纯软件 (CPU Crypto)                                               │
│  ────────────────────────────                                              │
│  ┌───────┐    ┌─────────────────────────┐    ┌───────┐                    │
│  │ 线路  │ ←→ │ 内核协议栈 (xfrm)        │ ←→ │ 应用  │                    │
│  │       │    │ CPU 执行 AES-NI 指令加密  │    │       │                    │
│  └───────┘    └─────────────────────────┘    └───────┘                    │
│  CPU 做全部: ESP 封装 + 加密 + 认证 + 解封装                               │
│                                                                             │
│  模式二: Lookaside (协处理器卸载)                                           │
│  ──────────────────────────────────                                        │
│  ┌───────┐    ┌──────────┐    ┌───────┐    ┌───────┐    ┌───────┐        │
│  │ 线路  │ ←→ │ xfrm协议 │ ←→ │  CPU  │ ←→ │  QAT  │    │       │        │
│  │       │    │ ESP封装  │    │       │    │ 加密  │    │       │        │
│  └───────┘    └──────────┘    └───────┘    └───────┘    └───────┘        │
│  CPU 做协议处理, 加密运算卸载到 QAT                                        │
│                                                                             │
│  模式三: Inline (NIC 硬件卸载)                                              │
│  ──────────────────────────────                                            │
│  ┌───────┐    ┌────────────────────────────┐    ┌───────┐                │
│  │ 线路  │ ←→ │ NIC (ESP封装 + 加密 + 认证) │ ←→ │ 应用  │                │
│  │       │    │ CPU 完全不参与加密路径        │    │       │                │
│  └───────┘    └────────────────────────────┘    └───────┘                │
│  NIC 做全部: 收到明文 → 自动加密封装 → 发密文                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 软件模拟的本质

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    硬件卸载 vs 软件模拟                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  所有模式最终只有两种执行者: CPU 或 硬件                                    │
│                                                                             │
│  "卸载" = 让硬件做                                                        │
│  "软件模拟" = 让 CPU 做, 但用同样的 API                                    │
│                                                                             │
│  Lookaside 模式:                                                           │
│    硬件: QAT PMD → 发给 PCIe 加速卡                                       │
│    软件: AESNI-MB PMD → CPU 执行 AES-NI + AVX 指令  ← 软件模拟           │
│    软件: OpenSSL PMD → 调 OpenSSL 库                 ← 软件模拟           │
│    软件: Null PMD → 什么都不做 (直通)                ← 软件模拟           │
│    对上层都是 enqueue / dequeue, 完全一样                                  │
│                                                                             │
│  Inline 模式:                                                              │
│    硬件: NIC 内部加密引擎 + ESP 协议处理器                                │
│    软件: CPU_CRYPTO → CPU 执行加密, 但应用代码和 Inline 一样             │
│           不需要手动 enqueue/dequeue              ← 软件模拟              │
│                                                                             │
│  结论:                                                                     │
│  - 没有 QAT → 用 AESNI-MB PMD 模拟 Lookaside                             │
│  - 没有 IPsec 网卡 → 用 CPU_CRYPTO 模拟 Inline                            │
│  - 没有任何硬件 → 纯软件 (模式一)                                         │
│  - API 层面 DPDK/Linux 都已统一, 换硬件不换代码                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Linux 内核支持情况

| 模式                   | 内核支持                    | 配置方式                     | 所需硬件           | 最小内核版本 |
| ---------------------- | --------------------------- | ---------------------------- | ------------------ | ------------ |
| **纯软件**             | CONFIG_XFRM + CONFIG_CRYPTO | `ip xfrm` / strongSwan       | 无 (CPU AES-NI)    | 2.6+         |
| **Lookaside**          | CONFIG_CRYPTO_DEV_QAT4xxx   | QAT 驱动注册到 crypto API    | Intel QAT 卡       | 4.x+         |
| **Lookaside 软件模拟** | 不需要额外配置              | 内核自动选 AES-NI 实现       | 无                 | 2.6+         |
| **Inline Crypto**      | CONFIG_XFRM_OFFLOAD         | `ip xfrm ... offload dev`    | 支持 IPsec 的 NIC  | 4.14+        |
| **Inline Packet**      | CONFIG_XFRM_OFFLOAD         | `ip xfrm ... offload packet` | ConnectX/BlueField | 6.2+         |

---

## 2. 环境准备

### 2.1 内核配置检查

```bash
# 检查关键内核配置
grep -E "CONFIG_XFRM|CONFIG_CRYPTO|CONFIG_INET_ESP" /boot/config-$(uname -r)

# 必须启用的配置:
# CONFIG_XFRM=y                    # XFRM 框架 (IPsec 核心)
# CONFIG_XFRM_OFFLOAD=y            # 硬件卸载支持
# CONFIG_INET_ESP=y                # ESP 协议
# CONFIG_INET_AH=y                 # AH 协议 (可选)
# CONFIG_CRYPTO_AEAD=y             # AEAD 算法框架
# CONFIG_CRYPTO_GCM=y              # AES-GCM
# CONFIG_CRYPTO_AES=y              # AES
# CONFIG_CRYPTO_AES_NI_INTEL=y     # AES-NI 硬件加速

# Inline offload 额外需要:
# CONFIG_MLX5_EN_IPSEC=y           # Mellanox IPsec offload
# 或 CONFIG_ICE_IPSEC_OFFLOAD=y    # Intel E810 IPsec offload
```

### 2.2 软件安装

```bash
# strongSwan (IKE 守护进程, 自动协商 SA)
apt install strongswan strongswan-swanctl charon-systemd
# 或
yum install strongswan

# iproute2 (ip xfrm 命令, 需要 5.x+)
ip -V
# 需要 iproute2 >= 5.9 才支持 offload 关键字

# 测试工具
apt install iperf3 tcpdump linux-perf ethtool

# 检查网卡是否支持 IPsec offload
ethtool -k enp3s0f0 | grep -i ipsec
# tx-ipsec-offload: on
# rx-ipsec-offload: on
```

### 2.3 测试拓扑

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        测试环境拓扑                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Host A (10.0.0.1)                        Host B (10.0.0.2)                │
│  ┌──────────────────────┐                 ┌──────────────────────┐        │
│  │  enp3s0f0            │   直连/交换机    │  enp3s0f0            │        │
│  │  (ConnectX-6 Dx)     │ ←─────────────→ │  (ConnectX-6 Dx)     │        │
│  │                      │                 │                      │        │
│  │  IP: 10.0.0.1/24     │                 │  IP: 10.0.0.2/24     │        │
│  │  IKE: 192.168.1.1    │                 │  IKE: 192.168.1.2    │        │
│  └──────────────────────┘                 └──────────────────────┘        │
│                                                                             │
│  管理网络 (SSH): 192.168.1.x (不在 IPsec 范围内)                           │
│  测试网络: 10.0.0.x (IPsec 保护)                                           │
│                                                                             │
│  注意: 确保管理网络和测试网络分离                                            │
│        否则 IPsec 隧道建立后 SSH 也被加密, 断了就连不上                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 模式一：纯软件 (xfrm + AES-NI)

### 3.1 手动建立 SA (ip xfrm)

```bash
# ============================================================
# Host A (10.0.0.1) 上执行
# ============================================================

# 预共享密钥 (AES-256-GCM)
KEY_A2B=aabbccddeeff0011223344556677889900aabbccddeeff0011223344556677889
KEY_B2A=11223344556677889900aabbccddeeff0011223344556677889900aabbccddeeff
SPI_A2B=0x12345678
SPI_B2A=0x87654321

# 出方向 SA (A → B)
ip xfrm state add \
    src 10.0.0.1 dst 10.0.0.2 \
    proto esp spi ${SPI_A2B} \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_A2B} 128

# 入方向 SA (B → A)
ip xfrm state add \
    src 10.0.0.2 dst 10.0.0.1 \
    proto esp spi ${SPI_B2A} \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_B2A} 128

# 出方向策略 (A → B 的流量走 IPsec)
ip xfrm policy add \
    src 10.0.0.1 dst 10.0.0.2 \
    dir out \
    tmpl src 10.0.0.1 dst 10.0.0.2 \
    proto esp mode tunnel

# 入方向策略
ip xfrm policy add \
    src 10.0.0.2 dst 10.0.0.1 \
    dir in \
    tmpl src 10.0.0.2 dst 10.0.0.1 \
    proto esp mode tunnel

# ============================================================
# Host B (10.0.0.2) 上执行 (对称配置)
# ============================================================

# 出方向 SA (B → A) — 使用 B2A 密钥
ip xfrm state add \
    src 10.0.0.2 dst 10.0.0.1 \
    proto esp spi ${SPI_B2A} \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_B2A} 128

# 入方向 SA (A → B) — 使用 A2B 密钥
ip xfrm state add \
    src 10.0.0.1 dst 10.0.0.2 \
    proto esp spi ${SPI_A2B} \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_A2B} 128

# 策略 (对称)
ip xfrm policy add \
    src 10.0.0.2 dst 10.0.0.1 \
    dir out \
    tmpl src 10.0.0.2 dst 10.0.0.1 \
    proto esp mode tunnel

ip xfrm policy add \
    src 10.0.0.1 dst 10.0.0.2 \
    dir in \
    tmpl src 10.0.0.1 dst 10.0.0.2 \
    proto esp mode tunnel
```

### 3.2 验证 SA 状态

```bash
# 查看 SA
ip xfrm state list
# 输出:
# src 10.0.0.1 dst 10.0.0.2
#   proto esp spi 0x12345678 reqid 0 mode tunnel
#   replay-window 0
#   aead rfc4106(gcm(aes)) 0xaabbccdd... 128
#   anti-replay context: seq 0x0, oseq 0x0, bitmap 0x00000000

# 查看策略
ip xfrm policy list

# 测试连通性
ping 10.0.0.2

# 抓包验证是 ESP 密文 (看不到 ICMP 明文)
tcpdump -i enp3s0f0 -n esp
# 应该看到: ESP(spi=0x12345678,seq=0x1), length 116
# 看不到 ICMP 内容 = 加密生效

# 查看 SA 统计
ip -s xfrm state list
# 关注: bytes, packets, add_time
```

### 3.3 检查 AES-NI 是否生效

```bash
# 查看内核 crypto 引用
cat /proc/crypto | grep -A 5 "gcm.*aes"
# 应该看到:
# name         : gcm(aes)
# driver       : aesni-gcm-aesni    ← "aesni" 表示使用 AES-NI 指令
# module        : kernel
# priority      : 400

# 如果看到 generic-aes 而非 aesni-gcm-aesni:
# 说明 AES-NI 未启用, 检查:
# 1. CPU 是否支持 AES-NI: grep aes /proc/cpuinfo
# 2. 内核模块是否加载: lsmod | grep aesni_intel
# 3. 手动加载: modprobe aesni_intel
```

### 3.4 使用 strongSwan 自动协商

```bash
# ============================================================
# Host A: /etc/swanctl/swanctl.conf
# ============================================================
connections {
    tunnel {
        remote_addrs = 10.0.0.2

        local {
            auth = psk
            id = 10.0.0.1
        }
        remote {
            auth = psk
            id = 10.0.0.2
        }

        children {
            net {
                local_ts = 10.0.0.1/32
                remote_ts = 10.0.0.2/32
                esp_proposals = aes256gcm16-chacha20poly1305-x25519
                mode = tunnel
            }
        }

        version = 2
        proposals = aes256-sha256-x25519
    }
}

secrets {
    ike-shared {
        id-1 = 10.0.0.1
        id-2 = 10.0.0.2
        secret = "MySecretPreSharedKey123!"
    }
}

# ============================================================
# Host B: /etc/swanctl/swanctl.conf (对称配置)
# ============================================================
connections {
    tunnel {
        remote_addrs = 10.0.0.1

        local {
            auth = psk
            id = 10.0.0.2
        }
        remote {
            auth = psk
            id = 10.0.0.1
        }

        children {
            net {
                local_ts = 10.0.0.2/32
                remote_ts = 10.0.0.1/32
                esp_proposals = aes256gcm16-chacha20poly1305-x25519
                mode = tunnel
            }
        }

        version = 2
        proposals = aes256-sha256-x25519
    }
}

secrets {
    ike-shared {
        id-1 = 10.0.0.1
        id-2 = 10.0.0.2
        secret = "MySecretPreSharedKey123!"
    }
}

# 启动 strongSwan
systemctl restart strongswan-swanctl   # 或 systemctl restart strongswan
systemctl status strongswan-swanctl

# 触发连接 (从 Host A)
swanctl --initiate --child net

# 查看协商状态
swanctl --list-sas
swanctl --list-policies
```

---

## 4. 模式二：Lookaside (Intel QAT)

### 4.1 QAT 驱动安装

```bash
# Intel QAT 驱动 (4xxx 系列)
# https://github.com/intel/QATdriver

git clone https://github.com/intel/QATdriver.git
cd QATdriver

# 编译内核模块
./configure --enable-icp-sriov=host
make -j$(nproc)
sudo make install

# 加载驱动
modprobe qat_4xxx
# 或老版本: modprobe intel_qat

# 验证
lsmod | grep qat
# qat_4xxx              16384  0

# 查看 QAT 设备
ls /dev/qat*
# /dev/qat_adf_ctl  /dev/qat_dev_processes  /dev/qat_sysfs

# 查看 QAT 状态
cat /sys/kernel/debug/qat_4xxx_0000:3d:00.0/fw_info
# 或: adf_ctl status
```

### 4.2 内核 crypto API 注册

```bash
# QAT 驱动会自动将加速算法注册到内核 crypto API
# 查看注册的算法
cat /proc/crypto | grep -B1 -A8 "driver.*qat"
# name         : gcm(aes)
# driver       : qat_aes_gcm          ← QAT 加速
# priority      : 9001                 ← 高优先级 (高于 AES-NI 的 400)
# refcnt        : 0
# selftest      : passed

# 查看优先级排名
cat /proc/crypto | grep -A3 "gcm.*aes" | grep -E "name|driver|priority"
# 内核自动选择优先级最高的实现:
#   qat_aes_gcm:    priority 9001  (QAT 硬件)
#   aesni-gcm:      priority 400   (AES-NI 指令)
#   gcm_base:       priority 100   (纯软件)

# 强制使用 QAT (可选)
# echo 0 > /proc/sys/net/core/xfrm_aevent_rseqth
# 或在 strongSwan 配置中指定算法
```

### 4.3 strongSwan 配置 QAT 卸载

```bash
# /etc/strongswan.d/charon/kernel-netlink.conf
# 确保 strongSwan 使用内核 xfrm (默认)

# strongSwan 会通过内核 crypto API 自动使用 QAT
# 只要 QAT 算法优先级高于 AES-NI, 内核会自动选择

# 验证: 启动 IPsec 后查看 QAT 统计
cat /proc/crypto | grep -A5 "qat_aes_gcm" | grep refcnt
# refcnt > 0 = QAT 正在被使用

# QAT 利用率
watch -n 1 "cat /sys/kernel/debug/qat_*/stats"
# 关注: num_crypto_requests, throughput_mbps
```

### 4.4 CPU 占用对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│            模式一 vs 模式二 CPU 占用对比                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  测试: iperf3 -c 10.0.0.2 -t 30 -P 4 -B 10Gbps                            │
│                                                                             │
│  模式一 (纯软件 AES-NI):                                                   │
│  ──────────────────────────                                                │
│  perf top -C 0                                                             │
│  12.3%  aesni_gcm_enc             ← 加密占 12% CPU                        │
│   3.1%  esp6_output               ← ESP 封装                              │
│   2.8%  xfrm_output               ← XFRM 框架                             │
│   1.5%  iptable_filter            ← 防火墙                                │
│                                                                             │
│  模式二 (QAT Lookaside):                                                   │
│  ──────────────────────────                                                │
│  perf top -C 0                                                             │
│   3.1%  esp6_output               ← ESP 封装 (不变)                       │
│   2.8%  xfrm_output               ← XFRM 框架 (不变)                      │
│   1.2%  qat_aes_gcm               ← QAT 驱动开销 (很小)                   │
│   0.3%  aesni_gcm_enc             ← 部分操作可能仍在 CPU                   │
│                                                                             │
│  关键: ESP 封装/解封开销不变 (CPU 仍做协议处理)                             │
│  只有"加密运算"被卸载, 协议处理仍然消耗 CPU                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 模式三A：Inline Crypto Offload (SA 卸载)

### 5.1 网卡准备

```bash
# Mellanox ConnectX-6/7 Dx 需要启用 IPsec offload
# 确认固件支持
mlxfwmanager --query

# 启用 IPsec offload (需要重启固件)
# 方法 1: mlxconfig
mlxconfig -d /dev/mst/mt4123_pciconf0 set IPSEC_OVER_RX=1 IPSEC_OVER_TX=1
# 重启后生效

# 方法 2: devlink
devlink dev param set pci/0000:3d:00.0 name ipsec_mode value true cmode runtime

# 验证
ethtool -k enp3s0f0 | grep ipsec
# tx-ipsec-offload: on
# rx-ipsec-offload: on

# Intel E810
ethtool -k enp3s0f0 | grep ipsec
# tx-ipsec-offload-hw: on
# rx-ipsec-offload-hw: on
```

### 5.2 配置 SA 卸载

```bash
# ============================================================
# Host A: 手动建立带 offload 的 SA
# ============================================================

# 出方向 SA → 卸载到网卡
ip xfrm state add \
    src 10.0.0.1 dst 10.0.0.2 \
    proto esp spi 0x12345678 \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_A2B} 128 \
    offload dev enp3s0f0 dir out
#          ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
#    这一行把 SA 下发到网卡硬件

# 入方向 SA → 卸载到网卡
ip xfrm state add \
    src 10.0.0.2 dst 10.0.0.1 \
    proto esp spi 0x87654321 \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_B2A} 128 \
    offload dev enp3s0f0 dir in

# 策略 (与模式一相同, 不变)
ip xfrm policy add \
    src 10.0.0.1 dst 10.0.0.2 dir out \
    tmpl src 10.0.0.1 dst 10.0.0.2 proto esp mode tunnel

ip xfrm policy add \
    src 10.0.0.2 dst 10.0.0.1 dir in \
    tmpl src 10.0.0.2 dst 10.0.0.1 proto esp mode tunnel

# ============================================================
# 验证 SA 已卸载到网卡
# ============================================================
ip xfrm state list
# 应该能看到 "crypto-offload" 标记:
# src 10.0.0.1 dst 10.0.0.2
#   proto esp spi 0x12345678 reqid 0 mode tunnel
#   aead rfc4106(gcm(aes)) 0x... 128
#   crypto-offload dev enp3s0f0 dir out   ← 关键标记

# 查看网卡 IPsec 统计
ethtool -S enp3s0f0 | grep -i ipsec
# rx_ipsec_packets: 14523
# tx_ipsec_packets: 14520
# rx_ipsec_bytes:   8714073
# tx_ipsec_bytes:   8714023
```

### 5.3 strongSwan 配置 Inline Crypto Offload

```bash
# /etc/swanctl/swanctl.conf — 添加 offload 配置
connections {
    tunnel {
        remote_addrs = 10.0.0.2
        local { auth = psk; id = 10.0.0.1 }
        remote { auth = psk; id = 10.0.0.2 }

        children {
            net {
                local_ts = 10.0.0.1/32
                remote_ts = 10.0.0.2/32
                esp_proposals = aes256gcm16-x25519
                mode = tunnel

                # Inline crypto offload
                hw_offload = crypto
                #               ↑↑↑↑↑↑↑
                # "crypto" = 只卸载加密运算 (SA offload)
                # "packet" = 全卸载 (需要内核 6.2+, 见 5.4 节)
                # "no"     = 纯软件 (默认)
            }
        }
        version = 2
        proposals = aes256-sha256-x25519
    }
}

# 如果 hw_offload 字段不被支持, 可能需要在 charon 配置中设置:
# /etc/strongswan.d/charon/kernel-netlink.conf
# kernel-netlink {
#     install_xfrm_policy = yes
#     install_xfrm_state = yes
# }
```

### 5.4 验证 Inline Crypto 工作状态

```bash
# 1. SA 状态确认有 offload 标记
ip xfrm state list | grep -A3 "offload"
# crypto-offload dev enp3s0f0 dir out

# 2. 抓包确认线路上是密文
tcpdump -i enp3s0f0 -n -c 5 esp
# ESP(spi=0x12345678,seq=0x5), length 116

# 3. CPU 占用应该大幅下降
perf top -C 0
# 不应该看到 aesni_gcm_enc
# 仍会看到少量 esp6_output (内核做 ESP 头封装)

# 4. 网卡统计递增
ethtool -S enp3s0f0 | grep -i ipsec
watch -n 1 "ethtool -S enp3s0f0 | grep ipsec"
```

---

## 6. 模式三B：Inline Packet Offload (全卸载)

### 6.1 前提条件

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               Inline Packet Offload 要求                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  内核: >= 6.2 (packet offload 支持)                                        │
│  iproute2: >= 6.0 (offload packet 关键字)                                  │
│  网卡:                                                                      │
│    - NVIDIA ConnectX-6 Dx / ConnectX-7 Dx (switchdev 模式)                │
│    - NVIDIA BlueField-2/3 DPU (switchdev 模式)                             │
│    - Marvell OCTEON cnxk                                                   │
│                                                                             │
│  switchdev 模式说明:                                                       │
│  ──────────────────                                                        │
│  ConnectX 默认工作在 netdev 模式 (每个端口一个 PF netdev)                  │
│  Inline packet offload 需要切换到 switchdev 模式:                          │
│                                                                             │
│  # 切换到 switchdev 模式                                                   │
│  devlink dev eswitch set pci/0000:3d:00.0 mode switchdev                   │
│                                                                             │
│  切换后:                                                                    │
│  - PF 变成 representor (管理口)                                            │
│  - VF 变成独立的 netdev (数据口)                                           │
│  - IPsec 全卸载在 VF 数据口上工作                                          │
│                                                                             │
│  注意: switchdev 模式切换会导致网络中断, 需要带外管理                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 配置 Packet Offload

```bash
# ============================================================
# 确认内核版本 >= 6.2
# ============================================================
uname -r
# 6.8.0-xx-generic  (OK)

# iproute2 版本
ip -V
# iproute2-6.1.0  (OK)

# ============================================================
# 切换到 switchdev 模式 (如果尚未切换)
# ============================================================
# 查看当前模式
devlink dev eswitch show pci/0000:3d:00.0
# mode legacy → 需要切换

# 创建 VF (如果还没有)
echo 2 > /sys/class/net/enp3s0f0/device/sriov_numvfs

# 切换 switchdev
devlink dev eswitch set pci/0000:3d:00.0 mode switchdev
# 网络会短暂中断

# 新的 netdev 名称会变化, 用 ip link 查看
ip link show

# ============================================================
# 配置 Packet Offload SA
# ============================================================

# 出方向 — 全卸载到网卡
ip xfrm state add \
    src 10.0.0.1 dst 10.0.0.2 \
    proto esp spi 0x12345678 \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_A2B} 128 \
    offload dev enp3s0f0 dir out \
    offload packet
#            ↑↑↑↑↑↑↑
# "packet" 关键字 = 全卸载模式

# 入方向 — 全卸载到网卡
ip xfrm state add \
    src 10.0.0.2 dst 10.0.0.1 \
    proto esp spi 0x87654321 \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' \
    ${KEY_B2A} 128 \
    offload dev enp3s0f0 dir in \
    offload packet

# 策略 — packet offload 模式下也需要卸载策略
ip xfrm policy add \
    src 10.0.0.1 dst 10.0.0.2 dir out \
    tmpl src 10.0.0.1 dst 10.0.0.2 proto esp mode tunnel \
    offload dev enp3s0f0 dir out

# ============================================================
# 验证
# ============================================================
ip xfrm state list
# 应该看到 "packet-offload" 标记:
#   packet-offload dev enp3s0f0 dir out
```

### 6.3 strongSwan 配置 Packet Offload

```bash
# /etc/swanctl/swanctl.conf
children {
    net {
        local_ts = 10.0.0.1/32
        remote_ts = 10.0.0.2/32
        esp_proposals = aes256gcm16-x25519
        mode = tunnel

        # 全卸载
        hw_offload = packet
    }
}

# strongSwan 5.9.10+ 支持 packet offload
swanctl --version
# strongSwan 5.9.10 或更高

# 重启并触发
systemctl restart strongswan-swanctl
swanctl --initiate --child net
```

### 6.4 Crypto Offload vs Packet Offload 对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│            Crypto Offload vs Packet Offload                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│              Crypto Offload              Packet Offload                     │
│              (SA 卸载)                   (全卸载)                            │
│                                                                             │
│  CPU 做的事:                                                                │
│  - 查找 SA                ✓              ✗                                  │
│  - 生成 IV                ✓              ✗                                  │
│  - 递增序列号             ✓              ✗                                  │
│  - ESP 封装 (加头/尾)     ✓              ✗                                  │
│  - 加密 payload           ✗ (NIC)        ✗ (NIC)                           │
│  - 计算 ICV               ✗ (NIC)        ✗ (NIC)                           │
│  - 修改 IP 头             ✓              ✗                                  │
│                                                                             │
│  NIC 做的事:                                                                │
│  - 加密 + 认证            ✓              ✓                                  │
│  - ESP 全流程             ✗              ✓                                  │
│  - 策略匹配               ✗              ✓                                  │
│                                                                             │
│  CPU 占用:                 中 (~30%)      极低 (<5%)                        │
│  内核版本:                 >= 4.14        >= 6.2                            │
│  网卡要求:                 较低           switchdev 模式                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. DPDK 软件模拟三种模式 (无硬件对照实验)

本文前面讲的是 Linux 内核路径, 这里补充 DPDK 用户态路径。
以下实验不需要 QAT 卡或 IPsec 网卡, 只需要 CPU, 就能跑通三种模式。

### 7.1 环境准备

```bash
# 编译 DPDK (确保启用 crypto PMD)
cd /path/to/dpdk
meson setup build -Dcrypto_ipsec_mb=enabled
ninja -C build -j$(nproc)

# 验证 AESNI-MB PMD 可用
ls build/drivers/crypto/
# 应该能看到 ipsec_mb 相关的库

# 编译 ipsec-secgw 示例 (DPDK 自带的 IPsec 安全网关)
cd examples/ipsec-secgw
make -j$(nproc)
```

### 7.2 软件模拟 Lookaside (AESNI-MB PMD)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│           软件模拟 Lookaside: AESNI-MB PMD                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  原理:                                                                     │
│  - 应用构造 crypto_op → enqueue → AESNI-MB PMD → CPU 执行 AES-NI         │
│  - 和真正的 QAT Lookaside 用完全一样的代码路径                            │
│  - 只是 enqueue 最终调用的是 CPU SIMD 函数而非 QAT 硬件                   │
│                                                                             │
│  对比:                                                                     │
│  真正 Lookaside:  enqueue → QAT PMD → PCIe → QAT 硬件 → PCIe → dequeue  │
│  软件模拟:       enqueue → AESNI-MB PMD → CPU AES-NI → dequeue           │
│  代码完全一样, 只有 PMD 不同                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```bash
# 启动 ipsec-secgw 使用 AESNI-MB 软件 PMD
# 使用 lib ipsec (app_sa_prm.enable=1) 做 ESP 处理

./build/ipsec-secgw \
    -l 0,1 -n 4 \
    --vdev crypto_aesni_mb \         # ← 软件 PMD, 不需要硬件
    -a 0000:3d:00.0 \
    -- \
    -p 0x3 \
    --config "(0,0,0),(1,0,1)" \
    -u 0x1 \
    --app-mode=ipsec-lookup \
    --sa-file /tmp/sa_lookup.cfg \
    --route-file /tmp/route.cfg

# sa_lookup.cfg 示例 (出方向, AES-GCM)
# sp IPv4 out 10.0.0.0/24 10.0.1.0/24 priority 1
# sa out 7 cipher_algo aes-256-gcm \
#    cipher_key aabbccddeeff0011223344556677889900aabbccddeeff0011223344556677889 \
#    auth_algo null \
#    mode ipv4-tunnel src 172.16.0.1 dst 172.16.1.1
# route 10.0.1.0/24 port 1

# 没有 --vdev crypto_aesni_mb 换成 --vdev crypto_openssl 就是另一个软件 PMD
# 没有 --vdev crypto_aesni_mb 换成 -a <qat_pci> 就是真正的 QAT 硬件 Lookaside
# 你的应用代码一行不用改
```

### 7.3 软件模拟 Inline (CPU_CRYPTO 模式)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│           软件模拟 Inline: CPU_CRYPTO 模式                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  原理:                                                                     │
│  - 应用代码和 Inline 模式一样, 不需要手动 enqueue/dequeue                 │
│  - rte_ipsec 内部自动调用 AESNI PMD 完成加密                              │
│  - 对应用来说看起来像 Inline (API 简洁)                                   │
│  - 实际加密还是 CPU 在做                                                  │
│                                                                             │
│  对比:                                                                     │
│  真正 Inline:    应用调用 pkt_process → NIC 自动加密                       │
│  CPU_CRYPTO:     应用调用 pkt_cpu_prepare → CPU 自动加密                   │
│  应用层 API 几乎一样, 但执行者不同                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```c
// CPU_CRYPTO 模式的应用代码

// 初始化 SA 时指定 CPU_CRYPTO action type
struct rte_security_session_conf sec_conf = {
    .action_type = RTE_SECURITY_ACTION_TYPE_CPU_CRYPTO,
    //             ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
    // 不是 LOOKASIDE_PROTOCOL, 不是 INLINE_CRYPTO
    // 而是 CPU_CRYPTO = "用 CPU 模拟 inline"
    .protocol = RTE_SECURITY_PROTOCOL_IPSEC,
    .ipsec = {
        .proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
        .mode = RTE_SECURITY_IPSEC_SA_MODE_TUNNEL,
        .direction = RTE_SECURITY_IPSEC_SA_DIR_EGRESS,
        // ...
    },
    .crypto_xform = &xform,
};

// 出方向处理 (注意: 不需要手动 enqueue/dequeue!)
uint16_t nb_processed;

// CPU_CRYPTO 模式用 pkt_cpu_prepare 而非 pkt_crypto_prepare
nb_processed = rte_ipsec_pkt_cpu_prepare(&ipsec_session, tx_mbufs, n);
// 内部自动: 生成 IV → 加密 → 计算 ICV, 全部在 CPU 上完成

nb_processed = rte_ipsec_pkt_process(&ipsec_session, tx_mbufs, n);
// 内部自动: 封装 ESP 头 + outer IP 头

rte_eth_tx_burst(port, queue, tx_mbufs, nb_processed);
// 发送

// 入方向处理
rte_ipsec_sad_lookup(sad, keys, sa_ptrs, n);
nb_processed = rte_ipsec_pkt_cpu_prepare(&ipsec_session, rx_mbufs, n);
// 内部自动: 解密 + 验证 ICV
nb_processed = rte_ipsec_pkt_process(&ipsec_session, rx_mbufs, n);
// 内部自动: 剥离 ESP 头
process_packet(rx_mbufs);
```

### 7.4 四种模式 API 对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               四种模式的代码差异 (出方向)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ① Lookaside (QAT 或 AESNI-MB PMD):                                      │
│  ──────────────────────────────────                                        │
│  rte_ipsec_pkt_crypto_prepare(ss, mb, ops, n);  // 你准备 crypto op      │
│  rte_cryptodev_enqueue_burst(dev, qp, ops, n);   // 你提交加密           │
│  rte_cryptodev_dequeue_burst(dev, qp, ops, n);   // 你等完成             │
│  rte_ipsec_pkt_process(ss, mb, n);                // 你封装 ESP           │
│  rte_eth_tx_burst(port, queue, mb, n);            // 发送                 │
│  → 5 步, 你手动管理 crypto op 的生命周期                                  │
│                                                                             │
│  ② CPU_CRYPTO (软件模拟 Inline):                                          │
│  ──────────────────────────────────                                        │
│  rte_ipsec_pkt_cpu_prepare(ss, mb, n);   // 自动加密, 无需 crypto op     │
│  rte_ipsec_pkt_process(ss, mb, n);        // 自动封装 ESP                │
│  rte_eth_tx_burst(port, queue, mb, n);    // 发送                         │
│  → 3 步, 不需要手动 enqueue/dequeue                                      │
│                                                                             │
│  ③ Inline Crypto (NIC SA 卸载):                                           │
│  ──────────────────────────────────                                        │
│  rte_ipsec_pkt_process(ss, mb, n);        // NIC 自动加密+封装           │
│  rte_eth_tx_burst(port, queue, mb, n);    // 发送                         │
│  → 2 步, 加密在 TX 时由 NIC 完成                                         │
│                                                                             │
│  ④ Inline Protocol (全卸载):                                              │
│  ──────────────────────────────────                                        │
│  rte_eth_tx_burst(port, queue, mb, n);    // NIC 自动做一切              │
│  → 1 步, 明文包进网卡, 密文包出网卡                                      │
│                                                                             │
│  代码复杂度: Lookaside > CPU_CRYPTO > Inline Crypto > Inline Protocol     │
│  硬件要求:   不需要 > 不需要 > IPsec NIC > switchdev NIC                  │
│                                                                             │
│  软件模拟的意义:                                                           │
│  - 没有硬件时也能用完整 API 开发和测试                                    │
│  - 代码架构不变, 以后加硬件只需改一行配置                                 │
│  - 性能测试时可以对比 "CPU 做全部" vs "硬件卸载" 的差距                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 性能对比测试

### 8.1 测试方法

```bash
# 吞吐量测试
# Host B 作为 server
iperf3 -s -B 10.0.0.2

# Host A 作为 client (每种模式分别测试)
iperf3 -c 10.0.0.2 -t 60 -P 4 -B 10.0.0.1 \
    --json > /tmp/result_software.json

# 延迟测试
ping -i 0.001 -c 10000 10.0.0.2 | tail -1

# CPU 占用 (另开终端)
perf stat -e cycles,instructions,cache-misses -C 0 sleep 60

# XFRM 统计 (加密了多少包/字节)
ip -s xfrm state list | grep -E "bytes|packets"

# 网卡 IPsec 统计 (inline 模式)
ethtool -S enp3s0f0 | grep ipsec
```

### 8.2 预期性能对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                 三种模式性能对比 (参考值)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  测试条件: AES-256-GCM, 1400 字节包, ConnectX-6 Dx, Xeon Gold 6348        │
│                                                                             │
│  指标           纯软件      Lookaside    Inline Crypto   Inline Packet     │
│  ────           ────────    ─────────    ─────────────   ─────────────     │
│  吞吐量         ~8 Gbps     ~20 Gbps     ~25 Gbps       ~40 Gbps         │
│  CPU 占用       ~80%        ~30%         ~15%           ~3%              │
│  延迟 (avg)     ~50μs       ~80μs        ~30μs          ~15μs            │
│  延迟 (P99)     ~120μs      ~200μs       ~60μs          ~25μs            │
│                                                                             │
│  说明:                                                                    │
│  - 纯软件: AES-NI 很快, 但 CPU 做全部协议处理, 吞吐瓶颈在 CPU            │
│  - Lookaside: 加密卸载到 QAT, 但 CPU↔QAT 往返增加延迟                    │
│  - Inline Crypto: 加密在 NIC, 但 ESP 封装仍在 CPU                        │
│  - Inline Packet: 全部在 NIC, CPU 几乎不参与                              │
│                                                                             │
│  注意: 实际数据取决于 CPU 型号、网卡型号、包大小、频率等                   │
│        以上数据仅作为模式间的相对参考                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.3 perf 热点对比

```bash
# 每种模式下运行 perf 分析
perf record -F 999 -a -g -C 0 -- sleep 30
perf report --stdio --no-kernel --percent-limit 1

# 预期热点分布:
#
# 纯软件:
#   15%  aesni_gcm_enc          # 加密
#    5%  esp6_output_head        # ESP 封装
#    3%  skb_to_sgvec            # scatter-gather
#    2%  xfrm_output_resume     # XFRM 状态机
#
# Lookaside (QAT):
#    5%  esp6_output_head        # ESP 封装 (不变)
#    3%  qat_algs_send           # QAT 驱动
#    2%  xfrm_output_resume     # XFRM 状态机 (不变)
#    1%  qat_compression         # QAT 硬件交互
#
# Inline Crypto:
#    3%  esp6_output_head        # ESP 封装
#    2%  xfrm_output_resume     # XFRM 状态机
#    1%  mlx5e_ipsec_tx          # 网卡 IPsec 驱动
#    0%  aesni_gcm_enc           # 加密已卸载!
#
# Inline Packet:
#    1%  netif_receive_skb       # 基本的网络栈
#    0%  esp / xfrm              # 协议处理已卸载!
```

---

## 9. 排坑指南

### 9.1 常见问题

```bash
# 问题 1: "RTNETLINK answers: Operation not supported"
# 原因: 内核未启用 XFRM_OFFLOAD 或网卡不支持
grep XFRM_OFFLOAD /boot/config-$(uname -r)
ethtool -k enp3s0f0 | grep ipsec

# 问题 2: "Crypto offload init failed"
# 原因: 网卡 IPsec 功能未启用
mlxconfig -d /dev/mst/mt4123_pciconf0 query | grep IPSEC
# 如果 IPSEC_OVER_RX/TX=0, 需要启用:
mlxconfig -d /dev/mst/mt4123_pciconf0 set IPSEC_OVER_RX=1 IPSEC_OVER_TX=1
# 然后重启服务器

# 问题 3: SA 已建立但流量不走 IPsec
# 检查策略
ip xfrm policy list
# 确认 dir out/in 的 src/dst 匹配

# 问题 4: "No buffer space available" (inline 模式)
# 原因: 网卡 IPsec SA 容量已满
# ConnectX-6 Dx 最多支持 ~128 个 SA
# 检查已有 SA 数量
ip xfrm state list | grep "offload" | wc -l

# 问题 5: strongSwan 协商失败
# 查看 strongSwan 日志
journalctl -u strongswan-swanctl -f
# 或
swanctl --log

# 问题 6: QAT 没有被使用 (Lookaside 模式)
# 检查 QAT 算法优先级
cat /proc/crypto | grep -A3 "gcm.*aes" | grep priority
# 确认 qat_aes_gcm 优先级 > aesni_gcm
# 如果不是, 重新加载 QAT 模块:
rmmod qat_4xxx && modprobe qat_4xxx

# 问题 7: Packet offload 模式不支持
# 检查内核版本
uname -r  # 需要 >= 6.2
# 检查网卡是否在 switchdev 模式
devlink dev eswitch show pci/0000:3d:00.0
# 需要 mode switchdev
```

### 9.2 调试工具

```bash
# XFRM 调试 (查看内核 xfrm 日志)
echo 1 > /proc/sys/net/core/xfrm_debug

# SA 全量信息
ip -d -s xfrm state list

# 策略全量信息
ip -d xfrm policy list

# 网卡 IPsec 详细统计 (Mellanox)
ethtool -S enp3s0f0 | grep -i "ipsec\|esp\|crypto"

# 内核 XFRM 事件跟踪
ip monitor xfrm state
ip monitor xfrm policy

# 抓包分析
tcpdump -i enp3s0f0 -n -vvv esp
tcpdump -i enp3s0f0 -n "proto 50"   # ESP = protocol 50

# perf 分析加密开销
perf top -K -C 0                      # 只看内核热点
perf record -e 'net:*' -a sleep 10    # 网络事件追踪
perf script | grep -i xfrm

# Mellanox 固件调试
mlxreg --reg_name MTUTC --get
mlxdump -d /dev/mst/mt4123_pciconf0 fs_dump --type FS_TREE
```

### 9.3 快速切换模式

```bash
#!/bin/bash
# switch_ipsec_mode.sh — 快速切换 IPsec 模式
# 使用方法: ./switch_ipsec_mode.sh [software|lookaside|inline-crypto|inline-packet]

MODE=$1
DEV=enp3s0f0
SRC=10.0.0.1
DST=10.0.0.2
KEY=aabbccddeeff0011223344556677889900aabbccddeeff0011223344556677889
SPI_OUT=0x12345678
SPI_IN=0x87654321

# 清理旧 SA 和策略
ip xfrm state flush
ip xfrm policy flush

OFFLOAD_FLAG=""
case $MODE in
    software)       OFFLOAD_FLAG="" ;;
    inline-crypto)  OFFLOAD_FLAG="offload dev ${DEV} dir out" ;;
    inline-packet)  OFFLOAD_FLAG="offload dev ${DEV} dir out offload packet" ;;
    lookaside)      OFFLOAD_FLAG="" ;;  # Lookaside 通过 crypto API 自动选择
    *)              echo "Usage: $0 [software|lookaside|inline-crypto|inline-packet]"; exit 1 ;;
esac

# 建立出方向 SA
ip xfrm state add \
    src ${SRC} dst ${DST} \
    proto esp spi ${SPI_OUT} \
    mode tunnel \
    aead 'rfc4106(gcm(aes))' ${KEY} 128 \
    ${OFFLOAD_FLAG}

# 建立入方向 SA (对称的 offload dir)
if [ "$MODE" = "inline-crypto" ]; then
    ip xfrm state add src ${DST} dst ${SRC} proto esp spi ${SPI_IN} \
        mode tunnel aead 'rfc4106(gcm(aes))' ${KEY} 128 \
        offload dev ${DEV} dir in
elif [ "$MODE" = "inline-packet" ]; then
    ip xfrm state add src ${DST} dst ${SRC} proto esp spi ${SPI_IN} \
        mode tunnel aead 'rfc4106(gcm(aes))' ${KEY} 128 \
        offload dev ${DEV} dir in offload packet
else
    ip xfrm state add src ${DST} dst ${SRC} proto esp spi ${SPI_IN} \
        mode tunnel aead 'rfc4106(gcm(aes))' ${KEY} 128
fi

# 策略
ip xfrm policy add src ${SRC} dst ${DST} dir out \
    tmpl src ${SRC} dst ${DST} proto esp mode tunnel
ip xfrm policy add src ${DST} dst ${SRC} dir in \
    tmpl src ${DST} dst ${SRC} proto esp mode tunnel

echo "IPsec mode switched to: ${MODE}"
ip xfrm state list | grep -E "offload|proto"
```

---

## 10. 小结

1. **纯软件 (xfrm + AES-NI)**：零硬件依赖，延迟最低 (~50ns 加密)，但吞吐受限于 CPU。适合中小流量场景。使用 `ip xfrm` 或 strongSwan 配置。

2. **Lookaside (QAT)**：加密卸载到 PCIe 加速卡，CPU 只做协议处理。吞吐提升 2-3 倍，但 CPU↔QAT 往返增加延迟。QAT 驱动通过内核 crypto API 自动注册，对上层透明。

3. **Inline Crypto Offload (SA 卸载)**：加密在 NIC 内完成，零内存拷贝。需要 `ip xfrm ... offload dev <nic>` 配置。内核仍做 ESP 封装，CPU 占用中等。

4. **Inline Packet Offload (全卸载)**：内核 6.2+ 支持，NIC 完成全部 IPsec 处理。需要 switchdev 模式。CPU 占用接近零，吞吐最高。

5. **配置方式统一**：四种模式都通过 `ip xfrm` 和 strongSwan 管理，差异仅在于 `offload` 关键字。切换模式不需要换工具链。

6. **选择建议**：< 5 Gbps 用纯软件；5-20 Gbps 看是否有 QAT；> 20 Gbps 必须用 Inline。Inline Packet 是最终目标，但需要较新的内核和 switchdev 网卡。

7. **软件模拟**：所有模式都能纯软件运行。没有 QAT → 用 AESNI-MB PMD 模拟 Lookaside；没有 IPsec 网卡 → 用 CPU_CRYPTO 模拟 Inline。代码架构不变，加硬件时只需改一行配置。

> [!tip] 相关阅读
>
> - [[ch30-lookaside-crypto|DPDK Lookaside 加速]] — DPDK 框架下的三种模式详解
> - [XFRM Device 内核文档](https://docs.kernel.org/networking/xfrm/xfrm_device.html)
> - [NVIDIA IPsec Crypto Offload](https://docs.nvidia.com/networking/display/MLNXOFEDv24101140lts/IPsec+Crypto+Offload)
> - [NVIDIA IPsec Packet Offload](https://docs.nvidia.com/doca/archive/3-0-0/ipsec+packet+offload/index.html)
> - [strongSwan Hardware Offload](https://wiki.strongswan.org/projects/strongswan/wiki/IpsecHW)
> - [Linux XFRM Reference Guide](https://pchaigno.github.io/xfrm/2024/10/30/linux-xfrm-ipsec-reference-guide.html)
> - [LWN: Extend XFRM Core for Packet Offload](https://lwn.net/Articles/916838/)
