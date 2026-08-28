# ex16 zero-copy-cases —— 零拷贝优化案例集

一个固件内五个可切换案例（`CONFIG_ZC_CASE`），每个案例都按「问题 → 拷贝版实现 →
零拷贝版实现 → 成对实测数字表 → 适用边界」组织，全部以 `esp_timer` 微基准 +
≥1000 轮 + 中位/P95/均值 + digest 校验做**同开机配对**对比（copy 版与 zc 版按块
交错，而非先后整段，把机器漂移摊到两种变体上）。

- 环境：ESP-IDF v6.0.2 + QEMU (openeth/SLIRP)，guest 得 `10.0.2.15/24`
- 负载：默认全部走 guest 内 `127.0.0.1` 自环；可选宿主反射器 `10.0.2.2:8331`
- **严禁把目的地址设为自身网卡 IP**（10.0.2.15）：持续 TCP 吞吐会咬死 tcpip 线程
  （Batch 8 gdb 取证卡在 `pbuf_free`/`g_lwip_protect_mutex`）

## 1. 五案例一览

| 案例 | Kconfig     | 主题                                      | 配对结论一句话                                |
| ---- | ----------- | ----------------------------------------- | --------------------------------------------- |
| A    | `ZC_CASE=1` | RX 就地解析：recv 回调直接读 pbuf payload | 均值 2.54→2.08µs/记录（省 18%）；栈帧深 +644B |
| B    | `ZC_CASE=2` | TX 分段提交：头/体分离 write+MORE         | 提交均值 15.74→13.09µs/消息（省 17%）         |
| C    | `ZC_CASE=3` | 接收路径层级拷贝差 raw/netconn/socket     | RTT 301/333/442µs（1.11×/1.47×）              |
| D    | `ZC_CASE=4` | 流式校验零落地 vs 落地整包再算            | CPU 持平（393 vs 362µs），内存 112KB→0        |
| E    | `ZC_CASE=5` | 诚实边界：COPY 被 IDF 硬编码强制          | apiflags 证据 + 2400 条 digest 全 PASS        |

案例 0（`ZC_CASE=0`，默认）为说明模式：打印案例目录 + 事实引用行，并在 8330 开
一扇入向命令门（hostfwd），`nc` 即可验证 SLIRP 入向路径。

## 2. 网络拓扑

```text
        宿主机 (Fedora)                                QEMU guest (ESP32, lwIP)
 ┌──────────────────────────┐                ┌─────────────────────────────────────┐
 │ tools/reflector.py       │                │  tcpip 线程（单线程，一切回调在此） │
 │  (可选) listen :8331     │◄───────────────┤  案例客户端 pump ──┐                │
 │        echo 回显         │   guest 出连   │                    ▼               │
 │                          │  10.0.2.2:8331 │  127.0.0.1 自环（默认负载路径）    │
 │ nc localhost 8330 ───────┼────────────────►  汇点 g_svc_main :8330          │
 │   (case0 命令口,hostfwd) │ hostfwd 入向   │  回声服务 :8332 raw（案例 C）      │
 │                          │                │  回声服务 :8333 netconn（案例 C）  │
 └──────────────────────────┘                │  回声服务 :8334 socket（案例 C）   │
                                             └─────────────────────────────────────┘
  ※ 全部负载目的地 = 127.0.0.1 或 10.0.2.2，绝不用 10.0.2.15（自身 IP）
```

端口纪律（SPEC §4）：8330 为主服务口（hostfwd `tcp::8330-:8330`），8331 为出连
宿主反射器；8332/8333/8334 是 guest 本地环回端口，不出网卡、不占 SLIRP 号段。

## 3. 构建与运行

```bash
# 一次性环境
. ~/esp/esp-idf/export.sh
cd practice/lwip-examples/ex16-zero-copy-cases

# 单案例构建（以案例 A 为例；切案例只需换 caseN 变体文件）
rm -f sdkconfig
SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.case1" idf.py -B build-case1 build

# 出镜像（monitor 因无 TTY 失败属预期；重复构建后可能静默不出图，用 merge-bin 兜底）
idf.py -B build-case1 qemu monitor < /dev/null || true
(cd build-case1 && python -m esptool --chip esp32 merge-bin \
   -o qemu_flash.bin --pad-to-size 4MB @flash_args)

# 运行（去 efuse -global 行的形态；并行实验按镜像路径精确 kill，禁止 pkill）
BUILD_DIR=build-case1 LOG=runs/case1.log tools/run_qemu.sh 100

# 一键归档全部案例（大耗时，可分段：tools/run_all.sh 0 1 / 2 3 / 4 5）
tools/run_all.sh
```

