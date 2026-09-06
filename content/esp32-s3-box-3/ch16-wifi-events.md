---
title: "ESP32-S3-BOX-3 工程实战（十六）：WiFi 与 esp_netif"
date: 2026-08-26 12:00:00
description: "从 station 例程逐行走读 ESP-IDF 的 WiFi 分层：esp_netif 为什么夹在应用与 esp_wifi 之间、init→start→connect 的事件流、「拿到 IP 才算连上」的边界、生产级断线重连状态机、wifi 任务与缓冲资源、Modem Sleep 省电与 DFS 的关系，最后在真机上连手机热点观察断线重连。"
tags: [esp32, esp32-s3, esp-idf, series, wifi]
---

# ESP32-S3-BOX-3 工程实战（十六）：WiFi 与 esp_netif

> [!info] ESP32-S3-BOX-3 工程实战系列 0. [[esp32-s3-box-3|系列索引]]
> 上一章：[[ch15-lvgl|第十五章：LVGL]]
> **第十六章：WiFi 与 esp_netif**（当前章）
> 下一章：[[ch17-rainmaker-matter|第十七章：生态一瞥]]

WiFi 是这块板子区别于「普通 MCU 开发板」的第一能力，也是事件驱动编程的最佳教材：连接的每一步推进都靠事件通知，而不是返回值。本章以官方 station 例程为主线走读，回答四个问题：**esp_netif 这层抽象为什么存在**、**从 init 到拿到 IP 中间发生了什么**、**断线之后怎么重连才算生产级**、**WiFi 任务与省电模式怎么和系统其余部分共处**。esp_event 的基础（事件循环、handler 注册、默认循环的任务模型）在 [[ch7-system-services|第七章系统服务层]] 已讲，本章直接使用，不重复教学。

本章所有例程与源码引用均为本地实地读取：esp-idf v6.0.2 的 `examples/wifi/getting_started/station/`、`components/esp_wifi/`、`components/esp_netif/`、`docs/zh_CN/api-guides/wifi-driver/`，以及 esp-box 仓库 factory_demo 的 `main/app/app_wifi.c` 与 `sdkconfig.defaults`。

---

## 16.1 分层全景：esp_netif 为什么夹在中间

先给结论图（L1 视角）：

```text
应用代码            socket / HTTP / MQTT / esp_netif_get_ip_info()
   │
esp_netif           网络接口抽象：netif 对象、DHCP 客户端、IP 事件（IP_EVENT_*）
   │
esp_wifi            驱动 + MAC 层：wifi 任务、扫描/连接状态机、WIFI_EVENT_*
   │
RF / PHY / BB       射频（闭源库 components/esp_wifi/lib/）
```

新手最容易困惑的一件事：**连接 WiFi 与「能上网」是两层的事**。`esp_wifi_connect()` 只负责 802.11 链路层关联；IP 地址、路由、DHCP 全部住在 esp_netif 这一层。把这两层分开的动机有三个：

1. **应用与 lwip 解耦**。TCP/IP 栈是第三方 lwip，IDF 不让应用代码直接摸它的内部 API，而是用 `esp_netif_*` 提供稳定接口（查 IP、开关 DHCP、DNS）。lwip 升级时应用代码不动。
2. **多接口管理**。ESP32 可同时开 STA + SoftAP（`WIFI_MODE_APSTA`），一个射频、两个网络接口、两套 IP——esp_netif 里各是一个独立的 netif 对象。以太网、PPP（蜂窝模组）也走同一套抽象，应用层 API 一致。
3. **IP 事件的归属**。`IP_EVENT_STA_GOT_IP` 由 esp*netif 发出（DHCP 在这层跑），`WIFI_EVENT*\*` 由 esp_wifi 发出。两个事件基（event base）、两套 ID，这正是第七章 esp_event「多事件源共循环」设计的用武之地。

L2 层看一眼「默认 STA 接口」是怎么拼起来的。`esp_netif_create_default_wifi_sta()` 在 `components/esp_wifi/src/wifi_default.c:418` 只做三件事：

