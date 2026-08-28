# ex06 http-downloader —— HTTP 客户端下载模板（裸 socket 版）

ESP-IDF v6.0.2 + QEMU (openeth/SLIRP)。guest 用**裸 socket** 向宿主机下载 ~5 MiB 动态生成
的确定性伪随机内容：解析 `Content-Length`、分块读、Fletcher-32 流式校验、connect/read
双计时，三条错误分支（connect 超时、read 中途断开、Content-Length 缺失）各有真实日志。
手法参考官方 `examples/protocols/http_request` 的 GET 写法，但不依赖
`protocol_examples_common`，以太网 bring-up 用自带的 15 步标准骨架。

配套宿主服务端 `tools/serve.py`：按固定种子逐块生成伪随机 payload，
同一 `(seed,size)` 每次产出字节级相同的流，供多轮 digest 对账。

## 1. 网络拓扑

```text
     ┌─────────────────── QEMU (-nic user,model=open_eth) ───────────────────┐
     │                                                                       │
     │   guest ESP32 (openeth MAC 52:54:00:12:34:56)                         │
     │   IP 10.0.2.15/24  gw/DNS 10.0.2.2                                    │
     │            │                                                          │
     │            │ TCP 出连 10.0.2.2:8250（SLIRP 落到宿主 loopback 同端口） │
     └────────────┼──────────────────────────────────────────────────────────┘
                  ▼
        宿主机 python3 tools/serve.py 监听 127.0.0.1:8250
          GET /good.bin      → 5 MiB 全量 + Content-Length + X-Demo-Fletcher32
          GET /short.bin     → 承诺 5 MiB 只发 1/4 后带 LINGER=0 强断
          GET /nolen.bin     → 无 Content-Length（EOF 定界），校验和头保留
          GET /blackhole.bin → 头 + 64 KiB 后永久沉默
```

ex06 号段为 **8250–8259**（SPEC §4）：主服务 8250；8257 特意留空作 closed-port /
connect-timeout 探针槽位。guest→10.0.2.2 方向不需要 hostfwd。

## 2. 目录结构

```text
ex06-http-downloader/
├── CMakeLists.txt              # 根工程文件（MINIMAL 形态）
├── sdkconfig.defaults          # 仅 CONFIG_ETH_USE_OPENETH=y（SPEC §3 最小集）
├── main/
│   ├── main.c                  # 全部逻辑单文件（bring-up + 六轮下载时刻表）
│   └── CMakeLists.txt
├── tools/
│   ├── serve.py                # 宿主服务端（确定性内容 + 错误分支注入）
│   └── fault-connect-timeout.log # 附录 A 故障注入运行的完整真实日志
└── run.log                     # 正式验收运行的真实串口日志（本文所有摘录出处）
```

无 `idf_component.yml`、无 managed component——依赖全部来自 `${IDF_PATH}`
（`esp_eth`/`esp_netif`/`esp_event`/`lwip`/`esp_timer`），离线可重复构建。

## 3. 构建与运行

### 3.1 宿主端：启动确定性内容服务器

```bash
cd practice/lwip-examples/ex06-http-downloader
python3 tools/serve.py
# 终端第一行是“标准答案”，用来和 guest 结果对账：
# ex06-serve listening on 127.0.0.1:8250 size=5242880 seed=20260826 fletcher32=1e82586d
```

想换大小/种子：`python3 tools/serve.py --size 1048576 --seed 42`（size 必须是 4 的倍数）。

### 3.2 guest 端：构建并跑进 QEMU

```bash
cd practice/lwip-examples/ex06-http-downloader
. ~/esp/esp-idf/export.sh
idf.py set-target esp32          # 仅首次
idf.py build

# 生成 QEMU flash/efuse 镜像（monitor 在无 TTY 下失败属预期，镜像已生成；
# 若重复构建后 qemu_flash.bin 时间戳未更新，用 esptool merge-bin 手动兜底，见 §9）
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在且比 build/*.bin 新

QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 75 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run.log
```

