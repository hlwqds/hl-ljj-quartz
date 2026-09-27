---
title: F429 动手连线手册：把系列里的物理实验串成一条实操线
date: 2026-09-23 10:30:00
description: f429-lab / embedded-basics / rpi-lab 三条线全部物理实操知识的汇总手册——铁律、基础设施、逐实验接线表、仪器速查、真机占位清单与实操顺序，每条事实 wikilink 回源章节
tags: [f429-lab, embedded-basics, rpi-lab, STM32, wiring, 手册]
---

# F429 动手连线手册：把系列里的物理实验串成一条实操线

> **这本手册怎么用**：把散落在系列各章里的物理实操知识（接线、跳线、仪器、安全规约）汇总成一张可执行的实操地图——**每一行都 wikilink 回源章节**，章节自己标注的状态（✅ 实测 / 先成文后实跑 / 待核对）原样保留，本手册不新增任何板上事实，查不到的一律继承源章节的「待核对」标注。
>
> **两条学习线，接线不可混用**：主线是 [[f429-lab|F429 裸机实验室]]（野火挑战者 STM32F429-V2 板）；平行线是 [[embedded-basics|嵌入式硬件基础]]（WeAct STM32F407VET6 + GD32VF103，无板先行）。两块板的引脚、跳线、板载器件完全不同，**A 线的接线表不能抄到 B 线上**——每张表都标了属于哪条线。
>
> 状态全景：序章 ch00a–d 与 ch01 清单已真机实测；ch02 起全部「先成文、后实跑」，本文把这些章节的接线准备做成了「零件到货就能动手」的清单。

## 1 动手前必读：五条铁律

全系列反复出现的规约，来源都在括号里，此处只汇总不展开。

| #   | 铁律                                                                                                                                              | 出处                                                                                                                      |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| 1   | **共地先行**：任何跨板信号线连接前，先把两板 GND 相连；不共地的「信号」是天线不是数据。拆线反向、最后拆 GND                                       | [[ch01-bookworm-surgery-baseline\|rpi-lab ch01]]                                                                          |
| 2   | **3.3V 电平域红线**：BCM2711 GPIO 无一 5V 容忍；3.3V TTL 引脚接 RS-232 的 ±12V 立即损坏，FT 引脚也救不了；调试器 VTref 只接 3V3「只看不喝」       | [[ch06-uart-protocol\|basics ch06]]、[[2026-08-30-electronics-first-principles-from-gnd-to-signal\|电学第一性原理]]       |
| 3   | **断电接线 → 逐根复查 → 认丝印不认脚号**；跳线帽改完必须断电重新上电才生效（BOOT 脚只在复位瞬间被采样）                                           | [[ch00a-swd-debug-port\|ch00a]]、[[2026-08-30-stm32f429-clock-misconfig-postmortem\|时钟故障复盘]]                        |
| 4   | **仪器三查**：共地通不通、3.3V 有没有、断线在哪；万用表蜂鸣档/电阻档必须断电测量                                                                  | [[ch08-instrument-roles-guide\|rpi-lab ch08]]、[[ch02-tools-multimeter-la\|basics ch02]]                                  |
| 5   | **电源纪律**：挑战者板 USB 与 DC 一次只插一个（防灌电流）；两块板的 3.3V 电源各回各家、永不并联；逻辑分析仪只做旁观者（高阻输入，不串进功率路径） | [[2026-08-30-electronics-first-principles-from-gnd-to-signal\|电学第一性原理]]、[[ch02-tools-multimeter-la\|basics ch02]] |

## 2 阶段 0：一次搭好的基础设施

这三样搭好后，全系列每章的「动手部分」都从它们出发。搭好后终身受用，坏了也按此修复。

### 2.1 烧录调试链（野火 DAP ↔ 挑战者调试座）

**主方式**：2×10 防呆排线，缺口对缺口物理唯一插不反——20 触点 = 1 根 VREF + 9 根 GND（偶数排 4~20 全是地，「信号夹地」标准做法）+ JTAG/SWD 信号 + nSRST + VCC + 两个保留位（fireDAP 上被野火挪作 V-UART 串口扩展，精确脚位待核对）。

**备方式（杜邦手动五线，理解协议用）**——✅ 2026-08-30 实测一次点亮：

| DAP 侧 | 板侧          | 用途                             |
| ------ | ------------- | -------------------------------- |
| SWDIO  | SWDIO（PA13） | 数据                             |
| SWCLK  | SWCLK（PA14） | 时钟                             |
| GND    | GND           | 共地，必须                       |
| VTref  | 3V3           | 电平参考，多数 DAP 必须接        |
| nRESET | NRST          | 建议接；不接则 halt 后要手按复位 |

