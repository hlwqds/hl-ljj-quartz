# eth_mdio_probe —— EMAC 与 PHY 上电探针（ch20 配套）

对应章节：[[ch20-ethernet-emac-phy|以太网上电：EMAC 与 PHY]]（F429 裸机实验室第二十章）。
系列总目录：[[f429-lab|F429 裸机实验室索引]]。

把章节的「MDIO 读 PHY ID + Link 检测」设计落成固件：全寄存器级裸机（无 HAL/CubeMX），
SYSCFG 选 RMII → ETH 三时钟 → DMA 描述符环上架 → MDIO 扫描 32 个 PHY 地址读 ID →
BCR 软复位+自协商 → 半秒轮询 BSR bit2，串口只打印 Link 翻转。

> 状态：**先成文、后实跑**——固件已编译通过（`arm-none-eabi-gcc 15.2`），真机行为待实测核销，
> 章节「待核对清单」里的 PHY 型号/地址/REF_CLK 方案以本固件串口读数为准对号入座。

## 硬件拓扑

```text
[笔记本] --USB--> [CH340] --USART1 PA9/PA10--> [STM32F429 挑战者 V2]
                                                  |  (RMII 九脚 + 50MHz REF_CLK)
                                                  [LAN8720/8742 PHY] --RJ45--> 网线 --> [树莓派 4B]
[野火 DAP] --SWD--> 烧录/调试（openocd）
```

## 目录结构

| 文件           | 说明                                                                        |
| -------------- | --------------------------------------------------------------------------- |
| `main.c`       | 时钟 180MHz + USART1 + SysTick + ETH 初始化 + MDIO 扫描 + Link 轮询（全部） |
| `startup.S`    | 向量表（内核 16 异常 + 91 外部中断兜底；SysTick 槽指向 `SysTick_Handler`）  |
| `stm32f429.ld` | F429IG 2MB flash + 192KB 主 SRAM；描述符/帧缓冲落 `.bss`（禁 CCM）          |
| `Makefile`     | `make` 编译、`make flash` 烧录、`make term` 串口                            |

## 复现命令

```bash
make                 # 编译（arm-none-eabi-gcc，NixOS 下 nix-shell -p gcc-arm-embedded）
make flash           # openocd + DAP 烧录
make term            # minicom /dev/ttyUSB0 @115200 看输出
# 活体寄存器核销（另一终端，任务跑着时）：
openocd -f interface/cmsis-dap.cfg -f target/stm32f4x.cfg
telnet localhost 4444
> mdw 0x40023830 1   # RCC_AHB1ENR：bit25:27=111 即 ETH 三时钟齐
> mdw 0x40013804 1   # SYSCFG_PMC：bit23=1 即 RMII 已选
> mdw 0x40028000 1   # MACCR：预期 0x0000408C
> mdw 0x4002900C 1   # DMARDLAR：应等于 nm 查到的 rx_d 地址（0x2000xxxx 段）
```

## 预期输出（待实测核销）

```text
=== eth_mdio_probe : ch20 EMAC+PHY ===
-- MDIO scan (reg2/3, addr 0..31) --
phy 0 ID1=0x0007 ID2=0xC0F0        # LAN8720 候选；若 0xC13x → LAN8742
link: UP   BSR=0x79xx autoneg=1    # 插网线直连树莓派后 1–3s
link: DOWN BSR=0x79xx autoneg=0    # 拔线
```

实测后把真实输出（含 `run.log`）回填本文件与章节，替换上表的推导值。

## 下一步

`lwip-arp-ping`（[[ch21-baremetal-lwip|裸机 lwIP]]）复用本工程的
`eth_hw_init()`/描述符环，把硬件邮箱接上协议栈发出第一声 ARP。
