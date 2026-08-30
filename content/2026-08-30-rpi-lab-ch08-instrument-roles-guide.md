---
title: 仪器手册：穷人逻辑分析仪与网络之眼
date: 2026-08-30 04:05:00
description: RPi4B 六种仪器角色速查——piscope 穷人逻辑分析仪、i2cdetect 主机扫描、tcpdump/iperf3 网络对端、hostapd 受控 AP、usbmon USB 之眼：每节用途/最小命令/预期输出/对接章节/已知坑
tags: [RPi, Instrument, Network, Lab]
---

# 仪器手册：穷人逻辑分析仪与网络之眼

> **状态声明**：本章为速查手册体裁，**未在真机执行**；以
> [[2026-08-30-rpi-lab-ch01-bookworm-surgery-baseline|ch01]] 升级后的 Bookworm 为前提。所有
> 「预期输出」均为待实测核销占位。全章接线遵守 ch01 规约：**跨板先共地、3.3V 红线**，此处只
> 引用不再重复。本章不占主线排期，按 F429/WiFi RF/BOX-3 各系列节奏取用。

## 本章装备清单

| 分类   | 装备                            | 价格/状态 | 用途                                                        |
| ------ | ------------------------------- | --------- | ----------------------------------------------------------- |
| 已有   | 树莓派 4B + MicroSD + 网线      | ✅        | 六种仪器角色共同的宿主机                                    |
| 已有   | 笔记本                          | ✅        | piscope 的远程 GUI 端（§1）、iperf3 的对端（§4）            |
| 已有   | 挑战者 F429 板                  | ✅        | 角色 1–4 的对接实验对象（按小节取用）                       |
| 需购买 | 杜邦线（母对母 + 公对母各一排） | ~¥10/排   | piscope 探针（§1 接线表）、I2C 四线对接（§2 接线表）        |
| 建议   | 万用表                          | ~¥50      | 接线三查：共地通不通、3.3V 有没有、断线在哪                 |
| 可选   | fx2lpo 24M 逻辑分析仪           | ~¥50      | piscope 的对照组（LA 到货后波形实验以 LA 为准，见定位提醒） |

> 各角色增量装备在正文小节处注明：hostapd（§5）用 RPi4B 板载无线，零额外硬件；usbmon（§6）
> 的 BOX-3 板还在途，本节只先备好仪器位。

## 本章会遇到的词

先混个脸熟，正文首现处会再展开（术语卡 📖 或行内括号）：

| 词                     | 一句话解释                                                       |
| ---------------------- | ---------------------------------------------------------------- |
| pigpiod / piscope      | GPIO 采样守护进程 + 远程波形 GUI：两者拼成穷人逻辑分析仪         |
| GPIO 编号 / 物理引脚号 | 同一根排针针脚的两套编号系统（SoC 命名 vs 数针脚）               |
| /dev/mem               | 把物理内存（含外设寄存器）开放给用户态的设备文件                 |
| I2C / 开漏             | 两线（SDA 数据/SCL 时钟）一主多从总线 / 只会拉低不会拉高的输出级 |
| pcap                   | 抓包存档的通用格式，tcpdump/Wireshark 通吃                       |
| iperf3 专有协议        | 控制信道+数据信道的私有协议——裸机板上没有客户端                  |
| hostapd / regdomain    | 用户态 AP 守护进程 / 各国无线电法规划定的功率与信道边界          |
| nl80211 / NM           | 内核无线的标准接口 / NetworkManager（发行版默认的网络管理服务）  |
| usbmon / URB           | 内核 USB 总线监视接口 / USB Request Block，USB 传输的基本单位    |
| 枚举 / 描述符          | 插上后主机问出设备身份的流程 / 设备自述身份的数据结构            |
| debugfs / modprobe     | 内核调试信息伪文件系统 / 加载内核模块的命令                      |
| VID / PID              | USB 厂商 ID / 产品 ID，各 16 位——设备的身份证号                  |

## 角色总表

| #   | 角色      | 一句话用途              | 主命令                  | 对接系列                 |
| --- | --------- | ----------------------- | ----------------------- | ------------------------ |
| 1   | piscope   | 1µs 采样穷人逻辑分析仪  | `pigpiod` + piscope GUI | F429 ch07/09 波形课      |
| 2   | i2cdetect | I2C 主机，扫 STM32 从机 | `i2cdetect -y 1`        | F429 ch08 双板实验       |
| 3   | tcpdump   | 网络之眼，抓上线首包    | `tcpdump -i eth0`       | F429 ch20–22             |
| 4   | iperf3    | 吞吐对端与链路基线      | `iperf3 -s` / `-c`      | F429 ch21/22             |
| 5   | hostapd   | 受控 AP（单频段单信道） | `hostapd hostapd.conf`  | WiFi RF ch15/16 真机核销 |
| 6   | usbmon    | USB 之眼，抓枚举事务    | `cat …/usbmon/0u`       | BOX-3 USB OTG（板在途）  |

