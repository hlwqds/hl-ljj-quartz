# RTOS+lwIP 示例工程套件 · 构建规格 v1（EXAMPLES SPEC）

本文件是 `practice/lwip-examples/` 套件全部示例的实现契约。实现者动手前必读，配套调研见
`research/upstream-survey.md` 与 `research/assets-and-constraints.md`。

## 1. 定位与目录约定

- **定位**：独立于《lwIP 深度解析》章节实验的**模板级示例**——每个示例自成一个干净工程，
  README 即文档，复制改名即可作为新项目起点。区别于章节实验的"探针/取证"风格，这里
  追求整洁、克制、可维护。
- 目录：`practice/lwip-examples/exNN-slug/`（NN 两位）。
- 每工程必备：`main/main.c`、`main/CMakeLists.txt`、根 `CMakeLists.txt`、
  `sdkconfig.defaults`、`README.md`、`run.log`（真实运行留存）；需要主机端配合的附
  `tools/`。
- 总索引 README 由编排者在集成阶段生成，示例作者不写。

## 2. 环境硬事实（引用，不重复论证）

环境与陷阱速查一律以 `../lwip-labs/CONVENTIONS.md` 为准（第 1 节环境事实、第 3 节运行流程
及 efuse warning、第 6 节八批实测）。特别注意：

- QEMU runner **去掉 efuse `-global nvram.esp32.efuse` 行**（Batch 4 实测偶发 NIC 不创建）。
- 初始化次序：`esp_netif_init()` 是第一句网络调用；socket/netconn 创建必须在它之后。
- 一切 raw 回调/sys_timeout 跑在 tcpip_thread 内；回调里禁止阻塞 API；跨线程操作用
  `tcpip_callback()`。守卫构建可用 `CONFIG_LWIP_CHECK_THREAD_SAFETY=y` 验证。
- SLIRP 边界：guest→10.0.2.2 TCP 落宿主机 loopback 同端口；DNS=10.0.2.3 查宿主
  /etc/hosts；主机→guest 只有 hostfwd 一条路；主机→guest ICMP 不通（ping 只能 guest 发起）；
  外环吞吐天花板 ~120 Mbit。
- **禁止 managed component 在线拉取**：依赖只允许 `${IDF_PATH}` 内组件或本仓 path 引用。
  esp-mqtt 用树内 `mqtt` 组件（`PRIV_REQUIRES mqtt`），不要学官方示例走 registry。

## 3. 标准骨架（强制）

app_main 序列按 `research/assets-and-constraints.md` 提炼的 15 步执行，要点：

1. `esp_netif_init()` → `esp_event_loop_create_default()` → 创建 DHCP 完成信号量；
2. （可选）控制平面任务先行：pin core1、prio 22（ch19/ch20 教训：控制命令口要活在
   受害者带宽之外）；
3. openeth MAC + `esp_eth_phy_new_generic()`（`reset_gpio_num=-1`）+
   `esp_eth_driver_install()` → 注册 `ETH_EVENT` 与 `IP_EVENT_ETH_GOT_IP` →
   glue + attach + start → 等 GOT_IP（15s 超时）→ 打印机器可读 READY 行再进应用逻辑。
4. root CMakeLists 允许 `MINIMAL_BUILD ON` 形态；main 的 `PRIV_REQUIRES` 按需：
   `esp_eth esp_netif esp_event lwip`（+`esp_timer`/`nvs_flash`/`esp_http_server`/`mqtt`…）。
5. `sdkconfig.defaults` 最小集只有 `CONFIG_ETH_USE_OPENETH=y`；观测类开关（LWIP_STATS、
   FREERTOS_USE_TRACE_FACILITY）仅在示例需要时叠加并注明。

构建-运行标准命令（去 efuse 行形态），日志落 `run.log`：

```bash
. ~/esp/esp-idf/export.sh && idf.py set-target esp32 && idf.py build
idf.py qemu monitor < /dev/null || true   # 只为生成 qemu_flash.bin/qemu_efuse.bin
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 30 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth[,hostfwd=...] -nographic -no-reboot 2>&1 | tee run.log
```

## 4. 端口分配表（专用号段 8200–8299，禁止越界）

每示例一个十位块；子槽位约定 `+0` 主服务 / `+1` 控制或辅助 / 其余保留。
hostfwd 两端同号（如 `tcp::8210-:8210`）。legacy 黑名单：8006、8108、8517、9014、1883。

