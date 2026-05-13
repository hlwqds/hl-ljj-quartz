---
title: bpftool 深度指南：BPF 程序与 Map 管理
date: 2026-04-18 09:00:00
tags: [BPF, bpftool, eBPF, Linux, Network, Observability, Kernel]
description: 深入讲解 bpftool 的所有核心功能：程序管理、Map 读写、JIT 编译、程序加载与调试，以及与 perf BCC 的协作。
---

# bpftool 深度指南：BPF 程序与 Map 管理

## 1. bpftool 是什么

bpftool 是 Linux BPF 系统的用户态管理工具，类似于 ethtool 是网卡的管理窗口，bpftool 是 BPF 子系统的管理窗口。

```
bpftool 的本质：
  内核 BPF 子系统通过 bpf() syscall 提供接口
  bpftool 调用这些接口，暴露为人类可读的 CLI

BPF 对象层级：
  Program（程序）：一段被内核验证+JIT 编译后执行的代码
    ├─ Type：kprobe / tracepoint / xdp / sock_ops / ...
    ├─ Instructions：BPF 字节码
    └─ Attach：挂载点（哪个 hook 执行它）

  Map（映射）：内核与用户态共享的 key-value 存储
    ├─ Type：hash / array / perf_event_array / ...
    ├─ Key/Value 大小
    └─ Max entries：最多存多少条

  Link：Program 附着到 hook 的关系（可观测）
    └─ 解决了 "program 在哪跑" 的问题
```

> [!note]
> bpftool 主要操作两类对象：**Program**（被动的代码）和 **Map**（主动的数据结构）。几乎所有 BPF 工作流都是：加载 Program 到内核 → 通过 Map 交换数据 → 用 bpftool 观测/调试。

---

## 2. 安装与基础命令

### 2.1 安装

```bash
# 方式 1：系统包
# Debian/Ubuntu
apt install bpftool
# 或
apt install linux-tools-$(uname -r)

# CentOS/RHEL
yum install bpftool

# 方式 2：源码编译（最新功能）
# bpftool 属于 iproute2 包
git clone https://github.com/shemminger/iproute2.git
cd iproute2/
./configure --prefix=/usr
make -j$(nproc)
make install

# 方式 3：单独编译 bpftool（内核源码）
# 在 kernel source 里：
cd tools/bpf/bpftool/
make -j$(nproc)
make install
```

### 2.2 基础命令

```bash
# 查看 bpftool 版本和帮助
bpftool version
bpftool help

# 常用命令
bpftool prog          # 程序管理
bpftool map           # Map 管理
bpftool link          # Link 管理（程序与 hook 的关系）
bpftool net           # 网络相关的 BPF 附加点
bpftool feature       # 探测内核 BPF 功能
bpftool btf           # BTF (BPF Type Format) 信息
bpftool gen          # 从 skeleton 生成代码
```

### 2.3 查看内核 BPF 功能

```bash
# 探测内核支持哪些 BPF 功能
bpftool feature probe

# output（精简）：
# Scanning system configuration...
# bpf() syscall for unprivileged users is enabled
# JIT compiler is enabled
# JIT compiler hardening is disabled
# Backend JIT compiler is clang (version 14.0.0)
# bpf_trace_printk() is enabled
# ...

# 探测特定功能
bpftool feature probe | grep -E "jit|jit_harden|xdp"

# output：
# JIT compiler is enabled
# JIT compiler hardening is disabled
# bpf_loop() is available
# bpf_spin_lock() is available
# ...
```

---

## 3. Program 管理

### 3.1 查看所有 BPF 程序

