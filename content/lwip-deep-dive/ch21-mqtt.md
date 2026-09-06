---
title: "lwIP 深度解析（二十一）：MQTT：esp-mqtt 架构与弱网行为"
date: 2026-08-26
description: "IDF v6 的 MQTT 真身是托管组件 espressif/mqtt 1.1.0。拆解 esp_mqtt_task 单任务状态机、STAILQ outbox（QUEUED→TRANSMITTED→ACKNOWLEDGED）、in/out buffer 1024B 语义与固定间隔重连；用 QEMU+SLIRP 直连宿主机 mosquitto 实测：20% TX 丢帧下 QoS0/QoS1 各 200 条零缺失、SIGSTOP 冻结 broker 的 keepalive 判死时延三轮复现、离线积压单价 1048B/条直逼堆耗尽、SIGTERM 死亡时序含 ECONNRESET 重连梯与 40ms 闪电解冻排空，并记录 clientId 接管风暴等五个真实排坑。"
tags: [lwip, network, esp32, esp-idf, qemu, mqtt]
---

> [!info] lwIP 深度解析系列 0. [[lwip-deep-dive|系列索引]] 21. **第二十一章：MQTT：esp-mqtt 架构与弱网行为**

# lwIP 深度解析（二十一）：MQTT：esp-mqtt 架构与弱网行为

这一章回答三个问题：**QoS0/1/2 在 lwIP 这一层到底意味着什么**（TCP 已经可靠了，为什么还要 QoS1）、**断线重连的退避节奏谁控制**（答案出乎意料地朴素——没有指数退避）、**broker 死掉的瞬间客户端协议栈里发生了什么**（FIN/静默/重置三种死法三副时序）。读完它，你应该能对着任意一条 `ESP_LOG` 里冒出来的 mqtt 报错，精确说出它出自 esp-mqtt 源码的哪条路径。源码参照：ESP-IDF v6.0.2 + 托管组件 **espressif/mqtt 1.1.0**（commit `1a1e5788`），lwIP 2.2.0-dev；实验在 QEMU openeth/SLIRP 上直连宿主机 mosquitto 2.0.22 完成。

> [!note] 一个反直觉的事实先摆在这
> IDF v6.0.2 的 `components/mqtt/` 目录下**没有任何客户端源码**——只剩测试工程壳。真实的 esp-mqtt 是组件管理器在首次构建时下载到工程里的 `managed_components/espressif__mqtt/`（manifest 写 `espressif/mqtt: "^1.0.0"`）。本章所有"源码走读"以这份下载产物为准。

---

## 21.1 核心问题三连

### 1. TCP 已然可靠，QoS 还剩什么

运行在 TCP 上意味着字节流不丢不乱。但 MQTT 的 QoS 承诺的不是"字节到达"，而是"**消息被应用确认**"。TCP 断连的那一刻，所有已发出未确认的消息全部作废——除非客户端自己把它们存了下来。esp-mqtt 的答案是 outbox：QoS>0 的消息在发出前先整体入箱，PUBACK 到达才删除。于是：

| QoS | 发送路径                                           | 断连时的命运                                                           | 一手实测结论（本章实验）                     |
| --- | -------------------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------- |
| 0   | 用户任务内同步直发，不入箱（`store=false` 时不入） | 直接丢失（返回 -1，日志 `Losing qos0 data when client not connected`） | 链路 20% 丢帧下 200/200 全达——TCP 兜住了帧损 |
| 1   | 先入箱 → 同步发 → 等 PUBACK 删除                   | 停留箱中，回连后带 DUP 重投                                            | 断连风暴窗产生秒级重复副本                   |
| 2   | 入箱 → PUBREC 后转 ACKNOWLEDGED → PUBREL/PUBCOMP   | ACKNOWLEDGED 态由 1s 定时器重发 PUBREL                                 | 流程存在但 ESP32 侧很少需要                  |

### 2. 退避节奏谁控制

谁都不控制——esp-mqtt 的重连间隔是**常量**：`abort_connection()` 把 `wait_timeout_ms = config->reconnect_timeout_ms`（默认 `MQTT_RECON_DEFAULT_MS` = 10s），之后每过一个完整周期就再试一次。没有指数退避、没有抖动。本章把它调成 2000ms 后，日志里能看到规整的 3 秒节拍。

### 3. broker 死亡瞬间发生什么

三种死法三条路：进程退出（内核代发 FIN）→ 读侧 EOF，事件层报 `EV ERROR type=1 sock_errno=0`；无声冻结（SIGSTOP）→ 内核替它应答 TCP，MQTT 层靠 keepalive 判死；硬重置（向已关闭的端口重连）→ 连接阶段直接吃 `ECONNRESET(104)`。21.6 节第 3 小节有逐毫秒时序表。

---

## 21.2 esp-mqtt 架构走读

### 1. 任务模型：一个任务、一个状态机、一把递归锁

`mqtt_client.c` 的主体是一个 FreeRTOS 任务 `esp_mqtt_task()`（默认优先级 5、栈 6144B，可经 `task.priority/task.stack_size` 覆盖），骨架如下：

