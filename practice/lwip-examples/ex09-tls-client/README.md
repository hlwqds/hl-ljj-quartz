# ex09：TLS 客户端模板（tls-client，诚实版）

`lwip-examples` 套件的 TLS **客户端**模板：guest 用 esp-tls（内嵌 Mbed TLS 4.1.0）连
宿主机 `openssl s_server`，完整演示「TCP 连接 → TLS 握手 → 应用记录往返 → 关闭」全周期，
并把本环境下真实发生的问题原样留档——

- **PHASE-A 外环主线**（10.0.2.2:8280）：握手全部成功、首条应用记录全部等不到响应
  （ch22 已知悬案①在本环境 9/9 复现）。示例代码内置 select 超时逃生舱，超时即报告
  并优雅关闭，绝不裸阻塞挂死。
- **PHASE-B 回环自连替代路径**（127.0.0.1:8281）：guest 内部起一个 esp-tls TLS echo
  服务端再用同一套客户端代码自连——回环上「握手 + 应用记录往返」全部走通
  （4/4 PASS），证明 guest 协议栈与 esp-tls 本身无辜，把问题域隔离在 SLIRP 边界。

> [!note] 这是"诚实版"示例的意义
> 教学模板最忌讳把 demo 跑通就行。TLS 在 QEMU SLIRP 外环上有一个传输层活着、
> 会话层僵死的现象，任何复用者都会撞上；本工程把它变成第一公民：现象如实测量、
> 代码内置逃生、证据链双端留存（run.log + sserv.log），另给一条能完整走通的
> 替代路径做对照。

## 网络拓扑

QEMU 用 SLIRP 用户态网络（无 hostfwd——外环只有 guest 出向流量；8281 只活在 guest 内）：

```text
      ESP32 guest (QEMU openeth)                    宿主机 (Fedora)
 ┌───────────────────────────────────┐        ┌────────────────────────────────┐
 │ PHASE-A: esp_tls 客户端任务       │        │ openssl s_server -rev         │
 │   10.0.2.15 ──TLS──► 10.0.2.2:8280 ╪═══════╪═► :8280 (self-signed RSA)     │
 │              （SLIRP 落到宿主机     │ SLIRP  │   ↑ 握手可达：ESTABLISHED 打印 │
 │                loopback 同端口）    │        │   ✗ 应用记录：kernel ACK 但    │
 │ PHASE-B: 同一客户端代码            │        │     进程永不回放（悬案①）      │
 │   自连 ──TLS──► 127.0.0.1:8281     │        └────────────────────────────────┘
 │          （guest 内 esp-tls echo） │
 └───────────────────────────────────┘
```

SLIRP 边界事实：guest 连 `10.0.2.2:P` 等价于宿主机连自己的 `127.0.0.1:P`，
所以对端就是宿主机上的普通进程，hostfwd 完全不需要。

## 文件结构

```text
ex09-tls-client/
├── CMakeLists.txt           # root 构建（MINIMAL_BUILD ON）
├── main/
│   ├── CMakeLists.txt       # PRIV_REQUIRES esp_eth esp_netif esp_event lwip
│   │                        #             esp_timer esp-tls mbedtls heap
│   ├── main.c               # 骨架 bring-up + PHASE-A/B 客户端（全部教学点带注释）
│   └── tls_local_certs.h    # PHASE-B 回环服务端的内嵌自签证书（生成命令见文件头）
├── tools/
│   ├── run_sserver.sh       # 一键生成自签证书 + 启动 openssl s_server
│   └── run_qemu.sh          # QEMU 启动器（timeout + tee run.log，无 efuse -global 行）
├── sdkconfig.defaults       # OPENETH + 软件密码实现 + INSECURE（跳过证书验证）组
├── certs/                   # 宿主端证书（run_sserver.sh 首次运行自动生成，无手工步骤）
├── run.log                  # guest 侧真实运行留存（118 行）
├── sserv.log                # 宿主侧同场运行留存（3 ESTABLISHED / 3 CLOSED / 0 回放数据）
└── README.md
```

## 构建与运行

