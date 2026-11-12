# ch16 协议栈架构、缓冲与零拷贝：先把“内存归谁”说清楚

> 所属章节：[[ch16-stack-architecture-zero-copy|第十六章：协议栈架构、缓冲与零拷贝]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已全部跑通**：`zig build test` → `All 55 tests passed`（54 个具名用例 +
>   根文件容器 test），2026-11-13，宿主 x86_64 / Zig 0.17.1。
> - **板侧镜像已生成**：`zig build -Dtarget=riscv32-freestanding-eabihf ...` 退出 0，
>   `esptool elf2image` 打印 `Merged 2 ELF sections.`，`image-info` 的 Segments 表
>   正好两个 flash 段：`0x40000020`（DROM, IROM）与 `0x40020020`（DROM, IROM）。
> - **板侧已上板（2026-11-13）**：自检 6 条全部 PASS（`loopback tx frames=1 bytes=49 identical=1`、
>   `udp … cksum=0x5a60 verified=1`、`rx kind=ipv4 … ok=1`），原始输出见 `../logs/ch16-boot.log`。
>
> 工程能在主机上跑单测、能在板上编出合法镜像；**唯一没有证据的是“串口里的那些
> 数字”**。不要把它当成已验收的板级结果。

## 目的

这是形态 B 的第十一个工程，也是本系列第一次把**主要交付放在主机侧**：

- `zig build test` 跑 55 个用例，覆盖协议栈里最容易写错、又最容易在没有硬件时
  验证的部分：**pbuf 链与引用计数、校验和、首部编解码、netif 输出路径、时间轮**；
- 板侧只留最小闭环：构造一帧以太网/IPv4/UDP，经 loopback 走一圈，验证同一份
  纯逻辑代码在 rv32 + 真实 SRAM 布局下仍自洽。

本章回答的四个问题：

1. **一段报文在层之间传递时，谁拥有它的内存？** pbuf 池 + 引用计数 + 显式
   `eat`/`toLinear`，把“复制发生在哪”变成可数的计数器（`linearize_copies`）。
2. **校验和能不能不复制就算？** 能。`Sum` 支持跨片连续字流，链上求和与连续
   缓冲求和结果必须一致（有测试钉死）。
3. **为什么校验和要增量更新？** TTL 递减、NAT 改写地址时，RFC 1624 的公式
   避免整包重算，也避免 -0/+0 的经典错误。
4. **计时器为什么用时间轮？** 排序链表的插入是 O(n)；哈希时间轮把“到期”变成
   `expire_at % slots`，tick 只看一个槽。RTO 重传（ch20）直接建在它上面。

## 工程不做的事

- **没有 MAC/PHY 驱动**：不读 MDIO、不配 RGMII、不建 DMA 描述符环（ch17）。
- **没有 IPv4 转发/分片重组/ARP 缓存**：只做首部编解码与严格校验（ch18）。
- **没有 UDP/TCP 状态机**：UDP 只有首部与校验和，TCP 只有 20 字节首部编解码（ch19/ch20）。
- **板侧不开中断**：`MIE = 0`，没有 tick；时间轮靠代码手动 `tick()` 推进。
- **不使用通用分配器**：pbuf 池是编译期定容的，池空即 `error.NoSpace`。
- **不提供需要 root 的 TAP 脚本**：TAP 需要 root 与 `ip tuntap`，本章把它
  写成可选的验证路径（见章节 16.2 的命令片段），主机单测不依赖它。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 只需串口。本章不需要以太网线、不需要示波器                      |

## 文件表

| 路径                  | 角色                                                                              | 代码浏览                                                                                   |
| --------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `build.zig`           | 目标串 + 链接脚本 + `zig build test`（五个纯逻辑模块）                            | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/build.zig)           |
| `linker/s31.ld`       | 两个 flash 段、`.trap_ram`、堆/栈边界符号、四条 ASSERT                            | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/linker/s31.ld)       |
| `src/start.zig`       | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss → `mtvec` | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/start.zig)       |
| `src/main.zig`        | 板侧编排：banner → 自检 → verdict → `wfi`                                         | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/main.zig)        |
| `src/selftest.zig`    | 板侧 6 条判据：帧构造、loopback、首部解析、校验和验证、接收分派                   | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/selftest.zig)    |
| `src/pbuf.zig`        | pbuf 池/链/引用计数/`eat`/`toLinear`；14 个主机侧用例                             | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/pbuf.zig)        |
| `src/checksum.zig`    | RFC 1071 反码和、伪首部、RFC 1624 增量更新；10 个用例                             | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/checksum.zig)    |
| `src/headers.zig`     | 以太网/IPv4/UDP/TCP 首部编解码与严格校验；9 个用例                                | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/headers.zig)     |
| `src/netif.zig`       | netif 抽象、MTU、`sendPbuf` 的零拷贝/线性化边界、输入分派；9 个用例               | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/netif.zig)       |
| `src/timer_wheel.zig` | 哈希时间轮（到期/取消/句柄复用/回绕）；12 个用例                                  | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/timer_wheel.zig) |
| `src/host_tests.zig`  | `zig build test` 的根：只 import 纯逻辑模块                                       | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/host_tests.zig)  |
| `src/hw.zig`          | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                                        | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/hw.zig)          |
| `src/trap.zig`        | `.trap_ram` 入口 + panic dump（80 字节帧）                                        | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/trap.zig)        |
| `src/log.zig`         | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                                         | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/src/log.zig)         |
| `idf-bootstrap/`      | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                          | —                                                                                          |
| `tools/flash.sh`      | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                    | [查看](/static/code/#/zig-esp32-s31/ch16-stack-architecture-zero-copy/tools/flash.sh)      |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置
single-app-large）、没有 `components/`、没有 `run.log`（真机未跑）。
生成物 `zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 不入库。

## 主机侧测试

```bash
cd practice/zig-esp32-s31/ch16-stack-architecture-zero-copy
zig build test --summary all
zig test src/host_tests.zig        # 想立刻看到 "All 55 tests passed" 时用这个
```

分布（54 个具名用例，另加根文件容器 test，共 55）：

| 模块              | 用例数 | 代表用例                                                                 |
| ----------------- | -----: | ------------------------------------------------------------------------ |
| `pbuf.zig`        |     14 | `eat: 跨块剥首部`、`eat: 被共享的节点不能归还`、`toLinear: 计数一次拷贝` |
| `checksum.zig`    |     10 | `RFC 1071 示例 → 0x220d`、`增量更新等于整包重算（TTL 64→63）`            |
| `headers.zig`     |      9 | `ipv4: 拒绝版本错误、IHL<5、总长过短、缓冲区截断`、`tcp: 标志位位序`     |
| `netif.zig`       |      9 | `单块 pbuf 的发送是零拷贝`、`多块 pbuf 必须线性化，计数一次`             |
| `timer_wheel.zig` |     12 | `跨度大于槽数（17 > 8）也能准时到期`、`到期后旧句柄不会误杀新计时器`     |

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh
zig version   # 必须 0.17.x
```

## 构建

### 1. 主机侧单测（不需要开发板）

见上。测试只编译 `src/host_tests.zig`，它只 import 五个纯逻辑模块，
不引用 `hw.zig`/`start.zig`/`trap.zig`。

### 2. 应用 ELF（纯 Zig，无 idf.py）

```bash
zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

### 3. 应用镜像（必须看到两个 `DROM, IROM` 段）

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`Segments Information` 里必须正好两行落在 flash：`0x40000020`
（`.flash.text`）与 `0x40020020`（`.flash.rodata`）。S31 的二级 bootloader 在
`SOC_MMU_DI_VADDR_SHARED=1` 下断言 `rom_index == 2`，少一个或三个 flash 段都会
`Assert failed`。（SRAM 段与 PADDING 段不算 flash 段。）

### 4. bootloader 与分区表（供应商步骤）

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

产物：`idf-bootstrap/build/bootloader/bootloader.bin`、
`idf-bootstrap/build/partition_table/partition-table.bin`、`idf-bootstrap/build/flash_args`。

### 5. 烧录

```bash
sh tools/flash.sh /dev/ttyUSB0     # Linux
```

## 运行（2026-11-13 板侧实测）

串口 115200 8N1 打开 UART0（GPIO58/59）。下面是目标形态，不是实测日志：

```text
ch16-stack-architecture-zero-copy | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: netif + eth/ipv4/udp headers + checksum, no MAC/IRQ (pbuf/wheel are host-only)
host: 55 unit tests via 'zig build test' (authoritative for pbuf/wheel/checksum)
frame: eth 14 + ipv4 20 + udp 8 + payload 7 = 49B
check: loopback tx frames=1 bytes=49 identical=1 ok=1
check: eth ethertype=0x800 dst=02:00:00:00:00:01 ok=1
check: ipv4 ver=4 ihl=5 ttl=64 proto=17 total=35 cksum=0x???? ok=1
check: udp sport=40000 dport=7 len=15 cksum=0x???? verified=1 ok=1
check: payload "zig/s31" offset=8 ok=1
check: rx kind=ipv4 src=192.168.1.10 frames=1 ok=1
checks: passed=6 failed=0 total=6
main: verdict=pass, skeleton idle (board run 待真机验证)
main: halting (wfi)
```

判读规则：

- `frame` 行给出**帧的真实长度**（`14+20+8+payload`），与后面的
  `total`/`len` 字段必须对得上；对不上说明首部写错了。
- `cksum=0x????` 是目标形态的占位符：具体数值必须来自真机，**不要从别处抄**。
- `udp ... verified=1` 的依据是「伪首部 + 数据报」求和为 0，而不是某个固定数字；
  它同时检查了 `len=15` 与 `dport=7`。
- `checks: passed=6 failed=0` 之后才打印 verdict；`failed>0` 时程序走
  `panic:` 路径并停在 `wfi`。
- pbuf 链与时间轮**不在板侧日志里**：它们的判据（`copies=0`/`copies=1`、
  到期顺序、句柄复用）由 `zig build test` 的 26 个用例覆盖。板侧只证明
  “首部/校验和/netif 在 rv32 上仍自洽”。

## 证据与边界

1. **为什么主机测试是权威**：pbuf 的引用计数、校验和的奇偶字节、时间轮的
   回绕，都是**纯逻辑**，与芯片无关。这类代码一旦在板上出错，你很难判断是
   逻辑错还是硬件/编译错。先在主机上钉死，板侧只剩“能不能跑起来”。
2. **为什么板侧只保留一条闭环**：板侧多做一件事就多一个“可能错但无法归因”
   的来源。本章板侧不打中断、不读 MAC、不做时间测量，所有输出都可以用
   静态推理复现。
3. **为什么 `alloc`/`eat` 不做“部分释放”**：共享节点被 `eat` 吃掉时返回
   `error.Shared`，而不是悄悄归还——后者会让另一条链指向空闲块，是典型的
   use-after-free。宁可让调用方看见错误。
4. **为什么校验和不放在 `netif`**：`netif` 只搬运字节；校验和属于传输层/网络层
   语义。把它们混在一起，会让“关闭校验和 offload”这类开关无处安放。

## 待真机验证

- [x] `zig build test` 退出 0（`All 55 tests passed`）
- [x] `zig build ... -Doptimize=ReleaseSmall` 退出码 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 正好两个 `DROM, IROM` 段：`0x40000020`、`0x40020020`
- [x] `bash -n tools/flash.sh` 退出码 0
- [ ] 串口出现 banner 与 `checks: passed=6 failed=0 total=6`
- [ ] `check: loopback tx ... identical=1`
- [ ] `check: ipv4 ... total=<14+20+8+payload 一致> cksum=0x????`（数值取自真机）
- [ ] `check: udp ... verified=1`
- [ ] `check: rx kind=ipv4 ... frames=1`
- [ ] `main: verdict=pass` 之后停在 `wfi`，复位可重复
- [ ] 可选：Linux 上 `ip tuntap add` + 本工程帧回放（需要 root）
