# ex04 udp-echo-bidir —— UDP 双向收发模板

lwIP 示例套件成员（总规格见 `../SPEC.md`）。单一 socket 层（BSD API）、最小组件集，
演示 UDP 最容易踩坑的四件事，入向与出向两条路径各有真实往返证据。

## 1. 目的与教学点

| 教学点                                                             | 在哪看                                                                                                                                       |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| **无连接语义**：没有 listen/accept/connect，一个 fd 服务任意多对端 | `main/main.c` 常驻服务循环：同一端口混着三种来源（宿主测试器 / 自环折返 / 宿主回声器），互不干扰                                             |
| **bind 固定本地端口**                                              | `app_main()` 中 `bind(:8230)`——hostfwd=`udp::8230-:8230` 只认固定端口；不 bind 的 socket 端口是临时的，SLIRP 无处投递                        |
| **recvfrom 来源地址判断**                                          | 回显目的地一律取自 `recvfrom()` 返回的 `sockaddr_in`。实测中宿主流量在 guest 眼里是 `10.0.2.2:46870` 这种 NAT 后临时端口，绝非"想当然的对端" |
| **超时必须自管（SO_RCVTIMEO）**                                    | `set_recv_timeout_ms()`。UDP 没有重传、没有 keepalive：不设 SO_RCVTIMEO，第一个丢包就能让单线程服务永久停摆                                  |
| **丢包时应用层如何感知**                                           | 序号 + 自己的定时器：`EX04-TX` 发出后在窗口内等匹配 seq 的回声，等不到打印 `EX04-LOSS`——协议栈不会给你任何通知                               |

SO_RCVTIMEO 无需额外配置开关：IDF 在 `components/lwip/port/include/lwipopts.h`
中硬编码 `LWIP_SO_RCVTIMEO=1`。

## 2. 网络拓扑

端口规划（SPEC §4 号段 823）：**8230** = 主服务（hostfwd 两端同号）；**8231** = 宿主辅助
UDP 回声器。

```text
          宿主 (Linux)                                         guest (ESP32 @ QEMU)
┌─────────────────────────────────────────────┐       ┌───────────────────────────────┐
│                                             │       │                               │
│  tools/send.py                              │       │  app: socket()+bind(:8230)    │
│    └──UDP──▶ 127.0.0.1:8230 ══ hostfwd ═════╪══════▶│    10.0.2.15:8230             │
│                                             │ udp:: │      │ ▲                      │
│                                8230-:8230   │       │      └─┘ tag='H' 原样回显     │
│  ▲                                          │       │                               │
│  │                                          │       │  tag='A'/'B' 探针（只收不发）  │
│ tools/udp_echo_srv.py ◀──UDP── 127.0.0.1:8231◀──SLIRP──┤                               │
│                                （出向路径 B） │       │  出向 sendto 10.0.2.2:<port>  │
└─────────────────────────────────────────────┘       └───────────────────────────────┘
  出向路径 A（自环打自己）：
    guest → 10.0.2.2:8230 → SLIRP 落到宿主 loopback:8230 → 该端口恰是 QEMU 自己的
    hostfwd 监听 → 数据报被转发回 guest:8230。
  出向路径 B（外服回声）：
    guest → 10.0.2.2:8231 → 宿主回声器原样回显 → 经 SLIRP NAT 折返回 guest:8230。
```

guest 地址由 SLIRP DHCP 分配为 `10.0.2.15/24`（网关/DNS 映射入口 `10.0.2.2`/`10.0.2.3`）。

## 3. 目录结构

```text
ex04-udp-echo-bidir/
├── CMakeLists.txt          # root 构建（MINIMAL_BUILD ON）
├── sdkconfig.defaults      # 仅 CONFIG_ETH_USE_OPENETH=y
├── main/
│   ├── CMakeLists.txt      # PRIV_REQUIRES esp_eth esp_netif esp_event esp_timer lwip
│   └── main.c              # 骨架 bring-up + 常驻 echo + 双出向探针
├── tools/
│   ├── run_qemu.sh         # 统一 QEMU 启动器（无 efuse -global 行，见 §7）
│   ├── send.py             # 入向验证器：序号 + digest + 超时感知
│   └── udp_echo_srv.py     # 宿主侧 UDP 回声器（出向路径 B 对端）
├── run.log                 # 真实运行留存（本 README 摘录均出自它）
└── README.md
```

payload 自定义协议头共 9 字节：`magic("EX04") + tag(1B) + seq(u32 大端)`，其后为确定性
填充体，回显必须逐字节一致（即强 digest 校验）。tag 含义：

- `'H'` = 宿主入向测试流量 → 必须原样回显给 recvfrom 给出的来源；
- `'A'`/`'B'` = 出向探针自己的回声 → **绝不再转发**，否则回声会被当成新请求无限放大成
  回声风暴（迟到者仅打印 `EX04-LATE` 并计数）。

## 4. 构建

```bash
cd practice/lwip-examples/ex04-udp-echo-bidir
. ~/esp/esp-idf/export.sh
idf.py set-target esp32        # 仅首次
idf.py build
```

