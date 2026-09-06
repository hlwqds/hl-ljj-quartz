---
title: "lwIP 深度解析（二）：ESP-IDF 网络架构总览：从网口到 socket"
date: 2026-08-26
description: "用一张组件栈全景图回答'一个字节从网卡到 socket read() 要穿过几层'：esp_eth/esp_wifi → esp_netif → lwIP core + port/esp32xx 适配层 → VFS socket 层 → POSIX API。拆解 esp_netif_t 与 lwIP struct netif 的包装关系（netif->state/client_data 双通道背指针）、ETH_EVENT→IP_EVENT 的完整事件翻译链、port/esp32xx 逐文件职责，并给出 Vanilla lwIP 与 ESP-IDF lwIP 的对照与 LWIP_STATS 统计基线实验。"
tags: [lwip, network, esp32, esp-idf, architecture]
---

> [!info] lwIP 深度解析系列 0. [[lwip-deep-dive|系列索引]] 2. **第 2 章：ESP-IDF 网络架构总览：从网口到 socket**

# lwIP 深度解析（二）：ESP-IDF 网络架构总览：从网口到 socket

这一章回答三个问题：**一个字节从网卡到达 `socket read()` 到底穿过几层**（每层的名字、职责和源码位置）、**esp_netif 这个"额外层"为什么存在**（IDF 的答案：统一 WiFi / 以太网 / PPP 的上界面）、**IDF 的 lwIP 和 Vanilla lwIP 谁在掌舵**（协议栈本身几乎没改，改的是"驾驶舱"）。读完它，你应该能在调试任何网络问题时先问一句"这个现象发生在哪一层"，而不是在错误的地方翻源码。源码参照版本：ESP-IDF **v6.0.2**（`~/esp/esp-idf`），捆绑 lwIP **2.2.0-dev**（`components/lwip/lwip/src`）。

---

## 2.1 核心问题三连

### 1. 一个字节的路程

从 QEMU 的 openeth 网卡收到一帧开始，到应用程序在 `read()` 里拿到这批数据，逐层点名：

```text
QEMU SLIRP 投递以太网帧
  ↓
emac_rx 任务          （esp_eth/src/openeth/…create 的收包任务）
  ↓ esp_eth_receive()
  ↓ input path 回调   （glue 在 attach 时通过 esp_eth_update_input_path_info 注入）
  ↓ esp_netif_receive()                    ← components/esp_netif
  ↓ ethernetif_input()                     ← esp_netif/lwip/netif/ethernetif.c
  │    └─ esp_pbuf_allocate(): 驱动 buffer 上直接套 pbuf（零拷贝）
  ↓ netif->input = tcpip_input()           ← 消息投进邮箱，切换到 tcpip_thread
  ↓ ethernet_input() → etharp / ip4_input / udp_input / tcp_input
  ↓ pcb 排队 + 唤醒等待者（per-thread 信号量）
  ↓
应用任务：read() 返回，收工。
```

粗数一下：**驱动任务 → esp_eth 输入回调 → esp_netif_receive → ethernetif_input（pbuf 化）→ 邮箱 → tcpip_thread 协议处理 → socket 接收队列 → 应用任务**——8 个命名站点、2 次上下文切换（rx 任务→tcpip_thread→应用）。哪一站出了问题就在哪一站找证据，这是全系列的地图。

TX 方向的清单同样值得背下来（以后第六章零拷贝分析就在这条线上做）：

```text
应用任务 write(fd)/sendto()
  ↓ VFS 表项路由（fd ≥ 54）→ lwip_write / lwip_sendto
  ↓ netconn API：封成 API 消息投进 tcpip_thread 邮箱（又一次切换）
  ↓ tcp_write → PCB 发送队列 → ip4_output → etharp_output
  ↓ netif->linkoutput = ethernet_low_level_output()
  ↓ esp_netif_transmit() → driver_transmit()（= esp_eth_transmit）
  ↓ MAC 驱动寄存器/DMA —— 离机
```

还有一个容易搞混的双入口事实，已对照头文件核实：`socket()/connect()/sendto()` 这类纯 socket 符号在编译期就是宏，直落 lwIP 的实现（`src/include/lwip/sockets.h`：`#define socket(...) lwip_socket(...)`）；而 `read()/write()/select()` 与文件系统共享语义，必须经 VFS 按 fd 区间分发后才落到 `lwip_read/lwip_select`。两条入口最终在 netconn 层汇合——所以"我的 sendto 调用到底走了 VFS 吗"这种问题有明确答案：没有。

### 2. esp_netif 为什么存在

Vanilla lwIP 有自己的接口抽象：`struct netif`。那 IDF 为什么还要再包一层 `esp_netif_t`？看三个动机，全部可在源码中验证：

1. **多物理介质统一上界面**。WiFi STA、WiFi AP、有线以太网、PPP 串口，四种介质的"启动、连接、拿 IP"生命周期完全不同；esp_netif 把它们收编成同一组动作（`esp_netif_attach` → `esp_netif_action_start` → `esp_netif_action_connected`）和同一个事件模型（`ESP_NETIF_IP_EVENT_GOT_IP`）。上层应用代码因此与介质无关。
2. **管理 TCP/IP 栈之外的状态**。lwIP 的 `netif` 只管协议面；DHCP 客户端状态机的人话版状态（`dhcpc_status`）、每网卡自己的 GOT_IP/LOST_IP 事件号、静态 IP 副本 `ip_info`、路由优先级 `route_prio` 这些"设备管理"信息，都放在 esp_netif 里（见 2.3 节结构体证据）。
3. **可替换的网络栈底座**。menuconfig 里 `ESP_NETIF_USE_TCPIP_STACK_LIB` 是一个 choice（默认 `ESP_NETIF_TCPIP_LWIP`，另有 loopback 等），esp_netif 对 TCP/IP 栈只假设了一个窄接口（init_fn/input_fn/transmit 三板斧）。换栈不换应用事件模型。

