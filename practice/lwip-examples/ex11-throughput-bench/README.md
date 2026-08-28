# ex11 throughput-bench —— 吞吐基准模板（iperf-lite）

ESP-IDF v6.0.2 + QEMU (openeth/SLIRP)。单固件双模式：

- **TX 泵**：guest 用阻塞 `send()` 把每轮 N MB 的确定性图样灌到宿主机 `tools/sink.py`
  （`10.0.2.2:8290`，SLIRP 落宿主 loopback 同端口，无需 hostfwd），发完半关等
  `'K'` 应答位对齐投递终点；
- **RX 灌入**：guest 监听 `:8291`（hostfwd `tcp::8291-:8291`），宿主机
  `tools/flood.py` 以 guest 发来的 `'R'` 就绪字节为发令枪灌入 N MB 后半关，
  guest 收满回 `'K'`。

方法学沿 ch6/ch24 口径：**双计时**（guest `esp_timer` µs 网格 × 宿主
`time.monotonic()` 墙钟，互不共用时钟、结果互证）、**Fletcher-16 digest 校验**
（两端各自实现同一 xorshift32 图样递推式，digest 对上即字节流对上）、
**轮次交错**（BOTH 模式按 T1,R1,T2,R2,… 跑，反复横跳证明无状态残留）。SDK 级
旋钮 `TCP_SND_BUF/WND` 提供两档预设文件（⚠ 切档必须删 `sdkconfig` 重生成）。

## 1. 网络拓扑

```text
      ┌────────────────── QEMU (-nic user,model=open_eth) ──────────────────┐
      │                                                                     │
      │   guest ESP32 (openeth MAC 52:54:00:12:34:56)                       │
      │   IP 10.0.2.15/24  gw/DNS 10.0.2.2                                  │
      │                                                                     │
      │   TX 泵 ──────────────► 10.0.2.2:8290  （出连，无需 hostfwd）       │
      │   RX 监听 ◄────────────  :8291         （hostfwd tcp::8291-:8291）  │
      └──────────────────────────────┬──────────────────────────────────────┘
                                     ▼ (SLIRP 用户态转发，guest↔宿主 loopback)
        宿主机 tools/sink.py   监听 0.0.0.0:8290   接 TX 泵，逐字节算 digest
        宿主机 tools/flood.py  连接 127.0.0.1:8291 灌 RX，等 'R' 再发
```

ex11 号段 **8290/8291**（SPEC §4）：`+0` 主数据口双向各一。8290 方向是 guest 出连
宿主，所以 runner 只需要 8291 一个 hostfwd。

## 2. 目录结构

```text
ex11-throughput-bench/
├── CMakeLists.txt              # 根工程文件（MINIMAL 形态）
├── sdkconfig.defaults          # 默认档（base）：SND_BUF/WND=5760/5760 基线口径
├── sdkconfig.defaults.wide     # 宽窗档（wide）：28800/28800 + openeth RX 环 32
├── main/
│   ├── main.c                  # 全部逻辑单文件（bring-up + TX/RX 轮次调度）
│   ├── CMakeLists.txt
│   └── Kconfig.projbuild       # EXAMPLE_BENCH_MODE / ROUNDS / MB / 等待秒数
├── tools/
│   ├── sink.py                 # TX 接收器（宿主，dual-caliber 计时 + digest）
│   ├── flood.py                # RX 灌流器（'R' 就绪握手 + 'K' 完成握手）
│   ├── sink-host.log           # base 档验收运行的宿主接收器真实输出
│   ├── flood-host.log          # base 档验收运行的宿主灌流器真实输出
│   ├── wide-run.log            # wide 档串口日志（对比实验证据）
│   ├── wide-sink-host.log      # wide 档宿主侧输出
│   └── wide-flood-host.log     # wide 档宿主侧输出
└── run.log                     # base 档正式验收运行的完整串口日志（摘录出处）
```

无 managed component、无在线拉取——依赖全部来自 `${IDF_PATH}`
（`esp_eth`/`esp_netif`/`esp_event`/`lwip`/`esp_timer`），离线可重复构建。

## 3. 构建与运行

### 3.1 宿主端：先起两个工具（各开一个终端，或用后台形态）

```bash
cd practice/lwip-examples/ex11-throughput-bench
# 终端 1：TX 接收器。conns 数 = 固件轮数，收满自动退场并打总账
python3 tools/sink.py --conns 3 | tee sink.out
# 终端 2：RX 灌流器。retry-sec 要盖住 QEMU 启动 + 若干 TX 轮的等待
python3 tools/flood.py --rounds 3 --mb 4 --retry-sec 90 | tee flood.out
```

