---
title: libgpiod 与用户态的过路费
date: 2026-08-30 03:40:00
description: 同一根脚走官方正道——Bookworm 的 libgpiod（注意是 1.6.3 不是 v2）、strace 给 devmem 与 gpioset 分别记账、翻转速率对比实验设计与量级推理
tags: [RPi, Linux, Driver, Lab]
---

# libgpiod 与用户态的过路费

> **状态声明**：本章为「先成文、后实跑」的实验设计，**未在真机执行**；以
> [[2026-08-30-rpi-lab-ch01-bookworm-surgery-baseline|ch01]] 升级后的 Bookworm 为前提。
> 所有「预期输出」均为待实测核销占位；性能量级表是**推理值**，不是实测值。

## 本章装备清单

| 分类   | 装备                 | 价格/状态 | 用途                 |
| ------ | -------------------- | --------- | -------------------- |
| 已有   | 树莓派 4B            | ✅        | 实验主体             |
| 已有   | MicroSD 卡+读卡器    | ✅        | 系统盘               |
| 已有   | 网线（直连笔记本）   | ✅        | SSH 访问             |
| 已有   | 笔记本（SSH 客户端） | ✅        | 控制台               |
| 需购买 | 杜邦线+LED+330Ω      | ~¥10      | 沿用 ch02 的同一颗灯 |

## 本章会遇到的词

| 词                  | 一句话版                                                    | 详见    |
| ------------------- | ----------------------------------------------------------- | ------- |
| libgpiod v1 / v2    | 官方 GPIO 库的两代：语法与 C API 全不兼容，抄命令前先验版本 | 第 1 节 |
| 线（line）          | 一根 GPIO 引脚在 libgpiod 里的称呼                          | 第 1 节 |
| 请求-持有-释放      | libgpiod 的所有权模型：先申请、进程活着就独占、fd 关即放    | 第 2 节 |
| /dev/gpiochipN      | 每块 GPIO 芯片一个字符设备，正门入口                        | 第 2 节 |
| /dev/gpiomem        | 树莓派特供：只露出 GPIO 寄存器页的窄门                      | 第 2 节 |
| udev                | 内核设备事件的用户态管家，负责给设备节点定权限/属组         | 第 2 节 |
| ioctl               | 「杂项控制」系统调用，设备专属命令都塞进它——你的主场        | 第 3 节 |
| strace / ptrace     | 系统调用记账器及其底层机制——你的主场                        | 第 4 节 |
| CLOCK_MONOTONIC_RAW | 单调递增时钟：只数时长、不受改时间影响，测速专用            | 第 3 节 |
| AXI 总线            | SoC 内部连 CPU 与外设的高速公路，写外设寄存器的最后一跳     | 第 5 节 |
| DMA                 | 外设自己搬数据不经 CPU，绕开 syscall 拥堵的终极方案         | 第 5 节 |

## 目标（先结论）

同一根 GPIO17、同一颗 LED（接线见 ch01），改走官方正道 libgpiod：命令族 + C API。然后用
strace 给 devmem 和 gpioset 各记一笔账，把「每层封装的过路费」算成一张系统调用账单；最后
设计翻转速率对比实验——三种实现、三个数量级的预期差，推理过程写明，实测留待核销。

| #    | 做通标准                                                        | 对应     |
| ---- | --------------------------------------------------------------- | -------- |
| R1.2 | gpioset 同脚同效果；strace 账单成表，与 ch02 的 devmem 账单对比 | 记账实验 |
| R1.4 | 翻转速率对比表（量级推理 + 实测计划）                           | 速率实验 |

## 1. 版本考古：Bookworm 是 libgpiod 1.6.3，不是 v2

第一个坑就在门口：libgpiod v2（2023 底发布）把命令行语法和 C API **全部重写**，而
**Raspberry Pi OS Bookworm 实际搭载的是 1.6.3**（v1 生态）——网上教程一半 v1 一半 v2，
抄之前必须先验货：

```bash
sudo apt install gpiod libgpiod-dev    # Bookworm 预期装到 1.6.3
gpioset --version                      # 先跑这一行再抄任何命令
```

**命令拆解：** 装包 + 验货

| 部分                       | 作用                                                                                               |
| -------------------------- | -------------------------------------------------------------------------------------------------- |
| `apt install gpiod`        | 装**命令行工具族**（gpioget/gpioset/gpiomon…）                                                     |
| `apt install libgpiod-dev` | 装**C 开发件**：头文件 `gpiod.h` + 链接库，第 3 节写代码要用                                       |
| `gpioset --version`        | 验货：打印实际版本号。v1 打印 `gpioset (libgpiod) 1.6.3` 一类，v2 形如 `2.x`——一行就知道抄哪代教程 |

