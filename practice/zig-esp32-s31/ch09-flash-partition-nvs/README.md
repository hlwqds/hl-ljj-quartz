# ch09 SPI Flash、分区与 NVS 存储：让状态活过重启

> 所属章节：[[ch09-spi-flash-partition-nvs|第九章：SPI Flash、分区与 NVS 存储]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

## 目的

这是形态 B 的第五个工程，骨架完全沿用 `ch04-linker-layout` / `ch08-timers-dma`：
Zig 自己产出 ELF、`linker/s31.ld` 决定段布局、`_start` 是入口、应用镜像由
`esptool elf2image` 生成，IDF 只负责二级 bootloader 与分区表。

在不变的骨架之上，本章加了三层一条链：

| 模块                | 做什么                                                     | 可观测量                                         |
| ------------------- | ---------------------------------------------------------- | ------------------------------------------------ |
| `src/flash.zig`     | 三个 ROM 函数（读/写/擦）、对齐与边界检查、写后读回        | 写是否被阵列接受（返回码 + 比对）                |
| `src/partition.zig` | 读 `0x8000` 的 `0xC00` 字节，按 32 字节解析，按 label 查找 | 条目数、`storage` 的 offset/size、MD5 区是否存在 |
| `src/kv.zig`        | 16 字节记录（`0x4B56` + seq + value + CRC32）的追加日志    | `records` / `last_value` / `torn` / 是否压缩     |
| `src/main.zig`      | 读表 → 找 `storage` → 扫描 → 追加 → 重扫                   | 开机计数每次 +1                                  |

工程**不做**的事，同样重要：

- 不改 IDF 的 `nvs` 分区、不碰 `bootloader` 与 `partition-table` 区域：写错
  这两处会直接变砖。
- 不实现 IDF-NVS 兼容格式：没有页头、没有 32 字节条目、没有命名空间。
  本工程的 KV 只占自定义的 `storage` 分区。
- 不打开中断：flash 写/擦是同步的，临界窗口只短暂清 `mstatus.MIE`。
- 不做 cache 挂起/恢复：本工程所有段都在 SRAM，写/擦期间不从 flash 取指。
  这是布局带来的前提，不是通用结论。

> [!warning] 验证状态
> 本工程**尚未**在任何真机上运行，构建与烧录也没有在本仓执行过。所有涉及
> ROM 行为、分区解析、掉电安全的结论都标为**待真机验证**。README 不附
> `run.log`，也不贴任何“看起来像实测”的日志。

## 硬件与接线

| 项       | 事实                                          |
| -------- | --------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash     |
| 控制台   | UART0，GPIO58(TX) / GPIO59(RX)，115200 8N1    |
| 下载模式 | BOOT = GPIO61；自动复位失败时按住 BOOT 再复位 |
| 观测     | 本章不需要示波器：串口输出就是全部证据        |

## 地址与常量（全部有出处）

| 项                              | 值                           | 出处                                 |
| ------------------------------- | ---------------------------- | ------------------------------------ |
| `esp_rom_spiflash_erase_sector` | `0x2f800160`                 | IDF v6.1 `esp32s31.rom.ld`           |
| `esp_rom_spiflash_write`        | `0x2f800168`                 | 同上                                 |
| `esp_rom_spiflash_read`         | `0x2f80016c`                 | 同上                                 |
| `esp_rom_printf`                | `0x2f800024`                 | 同上（与 ch06/ch08 一致）            |
| 分区表偏移 / 长度               | `0x8000` / `0xC00`           | IDF 分区表生成逻辑                   |
| 条目大小 / 上限                 | `32` / `95`                  | `0xC00 / 32 - 1`（末尾 32 字节 MD5） |
| `ESP_PARTITION_MAGIC`           | `0x50AA`（落盘字节 `AA 50`） | `esp_flash_partitions.h`             |
| 擦除单位                        | `0x1000`（4 KiB）            | 同上 + `esp_rom_spiflash.h`          |
| `storage`                       | `0x300000` / `0x10000`       | 本工程 `partitions.csv`              |

三条最容易被写错的语义：

1. **参数是偏移，不是 XIP 地址**：不要加 `0x42000000` 一类的映射基址；
2. **擦除参数是扇区号**：`offset / 0x1000`，传偏移会擦到无关位置；
3. **写/读的长度按字节、指针按 `u32*`**：地址、长度、缓冲都必须 4 字节对齐。

## 分区表

`idf-bootstrap/partitions.csv`：

```csv
# Name,     Type, SubType, Offset,   Size,     Flags
nvs,        data, nvs,     0x9000,   0x6000,
phy_init,   data, phy,     0xf000,   0x1000,
factory,    app,  factory, 0x10000,  0x2f0000,
storage,    data, spiffs,  0x300000, 0x10000,
```

- `storage` 借 `spiffs` 子类型当“通用数据槽”，但本工程不实现 SPIFFS。
- `factory` 的 `0x10000` 必须与 `tools/flash.sh` 替换的应用行一致；脚本从
  `flash_args` 读取，不手抄偏移。
- 打开自定义表的关键配置在 `sdkconfig.defaults`：
  `CONFIG_PARTITION_TABLE_CUSTOM=y` + `CONFIG_PARTITION_TABLE_CUSTOM_FILENAME`。
  改了 CSV 却没重新生成 `sdkconfig` 时，构建仍会用旧表——删 `sdkconfig` 再
  `idf.py build`。

## 记录格式（自定义 KV）

```text
字：      w0                w1       w2       w3
     +-----------------+--------+--------+--------+
     | magic(u16) | 0  |   seq  | value  | crc32  |
     +-----------------+--------+--------+--------+
      低16位=0x4B56        u32      u32      u32
              CRC32(IEEE) 覆盖 w0..w2（12 字节）
```

- 一条 16 字节，一个 4 KiB 扇区 256 条；
- 扫描：`0xFFFF` = 空白尾部（不是错误）；魔数或 CRC 不符 = 撕裂尾部；
- 追加：写下一个空槽 → 立刻读回比对；
- 满或尾部撕裂：压缩（保留最新值 → 擦扇区 → 写回槽 0 → 校验）。

**与 IDF-NVS 不兼容**：没有页头、没有 32 字节条目、没有命名空间、没有键名。
不要把本工程的读写指向 `nvs` 分区。

## 文件表

| 路径                               | 角色                                                | 代码浏览                                                                                       |
| ---------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `build.zig`                        | 目标串 + 链接脚本 + `zig-out/bin/app.elf`           | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/build.zig)                        |
| `linker/s31.ld`                    | 全 SRAM 布局、`.app_desc` 优先、三个 ROM flash 符号 | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/linker/s31.ld)                    |
| `src/start.zig`                    | `esp_app_desc_t` + naked `_start`                   | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/start.zig)                    |
| `src/flash.zig`                    | ROM read/write/erase、对齐检查、写后读回、临界窗口  | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/flash.zig)                    |
| `src/partition.zig`                | `0x8000`/`0xC00` 解析、`find("storage")`            | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/partition.zig)                |
| `src/kv.zig`                       | 16 字节记录、扫描、追加、压缩                       | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/kv.zig)                       |
| `src/main.zig`                     | 读表 → 找分区 → 扫描 → 追加 → 重扫                  | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/main.zig)                     |
| `idf-bootstrap/partitions.csv`     | 自定义分区表（含 `storage`）                        | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/idf-bootstrap/partitions.csv)     |
| `idf-bootstrap/sdkconfig.defaults` | 16 MB + 自定义分区表                                | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/idf-bootstrap/sdkconfig.defaults) |
| `tools/flash.sh`                   | 读 `flash_args`、替换应用行、一次烧完               | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/tools/flash.sh)                   |

