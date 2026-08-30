---
title: 裸机 lwIP：不带 OS 的协议栈
date: 2026-08-30 05:05:00
description: F429 裸机实验室（廿一）——NO_SYS=1 轮询模型亲手移植 lwIP，静态 IP 直连树莓派发第一声 ARP（tcpdump 亲眼看到 Linux 回答），ping 双向通，再升级 FreeRTOS 模型对照
tags: [STM32, lwIP, Network, Lab]
---

# 裸机 lwIP：不带 OS 的协议栈

> **状态声明**：本章属「先成文、后实跑」——移植设计、API 用法、预期输出均已写定，但**尚未在真机上执行**；
> 所有「预期输出」（含 tcpdump 抓包格式）均为**待实测核销的推导格式**，字段逐个给出推导依据，不装成
> 真跑截图。lwIP API 以源码与官方文档为准；板上事实沿用 ch20 待核对清单。方法论继承
> [[2026-08-30-stm32f429-brick-rescue-debug-story|序章]]。

## 本章装备清单

| 分类     | 装备                   | 价格/状态 | 用途                                         |
| -------- | ---------------------- | --------- | -------------------------------------------- |
| 已有     | 挑战者 F429-V2 板      | ✅        | 实验主体：板载以太网口是本章全部戏份         |
| 已有     | 野火 DAP + Mini-USB 线 | ✅        | 烧录固件 + 串口看打印                        |
| 已有     | 树莓派 4B + 网线       | ✅        | 网络对端：应答 ARP、当 ping 靶机、跑 tcpdump |
| 已有     | 笔记本                 | ✅        | 编译构建 + 串口终端                          |
| 建议购买 | 备用网线（短，~0.5m）  | ~¥5       | 板↔RPi 直连更整洁，不占路由器口              |

> 本章是以太网收束章：**网线 + RPi 是硬需求**——没有对端，第一声 ARP 无人应答，仪式无法举行。

## 本章会遇到的词（新词预览）

| 词                               | 一句话预览                                          | 谁的主场   |
| -------------------------------- | --------------------------------------------------- | ---------- |
| lwIP                             | 嵌入式世界的轻量 TCP/IP 协议栈，ESP32 用的就是它    | 嵌入式新知 |
| NO_SYS                           | lwIP 的无 OS 配置：没有线程，主循环轮询             | 嵌入式新知 |
| pbuf                             | lwIP 的包缓冲结构（sk_buff 的极简远房亲戚）         | 嵌入式新知 |
| netif                            | lwIP 的网络接口抽象（一块网卡的软件代表）           | 嵌入式新知 |
| ethernetif                       | 移植层粘合文件：把协议栈挂到真硬件                  | 嵌入式新知 |
| raw API                          | lwIP 最底层的回调式 API，无 OS 也能用               | 嵌入式新知 |
| 描述符环 / OWN 位                | ETH DMA 的收发工作队列与所有权标记（ch20 成果）     | 嵌入式新知 |
| RMII / MAC / PHY                 | 芯片内控制器与外部物理层芯片的连线约定（回勾 ch20） | 嵌入式新知 |
| CCM                              | F429 内核私有高速 RAM，DMA 看不见（选址大坑）       | 嵌入式新知 |
| DWT / CYCCNT                     | Cortex-M 内核自带的 CPU 周期计数器（裸机秒表）      | 嵌入式新知 |
| tcpip_thread / sys_arch          | NO_SYS=0 时代的协议栈专属线程 + OS 适配层           | 嵌入式新知 |
| ARP / ICMP / MTU / DHCP / socket | 你的主场——本章只看它们在裸机世界的长相              | 你的主场   |

## 目标（先说结论）

- lwIP 主系列（ESP32 侧 24 章）拆的是**乐鑫配好的一台整机**；本章把同一颗协议栈**拆散了亲手装到裸机
  上**：源码自己克隆、`lwipopts.h`（lwIP 的编译期裁剪配置头——全栈每个功能一个开关）自己裁、`ethernetif`
  （连接协议栈与真硬件的移植层文件）自己写、定时器自己喂——补齐「乐鑫替你配好」的那块拼图。
- 三步走：①**NO_SYS=1 轮询模型**（main 循环=事件循环）；②静态 IP 直连 RPi 发第一声 ARP——**RPi 侧
  tcpdump 亲眼看到 F429 的请求被 Linux 回答**，全系列最具仪式感的一刻；③ping 双向通（F429 侧是手搓的 ICMP echo）。
- 升级实验：切 **NO_SYS=0 + FreeRTOS**（RTOS=实时操作系统内核，给裸机补上线程/队列/信号量），一张代码结构对照表看清两种模型的分界线——就是 IDF 与裸机的差异清单。

