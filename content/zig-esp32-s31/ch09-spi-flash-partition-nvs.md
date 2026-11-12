---
title: "Zig × ESP32-S31 全栈开发（九）：SPI Flash、分区与 NVS 存储"
date: 2026-11-18 18:00:00
description: "把持久化拆成三层：ROM 里的 flash 读/写/擦三个绝对地址与它们的契约（4 字节对齐、先擦后写、扇区号擦除、cache 窗口）；0x8000 处 0xC00 字节的分区表（32 字节条目、落盘魔数 AA 50、MD5 尾巴）；以及一个不兼容 IDF-NVS 的追加式 KV（0x4B56 + seq + CRC32），用“开机计数 +1、读回比对”把三层串起来。"
tags: [zig, esp32-s31, riscv, spi-flash, partition-table, nvs, series]
---

> [!info] Zig × ESP32-S31 全栈开发系列 0. [[zig-esp32-s31|系列索引]]
>
> 1. [[ch01-goal-boundary-hardware|第一章：目标、边界与硬件鉴定]]
> 2. [[ch02-toolchain-first-image|第二章：工具链与第一个可烧录镜像]]
> 3. [[ch03-boot-image-partition|第三章：启动链、镜像格式与分区]]
> 4. [[ch04-linker-memory-layout|第四章：链接脚本与内存布局]]
> 5. [[ch05-clock-reset-watchdog|第五章：时钟、复位与看门狗]]
> 6. [[ch06-gpio-uart-logging-panic|第六章：GPIO、UART、日志与 panic]]
> 7. [[ch07-interrupts-exceptions-clic|第七章：中断、异常与 CLIC]]
> 8. [[ch08-timers-dma-precision|第八章：定时器、DMA 与精确时序]]
> 9. **第九章：SPI Flash、分区与 NVS 存储**
> 10. [[ch10-context-switch-cooperative-scheduler|第十章：上下文切换与协作调度]]

# Zig × ESP32-S31 全栈开发（九）：SPI Flash、分区与 NVS 存储

八章下来，工程里的每一个字节都是**易失**的：时钟、GPIO、UART、中断、定时器、DMA，掉电即清零。这一章第一次给工程加一个能力——**重启之后还在**。

ESP32-S31 模组上有 16 MB SPI NOR Flash。它不是“慢一点的内存”，而是一个有三条硬规则的外设：

1. 读按任意地址（但通常走 XIP/cache 路径）；
2. 写只能把 1 变 0，且**按 4 字节对齐**；
3. 擦除只能**整扇区**（4 KiB），擦完全是 1。

本章不引入新的构建形态，仍然是 ch04 定下的形态 B（Zig 产出 ELF、自己的链接脚本、IDF 只提供二级 bootloader 与分区表）。新增的只是三个模块：`flash.zig`（ROM 三个函数）、`partition.zig`（解析分区表）、`kv.zig`（追加式键值日志）。

> [!warning] 本章的证据边界
> ROM 函数的地址取自 IDF v6.1 的 `esp32s31.rom.ld`，函数签名取自同一版本的 `esp_rom_spiflash.h`；分区表结构与 `0x8000`/`0xC00` 取自 `esp_flash_partitions.h` 与 IDF 的分区表生成逻辑。S31 的 TRM 仍是 Pre-release v0.7。本工程已于 2026-11-13 **真机运行**：分区解析（nvs `0x9000/0x6000`）、KV append/rescan 与 `boot_count` 均通过，原始输出见 `../logs/ch09-boot.log`。

---

## 9.1 三种地址，别混着用

写 flash 的代码最容易犯的错不是位运算，而是**把三个地址空间当成一个**：

| 名字       | 例子            | 谁在用                          | 含义                                        |
| ---------- | --------------- | ------------------------------- | ------------------------------------------- |
| flash 偏移 | `0x300000`      | `esp_rom_spiflash_*`、`esptool` | 从 flash 第 0 字节算起的线性偏移            |
| XIP 地址   | `0x40000000` 起 | CPU 取指、`const` 数据          | MMU 把某段 flash 映射进地址空间后的虚拟地址 |
| SRAM 地址  | `0x2F000000` 起 | 变量、栈、本工程的代码          | 片上 SRAM，读写即读写                       |

