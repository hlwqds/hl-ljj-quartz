---
title: "Zig × ESP32-S31 全栈开发（二十五）：Wi-Fi blob 边界与 ABI 垫片"
date: 2026-12-04 18:00:00
description: "把「全 Zig 卡在 Wi-Fi」这件事拆成可测的形状：用 nm 量出 libnet80211/libpp/libcore 三份预编译归档（S31 Wi-Fi 的 7 份里承载 MAC/PP 的 3 份）的导出与未定义符号，找到它们真正的对外通道（ROM 的 g_osi_funcs_p 与 128 项 OSI 函数表），再在不链接任何 blob 的前提下，把这段边界写成有版本号、有长度校验、有上行队列、有错误码映射的 ABI 契约，并用模拟 blob 在主机与 rv32 上把每一条分支跑通。"
tags: [zig, esp32-s31, riscv, wifi, blob, abi, osi-funcs, freertos, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 上一章：[[ch24-mqtt-ota-application-protocols|第二十四章：MQTT 与 OTA]]
>
> **本章：第二十五章：Wi-Fi blob 边界与 ABI 垫片**
>
> 下一章：Wi-Fi 连接管理（规划中，尚无链接）

# Zig × ESP32-S31 全栈开发（二十五）：Wi-Fi blob 边界与 ABI 垫片

到 ch24 为止，这个系列已经能自己写出以太网 MAC（ch17）、IPv4/ICMP/ARP
（ch18）、UDP/DHCP/DNS（ch19）、TCP 状态机与拥塞控制（ch20/ch21）、
socket 与事件循环（ch22）、TLS 记录层与 HTTP/1.1（ch23）、MQTT 与 OTA
的编码（ch24）。这些章节有一个共同点：**协议是我们自己写的，所以边界
也是我们定的。**

Wi-Fi 不一样。S31 的 Wi-Fi 驱动由 **7 份预编译归档**组成（IDF
`components/esp_wifi/CMakeLists.txt:106` 的 `set(blobs core espnow mesh net80211 pp smartconfig wapi)`），
而本章只取其中承载 802.11 MAC / PP 的 3 份做 `nm` 取证（另用 `esp_coex` 的
`libcoexist.a` 作对照）：

```text
components/esp_wifi/lib/esp32s31/
    libnet80211.a   1 815 340 B   50 个成员
    libpp.a           943 030 B   54 个成员
    libcore.a           4 102 B    1 个成员
```

本章正面回答一个问题：**「全 Zig」卡在这里，卡的到底是什么？** 答案不是
「没有源码」这么含糊，而是三段可以逐一测量的东西：

1. blob 对外**导出**什么（1467 + 1227 + 4 个 `T`，见 25.2）；
2. blob 对外**要求**什么（1913 个不同的未定义符号，其中 39 个连 ROM 和所有
   S31 预编译归档都不提供，必须由 C 胶水补上，见 25.2 与
   `practice/zig-esp32-s31/ch25-wifi-blob-boundary/inventory.txt`）；
3. blob 通过什么**通道**提要求（不是直接调 FreeRTOS，而是走 ROM 数据符号
   `g_osi_funcs_p` 指向的一张 OSI 函数表：头文件里 128 行函数指针声明，
   S31 有效配置 126 个，见 25.1.3）。

测清楚之后，本章做一个刻意的选择：**不链接 blob**，只把「边界」写成一份
可编译、可断言、可在板子上跑的 ABI 契约，再用一个模拟 blob 把垫片的每条
分支跑通。真实的链接、真实的连接，留给 ch17 闭环之后的后续章节——
判据写在 25.12。

> [!warning] 本章的证据边界（重要）
>
> ch17 的以太网驱动**仍未闭环**（DMA 软复位超时、MDIO 扫不到 PHY、TX 超时，
> 见 `practice/zig-esp32-s31/logs/ch17d-boot.log`），板卡也没有可用的 Wi-Fi
> 连接路径。因此本章**不可能、也不允许**给出下面任何一条结论：
>
> - ✗「板子连上了 Wi-Fi」
> - ✗「扫描到了 N 个 AP」
> - ✗「blob 已经链接进固件」
> - ✗「`esp_wifi_init` 返回 ESP_OK」
> - ✗「事件来自真实射频」
>
> 本章的证据只有三种来源，缺一不可：
>
> 1. **`nm` 实测**（`tools/symbols.sh`）：每个符号数都能重跑复现；
> 2. **主机侧单测**（`zig build test`，15 个用例）：ABI 布局、注册表、
>    队列、错误码、生命周期、分配会计；
> 3. **板侧自检**（`practice/zig-esp32-s31/logs/ch25-boot.log`）：
>    `checks: passed=13 failed=0 total=13` 与 `main: verdict=pass`。
>
> 板侧跑的是**模拟 blob**（`src/stub_blob.zig`），它的入口表、版本字段、
> 错误码形状都是真的，内部一行 802.11 都没有。日志里没有「连接」，
> 因为确实没有发生连接。

## 25.1 「全 Zig」到底卡在哪

### 25.1.1 三份归档，三种不同的东西

三份 blob 不是同一类东西，混在一起谈「Wi-Fi 没源码」会掩盖真正的分工：

| 归档            | 成员 | 已定义符号 | 它是什么                                             |
| --------------- | ---: | ---------: | ---------------------------------------------------- |
| `libnet80211.a` |   50 |       1806 | 802.11 状态机：扫描/认证/关联/加密/省电/TWT/mesh/NAN |
| `libpp.a`       |   54 |       1381 | 包处理与 PHY 侧调度：TX/RX 管线、聚合、速率控制、TSF |
| `libcore.a`     |    1 |          7 | 一个成员 `misc_nvs.o`：把 blob 的 NVS 句柄接进调用方 |

（数字来自 `sh tools/symbols.sh` 的第 1、2 节；`defined_total` 含 `t`/`W`
等局部与弱符号，下面会拆开。）

`libcore.a` 只有 4 KB 却最能说明问题：它只有一个目标文件、7 个符号，
其中 5 个是未定义：

```text
$NM -u libcore.a
misc_nvs.o:
         U g_misc_nvs
         U g_osi_funcs_p
         U g_wifi_menuconfig
         U memset
         U wifi_log
```

这不是「一堆加密算法」的问题。这是**胶水**：blob 需要调用方给它一个
NVS 句柄、一个 OS 抽象表指针、一份 menuconfig 快照、一个日志函数。
`memset` 来自 libc，剩下四个全部来自调用方。

### 25.1.2 真正的问题：blob 要求调用方提供一整套 OS

把 1913 个未定义符号按形态分类（`inventory.txt` 第 6 节），net80211 侧是：

```text
lib=libnet80211.a unique=1147
  ieee80211_*=208      ← 同库/跨库内部引用（net80211 内部、以及 pp 提供）
  hal_*=47             ← PHY/硬件抽象层（由 libpp.a 或 ROM 提供）
  pm_*=51              ← 电源管理（ROM 的 pm_* 与 IDF 的 esp_pm）
  pp_*=3               ← 跨到 libpp.a
  g_globals=48         ← 全局数据锚点（多数是 ROM 数据段里的指针）
  compiler_rt(__*)=22  ← 软件浮点/64 位除法等
  libc_candidates=10   ← memcpy/memset…
```

pp 侧更极端：`hal_*=136`、`pm_*=143`。这不是「写个 WiFi 驱动」的量级，
而是「重建一整套 HAL + 电源管理 + 定时器 + 中断分配 + 内存分配」的量级。
本章不去重建它——但必须知道它的形状，否则垫片无从下手。

### 25.1.3 blob 不是直接调 FreeRTOS 的：它走 ROM 里的一张函数表

最容易误解的一点是「blob 直接调 `xQueueSend`」。用 `nm -u` 查一下就知道
不是：

```text
$NM -u libnet80211.a | grep -E '$Queue|$Task|^port' | wc -l
0
```

三份库里没有一个 `xQueue*` / `vTask*` / `port*` 未定义符号。它们全部通过
**一个函数指针表**间接调用。入口是 ROM 里的一个数据符号：

```text
$ grep -n g_osi_funcs_p ~/esp/esp-idf/components/esp_rom/esp32s31/ld/*.ld
esp32s31.rom.pp.ld:340:g_osi_funcs_p = 0x2f07ff44;
```

`0x2f07ff44` 在 SRAM 顶端（应用可用到 `0x2F07AFC0`，这一段是 ROM 给自己
留的全局区）。blob 读这个指针，得到 `wifi_osi_funcs_t`，然后按下标调用：

```c
// components/esp_wifi/include/esp_private/wifi_os_adapter.h:29
typedef struct wifi_osi_funcs_t {
    int32_t _version;                                        // :30
    ...
    bool (* _is_from_isr)(void);                             // :37
    ...
    int32_t (* _queue_send_from_isr)(void *queue, void *item, void *hptw);  // :56
    ...
    void *(* _malloc)(size_t size);                          // :73
    void (* _free)(void *p);                                 // :74
    ...
    int32_t _magic;                                          // :171
} wifi_osi_funcs_t;                                          // :172
```

这张表在头文件里共声明 **128 行函数指针字段**（`sed -n '29,172p' ... | grep -cE '\(\*'` →
128）。但其中两行是 ESP32 专有：

```c
#if CONFIG_IDF_TARGET_ESP32 || CONFIG_IDF_TARGET_ESP32S2 || CONFIG_ESP_WIFI_TARGET_ESP32
    void (* _phy_common_clock_enable)(void);    // :85
    void (* _phy_common_clock_disable)(void);   // :86
#endif
```

S31 不编译这两行，所以**有效配置是 126 个函数指针**；再加
`_version`（`:30`）与 `_magic`（`:171`）两个标量，恰好 128 个成员。
下文凡是说“要填多少项”，一律指 **126**（S31 有效）；“头文件声明多少行”
才是 128。调用方要把这 126 项填满，再让 `g_osi_funcs_p` 指过去：

```c
// components/esp_wifi/esp32s31/esp_adapter.c:699
wifi_osi_funcs_t g_wifi_osi_funcs = {
    ._version = ESP_WIFI_OS_ADAPTER_VERSION,   // 0x00000009，见头文件 :20
    ._set_intr = set_intr_wrapper,
    ...
    ._malloc = malloc,                         // :743
};
// components/esp_wifi/include/esp_private/wifi_os_adapter.h:174
extern wifi_osi_funcs_t g_wifi_osi_funcs;
```

于是「边界」这句话有了具体所指：**它就是这张表，加上版本字段
（`_version`）与结尾的 `_magic`。** 本章的 `HostApi` 是它的最小可判定子集。

> [!note] 版本不是装饰
>
> 表里第一个字段是 `_version`，IDF 把它定义为 `0x00000009`
> （`wifi_os_adapter.h:20`）。此外 blob 里还导出了一个
> `D g_wifi_osi_funcs_md5`（`nm --defined-only libnet80211.a` 可见），
> 配套的检查函数是 `esp_wifi_internal_osi_funcs_md5_check()`
> （`components/esp_wifi/include/esp_private/wifi.h:647`，注释写明
> “used for internal CI version check”）。
>
> 也就是说：**连 Espressif 自己都不敢用「结构一致」来保证兼容，
> 而是用版本号 + 结构 MD5 双重校验。** 本章把这条经验照抄：版本不匹配
> 一律拒绝，且不猜布局（25.5）。

### 25.1.4 还有 39 个符号，连 ROM 都不提供

把 1913 个未定义符号依次扣掉「三份库内部互相满足」（1688）、
「ROM 链接脚本提供」（473），再扣掉「其它 S31 预编译归档能提供」的部分，
剩下 39 个（`inventory.txt` 第 3、5 节）：

```text
left_for_idf_c_glue_and_newlib=39
```

它们分成三组：前两组能在 `esp_wifi` 组件自己的 C 源码里找到出处；第三组大部分属工具链
（newlib / compiler-rt），另有一个 `hexstr2bin` 在 IDF 的 `wpa_supplicant` 组件里
（`components/wpa_supplicant/src/utils/common.c:80`）：

| 组        | 符号                                                                                                  | 提供者                                                                                                                              |
| --------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 打印      | `pp_printf`、`net80211_printf`                                                                        | `components/esp_wifi/src/lib_printf.c:45`、`:72`                                                                                    |
| 监管/校准 | `regdomain_table`、`regulatory_data`、`est_PHY_*`（24 个）                                            | `regulatory/esp_wifi_regulatory.c:93`、`:280`；`src/ftm_load_calibration.c:15`                                                      |
| 事件/libc | `WIFI_EVENT`、`free`/`sprintf`/`strtok`/`puts`/`putchar`/`ceil`/`floor`、`__fixunsdfdi`、`hexstr2bin` | `src/wifi_init.c:59`（`ESP_EVENT_DEFINE_BASE(WIFI_EVENT)`）、newlib、compiler-rt、`components/wpa_supplicant/src/utils/common.c:80` |

（`esp_test_tx_duration` 在 IDF 的 `.c/.h` 里 `grep` 不到定义，本机没法给它
定位；本章不猜，把它记成「未定位」，见 `inventory.txt` 第 5 节原文。）

这就是「全 Zig」真正的成本清单：不是重写 802.11（那是几十万行），而是
**重写这几百个胶水 + 一张 126 项的表 + 版本/MD5 约定**。本章只做最后那一项，
并且做到可以验证。

## 25.2 blob 的实测事实

本节所有数字都由一条命令产出，输出确定（排序 + 去重）：

```bash
sh tools/symbols.sh              # 打印
sh tools/symbols.sh > inventory.txt
```

脚本只读本机 IDF 归档，可以覆盖 `IDF_PATH` / `NM` / `RISCV_NM`。
本机用的是 `riscv32-esp-elf-nm` 2.45（`esp-15.2.0_20251204`）。

### 25.2.1 归档元数据（`inventory.txt` 第 1 节，原文）

```text
lib=libnet80211.a bytes=1815340 members=50 stripped_members=7 sha256_16=bb011bf4e8125426
lib=libpp.a bytes=943030 members=54 stripped_members=17 sha256_16=1fe72c9b13813c30
lib=libcore.a bytes=4102 members=1 stripped_members=0 sha256_16=649dac152b6aa6a0
lib=libcoexist.a bytes=103760 members=11 stripped_members=2 sha256_16=9b8f55b1a1670ac8
```

`stripped_members` 是「`nm` 报 `no symbols` 的成员数」：net80211 有 7 个、
pp 有 17 个。也就是说**这些归档不是完整可读的**——一部分目标文件连符号表
都被剥掉了。这一条决定了本章的取证方式：只能看**导出与引用**，不能看实现。

### 25.2.2 已定义符号（`inventory.txt` 第 2 节，原文节选）

```text
lib=libnet80211.a defined_total=1806
  B=82     R=7      T=1467   W=33     t=177
  D=41
lib=libpp.a defined_total=1381
  B=40     R=8      T=1227   W=15     t=45
  D=44     b=1      r=1
lib=libcore.a defined_total=7
  B=2      D=1      T=4
```

怎么读这几行：

- `T`（text，全局函数）是主体：1467 / 1227 / 4。它们之中有相当一部分是
  `esp_wifi_*_internal` 这类**只给 IDF 内部用、但对外可见**的入口
  （`inventory.txt` 第 8 节能列出 20 个）；
- `D`/`B`（已初始化/未初始化全局数据）共 41+82（net80211）、44+40（pp），
  这些是 blob 的全局状态——**它们决定了 blob 只能被初始化一次**，
  也解释了为什么 25.7 的注册表要拒绝重复注册；
- `t`（局部函数）说明符号表**部分保留**：net80211 里 177 个、pp 里 45 个；
- `W`（weak）33 / 15 个，是 LTO 之后的弱定义，链接时可能被调用方覆盖。

### 25.2.3 未定义符号与提供者归属（`inventory.txt` 第 3 节，原文）

```text
unique_undefined_all=1913
provided_by_same_set_libs=1688
provided_by_rom_linker_scripts=473
found_in_any_s31_archive_overlapping=1715
left_for_idf_c_glue_and_newlib=39
```

前三行是**重叠计数**（同一个符号可能既在 ROM ld 里、又被别的归档导出），
最后一行才是互斥的剩余集合。这个 39 就是 25.1.4 的那张表。

### 25.2.4 未定义符号的形态（`inventory.txt` 第 6 节，原文）

```text
lib=libnet80211.a unique=1147
  ieee80211_*=208   hal_*=47   pm_*=51   pp_*=3
  g_globals=48      compiler_rt(__*)=22   libc_candidates=10
lib=libpp.a unique=867
  ieee80211_*=6     hal_*=136  pm_*=143  pp_*=24
  g_globals=45      compiler_rt(__*)=15   libc_candidates=4
lib=libcore.a unique=5
  g_globals=3       libc_candidates=1
```

这张表可以读出一件很重要的事：**三份库的「外向需求」不是均匀分布的。**
net80211 主要要「协议内部互相调用」（`ieee80211_*` 208 个）+ 电源管理
（`pm_*` 51 个）；pp 主要要 HAL（`hal_*` 136 个）与电源（`pm_*` 143 个）。
`compiler_rt` 那 37 个（22+15）说明 blob 里有软浮点/64 位除法——调用方
必须链接 compiler-rt，否则链接期就会缺符号。

### 25.2.5 结构性依赖：三个可以验的结论

把上面的读数收敛成三句话，本章的工程就围绕这三句展开：

1. **blob 的对外公共面是函数表，不是 FreeRTOS 头文件。**
   证据：`nm -u` 里 0 个 `xQueue*`/`vTask*`/`port*`；`g_osi_funcs_p` 在 ROM ld
   里是数据符号（`esp32s31.rom.pp.ld:340`）。
2. **blob 的版本兼容靠版本字段 + 结构 MD5，不靠“应该一样”。**
   证据：`wifi_os_adapter.h:20` 的 `ESP_WIFI_OS_ADAPTER_VERSION`、
   `:171` 的 `_magic`、`wifi.h:647` 的 md5 检查声明、
   `libnet80211.a` 导出的 `g_wifi_osi_funcs_md5`。
3. **blob 需要一小撮只存在于 C 侧的胶水与 newlib。**
   证据：39 个剩余符号里，**30 个能在 IDF 组件源码定位**（`esp_wifi/src` 的
   `lib_printf.c`、`wifi_init.c`、`ftm_load_calibration.c` 与 `regulatory/`，
   外加 `wpa_supplicant/src/utils/common.c:80` 的 `hexstr2bin`）、
   **8 个属工具链**（`free`/`sprintf`/`strtok`/`puts`/`putchar`/`ceil`/`floor` + `__fixunsdfdi`）、
   **1 个 `esp_test_tx_duration` 本机未定位**（见 25.1.4 表与 `inventory.txt` 第 5 节）。

## 25.3 三种策略：直链接、垫片、进程/核间拆分

知道边界之后，有且只有三条路。本章的选择是第二条，但代价表必须写全，
否则「为什么不用第一条」就只是偏好。

### 25.3.1 策略 A：直链接（lblob 直接进固件）

把**承载 MAC/PP 的 3 份 `.a` 连同 esp_wifi 的另外 4 份**（`espnow`/`mesh`/`wapi`/`smartconfig`，
再加 `esp_phy/libphy.a` 与 `esp_coex/libcoexist.a`）一起链进来，提供 ROM 地址、从其它
S31 归档取到的符号、以及 39 个纯胶水，让 `g_osi_funcs_p` 指向自己填的 126 项表（S31 有效配置）。
只链 3 份是不够的：`inventory.txt` 第 3 节的口径是 1913 个未定义符号里 1688 个由这 3 份
自己满足，剩下的 225 个 = **159 个 ROM + 27 个来自其它 S31 归档 + 39 个纯胶水**。

| 维度       | 代价                                                                                                                                                                          |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 链接       | 除这 3 份之外还要链 4 份 esp_wifi 归档 + `libphy.a`/`libcoexist.a`；要提供 159 个 ROM 地址、27 个由其它归档提供的符号、39 个纯胶水；缺一个就是链接错误，且错误名与 Wi-Fi 无关 |
| 初始化     | 要按 IDF 的顺序做：`esp_phy` 上电、NVS 初始化、`esp_event` 循环、`esp_timer`、`esp_pm` 锁                                                                                     |
| 内存       | blob 的 `D`/`B` 段（41+82、44+40 个符号）需要落位；本章 SRAM 只剩 `0x7AFC0` 给数据和栈                                                                                        |
| 中断       | 必须打开中断、分配 Wi-Fi 中断源——与本章「MIE=0、全轮询」的骨架直接冲突                                                                                                        |
| 可判定性   | 一旦跑起来，失败表现为「扫描不到 AP」；没有示波器/抓包时几乎无法归因                                                                                                          |
| 本章能做吗 | **不能**：ch17 的链路未闭环，板卡连接路径不成立；且直链接会把「边界」问题藏进链接错误里                                                                                       |

### 25.3.2 策略 B：垫片 + 边界（本章选择）

不链接 blob，只把边界写成契约：

- `blob_abi.zig`：`HostApi`（4 个入口）、`BlobVTable`（5 个入口）、`Event`、
  `Handle`、版本与长度字段；
- `adapter.zig`：注册表、上行队列、错误码映射、分配会计、`not_linked`；
- `stub_blob.zig`：模拟 blob，填满入口表并制造事件/错误；
- `selftest.zig` / `host_tests.zig`：主机 15 例 + 板侧 13 条判据。

| 维度     | 代价                                                                                               |
| -------- | -------------------------------------------------------------------------------------------------- |
| 真实性   | 没有真实射频、没有真实 blob；本章所有「事件」都来自 stub                                           |
| 收益     | 每一条分支都可判定（版本、长度、容量、队列满、注销、泄漏），失败点精确到 `check:` 行               |
| 迁移成本 | 真链接时要写一个 `real_blob.zig` 把 vtable 指到 blob 的入口，并填满 126 项 HostApi（S31 有效配置） |
| 内存     | `.bss` 实测 `0x3f0`（1008 B），不需要中断、不需要堆                                                |
| 风险     | 垫片与真实 blob 的行为差异（ISR 上下文、阻塞语义）必须靠接口文档与后续判据兜住                     |

### 25.3.3 策略 C：进程/核间拆分（blob 跑在另一个核或另一个 OS）

把 blob 塞进第二个核、或塞进一个「Wi-Fi 服务」里，用核间队列/IPI 通信。

| 维度     | 代价                                                                               |
| -------- | ---------------------------------------------------------------------------------- |
| 硬件     | S31 是双核，但 blob 的 ROM 依赖（`0x2f07ff44` 等）是**全局地址**，跨核共享要重定位 |
| 语义     | 事件要跨核搬运，`Event` 必须固定宽度（本章正好做成 20 字节，见 25.5）              |
| 调试     | 需要两侧日志对齐；本章连单核的事件顺序都还在用 tick 计量                           |
| 何时值得 | 当 blob 必须与 RTOS 共存、且主核要跑硬实时任务时；本章的骨架连调度器都没有，谈不上 |

### 25.3.4 为什么本章选 B

三个理由，按重要性排序：

1. **可判定**：B 的每条分支都能在板子上打印 `ok=1/0`，不需要射频、不需要 AP；
2. **不撒谎**：`linked_real_blob = false` 让「未链接」变成被测对象，而不是
   一句注释；
3. **可迁移**：`Event`/`Errno`/`HostApi` 的形状就是为了将来换成真实 blob 时
   **只改一处**（25.8.3）。

## 25.4 本章选择：边界 + 垫片

### 25.4.1 边界画在哪里

```text
    ┌───────────────────────────── 本工程（Zig，可判定） ─────────────────────────────┐
    │  selftest / main                                                                 │
    │      │                                                                           │
    │      ▼                                                                           │
    │  adapter.zig  ── register/attach/start/stop/deinit/deregister ──┐                │
    │      │   ▲                                                       │                │
    │      │   └──────────── HostApi（post/alloc/free/now_tick）────────┼──┐            │
    │      ▼                                                           │  │            │
    │  queue(8) → sink → 状态机                BlobVTable(init/start/stop/deinit/poll) │
    └──────────────────────────────────────────────────────────────────┼──┼────────────┘
                                                                       │  │
                        ┌──────────────────────────────────────────────┘  │
                        ▼                                                 ▼
                 stub_blob.zig（本章）                          real blob（未来，25.12）
```

边界的两侧各自只有一张表：

- 调用方 → blob：`BlobVTable`（5 个函数指针 + 版本 + 长度 + 名字）；
- blob → 调用方：`HostApi`（4 个函数指针 + 版本 + 长度 + 魔数）。

### 25.4.2 为什么边界要“薄而硬”

「薄」是指字段少：本章的 `HostApi` 只有 4 个入口，而 IDF 在 S31 上有 126 个函数指针。
少的好处是**能全测**：15 个主机用例 + 13 条板侧判据覆盖了它的每一条路径。

「硬」是指不可协商：`abi_version` 不等就拒绝（`.version_mismatch`），
`struct_size` 不等就拒绝（`.invalid_size`），`reserved` 非零就拒绝
（`.invalid_arg`）。判据 ③ 用三个改坏的 vtable 一次性验证这三条。

## 25.5 ABI 设计：vtable、版本、size/align、字节序

### 25.5.1 `Event`：20 字节的值类型

事件是跨边界的**唯一数据形状**，所以它必须满足三个条件：固定宽度、
无指针、无填充歧义。

```zig
// src/blob_abi.zig
pub const Event = extern struct {
    kind: u8,        // offset 0
    flags: u8,       // offset 1
    len: u16,        // offset 2   ← 小端
    seq: u32,        // offset 4
    payload: [12]u8, // offset 8
};
```

```text
offset  field    type   size
  0     kind     u8      1
  1     flags    u8      1
  2     len      u16     2
  4     seq      u32     4
  8     payload  [12]u8 12
------------------------------
        total    20 字节，4 字节对齐
```

20 字节不是随手选的：

- 它正好是 ch07 `TrapFrame`（80 字节）的四分之一，四个事件一屏日志能对齐；
- 12 字节 payload 够放 MAC(6) + 信道(1) + RSSI(1) + 一个 u32；
- 没有指针对齐问题：在 rv32 与 x86_64 上 `@sizeOf(Event)` 都是 20。

板侧读数（`logs/ch25-boot.log`）：

```text
read: sizes event=20 handle=4 vtable=44 hostapi=28 ptr=4
```

### 25.5.2 `Handle`：4 字节的不透明句柄

```zig
pub const Handle = extern struct {
    slot: u8,        // offset 0
    generation: u8,  // offset 1
    tag: u16,        // offset 2   ← 0x25A5
};
```

三段的用途各不相同：

| 字段         | 用途                                                                 |
| ------------ | -------------------------------------------------------------------- |
| `slot`       | 指向注册表下标（0..3），越界即拒绝                                   |
| `generation` | 每次回收 +1；**旧句柄因此指向“上一个生命周期”**，判据 ⑪ 靠它拒绝     |
| `tag`        | 0x25A5。句柄被 memcpy、被塞进 u32 之后，只有它还能证明「这是我们的」 |

### 25.5.3 `BlobVTable`：blob 的入口表

```zig
pub const BlobVTable = extern struct {
    abi_version: u32,   // offset 0   ← 必须 == 0x0001_0000
    struct_size: u16,   // offset 4   ← 必须 == @sizeOf(BlobVTable)
    reserved: u16,      // offset 6   ← 必须 == 0
    name: [16]u8,       // offset 8
    init: InitFn,       // offset 24
    start: StartFn,
    stop: StopFn,
    deinit: DeinitFn,
    poll: PollFn,
};
```

```text
offset  field        type      rv32   x86_64
  0     abi_version  u32        4       4
  4     struct_size  u16        2       2
  6     reserved     u16        2       2
  8     name         [16]u8    16      16
 24     init         ptr        4       8
 24+p   start        ptr        4       8
 24+2p  stop         ptr        4       8
 24+3p  deinit       ptr        4       8
 24+4p  poll         ptr        4       8
---------------------------------------------
        total                  44      64
```

**长度不是常数，而是 `24 + 5 × @sizeOf(usize)`。** 这条公式在
`comptime` 里用同一个表达式算出期望值，两侧各自断言：

```zig
fn expectedVTableSize(p: comptime_int) comptime_int {
    return 24 + 5 * p;
}

comptime {
    if (@offsetOf(BlobVTable, "init") != 24) @compileError("init 必须在偏移 24");
    if (@sizeOf(BlobVTable) != expectedVTableSize(ptr_size))
        @compileError("BlobVTable 长度必须是 24 + 5*sizeof(ptr)");
}
```

这就是「不手算常数」的意思：改一个字段，编译器告诉你哪条断言不成立，
而不是板子上读出一个错位的事件。

### 25.5.4 `HostApi`：调用方的能力表

```zig
pub const HostApi = extern struct {
    version: u32,      // 0
    struct_size: u32,  // 4
    post: PostFn,      // 8    blob → 调用方：上行事件
    alloc: AllocFn,    // 8+p
    free: FreeFn,      // 8+2p
    now_tick: TickFn,  // 8+3p
    magic: u32,        // 8+4p  ← 0x25A5_0001
};
```

rv32：`4 + 4 + 16 + 4 = 28`；x86_64：`8 + 32 + 4 = 44`，按 8 字节对齐变成
`48`。公式与对齐规则都写在 `expectedHostApiSize()` 里，板侧读数是
`hostapi=28`。

### 25.5.5 字节序：blob 眼里只有字节

Zig 的类型在跨语言边界上是**没有意义**的：对面拿到的是字节。所以本章把
事件头的编解码写成显式小端：

```zig
pub fn writeLe16(dst: *[2]u8, value: u16) void { ... }
pub fn writeLe32(dst: *[4]u8, value: u32) void { ... }
pub fn readLe16(src: *const [2]u8) u16 { ... }
pub fn readLe32(src: *const [4]u8) u32 { ... }

pub fn encodeEventHeader(ev: *const Event, dst: *[8]u8) void {
    dst[0] = ev.kind;
    dst[1] = ev.flags;
    writeLe16(dst[2..4], ev.len);
    writeLe32(dst[4..8], ev.seq);
}
```

判据 ② 用 `len = 0x0102`、`seq = 0x0403_0201` 验证字节序列是
`02 01` / `01 02 03 04`，并顺手断言 `@sizeOf(usize) == 4`、
`@bitSizeOf(usize) == 32`：

```text
check: abi width usize=4B le(u16=0x102 u32=0x4030201) roundtrip=1 ok=1
```

反过来说：如果哪天有人在事件结构里塞一个 `usize` 或一个 Zig `enum`，
这条判据会立刻变成 `ok=0`——因为 `enum` 的位宽是实现定义的，而 `usize`
在两侧不等宽。

### 25.5.6 为什么不用 `packed struct`

`packed struct` 在 Zig 里保证「无填充」，听起来更适合 ABI。但它会把每个
字段变成非对齐访问：rv32 上 `u32` 落在 2 字节边界时，一次读取会被拆成
两条指令（或者直接 trap，取决于目标是否允许非对齐访问）。本章的
`extern struct` + 显式断言达到了同样的布局确定性，却保留了自然对齐。

## 25.6 事件与错误码映射

### 25.6.1 事件通路

```text
blob 侧（stub_blob.zig）                    调用方侧（adapter.zig）
  pollFn(out)  ──写 Event──▶  pollEvent()  ──▶  drainBlob()
                                                   │
  startFn()  ──host.post(&ev)──▶  post()  ─────────┤
                                                   ▼
                                             queue_buf[8] （环形）
                                                   │
                                            dispatch() / pop()
                                                   ▼
                                               sink(ev)
```

两条上行路径都有，是因为真实 blob 两种都用：

- **异步回调**：连接完成这类事件在 `start` 返回之前就会投递
  （所以 `adapter.start` 先把状态置成 `.started` 再调 blob，失败回滚）；
- **轮询**：blob 内部有队列时，由调用方 `poll` 取。

判据 ⑥ 的顺序就是这条规则的可测形态：

```text
check: event order queued=5 delivered=5 seq=1..5 ordered=1 ok=1
```

### 25.6.2 队列满是一种背压，不是崩溃

环形队列容量 8。判据 ⑦ 让 stub 在启动时一次投 9 个：

```text
check: queue full capacity=8 queued=8 dropped=1 direct=no_space ok=1
```

第 9 个返回 `no_space`，`drop_count` 加一。**丢弃但不崩**是刻意的选择：
在真实 blob 里，事件丢弃比阻塞 blob 的调用栈安全得多（blob 可能正在
中断上下文里）。README 的待闭环项里因此留了「ISR 上下文的上行」一条。

### 25.6.3 错误码映射表

`esp_err_t` 是「0 = 成功，非 0 = 失败」，且多数失败是**正数**；本章的
`Errno` 是「0 = 成功，负数 = 失败」的 errno 风格。映射表如下（判据 ⑨
逐项对拍，共 10 项，含一个未知码）：

| `esp_err_t`             | 值       | 本章 `Errno`     | 语义                              |
| ----------------------- | -------- | ---------------- | --------------------------------- |
| `ESP_OK`                | `0`      | `.ok`            | 成功                              |
| `ESP_FAIL`              | `-1`     | `.fail`          | 通用失败                          |
| `ESP_ERR_NO_MEM`        | `0x101`  | `.no_mem`        | 内存不足                          |
| `ESP_ERR_INVALID_ARG`   | `0x102`  | `.invalid_arg`   | 参数错误                          |
| `ESP_ERR_INVALID_STATE` | `0x103`  | `.invalid_state` | 状态不允许（未 attach 就 start）  |
| `ESP_ERR_INVALID_SIZE`  | `0x104`  | `.invalid_size`  | 长度/结构不匹配                   |
| `ESP_ERR_NOT_SUPPORTED` | `0x106`  | `.not_supported` | 不支持                            |
| `ESP_ERR_TIMEOUT`       | `0x107`  | `.timeout`       | 超时                              |
| `ESP_ERR_WIFI_NOT_INIT` | `0x3001` | `.not_linked`    | **Wi-Fi 没被初始化 ≡ 本章未链接** |
| 其它                    | 任意     | `.fail`          | 未知码不猜                        |

最后一行是本章的关键设计：`ESP_ERR_WIFI_NOT_INIT` 是
`ESP_ERR_WIFI_BASE + 1`（`esp_wifi.h:63`，`ESP_ERR_WIFI_BASE = 0x3000`
见 `esp_err.h:39`），语义正是「驱动没装」。本章把「没有 blob」映射到同一个
语义位置，于是后续换成真实 blob 时，**调用方代码不需要改**
（判据 ⑩ 的期望从 `not_linked` 翻成 `ok` 即可）。

实现上要同时认两种输入：

```zig
pub fn errnoFromInt(rc: i32) abi.Errno {
    if (rc == 0) return .ok;
    if (rc > 0) return mapEsp(rc);              // ESP 正数错误码
    if (rc >= -13 and rc <= -1) return @enumFromInt(rc);  // 本章负数 errno
    return .fail;
}
```

`ESP_FAIL == -1` 与 `.fail == -1` 恰好同值，不冲突。

## 25.7 生命周期：注册、注销与泄漏

### 25.7.1 五步生命周期

```text
register  ──▶ attach  ──▶ start  ──▶ stop  ──▶ deinit  ──▶ deregister
  (登记)      (交表)      (启动)     (停止)     (释放)       (归还 slot)
```

每一步的拒绝条件都是显式的：

| 步骤         | 允许的前置 | 失败返回                                                                          |
| ------------ | ---------- | --------------------------------------------------------------------------------- |
| `register`   | 无         | `.version_mismatch` / `.invalid_size` / `.invalid_arg` / `.duplicate` / `.no_mem` |
| `attach`     | registered | `.invalid_state` / `.duplicate`（重复交表）/ `.no_mem`                            |
| `start`      | attached   | `.invalid_state`（未 attach）/ blob 的错误码                                      |
| `stop`       | started    | `.invalid_state`                                                                  |
| `deinit`     | attached   | `.invalid_state`                                                                  |
| `deregister` | registered | `.invalid_state`（还是 started）/ `.not_linked`（陈旧句柄）                       |

为什么把 `attach` 单独拆出来：`init` 需要传入 `HostApi`，而 `register`
时调用方还没准备好（真实 IDF 里也一样：先有 `wifi_init_config_t`，才有
`esp_wifi_init_internal(config)`，见 `wifi.h:437` 与 `wifi_init.c:471`）。
拆开之后，「注册但没交表」这个中间态可以被判据 ⑥ 直接测到：

```text
check: lifecycle start_before_attach=invalid_state attach=ok attach_again=duplicate init=1 ok=1
```

### 25.7.2 注销之后，旧句柄必须失效

注销做三件事：清 vtable、清 attached、`generation +%= 1`。第三件是关键：
旧句柄的 `generation` 与新值不同，`findSlot` 立刻拒绝。判据 ⑪：

```text
check: deregister batch=2 stop=ok dereg=ok stale=not_linked post=not_linked queued=0 ok=1
```

同一判据还验证了「注销之后 blob 再上行会被拒」——否则注销只是把调用方的
账本清零，blob 侧的回调还在往队列里塞事件。

### 25.7.3 泄漏检测：两本账

本章没有堆，`HostApi.alloc` 后面是 `.bss` 里 512 字节的 bump 池。每块前面
有 8 字节头：

```zig
pub const Header = extern struct {
    magic: u32,   // 0x25B10C4B
    len: u32,
};
```

`alloc` 写头、`free` 校验头并把 magic 清零。于是有两本账：

| 账       | 含义                                        | 判据 ⑫ 的读数                              |
| -------- | ------------------------------------------- | ------------------------------------------ |
| 分配会计 | `alloc_live` / `alloc_total` / `free_total` | `alloc_live=1->0 total=1 freed=1 errors=0` |
| 句柄会计 | `handlesOutstanding()` / `slotsFree()`      | `outstanding=0`，`slotsFree` 回到 4        |

重复释放不会静默通过：头里的 magic 已经是 0，第二次 `free` 记一次
`free_errors` 并返回。主机侧用例
`alloc accounting balances and double free is caught` 专门测这条。

**诚实说明**：bump 池没有回收路径，`free` 只是把会计减回去，内存要等
`reset()` 才真正复用。所以这里的「泄漏检测」看的是**会计是否平衡**，
不是水位——章节不把这一点说成内存管理。

### 25.7.4 并发假设

本章的骨架 `mstatus.MIE = 0`、没有中断、没有调度器。因此适配层**不加锁**，
所有函数都在同一个主循环上下文里调用。

唯一的例外是 `post()`：真实 blob 会从 Wi-Fi 任务甚至中断里回调它
（`wifi_os_adapter.h:37` 的 `_is_from_isr`、`:56` 的 `_queue_send_from_isr`
就是为这个存在）。所以 `post()` 的形状刻意做成单写者环形队列的 push：
只要外面包一层中断屏蔽，就能直接升级成 ISR-safe，不需要改数据结构。
这条假设写在 `adapter.zig` 的文件头，也写在 README 的待闭环项里。

## 25.8 最小可链接 demo 的验收途径

### 25.8.1 判据怎么排

13 条判据不是随便凑的，它们按「从静态到动态」的顺序排：

| #   | 判据                                    | 失败时说明什么                         |
| --- | --------------------------------------- | -------------------------------------- |
| ①   | ABI 布局（Event/Handle/VTable/HostApi） | 结构定义漂移，后面所有判据都无意义     |
| ②   | 宽度/字节序                             | 目标 ABI 不是 ilp32 或整数宽度假设错了 |
| ③   | 版本/长度/保留位拒绝                    | 兼容性检查没生效                       |
| ④   | 注册表容量（4 满，第 5 个 `no_mem`）    | 槽位计算错                             |
| ⑤   | 重复注册 → `duplicate`                  | 同一 blob 被初始化两次                 |
| ⑥   | 生命周期顺序（未 attach 不能 start）    | 状态机漏了一档                         |
| ⑦   | 事件顺序 1..5                           | 环形队列的 head/tail 写错              |
| ⑧   | 队列满 → `no_space` 且只丢 1 个         | 背压路径不计数                         |
| ⑨   | 错误码映射 10 项                        | ESP 与本章语义错位                     |
| ⑩   | 未链接 → 四种入口全 `not_linked`        | 垫片在撒谎（假装成功）                 |
| ⑪   | 注销后上行被拒、旧句柄失效              | generation 没自增                      |
| ⑫   | 泄漏：分配会计平衡、句柄归还            | init/deinit 不对称                     |
| ⑬   | 一帧闭包 = 2 逻辑 tick                  | 计时/派发的记账位置变了                |

### 25.8.2 判据 ⑬：为什么是「逻辑 tick」而不是「微秒」

本章没有可用的定时器（ch08 的 TIMG0 在别的工程里），也没有中断。要给出
「处理一帧事件要多久」这种读数，只有两种选择：编一个微秒数（不行），
或者定义清楚计时单位。

适配层里的 `tick` 是单调计数器：

- stub 的 `poll` 给事件打时间戳时调一次 `HostApi.now_tick()`（+1）；
- `dispatch` 每交付一个事件 +1。

于是「一帧事件的闭包」恒等于 2 个逻辑 tick：

```text
check: frame ticks=6 frames=3 per_frame=2 (logical, not wall clock) ok=1
```

这条判据的作用不是性能，而是**回归**：如果有人把 `now_tick` 从 `poll` 里
删掉，或者把 `dispatch` 的记账搬到 `pop` 外面，`per_frame` 就会变，
判据立刻 `ok=0`。章节里任何「耗时」的说法都必须带「逻辑 tick」这个定语。

### 25.8.3 将来换成真实 blob 要改哪里

未来接真实 blob 时，改动被限制在三个点：

1. `adapter.linked_real_blob = true`（判据 ⑩ 的期望自动翻转）；
2. 写一个 `real_blob.zig`：把 `BlobVTable` 的 5 个函数指针指到真实入口
   （`esp_wifi_init_internal` 等），`abi_version`/`struct_size` 填真实值；
3. 把 `HostApi` 从 4 项扩到 126 项（S31 有效配置），逐项接 FreeRTOS/esp_timer/esp_phy——
   **表结构本身不用改**，因为 `version` + `struct_size` + `magic` 已经在
   协议里（判据 ③ 会拒绝任何不匹配）。

这也解释了为什么本章要先把 `Event` 做成 20 字节的值类型：真实 blob 的
事件最终要跨上下文搬运，值类型比指针安全得多。

## 25.9 工程走读

### 25.9.1 浏览页深链表

| 文件                 | 在章节里的作用                                                  | 浏览器                                                                          |
| -------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `README.md`          | 工程根：验证状态、快速开始、符号取证用法、待闭环项              | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/README.md)          |
| `build.zig`          | 目标串、链接脚本、`zig build test`（15 例）                     | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界、6 条 ASSERT              | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t`（project_name = ch25…）+ naked `_start`        | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/start.zig)      |
| `src/main.zig`       | banner → 自检 → verdict → `wfi`                                 | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/main.zig)       |
| `src/blob_abi.zig`   | ABI v1.0 的全部结构、断言、小端编解码（25.5）                   | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/blob_abi.zig)   |
| `src/adapter.zig`    | 垫片：五步生命周期、环形队列、错误码映射、分配会计（25.6/25.7） | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/adapter.zig)    |
| `src/stub_blob.zig`  | 模拟 blob：入口表 + 错误注入 + poll 时间戳（25.8）              | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/stub_blob.zig)  |
| `src/selftest.zig`   | 板侧 13 条判据（25.10 的每一行都来自这里）                      | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/selftest.zig)   |
| `src/host_tests.zig` | 主机侧 15 个用例                                                | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/host_tests.zig) |
| `tools/symbols.sh`   | 符号取证（25.2 的每个数字）                                     | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/tools/symbols.sh)   |
| `tools/flash.sh`     | 按 `flash_args` 烧录，替换 factory 应用行                       | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/tools/flash.sh)     |

### 25.9.2 代码规模

| 文件                 | 行数 | 角色                          |
| -------------------- | ---: | ----------------------------- |
| `src/blob_abi.zig`   |  333 | ABI 契约 + 断言 + 编解码      |
| `src/adapter.zig`    |  464 | 垫片（注册表/队列/映射/会计） |
| `src/stub_blob.zig`  |  183 | 模拟 blob                     |
| `src/selftest.zig`   |  496 | 板侧 13 条判据                |
| `src/host_tests.zig` |  301 | 主机 15 例                    |

（行数以 `wc -l` 实际输出为准。）

### 25.9.3 `.bss` 花在哪里

`.bss` 实测 `0x3f0`（1008 B），四块：

| 对象           | 大小                     | 为什么必须在 `.bss`                    |
| -------------- | ------------------------ | -------------------------------------- |
| `slots[4]`     | 4 × `Slot`（约 12 B/个） | 注册表要跨函数调用存活                 |
| `queue_buf[8]` | 8 × 20 B = 160 B         | 环形队列；放栈上等于每层调用一份新队列 |
| `sink_buf[8]`  | 8 × 20 B = 160 B         | 判据 ⑦ 保存投递顺序                    |
| `pool[512]`    | 512 B                    | `HostApi.alloc` 的后备；无堆           |

主栈 16 KiB，`.bss` 1 KiB，中间是留给后续章节的 `_heap_start.._heap_end`。

## 25.10 上板自检输出

### 25.10.1 镜像

```text
$ env -u LD_LIBRARY_PATH $ZIG build -Dtarget=riscv32-freestanding-eabihf \
    -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
