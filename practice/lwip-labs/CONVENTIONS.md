# lwIP 深度解析系列 — 写作与实验公约

本文件是《lwIP 深度解析》系列全部章节作者（子 agent）的统一规范。写任何章节前先通读本文。

## 1. 环境事实（已验证，直接信任）

| 项                   | 值                                                                                                                                                                         |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ESP-IDF              | **v6.0.2**，位于 `~/esp/esp-idf`，激活方式 `. ~/esp/esp-idf/export.sh`                                                                                                     |
| 捆绑 lwIP 源码       | `~/esp/esp-idf/components/lwip/lwip/src`，版本 **2.2.0-dev**（上游 2.1.3 之后的开发版）                                                                                    |
| IDF 对 lwIP 的适配层 | `~/esp/esp-idf/components/lwip/port/esp32xx/`（VFS socket 集成、hooks、per-thread netdb 等）                                                                               |
| esp_netif 组件       | `~/esp/esp-idf/components/esp_netif/`                                                                                                                                      |
| QEMU                 | `esp_develop_9.2.2_20250817`，二进制 `~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa`                                               |
| QEMU 默认网卡        | IDF v6 的 `idf.py qemu` 默认追加 `-nic user,model=open_eth`（**OpenCores 网卡 + SLIRP 用户态网络**，DHCP 由 SLIRP 提供，guest 通常得 `10.0.2.15/24`，网关/DNS `10.0.2.2`） |
| 目标芯片             | `esp32`（Xtensa LX6 双核）                                                                                                                                                 |
| 主机工具             | `curl`、`nc`、`python3`、`tc`、`iperf`（已安装）、`sudo` 免密可用                                                                                                          |
| 机器                 | 16 核 / 62GB，Fedora                                                                                                                                                       |

**事实纪律（最高优先级）**：

- 所有函数签名、Kconfig 名、结构体字段、源码结构，必须**先 grep/Read IDF 与 lwIP 仓库实际源码确认再写**，禁止凭训练记忆编造。
- 源码引用格式：函数名 + 文件路径（如 `pbuf_alloc()` in `src/core/pbuf.c`）。行号可以不写；要写就必须核实。
- 遇到记忆与源码冲突，以源码为准，并在文中说明版本差异。

## 2. 实验工程规范

- 每章实验工程放在 `/home/huanglin/code/quartz/practice/lwip-chNN-slug/`（如 `practice/lwip-ch03-qemu-network-lab/`）。
- 从最小工程复制起步：`cp -r ~/esp/esp-idf/examples/get-started/hello_world practice/lwip-chNN-slug`，然后删掉复制来的 `build/`、`sdkconfig`，`idf.py set-target esp32` 重新生成。
- 需要联网的章节**复用 ch3 验证过的以太网 bring-up 模板**（`practice/lwip-ch03-qemu-network-lab/main/`，openeth 初始化 + esp_netif + DHCP 等待 IP），在此基础上写各章实验。
- WiFi 相关实验（ch18）注意：本环境 QEMU **没有** esp-wifi-mac，WiFi 无法仿真。源码走读可完整进行；实验要么标注「需真机」，要么用 openeth 以太网路径对照。
- `main` 组件的 `CMakeLists.txt` 需要 `PRIV_REQUIRES` 里带上用到的组件（如 `esp_eth`、`esp_netif`、`esp_event`、`lwip`、`esp_ping` 等）。