XIP 地址不是“偏移加一个常数”这么简单：映射由 MMU 页表决定，一页 64 KiB，页表由二级 bootloader 按分区表与镜像头建立。**同一块 flash，可以在两个不同 XIP 地址上被映射两次**，也可以完全不映射。

所以本工程所有 flash 操作的参数一律是**偏移**：`flash.zig` 的形参叫 `offset`，内部不做任何 `+0x40000000` 换算；串口上打出来的数可以直接喂给 `esptool read-flash`。

---

## 9.2 ROM 里的三个函数

应用不需要自己驱动 SPI0/1 控制器。掩膜 ROM 里已经有一套可用的 flash 例程，地址在 IDF 的 ROM 链接片段里固定：

```text
esp_rom_spiflash_erase_sector = 0x2f800160
esp_rom_spiflash_write        = 0x2f800168
esp_rom_spiflash_read         = 0x2f80016c
```

出处：IDF v6.1 `components/esp_rom/esp32s31/ld/esp32s31.rom.ld`。注意 `read` 与 `write` 只差 4 字节，它们是 ROM 跳转表里相邻的两项——这也提醒我们：**这些是绝对地址，不是可重定位符号**，写死在代码里就与 ROM 版本绑定了。

签名（IDF v6.1 `esp_rom_spiflash.h`）：

```c
esp_rom_spiflash_result_t esp_rom_spiflash_read(uint32_t src_address,
                                                uint32_t *dst_data,
                                                uint32_t len_bytes);
esp_rom_spiflash_result_t esp_rom_spiflash_write(uint32_t target_address,
                                                 const uint32_t *src_data,
                                                 uint32_t len_bytes);
esp_rom_spiflash_result_t esp_rom_spiflash_erase_sector(uint32_t sector_number);
```

三个返回值都是 `esp_rom_spiflash_result_t`：`0` 表示 OK，非 0 表示失败（枚举里是 ERR/TIMEOUT 一类）。本工程不猜具体码值，只判 `== 0`。

在 Zig 里按 C 原型声明成 `extern fn`，地址交给链接脚本的 `PROVIDE`（见 `linker/s31.ld`）：

```zig
extern fn esp_rom_spiflash_read(src_address: u32, dst_data: [*]u32, len_bytes: u32) c_int;
```

`[*]u32` 而不是 `[*]const u8`：这三个函数的长度参数**按字节计**，但指针类型是 `uint32_t *`，也就是说缓冲区必须按 4 字节访问。传一个 `u8` 切片进去在 C 侧是未定义行为，在 Zig 侧连编译都过不去——这是类型系统帮我们挡掉的第一类错误。

---

## 9.3 写 flash 的四条硬规则

### 1. 4 字节对齐（地址、长度、缓冲三者都要）

`esp_rom_spiflash_write` 的 `target_address` 与 `len_bytes` 都必须是 4 的倍数，`src_data` 也必须 4 字节对齐。原因在硬件：SPI 控制器按 32 位字装 FIFO，ROM 例程直接用 `volatile uint32_t *` 读源缓冲。

本工程的做法是把所有 flash 缓冲声明成 `[N]u32` 且 `align(4)`，并在 `write`/`read` 入口先查 `offset % 4`、`len % 4` 与 `offset+len <= flash_size`，不合格直接返回错误，绝不把未对齐的指针交给 ROM。

### 2. 先擦后写

NOR flash 的写操作只能把 bit 从 1 变成 0。想写入一个新值，目标区域必须先是全 1（`0xFF`）。所以顺序永远是 **erase → write → read back**，没有“覆盖写”。