注意 runner **没有 efuse `-global driver=nvram.esp32.efuse,...` 行**——该行在本机
QEMU 上偶发导致 openeth NIC 不创建（Batch 4 实测），示例统一去除此行。一次完整运行
约 15 s（固件 PHASE=READY→PHASE=DONE 计 11.5 s，见 run.log 时间戳）：六轮下载结束后
固件主动 `esp_restart()`，`-no-reboot` 使 QEMU 干净退出（退出码 0）；外层
`timeout 75` 只是兜底护栏（正常结束时不会触达）。

## 4. 运行时刻表（一次启动自动跑完六个场景）

| 轮次 | 目标             | 场景               | 预期结果                                                 |
| ---- | ---------------- | ------------------ | -------------------------------------------------------- |
| R1   | `/good.bin`      | 满血基准           | OK + 计时/校验对                                         |
| R2   | `/short.bin`     | 错误分支：中途断开 | TRUNCATED，容错退出                                      |
| R3   | `/good.bin`      | 交错回归           | 再次 OK（坏轮次不破坏后续好轮次）                        |
| R4   | `/nolen.bin`     | 错误分支：CL 缺失  | OK_NO_LEN（EOF 定界）                                    |
| R5   | `/blackhole.bin` | 附赠：读静默       | READ_TIMEOUT（SO_RCVTIMEO 救场）                         |
| R6   | `10.0.2.2:8257`  | closed-port 探针   | CONNECT_ERR；iptables 注入时变 CONNECT_TIMEOUT（附录 A） |

机器可读标记行（便于 CI 化抓取）：`[EX06] PHASE=READY/GOT_IP/DONE`、
`[DL] R=N BEGIN/RESULT ...`、`[EX06] SUMMARY ok=.. fail=.. avg_mbit_good=..`。

## 5. 真实输出摘录（全部出自本仓 `run.log`，未做任何润色）

首轮满血下载（进度条粒度 512 KB，注意首响应块夹带 body 前缀 1810 B）：

```text
I (2706) ex06: [EX06] GOT_IP 10.0.2.15 gw 10.0.2.2
I (2726) ex06: [DL] R=1 connected 10.0.2.2:8250 in 22 ms
I (2736) ex06: [DL] R=1 status=200 content_length=5242880 x_demo_fletcher32=1e82586d hdr_bytes=238
I (2736) ex06: [DL] R=1 progress 1 KB / first-chunk carry 1810B
I (2836) ex06: [DL] R=1 progress 514 KB
...
I (3246) ex06: [DL] R=1 RESULT status=OK bytes=5242880/5242880 f32_local=1e82586d f32_peer=1e82586d connect_ms=22 hdr_ms=10 xfer_ms=503 mbit=83.4
```

R3/R4（交错回归 + CL 缺失）：

```text
I (3766) ex06: [DL] R=3 RESULT status=OK bytes=5242880/5242880 f32_local=1e82586d f32_peer=1e82586d connect_ms=6 hdr_ms=2 xfer_ms=463 mbit=90.6
I (3776) ex06: [DL] R=4 status=200 content_length=-1 x_demo_fletcher32=1e82586d hdr_bytes=232
I (4236) ex06: [DL] R=4 RESULT status=OK_NO_LEN bytes=5242880/-1 f32_local=1e82586d f32_peer=1e82586d connect_ms=2 hdr_ms=2 xfer_ms=458 mbit=91.6
```

总账：

```text
I (14246) ex06: [EX06] SUMMARY ok=3 fail=3 avg_mbit_good=88.5 avg_rounds=3 host=10.0.2.2:8250
I (14246) ex06: [EX06] PHASE=DONE -- all branches exercised, restarting to exit QEMU
```

