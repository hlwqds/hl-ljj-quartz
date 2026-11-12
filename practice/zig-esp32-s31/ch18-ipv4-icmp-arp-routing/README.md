# ch18 IPv4、ICMP、ARP 与路由：把“能收帧”变成“能 ping”

> 所属章节：[[ch18-ipv4-icmp-arp-routing|第十八章：IPv4、ICMP、ARP 与路由]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!info] 验证状态：**已上板（2026-11-13）** —— 板侧 13 条判据全部 PASS
> （`checks: passed=13 failed=0 total=13`，原始输出 `../logs/ch18-boot.log`）；
> 真实 ping / 跨网段联调仍依赖 ch17 的收发包路径（DMA 未通）。
>
> 已经完成的是所有可静态验证的部分（2026-11-13，宿主 x86_64 / Zig 0.17.1）：
>
> - `zig build test` → `All 70 tests passed`（69 个具名用例 + 根文件容器 test）；
> - `zig build -Dtarget=riscv32-freestanding-eabihf … -Doptimize=ReleaseSmall` 退出 0；
> - `esptool elf2image` 打印 `Merged 2 ELF sections.`；
> - `image-info` 的段表里 `DROM, IROM` 行数 **正好 2**（`0x40000020` / `0x40020020`）；
> - `bash -n tools/flash.sh` 退出 0；
> - 静态占用：`.flash.text` 0x4b90、`.flash.rodata` 0xb30、`.data` 0x180、`.bss` 0x3810
>   （重组槽 2 × 3020 B + 三个 1500 B 分片缓冲 + 协议表，全部在内部 SRAM）。
>
> **下面没有一行是实测串口输出。** `check:` 开头的判读行由本工程上板后产生；
> 在那之前它们只是"目标形态"。板侧自检不打开中断、不碰 EMAC：链路层属于
> ch17，本章只证明"IPv4/ICMP/ARP/路由的纯逻辑在 rv32 镜像里自洽"。

## 待真机验证清单

| #   | 待验证项                          | 判据（跑起来看什么）                                                 | 对应章节 |
| --- | --------------------------------- | -------------------------------------------------------------------- | -------- |
| 1   | 板侧 13 条判据                    | `checks: passed=13 failed=0 total=13`                                | 18.10    |
| 2   | 大报文分片                        | `ipv4 frag mtu=1500 n=3 off=0/1480/2960 mf=1/1/0 last-len=60`        | 18.4     |
| 3   | 乱序重组                          | `ipv4 reasm order=2,0,1 len=3020 identical=1 completed=1`            | 18.5     |
| 4   | 路由（on-link / 默认）            | `route 8.8.8.8 on-link=0 via=192.168.1.1 prefix=0`                   | 18.8     |
| 5   | ARP 解析/学习/老化                | `arp learn state=reachable …`、`arp expire +31s state=stale`         | 18.7     |
| 6   | ARP 应答                          | `arp serve reply op=2 sha=02:00:00:00:00:02 tpa=192.168.1.50 len=28` | 18.7     |
| 7   | PMTU 学习                         | `pmtu dst=8.8.8.8 mtu=1400 needs-frag(1500)=1`                       | 18.9     |
| 8   | 接上 ch17 后的真 `ping`（跨工程） | PC 上 `ping <板子 IP>` 有回显；Wireshark 里 ICMP 0/8 成对            | 18.11    |
| 9   | 跨网段 ping（要求网关）           | `ping 8.8.8.8` 的 ARP 目标是网关 MAC，不是目的 MAC                   | 18.8     |

## 目的

这是形态 B 的第十三个工程，也是 Part IV"网络底座"的第三块。它把 ch17 送上来
的**以太网载荷**（EtherType `0x0800` / `0x0806`）继续往上拆：

1. **IPv4**：首部逐字段校验、校验和、分片（8 字节对齐）、有界重组、
   重复/重叠片处理、超时回收；
2. **ICMP**：回显请求/应答（`ping`）、`type 3 code 4`（frag needed，PMTU 的唯一来源）、
   广播/多播不应答策略；
3. **ARP**：28 字节报文、缓存的六个状态（`free/incomplete/reachable/stale/delay/probe`）、
   1 s 重传 ×3、30 s 确认期、60 s 回收；
4. **路由**：最长前缀匹配、同前缀按 metric 决胜、connected vs gateway、
   下一跳决定"ARP 解析谁"；
