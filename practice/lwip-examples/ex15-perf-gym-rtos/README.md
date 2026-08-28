# ex15 perf-gym-rtos —— RTOS 调度错误健身房

lwIP 示例套件 ex15：与 ex14 perf-gym-tcp（TCP 配置错误健身房，同套件姊妹篇）
对称的姊妹篇。ex14 让你亲手经历"网络配置坏了→定位→修复"，本工程把杠铃换到了
**RTOS 调度层**：一个固件内建 4 个可切换的错误场景（`CONFIG_GYM_SCENARIO`，0=健康
基线），全部走自动注入时序（起振→注入→观测→解除），每个场景配齐"诊断用的观测
原语"演示——任务表（`uxTaskGetSystemState`）、run-time 统计、邮箱水位代理、栈高水
位步进，所有关键事件都输出机器可读的 `$$$ EX15-ALARM` / `$$$ EX15-RECOVER` 行。

症状不是编造的：四个场景分别复刻《lwIP 深度解析》ch13（tcpip 单线程停摆实验 C/D）
与 ch19（优先级占空比崩塌实验）在本书实验中真实实测过的失败模式。

## 课程主线：心跳是被受害者

固件里有一个健康的双层心跳源，贯穿所有场景：

| 层      | 实现                              | 观测行                      | 衡量什么         |
| ------- | --------------------------------- | --------------------------- | ---------------- |
| RTOS 层 | `ex15_hb` 任务 500ms 一拍         | `EX15-HB`（带 `lag_ms`）    | 调度器还活着吗   |
| 网络层  | esp_ping 无限会话 ping SLIRP 网关 | `EX15-NET` / `EX15-NETTOUT` | 协议栈还在服务吗 |

告警由**旁路观测者**发出：`ex15_watch` 任务 pin core1、prio 21/22，压过 tcpip(18)
——Batch 4/7 双核测量纪律："测量任务优先级要压过 tcpip(18)"。它的存在本身也是一课：
当受害者包括监控自己时（场景 1 的 serial 全程无声），只有活在受害者带宽之外的观测者
才能喊出 ALARM。

每类根因让心跳以不同方式失联，**从失联模式反推调度根因**就是本课程的解法模板：

| 场景 | HB（RTOS 层） | NET（网络层）                | 指纹                                    |
| ---- | ------------- | ---------------------------- | --------------------------------------- |
| sc0  | 满拍 lag=0    | 全应答                       | 健康基线                                |
| sc1  | 整段缺席      | 零超时、零日志               | "暂停"而非"超时"+serial 无声 → 调度饿死 |
| sc2  | 满拍不缺      | NETTOUT 连发 + rttd 应答全灭 | 调度活+网络死 → 单线程堵点（tcpip 内）  |
| sc3  | 满拍不缺      | 正常                         | 延迟进长尾 → 邮箱水位饱和               |
| sc4  | 满拍不缺      | 正常                         | HWM 先于一切崩溃报警                    |

## 网络拓扑

```text
      QEMU guest (esp32) —— 全部负载自环，主机侧零配合
┌─────────────────────────────────────────────┐
│  ex15_hb(5) ──EX15-HB──► console            │
│  esp_ping ──ICMP echo──► 10.0.2.2 (SLIRP gw)│
│        ▲                    │ 回程被堵时的   │
│        │ tcpip_thread(18) ◄─┘ 排队地点 =    │
│  32 槽邮箱 / raw UDP :8320 慢回调 / 饱和水位 │
│                                             │
│  spin_c0(20)●core0   spin_c1(20)●core1      │
│  （sc1 才上场的两个高优自旋者）              │
│  ex15_gym/ex15_watch(21~22)●core1 旁路观测  │
└─────────────────────────────────────────────┘
openeth MAC 52:54:00:12:34:56 · DHCP 得 10.0.2.15/24
端口：8320 号段自环负载为主，无 hostfwd（SPEC §4）
```

## 构建命令

