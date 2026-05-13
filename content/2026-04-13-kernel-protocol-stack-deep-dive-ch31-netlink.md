---
title: "Kernel Protocol Stack 深度探索 (三十一)：Netlink 通信机制"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    netlink,
    rtnetlink,
    genetlink,
    uevent,
    netlink-socket,
    kernel-userspace-communication,
  ]
description: "深入解析 Netlink 通信机制——用户态与内核态交互的标准接口、rtnetlink、genetlink、uevent、netlink 协议族、nlmsg 格式"
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
> 27. [[2026-04-13-kernel-protocol-stack-deep-dive-ch27-raw-socket|第二十七章：RAW Socket 与 ICMP]]
> 28. [[2026-04-13-kernel-protocol-stack-deep-dive-ch28-socket-api|第二十八章：Socket API 概述]]
> 29. [[2026-04-13-kernel-protocol-stack-deep-dive-ch29-inet-sock|第二十九章：Inet Socket 实现]]
> 30. [[2026-04-13-kernel-protocol-stack-deep-dive-ch30-sock-mem|第三十章：Socket 内存管理]]
> 31. **第三十一章：Netlink 通信机制**

---

## 1. 概述

Netlink 是 Linux 内核与用户空间通信的标准机制，比 ioctl 更灵活，支持异步双向通信。它是一种特殊的 socket 家族（AF_NETLINK），用于：

- 路由信息获取（rtnetlink）
- 接口配置（iproute2）
- 网络统计（netlink）
- 热插拔事件（uevent）
- 防火墙配置（iptables/nftables）
- 连接跟踪查询

---

## 2. Netlink 协议族

### 2.1 socket 创建

```c
#include <sys/socket.h>
#include <linux/netlink.h>

int sock = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
// 或 NETLINK_USERSOCK, NETLINK_FIREWALL, NETLINK_NETFILTER 等
```

### 2.2 地址结构

```c
struct sockaddr_nl {
    sa_family_t     nl_family;   // AF_NETLINK
    unsigned short  nl_pad;      // 填充
    pid_t           nl_pid;      // 端口 ID（用户空间通常为进程 ID 或 0 表示内核）
    unsigned int    nl_groups;   // 多播组
};

struct nlmsghdr {
    __u32          nlmsg_len;   // 消息总长度（头部+数据）
    __u16          nlmsg_type;   // 消息类型
    __u16          nlmsg_flags; // 标志
    __u32          nlmsg_seq;   // 序列号
    __u32          nlmsg_pid;   // 发送方 PID
};
```

---

## 3. Netlink 消息格式

### 3.1 nlmsghdr 头部

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      nlmsg_len (total)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|        nlmsg_type        |       nlmsg_flags                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      nlmsg_seq                                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      nlmsg_pid                                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     payload...                                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.2 消息类型

| 类型         | 说明              |
| ------------ | ----------------- |
| NLMSG_NOOP   | 空消息            |
| NLMSG_ERROR  | 错误响应          |
| NLMSG_DONE   | 多消息结束标记    |
| RTM_NEWLINK  | 创建/更新网络接口 |
| RTM_DELLINK  | 删除网络接口      |
| RTM_NEWADDR  | 添加 IP 地址      |
| RTM_DELADDR  | 删除 IP 地址      |
| RTM_NEWROUTE | 添加路由          |
| RTM_DELROUTE | 删除路由          |
| RTM_NEWNEIGH | 添加 neighbor 项  |
| RTM_DELNEIGH | 删除 neighbor 项  |

### 3.3 消息标志

| 标志            | 说明             |
| --------------- | ---------------- |
| NLM_F_REQUEST   | 这是请求消息     |
| NLM_F_MULTI     | 多消息响应       |
| NLM_F_ACK       | 请求 ACK 确认    |
| NLM_F_ECHO      | 回显请求         |
| NLM_F_DUMP_INTR | 丢弃被中断的转储 |