定位提醒（来自本系列 spec 的 non-goals）：piscope 是穷人档——解码字节够用，量亚微秒时序不
行；24MHz LA 到货后波形实验以 LA 为准，本章是过渡期与「随手一抓」的答案。

## 1. piscope：穷人逻辑分析仪

> 📖 **术语卡：pigpiod 与 piscope**
> **是什么**：pigpiod 是 pigpio 库的守护进程（daemon：开机常驻的后台服务），独占 GPIO 做高速采样，在 8888 端口提供服务；piscope 是它的图形客户端，把采样流渲染成逻辑分析仪式的波形图。
> **为什么存在**：Linux 用户态进程没法稳定掐微秒级的点，干脆由一个专职守护进程集中采样，pigs（命令行）、piscope（界面）等多个工具共享同一份采样能力。
> **类比**：把 RPi 当作一台网络仪器：pigpiod 是机身固件，piscope 是你笔记本上的控制台——控制面与数据面分居两端。
> ⚠️ 类比边界：真逻辑分析仪的采样时钟是独立晶振；pigpiod 靠软件循环采样，时间戳有 µs 级抖动（正是下文「穷人档」边界的来源）。

**用途**：把 RPi 的若干 GPIO 当采样探针，1µs 采样率抓数字波形并解码——F429 阶段 2 的 SPI/UART
波形课（[[2026-08-30-f429-lab-ch09-rpi-piscope-logic-analyzer|F429 ch09]]）在 LA 到货前的主机位。

**装备与接线**（探 F429 的 SPI，波形源 =
[[2026-08-30-f429-lab-ch07-spi-flash-w25q64|F429 ch07]] 的 W25Q64 实验）：

| RPi 探针脚        | 接 F429 侧 | 说明                                                         |
| ----------------- | ---------- | ------------------------------------------------------------ |
| GPIO17（物理 11） | SCK        | 时钟是解码基准，必须抓（SCK = SPI 时钟线）                   |
| GPIO4（物理 7）   | MOSI       | 字节内容（MOSI = 主出从入数据线）                            |
| GPIO27（物理 13） | CS（可选） | 抓到片选可精确框定一次传输（CS = Chip Select，拉低选中从机） |
| GND（物理 9）     | GND        | **先共地再碰信号**（ch01 规约）                              |

（探针脚避开本系列自用的引脚：SPI0 的 19/21/23、I2C1 的 3/5；若与
[[2026-08-30-rpi-lab-ch05-request-irq-vs-nvic|ch05]] 按键实验同跑，GPIO4 让给探针时先 rmmod。）

> 📖 **术语卡：GPIO 编号 vs 物理引脚号**
> **是什么**：「GPIO17（物理 11）」这种双写法说的是**同一根针**：GPIO17 是 SoC 的 BCM 命名（程序、pigpio 里用这个）；物理 11 是排针上从角上数出来的第 11 针（万用表表笔、杜邦线认这个）。
> **为什么存在**：两套编号各有主人——芯片内部逻辑用 BCM 号，物理世界只能数针脚，改板不改针脚排布时两套就对不齐了。
> **类比**：像接口名与端口号的分工：`eth0` 是系统身份，RJ45 插孔位置是物理身份——程序引用前者，手去碰后者。
> ⚠️ 类比边界：网卡名与插孔通常一一对应，而 GPIO 号与针脚位置的映射**毫无规律**，跨板（RPi 与 F429）必须各自查表，禁止心算。

**最小可用命令**：

```bash
sudo apt install pigpiod            # 守护进程（pigpio 库/工具包名待实测）
sudo systemctl enable --now pigpiod # 或手动：sudo pigpiod -s 1（1µs 采样）
pigs hwver                           # 守护进程活着（返回 BCM 版本号）
# piscope GUI 不在 Debian 源：上游 install.sh 安装（github.com/joan2937/piscope，待实测）
# RPi 是 Lite 无桌面 → piscope 跑在笔记本上，连接对话框指向 raspberrypi.local 的 pigpiod
```

**命令拆解：** piscope 上车四步

| 部分                                  | 作用                                                                                                          |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `sudo apt install pigpiod`            | 装守护进程（包名待实测——待核对清单已记这一笔）                                                                |
| `sudo systemctl enable --now pigpiod` | `enable` = 设开机自启，`--now` = 顺手现在就启动一次；等价手动法见注释 `pigpiod -s 1`（`-s 1` = 采样间隔 1µs） |
| `pigs hwver`                          | pigs 是 pigpiod 自带的命令行客户端；`hwver` 问硬件版本——能吐出 BCM 版本号即证明守护进程活着                   |
| `install.sh`（上游）                  | piscope GUI 不在 Debian 源里，用上游脚本装（github.com/joan2937/piscope，待实测）                             |
| 远程用法（注释最后一行）              | RPi 是 Lite 无桌面：piscope 装在笔记本上，连接对话框里填 `raspberrypi.local` 的 pigpiod 地址                  |

