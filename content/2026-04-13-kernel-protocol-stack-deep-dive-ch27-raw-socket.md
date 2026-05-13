---
title: "Kernel Protocol Stack 深度探索 (二十七)：RAW Socket 与 ICMP"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    raw-socket,
    icmp,
    ping,
    traceroute,
    packet-signature,
    socket-options,
  ]
description: "深入解析 RAW Socket——允许直接访问 IP 层、自定义协议、ICMP 协议实现、ping/traceroute 工具原理、协议注册"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-kernel-protocol-stack-deep-dive-ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[2026-04-13-kernel-protocol-stack-deep-dive-ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[2026-04-13-kernel-protocol-stack-deep-dive-ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. [[2026-04-13-kernel-protocol-stack-deep-dive-ch5-napi|第五章：NAPI 与轮询模式]]
> 6. [[2026-04-13-kernel-protocol-stack-deep-dive-ch6-ethernet|第六章：Ethernet 与 MAC 层]]
> 7. [[2026-04-13-kernel-protocol-stack-deep-dive-ch7-bridge|第七章：网桥与 Switchdev]]
> 8. [[2026-04-13-kernel-protocol-stack-deep-dive-ch8-vlan|第八章：VLAN 与 802.1Q]]
> 9. [[2026-04-13-kernel-protocol-stack-deep-dive-ch9-macvlan|第九章：MACVLAN 与虚拟网卡]]
> 10. [[2026-04-13-kernel-protocol-stack-deep-dive-ch10-bonding|第十章：Bonding 与 teamd]]
> 11. [[2026-04-13-kernel-protocol-stack-deep-dive-ch11-ip-framing|第十一章：IP 协议封装]]
> 12. [[2026-04-13-kernel-protocol-stack-deep-dive-ch12-routing|第十二章：路由与 FIB]]
> 13. [[2026-04-13-kernel-protocol-stack-deep-dive-ch13-neighbor|第十三章：Neighbor 与 ARP]]
> 14. [[2026-04-13-kernel-protocol-stack-deep-dive-ch14-iptables|第十四章：iptables 基础]]
> 15. [[2026-04-13-kernel-protocol-stack-deep-dive-ch15-conntrack|第十五章：连接跟踪 Conntrack]]
> 16. [[2026-04-13-kernel-protocol-stack-deep-dive-ch16-nat|第十六章：NAT 与地址转换]]
> 17. [[2026-04-13-kernel-protocol-stack-deep-dive-ch17-gre|第十七章：GRE 隧道协议]]
> 18. [[2026-04-13-kernel-protocol-stack-deep-dive-ch18-vxlan|第十八章：VXLAN 虚拟可扩展局域网]]
> 19. [[2026-04-13-kernel-protocol-stack-deep-dive-ch19-geneve|第十九章：GENEVE 通用网络虚拟化封装]]
> 20. [[2026-04-13-kernel-protocol-stack-deep-dive-ch20-fib-rules|第二十章：FIB Rules 转发规则]]
> 21. [[2026-04-13-kernel-protocol-stack-deep-dive-ch21-tcp-headers|第二十一章：TCP 头部结构]]
> 22. [[2026-04-13-kernel-protocol-stack-deep-dive-ch22-tcp-states|第二十二章：TCP 状态机]]
> 23. [[2026-04-13-kernel-protocol-stack-deep-dive-ch23-tcp-data-buffer|第二十三章：TCP 数据与缓冲管理]]
> 24. [[2026-04-13-kernel-protocol-stack-deep-dive-ch24-tcp-congestion|第二十四章：TCP 拥塞控制]]
> 25. [[2026-04-13-kernel-protocol-stack-deep-dive-ch25-tcp-advanced|第二十五章：TCP 高级特性]]
> 26. [[2026-04-13-kernel-protocol-stack-deep-dive-ch26-udp|第二十六章：UDP 协议实现]]
> 27. **第二十七章：RAW Socket 与 ICMP**

---

## 1. 概述：RAW Socket

RAW Socket（原始套接字）允许应用直接访问 IP 层，绕过传输层（TCP/UDP）。用途：

- 实现自定义协议（ICMP、PIG负载探测）
- 发送原始数据包（自定义 IP 头）
- 网络诊断工具（ping、traceroute）
- 隧道协议（IPsec、IP隧道）
- 防火墙测试

### 1.1 与普通 Socket 对比

| 特性     | SOCK_STREAM (TCP) | SOCK_DGRAM (UDP) | SOCK_RAW (RAW) |
| -------- | ----------------- | ---------------- | -------------- |
| 协议层   | TCP（L4）         | UDP（L4）        | IP（L3）       |
| 数据单元 | 字节流            | 数据报           | IP 数据报      |
| 头部处理 | 内核处理          | 内核处理         | 用户可选       |
| 端口绑定 | 必须              | 必须             | 可选           |
| 权限     | 普通用户          | 普通用户         | root           |

---

## 2. RAW Socket 创建

### 2.1 socket() API

```c
#include <sys/socket.h>
#include <netinet/in.h>

// 创建 RAW socket，指定协议类型
int sock = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
// 创建 RAW socket，接收任意 IP 协议
int sock = socket(AF_INET, SOCK_RAW, IPPROTO_RAW);
```

### 2.2 内核实现

```c
// net/ipv4/raw.c
static int raw_create(struct net *net, struct socket *sock, int protocol,
                      int kern)
{
    struct sock *sk;

    // 查找匹配的协议处理
    struct inet_protosw *pp;
    for (pp = inet_protosw; pp; pp = pp->next) {
        if (pp->protocol == protocol && pp->type == sock->type)
            break;
    }

    if (!pp)
        return -EPROTONOSUPPORT;

    // 分配 sock 结构
    sk = sk_alloc(net, PF_INET, GFP_ATOMIC, pp->prot, kern);
    sock_init_data(sock, sk);

    // 初始化 RAW socket
    raw_sk(sk)->checksum = 1;  // 默认校验和验证
    raw_sk(sk)->hdrincl = 0;   // 默认包含 IP 头（由内核构造）
}
```

---

## 3. 协议注册

### 3.1 inet_protosw 结构

RAW socket 使用 inet_protosw 注册协议处理：

```c
// include/net/protocol.h
struct inet_protosw {
    struct list_head    list;
    unsigned short      type;        // SOCK_RAW
    unsigned short      protocol;    // IPPROTO_*
    struct proto       *prot;        // 协议处理函数
    const struct proto_ops *ops;    // socket 操作集
    int                 flags;      // INET_PROTOSW_*
};
```

### 3.2 ICMP 协议注册

```c
// net/ipv4/raw.c
static const struct proto_ops raw_ops = {
    .family         = PF_INET,
    .owner          = THIS_MODULE,
    .bind           = raw_bind,
    .socket_pair    = sock_no_socket_pair,
    .accept         = sock_no_accept,
    .listen         = sock_no_listen,
    .sendmsg        = raw_sendmsg,
    .recvmsg        = raw_recvmsg,
    .shutdown       = sock_no_shutdown,
    .setsockopt     = raw_setsockopt,
    .getsockopt     = raw_getsockopt,
    .sendpage       = sock_no_sendpage,
};

static struct proto raw_prot = {
    .name           = "RAW",
    .owner          = THIS_MODULE,
    .obj_size       = sizeof(struct raw_sock),
    .destroy        = raw_destroy,
    .close          = raw_close,
    .hash           = raw_hash,
    .unhash         = raw_unhash,
    .connect        = sock_def_connect,
};

static const struct inet_protosw raw_pf_inet = {
    .type           = SOCK_RAW,
    .protocol       = IPPROTO_IP,  // 通配
    .prot           = &raw_prot,
    .ops            = &raw_ops,
    .flags          = INET_PROTOSW_RAW,
};
```

---

## 4. ICMP 协议

### 4.1 ICMP 头部

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       Type      |       Code         |       Checksum        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Rest of Header                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             Data                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 4.2 ICMP 类型

| Type | Name                    | Description            |
| ---- | ----------------------- | ---------------------- |
| 0    | Echo Reply              | ping 响应              |
| 3    | Destination Unreachable | 目的不可达             |
| 4    | Source Quench           | 源抑制（已废弃）       |
| 8    | Echo Request            | ping 请求              |
| 11   | Time Exceeded           | TTL 过期（traceroute） |
| 12   | Parameter Problem       | IP 头错误              |

### 4.3 ICMP 消息结构

```c
// include/uapi/linux/icmp.h
struct icmphdr {
    __u8       type;           // 类型
    __u8       code;           // 代码
    __sum16    checksum;       // 校验和
    union {
        struct {
            __be16  id;
            __be16  sequence;
        } echo;
        __be32  gateway;
        struct {
            __u8   __unused;
            __u8   __reserved;
            __be16  reserved;
        } fwrd;
        struct {
            __be16  unused;
            __be16  mtu;
        } frag;
        __u8    reserved[4];
    } un;
};
```

---

## 5. ICMP 发送与接收

### 5.1 发送 ICMP

```c
// net/ipv4/icmp.c
int icmp_send(struct sk_buff *skb_in, int type, int code, __be32 info,
              struct icmp_bxm *data)
{
    struct icmphdr *icmph;
    struct sk_buff *skb;
    struct rtable *rt;
    struct flowi4 fl4;

    // 分配新的 skb
    skb = alloc_skb(ICMP_DROP_SIZE + len, GFP_ATOMIC);
    icmph = skb_put(skb, sizeof(*icmph) + len);

    // 填充 ICMP 头
    icmph->type = type;
    icmph->code = code;
    icmph->un.gateway = info;
    memcpy(skb_put(skb, len), data, len);

    // 计算校验和
    icmph->checksum = 0;
    icmph->checksum = ip_compute_csum(icmph, sizeof(*icmph) + len);

    // 查找路由，发送到 IP 层
    ip_route_output_flow(net, &fl4, icmp_reply_to(data->skb));
    return ip_push_pending_frames(net, &fl4);
}
```

### 5.2 接收 ICMP

```c
// net/ipv4/icmp.c
int icmp_rcv(struct sk_buff *skb)
{
    struct icmphdr *icmph;

    // 验证头部
    if (!pskb_may_pull(skb, sizeof(*icmph)))
        goto error;

    icmph = icmp_hdr(skb);

    // 查找对应的 socket（ICMP 可能上报给传输层）
    switch (icmph->type) {
    case ICMP_DEST_UNREACH:
    case ICMP_TIME_EXCEEDED:
    case ICMP_PARAMETERPROB:
        // 传递给 UDP/TCP 处理（如端口不可达）
        if (handler[icmph->type])
            handler[icmph->type](icmph, skb);
        break;
    case ICMP_ECHOREPLY:
        // 传递给 ping socket 处理
        raw_rcv(skb);
        break;
    }
}
```

---

## 6. RAW Socket 选项

### 6.1 IP_HDRINCL（包含 IP 头）

允许用户自己构造 IP 头部：

```c
int sock = socket(AF_INET, SOCK_RAW, IPPROTO_RAW);
int val = 1;
setsockopt(sock, IPPROTO_IP, IP_HDRINCL, &val, sizeof(val));

// 之后 sendto 需要自己构造完整的 IP 头
struct sockaddr_in addr;
addr.sin_family = AF_INET;
addr.sin_addr.s_addr = dest_ip;

sendto(sock, ip_packet, len, 0, (struct sockaddr *)&addr, sizeof(addr));
```

### 6.2 IP_RECVERR（错误报告）

```c
int val = 1;
setsockopt(sock, IPPROTO_IP, IP_RECVERR, &val, sizeof(val));

struct msghdr msg;
struct sock_extended_err ee;
char cmsg[CMSG_SPACE(sizeof(ee))];

msg.msg_control = cmsg;
msg.msg_controllen = sizeof(cmsg);
recvmsg(sock, &msg, MSG_ERRQUEUE);
```

### 6.3 IP_MTU_DISCOVER（MTU 发现）

```c
int val = IP_PMTUDISC_DO;  // 始终分片
setsockopt(sock, IPPROTO_IP, IP_MTU_DISCOVER, &val, sizeof(val));
```

### 6.4 其他选项

```c
// 接收TTL
int val = 1;
setsockopt(sock, IPPROTO_IP, IP_RECVTTL, &val, sizeof(val));

// 接收TOS
setsockopt(sock, IPPROTO_IP, IP_RECVTOS, &val, sizeof(val));

// 接收接口信息
setsockopt(sock, IPPROTO_IP, IP_PKTINFO, &val, sizeof(val));
```

---

## 7. 绑定与端口

### 7.1 bind 对 RAW Socket 的作用

```c
struct sockaddr_in addr;
addr.sin_family = AF_INET;
addr.sin_port = 0;  // RAW socket 不使用端口
addr.sin_addr.s_addr = htonl(INADDR_ANY);

bind(sock, (struct sockaddr *)&addr, sizeof(addr));
```

绑定 RAW socket 时指定 `sin_port=0`，只关心 IP 地址匹配。

### 7.2 connect

```c
// 连接到特定主机
struct sockaddr_in addr;
addr.sin_family = AF_INET;
addr.sin_port = 0;
addr.sin_addr.s_addr = inet_addr("8.8.8.8");

connect(sock, (struct sockaddr *)&addr, sizeof(addr));

// 之后可以只用 send()，自动路由到 connect 的地址
```

---

## 8. ping 实现原理

ping 使用 ICMP Echo Request/Reply：

```c
// 简化版 ping 实现
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>

int main() {
    int sock = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);

    struct sockaddr_in target;
    target.sin_family = AF_INET;
    target.sin_addr.s_addr = inet_addr(argv[1]);

    struct icmphdr icmp;
    icmp.type = ICMP_ECHO;
    icmp.code = 0;
    icmp.un.echo.id = htons(getpid() & 0xFFFF);
    icmp.un.echo.sequence = htons(1);
    icmp.checksum = 0;
    icmp.checksum = ip_checksum(&icmp, sizeof(icmp));

    sendto(sock, &icmp, sizeof(icmp), 0,
           (struct sockaddr *)&target, sizeof(target));

    char buf[1024];
    struct sockaddr_in from;
    socklen_t len = sizeof(from);
    recvfrom(sock, buf, sizeof(buf), 0,
             (struct sockaddr *)&from, &len);

    struct icmphdr *reply = (struct icmphdr *)(buf + sizeof(struct iphdr));
    if (reply->type == ICMP_ECHOREPLY)
        printf("Reply received\\n");
}
```

---

## 9. traceroute 实现原理

traceroute 使用 ICMP Time Exceeded 和 UDP：

### 9.1 基于 UDP 的 traceroute

```c
// 发送 UDP 数据包，TTL 从 1 开始递增
for (int ttl = 1; ttl <= 30; ttl++) {
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    setsockopt(sock, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl));

    // 发送到高端口（30000+）
    struct sockaddr_in target;
    target.sin_port = htons(30000 + ttl);
    sendto(sock, data, len, 0, &target, sizeof(target));

    // 等待 ICMP Time Exceeded
    int raw = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    recvfrom(raw, buf, sizeof(buf), 0, &from, &len);

    // 打印路由跳
}
```

### 9.2 基于 ICMP 的 traceroute

```c
// 直接发送 ICMP Echo Request，递增 TTL
for (int ttl = 1; ttl <= 30; ttl++) {
    int sock = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    setsockopt(sock, IPPROTO_IP, IP_TTL, &ttl, sizeof(ttl));

    sendto(sock, icmp_req, sizeof(icmp_req), 0, &target, sizeof(target));

    // 等待 ICMP TTL Exceeded 或 Echo Reply
}
```

---

## 10. 权限与安全

### 10.1 CAP_NET_RAW

创建 RAW socket 需要 `CAP_NET_RAW` 权限：

```bash
# 检查进程权限
cat /proc/<pid>/status | grep Cap

# 需要 CAP_NET_RAW capability
sudo setcap cap_net_raw+ep /path/to/program
```

### 10.2 绑定端口限制

Linux 限制非 root 进程绑定到保留端口（< 1024）：

```c
// 使用 SOCK_DGRAM 让内核处理校验和，而非 IPPROTO_RAW
int sock = socket(AF_INET, SOCK_DGRAM, 0);  // 普通 UDP socket
```

### 10.3 /proc 控制

```bash
# 禁用 RAW socket
sysctl -w net.ipv4.conf.all.raw_prot_drop = 1

# 限制 RAW 接收
sysctl -w net.ipv4.raw_l3mbuf_accept = 0
```

---

## 11. 诊断命令

```bash
# 查看 RAW socket 统计
cat /proc/net/snmp | grep Raw

# 查看 RAW socket 详情
cat /proc/net/raw

# 示例输出
 sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
  785: 00000000:0001 00000000:0000 0001 00000000:00000000 00:00000000     0 0 12345 0 100000001 2 0000000000000000 0

# 使用 tcpdump 捕获 ICMP
tcpdump -i eth0 icmp

# 使用 raw 抓取所有 IP 包
tcpdump -i eth0 ip
```

---

## 12. 总结

| 特性       | 说明                            |
| ---------- | ------------------------------- |
| SOCK_RAW   | 允许直接访问 IP 层              |
| IP_HDRINCL | 用户构造 IP 头                  |
| ICMP       | 网络诊断协议（ping/traceroute） |
| 权限       | 需要 CAP_NET_RAW                |
| 协议注册   | inet_protosw 表                 |

RAW Socket 是网络诊断和安全工具的基础，也是实现新型协议（如新型隧道协议）的必要手段。
