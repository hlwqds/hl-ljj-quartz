# lwip-pcapx-lab —— pcapx S3 集成验收实验工程

对 `../pcapx/` 组件（S1 核心 + S2 sinks）做 QEMU 全流程集成验收：openeth bring-up →
esp_console → pcapx attach → UDP/DNS 打流 → semihost pcap 落盘 → detach → 宿主校验。

- 规格：`docs/spec/pcapx.md` §4 行为契约、§5 验证计划
- 环境：ESP-IDF v6.0.2 / lwIP 2.2.0-dev / QEMU esp32 + openeth-SLIRP + `-semihosting`
  （见 `../lwip-labs/CONVENTIONS.md`）
- 会话全自动，不依赖串口交互

## 复现（两条 shim 命令）

```bash
# 构建 + 生成 QEMU 镜像
source /home/huanglin/esp/shims/build-pcapx-lab.sh

# 运行 60s（cap.pcap 落在本目录，串口输出 tee 到 run.log）
RUN_SECONDS=60 source /home/huanglin/esp/shims/run-pcapx-lab.sh

# 宿主校验（rx+tx==total 成对断言 + ARP 计数）
python3 ../pcapx/tools/pcapx_validate.py cap.pcap --expect total=107,arp=5,rx=53,tx=54
```

实验切换：编辑 `sdkconfig.defaults` 打开对应开关（build shim 每次重跑
`idf.py set-target`，sdkconfig 从 defaults 重新生成），再依次 source 两个 shim。

## 会话设计

1. openeth + DHCP（照抄 ch3 模板，SLIRP 得 `10.0.2.15`，DNS `10.0.2.3`）
2. `esp_console_init` → `pcapx_console_register`（IDF v6：init 之前不能 register），
   之后用 `esp_console_run("pcapx_stats")` 非交互驱动命令
3. 契约失败路径演示：
   - `attach(netif=NULL,sink=NULL)` → `ATTACH_FAIL reason=arg`
   - `attach(sink="/tmp/.")` → `SINK_OPEN_FAIL`（basename="."，宿主 open 目录
     EISDIR=21；QEMU 直连模式下与「未开 -semihosting」走同一 hint 行）
     - `ATTACH_FAIL reason=sink_open`
   - 已 attach 再 attach → `ATTACH_FAIL reason=busy`（该路径 core 未接管第二个
     sink 对象，故意遗留 ~4.3KB 换契约行证据）
4. 默认会话：semihost sink `/tmp/cap.pcap`、rx+tx、snaplen=128、过滤全 0 →
   50 个 UDP 包 × 20ms 发往 `10.0.2.2:9999`（闭合端口；目的 MAC 是网关 → ARP
   请求/应答，闭合端口回 ICMP port-unreachable，天然覆盖 ARP+IP+UDP+ICMP）
   - `getaddrinfo("baidu.com")`（DNS 查询/响应）→ 排空 500ms → stats → detach
     → 再打 stats（契约：未 attach 全 0）

## 实验开关（sdkconfig.defaults，默认全关）

| 开关                           | 内容                                                                                                                                                                                                                                           |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CONFIG_LAB_PCAPX_EXP_DROP=y`  | 丢包账目：lab 私有慢 sink（busy-wait 2ms/帧，出环速率钉死 ~500 帧/s）+ ring=2048 + snaplen=64 + 500 背靠背 UDP → 环满丢新。实测：`DROP cnt=32..896` 28 条、恒等式 `rx+tx=1003 == filtered(0)+dropped(918)+written(85)`、ring_high_wm=1976/2048 |
| `CONFIG_LAB_PCAPX_EXP_CHURN=y` | 竞态冒烟：UDP 流量（8ms/包）进行中 attach/detach ×100 → rounds_ok=100/100 无 crash，heap 344204→348428（delta -4224，无泄漏）。该构建先跑完整默认会话再跑 churn                                                                                |

注：DROP 实验用 lab 内自定义 `slow_sink`（vtable 实现正是 pcapx 可插拔轴的用法
演示）——数据丢弃仅计数，pcap 产物由默认会话提供。曾尝试 vTaskDelay 压慢 writer，
但 QEMU 下 tick 背压不稳定（1000 帧未触发一次 drop），改 busy-wait 后确定性触发。

## 验收产物

| 文件            | 内容                                                   |
| --------------- | ------------------------------------------------------ |
| `run.log`       | 默认会话（107 帧全链路：ARP 5 / UDP 52 / ICMP 50）     |
| `run-drop.log`  | DROP 实验（28 条 DROP 契约行 + IDENTITY OK）           |
| `run-churn.log` | CHURN 实验（101 对 ATTACH/DETACH + heap 对账）         |
| `cap.pcap`      | 默认会话产物，`pcapx_validate.py` exit 0 + expect 全过 |

## 本工程发现并修复的组件缺陷（详见 docs/decisions.md KD-9/KD-10）

1. `pcapx_sink_semihost.c`：IDF `esp_vfs_semihost` 硬依赖 OpenOCD attach（DSRSET
   位），QEMU `-semihosting` 不置位 → 整条 VFS 路径必失败。修复：新增 SIMCALL
   直连 fallback（Kconfig `PCAPX_SEMIHOST_SIMCALL_FALLBACK`，默认 y）。
2. `pcapx_core.c` tap 写环：帧数据直写环时漏加 12B prefix 偏移 → 帧头盖掉元数据
   → writer 解析出垃圾 caplen → tail 越过 head → used 下溢 → 越界写环踩堆
   （症状：TLSF assert / InstrFetchProhibited / Double exception 随机出现）。
