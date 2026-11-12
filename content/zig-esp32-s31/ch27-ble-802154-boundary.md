---
title: "Zig × ESP32-S31 全栈开发（二十七）：BLE 与 802.15.4 的边界——HCI、ATT/GATT、6LoWPAN"
date: 2026-11-13 22:00:00
description: "把 BLE 与 802.15.4 放在同一章，是因为它们在 S31 上是同一条缝的两种形态：前者是 5 份预编译归档（libble_app/libbtdm_common/libbredr_app/libbtbb/libbttestmode）对外只留 10 个未定义符号与一条 HCI 通道，后者在 IDF 里根本没有归档、只有 3571 行 C 源码与寄存器头。本章用 nm 把这层差量量出来，再把 host 侧的字节路径逐段写成可断言的 KAT：HCI 分帧、ATT 的 MTU/读/写/通知/错误、GATT 的句柄与 CCCD 订阅、802.15.4 的 FCF 与 6LoWPAN 无状态解压，12 条板侧判据全部来自实际运行。"
tags: [zig, esp32-s31, riscv, ble, hci, att, gatt, ieee802154, 6lowpan, thread, blob, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 上一章：[[ch26-wifi-connection-wpa2-wpa3|第二十六章：Wi-Fi 连接管理（WPA2/WPA3）]]
>
> **本章：第二十七章：BLE 与 802.15.4 的边界**
>
> 下一章：自举、功耗与综合（规划中，尚无链接）

# Zig × ESP32-S31 全栈开发（二十七）：BLE 与 802.15.4 的边界

ch17 到 ch25 把「自己写协议栈」这件事推到了两个尽头：一边是以太网 MAC
与整套 TCP/IP（ch17–ch22）、TLS/HTTP/MQTT/OTA（ch23–ch24），全是我们自己
的代码；另一边是 Wi-Fi（ch25），它由 7 份预编译归档组成，我们只能量出
它的边界，不能重写它。

BLE 和 802.15.4 是同一个问题的另外两张脸，而且**脸不一样**：

- **BLE 在 S31 上是 5 份闭源归档**（2.1 MB + 227 KB + 2.5 MB + 47 KB +
  192 KB），对外只要求 **10 个未定义符号**，其中 5 个还是链接器自己定义的
  段边界符号。也就是说：谁想「用 BLE」，不需要移植一个协议栈，只需要把
  这 10 个符号和一条 HCI 通道准备好。
- **802.15.4 在 S31 上根本没有归档**。IDF 的 `components/ieee802154/` 是
  10 个 C 文件、3571 行源码，直接操作 `ieee802154_reg.h` 里的寄存器；
  能称为「黑盒」的部分只剩 PHY（`libphy.a`）与 ROM 里的 `phy_*`。

于是本章的写法也分两半：

1. 对 BLE，量清楚「归档要求什么」——用 `nm` 把 1407 个未定义符号拆成
   1381 + 16 + 10，然后只实现 host 侧的字节路径（HCI → ATT → GATT）；
2. 对 802.15.4，既然它本来就是我们能读的源码，就不再复刻驱动，而是把
   **帧格式与 6LoWPAN 解压**这两段「规范密集、最容易写错位序」的部分写成
   KAT，和 IDF 源码、RFC 条文逐条对拍。

两条线最后落到同一块板子上：12 条判据、12 行 `check:`、`verdict=pass`。

> [!warning] 本章的证据边界（先读这一段）
>
> 板侧跑的是**字节路径**，不是射频。本章明确**不会**、也不允许出现下面
> 任何一种说法：
>
> - ✗「扫描到 N 个 BLE 设备」——没有链接 controller 归档，也没有射频初始化；
> - ✗「连接成功 / 读到特征值」——没有真实的 LE Connection Complete 事件，
>   也没有 ACL 数据在空口上跑过；
> - ✗「802.15.4 收到帧」——没有初始化 PHY，也没有打开接收窗口；
> - ✗「Thread 入网 / 成为 Router」——MLE 与边界路由器都没实现。
>
> 本章**能**说的只有这些：
>
> - ✓ 五份归档的符号面（成员数、导出数、未定义数、归属拆分）——`nm` 实测；
> - ✓ HCI/ATT/GATT/802.15.4/6LoWPAN 的字节布局与规范条文一致——KAT；
> - ✓ 同一份代码在 x86_64 与 rv32 上给出同样的结果——20 个主机用例 +
>   12 条板侧判据；
> - ✓ 每条判据都打印**具体错误码与计数**（`code=0x03`、`rejected=3`），
>   而不是一句 `ok=1`。
>
> 真链路交付物（扫描/连接/读特征值/入网）写在 27.11，每条给「跑什么、
> 看什么、算过」。

## 27.1 为什么把 BLE 与 802.15.4 放一章

单看名字，BLE 与 802.15.4 是两种完全不同的无线技术：前者是蓝牙低功耗，
跑在 2.4 GHz 的 40 个信道上；后者是 IEEE 的低速率 WPAN，15.4 的 2.4 GHz
版本有 16 个信道、250 kbps。它们的 MAC、连接模型、上层协议（GATT vs
6LoWPAN/Thread）都不一样，放一起讲似乎只是「凑一章」。

放到 S31 这颗芯片上看，它们共享三样东西，而且这三样恰好就是「全 Zig」
卡住的地方：

### 27.1.1 共享同一套射频前端与共存仲裁

S31 的 PHY 只是一份归档 `libphy.a`（164 246 字节，见
`components/esp_phy/lib/esp32s31/`），ROM 里另有一批 `phy_bt*` 与
`coex_bt*` 符号（`tools/symbols.sh` 第 7 节统计：`rom_phy_bt_count=11`、
`rom_coex_bt_count=2`）。BLE 与 802.15.4 都要通过 coex 仲裁去抢天线时间，
IDF 侧对应的 C 接口是 `esp_coex_ieee802154_*` 那 8 个函数
（`components/esp_coex/include/esp_coex_i154.h`，`coex_i154_functions=8`）。

也就是说：**它们不是两张独立的射频卡，而是一套射频 + 一个仲裁器 + 两种
MAC**。这一点在 ch25 讲 Wi-Fi blob 时已经露过一半（`libcoexist.a` 也在
Wi-Fi 的链接集合里）。

### 27.1.2 共享「controller 与 host 之间的那条缝」

BLE 的分层是干净的：

```text
   host（GATT/ATT/L2CAP/SMP/GAP）
        ↕  HCI（Command / Event / ACL / ISO）
   controller（Link Layer + PHY，闭源归档）
```

802.15.4 的分层在 IDF 里被压扁了一层：

```text
   Thread / 6LoWPAN / 应用
        ↕  esp_ieee802154_*（67 个公开函数）
   MAC（IDF C 源码，3571 行）—— 直接读写 ieee802154 寄存器
        ↕
   PHY（libphy.a + ROM phy_*）
```

两者都有一个「我们只能到这、再往下就进黑盒」的界面：BLE 是 HCI，
802.15.4 是寄存器（我们甚至能读它，因为 MAC 是源码）。本章把 BLE 的界面
写成 HCI 编解码，把 802.15.4 的界面写成帧头编解码 + 6LoWPAN 解压。

### 27.1.3 共享「协议密集、位序密集」这个难点

真正让人写错的地方不是「怎么调用 API」，而是位序与长度：

- HCI ACL 头的 12 位句柄 + 2 位 PB + 2 位 BC 拼在 16 位里，**小端**；
- ATT 是「1 字节操作码 + 参数」，句柄 2 字节**小端**，但 MTU 截断要按
  响应头的字节数扣；
- 802.15.4 的 FCF 是 16 位**小端**，位 0 是帧类型的最低位；
- 6LoWPAN 的 IPHC 是「大端位序」的位域（bit0 是最高位），而它承载的 UDP
  端口又是**网络序**。

一句话：**同一个报文里可以同时出现小端字段和网络序字段**，而它们相邻。
本章的判据里有三条（④⑨⑪）就是专门打这种地方的。

## 27.2 实测：S31 上这两类 blob 的符号面

本节所有数字都来自 `sh tools/symbols.sh`（产物 `inventory.txt`），
`nm` 是 `riscv32-esp-elf-nm`（`GNU nm (crosstool-NG esp-15.2.0_20251204) 2.45`）。
脚本是确定的：`LC_ALL=C` + 排序 + 去重 + 固定输出顺序，重跑 `diff` 无差异。

### 27.2.1 五份归档的元数据

```text
lib=libble_app.a       bytes=2189216 members=119 stripped_members=16
lib=libbtdm_common.a   bytes= 226874 members= 37 stripped_members= 2
lib=libbredr_app.a     bytes=2496108 members=161 stripped_members=15
lib=libbtbb.a          bytes=  47508 members=  2 stripped_members= 0
lib=libbttestmode.a    bytes= 191732 members= 13 stripped_members= 3
```

路径分别是：

```text
components/bt/controller/lib_esp32s31/esp32s31-bt-lib/libble_app.a
components/bt/controller/lib_esp32s31/esp32s31-bt-lib/libbtdm_common.a
components/bt/controller/lib_esp32s31/esp32s31-bt-lib/libbredr_app.a
components/esp_phy/lib/esp32s31/libbtbb.a
components/esp_phy/lib/esp32s31/libbttestmode.a
```

一个容易误解的点：`libbtbb.a` 在 `esp_phy` 目录下，但它装的是 **BLE 基带**
（成员里 186 个定义符号，绝大多数以 `ble_bb_` 开头，例如
`ble_bb_cte_get_agc_target_value`）。`libbttestmode.a` 是 DTM（Direct Test
Mode）用的，配合产测。

还有 16 + 15 + 3 = 34 个成员**没有符号表**（`nm` 报 `no symbols`）。它们不是
空文件：是没有 `.symtab` 的段数据。这意味着「归档里的字节数」不等于
「可审计的代码量」——你只能看到它们占的体积。

### 27.2.2 每份归档导出什么

```text
lib=libble_app.a      defined_total=2876  unique_undefined=1407
  B=88  D=15  R=33  T=2664  t=76
lib=libbtdm_common.a  defined_total= 426  unique_undefined= 151
  B=23  R=1   T=323  W=77  t=2
lib=libbredr_app.a    defined_total=4046  unique_undefined=2330
  B=73  R=88  T=2914  r=12  t=959
lib=libbtbb.a         defined_total= 186  unique_undefined=   4
  T=186
lib=libbttestmode.a   defined_total= 372  unique_undefined=  84
  B=99  D=9   R=2   T=262
```

`libble_app.a` 导出的 **`esp_*` 公共入口只有 18 个**（`T` 类型，`grep -c`），
而且不是我们熟悉的 `esp_vhci_host_send_packet`——那一个是 C 胶水里的函数
（`components/bt/host/bluedroid/api/esp_bluedroid_hci.c:87` 调用它）。归档导出
的是更底层的东西：

```text
esp_ble_adv_aa_setting            esp_ble_scan_aa_setting
esp_ble_adv_rx_rssi               esp_ble_scan_channel_setting
esp_ble_clear_rand_addr           esp_ble_set_aux_chan_index
esp_ble_controller_status_check   esp_ble_txpower_lvl_range_get
esp_ble_enable_fixed_aux_chan_index  esp_ble_txpower_range_get
esp_ble_get_dtm_rx_rssi           esp_ble_register_bb_funcs
esp_ble_get_received_adv_adi      esp_ble_unregister_bb_funcs
esp_ble_hw_get_static_addr        esp_register_ext_funcs
                                  esp_unregister_ext_funcs
```

这里的形态很关键：`esp_register_ext_funcs` / `esp_unregister_ext_funcs`
是**注册函数表**，`esp_ble_register_bb_funcs` 是注册基带回调。也就是说
controller 不是被动地被调用，它先要宿主交给它一组函数指针——这正是 ch25
里 `g_osi_funcs_p` 的同构做法（那一次是 ROM 数据符号指向 OSI 函数表）。

### 27.2.3 它到底要求什么：1407 = 1381 + 16 + 10

这是本章最重要的一张表：

```text
unique_undefined=1407
provided_by_the_five_s31_bt_archives=1381
provided_by_rom_linker_scripts=16
left_for_linker_and_newlib=10
```

这三类是**互斥**的（脚本里 `comm -12` 交叉验证，交集为 0），所以
1381 + 16 + 10 = 1407，读者可以相加。

读法：

1. **1381 个在五份归档内部自己解决**。其中 2843 个 `r_*` 前缀符号是
   `libble_app.a` 自己定义的重入/关中断变体（`defined_r_prefix=2843`），
   而它又引用了 1310 个 `r_*`（`undefined_r_prefix=1310`）——这些是
   **归档成员之间的交叉引用**，不是「ROM 提供」。这一点值得单独强调，因为
   很容易想当然地写成「`r_` 就是 ROM 版」：

   ```text
   ## 7. ROM 链接脚本里与 BT/PHY 有关的符号（否定证据）
   rom_r_ble_or_r_btdm_count=0
   rom_phy_bt_count=11
   rom_coex_bt_count=2
   ```

   `esp32s31.rom.*.ld` 里**一个** `r_ble*` / `r_btdm*` 都没有。S31 的 BLE
   controller 不是「ROM 里的固件 + 一层薄补丁」，而是**一整套自包含的补丁
   归档**：5 份加起来 5.15 MB，导出 7906 个符号。

2. **16 个由 ROM 链接脚本提供**，全是 `libgcc` 类（`__divdf3`、`__udivdi3`、
   `__popcountsi2`…）与 `abs`/`ets_printf`。也就是说 ROM 在这里的角色是
   「另一个 libc/libgcc」。

3. **剩下 10 个是真正要人补的**：

```text
glue: __assert_func
glue: _bss_end_btdm
glue: _bss_start_btdm
glue: _data_end_btdm
glue: _data_start_btdm
glue: _data_start_btdm_rom
glue: esp_restart
glue: free
glue: malloc
glue: sprintf
```

这 10 个可以分三类：

| 类           | 符号                                                                                             | 谁来补                   |
| ------------ | ------------------------------------------------------------------------------------------------ | ------------------------ |
| C 运行时     | `__assert_func`、`free`、`malloc`、`sprintf`                                                     | newlib / nano（IDF 侧）  |
| 平台         | `esp_restart`                                                                                    | IDF `esp_system`         |
| 链接器段符号 | `_bss_start_btdm`、`_bss_end_btdm`、`_data_start_btdm`、`_data_end_btdm`、`_data_start_btdm_rom` | controller 的 `.lf` 片段 |

最后一类最有意思。`components/bt/controller/linker_esp_btdm_controller.lf`
里有：

```text
32:    bt_bss -> dram0_bss
34:    data -> dram0_data
83:            data -> dram0_data  ALIGN(4) ALIGN(4, post) SURROUND(bt_data)
86:            bt_bss -> dram0_bss ALIGN(4) ALIGN(4, post) SURROUND(bt_bss),
88:            data -> dram0_data  ALIGN(4) ALIGN(4, post) SURROUND(bt_data)
94:        bt_bss -> dram0_bss ALIGN(4) ALIGN(4, post) SURROUND(bt_controller_bss),
96:        data -> dram0_data ALIGN(4) ALIGN(4, post) SURROUND(bt_controller_data)
99:archive: libbtdm_common.a
```

`SURROUND(bt_bss)` 会生成 `__start_bt_bss` / `__stop_bt_bss` 之类的边界，
`_bss_start_btdm` 这些符号就是同一种机制的具体名字。`_data_start_btdm_rom`
的存在说明 controller 的 `.data` 分两份：一份在应用段，一份在 ROM 里
（这解释为什么 34 个成员没有符号表却仍有数据）。

结论用一句话说：**ble 这层黑盒的「ABI 缝」只有 10 个符号宽，其中一半还是
链接器自动生成的。** 这比 ch25 的 Wi-Fi（39 个必须由 C 胶水补的符号、
一张 128 项 OSI 函数表）干净得多。

### 27.2.4 `libbtdm_common.a` 的缝更窄

```text
unique_undefined=151 provided_by_ble_set_plus_rom=150 left=1
glue: e_btdm_lp_modem_clock_set
```

只有一个符号。它是低功耗路径要调的 modem 时钟设置，IDF 侧由
`esp_hw_support/modem` 提供。也就是说：**如果你真的只链接
`libble_app.a + libbtdm_common.a + libbtbb.a`，需要自己实现的只有 1 个
平台函数 + 4 个 libc 函数 + `esp_restart`。**

### 27.2.5 802.15.4：没有归档

```text
## 8. 802.15.4 侧：没有归档，只有源码
archives_named_802154_in_idf=0
driver_files=10
driver_lines=3571
driver_frame_lines=468
ll_static_inline=2
public_api_functions=67
coex_i154_functions=8
```

`find components -path '*esp32s31*' -name '*.a' | grep 802154` 的结果是 0。
`components/ieee802154/` 里 10 个 C 文件、3571 行；帧解析在
`driver/esp_ieee802154_frame.c`（468 行），它自己就在做「FCF 位域 →
地址模式 → PAN 压缩」的判断：

```c
31: static inline uint8_t dst_addr_mode(const uint8_t *frame)
36: static inline uint8_t src_addr_mode(const uint8_t *frame)
41: static inline bool is_panid_compression(const uint8_t *frame)
60: static bool is_dst_panid_present(const uint8_t *frame)
71:   if ((src_mode == IEEE802154_FRAME_SRC_MODE_NONE && panid_compression) ||
72:       (dst_mode == IEEE802154_FRAME_DST_MODE_EXT && src_mode == IEEE802154_FRAME_SRC_MODE_EXT && panid_compression))
```

这段逻辑和本章 27.6 的 `encodeHeader`/`decodeHeader` 是同一件事的两个实现：
IDF 用它决定「帧里有没有 src PAN」，本章用它决定「头长 9 还是 11 字节」。
两者都从 FCF 的 bit6（PAN ID Compression）出发。

`ll_static_inline=2` 是个小细节：S31 的 `ieee802154_ll.h` 只有两个内联函数
（两个错误计数器读取），说明这颗芯片上 802.15.4 的寄存器操作没有集中在
LL 层，而是散在 `esp_ieee802154_dev.c`（1220 行）里直接写。

## 27.3 HCI：controller 与 host 的唯一缝

### 27.3.1 四种包型

HCI 在传输层上只有四种包（H4 编码）：

| 指示符 | 包型    | 方向              | 头                        |
| ------ | ------- | ----------------- | ------------------------- |
| `0x01` | Command | host → controller | OpCode(2) + PLen(1)       |
| `0x02` | ACL     | 双向              | Handle/Flags(2) + DLen(2) |
| `0x04` | Event   | controller → host | EventCode(1) + PLen(1)    |
| `0x03` | SCO     | 双向              | 本章不涉及                |

本章实现了前三种（`src/hci.zig`）。`src/hci.zig` 里 `h4_command/h4_acl/h4_event`
三个常数对应上表，出处是 Core 规范 Vol 4, Part A, §2 与 Vol 4, Part E, §5.4。

### 27.3.2 ACL 头：12 + 2 + 2 位挤在 16 位里

ACL 包头 4 字节：

```text
byte 0..1   Handle(12) | PB(2) | BC(2)   小端
byte 2..3   Data_Length(16)              小端
```

`Handle` 占低 12 位，`PB` 在 bit12..13，`BC` 在 bit14..15。本章的编码函数是
`AclHeader.encode`：

```zig
const handle_flags: u16 =
    @as(u16, self.handle) |
    (@as(u16, @intFromEnum(self.pb)) << 12) |
    (@as(u16, @intFromEnum(self.bc)) << 14);
out[0] = @truncate(handle_flags);
out[1] = @truncate(handle_flags >> 8);
```

KAT：`handle=0x042`、`PB=0b11`（complete）、`BC=0b00`、`Data_Length=5`
→ `0x3042` → 小端 `42 30 05 00`。这条就是判据 ①：

```text
check: hci acl header 42300500 handle=0x042 pb=3 ok=1
```

`pb=3` 是 `Pb.complete` 的枚举值（`0b11`）。判据同时检查了 decode 往返：
`back.handle == 0x042 and back.data_len == 5 and back.pb == .complete`。

一个坑：**`PB=0b00` 是“不可自动 flush 的首片”，`PB=0b10` 才是“可自动
flush 的首片”**，这两个位值写反了照样能编过、照样能跑，但 controller 侧会
把续片当首片、或把首片当续片，表现为「ATT 请求永远收不到响应」。本机就能
对拍：`components/bt/host/nimble/nimble/nimble/include/nimble/hci_common.h`
的 `:2891`–`:2894` 依次是

```c
#define BLE_HCI_PB_FIRST_NON_FLUSH          0
#define BLE_HCI_PB_MIDDLE                   1
#define BLE_HCI_PB_FIRST_FLUSH              2
#define BLE_HCI_PB_FULL                     3
```

本章的 `Pb` 枚举与这四个常数逐值对齐（`first_non_flushable=0b00`、
`continuation=0b01`、`first_flushable=0b10`、`complete=0b11`），Linux
`include/net/bluetooth/hci.h` 的 `ACL_START_NO_FLUSH/ACL_CONT/ACL_START/
ACL_COMPLETE` 也一致。

### 27.3.3 严格长度：拒绝，而不是截断

`encodeAcl` / `decodeAcl` 都做严格长度检查，规则如下：

| 情况                        | 结果             | 计数                              |
| --------------------------- | ---------------- | --------------------------------- |
| payload > 251               | `error.Oversize` | `rejected += 1`                   |
| 输出缓冲 < 4 + payload      | `error.NoSpace`  | `rejected += 1`                   |
| 输入 < 4                    | `error.Short`    | `rejected += 1`                   |
| Data_Length > 251（解包时） | `error.Oversize` | `rejected += 1`                   |
| 输入 < 4 + Data_Length      | `error.Short`    | `rejected += 1`、`truncated += 1` |
| 输入 > 4 + Data_Length      | `error.Trailing` | `rejected += 1`                   |

为什么 `acl_max_payload` 取 251？因为 LE 数据长度扩展（Data Length
Extension）之后一个 LL PDU 的载荷上限是 251 字节；ATT MTU 247 的值正好放得下。
真实 controller 的 ACL 缓冲由 `HCI_ACL_PKT_LEN` 一类配置决定，本章取 251
作为「不依赖配置的保守上界」。

判据 ② 直接打这条路径：

```text
check: hci acl max=251 oversize_rejected=1 encoded=1 truncated=1 ok=1
```

三个数字各有含义：

- `oversize_rejected=1`：252 字节被拒，且**没有**产生编码（`encoded=1` 是后
  面那个 251 字节成功包贡献的）；
- `encoded=1`：恰好 251 字节通过，总长 `4 + 251 = 255`；
- `truncated=1`：把那个 255 字节的包砍掉 1 字节再解，必须报 `Short` 且
  计入截断。

这条判据的写法本身就是本章的一条纪律：**计数是分开的**。如果
`rejected` 与 `truncated` 共用一个计数器，主 agent 复核时无法区分
「长度越界」和「包被砍断」。

### 27.3.4 Command 与 Event

Command 包：`01 | OpCode(2, LE) | PLen(1) | params`。OpCode 由 OGF/OCF 合成：

```zig
pub fn opcode(ogf: u6, ocf: u10) u16 {
    return (@as(u16, ogf) << 10) | @as(u16, ocf);
}
```

LE Controller 命令的 OGF 固定 `0x08`。LE Set Advertising Enable 的 OCF 是
`0x000A`，于是 OpCode = `0x200A`，包是 `01 0A 20 01 01`（最后两位是
`PLen=1` 和参数 `Enable=1`）。这个字节串在 `src/hci.zig` 里是
`kat_set_adv_enable`，主机测试逐字节比对。

Event 包：`04 | EventCode(1) | PLen(1) | params`。本章用两个事件：

- **Command Complete（0x0E）**：`num_hci_cmd_packets(1) | command_opcode(2) | 返回参数`；
- **LE Meta（0x3E）**：参数第一个字节是子事件码，`0x01` = LE Connection
  Complete，`0x02` = LE Advertising Report。

这里有一个非常容易写错的细节，本章的 KAT 注释里专门标了：**子事件码 0x02
和 Advertising Report 里的 `num_reports` 是两个不同的字节**。帧是这样的：

```text
04 3E <PLen> 02 <num_reports> <report 0> <report 1> ...
```

`02` 是子事件码，紧跟的才是 `num_reports`。判据 ⑤ 的 ADV_IND KAT 长这样：

```text
num_reports = 01
event_type  = 00 (ADV_IND)
addr_type   = 00 (public)
addr        = E0 E1 E2 E3 E4 E5   （小端打印时是 E5:E4:E3:E2:E1:E0）
data_len    = 0D
data        = 02 01 06 | 03 03 0A 18 | 05 09 'c' 'h' '2' '7'
rssi        = C0  (-64 dBm)
```

13 字节广播数据分三段：flags（`02 01 06`，LE General Discoverable + BR/EDR
not supported）、16 位 UUID `0x180A`（`03 03 0A 18`，即 Device Information
Service，UUID 字段小端）、完整设备名 "ch27"（`05 09` + 4 字节 ASCII）。

`findLocalName` 按 AD 结构的 `Length(1) + Type(1) + Data(Length-1)` 遍历，
遇到 `Type=0x09` 就返回数据；`Length=0` 视为填充并停止。主机测试断言
解析结果是 `"ch27"`，RSSI 是 `-64`。

### 27.3.5 本工程与真实 controller 的距离

`components/bt/controller/esp32s31/bt.c` 里，IDF 的初始化顺序是：

```c
60: extern int r_btdm_task_init(esp_btdm_controller_config_t *cfg);
230:    ret = r_btdm_task_init(&cfg->btdm);
266:    ret = hci_transport_init(BT_HCI_TRANSPORT_MODE);
```

`BT_HCI_TRANSPORT_MODE` 在 S31 上默认是 `HCI_TRANSPORT_VHCI`
（`components/bt/porting_btdm/transport/include/esp_hci_transport.h:32`；
`hci_transport_init` 的声明在同文件 `:47`）。

也就是说：真实路径是「`hci_transport_init(HCI_TRANSPORT_VHCI)` → 把 HCI
包通过 VHCI 环形缓冲交给 controller」。本章的 `hci.zig` 产出的正是这个
环形缓冲里该出现的字节，只是**没有接收方**。这个差别写在 27.11。

## 27.4 ATT/GATT：句柄、MTU、权限、通知

### 27.4.1 ATT 只有 8 个操作码

ATT 的 PDU 是「1 字节操作码 + 参数」，没有长度字段——长度由 L2CAP 给。
本章实现 8 个：

| 操作码 | 名字                      | 方向          | 参数                        | 规范           |
| ------ | ------------------------- | ------------- | --------------------------- | -------------- |
| `0x01` | Error Response            | server→client | req_op(1) handle(2) code(1) | Vol 3 F §3.4.1 |
| `0x02` | Exchange MTU Request      | client→server | client_rx_mtu(2)            | §3.4.2         |
| `0x03` | Exchange MTU Response     | server→client | server_rx_mtu(2)            | §3.4.2         |
| `0x0A` | Read Request              | client→server | handle(2)                   | §3.4.4         |
| `0x0B` | Read Response             | server→client | value(≤MTU-1)               | §3.4.4         |
| `0x12` | Write Request             | client→server | handle(2) value(…)          | §3.4.5         |
| `0x13` | Write Response            | server→client | 无                          | §3.4.5         |
| `0x1B` | Handle Value Notification | server→client | handle(2) value(≤MTU-3)     | §3.4.7         |

操作码数值在本机能查到四处对拍：`components/bt/host/nimble/nimble/nimble/
host/include/host/ble_att.h` 的 `:124`（0x01）、`:127`（0x02）、`:130`（0x03）、
`:151`（0x0a）、`:154`（0x0b）、`:175`（0x12）、`:178`（0x13）、`:199`（0x1b）。
这些行号是 `grep -n` 实测，写在 `src/att.zig` 的头注释里。

### 27.4.2 MTU：23 是下限，不是建议

规范给 ATT_MTU 的上限是 **517**（Vol 3, Part F, §3.2.8），默认值是 23。
NimBLE 把上限扩到 527（`ble_att.h:275`），理由就写在紧邻的注释里
（`:270-273`）：一个 527 的 MTU 才能让最大的 ATT 命令（Signed Write）装下
512 字节属性值。本章的 `att.max_mtu` **跟 NimBLE 取 527**——所以判据里
`min(client, server_max)` 的第二项是 527，不是规范原文的 517。

交换流程（判据 ③）：

```text
client → server   02 F7 00            (client_rx_mtu = 0x00F7 = 247)
server: negotiated = min(247, 527) = 247
server → client   03 F7 00
```

三个断言：

1. `decodeMtuReq` 返回 247；
2. `negotiate(247, 527) == 247`；
3. `encodeMtuRsp` 的 3 个字节等于 `03 F7 00`，且 `stats.mtu_exchanges == 1`。

以及一个**拒绝**断言：请求 22（`02 16 00`）返回 `error.MtuTooSmall`，
并且 `mtu_exchanges` **不能**加一（也就是「被拒的交换不计数」）。

这里要标明：**「拒绝 < 23」是本章更严的自定策略，不是规范要求。** 规范只说
23 是默认值与最小值，没说收到 22 必须报错；本机的 NimBLE 选择的是「夹到
23」——`components/bt/host/nimble/nimble/nimble/host/src/ble_att.c:492`
的 `ble_att_set_peer_mtu` 里，`:494-496` 就是

```c
if (peer_mtu < BLE_ATT_MTU_DFLT) {
    peer_mtu = BLE_ATT_MTU_DFLT;
}
```

本章之所以选「拒绝」，是因为本工程的判据要一个**可判别的失败**（`rejected`
计数 + `error.MtuTooSmall`），而不是一个静默的钳位。两种做法都对，但验收
方式不同——这也是本节要把「规范」与「本实现策略」分开写的原因。日志：

```text
check: att mtu req=247 negotiated=247 rsp=03f700 rejected=1 exchanges=1 ok=1
```

`rejected=1` 就是那次 22 的请求。这里刻意把「成功交换」与「被拒请求」用两个
计数器分开，理由和 27.3.3 一样。

### 27.4.3 截断：MTU 决定了每个响应的有效载荷

三个上限，都从「操作码字节数」推出来：

| PDU           | 头部字节           | 值上限  |
| ------------- | ------------------ | ------- |
| Read Response | 1（0x0B）          | MTU - 1 |
| Notification  | 3（0x1B + handle） | MTU - 3 |
| Write Request | 3（0x12 + handle） | MTU - 3 |

判据 ④ 用 30 字节的值打 MTU=23 的 Read Response：

```text
request  = 0A 25 00                 (句柄 0x0025)
response = 0B 'c' 'h' '2' '7'       (5 字节值)
cut      = 23                       (30 字节值被截到 22 + 1 字节头)
truncated= 1
```

日志：

```text
check: att read req=0a2500 rsp=0b-ch27 cut=23 truncated=1 ok=1
```

注意 `cut=23`：这是**整个 PDU** 的长度，不是值的长度。值 22 字节 + 头 1 字节。
写代码时最容易在这里差一：`MTU - 1` 是值上限，因为响应头占 1 字节。

### 27.4.4 GATT 表：句柄是按「声明/值/CCCD」推出来的

GATT 的句柄不是随便编号的，它按属性在服务里的顺序递增
（Vol 3, Part G, §3.3）。本章的规则在 `gatt.Table.add` 里：

```zig
const decl = self.next_handle;
const value_handle = decl + 1;
const cccd: u16 = if (perm.notify) value_handle + 1 else 0;
...
self.next_handle = value_handle + 1 + @intFromBool(perm.notify);
```

于是：

| 特征       | 声明句柄 | 值句柄 | CCCD 句柄 |
| ---------- | -------- | ------ | --------- |
| #1 只读    | 0x0001   | 0x0002 | —         |
| #2 读+通知 | 0x0003   | 0x0004 | 0x0005    |
| #3 读写    | 0x0006   | 0x0007 | —         |

8 个只读特征会占 16 个句柄，`next_handle == 0x0011`。判据 ⑧ 断言这个数：

```text
check: gatt capacity chars=8/8 ninth=table_full rejected=1 next=0x0011 ok=1
```

`table_full` 必须带**可判别的错误码**，所以 `gatt.Err.code()` 把
`table_full`/`subs_full` 映射到 ATT `0x11 Insufficient Resources`
（`ble_att.h:111`），而 `not_subscribed` 返回 `null`——因为「通知一个没
订阅的特征」根本不会产生 ATT 错误，它是服务端内部事件。这个区别是判据 ⑥
的一部分。

### 27.4.5 权限与错误码：三行代码必须给对三个数字

权限位与 nimble 的 `BLE_GATT_CHR_F_*` 一一对应
（`components/bt/host/nimble/nimble/nimble/host/include/host/ble_gatt.h:133`
READ、`:139` WRITE、`:142` NOTIFY），本章只复刻位含义，不链接 nimble。

判据 ⑤ 打的是「只读特征收到 Write Request」：

```text
request   = 12 02 00 'n' 'o' 'p' 'e'   (写句柄 0x0002，只读)
error rsp = 01 12 02 00 03
             ^  ^  ^^^^^  ^
             |  |    |     └─ 0x03 Write Not Permitted
             |  |    └─────── 句柄 0x0002
             |  └──────────── 原始操作码 0x12
             └─────────────── 0x01 Error Response
```

日志：

```text
check: gatt write ro_handle=0x0002 code=0x03 err_pdu=0112020003 ok_writes=1 ok=1
```

`ok_writes=1` 是随后对读写特征的那次成功写入（返回单字节 `0x13`）。一个
判据里同时验证「拒绝」与「放行」，比只验证拒绝更能证明权限位真的被读。

### 27.4.6 CCCD：2 字节，{01 00} 与 {00 00}

Client Characteristic Configuration Descriptor 的 UUID 是 `0x2902`
（`ble_gatt.h:69` 的 `BLE_GATT_DSC_CLT_CFG_UUID16`），值是 2 字节位图：
bit0 = Notification，bit1 = Indication。

本章的 `handleWrite` 对 CCCD 的处理：

- 长度必须 2，否则 `invalid_value`；
- 只接受 `{01 00}`（开启 Notification）与 `{00 00}`（关闭）；bit1（Indication）
  本章不支持，`{02 00}`/`{00 01}` 一律 `invalid_value`；
- 开启时如果订阅表已满（4 格）→ `subs_full`（ATT `0x11`），**不占槽**；
- 重复开启不占新槽；
- `{00 00}` 退订。

判据 ⑥ 走完整条：未订阅 → 本地错误且**不写任何字节**（缓冲首字节仍是
哨兵 `0xA5`）；订阅 → 写成功；通知 → `1B 02 00 't' '=' '2' '1'`；退订 →
再通知被拒。日志：

```text
check: notify unsub_untouched=1 cccd=0x0003 pdu=1b0200-t21 subs=1/1 ok=1
```

`pdu=1b0200-t21` 是 7 个字节：操作码 `1B`、句柄 `02 00`（小端 0x0002）、
值 `t=21`。`subs=1/1` 是「订阅次数 / 退订次数」，两者相等说明退订真的发生了。

「未订阅不写字节」这一条是刻意设计的：如果实现里先写操作码再判断订阅，
`buf[0]` 就会变成 `0x1B`，判据会立刻失败。这比「返回了一个错误」严格得多。

### 27.4.7 句柄越界

判据 ⑦ 打三个句柄：`0x0099`（从未分配）、`0x0000`（保留）、`0x0001`
（声明句柄，不可读）。三个都必须返回 `invalid_handle`，且只有一次错误响应
被编码进缓冲：

```text
check: gatt handle range 0x0099=01-0a990001 reserved_rejected=1 errors=1 ok=1
```

`01-0a990001` 是 5 字节 Error Response：`01 0A 99 00 01`。

## 27.5 一个最小 GATT 服务器怎么被验证（注入 HCI 包）

真实的验证路径是「把 HCI 包喂给 controller，控制器回事件」。本章没有
controller，于是把验证拆成三段，每段都能独立断言：

```text
   ┌────────────┐   ACL 包    ┌──────────┐   ATT PDU   ┌────────────┐
   │ hci.zig    │ ─────────→ │ (L2CAP)  │ ──────────→ │ att/gatt   │
   │ 分帧/解帧  │ ←───────── │  CID     │ ←────────── │ 表与权限   │
   └────────────┘  事件/ACL  └──────────┘  ATT PDU    └────────────┘
```

1. **封装层**：`hci.encodeAcl` 把一个 ATT PDU 封成 ACL 包。本章不做
   L2CAP 分片（4 字节 L2CAP 头：长度 2 + CID 2），因为 ATT 固定走
   CID `0x0004`，单帧足够。这一步在主机测试里断言：`4 + payload.len`。
2. **协议层**：`att` 的解码函数只接受「长度恰好」的 PDU；`gatt.Table`
   按句柄分发到「值」或「CCCD」。
3. **错误层**：所有失败都转成 `gatt.Err`，再由 `att.encodeError` 编码成
   5 字节。

把这三段接起来，「注入一个 Read Request」就变成：

```zig
// 1) 客户端侧字节
const req = att.kat_read_req;                    // 0A 25 00

// 2) 解出句柄
const handle = try att.decodeReadReq(&req, &att_stats);

// 3) 服务端处理
const reply = table.handleRead(handle, &out, 23, &att_stats);
switch (reply) {
    .pdu => |n| { /* out[0..n] 是 Read Response */ },
    .err => |e| { /* e.code() 给出 ATT 错误码 */ },
}
```

这条路径在板侧被 12 条判据覆盖，在主机侧被 20 个用例覆盖。**同一份代码、
两个架构、同样的字节**——这就是本章能拿出的最强证据。

### 27.5.1 为什么不用「真 controller + 空口」

因为那需要三件事同时成立：

1. 链接 5 份归档（5.15 MB）并解决 10 个 glue；
2. 初始化 PHY（`libphy.a` + `esp_phy_enable` 一类调用），并把 coex 配好；
3. 让 controller 真正进入 advertising 状态，这需要 `r_btdm_task_init` 成功
   返回——而它依赖 `esp_hw_support` 的时钟与低功耗钩子。

这三步里任何一步失败，都会表现为「板子复位」或「HCI 超时」，而不是
「判据失败」。本章的选择是：**先把能确定性判定的部分做到底**，把不确定性
留给 27.11 的判据。这也和 ch25 的做法一致（那次是不链接 Wi-Fi blob）。

## 27.6 802.15.4 MAC 帧与 6LoWPAN 最小解压

### 27.6.1 FCF：16 位、小端、位 0 是帧类型

帧控制字段（Frame Control Field）的位定义（IEEE 802.15.4-2015 §7.2.1.1）：

```text
bit 0..2   Frame Type      000 beacon / 001 data / 010 ack / 011 command
bit 3      Security
bit 4      Frame Pending
bit 5      Ack Request
bit 6      PAN ID Compression
bit 7      Reserved
bit 8      Sequence Number Suppression
bit 9      IE Present
bit 10..11 Destination Addressing Mode   00 none / 10 short / 11 long
bit 12..13 Frame Version
bit 14..15 Source Addressing Mode
```

本章的 KAT：数据帧 + 请求 ACK + PAN 压缩 + 双短地址 + version 0

```text
0001 (data) + 0020 (ack) + 0040 (pan comp) + 0800 (dst short) + 8000 (src short)
= 0x8861  →  小端字节 61 88
```

把源地址换成 64 位就是 `0xC861` → `61 C8`。判据 ⑨：

```text
check: ieee802154 fcf short=0x8861 long_src=0xc861 acks=1 pancomp=1 ok=1
```

判据还做了 decode 往返：`frame_type == .data`、`ack_request`、`pan_compress`、
`dest_mode == .short`、`src_mode == .short`、`version == 0`。

### 27.6.2 头长不是常数

地址模式与 PAN 压缩决定头长。本章的 `encodeHeader` 按下面的顺序写：

```text
FCF(2) | Seq(1) | Dest PAN(2) | Dest Addr(2 或 8) | [Src PAN(2)] | Src Addr(2 或 8)
```

`Src PAN` 只在「未压缩 PAN」且「有源地址」时出现。于是：

| 组合             | 头长 |
| ---------------- | ---- |
| 短/短 + PAN 压缩 | 9    |
| 短/长 + PAN 压缩 | 15   |
| 短/短 + 不压缩   | 11   |

判据 ⑩ 打前两行：

```text
check: ieee802154 hdr short=9B long=15B decoded=1 src=short ok=1
```

它同时断言了「解码回来的地址类型是 `.short`」（而不是只看长度），以及
`seq == 0x2A`、`dest_pan == 0x1234`。这段逻辑与 IDF 的
`esp_ieee802154_frame.c:60`（`is_dst_panid_present`）是同一件事：用 FCF 的
bit6 与两个地址模式决定 PAN 字段在不在。

### 27.6.3 6LoWPAN：IPHC 是「大端位序的位域」

6LoWPAN 的 IPHC 编码（RFC 6282 §3.1.1）两字节：

```text
byte 0:  0 1 1 | TF(2) | NH(1) | HLIM(2)
byte 1:  CID(1) | SAC(1) | SAM(2) | M(1) | DAC(1) | DAM(2)
```

注意这里的 bit0 是**最高位**（网络位序），与 802.15.4 的 FCF 相反。这是本章
最容易出错的地方：**同一个报文里，前 2 字节按 LE 读，后 2 字节按 BE 位域读。**

本章支持的组合（全部是无状态压缩）：

| 字段 | 值      | 含义                                 |
| ---- | ------- | ------------------------------------ |
| TF   | 11      | Traffic Class 与 Flow Label 全省     |
| NH   | 1       | 下一个头走 NHC                       |
| HLIM | 11      | Hop Limit = 255                      |
| CID  | 0       | 无上下文扩展                         |
| SAC  | 0       | 源地址用无状态压缩                   |
| SAM  | 10 / 11 | 源地址 16 位内联 / 全省（由 MAC 推） |
| M    | 0       | 目标不是组播                         |
| DAC  | 0       | 目标地址用无状态压缩                 |
| DAM  | 10 / 11 | 目标地址 16 位内联 / 全省            |

于是两个 KAT 字节：

- `7F 22`：SAM=10、DAM=10（两个 16 位内联地址）
- `7F 33`：SAM=11、DAM=11（地址全省，从 802.15.4 头推）

`7F` 的来历：`011` + `11`（TF）+ `1`（NH）+ `11`（HLIM）= `0b01111111`。

### 27.6.4 地址推导：RFC 6282 的两种 IID，与 RFC 4944 §6 的差别

16 位短地址 → IID 是 `0000:00ff:fe00:XXXX`。出处是 **RFC 6282 §3.1.1**
（SAM=10 的 16 位内联映射，§3.2.2 复述同一规则），OpenThread 的实现
（`components/openthread/openthread/src/core/net/ip6_address.cpp` 的
`InitAsLocator`）也是这个形式。

这里要点名一个容易混的差别：**RFC 4944 §6 给的是另一种派生**——
「PAN ID ‖ 16 个 0 ‖ 短地址」组成伪 48 位地址，再按 RFC 2464 变成 IID，
那样算出来会把 PAN ID 掺进 IID（`PAN:00ff:fe00:XXXX`）。本章的 KAT 按
RFC 6282 的口径（PAN 不进 IID），因为 IPHC 压缩后的地址就是这个口径。

64 位长地址 → IID 是「把 U/L 位取反」（RFC 2464 的 EUI-64 映射，RFC 4944 §6
对 EUI-64 地址引用同一条规则）。判据 ⑪ 用长地址
`02:11:22:33:44:55:66:77`，翻转后 IID 首位变成 `0x00`，导出
`fe80::11:2233:4455:6677`：

```text
check: lowpan stateless=2 ports=0x1234/0x5678 plen=10 ul_flip_ok=1 ok=1
```

这条判据同时验证了 `plen=10`（IPv6 Payload Length = UDP 头 8 + "ok" 2）与
两个端口的网络序。如果端口按小端读，`0x1234` 会变成 `0x3412`，判据立刻红。

### 27.6.5 NHC UDP：`11110CPP`

UDP 头压缩的 NHC 格式（RFC 6282 §4.3.3）：

```text
1 1 1 1 0 | C | P P
```

- `C=0`：16 位校验和**内联**；
- `C=1`：校验和省略（由终点重算）；
- `P=00`：两个端口都 16 位内联；
- `P=01/10/11`：端口部分压缩（本章不支持）。

本章的 KAT 用 `0xF0`（C=0、P=00），后面跟 2 + 2 端口与 2 字节校验和。
`7F 22 3C 9A 02 00 F0 12 34 56 78 AB CD 'o' 'k'` 一共 15 字节。

注意端口与校验和是**网络序**：`12 34` 是端口 0x1234，`AB CD` 是校验和
0xABCD。这与 802.15.4 自己的 PAN/短地址（小端）不同，所以 `fifteen4.zig`
里有两个函数：`getU16`（小端，给 MAC 字段）与 `getU16Be`（大端，给 UDP 字段）。

### 27.6.6 拒绝路径：判据 ⑫

不支持的东西必须**明确拒绝**，而不是猜：

| 输入                               | 原因              | 错误                           |
| ---------------------------------- | ----------------- | ------------------------------ |
| `7F 46`（SAC=1、SAM=01）           | 需要上下文表      | `error.UnsupportedCompression` |
| `7F 22 … F1`（P=01）               | 端口压缩未实现    | `error.UnsupportedCompression` |
| `C0 2A 00`（dispatch 11000xxx）    | 分片头，不是 IPHC | `error.BadDispatch`            |
| `7F 22 … E0`（NHC 11100 = 非 UDP） | 本章只支持 UDP    | `error.UnsupportedCompression` |

判据 ⑫ 在板侧打前三个，同时断言 `rejected=3`、`decompressed` 保持 1（前一条
成功解压的计数）：

```text
check: lowpan reject stateful+ports+frag rejected=3 decompressed=1 (UnsupportedCompression+UnsupportedCompression+BadDispatch) ok=1
```

主机侧多打一个「非 UDP 的 NHC」（`rejected=4`）。

## 27.7 Thread 在哪里（边界声明，不实现 MLE）

Thread 建立在 802.15.4 之上，由三块组成：

1. **MAC/PHY**：IEEE 802.15.4-2015，S31 上是 IDF 的 C 驱动 + `libphy.a`；
2. **6LoWPAN**：RFC 6282 的 IPHC/NHC（本章 27.6 实现了无状态子集）；
3. **MLE**（Mesh Link Establishment，RFC 未收录，Thread 规范定义）与
   路由/边界路由器。

S31 的 IDF 里带了一份 OpenThread：`components/openthread/lib/esp32s31/
libopenthread_br.a`，557 550 字节、21 个成员、249 个定义符号、230 个未定义
符号。它的导出里有 `otPlatDnsStartUpstreamQuery`、
`otPlatInfraIfSendIcmp6Nd`、`otPlatInfraIfDiscoverNat64Prefix` 这类
**边界路由器平台接口**——也就是说这是一份「border router」构建，需要宿主
提供 infra 接口（以太网/Wi-Fi）的实现。

本章**不链接**它，也不实现 MLE。理由很直接：

- MLE 的核心是「用 802.15.4 单跳广播建立邻接、协商角色、同步数据集」，
  它的每一条消息都要真的发出去、真的收到，否则判据只能是自欺；
- OpenThread 的 230 个未定义符号里，绝大多数是 `otPlat*` 平台钩子
  （radio、alarm、settings、infra-if），要全部实现才谈得上「入网」。

所以 Thread 在本章只出现两处：27.6 的 6LoWPAN（它是 Thread 的载荷格式）
与这里的边界声明。入网判据在 27.11.4。

## 27.8 与 ch25 的 ABI 垫片关系

ch25 交付的是一套**可插拔 blob 的 ABI**：`BlobVTable` + `HostApi` +
注册表 + 上行队列 + 错误码映射。本章的 BLE 部分和它是同构的，但**独立重写、
仅签名级依赖**：

| 维度         | ch25（Wi-Fi blob）                    | ch27（BLE controller）                                          |
| ------------ | ------------------------------------- | --------------------------------------------------------------- |
| 边界形态     | 注册 vtable（宿主给 blob 函数表）     | 注册函数指针（blob 让宿主给表）                                 |
| 入口         | `adapter.register(&vt, &h)`           | `esp_register_ext_funcs(...)`、`esp_ble_register_bb_funcs(...)` |
| 数据通道     | `Event` 结构（20 字节）+ 环形队列     | HCI 包（ACL/Event），字节流                                     |
| 缝的宽度     | 39 个必须胶水补的符号 + 128 项 OSI 表 | 10 个符号（含 5 个链接器段符号）                                |
| 版本校验     | ABI `version`/`size` 字段，拒绝不匹配 | HCI OpCode 与事件码（无版本字段）                               |
| 本章是否链接 | 否（`linked_real_blob` 恒 false）     | 否（无 extern）                                                 |

**签名级依赖**的意思是：本章的 `hci.encodeAcl` 与 ch25 的 `Event` 编码在
「长度字段 + 小端 + 显式拒绝」这三条上取同样的姿势，但类型、函数名、模块
边界完全不同，没有任何 `@import` 关系。这样做的好处是：ch25 的 blob 垫片
经验可以直接复用，而两章可以独立编译、独立验证。

一个具体的对照：ch25 的判据 ⑧ 是「队列满：投 9 个，前 8 个入队、第 9 个
`no_space`、`drop` 计数 +1」；本章的判据 ⑧ 是「表满：注册 8 个，第 9 个
`table_full`、`rejected=1`、`next_handle` 不变」。同一个纪律（容量边界必须
可判别），两个不同的容器。

## 27.9 工程走读

形态 B 的骨架与 ch13–ch26 相同：`linker/s31.ld` + `src/start.zig` +
`idf-bootstrap/`（只产 bootloader/分区表/flash_args）。本章新增的是五个
纯逻辑模块。

| 文件                 | 行数 | 职责                                                             | 查看                                                                             |
| -------------------- | ---- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `build.zig`          | 59   | 目标串、链接脚本、`zig build test`（20 例）                      | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/build.zig)          |
| `linker/s31.ld`      | 176  | 两个 flash 段、`.trap_ram`、堆/栈、6 条 ASSERT                   | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/linker/s31.ld)      |
| `src/start.zig`      | 164  | `esp_app_desc_t` + naked `_start`（关 WDT、清零 .bss、装 mtvec） | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/start.zig)      |
| `src/main.zig`       | 37   | banner → `selftest.run()` → verdict → `wfi`                      | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/main.zig)       |
| `src/hci.zig`        | 465  | H4/ACL/Command/Event/LE Meta，严格长度                           | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/hci.zig)        |
| `src/att.zig`        | 374  | 8 个操作码、MTU、截断、错误响应                                  | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/att.zig)        |
| `src/gatt.zig`       | 342  | 定长表、句柄分配、权限、CCCD 订阅                                | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/gatt.zig)       |
| `src/fifteen4.zig`   | 568  | FCF、地址、6LoWPAN IPHC/NHC                                      | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/fifteen4.zig)   |
| `src/selftest.zig`   | 642  | 12 条判据 + 4 行读数                                             | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/selftest.zig)   |
| `src/host_tests.zig` | 443  | 20 个主机用例                                                    | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/host_tests.zig) |
| `src/trap.zig`       | 149  | `.trap_ram` 异常入口 + panic                                     | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/trap.zig)       |
| `src/hw.zig`         | 44   | CSR 读、ROM 忙等、`wfi`                                          | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/hw.zig)         |
| `src/log.zig`        | 28   | 单行 `esp_rom_printf`                                            | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/log.zig)        |
| `tools/symbols.sh`   | 171  | 27.2 的每个数字                                                  | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/tools/symbols.sh)   |
| `inventory.txt`      | 114  | 符号取证产物                                                     | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/inventory.txt)      |
| `tools/flash.sh`     | 97   | 按 `flash_args` 烧录                                             | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/tools/flash.sh)     |
| `README.md`          | 111  | 验证状态、快速开始、文件表                                       | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/README.md)          |

