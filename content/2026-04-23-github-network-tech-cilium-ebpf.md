---
title: cilium/ebpf: 纯 Go eBPF 开发库
date: 2026-04-23 10:00:00
tags: [network, github, tooling, ebpf]
---

# cilium/ebpf: 纯 Go eBPF 开发库

## 项目概述

**cilium/ebpf** 是 Cilium 团队维护的纯 Go 语言实现的 eBPF 程序开发库，提供对 Linux eBPF 子系统的完整绑定。该项目支持读取、修改和加载 eBPF 程序及 Map，广泛应用于云原生网络、安全和可观测性场景。

| 属性         | 值                                            |
| ------------ | --------------------------------------------- |
| GitHub       | [cilium/ebpf](https://github.com/cilium/ebpf) |
| Stars        | 7.7k                                          |
| 语言         | Go                                            |
| 最新 Release | v0.21.0 (2026-03-05)                          |
| 最近更新     | Apr 21, 2026 (2 天前)                         |
| Fork         | 852                                           |

## 核心技术亮点

### 1. 纯 Go 实现，无 C 依赖

传统的 eBPF 开发需要借助 clang 编译和 iproute2 工具链。cilium/ebpf 纯 Go 实现，从 ELF 加载到程序编译全程可控：

```go
import "github.com/cilium/ebpf"
import "github.com/cilium/ebpf/asm"

// 直接编写 eBPF 汇编指令
insns := asm.Instructions{
    asm.Mov.Reg(asm.R0, asm.R1),  // func arg
    asm.Return(),
}
```

### 2. ELF 文件解析与 Map 生成

支持直接解析 clang 编译的 ELF 文件，自动提取 Map 定义和程序段：

```go
spec, err := ebpf.LoadCollectionSpec("bpf.o")
if err != nil {
    return err
}

// 加载所有 Map 和 Program
coll, err := ebpf.NewCollection(spec)
```

### 3. Struct Ops 支持

v0.21.0 新增 struct ops 功能，支持解析 struct ops sections，构建 MapSpecs 并解析函数指针成员：

```go
link.AttachStructOps(coll, "sched_ext")
```

### 4. BTF 与 CO-RE 支持

内置 BTF (BPF Type Format) 解析，支持 CO-RE (Compile Once - Run Everywhere) 跨内核移植：

```go
// 自动处理 BTF 信息
spec, err := ebpf.LoadCollectionSpecFromReader(os.Open("bpf.o"))
```

### 5. Windows eBPF 支持

v0.21.0 针对 ebpf-for-windows 升级到 v1.0.0-rc1，更新了 helper 函数命名以匹配 Windows API。

## v0.21.0 Breaking Changes

### XDP Attach Type 变更

Linux 6.18 起，XDP 程序需要正确的 attach type 才能插入 PROG_ARRAY：

```go
// 旧版本可能需要手动设置
spec.Programs["xdp"].AttachType = ebpf.AttachNone

// 新版本需显式声明
spec.Programs["xdp"].AttachType = ebpf.AttachXDP
```

如果使用混合 attach type 的 pinned program array，需先设置 `AttachNone` 后再升级。

## 适用场景

- **Kubernetes CNI 开发**：Cilium 本身使用此库实现 eBPF 数据平面
- **自定义网络策略**：实现 L4-L7 过滤和转发逻辑
- **安全监控**：eBPF 探针捕获网络/系统事件
- **性能分析**：用户态与内核态高效数据交换

## 实践要点

### 快速开始

```bash
go get github.com/cilium/ebpf@v0.21.0
```

### 编译 eBPF 程序

```bash
clang -target bpf -O2 -c xdp.c -o xdp.o
```

### 加载程序示例

```go
spec, _ := ebpf.LoadCollectionSpec("xdp.o")
prog := spec.Programs["xdp_pass"]

attr := &ebpf.MapCreateAttr{
    MapType:    ebpf.Array,
    KeySize:    4,
    ValueSize:  4,
    MaxEntries: 1,
}
m, _ := ebpf.NewMap(attr)

link, _ := ebpf.AttachXDP(prog, "eth0")
defer link.Close()
```

## 总结

cilium/ebpf 是云原生 eBPF 开发的核心基础设施库，提供安全、简洁的 Go API。相比直接使用 libbpf，降低了 eBPF 开发门槛，是构建高性能网络和安全解决方案的首选工具。
