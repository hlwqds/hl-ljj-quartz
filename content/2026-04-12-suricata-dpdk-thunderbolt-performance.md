---
title: Suricata + DPDK 性能测试 — Thunderbolt 拓展坞 + 25GbE
date: 2026-04-12 00:00:00
tags: [suricata, dpdk, ids, performance, thunderbolt, 25gbe]
description: 在 Thunderbolt 拓展坞 + Mellanox 25GbE 环境下编译和测试 Suricata DPDK 模式的性能
---

# Suricata + DPDK 性能测试 — Thunderbolt 拓展坞 + 25GbE

## 背景

基于 [DPDK + 25GbE on Thunderbolt](/2026-04-12-dpdk-thunderbolt-mellanox-guide) 确认 Thunderbolt 拓展坞下 DPDK 可行后，测试 Suricata IDS 在 DPDK 模式下的检测性能。

### 目标

- 在 Thunderbolt + Mellanox 环境下编译 Suricata DPDK 模式
- 测量不同规则集下的吞吐量和丢包率
- 验证 DPDK 模式相比 AF_PACKET 的性能优势

### 环境

| 项目     | 值                                                                      |
| -------- | ----------------------------------------------------------------------- |
| Suricata | 9.0.0-dev（源码编译），启用 DPDK 支持                                   |
| DPDK     | 24.11.4，已通过 trust_tb 解决 Thunderbolt DMA 限制                      |
| 网卡     | Mellanox ConnectX-4 Lx MCX4121A（双口 25GbE）                           |
| 连接     | SFP28 DAC 直连铜缆                                                      |
| 系统     | Fedora 43，内核 6.19.11                                                 |
| CPU      | Intel Meteor Lake，6P+8E（CPU 0-13 大核 5.4GHz，CPU 14-15 小核 2.5GHz） |

## 编译

### 前置：解除 CPU 频率限制

Fedora 43 默认 `powersave` 调频策略 + `balanced` 平台配置，笔记本编译会严重降频（最低 400MHz），Rust 编译极其缓慢。编译前必须解除：

```bash
# 1. CPU 调频策略切为 performance
sudo bash -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $c; done'

# 2. 平台配置切为 performance（解除 OEM 频率上限）
echo performance | sudo tee /sys/firmware/acpi/platform_profile
```

验证：

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
# performance

cat /sys/firmware/acpi/platform_profile
# performance
```

> 恢复默认：`sudo bash -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > $c; done'` + `echo balanced | sudo tee /sys/firmware/acpi/platform_profile`

### 依赖安装

```bash
sudo dnf install -y autoconf automake libtool gcc make \
  libbsd-devel libyaml-devel pcre2-devel jansson-devel \
  libpcap-devel file-devel zlib-devel libcap-ng-devel \
  libnet-devel numactl-devel libnl3-devel dbus-devel \
  libbpf-devel libunwind-devel librdkafka-devel

# Rust 工具链
rustup install 1.89.0
cd /path/to/suricata/rust && rustup override set 1.89.0
cargo install cbindgen
```

> **Rust 版本说明：** Suricata `Cargo.toml` 要求最低 `rust-version = "1.75.0"`，但未锁定上限。实测 rustc 1.94.1 编译 `suricata` crate 单核超过 10 分钟，而 1.89.0 只需约 1 分钟，差距巨大。建议使用 1.89.0。详见 [Rust LTO 原理与影响](/2026-04-13-rust-lto-principle-and-impact)。

| 包                | 用途                                 |
| ----------------- | ------------------------------------ |
| libbsd-devel      | `strlcpy` 等 BSD 兼容函数            |
| pcre2-devel       | 正则表达式引擎（规则匹配）           |
| jansson-devel     | JSON 解析（EVE 日志输出）            |
| librdkafka-devel  | Kafka 输出支持                       |
| libbpf-devel      | eBPF 支持                            |
| libcap-ng-devel   | 权限降级                             |
| cbindgen（cargo） | 生成 `rust-bindings.h`（C-Rust FFI） |
| rust/cargo        | Rust 组件编译（app-layer 等）        |

### 配置

```bash
cd /path/to/suricata
autoreconf -fi

PKG_CONFIG_PATH="/path/to/dpdk/build/meson-uninstalled:/path/to/dpdk/build/meson-private" \
CFLAGS="-I/usr/include/librdkafka" \
./configure --enable-unix-socket --enable-rdkafka --enable-dpdk \
  --prefix=/usr --localstatedir=/var --sysconfdir=/etc
```