省事形态（两条命令塞进同一个 shell，跑完 QEMU 自动收尾）：

```bash
(python3 tools/sink.py --conns 3 > sink.out 2>&1 &) \
&& (python3 tools/flood.py --rounds 3 --retry-sec 90 > flood.out 2>&1 &) && sleep 0.5
```

### 3.2 guest 端：构建并跑进 QEMU

```bash
cd practice/lwip-examples/ex11-throughput-bench
. ~/esp/esp-idf/export.sh
idf.py set-target esp32          # 仅首次
idf.py build

# 生成 QEMU flash/efuse 镜像。⚠ 重复构建后它可能静默失败不更新镜像，
# 兜底见 §6.4（本工程首跑就踩中，靠固件 BUILD 时间指纹当场识破）。
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在且新鲜

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 60 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8291-:8291 \
  -nographic -no-reboot < /dev/null | tee run.log
```

注意 runner **没有 efuse `-global driver=nvram.esp32.efuse,...` 行**——该行在本机
QEMU 上偶发导致 openeth NIC 不创建（Batch 4 实测），示例统一去除此行。一次 BOTH
会话约 12 s：3×(TX≈0.35s + RX≈0.37s + 交叠等待) + 启动 ≈2.7s，跑完固件主动
`esp_restart()`，`-no-reboot` 下 QEMU 进程干净退出（退出码 0）；`timeout 60`
只是护栏。若会话被中断要收尸，按特征精确找本工程实例，**禁止 pkill**
（并行作者实例会被误伤）：

```bash
pgrep -af 'hostfwd=tcp::8291'    # 找到 PID 后 kill <PID>
```

### 3.3 单方向模式

只想跑一个方向：`idf.py menuconfig` → Example Throughput Bench Configuration →
Benchmark mode 选 `TX` 或 `RX`（ respectively 只需起对应的一个宿主工具）。
死等对端不会卡死固件：TX 每轮有 `PEER_WAIT_SEC`（默认 20s）预算，RX 有
`RX_WAIT_SEC`（默认 30s），到点该方向标 `PEER_DOWN` 并跳过剩余同向轮次，
SUMMARY 照常给出。

## 4. 运行时刻表与机器可读标记行

BOTH 默认时刻表（T=TX 泵，R=RX 灌入，交错）：

| 序                    | 动作    | 目标                   | 预期                              |
| --------------------- | ------- | ---------------------- | --------------------------------- |
| T1                    | TX 泵   | `10.0.2.2:8290` (sink) | 4MB 全量送达，digest 与 sink 一致 |
| R1                    | RX 灌入 | guest `:8291` ← flood  | 4MB 收满，digest 与 flood 一致    |
| T2/R2、T3/R3 同构交错 |         |

CI 可 grep 的机器可读行（全部以 `[EX11]` 开头）：

```text
[EX11] PHASE=READY ...                        # bring-up 完成，参数自报
[EX11] BUILD <date time> snd_buf= wnd= mss= ring=   # 配置指纹（验镜像新鲜度）
[EX11] CFGOK / CFGWARN ...                    # 窗口×RX环深不等式开机体检
[EX11] TX R=n RESULT status= bytes=/ conn_ms= xfer_ms= full_ms= mbit= digest=
[EX11] RX R=n RESULT status= got=/ xfer_ms= mbit= digest=
[EX11] SUMMARY mode= rounds= tx_ok=/ avg_tx_mbit= rx_ok=/ avg_rx_mbit=
[EX11] PHASE=DONE                             # 正常收官
```

宿主两侧对应 `SINK-*` / `FLOOD-*` 行。四方 digest 交叉一致才算一轮有效。

## 5. 真实输出摘录（全部出自本仓 run.log 与 tools/\*-host.log，未润色）

TX 泵三轮（guest 口径，注意 `conn_ms` 只在首轮含 DHCP 后 ARP 税）：

```text
I (2709) ex11: [EX11] TX R=1 connected 10.0.2.2:8290 (wait 7 ms)
[EX11] TX R=1 RESULT status=OK bytes=4000000/4000000 conn_ms=7 xfer_ms=334 full_ms=336 mbit=95.84 stall=0 refusals=0 ack=1 digest=5b5c err=0
[EX11] TX R=2 RESULT status=OK bytes=4000000/4000000 conn_ms=3 xfer_ms=341 full_ms=342 mbit=93.85 stall=0 refusals=0 ack=1 digest=5b5c err=0
[EX11] TX R=3 RESULT status=OK bytes=4000000/4000000 conn_ms=2 xfer_ms=338 full_ms=338 mbit=94.73 stall=0 refusals=0 ack=1 digest=5b5c err=0
```