一条推论：**同一扇区里改一个字节，也要把整扇区读出来、改、擦、写回**。这是所有 flash 文件系统（包括 IDF 的 NVS）都要面对的成本，也是它们设计成“追加 + 垃圾回收”的根本原因。

### 3. 擦除的单位是扇区号，不是地址

`esp_rom_spiflash_erase_sector` 的参数是**扇区号**：`sector_number = offset / 0x1000`。传 `0x300000` 进去会去擦第 3145728 个扇区（越界），而控制器不会替你纠正。本工程的 `eraseSector(offset)` 在内部做除法，并且要求 `offset % 0x1000 == 0`。

### 4. cache 窗口：写/擦期间不能从 flash 取指

这是最容易被忽略的一条。应用代码默认是 **XIP** 的：`_start`、`main`、常量字符串都映射自 flash。擦除/写入时 SPI 控制器被 ROM 例程接管，cache 与 MMU 对这段 flash 的视图随之失效——此时如果 CPU 从 flash 取一条指令，读到的是控制器当前状态下的垃圾。

IDF 的处理方式是在 `spi_flash_write`/`spi_flash_erase_range` 外层包一个 **cache 挂起/恢复** 窗口。S31 上对应的 ROM 辅助函数名需要在 `esp32s31.rom.ld` 里逐个确认，本工程**不假设**它们的地址，而是走另一条同样正确但更朴素的路：**所有段都在 SRAM**（`linker/s31.ld` 没有 IROM/DROM 段），代码本来就不从 flash 取指，写/擦期间不存在“取指踩到失效映射”。配合 `flash.zig` 的临界窗口（关 `mstatus.MIE`）即可；被调用的 ROM 例程本身在 ROM 里，不在 flash 里。

> [!warning] 待真机验证
> 若将来把 `.text` 搬回 flash（形态 A 或真正的 XIP 布局），就必须在写/擦前后补上 cache 挂起/恢复，否则会在 `esp_rom_spiflash_write` 返回后随机取指失败。这一段是本工程刻意绕开的边界，不是“已经解决了”。

---

## 9.4 分区表：0x8000 处的 0xC00 字节

二级 bootloader 启动时做的第一件事之一，就是从 **`0x8000`** 读 **`0xC00`** 字节的分区表。这个位置和长度不是约定俗成，而是编译进 bootloader 的常量：

- 起始 `0x8000`：避开 `0x0` 的二级 bootloader 与 `0x8000` 之前的分区表预留区；
- 长度 `0xC00` = 3072 字节 = 96 × 32 字节；
- 最后 32 字节是**表尾**：`EB EB` + 14 个 `FF` + 16 字节 MD5。摘要只覆盖**已用条目的字节**（与第三章 `ch03-image-inspect` 的主机解析器一致），不是整块 `0xBE0`；
- 因此**最多 95 个有效条目**。第 96 个 32 字节槽位留给表尾，写满就会盖掉 MD5，bootloader 会拒绝整张表。

每个条目 32 字节，字段顺序由 `esp_partition_info_t`（IDF v6.1 `esp_flash_partitions.h`）固定：

| 偏移 | 大小 | 字段      | 说明                                                                          |
| ---- | ---- | --------- | ----------------------------------------------------------------------------- |
| 0    | 2    | `magic`   | `ESP_PARTITION_MAGIC = 0x50AA`，小端落盘为 `AA 50`（按字节读常写作 `0xAA50`） |
| 2    | 1    | `type`    | `0x00` = app，`0x01` = data                                                   |
| 3    | 1    | `subtype` | app: factory/ota\_\*；data: nvs/phy/fat/spiffs…                               |
| 4    | 4    | `offset`  | 分区的 flash 偏移（4 KiB 对齐）                                               |
| 8    | 4    | `size`    | 分区大小                                                                      |
| 12   | 16   | `label`   | 以 `\0` 结尾的 ASCII，最长 15 字符                                            |
| 28   | 4    | `flags`   | 加密/只读等标志                                                               |

本章在 `idf-bootstrap/partitions.csv` 里加了一个自定义数据分区：