```c
/* managed_components/espressif__mqtt/mqtt_client.c: esp_mqtt_task() */
while (client->run) {
    MQTT_API_LOCK(client);                 /* 递归互斥锁：把用户 API 与任务串行化 */
    run_event_loop(client);                /* 派发排队中的 MQTT_EVENT_* */
    mqtt_delete_expired_messages(client);  /* 清理滞留超 OUTBOX_EXPIRED_TIMEOUT_MS 的消息 */
    switch (state) {
    case MQTT_STATE_INIT:            /* 建 transport -> CONNECT -> 等 CONNACK */
        ...
        client->state = MQTT_STATE_CONNECTED;
    case MQTT_STATE_CONNECTED:
        mqtt_process_receive();      /* 解析入向报文并驱动全部 QoS 应答 */
        /* 先补发 QUEUED，再按 message_retransmit_timeout 周期重发 TRANSMITTED */
        process_keepalive();         /* keepalive 探测（见 21.4） */
    case MQTT_STATE_WAIT_RECONNECT:  /* 计时，到点回 INIT */
    }
    MQTT_API_UNLOCK(client);
    if (CONNECTED) esp_transport_poll_read(..., MQTT_POLL_READ_TIMEOUT_MS /*1000*/);
}
```

三个要点：

1. **用户调用的 `esp_mqtt_client_publish()` 也持同一把锁并在调用者上下文里完成同步写**——QoS0 是"发布者亲自写 socket"；写失败会当场 `abort_connection()`。
2. 任务主循环以 `poll_read` 最多阻塞 1000ms 为节拍，这决定了入向事件（PUBACK/DATA）的最大可见延迟。
3. 五个状态里真正干活的是 INIT 和 CONNECTED；`WAIT_RECONNECT` 只做倒计时。

### 2. outbox：先入箱、再等传输

`lib/mqtt_outbox.c` 是一个裸 STAILQ 单链表，每项 = 一个 `calloc` 出的结点头 + 一块存放**整条线上报文**（固定头+topic+payload+packet id）的堆缓冲：

```c
typedef struct outbox_item {
    char *buffer;  int len;  int msg_id; int msg_type; int msg_qos;
    outbox_tick_t tick;      pending_state_t pending;   /* QUEUED/TRANSMITTED/ACKNOWLEDGED */
    STAILQ_ENTRY(outbox_item) next;
} outbox_item_t;
```

生命周期：入箱 `QUEUED` → 被写下网络置 `TRANSMITTED`（qos0 则处理后立即删除）→ 收 PUBACK 删除；QoS2 收 PUBREC 转 `ACKNOWLEDGED`，等 PUBCOMP 后随 initiator 删除。`outbox->size` 是原子累加的字节数，`esp_mqtt_client_get_outbox_size()` 直接读它。`config->outbox.limit > 0` 时用它做入箱闸门，满了 publish 返回 **-2**。

### 3. in/out buffer：两条 1024B 缓冲的语义

`set_config` 阶段分配两块缓冲：`in_buffer`（收）默认 `buffer.size`=1024，输出缓冲默认同值（`buffer.out_size` 可单独放大）。语义上有两个容易踩的坑：

- **接收**：`mqtt_message_receive()` 发现 PUBLISH 总长超过 in_buffer 时，只装"固定头+topic(+packet id)"，payload 部分以多次分片 `MQTT_EVENT_DATA` 交付（`total_data_len/current_data_offset` 标注进度）；remaining-length 编码只读到 2 字节，即**单条消息上限约 16KB**，超出直接报错断连。
- **发送**：载荷大于输出缓冲同样分片循环写；非 QoS0 且放不下首个片段时会连同剩余数据整体入箱。

本章实验统一放大到 `buffer.size=out_size=2048`，让 1KB 消息走单包快路径——对照组的慢路径分片不在本章变量里。

### 4. 事件分发：MQTT*EVENT*\*

事件不是回调即发，而是填进 `client->event` 再派发给用户 handler（注册时可指定 `MQTT_EVENT_ANY` 通配）。对应用层可见的全集：

| 事件                      | 触发源                                     | 附带上文                                       |
| ------------------------- | ------------------------------------------ | ---------------------------------------------- |
| `BEFORE_CONNECT`          | 每次 INIT 进入                             | —                                              |
| `CONNECTED`               | CONNACK 且 rc=0                            | `session_present`                              |
| `DISCONNECTED`            | `abort_connection()`（一切失败的汇点）     | —                                              |
| `SUBSCRIBED/UNSUBSCRIBED` | SUBACK/UNSUBACK 匹配到 in-flight           | `msg_id`                                       |
| `PUBLISHED`               | PUBACK（QoS1）/PUBCOMP（QoS2）删除箱中项后 | `msg_id`                                       |
| `DATA`                    | 收到 PUBLISH                               | topic/data/分片偏移/qos/dup                    |
| `ERROR`                   | transport 错误或 CONNACK 拒绝              | `error_handle->sock_errno/connect_return_code` |
| `DELETED`                 | 过期清理删除箱中项（需 Kconfig 打开上报）  | `msg_id`                                       |

注意 handler 运行在 **mqtt 任务上下文**——里面只做信号量/计数是安全的，反调 client API 会与锁序纠缠。

