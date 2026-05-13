---
title: "Kernel Protocol Stack 深度探索 (二十八)：Socket API 概述"
date: 2026-04-13
tags: [linux, kernel, networking, series, socket, api, file-descriptor, socketpair, send, recv, sendmsg, recvmsg]
description: "深入解析 POSIX Socket API——socket 创建、bind/listen/accept、send/recv 系列、sendmsg/recvmsg/control message、文件描述符与 socket 的关系"
---

> [!info] Kernel Protocol Stack 深度探索系列
> 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
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
> 28. **第二十八章：Socket API 概述**

---

## 1. 概述

Socket API 是用户空间程序与内核网络栈交互的标准接口。Linux 将 socket 作为文件描述符（file descriptor）处理，统一了网络 I/O 与文件 I/O 的编程模型。

核心特点：
- Socket 是文件描述符，可使用 read/write/poll/select/epoll
- 支持多种协议族（AF_INET、AF_INET6、AF_UNIX）
- 支持多种类型（SOCK_STREAM、SOCK_DGRAM、SOCK_RAW）

---

## 2. Socket 创建：socket()

### 2.1 API

```c
#include <sys/socket.h>

int socket(int domain, int type, int protocol);

// 示例
int tcp_sock = socket(AF_INET, SOCK_STREAM, 0);      // TCP
int udp_sock = socket(AF_INET, SOCK_DGRAM, 0);        // UDP
int raw_sock = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP); // RAW
```

### 2.2 domain（协议族）

| Domain | 说明 |
|--------|------|
| AF_INET | IPv4 |
| AF_INET6 | IPv6 |
| AF_UNIX / AF_LOCAL | Unix Domain Socket |
| AF_NETLINK | Netlink |
| AF_PACKET | 链路层原始套接字 |

### 2.3 type（套接字类型）

| Type | 说明 |
|------|------|
| SOCK_STREAM | 面向连接的字节流（TCP） |
| SOCK_DGRAM | 无连接的数据报（UDP） |
| SOCK_RAW | 原始套接字（直接访问 IP 层） |
| SOCK_SEQPACKET | 面向连接的有序数据包 |
| SOCK_RDM | 可靠数据报（不常用） |

### 2.4 protocol

通常设为 0，让内核根据 domain 和 type 自动选择协议：
- AF_INET + SOCK_STREAM → IPPROTO_TCP
- AF_INET + SOCK_DGRAM → IPPROTO_UDP

### 2.5 内核实现

```c
// net/socket.c
SYSCALL_DEFINE3(socket, int, family, int, type, int, protocol)
{
    struct socket *sock;
    struct proto *prot;
    int err;

    // 查找协议处理
    struct net_proto_family *pf = rcu_dereference(net_families[family]);
    if (!pf)
        return -EAFNOSUPPORT;

    // 分配 socket
    err = sock_create(family, type, protocol, pf, &sock);
    if (err < 0)
        return err;

    // 分配文件描述符
    err = sock_map_fd(sock, type & SOCK_TYPE_MASK);
    return err;
}
```

---

## 3. 绑定地址：bind()

### 3.1 API

```c
#include <sys/socket.h>

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen);

// 示例（IPv4）
struct sockaddr_in addr;
memset(&addr, 0, sizeof(addr));
addr.sin_family = AF_INET;
addr.sin_port = htons(8080);
addr.sin_addr.s_addr = htonl(INADDR_ANY);  // 或具体 IP

bind(sockfd, (struct sockaddr *)&addr, sizeof(addr));
```

### 3.2 特殊地址

```c
// 绑定到任意地址（监听所有接口）
addr.sin_addr.s_addr = htonl(INADDR_ANY);

// 绑定到本地回环（仅本机访问）
addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);  // 127.0.0.1

// 绑定到特定网卡 IP
addr.sin_addr.s_addr = inet_addr("192.168.1.100");
```

### 3.3 内核实现