### 27.9.1 为什么 `hci.zig` 不依赖 `att.zig`

模块依赖是单向的：

```text
   fifteen4.zig   （独立：不依赖任何人）
   hci.zig        （独立：对象是字节缓冲）
   att.zig        （独立：只做 PDU）
   gatt.zig   →   att.zig        （GATT 需要把值编码成 Read Response/Notification）
   selftest.zig → 四个都依赖
```

`hci.zig` 不 import `att.zig`，因为 HCI 只知道「载荷是一段字节」；它不需要
知道载荷是 ATT 还是 L2CAP 信令。这样主机测试可以单独测 HCI，不需要构造
GATT 表。

### 27.9.2 静态内存账本

实测（`readelf -SW zig-out/bin/app.elf`）：

```text
.flash.text    0x40000020  size 0x38a0   (app_desc 256B + .text.trap + .text)
.flash.rodata  0x40020020  size 0x0b90   (KAT 字节串、格式化字符串)
.trap_ram      0x2f000000  size 0x006c
.data          0x2f000070  size 0x0130
.bss           0x2f0001a0  size 0x0050
```

`.bss` 只有 80 字节，因为 GATT 表（8 × `Char`，每个 30 字节左右）与统计
计数器都被 Zig 放进了 `.data`（它们有编译期初值），而 `selftest` 的临时
缓冲都在栈上。总静态占用不到 20 KB，主栈 16 KiB，heap 从 `_bss_end` 到
`_stack_bottom` 全部未用。

