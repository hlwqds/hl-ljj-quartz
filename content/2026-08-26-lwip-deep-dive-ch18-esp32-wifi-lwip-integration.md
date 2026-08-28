---
title: "lwIP 深度解析（十八）：ESP32 WiFi 与 lwIP 的对接"
date: 2026-08-26
description: "esp_wifi 到 lwIP 的整条接缝走读：wifi_sta netif 的创建与默认事件 handler 链、wlanif.c 的零拷贝/拷贝双模态（CONFIG_LWIP_L2_TO_L3_COPY）、esp_pbuf PBUF_REF 自定义释放回收驱动 L2 缓冲、TX 侧 esp_wifi_internal_tx 的复制语义与 AMPDU 重传对 pbuf 生命周期的约束；任务并发全景表（wifi 任务经 os_adapter 由闭源库创建 vs tcpip 任务 prio18）；WiFi 特有调优点：modem sleep 档位对 RTT 的官方口径、AMPDU/AMSDU 吞吐账目；Vanilla 通用移植法对照与断线→重连 DHCP 恢复链。实验在本章受环境限制（QEMU 无 esp-wifi-mac）：用编译期 nm 符号验证证明走读路径与二进制一致，再用 openeth 以太网 + linkoutput 10% 随机丢帧包装器做「无线损耗在 lwIP 层的表现」的可复现替身实验——RTT 中位数几乎不动，p99 从 1.17ms 炸到 4.5s，吞吐崩掉约 97%。"
tags: [lwip, network, esp32, esp-idf, wifi, qemu]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 18. **第十八章：ESP32 WiFi 与 lwIP 的对接**（当前章）

# lwIP 深度解析（十八）：ESP32 WiFi 与 lwIP 的对接

这一章回答三个问题：**WiFi 帧和以太网帧差在哪，802.11 → 802.3 的转换到底谁做**（lwIP 只认以太网帧，但空中飞的是 802.11 帧头 + QoS/加密尾巴，这中间必须有人翻译）、**esp_wifi 的收发路径怎么把帧交给 lwIP**（哪个任务、零拷贝还是拷贝、pbuf 什么时候还回去）、**WiFi 天然的丢包/延迟在 lwIP 层是什么体验**（TCP 重传定时器怎么看这些"空气里消失的帧"）。读完它，前十七章拼出的协议栈全景就补上了最后一块大积木——无线的那个尖角。

源码参照：ESP-IDF v6.0.2。涉及文件：`components/esp_wifi/src/wifi_netif.c`、`components/esp_wifi/src/wifi_default.c`、`components/esp_netif/lwip/netif/wlanif.c`、`components/esp_netif/lwip/netif/esp_pbuf_ref.c`、`components/esp_netif/lwip/esp_netif_lwip_defaults.c` 等，全部实地读取核实；WiFi MAC 层本体 `libnet80211.a` 是闭源预编译库，相关推断会明确标注为黑盒口径。

> [!warning] 本章实验形态特殊：源码级走读 + 编译期验证 + 以太网对照
> 本机 QEMU（esp_develop_9.2.2_20250817）**没有 esp-wifi-mac 包**，WiFi 无法仿真运行（这是 Espressif QEMU fork 的现状：官方功能表里 Wi-Fi 就是 ❌）。本章是全系列唯一一章实验受环境限制的：我们把能做的做满——① 开着完整 WiFi 配置编译固件，用 `xtensa-esp32-elf-nm` 从 elf 里 dump 出接缝符号表，证明走读的每一条代码路径都真实链接进了二进制；② 用 openeth 以太网跑同一套 echo 应用，在 `linkoutput` 上包一层「10% 随机丢帧」来模拟无线损耗在 lwIP 层的表现，A/B 对比 RTT 分布与吞吐。真机专属结论一律如实标注「需真机」，不编造任何 WiFi 运行输出。

---

## 18.1 核心问题三连：先给答案再展开

**一问：802.11 → 802.3 谁转换？** 答案：在 ESP32 上是闭源的 WiFi 库自己在 RX 路径上转好了。证据链有三条：① lwIP 这侧的 netif 实现叫 `wlanif.c`，开头注释就是 _"Ethernet Interface Skeleton used for WiFi"_——它完全按以太网 netif 工作（`low_level_init()` 里 `netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_ETHERNET`，MTU 1500），没有任何 LLC/SNAP 解析代码；② 注册给驱动的回调类型 `wifi_rxcb_t` 的签名是 `(void *buffer, uint16_t len, void *eb)`——驱动递上来的 buffer 直接被当作以太网帧塞给 `netif->input()`，中间没有 802.11 头剥离步骤；③ lwIP 内核根本不认识 802.11。所以转换发生在 `libnet80211` 黑盒内部（含从 A-MSDU/A-MPDU 子帧还原、WPA 解密后重组出以太网帧），本章把这层标为黑盒边界：我们能看到边界的形状（回调签名、缓冲数量配置），看不到里面的实现。

**二问：交接点在哪个函数、哪个任务？** 答案：交接点是 `wlanif_input()`，运行在 WiFi 驱动任务上下文里——它做的第一件事就是把 pbuf 投进 tcpip 线程邮箱（`netif->input(p, netif)` 即 `tcpip_input`，见 [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|第十三章]]）。TX 反向对称：应用通过 socket 写 → tcpip 线程内 TCP 发包 → `netif->linkoutput` = wlanif 的 `low_level_output` → `esp_netif_transmit_wrap()` → `wifi_transmit()` → `esp_wifi_internal_tx()` 把帧递进驱动。整条数据通路跨任务边界只有邮箱这一次投递——这正是系列暗线 A 的落点：单线程协议栈与异步驱动世界的唯一官方通道。

**三问：丢包/高延迟在 lwIP 眼里什么样？** 答案：什么都看不见，只是"慢"。WiFi 的碰撞退避、速率适配掉速、调制失败、省电模式错峰——最终到达 lwIP 时只剩两种症状：帧晚到（RTT 尾部拉长）或帧没到（对端沉默，等 RTO）。驱动不会告诉 lwIP「这一帧丢了」：`linkoutput` 返回 ERR_OK 只代表帧交给了介质，之后的事全是链路层的责任。这个特性就是 18.6 对照实验的方法学基础——我们在 `linkoutput` 里静默吞掉 10% 的帧并返回 ERR_OK，lwIP/TCP 的反应方式与真实无线损耗同构。

三问一表速览（各节给出完整证据）：

| 问题           | 一句话答案                                                                        | 证据所在节                           |
| -------------- | --------------------------------------------------------------------------------- | ------------------------------------ |
| 帧格式转换谁做 | 闭源 libnet80211 内部完成，lwIP 只见以太网帧                                      | 18.1（签名证据）/ 18.2.5（黑盒标注） |
| 收发怎么交接   | RX：驱动任务 → wlanif_input → tcpip 邮箱；TX：linkoutput → internal_tx 拷贝后即回 | 18.2.2 / 18.3                        |
| 丢包长什么样   | 中位数免疫、尾部爆炸、吞吐塌方，全靠 RTO 背锅                                     | 18.6.2 实测                          |