```c
// net/socket.c
static int __sys_bind(int sockfd, struct sockaddr *addr, int addrlen)
{
    struct socket *sock = sockfd_lookup(sockfd, &err);
    struct sock *sk = sock->sk;

    // 协议特定的 bind
    err = sock->ops->bind(sock, addr, addrlen);
    if (err < 0)
        return err;

    // 更新 socket 状态
    sk->sk_userlocks |= SOCK_BIND_LOCK;
    return 0;
}

// inet_bind（IPv4 TCP 实现）
int inet_bind(struct socket *sock, struct sockaddr *uaddr, int addr_len)
{
    struct sock *sk = sock->sk;
    struct inet_sock *inet = inet_sk(sk);
    struct sockaddr_in *addr = (struct sockaddr_in *)uaddr;

    // 检查端口是否可用
    if (sk->sk_prot->get_port(sk, addr->sin_port)) {
        if (inet_rcv_saddr(sk, addr->sin_addr.s_addr) == 0)
            return -EADDRINUSE;
    }

    // 绑定到地址
    inet->inet_saddr = addr->sin_addr.s_addr;
    inet->inet_sport = addr->sin_port;
    sk->sk_rcv_saddr = addr->sin_addr.s_addr;

    return 0;
}
```

---

## 4. 监听：listen()

### 4.1 API

```c
int listen(int sockfd, int backlog);
```

`backlog` 指定等待连接队列的最大长度（已完成连接但未 accept）。

### 4.2 内核实现

```c
// net/socket.c
SYSCALL_DEFINE2(listen, int, sockfd, int, backlog)
{
    struct socket *sock = sockfd_lookup(sockfd, &err);
    struct sock *sk = sock->sk;

    // 仅 TCP socket 支持 listen
    if (sk->sk_protocol == IPPROTO_TCP) {
        tcp_sync_mss(sk, 536);
        sk->sk_max_backlog = backlog;
        sk->sk_state = TCP_LISTEN;
    }
}
```

### 4.3 backlog 历史

- 早期 Linux：超过 backlog 的 SYN 请求被忽略
- 现代 Linux：使用 `syn backlog` 队列和 `accept queue`，SYN cookies 缓解
- 建议值：128-1024

---

## 5. 接受连接：accept()

### 5.1 API

```c
#include <sys/socket.h>

int accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
// 或非阻塞版本
int accept4(int sockfd, struct sockaddr *addr, socklen_t *addrlen, int flags);
```

### 5.2 内核实现

```c
// net/socket.c
SYSCALL_DEFINE4(accept4, int, sockfd, struct sockaddr *, upeer_sockaddr,
                int *, upeer_addrlen, int, flags)
{
    struct socket *sock = sockfd_lookup(sockfd, &err);
    struct sock *sk = sock->sk;

    // 从 accept 队列取出一个连接
    struct sock *newsk = sk->sk_prot->accept(sk, flags, &err);
    if (!newsk)
        return err;

    // 分配新的文件描述符
    newsock = sock_from_file(newsk->sk_socket, &err);
    err = sock_map_fd(newsock, flags & O_CLOEXEC ? O_CLOEXEC : 0);

    return err;
}

// inet_accept（TCP 实现）
struct sock *inet_accept(struct sock *sk, int flags, int *err)
{
    struct sock *newsk;

    // 从 accept 队列获取（可能阻塞等待）
    newsk = inet_csk_accept(sk, flags);
    if (!newsk)
        return NULL;

    // 复制连接信息
    newsk->sk_state = TCP_ESTABLISHED;
    return newsk;
}
```

---

## 6. 建立连接：connect()

### 6.1 API

```c
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
```

### 6.2 TCP connect 流程

```c
// net/socket.c
SYSCALL_DEFINE3(connect, int, sockfd, struct sockaddr *, uaddr, int, addrlen)
{
    struct socket *sock = sockfd_lookup(sockfd, &err);

    // TCP：三次握手开始
    if (sock->ops->connect) {
        err = sock->ops->connect(sock, uaddr, addrlen, sock->file->f_flags);
    }

    return err;
}

// inet_stream_connect（TCP 实现）
int inet_stream_connect(struct socket *sock, struct sockaddr *uaddr,
                        int addr_len, int flags)
{
    struct sock *sk = sock->sk;

    // 启动 TCP 三次握手
    err = tcp_v4_connect(sock->file, uaddr, addr_len);
    
    // 等待连接建立（可中断睡眠）
    current->state = TASK_INTERRUPTIBLE;
    schedule();
}
```

### 6.3 UDP connect

UDP 的 connect() 不建立连接，只是记录对端地址，后续 send/recv 不需再指定地址。

---

## 7. 发送数据：send()/sendto()/sendmsg()

### 7.1 API

```c
// send - 仅用于已连接 socket
ssize_t send(int sockfd, const void *buf, size_t len, int flags);

// sendto - 可指定目的地址（未连接 socket 必需）
ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
               const struct sockaddr *dest_addr, socklen_t addrlen);

// sendmsg - 高级用法，支持多缓冲区和 control message
ssize_t sendmsg(int sockfd, const struct msghdr *msg, int flags);
```

