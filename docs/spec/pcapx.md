# Spec: pcapx —— lwIP 可插拔抓包模块（FreeRTOS + lwIP / ESP-IDF）

- 状态：**S1~S3 完成并验收通过**（2026-08-28）。验收要点：validate exit 0
  （total=107 arp=5 rx=53+tx=54）、DROP 恒等式精确成立（1003=0+918+85）、
  churn 100/100 无泄漏、零侵入复核（esp-idf diff 为空）、spec §4 观测点
  全量 grep 回归。实现期新增 KD-9（QEMU 半托管双通路，spec 设计前提修正：
  VFS 驱动依赖 OpenOCD，QEMU 走 SIMCALL——已实现 fallback）/KD-10（S1 环
  偏移致命缺陷的分层二分定位）/KD-11（QEMU 无 vTaskDelay 背压）。
  遗留：吞吐差 <5% 定量项留真机（本环境噪声 ±50% 测不准）。
  S4 番外文章可选，待用户点名。
- 运行环境：本仓库 lwip-labs 公约环境（ESP-IDF v6.0.2 / lwIP 2.2.0-dev / QEMU esp32 + openeth-SLIRP，见 `practice/lwip-labs/CONVENTIONS.md`）

## 1. Goals（本迭代）

- 交付组件 `pcapx`：**零修改** lwIP/IDF 源码的前提下，运行时可插拔地对任一 netif
  做**双向、链路层**抓包，产出 Wireshark 可打开的标准 pcap。
- 「可插拔」三个维度都有兑现：接入点运行时 attach/detach（换装 netif 函数指针）、
  sink 后端可插拔（QEMU 半托管文件 / RAM 环形缓冲 / UART 帧）、组件本身按 labs
  公约可被任意实验工程引用。
- 抓包路径遵守 RTOS 纪律：tap 上下文不阻塞、不分配内存、持有时间有上界；
  溢出策略明确且计数精确可审计。
- 全部行为有单行可 grep 的观测点（见契约），验收产物 = QEMU 实跑的
  run.log + capture.pcap + 宿主校验脚本退出码。

## 2. Non-goals（本迭代，及各自影响）

- BPF/pcap-filter 表达式：只做结构体硬过滤（方向/ethertype/ip_proto/port）。
  影响：按复杂表达式过滤的需求不满足，可用 Wireshark 侧 display filter 补救。
- 网络回传 sink（TCP/UDP 把 pcap 发给宿主机）：自指回路风险（捕获自身发送会
  递增流量、SLIRP 下污染样本）。影响：远程真机场景先用 UART sink。
- WiFi sniffer / Radiotap 802.11：本环境 QEMU 无 esp-wifi-mac（公约已证）。
  影响：真机 WiFi 抓包留待 BOX-3 到货后的迭代。
- 多 netif 并发 attach：API 形态预留，实现只保证单 netif。
  影响：bridgeif/多网卡实验不覆盖。
- 复用 espressif/pcap 组件做文件写入：自写 24 字节头（教学价值 + 零依赖）。
- 发布到组件注册表、CI 化：labs 自用。

## 3. 机制映射（参照实现已实读）

| 关注点        | 参照实现                                                                                              | 本模块（pcapx）                                                                                                                                       |
| ------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| RX 接入       | `LWIP_HOOK_IP4_INPUT`（lwIP 2.2.0-dev 实读 ip4.c:521，编译期宏、仅 IP 层、仅输入侧，返回 1 即"吃包"） | **运行时换装 `netif->input`**（链路层、含 ARP/非 IP，不改编译配置）                                                                                   |
| TX 接入       | 上游**无输出钩子**（hooks 全集实读 arch.h/opt.h，无 IP4_OUTPUT）                                      | **运行时换装 `netif->linkoutput`**（完整发出的以太网帧，含网栈自产流量）                                                                              |
| pcap 文件格式 | `espressif/pcap`（esp-protocols，注册表 v1.0.1，esp*pcap*\* API，仅文件写入层，不含 lwIP 接入）       | 自写：全局头（µs 魔数 0xa1b2c3d4、snaplen、LINKTYPE_ETHERNET=1）+ 记录头；S1 agent 须先读 esp-protocols/pcap 源码与 issue 再动工                      |
| QEMU 抓包     | 宿主侧 `filter-dump`（需把 `-nic user` 改写为 `-netdev`+`-object filter-dump`，仅 QEMU 有效）         | 目标侧 **半托管 sink**（IDF v6 实读 `xtensa/semihosting.h` + `esp_vfs_semihost.h`；QEMU 加 `-semihosting` 后目标直写宿主文件，真机也走同一 API 形态） |
| 通用回传      | —                                                                                                     | UART 帧协议 sink（4 字节魔数+len+CRC，抗日志穿插）+ 宿主收集脚本                                                                                      |
| 缓冲与线程    | —                                                                                                     | SPSC 环形缓冲：tap 侧（eth 任务/tcpip 线程/应用线程混合上下文）只做时间戳 + `pbuf_copy_partial`（截 snaplen）+ 入环；专职 writer 任务出环写 sink      |