---

## 4. 常用 Netlink 协议

### 4.1 NETLINK_ROUTE（路由/接口）

用于配置网络接口、路由、邻居表等：

```c
#include <linux/rtnetlink.h>
#include <linux/neighbour.h>

// 创建 NETLINK_ROUTE socket
int sock = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);

// 设置接收多播组（RTMGRP_LINK | RTMGRP_IPV4_ROUTE 等）
struct sockaddr_nl addr;
addr.nl_family = AF_NETLINK;
addr.nl_groups = RTMGRP_LINK | RTMGRP_IPV4_IFADDR;
bind(sock, (struct sockaddr *)&addr, sizeof(addr));

// 接收消息
char buf[8192];
struct nlmsghdr *hdr = (struct nlmsghdr *)buf;
recv(sock, buf, sizeof(buf), 0);

// 处理消息
while (NLMSG_OK(hdr, len)) {
    switch (hdr->nlmsg_type) {
    case RTM_NEWLINK:
        // 网络接口变化
        struct ifinfomsg *ifi = NLMSG_DATA(hdr);
        break;
    case RTM_NEWADDR:
        // IP 地址变化
        struct ifaddrmsg *ifa = NLMSG_DATA(hdr);
        break;
    }
    hdr = NLMSG_NEXT(hdr, len);
}
```

### 4.2 NETLINK_NETFILTER（Conntrack）

```c
#include <linux/netfilter/nfnetlink.h>

int sock = socket(AF_NETLINK, SOCK_RAW, NETLINK_NETFILTER);

// 查询 conntrack 条目
struct nlmsghdr {
    .nlmsg_type = IPCTNL_MSG_CT_GET;
    .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
};

send(sock, &nlh, sizeof(nlh), 0);
recv(sock, buf, sizeof(buf), 0);
```

### 4.3 NETLINK_KOBJECT_UEVENT（UEvent）

用于接收内核热插拔事件：

```c
#include <linux/netlink.h>

int sock = socket(AF_NETLINK, SOCK_RAW, NETLINK_KOBJECT_UEVENT);

struct sockaddr_nl addr;
addr.nl_family = AF_NETLINK;
addr.nl_pid = 0;
addr.nl_groups = 1;  // Uevent group
bind(sock, (struct sockaddr *)&addr, sizeof(addr));

// 接收 uevent
char buf[8192];
recv(sock, buf, sizeof(buf), 0);

// uevent 格式示例：
// ACTION=add\0DEVPATH=/class/net/eth0\0SUBSYSTEM=net\0...
```

---

## 5. rtnetlink 详解

### 5.1 接口信息（RTM_NEWLINK）

```c
// struct ifinfomsg - 网络接口信息
struct ifinfomsg {
    unsigned char   ifi_family;   // AF_UNSPEC 或 AF_BRIDGE
    unsigned char   __ifi_pad;
    unsigned short  ifi_type;     // ARPHRD_* (如 ARPHRD_ETHER)
    int             ifi_index;     // 接口 index
    unsigned int    ifi_flags;     // IFF_* 标志
    unsigned int    ifi_change;    // 要改变的标志（用于 SETIFY）
};

struct nlmsghdr hdr = {
    .nlmsg_type = RTM_NEWLINK,
    .nlmsg_flags = NLM_F_REQUEST | NLM_F_ROOT,
};
```

### 5.2 地址信息（RTM_NEWADDR）

```c
// struct ifaddrmsg - IP 地址信息
struct ifaddrmsg {
    unsigned char  ifa_family;    // AF_INET 或 AF_INET6
    unsigned char  ifa_prefixlen; // 地址前缀长度
    unsigned char  ifa_flags;
    unsigned char  ifa_scope;
    int            ifa_index;    // 接口 index
};

// rtattr - 路由属性
struct rtattr {
    unsigned short  rta_len;    // 属性长度
    unsigned short  rta_type;   // IFA_* 类型
    // 值跟在头部后面
};

// 常用属性类型
// IFA_ADDRESS - IP 地址
// IFA_LOCAL - 本地地址（点对点）
// IFA_LABEL - 接口名称
```

