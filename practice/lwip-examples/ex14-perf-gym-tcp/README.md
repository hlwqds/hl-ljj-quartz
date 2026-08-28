# ex14 perf-gym-tcp —— TCP 配置错误健身房

lwIP 示例套件 ex14：**一个固件内建四个可切换的错误配置场景**，跑同一套基准负载，
让使用者亲手走完「性能坏了 → 用观测原语定位 → 找到根因 → 修复 → 前后数据对比」的
闭环。所有数字都来自本仓 QEMU（openeth + SLIRP）真实实测，归档在 `runs/`，
每条引用都可以 grep 复核——严禁编造是套件的一票否决项。

与 ex15（RTOS 调度健身房）互为姊妹篇：那边练调度器病，这边练协议栈配置病。

## 场景总表

| #   | 名字                   | 病根（哪一层）                     | 预设坏档                 | 修复方式                         |
| --- | ---------------------- | ---------------------------------- | ------------------------ | -------------------------------- |
| 0   | baseline               | 无（对照口径）                     | `sdkconfig.defaults.sc0` | —                                |
| 1   | tiny-window            | SND_BUF/WND 压到 2×MSS             | `sdkconfig.defaults.sc1` | 回基线口径（含一次"负结果"教学） |
| 2   | wide-window-small-ring | 大窗 × 小环（RX 环深 4）           | `sdkconfig.defaults.sc2` | 窗口退回工作区                   |
| 3   | missing-tcp_sent-hook  | raw 泵漏挂 tcp_sent 回调（代码级） | `sdkconfig.defaults.sc3` | 恢复回调注册（≈切回场景 0 形态） |
| 4   | pcb-gate-2             | MEMP_TCP_PCB 计数闸 = 2            | `sdkconfig.defaults.sc4` | 恢复默认 16                      |

## 网络拓扑

```text
      宿主机 (Fedora)                                   QEMU guest (esp32)
┌─────────────────────────────┐                 ┌──────────────────────────────────┐
│ tools/gym_echo.py  :8312    │◄═══ 双工镜像 ═══►│ LB 腿：select 全双工泵            │
│ (duplex 反射器, 收到即回发)  │    guest 发起    │ （up=发送口径 dn=回程到达口径）    │
│                             │                 │                                  │
│ tools/gym_sink.py  :8311    │◄─── TX 腿 ──────│ raw API 发送泵                    │
│ (读到底→digest→回 'K')       │    guest 发起    │ tcp_write/output + sent/poll 回调 │
│                             │                 │                                  │
│ tools/gym_flood.py ─────────┼──hostfwd:8310──►│ RX 腿监听口（'R'/'K' 应答位）      │
│ [sc4] nc×4 → 127.0.0.1:8310 │   (宿主主动)     │ ↑ 入向 SYN 在满池时被静默丢弃      │
└─────────────────────────────┘                 └──────────────────────────────────┘
        10.0.2.2 = SLIRP 网关（落宿主 loopback 同端口）      guest IP: 10.0.2.15/24

端口归属（SPEC §4 号段 8310/8311；8312 为镜像反射器口）：
  - 8310  guest 监听，QEMU 参数必须带 hostfwd=tcp::8310-:8310
  - 8311  guest 外连宿主 sink（无需 hostfwd 配合）
  - 8312  guest 外连宿主反射器（LB 腿）
```

> **为什么"自环腿"要绕道宿主机？** 本环境实测发现：凡是目的地为自身 IP 的 TCP 流量
> 都会被 ip4_route 送进 lwIP 内建回环队列（`netif_loop_output`），而该路径在持续
> 吞吐下会把 tcpip 线程咬死——gdb 现场取证两次，卡点分别在 `pbuf_free` 与
> `sys_mutex_unlock(g_lwip_protect_mutex)`（见排障节 §9.1）。所以 LB 腿采用
> 「经 SLIRP 的镜像回声」：引擎不变、对端换成宿主反射器，教学价值不变。

## 构建命令

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-examples/ex14-perf-gym-tcp

# ── 切场景标准三步（Batch 1 教训：跳步必翻车）──────────────────
# cp sdkconfig.defaults.scN{,.fixed} sdkconfig.defaults   # 选坏档或修档
# rm -f sdkconfig          # ← 必须删！defaults 只在 sdkconfig 缺席时生效
# idf.py build             # 重新生成全量 sdkconfig
# ─────────────────────────────────────────────────────────────
idf.py set-target esp32   # 仅首次
idf.py build

