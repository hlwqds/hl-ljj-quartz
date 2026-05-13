---
title: bpftool 实战指南：从入门到精通
date: 2026-04-18 10:00:00
tags: [BPF, bpftool, eBPF, Linux, Network, Observability, Kprobe, Tracepoint, XDP]
description: 用 30+ 实战案例详细讲解 bpftool 的每个核心功能：程序管理、Map 读写、字节码调试、kprobe/XDP/tracepoint 加载，以及与 perf/bpftrace 的协作。
---

# bpftool 实战指南：从入门到精通

## 0. 实战环境准备

### 0.1 确认环境

```bash
# 检查内核支持
uname -r
# 5.10+ 主流发行版都有完整 BPF 支持

# 检查 bpftool 是否安装
bpftool version
# 输出类似：bpftool v5.15.0 aka eBPF 2024

# 检查 BPF 文件系统
ls /sys/fs/bpf/
# 如果没有，挂载：
mount -t bpf bpf /sys/fs/bpf

# 检查当前用户是否有 CAP_BPF（5.8+ 非 root 可用 BPF）
cat /proc/self/status | grep Cap
# CapEff: 0000003fffffffff → 有 CAP_BPF

# 检查 JIT
cat /proc/sys/net/core/bpf_jit_enable
# 1 = 开启，2 = 开启 + debug 日志
```

### 0.2 常用工具准备

```bash
# bpftrace（快速写 BPF 探针）
sudo apt install bpftrace
bpftrace --version

# bcc-tools（BCC 工具集）
sudo apt install bcc-tools
ls /usr/share/bcc/tools/
# opensnoop  execsnoop  funccount  stackcount  etc.

# python3-bcc（BCC Python 绑定）
sudo apt install python3-bpfcc
```

---

## 1. bpftool prog show：查看正在运行的 BPF 程序

### 1.1 基础查看

```bash
# 最基础的命令，列出所有已加载的 BPF 程序
bpftool prog show

# 实际输出示例（截取真实系统）：
# 45: sched_ext  name bpf_monitoring  tag=d3a5b9c2e1f0  gpl
#     loaded_at 2026-04-18T09:30:00  uid 1000
#     xlated 256B  jited 192B  memlock 4096B
#     btf_id 78  map_ids 5,12
#     pids systemd(1)
# 78: kprobe  name ext4_file_write  tag=a1b2c3d4e5f6  gpl
#     loaded_at 2026-04-18T10:15:00  uid 0
#     xlated 128B  jited 86B  memlock 8192B
#     btf_id 103  map_ids 2,3
#     pids python3(12345)

# 格式化输出（JSON）
bpftool prog show --json | jq '.'

# 只显示 ID 和类型
bpftool prog show | awk '{print $1, $2, $3}'

# 只显示 XDP 程序
bpftool prog show | grep xdp

# 只显示 kprobe
bpftool prog show | grep kprobe

# 统计各类型数量
bpftool prog show | awk '{print $2}' | sort | uniq -c | sort -rn
```

### 1.2 配合 jq 精细过滤

```bash
# 查找引用了特定 map 的 program
bpftool prog show --json | jq '.[] | select(.map_ids | index(5) >= 0) | {id, name, type}'

# 查找特定进程加载的 program
bpftool prog show --json | jq '.[] | select(.pids | index("nginx") >= 0)'

# 查找占用 memlock 最大的 program
bpftool prog show --json | jq '.[] | select(.memlock_rss) | {id, name, memlock_rss}' | sort

# 查找所有 kprobe program
bpftool prog show --json | jq '.[] | select(.type == "kprobe")'
```

### 1.3 实战：找出所有 XDP 程序

```bash
# 场景：排查系统里谁在用 XDP
bpftool prog show | grep -A2 "^.*: xdp"

# 输出：
# 23: xdp  name xdp_ddos_fltr  tag=abc123  gpl
#     loaded_at 2026-04-17  uid 0
#     xlated 80B  jited 54B  memlock 4096B
#     btf_id 45  map_ids 1,2
#     pids docker(6789)

# 找 XDP program 对应的网卡
bpftool link show | grep xdp
# 12: perf_event  prog_id 23  kind xdp  target_id 0
# target_id=0 → 这是全局 XDP（attach 到所有网卡）

# 如果是 per-device XDP：
ip link show | grep xdp
# eth0: ... xdp id 23
# eth1: ... xdp id 45

# 找具体是哪个网卡的 XDP
ip -br link show | grep -v UP
# 或者
bpftool net show
```

---

## 2. bpftool prog dump：dump 字节码与 JIT 代码

### 2.1 xlated（BPF 字节码）

```bash
# dump 某个 program 的字节码（翻译后的 BPF 指令）
# 先找到 program id
bpftool prog show | grep kprobe
# 78: kprobe  name ext4_file_write  tag=a1b2c3d4e5f6  gpl

# dump 字节码
bpftool prog dump xlated id 78

# 实际输出：
# 0: (bf) r6 = r1              ; r6 = ctx (指向 struct pt_regs)
# 1: (18) r1 = 0x0              ; 加载 0 到 r1
# 3: (7b) *(u64 *)(r10 - 8) = r6   ; 保存 ctx 到栈
# 4: (85) call bpf_trace_printk#6  ; 调用辅助函数
# 5: (b7) r0 = 0                ; 返回值 = 0
# 6: (95) exit                  ; 退出

# 带 BTF 信息的 dump（更可读，需要编译时带 -g）
bpftool prog dump xlated id 78 with btf

# 输出（带注释）：
# 0: (bf) r6 = r1
#     ; struct pt_regs *ctx = (struct pt_regs *)r1
# 1: (18) r1 = 0x0
# 2: (7b) *(u64 *)(r10 - 8) = r6
#     ; bpf_printk("entered ext4_file_write");
# 4: (85) call bpf_trace_printk#6
# 5: (b7) r0 = 0
#     ; return 0
# 6: (95) exit

# 导出到文件
bpftool prog dump xlated id 78 file /tmp/prog78_xlated.txt

# dump 所有 program（系统快照）
for id in $(bpftool prog show --json | jq '.[].id'); do
    bpftool prog dump xlated id $id file /tmp/prog_${id}_xlated.txt 2>/dev/null
done
```

### 2.2 jited（机器码）