### 5.3 路由信息（RTM_NEWROUTE）

```c
struct rtmsg {
    unsigned char   rtm_family;   // AF_INET/AF_INET6
    unsigned char   rtm_dst_len;  // 目标前缀长度
    unsigned char   rtm_src_len;  // 源前缀长度
    unsigned char   rtm_tos;      // TOS
    unsigned char   rtm_table;    // 路由表 ID (RT_TABLE_*)
    unsigned char   rtm_protocol; // 协议 (RTPROT_*)
    unsigned char   rtm_scope;    // 范围 (RT_SCOPE_*)
    unsigned char   rtm_type;     // 类型 (RTN_*)
    unsigned int    rtm_flags;
};

// rtm_table 常用值
RT_TABLE_DEFAULT  // 默认表
RT_TABLE_MAIN    // 主表 (iproute2 使用)
RT_TABLE_LOCAL   // 本地表

// rtm_protocol 常用值
RTPROT_KERNEL    // 内核添加
RTPROT_BOOT      // 启动时添加
RTPROT_STATIC    // 静态配置

// rtm_type 常用值
RTN_UNICAST      // 单播路由
RTN_BLACKHOLE    // 黑洞路由（丢包）
RTN_PROHIBIT     // 禁止路由
RTN_LOCAL        // 本地路由
```

---

## 6. genetlink（通用 Netlink）

genetlink 为每个协议族提供了统一的注册接口，比 rtnetlink 更简单。

### 6.1 协议族定义

```c
#include <linux/genetlink.h>

// netlink 控制器 socket
struct genlmsghdr {
    __u8  cmd;       // 家族特定命令
    __u8  version;   // 版本
    __u16 reserved;  // 保留
};
```

### 6.2 用户空间使用

```c
#include <linux/genetlink.h>

// 获取家族 ID
int sock = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);

struct nlmsghdr {
    .nlmsg_type = CTRL_CMD_GETFAMILY;
    .nlmsg_flags = NLM_F_REQUEST;
};
struct genlmsghdr {
    .cmd = CTRL_CMD_GETFAMILY;
    .version = 1;
};

send(sock, &hdr, sizeof(hdr), 0);

// 接收响应获取 family ID
```

### 6.3 常用 genetlink 家族

| 家族名      | 说明              |
| ----------- | ----------------- |
| nlctrl      | Netlink 控制器    |
| tcp_metrics | TCP 性能指标      |
| devlink     | 设备链路管理      |
| wifi        | Wireless 设备配置 |

---

## 7. 内核实现

### 7.1 netlink socket 分配

```c
// net/netlink/af_netlink.c
static int netlink_create(struct net *net, struct socket *sock,
                           int protocol, int kern)
{
    struct sock *sk;
    struct netlink_sock *nlk;

    // 分配 netlink socket
    sk = netlink_alloc_sock(net, 0, protocol, &nlk);
    if (!sk)
        return -ENOMEM;

    sock_init_data(sock, sk);

    // 初始化 netlink 特定字段
    nlk->pid = netlink_un_autopid(net, current->pid);
    nlk->groups = 0;

    // 将 socket 加入 hash 表
    lock_sock(sk);
    nl_table_insert(nlk, nlk->pid);
    release_sock(sk);

    return 0;
}
```

### 7.2 消息接收