**你会看到**：`pigs hwver` 返回一串 BCM 版本数字；piscope 波形窗形态见下方预期输出。
**失败了先查**：服务状态（`systemctl status pigpiod`）；8888 端口默认只听 localhost——远程连接先看下文坑 2。

**预期输出（待实测核销）**：piscope 波形窗里 SCK 突发与 MOSI 位流对齐，解码器输出 F429 发出
的字节（如 W25Q64 的 JEDEC ID 命令 `9F`——SPI flash 的「报身家」命令：让芯片回吐厂商/容量标识）。

**已知坑**：

- pigpiod 靠 `/dev/mem` 采样——[[2026-08-30-rpi-lab-ch02-devmem-direct-register|ch02]] 的
  CONFIG_STRICT_DEVMEM 配置直接决定它能否工作；
- 守护进程默认只听 localhost:8888，远程 piscope 需放开监听（配置面在**受信局域网**内做，
  勿暴露公网）；
- 时基抖动：采样线程受内核调度影响，边沿时间戳有 µs 级抖动——解码字节没问题，量保持时间/
  建立时间裕量不行（这正是「穷人档」的边界）；
- 只测 0/1 电平，3.3V 红线照旧：探针勿碰任何 5V 信号点。

> 📖 **术语卡：/dev/mem**
> **是什么**：把**整段物理地址空间**（含外设寄存器区）直接开放给用户态读写的设备文件——pigpiod 正是靠它直捣 GPIO 控制器寄存器，拿到 1µs 采样（ch02 devmem 的老朋友）。
> **为什么存在**：给用户态留一条不经驱动的「物理地址后门」——老式 X 服务器与诸多硬件工具都靠它吃饭。
> **类比**：一栋楼的万能钥匙——方便，但拿着它的任何进程都能摸进任何房间。
> ⚠️ 类比边界：正因如此内核有 CONFIG_STRICT_DEVMEM 这道闸（ch02 配置项）：典型策略是拦 RAM 区、放行 MMIO 外设区——pigpiod 的采样能不能活，取决于这道闸怎么配。

## 2. i2cdetect：I2C 主机扫描

> 📖 **术语卡：I2C**
> **是什么**：两线制同步串行总线：SDA（数据线）+ SCL（时钟线），一主多从、每个从机一个 7 位地址；电气上是开漏（open-drain：器件只会把线拉低、从不会主动拉高），所以两根线都必须挂上拉电阻，空闲态为高。
> **为什么存在**：用最少的线挂最多的低速芯片（传感器、EEPROM）——地址制省掉了「每芯片一根片选线」。
> **类比（你的主场）**：一条共享介质的小总线网：7 位地址像 MAC，读/写位像方向——但「谁先说话」靠主从架构定死，不是载波侦听。
> **⚠️** 类比边界：I2C 没有冲突退避，两主同抢会互咬（本系列只用单主）；「线与」意味着任何一个器件拉低、整条线就是低。

**用途**：给 F429 自写 I2C 从机（[[2026-08-30-f429-lab-ch08-i2c-dual-board-rpi-master|F429 ch08]]）
当扫描主机——「扫出自配从机地址」是该实验的做通标准。

**装备与接线**：RPi 的 I2C1（编号 1 的 I2C 控制器，排针引出的那路）= SDA（数据线）GPIO2
（物理 **3**）、SCL（时钟线）GPIO3（物理 **5**），接 F429 对应
I2C 引脚，共地。注意 GPIO2/3 板载 1.8kΩ 固定上拉（上拉电阻：把开漏线默认拉回高电平的必需品——
没有它，松手后线的电平悬空）。

**最小可用命令**：

```bash
sudo apt install i2c-tools
sudo raspi-config nonint do_i2c 0        # 开 I2C（或 config.txt: dtparam=i2c_arm=on + 重启）
ls /dev/i2c-*                            # 预期 /dev/i2c-1
sudo i2cdetect -y 1                      # 扫总线 1
sudo i2cget -y 1 0x30 0x00               # （F429 从机就绪后）读从机寄存器 0 的手测
```

**命令拆解：** i2cdetect 上车五步