```bash
# 列出所有已加载的 BPF 程序
bpftool prog show

# output：
# 5: xdp  name test_xdp  tag=c0312d5b7b9a3f2a  gpl
#     loaded_at 2026-04-18T10:00:00  uid 0
#     xlated 80B  jited 54B  memlock 4096B
#     btf_id 12  map_ids 1,2
#     pids systemd(1)
# 6: kprobe  name ext_enter  tag=a1b2c3d4e5f6  gpl
#     loaded_at 2026-04-18T10:00:01  uid 0
#     xlated 120B  jited 80B  memlock 8192B
#     btf_id 14  map_ids 3
#     pids nginx(1234)

# ── 字段解释 ──
# 5:              BPF program ID
# xdp             Type（程序类型）
# name test_xdp   程序名
# tag=...         BPF 指令的 hash（唯一标识）
# gpl             License（GPL 才能用某些 helper）
# loaded_at       加载时间
# uid             加载进程 UID
# xlated 80B      字节码大小（80 字节）
# jited 54B       JIT 编译后机器码大小（54 字节）
# memlock 4096B   占用内存
# btf_id 12       对应的 BTF 信息 ID
# map_ids 1,2     引用的 Map ID
# pids            加载该程序的进程

# 只显示 ID 和类型
bpftool prog show --json | jq '.[] | {id, type, name}'

# 统计各类型程序数量
bpftool prog show | awk '{print $2}' | sort | uniq -c
```

### 3.2 字段详解

| 字段      | 含义                               |
| --------- | ---------------------------------- |
| `xlated`  | BPF 字节码大小（内核验证器输出）   |
| `jited`   | JIT 编译后机器码大小（x86/arm 等） |
| `memlock` | mlock() 锁定的内存（防止 swap）    |
| `btf_id`  | BTF 信息（用于调试/objdump）       |
| `map_ids` | 程序引用的 Map ID                  |
| `pids`    | 加载进程的 PID+名字                |

### 3.3 dump BPF 字节码

```bash
# 查看程序的 BPF 字节码（xlated，未 JIT 的原始字节码）
bpftool prog dump xlated id 5

# output：
# 0: (bf) r6 = r1
# 1: (18) r1 = 0x0
# 3: (7b) *(u64 *)(r10 - 8) = r6
# 4: (85) call bpf_trace_printk#6
# ...

# 查看 JIT 编译后的机器码（x86_64）
bpftool prog dump jited id 5

# output：
# 0: mov %r6,%rdi
# 1: sub $0x8,%rsp
# ...
#  bpf_trace_printk stub:
#  mov $0x2,%eax
#  ret

# 查看带 BTF 信息的源码级 dump（需要编译时带 -g）
bpftool prog dump xlated id 5 with peeled_branches
# with peeled_branches：简化条件分支

# 导出字节码到文件（用于调试/复现）
bpftool prog dump xlated id 5 file /tmp/prog5_xlated.txt
```

### 3.4 加载 BPF 程序

```bash
# 从 .o (object file) 加载
bpftool prog load ./my_program.o /sys/fs/bpf/my_program

# 或者不指定 path，bpftool 自动分配一个 fd
bpftool prog load ./xdp_prog.o /sys/fs/bpf/xdp_prog pin /sys/fs/bpf/xdp_prog
# 第二次参数：pin 路径（把 program pin 到 bpffs，供其他进程 attach）

# 加载多个 program 到同一个 object file
bpftool prog load ./multi_prog.o /sys/fs/bpf/multi \
    map name data_map /sys/fs/bpf/data_map \
    map name ctrl_map /sys/fs/bpf/ctrl_map
# 同时创建并 pin map

# 只创建 map（不加载 program）
bpftool map create /sys/fs/bpf/my_map type hash \
    key 4 value 8 entries 100 name my_map
```

### 3.5 Program Type 详解

```
Program Type（决定程序能调用哪些 helper，能访问哪些数据）：

tracepoint：      内核 tracepoint（最稳定）
kprobe：          任意内核函数入口/出口
kfunc：           内核函数（BPF_FEAT_KFUNC，4.16+）
uprobe：          用户态函数入口
uretprobe：       用户态函数返回
xdp：             Express Data Path（网卡驱动层）
xdp_generic：     XDP（在普通驱动上）
tc：              tc (traffic control) 入口
sock_ops：        TCP 拥塞控制扩展
sk_msg：          socket 消息处理
lwt_in/lwt_out/lwt_xmit：Lightweight tunnel
lsm：             Linux Security Module
freplace：        其他程序的 "替代实现"（Attach to existing prog）
```