---

## 18.2 esp_wifi → lwIP 数据通路：逐行走读

### 18.2.1 wifi_sta netif 是怎么造出来的

用户视角一行代码：`esp_netif_create_default_wifi_sta()`（声明在 `components/esp_wifi/include/esp_wifi_default.h`）。它展开只做三件事：

```c
esp_netif_t* esp_netif_create_default_wifi_sta(void)   /* wifi_default.c */
{
    esp_netif_config_t cfg = ESP_NETIF_DEFAULT_WIFI_STA();
    esp_netif_t *netif = esp_netif_new(&cfg);              /* 1. 建 esp_netif 对象 */
    ESP_ERROR_CHECK(esp_netif_attach_wifi_station(netif)); /* 2. 绑 WiFi 驱动接口 */
    ESP_ERROR_CHECK(esp_wifi_set_default_wifi_sta_handlers()); /* 3. 挂默认事件 handler */
    return netif;
}
```

三步各有一层证据值得拆开：

第 1 步的配置宏 `ESP_NETIF_INHERENT_DEFAULT_WIFI_STA()` 在 `components/esp_netif/include/esp_netif_defaults.h`：flags 带 `ESP_NETIF_DHCP_CLIENT`、事件挂 `get_ip_event = IP_EVENT_STA_GOT_IP` / `lost_ip_event = IP_EVENT_STA_LOST_IP`、`if_key = "WIFI_STA_DEF"`、**`route_prio = 100`**（对比以太网的 50、SoftAP 的 10）——多接口共存时lwIP 默认路由归谁，就是这个优先级说话。

第 2 步 attach 进来的是 `components/esp_wifi/src/wifi_netif.c` 构造的对象：一个小结构体 `{ base; wifi_if; }`，`base.post_attach = wifi_driver_start`。后者在 netif 侧注册驱动 IO 函数表——这就是**双方向的物理接缝**：

```c
static esp_err_t wifi_driver_start(esp_netif_t *esp_netif, void *args)
{
    ...
    esp_netif_driver_ifconfig_t driver_ifconfig = {
        .handle                = driver,
        .transmit              = wifi_transmit,        /* TX: -> esp_wifi_internal_tx() */
        .transmit_wrap         = wifi_transmit_wrap,   /* TX 带 netstack_buf 引用 */
        .driver_free_rx_buffer = wifi_free             /* RX: -> esp_wifi_internal_free_rx_buffer() */
    };
    return esp_netif_set_driver_config(esp_netif, &driver_ifconfig);
}
```

一个时序细节值得单独拆出来：attach 这一刻 **`wlanif_init_sta()` 还没跑，lwIP 的 netif 也还不存在**。`esp_netif_create_default_wifi_sta()` 只完成了"对象配对"；真正的 lwIP netif 要等接口 start 时由 `esp_netif_up()` 经 `_RUN_IN_LWIP_TASK` 投进 tcpip 线程，在内核里执行 `netif_add(esp_netif->lwip_netif, ..., esp_netif, esp_netif->lwip_init_fn, tcpip_input)` 才诞生（`esp_netif_lwip.c` 中核实）。这个调用一石三鸟：`lwip_init_fn` 就是 `wlanif_init_sta`（起名 'st'、装 output/linkoutput），第三个参数把 `tcpip_input` 钉死为收包入口——RX 过邮箱的宿命在 netif 出生那一刻就定了。对实验设计的含义见 18.6.1：「对象级创建」之所以安全，正是因为它绕过了 start/up 这条会触碰闭源库运行态的路径。

`wifi_transmit_wrap()` 是第一个分流器：只有开了 `CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y`（PSRAM 平台拿外部 RAM 给 WiFi/lwIP 缓冲兜底）且 PSRAM 就绪时才走 `esp_wifi_internal_tx_by_ref()`（对 pbuf 增引用计数后直接递指针）；否则与普通 `wifi_transmit()` 相同，调用 `esp_wifi_internal_tx()`。

第 3 步挂的默认 handler 是**控制平面的状态机翻译器**，住在 `wifi_default.c`：`WIFI_EVENT_STA_START` → `wifi_default_action_sta_start`（读 MAC、设进 esp_netif、转发给 `esp_netif_action_start`）；`WIFI_EVENT_STA_CONNECTED` → `wifi_default_action_sta_connected`（**在这里注册 RX 回调**，见下）；`WIFI_EVENT_STA_DISCONNECTED` → `wifi_default_action_sta_disconnected` → `esp_netif_action_disconnected`（18.5 节恢复链的主角）。

### 18.2.2 数据平面接缝的三层名字

RX 方向的数据通路要经过三个同名感很强的文件，先用一张表钉死各自角色，后面引用不再迷路：

| 文件                               | 角色                                                  | 关键符号                                                        |
| ---------------------------------- | ----------------------------------------------------- | --------------------------------------------------------------- |
| `esp_wifi/src/wifi_netif.c`        | 驱动侧适配对象：把驱动回调封装成 esp_netif 认识的形式 | `wifi_sta_receive()`、`esp_wifi_register_if_rxcb()`             |
| `esp_netif/lwip/esp_netif_lwip*.c` | 协议栈绑定：netstack 配置表 + 收发 wrap               | `_g_esp_netif_netstack_default_wifi_sta`、`esp_netif_receive()` |
| `esp_netif/lwip/netif/wlanif.c`    | lwIP 侧 netif 实现（以太网骨架套皮）                  | `wlanif_init_sta()`、`wlanif_input()`、`low_level_output()`     |

netstack 配置表在 `esp_netif_lwip_defaults.c`——每个接口类型的 init/input 函数在这里装配成全局常量：

```c
static const struct esp_netif_netstack_config s_wifi_netif_config_sta = {
        .lwip = {
                .init_fn  = wlanif_init_sta,   /* netif_add 回调：起名 st、装 output/linkoutput */
                .input_fn = wlanif_input       /* 驱动递帧入口 */
        }
};
const esp_netif_netstack_config_t *_g_esp_netif_netstack_default_wifi_sta = &s_wifi_netif_config_sta;
```

### 18.2.3 RX 回调的注册时机：STA 与 AP 不对称

一个精巧且实用的细节：AP 接口的 rxcb 在启动时就注册，STA 的却要等到连接成功。`wifi_netif.c` 注释原文说得直白：

```c
bool esp_wifi_is_if_ready_when_started(wifi_netif_driver_t ifx)
{
#ifdef CONFIG_ESP_WIFI_SOFTAP_SUPPORT
    // WiFi rxcb to be register wifi rxcb on start for AP only,
    // station gets it registered on connect event
    return (ifx && ifx->wifi_if == WIFI_IF_AP);
#else
    return false;
#endif
}
```

