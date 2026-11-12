# ch27-ble-802154-boundary —— HCI / ATT-GATT / 802.15.4 / 6LoWPAN 字节路径

本章的形态 B 工程：不链接任何 BLE 或 802.15.4 归档，只把「host 与 controller
之间那条缝」写成可编解码、可断言、可在 rv32 上跑通的字节路径。

- 章节正文：[[ch27-ble-802154-boundary|第二十七章：BLE 与 802.15.4 的边界]]
- 系列索引：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]
- 上一章：[[ch26-wifi-connection-wpa2-wpa3|第二十六章：Wi-Fi 连接管理（WPA2/WPA3）]]

> [!success] 验证状态（2026-11-13，真实上板）
>
> - `zig build test --summary all` → **20/20 tests passed**（主机 x86_64，Zig 0.17.1）
> - 交叉编译 → `Merged 2 ELF sections.`；`image-info` 恰好两条 `DROM, IROM`
>   （`0x40000020`、`0x40020020`）
> - 上板 → `checks: passed=12 failed=0 total=12`，`main: verdict=pass`
> - 原始串口日志：[`../logs/ch27-boot.log`](../logs/ch27-boot.log)
>
> 板侧**不碰射频**：没有扫描、没有连接、没有读特征值、没有 Thread 入网。
> 这些结论需要 controller 归档与 PHY 一起链接，判据写在章节 27.11。

## 快速开始

```bash
# 1) 主机侧单测（不碰硬件、不需要 IDF）
ZIG=/nix/store/m096jak4mrmdhah085l79rzfypviyhfw-zig-0.17.1/bin/zig
env -u LD_LIBRARY_PATH $ZIG build test --summary all

# 2) 交叉编译（目标串必须显式给）
env -u LD_LIBRARY_PATH $ZIG build \
  -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

# 3) ELF → 镜像（esptool 5.6 的 python 环境）
. /tmp/idfenv.sh
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf
python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin | grep 'DROM, IROM'

# 4) 烧录（两章共用一块板，一律 flock）
flock /tmp/s31-board.lock sh -c 'sh tools/flash.sh /dev/ttyUSB1'

# 5) 抓串口（先开端口再 RTS 复位；DTR+RTS 同时拉会进下载模式）
python3 - <<'PY'
import serial, time
s = serial.Serial('/dev/ttyUSB1', 115200, timeout=0.2)
s.setDTR(False); s.setRTS(True); time.sleep(0.1); s.setRTS(False); time.sleep(0.1)
buf = b""; t0 = time.time()
while time.time() - t0 < 12:
    buf += s.read(4096)
s.close()
open('../logs/ch27-boot.log', 'wb').write(buf)
print(buf.decode('utf-8', 'replace'))
PY
```

## 符号取证（章节 27.2 的每个数字）

```bash
sh tools/symbols.sh            # 打到标准输出
sh tools/symbols.sh > inventory.txt   # 重新生成（输出确定，可 diff）
```

脚本只读本机 IDF 与预编译归档，不写仓库以外的东西。它统计五份 S31 BT 归档
（`libble_app.a`、`libbtdm_common.a`、`libbredr_app.a`、`libbtbb.a`、
`libbttestmode.a`）的成员/符号面，把 `libble_app.a` 的未定义符号拆成
「五库内部解决 / ROM 链接脚本解决 / 剩下 10 个必须由胶水补」，并给出
802.15.4 侧**没有归档**的源码度量（`components/ieee802154/` 10 个文件 3571 行）。

只落摘要：完整 `nm` 转储是几百 KB，不入库（code-site 会当死链）。

## 文件职责