RX 灌入三轮（首轮 `wait_ms=3880` 是 flood 从进程启动就开始排队的正常现象，见 §6.5）：

```text
[EX11] -- R1 BEGIN listening=:8291 bytes=4000000
I (6929) ex11: [EX11] RX R=1 CONN from=10.0.2.2:47860 (wait 3880 ms)
[EX11] RX R=1 RESULT status=OK got=4000000/4000000 wait_ms=3880 xfer_ms=365 mbit=87.68 digest=5b5c stall=0 err=0
[EX11] RX R=2 RESULT status=OK got=4000000/4000000 wait_ms=257 xfer_ms=335 mbit=95.60 digest=5b5c stall=0 err=0
[EX11] RX R=3 RESULT status=OK got=4000000/4000000 wait_ms=264 xfer_ms=371 mbit=86.35 digest=5b5c stall=0 err=0
```

总账（默认档至少一轮完整双向数据，本图为三整轮）：

```text
[EX11] SUMMARY mode=both rounds=3 tx_ok=3/3 avg_tx_mbit=94.8 rx_ok=3/3 avg_rx_mbit=89.9
[EX11] PHASE=DONE -- rounds finished, restarting to exit QEMU cleanly
```

宿主侧同步对账（wall clock 口径，与 guest 数字独立得出、互相咬合）：

```text
SINK-DONE conn#1 peer=127.0.0.1:34224 bytes=4000000 dur=0.333s mbit=96.08 digest=5b5c ack=K
SINK-SUMMARY conns=3 with_data=3 avg_mbit=94.87        ← vs guest avg_tx=94.8 ✓
FLOOD-DONE round=2 bytes=4000000/4000000 send_s=0.127 full_s=0.336 mbit_e2e=95.34 digest=5b5c ack=K attempts=4
FLOOD-SUMMARY rounds=3 ok=3 avg_mbit=89.74             ← vs guest avg_rx=89.9 ✓
```

四个观测点（guest 写 / sink 读 / flood 发 / guest 读）每轮 digest 都是 `5b5c`：
4MB 经 SLIRP 往返一次都没有字节错位。

## 6. 宽窗口变体（wide 档）：步骤、数字、解读

### 6.1 切换步骤（顺序不能错）

```bash
cd practice/lwip-examples/ex11-throughput-bench
cp sdkconfig.defaults.wide sdkconfig.defaults   # ① 用宽窗预设覆盖 defaults
rm -f sdkconfig                                 # ② ⚠必删！defaults 只在无 sdkconfig 时生效
idf.py build                                    # ③ 重新生成全量配置再编译
idf.py qemu monitor < /dev/null || true         # ④ 出镜像（或走 §6.4 手工兜底）
# 然后照 §3.1/§3.2 跑
```

跑完换回默认档同样三步（`cp` 反向覆盖 + `rm sdkconfig` + rebuild）。

> [!warning] 为什么必须删 `sdkconfig`
> `sdkconfig.defaults` 只在 `sdkconfig` 不存在时被采用。残留旧值会静默吃掉新预设
> ——改完 SND_BUF 发现吞吐纹丝不动，九成是这个（Batch 1 教训）。防呆手段：看
> `[EX11] BUILD ... snd_buf= wnd=` 自报值与你预期是否一致。

### 6.2 两档旋钮差异

| 文件                     | SND_BUF | WND   | MSS  | openeth RX 环 | 邮箱(TCPIP/TCP recv) |
| ------------------------ | ------- | ----- | ---- | ------------- | -------------------- |
| sdkconfig.defaults(base) | 5760    | 5760  | 1440 | 默认 4        | 默认                 |
| sdkconfig.defaults.wide  | 28800   | 28800 | 1440 | **32**        | 32                   |

wide 把 `CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM` 一起拧到 32 不是顺手——是被不等式
强制的，两者必须成对出现（§7.3）。

### 6.3 对比数字（同一分钟窗口内先后配对测量，各 3 轮 × 4MB）

| 指标                   | base     | wide      | 变化                         |
| ---------------------- | -------- | --------- | ---------------------------- |
| TX 泵 guest 口径均值   | **94.8** | **113.5** | +20%，直逼 SLIRP 天花板      |
| TX 泵 sink 墙钟均值    | 94.87    | 113.61    | 与 guest 口径互证一致        |
| RX 灌入 guest 口径均值 | 89.9     | 76.2      | 噪声带内持平略降（解读见下） |
| RX 灌入 flood e2e 均值 | 89.74    | 76.07     | 与 guest 口径互证一致        |