```bash
cd practice/lwip-examples/ex15-perf-gym-rtos
. ~/esp/esp-idf/export.sh

# 场景 N 用变体配置构建到独立目录（注意分隔符是分号；改过 defaults 必须删 sdkconfig 重生成）
SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.sc3" idf.py -B build-sc3 build

# 或一把梭全场景重建+归档（内部逐个校验 EXREADY/EXDONE，输出 runs/scN.log）：
tools/run_all.sh            # 缺省跑 0..4；也可 tools/run_all.sh 2 3 只跑两个
```

`sdkconfig.defaults` 在 openeth 必填项之上叠加三组可观测性开关：
`CONFIG_LWIP_STATS=y`（五段协议计数）、`CONFIG_FREERTOS_USE_TRACE_FACILITY +
VTASKLIST_INCLUDE_COREID + GENERATE_RUN_TIME_STATS=y`（任务表/core 归属/run-time
统计，时钟默认 esp_timer@1MHz）。每个场景另有一行 `sdkconfig.defaults.scN`
（内容仅 `CONFIG_GYM_SCENARIO=n`）；sc3 变体多一行 `CONFIG_EX15_HB_PRIO=19`，
用途见其文件头注释。

## 运行命令

```bash
# 镜像已由 build 步骤生成时可直接运行（默认 110s 覆盖整个注入时间轴）：
BUILD_DIR=build-sc1 LOG=runs/sc1.log tools/run_qemu.sh 110
# timeout 到点退出码 124 属正常截停；进程主动复位退出码 0/-1 也算正常
```

时间轴（所有故障场景共用）：READY → 12s 注入 → 18s/29s 两张诊断帧 → 42s 解除 →
48s/60s 恢复确认帧 → 75s `$$$ EXDONE result=ok ... alarms[...]` 收口。

## 机器可读行协议（CI 可 grep）

| 行                                          | 含义                               |
| ------------------------------------------- | ---------------------------------- |
| `$$$ EX15-FACT`                             | 固件指纹 + 场景与全部参数          |
| `$$$ EXREADY sc=N(...)`                     | DHCP 起播成功（验收断言锚点）      |
| `EX15-HB` / `EX15-NET(TOUT)`                | 双层心跳原始拍                     |
| `== EX15-PHASE name=X ==`                   | 时间轴推进标记（inject/remove 等） |
| `EX15-INJECT phase=in\|out`                 | 注入/解除事件及参数                |
| `$$$ EX15-FRAME id=.. phase=..`…`FRAME-END` | 诊断帧（观测原语打包）             |
| `$$$ EX15-ALARM kind=...`                   | kind ∈ sched/net/mbx/stk           |
| `$$$ EX15-RECOVER kind=...`                 | 对应解除                           |
| `$$$ EXDONE ... result=ok`                  | 观察窗收口 + 四类告警总账          |

诊断帧内的观测原语：

- `EX15-TASK` / `EX15-T`：任务表一行一个任务（状态/优先级/核/HWM/run-time 计数/
  本窗占比 share%），按名字字典序排序保证帧间 diff 不失真；
- `EX15-ST`：lwip_stats 五段计数 snap-diff（LINK/IP/ICMP/TCP/UDP）；tcpip 卡死时
  直接降级为 `disabled reason=tcpip_no_ack wait_ms=1500`——这一行本身就是
  "tcpip 线程 1.5 秒没消化任何消息"的一手证据；
- `EX15-MBX`：邮箱水位代理（try 投递成功率即"未满槽位的实时供给率"）+
  阻塞投递等待分布（背压的一手观测）；
- `EX15-STKSTEP` / `EX15-STKUNWIND` / `EX15-STKDONE`：sc4 填栈步进与回退。

## 五步法课程

每个场景按「症状 → 诊断 → 根因 → 修复 → 前后数据」组织。健康基线参照系
（runs/sc0.log）：150 拍心跳全部 `lag_ms=0`，76 发 ping 全部应答 rtt≤1ms，
四类告警全 0，IDLE0/IDLE1 占比各约 49.9%。

### 基线帧怎么读（ex12 仪表盘的增量口径）