# 生成 QEMU flash/efuse 镜像（monitor 无 TTY 失败属预期，镜像已生成）：
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在
```

⚠ 场景切换**全部走构建期**。开机第一行机器可读指纹会打印生效值供核对：

```text
$$$ EX14FACT build="Aug 27 2026 19:44:49" scenario=1 name=tiny-window mss=1440 \
    snd_buf=2880 wnd=2880 openeth_ring=4 max_active_tcp=16 lwip_stats=1
```

若 FACT 行与你以为的场景不符，先怀疑残留的旧 `sdkconfig`，回看三步警告。

## 运行命令（完整可复制）

三个宿主工具各开一个终端（或用 `&` 后台）：

```bash
cd practice/lwip-examples/ex14-perf-gym-tcp/tools
python3 gym_echo.py                      # 8312 反射器，LB 腿对端（常驻）
python3 gym_sink.py --conns 2            # 8311 接收器，TX 腿对端（--conns=轮数）
python3 gym_flood.py --rounds 2 --mb 2   # hostfwd 灌流器，RX 腿发起方
```

QEMU 启动（统一去 efuse `-global` 行的 runner 形态，SPEC §3）：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 90 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8310-:8310 \
  -nographic -no-reboot 2>&1 | tee run.log
```

结束行为：固件打完 `$$$ EX14DONE` 后主动 `esp_restart()`，配合 `-no-reboot`
进程干净退出（exit=0）；超时截停 exit=124 也算正常（CONVENTIONS §3）。

**场景 4 追加步骤**：探针进入 `inbound-syn-drain` 窗口时（日志出现该行），
宿主打几条短连接进 guest 触发入向 SYN 静默丢弃：

```bash
for i in 1 2 3 4; do timeout 3 nc 127.0.0.1 8310 </dev/null >/dev/null 2>&1; done
```

## 机器可读标记一览（CI 化抓手）

| 标记                                  | 含义                                                               |
| ------------------------------------- | ------------------------------------------------------------------ |
| `$$$ EX14FACT`                        | 编译期配置指纹（scenario/snd_buf/wnd/ring/max_active_tcp）         |
| `$$$ EX14PROFILE`                     | 本次 profile 的腿组合、轮数、单轮字节数、端口                      |
| `$$$ EX14VERDICT key=`                | 开机四项确定性体检：window_small / wnd_ring / pcb_gate / sent_hook |
| `$$$ EX14NETUP`                       | DHCP 完成，拿到 10.0.2.15                                          |
| `$$$ EX14LB_LISTEN`                   | 镜像腿参数（port/backlog）                                         |
| `$$$ EX14ROUND r=N leg=… begin`       | 轮次/腿切换锚点                                                    |
| `$$$ EX14LB r=`                       | 镜像腿结果（up/dn 吞吐 + 双向 digest match）                       |
| `$$$ EX14TX r= … SNAP`                | raw 泵每 5s 采样：written/win_mbit/sent_hits/poll_hits/min_sndbuf  |
| `$$$ EX14TX r= … RESULT`              | 泵结算：状态机终态 + sent_hits（healthy 主通路命中数）/ack 流水    |
| `$$$ EX14RX_LISTEN` / `$$$ EX14RX r=` | hostfwd 入向腿（PEER_DOWN=宿主工具缺席）                           |
| `$$$ EX14CONC`                        | sc4 探针逐尝试行 + PHASE 行 + SUMMARY 判决行                       |
| `$$$ EX14STATS`                       | lwip_stats 差分快照（tcpip_callback 同步取样，ex12/ex13 手法）     |
| `$$$ EX14HEAP`                        | heap 三件套 free/largest/min_ever                                  |
| `$$$ EX14WD`                          | 看门狗心跳（每 5s 一行，用于冻结类故障的现场取证）                 |
| `$$$ EX14SUMMARY`                     | 全场汇总（各腿均值/完成数）                                        |
| `$$$ EX14DONE`                        | 收官行；缺失说明被截断或异常                                       |