| 示例                     | 号段      | hostfwd                                      |
| ------------------------ | --------- | -------------------------------------------- |
| ex01 ethernet-dhcp       | 无        | 无需联网服务端口                             |
| ex02 tcp-echo-server     | 8210/8211 | tcp::8210-:8210                              |
| ex03 tcp-echo-client     | 8220      | guest 出连宿主 8220（无需 hostfwd）          |
| ex04 udp-echo-bidir      | 8230      | udp::8230-:8230                              |
| ex05 http-server         | 8240      | tcp::8240-:80                                |
| ex06 http-downloader     | 8250      | guest 出连宿主 8250                          |
| ex07 sntp-clock          | 8260      | guest 出连宿主 UDP 8260→123 映射实验         |
| ex08 mqtt-pubsub         | 8270      | guest 直连 10.0.2.2:1883                     |
| ex09 tls-client          | 8280      | guest 出连宿主 8280 或回环自连               |
| ex10 ping-monitor        | 无        | ICMP 仅 guest 发起                           |
| ex11 throughput-bench    | 8290/8291 | 双向模式各一                                 |
| ex12 net-stats-dashboard | 无        | 纯观测                                       |
| ex13 tcp-hostlink        | 8300/8301 | hostfwd tcp::8300-:8300；出连宿主 8301       |
| ex14 perf-gym-tcp        | 8310/8311 | 场景自驱动为主；hostfwd tcp::8310-:8310 按需 |
| ex15 perf-gym-rtos       | 8320      | 自环负载为主                                 |
| ex16 zero-copy-cases     | 8330      | hostfwd tcp::8330-:8330；出连宿主 8331       |

## 5. 示例规格

### ex01 ethernet-dhcp —— 以太网起播基线

最小骨架本体：openeth bring-up 全程事件打印（START/CONNECTED/GOT_IP 各阶段时间戳）、
READY 行、循环打印 IP 统计。验收：run.log 含完整事件序列与 10.0.2.15 获取。

### ex02 tcp-echo-server —— TCP 服务端模板

单任务 accept 循环模型（注意 ch23 结论：串行 accept 必须先 recv 后回写且及时回收，
backlog 显式设足）。hostfwd 8210；README 给 `nc localhost 8210` 验证步骤。加分：并发
第二连接的行为说明（排队语义）。

### ex03 tcp-echo-client —— TCP 客户端模板

guest 主动连宿主 8220 的 python 监听器（tools/listener.py 提供，回显模式）。演示
connect/read/write/close 全周期 + SO_RCVTIMEO 超时处理 + 对端不存在时的 errno 分支
（ch16 错误账本）。验收：双向数据 digest 校验一致的运行证据。

### ex04 udp-echo-bidir —— UDP 收发模板

hostfwd udp 8230 入向 + guest 出向 echo 双路径；展示 bind 固定本地端口、sendto/recvfrom、
以及 netconn 或 socket 单层即可（保持简单）。验收：入向与出向各自有真实往返输出。

### ex05 http-server —— HTTP 服务模板

esp_http_server：GET /hello 文本、GET /info 返回 JSON（IP/up time/heap）、404 默认页；
keep-alive 说明引用 recv_wait_timeout 语义。curl 验证 + 简单 50 请求小压测脚本留 tools/。

### ex06 http-downloader —— HTTP 客户端下载模板

裸 socket GET 宿主 python http.server（tools/serve.py，动态生成 ~5MB 内容）的分块下载：
Content-Length 解析、进度打印（每 512KB）、digest 校验。演示"嵌入式 HTTP 客户端的正确姿势"
（重定向不做，超时必须有）。

### ex07 sntp-clock —— SNTP 对时模板【含一次裁决实验】

主线：esp_netif_sntp（或 lwip sntp API 二选一，说明取舍）指向 10.0.2.2；宿主侧若
UDP→loopback 转发不通则启用 research/upstream-survey.md 备选 B（/etc/hosts 钉域名 +
宿主 NTP 服务）。无论成败把"SLIRP UDP 转发裁决"写成 README 小节。验收：打印对时前后
的系统时钟差（sys_now 10ms 网格注意）。

### ex08 mqtt-pubsub —— MQTT 客户端模板

树内 mqtt 组件 + 宿主 mosquitto（编排文档给启动命令）。demo：订阅 demo/topic 回显、
周期 publish 计数、LWT 设置。URI `mqtt://10.0.2.2:1883`。clientId 必须唯一（互踢教训）。