### 3. 谁在掌舵：IDF 改了 lwIP 吗？

结论先行：**协议核的主体是 Vanilla 的，运行骨架是被重新接线的；但并非零改动**。把 `grep -r "ESP_LWIP" src/core` 扫一遍就会发现，Espressif 确实在 lwIP 内核文件里埋了若干条件补丁：例如 `tcp.c` 的 RTO 重传背退把 SYN*RCVD 也算进例外、`ip4.c` 给 NAPT 加了转发挂点、一族 `ESP_LWIP*\*\_TIMERS_ONDEMAND`让 IGMP/DHCP/重组定时器按需启动。不过这些改动的形态非常克制：**全部是`#if ESP_LWIP`包裹的编译期分支**（宏定义在`port/include/lwipopts.h`），而不是另起一套源码。主体逻辑与上游一致，改动集中在三处外围：

| 改动位置                                  | 干什么                                                                                                                     |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `components/lwip/port/**`                 | sys_arch（FreeRTOS 线程/信号量/邮箱原语实现）、VFS socket 注册、hooks 默认实现                                             |
| `components/lwip/port/include/lwipopts.h` | 把 sdkconfig 的每个 `CONFIG_LWIP_*` 映射成 lwIP 宏，裁剪面全在这一个文件；`#define ESP_LWIP 1` 开关内核里的 Espressif 补丁 |
| `components/esp_netif/lwip/**`            | 用 lwIP 正规 API（netif_add/netif_ext_callback）搭出 esp_netif 封装                                                        |

换句话说，第 4~14 章讲的所有 lwIP 核心机制，读的都是以 Vanilla 为主体、ESP_LWIP 微调过的代码；而"单线程 tcpip_thread + 邮箱"这条贯穿全系列的暗线，控制在 IDF 手里——`LWIP_TCPIP_CORE_LOCKING` 默认关（Kconfig `LWIP_TCPIP_CORE_LOCKING` default n），所有跨线程调用排队走邮箱，实验输出会实证这一点（`CORE_LOCKING = 0`）。

> [!note] 一句话版本
> ESP-IDF 网络子系统 = 以 Vanilla 为主体、仅带 ESP_LWIP 条件微调的 lwIP 内核 + FreeRTOS 移植层（port/）+ esp_netif 外交部（统一的接口管理/事件翻译）+ VFS 化的 BSD socket 出口。

---

## 2.2 组件栈全景图

```text
                应用任务 (app task)
                 │ POSIX: socket()/bind()/read()/write()
═════════════════▼═══════════════════════════════════ fd 54..63 ═══
│ VFS socket 层                                                      │
│   esp_vfs 按 fd 区间分发：                                          │
│   [LWIP_SOCKET_OFFSET, MAX_FDS) = [54,64) 归 lwIP                   │
│   vfs_lwip.c: read/write/close/fcntl/ioctl/fstat/select             │
├───────────────────────────────────────────────────────────────────┤
│ lwIP API 层                                                        │
│   BSD sockets (api_msg.c)  ·  netconn (api_lib.c)                  │
├───────────────────────────────────────────────────────────────────┤
│ tcpip_thread —— 单线程核心（prio 默认18, mbox 默认32 条）           │
│   RX: TCPIP_MSG_INPKT   控制: TCPIP_MSG_API / _CALLBACK            │
├───────────────────────────────────────────────────────────────────┤
│ lwIP core                                                          │
│   ethernet_input → etharp / ip4_input → udp/tcp → netconn 队列      │
│   src/core/, src/core/ipv4/, src/netif/ (上游主体+ESP_LWIP 微调)     │
╞═══════════════════════ 衔接带 ═════════════════════════════════════╡
│ struct netif                                                       │
│   netif_add(..., esp_netif, ethernetif_init, tcpip_input)           │
│   output=etharp_output · linkoutput=ethernet_low_level_output        │
│   组件: components/lwip + esp_netif/lwip/netif/ethernetif.c         │
├───────────────────────────────────────────────────────────────────┤
│ esp_netif (esp_netif_t)                                            │
│   容器/状态机/事件翻译/DHCP 管理          components/esp_netif/      │
├───────────────────────────────────────────────────────────────────┤
│ IO 驱动 glue                            esp_netif_set_driver_config │
│   esp_eth_netif_glue.c(以太网) / wifi glue / esp_netif_lwip_ppp.c   │
├───────────────────────────────────────────────────────────────────┤
│ MAC/PHY 驱动                                                        │
│   esp_eth_mac_openeth.c(QEMU) / emac_esp_dma(真机) → emac_rx 任务    │
═════════════════════════════════════════════════════════════════════
                 ▼ 网线/QEMU SLIRP
```

两个衔接点是理解全局的关键：

- **下半段（驱动侧）靠函数指针向上收敛**：MAC 驱动把收到的一帧交给 attach 时注入的 input 回调（对以太网是 `esp_netif_receive()`），esp_netif 再调 lwIP 侧注册的 `lwip_input_fn`（以太网为 `ethernetif_input()`）；
- **上半段（协议栈内部）靠邮箱向上串行化**：`netif->input` 固定挂 `tcpip_input()`，数据帧变成消息进入 tcpip_thread 的 mailbox。从此整个协议核心只在单一线程跑——这正是暗线 A 的入口，[[ch13-tcpip-thread-mailbox|第十三章]] 拆它的机制细节。