（退出 0，无输出）

$ python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
    --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
Creating ESP32-S31 image...
Merged 2 ELF sections.
Successfully created ESP32-S31 image.

$ python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin | grep 'DROM, IROM'
      0  0x02e80  0x40000020  0x00000018  DROM, IROM
      4  0x01048  0x40020020  0x00010018  DROM, IROM
```

正好两条 `DROM, IROM`：`0x40000020`（IROM，含 256 字节 `esp_app_desc_t`）
与 `0x40020020`（DROM）。本章没有 AES 软件查表，所以 `.rodata` 不需要
64 字节对齐，段起点就是 ORIGIN——这一点与 ch23 的 `0x40020040` 不同，
两条 ASSERT（`_rodata_start >= ORIGIN(drom)`、16 字节对齐）钉住了它。

`.section` 实测（`readelf -SW zig-out/bin/app.elf`）：

```text
[ 1] .flash.text    PROGBITS  40000020  002e80  AX  16
[ 2] .flash.rodata  PROGBITS  40020020  0007f0  AMS 16
[ 5] .trap_ram      PROGBITS  2f000000  00006c  AX  4
[ 6] .data          PROGBITS  2f000070  0000d0  WA  16
[ 7] .bss           NOBITS    2f000140  0003f0  WA  16
```

### 25.10.2 banner（日志前五行）

```text
ch25-wifi-blob-boundary | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: blob abi v1.0 + adapter shim + stub blob (13 checks)
note: no radio, no wifi link, no real blob linked - ch17 link pending
host: 15 unit tests via 'zig build test'
```

第一行就是工程身份。抓到别人的 banner 必须重烧重抓，不得改名。

### 25.10.3 十三条判据（`logs/ch25-boot.log` 原文）

```text
check: abi layout event=20 payload@8 handle=4 tag@2 vtable=44 hostapi=28 ok=1
check: abi width usize=4B le(u16=0x102 u32=0x4030201) roundtrip=1 ok=1
check: abi reject version=version_mismatch size=invalid_size reserved=invalid_arg slots_free=4 ok=1
check: registry capacity max=4 registered=4 fifth=no_mem free=0 ok=1
check: duplicate first=ok second=duplicate outstanding=1 ok=1
check: lifecycle start_before_attach=invalid_state attach=ok attach_again=duplicate init=1 ok=1
check: event order queued=5 delivered=5 seq=1..5 ordered=1 ok=1
check: queue full capacity=8 queued=8 dropped=1 direct=no_space ok=1
check: errno map cases=10 mismatched=0 esp_wifi_not_init(0x3001)=not_linked ok=1
check: not linked linked_real=0 real=not_linked start=not_linked poll=not_linked post=not_linked ok=1
check: deregister batch=2 stop=ok dereg=ok stale=not_linked post=not_linked queued=0 ok=1
check: leaks alloc_live=1->0 total=1 freed=1 errors=0 outstanding=0 ok=1
check: frame ticks=6 frames=3 per_frame=2 (logical, not wall clock) ok=1
```

### 25.10.4 读数与总结

```text
read: sizes event=20 handle=4 vtable=44 hostapi=28 ptr=4
read: counters post=3 drop=0 delivered=3 alloc=1/0 free_errors=0 tick=6
read: stub init=1 start=1 stop=0 deinit=0 poll=4 emitted=3
checks: passed=13 failed=0 total=13
main: verdict=pass, blob boundary verified with stub blob (wfi)
main: halting (wfi)
```

`read:` 三行不是判据，只是让日志能被人肉眼对拍：

- 第一行把四个结构的长度摊开（rv32：20 / 4 / 44 / 28，指针 4 字节）；
- 第二行是适配层的会计（3 次上行、0 次丢弃、3 次交付、1 次分配、0 次释放、
  6 个逻辑 tick）；
- 第三行是 stub 的入口调用计数（init 1、start 1、stop 0、deinit 0、poll 4、
  投递 3）。这是**最后一条判据 ⑬ 的快照**：它自己 `reset()` 之后只走了
  attach/start，没有 stop/deinit，所以这两个计数是 0；前面各条判据的计数器
  都被各自的 `reset()` 归零了，不是漏调用。

### 25.10.5 主机侧 15 例

```text
$ env -u LD_LIBRARY_PATH $ZIG build test --summary all
Build Summary: 3/3 steps succeeded; 15/15 tests passed
test success
+- run test 15 pass (15 total)
```

覆盖：ABI 布局、vtable/hostapi 长度公式、小端编解码、版本/长度/保留位拒绝、
注册表容量、重复注册、生命周期顺序、环形队列回绕、FIFO 投递顺序、队列背压、
错误码映射、未链接行为、注销语义、分配会计与重复释放、tick 计量。

## 25.11 决策记录（ADR-25）

### 25.11.1 上下文

- S31 的 Wi-Fi 由 7 份预编译归档组成（`esp_wifi/CMakeLists.txt:106`），本章只对
  承载 MAC/PP 的 3 份（`libnet80211`/`libpp`/`libcore`）做 `nm` 取证：1913 个未定义符号，
  其中 39 个必须由 C 胶水提供；
- blob 通过 ROM 数据符号 `g_osi_funcs_p`（`0x2f07ff44`）拿到 OSI 函数表
  （头文件 128 行声明，S31 有效 126 项），
  并用版本字段 + 结构 MD5 校验兼容性；
- 本章的骨架没有调度器、没有中断、没有堆，且 ch17 的链路未闭环。

### 25.11.2 选项

| 选项              | 结论                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| A 直链接          | 需要 7 份 Wi-Fi 归档 + `libphy`/`libcoexist`；159 个 ROM 地址 + 27 个跨归档符号 + 39 个纯胶水 + 126 项表 + 中断/PHY/NVS/PM；不可判定 |
| **B 边界 + 垫片** | **本章选择**：13 条判据 + 15 个主机用例，全部可复现                                                                                  |
| C 进程/核间拆分   | 需要调度器与跨核队列，本章骨架不具备；且 ROM 全局地址重定位未解决                                                                    |

### 25.11.3 决定

采用 B：交付 `blob_abi.zig`（契约）+ `adapter.zig`（垫片）+
`stub_blob.zig`（模拟 blob）+ 两侧判据。真实 blob 的链接推迟到 ch17 闭环后。

### 25.11.4 后果

正面：

- 每条分支都有 `check:` 行与主机用例，失败点精确到结构/字段/错误码；
- `not_linked` 成为被测行为，不再是一句注释；
- ABI 的版本/长度/魔数约定与 IDF 的 `_version`/`_magic`/md5 思路一致，
  将来接真实 blob 时迁移面被压到三个点（25.8.3）。

负面（必须记住）：

- 没有验证任何真实射频行为；「Wi-Fi 可用」这句话在本章完全不成立；
- `HostApi` 只有 4 项，真实需要 126 项（S31 有效），扩展时每一项都要重测；
- bump 池不回收内存，泄漏检测只覆盖会计；
- `post()` 的 ISR 安全性只是**形状上**成立，没有实测。

## 25.12 边界：真实 blob 链接与 Wi-Fi 连接待后续

本章明确不做的四件事，以及将来怎么验收：

### 25.12.1 真实 blob 链接

**做什么**：在 `zig build` 里把 `libnet80211.a` / `libpp.a` / `libcore.a`
连同 esp_wifi 另外 4 份归档一起链进固件，提供 159 个 ROM 地址（`esp32s31.rom.*.ld`）、
27 个来自其它 S31 归档的符号与 39 个纯胶水符号，
`HostApi` 扩到 126 项（S31 有效）。

**判据**：

1. `nm zig-out/bin/app.elf | grep ' U g_osi_funcs_p'` → 无输出（已解析）；
2. `elf2image` 仍打印 `Merged 2 ELF sections.`；
3. `image-info` 仍是两条 `DROM, IROM`；
4. 判据 ⑩ 的期望从 `not_linked` 翻成 `ok`（`linked_real_blob = true` 后
   自检会走到真实入口）；
5. `read: sizes` 行里的 `hostapi=` 从 28（本章的 4 项表）变成扩容后的表长
   （126 项函数指针 + 两个标量，按 `4+4+4p+4` 公式算出的值）。

### 25.12.2 `esp_wifi_init` 路径

**做什么**：按 IDF 顺序初始化（PHY 上电 → NVS → `esp_event` 循环 →
`esp_timer` → PM 锁 → `esp_wifi_init_internal`，见 `wifi_init.c` 的调用链）。

**判据**：`esp_wifi_init_internal` 返回 `0`；`read: counters post=` 出现真实
事件计数；`g_wifi_osi_funcs_md5` 的检查通过（否则会打印 md5 不匹配的错误码）。

### 25.12.3 Wi-Fi 连接

**做什么**：依赖 ch17 闭环（链路层与 TCP/IP 可用）。

**判据**：板侧事件队列里出现 `sta_connected`，且 `sink` 打印出真实 BSSID
（`Event.payload` 的前 6 字节）。在这之前，任何「连上了」的说法都是假的。

### 25.12.4 中断上下文的上行

**做什么**：给 `post()` 加中断屏蔽，让 blob 可以从 ISR 里投递。

**判据**：在 `mstatus.MIE = 1`、一个已知频率的定时器中断里反复 `post()`，
事件不丢、顺序不乱、`drop_count` 只在队列真满时增长。

## 事实来源

| #   | 事实                                                                | 来源（文件:行 / 命令）                                                                                                                                                                                                |
| --- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `libnet80211.a` 的归档大小/成员数/剥符号成员数                      | `sh tools/symbols.sh` 第 1 节（`wc -c`、`ar t`、`nm` 的 `no symbols` 计数）→ `inventory.txt`                                                                                                                          |
| 2   | `libnet80211.a` 已定义符号 1806（T=1467 D=41 B=82 R=7 W=33 t=177）  | `nm --defined-only libnet80211.a \| awk 'NF==3{print $2}' \| sort \| uniq -c`                                                                                                                                         |
| 3   | `libpp.a` 已定义符号 1381（T=1227 D=44 B=40 R=8 W=15 t=45 b=1 r=1） | 同上，归档换成 `libpp.a`                                                                                                                                                                                              |
| 4   | `libcore.a` 只有一个成员 `misc_nvs.o`，7 个已定义符号               | `ar t libcore.a`；`nm --defined-only libcore.a`                                                                                                                                                                       |
| 5   | 三库合计 1913 个不同未定义符号                                      | `nm -u <lib> \| awk 'NF==2 && $1=="U"{print $2}' \| sort -u`，再合并去重（`inventory.txt` 第 3 节）                                                                                                                   |
| 6   | 39 个符号连 ROM 与所有 S31 归档都不提供                             | `inventory.txt` 第 3、5 节（`comm -23` 求剩余集合）                                                                                                                                                                   |
| 7   | blob 不直接引用 FreeRTOS：`xQueue*`/`vTask*`/`port*` 的 U 计数为 0  | `nm -u libnet80211.a \| grep -cE '^(x\|v)Queue\|^(x\|v)Task\|^port'` → `0`                                                                                                                                            |
| 8   | blob 经 ROM 数据符号 `g_osi_funcs_p` 拿 OS 抽象表                   | `components/esp_rom/esp32s31/ld/esp32s31.rom.pp.ld:340`（`g_osi_funcs_p = 0x2f07ff44;`）                                                                                                                              |
| 9   | OS 抽象表结构 `wifi_osi_funcs_t` 的起止与版本字段                   | `components/esp_wifi/include/esp_private/wifi_os_adapter.h:29`（struct）、`:30`（`_version`）、`:171`（`_magic`）、`:172`（`}`）                                                                                      |
| 10  | 表的版本常数 `0x00000009`、魔数 `0xDEADBEAF`                        | 同文件 `:20`（`ESP_WIFI_OS_ADAPTER_VERSION`）、`:21`（`ESP_WIFI_OS_ADAPTER_MAGIC`）                                                                                                                                   |
| 11  | 表在头文件里声明 128 行函数指针，S31 有效 126 个                    | `sed -n '29,172p' wifi_os_adapter.h \| grep -cE '\(\*'` → `128`；`:85-86` 两项在 `#if CONFIG_IDF_TARGET_ESP32 …S2 … CONFIG_ESP_WIFI_TARGET_ESP32` 内，S31 不编译                                                      |
| 12  | ISR 相关入口在表里                                                  | 同文件 `:37`（`_is_from_isr`）、`:56`（`_queue_send_from_isr`）                                                                                                                                                       |
| 13  | `malloc`/`free` 也走表                                              | 同文件 `:73`、`:74`                                                                                                                                                                                                   |
| 14  | 调用方实现的表实例 `g_wifi_osi_funcs`                               | `components/esp_wifi/esp32s31/esp_adapter.c:699`（`. _version = ESP_WIFI_OS_ADAPTER_VERSION`）                                                                                                                        |
| 15  | blob 实现了 `esp_wifi_init_internal`，胶水调用它                    | `nm --defined-only libnet80211.a \| grep esp_wifi_init_internal` → `T`；声明在 `include/esp_private/wifi.h:437`；调用在 `src/wifi_init.c:471`                                                                         |
| 16  | 兼容性还有一道结构 MD5 校验                                         | `include/esp_private/wifi.h:647`（`esp_wifi_internal_osi_funcs_md5_check`）；blob 导出 `D g_wifi_osi_funcs_md5`                                                                                                       |
| 17  | 39 个胶水符号中的打印函数                                           | `components/esp_wifi/src/lib_printf.c:45`（`pp_printf`）、`:72`（`net80211_printf`）                                                                                                                                  |
| 18  | 监管数据表由 C 侧提供                                               | `components/esp_wifi/regulatory/esp_wifi_regulatory.c:93`（`regdomain_table[]`）、`:280`（`regulatory_data[]`）                                                                                                       |
| 19  | FTM 校准常数由 C 侧提供                                             | `components/esp_wifi/src/ftm_load_calibration.c:15`（`est_PHY_INIT_FTM_COMP_20_20D_MHZ`）                                                                                                                             |
| 20  | `WIFI_EVENT` 事件基由 C 侧定义                                      | `components/esp_wifi/src/wifi_init.c:59`（`ESP_EVENT_DEFINE_BASE(WIFI_EVENT)`）                                                                                                                                       |
| 21  | `esp_err_t` 通用码的数值                                            | `components/esp_common/include/esp_err.h:25`（`NO_MEM 0x101`）、`:26`（`INVALID_ARG 0x102`）、`:27`（`INVALID_STATE 0x103`）、`:28`（`INVALID_SIZE 0x104`）、`:30`（`NOT_SUPPORTED 0x106`）、`:31`（`TIMEOUT 0x107`） |
| 22  | `ESP_ERR_WIFI_BASE = 0x3000`，`NOT_INIT = +1`                       | `components/esp_common/include/esp_err.h:39`；`components/esp_wifi/include/esp_wifi.h:63`                                                                                                                             |
| 23  | 公共 API 形态（`esp_wifi_init` / `start` / `connect`）              | `components/esp_wifi/include/esp_wifi.h:388`、`:445`、`:495`                                                                                                                                                          |
| 24  | bootloader 的段地址同余检查                                         | `components/bootloader_support/src/esp_image_format.c:904`                                                                                                                                                            |
| 25  | 本工程 ABI 的期望值与实测                                           | `src/blob_abi.zig` 的 `expectedVTableSize`/`expectedHostApiSize`；板侧 `read: sizes … vtable=44 hostapi=28 ptr=4`                                                                                                     |
| 26  | `.bss` 实测 1008 B                                                  | `riscv32-esp-elf-readelf -SW zig-out/bin/app.elf`（`.bss` size `0x3f0`）                                                                                                                                              |