### ex09 tls-client —— TLS 客户端模板（诚实版）

首选宿主 openssl s_server（tools/run_sserver.sh 自签证书一次性生成）；**ch22 已知外环
悬案**（TLS 建立后首条应用记录可能卡死）——示例代码必须内置超时逃生，README 如实记录
该现象与 guest 回环替代路径（127.0.0.1 自连 esp-tls server 变体可选做）。内存账本快照
（握手前后 heap 三件套）是加分项。

### ex10 ping-monitor —— ping 监控模板

esp_ping 周期会话（目标 10.0.2.2）：成功/超时统计、丢包率、失败告警回调打印；复现 ch3
经验（单会话稳定，避免同时刻双会话）。README 注明主机→guest ICMP 不可用的边界。

### ex11 throughput-bench —— 吞吐基准模板

iperf-lite：两模式（TX 泵到宿主接收器 / RX 从宿主灌入），Kconfig 暴露 TCP_SND_BUF/WND
两个旋钮（说明改后必须删 sdkconfig 重生成——Batch 1 教训），双计时口径 + digest 校验
（ch6 方法学），声明 SLIRP ~120 Mbit 天花板与"窗口×RX 环深不等式"提示（ch24）。

### ex12 net-stats-dashboard —— 观测台模板

30s 周期控制台仪表盘：lwip_stats 协议计数增量（snap-diff 口径）、heap 三件套、任务表
（TRACE_FACILITY 开启）、uptime。是全系列的"健康检查"收口模板，README 解释每个数字。

### ex13 tcp-hostlink —— QEMU 与宿主双向 TCP 交互模板【入向命令 + 出向心跳并发】

目标：一个固件内**同时**演示两个发起方向的 TCP 应用，证伪"只能单向"的误解。

1. **入向服务面**：guest 监听 8300（hostfwd `tcp::8300-:8300`），实现一行式命令协议
   （`PING`→`PONG`、`ECHO <data>`→原样返回、`STATS`→lwip_stats+heap 单行 JSON、
   `TIME`→uptime、未知命令→`ERR unknown`）。应用层必须逐连接串行处理且先收后回
   （ch23/ch15 纪律），backlog 显式设足。
2. **出向心跳面**：周期（默认 5s）向宿主 8301 发起独立 TCP 会话，上报一行 JSON 心跳
   （ip/uptime/heap/已服务连接数），收到宿主 `ACK` 即断开。两方向并发运行互不阻塞，
   run.log 需体现"出向心跳成功发生期间入向命令仍被即时响应"的时间线证据。
3. 宿主工具：`tools/hostlink.py`（交互式命令客户端）、`tools/reverse_heartbeat.py`
   （8301 心跳接收器，校验 JSON 并回 ACK）。
4. 健壮性：命令超长截断保护、客户端突然断开不崩溃、心跳连不上不阻塞服务面。
5. README 中文全套：拓扑图标注双方向箭头、两种角色的复现命令、真实输出摘录、
   "SLIRP 入向只有 hostfwd 一条路"边界说明。

### ex14 perf-gym-tcp —— TCP 配置错误健身房【每场景：症状→诊断→根因→修复→前后数据】

一个固件内建**可切换的错误配置场景**（`CONFIG_GYM_SCENARIO=n`，0=健康基线），
跑同一套自环+回声基准负载，让使用者亲手经历"性能坏了→定位→修复→优化"的闭环：

1. **场景 1 窗口过小**：SND_BUF/WND 压到 2×MSS → 吞吐坍缩。诊断：双端计数差 +
   sndbuf 水位；修复：按 BDP 重算窗口并重测。
2. **场景 2 大窗小环黑洞**：WND=28800 但 openeth RX 环保持默认 4 → 吞吐黑洞
   （Batch 5「窗口×RX 环深不等式」）。诊断：RX 丢帧告警行 + 帧深统计；修复：环深 ≥16。
3. **场景 3 发送泵漏挂 tcp_sent**（代码级错误，复刻 ch6 真实 bug）：连接正常建立但
   吞吐涓流。诊断：acked 计数冻结 + tcp_sndbuf 钉死观察。
4. **场景 4 并发 PCB 耗尽**：MAX_ACTIVE_TCP=2 时并发第三连接静默无响应（ch5/ch10 现象）。
   诊断：SYN 发了没 ACK + `tcp.memerr` 计数爬升。

