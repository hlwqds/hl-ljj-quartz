# 上游官方示例调研 — ESP-IDF v6.0.2 官方网络示例与 lwIP 内置应用盘点

调研目的：回答「官方和上游是怎么组织 RTOS+lwIP 网络示例的，哪些能直接借鉴，哪些在 QEMU OpenCores+SLIRP 环境不可行」，为我们的 `practice/lwip-examples` SPEC 提供对齐依据。

- 核查基准：`~/esp/esp-idf`（v6.0.2）实际文件（ls/grep/Read 逐一核实），辅助对照本地旧副本 `~/esp/esp-idf-v5.1`。
- SLIRP 能力边界引用：`practice/lwip-labs/CONVENTIONS.md` 第 1 节环境事实、第 6 节已验证实测事实。
- 本文所有函数名、Kconfig 名均已在源码中核实；路径省略 `~/esp/esp-idf/` 前缀。

---

## 1. 官方协议/以太网示例总盘点

### 1.1 目录存在性清单

`examples/protocols/` 实际目录（ls 核实）：

| 示例                                                    | 一句话内容                                                                                                                                  | 关键组件                                           |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `sockets/tcp_server` 等                                 | BSD socket 系列：tcp_client/server、udp_client/server、non_blocking、udp_multicast、icmpv6_ping、tcp_transport_client、tcp_client_multi_net | lwip sockets + protocol_examples_common            |
| `http_request`                                          | **裸 POSIX socket 手写 HTTP GET 到 example.com**（非 esp_http_client）                                                                      | lwip/netdb                                         |
| `esp_http_client`                                       | esp_http_client 组件的标准 HTTP(S) 客户端                                                                                                   | esp_http_client                                    |
| `https_request` / `https_mbedtls` / `https_x509_bundle` | TLS 客户端三件套（esp-tls / 裸 mbedtls / crt bundle）                                                                                       | esp-tls、mbedtls                                   |
| `http_server/`                                          | 子目录型：simple、async_handlers、persistent_sockets、file_serving、ws_echo_server、captive_portal、restful_server、advanced_tests          | esp_http_server（自研实现）                        |
| `mqtt` / `mqtt5`                                        | MQTT over TLS，事件驱动；mqtt5 为 MQTT v5 特性                                                                                              | **espressif/mqtt ^1.0.0**（registry 托管，见 1.3） |
| `sntp`                                                  | esp_netif_sntp 封装 API 对时，支持 DHCP 下发 NTP                                                                                            | esp_netif_sntp + lwip sntp                         |
| `icmp_echo`                                             | esp_console REPL 里敲 `ping` 命令                                                                                                           | esp_ping（实现在 lwip 组件内 ping_sock.c）         |
| `icmp/pmtu_probe`                                       | ICMP PMTU 探测                                                                                                                              | lwip                                               |
| `static_ip`                                             | 停 DHCP 改静态 IP/DNS                                                                                                                       | esp_netif                                          |
| `dns_over_https`                                        | DoH 查询（example-local components 惯例）                                                                                                   | esp_http_client + 本地私有组件                     |
| `smtp_client`                                           | SMTP 邮件发送                                                                                                                               | esp-mqtt 同款依赖方式                              |
| `l2tap`                                                 | 二层 tap socket（VFS 层收发原始以太网帧）                                                                                                   | esp_eth                                            |
| `esp_local_ctrl`                                        | Wi-Fi 配网控制服务                                                                                                                          | espressif/mdns 等托管件                            |

`examples/ethernet/` 仅三个：`basic`（驱动 bring-up）、`iperf`（吞吐测试）、`ptp`（IEEE 1588 对时）。

### 1.2 统一骨架（所有联网示例共享）

每个示例是独立工程，标准文件构成：

```text
<example>/
├── CMakeLists.txt          # cmake_minimum_required(VERSION 3.22) + include project.cmake
├── main/
│   ├── <x>_main.c          # 或 app_main.c；入口固定 app_main()
│   ├── CMakeLists.txt      # idf_component_register(... PRIV_REQUIRES 显式列组件)
│   ├── Kconfig.projbuild   # menu "Example Configuration"
│   └── idf_component.yml   # managed component 依赖清单
├── README.md
├── sdkconfig.defaults
├── sdkconfig.ci[.变体]     # CI 用固化配置
└── pytest_<x>.py           # CI 自动化入口
```