| 部分                                | 作用                                                                                                                                   |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `sudo apt install i2c-tools`        | 装 i2c-tools 工具包——i2cdetect（扫描）/i2cget（读）/i2cset（写）一家子                                                                 |
| `sudo raspi-config nonint do_i2c 0` | raspi-config 的非交互模式：`nonint` = 不出菜单直接执行；`do_i2c 0` 里 **0 表示开启**（1 才是关）——与惯用的「0=假」直觉相反，是实测坑位 |
| `ls /dev/i2c-*`                     | 列 I2C 设备文件，预期 `/dev/i2c-1`——设备树里 I2C1 启用后内核才会生成它                                                                 |
| `sudo i2cdetect -y 1`               | 扫总线 1：对 0x03–0x77 每个地址发探测应答；`-y` 跳过「确认要扫吗」的交互提问                                                           |
| `sudo i2cget -y 1 0x30 0x00`        | 三段式参数：总线 1 → 从机地址 0x30 → 寄存器号 0x00——从机就绪后的单点手测                                                               |

**你会看到**：一张 8×8 的地址地图，自配从机处亮出两位十六进制（如 `30`），其余是 `--`。
**失败了先查**：全表 `--`（接线/共地/从机程序没跑三连查）；`UU`（内核驱动占用，正常现象，见下文坑）。

**预期输出（待实测核销）**：

```text
$ sudo i2cdetect -y 1
     0  1  2  3 ...
10: -- -- -- -- ...
30: 30 -- -- -- ...        # F429 从机地址（F429 ch08 自配，此处示例 0x30）
70: -- -- -- --
```

**已知坑**：

- **开漏与上拉**：I2C 是开漏线与（wired-AND：任何器件都可拉低，全部松手才算高），必须上拉。
  RPi 板载 1.8kΩ 常常已够；F429 侧若也开内部上拉，
  并联后阻值减半、边沿更快，长线/多设备时再评估；
- 地址写法：i2cdetect 显示 **7-bit** 地址——别与 8-bit 读写地址（7bit«1 | R/W）混淆；
- `UU` = 该地址被内核驱动占用（正常现象，不是从机）；全表 `--` = 无应答，先查接线/共地/从机
  程序在不在跑；
- 官方 man page 警告 generic scan 可能干扰个别器件——对自写从机无所谓，对成品模块保守用。

## 3. tcpdump：网络之眼

> 🎯 **你的主场**：tcpdump 是你家常便饭，这里不从头讲——只补「对端是**裸机板**」时的用法差异：
> 对端没有 OS、没有协议栈缓冲、上线初期可能连 IP 都没配上，此时链路层 MAC 头就是你唯一可靠的身份锚点，过滤与解读都要围绕它换位。

**用途**：抓 F429 以太网实验（[[2026-08-30-f429-lab-ch20-ethernet-emac-phy|ch20]] 链路建立、
[[2026-08-30-f429-lab-ch21-baremetal-lwip|ch21]] 裸机 lwIP）**上线首包**：ARP/DHCP/ICMP 三件套
（ARP：拿 IP 问 MAC 的协议；DHCP：自动领 IP 的协议；ICMP：ping 走的协议）
是 lwIP 移植的「第一口气」。

**最小可用命令**：

```bash
sudo apt install tcpdump
# 首包三件套一网打尽（-e 看链路层 MAC，-n 禁反查）：
sudo tcpdump -i eth0 -n -e 'arp or (udp port 67 or udp port 68) or icmp'
# 只看 DHCP 全流程：
sudo tcpdump -i eth0 -n -v 'udp port 67 or udp port 68'
# 存档 pcap（给 pcapx/tshark 做离线分析）：
sudo tcpdump -i eth0 -n -w /tmp/f429-boot.pcap && tcpdump -r /tmp/f429-boot.pcap -n
```

**命令拆解：** 三条抓法（你的主场工具，拆解偏重「抓裸机板」的差异点）

| 部分                                            | 作用                                                                                   |
| ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| `-i eth0`                                       | 选接口——**以 `ip link` 实际名为准**（网卡名漂移是老坑，下文坑 1）                      |
| `-n`                                            | 不做 DNS/端口反查。裸机板上线初期 DHCP 还没成，反查只会白等                            |
| `-e`                                            | 显示链路层（以太网头/MAC）。裸机板可能还没 IP——MAC 是唯一身份，这一层必开              |
| `'arp or (udp port 67 or udp port 68) or icmp'` | BPF 过滤表达式：ARP + DHCP（67 服务端/68 客户端两个 UDP 口）+ ICMP，首包三件套一网打尽 |
| `-v`                                            | 详细模式：DHCP 报文里的选项字段（DISCOVER/OFFER 携带什么参数）全展开                   |
| `-w /tmp/f429-boot.pcap`                        | 不解析、原文写入 pcap（packet capture 的通用存档格式，tcpdump/Wireshark 通吃）         |
| `&& tcpdump -r … -n`                            | `-r` 回读 pcap 离线分析——先抓后读，抓的窗口不受解析拖慢                                |