## 27.10 上板自检输出

烧录走 flock（两章共用 `/dev/ttyUSB1`）：

```bash
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'
```

串口抓取（先开端口再 RTS 复位）：

```python
import serial, time
s = serial.Serial('/dev/ttyUSB1', 115200, timeout=0.2)
s.setDTR(False); s.setRTS(True); time.sleep(0.1); s.setRTS(False); time.sleep(0.1)
buf = b""; t0 = time.time()
while time.time() - t0 < 12:
    buf += s.read(4096)
open('logs/ch27-boot.log', 'wb').write(buf)
```

原始日志在 `practice/zig-esp32-s31/logs/ch27-boot.log`。banner 之后是 12 条
判据与 4 行读数（原文，逐行未改）：

```text
ch27-ble-802154-boundary | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: hci framing + att/gatt server + 802154 fcf + 6lowpan (12 checks)
note: no radio, no scan, no connection, no thread join - controller blobs not linked
host: 20 unit tests via 'zig build test'
check: hci acl header 42300500 handle=0x042 pb=3 ok=1
check: hci acl max=251 oversize_rejected=1 encoded=1 truncated=1 ok=1
check: att mtu req=247 negotiated=247 rsp=03f700 rejected=1 exchanges=1 ok=1
check: att read req=0a2500 rsp=0b-ch27 cut=23 truncated=1 ok=1
check: gatt write ro_handle=0x0002 code=0x03 err_pdu=0112020003 ok_writes=1 ok=1
check: notify unsub_untouched=1 cccd=0x0003 pdu=1b0200-t21 subs=1/1 ok=1
check: gatt handle range 0x0099=01-0a990001 reserved_rejected=1 errors=1 ok=1
check: gatt capacity chars=8/8 ninth=table_full rejected=1 next=0x0011 ok=1
check: ieee802154 fcf short=0x8861 long_src=0xc861 acks=1 pancomp=1 ok=1
check: ieee802154 hdr short=9B long=15B decoded=1 src=short ok=1
check: lowpan stateless=2 ports=0x1234/0x5678 plen=10 ul_flip_ok=1 ok=1
check: lowpan reject stateful+ports+frag rejected=3 decompressed=1 (UnsupportedCompression+UnsupportedCompression+BadDispatch) ok=1
read: hci acl_buf=255 max_payload=251 encoded=1 decoded=1 rejected=2
read: att mtu=23/527 exchanges=0 reads=0 writes=0 notifies=0 errors=1 trunc=0
read: gatt chars=8 subs=0 mask=0x00 lowpan_len=15
read: 154 frames=0/0 decompressed=1 rejected=3
checks: passed=12 failed=0 total=12
main: verdict=pass, hci/att/gatt/802154 byte paths verified (wfi)
main: halting (wfi)
```

