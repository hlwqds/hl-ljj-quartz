# ch19 UDP、DHCP 与 DNS：从路由器拿到一个地址

> 所属章节：[[ch19-udp-dhcp-dns|第十九章：UDP、DHCP 与 DNS]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已全部跑通**：`zig build test` → `All 49 tests passed`
>   （48 个具名用例 + 根文件容器 test），2026-11-13，宿主 x86_64 / Zig 0.17.1。
> - **板侧镜像已生成**：`zig build -Dtarget=riscv32-freestanding-eabihf ...` 退出 0；
>   `esptool elf2image` 打印 `Merged 2 ELF sections.`；`image-info` 的段表里
>   落在 flash 的 `DROM, IROM` 行正好两条（`0x40000020` 与 `0x40020020`）。
> - **已上板（2026-11-13）**：板侧 14 条判据全部 PASS（`checks: passed=14 failed=0 total=14`），
>   原始输出见 `../logs/ch19-boot.log`。README 里未标“实测”的片段仍是目标形态。
> - 「从路由器拿到 IP」需要 ch17（MAC/DMA）+ ch18（IPv4/ARP/ICMP）+ 本章三件套
>   一起上板；本章只交付后者的纯逻辑与自检。

## 目的

这是形态 B 的第十四个工程（ch16=十一、ch17=十二、ch18=十三），也是 Part IV 的收官：**第一次让一个设备能自己
问出“我是谁、网关在哪、DNS 是谁”**。

`zig build test` 覆盖三块最容易写错、又最不需要硬件的逻辑：

| 模块       | 覆盖内容                                                            |
| ---------- | ------------------------------------------------------------------- |
| `udp.zig`  | 8 字节首部、伪首部校验和、0/0xFFFF 规则、端口分派（三种结局）       |
| `dhcp.zig` | 236+4+TLV 编解码、DISCOVER/OFFER/REQUEST/ACK、T1/T2、NAK、指数退避  |
| `dns.zig`  | header/问题编码、压缩指针解压（含环路防护）、A 记录、TTL 缓存与淘汰 |

本章回答的四个问题：

1. **UDP 校验和为什么“可以没有”**？IPv4 下字段为 0 表示发送方没算（RFC 768），
   接收方必须放行；而算出的结果恰好为 0 时要发 `0xFFFF`，否则会被误读成“没算”。
2. **DHCP 凭什么能在丢包的网络里拿到地址**？不是靠一次请求，而是靠**重传 +
   四计时器**：租期、T1、T2、以及每次重试的退避。
3. **DNS 解析器为什么必须有环路保护**？压缩指针只是一个 14 位偏移；自指或
   互指能让任何“跟随指针直到 0”的实现死循环。本工程用“指针必须严格向前”
   把终止性变成不变量。
4. **缓存为什么要看 TTL 而不是 LRU**？DNS 缓存的价值与剩余 TTL 成正比；
   淘汰最早到期的条目，等于优先丢掉“马上就要作废”的知识。

## 工程不做的事

- **没有 MAC/DMA**：不碰 EMAC 寄存器、不建描述符环（ch17）。
- **没有 IPv4/ARP/ICMP**：不解析 IP 首部、不发 ARP 请求、不处理分片（ch18）。
  本章的 `udp.seal/check` 需要调用方把 `src/dst` 传进来——这就是与 ch18 的接口。
- **板侧不发包**：自检只在本机构造报文并解析，串口不驱动网口。
- **没有 DHCP 服务器、DNS 服务器**：只做客户端/解析器。
- **不支持 DHCP 的 option overload（52）与 DNS 的 EDNS0**：遇到就跳过。
- **不使用堆**：所有报文缓冲、客户端状态、缓存条目都是 `.bss` 里的定容对象。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章自检只需要串口；真机联调才需要网线、路由器与抓包            |

## 文件表

| 路径                 | 角色                                                                    | 代码浏览                                                                  |
| -------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`（三个纯逻辑模块）                  | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界符号、四条 ASSERT                  | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                               | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/main.zig)       |
| `src/selftest.zig`   | 板侧 14 条判据：DHCP 全流程 + UDP 分派 + DNS 解析/缓存                  | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/selftest.zig)   |
| `src/udp.zig`        | 首部/校验和/端口分派；13 个主机侧用例                                   | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/udp.zig)        |
| `src/dhcp.zig`       | 报文编解码 + 客户端状态机；17 个用例                                    | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/dhcp.zig)       |
| `src/dns.zig`        | 查询编码/压缩指针/A 记录/缓存；18 个用例                                | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/dns.zig)        |
| `src/host_tests.zig` | `zig build test` 的根：只 import 纯逻辑模块                             | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/host_tests.zig) |
| `src/hw.zig`         | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                              | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/hw.zig)         |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump（80 字节帧）                              | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/trap.zig)       |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                               | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/src/log.zig)        |
| `idf-bootstrap/`     | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                | —                                                                         |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用          | [查看](/static/code/#/zig-esp32-s31/ch19-udp-dhcp-dns/tools/flash.sh)     |

表里的 `/static/code/#/…` 深链要在重跑 `npm run code-site`（`scripts/gen-code-site.mjs`
的 `PROJECT_GLOBS` 已覆盖 `practice/zig-esp32-s31/*`）之后才能打开；本批按约束
没有改动 code-site，所以当前站点上还看不到这一套源码。

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置
single-app-large）、没有 `components/`。生成物 `zig-out/`、`.zig-cache/`、
`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 不入库。

## 主机侧测试

```bash
cd practice/zig-esp32-s31/ch19-udp-dhcp-dns
zig build test --summary all
zig test src/host_tests.zig        # 想立刻看到 "All 49 tests passed" 时用这个
```

分布（48 个具名用例，另加根文件容器 test，共 49）：

| 模块       | 用例数 | 代表用例                                                           | 分类（粗粒度）                     |
| ---------- | -----: | ------------------------------------------------------------------ | ---------------------------------- |
| `udp.zig`  |     13 | `0 与 0xFFFF 的互换`、`奇数字节跨片求和`、`单字节翻转被抓住`       | 首部 4 / 校验和 5 / 分派 4         |
| `dhcp.zig` |     17 | `ACK 缺省 T1/T2`、`NAK 清空 offer`、`T1→T2→到期`、`退避 4→64`      | 编解码 5 / 状态机 9 / 计时与兜底 3 |
| `dns.zig`  |     18 | `压缩指针指回问题区`、`指针必须向前`、`跳过 CNAME`、`淘汰最早到期` | 编码 4 / 解压 4 / 响应 3 / 缓存 7  |

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
. /tmp/idfenv.sh          # 或 source $IDF_PATH/export.sh
zig version               # 必须 0.17.x
```

## 构建

### 1. 主机侧单测（不需要开发板）

见上。测试只编译 `src/host_tests.zig`，它只 import `udp.zig`/`dhcp.zig`/`dns.zig`，
不引用 `hw.zig`/`start.zig`/`trap.zig`/`selftest.zig`。

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

2026-11-13 本机实测（节选）：

```text
Merged 2 ELF sections.
Segment   Length   Load addr   File offs  Memory types
      0  0x04990  0x40000020  0x00000018  DROM, IROM
      1  0x0006c  0x2f000000  0x000049b0  DRAM, BYTE_ACCESSIBLE, IRAM
      2  0x00290  0x2f000070  0x00004a24  DRAM, BYTE_ACCESSIBLE, IRAM
      3  0x0b354  0x00000000  0x00004cbc  PADDING
      4  0x01dc8  0x40020020  0x00010018  DROM, IROM
```

判据是“落在 flash 的 `DROM, IROM` 行正好两条”，不是“总段数 == 2”。

### 4. bootloader 与分区表（供应商步骤）

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

### 5. 烧录

```bash
sh tools/flash.sh /dev/ttyUSB0     # Linux
```

## 运行（2026-11-13 板侧实测 14/14）

串口 115200 8N1，UART0（GPIO58/59）：

```text
ch19-udp-dhcp-dns | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: udp + dhcp client + dns resolver, no MAC/IPv4/IRQ (host tests are authoritative)
host: 49 unit tests via 'zig build test' (48 named + root container)
check: dhcp discover len=<n> last=END(255) ok=1
check: dhcp cookie=0x63825363 ok=1
check: dhcp option53=discover(1) ok=1
check: udp sport=68 dport=67 len=<n> verified=ok ok=1
check: udp demux dport=67 delivered=dhcp_server ports=2 ok=1
check: dhcp state=selecting xid=0x<..> ok=1
check: dhcp offer yiaddr=192.168.1.42 -> send_request ok=1
check: dhcp bound ip=192.168.1.42 lease=3600 t1=1800 t2=3150 ok=1
check: dhcp options gw=192.168.1.1 dns=223.5.5.5 ok=1
check: dhcp t1=1802 renew state=renewing ok=1
check: dns query len=29 qd=1 rd=1 labels=2 ok=1
check: dns a=93.184.216.34 ttl=300 cname_hops=0 ok=1
check: dns cache hit=1 ttl_left=1 entries=1 ok=1
check: dns cache expired=1 entries=0 ok=1
main: verdict=pass, skeleton idle (board run 待真机验证)
main: halting (wfi)
```

`<n>`、`<..>` 是占位符：真实数字必须来自真机，**不要从别处抄**。

判读规则：

- `len=<n>` 与 `14+20+8+payload` 无关（DHCP 长度由选项列表决定），但它必须
  `> 240+1` 且最后一个字节是 `END(255)`。
- `cookie=0x63825363` 是唯一能证明“这不是 BOOTP 老报文”的字段。
- `verified=ok` 的依据是「伪首部 + 数据报」求和折叠为 0，不是某个固定数字。
- `dhcp t1=1802 renew`：`t1_at = 绑定时刻(2) + 1800`，与 `lease/t2` 必须对得上。
- `checks: passed=.. failed=..` 之后才打印 verdict；`failed>0` 走 `panic:` 并停在 `wfi`。

## 与相邻章节的接口

| 章节 | 提供                                                 | 本章怎么用                                                    |
| ---- | ---------------------------------------------------- | ------------------------------------------------------------- |
| ch16 | `checksum`/`headers`/`netif`/`pbuf` 的主机侧骨架     | 只作思路与口径参考；本章自带的求和/首部更小，保证独立可编     |
| ch17 | 以太网收发帧（`netif.send` 传入 `(buffer,len)`）     | 本章的 UDP 数据报就是 IP 载荷：`eth 14B + ip 20B + udp dgram` |
| ch18 | IPv4 首部的 `src/dst/protocol/len`，ARP 解析网关 MAC | 本章的 `udp.seal/check(src,dst,…)` 就靠它传进来的两个地址     |
| ch19 | 本章：UDP 校验和、DHCP 客户端、DNS 解析器与缓存      | 给 ch20（TCP）与 ch22（socket）提供“端口/名字”两套基础设施    |

三章之间**只有函数签名级的依赖**：`udp.seal(src, dst, dgram)` 不需要知道
IPv4 首部长什么样；`dhcp.Client` 只产出 `Action`，不碰任何缓冲区；
`dns.findAnswer(packet, id, out_name)` 只读一个字节切片。因此三章工程可以
各自独立编译，也可以任意顺序拼装。

## 证据与边界

1. **为什么主机测试是权威**：UDP 的字节序、DHCP 的租期换算、DNS 的压缩指针，
   都是**纯逻辑**，与芯片无关。它们在板上出错时你很难区分“逻辑错”还是
   “编译/内存布局错”。先在主机上钉死，板侧只剩“能不能跑起来”。
2. **为什么板侧只保留一条闭环**：板侧多做一件事，就多一个“可能错但无法归因”
   的来源。本章板侧不打中断、不发包、不读 MAC，所有输出都能静态推理复现。
3. **为什么 NAK 要清空 offer**：留着旧 offer 会让下一次 REQUEST 继续请求
   同一个被拒绝的地址，表现为“无限 NAK 循环”。清空是唯一正确的选择。
4. **为什么 DNS 指针只许向前**：任何跳转都让偏移严格变小，终止性从此是
   **结构性保证**，而不是“跳 32 次就放弃”的经验值（那是二道防线）。

## 待真机验证

- [x] `zig build test` 退出 0（`All 49 tests passed`）
- [x] `zig build … -Doptimize=ReleaseSmall` 退出码 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 正好两个 `DROM, IROM` 段：`0x40000020`、`0x40020020`
- [x] `bash -n tools/flash.sh` 退出码 0
- [x] 串口出现 banner 与 `checks: passed=14 failed=0 total=14`（`../logs/ch19-boot.log`）
- [x] `check: udp demux dport=67 delivered=dhcp_server ports=2 ok=1`（同上日志）
- [x] `check: dhcp bound ip=… lease=… t1=… t2=…`（实测 `192.168.1.42 / 3600 / 1800 / 3150`）
- [x] `check: dns a=… ttl=… cname_hops=0 ok=1`（同上日志）
- [x] `check: dns cache expired=1 entries=0 ok=1`（同上日志）
- [x] `main: verdict=pass` 之后停在 `wfi`，复位可重复（同上日志）
- [ ] 联调（ch17+ch18 就绪后）：路由器分配地址 → `ping 网关` → `ping 223.5.5.5`
- [ ] 联调：`dns.findAnswer` 解析真实响应，缓存命中第二次查询