**你会看到**：Bookworm 上预期 `1.6.3`；若打出 `2.x` 说明系统已换代，全章命令换 v2 写法。
**失败了先查**：`command not found`（没装 gpiod 包，只装了库不会有命令）。

v1/v2 语法对照（v1 列来自 Debian bookworm 手册页，v2 列来自 libgpiod 上游源码，均已核对；
**以实机版本为准**；上游 upstream = 项目的原始官方源码仓，发行版只是它的下游打包；trixie = Debian 13 代号，Bookworm 的下一站）：

| 动作       | v1.6.3（Bookworm 预期）              | v2.x（trixie 及以后）                   |
| ---------- | ------------------------------------ | --------------------------------------- |
| 读电平     | `gpioget gpiochip0 17`               | `gpioget -c gpiochip0 17`（或按线名）   |
| 拉高并持有 | `gpioset -m signal gpiochip0 17=1`   | `gpioset -c gpiochip0 17=1`（默认持有） |
| 周期翻转   | 无内建，靠 shell 循环                | `-t/--toggle <period>` 内建             |
| 边沿监听   | `gpiomon --rising-edge gpiochip0 17` | 选项改名（`-e/--edge`，待核对）         |
| 默认行为   | `-m exit`：设完即退出                | 默认不退出，持有到 Ctrl-C               |

本文命令**全部按 v1.6.3 写**，v2 差异单独标注。这不是保守，是「接口版本是环境事实」的
基本功——和 DPDK/LWIP 抄配置前先看版本号同一个道理（DPDK：高性能网卡收发包框架；LWIP：嵌入式轻量 TCP/IP 栈——都是你的主场，版本敏感是共同性格）。

## 2. 命令族实操与「三扇门」

```bash
gpiodetect                          # 列出所有 gpiochip
gpioinfo gpiochip0                  # 逐线状态：方向/电平/消费者
gpioget gpiochip0 17                # 读一次
gpioset -m signal gpiochip0 17=1    # 拉高并持有到 Ctrl-C
gpiomon --rising-edge gpiochip0 17  # 边沿事件（可拿另一根脚+按键做输入实验）
```

**命令拆解：** 五件套（参数按 v1.6.3）

| 命令                                 | 作用                                                                                                 |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `gpiodetect`                         | 列出本机全部 gpiochip：设备名、标签、线的根数                                                        |
| `gpioinfo gpiochip0`                 | 逐线清单：编号、名字、方向、当前电平、**消费者**（consumer：当前谁持有这根线；`unused` = 空闲）      |
| `gpioget gpiochip0 17`               | 向芯片 gpiochip0 申请读「线 17」，打印一次电平（0/1）                                                |
| `gpioset -m signal gpiochip0 17=1`   | 申请线 17 → 置 1；`-m signal` = 以「等信号」模式持有到 Ctrl-C 才退出（对照 `-m exit`：设完立即退出） |
| `gpiomon --rising-edge gpiochip0 17` | 订阅线 17 的上升沿事件，来了打一行时间戳（边沿：电平 0→1 的跳变瞬间）                                |

**你会看到**：gpioinfo 一行一根线，58 行左右；gpioset 期间 LED 亮、Ctrl-C 后按手册警告电平不保证保持。
**失败了先查**：`Device or resource busy` = 该线已有消费者（gpioinfo 里能看到是谁）；找不到 gpiochip0 = gpiodetect 先看实际芯片名。

> 📖 **术语卡：请求-持有-释放（request-hold-release）**
> **是什么**：libgpiod 的所有权模型——动线之前必须先向内核**申请**（request）这根线；申请成功后**持有**（hold）期间它登记在你名下、别的进程动不了；进程退出或 fd 关闭即**释放**（release）。
> **为什么存在**：治 ch02 三宗罪里的「无所有权、全局可写」——所有权不再是全局状态，而是**跟着 fd 生命周期走**的属性，进程一死内核自动回收，不留孤儿锁。
> **类比**：图书馆借阅——凭卡（fd）借书（线），卡注销（进程退出）书自动归还，别人永远借不到你手里的那本。
> ⚠️ 类比边界：释放的是「使用权」，引脚电平不一定回初值——手册警告的就是这个（下拉/保持见 ch05）。

