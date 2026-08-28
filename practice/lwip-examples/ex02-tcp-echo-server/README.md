# ex02 tcp-echo-server —— TCP 服务端模板

lwIP 示例套件 ex02：socket 单任务 accept 循环模型的 TCP echo 服务端。
它是"复制改名即可开新服务端项目"的干净基线：openeth bring-up → DHCP → listen :8210 →
串行 accept → 对每条连接 `recv` 后原样回写 → close → 下一条。

三条从《lwIP 深度解析》实验沉淀的硬教训已固化进代码结构与注释（`main/main.c` 文件头）：

| 教训                                                                           | 出处          | 本模板的落法                                                 |
| ------------------------------------------------------------------------------ | ------------- | ------------------------------------------------------------ |
| 协议栈上下文不能被应用等待拖住（busy-wait 曾把第二连接吞吐打到 0.06 Mbit）     | ch15 livelock | 数据面循环只做"阻塞 recv → 立即回写"，统计打印走独立低频任务 |
| 单任务串行 accept 必须先 recv 后回写、及时 close                               | ch23 结论 a   | per-connection 数据驱动推进，FIN/RST 分支立即退出并 close    |
| listen backlog 必须显式设足，否则 SYN 被静默吞掉（客户端五发空转后 errno=113） | ch23 结论 b   | `listen(fd, 8)` 显式 backlog，注释写明依据与上限关系         |

## 网络拓扑

```text
宿主机 (Fedora)                          QEMU guest (esp32)
┌─────────────────────┐                 ┌──────────────────────────┐
│ nc / bench.py       │  tcp:8210       │ SLIRP user-net 10.0.2.2  │
│ localhost:8210 ─────┼──────────────►  │   │ hostfwd tcp::8210    │
│                     │                 │   ▼                      │
│ tools/bench.py      │                 │ openeth MAC              │
│  (N 连接压测)        │                 │ 52:54:00:12:34:56        │
└─────────────────────┘                 │   │ DHCP                 │
                                        │   ▼                      │
                                        │ lwIP socket echo server  │
                                        │ 10.0.2.15:8210 backlog=8 │
                                        └──────────────────────────┘
```

- guest IP 由 SLIRP DHCP 固定分配 `10.0.2.15/24`，网关/DNS `10.0.2.x`；
- 宿主机只能经 **hostfwd** 一条路访问 guest（ICMP 入向不通）；
- 端口约定见套件 SPEC §4：ex02 号段 8210/8211，本例只用 8210。

## 构建命令

```bash
cd practice/lwip-examples/ex02-tcp-echo-server
. ~/esp/esp-idf/export.sh
idf.py set-target esp32        # 仅首次
idf.py build                   # MINIMAL_BUILD ON，只编最小组件集
```

## 运行命令

```bash
# 生成 QEMU 镜像（monitor 因无 TTY 失败属预期，镜像已生成）：
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在

# 启动（tools/run_qemu.sh 内核 = 去 efuse -global 行的标准形态，
# 输出 tee 到 run.log；timeout 到点退出码 124 属正常截停）：
tools/run_qemu.sh [秒数]       # 默认 600s
```

等日志出现机器可读 READY 行即可开始连接：
`$$$ EX02ECHOREADY port=8210 backlog=8`

## 真实输出摘录

以下全部摘自本工程入库的 `run.log`（同一次真实运行）。

### 启动 bring-up 与 READY

```text
I (1595) ex02: == ex02 tcp-echo-server build@Aug 27 2026 12:42:58 ==
I (1715) ex02: ETH_EVENT: START
E (1715) esp_eth: esp_eth_ioctl(533): add mac address to filter not supported
I (1715) ex02: ETH_EVENT: CONNECTED (link up)
I (2715) ex02: GOT_IP: 10.0.2.15/255.255.255.0 gw 10.0.2.2
I (2715) ex02: net ready: 10.0.2.15/24 gw 10.0.2.2, starting echo server on :8210
$$$ EX02NETUP ip=10.0.2.15 gw=10.0.2.2
I (2715) ex02: echo server listening on 0.0.0.0:8210 backlog=8
$$$ EX02ECHOREADY port=8210 backlog=8
```