```c
esp_netif_t* esp_netif_create_default_wifi_sta(void)
{
    esp_netif_config_t cfg = ESP_NETIF_DEFAULT_WIFI_STA();
    esp_netif_t *netif = esp_netif_new(&cfg);              // 1. 建 netif 对象
    assert(netif);
    ESP_ERROR_CHECK(esp_netif_attach_wifi_station(netif)); // 2. 绑到 WiFi 驱动的 STA 接口
    ESP_ERROR_CHECK(esp_wifi_set_default_wifi_sta_handlers()); // 3. 挂默认事件 handler
    return netif;
}
```

第 3 步是「魔法」所在：`esp_wifi_set_default_wifi_sta_handlers()` 在内部把 WiFi 事件翻译成 netif 动作（`wifi_default.c`）——`WIFI_EVENT_STA_START` → `esp_netif_action_start`，`WIFI_EVENT_STA_CONNECTED` → `esp_netif_action_connected`，`WIFI_EVENT_STA_DISCONNECTED` → `esp_netif_action_disconnected`。而 `esp_netif_action_connected`（`components/esp_netif/esp_netif_handlers.c:35`）里藏着 DHCP 的启动点：`esp_netif_up()` 之后若 DHCP 状态是 `ESP_NETIF_DHCP_INIT` 就 `esp_netif_dhcpc_start()`。所以你不写一行 DHCP 代码，连上 AP 后 IP 就「自己」来了——是这一串默认 handler 在事件循环里替你干的。

---

## 16.2 状态机与事件：init → start → connect 的正确序列

官方 station 例程（`examples/wifi/getting_started/station/main/station_example_main.c`）的初始化序列，逐行都有明确的副作用：

| 步骤 | API                                                          | 背后发生什么                                          |
| ---- | ------------------------------------------------------------ | ----------------------------------------------------- |
| 1    | `esp_netif_init()`                                           | 创建 lwip 核心任务（tcpip_task），整个进程只调一次    |
| 2    | `esp_event_loop_create_default()`                            | 创建默认事件循环任务（sys_evt），第七章的主角         |
| 3    | `esp_netif_create_default_wifi_sta()`                        | 建 netif 对象 + 挂 16.1 节那串默认 handler            |
| 4    | `esp_wifi_init(&cfg)`                                        | 分配收发缓冲、控制结构，**创建 wifi 任务**（16.4 节） |
| 5    | `esp_wifi_set_mode(WIFI_MODE_STA)` + `esp_wifi_set_config()` | 配置模式与 SSID/密码                                  |
| 6    | `esp_wifi_start()`                                           | 启动驱动 → 事件 `WIFI_EVENT_STA_START`                |
| 7    | handler 里 `esp_wifi_connect()`                              | 内部先扫描目标 AP，找到才发起关联                     |
| 8    | 关联成功 → `WIFI_EVENT_STA_CONNECTED`                        | 默认 handler 在此事件里启动 DHCP 客户端               |
| 9    | DHCP 完成 → `IP_EVENT_STA_GOT_IP`                            | 到这里才算「能上网」                                  |

顺序 1→4 大体是硬约束（`esp_wifi.h` 文档明言 esp_wifi_init 必须先于其它 WiFi API），例程照抄即可。第 7 步值得注意：`esp_wifi_connect()` **在事件 handler 里调**，而不是 init 序列里直接调——因为 `esp_wifi_start()` 是异步的，必须等 `WIFI_EVENT_STA_START` 到了，station 接口才可用。

例程的事件 handler 全文（实地摘录）：

```c
static void event_handler(void* arg, esp_event_base_t event_base,
                                int32_t event_id, void* event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        if (s_retry_num < EXAMPLE_ESP_MAXIMUM_RETRY) {
            esp_wifi_connect();
            s_retry_num++;
            ESP_LOGI(TAG, "retry to connect to the AP");
        } else {
            xEventGroupSetBits(s_wifi_event_group, WIFI_FAIL_BIT);
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI(TAG, "got ip:" IPSTR, IP2STR(&event->ip_info.ip));
        s_retry_num = 0;
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
    }
}
```

