# ch17 以太网 MAC/PHY 驱动：从 MDIO 读到第一帧

> 所属章节：[[ch17-ethernet-mac-phy-driver|第十七章：以太网 MAC/PHY 驱动]] · 系列：[[zig-esp32-s31|Zig × ESP32-S31 全栈开发]]

> [!warning] 验证状态：**已上板四轮（2026-11-13）**：EMAC 时钟门控与 `mac_version=0x00001037`（`snps=0x37`）
> 读通；**DMA 软复位仍超时**（`busmode=0x00020101`），MDIO/PHY ID、RGMII、描述符环与 ping 均未进入。
> 第二轮按 IDF 顺序把数据接口时钟放到 SWR 之前、补写 `GMAC_MEM_CLK_FORCE_ON`（bit5）并打印
> 三个只读诊断位：`gmac_ctrl0=0x00000124`（`mem_clk_force_on=1`、`cactive=1`、
> `rst_clk_tx_n=0`、`rst_clk_rx_n=0`）——时钟域在要时钟，但 TX/RX 复位时钟没放行。
> 第三轮把 RGMII pad 路由提到时钟阶段之前，读数一字未变（`../logs/ch17c-boot.log`），
> 排除了 pad 顺序；剩下的最可疑环节是 ref clock 的源（MPLL 未按 500 MHz 运行）。
> 第四轮验证 GMAC 存储低功耗分支并继续跑完整阶段：`mem_lp_ctrl` 由 `0x6` 写成 `0xb` 后
> `prdyn` 仍为 0（不是 SWR 的钥匙）；`TXDESC_LIST`/`RXDESC_LIST` 写后读回 0，
> MDIO 扫不到 PHY，收发全部超时（`../logs/ch17d-boot.log`）。
> 详见 `../BRINGUP-2026-11-12.md` 第四轮与 `../logs/ch17{,b,c,d}-boot.log`。
> 已经完成的是可静态验证的部分：
>
> - `zig build -Dtarget=riscv32-freestanding-eabihf … -Doptimize=ReleaseSmall` 退出 0；
> - `elf2image` 打印 `Merged 2 ELF sections.`，`image-info` 的段表正好两行 `DROM, IROM`
>   （0x40000020 / 0x40020020，判据是“`DROM, IROM` 行数 == 2”）；
> - `zig build test` 的 20 个主机侧用例全绿（描述符布局、位域编码、PHY ID 解码、环回绕）；
> - `bash -n tools/flash.sh` 退出 0。
>
> **除 `clk:` / `rst:` 这几行外没有实测输出。** MDIO 的 `mdio:`、收发的 `tx:` / `rx:`
> 结果必须由本工程在板子上跑出来后才有资格写进章节；这些阶段目前还没被走到。
> 所有尚未验证的硬件行为在代码里都带 `TODO 待真机验证` 或 `待真机验证` 注释。

## 待真机验证清单

| #   | 待验证项     | 判据（跑起来看什么）                                                   | 对应章节 |
| --- | ------------ | ---------------------------------------------------------------------- | -------- |
| 1   | MDIO 通路    | 扫到 PHY，`ident` 既不是 `0x00000000` 也不是 `0xFFFFFFFF`              | 17.5     |
| 2   | PHY ID / OUI | `vendor=` 与原理图上的 PHY 厂商一致；`model`/`rev` 与手册对得上        | 17.5     |
| 3   | MDC 分频     | `csr_div` 档位下 MDC ≤ 2.5 MHz（示波器量 MDC，或至少“读 ID 稳定不飘”） | 17.4     |
| 4   | 引脚组别     | RGMII 走 GPIO8–19 还是 GPIO36–47；MDC/MDIO 到底接哪两个脚              | 17.3     |
| 5   | TXC 125 MHz  | GPIO13 上是 125 MHz、占空比接近 50%                                    | 17.6     |
| 6   | 自协商       | `bmsr.link=1`、协商出 1000M 全双工                                     | 17.6     |
| 7   | 描述符环     | TX 后 `TDES0.own` 被 DMA 清掉、`err=0`；RX 环 `des0` 由 DMA 清零       | 17.7     |
| 8   | 收包         | 插网线后 RX 环至少进一个包（ARP / LLDP / 广播）                        | 17.9     |
| 9   | ping 验收    | 接 18 章的 ARP/ICMP 之后，从 PC `ping` 通 —— **本章不做，留给 18 章**  | 17.11    |

