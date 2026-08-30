---
title: 设备树：嵌入式的 BIOS
date: 2026-08-30 03:55:00
description: /proc/device-tree 逐属性解读 GPIO 控制器节点，dtparam/dtoverlay 开 SPI0 到 MOSI-MISO 回环——F429「硬件描述写死在代码」的清算章：描述与驱动分离，同一驱动通吃多板
tags: [RPi, Linux, Driver, Devicetree, Lab]
---

# 设备树：嵌入式的 BIOS

> **状态声明**：本章为「先成文、后实跑」的实验设计，**未在真机执行**；以
> [[2026-08-30-rpi-lab-ch01-bookworm-surgery-baseline|ch01]] 升级后的 Bookworm（内核 ≥ 6.6）为
> 前提。DT 源码片段取自 raspberrypi/linux rpi-6.6.y 分支（已核对），本机节点路径、compatible
> 实际值、dmesg 行形态均以实测为准；所有「预期输出」为待实测核销占位。

## 本章装备清单

| 分类     | 装备                       | 价格/状态 | 用途                                          |
| -------- | -------------------------- | --------- | --------------------------------------------- |
| 已有     | 树莓派 4B + MicroSD + 网线 | ✅        | 实验主体                                      |
| 已有     | 笔记本（SSH 客户端）       | ✅        | 远程操作                                      |
| 需购买   | 杜邦线（母对母，1 根即可） | ~¥10      | 短接 MOSI-MISO（物理 19↔21）做 SPI 回环       |
| 建议购买 | 万用表                     | ~¥50      | 量 SCLK/CE 电平；波形级验证等 ch08 的 piscope |

> 本章前半（读树、开 SPI）只需板子本身；回环实验需要那根杜邦线——**不接也能跑 spiloop，
> 但 rx 会全 0 并报 MISMATCH**（这本身就是「没有物理层证据」的对照样本）。

### 本章会遇到的词

| 词                      | 一句话预览                                              |
| ----------------------- | ------------------------------------------------------- |
| 设备树（DT）            | 描述硬件（有什么、地址多少、接哪）的树形数据文件        |
| DTS / DTB               | 设备树的人写源码 / 编译后给机器吃的二进制               |
| overlay（.dtbo）        | 叠加在基础设备树上的「小补丁」片段                      |
| dtparam / dtoverlay     | config.txt 里「开外设开关」/「挂补丁」的两行咒语        |
| /proc/device-tree       | 内核正在使用的那棵活树（不是文件副本）                  |
| compatible              | 驱动匹配键：「厂商,型号」字符串，树与驱动的接头暗号     |
| reg                     | 属性：这块外设的寄存器地址+长度                         |
| probe                   | 驱动被匹配上之后执行的「入职函数」，设备号/中断都在这领 |
| SPI / MOSI/MISO/SCLK/CE | 四线串行总线：主出从入、主入从出、时钟、片选            |
| spidev                  | 内核的通用 SPI 字符设备接口，用户态 open/ioctl 它       |
| dtc                     | 设备树编译器（DTS↔DTB 双向）                            |
| platform device         | 内核按 DT 节点生成的「无总线设备」实例（对照 USB/PCI）  |

## 目标（先结论）

三件事拿下设备树（DT）：读得懂自家板子的活树（`/proc/device-tree/`）、用 overlay 把 SPI0 从
「声明为禁用」变成 `/dev/spidev0.0`、并亲手改一个参数看它流进驱动。本章是 ch04 遗留问题的
清算章：**my_gpio 里硬编码的 `0xFE200000`、btn_irq 里硬编码的 4 号线，在 DT 的世界里都是
待改造的裸机习俗**——硬件描述属于数据文件，不属于驱动代码。

| #    | 做通标准                                                      | 对应   |
| ---- | ------------------------------------------------------------- | ------ |
| R4.1 | `/proc/device-tree` 找到 GPIO 节点，五类属性逐个说出含义      | 读树   |
| R4.2 | `dtparam=spi=on` 后 `/dev/spidev0.0` 出现；MOSI-MISO 回环读回 | 开 SPI |
| R4.3 | 改总线频率/引脚参数，DT 节点与驱动 probe 行为随之变化         | 改参数 |