`ok=3` = R1/R3/R4；`fail=3` = 三个**故意制造**的故障场景。宿主端 serve.py 同步打印
对账行（同一轮内双端 Fletcher 一致）：

```text
[srv] 127.0.0.1 /good.bin: sent full fletch=1e82586d 255ms
```

宿主侧完整对账输出已归档 `tools/serve-host.log`（含冒烟与三次 QEMU 会话的分段说明，
服务端进程全程未重启；其中 short.bin 段服务端自记 `sent 1310720` 而 guest 只收到
446464 B，差异正是 §6.1 所述 LINGER=0 断连时的在途数据蒸发，双份记录互为印证）。

## 6. 错误分支行为对照（现象 + 处理 + 真实日志）

### 6.1 read 中途断开 —— `/short.bin`

服务端承诺 `Content-Length=5242880` 但只写 1/4 就带 `SO_LINGER(1,0)` 强断（模拟
进程死亡）。guest 在 `bytes_got < bytes_want` 时收到连接终止，判 TRUNCATED 并清理
现场继续下一轮：

```text
W (3296) ex06: [DL] R=2 TRUNCATED: EOF at got=446464 but Content-Length=5242880 (少发 4796416 B 后断开)
I (3296) ex06: [DL] R=2 RESULT status=TRUNCATED bytes=446464/5242880 f32_local=00000000 f32_peer=1e82586d connect_ms=9 hdr_ms=3 xfer_ms=0 mbit=0.0
```

> 注意实收 446464 B 小于服务端写出的 1310720 B：LINGER=0 丢弃发送缓冲 + SLIRP 断连
> 时在途数据一并蒸发，这正是「中途死掉」的字面含义，不是 bug。

### 6.2 Content-Length 缺失 —— `/nolen.bin`

头里没有 CL，客户端退化为 **EOF 定界**：无法预知长度、不能提前截断，只能读到对端关
闭为止，完整性交给 `X-Demo-Fletcher32` 头对账（HTTP/1.0+EOF 定界的天然局限，纯
HTTP 里更规范的解法是 chunked TE 或尾部 hash 清单，本示例刻意不做——保持裸 socket
最小教学面）。观察 R4 日志 `content_length=-1` 但最终 `OK_NO_LEN` 且双端校验和一致。

### 6.3 read 静默超时 —— `/blackhole.bin`（SO_RCVTIMEO 救场）

服务端发完头 + 64 KiB 后不再发送也不关闭。阻塞 recv 会无限挂着，SO_RCVTIMEO 到点
返回 EAGAIN，客户端据此分类 READ_TIMEOUT、关闭 socket、继续日程：

```text
W (14246) ex06: [DL] R=5 recv timeout after 10s: got=65536 want=5242880（SO_RCVTIMEO 救场，连读静默服务端）
```

### 6.4 connect 阶段的两个形态

closed-port 探针（默认运行，SLIRP 把 SYN 转给宿主 loopback，无人监听被拒）：

```text
W (14246) ex06: [DL] R=6 RESULT status=CONNECT_ERR errno=104(Connection reset by peer) connect_ms=1 note="connect 阶段失败，deadline=5s"
```

connect 超时形态需要网络层把 SYN 黑洞掉（Linux 内核总是秒回 RST，纯用户态造不出
“挂起”），用 iptables 注入，见附录 A。

## 7. 关键实现讲解（嵌入式 HTTP 客户端的正确姿势）

### 7.1 非阻塞 connect + 应用级死线

lwIP 阻塞 connect 放弃时间由 SYN 重传预算决定（`SYNMAXRTX × RTO` 背退，分钟量级），
嵌入式设备必须自己封顶：