STA 的注册动作发生在 `wifi_default_action_sta_connected()` 里（未注册时补调 `esp_wifi_register_if_rxcb(driver, esp_netif_receive, esp_netif)`）。注册函数内部把两层指针对好：上层 `s_wifi_rxcbs[WIFI_IF_STA] = fn`（esp_netif_receive），下层 `esp_wifi_internal_reg_rxcb(WIFI_IF_STA, wifi_sta_receive)`——后者才是闭源库认的那个函数指针。这个不对称的设计动机：关联回调（驱动收到 CONNECTED 事件、rt 完成认证协商）之前 STA 根本没有合法的对端 MAC 可过滤，提前挂上也收不到东西；而 AP 上电即可收关联请求。对调试者的含义很直接：**没拿到 CONNECTED 之前 STA 方向的一切静默是预期的**，别去抓「为什么收不到数据帧」的包。

### 18.2.4 wlanif_input：零拷贝/拷贝双模态

[[2026-08-26-lwip-deep-dive-ch4-pbuf-anatomy|第四章]] 提过 wlanif 有两个模态，本章落地全文。`wlanif_input()` 收到驱动递来的 `(buffer, len, l2_buff)` 后分叉：

```c
#ifdef CONFIG_LWIP_L2_TO_L3_COPY
    p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);       /* 拷贝模态 */
    memcpy(p->payload, buffer, len);
    esp_netif_free_rx_buffer(esp_netif, l2_buff);  /* 立刻还驱动缓冲 */
#else
    p = esp_pbuf_allocate(esp_netif, buffer, len, l2_buff);  /* 零拷贝模态 */
#endif
    ... netif->input(p, netif);   /* 投递 tcpip_thread 邮箱 */
```

`CONFIG_LWIP_L2_TO_L3_COPY` 默认 **n**（`components/lwip/Kconfig`），即默认零拷贝。零拷贝模态的真身是 `esp_pbuf_ref.c` 的自定义 pbuf：

```c
typedef struct esp_custom_pbuf {
    struct pbuf_custom p;      /* lwIP 官方扩展：带 custom_free_function */
    esp_netif_t *esp_netif;
    void* l2_buf;              /* 驱动的 L2 缓冲指针藏在 pbuf 里 */
} esp_custom_pbuf_t;

struct pbuf* esp_pbuf_allocate(esp_netif_t *esp_netif, void *buffer,
                               size_t len, void *l2_buff)
{
    esp_custom_pbuf_t* esp_pbuf = mem_malloc(sizeof(esp_custom_pbuf_t));
    esp_pbuf->p.custom_free_function = esp_pbuf_free;
    esp_pbuf->l2_buf = l2_buff;
    p = pbuf_alloced_custom(PBUF_RAW, len, PBUF_REF,
                            &esp_pbuf->p, buffer, len);   /* payload 就是驱动缓冲本身 */
    return p;
}
```

三个要点：① 类型是 **PBUF_REF**——pbuf 结构体外只有一个 header 小壳，payload 直指驱动 DMA 类缓冲，全程零字节拷贝；② 还缓冲的时机由 `custom_free_function` 钩住：**任何一处 `pbuf_free(p)` 都可能触发 `esp_pbuf_free()` → `esp_netif_free_rx_buffer()` → 驱动注册的 `esp_wifi_internal_free_rx_buffer()`**，把 `l2_buf` 还给驱动池；③ 壳自身从堆里 `mem_malloc`（IDF 全堆化，呼应第五章）。

零拷贝的直接代价是**所有权复杂化**：这颗 pbuf 从创建那一刻就被内核持有可能穿过整个协议栈（tcpip 线程处理、socket 接收队列、甚至被应用 `recvmsg` 分支续命），期间驱动缓冲不能复用。所以 WiFi 的动态 RX 缓冲上限和 lwIP 的消费速度必须匹配——官方文档调优节原话：_"This parameter needs to match the RX buffer size of the LwIP layer"_。应用拿着 recv 缓冲不放、socket 队列积压、tcpip 邮箱堵——每一环都会向上游传导成驱动缓冲耗尽 → 新帧到硬件无处落地 → 丢帧。

### 18.2.5 TX 方向与 AMPDU/重传对 pbuf 生命的约束

TX 侧回看 `low_level_output()`：单个 pbuf 时直接把 `q->payload/q->len` 交给 `esp_netif_transmit_wrap()`；**pbuf 链则先 `pbuf_alloc(PBUF_RAW_TX, tot_len, PBUF_RAM)` + `pbuf_copy()` 合并再发**——因为驱动 API 吃连续缓冲。注释还留了句诊断提示："application may has bug"（正常 TCP 出口不该出现链）。为什么不该出现？[[2026-08-26-lwip-deep-dive-ch6-zero-copy-tcp-write|第六章]] 已查明：IDF 把 `LWIP_NETIF_TX_SINGLE_PBUF` 硬编码为 1，`tcp_write()` 强制带 copy 标志，走到 netif 的必然是单段 pbuf。UDP 场景应用自己拼 pbuf 链仍可能踩到这里——多付一次全量 memcpy。

接着往下是本次走读的最后一个接缝 `esp_wifi_internal_tx()`，它在 `esp_wifi/include/esp_private/wifi.h` 里的文档注释写明语义：_"This API makes a copy of the input buffer and then forwards the buffer copy to WiFi driver."_（by*ref 变体则是增引用计数后直接递 pbuf。）**为什么要拷贝？** 因为驱动还要对这帧负责很久：加密（WPA 再算 MIC/加密尾巴）、按对端速率排队、可能进 A-MPDU 聚合等待、发生 CRC 冲突就要重传、最多重试到计数耗尽——期间 lwIP 侧的 pbuf 早被 free 了，驱动手里必须有自己的副本。反过来\_RX*方向同样存在"远程生命周期"：接收端开着 Block Ack 窗口时要缓存失序子帧等序号凑齐才能交给上层（也影响 lwIP 能多快看到完整帧），窗口配置 `CONFIG_ESP_WIFI_RX_BA_WIN` 默认 6（开 SPIRAM 时 16），Kconfig help 给的经验公式是「不超过静态 RX 缓冲数 × 2 且 ≤ 动态 RX 缓冲数」。

给一张 TX 全链条时序图收束本节：

```text
应用 send()/write()
   │ socket 层拷贝
tcpip 线程: TCP 组包 → pbuf(RAM, 单段) ── lwIP 内部一切照旧
   │ netif->linkoutput = low_level_output()          [wlanif.c]
   │ q->next==NULL ? 直通 : 先合并拷贝                  （IDF 下 TCP 出口恒为前者）
   │ esp_netif_transmit_wrap()                        [esp_netif_lwip.c]
   │ driver_transmit_wrap = wifi_transmit(_wrap)      [wifi_netif.c]
   ▼ esp_wifi_internal_tx() ——此处变黑盒：拷贝进驱动 TX 缓冲
{ 加密 → 排队 → (可选)AMPDU 聚合 → 空中发射 → 无 ACK 则重传 … }
   ▲ 成功/失败经驱动事件异步回来，lwIP 此前早已继续干活
```