> 开头 3 条 MAC filter ioctl 错误是 openeth 的固定预期噪音（CONVENTIONS C-05 白名单），不是故障。

### 单连接往返（宿主机 `printf ... | nc localhost 8210`）

```text
I (23425) ex02: conn #1 ACCEPT from 10.0.2.2:59226 (active=1)
I (23435) ex02: conn #1 msg 1: echo 37 bytes "hello-ex02-first-line
ping-from-host
"
I (23435) ex02: conn #1 peer closed (FIN) after 1 msgs, 37 bytes
I (23435) ex02: conn #1 10.0.2.2:59226 CLOSED srv=6ms (37 bytes echoed)
$$$ EX02CLOSE conn=1 bytes=37
```

两行文本被 TCP 合并成一次 recv 回来（面向字节流，不是消息边界服务——这正是模板要示范的语义）。

### 断开的三种路径（同一 run.log 内均有实证）

```text
I (45675) ex02: conn #2 peer closed (FIN) after 1 msgs, 10 bytes
W (145995) ex02: conn #16 recv failed errno=104 after 1 msgs
I (206795) ex02: conn #17 peer closed (FIN) after 0 msgs, 0 bytes
```

- conn #2：客户端正常 FIN（nc Ctrl-C）；
- conn #16：客户端 `SO_LINGER(0)+close` 强发 RST → recv 返回 -1，errno=104（ECONNRESET）；
- conn #17：connect 后立即 close 的空连接 → FIN 路径、0 字节优雅退出。

### 周期统计行（独立观测任务每 10s 打印）

```text
$$$ EX02STATS active=0 total_accepted=29 bytes_echoed=449991 uptime_s=320
```

## 并发语义说明（第二连接排队行为的实测描述）

单任务 accept 循环一次只能服务一条连接：第二条连接的握手会照常完成（挂在内核
backlog 里），但它的数据**不会**被处理，直到前一条被 close。用两条 nc 实测：

宿主机侧时间线（A 先连、B 后连并立即发送）：

```text
12:44:05.338 A: connect+send 'AAA-first'      A 收到回显 b'AAA-first\n'
12:44:05.349 B: connect+send 'BBB-second'
12:44:08.351 B: 3s 无回显（在 backlog 中排队）
12:44:10.351 A: close
12:44:10.852 B: 收到回显 b'BBB-second\n'（A 关闭后 0.00s 内立即到达）
```

guest 侧对应日志——conn #3（即 B）的 ACCEPT 时间戳与 conn #2（即 A）的 CLOSED
**在同一毫秒 tick**（I(45675)）：

```text
I (40665) ex02: conn #2 ACCEPT from 10.0.2.2:33148 (active=1)
I (40675) ex02: conn #2 msg 1: echo 10 bytes "AAA-first
I (45675) ex02: conn #2 peer closed (FIN) after 1 msgs, 10 bytes
I (45675) ex02: conn #2 10.0.2.2:33148 CLOSED srv=5010ms (10 bytes echoed)
I (45675) ex02: conn #3 ACCEPT from 10.0.2.2:33158 (active=1)
I (45675) ex02: conn #3 msg 1: echo 11 bytes "BBB-second
```

结论：B 从宿主机视角早在 A 存活期间就已 connect 成功（hostfwd 下 SLIRP 代答了
三次握手），它的等待发生在 lwIP 的 listen backlog 里，应用层完全不可见
（`active` 计数只有被 accept 之后才 +1）。这是**排队不拒绝**的串行模型：队列容量由
显式 backlog（本例 8）保证；吃满则新 SYN 被 lwIP 静默丢弃（ch23 的 errno=113 病灶）。

### 压测数字（tools/bench.py，digest 校验逐字节比对）

