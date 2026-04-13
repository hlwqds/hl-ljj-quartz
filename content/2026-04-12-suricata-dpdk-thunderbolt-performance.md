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

| 项目 | 值 |
|------|-----|
| Suricata | 9.0.0-dev（源码编译），启用 DPDK 支持 |
| DPDK | 24.11.4，已通过 trust_tb 解决 Thunderbolt DMA 限制 |
| 网卡 | Mellanox ConnectX-4 Lx MCX4121A（双口 25GbE） |
| 连接 | SFP28 DAC 直连铜缆 |
| 系统 | Fedora 43，内核 6.19.11 |

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

> **Rust 版本说明：** Suricata `Cargo.toml` 要求最低 `rust-version = "1.75.0"`，但未锁定上限。实测 rustc 1.94.1 编译 `suricata` crate 单核超过 10 分钟，而 1.89.0 只需约 1 分钟，差距巨大。建议使用 1.89.0。

| 包 | 用途 |
|----|------|
| libbsd-devel | `strlcpy` 等 BSD 兼容函数 |
| pcre2-devel | 正则表达式引擎（规则匹配） |
| jansson-devel | JSON 解析（EVE 日志输出） |
| librdkafka-devel | Kafka 输出支持 |
| libbpf-devel | eBPF 支持 |
| libcap-ng-devel | 权限降级 |
| cbindgen（cargo） | 生成 `rust-bindings.h`（C-Rust FFI） |
| rust/cargo | Rust 组件编译（app-layer 等） |

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
> - `PKG_CONFIG_PATH`：DPDK 本地编译时，`meson-uninstalled/libdpdk-uninstalled.pc` 包含正确的头文件和库路径，`meson-private/libdpdk.pc` 指向 `/usr/local/include`（头文件不在那里）
> - `CFLAGS="-I/usr/include/librdkafka"`：Fedora 的 `librdkafka-devel` 将头文件安装在 `/usr/include/librdkafka/rdkafka.h`，而 Suricata 搜索 `<rdkafka.h>`（无子目录），configure 检测头文件失败但库链接成功，实际编译时找不到

配置输出确认：

```
DPDK support:      yes
DPDK Bond PMD:     no    # 不影响单口测试
rdkafka support:   yes
Rust compiler:     1.94.1
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

# 3. 设置 DPDK 动态库路径
export LD_LIBRARY_PATH="/path/to/dpdk/build/lib:$LD_LIBRARY_PATH"
```

## Suricata DPDK 配置

`suricata.yaml` 中的 DPDK 配置：

```yaml
dpdk:
  eal-params:
    proc-type: primary
  interfaces:
    - interface: 0000:52:00.0    # Mellanox port 0 PCIe 地址
      threads: auto              # 自动分配所有核心
      promisc: true
      multicast: true
      checksum-checks: no
      checksum-checks-offload: true
      mtu: 1500
      rx-descriptors: 1024
      tx-descriptors: 1024
      mempool-size: auto
      mempool-cache-size: auto
```

### 启动 Suricata

```bash
sudo LD_LIBRARY_PATH="/path/to/dpdk/build/lib" \
  /path/to/suricata/src/suricata \
  -c /path/to/suricata/suricata.yaml \
  -i 0000:52:00.0
```

## 性能测试

### 测试拓扑

```
testpmd (flowgen)              Suricata (DPDK capture)
  0000:52:00.1  ──DAC──>  0000:52:00.0
```

testpmd 在端口 1 以 flowgen 模式生成流量，通过 DAC 发送到端口 0，Suricata 在端口 0 上用 DPDK 模式捕获并检测。

### 测试方法

## 测试结果

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

| 阶段 | CPU 占比 |
|------|----------|
| LTO 链接优化 | 145.2% |
| rustc 编译 | 41.7% |
| LLVM opt 优化 | 41.1% |
| cc1（C 编译） | 13.0% |

编译时间对比（`cargo build --release`）：

| rustc 版本 | LLVM 版本 | 编译时间 |
|------------|-----------|----------|
| 1.89.0 | LLVM 18 | ~50s |
| 1.91.0 | LLVM 19 | ~62s |
| 1.94.1 | LLVM 21 | >200s |

**解决：** 锁定 Rust 工具链版本：

```bash
cd /path/to/suricata/rust
rustup install 1.89.0
rustup override set 1.89.0
```

> 或者关闭 LTO（牺牲少量运行时性能换编译速度）：`RUSTFLAGS="-C lto=off" cargo build --release`

## 扩展阅读

- [DPDK + 25GbE on Thunderbolt 完整踩坑](/2026-04-12-dpdk-thunderbolt-mellanox-guide)