> [!note] 黑盒标注
> 以上花括号内环节发生在 `components/esp_wifi/lib/esp32/libnet80211.a` 等预编译库中，18.6 节实验 A 会用 `nm` 证明这些库真实存在并参与链接；库内的任务名、聚合策略、重传次数曲线属于实现细节，本文不做虚构性描述。可核对的外部事实仅两类：开放侧 adapter 注册了哪些函数（如 `components/esp_wifi/esp32/esp_adapter.c` 的 `task_create_pinned_to_core_wrapper`），以及闭源库导出了哪些符号。

---

## 18.3 任务并发全景：四个任务看一眼谁压着谁

| 任务                      | 创建者                               | 职责                                                          | 优先级                           | 栈                                                          | 核亲和                                                                                     |
| ------------------------- | ------------------------------------ | ------------------------------------------------------------- | -------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| tcpip ("tiT")             | `esp_netif_init()`                   | lwIP 单线程心脏                                               | 18（实测，ch14）                 | Kconfig 默认 3072，实际分配 3584B（ch14 实测高水位 ~2300B） | `LWIP_TCPIP_TASK_AFFINITY` 默认 NO_AFFINITY                                                |
| wifi 任务                 | **闭源库**经 os_adapter 创建（见下） | 收发调度、聚合、扫描/关联状态机，执行 `wifi_sta_receive` 回调 | 库内常量，开放源码不可见（黑盒） | 同左                                                        | Kconfig `ESP_WIFI_TASK_CORE_ID` 默认 Core0，经 `wifi_init_config_t.wifi_task_core_id` 传入 |
| eth RX（openeth，对照系） | `ETH_MAC_DEFAULT_CONFIG()`           | 以太网驱动收帧                                                | 15（ch3 工程注释口径）           | 4096B                                                       | 默认不绑核                                                                                 |
| 应用任务（echo_srv 等）   | 用户 `xTaskCreate`                   | 业务                                                          | 自定（示例常用 5）               | 自定                                                        | 默认 NO_AFFINITY                                                                           |

两个走读细节让这张表站得住：

**wifi 任务为什么核亲和来自 Kconfig 却不见创建代码？** 全链路是这样的：Kconfig choice `ESP_WIFI_TASK_CORE_ID`（默认 `ESP_WIFI_TASK_PINNED_TO_CORE_0`）→ `WIFI_INIT_CONFIG_DEFAULT()` 宏把值填进 `wifi_init_config_t.wifi_task_core_id` 字段（字段列表已在 18.1 前的 `esp_wifi.h` 结构体定义中核实，紧挨 `rx_ba_win`、`ampdu_*` 一族）→ `esp_wifi_init()` 连同整个 config 一起交给闭源库 → 库通过 `g_wifi_osi_funcs` 函数表里的 `_task_create_pinned_to_core` 创建任务——开放侧的实现是 `components/esp_wifi/esp32/esp_adapter.c` 里的 `task_create_pinned_to_core_wrapper()`，它只是转手调 FreeRTOS；**真正的任务名、优先级数值、栈大小都是库内常量**（真机上可用 task list 观测到的常见口径是优先级高于 tcpip 的 18，具体数字以你手上设备的任务清单为准，本文不代填）。

**所谓「WiFi RX 线程化」在 IDF v6 里是什么？** 按 Kconfig 逐项 grep 核对的结论：ESP32 目标上**不存在独立的「WiFi RX 任务」开关**。R0X 名称里最接近的是 `CONFIG_ESP_WIFI_RX_BA_WIN`——注意那是 Block Ack 重排窗口参数，不是线程参数。RX 分派的并发模型就是：中断底半部入队 → wifi 任务统一执行 `wifi_sta_receive()` → 同步走到 `tcpip_input()` 投邮箱。换句话说，**从空气到 lwIP 邮箱的所有预处理都串行地压在一个 wifi 任务里**——这与上一章 ethernetif「驱动 RX 任务 → 邮箱」的结构同构，只是工作任务从两个变成了一个，也是第二章架构图里「WiFi 是把 MAC+PHY+调度全部打包的胖驱动」这句话的任务模型注脚。

并发正确性的保证依旧遵守 [[2026-08-26-lwip-deep-dive-ch14-sys-arch-freertos-adapter|第十四章]] 总结的单写者纪律：除了投邮箱这一次跨界，谁都不许直接摸 lwIP 数据结构；控制面（如改 IP、开关 DHCP）必须用 `esp_netif_*` API，它们经 `_RUN_IN_LWIP_TASK` 宏强制序列化进 tcpip 线程。

把一次最小回显事务在四个任务间的接力画全（读法：每行是一个时间片，箭头处是任务切换点）：

```text
WiFi 场景（对照 18.6.2 的 openeth 场景：仅把「wifi 任务」换成「eth RX 任务 prio15」）
────────────────────────────────────────────────────────────────
wifi 任务      : 底半部收帧 → 组装/解密/重排 → wifi_sta_receive()
                  └→ esp_netif_receive() → wlanif_input() → esp_pbuf_allocate()
                     → tcpip_input() 投 mbox ──┐ (零拷贝：pbuf 指着驱动缓冲)
                                            ▼
tcpip 任务     : sys_mbox_fetch() 唤醒 → ip4_input → udp_input/tcp_input
                  │ → netconn trypost 到 socket 接收邮箱      ──┐
                                                            ▼
应用任务       : recv() 从邮箱取走数据……处理完 echo 回包
                  └→ send() → 落回 tcpip 任务(系统路径 ~37µs/api, ch14)
tcpip 任务     : TCP 出口组包 → linkoutput → esp_wifi_internal_tx()（拷贝后立即返回）
wifi 任务      : 排队聚合发射、等 ACK、必要时重传——lwIP 对此全程无感
────────────────────────────────────────────────────────────────
```

三个观察：① 一帧 RX 至少穿越 wifi→tcpip→应用三任务两次队列，所以「哪个环节最慢」永远先看邮箱水位而不是 CPU 占用；② TX 方向恰恰相反地轻快——`esp_wifi_internal_tx` 的 copy 语义让 tcpip 线程**同步返回**，发射与重传的所有等待都在驱动内部消化，这正是为什么 TCP 发送吞吐对驱动缓冲数量敏感（18.4.3 的配对公式）；③ 数据面四个任务里只有 tcpip 是 lwIP 的自己人，其余都是"带着邮箱门票的外人"。

---

## 18.4 WiFi 特有的 lwIP 调优点

### 18.4.1 ps 省！但 RTT 会替你记账

`esp_wifi_set_ps()` 三档的机制描述（DTIM/listen interval 语义）在 FreeRTOS 姊妹篇 [[2026-08-26-esp32-s3-box-3-ch16-wifi-events|《ESP32-S3-BOX-3 实战（十六）》]] 已经讲过档位本身，这里换 lwIP 视角算账。官方性能文档（`docs/en/api-guides/wifi-driver/wifi-performance-and-power-save.rst`）的原话口径：