### 5. 重连状态机：固定间隔，无退避

```c
/* abort_connection() —— 所有断连的汇点 */
wait_timeout_ms = config->reconnect_timeout_ms;   /* 默认 10*1000 */
reconnect_tick   = platform_tick_get_ms();
state            = WAIT_RECONNECT;
dispatch(MQTT_EVENT_DISCONNECTED);

/* WAIT_RECONNECT 分支 */
if (auto_reconnect && now - reconnect_tick > wait_timeout_ms)
    state = INIT;                                  /* 整个 connect 序列重来 */
```

`network.timeout_ms`（默认 10s）约束单次网络操作（连接/写）的上限；`disable_auto_reconnect=true` 可完全交给用户（配合 `esp_mqtt_client_reconnect()` 手动触发）。**没有指数退避**：弱网高频断连时就是等周期、再硬碰。本章实测一个由本机制引出的怪癖见实验小节的排坑 #4。

### 6. 传输栈归属：tcp_transport 之下才是 lwIP

esp-mqtt 自己一行 socket 代码都没有：`REQUIRES esp_event tcp_transport`。`mqtt://` scheme 映射到 tcp_transport 的 TCP 句柄，读写全是 `esp_transport_read/write/poll`。这一抽象层正是 TLS 能无感叠加的原因（21.5/22 章）。

### 7. 默认值速查：Kconfig 与运行时字段的分工

多数旋钮存在两层：Kconfig（须先开 `MQTT_USE_CUSTOM_CONFIG` 才暴露）与配置结构体字段，后者在 `set_config` 时覆盖前者；未设置一律落回 `lib/include/mqtt_config.h` 的数值：

| 语义                         | 结构体字段                               | 宏默认       | 本章取值        |
| ---------------------------- | ---------------------------------------- | ------------ | --------------- |
| keepalive 秒数（半周期探测） | `session.keepalive`                      | 120          | 5 / 90          |
| 单次网络操作超时             | `network.timeout_ms`                     | 10000        | 5000            |
| 重连固定间隔                 | `network.reconnect_timeout_ms`           | 10000        | 2000            |
| 重发周期                     | `session.message_retransmit_timeout`     | 1000         | 默认            |
| 收发缓冲                     | `buffer.size` / `buffer.out_size`        | 1024 / =size | 2048 / 2048     |
| outbox 上限字节              | `outbox.limit`                           | 0（不限）    | 不限            |
| poll 读粒度                  | Kconfig `MQTT_POLL_READ_TIMEOUT_MS`      | 1000         | 默认            |
| 过期清仓                     | Kconfig `MQTT_OUTBOX_EXPIRED_TIMEOUT_MS` | 30000        | 90000(实验放宽) |
| 任务栈/优先级                | `task.stack_size/priority`               | 6144 / 5     | 默认            |

这份表本身就是"什么时候该动哪个旋钮"的速查卡——例如想缩短判死时延只调 `keepalive` 是不够的：broker 还会按 1.5×keepalive 强制踢客户端，两侧语义要对齐。

---

## 21.3 QoS 机制的传输层落地

### 1. publish() 行为矩阵：调用语境决定一切

结合头文件注释与 `esp_mqtt_client_publish()` 实现，返回值语义全景：

| 场景            | QoS0                                                                             | QoS1/2                                     |
| --------------- | -------------------------------------------------------------------------------- | ------------------------------------------ |
| 已连接          | 用户任务同步写，成功返 **0**                                                     | 同步写 + 置 TRANSMITTED，返 packet id (>0) |
| 未连接          | 返 **-1**，数据丢弃（除非 Kconfig `MQTT_SKIP_PUBLISH_IF_DISCONNECTED` 提前拦截） | 入箱 QUEUED，返 packet id；后续靠重发路径  |
| outbox.limit 满 | 不受限                                                                           | 返 **-2**                                  |

> [!warning] "返 0 也是成功"
> 我们第一版实验代码按 `rc > 0` 判成功，把 200 条 QoS0 全判成了失败——QoS0 没有 packet id，**0 就是它的成功**。这一行值一章学费。

来源骨架（删注释后）展示三条返回路径的分歧点：

```c
int esp_mqtt_client_publish(client, topic, data, len, qos, retain)
{
    /* [rc=-2] outbox.limit>0 且 qos>0 且 (len + 已积压字节) 超限 */
    if (client->config->outbox_limit > 0 && qos > 0)
        if (len + outbox_get_size(client->outbox) > client->config->outbox_limit)
            return -2;

    int pending_msg_id = mqtt_client_enqueue_publish(...);   /* qos>0 才入箱 */

    /* [ret=id 或 -1] 未连接：qos>0 靠箱等回连；qos0 无处安放 */
    if (client->state != MQTT_STATE_CONNECTED)
        goto cannot_publish;                                 /* qos0 记 "Losing qos0 data" 日志 */

    while (sending) {                                        /* 同步写（含分片循环） */
        if (esp_mqtt_write(client) != ESP_OK)
            { esp_mqtt_abort_connection(client); ret = -1; goto cannot_publish; }
        ...
    }
    return pending_msg_id;      /* [qos0 恒为 0，qos1/2 为 packet id] */
}
```