分层职责速查表：

| 层           | 职责一句话                                 | 关键数据结构               | 源码位置（v6.0.2）                                |
| ------------ | ------------------------------------------ | -------------------------- | ------------------------------------------------- |
| MAC/PHY 驱动 | 帧/字节搬运、DMA、中断                     | `eth_handle_t`, MAC config | `components/esp_eth/src/{mac,openeth,phy}/`       |
| IO glue      | 把驱动函数表塞给 esp_netif、订阅 ETH_EVENT | `esp_eth_netif_glue_t`     | `components/esp_eth/src/esp_eth_netif_glue.c`     |
| esp_netif    | 接口容器、DHCP/IP 状态、事件翻译           | `struct esp_netif_obj`     | `components/esp_netif/`                           |
| lwIP 接口层  | lwIP 视角的网卡抽象                        | `struct netif`             | `components/esp_netif/lwip/netif/ethernetif.c` 等 |
| lwIP core    | ARP/IP/ICMP/UDP/TCP 协议本体               | `struct pbuf`, PCB 族      | `components/lwip/lwip/src/core/`                  |
| tcpip_thread | 单线程执行体 + 消息泵                      | `tcpip_msg`, `sys_mbox_t`  | `src/api/tcpip.c`, `port/freertos/sys_arch.c`     |
| API/VFS 层   | socket fd 与 POSIX read/write 打通         | `lwip_sock`, VFS 表项      | `src/api/sockets.c`, `port/esp32xx/vfs_lwip.c`    |

---

## 2.3 esp_netif 深入：包装关系、attach 流程与事件流

### 1. 数据结构：谁包含谁

esp_netif 不是继承也不是重写 lwIP 的 netif，而是**组合（containment）**。`components/esp_netif/lwip/esp_netif_lwip_internal.h` 里躺着本体定义（删节摘录，字段均经核实）：

```c
/* esp_netif/lwip/esp_netif_lwip_internal.h — Main esp-netif container */
struct esp_netif_obj {
    uint8_t mac[NETIF_MAX_HWADDR_LEN];
    esp_netif_ip_info_t* ip_info;        /* 管理面的地址副本 */
    esp_netif_ip_info_t* ip_info_old;

    // lwip netif related
    struct netif *lwip_netif;            /* ← 核心：包着真正的 lwIP netif */
    err_t (*lwip_init_fn)(struct netif*);      /* 由默认配置提供: ethernetif_init 等 */
    esp_err_t (*lwip_input_fn)(void *handle, void *buffer, size_t len, void *eb);
    void * netif_handle;                 /* vanilla netif 或 ppp_pcb */

    // io driver related                   ← attach 时由驱动填入
    void* driver_handle;
    esp_err_t (*driver_transmit)(void *h, void *buffer, size_t len);
    void (*driver_free_rx_buffer)(void *h, void* buffer);
    ...

    // dhcp related / event translation
    esp_netif_dhcp_status_t dhcpc_status; /* INIT/STARTED/STOPPED 人话状态机 */
    ip_event_t get_ip_event;              /* 本网卡拿到 IP 时发哪个事件号 */
    ip_event_t lost_ip_event;

    // misc flags, types, keys, priority
    esp_netif_flags_t flags;
    char * if_key;                        /* "WIFI_STA_DEF"/"ETH_DEF" ... */
    char * if_desc;
    int route_prio;
};
```

三个读法要点：

1. `lwip_netif` 字段证明方向：**esp_netif 拥有 lwIP netif**，创建时 `calloc(1, sizeof(struct netif))`（`esp_netif_lwip.c` 的 `esp_netif_lwip_add()`），销毁时一起 free。
2. `lwip_init_fn`/`lwip_input_fn` 证明适配面极窄：esp_netif 对 lwIP 只需要"怎么初始化一张接口"和"一个上行的 input 函数"两个钩子，其余全部复用 lwIP 原生机制。
3. `get_ip_event` 字段解释了为什么 WiFi 用户等 `IP_EVENT_STA_GOT_IP`、以太网用户等 `IP_EVENT_ETH_GOT_IP` 而代码却一模一样——事件号是建网卡时的配置参数，不是硬编码分支。

反向指针对：从 lwIP netif 找回 esp_netif，用的是 `netif_client_data`（或 `state` 槽位）。`esp_netif_lwip.c` 里的内联函数给了官方答案：

```c
static inline esp_netif_t* lwip_get_esp_netif(struct netif *netif)
{
#if LWIP_ESP_NETIF_DATA
    return (esp_netif_t*)netif_get_client_data(netif, lwip_netif_client_id);
#else
    return (esp_netif_t*)netif->state;   /* 常规路径 */
#endif
}
```

常规配置下走的是 `netif->state`：`esp_netif_lwip_add()` 调 `netif_add(esp_netif->lwip_netif, ..., esp_netif/*state 参数*/, esp_netif->lwip_init_fn, tcpip_input)`，lwIP 的 `netif_add()` 会先把 state 参存入 `netif->state`（`src/core/netif.c`：`netif->state = state;`）再调用 init_fn——所以 `ethernetif_init()` 开头才能写出 `esp_netif_t *esp_netif = netif->state;`。而一旦启用 PPP 或网桥（`CONFIG_PPP_SUPPORT` / `CONFIG_ESP_NETIF_BRIDGE_EN`），lwIP 自己要用 `netif->state` 装 `ppp_pcb` 或 bridge 配置，lwipopts.h 就切到 client_data 通道（`LWIP_ESP_NETIF_DATA` 定义处注释原话：`netif->state is used internally and we must store esp-netif ptr in netif->client_data`）。