三个事件各自的职责：

- **`WIFI_EVENT_STA_START`**：station 接口就绪，唯一该做的是发起连接。
- **`WIFI_EVENT_STA_DISCONNECTED`**：既在「连不上」时出现（密码错、找不到 AP），也在「连上后掉线」时出现。附带数据 `wifi_event_sta_disconnected_t` 有 `reason`（断线原因码）与 `rssi` 字段——生产代码必须区分「密码错（重试无意义）」与「信号弱/AP 暂时消失（值得重试）」。
- **`IP_EVENT_STA_GOT_IP`**：DHCP 完成。附带数据 `ip_event_got_ip_t` 含完整 `ip_info`（IP/掩码/网关）和 `ip_changed` 标志（IP 变了也会再发一次此事件）。

**「拿到 IP 才算连上」** 是本章最重要的边界认知。官方文档在场景走读里加粗强调：_「切忌在接收到 IP 之前启动任何套接字相关操作」_。`WIFI_EVENT_STA_CONNECTED` 只代表 802.11 关联成功，此刻还没有 IP，socket 全是废纸。反过来更狠：`WIFI_EVENT_STA_DISCONNECTED` 到达时，事件任务会通知 lwip 任务**清除所有 TCP/UDP 连接**——所有在用的 socket 立即变错误态。也就是说断线重连不只是重新 `esp_wifi_connect()`，应用层还要负责关掉并重建自己的 socket。

---

## 16.3 断线重连：从例程到生产级

官方例程的重连策略就是上面 handler 的中间分支：计数器 `s_retry_num`，上限 `CONFIG_ESP_MAXIMUM_RETRY`（Kconfig 默认 5），连上后清零，超限置 `WIFI_FAIL_BIT`。教学够用，生产差三口气：**无退避**（AP 消失时 5 次重试在一秒内烧完）、**不区分原因**（密码错也白试 5 次）、**超限后死透**（没有降级路径）。

factory_demo 的做法更「产品」一些（`app_wifi.c:140`）：断线事件里无条件 `esp_wifi_connect()`，同时刷 UI 状态栏——无限重连，交给用户拔电源。这也是一种合理的取舍：音箱类设备断网后除了等没有别的事可做。

两个官方事实先摆出来，再给改进骨架：

- v6 的 `esp_wifi.h` 对 `esp_wifi_connect()` 的 attention 4 明确写着：此 API **只尝试连接一次**，重连逻辑建议由应用实现（`wifi_sta_config_t.failure_retry_cnt` 可配置驱动内部重试，但要求 `scan_method = WIFI_ALL_CHANNEL_SCAN`）。
- handler 跑在 sys_evt 任务里（第七章），**不能在里面 `vTaskDelay` 或做任何阻塞等待**——会卡住整个系统事件循环（16.7 节翻车点第一条）。

生产级骨架：handler 只置事件标志，重连节拍由独立任务管理，指数退避 + 上限 + 降级动作：