同段源码顺带解释了弱网 qos0 写失败时为何会看到断连：写不动的兜底动作就是 `abort_connection()`——发布失败与连接终结在这个 API 里是绑定的。

### 2. QoS1 的定时与存储代价

发送后的 box 项每条携带完整线上字节。本章 C 阶段让 1024B payload 在离线状态下尽可能快地入箱，得到一组干净的单价数据：

```text
[HEAP] freeze-armed             free=258280 largest=131072
[OUTBOX] n= 50 wire= 52400B free=201788 largest=110592
[OUTBOX] n=100 wire=104800B free=144988 largest=110592
[OUTBOX] n=150 wire=157200B free= 87864 largest= 86016
[OUTBOX] n=200 wire=209600B free= 31064 largest= 30720
APP_OUTBOX_ACC_DONE n=227 span=17ms wire_bytes=237896 full_hits=1 heap_drop=258196B bytes_per_msg~1048.0
APP_STAGE_C_END free_heap=372
```

**单价 ≈ 1048 B/条**（1024 载荷 + 固定头/topic/结点头/malloc 开销），17ms 吃掉 258KB，第 200 条时堆上最大连续块只剩 30KB；另一轮跑到 `free_heap=372`——离线缓冲的真实内存价格就是"离线时长 × 码率 × 1048/1024"。写入端还是无限速的：积压速度取决于应用而**不是**网络。

连接级重发定时在另一维度：`message_retransmit_timeout` 默认 1000ms，任务是每个循环检查一次，凡 `TRANSMITTED` 超龄就取最老的一条带 DUP 位重写：

```c
/* MQTT_STATE_CONNECTED 分支的重发段 */
item = outbox_dequeue(client->outbox, QUEUED, NULL);
if (item) {
    if (mqtt_resend_queued(client, item) == ESP_OK) { ... /* 置 TRANSMITTED 或删除 */ }
} else if (has_timed_out(last_retransmit, client->config->message_retransmit_timeout)) {
    last_retransmit = platform_tick_get_ms();
    item = outbox_dequeue(client->outbox, TRANSMITTED, &msg_tick);
    if (item && (last_retransmit - msg_tick > message_retransmit_timeout))
        mqtt_resend_queued(client, item);        /* 带上 DUP 位整体重写 */
    item = outbox_dequeue(client->outbox, ACKNOWLEDGED, &msg_tick);
    if (item && (...))  mqtt_resend_pubrel(client, item);   /* QoS2 的后半程同样兜底 */
}
```

弱网下 RTT 被丢帧拖过 1 秒时，这条路径开始制造合法 DUP——注意它每次只补发**最老的一条**，深积压场景的追账速度天然受限于循环节拍。

### 3. QoS2 四步流程的实测可行性

四步握手与 esp-mqtt 内部状态的对应关系画出来一目了然：

```text
 发布端(esp-mqtt)                    broker(mosquitto)
 ─────────────────                  ─────────────────
 PUBLISH(qos2,id=N) ─────────────▶ 注册 msg_id=N，回 PUBREC
      [outbox: TRANSMITTED → ACKNOWLEDGED]
 ◀────────────── PUBREC
 PUBREL(id=N) ──────────────────▶ 转发完成待确认，回 PUBCOMP
      [mqtt_resend_pubrel() 兜底：ACKNOWLEDGED 超 1s 即重发]
 ◀────────────── PUBCOMP
 删除箱中项，MQTT_EVENT_PUBLISHED
```

四步里前半程的状态机（PUBREC 处理、置 ACKNOWLEDGED）与后半程的 `mqtt_resend_pubrel()` 都在源码中各占一个明确分支；QEMU+mosquitto 组合下流程通畅，但 2.x mosquitto 对 QoS2 的额外成本（驻留状态+两轮确认）与 ESP32 场景极少见的精确一次需求，使它更像协议完备性符号——本章未对其单独施压，留作真机课题。

### 4. QoS0 的"尽力而为"在网络层丢包下的真实到达率

这正是本章标题问题的高潮：**链路层 20% 吞帧 + 健康 TCP** 的世界里，QoS0 的丢失率是 **0**。第十二轮权威数据（mosquitto 侧订阅 `#` 全量抓包，256B 编号载荷 ×200）：

| 相位                         | 注入                   | QoS0 缺失 | QoS0 秒级重复 | QoS1 缺失 | QoS1 秒级重复 |
| ---------------------------- | ---------------------- | --------- | ------------- | --------- | ------------- |
| B1 flapless（keepalive=90s） | 20% TX 丢帧            | **0**     | 0             | **0**     | 0             |
| B2 flappy（keepalive=5s）    | 20% TX 丢帧 + 断连风暴 | **0**     | 0             | **0**     | **35**        |

QoS0 与 QoS1 的差异不在"健康链路上丢不丢"，而在 B2 那种**断连风暴**里：QoS1 由 outbox 保证"最终至少一次"，代价是 35 条秒级重复副本（mosquitto 对同一 session 的重发不做去重抑制）加约 190 条分钟级迟到副本；而 QoS0 的同步写在断连瞬间直接失败/丢弃。另一个一枪毙命的观察：跑满注入的轮次里，disc_total（断连次数）flapless=7、flappy=13+——即便 keepalive=90s，纯 TX 丢帧也能经由重传超时击穿传输层，esp-mqtt 只能靠 outbox 兜底，这正是"QoS 语义买的是跨连接持久性"的证据。