```c
fcntl(s, F_SETFL, flags | O_NONBLOCK);
rc = connect(...);                       /* 通常立刻 EINPROGRESS */
fd_set wfds; FD_ZERO(&wfds); FD_SET(s, &wfds);
struct timeval tv = { .tv_sec = CONNECT_DEADLINE_SEC };
rc = select(s + 1, NULL, &wfds, NULL, &tv);
/* rc==0 → 应用死线触发，不等协议栈慢慢重传；成功后 getsockopt(SO_ERROR) 取真因 */
```

无论成败都要把 O_NONBLOCK 还原再进入收发阶段（错误路径同样 close 掉 fd）。

### 7.2 分块读 + 流式 Fletcher-32

body 用 4 KB 缓冲搬运，Fletcher-32 边收边算（359 字防溢出批长，与 zlib 相同），
5 MiB 从不整包驻留内存。本地终值与服务端 `X-Demo-Fletcher32` 头比对。踩坑记录：
初版用 `pending_byte == 0xFF` 当「无半字」哨兵，随机 payload 里真实的 0xFF 低字节
撞了哨兵导致丢字错算（现象即 §7 所述 CHECKSUM MISMATCH），修复为显式 `has_lo`
布尔标志后三处实现（宿主 block 版 / 宿主流式版 / guest C 版）逐位一致。
教训：**校验器的状态标志不能用可能出现在数据流里的值**。

进度行不是每个 recv 都打（会把 UART 打成瓶颈），只在跨过 512 KB 边界时打一条。
教训：**校验器的状态标志不能用可能出现在数据流里的值**——正式归档前的一版固件正因此
错算，被「guest 本地值 vs 服务端头字段 vs 宿主独立参考实现」三方对账当场揭穿。

### 7.3 双计时口径（ch6 方法学）

`RESULT` 行拆三个时长：`connect_ms`（socket→建链）、`hdr_ms`（建链→响应头收齐）、
`xfer_ms`（首字节 body→收尾）。吞吐只按 `xfer_ms` 计——把 DNS/握手等待摊进下载
速率是常见的口径污染。计数网格用 `esp_timer_get_time()`（µs 级）而不是 `sys_now()`
（10 ms 粗格，Batch 4 实测）。

### 7.4 完整关闭

请求显式 `Connection: close`（HTTP/1.0 服务端回完即关），客户端收满 CL 字节即停，
`shutdown(SHUT_RDWR)` + `close()` 收尾。每轮打印下载前后 free heap 差值，验证错误
路径同样回收干净——run.log 实测：R1 完成 +4064 B（首轮一次性结构预热）、
R2/R3/R4 恒 `delta=0`，唯 read 超时轮残留 `delta=224`（超时路径的瞬时分配，
观察窗内不再扩大），证明六种结局都没有泄漏累积。

## 8. 吞吐数字与 SLIRP 天花板声明

本次验收运行（同窗口三次大块成功轮次）：83.4 / 90.6 / 91.6 Mbit，均值 **88.5 Mbit**
（SUMMARY 行），开销构成：每 512 KB 一条 UART 进度日志、单任务 recv 循环 + VFS
memcpy、SLIRP 用户态转发本身。

**天花板上下文（引用既有实测，不要拿这里的数字当 ESP32 性能）**：CONVENTIONS
Batch 2 实测 SLIRP 外环吞吐封顶 **~120 Mbit**，且与 lwIP 发送缓冲旋钮无关（瓶颈在
SLIRP 而非协议栈）；ch24 进一步给出「窗口×RX 环深不等式」（WND=11520 需 openeth RX
环 ≥16，否则吞吐坍缩到个位数）。另据 Batch 4，QEMU 吞吐受宿主机负载影响 ±50%：
**对比实验必须同时段开机配对测量**，隔天数字不可比。本示例作为功能模板未调优,
距离天花板的差距主要来自进度日志频率——把 `PROGRESS_STEP` 调大即可逼近。

## 9. 已知边界与排障

- **重定向不做**：301/302 跟随涉及多轮 Location 解析，超出模板定位；非 2xx 直接报
  `HTTP_BAD_STATUS` 退出本轮。