> 📖 **术语卡：lwIP**
> **是什么**：Lightweight IP，为嵌入式设备写的开源 TCP/IP 协议栈（作者 Adam Dunkels），小内存 MCU 的事实标准。
> **为什么存在**：Linux 协议栈深度耦合内核、依赖 MMU；几十 KB RAM 的芯片也需要 TCP/IP，lwIP 把整栈写成可裁剪的独立 C 库。
> **类比**：把内核网络子系统抽出来做成可移植库——sk_buff 换成 pbuf，softirq 换成轮询/邮箱。
> ⚠️ 类比边界：lwIP 不是 Linux 栈的裁剪版，是独立实现；默认参数（定时器节拍、TCP 行为）更保守，吞吐天花板也更低。

> 📖 **术语卡：lwIP 的 NO_SYS 模式**
> **是什么**：lwIP 的无操作系统配置：没有线程/信号量，主循环轮询收包、回调处理。
> **为什么存在**：小到没有 RTOS 的芯片也要用 TCP/IP。
> **类比**：单线程 reactor 事件循环——一个 while 循环喂所有连接。
> ⚠️ 类比边界：reactor 有 epoll 帮忙等事件，NO_SYS 靠主循环死轮询网卡。

## 系统侧类比：单线程 reactor

| lwIP 侧                          | 系统侧对应（读者已熟）                       |
| -------------------------------- | -------------------------------------------- |
| NO_SYS=1 的 main 循环            | 单线程事件循环（libuv/redis 的事件驱动内核） |
| `ethernetif_poll()` 轮询描述符环 | `epoll_wait` 返回可读事件                    |
| raw API 回调（`udp_recv` 等）    | reactor 的读就绪回调——**回调即临界区**       |
| `sys_check_timeouts()`           | 事件循环的 timeout 参数：顺路处理到期定时器  |
| NO_SYS=0 的 `tcpip_input` 邮箱   | 工作线程队列：回调挪进专用线程执行           |

「第三弹」顿悟：ARP、Dhcp、ICMP、MTU（最大传输单元——你的主场，裸机上它就是 `netif->mtu = 1500`
一行代码）——这些你在 RPi/服务器上天天配的东西，在裸机上是你**亲手
发出去的第一批字节**；42 字节里 14 字节以太头是你 ethernetif 填的，28 字节 ARP 是 lwIP 的
`etharp_output`（IP 出口→以太帧的翻译官，顺带管 ARP 缓存）填的——分界线清清楚楚。

> ⚠️ **类比边界**：事件循环的 `epoll_wait(timeout)` 会睡到有事件或超时；NO_SYS 的主循环是纯忙轮询，
> CPU 100% 花在「问网卡有了吗」上。要省 CPU/省电只能靠中断唤醒（升级实验的方向）——这是两种模型的
> 本质差价。

## 第〇步：源码与移植层三件套

lwIP 源码本机暂无（`~/stm32` 下只有 FreeRTOS/CMSIS），按与主系列一致的版本取：

```bash
git clone https://git.savannah.gnu.org/git/lwip.git ~/stm32/lwip   # 或 GitHub 镜像 lwip-tcpip/lwip
cd ~/stm32/lwip && git checkout STABLE-2_2_0_RELEASE              # 与主系列 2.2.0-dev 同族
```

**命令拆解：** 源码获取两连

| 部分                                | 作用                                                                    |
| ----------------------------------- | ----------------------------------------------------------------------- |
| `git clone <url> ~/stm32/lwip`      | 把 lwIP 仓库克隆到 `~/stm32/lwip`（Savannah 是 lwIP 的官方老家）        |
| `git checkout STABLE-2_2_0_RELEASE` | 切到 2.2.0 稳定发布标签——与主系列（IDF 内的 2.2.0-dev）同族，行为可对照 |
| 注释里的 GitHub 镜像                | Savannah 拉不动时的替代源 `lwip-tcpip/lwip`，同一仓库的镜像             |

> 📖 **术语卡：ethernetif——协议栈与硬件之间的移植层**
> **是什么**：lwIP 圈约定俗成的移植文件名：实现收帧（low_level_input）、发帧（low_level_output）、初始化挂接（ethernetif_init）三件套，把 netif 挂到真网卡上。
> **为什么存在**：协议栈要硬件无关，总得有个文件替它「会说硬件话」；ESP32 上乐鑫替你写好的 wlanif.c 干的就是这活。
> **类比**：内核网卡驱动的 probe/open/ndo_start_xmit 那一层，只是薄得多——本章约 100 行。
> ⚠️ 类比边界：内核有 NAPI/软中断整套收包框架分层，ethernetif 没有框架，收包时机全由你的主循环/中断决定。