```text
$ python3 tools/bench.py --conns 4 --msgs 20 --size 512
conn   0: PASS connect=0.0s rtt_avg=1ms rtt_max=14ms
conn   1: PASS connect=0.0s rtt_avg=11ms rtt_max=212ms
conn   2: PASS connect=0.0s rtt_avg=1ms rtt_max=3ms
conn   3: PASS connect=0.0s rtt_avg=2ms rtt_max=24ms
BENCH RESULT PASS conns=4 msgs_per_conn=20 total_wire_bytes=81920 wall=0.2s agg=2.88Mbit/s

$ python3 tools/bench.py --conns 8 --msgs 30 --size 1024
conn   0: PASS connect=0.0s rtt_avg=47ms rtt_max=1408ms
...
conn   4: PASS connect=0.0s rtt_avg=194ms rtt_max=5800ms
BENCH RESULT PASS conns=8 msgs_per_conn=30 total_wire_bytes=491520 wall=5.8s agg=0.68Mbit/s
```

- 两轮共 16 条并发连接全部 digest PASS（`sha256(发出字节流)==sha256(收到字节流)` 且逐条消息相等）；
- guest 日志里各连接 ACCEPT/CLOSED 严格交替、无一交叠，单条已排队连接被服务时
  全部 ~30 条消息在 13~41ms 内回显完毕；
- wall 时间远大于服务耗时之和的部分来自**排队的尾延迟**：8 流同刻灌入时有一条流出现
  ~5.8s 尾部等待（重传退避型阶梯）。呼应 ch24 发现——SLIRP/openeth 的默认 RX 环深
  （4）是多流洪峰的第一瓶颈。聚合吞吐数字不代表协议栈能力天花板（对比 ex11 基准）。

## 已知边界 / 排障

- **WiFi 不可仿真**：本环境 QEMU 无 esp-wifi-mac，openeth 以太网路径为唯一联网路径。
- **并行实验端口冲突**：启动失败先看是否 8210 被别的 QEMU 占了。按 hostfwd 特征精确
  kill（禁止 pkill，有并行作者实例在跑）：

  ```bash
  for p in $(pgrep -f '^/home/huanglin/.espressif/tools/qemu-xtensa'); do
    tr '\0' ' ' < /proc/$p/cmdline | grep -q 'tcp::8210' && kill $p || true
  done
  ```

- **镜像陈旧**：重复构建后 `idf.py qemu monitor` 可能静默不更新镜像（Batch 6 教训），
  核对启动日志里的 `build@__DATE__ __TIME__` 指纹；必要时手动合并：

  ```bash
  cd build && python -m esptool --chip esp32 merge-bin \
    -o qemu_flash.bin --pad-to-size 4MB @flash_args
  ```

- **性能天花板**：SLIRP 用户态转发约 ~120 Mbit 封顶，且受宿主机负载影响可达 ±50%；
  本示例定位是"正确性模板"，吞吐基准见 ex11。
- **想做超时版 accept**：给 accepted socket 加 SO_RCVTIMEO 即可让慢客户端到期放行
  （参考 ex03 的超时分支写法）；本模板刻意保持无超时的最简形态。

## 目录结构

```text
ex02-tcp-echo-server/
├── CMakeLists.txt          # root：MINIMAL_BUILD ON
├── main/
│   ├── CMakeLists.txt      # PRIV_REQUIRES esp_eth esp_netif esp_event lwip esp_timer
│   └── main.c              # 全部业务：bring-up + echo 数据面 + 观测面
├── sdkconfig.defaults      # 仅 CONFIG_ETH_USE_OPENETH=y
├── tools/
│   ├── run_qemu.sh         # 标准 QEMU 启动器（去 efuse 形态，tee run.log）
│   ├── verify.md           # nc 极简验证步骤（含第二连接排队演示）
│   └── bench.py            # N 连接 × M 消息 sha256 digest 校验压测
├── README.md               # 本文
└── run.log                 # 真实运行留存（128KB 未截断）
```