要点：

1. **共享接入层 protocol_examples_common**：`examples/common_components/protocol_examples_common/`，核心 API `example_connect()`——阻塞直到拿到 IP。Kconfig choice `EXAMPLE_CONNECT_{WIFI,ETHERNET,PPP,THREAD}` 决定接入方式；IPv4/IPv6 开关、SSID/密码等也在此层配置。README（`examples/protocols/README.md`）明说它"只适合示例用，真实应用要换成完整连接管理"。
2. **以太网初始化已外移出 IDF 树**：protocol_examples_common 的 idf_component.yml 依赖 registry 组件 `espressif/ethernet_init: ^1.3.0`（`ethernet_init_all()`）。IDF v6 的 examples 树内**没有**该组件源码（全树 find 只有 v5.1 遗留副本），构建时从组件管理器拉取。这直接影响我们能否照抄官方以太网 bring-up——不能离线照抄，必须自带模板（ch3 已验证的 openeth 模板）。
3. **事件驱动接线模式统一**：`ETHERNET_EVENT_*` / `IP_EVENT_ETH_GOT_IP`（payload `ip_event_got_ip_t`）两个 handler 注册到 default event loop，这与 CONVENTIONS §6 Batch 1 记录一致。

### 1.3 重点示例逐个拆解

#### ethernet/basic — 以太网 bring-up 基准

- 结构：单文件 `main/ethernet_example_main.c` + Kconfig.projbuild；`PRIV_REQUIRES esp_netif esp_eth`。
- 初始化路径（app_main）：`eth_init()`（MAC+PHY 创建、driver install）→ `esp_netif_init()` → `esp_event_loop_create_default()` → `ESP_NETIF_DEFAULT_ETH()` + `esp_netif_new()` → `esp_eth_new_netif_glue()` → `esp_netif_attach()` → 注册 handler → `esp_eth_start()`。
- MAC/PHY：`esp_eth_mac_new_esp32(&esp32_emac_config, &mac_config)` + `esp_eth_phy_new_generic(&phy_config)`（v6 已无 dp83848 专用构造，registry 化，印证 CONVENTIONS §6）。
- **Kconfig 无 openeth/QEMU 项**（通读 main/Kconfig.projbuild：只有 PHY interface/RMII 时钟/MDC-MDIO GPIO/PHY addr/reset/deinit-after-S）。对 openeth 的全量 grep 结论：
  - 驱动本体在 `components/esp_eth/src/openeth/esp_eth_mac_openeth.c`，头 `include/esp_eth_mac_openeth.h`，开关 `CONFIG_ETH_USE_OPENETH`（`components/esp_eth/Kconfig`，menuconfig 项 "Support OpenCores Ethernet MAC (for use with QEMU)"，default n，子项 DMA RX/TX buffer 数默认 4/1）。
  - 全部 examples 只命中 3 处遗留痕迹：`protocol_examples_common/sdkconfig.rename` 记录了改名 `CONFIG_EXAMPLE_USE_OPENETH -> CONFIG_ETHERNET_OPENETH_SUPPORT`，而这两个符号如今在任何 Kconfig 中都已无定义（另一处命中是一个旧 CI sdkconfig 写着 `CONFIG_ETHERNET_OPENETH_SUPPORT=y`）。
  - **判定：官方示例不提供 QEMU/openeth 路径；QEMU 示例必须自带 bring-up（即 ch3 openeth 模板的价值所在），可参考 basic 的事件接线写法但不可整体复制。**

#### ethernet/iperf — 吞吐示例的实现方式