```bash
# dump JIT 编译后的 x86_64 机器码
bpftool prog dump jited id 78

# 输出（x86_64 汇编）：
# 0:   push   %rbp
# 1:   mov    %rsp,%rbp
# 2:   sub    $0x8,%rsp
# 3:   mov    %rdi,-0x8(%rbp)
# 4:   mov    $0x0,%eax         ; bpf_trace_printk stub
# 5:   add    $0x8,%rsp
# 6:   pop    %rbp
# 7:   ret

# jited + BTF = 最好用的调试方式
bpftool prog dump jited id 78 with btf

# 如果看到 "0: (97)" 表示什么？
# → 这是 BPF_EXIT 的 opcode = 0x95，在 JIT 后变成 x86 ret

# 配合 addr2line 反查源码行号（需要 ELF 信息）
# 需要编译时带 -g
```

### 2.3 实战：验证 JIT 是否生效

```bash
# 场景：JIT 没生效，性能差

# Step 1: 找到要检查的 program
bpftool prog show | grep sock_ops
# 90: sock_ops  name bpf_cc_algo  tag=9f8e7d6c5b4a  gpl

# Step 2: 对比 xlated 和 jited 大小
bpftool prog show id 90 | grep "xlated\|jited"
# xlated 512B  jited 256B
# 有 jited → JIT 在工作

# 如果 jited 是 0B：
# → JIT 被禁用或该 program 类型不支持 JIT

# Step 3: 检查系统 JIT 是否开启
cat /proc/sys/net/core/bpf_jit_enable
# 0 = 关闭，1 = 开启，2 = 开启+日志

# 开启 JIT（临时）
echo 1 > /proc/sys/net/core/bpf_jit_enable

# 开启 JIT（永久）
# /etc/sysctl.conf:
# net.core.bpf_jit_enable = 1

# Step 4: JIT 日志（如果 eBPF 程序报错）
echo 2 > /proc/sys/net/core/bpf_jit_enable
# 然后 dmesg | tail 查看 JIT 日志
dmesg | grep "bpf_jit" | tail -20

# 关闭 JIT 后的效果（对比性能）
# 关 JIT → 所有 BPF 走 interpreter，性能下降 2-5x
echo 0 > /proc/sys/net/core/bpf_jit_enable
```

---

## 3. bpftool map：Map 管理与数据读写

### 3.1 查看 Map

```bash
# 列出所有 Map
bpftool map show

# 输出示例：
# 1: hash  name packet_cnt  flags 0x0
#     key 8B  value 8B  max_entries 65536  memlock 131072B
#     btf_id 15  frozen 0
# 2: array  name xdp_stats  flags 0x0
#     key 4B  value 8B  max_entries 16  memlock 32768B
#     btf_id 18  frozen 0
# 3: perf_event_array  name events  flags 0x0
#     key 4B  value 8B  max_entries 8  memlock 8192B
#     btf_id 22  frozen 0

# 找特定名字的 map
bpftool map show | grep xdp
# 2: array  name xdp_stats ...

# 找引用了 program 90 的 map
bpftool map show --json | jq '.[] | select(.inner_map_ids == 90)'

# 找 frozen（被冻结）的 map
bpftool map show | grep frozen
```

### 3.2 dump Map 内容

```bash
# dump hash map
bpftool map dump id 1

# 输出：
# key: 0a 00 00 00 00 00 00 00   ← src_ip 10.0.0.1 (LE)
# value: 00 00 00 00 00 00 00 00   ← count = 0
# ----
# key: 0b 00 00 00 00 00 00 00   ← src_ip 11.0.0.1
# value: 01 00 00 00 00 00 00 00   ← count = 1
# ----

# dump array map（按索引顺序）
bpftool map dump id 2

# 输出：
# key: 00 00 00 00        ← index 0
# value: 00 00 00 00 00 00 00 00
# ----
# key: 01 00 00 00        ← index 1
# value: 00 00 00 00 00 00 00 00
# ----

# JSON 格式
bpftool map dump id 1 --json | jq '.'

# 只看 key，不看 value
bpftool map dump id 1 --show-keys

# 只看非零的 value（过滤）
bpftool map dump id 1 | grep -v "value: 00 00 00 00 00 00 00 00"
```

### 3.3 lookup（读单个 key）

```bash
# 场景：想知道特定 IP 的计数

# hash map：key 是 src_ip (8 bytes)
bpftool map lookup id 1 key 0a 00 00 00 00 00 00 00

# 输出：
# key: 0a 00 00 00 00 00 00 00
# value: 00 00 00 00 00 00 00 00

# 十六进制 key（更直接）
# 如果我知道 key 是二进制 0x0a 0x00 0x00 0x00 0x00 0x00 0x00 0x00：
printf '\x0a\x00\x00\x00\x00\x00\x00\x00' | xxd
# 00000000: 0a00 0000 0000 0000                   ....

# 用 xxd 辅助 lookup：
echo -n $'\x0a\x00\x00\x00\x00\x00\x00\x00' | bpftool map lookup id 1 key -
# 从 stdin 读取 key

# array map：key 是索引
bpftool map lookup id 2 key 00 00 00 00
# 读 index 0

# 找不到时
# Error: can't lookup key: key does not exist
```

### 3.4 update（写 key-value）

```bash
# 更新 hash map 的 value
bpftool map update id 1 \
    key 0a 00 00 00 00 00 00 00 \
    value 2a 00 00 00 00 00 00 00
# 把 IP 10 的计数从 0 改成 42

# 用 xxd 转换：
echo -n $'\x0a\x00\x00\x00\x00\x00\x00\x00' | bpftool map update id 1 key - \
    value $'\x2a\x00\x00\x00\x00\x00\x00\x00'

# 批量 update（脚本）
#!/bin/bash
# 往 hash map 写入多个条目
for ip in 10 11 12 13 14 15; do
    ip_hex=$(printf '%02x' $ip)
    key=$(printf "\\x${ip_hex}\\x00\\x00\\x00\\x00\\x00\\x00\\x00")
    val=$(printf "\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x$(printf '%02x' $ip)")
    echo -n "$key" | bpftool map update id 1 key - value $val
done

# 清空某个 key（value 写 0）
bpftool map update id 1 key 0a 00 00 00 00 00 00 00 value zero

# pinned map（从 bpffs 路径操作）
bpftool map lookup pinned /sys/fs/bpf/xdp_stats_map key 00 00 00 00
```