说明：改 `sdkconfig.defaults*` 后必须删 `sdkconfig` 重生成（Batch 1 教训）；
`run_all.sh` 已内置 merge-bin 兜底与 `EXREADY` 校验。

### 案例 0 命令门实测（runs/case0-door.log）

```text
$ nc localhost 8330 然后逐行输入：
== HELP == ex16 case0 command door. Commands: HELP CASES STATS HEAP UPTIME
== UPTIME == uptime_ms=13517 ready_rel_ms=12320
== BOGUS == ERR unknown cmd: BOGUS
```

固件侧同步打印 `EX16-DOOR cmd=HELP` / `cmd=unknown line='BOGUS'`。

## 4. 通用测量方法学

- **时钟**：`esp_timer_get_time()`（1µs 网格）。`sys_now()` 是 10ms tick 网格，
  严禁用于微基准。
- **同开机配对**：每个案例在一次开机内让 copy 版与 zc 版按块交错（每
  `CONFIG_ZC_BLOCK=300` 条切换一次变体）；案例 C 是三层轮换、案例 D 是
  LAND/STREAM 流级交错。避免"先测 A 后测 B"的机器漂移偏差。
- **统计**：每变体默认 1200 轮，报中位/P95/均值。esp_timer 是 µs 整数网格，
  亚微秒差值用多轮均值恢复分辨率（`mean_us` 带两位小数）。
- **digest 纪律**：所有承载内容带序号+校验和（magic/type/seq/len/hdr_sum/
  body_xsum），收端逐条校验；案例 D 另有 112KiB 模式流的 Fletcher32 golden
  对账；任何一轮错数据立即 `$$$ EXFAIL`。
- **闭环握手**：会话以 `RT_CTRL_END` 结束并要求 `RT_CTRL_ACK` 回环，
  杜绝"发完 ≠ 收全"的读数竞态；读统计一律在 ACK 到手之后。
- **上下文纪律**：一切 raw API 调用都在 tcpip 线程；任务侧发送经
  `tcpip_callback` 排程（`zc_cli_post_from_task`）。开发期曾因任务侧直接
  `tcp_write` 触发 `tcp_free_acked_segments` 断言崩溃——正是 ch15 的
  xtw 误用本尊。

机器可读行协议（CI 可 grep）：`$$$ EX16-FACT / EXREADY / EX16-CFG /
EX16-CATALOG / EX16-SAMPLE / EX16-RESULT / EX16-DIGEST / EX16-CITE /
EX16-EFLAG / EXFAIL / EXDONE`，过程行 `EX16-PROG / EX16-HEAP / EX16-STAGE /
EX16-PHASE / EX16-CLICONN / EX16-SRVUP`。

## 5. 案例 A —— RX 就地解析

**问题**：`tcp_recv` 回调拿到 pbuf 后，传统写法先 `memcpy` 到应用缓冲再解析；
就地解析直接在 pbuf payload 上读。省掉的那一跳值多少钱？回调里暂存缓冲对
tcpip 线程栈的隐性税是多少？

**拷贝版实现**：`caseA_on_rec` 拷贝快路——整条 `memcpy` 进暂存缓冲后跑
`zc_check_rec`（magic/len/hdr_sum/body_xsum 全套校验）。
**零拷贝版实现**：`want_zc` 记录直接把 pbuf 里的连续区指针喂给同一个校验函数，
零拷贝。两版校验工作量一致，差值就是搬运本身。

**contiguous 现实**：TCP 是字节流，SLIRP 分段交付让"记录整条落在本次回调的单一
连续区"并非理所当然。只有这种情况才走零拷贝；跨段记录必须先拼装（拷贝不可避
免），如实计入 `span_*` 且不混入配对统计——本次 2400 条记录里 866 条（36%）跨段。

**成对实测数字**（runs/case1.log，1200 轮/变体，记录 530B）：