```c
#define RECONNECT_MAX      10    /* 连续失败上限 */
#define RECONNECT_BASE_MS  1000  /* 退避基数 */

static void event_handler(void* arg, esp_event_base_t base,
                          int32_t id, void* data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        xEventGroupSetBits(s_flags, FLAG_START);
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t* d = data;
        if (d->reason == WIFI_REASON_AUTH_FAIL ||
            d->reason == WIFI_REASON_NO_AP_FOUND) {
            /* 凭证错误类：重试无意义，直接降级（如重启配网） */
            xEventGroupSetBits(s_flags, FLAG_BAD_CRED);
        } else {
            xEventGroupSetBits(s_flags, FLAG_DOWN);  /* 只置标志，不干活 */
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        xEventGroupSetBits(s_flags, FLAG_GOT_IP);
    }
}

static void reconnect_task(void* arg)       /* 独立任务，退避节拍住这里 */
{
    int fails = 0;
    for (;;) {
        EventBits_t b = xEventGroupWaitBits(s_flags, FLAG_START | FLAG_DOWN,
                                            pdTRUE, pdFALSE, portMAX_DELAY);
        if (b & FLAG_START) fails = 0;
        if (b & (FLAG_START | FLAG_DOWN)) {
            esp_wifi_connect();
            b = xEventGroupWaitBits(s_flags, FLAG_GOT_IP | FLAG_BAD_CRED,
                                    pdTRUE, pdFALSE, pdMS_TO_TICKS(15000));
            if (b & FLAG_GOT_IP) { fails = 0; continue; }
            if (++fails > RECONNECT_MAX) { start_provisioning(); fails = 0; continue; }
            vTaskDelay(pdMS_TO_TICKS(RECONNECT_BASE_MS << (fails - 1)));  /* 1s,2s,4s… */
        }
    }
}
```

要点：退避用 `vTaskDelay` 而不是软件定时器，是因为重连序列本身是顺序流程，任务模型最直白；`fails` 在 GOT_IP 后清零，把「连上后又掉」与「从未连上」区分开（前者立刻重连，后者走退避）。这个骨架未在真机验证过，节拍参数当占位符看。

---

## 16.4 WiFi 任务与资源：谁在哪个核上跑

WiFi 启动后系统里多出三个常驻任务，各有归属：

| 任务       | 创建者                            | 作用                                 | 关键配置                              |
| ---------- | --------------------------------- | ------------------------------------ | ------------------------------------- |
| wifi task  | `esp_wifi_init()`                 | 驱动与 MAC 层：扫描、关联、收发调度  | 核绑定见下                            |
| tcpip_task | `esp_netif_init()`                | lwip 协议栈                          | `CONFIG_LWIP_TCPIP_TASK_STACK_SIZE`   |
| sys_evt    | `esp_event_loop_create_default()` | 派发 WIFI/IP/PROV 事件给你的 handler | 栈默认 2304B，factory_demo 提到 4096B |

wifi 任务钉在哪个核由 Kconfig choice `ESP_WIFI_TASK_CORE_ID` 决定，默认 `CONFIG_ESP_WIFI_TASK_PINNED_TO_CORE_0`——即 Core 0，正是 FreeRTOS 系列第一章讲的 **PRO_CPU**（Protocol CPU）约定：协议栈任务住 Core 0，应用任务住 Core 1，避免互相踩调度（见 [[freertos-deep-dive|FreeRTOS 系列索引]] 的双核章节）。若想换核，宏链在 `esp_wifi.h:197`（`WIFI_TASK_CORE_ID` → `wifi_init_config_t.wifi_task_core_id`）。

缓冲资源是 WiFi 内存开销的大头，概念级认识三组 Kconfig（`components/esp_wifi/Kconfig`，含 help 原文口径）：

| 配置                                    | 默认 | 说明                                                                                                                           |
| --------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------ |
| `CONFIG_ESP_WIFI_STATIC_RX_BUFFER_NUM`  | 10   | 静态接收缓冲，每个约 1.6KB，`esp_wifi_init` 时分配、`esp_wifi_deinit` 才释放                                                   |
| `CONFIG_ESP_WIFI_DYNAMIC_RX_BUFFER_NUM` | 32   | 动态接收缓冲上限，按帧大小分配                                                                                                 |
| `CONFIG_ESP_WIFI_CACHE_TX_BUFFER_NUM`   | 32   | 发送缓存队列长度，**仅在 `CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y` 时存在**：静态 TX 缓冲不够用时，驱动先把上层包缓存进这个队列 |

factory_demo 的 `sdkconfig.defaults` 给了一份真机调优样例（8MB PSRAM 被 LVGL/音频/语音模型瓜分后的抠门配置）：`SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y`、`ESP_WIFI_STATIC_RX_BUFFER_NUM=3`、`DYNAMIC_RX_BUFFER_NUM=4`、`STATIC_TX_BUFFER_NUM=4`、`CACHE_TX_BUFFER_NUM=16`——缓冲全部砍到默认值的 1/3~1/2，用 PSRAM 兜底。这印证一个事实：**WiFi 吞吐与内存余量是一对可调的旋钮**，音频 + 屏幕 + AI 共存的设备上，默认值未必合适。