> When Modem-sleep mode is enabled, the delay in receiving Wi-Fi data may be the same as the DTIM cycle (minimum power-saving mode) or the listening interval (maximum power-saving mode).

翻译成 ping 口径：MIN_MODEM 下每次醒来间隔 ≈ AP 的 DTIM × beacon 间隔。常见 AP beacon 102.4ms、DTIM=1~3，那么睡眠档下的下行首包延迟就有 100~300ms 量级的抖动来源——请求恰好在睡眠期到达 AP，要压到下一个 DTIM 才放行。MAX_MODEM 更狠：listen interval 可以自己配成多个 DTIM（`wifi_config_t.sta.listen_interval`），广播/组播在睡眠期直接丢失（文档明言），mDNS、保活组播之类全遭殃。**lwIP 层的可操作建议**：

| 需求                             | 选择                                   | lwIP/协议侧联动                                                    |
| -------------------------------- | -------------------------------------- | ------------------------------------------------------------------ |
| 低延迟交互（SSH/MQTT 心跳/配网） | `WIFI_PS_NONE`                         | RTT 分布收紧，代价 mA                                              |
| 常规 IoT 上报                    | `WIFI_PS_MIN_MODEM`（默认）            | 应用超时预算留 ≥ 300ms 余量；`CONFIG_LWIP_TCP_TMR_INTERVAL` 别乱动 |
| 电池极限                         | `WIFI_PS_MAX_MODEM` + listen_interval↑ | 放弃实时性预期；keepalive 周期 > listen interval 否则假死          |

另外一档容易被忽略：`CONFIG_ESP_WIFI_STA_DISCONNECTED_PM_ENABLE`（默认 y）允许**未连接时**关闭 RF——对「扫一下要不要联网」类产品是免费功耗收益，不影响已连接场景。

### 18.4.2 sniffer/NAN 与 netif 的旁路关系

netif 不是 WiFi 流量的唯一出口。两条旁路要心里有数：**① Promiscuous/sniffer**：`esp_wifi_set_promiscuous(true)` + 设置 sniffer 回调后，驱动把收到的原始 802.11 帧（含坏 FCS 可选）直接递给回调，不产生 pbuf、不进 netif、不占 lwIP 内存——这条路径上 802.11 → 以太网的转换也不发生，拿到的是裸帧。做无线分析工具用它，但如果同时开着 STA，要注意吞吐会抢 wifi 任务的时间片。**② NAN/Wi-Fi Aware**：`esp_netif` 有专门的 NAN 配置宏（`ESP_NETIF_INHERENT_DEFAULT_WIFI_NAN`，route*prio 10、无 DHCP flag），`wlanif_init_nan()` 与 sta/ap 仅名字不同（'n','a'）；但 NAN 的同步/发现信令大部分走自己的 app 层（`esp_nan.h`），真正需要 IP 的场景才有 netif 参与。两者共同的教学价值：**netif 是「IP 数据面」的组织单位，不是「射频事件」的**——事件面归 esp_event（WIFI_EVENT*\*），裸流面归 promiscuous 回调。

### 18.4.3 AMPDU/AMSDU 吞吐账目

调吞吐前先看清天花板在哪。Espressif 实验室官方数据（同文档，esp32 表，iperf 例程口径）：

| 方向             | Air in Lab | Shield-box（屏蔽箱） |
| ---------------- | ---------- | -------------------- |
| Raw 802.11 RX/TX | N/A        | 130 Mbit/s           |
| UDP RX / TX      | 30 / 30    | 85 / 75              |
| TCP RX / TX      | 20 / 20    | 65 / 75              |

Read 的顺序很有信息量：raw 130 说明 RF 能扛；UDP 掉到 85 说的是驱动+内存拷贝开始成为瓶颈；TCP 再掉到 65~75 是 lwIP CPU 时间在分账。所以「加吞吐」的操作序列应该是自下而上对齐各层缓冲（否则白调）：文档给的配对公式——`CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM` ↔ `CONFIG_LWIP_TCP_WND_DEFAULT`，`CONFIG_ESP_WIFI_DYNAMIC_TX_BUFFER_NUM` ↔ `CONFIG_LWIP_TCP_SND_BUF_DEFAULT`（原文："Its value should be configured to the value of WIFI_DYNAMIC_RX_BUFFER_NUM (KB)"），BA 窗口夹在其中（默认 6 / SPIRAM 16）。聚合开关是杠杆也是账目项：`ESP_WIFI_AMPDU_TX/RX_ENABLED` 默认 y（TX BA win 6）；`ESP_WIFI_AMSDU_TX_ENABLED` 默认 n——AMSDU 单帧可塞多个 MSDU 减少物理帧开销，但它放大了单个丢包的破坏半径（一发全损），弱信号环境打开反而翻车，这正是它不开的原因之一。IRAM 相关的 `ESP_WIFI_IRAM_OPT`（+15KB IRAM 换吞吐）属第三章「链接器 GC 让 size 失真」的同族话题，衡量时记得用真实流量而不是 .text 大小。

---

## 18.5 Vanilla lwIP 对照：通用移植姿势 vs IDF 做法，以及错误恢复链

**通用姿势**（upstream/contrib 世界移植无线网卡的常规做法）：驱动收到无线帧 → 移植层自建 `ethernetif.c` 骨架，input 路径把驱动缓冲**拷**进 `pbuf_alloc(PBUF_RAW,...)` 再 `netif->input()`，output 路径 `low_level_output` 把 pbuf 内容拷给驱动发送缓冲；802.11↔802.3 转换要么芯片/固件做（多数 SDIO/USB 无线模组的做法），要么移植层自己写 LLC/SNAP 摆渡。要点是万变不离 netif 抽象：lwIP 永远以为自己在跟一块以太网网卡说话。IDF 的 WiFi 接入与骨架同构，逐维对比如下：

| 维度           | Vanilla 通用移植                  | ESP-IDF v6 做法                                                                               |
| -------------- | --------------------------------- | --------------------------------------------------------------------------------------------- |
| RX 缓冲交接    | 拷进新建 pbuf（复制一次）         | 默认零拷贝 PBUF_REF 自定义 pbuf + custom_free 归还；`LWIP_L2_TO_L3_COPY` 可切回拷贝（18.2.4） |
| TX 生命周期    | 拷走即返回，驱动持副本            | 同为 copy 语义，但开 PSRAM 时有 by_ref 引用计数变体（18.2.1）；链式 pbuf 需合并拷贝           |
| 802.11→802.3   | 移植层或模组固件做                | 闭源库内部做，边界只递成品以太网帧                                                            |
| 状态机接线     | 驱动回调直呼 netif 函数，竞态自理 | WIFI/IP 事件循环翻译成 action handler，DHCP 启动点藏在 CONNECTED 分支里                       |
| 控制面线程安全 | 各写各的锁                        | `_RUN_IN_LWIP_TASK` 强制全部序列化进 tcpip 线程                                               |
| 多接口身份     | 一个 netif 一个移植实例           | sta/ap/nan 共用 wlanif.c，仅 name 两字符之差 + if_key/route_prio 区分                         |