**你会看到**：`who-has` → DHCP 四步 → `echo request/reply` 的上线时序（完整形态见下方预期输出）。
**失败了先查**：接口名；RPi 自身流量混入——拿到 F429 的 MAC 后用 `ether host aa:bb:cc:…` 精确圈定（对端没 IP 时这是唯一锚点，下文坑 2）。

**预期输出（待实测核销）**：F429 上电后依次出现——`who-has 10.42.0.1 tell 10.42.0.x`（ARP，
请求网关 MAC）、`DHCPDISCOVER → OFFER → REQUEST → ACK`（若走 DHCP；裸机实验也可能静态配
置，则直接是 ARP+ICMP）、`ICMP echo request/reply`（F429 ch21 的「ping 通树莓派」做通标准）。

**已知坑**：

- `-i eth0` 以 `ip link` 实际名为准（网卡名漂移是老坑）；
- RPi 自身流量会混入，拿到 F429 的 MAC 后用 `ether host aa:bb:cc:…` 精确圈定；
- DHCP 用广播 udp 68→67，过滤器别写错方向；
- pcap 离线分析直接交给
  [[2026-08-28-lwip-deep-dive-extra-pcapx-pluggable-capture|lwIP 附加篇：pcapx]] 的套路与
  [[2026-08-26-lwip-deep-dive-ch23-debugging-toolbox|lwIP（二十三）：调试工具箱]]——抓下来的
  文件是三个系列共用的证据格式。

## 4. iperf3：吞吐对端

> 🎯 **你的主场**：iperf3 同样是你主场——本节的增量不在工具本身，在「**裸机板没有 iperf3 客户端**」这条事实链（下文诚实说明），拆解以参数坑位为主。

**用途**：两件事——① 测「链路本身」的基线上限（笔记本↔RPi 直连网线）；② 给
[[2026-08-30-f429-lab-ch22-esp32-vs-f429-throughput|F429 ch22]] 的全家对照当对端/参照。

**最小可用命令**：

```bash
sudo apt install iperf3
iperf3 -s                                # RPi 起服务端（默认 TCP 5201）
# 笔记本侧：
iperf3 -c 10.42.0.x -t 10                # TCP 上行基线
iperf3 -c 10.42.0.x -u -b 0 -t 10        # UDP 打满（-b 0 = 不限速，默认仅 1Mbps 是坑）
iperf3 -c 10.42.0.x -R                   # 反向（RPi 发、笔记本收）
iperf3 -c 10.42.0.x -P 4                 # 4 并行流
```

**命令拆解：** iperf3 六连

| 部分                      | 作用                                                                                   |
| ------------------------- | -------------------------------------------------------------------------------------- |
| `sudo apt install iperf3` | 装 iperf3（RPi 与笔记本两侧都要装）                                                    |
| `iperf3 -s`               | 服务端模式，默认监听 TCP **5201** 端口                                                 |
| `-c 10.42.0.x`            | 客户端模式，`-c` 指向服务端地址（跑在笔记本侧）                                        |
| `-t 10`                   | 测试持续 10 秒（默认也是 10s，写明便于复现）                                           |
| `-u -b 0`                 | `-u` 换 UDP；`-b` 设目标比特率，**`0` = 不限速打满**（UDP 模式默认只发 1Mbps——经典坑） |
| `-R`                      | reverse 反向：服务端发、客户端收——测下行方向的吞吐                                     |
| `-P 4`                    | 4 条并行流——测多流能否抬升总吞吐（单流受单连接窗口限制时常见手段）                     |

**你会看到**：TCP 模式 sender/receiver 两行 `Mbits/sec`；UDP 模式多一行 `Jitter` 与丢包率（读法见下表）。
**失败了先查**：5201 端口被占/防火墙；两端是否真在同一段（两侧 `ip addr` 对一下）。

**报告怎么读（形态示意，待实测）**：

| 模式 | 关键行                                                    | 说明                                  |
| ---- | --------------------------------------------------------- | ------------------------------------- |
| TCP  | `… Mbits/sec sender / receiver`                           | 两行都看；`Retr`（重传）高=链路质量差 |
| UDP  | `… Mbits/sec` + `Jitter: … ms` + `Lost/Total Dgrams (x%)` | 丢包率与抖动才是 UDP 的主指标         |

**已知坑与 F429 对接的诚实说明**：iperf3 是专有协议（控制信道+数据信道），**F429 裸机没有
iperf3 客户端**——所以用法是：笔记本↔RPi 先测**链路基线**（千兆直连预期数百 Mbps 起，待实测）；
F429 侧用自研 UDP 发送器打流，RPi 用 `tcpdump -w` 抓满再离线算 bytes/duration 得有效吞吐；
ESP32（IDF 自带 iperf 组件）可以真连 RPi 的 iperf3 服务端。三机同表就是 F429 ch22 的素材。
另外记住 TCP 吞吐受窗口约束——F429 上窗口是 lwIP 缓冲决定的（
[[2026-08-26-lwip-deep-dive-ch12-tcp-reliability-flow-control|lwIP（十二）：TCP 可靠性与流控]]），
链路基线再高，lwIP 侧也到不了。

