---
title: "F429 × Korvo-1（六）：数据通道——socket 代理 RPC 与 mini socket API"
date: 2026-10-10 12:00:00
description: "把 socket 搬过 SPI：代理模型的总图（socket 表/句柄映射/RPC 语义）、六条 socket 命令（OPEN/CONNECT/SEND/RECV/CLOSE + 事件通知）与状态、背压三闸门（S3 接收水位/链路在途/F429 缓冲水位）、半关闭与错误传播语义；F429 侧 ws_* mini socket API 的函数表与阻塞模型。内存回环传输层上全链路仿真实测。"
tags: [wifi, spi, socket, rpc, coprocessor, series]
---

> [!info] WiFi 协处理器实战 0. [[wifi-coproc|系列索引]] 1. [[ch01-coproc-architecture|第一章]] … 5. [[ch05-control-protocol|第五章]] 6. **第六章：数据通道——socket 代理**

# F429 × Korvo-1（六）：数据通道——socket 代理 RPC 与 mini socket API

控制通道管"配置"，数据通道管"吞吐"——HTTP 下载、MQTT 长连、NTP 查询的每个字节都从这里过河。这一章是本系列的工程重心：代理模型总图（6.1）、命令语义（6.2）、背压三闸门（6.3）、F429 侧 API（6.4）。做完这章，F429 的应用代码已经可以"假装自己有网卡"。

---

## 6.1 模型总图：一张 socket 表，两个世界

S3 侧维护一张 **socket 表**：`[sock_id → 真实 BSD socket + 状态 + 接收缓冲水位]`；F429 侧拿到的"socket 句柄"就是 sock_id（从 1 起，S3 分配、生命周期由 F429 通过命令管理）。所有操作都是 ch05 帧上的 RPC，数据走独立的**数据帧**（ch03 的 type=DATA）大块流动：

```text
F429 应用             F429 侧代理              SPI/UART 链路            S3 侧服务
    │                    │                        │                      │
ws_connect(ip:80) ─▶ SOCK_CONNECT(sock,ip:80) ──控制帧──▶ 真实 connect()
    │                    ◀───────────── SOCK_RESULT(status) ────────────┤
ws_send(buf)      ─▶ SOCK_DATA(sock, bytes)    ──数据帧──▶ write()
    │                    ◀──── SOCK_DATA_EVENT(sock, bytes) ◀── read() ─┤
ws_recv() ◀──────────────┘（从本地缓冲取出；不够则阻塞/轮询等事件）
```

## 6.2 命令语义：六条与状态机

在 ch05 的 TLV 框架上扩一组 `0x20` 段命令：

| cmd                                     | 语义            | 关键细节                                                   |
| --------------------------------------- | --------------- | ---------------------------------------------------------- |
| SOCK_OPEN                               | 创建（TCP/UDP） | S3 分配 sock_id 回传；并发上限 8（表大小，也是 RAM 账）    |
| SOCK_CONNECT                            | 连接/绑定       | TCP 显式 connect；UDP 用它设默认对端（sendto 语义则免）    |
| SOCK_SEND                               | 发数据          | 请求带 sock_id+数据（≤460B/帧，大块自动分帧）              |
| SOCK_RECV                               | 主动拉取        | 正常路径用事件推（下条），此命令做"水位补充"与调试         |
| SOCK_CLOSE                              | 关闭            | 半关闭语义：CLOSE 后 S3 的 FD 关闭，缓冲里未取数据仍可拉完 |
| （事件）SOCK_DATA / SOCK_EOF / SOCK_ERR | S3 主动推       | 有数据/对端关闭/错误码传播——事件帧复用 ch05 的 0x40 空间   |

**错误传播语义**要单独立规矩：S3 的 errno 跨河映射为协议 status（ENOENT→无此 sock_id、ECONNRESET→对端复位…），F429 的 API 以返回码还原——**远端失败必须像本地失败一样可编程处理**，否则应用没法写健壮。

## 6.3 背压三闸门：快产慢销的解法

