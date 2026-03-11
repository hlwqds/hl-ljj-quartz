---
title: pwru 详解：基于 eBPF 的 Linux 网络丢包追踪神器
date: 2025-12-19 10:00:00
pin: true
tags: [linux, network, ebpf, troubleshooting, pwru, cilium, packet-trace, kernel, debug]
---


# pwru 详解：基于 eBPF 的 Linux 网络丢包追踪神器

在复杂的 Linux 网络环境中（尤其是 Kubernetes, Docker, Cilium 场景），丢包排查往往是运维人员的噩梦。当常规的 `tcpdump`、`ping`、`iptables-save` 无法解释数据包为何消失时，你需要一把“手术刀”来剖析内核的网络协议栈。

这就是 **pwru (Packet Where aRe yoU)**。

## 1. 它是做什么的？

`pwru` 是由 Cilium 团队开源的一款基于 eBPF 的排错工具。
它的核心功能简单而强大：**追踪一个数据包在 Linux 内核中经过的每一个函数。**

### 解决的痛点
以往我们想知道包是在 `iptables` 被丢弃的，还是在 `tc` 被限速的，还是在 `route` 被黑洞的，往往只能靠猜或逐一检查配置。
而 `pwru` 能直接告诉你：
> "这个包进入了 `ip_rcv`，经过了 `ipt_do_table`，最后在 `ip_forward` 中因为路由查找失败调用了 `kfree_skb`。"

## 2. 工作原理

`pwru` 利用了 eBPF 极其强大的可编程性和内核元数据（BTF）。

1.  **扫描函数**: 它会自动解析 `/sys/kernel/btf/vmlinux`，找出内核中所有接收 `struct sk_buff *`（数据包结构体）作为参数的函数。通常有上千个。
2.  **Kprobes 挂载**: 它通过 eBPF 将这些函数全部 Hook 住（不用担心性能，eBPF 开销极低）。
3.  **实时追踪**: 当符合你过滤条件的数据包出现时，它会记录该包在内核中的“旅行轨迹”。

## 3. 安装

由于依赖 BTF (BPF Type Format)，你需要确保内核版本较新（建议 5.10+，虽然 4.18+ 可能也支持）。

```bash
# 下载二进制文件 (推荐)
wget https://github.com/cilium/pwru/releases/latest/download/pwru-linux-amd64.tar.gz
tar xvf pwru-linux-amd64.tar.gz
chmod +x pwru
sudo mv pwru /usr/local/bin/
```

## 4. 实战用法

### 4.1 基础追踪 (Ping 测试)
假设你想知道 ping 包在内核里走了哪些路。

**终端 1 (运行 pwru)**:
```bash
# 过滤 ICMP 协议
sudo pwru --filter-proto icmp
```

**终端 2 (发包)**:
```bash
ping 1.1.1.1
```

**输出结果**:
```text
SKB               CPU  PROCESS     FUNC
0xffff8881a2b3c4d 1    ping        ip_send_skb
0xffff8881a2b3c4d 1    ping        ip_output
0xffff8881a2b3c4d 1    ping        ip_finish_output
...
0xffff8881a2b3c4d 1    <softirq>   ixgbe_xmit_frame (网卡驱动发包)
```

### 4.2 追踪特定端口 (Web 服务不通)
如果 80 端口不通，想看包丢在哪。

```bash
sudo pwru --dst-port 80
```

### 4.3 追踪特定 5 元组
支持类似 tcpdump 的过滤语法：
```bash
sudo pwru 'dst host 1.1.1.1 and dst port 80'
```

### 4.4 开启堆栈打印 (核心功能)
仅仅看到包经过了哪些函数还不够，有时候我们需要知道**是谁调用了这个函数**。加上 `--output-stack` 参数。

```bash
sudo pwru --dst-port 80 --output-stack
```

如果包被丢弃，你会看到类似这样的堆栈：
```text
kfree_skb
nf_hook_slow
ip_forward
...
```
这能帮你快速定位是防火墙（nf_hook）还是路由转发（ip_forward）出的问题。

## 5. 什么时候使用 pwru？

请记住，`pwru` 是**重型武器**。

1.  **日常排查**: 先用 `ping`, `curl`, `tcpdump`。
2.  **怀疑丢包**: 用 `iptables-save`, `ip route` 检查配置。
3.  **绝望时刻**: 当所有配置看起来都对，但包就是发不出去或收不到，或者你想深入学习 Linux 内核网络栈时，请使用 `pwru`。

## 7. 常见报错与解决

### 报错：Failed to retrieve available ftrace functions
```text
Failed to retrieve available ftrace functions (is /sys/kernel/debug/tracing mounted?): no such file or directory
```
这是因为 Linux 的 `debugfs` 没有挂载，导致 `pwru` 无法读取内核函数列表。

**解决方法**:
1.  **挂载 debugfs**:
    ```bash
    sudo mount -t debugfs debugfs /sys/kernel/debug
    ```
2.  **容器环境**:
    如果你在 Docker/K8s 中运行，需要开启特权模式并挂载该目录：
    ```bash
    docker run --privileged -v /sys/kernel/debug:/sys/kernel/debug ...
    ```

### 7.2 Arch Linux 用户专属：路径兼容性修复

**现象**: 
在 Arch Linux（或较新内核）上，tracefs 通常挂载在 `/sys/kernel/tracing`，而旧版 `pwru` 硬编码去寻找 `/sys/kernel/debug/tracing`。
由于 `/sys/kernel/debug` 不允许创建软链接，简单的 `ln -s` 会失败。

**终极解决方案 (Wrapper 脚本)**:
利用 `unshare` 创建独立的挂载命名空间，在不污染宿主机的情况下“伪造”出 `pwru` 想要的路径。

保存以下内容为 `pwru-arch.sh` 并运行：

```bash
#!/bin/bash
# 解决 Arch Linux 下 pwru 找不到 tracing 目录的问题
set -e

if [ "$EUID" -ne 0 ]; then echo "请使用 sudo 运行"; exit 1; fi

# 定义路径
DEBUG_TRACING="/sys/kernel/debug/tracing"
ARCH_TRACING="/sys/kernel/tracing"

if [ -d "$DEBUG_TRACING" ]; then
    exec pwru "$@"
fi

echo "检测到 Arch Linux 路径布局，正在创建隔离挂载环境..."

# 使用 unshare -m 创建独立命名空间
# 1. 挂载 tmpfs 覆盖 /sys/kernel/debug
# 2. 将真正的 tracefs bind 过去
unshare -m /bin/bash <<EOF
  mount -t tmpfs tmpfs /sys/kernel/debug
  mkdir -p $DEBUG_TRACING
  mount --bind $ARCH_TRACING $DEBUG_TRACING
  exec pwru "$@"
EOF
```

## 8. 总结

`pwru` 是网络排错领域的“显微镜”。它将原本黑盒的 Linux 内核网络处理流程完全透明化。虽然使用门槛稍高（需要理解一些内核函数名），但对于解决疑难杂症，它是无价之宝。