## 目的

这是形态 B 的第十二个工程，骨架沿用 `ch15-observability-testing-stability`
（同一套 `linker/s31.ld` + `_start` + `esptool elf2image`，IDF 只提供二级
bootloader 与分区表）。**没有调度器、没有中断、没有 netif**：`MIE` 恒为 0，
DMA 中断使能全 0，收发全靠轮询。

本章要回答的是“以太网到底难在哪”，答案不是“发一个包”，而是三件事：

1. **MDIO 是唯一能证明“PHY 活着”的通道**。没有它，后面所有现象都无法区分
   “MAC 没配对”和“PHY 没插线”。
2. **描述符环的所有权只有一个同步点**（OWN 位）。这一位错，症状是 DMA
   永远不碰描述符，而串口上什么都看不到。
3. **cache 维护在 S31 上是空操作，在 P4 上不是**。同一个驱动换芯片时，
   唯一必须改的语义就在这里。

### 九个阶段

| 阶段 | 动作                                              | 串口前缀        |
| ---- | ------------------------------------------------- | --------------- |
| 0    | banner + 构建选项 + 关 RTC WDT                    | `wdt:`          |
| 1    | 时钟门控 + GMAC 复位 + 版本寄存器                 | `clk:` / `rst:` |
| 2    | RGMII 引脚（IO_MUX）+ MDC/MDIO（GPIO 矩阵）       | `pin:`          |
| 3    | MDIO 分频 + 扫 PHY + ID/BMSR/ANAR/ANLPAR/千兆状态 | `mdio:`         |
| 4    | MACCR / MACFF / MAC 地址                          | `mac:`          |
| 5    | DMA 软复位 + BUSMODE / OPMODE                     | `dma:`          |
| 6    | 描述符环地址与 OWN 位                             | `ring:`         |
| 7    | 发一帧最小以太网帧                                | `tx:`           |
| 8    | 轮询 RX 环                                        | `rx:`           |
| 9    | 统计 + 待真机验证清单                             | `sum:`          |

### 工程不做的事

- **不实现 ARP/ICMP**：本章只保证“能读 PHY、能发一帧、能进一帧”。
  `ping` 需要 ARP 缓存与 ICMP 回显，属于 18 章。
- **不配置 PLL**：RGMII 的 125 MHz TXC 来自 CNNT 的 ref clock 分频器，
  分频值按“源 PLL 500 MHz / 125 MHz - 1 = 3”写死。源 PLL 是 bootloader
  留下的状态，**待真机验证**。
- **不开中断**：`DMA.INTRENABLE = 0`、`MAC.INTMASK = 0xFFFFFFFF`。
  中断路径（中断源 98 = `ETS_SBD_INTR_SOURCE`；CLIC 输入由中断矩阵
  路由到 16..47）在 17.8 里作为对照讨论，代码里不启用。
- **不做 cache 维护**：S31 内部 SRAM 不经 L1 D-cache
  （`soc_caps.h` 没有 `SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE`），
  所以描述符环只要 `fence rw, rw`。P4 的对照做法写在 17.7 的表里。
- **不分配内存**：描述符环、缓冲、统计全在 `.bss`。

## 硬件与接线