> **说明：**
>
> - `PKG_CONFIG_PATH`：DPDK 本地编译时，`meson-uninstalled/libdpdk-uninstalled.pc` 包含正确的头文件和库路径，`meson-private/libdpdk.pc` 指向 `/usr/local/include`（头文件不在那里）
> - `CFLAGS="-I/usr/include/librdkafka"`：Fedora 的 `librdkafka-devel` 将头文件安装在 `/usr/include/librdkafka/rdkafka.h`，而 Suricata 搜索 `<rdkafka.h>`（无子目录），configure 检测头文件失败但库链接成功，实际编译时找不到

配置输出确认：

```
DPDK support:      yes
DPDK Bond PMD:     no    # 不影响单口测试
rdkafka support:   yes
Rust compiler:     1.89.0
```

### 编译

```bash
make -j$(nproc)
```

编译完成后验证：

```bash
LD_LIBRARY_PATH="/path/to/dpdk/build/lib" ./src/suricata --build-info | grep -E "DPDK|rdkafka|Rust|JA3|JA4"
# DPDK support:                            yes
# rdkafka support:                         yes
# Rust support:                            yes
# JA3 support:                             yes
# JA4 support:                             yes
```

> **运行时依赖：** Suricata 链接了 DPDK 动态库，启动时需要设置 `LD_LIBRARY_PATH` 指向 DPDK 的 `build/lib/` 目录。

## 运行前置条件

在启动 Suricata DPDK 模式之前，需要完成以下环境准备：

```bash
# 1. 加载 trust_tb 内核模块（清除 Thunderbolt untrusted 标记）
sudo insmod ~/code/tools/trust_tb/trust_tb.ko

# 2. 分配 Hugepages
sudo sysctl -w vm.nr_hugepages=1024

# 3. 创建日志目录
sudo mkdir -p /var/log/suricata

# 4. 安装系统配置文件
sudo mkdir -p /etc/suricata /var/lib/suricata/rules
sudo cp /path/to/suricata/etc/*.config /etc/suricata/
```

## Suricata DPDK 配置

使用独立的测试配置文件 `suricata-dpdk-test.yaml`，禁用 af-packet 和 pcap，仅启用 DPDK 模式：

```yaml
%YAML 1.1
---
# Suricata DPDK 测试配置 — Thunderbolt + Mellanox 25GbE
# 仅保留 DPDK 模式，禁用 af-packet/pcap 等其他 capture

suricata-version: "9.0"

vars:
  address-groups:
    HOME_NET: "[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]"
    EXTERNAL_NET: "!$HOME_NET"
  port-groups:
    HTTP_PORTS: "80"
    HTTPS_PORTS: "443"
    SSH_PORTS: "22"

default-log-dir: /var/log/suricata/

outputs:
  - fast:
      enabled: yes
      filename: fast.log
      append: yes

  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve.json
      types:
        - alert:
            payload: yes
            payload-printable: yes
            http: yes
        - stats:
            enabled: yes
            threads: yes

  - stats:
      enabled: yes
      filename: stats.log
      append: yes

threading:
  set-cpu-affinity: yes
  cpu-affinity:
    management-cpu-set:
      cpu: [0]
    worker-cpu-set:
      cpu: [1, 2, 3]
      mode: "exclusive"

af-packet: []
pcap: []

dpdk:
  eal-params:
    proc-type: primary
    d: /home/huanglin/code/dpdk/build/drivers
  interfaces:
    - interface: 0000:22:00.0
      threads: auto
      promisc: true
      multicast: true
      checksum-checks: no
      checksum-checks-offload: true
      mtu: 1500
      mempool-size: auto
      mempool-cache-size: auto
      rx-descriptors: 1024
      tx-descriptors: 1024
      copy-mode: none
      copy-iface: none

logging:
  outputs:
    - console:
        enabled: yes
    - file:
        enabled: yes
        filename: suricata.log
        level: info

default-rule-path: /var/lib/suricata/rules
rule-files:
  - suricata.rules

classification-file: /etc/suricata/classification.config
reference-config-file: /etc/suricata/reference.config
```

### 配置要点

#### 1. DPDK PMD 插件加载（`eal-params.d`）

**关键配置：** `d: /home/huanglin/code/dpdk/build/drivers`

