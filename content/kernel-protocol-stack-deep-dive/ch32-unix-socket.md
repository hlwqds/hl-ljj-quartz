---
title: "Kernel Protocol Stack 深度探索 (三十二)：Unix Domain Socket"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    unix-socket,
    af-unix,
    uds,
    ancillary-data,
    file-descriptor-passing,
    abstract-socket,
  ]
description: "深入解析 Unix Domain Socket——本地通信、AF_UNIX 协议、UDS 地址格式、文件描述符传递、ancillary data、抽象 socket 命名空间"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[kernel-protocol-stack-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. [[ch5-napi|第五章：NAPI 与轮询模式]]
> 6. [[ch6-ethernet|第六章：Ethernet 与 MAC 层]]
> 7. [[ch7-bridge|第七章：网桥与 Switchdev]]
> 8. [[ch8-vlan|第八章：VLAN 与 802.1Q]]
> 9. [[ch9-macvlan|第九章：MACVLAN 与虚拟网卡]]
> 10. [[ch10-bonding|第十章：Bonding 与 teamd]]
> 11. [[ch11-ip-framing|第十一章：IP 协议封装]]
> 12. [[ch12-routing|第十二章：路由与 FIB]]
> 13. [[ch13-neighbor|第十三章：Neighbor 与 ARP]]
> 14. [[ch14-iptables|第十四章：iptables 基础]]
> 15. [[ch15-conntrack|第十五章：连接跟踪 Conntrack]]
> 16. [[ch16-nat|第十六章：NAT 与地址转换]]
> 17. [[ch17-gre|第十七章：GRE 隧道协议]]
> 18. [[ch18-vxlan|第十八章：VXLAN 虚拟可扩展局域网]]
> 19. [[ch19-geneve|第十九章：GENEVE 通用网络虚拟化封装]]
> 20. [[ch20-fib-rules|第二十章：FIB Rules 转发规则]]
> 21. [[ch21-tcp-headers|第二十一章：TCP 头部结构]]
> 22. [[ch22-tcp-states|第二十二章：TCP 状态机]]
> 23. [[ch23-tcp-data-buffer|第二十三章：TCP 数据与缓冲管理]]
> 24. [[ch24-tcp-congestion|第二十四章：TCP 拥塞控制]]
> 25. [[ch25-tcp-advanced|第二十五章：TCP 高级特性]]
> 26. [[ch26-udp|第二十六章：UDP 协议实现]]
> 27. [[ch27-raw-socket|第二十七章：RAW Socket 与 ICMP]]
> 28. [[ch28-socket-api|第二十八章：Socket API 概述]]
> 29. [[ch29-inet-sock|第二十九章：Inet Socket 实现]]
> 30. [[ch30-sock-mem|第三十章：Socket 内存管理]]
> 31. [[ch31-netlink|第三十一章：Netlink 通信机制]]
> 32. **第三十二章：Unix Domain Socket**

---

## 1. 概述

Unix Domain Socket（UDS，AF_UNIX）是运行在同一台主机上的进程间通信（IPC）机制。与网络 socket 不同，UDS 不经过网络协议栈，数据直接在内核中传递，效率更高。

主要特点：

- 同一主机进程间通信，无需网络
- 支持流式（SOCK_STREAM）和数据报（SOCK_DGRAM）两种模式
- 支持文件描述符传递（ancillary data）
- 支持抽象命名空间（无需文件系统路径）

---

## 2. 地址格式

### 2.1 sockaddr_un 结构

```c
#include <sys/un.h>

struct sockaddr_un {
    sa_family_t sun_family;   // 固定为 AF_UNIX
    char        sun_path[108]; // 文件系统路径（以空字符结尾）
};
```

### 2.2 两种地址类型

```
1. 文件系统路径：
   /tmp/my_socket
   /var/run/dbus/system_bus_socket

2. 抽象命名空间（以 '\0' 开头）：
   \0/tmp/my_socket
   \0@org.freedesktop.DBus
```

### 2.3 绑定示例

```c
// 文件系统 socket
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
strcpy(addr.sun_path, "/tmp/my_socket");
bind(sock, (struct sockaddr *)&addr, sizeof(addr));

// 抽象 socket（以空字符开头）
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
addr.sun_path[0] = '\0';  // 必须以空字符开头
strcpy(addr.sun_path + 1, "my_abstract_socket");
bind(sock, (struct sockaddr *)&addr, sizeof(addr));
```

---

## 3. 创建与使用

### 3.1 socket() 创建

```c
#include <sys/socket.h>
#include <sys/un.h>

int sock = socket(AF_UNIX, SOCK_STREAM, 0);
// 或 SOCK_DGRAM

// 绑定地址
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
strcpy(addr.sun_path, "/tmp/server_socket");
bind(sock, (struct sockaddr *)&addr, sizeof(addr));

// 监听
listen(sock, 5);

// 接受连接
int client = accept(sock, NULL, NULL);
```

### 3.2 客户端连接

```c
int sock = socket(AF_UNIX, SOCK_STREAM, 0);
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
strcpy(addr.sun_path, "/tmp/server_socket");

connect(sock, (struct sockaddr *)&addr, sizeof(addr));
send(sock, "hello", 5, 0);
```

### 3.3 数据报模式

```c
// 服务端
int sock = socket(AF_UNIX, SOCK_DGRAM, 0);
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
strcpy(addr.sun_path, "/tmp/uds_dgram");
bind(sock, (struct sockaddr *)&addr, sizeof(addr));

char buf[256];
recvfrom(sock, buf, sizeof(buf), 0, NULL, NULL);

// 客户端
int sock = socket(AF_UNIX, SOCK_DGRAM, 0);
struct sockaddr_un server_addr;
server_addr.sun_family = AF_UNIX;
strcpy(server_addr.sun_path, "/tmp/uds_dgram");

sendto(sock, "ping", 4, 0, (struct sockaddr *)&server_addr, sizeof(server_addr));
```

---

## 4. 内核实现

### 4.1 unix_sock 结构

```c
// include/net/unix.h
struct unix_sock {
    struct sock         sk;
    struct unix_address *addr;        // 绑定地址
    struct dentry       *dentry;       // 文件系统入口（文件系统路径类型）
    struct file         *peer;         // 连接对端

    // 等待队列
    struct sk_buff_head  link_queue;   // 数据报队列（SOCK_DGRAM）
    struct sk_buff_head  message_queue; // 消息队列
    struct mutex        readlock;

    // 凭证传递
    struct pid          *peer_pid;     // 对端 PID
    struct cred         *peer_cred;    // 对端凭证

    // 状态
    long                state;         // 连接状态
    unsigned long       gc_candidate;   // GC 候选
    bool                gc_poll_flag;
};

static const struct proto_ops unix_stream_ops = {
    .family         = PF_UNIX,
    .bind           = unix_bind,
    .connect        = unix_stream_connect,
    .socketpair     = unix_socketpair,
    .accept         = unix_accept,
    .sendmsg        = unix_sendmsg,
    .recvmsg        = unix_recvmsg,
    .poll           = unix_poll,
    .listen         = unix_listen,
};

static const struct proto_ops unix_dgram_ops = {
    .family         = PF_UNIX,
    .bind           = unix_bind,
    .socketpair     = unix_socketpair,
    .sendmsg        = unix_dgram_sendmsg,
    .recvmsg        = unix_dgram_recvmsg,
    .poll           = unix_poll,
};
```

### 4.2 unix_sock 链表

```c
// net/unix/af_unix.c
static HLIST_HEAD(unix_sk_list);  // 所有 Unix socket 的哈希表
static DECLARE_WAIT_QUEUE_HEAD(unix_waitq);

// socket 查找（通过路径）
struct sock *unix_find_by_path(struct sockaddr_un *sunname, int path_len)
{
    struct hlist_nulls_node *node;
    struct sock *u;

    // 遍历哈希表查找匹配路径的 socket
    sk_nulls_for_each_rcu(u, node, &unix_sk_list) {
        struct unix_sock *up = unix_sk(u);
        if (up->addr && path_len == up->addr->len &&
            memcmp(up->addr->name, sunname, path_len) == 0)
            return u;
    }
    return NULL;
}
```

### 4.3 accept() 实现

```c
// net/unix/af_unix.c
static struct sock *unix_accept(struct socket *sock, int flags)
{
    struct sock *sk = sock->sk;
    struct sock *newsk;

    // 从连接队列取一个等待中的连接
    if (sock->state == SS_UNCONNECTED)
        return NULL;

    newsk = unix_dequeue_connect(sk);
    if (!newsk)
        return NULL;

    // 更新状态
    newsk->sk_state = TCP_ESTABLISHED;
    newsk->sk_peer_pid = get_pid(current->pid);

    return newsk;
}
```

---

## 5. 文件描述符传递

### 5.1 原理

通过 `sendmsg()` 的 ancillary data（control message）可以传递文件描述符到另一个进程，实现 IPC。

```
进程 A                    进程 B
  │                         │
  │  socketpair() 创建       │
  │───── pair[0] ───────────│
  │───── pair[1] ───────────│
  │                         │
  │  SCM_RIGHTS              │
  │  sendmsg(pair[0], FD)   │──────► 进程 B 获得 FD 的副本
  │                         │
```

### 5.2 发送文件描述符

```c
int sender_fd = open("/etc/passwd", O_RDONLY);
int usock = socket(AF_UNIX, SOCK_STREAM, 0);

struct msghdr msg = {0};
struct cmsghdr *cmsg;
char cmsgbuf[CMSG_SPACE(sizeof(int))];

msg.msg_control = cmsgbuf;
msg.msg_controllen = sizeof(cmsgbuf);

cmsg = CMSG_FIRSTHDR(&msg);
cmsg->cmsg_level = SOL_SOCKET;
cmsg->cmsg_type = SCM_RIGHTS;
cmsg->cmsg_len = CMSG_LEN(sizeof(int));
*((int *)CMSG_DATA(cmsg)) = sender_fd;

msg.msg_controllen = cmsg->cmsg_len;

sendmsg(usock, &msg, 0);
close(sender_fd);  // 发送后仍保留引用，直到 socket 关闭
```

### 5.3 接收文件描述符

```c
int usock = accept(listen_sock, NULL, NULL);

char cmsgbuf[CMSG_SPACE(sizeof(int))];
struct msghdr msg = {0};
struct cmsghdr *cmsg;

msg.msg_control = cmsgbuf;
msg.msg_controllen = sizeof(cmsgbuf);

recvmsg(usock, &msg, 0);

for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
    if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
        int received_fd = *((int *)CMSG_DATA(cmsg));
        // 使用 received_fd（已自动 dup）
        read(received_fd, buf, sizeof(buf));
        close(received_fd);
    }
}
```

### 5.4 内核传递实现

```c
// net/unix/af_unix.c
static int unix_attach_fds(struct msghdr *msg, struct sock *sk)
{
    struct sk_buff *skb;
    struct unix_sock *u = unix_sk(sk);
    struct scm_fp_list *fpl = NULL;
    struct cmsghdr *cmsg;
    int i;

    // 从 ancillary data 提取 FD 列表
    for (cmsg = CMSG_FIRSTHDR(msg); cmsg; cmsg = CMSG_NXTHDR(msg, cmsg)) {
        if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS)
            continue;

        fpl = (struct scm_fp_list *)CMSG_DATA(cmsg);
        break;
    }

    // 复制 FD 列表到 skb
    skb = alloc_skb(0, GFP_KERNEL);
    skb->sk = sk;

    // 对每个 FD，增加引用计数并放入 skb
    for (i = 0; i < fpl->len; i++) {
        skb->original_sk[i] = get_file(fpl->fp[i]);
    }
}
```

---

## 6. 凭证传递（SCM_CREDENTIALS）

### 6.1 发送进程凭证

```c
struct msghdr msg = {0};
struct ucred cred = {
    .pid = getpid(),
    .uid = getuid(),
    .gid = getgid(),
};

msg.msg_control = &cred;
msg.msg_controllen = sizeof(cred);

// 或使用 cmsg
struct cmsghdr *cmsg;
char cmsgbuf[CMSG_SPACE(sizeof(struct ucred))];

cmsg = CMSG_FIRSTHDR(&msg);
cmsg->cmsg_level = SOL_SOCKET;
cmsg->cmsg_type = SCM_CREDENTIALS;
cmsg->cmsg_len = CMSG_LEN(sizeof(struct ucred));
*((struct ucred *)CMSG_DATA(cmsg)) = cred;
```

### 6.2 接收进程凭证

```c
struct msghdr msg = {0};
struct ucred cred;
char cmsgbuf[CMSG_SPACE(sizeof(cred))];

msg.msg_control = cmsgbuf;
msg.msg_controllen = sizeof(cmsgbuf);

recvmsg(sock, &msg, 0);

for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
    if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_CREDENTIALS) {
        struct ucred *ucred = (struct ucred *)CMSG_DATA(cmsg);
        printf("PID=%d UID=%d GID=%d\\n",
               ucred->pid, ucred->uid, ucred->gid);
    }
}
```

---

## 7. 抽象命名空间

### 7.1 与文件系统路径对比

| 特性     | 文件系统路径   | 抽象命名空间       |
| -------- | -------------- | ------------------ |
| 生命周期 | 与文件相同     | 与进程生命周期相同 |
| 清理     | 需要 unlink    | 自动清理           |
| 权限     | 文件系统权限   | 无权限限制         |
| 可见性   | 所有进程       | 仅同命名空间进程   |
| 位置     | /tmp, /var/run | 内存中             |

### 7.2 使用场景

```c
// DBus 使用抽象 socket
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
addr.sun_path[0] = '\0';  // 抽象命名空间标志
strcpy(addr.sun_path + 1, "/org/freedesktop/DBus");
bind(sock, (struct sockaddr *)&addr, sizeof(addr));
```

### 7.3 自动清理

当进程退出时，绑定到抽象命名空间的 socket 自动被内核清理，无需手动删除文件。

---

## 8. SOCK_SEQPACKET

### 8.1 概述

SOCK_SEQPACKET 提供面向连接的序列化数据包，兼具 SOCK_STREAM 和 SOCK_DGRAM 的特点：

- 面向连接（需先 connect/listen/accept）
- 保留消息边界（不合并/分片）
- 有序、可靠传输

### 8.2 使用示例

```c
// 服务端
int sock = socket(AF_UNIX, SOCK_SEQPACKET, 0);
struct sockaddr_un addr;
addr.sun_family = AF_UNIX;
strcpy(addr.sun_path, "/tmp/seqpacket");
bind(sock, (struct sockaddr *)&addr, sizeof(addr));
listen(sock, 5);

// 接收消息（保留边界）
int client = accept(sock, NULL, NULL);
char buf[1024];
int len = recv(client, buf, sizeof(buf), 0);
// len 精确等于发送方一次 send 的字节数
```

---

## 9. vs 网络 Socket

### 9.1 性能对比

| 特性     | Unix Domain Socket     | 网络 Socket (127.0.0.1) |
| -------- | ---------------------- | ----------------------- |
| 数据路径 | 内核直接传递           | 仍经过网络协议栈        |
| 拷贝次数 | 2 次（用户→内核→用户） | 2 次（相同）            |
| 延迟     | ~1-2 μs                | ~3-5 μs                 |
| 吞吐量   | 更高                   | 略低                    |
| 资源消耗 | 更少                   | 略多                    |

### 9.2 使用场景

- 同一主机内进程通信：UDS
- 跨主机通信：网络 socket
- 需要传递文件描述符：UDS
- 需要保留消息边界：SOCK_SEQPACKET 或 SOCK_DGRAM

---

## 10. 调试命令

### 10.1 /proc 接口

```bash
# 查看 Unix socket 统计
cat /proc/net/unix

# 示例输出
Num       RefCount Protocol Flags    Type St Conn  Num Peti Fin，声
00000000D5A3D782: 00000002 00000000 00000000 00000001 00000000 00000001 00000000
00000000E0B5C3D8: 00000002 00000000 00000000 00000001 00000000 00000000 00000000

# 查看 FD 指向的 socket
ls -la /proc/<pid>/fd | grep socket
```

### 10.2 ss 命令

```bash
# 查看 Unix socket
ss -x

# 示例输出
State      Recv-Q  Send-Q  Local Address:Port   Peer Address:Port
ESTAB      0       0       /tmp/server.sock    /tmp/client.sock
```

---

## 11. 总结

| 特性            | 说明                       |
| --------------- | -------------------------- |
| AF_UNIX         | 本地进程通信协议族         |
| SOCK_STREAM     | 面向连接流式（类似 TCP）   |
| SOCK_DGRAM      | 无连接数据报（类似 UDP）   |
| SOCK_SEQPACKET  | 面向连接数据包（保留边界） |
| SCM_RIGHTS      | 文件描述符传递             |
| SCM_CREDENTIALS | 进程凭证传递               |
| 抽象命名空间    | 以 `\0` 开头的地址         |

Unix Domain Socket 是 Linux 本地 IPC 的核心机制，文件描述符传递和抽象命名空间使其在系统服务（如 DBus、systemd）间通信中扮演关键角色。