### 3.5 delete（删除 key）

```bash
# 删除 hash map 中的 key
bpftool map delete id 1 key 0a 00 00 00 00 00 00 00

# 批量删除（先 dump 所有 key，再逐个删除）
bpftool map dump id 1 | grep "^key:" | while read line; do
    key=$(echo "$line" | awk '{print $2, $3, $4, $5, $6, $7, $8, $9}')
    bpftool map delete id 1 key $key
done

# 清空整个 map（重建）
bpftool map delete id 1 key 0a 00 00 00 00 00 00 00  # 一个一个删
# 或者：删除 map 再重建
bpftool map create /sys/fs/bpf/same_name type hash key 8 value 8 entries 65536
```

### 3.6 freeze（冻结 Map）

```bash
# freeze 后：只允许 BPF 程序写入，禁止用户态更新
bpftool map freeze id 1

# 验证
bpftool map show id 1 | grep frozen
# frozen 1

# freeze 后尝试 update
bpftool map update id 1 key 0a 00 00 00 00 00 00 00 value 2a 00 00 00 00 00 00 00
# Error: can't update: map is frozen

# freeze 的典型用途：
# BPF 程序计数 → 用户态只读 → 防止意外污染数据
# 比如：BPF 程序在统计数据，用户运维脚本只能读不能写
```

### 3.7 create（创建 Map）

```bash
# 创建一个 hash map 并 pin 到 bpffs
bpftool map create /sys/fs/bpf/my_counter \
    type hash \
    key 8 value 8 \
    entries 1024 \
    name my_counter

# 创建 array map
bpftool map create /sys/fs/bpf/ip_index \
    type array \
    key 4 value 16 \
    entries 256 \
    name ip_index

# 创建 perf_event_array（用于 perf output）
bpftool map create /sys/fs/bpf/perf_output \
    type perf_event_array \
    key 4 value 8 \
    entries 8 \
    name perf_output

# 查看创建结果
bpftool map show pinned /sys/fs/bpf/my_counter

# 删除 pinned map
rm /sys/fs/bpf/my_counter
# 或者
bpftool map del pinned /sys/fs/bpf/my_counter
```

### 3.8 实战：监控 XDP packet count

```bash
# 场景：用 bpftrace 写一个 XDP counter，然后用 bpftool 观察

# Step 1: 写一个简单的 XDP 程序（C 代码，保存为 counter.bpf.c）
cat > counter.bpf.c << 'EOF'
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);      // src IP
    __type(value, __u64);    // packet count
} pkt_count SEC(".maps");

SEC("xdp")
int count_packets(struct xdp_md *ctx) {
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto == htons(ETH_P_IP)) {
        struct iphdr *ip = data + sizeof(*eth);
        if ((void *)(ip + 1) > data_end)
            return XDP_PASS;

        __u32 src_ip = ip->saddr;
        __u64 *count = bpf_map_lookup_elem(&pkt_count, &src_ip);
        if (count) {
            __sync_fetch_and_add(count, 1);
        } else {
            __u64 one = 1;
            bpf_map_update_elem(&pkt_count, &src_ip, &one, BPF_ANY);
        }
    }
    return XDP_PASS;
}
EOF

# Step 2: 编译
clang -target bpf -Wall -O2 -g -c counter.bpf.c -o counter.bpf.o

# Step 3: 加载（bpftool）
bpftool prog load counter.bpf.o /sys/fs/bpf/counter \
    map name pkt_count pinned /sys/fs/bpf/pkt_count

# Step 4: attach 到 eth0
bpftool net attach xdp id $(bpftool prog show name count_packets --json | jq '.[0].id') dev eth0

# Step 5: 用 ping 触发流量
ping -c 100 8.8.8.8 &

# Step 6: bpftool 观察 Map 数据（实时）
watch -n1 'bpftool map dump id $(bpftool map show name pkt_count --json | jq ".[0].id")'

# Step 7: 或者直接用 bpftool 查 key
# 先看看 map id
MAP_ID=$(bpftool map show name pkt_count --json | jq '.[0].id')
bpftool map dump id $MAP_ID

# 输出：
# key: c0 a8 01 01        ← 192.168.1.1 (LE)
# value: 64 00 00 00 00 00 00 00   ← 100 (LE) = ping 发了 100 个包

# 实战技巧：把 IP 转换成人类可读格式
# 用 python 解析：
python3 -c "
import struct
data = bytes.fromhex('c0 a8 01 01'.replace(' ', ''))
ip = '.'.join(str(b) for b in reversed(data))
print(f'Src IP: {ip}')
val = int.from_bytes(bytes.fromhex('64 00 00 00 00 00 00 00'.replace(' ', '')), 'little')
print(f'Count: {val}')
"
# Src IP: 192.168.1.1
# Count: 100
```

---

## 4. bpftool prog load：加载 BPF 程序

### 4.1 基础加载

```bash
# 从 object file 加载
bpftool prog load ./my_prog.o /sys/fs/bpf/my_prog

# 加载时同时 pin map
bpftool prog load ./counter.bpf.o /sys/fs/bpf/counter \
    map name pkt_count pinned /sys/fs/bpf/pkt_count \
    map name xdp_stats pinned /sys/fs/bpf/xdp_stats

# 如果 obj 文件里有多个 program，可以选择性加载
# 查看 obj 文件里有几个 program：
llvm-objdump -t ./counter.bpf.o | grep -E "SEC\(" | head

# 输出：
# .text:    函数
# xdp:      XDP program
# maps:     map 定义

# 只加载某个 program：
bpftool prog load ./counter.bpf.o /sys/fs/bpf/counter \
    type xdp
# type xdp = 指定 program type（省略则加载所有）

# 查看加载后的状态
bpftool prog show name count_packets
```

### 4.2 加载时指定 BTF

```bash
# 如果 object 文件包含 DWARF/bpf.debug_info，bpftool 自动使用
# 强制使用 BTF：
bpftool prog load ./my_prog.o /sys/fs/bpf/my_prog with_btf

# 导出 BTF info：
bpftool prog load ./my_prog.o /sys/fs/bpf/my_prog \
    btf custom.btf

# 查看 object 文件的 BTF 信息：
bpftool btf dump file ./my_prog.o
```

### 4.3 实战：加载 XDP 程序并观察