代理链路的天生矛盾：**WiFi 收得快，SPI 送得慢，F429 吃得可能更慢**。没有背压的结局是 S3 内存涨爆。三道闸门从上游到下游：

1. **S3 接收缓冲水位**：每个 socket 的 RX 缓冲设高水位（如 8 KB）；超过则**停止读取该 FD**（TCP 下内核窗口自动收缩，源头自然减速——TCP 自带端到端背压，借力打力）；降到低水位恢复读。
2. **链路在途上限**：S3 的帧发送队列设深度上限（如 32 帧）；排队满则新收的数据暂留 socket 缓冲——闸门 1 已经保证它不会无限涨。
3. **F429 应用消费**：`ws_recv()` 取走数据才腾出本地缓冲；应用不消费，闸门 2 迟早顶住，整条链路自然降速到消费者速率。

**慢消费者问题在分布式链路里的通用解法就是"让背压逐级回传到源头"**——这里源头是 TCP 滑动窗口，免费且精确。UDP 则没有这待遇：超水位的 UDP 包直接丢并计数（应用层自愈），这也是"TCP 隧道化、UDP 有损化"的务实取舍。

## 6.4 F429 侧 API：ws\_\* 家族

给应用的门面，签名刻意贴着 BSD 走（移植成本最低）：

```c
int  ws_socket(int type);                      /* SOCK_STREAM / SOCK_DGRAM */
int  ws_connect(int sid, const uint8_t ip[4], uint16_t port);
int  ws_send(int sid, const void *buf, size_t len);   /* 阻塞至全部入队 */
int  ws_recv(int sid, void *buf, size_t len);         /* 阻塞；0=EOF；<0=errno 映射 */
int  ws_close(int sid);
int  ws_dns(const char *name, uint8_t ip[4]);         /* ch05 DNS 的门面 */
```

阻塞模型对裸机 F429 的实现：`ws_recv` 无数据时挂起当前"逻辑块"——裸机下可以用 [[f429-lab|F429 实验室]]ch15 的轮转调度把每个连接当一个任务；不想上调度就提供非阻塞版 `ws_poll`。**API 的阻塞语义与宿主调度模型的匹配**，是移植这层时最后一块拼图。

> [!tip] 🧪 配套实验：wifi-coproc-labs/ch06-sockproxy
> 代理层全链路仿真：内存回环传输层（对接 ch03 帧层）+ 假想"S3 服务端"（echo 模式：SOCK*DATA 来什么回什么）+ F429 侧 ws*\* API——跑通 socket 生命周期（open→connect→send/recv×N→EOF→close）、分帧重组、错误码映射与背压水位触发，真实运行留 run.log。S3 侧真实 socket 服务的骨架代码随工程附上（待板）。源码直达：[sockproxy.c（代码浏览）](/static/code/#/wifi-coproc-labs/ch06-sockproxy/sockproxy.c)、[完整工程](/static/code/#/wifi-coproc-labs/ch06-sockproxy/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/wifi-coproc-labs/ch06-sockproxy)。

## 6.5 小结

- 代理模型一张表：sock_id 由 S3 分配、生命周期由 F429 驱动；控制帧管命令、数据帧管吞吐，事件帧管通知。
- 六条命令 + 三个事件；错误码跨河映射——远端失败要像本地失败一样可编程。
- 背压三闸门逐级回传：S3 水位停读 → 借 TCP 窗口从源头减速；链路在途上限；F429 消费速率兜底。UDP 无背压可借，超水即丢 + 计数。
- ws\_\* API 贴 BSD 签名；阻塞语义要和宿主调度模型（轮转任务或 ws_poll）对表。
- 仿真传输层上全链路已实测；真机只换传输层实现，协议零改动——分层的红利。

至此零件全部到齐。下一章总装第一个真应用：NTP 校时（UDP 一问一答）+ HTTP 文件下载（TCP 流 + 分片 + 校验）——用两个最经典的应用验收整条链路，并和 F429 以太网直连（ch20/21）的基线做一次吞吐对照。[[ch07-first-app|第七章：总装首个应用]]。
