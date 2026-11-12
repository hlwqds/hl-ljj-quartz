# ch13 堆、栈保护与内存 caps：分配器自己写

> 所属章节：[[ch13-heap-stack-caps|第十三章：堆、栈保护与内存 caps]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是形态 B 的第七个工程，骨架完全沿用 `ch11-preemptive-scheduler`：Zig 产出
ELF、`linker/s31.ld` 决定段布局、`_start` 是入口、应用镜像由 `esptool
elf2image` 生成，IDF 只负责二级 bootloader 与分区表（`idf-bootstrap/`）。

在不变的骨架之上，本章只做"内存"这一件事：

| 模块                  | 做什么                                                                   | 可观测量                                    |
| --------------------- | ------------------------------------------------------------------------ | ------------------------------------------- |
| `src/alloc/tlsf.zig`  | 两级位图索引（fl/sl）、块头 + 界限标记、切分与双向物理合并、对齐分配     | `heap: total=… used=… free=… largest=…`     |
| `src/alloc/slab.zig`  | 固定尺寸槽（16/32/64/128/256）、1 KiB 页、u64 位图、页从 TLSF 借用       | `slab: class=… pages=… used=… waste=…`      |
| `src/caps.zig`        | 六个地址空间 + 能力集合（exec/8bit/dma/internal/psram/retention）+ 归类  | `space: <name> = 0x… -> <region>`           |
| `src/heap.zig`        | 从链接符号 `_heap_start/_heap_end` 定义 arena、caps 检查、预算表         | `budget: sram …`、`heap: …`                 |
| `src/stack_guard.zig` | 主栈填魔数 + 边界哨兵 + 高水位；模拟任务栈的"踩哨兵 → 必须报 overrun"    | `stack: main … sentinel=ok`、`stack: sim …` |
| `src/psram.zig`       | 只读探针：读 PSRAM 侧 MMU 页大小与表项有效位，没有映射就打印 `mapped=no` | `psram: window=… mmu_valid_entries=…`       |
| `src/main.zig`        | 编排五组观测，全部同步执行（本章不开中断）                               | 串口行序                                    |

工程**不做**的事，同样重要：

- **不初始化 PSRAM**：bootloader 没开 `CONFIG_SPIRAM`，本章也不建 MMU 映射。
  `psram.zig` 只读表项、只在"确实已映射"时才做读写校验。
- **不配硬件 SP 监视器**：`bus_monitor` 的 `SP_MIN/SP_MAX` 与中断源 119 写在
  正文 13.7，本章只读不配（需要开中断，留给 ch14/ch15）。
- **不把 slab 空页还给 TLSF**：1 KiB 的确定性比抖动更值钱，预算按峰值报。
- **不开中断**：`MIE = 0` 全程不变；`trapEntry` 仍装好，用于打印非法访问现场。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行：`zig build` 与 `esptool` 在本仓执行过
> （产物是两个 flash 段），但**上板、串口输出、PSRAM 探针结果全部待真机验证**。
> README 不附 `run.log`，也不贴任何"看起来像实测"的日志。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 观测     | 串口即可；本章不新增外部接线                                    |

## 内存地图（本章用到的全部数字）

| 区间                 | 地址                               | 来源                                           |
| -------------------- | ---------------------------------- | ---------------------------------------------- |
| SRAM（物理 512 KiB） | `0x2F000000` + `0x80000`           | `soc.h` `SOC_IRAM_LOW/HIGH`                    |
| SRAM（应用可用）     | `0x2F000000` + `0x7AFC0`           | `ld.hp_mem_defs` `SRAM_SEG_END`                |
| LP SRAM              | `0x2E000000` + `0x8000`            | `soc.h` `SOC_RTC_IRAM_LOW/HIGH`                |
| ROM                  | `0x2F800000` + `0x50000`           | `soc.h` `SOC_IROM_MASK_LOW/HIGH`               |
| Flash 线性窗口       | `0x40000000` + 64 MiB              | `ext_mem_defs.h`（1024 × 64 KiB）              |
| PSRAM 线性窗口       | `0x50000000` + 64 MiB              | `ext_mem_defs.h` `SOC_MMU_PSRAM_VADDR_BASE`    |
| PSRAM 侧 MMU 寄存器  | `0x20502000` + `0x37C/0x380/0x384` | `spi_mem_s_reg.h`（`DR_REG_PSRAM_MSPI0_BASE`） |

本工程自己的布局（`linker/s31.ld`）：

```text
0x40000020  .flash.text    .app_desc(256B) + .text.trap + .text     (镜像第 0 段)
0x40020020  .flash.rodata  .rodata/.srodata                          (镜像第 3 段)
0x2F000000  .trap_ram      trap 入口（必须在 SRAM）
            .data / .bss   静态数据；_bss_end == _heap_start
            [_heap_start, _heap_end)   TLSF arena（约 480 KiB）
            [_stack_bottom, _stack_top) 主栈 16 KiB，sp 初值 = _stack_top
0x2F07AFC0                 应用可用 SRAM 的上界（再往上是 bootloader）
```

## 文件表

| 路径                  | 角色                                                                            | 代码浏览                                                                               |
| --------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `build.zig`           | 目标串 + 链接脚本 + `zig-out/bin/app.elf`                                       | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/build.zig)                    |
| `linker/s31.ld`       | 两个 flash 装载段、`.trap_ram`、`_heap_start/_heap_end`、16 KiB 主栈            | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/linker/s31.ld)                |
| `src/start.zig`       | `esp_app_desc_t` + naked `_start`（关中断 → sp/gp → 关 RWDT → 清 .bss → mtvec） | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/start.zig)                |
| `src/trap.zig`        | `.trap_ram` 里的 trap 入口 + 现场打印（`mcause & 0x1F` / 中断看 bit31）         | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/trap.zig)                 |
| `src/log.zig`         | `esp_rom_printf("%s")` 包装，Zig 侧格式化                                       | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/log.zig)                  |
| `src/alloc/tlsf.zig`  | TLSF：两级索引、块头、合并、对齐、`verify/verifyLists/verifyFlags`              | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/alloc/tlsf.zig)           |
| `src/alloc/slab.zig`  | slab：尺寸类、页借用、位图槽、内部碎片统计                                      | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/alloc/slab.zig)           |
| `src/caps.zig`        | 地址空间表 + `Caps` 能力位 + `regionOf/find/tag`                                | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/caps.zig)                 |
| `src/heap.zig`        | arena 接线、caps 检查、预算表、结构自检                                         | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/heap.zig)                 |
| `src/stack_guard.zig` | 哨兵 / 高水位 / 模拟溢出                                                        | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/stack_guard.zig)          |
| `src/psram.zig`       | PSRAM 窗口常量 + 只读 MMU 探针                                                  | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/psram.zig)                |
| `src/main.zig`        | 五组观测的编排                                                                  | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/src/main.zig)                 |
| `idf-bootstrap/`      | 最小 IDF 工程（仅源文件，无 `build/`）：产出 bootloader、分区表与 `flash_args`  | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/idf-bootstrap/CMakeLists.txt) |
| `tools/flash.sh`      | 读 `flash_args`、替换 `0x10000` 应用行、一次烧三段                              | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/tools/flash.sh)               |
| `README.md`           | 本文件                                                                          | [查看](/static/code/#/zig-esp32-s31/ch13-heap-stack-caps/README.md)                    |

工程没有 `build.zig.zon`（零 Zig 依赖）、没有 `partitions.csv`（用 IDF 内置的
single-app-large）、没有 `run.log`（真机未跑）。生成物 `zig-out/`、`.zig-cache/`、
`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig` 一律不入库（SPEC §6）。

`idf-bootstrap/` 只有四个源文件（根 `CMakeLists.txt`、`main/CMakeLists.txt`、
`main/app_main.c`、`sdkconfig.defaults`），**不含任何预编译产物**：`build/` 里的
`bootloader.bin`、`partition-table.bin` 与 `flash_args` 必须由本机自己生成一次，
且按 SPEC §3.2/§6 不入库。生成命令见下面「4. bootloader 与分区表」。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥ 5.2）

```bash
. /tmp/idfenv.sh                 # 或 . $IDF_PATH/export.sh
zig version                      # 必须是 0.17.1
esptool version                  # ≥ 5.2
```

## 构建

### 1. 应用 ELF

```bash
cd practice/zig-esp32-s31/ch13-heap-stack-caps

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
# Segment 0: 0x40000020 DROM, IROM
# Segment 3: 0x40020020 DROM, IROM
```

### 3. 主机侧单测（不碰硬件）

```bash
zig test src/alloc/tlsf.zig    # 5 个测试：基本/对齐/耗尽/双重释放/随机压力
zig test src/alloc/slab.zig    # slab 分页复用 + 顺带跑 tlsf
zig test src/caps.zig          # 地址归类与能力匹配
```

### 4. bootloader 与分区表（本机生成一次，不入库）

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

产物（`build/` 按 SPEC §3.2/§6 不入库）：

```text
idf-bootstrap/build/bootloader/bootloader.bin
idf-bootstrap/build/partition_table/partition-table.bin
idf-bootstrap/build/flash_args        # 偏移的唯一来源
```

本仓**不提供**预编译的 bootloader / 分区表 / `flash_args`：`tools/flash.sh` 在
缺 `flash_args` 时会明确报错退出，而不是退回到手抄偏移。

### 5. 烧录

前置：`idf-bootstrap/build/flash_args` 必须先由第 4 步生成（本仓不提供预编译产物）：

```bash
cd idf-bootstrap && idf.py --preview set-target esp32s31 && idf.py build && cd ..
```

```bash
sh tools/flash.sh /dev/ttyUSB0
```

脚本只读 `idf-bootstrap/build/flash_args`（缺失时明确报错退出，绝不退回手抄偏移），
保留 bootloader / 分区表两行
（**偏移一律不手抄**），把 `0x10000` 那行换成 `app.bin` 的绝对路径，再
`cd` 到该 build 目录执行 esptool。脚本本身**不调用 `idf.py`**。

## 运行（目标形态，非实测日志）

串口按 **115200 8N1** 打开 UART0（GPIO58/59）。行序是确定的，数字是
**验收目标**（`<…>` 处必须由真机填）：

```text
ch13-heap-stack-caps | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
allocator: TLSF fl_shift=5 sl_log2=4 header=16B min_block=32B
budget: image=0x40000020 irom.text=<n>B drom.rodata=<n>B
budget: sram trap=<n>B data=<n>B bss=<n>B heap=<n>B stack=16384B
budget: sram_total=524288B app_usable=503744B static=<n>B heap=<n>permille stack=<n>permille
space: image          = 0x40000020 -> flash_cache
space: text           = 0x40000020 -> flash_cache
space: rodata         = 0x40020020 -> flash_cache
space: trap_vector    = 0x2f000000 -> sram
space: data           = 0x2f00xxxx -> sram
space: heap_start     = 0x2f00xxxx -> sram
space: heap_end       = 0x2f076fc0 -> sram
space: stack_top      = 0x2f07afc0 -> sram
space: rom.ets_printf = 0x2f800024 -> rom
space: psram.window   = 0x50000000 -> psram_cache
space: mmu.psram_reg  = 0x20502000 -> mmio
heap: total=<n> used=0 free=<n> largest=<n> frag=0permille blocks=1 tag=init
heap: verify=ok
alloc: sizes=7 aligned64_ok=7 first=0x…c0 last=0x…
frag: ops=<n> peak_used=<n> free=<n> largest=<n> blocks=<n>
frag: overlap_hits=0 corrupt=0 ooms=<n> frag=<n>permille
heap: total=… used=… free=… largest=… frag=…permille blocks=… tag=after-frag
slab: class= 16B pages=<n> slots=<n> used=<n> waste=<n>B
slab: class= 32B pages=<n> slots=<n> used=<n> waste=<n>B
slab: class= 64B pages=<n> slots=<n> used=<n> waste=<n>B
slab: class=128B pages=<n> slots=<n> used=<n> waste=<n>B
slab: class=256B pages=<n> slots=<n> used=<n> waste=<n>B
slab: borrowed=<n>B waste=<n>B allocs=<n> frees=<n> ooms=<n>
slab: after_release used_slots_total=0 borrowed=<n>B (pages are kept)
heap: total=… used=… free=… tag=after-slab
caps: alloc(internal+8bit, 128)=0x… region=sram
caps: alloc(size=1024) region=psram_cache has no arena in this chapter
caps: alloc(size=64) region=lp_sram has no arena in this chapter
caps: alloc(exec+dma+internal, 64)=0x…
stack: main armed span=16384B fill=0xa5 canary=0xdeadbeef
stack: main span=16384B used=<n>B free=<n>B sentinel=ok canary=0xdeadbeef
stack: sim armed base=0x… len=512B
stack: sim sentinel=ok at=0x… expect=0xdeadbeef got=0xdeadbeef
stack: sim simulate overrun -> write 0x78563412 at 0x…
stack: sim sentinel=overrun at=0x… expect=0xdeadbeef got=0x78563412
stack: sim overrun DETECTED (checker works)
stack: sim sentinel=ok at=0x… expect=0xdeadbeef got=0xdeadbeef
psram: window=0x50000000..0x54000000 entry=1024 page=<n>B chip=16777216B
psram: mmu_valid_entries=<n>/1024 mapped=no|yes
psram: no mapping programmed by bootloader -> skip rw (initialise PSRAM first)
heap: total=… used=… free=… tag=final
heap: verify=ok allocs=<n> frees=<n> ooms=<n>
lab: done (halt)
```

判读要点：

- `heap: verify=ok` 出现在 **每次** 压测之后：块链自洽 + 空闲链自洽 + `PREV_FREE`
  与物理相邻状态一致。任何一项不成立都会打印 `corrupted` 并停下。
- `frag: overlap_hits=0` 说明分配器没有把同一块内存发出去两次（每块首字写了
  本槽的哨兵值，释放时比对）。
- `stack: sim sentinel=overrun` 那一行是**故意的**：只有它能证明检测器会响。
- `psram: mapped=no` 是预期结果（bootloader 没开 `CONFIG_SPIRAM`）。如果这行
  变成 `mapped=yes`，说明你的 bootloader 建了映射，`rw_probe` 才有意义。

## 证据与边界

### 1. 为什么堆起点是 `_heap_start` 而不是某个固定地址

`_heap_start = _bss_end`（链接脚本算出）。静态对象变多，堆自动变短；堆"多大"
不是常数，而是 `_heap_end - _heap_start`。硬编码 `0x2F040000` 之类的地址会在
下一次改布局时静默踩到 `.bss`——这类错误在串口里通常表现为"某个全局变量莫名
变成 0"。

### 2. 为什么 `_bss` 上界要 `ASSERT` 在栈底之下

`ASSERT(_bss_end <= _stack_bottom)` 让"静态对象吃进栈区"变成**构建失败**，
而不是运行期把栈踩掉。裸机里没有 MMU 保护页兜底，构建期检查是唯一便宜的防线。

### 3. 为什么 release 后还有元数据浪费

TLSF 每块 16 字节头（rv32）：`size_and_flags` + `prev_phys` + 两条链指针。
8 字节的最小请求实际占 32 字节（`min_block`），这是"能合并"的价格。slab 正是
为"大量小对象"把这个价格摊薄：64 个 16 字节对象只花一个 16 字节块头 + 位图。

### 4. 为什么 slab 不还页

还页会让"页数"随负载抖动，位图与页描述要重写，且下一次申请可能立刻又借回来。
本章选择"页保留、按峰值报预算"：`slab: borrowed=…B` 就是峰值占用。

### 5. 为什么 PSRAM 只读探针

窗口存在 ≠ 能访问。没建映射时读 `0x50000000` 会进 load access fault（本章会
打印 `trap: exception code=5`），而不是读到 0。所以顺序必须是"先读 MMU 表项
有效位，确认有映射，再解引用"。

### 6. 待真机验证

- [ ] `zig build … -Doptimize=ReleaseSmall` 退出 0（本仓已执行）
- [ ] `esptool elf2image` + `image-info` 出现两个 `DROM, IROM` 段（本仓已执行）
- [ ] `bash -n tools/flash.sh` 通过（本仓已执行）
- [ ] `zig test src/alloc/tlsf.zig` / `slab.zig` / `caps.zig` 全绿（本仓已执行）
- [ ] 上板后串口出现 banner 与 `budget:` / `space:` 各 10 行
- [ ] `heap: verify=ok` 在 init / after-align / stress / after-drain / final 全部为 ok
- [ ] `frag: ops` 的 `overlap_hits=0 corrupt=0`
- [ ] `stack: main … sentinel=ok`，且 `used` 落在几千字节量级
- [ ] `stack: sim sentinel=overrun` 出现且 `got=0x78563412`
- [ ] `psram: mmu_valid_entries` 与 `mapped=` 的结论记录在案（预期 0 / no）
- [ ] 连续复位 10 次，`heap: total` 与 `epilogue` 数字稳定