JTAG 六线版本（TCK→PA14、TMS→PA13、TDI→PA15、TDO←PB3、可选 TRST→PB4）与双协议切换实验见 [[ch00b-jtag-debug-port|ch00b]]，全系列默认走 JTAG（`openocd.cfg`），SWD 用 `openocd-swd.cfg`。连接不起先查：`lsusb | grep -i dap`、换主板直插 USB 口（拓展坞供电不足是常见暗坑）、`adapter speed 500` 救急。

### 2.2 控制台串口（全系列统一）

```text
USART1 PA9(TX)/PA10(RX) ↔ 板载 CH340 ↔ Mini-USB ↔ /dev/ttyUSB0 @115200 8N1
```

前置：**J80/J81 跳帽在位**；重上电后 `/dev/ttyUSB0` 权限会丢，`sudo setfacl -m u:$USER:rw /dev/ttyUSB0`。规范源头：[[2026-08-30-stm32f429-clock-misconfig-postmortem|时钟故障复盘]] 与 practice/f429-lab/SPEC.md。

### 2.3 救砖预案（3 分钟，先学会再动手）

固件烧坏调试口失联时的标准恢复路：**J64 跳线帽移到 3V3–BOOT0 → 断电重新上电（BOOT 只在复位瞬间采样）→ `python3 -m stm32loader -p /dev/ttyUSB0 -b 115200 -e` 全片擦除 → 帽回 GND 重烧**。J64 在板左侧中部跳线簇（Mini-USB 和 CH340 上方），丝印 `3V3/BOOT0/BOOT1`，官方文档无记载——完整流程见 [[2026-08-30-stm32f429-clock-misconfig-postmortem|时钟故障复盘]]。

## 3 跳线帽地图与互斥表（挑战者 F429）

| 跳线    | 作用                                             | 状态    | 场景                                            |
| ------- | ------------------------------------------------ | ------- | ----------------------------------------------- |
| J64     | BOOT0/BOOT1 选择（丝印 3V3/BOOT0/BOOT1）         | ✅ 实测 | 救砖（§2.3）                                    |
| J80/J81 | USART1 ↔ CH340 接通                              | ✅ 在用 | 所有串口实验的前置                              |
| J77     | 板载电位器 → PC3 选通（不盖则 PC3 悬空漂移）     | 待实跑  | ch04/ch11 ADC 实验前置                          |
| J73     | 与板载 LED 相关（细节待核对）                    | 待核对  | [[ch01-systick-heartbeat\|ch01]] LED 不闪先查它 |
| J78     | 触摸按键（曾与 SPI1 PA5 候选冲突，已随勘误解除） | 待核对  | [[ch07-spi-flash-w25q64\|ch07]]                 |

互斥三条（[[f429-lab|系列索引]] 声明）：CAN ↔ 屏幕不能同用；485 ↔ 液晶共用 PB8；ADC 旋钮实验先盖 J77。

## 4 板载外设实验（零外部接线，上电即做）

| 实验                    | 板载器件与关键事实                                                                                                              | 状态          | 源章节                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------- | --------------------------------------------------------------------- |
| SysTick 心跳 + LED      | LED = **PH10**（RGB 红，共阳低电平点亮）；`mdw 0xE000E010 3` 活体读；串口时间戳对表测晶振 +40.9ppm（65 秒精测）                 | ✅ 清单已核销 | [[ch01-systick-heartbeat\|ch01]]                                      |
| 按键轮询→EXTI 中断→消抖 | KEY1 候选 PA0 / KEY2 候选 PC13、低有效+内部上拉——**均为野火教程常见值，本板待核对**；万用表量按键两端电平核对                   | ✍️ 先成文     | [[ch02-button-polling-to-interrupt\|ch02]]                            |
| 定时器 PWM 蜂鸣器唱歌   | 蜂鸣器 = **PI11**，置高即响（有源/无源待核对）；手机调音器 App 对音；听感判据验收                                               | ✍️ 先成文     | [[ch03-timer-pwm-buzzer\|ch03]]                                       |
| ADC 第一眼 + DMA 双缓冲 | **先盖 J77**，旋电位器看串口 0–4095 / ASCII 示波器；万用表量 PC3 反推 VREF+（代码按 3.3V 占位，实际值待核对）                   | ✍️ 先成文     | [[ch04-adc-first-analog\|ch04]]、[[ch11-adc-dma-double-buffer\|ch11]] |
| SPI Flash 全流程        | **勘误后定论：W25Q256（32MB）@ SPI5，SCK=PF7/MISO=PF8/MOSI=PF9/CS=PF6（软件 GPIO），模式 3，JEDEC 预期 EF 40 19**；丝印终验待做 | ✍️ 先成文     | [[ch07-spi-flash-w25q64\|ch07]]                                       |
| RTOS 系列（ch12–ch19）  | 无新接线——DAP 硬件断点+单步是主角：`bp <地址> 2 hw` 冻结现场、`mdw` 裸读栈区 0xA5 海岸线、逐条走 PendSV                         | ✍️ 先成文     | [[ch17-pendsv-single-step\|ch17]] 为代表                              |

