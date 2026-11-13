---
title: 第二十八章：自举、功耗、性能与综合项目
date: 2026-11-13 20:30:00
description: "Zig × ESP32-S31 的收官章：28A 把 bootloader 选槽、A/B 回滚、睡眠预算与性能统计做成可离线判定的模型；28B 的自举 bootloader 只给边界与迁移清单。"
tags: [Zig, ESP32-S31, Bootloader, OTA, Power, Performance]
---

# 第二十八章：自举、功耗、性能与综合项目

> [!info] 本章导航
> 系列索引：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]] · 上一章：[[ch27-ble-802154-boundary|第二十七章：BLE 与 802.15.4 边界]] · 本章：自举、功耗、性能与综合项目

> [!warning] 验证状态
> 本章是 **28A**：没有实现 form C 的 Zig 二级 bootloader，也没有真机测量。
> 工程已落盘，但按本轮要求**未运行 `zig build test`、未烧录、未测电流**。
> 文中电流、唤醒时间、频率都是模型值；能离线判定的只有选槽、回滚、
> 预算与统计这些纯逻辑，判据见 28.9。

## 28.1 收官章要解决的不是“再写一个驱动”

到 ch27 为止，我们已经有了：裸机启动、链接脚本、GPIO/UART、中断、定时器、DMA、flash 分区、协作/抢占调度、同步原语、堆/栈、双核、可观测性、Zig TCP/IP、TLS/HTTP、MQTT/OTA、Wi-Fi/BLE 边界。

这些章节回答的是“每一层怎么写”。收官章要回答的是产品化的问题：

1. **启动链的最后一段**：IDF 的二级 bootloader 替我们做了什么？如果换成 Zig，边界在哪？
2. **低功耗**：light sleep 与 deep sleep 的差别不只是电流，还有唤醒开销和状态保留。
3. **性能**：没有计时器、没有统计口径的“优化”不可复现。
4. **综合项目**：一条命令构建/烧录，能把前面章节的证据串起来。

本章把 28A 与 28B 明确分开：

|        | 28A（本章工程）                        | 28B（可选，未实现）                     |
| ------ | -------------------------------------- | --------------------------------------- |
| 启动链 | ROM → IDF bootloader → Zig app         | ROM → Zig bootloader → Zig app          |
| 选槽   | 读 `otadata` 的模型；真实选槽由 IDF 做 | 自己解析 `otadata`、校验镜像、写回状态  |
| A/B    | 复用 ch24 状态机 + `bootslot.zig`      | bootloader 内实现                       |
| 验收   | 模型自检 + 真机电流/频率/吞吐          | ROM 直接进入 Zig bootloader，回滚可复现 |

> 28B 不是“多写一个 `main`”：它需要自己的链接地址、镜像头、段校验、分区表解析、flash 读回校验和失败救援。没有独立 bring-up 循环，不要把它塞进 28A 的工程里假装完成。

## 28.2 启动链：ROM、二级 bootloader、应用

ESP32-S31 的启动链可以粗分成三段：

```text
ROM 一级引导
  → 读 eFuse / strapping，决定从 SPI flash 还是 UART 下载
  → 从 flash 固定偏移加载二级 bootloader
二级 bootloader（IDF）
  → 读分区表（0x8000）
  → 解析 otadata，选择 ota_0 / ota_1 / factory
  → 校验镜像（magic、段、checksum、SHA-256、secure boot）
  → 跳转到应用的入口
应用（本章的 Zig ELF）
  → _start：关中断、设 sp/gp、关 RTC WDT、清 bss、装 mtvec
  → main：自检 / 业务
```

本章只改最后一段。**前面两段的偏移、镜像头、分区表字段以 ch03 的实读为准**，不要在这里背数字：不同 flash 大小、不同 IDF 版本的 `flash_args` 会把 bootloader 偏移和分区表位置写在不同地方。

应用侧必须让 bootloader 认得出“这是一个合法应用”：

