---
title: "Zig × ESP32-S31 全栈开发（十七）：以太网 MAC/PHY 驱动"
date: 2026-11-29 18:00:00
description: "把 RJ45 接进裸机：S31 千兆 EMAC 的 MAC/DMA 两块寄存器地图、RGMII 的 12 根线与 IO_MUX 功能号、CNNT 域的时钟/复位/125MHz TXC 分频、MDIO 帧与 PHY ID 解码、自协商的 ANAR/ANLPAR/1000BASE-T 三重判定、32 字节增强描述符环与唯一的 OWN 同步点、cache 维护在 S31 与 P4 上的分界、轮询与中断两条替换路径，以及收包交给 netif 的四次交接。"
tags: [zig, esp32-s31, riscv, ethernet, emac, rgmii, mdio, dma, series]
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
> 9. [[ch09-spi-flash-partition-nvs|第九章：SPI Flash、分区与 NVS 存储]]
> 10. [[ch10-context-switch-cooperative-scheduler|第十章：上下文切换与协作调度]]
> 11. [[ch11-preemptive-scheduler-tcb-tick|第十一章：抢占调度、TCB 与 tick]]
> 12. [[ch12-sync-primitives-ipc|第十二章：同步原语与 IPC]]
> 13. [[ch13-heap-stack-caps|第十三章：堆、栈保护与内存 caps]]
> 14. [[ch14-dual-core-smp-ipi|第十四章：双核 SMP 与 IPI]]
> 15. [[ch15-observability-testing-stability|第十五章：可观测性、测试与稳定性]]
> 16. [[ch16-stack-architecture-zero-copy|第十六章：协议栈架构、缓冲与零拷贝]]
> 17. **第十七章：以太网 MAC/PHY 驱动**
> 18. [[ch18-ipv4-icmp-arp-routing|第十八章：IPv4、ICMP、ARP 与路由]]

# Zig × ESP32-S31 全栈开发（十七）：以太网 MAC/PHY 驱动

前十六章里，所有“数据从外面进来”的路径都绕不开一个前提：得有人把比特从
差分对上搬进内存。这一章就是那个“有人”——S31 的千兆 EMAC（Synopsys
DWC_gmac 核）+ RGMII PHY。

这一章真正的难点不在“写一个 DMA 驱动”，而在**证明自己看对了**：
MDIO 读回的值是唯一能证明 PHY 活着的证据；`OWN` 位是唯一能证明 DMA
真的动了描述符的证据；`snps=0x37` 是唯一能证明“复位之后寄存器真的是默认值”
的证据。所以工程被切成九个阶段，每一段都先打印“我准备做什么”，
再打印“读回来是什么”。

> [!warning] 本章的证据边界
> 静态部分全部验证过：交叉编译退出 0、`elf2image` 两个 flash 段、`zig build test`
> 的 20 个主机侧用例全绿、`bash -n tools/flash.sh` 退出 0。
>
> **已上板一次（2026-11-13，CoreBoard-1）**，结果分两截：
>
> - **通过**：EMAC 侧时钟门控生效（`hp_sys_clkrst+0xc8 bit0` 读回 1）；
>   `mac_version=0x00001037`（`snps=0x37`，Synopsys GMAC 签名对上）；
>   `hw_feature=0x0b056727`。
> - **未通过**：DMA 软复位超时——`dma soft reset failed: Timeout (busmode=0x00020101)`。
>   MDIO / PHY ID、RGMII、描述符环与 ping 因此全部没有进入。
>
> 所以本章其余“硬件到底怎么表现”的结论仍标「待真机验证」；`busmode` 的实测值与
> 排查方向写在 `../BRINGUP-2026-11-12.md` 第四轮。凡是没有证据的地方，本章的
> 写法是**写出判据**而不是写出结论。

---

## 17.1 为什么把以太网放在 Wi-Fi 前面

系列路线图把 Part IV 叫作“网络底座”，并且把以太网排在 Wi-Fi 之前
（`content/zig-esp32-s31/index.md` 的 Part IV 表格，第 17 行）。理由不是
“有线更简单”，而是**有线是唯一不需要厂商 blob 的路径**：

| 路径   | 需要什么                                  | 对“全 Zig”意味着               |
| ------ | ----------------------------------------- | ------------------------------ |
| 以太网 | MAC/DMA 寄存器 + 标准 PHY（MDIO 可读）    | 全部自己写，寄存器级可查       |
| Wi-Fi  | `libnet80211`/`libpp`/`libphy` 三个二进制 | 必须接 blob 或写兼容层（ch25） |

以太网这条路上，**每一个字节的来龙去脉都能在寄存器里查到**：帧从 PHY 的
RXD 差分对进来，经 RGMII 的 DDR 采样进 MAC，由 DMA 按描述符写进 SRAM，
CPU 读描述符的 `OWN` 位知道“这帧是我的了”。中间没有闭源环节。

这也是本章的一个隐性目标：把“无 blob 的诚实路径”跑通一次之后，
ch25 讨论“Wi-Fi blob 边界”时才有对照物——你会清楚地知道，
哪些事情是硬件做的、哪些事情是 blob 替你做的。

---

## 17.2 S31 千兆 EMAC 的架构：两块寄存器 + 一个 CNNT 域

S31 的 EMAC 是 Synopsys DWC_gmac 的千兆配置。读版本寄存器（MAC 块 `+0x20`）
的低 8 位是 `GMAC_SNPSVER`，本核的默认值是 `0x37`——这是本章第一个可打印的
“复位生效”证据（`gmac_reg.h:782-790`）。

寄存器被切成两块，共用一个基址：

```text
0x2035_0000 + 0x000 .. 0x0FF    MAC：配置/过滤/MDIO/MAC 地址/中断
0x2035_0000 + 0x1000 .. 0x105F  DMA：总线模式/描述符环/状态/操作模式
```

基址来自 `components/soc/esp32s31/register/soc/reg_base.h:16`
（`DR_REG_GMAC_BASE = 0x20350000`）。DMA 块的偏移在 `gmac_reg.h` 里连续排出：
`BUSMODE +0x1000`、`TXPOLLDEMAND +0x1004`、`RXPOLLDEMAND +0x1008`、
`RXDESCLIST +0x100c`、`TXDESCLIST +0x1010`、`STATUS +0x1014`、
`OPMODE +0x1018`、`INTRENABLE +0x101c`（`gmac_reg.h:3351-4152`）。

同一个 IP 在 IDF 里有两套符号，读代码时要能互相翻译：

| 一套               | 例子                                   | 谁在用                                              |
| ------------------ | -------------------------------------- | --------------------------------------------------- |
| 位宏（CMSIS 风格） | `GMAC_RE (BIT(2))`、`GMAC_TE (BIT(3))` | `gmac_reg.h`，直接读改写地址                        |
| 位域结构体         | `emac_mac_dev_t.gmacconfig.rx`         | `emac_ll_set_*`（`esp32s31/include/hal/emac_ll.h`） |