## 3. 标准构建-运行流程（已验证，照抄）

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-chNN-slug
idf.py set-target esp32        # 仅首次
idf.py build
# 生成 QEMU flash/efuse 镜像（monitor 会因无 TTY 失败，忽略它，镜像已生成）：
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在
# 直接运行 QEMU，串口输出落 run.log：
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 30 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=nvram.esp32.efuse,property=drive,value=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth -nographic -no-reboot 2>&1 | tee run.log
```

> [!warning] efuse `-global` 行注意（Batch 4 实测，示例工程必须遵守）
> 上面模板中的 `-global driver=nvram.esp32.efuse,...` 行在本机 QEMU 上**偶发导致 openeth NIC 未创建**（启动警告 "was not created"，guest 在 `esp_eth_mac_new_openeth()` 崩溃复位）。ch19/ch20/ch24 的 runner 已改用**去掉该行**的形态并稳定运行。示例工程统一使用去 efuse `-global` 行的 runner；遇到 NIC 未创建先查这里。

要点：

- 退出码 `124` = timeout 正常截停；`0`/`-1` = 应用主动 reset 后 `-no-reboot` 退出。都算正常。
- 需要**主机访问 guest 服务**（HTTP 等）时，`-nic` 追加 hostfwd，端口约定 **8000+章号**：`-nic user,model=open_eth,hostfwd=tcp::80NN-:80`（NN 为章号，避免并行实验端口冲突）。
- 故障注入（丢包/延迟）优先用**应用内/驱动层注入**（在 ethernet input 路径按概率丢弃、加延迟队列），不依赖主机 root；`sudo tc netem` 配 tap 是可选进阶。
- 长跑实验注意 `timeout` 上限，保持单次实验在几分钟内可复现。
- **禁止 `git add/commit/push`。**

## 4. 文章规范

风格基准：`content/2026-08-26-freertos-deep-dive-ch13-task-notifications.md`（动笔前先读它找手感）。

- 文件路径：`content/2026-08-26-lwip-deep-dive-chNN-slug.md`（NN 两位数字）。
- frontmatter：
  ```yaml
  ---
  title: "lwIP 深度解析（N）：小标题"
  date: 2026-08-26
  description: "一段高信息密度摘要，概述本章结论要点。"
  tags: [lwip, network, esp32, esp-idf, qemu, 主题标签2~3个]
  ---
  ```
- 头部导航 callout（只列索引 + 本章）：
  ```markdown
  > [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]]
  > N. **第 N 章：小标题**
  ```
- 一级标题与 title 相同；开场段用「这一章回答三个问题：**…**、**…**、**…**。读完它…」句式，并注明源码参照版本。
- 小节编号 `## N.1`、`## N.2`…；**末尾必有 `## N.x 小结`**（要点式 bullet）+ 下一章预告段（含下一章 wikilink）。
- 必含「Vanilla lwIP 与 ESP-IDF lwIP」对照小节：IDF 的 Kconfig 裁剪、组件封装、Hook 点、替换实现。
- 实验小节必须包含：实验目的、完整可复制命令、**从 `run.log` 粘贴的真实输出摘录**、结果解读。**严禁编造运行输出**；跑不通就改到跑通；环境受限跑不了的实验，如实标注并给出真机/其他环境路径。
- 性能实验纪律：所有数字必须来自真实测量，写明测量方法（工具、命令、重复次数）。
- 篇幅目标 450~650 行；中文为主、技术术语保留英文；代码块标注语言；适当使用 `> [!tip]` / `> [!warning]` / `> [!note]` callout；对比用表格。
- 系列暗线（每章自然呼应，不生硬）：**A.** 单线程 `tcpip_thread` 邮箱模型如何与 RTOS 多任务世界对接；**B.** Vanilla lwIP vs ESP-IDF lwIP 改造对照。

## 5. 全系列文件名映射（wikilink 引用以此为准）