## 5. hostapd：受控 AP

> 📖 **术语卡：hostapd**
> **是什么**：用户态的 AP（access point，接入点）守护进程：读一份 conf 文件，把无线网卡驱动成 802.11 接入点——发信标、管认证、走四次握手。
> **为什么存在**：让「受控的无线环境」可编程——信道、速率、认证方式全写在配置里，重启即复现，这是家用路由器黑盒给不了的。
> **类比**：把 RPi 变成一台「配置文件驱动的迷你路由器控制面」——频谱里的实验台。
> ⚠️ 类比边界：hostapd 只管 802.11 这一层：不管 IP 地址分配（那是 dnsmasq/静态配置的事）、不管报文转发（那是内核路由的事）。

**用途**：把 RPi4B 变成**单频段、单信道、参数可写**的 AP，给
[[2026-08-29-wifi-rf-hw-ch15-hands-on-measurements|WiFi RF（十五）：动手测量]] 与
[[2026-08-29-wifi-rf-hw-ch16-rate-negotiation|WiFi RF（十六）：速率协商]] 提供真机核销环境。
RPi4B 的优势恰是「穷」：2.4G 单频段、一次只开一个 BSS（Basic Service Set，一个 AP 广播出
的那个「网络」实体——SSID 是它的名字），不像家用路由器挤满邻居——**频谱里的
受控环境**（对照 RF 系列的干扰共存课）。

**最小 hostapd.conf**：

```text
interface=wlan0
driver=nl80211
ssid=RPi-Lab
country_code=CN
ieee80211d=1
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=<不少于8位>
```

**配置拆解：** hostapd.conf 逐行

| 行                                 | 作用                                                                                     |
| ---------------------------------- | ---------------------------------------------------------------------------------------- |
| `interface=wlan0`                  | 要驱动成 AP 的无线接口名（以 `ip link` 实名为准）                                        |
| `driver=nl80211`                   | 走 nl80211 驱动接口——内核无线的标准 netlink 接口，现代网卡全用它                         |
| `ssid=RPi-Lab`                     | 广播的网络名                                                                             |
| `country_code=CN` + `ieee80211d=1` | 法规域设 CN（术语卡见下）；`ieee80211d` = 在信标里通告国家码，让客户端同步遵守同一套约束 |
| `hw_mode=g` + `channel=6`          | 2.4GHz 频段（g）、信道 6——1/6/11 是 2.4G 里三个互不重叠的经典选择                        |
| `ieee80211n=1` + `wmm_enabled=1`   | 开 802.11n 高速模式；WMM（WiFi 多媒体 QoS 子层）是 802.11n 的前提条件，必须一起开        |
| `auth_algs=1`                      | 认证算法选「开放系统」：认证阶段不设防，真正的安全交给后面的 WPA 四次握手                |
| `wpa=2`                            | 只允许 WPA2（不兼容老的 WPA1）                                                           |
| `wpa_key_mgmt=WPA-PSK`             | 密钥管理用 PSK（pre-shared key，预共享密钥——「输密码连 WiFi」那个模式）                  |
| `rsn_pairwise=CCMP`                | 单播加密套件选 CCMP（基于 AES；WPA2 标配——已破的 TKIP 别用）                             |
| `wpa_passphrase=<不少于8位>`       | PSK 明文口令，长度下限 8 位                                                              |

**你会看到**：无——conf 是写给 hostapd 读的，效果看启动日志与下面两条 `iw` 查询。
**失败了先查**：前台日志第一条报错：最常见是 regdomain 不一致、或 wlan0 仍被 NetworkManager 抢管（见下）。

**最小可用命令**：

```bash
sudo apt install hostapd
nmcli device set wlan0 managed no          # Bookworm 坑：NM 默认管 wlan0，先剥离
sudo systemctl unmask hostapd              # RPi OS 传统：hostapd 出厂被 mask（待实测）
sudo hostapd ./hostapd.conf                # 前台跑，先看日志再谈服务化
iw dev wlan0 info                          # 预期 type AP、channel 6
iw dev wlan0 station dump                  # 客户端关联后：signal（dBm）等实测点
```

**命令拆解：** hostapd 上车五步