本章用第一套（位宏）：裸机 Zig 里不需要位域结构体，移位常量更直白，
而且**位号可以逐条对照**。两套的位号必须一致——这是本章核对工作的一半
工作量；`src/regs.zig` 里每个常量下面都标了 struct 里的字段名。

第三块不属于 GMAC，但**必须配**：CNNT 域（`0x2035_9000`）。时钟、复位、
接口选择、RGMII 的 125 MHz TXC 分频全在这里：

```text
CNNT_SYS + 0x1c  GMAC_MEM_LP_CTRL      （内存低功耗）
CNNT_SYS + 0x3c  HP_EMAC_CTRL          RST_EN bit1
CNNT_SYS + 0x40  HP_EMAC_REF_CTRL      REF_CLK_SEL[1:0]/EN bit2/DIV[15:8]
CNNT_SYS + 0x44  HP_EMAC_RMII_PAD_CTRL
CNNT_SYS + 0x48  HP_EMAC_RMII_CTRL     PAD_OUT_CLK_EN bit2（RGMII 的 TXC）
CNNT_SYS + 0x4c  HP_EMAC_RX_CTRL       PAD_CLK_EN/SEL/180_CLK_EN
CNNT_SYS + 0x50  HP_EMAC_TX_CTRL       同上
CNNT_SYS + 0x60  GMAC_CTRL0            PHY_INTF_SEL[4:2]
```

来源：`cnnt_sys_reg.h:138/338/364/397/416/449/482/558`。

> 一个坑：`cnnt_sys_reg.h` 里所有寄存器都写成 `DR_REG_CNNT_BASE + off`，
> 但整个 IDF 树里**没有** `DR_REG_CNNT_BASE` 的定义（真正的基址叫
> `DR_REG_CNNT_SYS_REG_BASE`，见 `reg_base.h:21`）。所以这些 `#define`
> 实际上是不可用的死代码——HAL 走的是 `CNNT_SYS_REG` 这个结构体实例。
> 本章直接按 `0x2035_9000 + off` 访问，并在 `src/regs.zig` 里注明了这一点。

---

## 17.3 RGMII 的 12 根线与 IO_MUX 功能号

RGMII 是 DDR 接口：125 MHz 时钟、双沿采样、每根数据线每周期传 2 bit。
千兆全双工需要这些信号：

| 信号       | 方向 | RGMII 里的语义                                 |
| ---------- | ---- | ---------------------------------------------- |
| TXC        | 出   | 125 MHz 发送时钟（SoC 产生，送 PHY）           |
| TX_CTL     | 出   | TXEN 与 TXERR 的复用（DDR）                    |
| TXD0..TXD3 | 出   | 数据，每根每周期 2 bit → 4 根 × 2 = 8 bit/周期 |
| RXC        | 入   | 125 MHz 接收时钟（PHY 产生）                   |
| RX_CTL     | 入   | RXDV 与 RXERR 的复用                           |
| RXD0..RXD3 | 入   | 数据                                           |
| MDC        | 出   | 管理时钟（≤ 2.5 MHz）                          |
| MDIO       | 双向 | 管理数据                                       |

S31 的引脚有一个很好的性质：**数据/时钟脚有 IO_MUX 功能，MDC/MDIO 没有**。
`soc_caps.h:119-121` 三条宏把这件事说清楚了：

```c
#define SOC_EMAC_USE_MULTI_IO_MUX          (1)  // 每根信号有多个 IO_MUX 候选脚
#define SOC_EMAC_MII_USE_GPIO_MATRIX       (1)  // MII/RMII 信号也能走 GPIO 矩阵
#define SOC_EMAC_DEDICATED_GPIO_CTRL_SUPPORTED (1) // 另有 CNNT 域的独立 pad 控制
```

候选脚表在 `components/esp_hal_emac/esp32s31/emac_periph.c`。第一组是
**GPIO8–19 一整块**，12 根信号一一对应（每个都是 IO_MUX 功能号 2）：

| GPIO | 8    | 9    | 10   | 11   | 12     | 13  | 14  | 15     | 16   | 17   | 18   | 19   |
| ---- | ---- | ---- | ---- | ---- | ------ | --- | --- | ------ | ---- | ---- | ---- | ---- |
| 信号 | TXD0 | TXD1 | TXD2 | TXD3 | TX_CTL | TXC | RXC | RX_CTL | RXD3 | RXD2 | RXD1 | RXD0 |

功能号来自 `io_mux_reg.h:188-264`（`FUNC_GPIO8_GMAC_PHY_TXD0_PAD = 2` 等，
12 个全是 2）；`emac_periph.c` 的第二组候选是 GPIO36–47。

配置一个脚的写法（`src/pins.zig`）：

```zig
// IO_MUX 每脚一个 4 字节寄存器：0x2058_2000 + 4*gpio
//   MCU_SEL[14:12] = 2  → 选 GMAC 功能
//   FUN_IE  bit9   = 1  → 输入使能（只有输入脚需要）
//   FUN_DRV[11:10] = 2  → 驱动强度档
var v = hw.readReg(regs.iomuxAddr(cfg.gpio));
v &= ~(regs.iomux.mcu_sel_mask | regs.iomux.fun_ie |
       regs.iomux.fun_pu | regs.iomux.fun_pd);
v |= @as(u32, cfg.func) << regs.iomux.mcu_sel_shift;
if (cfg.input) v |= regs.iomux.fun_ie;
hw.writeReg(regs.iomuxAddr(cfg.gpio), v);
```

MDC/MDIO 只能走 GPIO 矩阵，而且 S31 的矩阵是**“信号索引”结构**
（`gpio_struct.h:972-1022`），和 ESP32 那一代的“按 GPIO 号索引”不一样：

| 方向 | 寄存器地址                       | 字段                                                           |
| ---- | -------------------------------- | -------------------------------------------------------------- |
| 输出 | `0x2058_3000 + 0xaf4 + 4*gpio`   | `OUT_SEL[8:0]`、`OUT_INV_SEL` bit9、`OEN_SEL` bit10            |
| 输入 | `0x2058_3000 + 0x2f4 + 4*signal` | `IN_SEL[7:0]`（GPIO 号）、`IN_INV_SEL` bit8、`SIG_IN_SEL` bit9 |

即：**输出按脚索引、输入按信号索引**。输入侧寄存器里存的是 GPIO 号，
再置 `SIG_IN_SEL = 1` 表示“走矩阵”（0 是旁路直连 IO_MUX）。
信号号来自 `gpio_sig_map.h`：MDIO 输入 = 107、MDC 输出 = 108、MDO 输出 = 109。

`OEN_SEL` 这一位决定了 MDIO 会不会打架：置 1 表示输出使能由
`GPIO_ENABLE_REG` 控制（永远驱动），置 0 表示由外设控制（读 PHY 时三态）。
MDIO 是双向线，**必须置 0**，否则 MAC 会一直把线拉低/拉高，PHY 无法回话。