语义要点（这是本节的核心，不是命令本身）：libgpiod 是**请求-持有-释放**模型。`gpioset`
默认 `-m exit` 立刻退出，手册原话警告退出后电平**不保证保持**——因为「持有」跟着进程的
文件描述符生命周期走，fd 关闭即释放（fd：file descriptor 文件描述符，进程持有资源的整数句柄——你的主场）。这是 ch02 三宗罪里「无所有权」的官方解药：
**所有权从全局状态变成了 fd 的属性**。

三扇门的权限光谱（把 ch02 的门禁知识收拢）：

| 门               | 能碰什么                 | 谁能进               | 护栏                    |
| ---------------- | ------------------------ | -------------------- | ----------------------- |
| `/dev/mem`       | 全部物理地址             | root                 | 几乎没有（CONFIG 锁外） |
| `/dev/gpiomem`   | 仅 GPIO 寄存器页         | gpiomem 组（待核对） | 窄，但裸写              |
| `/dev/gpiochipN` | 经内核 GPIO 子系统的正门 | gpio 组（预期 0660） | 请求制、事件、所有权    |

> 📖 **术语卡：/dev/gpiochipN（GPIO 字符设备）**
> **是什么**：现代 GPIO 的**正门**——每块 GPIO 控制器芯片在 /dev 下长出一个字符设备节点；libgpiod 的命令和 C API 底层全是 open 它 + ioctl 说话。
> **为什么存在**：把「碰 GPIO」纳入内核 GPIO 子系统的管理：每次动线要先请求、内核登记所有权、非法操作直接拒绝——正好是 ch02 sysfs 三宗罪的逐条解药。
> **类比**：银行柜台——不能自己进金库（/dev/mem），每笔业务填单（ioctl 请求），柜员（内核）核验后代你操作，全程留痕。

> 📖 **术语卡：/dev/gpiomem（树莓派特供的窄门）**
> **是什么**：树莓派内核提供的设备文件：只把 GPIO 控制器那一页寄存器（不是整个物理地址空间）映射给用户态，权限给到 gpiomem 组——pigpio、RPi.GPIO 这类库走的就是它。
> **定位**：宽窄介于 /dev/mem 与 /dev/gpiochipN 之间——裸写寄存器的能力保住了，爆炸半径被锁死在 GPIO 一页。
> ⚠️ 类比边界：它仍然**绕过** GPIO 子系统的所有权管理——能写，但没有请求/仲裁/事件，护栏只有「地址范围窄」这一道。

> 📖 **术语卡：udev**
> **是什么**：内核设备事件的用户态管家——内核每发现一个设备就发事件，udev 按规则给 /dev 下的设备节点**定名字、属主、属组、权限**（如 `/dev/gpiochip0 → root:gpio 0660`）。
> **为什么存在**：让「谁能用哪个设备」成为可配置的策略（规则文件），而不是内核写死；用户加进 gpio 组即可免 sudo 用 GPIO，就是这么来的。
> **类比**：楼宇访客系统——住户名单（组）和门禁卡权限（规则）集中管理，保安（内核）只认卡。
> ⚠️ 类比边界：udev 定的是**设备节点**的权限；chip 是否允许你的请求，仍由内核 GPIO 子系统在 ioctl 里二次裁决。

`ls -l /dev/gpiochip0` 预期 `root:gpio 0660`，pi 用户在 gpio 组里即可免 sudo——对比 ch02
devmem 必须 root，内核给 GPIO 开的是「窄门 + 全护栏」。

**命令拆解：** `ls -l /dev/gpiochip0`

| 部分        | 含义                                                   |
| ----------- | ------------------------------------------------------ |
| 第 1 位 `c` | 字符设备（ch02 已释）                                  |
| `root:gpio` | 属主 root、属组 gpio                                   |
| `0660`      | 属主读写、组读写、其他人无份（八进制权限位——你的主场） |

（看自己是否在 gpio 组：`groups` 里找 gpio；不在则 `sudo usermod -aG gpio pi` 后重登。）

## 3. C API：v1.6.3 版翻转程序