```text
$$$ EX15-FRAME id=1 phase=baseline rel_ms=1501 sc=0-healthy-baseline fault=0
EX15-HBSUM beats=3 last_gap_ms=2 alarms_sched=0
EX15-NETSUM ok=2 tout=0 consec=0 rtt_last=0 rtt_min=0 rtt_max=1 alarms_net=0
EX15-TASK n=12 order=name_asc clock=esp_timer-1MHz
EX15-T IDLE0            st=ready    prio= 0 core=0  hwm= 1088 rt_us=2607753    win_ms=2607 share=48.7%
...
EX15-T tcpip            st=blocked  prio=18 core=NA hwm= 2328 rt_us=24263      win_ms=24 share=0.4%
EX15-HEAP free=262140 largest=139264 min_ever=258836 cap=MALLOC_CAP_8BIT
```

（摘自 runs/sc0.log。）任务表是全书实测地图的重现：tcpip prio18 栈高水位 2328B、
NO_AFFINITY——与 Batch 4 实测值完全一致。

### 场景 1 · 优先级倒挂饿死监控（sc1）

1. **症状**：t+12s 起控制台除了周期 HB 缺席外一片死寂——没有报错、没有 panic。
   `EX15-HBSUM beats=24 last_gap_ms=17512`：心跳停在注入那一刻；NETSUM 显示
   ping 一个都没超时。两核各被一个 prio20 自旋任务钉死（`EX15-INJECT phase=in
event=spinner_pin_both_cores prio=20 duty=100`）。
2. **诊断**：旁路看门狗 2.5s 后升旗 `$$$ EX15-ALARM kind=sched gap_ms=2502`。
   故障窗诊断帧拿到定罪现场：`spin_c0/spin_c1 各吃掉本窗 49.9% 共 ~100%，
IDLE 占比 0%，tcpip win_ms=0`；同时 `EX15-ST disabled reason=tcpip_no_ack`
   证明协议栈也在挨饿。
3. **根因**：高优先级×时长×频率的伤害公式；prio 自旋钉核的占空比 70%~85% 是存活
   分水岭，100% 全灭且 serial 无声（ch19 实验 C；CONVENTIONS Batch 5）。独占 CPU
   时连 esp_ping 的超时回调都不再执行——所以网络心跳表现为"暂停"而不是"超时"，
   日志静默本身就是线索。
4. **修复**：给低优工作留出确定性空隙（降占空比/削峰）、控制面与测量探针钉在
   受害者带宽之外（本工程的 ex15_gym/watch 即此设计，见 ch19 ctrl_srv 教训：
   "spinstop 曾被自己的注入卡住"）。真实系统中再加 TWDT 兜底。
5. **前后数据**：解除后 `EX15-RECOVER kind=sched gap_back_to=234ms
beats_missing=60`；恢复期可见心跳快速补拍的"时间债清偿"曲线；EXDONE 总账
   `alarms[sched=1 net=0]`，网络层自始至终零丢账。想复测分水岭把
   `CONFIG_EX15_SC1_DUTY_PCT` 调到 70/85 再跑即可。

### 场景 2 · raw 回调里做慢操作拖死协议栈（sc2）

1. **症状**：t+12s 绑定 8320 端口的 raw UDP 回调开始每次 busy-wait 900ms
   （`EX15-INJECT arm event=udp_raw_bound port=8320 busy_ms=900`）。14.8s 起
   `EX15-NETTOUT consec=1/2` 连发，网关心跳判死。
2. **诊断**：判别性一眼——`EX15-HBSUM beats=36 last_gap_ms=251`：调度层毫发无损
   （500ms 心跳一拍不落、lag<320ms），死的只有经 tcpip 线程的一切。这就是
   "单线程堵点"指纹：凶手不在调度表里，在被投进同一个线程的某段代码里。
   `EX15-SLOWCB enter hits=N busy_ms=900 (running INSIDE 'tcpip' -- whole stack
stalls)` 直接指认现行。
3. **根因**：一切 raw 回调/sys_timeout 都在 tcpip_thread 内执行；回调睡觉＝全栈
   停摆（含 ICMP/TCP/定时器），3 秒卡死使 ICMP 会话零进展、echo 建连 9ms→2955ms
   （ch13 实验 C；CONVENTIONS Batch 4 单线程停摆实证）。附带教训：泵任务的
   socket send 也被拖住——`EX15-PUMP exit sent=121 slow_sends=35 avg_slow_ms=846
max_ms=905`，阻塞沿传导链爬回了应用层。
4. **修复**：回调只做无阻塞的最小动作，重活交给 `tcpip_callback()` 投递的工作队列
   任务；确实要长时间持有时分段检查取消闸门（本工程 `burn_ms_checked` 的
   分片模式即是范例，解除注入后 ≤50ms 内释放线程）。