### 7.2 sendmsg 结构

```c
struct msghdr {
    void         *msg_name;       // 目的地址（可选）
    int           msg_namelen;    // 地址长度
    struct iovec *msg_iov;        // 缓冲区数组
    size_t        msg_iovlen;     // 缓冲区数量
    void         *msg_control;    // control message
    size_t        msg_controllen; // control message 长度
    int           msg_flags;       // 标志
};

struct iovec {
    void  *iov_base;  // 缓冲区指针
    size_t iov_len;   // 缓冲区长度
};
```

### 7.3 内核实现

```c
// net/socket.c
SYSCALL_DEFINE3(send, int, sockfd, void *, buff, size_t, len, unsigned int, flags)
{
    return sys_sendto(sockfd, buff, len, flags, NULL, 0);
}

SYSCALL_DEFINE6(sendto, int, sockfd, void *, buff, size_t, len,
                unsigned int, flags, struct sockaddr *, addr, int, addr_len)
{
    struct socket *sock = sockfd_lookup(sockfd, &err);

    // 协议特定的 sendmsg
    if (sock->ops->sendmsg)
        err = sock->ops->sendmsg(sock, (struct msghdr *) &msg, len);
    else
        err = sock->sk->sk_prot->sendmsg(sock->sk, &msg);

    return err;
}
```

### 7.4 flags 参数

| Flag | 说明 |
|------|------|
| MSG_OOB | 发送外带数据（TCP） |
| MSG_DONTROUTE | 跳过路由表 |
| MSG_DONTWAIT | 非阻塞 |
| MSG_EOR | 标记消息结束 |
| MSG_MORE | 还有更多数据 |
| MSG_NOSIGNAL | 不发送 SIGPIPE |
| MSG_CONFIRM | 确认对端收到 |

---

## 8. 接收数据：recv()/recvfrom()/recvmsg()

### 8.1 API

```c
// recv - 仅用于已连接 socket
ssize_t recv(int sockfd, void *buf, size_t len, int flags);

// recvfrom - 获取发送方地址
ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags,
                 struct sockaddr *src_addr, socklen_t *addrlen);

// recvmsg - 高级用法
ssize_t recvmsg(int sockfd, struct msghdr *msg, int flags);
```

### 8.2 内核实现

```c
// net/socket.c
SYSCALL_DEFINE6(recvfrom, int, sockfd, void *, ubuf, size_t, size,
                unsigned int, flags, struct sockaddr *, uaddr, int *, addr_len)
{
    struct socket *sock = sockfd_lookup(sockfd, &err);
    struct sk_buff *skb;

    // 从 socket 接收队列取数据（可能睡眠等待）
    skb = sock_dequeue(sock->sk, timeout);
    if (!skb)
        return -EAGAIN;

    // 复制到用户空间
    err = skb_copy_datagram_msg(skb, 0, msg, size);
    
    // 返回发送方地址
    if (uaddr) {
        struct sockaddr *addr = (struct sockaddr *)uaddr;
        addr->sa_family = skb->protocol;
        // 填充发送方地址
    }

    return size;
}
```

### 8.3 flags 参数

| Flag | 说明 |
|------|------|
| MSG_OOB | 接收外带数据 |
| MSG_PEEK | 窥视（不删除数据） |
| MSG_DONTWAIT | 非阻塞 |
| MSG_ERRQUEUE | 从错误队列接收 |
| MSG_TRUNC | 数据被截断 |
| MSG_WAITALL | 等待完整消息 |

---

## 9. 关闭：close()/shutdown()

### 9.1 close()

```c
int close(int sockfd);
```

关闭文件描述符，TCP 会发送 FIN 进入四次挥手流程。

### 9.2 shutdown()

```c
int shutdown(int sockfd, int how);
// how: SHUT_RD, SHUT_WR, SHUT_RDWR
```

关闭连接的读或写半边，但不释放 fd：

```c
// 关闭写端（发送 FIN）
shutdown(sockfd, SHUT_WR);

// 关闭读端（不再接收数据）
shutdown(sockfd, SHUT_RD);
```

### 9.3 两者区别

| close() | shutdown() |
|---------|------------|
| 释放文件描述符 | 仅关闭连接方向 |
| 引用计数减 1 | 立即生效 |
| 所有方向关闭 | 可选择只关读或写 |

---