| 项              | 事实                                                                     |
| --------------- | ------------------------------------------------------------------------ |
| 目标板          | ESP32-S31-Function-CoreBoard-1                                           |
| 模组            | ESP32-S31-WROOM-3（N16R16V），16 MB Flash + 16 MB PSRAM                  |
| 以太网          | 板载 1G MAC + RGMII PHY + RJ45（见 `practice/zig-esp32-s31/SPEC.md:82`） |
| 控制台          | UART0，GPIO58（TX）/ GPIO59（RX），115200 8N1                            |
| 下载模式        | BOOT = GPIO61                                                            |
| RGMII 数据/时钟 | GPIO8–19（IDF `emac_periph.c` 第一组），IO_MUX 功能号 2                  |
| MDC / MDIO      | **待真机验证**：`src/pins.zig` 顶部常量，默认 GPIO20 / GPIO21            |
| 观测            | 串口 + （推荐）示波器看 GPIO13 的 125 MHz TXC                            |

`src/pins.zig` 的 RGMII 表：

| 信号      | GPIO              | 方向 | IO_MUX |
| --------- | ----------------- | ---- | ------ |
| TXD0–TXD3 | 8 / 9 / 10 / 11   | 出   | 2      |
| TX_CTL    | 12                | 出   | 2      |
| TXC       | 13                | 出   | 2      |
| RXC       | 14                | 入   | 2      |
| RX_CTL    | 15                | 入   | 2      |
| RXD3–RXD0 | 16 / 17 / 18 / 19 | 入   | 2      |

## 寄存器速查

全部来自 `~/esp/esp-idf/components/soc/esp32s31/register/soc/`：

| 名字                     | 地址                          | 关键位                                                                                |
| ------------------------ | ----------------------------- | ------------------------------------------------------------------------------------- |
| GMAC MAC 块              | `0x2035_0000`                 | `reg_base.h:16`                                                                       |
| GMAC DMA 块              | `0x2035_0000 + 0x1000`        | `gmac_reg.h:3351`                                                                     |
| MACCR                    | +0x000                        | TE bit3、RE bit2、DM bit11、PS bit15、FES bit14                                       |
| MACFF                    | +0x004                        | PM bit0、RA bit31、DBF bit5（置 1 = 丢广播）                                          |
| GMIIADDR                 | +0x010                        | busy bit0、write bit1、csrclk[5:2]、reg[10:6]、dev[15:11]                             |
| GMIIDATA                 | +0x014                        | data[15:0]                                                                            |
| VERSION                  | +0x020                        | SNPSVER[7:0]（本核默认 0x37）                                                         |
| BUSMODE                  | +0x1000                       | SWR bit0、DSL[6:2]、ATDS bit7、PBL[13:8]、USP bit23、PBLX8 bit24、AAL bit25、MB bit26 |
| STATUS                   | +0x1014                       | TI bit0、RI bit6、AIS bit15、NIS bit16、RS[19:17]、TS[22:20]                          |
| OPMODE                   | +0x1018                       | SR bit1、OSF bit2、ST bit13、FTF bit20、RSF bit25                                     |
| RXDESC/TXDESC            | +0x100c / +0x1010             | 环基址（低 2 位被硬件忽略）                                                           |
| CNNT_SYS                 | `0x2035_9000`                 | RST_EN +0x3c bit1、PHY_INTF_SEL +0x60 [4:2]、REF_CLK_DIV +0x40 [15:8]                 |
| HP_SYS_CLKRST EMAC_CTRL0 | `0x2058_7000 + 0xc8`          | bit0 = EMAC_SYS_CLK_EN                                                                |
| IO_MUX                   | `0x2058_2000 + 4*n`           | MCU_SEL[14:12]、FUN_IE bit9、FUN_DRV[11:10]                                           |
| GPIO 矩阵输出            | `0x2058_3000 + 0xaf4 + 4*n`   | OUT_SEL[8:0]、OEN_SEL bit10                                                           |
| GPIO 矩阵输入            | `0x2058_3000 + 0x2f4 + 4*sig` | IN_SEL[7:0]、SIG_IN_SEL bit9                                                          |

## 构建、测试、烧录