| 部分                                | 作用                                                                                                                                    |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `nmcli device set wlan0 managed no` | nmcli 是 NetworkManager（NM，发行版默认的网络管理服务）的命令行客户端；本句把 wlan0 从 NM 托管名单里摘出去——不摘则 NM 与 hostapd 抢网卡 |
| `sudo systemctl unmask hostapd`     | RPi OS 传统出厂把 hostapd 服务 **mask**（把服务单元符号链接到 /dev/null 的彻底禁用）；`unmask` 解除（Bookworm 是否如此待实测）          |
| `sudo hostapd ./hostapd.conf`       | 前台运行：日志直刷终端，先看它活不活、错在哪，再谈 systemd 服务化                                                                       |
| `iw dev wlan0 info`                 | iw 是无线设备配置命令行；本句查接口状态——预期 `type AP`、`channel 6`                                                                    |
| `iw dev wlan0 station dump`         | 列已关联站点（station）与其信号强度（signal，dBm）——RF 系列要的实测素材点                                                               |

**你会看到**：`info` 里 `type AP`；客户端关联后 `station dump` 冒出 MAC 与 signal 行。
**失败了先查**：wlan0 是否被 rfkill 软封锁（`rfkill list`）；`country_code` 与 `iw reg get` 是否一致（见下）。

**预期输出（待实测核销）**：ESP32/BOX-3 侧扫描到 `RPi-Lab` 并完成四次握手；
`station dump` 出现关联站点及其 signal 读数——这正是 RF 系列要的 dBm 级实测素材。

> 📖 **术语卡：regdomain（法规域）**
> **是什么**：各国无线电管理法规划定的边界——可用频段、可用信道、最大发射功率。无线驱动按 `country_code` 加载对应约束，`iw reg get` 可查当前生效的法规域。
> **为什么存在**：同一块网卡全球销售，法规各国不同——regdomain 是内核侧的合规开关。
> **类比（你的主场）**：像防火墙的策略边界：配置声明意图（country_code），内核执行约束（信道/功率上限）——当配置与内核认知不一致，按更严的执行。
> ⚠️ 类比边界：regdomain 管的是**发射侧硬约束**，与加密/认证无关——AP 密码再安全，配错法规域照样拒启或被迫改道。

**已知坑**：

- **regdomain**：`country_code` 与 `iw reg get` 要一致（CN 的 2.4G 功率/信道限制），不一致时
  hostapd 拒启或信道被迫改道——RF 系列的法规课（
  [[2026-08-29-wifi-rf-hardware-beginner-series-index|WiFi RF 系列索引]] 第 17 章）在实机上先收
  一笔利息；
- hostapd 不管 IP：最小核销只到关联+握手即可，需要跑业务再加 dnsmasq（轻量 DNS/DHCP 服务器，
  一个进程把 AP 的地址分配全包了）或静态地址；
- 想要受控的速率实验就锁 `ht_capab`（802.11n 高吞吐能力位的开关集：能开哪些 MCS 速率/特性
  写在这里）/信道带宽（20MHz 单宽是干净实验的默认姿态）；
- 与本系列「网线直连」主线的安全边界不冲突：AP 实验时 wlan0 独立，eth0 的 SSH 通道不受影响
  （`nmcli device set wlan0 managed no` 只动 wlan0）。

## 6. usbmon：USB 之眼

> 📖 **术语卡：usbmon**
> **是什么**：内核自带的 USB 总线监视接口：把流经各 USB 主机控制器的 URB 记录下来，经 debugfs 暴露成两套接口——文本（`Nu`，给人读）与二进制（`Ns`，给 Wireshark 吃）。
> **为什么存在**：USB 的对话全部发生在主机控制器里，用户态天生看不见——要看得内核自己录。
> **类比（你的主场）**：USB 版的 tcpdump——只不过抓的不是以太网帧，是主控制器与设备之间的 URB 事务。
> ⚠️ 类比边界：tcpdump 有 BPF 过滤器可以戴在内核里；usbmon 的文本流**没有过滤器**，只能全量录、事后筛（见坑 1）。

**用途**：抓 BOX-3（ESP32-S3，USB OTG / USB-Serial-JTAG——
[[2026-08-26-esp32-s3-box-3-ch5-image-and-flashing|BOX-3 第五章]]讲过它的原理）**插上笔记本/RPi
瞬间的枚举事务**（枚举 enumeration：设备插上后，主机通过控制传输逐步问出设备身份、分配地址、
选中配置的标准流程；控制传输 control transfer：USB 四种传输类型之一，专跑枚举这类「一问一答」）：
控制传输如何一步步把描述符（descriptor：设备自述身份的数据结构——设备/配置/字符串各有
一份）问出来。板在途，本节先备好仪器位。

**最小可用命令**：

```bash
lsusb; lsusb -t                            # 总线与树形拓扑（插前/插后各拍一张快照）
lsusb -v -d 303a:xxxx                      # 指定设备的全描述符 dump（VID/PID 待实测）
sudo mount -t debugfs none /sys/kernel/debug   # 若未挂（Bookworm 通常已挂）
sudo modprobe usbmon                       # usbmon 若为模块（内核配置待实测）
ls /sys/kernel/debug/usb/usbmon            # 预期 0u 1u …（文本接口，0u=全部总线）
sudo cat /sys/kernel/debug/usb/usbmon/0u   # 先开这个，再插 BOX-3
```

