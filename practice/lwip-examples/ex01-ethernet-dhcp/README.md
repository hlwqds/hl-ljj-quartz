# ex01 ethernet-dhcp —— 以太网起播基线

`practice/lwip-examples` 套件的第 1 课，也是最薄的一课：把 QEMU 的 openeth 虚拟网卡带到 DHCP 拿到 IP，**全程事件可见**（START / CONNECTED / GOT_IP 各阶段带时间戳）、**机器可读标记齐全**（`$$$ EXREADY` 一行即可让验收脚本断言成功）。无业务连接、无 hostfwd 端口、不需要任何主机端工具——复制改名就是你的下一个项目的起点。

## 目的

1. 走通 ESP-IDF v6 标准以太网 bring-up 序列：`esp_netif_init()` → 事件循环 → `esp_netif_new(ESP_NETIF_DEFAULT_ETH)` → openeth MAC + generic PHY → 驱动安装 → 注册事件 → glue 挂接 → `esp_eth_start()` → 等 DHCP；
2. 观察三个关键事件的完整时序与间隔：驱动 START、PHY 自协商完成（CONNECTED）、DHCP 租约到手（GOT_IP）；
3. 演示如何周期采样 `lwip_stats.link` 计数增量（读取经 `tcpip_callback()` 投递到 tcpip_thread 执行，示范跨线程观察的正确姿势）。

## 网络拓扑

```text
     Linux host                                   ESP32 guest (QEMU)
 ┌────────────────────────┐                  ┌──────────────────────────────┐
 │ qemu-system-xtensa     │   SLIRP 用户态   │ open_eth MAC 52:54:00:12:34:56│
 │  -M esp32              │◄────────────────►│ esp_eth + esp_netif          │
 │  -nic user,model=open_eth                 │ lwIP 2.2.0-dev (IDF v6.0.2)  │
 │  内置 DHCP/DNS 代理    │                  │ app: 事件打印 + 统计观测      │
 └────────────────────────┘                  └──────────────────────────────┘
        10.0.2.2 = 网关；DHCP 下发：
        guest 得 10.0.2.15/24，DNS = 10.0.2.3（注意不是网关）
```

端口登记：本示例**不占用任何端口**（SPEC §4 中 ex01 行：「无需联网服务端口」），QEMU 命令不带 hostfwd。

## 构建与运行

环境：ESP-IDF v6.0.2（`~/esp/esp-idf`），QEMU 用 Espressif fork `esp_develop_9.2.2_20250817`。从仓库根目录出发：

```bash
cd practice/lwip-examples/ex01-ethernet-dhcp
. ~/esp/esp-idf/export.sh
idf.py set-target esp32                     # 仅首次需要
idf.py build

# 生成 QEMU 镜像（monitor 因无 TTY 报错属预期，镜像已生成）
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin    # 必须两者都存在

# 单命令运行：串口输出实时回显并落盘 run.log（默认超时 45s）
tools/run_qemu.sh 45
```

不想用脚本的话，手工等价命令如下（核心特征：**不带 efuse `-global` 行**，理由见「已知边界」）：

```bash
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 45 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth \
  -nographic -no-reboot 2>&1 | tee run.log
```

结束方式：固件打完 30s 统计窗后进入空转保活（`while(1) vTaskDelay`），由外部 `timeout` 发 SIGTERM 截停——日志末尾出现 `terminating on signal 15 from pid ... (timeout)` 即为正常收场；脚本包装后退出码恒为 0。应用层若在 DHCP 阶段失败会打印 `$$$ EXFAIL reason=dhcp_timeout` 后主动返回。

一键核对（CI 化验证只需这一条 grep）：

```bash
grep -E 'EX01-FACT|ETH_EVENT (START|CONNECTED)|GOT_IP|\$\$\$ EXREADY|\$\$\$ EXDONE' run.log
```

## 真实输出摘录

以下逐行来自本目录入库的 `run.log`（真实运行，未做任何编辑；标注了行号便于对照）：

```text
run.log:56-69
I (1568) main_task: Calling app_main()
I (1568) ex01: == ex01 ethernet-dhcp: openeth bring-up baseline ==
I (1568) ex01: EX01-FACT build="Aug 27 2026 12:43:16" lwip_stats=1
...
I (1588) esp_eth.netif.netif_glue: ethernet attached to netif
I (1688) ex01: [t=163 ms] ETH_EVENT START
I (1688) ex01: waiting for DHCP lease ...
I (1688) ex01: [t=167 ms] ETH_EVENT CONNECTED (link up)
I (2698) ex01: [t=1173 ms] IP_EVENT GOT_IP: ip 10.0.2.15 nm 255.255.255.0 gw 10.0.2.2
I (2698) ex01: $$$ EXREADY ip=10.0.2.15 nm=255.255.255.0 gw=10.0.2.2 dns=10.0.2.3 mac=52:54:00:12:34:56 t_ms=1173
```

时间轴解读：驱动启动（163ms）到链路 up 只隔 **4ms**（虚拟 PHY 自协商瞬间完成），DHCP 全程约 **1s**。DNS 10.0.2.3 由 SLIRP 通过 DHCP option 下发，不是网关地址。

拿到 IP 后是 30 秒统计窗（每 5s 一个采样点）：