- 结构：`main/{ethernet_iperf_main.c, cmd_ethernet.c/h}` + REPL；idf_component.yml 引 `cmd_system`（path 指 `${IDF_PATH}/examples/system/console/advanced/components/cmd_system`）、`espressif/ethernet_init ^1.3.0`、**`espressif/iperf-cmd ~1.0.2`**（registry）。
- 主流程：控制台 REPL + `init_ethernet_and_netif()`（多网卡循环建 netif，route_prio 递减）等 IP 后注册 `iperf` 命令。
- **吞吐实现不是 lwIP 内置 lwiperf**。证据链：v5.1 时代实现在 `examples/common_components/iperf/iperf.c`，grep 确认为**纯 BSD socket 自研 iperf clone**（SOCK_DGRAM/SOCK_STREAM + 自定义包头 + 线程收发），全文件零处 lwiperf 引用；v6 把这套代码移成 registry 托管的 espressif/iperf-cmd。lwIP 自带 `lwip/src/apps/lwiperf/lwiperf.c` 在 IDF 中不被编译（见第 2 节）。
- **判定：官方 iperf 路线依赖网络下载 managed component，我们只能借鉴其命令行交互形态；吞吐实验本体建议自研双计时口径（ch6 方法学）或手动把 lwiperf.c 加入构建作为对照物。**

#### ethernet/ptp

- example-local components 惯例样板：`components/ptpd`（lwIP 无关的自带 PTPd 移植）+ `components/esp_eth_time`。对本项目无借鉴价值（需硬件 timestamp，QEMU openeth 不支持）。

#### protocols/sntp

- 主文件 `sntp_example_main.c`；Kconfig：`SNTP_TIME_SERVER`（默认 `pool.ntp.org`）+ choice `SNTP_TIME_SYNC_METHOD_{IMMED,SMOOTH,CUSTOM}`。
- 核心 API 是 **esp_netif 封装层**而非裸 lwip：`esp_netif_sntp_init()` / `ESP_NETIF_SNTP_DEFAULT_CONFIG()` / `esp_netif_sntp_start()` / `esp_netif_sntp_sync_wait()`；`LWIP_DHCP_GET_NTP_SRV` 打开时演示 DHCP option 42 下发 NTP 服务器（`server_from_dhcp=true`）；自定义同步可覆写 `sntp_sync_time()`。
- 结尾 `RTC_DATA_ATTR boot_count` + `esp_deep_sleep(10)` —— QEMU 下 deep sleep 语义受限，移植时要改。
- 依赖链：nvs_flash + protocol_examples_common（要 WiFi/Ethernet 二选一）。

#### protocols/sockets/tcp_server、udp_server

- 单文件任务模型：`app_main` → `example_connect()` → `xTaskCreate(tcp_server_task)`；socket 循环 accept→recv→回发（do*retransmit）；keepalive 参数走 Kconfig（`EXAMPLE_KEEPALIVE*\*`）。
- 测试侧配套 `scripts/run_tcp_client.py` 等 + README 教你用 `nc`。**这是最容易被我们 QEMU 工程直接吸收的形态**（hostfwd 反向可达已由 ch3 验证）。

#### protocols/http_server/

- 服务器本体是 **Espressif 自研 esp_http_server**：`components/esp_http_server/src/{httpd_main,httpd_parse,httpd_sess,httpd_txrx,httpd_uri,httpd_ws}.c`，与 lwIP 上游 httpd 无血缘（grep 全 components 树无人引用 `src/apps/httpd`）。lwIP 组件 CMake 里也没编译任何 httpd 源码。
- 子示例里对我们有价值的是 `simple/`（GET/POST/Basic Auth/SSE 最小面）和 `captive_portal/`（自带 dns_server 小组件，正是 raw UDP DNS 的好教材）。

#### protocols/mqtt、mqtt5

