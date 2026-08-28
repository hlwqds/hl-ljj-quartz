# ex08 mqtt-pubsub —— esp-mqtt 客户端模板

QEMU openeth 网络上的最小 MQTT 发布/订阅模板：树内 esp-mqtt 组件连接宿主机
mosquitto，订阅 `demo/topic` 收自回显与外部消息、周期发布 QoS1 计数消息、配置
LWT 遗嘱，并完整演示「杀 broker → DISCONNECTED → 离线积压 → 重启 broker → 自动
重连 → 重新订阅 → outbox 排空」全过程。复制改名即可作为新项目起点。

## 目的与演示点

| 演示点      | 内容                                                                     |
| ----------- | ------------------------------------------------------------------------ |
| 订阅回显    | 订阅 `demo/topic`（SUBSCRIBED 事件确认），自己发的计数消息经 broker 回环 |
| 周期发布    | 每 3s 一条 `ex08-counter=N` 消息（QoS1，等待 PUBACK）                    |
| 下行注入    | 宿主侧 `tools/demo_pub.sh` 发消息进 guest                                |
| LWT 遗嘱    | TCP 未发 DISCONNECT 即断开时，broker 代发遗嘱到 `demo/lwt`               |
| 断线重连    | DISCONNECTED 后按默认节奏自动重连；重连成功后在 CONNECTED 里重新订阅     |
| outbox 排空 | 离线窗口的 QoS1 消息入 outbox，重连后统一定向补投                        |

三类核心事件（CONNECTED / DATA / DISCONNECTED）全程留真实日志；另有机器可读行
（`$$$ READY` / `$$$ EVT ...`）便于 grep/CI 断言。

## 网络拓扑

```text
   宿主机                                       QEMU SLIRP                guest (ESP32, openeth)
┌──────────────────────────┐              ┌────────────────────┐      ┌─────────────────────────┐
│ mosquitto  :1883         │ ◄──TCP:1883─ │ guest→10.0.2.2 直落 │ ◄─── │ 10.0.2.15  esp-mqtt 客户端│
│ mosquitto_sub 观察者      │              │ loopback 同端口      │      │ mqtt://10.0.2.2:1883    │
│ tools/demo_pub.sh        │ ─publish──►  │ (用户态转发)         │ ───► │ sub: demo/topic         │
└──────────────────────────┘              └────────────────────┘      └─────────────────────────┘
                   DHCP: guest 得 10.0.2.15/24, gw 10.0.2.2

方向要点：guest 出连 10.0.2.2:1883 直接命中宿主 loopback 的 mosquitto，
因此本示例**无需 hostfwd**（套件端口表 ex08 号段 8270 仅保留备用）。
```

## 环境准备：mosquitto 安装与启动

宿主机需要 mosquitto 三件套（本机 Fedora 已装好）：

```bash
# Fedora
sudo dnf install mosquitto            # 含 broker 与 mosquitto_sub/mosquitto_pub
# Debian/Ubuntu 等价
sudo apt install mosquitto mosquitto-clients
```

用工程自带脚本管理 broker（配置在 `tools/mosquitto.conf`：监听
`0.0.0.0:1883`、允许匿名、不做持久化）：

```bash
cd practice/lwip-examples/ex08-mqtt-pubsub
tools/run_broker.sh start             # 启动（后台），日志 /tmp/ex08-mosquitto.log
tools/run_broker.sh status            # 查看 PID 与端口占用归属
tools/run_broker.sh stop              # 按 pidfile 精确停止（不用 pkill）
tools/run_broker.sh restart           # stop && start
```

手动等价命令（想自己敲的话）：

```bash
mosquitto -c tools/mosquitto.conf     # 前台起一个
```

> 脚本启动前会校验 1883 归属：被别的进程占着就拒绝并提示排查
> （并行实验互相踩端口的教训）。真正 LISTEN 到端口才算成功。