工程里 RGMII 组别与 MDC/MDIO 脚号都是常量，默认值取自 IDF 表的第一组与
GPIO20/21：

```zig
pub const default_mdc: u5 = 20;
pub const default_mdio: u5 = 21;
```

**待真机验证**：这两脚的编号必须与原理图一致。接错的症状非常明确——
MDIO 读回 `0xFFFF`（线被上拉拉高，没有器件驱动低电平）或 `0x0000`
（MDO 一直拉低）。本章把这个判据写进了 `mdio:` 阶段的打印里。

---

## 17.4 时钟、复位与 MDC 分频

初始化顺序不是随便排的，它由三件事约束：

1. **寄存器访问之前必须有系统时钟**。`HP_SYS_CLKRST + 0xC8` 的 bit0
   是 `EMAC_SYS_CLK_EN`（`hp_sys_clkrst_reg.h:2194-2201`）。IDF 的
   `emac_ll_enable_bus_clock(0, true)` 就是写这一位。
2. **HAL 初始化之前必须复位**。`emac_ll_reset_register(0)` 写
   `CNNT_SYS_REG.sys_hp_emac_ctrl.sys_emac_rst_en = 1` 然后立刻写 0
   （`emac_ll.h:892-899`）。esp_eth 的注释写得很直白：
   "this must be called before HAL layer initialization"
   （`esp_eth_mac_esp.c:1186-1188`）。
3. **描述符环与 MAC 配置必须在 DMA 启动之前**。否则 DMA 会用垃圾指针。

工程的顺序与 IDF 一一对应：

| 步骤        | 工程里的函数               | IDF 里的对应物                        |
| ----------- | -------------------------- | ------------------------------------- |
| 开门控      | `emac.enableBusClock()`    | `emac_ll_enable_bus_clock(0, true)`   |
| 复位寄存器  | `emac.resetRegisters()`    | `emac_ll_reset_register(0)`           |
| 读版本      | `emac.macVersion()`        | 无（本章新加的判据）                  |
| 选接口+时钟 | `emac.enableRgmiiClocks()` | `emac_ll_clock_enable_rgmii()`        |
| MDC 分频    | `emac.setCsrDiv()`         | `emac_hal_set_csr_clock_range()`      |
| DMA 软复位  | `emac.resetDma()`          | `emac_hal_reset()` + 轮询 `sw_rst`    |
| MAC 默认值  | `emac.initMacConfig()`     | `emac_hal_init_mac_default()`         |
| DMA 默认值  | `emac.initDmaDefaults()`   | `emac_hal_init_dma_default()`         |
| 环基址      | `emac.setRingAddresses()`  | `emac_hal_set_rx_tx_desc_addr()`      |
| 启动        | `emac.startDma()`          | `emac_hal_start()`：TE → ST → SR → RE |

启动顺序有一句必须照抄的实测经验。IDF 的 `emac_hal_start`
（`emac_hal.c:638-655`）先使能 MAC 发送器（TE）、再启动 DMA 发送（ST），
再启动 DMA 接收（SR）、最后使能 MAC 接收器（RE），并在中间写了一条注释：

```c
/* Note that the EMAC Databook states the DMA could be started prior enabling
   the MAC transmitter. However, it turned out that such order may cause the MAC
   transmitter hangs */
```

“数据手册说可以先启 DMA，但实测会挂住发送器。”这条注释比手册值钱——
本章的 `startDma()` 就按 TE→ST→SR→RE 排，`stopDma()` 按
“停 TX DMA → 停两个 MAC 状态机 → 停 RX DMA”反向收尾。

顺带说明：`initMacConfig` **不打开** TE/RE（IDF 的 `init_mac_default` 也不开），
所以在 `mac:` 阶段打印出来的 `te=0 re=0` 是**正确**的。要等 `tx:` 阶段看到
`start order TE->ST->SR->RE done: te=1 re=1` 才算真的启动。

MDC 分频值得单独说：`GMIIADDRESS.miicsrclk[5:2]` 不是“除数”，而是
**除数表的索引**。表在 `emac_hal.c:17-24`：

```c
static uint8_t emac_crs_div_table[] = { 42, 62, 16, 26, 102, 124 };
```

IEEE 802.3 第 22 条规定 MDC 上限 2.5 MHz。裸机拿不到确切的 SYS 频率
（那是 bootloader 配的 CPU/SYS 分频决定的），所以本工程默认取**最保守的档位**：

```zig
pub const csr_div_safest: u4 = 5;   // 除数 124
```

只要 SYS_CLK ≤ 310 MHz，`SYS/124 ≤ 2.5 MHz` 就成立——这是一条**可以算出来的
保证**，而不是“差不多”。主机侧单测里用 40→300 MHz 每 20 MHz 扫一遍验证了它。

如果哪天真机测出了 SYS 频率，`regs.pickCsrDiv(sys_hz)` 会按“合格档里最快”
挑一个（240 MHz → 档位 4 即 /102；80 MHz → 档位 0 即 /42），
单测已经把这两个值钉住了。

---

## 17.5 MDIO：读 PHY ID 是唯一可信的握手

MDIO 的帧头（前导 + start + opcode + PHY 地址 + 寄存器地址 + turnaround）
**由硬件拼**，软件只填四个字段并置 busy（`emac_hal.c:239-250`）：

```text
GMIIADDRESS（MAC + 0x10）
  bit0      miibusy    1 = 事务进行中（写完自清零）
  bit1      miiwrite   1 = 写，0 = 读
  [5:2]     miicsrclk  MDC 分频档位
  [10:6]    miireg     寄存器号（0..31）
  [15:11]   miidev     PHY 地址（0..31）
GMIIDATA（MAC + 0x14）
  [15:0]    data       写操作前先填，读操作后取
```

位号来自 `emac_mac_struct.h` 的 `emacgmiiaddr` 位域（`miibusy/miiwrite/
miicsrclk/miireg/miidev` 依次是 bit0/bit1/[5:2]/[10:6]/[15:11]）。

**读操作的顺序有一个必须遵守的细节**：先写“地址 + busy=0”摆好字段，
再写“地址 + busy=1”启动；数据寄存器在 busy 清零之前**不可信**。
写操作则是先把数据写进 GMIIDATA，再置 busy。

工程的实现（`src/emac.zig`）：

```zig
try waitMdioIdle(timeout_us);                     // busy 必须为 0
hw.writeReg(gmii_addr, gmiiAddrValue(dev, reg, csr_div, false, false));
hw.fence();
hw.writeReg(gmii_addr, gmiiAddrValue(dev, reg, csr_div, false, true)); // busy=1
try waitMdioIdle(timeout_us);                     // 等它自清零
return @truncate(hw.readReg(gmii_data));
```

超时用 1 MHz 的软件时钟（TIMG0）而不是空转计数：MDC 周期与 SYS 时钟相关，
固定循环次数在不同主频下代表完全不同的时间。2 ms 的预算对一次
64 bit 事务（MDC ≤ 2.5 MHz 时约 26 µs）宽裕得多。

