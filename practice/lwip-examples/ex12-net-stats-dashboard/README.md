# ex12 net-stats-dashboard —— 观测台模板

`practice/lwip-examples` 套件的收口一课：每 30s 在控制台打**一帧完整仪表盘**（同一时刻快照、统一 key=value 格式），把 lwIP 协议栈计数、heap 水位、RTOS 任务表装进同一次输出，两帧相邻即可 `diff` 出所有增量。后台自带一个轻量自流量源（esp_ping 无限会话 ping 网关 10.0.2.2）让计数器动起来。无 hostfwd、无外部工具依赖——复制改名就是一个现成的"运行观测底座"。

本示例的**核心价值在本文的「逐字段解读」章节**：仪表盘上每个数字是什么意思、口径是什么、异常时先看哪里。读懂它，你在任何 ESP-IDF+lwIP 项目里都能照抄这套健康检查。

## 目的

1. 建立一套**可 diff 的周期观测格式**：单次快照同帧打印、行序稳定（任务表按 prio 降序排序）、绝对值与增量并列；
2. 示范 lwip_stats 的**安全读取姿势**：五个协议段在同一次 `tcpip_callback()` 回调里取齐（跑在 tcpip_thread 内），不裸读共享结构、不同字段不出自不同时刻；
3. 给出 heap 三件套与任务栈高水位的正确口径（特别是 min-ever 为什么不能跨阶段取差）；
4. 用自流量源演示"计数器动起来"与各协议段的真实响应差异。

## 网络拓扑

```text
     Linux host                                   ESP32 guest (QEMU)
 ┌────────────────────────┐                  ┌──────────────────────────────┐
 │ qemu-system-xtensa     │   SLIRP 用户态   │ open_eth MAC 52:54:00:12:34:56│
 │  -M esp32              │◄──── ICMP ──────►│ esp_eth + esp_netif          │
 │  -nic user,model=open_eth                 │ lwIP 2.2.0-dev (IDF v6.0.2)  │
 │                        │                  │ app: 30s 仪表盘 + 自 ping    │
 │  SLIRP 网关 10.0.2.2 ──┼── 恒应答 echo ───┤ (esp_ping 无限会话, 静默回调) │
 └────────────────────────┘                  └──────────────────────────────┘
        guest 得 10.0.2.15/24（DHCP），网关/DNS 见 EXREADY 行
```

端口登记：本示例**不占用任何端口**（SPEC §4 中 ex12 行：「纯观测」），QEMU 命令不带 hostfwd，也不需要任何宿主端工具。

## 构建与运行

环境：ESP-IDF v6.0.2（`~/esp/esp-idf`），QEMU 用 Espressif fork `esp_develop_9.2.2_20250817`。

```bash
cd practice/lwip-examples/ex12-net-stats-dashboard
. ~/esp/esp-idf/export.sh
idf.py set-target esp32                     # 仅首次需要
idf.py build

# 生成 QEMU 镜像（monitor 因无 TTY 报错属预期，镜像已生成）
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin    # 必须两者都存在

# 单命令运行：串口输出实时回显并落盘 run.log（默认超时 80s）
tools/run_qemu.sh
# 或指定超时：起播约需 3s、周期 30s，80s 稳定收进 frame1/frame2 两帧
tools/run_qemu.sh 80
```

手工等价命令（核心特征：**不带 efuse `-global` 行**，理由见「已知边界」）：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 80 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth \
  -nographic -no-reboot 2>&1 | tee run.log