- `esp_app_desc_t` 必须在镜像里、256 字节、`magic_word = 0xABCD5432`；
- 两个 flash 装载段（DROM/IROM）的段头、长度、校验和要匹配；
- `app_desc` 里的 `secure_version` 只能单调不回退；
- 入口地址与链接脚本的 `ENTRY(_start)` 一致。

`src/start.zig` 里的 `comptime` 断言就是把这些硬约束钉在编译期：

```zig
comptime {
    if (@sizeOf(AppDesc) != 256) @compileError("esp_app_desc_t 在镜像里必须是 256 字节");
    if (@offsetOf(AppDesc, "idf_ver") != 112) @compileError("idf_ver 必须在偏移 112");
    if (@offsetOf(AppDesc, "app_elf_sha256") != 144) @compileError("sha256 必须在偏移 144");
}
```

> 这些断言只能证明“结构布局对”，不能证明“bootloader 会接受这个镜像”。后者要靠 `esptool image-info` 与真机启动日志。

## 28.3 otadata：两个扇区与一个序号

IDF 的 `otadata` 用两个扇区交替写，目的是“写新记录时旧记录还在”。bootloader 的选择规则可以压缩成三步：

1. **CRC 先过**：空白 flash（全 `0xFF`）或半写记录直接丢；
2. **序号最大**：`seq` 越大越新，回绕按无符号比较；
3. **平手取先找到的**：避免同样合法的两条记录导致启动槽随机。

本章的 `bootslot.zig` 用 16 字节条目复现这个决策：

```text
偏移 0   magic "S31B"
偏移 4   seq（u32 LE）
偏移 8   slot（0=A/ota_0，1=B/ota_1）
偏移 9   state（NEW/PENDING/VERIFY/VALID/INVALID/ABORTED）
偏移 10  保留（必须 0）
偏移 12  CRC32（覆盖 0..12）
```

它**不是** IDF 的 `esp_ota_select_entry_t` 兼容格式，字段布局只为教学可读；但“CRC 先过、再比 seq”的语义与 IDF 一致。真正写 `otadata` 时要按 IDF 的结构与扇区擦写顺序来，不能把这个 16 字节结构直接烧进去。

选槽之后还有一道状态判断：如果胜出的槽是 `ABORTED`/`INVALID`/`UNDEFINED`，不能启动它；本章的模型回退到 `factory`（真实 IDF 在“没有可启动应用”时会停在 bootloader，本章的模型更宽容，便于教学）。

## 28.4 A/B 状态机：验签通过 ≠ 能跑

ch24 已经给出 OTA 状态机：

```text
NEW → PENDING_VERIFY → VALID
                     ↘ INVALID → 回滚
                     ↘ ABORTED → 回滚
```

本章直接复用 `ota.zig`，只在外面加 bootloader 关心的两个计数：

- **启动次数**：处于 `PENDING_VERIFY` 的槽，每启动一次 `boot_attempts++`；超过预算仍未被 `markValid()`，标 `ABORTED` 并回滚。
- **运行失败次数**：应用自检失败、看门狗复位、关键任务崩，调用 `noteFailure()`；连续失败达到预算，标 `INVALID` 并回滚。

关键点是“连续”：`noteHealthy()` 会清零失败计数。否则设备偶尔一次网络超时就会把好固件回滚掉。

```zig
var rb = ota.Rollback.init(.{ .max_boot_attempts = 2, .max_runtime_failures = 3 });
rb.stage(.b) catch {};
rb.setBootSlot(.b) catch {};
rb.noteFailure();
rb.noteFailure();
rb.noteFailure(); // B → INVALID，active 回到 A，rollbacks = 1
```

> 真实的 `esp_ota_mark_app_valid_cancel_rollback()` 只在应用确认自己“能跑”之后调用；不要在 `main` 第一行就调用，否则回滚机制等于没有。

## 28.5 功耗：先算唤醒开销，再谈睡眠电流

低功耗最常见的错误是只看“睡眠电流”，不看“醒着的时间”。设：

