# ch25 Wi-Fi blob 边界：ABI、垫片与「未链接」的诚实回答

> 所属章节：[[ch25-wifi-blob-boundary|第二十五章：Wi-Fi blob 边界与 ABI 垫片]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已跑通**：`zig build test --summary all` → `15/15 tests passed`
>   （2026-11-13，宿主 x86_64 / Zig 0.17.1）。覆盖 ABI 布局、版本/长度拒绝、
>   注册表容量、重复注册、生命周期顺序、FIFO 与环形队列回绕、队列背压、
>   `esp_err_t → Errno` 映射、未链接行为、注销语义、分配会计与重复释放、
>   tick 计量。
> - **镜像合法**：交叉编译退出 0；`esptool elf2image` 打印
>   `Merged 2 ELF sections.`；`image-info` 中 `DROM, IROM` 行正好两条
>   （`0x40000020`、`0x40020020`）。
> - **已上板（2026-11-13）**：13 条判据全部 PASS
>   （`checks: passed=13 failed=0 total=13`、`main: verdict=pass`），
>   原始输出见 [`../logs/ch25-boot.log`](../logs/ch25-boot.log)。
> - **本章没有 Wi-Fi 结论**：`adapter.linked_real_blob` 恒为 `false`，
>   真实 blob 没有链接进来，ch17 的链路仍未闭环。因此**没有**「Wi-Fi 可用」
>   「连上 AP」「blob 已链接」这类结论——本章证明的是**边界本身**：
>   一个闭源协议栈需要调用方提供的接口，能被写成可编译、可断言、可在
>   rv32 上跑通的契约。

## 目的

这个工程只回答一个问题：**「全 Zig」卡在 Wi-Fi 上的时候，卡住的到底是什么？**

S31 的 Wi-Fi 驱动由 7 份预编译归档组成（`esp_wifi/CMakeLists.txt:106`），本章只对
承载 MAC/PP 的 3 份（`libnet80211.a` / `libpp.a` / `libcore.a`）做 `nm` 取证，
再加上它们要求调用方提供的一整套胶水。本章不链接这些 blob，而是：

1. 用 `nm` 把 blob 的对外形状**测出来**（`tools/symbols.sh` → `inventory.txt`）；
2. 把「调用方要提供什么」写成一份带版本号、带长度校验的 ABI
   （`src/blob_abi.zig`）；
3. 写一层垫片，把 blob 的入口表、错误码、上行事件翻译成本工程的调用面
   （`src/adapter.zig`），并在没有 blob 的时候返回 `not_linked`；
4. 用一个模拟 blob 把垫片的每一条分支跑通
   （`src/stub_blob.zig` + 板侧 `src/selftest.zig`）。

### 这个工程明确不做的事

- **不链接真实 Wi-Fi blob**：`linked_real_blob = false`，判据 ⑩ 直接测它。
- **不跑射频**：没有 `esp_wifi_init`、没有 MAC、没有扫描、没有连接。
- **不实现 OS 抽象层的全部入口**：头文件声明 128 行函数指针，S31 有效 126 个；
  本章只实现判据需要的四个
  （`post` / `alloc` / `free` / `now_tick`）。
- **不声称实时性**：日志里的 tick 是适配层里的逻辑计数器，不是墙钟时间。
- **不使用堆**：`HostApi.alloc` 后面是 `.bss` 里 512 字节的 bump 池。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章只需要串口；不需要网线、路由器或 AP                         |

## 文件表

| 路径                 | 角色                                                                      | 代码浏览                                                                        |
| -------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`                                      | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界、6 条 ASSERT                        | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss   | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                                 | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/main.zig)       |
| `src/blob_abi.zig`   | ABI v1.0：`Event`/`Handle`/`HostApi`/`BlobVTable` + 布局断言 + 小端编解码 | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/blob_abi.zig)   |
| `src/adapter.zig`    | 垫片：注册/attach/start/stop/deinit/注销、环形队列、错误码映射、分配会计  | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/adapter.zig)    |
| `src/stub_blob.zig`  | 模拟 blob：入口表 + 错误注入 + 启动即投递 + poll 带时间戳                 | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/stub_blob.zig)  |
| `src/selftest.zig`   | 板侧 13 条判据与三行 `read:` 读数                                         | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/selftest.zig)   |
| `src/host_tests.zig` | `zig build test` 的根：15 个主机侧用例                                    | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/host_tests.zig) |
| `src/hw.zig`         | ROM 打印/忙等/停机的最小集合                                              | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/hw.zig)         |
| `src/log.zig`        | 串口一行输出（`esp_rom_printf`）                                          | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/log.zig)        |
| `src/trap.zig`       | trap 入口（`.trap_ram`）与 panic                                          | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/src/trap.zig)       |
| `tools/symbols.sh`   | blob 符号取证（章节 25.2 的每个数字都由它产出）                           | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/tools/symbols.sh)   |
| `tools/flash.sh`     | 按 `idf-bootstrap/build/flash_args` 烧录，替换 factory 应用行             | [查看](/static/code/#/zig-esp32-s31/ch25-wifi-blob-boundary/tools/flash.sh)     |

## 快速开始

```bash
# 1) 主机侧单测（15 个用例，x86_64）
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG build test --summary all

# 2) 交叉编译
env -u LD_LIBRARY_PATH $ZIG build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall

# 3) 转应用镜像并核对两个装载段
. /tmp/idfenv.sh
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin | grep 'DROM, IROM'

# 4) 烧录（两个 agent/两个终端共用一块板：必须 flock）
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'

# 5) 串口 115200 8N1：先开端口再复位（只拉 RTS 是复位，DTR+RTS 同拉进下载模式）
```

### `idf-bootstrap/` 是一次性产物

`idf-bootstrap/build/`（二级 bootloader、分区表、`flash_args`）被 `.gitignore`
忽略，新克隆里**没有**。需要自己生成一次：

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
```

它不链接本工程的 Zig 代码（`main/app_main.c` 是空实现），只负责产出
bootloader、分区表与 `flash_args`。应用镜像由 `../zig-out/bin/app.bin` 顶替，
偏移（`0x10000`）由 `flash_args` 决定。

## 符号取证：`tools/symbols.sh`

章节 25.2 的**每一个数字**都能用这条命令复现（输出是确定的：排序 + 去重）：

```bash
sh tools/symbols.sh            # 打到标准输出
sh tools/symbols.sh > inventory.txt
```

脚本只读本机 IDF 归档（`~/esp/esp-idf/components/esp_wifi/lib/esp32s31/`
与 `components/esp_coex/lib/esp32s31/`），用
`~/.espressif/tools/riscv32-esp-elf/esp-15.2.0_20251204/.../riscv32-esp-elf-nm`
统计。可覆盖 `IDF_PATH` / `NM` / `RISCV_NM`。

`inventory.txt` 的九个小节：

| 小节 | 内容                                                                          |
| ---- | ----------------------------------------------------------------------------- |
| 1    | 四个归档的字节数、成员数、被剥符号的成员数、sha256 前 16 位                   |
| 2    | 每个库的已定义符号直方图（`T/D/B/R/W` + 小写局部符号）                        |
| 3    | 未定义符号总数，以及「同集合内互相满足 / ROM ld 提供 / 其它 S31 归档 / 剩余」 |
| 4    | ROM 提供的未定义符号样例                                                      |
| 5    | **胶水层要补的全部符号**（ROM 与所有 S31 归档都不提供的剩余集合）             |
| 6    | 每个库未定义符号的形态分类（`ieee80211_*`/`hal_*`/`pm_*`/`g_*`/`__*`/libc）   |
| 7    | ROM 里的 `g_osi_funcs_p`（blob 拿 OS 抽象表的入口）                           |
| 8    | blob 自己导出的 `esp_wifi_*` 公共入口                                         |
| 9    | `libcoexist.a` 对照读数                                                       |

本机实测（2026-11-13，IDF v6.1 / esp-15.2.0_20251204）：

```text
lib=libnet80211.a bytes=1815340 members=50 stripped_members=7
lib=libpp.a       bytes=943030  members=54 stripped_members=17
lib=libcore.a     bytes=4102    members=1  stripped_members=0

unique_undefined_all=1913
provided_by_same_set_libs=1688
provided_by_rom_linker_scripts=473
left_for_idf_c_glue_and_newlib=39
rom-ld:esp32s31.rom.pp.ld:340:g_osi_funcs_p = 0x2f07ff44;
```

完整输出见工程内的 `inventory.txt`（由上面的命令生成）。

## 上板输出

`../logs/ch25-boot.log` 的判据区（原文，13 行）：

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
checks: passed=13 failed=0 total=13
main: verdict=pass, blob boundary verified with stub blob (wfi)
```

## 待闭环项

| 项                                     | 判据（跑什么 / 看什么 / 算过）                                                                               |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| 真实 blob 链接（net80211 + pp + core） | 把三个 `.a` 加进链接，`nm app.elf` 里不再出现 `U g_osi_funcs_p`；`elf2image` 仍打印 `Merged 2 ELF sections.` |
| `esp_wifi_init` 路径                   | 调用 `esp_wifi_init_internal` 后 `not_linked` 消失；判据 ⑩ 的期望从 `not_linked` 翻成 `ok`                   |
| Wi-Fi 连接                             | 依赖 ch17 闭环（TCP/IP 与链路）；板侧日志出现 `sta_connected` 才算过                                         |
| 中断上下文的上行                       | `post()` 在 `mstatus.MIE=1` 下被 ISR 调用仍不丢事件（需要 irqsave 版本）                                     |
| 真实 `now_tick`                        | 接 `esp_timer_get_time` 后，`read: frame ticks` 的含义从「逻辑」变成「微秒」                                 |

## 与相邻章节的关系

本章与 ch24 是**独立重写、仅签名级依赖**：

- ch24 的 MQTT/OTA 只需要「一段字节 + 一个错误码」，它的传输层契约与本章的
  `Event`/`Errno` 形状相容，但**不 import** 本章任何文件；
- 本章的 `HostApi` 形状与 IDF 的 `wifi_osi_funcs_t` 相容（版本字段 + 长度 +
  函数指针表），但**不依赖** IDF 头文件——工程里没有 `#include`，也没有
  C 编译单元；
- 两章共同的下一步都是 ch17：没有链路，MQTT 发不出去，blob 也连不上 AP。