## 1. 原理：DT = 嵌入式的 BIOS

x86 服务器开机时，操作系统不知道板上有几根内存、网卡挂在哪条 PCIe——它读 **ACPI 表**（BIOS/
UEFI 准备好的硬件描述表——你的主场，`/sys/firmware/acpi/` 里能看到）。嵌入式没有 BIOS，
历史上每个内核驱动把自己的板子地址写死在代码里；
设备树就是把这份描述从驱动里抽出来，做成一个**随板走、不随内核走**的数据文件：板厂描述板子
（DTS），内核带着一套驱动（二进制不变），启动时按描述对号入座。

> 📖 **术语卡：设备树（Device Tree，DT）与 DTS/DTB**
> **是什么**：一棵描述硬件的树：节点=外设/控制器，属性=地址、中断号、引脚、开关状态。
> 人写 DTS（文本源码），dtc 编译成 DTB（二进制），启动时固件把 DTB 交给内核展开使用。
> **为什么存在**：让「同一份内核驱动」通吃不同板子——板差异全部住在数据文件里。
> **类比**：你的主场——容器镜像的 manifest：镜像（驱动）不变，部署参数（描述）随环境走。
> ⚠️ 类比边界：manifest 错了部署当场报错；DT 错了常是**静默哑火**（设备不出现，不报错）。

主轴对照——同一份硬件信息，两个世界放哪：

| 维度              | F429 裸机                                                   | RPi Linux 设备树                                                 |
| ----------------- | ----------------------------------------------------------- | ---------------------------------------------------------------- |
| 硬件描述在哪      | 固件代码里（`GPIOA->MODER=…`、寄存器地址全编译进 .bin）     | /boot/firmware 下的 DTB，与驱动二进制分离                        |
| CubeMX 扮演什么   | 「一次性 DT」：图形配置被**编译进代码**，之后与代码同生共死 | 描述始终是数据，改描述不重编驱动                                 |
| 换一块板          | 重改宏、重编译、重烧录                                      | 换 DTB/overlay，同一个驱动镜像通吃（spi-bcm2835 从 Zero 跑到 5） |
| 使能/禁用一个外设 | 删代码或加编译宏                                            | `status = "okay"/"disabled"` 一行                                |
| 描述写错的下场    | 编译照过，运行时寄存器写错（静默炸）                        | probe 不来、设备不出现（静默哑）                                 |
| 系统侧类比        | 硬编码——改配置要重新编译部署                                | 声明式配置——manifest 与二进制分离                                |

对系统侧读者最短的路：DT 之于嵌入式驱动，就是 ACPI 之于 x86 内核、manifest 之于容器镜像——
**声明式硬件配置 vs 硬编码**。第 5 节会看到 `reg`、`interrupts` 这些字段如何逐一流进驱动的
probe 参数，那是「声明如何被消费」的实证。

## 2. R4.1：解读自家活树 /proc/device-tree/

内核启动时把 DTB 解开（unflatten）成一棵活树挂在 `/proc/device-tree/`——它不是文件副本，
**它就是内核正在使用的那棵树**。先找 GPIO 控制器（基址 0xFE200000，ch02 的老熟人）：

```bash
find /proc/device-tree -name '*gpio@*' -o -name 'gpio' | head
ls /proc/device-tree/soc/gpio@7e200000/     # 单元地址以实测为准（形态 7e200000/fe200000）
cat /proc/device-tree/soc/gpio@7e200000/compatible
od -An -tx1 /proc/device-tree/soc/gpio@7e200000/reg
```

活树的形态：每个节点是一个目录、每个属性是一个伪文件（DTB 已被内核展开成内存结构，再以
目录/文件形式挂出来）。两条新命令：

**命令拆解：** `find /proc/device-tree -name '*gpio@*' -o -name 'gpio' | head`

| 部分              | 作用                                                       |
| ----------------- | ---------------------------------------------------------- |
| `find`            | 递归遍历目录树找文件                                       |
| `-name '*gpio@*'` | 名字含 `gpio@` 的节点（DT 惯例：节点名=设备类型@单元地址） |
| `-o -name 'gpio'` | `-o`=逻辑或，再匹配裸名 gpio                               |
| `\| head`         | 只看前 10 行，防刷屏                                       |