DPDK shared 构建模式下，PMD 驱动（如 mlx5）是独立的 `.so` 文件，不会自动加载。EAL 初始化时通过以下流程查找 PMD：

1. 检查编译时硬编码的 `RTE_EAL_PMD_PATH`（默认为 `/usr/local/lib64/dpdk/pmds-25.0`）
2. 如果该目录不存在（未 `ninja install`），跳过
3. 遍历通过 EAL `-d` 参数添加的插件目录

因此必须在 `eal-params` 中通过 `d` 指定 DPDK drivers 目录。Suricata 会将单字符键 `d` 转换为 EAL 参数 `-d`。

> **常见误区：** `DPDK_PLUGIN_PATH` 环境变量**不是**运行时配置。它只是嵌入二进制的元数据字符串，供 `dpdk-pmdinfo.py` 工具读取。设置该环境变量对 PMD 加载没有效果。

#### 2. 线程亲和性（`threading`）

DPDK 模式**强制要求**配置线程亲和性（`set-cpu-affinity: yes`），否则启动报错。必须同时配置：

- `management-cpu-set`：管理线程（流超时、计数器等）
- `worker-cpu-set`：工作线程（数据包检测）

#### 3. CPU 核心选择

DPDK PMD 使用 busy-poll 模式，每个 worker 线程会 100% 占用一个 CPU 核心。在大小核架构（如 Intel P-core/E-core）上，**必须将 worker 绑定到大核**，小核的处理能力不足以应对线速轮询。

查看 CPU 拓扑：

```bash
lscpu -e | grep -E "CPU|^\s*[0-9]"
```

示例输出（Meteor Lake）：

```
CPU NODE SOCKET CORE L1d:L1i:L2:L3 ONLINE    MAXMHZ   MINMHZ       MHZ
  0    0      0    0 0:0:0:0          yes 5400.0000 400.0000 1625.2950
...
 14    0      0   14 64:64:8          yes 2500.0000 400.0000 1540.8480  # E-core
 15    0      0   15 66:66:8          yes 2500.0000 400.0000  551.6230  # E-core
```

根据 MAXMHZ 区分大小核，将 worker 绑定到高频率核心。

### 启动 Suricata

```bash
sudo LD_LIBRARY_PATH="/path/to/dpdk/build/lib" \
  /path/to/suricata/src/suricata \
  -c /path/to/suricata/suricata-dpdk-test.yaml \
  --dpdk -vvv
```

> **注意：** 必须使用 `--dpdk` 参数选择 DPDK 运行模式。不要使用 `-i` 参数，它默认选择 af-packet 模式。

或使用启动脚本：

```bash
./suricata-dpdk.sh -vvv
```

启动脚本 `suricata-dpdk.sh`：

```bash
#!/bin/bash
# Suricata DPDK 启动脚本
# PMD 插件加载通过 YAML 配置 eal-params.d 指定（EAL -d 参数），
# DPDK_PLUGIN_PATH 环境变量仅用于 dpdk-pmdinfo.py 元数据，不是运行时配置

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DPDK_BUILD="/home/huanglin/code/dpdk/build"

exec sudo \
  LD_LIBRARY_PATH="$DPDK_BUILD/lib" \
  $SCRIPT_DIR/src/suricata \
  -c $SCRIPT_DIR/suricata-dpdk-test.yaml \
  --dpdk "$@"
```

## 性能测试

### 测试拓扑

```
流量生成器                     Suricata (DPDK capture)
  enp34s0f1np1  ──DAC──>  0000:22:00.0
  (内核驱动)                  (DPDK / vfio-pci)
```

双口 Mellanox ConnectX-4 Lx 通过 SFP28 DAC 直连。端口 0 绑定 vfio-pci 供 Suricata DPDK 使用，端口 1 保留内核驱动（mlx5_core）用于流量生成。

### 流量生成方案

#### 方案对比

