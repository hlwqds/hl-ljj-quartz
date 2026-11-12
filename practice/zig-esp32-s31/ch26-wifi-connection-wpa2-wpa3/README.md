# ch26 Wi-Fi 连接管理：WPA2/WPA3 的密钥、4-way 与状态机（离线可断言的那一层）

> 所属章节：[[ch26-wifi-connection-wpa2-wpa3|第二十六章：Wi-Fi 连接管理与 WPA2/WPA3]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已跑通**：`zig build test --summary all` → `20/20 tests passed`
>   （2026-11-13，宿主 x86_64 / Zig 0.17.1）。覆盖 RFC 6070 四条 PBKDF2 向量、
>   WPA2 PMK、PTK-384/512、EAPOL 编解码与 MIC 正/反例、重放计数、4-way 顺序机、
>   SAE 的 pwd-seed/pwd-value/F_p 归约/KCK/PMK/PMKID/confirm、扫描候选选择、
>   连接状态机、退避与事件队列。
> - **镜像合法**：交叉编译退出 0；`esptool elf2image` 打印
>   `Merged 2 ELF sections.`；`image-info` 中 `DROM, IROM` 行正好两条
>   （`0x40000020`、`0x40020020`）。
> - **已上板（2026-11-13）**：13 条判据全部 PASS
>   （`checks: passed=13 failed=0 total=13`、`main: verdict=pass`），
>   原始输出见 [`../logs/ch26-boot.log`](../logs/ch26-boot.log)。
> - **本章没有射频结论**：没有 `esp_wifi_init`、没有扫描、没有 AP、没有链路。
>   板侧证据全部来自「自造帧 / 注入路径 / 纯逻辑 / known-answer」。因此**没有**
>   「连上 AP」「扫描到 N 个 AP」「拿到 IP」这类结论；这些是 26.11 的待闭环项。

## 目的

这个工程只回答一个问题：**「Wi-Fi 连接管理」里，哪些部分今天就能写成可断言的代码？**

答案是三层，全部不依赖射频：

1. **密钥层**：passphrase + SSID → PMK（PBKDF2-HMAC-SHA1，4096 轮）
   → PTK（PRF-384 / PRF-512）→ KCK/KEK/TK 的切分；
2. **帧层**：EAPOL-Key 描述符的编/解码、MIC（HMAC-SHA1 截断 16 字节）与
   重放计数的比较、4-way 顺序机（msg1 → msg2 → msg3 → msg4）；
3. **连接层**：扫描候选的选择（去重/过滤/排序）、连接状态机
   （idle→scan→auth→assoc→fourway→connected→reconnect→failed）、
   指数退避 + 抖动 + 上限、事件环形队列的丢最旧语义。

### 这个工程明确不做的事

- **不链接 Wi-Fi/PHY blob**：没有 `libnet80211.a`/`libpp.a`/`libcore.a`/`libphy.a`，
  也没有 `#include` 任何 IDF 头文件。真实 blob 的链接是 ch25 的边界。
- **不跑射频**：没有 `esp_wifi_init`、没有 MAC、没有信标帧、没有 AP。
- **不实现 CCMP/AES**：MIC 算完就结束，不加解密不了帧（本章不解密 GTK）。
- **不实现 SAE 的椭圆曲线**：PWE 的 y 坐标、`scalar-op`/`elem-op`、
  恒定时间实现、H2E、组协商全部**没有**实现（清单见 `src/sae.zig` 的
  `unimplemented` 表，自检打印条数）。本章只做 SAE 的字节层：pwd-seed、
  pwd-value、F_p 归约、F_q 加法、KCK/PMK/PMKID、confirm。
- **不使用堆**：所有缓冲都在 16 KiB 主栈上；`.bss` 实测 16 字节。
- **不声称实时性**：状态机的「毫秒」是逻辑时间（`tick(now_ms)` 由自检给），
  不是墙钟。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章只需要串口；**不需要**网线、路由器或 AP                     |

两块终端/两个 agent 共用一块板时，烧录必须串行化：

```bash
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'
```

## 文件表

| 路径                 | 角色                                                                        | 代码浏览                                                                               |
| -------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`（20 例）                               | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界、6 条 ASSERT                          | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss     | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                                   | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/main.zig)       |
| `src/wpa2.zig`       | PBKDF2→PMK、PRF→PTK、EAPOL 编解码、MIC、重放计数、4-way 顺序机              | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/wpa2.zig)       |
| `src/sae.zig`        | WPA3-SAE 的字节层：pwd-seed/pwd-value、F_p/F_q、KCK/PMK/PMKID、confirm      | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/sae.zig)        |
| `src/conn.zig`       | 连接状态机、事件环形队列（丢最旧）、退避+抖动、扫描候选选择                 | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/conn.zig)       |
| `src/vectors.zig`    | 判据用的常数表（编译期十六进制解码，出处逐条注释）                          | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/vectors.zig)    |
| `src/selftest.zig`   | 板侧 13 条判据与三行 `read:` 读数                                           | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/selftest.zig)   |
| `src/host_tests.zig` | `zig build test` 的根：20 个主机侧用例                                      | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/host_tests.zig) |
| `src/hw.zig`         | ROM 打印/忙等/停机的最小集合                                                | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/hw.zig)         |
| `src/log.zig`        | 串口一行输出（`esp_rom_printf`）                                            | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/log.zig)        |
| `src/trap.zig`       | trap 入口（`.trap_ram`）与 panic                                            | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/src/trap.zig)       |
| `tools/vectors.py`   | 交叉实现向量生成器（CPython hashlib/hmac，产出 `src/vectors.zig` 的每个值） | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/tools/vectors.py)   |
| `tools/flash.sh`     | 按 `idf-bootstrap/build/flash_args` 烧录，替换 factory 应用行               | [查看](/static/code/#/zig-esp32-s31/ch26-wifi-connection-wpa2-wpa3/tools/flash.sh)     |

## 快速开始

```bash
# 1) 主机侧单测（20 个用例，x86_64）
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

# 5) 串口 115200 8N1：先开端口排空残留，再只拉 RTS 复位（DTR+RTS 同拉进下载模式）

# 6) 重新生成向量（改了密码学代码才需要）
python3 tools/vectors.py
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

## 向量从哪来：`tools/vectors.py`

章节 26.3–26.5 的**每一个十六进制常数**都能用这条命令复现：

```bash
python3 tools/vectors.py
```

它是一个**对照实现**，不是被测代码：用 CPython 的 `hashlib.pbkdf2_hmac` /
`hmac` / `hashlib.sha256` 把每个期望值算一遍，与 `src/wpa2.zig` / `src/sae.zig`
的 Zig 实现逐字节对拍。常数分两类：

| 类                     | 例子                                                  | 权威性                                 |
| ---------------------- | ----------------------------------------------------- | -------------------------------------- |
| 公开标准向量           | RFC 6070 的四条 PBKDF2；`password`/`IEEE` 的 WPA2 PSK | 标准文本或长期沿用的公开示例           |
| 本工程固定输入的交叉值 | PTK、EAPOL msg2 的 MIC、SAE 的 pwd-seed/confirm       | **两套独立实现一致**（Zig 与 CPython） |

本机实测（2026-11-13）：

```text
rfc6070[c1]    = 0c60c80f961f0e71f3a9b524af6012062fe037a6
rfc6070[c2]    = ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957
rfc6070[c4096] = 4b007901b765489abead49d926f721d065a429c1
rfc6070[long]  = 3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038
pmk  (password/IEEE) = f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e
ptk512 = 0cb59d207218375a0cc1c4db3cc0736060aad631553eee9dad2e06711528a2e8
         933ef3ea575a37b1ccce47a080b20de18c7d6b7bc7b4c9bf71f755e381e79f3c
mic (msg2, key_info=0x010a, replay=1) = 73e895d1efbcfc3c240b8752b08f41ea
```

SAE 的字段布局照抄本机 IDF 的 hostap 实现
（`components/wpa_supplicant/src/common/sae.c`），所以将来接真实实现时，
替换的是「k 与 commit 元素从哪来」，字节层不用动。

## 上板输出

`../logs/ch26-boot.log` 的判据区（原文，13 行）：

```text
check: pbkdf2 rfc6070 c1=0c60c80f c2=ea6c014d c1_ok=1 c2_ok=1 bad_len=1/1 ok=1
check: ptk prf512=0cb59d207218375a prf384_prefix=1 swap_invariant=1 kck=0cb59d207218375a ok=1
check: eapol mic len=121 mic=73e895d1efbcfc3c vec=1 verify=1 tamper=1 wrong_kck=1 decode=1 ok=1
check: replay accept(1,2)=1 same(2,2)=0 back(2,1)=0 msg1_twice=BadReplay:1 rejects=1 ok=1
check: 4way order msg2_early=1 msg4_early=1 msg3_skip=1 msg3_nokeyinfo=1 ok=1
check: sae pwd-seed=63ab6f8392ff2824 pwd-value=559ea05d3c0ff84d det=1 ctr=1 modp=1 modq=1 ovf=1 ok=1
check: scan in=5 out=3 merged_rssi=-52 order=-40,-52,-88 open_dropped=1 ok=1
check: fsm auth->assoc start=1 scan=1 auth=1 state=assoc reauth=0 idle_auth=0 ok=1
check: fsm fourway->connected assoc=1 fourway=1 done=1 state=connected reset=1 extra=1 ok=1
check: backoff base=1000/2000/4000/8000/8000 jitter=1096/2068/4024/8086/8100 span<=125 cap=8000 ok=1
check: retries max=5 at_cap_state=reconnect retries=6 6th=failed capped=1 ok=1
check: queue cap=8 pushed=11 dropped=3 head_arg=3 tail_arg=10 push_full=dropped_oldest ok=1
check: sae derive kck=047c1f688fc5fe70 pmkid=954a8877fbadc0e3 kdf=1/1/1/1 confirm=1/1 tamper_rej=1 ok=1
```

## 待闭环项

| 项                       | 判据（跑什么 / 看什么 / 算过）                                                                                       |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| 真实 blob 链接           | 见 ch25：`nm app.elf` 里不再出现 `U g_osi_funcs_p`；`elf2image` 仍打印 `Merged 2 ELF sections.`                      |
| 真实扫描                 | `esp_wifi_scan_start` 返回 0，`scan` 事件里的 AP 数与 `selectCandidates` 的输出一致；板侧日志出现真实 BSSID          |
| 真实 4-way               | 打开 `CONFIG_ESP_WIFI_*` 的调试打印，msg1/2/3/4 四条 MIC 校验都过；`conn.Machine` 的 `fourway_ok` 来自回调           |
| SAE 的椭圆曲线           | `src/sae.zig` 的 `unimplemented` 表逐条消掉：PWE 的 y、scalar-op、elem-op、恒定时间实现、H2E、组协商                 |
| 拿到 IP                  | 依赖 ch17（以太网/链路）闭环；判据是 DHCP ACK 后 `conn.State.connected` 且 `ch19` 的地址分配成功                     |
| 中断上下文的真实事件来源 | `post()` 在 ISR 里投递不丢事件；判据是 `queue.dropped` 只在队列真满时增长                                            |
| 浏览页深链               | 本文的 `/static/code/#/…` 链接要等 `npm run code-site` 重新生成后才可点开（主 agent 负责；本工程已被套件 glob 收录） |

## 与相邻章节的关系

本章与 ch25 是**独立重写、仅签名级依赖**：

- ch25 定义的是「blob 要调用方提供什么」（`HostApi`/`Event`/`Errno` 的 ABI 形状），
  本章定义的是「连上之后状态怎么走」；两章的 `Event` **不是同一个类型**，
  也**不互相 import**。真实接起来时，把 blob 的 `WIFI_EVENT` 翻译成本章
  `conn.EventKind` 是适配层的一行 switch，而不是共享结构体。
- 两章共同的下一步都是 ch17：没有链路，ch25 的 blob 连不上 AP，本章的
  「connected」也只能停在状态机里。
- 下一章 [[ch27-ble-802154-boundary]] 把同样的纪律搬到另一种射频上：
  BLE 与 802.15.4 的边界，同样先写「能离线断言的那一层」。
