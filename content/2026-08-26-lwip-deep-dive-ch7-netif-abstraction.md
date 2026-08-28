---
title: "lwIP 深度解析（七）：netif 抽象层：协议栈与网卡的契约"
date: 2026-08-26
description: "逐字段解剖 struct netif：input/output/linkoutput 函数指针契约、ip_addr 三元组、flags、state/client_data 背指针；走读 netif_add → init_fn → set_up/link_up 的生命周期与每次状态转换触发的事件（ext-callback、ARP 清理、GARP）；拆解 ip4_route 的前缀匹配与默认网卡回退规则，用 lo 与 en 双网卡在 QEMU 里实测路由分派，再用 link down/up 故障注入展示发送失败传播与 DHCP reboot 恢复路径。"
tags: [lwip, network, esp32, esp-idf, qemu, netif, routing]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 7. **第七章：netif 抽象层：协议栈与网卡的契约**

# lwIP 深度解析（七）：netif 抽象层：协议栈与网卡的契约

这一章回答三个问题：**协议栈怎么做到对网卡一无所知**（lwIP 内核里连一句 "openeth" 都找不到，它靠什么把包交给具体硬件）、**一个 `struct netif` 里哪些是"契约"、哪些是"状态"**（函数指针是驱动要填的合同条款，ip 地址是运行期改写的状态栏）、**多网卡并存时一个包按什么规则选路**（`ip4_route` 的扫描顺序、默认网卡、loopback 特判）。读完它，你就拿到了"向 lwIP 移植一块新网卡"和"诊断多网卡路由问题"两份钥匙——第 17 章会亲手填一次这份契约。源码参照：ESP-IDF v6.0.2 内捆绑的 lwIP **2.2.0-dev**，关键文件 `src/include/lwip/netif.h`、`src/core/netif.c`、`src/core/ipv4/ip4.c`；实验工程 `practice/lwip-ch07-netif-abstraction/`，复用[[2026-08-26-lwip-deep-dive-ch3-qemu-network-lab|第三章]]的 openeth 联网模板。

---

## 7.1 契约层全景：一张 struct 装下所有网卡

### 1. 以太网、SLIP、loopback 用同一个结构体

lwIP 的世界里有以太网卡、SLIP 串口、PPP 链路、软件 loopback——它们介质不同、帧格式不同、发一字节数据的代码更是风马牛不相及。但内核上层（IP/UDP/TCP）只认识一个类型：`struct netif`。这与[[2026-08-26-freertos-deep-dive-ch16-portmacro-port-contract|FreeRTOS 端口层契约]]同构：**内核主体声明它需要的动作，每块"硬件"提供实现**。区别在于 FreeRTOS 用一份 `portmacro.h` 宏清单承载契约，而 lwIP 把契约直接铸进了结构体的函数指针成员：

```c
/* src/include/lwip/netif.h —— 结构体注释原文直译：
 * "以下字段应由设备驱动的初始化函数填写：
 *  hwaddr_len, hwaddr[], mtu, flags" */
struct netif {
#if !LWIP_SINGLE_NETIF
  struct netif *next;              /* 全局链表 node */
#endif
  ip_addr_t ip_addr;               /* IPv4 三元组（网络字节序） */
  ip_addr_t netmask;
  ip_addr_t gw;
  ...
  netif_input_fn input;            /* 驱动收包后往上推的入口 */
  netif_output_fn output;          /* IP 层发包的第一站（以太网=etharp_output） */
  netif_linkoutput_fn linkoutput;  /* 帧真的出门的最后一站 */
  void *state;                     /* 驱动私有数据背指针 */
  void* client_data[...];          /* 多客户端背指针槽位数组 */
  u16_t mtu;
  u8_t hwaddr[NETIF_MAX_HWADDR_LEN];
  u8_t hwaddr_len;
  u8_t flags;
  char name[2];                    /* "en"/"lo"，配合 num 组成 en1/lo0 */
  u8_t num;
};
```

### 2. 谁写谁读：契约与状态的分界线

把字段按"谁在什么时候碰它"分两类，netif 就不再是一堆乱码：

| 类别         | 字段                                             | 写入者                    | 运行期还会变吗                          |
| ------------ | ------------------------------------------------ | ------------------------- | --------------------------------------- |
| **函数契约** | `input` / `output` / `linkoutput` / `output_ip6` | 驱动 `init_fn` 一锤定音   | 基本不变（特例见下文 null-output 占位） |
| **能力申报** | `flags` 能力位、`mtu`、`hwaddr`/`hwaddr_len`     | 驱动 `init_fn`            | 不变；`flags` 里的 UP/LINK_UP 是例外    |
| **地址状态** | `ip_addr`/`netmask`/`gw`、DHCP 实例              | 协议栈（set_addr/DHCP）   | 随时被改写——契约里最活跃的部分          |
| **管理状态** | `flags` 的 UP(0x01)/LINK_UP(0x04) 位             | 驱动/管理员 API           | 按 up/down 翻转                         |
| **背指针**   | `state` 或 `client_data[n]`                      | 适配层（esp_netif）或驱动 | 注册期一次                              |

`flags` 一个字节能横跨两类，是个精心设计的小陷阱：`NETIF_FLAG_BROADCAST`(0x02)、`ETHARP`(0x08)、`ETHERNET`(0x10)、`IGMP`(0x20)、`MLD6`(0x40) 是出生时定死的能力位；`UP`(0x01)、`LINK_UP`(0x04) 则由生命周期 API 翻转。7.3 节的故障注入实验里我们会亲眼看到 flags 从 `0x7f` 变成 `0x7b`——少的正是 LINK_UP 那 4 个 bit。