```csv
# Name,   Type, SubType, Offset,   Size
nvs,      data, nvs,     0x9000,   0x6000
phy_init, data, phy,     0xf000,   0x1000
factory,  app,  factory, 0x10000,  0x2F0000
storage,  data, spiffs,  0x300000, 0x10000
```

几点说明：

- `storage` 用 `spiffs` 子类型只是借一个“通用数据槽”的编号；本工程**不**实现 SPIFFS，也**不**让 IDF 的 NVS 去碰它。
- 偏移 `0x300000` 在 factory（`0x10000` + `0x2F0000` = `0x300000`）之后，正好衔接；`0x10000` 大小即 64 KiB，够放 16 个 4 KiB 扇区。
- 偏移的唯一权威仍是 `idf-bootstrap/build/flash_args`；`tools/flash.sh` 不手抄偏移。

解析本身很短：一次 4 字节对齐的 `read`，把 `0xC00` 字节读进 SRAM，然后按 32 字节步进，遇到 `magic != 0x50AA`（字节 `AA 50`）或 `type` 不在 `{0,1}` 就停——这既处理“表只有 3 条”的正常情况，也顺手挡住“读到全 `0xFF`”的未烧录状态。

---

## 9.5 自己的 KV：16 字节记录 + 追加日志

IDF 的 NVS 是一套完整实现：页（4 KiB）、页头、32 字节条目、命名空间、类型、跨页索引、位图、垃圾回收。本章**不**复刻它，只做一个能讲清“掉电安全”的最小模型：

```text
字：      w0                w1       w2       w3
     +-----------------+--------+--------+--------+
     | magic(u16) | 0  |   seq  | value  | crc32  |
     +-----------------+--------+--------+--------+
      低16位=0x4B56        u32      u32      u32
              CRC32 覆盖 w0..w2（12 字节）
```

一条 16 字节 = 4 个 32 位字。`magic` 语义上是 `u16`，但**占满第一个字**（高 16 位写 0），这样落盘永远是 ROM 例程喜欢的整齐字对齐；`seq` 在字节 4..8、`value` 在 8..12、`crc32` 在 12..16。字段含义：

- `magic = 0x4B56`：用来区分“有效记录”与“空白/垃圾”（擦除后是 `0xFFFF`）；
- `seq`：单调递增的记录序号，从 1 开始；扫描时用它判断哪条最新；
- `value`：本章存的是开机计数；
- `crc32`：IEEE 802.3 多项式，覆盖前三个字（magic 字、`seq`、`value`）共 12 字节。CRC 是必要的：`magic` 只有 16 位，一个被擦了一半的扇区很可能留下正确的 magic。

### 1. 追加，而不是原地改

挂载 = 顺序扫描第一个 4 KiB 扇区：`magic == 0xFFFF` 是**空白尾部**（到此为止，返回最后一条有效记录）；`magic != 0x4B56` 或 CRC 不匹配是**撕裂尾部**（写到一半掉电，记 `torn = true`）；其余情况按 `seq` 递增接受。

写入 = 追加到下一条空槽：在 SRAM 里组好 16 字节 → `write(base + slot*16, ...)`（16 字节天然 4 字节对齐）→ 立刻 `read` 同一偏移读回比对。这一步把“ROM 说成功”变成“我们亲眼看到”。

### 2. 尾部满了怎么办

一个扇区 4096 / 16 = 256 条。写满之后不能“从头覆盖”（那会破坏最新记录），只能：

1. 把最新一条记录留在 RAM 里；
2. `eraseSector(base)`；
3. 把这一条写回槽 0；
4. 读回校验。

尾部撕裂（`torn = true`）也走这条路：撕裂槽里的位已经被写成 0，**不能**原地覆盖，只能擦整扇区再写回。这就是**压缩（compaction）**的最小形态：先擦后写、只保留活数据。真实 NVS 的垃圾回收是它的多页版本，原理相同。

### 3. 明确声明：不是 IDF-NVS 兼容格式

