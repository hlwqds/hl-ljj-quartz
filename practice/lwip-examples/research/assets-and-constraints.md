# lwIP 示例工程规格输入书：资产盘点与约束固化

- 调研人：B（示例工程套件计划调研员）
- 日期：2026-08-26
- 调研范围：`practice/lwip-ch01*` ~ `practice/lwip-ch24*` 共 24 个章节实验工程、
  `practice/lwip-labs/CONVENTIONS.md`、根目录 `AGENTS.md`
- 抽样深读工程：ch03（模板）、ch11（hook 注入）、ch12（TX 注入）、ch15（raw 状态机）、
  ch16（VFS/fd）、ch19（TCP 控制通道）、ch20（httpd 压测）、ch21（MQTT 编排）、ch24（调优）
- 本文所有结论均给出文件路径出处；与 CONVENTIONS 不一致处集中在第 6 节汇总。

---

## 1. 标准骨架定义（自 ch03 提炼，经 ch15/16/19/20 二次验证）

### 1.1 环境基线（全部已在各章实测）

| 项         | 值                                                                       |
| ---------- | ------------------------------------------------------------------------ |
| ESP-IDF    | v6.0.2（`~/esp/esp-idf`，`. ~/esp/esp-idf/export.sh` 激活）              |
| lwIP       | IDF 捆绑 2.2.0-dev（上游 2.1.3 后开发版），全堆化 MEM_LIBC_MALLOC        |
| QEMU       | `esp_develop_9.2.2_20250817` fork，`qemu-system-xtensa`，openeth + SLIRP |
| 目标芯片   | esp32（Xtensa LX6 双核）                                                 |
| guest 地址 | DHCP 得 `10.0.2.15/24`，网关 `10.0.2.2`，DNS `10.0.2.3`                  |

出处：`practice/lwip-labs/CONVENTIONS.md` 第 1、3 节及第 6 节 Batch 1。

### 1.2 目录布局建议

```text
practice/lwip-examples/
├── README.md                 # 总索引：示例清单 + 端口登记总表（见本文第 4 节）
├── research/                 # 规划文档
└── exNN-slug/                # 每个示例自成一体的完整 IDF 工程
    ├── CMakeLists.txt        # root 构建骨架（见 1.4）
    ├── main/
    │   ├── CMakeLists.txt    # 见 1.4
    │   └── lab_main.c        # 标准联网骨架 + 本示例业务（见 1.3）
    ├── tools/
    │   ├── run_qemu.sh       # 统一 QEMU 启动器（timeout + tee run.log）
    │   ├── ctl.py            # 控制通道客户端（有控制口的示例才带）
    │   └── bench.py          # 主机压测/驱动脚本（按需）
    ├── sdkconfig.defaults    # 至少 CONFIG_ETH_USE_OPENETH=y（见 1.5）
    └── run.log               # 真实运行日志入库（受日志截断政策约束）
```

参照：ch19/ch20/ch24 的 `tools/` 三件套形态
（`practice/lwip-ch20-http-server/tools/{run_qemu.sh,ch20ctl.py,bench.py}`）；
ch11 的 `scripts/{run_exp.sh,exp11.py}` 是另一成熟变体（背景启动 + PID 清理 trap）。

### 1.3 app_main 标准调用序列（精确到函数，逐条有源）

以下序列综合自 `practice/lwip-ch03-qemu-network-lab/main/lab_main.c`（钦定模板），
并与 `practice/lwip-ch19-isr-and-priority-design/main/lab_main.c`、
`practice/lwip-ch20-http-server/main/lab_main.c` 的实现逐行比对一致：

```text
app_main(void)
│
├── ESP_ERROR_CHECK(esp_netif_init())                 // ① 必须是第一句网络相关调用
├── ESP_ERROR_CHECK(esp_event_loop_create_default())  // ② 默认事件循环
├── s_got_ip = xSemaphoreCreateBinary()               // ③ DHCP 完成信号量
│
├── [可选·先于一切受害流量] xTaskCreatePinnedToCore(
│       ctrl_server_task, ..., prio=22, core=1)       // ④ 控制平面钉 core1 高优先级
│                                                     //   （ch19/ch20 教训固化，见 C-14）
│
├── esp_netif_config_t cfg = ESP_NETIF_DEFAULT_ETH();
├── esp_netif_t *eth_netif = esp_netif_new(&cfg);     // ⑤ netif 实例
│
├── eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();      // rx 任务 4096B prio15
├── esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);   // ⑥ openeth MAC（仅 QEMU）
├── eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
├── phy_cfg.reset_gpio_num      = -1;                 // ⑦ 虚拟 PHY 无复位脚
├── phy_cfg.autonego_timeout_ms = 3000;
├── esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);   // ⑧ v6 registry 机制 PHY
│
├── esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
├── esp_eth_handle_t eth_handle = NULL;
├── ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));  // ⑨
│
├── esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
│                             &eth_event_handler, NULL);       // ⑩ 链路事件
├── esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
│                             &ip_event_handler, NULL);        // ⑪ GOT_IP 事件
│                                                             //   payload: ip_event_got_ip_t
├── esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
├── ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));         // ⑫ glue 层挂接，
│                                                             //   netif up 时自动起 DHCP
├── ESP_ERROR_CHECK(esp_eth_start(eth_handle));                 // ⑬ 自协商→链路up→DHCP
│
├── xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(10000)) != pdTRUE    // ⑭ 等 DHCP（超时报错返回）
│   → ESP_LOGE("DHCP timeout") ; return;
│
├── [推荐] 打印事实行 + READY 行到 stdout                       // ⑮ 如 $$$ EXREADY ...
│   （机器可读标记协议见 3.4 节）
│
├── 启动应用服务器任务 / 注册应用阶段                            // ⑯ 各示例业务
│
└── while (1) vTaskDelay(pdMS_TO_TICKS(60000));                 // ⑰ KEEPALIVE 保持进程存活
```