**命令拆解：** `od -An -tx1 /proc/device-tree/soc/gpio@7e200000/reg`

| 部分   | 作用                                                       |
| ------ | ---------------------------------------------------------- |
| `od`   | octal dump——按字节原样打印文件的老牌工具                   |
| `-An`  | 不打印左侧地址列（A=address，n=none）                      |
| `-tx1` | 十六进制显示、每字节一组（t=type，x=hex，1=1 字节分组）    |
| `reg`  | 属性本体：内容是「大端 32bit cell」——每数 4 字节、高位在前 |

**你会看到**：形如 `7e 20 00 00 00 00 00 b4`——前 4 字节拼成 0x7e200000（地址），后 4 字节
0xb4（长度 180 字节）。
**失败了先查**：路径不存在——单元地址形态与你的板子不符（7e…/fe… 两版，先
`ls /proc/device-tree/soc/`）。

五类属性的含义与流向（这是本节的主表；「值」列为 rpi-6.6.y 源码预期，以实测为准）：

| 属性                              | 预期值（节选）                   | 含义                                         | 流进内核哪里                                           |
| --------------------------------- | -------------------------------- | -------------------------------------------- | ------------------------------------------------------ |
| `compatible`                      | `"brcm,bcm2835-gpio"`            | 驱动匹配键（厂商,型号）                      | pinctrl 驱动 of_match_table → probe 被选中             |
| `reg`                             | `<0x7e200000 0xb4>`              | 寄存器块地址+长度（总线地址）                | 经 /soc ranges 翻译成 0xfe200000 → ioremap             |
| `interrupts`                      | 三条（GPIO bank 0/1/2 的父中断） | 本控制器作为**中断源**接到 GIC               | 建 gpio irqdomain 的父链——ch05 `gpiod_to_irq()` 的底账 |
| `gpio-controller` + `#gpio-cells` | 存在；`2`                        | 声明自己是 GPIO 提供者；2 个 cell=线号+flags | gpiochip 注册——`gpiodetect` 看到的 gpiochip0（58 线）  |
| `status`                          | `"okay"`                         | 存在性总开关                                 | `disabled` 则 platform device 根本不创建               |

三个读树要点：

1. **字符串属性读出来不带换行**——`cat compatible` 输出黏着提示符，属性是原始字节（字符串以
   `\0` 结尾；整数是大端 32bit cell），所以要用 `od`/`xxd` 看数值。
2. **地址有两个身份**：节点叫 `gpio@7e200000`（总线地址 0x7e…，VideoCore 视角），`/proc/iomem`
   里写着 `fe200000.gpio`（ARM 物理视角）——翻译发生在 /soc 节点的 `ranges` 属性。ch02 直捅的
   `0xFE200000` 就是翻译后的那个地址。
3. **同一个节点两种身份**：它既被 gpiod 当 GPIO 提供者（`gpio-controller`），也被中断子系统当
   中断提供者（`interrupt-controller`）——ch05 按键中断的两条身份线在树上就长这样。

> 📖 **术语卡：compatible 属性**
> **是什么**：每个 DT 节点的「自我介绍」字符串，格式「厂商,型号」（如 `brcm,bcm2835-gpio`）。
> 驱动侧有一张 of_match_table（兼容串清单），内核拿节点的 compatible 对表——对上才 probe。
> **为什么存在**：这是树与驱动唯一的接口协议——描述与代码的接头暗号。
> **类比**：HTTP 内容协商：客户端（驱动）声明能处理的类型，服务端（节点）声明自己是什么，
> 匹配上才成交。
> ⚠️ 类比边界：Content-Type 有 IANA 注册表；compatible 无全局注册中心，厂商自报家门，
> 拼错=静默不匹配。

> 📖 **术语卡：probe（探测函数）与 platform 设备**
> **是什么**：内核为每个 status=okay 的 DT 节点创建一个 platform device（无总线设备的通用
> 容器）；某驱动匹配表命中它的 compatible 后，内核调用该驱动的 probe 函数——在这里领资源
> （ioremap 地址、IRQ 号、时钟）并注册设备。
> **为什么存在**：把「你存在」与「我来服务你」解耦：设备由树声明、驱动独立装载，probe 是
> 两者的握手现场。
> **类比**：你的主场——DHCP 认领：设备上线（节点），服务端认领（匹配），下发资源（probe
> 拿地址/中断号）。
> ⚠️ 类比边界：probe 只在绑定/枚举时跑一次；不是每次 open 设备都跑。

