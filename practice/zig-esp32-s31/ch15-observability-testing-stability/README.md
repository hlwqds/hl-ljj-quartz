# ch15 可观测性、测试与稳定性：让“不知道发生了什么”变成一条可判读的输出

> 所属章节：[[ch15-observability-testing-stability|第十五章：可观测性、测试与稳定性]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
> 本工程**已上板一次（2026-11-13，修复前版本）**。构建、主机侧单测、镜像生成
> 均通过（Zig 0.17.1 + esptool 5.6，两个 `DROM, IROM` 段）。
> 首轮真机结论：
>
> - `check: clock ... measured=1003us ratio=100%`：TIMG0 1 MHz 时间基成立（实测）；
> - `mtvec` 读回 `0x2f000003`：S31 把 MODE 固定为 3（CLIC），只比较 BASE；
> - `RTC_WDT CONFIG0=0x8007ee00`：EN=1、STG0..3=0、flashboot=0（旧序列没解 SWD_WPROTECT，不是硬件自恢复），
>   功能判据改为“没有武装的 stage”；
> - `sram stack ok=0` 的汇总位无法定位，已拆成 trap/data/bounds 独立行 + bitmask。
>
> 三个判据已修，**次轮已复跑：`checks: passed=8 failed=0`**（2026-11-13）。下面未标实测的行是目标形态；
> 只有正文标“首轮实测”的值来自真机。

## 目的

这是形态 B 的第十个工程，骨架沿用 `ch13-heap-stack-caps`（同一套
`linker/s31.ld` + `_start` + `esptool elf2image`，IDF 只提供二级 bootloader
与分区表）。**没有调度器、没有任务切换、没有中断**：`MIE` 恒为 0，
程序是一条从自检到 panic dump 的顺序执行链。

本章要解决的不是“怎么写 printf”，而是三个更难的问题：

1. **启动时的假设是谁验证的？** 链接符号、SRAM 区间、时钟分频、`mtvec`、
   RTC WDT——只要有一个与基座不一致，后面的所有实验都不可信。工程把
   六组检查做成启动清单，硬判据失败即 `panic`（时钟 1 ms 校准只报告，不 gate）。
2. **崩溃时怎么知道之前发生了什么？** 32 条 24 字节的时间戳 trace 环，
   panic dump 打印最新 8 条。环是纯逻辑，主机侧可单测。
3. **怎么区分“在跑”与“有进展”？** 两层：应用层软件 watchdog 绑定
   业务周期（自动恢复并计数），RTC WDT 只证明“四个 stage 都已 disarm”。

### 六组自检

| 组    | 对照物                                                        | 失败意味着                                      |
| ----- | ------------------------------------------------------------- | ----------------------------------------------- |
| syms  | `.flash.text` / `.flash.rodata` vs IDF `memory.ld.in`         | 链接脚本与基座不一致                            |
| sram  | `.trap_ram`/`.data`/`.bss`/堆/栈边界                          | 静态对象吃进栈区或边界算错                      |
| clock | `HP_SYS_CLKRST` + TIMG0 门控（硬判据）+ 1 ms 校准（advisory） | 门控没开；或时间基不是 1 MHz（只报告）          |
| irq   | `mtvec BASE/mstatus/mie/CLIC THRESH`                          | 向量没装、中断没关（MODE=3 正常）               |
| wdt   | `CONFIG0` 的 STG0..3 + flashboot                              | 还有 stage 武装或 flashboot 开（EN=1 不是失败） |
| trace | 环形缓冲自身（覆盖/顺序/丢弃计数）                            | 观测工具本身有 bug                              |

### 三个可判读的阶段

| 阶段 | 动作                         | 打印前缀                          |
| ---- | ---------------------------- | --------------------------------- |
| 0    | 启动自检                     | `check:` → `checks: passed=8 ...` |
| 1    | 8 × 250 ms 心跳 + trace      | `hb:`                             |
| 2    | 可恢复断言 → 软件 watchdog   | `assert:` / `wdt:`                |
| 3    | 可选 30 s 压测（`-Dstress`） | `stress:`                         |
| 4    | 故意非法指令 → trap → 停机   | `panic:`                          |

### 工程不做的事

- **不做任务切换**：单线程顺序执行。ch10–ch12 的 switch 帧/上下文恢复
  不在这里复用，也不应把本章代码当成调度器模板。
- **不开中断**：没有 tick ISR，时间戳来自读 TIMG0 计数器而不是“第几次 tick”。
- **不做异步日志**：所有输出在栈上格式化后一次 `%s` 写完；panic 时日志
  本身不能成为崩溃点。
- **不实现 RTC/MWDT 的配置**：只在 `_start` 与 `main` 里 disarm RTC WDT，
  并读回 stage/flashboot；EN 可写，disarm 后读回必须是 0（次轮 `after=0x0`）。真正的硬件看门狗配置
  留给需要它的章节。
- **不分配内存**：trace 环、计数器、栈全部是 `.bss` / 链接脚本符号。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 只需串口。本章不新增外部接线，不需要示波器                      |

## 寄存器 / 符号速查

| 项                        | 值 / 位置                                                  | 说明                                            |
| ------------------------- | ---------------------------------------------------------- | ----------------------------------------------- |
| SRAM 应用区间             | `0x2F000000 .. 0x2F07AFC0`（len `0x7AFC0`）                | `memory.ld.in:19` + `ld.hp_mem_defs:9`          |
| IROM / DROM 装载段        | `0x40000020` / `0x40020020`                                | bootloader 要求正好两个 flash 段                |
| TIMG0                     | `0x20580000`                                               | `reg_base.h:71`                                 |
| `HP_SYS_CLKRST_TIMERGRP0` | `0x20587000 + 0x114`                                       | APB bit0，`T0_SRC_SEL[4:3]`，T0 clk bit5        |
| `T0CONFIG`                | `+0x00`；DIVIDER[28:13]、INCREASE bit30、EN bit31          | 40 MHz / 40 = 1 MHz                             |
| `T0UPDATE/T0LO/T0HI`      | `+0x0c` / `+0x04` / `+0x08`                                | UPDATE bit31 自清零；HI 只取低 22 位            |
| CLIC                      | `0x10800000`；CTRL(i)=`0x10801000+4i`                      | `clic_reg.h:17/18/69`                           |
| `mtvec` 读回              | 写 `0x2f000000` → 读 `0x2f000003`                          | S31 WARL：MODE=3（CLIC），只比较 BASE           |
| RTC WDT                   | `0x20801000`；STG0..3 `[30:19]`、flashboot bit12、EN bit31 | 功能判据 stage/flashboot，且 EN 读回 0          |
| RTC WDT 保护/喂狗         | WPROTECT `+0x18`、SWD_WPROTECT `+0x20`、FEED `+0x14`       | 键 `0x50D83AA1`；`_start`+`main` 各 disarm 一次 |
| `mcause`（非法指令）      | `0x30000002`（本板实测，BRINGUP）                          | 异常码只取 `cause & 0x3F`                       |
| `mcause`（ecall）         | `0x3800000b`（ch10–ch12 板级实测）                         | 同上                                            |
| trap 帧                   | 80 字节                                                    | 16 GPR + mepc + mstatus + 2 填充                |

## 文件表

| 路径                 | 角色                                                                              | 代码浏览                                                                                     |
| -------------------- | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `build.zig`          | 目标串 + 链接脚本 + `-Dstress`/`-Dpanic-demo` + `zig build test`                  | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/build.zig)          |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界符号、四条 ASSERT                            | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/linker/s31.ld)      |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`：关中断 → sp/gp → 关 RTC WDT → 清 bss → `mtvec` | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/start.zig)      |
| `src/main.zig`       | 编排：自检 → 心跳 → 断言 → watchdog → 压测 → panic 演示                           | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/main.zig)       |
| `src/check.zig`      | 六组启动自检 + `expect()` 可恢复断言                                              | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/check.zig)      |
| `src/trace.zig`      | 32×24 字节时间戳环；纯逻辑，含 5 个主机侧测试                                     | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/trace.zig)      |
| `src/watchdog.zig`   | 软件 watchdog（截止时间、饱和减法、恢复计数）；含 4 个测试                        | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/watchdog.zig)   |
| `src/trap.zig`       | `trapEntry`（`.trap_ram`）、`trapDispatch`、`panic`、`trip()`                     | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/trap.zig)       |
| `src/hw.zig`         | 寄存器/CSR 读、TIMG0 初始化与 `nowUs()`、`halt()`                                 | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/hw.zig)         |
| `src/stress.zig`     | 30 s 压测：确定性 LCG、绝对时刻报告、chunk 间隔最大值                             | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/stress.zig)     |
| `src/log.zig`        | 栈上格式化 + ROM `esp_rom_printf`（`%s`）                                         | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/log.zig)        |
| `src/host_tests.zig` | `zig build test` 的根：只 import 纯逻辑模块                                       | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/src/host_tests.zig) |
| `idf-bootstrap/`     | 最小 IDF 工程：只为产出 bootloader、分区表、`flash_args`                          | —                                                                                            |
| `tools/flash.sh`     | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                    | [查看](/static/code/#/zig-esp32-s31/ch15-observability-testing-stability/tools/flash.sh)     |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置
single-app-large）、没有 `components/`、没有 `run.log`（真机未跑）。
生成物 `zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 都不入库。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh
zig version   # 必须 0.17.x
```

## 构建

### 1. 主机侧单测（不需要开发板）

```bash
cd practice/zig-esp32-s31/ch15-observability-testing-stability
zig build test --summary all
```

`zig build test` 只编译 `src/host_tests.zig`，它只 import `trace.zig` 与
`watchdog.zig`。九个具名用例（`zig build test` 实际报 `All 10 tests passed`，多出的一个是根文件的容器 test）覆盖：空环、顺序、覆盖与丢弃计数、记录尺寸/格式化、
reset、watchdog 边界（恰好等于 deadline 不超时）、`checkAndRecover` 计数、
时钟回退不误报。设备侧自检（链接符号、寄存器、时钟校准）**无法**在主机上跑。

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

`Segments Information` 里必须正好两行 `DROM, IROM`：
`0x40000020`（`.flash.text`）与 `0x40020020`（`.flash.rodata`）。
S31 的二级 bootloader 在 `SOC_MMU_DI_VADDR_SHARED=1` 下断言 `rom_index == 2`，
少一个或三个 flash 段都会 `Assert failed`。（SRAM 段与 PADDING 段不算 flash 段。）

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

脚本读 `flash_args`，保留 `--flash_mode`/`--flash_freq`/`--flash_size` 与
bootloader、partition-table 两行（偏移一律不手抄），把 `0x10000` 那一行
替换成 `app.bin` 的绝对路径，再 `cd` 到该 build 目录执行 esptool。

## 运行

串口 115200 8N1 打开 UART0（GPIO58/59）。下面是**目标形态**（验收目标，不是实测日志）：

```text
ch15-observability-testing-stability | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
build: stress=0 panic_demo=1 trace_cap=32
clock: TIMG0 T0 1MHz (XTAL 40MHz / 40), MIE=0, no scheduler
wdt: rtc before=0xc0000000 after=0x0 tries=1
check: begin - symbols, regions, clock, interrupt, watchdog, trace
check: flash image=0x40000020 text=0x40000120..0x4000xxxx
check: flash drom=0x40020020..0x4005f020 rodata=0x40020020..0x400208a0 ok=1
check: sram trap=0x2f000000..0x2f00006c data=0x2f000070..0x2f000070
check: sram bss=0x2f000070..0x2f000390 heap=0x2f000390..0x2f076fc0
check: sram stack=0x2f076fc0..0x2f07afc0 expect_top=0x2f07afc0 size=0x4000
check: sram trap_ok=1 data_ok=1 bounds_bits=0x3f ok=1
check: clock ctrl=0x... apb_en=1 t0_clk_en=1 src=0 ok=1
check: clock delay=1000us measured=<n>us ratio=<n>% advisory=ok
check: irq mtvec=0x2f000003 base=0x2f000000 trapEntry=0x2f000000 mode=3 (info)
check: irq MIE=0 mie=0x0 thresh=<n> clic[16]=0x... ok=1
check: wdt cfg=0x0 en=0 stages=0x0 flashboot=0 wprotect=0x0 ok=1
check: trace cap=32 count=32 dropped=3 oldest=0x3 newest=0x22 ok=1
checks: passed=8 failed=0 total=8 advisory=1 (clock calibration)
hb: seq=0 t=250ms ring=3/32 span=<n>us
...
hb: seq=7 t=2000ms ring=<n>/32 span=<n>us
assert: ok tag=trace capacity is 32
assert: caught tag=demo: injected invariant failure action=recover
assert: demo caught=1 (recoverable path exercised)
wdt: deadline=100ms early_expired=0 recovered=1 trips=1
wdt: demo only - production should escalate to trap.panic
assert: ok tag=watchdog deadlines
stress: skipped (build with -Dstress=true for the 30 s soak)
main: panic demo - next instruction is illegal (0x00000000)
panic: injecting illegal instruction 0x00000000
panic: exception code=2 (illegal instruction) cause=0x30000002
panic: mepc=0x4000xxxx mtval=0x0 mstatus=0x...
panic: ra=0x4000xxxx a0=0x... a1=0x... a2=0x...
trace: t=<n>us tag=panic a=0x2 b=0
...
dump: trace shown=8/<n> pushed=<n> dropped=<n>
panic: halted (wfi)
```

判读规则：

- `checks: passed=8 failed=0 advisory=1`：八条硬判据全过（flash 1 + sram 3 +
  clock 门控 1 + irq 1 + wdt 1 + trace 1）；时钟 1 ms 校准是 advisory，单独打印。
- `check: clock delay ... measured` 落在 `[800, 1200]` 时 `advisory=ok`。
  **具体数字必须来自真机**；超出范围不会 panic，但所有 µs 时间戳都不可信。
- `check: irq base == trapEntry`：`mtvec` 的 BASE 指向 SRAM 里的入口；
  `mode=3` 是 S31 的 WARL 行为（CLIC 模式），不是失败。
- `check: wdt stages=0`、`flashboot=0` 且 `en=0`：关狗步骤确实生效（旧序列 `en=1` 是 WPROTECT 没解），
  单看 EN 会误判（首轮就是这么误判的）。
- `assert: caught ... action=recover` 之后程序**继续**；`panic:` 之后停在 `wfi`。
- `hb` 的 `t` 是相对启动的毫秒数；`span` 是环里最早与最新记录的时间差。

## 证据与边界

1. **为什么自检要读寄存器而不是“相信初始化代码”**：初始化代码与寄存器之间
   隔着 bootloader、clock tree、复位域。本章的 `clock` 与 `wdt` 两组都是
   “读回值 + 期望”，任何一步被上游改动都会在启动第一行暴露。
2. **为什么 trace 记录不是 16 字节**：`u64` 时间戳 + `u8` tag + 两个 `u32`
   在 RISC-V ILP32 下按 8 对齐是 24 字节。硬塞成 16 字节需要把时间戳降成
   `u32`（71 分钟回绕）或去掉一个载荷；本章选择诚实的 24 字节。
3. **为什么 panic 里也要打印 trace**：崩溃时寄存器只说明“最后一条指令是
   什么”，trace 说明“最后 8 个业务事件是什么”。后者的信息量通常更大。
4. **为什么非法指令演示是必要的**：dump 代码只有真的跑过一次才算存在。
   默认 `-Dpanic-demo=true`；要跑长时间 soak 时用 `-Dpanic-demo=false`，
   程序在心跳与 watchdog 演示后停在 `wfi`。
5. **为什么软件 watchdog 不在超时后复位**：本章演示的是“检测 + 恢复计数”，
   生产代码应把 `checkAndRecover` 返回 true 的分支升级为 `trap.panic` 或
   受控重启。这个边界写在 `main.zig` 的 `watchdogDemo` 注释里。

## 待复跑确认

- [ ] `zig build ... -Doptimize=ReleaseSmall` 退出码 0
- [ ] `zig build test` 退出码 0（`All 10 tests passed`）
- [ ] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [ ] `image-info` 的 Segments 表正好两行 `DROM, IROM`：`0x40000020`、`0x40020020`
- [ ] `bash -n tools/flash.sh` 退出码 0
- [ ] 串口出现 banner、`checks: passed=8 failed=0 advisory=1`
- [ ] `check: clock ... advisory=ok`（`measured` 在 `[800, 1200]`）
- [ ] `check: irq base == trapEntry` 且 `MIE=0`
- [ ] `check: wdt cfg=0x0 en=0 stages=0x0 flashboot=0`
- [ ] 8 条 `hb`，`t` 单调递增，`ring` 不超过 32
- [ ] `assert: caught ... action=recover` 后程序继续
- [ ] `wdt: ... recovered=1 trips=1`
- [ ] 默认构建在 `panic:` 之后停在 `wfi`，复位后重复出现同样的 dump
- [ ] `-Dstress=true` 构建：`stress: end elapsed≈30000ms`、`verdict=pass`
- [ ] 连续复位 10 次，`checksum` 与 `checks:` 行完全一致