| 方案                      | 速率                      | 可行性                   | 说明                                                                  |
| ------------------------- | ------------------------- | ------------------------ | --------------------------------------------------------------------- |
| DPDK testpmd（primary）   | 线速（10+10 Gbps 已验证） | 不能与 Suricata 同时运行 | DPDK 只允许一个 primary 进程                                          |
| DPDK testpmd（secondary） | —                         | 失败                     | static vs shared DPDK tailq 不兼容；shared vs shared mbuf pool 不兼容 |
| Pktgen-DPDK（secondary）  | 待测                      | 可行                     | 专为流量生成设计，支持多进程，可自行创建 mbuf pool                    |
| 内核 pktgen               | ~49 万 pps / ~2.0 Gbps    | 可用                     | Fedora 43 内核 6.19.11 模块缺失，需手动编译加载                       |
| 内核 raw socket（单线程） | ~46 万 pps / ~2.3 Gbps    | 可用                     | 系统调用开销是瓶颈                                                    |
| 内核 raw socket（多进程） | ~55 万 pps / ~2.8 Gbps    | 可用                     | 提升有限，受内核协议栈限制                                            |
| 独立机器                  | 线速                      | 最佳方案                 | 需要额外硬件                                                          |

#### DPDK 多进程失败分析

DPDK 多进程要求 primary 和 secondary 使用**完全一致的 DPDK 构建**，包括：

1. **static vs shared**：tailq 对象内存布局不同，secondary 启动时报 `Cannot initialize tailq: RTE_FIB`
2. **shared vs shared（相同构建）**：mbuf pool 命名和结构不兼容，secondary 报 `Get mbuf pool for socket 0 failed`

DPDK 多进程设计用于**同一应用的不同实例**（如多个 testpmd 实例分摊负载），不适用于不同应用之间（Suricata + testpmd）共享端口。

**Pktgen-DPDK** 是专为流量生成设计的 DPDK 应用，与 testpmd 不同，它可以自行创建 mbuf pool，不依赖 primary 的内存池，因此更适合作为 Suricata 的 secondary 流量生成器。

#### 内核发包瓶颈分析

内核 mlx5_core 驱动发包速率上限约 ~50 万 pps（~2 Gbps），多线程 pktgen 也无法突破：

| 发包方式              | 速率                   | 说明                  |
| --------------------- | ---------------------- | --------------------- |
| raw socket（单线程）  | ~46 万 pps / ~2.3 Gbps | 系统调用开销瓶颈      |
| raw socket（4 进程）  | ~55 万 pps / ~2.8 Gbps | 提升有限              |
| 内核 pktgen（1 线程） | ~49 万 pps / ~2.0 Gbps | 受限于 mlx5_core 驱动 |
| 内核 pktgen（4 线程） | ~59 万 pps / ~2.4 Gbps | 多线程几乎无扩展      |

瓶颈原因：mlx5_core 内核驱动每发一个包要经过 sk_buff 分配、协议栈钩子、驱动锁等多层开销，而 DPDK 是用户态直接往 TX ring 批量写描述符。与两台机器的场景不同，单机双口时 TX（内核）和 RX（DPDK）共享同一 PCIe 总线和 CPU 资源。

#### 内核 pktgen 编译（Fedora 43）

Fedora 43 内核 6.19.11 标记了 `CONFIG_NET_PKTGEN=m` 但未包含编译好的模块文件。可以从 kernel.org 下载源码手动编译：

```bash
# 1. 下载 pktgen.c
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/net/core/pktgen.c?h=v6.19.11" -o /tmp/pktgen.c

# 2. 复制到内核源码树并编译
sudo cp /tmp/pktgen.c /usr/src/kernels/$(uname -r)/net/core/pktgen.c
cd /usr/src/kernels/$(uname -r)
sudo make M=net/core pktgen.ko

# 3. 加载模块
sudo insmod /usr/src/kernels/$(uname -r)/net/core/pktgen.ko
ls /proc/net/pktgen/  # 确认 pgctrl 和 kpktgend_* 存在
```

#### Pktgen-DPDK 编译

```bash
# 1. 克隆
git clone https://github.com/pktgen/Pktgen-DPDK.git

# 2. 配置（需要禁用 bonding，DPDK 未编译 bonding PMD）
cd Pktgen-DPDK
# 注释 bonding 相关代码（app/pktgen-cmds.c, app/pktgen-cmds.h, app/cli-functions.c）
PKG_CONFIG_PATH="/path/to/dpdk/build/meson-uninstalled" meson setup build
meson configure build -Dwerror=false
ninja -C build
```

#### 双 DPDK Primary 共存方案

使用 `--file-prefix` 可以让两个 DPDK 进程各自管理独立的 hugepage 文件，作为独立的 primary 进程运行：