想看「源码」，反编译固件里的 DTB（树上看到的一切都能在这一步对上）：

```bash
sudo apt install device-tree-compiler
ls /boot/firmware/*.dtb                        # 预期 bcm2711-rpi-4-b.dtb（以实测为准）
sudo dtc -I dtb -O dts /boot/firmware/bcm2711-rpi-4-b.dtb > /tmp/board.dts && less /tmp/board.dts
# 反编译会刷一串 warning（unit_address_vs_reg 之类）——历史遗留噪音，正常
```

**命令拆解：** `sudo dtc -I dtb -O dts /boot/firmware/bcm2711-rpi-4-b.dtb > /tmp/board.dts`

| 部分               | 作用                                               |
| ------------------ | -------------------------------------------------- |
| `dtc`              | 设备树编译器（device tree compiler），DTS↔DTB 双向 |
| `-I dtb`           | 输入格式：编译后的二进制 DTB                       |
| `-O dts`           | 输出格式：人读的 DTS 源码                          |
| `> /tmp/board.dts` | 重定向落盘，配合 less 翻看                         |

## 3. R4.2：overlay 开 SPI——从 config.txt 到 /dev/spidev0.0

### 3.1 全链路：一行配置走过六站

```text
[1] /boot/firmware/config.txt:  dtparam=spi=on
[2] GPU 固件(start4.elf) 读 config.txt，把 base DTB 里 spi0 节点的 status 从 disabled 改 okay
    （dtoverlay=xxx 则是把 overlays/xxx.dtbo 片段按符号合并进 base DTB）
[3] 固件把合成后的 DTB 交给内核
[4] 内核解树：of/platform 对 status=okay 的节点创建 platform device
[5] compatible "brcm,bcm2835-spi" 匹配到 spi-bcm2835 驱动 → bcm2835_spi_probe()：
    ioremap 寄存器、clk_get、request_irq(bcm2835_spi_interrupt)、注册 spi 主控制器 spi0
[6] 子节点 spidev@0 交给 SPI core → spidev 驱动绑定 → devtmpfs 冒出 /dev/spidev0.0
```

`dtparam` 与 `dtoverlay` 的分工：**dtparam 是基础 DTB 自带的板级开关**（base DTB 的
`__overrides__` 段定义了 `spi`——官方 README 原话："Set to 'on' to enable the spi interfaces
(default 'off')"）；**dtoverlay 是把 overlays/ 目录下的 .dtbo 片段叠加到基础树上**，能力更广
（改引脚、加节点、加参数）。第 4 节两种都用。

> 📖 **术语卡：overlay（设备树覆盖片段，.dtbo）**
> **是什么**：一个只描述「差异」的小设备树片段：定位到基础树的某个节点（target），覆盖/
> 追加若干属性。编译成 .dtbo 放进 /boot/firmware/overlays/，config.txt 一行挂载。
> **为什么存在**：官方不可能为每块 HAT 扩展板出一整份 DTB——补丁式描述才能组合。
> **类比**：你的主场——git patch / k8s 的 kustomize overlay：不动基础清单，只叠加差异。
> ⚠️ 类比边界：git patch 冲突会报错；DT overlay 合并失败常是**静默不生效**，要靠
> `dtoverlay -l` 与活树核对。

**命令拆解：** config.txt 里的 `dtparam=spi=on` 与 `dtoverlay=spi0-2cs,cs1_pin=16`

| 部分                     | 作用                                                           |
| ------------------------ | -------------------------------------------------------------- |
| `dtparam=spi=on`         | 拨动**基础 DTB 自带**的板级开关：spi0 节点 status→okay         |
| `dtoverlay=spi0-2cs`     | 挂载 overlays/spi0-2cs.dtbo 片段到基础树                       |
| `,cs1_pin=16`            | 逗号后是该 overlay 声明的参数（对应其 `__overrides__` 段）     |
| 谁来读这行               | 不是内核——GPU 侧固件（start4.elf）开机时读 config.txt 合成 DTB |
| `dtoverlay=xxx` 运行时挂 | `sudo dtoverlay xxx.dtbo` 可不重启挂载（§4 末尾的限制）        |