---

## 21.4 keepalive 与半开检测

### 1. 判死公式就在源码里

```c
/* process_keepalive() */
const uint64_t keepalive_ms = keepalive * 1000;
if (wait_for_ping_resp) {
    if (has_timed_out(keepalive_tick, keepalive_ms)) {     /* 等回声超过 ka */
        ESP_LOGE(TAG, "No PING_RESP, disconnected");
        esp_mqtt_abort_connection(client);
    }
} else if (has_timed_out(keepalive_tick, keepalive_ms / 2)) {
    esp_mqtt_client_ping(client);                          /* 半周期发 PINGREQ */
    wait_for_ping_resp = true;
}
```

即"距上次任何活动 `ka/2` 发探测，发出后 `ka` 内无 PONG 即判死"，理论窗口 `[1.5ka, 2ka]`。注意 `keepalive_tick` 只在收到 PINGRESP 时刷新。

### 2. 三种死法的实测对照

SIGSTOP 冻结 mosquitto（内核仍替它 ACK TCP、但应用不再说话），三次独立运行测得 ARM→判死时延 **10311 / 7273 / 4170 ms**（keepalive=5s）——全部落在理论窗内的不同相位：冻结撞上探测周期的位置不同，剩余等待就不同。对照两种立即死法：

| 死法               | 现象                    | 客户端感知路径                                         | 时延量级     |
| ------------------ | ----------------------- | ------------------------------------------------------ | ------------ |
| SIGTERM 进程退出   | 内核代发 FIN            | poll/read EOF → `EV ERROR sock_errno=0` → DISCONNECTED | 亚秒         |
| SIGSTOP 应用冻结   | 内核代答 TCP，应用沉默  | 上述公式走完才判死                                     | [1.5ka, 2ka] |
| 端口无人监听时重连 | SYN 得到 RST/ECONNRESET | connect 失败，EV ERROR `sock_errno=104`                | 逐次尝试即刻 |

第三种的实战意义：**RST 不是死亡证据而是"对端确实不存在"的证据**，它与 FIN 都比无声冻结友好得多——这与 [[ch11-tcp-state-machine|第十一章]] 的半开连接讨论严丝合缝：半开的可怕恰恰在于两端都没错，只是对面没了。

---

## 21.5 Vanilla lwIP 与 ESP-IDF lwIP 对照

| 维度                | Vanilla lwIP 2.2.0-dev                                                     | ESP-IDF v6 实际用法                                                                  |
| ------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 协议栈内置 MQTT app | **有**：`src/apps/mqtt/mqtt.c`（1480 行 raw-API 客户端，`LWIP_MQTT` 门控） | 存在于 vendored 源码树，但 `LWIP_MQTT` 保持 0、无 Kconfig 暴露——**编译期死码**       |
| 生产 MQTT 客户端    | 无官方推荐上层件                                                           | 托管组件 `espressif/mqtt ^1.0.0`（下载进工程 `managed_components/espressif__mqtt/`） |
| 并发模型            | 回调塞进 tcpip_thread 语境（raw API 单缓冲）                               | 独立 FreeRTOS mqtt 任务 + API 递归锁，publish 可从任意任务发起                       |
| 可靠性设施          | 无 outbox（单 in-flight pending 消息）                                     | STAILQ outbox、重发定时器、过期清理、MQTT5                                           |
| 典型 API 形状       | `mqtt_client_new()` + `mqtt_set_callback()`，事件进回调                    | `esp_mqtt_client_init/start()` + 事件分发器（结构体事件，经队列派发）                |
| 传输抽象            | 直挂 netcon/pcb                                                            | `tcp_transport` 组件层，`mqtt://mqtts://ws://wss://` 同构切换                        |
| TLS 叠加            | altcp_tls 手工接线                                                         | scheme 换 `mqtts://` 即启用 esp-tls → mbedtls 路径（证书校验、ALPN 字段一应俱全）    |

两行 API 对照足以感受气质差异：上游是"你给我回调指针，我在 tcpip 线程里打扰你"；IDF 版是"你在自己的任务里发指令，我把结果当事件递回来"。前者省一个任务与一次数据拷贝，后者换来了多任务安全、可扩展的传输栈与本章主角 outbox——在idf这样"每个外设都有任务"的世界里这是多数派选择。

一句话：**Vanilla 给了一根细骨头，IDF 换成了整套器官移植**——代价是整个 client 跑在 tcpip_thread 之外的任务里，所有对状态的修改都要通过那把 API 锁回到 mqtt 任务序列化执行（系列暗线 A 的又一次变奏）。

> [!tip] ch22 的伏笔
> 本章构建日志里 mbedtls 的目标文件赫然在列——那是 `MQTT_TRANSPORT_SSL=y` 经由 tcp_transport→esp-tls 拖进链接的，即使我们只用明文 `mqtt://`。下一章 [[ch22-tls-esp-tls-mbedtls|第二十二章]] 就拆这条"mqtts 到底多贵"的链路。

