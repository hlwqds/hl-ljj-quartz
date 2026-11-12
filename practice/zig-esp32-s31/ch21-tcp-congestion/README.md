# ch21 TCP 拥塞控制与吞吐

> 所属章节：[[ch21-tcp-congestion-throughput|第二十一章：TCP 拥塞控制与吞吐]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **主机侧已跑通**：`zig build test` → `21/21 tests passed`（20 个具名用例 +
>   根文件容器 test），2026-11-13，宿主 x86_64 / Zig 0.17.1。
> - **确定性已对拍**：同种子两次运行指纹一致（`hash=0xfd1ab529b33a5ef`），
>   换种子必变（`0xa02c6b11b5f4514c`），用例与板侧读数都钉住了这一点。
> - **镜像合法**：交叉编译退出 0；`esptool elf2image` 打印
>   `Merged 2 ELF sections.`；`image-info` 中落在 flash 的 `DROM, IROM`
>   行正好两条（`0x40000020` 与 `0x40020020`）。
> - **已上板（2026-11-13）**：板侧 10 条判据全部 PASS
>   （`checks: passed=10 failed=0 total=10`，`main: verdict=pass`），
>   原始输出见 `../logs/ch21-boot.log`。
> - **本章没有真链路结论**：ch17 的以太网驱动仍未闭环（DMA 软复位超时、
>   MDIO 扫不到 PHY，见 `../logs/ch17d-boot.log`）。文中所有吞吐/曲线数字
>   都是**主机侧确定性仿真**，不是板子跑出来的。真链路吞吐要等 ch17
>   闭环后另测。

## 目的

这是形态 B 的第十六个工程。它只回答一个问题：**TCP “发多快”是怎么决定的。**

上一章（ch20）把 TCP 的可靠性做完：序号、确认、重传、乱序重组。但一个
“只要接收窗口允许就全塞进去”的发送端会把瓶颈路由器的队列打爆。拥塞控制
就是发送端在看不到网络内部时，用丢包/时延作为反馈，推断“现在能塞多少”的
机制。

本工程交付四样东西，全部**不碰硬件**：

| 模块                 | 覆盖内容                                                                                                                                                                    |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/cong.zig`       | 慢启动、拥塞避免、Reno 快重传/快恢复、超时收缩、`ssthresh` 下限、`min(cwnd,rwnd)`、RFC 7323 窗口缩放、BDP、RFC 6298 RTT/RTO、pacing 令牌桶、Nagle 判据、Mathis 公式整数开方 |
| `src/sim.zig`        | 确定性丢包仿真：段队列 + 接收位图 + 周期/随机两种丢包模式，输出 `cwnd` 曲线、重传数、有效吞吐、曲线指纹                                                                     |
| `src/selftest.zig`   | 板侧 10 条判据（对应章节 21.9 的判读顺序）                                                                                                                                  |
| `src/host_tests.zig` | `zig build test` 的根：只 import 上面两个纯逻辑模块                                                                                                                         |

## 工程不做的事

- **没有 MAC/DMA、没有 IPv4、没有 socket**：链路层在 ch17（未闭环），
  IPv4 在 ch18，状态机在 ch20。本章只做“窗口控制律”。
- **不发任何真实报文**：仿真是纯整数 tick 循环，串口不驱动网口。
- **不测真链路吞吐**：所有数字标注「仿真，非真链路」。
- **不做 SACK / NewReno 的多洞恢复**：本章实现 Reno；
  lwIP 的 `TF_INFR` 语义在章节 21.10 里做源码级对照。
- **不做 CUBIC / BBR / ECN**。
- **不使用堆、不使用浮点、不读时钟**：所有缓冲在 `.bss`，
  仿真时间由 `tick` 参数驱动。板上主栈只有 16 KiB，仿真器的段队列
  （128 × 24 B）与接收位图（256 B）因此是**文件作用域静态缓冲**而不是
  局部变量——它们进栈会直接越过栈顶，表现为 trap。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 本章自检只需要串口；不需要网线、路由器或抓包                    |

## 文件表

| 路径                 | 角色                                                                    | 代码浏览                                                                    |
| -------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `zig build test`（两个纯逻辑模块）                  | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界符号、四条 ASSERT                  | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/start.zig)      |
| `src/main.zig`       | 板侧编排：banner → 自检 → verdict → `wfi`                               | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/main.zig)       |
| `src/selftest.zig`   | 板侧 10 条判据与两行曲线读数                                            | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/selftest.zig)   |
| `src/cong.zig`       | 控制律：慢启动/拥塞避免/快重传/超时/RTO/BDP/pacing/Nagle/Mathis         | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/cong.zig)       |
| `src/sim.zig`        | 确定性丢包仿真：段队列、接收位图、周期/随机丢包                         | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/sim.zig)        |
| `src/host_tests.zig` | `zig build test` 的根：只 import 纯逻辑模块                             | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/host_tests.zig) |
| `src/hw.zig`         | 最小寄存器集合：ROM 忙等、CSR 读、`halt()`                              | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/hw.zig)         |
| `src/trap.zig`       | `.trap_ram` 入口 + panic dump（80 字节帧）                              | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/trap.zig)       |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                               | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/src/log.zig)        |
| `idf-bootstrap/`     | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                | —                                                                           |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用          | [查看](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/tools/flash.sh)     |

完整工程（入口为工程 README，可再进目录树）：[ch21-tcp-congestion](/static/code/#/zig-esp32-s31/ch21-tcp-congestion/README.md)

> 表里的 `/static/code/#/…` 深链要重跑一次 `npm run code-site`
> （`scripts/gen-code-site.mjs` 的 `PROJECT_GLOBS` 已覆盖
> `practice/zig-esp32-s31/*`）之后才能打开；本批按“只动本章两个路径”的
> 约束没有改 code-site。

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF
内置 single-app-large）、没有 `components/`。生成物 `zig-out/`、
`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 不入库。

## 主机侧测试

```bash
cd practice/zig-esp32-s31/ch21-tcp-congestion
zig build test --summary all
zig test src/host_tests.zig        # 想立刻看到 "All 21 tests passed" 时用这个
```

> 覆盖边界：`src/host_tests.zig` 只 import `cong.zig` / `sim.zig`，
> **不编译 `src/selftest.zig`**。那十个板侧判据由 rv32 交叉编译 + 上板运行
> 验证；21 个用例不等于“板侧判据已被主机覆盖”。

分布（20 个具名用例 + 根文件容器 test）：

| 模块       | 用例数 | 代表用例                                                                                                                                                                                                                                                            |
| ---------- | -----: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cong.zig` |     14 | `慢启动：每个 RTT 翻倍 1 -> 2 -> 4 -> 8`、`慢启动：单个 ACK 至多加 2 SMSS`、`快重传：三个重复 ACK…`、`快重传：ssthresh 下限是 2 MSS`、`超时：cwnd 回到 1 MSS`、`窗口取小`、`窗口缩放：shift 钳到 14`、`Nagle`、`BDP`、`RTT 估计`、`pacing`、`Mathis`                |
| `sim.zig`  |      6 | `无丢包：曲线从 1 段起步，峰值落在 BDP 附近`、`确定性：同种子两次运行逐字节一致，换种子必变`、`周期丢包：稳态吞吐随丢包率严格单调下降（4 MiB 传输）`、`丢包时两种恢复机制都被触发过`、`吞吐被接收窗口卡住`、`仿真稳态吞吐与 Mathis 同量级（4 MiB 传输，1% 与 10%）` |

## 怎么跑仿真（主机侧）

仿真不需要开发板，也不需要网络。两种用法：

**1. 看内置用例的结论**

```bash
zig build test
```

**2. 自己改参数跑（临时脚本，不提交）**

```zig
const sim = @import("sim.zig");

pub fn main() void {
    const r = sim.run(.{
        .loss = .{ .periodic = 100 }, // 每 100 个段丢一个 ≈ 1%
        // .loss = .{ .random = 20 }, // 或者随机 2%
        .seed = 0x21C0_FFEE,
    });
    // r.throughputMilli() 是“字节/tick ×1000”，r.completed 表示是否传完
    std.debug.print("tp={d} retx={d} hash=0x{x}\n", .{ r.throughputMilli(), r.retransmits, r.hash });
}
```

> 这个文件请放在工程目录里（`@import` 是相对路径），跑完删掉；
> 本仓库只保留 `src/` 下的正式文件。

参数含义（全部在 `sim.Params` 的注释里）：

| 字段                  | 单位       | 默认         | 说明                                            |
| --------------------- | ---------- | ------------ | ----------------------------------------------- |
| `mss`                 | 字节       | 1460         | 段大小                                          |
| `link_bytes_per_tick` | 字节/tick  | 1250         | 链路速率（1250 × 8 × 1000 = 10 Mbit/s）         |
| `one_way_ticks`       | tick(1 ms) | 12           | 单程时延，RTT = 24 tick                         |
| `rwnd_bytes`          | 字节       | 65536        | 接收窗口                                        |
| `rto_ticks`           | tick       | 200          | 超时门限                                        |
| `initial_ssthresh`    | 字节       | 32768        | 慢启动切换点                                    |
| `total_bytes`         | 字节       | 262144       | 传输总量；稳态判据用 4194304（4 MiB ≈ 2873 段） |
| `loss`                | —          | `.none`      | `.none` / `.periodic(k)` / `.random(‰)`         |
| `seed`                | —          | `0x21C0FFEE` | 仅 `.random` 使用                               |

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
. /tmp/idfenv.sh          # 或 source $IDF_PATH/export.sh
zig version               # 必须 0.17.x
```

## 构建

### 1. 主机侧单测（不需要开发板）

见上。测试只编译 `src/host_tests.zig`，它只 import `cong.zig` / `sim.zig`，
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
      0  0x02800  0x40000020  0x00000018  DROM, IROM
      3  0x00c68  0x40020020  0x00010018  DROM, IROM
```

判据是“落在 flash 的 `DROM, IROM` 行正好两条”，不是“总段数 == 2”。

### 4. bootloader 与分区表（供应商步骤）

`idf-bootstrap/build/` 里的 `bootloader.bin`、`partition-table.bin` 与
`flash_args` 是从同一套 IDF v6.1 工程产出的；自己重建的方法：

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

### 5. 烧录（必须独占串口，与其他章节共用板子时用 flock）

```bash
. /tmp/idfenv.sh                  # flash.sh 调用裸 esptool，必须先有 IDF python env
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'
```

### 6. 抓串口（先开端口再复位，否则丢 ROM banner）

```bash
flock /tmp/s31-board.lock python3 - <<'EOF'
import serial, time
ser = serial.Serial('/dev/ttyUSB1', 115200, timeout=0.2)
# 打开端口本身就会拉 RTS/DTR（ESP 自动复位电路）：先读掉这次启动，
# 再显式复位一次，日志里才只有一次完整启动。
t = time.time() + 0.8
while time.time() < t:
    ser.read(8192)
ser.setDTR(False); ser.setRTS(True); time.sleep(0.1); ser.setRTS(False)  # 只拉 RTS = 复位
deadline = time.time() + 14; buf = bytearray()
while time.time() < deadline:
    d = ser.read(8192)
    if d: buf += d
ser.close()
open('../logs/ch21-boot.log','wb').write(bytes(buf))
EOF
```

## 运行（2026-11-13 板侧实测 10/10）

串口 115200 8N1，UART0（GPIO58/59）：

```text
ch21-tcp-congestion | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
scope: cwnd/ssthresh/rto/bdp/pacing/nagle + deterministic loss sim
note: throughput numbers are host-side simulation, NOT a real link
host: 21 unit tests via 'zig build test' (20 named + root container)
check: cwnd slowstart rtt 1,2,4,8 ok=1
check: cwnd ca per-rtt 8,9,10,11 ok=1
check: fast retx ssthresh=7300 cwnd=11680 state=fast_recovery ok=1
check: timeout cwnd=1460 ssthresh=11680 ok=1
check: window min(cwnd=14600,rwnd=5840)=5840 ok=1
check: wscale shift=14 encode(1MiB)=64 decode=1048576 max=1073725440 ok=1
check: nagle unacked=1 small=blocked full=allowed idle=allowed ok=1
sim: cwnd none@1rtt n=14 [1,1,2,4,8,16,23,24,25,26,26,27,28,29]
sim: cwnd loss1/100 n=15 [1,1,2,4,8,16,23,24,25,26,29,13,14,15,16]
sim: k100 ramp sent=180 retx=1 to=0 fr=1 dup=23 ticks=346
check: sim tp none=1211876 k100=596290 k25=245395 k10=136453 ok=1
sim: k100 steady sent=2874 retx=29 to=1 fr=28 dup=386 ticks=7034
sim: seed=0x21c0ffee hash=0xfd1ab529b33a5ef rerun=0xfd1ab529b33a5ef equal=1
check: bdp 10mbit/24ms = 30000B 21seg rwnd_needed=30660 ok=1
check: mathis p=1% theory=745025 sim=596290 ratio_x1000=800 ok=1
checks: passed=10 failed=0 total=10
main: verdict=pass, congestion control law verified off-link (wfi)
main: halting (wfi)
```

判读规则：

- `cwnd slowstart 1,2,4,8`：慢启动每个 RTT 翻倍，四拍齐全；
- `cwnd ca per-rtt 8,9,10,11`：拥塞避免每 RTT 恰好 +1 MSS（多一个或少一个都算失败）；
- `fast retx ssthresh=7300 cwnd=11680`：`7300 = 5×1460`、`11680 = 8×1460`，
  即“减半”与“+3 MSS”两条公式同时成立；
- `timeout cwnd=1460`：超时后窗口回 1 MSS，不是减半；
- `window …=5840`：`min(14600, 5840)`，证明取小与单位都对；
- `wscale …=64 / 1048576 / 1073725440`：编码向下取整、往返一致、shift 钳 14；
- `sim tp none > k100 > k25 > k10`：4 MiB 稳态运行下，丢包越狠吞吐越低
  （严格不等式，不是四舍五入相等）；
- `k100 ramp` 与 `k100 steady`：同样是 1% 丢包，256 KiB 只有 1 次重传（曲线用它），
  4 MiB 有 29 次（判据用它）。**运行长度不够时比值会落在 1 附近，那是爬坡均值的巧合**，
  章节 21.7.2 有对照；
- `mathis ratio_x1000=800`：稳态下仿真比 1% 丢包的理论值低 20%
  （周期丢包固定命中 + go-back-N 超时导致，见章节 21.7.3）；
- `checks: passed=.. failed=..` 之后才打印 verdict；`failed>0` 走 `panic:` 并停在 `wfi`。

> [!note] `sim:` 行是读数，不是判据
> 它们的单位是“字节/tick（毫单位）”与“MSS 段数”，链路参数写死在仿真里
> （10 Mbit/s、24 ms RTT）。**不要**读成板子的实测吞吐。
> `check: sim tp` 用的运行长度是 4 MiB（≈2873 段，1% 丢包约 29 次事件），
> 曲线读数用的运行长度是 256 KiB（≈180 段），两者不能混着比。

## 与相邻章节的接口

| 章节 | 提供                                           | 本章怎么用                                                                                    |
| ---- | ---------------------------------------------- | --------------------------------------------------------------------------------------------- |
| ch16 | `headers.zig`（只到 UDP）/ `pbuf` / `checksum` | 完全不用：拥塞控制只看“ACK 确认了多少字节”                                                    |
| ch17 | 以太网收发帧                                   | 不需要（未闭环）；真链路联调时才需要                                                          |
| ch18 | IPv4/ARP/ICMP                                  | 不需要                                                                                        |
| ch19 | UDP/DHCP/DNS 与端口表                          | 不需要                                                                                        |
| ch20 | TCP 状态机、seq/ack、RTO 重传                  | 本章的 `Cwnd` 就是它“发送多少”的那一半；接口是四个事件（新 ACK / 重复 ACK / 超时 / 发送机会） |
| ch21 | 本章：拥塞控制律 + 确定性仿真                  | 给 ch22（socket API）提供“发多快”的策略                                                       |
| ch22 | Socket API 与事件循环（规划）                  | 会复用本章的四个事件入口与仿真的驱动形状                                                      |

## 证据与边界

1. **为什么主机测试是权威**：`cwnd` 的加减、`ssthresh` 的下限、窗口缩放的
   位移、Mathis 的开方都是**整数算术**，与芯片无关。板上出错时你很难区分
   “逻辑错”还是“布局错”；先在主机上钉死，板侧只剩“能不能跑起来”。
2. **为什么板侧只保留一条闭环**：板侧多做一件事，就多一个无法归因的
   来源。本章板侧不打中断、不发包、不读 MAC，所有输出都能静态推理复现。
3. **为什么仿真要两个丢包模式**：周期丢包用来做“单调性”判据（结果不依赖
   随机数），随机丢包用来做“同种子可复现”判据（换种子必须变）。
   用一个模式同时做两件事，必然有一件是假的。
4. **为什么静态缓冲**：主栈 16 KiB，仿真器的工作内存若放局部变量会越界；
   放到 `.bss` 之后，代价是“跨调用保留状态”，所以 `run()` 开头必须
   `@memset(&g_delivered, false)`。这一条在主机上不可见，只在板上表现为 trap。

## 待真机验证

- [x] `zig build test` 退出 0（`21/21 tests passed`）
- [x] 仿真确定性：同种子两次指纹一致、换种子必变
- [x] `zig build … -Doptimize=ReleaseSmall` 退出码 0
- [x] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [x] `image-info` 正好两个 `DROM, IROM` 段：`0x40000020`、`0x40020020`
- [x] `bash -n tools/flash.sh` 退出码 0
- [x] 串口出现 banner 与 `checks: passed=10 failed=0 total=10`（`../logs/ch21-boot.log`）
- [x] 两行 `cwnd` 曲线采样与 `hash/rerun/equal=1`（同上日志）
- [x] `main: verdict=pass` 之后停在 `wfi`，复位可重复（同上日志）
- [ ] 真链路吞吐/时延曲线（需 ch17 闭环，本章不代填）
- [ ] ch20 状态机 + 本章控制律合体后的丢包恢复实测
- [ ] `LWIP_WND_SCALE` 在真链路上的协商效果