```c
// toggle.c — libgpiod v1.6 API（Bookworm 预期版本；v2 见下表）
#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char **argv)
{
    long n = argc > 1 ? atol(argv[1]) : 1000000;   /* 翻转次数 */
    int v = 0;
    struct gpiod_chip *chip = gpiod_chip_open_by_name("gpiochip0");
    struct gpiod_line *line = gpiod_chip_get_line(chip, 17);
    struct timespec t0, t1;

    if (!chip || !line) { perror("open"); return 1; }
    if (gpiod_line_request_output(line, "rpi-lab", 0) < 0) { perror("request"); return 1; }

    clock_gettime(CLOCK_MONOTONIC_RAW, &t0);
    for (long i = 0; i < n; i++) {
        v ^= 1;
        gpiod_line_set_value(line, v);             /* v1：每次翻转一次 ioctl */
    }
    clock_gettime(CLOCK_MONOTONIC_RAW, &t1);

    double sec = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("%ld toggles in %.3f s -> %.0f Hz (full cycles)\n", n, sec, n / 2 / sec);

    gpiod_line_release(line);
    gpiod_chip_close(chip);
    return 0;
}
```

```bash
gcc -O2 -o toggle toggle.c -lgpiod && ./toggle 1000000
```

**命令拆解：** `gcc -O2 -o toggle toggle.c -lgpiod`

| 部分        | 作用                                                          |
| ----------- | ------------------------------------------------------------- |
| `-O2`       | 开二级优化（测速程序要优化档，否则测的是编译器的懒惰）        |
| `-o toggle` | 产物可执行文件名 toggle                                       |
| `-lgpiod`   | 链接 libgpiod 共享库（`-l` + 库名，对应 libgpiod-dev 装的库） |

**代码走读：** toggle.c 五段

| 段                                  | 干什么                                                                                                                           |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `gpiod_chip_open_by_name(...)`      | 打开正门：按名字拿到 gpiochip0 的句柄                                                                                            |
| `gpiod_chip_get_line(chip, 17)`     | 挑线：在芯片里定位 17 号线（还没拿所有权）                                                                                       |
| `gpiod_line_request_output(...)`    | **申请**：以「rpi-lab」名义请求为输出、初值 0——内核从此登记持有者                                                                |
| 循环体 `gpiod_line_set_value(...)`  | 每次翻转 = 一次 **ioctl**（ioctl：向已打开的设备 fd 发「设备专属命令」的系统调用，命令号带参数打包进内核——你的主场，本章的主角） |
| `gpiod_line_release` + `chip_close` | 释放 + 关门：交还所有权                                                                                                          |

计时装具 `clock_gettime(CLOCK_MONOTONIC_RAW, ...)`：读**单调原始时钟**——只负责「从某个起点持续向上数纳秒」，不受 NTP 校时拨针影响（对比墙钟 CLOCK_REALTIME），测耗时专用；包在循环前后各读一次，差值即耗时。`v ^= 1` 是按位异或翻 0/1（0→1→0 循环），`n/2/sec` 是换算成完整周期数（一次翻转只是半个周期）。

v2 的 C API 是全面重构，函数名对照（草图，逐名以 libgpiod v2 文档为准，待核对）：

| 任务     | v1.6.3（上面用的）            | v2.x                                                 |
| -------- | ----------------------------- | ---------------------------------------------------- |
| 开芯片   | `gpiod_chip_open_by_name()`   | `gpiod_chip_open("/dev/gpiochip0")`                  |
| 配置方向 | `gpiod_line_request_output()` | `gpiod_line_settings` + `gpiod_line_config` 两级配置 |
| 拿请求   | （line 即请求句柄）           | `gpiod_chip_request_lines()` → `gpiod_line_request`  |
| 置值     | `gpiod_line_set_value()`      | `gpiod_line_request_set_value()`                     |

## 4. strace 记账实验设计

方法：对两种点灯方式各跑一次 strace（system call trace：把目标进程发出的**每一次系统调用**逐条记录下来的工具，底层靠 ptrace 机制拦下进程——你的主场，本章的记账员），先看序列再看汇总。系统调用 syscall 是用户态进内核干活的唯一正门（open/ioctl/close 全是它——你的主场）。

```bash
sudo apt install strace
sudo strace -o /tmp/devmem.log busybox devmem 0xFE20001C 4 0x00020000
sudo strace -o /tmp/gpioset.log gpioset -m time -s 1 gpiochip0 17=1
strace -c -o /tmp/devmem.sum busybox true     # 汇总模板（跑真命令替换 true）
grep -cE 'ioctl' /tmp/gpioset.log             # 手工对账
```

**命令拆解：** 记账四连