---

## 21.6 实验：QEMU guest × 宿主机 mosquitto

### 0. 工程与网络事实

工程位于 `practice/lwip-ch21-mqtt/`，沿 [[ch3-qemu-network-lab|第三章]] openeth bring-up 模板，main 组件 manifest 增加 `espressif/mqtt: "^1.0.0"`。关键事实：SLIRP 下 guest 访问 `10.0.2.2:<port>` 落到宿主机 loopback 同端口，因此固件直连 `mqtt://10.0.2.2:1883` 即达宿主机 mosquitto，**全程不需要 hostfwd**。

```bash
# 环境：ESP-IDF v6.0.2 / qemu-system-xtensa(esp_develop_9.2.2_20250817) / mosquitto 2.0.22
cd practice/lwip-ch21-mqtt
idf.py set-target esp32          # sdkconfig.defaults 含 CONFIG_ETH_USE_OPENETH=y
idf.py build
idf.py qemu monitor < /dev/null || true   # 生成 build/qemu_flash.bin + qemu_efuse.bin
/usr/sbin/mosquitto -c scripts/mosquitto_lab.conf -v &      # 仅监听 127.0.0.1
python3 scripts/mqtt_bridge.py --jsonl run/bridge.jsonl &   # 订阅 '#'@qos1 的全量抓包桥
bash scripts/run_lab.sh                                     # 编排全流程（见下）
```

固件单次上电顺序执行四个阶段，宿主机脚本只负责两个动作：看到 `APP_PHASE_FREEZE_ARMED` 就 `kill -STOP` mosquitto、14s 后 `kill -CONT`；看到 `APP_PHASE_HARDKILL_ARMED` 就 `kill -TERM`、6s 后重启。故障注入沿用系列手法：拿到 IP 后经 `tcpip_callback` 把 `netif->linkoutput` 换成包装函数，`tot_len>=60` 的出向帧按 20% 概率吞掉并谎报成功（ARP 等 42B 小帧豁免）。

### 0.5 抓包桥与判重方法

mosquitto 只是转发器，要给"到达数/重复数"下结论必须有 broker 侧的独立证人。`scripts/mqtt_bridge.py`（纯 stdlib 手写 MQTT 3.1.1）以 QoS1 订阅 `#`，把收到的每条 PUBLISH 落一行 JSONL：

```json
{
  "ts_ns": 1787780613,
  "topic": "ch21/offline/qos1",
  "plen": 280,
  "seq": 17,
  "tag": "offline",
  "qos": 0,
  "dup": 0
}
```

三个方法学要点：载荷内嵌编号 `i=<seq>` 与阶段标签 `<tag>` 用于**按 (topic, tag) 分组归位**——两轮相位会复用同一 seq 空间，直接全局去重会把"跨相位的合法副本"误判成重复；桥对收到的 QoS1 立即回 PUBACK，排除因确认迟滞诱发的 broker 重发；订阅端看到的 `dup` 位来自 mosquitto 转发报文头，可作为辅助证据但不作判重主依据（转发会重建头部）。broker 死亡期间桥自动重连续订（退避 0.8s 起），重连事件全部留痕于其 stdout。

mosquitto 侧同时开 `-v` 记录每一条 CONNECT/CONNACK/SUBSCRIBE/PINGREQ——后文 keepalive 观察与"clientId 接管风暴"排坑都从这里取证：

```text
1787778603: Received PINGREQ from ESP32_000000
1787778603: Sending PINGRESP to ESP32_000000
```

### 1. 基线：RTT 与突发吞吐

方法：guest 发布 `ch21/rtt/req`，宿主机桥原样回发 `ch21/rtt/rsp`，guest 用自己的 `esp_timer` 计往返（同一时钟域，无跨机对钟误差），每种 QoS 25 轮；吞吐为 1KB×200 条背靠背。

```text
T+2223ms [RTT] qos0 ok=25 fail=0 min=6394us p50=41017us p95=42389us max=44468us avg=39484us
T+3326ms [RTT] qos1 ok=25 fail=0 min=42811us p50=43826us p95=46670us max=52477us avg=44043us
T+3402ms [BURST] qos0 sent=200 pub_err=0 acked=0 span=0.076s -> 2642 msg/s (21641.0 kbit/s payload)
T+4486ms [BURST] qos1 sent=200 pub_err=0 acked=200 span=0.292s -> 686 msg/s (5617.6 kbit/s payload)
```

解读：p50≈41ms 而 min 只有几 ms——下限是 SLIRP 往返（~3ms），主体却是 mqtt 任务 1s 粒度 poll 的量化台阶；QoS1 比 QoS0 平均恰好多出一个 PUBACK 往返（+4.4ms）。突发吞吐的 QoS0 值只度量本地写入速率，QoS1 的 686 msg/s 则含完整确认闭环，两者共同指向同一事实：**这个虚拟链路的瓶颈是协议栈串行化而非带宽**。

### 2. 有损链路 QoS 对比：20% 帧损下的到达矩阵