### PHY ID 怎么读成“厂商 + 型号”

寄存器 2/3 是标准化的（IEEE 802.3 第 22 条）：

```text
PHYID1 = OUI[21:6]
PHYID2 = OUI[5:0] << 10 | MODEL[5:0] << 4 | REV[3:0]
```

拼出来的 22 位“OUI”与数据手册封面上的 24 位公司 OUI **不是一回事**，
这是个常见误会。举三个真实 ID：

| PHY     | ID1/ID2             | 拼出的 OUI | 厂商              |
| ------- | ------------------- | ---------- | ----------------- |
| RTL8211 | `0x001C` / `0xC916` | `0x000732` | Realtek           |
| 88E1512 | `0x0141` / `0x0DD1` | `0x005043` | Marvell           |
| DP83867 | `0x2000` / `0xA231` | `0x080028` | Texas Instruments |

`src/phy.zig` 的解码：

```zig
const oui: u32 = (@as(u32, id1) << 6) | (@as(u32, id2) >> 10);
const model: u16 = (id2 >> 4) & 0x3F;
const revision: u16 = id2 & 0xF;
```

主机侧单测把这三个 ID 都钉住了——不是为了“支持这三家”，而是为了证明
**移位算法本身是对的**。真机上如果读到 `0x0000` 或 `0xFFFF`，
问题一定在物理层（脚号/供电/PHY 复位），不要在算法里找。

### 扫地址

PHY 地址由 PHY 的 strapping 脚决定（0..31）。工程扫全部 32 个地址，
取第一个“ID 既不是 0 也不是 0xFFFFFFFF”的：

```zig
pub fn scanPhy(timeout_us: u32) ?u5 {
    var a: u32 = 0;
    while (a < 32) : (a += 1) {
        const addr: u5 = @intCast(a);
        const id1 = mdioRead(addr, phy.reg.phy_id1, timeout_us) catch 0;
        if (id1 != 0 and id1 != 0xFFFF) return addr;
    }
    return null;
}
```

两种失败值对应两种物理事实，这个区分很重要：

- `0xFFFF`：MDIO 线被上拉拉高。没有任何器件把它拉低 → PHY 没供电、
  或者 MDIO 脚号接错；
- `0x0000`：线被持续拉低 → MDO 一直驱动（`OEN_SEL` 配错）、或 MDC 没出来。

---

## 17.6 自协商：三次读、一张表

PHY 自协商的结果不是“一个寄存器”，而是三处信息合起来：

```text
BMSR    (0x01)  bit2 链路、bit5 自协商完成、[15:9] 支持的能力位
ANAR    (0x04)  我们通告的能力（10/100 四档 + pause）
ANLPAR  (0x05)  对端通告的能力
GbT ctrl(0x09)  1000BASE-T 的主从偏好
GbT stat(0x0A)  bit11 对端 1000FD、bit13 本地接收 OK、bit14 master
```

判定顺序必须是“先千兆、后十百兆”，因为 1000BASE-T 不走 ANAR/ANLPAR
那 16 位（它用 next-page 机制，寄存器 9/10）：

```zig
const g = phy.negotiated1000(snap.gb_status);          // bit11 & bit13
const mode = if (g != .unknown) g
             else phy.negotiatedFromPar(snap.anar, snap.anlpar);
```

`negotiatedFromPar` 就是**取交集**，并按“100FD > 100HD > 10FD > 10HD”
从高到低选。这个顺序不是随便定的：802.3 的优先级解析就是按能力位从高到低。

协商结果决定 MAC 侧三个位（`src/emac.zig` 的 `initMacConfig`）：

| 速率  | `PS`(bit15) | `FES`(bit14) | `DM`(bit11) |
| ----- | ----------- | ------------ | ----------- |
| 1000M | 0           | 0            | 1           |
| 100M  | 1           | 1            | 1           |
| 10M   | 1           | 0            | 1           |

这三位的语义在 `emac_mac_struct.h` 的 `gmacconfig` 位域里写得很清楚：
`mii` = 1 表示 10/100，`fespeed` = 1 表示 100M，`duplex` = 1 是全双工。
`emac_ll_set_port_speed()` 的实现就是这两行（`emac_ll.h:...`）：
10/100 时 `mii = 1; fespeed = speed`，1000 时 `mii = 0`。

**待真机验证**：PHY 自协商完成后 MAC 侧必须跟一次（IDF 是在 link up 回调里
重新 `emac_hal_set_speed`）。本工程在 `mac:` 阶段按协商结果配一次；
如果真机上出现“PHY 协商 1000M 但收不到包”，第一个要查的就是这里。

### 125 MHz TXC 从哪来

RGMII 的 TXC 由 SoC 产生。S31 的做法是：CNNT 的 ref clock 发生器
（源可选 MPLL/CPLL/APLL）分频后送到 pad：

```text
HP_EMAC_REF_CTRL (CNNT+0x40)
  [1:0]   REF_CLK_SEL     0 = MPLL 500MHz，1 = CPLL 300MHz（cnnt_sys_reg.h 注释）
  bit2    REF_CLK_EN
  bit3    REF_50M_PAD_OUT_CLK_EN   （PHY 需要 50 MHz 参考时的另一条路）
  [15:8]  REF_CLK_DIV_NUM
```

分频值的算法在 IDF 里（`esp_eth_mac_esp.c:255-270`）：

```c
if (set_freq_hz > out_freq_hz) div = set_freq_hz / out_freq_hz;
emac_hal_ref_clock_div(&emac->hal, div - 1);
```

即**寄存器值 = 源频率 / 125 MHz - 1**。工程按 MPLL 500 MHz 算：

```zig
pub const rgmii_ref_src_mpll: u32 = 0;
pub const rgmii_ref_div: u32 = 3;      // 500/125 - 1
```

**待真机验证**：这条链有两个外部前提——MPLL 的默认频率确实是 500 MHz
（取决于 bootloader 配的时钟树），以及 pad 输出使能（`RMII_CTRL` bit2
`PAD_OUT_CLK_EN`）确实把时钟送到了 GPIO13。判据只有一条：示波器上
GPIO13 应该是 125 MHz、占空比接近 50%。没有这一步，后面所有的收包
现象都无法归因。

---

## 17.7 DMA 描述符环与 OWN 位

S31 支持两种描述符格式：普通 4 字（16 B）与**增强 8 字（32 B）**。
IDF 统一用增强格式（`emac_ll_enhance_desc_enable(true)` → `BUSMODE.ATDS`
bit7），所以 `EMAC_HAL_DMA_DESC_SIZE = 32`（`emac_hal.h:33`）。

一个字一个字看（`emac_hal.h:56-109` / `:116-187`）：