---

## 4. Map 管理

### 4.1 查看所有 Map

```bash
# 列出所有 Map
bpftool map show

# output：
# 1: hash  name packet_cnt  flags 0x0
#     key 8B  value 8B  max_entries 10000  memlock 16384B
#     btf_id 5
# 2: array  name config_map  flags 0x0
#     key 4B  value 16B  max_entries 256  memlock 32768B
#     btf_id 8
# 3: perf_event_array  name events  flags 0x0
#     key 4B  value 8B  max_entries 8  memlock 8192B
#     btf_id 10

# 字段解释：
# 1:                 Map ID
# hash              Type
# name packet_cnt   程序里定义的名字
# key 8B            Key 大小（8 字节）
# value 8B          Value 大小（8 字节）
# max_entries 10000 最多 10000 条
# memlock 16384B    占用内存
# btf_id 5          BTF 类型信息
```

### 4.2 查看 Map 内容

```bash
# 查看某个 Map 的内容
bpftool map dump id 1

# output（hash map）：
# key: 10 00 00 00 00 00 00 00
# value: 00 00 00 00 00 00 00 00
# ----
# key: 11 00 00 00 00 00 00 00
# value: 01 00 00 00 00 00 00 00
# ----

# JSON 格式（方便脚本处理）
bpftool map dump id 1 --json

# 只看所有 key（不展开 value）
bpftool map dump id 1 --show-keys

# 只看所有 value（不显示 key）
bpftool map dump id 1 --show-values

# 查看 array map（按索引顺序）
bpftool map dump id 2
# key: 00 00 00 00          ← index 0
# value: 01 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00
# ----
# key: 01 00 00 00          ← index 1
# value: 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

### 4.3 读写 Map 条目

```bash
# 读取单个 key（HEX 编码）
bpftool map lookup id 1 key 0x10 0x00 0x00 0x00 0x00 0x00 0x00 0x00

# output：
# key: 10 00 00 00 00 00 00 00
# value: 00 00 00 00 00 00 00 00

# 找不到 key 时
# Error: can't lookup key: key does not exist

# 插入/更新 key-value
bpftool map update id 1 key 0x10 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    value 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00

# 更新所有字段为 0（清空）
bpftool map update id 1 key 0x10 0x00 0x00 0x00 0x00 0x00 0x00 0x00 \
    value zero

# 删除 key
bpftool map delete id 1 key 0x10 0x00 0x00 0x00 0x00 0x00 0x00 0x00

# 批量操作（pin 到 bpffs 后直接操作文件）
# bpffs（BPF filesystem）是内核暴露的 Map 访问接口
ls /sys/fs/bpf/
# 路径如：/sys/fs/bpf/my_hash_map
# 直接用 shell 操作：
#   创建：bpftool map create /sys/fs/bpf/my_map ...
#   读写：bpftool map lookup pinned /sys/fs/bpf/my_map key ...

# 批量 dump 所有 key
bpftool map dump id 1 | grep "key:" | awk '{print $2}' | \
    while read key; do
        bpftool map lookup id 1 key $key
    done
```

### 4.4 冻结/监控 Map

```bash
# 冻结 Map（禁止用户态写入，只允许 BPF 程序写入）
bpftool map freeze id 1

# output：
# Map frozen.

# 冻结后尝试更新：
bpftool map update id 1 key 0x10 ... value 0x01 ...
# Error: permission denied: map is frozen

# 解冻：
# (没有直接命令，需要重新加载)

# 持续监控 Map 变化（-F watch 模式，bpftool 5.6+）
bpftool map dump id 1 --raw-access -F
# -F: follow 模式，持续输出变化
# --raw-access: 原始字节（无格式）
```

### 4.5 Map Type 详解

```
常见 Map Type：