固件自报核对：base `snd_buf=5760 wnd=5760 ring=4`，wide
`snd_buf=28800 wnd=28800 ring=32`——换档确实生效。

**解读**：TX 方向受益直接——发送缓冲从 5.6KB 放到 28KB，泵可以一次压更多在途
数据，把链路利用率顶到 113 Mbit（SLIRP 天花板 ~120 的 94%）。RX 方向没有兑现
等幅收益反而略降：这正好印证 Batch2/ch24 的结论——外环瓶颈在 SLIRP 用户态转发
与驱动接收路径，不在协议栈窗口宽度；更大的 WND 让 SLIRP 前送更猛的突发，openeth
接收描述符环（虽已抬到 32）与 emac_rx 单任务成了新的第一闸门。另按 Batch4 纪律，
QEMU 吞吐受宿主负载影响可达 ±50%，任何跨配置对比都必须像本次一样同时段配对，
隔天数字没有可比性。

### 6.4 qemu_flash.bin 时效性兜底（首跑真实踩中）

`idf.py qemu monitor` 在重复构建后可能静默失败、不再刷新 `qemu_flash.bin`——
本工程第二次构建后实锤发生过一次（旧镜像里 TX 还带着未修复的 bug 在跑）。判别
与自救：

```bash
ls -la build/qemu_flash.bin          # 和刚 build 完的时间戳对不上就是中招
grep '\[EX11\] BUILD' run.log        # 对照固件自报时间戳，旧的立现形
cd build && python -m esptool --chip esp32 merge-bin \
  -o qemu_flash.bin --pad-to-size 4MB @flash_args   # 手工合并兜底
```

### 6.5 其它已知边界与排障

- **SLIRP hostfwd 会“提前接受”宿主侧 connect**：哪怕 guest 根本没监听 8291，
  宿主 `connect(127.0.0.1:8291)` 也立刻成功（连接先进 SLIRP 的队列）。直接开始
  灌流会把字节灌进幻影连接，搅乱计时甚至中途吃 RST。协议解法是应用层就绪握手：
  guest accept 后先发 `'R'`，flood 见 `'R'` 才开灌、不见则关掉重连（log 里
  `phantom-conn` 就是它在干活）。首轮 `wait_ms≈3.9s` 也是同一机理：flood 从进程
  启动就在排队，真正开灌要等到 guest 监听出现并 accept。后续轮次 wait 只有零点几秒。
- **TX 轮伴随刷屏 `opencores.emac: RX frame dropped (0x14)`**：重负载期 ACK/FIN
  小帧把默认深度 4 的 RX 描述符环挤爆所致，属预期噪音；ACK 时钟没断，吞吐不受
  影响。想让它闭嘴就把环加深（wide 档自然消失大半）。
- **TX 对端不在时的形态**：connect 经 SLIRP 得到的是快速拒绝（ECONNREFUSED，
  `refusals=N` 每 300ms 退避重试），死线耗尽后报 `PEER_DOWN` 并跳过剩余同向轮次；
  不会出现裸 connect 分钟级挂死（非阻塞 + select 死线兜住）。
- **`send_s` 是“管道口径”不是吞吐**：flood 打印的 `send_s=0.124s/251Mbit` 只是
  字节离开宿主 socket 缓冲的速度，真正的端到端口径看 `full_s`/`mbit_e2e`
  （含 `'K'` 完成位），与 guest 侧互证。README 表格一律引 e2e/guest 数字。
- **固定参数**：SO_SNDTIMEO 10s / SO_RCVTIMEO 15s 兜住一切阻塞调用；backlog=4；
  图样周期 64 KiB（xorshift32 seed=0x11c0ffee），Fletcher-16 mod 255——两端算法
  各自实现但逐位一致，改动请同步 tools/\*.py 与 main.c 两处。

## 7. 旋钮手册与调优指引

### 7.1 工程级（menuconfig → Example Throughput Bench Configuration）