**错误恢复链**（接 Batch 1 事件链事实 + ch16 边界认知）：Station 掉线后发生了什么？`WIFI_EVENT_STA_DISCONNECTED` → 默认 handler `wifi_default_action_sta_disconnected()` → `esp_netif_action_disconnected()`（`esp_netif_handlers.c`）只有一行正文 `esp_netif_down(esp_netif)`——netif 撤地址、DHCP 客户端停摆、路由撤除，lwIP 侧所有基于该接口的 PCB 进入不可用态（socket 表现为读写报错，应用该重建的要重建，见 ch16 的断线清场描述）。随后应用的经典恢复循环 `esp_wifi_connect()` → `CONNECTED` → `wifi_default_action_sta_connected` 补注册 rxcb → `esp_netif_action_connected()`：这里藏着 DHCP 的分支逻辑（读源码可见三层：`DHCP_INIT` 态直接 start；`DHCP_STOPPED` 态若配了合法静态 IP 则直接 post GOT_IP 事件并比对 old_ip 置 `ip_changed`；其余不动）。最后 DHCP 成功 → `IP_EVENT_STA_GOT_IP`（宏字段 `get_ip_event`）→ 应用才有资格建 socket。**「DISCONNECTED→GOT_IP 全程重走」是设计使然而非事故**：IP 本来就可能变，静态 IP 用户也要重新走一遍确认流程。

> [!tip] 为什么你的 MQTT 断线检测比 WiFi 断线慢半拍
> lwIP 的 TCP keepalive / 应用层心跳跑在 IP 地址还在、但对端已死的连接上；而 WiFi 断线事件的传播终点是 esp_event。若你的业务只盯 socket 错误而不订阅 WIFI_EVENT/IP_EVENT，感知延迟就等于保活周期差。正确姿势是双层：事件层快路径触发立刻重建，心跳层兜底覆盖 WiFi 未报断线的场景（如 AP 假活）。

---

## 18.6 实验：nm 符号验证 + 以太网对照丢包 A/B

实验工程：`practice/lwip-ch18-esp32-wifi-lwip-integration/`。宿主机端口沿用约定选号 **8050**（8003/8005/8006/8009/8010~8012/8014~8019/8027/8517/9014 已被其他章占用）。

### 18.6.1 实验 A：编译期验证——走读路径与二进制一致

目的：QEMU 跑不了 WiFi，但**编译器可以替我们回答「这些接缝函数真的都在吗」**。做法：工程 main 里做一次「对象级创建」——只调 `esp_netif_create_default_wifi_sta()` 建 netif 对象并挂默认 handler，**不调 `esp_wifi_init/start`**（没有射频，触碰不了闭源库运行路径），然后 openeth 正常 bring-up。sdkconfig 保持目标默认（`CONFIG_ESP_WIFI_ENABLED=y` 在 SOC 支持 WiFi 时默认开，grep sdkconfig 确认）。

命令（CONVENTIONS §3 标准流程）：

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch18-esp32-wifi-lwip-integration
idf.py set-target esp32 && idf.py build
# 生成 QEMU 镜像（monitor 因无 TTY 失败可忽略）
idf.py qemu monitor < /dev/null || true
NM=~/.espressif/tools/xtensa-esp-elf/esp-15.2.0_20251204/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
$NM build/lwip_ch18_esp32_wifi_lwip_integration.elf \
  | grep -E "wlanif|esp_pbuf_allocate|esp_pbuf_free|esp_netif_receive$|\
wifi_sta_receive|wifi_ap_receive|esp_wifi_internal_tx|esp_wifi_internal_reg_rxcb|\
esp_netif_transmit_wrap|lossy_linkoutput|low_level_output$|esp_wifi_create_if_driver" | sort
```

main 里对象级创建的代码只有一行（完整的注释版在工程 `main/lab_main.c`）：

```c
/* 不调 esp_wifi_init/start：QEMU 无射频，只造对象、挂事件 handler，
 * 让整条接缝代码被链接器真实拉进固件 */