```text
TX 描述符（32 B）                    RX 描述符（32 B）
+0   TDES0  状态/控制/OWN            +0   RDES0  状态/帧长/OWN
+4   TDES1  Buffer1Size[12:0] …      +4   RDES1  Buffer1Size/链式/环尾/DIC
+8   Buffer1Addr                     +8   Buffer1Addr
+12  Buffer2 / NextDescAddr          +12  Buffer2 / NextDescAddr
+16  Reserved1                       +16  扩展状态（IP/PTP/VLAN）
+20  Reserved2                       +20  Reserved
+24  TimeStampLow                    +24  TimeStampLow
+28  TimeStampHigh                   +28  TimeStampHigh
```

关键位（两张表都从 `emac_hal.h` 的位域定义抄，与 `gmac_reg.h` 的 TDES/RDES
定义一致）：

| 描述符 | 位                    | 含义                                       |
| ------ | --------------------- | ------------------------------------------ |
| TDES0  | bit31 OWN             | 1 = DMA 拥有                               |
| TDES0  | bit28 FS / bit29 LS   | 首段/末段（单缓冲时分段为 0 错误）         |
| TDES0  | bit20 TCH             | 第二个地址是“下一个描述符”而不是第二块缓冲 |
| TDES0  | bit21 TER             | 环尾                                       |
| TDES0  | bit30 IC              | 完成时置中断                               |
| TDES0  | bit15 ES              | 错误汇总（读这个比逐个看错误位快）         |
| RDES0  | bit31 OWN             | 1 = DMA 拥有                               |
| RDES0  | bit9 FS / bit8 LS     | 首/末描述符                                |
| RDES0  | [29:16] FL            | 帧长（**含 FCS**：本章 `APCS = 0`，见下）  |
| RDES0  | bit15 ES              | 错误汇总                                   |
| RDES1  | bit14 RCH / bit15 RER | 链式 / 环尾                                |
| RDES1  | bit31 DIC             | 置 1 = 这一帧不收完不置 RI（轮询模型用它） |

### 唯一的同步点

OWN 位是 CPU 与 DMA 之间**唯一**的握手信号。围绕它只有两条规则：

1. **CPU → DMA**：先写完 `des1`/`buffer1`/`next`，`fence rw, rw`，
   再写含 `OWN=1` 的 `des0`。这一次写是“交权”的唯一动作。
2. **DMA → CPU**：读 `des0` 发现 `OWN == 0` 才算收到，之后描述符里的
   其它字段（尤其是 RDES0 的帧长与错误位）才有效。

工程里两处代码都写成了“先 fence 再写 OWN”，并在注释里标了原因：

```zig
tx_ring[i].des1 = descs.txDes1(len);
tx_ring[i].buffer1 = addrOf(&tx_buf[0]);
hw.fence();                                    // 缓冲与字段先可见
tx_ring[i].des0 = descs.txDes0(end_of_ring);   // 这一次写 = 交权
hw.fence();
```

```zig
rx_ring[i].des0 = 0;            // 清状态位，CPU 收回
hw.fence();
rx_ring[i].des0 = descs.rdes0.own;  // 重新交给 DMA
hw.fence();
```

`fence rw, rw` 在 Zig 0.17 里没有内建指令（`@fence` 已删除），只能内联汇编
（`src/hw.zig`）：

```zig
pub inline fn fence() void {
    asm volatile ("fence rw, rw" ::: .{});
}
```

### cache 维护：S31 是空操作，P4 不是

这是本章最容易被抄错的一段。IDF 的 `eth_dma_tx_descriptor_t` 在 P4 上会
多出一个 `CacheAlign[]` 尾巴，把描述符撑到 64 字节（`emac_hal.h:29-31` 的 P4 分支 + `:106-108` 的 `CacheAlign[]`），
因为它用了 L1 D-cache。S31 的 `soc_caps.h` 里**没有**
`SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE`，内部 SRAM 不经 D-cache，
所以描述符只需要内存序，不需要 cache 操作。

| 目标                | 描述符大小         | 交权前                           | 收包后                            |
| ------------------- | ------------------ | -------------------------------- | --------------------------------- |
| S31                 | 32 B               | `fence rw, rw`                   | `fence rw, rw`                    |
| P4（有 L1 D-cache） | 64 B（含对齐填充） | `Cache_WriteBack_Addr` + `fence` | `Cache_Invalidate_Addr` + `fence` |

写成表格而不是“总之记得维护 cache”，是因为**把空操作和真操作混在一起
讲**是以太网驱动最常见的错误来源：在 S31 上加了 cache 操作会编译失败
（函数不存在）；在 P4 上漏了会表现为“描述符内容看起来没变”。

### 环长与缓冲

工程用 2 个 TX 描述符 + 4 个 RX 描述符，每个 RX 挂 1536 B 缓冲：

```zig
pub const tx_ring_len: usize = 2;
pub const rx_ring_len: usize = 4;
pub const rx_buf_size: usize = 1536;
pub var rx_ring: [rx_ring_len]descs.RxDesc align(descs.desc_align) = undefined;
pub var rx_bufs: [rx_ring_len][rx_buf_size]u8 align(16) = undefined;
```

`align(32)` 不只是好看：硬件要求描述符至少 8 字节对齐
（`EMAC_LL_DMA_MEM_ALIGNMENT = 8`，`emac_ll.h:95`），而 32 字节对齐顺带
满足了将来换到有 cache 的目标时的 cache line 粒度。

> `= undefined` 在这里是**安全的**：这些数组在 `.bss` 里，`_start` 会清零。
> 但这条安全依赖于链接脚本的 `_bss_start`/`_bss_end` 正确——ch15 的自检
> 就是在验证这件事。本章沿用同一个链接脚本，没有再重复实现自检。

---

## 17.8 中断 vs 轮询：两条可替换的路径

本章全程轮询：

```text
DMA.INTRENABLE = 0
MAC.INTMASK    = 0xFFFFFFFF   （INTMASK 是 1 = 屏蔽）
MIE = 0
```

轮询的好处是**没有并发**：`txFrame`/`rxPoll` 之间不会插入任何东西，
OWN 位的读写不需要临界区。对“先证明硬件能收发”这个目标，这是最低风险的选择。

中断路径需要三件事，这里作为对照写清楚（本章不启用）：

1. **DMA 侧**：`INTRENABLE` 置 `RI(bit6) | NIS(bit16)`，`OPMODE` 不动；
   描述符的 `RDES1[31]`（DIC）要清 0，否则收完不置 RI。
2. **MAC 侧**：`INTMASK` 清掉不关心的位（它默认全屏蔽）。
3. **中断矩阵**：EMAC 的中断源号是 **98**（`ETS_SBD_INTR_SOURCE`，
   `interrupts.h` 的枚举第 99 项；同文件用
   `#define ETS_ETH_MAC_INTR_SOURCE ETS_SBD_INTR_SOURCE` 给了兼容别名）。
   矩阵寄存器 `INTERRUPT_CORE0_SBD_INTR_MAP_REG = 0x20585000 + 0x188`
   （`interrupt_core0_reg.h:2071`），`MAP[5:0]` 写 **CLIC 输入号**（16..47，
   见 ch07 的结论），`PASS_LEVEL[9:8]` 一般不填。