5. **PMTU**：从 ICMP 错误里记住路径 MTU，并给分片/DF 决策提供输入。

本章回答的四个问题：

1. **为什么分片边界是 8 字节？** 因为首部里"标志 + 片偏移"共用 16 位，
   偏移以 8 字节为单位。除最后一片外，任何片的载荷不是 8 的倍数都无法表达。
2. **重组表为什么要"有界 + 超时"？** 无界重组是经典的内存耗尽与重叠攻击面
   （teardrop、RFC 1858）。本工程 2 个槽 × 3020 B、30 s 超时、容量满时踢最旧。
3. **ARP 缓存为什么不是一张 map？** 因为"知道 MAC"和"这条映射还新鲜"是两件事。
   六个状态把"等应答 / 可用 / 该复核 / 正在复核"分开，每个状态有自己的定时器。
4. **路由为什么必须先最长前缀？** 默认路由匹配一切；如果先查默认路由，
   同网段的所有流量都会绕到网关上（"发夹弯"），并且 ARP 会去解析网关而不是对端。

## 与 ch16 的接口边界

| 层             | ch16（协议栈架构/零拷贝）                  | ch18（本章）                                                        |
| -------------- | ------------------------------------------ | ------------------------------------------------------------------- |
| 缓冲           | `pbuf` 池、链、引用计数、`eat`、`toLinear` | **不用** pbuf：分片/重组用固定槽 + 显式长度；`storage` 由调用方挂上 |
| 校验和         | `checksum.Sum`（流式、跨片、RFC 1624）     | `inet.Sum` **独立重写**：同样的算法，不同的结构（`pending` 单字节） |
| 首部           | `headers.Ipv4` 只做编解码 + 严格校验       | `ipv4.Header` 增加分片/偏移语义、`parseChecked`、重组键             |
| MTU            | `netif` 只拒绝超 MTU 的发送                | `ipv4.needsFragment` + `Pmtu` 表，把"拒绝"升级为"分片/回 ICMP"      |
| 时钟           | `timer_wheel` 提供到期调度                 | 所有状态机收 `now_ms: u32` 参数，**不读时钟**（主机可测）           |
| EtherType 分派 | `netif.receive` 返回 `.ipv4/.arp`          | 本章消费这两类载荷：`0x0800` → `ipv4`，`0x0806` → `arp`             |

**为什么不 `@import("../ch16-.../src/pbuf.zig")`**：`zig build` 的根模块只包含本工程
的 `src/`。跨工程引用要么复制相对路径（把 ch16 的目录布局变成隐式契约），要么在
`build.zig` 里挂一个模块（那本章就不能单独拷走、单独编译）。本系列的约定是
**每章工程独立可编**，共享的是"接口与做法"，不是文件。

## 工程不做的事

- **不驱动 EMAC**：没有 MDIO、没有 DMA 描述符环、没有中断（ch17）。
- **不做 ARP 待发队列**：`incomplete` 期间上层数据报直接丢/回"暂时不可达"。
  真实栈会排队并在解析成功后重放（lwIP 的 `etharp` 队列），本章留作边界。
- **不做 IPv4 选项**：解析允许 `ihl > 5` 并跳过，但生成与分片只支持 20 字节首部。
- **不做 ICMP 重定向 / 时间戳 / 源抑制**：只实现 echo 与 frag-needed。
- **不做动态路由协议**：路由表是手工 `add` 的 connected + 默认路由。
- **不做 65535 字节重组**：上限 3000 字节载荷，够覆盖"上游 MTU 小于本地 MTU"的
  常见情形，又给内存放大一个硬边界。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 只需串口。本章不需要网线、不需要示波器                          |

## 协议参数速查

| 参数                 | 值                           | 依据                                      |
| -------------------- | ---------------------------- | ----------------------------------------- |
| IPv4 最小 / 最大首部 | 20 / 60 字节（IHL 4 bit）    | RFC 791 §3.1                              |
| 分片载荷粒度         | 8 字节（片偏移 13 bit）      | RFC 791 §3.1                              |
| 重组超时             | 30 s                         | RFC 1122 §3.3.2（要求 ≥60 s，Linux 30 s） |
| 重组上限             | 2 槽 × 3000 B 载荷           | 本章取舍（内存放大边界）                  |
| ICMP 校验和          | 覆盖整个 ICMP 报文，无伪首部 | RFC 792                                   |
| ICMP 错误引用长度    | 原 IP 首部 + 8 字节（28 B）  | RFC 792                                   |
| ARP 重传             | 1 s × 3 次                   | RFC 1122 §2.3.2.1                         |
| ARP 确认期 / 回收    | 30 s / 60 s                  | 本章取值（对齐 Linux NUD 默认量级）       |
| ARP 报文             | 28 字节（以太网 + IPv4）     | RFC 826                                   |
| PMTU 下限 / 缓存期   | 68 B / 10 min                | RFC 791、RFC 1191                         |
| 路由表容量           | 16 条，线性扫描 LPM          | 本章取舍（主机路由表规模）                |

