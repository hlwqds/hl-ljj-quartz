# ch23 TLS 记录层、密钥派生与 HTTP/1.1

> 所属章节：[[ch23-tls-http|第二十三章：TLS 记录层、密钥派生与 HTTP/1.1]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已跑通**：`zig build test` → `32/32 tests passed`（2026-11-13，
>   宿主 x86_64 / Zig 0.17.1）。已知答案分别取自 RFC 5869 A.1（HKDF）、
>   RFC 7748 §6.1（X25519）、NIST SP 800-38D（AES-128-GCM），
>   RFC 8446 §7.1（HkdfLabel 结构）用「手工拼字节 vs 本模块输出」对拍。
> - **镜像合法**：交叉编译退出 0；`esptool elf2image` 打印
>   `Merged 2 ELF sections.`；`image-info` 中落在 flash 的 `DROM, IROM`
>   行正好两条（`0x40000020`、`0x40020040`，见下文「DROM 起点」）。
> - **已上板（2026-11-13）**：13 条判据全部 PASS
>   （`checks: passed=13 failed=0 total=13`、`main: verdict=pass`），
>   原始输出见 [`../logs/ch23-boot.log`](../logs/ch23-boot.log)。
> - **本章没有真链路结论**：ch17 的以太网驱动仍未闭环，ch22 的 socket/事件
>   循环尚在实施。因此**没有**「HTTPS GET 成功」「完整 TLS 握手通过」
>   「浏览器访问板端页面」这类结论——本章只证明记录层/密钥派生/AEAD/DER/
>   HTTP 解析这些**不依赖网络**的部分在 rv32 上给出了与规范一致的结果。

## 目的

这是形态 B 的第十八个工程（按内容计第 23 章）。它只回答一个问题：
**「加密」这一段在最小可用协议栈里究竟由哪些可判定的零件组成。**

上一章（ch22）把 socket 与事件循环做完：谁来等、等什么、怎么把字节交给
上层。本章紧接着处理「交给上层的字节到底是什么格式」，并选择把两件事
放在一起：

| 层               | 本章交付                                                            | 为什么必须和另一层同章                                                |
| ---------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------- |
| TLS 1.3 记录层   | 头 5 字节的编解码、2^14+256 的长度上下界、分片、跨记录握手重组      | 没有记录层就没有“一段可交付给上层的数据”，HTTP 的解析器不知道边界在哪 |
| TLS 1.3 密钥派生 | HKDF-Extract/Expand、`tls13 ` 前缀的 `HkdfLabel`、traffic secret 链 | 密钥不在记录层出现，但它决定“哪条记录能用哪个 key/iv 解”              |
| ECDHE            | X25519（RFC 7748 §6.1 向量）                                        | 是 `handshake_secret` 的 IKM                                          |
| AEAD             | AES-128-GCM + TLS nonce/AD 规则                                     | 记录层与密钥派生唯一的“汇合点”                                        |
| X.509            | DER 子集解析 + ECDSA 自洽验签                                       | 证明“对端是谁”；没有它，TLS 只是加密管道                              |
| HTTP/1.1         | 请求行/首部/`Content-Length`/chunked/keep-alive + 响应构造          | 是 TLS 的**可用性证明**：能解出一个请求，才算这条链有用               |

本工程交付六个纯逻辑模块 + 一只板侧自检，**全部不需要网络**：

| 模块                      | 覆盖内容                                                                                                                     |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `src/tls_record.zig`      | `ContentType`、`legacy_record_version`、长度上限 `2^14+256`、`Splitter` 分片、`MessageReader` 跨记录重组、握手头 4 字节分帧  |
| `src/tls_keyschedule.zig` | `extract`/`expand`、`HkdfLabel` 编码、`expandLabel`、`deriveSecret`、handshake/application secret 完整链（不实现握手状态机） |
| `src/x25519.zig`          | RFC 7748 §6.1 两组向量、低阶点拒绝（输出全零）、DH 对称性                                                                    |
| `src/aead.zig`            | AES-128-GCM 加封/解封、TLS 1.3 nonce（iv XOR seq）、additional data（记录头）、`key`/`iv` 派生                               |
| `src/cert.zig`            | DER 构造（fixture）+ 解析（SEQUENCE/SET/INTEGER/OID/BIT STRING/UTCTime/SAN）+ ECDSA-P256 自洽验签                            |
| `src/http.zig`            | 请求行/首部解析、`Content-Length`、chunked 解码、keep-alive 判定、响应构造                                                   |
| `src/selftest.zig`        | 板侧 13 条判据（对应章节 23.10 的判读顺序）                                                                                  |
| `src/host_tests.zig`      | `zig build test` 的根：只 import 上面六个纯逻辑模块                                                                          |

## 工程不做的事

- **不实现完整 TLS 握手状态机**：没有 ClientHello 的编解码、没有
  `supported_versions`/`key_share` 扩展解析、没有 Finished 的 verify_data、
  没有 session ticket。本章只到 “从共享秘密 + 两个转录哈希派生 traffic secret”。
- **不发任何真实报文**：没有 MAC/DMA（ch17 未闭环）、没有 TCP（ch20 是纯状态机）、
  没有 socket（ch22 未落地）。板侧自检的数据全部是自造字节。
- **不做证书链验证**：没有信任锚、没有 CA store、不做有效期与当前时间的比较
  （板上没有可信时钟）。
- **不支持 RSA / Ed25519 / 压缩点 / 多 RDN**：只认 P-256 + uncompressed SEC1。
- **不做 URL 解码、query 解析、请求体读取**：HTTP 解析器只报告长度，不消费 body。
- **不使用堆**：所有缓冲都是 `.bss` 静态对象；没有分配器，也没有 `OutOfMemory` 分支。
- **不使用浮点**：所有派生与判定都是整数运算（rv32 的 `f` 扩展只用于链接 ABI，自检不用）。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章自检只需要串口；不需要网线、路由器或抓包                    |

## 文件表

| 路径                           | 角色                                                                    | 代码浏览                                                                        |
| ------------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `build.zig`                    | 目标串 + 链接脚本 + `zig build test` + `gen-fixture`                    | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/build.zig)                    |
| `linker/s31.ld`                | 两个 flash 段、`.trap_ram`、堆/栈边界、5 条 ASSERT                      | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/linker/s31.ld)                |
| `src/start.zig`                | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/start.zig)                |
| `src/main.zig`                 | 板侧编排：banner → 自检 → verdict → `wfi`                               | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/main.zig)                 |
| `src/selftest.zig`             | 板侧 13 条判据与两行 `read:` 读数                                       | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/selftest.zig)             |
| `src/tls_record.zig`           | 记录层头、长度上限、分片、跨记录重组                                    | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/tls_record.zig)           |
| `src/tls_keyschedule.zig`      | HKDF-Extract/Expand、HkdfLabel、Expand-Label、Derive-Secret、密钥链     | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/tls_keyschedule.zig)      |
| `src/x25519.zig`               | X25519 已知答案与调用面                                                 | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/x25519.zig)               |
| `src/aead.zig`                 | AES-128-GCM、TLS nonce/AD、key/iv 派生                                  | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/aead.zig)                 |
| `src/cert.zig`                 | DER 构造/解析、SAN、ECDSA 验签                                          | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/cert.zig)                 |
| `src/http.zig`                 | HTTP/1.1 请求解析、chunked、keep-alive、响应构造                        | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/http.zig)                 |
| `src/host_tests.zig`           | `zig build test` 的根：六个纯逻辑模块 + 端到端用例                      | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/host_tests.zig)           |
| `src/gen_cert_fixture.zig`     | `zig build gen-fixture`：把自签证书写成 DER                             | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/gen_cert_fixture.zig)     |
| `src/testdata/sample-cert.der` | 419 字节的自签证书 fixture（`@embedFile` 进固件）                       | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/testdata/sample-cert.der) |
| `src/hw.zig`                   | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                              | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/hw.zig)                   |
| `src/trap.zig`                 | `.trap_ram` 入口 + panic dump（80 字节帧）                              | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/trap.zig)                 |
| `src/log.zig`                  | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                               | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/src/log.zig)                  |
| `idf-bootstrap/`               | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                | —                                                                               |
| `tools/flash.sh`               | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用          | [查看](/static/code/#/zig-esp32-s31/ch23-tls-http/tools/flash.sh)               |

## 主机侧测试

```bash
cd practice/zig-esp32-s31/ch23-tls-http
zig build test        # 32/32 tests passed
```

32 个用例里有 21 个带已知答案或明确的拒绝分支，逐条列出（这是“证据”而不是
“覆盖率”）：

| 用例                                                                 | 向量/判据出处                                                                  |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `RFC 5869 A.1 extract`                                               | RFC 5869 附录 A.1（SHA-256）：`PRK = 07770936…b3e5`                            |
| `RFC 5869 A.1 expand`                                                | 同上：`OKM = 3cb25f25…5865`（42 字节）                                         |
| `HkdfLabel layout carries the tls13 prefix and lengths`              | RFC 8446 §7.1 的 `HkdfLabel` 结构（`label<7..255>` 首字节 = 6+len）            |
| `RFC 7748 6.1 vector 1`                                              | RFC 7748 §6.1 第一组（输出 `c3da5537…8552`）                                   |
| `RFC 7748 6.1 vector 2`                                              | RFC 7748 §6.1 第二组（输出 `95cbde94…7957`）                                   |
| `all-zero peer key is rejected`                                      | RFC 8446 §7.4.2：共享秘密全零必须拒绝                                          |
| `DH symmetry: a*b == b*a`                                            | 固定 seed 派生两对密钥，双向共享秘密相同                                       |
| `NIST GCM: empty plaintext tag`                                      | NIST SP 800-38D Test Case 1：`T = 58e2fcce…455a`                               |
| `NIST GCM: 16 zero bytes`                                            | Test Case 2：`C = 0388dace…fe78`、`T = ab6e47d4…bddf`；含 tag 篡改/AD 篡改拒绝 |
| `nonce XORs only the low 8 bytes`                                    | RFC 8446 §5.3 的 nonce 构造                                                    |
| `record length limit is 2^14+256`                                    | RFC 8446 §5.2：`16640` 收、`16641` 拒                                          |
| `record version guard rejects nonsense versions`                     | RFC 8446 §5.1：`legacy_record_version` 判定                                    |
| `handshake message fragmented across three records…`                 | 4 字节握手头 + 跨记录重组（自造 3004 字节消息）                                |
| `two handshake messages inside one record are both delivered`        | 一条记录里两条消息的顺序交付                                                   |
| `expand-label equals manual HKDF-Expand over a hand-built HkdfLabel` | 手工拼 info 与本模块输出逐字节相同                                             |
| `certificate chain: parse → verify → tamper`                         | fixture 解析 + ECDSA 验签 + 篡改拒绝                                           |
| `chunked decoding`                                                   | RFC 9112 §7.1：`4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n` → `Wikipedia`            |
| `http framing rules`                                                 | RFC 9112 §6.1：`Content-Length` 与 `chunked` 并存必须拒绝                      |
| `RFC 8448 3: handshake key schedule matches the trace`               | RFC 8448 §3：early/derived/handshake/c hs/s hs 五项                            |
| `our record constants equal std.crypto.tls's`                        | 与 `std/crypto/tls.zig:41-43` 的 5 / 2^14 / 2^14+256 对拍                      |

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
# 本机实测路径
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
. /tmp/idfenv.sh     # IDF v6.1 的 python env（esptool 5.6）
```

## 构建

### 1. 主机侧单测（不需要开发板）

```bash
env -u LD_LIBRARY_PATH $ZIG build test --summary all
# Build Summary: 3/3 steps succeeded; 32/32 tests passed
```

### 2. 应用 ELF（纯 Zig，无 idf.py）

```bash
env -u LD_LIBRARY_PATH $ZIG build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
# zig-out/bin/app.elf
```

### 3. 应用镜像（必须看到 `Merged 2 ELF sections.`）

```bash
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
# Merged 2 ELF sections.
# Successfully created ESP32-S31 image.

python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin | grep 'DROM, IROM'
#       0  0x198b0  0x40000020  0x00000018  DROM, IROM
#       3  0x04160  0x40020040  0x00020038  DROM, IROM
```

### 4. bootloader 与分区表（供应商步骤）

`idf-bootstrap/` 里已经带着一次 IDF 构建的产物
（`build/bootloader/bootloader.bin`、`build/partition_table/partition-table.bin`、
`build/flash_args`），与 ch19–ch22 共用同一套。要重新生成：

```bash
cd idf-bootstrap && idf.py --preview set-target esp32s31 && idf.py build && cd ..
```

### 5. 烧录（必须独占串口，与其他章节共用板子时用 flock）

```bash
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'
```

### 6. 抓串口（先开端口再复位）

```python
import serial, time
s = serial.Serial('/dev/ttyUSB1', 115200, timeout=0.2)
s.setDTR(False); s.setRTS(True); time.sleep(0.1); s.setRTS(False); time.sleep(0.1)
buf = b""
t0 = time.time()
while time.time() - t0 < 15:
    d = s.read(4096)
    if d:
        buf += d
s.close()
open('../logs/ch23-boot.log', 'wb').write(buf)
```

## 运行（2026-11-13 板侧实测 12/12）

```text
ch23-tls-http | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: tls1.3 record/keyschedule + x25519 + aes-128-gcm + x509 der + http1.1
note: no network, no real handshake - ch17 link and ch22 event loop pending
host: 32 unit tests via 'zig build test'
check: record frag records=3 lens=1024,1024,956 reasm=1 ok=1
check: record limit max=16640 exact=1 over=0 raw=0 ok=1
check: hkdf-extract rfc5869 prk=07770936 ok=1
check: hkdf-expand-label label_len=9 info_len=15 out=8a5be387 manual=1 ok=1
check: x25519 rfc7748 v1=c3da5537 v2=95cbde94 loworder=rejected ok=1
check: aes-gcm nist tag=ab6e47d4 ct=0388dace tamper=2/2 ok=1
check: x509 der cn=ch23-stub.local issuer=ch23-stub.local san=3 first=ch23.local nb=2026-01-01 ok=1
check: x509 verify ok=1 tampered=rejected fp=00f3df22 ok=1
check: http request GET /index.html q=x=1 hdrs=3 keep=1 ok=1
check: http chunked decoded=9 body=Wikipedia bad=rejected ok=1
check: http keepalive 1.1=1 1.1+close=0 1.0=0 1.0+keep=1 ok=1
check: http response status=200 cl=9 total=97 conn=keep-alive close=1 ok=1
check: rfc8448 chain early=33ad0a1c hs=1dc826e9 c_hs=b3eddb12 ok_all=1 ok=1
read: traffic c_ap=ef97e3ec s_ap=b7c74e70 master=11c9962e
read: x25519 pub(len=32)=9a4503a9
checks: passed=13 failed=0 total=13
main: verdict=pass, tls/http primitives verified off-link (wfi)
main: halting (wfi)
```

判读规则（细节见章节 23.10）：

- `record frag 3/1024,1024,956`：一条 3004 字节握手消息被切成三条记录，
  第 3 条是余数（3004−2048=956），重组后逐字节回到原样；
- `prk=07770936`：RFC 5869 A.1 的前 4 字节，错一位都不算过；
- `v1=c3da5537 v2=95cbde94`：RFC 7748 §6.1 两组输出前缀；
- `tag=ab6e47d4 ct=0388dace`：NIST SP 800-38D Test Case 2 的 tag/密文前缀；
- `tamper=2/2`：tag 篡改、AD 篡改各一次，都必须被拒绝；
- `fp=00f3df22`：fixture 的 SHA-256 前缀（完整值见章节 23.6）；
- `check: http …` 五行：请求/分块/持久连接/响应构造各自独立判据；
- `passed=13 failed=0` 之后才打印 verdict；`failed>0` 走 `panic:` 并停在 `wfi`。

> [!note] `read:` 行是读数，不是判据
> `traffic`/`x25519 pub` 两行的作用是“让日志能被人肉眼对拍”，不参与
> `checks:` 计数。它们是固定 seed 派生的，换 seed 就会变。

## 与相邻章节的接口

| 章节 | 提供                                          | 本章怎么用                                                                           |
| ---- | --------------------------------------------- | ------------------------------------------------------------------------------------ |
| ch16 | `pbuf` / 零拷贝发送栈                         | 不用：本章不碰链路层                                                                 |
| ch17 | 以太网收发帧                                  | 不用（未闭环）；真链路联调时才需要                                                   |
| ch18 | IPv4/ARP/ICMP                                 | 不用                                                                                 |
| ch19 | UDP/DHCP/DNS                                  | 不用（TLS 只跑 TCP）                                                                 |
| ch20 | TCP 状态机、seq/ack、重传                     | 本章的字节流最终由它承载，但本章不调用它                                             |
| ch21 | 拥塞控制律 + 确定性仿真                       | 决定“发多快”，与 TLS 无关                                                            |
| ch22 | socket API 与事件循环（独立重写，签名级依赖） | 本章的 `parseRequest` 需要它给出“一次读到了多少字节”；本章只定义签名，不调用它的实现 |
| ch23 | 本章：TLS 记录层/密钥派生/AEAD/DER/HTTP 解析  | 给 ch24（MQTT/OTA）提供“怎么把一条消息装进 TLS 记录”的形状                           |
| ch24 | MQTT 3.1.1 编解码与 OTA 分片（规划中）        | 会复用本章的记录分片与应答构造                                                       |

**与 ch22 是独立重写、只有签名级依赖**：本章不 import ch22 的任何文件，
也不假设它的事件循环存在；`http.parseRequest(data)` 的输入是“一次已读到的
字节”，谁来读、读完怎么回到循环，是 ch22 的职责。

## 证据与边界

1. **DROM 段起点是 0x40020040，不是 0x40020020。** 这是本章与 ch19–ch22
   唯一不同的镜像事实，原因可追：`std/crypto/aes/soft.zig:746-750` 里五张
   AES S-box/LUT 写了 `align(64)`（让加解密用不同 L1 cache line），它们进
   `.rodata` 之后把整节的对齐抬到 64，lld 因此把输出节推到 64 的整数倍。
   bootloader 真正检查的是页内偏移同余
   （`esp_image_format.c:904`：`segment_data_offs % mmu_page_size ==
load_addr % mmu_page_size`），镜像里 `paddr=0x30040 / vaddr=0x40020040`
   同余成立，实测启动并跑完 13 条判据。ch21 的 `0x40020020` 只是它的 rodata
   恰好只对齐到 16 的**结果**，不是 bootloader 的硬要求。
2. **为什么板侧只保留 13 条判据**：每条都必须对应一个“换成别的实现就会失败”
   的判据。板侧不做握手、不发包，所以没有不可归因的失败源。
3. **为什么主机测试是权威**：HKDF/GCM/X25519/DER 的字节都来自规范，
   与芯片无关；板上出错时很难区分“逻辑错”还是“布局错”。
4. **为什么 fixture 是自签的**：没有 CA store、没有可信时钟。自签证书能证明
   “DER 解析 + ECDSA 验签的调用面是对的”，不能证明“这个公钥被谁信任”。

## 待真机验证（需要 ch17 + ch22 闭环）

- [x] `zig build test` 退出 0（32/32）
- [x] 交叉编译退出 0（`ReleaseSmall`）
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 恰好两条 `DROM, IROM`：`0x40000020`、`0x40020040`
- [x] `bash -n tools/flash.sh` 退出 0
- [x] 串口 banner 首行为 `ch23-tls-http | form B …`
- [x] 13 条判据全 PASS（`../logs/ch23-boot.log`）
- [ ] 真实 TLS 1.3 握手（需要 ch17 链路 + ch22 socket；判据：与
      `openssl s_server` 完成一次 1-RTT 握手，ServerHello 的 key_share
      与本工程的 X25519 输出一致，且每条记录能被 AES-128-GCM 正确解封）
- [ ] 一次真实 HTTPS GET（判据：`GET / HTTP/1.1` 的 200 响应被本工程
      `parseRequest`/`decodeChunked` 正确切分，Content-Length 与 body 长度一致）
- [ ] 证书链验证（需要 CA store 与时钟；判据：对一个公开根签发的叶证书
      走完链式验签，并对过期证书拒绝）