关键次序注记：

- ① 必须严格先于任何 socket/netconn 创建：tcpip 邮箱由 `esp_netif_init()` 创建，
  先创建 socket 会触发 `tcpip_send_msg_wait_sem` assert 崩溃复位
  （CONVENTIONS 第 6 节 Batch 1；ch16 `lab_main.c:552` 注释原话「必须先于任何 socket」）。
- 应用监听任务可以在拿到 IP 之前创建并 bind INADDR_ANY（ch03 `lab_main.c:230-233` 注释），
  但涉及对外主动连接的业务必须放在 ⑭ 之后。
- 事件枚举是 IDF v6 的 `ETHERNET_EVENT_*`（不是 v5 的 `ESP_ETH_EVENT_*`），
  IP 事件用 `IP_EVENT_ETH_GOT_IP`（CONVENTIONS Batch 1；ch03 `lab_main.c:47-67` 实现可抄）。

### 1.4 CMakeLists 模板

root `CMakeLists.txt`（出处：`practice/lwip-ch03-qemu-network-lab/CMakeLists.txt`）：

```cmake
cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Trim 构建：只编最小组件集（各章实测可将 build 体积控制在最小）
idf_build_set_property(MINIMAL_BUILD ON)
project(exNN_slug)
```

main `CMakeLists.txt` 的 `PRIV_REQUIRES` 清单（出处：ch03/ch19/ch20 三份 main/CMakeLists.txt）：

| 示例类型                                  | PRIV_REQUIRES                                                            | 验证源                                                                            |
| ----------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| 最小联网骨架（必选）                      | `esp_eth esp_netif esp_event lwip`                                       | `lwip-ch03-qemu-network-lab/main/CMakeLists.txt`                                  |
| + 计时/任务表/heap 观察                   | 上加 `freertos esp_timer`                                                | `lwip-ch19-.../main/CMakeLists.txt`、ch24 同款                                    |
| + HTTP 服务                               | 上加 `esp_http_server`                                                   | `lwip-ch20-http-server/main/CMakeLists.txt`                                       |
| + ping 会话                               | **无需新组件**：ping 实现在 lwip 组件内 `apps/ping/ping_sock.c`          | CONVENTIONS Batch 1；ch03 `lab_main.c:33-34`                                      |
| + 编译期 hook 注入（LWIP_HOOK_IP4_INPUT） | 在 **root** CMakeLists 加 `add_compile_options(-include ...)`，不放 main | `lwip-ch11-tcp-state-machine/CMakeLists.txt:10` 与其 `main/CMakeLists.txt:5` 注释 |

INCLUDE_DIRS：ch03 用 `"."`（头文件在 main/ 下需要被外部引用时）；ch19/ch20/ch24 用 `""`。
单独源文件拆分时可任意，二者均可构建。

### 1.5 sdkconfig.defaults 与构建-运行流程

`sdkconfig.defaults` 最小集（出处：ch03 与 ch24 各自的 sdkconfig.defaults）：

```ini
# 必填：OpenCores Ethernet MAC 驱动（仅 QEMU 可用，真机不可用）
CONFIG_ETH_USE_OPENETH=y

# 可观测性叠加层（按示例需要选用，ch24 验证过的组合）：
CONFIG_LWIP_STATS=y                        # lwip_stats 结构体可读
CONFIG_FREERTOS_USE_TRACE_FACILITY=y       # uxTaskGetSystemState（IDF v6 默认关！）
CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS=y  # ulRunTimeCounter 有值
CONFIG_FREERTOS_VTASKLIST_INCLUDE_COREID=y # TaskStatus_t.xCoreID 字段存在
```

三条 sdkconfig 纪律：

1. 改 `sdkconfig.defaults` 后必须删除 `sdkconfig` 重新生成才生效
   （CONVENTIONS Batch 1，末条）。
2. 多配置变体用 `SDKCONFIG_DEFAULTS="a;b"` 叠加层模式，另开 build 目录
   （`lwip-ch11-tcp-state-machine/README.md:22-24`：
   `idf.py -B build_d -D SDKCONFIG=sdkconfig.d11 -D SDKCONFIG_DEFAULTS="..." build`）。
3. 构建期参数注入可用 cache 变量 + `add_compile_definitions`
   （`lwip-ch19-isr-and-priority-design/main/CMakeLists.txt` 的 `CH19_APP_PRIO` 手法）。

标准构建-运行流程照抄 CONVENTIONS 第 3 节，但对示例套件做一处修订：
**去掉 `-global driver=nvram.esp32.efuse,...` 行**（理由见 C-02 与第 6 节不一致点 1），
采用 ch19/ch20/ch24 已固化的启动器形态：

```bash
tools/run_qemu.sh   # 参数化 timeout + tee run.log
```

其内核（出自 `practice/lwip-ch20-http-server/tools/run_qemu.sh`）：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
cd "$(dirname "$0")/.."
T=${1:-600}
timeout $T $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::<HOST_PORT>-:<GUEST_PORT> \
  -nographic -no-reboot 2>&1 | tee run.log