- **chunked 不支持**：EOF 定界模式下若对端发 chunked 编码会当原文存进校验（教学版
  明确不做 TE 解码）。
- **响应头上限 2048 B**：防畸形服务端撑爆累积缓冲，超出报 `HEADER_TOOLONG`。
- **HOST 钉死数值 IP**：骨架走 `getaddrinfo()` 统一入口，扩到域名时 SLIRP 的 DNS
  代理（10.0.2.3）会查宿主 `/etc/hosts`（ch3/ch7 实测）。
- **runner 去掉了 efuse `-global` 行**：带上它 NIC 偶发不创建，guest 会崩在
  `esp_eth_mac_new_openeth()`（Batch 4 悬案）。见到 `[EX06] ETH START` 都没打出来先查这里。
- **qemu_flash.bin 时效**：`idf.py qemu monitor` 在重复构建后可能静默失败。核对时间
  戳；兜底：`cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin
--pad-to-size 4MB @flash_args`，配合固件打印的 `[EX06] build <date time>` 指纹核对。
- **closed-port 探针看到的 errno 是 104 不是 111**：SLIRP 把宿主 loopback 的拒绝转
  成中程 RST，lwIP 侧呈现为 ECONNRESET；语义等价「无人应答」，分类上同归 connect 阶段失败。
- **端口账本**：8250–8259 归 ex06（§4 号段表）；并行作者跑其它示例互不影响——本例
  不占 hostfwd，但 serve.py 的 8250 若被占用会 `OSError: Address already in use`，
  先 `ss -ltnp | grep 8250` 按归属处理。

## 附录 A 故障注入：connect 黑洞超时（需宿主 root，可选加分场景）

纯用户态造不出内核级的「SYN 静默丢弃」，用 iptables 对 loopback 单端口打一条 DROP，
让 R6 探针从「秒拒」变成「真·超时」。规则范围最小化（127.0.0.1 + dport 8257），
跑完立即还原：

```bash
sudo iptables -I OUTPUT 1 -d 127.0.0.1 -p tcp --dport 8257 -j DROP
# …照常起 serve.py 并运行 QEMU…
sudo iptables -D OUTPUT 1    # 还原，勿省
```

该配置下的完整真实日志已存档于 `tools/fault-connect-timeout.log`，探针轮的变化：

```text
I (14283) ex06: [DL] R=6 BEGIN path=/probe host=10.0.2.2:8257
W (19293) ex06: [DL] R=6 RESULT status=CONNECT_TIMEOUT errno=119(Connection already in progress) connect_ms=5008 note="connect 阶段失败，deadline=5s"
```

`connect_ms=5008` 即 5 秒应用死线精确触发（select 到点返 0，不等协议栈继续重传
SYN）。`errno=119 (EINPROGRESS)` 是 connect 返回后未被覆写的陈旧 errno——select
超时路径不会设置新 errno，这也提醒我们：**应用层超时要自己命名语义，别拿 errno
讲故事**。其余五轮不受影响（该 boot SUMMARY 均 `ok=3 fail=3`、均值 89.4 Mbit）。

## 附录 B 与官方 http_request 示例的差异

| 维度     | 官方 http_request                    | 本示例                                        |
| -------- | ------------------------------------ | --------------------------------------------- |
| 接入层   | `example_connect()`（WiFi/Eth 封装） | 自带 openeth bring-up 骨架（无 managed 依赖） |
| 读法     | 64 B 小缓冲, 内容直接 putchar        | 4 KB 分块 + 流式校验 + 进度 + 计数            |
| 超时     | 仅接收超时                           | connect 死线 + SNDTIMEO + RCVTIMEO 三保险     |
| 结果判定 | 打完就完                             | 状态机分类十种结局 + 机器可读标记行           |
| 循环方式 | while(1) 永动                        | 六轮时刻表跑完 `esp_restart()` 退出           |