乐鑫 fork 的 contrib（ports/）不用——裸机自己写三件：`cc.h`（小端字节序+`PACK_STRUCT`，约 20 行）、
`lwipopts.h`（裁剪配置，见下表）、`ethernetif.c`（low_level 三件套，直接吃 ch20 的描述符环，约
100 行）。阶段一（NO_SYS=1）关键项：

| 项                                      | 值       | 理由                                                                         |
| --------------------------------------- | -------- | ---------------------------------------------------------------------------- |
| `NO_SYS`                                | 1        | 无 OS：没有线程/邮箱/信号量，主循环即世界                                    |
| `LWIP_IPV4/LWIP_ARP/LWIP_ICMP/LWIP_RAW` | 1        | ARP+ICMP 是阶段②③的主角，raw（lwIP 最底层的回调式 API）是手搓 ping 的通道    |
| `MEM_SIZE`                              | 16\*1024 | mem 堆（pbuf 结构壳等小对象）；静态数组落 .bss（SRAM）                       |
| `PBUF_POOL_SIZE`                        | 8        | 收帧池：8×(1536+头)≈12.5KB，环深 4 的两倍余量                                |
| `LWIP_NETCONN/LWIP_SOCKET/DHCP`         | 0→升级开 | netconn/socket（你的主场：BSD socket 风格）需要 OS 层；DHCP 阶段②③ 用静态 IP |

内存选址一条铁律（ch05 埋的雷、ch13 实证的坑）：**pbuf 池、mem 堆、描述符、帧缓冲全部落 SRAM
（.bss，未初始化静态数据段），CCM（Core Coupled Memory：F429 内核私有的 64KB 高速 RAM，DMA 总线
根本连不到它）一字节都不给**——它们要被 ETH DMA 直接读写。「堆选址是拓扑决策」就此兑现。

> 📖 **术语卡：描述符环——ETH DMA 的工作队列**
> **是什么**：一串固定格式的描述符（状态位+长度+缓冲区地址）首尾相接成环，CPU 和 ETH 外设的 DMA 各持一个游标；每个描述符的 OWN 位标记「这个槽现在谁说了算」。
> **为什么存在**：MAC 外设的 DMA 不懂 malloc，只认预先铺好的地址表——收发包变成「填描述符+推游标」，零动态内存。
> **类比**：virtio 的 vring：设备与 CPU 共享一个环、靠所有权位交接缓冲——思想一模一样。
> ⚠️ 类比边界：vring 有完整的内存屏障与通知语义；这里靠手册规定的访问顺序，且要自己保证缓冲落在 DMA 可达的 SRAM（上面那条铁律）。

> 📖 **术语卡：pbuf——lwIP 的包缓冲**
> **是什么**：lwIP 里所有包的载体：一个小结构体（长度、payload 指针、next 指针）+ 数据区；大包由多个 pbuf 串成链。三种来源：PBUF_POOL（固定大小池，收包主力）、PBUF_RAM（mem 堆分配，发包拼装）、PBUF_ROM（指向只读数据，零拷贝）。
> **为什么存在**：嵌入式没有伙伴系统/页面池，lwIP 用预分配策略换内存可预测——MEM_SIZE 与 PBUF_POOL_SIZE 在编译期就定死。
> **类比**：sk_buff 的极简远房亲戚：同样「元数据+数据」分离、同样支持链式拼装。
> ⚠️ 类比边界：sk_buff 可以随意 realloc/线性化/克隆；pbuf 尽量不挪数据，跨层要么链要么拷贝（17.4 的拷贝派/引用派之争）。

## 第一步：NO_SYS=1 轮询模型 bring-up

> 📖 **术语卡：RMII——MAC 与 PHY 之间的精简总线**
> **是什么**：Reduced Media Independent Interface：芯片内以太网控制器（MAC，F429 内置）与外部物理层芯片（PHY，如 LAN8720，管线上电气信号）之间的标准连线：约 7 根信号线 + 一根共享 50MHz REF_CLK，比老 MII 的 16 根省一半引脚（细节回勾 ch20）。
> **为什么存在**：MAC 与 PHY 通常分属两颗硅（数字控制器 vs 模拟前端），需要标准化接口才能任意搭配。
> **类比**：CPU 与网卡之间的 PCIe 之于服务器——芯片间标准互连，谁家产品都能对接。
> ⚠️ 类比边界：PCIe 有枚举与链路训练协商；RMII 是裸并行线，REF_CLK 相位/来源配错就整链静默死——待核对 #2 的头号嫌疑。