hash：          任意 key 的哈希表，最灵活
array：         固定索引的数组（index = key）
perf_event_array：perf 事件输出（用于 bpf_perf_event_output）
prog_array：    存储 BPF program fd（用于 tail call）
sockmap：       socket 映射（用于 sock redirect）
sk_storage：    socket 本地存储（per-socket data）
task_storage：  task 本地存储（per-task data）
stack_trace：   存储 stack trace
lpm_trie：      最长前缀匹配（用于 IP 范围）
bloom_filter：   布隆过滤器（存在性判断）
cgroup_storage：cgroup 级别的 key-value
devmap：        device 映射（XDP redirect）
cpumap：        CPU 映射（XDP multi-buffer）

特殊 Map：
ringbuf：       高性能环形缓冲区（6.1+ 替代 perf_event_array）
ustat：         用户态统计
```

---

## 5. Link 管理（Program 与 Hook 的关系）

### 5.1 什么是 Link

```
Link = Program 附着到 Hook 的关系记录

在没有 Link 之前：
  Program → 知道"在哪跑"（type 决定）
  但外部只能通过 type 推测，不能精确知道"挂在了哪个 exact hook"

有了 Link 之后：
  bpftool link show
  → 精确知道哪个 program 挂在哪个 tracepoint/fs/cgroup...
  → 可以 detach（精确解除附着）
  → 可以查询 attach 详细信息

Link 解决了：
  1. program 卸载时正确清理
  2. 多 program 附着同一个 hook 的顺序管理
  3. 可观测性（知道谁在跑）
```

### 5.2 查看 Link

```bash
# 列出所有 Link
bpftool link show

# output：
# 5: perf_event  prog_id 3  kind xdp
#     target_id 0
#     btf_id 15  attachtag a1b2c3d4e5f6
# 6: tracepoint  prog_id 7  kind kprobe
#     target sys_enter_write
#     btf_id 16  attachtag b2c3d4e5f6a1
# 7: cgroup  prog_id 9  kind sock_ops
#     target_id 1234  cgroup_id 100

# 字段解释：
# 5:                    Link ID
# perf_event            Link 类型（perf_event / tracepoint / cgroup / ...）
# prog_id 3             对应的 program ID
# kind kprobe           program 的 kind（辅助说明）
# target sys_enter_write 具体的 hook 目标
# target_id 0           hook 的具体 ID（cgroup inode 等）
# btf_id 15             BTF 调试信息
# attachtag             唯一的 attach 标识
```

### 5.3 detach（精确卸载）

```bash
# 通过 Link ID detach（精确卸载某个 program 的附着）
bpftool link detach 6

# 卸载后 program 还在，只是停止执行

# 通过 program ID 卸载（所有附着一起卸）
bpftool prog detach id 3

# 查看某 program 的所有 link
bpftool link show | grep "prog_id 3"
```

---

## 6. BTF 调试信息

### 6.1 什么是 BTF

```
BTF (BPF Type Format) = DWARF 的精简版，专门给 BPF 用

作用：
  1. 自动生成 BPF program 的 CO-RE（重定位）
  2. bpftool prog dump 可以显示源码级信息
  3. libbpf/BCC 可以用类型安全的方式访问 map
  4. bpftrace 可以知道 "struct sk_buff *skb" 的字段名

BTF 信息存在：
  /sys/kernel/btf/vmlinux   ← 内核的 BTF（所有内核 struct）
  /sys/fs/bpf/...            ← 用户程序的 BTF（编译时 -g）
```

### 6.2 查看 BTF

```bash
# 查看内核 vmlinux BTF
bpftool btf show

# output：
# [1] INT 'int' size=4
# [2] PTR '(void *)' type_id=0
# [3] STRUCT 'task_struct' size=8256 [...]
# [4] FUNC 'sys_write' type_id=5
# ...

# 查看特定类型（通过 ID 或名字）
bpftool btf dump id 3
# 打印 struct task_struct 的完整定义

# 通过名字 dump
bpftool btf dump name vmlinux