| 章   | 文件名（前缀 `2026-08-26-lwip-deep-dive-`）                         |
| ---- | ------------------------------------------------------------------- |
| 索引 | `series-index` → 完整名 `2026-08-26-lwip-deep-dive-series-index.md` |
| 1    | `ch1-why-lwip`                                                      |
| 2    | `ch2-esp-idf-network-architecture`                                  |
| 3    | `ch3-qemu-network-lab`                                              |
| 4    | `ch4-pbuf-anatomy`                                                  |
| 5    | `ch5-memory-management`                                             |
| 6    | `ch6-zero-copy-tcp-write`                                           |
| 7    | `ch7-netif-abstraction`                                             |
| 8    | `ch8-ethernet-arp`                                                  |
| 9    | `ch9-ip4-icmp`                                                      |
| 10   | `ch10-udp-pcb-layers`                                               |
| 11   | `ch11-tcp-state-machine`                                            |
| 12   | `ch12-tcp-reliability-flow-control`                                 |
| 13   | `ch13-tcpip-thread-mailbox`                                         |
| 14   | `ch14-sys-arch-freertos-adapter`                                    |
| 15   | `ch15-raw-api-callbacks`                                            |
| 16   | `ch16-socket-netconn-vfs`                                           |
| 17   | `ch17-ethernetif-porting-guide`                                     |
| 18   | `ch18-esp32-wifi-lwip-integration`                                  |
| 19   | `ch19-isr-and-priority-design`                                      |
| 20   | `ch20-http-server`                                                  |
| 21   | `ch21-mqtt`                                                         |
| 22   | `ch22-tls-esp-tls-mbedtls`                                          |
| 23   | `ch23-debugging-toolbox`                                            |
| 24   | `ch24-performance-tuning-pitfalls`                                  |

wikilink 写法：`[[2026-08-26-lwip-deep-dive-ch4-pbuf-anatomy|第四章]]`。

FreeRTOS 系列关键前置章（同前缀 `2026-08-26-freertos-deep-dive-`）：`ch1-from-bare-metal-to-rtos`、`ch10-queue-universal-ipc`、`ch13-task-notifications`、`ch15-software-timers-daemon`、`ch19-heap-allocators-comparison`、`ch24-debugging-tracing-pitfalls`。

## 6. 已验证实测事实（各批沉淀，写作时直接引用，勿再踩坑）

**Batch 1（ch1~ch3）**：

- IDF lwIP **全堆化**：`MEM_LIBC_MALLOC=1` 且 `MEMP_MEM_MALLOC=1`。上游的静态 memp 池数组在 IDF 中不存在；但每类元素仍受 `MEMP_NUM_*` 计数上限约束（memp 计数器还在），内存全部来自 libc 堆。内存观察用 `heap_caps_get_free_size()` 等，`stats_display()` 输出无 MEM/MEMP 段（编译期被掏空）。
- esp_ping **不是独立组件**：实现在 `components/lwip/apps/ping/ping_sock.c`，头文件 `components/lwip/include/apps/ping/ping_sock.h`，CMake 只需 `PRIV_REQUIRES lwip`。
- SLIRP 网络：DHCP 分配 `10.0.2.15/24`，网关 `10.0.2.2`，**DNS 是 10.0.2.3（不是网关）**；SLIRP 的 DNS 代理会查宿主机 `/etc/hosts`，可用它做确定性 DNS 实验。
- IDF v6 事件枚举是 `ETHERNET_EVENT_*`（不是 v5 的 `ESP_ETH_EVENT_*`）；IP 事件用 `IP_EVENT_ETH_GOT_IP`，payload `ip_event_got_ip_t`。
- socket/netconn 创建必须在 `esp_netif_init()` 之后，否则 tcpip 邮箱未就绪，`tcpip_send_msg_wait_sem` assert 崩溃复位。
- PHY 用 `esp_eth_phy_new_generic()`（v6 已无 `esp_eth_phy_new_dp83848`，迁到 registry 机制）。
- 任务清单类调试需 `CONFIG_FREERTOS_USE_TRACE_FACILITY=y`（IDF v6 默认关）。
- 改 `sdkconfig.defaults` 后必须删除 `sdkconfig` 重新生成才生效。
- IDF 在 lwIP core 内有 `ESP_LWIP` 条件补丁（TCP RTO 背退、NAPT 挂点、按需定时器），不要写「IDF 未改编 core」。
- 链接器 GC 会让「未真实使用协议」的 size 实验失真（.text 虚低 ~10KB）；探针必须真实走 socket/DNS 路径。
- esp_netif 与 netif 是**组合**关系：`esp_netif_obj` 持 `lwip_netif` 指针，常规背指针走 `netif->state`，启用 PPP/bridge 时切 `netif_get/set_client_data`；esp_netif 控制路径经 `_RUN_IN_LWIP_TASK` 宏强制投递到 tcpip_thread（`LWIP_TCPIP_CORE_LOCKING=n` 默认）。
- ch3 标准联网模板：`practice/lwip-ch03-qemu-network-lab/main/lab_main.c`（openeth bring-up + DHCP + esp_ping + TCP echo hostfwd=tcp::8003-:8888，全部实测通过）。联网章节先读它。
- openeth 启动日志固定刷 3 条 MAC filter ioctl 错误，属预期噪音；QEMU 虚拟网卡 MAC 固定 `52:54:00:12:34:56`。

