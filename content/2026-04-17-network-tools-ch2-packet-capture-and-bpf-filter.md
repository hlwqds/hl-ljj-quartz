---
title: 网络工具深度系列 Ch2：流量捕获与 BPF 过滤
date: 2026-04-17 11:00:00
tags: [Network, tcpdump, BPF, Packet Capture, Wireshark, Traffic Analysis]
description: 深入讲解 tcpdump BPF 语法、高级过滤表达式、内核旁路（afpacket）、抓包文件分析（ Brim/Wireshark），以及常见坑与优化技巧。
---

# 网络工具深度系列 Ch2：流量捕获与 BPF 过滤

## 1. tcpdump 的本质

tcpdump 做的事：

```
用户输入 BPF 表达式
       ↓
tcpdump 调用 pcap_compile() 编译成 BPF 字节码
       ↓
调用 pcap_setfilter() 通过 setsockopt(SO_ATTACH_FILTER) 注入内核
       ↓
内核 netfilter/网卡驱动层按 BPF 过滤，符合条件的包才 copy 到用户态
       ↓
用户态收到原始包（链路层帧），按格式解析并打印
```

> [!note]
> BPF filter 运行在内核，收包阶段就已经过滤掉了，不需要送到用户态再过滤。这是 tcpdump 高效的根本原因。

---

## 2. BPF 过滤表达式详解

### 2.1 基本结构

```
tcpdump [options] <expression>

expression = qualifier + id + optional modifiers

qualifier = type | dir | proto

type:  host | net | port | portrange
dir:  src | dst | src or dst | src and dst
proto:  tcp | udp | icmp | ip | ip6 | arp | ...
```

### 2.2 四元组过滤（最常用）

```bash
# 精确 5-tuple 过滤
tcpdump host 10.0.0.1 and port 443

# 精确 4-tuple（源 IP + 源 port + 目标 IP + 目标 port）
tcpdump src 10.0.0.50 and src port 8080 and dst 10.0.0.1 and dst port 443

# 范围 port（适用于负载均衡场景）
tcpdump portrange 8000-9000

# 网络段
tcpdump net 10.0.0.0/24
tcpdump net 10.0.0.0 mask 255.255.255.0
```

### 2.3 协议层过滤

```bash
# 只抓 TCP
tcpdump tcp

# 只抓 UDP（DNS/QUIC/NTP）
tcpdump udp

# 只抓 ICMP（ping 排查）
tcpdump icmp

# 只抓 ICMP echo request（ping）
tcpdump 'icmp[icmptype] == 8'

# 只抓 ICMP echo reply（ping response）
tcpdump 'icmp[icmptype] == 0'

# 只抓 IP 头 TTL 超过 64 的（traceroute 最后一跳）
tcpdump 'ip[8] > 64'
# ip[8] 是 TTL 字段

# 只抓 IP 分片
tcpdump 'ip[6:2] & 0x3fff != 0'
# ip[6:2] 是 fragment offset 字段
```

### 2.4 TCP 特定过滤

```bash
# 只抓 SYN（连接建立）
tcpdump 'tcp[tcpflags] == tcp-syn'

# 只抓 SYN-ACK（服务器响应）
tcpdump 'tcp[tcpflags] == tcp-syn-ack'

# 只抓 RST（重置连接）
tcpdump 'tcp[tcpflags] == tcp-rst'

# 只抓 FIN（优雅关闭）
tcpdump 'tcp[tcpflags] == tcp-fin'

# 排除 SYN/FIN/RST，只抓数据帧
tcpdump 'tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) == 0'

# 只抓 ACK（不含数据）
tcpdump 'tcp[12] = 0x10'
# tcp[12] 是 data offset，flags 在 byte 13，ACK=0x10

# 只抓带 payload 的 TCP 包（data offset > 5）
tcpdump 'tcp[13] & 0x08 != 0'
# 或更精确：tcp[0:2] & 0x3fff != 0 看 fragment offset
```