- **esp-mqtt 也迁出了 IDF 树**：`components/mqtt/` 只剩 `test_apps/`，实际库由 idf_component.yml 拉 `espressif/mqtt: ^1.0.0`（两个示例相同写法）。默认 broker `mqtts://test.mosquitto.org:8883|8886`，证书验证 choice（bundle vs 内嵌 mosquitto.org.crt）。
- 事件处理样板完整（CONNECTED/SUBSCRIBED/PUBLISHED/DATA/ERROR 分支），错误归类 TCP_TRANSPORT vs CONNECTION_REFUSED。CONVENTIONS §6 Batch 6 的 outbox/keepalive 公式就是这个库的行为。
- **判定：代码可整段借鉴，但 QEMU 内必须把 broker 换成宿主机 loopback 上的 mosquitto（URI 写 `mqtt://10.0.2.2:1883`），公网 broker 不可依赖。**

#### protocols/icmp_echo

- 形态 = REPL + argtable3 解析的 `ping` 命令，底层 `esp_ping_new_session/start/delete_session`（实现在 lwip 组件内 `apps/ping/ping_sock.c`，头文件 `include/apps/ping/ping_sock.h`——与 CONVENTIONS §6 记录一致，esp_ping 不是独立组件）。
- 回调三件套 on_ping_success/on_ping_timeout/on_ping_end，统计口径（loss 计算、duration）可直接抄。
- app_main 先 `nvs_flash_init()` + `esp_netif_init()` 再起 REPL，支持 `EXAMPLE_PROVIDE_WIFI_CONSOLE_CMD` 时手动连接。

#### protocols/static_ip

- 三步标准动作：GOT_IP 事件回调里 `esp_netif_dhcpc_stop(netif)` → `esp_netif_set_ip_info()` → 可选 `esp_netif_set_dns_info()`；Kconfig 提供 IP/mask/gw/DNS 四个 string 项（默认静态 IP 居然是 192.168.4.2 系）。适合直接改造成 SLIRP 版本（10.0.2.15/24 gw 10.0.2.2——但注意 SLIRP 环境 DNS=10.0.2.3）。

#### protocols/dns_over_https 及其他

- DoH：example-local components（`components/dns_over_https` + `components/time_sync`）+ cert bundle 选择 Google/Cloudflare/Custom 上游，走 esp_http_client。强依赖公网 TLS，QEMU 不可行。
- `l2tap`：二层 tap socket 收发原始帧，openeth 路径理论可用（有真实 eth 句柄即可），属于可选进阶实验素材。

---

## 2. lwIP 2.2.0-dev 内置应用在本 IDF 中的可用性

### 2.1 源码存在但基本都不编译

捆绑源码 `components/lwip/lwip/src/apps/` 实际内容（ls 核实）：`altcp_tls`、`http`（内含 `httpd.c`、`http_client.c`、`fs.c`、makefsdata）、`lwiperf/lwiperf.c`、`mdns/{mdns,mdns_domain,mdns_out}.c`、`mqtt/mqtt.c`、`netbiosns`、`smtp`、`snmp`、`sntp/sntp.c`、`tftp/tftp.c`。

IDF 编译面（`components/lwip/CMakeLists.txt` srcs 清单核实）：

| lwIP app            | 是否进 IDF 构建 | 进入方式                                                                                                                                                                                                                                                          |
| ------------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/sntp/sntp.c`  | **编译**        | 无条件列入 srcs；另有 ESP 包装层 `components/lwip/apps/sntp/sntp.c`（esp_sntp API 与 VFS/事件集成）                                                                                                                                                               |
| `apps/netbiosns`    | **编译**        | 无条件（孤儿功能，几乎无人知）                                                                                                                                                                                                                                    |
| apps/http (httpd)   | 不编译          | 无 Kconfig 入口                                                                                                                                                                                                                                                   |
| apps/lwiperf        | 不编译          | 无 Kconfig 入口                                                                                                                                                                                                                                                   |
| apps/mdns           | 不编译          | 头 `mdns_opts.h` 里仍是 `LWIP_MDNS_RESPONDER=0` 默认                                                                                                                                                                                                              |
| apps/mqtt           | 不编译          | 被上游 espressif/mqtt 组件替代（注意：**2.2.0-dev 的 mqtt.c 里已没有 LWIP_MQTT 主开关宏**，查遍 `src/include` 无 `define LWIP_MQTT`；它是"加进构建就参与编译"的普通源文件。此前"IDF 用 LWIP_MQTT=0 使其成死码"的说法对 2.2.0-dev 应修正为"未列入编译清单而死码"） |
| apps/tftp           | 不编译          | 源文件仅 gate 在 `#if LWIP_UDP`                                                                                                                                                                                                                                   |
| smtp/snmp/altcp_tls | 不编译          | 同上                                                                                                                                                                                                                                                              |