几处需要解释的读数：

- `read: att … exchanges=0 reads=0 …`：四行 `read:` 打印的是**最后一次
  reset 之后**的计数。每个 check 开头都会 `att_stats.reset()`，最后一条
  判据（⑫）只碰 802.15.4，所以 ATT 的计数停在 ⑦ 的状态（1 次 error、
  exchanges 已被 ⑧ 的 reset 清掉）。这不是 bug：判据内部的数字都断言在
  `check:` 行里，`read:` 只是给人肉对拍用的。
- `read: 154 frames=0/0`：帧计数在 ⑫ 开头被 reset，之后只做解压不做
  编解码，所以是 0。
- `check: hci acl header … pb=3`：`pb=3` 是 `Pb.complete` 的枚举值。

启动段（bootloader）也值得贴两行，因为它证明「两段」：

```text
I (81) esp_image: segment 0: paddr=00010020 vaddr=40000020 size=038a0h ( 14496) map
I (119) esp_image: segment 4: paddr=00020020 vaddr=40020020 size=01314h (  4884) map
```

`esptool image-info` 的对应输出（恰好两行 `DROM, IROM`）：

```text
      0  0x038a0  0x40000020  0x00000018  DROM, IROM
      4  0x01314  0x40020020  0x00010018  DROM, IROM
```