| 指标（µs/记录）            | 拷贝版（memcpy+解析） | 零拷贝版（就地解析） | 差值                 |
| -------------------------- | --------------------- | -------------------- | -------------------- |
| 中位                       | 2                     | 2                    | 0（µs 网格抹平）     |
| P95                        | 3                     | 3                    | 0                    |
| **均值**                   | **2.54**              | **2.08**             | **0.46（-18.1%）**   |
| 样本数（contig 快路）      | 768                   | 766                  | —                    |
| 跨段记录（span，未入对账） | 432                   | 434                  | 拼装耗时 2350µs 合计 |

栈峰值探针（专批 200 条/变体，HWM 单调性：顺序固定先 ZC 后 COPY）：

| 指标                            | ZC 批后 | COPY 批后 | 差值 |
| ------------------------------- | ------- | --------- | ---- |
| tcpip 线程 HWM（FreeRTOS 单位） | 2324    | 2308      | 16   |
| 回调帧内对象最低地址差（字节）  | —       | —         | +644 |

帧地址差 644B ≈ 局部暂存缓冲 530B + 调用帧开销——这就是"回调里开大数组"对
tcpip 线程栈的真实附加税（该栈总量仅 ~4.6KB）。

**适用边界**：就地解析的前提是**记录完整落在单一连续区**（contiguous 检查必须
有，否则跨段记录会把解析撕裂）；解析必须轻（本例 O(n) 校验即上限），不得阻塞、
不得长占 tcpip 线程；只在 raw API 收包路径可用。

## 6. 案例 B —— TX 分段提交

**问题**：发送"头+体"消息，传统写法把两段拼进大缓冲后一次 `tcp_write`；
分段写法各自 `tcp_write` + `TCP_WRITE_FLAG_MORE`。省掉的用户侧拼接 memcpy
值多少钱？两次 write 调用的开销又是多少？

**拷贝版实现**：`memcpy(hdr)`+`memcpy(body)` 进 `s_b_stage`（整帧 1058B）后
一次 `tcp_write`。**零拷贝版实现**：`tcp_write(tpl_head,34,MORE)` +
`tcp_write(body,1024,COPY)`，各自引用自己的存储，无拼接。

**成对实测数字**（runs/case2.log，1200 轮/变体，消息 1058B）：

| 指标（µs/消息）      | 拷贝版（拼接+1 次 write） | 零拷贝版（2 次 write） |
| -------------------- | ------------------------- | ---------------------- |
| 提交总账中位         | 19                        | 15                     |
| 提交总账 P95         | 23                        | 20                     |
| **提交总账均值**     | **15.74**                 | **13.09（-16.8%）**    |
| 其中拼接 memcpy 分项 | 中位 2，均值 2.00         | 0（不存在这一跳）      |

分解：`拼接跳 2.00µs`；两 write 相对一 write 的调用开销 ≈ -0.66µs（分段后单次
拷贝更小，write 内部成本随之下降，抵消了多一次调用的开销）——净省 2.65µs/消息。

**边界（必须讲清）**：IDF 硬编码 `LWIP_NETIF_TX_SINGLE_PBUF=1` 使协议栈内部的
COPY **仍然存在**（见案例 E）。本案例省掉的只是**用户侧那次拼接 memcpy**；
"tcp_write 零拷贝"在 IDF 上不存在。计时段落只包住用户动作 + `tcp_write` 调用，
批末统一 `tcp_output` 冲刷不计入，两变体对称。

## 7. 案例 C —— 接收路径层级拷贝差

**问题**：同一回声负载（256B 记录，严格 ping-pong）分别走 raw / netconn /
socket 三层，应用侧每消息成本差多少？承接 ch10（UDP 三层 RTT 102.9/214.8/
287.6µs）与 ch15（TCP 回环 64B RTT raw 162µs vs socket 439µs）的分层税数据。

**实现**：三对独立的回环"客户端↔回声服务器"——raw 对全在 tcpip 线程回调驱动；
netconn 服务器任务 + 编排任务客户端（`netconn_recv_tcp_pbuf`）；socket 对同构
（SO_RCVTIMEO 兜底）。三层按 pass 轮换（`raw→netconn→socket` × 5 遍）实现同开机
配对；每条回声逐位校验后计入 RTT。

**成对实测数字**（runs/case3.log，1200 样本/层）：