工程没有 `build.zig.zon`、没有 `components/`、没有 `run.log`。生成物
`zig-out/`、`.zig-cache/`、`idf-bootstrap/build/`、`idf-bootstrap/sdkconfig`
都不入库。

## 环境（Zig 0.17.1 / IDF v6.1 / esptool ≥5.2）

```bash
# Linux / macOS / WSL
. $IDF_PATH/export.sh

# Windows PowerShell
. $env:IDF_PATH\export.ps1
```

## 构建

### 1. 应用 ELF（纯 Zig，无 idf.py）

```bash
cd practice/zig-esp32-s31/ch09-flash-partition-nvs

zig build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei \
  -Doptimize=ReleaseSmall
```

### 2. 应用镜像

```bash
esptool --chip esp32s31 elf2image \
  --flash-mode dio --flash-size 16MB --flash-freq 80m \
  -o zig-out/bin/app.bin zig-out/bin/app.elf
```

### 3. bootloader 与分区表（供应商步骤）

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
cd ..
```

产物：`build/bootloader/bootloader.bin`、`build/partition_table/partition-table.bin`、
`build/flash_args`。分区表应该是 **4 条**（`nvs`/`phy_init`/`factory`/`storage`）；
如果只有 3 条，说明自定义 CSV 没生效。

### 4. 烧录

```bash
sh tools/flash.sh /dev/ttyUSB0    # Linux
sh tools/flash.sh COM7            # Windows（Git Bash / MSYS2）
```

脚本保留 `--flash_*` 选项与 bootloader/partition-table 两行，把 `0x10000`
那一行换成 `app.bin` 的绝对路径，然后 `cd` 到 `flash_args` 所在目录执行
esptool（相对路径以 build 目录为基准）。

## 运行

串口 115200 8N1。目标形态（验收目标，不是实测）：

```text
ch09-flash-partition-nvs | form B (Zig ELF + IDF 2nd-stage bootloader)
console: UART0 TX=GPIO58 RX=GPIO59 115200 8N1 (ROM default)
partition table @0x8000: 4 entries, md5=present
  [0] nvs type=1 sub=0x2 off=0x9000 size=0x6000
  [1] phy_init type=1 sub=0x1 off=0xf000 size=0x1000
  [2] factory type=0 sub=0x0 off=0x10000 size=0x2f0000
  [3] storage type=1 sub=0x82 off=0x300000 size=0x10000