### 2.5 Payload 内容过滤（深度包检查）

```bash
# 抓 HTTP GET 请求
tcpdump 'tcp[((tcp[12:1] & 0xf0) >> 2):2] = 0x4745'
# 0x4745 = 'GE'，HTTP GET 前两个字节

# 抓 HTTP POST 请求
tcpdump 'tcp[((tcp[12:1] & 0xf0) >> 2):2] = 0x504f'
# 0x504f = 'PO'，HTTP POST

# 更实用的方法：端口过滤 + 字符串匹配
tcpdump -i eth0 'port 80 and tcp[((tcp[12:1] & 0xf0) >> 2):4] = 0x47455420'
# 0x47455420 = 'GET '（4字节，更精确）

# 抓含有 "login" 的包
tcpdump -i eth0 'port 80 and tcp[((tcp[12:1] & 0xf0) >> 2):5] = 0x6c6f67696e'
# 0x6c6f67696e = 'login'

# DNS 查询（UDP port 53，问答部分搜索 "example"）
tcpdump -i eth0 'udp port 53 and (udp[10:2] & 0x0120) = 0x0100'
# DNS query: qr=0, opcode=0
```

> [!warning]
> payload 内容过滤需要在用户态做完整 TCP 重组（因为 TCP 是流协议，单包可能不含完整应用数据）。`tcp[((tcp[12:1] & 0xf0) >> 2):N]` 只能看当前包的数据偏移，不能跨包匹配。复杂内容过滤建议用 Wireshark。

### 2.6 组合表达式

```bash
# 与或非运算
tcpdump host 10.0.0.1 and port 443
tcpdump host 10.0.0.1 and not port 22
tcpdump \(host 10.0.0.1 or host 10.0.0.2\) and port 443

# 排除内网流量（快速找外部攻击）
tcpdump not net 192.168.0.0/16 and not net 10.0.0.0/8 and not net 172.16.0.0/12

# 排除 ARP/DHCP（减少噪音）
tcpdump 'not arp and not (udp port 67 or udp port 68)'

# 排除 keepalive（常见噪音）
tcpdump 'tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) == 0 and tcp[((tcp[12:1] & 0xf0) >> 2):2] != 0x0101'
# 排除带 \x01\x01 (prob/ack) 的空包
```

---

## 3. tcpdump 高级选项

### 3.1 读取与保存

```bash
# 抓包保存（-w 写文件，-C 控制文件大小）
tcpdump -i eth0 -w /tmp/capture.pcap -C 100
# -C 100: 每个文件最大 100MB，超出后创建新文件 (capture.pcap0, .pcap1...)
# 配合 -W 限制文件总数（轮转）

# 抓包并实时查看（-l 输出行缓冲，tail -f 实时跟踪）
tcpdump -i eth0 -l | tail -f

# 同时显示和保存（-s 0 抓完整包，-nn 不做 DNS/port 解析）
tcpdump -i eth0 -nn -s 0 -w /tmp/capture.pcap

# 读文件分析（-r 读，-v -vv -vvv 控制详细程度）
tcpdump -r /tmp/capture.pcap 'tcp[tcpflags] & tcp-rst != 0'
tcpdump -r /tmp/capture.pcap -vv 'port 443' | less

# 读文件并导出特定流（editcap / tcpdump 组合）
tcpdump -r large.pcap 'host 10.0.0.1' -w small.pcap
```

### 3.2 采样与速率控制

```bash
# 每 N 个包抽 1 个（降低高流量场景的开销）
tcpdump -i eth0 -c 100 'port 443'
# 只抓前 100 个包，然后退出

# 每 100ms 抽 1 个包（精确采样）
tcpdump -i eth0 -D "every 100"

# 或者用 pf_ring（需要额外驱动）
tcpdump -i eth0 -i pf_ring:every=100

# 限制每个包抓的字节数（-s snaplen，省空间但丢数据）
tcpdump -i eth0 -s 96
# 只抓前 96 字节（够看 header，但丢 payload）
# -s 0 或 -s 65535：抓完整包
```