| 旋钮                          | 默认 | 说明                                                       |
| ----------------------------- | ---- | ---------------------------------------------------------- |
| `EXAMPLE_BENCH_MODE`          | BOTH | BOTH/TX/RX 三选一                                          |
| `EXAMPLE_BENCH_ROUNDS`        | 3    | 每方向轮数（1–10）                                         |
| `EXAMPLE_BENCH_MB`            | 4    | 单轮 MB，十进制（1–64）                                    |
| `EXAMPLE_BENCH_PEER_WAIT_SEC` | 20   | TX 每轮等待 sink 就绪的死线                                |
| `EXAMPLE_BENCH_RX_WAIT_SEC`   | 30   | RX 每轮等待 flood 接入的死线                               |
| `EXAMPLE_BENCH_PROGRESS`      | 关   | 轮内每 MiB 进度行；UART 日志本身占带宽，对比测量建议保持关 |

### 7.2 SDK 级：SND_BUF / WND 两档预设

真身是 lwIP 组件符号（Component config → lwIP → TCP）：
`CONFIG_LWIP_TCP_SND_BUF_DEFAULT` / `CONFIG_LWIP_TCP_WND_DEFAULT`。工程不重复定义，
只给两档预设文件（§6.2），外加三条铁律：

1. 改完必删 `sdkconfig` 重生成（§6.1），然后用 `[EX11] BUILD` 自报值核验；
2. 只拧 WND 不动 RX 环深 = 白改甚至更糟（§7.3）；
3. 甩锅前先想 SLIRP：外环天花板 ~120 Mbit 在那里摆着（§8）。

### 7.3 窗口×RX 环深不等式（调优头号发现，ch24 实测沉淀）

```text
WND >= 11520  ⇒  openeth RX 环深 >= 16   （环 4 时是 3.4~6.7 Mbit 黑洞）
WND >= 28800  ⇒  openeth RX 环深 >= 32
```

规则在本工程里的三道防线：

- `sdkconfig.defaults.wide` 里环深与 WND 成对出现；
- 固件开机自检（`[EX11] CFGWARN/CFGOK`），一启动就知道是不是自毁式调参；
- 正文数字（§6.3）给过反例：环不够时 WND 拧得再大也只有个位数 Mbit。

### 7.4 把这个模板改坏的三种姿势（前辈实测账本）

| 姿势                                                   | 后果                                         | 出处    |
| ------------------------------------------------------ | -------------------------------------------- | ------- |
| raw API 发送泵不注册 `tcp_sent()` 回调                 | ACK 无从驱动补发，吞吐涓流                   | Batch 2 |
| 依赖 `tcp_write` no-copy 提升性能                      | IDF 强制 `TCP_WRITE_FLAG_COPY`，编译期不可达 | Batch 2 |
| `CONFIG_LWIP_MAX_ACTIVE_TCP` 默认 16 以下 + 多并发连接 | SYN 静默黑洞                                 | ch24    |

另外两条不影响本模板但值得知道的：`TCP_SNDLOWAT` 只影响 socket 可写语义；
recv 邮箱深度 8→64 实测不敏感（瓶颈不在那）。sys_now() 是 10ms 粗格——凡是计时
都用 `esp_timer_get_time()`（本工程全程如此）。

## 8. 天花板声明（拿数字前必读）

- **SLIRP 外环吞吐天花板 ~120 Mbit**（CONVENTIONS Batch 2：默认 SND_BUF=5760 与调大
  到 28800 都到顶，瓶颈在 SLIRP 用户态转发而非 lwIP）。本工程 wide 档 TX 113.5 已达
  天花板 94%——再拧任何协议栈旋钮都不会超过这条线。
- **QEMU 吞吐受宿主机负载影响 ±50%**（Batch 4）：本文所有对比均在同一分钟窗口内
  配对完成。引用本 README 数字时注明环境（16 核宿主 + esp_develop_9.2.2 QEMU），
  不要当 ESP32 真机性能；真机数值请用真机按同一方法学重测。
- 双计时/digest/交错轮次这套方法学随模板带走即可复用：guestµs 计时 × 宿主墙钟
  互证 + 四点 digest 对账 + 至少两轮交错排除偶发。

## 9. 已验证的验收路径（重现清单）

```bash
# 1. 构建生成镜像（见 §3.2 全流程）
# 2. 终端 A/B 起 sink.py / flood.py（§3.1）
# 3. 跑 QEMU 60s，QEMU 自动退出（退出码 0）
# 4. 核对四处 digest 均为 5b5c、SUMMARY 双向 3/3：
grep -E "RESULT|SUMMARY" run.log | grep EX11
grep -E "SUMMARY" tools/sink-host.log tools/flood-host.log
```

预期 SUMMARY：`tx_ok=3/3 avg_tx_mbit≈94±10 rx_ok=3/3 avg_rx_mbit≈90±10`
（绝对值随宿主负载浮动，双向 3/3 + 四点 digest 一致才是硬标准）。