同一 publisher 分别以 QoS0/QoS1 发 200 条编号消息（`i=<seq>;...` 可从抓包侧还原编号），broker 侧桥记录每一次到达。两侧联合统计（第十二轮权威数据）：

```text
topic                  tag           n  uniq missing dupC dupGapMed(ms)
ch21/lossy/qos0        lossyq0       389   200       0  189        117500
ch21/lossy/qos1        lossyq1       418   200       0  218        112500
ch21/offline/qos1      offline        30    30       -    0             40(ms burst)
```

结合 QEMU 日志的事件锚点拆相后（两相位各自独立计）：

| 指标                | B1 flapless     | B2 flappy                                    |
| ------------------- | --------------- | -------------------------------------------- |
| QoS0 编号唯一送达   | 200/200，缺失 0 | 200/200，缺失 0                              |
| QoS1 编号唯一送达   | 200/200，缺失 0 | 200/200，缺失 0                              |
| QoS1 秒级重复副本   | 0               | **35**（DUP 重发窗内）                       |
| 断连次数 disc_total | 7               | 13                                           |
| 该相位实际吞帧      | 58 帧           | 112 帧（占 TX 9.4%，20% 概率作用于瞬时窗口） |

解读浓缩成一句：**帧损打在链路上，TCP 一律兜住（缺失恒为零）；QoS 等级的差异只在"连接活不活得下去"的重型扰动里显形**——B2 的断连风暴里 QoS1 以 35 条重复副本买到零缺失，QoS0 则以若干次 `-1` 拒收换取同样的零缺失（门控重试后全部送达）。所谓"至少一次 vs 尽力而为"，本质是"是否肯付存储与重复的价"。

### 3. 故障注入·broker 死亡：FIN 时序与重连梯子

宿主机标记与 guest 日志交织（本轮 TERM 发生在 guest T+289.4s 左右）：

```text
I ... APP_STAGE_D_BEGIN (sanity ping)
I ... EV ERROR type=1 sock_errno=0 connect_rc=0        ← FIN 达：读侧干净 EOF
I ... EV DISCONNECTED (total=14)
I ... APP_OFFLINE_ENQUEUED n=30 outbox=8400B ack_pre=610   ← broker 已死窗口入队 30×QoS1
I ... EV BEFORE_CONNECT                                 ← reconnect_timeout=2s 的第一次重试
I ... EV ERROR type=1 sock_errno=104 connect_rc=0       ← broker 未起：SYN 吃 RST => ECONNRESET
I ... EV DISCONNECTED (total=15)
I ... EV BEFORE_CONNECT
I ... EV CONNECTED session_present=0                    ← 3s 节拍上的第二次尝试命中重启
I ... APP_OFFLINE_DRAINED outbox=0B puback_delta=30 (期望 n)
```

这份 12 行就是"broker 死亡瞬间"的全部解剖：EOF(0)/重置(104) 两种错误码把"对端客气地走了"与"对端根本不在"区分得清清楚楚；离线 30 条恰 8400B（280B/条 wire 实测，与理论一致）；重启后回连踩着 2s 固定间隔在第 2 个节拍命中。

### 4. 无声掉线：SIGSTOP 与 keepalive 判死

三次独立运行的 ARM→判死时延：**10311 / 7273 / 4170 ms**（keepalive=5s）。源码公式给的理论窗 `[1.5ka, 2ka]=[7500,10000]ms` 加上 ARM 时刻落在探测周期内的随机相位，三个样本无一越界且分布合理。对应的 guest 日志只有孤零零一行区别于 RST/FIN 风格的错误：

```text
E (16342) mqtt_client: No PING_RESP, disconnected
```

期间 bridge 的 TCP 层仍然正常（内核代答）， Sniffer 侧看不到任何异常——**半开之恶正是在统计里隐形，在应用层姗姗来迟**。

### 5. outbox 积压：离线缓冲的真实内存价格

见 QoS1 存储代价一段引用的五连 `[OUTBOX]` 快照：曲线斜率严格线性（1048B/条），free 最低探至 372B（近耗尽！），配合 Kconfig `CONFIG_MQTT_REPORT_DELETED_MESSAGES=y` 还能在 90s（默认 30s）过期线被穿越时捕获成串的 `EV DELETED msg_id=` 事件——前几轮迭代里整批离线消息被过期清理"无声消失"、桥侧踪迹全无，靠的正是这些 DELETED 行才定位到的机制。这就是数据：**离线缓冲的价格 = 码率 × 断连时长 × ~1.02，外加一个看不见的 30 秒炸弹（默认）**。

### 6. 跨轮稳定性核对

QEMU 时序受宿主机负载扰动（系列既知 ±50%），关键指标的跨轮复现情况：

| 指标               | 第 9 轮          | 第 11 轮         | 第 12 轮（权威） |
| ------------------ | ---------------- | ---------------- | ---------------- |
| RTT qos0 p50 / avg | 41.06 / 39.54 ms | 41.08 / 39.63 ms | 41.02 / 39.48 ms |
| RTT qos1 p50 / avg | 43.83 / 44.50 ms | 44.06 / 44.32 ms | 43.83 / 44.04 ms |
| QoS1 突发确认吞吐  | 571 msg/s        | 588 msg/s        | 686 msg/s        |
| 冻结判死时延       | 7273 ms          | 4170 ms          | 10311 ms         |
| 积压单价 bytes/条  | ~1048            | ~1048            | ~1048            |
| B 相位唯一送达     | 200×2 全达       | 200×2 全达       | 200×2 全达       |