### 3.2 实验：启用 + 回环

```bash
sudo tee -a /boot/firmware/config.txt <<< 'dtparam=spi=on'
sudo reboot
ls -l /dev/spidev0.*                # 预期 spidev0.0 与 spidev0.1（CE0/CE1 两个片选）
dmesg | grep -iE 'spi|bcm2835'      # probe 行形态待实测（见待核对清单）
gpioinfo gpiochip0 | grep -E '^\s+line\s+(7|8|9|10|11):'   # SPI 引脚应显示被占用（spi0 功能）
```

**命令拆解：** `sudo tee -a /boot/firmware/config.txt <<< 'dtparam=spi=on'`

| 部分           | 作用                                                             |
| -------------- | ---------------------------------------------------------------- |
| `<<< '字符串'` | here-string：把字符串当 tee 的标准输入（免建临时文件）           |
| `tee -a`       | 写入目标文件且**追加**（-a=append；不带则覆盖——config.txt 慎用） |
| `sudo` 给 tee  | 重定向由 tee（root）执行而非 shell——同 ch04 §3.3 的原理          |

末行 `gpioinfo`（libgpiod 工具族：列出 gpiochip0 每根线的当前消费者）用 `grep -E`（扩展正则）
过滤出 7/8/9/10/11 号线——开 SPI 后它们应标注 spi0 功能而非闲置。

SPI0 引脚（后文全系列复用）：MOSI=GPIO10 物理 **19**、MISO=GPIO9 物理 **21**、SCLK=GPIO11
物理 23、CE0=GPIO8 物理 24。**回环 = 一根杜邦线短接物理 19 与 21**（MOSI 发什么 MISO 收什么）。

> 📖 **术语卡：SPI 总线（Serial Peripheral Interface）**
> **是什么**：主从式四线串行总线：SCLK（时钟——主设备打的节拍）、MOSI（主出从入）、
> MISO（主入从出）、CE/CS（片选——拉低哪根就选中哪个从设备）。全双工：收发同时进行。
> **为什么存在**：一主多从、时序简单、无地址协议开销——比 I2C 快，比并口省引脚。
> **类比**：同步串行版的「专线对讲」：主机打拍子（SCLK），两边按拍子各说各听（MOSI/MISO），
> CE 是「点名」开关。
> ⚠️ 类比边界：SPI 无应答/无地址机制——从设备死活全靠 CE 和时序，出了错总线不会告诉你。

> 📖 **术语卡：spidev**
> **是什么**：内核里的「通用 SPI 用户态接口」驱动：绑定到 DT 里 compatible="spidev" 的子节点，
> 生成 /dev/spidev总线.片选（如 /dev/spidev0.0），用户态用 open/ioctl 读写。
> **为什么存在**：让用户态程序不经写驱动就能玩 SPI 外设——本章回环程序的全部依赖。
> **类比**：/dev/mem 的文明版——不给你裸寄存器，给你结构化的「一次传输一个消息」接口。
> ⚠️ 类比边界：spidev 是调试/原型工具，内核文档明确不建议生产用（专有外设应写正经驱动）。

回环自检程序（ch07 全栈跟踪的靶子就是它）：

```c
// spiloop.c — SPI0 回环自检：物理 19(MOSI) ↔ 21(MISO) 短接
// 用法：./spiloop [speed_hz]；不带参数 = 用设备默认速率（DT 的 spi-max-frequency）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

int main(int argc, char **argv)
{
    uint8_t tx[4] = { 0xA5, 0x5A, 0x00, 0xFF };
    uint8_t rx[4] = { 0 };
    struct spi_ioc_transfer tr = {
        .tx_buf = (unsigned long)tx, .rx_buf = (unsigned long)rx,
        .len = 4, .bits_per_word = 8,
        .speed_hz = argc > 1 ? strtoul(argv[1], NULL, 0) : 0,   /* 0 = 设备默认 */
    };
    int fd = open("/dev/spidev0.0", O_RDWR);

    if (fd < 0 || ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 1) { perror("spi"); return 1; }
    printf("tx: %02x %02x %02x %02x @ %u Hz\n", tx[0], tx[1], tx[2], tx[3], tr.speed_hz);
    printf("rx: %02x %02x %02x %02x\n", rx[0], rx[1], rx[2], rx[3]);
    printf("%s\n", !memcmp(tx, rx, 4) ? "LOOPBACK OK" : "MISMATCH");
    return 0;
}
```