5. **前后数据**：`$$$ EX15-RECOVER kind=net downtime_ms=27260 lost_during=0
ok_total=14`；EXDONE `alarms[sched=0 net=1] hb_beats=150`——RTC 层心跳全程
   150/150 满，证明"死的是协议栈线程，不是调度器"。

### 场景 3 · tcpip 邮箱打满传导（sc3）

1. **症状**：t+12s 三个生产者任务开始向全局唯一邮箱高频投递回调，容量探针立刻给出
   教科书数字：`EX15-MBXEV kind=capacity_probe posted=64 accepted=34 rejected=30`
   ——接受数≈TCPIP_MBOX_SIZE=32（此刻已有在途消息占用若干槽位）。此后
   try_full 以每秒上万的速度累积。
2. **诊断**：两张故障帧读出稳定水位：`EX15-MBX mode=flooded try_ok=14307(+14307)
try_full=210459(+210459) satur=93.6% blk_n=21 blk_avg_us=294 blk_max_us=1628`。
   失败即返（tcpip*try_callback→ERR_MEM）就是实时水面标尺；pacemaker 每 300ms 的
   阻塞投递则量出背压等待分布（均值百微秒级、尾部 ~1.6ms）。读法：\*\* satur 是
   "邮箱不健康的瞬时占比"，blk*\* 是"投递方正在为拥挤付多少税"\*\*。
3. **根因**：邮箱硬容量唯一约束是 `CONFIG_LWIP_TCPIP_RECVMBOX_SIZE`(32)——IDF 全堆化
   后 MEMP_NUM_TCPIP_MSG_API 票闸不生效（ch13 实验 D；CONVENTIONS Batch 4）。
   两种语义的分野：`tcpip_callback` 给调用者施压（背压，最坏把自己也拖下水），
   `tcpip_try_callback` 给调用者决定权（丢弃，失败分支必须自己处理）。
   INPKT 走 trypost——把洪峰换成网络包，邮箱满＝真实报文被丢弃。
4. **修复**：为高频路径减负/合并投递；消费者侧避免人为加重消化（本场景用
   `CONFIG_EX15_SC3_WORK_US=400` 模拟"真实消息带工作量"，这是诚实前提）；
   测量探针先于业务做好优先级隔离——sc3 变体专设 `CONFIG_EX15_HB_PRIO=19`
   压过 tcpip(18)，否则满负荷的 tcpip 会连带饿死低优心跳，故事就串台成 sc1
   了（Batch 4/7 纪律的应用；首轮不带此旋钮的试验确实打出过 5 次
   kind=sched 假警报）。
5. **前后数据**：解除后工人退场对账 `EX15-FLOODER exit id=0 ok=23401 fail=341963`
   （单工人 accept 率 ~6.4%），两个静默确认拍后
   `$$$ EX15-RECOVER kind=mbx quiet_ticks=2 final_try_full=1025552`；EXDONE
   `alarms[sched=0 net=0 mbx=1]`，心跳与 ping 全程无恙——伤情被精确限制在邮箱维度。

### 场景 4 · 任务栈余量耗尽告警（sc4）

1. **症状**：专用受害者 `ex15_stkburn`（4096B 栈）每 400ms 递归一层、每层吃掉
   288B（256B 数组+调用开销），EX15-STKSTEP 行实时直播余量下潜：
   `lvl=8 hwm_free=956` → crossing！
2. **诊断**：越线的瞬间告警：`$$$ EX15-ALARM kind=stk task=ex15_stkburn hwm=956
below=1024 lvl=8`。这里教的第一件事是**告警阈值设计点要选在危险之上**：
   阈值 1024 高于绝对护栏 `STOP_MARGIN=768`，留出"发现→响应"窗口；若把阈值设在
   地板之下，永远轮不到告警就先撞墙了。