- 睡眠电流 $I_s$，运行电流 $I_r$；
- 睡 $T_s$，醒 $T_w$；
- 占空比平均电流：

$$
I_{avg} = \frac{I_s T_s + I_r T_w}{T_s + T_w}
$$

本章的 `power.zig` 把 light/deep 两种模式都按这个式子算。模型值：

| 模式        | 电流（模型） | 唤醒开销（模型） | 说明                              |
| ----------- | ------------ | ---------------- | --------------------------------- |
| run         | 25 mA        | —                | 80 MHz、外设开                    |
| light sleep | 1.2 mA       | 80 µs            | 保留 SRAM/外设状态，醒来继续执行  |
| deep sleep  | 0.01 mA      | 12 ms            | 只保留 RTC，醒来重新走 bootloader |

这些数字**不是 S31 的实测值**。它们只用于比较策略：当睡眠周期只有 1 s 时，deep sleep 的 12 ms 唤醒会把平均电流拉高；睡眠周期到 60 s，deep 才明显占优。

RTC 计数器是 32 位，慢时钟按 136 kHz 标称：

$$
T_{max} = \frac{2^{32}}{136\,000}\ \text{s} \approx 31\,580\ \text{s} \approx 8.77\ \text{h}
$$

所以“深睡 24 小时再唤醒”不能只写一个 64 位 µs 参数就完事；要么分段唤醒，要么用外部 RTC/看门狗。`power.maxSleepUs()` 把这条上限算出来，板侧自检会打印。

## 28.6 性能：把“感觉”变成分位数

性能剖析至少要有三样东西：

1. **时间源**：SYSTIMER（ch08 已走通读数路径），不要用 `tick` 当微秒；
2. **样本**：同一段固定工作量重复 N 次，记录每次的周期/纳秒；
3. **统计口径**：min/max/mean 会被长尾骗，必须给 p50/p95。

`perf.zig` 的百分位用最近秩：

$$
\text{rank} = \left\lceil \frac{p}{100} \cdot n \right\rceil
$$

不插值，避免“p95 比最大值还大”这类实现错误。吞吐统一用 MiB/s（$1\,\text{MiB}=2^{20}$ 字节），周期与频率的折算要区分两件事：

- **周期数**随频率上升而上升：80 MHz 下 1000 周期，320 MHz 下同一条代码约 4000 周期；
- **执行时间**随频率上升而下降：80 MHz 下 1000 ns，320 MHz 下约 250 ns（理想线性）。

真实系统不会完全线性：flash cache、PSRAM 等待、DMA 争用都会让高频收益打折。所以“80→320 MHz 提升 4 倍”只能作为上界，必须用实测数据修正。

## 28.7 综合项目：一条命令能复现什么

本章工程的“综合”不是把 ch01–ch27 的代码全搬进来，而是把收官决策串成一条可复现链：

```bash
cd practice/zig-esp32-s31/ch28-bootstrap-power-performance
zig build test                       # 主机侧纯逻辑
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
./tools/flash.sh /dev/ttyUSB1        # 需要 IDF v6.1 环境
```

串口期望（**未实测，仅作为判据**）：

```text
ch28-bootstrap-power-performance | form B (Zig ELF + IDF 2nd-stage bootloader)
scope: otadata pick + a/b rollback + sleep budget + perf stats
scope note: 28A only; no custom 2nd-stage bootloader, no flash write, no real sleep
check: otadata entry roundtrip + crc32 ok=1
...
read: checks: passed=12 failed=0 total=12
main: verdict=pass, boot/power/perf models verified off-link (wfi)
```

如果这里出现 `ok=0`，先看是哪一条：选槽/CRC 错会表现为升级后仍启动旧槽；回滚计数错会表现为坏固件反复重启；性能统计错会表现为 p95 小于 p50 这类自相矛盾。

## 28.8 如果要做 28B：Zig 二级 bootloader 的迁移清单

28B 的“自举”至少包含以下工作，缺一项都不算完成：