## 构建与离线依赖说明

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-examples/ex08-mqtt-pubsub
idf.py set-target esp32               # 仅首次
idf.py build
idf.py qemu monitor < /dev/null || true   # 生成 qemu_flash.bin/qemu_efuse.bin（monitor 无 TTY 失败可忽略）
ls build/qemu_flash.bin build/qemu_efuse.bin
# 若重复构建后镜像未更新，手动合并兜底：
# cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args
```

**离线构建**：ESP-IDF v6 树内的 `components/mqtt` 目录只剩 test_apps，
esp-mqtt 本体已迁出 IDF 主仓（官方示例走 component registry 在线拉取，本套件禁
止）。本工程把 **espressif/mqtt v1.1.0**（commit
`1a1e5788a5cf57a0f44a3c6c061407f6c9be1026`）vendor 进 `components/mqtt/`
（已剔除 test/docs/examples/在线解析清单），`main` 里
`PRIV_REQUIRES mqtt` 解析到工程本地组件。工程目录下没有
`managed_components/` 与 `dependencies.lock`，构建全程不访问网络。

## 运行

### 方式一：一键全流程演示

```bash
tools/demo_reconnect.sh               # 总预算默认 150s，一次跑完全部场景
```

脚本会自动：起 broker → 起 QEMU（写 run.log）→ 等连接/订阅确认 → 触发两条下行
消息 → SIGTERM 杀 broker → 等 DISCONNECTED → 重启 broker → 等第二次
CONNECTED/SUBSCRIBED 并断言重订阅成功 → SIGKILL QEMU 触发遗嘱 → 全程
`mosquitto_sub` 观察者记录 broker 视角报文。结束打印两端关键行。

### 方式二：手动分步

```bash
# 终端 1：broker
tools/run_broker.sh start

# 终端 2（可选）：broker 视角观察者，看所有 demo/# 报文
mosquitto_sub -h 127.0.0.1 -t 'demo/#' -v

# 终端 3：guest（前台 300s；退出码 124 = timeout 正常截停）
tools/run_qemu.sh 300
# 想后台就：tools/run_qemu.sh 300 &
# 结束按 PID 精确杀：kill <pgrep -f 'qemu-system-xtensa.*ex08-mqtt-pubsub' 得到的 PID>