```text
源 98 (SBD/EMAC) --matrix[98] = 0x20585188--> CLIC 输入 16..47
```

对比一下代价：

| 维度     | 轮询（本章）                | 中断                                |
| -------- | --------------------------- | ----------------------------------- |
| CPU 占用 | RX 空闲时白跑循环           | 空闲时不占                          |
| 并发风险 | 无                          | ISR 与主循环竞争描述符 → 需要临界区 |
| 调试难度 | 低（单线程）                | 高（要能打印 ISR 现场）             |
| 适用场景 | 一次性诊断、bare-metal 验证 | 持续吞吐                            |

ch12 的关中断/自旋锁、ch07 的 CLIC 路由在这里会重新汇合：一旦开中断，
`rxPoll` 里“读 OWN → 处理 → 重挂 OWN”这三步就必须是原子的。

---

## 17.9 从描述符到 netif：四次交接

本章**没有** netif（那是 ch16 的抽象、ch18 的用法）。但收包路径必须在这里
说清楚，否则下一章接协议栈时会发现“接口对不上”。一帧从线缆到协议栈要过四次
交接，其中只有最后一次有设计自由度：

```text
[1] PHY → MAC      RGMII DDR 采样；CRC 由 MAC 校验，但**不剥离**（APCS=0）
[2] MAC → DMA      MAC 把帧写进 MTL FIFO，DMA 按 RX 描述符写 SRAM
[3] DMA → CPU      OWN 从 1 变 0；CPU 读 RDES0 拿长度与错误位
[4] CPU → 协议栈    把 (buffer 指针, 长度, 时间戳) 交给上层，然后立即重挂 OWN
```

第 [4] 步是唯一有设计自由度的地方，三种做法：

| 做法                                  | 副本        | 代价                   | 适用                        |
| ------------------------------------- | ----------- | ---------------------- | --------------------------- |
| 拷进自己的缓冲再重挂                  | 1 次 memcpy | 简单，缓存友好         | 本章的诊断路径              |
| 把 buffer 交给上层，重挂一个新 buffer | 0 次        | 需要 buffer 池         | 零拷贝（ch16 的 pbuf 思路） |
| 半环滚动（描述符数 = 2N）             | 0 次        | 需要“已消费到哪”的水位 | 高吞吐                      |

本章的 `rxPoll` 用第一种：先 `@memcpy` 前 64 字节到 `RxFrame.head`
（打印够用），然后**立刻**重挂 OWN。这样做的好处是——即使上层卡住，
RX 环也不会因为“描述符耗尽”而丢包；坏处是每帧多一次拷贝。

净荷长度来自 RDES0 的 `FL[29:16]`。**这里的 4 字节 FCS 没有剥离**：
IDF 的默认配置是 `emac_ll_auto_pad_crc_strip_enable(false)`，即
`MACCR.APCS = 0`，“MAC 把收到的帧原样交给软件”。所以：

```text
FL = 14（以太头）+ IP_total_length + 4（FCS）      （无 VLAN）
```

这个 +4 是接 18 章时最容易漏的一处：如果按 `FL - 14` 当 IP 长度去校验，
IPv4 的 `total_length` 永远比它小 4，校验和/分片判断会全错。
两种做法都可以，但必须明确选一种：

| 选择             | `APCS` | FL 含 FCS | 上层怎么算                              |
| ---------------- | ------ | --------- | --------------------------------------- |
| 本章（IDF 默认） | 0      | 是        | 减 4，或让 IP 层信自己的 `total_length` |
| 让 MAC 剥 FCS    | 1      | 否        | `FL - 14` 直接就是 IP 报文长度          |

---

## 17.10 工程结构与判读顺序

工程是形态 B（Zig 产 ELF + IDF 只提供二级 bootloader/分区表），
文件职责表在 `practice/zig-esp32-s31/ch17-ethernet-mac-phy-driver/README.md`。
这里只强调三件事：

站内代码浏览（不离开站点看高亮源码）：