3. **根因与一次真实事故**：首版地板只有 192B，lvl=11 余 92B 后继续在栈上 printf
   （自身要几百字节）——真溢出了，Backtrace 里赫然出现
   `0xa5a5a5a5 |<-CORRUPTED`（正是我们 memset 的填充图案写穿了返回地址）。
   教学目标定在告警而非崩溃表演，故地板提到 768B 并写进 Kconfig help。
   另一处必考知识点：HWM（usStackHighWaterMark）是**单调的历史最低值**——弹栈不
   回血，`hwm_final=380 min_seen=668`（收尾打印自己又把瞬时余量打到过 380 并计入
   极值），想归零只能重建任务。
4. **修复**：栈深审计 + 合理预留 + 上电自检打印 HWM（本工程诊断帧的 hwm 列）+
   阈值告警＋（真机）stack canary/TWDT。演示收尾用行动教学：
   `round1_min_seen=668 round2_fresh_initial_hwm=3628`——重建任务后 HWM 从满格
   重新开始。
5. **前后数据**：EXDONE `alarms[sched=0 net=0 mbx=0 stk=1]`；全程心跳 150/150、
   ping 零超时——栈耗尽型风险靠 HWM 预警，不需要等到任何功能挂掉才能看见。

## 已知边界与排障

- **并行纪律**：QEMU 必须 kill 精确 PID（按 cmdline 特征过滤），禁止 pkill——仓库
  里有并行作者实例（CONVENTIONS Batch 3 起）。tools/run_qemu.sh 头部给了模板。
- **镜像时效**：换场景重编译后务必确认 `$` EX15-FACT 的 `build="..."` 时间戳变化；
  疑似烧旧镜像时手动 merge-bin 兜底（Batch 6）。
- **sdkconfig 陷阱**：五个场景共用工程根部的 `sdkconfig` 文件（`idf.py -B` 不改它
  的位置）。手工切换场景请先 `rm -f sdkconfig` 再 build，否则新默认值不生效、
  会拿旧场景参数跑出新场景名（本项目所有坑都替你踩过了一遍，run_all.sh 已内置）。
- **心跳探测单会话**：网络心跳只用一个 esp_ping 会话且永不重建（SLIRP 同刻第二会话
  恒超时，ch3/ch10 经验）；ICMP 只能 guest 发起，主机→guest ICMP 不可达是 SLIRP
  硬边界不是本工程的缺陷。
- **自环路径**：sc2 的触发流量发往 127.0.0.1:8320（lwIP 把 loopback 内建于 ip4_route
  特判，Batch 3）；发往自身网卡 IP 反而出网卡被 SLIRP 吞掉——本地短路的只有回环。
  裸 `send()` 对未连接 UDP socket 会直接失败（errno 路径已在泵任务里如实打印）。
- **QEMU 计时口径**：宿主负载可使吞吐/延迟漂移 ±50%（Batch 4），对比实验请同时段
  开机配对；本工程所有结论都以"同一开机内的相对对照"给出。
- **实时统计时钟**：run-time stats 默认 esp_timer@1MHz，约 4290s 回卷；本工程窗口
  75s，不受影响。LWIP_STATS 关闭时诊断帧相应段落自动降级提示，不影响场景叙事。

## 目录结构

```text
ex15-perf-gym-rtos/
├── main/main.c               # 全部逻辑（骨架/观测原语/四场景/编排器，注释即文档）
├── main/Kconfig.projbuild    # GYM_SCENARIO 与时间轴/各场景旋钮
├── sdkconfig.defaults        # openeth + 三组可观测性开关
├── sdkconfig.defaults.sc0~4  # 场景变体（sc3 附带心跳提权说明）
├── tools/run_qemu.sh         # 去 efuse -global 行标准形态 runner（SPEC §3）
├── tools/run_all.sh          # 全场景重建-出图-运行-校验一条龙
├── runs/sc{0..4}.log         # 最终固件的五轮完整实测归档
└── run.log                   # 基线轮留存（= runs/sc0.log）
```

生成于《lwIP 深度解析》与 FreeRTOS 系列沉淀之上的示例套件成员之一；
根因条目均已标注出处章节/批次，欢迎按标注回溯一手实验记录。
