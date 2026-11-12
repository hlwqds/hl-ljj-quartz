# ch14 双核 SMP 与 IPI：把两个核带到同一个时间轴上

> 所属章节：[[ch14-dual-core-smp-ipi|第十四章：双核 SMP 与 IPI]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
> 本工程**已上板（2026-11-13）**：`core1: up hart=1`、IPI ping-pong、`jobs … migrated=2`、
> `lat[rtt] avg≈1573 ticks（≈98.3 µs）`，原始输出见 `../logs/ch14-boot.log`。
> README 与正文里未标“实测”的日志、tick 数仍是验收目标。

## 目的

这是形态 B 的第九个工程，骨架沿用 `ch13-heap-stack-caps`：Zig 自己产 ELF、
`linker/s31.ld` 决定段布局、`_start` 是 core0 的入口、应用镜像由
`esptool elf2image` 生成，IDF 只负责二级 bootloader 与分区表
（`idf-bootstrap/`）。

在不变的骨架上，本章把单核内核扩成两颗核：

| 主题              | 落点                           | 本章用它证明什么                                      |
| ----------------- | ------------------------------ | ----------------------------------------------------- |
| core1 启动        | `src/smp.zig`                  | 时钟、复位、PMU stall、ROM 引导地址四个动作缺一不可   |
| 每核数据          | `PerCpu` + `mscratch`          | 同一份代码、同一份 .bss，靠 mscratch 找“我是谁”       |
| 每核 CLIC         | `src/clic.zig`                 | 0x10800000 是本核、+0x10000 是对核的别名关系          |
| CLIC 软件中断 IPI | `src/clic.zig` + `src/smp.zig` | 源 65/66 → 目标核矩阵 → 输入 19/20，可清可屏蔽        |
| 跨核唤醒          | `src/sched.zig`                | 远端入队（目标核锁）+ `fence` + IPI，零轮询           |
| 负载均衡          | `src/demo.zig` 阶段 B          | push 迁移：把一半 job 挂到另一个核的队列              |
| 内存屏障          | `src/hw.zig`                   | `fence rw,rw` 是 release 的最低要求；`fence.i` 的边界 |

### 三个可判读的阶段

`src/demo.zig` 由 prio 5 的 `supervisor`（core0）串起三个阶段：

| 阶段 | 谁在跑                                | 打印                                                          |
| ---- | ------------------------------------- | ------------------------------------------------------------- |
| A    | `supervisor`(core0) / `worker`(core1) | `sup: phase A ...`、`lat[rtt]: ...`、`lat[isr->task]: cpu0/1` |
| B    | 4 个 `job`（2+2 分布在两核）          | `bal: push jobs ...`、`jobs: total=4 core0=2 core1=2 ...`     |
| C    | `supervisor`                          | `cpu0: ticks=... ipis_in=...`、`cpu1: ...`、`barrier: ...`    |

验收的核心是两条：

1. **两个核的 `ipis_in`/`ipis_out` 都非零**：说明 ping-pong 是两个方向都走
   IPI，而不是 core0 单方面轮询共享变量；
2. **`jobs: core0 + core1 == total`，且 `migrated == 2`**：说明任务真的在
   两个核的队列之间迁移并被各自执行。

### 工程不做的事

- **不做全局就绪队列**：每核一条队列，跨核只做“远端入队 + IPI”。
  代价是负载不均时需要显式迁移（本章用 push，不做 steal）。
- **不做 steal**：偷取需要“对方队列尾部 + 对方是否空闲”的判据与回滚，
  本章只演示同一条硬件链路上的 push 迁移。
- **不做多核同步原语的完整集合**：只有核队列锁（自旋 + 关本核中断），
  没有跨核互斥量、没有优先级继承（ch12 的单核版本已证明协议）。
- **不做 FP 上下文**：两个核共用 80 字节 trap 帧 / 64 字节 switch 帧，
  FP 任务的 208 字节变体见 ch11 的边界说明。
- **不在中断里打印**：串口是共享设备，ISR 打印会遇到“任务持锁、ISR 等锁”
  的自死锁。所有观测值先进 `PerCpu` 计数器，最后在 supervisor 里打印一次。

## 硬件与接线

| 项       | 事实                                                             |
| -------- | ---------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                   |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM          |
| 核数     | 2（`soc_caps.h:175` `SOC_CPU_CORES_NUM (2U)`）                   |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥  |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位               |
| 观测     | 只需串口。本章不新增外部接线，不需要示波器（延迟以 SYSTIMER 计） |

## 寄存器 / 指令速查

| 项                             | 值 / 位置                                          | 说明                                                 |
| ------------------------------ | -------------------------------------------------- | ---------------------------------------------------- |
| `mhartid`                      | CSR 0xF14                                          | 本核编号；IDF 的 `rv_utils_get_core_id()` 就是读它   |
| `mscratch`                     | CSR 0x340                                          | 每 hart 一个 XLEN 寄存器，本章存 `&PerCpu[hart]`     |
| `mintthresh`                   | CSR 0x347                                          | S31 `INTTHRESH_STANDARD=1`，阈值只能写这个 CSR       |
| CLIC 门限（内存映射）          | `0x10800008`                                       | **S31 上不生效**；仅 `INTTHRESH_STANDARD=0` 的芯片用 |
| CLIC 控制字                    | `0x10801000 + 4*i`（对核 +0x10000）                | byte0 IP、byte1 IE、byte2 ATTR、byte3 CTL            |
| `HP_SYSTEM_CPU_INT_FROM_CPU_n` | `0x20586010` / `0x20586014`                        | 写 1 触发源 65/66，写 0 清源                         |
| 中断矩阵 core0 / core1         | `0x20585000` / `0x20585800`                        | `+4*源`，MAP[5:0] = CLIC 输入号                      |
| core1 时钟/复位                | `HP_SYS_CLKRST+0x20`：bit0/bit1 置 1、bit2 清 0    | CORE1_CLIC_CLK_EN / CPU_CLK_EN / GLOBAL_RST_EN       |
| core1 stall                    | `PMU+0x1EC` 的 [23:16]，0xFF = 运行                | `PMU_HPCORE1_SW_STALL_CODE`                          |
| core1 引导地址                 | ROM `ets_set_appcpu_boot_addr` = `0x2f8000a8`      | 写 `core1Entry` 的地址                               |
| 停核状态                       | `HP_SYSTEM+0x64` 的 bit1                           | CORESTALLED_ST，解 stall 后应清零                    |
| SYSTIMER                       | `0x20399000`；CONF+0x00 bit31、VAL HI/LO=0x40/0x44 | 全局 52 位计数，跨核唯一可比的时间轴                 |
| SYSTIMER 时钟门                | `HP_SYS_CLKRST+0x120` bit0 + bit4                  | 两个都要置 1（真机约束 6）                           |
| `fence rw, rw`                 | 基座 I                                             | 发布共享状态后再发 IPI 的最低要求                    |
| `fence.i`                      | Zifencei                                           | 只影响**本核**取指；别的核要各自 fence.i             |
| trap 帧 / switch 帧            | 80 字节 / 64 字节                                  | 与 ch10–ch13 完全一致；两个核共用同一个 trapEntry    |

## 文件表

| 路径                               | 角色                                                                                         | 代码浏览                                                                                     |
| ---------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `build.zig`                        | 目标串 + 链接脚本 + 可执行产物 `zig-out/bin/app.elf`                                         | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/build.zig)                        |
| `linker/s31.ld`                    | `.app_desc` 最前、`.text.trap`、`.trap_ram` 进 SRAM、两个 flash 段                           | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/linker/s31.ld)                    |
| `src/start.zig`                    | `esp_app_desc_t`（256 字节）+ naked `_start`：关中断 → sp/gp → 关 RWDT → 清 `.bss` → `mtvec` | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/start.zig)                    |
| `src/core1.zig`                    | core1 的入口（naked）：sp/gp/mtvec → `core1Main`；IPI/tick/ready → 调度器                    | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/core1.zig)                    |
| `src/smp.zig`                      | **本章核心**：`PerCpu`、`mscratch`、core1 启动、IPI 收发、延迟统计                           | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/smp.zig)                      |
| `src/clic.zig`                     | 每核 CLIC：本核/对核别名、优先级、pending、`mintthresh` CSR、矩阵路由                        | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/clic.zig)                     |
| `src/sched.zig`                    | 每核就绪队列、`switchCore`、`blockIf`（谓词复查）、`wakeRemote`、trap 分发                   | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/sched.zig)                    |
| `src/context.zig`                  | 帧布局、`trapEntry`（`.trap_ram`）、`switchRaw`（mscratch）、`taskStart`                     | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/context.zig)                  |
| `src/tick.zig`                     | TIMG0 T0/T1 两个 1 ms 通道；共享时钟门只写一次                                               | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/tick.zig)                     |
| `src/systimer.zig`                 | 52 位全局时间轴；HI→LO→HI 复读检测跨核快照撕裂                                               | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/systimer.zig)                 |
| `src/hw.zig`                       | 寄存器/CSR 薄封装与 `fence` 三连                                                             | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/hw.zig)                       |
| `src/console.zig`                  | 双核共用的 `esp_rom_printf` + 自旋锁串行化                                                   | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/console.zig)                  |
| `src/demo.zig`                     | 阶段 A/B/C：ping-pong、push 迁移、汇总打印                                                   | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/demo.zig)                     |
| `src/main.zig`                     | banner、core0 中断拓扑、建任务、启动 core1、交出控制权                                       | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/src/main.zig)                     |
| `idf-bootstrap/CMakeLists.txt`     | 最小 IDF 工程根：只为产出 bootloader 与分区表                                                | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/idf-bootstrap/CMakeLists.txt)     |
| `idf-bootstrap/main/*`             | 空 `app_main`，让 IDF 构建走完                                                               | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/idf-bootstrap/main/app_main.c)    |
| `idf-bootstrap/sdkconfig.defaults` | 16 MB Flash + single-app-large（factory 在 `0x10000`），不启用 PSRAM                         | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/idf-bootstrap/sdkconfig.defaults) |
| `tools/flash.sh`                   | 读 `flash_args`、替换应用行、一次烧 bootloader + 分区表 + 应用                               | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/tools/flash.sh)                   |
| `README.md`                        | 本文件                                                                                       | [查看](/static/code/#/zig-esp32-s31/ch14-dual-core-smp-ipi/README.md)                        |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置
single-app-large）、没有 `components/`、没有 `run.log`（真机未跑）。
生成物 `zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 都不入库。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh
zig version   # 必须 0.17.x
```

`-Dcpu` 里的 `+a` 不是可选的：本工程用 `@cmpxchgWeak` 与 `amoadd` 做锁和计数，
没有 A 扩展时汇编器会直接拒绝。`+zifencei` 也是显式的：`fence.i` 在本章
只出现在“为什么这里不需要它”的注释里，但边界讨论要求它可编译。

## 构建

### 1. 应用 ELF（纯 Zig，无 idf.py）

```bash
cd practice/zig-esp32-s31/ch14-dual-core-smp-ipi

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

### 2. 应用镜像（必须看到两个 flash 段）

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf

esptool --chip esp32s31 image-info zig-out/bin/app.bin
```

`image-info` 的 Segments 表里必须正好有两行 `DROM, IROM`：
`0x40000020`（.flash.text）与 `0x40020020`（.flash.rodata）。
S31 的二级 bootloader 在 `SOC_MMU_DI_VADDR_SHARED=1` 下断言 `rom_index == 2`，
少一个或三个段都会 `Assert failed`。表里还会出现 DRAM 与 PADDING 行
（`.trap_ram`、`.bss` 与 esptool 的对齐填充），它们不计入那两个 flash 段，
ch12/ch13 的镜像也是同样的形状。

### 3. bootloader 与分区表（供应商步骤）

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

产物：`idf-bootstrap/build/bootloader/bootloader.bin`、
`idf-bootstrap/build/partition_table/partition-table.bin`、`idf-bootstrap/build/flash_args`。

### 4. 烧录

```bash
sh tools/flash.sh /dev/ttyUSB0     # Linux
```

脚本读 `flash_args`，保留 `--flash_mode`/`--flash_freq`/`--flash_size` 与
bootloader、partition-table 两行（偏移一律不手抄），把 `0x10000` 那一行替换成
`app.bin` 的绝对路径，再 `cd` 到该 build 目录执行 esptool。脚本不调用 `idf.py`。

## 运行

串口 115200 8N1 打开 UART0（GPIO58/59）。下面是**目标形态**（验收目标，不是实测日志）：

```text
ch14-dual-core-smp-ipi | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default, shared lock)
mtvec: base=0x2f000000 mode=0 (0 = direct, same entry on both harts)
frames: trap=80 switch=64 bytes (integer only)
cpu: hart=0 mhartid, cores=2, per-cpu state via mscratch
ipi: clic input 19->core0 / 20->core1 via src 65/66
tick: core0=TIMG0_T0 src 25 / core1=TIMG0_T1 src 26 -> input 16 each
sched: 6 tasks created, 1 queued on core0 (+1 idle per core)
core1: up hart=1 sp=0x2f00xxxx clic_ipi=input 20 tick=TIMG0_T1/input 16
core1: ready flag observed by core0 (release/acquire)
sched: core0 handing over to idle (MIE opens on idle stack), mscratch=0x2f00xxxx
sup: core0 phase A - ipi ping-pong rounds=32
sup: phase A done - core0 pings=<n> core1 pings=<n>
bal: push jobs -> core0=2 core1=2 (one IPI per remote enqueue)
jobs: total=4 core0=2 core1=2 migrated=2 steps_each=6
lat[rtt]: core0 round-trip (wake->work->wake) min=<a> avg=<b> max=<c> systimer ticks
lat[rtt]: ~ min=<x>.<xx> avg=<y>.<yy> max=<z>.<zz> us (assume 16 MHz)
lat[isr->task]: cpu0 min=<a> avg=<b> max=<c> n=<k> systimer ticks
lat[isr->task]: cpu1 min=<a> avg=<b> max=<c> n=<k> systimer ticks
cpu0: ticks=<t0> ipis_in=<i0> ipis_out=<o0> wakeups=<w0> pings=<p0> switches=<s0> jobs=2
cpu1: ticks=<t1> ipis_in=<i1> ipis_out=<o1> wakeups=<w1> pings=<p1> switches=<s1> jobs=2
barrier: clic mintthresh=0x1f (0x1f = allow all levels 1..7)
result: A/B/C complete (target shape; numbers are 待真机验证)
```

判读规则：

- `ipis_in`/`ipis_out` 在两个核上都非零：双向 IPI 链路成立。
- `jobs: core0 + core1 == 4` 且 `migrated == 2`：任务在两核队列间迁移并各自执行。
- `ticks` 两个核都非零：TIMG0 T0/T1 两条独立通道都在投递（每核 1 ms）。
- `lat[rtt]` 的量级预期是“IPI 投递 + 一次 trap + 一次换栈 + 一小段忙等”，
  具体数字**必须来自真机**；`lat[isr->task]` 必然小于 `lat[rtt]`
  （前者只含本核 ISR→任务，含不了对端的执行时间）。
- `barrier: mintthresh=0x1f`：S31 的阈值走 CSR；如果这里读回 0 或异常值，
  说明中断会在 `mret` 后立刻重复投递（或全被屏蔽），两个现象都很好认。

## 证据与边界

### 1. 为什么每核数据必须用 mscratch，而不是全局数组 + mhartid

`mscratch` 是每 hart 独立的 CSR，读写各一条指令，不占通用寄存器；
`switchRaw` 与 `trapEntry` 里都只需要一条 `csrr`。用“全局数组 + 每次读
`mhartid`”也能工作，但 trap 入口要额外压一个寄存器、并且每次都要做
数组缩放；更糟的是，`mhartid` 在 `switchRaw` 的 naked 代码里没法安全地
当成“当前上下文”的索引 —— 迁移后的任务在另一个核上恢复时，它的
`save_slot` 属于**新**核的 PerCpu，这一点只有“由当前核决定”的 mscratch
能表达。

### 2. 为什么 switch_save_slot 不能是全局变量

ch10–ch13 的 `switch_save_slot`/`switch_target_sp` 是两份模块级变量。
SMP 下两个核可能同时进入 `switchTo`：core0 写好 `switch_target_sp = A`、
core1 紧接着写 `switch_target_sp = B`，core0 的 `switchRaw` 就会把 sp 换成
B —— 两个任务跑在同一个栈上，现场立刻崩。本章把它们放进 `PerCpu`，
`switchRaw` 用 `mscratch` 取本核那一份，`smp.zig` 用 `@offsetOf` 断言
偏移 0/4 与汇编一致。

### 3. 为什么“远端入队”必须在目标核的锁里改 state

`wakeRemote` 在目标核锁内做三件事：检查 `state == .blocked`、改成 `.ready`、
入队。若把“检查”放在锁外，就会出现：检查时任务是 blocked → 目标任务
自己先被 tick 唤醒并跑起来 → 我们再把它挂进队列 → 同一个 TCB 在环上出现
两次，出队一次后仍然“幽灵”可跑。这是 ch11 “pickNext 复活 done 任务”的
SMP 版本。

### 4. 丢唤醒的两个形状，以及 `blockIf` 怎么关掉它

```text
A：检查条件（不满足）
B：                        ← 对方在这里满足条件并 wakeRemote（看到 running，忽略）
A：标 blocked 并切走       ← 永远等不到下一次唤醒
```

`blockIf(pred)` 把“标 blocked → 复查 pred → 切走”放进**目标核的锁**，
与 `wakeRemote` 的“锁内检查 blocked → 入队”互斥。于是只有两种时序：
条件在锁内已满足（不阻塞直接返回），或条件在锁内未满足（必然已 blocked，
对方的 wake 一定入队）。

### 5. 屏障到底防什么

- `fence rw, rw`（发 IPI 之前）：保证“队列/状态写”先于“触发寄存器写”
  被对端看到。没有它，对端可能在中断里醒来却读到旧队列。
- `fence rw, rw`（取锁之后）：保证锁内读到的数据不早于锁本身。
  `@cmpxchgWeak(..., .acquire)` 已经给了 acquire 语义，显式 fence 是
  为了把“MMIO 与普通内存混排”这条也覆盖住。
- `fence.i`：只让**本核**的取指看到刚写进内存的指令。本章不用它（没有
  运行时生成代码）；如果将来做 patch/跳板，写完代码的核要 fence.i，
  另一个核也必须各自 fence.i，否则它可能继续执行 cache 里的旧指令。

### 6. 为什么延迟用 SYSTIMER 而不是 mcycle

`mcycle` 是每 hart 一份的周期计数，两个核的起点不同，跨核相减没有意义。
SYSTIMER 是全局 52 位计数，是本章唯一正确的时间轴。代价是它的
VAL HI/LO 是**共享快照**：两个核同时请求 UPDATE 时会互相打断，
所以 `now()` 用 HI→LO→HI 复读，前后 HI 不同就重试。

### 待真机验证

- [ ] `zig build ... -Doptimize=ReleaseSmall` 退出码 0
- [ ] `esptool elf2image` 打印 `Merged 2 ELF sections.`
- [ ] `image-info` 的 Segments 表正好两行 `DROM, IROM`：`0x40000020`、`0x40020020`
- [ ] `bash -n tools/flash.sh` 退出码 0
- [ ] 串口出现 banner，`cpu: hart=0`，`mtvec: base=0x2f000000 mode=0`
- [ ] `core1: up hart=1 ...` 与 `core1: ready flag observed` 两行都出现
      （否则 core1 的时钟/复位/stall/引导地址四步里有一处没生效）
- [ ] `sup: phase A - ipi ping-pong rounds=32` 之后 `phase A done` 出现，
      且 `core0 pings` 与 `core1 pings` 都约等于 32
      （`ipis_in` = IPI 到达数；`wakeups` = 因 IPI 真正恢复的任务次数）
- [ ] `jobs: total=4 core0=2 core1=2 migrated=2`（迁移真的发生）
- [ ] `lat[rtt]` 的 max 明显大于 min（说明测到的是真实调度路径，不是常量）
- [ ] `lat[isr->task]: cpu1` 已记录（core1 的 IPI 输入 20 真的投递了）
- [ ] 连续复位 10 次，`jobs` 的分布稳定为 2/2，不出现 core1 整核无输出
- [ ] 若 core1 无任何输出：依次检查 `HP_SYS_CLKRST+0x20` 的 bit0/bit1/bit2、
      `PMU+0x1EC` 的 [23:16]、`HP_SYSTEM+0x64` 的 bit1，以及 ROM 引导地址
      是否是 `core1Entry` 的地址（Zig 默认不产符号表：用
      `objdump -d --section=.text zig-out/bin/app.elf` 找第一条 `call` 之前
      那段序言，或临时加 `-femit-asm` 对照）
- [ ] 若 IPI 不投递：先确认 `mintthresh`（CSR 0x347）读回 `0x1f`，
      再确认目标核矩阵 `[源]` 的 MAP[5:0] 是 19/20，最后确认
      `HP_SYSTEM_CPU_INT_FROM_CPU_n` 写完是否为 1