### 构建（离线可重复，无 managed component）

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-examples/ex09-tls-client
idf.py set-target esp32        # 仅首次
idf.py build
# 生成 QEMU 镜像（monitor 会因无 TTY 失败，忽略它，镜像已生成）：
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在
```

> [!warning] 镜像新鲜度兜底
> 重复构建后 `idf.py qemu monitor` 可能静默失败（qemu_flash.bin 不再更新）。
> 手动合并兜底：
> `cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args`
> 并核对固件打印的 `EX09-FACT built="..."` 时间指纹。

### 运行

**终端 1** —— 启动宿主端 TLS 服务器（首次自动生成证书并打印指纹）：

```bash
cd practice/lwip-examples/ex09-tls-client
tools/run_sserver.sh | tee sserv.log
```

启动后应看到（真实输出）：

```text
SSERVO-GEN cert=certs/sserver.crt key=certs/sserver.key subject=/CN=localhost
SSERVO-FP sha256=FB:03:01:B2:C1:A8:95:A5:74:78:85:36:21:58:A1:19:2A:6D:2D:AC:75:B9:A1:F2:BC:68:5D:4A:0B:C7:67:FB
SSERVO-READY mode=rev port=8280 tls=tls1_2 waiting ...
Using default temp DH parameters
ACCEPT
```

证书说明：脚本用 `openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=localhost"`
一次性生成（`certs/sserver.crt` + `.key`，已存在则复用，`--renew` 强制重签）；仅限离线
QEMU 教学。`s_server -rev` 是"按行反转回显"——攒齐以 `\n` 结尾的一行才回放该行的逐字节
反转，所以固件探针行刻意以 `\r\n` 收尾。

**终端 2** —— 启动 QEMU（默认 90s 自动截停，退出码 124 属正常）：

```bash
tools/run_qemu.sh 90          # 串口输出落 run.log
```

全程约 40s：boot ~3s → 三轮外环尝试（每轮最多 ~9s，命中悬案即提前收手）→ 两轮回环
自连（每轮 ~1s）→ 进入空闲心跳。

### 结束时精确清理

长跑/自动化时请按 PID 杀进程，禁止 `pkill`（有并行实验实例共存）：

```bash
pgrep -af 'qemu-system-xtensa|openssl s_server'   # 找到目标 PID 后
kill <PID>
```

## run.log 真实输出摘录（本次实测，2026-08-27）

```text
EX09-FACT built="Aug 27 2026 13:31:36" idf_version=v6.0.2
I (2637) ex09: GOT_IP: 10.0.2.15
$$$ EXREADY outer=10.0.2.2:8280 local=127.0.0.1:8281 attempts=3+2 probe_len=41 escape_budget_ms=8000
EX09-MEM tag=boot-baseline  free=252268 largest=131072 min-ever=252248
EX09-PHASE name=TLS-OUTER target=10.0.2.2:8280 seq=1 expect=app-roundtrip
EX09-TCPPLUSHS seq=1 elapsed_ms=218 (tcp_connect+tls_handshake)
EX09-HS-OK version=TLSv1.2 suite=TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384 peer_cert_bytes=0
EX09-MEM tag=post-hs-1      free=229416 largest=110592 min-ever=219700
EX09-LEDGER seq=1 handshake_peak_delta=32548 (min-ever 252248 -> 219700)
EX09-WROTE seq=1 len=41 ms=1 -> waiting app record (budget 8000 ms)
EX09-APP-TIMEOUT seq=1 budget_ms=8000 got=0 -> KNOWN-ISSUE-HIT (SLIRP outer-loop TLS, see ch22 case#1); closing by escape hatch
EX09-MEM tag=post-close-1   free=255344 largest=110592 min-ever=219700
注：seq=2/3 同形态——握手 173~196ms 成功，应用记录 8s 无回应，逃生收手。
EX09-PHASEOVER name=OUTER attempts=3 pass=0 hang_escaped=3 hs_fail=0 short_echo=0
EX09-PHASE name=TLS-LOCAL target=127.0.0.1:8281 seq=4 expect=app-roundtrip
EX09-SRV session established fd=56
EX09-TCPPLUSHS seq=4 elapsed_ms=999 (tcp_connect+tls_handshake, loopback)
EX09-WROTE seq=4 len=41 ms=0 -> waiting app record (budget 8000 ms)
EX09-REPLY seq=4 len=41 xor_match=YES (xor order-independent: outer replies byte-reversed via s_server -rev, local echo returns as-is)
EX09-SRV session closed
EX09-PHASEOVER name=LOCAL attempts=2 pass=2 other=0
EX09-SUMMARY outer=pass:0/hang:3/hsfail:0/short:0 local=pass:2/other:0
```

宿主侧 sserv.log 同场关键证据——三次握手全部完成但零应用数据回放：

```text
CONNECTION ESTABLISHED
Protocol version: TLSv1.2
Ciphersuite: ECDHE-RSA-AES256-GCM-SHA384
CONNECTION CLOSED            ← 直接关闭：没有任何反转回显输出
（共 3 组 ESTABLISHED/CLOSED，其间没有出现任何探针内容）
```

跨双端对账成立：guest 发出了 41 字节探针（WROTE 成功）、宿主 kernel 完成了握手与
ACK，但数据从未抵达服务进程——这就是悬案①的现场。

## 已知现象与边界：SLIRP 外环 TLS 悬案①

### 现象