**Batch 2（ch4~ch6）**：

- MEMP 计数闸门收窄：`MEMP_MEM_MALLOC && ESP_LWIP` 下显式计数闸门**只覆盖 MEMP_TCP_PCB**；`PBUF_POOL_SIZE`（默认 16，注意宏名不是 MEMP_NUM_PBUF_POOL，本仓库无该宏）名义上限**不生效**。POOL 元素固定整格 ~1536B。pbuf 分配失败返回 NULL 不崩溃。
- PCB 耗尽现象：listen PCB 分配失败时 `tcp_listen_input` **静默丢弃 SYN（不发 RST）**，`tcp.memerr` 计数爬升；accept 侧可能见 `errno=113`（EHOSTDOWN，语义错位）。
- 堆耗尽时 openeth RX 任务第一步 `malloc(1516)` 失败 → **驱动层丢帧**（日志刷屏），lwIP 协议计数器可能保持冻结。
- 碎片化诊断三联征：free 回涨 / `heap_caps_get_largest_free_block` 不动 / min-ever 记录。
- **IDF 把 `LWIP_NETIF_TX_SINGLE_PBUF` 硬编码为 1**（`port/include/lwipopts.h`）→ `tcp_write()` 入口强制 `TCP_WRITE_FLAG_COPY`，**no-copy 编译期不可达**。
- SLIRP 用户态转发吞吐天花板 ~120 Mbit（默认 SND_BUF=5760 与调大 28800 都到顶，瓶颈在 SLIRP）；真机数值不可复用，方法学可继承（guest/主机双计时口径、digest 校验、交错轮次）。
- 发送泵必须注册 `tcp_sent()` 回调（ACK 驱动补充发送），否则吞吐涓流。
- netconn 接收邮箱深度 `CONFIG_LWIP_TCP_RECVMBOX_SIZE=6`；socket 层 recv 有额外 memcpy；`TCP_SNDLOWAT` 只影响 socket 可写语义。
- hostfwd 端口已占用：8003(ch3)、8005(ch5)、8006(ch6)；并行跑实验时启动 QEMU 后先 grep 启动失败信息再等应用 PHASE 标记。
- ch4 实测参考：`sizeof(struct pbuf)=16`；layer 头偏移 RAW=0 / LINK=14 / IP=54 / TRANSPORT=74（IPv6 开启时）；`esp_ping_new_session` 在堆高水位下 `create ping task failed` 可复现，可作故障观察点。

**Batch 3（ch7~ch12）**：