```bash
# 完整 XDP 加载流程

# Step 1: 准备 XDP 程序（简化版 xdp_drop.bpf.c）
cat > xdp_drop.bpf.c << 'EOF'
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, int);
    __type(value, int);
} drop_counter SEC(".maps");

SEC("xdp")
int xdp_drop_tcp(struct xdp_md *ctx) {
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_PASS;

    if (eth->h_proto != htons(ETH_P_IP)) return XDP_PASS;

    struct iphdr *ip = data + sizeof(*eth);
    if ((void *)(ip + 1) > data_end) return XDP_PASS;

    // 丢 TCP 包
    if (ip->protocol == IPPROTO_TCP) {
        int key = 0;
        int *count = bpf_map_lookup_elem(&drop_counter, &key);
        if (count) (*count)++;
        return XDP_DROP;
    }
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
EOF

# Step 2: 编译
clang -target bpf -O2 -g -Wall -c xdp_drop.bpf.c -o xdp_drop.bpf.o

# Step 3: 验证编译结果
llvm-objdump -h xdp_drop.bpf.o
# 输出：
# xdp_drop.bpf.o:   file format ELF64-BPF
# Sections:
#     Name         Type     Addr      Size
#     .maps        PROGBITS 000000000  00000100
#     xdp          PROGBITS 000000000  00000120
#     license      PROGBITS 000000000  00000004

# Step 4: 加载
bpftool prog load xdp_drop.bpf.o /sys/fs/bpf/xdp_drop \
    map name drop_counter pinned /sys/fs/bpf/drop_counter

# Step 5: 验证 program 加载成功
bpftool prog show name xdp_drop_tcp

# 输出：
# 101: xdp  name xdp_drop_tcp  tag=3f2a1b0c9d8e  gpl
#     loaded_at 2026-04-18T11:00:00  uid 0
#     xlated 192B  jited 128B  memlock 8192B
#     btf_id 150  map_ids 202
#     pids bpftool(12345)

# Step 6: attach 到网卡
PROG_ID=$(bpftool prog show name xdp_drop_tcp --json | jq '.[0].id')
bpftool net attach xdp id $PROG_ID dev eth0

# Step 7: 确认 attach 成功
ip link show eth0 | grep xdp
# eth0: ... xdp id 101

# Step 8: 发送 TCP 流量（触发 drop）
curl -s --connect-timeout 1 http://10.0.0.1:80 &
# 或
nc -z 8.8.8.8 443 &

# Step 9: 查看 drop count
bpftool map dump id $(bpftool map show name drop_counter --json | jq '.[0].id')
# value 的前 4 字节就是 drop count

# Step 10: 解绑 XDP（清理）
bpftool net detach xdp dev eth0
```

---

## 5. bpftool kprobe/unix/prog attach：挂载 BPF 程序

### 5.1 attach kprobe

```bash
# 加载 kprobe program 后 attach
# 假设已有 ext4_write_end.o（编译好的 BPF program）
bpftool prog load ext4_write_end.o /sys/fs/bpf/ext4_write_end

# 找函数地址
bpftool prog show name ext4_write_end --json | jq '.[0].id'
# 假设是 105

# attach（两种方式）

# 方式 1：用 bpftool trace attach
bpftool trace attach id 105 /proc/kallsyms

# 方式 2：用 bpftool prog attach（通用）
bpftool prog attach id 105 \
    attach_type kprobe \
    target ext4_write_end

# 查看 attach 结果
bpftool link show | grep 105

# detach
bpftool prog detach id 105 attach_type kprobe target ext4_write_end

# attach 到函数入口（默认 kprobe）或出口（kretprobe）
# kretprobe = 函数返回时执行
# bpftool prog attach id 105 attach_type kretprobe target ext4_write_end
```

### 5.2 attach tracepoint

```bash
# 加载 tracepoint program
bpftool prog load ./sched_switch.o /sys/fs/bpf/sched_switch

# 找 tracepoint path
ls /sys/kernel/debug/tracing/events/sched/sched_switch/
# id  format  filter  hist  enable  trigger

# attach
bpftool prog attach id 106 \
    attach_type tracepoint \
    target sched_switch

# 或者直接用 tracepoint id
TRACE_ID=$(cat /sys/kernel/debug/tracing/events/sched/sched_switch/id)
bpftool trace attach id 106 tracepoint_id $TRACE_ID

# 查看
bpftool link show | grep tracepoint

# detach
bpftool link show | grep "prog_id 106" | awk '{print $1}' | xargs bpftool link detach
```

### 5.3 实战：追踪 TCP 连接建立

```bash
# 追踪 inet_csk_accept（TCP accept）

# Step 1: 写 BPF 程序（accept.bpf.c）
cat > accept.bpf.c << 'EOF'
#include <linux/bpf.h>
#include <linux/skbuff.h>
#include <linux/tcp.h>
#include <linux/socket.h>
#include <net/sock.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_trace_printk.h>

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);  // pid
    __type(value, __u64); // timestamp
} start_time SEC(".maps");

SEC("tracepoint/syscalls/sys_enter_accept4")
int trace_accept(struct trace_event_raw_sys_enter *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    __u64 ts = bpf_ktime_get_ns();
    bpf_map_update_elem(&start_time, &pid, &ts, BPF_ANY);
    bpf_trace_printk("accept syscall entered, pid=%d\\n", pid);
    return 0;
}

char _license[] SEC("license") = "GPL";
EOF

# Step 2: 编译
clang -target bpf -O2 -g -c accept.bpf.c -o accept.bpf.o

# Step 3: 加载
bpftool prog load accept.bpf.o /sys/fs/bpf/accept_trace

# Step 4: attach
PROG_ID=$(bpftool prog show name trace_accept --json | jq '.[0].id')
bpftool prog attach id $PROG_ID attach_type tracepoint target sys_enter_accept4

# Step 5: 观察 bpf_trace_pipe（bpf_trace_printk 的输出）
# 终端1：
cat /sys/kernel/debug/tracing/trace_pipe

# 终端2：触发 accept
nc -l 8080 &
sleep 1
curl localhost:8080

# 终端1 看到：
# nc-12345-... [001] ...  accept syscall entered, pid=12345

# Step 6: 用 bpftool 查看 map（统计）
bpftool map dump id $(bpftool map show name start_time --json | jq '.[0].id')
```