| 层      | 中位 (µs) | P95 (µs) | 相对 raw |
| ------- | --------- | -------- | -------- |
| raw     | 301       | 390      | 1.00×    |
| netconn | 333       | 578      | 1.11×    |
| socket  | 442       | 782      | 1.47×    |

与章节实验的互证与差异解释：socket/netconn 的分层方向与 ch10/ch15 完全一致；
倍率比 ch15 的 2.7× 小，因为本例载荷 256B（ch15 为 64B）——载荷越大，每跳
固定开销占比越小，分层税被摊薄；且 ch15 口径含当时的机器负载差异。

**适用边界**：本例量化的是"应用侧每消息处理成本"（RTT 口径），不是纯 syscall
税；netconn/socket 换来的是可移植性与阻塞语义，raw 换来的是最低延迟——按场景
选层，不要无脑全 raw（回调里做重活会拖死整个协议栈，见 ch13/ch15）。

## 8. 案例 D —— 流式校验零落地

**问题**：收到 112KiB 流后要校验 Fletcher32（ex06 方法学）。「边收边算」把校验
融进收包热路径、零落地；「收完落地整包再算」需要整块驻留缓冲 + 第二遍扫描。
CPU 差多少？内存差多少？

**拷贝版（LAND）实现**：payload 全部 `memcpy` 进 112KiB 静态 arena，收完在
arena 上做一遍计时的 Fletcher32 sweep。
**零拷贝版（STREAM）实现**：recv 路径里直接 `f32_feed`，不落地任何 payload
（驻留只有当前记录 ~1.4KB）。

**成对实测数字**（runs/case4.log，各 3 条流，流长 114688B，6/6 digest 对上
golden `78c51387`）：

| 指标                   | 落地再算（LAND） | 边收边算（STREAM）   |
| ---------------------- | ---------------- | -------------------- |
| Fletcher32 总耗时 (µs) | 393 / 257 / 790  | 345 / 362 / 1057     |
| **中位**               | **393**          | **362**              |
| 峰值额外内存（字节）   | **114688**       | **≈0（单记录量级）** |

**诚实结论**：CPU 两侧统计上持平（FNV/Fletcher 该算的都算了，流式还占着收包
热路径）——**零落地买的是内存峰值 112KB→0，不是 CPU**。在 240KB 级自由堆的
ESP32 上，这 112KB 决定了"能不能同时干别的"。数据点抖动大（QEMU 吞吐受宿主
负载影响 ±50%，CONVENTIONS Batch 4）但配对内趋势稳定。

## 9. 案例 E —— 诚实边界（必做）：COPY 被硬编码强制

**问题**：通用 lwIP 教程说 `tcp_write(pcb, buf, len, 0)`（不带
`TCP_WRITE_FLAG_COPY`）是零拷贝提交。在 ESP-IDF 上照做会发生什么？

**证据一：源码引用**（固件每次开机都打印，`$$$ EX16-CITE` 行）：

> `components/lwip/port/include/lwipopts.h` **line 765**：
> `#define LWIP_NETIF_TX_SINGLE_PBUF  1` —— 硬编码，不是 Kconfig 旋钮。
>
> `components/lwip/lwip/src/core/tcp_out.c` **lines 425-428**：
> `#if LWIP_NETIF_TX_SINGLE_PBUF` / `/* Always copy to try to create single
pbufs for TX */` / `apiflags |= TCP_WRITE_FLAG_COPY;` —— `tcp_write` 入口
> 无条件强制 COPY，调用方传什么都一样。

**为什么**：该宏假设 TX 走单 pbuf（DMA 网卡不支持 scatter-gather，如 ESP32
内部 EMAC）；强制拷贝还让 lwIP 在拷贝时顺带做校验和预计算。

**证据二：apiflags 请求打印**（runs/case5.log）：

```text
$$$ EX16-EFLAG form=copy-explicit     req_apiflags=0x01 semantics='upstream=lwIP-private copy'
$$$ EX16-EFLAG form=nocopy-requested  req_apiflags=0x00 semantics='upstream=zero-copy reference; IDF=silently forced to COPY by port macro'
```

**证据三：行为学验证**（流水线深度 4，源缓冲滚动复用——消息 i 写完立刻让位给
i+1..i+4，若真走了引用语义，未 ACK 的在途帧必然被撕碎）：