```c
/* ---------- main.c：无 OS 的全部「线程」就是这个循环 ---------- */
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"
#include "netif/ethernet.h"
#include "ethernetif.h"          /* 自写极简版 */
static struct netif g_netif;

int main(void)
{
    clock_init(); uart_init();
    eth_hw_init();               /* ch20 成果：时钟+RMII+描述符环+MAC 地址+DMA 开张 */
    lwip_init();                 /* NO_SYS 下没有 tcpip_init——它就是全部初始化 */

    ip4_addr_t ip, nm, gw;       /* 与 RPi 直连网段（RPi 侧同段静态地址，见下文） */
    IP4_ADDR(&ip, 10,42,0,10); IP4_ADDR(&nm, 255,255,255,0); IP4_ADDR(&gw, 10,42,0,20);
    netif_add(&g_netif, &ip, &nm, &gw, NULL, ethernetif_init, ethernet_input);
    /* ↑ input 填 ethernet_input：同步解析（netconn/socket 模型才换 tcpip_input，见升级实验） */
    netif_set_default(&g_netif); netif_set_up(&g_netif);
    netif_set_link_up(&g_netif); /* Link 状态由 ch20 的 BSR 轮询喂进来 */

    for (;;) {
        ethernetif_poll(&g_netif);   /* RX：环里 OWN 归 CPU 的帧 → pbuf → ethernet_input */
        sys_check_timeouts();        /* ARP/TCP 定时器的口粮——没人替你喂，忘喂=ARP 表不老化 */
        app_tick();                  /* 阶段③的手搓 ping、心跳打印都挂这 */
    }
}
```

> 📖 **术语卡：netif——lwIP 的网络接口抽象**
> **是什么**：lwIP 用一个 `struct netif` 代表一块网卡：IP/掩码/网关、MAC、MTU、两个发送出口（output=IP 层出口、linkoutput=链路层出口）都挂在上面。
> **为什么存在**：协议栈要能接任意硬件（以太网/WiFi/PPP/环回），netif 就是那个统一插槽，多个接口还能组链表做多跳选路。
> **类比**：`struct net_device` 的软件化身：`netif_add` ≈ register_netdev，`netif_set_up` ≈ `ip link set eth0 up`。
> ⚠️ 类比边界：net_device 背后有驱动模型/热插拔/队列纪律整套框架，netif 就是个纯结构体+链表节点。

> 📌 **静态 IP（你的主场，裸机长这样）**：`IP4_ADDR` 三连就是 `ip addr add 10.42.0.10/24` 的裸机等价
> 物——地址/掩码/网关逐字段写死进 netif 结构体；没有 DHCP、没有 netplan，直连两台设备各占 10.42.0.x
> 一个地址（F429=.10，RPi=.20）。升级实验再换成 `dhcp_start()` 自动领。

`ethernetif.c` 极简版（拷贝派：一跳 memcpy，环压力最小——选型讨论见
[[2026-08-26-lwip-deep-dive-ch17-ethernetif-porting-guide|lwIP（十七）]]17.4 的 A/B 方案表）：