## 10. Control Message（辅助数据）

### 10.1 用途

Control message 用于传递元数据（如文件描述符、凭证、TTL、TOS 等）。

### 10.2 发送 control message

```c
struct msghdr msg = {0};
struct cmsghdr *cmsg;
char cmsgbuf[CMSG_SPACE(sizeof(int))];  // 传送文件描述符
int fd_to_send = socket_fd;

msg.msg_control = cmsgbuf;
msg.msg_controllen = CMSG_SPACE(sizeof(int));

cmsg = CMSG_FIRSTHDR(&msg);
cmsg->cmsg_level = SOL_SOCKET;
cmsg->cmsg_type = SCM_RIGHTS;  // 传送文件描述符
cmsg->cmsg_len = CMSG_LEN(sizeof(int));
*((int *)CMSG_DATA(cmsg)) = fd_to_send;

sendmsg(sockfd, &msg, 0);
```

### 10.3 接收 control message

```c
struct msghdr msg = {0};
struct cmsghdr *cmsg;
char cmsgbuf[CMSG_SPACE(sizeof(int))];

msg.msg_control = cmsgbuf;
msg.msg_controllen = sizeof(cmsgbuf);

recvmsg(sockfd, &msg, 0);

for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
    if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
        int received_fd = *((int *)CMSG_DATA(cmsg));
        // 使用 received_fd
    }
}
```

### 10.4 常用 control message 类型

| Type | Level | 说明 |
|------|-------|------|
| SCM_RIGHTS | SOL_SOCKET | 传递文件描述符 |
| SCM_CREDENTIALS | SOL_SOCKET | 发送进程凭证 |
| IP_TTL | IPPROTO_IP | 发送 TTL |
| IP_PKTINFO | IPPROTO_IP | 接收包信息 |
| IPV6_PKTINFO | IPPROTO_IPV6 | IPv6 包信息 |
| SCM_TIMESTAMP | SOL_SOCKET | 时间戳 |

---

## 11. socketpair()

### 11.1 API

创建一对已连接的 socket（类似 pipe）：

```c
int socketpair(int domain, int type, int protocol, int sv[2]);

// 示例
int sv[2];
socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
write(sv[0], "hello", 5);
read(sv[1], buf, 5);  // 读到 "hello"
```

### 11.2 用于进程间通信

socketpair 创建的两个 fd 已连接，常用于父子进程通信或 Unix Domain Socket 传递。

---

## 12. getsockopt()/setsockopt()

### 12.1 API

```c
int getsockopt(int sockfd, int level, int optname, void *optval, socklen_t *optlen);
int setsockopt(int sockfd, int level, int optname, const void *optval, socklen_t optlen);
```

### 12.2 常用选项

```c
// SO_REUSEADDR - 复用地址
int opt = 1;
setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

// SO_REUSEPORT - 复用端口（多进程负载均衡）
setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

// SO_RCVBUF / SO_SNDBUF - 缓冲区大小
int rcvbuf = 256 * 1024;
setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

// SO_KEEPALIVE - TCP keepalive
opt = 1;
setsockopt(sockfd, SOL_SOCKET, SO_KEEPALIVE, &opt, sizeof(opt));

// SO_LINGER - close 时等待数据发送
struct linger ling = { .l_onoff = 1, .l_linger = 5 };
setsockopt(sockfd, SOL_SOCKET, SO_LINGER, &ling, sizeof(ling));
```

### 12.3 IP 层选项

```c
// IP_MTU_DISCOVER - 设置 Path MTU Discovery
int val = IP_PMTUDISC_DO;
setsockopt(sockfd, IPPROTO_IP, IP_MTU_DISCOVER, &val, sizeof(val));

// IP_MULTICAST_TTL - 多播 TTL
int ttl = 64;
setsockopt(sockfd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
```

---

## 13. 总结

| 系统调用 | 用途 |
|---------|------|
| socket() | 创建 socket |
| bind() | 绑定地址/端口 |
| listen() | 监听（服务器） |
| accept() | 接受连接 |
| connect() | 连接服务器 |
| send/sendto/sendmsg | 发送数据 |
| recv/recvfrom/recvmsg | 接收数据 |
| close() | 关闭 socket |
| shutdown() | 半关闭 |
| getsockopt/setsockopt | 设置选项 |
| socketpair() | 创建成对 socket |

Socket API 是 Unix 网络编程的基石，通过文件描述符抽象统一了网络 I/O 与文件系统 I/O。