### 2. attach 流程：四步接线

以以太网为例（ch3 的 QEMU openeth 走同一条路）：

```text
①  esp_netif_new(ESP_NETIF_DEFAULT_ETH())
      └─ 复制默认配置: init_fn/input_fn 来自 _g_esp_netif_netstack_default_eth,
         get_ip_event = IP_EVENT_ETH_GOT_IP     (include/esp_netif_defaults.h)

②  esp_netif_attach(esp_netif, esp_eth_new_netif_glue(eth_handle))
      └─ esp_netif_attach() 只做一件事: 调驱动的 post_attach 回调

③  esp_eth_post_attach()                          (esp_eth_netif_glue.c)
      ├─ esp_eth_update_input_path_info(handle, eth_input_to_netif, esp_netif)
      │       /* 驱动收到的每一帧从此投递给这个回调, priv=esp_netif */
      └─ esp_netif_set_driver_config(esp_netif, &driver_ifconfig)
              .transmit            = esp_eth_transmit      /* TX 下行出口 */
              .driver_free_rx_buffer = eth_l2_free
              .driver_set_mac_filter = eth_set_mac_filter
      随后 esp_netif_set_mac() 同步 MAC 到 esp_netif.mac

④  （以太网通常 AUTOUP）esp_netif_start → start_api:
      esp_netif_lwip_add():
          calloc struct netif
          netif_add(netif, &ip/gw/mask, esp_netif, ethernetif_init, tcpip_input)
              └─ ethernetif_init(): name="en",
                 netif->output     = etharp_output   /* IPv4 出口 */
                 netif->output_ip6 = ethip6_output
                 netif->linkoutput = ethernet_low_level_output /* 真正发包 */
          lwip_set_esp_netif(netif, esp_netif)  /* 反向背指针 */
      ESP_NETIF_FLAG_AUTOUP ⇒ netif_set_up() + netif_set_link_up()
```

一条隐藏纪律值得圈出：**esp_netif 的控制类操作（start/stop/up/down/dhcp）必须在 tcpip_thread 里执行**。封装手法与判定代码都在 `esp_netif_lwip.c`：

```c
static inline esp_err_t esp_netif_lwip_ipc_call_msg(esp_netif_api_msg_t *msg)
{
    if (!sys_thread_tcpip(LWIP_CORE_LOCK_QUERY_HOLDER)) {      /* 不在核心线程 */
        sys_arch_sem_wait(&api_lock_sem, 0);                   /* 串行化并发调用 */
        tcpip_send_msg_wait_sem((tcpip_callback_fn)esp_netif_api_cb,
                                msg, &api_sync_sem);           /* 邮箱投递 + 等回执 */
        sys_sem_signal(&api_lock_sem);
        return msg->ret;
    }
    return msg->api_fn(msg);                                   /* 本来就在核心线程: 直呼 */
}
/* esp_netif_up / esp_netif_start / esp_netif_dhcpc_stop ... 一律经宏展开到这里:
   esp_err_t esp_netif_up(esp_netif_t*n) _RUN_IN_LWIP_TASK(esp_netif_up_api, n, NULL) */
```

也就是说，你在任何应用任务里随手调 `esp_netif_dhcpc_start()`，它其实已经在 tcpip_thread 执行完才返回——免锁，但每次调用付出一次上下文往返的价格（第 13 章会量化这条路）。

### 3. 事件流：DHCP 结果如何变成 IP_EVENT_STA_GOT_IP

esp_event 流量分成两个 base：驱动事件走 `ETH_EVENT`/`WIFI_EVENT`，IP 结果走 `IP_EVENT`。中间的翻译器就是 esp_netif，它是 lwIP `netif_ext_callback` 机制的一个正经用户：

```text
tcpip_thread (DHCP 完成)                       eth/default 事件循环
────────────────────────────                 ────────────────────────
dhcp_bind(): 写入 netif->ip_addr/gw/mask
  └ netif_set_addr() → netif_invoke_ext_callback(
        LWIP_NSC_IPV4_SETTINGS_CHANGED...)      (src/core/netif.c)
      └ netif_callback_fn()               ← esp_netif 全局注册的 ext callback
          └ esp_netif_internal_dhcpc_cb()
              ├ 拷贝 ip_addr → esp_netif->ip_info
              ├ evt_id = esp_netif_get_event_id(esp_netif, GOT_IP)
              │        (= IP_EVENT_STA_GOT_IP 或 IP_EVENT_ETH_GOT_IP …)
              └ esp_event_post(IP_EVENT, evt_id, &evt)  ───────→  你的 handler
```

下行触发同样优雅：以太网连线时驱动先发 `ETH_EVENT`（`ETHERNET_EVENT_START/CONNECTED`），glue 里的 `eth_action_*` 只是转发给 `esp_netif_action_start/connected()`（`esp_netif_handlers.c`）；后者 `esp_netif_up()` + 若 DHCP 客户端还处于 INIT 就 `esp_netif_dhcpc_start()`。于是**同几个 action 函数被 WiFi/以太网两种 glue 共用**，这是 esp_netif"外交官"价值的现场演示。 另外，`netif_callback_fn` 还监听 link/status 变化统一发 `IP_EVENT_NETIF_UP/DOWN`，以及 `NETIF_FLAG_GARP`（周期免费 ARP，Kconfig 默认开 60s）这类小装饰都在此文件顺路完成。

> [!tip] 静态 IP 分支也在同一函数里
> `esp_netif_action_connected()` 末尾检查 `ESP_NETIF_DHCP_STOPPED` 且持有合法静态 IP 时，不等 DHCP 直接 `esp_event_post(IP_EVENT, ...)`。所以"DHCP 模式和静态 IP 模式共用同一个 GOT_IP 事件",排障时应先确认 `dhcpc_status` 到底处于哪个状态。