这一点必须在文档里写死，否则将来一定有人拿 `nvs_flash_init` 去读这个分区：

- 没有 NVS 页头/状态标记，没有 32 字节条目与命名空间；
- 没有键名，只有固定布局的记录，且只有一种“键”：开机计数。

它占的是 `storage` 分区，不是 `nvs` 分区。**永远不要把本工程的读写指向 `nvs`、`bootloader` 或 `partition-table` 所在区域**：前者会破坏 IDF 自己的数据，后者会让板子直接变砖。

---

## 9.6 工程走读

> 完整工程:[ch09-flash-partition-nvs](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/)

| 文件                                | 查看                                                                                            |
| ----------------------------------- | ----------------------------------------------------------------------------------------------- |
| `build.zig`                         | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/build.zig)                         |
| `linker/s31.ld`                     | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/linker/s31.ld)                     |
| `src/flash.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/flash.zig)                     |
| `src/kv.zig`                        | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/kv.zig)                        |
| `src/main.zig`                      | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/main.zig)                      |
| `src/partition.zig`                 | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/partition.zig)                 |
| `src/start.zig`                     | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/src/start.zig)                     |
| `idf-bootstrap/CMakeLists.txt`      | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/idf-bootstrap/CMakeLists.txt)      |
| `idf-bootstrap/main/CMakeLists.txt` | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/idf-bootstrap/main/CMakeLists.txt) |
| `idf-bootstrap/main/app_main.c`     | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/idf-bootstrap/main/app_main.c)     |
| `idf-bootstrap/sdkconfig.defaults`  | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/idf-bootstrap/sdkconfig.defaults)  |
| `tools/flash.sh`                    | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/tools/flash.sh)                    |
| `README.md`                         | [查看](/static/code/#/zig-esp32-s31/ch09-flash-partition-nvs/README.md)                         |

### 1. 文件与职责

| 文件                           | 职责                                                            |
| ------------------------------ | --------------------------------------------------------------- |
| `src/flash.zig`                | 三个 ROM 函数指针、对齐检查、`read/write/eraseSector`、临界窗口 |
| `src/partition.zig`            | 读 `0x8000` 的 `0xC00` 字节，按 32 字节解析，按 label 查找      |
| `src/kv.zig`                   | 16 字节记录、扫描、追加、压缩、读回校验                         |
| `src/main.zig`                 | 串起三层：读表 → 找 `storage` → 扫描 → 追加 → 读回比对          |
| `src/start.zig`                | 与 ch08 相同：`esp_app_desc_t` + naked `_start`                 |
| `linker/s31.ld`                | 全 SRAM 布局；新增三个 ROM 符号的 `PROVIDE`                     |
| `idf-bootstrap/partitions.csv` | 自定义分区表，含 `storage`                                      |

### 2. 主流程

```text
banner
  ↓
partition.load()       读 0x8000..0x8C00 进 .bss，逐条校验
  ↓
partition.find("storage")   → base = 0x300000, size = 0x10000
  ↓
kv.scan(base)          扫描第一个扇区，得到 last_seq / last_value / torn
  ↓
kv.append(last_value+1)  追加 → 读回比对
  ↓