- `sizeof(struct netif)=260`；**loopif.c 在 2.2.0-dev 已不存在**（loopback 内建于 ip4_route 的 127.0.0.1 特判）；ext-callback 记录仪是观测 netif 事件的现成范式。
- **ARP 缓存只在 admin-down 清理**（`netif_set_down` → `etharp_cleanup_netif`）；link-down 不清。首包 ARP 税实测 ~8 倍（22.6ms vs 2.5~4.8ms）。SLIRP 假 MAC 编码目标 IP（`52:55:0a:…` 指纹）；guest→10.0.2.2 的 TCP 会落到宿主机 loopback 同端口。
- IDF 补丁 `ESP_LWIP_ARP`：ARP 队满丢**新**包返 ERR_MEM（上游丢队首旧包），且**不计 memerr**；`ARP_QUEUEING=1` IDF 硬编码（上游默认 0）；IDF 默认 60s 周期免费 ARP（`CONFIG_LWIP_ESP_GRATUITOUS_ARP=y`）；`ARP_MAXPENDING` 注释写 10s 但宏值 5（实测 5s）。
- `CONFIG_LWIP_IP4_REASSEMBLY` IDF 默认 **n**（上游 y）；`CONFIG_LWIP_IP_REASS_MAX_PBUFS` Kconfig 锁死 10~100；**IDF 把 `IP_REASS_MAXAGE` 从 15 覆写为 3 秒**（`port/include/lwipopts.h:241`）；`MIB2_STATS` Kconfig 未暴露（根 CMakeLists `add_compile_definitions` 注入法）。SLIRP 回程超大包按 guest MTU 分片，入向重组可实测；openeth RX 描述符环是洪峰第一瓶颈（先于协议栈 memerr）。
- **`CONFIG_LWIP_MAX_UDP_PCBS` 是死旋钮**（计数闸只覆盖 MEMP_TCP_PCB）；真实上限是 fd 槽位（第 16 个 socket `errno=23 ENFILE`，FD_SETSIZE−MAX_SOCKETS）。netconn/socket 邮箱**丢包零痕迹**（recv 在 udp_input 入口已计数，丢在 recv_udp trypost 静默分支）。`LWIP_CHECKSUM_CHECK_UDP` IDF 默认 n；`UDP_RECVMBOX_SIZE` Kconfig 范围 6~64。三层 API 实测：64B RTT raw 102.9µs / netconn 214.8µs / socket 287.6µs；突发吞吐 raw 68.4 / netconn 55.9 / socket 43.3 Mbit。SLIRP 突发尾巴恒定 ~0.8% 仿真丢包（与协议栈无关）。
- Nagle/延迟 ACK 在 SLIRP 下测不出差异（对端即时 ACK）；真机 40ms/250ms 台阶复现路径见 ch12（反转收发方向 + 调 `CONFIG_LWIP_TCP_TMR_INTERVAL=250`——它是延迟 ACK 上限与 RTO tick 共同基准）。10% 丢帧→RTO 退避实测至 3000ms；40% 丢帧→连接事实死亡（rto 192 tick ≈96s）。有损链路瓶颈是 RTO 占空比而非窗口宽度。`tcp_nagle_delay` 字段在 2.2.0-dev 不存在（是 TF_NODELAY flag）。
- `esp_netif_get_netif_impl()` 拿到 lwip netif 后可在 tcpip_thread 内安全换 `linkoutput`/`output` 函数指针（故障注入标准手法，ch12 用它做了确定性丢帧注入）。
- hostfwd 端口占用更新：8003/8005/8006/8009/8010~8012(UDP)/8019 已用；**并行实验 kill QEMU 必须按 hostfwd 特征精确 kill，禁止 pkill**（有并行作者实例在跑）。
- `ip4_addr_t.addr` 手写常数会被当另一地址——必须 `PP_HTONL(LWIP_MAKEU32(a,b,c,d))`；`ipaddr_ntoa()` 共享静态缓冲，多点打印串值，用 `_r` 变体。

**Batch 4（ch11 重试 + ch13~ch16）**：