---

## 2.4 lwIP 适配层解剖：port 目录逐文件清单

按 CONVENTIONS 指定的目录 `components/lwip/port/esp32xx/` 通读一遍，加上外围兄弟目录，给出指纹级清单（行数为 v6.0.2 实测）：

**`port/esp32xx/`（socket-VFS 语境下的 esp32x 公共件）**

| 文件                   | 行数 | 职责                                                                                                                                                                                                                                                                                                                                                                                                          |
| ---------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vfs_lwip.c`           | 142  | 把 lwIP socket 注册成一个 VFS 设备：`esp_vfs_register_fd_range(LWIP_SOCKET_OFFSET..MAX_FDS)`，read/write/close/fcntl/ioctl/fstat 全部转发给 `lwip_*` 函数；select 走 `s_lwip_select_ops`（唤醒令牌来自 per-thread 信号量）。文件开头三条 `_Static_assert` 是很好的边界教育：`MAX_FDS >= CONFIG_LWIP_MAX_SOCKETS`、`FD_SETSIZE >= CONFIG_LWIP_MAX_SOCKETS`、`LWIP_SOCKET_OFFSET >= 6`（前 6 个 fd 留给 stdio） |
| `no_vfs_syscalls.c`    | 75   | `CONFIG_VFS_SUPPORT_IO=n` 时的降级路径：直接覆盖 newlib 的 `_write_r/_read_r/_close_r/fcntl/ioctl/select`，fd < LWIP_SOCKET_OFFSET 落到 console 实现。和 vfs 版二选一编译                                                                                                                                                                                                                                     |
| `include/arch/cc.h`    | —    | lwIP 平台抽象：小端宏、`htons/ntohl` 直接映射 `__builtin_bswap*`、断言裁剪（`CONFIG_LWIP_ESP_LWIP_ASSERT` 决定 `LWIP_NOASSERT`）                                                                                                                                                                                                                                                                              |
| `include/sys/socket.h` | 17   | POSIX 兼容垫片：`sys/socket.h` 重定向到 `lwip/sockets.h` 并捎上 `<net/if.h>` 的 `SOMAXCONN`                                                                                                                                                                                                                                                                                                                   |
| `netif/dhcp_state.c`   | —    | 把 DHCP 拿到的最后 IP 存进 NVS（namespace `"dhcp_state"`，key 为 netif->num），重启时由 lwIP 的 restore 钩子取回，配合 `CONFIG_LWIP_DHCP_RESTORE_LAST_IP`                                                                                                                                                                                                                                                     |

**`port/` 其余成员**

| 文件                            | 职责                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `freertos/sys_arch.c`（592 行） | lwIP `<sys_arch.h>` 全家桶的 FreeRTOS 实现：`sys_sem_new/sys_mbox_new` 直映 xSemaphore/xQueue；`sys_thread_new()` 一行关键代码 `xTaskCreatePinnedToCore(thread, name, stacksize, arg, prio, ..., CONFIG_LWIP_TCPIP_TASK_AFFINITY)`；`sys_init()` 里创建 per-thread TLS key（供每个任务一个 select 唤醒信号量）并顺手完成 **VFS socket 注册**——所以只要 tcpip_thread 起来，POSIX socket 自动可用；`sys_now()` 基于 tick 提供毫秒时钟 |
| `hooks/lwip_default_hooks.c`    | 各 `CONFIG_LWIP_HOOK_*_DEFAULT` 选择项的默认弱实现（ip6 route/nd6 gw/ip6 input 选源址/DHCP extra option 等）                                                                                                                                                                                                                                                                                                                        |
| `hooks/tcp_isn_default.c`       | RFC 6528 TCP ISN 算法（MD5 四元组 + 启动期注入的 16 字节随机 secret + 时间戳），`CONFIG_LWIP_HOOK_TCP_ISN_DEFAULT` 使能；secret 由 `esp_netif_init()` 启动早期用 bootloader 种好的随机源灌入                                                                                                                                                                                                                                        |
| `apps/netdb`（`esp_netdb.c`)    | `esp_getaddrinfo()`：AF_UNSPEC 时先 IPv4 后 IPv6 两次查询再拼接结果链                                                                                                                                                                                                                                                                                                                                                               |
| `sockets_ext.c`                 | IPv6 相关 setsockopt 的扩展实现（供 sockets.c 钩住）                                                                                                                                                                                                                                                                                                                                                                                |
| `acd_dhcp_check.c`              | DHCP 提议地址冲突检测（ACD：ARP probe）计时逻辑                                                                                                                                                                                                                                                                                                                                                                                     |
| `if_index.c`                    | POSIX `if_nametoindex/if_indextoname` 转发到 lwIP `if_api`                                                                                                                                                                                                                                                                                                                                                                          |

**`components/esp_netif/lwip/`（esp_netif 的 lwIP 后端）**

| 文件                        | 行数 | 职责                                                                                                                                                                                          |
| --------------------------- | ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `esp_netif_lwip.c`          | 3020 | 全部实现核心：本节 2.3 的结构体背指针/netif_add/DHCP 回调/IPC 机制全在这；另含 IGMP/MLD mac filter 桥接、DNS per-netif、GARP 计时等                                                           |
| `esp_netif_lwip_defaults.c` | 76   | 四份默认网络栈配置（`_g_esp_netif_netstack_default_eth/wifi_sta/wifi_ap/ppp`），内容只有两行类型的东西：`.lwip.init_fn = ethernetif_init, .input_fn = ethernetif_input`——默认接线表的实物形态 |
| `esp_netif_lwip_ppp.c`      | 394  | PPP 专用（pppapi 包装、phase/error 事件）                                                                                                                                                     |
| `esp_netif_br_glue.c`       | 404  | 802.1D 网桥 glue（`CONFIG_ESP_NETIF_BRIDGE_EN`）                                                                                                                                              |
| `esp_netif_sntp.c`          | 202  | SNTP 封装                                                                                                                                                                                     |
| `netif/ethernetif.c`        | 188  | 以太网接口模板：RX 侧把驱动 buffer 包成 `esp_pbuf_allocate()` 的自定义 pbuf（零拷贝进协议栈）、TX 侧单 pbuf 直接传 payload、pbuf 链才退化为复制                                               |
| `netif/wlanif.c`            | —    | WiFi STA/AP/NAN 接口模板，结构与 ethernetif 同构                                                                                                                                              |
| `netif/esp_pbuf_ref.c`      | —    | 自定义 pbuf 类型：payload 就是驱动接收 buffer，靠 ref-count + 驱动提供的 free 回调归还，减少一次 memcpy                                                                                       |

> [!warning] 读源码别迷路
> lwIP 内核在 `components/lwip/lwip/src/`（上游主体，个别处有 `#if ESP_LWIP` 微调），而"哪些功能被编译进来"的开关在 `components/lwip/port/include/lwipopts.h`。grep 一个 lwIP 符号前先想清楚它在哪一侧——两边文件树相似度很高，搜错树会白忙一场。