```text
run.log:70-77
I (7698) ex01: EX01-ST tick=1/6 up_s=6 ip=10.0.2.15 rx=2(+1) tx=2(+1) drop=+0 err=+0
I (12698) ex01: EX01-ST tick=2/6 up_s=11 ip=10.0.2.15 rx=3(+1) tx=3(+1) drop=+0 err=+0
I (17698) ex01: EX01-ST tick=3/6 up_s=16 ip=10.0.2.15 rx=3(+0) tx=3(+0) drop=+0 err=+0
I (22698) ex01: EX01-ST tick=4/6 up_s=21 ip=10.0.2.15 rx=3(+0) tx=3(+0) drop=+0 err=+0
I (27698) ex01: EX01-ST tick=5/6 up_s=26 ip=10.0.2.15 rx=3(+0) tx=3(+0) drop=+0 err=+0
I (32698) ex01: EX01-ST tick=6/6 up_s=31 ip=10.0.2.15 rx=3(+0) tx=3(+0) drop=+0 err=+0
I (32698) ex01: $$$ EXDONE stats_window_ms=30000 t_ms=31173
qemu-system-xtensa: terminating on signal 15 from pid 3811474 (timeout)
```

快照起点在 GOT_IP 之后，所以 DHCP 协商的十来个帧不在绝对值里；tick1/tick2 各有一对零星收发（IP 就位初期协议栈免费 ARP 类控制帧的尾巴），之后链路完全静默，增量为 `+0` 属正常观测——本示例刻意不造流量，这是"空载基线"。

## 机器可读标记一览

| 标记                          | 含义                                           |
| ----------------------------- | ---------------------------------------------- |
| `EX01-FACT build="..."`       | 固件编译指纹，用于核对 QEMU 加载的不是旧镜像   |
| `$$$ EXREADY ip=... t_ms=`    | 起播成功门信号：含 ip/nm/gw/dns/MAC 与到达时刻 |
| `$$$ EXFAIL reason=...`       | 失败门信号（当前仅 dhcp_timeout 一种）         |
| `EX01-ST tick=n/N ...`        | 周期统计行：链路收发计数绝对值与（+增量）      |
| `$$$ EXDONE stats_window_ms=` | 统计窗收口                                     |

## 如何读 EX01-ST 的数字

依赖 `sdkconfig.defaults` 里的 **`CONFIG_LWIP_STATS=y`**（它同时使能 LINK_STATS）；删掉该开关重建后仍可运行，但统计段恒为零。

- `rx` / `tx`：链路层累计收/发包数，括号内为距上次采样的增量。统计读取经 `tcpip_callback()` 在 tcpip_thread 内完成拷贝，避免裸读共享结构的竞态示范缺位。
- `drop`：链路层丢弃（openeth RX 描述符环满时的第一受害者，洪峰实验会看到这里爬升）。
- `err`：三个协议栈侧错误之和（校验和错 + 长度错 + 内存不足）的增量聚合。

## 已知边界与排障

以下均为本机实测特性，**不要把它们当故障**：

1. **MAC filter ioctl 错误 ×3 是预期噪音**。启动阶段固定刷出：

   ```text
   E (1688) esp_eth: esp_eth_ioctl(533): add mac address to filter not supported
   E (1688) esp_eth.netif.netif_glue: eth_set_mac_filter(56): failed to add mac filter
   E (1688) esp_netif_lwip: Failed to add multicast filter for IPv4
   ```

   这是 openeth 的已知白名单噪音（CONVENTIONS Batch 1 / C-05），不影响收发。

2. **虚拟网卡 MAC 固定** `52:54:00:12:34:56`，不是随机分配。
3. **SLIRP 地址面**：guest 恒得 `10.0.2.15/24`，网关/DHCP 服务器 `10.0.2.2`，DNS `10.0.2.3`。
4. **efuse `-global` 行陷阱**：若给 QEMU 命令手工加回 `-global driver=nvram.esp32.efuse,...` 一行，在本机偶发导致 openeth NIC 未创建，固件将在 `esp_eth_mac_new_openeth()` 里崩溃复位。套件所有 runner 已统一去掉该行；遇到 NIC 未创建先查这里。
5. **主机→guest 无路可达**：本示例 guest 上没有任何监听服务；即便有，SLIRP 下主机访问 guest 只有 hostfwd 一条路，且宿主 `ping 10.0.2.15` 恒不通（SLIRP 不支持主机→guest 方向 ICMP）。
6. **改过 `sdkconfig.defaults` 必须删除生成的 `sdkconfig` 再重新构建**，否则配置不生效（曾踩坑项）。
7. **亚毫秒/毫秒级时间戳**不得基于 `sys_now()`（10ms tick 网格），本示例统一走 `esp_timer_get_time()`。

## 文件结构

| 文件                  | 作用                                                                      |
| --------------------- | ------------------------------------------------------------------------- |
| `main/main.c`         | bring-up 序列 + 事件打印 + READY 门信号 + 统计采样循环（全部逻辑）        |
| `main/CMakeLists.txt` | main 组件声明：`PRIV_REQUIRES esp_eth esp_netif esp_event lwip esp_timer` |
| `CMakeLists.txt`      | root 构建骨架（`MINIMAL_BUILD ON` trim 形态）                             |
| `sdkconfig.defaults`  | 最小集：`CONFIG_ETH_USE_OPENETH=y` + 观测叠加 `CONFIG_LWIP_STATS=y`       |
| `tools/run_qemu.sh`   | 标准 QEMU 启动器（timeout + tee run.log，无 efuse 行、无 hostfwd）        |
| `run.log`             | 真实运行留存（本文摘录的出处）                                            |
