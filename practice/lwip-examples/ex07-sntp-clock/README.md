# ex07：SNTP 对时模板 + SLIRP UDP 转发裁决实验（sntp-clock）

`practice/lwip-examples` 套件第 7 课。表面任务是「给 guest 对时」（SNTP），真正的主线是一场
**裁决实验**：guest 主动向 SLIRP 网关 `10.0.2.2` 发出的 UDP 报文，到底会不会落到宿主机的
loopback 同端口上？这个问题在调研文档里挂了整整一章的「需构建期实证」标记，ex07 用一次
运行给出终审：**可行**（详见[裁决小节](#slirp-udp-转发裁决结论)）。

同时交付三个时钟教学点的真实测量：

1. **对时前后的系统时钟差**：上电默认态距 1970 基准仅 ~1 秒，SNTP 一发即中后跳到宿主
   当前时刻（跨边界 µs 级对账一致）；
2. **`sys_now()` 是 10ms tick 网格**：同样本窗内唯一值只有 1 个 vs `esp_timer_get_time()`
   的 199 个——亚毫秒计时用它是错的；
3. **`settimeofday()` 跳变墙钟后 esp_timer 不受影响**：对时落定前后 esp_timer 连续单调，
   两次周期对时间隔实测 19.998s ≈ 配置的 20s。

## 目的

- 学会在 RTOS 上用 SNTP 建立墙钟（wall clock）：esp_netif_sntp 全流程、随机启动延迟、
  同步等待、周期重对时（RFC 4330 下限 15s）。
- 用最小 UDP 探针组做协议栈外的链路级裁决：开放端口反射器 / 空端口对照。
- 认清 ESP32 双时钟体系：系统时间（可跳变，SNTP 写入）vs esp_timer（单调，永不回拨），
  以及 `sys_now()` 的 tick 网格陷阱。

## 网络拓扑

```text
       宿主机 (Fedora, python3 tools/ntpd.py)
 ┌───────────────────────────────────────────────┐
 │  127.0.0.1:8260  ← SNTP v4 应答器 (ntp 槽位)    │
 │  127.0.0.1:8262  ← UDP 反射器 (reflector 槽位)  │
 │  127.0.0.1:8261  ← 【无监听】空端口对照          │
 └────────────▲────────────────▲─────────────────┘
              │ 同端口号落 loopback      │
 ┌────────────┴────────────────┴─────────────────┐
 │ QEMU slirp user-net (guest 出站 UDP 转发)      │
 │   gw/DNS 代理: 10.0.2.2 / 10.0.2.3            │
 ├───────────────────────────────────────────────┤
 │ guest ESP32 (openeth): 10.0.2.15/24           │
 │   lwIP SNTP 客户端  src/dst port=8260(编译期覆盖)│
 │   裁决探针          → 8262 反射器 / 8261 空口   │
 └───────────────────────────────────────────────┘
```

无 hostfwd——本示例全部流量是 guest 出向（SPEC §4 ex07 行）。

## 文件结构

```text
ex07-sntp-clock/
├── CMakeLists.txt        # 根工程；add_compile_definitions(SNTP_PORT=8260) 是本例关键改动
├── main/
│   ├── CMakeLists.txt
│   └── main.c            # bring-up → 时钟基线 → 探针裁决 → SNTP 主线 → 回退预案
├── sdkconfig.defaults    # openeth + SNTP_DEBUG + UPDATE_DELAY=20s(教学用)
├── tools/
│   ├── ntpd.py           # 单文件 stdlib：SNTP v4 应答器 + UDP 反射器（宿主侧）
│   ├── run_qemu.sh       # 标准 QEMU 启动器（去 efuse -global 形态）
│   ├── ntpd-host.log     # 终版运行的宿主侧真实日志（tee 存档）
│   ├── ntpd-host.run1-responder-crash.log   # 第一次尝试：应答器崩溃实录（教训存档）
│   └── run1-guest-sntp-no-reply.log         # 第一次尝试：guest 侧看到的"服务死"现场
└── run.log               # guest 串口输出终版（成功路径全文）
```

## 构建

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-examples/ex07-sntp-clock
idf.py set-target esp32        # 仅首次
idf.py build
# 生成 QEMU 镜像（monitor 会因无 TTY 失败，忽略它，镜像已生成）：
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在
```

> [!warning] 镜像新鲜度兜底
> 重复构建后 `idf.py qemu monitor` 可能静默失败（qemu_flash.bin 不再更新）。手动合并：
> `cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args`
> 并核对固件打印的 `FACT built="..."` 指纹。

### 关键编译期改动：SNTP_PORT=8260（为什么必须动它）

lwIP 的 SNTP 客户端把**本地绑定端口与远端目的端口绑死在同一个宏**上
（`sntp_opts.h`: `#define SNTP_PORT LWIP_IANA_PORT_SNTP`(123)；`src/apps/sntp/sntp.c`
里 `udp_bind(..., SNTP_PORT)` 与 `udp_sendto(pcb, p, server_addr, SNTP_PORT)` 各用一次）。
而 SLIRP 的外连转发是「同端口号落宿主 loopback」，123 又是特权端口。两个约束合起来：

```c
// 根 CMakeLists.txt —— 必须写在 include(project.cmake) 之前才能传进 lwip 组件源码
add_compile_definitions(SNTP_PORT=8260);
```

生效取证（配置生成后可复查）：`grep -o 'DSNTP_PORT=8260' build/compile_commands.json`
在本仓命中 lwip 组件的两个 sntp.c 编译命令各一处。若想改用标准端口 123，需要宿主侧
`sudo` 监听或 iptables 重定向，见排障速查最后一行。

## 运行

**终端 1** —— 启动宿主端两槽位服务：

```bash
cd practice/lwip-examples/ex07-sntp-clock
python3 tools/ntpd.py 2>&1 | tee tools/ntpd-host.log
```

启动后应看到（真实输出）：

```text
$$$ NTPREADY kind=ntp port=8260 host_utc=2026-08-27T05:32:07.433Z
NTP-ALL slots=all waiting ...（Ctrl-C 结束；8261 保持无监听——那是固件空端口探针的对象）
$$$ NTPREADY kind=reflector port=8262 host_utc=2026-08-27T05:32:07.433Z
```

8261 故意不监听——固件要用它观察「宿主无服务」时的现象。

**终端 2** —— 启动 QEMU（默认 100s 自动截停，退出码 124 属正常）：

```bash
tools/run_qemu.sh 100         # 串口输出落 run.log
```

固件全程约 40s：探针裁决（~12s）→ SNTP 初次对时（最快 3s 内，随机启动延迟可达 5s+）→
25s 周期对时观测窗 → 打印收口标记后主动复位退出。结束时按 PID 清理（套件纪律：禁 pkill）：

```bash
pgrep -af 'qemu-system-xtensa|ntpd.py'   # 找到目标 PID 后逐个 kill <PID>
```

## SLIRP UDP 转发裁决结论

> **判决：可行。** guest 主动发往 `10.0.2.2:<port>` 的 UDP 报文经 SLIRP 用户态转发，
> 落到**宿主机 loopback 的同端口号**，应答原路返回。与 TCP 侧多年沉淀的规则完全同构，
> 从此「SLIRP 只转 TCP、UDP 靠 DNS/hostfwd 绕」的记忆可以删除了。

### 正向证据（本仓 run.log + ntpd-host.log 同时段配对）

guest 侧反射器探针一次成功，48 字节载荷逐字节往返保真（rtt 为 esp_timer µs 口径）：

```text
I (2841) ex07: [EX07] PROBE dst=10.0.2.2:8262 attempt=1/3 len=48
I (2851) ex07: [EX07] PROBE reply 48 bytes from 10.0.2.2:8262 rtt_us=8822 payload_match=yes head="EX07PROBE se"
I (2851) ex07: $$$ EX07-RESULT UDP-FORWARD dst=10.0.2.2:8262 status=REACHABLE rtt_us=8822 payload_match=yes attempts=1 verdict="guest 出站 UDP 经 SLIRP 可达宿主 loopback 同端口"
```

宿主侧同刻记账（注意 guest 的 NAT 后源端口：guest 固定源端口 8260，SLIRP 转成宿主侧临时端口 58319 回程映射回去）：

```text
NTP-ECHO peer=127.0.0.1:58319 len=48 head=234200004558303750524f4245207365713d6131 magic="EX07PROBE " rx_bytes=60 tx_bytes=60 allzero=False
```

### 判决的可信度加固：同一判决被第二证据独立复现

主线 SNTP 本身就是第二个探针——若 UDP→loopback 不通，SNTP 必然失败。终局运行里
请求/应答双双到位，且宿主 xmit 时间戳与 guest 收到的 server time 在 **µs 位**上一致
（`214642` 六位数完全相同；SYNC#2 尾差 1µs 来自 NTP 定点小数的取整）：

```text
# 宿主:
NTP-REQ ts=2026-08-27T05:32:42.214543Z peer=127.0.0.1:35592 li=0 vn=4 mode=3 len=48 OK
NTP-RSP peer=127.0.0.1:35592 bytes=48 xmit_epoch=1787808762.214642 srv_processing_us=99
# guest:
I (14441) ex07: [EX07] SYNC#1 server_time_utc="2026-08-27 05:32:42.214642" wall_after_epoch=1787808762 et_at_apply_us=12810346
```

### 空端口对照（8261 无监听）：静默吞掉，无 ICMP 引导错误

```text
W (5851) ex07: [EX07] PROBE no reply within 3s errno=11 (No more processes)
I (11851) ex07: $$$ EX07-RESULT UDP-CLOSED dst=10.0.2.2:8261 observed=NO_REPLY last_errno=11
```

三轮均超时收场：应用层**只看到 SO_RCVTIMEO 型 EAGAIN(errno=11)**，没有拿到 ECONNREFUSED。
对比 Batch 5 曾观测到的「发往 discard 端口立即回弹 ICMP type3」，本例说明未 connect 的
UDP socket 不消费 ICMP 不可达错误（lwIP 只在特定 pcb 状态才把 ICMP 错误排队）——
**别指望用 recvfrom 错误码探测远端 UDP 服务存活，超时是唯一可靠信号**。

### 失败回退路径（两条预案，均留有真实日志或固化在固件里）

第一轮尝试确实失败过一次，但根因值得记录：**转发面无罪，宿主工具崩了**。当时应答器在
收到首个请求后因组包 bug 抛异常退出（`ntpd-host.run1-responder-crash.log`），此后 guest
的第二笔重试自然无人应答，14 轮等待全 TIMEOUT——这正是「远端服务死后应用视角」的完整
现场（`tools/run1-guest-sntp-no-reply.log`）：

```text
sntp_send_request: Sending request to server        # 第 1 笔发出（宿主随后崩溃）
...
sntp_retry: Next request will be sent in 15000 ms   # lwIP 以 15s 步长退避重试
...
sntp_send_request: Sending request to server        # 第 2 笔发出（尸体现场，无回应）
W (53682) ex07: $$$ EX07-RESULT SNTP-PRIMARY status=FAIL server=10.0.2.2:8260 rounds=14 note="主线不通，按备选预案注入回退时钟"
```

固件内置两级预案，任何一层失败都能继续交付教学价值：

1. **备选 B（调研文档既定方案，主线成立时无需启用）**：把 NTP 域名经 SLIRP DNS 代理钉到
   已知地址（Batch 1 验证过 SLIRP DNS 会查宿主 `/etc/hosts`）。做法：宿主
   `echo '10.0.2.2 ntp.qemu.host' | sudo tee -a /etc/hosts`，固件改配
   `ESP_NETIF_SNTP_DEFAULT_CONFIG("ntp.qemu.host")`——解析走确定性 DNS，投递仍走本次
   已判成立的 UDP 转发面。
2. **机制演示版兜底（已实装且实跑验证）**：SNTP 等 42s 仍不齐时，固件注入已知答案时钟并
   如实标注来源，同一套时钟指标照常产出：

```text
W (53682) ex07: [EX07] FALLBACK manual settimeofday to epoch=1769904000 (sync mechanism demo, NOT a real NTP result)
I (53682) ex07: $$$ EX07-RESULT CLOCK-DELTA delta_s=1769903999 origin=fallback-injection
```

## 时钟教学点：三块真实测量怎么读

### ① 对时前后的系统时钟差

```text
I (2811) ex07: [EX07] PHASE=CLOCK-BEFORE epoch_sec=1.185111 utc="1970-01-01 00:00:01" cst8="1970-01-01 08:00:01" ...
I (14441) ex07: [EX07] PHASE=CLOCK-AFTER epoch_sec=1787808762.216164 utc="2026-08-27 05:32:42" cst8="2026-08-27 13:32:42" ...
I (14441) ex07: $$$ EX07-RESULT CLOCK-DELTA delta_s=1787808761 origin=sntp-primary
```

上电默认态是裸 epoch（差值口径统一用 UTC epoch 秒）。1.18~12.9s 的真实间隔里 `sys_now`
只走到 12.7s 级别——对时钟学最直观的一课：**墙钟可以被外部一步改写，跟 CPU 过了多少
tick 无关**。

### ② sys_now() 是 10ms tick 网格

220 连读窗口（物理跨度仅 0.3ms）：`unique_sysnow=1` vs `unique_esptimer=199`；
翻转步进抓取显示每次 sys_now 变化恰好 +10ms，而 esp_timer 在翻转间隙走了
5341/9892/9962µs。`portTICK_PERIOD_MS=10` 决定了 `sys_now()` 的分辨率上限就是 10ms，
两倍抖动都不止亚毫秒需求一个数量级——**亚毫秒一律 esp_timer_get_time()（µs 网格）**。
本示例自己的 RTT 测量就用它（`rtt_us=8822`）。

### ③ settimeofday 之后 esp_timer 不受影响

```text
I (14441) ex07: [EX07] ESPTIMER continuity: et_at_apply_us=12810346 et_now_us=12811900 elapsed=1.554ms
I (34441) ex07: [EX07] SYNC#2 ... et_at_apply_us=32808691 ...
```

对时瞬间墙钟跳了 17 亿秒，esp_timer 却从 12810346 平滑走到 12811900（+1.554ms，正是事件
派发耗时）；第二次对时的 esp_timer 读数与前次相差 19998345µs ≈ 配置的 20000ms 更新周期。
这是"**单调时钟与墙钟分家**"的活教材：相对时长测量永远锚 esp_timer，绝对日期才看
SNTP 结果。`reachability=0x01` 也顺势展示——低 8 位即最近 8 次查询的到达/应答位图。

## esp_netif_sntp 与原生 lwip sntp API 的取舍

选了 **esp_netif_sntp** 作为主线。理由：

- 它是官方现行推荐封装（examples/protocols/sntp 即用它），生命周期钩子齐全：
  `init/start/sync_wait/deinit` 四步语义清晰，`sync_wait()` 自带跨任务同步信号量；
- 免费获得 `NETIF_SNTP_EVENT` 事件通道（timeval 载荷可直接人读打印）和 DHCP option 42
  扩展位（`server_from_dhcp`，本例未开）。
- 但要清醒它只是薄包装：底层就是 lwIP `sntp_init()/sctp...`，连通知回调都是转接的——
  一个 sync 里 `sync_cb` 与 event **都会**触发一次（见 `esp_netif/lwip/esp_netif_sntp.c`
  的 `sync_time_cb`），两个都注册会双计事件数，本示例因此只走事件通道（main.c 注释）。

- 但要清醒它只是薄包装：底层就是 lwIP 的 SNTP 状态机，连通知回调都是转接的——
  一个 sync 里 `sync_cb` 与 event **都会**触发一次（见 `esp_netif/lwip/esp_netif_sntp.c`
  的 `sync_time_cb`），两个都注册会双计事件数，本示例因此只走事件通道（main.c 注释）。

原生路径（`esp_sntp.h` 直调 `esp_sntp_setserver()+esp_sntp_init()`）更适合：
无 esp*netif 场景（纯 netif 应用）、需要对服务器数组做细粒度增删、或在 ISR 之外的极简
直调风格。两者共享同一批 `CONFIG_LWIP_SNTP*\*`旋钮与同一个编译期`SNTP_PORT`。

## run.log 真实输出摘录（完整文件见根目录 run.log）

```text
I (2811) ex07: $$$ EX07READY ip=10.0.2.15 gw=10.0.2.2 dns=10.0.2.3 t_ms=1120
I (2811) ex07: [EX07] PHASE=CLOCK-BEFORE epoch_sec=1.185111 utc="1970-01-01 00:00:01" cst8="1970-01-01 08:00:01" et_us=1180619 tick_ms=1120
I (2811) ex07: [EX07] CLOCK-GRID samples=220 span_ms=0.3 unique_sysnow=1 unique_esptimer=199
I (2821) ex07: [EX07] GRID-STEP 1 sysnow_flip_ms=10 esptimer_span_us=5341
I (2851) ex07: $$$ EX07-RESULT UDP-FORWARD dst=10.0.2.2:8262 status=REACHABLE rtt_us=8822 payload_match=yes attempts=1 ...
I (11851) ex07: $$$ EX07-RESULT UDP-CLOSED dst=10.0.2.2:8261 observed=NO_REPLY last_errno=11
I (14441) ex07: [EX07] SYNC#1 server_time_utc="2026-08-27 05:32:42.214642" wall_after_epoch=1787808762 et_at_apply_us=12810346
sntp_process: Thu Aug 27 13:32:42 2026
, 214642 us
I (14441) ex07: [EX07] SNTP synced within ~3s (rounds=1)
I (14441) ex07: $$$ EX07-RESULT SNTP-PRIMARY status=OK server=10.0.2.2:8260 wait_rounds=14 startup_delay_budget_ms=5000
I (14441) ex07: $$$ EX07-RESULT CLOCK-DELTA delta_s=1787808761 origin=sntp-primary
I (14441) ex07: [EX07] PHASE=CLOCK-AFTER epoch_sec=1787808762.216164 utc="2026-08-27 05:32:42" cst8="2026-08-27 13:32:42" ...
I (14441) ex07: $$$ EX07-RESULT ESPTIMER-AFTER-SETTIMEOFDAY monotonic=yes et_at_apply_us=12810346 et_final_us=12811900
I (14441) ex07: $$$ EX07-RESULT SYNC-TOTAL events=1 interval_ms=20000 mode=primary reachability=0x01
I (34441) ex07: [EX07] SYNC#2 server_time_utc="2026-08-27 05:33:02.214639" wall_after_epoch=1787808782 et_at_apply_us=32808691
I (39441) ex07: $$$ EX07-RESULT PERIODIC-SYNC events_seen=2 expect_ge=2 note="SYNC#2 应出现且间隔≈UPDATE_DELAY"
I (39441) ex07: $$$ EX07DONE
```

## CI 化断言（机器可读标记）

| 标记                                                          | 含义                                                  |
| ------------------------------------------------------------- | ----------------------------------------------------- |
| `$$$ EX07READY ip=.. t_ms=`                                   | 起播成功门信号                                        |
| `$$$ EX07-RESULT SYSNOW-GRID grid_ms=10 …`                    | 教学点②结论行                                         |
| `$$$ EX07-RESULT UDP-FORWARD status=REACHABLE\|UNREACHABLE …` | **裁决行**（核心断言）                                |
| `$$$ EX07-RESULT UDP-CLOSED observed=…`                       | 空端口对照行为                                        |
| `$$$ EX07-RESULT SNTP-PRIMARY status=OK\|FAIL …`              | 主线对时结果                                          |
| `$$$ EX07-RESULT CLOCK-DELTA delta_s=N origin=…`              | 对时前后时钟差                                        |
| `$$$ EX07-RESULT SYNC-FALLBACK applied=yes…`                  | 仅失败回退注入时出现                                  |
| `$$$ EX07-RESULT PERIODIC-SYNC events_seen=N`                 | 周期重对时观测窗结果                                  |
| `$$$ EXFAIL reason=…`                                         | 致命失败门信号（当前仅 dhcp_timeout / sntp_init_err） |
| `$$$ EX07DONE`                                                | 收口                                                  |

CI 断言建议顺序：`EX07READY` → `UDP-FORWARD status=REACHABLE` → `SNTP-PRIMARY status=OK`
→ `CLOCK-DELTA origin=sntp-primary 且 delta_s>1e9` → `PERIODIC-SYNC events_seen>=2` →
`EX07DONE`。

## 已知边界 / 排障速查

- **efuse `-global` 行**：沿用套件去 efuse runner 形态；若自改启动参数出现 NIC 未创建，
  先删该行（Batch 4 实测坑）。
- **826x 端口被占**：`ss -ulnp | grep 826` 查占用者；并行作者实例共存时禁止 pkill，按 PID 杀。
- **初次对时可能迟到**：`LWIP_SNTP_STARTUP_DELAY` 默认开，首笔查询随机延迟 0~5000ms
  （run2 里几乎零延迟秒中，run1 里迟到 ~2.7s 才首发——同一固件两次运行的活样本）。
  固件预算 42s，勿以「几秒没动静」判死。
- **UPDATE_DELAY 下限 15s**（RFC 4330 强制），本例设 20s 只为单窗看到第二次对时；
  改 `sdkconfig.defaults` 后记得删 `sdkconfig` 重新生成。
- **Linux 特权端口 123**：想回归标准端口需删除根 CMakeLists 的 `add_compile_definitions`
  并满足其一：宿主 root 起 NTP 服务于 123；或 iptables 把出站/本地 123 REDIRECT 到号段
  内非特权端口（如 `sudo iptables -t nat -A OUTPUT -p udp --dport 123 -j REDIRECT --to-ports 8260`）。
- **monitor 兜底**：镜像不新鲜时用 merge-bin 手动合并并核对 `FACT built=` 指纹。

## 作为模板复制改造

换项目只需三处：`SERVER_STR`（或换成你的域名）、`SECOND_SYNC_WAIT_S` 观测窗、以及决定
是否保留 `SNTP_PORT` 编译期覆盖。删减分支时保留探针对照组——它们是你下一次换网络底座
（真机/QEMU 版本升级）时最先报警的哨兵。

## 端口登记（套件号段 8260~8269）

| 端口 | 角色                                        | 方向           |
| ---- | ------------------------------------------- | -------------- |
| 8260 | SNTP（编译期 SNTP_PORT 覆盖，源=目的=8260） | guest 出连宿主 |
| 8261 | 空端口对照（故意无监听）                    | guest 出连宿主 |
| 8262 | UDP 反射器（转发裁决正向证据）              | guest 出连宿主 |