esp_netif_t *sta_netif = esp_netif_create_default_wifi_sta();
```

guest 上电后（18.6.2 的 run.log 同时也是本实验的运行证据）能看到它安静地共存：

```text
I (1581) ch18lab: == ch18 lab: wifi seam symbols in elf + openeth lossy-linkoutput A/B ==
I (1581) ch18lab: wifi sta netif object created @0x3ffc003c (object-level only, no RF)
I (1611) esp_eth.netif.netif_glue: ethernet attached to netif
I (2711) ch18lab: GOT_IP: 10.0.2.15/255.255.255.0 gw 10.0.2.2
I (2711) ch18lab: ETH netif impl @0x3ffc2618 name=en1
```

sta 对象既没起射频也没生成 lwIP netif（18.2.1 的时序细节），以太网侧 DHCP 照常拿 `10.0.2.15`——「WiFi 没跑」并不妨碍它的代码符号全部上桌。

真实输出（本机构建实测摘录，地址随构建漂移属正常）：

```text
40088c00 t wifi_sta_receive
400d7a6c t lossy_linkoutput
400f1b94 T esp_netif_transmit_wrap
400f1bc8 T esp_netif_receive
400f1f44 t low_level_output
400f1fe0 T wlanif_input
400f203c T wlanif_init
400f2080 T wlanif_init_sta
400f2098 t ethernet_low_level_output
400f21b8 t esp_pbuf_free
400f21cc T esp_pbuf_allocate
400f82c8 T esp_wifi_internal_reg_rxcb
40104a40 T esp_wifi_internal_tx
40106dbc t wifi_ap_receive
40106e28 T esp_wifi_create_if_driver
```

结果解读，三条硬证据：① 18.2 走读的每一个接缝符号——`wlanif_input/init_sta`（netif 侧）、`esp_netif_receive/transmit_wrap`（绑定层）、`wifi_sta_receive/ap_receive/create_if_driver`（驱动适配对象）、`esp_pbuf_allocate/free`（零拷贝 pbuf）、`esp_wifi_internal_tx/reg_rxcb`（闭源库边界 API）——**全部真实存在于 elf**，包括小写 t 的 static 函数（没被链接器 GC 掉，说明确实从可达代码路径被引用）；② 顺带验证 18.6.3 要用的注入器本体 `lossy_linkoutput` 也链接进来了；③ 闭源库成员确认：对预编译归档直接 `nm` 可见 `esp_wifi_internal_tx/internal_reg_rxcb/init_internal` 由 `components/esp_wifi/lib/esp32/libnet80211.a` 导出（map 文件同步显示 `libnet80211.a(ieee80211_output.o)` 等成员参与了最终链接）——黑盒边界从此有了可复核的锚点。

### 18.6.2 实验 B：以太网对照——10% 丢帧 linkoutput 包装器

> [!warning] 方法学替换声明
> 本实验**不是 WiFi 实验**。openeth 是理想有线链路；我们在 guest 的 `netif->linkoutput` 外包一层随机丢帧器模拟「上行方向无线损耗」。它与真实 WiFi 的异同：相同的是对 lwIP 的表现同构（帧交给介质后无声消失，TCP 只能等 ACK 判生死）；不同的是真实无线丢包强突发（深衰落成串丢）、且驱动层还有 MAC 重传这道墙（我们绕过了它，同等应用负载下比真实情境更狠）。所有结论请按「TCP 对独立随机丢帧的反应」解读，勿外推为 ESP32 WiFi 性能数据。

原理：ch12 验证过的标准手法——`esp_netif_get_netif_impl()` 拿到 lwIP netif 后，通过 `tcpip_callback()` 在 tcpip 线程内原子替换 `linkoutput` 函数指针。注入器固定种子 xorshift32 PRNG 保证可复现：

```c
static err_t lossy_linkoutput(struct netif *netif, struct pbuf *p)
{
    s_seed ^= s_seed << 13; s_seed ^= s_seed >> 17; s_seed ^= s_seed << 5;
    if ((s_seed % 100u) < LOSS_PERCENT) {
        s_drop++;
        return ERR_OK;                    /* 帧在“空中”消失，发送方毫不知情 */
    }
    s_pass++;
    return s_orig_linkoutput(netif, p);
}
```

丢帧**对所有帧生效**（ARP、纯 ACK、数据一样抽签），错误码语义刻意保持 ERR_OK——这才是无线。宿主机测量脚本 `tools/bench.py`：RTT 套件（300 次 64B echo 往返事务，TCP_NODELAY）与 bulk 套件（上传 4 MiB / 16KB 块、滚动校验回显，goodput 按已校验字节计）。两相位同机先后测量，避开 QEMU ±50% 负载抖动（Batch 3 教训）。

一键复现命令：

```bash
cd practice/lwip-ch18-esp32-wifi-lwip-integration
./tools/run_experiment.sh          # 起 QEMU(hostfwd 8050) → 自动跑完两相位 → 打印 bench_out.txt
cat bench_out.txt
```

真实输出（第二轮完整运行实录；guest 侧 run.log 同步记录相位标记）：

```text
########## PHASE 1: BASELINE ##########
== RTT suite ==
samples_total=300 completed=300 stalled_failed=0
rtt_p50=0.46ms rtt_p90=0.64ms rtt_p95=0.73ms rtt_p99=1.17ms rtt_max=9.87ms rtt_mean=0.51ms
== BULK suite ==
upload_target=4194304 sent=4194304 verified_echo=4194304 elapsed=8.91s goodput_verified=3.77Mbit/s partial=False

########## SWITCH: install lossy linkoutput ##########
ctl b'CTL:LOSSY_ON' -> b'OK\n'
########## PHASE 2: LOSSY 10% TX FRAME DROP ##########
== RTT suite ==
samples_total=300 completed=300 stalled_failed=0
rtt_p50=0.55ms rtt_p90=1487.41ms rtt_p95=1497.85ms rtt_p99=4488.12ms rtt_max=10491.88ms rtt_mean=234.99ms
== BULK suite ==
upload_target=4194304 sent=131072 verified_echo=128192 elapsed=33.48s goodput_verified=0.03Mbit/s partial=True