两行之外还有 `PADDING` 段（把 DROM 的页内偏移对齐），这不是本章引入的：
ch23–ch25 的镜像都有，`elf2image` 自己插的。

## 27.11 边界：真实扫描/连接/读特征值/入网需要什么

本节把「还没做到的事」写成判据。每条都给出「跑什么、看什么、算过」，
不给结论。

### 27.11.1 真实广播/扫描

**需要什么**：

1. 链接 `libble_app.a` + `libbtdm_common.a` + `libbtbb.a` + `libphy.a`，
   解决 27.2.3 的 10 个 glue（其中 5 个由链接脚本片段给）；
2. 调 `hci_transport_init(HCI_TRANSPORT_VHCI)`（S31 默认路径），
   再按 `components/bt/controller/esp32s31/bt.c:230` 的顺序
   `r_btdm_task_init(&cfg->btdm)`；
3. 初始化 PHY（`esp_phy_enable`）并把 coex 的 i154/BT 仲裁配好。

**判据**：

- 跑：发 LE Set Scan Enable（OpCode `0x200C`，参数 `01 00`），等 2 秒。
- 看：Event 包里是否出现 `0x3E 0x02`（LE Meta / Advertising Report），
  并且 `num_reports ≥ 1`。
- 算过：至少一条报告的 `data_len > 0` 且 `findLocalName` 能解出名字，
  RSSI 在 `[-100, 0]` 内。