```c
/* ---------- ethernetif.c：low_level 三件套，吃 ch20 的描述符环 ---------- */
static uint32_t rx_cur, tx_cur;                 /* 游标：CPU 侧视角推进 */

static void rx_rearm(uint32_t i)                /* 还槽给 DMA：OWN=1，游标前进 */
{
    rx_d[i].d1 = (1u << 14) | ETH_MAX;
    rx_d[i].d0 = 0x80000000u;
    rx_cur = (rx_cur + 1) % RX_DESC_N;
    ETH_DMA_RPDR = 1;                           /* 写任意值=收包轮询需求，防 DMA 挂起 */
}

static struct pbuf *low_level_input(void)
{
    if (rx_d[rx_cur].d0 & 0x80000000u) return NULL;   /* OWN 归 DMA：无货 */
    uint32_t fl = (rx_d[rx_cur].d0 >> 16) & 0x3FFFu;  /* FL：帧长含 4B CRC */
    uint32_t i = rx_cur;
    struct pbuf *p = NULL;
    if (fl >= 60u) {                                  /* runt 帧直接弃 */
        p = pbuf_alloc(PBUF_RAW, fl - 4u, PBUF_POOL); /* 去 CRC 后交给栈 */
        if (p) memcpy(p->payload, rx_b[i], fl - 4u);  /* 一跳拷贝，拷完即还槽 */
    }
    rx_rearm(i);
    return p;
}

void ethernetif_poll(struct netif *netif)
{
    struct pbuf *p;
    while ((p = low_level_input()) != NULL) {
        if (netif->input(p, netif) != ERR_OK) pbuf_free(p); /* 投递失败自回收：铁律 */
    }
}

static err_t low_level_output(struct netif *netif, struct pbuf *p)
{
    while (tx_d[tx_cur].d0 & 0x80000000u) { }         /* OWN 未归：环满自旋等（教学取舍） */
    uint32_t n = 0, i = tx_cur;
    for (struct pbuf *q = p; q; q = q->next) {        /* pbuf 链拼进连续 DMA 缓冲 */
        memcpy(tx_b[i] + n, q->payload, q->len);
        n += q->len;
    }
    tx_d[i].d1 = n;                                   /* TBS1=帧长 */
    tx_d[i].d0 = (1u << 20) | (1u << 29) | (1u << 28) | 0x80000000u; /* TCH|FS|LS|OWN */
    ETH_DMA_TPDR = 1;                                 /* 踢 TX DMA */
    tx_cur = (tx_cur + 1) % TX_DESC_N;
    return ERR_OK;          /* 满时绝不返回 ERR_MEM：lwIP ch17 实验c 的 errno 穿透事故 */
}

err_t ethernetif_init(struct netif *netif)
{
    netif->name[0] = 'e'; netif->name[1] = 'n';
    netif->output = etharp_output;                    /* IP 出口：白拿（ARP 全由栈做） */
    netif->linkoutput = low_level_output;             /* 唯一必须手写的发送函数 */
    netif->hwaddr_len = 6;                            /* hwaddr=ch20 写进 MACA0HR/LR 的值 */
    netif->mtu = 1500;
    netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_LINK_UP;
    return ERR_OK;
}
```

**代码走读（30 秒）**：收包——`ethernetif_poll` 循环查环上 OWN 位（1=DMA 占着，0=轮到 CPU）→ 有货
则 `pbuf_alloc` 开壳、`memcpy` 一跳把帧拷进 pbuf、立刻 `rx_rearm` 还槽 → `netif->input`（此处即
`ethernet_input`）同步送进协议栈解析。发包——`low_level_output` 等 TX 槽 OWN 归还（环满自旋）→ 把
pbuf 链逐段拷进连续 DMA 缓冲 → 描述符写长度+FS/LS+OWN → 写 TPDR 踢 DMA。短于 64B 的 runt（残帧）
直接弃收。你写的全部工作就是「搬运与登记」——协议一个字节都不用你管。

对照 lwIP 主系列的地图：`netif_add` 每个参数在
[[2026-08-26-lwip-deep-dive-ch7-netif-abstraction|lwIP（七）：netif 抽象]]逐字段拆过；`etharp_output`
接手后 ARP 构造/缓存/重发全不劳烦你（[[2026-08-26-lwip-deep-dive-ch8-ethernet-arp|lwIP（八）：以太网与 ARP]]）。

## 第二步：第一声 ARP——tcpdump 见证仪式

RPi 侧准备（直连拓扑，地址沿用 RPi ch08 的 10.42.0.x 语义；命令出自
[[2026-08-30-rpi-lab-ch08-instrument-roles-guide|RPi 仪器手册]]）：

```bash
sudo nmcli con add type ethernet ifname eth0 ipv4.method manual \
     ipv4.addresses 10.42.0.20/24 con-name f429-link        # RPi 侧静态地址
sudo tcpdump -i eth0 -n -e 'arp or icmp'                    # 仪式现场：-e 看 MAC，-n 禁反查
```

**命令拆解：** `sudo nmcli con add type ethernet ifname eth0 ipv4.method manual ipv4.addresses 10.42.0.20/24 con-name f429-link`

| 部分                           | 作用                                                                      |
| ------------------------------ | ------------------------------------------------------------------------- |
| `nmcli con add`                | NetworkManager 命令行：新建一条连接配置（connection）                     |
| `type ethernet ifname eth0`    | 有线类型、绑定 RPi 的 eth0 网卡                                           |
| `ipv4.method manual`           | 手动配 IP（你的主场：等价直接 `ip addr add`，但交给 NetworkManager 托管） |
| `ipv4.addresses 10.42.0.20/24` | RPi 侧地址+前缀长度；10.42.0.x 是与 F429 约定的直连网段                   |
| `con-name f429-link`           | 起个名字，之后 `nmcli con up f429-link` 可反复拉起                        |

**失败先查**：`ip addr show eth0` 看地址是否真挂上；换网线后重跑 `nmcli con up f429-link`。

**命令拆解：** `sudo tcpdump -i eth0 -n -e 'arp or icmp'`（tcpdump 是你的主场，这里抓的是裸机板发的第一声 ARP）