1. **独立链接**：bootloader 链接到 ROM 期望的 flash 偏移，入口、段布局、栈都在 SRAM；不能复用应用的链接脚本。
2. **镜像头**：按 ch03 的格式写 magic、段数、entry、checksum、hash；`esptool image-info` 必须能解析。
3. **分区表**：从 `0x8000` 读表，校验 MD5/条目边界；按 label 找 `factory`/`ota_0`/`ota_1`/`otadata`。
4. **选槽**：读两个 otadata 扇区，CRC/seq 选择；`ABORTED`/`INVALID`/`UNDEFINED` 不启动；没有可启动槽时进入救援（UART 下载或 factory）。
5. **镜像校验**：段长度/校验和、SHA-256、`esp_app_desc_t` 魔数、`secure_version` 单调。
6. **回滚**：启动计数写回 otadata；应用确认后清计数；失败达预算切槽。
7. **失败路径**：校验失败不能“跳过去试试”，要打印原因并停在可恢复状态；UART 下载模式必须还能进。
8. **bring-up 循环**：先用 ROM 直接加载 bootloader 的小镜像验证入口，再逐步加分区表/校验/选槽；每一步都要有串口证据。

风险排序：**镜像头/链接地址** > **flash 读校验** > **otadata 写回** > **回滚**。前两项错会直接变砖，后两项错只是升级行为不对。

## 28.9 真机验收清单（本轮未做）

| #   | 项目        | 判据                                                         | 工具                                    |
| --- | ----------- | ------------------------------------------------------------ | --------------------------------------- |
| 1   | 镜像合法    | `image-info` 解析出两个 flash 段，checksum/SHA 与构建一致    | `esptool image-info`                    |
| 2   | 启动        | banner 出现 `ch28-bootstrap-power-performance`，12 条 `ok=1` | UART 115200                             |
| 3   | 选槽        | 写入 seq 更大的 B 后，重启从 B 启动；CRC 坏一个扇区仍能选 A  | `otadata` 读写脚本                      |
| 4   | 回滚        | B 连续三次自检失败 → 回 A，`rollbacks=1`                     | 串口 + 分区表                           |
| 5   | light sleep | 唤醒原因、唤醒时间、平均电流；与模型偏差记录                 | 电流表 + `esp_sleep_get_wakeup_cause()` |
| 6   | deep sleep  | RTC timer 唤醒；单次睡眠不超过 32 位上限；电流               | 电流表                                  |
| 7   | 性能        | 80/160/320 MHz 三档的 p50/p95、吞吐、每字节周期              | SYSTIMER + 串口                         |
| 8   | 综合        | 一条命令构建/烧录；OTA 切槽后可回到旧版本                    | `tools/flash.sh` + OTA                  |

> 没有第 5–7 项的电流表/计时数据，就不要在文章里写“功耗降低 X%”“性能提升 Y 倍”。模型只能给方向，不能给结论。

## 28.10 本章小结与系列收尾

- **自举**：28A 读懂 bootloader 的选槽与校验，28B 才自己实现；两者之间隔着链接地址、镜像头、flash 校验与救援路径，不是一层薄封装。
- **功耗**：先算唤醒开销，再谈睡眠电流；32 位 RTC 计数器有 8.77 小时的单次上限。
- **性能**：时间源、样本、分位数三件套缺一不可；频率折算只是上界，必须用实测修正。
- **产品化**：A/B 回滚的关键不是“能升级”，而是“升级失败还能回来”；`markValid()` 必须在自检之后调用。

到这里，28 章的路线走完：从 ROM 到应用、从裸机到 RTOS、从以太网到 Wi-Fi 边界、从协议到 OTA。**能离线判定的部分已经给出判据；不能离线判定的部分，统一留在真机清单里，不用文字冒充数据。**

> [!tip] 工程入口
> 完整工程：[ch28-bootstrap-power-performance](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/README.md) · 选槽实现：[bootslot.zig](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/bootslot.zig) · 功耗模型：[power.zig](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/power.zig) · 性能统计：[perf.zig](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/perf.zig)