```

镜像生成兜底：`idf.py qemu monitor < /dev/null || true` 在重复构建后可能静默失败
（qemu_flash.bin 不再更新），此时手动合并：
`cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args`
（CONVENTIONS Batch 6）。固件打印 `__TIME__` 指纹核对镜像新鲜度（Batch 7，ch24 实践）。

---

## 2. 硬约束清单（每条注明出处）

编号 C-01 起，写入示例工程规格时可直接引用编号。

### 2.1 初始化与环境

- **C-01 socket/netconn 创建必须在 `esp_netif_init()` 之后**。
  出处：CONVENTIONS Batch 1「邮箱未就绪 → tcpip_send_msg_wait_sem assert 崩溃复位」；
  代码实证 `lwip-ch16-socket-netconn-vfs/main/lab_main.c:552`。
- **C-02 QEMU 启动命令不带 `-global driver=nvram.esp32.efuse,...`**。
  该行在本机 qemu 上偶发导致 openeth NIC 未创建，guest 在
  `esp_eth_mac_new_openeth()` 崩溃复位；遇到时删除该行重跑即愈。
  出处：CONVENTIONS Batch 4「QEMU 已知坑」；旁证：ch19/ch20/ch24 的
  `tools/run_qemu.sh` 均已删除该行（ch11 `scripts/run_exp.sh` 尚残留，属滞后）。
- **C-03 改 sdkconfig.defaults 必须删 sdkconfig 再生**。出处：CONVENTIONS Batch 1。
- **C-04 WiFi 不可仿真**：本环境 QEMU 无 esp-wifi-mac，WiFi 相关示例要么标注「需真机」，
  要么走 openeth 以太网对照路径。出处：CONVENTIONS 第 2 节。
- **C-05 openeth 启动噪声白名单**：启动日志固定刷 3 条 MAC filter ioctl 错误属预期噪音；
  QEMU 虚拟网卡 MAC 固定 `52:54:00:12:34:56`。验收时不得把这两项当故障。
  出处：CONVENTIONS Batch 1。

### 2.2 单线程上下文规则（tcpip_thread）

- **C-06 raw API 只能在 tcpip_thread 上下文调用**；应用任务观察协议栈状态一律经
  `tcpip_callback()` 投递观察器函数。范式代码：
  `lwip-ch15-raw-api-callbacks/main/lab_main.c` 的 `hb_in_stack()` +
  `app_main` 心跳循环（`lab_main.c:662-667`）。跨线程裸调后果演示（udp_new 断言复位、
  对在役 PCB 越权 write）也在同文件 `wild_new_task`/`wild_write_task`。
- **C-07 误用演示 vs 生产形态分开**：`CONFIG_LWIP_CHECK_THREAD_SAFETY=y` 守卫构建可当场击毙
  跨线程裸调——做反例教学用它，正常示例保持默认构建。
  出处：CONVENTIONS Batch 4；ch15 `print_facts()` 打印该开关状态（`lab_main.c:564-568`）。
- **C-08 raw API 连接生命周期契约**（示例代码必须示范正确写法，范本 ch15）：
  - EOF/错误分支：先处理 pbuf 所有权（`pbuf_free`），登出全部回调
    （`tcp_arg/recv/sent/err/poll` 全置 NULL，见 `detatch_callbacks()`），
    再清应用状态，最后 `tcp_close()` 或 `tcp_abort()`；回调内自行 abort 后返回 `ERR_ABRT`。
  - `err` 回调到来时 PCB 已被核心释放，只剩应用状态可清理（`raw_err_cb`）。
  - accept 中 `es==NULL` 或 alloc 失败 → `tcp_abort(newpcb)` 并返 `ERR_ABRT`。
    出处：`lwip-ch15-raw-api-callbacks/main/lab_main.c:159-361`。
- **C-09 发送泵必须注册 `tcp_sent()` 回调**（ACK 驱动补发），否则吞吐涓流；
  另注册 `tcp_poll()` 作兜底泵防死锁（ch15 `raw_poll_cb` 每 4 slow-tick 补推一次）。
  出处：CONVENTIONS Batch 2 + ch15 实现。
- **C-10 IP 地址常数禁止手写 u32**：必须 `PP_HTONL(LWIP_MAKEU32(a,b,c,d))`；
  `ipaddr_ntoa()` 共享静态缓冲会串值，多点打印用 `_r` 变体。
  出处：CONVENTIONS Batch 3；用法实例 `lwip-ch16-socket-netconn-vfs/main/lab_main.c:185`。

### 2.3 SLIRP/QEMU 能力边界（决定示例怎么设计实验）

- **C-11 SLIRP 无主机→guest 方向 ICMP**：宿主 `ping 10.0.2.15` 恒不通，ICMP 只能 guest 发起
  （示例若含连通性检查，用 TCP/UDP 探针而不是被 ping）。
  出处：CONVENTIONS Batch 4。
- **C-12 guest→`10.0.2.2:P` 的 TCP/UDP 连接落到宿主机 loopback 同端口**——这是全部
  「host 工具」类资产的通信根基（如 ch08 host_listener:8108、ch06 recv_counter:8006、
  ch21 mosquitto:1883）。出处：CONVENTIONS Batch 3；
  实证 `lwip-ch08-ethernet-arp/tools/host_listener.py:5`。
- **C-13 SLIRP 怪癖清单**（示例文档「已知行为」节必备）：
  - 用户态转发吞吐天花板约 120 Mbit，瓶颈在 SLIRP 与 openeth RX 描述符环
    （默认 TX=1/RX=4），不在协议栈（CONVENTIONS Batch 2、Batch 5）。
  - 对 discard 端口的 UDP 会立即回弹 ICMP type3 大帧；同刻第二个 ping 会话恒超时；
    确定性流量用 UDP 探针造（Batch 5）。
  - SLIRP 突发尾巴恒定约 0.8% 仿真丢包，与协议栈无关（Batch 3）。
  - 回环加密税极端示例：明文 13.39 vs TLS 0.38 Mbit/s ≈ 97%（Batch 6，ch22）。

### 2.4 优先级地图与调度纪律

- **C-14 openeth 平台基准优先级地图**（示例建任务时的坐标系，实测来源 CONVENTIONS Batch 5）：

  | 任务         | 优先级 | 栈    | 亲和        |
  | ------------ | ------ | ----- | ----------- |
  | tcpip        | 18     | 3584B | NO_AFFINITY |
  | emac_rx      | 15     | 4096B | -           |
  | 应用 echo 类 | 5      | 4096B | 建议 pin 核 |
  | ping 任务    | 2      | -     | -           |

  控制平面试例值：prio=22、pin core1（ch19/ch20 `ctrl_srv`），在受害者带宽之外保证可控性。

- **C-15 测量任务优先级必须压过 tcpip(18)**：低优先级探针会被 NO_AFFINITY 高优先级自旋饿住，
  造成「没有阻塞」假象（双核测量陷阱）。出处：CONVENTIONS Batch 4。
- **C-16 亚毫秒计时不许用 `sys_now()`**（10ms tick 网格），用 `esp_timer_get_time()`。
  出处：CONVENTIONS Batch 4（`sys_now()` 实现在
  `components/lwip/port/freertos/sys_arch.c`）。

### 2.5 故障注入纪律（示例若含注入场景）

- **C-17 注入优先做在协议栈内**（应用层/驱动层），不依赖宿主机 root + tc。
  出处：CONVENTIONS 第 3 节要点。
- **C-18 TX 方向注入**：`esp_netif_get_netif_impl()` 取 lwip netif，在 tcpip 线程内换
  `linkoutput` 函数指针包一层 wrapper。范本：
  `lwip-ch12-tcp-reliability/main/lab_main.c:97-132`（`dropping_linkoutput` 按 xorshift
  LCG 概率丢帧，保存 `s_orig_linkoutput` 还原）。RX 方向**不能**换 `netif->input`
  （openeth 路径不经它），必须编译期 `LWIP_HOOK_IP4_INPUT`（见 C-19）或
  `esp_eth_update_input_path()`（Batch 5，ch17 手法）。
- **C-19 编译期 hook 注入配方**（ch11 完整三件套，可直接搬）：
  1. 头文件声明宏与原型，且原型用 `#ifndef __ASSEMBLER__` 保护
     （`lwip-ch11-tcp-state-machine/main/ch11_ip4_hook.h`）；
  2. root CMakeLists `add_compile_options(-include <头>)` 强制进所有编译单元
     ——必须在 root，组件 target 在 main 的组件级 CMakeLists 里不可见
     （`lwip-ch11-tcp-state-machine/CMakeLists.txt:10` 及
     `main/CMakeLists.txt:5` 注释）；
  3. 语义：hook 返回非 0 表示消费了 pbuf，所有权移交需自行释放
     （`ch11_ip4_hook.h:9`）。