# 任意时刻从宿主侧注入下行消息
tools/demo_pub.sh "hello from host"
```

固件就绪标志（`fw=` 时间戳务必与本次 `idf.py build` 时间对照，防止跑旧镜像）：

```text
$$$ READY role=mqtt-client uri=mqtt://10.0.2.2:1883 clientId=ex08-000000-us1164126 sub=demo/topic lwt=demo/lwt ka=10s pub_period=3s fw=Aug 27 2026 13:25:54
```

## 真实输出摘录

以下全部摘自本项目 `run.log`（2026-08-27 由 `tools/demo_reconnect.sh` 留存），
可 grep 关键字核对。

### ① 连接、订阅确认、周期计数消息（自回显）

```text
I (2646) ex08: GOT_IP: 10.0.2.15
I (2686) ex08: [MQTT] CONNECTED #1 session_present=0
I (2696) ex08: [MQTT] SUBSCRIBED msg_id=63684 (topic=demo/topic confirmed)
I (5686) ex08: [APP] PUBLISH seq=1 msg_id=57323 topic=demo/topic outbox=45B acked=0
I (5686) ex08: [MQTT] DATA #1 (self-echo) topic=demo/topic qos=1 len=29 data=ex08-counter=1 uptime_ms=4200
I (8686) ex08: [APP] PUBLISH seq=2 msg_id=32292 topic=demo/topic outbox=45B acked=1
I (8686) ex08: [MQTT] DATA #2 (self-echo) topic=demo/topic qos=1 len=29 data=ex08-counter=2 uptime_ms=7200
```

发布→PUBACK（`acked` 递增）→经 broker 回环回到自己的 DATA 事件，三步闭环。

### ② 宿主下行消息（demo_pub.sh 注入）

宿主侧执行 `tools/demo_pub.sh "hello-from-host @ 13:28:26"` 与第二条后，guest：

```text
I (9726) ex08: [MQTT] DATA #3 (external)  topic=demo/topic qos=1 len=26 data=hello-from-host @ 13:28:26
I (12736) ex08: [MQTT] DATA #5 (external)  topic=demo/topic qos=1 len=15 data=second downlink
```

同一主题上"自回显"与"外部消息"仅 payload 不同——发布/订阅解耦的直接体现。

### ③ 杀 broker：FIN 秒级感知 + 离线期 QoS1 入 outbox

SIGTERM 杀掉 mosquitto（TCP FIN 干净送达）后：

```text
W (17786) ex08: [MQTT] ERROR type=1 sock_errno=0 connect_rc=0
W (17786) ex08: [MQTT] DISCONNECTED #1 -> auto-reconnect in ~10s intervals
$$$ EVT DISCONNECTED n=1 outbox_bytes=0
I (20686) ex08: [APP] PUBLISH seq=6 msg_id=61918 topic=demo/topic outbox=46B acked=5
I (23686) ex08: [APP] PUBLISH seq=7 msg_id=45046 topic=demo/topic outbox=92B acked=5
I (26686) ex08: [APP] PUBLISH seq=8 msg_id=59960 topic=demo/topic outbox=138B acked=5
I (29686) ex08: [APP] PUBLISH seq=9 msg_id=42655 topic=demo/topic outbox=184B acked=5
I (32686) ex08: [APP] PUBLISH seq=10 msg_id=37194 topic=demo/topic outbox=231B acked=5
```

断连期间 `acked` 冻结在 5，而每条 ~31B 的消息让 outbox 以 ~46B/条爬升
（46/92/138/184/231）——离线发布的去向一目了然。另一轮实验还抓到过死窗中期
的失败重试签名（`ERROR type=1 sock_errno=104`＝ECONNRESET）。

### ④ 重启 broker：重连成功 + 重新订阅 + 积压定向排空

```text
I (32806) ex08: [MQTT] CONNECTED #2 session_present=0
I (32806) ex08: [MQTT] SUBSCRIBED msg_id=43884 (topic=demo/topic confirmed)
I (32806) ex08: [MQTT] DATA #8 (self-echo) topic=demo/topic qos=1 len=30 data=ex08-counter=6 uptime_ms=19200
I (32816) ex08: [MQTT] DATA #9 (self-echo) topic=demo/topic qos=1 len=30 data=ex08-counter=7 uptime_ms=22200
I (32826) ex08: [MQTT] DATA #12 (self-echo) topic=demo/topic qos=1 len=31 data=ex08-counter=10 uptime_ms=31200
I (35686) ex08: [APP] PUBLISH seq=11 msg_id=17005 topic=demo/topic outbox=47B acked=10
```

重连成功的同毫秒内重新订阅拿到 SUBSCRIBED 确认；counter=6..10 这五条是断连窗
入队消息的补投（时间戳 19200~31200 属断线期）；随后稳态恢复：每条新消息
`outbox=47B`（即发即清）、`acked` 追平序号。

### ⑤ LWT 遗嘱（broker 视角观察者）

`mosquitto_sub -t 'demo/#' -v` 全程驻留，两次捕获同一份遗嘱文本：

```text
demo/lwt client ex08-000000-us1164126 left unexpectedly (no DISCONNECT)
demo/topic ex08-counter=11 uptime_ms=34200
...
demo/lwt client ex08-000000-us1164126 left unexpectedly (no DISCONNECT)
```

第一条出现在 **broker 自己被 SIGTERM** 时（broker 关闭连接，客户端没机会发
DISCONNECT，协议规定此时代发遗嘱）；第二条是我们 SIGKILL QEMU（进程蒸发、内核
关 socket、同样没有 DISCONNECT 报文）。两种非正常断开都正确触发了遗嘱——这正
是 LWT 的设计意图，也是验证它的标准手法。

## 机制注解（模板选型的依据）

- **clientId 必须唯一**：MQTT 同 id 两连接互踢（ch21 Batch 6 实测风暴）。本环境
  QEMU 的 eFuse 基础 MAC 恒为全 0（见 READY 行 `clientId=ex08-000000-us…`），
  只拼 MAC 的写法在并行第二台虚拟机上必撞，所以模板用
  `MAC 后缀 + 开机微秒数` 双保险（`main/main.c` app_main 内有注释）。
- **重连节奏**：不设 `network.reconnect_timeout_ms` 时走 esp-mqtt 默认固定间隔
  `MQTT_RECON_DEFAULT_MS = 10*1000`（`components/mqtt/lib/include/mqtt_config.h:24`）；
  本次断连 t=17.786s、复联 t=32.806s，中间恰有一个 10s 级重试格点。若对端是
  SIGSTOP 式无声死亡，则由 keepalive 判死，时延符合 ch21 源码公式
  `[1.5×ka, 2×ka]`（本模板 ka=10s ⇒ 15~20s）。
- **干净断开不触发遗嘱**：调用 `esp_mqtt_client_disconnect()` 会先发 DISCONNECT
  报文，遗嘱不会发布；只有 TCP 层"没有告别的死亡"才触发。给 vs-拔电/崩溃复位
  场景做心跳兜底时别搞混。
- **clean session 与重订阅**：esp-mqtt 默认 clean session=true，broker 重连后
  不会替你恢复订阅，模板把 `esp_mqtt_client_subscribe()` 放进了
  MQTT_EVENT_CONNECTED 分支——每次连接成功必然重新订阅，这是正确姿势而非冗余。

## 已知边界与排障

- 启动初期固定刷 3 条 MAC filter ioctl 错误
  （`add mac address to filter not supported` 等）属 openeth 白名单噪音；
  虚拟网卡 MAC 固定 `52:54:00:12:34:56`，与 eFuse 基础 MAC 是两回事。
- 1883 被其他进程占位时 `tools/run_broker.sh start` 会拒绝并列出占用者；
  千万别顺手 pkill——并行作者的 QEMU/broker 可能同屏在跑，按 PID 精确操作。
- 本示例无 hostfwd，主机无法反向"拨入"guest：所有下行必须走 broker 中转
  （这正是 MQTT 的用法）。连通性探针用 `ss -ltn sport = :1883` 与
  `tools/demo_pub.sh`，不要 ping 10.0.2.15（SLIRP 不回 guest 方向外的 ICMP）。
- `clientId` 只保证单实例唯一性；如果你复制本工程起两个 QEMU 又手动改死
  clientId，就会复现互踢——留着代码里的自动后缀即可。
- 改 `sdkconfig.defaults` 后必须删 `sdkconfig` 重新生成才生效。
- 嵌入两条以上 >256B 的长消息不需要放大 buffer；要发接近 KB 级再考虑
  `cfg.buffer.size/out_size`（当前默认 1024B 够用且本次全程无 DELETED 事件）。

## 文件清单

| 文件                      | 说明                                                     |
| ------------------------- | -------------------------------------------------------- |
| `main/main.c`             | openeth 标准骨架 + mqtt 事件处理 + READY/EVT 机器可读行  |
| `components/mqtt/`        | espressif/mqtt v1.1.0 的离线 vendor 副本（树内组件形态） |
| `tools/run_qemu.sh`       | QEMU 启动器（去 efuse 行形态，tee run.log，无 hostfwd）  |
| `tools/demo_reconnect.sh` | 断线重连全流程编排（产出本文全部证据行）                 |
| `tools/run_broker.sh`     | mosquitto start/stop/status/restart（带端口归属检查）    |
| `tools/mosquitto.conf`    | 允许匿名、监听 1883、关闭持久化                          |
| `tools/demo_pub.sh`       | 向 demo/topic 发布一条 QoS1 下行消息                     |
| `run.log`                 | 真实运行留存（对应上文摘录）                             |

> 参考实现：`practice/lwip-ch21-mqtt/main/lab_main.c`（章节实验版，弱网故障
> 注入语境）与官方 `examples/protocols/mqtt`（结构借鉴；其连接层依赖
> protocol_examples_common 与 registry 在线拉取，本模板均已替换为离线形态）。