storage base=0x300000 size=0x10000
kv: append-only log, NOT IDF-NVS compatible
kv: scan records=0 last_value=0 torn=0
kv: append seq=1 value=1 -> verify ok
kv: rescan records=1 last_value=1
kv: boot_count ok
done: power-cycle to see boot_count increment
```

复位后再看：`records` 与 `last_value` 都 +1。连续 256 次之后出现压缩，串口先打印
`kv: compaction: tail not writable, erase + rewrite slot 0`，随后 `records` 回落到 1，
`last_value` 继续递增。

## 证据与边界

### 1. 为什么“写返回 0”不够

ROM 的返回码只代表 SPI 控制器报告完成。真正的证据是 `flash.writeVerified`
里的读回比对，以及 `main` 末尾的重新扫描：它走的是和“下次开机”完全相同的
路径（读扇区 → 校验魔数/CRC → 取最后一条）。

### 2. 为什么代码必须全在 SRAM

写/擦 flash 时 SPI 控制器被 ROM 例程接管，cache/MMU 对 flash 的视图会失效。
如果 `.text` 是 XIP 的，写操作期间的取指就可能命中失效映射。本工程的链接
脚本把所有段放进 SRAM，因此窗口内不存在 flash 取指；代价是镜像体积受
`0x7AFC0` 限制。改布局前先读 `linker/s31.ld` 顶部的注释。

### 3. 临界窗口只关 MIE

`flash.Critical` 用 `csrrci mstatus, 8` / `csrsi mstatus, 8` 清/恢复
`mstatus.MIE`，不动 `mie`。它挡的是“中断在写操作中途进来并访问 flash”，
不承担 cache 一致性的职责。

### 4. 压缩不是事务

`kv.compact` 的顺序是“组记录 → 擦 → 写回 → 校验”。擦除后掉电会得到
`records=0`（数据退化，但不读到垃圾）；NVS 用双页 + 状态位解决同一问题，
本章刻意不引入。这是设计取舍，不是遗漏。

### 5. 排障表

| 现象                           | 根因                                                                   | 处置                                                                            |
| ------------------------------ | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `partition: read failed`       | ROM read 返回非 0                                                      | 核对链接脚本的 `PROVIDE` 地址与 rom.ld                                          |
| 条目数为 0、`md5=absent`       | 分区表没烧，或读错偏移                                                 | 确认 `flash_args` 有 `0x8000` 行；`xxd` 看前 2 字节是否为 `AA 50`               |
| `storage not found`            | CSV 没生效                                                             | 删 `idf-bootstrap/sdkconfig` 重新 build；确认 `CONFIG_PARTITION_TABLE_CUSTOM=y` |
| `kv: scan ... torn=1` 每次出现 | 上次写到一半复位，或 CRC 范围不一致                                    | 比对 `encode` 与 `scan` 覆盖的 12 字节                                          |
| `kv: append failed`            | 目标槽没擦过，或扇区已满但 `full` 判断没触发（撕裂尾部让扫描提前停止） | 确认 `records` 与 `full`；必要时手动擦一次 `storage` 首扇区                     |
| 计数每次归 1                   | `scan` 没读到旧记录，或误擦                                            | 确认 `scan` 只读；`compact` 只在 `full` 时调用                                  |
| 写后立刻取指异常               | `.text` 被改回 flash，缺 cache 窗口                                    | 恢复全 SRAM 布局                                                                |

### 待真机验证

- [ ] `zig build` 产出 `zig-out/bin/app.elf`；`readelf -h` 的 entry == `_start`
- [ ] `xxd -s 32 -l 4 zig-out/bin/app.bin` 为 `32 54 cd ab`
- [ ] `idf-bootstrap` 生成 **4 条**分区表的 `partition-table.bin`，前两字节 `AA 50`
- [ ] `flash_args` 含 `0x8000` 的 partition-table 行与 `0x10000` 的 factory 行
- [ ] `tools/flash.sh` 一次烧录成功，串口出现横幅与 4 条分区
- [ ] 首次启动 `records=0`，追加后 `value=1`，重扫 `last_value=1`
- [ ] 复位一次，`value=2`；连续复位 N 次，`value=N`
- [ ] 第 257 次启动出现压缩，`records` 回落且 `value` 继续递增
- [ ] 写操作中拔电，重启后 `torn=1` 且计数不倒退
- [ ] `run.log` 回填：真机串口原始输出（当前状态：**run.log 待真机回填**）