### 5.4 实战：追踪 TCP retransmit

```bash
# TCP 重传追踪

# Step 1: 用 bpftrace 一行脚本（最简单）
bpftrace -e '
    tracepoint:tcp/tcp_retransmit_skb {
        @["src"] = hist(tcp_skb_trace_args(args)->saddr);
        @["rcv_nxt"] = hist(tcp_skb_trace_args(args)->rcv_nxt);
    }
'

# 等价 bpftool 操作：
# TCP 重传探针在 tcp_retransmit_skb tracepoint
ls /sys/kernel/debug/tracing/events/tcp/tcp_retransmit_skb/
# id  format

# Step 2: 找相关 kprobe
# tcp_retransmit_skb 的调用路径
cat /sys/kernel/debug/tracing/kprobe_profile | grep tcp_retransmit

# Step 3: 用 bpftrace 替代手动写 C
bpftrace -e '
    tracepoint:tcp:tcp_retransmit_skb {
        $skb = (struct sk_buff *)args->skbaddr;
        $family = $skb->sk ? $skb->sk->__sk_common.skc_family : 0;
        if ($family == AF_INET) {
            $src = $skb->sk->__sk_common.skc_rcv_saddr;
            $dst = $skb->sk->__sk_common.skc_daddr;
            $sport = $skb->sk->__sk_common.skc_num;
            $dport = bpf_ntohs($skb->sk->__sk_common.skc_dport);
            printf("retransmit: %pI4:%d -> %pI4:%d\n", $src, $sport, $dst, $dport);
        }
    }
' &
```

---

## 6. bpftool link：精确管理程序与 Hook 的关系

### 6.1 link show

```bash
# 查看所有 link
bpftool link show

# 输出：
# 10: perf_event  prog_id 45  kind kprobe
#     target sys_enter_write
#     target_id 0
#     btf_id 99  attachtag abc123
# 11: tracepoint  prog_id 46  kind tracepoint
#     target sched_switch
#     btf_id 101  attachtag def456
# 12: cgroup  prog_id 47  kind sock_ops
#     target_id 1234  cgroup_id 5678

# 只看 tracepoint link
bpftool link show | grep tracepoint

# 查看特定 prog_id 的 link
bpftool link show | grep "prog_id 45"

# JSON 输出
bpftool link show --json | jq '.[] | {id, type, prog_id, target}'
```

### 6.2 link detach

```bash
# 通过 link id 精确 detach
bpftool link detach 10
# link 10: kprobe sys_enter_write → 解除附着，program 停止执行

# 通过 program ID detach 所有附着
bpftool prog detach id 45
# 解除 prog_id=45 的所有 link（可能多个 hook 都挂着）

# 批量 detach（同类型）
for link_id in $(bpftool link show | grep "kind kprobe" | awk '{print $1}' | tr -d ':'); do
    bpftool link detach $link_id
done
```

### 6.3 实战：清理所有 BPF program

```bash
# 场景：测试完要清理所有 BPF program 和 map

# Step 1: 找出所有 link
bpftool link show | awk '{print $1}' | tr -d ':' | while read id; do
    [ -n "$id" ] && bpftool link detach $id 2>/dev/null && echo "Detached link $id"
done

# Step 2: 找出所有 pinned map 并删除
ls /sys/fs/bpf/ | while read name; do
    if [ -f "/sys/fs/bpf/$name" ]; then
        rm "/sys/fs/bpf/$name" && echo "Removed $name"
    fi
done

# Step 3: 清理 tc qdisc 的 bpf program
tc qdisc show | grep "bpf obj"
# 如果有，删除
# tc qdisc del dev eth0 ingress

# Step 4: 清理 XDP
ip link set dev eth0 xdp off 2>/dev/null
```

---

## 7. bpftool btf：查看类型信息

### 7.1 查看内核 BTF

```bash
# 查看系统所有 BTF 类型
bpftool btf show

# 输出（精简）：
# [1] INT 'int' size=4
# [2] PTR '(void *)' type_id=0
# [3] STRUCT 'sk_buff' size=976  vlen=87
# [4] FUNC 'tcp_v4_connect' type_id=12

# 只看 struct 类型
bpftool btf show | grep "STRUCT"

# 只看特定类型
bpftool btf dump id 3
# 输出 struct sk_buff 完整定义

# 按名字查找
bpftool btf show | grep "FUNC 'inet_connect'"
# [45] FUNC 'inet_connect' type_id=67

# dump 某个 struct
bpftool btf dump id 3
# 输出：
# [3] STRUCT 'sk_buff' size=976  vlen=87
#     member 'head'       offset=0  type_id=2  (void *)
#     member 'network_header' offset=56  type_id=2
#     member 'transport_header' offset=64  type_id=2
#     member 'data'       offset=80  type_id=2
#     ...（87 个成员）
```

### 7.2 实战：找 struct offset

```bash
# 场景：写 BPF 程序需要知道某字段的 offset
# 比如 sk_buff 的 data 字段在 offset 多少？

# 查 BTF
bpftool btf show | grep "STRUCT 'sk_buff'"
# [327] STRUCT 'sk_buff' ...

# dump 该 struct
bpftool btf dump id 327 | grep "'data'"

# 输出：
#     member 'data'       offset=80  type_id=2

# 结论：data 在 offset 80

# 所以 C 代码里可以直接用：
# void *data = (void *)(skb->data);
# 或者用 BPF_CORE_READ：
# __u8 *data = BPF_CORE_READ(skb, data);

# 另一个例子：找 tcphdr 的 source port offset
bpftool btf show | grep "STRUCT 'tcphdr'"
bpftool btf dump id $(bpftool btf show | grep "STRUCT 'tcphdr'" | awk -F'[][]' '{print $2}') \
    | grep -E "source|dest"

# 输出：
#     member 'source'     offset=0  type=__u16
#     member 'dest'       offset=2  type=__u16
# 所以 source port 在 offset 0，dest port 在 offset 2
```

### 7.3 实战：验证 BPF CO-RE 重定位