```bash
# Suricata（默认 prefix）
sudo LD_LIBRARY_PATH=/path/to/dpdk/build/lib \
  ./src/suricata -c suricata-dpdk-test.yaml --dpdk

# Pktgen-DPDK（独立 prefix，只探测端口 1）
sudo LD_LIBRARY_PATH=/path/to/dpdk/build/lib \
  /path/to/Pktgen-DPDK/build/app/pktgen \
  -l 4-7 --main-lcore 4 -a 0000:22:00.1 \
  --file-prefix=pktgen \
  -d /path/to/dpdk/build/drivers \
  -- -T -P -m "[5-7].0" -f /tmp/pktgen_cmd.txt
```

两个 primary 进程可以同时访问同一块双口网卡的不同端口。Suricata 占端口 0（vfio-pci），Pktgen 占端口 1（vfio-pci）。

#### 推荐方案：内核 pktgen（百万级 pps）

Fedora 43 内核 6.19.11 标记了 `CONFIG_NET_PKTGEN=m` 但未包含编译好的模块文件。可以从 kernel.org 下载源码手动编译：

```bash
# 1. 下载 pktgen.c
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/net/core/pktgen.c?h=v6.19.11" -o /tmp/pktgen.c

# 2. 复制到内核源码树并编译
sudo cp /tmp/pktgen.c /usr/src/kernels/$(uname -r)/net/core/pktgen.c
cd /usr/src/kernels/$(uname -r)
sudo make M=net/core pktgen.ko

# 3. 加载模块
sudo insmod /usr/src/kernels/$(uname -r)/net/core/pktgen.ko
ls /proc/net/pktgen/  # 确认 pgctrl 和 kpktgend_* 存在
```

pktgen 支持自定义 MAC/IP/端口/协议/包大小/VLAN 等，直接走内核驱动发到物理口，速率可达百万级 pps。

### 测试结果

#### Suricata DPDK 基本功能验证

使用 Pktgen-DPDK（独立 primary）发送 500 万 UDP 包（512 字节），Suricata 同时在另一个 primary 进程中接收：

```
Notice: device: 0000:22:00.0: packets: 5000565, drops: 0 (0.00%), invalid chksum: 0
```

- **收包**：5,000,565 包
- **丢包**：0（0.00%）
- **速率**：~33 万 pps / ~2.1 Gbps

Suricata DPDK 模式在单机双 DPDK primary 共存方案下完全正常收包，0 丢包。

#### 流量生成瓶颈分析

单机环境下，无论用内核工具还是双 DPDK primary，发包速率都卡在 ~2 Gbps。而 testpmd 独占双口时能达到 10+ Gbps，差距的原因是 **TX 和 RX 共享同一块 NIC 的 PCIe 资源**：

| 场景                   | TX 方式             | RX 方式            | 速率     |
| ---------------------- | ------------------- | ------------------ | -------- |
| testpmd（独占）        | DPDK PMD（port 1）  | DPDK PMD（port 0） | 10+ Gbps |
| Pktgen-DPDK + Suricata | DPDK PMD（port 1）  | DPDK PMD（port 0） | ~2 Gbps  |
| 内核 pktgen + Suricata | mlx5_core（port 1） | DPDK PMD（port 0） | ~2 Gbps  |

testpmd 独占双口时，TX 和 RX 都在同一个进程内协调，可以直接从 RX ring 回收 TX 发出的包，PCIe DMA 总线利用效率最高。当 TX 和 RX 分属不同进程（即使都是 DPDK），每次 DMA 传输都需要经过 PCIe 总线仲裁，加上两套 DPDK 运行时的内存带宽竞争，吞吐大幅下降。

这个瓶颈是 Thunderbolt 拓展坞下双口共享同一 PCIe 链路的物理限制，非软件问题。

| 发包方式                  | 速率               | 说明                     |
| ------------------------- | ------------------ | ------------------------ |
| DPDK testpmd（独占双口）  | 线速（10+10 Gbps） | 不能与 Suricata 同时运行 |
| Pktgen-DPDK（双 primary） | ~2.1 Gbps          | PCIe 资源竞争瓶颈        |
| 内核 pktgen               | ~2.0 Gbps          | 内核驱动 + PCIe 竞争     |
| 内核 raw socket（多进程） | ~2.8 Gbps          | 内核协议栈 + PCIe 竞争   |

#### 硬件吞吐能力（独立测试）