RTT 与积压单价近乎刻度级稳定（抖动 <1%），吞吐有 ±15% 漂移，判死时延在理论窗内随冻结相位自然散布。重复测量给出的不是"一个数"，而是"每个数的方差来源"。

### 7. 结果解读小结

1. 健康链路帧损 ≤20% 时，QoS 等级不改变丢失率（皆零）；它改变的是断连期的语义与代价。
2. esp-mqtt 的重连节拍与 poll 粒度共同塑造了用户可见的所有延迟台阶（41ms 的 RTT 中位数里一半以上是调度网格）。
3. 离线 publishing 是"把内存换在线率"的交易，汇率 1048B/条，且默认 30 秒后清仓。
4. 判重要在"事件与消息两个坐标系"同时做：event 时间戳定相位边界，payload 编号定消息身份——任何单维度都会被 seq 复用或迟到副本骗到。

> [!warning] 本章实验驱出的五个真坑（全部有日志实证）
>
> 1. **QoS0 成功返回 0**——拿 ">0 当成功" 会全军覆没；
> 2. **clientId 接管互踢风暴**：同 id 的两个客户端并存时，mosquitto 会"关闭旧连接、接受新连接"，若双方都在自动重连就陷入互踢死循环；诊断指纹是 broker 日志里每秒成串的 `Client ch21bridge already connected, closing old connection.` + `New client connected ... as ch21bridge`。解决办法朴素到无聊：**每个进程生成唯一 id**（我们最后用 `ch21bridge-<pid>`），并把重连退避从 50ms 放宽到 800ms；
> 3. **编排脚本不清旧日志**导致 marker 匹配到上一轮内容，故障动作提前 N 分钟误触发；
> 4. **SLIRP 残留连接**会让紧随其后的 connect() 立刻吃 `EINPROGRESS(119)`，需要重试循环兜住；
> 5. **离线积压默认 30s 过期清仓**（`OUTBOX_EXPIRED_TIMEOUT_MS`），长断连场景看似"消息最终丢了"，实为库的设计行为。

坑 #2 的现场长这样（同一秒内三次接管，这是互踢风暴的典型心电图）：

```text
1787778460: Client ch21bridge already connected, closing old connection.
1787778460: New client connected from 127.0.0.1:56932 as ch21bridge (p2, c1, k60).
1787778460: Sending CONNACK to ch21bridge (0, 0)
1787778460: Received SUBSCRIBE from ch21bridge
```

而坑 #5 被抓获的功劳属于 `MQTT_EVENT_DELETED`——打开上报后，90 秒过期线穿越瞬间刷出的整批 `EV DELETED msg_id=...` 就是积压内容的死亡名单，与我们从桥侧统计到的"零到达"严丝合缝地互相印证。

---

## 21.7 小结

- IDF v6 的 MQTT 客户端是托管组件 espressif/mqtt 1.1.0：单任务状态机（INIT/CONNECTED/WAIT_RECONNECT…）+ API 递归锁；上游 lwIP 自带的 raw-API mqtt app（`LWIP_MQTT` 门控）在 IDF 中从不启用。
- outbox 是理解 esp-mqtt 的钥匙：STAILQ 上的整包拷贝，QUEUED→TRANSMITTED→删除/ACKNOWLEDGED 两态三迁；QoS1/QoS2 的"断连存活期"与内存价格（实测 1048B/条）都由它承担；默认 30s 过期清理可能在不告知的情况下清仓（可用 Kconfig 改期并开 DELETED 上报）。
- publish() 的返回值语义按 (QoS, 是否连接) 分裂：QoS0 成功即 0、离线 -1 丢弃；QoS>0 离线入箱返 id、箱满 -2。
- 重连是固定间隔（默认 10s，`network.reconnect_timeout_ms`）的机械循环，无指数退避；`message_retransmit_timeout`(1s) 周期性带 DUP 补发，outflow 超 RTT 时制造合法重复。
- keepalive 判死窗口由源码定死为 [1.5ka, 2ka]，实测三样本 4.2/7.3/10.3s 全部落窗；FIN/RST/静默三种死法分别以 EOF、ECONNRESET、超时呈现在事件层。
- 弱网定性结论：帧损本身被 TCP 吸收（800 条编号消息零缺失），QoS 分级只在断连期兑现价值——重复与内存即是账单。
- 对照暗线收束：IDF 用"独立任务+锁+组件化传输层"替换 Vanilla 的"回调+单缓冲"，又一次把 tcpip_thread 的单线程世界外包给了 RTOS 多任务。

下一章进入安全层：`mqtts://` 背后 tcp_transport→esp-tls→mbedtls 的整条链路——握手要几个 RTT、多少堆、多少任务切换，以及证书验证失败时那一串 error code 分别是谁吐的。见 [[ch22-tls-esp-tls-mbedtls|第二十二章]]。