```bash
# 场景：验证 BPF 程序在不同内核版本间的字段偏移

# 写一个使用 BPF_CORE_READ 的程序
cat > check_sk.bpf.c << 'EOF'
#include <linux/bpf.h>
#include <linux/skbuff.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

SEC("tracepoint/syscalls/sys_enter_write")
int check_sk(struct trace_event_raw_sys_enter *ctx) {
    // 通过 BTF 读取 sk_buff->len
    // 依赖 BPF CO-RE 自动重定位
    // 不需要手动算 offset
    bpf_printk("trace enter write\\n");
    return 0;
}
char _license[] SEC("license") = "GPL";
EOF

# 编译时用 CO-RE
clang -target bpf -O2 -g -c check_sk.bpf.c -o check_sk.bpf.o
# CO-RE 信息在 .BTF.ext section

# 加载
bpftool prog load check_sk.bpf.o /sys/fs/bpf/check_sk

# dump 带 BTF 的字节码（验证 CO-RE）
bpftool prog dump xlated id $(bpftool prog show name check_sk --json | jq '.[0].id') with btf

# 如果看到警告：
# "libbpf: extern (root): failed to resolve 'bpf_test'
# → BTF 重定位失败，字段可能被重命名或移除
```

---

## 8. bpftool net：网络 BPF 附加点

### 8.1 XDP

```bash
# 查看 XDP 附加状态
bpftool net

# 输出：
# xdp:
#   eth0(3) driver id 23  xdp_prog 'xdp_fwd' @5
#   eth1(4) hw  id 45  xdp_prog 'xdp_hw' @7
#   lo(1) offloaded id 99  xdp_prog 'xdp_ovs' @11

# 解释：
# eth0: driver 模式（内核驱动直接处理）
# eth1: hw 模式（网卡硬件卸载）
# lo: offloaded（OVS/DPDK 接管）

# attach XDP（bpftool 方式）
bpftool net attach xdp id 23 dev eth0

# detach XDP
bpftool net detach xdp dev eth0

# 查看所有 XDP program
bpftool net | grep -A1 "xdp:"

# 快速查看所有 XDP program + 对应网卡
bpftool net show
```

### 8.2 tc（traffic control）

```bash
# BPF 附加到 tc ingress/egress

# attach tc ingress（在 netdev 层，XDP 之后）
tc qdisc add dev eth0 clsact

# 用 bpftool 加载 tc program
bpftool prog load ./tc_sched.o /sys/fs/bpf/tc_sched \
    map name filter_map pinned /sys/fs/bpf/filter_map

# attach 到 tc ingress
tc filter add dev eth0 ingress \
    protocol ip \
    bpf object-pinned /sys/fs/bpf/tc_sched \
    section clsact/ingress \
    action bpf

# attach 到 tc egress
tc filter add dev eth0 egress \
    protocol ip \
    bpf object-pinned /sys/fs/bpf/tc_sched \
    section clsact/egress \
    action bpf

# 查看 tc bpf program
tc filter show dev eth0 ingress
# output：
# filter protocol ip pref 1 distributor
# filter protocol ip pref 1 distributor  chain 0 handle 0x1
#   bpf oci

# detach
tc filter del dev eth0 ingress
```

### 8.3 实战：XDP + tc 组合限速

```bash
# 场景：XDP 在入口限速 + tc 在出口限速

# Step 1: 写限速 BPF（XDP 入口）
cat > ratelimit.bpf.c << 'EOF'
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, int);
    __type(value, __u64);  // byte count
} bw_state SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, int);
    __type(value, __u32);  // rate limit in bytes/s
} rate_limit SEC(".maps");

SEC("xdp")
int ratelimit_xdp(struct xdp_md *ctx) {
    __u64 now = bpf_ktime_get_ns();
    __u32 key = 0;
    __u64 *bytes = bpf_map_lookup_elem(&bw_state, &key);
    __u32 *limit = bpf_map_lookup_elem(&rate_limit, &key);

    if (bytes && limit) {
        __u64 elapsed = now / 1000000000ULL; // seconds
        __u64 allowed = (*limit) * elapsed;
        if (*bytes > allowed) return XDP_DROP;
        __sync_fetch_and_add(bytes, 64); // approximate packet size
    }
    return XDP_PASS;
}
char _license[] SEC("license") = "GPL";
EOF

# Step 2: 编译 + 加载
clang -target bpf -O2 -g -c ratelimit.bpf.c -o ratelimit.bpf.o
bpftool prog load ratelimit.bpf.o /sys/fs/bpf/rl \
    map name bw_state pinned /sys/fs/bpf/bw_state \
    map name rate_limit pinned /sys/fs/bpf/rate_limit

# Step 3: attach
PROG_ID=$(bpftool prog show name ratelimit_xdp --json | jq '.[0].id')
bpftool net attach xdp id $PROG_ID dev eth0

# Step 4: 设置限速值（100MB/s）
bpftool map update id $(bpftool map show name rate_limit --json | jq '.[0].id') \
    key 00 00 00 00 value 64 00 00 00 00 00 00 00
# 0x64 = 100 MB/s = 100 * 1024 * 1024 bytes/s
# 更简单：printf '\x64\x00\x00\x00' | ...

# Step 5: 观察
watch -n1 'bpftool map dump id $(bpftool map show name bw_state --json | jq ".[0].id")'

# Step 6: 清理
bpftool net detach xdp dev eth0
```

---

## 9. bpftool feature：探测内核 BPF 能力

### 9.1 完整探测

```bash
# 探测内核支持的所有 BPF 功能
bpftool feature probe

# 实际输出（精简）：
# Scanning system configuration...
# bpf() syscall for unprivileged users is enabled
# JIT compiler is enabled
# JIT compiler hardening is disabled
# JIT caller address is fetched with eBPF jited_enter_
# BPF_TYPE_MAP_OPS support is available
# bpf_trace_printk() is enabled
# bpf_spin_lock() is available
# bpf_probe_read_kernel() is available
# ...
# memlock pre-allocated setsockopt is available
# bpf_sock_ops() is available
# ...

# 只看 JIT 相关
bpftool feature probe | grep jit

# 只看 map 类型支持
bpftool feature probe | grep "MAP"

# 只看 prog 类型支持
bpftool feature probe | grep "PROGRAM"
```

### 9.2 探测特定功能