| 部分            | 作用                                                           |
| --------------- | -------------------------------------------------------------- |
| `tcpdump`       | 抓包神器：把网卡上经过的帧截下来打印/落盘                      |
| `-i eth0`       | 听哪块网卡：RPi 的有线口                                       |
| `-n`            | 不做 DNS 反查（IP/MAC 直接显示，快且不添乱）                   |
| `-e`            | 打印链路层头——仪式关键：要亲眼看到广播地址 `ff:ff:ff:ff:ff:ff` |
| `'arp or icmp'` | BPF 过滤表达式：只留 ARP 与 ping 包（过滤在内核态完成）        |

**你会看到**：`who-has 10.42.0.20 tell 10.42.0.10`——你手搓协议栈的第一个包！
**失败了先查**：网线/网段/REF_CLK（抓不到包第一嫌疑，见待核对 #2）。

F429 侧只加一行：主循环里对 `10.42.0.20` 发一个 UDP 包（或 `etharp_query`）——lwIP 发现 ARP 表没有目的 MAC，第一声 ARP 就出去了。

**预期输出（待实测核销）——格式与字段推导**，不是真跑截图：

```text
# RPi 侧 tcpdump 预期格式（符号占位；实跑后替换为真实输出存档 run.log）
hh:mm:ss.usec  ff:ff:ff:ff:ff:ff > <rpi-mac>, ethertype ARP (0x0806), length 42:
    Request who-has 10.42.0.20 tell 10.42.0.10, length 28
hh:mm:ss.usec  <rpi-mac> > <f429-mac>, ethertype ARP (0x0806), length 42:
    Reply 10.42.0.20 is-at <rpi-mac>, length 28
```

| 字段           | 推导                                                                                                 |
| -------------- | ---------------------------------------------------------------------------------------------------- |
| `length 42/28` | 外层 42=14B 以太头+28B ARP；括号内 28=ARP 报文本体                                                   |
| 目的 `ff:…:ff` | ARP 请求是广播——你填的以太头前 6 字节；应答第二行则点到点单播                                        |
| `<f429-mac>`   | `12:34:56:78:9A:BC`——ch20 写进 MACA0HR/LR 的自造值（首字节 0x12 的 bit1=1，本地管理位）              |
| `<rpi-mac>`    | RPi eth0 真实地址（`ip link` 可查），前 3 字节是树莓派 OUI（OUI=IEEE 分给厂商的 MAC 前缀，你的主场） |

这一刻的分量：**RPi 上什么都没配「服务」，是 Linux 内核协议栈本能地回答了一个新节点的第一声喊话**
——两个协议栈（lwIP/Linux）在 42 字节上完成第一次握手。F429 串口侧预期同步打出 ARP 状态行（开
ETHARP_DEBUG 可得，格式待实测）。

## 第三步：ping 双向通

- **RPi → F429**：`ping 10.42.0.10`——lwIP 收到 ICMP echo request 自动回（`LWIP_ICMP=1` 即可，
  无需一行应用代码；全路径见[[2026-08-26-lwip-deep-dive-ch9-ip4-icmp|lwIP（九）：IP 与 ICMP]]）。
- **F429 → RPi**：裸机没有 iputils，**ping 是自己手搓的**——raw API 造 ICMP echo request：

> 📖 **术语卡：raw API——lwIP 的回调式底层接口**
> **是什么**：lwIP 最底层（也最快）的应用接口：你创建 pcb（protocol control block，协议控制块）并注册 recv 回调，协议栈解析到匹配的包时在同一上下文里直接调你。
> **为什么存在**：不依赖线程/信号量，NO_SYS=1 唯一可用的 API 层；且少一层拷贝与线程切换开销。
> **类比**：内核里挂 netfilter hook 或 socket filter 的感觉——包到点，框架直接调你的函数。
> ⚠️ 类比边界：回调运行在协议栈上下文（这里是主循环）里：不能阻塞、要快进快出——全章「回调即临界区」即此意。

**命令拆解：** `ping 10.42.0.10`（你的主场，只列差异）

| 部分         | 作用                                                     |
| ------------ | -------------------------------------------------------- |
| `ping`       | iputils 客户端：发 ICMP echo request、等 reply、统计 RTT |
| `10.42.0.10` | F429 的静态 IP（本章手工配的，无 DHCP）                  |

**对端差异**：回包的不是 Linux 内核，是 lwIP——`LWIP_ICMP=1` 时回 echo reply 是协议栈本能，一行应用代码都不用写。