- **C-20 故障场景下探测连接用开环 paced 模式**（connect 显式超时报失败），
  不要闭环等回复才发下一个；且注入控制平面必须活在受害者带宽之外。
  出处：CONVENTIONS Batch 5（spinstop 被自己的注入卡住的教训）；
  工具范本 `lwip-ch19-isr-and-priority-design/tools/bench_openloop.py`。

### 2.6 测量与配对纪律

- **C-21 性能对比必须同时段开机配对测量**：QEMU 吞吐受宿主机负载影响 ±50%，
  隔天/异载数字不可比。出处：CONVENTIONS Batch 4；批量 JSON 档案实践见
  `lwip-ch20-http-server/results/*_r{1,2,3}.json`（每组 3 轮配对）。
- **C-22 所有数字必须真实测量且写明方法**（工具、命令、重复次数），严禁编造
  run.log 输出。出处：CONVENTIONS 第 4 节、AGENTS.md CI 节精神同源。
- **C-23 长跑受控**：单次实验控制在几分钟内（timeout 兜底）；退出码 124 =
  timeout 正常截停，0/-1 = 应用主动 reset，都算正常结束。
  出处：CONVENTIONS 第 3 节；`lwip-ch20-http-server/tools/run_qemu.sh:4` 注释。

### 2.7 端口与进程卫生

- **C-24 kill QEMU 必须 PID/hostfwd 特征精杀，禁止 pkill**（并行作者实例共存）。
  出处：CONVENTIONS Batch 3；实现范本 `lwip-ch11-tcp-state-machine/scripts/run_exp.sh`
  的 `cleanup()` trap、`lwip-ch21-mqtt/scripts/run_lab.sh` 的 PID 守卫与
  「端口被占先等待释放再校验归属」循环（`run_lab.sh:26-33`）。
- **C-25 QEMU 启动后立刻探测 hostfwd 冲突**：grep 日志
  `(could not set up host forwarding|Failed to add)`，命中即中止。
  出处：`lwip-ch11-tcp-state-machine/scripts/run_exp.sh:34`。
- **C-26 新示例先查端口总账再取号**（本文第 4 节为权威账本），冲突会导致 QEMU 起不来
  或串台。出处：CONVENTIONS Batch 2/3/4/5 累积账目 + 本文全面复核版。

### 2.8 入库与格式约束（来自 AGENTS.md「CI 与提交规范」节）