# 查看 struct sk_buff 的字段布局
bpftool btf dump id $(bpftool btf show | grep "STRUCT 'sk_buff'" | awk -F'[][]' '{print $2}')

# output：
# [327] STRUCT 'sk_buff' size=976  vlen=87
#     member 'head'       offset=0  type_id=2  (void *)
#     member 'network_header' offset=56  type_id=2
#     member 'transport_header' offset=64  type_id=2
#     member 'data'       offset=80  type_id=2
#     ...
#     member '__u16 gso_segs' offset=152
```

### 6.3 BTF + prog dump

```bash
# 有了 BTF，prog dump 可以显示结构体字段名
bpftool prog dump xlated id 6 with btf

# output（比 with peeled_branches 更可读）：
# 0: (bf) r6 = r1
# 1: (7b) *(u64 *)(r10 - 8) = r6
# 2: (18) r1 = 0x0
# 3: (85) call bpf_trace_printk#6
# 4: (b7) r0 = 0
# 5: (95) exit
#     ; if (!skb) return 0;
#     ; struct sk_buff *skb = ctx;
#     ; __u32 *pkt_cnt = bpf_map_lookup_elem(&data, &key);
# ...

# 查看某 program 引用的所有 map 的 BTF 类型
bpftool prog show id 6 --json | jq '.map_ids[]'
```

---

## 7. 实战：完整 BPF 程序加载与调试

### 7.1 场景：加载 XDP 程序

```bash
# 假设已有 xdp_prog.o（clang -target bpf -g -O2 -c xdp_prog.c）

# Step 1: 加载 program（同时创建 map）
bpftool prog load ./xdp_prog.o /sys/fs/bpf/xdp_prog \
    map name packet_cnt type hash key 8 value 8 entries 65535 \
    map name xdp_stats type array key 4 value 8 entries 16

# Step 2: attach 到网卡
bpftool net attach xdp id $(bpftool prog show name xdp_prog --json | jq '.[0].id') dev eth0

# 等价于：
ip link set dev eth0 xdp obj /sys/fs/bpf/xdp_prog sec xdp

# Step 3: 验证 attach
ip link show eth0
# output:
# eth0: ... xdp id 7 ...
#         xdp: id 7

# Step 4: 查看 map 数据（实时观察 packet count）
bpftool map dump id 1
# 持续观察：
watch -n1 'bpftool map dump id 1'

# Step 5: 查看 program 运行状态
bpftool prog show name xdp_prog
# 确认 jited + xlated 字节数合理
# 确认 pids 显示 ip/ifindex
```

### 7.2 场景：调试 kprobe 程序

```bash
# 场景：追踪 sys_enter_write 系统调用

# Step 1: 加载 tracepoint program
bpftool prog load ./trace_write.o /sys/fs/bpf/trace_write \
    map name events type perf_event_array key 4 value 8 entries 8

# Step 2: attach 到 tracepoint
bpftool trace attach /sys/kernel/debug/tracing/events/syscalls/sys_enter_write/id \
    id $(bpftool prog show name trace_write --json | jq '.[0].id')

# 更简单的方式（不需要手动找 tracepoint id）：
# 用 bpftrace 一行脚本：
bpftrace -e 'tracepoint:syscalls:sys_enter_write { @[comm] = count(); }'

# Step 3: 查看 bpftrace 输出
# bpftrace 自动创建 map 并持续输出

# Step 4: 如果用纯 bpftool：
# 手动 attach：
TRACE_ID=$(cat /sys/kernel/debug/tracing/events/syscalls/sys_enter_write/id)
bpftool prog attach id $PROG_ID attach_type tracing
```

### 7.3 场景：tail call 链接多个 program

```
Tail call = 一个 BPF program 调用另一个 BPF program
            不返回调用者（直接跳转到目标 program）

限制：
  - 最多 33 层（tail call 链）
  - 跳转双方要满足兼容性（ctx 相同）
  - 用 prog_array map 存储 target program