规范/文档条文（不是本机文件）：

| 资料                          | 用到的部分                                                        |
| ----------------------------- | ----------------------------------------------------------------- |
| ESP-IDF Wi-Fi 编程指南        | 「Wi-Fi 驱动初始化顺序」与 `wifi_init_config_t` 的字段语义        |
| `esp_wifi` 组件的 `linker.lf` | 段映射（`.wifi0iram` 等）与 `extram_bss` 方案，说明 blob 的段要求 |

## 自查清单

- [x] `sh tools/symbols.sh` 可重跑，输出确定（两次运行 `diff` 无差异）
- [x] 章节里引用的每个符号数/成员数都能用 `tools/symbols.sh` 复现
      （`inventory.txt` 第 1/2/3/5/6 节）
- [x] `zig build test --summary all` 退出 0，`15/15 tests passed`（主机 x86_64 / Zig 0.17.1）
- [x] 交叉编译退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 恰好两条 `DROM, IROM`：`0x40000020`、`0x40020020`
- [x] `flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'` 成功
- [x] 串口 banner 首行是 `ch25-wifi-blob-boundary | form B …`（确认不是同伴的镜像）
- [x] 13 条 `check:` 全 PASS，`checks: passed=13 failed=0 total=13`
- [x] `main: verdict=pass` 后停在 `wfi`
- [x] 本章引用的每一行 `check:` 都与 `logs/ch25-boot.log` 逐字一致
- [x] 没有任何「Wi-Fi 可用 / 连上 AP / blob 已链接」的结论
- [x] `linked_real_blob = false` 是判据 ⑩ 的被测对象，不是注释
- [x] 未修改索引、套件 README、BRINGUP 或任何既有章节工程
- [ ] 真实 blob 链接（判据见 25.12.1）
- [ ] `esp_wifi_init` 路径（判据见 25.12.2）
- [ ] Wi-Fi 连接（判据见 25.12.3）
- [ ] ISR 上下文的上行（判据见 25.12.4）

## 下一章预告

ch26 规划为 **Wi-Fi 连接管理**：把本章的 `Event`/`Errno`/注册表接到真实的
`esp_wifi` 状态机上——扫描结果、认证/关联、DHCP、断线重连与事件状态机。

它必须等两件事：

1. ch17 的链路闭环（没有它，连上了也拿不到 IP）；
2. 本章 25.12.1 的真实 blob 链接（没有它，事件来自 stub 而不是射频）。

ch26 的板侧纪律与本章一致：**能离线判定的做深（状态机迁移、重连退避、
事件顺序），必须联网的写判据、不写结论。**

> [!info] 系列导航
>
> 上一章：[[ch24-mqtt-ota-application-protocols|第二十四章：MQTT 与 OTA]]
>
> **本章：第二十五章：Wi-Fi blob 边界与 ABI 垫片**
>
> 下一章：Wi-Fi 连接管理（规划中）
>
> 系列索引：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]