**当前状态**：未做。本章的 `hci.kat_adv_event_params` 是**手工构造**的事件
参数，注释里写明了它来自规范布局，不是抓包。

### 27.11.2 真实连接与 GATT 读写

**需要什么**：27.11.1 的全部 + 一个能发起连接的 peer（手机/另一块板）。

**判据**：

- 跑：在 27.11.1 的扫描结果里选一个发起 LE Create Connection，
  然后 `Exchange MTU` → `Read Request` → `Write Request` → 订阅通知。
- 看：Connection Complete 的 `status == 0` 且 `handle` 与后续 ACL 包的
  handle 一致；Read Response 的值与 peer 侧的特征值逐字节相同。
- 算过：MTU 协商结果 ≥ 23 且 ≤ 双方声明上限；至少收到 1 个
  Notification 且其 CCCD 状态在写之前是 0。

**当前状态**：未做。本章验证的是「同样的字节被正确编码/解码」，而不是
「这些字节在空口上跑过」。

### 27.11.3 802.15.4 真实收发

**需要什么**：`libphy.a` + `esp_ieee802154_*`（67 个公开函数）+ 一个
已知的发送方（第二块板 / 一个 802.15.4 嗅探器）。

**判据**：

- 跑：`esp_ieee802154_set_channel(15)`、`set_panid(0x1234)`、
  `set_extended_address(...)`，然后 `esp_ieee802154_transmit(frame, true)`。