---

## 16.5 省电：Modem Sleep 与 DFS 的一币两面

STA 连上后的射频省电只有一档机制：**Modem Sleep**（802.11 传统节能模式，睡眠时 RF/PHY/BB 断电，靠按节拍醒来收 beacon 维持连接）。`esp_wifi_set_ps()` 三档（枚举定义见 `esp_wifi_types_generic.h:375`）：

| 模式                        | 醒来节拍                                          | 组播/广播 | 典型场景                  |
| --------------------------- | ------------------------------------------------- | --------- | ------------------------- |
| `WIFI_PS_NONE`              | 不睡                                              | 不丢      | 吞吐/低延迟优先，功耗最高 |
| `WIFI_PS_MIN_MODEM`（默认） | 每个 DTIM 间隔醒一次                              | 不丢      | 通用档位                  |
| `WIFI_PS_MAX_MODEM`         | 每个 listen interval 醒一次（可配成多个 DTIM 长） | **会丢**  | 电池供电、容忍延迟        |

`listen_interval` 在 `wifi_config_t.sta` 里配置，单位是 AP 的 beacon 间隔，置 0 时驱动用默认值 3；必须在连接前设置。MAX 档省电更多，代价是「醒得不够勤 → beacon 之间的广播/组播收不到」——mDNS、组播时钟同步、依赖广播的发现协议都会受影响。

**与 DFS 的关系**是本节的关键耦合。CPU 动态调频（PM/DFS，factory_demo 的 `CONFIG_PM_ENABLE=y` + `CONFIG_PM_DFS_INIT_AUTO=y`，240MHz 高载 40MHz 空闲）与 WiFi 看似无关，实际靠 PM lock 缝合：`esp_wifi_init()` 在 `CONFIG_PM_ENABLE` 时创建一把 `ESP_PM_APB_FREQ_MAX` 锁（`src/wifi_init.c:473`，名字就叫 "wifi"），射频活动期间持有（`wifi_apb80m_request()`）、空闲释放。射频一工作，APB 时钟就被钉在 80MHz，DFS 降不动；射频睡眠时锁释放，DFS 才能压频。所以「WiFi 省电模式」与「CPU 调频省电」是叠乘关系：Modem Sleep 决定射频醒多久，PM lock 决定醒着的时候 CPU 能不能降频。

factory_demo 是这套取舍的完整样本（`sdkconfig.defaults` + `app_wifi.c` 均实地核实）：

- `CONFIG_EXAMPLE_POWER_SAVE_MAX_MODEM=y` + `CONFIG_EXAMPLE_WIFI_LISTEN_INTERVAL=10` → `DEFAULT_PS_MODE = WIFI_PS_MAX_MODEM`，每 10 个 beacon 周期醒一次（激进省电档）；
- 配网阶段反其道而行：BLE 配网循环里先 `esp_wifi_set_ps(WIFI_PS_MIN_MODEM)` 保证配网响应性，`WIFI_PROV_DEINIT` 事件再切回 `DEFAULT_PS_MODE`；
- `esp_wifi_set_inactive_time(WIFI_IF_STA, ...)` 配 beacon 超时（多久收不到 beacon 判掉线）；
- `CONFIG_ESP_PHY_MAC_BB_PD=y` 让轻睡眠时 MAC/基带电源域真正下电。

取舍表（经验口径，具体数值以真机实测为准）：

| 需求                      | 推荐                            | 理由                              |
| ------------------------- | ------------------------------- | --------------------------------- |
| 音箱随时响应语音指令      | MIN_MODEM                       | 广播/组播不丢，云端 MQTT 延迟可控 |
| 电池传感器低频上报        | MAX_MODEM + listen_interval 10+ | 每分钟醒几百毫秒即可              |
| iperf 打吞吐 / 低延迟控制 | PS_NONE                         | 睡眠唤醒引入首包延迟，不可控      |