```bash
gcc -O2 -o spiloop spiloop.c && sudo ./spiloop        # 默认速率（DT 决定）
sudo ./spiloop 1000000                                # 显式 1MHz——ch07/piscope 用慢速好读波形
# spidev 默认仅 root 可开；udev 放权思路同 ch04 第 3.4 节
```

spiloop 走读（三个新面孔）：`spi_ioc_transfer`（一段传输的描述结构：发缓冲、收缓冲、长度、
位宽、速率——回环实验的主角）；`SPI_IOC_MESSAGE(1)`（ioctl 命令宏：一次提交 1 段传输，驱动
同步完成全双工收发）；`tx_buf/rx_buf` 指向的两块缓冲在**同一次**传输里各司其职——MOSI 送出
tx 的同时 MISO 收进 rx，这正是回环能「原样收回」的机制根源。

## 4. R4.3：改 overlay 参数，看它流进驱动

### 4.1 引脚参数：现成 overlay 的 dtparam

rpi-6.6.y 的 `spi0-2cs` overlay 提供 `cs0_pin`/`cs1_pin`（默认 8/7）与 `no_miso` 三个参数
（已核对源码 `__overrides__`）。把 CS1 从 GPIO7 挪到 GPIO16——用它整体替换掉 `dtparam=spi=on`
（spi0-2cs 自带 `status = "okay"`，等于把「开 SPI」和「改引脚」合成一步）：

```bash
sudo sed -i 's/^dtparam=spi=on/dtoverlay=spi0-2cs,cs1_pin=16/' /boot/firmware/config.txt
sudo reboot
od -An -tx4 $(find /proc/device-tree -name 'spi@*' | head -1)/cs-gpios
# 预期 cs-gpios 的第二个引用从 07 变成 10（16 的 16 进制）——引脚参数流进了树
```

**命令拆解：** `sudo sed -i 's/^dtparam=spi=on/dtoverlay=spi0-2cs,cs1_pin=16/' /boot/firmware/config.txt`

| 部分                            | 作用                                                     |
| ------------------------------- | -------------------------------------------------------- |
| `sed 's/旧/新/'`                | 流编辑器替换：s=substitute，把匹配「旧」的行换成「新」   |
| `^dtparam=spi=on`               | 匹配模式：行首（^）锚定，只换整行精确匹配的这一行        |
| `-i`                            | 直接改写文件本体（in-place）——改的是启动配置，先备份更稳 |
| `dtoverlay=spi0-2cs,cs1_pin=16` | 替换结果：挂 overlay 并传参（§3.1 拆解过语法）           |

第三行的 `od -An -tx4`（每 4 字节一组=一个 cell）读 cs-gpios 属性验证改动落树。

### 4.2 频率参数：写一个自己的 overlay（15 行）

`spi0-2cs` 没有速率参数——正好，自己写一个。基础 DTB 里 spidev0 的默认
`spi-max-frequency = <125000000>`（rpi-6.6.y 源码已核对），我们把它压到 4MHz：

```dts
// my-spi-speed-overlay.dts — 把 spidev0 的速率上限从 125MHz 改为 4MHz
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2711";

    fragment@0 {
        target = <&spidev0>;            /* 基础 DTB __symbols__ 里的标签，合并期解析 */
        __overlay__ {
            spi-max-frequency = <4000000>;
        };
    };
};
```