使用 DPDK testpmd flowgen 双口转发（Suricata 未运行），双口各达到 10+ Gbps，合计 20+ Gbps，确认 Thunderbolt 拓展坞 + Mellanox 25GbE 的硬件能力。

#### 待测试

- 高速率下的 Suricata 丢包阈值
- 不同规则集对吞吐量的影响
- DPDK 模式 vs AF_PACKET 模式的性能对比

## 突破单机瓶颈：共享内存收包方案

### 瓶颈回顾

单机双口方案受限于 PCIe 资源竞争，TX 和 RX 分属不同进程时吞吐上限约 2 Gbps。无论用 DPDK、AF_XDP、内核 raw socket 还是共享内存，物理层的数据传输（端口1 → NIC内部交换 → 端口0 → PCIe → CPU内存）都无法绕过。

但如果**绕过物理 NIC**，直接在内存中向 Suricata 注入数据包，就完全消除了 PCIe 瓶颈：

```
物理方案（有瓶颈）：
  pktgen (port1) → NIC内部交换 → port0 → PCIe → Suricata
                                        ↑ PCIe竞争，~2Gbps

共享内存方案（无瓶颈）：
  发包进程 → 共享内存 ring buffer → Suricata 直接读取
                    ↑ 纯内存操作，理论几十Gbps
```

### Suricata 收包模式性能上限

| 模式                 | 机制                                   | 典型吞吐量 (25GbE)           | CPU 开销               |
| -------------------- | -------------------------------------- | ---------------------------- | ---------------------- |
| AF_PACKET（默认）    | 内核 sk_buff 拷贝 → syscall → 用户态   | 2-5Mpps (~3-8 Gbps@512B)     | 高：每包一次系统调用   |
| pcap                 | AF_PACKET + libpcap 封装               | 1-3Mpps (~2-5 Gbps@512B)     | 最高：libpcap 额外开销 |
| AF_XDP（copy 模式）  | XDP redirect → AF_XDP socket，内核拷贝 | 8-15Mpps (~10-18 Gbps@512B)  | 中：syscall 但批量处理 |
| AF_XDP（zero-copy）  | DMA 直接到用户态 ring buffer           | 15-25Mpps (~18-25 Gbps@512B) | 低：真正零拷贝         |
| DPDK PMD（当前使用） | 完全内核 bypass，用户态轮询            | 25-35Mpps（可达线速）        | 高：busy-poll 吃满核心 |

DPDK PMD 已经是最快的收包方式。Suricata 当前 2 Gbps 下 0 drop 说明检测引擎远未饱和。

### 共享内存 Ring 方案

最直接的实现是利用 DPDK 的 `rte_ring`（Suricata 已链接 DPDK，无需额外依赖）：

```
发包进程（独立 primary，不绑定 NIC）       Suricata（独立 primary，不绑定 NIC）
  ├─ 构造包 → rte_mbuf
  ├─ rte_ring_sp_enqueue()
  └─ 循环直到发包完成                      ├─ rte_ring_sc_dequeue()
                                          └─ 丢进 decode → detect 流水线
        ↓ 共享内存 ring buffer ↓
```

**核心改动：** 给 Suricata 添加一个 `runmode-ring.c`，替代 `runmode-dpdk.c` 中的 `rte_eth_rx_burst()` 为 `rte_ring_dequeue()`。Suricata 的 capture 模块是插件式的，新增一个运行模式完全符合现有架构。

**优势：**

- 不需要绑定任何 NIC，不需要 vfio-pci
- 不需要 Thunderbolt、DAC 电缆、甚至不需要网卡
- 两个 DPDK 进程通过 `--file-prefix` 各自独立，不共享 hugepage 文件
- 环形缓冲区操作是 CAS 指令 + 指针交换，每包 ~10ns

**理论吞吐量：**

DDR5 内存带宽约 50 GB/s，64B 包通过 ring buffer 每包约 10ns，理论上限 100M+ pps，远超 25GbE 线速（~37Mpps @64B）。

### Suricata 检测引擎估算吞吐量

共享内存注入测的是 Suricata 检测引擎的**纯处理能力**，去掉了 I/O 影响。基于 Meteor Lake 3 个 P-core（5.4GHz）：

