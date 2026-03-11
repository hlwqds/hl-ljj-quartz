---
title: "项目挑战：用 C 语言从零实现 eBPF 网络追踪器 (C-pwru)"
date: 2025-12-19 10:00:00
pin: true
tags: [project, ebpf, linux-kernel, c, libbpf, networking, tutorial]
---


# 项目挑战：用 C 语言从零实现 eBPF 网络追踪器 (C-pwru)

`pwru` 是一个神奇的工具，它能告诉你在 Linux 内核里“包去哪了”。虽然原版是用 Go 编写的，但作为追求极致性能和底层掌控力的开发者，我决定发起一个挑战：**用纯 C 语言和 libbpf 实现一个功能对标的 C-pwru。**

本文是该项目的里程碑计划书（TODO List）。

## 1. 项目目标

实现一个命令行工具，能够：
1.  自动识别内核中所有处理 `sk_buff` 的函数。
2.  支持按 IP、端口、协议过滤流量。
3.  实时打印数据包经过的内核函数名及其处理时间。
4.  （进阶）支持打印内核堆栈（Stack Trace）。

## 2. 核心技术栈

*   **内核态**: eBPF (C 语言)
*   **用户态**: C11 + libbpf
*   **编译链**: LLVM/Clang
*   **内核特性**: BTF (BPF Type Format), Kprobes, RingBuffer

## 3. 阶段性里程碑 (TODO)

### 阶段一：环境搭建与“Hello skb”
- [ ] 搭建 `libbpf-bootstrap` 开发环境。
- [ ] 编写基础 eBPF 程序，挂载到单个已知函数（如 `ip_rcv`）。
- [ ] 成功在用户态捕获并打印 `sk_buff` 结构体的内存地址。

### 阶段二：解析与过滤 (内核态逻辑)
- [ ] 实现 `skb` 深度解析：从 `sk_buff` 中提取源/目的 IP 和端口。
- [ ] 实现用户态配置下发：通过 BPF Map 传递过滤条件。
- [ ] 引入 `bpf_ringbuf` 替代 `perf_event_array` 以获得更高性能。

### 阶段三：BTF 魔法 (自动化核心)
- [ ] 在用户态利用 `libbpf` 加载 `/sys/kernel/debug/btf/vmlinux`。
- [ ] **算法实现**：遍历 BTF 类型树，筛选出所有第一个参数类型为 `struct sk_buff *` 的函数。
- [ ] 验证筛选结果，确保能找回像 `ip_local_deliver` 这里的核心函数。

### 阶段四：动态批量挂载
- [ ] 实现循环逻辑，将同一个 BPF 程序动态附加（Attach）到筛选出的几百个函数上。
- [ ] 解决“参数偏移”问题：处理某些函数 `skb` 不在第一个参数的情况。
- [ ] 处理挂载失败的优雅降级逻辑。

### 阶段五：体验与性能优化
- [ ] 增加输出美化：类似于 `tcpdump` 的实时滚动视图。
- [ ] 实现内核堆栈抓取：使用 `bpf_get_stackid` 并在用户态还原符号。
- [ ] 压力测试：在高并发流量下测试对系统的性能影响。

## 4. 关键代码片段预研 (用户态 BTF 搜索)

```c
// 伪代码：如何寻找带 sk_buff 参数的函数
struct btf *btf = btf__load_vmlinux_btf();
__u32 type_id, skb_type_id;

// 1. 找到 sk_buff 结构体的 ID
skb_type_id = btf__find_by_name_kind(btf, "sk_buff", BTF_KIND_STRUCT);

// 2. 遍历所有函数
for (i = 1; i <= btf__type_cnt(btf); i++) {
    const struct btf_type *t = btf__type_by_id(btf, i);
    if (!btf_is_func(t)) continue;
    
    // 检查参数...
}
```

## 5. 结语

这将是一段漫长但充满收获的旅程。每一行 C 代码都将带我更深入地接触 Linux 网络协议栈的跳动脉搏。

**Stay hungry, Stay eBPF.**

---
[ ] *最后更新日期：2025-12-19*