- **C-27 日志超 1MB 必须截断入库**：保留首 5000 行 + 关键证据行（assert failed/panic/
  abort 等）+ 末尾 500 行，写入 `[LOG TRUNCATED: ...]` 标注原始行数；调试刷屏大日志不入库。
- **C-28 只提交源码**：`main/`、`CMakeLists.txt`、`sdkconfig.defaults`（及变体）、
  `README.md`、run 日志；生成物（`build*/` 通配、`sdkconfig` 生成物、
  `managed_components/`、`qemu_efuse.bin`、`qemu.pid`）gitignore 必须命中。
- **C-29 一切新增 .md/.json/.yaml 必须先 `npx prettier <文件> --write`**，交付前本地
  `npm run check` 复现 CI（prettier 全仓检查覆盖 practice/ 目录）。
- **C-30 wikilink 完整性**：文章引用的其他系列必须一并入库（对本套件：README 引用的
  content 文章必须在库中）。

---

## 3. 可复用资产索引表

### 3.1 固件端模式（搬代码时保留原出处注释）

| 资产                             | 源路径（相对 practice/）                                             | 搬运价值                                                                                          |
| -------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| 联网 bring-up 钦定模板           | `lwip-ch03-qemu-network-lab/main/lab_main.c`                         | 1.3 节骨架唯一权威源                                                                              |
| raw API per-connection 状态机    | `lwip-ch15-raw-api-callbacks/main/lab_main.c`                        | `es_t` 背压队列、`detatch_callbacks`、graceful-close vs abort 双路径、poll 兜底泵——raw 示例的地基 |
| UDP raw 控制口（tcpip 内命令机） | `lwip-ch15-raw-api-callbacks/main/lab_main.c:476-552`                | 小型控制面：免烧写改全局旋钮（leak/busy），带 ACK 应答                                            |
| TCP 控制通道（一条连接一条命令） | `lwip-ch19-isr-and-priority-design/main/lab_main.c:302-389`          | ch19/ch20 同构；命令解析 + `$$$` 应答；运行时 `vTaskPrioritySet` 改参数                           |
| 任务表 dump / run-time 差分      | `lwip-ch19-isr-and-priority-design/main/lab_main.c:94-136`           | `uxTaskGetSystemState` 快照差分算每任务 CPU 账单（需 C-15 的三个 Kconfig）                        |
| httpd 带 user_ctx 端点统计       | `lwip-ch20-http-server/main/lab_main.c:53-98,119-282`                | ep_stats 计数器 + ESP_HTTP_SERVER_EVENT 全事件记账 + 运行时 restart 改参                          |
| async worker 模式                | `lwip-ch20-http-server/main/lab_main.c:214-246`                      | handler 快速移交重活的正解                                                                        |
| VFS/fd 实验组                    | `lwip-ch16-socket-netconn-vfs/main/lab_main.c:329-544`               | fstat(S_IFSOCK)/POSIX read-write/poll 双连检测、fd 耗尽 ENFILE 观察、阻塞 recv 四种逃生           |
| loopback 基准对（sock vs nc）    | `lwip-ch16-socket-netconn-vfs/main/lab_main.c:168-327`               | 排除 SLIRP 干扰测纯 API 层深的口径（127.0.0.1 特判内建于 ip4_route）                              |
| FACT 事实打印行                  | `lwip-ch15-raw-api-callbacks/main/lab_main.c:556-575`                | 开机一行输出 sizeof/WND/MSS/邮箱深度等，验收机器核对                                              |
| 观测打标输出协议                 | ch11 `state_lab.c`、ch15/19/20 lab_main.c                            | 见 3.4 节，建议直接定为示例套件标准                                                               |
| hook 注入样板                    | `lwip-ch11-tcp-state-machine/main/ch11_ip4_hook.h` + root CMakeLists | 编译期 LWIP_HOOK_IP4_INPUT 注入完整配方（C-19）                                                   |

### 3.2 主机工具（全部 python3 stdlib 或轻依赖，随示例搬运）

| 工具                          | 源路径（相对 practice/）                                                                       | 能力摘要                                                                          |
| ----------------------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| TCP 多子命令压测器            | `lwip-ch15-raw-api-callbacks/host/tcp_bench.py`                                                | rtt/tput/dualrtt/eofcycle/abrt/floodtp/ctrl 七个子命令；魔数载荷帧 `C15`+kind+seq |
| 开环 RTT 分位数探针           | `lwip-ch19-isr-and-priority-design/tools/bench_openloop.py`                                    | 固定节奏发包不等回复，输出 p50/p90/p99——弱网/故障场景标准测量姿势（C-20）         |
| 背景负载锤                    | `lwip-ch19-isr-and-priority-design/tools/hammer.py`                                            | 并发压测背景流                                                                    |
| 控制通道客户端                | `lwip-ch19-isr-and-priority-design/tools/ch19ctl.py`、`lwip-ch20-http-server/tools/ch20ctl.py` | 两个风格（读终止标记 vs 读 EOF），取一统一                                        |
| HTTP 压测器（ka/noka + JSON） | `lwip-ch20-http-server/tools/bench.py`                                                         | keep-alive 开关两模式，延迟分布，输出一行 JSON 摘要供成表                         |
| Slowloris 慢攻击 harness      | `lwip-ch20-http-server/tools/slowloris.py`                                                     | 半请求头 + 滴灌续命 + 死亡嗅探                                                    |
| 大 POST 发射器                | `lwip-ch20-http-server/tools/bigpost.py`                                                       | Content-Length 骗大 / chunked 上传                                                |
| MQTT 桥（纯 stdlib 客户端）   | `lwip-ch21-mqtt/scripts/mqtt_bridge.py`                                                        | 手写 MQTT 3.1.1 CONNECT/SUBSCRIBE/PUBLISH + qos1 puback + 断线重连 + JSONL 落盘   |
| 主机侧 TCP sink 计数器        | `lwip-ch06-zero-copy-tcp-write/host/recv_counter.py`                                           | guest 外发吞吐测量（配合 C-12 反向连接模式）                                      |
| 高并发 accept/close 监听器    | `lwip-ch08-ethernet-arp/tools/host_listener.py`                                                | ARP 税/连接风暴实验的对端                                                         |
| UDP 三层 API bench            | `lwip-ch10-udp-pcb-layers/host/udp_bench.py`                                                   | raw/netconn/socket 同题对比驱动                                                   |
| 实验编排器（全周期范式）      | `lwip-ch11-tcp-state-machine/scripts/run_exp.sh` + `exp11.py`                                  | 背景 QEMU + hostfwd 冲突探测 + PID trap 清理 + 分 phase 驱动（C-24/C-25 范本）    |
| 多进程编排（broker 级）       | `lwip-ch21-mqtt/scripts/run_lab.sh` + `mosquitto_lab.conf` + `analyze.py`                      | 孤儿守卫、端口等待归属校验、HOST_MARK 时间戳事件流                                |
| 统一 QEMU 启动器              | `lwip-ch19/ch20/ch24 .../tools/run_qemu.sh`                                                    | timeout + tee run.log 形态（1.5 节已定为套件标准）                                |