| 规则集                           | 64B 包     | 512B 包    | 1518B 包     |
| -------------------------------- | ---------- | ---------- | ------------ |
| 无规则（仅 decode）              | ~35-45Mpps | ~25-30Mpps | ~18-22Mpps   |
| 小规则集（~100 条）              | ~15-25Mpps | ~8-12Mpps  | ~4-6Mpps     |
| Emerging Threats 全量（~30K 条） | ~6-10Mpps  | ~3-5Mpps   | ~1.5-2.5Mpps |
| ET + 启用 HTTP/TLS 解码          | ~4-7Mpps   | ~2-3Mpps   | ~1-1.5Mpps   |

512B 包换算成带宽：

| 规则集        | 3 核吞吐      |
| ------------- | ------------- |
| 无规则        | ~12-15 Gbps   |
| 小规则集      | ~3-6 Gbps     |
| ET 全量       | ~1.2-2 Gbps   |
| ET + 协议解码 | ~0.8-1.2 Gbps |

Suricata 的处理流水线：

```
包 → decode（快） → stream reassembly → app-layer decode → 签名匹配（MPM）
                                                          ↑
                                                   真正的瓶颈
                                                规则越多、payload越大越慢
```

多模式匹配（MPM）引擎对每个包 payload 做字符串搜索，复杂度与规则数和 payload 大小正相关。decode 阶段（解析以太网/IP/TCP 头）非常快，不是瓶颈。

### 小结

- 当前 2 Gbps 测试中 Suricata 0 drop，检测引擎远未饱和
- 共享内存方案可以测出 Suricata 在当前硬件上的**真实处理上限**
- DPDK PMD 已是最快的物理收包方式，不需要换成 AF_XDP
- 共享内存方案的瓶颈从 I/O 转移到了检测引擎，是 IDS 性能基准测试的标准做法

## 排坑记录

### 问题 1：configure 找不到 DPDK

**现象：** `configure` 报 `libdpdk >= 19.11 not found by pkg-config`

**原因：** 未设置 `PKG_CONFIG_PATH`，configure 找不到 DPDK 的 pkg-config 文件

**解决：** 设置 `PKG_CONFIG_PATH` 指向 DPDK 构建目录：

```bash
PKG_CONFIG_PATH="/path/to/dpdk/build/meson-uninstalled:/path/to/dpdk/build/meson-private"
```

### 问题 2：编译找不到 DPDK 头文件（rte_eal.h）

**现象：** C 编译报 `rte_eal.h：没有那个文件或目录`

**原因：** `meson-private/libdpdk.pc` 的 `includedir` 指向 `/usr/local/include`，但 DPDK 未 `ninja install`，头文件在源码树中

**解决：** configure 时通过 `PKG_CONFIG_PATH` 优先使用 `meson-uninstalled` 下的 `.pc` 文件，它包含正确的构建目录路径

### 问题 3：rdkafka.h 找不到

**现象：** 编译报 `rdkafka.h：没有那个文件或目录`

**原因：** Fedora 的 `librdkafka-devel` 将头文件安装在 `/usr/include/librdkafka/rdkafka.h`，而 Suricata 搜索 `<rdkafka.h>`（无子目录）。configure 检测头文件失败但库链接成功，实际编译时找不到

**解决：** configure 时追加 include 路径：

```bash
CFLAGS="-I/usr/include/librdkafka"
```

### 问题 4：rust-bindings.h 找不到

**现象：** 编译报 `rust-bindings.h：没有那个文件或目录`

**原因：** `git clean -xfd` 后 `rust/gen/rust-bindings.h` 被删除，需要 `cbindgen` 重新生成

**解决：** 安装 `cbindgen`：

```bash
cargo install cbindgen
```

### 问题 5：Rust 编译极慢（rustc 版本问题）

**现象：** rustc 单核编译 `suricata` crate 超过 10 分钟，虚拟机反而更快

**原因：** rustc 1.94.1 使用 LLVM 21，1.89.0 使用 LLVM 18。通过 `perf record` 分析编译过程，发现 **LTO（链接时优化）** 占了 145% 的 CPU 时间（多核并行），是主要瓶颈。新版本 LLVM 的 LTO 开销显著增大。

perf 分析结果：

| 阶段          | CPU 占比 |
| ------------- | -------- |
| LTO 链接优化  | 145.2%   |
| rustc 编译    | 41.7%    |
| LLVM opt 优化 | 41.1%    |
| cc1（C 编译） | 13.0%    |

编译时间对比（`cargo build --release`）：