方法学（ch6/Batch 4 沉淀）：双计时口径（guest esp_timer µs 网格 vs 宿主
time.monotonic()）、Fletcher-16+64KiB xorshift32 图样两端同构、同开机交错轮次
（QEMU 吞吐受宿主负载 ±50% 摆动，跨机不作数）。**口径警示**：LB 腿的 up 是
"本地栈吸收口径"、dn 是"回程到达口径"，两者天然不对称；吞吐主战场看 TX/RX 腿。

---

## 五步法课程

### 场景 1 · tiny-window —— 第一课：症状缺席 ≠ 配置健康（负结果课）

**第 1 步 症状**：……没有症状。这正是本题。
按 BDP 教条，SND_BUF/WND=2880（2×MSS）×毫秒级 RTT 应把外环打到个位数 Mbit；
但 SLIRP 宿主内路径的真实 RTT 是**亚毫秒级**（Batch 4 实测空闲 RTT ~103µs），
BDP 小到 2880B 窗口照样喂饱管道。

**第 2~3 步 工具与读数**（`runs/sc1-broken.log`）：

```text
$$$ EX14VERDICT key=window_small predicted_broken snd_buf=2880 wnd=2880 mss=1440
$$$ EX14TX r=1 RESULT status=COMPLETE bytes=2000000/2000000 xfer_ms=147 mbit=108.844 sent_hits=1386 ...
$$$ EX14SUMMARY scenario=1 rounds=2 lb_ok=2/2 avg_lb_up=22.15 avg_lb_dn=21.02 | tx_complete=2 ... avg_tx_mbit=115.96 | rx_ok=2/2 avg_rx_mbit=70.28
```

开机体检说 predicted_broken，实测三腿全绿。"预测"和"读数"打架时，**信读数**。

**第 4 步 根因**：不是窗口没生效（FACT 行证明 2880 已编译进镜像），而是这条路径
没有足够 RTT 让"窗口÷RTT"成为约束项。理论病灶需要匹配的环境条件才发作。

**第 5 步 修复与前後数据**（`runs/sc1-fixed.log`）：回到基线口径 5760/5760，
数字依旧全绿（avg_tx_mbit=82.49 / avg_rx_mbit=80.29）——修复动作验证的是
"无害化"，不是"提速"。

**加餐（把负结果变成金子）**：排障时曾试过"抬窗到 11520 并把环深设成恰好够的 16"，
结果 RX 腿当场掉进黑洞（`runs/annex-boundary-wnd11520-ring16.log`）：

```text
$$$ EX14FACT ... snd_buf=11520 wnd=11520 openeth_ring=16 ...
$$$ EX14RX r=1 RESULT status=OK got=2000000/2000000 wait_ms=90 xfer_ms=6306 mbit=2.537
```

两个教训打包带走：① 别背教条，环境变了先重测基线；② 不等式的**边界值不稳**，
留余量要给足（衔接场景 2）。

### 场景 2 · wide-window-small-ring —— 头号调优地雷：大窗小环黑洞

**第 1 步 症状**（`runs/sc2-broken.log`）：症状是**选择性**的——

```text
$$$ EX14VERDICT key=wnd_ring predicted_blackhole wnd=28800 ring=4 need_ring=32 detail=WND>=28800-requires-ring>=32(ch24/Batch5)
$$$ EX14LB r=1 RESULT status=OK conn_ms=18 up_mbit=21.62 dn_mbit=0.09 up_ms=97 dn_ms=22216 up_digest=3281 dn_digest=3281 match=1
$$$ EX14TX r=1 RESULT status=COMPLETE bytes=2000000/2000000 xfer_ms=192 mbit=83.333 sent_hits=1280 poll_hits=0 acked_app=1971360 min_sndbuf=0 k=0 digest=c546 err=0 stage=done_ok
$$$ EX14RX r=1 RESULT status=PEER_DOWN waited_s=25
```

出方向的 TX 腿 83 Mbit 生龙活虎，回程方向却被钉死在 **0.09 Mbit**（22 秒爬完
256KB！），RX 腿甚至连握手都没能在预算内完成（PEER_DOWN——灌流器的就绪预算被
慢速摄入拖穿）。哪个方向死、哪个方向活，本身就是定位证据：**死的全是要经过
openeth RX 描述符环的方向**。

