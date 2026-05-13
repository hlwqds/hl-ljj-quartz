---
title: 网络工具深度系列 Ch1：套接字枚举与连接状态
date: 2026-04-17 10:00:00
tags: [Network, Linux, ss, netstat, socket, TCP, UDP]
description: 深入讲解 ss、netstat 的实现原理，以及 TCP/UDP socket 状态机、inode 反查、namespace 隔离等实用技巧。
---

# 网络工具深度系列 Ch1：套接字枚举与连接状态

## 1. 从 socket 到连接状态

Linux 网络工具的本质，是对 **socket inode 的读取和解释**。每个 TCP/UDP 套接字在内核中对应一个 `struct sock`，在 `/proc/net/` 下以文本形式暴露。我们看到的 `ss -tunapl` 输出，就是对这些文件的解析和聚合。

```
/proc/net/tcp         → IPv4 TCP socket 表
/proc/net/tcp6        → IPv6 TCP socket 表
/proc/net/udp         → IPv4 UDP socket 表
/proc/net/udp6        → IPv6 UDP socket 表
/proc/net/unix        → Unix Domain Socket 表
/proc/net/raw         → raw socket 表
/proc/net/dev          → NIC 收发统计
/proc/net/snmp         → IP/ICMP/TCP/UDP 统计
/proc/net/netstat      → 扩展网络统计
```

> [!note]
> `netstat` 和 `ss` 本质上读取的是同一批 `/proc/net/` 文件，但解析效率和功能扩展程度不同。

---

## 2. netstat vs ss：原理对比

### 2.1 netstat 的问题

```
netstat -tunapl

问题 1：调用链长
  netstat → /proc/net/tcp → 解析文本 
           → 额外调用 getpidcon() 查进程上下文（SELinux）
           → 额外调用 resolv() 做反向 DNS 解析
           → 额外查询 /proc/<pid>/fd/ 获取 socket inode
           → 每条记录都是一次系统开销

问题 2：无法按需过滤
  netstat 输出全量后，用户自己 grep
  → TIME_WAIT 有 10000 条？先全部读出来再过滤

问题 3：无法获取 socket 内存信息
  netstat 的 struct 就是文本解析，socket 的 rmem/wmem 拿不到
```

### 2.2 ss 的优势

```
ss -tunapl

优势 1：直接调用 netlink（通过 inet_diag 协议）
  ss → netlink socket → 发送 AF_INET/AF_INET6 + SOCK_DIAG 信息
       → 内核返回 struct sock_diag 信息（一次性）
       → 直接解析二进制，不用读 /proc/net/tcp 文本

优势 2：按需查询（BPF 过滤）
  ss state established 'sport = :443'
  → 内核帮过滤，ss 只拿结果，不做后处理

优势 3：扩展信息丰富
  -tunapl 的 'p' 打印进程，'e' 打印内存/队列信息
  直接调用 getsockopt(SO_ATTACH_FILTER) 拿扩展信息
```

### 2.3 实测对比

```bash
# 制造大量 TIME_WAIT 连接（模拟高并发场景）
for i in {1..5000}; do 
    nc -z -w1 8.8.8.8 53 &
done
wait

# netstat（慢）
time netstat -tan | grep TIME_WAIT | wc -l
# real    0m0.817s

# ss（快）
time ss -tan state time-wait | wc -l
# real    0m0.041s

# 差距：20x（连接数越多差距越大）
```

| 指标 | netstat | ss |
|------|---------|-----|
| 底层协议 | /proc 文本解析 | netlink + inet_diag |
| 5000 TIME_WAIT 耗时 | ~800ms | ~40ms |
| 过滤能力 | 用户态过滤 | 内核 BPF 过滤 |
| 进程信息 | getpidcon() 逐条查 | inode → fd → pid 一次性 |
| 内存/队列信息 | ❌ 无 | ✅ getsockopt |

---

## 3. TCP socket 状态机

### 3.1 状态分类

```
┌────────────┐    ┌─────────────┐    ┌────────────┐    ┌────────────┐
│  CLOSED    │───▶│  LISTEN     │───▶│  SYN_RCVD  │───▶│ ESTABLISHED│
└────────────┘    └─────────────┘    └────────────┘    └────────────┘
     ▲                  ▲                  ▲                 │
     │                  │                  │                 │
     └──────────────────┴──────────────────┴─────────────────┘
                          (发送 RST 或超时)

ESTABLISHED ──────────────────────────────▶ CLOSE_WAIT
     │                                           │
     ▼                                           │
  FIN_WAIT_1 ───▶ FIN_WAIT_2                  LAST_ACK
     │                                           │
     ▼                                           ▼
 CLOSING      ─────▶ TIME_WAIT ◀───────────── CLOSING
     │
     └──────────────────────────────────────────────┘
                       (同时收到 FIN + ACK)
```