生成 QEMU 镜像（`idf.py qemu monitor` 因无 TTY 失败属预期，镜像已生成）：

```bash
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin
# 兜底（重复构建后 monitor 可能静默失败、镜像未更新时手动合并）：
# cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args
```

固件开机打印 `EX04-FACT build_time=<HH:MM:SS>`（编译时刻指纹），可核对镜像新鲜度，
防止"烧旧镜像测新代码"。

## 5. 运行与验证

### 5.1 推荐姿势：三终端

```bash
# 终端 A —— 启动 guest（串口输出 tee 到 run.log；600s timeout 自然截停，退出码 124 属正常）
tools/run_qemu.sh 600

# 终端 B —— 宿主 UDP 回声器（出向路径 B 的对端；不出向验证路径 B 可省略）
python3 tools/udp_echo_srv.py --port 8231

# 终端 C —— 入向验证（等终端 A 打印 $$$ EX04READY 与两段 EX04-LOOPSUM 之后执行）
python3 tools/send.py                                    # 默认 20 包 @64B
python3 tools/send.py --count 500 --size 512 --interval-ms 25   # 加量 ping-pong 压测
```

### 5.2 单终端一条龙（照抄可复现）

```bash
python3 tools/udp_echo_srv.py --port 8231 > /tmp/ex04_echosrv.log 2>&1 &
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 120 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=udp::8230-:8230 \
  -nographic -no-reboot > run.log 2>&1 &
QP=$!                          # 记下精确 PID，停止时 kill -TERM $QP（禁止 pkill）
sleep 8                        # 等 READY + 两个出向探针阶段完成
python3 tools/send.py          # 入向验证；结束后 QEMU 由 timeout 或 kill -TERM 收场
```

### 5.3 真实输出摘录（全部出自本次入库的 run.log，非编造）

启动（bootloader 噪音略）：

```text
I (2724) ex04: GOT_IP: 10.0.2.15
EX04-FACT build_time=12:45:35 guest_ip=10.0.2.15 app_port=8230 ext_echo_port=8231 probe_n=10 recv_timeout_ms=2000 api=socket
$$$ EX04READY port=8230 mode=udp-echo tag_h=ECHO tags_ab=INTERNAL
```

**出向路径 A（自环打自己）**：guest→10.0.2.2:8230 经 SLIRP 折返回 guest:8230，逐字节 digest OK：

```text
EX04-PHASE mode=self-loop target=10.0.2.2:8230 n=10 interval_ms=100 timeout_ms=2000
EX04-TX mode=self-loop seq=0 dst=10.0.2.2:8230 len=64
EX04-RX mode=self-loop seq=0 from=10.0.2.2:8230 len=64 rtt_us=6072 digest=OK
EX04-TX mode=self-loop seq=1 dst=10.0.2.2:8230 len=64
EX04-RX mode=self-loop seq=1 from=10.0.2.2:8230 len=64 rtt_us=687 digest=OK
...
EX04-LOOPSUM mode=self-loop target=10.0.2.2:8230 sent=10 ok=10 lost=0 corrupt=0 loss_pct=0.0 rtt_avg_us=1216 rtt_min_us=514 rtt_max_us=6072
```

（seq=0 的首包 ~6ms 是 ARP 未命中的一次性开销，见 CONVENTIONS Batch 3"首包税"；此后回落
到亚毫秒档。）

**出向路径 B（宿主回声器）**：对端是独立宿主进程 `udp_echo_srv.py`，回声器侧日志：

```text
EX04-SRV listening on udp://127.0.0.1:8231
EX04-SRV echo #1 from=127.0.0.1:8230 len=64 magic=EX04 tag=B seq=0
...
EX04-SRV echo #10 from=127.0.0.1:8230 len=64 magic=EX04 tag=B seq=9
```

guest 侧汇总行：

```text
EX04-LOOPSUM mode=ext-srv target=10.0.2.2:8231 sent=10 ok=10 lost=0 corrupt=0 loss_pct=0.0 rtt_avg_us=794 rtt_min_us=526 rtt_max_us=1227
```

**入向（hostfwd 8230 → guest）**：`tools/send.py --count 20` 的宿主侧输出：

```text
EX04-IN seq=0 len=64 from=127.0.0.1:8230 rtt_ms=0.93 digest=OK
EX04-IN seq=1 len=64 from=127.0.0.1:8230 rtt_ms=0.68 digest=OK
...
# 汇总 sent=20 ok=20 retried=0 missing=[] loss_pct=0.00
EX04-HOST-INBOUND dst=127.0.0.1:8230 size=64 sent=20 ok=20 missing=0 corrupt=0 attempts=20 loss_pct=0.00 rtt_avg_ms=0.72 rtt_p95_ms=1.32
```

对应 guest 侧交叉证据（注意 `from=10.0.2.2:46870`——hostfwd 流量经 SLIRP 伪装后的来源，
正是"必须用 recvfrom 返回值回包"的原因）：