```bash
cd practice/zig-esp32-s31/ch17-ethernet-mac-phy-driver
. /tmp/idfenv.sh

# 1) 交叉编译（Zig 0.17.1）
zig build -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall

# 2) ELF → 镜像
python -m esptool --chip esp32s31 elf2image --flash-mode dio --flash-size 16MB \
  --flash-freq 80m -o zig-out/bin/app.bin zig-out/bin/app.elf

# 3) 段表必须正好两行 DROM, IROM
python -m esptool --chip esp32s31 image-info zig-out/bin/app.bin

# 4) 主机侧单测（不需要开发板）
zig build test

# 5) 烧录（偏移只从 IDF 的 flash_args 来；见下）
sh tools/flash.sh /dev/ttyUSB0
```

PHY 还没接线时，可以先跑一遍“不碰 MDIO”的形态，确认时钟/复位/IDLE 路径正常：

```bash
zig build -Dskip-mdio=true -Dtarget=riscv32-freestanding-eabihf \
  -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall
```

`tools/flash.sh` 的前置条件与 ch15 相同：先在 `idf-bootstrap/` 里完成一次
IDF 构建，产出 `build/{bootloader,partition_table}/…` 与 `build/flash_args`。
脚本把 `flash_args` 里的 `0x10000` 应用行替换成 `zig-out/bin/app.bin`，
bootloader 与分区表行原样保留。

```bash
cd idf-bootstrap
idf.py --preview set-target esp32s31
idf.py build
```

## 源码地图

| 文件                 | 内容                                                               |
| -------------------- | ------------------------------------------------------------------ |
| `src/start.zig`      | `_start`（关中断/栈/gp/关 WDT/清 .bss/装 mtvec）+ `esp_app_desc_t` |
| `src/hw.zig`         | MMIO、`fence rw, rw`、CSR、TIMG0 1 MHz、RTC WDT disarm             |
| `src/log.zig`        | 串口输出（ROM `esp_rom_printf`，栈上格式化）                       |
| `src/trap.zig`       | trap 入口（`.trap_ram`）+ panic dump                               |
| `src/regs.zig`       | 寄存器地图与位域编码（**纯常量 + 纯函数**）                        |
| `src/descs.zig`      | 32 字节增强描述符、OWN 位、帧长/错误解码                           |
| `src/phy.zig`        | IEEE 802.3 第 22 条寄存器解码（ID/OUI/BMSR/ANAR/千兆）             |
| `src/pins.zig`       | RGMII IO_MUX + MDC/MDIO GPIO 矩阵                                  |
| `src/emac.zig`       | 时钟/复位/MDIO/MAC/DMA/环/一发一收                                 |
| `src/main.zig`       | 九个阶段的编排与打印                                               |
| `src/host_tests.zig` | 主机侧单测入口                                                     |
| `linker/s31.ld`      | 两个 flash 装载段 + `.trap_ram` + 堆栈边界                         |
| `idf-bootstrap/`     | 只产 bootloader / 分区表 / flash_args 的 IDF 工程                  |

## 判读顺序（上板后照着这个顺序看）

1. `clk:` / `rst:` —— 门控位为 1、`snps=0x37`。**这两行不对，后面全部无意义。**
2. `pin:` —— `mcu_sel=2`（RGMII）、输出脚 `ie=0`、输入脚 `ie=1`。
3. `mdio:` —— 分频档位先看，再看扫到的地址与 ID。`no PHY responded` 说明
   要么脚号错、要么 PHY 无供电；**不要**在这一步就去怀疑驱动逻辑。
4. `mac:` / `dma:` —— `te=1 re=1`、`busmode` 的 `atds=1`、`swr=0`。
5. `ring:` —— 描述符地址必须落在 SRAM（`0x2f….`），`rx[i].des0 = 0x80000000`
   （OWN = 1）。
6. `tx:` —— `own` 被清、`err=0`；`status` 里的 `TI(bit0)` 应该被置起来。
7. `rx:` —— 没有帧是正常的（PHY 没插线）；有帧时先看 `err=0x0` 与 `type`。
8. `sum:` —— 七条待真机验证清单，逐条打勾才算本章收尾。
