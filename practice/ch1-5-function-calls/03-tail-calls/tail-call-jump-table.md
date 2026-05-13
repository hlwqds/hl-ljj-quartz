# Tail Call 与 PROG_ARRAY jump_table 工作原理

## 概述

BPF Tail Call 通过 `BPF_MAP_TYPE_PROG_ARRAY` map 实现跨程序跳转。与 BPF-to-BPF Call 不同，Tail Call 的跳转目标是**运行时由用户态程序填充**的，不是编译时确定的。

本文基于 `03-tail-calls` 示例代码，分析完整的工作流程。

## 两种 Call 的对比

|            | BPF-to-BPF Call              | Tail Call (PROG_ARRAY)           |
| ---------- | ---------------------------- | -------------------------------- |
| 调用关系   | 编译时确定（同一个 `.o` 内） | 运行时确定（不同 `.o`）          |
| 谁填充映射 | 编译器/链接器                | 用户态程序                       |
| 返回       | 可以返回                     | 不返回（栈帧丢弃）               |
| 深度限制   | 8 层                         | 33 层                            |
| 典型场景   | 代码复用                     | 程序链（XDP 管线、防火墙规则链） |

## jump_table 的结构

`BPF_MAP_TYPE_PROG_ARRAY` 是一个特殊的 map，value 存的是 **BPF 程序的 fd**：

```c
struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 3);      // 最多 3 个阶段
    __uint(key_size, sizeof(u32)); // index 类型: u32
    __uint(value_size, sizeof(u32)); // value 类型: prog fd
} jump_table SEC(".maps");
```

加载后 jump_table 的内容：

```
index │ prog fd     │ SEC 名称
──────┼─────────────┼──────────────
  0   │ 0 (空)       │ (未使用)
  1   │ 5            │ SEC("xdp/stage1")
  2   │ 7            │ SEC("xdp/stage2")
```

**注意**：`.o` 文件中 jump_table 是空的。fd 是用户态程序在加载后填入的。

## 完整加载流程

```
用户态程序                          内核
─────────────────────────────────────────────────────

1. 加载 BPF 程序
   bpftool prog load stage0.bpf.o  ──→  创建 prog, 返回 fd=3
   bpftool prog load stage1.bpf.o  ──→  创建 prog, 返回 fd=5
   bpftool prog load stage2.bpf.o  ──→  创建 prog, 返回 fd=7

2. 填充 jump_table
   bpftool map update              ──→  jump_table[1] = fd 5
     key=1 value=5                    jump_table[2] = fd 7
   bpftool map update
     key=2 value=7

3. attach 到网卡
   bpftool link set dev eth0        ──→  eth0 的 XDP hook → stage0
     type xdp obj stage0
```

**关键**：第 2 步必须在第 1 步之后。因为 fd 在 `bpf_prog_load` 时才分配。

## 运行时跳转流程

```
网卡收包 → stage0 (L2 解析)
  │
  ├─ 非 IPv4 → return XDP_PASS
  │            (不调用 tail_call, 正常返回)
  │
  └─ IPv4 → bpf_tail_call(ctx, &jump_table, 1)
              │
              │   内核执行:
              │   1. 查 jump_table[1] → fd=5 → SEC("xdp/stage1")
              │   2. 丢弃 stage0 的栈帧
              │   3. 用 ctx 替换栈帧
              │   4. 跳转到 stage1 继续执行
              │
              ▼
         stage1 (L3 解析)
              │
              └─ bpf_tail_call(ctx, &jump_table, 2)
                        │
                        ▼
                   stage2 (L4 策略)
                        │
                        └─ return XDP_PASS
                             (最终返回给网卡驱动)
```

### 跳转失败的情况

如果 `jump_table[index]` 的值为 0（未填充），`bpf_tail_call` 返回 `-1`，程序继续执行 tail_call 后面的代码：

```c
// stage0.bpf.c
bpf_tail_call(ctx, &jump_table, 1);
// 如果跳转失败，执行到这里
return XDP_PASS;  // 默认行为: 放行
```

这提供了一种**优雅降级**机制——如果后续阶段没加载，包不会被丢弃。

## bpf_tail_call 的实现原理 (kernel/bpf/core.c)

### 为什么能解决 512B 栈限制

BPF-to-BPF Call 的栈结构：

```
┌─────────────┐
│  main func   │ ← 使用 200B
│  ┌───────┐  │
│  │sub_func│  │ ← 再分配 300B
│  │       │  │   累计 500B!
│  └───────┘  │
└─────────────┘
  总深度: 500B
```

Tail Call 的栈结构：

```
┌─────────────┐
│  stage0     │ ← 使用 200B
└─────────────┘
  tail_call → 丢弃栈帧

┌─────────────┐
│  stage1     │ ← 重新使用 200B (同一段 512B 空间)
└─────────────┘
  tail_call → 丢弃栈帧

┌─────────────┐
│  stage2     │ ← 再次使用 200B
└─────────────┘
  return → 最终返回
```

每个阶段**独立使用**同一块 512B 栈空间，因为 tail call 会丢弃当前栈帧再跳转。这就是为什么 tail call 没有累加栈限制。

### 深度限制

内核限制 tail call 最多 33 层（`MAX_TAIL_CALL_CNT`）。超过后 `bpf_tail_call` 返回 -E2BIG。

### 约束

- Tail Call **不能传参数**——只能传递 `ctx`（隐式传递）
- Tail Call **不能返回值**——跳转后当前栈帧已销毁
- 被跳转的程序**不能有 tail call 的返回值依赖**

## stage_stats 统计 map

三个程序共享同一个 `stage_stats`（`BPF_MAP_TYPE_PERCPU_ARRAY`）：

```c
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 3);
    __type(key, u32);     // index = stage number
    __type(value, u64);   // value = packet count
} stage_stats SEC(".maps");
```

每个阶段调用 `record_stage(stage_number)` 递增自己的计数器。通过 `bpftool map dump` 可以看到每个阶段处理了多少包。

## 调试技巧

```bash
# 查看 jump_table 的内容 (fd 映射)
bpftool map dump name jump_table

# 查看 stage_stats (每个阶段的包计数)
bpftool map dump name stage_stats

# 查看 tail call 执行统计
bpftool prog show | grep -A3 tail_call
```