```

结束方式：固件仪表盘永不退出（观测台就该常驻），由外部 `timeout` 发 SIGTERM 截停——日志末尾出现 `terminating on signal 15 from pid ... (timeout)` 即为正常收场；runner 包装后退出码恒为 0。

一键核对（CI 化验证只需这几条 grep）：

```bash
grep -E 'EX12-FACT|EXREADY|EXTRAFFIC' run.log      # 起播门信号 + 固件指纹
grep -c 'EX12-FRAME id=' run.log                   # ≥2 说明至少两个周期
grep 'EX12-ST icmp' run.log                        # 自流量是否让计数爬升
```

## 真实输出摘录

以下逐行来自本目录入库的 `run.log`（真实运行，未做任何编辑）：

```text
I (1544) ex12: $$$ EX12-FACT build="Aug 27 2026 13:25:11" lwip_stats=1 trace_facility=1
...
I (2664) ex12: [t=1166 ms] IP_EVENT GOT_IP: ip 10.0.2.15 nm 255.255.255.0 gw 10.0.2.2
I (2664) ex12: $$$ EXREADY ip=10.0.2.15 nm=255.255.255.0 gw=10.0.2.2 t_ms=1166
I (2664) ex12: $$$ EXTRAFFIC target=10.0.2.2 interval_ms=1000 count=infinite
$$$ EX12-FRAME id=1 up_ms=31166 period_ms=30000 src=self-ping iv_ms=1000
EX12-ST link  recv=3(+2) xmit=3(+2) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST ip    recv=33(+30) xmit=33(+30) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST icmp  recv=31(+30) xmit=0(+0) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST tcp   recv=0(+0) xmit=0(+0) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST udp   recv=2(+0) xmit=2(+0) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-HEAP free=270504 largest=147456 min_ever=265972 unit=bytes cap=MALLOC_CAP_8BIT
EX12-TASK n=10 order=prio_desc,name_asc hwm_unit=bytes
EX12-T ipc0             prio=24 core=0  hwm=564
EX12-T ipc1             prio=24 core=1  hwm=572
EX12-T esp_timer        prio=22 core=0  hwm=3640
EX12-T sys_evt          prio=20 core=0  hwm=1664
EX12-T tcpip            prio=18 core=NA hwm=2328
EX12-T emac_rx          prio=15 core=NA hwm=3256
EX12-T ping             prio= 2 core=NA hwm=1400
EX12-T main             prio= 1 core=0  hwm=2468
EX12-T IDLE0            prio= 0 core=0  hwm=976
EX12-T IDLE1            prio= 0 core=1  hwm=1100
EX12-SYS uptime_s=31 ntp=disabled(ntp-line-placeholder) clock_src=esp_timer
$$$ EX12-FRAME-END id=1
```

第二个周期（61s 处），直接展示两帧的可 diff 性——除数字外逐字符同构：

```text
$$$ EX12-FRAME id=2 up_ms=61166 period_ms=30000 src=self-ping iv_ms=1000
EX12-ST link  recv=3(+0) xmit=3(+0) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST ip    recv=63(+30) xmit=63(+30) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST icmp  recv=61(+30) xmit=0(+0) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST tcp   recv=0(+0) xmit=0(+0) drop=0(+0) chkerr=0(+0) memerr=0(+0)
EX12-ST udp   recv=2(+0) xmit=2(+0) drop=0(+0) chkerr=0(+0) memerr=0(+0)
...
```

**增量确实随自流量变化**：自流量为 1 pps 的 echo 对，每个 30s 周期 ip.recv/ip.xmit 各 `+30`（30 个请求出去、30 个应答回来）、icmp.recv 同步 `+30`；frame1/frame2 斜率完全一致，停止自流量后斜率归零即可反证因果。两帧之间 heap 与任务栈水位几乎不动（IDLE1 的 hwm 从 1100 微降到 988 属正常抖动），说明稳态无泄漏。

## 机器可读标记一览

| 标记                             | 含义                                                           |
| -------------------------------- | -------------------------------------------------------------- |
| `$$$ EX12-FACT build=`           | 固件编译指纹 + 两个观测开关状态（lwip_stats / trace_facility） |
| `$$$ EXREADY ip=... t_ms=`       | 起播成功门信号（套件标准格式）                                 |
| `$$$ EXFAIL reason=dhcp_timeout` | 起播失败门信号                                                 |
| `$$$ EXTRAFFIC target=...`       | 自流量源启动信息                                               |
| `$$$ EX12-FRAME id=n up_ms=…`    | 仪表盘帧开始（含快照时刻/周期/流量参数）                       |
| `EX12-ST <proto> ...`            | 协议计数行（绝对值+增量），frame 内共 5 行                     |
| `EX12-HEAP free=... min_ever=`   | heap 三件套                                                    |
| `EX12-TASK n=...` + `EX12-T …`   | 任务表头 + 每任务一行                                          |
| `EX12-SYS uptime_s=... ntp=`     | uptime 与 NTP 占位行                                           |
| `$$$ EX12-FRAME-END id=n`        | 仪表盘帧结束                                                   |

## 逐字段解读（核心章节）

### EX12-ST 五个协议段的十个动作

每行格式 `recv=A(+a) xmit=B(+b) drop=C(+c) chkerr=D(+d) memerr=E(+e)`：
`A~E` 是开机以来的**累计值**，括号内是距上一帧的**增量**。下面是每个字段的含义与本环境的真实口径：

| 字段     | 含义               | 本环境的真实口径（重要！）                                                                                                                                                       | 异常时看哪里                                                                                           |
| -------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `recv`   | 该层收到的包数     | **ip/icmp 是最活跃的生命线**；本例自流量每帧给 ip 与 icmp 各推 +30                                                                                                               | ip.recv 不涨而驱动日志刷丢包 → 死在链路层之下（Batch 2：openeth RX malloc 失败丢帧，协议计数器冻结）   |
| `xmit`   | 该层发出的包数     | 应答与请求大致对称（本例 ip.xmit ≈ ip.recv）；TCP 大量 xmit 而 recv 停滞 = 对端没回 ACK，看重传                                                                                  | xmit 长期 > recv 且差距扩大 → 上游丢包或对端死亡                                                       |
| `drop`   | 该层主动丢弃的包数 | 正常稳态恒 0；这是"输入路径走得下去吗"的第一问。注意各层语义不同：tcp.drop 是报文被 tcp_input 验证分支拒收；udp.drop 主要是"无匹配 PCB/长度错"；tcp.memerr 才对应 PCB 耗尽那条线 | link 层看 RX 描述符环与内存；udp 段的 recv 邮箱满丢包是**零痕迹**的（ch10），drop 计不到它             |
| `chkerr` | 校验和错误         | SLIRP 路径下正常恒 0（软件校验和全算对才转发）                                                                                                                                   | chkerr 爬升 = 链路上有坏字节（DMA/驱动 bug、硬件 PHY），先怀疑数据完整性再怀疑协议栈                   |
| `memerr` | 内存不足导致的失败 | 全堆化配置下由 libc heap 兜底，短期洪峰会先打穿它                                                                                                                                | tcp.memerr 爬升的经典剧本：listen PCB 耗尽 → SYN 被静默丢弃（ch23 结论：不发 RST），伴随对端 errno=113 |

### 各协议段在本示例里的"预期形态"

| 段     | 本示例的典型曲线                         | 解读                                                                                                                                                                                                                                                                                                             |
| ------ | ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `link` | **基本冻结**（本 run 开局 +2 后恒 0）    | 不是坏了，是口径问题：openeth 数据路径在 IDF 的 esp_netif 适配层里根本不经过任何 `LINK_STATS_INC(link.*)` 站点（已核对源码：IDF port 与 esp_netif 目录零命中；lwIP 2.2.0-dev 中 link.recv/xmit 只在 loopback/netif_poll 路径计数）。链接层健康要看 ip 段 + 驱动日志，不要盯 link 行                              |
| `ip`   | 每 30s 帧 ±30 对称增长                   | 收发对称说明 SLIRP 双向都在转；只有单边涨 = 回程断了                                                                                                                                                                                                                                                             |
| `icmp` | recv +30 但 **xmit 恒 0**                | 又一个口径知识点：esp_ping 发请求走的是 RAW socket（`ping_sock.c` 里 `socket(AF_INET, SOCK_RAW, IP_PROTO_ICMP)`），自组 echo request **不经过 icmp.c**，所以 `icmp.xmit`（只在 icmp.c 自己组装报文时递增）永远不动；而应答要过 `icmp_input()` 所以 recv 正常涨。"某个计数不涨"不等于"某条路不通"，要看是谁在计数 |
| `tcp`  | 全 0                                     | 正常——本示例零 TCP 流量。这就是"空载基线"的意义：异常检测是拿真实曲线跟自己的基线比，不是跟 0 比                                                                                                                                                                                                                 |
| `udp`  | 绝对值≈2 后冻结（DHCP 一对请求一对应答） | DHCP 之后的静默符合预期；如果哪天 udp.recv 在涨但应用侧收不到数，第一嫌疑是 recv 邮箱满了静默丢包（ch10 结论：netconn/socket 邮箱丢包零痕迹，计数器全然不知情）                                                                                                                                                  |

### EX12-HEAP heap 三件套

| 字段       | API                                      | 含义与口径                                                                                                                                                                           |
| ---------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `free`     | `heap_caps_get_free_size(8BIT)`          | 当前可用总字节数，随分配/释放上下起伏——看趋势不看单点                                                                                                                                |
| `largest`  | `heap_caps_get_largest_free_block(8BIT)` | 最大连续块。**碎片化诊断三联征之一**：free 回涨了但 largest 不涨 = 碎了                                                                                                              |
| `min_ever` | `heap_caps_get_minimum_free_size(8BIT)`  | 历史最低点的**多区域 sum-of-minima**，单调不增。**禁止跨阶段取差**（Batch 6 教训：它是各区各自最小值之和，不是某区连续时间线）；想知道某阶段峰值用量，用"阶段边界 free 差值"而不是它 |

异常排查顺序建议：`free` 掉底（考虑 OOM 分支）→ `largest` 不跟 free 回涨（碎片）→ `min_ever` 逼近临界值（历史最深水位离死多远）。
另注：IDF lwIP 全堆化，`stats_display()` 输出没有 MEM/MEMP 段，内存观测就认这三件套。

### EX12-T 任务表

列含义（每行一个任务，`prio` 降序、名字典序稳定排序，保证帧间 diff 只见数字变化）：

| 列     | 含义        | 关注点                                                                                                       |
| ------ | ----------- | ------------------------------------------------------------------------------------------------------------ |
| 名字   | task 创建名 | 认识系统常驻任务：`tcpip`(18)/`emac_rx`(15)/`esp_timer`(22)/`ipc0/1`(24)/`sys_evt`(20)；本例额外有 `ping`(2) |
| `prio` | 当前优先级  | 抢占关系的地图。想不被饿死，你的工作优先级要压过 tcpip(18)（双核测量陷阱见 ch24）                            |
| `core` | 亲和核      | `0/1`=钉核，`NA`=tskNO_AFFINITY 自由浮动                                                                     |
| `hwm`  | 栈高水位(B) | 运行以来栈剩余的最小字节数，单位是**字节**。太小（逼近 0）= 栈溢出倒计时；掉 0 即已实际溢出                  |

开关依赖：整段需要 `CONFIG_FREERTOS_USE_TRACE_FACILITY=y`，core 列还需要 `CONFIG_FREERTOS_VTASKLIST_INCLUDE_COREID=y`（它们会把 `xCoreID` 字段编进 TaskStatus_t）；不开则该段降级打印 `disabled` 提示。三个开关都写在 `sdkconfig.defaults`（同 ch24 的配置三件套）。

### EX12-SYS uptime 与 NTP 占位行

- `uptime_s`：来自 `esp_timer_get_time()`（微秒精度）。注意**不能换成 `sys_now()`** 做亚秒级时间戳——它在 IDF 里是 10ms tick 网格（CONVENTIONS Batch 4）。
- `ntp=disabled(ntp-line-placeholder)`：NTP 信息行的**缺省占位**。本示例不跑 SNTP（对时模板见 ex07 sntp-clock）；扩展成真时钟源时只需替换这一行的赋值来源，帧格式与其余段落都不动——观测格式的向后兼容就是这么保持的。

## 已知边界与排障

以下均为本机实测特性，**不要把它们当故障**：

1. **MAC filter ioctl 错误 ×3 是预期噪音**（openeth 白名单噪音，见 ex01 README 同款说明），不影响收发。
2. **link 段基本不增长**：口径问题而非故障，详见上文各协议段表格的 link 条目。
3. **icmp.xmit 恒 0**：RAW socket 自组报文不过 icmp.c，同上见表格 icmp 条目。
4. **计数器是 u16**：默认 `LWIP_STATS_LARGE=n` 时 STAT_COUNTER 为 u16_t，高吞吐长跑会在 65535 处回卷。本示例差值按原生宽度回卷计算，单次回卷不影响增量显示；若要 32 位计数器需自行开 `LWIP_STATS_LARGE`（IDF Kconfig 未暴露，要在 lwipopts 层覆盖）。
5. **efuse `-global` 行陷阱**：手工加回 `-global driver=nvram.esp32.efuse,...` 会偶发导致 openeth NIC 未创建、固件在 `esp_eth_mac_new_openeth()` 崩溃复位。套件 runner 已统一去掉该行。
6. **改过 `sdkconfig.defaults` 必须删除生成的 `sdkconfig` 再重新构建**，否则三个 FreeRTOS/LwIP 观测开关不生效（曾踩坑项）。
7. **同刻第二 ping 会话恒超时**（SLIRP 会话边界毛刺）：本示例刻意只挂单个永久会话；要加第二个探针请错开启动时刻或改用 UDP 探针造确定性流量。
8. **QEMU 时钟漂移**：帧间隔以 guest 的 esp_timer 计，TCG 下与宿主墙钟有少量漂移，属仿真常态。

## 文件结构

| 文件                  | 作用                                                                               |
| --------------------- | ---------------------------------------------------------------------------------- |
| `main/main.c`         | bring-up 序列 + 自流量源 + 快照/差分/任务表/heap 打印逻辑（全部逻辑，约 400 行）   |
| `main/CMakeLists.txt` | main 组件声明：`PRIV_REQUIRES esp_eth esp_netif esp_event lwip esp_timer freertos` |
| `CMakeLists.txt`      | root 构建骨架（`MINIMAL_BUILD ON` trim 形态）                                      |
| `sdkconfig.defaults`  | `CONFIG_ETH_USE_OPENETH` + 观测叠加 `CONFIG_LWIP_STATS` + FreeRTOS 任务表三件套    |
| `tools/run_qemu.sh`   | 标准 QEMU 启动器（timeout + tee run.log，无 efuse 行、无 hostfwd，默认 80s）       |
| `run.log`             | 真实运行留存（本文摘录的出处，含两帧完整仪表盘）                                   |