**第 2 步 工具**：EX14FACT 确认旋钮真实生效；EX14STATS 看 `d_link.recv` 是否还在
增长（帧还在进，只是进得慢）；换算杆是 Batch 5 的「窗口×RX 环深不等式」：
WND≥11520 需环≥16，WND≥28800 需环≥32，只拧窗口不抬环必翻车。

**第 3 步 读数的关键比对**：同 boot 内 TX/RX(转回程) 数字差了三个数量级，而
ch24/Batch 5 记录的同款配方（大窗+小环）现象一致——黑洞性质可复现，不是玄学。

**第 4 步 根因**：openeth RX 描述符环默认 4 个 1600B 缓冲（IDF Kconfig 默认），
洪峰到达速率超过"环回收 + 协议栈搬运"的服务能力后，描述符供不上、帧排队丢给
INT_BUSY，窗口再大也只是让栈"想收而收不到"。出处：Batch 5/ch24（CONVENTIONS §6）。

**第 5 步 修复与前後数据**（`runs/sc2-fixed.log`）：
我们把教科书公式试了两层，两层结论都有价值——

```text
a) 抬环到 32（不等式要求的值）→ 依然黑洞（runs/annex-ring32-cure-fails.log）：
   $$$ EX14LB r=1 RESULT status=OK conn_ms=14 up_mbit=51.15 dn_mbit=0.11 ...
b) 把窗口退回 4×MSS 工作区（交付的 .fixed 档）→ 立刻恢复：
   $$$ EX14RX r=1 RESULT status=OK got=2000000/2000000 wait_ms=1720 xfer_ms=225 mbit=71.221
   $$$ EX14RX r=2 RESULT status=OK got=2000000/2000000 wait_ms=92 xfer_ms=190 mbit=84.428
```

| 口径           | broken(28800/ring4) | ring32 公式修复 | 工作区修复(5760)     |
| -------------- | ------------------- | --------------- | -------------------- |
| LB 回程        | **0.09 Mbit**       | 0.11 Mbit       | 1.42–1.64 Mbit       |
| RX 腿(hostfwd) | PEER_DOWN           | —               | **71.2 / 84.4 Mbit** |
| TX 腿          | 102.7 Mbit 均值     | —               | 72.5 Mbit 均值       |

结论升级：不等式在本环境是**必要条件而非充分条件**——窗口大到 20×MSS 量级后，
SLIRP/openeth 联合管道给不出吸纳速率，环再深也填不满。工程答案：旋钮成对规划、
实测验收，别信单点公式。

### 场景 3 · missing-tcp_sent-hook —— 复刻 ch6 真 bug：涓流的诞生

**第 1 步 症状**（`runs/sc3-broken.log`）：连接建立一切正常、digest 校验都能过，
但吞吐涓流：

```text
$$$ EX14TX r=1 SNAP t_ms=5099 written=326880/2000000 win_mbit=0.51 sent_hits=0 poll_hits=10 min_sndbuf=0 acked_app=0
```

**第 2 步 工具**：泵自身的遥测就是显微镜——`sent_hits`（ACK 驱动的补发主通路命中
计数）、`acked_app`（应用可见的确认流水账）、`poll_hits`（500ms 级兜底慢车道）、
`written` 的步进形状。

**第 3 步 读数**：`sent_hits=0` 且 `acked_app=0` **全程冻结**，同时 `written` 以
恰好 SND_BUF=5760 字节为台阶、每 500ms 一格缓慢爬升（poll_hits 每 5s +10——
正是 tcp_poll 兜底节拍的频率）。 ACK 明明在网络上飞（对端 digest 都能对上：
c546），应用却永远不知道。

**第 4 步 根因**：raw API 的补发有两条路——主通路是 `tcp_sent()` 回调随 ACK 即时
触发 `pump_fill()`（健康档这一项的命中数是 sent_hits≈1386 ≈ 总字节/MSS）；辅通路
才是 `tcp_poll()` 的百毫秒级轮询。漏挂注册行后应用层失去主通路，只剩慢车道
节拍驱动，量化出来就是 0.55 Mbit vs 健康 95 Mbit ≈ **170 倍差距**。这是 ch6
真实踩过的坑（Batch 2：「发送泵必须注册 tcp_sent() 回调，否则吞吐涓流」）。
代码位置：`main/main.c` 中唯一一处条件编译
`#if SCN != 3 → tcp_sent(tpcb, pump_sent_cb)`。