TLS 握手完全成功（协议版本/套件协商正常、双向 Finished 交换完毕），随后 client 写出的
首条**应用记录**永远得不到回应。表现为 guest 阻塞在等待读写直至放弃，而不是收到任何
错误。ch22 的取证结论（引用）：同一字节流在本机 python 客户端上瞬时往返；`tcpdump -X`
证明 guest 的记录完整到达宿主机 kernel 且每个 segment 都被 ACK——但服务进程永远不回放。
openssl（`-quiet` 有无一致）与 python ssl 服务端一致复现。

### 本次环境复现情况（如实测量，不回避）

| 时段                         | 尝试对象         | 握手                           | 首条应用记录                     |
| ---------------------------- | ---------------- | ------------------------------ | -------------------------------- |
| 本次交付会话三轮运行         | 外环 s_server ×9 | 9/9 成功（~200ms）             | 0/9 有响应，全部命中 8s 逃生预算 |
| 本次交付会话两轮运行         | 回环自连 ×4      | 4/4 成功                       | 4/4 完整往返                     |
| ch22 历史（Batch 6，供参考） | 外环             | 前期多次僵死，后期若干次能通过 | —                                |

即：**当前环境的复现概率接近必现**。ch22 后期曾观察到偶发通过的窗口，所以这不排除
与时序相关；读者在自己环境跑出 pass 也不足为奇——模板会把两种结果都如实统计出来
（看 `EX09-SUMMARY outer=pass:N/hang:N/...`）。

### 定位思路（为什么断定不在 guest）

PHASE-B 与 PHASE-A 共用同一套客户端代码（连接建立函数不同而已）：回环路径上同样的
esp-tls 版本、同样的探针、同样的等待逻辑，握手与应用记录往返全部正常。于是嫌疑只剩
SLIRP 出向边界的用户态转发环节——这正是"替代路径用于隔离问题域"的设计动机。

### 逃生舱设计动机（读代码前先看这个）

悬案的杀伤力在于它**不是报错而是无限挂死**：阻塞的 recv/read 既不会返回错误也不会
EOF，开发者最容易写出的正确 demo 在这里就是一枪毙命。因此本模板立了三条规矩：

1. **一切应用记录等待必须过超时预算**：`select()` 携带剩余预算等待 fd 可读，
   `nready==0` 即判定命中、打印 `KNOWN-ISSUE-HIT` 并立即关闭连接；
2. **不用 SO_RCVTIMEO 兜这条线**：SO_RCVTIMEO 能把底层 lwIP `recv()` 打断为 EAGAIN，
   但经 esp-tls 映射成 `MBEDTLS_ERR_SSL_WANT_READ` 后会被当"再试一次"，很容易写出
   忙轮询甚至漏判；`select` 在等待入口处一次裁决，语义最干净；
3. **挂死也不许拖死整机会话**：单轮预算 8s 固定（远大于正常 RTT ~5ms、又小于人
   注意力阈值），命中后 destroy 连接继续下一轮，最后统一汇总复现率。

### 对使用者的影响与建议

- 在 QEMU SLIRP 上演示/验证 TLS 数据面，优先用 PHASE-B 形态（回环自连）或直接引
  esp_https_client 类高层组件前先想清楚观测点；
- 把 guest 从 SLIRP 换成 tap/bridge 直通网络后此现象预期消失（未在本环境验证，属
  合理推断而非实测结论）；
- 生产真机不受影响：该问题是 QEMU SLIRP 边界的，不是 esp-tls/lwIP 的。

## 内存账本（加分项：握手前后 heap 三件套）

口径照搬 ch22（CONVENTIONS Batch 6）：`heap_caps_get_free_size / largest_free_block /
minimum_free_size(MALLOC_CAP_DEFAULT)` 三件套阶段即时快照 + min-ever 阶段差兜住采样
间隙里的握手峰值。

| 快照位（本轮 seq=1）      | free (B) | largest (B) | min-ever (B) |
| ------------------------- | -------- | ----------- | ------------ |
| boot 基线                 | 252268   | 131072      | 252248       |
| post-hs-1（握手完成后）   | 229416   | 110592      | 219700       |
| post-close-1（关闭+回收） | 255344   | 110592      | 219700       |

- **稳态增量 ≈ −22.9KB**（252268 → 229416，连接保持期间），与 ch22 实测 −27KB 同量级；
- **握手峰值增量 = 32548 B**（min-ever 252248 → 219700），与 ch22 的 33072 B 几乎一致；
- close 后 free 回到基线上方（255344 > 252268），残差为正说明本轮无泄漏积累。
- 三个诚实的口径警告（读 LEDGER 行前必看）：
  1. min-ever 是全局单调水位，**从第二轮起 delta 只反映"比历史更深的坑"**（实测
     seq=2 只有 12 B、seq=3 为 0），不代表第二轮没分配内存；
  2. PHASE-B 里 client/server 同池，快照混合两端分配量，不能当单连接成本引用；
  3. 跨阶段直接拿 free 相减失真（碎片与残留混合），要对照三件套一起读。