---

## 2.5 并发视角预览：谁在哪个线程

到目前为止的所有主角都是 RTOS 任务。定位汇总（默认配置实测值出自本章实验，机制展开留给后续章节）：

| 任务名                      | 创建点                                                                                                                 | 优先级/亲和（默认）                                                                                                                                   | 职责与边界                                                           |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `main_task` / 你的 app task | esp_system 启动流程                                                                                                    | 1 / CPU0（main_task）                                                                                                                                 | 调 POSIX socket API；也常是 esp_netif 控制调用发起方（自动转投邮箱） |
| `sys_evt`                   | `esp_event_loop_create_default()`                                                                                      | `ESP_TASKD_EVENT_PRIO` = configMAX_PRIORITIES−5（configMAX_PRIORITIES=25，即 20；`components/esp_system/include/esp_task.h`），压过 tcpip_thread 一头 | 执行 ETH_EVENT/`IP_EVENT` 用户 handler；注意 handler 里别做重活      |
| `tcpip_thread`              | `tcpip_init()`（tcpip.c:`sys_thread_new(TCPIP_THREAD_NAME,...)`，名字也确认过）                                        | `LWIP_TCPIP_TASK_PRIO`=18 / 无亲和（实验值 `tskNO_AFFINITY`）                                                                                         | 全部协议处理 + esp_netif 控制 IPC 的落点。**独占 lwIP core**         |
| `emac_rx`                   | MAC 驱动创建（真机 DMA 与 openeth 同名）：`xTaskCreatePinnedToCore(emac_..._rx_task,"emac_rx",..., rx_task_prio, ...)` | 可配（MAC flags 决定绑核）                                                                                                                            | ISR 之后的中半场：把帧搬出来打给 input path；不在本任务里跑协议      |
| ping/定时类                 | lwIP timeout 机制统一挂在 tcpip_thread 的时间轴上                                                                      | —                                                                                                                                                     | arp/GARP/dhcp renew/timers 全部不是独立任务（前提：系统时钟源正确）  |

两个立刻能兑现的正确姿势：

1. **handler 里别碰协议**：`sys_evt` 收到 `IP_EVENT_STA_GOT_IP` 后如果直接用 raw API 发包，等于绕过邮箱从另一个线程戳 lwIP core（socket API 没事，raw API 禁止）。想要这种能力请投递回你的工作任务，或阅读第 13 章的合法通道。
2. **tcpip_thread 卡死 = 全网停摆**：它的栈（默认 3072B，Kconfig `LWIP_TCPIP_TASK_STACK_SIZE`）供所有协议+控制 IPC 使用；大量并发长连接与密集 esp_netif 调用时留意溢出记录点。

WiFi 路线与此同构、仅岗位名字不同（第十八章的主角）：esp_wifi 内部收发不再经过 esp_eth 的 `emac_rx`，而是 WiFi 驱动自己的任务把 802.11 帧转成以太帧形状后调同一个 `esp_netif_receive()`；attach 由 `components/esp_wifi/src/wifi_default.c` 的 `esp_netif_attach_wifi_station()` 完成（默认事件号正是 `IP_EVENT_STA_GOT_IP`）。换句话说，2.2 图从"衔接带"以上完全不变，以下换成 WiFi 驱动栈——esp_netif 统一界面的意义在换介质时看得最清楚。

---

## 2.6 Vanilla lwIP 与 ESP-IDF lwIP 对照

### 1. bring-up 步骤对照

裸 lwIP 移植一篇 netif 你要自己写，IDF 把标准答案预填好了：

