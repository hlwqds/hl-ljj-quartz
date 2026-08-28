# ex03：TCP 回显客户端（tcp-echo-client）

`lwip-examples` 套件的 TCP **客户端**模板：guest 主动外连宿主机 loopback 的回显服务器，
一次运行依次演示四个场景——

| 场景    | 目标端口 | 对端行为                | 固件演示的错误分支                     |
| ------- | -------- | ----------------------- | -------------------------------------- |
| REFUSED | 8225     | 无进程监听              | connect 被拒（服务器未启动）           |
| TIMEOUT | 8221     | accept 后沉默不回       | SO_RCVTIMEO 到期 -> EAGAIN             |
| RESET   | 8222     | 读走首条消息后 RST 掐线 | 中途断开 -> ECONNRESET                 |
| ECHO    | 8220     | 正常逐条回显            | 正常路径 + Fletcher-16 对账 + 优雅关闭 |

错误分支沿用 ch16「错误账本」纪律：每个失败分支都打印 `rc / errno / 符号名 /
strerror / 耗时`，以实测为准。**lwIP socket 层的 errno 与 Linux 有实质出入**，
对照见下文[三场景对照](#三种错误分支现象对照)。

## 网络拓扑

QEMU 用 SLIRP 用户态网络（无 hostfwd——本示例只有 guest 出向流量）：

```text
     ESP32 guest (QEMU openeth)                宿主机 (Fedora)
 ┌─────────────────────────────┐          ┌──────────────────────────┐
 │  10.0.2.15/24  ex03cli 任务 │          │  python3 tools/listener.py
 │        │                    │          │   ├─ :8220 echo   （回显）│
 │        ▼ TCP SYN            │          │   ├─ :8221 silent （沉默）│
 │   10.0.2.2:P ═══════════════╪══════════╪═► :8222 reset （RST）     │
 │  （SLIRP 把出向连接落到       │  SLIRP   │   └─ :8225 永远没人听     │
 │    宿主机 loopback 同端口）   │          │                          │
 └─────────────────────────────┘          └──────────────────────────┘
```

SLIRP 边界事实：guest 连 `10.0.2.2:P` 等价于宿主机连自己的 `127.0.0.1:P`
（CONVENTIONS C-12）。所以对端就是宿主机上的普通进程，hostfwd 完全不需要。

## 文件结构

```text
ex03-tcp-echo-client/
├── CMakeLists.txt          # root 构建（MINIMAL_BUILD ON）
├── main/
│   ├── CMakeLists.txt      # PRIV_REQUIRES esp_eth esp_netif esp_event lwip esp_timer
│   └── main.c              # 骨架 bring-up + 四场景客户端（全部教学点带注释）
├── tools/
│   ├── listener.py         # 宿主端三模式监听器（单文件 stdlib）
│   └── run_qemu.sh         # QEMU 启动器（timeout + tee run.log）
├── sdkconfig.defaults      # 只有 CONFIG_ETH_USE_OPENETH=y
├── run.log                 # 真实运行留存（本次 104 行，全四场景 PASS）
└── listener.log            # 宿主端同场运行留存
```

## 构建

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-examples/ex03-tcp-echo-client
idf.py set-target esp32        # 仅首次
idf.py build
# 生成 QEMU 镜像（monitor 会因无 TTY 失败，忽略它，镜像已生成）：
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在
```

> [!warning] 镜像新鲜度兜底
> 重复构建后 `idf.py qemu monitor` 可能静默失败（qemu_flash.bin 不再更新）。
> 手动合并兜底：`cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args`
> 并核对固件打印的 `EX03-FACT built="..."` 指纹。

## 运行

**终端 1** —— 启动宿主端三模式监听器（推荐 `--all` 一口气起全三个端口）：

```bash
cd practice/lwip-examples/ex03-tcp-echo-client
python3 tools/listener.py --all 2>&1 | tee listener.log
```

启动后应看到（真实输出）：

```text
$$$ LSTREADY mode=echo port=8220
$$$ LSTREADY mode=silent port=8221
LST-ALL modes=echo:8220,silent:8221,reset:8222 waiting ...
$$$ LSTREADY mode=reset port=8222
```

**终端 2** —— 启动 QEMU（默认 90s 自动截停，退出码 124 属正常）：

```bash
tools/run_qemu.sh 90          # 串口输出落 run.log
```

固件在拿到 DHCP 租约后按固定时刻表跑完四场景（约 35s），随后进入空闲心跳。
要复刻单场景，也可以只起对应模式：`python3 tools/listener.py --mode reset` 等。

### 结束时精确清理

长跑/自动化时请按 PID 杀 QEMU，禁止 `pkill`（有并行实验实例共存）：

```bash
pgrep -af qemu-system-xtensa        # 找到目标 PID 后
kill <PID>
```

## 三种错误分支现象对照

以下数值全部来自本仓 `run.log` + `listener.log`（同时段配对测量），不是理论推导。

| 场景          | 复现条件                   | guest 实测现象                                                              | listener.log 关键行                           | 根因                                                                                                  |
| ------------- | -------------------------- | --------------------------------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| 服务器未启动  | 什么都不听 8225 就 connect | `connect rc=-1 errno=104(ECONNRESET) elapsed_ms=10.0`                       | （无任何连接记录）                            | SLIRP 代答 RST；lwIP err.c 无 ECONNREFUSED 映射条目，拒绝由 ERR_RST 承载                              |
| 中途断开      | 8222 reset 监听器          | 发送成功后 `recv n=-1 errno=104(ECONNRESET) waited_ms=5`                    | `read_bytes=256 digest_rx=3f1f drop_mode=RST` | 对端读完数据后以 SO_LINGER(1,0)+close 发 RST；FIN 给 EOF(0)，RST 给 -1+104，这是两者最直观的差别      |
| 对端超时/沉默 | 8221 silent 监听器         | `recv n=-1 errno=11(EAGAIN/EWOULDBLOCK) elapsed_ms=2996/2999`（可重入两次） | `swallowed_bytes=0 (never replied)`           | SO_RCVTIMEO 到期把阻塞 recv 打断为 ERR_TIMEOUT，err.c 将其映射为 EWOULDBLOCK（newlib 里 ==EAGAIN=11） |

### errno 教学点（源码级，防踩坑）

1. **为什么看不到 ECONNREFUSED？**
   `err_to_errno_table[]`（`~/esp/esp-idf/components/lwip/lwip/src/api/err.c`）里
   根本没有 refused 条目。「宿主无进程监听」在这个体系里是 SLIRP 回了 RST ->
   `ERR_RST(-14)` -> `ECONNRESET`。Linux 上同一现象才是教科书里的
   `ECONNREFUSED(111)`。判定代码请覆盖 RST/超时两类（本例 10ms 内即被拒，
   若链路静默丢包则会走另一条路变成 `ETIMEDOUT(116)`）。
2. **errno 数值域不是 Linux 的**。ESP-IDF 用 newlib errno：`EAGAIN=11`、
   `ECONNRESET=104`、`ECONNREFUSED=111`、`ETIMEDOUT=116`、`ENOTCONN=128`
   （Linux 上 ENOTCONN 是 107，注意别按数字写死判断，一律用宏名）。
3. **strerror 文案会骗人**。newlib 对 `EAGAIN` 的字符串是
   `"No more processes"`（历史上的 EMORE 继承物），日志里看着莫名，其实是收发
   超时的正解——对照本文表格即可安心。
4. **SO_RCVTIMEO 不需要开 Kconfig**。IDF port 在
   `components/lwip/port/include/lwipopts.h` 硬编码 `LWIP_SO_RCVTIMEO=1`。

## 正常路径：digest 双端对账

场景 D 发送 8 条编号消息（每条 256B，序号前缀 + 确定性填充图案），逐条 request/response；
双端各自累积 Fletcher-16（与 ch6 方法学同款算法），最后 shutdown(SHUT_WR)
半关闭 -> drain 到 EOF -> close：

```text
EX03-ROUND seq=01/08 bytes=256 rtt_ms=8 memcmp=equal
...
EX03-CLOSE graceful: shutdown(SHUT_WR) -> drain until EOF
EX03-CLOSE shutdown rc=0 (FIN queued)
EX03-CLOSE recv-final n=0 extra_bytes=0 (clean EOF from peer FIN)
EX03-DIGEST sent=7755 received=7755 total_bytes=2048 match=YES
```

```text
LST-ECHO-DONE conn#1 addr=127.0.0.1:34096 rx_bytes=2048 tx_bytes=2048 digest_rx=7755 digest_tx=7755 match=YES
```

跨边界对账成立：guest 写入端 `sent=7755` == 宿主接收端 `digest_rx=7755` ==
宿主回显端 `digest_tx=7755` == guest 接收端 `received=7755`，2048 字节无损往返。

## run.log 真实输出摘录（完整版见根目录 run.log）

```text
I (2680) ex03: GOT_IP: 10.0.2.15
$$$ EXREADY target=10.0.2.2 ports=8220:echo,8221:silent,8222:reset,8225:dead msgs=8x256
EX03-PHASE name=REFUSED target=10.0.2.2:8225 expect=connect-deny
EX03-CONNECT-DENY port=8225 rc=-1 errno=104(ECONNRESET:Connection reset by peer) elapsed_ms=10.0
EX03-PHASE name=TIMEOUT target=10.0.2.2:8221 expect=EAGAIN x2
EX03-TIMEOUT hit#1 n=-1 errno=11(EAGAIN/EWOULDBLOCK:No more processes) elapsed_ms=2996 -> EAGAIN branch taken
EX03-TIMEOUT hit#2 n=-1 errno=11(EAGAIN/EWOULDBLOCK:No more processes) elapsed_ms=2999 -> EAGAIN branch taken
EX03-PHASE name=RESET target=10.0.2.2:8222 expect=ECONNRESET
EX03-RST n=-1 errno=104(ECONNRESET:Connection reset by peer) waited_ms=5 -> connection killed by peer AFTER server consumed our message
EX03-PHASE name=ECHO target=10.0.2.2:8220 msgs=8 len=256 expect=digest-match
EX03-DIGEST sent=7755 received=7755 total_bytes=2048 match=YES
EX03-SUMMARY refused=PASS timeout=PASS reset=PASS echo=PASS
```

顺带一提（预期噪音白名单）：启动段固定出现 3 条 openeth MAC filter ioctl 报错
（`add mac address to filter not supported` 等），属已知虚拟网卡限制，不是故障
（C-05）；本次 boot 干净无 NIC 缺失告警。

## CI 化断言（机器可读标记）

验收只需 grep，不依赖人眼：

```bash
grep -c 'EX03-RES .*status=PASS' run.log            # >= 4
grep 'EX03-DIGEST' run.log | grep -q 'match=YES'
grep 'EX03-SUMMARY' run.log
```

## 作为模板复制改造

client_task 里每个阶段都是独立函数（`phase_refused/timeout/reset/echo`），骨架
bring-up 一个字都不用改。常见改造点：

- 换服务地址/端口：改 `PORT_ECHO` 等常量或直接传参化；
- 请求响应改双向大流量：照 ch06 的发送泵思路给 socket 层加非阻塞/select 轮询；
- 错误重试策略：REFUSED/RESET 类错误适合指数退避重连，TIMEOUT 类适合查对端健康
  再降级——三种语义别混为一谈。

## 端口登记（套件号段 8200~8299）

| 端口 | 用途                        | 方向       |
| ---- | --------------------------- | ---------- |
| 8220 | 主服务槽：正常回显          | guest 出向 |
| 8221 | 辅助槽(+1)：silent 超时演示 | guest 出向 |
| 8222 | 保留槽：RST 中途断开演示    | guest 出向 |
| 8225 | 保留槽：故意无人监听的靶子  | guest 出向 |

全部无需 hostfwd（SPEC §4 对 ex03 的约定）。宿主侧若 8220~8222 被别的进程占了，
listener 会打出 `LST-LISTEN mode=xx port=xx FAILED errno=98` 并跳过该模式。

## 排障速查

| 现象                                    | 定位                                                                               |
| --------------------------------------- | ---------------------------------------------------------------------------------- |
| boot 即崩在 `esp_eth_mac_new_openeth()` | 查 QEMU 命令是否残留 efuse `-global` 行（必须用去掉它的形态，CONVENTIONS Batch 4） |
| 所有场景 CONNECT-OK 但对账失败          | 8225 居然能连上 = 有人占用了保留槽；或 4 个端口串台，`ss -ltnp` 归属排查           |
| 场景 B/C 直接 FAIL reason=no-connection | 忘了先起 `tools/listener.py --all`；REFUSED 场景反而是它天然的工作状态             |
| 卡在 `waiting for DHCP lease ...`       | `-nic user,model=open_eth` 丢了；或上一轮 QEMU 未退净                              |
| TIMEOUT hit 的 elapsed 远小于 3000ms    | 对端其实回了数据——检查是否误用 echo 模式占了 8221                                  |