kv.scan(base)          再扫一遍，确认新记录可见（模拟“下次开机”）
```

最后一步是本章验收的核心：**不是“写成功了”，而是“重新扫描能读回来”**。前者只证明 ROM 返回 0，后者才证明数据真的落了盘。

### 3. 关键片段：一条记录的组装

`kv.encode` 先填 `{0x4B56, seq, value, 0}` 四个字，再对前 12 字节算 `std.hash.Crc32` 写进 `w[3]`。`std.mem.asBytes` 得到的字节序就是 RISC-V 的小端，与扫描端的读法完全一致——同构机器上不需要 `@byteSwap`；但主机侧单测必须用同样的字节序，否则 CRC 会对不上。

### 4. 为什么先读回再继续

ROM 的返回码只覆盖“控制器报告完成”，不覆盖“数据真的写进了阵列”。本工程在每次写后立刻 `read` 同一区域并 `std.mem.eql` 比对：

- 一致 → 打印 `kv: append seq=N value=M -> verify ok`；
- 不一致 → `writeVerified` 返回 `VerifyFailed`，主流程打印 `kv: append failed`，并且**不**推进 `seq`，下一次开机仍会重试。

---

## 9.7 验收与证据

### 1. 验收标准

1. 第一次上电：`kv: scan records=0 last_value=0 torn=0`，随后 `kv: append seq=1 value=1 -> verify ok`；
2. 复位（不复位 flash）：`kv: scan records=1 last_value=1`，随后 `value=2`；
3. 连续复位 N 次，`value == N`，且 `records == N`（在 256 条以内）；
4. 写满 256 条后再复位：出现一次 `kv: compaction`，`records` 回落到 1，`value` 继续递增；
5. 断电测试：写入过程中拔电，重启后 `torn=1` 且计数不倒退。

### 2. 输出形态（2026-11-13 实测）

```text
ch09-flash-partition-nvs | form B (Zig ELF + IDF 2nd-stage bootloader)
  [0] nvs type=1 sub=0x2 off=0x9000 size=0x6000