> 🎯 **你的主场边缘**：lsusb 是你平时就在用的工具，本节的增量用法是「拿它当**枚举对照的快照机**」——插前/插后各拍一张，diff 出新增设备即锁定目标总线与 VID:PID，再交给 usbmon 细看。

**命令拆解：** usbmon 上车七步

| 部分                                           | 作用                                                                                                               |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `lsusb; lsusb -t`                              | 平面清单（一行一设备：总线/设备号/VID:PID/描述——VID/PID = 厂商/产品标识，各 16 位）+ 树形拓扑（谁挂在哪个 hub 口） |
| `lsusb -v -d 303a:xxxx`                        | `-v` 全描述符 dump；`-d` 只看指定 `VID:PID`（乐鑫 VID 0x303a，PID 待实测）                                         |
| `sudo mount -t debugfs none /sys/kernel/debug` | 挂 debugfs（内核调试信息的伪文件系统，tracefs 的邻居前辈）——usbmon 藏在它下面                                      |
| `sudo modprobe usbmon`                         | modprobe = 加载内核模块；usbmon 若被编成模块（而非 built-in）就先装它                                              |
| `ls /sys/kernel/debug/usb/usbmon`              | 确认接口文件在：`0u` = 全部总线汇总，`1u`/`2u` = 各条总线各自一份                                                  |
| `sudo cat …/usbmon/0u`                         | 开读文本流——**先跑这条再插设备**，枚举事务一发生就被录下，动作完 Ctrl-C                                            |

**你会看到**：一屏 URB 文本行，插上 BOX-3 的瞬间猛刷一串（骨架见下方预期输出）。
**失败了先查**：`ls` 不见 usbmon 目录——usbmon 没编进内核也没编成模块（`zgrep USBMON /proc/config.gz`，待核对清单已记）。

> 📖 **术语卡：URB（USB Request Block）**
> **是什么**：USB 传输的基本单位——主机控制器与设备之间一次「提交—完成」的事务封装，内含方向、端点、数据与完成状态。
> **为什么存在**：USB 是主机主导的总线，一切收发都由主机提交请求、控制器异步完成，URB 就是这张请求单。
> **类比（你的主场）**：内核网络栈里的 skb（socket buffer）——一次 I/O 的统一信封，生命周期由提交方跟踪。
> ⚠️ 类比边界：skb 只在内存里流动；URB 还要落到线缆上的打包分帧——文本流里你看到的是请求单，不是线上的位。

**预期输出（待实测核销）**：文本 URB 流里依次出现枚举骨架——`GET_DESCRIPTOR (Device)` →
`SET_ADDRESS` → `GET_DESCRIPTOR (Device/Config/String)` → `SET_CONFIGURATION`（形态示意，具体
顺序/重试以实测为准）；用户态对应物是 `/dev/ttyACM*` 冒出来（USB CDC ACM 类——内核认出「USB
串口」后生成的设备节点；BOX-3 第五章的既定事实）。

**已知坑**：

- 0u 文本流**没有过滤器且量巨大**——一定先开 cat 再插设备，动作做完 Ctrl-C；
- `SET_ADDRESS` 只在首次枚举出现，重插若走 hub port reset 流程会少几步——对照分析时对齐场景；
- `lsusb -v` 部分描述符（字符串类）要 root；VID/PID 以 `lsusb` 实测为准（乐鑫 VID 为 0x303a，
  PID 因 OTG 模式而异，待核对）；
- 想进 wireshark 图形分析：用二进制接口（usbmon 的 `N s` 设备）抓流另存——文本接口给人看，
  二进制给工具吃。

## 本章待核对清单（汇总）

- pigpiod/piscope 在 Bookworm 的包名与上游 install.sh 的可用性；1µs 采样的实际 CPU 占用
- piscope 在笔记本（Fedora）远程连接 raspberrypi.local 的构建依赖
- Bookworm 出厂 I2C/SPI dtparam 的默认状态（i2c_arm 是否默认 on）
- F429 I2C 从机自配地址与 i2cdetect 实测表（F429 ch08 联动）
- 千兆直连的 iperf3 基线数值；F429 UDP 打流的有效吞吐测法落地
- hostapd 在 RPi OS Bookworm 是否出厂 masked；NM 的 wlan0 托管剥离是否影响 eth0
- usbmon 是 built-in 还是模块（`zgrep USBMON /proc/config.gz`）；BOX-3 的 VID/PID 实测
- 各「预期输出」块的实测核销（本系列统一纪律：不编造，实测后替换并移除占位标注）