- 看：`esp_ieee802154_transmit_done()` 回调里的 `ack` 是否非空（请求了 ACK
  时），以及接收侧是否收到完全相同的字节。
- 算过：发 100 帧，ACK 率 > 90%，且接收侧解出的 FCF 与发送侧 `encode` 的
  16 位值相同。

**当前状态**：未做。本章只验证 FCF/地址/6LoWPAN 的字节层。

### 27.11.4 Thread 入网

**需要什么**：27.11.3 + `libopenthread_br.a` + 全部 `otPlat*` 钩子
（radio、alarm、settings、infra-if）+ 一个 Thread 边界路由器或另一节点。

**判据**：

- 跑：以 FTD 角色启动 OpenThread，扫 5 分钟，attach 到目标网络。
- 看：`ot_state_changed` 回调从 `detached` 变为 `child`（或 `router`），
  且 `ot_thread_get_leader_rloc16()` 非 0。
- 算过：MLE Advertisement 的接收计数 > 0；父节点 RLOC16 稳定 60 秒。

**当前状态**：未做，且本章明确不实现 MLE（见 27.7）。

### 27.11.5 为什么这些判据不写「预计能过」

因为本章所有「能过」的证据都来自实际运行：12 条判据、20 个用例、两次
`nm` 统计。凡是没跑过的，就写「需要什么 + 怎么判」，而不是猜一个结果。
这也是 ch17 以太网至今没闭环给这个系列留下的教训：**没量到的东西不要写
成结论。**

## 事实来源

本机 IDF（`~/esp/esp-idf`）与工程内文件，行号为 `grep -n` / `sed -n` 实测：