| 步骤            | Vanilla lwIP                                      | ESP-IDF                                                               |
| --------------- | ------------------------------------------------- | --------------------------------------------------------------------- |
| OS 模式声明     | `NO_SYS 0` 写进 opt.h                             | menuconfig 强制（实验打印 `NO_SYS = 0`，无 UI 选项）                  |
| 启动内核线程    | `tcpip_init(NULL,NULL)`                           | `esp_netif_init()` 内部代调（含 TCPIP 初始化信号同步）                |
| 准备接口对象    | 手写 `struct netif my_netif` + `my_netif.name` 等 | `esp_netif_new(&cfg)`（或 default 宏一步到位）                        |
| 接口初始化钩子  | `netif_add(..., my_ethernetif_init, tcpip_input)` | 同样是 `netif_add`，init_fn 由 stack_default 提供，state 即 esp_netif |
| 连接/断链副作用 | 用户自行 `netif_set_link_up` + `dhcp_start`       | 事件驱动：`ETHERNET_EVENT_CONNECTED` → action 链自动补齐              |
| 结果通知        | 自己轮询 or 顺 extension callback                 | `IP_EVENT_*` 现成                                                     |
| 发送方向        | 实现 `low_level_output` 摆平一切                  | 只需给 glue 提供 transmit 回调，pbuf 链细节已封装                     |

### 2. Kconfig 裁剪面（IDF 相当于 lwipopts 的可操作面板）

| Kconfig                                   | 默认      | 说明                                                                          |
| ----------------------------------------- | --------- | ----------------------------------------------------------------------------- |
| `LWIP_TCPIP_CORE_LOCKING`                 | **n**     | 保持经典邮箱模型；开则多一把全局锁，配 `..._LOCKING_INPUT` 决定 RX 是否绕邮箱 |
| `LWIP_TCPIP_TASK_PRIO` / `STACK_SIZE`     | 18 / 3072 | 高吞吐可上调优先级，help 原文允许"up to configMAX_PRIORITIES-1"               |
| `LWIP_TCPIP_RECVMBOX_SIZE`                | 32        | tcpip_thread 信箱深度，窗口放大场景建议联动调整                               |
| `LWIP_STATS`                              | **n**     | 统计默认关闭省 RAM；要观测需手动打开（见实验）                                |
| `LWIP_ESP_GRATUITOUS_ARP` (+interval 60s) | y         | IDF 加味：定期 GARP 抗 AP 表老化                                              |
| `LWIP_DHCP_RESTORE_LAST_IP`               | n         | 配合 dhcp_state.c 的 NVS 存取                                                 |
| `LWIP_HOOK_TCP_ISN` choice                | DEFAULT   | RFC6528 ISN，见 port/hooks/tcp_isn_default.c                                  |
| `ESP_NETIF_USE_TCPIP_STACK_LIB`           | LWIP      | 这个 choice 本身就是"换栈"按钮（loopback 备选）                               |

菜单整体在 `Component config → LWIP` / `ESP NETIF Adapter`（后者管 lost-ip timer、bridge、L2 TAP、data-traffic 事件等）。数字都取自 `components/lwip/Kconfig`（1559 行）与 `components/esp_netif/Kconfig`。

### 3. Hook 注入点与特有组件

IDF 把上游十几个 hook 点接入 menuconfig（`LWIP_HOOK_IP6_ROUTE`、`LWIP_HOOK_ND6_GET_GW`、`LWIP_HOOK_DHCP_EXTRA_OPTION`、`LWIP_HOOK_NETCONN_EXTERNAL_RESOLVE`……凡是 lwIP 支持的扩展点，IDF 均有对应 choice），默认档提供保守弱实现。特有组件三条要记住：`esp_netif_stack_default`（各类型接口的 init_fn/input_fn 预设接线）、`lwip_fops` 式 VFS 集成（即 2.4 的 vfs_lwip.c）、TLS-based per-thread 资源（select 唤醒信号量与线程私有存储）。它们共同的哲学：**不改 lwIP 一个字，也能把它驯服成嵌入式 POSIX 服务**。

---

## 2.7 实验：架构探针 + 统计基线

目的：不连真实网口的前提下，①固定环境事实（lwIP 版本号、裁剪面数值），②体验标准启动序列的最小形态，③建立"LWIP_STATS 计数何时开始"的第一直觉。

工程位置 `practice/lwip-ch02-esp-idf-network-architecture/`（复制 hello_world 起步，删除其 main 改写为探针；`PRIV_REQUIRES esp_netif esp_event lwip`；`sdkconfig.defaults` 仅加一行 `CONFIG_LWIP_STATS=y`）。

构建与运行（完整命令）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch02-esp-idf-network-architecture
idf.py set-target esp32        # 仅首次
idf.py build
idf.py qemu monitor < /dev/null || true     # 生成 qemu_flash.bin / qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 25 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot > run.log 2>&1
# 退出码 124 = timeout 截停属预期（程序打印完毕后空转）
```

run.log 真实输出摘录（ESPIDF v6.0.2, lwIP 2.2.0-dev，未截略的逐字段落）：

```text
=== ch02: ESP-IDF network architecture probe ===
[1] LWIP_VERSION_STRING = 2.2.0d
[2] compile-time configuration:
  NO_SYS                           = 0
  LWIP_SOCKET                      = 1
  LWIP_NETCONN                     = 1
  LWIP_TCPIP_CORE_LOCKING          = 0
  TCPIP_MBOX_SIZE                  = 32
  LWIP_TCPIP_TASK_AFFINITY         = 2147483647
  FD_SETSIZE                       = 64
  CONFIG_LWIP_MAX_SOCKETS          = 10
  LWIP_SOCKET_OFFSET               = 54
  MEMP_NUM_TCP_PCB (MAX_ACTIVE_TCP) = 16
  TCP_SND_BUF                      = 5760
  TCP_WND                          = 5760
  MEM_LIBC_MALLOC                  = 1
  MEMP_MEM_MALLOC                  = 1
  LWIP_STATS                       = 1
[3] boot sequence: event loop -> esp_netif_init()
[4] protocol statistics baseline:
-- stats baseline (before any activity, no netif exists) --