| 命令                                                 | 作用                                                                                          |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `strace -o /tmp/devmem.log 命令`                     | `-o` 把逐条 syscall 日志写进指定文件（不刷屏）                                                |
| `strace -o .../gpioset.log gpioset -m time -s 1 ...` | gpioset v1 的 `-m time` + `-s 1`：以「定时」模式持有 1 秒再退出，让 strace 有窗口抓全生命周期 |
| `strace -c -o .../devmem.sum 命令`                   | `-c` = 只出**汇总表**（各 syscall 的次数/耗时统计）；这里跑 `true` 只是占位模板               |
| `grep -cE 'ioctl' 日志`                              | 数 ioctl 出现行数（`-c` 计数、`-E` 走扩展正则），跟预期账单对账                               |

**你会看到**：devmem.log 里 openat + mmap 一串之后**再无**访存类调用；gpioset.log 里每次操作前都有一条 `ioctl(...)`。
**失败了先查**：日志里 `EPERM`（strace 需要的 ptrace 权限被限制）；漏掉 `-o` 直接刷屏到没法数。

预期账单（待实测核销）：

| 访客                | 每次动作的预期 syscall 序列                                                                                                  | 关键差异                   |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| busybox devmem      | execve + 十余个 openat（动态链接器/libc）+ openat("/dev/mem") + mmap×2 + munmap + close×N                                    | 数据面 **0 syscall**       |
| gpioset（一次置值） | openat("/dev/gpiochip0") + ioctl(GET_CHIPINFO) + ioctl(GET_LINEINFO) + ioctl(GET_LINEHANDLE 请求) + ioctl(SET_VALUE) + close | 每次 setValue = 1 次 ioctl |

（表内 syscall 速查，均为你的主场：execve = 启动新程序；openat = 打开文件/设备；动态链接器 = 程序启动时把依赖的共享库挂进内存的那环；mmap/munmap = 映射/解除映射一段地址；close = 关闭 fd。GET_CHIPINFO/GET_LINEINFO/SET_VALUE 等是 GPIO 字符设备定义的 ioctl **命令号**——内核给每种「公文」编的号。）

原理层的两个洞察：

1. **devmem 的寄存器写不在 syscall 里**。open/mmap 只是「借道手续」，借完之后 CPU 对映射页的
   每次 store 直达外设、零系统调用——一次借道可以无限次写。它快，是因为它根本没过安检。
2. **libgpiod 把每次动线装进 ioctl 的「公文包」**。内核在 ioctl 里验请求、记账所有权、
   才代你碰寄存器。慢在每一次都要过一次系统调用边界，换到的是：非法请求进不来、两个进程
   抢一根脚会被内核仲裁、边沿事件有处订阅。

一句话类比：devmem = 拿到机房钥匙自己进去拔线；gpiod = 每次去值班室填单子，慢，但每一单
都有门禁记录、有值班员拦着别人同时进。

实验纪律：**记账用 strace，测速绝不在 strace 下测**——ptrace（process trace：strace 的底层机制，被跟踪进程每次 syscall 都要暂停等跟踪者过目一眼——你的主场）给每个 syscall 加的开销
（µs 级）足以把账算歪。

## 5. 翻转速率对比实验设计（量级推理，待实测）

三种实现、三种「过路费」：进程创建（ms 级）、系统调用（µs 级）、访存（百 ns 级）——三个
数量级正好对应三层接口。测量用循环计数器（`clock_gettime(CLOCK_MONOTONIC_RAW)` 包住 N 次
翻转），用 piscope 1µs 采样（piscope：树莓派上的**软件逻辑分析仪**——用 DMA 持续采样所有 GPIO 引脚电平、在浏览器里画波形，不花一分钱仪器钱；[[2026-08-30-rpi-lab-ch08-instrument-roles-guide|ch08 仪器手册]]）
或万用表/LED 做波形侧的交叉验证。

| 实现                                           | 预期量级    | 推理链                                                                               |
| ---------------------------------------------- | ----------- | ------------------------------------------------------------------------------------ |
| shell 循环 busybox devmem（set+clr 两次/周期） | ~10² Hz     | 每次翻转 = fork+execve+动态链接+open/mmap/munmap/close，进程创建即 1–3ms，一周期两次 |
| shell 循环 gpioset v1（同上结构）              | ~10¹–10² Hz | 同为进程创建主导，ioctl 只占零头                                                     |
| C：mmap /dev/mem 一次 + 紧循环直写 GPSET/GPCLR | ~10⁶–10⁷ Hz | 数据面 0 syscall；每周期 2 次 Device 内存写，AXI 外设写 ~百 ns 级                    |
| C：libgpiod v1 set_value 循环                  | ~10⁵–10⁶ Hz | 每次翻转 1 次 ioctl，syscall 往返 ~1–2µs                                             |