---

## 16.6 实验：连手机热点 + 观察断线重连

基于官方 station 例程裁剪的完整骨架（保留事件骨架、去掉 WPA3 宏分支便于阅读；SSD/密码走 menuconfig，即 `CONFIG_ESP_WIFI_SSID/PASSWORD`，见 `main/Kconfig.projbuild`）：

```c
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "esp_netif.h"

static EventGroupHandle_t s_ev;
#define BIT_GOT_IP  BIT0
#define BIT_LOST    BIT1

static void handler(void* a, esp_event_base_t base, int32_t id, void* data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t* d = data;
        ESP_LOGI("exp", "disconnect, reason=%d rssi=%d", d->reason, d->rssi);
        esp_wifi_connect();                       /* 教学式无限重连 */
        xEventGroupSetBits(s_ev, BIT_LOST);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* e = data;
        ESP_LOGI("exp", "got ip " IPSTR " gw " IPSTR, IP2STR(&e->ip_info.ip),
                 IP2STR(&e->ip_info.gw));
        xEventGroupSetBits(s_ev, BIT_GOT_IP);
    }
}

void app_main(void)
{
    esp_err_t r = nvs_flash_init();
    if (r == ESP_ERR_NVS_NO_FREE_PAGES || r == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }
    s_ev = xEventGroupCreate();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, handler, NULL, NULL));

    wifi_config_t wc = {
        .sta = { .ssid = CONFIG_ESP_WIFI_SSID,
                 .password = CONFIG_ESP_WIFI_PASSWORD,
                 .threshold.authmode = WIFI_AUTH_WPA2_PSK },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());

    for (;;) {  /* 状态机观察窗：打印每次状态跃迁 */
        EventBits_t b = xEventGroupWaitBits(s_ev, BIT_GOT_IP | BIT_LOST,
                                            pdTRUE, pdFALSE, portMAX_DELAY);
        ESP_LOGI("exp", b & BIT_GOT_IP ? "STATE: ONLINE" : "STATE: OFFLINE");
    }
}
```

> [!warning] 待真机验证
> 以下步骤与观察点尚未在 BOX-3 上执行，到货后按此清单验证并回填日志：
>
> 1. 拷贝例程：`cp -r $IDF_PATH/examples/wifi/getting_started/station ~/esp/wifi-lab && cd ~/esp/wifi-lab`，用上面的骨架替换 `main/station_example_main.c`；
> 2. `idf.py set-target esp32s3 && idf.py menuconfig`，在 Example Configuration 里填手机热点 SSID/密码（手机热点选 2.4GHz 频段，S3 不支持 5GHz）；
> 3. `idf.py -p /dev/ttyACM0 flash monitor`；
> 4. **观察点一（拿到 IP）**：日志应依次出现 `WIFI_EVENT_STA_START` 后的连接过程、`got ip ...`（此行格式即源码里的 `ESP_LOGI(TAG, "got ip:" IPSTR, ...)`，IP 为手机热点分配的 192.168.x.x）与 `STATE: ONLINE`；
> 5. **观察点二（断线重连）**：关掉手机热点，应看到 `disconnect, reason=...` 与 `STATE: OFFLINE`，随后周期性重试日志；重新打开热点，应在数秒内看到新的 `got ip` 与 `STATE: ONLINE`。记下 reason 值（beacon 超时与主动 deauth 的原因码不同，可在 `esp_wifi_types_generic.h` 的 `WIFI_REASON_*` 里对号）；
> 6. **观察点三（IP 变化）**：断开重连后若热点分配了不同 IP，注意 `IP_EVENT_STA_GOT_IP` 会再次触发——验证「连上」判断必须看事件而不是看一次 IP。

预期行为都来自源码与文档口径；具体时间戳、reason 数值以真机输出为准，不预写。

---