```c
// net/netlink/af_netlink.c
static int netlink_recvmsg(struct socket *sock, struct msghdr *msg,
                            size_t total_len, int flags)
{
    struct sock *sk = sock->sk;
    struct netlink_sock *nlk = nlk_sk(sk);
    struct sk_buff *skb;

    // 从接收队列取消息
    skb = __skb_recv_datagram(sk, flags & MSG_DONTWAIT, &timeo, &err);
    if (!skb)
        return err;

    // 复制到用户空间
    err = skb_copy_datagram_msg(skb, 0, msg, total_len);
    if (err)
        goto out;

    // 返回发送方地址
    if (msg->msg_name) {
        struct sockaddr_nl *addr = (struct sockaddr_nl *)msg->msg_name;
        addr->nl_family = AF_NETLINK;
        addr->nl_pid = NETLINK_CB(skb).pid;
        addr->nl_groups = NETLINK_CB(skb).groups;
    }

out:
    consume_skb(skb);
    return err;
}
```

### 7.3 消息发送

```c
// net/netlink/af_netlink.c
static int netlink_sendmsg(struct socket *sock, struct msghdr *msg,
                           size_t len)
{
    struct sock *sk = sock->sk;
    struct netlink_sock *nlk = nlk_sk(sk);
    struct sk_buff *skb;
    struct nlmsghdr *hdr;
    int err;

    // 分配 skb
    skb = nlmsg_new(len, GFP_KERNEL);
    if (!skb)
        return -ENOMEM;

    // 填充 nlmsghdr
    hdr = nlmsg_put(skb, nlk->pid, nlk->seq, msg->msg_namelen,
                     0, 0);
    if (!hdr) {
        kfree_skb(skb);
        return -EMSGSIZE;
    }

    // 复制数据
    err = nlmsg_unicast(sk, skb, nlk->pid);

    return err;
}
```

---

## 8. iproute2 使用示例

### 8.1 ip 命令内部使用 netlink

```bash
# 查看接口
ip link show
# 内部调用：RTM_GETLINK

# 查看 IP 地址
ip addr show
# 内部调用：RTM_GETADDR

# 查看路由
ip route show
# 内部调用：RTM_GETROUTE

# 设置接口 up
ip link set eth0 up
# 内部调用：RTM_SETLINK
```

### 8.2 监控网络事件

```bash
# 实时监控接口变化
ip monitor link

# 实时监控路由变化
ip monitor route

# 实时监控地址变化
ip monitor address
```

---

## 9. /proc 接口

```bash
# 查看 netlink socket 统计
cat /proc/net/netstat | grep Netlink

# 查看 netlink socket 列表
cat /proc/net/netlink

# 示例输出
sk       RefCnt Rmem   User   Inode  Headlen  Opens  Rqueue  Wqueue  Drops
nl:00000D5A  1      0      0       1234567 0       0      0       0       0
```

---

## 10. libnl 库

用户空间可以使用 libnl 库简化 netlink 编程：

```c
#include <netlink/netlink.h>
#include <netlink/route/link.h>
#include <netlink/route/addr.h>

// 初始化
struct nl_sock *sock = nl_socket_alloc();
nl_connect(sock, NETLINK_ROUTE);

// 获取接口列表
struct nl_cache *link_cache;
rtnl_link_alloc_cache(sock, &link_cache);

// 获取 eth0 接口
struct rtnl_link *link = rtnl_link_get_by_name(link_cache, "eth0");
int ifindex = rtnl_link_get_ifindex(link);

// 释放
rtnl_link_put(link);
nl_socket_free(sock);
```

---

## 11. 总结

| 协议                   | 说明                          |
| ---------------------- | ----------------------------- |
| NETLINK_ROUTE          | 路由/接口/地址配置 (iproute2) |
| NETLINK_NETFILTER      | 防火墙/conntrack              |
| NETLINK_KOBJECT_UEVENT | 热插拔事件                    |
| NETLINK_GENERIC        | 通用 netlink 族               |
| NETLINK_SOCK_DIAG      | Socket 统计查询               |

Netlink 是 Linux 网络管理的核心机制，iproute2、iptables、conntrack 等工具都依赖它与内核通信。理解 netlink 消息格式对于网络工具开发和调试至关重要。