硬要求：每个场景必须给「坏配置实测数字」和「修复后实测数字」成对呈现（同开机配对、
交错轮次），README 按课程结构组织五步法讲解；场景切换用 Kconfig，
`sdkconfig.defaults.scN` 变体随工程交付；日志留 `runs/scN-*.log` 归档。

### ex15 perf-gym-rtos —— RTOS 调度错误健身房【症状同样来自真实实测事实】

1. **场景 1 优先级倒挂饿死监控**：高优自旋任务占用 CPU 导致低优心跳停摆——复现
   ch19 的 70%~85% 占空比分水岭，教 uxTaskGetSystemState/backtrace 定位。
2. **场景 2 回调里做慢操作拖死协议栈**：raw 回调 busy-wait → ping/服务全停
   （ch13 停摆实验的应用版），教"从心跳失联反推单线程堵点"。
3. **场景 3 tcpip 邮箱打满**：高频投递淹没 32 槽邮箱 → 投递方阻塞传导链
   （ch13 实验 D），教读邮箱水位与阻塞时长分布。
4. **场景 4 任务栈余量耗尽**：递归/大局部数组把 HWM 逼到阈值下 → 高水位告警设计
   与溢出边缘观察（不含真溢出崩溃，以告警教学为主）。

硬要求：全部走自动注入时序（起振→注入→观测→解除），机器可读行输出 ALARM/RECOVER；
每个场景配「诊断用的观测原语」演示（任务表/邮箱水位/运行时统计），README 五步法结构与
ex14 对称。

## 6. 通用验收清单（一票否决项在前）

1. README 缺失或无中文说明 = 否决。README 必须：目的、网络拓扑（ASCII）、构建命令、
   运行命令（完整可复制）、**真实输出摘录**、已知边界/排障。
2. run.log 无真实输出、或输出与文章声称不符 = 否决。严禁编造。
3. 在线拉取 managed component = 否决（构建离线可重复）。
4. 日志 >1MB 未截断 = 否决（首 5000 行 + 关键证据行 assert failed/panic + 尾 500 行 +
   截断标注，政策见 AGENTS.md）。
5. prettier 未过（交付前 `npx prettier <新文件> --write`）= 否决。
6. 未按 §3 骨架与 §4 端口表 = 打回。
7. 加分项：控制通道免烧写注入、故障注入场景、机器可读标记行（便于 CI 化）。

### ex16 zero-copy-cases —— 零拷贝优化案例集【每个案例：拷贝版 vs 零拷贝版成对实测】

一个固件内四个可切换案例（`CONFIG_ZC_CASE=n`，0=说明模式），全部以
`esp_timer` 微基准 + 足够轮次 + digest 校验做同开机配对对比：

1. **案例 A RX 就地解析**：raw API 的 `tcp_recv` 回调直接在 pbuf payload 上解析协议头
   字段（就地读），对比"先 memcpy 到应用缓冲再解析"的传统写法——量化每字节的
   CPU 时延差与峰值栈差。注意回调解持有时限，解析必须轻。
2. **案例 B TX 分段提交**：`tcp_write` 多段提交（头/体分离各自 write + `MORE` 标志）
   对比"用户侧先拼进大缓冲再整体 write"——COPY 语义下省掉的是**用户侧那次**
   memcpy；量化的就是这一跳。
3. **案例 C 接收路径层级拷贝差**：同一回声负载分别走 raw / netconn / socket 三层，
   对比应用侧每消息处理成本（承接 ch10/ch15 分层税数据，细化到 per-copy 成本）。
4. **案例 D 流式校验零落地**：边收边算 Fletcher32（ex06 方法学）对比"收完落地整包
   再算"——量内存峰值差与校验耗时摊销。
5. **案例 E 诚实边界（必做）**：复现并讲解 IDF 的 `LWIP_NETIF_TX_SINGLE_PBUF=1`
   硬编码使 `TCP_WRITE_FLAG_COPY` 不可达（ch6 实证）——打印实际 apiflags、引用
   port 头文件行号，说明"为什么"（校验和/单缓冲假设）与上游环境的替代路径，
   防止读者照搬通用教程踩坑。

硬要求：每个案例 README 按「问题 → 拷贝版实现 → 零拷贝版实现 → 成对实测数字表 →
适用边界」组织；对比结论必须数字支撑（µs 级、多轮中位）；机器可读标记 `$$$ EX16...`。
