# ex10 ping-monitor —— 周期 ICMP 监控守护模板

`practice/lwip-examples` 套件的第 10 课：用 esp_ping 起一个**单会话常驻**的周期探测守护（目标默认 SLIRP 网关 10.0.2.2），完整实现"监控守护"的三件套——每 RTT 打印、每 N 个样本滚动汇总（min/avg/max + 窗口丢包率）、连续失败 K 次触发**锁存式告警**。固件内还内置了定时「拔网线」故障注入与自愈，无人值守即可走完 `正常监控 → 告警升旗 → 断网维持 → 自愈解除` 的守护生命周期。复制改名就是你的下一个网络监控项目的起点。

## 目的

1. 演示 esp_ping 的正确常驻姿势：`ESP_PING_COUNT_INFINITE` 无限会话 + 三个回调里做统计，而不是像一次性 ping 工具那样数完就删；
2. 给出可直接抄走的监控守护模板件：
   - **逐样本行**：`EX10-RTT` / `EX10-TIMEOUT`（含当前连续失败计数）；
   - **滚动汇总**：每 N 个样本一行 `EX10-SUMMARY`（min/avg/max RTT、窗口内丢包率），成功与超时两条路径都会结算窗口；
   - **告警机**：连续失败 ≥ 阈值触发一次 `$$$ EX10-ALARM` 并锁存，直到下一次成功才打 `$$$ EX10-RECOVER` 解除——不会在持续断网期间反复刷告警；
3. 示范 TCP/IP 层「拔网线」故障注入的标准手法（ch7 同款）：`tcpip_callback()` 投递到 tcpip_thread 执行 `netif_set_link_down()/netif_set_link_up()`，以及配套的告警行为验证。

## 网络拓扑

```text
     Linux host                                   ESP32 guest (QEMU)
 ┌────────────────────────┐                  ┌──────────────────────────────┐
 │ qemu-system-xtensa     │                  │ open_eth MAC 52:54:00:12:34:56│
 │  -M esp32              │   SLIRP 用户态   │ esp_eth + esp_netif           │
 │  -nic user,model=...   │◄──ICMP echo─────►│ lwIP 2.2.0-dev (IDF v6.0.2)   │
 │  10.0.2.2 = SLIRP 网关 │◄────(仅出向)─────│ ex10 守护：esp_ping 监控任务   │
 └────────────────────────┘                  └──────────────────────────────┘
        ▲ 只能 guest → host 方向 ping 通（SLIRP 代答，TTL=255）；
        │ host → guest 的 ICMP 不通（ping 10.0.2.15 恒失败）——本示例无 hostfwd。
```

端口登记：本示例**不占用任何端口**（SPEC §4 中 ex10 行：「ICMP 仅 guest 发起」），QEMU 命令不带 hostfwd。

## 关键边界（先读这个）

1. **主机→guest 的 ping 永远不通**。SLIRP 不支持入向 ICMP，宿主机上 `ping 10.0.2.15` 必然失败；本示例演示的监控方向是 **guest → 目标**（默认网关 10.0.2.2）。想测 guest 侧服务的可达性请配合各 server 类示例的 hostfwd。
2. **esp_ping 不是独立组件**。它实现在 IDF 捆绑的 lwIP 组件内：源码 `~/esp/esp-idf/components/lwip/apps/ping/ping_sock.c`，头文件 `components/lwip/include/apps/ping/ping_sock.h`，CMake 里 `PRIV_REQUIRES lwip` 即可，不需要（也不能）从 component registry 拉包。
3. **务必单会话模式**。SLIRP 有一个实测怪癖：同一时刻开的第二个 ping 会话恒超时（CONVENTIONS Batch 5 会话边界毛刺）。本工程全程只建一次会话且永不重建；要换目标/节奏请改 Kconfig 后重启。
4. RTT 的可见粒度是整毫秒：esp_ping 内部用 `gettimeofday()` 差值（`PING_TIME_DIFF_MS`）计算 TIMEGAP。SLIRP 网关就在宿主进程内，真实 RTT 亚毫秒级，所以常见 `rtt_ms=0/1` 属正常观测；首包可能带 ARP 税略高（本次实测 seq=1 rtt_ms=2）。回包 TTL=255 是 SLIRP 代答指纹（ch9 结论）。