### 3. 两根全局骨架

链表和默认指针是整个 netif 子系统仅有的两个全局变量：

```c
extern struct netif *netif_list;      /* 所有已注册 netif 的单链表 */
extern struct netif *netif_default;   /* 无匹配路由时的兜底出口 */
#define NETIF_FOREACH(netif) for ((netif)=netif_list; (netif)!=NULL; (netif)=(netif)->next)
```

注意两点，实验中都会被验证：其一，`netif_add()` 把新接口插到**链表头**（`netif->next = netif_list; netif_list = netif;`），所以遍历顺序与创建顺序相反；其二，`num` 分配器保证 `(name, num)` 唯一，`num+1` 就是 RFC 3493 的 interface index。本机实测 `sizeof(struct netif) == 260`（Xtensa 32 位、IPv6 开、全堆化配置），比 `struct pbuf` 的 16 字节厚道得多——它是常驻内存的全局家底，不是随包分配的面包屑。

---

## 7.2 struct netif 逐域解剖

### 1. 发送方向的三级函数指针

发送契约比接收复杂，因为以太网发送天然是两段式：先问 ARP 要 MAC（可能要等几个毫秒甚至发不出），再把完整帧怼到总线上。lwIP 把这两段拆成两个指针：

```text
TCP/UDP/IP 层发包
   │
   ▼
netif->output(netif, p, 目标 IP)        ← L3 出口：以太网=etharp_output，
   │   把 IP 头写好、查 ARP 表            loopback=netif_loop_output_ipv4
   │   拿到 MAC 或挂起等待
   ▼
netif->linkoutput(netif, p)             ← L2 出口：参数已是完整以太网帧，
       （ethernet_low_level_output）        由驱动 DMA/寄存器真正发出
```

为什么 loopback 没有 linkoutput？因为它根本不出门——7.4 节展开。而 SLIP 这类点对点裸接口则相反：不需要 ARP，把 `output` 直接设为自己的链路发送函数，绕过中间商。这套设计让内核发包路径只面对一个抽象语句 `netif->output(...)`，无从知晓后面是 openeth 寄存器还是 127.0.0.1 的内存拷贝。

接收方向的 `input` 反而是三个里最"标准化"的：多线程模式下几乎总是 `tcpip_input()`（把 pbuf 打包成消息投进 tcpip_thread 邮箱——[[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|第十三章]]的主角）。真正的分支选择藏在它的实现里：`netif_input()` 看 flags 里有没有 `ETHARP|ETHERNET` 决定走 `ethernet_input()` 还是直接 `ip_input()`。**flags 又一次充当了运行时契约仲裁员。**

### 2. ip_addr 三元组与那个著名的字节序陷阱

`ip_addr`/`netmask`/`gw` 三兄弟是最活跃的状态字段。先立个字据：`ip4_addr_t.addr` 存的是"网络字节序整数"，正确构造方式照抄 `IP4_ADDR` 宏本体：

```c
/* src/include/lwip/ip4_addr.h:104 */
#define IP4_ADDR(ipaddr, a,b,c,d)  (ipaddr)->addr = PP_HTONL(LWIP_MAKEU32(a,b,c,d))
```

> [!warning] 本章实验的真实翻车现场：手写 0x0A000002 ≠ 10.0.0.2
> `LWIP_MAKEU32(a,b,c,d)` 只是把四字节拼成 `a<<24|b<<16|c<<8|d`，在小端 Xtensa 上还要再经 `PP_HTONL` 换一次字节序才是 `.addr` 真身。本章 E2 我先手写了 `0x7f000001` 想"当然地"表达 127.0.0.1——运行结果：地址打印成 `1.0.0.127`，路由表全线失灵，ping 网关全部超时。另一个连带坑：`ipaddr_ntoa()` 内部是一个静态缓冲区，一次 `ESP_LOGI("%s/%s", ipaddr_ntoa(&a), ipaddr_ntoa(&b))` 打出来两个值一样！要点名要用 `_r` 版本各自的 buffer。这两个坑都是"能编译能链接、运行全盘错"的典型——契约层调试远比想象中阴险。

三元组的改写从不裸写，一律走 `netif_set_addr()` 家族。它不只是赋值：还要通知 TCP/UDP/RAW 层"本地地址变了你手里的绑定作废"、刷新 MIB2 计数、补发 gratuitous ARP——这些副作用在 7.3 节拆解。

### 3. state 与 client_data：背指针的双轨制

结构体里有两条通往外部世界的暗道：

```c
void *state;   /* 经典背指针：驱动塞私有数据的地方 */
#ifdef netif_get_client_data
  void* client_data[LWIP_NETIF_CLIENT_DATA_INDEX_MAX + LWIP_NUM_NETIF_CLIENT_DATA];
#endif
```

`state` 是单槽位的祖传设计，第一个伸手的人占坑。但 lwIP 自己内部组件也要用：DHCP 客户端实例就藏在 `client_data[LWIP_NETIF_CLIENT_DATA_INDEX_DHCP]` 这个内部保留槽位里（枚举 `enum lwip_internal_netif_client_data_index` 列出了 DHCP/AUTOIP/ACD/IGMP/DHCP6/MLD6 这些保留编号），加上用户可用槽位构成数组。esp_netif 的适配层实读（`components/esp_netif/lwip/esp_netif_lwip.c`）展示了双轨如何分工：

```c
static inline esp_netif_t* lwip_get_esp_netif(struct netif *netif)
{
#if LWIP_ESP_NETIF_DATA    /* 启用 PPP/bridge 等特殊接口时为 1 */
    return (esp_netif_t*)netif_get_client_data(netif, lwip_netif_client_id);
#else                      /* 常规以太网/WiFi：state 单槽就够了 */
    return (esp_netif_t*)netif->state;
#endif
}
```