########## UNWRAP + guest counters ##########
ctl b'CTL:LOSSY_OFF' -> b'OK\n'
```

guest 日志中的关键行（run.log 摘录，注入计数来自摘掉包装器时的打印）：

```text
I (2711) ch18lab: ETH netif impl @0x3ffc2618 name=en1
I (12041) ch18lab: INJECT: linkoutput wrapped, loss=10% seed=0x20260826
I (117111) ch18lab: INJECT: removed, pass=538 drop=56 (9%)
```

结果解读：

- **中位数几乎免疫，尾部指数爆炸**：p50 仅 0.46ms→0.55ms（+20%，多为抽样噪声），而 p90 0.64ms→1487ms（×2300）、p99 1.17ms→4488ms、max 9.87ms→10.5s。TCP 把偶发丢帧转化成「等 RTO」：丢一个回显帧 → 对端沉默 → 重传定时器到期 → 指数退避再试。分布形状从「贴地的窄脉冲」变成「长尾」——这就是无线链路上 ping 图的真实审美（偶发秒级毛刺、均值毫无意义），只是这里把它逼到了极端。max≈10s 与 ch12 的 RTO 退避链（1s→2s→3s 台阶封顶 3000ms）串联合理：数个台阶叠加即可堆出十秒 stall。
- **吞吐塌方且不成比例**：baseline 3.77Mbit/s 满额完成；lossy 相位 60s 预算只挪了 131KB 后放弃（goodput 0.03Mbit/s，↓97%）。不是线性劣化的原因：bulk 相位在途数据大，一旦窗口内有帧消失，后续 ACK 拥挤在重传之后，有效窗口迅速缩水；被卡住的整窗数据无法推进，采样期内只完成极少量有效传输。第一轮试跑曾得到「786KB/60s」的中档结果——同参数不同随机相位落点导致悬殊方差，这本身就是有损链路的特征：**吞吐指标对丢帧瞬间的位置极度敏感**（正在传输什么、窗口多大、撞没撞上 RTO）。
- **注入计数诚实**：pass=538 drop=56 → 9.4%，与设定 10% 吻合（样本量小的统计涨落）；同时它侧面暴露残酷事实——塌方期 104s 里总共只发出 594 个帧：**瓶颈不在带宽，在于绝大多数时间根本没有帧能上路**（在等 RTO）。
- 客观的 caveats：SLIRP 本身带 ~0.8% 仿真尾损（ch10 实测），对两相位同时存在、不改相对结论；absolute 吞吐受 SLIRP 天花板压制，只取同 harness 相对比较；测量只有单轮次样本量（方法学演示性质），严谨曲线上应做 N 轮交错。

### 18.6.3 附录：给想追到「真·WiFi 仿真」的读者

本环境的既定事实（均已本机核实）：`qemu-system-xtensa` 安装目录下**不存在** esp-wifi-mac 相关包（find 为空）；官方 esp-toolchain-docs 的 QEMU 功能矩阵把 Wi-Fi 标为不支持，建议以 OpenCores Ethernet 替代联网需求（参见仓库 README 功能表与 esp-idf issue #15087 的官方指向）。历史上的 Wi-Fi 仿真路线 Espressif 确实做过：以闭源 blob 形式发布（文献中称 esp-wifi-mac.pkg），主要面向 ESP32-C3 目标、配合定制 QEMU 构建——因为 MAC 软件仿真的实现无法开源，所以从未进入常规发行渠道；学术圈因此也有逆向的开源 MAC 项目（Zeus WPI 的 lib80211mac 系列）。若你执意复现，参考路径（**以下步骤未经本机验证**，仅作路标）：① 关注 espressif/qemu releases 是否提供附 WiFi blob 的构建变体；② 官方替代品 [esp-emulator](https://github.com/espressif/esp-emulator)（RISC-V 目标 emulator，自带 WiFi/BLE 仿真与本篇同款 OpenCores ETH）；③ 最可靠路径仍是真机：任意 ESP32 DevKit + 本章工程的 openeth 部分换成 `esp_netif_create_default_wifi_sta()` 正式初始化即可，走读章节的接线照抄。

真机环境下编译与启动与以太网章的差异点（预期清单，供对照）：组件依赖加 `esp_wifi`/`nvs_flash`，先 `nvs_flash_init()`；事件侧 `IP_EVENT_STA_GOT_IP` 替代 `IP_EVENT_ETH_GOT_IP`；启动顺序 esp_netif_init → 建默认 STA netif → `esp_wifi_init(WIFI_INIT_CONFIG_DEFAULT())` → set_mode/set_config → start → 等 START 事件再 connect；不再需要 `-nic user,model=open_eth,hostfwd=...` 的 QEMU 参数与 mac filter 噪音日志。若装上了带 WiFi 仿真的 QEMU 变体，则差异通常只剩「换二进制 + 按其 README 传入射频仿真参数」，应用代码零改动——这正是 esp_netif 抽象的回报。

## 18.7 翻车点表：WiFi × lwIP 联合排雷

| 症状                                               | 根因                                                                       | 处理                                                                        |
| -------------------------------------------------- | -------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| CONNECTED 一到就建 socket，发数据 errno 报错或卡住 | 只完成了 802.11 关联，DHCP 还没跑完（rxcb 都还没注册）                     | 以 `IP_EVENT_STA_GOT_IP` 为唯一放行闸门（18.5 恢复链）                      |
| 掉线重连后 IP 变了，socket 全失效但应用还在用旧 fd | `esp_netif_action_disconnected → esp_netif_down` 清了地址/路由，PCB 不可用 | 订阅 DISCONNECTED 主动关闭重建 socket；别等读写报错兜底                     |
| 高吞吐时 heap 直落、动态 RX 缓冲刷满、随后丢帧     | 零拷贝 pbuf 停留时间长（消费慢），驱动缓冲池被扣住不还                     | 对齐 DYNAMIC_RX_BUFFER_NUM ↔ TCP_WND（18.4.3 公式）；排查 recv 循环是否积压 |
| `tcp_write` 返回 ERR_MEM 但看堆余量充足            | TX 拷贝语义下驱动 TX 缓冲排队满（重传滞留），上游误报内存                  | 关注 DYNAMIC_TX_BUFFER_NUM 与 SND_BUF 配对；重传风暴场景先降负载            |
| mDNS/组播时通时断，STA 省电档开着                  | MAX_MODEM listen interval 内广播组播直接丢（官方明言）                     | 组播业务禁用 MAX 档或缩短 listen_interval（18.4.1）                         |
| ping 抖动大但带宽测试正常、均值看不出问题          | Modem sleep 让下行首包压到 DTIM/listen interval 才放行                     | 看 p95/p99 别看平均；低延迟需求切 `WIFI_PS_NONE`（18.4.1）                  |
| 多接口共存（ETH+STA/AP）时出网走错口               | 默认路由按 netif route_prio 取：STA 100 > ETH 50 > AP/NAN 10               | 用 `esp_netif_set_route_prio()` 或接口绑定 socket 显式分流（18.2.1）        |
| QEMU 里调 wifi 相关实验直接复位/死等射频           | 本机 QEMU 无 esp-wifi-mac，libnet80211 无法运行                            | 本章同款处理：对象级创建 + nm 符号验证 + openeth 对照（18.6）               |

---

## 18.8 小结

- **802.11 → 以太网的翻译在闭源库内完成**，lwIP 拿到的永远是标准以太网帧；开放世界看得到的只有边界签名（`wifi_rxcb_t` 回调、`esp_wifi_internal_tx` 的 copy 语义）和这侧的 `wlanif.c`「以太网骨架套皮」。
- **数据面的完整链条是三个文件、两次跨界**：wifi 任务执行 `wifi_sta_receive` → `esp_netif_receive` → `wlanif_input` →（PBUF_REF 零拷贝 or L2_TO_L3 拷贝，默认零拷贝）→ `tcpip_input` 投邮箱；TX 反向经 `low_level_output` → `esp_netif_transmit_wrap` → `esp_wifi_internal_tx`（驱动持副本直到 ACK/重传结束）。STA 的 rxcb 在 CONNECTED 事件才注册——那之前的静默是特性。
- **pbuf 生命周期的无线特供约束**：RX 侧零拷贝 pbuf 的 custom_free 决定驱动缓冲归还时刻，消费端任何滞留都会反噬到驱动缓冲池；TX 侧 `LWIP_NETIF_TX_SINGLE_PBUF=1`（ch6）保证了 wlanif 看到的几乎总是单段 pbuf。
- **任务模型一句话**：WiFi 是「胖驱动单任务」——从底半部到 rxcb 回调都压在一个核亲和 Core0（可配）的 wifi 任务里，库里凭 os_adapter 要资源，任务名/优先级是黑盒；与 tcpip 任务(prio 18)之间只有邮箱这条羊肠小道。
- **调优优先级**：先对齐缓冲配对（DYNAMIC_RX↔TCP_WND、DYNAMIC_TX↔SND_BUF、BA 窗≤2×静态RX），再谈 AM×DU 杠杆（AMPDU y 是默认、AMSDU n 是谨慎）；省电档位决定 RTT 地板（官方口径：延迟可与 DTIM/listen interval 同阶），吞吐对丢帧瞬时位置的敏感度远大于对平均值的敏感度——18.6 用一根 10% 的签筒复现了这条规律。
- **Vanilla 差异的四个关键词**：零拷贝开关、控制面强制过河（\_RUN_IN_LWIP_TASK）、事件面独立（esp_event）、名字即接口。断线恢复链 `DISCONNECTED → esp_netif_down → connect → CONNECTED →(rxcb 补挂) → DHCP → GOT_IP` 每一步都有据可查， 别在 GOT_IP 前建 socket（ch16 边界）。

下一章转到协议栈头顶上的调度问题：中断与优先级设计。当网卡中断、wifi 任务、tcpip 任务和应用在双核上抢时间，谁来让谁？临界区持有时中断被拖住会发生什么？优先级怎么排才能既不饿死协议栈又不饿死应用——[[2026-08-26-lwip-deep-dive-ch19-isr-and-priority-design|第十九章：ISR 与优先级设计]] 将把前面所有章节里的任务清单摊在一张优先级地图上重新审视。