### 3.2 各状态含义

| 状态 | 含义 | 常见场景 |
|------|------|---------|
| `CLOSED` | 无连接 | 初始状态 |
| `LISTEN` | 服务端监听中 | `ss -lt` 看到的 |
| `SYN_SENT` | 客户端发了 SYN，等待 ACK | 连接建立中 |
| `SYN_RECV` | 服务端收到 SYN，发了 SYN+ACK | 三次握手中间 |
| `ESTABLISHED` | 连接建立，双方可传数据 | 正常通信 |
| `FIN_WAIT1` | 主动关闭，发了 FIN，等待对方 ACK | close() 后 |
| `FIN_WAIT2` | 收到对方 ACK，等待对方 FIN | 另一半已确认关闭 |
| `CLOSE_WAIT` | 被动关闭，收到 FIN 后 | 对端已关闭，本地还没 |
| `CLOSING` | 双方同时关闭 | 罕见 |
| `LAST_ACK` | 被动关闭，发了 FIN，等待最后 ACK | close() 后 |
| `TIME_WAIT` | 等待 2MSL，确保对方收到最后的 ACK | close() 后，2min |

### 3.3 TIME_WAIT 的作用

```
为什么要有 TIME_WAIT？

Client                          Server
  │                                │
  │─────────── FIN ────────────────▶│  Server: close()
  │◀──────────── ACK ───────────────│  Client: 收到 FIN，发 ACK
  │                                │
  │   如果这个 ACK 丢了？           │
  │   Server 不知道 Client 收到 FIN │
  │                                │
  │◀───────── (重传 FIN) ──────────│  Server: 等待 ACK，没等到
  │─────────── ACK ────────────────▶│  Client: 重传 ACK
  │                                │
  TIME_WAIT: 等 2MSL，确保上述场景完成
  MSL (Maximum Segment Lifetime) 通常 = 60s
  所以 TIME_WAIT 通常持续 120s

如果不用 TIME_WAIT：
  新连接可能收到旧连接的延迟包（seq 重叠）
  → 数据错乱
```

### 3.4 TIME_WAIT 调优

```bash
# 方法 1：开启重用（快速回收）
# /etc/sysctl.conf
net.ipv4.tcp_tw_reuse = 1

# 原理：新的 connect() 可以复用 TIME_WAIT 的 port（但仅限客户端）
# 内核会验证新连接的 4-tuple + timestamp 不会冲突

# 方法 2：调小 MSL（减少等待时间）
net.ipv4.tcp_fin_timeout = 30
# 改成 30s（默认 60s），TIME_WAIT 从 120s 变成 60s

# 方法 3：调大可用 port 范围（增加 source port 数量）
net.ipv4.ip_local_port_range = 1024 65535
# 默认 32768 61000，共 28237 个 port
# 高并发短连接场景下，port 可能耗尽

# 方法 4：socket 选项 SO_REUSEADDR
# 程序里 setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one))
# 允许 bind 已 TIME_WAIT 的 address:port

# 方法 5：使用更多 client IP（增加 source IP）
# 4-tuple: (src_ip, src_port, dst_ip, dst_port)
# src_ip 增加 → 连接数上限乘以 IP 数量
```

---

## 4. ss 高级用法

### 4.1 按状态过滤

```bash
# 看所有 ESTABLISHED 连接（最常用）
ss -tunapl state established

# 看所有监听端口
ss -tlnapl

# 看所有 TIME_WAIT（排查高并发问题）
ss -tan state time-wait

# 看所有 CLOSE_WAIT（可能有资源泄漏）
ss -tan state close-wait

# 看所有非 LISTEN 的连接数（快速统计并发数）
ss -s

# 复合过滤：ESTABLISHED 且目标端口是 443
ss -t state established 'dport = :443'

# 源端口过滤
ss -t state established 'sport = :8080'
```

### 4.2 按进程/文件描述符过滤

```bash
# 看某个进程的所有连接
ss -tunapl pid $(pidof nginx)

# 看某个 PID 的连接（更精确）
ss -tunapl process pid=12345

# 通过 inode 找进程（反向查）
ss -tunapl | grep 10.0.0.1:443
# 假设输出显示 inode=12345
ls -la /proc/*/fd/* 2>/dev/null | grep socket:\[12345\]
# 找到进程 PID

# 用 ls 找（更简洁）
lsof -i @10.0.0.1:443
```

### 4.3 扩展信息（-e, -i, -m）