| 指标            | copy 显式请求 | no-copy 请求 |
| --------------- | ------------- | ------------ |
| 发送消息数      | 1200          | 1200         |
| 回声逐位 digest | 全 PASS       | 全 PASS      |

```text
$$$ EX16-DIGEST item=E-roundtrip status=PASS verified=2400 planned=2400
$$$ EX16-RESULT case=E kind=evidence copy_form_sent=1200 nocopy_req_sent=1200 verdict=PASS
```

两种形态行为完全一致且内容无损——只有 COPY 被静默强制时才会如此。**推论**：
在 IDF 上 `tcp_write` 后立即复用源缓冲是**安全的**；把上游"必须等 ACK 才能动
缓冲"的守则搬过来是白白自缚（反之，在允许真零拷贝的移植上照搬 IDF 写法会
踩数据撕裂）。

**编译期兜底**：`zc_casee.c` 里有
`#if LWIP_NETIF_TX_SINGLE_PBUF != 1 #error ...`——换了上游环境的移植构建本例
会当场编译失败，防止读者拿着错误前提跑数字。

**替代路径**：真零拷贝 TX 需要（a）自备 netif 移植并把
`LWIP_NETIF_TX_SINGLE_PBUF` 置 0（openeth/SLIRP 环境做不到），或（b）走上游
pbuf 引用语义可用的环境。RX 侧的零拷贝（案例 A）不受此限制，随时可用。

## 10. 已知边界与排障

| 现象                                             | 原因与处置                                                                                                 |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `tcp_free_acked_segments` 断言崩溃               | 任务上下文直接调了 `tcp_write`（ch15 xtw 误用）。任务侧发送必须走 `tcpip_callback`                         |
| 第二条消息起汇点报 `absurd_len`，首条正常        | 拼接缓冲按"payload 尺寸"而非"整帧尺寸"声明，越界 18B 踩坏相邻静态区（本工程已修，`s_b_stage[B_WIRE_TOT]`） |
| 案例相位永不结束                                 | END 握手缺失/ACK 超时——所有相位必须以 `RT_CTRL_END`+ACK 闭环                                               |
| `Connection refused` 到 8330                     | case0 才开命令门；基准案例的汇点语法是记录流，不是行协议                                                   |
| 栈探针 HWM 差值不可信                            | HWM 是历史极值且单位随移植变化——本工程以"帧内对象地址差"为准，HWM 仅旁证                                   |
| QEMU NIC 未创建 / `esp_eth_mac_new_openeth` 崩溃 | runner 带 efuse `-global` 行的偶发坑——去掉该行（本工程 runner 已去）                                       |
| `qemu_flash.bin` 未更新                          | `idf.py qemu monitor` 静默失败（Batch 6）——用 merge-bin 兜底                                               |
| 目的地址写成 10.0.2.15 后 tcpip 咬死             | Batch 8 实锤：自环负载一律 127.0.0.1 或宿主反射器                                                          |

日志合规：所有归档日志 <10KB，远低于 1MB 截断线；`runs/*.log` 为真实运行留存，
`run.log` 为 case0 + 命令门演示的真实运行。

## 11. 文件导览

| 文件                             | 职责                                                     |
| -------------------------------- | -------------------------------------------------------- |
| `main/zc_priv.h`                 | 线格式/采样器/汇点/客户端 共享声明                       |
| `main/zc_common.c`               | 收帧引擎、raw 客户端基座、tcpip 桥、Fletcher32           |
| `main/zc_casea.c` ~ `zc_casee.c` | 五案例各自实现（头部注释即设计说明）                     |
| `main/main.c`                    | 骨架 bring-up、案例调度、case0 目录与命令门              |
| `tools/run_qemu.sh`              | QEMU runner（去 efuse 行，hostfwd 8330，精确 kill 注记） |
| `tools/run_all.sh`               | 全案例构建+运行+校验归档（可分段传参）                   |
| `tools/reflector.py`             | 可选宿主反射器（8331 回显，配合 `ZC_HOST_REFLECTOR=y`）  |
| `runs/case{0..5}.log`            | 六次真实运行归档                                         |
| `runs/case0-door.log`            | case0 命令门入向演示归档                                 |