```c
/* ---------- 手搓 ping：raw pcb + 8 字节头 + 校验和 ---------- */
static struct raw_pcb *ping_pcb; static uint32_t g_t0;  /* pcb=raw_new(ICMP)；g_t0=DWT 计时 */

static u8_t ping_recv(void *arg, struct raw_pcb *pcb, struct pbuf *p, const ip_addr_t *addr)
{
    uart_puts("[ping] reply rtt_us=");   /* (DWT->CYCCNT - g_t0)/180，格式待实测 */
    uart_putdec((DWT->CYCCNT - g_t0) / 180u);
    pbuf_free(p);
    return 1;                            /* 已消费，不再向上送 */
}

static void ping_send(const ip4_addr_t *dst)
{
    static uint16_t seq;
    struct pbuf *p = pbuf_alloc(PBUF_IP, 8, PBUF_RAM);
    uint8_t *h = p->payload;
    h[0]=8; h[1]=0; h[2]=0; h[3]=0;      /* type=echo request, code=0, cksum 清零 */
    h[4]=0xF4; h[5]=0x29; h[6]=seq>>8; h[7]=(uint8_t)seq++;
    uint16_t c = inet_chksum(h, 8);      /* lwIP 白送的标准校验和函数 */
    h[2]=c>>8; h[3]=(uint8_t)c;
    g_t0 = DWT->CYCCNT; raw_sendto(ping_pcb, p, dst);   /* 记账发出时刻，recv 侧算 RTT */
    pbuf_free(p);
}
```

**走读**：`ping_send` 手拼 8 字节 ICMP 头——type=8（echo request）/code=0/校验和先清零、id=0xF429、
seq 递增；`inet_chksum` 算完回填，`raw_sendto` 经 raw pcb 直下 IP 层发出。`ping_recv` 是栈回调：收到
reply 时用 DWT 周期差算 RTT——`DWT->CYCCNT` 是 Cortex-M 内核自带的 CPU 周期计数器（调试单元
DWT=Data Watchpoint and Trace 的一部分），180MHz 主频下 180 个周期=1µs，代码里的 `/180` 由此而来。

**预期输出（待实测核销）**：RPi 侧 `ping` 的 `time=` 与 F429 侧 DWT 计时应同一量级（直连空载亚
毫秒级，数值不预填）；tcpdump 双向出现 `ICMP echo request/reply`，payload 里 `0xF4 0x29`
可辨——那是你自己填的两个字节。

## 升级实验：NO_SYS=0 + FreeRTOS 模型

换档三处：`lwipopts.h` 改 `NO_SYS=0`（可开 `LWIP_NETCONN/LWIP_SOCKET/LWIP_DHCP`）；补 `sys_arch.c`
（信号量/互斥/邮箱映射到 FreeRTOS 队列——
[[2026-08-26-lwip-deep-dive-ch14-sys-arch-freertos-adapter|lwIP（十四）：sys_arch 缝合层]]的裸机作业
版）；收包路径搬进中断+任务（ETH_IRQn=61，NVIC（Nested Vectored Interrupt Controller，Cortex-M 的
中断控制器——IRQ 号与优先级归它管，对应你熟悉的 IRQ 分配那层）优先级 ≥5——ch12 契约）：

> 📖 **术语卡：tcpip_thread——NO_SYS=0 的协议栈专属线程**
> **是什么**：`tcpip_init()` 拉起的一个专属线程：其他任务把包/请求投进邮箱（mbox，lwIP 对消息队列的叫法），它串行执行全部协议栈代码与应用回调。
> **为什么存在**：lwIP 内部大多不可重入；把所有栈操作收拢到单线程，用「串行化」换线程安全。
> **类比**：Redis 的事件循环线程：所有命令排队进一个线程执行，天然免锁。
> ⚠️ 类比边界：Redis 新版还多了 I/O 线程；tcpip_thread 是彻底串行的，跨线程交互只能靠邮箱传消息（不是共享内存加锁）。

```c
/* ---------- 同一套 ethernetif，换 FreeRTOS 模型 ---------- */
tcpip_init(NULL, NULL);                    /* 起 tcpip_thread：lwIP 主系列 ch13 的心脏落地 */
netif_add(&g_netif, &ip, &nm, &gw, NULL, ethernetif_init, tcpip_input);
/*                                        ↑ 唯一关键差异：input 改投邮箱，不再同步解析 */
netif_set_default(&g_netif); netif_set_up(&g_netif); netif_set_link_up(&g_netif);
dhcp_start(&g_netif);                      /* 从手动配 IP 升级为 DHCP 客户端 */

void ETH_IRQHandler(void)                  /* IRQ61：ISR 只做三件事（lwIP ch19 纪律） */
{
    BaseType_t w = pdFALSE;
    if (ETH_DMA_DMASR & 0x00010040u) {     /* RI+NIS：收到帧 */
        xSemaphoreGiveFromISR(g_rx_sem, &w);
        ETH_DMA_DMASR = 0xFFFFFFFFu;       /* 写 1 清状态 */
    }
    portYIELD_FROM_ISR(w);
}
void eth_rx_task(void *arg)                /* 与 openeth 的 emac_rx 同构的搬运工 */
{
    for (;;) {
        xSemaphoreTake(g_rx_sem, portMAX_DELAY);
        ethernetif_poll(&g_netif);         /* 同一个 poll——只是换了个执行者 */
    }
}
```