```bash
# -e：显示详细 socket 信息（内存、队列）
ss -tunapl state established -e
# output:
# State      Recv-Q   Send-Q   Local Address:Port   Peer Address:Port
# ESTAB      0        0        10.0.0.50:65432      10.0.0.1:443
#           mem:(r0,w0,f0,t0)   skmem:(r0,t0,u0,w0,o0)

# -m：显示 socket 内存使用
ss -tunapl -m
# skmem: r4096,t0,u2048,w0,o0
# r = rmem（接收缓冲区）
# t = wmem（发送缓冲区，TCP 无）
# u = unkown
# w = wmem（TCP write buffer）
# o = oob（out-of-band）

# -i：显示 TCP 内部信息（retrans, cwnd, pacing）
ss -t state established -i
# output:
# ESTAB      0        0        10.0.0.50:65432      10.0.0.1:443
#         cubic rtt:0.5ms advmss:1448 pacing_rate 11.8Mbps
#         rcv_space:5832 rcv_space:2926
```

### 4.4 定时采样

```bash
# 持续监控，每秒打印一次
watch -n1 'ss -s'

# 每秒统计各状态数量
watch -n1 'ss -tan state time-wait | wc -l'

# 每 5 秒采样，写入文件（用于趋势分析）
while true; do
    echo "$(date +%s) $(ss -s)" >> /tmp/ss_stats.txt
    sleep 5
done

# 分析 TIME_WAIT 趋势（导入 gnuplot）
```

---

## 5. inode 反查：定位任意 socket 的进程

### 5.1 为什么需要 inode 反查

```
场景 1：netstat 显示大量 CLOSE_WAIT，但 netstat 没显示进程
  → 需要通过 inode 找到对应 PID

场景 2：某个连接泄漏（没 close），但不知道是哪个进程
  → 通过 inode 反查

场景 3：容器内 ss 看到的连接，想知道在宿主机哪个进程
  → namespace 问题，下文详述
```

### 5.2 方法 1：lsof

```bash
# 通过 port 找进程
lsof -i :443

# 通过 IP+Port 找
lsof -i @10.0.0.1:443

# 通过 inode 找
# 先拿到 inode
ss -tunapl | grep 10.0.0.1:443
# tcp   ESTAB   0   0   10.0.0.50:65432   10.0.0.1:443   users:(("nginx",pid=12345,fd=6))
# inode = 12345

# 然后
lsof | grep socket
# 或者
ls -la /proc/*/fd/* 2>/dev/null | grep socket:\[12345\]
```

### 5.3 方法 2：/proc/ 带 socket 链接

```bash
# /proc/<pid>/fd/ 里的 socket 链接格式
ls -la /proc/12345/fd/ | grep socket
# lr-x------ 1 nginx nginx 64 Apr 16 10:00 socket:[12345]
#                             ↑ inode 编号在 [] 里

# 批量找：所有进程 fd 里的 socket
for pid in /proc/[0-9]*; do
    for fd in $pid/fd/*; do
        link=$(readlink $fd 2>/dev/null)
        if [[ "$link" == "socket:["* ]]; then
            echo "PID=$(basename $pid) FD=$(basename $fd) INODE=${link//[![:digit:]]}"
        fi
    done
done
```

### 5.4 方法 3：ss 自己带 -p

```bash
# 直接加 -p 就显示进程（但需要权限）
ss -tunapl state established -p

# output:
# State    Recv-Q   Send-Q   Local Address:Port   Peer Address:Port   Process
# ESTAB    0        0        10.0.0.50:65432      10.0.0.1:443        users:(("curl",pid=23456,fd=5))
```

---

## 6. network namespace 隔离下的套接字

### 6.1 namespace 对 ss 的影响

```bash
# 默认：查看当前 namespace 的 socket
ss -tunapl

# 查看所有 namespace（包括 host 和容器）
ss -tunapl netns all
# 或切换到 host namespace 查看
ip netns exec ns1 ss -tunapl
# 但 ip netns exec 是在哪个 namespace 下执行命令

# 更直接的方法：直接 cat /var/run/netns/<nsname>
# 或者创建 namespace 的 fd
```

### 6.2 跨 namespace 反查

```
场景：容器 A 里的连接，宿主机想找到对应进程

宿主机：
  ss -tunapl -p   # 看不到容器内的进程（namespace 隔离）
  
  # 解法：知道容器 PID → nsenter 进入该 PID 的 namespace
  docker inspect nginx --format '{{.State.Pid}}'
  # 假设返回 12345

  nsenter -t 12345 -n ss -tunapl
  # -t: target PID
  # -n: network namespace
  # 结果：看到容器内的 ss 输出

  # 然后在宿主机上：
  ls -la /proc/12345/fd/ | grep socket
```

### 6.3 veth pair 跨 namespace

```
host namespace                    container namespace
     │                                     │
     │.1 (veth-host)                       │.2 (veth-container)
     │                                     │
     └──▶ eth0 (物理网卡)                  eth0 (容器内虚拟网卡)
           │
           └──▶ KNI ───────────────────────▶ eth0

ping 10.0.0.1 在容器内：
  eth0 → veth-container → veth-host → eth0 → ...
```