ESP 侧包装层（都在 `components/lwip/` 内）：`apps/ping/ping_sock.c`（CONFIG_LWIP_ICMP 条件加入）、`apps/dhcpserver/dhcpserver.c`（CONFIG_LWIP_DHCPS）、`apps/netdb/esp_netdb.c`（CONFIG_LWIP_USE_ESP_GETADDRINFO）。

### 2.2 Kconfig 对照结论

`components/lwip/Kconfig` 里与内置应用相关的只有：

- SNTP 菜单：`LWIP_SNTP_MAX_SERVERS`(1~16)、`LWIP_SNTP_UPDATE_DELAY`、`LWIP_SNTP_STARTUP_DELAY`(+`LWIP_SNTP_MAXIMUM_STARTUP_DELAY`)、`LWIP_SNTP_DEBUG`；
- `LWIP_DNS_SUPPORT_MDNS_QUERIES`（DNS 解析器支持 `.local` one-shot 组播查询——只是 client 行为，不是 mDNS responder）;
- port 层映射只在 `port/include/lwipopts.h` 看到 SNTP 族（如 `SNTP_MAX_SERVERS` ← `CONFIG_LWIP_SNTP_MAX_SERVERS`）与 `LWIP_DHCP_GET_NTP_SRV` 的条件定义。

**不存在** `LWIP_HTTPD` / `LWIP_MQTT` / `LWIP_TFTP` / `LWIP_IPERF` / mDNS responder 的任何 IDF Kconfig。上层遮挡关系总结：

| 上游 app | 在 IDF 世界中的替身                                | 替身身份                       |
| -------- | -------------------------------------------------- | ------------------------------ |
| sntp     | esp_sntp / esp_netif_sntp                          | 包装（可下沉到 lwip 原生调用） |
| ping     | esp_ping                                           | 实现就在 lwip 组件内           |
| httpd    | esp_http_server                                    | 完全替换（自研）               |
| mqtt     | espressif/mqtt（registry）                         | 完全替换                       |
| mdns     | espressif/mdns（registry，IDF 树内无此组件）       | 完全替换                       |
| lwiperf  | espressif/iperf-cmd（registry，且非 lwiperf 血统） | 平行替代                       |
| tftp     | 无                                                 | 无替身，源头在 bundled tree    |

对我们的启示：想教「原生 lwIP 应用层」（raw API 的 httpd/ smtp/tftp、netconn 的 lwiperf）必须自己把 `components/lwip/lwip/src/apps/<x>/...c` 加进工程 CMakeLists 源列表。这正是本项目区别于官方示例组织方式的核心扩展点，而且完全可行（这些 .c 只依赖 lwip 头与 netconn/raw API，不需要额外组件）。

---

## 3. SLIRP 环境适配性判定表

前提事实（引自 CONVENTIONS §1/§6）：SLIRP 下 guest 得 10.0.2.15/24、gw/DNS 代理体系 10.0.2.2/10.0.2.3；主机无法 hostfwd ICMP，入向 ICMP 恒不通；guest→10.0.2.2 的 **TCP** 稳定落到宿主机 loopback 同端口；SLIRP 用户态转发吞吐天花板 ~120 Mbit；同刻第二个 ping 会话恒超时；CH20 曾出现外环 TLS 建立成功后首条应用记录卡死（悬案未闭合）。TCP 经 10.0.2.2 到达宿主 loopback 服务已多次实测成立；guest 出站 UDP 到 10.0.2.2 的端口转发行为未做过专项实测，凡依赖它的条目都标「需构建期实证」。