### 3.3 sdkconfig 叠加层样例

| 文件                                                       | 用途                                          |
| ---------------------------------------------------------- | --------------------------------------------- |
| `lwip-ch11-tcp-state-machine/sdkconfig.ch11d.defaults`     | 收窄 `MAX_ACTIVE_TCP=2` 制造 PCB 耗尽的变体层 |
| `lwip-ch15-raw-api-callbacks/sdkconfig.defaults.thrcheck`  | CHECK_THREAD_SAFETY 击毙演示配置              |
| `lwip-ch24-performance-tuning-pitfalls/sdkconfig.defaults` | 可观测性 + 调优参数全集（窗口×环深实验产物）  |

### 3.4 日志打标协议（建议直接定为套件规范）

四章实践已自发收敛出一套机器可读前缀，示例套件应制度化：

| 标记                                 | 含义             | 出处                                          |
| ------------------------------------ | ---------------- | --------------------------------------------- |
| `$$$ XXXREADY port=N`                | 某服务就绪门信号 | ch19 `ECHOREADY`/ch20 `CTRLREADY`/`HTTPREADY` |
| `$$$ KEY=value ...`                  | 命令应答/状态行  | ch19 `SET`、ch20 `STATS`/`EP`/`ENDSTATS`      |
| `### TASKTABLE` / `### ENDTASKTABLE` | 块状 dump 边界   | ch19 `dump_task_table`                        |
| `$@@ BENCHSTART/DONE`                | 长事务边界       | ch19 `bench` 命令                             |
| `PHASE A/B/...`                      | 实验阶段分隔     | ch16 `lab_main.c:597` 起                      |
| `EXnn-FACT`/`-ST`/`-CLOSE ...`       | 事实行/统计/事件 | ch15 `CH15-*` 家族的泛化                      |

好处：主机驱动脚本与验收器可以只用 grep 就断言流程推进（ch11/exp11.py 即此法）。

---

## 4. 端口分配总账

### 4.1 hostfwd 已占用（host:port -> guest:port，本仓全量 grep 复核）

数据来源：对 `practice/lwip-ch*/` 全部 `.c/.sh/.py/.md` 的 `hostfwd=` 正则全量提取
（生成物与 managed_components 已排除）。

| host 端口 | proto | guest 端口 | 占用工程  | 用途           |
| --------- | ----- | ---------- | --------- | -------------- |
| 8003      | tcp   | 8888       | lwip-ch03 | echo           |
| 8005      | tcp   | 8888       | lwip-ch05 | 实验           |
| 8009      | tcp   | 8888       | lwip-ch09 | 实验           |
| 8010      | udp   | 8010       | lwip-ch10 | raw UDP 层压测 |
| 8012      | tcp   | 8012       | lwip-ch12 | 可靠性实验     |
| 8013      | tcp   | 8013       | lwip-ch12 | 可靠性实验     |
| 8014      | tcp   | 8814       | lwip-ch11 | 演示服务器     |
| 9014      | tcp   | 8813       | lwip-ch11 | 控制通道       |
| 8015      | tcp   | 8888       | lwip-ch13 | 实验           |
| 8016      | tcp   | 8888       | lwip-ch14 | 实验           |
| 8017      | tcp   | 8017       | lwip-ch15 | raw echo       |
| 8517      | tcp   | 8517       | lwip-ch15 | socket 对照组  |
| 8018      | tcp   | 8888       | lwip-ch16 | 实验           |
| 8020      | tcp   | 8888       | lwip-ch17 | 实验           |
| 8020      | udp   | 8020       | lwip-ch17 | 注入/压测      |
| 8022      | tcp   | 8888       | lwip-ch19 | echo 受试目标  |
| 8023      | tcp   | 9999       | lwip-ch19 | 控制通道       |
| 8024      | tcp   | 80         | lwip-ch20 | httpd          |
| 8025      | tcp   | 9999       | lwip-ch20 | 控制通道       |
| 8027      | udp   | 8027       | lwip-ch15 | raw 控制口     |
| 8028      | tcp   | 8888       | lwip-ch24 | echo           |
| 8029      | tcp   | 9999       | lwip-ch24 | 控制通道       |
| 8030      | tcp   | 80         | lwip-ch24 | http           |
| 8031      | tcp   | 8888       | lwip-ch23 | 探针目标       |
| 8050      | tcp   | 8888       | lwip-ch18 | WiFi 对照实验  |