操作：
  1. 创建一个 prog_array map
  2. 把多个 program load 进 map
  3. 在第一个 program 里调用 bpf_tail_call(ctx, map, index)
```

```bash
# Step 1: 创建 prog_array map
bpftool map create /sys/fs/bpf/jmp_table type prog_array \
    key 4 value 4 entries 8 name jmp_table

# Step 2: 加载 program A
bpftool prog load ./prog_a.o /sys/fs/bpf/prog_a

# Step 3: 加载 program B
bpftool prog load ./prog_b.o /sys/fs/bpf/prog_b

# Step 4: 把 B pin 进 map（A 里面会 tail_call 到 index 0）
bpftool map update id $JMP_MAP_ID key 0 0 0 0 \
    value pinned /sys/fs/bpf/prog_b

# Step 5: attach A 到 hook
bpftool net attach xdp id $PROG_A_ID dev eth0

# 验证 tail_call 是否工作：
# bpftool prog show id $PROG_A_ID
# 观察 jited 字节数是否包含 tail_call stub
```

---

## 8. perf / BCC 协作

### 8.1 perf 与 bpftool

```bash
# perf 在 Linux 5.8+ 内部使用 BPF
perf record -e bpfcache/  # perf 管理的 BPF 程序

# bpftool 看不到 perf 私有的 BPF program（perf 自己管理）

# perf list 可以看到所有可用的 BPF 程序类型
perf list | grep -i bpf

# output：
#   bpfcache/cpu-clock/                                   [Kernel PMU]
#   bpfcache/cpu-clock/                                   [Kernel PMU]
#   ...
```

### 8.2 BCC 程序观测

```bash
# BCC (BPF Compiler Collection) 工具动态生成+加载 BPF
# 常见 BCC 工具：
#   - opensnoop：追踪 open() 系统调用
#   - execsnoop：追踪 execve() 系统调用
#   - funcslower：追踪函数慢调用
#   - offcputime：off-CPU 时间分析
#   - funccount：函数调用计数
#   - trace：自定义探针

# 用 bpftool 观测 BCC 加载的程序
# 假设 opensnoop 正在运行
bpftool prog show | grep opensnoop
# 5: tracepoint  name bpf_prog_main  opensnoop

# 查看 opensnoop 的 map（BCC 用 hash map 存数据）
bpftool map show | grep opensnoop
# 3: hash  name odispid  opensnoop
# 4: perf_event_array  name events  opensnoop

# dump opensnoop 的数据（实时看到文件 open）
bpftool map dump id 3
# key: ... (进程名等)
# value: open 计数
```

### 8.3 快速诊断清单

```bash
# 1. 系统里有多少 BPF program 在跑？
bpftool prog show | wc -l

# 2. 哪些 program 引用了某个 map？
bpftool map show id 1
# 看 prog_ids 字段

# 3. 某个进程加载了哪些 program？
bpftool prog show | grep "pids nginx"

# 4. 查看某个 program 的引用计数（是否还被使用）
bpftool prog show id 6
# 如果没有 pids → 可能是 detached 但没卸载

# 5. 强制卸载某个 program
bpftool prog detach id 6
bpftool prog del id 6

# 6. 快速定位占用最多 memlock 的 program
bpftool prog show | awk '/memlock/ {print $3, $0}' | sort -rn | head

# 7. 导出所有 program 的状态（快照）
bpftool prog show --json > /tmp/bpf_progs.json
bpftool map show --json > /tmp/bpf_maps.json
```

---

## 9. bpftool 进阶用法

### 9.1 批处理模式

```bash
# bpftool 支持从 stdin 读取命令
echo "prog show" | bpftool batch

# 或从文件
cat <<EOF | bpftool batch
prog show
map show
link show
EOF