### 3.3 环转文件（持续抓包）

```bash
# 持续抓包，文件每 100MB 轮转，保留最近 10 个文件
tcpdump -i eth0 -W 10 -C 100 -w /tmp/capture_%Y%m%d_%H%M%s.pcap 'port 443'

# 参数解释：
# -W 10: 最多 10 个文件（超出后删除最早的）
# -C 100: 每个文件 100MB
# %Y%m%d_%H%M%s: 时间戳命名（避免覆盖）

# 分析时合并多个文件
mergecap -w merged.pcap capture_*.pcap

# 时间范围过滤（用 tcpdump 本身）
tcpdump -r merged.pcap 'tcp and port 443 and time 2026-04-17 10:00:00 <= 2026-04-17 11:00:00'
```

---

## 4. 内核旁路：AF_PACKET 与 tpacket_v3

### 4.1 pcap 的局限

```
传统 pcap：
  NIC → kernel driver → netfilter (XDP/iptables) → TCP/IP stack
            ↓
       pcap 通过 raw socket 复制一份到用户态

问题：
  1. 每个包都要经过完整内核路径（即使不 filtered）
  2. copy_to_user 开销（内存拷贝）
  3. 中断处理 + 软中断（context switch）

现代高速网卡（10Gbps+）场景下，pcap 只能跑到 2-3Gbps
  → 丢包率 > 50%
```

### 4.2 AF_PACKET：零拷贝旁路

```bash
# 启动 afpacket（通过 tcpdump -i 使用）
tcpdump -i eth0 --packet-fanout

# AF_PACKET + tpacket_v3（Linux 3.2+）：
# 通过 mmap 共享 kernel buffer，用户态直接读
# 零拷贝，延迟极低

# docker 里的 afpacket 旁路模式
docker run --cap-add=NET_ADMIN --network=host nicolaka/tcpdump -i eth0
# 或用 --device 映射物理网卡到容器
```

### 4.3 tpacket_v3 vs tpacket_v2

| 特性 | tpacket_v2 | tpacket_v3 |
|------|------------|------------|
| 内存布局 | 环形缓冲（每个 ring slot 大小固定） | 灵活大小的块（block） |
| 延时 | 中等（等待固定大小块） | 低（单个包即可上圈） |
| 内存效率 | 低（slot 必须 >= max packet size） | 高（block 按需分配） |
| 用途 | 通用抓包 | 超高吞吐（100Gbps+） |

### 4.4 XDP vs AF_PACKET

```
XDP：网络驱动的最早期（在 skb 分配之前），可丢弃包
     优点：最早机会过滤，最高性能
     缺点：只能丢弃/转发，不能完整分析（内存受限）
     
AF_PACKET：在 TCP/IP stack 之前（kernel 5.8+ 支持 tpacket_v3）
           优点：零拷贝，完整包，高性能
           缺点：仍需 softirq，无法完全绕过 kernel

最佳实践：
  高吞吐场景（100Gbps+）→ XDP + AF_PACKET 组合
  普通场景 → AF_PACKET (tpacket_v3)
  低速场景 → pcap（兼容性好）
```

---

## 5. tcpdump 常见坑

### 5.1 网卡名混淆

```bash
# -i 指定网卡，但 lo、eth0、any 的行为不同
tcpdump -i eth0   # 只抓物理网卡 eth0
tcpdump -i lo     # 只抓 lo
tcpdump -i any    # 抓所有网卡（但 lo 可能会看到回环流量）

# any 的坑：会抓到 kernel 内部的 traffic
# 排除 lo：
tcpdump -i any 'not host 127.0.0.1'

# 多网卡时明确指定，不要用 any
tcpdump -i eth0 'port 443'
```

### 5.2 元数据泄漏（采样偏差）