### 4.2 非 hostfwd 的主机侧监听（guest 主动外连，同样构成占用）

| host 端口 | 占用者                                                   | 模式                  |
| --------- | -------------------------------------------------------- | --------------------- |
| 8006      | `lwip-ch06-zero-copy-tcp-write/host/recv_counter.py`     | guest → 10.0.2.2:8006 |
| 8108      | `lwip-ch08-ethernet-arp/tools/host_listener.py`          | guest → 10.0.2.2:8108 |
| 1883      | `lwip-ch21-mqtt/scripts/mosquitto_lab.conf`（mosquitto） | guest → 10.0.2.2:1883 |

### 4.3 guest 内部端口（不占主机，但避免撞号造成混淆）

| guest 端口          | 工程       | 用途                                           |
| ------------------- | ---------- | ---------------------------------------------- |
| 9001-9004           | lwip-ch16  | sock/nc/VFS/silent 四个 loopback 服务          |
| 7777                | lwip-ch19  | 回环 ping-pong bench                           |
| 9999                | ch19/20/24 | 控制通道 guest 侧事实上标准口                  |
| 8010/8011/8012/8019 | lwip-ch10  | raw/netconn/socket UDP + 控制口（仅 guest 侧） |

### 4.4 号段结论与新号段建议

事实：所谓「8000+章号」公约（CONVENTIONS 第 3 节）已名存实亡——80xx 低段已被塞满，
且 ch11 的 9014 已经跳出 8xxx 段。本仓 8100 以上实际占用只有三点：
`8108`（ch08 主机监听）、`8517`（ch15 hostfwd）、`9014`（ch11 hostfwd）。

建议（避开全部上述端口）：

1. **专用号段：8200-8299**（全仓 grep 证实零占用）。每个示例分一个十位块，
   例内固定子槽位：
   - `+0`：主服务；`+1`：控制通道（若有）；`+2`、`+3`：备用第二服务；
   - `+9`：保留（内部诊断口）。
     即示例 ex01 用 8200/8201…，ex02 用 8210/8211…… 可容 10 个示例，
     扩展段顺延 **8300-8399**（同样零占用）。
2. 若坚持字面上的「8100+」开头：可用 **8110-8199**，但必须永久避让 `8108`
   （ch08 legacy），不如 8200 段干净。
3. guest 内部端口维持既有惯例：控制口 9999、实验服务用 88xx/80xx，
   不与新号段产生映射混淆（hostfwd 两端端口号建议保持一致，ch15/12 风格：
   `hostfwd=tcp::8201-:8201`，比 ch03 的 `8003->8888` 平移式更好审计）。
4. 总表维护规则：`practice/lwip-examples/README.md` 维护示例套件自己的端口登记表；
   新示例 PR 必须带该表更新（对应 C-26）。

---

## 5. 验收标准草案（单个合格示例工程检查清单）

### 5.1 构建

- [ ] 干净环境下 `export.sh` → `idf.py set-target esp32` → `idf.py build` 一次通过；
      无新增告警。
- [ ] 删除生成的 `sdkconfig` 重跑仍可构建（证明 `sdkconfig.defaults` 自足，C-03）。
- [ ] root CMakeLists 含 `MINIMAL_BUILD ON`；main 组件 `PRIV_REQUIRES` 与实际 include
      对齐（1.4 清单，缺项会在 trimmed build 下才爆）。

### 5.2 QEMU 运行

- [ ] `tools/run_qemu.sh` 单命令可启动；**不含 efuse `-global` 行**（C-02）。
- [ ] 启动后日志无 hostfwd 冲突签名（C-25），或脚本内置探测。
- [ ] `run.log` 有真实完整链路：boot → openeth → `GOT_IP` → 业务 READY 门信号 →
      至少一轮完整交互输出。严禁编造（C-22）。
- [ ] 结束方式受控：timeout 124 或应用主动退出（C-23），无 panic 复位循环
      （预期演示的崩溃除外，且须在 README 声明）。
- [ ] 退出码/终止方式在 README 说明。

### 5.3 README

- [ ] ASCII/mermaid 拓扑图，标注 host <-> SLIRP <-> guest 的全部端口映射与本示例
      所用号段位置。
- [ ] 从零可复制的完整命令序列：构建、镜像生成（含 merge-bin 兜底提示）、启动、
      每个 host 工具的调用示例。
- [ ] 「已知行为」小节收录适用的 SLIRP 怪癖（C-13 白名单噪音 C-05）。
- [ ] 端口号登记于套件总表并在文内注明用途。

### 5.4 日志入库与仓库卫生

- [ ] `run.log` 超 1MB 则按 C-27 截断（首 5000 + 证据行 + 末 500 + `[LOG TRUNCATED]`）。
- [ ] `git status` 干净：`build*/`、`sdkconfig`、`managed_components/`、`qemu_efuse.bin`
      均被 ignore 命中（C-28）。
- [ ] 脚本无 `pkill`，QEMU/后台进程按 PID 清理（C-24）。

### 5.5 格式与 CI

- [ ] 全部新 `.md/.json/.yaml` 已跑 `npx prettier --write`（C-29）。
- [ ] 本地 `npm run check` 绿。
- [ ] 若引用系列文章：wikilink 目标均已入库（C-30）。