- **QEMU 已知坑**：第 3 节模板中 `-global driver=nvram.esp32.efuse,...` 行在本机 qemu 上**偶发导致 openeth NIC 未创建**（启动警告 "was not created"，guest 在 `esp_eth_mac_new_openeth()` 崩溃复位）。遇到时删掉该行重跑即可。
- sys_arch 实现真身在 `components/lwip/port/freertos/sys_arch.c`（**不是** esp32xx/；esp32xx 只有 VFS/netif 集成）。`sys_now()` 是 `xTaskGetTickCount()*portTICK_PERIOD_MS`（10ms 网格）——**亚毫秒时序禁止用 sys_now**。`MEMP_NUM_TCPIP_MSG_API` 票闸实测不生效，邮箱硬容量唯一约束是 `CONFIG_LWIP_TCPIP_RECVMBOX_SIZE`(32)。系统路径单价 ~37µs/api 往返。
- tcpip 任务实测栈 3072+512=3584B（高水位 ~2300B）、优先级 18、亲和 NO_AFFINITY；IDF 对 tcpip.c 本体零改动。
- **SLIRP 不支持主机→guest 方向 ICMP**（ping 10.0.2.15 恒不通）；ICMP 只能 guest 发起。入向包观测注入用编译期 `LWIP_HOOK_IP4_INPUT`（openeth 路径不经过 `netif->input` 换指针）；TX 注入换 `linkoutput` 可行。pbuf `tot_len` 含以太网填充，载荷判定以 IPv4 头为准。
- TIME_WAIT 回收是**阶梯式泄洪不是悬崖清零**（各 PCB 记自己 FIN 时刻）。
- raw vs socket TCP 实测：64B RTT 162µs vs 439µs（2.7×）、吞吐 67.7 vs 38.9 Mbit；socket 比 netconn 再贵 +23~54% RTT（127.0.0.1 回环口径）。单线程停摆实证：recv 回调 busy-wait 200ms → 第二连接吞吐 103→0.06 Mbit。
- `CONFIG_LWIP_CHECK_THREAD_SAFETY=y` 守卫构建可当场击毙跨线程裸调 raw API（udp_new 断言复位）——做误用演示用它，做 VFS 对照实验留默认构建。
- fd 公式：`LWIP_SOCKET_OFFSET = FD_SETSIZE(64) − CONFIG_LWIP_MAX_SOCKETS`；socket 可用上限 = MAX_SOCKETS − busy_slots；IDF close 回收是同步路径（~157µs）；阻塞 recv 解救：跨任务 close 返回 errno=128 并走 `netconn_mark_mbox_invalid` 哨兵机制。IDF `poll()` 是 select 仿真（双事件计数会虚报 nready）；FIONREAD 默认配置返回 errno 88。
- 双核测量陷阱：低优先级探针会被 NO_AFFINITY 高优先级自旋饿住造成"没有阻塞"假象——测量任务优先级要压过 tcpip(18)。
- QEMU 吞吐受宿主机负载影响 ±50%，性能对比务必同时段开机配对测量。
- hostfwd 已占用端口累计：8003/8005/8006/8009/8010~8012/8014/8015/8016/8017/8018/8019/8517/9014/8027(UDP)；新章节先查此表再选号。

**Batch 5（ch17~ch19）**：