## 文件表

| 路径                 | 角色                                                                            | 代码浏览                                                                           |
| -------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`（五个纯逻辑模块）                          | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界符号、四条 ASSERT                          | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/linker/s31.ld)      |
| `src/inet.zig`       | 地址解析/掩码/前缀匹配、RFC 1071 校验和、RFC 1624 增量更新；11 个用例           | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/inet.zig)       |
| `src/ipv4.zig`       | 首部编解码、分片、有界重组、PMTU；22 个用例                                     | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/ipv4.zig)       |
| `src/icmp.zig`       | 回显请求/应答、frag-needed、应答策略；10 个用例                                 | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/icmp.zig)       |
| `src/arp.zig`        | 28 字节报文、缓存六状态机、老化、应答；15 个用例                                | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/arp.zig)        |
| `src/route.zig`      | LPM、metric 决胜、connected/gateway；11 个用例                                  | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/route.zig)      |
| `src/host_tests.zig` | `zig build test` 的根：只 import 纯逻辑模块                                     | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/host_tests.zig) |
| `src/selftest.zig`   | 板侧 13 条判据（分片/重组/路由/ARP/PMTU 走一遍）                                | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/selftest.zig)   |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                                       | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/main.zig)       |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss → mtvec | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/start.zig)      |
| `src/hw.zig`         | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                                      | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/hw.zig)         |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump（80 字节帧）                                      | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/trap.zig)       |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                                       | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/src/log.zig)        |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                  | [查看](/static/code/#/zig-esp32-s31/ch18-ipv4-icmp-arp-routing/tools/flash.sh)     |
| `idf-bootstrap/`     | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                        | —                                                                                  |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置
single-app-large）、没有 `run.log`（真机未跑）。生成物 `zig-out/`、`.zig-cache/`、
`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 不入库。

## 主机侧测试

```bash
cd practice/zig-esp32-s31/ch18-ipv4-icmp-arp-routing
zig build test --summary all
zig test src/host_tests.zig        # 想立刻看到 "All 70 tests passed" 时用这个
```

分布（69 个具名用例，另加根文件容器 test，共 70）：

| 模块        | 用例数 | 代表用例                                                                  |
| ----------- | -----: | ------------------------------------------------------------------------- |
| `inet.zig`  |     11 | `RFC 1071 示例得出 0x220d`、`增量更新等于整包重算（TTL 递减）`            |
| `ipv4.zig`  |     22 | `分片三片、偏移/MF/长度都对`、`重叠但内容不同 → 整包丢弃（teardrop）`     |
| `icmp.zig`  |     10 | `应答只改 type 与校验和`、`frag needed 携带下一跳 MTU 与 28 字节引用`     |
| `arp.zig`   |     15 | `delay 到期转 probe`、`sender IP 为 0.0.0.0 的地址探测不学习（RFC 5227）` |
| `route.zig` |     11 | `最长前缀匹配：/32 > /24 > /16 > /0`、`插入顺序不影响 LPM 结果`           |

这些用例覆盖的恰好是"上板后最难调"的部分：**位布局、边界、状态机时序**。
它们全部用假时钟（`now_ms` 参数）驱动，没有 `sleep`，跑完 < 10 ms。

## 构建、测试、烧录

```bash
cd practice/zig-esp32-s31/ch18-ipv4-icmp-arp-routing
. /tmp/idfenv.sh

# 1) 交叉编译（Zig 0.17.1）
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

# 2) ELF → 镜像
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf

# 3) 段表必须正好两行 DROM, IROM
python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin

# 4) 主机侧单测（不需要开发板）
zig build test

# 5) 烧录（偏移只从 IDF 的 flash_args 来）
sh tools/flash.sh /dev/ttyUSB0
```