kv: append-only log, NOT IDF-NVS compatible
kv: scan records=2 last_value=2 torn=0
kv: append seq=3 value=3 -> verify ok
kv: rescan records=3 last_value=3
kv: boot_count ok
```

以上为 2026-11-13 真机原文（完整见 `../logs/ch09-boot.log`）；分区条目数随分区表变化，以实际烧录为准。

### 3. 真机前能做的静态检查

```bash
# 分区表必须是 4 条，且前两字节为 AA 50
xxd -l 4 idf-bootstrap/build/partition_table/partition-table.bin
# 三个 ROM 符号与代码里的常量必须一致
grep -n 'esp_rom_spiflash_' "$IDF_PATH/components/esp_rom/esp32s31/ld/esp32s31.rom.ld"
```

---

## 9.8 排错

| 现象                                                                     | 根因                                          | 处置                                                                               |
| ------------------------------------------------------------------------ | --------------------------------------------- | ---------------------------------------------------------------------------------- |
| 条目数 0、`md5=absent`，随后 `storage not found`                         | 分区表没烧，或读的是错误的偏移                | 确认 `flash_args` 里有 `0x8000` 的 partition-table 行                              |
| `partition: storage not found`                                           | `partitions.csv` 没被采用                     | 检查 `CONFIG_PARTITION_TABLE_CUSTOM=y` 与 `CONFIG_PARTITION_TABLE_CUSTOM_FILENAME` |
| `flash.Error.UnalignedOffset`（`append` 返回的错误）                     | 偏移不是 4 的倍数                             | 记录本身 16 字节对齐；检查 `base + slot*16` 的 `base`                              |
| `flash.Error.WriteFailed`（串口显示 `kv: append failed (write/verify)`） | 目标区域没擦过（不是全 `0xFF`），ROM 拒绝写入 | 先 `eraseSector`；本工程每次只提交一条 16 字节记录，不跨槽                         |
| 每次启动都 `torn=1`                                                      | 上一条记录写到一半就复位，或 CRC 覆盖范围写错 | 对比 `kv.encode` 与 `kv.scan` 覆盖的 12 字节                                       |
| 计数每次回到 1                                                           | 每次都在擦除后再追加，或扫描没读到旧记录      | 确认 `scan` 只读不擦；`append` 在槽位未满时不擦                                    |
| 读回不一致且 `bad` 固定在某处                                            | 写到了 `nvs`/`partition-table` 区域           | 核对 `storage` 的 offset 是否与分区表一致                                          |
| 写完立刻取指异常                                                         | 代码在 flash 里（XIP），缺 cache 窗口         | 保持全 SRAM 布局，或补 cache 挂起/恢复                                             |

---

## 9.9 下一章预告

持久化解决了“状态活过重启”，但工程仍然是**单线程顺序执行**：`main` 从头跑到尾，所有等待都是忙等。下一章（[[ch10-context-switch-cooperative-scheduler|第十章：上下文切换与协作调度]]）进入 Zig RTOS：

- RV32 的调用约定、callee-saved 寄存器与栈帧；
- 汇编实现的上下文切换：保存/恢复哪些寄存器、`sp` 怎么换；
- F 寄存器（硬浮点 ABI）的额外代价；两个任务各自栈上跑，用 GPIO 翻转测切换开销。

---

## 事实来源

| 事实                                                                                | 来源                                                      | 备注                                                |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------- | --------------------------------------------------- |
| `esp_rom_spiflash_read=0x2f80016c`、`_write=0x2f800168`、`_erase_sector=0x2f800160` | IDF v6.1 `components/esp_rom/esp32s31/ld/esp32s31.rom.ld` | 绝对地址，与 ROM 版本绑定                           |
| 三个函数的原型与 `esp_rom_spiflash_result_t`                                        | IDF v6.1 `esp_rom_spiflash.h`                             | `0` = OK                                            |
| 分区表位于 `0x8000`、长度 `0xC00`、条目 32 字节、最多 95 条                         | IDF v6.1 分区表生成与 `esp_flash_partitions.h`            | 96 槽含末尾 32 字节 MD5                             |
| `ESP_PARTITION_MAGIC = 0x50AA`（落盘字节 `AA 50`）                                  | 同上                                                      | 逐字节比较时等价于 `byte[0]==0xAA`、`byte[1]==0x50` |
| 扇区 4 KiB；擦除参数是扇区号；NVS 的页/条目结构                                     | 同上 + IDF v6.1 `nvs` 文档                                | 本工程**不**兼容、不读写 `nvs` 分区                 |
| SRAM 区间 `0x2F000000` + `0x7AFC0`                                                  | IDF v6.1 `esp_system/ld/esp32s31/memory.ld.in`            | 与第四章一致                                        |
| `esp_rom_printf=0x2f800024`、`esp_rom_delay_us=0x2f80003c`                          | IDF v6.1 `esp32s31.rom.ld`                                | 与第六/八章一致                                     |

## 自查清单

- [ ] flash 偏移、XIP 地址、SRAM 地址三者的区别是什么？为什么本工程只传偏移？
- [ ] 三个 ROM 函数的参数里，哪些必须以 4 字节为单位？为什么缓冲是 `u32*`？
- [ ] 为什么写之前必须擦？为什么改一个字节也要擦整扇区？
- [ ] `erase_sector` 的参数为什么是扇区号，传偏移会发生什么？
- [ ] 写/擦期间为什么要处理 cache？本工程为什么可以不做显式挂起？
- [ ] 分区表为什么在 `0x8000`？`0xC00` 是怎么算出来的？为什么最多 95 条？
- [ ] 分区条目的 32 字节里，`magic` 的数值是 `0x50AA`，为什么落盘看到的是 `AA 50`？按字节比较该怎么写？
- [ ] `storage` 分区的 offset 为什么刚好是 `0x300000`？
- [ ] 本工程的 KV 与 IDF NVS 有哪些结构性差别？为什么不能指向 `nvs` 分区？
- [ ] 记录里为什么需要 CRC32，光有 16 位 magic 不够吗？
- [ ] “空白尾部”和“撕裂尾部”怎么区分？各自应该怎么处理？
- [ ] 扇区写满后为什么要先读活记录、再擦、再写回？
- [ ] 为什么验收标准里强调“重新扫描能读回来”，而不是“写返回 0”？

---

本章的产出不是一个数字，而是**三层可独立验证的链路**：ROM 函数能按偏移读写、分区表能被正确解析、记录能在断电后重新扫出来。下一章离开存储，回到 CPU：把“一个 main”变成“多个任务”。

系列导航：[[ch08-timers-dma-precision|上一章]] · [[zig-esp32-s31|系列索引]]