| 候选类型         | QEMU 可行性          | 依据与绕行方案                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ---------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TCP echo server  | 可行                 | hostfwd=`tcp::80NN-:8888` 主机 nc 连 guest，或 guest 连 10.0.2.2 反打宿主 loopback echo；两条路都有实测先例（ch3/ch16）                                                                                                                                                                                                                                                                                                               |
| TCP echo client  | 可行                 | 目标指向 10.0.2.2 宿主 nc listener 即可，零外网依赖                                                                                                                                                                                                                                                                                                                                                                                   |
| UDP echo         | 可行                 | hostfwd 支持 udp 规则；亦可用 discard 端口怪癖（ICMP type3 回弹大帧）做反向观测素材（Batch 5）                                                                                                                                                                                                                                                                                                                                        |
| HTTP server      | 可行                 | esp_http_server 或手写 server + hostfwd 8000+章号；curl 从宿主验证；会话池/超时行为正好对应 Batch 7 观测点                                                                                                                                                                                                                                                                                                                            |
| HTTP 大文件下载  | 可行                 | 宿主机 loopback 起 `python3 -m http.server`，guest 拉 `http://10.0.2.2:<port>/big.bin`，全程离线确定；吞吐上限按 ~120 Mbit 叙述并遵守窗口×RX 环深不等式调优发现（Batch 7）                                                                                                                                                                                                                                                            |
| SNTP 对时        | 需构建期实证         | 默认 `pool.ntp.org` 要公网+UDP 双重不确定。备选 A：宿主机跑 chrony/简易 NTP 监听 loopback，guest 的 `SNTP_TIME_SERVER` 指向 `10.0.2.2`（依赖「出站 UDP→10.0.2.2 落宿主」这一未专项实测的行为，若成立则完全离线可控）；备选 B：经 SLIRP DNS 查宿主 `/etc/hosts` 把 NTP 域名钉到已知地址后同样指向宿主服务（域名解析部分已被 Batch 1 验证为确定性手段）。两案都要实测兜底；再不行退化为「手动 settimeofday + 自定义 sync 回调」演示机制 |
| MQTT pub/sub     | 可行                 | 宿主 loopback 装 mosquitto，broker URI `mqtt://10.0.2.2:1883`，订阅端用 `mosquitto_sub`；TLS 变体可做但要避开 ch22 外环悬案形态（记录复现条件即可）；clientId 互踢/outbox 行为已有沉淀可直接设计故障注入                                                                                                                                                                                                                              |
| TLS client       | 需绕行               | guest↔10.0.2.2 的 openssl s_server 存在「握手成功后首条应用记录无响应」悬案；宿主 python https server 待复核。主线教学退守 guest 内 loopback TLS（加密税 97% 数据已沉淀），外环标实证                                                                                                                                                                                                                                                 |
| ping（esp_ping） | 需绕行               | 只能 guest 发起；目标选 10.0.2.2/10.0.2.3；单会话可用、同刻第二会话恒超时、DHCP 竞态下 `create ping task failed` 都是已复现的观察点；主机 ping guest 不可用作验收手段                                                                                                                                                                                                                                                                 |
| iperf 式吞吐     | 可行                 | 自研或 lwiperf 自编（见 2.2）；天花板 ~120 Mbit 必须写入预期；SND_BUF/RX 环深配套调整已验证                                                                                                                                                                                                                                                                                                                                           |
| mDNS             | 不可行（观测半可行） | 多播/广播不出 SLIRP，无应答者；`espressif/mdns` 又需联网拉取。只能在发包侧组播帧层面观测（openeth TX 挂钩），responder 协议语义验证只能标注「需真机或双机 TAP 进阶」。`.local` one-shot 查询发出可见、应答永不到                                                                                                                                                                                                                      |
| TFTP             | 需构建期实证         | bundled tftp.c 从未被 IDF 编译，源码级启用本身就是教学点；传输走 UDP69 至宿主 tftpd（10.0.2.2），可行性取决于与 SNTP 相同的「出站 UDP 转 loopback」问题，实测定生死；失败也不损失其他章节独立性                                                                                                                                                                                                                                       |