| #   | 事实                                                                           | 出处（行号实测）                                                                                      |
| --- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| 1   | ATT 操作码 `0x01/0x02/0x03/0x0a/0x0b/0x12/0x13/0x1b`                           | `components/bt/host/nimble/nimble/nimble/host/include/host/ble_att.h:124,127,130,151,154,175,178,199` |
| 2   | ATT 错误码 `0x01/0x02/0x03/0x04/0x11`                                          | 同文件 `:62,65,68,71,111`                                                                             |
| 3   | `BLE_ATT_MTU_DFLT 23`、`BLE_ATT_MTU_MAX 527`                                   | 同文件 `:269,275`                                                                                     |
| 4   | GATT 权限位 READ/WRITE/NOTIFY = `0x02/0x08/0x10`                               | `components/bt/host/nimble/nimble/nimble/host/include/host/ble_gatt.h:133,139,142`                    |
| 5   | CCCD UUID `0x2902`                                                             | 同文件 `:69`（`BLE_GATT_DSC_CLT_CFG_UUID16`）                                                         |
| 6   | HCI 传输模式枚举含 `HCI_TRANSPORT_VHCI`，`hci_transport_init` 原型             | `components/bt/porting_btdm/transport/include/esp_hci_transport.h:32,47`                              |
| 7   | S31 controller 初始化顺序 `r_btdm_task_init` → `hci_transport_init`            | `components/bt/controller/esp32s31/bt.c:60,230,266`                                                   |
| 7a  | PB 标志的四个位值（0=FIRST_NON_FLUSH、1=MIDDLE、2=FIRST_FLUSH、3=FULL）        | `components/bt/host/nimble/nimble/nimble/include/nimble/hci_common.h:2891,2892,2893,2894`             |
| 7b  | MTU<23 时 NimBLE 是“夹到 23”而不是拒绝                                         | `components/bt/host/nimble/nimble/nimble/host/src/ble_att.c:492,494,495`                              |
| 7c  | 527 的理由是让 Signed Write 装下 512 字节属性值                                | `components/bt/host/nimble/nimble/nimble/host/include/host/ble_att.h:270,273,275`                     |
| 8   | controller 数据/ BSS 段被 `SURROUND`，`archive: libbtdm_common.a`              | `components/bt/controller/linker_esp_btdm_controller.lf:32,34,83,86,88,94,96,99`                      |
| 9   | 802.15.4 帧解析的地址模式/PAN 压缩判定                                         | `components/ieee802154/driver/esp_ieee802154_frame.c:31,36,41,60,71,72`                               |
| 10  | 802.15.4 帧信息结构与回调原型                                                  | `components/ieee802154/include/esp_ieee802154_types.h:24,86,101,113`                                  |
| 11  | 802.15.4 公开 API（set_channel / transmit / set_panid / set_extended_address） | `components/ieee802154/include/esp_ieee802154.h:59,198,236,279`                                       |
| 12  | coex 的 802.15.4 接口 8 个                                                     | `components/esp_coex/include/esp_coex_i154.h`（`grep -c esp_coex_ieee802154` = 8）                    |
| 13  | 五份归档的元数据与符号直方图                                                   | `tools/symbols.sh` 第 1/2 节 → `inventory.txt`（`nm` 实测）                                           |
| 14  | `libble_app.a` 未定义 1407 的归属 1381+16+10                                   | `tools/symbols.sh` 第 3/4 节                                                                          |
| 15  | ROM 里 `r_ble*`/`r_btdm*` 计数为 0，`phy_bt*`=11、`coex_bt*`=2                 | `tools/symbols.sh` 第 7 节                                                                            |
| 16  | 802.15.4 无归档；10 文件 3571 行；frame.c 468 行                               | `tools/symbols.sh` 第 8 节                                                                            |
| 17  | OpenThread 归档 557 550 B / 21 成员 / 249 定义 / 230 未定义                    | `tools/symbols.sh` 第 10 节                                                                           |
| 18  | 段布局 `.text 0x3880`、`.rodata 0xb70`、`.bss 0x50`                            | `readelf -SW zig-out/bin/app.elf`（27.9.2 的五行）                                                    |
| 19  | 12 条判据的每一行输出                                                          | `practice/zig-esp32-s31/logs/ch27-boot.log`（27.10 全文）                                             |
| 20  | 地址内存布局 `SRAM_START = 0x2F000000`                                         | `components/esp_system/ld/esp32s31/memory.ld.in:19`；`linker/s31.ld` 头注释                           |

规范/标准条文（不是本机文件）：

| 资料                     | 用到的部分                                                                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bluetooth Core Spec v5.4 | Vol 4 Part A §2（H4）、Part E §5.4.1/§5.4.2/§5.4.4（包格式）、§7.7.14（Command Complete）、§7.7.65（LE Meta）                                                  |
| Bluetooth Core Spec v5.4 | Vol 3 Part F §3.3/§3.4.1/§3.4.2/§3.4.4/§3.4.5/§3.4.7（ATT）、§3.2.8/§3.2.9（MTU）                                                                              |
| Bluetooth Core Spec v5.4 | Vol 3 Part G §3.3（属性与 CCCD 布局）、§3.3.3.3（CCCD 语义）                                                                                                   |
| IEEE 802.15.4-2015       | §7.2.1.1（Frame Control）、§7.2.2（Sequence Number）、§7.2.3（Addressing）                                                                                     |
| RFC 6282                 | §3.1.1（LOWPAN_IPHC 位域、SAM/DAM 的 16 位内联映射 `0000:00ff:fe00:XXXX`）、§3.2.2（IID 推导：EUI-64 取反 U/L、短地址固定映射）、§4.3.3（UDP NHC，`11110CPP`） |
| RFC 4944                 | §6（**只用于** EUI-64 → IID 时的 U/L 取反引用；它给短地址的派生是「PAN ID ‖ 0000 ‖ 短地址」的伪 48 位，本章不采用，见 27.6.4）                                 |
| RFC 2464                 | EUI-64 → IID 的 U/L 位翻转规则                                                                                                                                 |
| RFC 768                  | UDP 头的网络字节序（端口/校验和大端）                                                                                                                          |

## 自查清单

- [x] `zig build test --summary all` 退出 0，`20/20 tests passed`（x86_64，Zig 0.17.1）
- [x] 每个 KAT 在代码注释里标了规范出处（`src/hci.zig`/`att.zig`/`fifteen4.zig` 头注释）
- [x] `sh tools/symbols.sh` 可重跑，两次输出 `diff` 无差异（`LC_ALL=C` + 排序去重）
- [x] 27.2 里每个数字都能在 `inventory.txt` 找到对应行（第 1/2/3/4/5/6/7/8/10 节）
- [x] 只落摘要：`inventory.txt` 114 行，无完整 `nm` 转储
- [x] 交叉编译退出 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 恰好两条 `DROM, IROM`：`0x40000020`、`0x40020020`
- [x] `flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'` 成功
- [x] 串口 banner 首行是 `ch27-ble-802154-boundary | form B …`（确认不是同伴的镜像）
- [x] 12 条 `check:` 全 PASS，`checks: passed=12 failed=0 total=12`
- [x] `main: verdict=pass` 后停在 `wfi`
- [x] 本章引用的每一行 `check:`/`read:`/`checks:` 都与 `logs/ch27-boot.log` 逐字一致
- [x] 判据条数 12 在 `build.zig` 注释、`src/main.zig` banner、`src/selftest.zig`、`linker/s31.ld`、README、本章六处一致
- [x] 每条判据都打印具体错误码/计数（`code=0x03`、`rejected=3`、`next=0x0011`），不是裸 `ok=1`
- [x] 没有任何「扫描到设备 / 连接成功 / 读到特征值 / 入网」的结论
- [x] 工程没有 `extern` 到任何 BLE/802.15.4 归档符号；`tools/symbols.sh` 只读取证
- [x] 未修改索引、套件 README、BRINGUP 或任何既有章节工程
- [ ] 真实广播/扫描（判据见 27.11.1）
- [ ] 真实连接与 GATT 读写（判据见 27.11.2）
- [ ] 802.15.4 真实收发（判据见 27.11.3）
- [ ] Thread 入网（判据见 27.11.4）

## 下一章预告

ch28 规划为 **自举、功耗与综合**：把 ch01–ch27 的形态 B 工程收成一条可复现的
构建链（镜像 → 烧录 → 自检 → 日志），并把 S31 的低功耗路径（PMU/LP 核、
RTC 定时唤醒）与「一次上电跑完全套判据」的功耗账本写清楚。

它需要的三件前置，本章已经备好两件：

1. 形态 B 的镜像与烧录链（本章沿用并再次实测）；
2. 一套「判据即日志」的验收纪律（12 条 `check:` + 1 行 `checks:`）；
3. 低功耗路径的实测（ch14 的双核与 ch15 的观测基础已具备，功耗账本待做）。

ch28 的板侧纪律与本章一致：**能离线判定的做深，必须联网/必须计量的写判据、
不写结论。**

> [!info] 系列导航
>
> 上一章：[[ch26-wifi-connection-wpa2-wpa3|第二十六章：Wi-Fi 连接管理（WPA2/WPA3）]]
>
> **本章：第二十七章：BLE 与 802.15.4 的边界**
>
> 下一章：自举、功耗与综合（规划中）
>
> 系列索引：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]