## 构建与运行

环境：ESP-IDF v6.0.2（`~/esp/esp-idf`），QEMU 用 Espressif fork `esp_develop_9.2.2_20250817`。从仓库根目录出发：

```bash
cd practice/lwip-examples/ex10-ping-monitor
. ~/esp/esp-idf/export.sh
idf.py set-target esp32                     # 仅首次需要
idf.py build

# 生成 QEMU 镜像（monitor 因无 TTY 报错属预期，镜像已生成）
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin    # 必须两者都存在

# 单命令运行：串口输出实时回显并落盘 run.log（默认超时 75s > 55s 监控窗）
tools/run_qemu.sh 75
```

不想用脚本的话，手工等价命令如下（核心特征：**不带 efuse `-global` 行**，理由见「已知边界」）：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 75 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth \
  -nographic -no-reboot 2>&1 | tee run.log
```

结束方式：55s 监控窗收口后打印全程汇总并空转保活，由外部 `timeout` 发 SIGTERM 截停——日志末尾出现 `terminating on signal 15 from pid ... (timeout)` 即为正常收场；脚本包装后退出码恒为 0。DHCP 失败与会话创建失败分别打 `$$$ EXFAIL reason=dhcp_timeout` / `reason=ping_session_create`。

一键核对（CI 化验证只需这一条 grep）：

```bash
grep -E 'EX10-FACT|\$\$\$ EXREADY|EX10-SUMMARY|\$\$\$ EX10-ALARM|\$\$\$ EX10-RECOVER|EX10-FINAL|\$\$\$ EXDONE' run.log
```

## 默认时间线（autoinject=y）

监控纪元从会话启动计起（日志里的 `rel_s`）：

| 时刻    | 事件                                                                            |
| ------- | ------------------------------------------------------------------------------- |
| rel≈0s  | EXREADY 后起无限 ping 会话，逐样本打印开始                                      |
| rel≈11s | 第 1 条滚动汇总（10 样本全通）                                                  |
| rel=15s | **注入 link_down**（拔网线）：探针 sendto 立刻失败，样本转入超时                |
| rel=20s | 连续失败达阈值 5 → `$$$ EX10-ALARM` 升旗（之后断网期不再重复告警，只计 consec） |
| rel=30s | 中段汇总 `loss=100.0% rtt=-ms`（纯丢失窗口以 `-` 显示而非误导性的 0）           |
| rel=33s | **注入 link_up**（自愈）：下一个探针立即恢复 → `$$$ EX10-RECOVER` 解除锁存      |
| rel≈55s | 收口：`EX10-FINAL` 全程累计 + `$$$ EXDONE`                                      |

## 真实输出摘录

以下逐行来自本目录入库的 `run.log`（真实运行，未做任何编辑；标注了行号便于对照）：

```text
run.log:58,67
I (1587) ex10: EX10-FACT build="Aug 27 2026 13:28:53" target=10.0.2.2 interval_ms=1000 timeout_ms=1000 alarm_th=5 summary_every=10 window_s=55 autoinject=1
I (2707) ex10: [t=1157 ms] IP_EVENT GOT_IP: ip 10.0.2.15 nm 255.255.255.0 gw 10.0.2.2
I (2707) ex10: $$$ EXREADY target=10.0.2.2 interval_ms=1000 timeout_ms=1000 alarm_th=5 netif=en1 t_ms=1158
I (2707) ex10: EX10-RTT seq=1 rtt_ms=2 ttl=255 size=64 ok=1
```

健康期与第一条滚动汇总（注意 avg 一位小数的整数格式化）：

```text
run.log:78
I (11707) ex10: EX10-SUMMARY window_n=10 ok=10 lost=0 loss=0.0% rtt_min=0ms rtt_avg=0.3ms rtt_max=2ms
```

拔线后的告警触发全过程（组件侧报错与守护侧计数交替出现）：

```text
run.log:85-98
W (17707) ex10: >>> EX10-INJECT event=link_down call=netif_set_link_down(en1) before flags=0x7f link_up=1 up=1
W (17707) ex10: <<< EX10-INJECT done=link_down after flags=0x7b link_up=0 up=1 (UP bit still set: admin up untouched, only LINK_UP cleared)
E (17707) ping_sock: send error=0
W (18707) ex10: EX10-TIMEOUT seq=16 consec=1/5 rel_s=16.0
...
W (22707) ex10: EX10-TIMEOUT seq=20 consec=5/5 rel_s=20.0
E (22707) ex10: $$$ EX10-ALARM consec_lost=5 threshold=5 target=10.0.2.2 lost=5/20 rel_s=20.0
I (22707) ex10: EX10-SUMMARY window_n=10 ok=5 lost=5 loss=50.0% rtt_min=0ms rtt_avg=0.0ms rtt_max=0ms
```

纯断网窗口的中间汇总（这条来自超时路径的窗口结算，证明断网期守护没有"失明"）：

```text
run.log:119
I (32707) ex10: EX10-SUMMARY window_n=10 ok=0 lost=10 loss=100.0% rtt_min=-ms rtt_avg=-ms rtt_max=-ms
```

自愈与恢复解除（seq=33 是接线瞬间的最后一次超时，seq=34 即恢复正常，downtime 全程 13.003s）：

```text
run.log:126-130
W (35707) ex10: >>> EX10-INJECT event=link_up call=netif_set_link_up(en1)
I (35707) ex10: <<< EX10-INJECT done=link_up after flags=0x7f link_up=1 (healed; recovery confirmation left to the probe loop)
W (35707) ex10: EX10-TIMEOUT seq=33 consec=18/5 rel_s=33.0
I (35707) ex10: $$$ EX10-RECOVER rel_s=33.0 downtime_ms=13003 alarms_total=1 (consecutive-fail cleared, path is serving again)
I (35707) ex10: EX10-RTT seq=34 rtt_ms=0 ttl=255 size=64 ok=16
```

收口（五个滚动窗 + 全程账本对得上：38+18=56 样本、18 丢失即断网期的 seq16~33）：

```text
run.log:157-158
I (60507) ex10: EX10-FINAL samples=56 ok=38 lost=18 loss=32.1% rtt_min=0ms rtt_avg=0ms rtt_max=2ms alarms=1 window_ms=55000
I (60507) ex10: $$$ EXDONE monitor_window_ms=55000 t_ms=58957
```

结果解读要点：

- **告警时延 ≈ 阈值 × 探测周期**：threshold=5、interval=1s 下，从链路故障到 ALARM 精确走了 5 个样本（15s→20s）。生产调参就是拿可用性预算除以周期换算阈值；
- **锁存语义有效**：断网共产生 18 个连续超时（consec 一路涨到 18/5），但 ALARM 只发了一次；RECOVER 行携带 `downtime_ms=13003`，即告警持续时间天然就是一段现成的故障时长测量；
- **断网期每个样本都留下痕迹**：组件每次尝试发包失败都打 `E (...) ping_sock: send error=0`（esp_ping 对失败的 sendto 取 SO_ERROR 回读，值 0 是该组件的行为，不是没报错）；守护侧则每秒一个 `EX10-TIMEOUT`；
- **自愈即时生效**：`netif_set_link_up` 与下一拍探针同 tick 到来，恢复在 1 个采样间隔内得到确认，ARP 缓存未清（link-down 不清 ARP，CONVENTIONS Batch 3）、IP 配置未动，所以没有额外的重协商延迟。

## 手动故障注入（关掉 autoinject 时怎么玩）

Kconfig 里把 `EX10_FAULT_AUTOINJECT` 关掉（改后需删除 `sdkconfig` 重新生成）后，固件只做纯监控。此时可用同样手法在任意时刻手动拔线——两行核心代码（完整版在 `main/main.c` 的 `ex10_inject_link_down()/ex10_inject_link_up()`，直接借调试器/console 调用亦可）：

```c
#include "lwip/tcpip.h"
#include "lwip/netif.h"