- RX 方向观察点新手法：`esp_eth_update_input_path()` 覆写 glue 输入路径（与 linkoutput 替换配对，TX/RX 双观察点成立）。openeth 描述符环默认 TX=1/RX=4（Kconfig）；RX 过载时控制窗 ~750fps、过载窗精确坍缩到 33fps（30ms/帧管道上限），丢帧告警走 INT_BUSY。
- WiFi netif 接缝函数族是 `wlanif_init_sta/ap` / `wlanif_input`（esp_netif_lwip_defaults.c），不是 ethernetif；`esp_wifi_internal_tx/reg_rxcb` 由 libnet80211.a 导出；**WiFi 任务优先级是闭源常量**，文档须标注黑盒。
- 任务优先级地图（openeth 平台）：tcpip=18(NO_AFFINITY)、emac_rx=15/4096B、应用 echo=5。ping 任务裸 xTaskCreate(prio=2)，与 Kconfig help 文本脱节。
- ISR 通道真名：`sys_mbox_trypost_fromisr`（队满 ERR_MEM、唤醒高优返 IDF 私有 **ERR_NEED_SCHED=123**）、`sys_sem_signal_isr`；上游唯一 ISR 入口 `tcpip_callbackmsg_trycallback_fromisr`；"sys_arch_signal_isr"这个名字不存在。vfs_lwip.c 的消费场景是 VFS select 打断链。
- openeth 中断以 ESP_INTR_FLAG_IRAM 注册未指定 level，落 Level1~3。
- 每包 CPU 账单（128B echo 往返）：NIC 链路全程 ~601µs（emac_rx 137 / tcpip 298 / app 166 µs）。回环 RTT 631µs 中 tcpip 独占 435µs。
- 优先级倒挂临界线实测：prio23 自旋钉 core0 时 **duty≤70% 存活、70%~85% 分水岭、≥85% 全灭**。RX 任务压到 IDLE 级在轻载下无感——丢包阀在描述符环不在优先级表。
- 故障注入控制平面必须活在受害者带宽之外（spinstop 曾被自己的注入卡住）；开环 paced 探针模式（connect 显式超时报 CONNECT_FAIL）比闭环压测更适合故障场景。
- SLIRP 怪癖补充：对发往 discard 端口的 UDP 会立即回弹 ICMP type3 大帧；同刻第二次开的 ping 会话恒超时（会话边界毛刺）；确定性流量请用 UDP 探针造。
- hostfwd 新增占用：8020(ch17)、8022/8023(ch19)、8050(ch18)。

**Batch 6（ch20 重试中 + ch21~ch22）**：

- **IDF v6.0.2 内置 Mbed TLS 4.1.0**（大版本！错误码已改绑 PSA：内存不足是 -0x008D=PSA_ERROR_INSUFFICIENT_MEMORY，不再是老 -0x7F00 段）。TLS 握手实测：RSA tcp 9ms/TLS 335ms，EC 347ms；套件 ECDHE-RSA-AES-256-GCM-SHA384。内存：会话稳态 +27KB、握手峰值 +33KB（IN buffer 16717B/OUT 4429B，堆饥饿时 mbedtls 直接报 `alloc(16717) failed`）。回环加密税：明文 13.39 vs TLS 0.38 Mbit/s ≈ **97%**。min-ever 是多区域 sum-of-minima，跨阶段取差会失真——用「阶段前后差+周期采样窗 min」双指标。
- **`idf.py qemu monitor < /dev/null` 在重复构建后可能静默失败**，qemu_flash.bin 不再更新。手动镜像生成兜底：`cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args`。
- esp-mqtt：outbox 离线积压实测 **1048B/条**（纯消息 280B/条）；broker SIGSTOP 判死时延符合源码公式 [1.5×ka, 2×ka]；默认 30s 过期清仓（EV DELETED）。**上游 lwIP 其实有 `src/apps/mqtt`，IDF 用 `LWIP_MQTT=0` 使其成死码**。clientId 重复会互踢风暴。
- ch22 留下两个未闭合悬案（可作调试教学案例）：①SLIRP 外环 TLS 建立成功但首条应用记录永不响应（kernel ACK 但进程不回放，openssl/python 服务端一致）；②guest 内 loopback 明文服务仅第一条连接可用，后续 connect 全 RST。
- QEMU 并行资源竞争：提前启动会撞上一轮未释放资源，编排脚本要内置等待释放逻辑；宿主机端口（如 1883）可能被并行进程占位，按 pid 校验归属。

**Batch 7（ch20 重试 + ch23~ch24，收官）**：