## CI 化断言（机器可读标记）

```bash
grep -q 'EX09-SUMMARY' run.log && \
grep -cE 'EX09-TCPPLUSHS' run.log                 # >= 5（3 外环 + 2 回环握手都成功）
grep -c 'EX09-REPLY .* xor_match=YES' run.log      # 回环应答数（本次实测 2）
grep -c 'EX09-APP-TIMEOUT' run.log                 # 悬案命中数（本次实测 3，如实记录）
grep -q 'EX09-MEM tag=final' run.log               # 内存账本收口快照存在
```

## 证书验证升级（pinning 路径）

默认姿势是"跳过验证"（自签证书不在任何信任链里）：`sdkconfig.defaults` 开启
`CONFIG_ESP_TLS_INSECURE + CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY`，cfg 不带信任锚即放行
任何证书。**生产工程严禁开启这一组**。升级为 CA 固定（pinning）三步：

1. sdkconfig 删掉上面两项（INSECURE 未开时带 cacert 才合法）；
2. 把 `tools/run_sserver.sh` 生成的 `certs/sserver.crt` 内容转成 C 字符串
   （格式参考 `main/tls_local_certs.h`），填入 cfg：

   ```c
   esp_tls_cfg_t cfg = {
       .cacert_buf   = (const unsigned char *)SERVER_CERT_PEM,
       .cacert_bytes = strlen(SERVER_CERT_PEM) + 1, /* PEM 必须含结尾 NUL！ */
       .common_name  = "localhost",                 /* 主机名对 CN/SAN 校验 */
       .timeout_ms   = 10000,
   };
   ```

3. 证书每次 `--renew` 后都要同步重嵌；common_name 与 CN 不匹配时报
   `MBEDTLS_ERR_X509_CERT_VERIFY_FAILED`，细节看 `EX09-HS-FAIL cert_flags=` 打印。

注意：修复 pinning 只解决"认证"，不影响悬案①——那是外环边界的数据面问题。

## 作为模板复制改造

- 换目标服务器：改 `HOST_IP_STR` / `PORT_TLS`（注意套件号段纪律 SPEC §4）；
- 改请求载荷：`g_probe` 一处即可，记得保住结尾 `\n`；
- 需要 mbedTLS 逐行日志排障：加 `CONFIG_MBEDTLS_DEBUG=y` +
  `CONFIG_MBEDTLS_DEBUG_LEVEL_VERBOSE=y` + `CONFIG_LOG_DEFAULT_LEVEL_DEBUG=y`
  （ch22 全记录就是这么抓的），日志量会暴涨，别忘了 run.log 截断政策；
- 分段计时 TCP/TLS 握手（staged 手法）：见 ch22 `lab_main.c` 的
  `set_conn_sockfd + set_conn_state(CONNECTING)` 用法；
- ECDSA 对照：宿主换 `-cert` 为 EC 证书即可（mbedTLS 侧无需改动）。

## 端口登记（套件号段 8280~8289）

| 端口 | 用途                                   | 方向                       |
| ---- | -------------------------------------- | -------------------------- |
| 8280 | 主服务槽(+0)：宿主 openssl s_server    | guest 出向（无需 hostfwd） |
| 8281 | 辅助槽(+1)：guest 内回环 TLS echo 服务 | 仅 guest 内部 127.0.0.1    |

## 排障速查

| 现象                                           | 定位                                                                                     |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| boot 即崩在 `esp_eth_mac_new_openeth()`        | QEMU 命令残留 efuse `-global` 行（必须用去掉它的形态，CONVENTIONS Batch 4）              |
| `SSERVO-LISTEN port=8280 FAILED errno=98`      | 8280 被占（并行实验/上一轮没退净），`ss -ltnp` 归属排查                                  |
| 全部 `EX09-HS-FAIL`                            | 忘了先起 `tools/run_sserver.sh`；或 s_server 死了看 sserv.log                            |
| 卡在 `waiting for DHCP lease ...`              | `-nic user,model=open_eth` 丢了；或上一轮 QEMU 未退净                                    |
| 外环 `EX09-APP-TIMEOUT` 但回环 `xor_match=YES` | 正常！就是本文档"已知现象"所述悬案①被正确逃生接住的样子                                  |
| 回环也失败                                     | 参考本地服务器打印 `EX09-SRV handshake failed`（查 `tls_local_certs.h` 是否损坏/栈溢出） |
| mirror 陈旧导致行为不符                        | 核对 `EX09-FACT built=` 指纹；用 README 的 merge-bin 兜底命令重生成镜像                  |