**第 5 步 修复与前後数据**（`runs/sc3-fixed.log`）：把注册行还回来即可
（交付等价操作 = 切回场景 0 形态重建，因此 FIX 档的 FACT 行显示 scenario=0）：

```text
$$$ EX14VERDICT key=sent_hook present detail=ack-driven-refill-on
$$$ EX14TX r=1 RESULT status=COMPLETE bytes=2000000/2000000 xfer_ms=194 mbit=82.474 sent_hits=1384 poll_hits=1 acked_app=1994400 ...
```

| 口径              | broken(sc3)     | fixed               |
| ----------------- | --------------- | ------------------- |
| TX effective rate | **0.554 Mbit**  | 82.5–108.1 Mbit     |
| sent_hits         | 0（主通路死亡） | 1384（逐 MSS 补发） |
| acked_app         | 0 冻结          | 1994400 流动        |

附产证据：`runs/sc3-broken-sink-host.log` 里宿主端收到的是绵延 29 秒的细水。

### 场景 4 · pcb-gate-2 —— 计数闸下的静默处决

**第 1 步 症状**（`runs/sc4-broken.log`）：新连接无声无息地不响应，某些路径直接
报内存错——而且两种死法都会出现在同一份档案里。

**第 2 步 工具**：PCB 池算术表 + 探针逐尝试行 + memerr 差分。开机体检直接背书：

```text
$$$ EX14VERDICT key=pcb_gate predicted_broken max_active_tcp=2 detail=list+client+child-minimum-is-3-pcbs(Batch2)
```

**第 3 步 读数**（池 = listen(:8310) 占 1 格 + 探针逐个持有 socket）：

```text
$$$ EX14CONC attempt=1 op=connect result=SUCCESS echo_check=PASS -- holding-socket
$$$ EX14CONC attempt=2 op=connect result=SUCCESS echo_check=PASS -- holding-socket
$$$ EX14CONC attempt=3 op=socket_alloc result=FAIL errno=105(No buffer space available) elapsed_ms=2
$$$ EX14CONC PHASE=inbound-syn-drain window_s=6 expect=host-nc-to-8310
$$$ EX14STATS phase=conc_post_diff d_link.recv=1 d_tcp.xmit=8 d_tcp.recv=9 d_tcp.drop=0 d_tcp.memerr=3
$$$ EX14CONC SUMMARY attempts=3 ok=2 silent_drop=0 alloc_fail=1 memerr_delta=3 verdict=starved
```

两个铁证并排：① 第 3 次 socket 创建当场 `ENOBUFS`——`MEMP_TCP_PCB` 计数闸是 IDF
lwIP 里**唯一起作用的 PCB 上限**（PBUF_POOL_SIZE 的名义上限并不生效，Batch 2）；
② 排水窗里宿主打入 4 条短连接，`d_tcp.memerr` 精确 +3——满池状态下
`tcp_listen_input` 分配 child PCB 失败，**静默丢弃 SYN 不回 RST**
（源码 `lwip/src/core/tcp_in.c`，ch5/ch10 同款现象，nc 端表现为无响应超时）。

**第 4 步 根因**：一票难求的池子里，listen PCB 也占格。MAX_ACTIVE_TCP=2 时
"listen(1)+client(1)" 就已打满，任何第三者——无论是本地新建 socket 还是入向
SYN 要生的 child——都被静默处决。accept 侧偶见 errno=113(EHOSTDOWN) 的错位语义
也是这个家族的（Batch 2 错误账本）。

**第 5 步 修复与前後数据**（`runs/sc4-fixed.log`）：恢复默认 16 后同款探针：

```text
$$$ EX14FACT ... scenario=4 name=pcb-gate-2 ... max_active_tcp=16 ...
$$$ EX14CONC attempt=3 op=connect result=SUCCESS echo_check=PASS -- holding-socket
$$$ EX14CONC SUMMARY attempts=3 ok=3 silent_drop=0 alloc_fail=0 memerr_delta=0 verdict=healthy
```

注意 FIX 档的 scenario 仍标 4——坏的是旋钮不是代码，tag 只负责挑 profile 与病历本。

---

## 已知边界与排障（排障过程的实录沉淀）

### 9.1 本环境的头号工程发现：别用 127.0.0.1 打流量

