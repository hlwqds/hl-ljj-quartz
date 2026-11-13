# ch28 自举、功耗、性能与综合项目（28A）

> 所属章节：[[ch28-bootstrap-power-performance|第二十八章：自举、功耗、性能与综合项目]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态
>
> - **未做真机验证**：本文与工程按 2026-11-13 的计划落盘，尚未编译、烧录或测量。
> - **未运行 `zig build test`**：按用户要求本轮不做构建验证；工程中的主机测试只作为交付物。
> - **28A 边界**：仍由 IDF 二级 bootloader 装载本应用，**没有**实现 form C 的 Zig 二级 bootloader，**没有**写 flash、没有真正进睡、没有改 CPU 频率。
> - 文中的 mA、唤醒 µs、频率都是**模型值**，不是实测值；真机判据见 28.9。

## 目的

本章是系列的收官，回答三个产品化问题：

1. **启动链最后一段谁负责**：IDF bootloader 已经做了镜像校验、分区表、`otadata` 选槽；Zig 应用至少要能读懂这些决策，才能谈“自己写 bootloader”。
2. **低功耗怎么算**：light/deep sleep 的选择不是“越深越好”，而是唤醒开销 × 频率 × 占空比的算术。
3. **性能怎么量**：没有计时器和统计口径的“优化”只是感觉；本章给出 p50/p95、吞吐、每字节周期与频率折算。

### 28A 与 28B

|           | 28A（本工程）                              | 28B（可选，未实现）                         |
| --------- | ------------------------------------------ | ------------------------------------------- |
| 启动链    | ROM → IDF bootloader → Zig app             | ROM → Zig bootloader → Zig app              |
| 分区/选槽 | 读 `otadata` 模型；真实选槽仍由 IDF 做     | 自己解析分区表、写 `otadata`、校验镜像      |
| A/B/回滚  | 复用 ch24 状态机 + `bootslot.zig` 选槽模型 | bootloader 内实现槽位状态与回滚             |
| 风险      | 低；可离线判定                             | 高；需要独立的 bring-up 循环                |
| 验收      | 模型自检 + 真机电流/频率/吞吐              | ROM 直接跳到 Zig bootloader，A/B 回滚可复现 |

> 28B 不是在 28A 上“加一个文件”就能完成：它需要自己的链接地址、镜像头、分区表解析、flash 读校验与失败救援路径。本工程只把 28B 的**决策逻辑**抽出来，不冒充实现。

## 硬件与接线

| 项       | 事实                                                            |
| -------- | --------------------------------------------------------------- |
| 目标板   | ESP32-S31-Function-CoreBoard-1                                  |
| 模组     | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM         |
| 控制台   | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1，板载 USB-UART 桥 |
| 下载模式 | BOOT 按键 = GPIO61；自动复位失败时按住 BOOT 再复位              |
| 网络     | 本章不需要网线/路由器；ch17 未闭环前不声称任何链路结论          |
| 测量     | 真机功耗/性能验收需要电流表与 SYSTIMER 日志；本轮未接           |

## 文件表

| 路径                 | 角色                                                         | 代码浏览                                                                                                                           |
| -------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `build.zig`          | 形态 B 构建入口 + `zig build test`                           | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/build.zig)          |
| `linker/s31.ld`      | 两个 flash 装载段、`.trap_ram`、栈/堆边界                    | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/linker/s31.ld)      |
| `src/bootslot.zig`   | 16 B otadata 条目、CRC32、双扇区选槽、factory 回退           | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/bootslot.zig)   |
| `src/power.zig`      | light/deep sleep 预算、RTC 32 位上限、电池寿命               | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/power.zig)      |
| `src/perf.zig`       | min/max/mean、p50/p95、吞吐、周期/频率折算                   | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/perf.zig)       |
| `src/ota.zig`        | 复用 ch24 的 A/B 状态机（NEW→PENDING→VALID/INVALID/ABORTED） | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/ota.zig)        |
| `src/selftest.zig`   | 板侧 12 条判据                                               | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/selftest.zig)   |
| `src/host_tests.zig` | 主机侧测试根                                                 | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/host_tests.zig) |
| `src/main.zig`       | banner → 自检 → verdict → `wfi`                              | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/main.zig)       |
| `src/start.zig`      | `esp_app_desc_t` + naked `_start`                            | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/src/start.zig)      |
| `tools/flash.sh`     | 读 `flash_args` 并烧 bootloader/分区表/应用                  | [查看](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/zig-esp32-s31/ch28-bootstrap-power-performance/tools/flash.sh)     |
| `idf-bootstrap/`     | 最小 IDF 工程，只产出 bootloader/分区表                      | —                                                                                                                                  |

## 环境