IDF 的 `port/include/lwipopts.h` 注释把切换条件写得明明白白："If special lwip interfaces (like bridge, ppp) enabled, `netif->state` is used internally and we must store esp-netif ptr in `netif->client_data`"。第四章提过 esp_netif_obj 与 netif 是组合关系（esp_netif 持 lwip_netif 指针），这里的反向背指针就是那条关系的另一半。E1 实验将同时展示两个槽位：en 网卡 `state` 指向 esp_netif 对象且 DHCP 槽位有实例，lo 网卡两者皆空。

### 4. 循环队列与其他杂项

`ENABLE_LOOPBACK` 时（IDF 默认开）每个 netif 尾部还挂着 `loop_first/loop_last` 两个 pbuf 队列指针——发给自己的包在此排队，`LOOPBACK_MAX_PBUFS`（IDF 默认 8）限流防爆。ESP-LWIP 还给结构体追加了 `napt` 成员（NAPT 功能标记，`#if ESP_LWIP && IP_NAPT`），vanilla 用户看不到它——这是 IDF 改造 core 的又一处实证。

---

## 7.3 生命周期走读：每个转换触发什么

### 1. 出生：netif_add 与 init_fn 的接力

`netif_add(netif, ipaddr, netmask, gw, state, init, input)` 干七件事，顺序很讲究：

```text
netif_add()
 ├─ 清零地址三元组、mtu=0、flags=0
 ├─ output/output_ip6 ← netif_null_output_*   【占位符：此时发包返回 ERR_IF】
 ├─ 记住 state / input 参数
 ├─ netif_set_addr()                            【先安家：写入三元组】
 ├─ init(netif)                                 【呼叫驱动：填契约字段】
 │     └─ ethernetif_init():
 │           name="en"; output=etharp_output;
 │           linkoutput=ethernet_low_level_output;
 │           flags=BROADCAST|ETHARP|ETHERNET(|IGMP|MLD6); mtu=1500
 ├─ 分配唯一 num（冲突则 ++ 重试）
 ├─ 插入 netif_list 链表头
 └─ netif_invoke_ext_callback(LWIP_NSC_NETIF_ADDED)
```

占位 output 是个容易被忽略的安全网：`netif_add` 一进就把 output 挂到失败返回的占位实现上，而驱动契约要到同函数末尾的 `init(netif)` 才生效——这中间无论发生什么（典型如 `netif_add_noaddr()` 配了结构体却迟迟不给地址），被人触发的发送都会得到明确的错误码而不是野指针跳转。hwaddr 的实际拷贝不发生在 `ethernetif_init` 里，而是 esp_netif 随后单独执行 `memcpy(esp_netif->lwip_netif->hwaddr, mac, NETIF_MAX_HWADDR_LEN)`（`esp_netif_lwip.c:1143`）。

### 2. up/down 与 link up/down：两组语义、两种后果

这是本章最重要的语义区分——**管理态（UP）与物理态（LINK_UP）是独立的开关**，后果不对称：

| 动作                  | flags 变化 | 连带事件                                                               | 数据面后果             |
| --------------------- | ---------- | ---------------------------------------------------------------------- | ---------------------- |
| `netif_set_up`        | +UP        | status_callback、NSC_STATUS_CHANGED(1)、发 gratuitous ARP/IGMP 报告    | 可收发（还需 LINK_UP） |
| `netif_set_down`      | −UP        | NSC_STATUS_CHANGED(0)、**etharp_cleanup_netif 清 ARP 表**、nd6 清理    | 立刻停摆，邻居缓存作废 |
| `netif_set_link_up`   | +LINK_UP   | **dhcp_network_changed_link_up**、发报告/GARP、NSC_LINK_CHANGED(1)     | 恢复可收发             |
| `netif_set_link_down` | −LINK_UP   | 仅 autoip/acd 收尾 + NSC_LINK_CHANGED(0)，**不清 ARP**、不动 DHCP 配置 | 新包出不去，旧缓存留着 |

三处细节值得放大。第一，`netif_issue_reports()` 有前置闸门："Only send reports when both link and admin states are up"——所以 bring-up 序列里谁是最后一个 up 谁 triggers GARP。第二，link-up 触发的 `dhcp_network_changed_link_up()` 对 BOUND 态的处理是 `dhcp_reboot()`（tries=0、快速重试、单播 REQUEST 续租）而非从 INIT 重新 discover——E3 实验会在日志里验证这一点。第三，link-down 竟然不清 ARP 表，只有 admin down 才清——意味着拔掉网线再插回，只要没经过 set_down，旧的 IP-MAC 映射还在缓存里继续服役。这个差异在生产环境排查"换设备后不通"时极其关键。

### 3. 事件广播：ext-callback 多订阅者机制

每个生命周期转换最后都会 `netif_invoke_ext_callback()`。它维护一条**链表式多订阅者通道**，任何人都可以挂号：

```c
/* 使用范式（本章实验即如此） */
NETIF_DECLARE_EXT_CALLBACK(s_ch7_ext_cb);
netif_add_ext_callback(&s_ch7_ext_cb, my_logger);   /* 必须在 tcpip 线程上下文调用 */
```

reason 是位掩码，可以在同一次 `netif_set_addr` 里复合出现（下表同时给出实测观察到的组合）：