开发本示例过程中，guest 内自环回声服务器模式在持续吞吐下会随机把整个系统咬死
（包括 tcpip 线程、所有任务、UART 输出）。gdb 附着取证两次独立样本：

```text
#0 _WindowUnderflow8 () ... xtensa_vectors.S:2166
#1 pbuf_free (...) pbuf.c:801
#2 tcp_input (...) tcp_in.c:582
#3 ip4_input (inp=0x3ffc8714 <loop_netif>) ...
#5 netif_poll (netif=0x3ffc8714 <loop_netif>) netif.c:1317
```

```text
#2 sys_mutex_unlock (pxMutex=0x3ffc8f30 <g_lwip_protect_mutex>) sys_arch.c:79
#4 netif_loop_output (netif=0x3ffcdd80 ...) netif.c:1212
```

凡是目的地址为自身 IP 的报文都走 `netif_loop_output` 内建回环队列（ip4_route 的
特殊分支，Batch 3 记录过 loopif.c 已内建于 ip4_route）。高吞吐下该路径会撞上
致命态——这属于 QEMU 环境 + lwIP 组合的深层缺陷，与业务代码无关（把回声改为经
SLIRP 外部反射后稳定性问题完全消失）。与 ch22 悬案②「guest loopback 仅第一条
连接可用」同族。**给后人的行规：在这套 QEMU 环境做 TCP 性能实验，流量一律走
外部路径（10.0.2.2 或 hostfwd），不要打自身 IP。**

### 9.2 第二课：回调里 printf = UART 背压地狱

调试中途曾在 `pump_sent_cb` 里加过逐 ACK 打印——瞬间把整条泵打成涓流并连带拖垮
系统节拍。tcpip 线程里的每一次控制台写都在消耗 115200 波特的串口预算；教训固化：
**回调里只动计数器，遥测交给别的任务读数打印**（main.c 注释同款警告）。

### 9.3 其他排障速查

- **NIC 未创建/启动崩溃**：检查 QEMU 命令是否带 `-global driver=nvram.esp32.efuse,...`，
  统一用去 efuse 行形态（Batch 4 实录；SPEC §3 模板已是安全形态）。
- **改了旋钮没生效**：没删 `sdkconfig`。以 `$$$ EX14FACT` 打印值为准。
- **RX/TX 腿 PEER_DOWN**：不是固件的错，是对应宿主工具（gym_flood/gym_sink）没起
  或端口被占（启动 QEMU 前先 `ss -tlnp | grep 8310`）。
- **幻影连接**：SLIRP hostfwd 会先于 guest 监听放行宿主 connect，所以接入方必须
  等 guest 的 'R' 发令枪再灌流（ex11 验证过的手法，本例 flood 工具已内置）。
- **并行实验杀进程**：禁止 pkill；按 PID 或专属特征精确清理，避免误伤同机其他
  作者实例（本次开发中曾误伤一个并行 QEMU 实例，特此记录教训）。
- **日志 >1MB 截断政策**：本示例所有归档均在 250 行以内，未触发截断需求。

## 文件清单

```text
ex14-perf-gym-tcp/
├── CMakeLists.txt / main/{CMakeLists.txt,Kconfig.projbuild,main.c}
├── sdkconfig.defaults            # = sc0 基线（构建入口）
├── sdkconfig.defaults.sc0        # 场景 0 对照档
├── sdkconfig.defaults.sc{1..4}   # 四个坏档
├── sdkconfig.defaults.sc{1..4}.fixed  # 四个修复档
├── tools/gym_echo.py             # 8312 双工反射器（LB 腿对端 + sc4 探针目标）
├── tools/gym_sink.py             # 8311 接收器（TX 腿对端）
├── tools/gym_flood.py            # hostfwd 灌流器（RX 腿发起方）
├── runs/                         # 全部实测档案（配套 *-host.log 为宿主侧证据）
│   ├── sc0-baseline.log                  # 基线
│   ├── sc{1..4}-broken.log / sc{1..4}-fixed.log
│   ├── annex-boundary-wnd11520-ring16.log  # 环深边界不稳：RX 黑洞复现
│   ├── annex-ring32-cure-fails.log         # "抬环公式"不足以救 28800 量级
│   └── *-host.log                           # 对应宿主工具输出
└── run.log                       # 留存：sc0-baseline 全场日志
```