static void link_down_cb(void *ctx)          /* 在 tcpip_thread 内执行 */
{
    netif_set_link_down((struct netif *)ctx); /* 只摘 LINK_UP 位 */
}

/* 从别的任务调用：raw API 必须投递到 tcpip_thread，禁止跨线程裸调 */
struct netif *nw = (struct netif *)esp_netif_get_netif_impl(eth_netif);
tcpip_callback(link_down_cb, nw);
```

预期行为（与本次自动注入的实测一致）：

1. 注入后**下一个探针立刻失败**：esp_ping 的 raw socket `sendto` 同步报错（组件打 `send error=` 行），守护侧开始累计 `consec=N/threshold`；
2. 到达阈值触发**一次** `$$$ EX10-ALARM`；继续断网只会让 consec 数字增长，不再刷告警；
3. 执行 `netif_set_link_up(...)` 后 ≤1 个采样周期内出现 `EX10-RTT` 且随之打出 `$$$ EX10-RECOVER downtime_ms=...`；
4. 不要用重启网络栈、重建 ping 会话等方式模拟——那会踩 SLIRP 双会话怪癖，现象失真。

若想在物理层仿真更深的故障（丢帧而非全断），参考 ch12 的 `linkoutput` 替换法按概率丢帧；本示例选 `netif_set_link_down` 因为它是"拔网线"的最忠实等价物：admin UP/DHCP/IP 配置全保留，只有 LINK_UP 位被摘掉。

## Kconfig 参数

全部旋钮在 `idf.py menuconfig` → "EX10 ping-monitor configuration"：

| 项                      | 默认       | 说明                                                            |
| ----------------------- | ---------- | --------------------------------------------------------------- |
| `EX10_TARGET_IP`        | `10.0.2.2` | 监控目标 IPv4；SLIRP 网关即宿主方向代答者                       |
| `EX10_INTERVAL_MS`      | 1000       | 探测周期；监控节奏旋钮                                          |
| `EX10_TIMEOUT_MS`       | 1000       | 单次探测超时（raw socket SO_RCVTIMEO 实现）；建议 ≤ 2× interval |
| `EX10_ALARM_THRESHOLD`  | 5          | 连续失败告警阈值（次）；告警到恢复的时间差即本次故障时长        |
| `EX10_SUMMARY_EVERY`    | 10         | 滚动汇总窗口大小（样本数）                                      |
| `EX10_MONITOR_WINDOW_S` | 55         | 监控总时长，到点收口打印 FINAL                                  |
| `EX10_FAULT_AUTOINJECT` | y          | 定时自动拔线/接回                                               |
| `EX10_INJECT_AT_S`      | 15         | 拔线时刻（监控秒）                                              |
| `EX10_RECOVER_AT_S`     | 33         | 接回时刻（监控秒），须大于拔线时刻                              |

改过 `sdkconfig.defaults` 或 Kconfig 后必须删除生成的 `sdkconfig` 再重新构建才生效（曾踩坑项）。

## 机器可读标记一览

| 标记                             | 含义                                                          |
| -------------------------------- | ------------------------------------------------------------- |
| `EX10-FACT build="..."`          | 固件编译指纹 + 全部生效参数，核对加载的不是旧镜像             |
| `$$$ EXREADY target=... t_ms=`   | 起播门信号：目标/节奏/阈值/netif 名齐备，随后进入监控主线     |
| `EX10-RTT seq= rtt_ms= ttl= ok=` | 成功样本：序号/往返毫秒/TTL/累计成功数                        |
| `EX10-TIMEOUT seq= consec=a/b`   | 超时样本：序号/当前连续失败(a)/告警阈值(b)                    |
| `EX10-SUMMARY window_n=...`      | 滚动窗口结算：ok/lost/loss%/rtt min·avg·max（纯丢失窗为 `-`） |
| `$$$ EX10-ALARM consec_lost=`    | 告警升起（锁存）；含当时的目标与全程丢失比分                  |
| `$$$ EX10-RECOVER downtime_ms=`  | 告警解除；downtime_ms 即本次故障持续时长                      |
| `EX10-INJECT event=link_down/up` | 注入器动作行（含注入前后 flags/link_up 状态对照）             |
| `EX10-FINAL samples= alarms=`    | 全程总账：样本/成功/丢失/丢包率/RTT 分位/告警次数             |
| `$$$ EXDONE monitor_window_ms=`  | 监控窗正常收口                                                |
| `$$$ EXFAIL reason=...`          | 失败门信号（dhcp_timeout / ping_session_create）              |

验收流水线建议的组合判断：`EXREADY ∧ EXDONE ∧ (EX10-ALARM ∧ EX10-RECOVER ⇔ autoinject=1)`。

## 实现要点（模板可直接抄的部分）

- **单写者免锁模型**：全部统计写在 esp_ping 回调里（它们由唯一的内部 ping 任务串行调用，天然互斥）；app_main 只在 `esp_ping_stop()` 之后过了 `QUIT_GRACE_MS`（覆盖末次超时窗）才读全程累计——「先静默再读」（quiesce-then-read），用生命周期顺序替代互斥锁；
- **回调上下文**：三个回调跑在 esp_ping 内部的裸 `xTaskCreate(prio=2)` 任务里（不是 tcpip_thread），里面只做日志与自有变量读写，勿再调 raw API；
- **高水位失败观察点**：堆紧张时 `esp_ping_new_session` 会在 `create ping task failed` / `no memory for esp_ping object` 处返回 `ESP_ERR_NO_MEM`（ch4 实测可复现）。生产守护应在此带退避重试；模板保持一次尝试 + 明确的 `$$$ EXFAIL` 门信号；
- **seqno 计数的是尝试次数**：断网期间 sendto 失败 seqno 也照加（实例中 seq16~33 连续推进），所以连续超时的 seq 区间天然刻画了故障窗口；
- **中间汇总的两条路径**：窗口结算函数必须同时挂在成功与超时回调上——第一版只挂在成功路径，纯断网期的窗口被拉长到 n=24 才结算（本仓库留档的第一轮 run.log 即此形态），是典型的"happy path 观测盲区"。

## 已知边界与排障

以下均为本机实测特性，**不要把它们当故障**：

1. **MAC filter ioctl 错误 ×3 是预期噪音**（openeth 白名单噪音，不影响收发）：`add mac address to filter not supported` / `eth_set_mac_filter(56)` / `Failed to add multicast filter for IPv4`。
2. **`E (...) ping_sock: send error=0` 刷屏 = 发送路径故障的证据行**，不是噪音消失时的误报：esp_ping sendto 失败后取 `SO_ERROR` 回读，在本环境读到 0。看到它连着 `EX10-TIMEOUT` 出现即为发送面故障签名。
3. **efuse `-global` 行陷阱**：给 QEMU 命令手工加回 `-global driver=nvram.esp32.efuse,...` 一行，在本机偶发导致 openeth NIC 未创建、固件在 `esp_eth_mac_new_openeth()` 崩溃复位。套件所有 runner 已统一去掉该行。
4. **改监控目标**：改成公网地址（如 223.5.5.5）也可行（经 SLIRP NAT 多跳转发，TTL 会变小），但端到端行为受宿主出口网络影响，CI 场景建议保持 10.0.2.2 的确定性。
5. **退出码 124**（timeout 截停）与 0 都算正常收场；监控窗未跑完就退出先查 DHCP 阶段的 `$$$ EXFAIL`。
6. 本示例不开 `CONFIG_LWIP_STATS`——统计口径只用守护自己的采样账本；要看协议栈侧计数请配 ex12 观测台模板。

## 文件结构

| 文件                     | 作用                                                                      |
| ------------------------ | ------------------------------------------------------------------------- |
| `main/main.c`            | bring-up + esp_ping 监控守护三件套 + 注入器（全部逻辑）                   |
| `main/Kconfig.projbuild` | 目标 IP/间隔/超时/告警阈值/汇总粒度/监控窗长/自动注入时刻 等全部旋钮      |
| `main/CMakeLists.txt`    | main 组件声明：`PRIV_REQUIRES esp_eth esp_netif esp_event lwip esp_timer` |
| `CMakeLists.txt`         | root 构建骨架（`MINIMAL_BUILD ON` trim 形态）                             |
| `sdkconfig.defaults`     | 最小集：仅 `CONFIG_ETH_USE_OPENETH=y`                                     |
| `tools/run_qemu.sh`      | 标准 QEMU 启动器（timeout + tee run.log，无 efuse 行、无 hostfwd）        |
| `run.log`                | 真实运行留存（本文摘录的出处，含完整告警/自愈时间线）                     |