```bash
# tcpdump 本身产生的流量可能被 tcpdump 抓到
# 比如 tcpdump 显示 "no banner" 时发了 DNS 查询

# 避免自抓：排除 tcpdump 进程自己的流量
# 方法 1：抓包时加进程过滤（但无法过滤 kernel 发的 ARP）
tcpdump 'not (tcp[((tcp[12:1] & 0xf0) >> 2):2] = 0x0018)'
# 排除带有 ACK+PSH 的包（tcpdump 的探针包）

# 方法 2：BPF 里排除本机 IP
tcpdump 'not (src host 10.0.0.50 and dst host 10.0.0.50)'

# 方法 3：用 -Q direction 指定进/出
tcpdump -i eth0 -Q in 'port 443'
# 只抓入方向（不抓出方向，减少自抓）
```

### 5.3 MTU 与 snaplen 丢失数据

```bash
# 默认 snaplen = 96 字节（够用，但丢 payload）
tcpdump -s 0   # 抓完整包

# MTU 问题：大包被分片
tcpdump 'ip[6:2] & 0x1fff != 0'   # 看分片包
# 需要重组才能看到完整内容
# tcpdump 本身不支持重组，但 tshark 支持
tshark -r /tmp/capture.pcap -Y 'http' -T fields -e http.request.uri
```

### 5.4 时间戳与时区问题

```bash
# tcpdump 默认用本地时间
# 写文件时用 -tttt 显示高精度时间
tcpdump -r /tmp/capture.pcap -tttt | head

# UTC 时间（跨国分析时）
tcpdump -r /tmp/capture.pcap -ttttu | head

# Wireshark 里时区不对：
# Edit → Preferences → Appearance → Time → 显示 UTC
# 或用 editcap 改时间戳
editcap -T utc /tmp/capture.pcap /tmp/utc.pcap
```

### 5.5 VLAN 标签导致 filter 失效

```bash
# 过滤 port 443 但没抓到？可能网卡有 VLAN
# 802.1Q VLAN tag 会在 ethernet header 里加 4 字节

# 正常包：ethertype = 0x0800 (IPv4)
# VLAN 包：ethertype = 0x8100 (VLAN)，后面跟 4 字节 VLAN tag，然后才是 0x0800

# 过滤 VLAN 后的 port 443：
tcpdump -i eth0 'port 443 or vlan 100'
# 或明确加 VLAN
tcpdump -i eth0 'vlan and port 443'

# 如果网卡配置了 VLAN，ethertype 会变
# 检查：tcpdump -e（显示链路层 header）

# 802.1Q double tagging (Q-in-Q)：再加 4 字节
# tcpdump 的 'vlan' 只能处理单层，Q-in-Q 需要：
tcpdump 'ether[12:2] = 0x8100'
```

---

## 6. BPF 进阶：直接编写 BPF 程序

### 6.1 tcpdump -d 看编译结果

```bash
# -d：显示编译后的 BPF 字节码（看不懂，但可以验证 filter 是否被优化）
tcpdump -d 'tcp and port 443 and host 10.0.0.1'
# (000) ldh      [12]              ; load ether type
# (001) jeq      #0x86dd           ; ipv6?
# (002) jeq      #0x800            ; ipv4?
# ...

# -dd：显示 C 格式的 BPF 程序（可以拿去写代码）
tcpdump -dd 'tcp and port 443'
# { 0x28, 0x0, 0, 0x0000000c },
# { 0x15, 0, 1, 0x00000835 },
# ...

# -ddd：显示带注释的字节码（人类可读）
tcpdump -ddd 'tcp and port 443'
```

### 6.2 直接注入 BPF（通过 setsockopt）

```c
// 手动构造 BPF 程序并 attach 到 raw socket
#include <linux/bpf.h>
#include <sys/socket.h>

struct sock_fprog prog = {
    .len = 3,
    .filter = (struct sock_filter[]) {
        { BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 0), 0, 0, 0 },  // 加载 EtherType
        { BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0x0800, 0, 1), 0, 0, 0 },  // IPv4
        { BPF_STMT(BPF_RET | BPF_K, 0xFFFFFFFF), 0, 0, 0 }  // 保留
    }
};

int sock = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
setsockopt(sock, SOL_SOCKET, SO_ATTACH_FILTER, &prog, sizeof(prog));
```