关键设计决定（附理由）：

- **换装指针而非编译期钩子**：唯一能同时覆盖 RX+TX、链路层、且"可插拔"的接入点；
  代价是 detach 有竞态窗口——契约如实约束（见 detach 行）。
- **溢出丢新不丢旧**：保序（被接受样本时间戳单调），丢新计数语义简单可审计。
- **wrap 常驻 + 原子使能位**：attach 后 wrap 永久安装在 netif 上，capture 由
  原子 flag 门控；detach 恢复指针建议在链路静默期执行（契约注明）。

## 4. 行为契约（每行含观察点）

- `pcapx_attach(netif, cfg)` 成功：该 netif 的 RX/TX 帧进入环形缓冲并被 writer 写出
  → obs: `I (t) pcapx: ATTACH netif=st mode=rx+tx snap=128 sink=semihost:/tmp/cap.pcap`
- attach 时 netif 未 up / 已 attach / sink 打开失败：拒绝并给出可操作错误
  → obs: `E (t) pcapx: ATTACH_FAIL netif=st reason=down|busy|sink_open`
- 半托管 sink 在未开 `-semihosting` 的 QEMU 里：打开即失败，错误带修复提示
  → obs: `E (t) pcapx: SINK_OPEN_FAIL path=/tmp/cap.pcap hint='qemu 需追加 -semihosting'`
- tap 路径不阻塞不分配：帧到达只做拷贝入环；环满丢**新**帧并计数（每聚合
  N=32 次打一条，防刷屏）
  → obs: `W (t) pcapx: DROP cnt=123`（累计值可 grep 对账）
- 超过 snaplen 的帧截断记录（caplen < origlen），trunc 计数
  → obs: `pcapx_get_stats()` 字段 `truncated`
- `pcapx_detach(netif)`：恢复原始指针路径直通，打印会话总计
  → obs: `I (t) pcapx: DETACH netif=st rx=120 tx=88 drop=3 trunc=12`
- 产物合法性：Wireshark / python 可解析，全局头与记录头字节正确
  → obs: `python3 tools/pcapx_validate.py <file>` exit 0，输出包计数摘要
- 计数精确性：UDP 定向打流 N 包，capture 包数 + drop + (因过滤规则排除的)
  == 协议栈收发总数
  → obs: validate 脚本 `--expect` 断言失败时 exit 非 0
- 零侵入性：lwIP 与 IDF 源码零 diff，sdkconfig 不新增任何 `LWIP_HOOK_*` 宏
  → obs: `git -C ~/esp/esp-idf diff --stat` 为空（组件 README 记录核查步骤）
- 不 attach 时近乎零开销：wrap 已装但 flag 关闭时 iperf 吞吐差 < 5%
  → obs: lab 实验记录表（iperf 前后对照，run.log 存证）

## 5. 验证计划（证据来源绑定）

- pcap 字节正确性：validate 脚本（纯 python struct 解析，无 scapy 依赖）对
  golden 样本与实跑产物双重校验；S2 交付脚本，S3 交付实跑证据。
- 集成主实验：`practice/lwip-pcapx-lab/`（复制 ch3 以太网模板起步，公约流程）：
  DHCP 得 10.0.2.15 → attach → `nc` 收发 + iperf UDP 打流 → detach →
  宿主 `-semihosting` 文件落地 → validate 断言 ARP/DHCP/UDP 计数。
- 丢包账目实验：ring 缩到 4KB + snaplen=64 + iperf 满速 → DROP 累计与
  `rx+drop` 恒等式核对（脚本断言）。
- 观测点全量回归：契约每行的日志在 run.log 中逐条 grep（S3 出回归清单表）。
- 竞态冒烟：attach/detach 交替 100 次于 iperf 进行中 → 无 crash、无泄漏
  （heap before/after 对账）。

## 6. 任务拆分与扇出（process，确认后执行）

- **S1 核心组件**（`practice/pcapx/`）：换装/恢复、SPSC 环、tap 拷贝路径、
  Kconfig、全部日志观测点。前置：clone/读 esp-protocols/pcap 参考源码与 issue。
- **S2 sink 与宿主工具**：半托管 sink（含 `-semihosting` 冒烟）、RAM sink +
  esp_console 导出子命令、UART 帧 sink + `tools/pcapx_uart_collect.py`、
  `tools/pcapx_validate.py`。与 S1 并行。
- **S3 集成 lab 与验收**（依赖 S1+S2）：`practice/lwip-pcapx-lab/` 全流程 +
  验证计划全项 + 观测点回归表 + 结算。
- **S4 番外文章**（可选，依赖 S3 产物）：并入 lwIP 系列「给 lwIP 造一个可插拔
  抓包模块」，交叉引用系列 netif 章节。

依赖：S1 ∥ S2 → S3 → S4。实现期间新踩的坑按公约记 `docs/decisions.md` KD-8+。