| 项         | 版本/说明                                 |
| ---------- | ----------------------------------------- |
| Zig        | 0.17.1（与 ch24 一致；本工程零 Zig 依赖） |
| ESP-IDF    | v6.1（`esp32s31` preview target）         |
| esptool    | ≥ 5.2（`elf2image` / `image-info`）       |
| 交叉工具链 | `riscv32-esp-elf` 15.2.0                  |
| 串口       | `/dev/ttyUSB*` 或 `COM*`，115200 8N1      |

## 构建

```bash
cd practice/zig-esp32-s31/ch28-bootstrap-power-performance

# 主机侧纯逻辑测试
zig build test

# 交叉编译（与 ch24 同一目标串）
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

# 生成应用镜像
esptool.py --chip esp32s31 elf2image \
  --flash-mode dio --flash-freq 80m --flash-size 16MB \
  -o zig-out/bin/app.bin zig-out/bin/app.elf
```

## 运行（完整可复制，含 -p <PORT>）

```bash
# <PORT> 替换为实际串口，例如 /dev/ttyUSB1 或 COM7
cd practice/zig-esp32-s31/ch28-bootstrap-power-performance
./tools/flash.sh <PORT>

# 观察串口（idf.py 使用 -p <PORT>）
idf.py -p <PORT> monitor
```

> `tools/flash.sh` 读取 `idf-bootstrap/build/flash_args`，把应用行替换成本工程的
> `app.bin`，一次烧 bootloader + 分区表 + 应用；不写 `otadata`，本章不切槽。

## 真实输出

待真机验证：`run.log` 待真机回填。

### 自检判据

| #   | 判据                             | 失败意味着                |
| --- | -------------------------------- | ------------------------- |
| ①   | otadata 条目 16 B 往返 + CRC32   | 线上格式或 CRC 实现错     |
| ②   | 双扇区取 seq 最大者              | 升级后仍启动旧槽          |
| ③   | 一个扇区 CRC 坏仍能选另一个      | 单扇区损坏导致变砖        |
| ④   | 选中槽 ABORTED/INVALID → factory | 回滚后无路可走            |
| ⑤   | pending_verify 启动次数预算      | 新固件永远停在待验证      |
| ⑥   | 连续运行失败触发 A/B 回滚        | 坏固件反复重启            |
| ⑦   | `esp_app_desc_t` 256 B / 偏移    | bootloader 读不到镜像身份 |
| ⑧   | RTC 32 位单次最大睡眠            | 睡过头或提前醒            |
| ⑨   | deep/light 平均电流低于 run      | 功耗模型符号/权重错       |
| ⑩   | 最近秩 p50/p95                   | 性能统计口径不一致        |
| ⑪   | 1 MiB / 1 s = 1 MiB/s            | 吞吐单位错                |
| ⑫   | 80→320 MHz 周期/时间折算         | 频率换算方向错            |

板上出现 `checks: failed=N` 时，先看第 N 条判据行（`check: ... ok=0`），不要先怀疑串口或链接脚本。

### 真机验收（未做）

1. **启动链**：`esptool.py image_info` 解析本工程 `app.bin`，确认两个 flash 段；串口 banner 出现 `ch28-bootstrap-power-performance`。
2. **A/B**：在 `partitions.csv` 增加 `otadata`/`ota_0`/`ota_1`，用 IDF 的 `esp_ota_set_boot_partition` 切槽；连续三次失败后确认回滚到旧槽。
3. **功耗**：分别测 run / light / deep 的 mA；deep sleep 用 RTC timer 唤醒，记录 `esp_sleep_get_wakeup_cause()`；与 `power.zig` 的预算对比，偏差 >30% 要改模型。
4. **性能**：80/160/320 MHz 三档跑同一段固定工作量，记录 SYSTIMER 周期与 ns；用 `perf.zig` 输出 p50/p95/吞吐。
5. **综合 demo**：一条命令构建 + 烧录；从串口看到 `verdict=pass`，并能通过 OTA 槽位切换回到旧版本。

## 已知边界与排障

- 不实现 form C 的 Zig 二级 bootloader（28B 另立工程）。
- 不写 flash、不擦 `otadata`、不改分区表。
- 不真正进入 light/deep sleep；不测电流。
- 不调用 `esp_pm_configure`、不改 CPU 频率。
- 不声称已经达到任何吞吐/功耗指标。
- **板上出现 `checks: failed=N`**：先看第 N 条判据行；再检查 `run.log` 是否在 `start.zig` 清 `.bss` 之前被写入。
- **串口无输出**：先确认 BOOT/复位时序与 `-p <PORT>`；再确认 `flash_args` 里的 bootloader/分区表偏移与应用行没有被旧工程覆盖。
- **`image-info` 段数不对**：检查链接脚本是否仍有两个 flash 装载段（DROM/IROM），不要只留一个。