| reason 位                            | 值                   | 何时发出                                                          | args 内容            |
| ------------------------------------ | -------------------- | ----------------------------------------------------------------- | -------------------- |
| NETIF_ADDED / REMOVED                | 0x0001/0x0002        | add 成功后 / remove 前                                            | NULL                 |
| LINK_CHANGED                         | 0x0004               | link up/down 且状态翻转                                           | link_changed.state   |
| STATUS_CHANGED                       | 0x0008               | 管理 up/down                                                      | status_changed.state |
| IPV4_ADDRESS/GATEWAY/NETMASK_CHANGED | 0x0010/0x0020/0x0040 | 对应项真实变化                                                    | ipv4*changed.old*\*  |
| IPV4_SETTINGS_CHANGED                | 0x0080               | 上述任一发生后追加                                                | 同上                 |
| IPV4_ADDR_VALID                      | 0x0400               | 设置流程末尾**无条件**追加（"eg. DHCP reboot"，即使地址没变也发） | 同上                 |

经典日志 `reason=0x04f0` = ADDRESS|NETMASK|GATEWAY|SETTINGS|ADDR_VALID 五位齐发——DHCP 初次绑定的标准签名；而 recovery 日志里的孤零零 `0x0400` 正是 reboot 续租成功、三项地址原封未动的证据链。对比老式的单订阅者 `status_callback/link_callback` 槽位，ext-callback 解决了"栈外多个模块都想看事件"的归属权问题——这正是下一小节 esp_netif 的命脉。

> [!tip] 向 tcpip 世界借线程的纪律
> 上文反复强调 `netif_add_ext_callback` 要在 tcpip 线程执行——不只它，整个 netif API 族（set_up/set_addr/remove…）都带 `LWIP_ASSERT_CORE_LOCKED()` 断言。应用任务想动它们，唯一正道是用 `tcpip_callback(fn, ctx)` 把操作投递过去排队执行（本章实验通篇如此），或者走 socket/netconn 层由它们代为投递。这条纪律就是系列暗线 A 的具体表现：**一切共享状态的消息化访问**。

---

## 7.4 路由选择：ip4_route 的五步裁决

### 1. 五步流水线

每个出站的 IP 包都要回答一次"走哪张网卡"。`src/core/ipv4/ip4.c` 的 `ip4_route(dest)` 给出标准答案：

```text
① 组播特例：dest 为组播 && 管理员指定了 ip4_default_multicast_netif → 直接用它
② 前缀扫描：NETIF_FOREACH(netif):
     合格条件 = netif_is_up && netif_is_link_up && 地址非 0.0.0.0
     匹配条件 = (dest & netmask) == (netif.ip_addr & netmask)   ← 同子网前缀命中
                或 网卡无 BROADCAST 标志 && dest == gw           ← 点对点链路的 peer 特判
③ loopback 兜底：仅当 LWIP_NETIF_LOOPBACK && !LWIP_HAVE_LOOPIF
     （127.x 允许借助任意 up 的网卡出去——本环境不适用，见下）
④ 路由钩子：LWIP_HOOK_IP4_ROUTE_SRC / LWIP_HOOK_IP4_ROUTE 让外挂策略接管
⑤ 默认网卡终审：
     netif_default 存在 && is_up && is_link_up && 地址非 0.0.0.0 && dest 非 127.x
     → 放行 return netif_default
     否则 → DEBUG 打印 "ip4_route: No route to x.x.x.x"，ip.rterr++，return NULL
```

②和⑤合起来解释了一个反直觉现象：**发往自己子网内对端（如网关 10.0.2.2）的包其实不走"默认路由"分支**，早在②的前缀命中就拍板了；默认网卡只在②全落空后才登场。⑤里对 dest 的 `ip4_addr_isloopback` 再审是个防御性兜底——当系统没有独立 loop 网卡时防止 127 包被误投到以太网上。

### 2. "127.0.0.1 不走网卡"的实现

这句口诀的真身是一张**寄生在协议栈里的隐藏网卡**。版本演化很有戏剧性：老版 lwIP（≤2.1）把它放在独立文件 `src/netif/loopif.c`；本仓库的 2.2.0-dev 里**该文件已不存在**，逻辑整体并入 `src/core/netif.c` 的 `netif_init()`：

```c
#if LWIP_HAVE_LOOPIF
  IP4_ADDR(&loop_gw,      127, 0, 0, 1);
  IP4_ADDR(&loop_ipaddr,  127, 0, 0, 1);
  IP4_ADDR(&loop_netmask, 255, 0, 0, 0);
  netif_add(&loop_netif, LOOPIF_ADDRINIT NULL, netif_loopif_init, tcpip_input);
  netif_set_link_up(&loop_netif);
  netif_set_up(&loop_netif);
#endif
```

调用时机要说准：`tcpip_init()` 第一行就同步执行 `lwip_init()`（其内部逐个调子模块初始化，`netif_init()` 是其中之一），然后才去创建 tcpip 线程——所以 **lo0 先于任何驱动、甚至先于 tcpip_thread 出生，拿走 name="lo"+num=0**。它的契约极简：`output=netif_loop_output_ipv4`、没有 linkoutput、没有 MAC、flags 只有 UP|LINK_UP（连 BROADCAST 都没有——顺便符合②中点对点特判的气质）。

之后 ping 127.0.0.1 的旅程是纯内存循环：`ip4_route` 在②里让 lo0 前缀命中（127.0.0.1 & 255.0.0.0 == lo 地址）→ `output` 即 `netif_loop_output()`：整包 `pbuf_copy` 进新 pbuf、SYS_ARCH_PROTECT 下挂进 `loop_first/last` 队列、`tcpip_try_callback(netif_poll)` 预约 tcpip 线程来 Drain → `netif_poll` 取出后**直接 `ip_input(in, netif)`**——跳过整个以太网层，无帧、无驱动、无中断。全程只在 `icmp.recv/xmit` 留痕（我们实验统计的对照恰好抓到了这个指纹）。