ch12–ch19 的共同仪器姿势：openocd **活体读**（跑着读不 halt）验 DMA/DWT 在转；断点地址每次重新构建后用 `arm-none-eabi-nm` 重查（地址会挪）；F429 有 6 个 FPB 硬件断点；`reg basepri` 必须 halt 态才读得到。

## 5 跨板实验（树莓派 4B 登场）

RPi 在本系列固定扮演三个角色：I2C 主机（ch08）、逻辑分析仪（ch09）、网络对端（ch20–22）。跨板接线全部遵守 §1 铁律 1/2。

### 5.1 I2C 双板（RPi 主 ↔ F429 从）

| RPi 物理脚            | F429 侧              | 用途                               |
| --------------------- | -------------------- | ---------------------------------- |
| 物理 3（GPIO2, SDA1） | PB7（I2C1_SDA, AF4） | SDA；RPi 侧板载 1.8kΩ 上拉（焊死） |
| 物理 5（GPIO3, SCL1） | PB6（I2C1_SCL, AF4） | SCL；同上                          |
| 物理 6（GND）         | 任意 GND             | 共地，第一根线                     |

两板均 3.3V 域可直连。流程：`raspi-config nonint do_i2c 0`（0 是开启）→ 接线前先 `i2cdetect -y 1` 空扫留底 → 扫到 0x2A → `i2cget/i2cset` 闭环。PB6/PB7 在挑战者黑排针的实际引出位置**待核对**。源：[[ch08-i2c-dual-board-rpi-master|ch08]]。

### 5.2 piscope 探针（两张接线表并存，实跑前需统一）

系列里有两张 piscope 探针表，通道分配不一致，如实并列：

| 信号（F429 侧） | [[ch09-rpi-piscope-logic-analyzer\|ch09]] 版 | [[ch08-instrument-roles-guide\|rpi-lab ch08]] 版 |
| --------------- | -------------------------------------------- | ------------------------------------------------ |
| SPI SCK         | GPIO17（物理 11）                            | GPIO17（物理 11）                                |
| SPI MOSI        | GPIO27（物理 13）                            | GPIO4（物理 7）                                  |
| SPI CS          | GPIO22（物理 15）                            | GPIO27（物理 13）                                |
| SPI MISO        | GPIO23（物理 16）                            | —                                                |
| UART TX（PA9）  | GPIO5（物理 29）                             | —                                                |
| GND             | 物理 6                                       | 物理 9                                           |

物理 6 和物理 9 都是 GND，电气上不冲突；通道分配不同属于两章各自成文的口径差，**实跑时统一成一张并回填两章**。共同纪律：**别用 GPIO2/3（物理 3/5）当探头**——焊死 1.8kΩ 上拉会把被测线强行拉高；避开 SPI0 的 19/21/23。能力边界算术：UART 115200（8.7 采样/位）轻松，SPI ÷256=351.6kHz 边界勉强，5.6MHz 以上出局（换 fx2lpo）。上车：`sudo pigpiod -s 1`（1µs 采样档）→ `ssh -X` 跑 piscope GUI，触发选 CS 下降沿。

### 5.3 以太网三连（ch20/ch21/ch22）

**接法只有一根线**：网线直连板 RJ45 ↔ RPi eth0——**不必飞地线**（RJ45 磁性件隔离直流地，这是与 I2C/SPI 实验的本质区别）。IP 规划：F429=10.42.0.10，RPi=10.42.0.20/24（`nmcli con add ... ipv4.addresses 10.42.0.20/24`）。

观察点与命令：