汇总口径：**11 类候选中 7 类直接可行、4 类需绕行或实证、1 类（mDNS）判不可行**（UDP 相关两项共用同一个待实证假设，一次实验即可同时裁定）。

---

## 4. 命名与结构惯例（SPEC 对齐依据）

### 4.1 README 骨架

高频范例（basic/iperf/simple/tcp_server）收敛出的标准节序列：

```text
# <Title>
## Overview                    # 一两句定位
## How to use example          # 或直接下一级
### Hardware Required
### Configure the project      # 说明 menuconfig 关键项
### Build and Flash            # 含 Build and Run 变体
## Example Output              # 真实粘贴日志
## Troubleshooting             # 常见坑
```

细节习惯：跨示例共享概念只写一次（protocols/README.md 集中讲 `example_connect()`，各子 README 链接过去）；操作类命令块全部可复制；输出块标注 `(Top-level) task wdt ...` 之类真实串口文本。

### 4.2 工程结构惯例

- 根 CMakeLists 固定三件套，联调型示例追加 `idf_build_set_property(MINIMAL_BUILD ON)`；
- main 组件 `PRIV_REQUIRES` 显式列依赖（绝不隐式继承），借 shared component 时用 `path: ${IDF_PATH}/examples/common_components/xxx` 或 `${IDF_PATH}/examples/system/console/advanced/components/cmd_system` 这种绝对路径引用；
- 例内私有小功能打成 example-local `components/<name>`（dns_over_https、ptp/captive_portal 的 dns_server 都是此形态），这正是我们多示例间共享 openeth bring-up 模板可采用的手段；
- 外部化优先级演进已明确：例内拷贝（v5.1 common_components/iperf）→ registry managed component（v6 espressif/iperf-cmd）。我们的 SPEC 因离线约束要反其道而行：一切依赖必须 ${IDF_PATH} 或仓库内 path。

### 4.3 配置约定

- `sdkconfig.defaults` 只放「与本示例教学目标相关的最小覆盖」，芯片差异进 `sdkconfig.defaults.<target>`；
- CI 配置命名 `sdkconfig.ci` / `sdkconfig.ci.<variant>`（如 `sdkconfig.ci.ipv6_only`），sntp 的 CI 文件示范了「换服务器+开第二 server+stdin 注入凭证」的最小变形；
- Kconfig 命名统一 `EXAMPLE_` 前缀，menu 名 `Example Configuration`（以太网专属菜单叫 `Example Ethernet Configuration`）；范围校验显式写 range。

### 4.4 版本标注习惯

- 官方示例**自身不带版本标注**：版本锚定靠 git tag/发布页；新文件用 SPDX 头（`SPDX-License-Identifier: Apache-2.0`），老文件用 Public Domain/CC0 描述头，两者并存于同一版本树。
- 我们的项目约定应当比官方更严：工程名、目标芯片、IDF 版本、lwIP 版本都要在每个 SPEC/README 头部显式声明（这也是 CONVENTIONS「源码引用须注明版本」纪律的自然延伸）。

---

## 5. 结论速览

1. **官方以太网路径不可直接用**：basic 硬绑片上 EMAC，`esp_eth_mac_new_openeth` 虽在组件里有完整驱动与 Kconfig（`CONFIG_ETH_USE_OPENETH`）却没有任何官方示例接进去；官方共享层的以太网初始化又依赖在线拉取的 `espressif/ethernet_init`。QEMU 工程必须以 ch3 openeth 模板为唯一 bring-up 起点。
2. **lwIP 原生应用层是被官方示例体系放弃的教学区**：除 sntp/netbiosns 外一律不编译、无 Kconfig；官方用自己的组件群（esp_http_server/espressif/mqtt/espressif/mdns/iperf-cmd）整体替换。我们要教的「协议栈自己长什么样」恰恰在这些未编译目录里，需要自行挂源码——这是差异化价值最大、也完全可行的路线。
3. **SLIRP 判定表给出 7 可行 / 3 需绕行或实证 / 1 不可行**；两个 UDP 转发疑点（SNTP、TFTP）可合并为一个开机实验一次性裁决。