### 6.3 seccomp 限制 BPF

```
安全场景：容器内的进程不能随意 attach BPF
→ seccomp 限制能调用的 BPF syscall

典型策略：
  "syscalls": [
    { "name": "bpf", "action": "SCMP_ACT_ERRNO" }
  ]
  → 进程无法调用 bpf()，只能通过预先加载的 BPF 程序被动抓包
```

---

## 7. 抓包文件分析工具链

### 7.1 命令行工具

```bash
# tshark：命令行 Wireshark，功能齐全
tshark -r /tmp/capture.pcap -Y 'tcp.port == 443' -T fields -e ip.src -e ip.dst -e tcp.srcport -e tcp.dstport -e http.request.uri

# 用 tshark 导出 HTTP 请求的 CSV
tshark -r /tmp/capture.pcap -Y 'http' -T fields -e frame.time -e ip.src -e http.host -e http.request.uri > http_requests.csv

# capinfos：看文件基本信息（编码格式、时间范围、包数、大小）
capinfos /tmp/capture.pcap

# editcap：编辑/转换/切割抓包文件
editcap -r large.pcap 100-200 small.pcap  # 提取第 100-200 个包
editcap -A "2026-04-17 10:00:00" -B "2026-04-17 11:00:00" large.pcap window.pcap
editcap -t 3600 large.pcap shifted.pcap  # 时间戳偏移 1 小时

# mergecap：合并多个文件
mergecap -w merged.pcap file1.pcap file2.pcap file3.pcap

# split：将大文件按时间均匀分割
tcpdump -r large.pcap -C 100 -w split_file  # 每 100MB 一个
```

### 7.2 高速抓包格式：pcapng

```
pcapng > pcap：
  - 支持多接口同步抓包（每个接口一个 Section）
  - 支持 name resolution (DNS cache, MAC vendor)
  - 支持 packet comment（注释）
  - 支持 enhanced packet block (EPB) 带精确时间戳

Wireshark 默认格式
Brim、Zeek 也支持
```

### 7.3 Zeek：网络流量安全分析

```bash
# Zeek 不是抓包工具，是分析工具
# 输入：pcap 文件
# 输出：结构化日志（conn.log, http.log, dns.log, ssl.log...）

# 基础用法
zeek -r /tmp/capture.pcap

# 输出目录
ls *.log
# conn.log：每个连接一条记录（5-tuple + 持续时间 + 字节数）
# http.log：每个 HTTP 请求一条
# dns.log：每个 DNS 查询一条
# ssl.log：TLS 握手信息

# 实时监控
zeek -i eth0

# 自定义脚本（Zeek script）
zeek -r /tmp/capture.pcap -s /opt/zeek-scripts/http-analysis.bro
```

### 7.4 Brim：快速搜索大 pcap

```
Brim = Wireshark 前端 + Zeek + 全文搜索
  - Electron 应用，跨平台
  - 支持 Brim query language (zql)：类似 SQL
  - 可以直接搜索 pcap 里的 payload 内容

常用 zql：
  _path=conn | put src_ip=id.orig_h | filter conn_state == "ESTABLISHED"
  _path=http | search "password"
  _path=dns | filter answers contains "10.0.0"
```

### 7.5 流量回放工具

```bash
# tcpreplay：把 pcap 文件重放到网络
tcpreplay --intf1=eth0 /tmp/capture.pcap

# 加速/减速回放（压测场景）
tcpreplay --multiplier=2.0 --intf1=eth0 /tmp/capture.pcap
# 2x 速度

# 只回放特定流（用 tcpflow 提取）
tcpflow -r /tmp/capture.pcap -o /tmp/flows
# 提取出单独的流文件，然后用 tcpreplay 逐一回放

# 高性能回放：netsniff-ng
netsniff-ng -i /tmp/capture.pcap --totals -d eth0
# netsniff-ng 是 0 拷贝，性能比 tcpreplay 高 3-5x
```