`tools/flash.sh` 的前置条件与 ch16/ch17 相同：先在 `idf-bootstrap/` 里完成一次
IDF 构建，产出 `build/{bootloader,partition_table}/…` 与 `build/flash_args`。

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
```

## 运行（目标形态，待真机验证）

```text
ch18-ipv4-icmp-arp-routing | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: ipv4 header/frag/reasm + icmp echo/frag-needed + arp cache + route lpm
link: no MAC/DMA/IRQ - ch17 owns the ethernet data path
host: 70 unit tests via 'zig build test' (authoritative for all five modules)
check: addr 192.168.1.10/24 net=192.168.1.0 same-subnet(.50)=1 same-subnet(8.8.8.8)=0 ok=1
check: icmp echo-request len=15 type=8 cksum-ok=1 ok=1
check: icmp echo-reply len=15 type=0 payload-copied=1 ok=1
check: ipv4 ver=4 ihl=5 proto=1 total=3020 payload=3000 cksum-ok=1 ok=1
check: ipv4 frag mtu=1500 n=3 off=0/1480/2960 mf=1/1/0 last-len=60 ok=1
check: ipv4 reasm order=2,0,1 len=3020 identical=1 completed=1 ok=1
check: route 192.168.1.50 on-link=1 via-self=1 prefix=24 ok=1
check: route 8.8.8.8 on-link=0 via=192.168.1.1 prefix=0 ok=1
check: arp resolve miss=1 request target=192.168.1.1 ok=1
check: arp learn state=reachable mac=02:00:00:00:00:01 lookup-hit=1 ok=1
check: arp expire +31s state=stale ok=1
check: arp serve reply op=2 sha=02:00:00:00:00:02 tpa=192.168.1.50 len=28 ok=1
check: pmtu dst=8.8.8.8 mtu=1400 needs-frag(1500)=1 ok=1
checks: passed=13 failed=0 total=13
main: verdict=pass, skeleton idle (board run 待真机验证)
main: halting (wfi)
```

判读规则：

- 第 4 行 `total=3020` 必须等于 `20 + 8 + 2992`；`payload=3000` 是 ICMP 首部+数据。
- 第 5 行三个偏移必须是 `0 / 1480 / 2960`：第一片载荷是 `(1500-20)/8*8 = 1480`。
- 第 6 行 `identical=1` 是逐字节比对（`std.mem.eql`）的结论，不是"长度对得上"。
- `checks:` 行之后才打印 verdict；`failed>0` 时走 `panic:` 路径并停在 `wfi`。

## 判据背后的四个设计决定

1. **所有纯逻辑都收 `now_ms`**，不读时钟、不 sleep。这样 ARP 老化、重组超时、
   PMTU 过期都能在主机上用一条 `for` 循环把时间推过去，测试是确定性的。
   （ch11 的 tick 到来之后，板侧只需把 `now_ms` 接上 `esp_timer`。）
2. **重组缓冲由调用方提供**（`Reasm.attach`）。把它放进 `Reasm{}` 的默认值会让
   这个编译期常量把 6 KB 写进 `.data`——镜像变大、启动变慢，而且 `.bss` 的
   边界检查就失效了。现在的 `.data` 只有 0x180 字节。
3. **`incomplete` 不返回 MAC，也不猜广播**：上层必须显式处理"暂时不可达"。
   猜广播会把数据帧发给全宿舍，还会让对端的连接状态错乱。
4. **重叠片一律比对内容**：RFC 791 只允许完全相同的重叠；不一致直接丢整包并
   计入 `stats.failed`。这是 teardrop 类攻击的最小防线。

## 待真机验证

- [x] `zig build test` 退出 0（68/68）
- [x] `zig build … -Doptimize=ReleaseSmall` 退出码 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 正好两个 `DROM, IROM` 段：`0x40000020`、`0x40020020`
- [x] `bash -n tools/flash.sh` 退出码 0
- [x] `.data` 只剩 0x180 字节（重组缓冲已移出结构体默认值）
- [ ] 串口出现 banner 与 `checks: passed=13 failed=0 total=13`
- [ ] `ipv4 reasm … identical=1`
- [ ] `arp expire +31s state=stale`
- [ ] `main: verdict=pass` 之后停在 `wfi`，复位可重复
- [ ] 接上 ch17 的收发路径后，PC `ping` 通（跨工程，见 18.11）