```bash
dtc -@ -I dts -O dtb -o my-spi-speed.dtbo my-spi-speed-overlay.dts
sudo cp my-spi-speed.dtbo /boot/firmware/overlays/
echo 'dtoverlay=my-spi-speed' | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

**命令拆解：** `dtc -@ -I dts -O dtb -o my-spi-speed.dtbo my-spi-speed-overlay.dts`

| 部分                   | 作用                                                                                       |
| ---------------------- | ------------------------------------------------------------------------------------------ |
| `-I dts -O dtb`        | 方向与 §2 相反：源码 → 二进制                                                              |
| `-@`                   | 额外生成符号表：把 `&spidev0` 这类**标签**引用记进 **symbols**，overlay 定位 target 全靠它 |
| `-o my-spi-speed.dtbo` | 输出文件名：overlays/ 目录约定 .dtbo 后缀                                                  |

源码里两个新语法：`/plugin/;`（声明「这是 overlay 不是完整树」，允许只写差异）；
`fragment@0` + `__overlay__`（overlay 的标准骨架：第 0 号补丁片段，正文写在 **overlay** 里）。

核销证据（三层）：

```bash
od -An -tx4 $(find /proc/device-tree -name 'spidev@0' -o -name 'spidev@1' | head -1)/spi-max-frequency
# 预期 003d0900（4,000,000 的大端 32bit）——声明层
sudo ./spiloop                                                        # 功能层：回环仍 OK
# 物理层：piscope（ch08）量 SCLK 周期应从 ~8ns 变 ~250ns——4MHz 的物理实证
```

一个必须讲清的限制：**运行时 `sudo dtoverlay my-spi-speed.dtbo` 可以即时挂载 overlay，但对
已注册设备改属性不会触发重新 probe**——`spi-max-frequency` 是设备注册时消费的，速率实验必须
走 config.txt + 重启。`dtoverlay -l` 能列出已挂 overlay（形态待核对）；固件侧的 overlay 报错
用 `sudo vclog --msg`（旧名 `vcdbg log msg`）查——两者可用性待核对。

## 5. DT 字段 → 驱动 probe 参数：声明的消费路径

把 rpi-6.6.y 里 spi0 节点的骨架抄出来，逐字段标注它流进了谁的哪个参数——这张表是「描述与
驱动分离」的账本（spi0 中断号等具体值以本机反编译为准）。两个语法先认脸：**标签**
（`spi0:`、`spidev0:`——给节点起的别名，DTS 里用 `&标签` 引用，§4.2 overlay 的 target 靠它）；
**phandle**（编译后标签化成的「节点指针」数字——`cs-gpios` 里第一个 cell 就是 GPIO 节点的
phandle）：

```dts
&spi0 {                                   /* 标签：overlay 的 target 靠它定位 */
    pinctrl-names = "default";
    pinctrl-0 = <&spi0_pins &spi0_cs_pins>; /* 引脚复用：MOSI/MISO/SCLK/CS 的 GPIO 配置 */
    cs-gpios = <&gpio 8 1>, <&gpio 7 1>;    /* 两个片选，尾缀 1 = 低有效 */
    status = "okay";                        /* 总开关（dtparam=spi=on 改的就是这类行） */

    spidev0: spidev@0 {                     /* 标签从这里来 */
        compatible = "spidev";
        reg = <0>;                          /* 挂在哪个片选：CE0 → 设备名 spidev0.0 */
        spi-max-frequency = <125000000>;    /* 速率上限（本章 4.2 改的字段） */
        status = "okay";
    };
};
```

| DT 字段                                       | 消费者                   | 落点（probe 里的形态）                                                         |
| --------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------ |
| `compatible = "brcm,bcm2835-spi"`（控制器级） | spi-bcm2835 驱动         | of_match_table 命中 → `bcm2835_spi_probe()` 被调用                             |
| `reg <… 0x1000>`                              | probe 里 platform 框架   | `platform_get_resource()` → `devm_ioremap`（ch04 手工 ioremap 的官配版）       |
| `interrupts` + `interrupt-parent`             | probe                    | `platform_get_irq()` → `request_irq(bcm2835_spi_interrupt)`（ch05 的框架示范） |
| `pinctrl-0`                                   | pinctrl 子系统           | 引脚复用配置（哪几根 GPIO 变成 MOSI/MISO/SCLK）                                |
| `cs-gpios`                                    | **SPI core（非本驱动）** | 片选降级为 GPIO 操作，`1` 是低有效 flag                                        |
| `status`                                      | of/platform              | `disabled` 就没有第 3 列的一切                                                 |
| 子节点 `compatible="spidev"` + `reg=<0>`      | SPI core → spidev.c      | `spi_new_device`：总线 0、片选 0 → `/dev/spidev0.0`                            |
| 子节点 `spi-max-frequency`                    | SPI core                 | `spi_device->max_speed_hz`（用户态可再经 ioctl 压低）                          |

注意 `cs-gpios` 和 `spi-max-frequency` 的消费者**不是** spi-bcm2835 而是 SPI 核心——DT 的字段
不只喂「匹配到的那个驱动」，整条总线栈各取所需。这也是 DT 学习最大的坑：**字段到消费者的映射
要看驱动与子系统文档，树本身不告诉你**（`Documentation/devicetree/bindings/` 是权威账本，
spidev 的绑定文档值得扫一眼，见待核对清单）。

## 预期输出（待实测核销）

```text
$ ls -l /dev/spidev0.*
crw------- 1 root root ... /dev/spidev0.0
crw------- 1 root root ... /dev/spidev0.1