LINK
	xmit: 0
	recv: 0
	...
	cachehit: 0

ETHARP
	xmit: 0
	recv: 0
	...
	cachehit: 0

IP
	xmit: 0
	recv: 0
	...(ICMP/UDP/TCP 六组结构相同, 全部计数器为 0)
-- after socket(): fd = 54 (expect >= LWIP_SOCKET_OFFSET)
-- after close(fd): VFS slot released back to the pool
=== done; no real interface created, application idles ===
```

结果解读：

1. **暗线 A 的第一块实证**：`LWIP_TCPIP_CORE_LOCKING = 0`——这台设备的 lwIP 不是"加锁访问的库"，而是"写信给管家（tcpip_thread）的服务"。`TCPIP_MBOX_SIZE = 32` 是管家的公文包容量。
2. **VFS 编号的数学**：`fd = 54` 一分不差落在 `LWIP_SOCKET_OFFSET = FD_SETSIZE − CONFIG_LWIP_MAX_SOCKETS = 64 − 10` 上——socket 占据 fd 空间的最上段，正如 2.2 图中的那条分界线；`close()` 归还槽位。`LWIP_SOCKET_OFFSET >= 6` 这条 static assert 保护的就是 stdio 前 6 个描述符。
3. **统计基线的"零"是精确答案而非没跑起来**：LWIP_STATS=y 已生效，但六组协议计数全 0——因为**没有创建任何 netif、没有任何一帧经过**。计数器的自增点都在真实数据通路上，例如 `ip4_input()` 入口 `IP_STATS_INC(ip.recv)`（src/core/ipv4/ip4.c）、ARP 报文到达才记 `ETHARP_STATS_INC(etharp.recv)`（src/core/ipv4/etharp.c）。第三章让 SLIRP 给我们发 DHCP 帧，这些 0 会立刻活过来——基线正是照变化量的尺子。
4. **计划外发现（价值最大的一条）**：即便打开 stats，`MEM_STATS_DISPLAY()/MEMP_STATS_DISPLAY()` 也什么都不打印——它们被预处理器整段掏空。原因写在同一份 lwipopts.h：IDF 设了 `MEM_LIBC_MALLOC = 1` 和 `MEMP_MEM_MALLOC = 1`，所有池分配退化到 libc 堆，lwIP 自带的 heap/memp 两套记账随之编译出局。含义有两层：性能调优（第六章）要看内存瓶颈得用 IDF 的 heap 工具而非 lwIP MEM 统计；这也是"IDF 裁剪面到底动了什么"最直观的例子。

> [!tip] 全 0 也值得一跑
> 这次实验真正固化的是坐标系：版本号 2.2.0d、affinity 位图值 `tskNO_AFFINITY`(2147483647)、TCP 缺省窗/发送缓冲 5760B、MAX_ACTIVE_TCP=16。后续每一章出现对照差异时都可以回这张小卡片核对"是不是我改了什么"。

---

## 2.8 小结

- 一个字节 RX 全程 8 个命名站点：MAC 驱动任务 → input path → `esp_netif_receive` → `ethernetif_input`（驱动 buffer 直接 pbuf 化，零拷贝）→ `tcpip_input` 邮箱 → tcpip_thread 协议处理 → netconn/socket 接收队列 → 应用任务。
- esp_netif 是**组合** lwIP netif 的容器（`esp_netif_obj.lwip_netif` + init/input/驱动三组函数指针），不是替代品。`netif_add(state=esp_netif)` 让 `netif->state` 天然成为背指针；启用 PPP/bridge 时切到 `netif_get_client_data` 通道。它是 IDF 层的四介质统一台面 + DHCP/事件号等栈外状态的持有人。
- 控制流翻译：驱动（如 glue 的 `post_attach`）只往 esp*netif 塞 transmit/free_rx/mac_filter 三个回调；生命周期的推进靠事件（ETH_EVENT → `esp_netif_action*\*`→ DHCP 起/停）；结果回流靠 lwIP 原生`netif_ext_callback`（`DHCP_CB_CHANGE`掩码捕获绑定）→`esp_event_post(IP_EVENT, ...)`。协议核零侵入。
- 所有 esp_netif 控制调用经由 `_RUN_IN_LWIP_TASK` 强制进入 tcpip_thread 执行；配合 `LWIP_TCPIP_CORE_LOCKING=n` 默认值，"单线程 core + 邮箱"不仅成立而且被贯彻到了管理层——暗线 A 的第一实证。
- port 层分工记忆法：`port/esp32xx` 管 socket↔VFS（`esp_vfs_register_fd_range(54..64)`、sys_init 时注册）、`port/freertos` 管 RTOS 原语 + VFS 注册入口、`port/hooks` 管 ISN/默认 hook、esp_netif/lwip 管 netif 模板（ethernetif/wlanif）与容器本体。
- Vanilla vs IDF：bring-up 从五个手工步骤塌缩成 `esp_netif_init/new/attach/start`；裁剪旋钮集中在 `LWIP_*` Kconfig（core-locking 关、stats 关、mbox 32、prio 18）；hook 点全部 menuconfig 化且有弱实现兜底。
- 实验：探针工程产出可信基线（2.2.0d / fd=54 / 六组协议统计全 0 / mem·memp 记账因 LIBC malloc 被裁掉），每一个数字都对上了源码推演。

下一章把这副全景图接上电：在 QEMU 里点亮 OpenCores open_eth 网卡，走完 `esp_eth → esp_netif → DHCP → 拿到 10.0.2.15` 的完整 bring-up，并用主机工具验证连通——第一个非零的协议统计将在那里诞生。见 [[ch3-qemu-network-lab|第三章]]。