```text
EX04-ECHO n=1 from=10.0.2.2:46870 len=64 seq=0 -> echoed
EX04-ECHO n=2 from=10.0.2.2:46870 len=64 seq=1 -> echoed
...
EX04-ST rx_total=20 echoed_h=20 rx_short=0 self_ok=10 self_lost=0 ext_ok=10 ext_lost=0 uptime_s=23
EX04-ST rx_total=520 echoed_h=520 rx_short=0 self_ok=10 self_lost=0 ext_ok=10 ext_lost=0 uptime_s=35
```

（第二条 ST 时 rx_total=520 = 入向 20 + 500 包加压一轮，与宿主侧
`sent=500 ok=500 ... loss_pct=0.00 rtt_avg_ms=0.27` 完全对账。）

退出方式：QEMU 由外部精确 kill（`kill -TERM <pid>`）或 timeout 截停，日志末行为
`qemu-system-xtensa: terminating on signal 15 from pid ... (timeout)`，无 panic 复位。

## 6. 丢包观测：UDP 下应用层如何"看见"丢失

同一环境做的两组对照实验（数据均为实测）：

| 实验                                                       | 结果                                                                                                                                                                           | 解读                                                                                                  |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| ping-pong ×500 @512B                                       | `ok=500 loss_pct=0.00`，rtt_avg 0.27ms                                                                                                                                         | 一问一答节奏下链路非常可靠                                                                            |
| 无界流水线洪水：2000 包 @512B，49ms 内全部发出（~40k pps） | 宿主侧仅收到 7 个唯一回显（`loss_pct=99.65`）；guest 应用层 `rx_total` 只增 7；无 corrupt、无短包；同时 openeth 驱动刷屏 `emac_opencores_isr_handler: RX frame dropped (0x14)` | 过载坍缩，不是普通"丢包"：绝大部分在宿主 socket 缓冲/SLIRP 就被丢弃，到达网卡的尾巴又溢出 RX 描述符环 |

要点：

1. 协议栈对 UDP 丢弃零通知——应用层唯一的感知手段就是本文的"序号 + 定时器"
   （`EX04-IN TIMEOUT` / `EX04-LOSS` 行）。宏观看，send.py 的 `missing=[...]` 列表就是
   应用层视角的完整丢包账本。
2. 本例洪水的坍缩点在协议栈之外（缓冲/NIC 环），与 CONVENTIONS Batch 3 记录的
   "突发尾巴恒定 ~0.8% 仿真丢包，与协议栈无关"、Batch 5 的"openeth RX 描述符环是
   洪峰第一瓶颈"一致；~0.8% 尾巴需按 ch10 式有窗压测口径才会显现，普通 ping-pong
   节奏下观察不到。
3. FIFO 会把你的错误放大：若此处盲目给发送加重试风暴，只会进一步喂满已经拥塞的队列
   ——UDP 应用的重试策略必须带退避。

## 7. 已知边界与排障

- **启动器刻意不含 `-global driver=nvram.esp32.efuse,...` 行**：该行在本机 QEMU 上偶发
  导致 openeth NIC 未创建（警告 "was not created"，guest 在 `esp_eth_mac_new_openeth()`
  复位）。遇到先查 `tools/run_qemu.sh` 是否被改回带此行的形态。
- **openeth 启动固定刷 3 条 MAC filter ioctl 错误**，属预期噪音，不是故障。
- **hostfwd 冲突**：QEMU 启动后立刻
  `grep -iE "could not set up host forwarding" run.log`，命中说明宿主 8230 被占（并行
  实验冲突），换端口或停掉占用者再跑。
- **主机→guest 只有 hostfwd 一条路**，且 ICMP 不通（宿主 `ping 10.0.2.15` 恒不通）；
  连通性检查请用 UDP/TCP 探针而不是 ping。
- **SLIRP 吞吐天花板 ~120 Mbit、洪水行为见 §6**；本模板是功能示例，不是性能基准
  （吞吐基准是 ex11 的职责）。
- **出向自环依赖 QEMU 自身的 hostfwd 监听**（8230 在宿主 loopback 可达）。若你改为去掉
  hostfwd 只做纯出向实验，路径 A 将按设计打印 `EX04-LOSS`——这本身就是"应用层感知
  丢包"的现成教材。
- **结束纪律**：kill QEMU 必须按 PID（或让 `timeout` 到点自然收场），禁止 `pkill`；
  退出码 124 = timeout 正常截停，0/-1 = 应用主动 reset，均属正常。

## 8. 端口登记

| 端口 | 协议 | 方向                           | 用途                                                           |
| ---- | ---- | ------------------------------ | -------------------------------------------------------------- |
| 8230 | UDP  | 宿主→guest（hostfwd 同号直通） | 主服务：bind :8230 的 echo server；同时是出向路径 A 的折返目标 |
| 8231 | UDP  | guest→宿主（loopback 同端口）  | 宿主 UDP 回声器（出向路径 B 对端）                             |

登记于套件号段 823（SPEC §4），子槽位遵循 `+0` 主服务 / `+1` 辅助约定。