| rustc 版本 | LLVM 版本 | 编译时间 |
| ---------- | --------- | -------- |
| 1.89.0     | LLVM 18   | ~50s     |
| 1.91.0     | LLVM 19   | ~62s     |
| 1.94.1     | LLVM 21   | >200s    |

**解决：** 锁定 Rust 工具链版本：

```bash
cd /path/to/suricata/rust
rustup install 1.89.0
rustup override set 1.89.0
```

> 或者关闭 LTO（牺牲少量运行时性能换编译速度）：`RUSTFLAGS="-C lto=off" cargo build --release`

### 问题 6：启动报日志目录不存在

**现象：** `error opening file /var/log/suricata//suricata.log: No such file or directory`

**原因：** Suricata 默认日志目录 `/var/log/suricata/` 不存在

**解决：**

```bash
sudo mkdir -p /var/log/suricata
```

### 问题 7：--dpdk 参数缺失导致使用 af-packet

**现象：** 使用 `-i 0000:22:00.0` 启动后，Suricata 使用 af-packet 模式而非 DPDK

**原因：** `-i` 参数在 Suricata 中默认选择 af-packet 模式。Caracal（Suricata DPDK fork）使用 `--dpdk` 参数选择 DPDK 运行模式

**解决：** 使用 `--dpdk` 参数启动，不使用 `-i`：

```bash
./src/suricata -c suricata-dpdk-test.yaml --dpdk
```

### 问题 8：DPDK PMD 未加载，设备找不到

**现象：** EAL 初始化成功，但 `rte_eth_dev_get_port_by_name("0000:22:00.0")` 返回 "No such device"。日志中没有任何 mlx5 PMD 探测信息。

**原因：** DPDK shared 构建模式下，PMD 驱动（mlx5 等）是独立的 `.so` 文件，需要通过 EAL `-d` 参数指定插件目录才能加载。默认的 `RTE_EAL_PMD_PATH`（`/usr/local/lib64/dpdk/pmds-25.0`）在未执行 `ninja install` 时不存在。

DPDK 插件加载流程（`eal_common_options.c`）：

1. `eal_plugins_init()` 检查 `is_shared_build()` — 确认是 shared 链接
2. 检查 `default_solib_dir`（`RTE_EAL_PMD_PATH`）是否存在 — 不存在则跳过
3. 遍历通过 EAL `-d` 参数添加的 `solib_list` — 列表为空则不加载任何 PMD
4. 结果：mlx5 PMD `.so` 存在于 `build/drivers/` 但未被加载

> **关于 `DPDK_PLUGIN_PATH`：** 该环境变量在 DPDK 源码中仅用于嵌入二进制的元数据字符串（`"DPDK_PLUGIN_PATH=" RTE_EAL_PMD_PATH`），供 `dpdk-pmdinfo.py` 工具读取。它**不是**运行时配置，设置该环境变量对 PMD 加载没有效果。

**解决：** 在 YAML 配置的 `eal-params` 中添加 `d` 参数：

```yaml
dpdk:
  eal-params:
    proc-type: primary
    d: /path/to/dpdk/build/drivers
```

Suricata 将 YAML 中的单字符键 `d` 转换为 EAL 参数 `-d`，EAL 解析后调用 `eal_plugin_add()` 将该目录加入 PMD 扫描列表。

### 问题 9：DPDK runmode requires configured thread affinity

**现象：** `Error: dpdk: DPDK runmode requires configured thread affinity`

**原因：** Suricata DPDK 模式强制要求开启 CPU 亲和性配置（`threading_set_cpu_affinity`），否则工作线程无法正确绑定到 CPU 核心

**解决：** 在配置中添加 threading 部分：

```yaml
threading:
  set-cpu-affinity: yes
  cpu-affinity:
    management-cpu-set:
      cpu: [0]
    worker-cpu-set:
      cpu: [1, 2, 3]
      mode: "exclusive"
```

> **注意 CPU 核心选择：** DPDK PMD 使用 busy-poll 模式，每个 worker 占满一个核心。在大小核架构上必须将 worker 绑定到大核（P-core），小核（E-core）处理能力不足。

## 扩展阅读

- [DPDK + 25GbE on Thunderbolt 完整踩坑](/2026-04-12-dpdk-thunderbolt-mellanox-guide)
- [Rust LTO 原理与影响](/2026-04-13-rust-lto-principle-and-impact)