## 16.7 翻车点表与小结

| 症状                                                   | 根因                                                                                                       | 处理                                                                                                                 |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 连接成功但 socket 报错，过一会儿又好了                 | 在 `WIFI_EVENT_STA_CONNECTED`（关联完成）就建 socket，IP 还没到                                            | 建 socket 的时点移到 `IP_EVENT_STA_GOT_IP` 之后（16.2 节边界）                                                       |
| 系统偶发卡死/看门狗复位，日志停在某个 handler 内       | handler 跑在 sys_evt 任务里做了阻塞重活（`vTaskDelay`、HTTP 请求、大计算），卡住整条事件循环               | handler 只置标志/发队列，重活挪到 worker 任务（16.3 骨架）；sys_evt 栈默认仅 2304B，必要时同步调大                   |
| MAX_MODEM 下 mDNS 发现不了设备、keepalive 丢、组播断流 | listen interval 过长，beacon 间的广播/组播全丢（文档明言 MAX 档会丢广播）                                  | 改 `WIFI_PS_MIN_MODEM` 或调小 `listen_interval`；依赖组播的业务不要用 MAX 档                                         |
| WiFi 密码被读出                                        | `CONFIG_ESP_WIFI_NVS_ENABLED` 默认开，配置（含明文密码）持久化在 NVS；配网框架同样把凭据写 NVS，默认不加密 | 量产开 NVS Encryption（Flash Encryption + nvs_keys）；或敏感场景禁用 WiFi 配置持久化                                 |
| 出差/出口设备扫不到 12/13 信道 AP                      | 默认国家码 `cc="01"`，信道范围 1~11（`wifi_country_policy` 文档默认值）；各国信道与功率法规不同            | 用 `esp_wifi_set_country()` 显式配置（如 CN：1~13 信道），或确认 `WIFI_COUNTRY_POLICY_AUTO` 下 AP 的 country IE 生效 |
| 重试五次后设备「死机」在 WAIT                          | 例程超限后只置 FAIL_BIT，主流程没有下一步                                                                  | 按 16.3 节骨架加退避与降级路径（超限重启配网/进低功耗等待）                                                          |
| PSRAM 设备上高吞吐时内存耗尽崩溃                       | 动态 TX/RX 缓冲无上限增长                                                                                  | `SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y` + 静态缓冲 + CACHE_TX 兜底（对照 factory_demo 的调优值，16.4 节）                  |

本章小结：

- **esp_netif 是应用与协议栈之间的接口抽象层**：netif 对象 + DHCP + IP 事件都住这层；`esp_netif_create_default_wifi_sta()` 挂的那串默认 handler，把 `WIFI_EVENT_STA_CONNECTED` 翻译成 `esp_netif_up` + DHCP 启动，这就是「不写 DHCP 代码也有 IP」的全部魔法。
- **init → start → connect 是事件驱动的接力**：`esp_wifi_connect()` 必须等 `WIFI_EVENT_STA_START`；**「连上」的唯一定义是 `IP_EVENT_STA_GOT_IP`**——断线事件会清光所有 socket，应用层要自己重建。
- **重连要独立任务 + 退避 + 原因分诊**：handler 里只置事件标志；密码错与 AP 消失要分流，超限要有降级出口。官方例程与 factory_demo 各给了一种极端（有限次 vs 无限连），生产代码取中间。
- **wifi 任务默认钉 Core 0（PRO_CPU）**，缓冲内存是一组可调旋钮，PSRAM 设备参考 factory_demo 的紧预算配置。
- **Modem Sleep 三档 × DFS 是叠乘省电**：PS 档位决定射频醒多久，PM lock（`ESP_PM_APB_FREQ_MAX`）决定射频醒着时 CPU 降不降得下频；MAX 档的代价是广播/组播丢失。

下一章离开驱动层看生态：RainMaker 云平台与 Matter 协议在 BOX-3 上怎么跑起来——factory_demo 里那套 BLE 配网 + 自声明 claiming 的完整版图将在那里展开。