$ sudo ./spiloop
tx: a5 5a 00 ff @ 0 Hz                          # 0 = 设备默认速率（DT 的 spi-max-frequency）
rx: a5 5a 00 ff
LOOPBACK OK                                     # 物理层证据：短接线把 0xA5 送回来了

$ od -An -tx4 .../spidev@0/spi-max-frequency
003d0900                                        # 4MHz 的大端 cell（4.2 实验后）
```

## 与 F429/裸机对照

F429 世界没有设备树，但**它欠的每一笔账都能在 F429 系列里找到欠条**：

| 本系列遇到的坑           | F429 世界的同款                                      | DT 的解法                          |
| ------------------------ | ---------------------------------------------------- | ---------------------------------- |
| ch04 硬编码 `0xFE200000` | 固件里寄存器地址全是魔数（RM0090 抄进代码）          | `reg` 属性 + ioremap 由框架代持    |
| ch05 硬编码 4 号线       | KEY1 引脚候选 PA0 还在「待核对」（F429 ch02 占位宏） | 引脚是节点里的数据，改树不改代码   |
| 换板重编译               | 移植 = 重查一遍晶振/引脚重编译（序章晶振 25M 血案）  | 同一驱动 + 不同 DTB/overlay        |
| 描述错误静默哑           | 八环使能链断一环无声无息（F429 ch02）                | 同样静默！靠 `status`/dmesg/树核对 |

最后一行是公平话：**DT 没有消灭「配置错误静默失败」**，它只是把失败面从「编译过的代码」挪到
「没编译过的数据」。诊断工具换了（`ls /proc/device-tree`、`dmesg`、`dtoverlay -l`），方法论没变
——先问「描述到了没」，再问「驱动 probe 了没」，最后问「设备节点出了没」。

下一章 [[2026-08-30-rpi-lab-ch07-read-syscall-fullstack-trace|ch07]] 拿本章的 spiloop 当靶子，
从 strace 到 ftrace 把 `read/ioctl(/dev/spidev0.0)` 一直追到 bcm2835 的寄存器写——四层证据链
在 Linux 的完整版。

## 待核对清单

- `/proc/device-tree` 下 spi/gpio 节点的确切路径与单元地址（spi@7e204000? gpio@7e200000?）
- GPIO 节点 `compatible` 实际值（预期 `brcm,bcm2835-gpio`，2711 或用别的串）
- 本机 DTB 文件名（bcm2711-rpi-4-b.dtb?）与 overlays/ 目录内容
- `dtparam=spi=on` 后 dmesg 里 spi/bcm2835 相关行的形态（probe 是否有可读打印）
- `/sys/bus/spi/devices/spi0.0/` 是否暴露速率类属性（6.6 主线尚无 spi 设备 sysfs 属性，rpi 分支
  待实测；无则用 /proc/device-tree + piscope 兜底）
- 自制 overlay 的 `target = <&spidev0>` 在本机固件合并是否通过（标签是否在 **symbols**）
- `dtoverlay -l`、`sudo dtoverlay xxx.dtbo` 运行时挂载、`vclog --msg` 三件套的可用性
- spidev 的 devicetree binding 文档位置（Documentation/devicetree/bindings/spi/ 下具体文件名）