两种模型的代码结构对照（这张表就是「IDF 替你做了什么」的答案）：

| 维度           | NO_SYS=1 轮询（阶段②③）       | NO_SYS=0 + FreeRTOS（升级）                                            |
| -------------- | ----------------------------- | ---------------------------------------------------------------------- |
| 定时器喂养     | 主循环 `sys_check_timeouts()` | tcpip_thread 自动                                                      |
| 收包执行者     | main 循环轮询                 | ETH IRQ → 信号量 → rx 任务                                             |
| `netif->input` | `ethernet_input`（同步解析）  | `tcpip_input`（投邮箱）                                                |
| API 层级       | 仅 raw API 回调               | raw/netconn/socket 全开                                                |
| 并发风险       | 无：单线程，回调即临界区      | 跨界只许邮箱一次投递（ch13 单写者纪律）                                |
| 需要移植       | cc.h/lwipopts.h/ethernetif    | 再加 sys_arch.c（ch14 的映射表）                                       |
| ESP32 对应     | 无（IDF 只有 OS 模型）        | `esp_netif_init()` 内部即此模型                                        |
| DHCP           | 手动配静态                    | `dhcp_start`（RPi 侧需 dnsmasq——轻量 DNS/DHCP 服务，你的主场；待实测） |

## 系列对照

- **lwIP 主系列闭环**：主系列 ch17 讲「移植契约一页纸」，本章把契约兑现到真 MAC；ch18 的 wlanif
  是乐鑫写好的 ethernetif 套皮——**你手写这 100 行，就是 wlanif.c 的前世**。RPi 抓的
  `f429-boot.pcap` 可直接套用[[2026-08-28-lwip-deep-dive-extra-pcapx-pluggable-capture|pcapx 附加篇]]。
- **回扣本系列**：ch06 环形缓冲→ch10 DMA→ch20 描述符环→本章 pbuf，四级缓冲一脉贯通；DWT 计时
  （ch01）成了 ping RTT 的秒表；ch12 优先级契约在 IRQ61 的 NVIC 配置上一票检验。
- **FreeRTOS 侧**：tcpip_thread 的栈深/优先级是
  [[2026-08-26-lwip-deep-dive-ch19-isr-and-priority-design|lwIP（十九）]]的作业——实测后回填。

## 本章待核对清单

| #   | 项                                                             | 核对方法                                                           |
| --- | -------------------------------------------------------------- | ------------------------------------------------------------------ |
| 1   | ARP/ping 的 tcpdump 真实输出（本章全部预期格式的实测核销）     | RPi ch08 命令 + run.log 存档                                       |
| 2   | REF_CLK 方案是否正确（抓不到包的第一嫌疑）                     | ch20 清单 #3；piscope 看 PA1                                       |
| 3   | pbuf 池 8 深是否够 + `low_level_output` 自旋等待的极限         | lwip_stats（lwIP 内建统计计数器）+ ch22 打流                       |
| 4   | TX 描述符位序（TDES0 FS/LS/TBS 实测）                          | 对照 tcpdump 收到的帧完整性                                        |
| 5   | DHCP 全流程（DISCOVER→OFFER→REQUEST→ACK）在 RPi dnsmasq 下实测 | tcpdump `udp port 67 or 68`（DHCP 的 UDP 端口，你的主场）          |
| 6   | tcpip_thread 栈深实测（FreeRTOS 模型）                         | uxTaskGetStackHighWaterMark（FreeRTOS 查任务栈最小剩余的官方 API） |
| 7   | lwip 2.2.0 与 IDF 2.2.0-dev 的 API 行为差异（如有）            | 两树 diff 提交记录抽查                                             |

上一章：[[2026-08-30-f429-lab-ch20-ethernet-emac-phy|以太网上电：EMAC 与 PHY]]——硬件邮箱已上架；
下一章：[[2026-08-30-f429-lab-ch22-esp32-vs-f429-throughput|全家对照：ESP32 vs F429]]。系列总目录见
[[2026-08-30-f429-lab-series-index|F429 裸机实验室索引]]。