`LWIP_LOOPBACK_MAX_PBUFS=8` 在队列过深时直接 `ERR_MEM` 拒收——给"程序往自己地址狂灌包"这种自残行为设了个天花板。

### 3. netif_default 的切换语义

`netif_set_default(netif)` 是全章最平淡的函数：swap 指针 + MIB2 记账，**零事件零回调**。真正的策略在调用方手里：vanilla 由应用手动调；IDF 则在 DHCP 拿到地址的路径上通过 `esp_netif_update_default_netif(esp_netif, ESP_NETIF_GOT_IP)` 自动挂默认。多网卡共存时谁最后拿到 IP 谁上位的语义、以及 `esp_netif_set_default_netif()` 手工夺权的 API，是多网卡部署的日常操作面。

---

## 7.5 Vanilla lwIP 与 ESP-IDF lwIP 对照

同一套 netif 契约，两边接入姿势完全不同：

| 维度         | Vanilla lwIP                                                                                                                        | ESP-IDF v6                                                                                               |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 接口注册     | 应用手动准备 `struct netif`（通常 static 全局），`netif_add(…, ethernetif_init, tcpip_input)` 后手动 set_default/set_link_up/set_up | `esp_netif_new()` + `esp_netif_attach(glue)`，app 永远摸不到 struct 本体                                 |
| init_fn 来源 | 移植者自写 `ethernetif.c`（官方 skeleton）                                                                                          | `components/esp_netif/lwip/netif/ethernetif.c` 固定提供，name="en"                                       |
| loopback     | 老≤2.1：`src/netif/loopif.c` 手动注册；新上游：core 内建，宏默认自动                                                                | `CONFIG_LWIP_NETIF_LOOPBACK=y`（Kconfig 默认 y）→ `LWIP_HAVE_LOOPIF=1` 自动生成 lo0                      |
| BACKPOINTER  | app 自由定义 `state`                                                                                                                | 常规走 `state`=esp_netif；开 PPP/bridge 切 client_data（见 7.2.3）                                       |
| 事件出口     | 自己设 status_callback/link_callback（单订阅者）                                                                                    | **强制开启 `LWIP_NETIF_EXT_STATUS_CALLBACK=1`**（port lwipopts.h 注明供 esp-netif 用），翻译成 esp_event |
| Kconfig 裁剪 | opt.h 手编                                                                                                                          | `CONFIG_LWIP_NUM_NETIF_CLIENT_DATA=0` 默认、`CONFIG_LWIP_LOOPBACK_MAX_PBUFS=8` 等                        |

esp_netif 的翻译链值得单独画一遍，因为它是"lwIP 事件 → ESP-IDF 世界观"的国境口岸：

```text
lwIP core:  netif_set_link_down()
                 └─ netif_invoke_ext_callback(LWIP_NSC_LINK_CHANGED, state=0)
                      ├─ 订阅者A: esp_netif 注册的 netif_callback_fn
                      │     （首次 esp_netif_new 时 netif_add_ext_callback 挂入，
                      │      全系统仅此一份、常驻）
                      │      · LINK|STATUS_CHANGED → 归一化为"有效 up/down 是否翻转"
                      │        翻转才 post IP_EVENT_NETIF_UP / IP_EVENT_NETIF_DOWN
                      │        （v6 新增的两个 IP 事件；up/down 组合态防抖在这里做）
                      │      · IP 地址族变化(DHCP_CB_CHANGE 四位掩码) →
                      │        esp_netif_internal_dhcpc_cb → 衔接 DHCP→事件链，
                      │        最终 post 应用熟悉的 IP_EVENT_ETH_GOT_IP
                      └─ 订阅者B: 你自己的观察者（本章实验即如此，与 A 并行收到同样事件）
```

也就是说，第三章我们习以为常的 `GOT_IP` 事件，其源头只是 `netif_do_set_ipaddr()` 里的一次普通三元组写入 + ext-callback 广播——esp_netif 认领它、去抖、换皮后重新发布。理解这条链，你在 ESP-IDF 文档里看到的"netif 状态"、"esp_netif 状态"、"IP_EVENT"三套词汇就合并成了同一个真相的三种方言。

> [!note] IDF 加在 core 里的另外一笔
> `netif_add()` 里有一段 `#if ESP_LWIP #if IP_NAPT netif->napt = 0;`——NAPT（NAT for lwIP）功能位随接口初始化清零。核心修改虽小，却再次证实系列暗线 B：IDF 不是"原样打包 lwIP"，而是在契约层的关键点位留下自己的挂钩。

---

## 7.6 实验：解剖、路由分派与链路故障注入