| 文件                 | 职责                                                             | 查看                                                                                       |
| -------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `README.md`          | 工程根：验证状态、快速开始、符号取证用法                         | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/README.md)                    |
| `build.zig`          | 目标串、链接脚本、`zig build test`（20 例）                      | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/build.zig)                    |
| `linker/s31.ld`      | 两个 flash 段、`.trap_ram`、堆/栈边界、6 条 ASSERT               | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/linker/s31.ld)                |
| `src/start.zig`      | `esp_app_desc_t`（project_name = ch27…）+ naked `_start`         | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/start.zig)                |
| `src/main.zig`       | banner → 自检 → verdict → `wfi`                                  | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/main.zig)                 |
| `src/hci.zig`        | HCI 分帧：H4 / ACL 头 / Command / Event / LE Meta（27.3）        | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/hci.zig)                  |
| `src/att.zig`        | ATT 8 个操作码、MTU 协商、读/写/通知/错误（27.4）                | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/att.zig)                  |
| `src/gatt.zig`       | 定长特征表、句柄分配、权限、CCCD 订阅（27.4/27.5）               | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/gatt.zig)                 |
| `src/fifteen4.zig`   | 802.15.4 FCF/地址 + 6LoWPAN IPHC 解压（27.6）                    | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/fifteen4.zig)             |
| `src/selftest.zig`   | 板侧 12 条判据（27.10 的每一行都来自这里）                       | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/selftest.zig)             |
| `src/host_tests.zig` | 主机侧 20 个用例                                                 | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/host_tests.zig)           |
| `src/trap.zig`       | `.trap_ram` 里的异常入口 + panic（放 flash 会 CPU_LOCKUP_RESET） | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/trap.zig)                 |
| `src/hw.zig`         | CSR 读、ROM 忙等、`wfi` 停机                                     | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/hw.zig)                   |
| `src/log.zig`        | 走 ROM `esp_rom_printf` 的单行输出                               | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/src/log.zig)                  |
| `tools/symbols.sh`   | 符号取证（27.2 的每个数字）                                      | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/tools/symbols.sh)             |
| `inventory.txt`      | 符号取证产物（元数据/直方图/归属/glue 清单/802.15.4 度量）       | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/inventory.txt)                |
| `tools/flash.sh`     | 按 `flash_args` 烧录，替换 factory 应用行                        | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/tools/flash.sh)               |
| `idf-bootstrap/`     | 只产 bootloader/分区表/flash_args 的 IDF 工程（`build/` 被忽略） | [查看](/static/code/#/zig-esp32-s31/ch27-ble-802154-boundary/idf-bootstrap/CMakeLists.txt) |

## 形态 B 的硬约束（本工程照抄，不重讲）

1. 镜像里正好两段落在 `0x40000000..0x44000000`（IROM + DROM），且 `0x20` 偏移；
2. trap 向量必须在 SRAM（`.trap_ram`），否则异常投递直接 `CPU_LOCKUP_RESET`；
3. 第一个装载段最前面是 256 字节 `esp_app_desc_t`（魔数 `0xABCD5432`）；
4. `_start` 里必须关 RTC/LP WDT，否则约 9 s 后 `rst:0x10 CHIP_LP_WDT_RESET`。

这些在本系列 ch13–ch26 已逐条实测，本工程只是沿用；地址来源见
`linker/s31.ld` 头注释（`components/esp_system/ld/esp32s31/memory.ld.in:19`）。

## 待闭环

| 项                   | 需要什么                                                                                            | 判据    |
| -------------------- | --------------------------------------------------------------------------------------------------- | ------- |
| 真实广播/扫描        | 链接 `libble_app.a` + `libbtdm_common.a` + `libbtbb.a`，配 `hci_transport_init(HCI_TRANSPORT_VHCI)` | 27.11.1 |
| 真实连接与 GATT 读写 | 上面 + ATT MTU 协商走真实 controller                                                                | 27.11.2 |
| 802.15.4 真实收发    | 链接 `esp_phy` 的 PHY + `libphy.a`，`esp_ieee802154_transmit()`                                     | 27.11.3 |
| Thread 入网          | 上面 + `libopenthread_br.a` 与 MLE/边界路由器                                                       | 27.11.4 |