- esp*http_server：会话池 7 格 sock_db、无时钟源 LRU 计数器、池满默认摘除 listen_fd（lru_purge=false）；`keep_alive*\*`配置实为 TCP SO_KEEPALIVE，真正回收裁判是`recv_wait_timeout`(SO_RCVTIMEO)；会话串行化回收 → 最坏恢复时间 = max_open_sockets × recv_wait_timeout；无 Content-Length 上限配置（HTTPD_413 存在但全 src 无触发者）；chunked 请求体不支持。排障签名：`httpd_sock_err: error in recv : 11`、`408 Request Timeout`、`parse_block: incomplete`。
- lwIP 2.2.0-dev 中 `debug_flags` 全局已不存在——**运行时动态调 debug 不可行**，只能编译期；IDF Kconfig 无 `TCP_RST_DEBUG` 入口。
- **ch22 悬案②已破**：guest loopback "仅第一条连接可用"零 RST——真死法是 (a) 单任务串行 accept→recv 黑洞 (b) backlog(2) 吃满 `listen backlog exceeded` + SYNMAXRTX=4 五发空转后 errno=113。loopback 上 TCP stats xmit==recv 是自环计数假象，不能当丢包判据。gdb 附着 QEMU 无 RTOS 线程感知，手动读 `pxCurrentTCBs[n]`。
- **窗口×RX 环深不等式（调优头号发现）**：WND=11520 时 openeth RX 环 4 → 3.4~6.7 Mbit 黑洞，环抬 16 → 57~69 Mbit；WND=28800 需环 ≥32。单拧窗口必翻车。SND_BUF/WND=65535 拉满触发间歇性涓流档（未闭合悬案）。邮箱深度 8→64 不敏感；`MAX_ACTIVE_TCP` 默认 16 是多连接负载头号地雷（SYN 静默黑洞）。
- 弱网(15% 丢帧)×堆紧张(≤40KB) 组合拳：成功率仍 100% 但 HTTP p90 从 10.7ms 崩到 4185ms。
- 镜像时效性：固件打印 `__TIME__` 指纹核对，配合手动 merge-bin 兜底，杜绝烧旧镜像量新数据。

## 7. 账目勘误与新工作口径（示例套件调研发现）

- 第 3 节「端口约定 8000+章号」与 §6 各 Batch 的端口记录是**历史账**，实际曾先到先得跳号
  （8006 实为主机侧反向监听、8011/8012 仅 guest 侧、8019 无对应 hostfwd 等，明细见
  `../lwip-examples/research/assets-and-constraints.md`）。
- **新工程一律使用专用号段 8200–8299**（分配表见 `../lwip-examples/SPEC.md` §4）；
  legacy 黑名单：8006、8108、8517、9014、1883。
- 后期章节实际沿用的是 ch19 改良版模板（控制平面先行、DHCP 15s 超时），非 ch03 原版。

**Batch 8（示例套件 ex14/ex15 沉淀）**：

- **QEMU 致命坑：目的地址为自身 IP 的持续 TCP 吞吐会咬死 tcpip 线程**（gdb 取证卡在 `pbuf_free`/`g_lwip_protect_mutex` 解锁）。自环负载一律用 127.0.0.1 或走 SLIRP 宿主反射器；UDP 自身 IP 流量则会被 SLIRP 静默吞掉。ex14/ex15 均已改道。
- **「RX 环深 ≥16」是必要非充分**：ex14 实测 WND=28800 + ring=32 修复黑洞失败（0.09→0.11 Mbit 不变），回工作区 5760 反而恢复 71~84 Mbit。不等式的边界态（11520/16）同样脆弱——调优必须成对重测，勿信单公式。
- **SLIRP 亚毫秒 RTT 使 BDP 教条失效**：SND_BUF/WND=2880 小窗实测 115.96 Mbit 全绿不发病。「小窗必慢」在仿真环境不成立，属诚实负结果教学。
- 并行实验误伤实锤：过宽的进程匹配会误杀他人 QEMU 实例——kill 纪律升级为「记录 PID 精确操作」，被误杀方靠构建指纹/FACT 校验自检后重跑。