实验工程 `practice/lwip-ch07-netif-abstraction/` 基于 ch3 openeth 模板，三组实验共用一次启动。构建与运行的标准命令：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch07-netif-abstraction
idf.py set-target esp32        # 仅首次
idf.py build
idf.py qemu monitor < /dev/null || true    # 生成 build/qemu_flash.bin / qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 50 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run.log
```

`sdkconfig.defaults` 相比模板加了一行 `CONFIG_LWIP_STATS=y` 用于读协议计数器。本章实验没有"主机访问 guest"的需求（ch3 的 TCP echo server 已移除），因此不加 hostfwd；若你要扩展出主机可达的服务，按系列约定追加 `-nic user,model=open_eth,hostfwd=tcp::8007-:<端口>`。所有对 netif 内部字段的读取都封装成函数经 `tcpip_callback()` 投递进 tcpip 线程执行（7.3 的纪律）。另外注册了一个自己的 ext-callback 当"事件记录仪"，它会在下面所有日志里以 `[extcb]` 行同步出镜。

### E1：运行时解剖两张网卡

目的：验证 7.2 的逐域分析与实跑结构体一一对应。dump 函数经 `NETIF_FOREACH` 遍历并解码打印。真实输出摘录（run.log）：

```text
I (2595) ch7lab: === E1: netif_list 解剖（sizeof(struct netif)=260）===
I (2595) ch7lab: --- netif en1 (index=2) ---
I (2595) ch7lab:   struct@0x3ffb8d0c size=260 state(背指针)=0x3ffb8c9c
I (2595) ch7lab:   ip/mask/gw: 10.0.2.15/255.255.255.0 gw 10.0.2.2
I (2595) ch7lab:   mtu=1500 hwaddr_len=6 hwaddr=52:54:00:12:34:56 flags=0x7f[UP BCAST LINK_UP ETHARP ETH IGMP MLD6 ]
I (2595) ch7lab:   input=0x400df748 output=0x400e8e20 linkoutput=0x400f31e8
I (2595) ch7lab:   hostname="espressif"
I (2595) ch7lab:   client_data[DHCP]=0x3ffba1fc
I (2595) ch7lab:   loopback 队列 first=0 last=0
I (2595) ch7lab: --- netif lo0 (index=1) ---
I (2595) ch7lab:   struct@0x3ffb368c size=260 state(背指针)=0
I (2595) ch7lab:   ip/mask/gw: 127.0.0.1/255.0.0.0 gw 127.0.0.1
I (2595) ch7lab:   mtu=0 hwaddr_len=0 hwaddr=00:00:00:00:00:00 flags=0x05[UP LINK_UP ]
I (2595) ch7lab:   input=0x400df748 output=0x400dff8c linkoutput=0
I (2595) ch7lab:   hostname="(null)"
I (2595) ch7lab:   client_data[DHCP]=0 (无 DHCP 实例)
I (2595) ch7lab: === E1 done: 共 2 个 netif, 默认网卡(netif_default)=0x3ffb8d0c ===
```

对照源码逐条兑现：

- **两张卡，命名规则肉眼可见**：lo 先出生（tcpip_init 内建，拿 num=0）、en 后注册（拿 num=1），但遍历先见到 `en1` 后见到 `lo0`——`netif_add` 的**链表头插入**（7.1 第 3 点）让后来者居前。index 分别为 2 和 1（num+1）。
- **函数指针契约侧写**：两个 netif 的 `input` 指针完全相同（都是 `netif_add` 传入的 `tcpip_input`，运行地址一致互证）；en 独有第三个 `linkoutput`；两者 `output` 不同（en 是 `etharp_output`，lo 是静态函数 `netif_loop_output_ipv4`，后者不出 symbol table 但由 `netif_loopif_init` 源码坐实）。想知道指针对应哪个符号，可在主机上用 `xtensa-esp32-elf-nm build/*.elf` 对照。
- **背指针双轨**：en 的 `state` 非空（指向 esp_netif 对象，即 `esp_netif_get_netif_impl()` 返回的那条组合关系），lo 的为 NULL；DHCP 保留槽位 en 有实例、lo 为空。
- **能力申报差异**：en flags=`0x7f` 七位全满——基础三位 `BROADCAST|ETHARP|ETHERNET` 由 skeleton init 写入，IGMP（`#if ESP_LWIP && LWIP_IGMP`）与 MLD6（`#if ESP_IPV6 && LWIP_IPV6_MLD`）由 IDF 条件编译追加；lo 只有 UP|LINK_UP，是"最吝啬但诚实的能力申报"。
- lo 的 `mtu=0`：`netif_loopif_init` 根本没设 mtu，回环路径不查 MTU——又一个"这块网卡活在协议栈内部"的证据。

顺带回收 bring-up 阶段记录仪的完整事件流，它就是 7.3/7.5 两节的动态注脚：

```text
I (1595) [extcb] netif en1 reason=0x0001      ← NETIF_ADDED：glue 完成 attach/add
I (1595) [extcb]   NETIF_ADDED
I (1595) [extcb] netif en1 reason=0x0008      ← 管理 up（glue 流程 netif_set_up）
I (1595) [extcb]   STATUS_CHANGED state=1
I (1595) [extcb] netif en1 reason=0x0004      ← 物理 up（自协商完成 netif_set_link_up）
I (1595) [extcb]   LINK_CHANGED state=1
I (2595) ch7lab: GOT_IP: 10.0.2.15/255.255.255.0 gw 10.0.2.2
I (2595) [extcb] netif en1 reason=0x04f0      ← DHCP bind 五位复合签名
I (2595) [extcb]   IPv4 settings event (old addr 为空/未变)
```

STATUS 先于 LINK 出现，因为 glue 在驱动 CONNECTED 事件前就完成了 netif_set_up；而 GARP 直到 issue_reports 闸门全开后才放行——对照 7.3 表格的第二处细节即可读懂这个顺序。

### E2：双网卡路由分派实测

目的：验证 `ip4_route` 五步裁决与 lo/en 的分工。直接在 tcpip 线程上下文调用 `ip4_route()` 问路（比猜测更权威），再用 esp_ping 做行为交叉验证：

```text
I (2895) ch7lab: === E2a: ip4_route() 分派表（ctx=tcpip_thread）===
I (2895) ch7lab:   lo-self    127.0.0.1        -> netif lo0 (ip=127.0.0.1)
I (2895) ch7lab:   in-subnet  10.0.2.2         -> netif en1 (ip=10.0.2.15)
I (2895) ch7lab:   dns        10.0.2.3         -> netif en1 (ip=10.0.2.15)
I (2895) ch7lab:   off-subnet 192.168.199.99   -> netif en1 (ip=10.0.2.15)
I (2895) ch7lab: === E2a done ===
I (2895) ch7lab: [stats before-pings] icmp.xmit=0 icmp.recv=0 icmp.err=0 | ip.xmit=2 ip.rterr=0 | link.xmit=1 link.recv=1 link.drop=0
...
I (2895) ch7lab: [ping 10.0.2.2] seq=1 reply time=0 us
I (3095) ch7lab: [ping 10.0.2.2] seq=2 reply time=0 us
I (7795) ch7lab: [stats after-eth-ping] icmp.xmit=0 icmp.recv=2 icmp.err=0 | ip.xmit=4 ip.rterr=0 | link.xmit=2 link.recv=2 link.drop=0
I (7795) ch7lab: [ping 127.0.0.1] seq=1 reply time=0 us
I (7995) ch7lab: [ping 127.0.0.1] seq=2 reply time=0 us
I (12695) ch7lab: [stats after-lo-ping] icmp.xmit=2 icmp.recv=6 icmp.err=0 | ip.xmit=8 ip.rterr=0 | link.xmit=7 link.recv=7 link.drop=0
```

解读四个层次：

1. **lo-self 命中 lo0**：五步流程的②阶段，127/8 前缀直接命中 loop 网卡——7.4 的判决在真实 netif_list 上得到复现。
2. **in-subnet/off-subnet 同答 en1，但走的裁决分支不同**：10.0.2.2/24 属于②的前缀命中；192.168.199.99 不属任何前缀，走到⑤靠 netif_default 放行。日志只能显示最终选择的网卡无法区分二者，但这恰是"默认网卡=en1 所以殊途同归"的场景——若再加第二块物理网卡，off-subnet 的答案才会显出差别。
3. **ping 计数器指纹**：走 eth 的 echo request 经 RAW PCB 直达 `ip4_output`，全程不进 `icmp.c` 的发包函数，所以健康的 eth ping 只见 `icmp.recv` 增加（SLIRP 回来的应答）；而回环请求会被协议栈自己的 ICMP 模块收到并就地生成应答——`after-lo-ping` 里 `icmp.xmit` 因此从 0 变 2。这个 RAW-PCB 与 ICMP 内部函数的统计口径差，ch9/ch15 会正面拆解。（计数器之间偶发的额外波动来自 IPv6 ND 等后台周期的组播杂音，与本实验结论无关。）
4. **背景板里的自证**：`before-pings` 里已有的少量计数是 DHCP 阶段的 UDP 广播残留。

### E3：故障注入——link down 之后世界怎样

目的：直接驱动契约层的转换函数，观察数据面失败传播与恢复路径。注入点故意不走 esp_netif/glue 事件链（生产中应走 ETHERNET_EVENT_DISCONNECTED → esp_netif_action_disconnected），以便在裸契约粒度上核对 7.3 的表格：

```text
I (12695) ch7lab: >>> 注入: netif_set_link_down(en1)，注入前 flags=0x7f link_up=1 up=1
I (12695) [extcb] netif en1 reason=0x0004
I (12695) [extcb]   LINK_CHANGED state=0
I (12695) ch7lab: <<< 注入完成: flags=0x7b link_up=0 up=1（注意 UP 位仍置位）
W (12895) ch7lab: [udp-probe link-down] sendto 失败 rc=-1 errno=118
I (12895) ch7lab: 走 eth 的 ping（预期全超时）：
E (12895) ping_sock: send error=0
W (13795) ch7lab: [ping 10.0.2.2-DOWN] seq=1 TIMEOUT
E (13795) ping_sock: send error=0
W (14695) ch7lab: [ping 10.0.2.2-DOWN] seq=2 TIMEOUT
I (14695) ch7lab: [ping 10.0.2.2-DOWN] 统计: sent=0 recv=0 loss=100%
I (17795) ch7lab: [stats after-down-pings] icmp.xmit=2 icmp.recv=6 icmp.err=0 | ip.xmit=8 ip.rterr=3 | link.xmit=7 link.recv=7 link.drop=0
I (17795) ch7lab: 走 lo 的 ping（预期照常成功——此路不经过物理网卡）：
I (17795) ch7lab: [ping 127.0.0.1-DOWN] seq=1 reply time=0 us
I (17995) ch7lab: [ping 127.0.0.1-DOWN] seq=2 reply time=0 us
I (18195) ch7lab: [ping 127.0.0.1-DOWN] 统计: sent=2 recv=2 loss=0%
I (22695) ch7lab: down 态路由复测：
I (22695) ch7lab:   lo-self    127.0.0.1        -> netif lo0 (ip=127.0.0.1)
I (22695) ch7lab:   in-subnet  10.0.2.2         -> NO ROUTE (ip.rterr+1)
I (22695) ch7lab:   dns        10.0.2.3         -> NO ROUTE (ip.rterr+1)
I (22695) ch7lab:   off-subnet 192.168.199.99   -> NO ROUTE (ip.rterr+1)
```

down 态四条铁律全部现形：

- **flags 只掉了 LINK_UP**（0x7f→0x7b）：管理 UP 未动，与 admin-down 彻底不同路线；
- **UDP sendto 失败 errno=118**：`ERR_RTE(-4)` 经 err_to_errno 映射为 newlib 的 `EHOSTUNREACH=118`（注意与 Linux glibc 的 113 不同——ESP32 上跑的是 newlib 的 errno 编号表），协议栈错误干净地传播到 socket 语义层；
- **route 全灭但有账可查**：本轮 down 窗口内的三次出站尝试（两次 raw echo + 一次 UDP sendto）让 `ip.rterr` 恰好 +3，错误可见可量；随后路由复测的三个 NO ROUTE 会继续累加；
- **127.0.0.1 完全免疫**：lo0 自身 up+link_up+地址有效，②扫描照常命中——**"ping 得通 127.0.0.1"从来不代表物理网络健在**，这是排障时必须破除的错觉。且 down 期间未发生 `etharp_cleanup`（UP 位在），恢复后旧 ARP 缓存无缝复用，这正是 admin/link 双态设计的意图所在。

顺带一提日志里三次出现的 `E ping_sock: send error=0`：这是 esp_ping 的 raw_sendto 失败告警（错误码经它自己的变量流转被打印成 0），与本实验关注点无冲突——真正权威的错误语义在 UDP 探针的 errno 与 `ip.rterr` 计数上。

恢复阶段（C2）的看点是 DHCP 走哪扇门回来：

```text
I (22695) ch7lab: >>> 注入: netif_set_link_up(en1)
I (22695) [extcb] netif en1 reason=0x0004
I (22695) [extcb]   LINK_CHANGED state=1
I (23695) [extcb] netif en1 reason=0x0400      ← 一秒后：孤零零一位 ADDR_VALID
I (23695) [extcb]   IPv4 settings event (old addr 为空/未变)
I (23895) ch7lab: [udp-probe recovered] sendto OK (3 bytes)
```

对比初生时期的复合签名 `0x04f0`，这里只有 `0x0400`——address/netmask/gateway 三项均未产生 CHANGED 位（值没变，`netif_do_set_*` 的相等短路生效），唯有"设置流程末尾无条件追加"的 `LWIP_NSC_IPV4_ADDR_VALID` 到场。这精确对应 7.3 的第三处细节：`dhcp_network_changed_link_up()` 把 BOUND 态推向 `dhcp_reboot()` 快速续租而非 INIT rediscover——DHCP 客户端根本不需要从头再来。紧随其后的 UDP 探针一次成功、终态 dump 里 flags 回到 `0x7f`，数据面在毫秒级无痕复原。

---

## 7.7 小结

- netif 是 lwIP 的"端口层契约"：`input/output/linkoutput` 三个函数指针 + `flags/mtu/hwaddr` 能力申报由驱动 init_fn 一次性填妥；内核从此对网卡介质零知识。
- 契约与状态同住一个结构体：地址三元组、UP/LINK_UP 位是随时被改写的活状态；`sizeof(struct netif)=260`（本环境实测），它随 `netif_add` 头插进 `netif_list`，later-first 的遍历顺序要记牢。
- 背指针双轨制：常规 `state` 单槽即够；DHCP 等内部组件走 `client_data[]` 保留槽位；esp_netif 开 PPP/bridge 时被迫切到 client_data 存自身句柄。
- 管理态与物理态是不对称的双开关：admin-down 清 ARP 表掐断缓存，link-down 只掐数据面不动缓存与 DHCP 配置；link-up 的 DHCP 恢复路径是 reboot 续租（事件签名只剩 `LWIP_NSC_IPV4_ADDR_VALID=0x0400`）而非重 discover。
- ext-callback 是位掩码多订阅者广播，同一次 set_addr 可能五位复合（`0x04f0` 是初次 DHCP bind 的标准签名）；它正是 esp_netif 把 lwIP 事件翻译成 IP_EVENT 的国境口岸，你的代码也可以并列挂一个观察者。
- `ip4_route` 五步裁决：组播特例 → 前缀/点对点扫描（要求 up+link_up+有地址）→ loopback 兜底分支 → 路由钩子 → 默认网卡终审（再审不过则 `rterr++` 返回 NULL）；子网内目的地根本轮不到"默认路由"出场。
- loopback 是寄生网卡：2.2.0-dev 已无 `src/netif/loopif.c`，由 `netif_init()` 在 tcpip_init 内自动诞生（IDF 默认 `CONFIG_LWIP_NETIF_LOOPBACK=y`）；127 流量走 `pbuf_copy` + 内存队列 + 直接 `ip_input`，零以太网帧零驱动参与，因此永远不被 link down 波及。
- 实操双坑留档：`.addr` 构造必须 `PP_HTONL(LWIP_MAKEU32(a,b,c,d))`（手写常数会被当作另一地址）；`ipaddr_ntoa` 共享静态缓冲区，多点打印必须用 `_r` 变体各配 buffer。
- 操作 netif 的唯一线程纪律：全部 API 带 core-lock 断言，应用侧用 `tcpip_callback()` 投递——单线程邮箱模型对所有共享状态一视同仁。

到这里，协议栈已经知道自己有哪些网卡、每个包该从哪张脸出去、网卡抽风时错误如何逐级上抛。但以太网发出去之前还有一个必答题没讲：`netif->output` 挂着的 `etharp_output` 到底怎么把 IP 地址变成 MAC？ARP 表长什么样、请求/应答如何在 SLIRP 网络里往来、那张被 link-down 饶过不清理的缓存究竟藏着什么？下一章 [[2026-08-26-lwip-deep-dive-ch8-ethernet-arp|第八章：以太网帧与 ARP：从 IP 到 MAC 的最后一公里]] 进入 `src/core/ipv4/etharp.c` 与 `src/netif/ethernet.c`，把每一帧出门前的最后一步拆到字节级。