- ch20 MDIO：串口看 `phy N ID1=…`（PHY 候选 LAN8720/LAN8742，**型号/地址/REF_CLK 方案均待核对**）；插拔网线看 `link: UP/DOWN`；RMII 九脚（PA1/PA2/PC1/PA7/PC4/PC5/PG11/PG13/PG14，全 AF11）为 datasheet 标准值，**板上实际走线待核对**
- ch21 ARP/ping：RPi 侧 `sudo tcpdump -i eth0 -n -e 'arp or icmp'` 见证第一声 ARP 广播（ff:ff:ff:ff:ff:ff），再双向 ping
- ch22 打流：`iperf3 -u -b 0 -c 10.42.0.20` + `tcpdump -w` 落盘数包算丢帧率（`-b 0` 不放开就白测）；百兆线速理论天花板 94.1Mbps

源：[[ch20-ethernet-emac-phy|ch20]]、[[ch21-baremetal-lwip|ch21]]、[[ch22-esp32-vs-f429-throughput|ch22]]。配套工程深链：[eth-mdio-probe](/static/code/#/f429-lab/eth-mdio-probe/main.c)、[lwip-arp-ping](/static/code/#/f429-lab/lwip-arp-ping/main.c)。

## 6 面包板外接实验

### 6.1 主线（挑战者 F429）：分立 PLL

[[ch00e-clock-tree-and-systick-silicon|ch00e]] 文末埋的配套实验——74HC4046+74HC4040 把片内 PLL 拆成看得见的链路（参考→鉴相→RC 环路滤波→VCO→÷N 反馈），万用表看 VCOIN 锁定电压、piscope 双通道看相位对齐。完整接线表与六步实验：[pll-4046-breadboard 教程](/static/code/#/f429-lab/pll-4046-breadboard/docs/tutorial.md)、[观测指南](/static/code/#/f429-lab/pll-4046-breadboard/docs/instruments.md)。

### 6.2 平行线（WeAct F407 + GD32，[[embedded-basics|嵌入式硬件基础]]）

| 实验                | 接线（原文照抄）                                                                       | 等什么器材       | 源章节                               |
| ------------------- | -------------------------------------------------------------------------------------- | ---------------- | ------------------------------------ |
| 真机点灯+按键       | PA0 →[330Ω]→ LED（长脚接电阻侧）→ GND；PA1 → 轻触按键 → GND（内部上拉低有效）          | F407 核心板      | [[ch05-gpio-and-mco\|basics ch05]]   |
| PWM 呼吸灯          | PA6（TIM3_CH1, AF2）→[470Ω]→ LED → GND；LA 看占空比滑动、万用表读平均值 3.3V×duty      | 同上             | [[ch08-timer-systick\|basics ch08]]  |
| 双板 UART           | F407 PA9(TX) → GD32 PA10(RX)、F407 PA10(RX) ← GD32 PA9(TX)（交叉！）、GND↔GND          | 两块板或 USB-TTL | [[ch06-uart-protocol\|basics ch06]]  |
| I2C 接 BME280       | PB6→SCL、PB7→SDA、SDO→GND（地址 0x76）、3V3 供电、4.7kΩ 上拉×2（模块板载则免）         | BME280 模块      | [[ch10-i2c-spi-theory\|basics ch10]] |
| SWD 烧录（ST-Link） | SWDIO(20pin 脚7)→PA13、SWCLK(脚9)→PA14、GND(脚4)→GND、VTref(脚1)→3V3、RESET(脚15)→NRST | ST-Link V2       | [[ch11-debug-swd-jtag\|basics ch11]] |

LED 限流三例均为原文给出、数值不同皆有出处：basics ch02 体检 220Ω（≈5.9mA）/ ch05 点灯 330Ω（≈4mA）/ ch08 PWM 470Ω（≈2.8mA）。采购全套（三件套约 287 元 + 避坑注记：BMP280 冒充 BME280、Blue Pill 假片重灾区、金属壳 ST-Link 发热）见 [[ch01-roadmap-and-boards|basics ch01]]。

## 7 仪器速查

### 7.1 万用表

表笔纪律：黑表笔永远插 COM；电压/电阻/通断红笔插 VΩ；**测电流红笔换 mA/10A 孔，测完立刻拔回 VΩ**（烧表四场景之首：电流档并联电源两端）。三查套路：共地通不通（断电蜂鸣档）、3.3V 有没有（DC 档 3.25~3.35V）、断线在哪（蜂鸣档追线）。独门技巧：MIN/MAX 锁存量供电瞬间跌落；1Hz 方波直读平均值 ≈ VDD/2。源：[[ch02-tools-multimeter-la|basics ch02]]、[[2026-08-30-electronics-first-principles-from-gnd-to-signal|电学第一性原理]]。

### 7.2 逻辑分析仪（fx2lafw 24MHz / fx2lpo）

三原则：共地优先（GND 夹子先接）、输入量程红线（0~5.25V，12V/24V/母线禁止直连）、只做旁观者。安装 `sudo dnf install sigrok-cli pulseview sigrok-firmware-fx2lafw`；无设备自检 `sigrok-cli -d fx2lafw --scan`。两个实踩坑：binary 输入采样率必须写全数字 `24000000`（`24m` 被静默截成 24Hz）；10× 采样率规则买的是边沿定位精度不是能不能解码。源：[[ch02-tools-multimeter-la|basics ch02]]。

### 7.3 openocd（全系列的眼睛）

活体读 `mdw <addr>`（跑着读，不 halt）；内核私有寄存器（BASEPRI）必须 halt 后 `reg`；断点 `bp <addr> 2 hw`（Thumb 2 字节对齐；nm 地址最低位是 1 时先减 1）；被杀会话可能把 NRST 留在按住态（寄存器读全 0），新会话 `reset halt` 即救。源：[[ch00c-debug-stack-panorama|ch00c]]、[[ch17-pendsv-single-step|ch17]]。

## 8 真机占位与待核对总清单

### 8.1 高价值待核对项（实跑时第一优先核销）

| 待核对项                                                   | 影响章节  | 核对手段              |
| ---------------------------------------------------------- | --------- | --------------------- |
| KEY1=PA0 / KEY2=PC13、低有效假设                           | ch02      | 万用表量电平 + 丝印   |
| 蜂鸣器 PI11 有源/无源、驱动电路                            | ch03      | 听感 + 原理图         |
| VREF+ 实际电压、电位器阻值                                 | ch04/11   | 万用表反推            |
| W25Q256 丝印终验（勘误后定论）                             | ch07      | JEDEC ID 实读         |
| PB6/PB7 在黑排针的引出位置                                 | ch08      | 万用表通断追线        |
| RPi BCM 号 ↔ 物理脚号全套                                  | ch09      | pinout.xyz 上电前复核 |
| PHY 型号（LAN8720/LAN8742）、地址、REF_CLK 方案、RMII 走线 | ch20–22   | MDIO 扫描 + 原理图    |
| fireDAP 20 脚座 TXD/RXD 精确脚位                           | ch00 系列 | 丝印 + 通断           |

### 8.2 embedded-basics 真机回填路线（板到即激活，顺序照抄）

1. F407 到位 → 真机点灯 + PWM 呼吸灯（basics ch05/ch08）
2. → 双板 UART（ch06，或一块板 + USB-TTL）
3. → SWD/openocd 真机调试（ch11）
4. → I2C/SPI 接 BME280 首读（ch10）
5. GD32VF103 到位 → RISC-V 工具链 + 重做点灯/UART（ch09）
6. 综合项目：F407 主控 + ESP01-S WiFi 协处理器（ch12 尾声）

## 9 实操顺序建议

```text
阶段 0  基础设施（§2）：SWD 烧录通 → 串口通 → 救砖演练一遍     ← 全部 ✅ 实测路线
阶段 1  板载外设（§4）：LED 心跳 → 按键 → 蜂鸣器 → 电位器 ADC   ← 顺手核销各章待核对项
阶段 2  仪器上线（§5.2/§7）：piscope 抓 UART → 抓 SPI
阶段 3  跨板（§5.1）：I2C 双板互访
阶段 4  以太网（§5.3）：MDIO → ARP/ping → 打流
并行    面包板（§6.1）：4046 分立 PLL（零件在途）
```

每个阶段的出口判据就是对应章节文末的「待核对清单」逐项打钩——这个系列的玩法本来就是**实跑数据回填章节**，你动手的过程同时是核销的过程。

## 10 器材增量总表

| 状态   | 器材                                                          | 用途              | 参考价  |
| ------ | ------------------------------------------------------------- | ----------------- | ------- |
| ✅     | 挑战者 F429-V2、野火 DAP+排线、Mini-USB 线、树莓派 4B、笔记本 | 基础盘            | —       |
| 建议购 | **网线一根（短 0.5m）**                                       | ch20/21/22 硬需求 | ~¥5     |
| 建议购 | 万用表（自动量程入门级）                                      | §7.1 全部场景     | ~¥50–80 |
| 可选   | fx2lpo 24M 逻辑分析仪                                         | MHz 级波形        | ~¥40–50 |
| 可选   | 杜邦线（公对公/母对母各一排）                                 | 探针/跨板         | ~¥10/排 |
| 在途   | 4046 PLL 套件（BOM 见工程 README）                            | §6.1              | ~¥40    |

若走 embedded-basics 平行线，另需三件套整包（约 287 元，清单与避坑见 [[ch01-roadmap-and-boards|basics ch01]]）。