（推理链两处生词：fork+execve = Linux 创建新进程 + 换入新程序映像的系统调用对，shell 每跑一条外部命令一次——你的主场；AXI：SoC 内部把 CPU 与各外设控制器连起来的高速互联总线，寄存器写的最后一跳就是它，单次写延迟约百 ns 级。）

devmem 的 C 版骨架（对比程序，与 toggle.c 同构）：

```c
/* 核心三行：一次借道，无限次写——这就是零 syscall 数据面 */
int fd = open("/dev/mem", O_RDWR | O_SYNC);
volatile uint32_t *gpio = mmap(NULL, 0x1000, PROT_WRITE, MAP_SHARED,
                               fd, 0xFE200000);
for (long i = 0; i < n; i++) { gpio[0x1C/4] = 1u<<17; gpio[0x28/4] = 1u<<17; }
```

**代码走读：** 与 ch02 手算的地址对上号——`gpio` 指向 0xFE200000 整页；`gpio[下标]` 按 **uint32（4 字节）**为单位寻址，所以偏移先除以 4：`0x1C/4 = 7` 号格正是 GPSET0、`0x28/4 = 10` 号格是 GPCLR0；循环体每轮写 `1u<<17`（bit17=1）一次置位一次清零 = 一个完整周期——三行循环全部是普通内存写指令，一条 syscall 都没有（`volatile`：禁止编译器把这些「有副作用」的写合并/优化掉，ch02 已释）。

这张表本身就是「为什么有人写裸机」的量化答案，也是为什么协议位拆不该用 shell/轮询做——
要么进内核（[[2026-08-30-rpi-lab-ch04-kernel-module-mygpio|ch04]]），要么 DMA（Direct Memory Access：让专门控制器自己搬数据的机制，CPU 不再逐次参与搬运，网卡收包、piscope 采样都靠它——ch08 再见）。1MHz 量级的
方波需求一到，三扇门里只有「零 syscall」那扇够用。

## 预期输出（待实测核销）

```text
$ gpiodetect
gpiochip0 [pinctrl-bcm2711] (58 lines)     # 标签与行数以实测为准
...                                        # 可能有扩展器/virt 芯片

$ gpioinfo gpiochip0 | head -5
line   0:      unnamed       unused   input  active-high

$ gpioget gpiochip0 17
0                                           # LED 熄灭时

$ ./toggle 1000000
1000000 toggles in x.xxx s -> xxxxxx Hz     # 预期 10^5–10^6 量级
```

（输出注：`pinctrl-bcm2711` 是内核 pinctrl 驱动给 BCM2711 这颗 GPIO 控制器挂的设备标签；「扩展器/virt 芯片」= 外挂 I2C/SPI 的 GPIO 扩展芯片 / 内核里软件模拟的虚拟 GPIO 芯片（测试用），都会各自登记成一个 gpiochip。）

## 与 F429/裸机对照

| 维度     | F429 直写 BSRR               | Linux 用户态               |
| -------- | ---------------------------- | -------------------------- |
| 过路费   | 无——一条 store 指令          | syscall 边界 / 进程创建    |
| 护栏     | 无——任何代码都能踩任何寄存器 | 请求制 + 所有权 + 权限     |
| 速率上限 | 总线写速度（几十 MHz 级）    | 见上表，最高也是总线写速度 |
| 多方仲裁 | 靠程序员自觉 + 临界区        | 内核 GPIO 子系统强制       |

FreeRTOS 的临界区/优先级是最原始的「过路费」，Linux 把收费亭统一设在 syscall 边界——换来
的是**全系统一致的检查点**。代价看得见：一两个数量级的吞吐。这张账单在
[[2026-08-30-rpi-lab-ch07-read-syscall-fullstack-trace|ch07（一次 read 的全栈旅行）]] 会从
另一头再算一遍。

## 待核对清单

- 实机 libgpiod 版本（预期 1.6.3；若已升 v2，命令与 API 全章换 v2 语法）
- `/dev/gpiochip0` 的属主/权限（预期 root:gpio 0660）与 pi 的 gpio 组成员身份
- `/dev/gpiomem` 是否存在、属组是什么
- v2 命令行选项的准确拼写（`-e rising` 等）
- gpiomon v1 的 `--rising-edge` 选项拼写
- 速率表三个量级（10² / 10⁵–10⁶ / 10⁶–10⁷）的实测核销
- gpiodetect 输出的 gpiochip 标签（pinctrl-bcm2711?）与行数（58?）