```bash
# 探测能否 unprivileged 使用 BPF
bpftool feature probe | grep "unprivileged"

# 输出：
# bpf() syscall for unprivileged users is enabled
# unprivileged_bpf_disabled: 0
# → 可以非 root 使用

# 如果 disabled = 1，需要：
echo 0 > /proc/sys/kernel/unprivileged_bpf_disabled

# 探测是否有 BPF_TYPE_MAP_OPS
bpftool feature probe | grep MAP_OPS

# 探测是否有 bpf_timer
bpftool feature probe | grep timer
# bpf_timer is available → kernel 5.15+

# 探测是否有 BPF_F_PRESERVE_ELEMS
bpftool feature probe | grep PRESERVE
```

### 9.3 实战：确认环境是否支持某功能

```bash
# 场景：你想用 BPF iter (bpf_iter_<type>)
# 确认内核支持

bpftool feature probe | grep "iter"

# 如果没有：
# Error: ... (bpf_iter support not available)

# 确认是否支持 struct_ops（内核 5.17+）
bpftool feature probe | grep "struct_ops"

# 快速检查脚本
#!/bin/bash
FEATURES=$(bpftool feature probe 2>&1)

check() {
    if echo "$FEATURES" | grep -q "$1"; then
        echo "✅ $1"
    else
        echo "❌ $1"
    fi
}

echo "=== BPF Feature Check ==="
check "JIT compiler is enabled"
check "bpf_trace_printk() is enabled"
check "BPF_TYPE_MAP_OPS support is available"
check "bpf_spin_lock() is available"
check "unprivileged_bpf_disabled: 0"
```

---

## 10. 实战：完整 BPF 性能分析流程

### 10.1 场景：分析 nginx 进程的网络延迟

```bash
# 目标：追踪 nginx 的每个连接延迟（accept → first byte）

# Step 1: 写 BPF 程序
cat > nginx_latency.bpf.c << 'EOF'
#include <linux/bpf.h>
#include <linux/skbuff.h>
#include <linux/tcp.h>
#include <linux/socket.h>
#include <net/sock.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_trace_printk.h>

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);  // pid
    __type(value, __u64); // accept timestamp
} accept_ts SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);  // sock pointer
    __type(value, __u64); // connect timestamp
} connect_ts SEC(".maps");

// trace accept syscall
SEC("tracepoint/syscalls/sys_enter_accept4")
int trace_accept(struct trace_event_raw_sys_enter *ctx) {
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    __u64 ts = bpf_ktime_get_ns();
    bpf_map_update_elem(&accept_ts, &pid, &ts, BPF_ANY);
    return 0;
}

// trace TCP 连接建立（sock_ops）
SEC("sock_ops")
int trace_tcp(struct bpf_sock_ops *ctx) {
    __u32 op = ctx->op;
    if (op == BPF_SOCK_OPS_TCP_CONNECT_CB) {
        __u64 ts = bpf_ktime_get_ns();
        __u32 key = (__u32)(ctx->socket_id);
        bpf_map_update_elem(&connect_ts, &key, &ts, BPF_ANY);
    }
    if (op == BPF_SOCK_OPS_TCP_ESTABLISHED_CB) {
        __u64 ts = bpf_ktime_get_ns();
        __u32 key = (__u32)(ctx->socket_id);
        __u64 *start = bpf_map_lookup_elem(&connect_ts, &key);
        if (start) {
            __u64 latency = ts - *start;
            bpf_printk("TCP established latency: %lld ns\n", latency);
        }
    }
    return 0;
}

char _license[] SEC("license") = "GPL";
EOF

# Step 2: 编译
clang -target bpf -O2 -g -c nginx_latency.bpf.c -o nginx_latency.bpf.o

# Step 3: 加载
bpftool prog load nginx_latency.bpf.o /sys/fs/bpf/nginx_latency \
    map name accept_ts pinned /sys/fs/bpf/accept_ts \
    map name connect_ts pinned /sys/fs/bpf/connect_ts

# Step 4: attach sock_ops（需要 cgroup）
# 创建 cgroup
mkdir -p /sys/fs/bpf/nginx_cgroup
mount -t cgroup2 none /sys/fs/bpf/nginx_cgroup

# attach program 到 cgroup
CGROUP_ID=$(bpftool cgroup show /sys/fs/bpf/nginx_cgroup --json | jq '.[0].id')
PROG_ID=$(bpftool prog show name trace_tcp --json | jq '.[0].id')
bpftool cgroup attach /sys/fs/bpf/nginx_cgroup sock_ops id $PROG_ID

# attach tracepoint
TP_ID=$(bpftool prog show name trace_accept --json | jq '.[0].id')
TP_PATH=$(ls /sys/kernel/debug/tracing/events/syscalls/sys_enter_accept4/id)
bpftool trace attach tracepoint_id $TP_PATH id $TP_ID

# Step 5: 启动 nginx 并观察
nginx
sleep 2
curl localhost:80
curl localhost:80
curl localhost:80

# Step 6: 查看 bpf_trace_pipe
cat /sys/kernel/debug/tracing/trace_pipe | grep established

# 输出：
# nginx-123-... [003] ...  TCP established latency: 1234567 ns
# nginx-124-... [003] ...  TCP established latency: 987654 ns
# → 第一个连接的延迟 1.2ms，第二个 1ms

# Step 7: 查看 map 数据
bpftool map dump id $(bpftool map show name connect_ts --json | jq '.[0].id')
```

### 10.2 场景：排查哪个内核函数被 kprobe 命中最多

```bash
# 场景：想知道系统中哪些 kprobe 被调用最频繁

# Step 1: 用 BCC 的 funccount（BCC 自带）
funccount 'vfs_*' 2>/dev/null &
# vfs_read, vfs_write 等被调用次数统计

# 用 bpftool 查看 BCC 加载的程序：
bpftool prog show | grep funccount
# 150: kprobe  name funccount_vfs_read  tag=...

# Step 2: 直接用 bpftool 找 kprobe
bpftool prog show | grep kprobe | head -20

# Step 3: 找特定模块的 kprobe
bpftool prog show | grep -E "blk_|ext4_|xfs_|tcp_"

# Step 4: 看 kprobe 的执行统计（需要 kernel 5.8+ bpf_stats）
# 启用 bpf stats
echo 1 > /proc/sys/kernel/bpf_stats_enabled

# 查看每个 program 的 run_time_ns + run_cnt
bpftool prog show --json | jq '.[] | {name, run_cnt, run_time_ns}'

# 按 run_cnt 排序
bpftool prog show --json | jq '.[] | select(.run_cnt > 0) | {name, run_cnt, run_time_ns}' \
    | sort | head -20
```

