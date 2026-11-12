# ch24 MQTT 3.1.1 与 OTA 应用协议

> 所属章节：[[ch24-mqtt-ota-application-protocols|第二十四章：MQTT 3.1.1 与 OTA 应用协议]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已跑通**：`zig build test` → `27/27 tests passed`（2026-11-13，
>   宿主 x86_64 / Zig 0.17.1）。已知答案来自 RFC 8032 §7.1 TEST 1（Ed25519
>   的种子/公钥/签名三件套）、FIPS 180-4（SHA-256 的 `abc` 向量）与
>   MQTT 3.1.1 §2.2.3（剩余长度的宽度 1/1/2/2/3/4）。
> - **镜像合法**：交叉编译退出 0；`esptool elf2image` 打印
>   `Merged 2 ELF sections.`；`image-info` 中落在 flash 的 `DROM, IROM`
>   行正好两条：`0x40000020`（`len=0x17980`）与 `0x40020020`（`len=0x02df8`）。
> - **已上板（2026-11-13）**：13 条判据全部 PASS
>   （`checks: passed=13 failed=0 total=13`、`main: verdict=pass`），
>   原始输出见 [`../logs/ch24-boot.log`](../logs/ch24-boot.log)，banner 首行是
>   `ch24-mqtt-ota-application-protocols | form B …`。
> - **本章没有真链路结论**：ch17 的以太网驱动仍未闭环，ch09 的 flash/分区表
>   写入不在本工程范围内。因此**没有**「连上 MQTT broker」「订阅成功」
>   「OTA 升级完成」「固件已写进 flash」这类结论——本章只证明报文编解码、
>   会话时序、清单信任链与 A/B 回滚决策这些**不依赖网络、不写 flash**
>   的部分在 rv32 上给出了与规范一致的结果。

## 目的

这是形态 B 的第十九个工程（按内容计第 24 章）。它只回答一个问题：
**设备接入云端时，真正由我们自己负责的那一层长什么样。**

TLS、TCP、IP 都有现成的实现可以对照；而 MQTT 的报文格式与 OTA 的镜像信任链
是“我们自己写的”，写错一个字节就会表现为 `broker 断开连接` 或
`新固件永远起不来`。本章把它们拆成可判定的零件：

| 层         | 本章交付                                                                    | 为什么必须和另一层同章                                               |
| ---------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| MQTT 报文  | 固定头/剩余长度变长编码/CONNECT/CONNACK/PUBLISH/四个 ACK/SUBSCRIBE/SUBACK   | OTA 的进度与命令都靠 MQTT 承载，报文写错就收不到升级指令             |
| MQTT 会话  | 心跳（keepalive/2 发 PINGREQ、1.5× 判死）、重传窗口（DUP=1）、inflight 背压 | OTA 是大报文，QoS1/2 的重传与窗口是“升级能不能完成”的物理边界        |
| 主题过滤器 | `+`/`#` 的层级语义、父子层规则、`$SYS` 例外、非法过滤器拒绝                 | 订阅写错（`a/#` 与 `a/+` 差一层）会让设备收不到自己的 OTA 主题       |
| OTA 清单   | 版本/长度/SHA-256/Ed25519 签名，四步校验的先后顺序                          | 没有信任链，“升级”就是“让任何人替换你的固件”                         |
| A/B 与回滚 | 内存态槽位状态机：NEW→PENDING_VERIFY→VALID/INVALID/ABORTED，连击失败回滚    | 验签通过 ≠ 能跑；回滚是 OTA 的最后一道保险，和清单校验同属“升级决策” |

本工程交付三个纯逻辑模块 + 一只板侧自检，**全部不需要网络、不需要写 flash**：

| 模块                 | 覆盖内容                                                                                                                                                                                  |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/mqtt.zig`       | 报文类型/flags 校验、剩余长度编码与解码（含 4 字节上限与非最短编码拒绝）、CONNECT/CONNACK/PUBLISH/四个 ACK/SUBSCRIBE/SUBACK/UNSUBSCRIBE/PING/DISCONNECT、主题过滤器合法性与匹配、流式重组 |
| `src/session.zig`    | 连接与拒绝、心跳计时、重传窗口与 DUP 位、inflight 上限背压、QoS2 接收侧去重、`FrameRecorder`（发包录制）                                                                                  |
| `src/ota.zig`        | 108 字节清单的编解码、SHA-256、Ed25519 验签（RFC 8032 向量）、版本单调性、A/B 槽位状态机与回滚                                                                                            |
| `src/selftest.zig`   | 板侧 13 条判据（对应章节 24.10 的判读顺序）                                                                                                                                               |
| `src/host_tests.zig` | `zig build test` 的根：只 import 上面三个纯逻辑模块                                                                                                                                       |

## 工程不做的事

- **不连任何 broker**：没有 MAC/DMA（ch17 未闭环）、没有 TCP 连接、没有 socket。
  会话层的 `Sink` 是一个函数指针，板侧挂的是把字节录进 `.bss` 的录制器。
- **不写 flash**：分区表仍是 `single-app-large`（只有 factory），没有
  `otadata`/`ota_0`/`ota_1`。A/B 槽位是两个内存结构体，bootloader 的真实
  选择规则只作为注释与对照表出现。
- **不实现 broker 侧**：不解析 SUBSCRIBE 的授权、不做 retained message、
  不做遗嘱消息的分发、不做 session 持久化（`clean_session` 恒为 1）。
- **不支持 MQTT 5.0**：没有 properties、没有 receive maximum 字段、
  没有 reason code（3.1.1 用返回码）。5.0 的差异在章节 24.3 里列成表。
- **不做真实 TLS**：MQTT over TLS 是 ch23 的记录层 + 本章的报文，
  本章不把两者接起来（判据见章节 24.11）。
- **不使用堆**：所有缓冲都是 `.bss` 静态对象；没有分配器，也没有
  `OutOfMemory` 分支。
- **不使用中断与多核**：全轮询、`MIE=0`，所以会话状态机不需要锁。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章自检只需要串口；不需要网线、路由器或 broker                 |

## 文件表

| 路径                 | 角色                                                                    | 代码浏览                                                                                    |
| -------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `build.zig`          | 目标串、链接脚本、`zig build test`                                      | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界、6 条 ASSERT                      | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                               | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/main.zig)       |
| `src/selftest.zig`   | 板侧 13 条判据与两行 `read:` 读数                                       | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/selftest.zig)   |
| `src/mqtt.zig`       | 固定头、剩余长度、各类报文编解码、主题匹配、流式重组                    | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/mqtt.zig)       |
| `src/session.zig`    | 会话状态机：心跳、重传、背压、QoS2 去重、发包录制                       | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/session.zig)    |
| `src/ota.zig`        | 清单编解码、SHA-256、Ed25519、A/B 槽位与回滚                            | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/ota.zig)        |
| `src/host_tests.zig` | `zig build test` 的根：27 个用例                                        | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/host_tests.zig) |
| `src/hw.zig`         | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                              | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/hw.zig)         |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump（80 字节帧）                              | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/trap.zig)       |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                               | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/src/log.zig)        |
| `idf-bootstrap/`     | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                | —                                                                                           |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用          | [查看](/static/code/#/zig-esp32-s31/ch24-mqtt-ota-application-protocols/tools/flash.sh)     |

## 快速开始

```bash
cd practice/zig-esp32-s31/ch24-mqtt-ota-application-protocols

ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig

# 1) 主机侧单测（不需要开发板）→ 27/27 tests passed
env -u LD_LIBRARY_PATH $ZIG build test --summary all

# 2) 交叉编译（CPU 串必须写全；写 esp32s31 会 configure 失败）
env -u LD_LIBRARY_PATH $ZIG build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

# 3) ELF → 应用镜像（打印 Merged 2 ELF sections.）
. /tmp/idfenv.sh                       # esptool 5.6 的 python 环境
python -m esptool --chip esp32s31 elf2image --flash-mode dio \
  --flash-size 16MB --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin | grep 'DROM, IROM'

# 4) 烧录（与其它章节共用一块板，必须拿锁）
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'

# 5) 抓串口（先开端口，再只拉 RTS 复位）
python3 - <<'PY'
import serial, time
s = serial.Serial('/dev/ttyUSB1', 115200, timeout=0.2)
time.sleep(0.3); s.reset_input_buffer()
s.setDTR(False); s.setRTS(True); time.sleep(0.1); s.setRTS(False); time.sleep(0.1)
buf = b""; t0 = time.time()
while time.time() - t0 < 15:
    d = s.read(4096)
    if d: buf += d
s.close()
print(buf.decode("utf-8", "replace"))
PY
```

### `idf-bootstrap/` 的生成物

`idf-bootstrap/build/` 被 `.gitignore` 里的 `practice/zig-esp32-s31/**/build*/`
挡住，**新克隆的仓库里没有** bootloader/分区表/flash_args。第一次使用前在
`idf-bootstrap/` 里跑一次 IDF 构建：

```bash
cd idf-bootstrap
. ~/esp/esp-idf/export.sh
idf.py --preview set-target esp32s31
idf.py build
# 产物：build/bootloader/bootloader.bin、build/partition_table/partition-table.bin、
#       build/flash_args（tools/flash.sh 读这个文件里的偏移）
```

该工程只有一个空 `app_main.c`：它的应用镜像不会被烧，`tools/flash.sh`
会把 `flash_args` 里 `0x10000` 那一行换成 `zig-out/bin/app.bin`。

## 主机侧测试

`zig build test` 跑 27 个用例（26 个具名 + 1 个根 `test` 块），其中带已知答案
或明确拒绝分支的十六条：

| 用例                                                                              | 向量/判据出处                                                                  |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `remaining length encodes 0/127/128/16383/16384 at the canonical widths`          | MQTT 3.1.1 §2.2.3 的变长编码（宽度 1/1/2/2/3，另加 2097152 与 2^28-1）         |
| `remaining length rejects overflow, five-byte forms and non-minimal encodings`    | §2.2.3 上限 268435455；4 字节续位与非最短编码都要拒                            |
| `CONNECT byte-level KAT for client_id ch24, clean session, keepalive 60`          | 手工拼的 18 字节报文（对照 `mqtt_msg.c:72-118` 的同一段编码逻辑）              |
| `CONNACK decodes session_present and return code, rejects reserved bits`          | MQTT-3.2.2-1 / MQTT-3.2.2-4                                                    |
| `PUBLISH rejects QoS 3, zero packet id on QoS>0 and trailing garbage`             | MQTT-3.3.1-4（QoS 3 非法）、MQTT-2.3.1-2                                       |
| `the four acknowledgement packets are four bytes each, PUBREL keeps flags 0b0010` | MQTT-3.6.1-1 / MQTT-3.7.1-1                                                    |
| `SUBSCRIBE carries two filters and SUBACK maps granted QoS with 0x80 failure`     | MQTT-3.8.1-1、MQTT-3.9.3-2（只有 0x00/0x01/0x02/0x80）                         |
| `topic filter validity follows the # and + placement rules`                       | §4.7.1（8 条合法 + 8 条非法）                                                  |
| `topic matching: + eats one level, # eats the rest including the parent`          | §4.7.2 与 MQTT-4.7.2-1（`$SYS` 例外）                                          |
| `StreamReader waits while the remaining-length field is incomplete`               | TCP 最常见的切分点：`0x30` / `0x80` / 剩余；严格版报错而可空版返回 `null`      |
| `session keepalive pings at half the interval and fails the link at 1.5x`         | 与 esp-mqtt `process_keepalive`（`mqtt_client.c:787-807`）同构                 |
| `session enforces the inflight window and frees it on PUBACK (backpressure)`      | 窗口 = 4，第 5 条 `error.InflightFull`；QoS0 不占窗口                          |
| `sha256 of abc matches the FIPS 180-4 vector`                                     | FIPS 180-4 / NIST 的 `ba7816bf…0015ad`                                         |
| `Ed25519 fixture key pair reproduces RFC 8032 7.1 TEST 1`                         | RFC 8032 §7.1：种子→公钥→空消息签名的三件套逐字节一致                          |
| `OTA manifest verifies a sealed image and rejects every tamper path`              | 六条拒绝分支：长度、摘要、版本号改动、签名翻位、魔数、降级                     |
| `A/B: three consecutive runtime failures roll back from B to A`                   | 与 `ESP_OTA_IMG_INVALID` + `esp_ota_mark_app_invalid_rollback_and_reboot` 同构 |

## 静态缓冲的账

主栈 16 KiB（`_stack_size = 0x4000`），工作区全在 `.bss`（实测 `0x1ca0 = 7328` 字节）：

| 缓冲         | 大小 | 用途                                              |
| ------------ | ---- | ------------------------------------------------- |
| `g_wire`     | 512  | 一条出站报文的编码缓冲                            |
| `g_rx`       | 512  | 入站报文（自造）                                  |
| `g_stream`   | 512  | `StreamReader` 的重组缓冲                         |
| `g_image`    | 512  | OTA 镜像副本（篡改用）                            |
| `g_manifest` | 108  | OTA 清单                                          |
| `g_rec`      | 5164 | `FrameRecorder`：10 帧 × 512 字节 + 长度表 + 计数 |

实测 `.bss = 0x1ca0`（逐项相加 2048 + 108 + 5164 + 8 = 7328，与实测一致）、
`.trap_ram = 0x6c`（在 `0x2f000000`）、
`.flash.text = 0x17980`、`.flash.rodata = 0x1c20`。放 `.bss` 而不是栈上：
Ed25519 验签的 Edwards25519 标量乘会吃掉几 KiB 栈，再叠 512 字节镜像副本
就会踩穿 16 KiB 主栈，表现为 `Store access fault` 而不是可归因的失败。
