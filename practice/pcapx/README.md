# pcapx —— lwIP 可插拔抓包组件（S1 核心）

对任一 lwIP `netif` 做双向、链路层抓包，产出 Wireshark 可直接打开的标准 pcap（µs 魔数 `0xa1b2c3d4`、`LINKTYPE_ETHERNET`）。**零修改** lwIP/IDF 源码（见下方「零侵入性核查」）。

- 规格：`docs/spec/pcapx.md`（行为契约第 4 节）
- 冻结接口：`include/pcapx.h`
- 参考实现：[espressif/pcap](https://github.com/espressif/idf-extra-components/tree/master/pcap)（仅文件写入层，已实读对照其头部字节序与 flush 策略；本组件自写 24B 头，零依赖）

## 目录

```
pcapx/
├── include/pcapx.h          # 冻结契约（API/过滤器/sink vtable/统计）
├── src/pcapx_core.c         # S1：换装接入 + tap 拷贝路径 + SPSC 环 + writer 任务
├── src/pcapx_sink_semihost.c# S2：半托管 sink（QEMU -semihosting 直写宿主文件）
├── src/pcapx_sink_ram.c     # S2：RAM 暂存 sink（console 导出）
├── src/pcapx_sink_uart.c    # S2：UART 帧 sink（宿主收集脚本还原 pcap）
├── src/pcapx_console.c      # S2：esp_console 子命令
├── Kconfig                  # writer 优先级/栈/环容量默认值
└── CMakeLists.txt
```

S2 文件由并行切片落盘；本组件的构建在 S2 就位后由主会话统一执行。

## 集成

实验工程（如 `practice/lwip-pcapx-lab/`）顶层 `CMakeLists.txt` 加：

```cmake
set(EXTRA_COMPONENT_DIRS "${CMAKE_CURRENT_LIST_DIR}/../pcapx")
```

`main/CMakeLists.txt` 的 `PRIV_REQUIRES` 加 `pcapx`，源码 `#include "pcapx.h"`。

## API 用法

```c
#include "pcapx.h"

// sink 构造器由 S2 提供；返回对象所有权移交 pcapx
pcapx_sink_t *sink = pcapx_sink_semihost_new("/tmp/cap.pcap");

pcapx_config_t cfg = {
    .netif     = esp_netif_get_netif_impl(esp_netif), // 须已 up（netif_is_up）
    .direction = PCAPX_DIR_RX | PCAPX_DIR_TX,
    .snaplen   = 128,          // 每包最大捕获字节数，超出截断并计 truncated
    .filter    = { .ethertype = 0, .ip_proto = 17, .port = 0 }, // 全 0 = 抓全部
    .ring_bytes = 0,           // 0 → 用 CONFIG_PCAPX_RING_BYTES
    .sink      = sink,
};
esp_err_t err = pcapx_attach(&cfg);   // 成功后 wrap 常驻，原子 flag 门控捕获

pcapx_stats_t st;
pcapx_get_stats(&st);                 // rx/tx/filtered/dropped/truncated/written/ring_high_wm

pcapx_detach();                       // 排空 + sink close + 恢复原指针（建议链路静默期）
```

要点：

- **端口按网络序比较**（`filter.port` 与线上字节直接 `==`，命中 src 或 dst 任一）；`ethertype` 是主机序（`0x0800`/`0x0806`/`0x86dd`）。
- IPv6 不跟随扩展头；VLAN 帧在设置 `ip_proto`/`port` 过滤时判不匹配（non-goal，Wireshark 侧 display filter 可补）。
- `snaplen` 影响环内单帧占用（12B 元数据 + `min(tot_len, snaplen)`）；丢包实验把 ring 缩到 4KB + snaplen=64。

## Kconfig（menuconfig → pcapx）

| 选项                                     | 默认 | 说明                                                                                    |
| ---------------------------------------- | ---- | --------------------------------------------------------------------------------------- |
| `CONFIG_PCAPX_WRITER_PRIO`               | 17   | writer 任务优先级（介于 emac_rx=15 与 tcpip=18 之间，不抢网栈）                         |
| `CONFIG_PCAPX_WRITER_STACK`              | 4096 | writer 栈（字节），需容纳 sink 实现的栈深                                               |
| `CONFIG_PCAPX_RING_BYTES`                | 8192 | SPSC 环容量（字节），`ring_bytes=0` 时启用                                              |
| `CONFIG_PCAPX_SEMIHOST_SIMCALL_FALLBACK` | y    | QEMU 下 VFS semihost 不可用时退化为 raw SIMCALL 直连宿主文件（见下方「QEMU 直连模式」） |

### QEMU 直连模式（S3 集成实证，KD-9）

IDF 的 `esp_vfs_semihost_register()` 硬依赖 OpenOCD 式调试器 attach
（`esp_cpu_dbgr_is_attached()` 读 DSRSET bit0），Espressif QEMU 的 `-semihosting`
**不置该位**——VFS 路径在 QEMU 下必失败（`"OpenOCD is not connected!"`）。
QEMU 实际拦截的是 **SIMCALL 指令 + Xtensa ISS 调用号**（write=4/open=5/close=6/
lseek=19，a3..a6 传参、a2 返回、a3 errno；实现见 espressif/qemu
`target/xtensa/xtensa-semi.c`），与 OpenOCD 的 `break 1,14` + ARM 号约定是两条
不同通路（IDF `openocd_semihosting.h` 注释自证「not compatible with QEMU for
Xtensa」）。

fallback 行为：register 返回 `ESP_ERR_NOT_SUPPORTED` 时，sink 以 basename 直连
SIMCALL open/write/close（复刻 VFS 通路「剥挂载前缀」行为，文件落 QEMU 进程
cwd）。两个陷阱（都踩过）：

- **flags 位错位**：QEMU 把 flags 原样透传给宿主 `open()`，guest newlib 的
  `O_CREAT=0x200/O_TRUNC=0x400` 与宿主 Linux x86_64（`0x40/0x200`）不同源，
  必须用显式常数 `0x241`。
- **真机警告**：SIMCALL 是 ISS 专用指令，无 OpenOCD 的真机（ESP32 LX6）上执行
  即 illegal instruction——真机请 attach OpenOCD（VFS 路径）或改用 UART/RAM
  sink。RISC-V 构建自动编译掉 fallback。

## S3 集成缺陷修复记录（2026-08-27，lab 见 `../lwip-pcapx-lab/`）

1. **semihost sink QEMU 不可用**（现象/根因/修复见上节与 KD-9）：
   `pcapx_sink_semihost.c` 增加 SIMCALL fallback + Kconfig 开关。
2. **tap 写环偏移缺陷**（KD-10）：`pcapx_core.c` 帧数据直写环时
   `off = pos % ring_size` 漏加 `PCAPX_RING_PREFIX`，帧头 12B 覆盖时间戳元数据
   → writer 解析垃圾 caplen（≤65535）→ `s_tail` 越过 `s_head` → `used` 无符号
   下溢 → 后续帧按 64KB 长度越界写环踩堆。症状随机（TLSF assert /
   InstrFetchProhibited / Double exception），靠 tap/writer 双侧指纹日志定位
   （环首 12B 读出 `ffffffffffff 525400123456` = 帧头而非元数据）。修复一行：
   `off = (pos + PCAPX_RING_PREFIX) % s_ring_size`。

## 日志契约与分工（TAG 均为 `pcapx`）

| 行                                                                        | 谁打                 | 说明                                                                                                |
| ------------------------------------------------------------------------- | -------------------- | --------------------------------------------------------------------------------------------------- |
| `I pcapx: ATTACH netif=xx mode=rx+tx snap=N sink=<name>`                  | **core**             | `sink=` 取值 = `pcapx_sink_t.name`（S2 的 sink 应把完整身份编进 name，如 `semihost:/tmp/cap.pcap`） |
| `E pcapx: ATTACH_FAIL netif=xx reason=arg\|down\|busy\|sink_open\|no_mem` | **core**             | `no_mem` 为头文件枚举之外的小扩展（环/弹床/任务分配失败也要可 grep）                                |
| `E pcapx: SINK_OPEN_FAIL path=... hint='qemu 需追加 -semihosting'`        | **S2 semihost sink** | 修复提示属 sink 领域知识，core 只打上一行的 `reason=sink_open`                                      |
| `W pcapx: DROP cnt=N`                                                     | **core**             | tap 上下文唯一被豁免的打印：每聚合 32 次丢帧一条（计数为累计值）                                    |
| `I pcapx: DETACH netif=xx rx=N tx=N drop=N trunc=N`                       | **core**             | 会话总计，取自 detach 时的统计快照                                                                  |
| `W pcapx: SINK_WRITE err=0x.. sink=..`                                    | **core**（非契约行） | sink 中途写失败只报一次；后续帧照常出环丢弃，防环塞死                                               |

## 设计要点（为什么这样做）

- **换装指针而非编译期钩子**：唯一同时覆盖 RX+TX、链路层（含 ARP）、且运行时可插拔的接入点。attach 保存 `netif->input`/`netif->linkoutput` 原指针并替换为 wrap；wrap 常驻安装，捕获由原子 `s_enabled` 门控（不 attach 时 wrap 已装但 flag 关 → 直通近零开销）。capture 都发生在调用原函数**之前**（此刻 pbuf 仍归调用者所有）；`linkoutput` 返回值透传。
- **多生产者事实**：input wrap 跑在 eth RX 任务、linkoutput wrap 跑在 tcpip_thread，双核可并发。「SPSC 环」按单消费者理解；入环（含 ≤snaplen 的 memcpy）由一把 `portENTER_CRITICAL` 旋锁串行化，临界区有界。出环大拷贝在锁外——生产者永不触碰未消费区 `[tail, head)`。
- **丢新不丢旧**：保序、计数语义简单；被接受样本时间戳单调。
- **detach 的竞态收敛**：关 flag → 恢复指针 → 等 `inflight==0`（在飞 tap 的尾部有界）→ 停 writer（`run=false` + notify）→ 等排空完成信号量 → 回收。残余窗口（lwIP 内部缓存指针之类）不存在于现行路径，但契约仍建议链路静默期 detach。
- **writer 自删**：`vTaskDelete(NULL)` 只把 TCB 挂待回收链表、由 Idle 收尸（FreeRTOS 系列 ch5/ch9 语义）；give 完成信号量 → 清句柄 → 自删的顺序保证 detach 侧与后续 attach 都不引用死任务（详见 `src/pcapx_core.c` 中 `pcapx_task` 尾部注释）。

## 零侵入性核查步骤

```bash
# lwIP 与 IDF 源码零 diff（spec 第 4 节观察点）：
git -C ~/esp/esp-idf diff --stat    # 期望：空输出

# sdkconfig 不新增任何 LWIP_HOOK_* 宏（本组件不依赖编译期钩子）：
grep -E '^CONFIG_LWIP_HOOK' <lab>/sdkconfig | sort   # 与未引入 pcapx 的基线一致
```

## 复现环境

ESP-IDF v6.0.2 / lwIP 2.2.0-dev / FreeRTOS SMP（esp32, Xtensa LX6），QEMU `esp_develop_9.2.2_20250817` + openeth-SLIRP。见 `../lwip-labs/CONVENTIONS.md`。