---

## 8. 实战案例

### 8.1 案例：抓取 DNS 查询并分析延迟

```bash
# 只抓 DNS（UDP 53），显示详细信息
tcpdump -i eth0 -nn -vv 'udp port 53'

# 输出：
# 10.0.0.50.54321 > 8.8.8.8.53:  [bad udp cksum]  25833+ A? example.com.
#   0x0000:  4500 0029  ...  (IP header)
#   0x0014:  ... (DNS query)

# 分析 DNS 响应时间（看 DNS server 到我们之间）
# 用 -ttt 看毫秒时间戳
tcpdump -i eth0 -ttt 'udp port 53' | grep example.com

# 统计 DNS 响应时间分布
tcpdump -r /tmp/dns.pcap 'udp port 53' | awk '{print $3}' | cut -d. -f1 | sort -n | uniq -c
```

### 8.2 案例：分析 HTTP 慢请求

```bash
# 抓完整 HTTP 流量（port 80，不限 snaplen）
tcpdump -i eth0 -nn -s 0 'port 80 and tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) == 0'

# 找响应时间超过 1s 的请求：
tshark -r /tmp/http.pcap -Y 'http.response.time > 1000' -T fields -e ip.src -e http.host -e http.request.uri -e http.response.time

# 用 httpry（专用 HTTP 日志工具）
httpry -i eth0 -r /tmp/http.log
# 输出：timestamp src_ip dst_ip method host uri status latency

# 分析 slow query（看哪些 URL 响应时间 > 500ms）
awk '$NF > 0.5 {print}' /tmp/http.log | sort -k7 -nr | head -20
```

### 8.3 案例：QUIC 抓包

```bash
# QUIC 使用 UDP，所以直接过滤 UDP port
tcpdump -i eth0 -nn 'udp port 443'

# QUIC 包特征：UDP 头部之后是 QUIC header
# QUIC header 包含：version, connection ID, packet number, crypto frames

# 导出给 Wireshark 分析（Wireshark 能解析 QUIC 0-RTT）
# 但 QUIC 的加密标签导致内容不可见（Wireshark 只能看到 header）
# 需要 session key 才能解密（Chrome 支持导出 SSLKEYLOGFILE）
export SSLKEYLOGFILE=/tmp/quic_keys.log
chrome --quic-privacy-mode=false

# 然后 Wireshark 加载 keys：
# Edit → Preferences → Protocols → TLS → (Pre)-Master-Secret log filename
# /tmp/quic_keys.log

# 分析 QUIC 拥塞控制：
# Wireshark → Statistics → TCP Stream Graphs → Time-Sequence (tcptrace)
```

---

## 9. 小结

```
tcpdump 核心：
  BPF filter → 内核过滤 → 用户态解析
  过滤器写对了，效率差 10-100x

BPF 表达式优先级：
  port > host > tcp/udp > tcpflags > payload

高速抓包：
  10Gbps 以下：AF_PACKET + tpacket_v3
  100Gbps+：XDP + AF_PACKET 组合

分析工具链：
  tcpdump 快速定位 → tshark 结构化提取 → Brim 全文搜索
  Zeek 生成日志 → 时间分析
  tcpreplay/tcprewrite → 流量回放

常见坑：
  - snaplen 默认 96，丢 payload
  - any 会抓到 lo 自抓
  - VLAN 会导致 ethertype 后移
  - tcpdump 自己的 probe 流量可能自抓
```

---

## 延伸阅读

- `man pcap-filter` — BPF 语法完整参考
- `man tcpdump` — tcpdump 选项
- `man pcap` — libpcap API
- Wireshark Wiki: https://wiki.wireshark.org/
- Zeek Document: https://docs.zeek.org/
- Brim (ZQL): https://github.com/brimsec/brim/wiki/ZQL-Reference