### 10.3 场景：bpftrace + bpftool 组合排查

```bash
# 场景：bpftrace 快速定位 + bpftool 深入分析

# Step 1: bpftrace 快速扫描（不需要写 C）
# 找系统中最慢的系统调用
bpftrace -e '
    tracepoint:raw_syscalls:sys_enter {
        @start[pid] = nsecs;
    }
    tracepoint:raw_syscalls:sys_exit {
        $ns = @start[pid];
        if ($ns > 0) {
            $lat = (nsecs - $ns) / 1000; // us
            @["us", comm, pid] = hist($lat);
            delete(@start[pid]);
        }
    }
' &
# 按延迟分布统计

# Step 2: 找到慢系统调用后，用 bpftool 深入看
# 假设发现某进程调用 openat 很慢
bpftool prog show | grep sys_enter_openat

# Step 3: dump 该 program 的字节码（分析逻辑）
bpftool prog dump xlated id $(bpftool prog show name trace_openat --json | jq '.[0].id') with btf

# Step 4: 查看该 program 引用的 map
bpftool prog show name trace_openat --json | jq '.[0].map_ids'
MAP_ID=$(bpftool prog show name trace_openat --json | jq '.[0].map_ids[0]')

# Step 5: dump map 数据
bpftool map dump id $MAP_ID | head -30
```

---

## 11. 常用诊断脚本

### 11.1 系统 BPF 快照

```bash
#!/bin/bash
# bpf_snapshot.sh — 完整 BPF 系统快照

OUT=/tmp/bpf_$(hostname)_$(date +%Y%m%d_%H%M%S)
mkdir -p $OUT

echo "[$(date)] Bpf Snapshot: $OUT"

# 1. 所有 program
echo "=== Programs ==="
bpftool prog show > $OUT/progs.txt
bpftool prog show --json > $OUT/progs.json

# 2. 所有 map
echo "=== Maps ==="
bpftool map show > $OUT/maps.txt
bpftool map show --json > $OUT/maps.json

# 3. 所有 link
echo "=== Links ==="
bpftool link show > $OUT/links.txt
bpftool link show --json > $OUT/links.json

# 4. 网络 BPF
echo "=== Network BPF ==="
bpftool net > $OUT/net.txt

# 5. Feature probe
echo "=== Features ==="
bpftool feature probe > $OUT/features.txt

# 6. BTF
echo "=== BTF ==="
bpftool btf show > $OUT/btf.txt

# 7. 所有 pinned map 的内容
echo "=== Map Contents ==="
for map in $(ls /sys/fs/bpf/ 2>/dev/null); do
    if [ -f "/sys/fs/bpf/$map" ]; then
        echo "--- $map ---" >> $OUT/map_contents.txt
        bpftool map dump pinned /sys/fs/bpf/$map >> $OUT/map_contents.txt 2>&1
    fi
done

# 8. 统计
echo ""
echo "=== Summary ==="
echo "Programs: $(bpftool prog show | wc -l)"
echo "Maps: $(bpftool map show | wc -l)"
echo "Links: $(bpftool link show | wc -l)"
echo "Pinned maps: $(ls /sys/fs/bpf/ | wc -l)"

echo "Snapshot saved to: $OUT"
ls -lh $OUT
```

### 11.2 查找问题 BPF program

```bash
#!/bin/bash
# find_bpf_issues.sh — 找常见 BPF 问题

echo "=== BPF 问题排查 ==="

echo ""
echo "[1] 占用 memlock 最多的 program"
bpftool prog show --json | jq -r '.[] | "\(.memlock_rss // 0) \(.id) \(.name)"' | \
    sort -rn | head -10 | while read size id name; do
    echo "  memlock=${size}B id=${id} name=${name}"
done

echo ""
echo "[2] 没有 JIT 的 program"
bpftool prog show --json | jq -r '.[] | select(.jited == "0B") | "id=\(.id) type=\(.type) name=\(.name)"'

echo ""
echo "[3] 引用了已删除 map 的 program（orphan program）"
bpftool prog show --json | jq -r '.[] | select(.map_ids | length > 0) as $p |
    . as $p | '"'"'[]'"'"' |
    . as $refs | '"'"'[]'"'"' |
    $refs' 2>/dev/null
# 注：简化版，实际情况需要更复杂的 jq

echo ""
echo "[4] 长时间运行的 program（加载后从未卸载）"
bpftool prog show --json | jq -r '.[] | "\(.loaded_at) \(.name)"' | sort

echo ""
echo "[5] xlated vs jited 差异大的 program（可能有问题）"
bpftool prog show --json | jq -r '.[] |
    select(.jited_size != null) |
    select(.xlated_size != null) |
    select((.jited_size | tonumber) < (.xlated_size | tonumber) * 0.3) |
    "jited=\(.jited_size) xlated=\(.xlated_size) ratio=\($ratio) name=\(.name)"'
```

---

## 12. 小结

```
bpftool 核心命令速查：

prog show      — 有哪些 program 在跑
prog dump      — 字节码/JIT 代码
prog load      — 从 .o 加载程序
prog attach    — 挂载到 kprobe/tracepoint/cgroup
prog detach    — 卸载

map show       — 有哪些 map
map dump       — 看所有条目
map lookup     — 读单个 key
map update     — 写 key-value
map delete     — 删除 key
map freeze     — 禁止用户态写入
map create     — 单独创建 map

link show      — program 挂在哪个 hook
link detach    — 精确卸载

btf show/dump  — 内核类型信息（struct offset）

net show/attach/detach — XDP/tc 的附加状态

feature probe  — 内核 BPF 能力探测

实战三步曲：
  1. bpftool prog show → 系统里有什么
  2. bpftool map dump → 数据长什么样
  3. bpftool prog dump → 程序在干什么
```

---

## 延伸阅读

- `man bpftool` — 完整手册
- bpftool 源码: `tools/bpf/bpftool/` (内核源码)
- BCC 工具集: `tools/bcc/` — 300+ 预制 BPF 工具
- bpftrace: `tools/bpf/bpftrace/` — 一行脚本 BPF
- BPF CO-RE: `Documentation/bpf/bpf_development_QA.rst`
- 《BPF Performance Tools》— 布劳恩著（系统性 BPF 工具书）
- https://ebpf.io/ — eBPF 生态总览