### 5.6 编码纪律静态自查

- [ ] 无任何 socket/netconn 创建早于 `esp_netif_init()`（C-01）。
- [ ] raw API 调用全部处于 tcpip 上下文，跨线程观察走 `tcpip_callback`（C-06）。
- [ ] raw 服务的 EOF/error/close/abort 路径符合 C-08 契约（重点查 detach 顺序）。
- [ ] 注册了 `tcp_sent`/`tcp_poll` 泵（C-09，吞吐型服务）。
- [ ] IP 常数全部经 `PP_HTONL(LWIP_MAKEU32(...))`（C-10）。
- [ ] 服务端设置 `SO_REUSEADDR`（重复运行友好，ch03 起的全部工程一致实践）。
- [ ] 控制通道任务（若有）钉 core1 且优先级高于受害任务（C-14）。

---

## 6. CONVENTIONS.md 与仓库实际的不一致点（发现的 drift）

调研过程中确认以下偏差，供修订 CONVENTIONS 或在本套件规格中绕开：

1. **第 3 节标准流程与第 6 节 Batch 4 自相矛盾（efuse 行）**。
   第 3 节的照抄模板包含 `-global driver=nvram.esp32.efuse,...`，而 Batch 4 明确记录该行
   偶发导致 openeth NIC 未创建。仓库最新 runner（ch19/ch20/ch24 的 `tools/run_qemu.sh`）
   均已删除该行，但第 3 节文本未更新，`lwip-ch11-tcp-state-machine/scripts/run_exp.sh`
   也仍带此行。示例套件采用无 efuse 版（本文 1.5、约束 C-02）。

2. **「8000+章号」端口公约名存实亡，账目无单一权威表**。
   实际分配是先到先得：ch11 用 8014+9014（并非 8011，低段被占后跳号且逸出到 9xxx）、
   ch12 追加 8013、ch15 追加 8517/8027、ch18 用 8050、ch23 用 8031、ch24 用
   8028-8030。CONVENTIONS 的账目散落在 Batch 2/3/4/5 正文里且相互补充，
   无法一次查全。本文第 4 节为复核后的全量总账。

3. **Batch 3 的 UDP 账目与当前代码漂移**。
   Batch 3 称 hostfwd 已占「8010~8012(UDP)」，当前仓库 ch10 仅剩
   `hostfwd=udp::8010-:8010` 一条；8011/8012 现仅为 guest 侧端口。
   Batch 3/4 列出的 8019 在现仓库中找不到对应 hostfwd（现为 ch10 guest 侧控制口）。
   账目偏保守方向（多报占用），不会导致事故，但印证「账本只增不减、与代码不同步」，
   新套件应以可 grep 的登记表替代口头账。

4. **ch06 的 8006 类型记错**。
   Batch 2 将 8006 列入「hostfwd 端口已占用」，实际它是 guest 反向外连的主机侧监听端口
   （`lwip-ch06-zero-copy-tcp-write/host/recv_counter.py:71`，默认 `--port 8006`），
   属 4.2 类而非 hostfwd。两类占用都成立，但机制不同（hostfwd 由 QEMU 占、
   反向由 host 工具进程占），排障手段也不同。

5. **工程 README 覆盖率极低，CONVENTIONS 未要求**。
   24 个工程仅 9 个有 README.md；其中同时满足「拓扑图 + 完整复现命令」标准的更少
   （较完整的样例：ch11、ch16、ch23 的 README）。示例套件把 README 列为一票否决项
   （5.3 节），这是相对 CONVENTIONS 的**加严**而非纠偏，特此注明缘由。

6. **次要**：CONVENTIONS 第 2 节说联网章节「复用 ch3 验证的以太网 bring-up 模板」，实际
   ch19/ch20 已在模板上追加了本地化改动（控制平面先行启动、DHCP 超时放宽到 15s、
   `#include "esp_eth_mac_openeth.h"` 显式头），后续章节抄的是 ch19 版而非 ch03 原版。
   本文档 1.3 的序列以两者的公共稳定部分为准，并把控制平面列为可选步骤 ④。

---

## 7. 主要参考文件

- `/home/huanglin/code/quartz/practice/lwip-labs/CONVENTIONS.md`（环境事实 + 六批实测沉淀）
- `/home/huanglin/code/quartz/AGENTS.md`（CI 与提交规范、日志截断政策）
- `/home/huanglin/code/quartz/practice/lwip-ch03-qemu-network-lab/main/lab_main.c`（钦定模板）
- `/home/huanglin/code/quartz/practice/lwip-ch11-tcp-state-machine/`（hook 注入 + 编排脚本）
- `/home/huanglin/code/quartz/practice/lwip-ch12-tcp-reliability/main/lab_main.c`（TX 注入）
- `/home/huanglin/code/quartz/practice/lwip-ch15-raw-api-callbacks/`（raw 状态机 + 七合一 bench）
- `/home/huanglin/code/quartz/practice/lwip-ch16-socket-netconn-vfs/main/lab_main.c`（VFS/fd）
- `/home/huanglin/code/quartz/practice/lwip-ch19-isr-and-priority-design/`（控制通道 + 任务表）
- `/home/huanglin/code/quartz/practice/lwip-ch20-http-server/`（httpd 压测全家桶）
- `/home/huanglin/code/quartz/practice/lwip-ch21-mqtt/scripts/`（多进程编排范式）
- `/home/huanglin/code/quartz/practice/lwip-ch24-performance-tuning-pitfalls/`（调优收官 runner）