# 用途：批量操作
cat <<EOF | bpftool batch
map update id 1 key 0x10 0x00 0x00 0x00 0x00 0x00 0x00 0x00 value 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00
map update id 1 key 0x11 0x00 0x00 0x00 0x00 0x00 0x00 0x00 value 0x02 0x00 0x00 0x00 0x00 0x00 0x00 0x00
prog show
EOF
```

### 9.2 脚本化

```bash
#!/bin/bash
# bpf_snapshot.sh — BPF 系统快照脚本

OUT=/tmp/bpf_snapshot_$(date +%Y%m%d_%H%M%S)
mkdir -p $OUT

echo "=== Snapshot $(date) ===" > $OUT/summary.txt

# 1. 所有 program
bpftool prog show --json > $OUT/programs.json
bpftool prog show >> $OUT/summary.txt

# 2. 所有 map
bpftool map show --json > $OUT/maps.json
bpftool map show >> $OUT/summary.txt

# 3. 所有 link
bpftool link show --json > $OUT/links.json
bpftool link show >> $OUT/summary.txt

# 4. 各 program 的字节码（如果有 BTF）
for prog_id in $(bpftool prog show --json | jq '.[].id'); do
    bpftool prog dump xlated id $prog_id with btf >> $OUT/prog_${prog_id}_xlated.txt 2>/dev/null
done

# 5. btf 信息
bpftool btf show > $OUT/btf.txt

# 6. feature 探测
bpftool feature probe > $OUT/features.txt

echo "Snapshot saved to $OUT"
ls -lh $OUT
```

### 9.3 内核参数调优

```bash
# 与 bpftool 配合的 sysctl 参数
# /proc/sys/kernel/bpf_stats_enabled：启用 BPF stats（bpftool prog -s 显示 run_time）

# 启用后可以看到每个 program 的运行统计
bpftool prog show --json | jq '.[] | {name, run_time_ns, run_cnt}'

# bpf() syscall 限制
cat /proc/sys/kernel/bpf/max_progs
# 最大加载 program 数量（默认 4096）

cat /proc/sys/kernel/bpf/max_maps
# 最大 map 数量

cat /proc/sys/kernel/bpf/jit_limit
# JIT 生成的机器码最大内存（默认 64MB）

cat /proc/sys/kernel/bpf/jit_limit
# 调大（高吞吐 BPF 程序）
echo 256 > /proc/sys/kernel/bpf/jit_limit
```

---

## 10. 小结

```
bpftool 核心命令：

Prog 管理：
  bpftool prog show                    列出所有 program
  bpftool prog dump xlated id N        字节码（可读）
  bpftool prog dump jited id N         JIT 机器码
  bpftool prog load FILE PIN            加载 .o 文件
  bpftool prog attach/detach           附着/脱离

Map 管理：
  bpftool map show                     列出所有 map
  bpftool map dump id N                查看所有条目
  bpftool map lookup id N key HEX      读单个 key
  bpftool map update id N key HEX value HEX   写 key-value
  bpftool map freeze id N              禁止用户态写入
  bpftool map create PIN type ...       创建 map

Link 管理：
  bpftool link show                    列出所有 link
  bpftool link detach N                精确卸载

BTF：
  bpftool btf show                     查看类型信息
  bpftool btf dump id N                查看具体 struct
  bpftool prog dump with btf           源码级 dump

Feature：
  bpftool feature probe                探测内核 BPF 能力

诊断顺序：
  1. bpftool prog show → 有哪些 program 在跑
  2. bpftool map show → 有哪些 map
  3. bpftool map dump → 看 map 数据（实时值）
  4. bpftool prog dump → 看字节码（是否被 JIT）
  5. bpftool link show → 确认程序挂在哪里
```

---

## 延伸阅读

- `man bpftool` — bpftool 完整手册
- bpftool 源码: `tools/bpf/bpftool/` (内核源码树)
- iproute2: https://github.com/shemminger/iproute2
- BPF 设计文档: `Documentation/bpf/` (内核源码)
- BCC 工具集: https://github.com/iovisor/bcc
- libbpf (BPF CO-RE): https://github.com/libbpf/libbpf
- 布劳恩/林晨：BPF Performance Tools (book)