---

## 7. 实用案例

### 7.1 案例 1：定位 TIME_WAIT 源头

```bash
# Step 1：确认 TIME_WAIT 数量
ss -s
# tcp   12345  TIME_WAIT

# Step 2：看 TIME_WAIT 的来源 IP 分布
ss -tan state time-wait | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -10

# Step 3：看 TIME_WAIT 的目标 port 分布（判断哪个服务）
ss -tan state time-wait | awk '{print $5}' | cut -d: -f2 | sort | uniq -c | sort -nr | head -10

# Step 4：找源头进程（如果 port 是服务 port）
ss -tan state time-wait | grep :8080 | head -5
# 假设看到 local_address 10.0.0.50:8080，说明是本机服务产生的大量 TIME_WAIT
# 反查 nginx PID：
ss -tan state time-wait | grep :8080 | head -1 | awk '{print $1}' | xargs -I{} lsof -i {}

# Step 5：解决方案
# 如果大量 TIME_WAIT 来自本机向外连接（client 行为）：
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# 如果是服务端产生（大量 CLOSE_WAIT）：
# → 排查是不是 upstream 超时没响应
# → 排查是不是 keepalive 没开
```

### 7.2 案例 2：快速排查端口冲突

```bash
# 想用 port 8080，但不知道被谁占用了
ss -tlnapl | grep :8080

# output:
# LISTEN  0  511  *:8080  *:*  users:(("java",pid=12345,fd=16))

# 如果 ss 没显示进程：
ss -tlnapl | grep :8080
# LISTEN  0  511  *:8080  *:*  ino:12345 sk:abcdef12

# inode 反查
ls -la /proc/*/fd/* 2>/dev/null | grep socket:\[12345\]
# 找到 java 进程

# 或者用 fuser（更直接）
fuser 8080/tcp
# 12345/tcp

# kill 或重启该进程
kill -9 12345
```

### 7.3 案例 3：分析 UDP 连接（少了状态）

```bash
# UDP 没有状态，ss 用途变了
ss -unapl

# output:
# State   Recv-Q  Send-Q  Local Address    Peer Address    Process
# UNCONN  0       0       0.0.0.0:53       0.0.0.0:*       users:(("dnsmasq",pid=6789,fd=5))
# UNCONN  124     0       127.0.0.1:53     0.0.0.0:*       users:(("dnsmasq",pid=6789,fd=6))

# Recv-Q 有值：说明有包在队列里，程序没及时取（可能阻塞了）
# Send-Q 有值：说明发出去的包对方没收到（网络问题）

# 查看 UDP 内存压力
ss -unapl -m
# 如果 rm > 0 且持续增长 → UDP 缓冲区满
```

### 7.4 案例 4：conntrack 满导致的连接问题

```bash
# conntrack 表满后，新连接建立失败
# 症状：连接正常但新建连接卡住

# Step 1：检查 conntrack table 使用率
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 百分比
echo "scale=2; $(cat /proc/sys/net/netfilter/nf_conntrack_count) * 100 / $(cat /proc/sys/net/netfilter/nf_conntrack_max)" | bc

# Step 2：查看各状态分布
cat /proc/net/nf_conntrack | awk '{print $4}' | sort | uniq -c | sort -nr | head

# Step 3：找最大的源 IP（可能是攻击/爬虫）
cat /proc/net/nf_conntrack | awk '{print $5}' | cut -d= -f2 | sort | uniq -c | sort -nr | head -10

# Step 4：调大 table（临时）
echo 2000000 > /proc/sys/net/netfilter/nf_conntrack_max

# Step 5：加到 sysctl.conf（永久）
# net.netfilter.nf_conntrack_max=2000000
# net.netfilter.nf_conntrack_buckets=250000
```

---

## 8. 小结

```
ss 是 netstat 的现代替代品：
  - netlink 比 /proc 文本解析快 10-20x
  - 内核 BPF 过滤，不用用户态 grep
  - 支持 TCP/UDP/Unix/raw/DCCP 所有类型

TIME_WAIT 不可怕：
  - 主动端产生（client）→ tcp_tw_reuse 可缓解
  - 被动端产生（server）→ 调小 fin_timeout 或加长 port 范围
  - 彻底解决需要连接池 + keepalive

inode 反查三步：
  ss 拿到 inode → ls /proc/*/fd/* → 找到进程

namespace 隔离：
  ip netns exec <ns> ss → 进入 namespace 查看
  nsenter -t <pid> -n → 进入进程的网络 namespace
```

---

## 延伸阅读

- `man 8 ss` — ss 完整选项
- `man 8 netstat` — netstat 历史（已废弃）
- `man 7 socket` — socket API
- `/proc/net/` — 内核网络统计文件
- iproute2 源码：`ip/ss.c` — ss 的 netlink 实现