| 文件                 | 代码浏览                                                                             |
| -------------------- | ------------------------------------------------------------------------------------ |
| `build.zig`          | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/build.zig)          |
| `linker/s31.ld`      | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/linker/s31.ld)      |
| `src/regs.zig`       | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/regs.zig)       |
| `src/emac.zig`       | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/emac.zig)       |
| `src/phy.zig`        | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/phy.zig)        |
| `src/descs.zig`      | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/descs.zig)      |
| `src/pins.zig`       | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/pins.zig)       |
| `src/host_tests.zig` | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/host_tests.zig) |
| `src/main.zig`       | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/main.zig)       |
| `src/start.zig`      | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/src/start.zig)      |
| `tools/flash.sh`     | [查看](/static/code/#/zig-esp32-s31/ch17-ethernet-mac-phy-driver/tools/flash.sh)     |

**第一，`src/regs.zig` 是唯一的地址来源。** 所有基址、偏移、位域都只在这个
文件里出现一次；`emac.zig` 只做 `hw.readReg(regs.gmac + regs.mac.config)`
这种拼接。这样“某个地址写错了”只需要改一个地方，而且可以用 grep 对回
`事实来源`表。

**第二，纯逻辑留在能被 host test 覆盖的地方。** `descs.zig`（描述符布局、
OWN 位、帧长解码）、`regs.zig`（GMII 地址编码、分频选择）、`phy.zig`
（ID 解码、自协商）、`pins.zig`（引脚表）都不碰 MMIO，20 个用例在
x86_64 上跑。它们覆盖的恰好是“上板后最难调”的部分。

**第三，串口输出的前缀就是判读顺序。** 上板后按这个顺序看：

| 顺序 | 前缀    | 判据                                                 | 不对时先怀疑               |
| ---- | ------- | ---------------------------------------------------- | -------------------------- |
| 1    | `clk:`  | `emac_sys_clk_en=1`                                  | 门控位/基址                |
| 2    | `rst:`  | `snps=0x37`                                          | 复位没生效、或基址错       |
| 3    | `pin:`  | RGMII `mcu_sel=2`；输入脚 `ie=1`                     | 引脚组别、功能号           |
| 4    | `mdio:` | 扫到地址、`ident` 不是 0/0xFFFF                      | MDC/MDIO 脚号、PHY 供电    |
| 5    | `mac:`  | `te=0 re=0`（还没启动）、`ps/fes` 与协商一致         | 各速率位                   |
| 6    | `dma:`  | `swr=0`、`atds=1`                                    | 软复位超时（AXI 时钟没开） |
| 7    | `ring:` | 描述符地址在 `0x2f…`、`rx[i].des0=0x80000000`        | 链接脚本、`.bss` 未清零    |
| 8    | `tx:`   | `te=1 re=1`（TE→ST→SR→RE 生效）、`own` 被清、`err=0` | TXC 没出来、PHY 没 link    |
| 9    | `rx:`   | 有帧且 `err=0`                                       | RXC、RX_CTL、过滤位        |

`snps=0x37` 这条判据值得单独说：它是**复位是否真的生效**的证据。
如果读到 `0x00` 或 `0xFFFFFFFF`，那说明要么门控没开（读回 0），
要么基址错了/总线异常——这时候往下配 DMA 完全是浪费。

---

## 17.11 还不做的事与下一章

本章交付的是“能证明硬件活着”的最小闭环：

- ✅ MDIO 读 PHY ID（厂商/型号/版本）
- ✅ 自协商状态可读（BMSR/ANAR/ANLPAR/千兆三处）
- ✅ MAC/DMA 初始化完成，环地址与 OWN 位可打印
- ✅ 发一帧最小以太网帧（广播 + 实验性 EtherType `0x88B5`）
- ✅ 轮询 RX 环并打印帧头
- ❌ **不做 ARP/ICMP**：所以**不能 ping**
- ❌ 不做多播/哈希过滤表（`MACFF` 现在全通）
- ❌ 不做流控（pause 帧）
- ❌ 不做 PTP/时间戳（虽然描述符里有 TS 字段）

下一章（ch18）在它上面接 IPv4/ICMP/ARP：ARP 请求是 42 字节的广播帧，
正好可以用来验证“RX 环能进包”；ICMP 回显则是 `ping` 的最后一公里。
ch16 的缓冲/零拷贝抽象会在那里第一次真正被用到——本章的
“重挂 OWN 前要不要拷贝”就是那个抽象的第一个决策点。

**验收口径要说清楚**：本章的验收是「PHY ID 读通 + 一帧能发 + 一帧能收」；
「ping 通」是 18 章的验收。把这两件事混在一起，是这类章节最常见的
过度承诺。

---

## 17.12 本章的“不能写”清单

写硬件章节最容易犯的错，是把“应该”写成“实测”。本章刻意保留了四类
未验证结论，并给出各自的判据，而不是给一个漂亮的结果：

| 未验证项                   | 为什么不能写结论 | 判据                                       |
| -------------------------- | ---------------- | ------------------------------------------ |
| MDIO 能否扫到 PHY          | 没上板           | `mdio:` 行有非 0/非 0xFFFF 的地址          |
| RGMII 组别与 MDC/MDIO 脚号 | 没看本板原理图   | PHY ID 能读到，且与原理图上的 PHY 型号一致 |
| TXC 是否 125 MHz           | 没接示波器       | GPIO13 上 125 MHz、占空比 ≈50%             |
| 描述符环是否真跑起来       | 没上板           | `tx:` 的 `own` 被清、`err=0`；`rx:` 能进帧 |

反过来说，本章**可以**写下结论的部分都来自可查的源码与可算的算术：

- 寄存器基址/偏移/位号 → `事实来源`表的路径与行号；
- 描述符 32 字节与字段顺序 → `emac_hal.h` 的 `ASSERT_TYPE_SIZE`；
- MDC ≤ 2.5 MHz → 除数表与 IEEE 上限，两边都能算；
- 125 MHz 分频值 = 500/125 - 1 → IDF 的 `div - 1` 算法。

这条界线不是谨慎，而是**证据链必须可追溯**：读者要能自己重算一遍，
而不是相信作者跑过一次。

---

## 事实来源

本章所有寄存器地址、位号与初始化顺序都来自本地 ESP-IDF v6.1 的 esp32s31 源码，
下表逐条给出路径（相对 `~/esp/esp-idf/`）：

| #   | 事实                                                                                                         | 路径与位置                                                                                                                                                      |
| --- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | GMAC 基址 `0x20350000`                                                                                       | `components/soc/esp32s31/register/soc/reg_base.h:16`                                                                                                            |
| 2   | MAC 块偏移（`MACCONFIG +0x0` … `MACADDRESS0LOW +0x44`）                                                      | `components/soc/esp32s31/register/soc/gmac_reg.h:16/337/533/609/623/1161/1287/1349/1370`                                                                        |
| 3   | DMA 块偏移（`BUSMODE +0x1000` … `HWFEATURE +0x1058`）                                                        | `components/soc/esp32s31/register/soc/gmac_reg.h:3351/3591/3606/3622/3886/4152/4535/4547/4583`                                                                  |
| 4   | MACCR 位号（`RE bit2`、`TE bit3`、`DM bit11`、`FES bit14`、`PS bit15`、`APCS bit7`、`JD bit22`、`WD bit23`） | `components/soc/esp32s31/register/soc/gmac_reg.h`（0x0 寄存器段的 `GMAC_xx` 宏）与 `emac_mac_struct.h` 的 `gmacconfig` 位域                                     |
| 5   | MACFF 位号（`PROMISCUOUS bit0`、`DBF bit5`、`RA bit31`）                                                     | `components/soc/esp32s31/register/soc/gmac_reg.h:337-505`                                                                                                       |
| 6   | GMII 地址寄存器位域（busy0/write1/csr[5:2]/reg[10:6]/dev[15:11]）                                            | `components/soc/esp32s31/register/soc/emac_mac_struct.h:81-93`                                                                                                  |
| 7   | DMA 操作模式位号（`SR bit1`、`ST bit13`、`FTF bit20`、`RSF bit25`）                                          | `components/soc/esp32s31/register/soc/gmac_reg.h:3886-4150`                                                                                                     |
| 8   | DMA 总线模式位号（`SWR bit0`、`DSL[6:2]`、`ATDS bit7`、`PBL[13:8]`、`AAL bit25`、`MB bit26`）                | `components/soc/esp32s31/register/soc/gmac_reg.h:3351-3560`                                                                                                     |
| 9   | 描述符 32 字节、TDES0/RDES0 位定义                                                                           | `components/esp_hal_emac/include/hal/emac_hal.h:33`（`EMAC_HAL_DMA_DESC_SIZE`）、`:56-109`（TX 描述符）、`:116-187`（RX 描述符），含 `ASSERT_TYPE_SIZE`         |
| 10  | 描述符最小对齐 8、PBL 不能取 32                                                                              | `components/esp_hal_emac/esp32s31/include/hal/emac_ll.h:95`（`EMAC_LL_DMA_MEM_ALIGNMENT`）与同文件 `:86` 的 "burst length 32 is intentionally NOT defined" 注释 |
| 11  | RGMII 时钟/接口选择（`PHY_INTF_SEL=1`、`180_CLK_EN`）                                                        | `components/esp_hal_emac/esp32s31/include/hal/emac_ll.h:1030-1059`（`emac_ll_clock_enable_rgmii`）                                                              |
| 12  | 总线时钟与寄存器复位                                                                                         | `components/esp_hal_emac/esp32s31/include/hal/emac_ll.h:867-905`；`emac_clk` 用 `HP_SYS_CLKRST.EMAC_CTRL0`（`hp_sys_clkrst_reg.h:2194-2201`，偏移 `+0xc8`）     |
| 13  | CNNT 域寄存器偏移与字段                                                                                      | `components/soc/esp32s31/register/soc/cnnt_sys_reg.h:138/338/364/397/416/449/482/558`（注意文件里的 `DR_REG_CNNT_BASE` 未定义，实际基址见 `reg_base.h:21`）     |
| 14  | MDC 分频表 `{42,62,16,26,102,124}` 与 MDC 判据                                                               | `components/esp_hal_emac/emac_hal.c:17-24`（`emac_crs_div_table`）、同文件 `79-110`（`find_set_closest_csr_clock_range` / `set_csr_clock_range`）               |
| 15  | MAC/DMA 默认配置的逐条顺序                                                                                   | `components/esp_hal_emac/emac_hal.c:111-238`（`init_mac_default` / `init_dma_default`）                                                                         |
| 16  | 初始化顺序（先开时钟、再复位、后 HAL）与 RGMII 启动序列                                                      | `components/esp_eth/src/mac/esp_eth_mac_esp.c:1186-1188`、同文件 `1000-1045`                                                                                    |
| 17  | ref clock 分频算法（`div = src/out - 1`）与 125 MHz                                                          | `components/esp_eth/src/mac/esp_eth_mac_esp.c:49`、`255-270`                                                                                                    |
| 18  | RGMII 引脚表（GPIO8-19 / 36-47）与功能号                                                                     | `components/esp_hal_emac/esp32s31/emac_periph.c:200-360`；`components/soc/esp32s31/register/soc/io_mux_reg.h:188-264`                                           |
| 19  | IO_MUX 字段（`MCU_SEL[14:12]`、`FUN_IE bit9`、`FUN_DRV[11:10]`）                                             | `components/soc/esp32s31/register/soc/io_mux_reg.h:40-70`                                                                                                       |
| 20  | GPIO 矩阵字段（输出按脚索引 / 输入按信号索引）                                                               | `components/soc/esp32s31/register/soc/gpio_struct.h:972-1022`；`gpio_reg.h` 的 `GPIO_FUNC0_OUT_SEL_CFG_REG +0xaf4` / `GPIO_FUNC0_IN_SEL_CFG_REG +0x2f4`         |
| 21  | EMAC 信号号（MDI 107 / MDC 108 / MDO 109）                                                                   | `components/soc/esp32s31/include/soc/gpio_sig_map.h:226-231`                                                                                                    |
| 22  | EMAC 能力（千兆、多 IO_MUX、GPIO 矩阵、无 L1 cache 直连内部 SRAM）                                           | `components/soc/esp32s31/include/soc/soc_caps.h:113-122` 与 `170-172`（CACHE CAPS 段无 `SOC_CACHE_INTERNAL_MEM_VIA_L1CACHE`）                                   |
| 23  | EMAC 中断源 = 98（`ETS_SBD_INTR_SOURCE`）、别名 `ETS_ETH_MAC_INTR_SOURCE`                                    | `components/soc/esp32s31/include/soc/interrupts.h:117`、`:196-197`                                                                                              |
| 24  | 中断矩阵寄存器 `SBD_INTR_MAP = base + 0x188`，`MAP[5:0]`                                                     | `components/soc/esp32s31/register/soc/interrupt_core0_reg.h:2071-2080`                                                                                          |
| 25  | EMAC 时钟源可选 MPLL/CPLL/APLL、PTP 源                                                                       | `components/soc/esp32s31/include/soc/clk_tree_defs.h:762-795`                                                                                                   |
| 26  | IEEE 802.3 第 22 条：MDC ≤ 2.5 MHz、BMCR/BMSR/PHYID/ANAR/ANLPAR 的位定义                                     | IEEE Std 802.3-2018 Clause 22（公开规范）                                                                                                                       |

---

## 自查清单

上板前（静态）：

- [ ] `zig build -Dtarget=riscv32-freestanding-eabihf -Dcpu=generic_rv32+m+a+c+f+zicsr+zifencei -Doptimize=ReleaseSmall` 退出 0
- [ ] `elf2image` 打印 `Merged 2 ELF sections.`
- [ ] `image-info` 的段表里 `DROM, IROM` 行数 **正好 2**（不是“总段数 == 2”）
- [ ] `zig build test` 全绿（20 个用例）
- [ ] `bash -n tools/flash.sh` 退出 0
- [ ] `git status --short` 只有本章新建的路径

上板后（按阶段，逐条打勾才叫“跑通”）：

- [ ] `clk: emac_sys_clk_en=1`
- [ ] `rst: mac_version=0x…37`（`snps=0x37`）
- [ ] `pin:` RGMII 脚的 `mcu_sel=2`，输入脚 `ie=1`，输出脚 `ie=0`
- [ ] `pin:` MDC/MDIO 的 `out_sel`/`in_sel` 与实际脚号一致
- [ ] `mdio:` 扫到 PHY，`ident` 既不是 `0x00000000` 也不是 `0xFFFFFFFF`
- [ ] `mdio: vendor=` 与原理图上的 PHY 厂商一致
- [ ] `mdio: link=1`（插网线）、`negotiated=1000M full`（或与交换机一致）
- [ ] `mac:` 的 `te=0 re=0`（尚未启动）与 `ps/fes` 与协商速率一致
- [ ] `tx:` 里 `start order TE->ST->SR->RE done: te=1 re=1`
- [ ] `dma: swr=0`、`atds=1`、`pbl=16`
- [ ] `ring:` 描述符地址落在 `0x2f…`（SRAM），`rx[i].des0=0x80000000`
- [ ] `tx:` `own` 被清、`err=0`、`status` 里 `TI(bit0)` 置起
- [ ] `rx:` 至少收到一帧（ARP/LLDP/广播），`err=0`
- [ ] 示波器：GPIO13（TXC）125 MHz、占空比 ≈50%
- [ ] 换一根网线/换一个对端重跑一次，结论不变

失败时的第一反应（按顺序排查，不要跳步）：

1. `snps` 不对 → 停下来查基址与门控，**不要**继续配 DMA；
2. `mdio` 读回 0xFFFF/0x0000 → 查脚号、`OEN_SEL`、PHY 供电；
3. `own` 一直不清 → 查 TXC/RXC 有没有时钟、`OPMODE.ST/SR` 是否置起；
4. 能发不能收 → 查 `MACFF`（`DBF` 是否误置 1 丢掉广播）、`RX_CTL` 引脚。

---

本章的交付物是“可判读”：每一行串口输出都对应一个寄存器与一条判据，
每一个尚未验证的结论都标了「待真机验证」。以太网真正的难点不在于把帧搬进来，
而在于**能证明自己搬对了**——下一章就站在这个可判读的地基上做 ARP 与 ICMP。

系列导航：[[ch16-stack-architecture-zero-copy|上一章]] · [[zig-esp32-s31|系列索引]]
